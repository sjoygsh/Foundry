//! Decoded images, and what every decoder promises about them.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// An image in memory, decoded and ready to become a GPU texture.
///
/// **Always 8-bit RGBA, straight (non-premultiplied) alpha, sRGB-encoded.** Every decoder
/// expands to this one layout rather than preserving the source's, because the alternative
/// is a format enum that every consumer must switch on — and there is exactly one consumer
/// that matters, `render2d`, which wants one thing.
///
/// **sRGB-encoded** is the important half. PNG carries sRGB values, `render2d` creates
/// `rgba8_unorm_srgb` textures, and the GPU converts to linear on sample
/// (`docs/design/render2d.md` §6). Nothing here converts anything; this type just records
/// what the bytes mean so that the decision is made once, in writing, rather than
/// rediscovered when the blending looks wrong.
///
/// **Straight alpha, not premultiplied.** That is what PNG stores. The batcher
/// premultiplies when it writes vertices, which is the last moment it can be done without
/// losing precision in the stored image.
pub const Image = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes, rows top to bottom, no padding between rows.
    pixels: []u8,

    pub const channels: u32 = 4;

    /// Allocates uninitialised pixel storage. The caller fills it.
    pub fn alloc(gpa: Allocator, width: u32, height: u32) Allocator.Error!Image {
        std.debug.assert(width > 0 and height > 0);
        // The multiplication cannot overflow for any dimensions a decoder will accept —
        // they are bounded long before this — but a `usize` cast of a product of `u32`s
        // is exactly the pattern that goes wrong on a 32-bit target, so it is widened
        // rather than trusted.
        const bytes: usize = @as(usize, width) * @as(usize, height) * channels;
        return .{ .width = width, .height = height, .pixels = try gpa.alloc(u8, bytes) };
    }

    pub fn deinit(self: *Image, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    pub fn byteSize(self: Image) usize {
        return self.pixels.len;
    }

    pub fn strideBytes(self: Image) usize {
        return @as(usize, self.width) * channels;
    }

    /// Row `y`, top to bottom.
    pub fn row(self: Image, y: u32) []u8 {
        std.debug.assert(y < self.height);
        const stride = self.strideBytes();
        return self.pixels[@as(usize, y) * stride ..][0..stride];
    }

    /// The four bytes of one pixel, in RGBA order.
    pub fn pixel(self: Image, x: u32, y: u32) *[4]u8 {
        std.debug.assert(x < self.width);
        return self.row(y)[@as(usize, x) * channels ..][0..channels];
    }
};

const testing = std.testing;

test "an image is tightly packed rgba" {
    var img = try Image.alloc(testing.allocator, 3, 2);
    defer img.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3 * 2 * 4), img.byteSize());
    try testing.expectEqual(@as(usize, 12), img.strideBytes());
    try testing.expectEqual(@as(usize, 12), img.row(0).len);

    @memset(img.pixels, 0);
    img.pixel(2, 1)[0] = 0xAB;
    // Last pixel of the last row is the last four bytes: no padding anywhere.
    try testing.expectEqual(@as(u8, 0xAB), img.pixels[img.pixels.len - 4]);
}
