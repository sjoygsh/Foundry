//! WAV decoding, written rather than depended on (ADR-0023).
//!
//! Beside `png.zig`, and for its reasons (ADR-0018): **a sound is a stranger's file**. A mod
//! ships a `.wav` and this code parses it, so the untrusted path is Zig, where an index is
//! checked and a malformed file produces an error rather than undefined behaviour.
//!
//! There is a second reason here that PNG did not have. The samples this produces are read
//! by the device thread, inside a callback that cannot allocate, cannot lock and cannot
//! fail (`docs/design/audio.md` §3). Everything that could go wrong about a sound has to
//! go wrong *here*, on a thread that is allowed to be slow and allowed to return an error.
//!
//! **The supported subset is stated and everything outside it is refused by name**: PCM at
//! 8, 16, 24 and 32 bits, IEEE float at 32, one or two channels, `WAVE_FORMAT_EXTENSIBLE`
//! resolved to whichever of those its sub-format names. ADPCM, µ-law and A-law get a
//! sentence naming the format they are, because a mod author deserves one rather than a
//! noise.
//!
//! Design: `docs/design/audio.md` §6.

const std = @import("std");
const core = @import("core");

const Sound = @import("sound.zig").Sound;

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.asset);

pub const DecodeError = error{
    /// Not a WAV, or a WAV that violates the format: bad signature, truncation, a chunk
    /// size running past the end, a `data` length that is not a whole number of frames.
    InvalidSound,
    /// A valid WAV this decoder does not handle. Distinct from `InvalidSound` because the
    /// file is fine and the answer for the author is different — transcode, do not debug.
    UnsupportedSound,
    /// Longer than `Limits` allows.
    SoundTooLarge,
    OutOfMemory,
};

/// Bounds applied **before** anything is allocated from a size the file supplied.
pub const Limits = struct {
    /// Frames, not samples, so the bound is the same for mono and stereo. 2^24 frames is
    /// about five and a half minutes at 48 kHz, and 134 MiB once expanded to stereo
    /// `f32` — which is already past the point where a sound should be streamed rather
    /// than decoded whole (`audio.md` §11).
    max_frames: u64 = 1 << 24,
    /// Above this a file is refused rather than resampled. Well past every real device;
    /// a rate of a few million is a corrupt header wearing a plausible field.
    max_sample_rate: u32 = 768_000,
};

/// Whether `bytes` begins with a RIFF/WAVE container. Cheap, and the basis for dispatching
/// between decoders once there is more than one.
pub fn isWav(bytes: []const u8) bool {
    return bytes.len >= 12 and
        std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WAVE");
}

/// The `wFormatTag` values this decoder can name. Not exhaustive — the point of the
/// enumeration is that a refusal says *what the file is*, and everything else is refused
/// by number.
const Format = enum(u16) {
    pcm = 1,
    adpcm_ms = 2,
    ieee_float = 3,
    alaw = 6,
    mulaw = 7,
    adpcm_ima = 17,
    adpcm_gsm = 49,
    mpeg = 80,
    /// The tag is a lie and the real one is inside the sub-format GUID.
    extensible = 0xFFFE,
    _,

    fn name(self: Format) []const u8 {
        return switch (self) {
            .pcm => "PCM",
            .adpcm_ms => "Microsoft ADPCM",
            .ieee_float => "IEEE float",
            .alaw => "A-law",
            .mulaw => "mu-law",
            .adpcm_ima => "IMA ADPCM",
            .adpcm_gsm => "GSM 6.10",
            .mpeg => "MPEG",
            .extensible => "WAVE_FORMAT_EXTENSIBLE",
            _ => "unrecognised",
        };
    }
};

/// What the `fmt ` chunk said, after it has been checked.
const Fmt = struct {
    format: Format,
    channels: u8,
    sample_rate: u32,
    bits: u16,

    fn bytesPerSample(self: Fmt) usize {
        return self.bits / 8;
    }
};

