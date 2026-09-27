//! Mip chains, built on the CPU from a decoded image, at load.
//!
//! **A pure function of the pixels and the colour space** (`docs/design/meshes.md` §4.2). The
//! renderer uploads what this returns; nothing here knows a GPU exists, and nothing here reads
//! a record. The loader decides *whether* a texture has a chain (`mipmaps`) and *what its bytes
//! mean* (`color_space`); this module only makes the chain those two answers describe.
//!
//! Why at load rather than in `fpack`: a build-time chain needs a second runtime texture format
//! beside PNG, with its own version, reader, writer and refusals. The trigger to move it is a
//! measured load time, which is also the trigger for compressed GPU formats, and both move
//! together when it fires (§4.2).
//!
//! Each level is a box filter of the one above:
//! - **Halving floors, and never reaches zero**, exactly as `rhi.Extent2D.mipLevel` defines a
//!   level's size, so a chain from here always matches the texture the RHI creates for it.
//! - **An odd dimension keeps its last row or column.** A 2×2 box over a five-texel row would
//!   read texels 0–3 and drop the fifth, so the last texel of the next level reads three: a
//!   one-texel line at an image's edge fades as it shrinks instead of vanishing. A dimension
//!   already at 1 reads its one row or column, which is the 2×2 box with it taken twice.
//! - **sRGB is filtered in linear light.** Averaging encoded bytes darkens every level, and
//!   visibly: black and white average to 128 encoded, which is 22% grey, not 50%.
//! - **Colour is weighted by alpha; alpha is a plain average.** A transparent texel's colour
//!   is whatever the exporter left there, often black, and weighting it in draws the dark halo
//!   alpha-tested foliage otherwise gets at a distance. A block with no coverage at all keeps
//!   the plain average of its colours, so it stays near its neighbours rather than turning black.
//!
//! **Deterministic** (I9): the transfer functions are tables computed at compile time, the
//! arithmetic is `f32` in a fixed order with no fast-math, and the only rounding is
//! round-to-nearest. The same image gives the same bytes on every host, and a test pins a hash.

const std = @import("std");
const image_mod = @import("image.zig");

const Allocator = std.mem.Allocator;
const Image = image_mod.Image;

/// What an image's bytes mean. The record's `color_space` field, parsed by the loader.
///
/// `srgb` is what every colour texture is, and what a PNG stores. `linear` is data that is not a
/// colour a person looks at — a normal map, a mask, a roughness texture (ADR-0048) — and it is
/// averaged as the numbers it is.
pub const ColorSpace = enum { srgb, linear };

/// One level's place in a chain's bytes.
pub const Level = struct {
    width: u32,
    height: u32,
    /// Byte offset of the level's first texel in `Chain.bytes`.
    offset: usize,

    pub fn byteSize(self: Level) usize {
        return @as(usize, self.width) * @as(usize, self.height) * Image.channels;
    }
};

/// Every level of an image, largest first, down to 1×1.
///
/// **One allocation, levels packed back to back**, each tightly as `Image` is: rows top to
/// bottom, no padding. Level 0 is a copy of the source, so the chain is self-contained and the
/// loader may free its decoded image before uploading. A 2D texture's chain is at most a third
/// larger than its image, and lives only as long as its upload.
pub const Chain = struct {
    bytes: []u8,
    levels: []Level,

    pub fn deinit(self: *Chain, gpa: Allocator) void {
        gpa.free(self.bytes);
        gpa.free(self.levels);
        self.* = undefined;
    }

    pub fn levelCount(self: Chain) u32 {
        return @intCast(self.levels.len);
    }

    /// Level `index` as an image **borrowing the chain's bytes**. Never `deinit` it.
    pub fn level(self: Chain, index: u32) Image {
        const l = self.levels[index];
        return .{
            .width = l.width,
            .height = l.height,
            .pixels = self.bytes[l.offset..][0..l.byteSize()],
        };
    }
};

/// How many levels a full chain of this size has: `floor(log2(max(width, height))) + 1`.
pub fn levelCount(width: u32, height: u32) u32 {
    std.debug.assert(width > 0 and height > 0);
    return 32 - @clz(@max(width, height));
}

