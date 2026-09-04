//! PNG decoding, written rather than depended on (ADR-0018).
//!
//! The reason is not that PNG is interesting. It is that **images are the first thing a
//! stranger's file reaches directly** — a mod ships a texture, and this code parses it.
//! Image decoders are historically the richest source of memory-safety bugs in software of
//! this kind, so the untrusted path is Zig, where an index is checked and a malformed file
//! produces an error instead of undefined behaviour.
//!
//! Two things are taken from `std` rather than written, because both are correct there and
//! neither is where the risk lives: `std.compress.flate` for the zlib stream (including its
//! Adler-32 footer) and `std.hash.Crc32` for chunk checksums.
//!
//! **The supported subset is stated and everything outside it is refused**, never
//! approximated: bit depth 8, colour types 0/2/3/4/6, `tRNS` transparency, non-interlaced.
//! 16-bit channels and Adam7 interlacing return `error.UnsupportedImage` — a mod author
//! gets a sentence, and M3's content pipeline is the right place to transcode.
//!
//! Colour management is deliberately absent: `gAMA`, `cHRM` and `iCCP` are ignored and the
//! data is taken to be sRGB, which is what `Image` documents and what essentially every
//! sprite PNG in existence actually is.

const std = @import("std");
const core = @import("core");

const Image = @import("image.zig").Image;

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.asset);

pub const DecodeError = error{
    /// Not a PNG, or a PNG that violates the format: bad signature, bad chunk CRC,
    /// truncation, a palette index out of range, a broken compressed stream.
    InvalidImage,
    /// A valid PNG this decoder does not handle. Distinct from `InvalidImage` because the
    /// file is fine and the answer for the author is different.
    UnsupportedImage,
    /// Larger than `Limits` allows.
    ImageTooLarge,
    OutOfMemory,
};

/// Bounds applied **before** anything is allocated from a size the file supplied.
///
/// "Allocate what the header claims" is precisely how decoders are made to exhaust memory,
/// so the header is checked against these first and the allocation happens second.
pub const Limits = struct {
    /// Refused above this in either axis. 8192 is a common GPU texture limit; a caller
    /// that knows its device's real limit should pass it.
    max_dimension: u32 = 8192,
    /// Total pixels, which bounds the decoded image at 16 M pixels — 64 MiB of RGBA.
    max_pixels: u64 = 1 << 24,
    /// Total `IDAT` bytes. A compressed stream can be far smaller than what it expands
    /// to, but the expansion is separately bounded by `max_pixels`, so this only needs to
    /// stop an absurd file before it is copied.
    max_compressed_bytes: usize = 64 << 20,
};

pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// Whether `bytes` begins with the PNG signature. Cheap, and the basis for dispatching
/// between decoders once there is more than one.
pub fn isPng(bytes: []const u8) bool {
    return bytes.len >= signature.len and std.mem.eql(u8, bytes[0..signature.len], &signature);
}

const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    palette = 3,
    grayscale_alpha = 4,
    rgba = 6,

    /// Bytes per pixel in the *filtered* data, at bit depth 8. Palette entries are one
    /// index byte, which is why this is not simply the output channel count.
    fn channels(self: ColorType) usize {
        return switch (self) {
            .grayscale => 1,
            .rgb => 3,
            .palette => 1,
            .grayscale_alpha => 2,
            .rgba => 4,
        };
    }
};

const Filter = enum(u8) { none = 0, sub = 1, up = 2, average = 3, paeth = 4 };

const Header = struct {
    width: u32,
    height: u32,
    color_type: ColorType,
};

