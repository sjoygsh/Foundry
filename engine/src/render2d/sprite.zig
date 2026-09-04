//! What a game asks for, and the vertices it becomes.

const std = @import("std");
const core = @import("core");

const color_mod = @import("color.zig");
const texture_mod = @import("texture.zig");

const Color = color_mod.Color;
const BlendMode = color_mod.BlendMode;
const TextureHandle = texture_mod.TextureHandle;
const Rect = core.math.Rect;
const Vec2 = core.math.Vec2;

/// One textured quad.
///
/// Every field after `texture`, `position` and `size` has a default, so the simplest call
/// names three of them. That matters more than it looks: this struct's shape is what every
/// game and every mod will type thousands of times, and it is a compatibility decision
/// rather than a style one (CLAUDE.md §7).
pub const Sprite = struct {
    texture: TextureHandle,
    /// Where the sprite's `origin` sits, in world units.
    position: Vec2,
    /// Extent in world units, before rotation.
    size: Vec2,
    /// The sub-rectangle of the texture to draw, in UV space. An atlas region supplies
    /// this; a whole texture is the default.
    uv: Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    /// Which point of the sprite `position` refers to, normalised. Centre by default,
    /// because rotating about a corner is the unusual case.
    origin: Vec2 = .{ .x = 0.5, .y = 0.5 },
    /// Radians, counter-clockwise, matching world space.
    rotation: f32 = 0,
    /// Multiplied into the sampled texel, in **linear** light. See `color.zig`.
    tint: Color = .white,
    /// Draw order. Lower draws first; ties break on submission order, never on texture.
    layer: i16 = 0,
    blend: BlendMode = .alpha,
    flip_x: bool = false,
    flip_y: bool = false,
};

/// The vertex the sprite shader consumes.
///
/// 20 bytes. `u8` colour rather than `f32` saves a quarter of the buffer at scale, and
/// eight bits of a *multiplier* is plenty — this is a tint, not the image.
pub const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    /// Linear, premultiplied by alpha. See `Color.toPremultipliedRgba8`.
    color: [4]u8,
};

comptime {
    // The shader's `[[stage_in]]` layout is a contract, and silent padding is the kind of
    // bug that costs an afternoon. Asserted here rather than trusted.
    std.debug.assert(@sizeOf(Vertex) == 20);
    std.debug.assert(@offsetOf(Vertex, "position") == 0);
    std.debug.assert(@offsetOf(Vertex, "uv") == 8);
    std.debug.assert(@offsetOf(Vertex, "color") == 16);
}

pub const vertices_per_quad = 4;
pub const indices_per_quad = 6;

/// Corner order, and the reason for it.
///
/// Bottom-left, bottom-right, top-right, top-left — counter-clockwise in a Y-up space,
/// which matches `FrontFace.counter_clockwise`. Nothing culls in 2D, so this costs
/// nothing today and means enabling culling later is not a debugging session.
pub const Corner = enum(u2) { bottom_left = 0, bottom_right = 1, top_right = 2, top_left = 3 };

/// Turn one sprite into four vertices, in world space.
///
/// Rotation is applied here, on the CPU, to four corners — not by a per-sprite matrix on
/// the GPU. Four rotated points cost eight multiplies; a per-sprite matrix costs a binding
/// and ends the batch, and one draw call for ten thousand sprites is the entire point.
pub fn writeQuad(sprite: Sprite, out: *[vertices_per_quad]Vertex) void {
    // Local extents. `origin` is normalised, so an origin of (0.5, 0.5) centres the quad
    // and (0, 0) puts `position` at its bottom-left.
    const x0 = -sprite.origin.x * sprite.size.x;
    const x1 = (1 - sprite.origin.x) * sprite.size.x;
    const y0 = -sprite.origin.y * sprite.size.y;
    const y1 = (1 - sprite.origin.y) * sprite.size.y;

    const c = @cos(sprite.rotation);
    const s = @sin(sprite.rotation);

    // UVs are Y-down: `uv.y` is the *top* edge of the region, which is what every one of
    // Metal, Vulkan and D3D means by v = 0 (`rhi.md` §9). The flip between that and a
    // Y-up world lives here and nowhere else.
    var u_left = sprite.uv.x;
    var u_right = sprite.uv.x + sprite.uv.w;
    var v_top = sprite.uv.y;
    var v_bottom = sprite.uv.y + sprite.uv.h;
    if (sprite.flip_x) std.mem.swap(f32, &u_left, &u_right);
    if (sprite.flip_y) std.mem.swap(f32, &v_top, &v_bottom);

    const packed_color = sprite.tint.toPremultipliedRgba8();

    const local = [vertices_per_quad][2]f32{
        .{ x0, y0 }, // bottom-left
        .{ x1, y0 }, // bottom-right
        .{ x1, y1 }, // top-right
        .{ x0, y1 }, // top-left
    };
    const uvs = [vertices_per_quad][2]f32{
        .{ u_left, v_bottom },
        .{ u_right, v_bottom },
        .{ u_right, v_top },
        .{ u_left, v_top },
    };

    for (0..vertices_per_quad) |i| {
        const lx = local[i][0];
        const ly = local[i][1];
        out[i] = .{
            .position = .{
                sprite.position.x + (lx * c - ly * s),
                sprite.position.y + (lx * s + ly * c),
            },
            .uv = uvs[i],
            .color = packed_color,
        };
    }
}