/// The size of level `index`, halving with floor and never reaching zero. The same answer as
/// `rhi.Extent2D.mipLevel`, which `asset` cannot import (ADR-0007).
pub fn levelSize(width: u32, height: u32, index: u32) struct { width: u32, height: u32 } {
    const shift: u5 = @intCast(@min(index, 31));
    return .{ .width = @max(1, width >> shift), .height = @max(1, height >> shift) };
}

/// Builds the full chain of `source`, whose bytes mean what `space` says.
///
/// `source` is a decoded image, whose dimensions its decoder has already bounded; the only
/// failure left is memory. The total is at most 4/3 of the source plus one texel per level, and
/// is computed with overflow checks anyway, because a `usize` product of `u32`s is the pattern
/// that goes wrong on a 32-bit target.
pub fn generate(gpa: Allocator, source: Image, space: ColorSpace) Allocator.Error!Chain {
    std.debug.assert(source.width > 0 and source.height > 0);
    std.debug.assert(source.pixels.len == source.byteSize() and
        source.byteSize() == @as(usize, source.width) * source.height * Image.channels);

    const count = levelCount(source.width, source.height);
    const levels = try gpa.alloc(Level, count);
    errdefer gpa.free(levels);

    var total: usize = 0;
    for (levels, 0..) |*l, i| {
        const size = levelSize(source.width, source.height, @intCast(i));
        l.* = .{ .width = size.width, .height = size.height, .offset = total };
        total = std.math.add(usize, total, l.byteSize()) catch return error.OutOfMemory;
    }

    const bytes = try gpa.alloc(u8, total);
    var chain: Chain = .{ .bytes = bytes, .levels = levels };

    @memcpy(chain.level(0).pixels, source.pixels);
    var index: u32 = 1;
    while (index < count) : (index += 1) {
        downsample(chain.level(index - 1), chain.level(index), space);
    }
    return chain;
}

/// One level from the one above. `dst` is the floor-halved size of `src`.
fn downsample(src: Image, dst: Image, space: ColorSpace) void {
    const decode: *const [256]f32 = switch (space) {
        .srgb => &srgb_to_linear,
        .linear => &unorm_to_float,
    };

    var y: u32 = 0;
    while (y < dst.height) : (y += 1) {
        const rows = footprint(y, src.height, dst.height);
        var x: u32 = 0;
        while (x < dst.width) : (x += 1) {
            const cols = footprint(x, src.width, dst.width);

            // Accumulated in one fixed order, rows then columns, so the sums are the same on
            // every host (I9).
            var weighted: [3]f32 = .{ 0, 0, 0 };
            var plain: [3]f32 = .{ 0, 0, 0 };
            var coverage: f32 = 0;
            var alpha_sum: u32 = 0;
            var sy = rows.first;
            while (sy < rows.first + rows.count) : (sy += 1) {
                var sx = cols.first;
                while (sx < cols.first + cols.count) : (sx += 1) {
                    const texel = src.pixel(sx, sy);
                    const a = unorm_to_float[texel[3]];
                    for (0..3) |c| {
                        const value = decode[texel[c]];
                        weighted[c] += value * a;
                        plain[c] += value;
                    }
                    coverage += a;
                    alpha_sum += texel[3];
                }
            }

            const n = rows.count * cols.count;
            const out = dst.pixel(x, y);
            for (0..3) |c| {
                const value = if (coverage > 0)
                    weighted[c] / coverage
                else
                    plain[c] / @as(f32, @floatFromInt(n));
                out[c] = switch (space) {
                    .srgb => encodeSrgb(value),
                    .linear => encodeUnorm(value),
                };
            }
            // Integer, rounding half up: alpha is coverage, not light, and needs no table.
            out[3] = @intCast((alpha_sum + n / 2) / n);
        }
    }
}

const Footprint = struct { first: u32, count: u32 };

/// Which source rows (or columns) destination row `d` reads.
fn footprint(d: u32, src_len: u32, dst_len: u32) Footprint {
    if (src_len == 1) return .{ .first = 0, .count = 1 };
    // The last texel of an odd dimension reads the one the 2×2 box would otherwise drop.
    const odd_tail: u32 = if (src_len % 2 == 1 and d == dst_len - 1) 1 else 0;
    return .{ .first = 2 * d, .count = 2 + odd_tail };
}

// -- transfer functions ----------------------------------------------------------------