/// Decode `bytes` into an RGBA8 `Image` owned by `gpa`.
///
/// `bytes` is borrowed and may be freed as soon as this returns.
pub fn decode(gpa: Allocator, bytes: []const u8, limits: Limits) DecodeError!Image {
    if (!isPng(bytes)) return error.InvalidImage;

    var header: ?Header = null;
    var palette: []const u8 = &.{};
    var transparency: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var idat_finished = false;
    var saw_end = false;

    var chunks: ChunkIterator = .{ .bytes = bytes, .pos = signature.len };
    while (try chunks.next()) |chunk| {
        // The first chunk must be IHDR, and nothing may precede it. Enforced rather than
        // assumed, because every later chunk's validation depends on the header.
        if (header == null and !std.mem.eql(u8, &chunk.kind, "IHDR")) return error.InvalidImage;

        if (std.mem.eql(u8, &chunk.kind, "IHDR")) {
            if (header != null) return error.InvalidImage;
            header = try parseHeader(chunk.data, limits);
        } else if (std.mem.eql(u8, &chunk.kind, "PLTE")) {
            if (palette.len != 0 or idat.items.len != 0) return error.InvalidImage;
            if (chunk.data.len == 0 or chunk.data.len % 3 != 0 or chunk.data.len > 256 * 3) {
                return error.InvalidImage;
            }
            palette = chunk.data;
        } else if (std.mem.eql(u8, &chunk.kind, "tRNS")) {
            if (transparency.len != 0 or idat.items.len != 0) return error.InvalidImage;
            transparency = chunk.data;
        } else if (std.mem.eql(u8, &chunk.kind, "IDAT")) {
            // The spec requires IDAT chunks to be consecutive. Enforcing it costs one
            // bool and rejects a class of malformed file that would otherwise decode.
            if (idat_finished) return error.InvalidImage;
            if (idat.items.len + chunk.data.len > limits.max_compressed_bytes) {
                return error.ImageTooLarge;
            }
            try idat.appendSlice(gpa, chunk.data);
        } else if (std.mem.eql(u8, &chunk.kind, "IEND")) {
            if (chunk.data.len != 0) return error.InvalidImage;
            saw_end = true;
            break;
        } else {
            // Bit 5 of the first byte clear means uppercase, which means *critical*: a
            // decoder that does not understand it must not pretend it decoded the file.
            // Ancillary chunks — gamma, text, timestamps — are skipped, which is the
            // whole point of the distinction.
            if (chunk.kind[0] & 0x20 == 0) {
                log.warn("png: unsupported critical chunk '{s}'", .{chunk.kind});
                return error.UnsupportedImage;
            }
        }

        if (idat.items.len != 0 and !std.mem.eql(u8, &chunk.kind, "IDAT")) idat_finished = true;
    }

    const info = header orelse return error.InvalidImage;
    if (!saw_end or idat.items.len == 0) return error.InvalidImage;
    if (info.color_type == .palette and palette.len == 0) return error.InvalidImage;
    try validateTransparency(info, palette, transparency);

    const channels = info.color_type.channels();
    const stride = @as(usize, info.width) * channels;
    // Every scanline is prefixed by one filter byte. This product is bounded by the
    // limits already applied to width and height.
    const raw_len = @as(usize, info.height) * (stride + 1);

    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    try inflateExact(idat.items, raw);
    try unfilter(raw, info.height, stride, channels);

    return expand(gpa, info, raw, stride, palette, transparency);
}

const Chunk = struct {
    kind: [4]u8,
    data: []const u8,
};

const ChunkIterator = struct {
    bytes: []const u8,
    pos: usize,

    fn next(self: *ChunkIterator) DecodeError!?Chunk {
        if (self.pos == self.bytes.len) return null;
        // Length and type, then data, then CRC. Anything shorter is truncation.
        if (self.pos + 8 > self.bytes.len) return error.InvalidImage;

        const len = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
        // The spec caps a chunk at 2^31-1; the buffer caps it far lower. Checking against
        // the buffer first means the addition below cannot overflow.
        if (len > self.bytes.len - self.pos - 8) return error.InvalidImage;

        const kind_start = self.pos + 4;
        const data_start = kind_start + 4;
        const data_end = data_start + len;
        if (data_end + 4 > self.bytes.len) return error.InvalidImage;

        const stored_crc = std.mem.readInt(u32, self.bytes[data_end..][0..4], .big);
        // The CRC covers the type and the data, not the length.
        if (std.hash.Crc32.hash(self.bytes[kind_start..data_end]) != stored_crc) {
            return error.InvalidImage;
        }

        self.pos = data_end + 4;
        return .{
            .kind = self.bytes[kind_start..][0..4].*,
            .data = self.bytes[data_start..data_end],
        };
    }
};