const Chunk = struct {
    id: [4]u8,
    data: []const u8,
};

const ChunkIterator = struct {
    bytes: []const u8,
    pos: usize,

    fn next(self: *ChunkIterator) DecodeError!?Chunk {
        if (self.pos >= self.bytes.len) return null;
        // An id and a size, then that many bytes. Fewer than eight left means the file
        // claims another chunk and has not got one, which is truncation.
        if (self.bytes.len - self.pos < 8) return error.InvalidSound;

        const id = self.bytes[self.pos..][0..4].*;
        const size = std.mem.readInt(u32, self.bytes[self.pos + 4 ..][0..4], .little);

        const data_start = self.pos + 8;
        // Checked against what is left rather than against the sum, so the addition
        // below cannot overflow whatever the file claims.
        if (size > self.bytes.len - data_start) return error.InvalidSound;
        const data_end = data_start + size;

        // Chunks are padded to an even length and the pad byte is not part of the data.
        // The last chunk in a file is often written without it, so a pad that would run
        // past the end ends the walk instead of failing it.
        self.pos = @min(data_end + (size & 1), self.bytes.len);
        return .{ .id = id, .data = self.bytes[data_start..data_end] };
    }
};

/// Decode `bytes` into a `Sound` owned by `gpa`.
///
/// `bytes` is borrowed and may be freed as soon as this returns.
pub fn decode(gpa: Allocator, bytes: []const u8, limits: Limits) DecodeError!Sound {
    if (!isWav(bytes)) return error.InvalidSound;

    // The RIFF chunk's own size field is not trusted for bounds. It is wrong in a great
    // many real files, every sub-chunk is separately bounded against the buffer, and
    // believing it would refuse sounds that decode perfectly well.
    var info: ?Fmt = null;
    var payload: ?[]const u8 = null;

    var chunks: ChunkIterator = .{ .bytes = bytes, .pos = 12 };
    while (try chunks.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.id, "fmt ")) {
            if (info != null) return error.InvalidSound;
            info = try parseFmt(chunk.data, limits);
        } else if (std.mem.eql(u8, &chunk.id, "data")) {
            if (payload != null) return error.InvalidSound;
            // Ordering, enforced rather than assumed: `data` cannot be interpreted
            // without the `fmt ` that says what its bytes mean.
            if (info == null) return error.InvalidSound;
            payload = chunk.data;
        }
        // Everything else — `LIST`, `fact`, `cue `, an editor's private chunk — is
        // skipped by its declared size, which the iterator has already checked.
    }

    const fmt = info orelse return error.InvalidSound;
    const data = payload orelse return error.InvalidSound;

    const frame_bytes = fmt.bytesPerSample() * fmt.channels;
    if (data.len % frame_bytes != 0) return error.InvalidSound;
    const frames = data.len / frame_bytes;

    // A sound with no frames is refused rather than carried. It cannot be heard, and a
    // looping voice wraps its cursor by the source length — so admitting one would put a
    // division by zero in the one place that must never branch on a special case.
    if (frames == 0) return error.InvalidSound;
    if (frames > limits.max_frames) {
        log.warn("wav: {d} frames exceeds the {d}-frame limit", .{ frames, limits.max_frames });
        return error.SoundTooLarge;
    }

    var sound = try Sound.alloc(gpa, frames, fmt.channels, fmt.sample_rate);
    errdefer sound.deinit(gpa);
    try convert(fmt, data, sound.samples);
    return sound;
}