/// `b / 255`, exactly as a `unorm8` is defined.
const unorm_to_float: [256]f32 = blk: {
    var table: [256]f32 = undefined;
    for (&table, 0..) |*t, i| t.* = @as(f32, @floatFromInt(i)) / 255.0;
    break :blk table;
};

/// The sRGB transfer function's inverse, per byte, from IEC 61966-2-1.
const srgb_to_linear: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*t, i| t.* = @floatCast(srgbDecodeExact(@as(f64, @floatFromInt(i)) / 255.0));
    break :blk table;
};

/// `srgb_midpoints[k]` is the linear value whose encoding is exactly `k + 0.5`: the boundary
/// between bytes `k` and `k + 1`. Encoding is monotonic, so round-to-nearest in the encoded
/// domain is a count of the boundaries at or below a value, with no `pow` at run time.
const srgb_midpoints: [255]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [255]f32 = undefined;
    for (&table, 0..) |*t, k| t.* = @floatCast(srgbDecodeExact((@as(f64, @floatFromInt(k)) + 0.5) / 255.0));
    break :blk table;
};

fn srgbDecodeExact(encoded: f64) f64 {
    if (encoded <= 0.04045) return encoded / 12.92;
    return std.math.pow(f64, (encoded + 0.055) / 1.055, 2.4);
}

/// Linear light to the nearest sRGB byte; a tie goes up. Out-of-range values clamp.
fn encodeSrgb(value: f32) u8 {
    // Binary search for the first boundary above `value`; its index is the byte.
    var lo: usize = 0;
    var hi: usize = srgb_midpoints.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (srgb_midpoints[mid] <= value) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo);
}

fn encodeUnorm(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 1.0) * 255.0));
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;
const core = @import("core");

fn solid(gpa: Allocator, width: u32, height: u32, texels: []const [4]u8) !Image {
    var img = try Image.alloc(gpa, width, height);
    std.debug.assert(texels.len == @as(usize, width) * height);
    for (texels, 0..) |t, i| @memcpy(img.pixels[i * 4 ..][0..4], &t);
    return img;
}

test "a chain has one level per halving, sized as the RHI sizes a mip level" {
    const cases = [_][2]u32{ .{ 1, 1 }, .{ 16, 4 }, .{ 5, 3 }, .{ 1, 7 }, .{ 256, 256 }, .{ 17, 1 } };
    for (cases) |case| {
        var img = try Image.alloc(testing.allocator, case[0], case[1]);
        defer img.deinit(testing.allocator);
        @memset(img.pixels, 0x7F);

        var chain = try generate(testing.allocator, img, .srgb);
        defer chain.deinit(testing.allocator);

        const expected_count = std.math.log2_int(u32, @max(case[0], case[1])) + 1;
        try testing.expectEqual(expected_count, chain.levelCount());
        try testing.expectEqual(expected_count, levelCount(case[0], case[1]));

        var offset: usize = 0;
        for (chain.levels, 0..) |l, i| {
            try testing.expectEqual(@max(1, case[0] >> @intCast(i)), l.width);
            try testing.expectEqual(@max(1, case[1] >> @intCast(i)), l.height);
            try testing.expectEqual(offset, l.offset);
            offset += l.byteSize();
        }
        const last = chain.levels[chain.levels.len - 1];
        try testing.expectEqual(@as(u32, 1), last.width);
        try testing.expectEqual(@as(u32, 1), last.height);
        try testing.expectEqual(offset, chain.bytes.len);
        // Level 0 is the source, copied.
        try testing.expectEqualSlices(u8, img.pixels, chain.level(0).pixels);
    }
}

test "sRGB is averaged in linear light, and linear data is averaged as numbers" {
    const texels = [_][4]u8{ .{ 0, 0, 0, 255 }, .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 }, .{ 0, 0, 0, 255 } };
    var img = try solid(testing.allocator, 2, 2, &texels);
    defer img.deinit(testing.allocator);

    // Half the light is 0.5 linear, which sRGB encodes as 187.5, rounded up. Averaging the
    // encoded bytes would give 128: a level a fifth as bright as its source.
    var srgb = try generate(testing.allocator, img, .srgb);
    defer srgb.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 188, 188, 188, 255 }, srgb.level(1).pixels);

    // The same bytes as data: half of 255, rounded to nearest.
    var linear = try generate(testing.allocator, img, .linear);
    defer linear.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, linear.level(1).pixels);
}