fn parseHeader(data: []const u8, limits: Limits) DecodeError!Header {
    if (data.len != 13) return error.InvalidImage;

    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    const bit_depth = data[8];
    const color_type_raw = data[9];
    const compression = data[10];
    const filter_method = data[11];
    const interlace = data[12];

    if (width == 0 or height == 0) return error.InvalidImage;
    // Only method 0 is defined for either. A file claiming otherwise is malformed rather
    // than merely unsupported: no such PNG exists.
    if (compression != 0 or filter_method != 0) return error.InvalidImage;

    const color_type = std.enums.fromInt(ColorType, color_type_raw) orelse
        return error.InvalidImage;

    switch (interlace) {
        0 => {},
        1 => {
            log.warn("png: Adam7 interlacing is not supported", .{});
            return error.UnsupportedImage;
        },
        else => return error.InvalidImage,
    }

    switch (bit_depth) {
        8 => {},
        1, 2, 4, 16 => {
            // Valid PNG, outside the subset. Whether this particular depth is legal for
            // this colour type is not checked, because the answer is the same either way.
            log.warn("png: bit depth {d} is not supported; only 8 is", .{bit_depth});
            return error.UnsupportedImage;
        },
        else => return error.InvalidImage,
    }

    if (width > limits.max_dimension or height > limits.max_dimension) return error.ImageTooLarge;
    if (@as(u64, width) * @as(u64, height) > limits.max_pixels) return error.ImageTooLarge;

    return .{ .width = width, .height = height, .color_type = color_type };
}

fn validateTransparency(info: Header, palette: []const u8, transparency: []const u8) DecodeError!void {
    if (transparency.len == 0) return;
    switch (info.color_type) {
        // tRNS is meaningless when the image already carries alpha, and the spec forbids it.
        .grayscale_alpha, .rgba => return error.InvalidImage,
        .grayscale => if (transparency.len != 2) return error.InvalidImage,
        .rgb => if (transparency.len != 6) return error.InvalidImage,
        .palette => if (transparency.len > palette.len / 3) return error.InvalidImage,
    }
}

/// Decompress exactly `out.len` bytes, and require the stream to end there.
///
/// Both halves matter. A short stream leaves part of the image undefined; a long one means
/// the file disagrees with its own header, and one of the two is lying.
///
/// Streaming into a *fixed* writer gets both checks and the checksum from one call: an
/// over-long stream fails the write, a short one returns fewer bytes than asked for, and
/// running to the end is what makes the decompressor consume the zlib footer and verify
/// its Adler-32. `streamRemaining` rather than `readSliceAll` because only the streaming
/// path works with a zero-length window buffer, which is how `std` itself drives this.
fn inflateExact(compressed: []const u8, out: []u8) DecodeError!void {
    var input: std.Io.Reader = .fixed(compressed);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});

    var writer: std.Io.Writer = .fixed(out);
    const written = decompress.reader.streamRemaining(&writer) catch return error.InvalidImage;
    if (written != out.len) return error.InvalidImage;
}

/// Reverse the per-scanline filters, in place, leaving each row's data unfiltered.
///
/// `raw` is `height` rows of `1 + stride` bytes. Row `y`'s filter refers to the byte
/// `bpp` to its left in the same row and to the same byte in the row above, both of which
/// are already unfiltered by the time they are read.
fn unfilter(raw: []u8, height: u32, stride: usize, bpp: usize) DecodeError!void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_start = @as(usize, y) * (stride + 1);
        const filter = std.enums.fromInt(Filter, raw[row_start]) orelse
            return error.InvalidImage;
        const row = raw[row_start + 1 ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else raw[row_start - stride ..][0..stride];

        switch (filter) {
            .none => {},
            .sub => for (bpp..stride) |i| {
                row[i] = row[i] +% row[i - bpp];
            },
            .up => if (prev) |above| {
                for (0..stride) |i| row[i] = row[i] +% above[i];
            },
            .average => {
                for (0..stride) |i| {
                    const left: u16 = if (i >= bpp) row[i - bpp] else 0;
                    const above: u16 = if (prev) |p| p[i] else 0;
                    row[i] = row[i] +% @as(u8, @truncate((left + above) / 2));
                }
            },
            .paeth => {
                for (0..stride) |i| {
                    const left: u8 = if (i >= bpp) row[i - bpp] else 0;
                    const above: u8 = if (prev) |p| p[i] else 0;
                    const corner: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
                    row[i] = row[i] +% paeth(left, above, corner);
                }
            },
        }
    }
}

