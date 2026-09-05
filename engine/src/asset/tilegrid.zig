//! `foundry:tilegrid` — a grid of tile ids, as an asset.
//!
//! **A map's bulk is a binary payload and belongs in one** (`CLAUDE.md` §6). A 64x48 map is
//! 3,072 numbers and a real one is far more; a list of ten thousand integers in a `.fdt` file
//! is a binary payload wearing a disguise — unreadable, undiffable in any useful sense, and
//! expensive to parse at exactly the moment content loading is being measured. So the grid is
//! an asset, its identity is its content id and its path merely derives one (ADR-0021),
//! exactly like a texture.
//!
//! The format is a header and a little-endian `u16` array, with the version in a **field
//! rather than in the magic** — the same discipline `.fpk` and `.fsav` keep, so a grid from a
//! future Foundry reports "format version 3, this build understands 1" instead of "not a
//! grid" (I8).
//!
//! ```
//! 0   magic            [4]u8   "FGRD"
//! 4   format_version   u32
//! 8   width            u32     cells
//! 12  height           u32     cells
//! 16  tiles            u16[width * height], little-endian
//! ```
//!
//! **Row-major, and row 0 is the bottom row**, because world Y is up (`render2d.md` §4) and
//! `physics2d.Grid` addresses cell (0,0) at the world origin. A picture of a map has its
//! highest row first, so whatever writes one reverses; that is the compiler's job and not
//! this format's.
//!
//! **The loader lives here and not in `render2d`.** A grid of tile ids is not a GPU concept —
//! it is `[]const u16`, which `render2d` draws and `physics2d` collides against and neither
//! owns — and `fpack` has to read the same format without linking a renderer. That is the
//! reasoning `schemas.zig` already gives for the texture *record*, applied one step further
//! because here the product is not a GPU object either. It is still registered at runtime by
//! whoever wants it (I6); nothing self-registers.
//!
//! Design: `docs/design/tilemaps-and-collision.md` §9.

const std = @import("std");
const core = @import("core");

const registry_mod = @import("registry.zig");
const schemas = @import("schemas.zig");

const Allocator = std.mem.Allocator;
const Loader = registry_mod.Loader;
const Record = @import("data").store.Record;
const Payload = registry_mod.Payload;

pub const magic = "FGRD";

/// Bumped when the layout above changes. In a field, not in the magic.
pub const format_version: u32 = 1;

pub const header_size: usize = 16;

pub const ReadError = error{
    /// Too short, or the magic is not `FGRD`. Ask `versionOf` first: a grid from a newer
    /// Foundry is a different report from a file that was never a grid.
    NotAGrid,
    /// The magic is right and the version is not one this build reads.
    UnsupportedVersion,
    /// A zero dimension, a size that does not match the bytes, or a truncated array.
    Malformed,
};

/// The format version of `bytes`, or null if it is not a grid at all.
pub fn versionOf(bytes: []const u8) ?u32 {
    if (bytes.len < header_size) return null;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return null;
    return std.mem.readInt(u32, bytes[4..8], .little);
}

/// A decoded grid. **Owns `tiles`.**
pub const TileGrid = struct {
    width: u32,
    height: u32,
    /// Row-major, `width * height` long, row 0 at the bottom.
    tiles: []u16,

    pub fn deinit(self: *TileGrid, gpa: Allocator) void {
        gpa.free(self.tiles);
        self.* = .{ .width = 0, .height = 0, .tiles = &.{} };
    }

    pub fn tileAt(self: TileGrid, x: u32, y: u32) ?u16 {
        if (x >= self.width or y >= self.height) return null;
        return self.tiles[@as(usize, y) * self.width + x];
    }
};