test "the sRGB tables round-trip every byte" {
    for (0..256) |i| {
        try testing.expectEqual(@as(u8, @intCast(i)), encodeSrgb(srgb_to_linear[i]));
        try testing.expectEqual(@as(u8, @intCast(i)), encodeUnorm(unorm_to_float[i]));
    }
    try testing.expectEqual(@as(u8, 0), encodeSrgb(-1.0));
    try testing.expectEqual(@as(u8, 255), encodeSrgb(2.0));
}

test "a transparent texel's colour does not bleed into its opaque neighbour" {
    // One opaque red texel among three transparent green ones: an exporter's leftover colour
    // under zero alpha, which is what a cut-out's border usually is.
    const texels = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 0 }, .{ 0, 255, 0, 0 }, .{ 0, 255, 0, 0 } };
    var img = try solid(testing.allocator, 2, 2, &texels);
    defer img.deinit(testing.allocator);

    for ([_]ColorSpace{ .srgb, .linear }) |space| {
        var chain = try generate(testing.allocator, img, space);
        defer chain.deinit(testing.allocator);
        // Pure red, a quarter covered (63.75, rounded to nearest).
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 64 }, chain.level(1).pixels);
    }
}

test "a block with no coverage keeps the plain average of its colours" {
    const texels = [_][4]u8{ .{ 200, 0, 0, 0 }, .{ 200, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
    var img = try solid(testing.allocator, 2, 2, &texels);
    defer img.deinit(testing.allocator);

    var chain = try generate(testing.allocator, img, .linear);
    defer chain.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 100, 0, 0, 0 }, chain.level(1).pixels);
}

test "an odd dimension keeps its last row and column" {
    // A bright line on the right edge of a 3-wide image. A plain 2×2 box reads columns 0 and
    // 1 and loses it; the tail reads all three.
    const row = [_][4]u8{ .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 255, 255, 255, 255 } };
    var wide = try solid(testing.allocator, 3, 1, &row);
    defer wide.deinit(testing.allocator);
    var chain = try generate(testing.allocator, wide, .linear);
    defer chain.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), chain.levelCount());
    try testing.expectEqualSlices(u8, &.{ 85, 85, 85, 255 }, chain.level(1).pixels);

    // And down a column, with five texels: the last of two destination texels reads three.
    const column = [_][4]u8{
        .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 255, 0, 0, 255 },
    };
    var tall = try solid(testing.allocator, 1, 5, &column);
    defer tall.deinit(testing.allocator);
    var tall_chain = try generate(testing.allocator, tall, .linear);
    defer tall_chain.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 85, 0, 0, 255 }, tall_chain.level(1).pixels);
}

/// A fixed, irregular image: odd dimensions, every alpha from opaque to empty, and colour
/// under zero alpha. Built by formula, so no binary is committed for it.
fn pinnedImage(gpa: Allocator) !Image {
    var img = try Image.alloc(gpa, 13, 7);
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const p = img.pixel(x, y);
            p[0] = @truncate(x * 37 + y * 11);
            p[1] = @truncate(x * 5 + y * 71);
            p[2] = @truncate((x ^ y) * 29);
            p[3] = @truncate(if ((x + y) % 5 == 0) 0 else x * 23 + y * 19);
        }
    }
    return img;
}

test "a chain is deterministic, and its bytes are pinned" {
    var img = try pinnedImage(testing.allocator);
    defer img.deinit(testing.allocator);

    var first = try generate(testing.allocator, img, .srgb);
    defer first.deinit(testing.allocator);
    var second = try generate(testing.allocator, img, .srgb);
    defer second.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, first.bytes, second.bytes);

    var linear = try generate(testing.allocator, img, .linear);
    defer linear.deinit(testing.allocator);

    // Pinned on the first host to run it. A change here is a change to every mipmapped
    // texture's pixels, on every host, and is a decision rather than a refactor.
    try testing.expectEqual(@as(u64, 0x27012e52514ef7c2), core.id.fnv1a64(first.bytes));
    try testing.expectEqual(@as(u64, 0x1e261bb4c0e8744c), core.id.fnv1a64(linear.bytes));
}