/// The static index pattern: two triangles per quad, sharing the diagonal.
///
/// Written once at startup into a `device_local` buffer that never changes again, so the
/// per-frame upload is vertices only.
pub fn writeIndices(out: []u32) void {
    std.debug.assert(out.len % indices_per_quad == 0);
    var quad: u32 = 0;
    while (quad * indices_per_quad < out.len) : (quad += 1) {
        const base = quad * vertices_per_quad;
        const at = quad * indices_per_quad;
        out[at + 0] = base + 0;
        out[at + 1] = base + 1;
        out[at + 2] = base + 2;
        out[at + 3] = base + 0;
        out[at + 4] = base + 2;
        out[at + 5] = base + 3;
    }
}

const testing = std.testing;
const tolerance = 1e-4;

fn unitSprite() Sprite {
    return .{
        .texture = .none,
        .position = .init(0, 0),
        .size = .init(2, 2),
    };
}

test "a centred sprite straddles its position" {
    var v: [4]Vertex = undefined;
    writeQuad(unitSprite(), &v);

    try testing.expectEqual([2]f32{ -1, -1 }, v[@intFromEnum(Corner.bottom_left)].position);
    try testing.expectEqual([2]f32{ 1, -1 }, v[@intFromEnum(Corner.bottom_right)].position);
    try testing.expectEqual([2]f32{ 1, 1 }, v[@intFromEnum(Corner.top_right)].position);
    try testing.expectEqual([2]f32{ -1, 1 }, v[@intFromEnum(Corner.top_left)].position);
}

test "origin moves the quad relative to its position, not the other way round" {
    var sprite = unitSprite();
    sprite.origin = .init(0, 0);
    var v: [4]Vertex = undefined;
    writeQuad(sprite, &v);
    // With the origin at the bottom-left, `position` *is* the bottom-left corner.
    try testing.expectEqual([2]f32{ 0, 0 }, v[@intFromEnum(Corner.bottom_left)].position);
    try testing.expectEqual([2]f32{ 2, 2 }, v[@intFromEnum(Corner.top_right)].position);
}

test "v = 0 is the top of the texture, so the world flips and the texture does not" {
    var v: [4]Vertex = undefined;
    writeQuad(unitSprite(), &v);
    // The top-left corner of the quad samples the top-left of the region.
    try testing.expectEqual([2]f32{ 0, 0 }, v[@intFromEnum(Corner.top_left)].uv);
    try testing.expectEqual([2]f32{ 1, 1 }, v[@intFromEnum(Corner.bottom_right)].uv);
}

test "a sub-rectangle and its flips address the region, not the whole texture" {
    var sprite = unitSprite();
    sprite.uv = .init(0.25, 0.5, 0.25, 0.25);
    var v: [4]Vertex = undefined;
    writeQuad(sprite, &v);
    try testing.expectEqual([2]f32{ 0.25, 0.5 }, v[@intFromEnum(Corner.top_left)].uv);
    try testing.expectEqual([2]f32{ 0.5, 0.75 }, v[@intFromEnum(Corner.bottom_right)].uv);

    sprite.flip_x = true;
    writeQuad(sprite, &v);
    try testing.expectEqual([2]f32{ 0.5, 0.5 }, v[@intFromEnum(Corner.top_left)].uv);

    sprite.flip_x = false;
    sprite.flip_y = true;
    writeQuad(sprite, &v);
    // Flipping vertically swaps which row the top corner reads, and nothing else.
    try testing.expectEqual([2]f32{ 0.25, 0.75 }, v[@intFromEnum(Corner.top_left)].uv);
}

test "rotation is counter-clockwise about the origin" {
    var sprite = unitSprite();
    sprite.rotation = std.math.pi / 2.0;
    var v: [4]Vertex = undefined;
    writeQuad(sprite, &v);

    // A quarter turn counter-clockwise sends the bottom-right corner to the top-right.
    const br = v[@intFromEnum(Corner.bottom_right)].position;
    try testing.expectApproxEqAbs(@as(f32, 1), br[0], tolerance);
    try testing.expectApproxEqAbs(@as(f32, 1), br[1], tolerance);
}

test "rotation happens about the sprite's own origin, not the world's" {
    var sprite = unitSprite();
    sprite.position = .init(100, 50);
    sprite.rotation = 0.7;
    var v: [4]Vertex = undefined;
    writeQuad(sprite, &v);

    // Whatever the rotation, the four corners stay centred on `position`.
    var sum_x: f32 = 0;
    var sum_y: f32 = 0;
    for (v) |vertex| {
        sum_x += vertex.position[0];
        sum_y += vertex.position[1];
    }
    try testing.expectApproxEqAbs(@as(f32, 100), sum_x / 4, tolerance);
    try testing.expectApproxEqAbs(@as(f32, 50), sum_y / 4, tolerance);
}

test "the index pattern is two triangles sharing the diagonal" {
    var indices: [12]u32 = undefined;
    writeIndices(&indices);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, indices[0..6]);
    // The second quad's indices are offset by four vertices, not by six.
    try testing.expectEqualSlices(u32, &.{ 4, 5, 6, 4, 6, 7 }, indices[6..12]);
}