/// The PNG predictor: whichever of left, above and upper-left is closest to `a + b - c`.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn expand(
    gpa: Allocator,
    info: Header,
    raw: []const u8,
    stride: usize,
    palette: []const u8,
    transparency: []const u8,
) DecodeError!Image {
    var image = try Image.alloc(gpa, info.width, info.height);
    errdefer image.deinit(gpa);

    // At bit depth 8 a tRNS sample is stored as two bytes with the value in the low one.
    const key_gray: ?u8 = if (info.color_type == .grayscale and transparency.len == 2)
        transparency[1]
    else
        null;
    const key_rgb: ?[3]u8 = if (info.color_type == .rgb and transparency.len == 6)
        .{ transparency[1], transparency[3], transparency[5] }
    else
        null;

    var y: u32 = 0;
    while (y < info.height) : (y += 1) {
        const src = raw[@as(usize, y) * (stride + 1) + 1 ..][0..stride];
        const dst = image.row(y);
        var x: u32 = 0;
        while (x < info.width) : (x += 1) {
            const out = dst[@as(usize, x) * 4 ..][0..4];
            switch (info.color_type) {
                .grayscale => {
                    const v = src[x];
                    out.* = .{ v, v, v, if (key_gray) |k| (if (v == k) 0 else 255) else 255 };
                },
                .rgb => {
                    const p = src[@as(usize, x) * 3 ..][0..3];
                    const opaque_alpha: u8 = if (key_rgb) |k|
                        (if (std.mem.eql(u8, p, &k)) 0 else 255)
                    else
                        255;
                    out.* = .{ p[0], p[1], p[2], opaque_alpha };
                },
                .palette => {
                    const index = src[x];
                    // The one bounds check that the file controls directly, and the
                    // reason a palette PNG is the classic decoder exploit.
                    if (@as(usize, index) * 3 + 3 > palette.len) return error.InvalidImage;
                    const entry = palette[@as(usize, index) * 3 ..][0..3];
                    const alpha: u8 = if (index < transparency.len) transparency[index] else 255;
                    out.* = .{ entry[0], entry[1], entry[2], alpha };
                },
                .grayscale_alpha => {
                    const p = src[@as(usize, x) * 2 ..][0..2];
                    out.* = .{ p[0], p[0], p[0], p[1] };
                },
                .rgba => out.* = src[@as(usize, x) * 4 ..][0..4].*,
            }
        }
    }

    return image;
}

// ---------------------------------------------------------------------------------
// Tests
//
// The fixtures below come from scripts/gen-test-pngs.py, which shares no code with
// this decoder. That is deliberate: a fixture produced by our own filter routines
// would agree with our own bugs, and Python's zlib emits a real Huffman-coded stream
// where the hand-assembled stored-block builder further down does not.
// ---------------------------------------------------------------------------------

const testing = std.testing;

/// 4x4 RGBA, every scanline Paeth-filtered.
const png_rgba_paeth = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
    0x08, 0x06, 0x00, 0x00, 0x00, 0xA9, 0xF1, 0x9E, 0x7E, 0x00, 0x00, 0x00,
    0x2C, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xE1, 0x12, 0x61, 0xFD,
    0x6F, 0xC3, 0xA0, 0xC1, 0x00, 0xC3, 0x2C, 0x0C, 0x36, 0x1A, 0xE7, 0x18,
    0x18, 0x6E, 0x30, 0x30, 0x30, 0x04, 0x30, 0x80, 0x68, 0xA8, 0x00, 0x88,
    0xD3, 0x01, 0xC4, 0x28, 0x2A, 0x34, 0xC0, 0x2A, 0x00, 0x70, 0x1E, 0x0A,
    0xCD, 0x85, 0xA6, 0xAB, 0xCB, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
};

/// The same 4x4 image, Average-filtered. Must decode identically.
const png_rgba_average = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
    0x08, 0x06, 0x00, 0x00, 0x00, 0xA9, 0xF1, 0x9E, 0x7E, 0x00, 0x00, 0x00,
    0x3C, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xE6, 0x12, 0x61, 0xFD,
    0xEF, 0xC8, 0xA5, 0xDD, 0x10, 0xCF, 0x65, 0xDF, 0x50, 0xCB, 0x15, 0xDC,
    0xC0, 0xCC, 0xEA, 0xA6, 0xED, 0x27, 0x27, 0x77, 0xE3, 0xB9, 0x9C, 0x5C,
    0xC0, 0x73, 0x10, 0xCD, 0xCC, 0x9A, 0x62, 0x6F, 0x0A, 0xE1, 0x74, 0x00,
    0x31, 0x03, 0x50, 0xA0, 0x29, 0x58, 0x06, 0xA2, 0x82, 0x01, 0xAC, 0x02,
    0x00, 0xB2, 0xED, 0x16, 0x01, 0xC5, 0x99, 0x1B, 0x71, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

