//! The render2d values that cross the public boundary.
//!
//! These are intentionally separate from `render2d`'s game-facing Zig structs. The latter
//! can evolve with the engine; these are the frozen C layout (`public-abi.md` §5). Every
//! padding byte is named so a C author and the agreement translation unit see the same shape.
//!
//! Design: `docs/design/public-abi.md` §9; `docs/design/render2d.md` §§5, 6, 10 and 11.

const std = @import("std");

const types = @import("types.zig");

const Bool = types.Bool;
const Texture = types.Texture;

/// A two-dimensional point or extent, in logical screen points or world units as the call
/// that carries it specifies.
pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// A rectangle. Render2d's public rectangles are in logical points, except UV rectangles,
/// which are normalised texture coordinates.
pub const Rect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// A linear-light colour multiplier. `render2d` performs the premultiplication when it
/// writes its vertex, so this remains four ordinary floats at the ABI.
pub const Color = extern struct {
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,
};

/// A camera in world units and logical screen points.
pub const Camera = extern struct {
    center: Vec2 = .{},
    zoom: f32 = 1,
    rotation: f32 = 0,
    viewport: Rect = .{},
};

/// A sprite descriptor. `blend` uses the stable values alpha=0, additive=1, none=2.
/// Boolean values accept any nonzero input and the ABI writes exactly 0 or 1 only on output
/// types; the flag bytes are therefore u8 rather than C's implementation-defined `bool`.
pub const Sprite = extern struct {
    texture: Texture = .none,
    position: Vec2 = .{},
    size: Vec2 = .{},
    uv: Rect = .{ .w = 1, .h = 1 },
    origin: Vec2 = .{ .x = 0.5, .y = 0.5 },
    rotation: f32 = 0,
    tint: Color = .{},
    layer: i16 = 0,
    reserved_layer: u16 = 0,
    blend: i32 = 0,
    flip_x: Bool = 0,
    flip_y: Bool = 0,
    reserved_flags: [2]u8 = .{ 0, 0 },
};

/// Fixed-grid bitmap font metadata. The texture and UV rectangle identify the font's
/// region; the remaining fields describe its codepoint grid. `no_codepoint` means no
/// substitution glyph.
pub const Font = extern struct {
    texture: Texture = .none,
    uv: Rect = .{},
    width: u32 = 0,
    height: u32 = 0,
    cell_width: u32 = 0,
    cell_height: u32 = 0,
    columns: u32 = 0,
    first_codepoint: u32 = ' ',
    glyph_count: u32 = 0,
    substitute: u32 = '?',
    reserved: [4]u8 = .{ 0, 0, 0, 0 },

    pub const no_codepoint: u32 = std.math.maxInt(u32);
};

/// Text drawing parameters. The layer and blend padding is explicit for C and C++.
pub const TextOptions = extern struct {
    position: Vec2 = .{},
    scale: f32 = 1,
    tint: Color = .{},
    layer: i16 = 0,
    reserved_layer: u16 = 0,
    blend: i32 = 0,
    letter_spacing: f32 = 0,
    line_spacing: f32 = 0,
};

/// The discriminant for `ViewDesc`: camera=0 and screen=1.
pub const ViewKind = enum(i32) {
    camera = 0,
    screen = 1,
};

/// A view descriptor. C unions are deliberately excluded from the public ABI (§5), so both
/// payloads are present at fixed offsets and `kind` selects which one is meaningful.
pub const ViewDesc = extern struct {
    kind: i32 = 0,
    reserved: u32 = 0,
    camera: Camera = .{},
    screen: Rect = .{},
};

/// Per-frame output counters, copied from `render2d.Stats`.
pub const Stats = extern struct {
    sprites: u32 = 0,
    glyphs: u32 = 0,
    tiles: u32 = 0,
    batches: u32 = 0,
    draw_calls: u32 = 0,
    vertices: u32 = 0,
    vertex_bytes: u32 = 0,
    buffers_used: u32 = 0,
    textures_resident: u32 = 0,
    views: u32 = 0,
};