fn parseFmt(chunk: []const u8, limits: Limits) DecodeError!Fmt {
    // 16 bytes is the whole of the original `fmt `; the extension after it is optional
    // for everything except EXTENSIBLE.
    if (chunk.len < 16) return error.InvalidSound;

    var format: Format = @enumFromInt(std.mem.readInt(u16, chunk[0..2], .little));
    const channels = std.mem.readInt(u16, chunk[2..4], .little);
    const sample_rate = std.mem.readInt(u32, chunk[4..8], .little);
    // `nAvgBytesPerSec` at 8 and `nBlockAlign` at 12 are derivable from the rest and are
    // deliberately not read: nothing below needs them, so a file that gets them wrong
    // still decodes correctly rather than being refused over a redundant field.
    const bits = std.mem.readInt(u16, chunk[14..16], .little);

    if (format == .extensible) {
        // The real tag is the first two bytes of the 16-byte sub-format GUID, which sits
        // eight bytes into the 22-byte extension: 16 + 2 (cbSize) + 2 + 4, then the GUID.
        if (chunk.len < 40) return error.InvalidSound;
        if (std.mem.readInt(u16, chunk[16..18], .little) < 22) return error.InvalidSound;
        format = @enumFromInt(std.mem.readInt(u16, chunk[24..26], .little));
        // A file whose sub-format is itself EXTENSIBLE is nonsense rather than a format
        // we do not support, and following it would be a loop.
        if (format == .extensible) return error.InvalidSound;
    }

    // **The format is asked first**, and the order is load-bearing rather than tidy. A
    // 4-bit sample is nonsense for PCM and correct for ADPCM, so a decoder that checks the
    // depth first tells the author their file is corrupt when it is merely compressed.
    switch (format) {
        .pcm, .ieee_float => {},
        else => {
            log.warn(
                "wav: format {s} (tag {d}) is not supported; PCM and IEEE float are",
                .{ format.name(), @intFromEnum(format) },
            );
            return error.UnsupportedSound;
        },
    }

    if (channels == 0) return error.InvalidSound;
    if (channels > 2) {
        log.warn("wav: {d} channels is not supported; mono and stereo are", .{channels});
        return error.UnsupportedSound;
    }

    if (sample_rate == 0) return error.InvalidSound;
    if (sample_rate > limits.max_sample_rate) {
        log.warn(
            "wav: {d} Hz is above the {d} Hz limit",
            .{ sample_rate, limits.max_sample_rate },
        );
        return error.UnsupportedSound;
    }

    // Zero bits describes nothing at all, whatever the format; every other depth is a
    // depth this decoder does not have a conversion for.
    if (bits == 0) return error.InvalidSound;
    switch (format) {
        .pcm => switch (bits) {
            8, 16, 24, 32 => {},
            else => {
                log.warn("wav: {d}-bit PCM is not supported; 8, 16, 24 and 32 are", .{bits});
                return error.UnsupportedSound;
            },
        },
        .ieee_float => switch (bits) {
            32 => {},
            else => {
                log.warn("wav: {d}-bit float is not supported; 32 is", .{bits});
                return error.UnsupportedSound;
            },
        },
        else => unreachable,
    }

    return .{
        .format = format,
        .channels = @intCast(channels),
        .sample_rate = sample_rate,
        .bits = bits,
    };
}

/// Expand `data` into `out`, which is exactly the right length.
///
/// The scale factors are the full range of the source type, so a full-scale negative
/// sample becomes exactly -1.0 and a full-scale positive one falls just inside +1.0. That
/// asymmetry is the two's-complement range, not a rounding choice, and dividing by the
/// positive maximum instead would let a full-scale file clip.
fn convert(fmt: Fmt, data: []const u8, out: []f32) DecodeError!void {
    const stride = fmt.bytesPerSample();
    std.debug.assert(out.len * stride == data.len);

    switch (fmt.format) {
        .pcm => switch (fmt.bits) {
            8 => for (out, 0..) |*sample, i| {
                // The only unsigned depth in the format, centred on 128.
                sample.* = (@as(f32, @floatFromInt(data[i])) - 128.0) / 128.0;
            },
            16 => for (out, 0..) |*sample, i| {
                const raw = std.mem.readInt(i16, data[i * 2 ..][0..2], .little);
                sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
            },
            24 => for (out, 0..) |*sample, i| {
                const raw = std.mem.readInt(i24, data[i * 3 ..][0..3], .little);
                sample.* = @as(f32, @floatFromInt(raw)) / 8388608.0;
            },
            32 => for (out, 0..) |*sample, i| {
                const raw = std.mem.readInt(i32, data[i * 4 ..][0..4], .little);
                // Widened first: an `i32` has more significant bits than an `f32` has
                // mantissa, so the division is done where the rounding is defined and
                // narrowed once, rather than rounding twice.
                sample.* = @floatCast(@as(f64, @floatFromInt(raw)) / 2147483648.0);
            },
            else => unreachable,
        },
        .ieee_float => for (out, 0..) |*sample, i| {
            const raw = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
            const value: f32 = @bitCast(raw);
            // The one place this decoder is stricter than the image path, which prefers a
            // wrong-looking sprite to a missing one. A NaN reaching the mixer propagates
            // through the accumulator and silences everything for the rest of the
            // session — the least diagnosable failure available (`audio.md` §6).
            if (!std.math.isFinite(value)) {
                log.warn("wav: a float sample is not finite", .{});
                return error.InvalidSound;
            }
            sample.* = value;
        },
        else => unreachable,
    }
}