/// 3x2 palette image with a tRNS shorter than the palette.
const png_palette_trns = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x03, 0x00, 0x00, 0x00, 0xAA, 0xAA, 0x96, 0x28, 0x00, 0x00, 0x00,
    0x0C, 0x50, 0x4C, 0x54, 0x45, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00,
    0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xD6, 0x02, 0x8F, 0x7B, 0x00, 0x00, 0x00,
    0x02, 0x74, 0x52, 0x4E, 0x53, 0x00, 0x80, 0x9B, 0x2B, 0x4E, 0x18, 0x00,
    0x00, 0x00, 0x10, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x64, 0x60,
    0x64, 0x64, 0x64, 0xFE, 0xFF, 0x1F, 0x00, 0x03, 0x25, 0x02, 0x06, 0x53,
    0x4E, 0x98, 0xD5, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
};

/// 2x2 greyscale at 16 bits: valid PNG, outside the subset.
const png_grayscale_16bit = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x10, 0x00, 0x00, 0x00, 0x00, 0x07, 0x4D, 0x8E, 0xBB, 0x00, 0x00, 0x00,
    0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, 0x60, 0xF8, 0xFF,
    0x9F, 0xA1, 0x81, 0xC1, 0x81, 0x01, 0x00, 0x0F, 0x7D, 0x02, 0xBF, 0x3A,
    0x01, 0x20, 0x94, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
};

/// 4x4 RGBA declaring Adam7 interlacing.
const png_interlaced = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
    0x08, 0x06, 0x00, 0x00, 0x01, 0xDE, 0xF6, 0xAE, 0xE8, 0x00, 0x00, 0x00,
    0x47, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x05, 0xC1, 0xA1, 0x01, 0x00,
    0x40, 0x04, 0x00, 0x40, 0x45, 0x91, 0xAD, 0xF1, 0x6B, 0xC8, 0x8A, 0x21,
    0x7E, 0x08, 0xE5, 0xB3, 0x0D, 0xEC, 0x22, 0x2B, 0x66, 0xF2, 0x77, 0x40,
    0x8C, 0x2B, 0x7C, 0xF6, 0xB1, 0x6D, 0xB1, 0x2F, 0x90, 0x9E, 0x11, 0xC5,
    0x79, 0xEA, 0x53, 0x6A, 0x03, 0x14, 0x96, 0x12, 0x9E, 0x2F, 0x30, 0x2B,
    0x4E, 0x02, 0xB5, 0x5F, 0x69, 0xBB, 0xAF, 0xCF, 0xAD, 0xC6, 0xFB, 0x01,
    0xA1, 0x31, 0x1C, 0x71, 0x85, 0xC7, 0xF1, 0x17, 0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

/// The 4x4 image's pixels, RGBA, top row first.
const expected_rgba = [_]u8{
    0x0A, 0x14, 0x05, 0xFF, 0x46, 0x14, 0x2D, 0xFF, 0x82, 0x14, 0x55, 0xFF,
    0xBE, 0x14, 0x7D, 0xFF, 0x0A, 0x50, 0x2D, 0xCD, 0x46, 0x50, 0x05, 0xCD,
    0x82, 0x50, 0x7D, 0xCD, 0xBE, 0x50, 0x55, 0xCD, 0x0A, 0x8C, 0x55, 0x9B,
    0x46, 0x8C, 0x7D, 0x9B, 0x82, 0x8C, 0x05, 0x9B, 0xBE, 0x8C, 0x2D, 0x9B,
    0x0A, 0xC8, 0x7D, 0x69, 0x46, 0xC8, 0x55, 0x69, 0x82, 0xC8, 0x2D, 0x69,
    0xBE, 0xC8, 0x05, 0x69,
};

/// Builds a PNG from parts, so that a test can produce one that is wrong in exactly one
/// way. The compressed stream uses stored DEFLATE blocks, which needs no compressor and
/// makes the bytes predictable.
fn appendChunk(gpa: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len_bytes);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);

    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try out.appendSlice(gpa, &crc_bytes);
}