comptime {
    if (@sizeOf(Vec2) != 8 or @offsetOf(Vec2, "x") != 0 or @offsetOf(Vec2, "y") != 4) {
        @compileError("FoundryRenderVec2 layout changed");
    }
    if (@sizeOf(Rect) != 16 or @offsetOf(Rect, "x") != 0 or @offsetOf(Rect, "y") != 4 or
        @offsetOf(Rect, "w") != 8 or @offsetOf(Rect, "h") != 12)
    {
        @compileError("FoundryRenderRect layout changed");
    }
    if (@sizeOf(Color) != 16 or @offsetOf(Color, "r") != 0 or @offsetOf(Color, "g") != 4 or
        @offsetOf(Color, "b") != 8 or @offsetOf(Color, "a") != 12)
    {
        @compileError("FoundryRenderColor layout changed");
    }
    if (@sizeOf(Camera) != 32 or @offsetOf(Camera, "center") != 0 or
        @offsetOf(Camera, "zoom") != 8 or @offsetOf(Camera, "rotation") != 12 or
        @offsetOf(Camera, "viewport") != 16)
    {
        @compileError("FoundryRenderCamera layout changed");
    }
    if (@sizeOf(Sprite) != 80 or @offsetOf(Sprite, "texture") != 0 or
        @offsetOf(Sprite, "position") != 8 or @offsetOf(Sprite, "size") != 16 or
        @offsetOf(Sprite, "uv") != 24 or @offsetOf(Sprite, "origin") != 40 or
        @offsetOf(Sprite, "rotation") != 48 or @offsetOf(Sprite, "tint") != 52 or
        @offsetOf(Sprite, "layer") != 68 or @offsetOf(Sprite, "reserved_layer") != 70 or
        @offsetOf(Sprite, "blend") != 72 or @offsetOf(Sprite, "flip_x") != 76 or
        @offsetOf(Sprite, "flip_y") != 77 or @offsetOf(Sprite, "reserved_flags") != 78)
    {
        @compileError("FoundryRenderSprite layout changed");
    }
    if (@sizeOf(Font) != 64 or @offsetOf(Font, "texture") != 0 or @offsetOf(Font, "uv") != 8 or
        @offsetOf(Font, "width") != 24 or @offsetOf(Font, "height") != 28 or
        @offsetOf(Font, "cell_width") != 32 or @offsetOf(Font, "cell_height") != 36 or
        @offsetOf(Font, "columns") != 40 or @offsetOf(Font, "first_codepoint") != 44 or
        @offsetOf(Font, "glyph_count") != 48 or @offsetOf(Font, "substitute") != 52 or
        @offsetOf(Font, "reserved") != 56)
    {
        @compileError("FoundryRenderFont layout changed");
    }
    if (@sizeOf(TextOptions) != 44 or @offsetOf(TextOptions, "position") != 0 or
        @offsetOf(TextOptions, "scale") != 8 or @offsetOf(TextOptions, "tint") != 12 or
        @offsetOf(TextOptions, "layer") != 28 or @offsetOf(TextOptions, "reserved_layer") != 30 or
        @offsetOf(TextOptions, "blend") != 32 or @offsetOf(TextOptions, "letter_spacing") != 36 or
        @offsetOf(TextOptions, "line_spacing") != 40)
    {
        @compileError("FoundryRenderTextOptions layout changed");
    }
    if (@sizeOf(ViewDesc) != 56 or @offsetOf(ViewDesc, "camera") != 8 or
        @offsetOf(ViewDesc, "screen") != 40)
    {
        @compileError("FoundryRenderViewDesc layout changed");
    }
    if (@sizeOf(Stats) != 40) @compileError("FoundryRenderStats layout changed");
}

test "render ABI value layouts have explicit stable widths" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 8), @sizeOf(Vec2));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Rect));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Color));
    try testing.expectEqual(@as(usize, 32), @sizeOf(Camera));
    try testing.expectEqual(@as(usize, 80), @sizeOf(Sprite));
    try testing.expectEqual(@as(usize, 64), @sizeOf(Font));
    try testing.expectEqual(@as(usize, 44), @sizeOf(TextOptions));
    try testing.expectEqual(@as(usize, 56), @sizeOf(ViewDesc));
    try testing.expectEqual(@as(usize, 40), @sizeOf(Stats));
}