const testing = std.testing;

const BuildOptions = struct {
    format: u16 = 1,
    channels: u16 = 1,
    sample_rate: u32 = 48_000,
    bits: u16 = 16,
    /// The `data` chunk's bytes, exactly as they should appear.
    data: []const u8,
    /// Written verbatim after `WAVE` and before `fmt `.
    prefix_chunks: []const u8 = &.{},
    /// Written verbatim after `data`.
    suffix_chunks: []const u8 = &.{},
    /// When set, the sub-format GUID's tag and an EXTENSIBLE `fmt ` chunk.
    extensible_sub_format: ?u16 = null,
    /// Overrides `cbSize`, to build an extension that lies about its own length.
    extension_size: ?u16 = null,
};

fn buildWav(gpa: Allocator, options: BuildOptions) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "RIFF");
    try out.appendSlice(gpa, &.{ 0, 0, 0, 0 }); // Patched at the end.
    try out.appendSlice(gpa, "WAVE");
    try out.appendSlice(gpa, options.prefix_chunks);

    var fmt: std.ArrayList(u8) = .empty;
    defer fmt.deinit(gpa);
    const tag: u16 = if (options.extensible_sub_format != null) 0xFFFE else options.format;
    const block_align: u16 = @intCast(options.channels * (options.bits / 8));
    try appendInt(gpa, &fmt, u16, tag);
    try appendInt(gpa, &fmt, u16, options.channels);
    try appendInt(gpa, &fmt, u32, options.sample_rate);
    try appendInt(gpa, &fmt, u32, options.sample_rate * block_align);
    try appendInt(gpa, &fmt, u16, block_align);
    try appendInt(gpa, &fmt, u16, options.bits);
    if (options.extensible_sub_format) |sub| {
        try appendInt(gpa, &fmt, u16, options.extension_size orelse 22);
        try appendInt(gpa, &fmt, u16, options.bits); // wValidBitsPerSample
        try appendInt(gpa, &fmt, u32, 0); // dwChannelMask
        try appendInt(gpa, &fmt, u16, sub);
        // The rest of the KSDATAFORMAT_SUBTYPE GUID, which nothing reads.
        try fmt.appendSlice(gpa, &[_]u8{0} ** 14);
    }
    try appendChunk(gpa, &out, "fmt ", fmt.items);
    try appendChunk(gpa, &out, "data", options.data);
    try out.appendSlice(gpa, options.suffix_chunks);

    std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len - 8), .little);
    return out.toOwnedSlice(gpa);
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

fn appendChunk(gpa: Allocator, out: *std.ArrayList(u8), id: *const [4]u8, data: []const u8) !void {
    try out.appendSlice(gpa, id);
    try appendInt(gpa, out, u32, @intCast(data.len));
    try out.appendSlice(gpa, data);
    if (data.len % 2 == 1) try out.append(gpa, 0);
}

