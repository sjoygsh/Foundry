//! Colour, and the one conversion that keeps it correct.

const std = @import("std");

/// A colour in **linear** light, not sRGB.
///
/// This is the single most consequential detail in the renderer, and it is worth being
/// blunt about why. The swapchain is an `_srgb` format and textures decoded from PNG are
/// created as `_srgb`, so the GPU converts sRGB to linear when it samples and back when it
/// writes. Everything in between — every multiply, every blend, every fade — happens in
/// linear light, and a tint expressed in sRGB values silently produces the wrong result.
///
/// It is *silent* that makes it dangerous: nothing errors, nothing looks obviously broken,
/// and half-transparent overlaps are subtly too dark forever. So the type is linear, and
/// the numbers a colour picker gives you go through `srgb8`.
pub const Color = extern struct {
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,

    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    /// Components already in linear light.
    pub fn linear(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// The eight-bit sRGB values that a colour picker, a hex code or an artist gives you.
    /// Alpha is *not* converted: alpha has never been gamma-encoded.
    pub fn srgb8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = srgbToLinear(r),
            .g = srgbToLinear(g),
            .b = srgbToLinear(b),
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    /// Pack into the vertex format: eight bits per channel, **premultiplied by alpha**.
    ///
    /// Premultiplying here rather than in the shader is what lets `alpha` and `additive`
    /// blending differ by a single blend factor instead of by a whole pipeline
    /// permutation (`docs/design/render2d.md` §6). Eight bits of a *multiplier* is
    /// plenty; this is a tint, not the image.
    pub fn toPremultipliedRgba8(self: Color) [4]u8 {
        const a = std.math.clamp(self.a, 0, 1);
        return .{
            encode(self.r * a),
            encode(self.g * a),
            encode(self.b * a),
            encode(a),
        };
    }

    fn encode(v: f32) u8 {
        // Non-finite input would make the cast undefined, and a colour can come from a
        // content file, so it is clamped rather than trusted.
        if (std.math.isNan(v)) return 0;
        return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
    }
};

/// The sRGB transfer function, exactly as the standard defines it. Not an approximation
/// with 2.2: the linear segment near black is where the difference is visible.
fn srgbToLinear(value: u8) f32 {
    const c = @as(f32, @floatFromInt(value)) / 255.0;
    if (c <= 0.04045) return c / 12.92;
    return std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

/// How a sprite combines with what is already in the target.
///
/// Named `none` rather than `opaque` because the latter is a Zig keyword — and `none`
/// reads correctly anyway: no blending.
pub const BlendMode = enum {
    /// Source over destination, with premultiplied alpha.
    alpha,
    /// Added to the destination. Glows, sparks, light.
    additive,
    /// Overwrites. Cheapest, and correct only when nothing is translucent.
    none,

    pub const count = @typeInfo(BlendMode).@"enum".fields.len;
};

const testing = std.testing;

test "sRGB conversion is the real transfer function at both ends" {
    // The endpoints are exact by definition.
    try testing.expectEqual(@as(f32, 0), Color.srgb8(0, 0, 0, 255).r);
    try testing.expectApproxEqAbs(@as(f32, 1), Color.srgb8(255, 255, 255, 255).r, 1e-6);

    // Mid-grey is the case that exposes a naive 2.2 approximation: sRGB 128 is about
    // 0.2159 in linear light, not 0.5 and not (128/255)^2.2 = 0.2176.
    try testing.expectApproxEqAbs(@as(f32, 0.2158), Color.srgb8(128, 128, 128, 255).r, 1e-3);

    // Below the knee the transfer function is linear, not a power curve.
    try testing.expectApproxEqAbs(@as(f32, 10.0 / 255.0 / 12.92), Color.srgb8(10, 0, 0, 255).r, 1e-6);

    // Alpha is never gamma-encoded and so is never converted.
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), Color.srgb8(0, 0, 0, 128).a, 1e-6);
}

test "packing premultiplies and clamps" {
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, Color.white.toPremultipliedRgba8());
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, Color.transparent.toPremultipliedRgba8());

    // Half alpha halves the colour: that is what premultiplied means.
    const half = Color.linear(1, 0.5, 0, 0.5).toPremultipliedRgba8();
    try testing.expectEqual(@as(u8, 128), half[0]);
    try testing.expectEqual(@as(u8, 64), half[1]);
    try testing.expectEqual(@as(u8, 0), half[2]);
    try testing.expectEqual(@as(u8, 128), half[3]);

    // Out-of-range and non-finite components come from content files, so they are
    // clamped rather than allowed to make the cast undefined.
    const wild = Color.linear(5, -3, std.math.nan(f32), 2).toPremultipliedRgba8();
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, wild);
}