/// Decodes a grid, copying its tiles into memory the caller owns.
///
/// **Copied rather than aliased, and the endianness is honoured rather than assumed.** The
/// array in the file is little-endian by specification; a consumer wants `[]const u16` in
/// host order, and the file's bytes are neither guaranteed to be two-byte aligned nor to
/// outlive the load. One pass at load time buys a format that means the same thing on every
/// machine, which is what I8 asks a versioned format to be worth.
///
/// No separate size limit: `width * height` must agree with the byte length exactly, so a
/// header claiming a billion cells is refused by the file it arrived in rather than by a
/// number chosen here.
pub fn read(gpa: Allocator, bytes: []const u8) (ReadError || Allocator.Error)!TileGrid {
    const version = versionOf(bytes) orelse return error.NotAGrid;
    if (version != format_version) return error.UnsupportedVersion;

    const width = std.mem.readInt(u32, bytes[8..12], .little);
    const height = std.mem.readInt(u32, bytes[12..16], .little);
    if (width == 0 or height == 0) return error.Malformed;

    const count = @as(u64, width) * @as(u64, height);
    const payload = bytes[header_size..];
    if (count * 2 != payload.len) return error.Malformed;

    const tiles = try gpa.alloc(u16, @intCast(count));
    errdefer gpa.free(tiles);
    for (tiles, 0..) |*tile, i| {
        tile.* = std.mem.readInt(u16, payload[i * 2 ..][0..2], .little);
    }
    return .{ .width = width, .height = height, .tiles = tiles };
}

pub const WriteError = error{
    /// A zero dimension, or dimensions that disagree with the tile count.
    InvalidGrid,
};

/// Encodes a grid. The caller owns the returned bytes.
///
/// Here rather than in `fpack`, so that the writer and the reader are one file and the
/// round trip is a test rather than a hope. `fpack` is a Foundry application built on
/// Foundry's own modules (ADR-0011), so using this is what it is supposed to do.
pub fn write(
    gpa: Allocator,
    width: u32,
    height: u32,
    tiles: []const u16,
) (WriteError || Allocator.Error)![]u8 {
    if (width == 0 or height == 0) return error.InvalidGrid;
    const count = @as(u64, width) * @as(u64, height);
    if (count != tiles.len) return error.InvalidGrid;

    const bytes = try gpa.alloc(u8, header_size + @as(usize, @intCast(count * 2)));
    errdefer gpa.free(bytes);

    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], format_version, .little);
    std.mem.writeInt(u32, bytes[8..12], width, .little);
    std.mem.writeInt(u32, bytes[12..16], height, .little);
    for (tiles, 0..) |tile, i| {
        std.mem.writeInt(u16, bytes[header_size + i * 2 ..][0..2], tile, .little);
    }
    return bytes;
}

/// The loader to hand `Registry.registerLoader`.
///
/// It needs no context, because a grid of numbers needs nothing but an allocator to become
/// one. The payload is a pointer to a `TileGrid` the loader allocated and the loader frees;
/// a grid does not fit in the registry's one opaque word the way a texture handle does.
pub fn tilegridLoader() Loader {
    return .{
        .schema = schemas.tilegrid.id,
        .ctx = null,
        .load = load,
        .unload = unload,
    };
}

fn load(
    ctx: ?*anyopaque,
    gpa: Allocator,
    record: Record,
    bytes: []const u8,
) registry_mod.LoadError!Payload {
    _ = ctx;
    _ = record;

    const grid = gpa.create(TileGrid) catch return error.OutOfMemory;
    errdefer gpa.destroy(grid);

    grid.* = read(gpa, bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // The file is a grid and this build cannot read it: a different report for the
        // author than "this is not a grid at all", which is the whole point of I8's
        // version-in-a-field rule.
        error.UnsupportedVersion => error.UnsupportedVersion,
        error.NotAGrid, error.Malformed => error.InvalidAsset,
    };
    return .fromPointer(grid);
}

fn unload(ctx: ?*anyopaque, gpa: Allocator, payload: Payload) void {
    _ = ctx;
    const grid: *TileGrid = @ptrCast(@alignCast(payload.pointer().?));
    grid.deinit(gpa);
    gpa.destroy(grid);
}