fn zlibStored(gpa: Allocator, data: []const u8) ![]u8 {
    std.debug.assert(data.len <= 0xFFFF);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // CMF 0x78 (deflate, 32 KiB window) and FLG 0x01, chosen so the pair is a multiple
    // of 31, which is how zlib headers are checked.
    try out.appendSlice(gpa, &.{ 0x78, 0x01 });
    // One final stored block: BFINAL=1, BTYPE=00, then padding to a byte boundary.
    try out.append(gpa, 0x01);

    const len: u16 = @intCast(data.len);
    const nlen = ~len;
    try out.appendSlice(gpa, &.{
        @as(u8, @truncate(len)),  @as(u8, @truncate(len >> 8)),
        @as(u8, @truncate(nlen)), @as(u8, @truncate(nlen >> 8)),
    });
    try out.appendSlice(gpa, data);

    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(data), .big);
    try out.appendSlice(gpa, &adler);

    return out.toOwnedSlice(gpa);
}

const BuildOptions = struct {
    width: u32,
    height: u32,
    color_type: u8,
    bit_depth: u8 = 8,
    interlace: u8 = 0,
    /// Scanlines, each prefixed by its filter byte.
    filtered: []const u8,
    palette: ?[]const u8 = null,
    trns: ?[]const u8 = null,
};

fn buildPng(gpa: Allocator, options: BuildOptions) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], options.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], options.height, .big);
    ihdr[8] = options.bit_depth;
    ihdr[9] = options.color_type;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = options.interlace;
    try appendChunk(gpa, &out, "IHDR", &ihdr);

    if (options.palette) |p| try appendChunk(gpa, &out, "PLTE", p);
    if (options.trns) |t| try appendChunk(gpa, &out, "tRNS", t);

    const compressed = try zlibStored(gpa, options.filtered);
    defer gpa.free(compressed);
    try appendChunk(gpa, &out, "IDAT", compressed);

    try appendChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

test "decodes a Paeth-filtered rgba image" {
    var img = try decode(testing.allocator, &png_rgba_paeth, .{});
    defer img.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 4), img.width);
    try testing.expectEqual(@as(u32, 4), img.height);
    try testing.expectEqualSlices(u8, &expected_rgba, img.pixels);
}

test "the filter is not visible in the result" {
    // The same image, Average-filtered instead of Paeth-filtered. Filters are a
    // compression detail; two encodings of one image must decode to the same pixels.
    var paeth_img = try decode(testing.allocator, &png_rgba_paeth, .{});
    defer paeth_img.deinit(testing.allocator);
    var average_img = try decode(testing.allocator, &png_rgba_average, .{});
    defer average_img.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, paeth_img.pixels, average_img.pixels);
}

test "decodes a palette image and applies tRNS, defaulting the tail to opaque" {
    var img = try decode(testing.allocator, &png_palette_trns, .{});
    defer img.deinit(testing.allocator);

    // Palette: red, green, blue, yellow. tRNS covers only the first two entries.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0 }, img.pixel(0, 0));
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 128 }, img.pixel(1, 0));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.pixel(2, 0));
    try testing.expectEqualSlices(u8, &.{ 255, 255, 0, 255 }, img.pixel(0, 1));
}

test "a valid PNG outside the subset is unsupported, not invalid" {
    // The distinction matters to whoever wrote the file: one means "fix your exporter",
    // the other means "your file is broken".
    try testing.expectError(
        error.UnsupportedImage,
        decode(testing.allocator, &png_grayscale_16bit, .{}),
    );
    try testing.expectError(
        error.UnsupportedImage,
        decode(testing.allocator, &png_interlaced, .{}),
    );
}

test "grayscale and grayscale+alpha expand to rgba" {
    const gpa = testing.allocator;

    // 2x1 greyscale, unfiltered rows.
    const gray = try buildPng(gpa, .{
        .width = 2,
        .height = 1,
        .color_type = 0,
        .filtered = &.{ 0, 10, 200 },
    });
    defer gpa.free(gray);

    var gray_img = try decode(gpa, gray, .{});
    defer gray_img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 10, 10, 10, 255 }, gray_img.pixel(0, 0));
    try testing.expectEqualSlices(u8, &.{ 200, 200, 200, 255 }, gray_img.pixel(1, 0));

    const gray_alpha = try buildPng(gpa, .{
        .width = 2,
        .height = 1,
        .color_type = 4,
        .filtered = &.{ 0, 10, 64, 200, 255 },
    });
    defer gpa.free(gray_alpha);

    var ga_img = try decode(gpa, gray_alpha, .{});
    defer ga_img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 10, 10, 10, 64 }, ga_img.pixel(0, 0));
    try testing.expectEqualSlices(u8, &.{ 200, 200, 200, 255 }, ga_img.pixel(1, 0));
}

