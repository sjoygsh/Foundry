//! Foundry `asset` — layer L2. Bytes on disk become things the engine can use.
//!
//! Depends on `core`, `data` and `platform` — the module with both a filesystem and the
//! content model, which is what makes it the seam between them.
//!
//! **What is here is deliberately less than what this module will be.** It decodes images
//! and loads them from disk. It has no registry, no content IDs, no reference counting and
//! no hot reload — because the asset ID scheme is a decision deliberately postponed to M3
//! (CLAUDE.md §9), and a half-built registry now would resolve it by accident. Callers pass
//! a path, and paths are what M3 replaces.
//!
//! The split with `render2d` is that this module owns nothing on the GPU. It produces an
//! `Image` in ordinary memory; the renderer turns it into a texture and owns it from there
//! (`docs/design/render2d.md` §8).
//!
//! Everything here parses input from files, which means input from mods, which means
//! **untrusted input**: validated and refused, never asserted (CLAUDE.md §5).

const std = @import("std");
const core = @import("core");
const platform = @import("platform");

pub const image = @import("image.zig");
pub const png = @import("png.zig");
pub const schemas = @import("schemas.zig");

pub const Image = image.Image;
pub const DecodeError = png.DecodeError;
pub const Limits = png.Limits;

pub const LoadError = DecodeError || platform.FileError;

/// Read `path` and decode it as an image.
///
/// The file is read whole and then decoded, rather than streamed: PNG's `IDAT` chunks have
/// to be concatenated before the zlib stream can be read anyway, and an image small enough
/// to become a texture is small enough to hold twice for a moment.
pub fn loadImage(
    gpa: std.mem.Allocator,
    os: *platform.os.Os,
    path: []const u8,
    limits: Limits,
) LoadError!Image {
    // The same bound the decoder applies to compressed data, applied one layer earlier so
    // an absurd file is refused before it is read rather than after.
    const bytes = try os.readFile(gpa, path, limits.max_compressed_bytes);
    defer gpa.free(bytes);
    return png.decode(gpa, bytes, limits);
}

test {
    _ = image;
    _ = png;
    _ = schemas;
}

const testing = std.testing;

/// A 1x1 RGBA PNG whose single pixel is (200, 40, 60, 255).
const one_pixel_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x38, 0xA1, 0x61, 0xF3,
    0x1F, 0x00, 0x05, 0x14, 0x02, 0x2C, 0xC2, 0x0E, 0x5D, 0x14, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "loadImage reads a file and decodes it, and reports both kinds of failure" {
    const gpa = testing.allocator;

    var os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-asset-test", .env = &.{} });
    defer os.deinit();

    const dir = try os.tempDirAlloc(gpa);
    defer gpa.free(dir);

    const good = try platform.os.joinPath(gpa, &.{ dir, "foundry-one-pixel.png" });
    defer gpa.free(good);
    const bad = try platform.os.joinPath(gpa, &.{ dir, "foundry-not-a.png" });
    defer gpa.free(bad);

    try os.writeFile(good, &one_pixel_png);
    try os.writeFile(bad, "this is not a png");

    {
        var img = try loadImage(gpa, os, good, .{});
        defer img.deinit(gpa);
        try testing.expectEqual(@as(u32, 1), img.width);
        try testing.expectEqualSlices(u8, &.{ 200, 40, 60, 255 }, img.pixel(0, 0));
    }

    // A file that exists but is not an image, and a file that does not exist, are
    // different failures and stay different: the caller can tell "your texture is
    // corrupt" from "your texture is missing".
    try testing.expectError(error.InvalidImage, loadImage(gpa, os, bad, .{}));
    const missing = try platform.os.joinPath(gpa, &.{ dir, "foundry-absent.png" });
    defer gpa.free(missing);
    try testing.expectError(error.FileNotFound, loadImage(gpa, os, missing, .{}));
}