/// Four stereo frames of 16-bit PCM: full-scale negative, silence, half, full-scale
/// positive, with the right channel one step behind the left.
const pcm16_stereo = [_]u8{
    0x00, 0x80, 0x00, 0x00, // -1.0, 0.0
    0x00, 0x40, 0x00, 0xC0, // 0.5,  -0.5
    0xFF, 0x7F, 0x01, 0x80, // ~1.0, ~-1.0
    0x00, 0x00, 0x00, 0x40, // 0.0,  0.5
};

test "decodes 16-bit stereo pcm, exactly" {
    const gpa = testing.allocator;
    const bytes = try buildWav(gpa, .{ .channels = 2, .data = &pcm16_stereo });
    defer gpa.free(bytes);

    var sound = try decode(gpa, bytes, .{});
    defer sound.deinit(gpa);

    try testing.expectEqual(@as(u8, 2), sound.channels);
    try testing.expectEqual(@as(u32, 48_000), sound.sample_rate);
    try testing.expectEqual(@as(usize, 4), sound.frameCount());

    // Exact, not approximate: every one of these is representable in `f32`, and an
    // epsilon here would hide a scale factor that is off by one.
    try testing.expectEqual(@as(f32, -1.0), sound.frame(0)[0]);
    try testing.expectEqual(@as(f32, 0.0), sound.frame(0)[1]);
    try testing.expectEqual(@as(f32, 0.5), sound.frame(1)[0]);
    try testing.expectEqual(@as(f32, -0.5), sound.frame(1)[1]);
    try testing.expectEqual(@as(f32, 32767.0 / 32768.0), sound.frame(2)[0]);
    try testing.expectEqual(@as(f32, 0.5), sound.frame(3)[1]);
}

test "every accepted depth reaches the same values" {
    const gpa = testing.allocator;

    // Silence, full-scale negative, and half positive, in each source encoding.
    const cases = [_]struct { bits: u16, format: u16 = 1, data: []const u8 }{
        .{ .bits = 8, .data = &.{ 0x80, 0x00, 0xC0 } },
        .{ .bits = 16, .data = &.{ 0x00, 0x00, 0x00, 0x80, 0x00, 0x40 } },
        .{ .bits = 24, .data = &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x40 } },
        .{ .bits = 32, .data = &.{
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x80,
            0x00, 0x00, 0x00, 0x40,
        } },
        .{
            .bits = 32,
            .format = 3,
            .data = &.{
                0x00, 0x00, 0x00, 0x00, // 0.0
                0x00, 0x00, 0x80, 0xBF, // -1.0
                0x00, 0x00, 0x00, 0x3F, // 0.5
            },
        },
    };

    for (cases) |case| {
        const bytes = try buildWav(gpa, .{
            .bits = case.bits,
            .format = case.format,
            .data = case.data,
        });
        defer gpa.free(bytes);

        var sound = try decode(gpa, bytes, .{});
        defer sound.deinit(gpa);

        try testing.expectEqual(@as(usize, 3), sound.frameCount());
        try testing.expectEqual(@as(f32, 0.0), sound.samples[0]);
        try testing.expectEqual(@as(f32, -1.0), sound.samples[1]);
        // 8-bit has no exact 0.5: its centre is 128 and half of 128 steps is 0x C0,
        // which is exactly 0.5. Every other depth is exact for the same reason.
        try testing.expectEqual(@as(f32, 0.5), sound.samples[2]);
    }
}

test "8-bit is unsigned and centred on 128" {
    const gpa = testing.allocator;
    const bytes = try buildWav(gpa, .{ .bits = 8, .data = &.{ 0x00, 0x80, 0xFF } });
    defer gpa.free(bytes);

    var sound = try decode(gpa, bytes, .{});
    defer sound.deinit(gpa);

    try testing.expectEqual(@as(f32, -1.0), sound.samples[0]);
    try testing.expectEqual(@as(f32, 0.0), sound.samples[1]);
    try testing.expectEqual(@as(f32, 127.0 / 128.0), sound.samples[2]);
}

