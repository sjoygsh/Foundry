//! Texture, vertex and index formats.
//!
//! A deliberately small set: the formats Foundry actually uses, not an enumeration of
//! everything the three APIs can express. Adding one is cheap; removing one that a shader
//! or a compiled asset already names is not, so the list grows only when something needs
//! it (development rule 7).
//!
//! Design: `docs/design/rhi.md` §2.

const std = @import("std");

/// Pixel formats for textures and render targets.
///
/// `bgra8_unorm_srgb` is first among equals: it is what `CAMetalLayer` hands back by
/// default, so the swapchain format on the primary target is a BGRA one whether or not
/// anything else uses it.
pub const TextureFormat = enum(u16) {
    // 8-bit.
    r8_unorm,
    rg8_unorm,
    rgba8_unorm,
    rgba8_unorm_srgb,
    bgra8_unorm,
    bgra8_unorm_srgb,

    // Floating point, for HDR targets and data textures.
    r16_float,
    rgba16_float,
    r32_float,
    rgba32_float,

    // Depth and stencil.
    depth32_float,
    depth32_float_stencil8,

    /// Bytes per texel. Every format here is uncompressed and single-texel-block; block
    /// compressed formats will need this to become a block size rather than a texel size,
    /// which is why callers should ask rather than assume.
    pub fn bytesPerTexel(self: TextureFormat) u32 {
        return switch (self) {
            .r8_unorm => 1,
            .rg8_unorm, .r16_float => 2,
            .rgba8_unorm, .rgba8_unorm_srgb, .bgra8_unorm, .bgra8_unorm_srgb, .r32_float, .depth32_float => 4,
            .rgba16_float => 8,
            .rgba32_float => 16,
            // Padded to 8 on every implementation Foundry targets; the stencil byte is not
            // addressable alongside the depth in a linear layout.
            .depth32_float_stencil8 => 8,
        };
    }

    pub fn isDepth(self: TextureFormat) bool {
        return switch (self) {
            .depth32_float, .depth32_float_stencil8 => true,
            else => false,
        };
    }

    pub fn hasStencil(self: TextureFormat) bool {
        return self == .depth32_float_stencil8;
    }

    /// Whether sampling this format applies sRGB-to-linear conversion in hardware.
    ///
    /// Worth asking rather than inferring from the name: getting it wrong produces an
    /// image that is subtly, uniformly too dark or too bright, which is easy to look at
    /// for weeks without noticing.
    pub fn isSrgb(self: TextureFormat) bool {
        return switch (self) {
            .rgba8_unorm_srgb, .bgra8_unorm_srgb => true,
            else => false,
        };
    }

    /// A format may be a colour attachment only if it is not a depth format.
    pub fn isColor(self: TextureFormat) bool {
        return !self.isDepth();
    }
};

/// Vertex attribute formats.
pub const VertexFormat = enum(u16) {
    float32,
    float32x2,
    float32x3,
    float32x4,
    /// Four bytes normalised to `[0, 1]`. What vertex colours should be.
    unorm8x4,
    uint8x4,
    uint16x2,
    uint32,

    pub fn size(self: VertexFormat) u32 {
        return switch (self) {
            .float32, .unorm8x4, .uint8x4, .uint16x2, .uint32 => 4,
            .float32x2 => 8,
            .float32x3 => 12,
            .float32x4 => 16,
        };
    }
};

pub const IndexFormat = enum(u8) {
    uint16,
    uint32,

    pub fn size(self: IndexFormat) u32 {
        return switch (self) {
            .uint16 => 2,
            .uint32 => 4,
        };
    }
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "every texture format reports a plausible size" {
    for (std.enums.values(TextureFormat)) |f| {
        try testing.expect(f.bytesPerTexel() > 0);
        try testing.expect(f.bytesPerTexel() <= 16);
    }
}

test "depth formats are not colour formats, and vice versa" {
    // A pass that used a depth format as a colour attachment would be rejected by every
    // real backend; this is the predicate the validation backend checks with.
    try testing.expect(TextureFormat.depth32_float.isDepth());
    try testing.expect(!TextureFormat.depth32_float.isColor());
    try testing.expect(TextureFormat.rgba8_unorm.isColor());
    try testing.expect(!TextureFormat.rgba8_unorm.isDepth());

    for (std.enums.values(TextureFormat)) |f| {
        try testing.expect(f.isDepth() != f.isColor());
    }
}

test "stencil implies depth" {
    for (std.enums.values(TextureFormat)) |f| {
        if (f.hasStencil()) try testing.expect(f.isDepth());
    }
}

test "sRGB is a property of the format, not of the name" {
    try testing.expect(TextureFormat.bgra8_unorm_srgb.isSrgb());
    try testing.expect(!TextureFormat.bgra8_unorm.isSrgb());
    // No depth format is ever sRGB.
    for (std.enums.values(TextureFormat)) |f| {
        if (f.isDepth()) try testing.expect(!f.isSrgb());
    }
}

test "vertex format sizes are what a packed struct would give" {
    try testing.expectEqual(@as(u32, 8), VertexFormat.float32x2.size());
    try testing.expectEqual(@as(u32, 16), VertexFormat.float32x4.size());
    try testing.expectEqual(@as(u32, 4), VertexFormat.unorm8x4.size());
    for (std.enums.values(VertexFormat)) |f| {
        try testing.expect(f.size() % 4 == 0); // every one is 4-byte aligned
    }
}

test "index format sizes" {
    try testing.expectEqual(@as(u32, 2), IndexFormat.uint16.size());
    try testing.expectEqual(@as(u32, 4), IndexFormat.uint32.size());
}