test "a colour key in tRNS makes exactly that colour transparent" {
    const gpa = testing.allocator;
    const bytes = try buildPng(gpa, .{
        .width = 2,
        .height = 1,
        .color_type = 2,
        .filtered = &.{ 0, 1, 2, 3, 9, 9, 9 },
        // Two-byte samples even at depth 8; the value is in the low byte.
        .trns = &.{ 0, 1, 0, 2, 0, 3 },
    });
    defer gpa.free(bytes);

    var img = try decode(gpa, bytes, .{});
    defer img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0 }, img.pixel(0, 0));
    try testing.expectEqualSlices(u8, &.{ 9, 9, 9, 255 }, img.pixel(1, 0));
}

test "unknown ancillary chunks are skipped and unknown critical chunks are refused" {
    const gpa = testing.allocator;

    const base = try buildPng(gpa, .{
        .width = 1,
        .height = 1,
        .color_type = 6,
        .filtered = &.{ 0, 1, 2, 3, 4 },
    });
    defer gpa.free(base);

    // Splice a chunk in after IHDR, which ends 8 + 25 bytes in.
    const insert_at = signature.len + 25;
    for ([_]struct { kind: *const [4]u8, ok: bool }{
        .{ .kind = "tEXt", .ok = true }, // ancillary: lowercase first letter
        .{ .kind = "zTXt", .ok = true },
        .{ .kind = "ZZZZ", .ok = false }, // critical: uppercase, and we do not know it
    }) |case| {
        var spliced: std.ArrayList(u8) = .empty;
        defer spliced.deinit(gpa);
        try spliced.appendSlice(gpa, base[0..insert_at]);
        try appendChunk(gpa, &spliced, case.kind, "hello");
        try spliced.appendSlice(gpa, base[insert_at..]);

        if (case.ok) {
            var img = try decode(gpa, spliced.items, .{});
            defer img.deinit(gpa);
            try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, img.pixel(0, 0));
        } else {
            try testing.expectError(error.UnsupportedImage, decode(gpa, spliced.items, .{}));
        }
    }
}

test "limits are applied to the header, before anything is allocated" {
    const gpa = testing.allocator;
    // A header claiming 4096x4096 with a one-byte IDAT. If the limit were checked after
    // allocating from the header, this would ask for 64 MiB on the strength of a lie.
    const bytes = try buildPng(gpa, .{
        .width = 4096,
        .height = 4096,
        .color_type = 6,
        .filtered = &.{0},
    });
    defer gpa.free(bytes);

    try testing.expectError(
        error.ImageTooLarge,
        decode(gpa, bytes, .{ .max_dimension = 1024 }),
    );
    try testing.expectError(
        error.ImageTooLarge,
        decode(gpa, bytes, .{ .max_pixels = 1024 * 1024 }),
    );
}

test "a malformed file is refused rather than tolerated" {
    const gpa = testing.allocator;
    const valid = try buildPng(gpa, .{
        .width = 2,
        .height = 2,
        .color_type = 6,
        .filtered = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 9, 10, 11, 12, 13, 14, 15, 16 },
    });
    defer gpa.free(valid);

    // The valid original decodes, so every failure below is caused by the mutation.
    {
        var img = try decode(gpa, valid, .{});
        defer img.deinit(gpa);
        try testing.expectEqual(@as(u32, 2), img.width);
    }

    // A flipped bit anywhere in the IDAT payload must fail the chunk CRC.
    {
        const corrupt = try gpa.dupe(u8, valid);
        defer gpa.free(corrupt);
        corrupt[corrupt.len - 10] ^= 0xFF;
        try testing.expectError(error.InvalidImage, decode(gpa, corrupt, .{}));
    }

    // Truncation, at every length: none of them may read out of bounds or succeed.
    {
        var cut: usize = 0;
        while (cut < valid.len) : (cut += 1) {
            try testing.expectError(error.InvalidImage, decode(gpa, valid[0..cut], .{}));
        }
    }

    // A signature that is one byte wrong is not a PNG.
    {
        const corrupt = try gpa.dupe(u8, valid);
        defer gpa.free(corrupt);
        corrupt[1] = 'X';
        try testing.expectError(error.InvalidImage, decode(gpa, corrupt, .{}));
        try testing.expect(!isPng(corrupt));
    }
}