test "24-bit is sign-extended from three bytes" {
    const gpa = testing.allocator;
    const bytes = try buildWav(gpa, .{
        .bits = 24,
        // -1 and +1 as 24-bit little-endian, then full-scale negative.
        .data = &.{ 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00, 0x00, 0x80 },
    });
    defer gpa.free(bytes);

    var sound = try decode(gpa, bytes, .{});
    defer sound.deinit(gpa);

    // A decoder that read three bytes as unsigned would make the first of these +1.0.
    try testing.expectEqual(@as(f32, -1.0 / 8388608.0), sound.samples[0]);
    try testing.expectEqual(@as(f32, 1.0 / 8388608.0), sound.samples[1]);
    try testing.expectEqual(@as(f32, -1.0), sound.samples[2]);
}

test "extensible resolves to its sub-format" {
    const gpa = testing.allocator;

    const pcm = try buildWav(gpa, .{ .extensible_sub_format = 1, .data = &.{ 0x00, 0x40 } });
    defer gpa.free(pcm);
    var sound = try decode(gpa, pcm, .{});
    defer sound.deinit(gpa);
    try testing.expectEqual(@as(f32, 0.5), sound.samples[0]);

    // And an unsupported sub-format is refused as what it really is, not as EXTENSIBLE.
    const mulaw = try buildWav(gpa, .{ .extensible_sub_format = 7, .data = &.{ 0x00, 0x40 } });
    defer gpa.free(mulaw);
    try testing.expectError(error.UnsupportedSound, decode(gpa, mulaw, .{}));

    // A sub-format of EXTENSIBLE is nonsense rather than an unsupported format.
    const recursive = try buildWav(gpa, .{ .extensible_sub_format = 0xFFFE, .data = &.{ 0x00, 0x40 } });
    defer gpa.free(recursive);
    try testing.expectError(error.InvalidSound, decode(gpa, recursive, .{}));

    // An extension that claims to be shorter than the GUID it must contain.
    const stunted = try buildWav(gpa, .{
        .extensible_sub_format = 1,
        .extension_size = 6,
        .data = &.{ 0x00, 0x40 },
    });
    defer gpa.free(stunted);
    try testing.expectError(error.InvalidSound, decode(gpa, stunted, .{}));
}

test "unknown chunks are skipped, on either side of the ones that matter" {
    const gpa = testing.allocator;

    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(gpa);
    try appendChunk(gpa, &prefix, "LIST", "INFOwhatever");
    // An odd length, so the pad byte has to be accounted for or `fmt ` is misread.
    try appendChunk(gpa, &prefix, "junk", "odd");

    var suffix: std.ArrayList(u8) = .empty;
    defer suffix.deinit(gpa);
    try appendChunk(gpa, &suffix, "cue ", &.{ 0, 0, 0, 0 });

    const bytes = try buildWav(gpa, .{
        .channels = 2,
        .data = &pcm16_stereo,
        .prefix_chunks = prefix.items,
        .suffix_chunks = suffix.items,
    });
    defer gpa.free(bytes);

    var sound = try decode(gpa, bytes, .{});
    defer sound.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), sound.frameCount());
    try testing.expectEqual(@as(f32, -1.0), sound.samples[0]);
}

test "a final odd-sized chunk without its pad byte still decodes" {
    const gpa = testing.allocator;
    // Three frames of 8-bit mono: an odd `data` length, and the last chunk in the file.
    var bytes = try buildWav(gpa, .{ .bits = 8, .data = &.{ 0x80, 0xC0, 0x40 } });
    defer gpa.free(bytes);

    // Writers that omit the trailing pad are common enough that refusing them would be
    // refusing real files.
    const trimmed = bytes[0 .. bytes.len - 1];
    var sound = try decode(gpa, trimmed, .{});
    defer sound.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), sound.frameCount());
}