/// The loaded grid behind an asset payload.
pub fn fromPayload(payload: Payload) *const TileGrid {
    return @ptrCast(@alignCast(payload.pointer().?));
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "a grid survives the round trip it was written for" {
    const gpa = testing.allocator;
    const tiles = [_]u16{ 0, 1, 2, 3, 4, 5 };

    const bytes = try write(gpa, 3, 2, &tiles);
    defer gpa.free(bytes);

    try testing.expectEqualStrings(magic, bytes[0..4]);
    try testing.expectEqual(@as(?u32, 1), versionOf(bytes));
    try testing.expectEqual(header_size + 12, bytes.len);

    var grid = try read(gpa, bytes);
    defer grid.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), grid.width);
    try testing.expectEqual(@as(u32, 2), grid.height);
    try testing.expectEqualSlices(u16, &tiles, grid.tiles);
    // Row 0 is the bottom row, so (0,0) is the first number written.
    try testing.expectEqual(@as(?u16, 0), grid.tileAt(0, 0));
    try testing.expectEqual(@as(?u16, 3), grid.tileAt(0, 1));
    try testing.expectEqual(@as(?u16, null), grid.tileAt(3, 0));
}

test "the array is little-endian on every machine, not in host order" {
    const gpa = testing.allocator;
    const tiles = [_]u16{0x0102};
    const bytes = try write(gpa, 1, 1, &tiles);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(u8, 0x02), bytes[header_size]);
    try testing.expectEqual(@as(u8, 0x01), bytes[header_size + 1]);
}

test "a file that is not a grid, and one from a newer Foundry, are different answers" {
    const gpa = testing.allocator;

    try testing.expectEqual(@as(?u32, null), versionOf("no"));
    try testing.expectEqual(@as(?u32, null), versionOf("NOPE" ++ [_]u8{0} ** 12));
    try testing.expectError(error.NotAGrid, read(gpa, "no"));

    var future = [_]u8{0} ** (header_size + 2);
    @memcpy(future[0..4], magic);
    std.mem.writeInt(u32, future[4..8], 99, .little);
    std.mem.writeInt(u32, future[8..12], 1, .little);
    std.mem.writeInt(u32, future[12..16], 1, .little);
    try testing.expectEqual(@as(?u32, 99), versionOf(&future));
    try testing.expectError(error.UnsupportedVersion, read(gpa, &future));
}

test "dimensions that disagree with the bytes are refused rather than trusted" {
    const gpa = testing.allocator;
    const tiles = [_]u16{ 1, 2, 3, 4 };
    const bytes = try write(gpa, 2, 2, &tiles);
    defer gpa.free(bytes);

    // Truncated.
    try testing.expectError(error.Malformed, read(gpa, bytes[0 .. bytes.len - 2]));

    // A header claiming more cells than the file can hold. This is the guard that means no
    // separate size limit is needed: the file bounds the claim.
    var lying = try gpa.dupe(u8, bytes);
    defer gpa.free(lying);
    std.mem.writeInt(u32, lying[8..12], 100_000, .little);
    try testing.expectError(error.Malformed, read(gpa, lying));

    // Zero is not a grid, which is also what `physics2d.Grid.validate` says.
    std.mem.writeInt(u32, lying[8..12], 0, .little);
    try testing.expectError(error.Malformed, read(gpa, lying));

    try testing.expectError(error.InvalidGrid, write(gpa, 0, 2, &tiles));
    try testing.expectError(error.InvalidGrid, write(gpa, 3, 2, &tiles));
}

test "the payload is a pointer the loader owns, and unloading frees it" {
    const gpa = testing.allocator;
    const tiles = [_]u16{ 7, 8 };
    const bytes = try write(gpa, 2, 1, &tiles);
    defer gpa.free(bytes);

    const loader = tilegridLoader();
    const payload = try loader.load(loader.ctx, gpa, undefined, bytes);
    const grid = fromPayload(payload);
    try testing.expectEqual(@as(u32, 2), grid.width);
    try testing.expectEqualSlices(u16, &tiles, grid.tiles);
    loader.unload(loader.ctx, gpa, payload);
}