test "a palette index outside the palette is refused" {
    const gpa = testing.allocator;
    const bytes = try buildPng(gpa, .{
        .width = 2,
        .height = 1,
        .color_type = 3,
        // Index 7 into a two-entry palette. This is the classic decoder exploit.
        .filtered = &.{ 0, 0, 7 },
        .palette = &.{ 255, 0, 0, 0, 255, 0 },
    });
    defer gpa.free(bytes);

    try testing.expectError(error.InvalidImage, decode(gpa, bytes, .{}));
}

test "structural rules are enforced, not assumed" {
    const gpa = testing.allocator;

    // A palette image with no PLTE.
    {
        const bytes = try buildPng(gpa, .{
            .width = 1,
            .height = 1,
            .color_type = 3,
            .filtered = &.{ 0, 0 },
        });
        defer gpa.free(bytes);
        try testing.expectError(error.InvalidImage, decode(gpa, bytes, .{}));
    }

    // tRNS on an image that already carries alpha.
    {
        const bytes = try buildPng(gpa, .{
            .width = 1,
            .height = 1,
            .color_type = 6,
            .filtered = &.{ 0, 1, 2, 3, 4 },
            .trns = &.{ 0, 1 },
        });
        defer gpa.free(bytes);
        try testing.expectError(error.InvalidImage, decode(gpa, bytes, .{}));
    }

    // Zero width.
    {
        const bytes = try buildPng(gpa, .{
            .width = 0,
            .height = 1,
            .color_type = 6,
            .filtered = &.{0},
        });
        defer gpa.free(bytes);
        try testing.expectError(error.InvalidImage, decode(gpa, bytes, .{}));
    }

    // An undefined compression method, which no real PNG has.
    {
        var bytes = try buildPng(gpa, .{
            .width = 1,
            .height = 1,
            .color_type = 6,
            .filtered = &.{ 0, 1, 2, 3, 4 },
        });
        defer gpa.free(bytes);
        // IHDR data begins 8 + 8 bytes in; compression method is its eleventh byte. The
        // CRC has to be recomputed, or this would be caught for the wrong reason.
        const ihdr = bytes[signature.len + 8 ..][0..13];
        ihdr[10] = 1;
        var crc: std.hash.Crc32 = .init();
        crc.update(bytes[signature.len + 4 ..][0..17]);
        std.mem.writeInt(u32, bytes[signature.len + 21 ..][0..4], crc.final(), .big);
        try testing.expectError(error.InvalidImage, decode(gpa, bytes, .{}));
    }
}

test "the compressed stream must be exactly as long as the header implies" {
    const gpa = testing.allocator;

    // 2x1 rgba needs 1 + 8 bytes; give it 1 + 4, then 1 + 12.
    for ([_][]const u8{
        &.{ 0, 1, 2, 3, 4 },
        &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    }) |filtered| {
        const bytes = try buildPng(gpa, .{
            .width = 2,
            .height = 1,
            .color_type = 6,
            .filtered = filtered,
        });
        defer gpa.free(bytes);
        try testing.expectError(error.InvalidImage, decode(gpa, bytes, .{}));
    }
}

test "an unknown filter type is refused" {
    const gpa = testing.allocator;
    const bytes = try buildPng(gpa, .{
        .width = 1,
        .height = 1,
        .color_type = 6,
        .filtered = &.{ 5, 1, 2, 3, 4 },
    });
    defer gpa.free(bytes);
    try testing.expectError(error.InvalidImage, decode(gpa, bytes, .{}));
}

test "the paeth predictor picks the nearest of left, above and upper-left" {
    // Values from the PNG specification's description of the predictor.
    try testing.expectEqual(@as(u8, 10), paeth(10, 20, 30)); // p = 0,  a is nearest
    try testing.expectEqual(@as(u8, 20), paeth(10, 20, 5)); // p = 25, b is nearest
    try testing.expectEqual(@as(u8, 200), paeth(200, 5, 8)); // a wins on the tie rule
    try testing.expectEqual(@as(u8, 0), paeth(0, 0, 0));
    // Ties resolve toward a, then b: the order is part of the format, not a preference.
    try testing.expectEqual(@as(u8, 4), paeth(4, 4, 4));
}