test "a valid wav outside the subset is unsupported, not invalid" {
    const gpa = testing.allocator;

    const cases = [_]BuildOptions{
        .{ .format = 7, .bits = 8, .data = &.{ 0x00, 0x00 } }, // mu-law
        .{ .format = 6, .bits = 8, .data = &.{ 0x00, 0x00 } }, // A-law
        .{ .format = 17, .bits = 4, .data = &.{ 0x00, 0x00 } }, // IMA ADPCM
        .{ .format = 3, .bits = 64, .data = &[_]u8{0} ** 8 }, // 64-bit float
        .{ .bits = 12, .data = &.{ 0x00, 0x00, 0x00 } }, // 12-bit PCM
        .{ .channels = 6, .data = &[_]u8{0} ** 12 }, // 5.1
        .{ .sample_rate = 3_000_000, .data = &.{ 0x00, 0x00 } },
    };

    for (cases, 0..) |case, i| {
        const bytes = try buildWav(gpa, case);
        defer gpa.free(bytes);
        testing.expectError(error.UnsupportedSound, decode(gpa, bytes, .{})) catch |err| {
            std.debug.print("case {d} did not report UnsupportedSound\n", .{i});
            return err;
        };
    }
}

test "a malformed file is refused rather than tolerated" {
    const gpa = testing.allocator;
    const valid = try buildWav(gpa, .{ .channels = 2, .data = &pcm16_stereo });
    defer gpa.free(valid);
    // The baseline decodes, so every mutation below is the only thing that is wrong.
    var baseline = try decode(gpa, valid, .{});
    baseline.deinit(gpa);

    // Not a RIFF/WAVE container at all.
    try testing.expectError(error.InvalidSound, decode(gpa, "", .{}));
    try testing.expectError(error.InvalidSound, decode(gpa, valid[0..8], .{}));
    {
        const wrong = try gpa.dupe(u8, valid);
        defer gpa.free(wrong);
        @memcpy(wrong[8..12], "AVI ");
        try testing.expectError(error.InvalidSound, decode(gpa, wrong, .{}));
    }

    // Truncated: a chunk header that runs off the end.
    try testing.expectError(error.InvalidSound, decode(gpa, valid[0 .. valid.len - 20], .{}));

    // A chunk size that claims more than the file holds.
    {
        const lying = try gpa.dupe(u8, valid);
        defer gpa.free(lying);
        const data_at = std.mem.indexOf(u8, lying, "data").?;
        std.mem.writeInt(u32, lying[data_at + 4 ..][0..4], 0xFFFF_FFFF, .little);
        try testing.expectError(error.InvalidSound, decode(gpa, lying, .{}));
    }

    // No `fmt `, and no `data`.
    {
        const no_fmt = try gpa.dupe(u8, valid);
        defer gpa.free(no_fmt);
        @memcpy(no_fmt[std.mem.indexOf(u8, no_fmt, "fmt ").?..][0..4], "junk");
        try testing.expectError(error.InvalidSound, decode(gpa, no_fmt, .{}));

        const no_data = try gpa.dupe(u8, valid);
        defer gpa.free(no_data);
        @memcpy(no_data[std.mem.indexOf(u8, no_data, "data").?..][0..4], "junk");
        try testing.expectError(error.InvalidSound, decode(gpa, no_data, .{}));
    }

    // A `data` length that is not a whole number of frames: four stereo 16-bit frames
    // are sixteen bytes, and fourteen is not a frame boundary.
    {
        const partial = try buildWav(gpa, .{ .channels = 2, .data = pcm16_stereo[0..14] });
        defer gpa.free(partial);
        try testing.expectError(error.InvalidSound, decode(gpa, partial, .{}));
    }

    // Zero channels, zero rate, zero bits: each a header that cannot describe anything.
    for ([_]BuildOptions{
        .{ .channels = 0, .data = &pcm16_stereo },
        .{ .sample_rate = 0, .data = &pcm16_stereo },
        .{ .bits = 0, .data = &pcm16_stereo },
    }) |case| {
        const bytes = try buildWav(gpa, case);
        defer gpa.free(bytes);
        try testing.expectError(error.InvalidSound, decode(gpa, bytes, .{}));
    }

    // A `fmt ` shorter than the sixteen bytes every WAV has.
    {
        var short: std.ArrayList(u8) = .empty;
        defer short.deinit(gpa);
        try short.appendSlice(gpa, "RIFF");
        try appendInt(gpa, &short, u32, 0);
        try short.appendSlice(gpa, "WAVE");
        try appendChunk(gpa, &short, "fmt ", &[_]u8{0} ** 12);
        try appendChunk(gpa, &short, "data", &pcm16_stereo);
        try testing.expectError(error.InvalidSound, decode(gpa, short.items, .{}));
    }
}

test "data before fmt is refused, because its bytes have no meaning yet" {
    const gpa = testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "RIFF");
    try appendInt(gpa, &out, u32, 0);
    try out.appendSlice(gpa, "WAVE");
    try appendChunk(gpa, &out, "data", &pcm16_stereo);

    var fmt: std.ArrayList(u8) = .empty;
    defer fmt.deinit(gpa);
    try appendInt(gpa, &fmt, u16, 1);
    try appendInt(gpa, &fmt, u16, 2);
    try appendInt(gpa, &fmt, u32, 48_000);
    try appendInt(gpa, &fmt, u32, 48_000 * 4);
    try appendInt(gpa, &fmt, u16, 4);
    try appendInt(gpa, &fmt, u16, 16);
    try appendChunk(gpa, &out, "fmt ", fmt.items);

    try testing.expectError(error.InvalidSound, decode(gpa, out.items, .{}));
}

test "an empty sound is refused rather than carried" {
    const gpa = testing.allocator;
    const bytes = try buildWav(gpa, .{ .data = "" });
    defer gpa.free(bytes);
    try testing.expectError(error.InvalidSound, decode(gpa, bytes, .{}));
}

test "the frame limit is applied before anything is allocated" {
    const gpa = testing.allocator;
    const bytes = try buildWav(gpa, .{ .channels = 2, .data = &pcm16_stereo });
    defer gpa.free(bytes);

    // An allocator that fails on its first request. If the limit were checked after the
    // allocation, this would report `OutOfMemory` — which is exactly the bug that lets a
    // header claiming four gigabytes cost four gigabytes.
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try testing.expectError(
        error.SoundTooLarge,
        decode(failing.allocator(), bytes, .{ .max_frames = 3 }),
    );
    try testing.expectEqual(@as(usize, 0), failing.allocations);

    // And the same file is fine when it fits.
    var sound = try decode(gpa, bytes, .{ .max_frames = 4 });
    defer sound.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), sound.frameCount());
}

test "a non-finite float sample refuses the file" {
    const gpa = testing.allocator;

    for ([_][4]u8{
        .{ 0x00, 0x00, 0xC0, 0x7F }, // NaN
        .{ 0x00, 0x00, 0x80, 0x7F }, // +inf
        .{ 0x00, 0x00, 0x80, 0xFF }, // -inf
    }) |bad| {
        var payload: [8]u8 = .{ 0x00, 0x00, 0x00, 0x3F } ++ [_]u8{0} ** 4;
        @memcpy(payload[4..8], &bad);

        const bytes = try buildWav(gpa, .{ .format = 3, .bits = 32, .data = &payload });
        defer gpa.free(bytes);
        // A NaN silences the whole mix from the moment it enters the accumulator, so it
        // is refused at the door rather than debugged from the symptom.
        try testing.expectError(error.InvalidSound, decode(gpa, bytes, .{}));
    }
}

test "isWav recognises the container and nothing else" {
    try testing.expect(isWav("RIFF\x00\x00\x00\x00WAVE"));
    try testing.expect(!isWav("RIFF\x00\x00\x00\x00AVI "));
    try testing.expect(!isWav("RIFF\x00\x00\x00"));
    try testing.expect(!isWav(""));
}
