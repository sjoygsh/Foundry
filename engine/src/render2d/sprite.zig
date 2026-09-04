//! What a game asks for, and the vertices it becomes.

const std = @import("std");
const core = @import("core");

const color_mod = @import("color.zig");
const texture_mod = @import("texture.zig");
const view_mod = @import("view.zig");

const Color = color_mod.Color;
const BlendMode = color_mod.BlendMode;
const TextureHandle = texture_mod.TextureHandle;
const YAxis = view_mod.YAxis;
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
///
/// In a **Y-down** space the same order is clockwise as seen. That is free today for the
/// same reason, and is written down here so that turning culling on later is one decision
/// about screen-space quads rather than a mystery.
pub const Corner = enum(u2) { bottom_left = 0, bottom_right = 1, top_right = 2, top_left = 3 };

/// Turn one sprite into four vertices, in the space named by `y_axis`.
///
/// Rotation is applied here, on the CPU, to four corners — not by a per-sprite matrix on
/// the GPU. Four rotated points cost eight multiplies; a per-sprite matrix costs a binding
/// and ends the batch, and one draw call for ten thousand sprites is the entire point.
///
/// **`y_axis` is the space's, not the sprite's.** It comes from the view the draw was
/// recorded against (`view.zig`), and it is the only thing that differs between drawing a
/// sprite in the world and drawing the same sprite in a HUD. `origin` keeps meaning the
/// same thing in both: `(0, 0)` is the corner nearest the space's own origin, so a HUD
/// element there sits in the top-left of the window and a world sprite sits above and to
/// the right of the world origin.
pub fn writeQuad(sprite: Sprite, y_axis: YAxis, out: *[vertices_per_quad]Vertex) void {
    const e = localExtents(sprite);
    const x0 = e.x0;
    const x1 = e.x1;
    const y0 = e.y0;
    const y1 = e.y1;

    // Counter-clockwise **as seen**, in both spaces. In a Y-down space the same angle
    // would otherwise turn the other way, and a UI element spinning backwards relative to
    // an identical world sprite is a difference nobody would guess at.
    const rotation = switch (y_axis) {
        .up => sprite.rotation,
        .down => -sprite.rotation,
    };
    const c = @cos(rotation);
    const s = @sin(rotation);

    // UVs are Y-down: `uv.y` is the *top* edge of the region, which is what every one of
    // Metal, Vulkan and D3D means by v = 0 (`rhi.md` §9). The flip between that and a
    // Y-up world lives here and nowhere else.
    var u_left = sprite.uv.x;
    var u_right = sprite.uv.x + sprite.uv.w;
    var v_top = sprite.uv.y;
    var v_bottom = sprite.uv.y + sprite.uv.h;
    if (sprite.flip_x) std.mem.swap(f32, &u_left, &u_right);
    if (sprite.flip_y) std.mem.swap(f32, &v_top, &v_bottom);
    // In a Y-down space the corner at the *smaller* local y is the one on top, so the
    // texture's top row belongs there instead. This one swap is the whole difference
    // between a readable HUD and an upside-down one.
    if (y_axis == .down) std.mem.swap(f32, &v_top, &v_bottom);

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

/// The sprite's own frame: the quad's corners before rotation and before translation.
///
/// Shared by `writeQuad` and `containsPoint` on purpose. Drawing and hit-testing
/// disagreeing about where a sprite is would be a bug you could only find by clicking,
/// and it is avoided by there being one definition rather than two that agree today.
const LocalExtents = struct { x0: f32, x1: f32, y0: f32, y1: f32 };

/// `origin` is normalised, so (0.5, 0.5) centres the quad and (0, 0) puts `position` at
/// its bottom-left.
fn localExtents(sprite: Sprite) LocalExtents {
    return .{
        .x0 = -sprite.origin.x * sprite.size.x,
        .x1 = (1 - sprite.origin.x) * sprite.size.x,
        .y0 = -sprite.origin.y * sprite.size.y,
        .y1 = (1 - sprite.origin.y) * sprite.size.y,
    };
}

/// True when `world_point` falls inside the sprite as drawn — rotation included.
///
/// The answer to "what did I click", once `Camera2D.screenToWorld` has turned the mouse
/// into a world point. It is *geometry*, not a picking system: there is no sprite list to
/// search, because submission is immediate and a sprite becomes vertices the moment it is
/// drawn (`docs/design/render2d.md` §2). The game owns its objects and knows which of them
/// are worth testing; a renderer-side "what is at this point" would have to retain
/// everything in order to answer, which is the design this one deliberately is not.
///
/// Alpha is not consulted. This is the rectangle, so a click in a sprite's transparent
/// corner counts as a hit. Per-pixel picking needs the decoded image kept around and is a
/// different feature with a different cost; when something wants it, it should say so.
pub fn containsPoint(sprite: Sprite, point: Vec2, y_axis: YAxis) bool {
    const e = localExtents(sprite);

    // Into the sprite's own frame: translate, then rotate by `-rotation`, which is exactly
    // the inverse of what `writeQuad` applies to each corner — its sign flip in a Y-down
    // space included, so a UI element is clickable exactly where it is drawn.
    const rotation = switch (y_axis) {
        .up => sprite.rotation,
        .down => -sprite.rotation,
    };
    const dx = point.x - sprite.position.x;
    const dy = point.y - sprite.position.y;
    const c = @cos(-rotation);
    const s = @sin(-rotation);
    const lx = dx * c - dy * s;
    const ly = dx * s + dy * c;

    // `@min`/`@max` rather than assuming `x0 < x1`: a negative size mirrors the quad,
    // which draws fine and would silently never be clickable otherwise. A NaN point
    // fails every comparison and so is a miss, which is the right answer for it.
    return lx >= @min(e.x0, e.x1) and lx <= @max(e.x0, e.x1) and
        ly >= @min(e.y0, e.y1) and ly <= @max(e.y0, e.y1);
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
    writeQuad(unitSprite(), .up, &v);

    try testing.expectEqual([2]f32{ -1, -1 }, v[@intFromEnum(Corner.bottom_left)].position);
    try testing.expectEqual([2]f32{ 1, -1 }, v[@intFromEnum(Corner.bottom_right)].position);
    try testing.expectEqual([2]f32{ 1, 1 }, v[@intFromEnum(Corner.top_right)].position);
    try testing.expectEqual([2]f32{ -1, 1 }, v[@intFromEnum(Corner.top_left)].position);
}

test "origin moves the quad relative to its position, not the other way round" {
    var sprite = unitSprite();
    sprite.origin = .init(0, 0);
    var v: [4]Vertex = undefined;
    writeQuad(sprite, .up, &v);
    // With the origin at the bottom-left, `position` *is* the bottom-left corner.
    try testing.expectEqual([2]f32{ 0, 0 }, v[@intFromEnum(Corner.bottom_left)].position);
    try testing.expectEqual([2]f32{ 2, 2 }, v[@intFromEnum(Corner.top_right)].position);
}

test "v = 0 is the top of the texture, so the world flips and the texture does not" {
    var v: [4]Vertex = undefined;
    writeQuad(unitSprite(), .up, &v);
    // The top-left corner of the quad samples the top-left of the region.
    try testing.expectEqual([2]f32{ 0, 0 }, v[@intFromEnum(Corner.top_left)].uv);
    try testing.expectEqual([2]f32{ 1, 1 }, v[@intFromEnum(Corner.bottom_right)].uv);
}

test "a sub-rectangle and its flips address the region, not the whole texture" {
    var sprite = unitSprite();
    sprite.uv = .init(0.25, 0.5, 0.25, 0.25);
    var v: [4]Vertex = undefined;
    writeQuad(sprite, .up, &v);
    try testing.expectEqual([2]f32{ 0.25, 0.5 }, v[@intFromEnum(Corner.top_left)].uv);
    try testing.expectEqual([2]f32{ 0.5, 0.75 }, v[@intFromEnum(Corner.bottom_right)].uv);

    sprite.flip_x = true;
    writeQuad(sprite, .up, &v);
    try testing.expectEqual([2]f32{ 0.5, 0.5 }, v[@intFromEnum(Corner.top_left)].uv);

    sprite.flip_x = false;
    sprite.flip_y = true;
    writeQuad(sprite, .up, &v);
    // Flipping vertically swaps which row the top corner reads, and nothing else.
    try testing.expectEqual([2]f32{ 0.25, 0.75 }, v[@intFromEnum(Corner.top_left)].uv);
}

test "rotation is counter-clockwise about the origin" {
    var sprite = unitSprite();
    sprite.rotation = std.math.pi / 2.0;
    var v: [4]Vertex = undefined;
    writeQuad(sprite, .up, &v);

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
    writeQuad(sprite, .up, &v);

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

test "a point inside a sprite is a hit and a point outside is not" {
    const sprite = unitSprite(); // 2x2, centred on the origin.
    try testing.expect(containsPoint(sprite, .init(0, 0), .up));
    try testing.expect(containsPoint(sprite, .init(0.99, -0.99), .up));
    try testing.expect(containsPoint(sprite, .init(-1, 1), .up)); // exactly on a corner
    try testing.expect(!containsPoint(sprite, .init(1.01, 0), .up));
    try testing.expect(!containsPoint(sprite, .init(0, -1.01), .up));
    try testing.expect(!containsPoint(sprite, .init(50, 50), .up));
}

test "hit testing respects rotation, and not just the bounding box" {
    // The test that catches forgetting to rotate. Turned 45 degrees, a 2x2 square's own
    // corner is at (1.41, 0) — so the point (0.9, 0.9), comfortably inside the *axis
    // aligned* bounds, is now outside the sprite itself.
    var sprite = unitSprite();
    sprite.rotation = std.math.pi / 4.0;

    try testing.expect(containsPoint(sprite, .init(0, 0), .up));
    try testing.expect(containsPoint(sprite, .init(1.3, 0), .up));
    try testing.expect(!containsPoint(sprite, .init(0.9, 0.9), .up));

    // Unrotated, that same point is inside — so the two answers really do differ.
    sprite.rotation = 0;
    try testing.expect(containsPoint(sprite, .init(0.9, 0.9), .up));
}

test "hit testing agrees with the quad that gets drawn" {
    // Drawing and picking must not drift apart, so this checks them against each other
    // rather than against hand-written coordinates: take the vertices `writeQuad`
    // produces, and probe just inside and just outside each corner along the diagonal.
    const cases = [_]Sprite{
        .{ .texture = .none, .position = .init(0, 0), .size = .init(2, 2) },
        .{ .texture = .none, .position = .init(-30, 12), .size = .init(64, 16) },
        .{ .texture = .none, .position = .init(5, 5), .size = .init(10, 10), .rotation = 0.9 },
        .{ .texture = .none, .position = .init(1, -7), .size = .init(3, 40), .rotation = -2.2 },
        .{ .texture = .none, .position = .init(0, 0), .size = .init(8, 8), .origin = .init(0, 0) },
        .{ .texture = .none, .position = .init(4, 4), .size = .init(8, 2), .origin = .init(1, 0.25), .rotation = 0.3 },
    };

    for (cases) |sprite| {
        var v: [vertices_per_quad]Vertex = undefined;
        writeQuad(sprite, .up, &v);

        var centroid: Vec2 = .zero;
        for (v) |vertex| {
            centroid.x += vertex.position[0] / 4;
            centroid.y += vertex.position[1] / 4;
        }
        try testing.expect(containsPoint(sprite, centroid, .up));

        for (v) |vertex| {
            const corner: Vec2 = .init(vertex.position[0], vertex.position[1]);
            const toward = centroid.sub(corner);
            // Inside the corner by 2% of the diagonal, and outside it by the same.
            try testing.expect(containsPoint(sprite, corner.add(toward.scale(0.02)), .up));
            try testing.expect(!containsPoint(sprite, corner.sub(toward.scale(0.02)), .up));
        }
    }
}

test "origin moves what counts as inside, exactly as it moves what gets drawn" {
    var sprite = unitSprite();
    sprite.origin = .init(0, 0); // `position` is now the bottom-left corner.
    try testing.expect(containsPoint(sprite, .init(0.1, 0.1), .up));
    try testing.expect(containsPoint(sprite, .init(1.9, 1.9), .up));
    try testing.expect(!containsPoint(sprite, .init(-0.1, 0.1), .up));
}

test "a mirrored sprite is still clickable" {
    // A negative extent draws a mirrored quad, which is a legitimate thing to ask for.
    // Testing `x0 <= lx <= x1` without ordering them would make it unhittable.
    var sprite = unitSprite();
    sprite.size = .init(-4, 4);
    try testing.expect(containsPoint(sprite, .init(0, 0), .up));
    try testing.expect(containsPoint(sprite, .init(1.5, 1), .up));
    try testing.expect(containsPoint(sprite, .init(-1.5, 1), .up));
    try testing.expect(!containsPoint(sprite, .init(3, 0), .up));
}

test "a degenerate sprite is a miss, not a crash" {
    var sprite = unitSprite();
    sprite.size = .zero;
    try testing.expect(containsPoint(sprite, .init(0, 0), .up)); // the single point it is
    try testing.expect(!containsPoint(sprite, .init(0.01, 0), .up));

    // Nonsense coordinates arrive from content and from scripts. They miss.
    const nan = std.math.nan(f32);
    try testing.expect(!containsPoint(unitSprite(), .init(nan, 0), .up));
    try testing.expect(!containsPoint(unitSprite(), .init(0, nan), .up));
}

test "a Y-down space puts the texture's top row at the top of the screen" {
    // The bug this parameter exists to prevent: without it a HUD draws upside down, and
    // the symptom looks like a broken font rather than a wrong space.
    var sprite = unitSprite();
    sprite.uv = .init(0, 0, 1, 1);

    var up: [vertices_per_quad]Vertex = undefined;
    writeQuad(sprite, .up, &up);
    var down: [vertices_per_quad]Vertex = undefined;
    writeQuad(sprite, .down, &down);

    // In both spaces the vertex nearest the top of the screen must carry v = 0. "Nearest
    // the top" is the largest y in a Y-up space and the smallest in a Y-down one.
    var up_top: usize = 0;
    for (up, 0..) |v, i| if (v.position[1] > up[up_top].position[1]) {
        up_top = i;
    };
    var down_top: usize = 0;
    for (down, 0..) |v, i| if (v.position[1] < down[down_top].position[1]) {
        down_top = i;
    };

    try testing.expectApproxEqAbs(@as(f32, 0), up[up_top].uv[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), down[down_top].uv[1], 1e-6);
}

test "the positions themselves are the same in both spaces" {
    // Only the texture mapping and the rotation direction differ. `origin` is normalised
    // against the space's own direction, so `(0, 0)` is the corner nearest that space's
    // origin in both — and the corner *coordinates* therefore come out identical.
    var sprite = unitSprite();
    sprite.rotation = 0;

    var up: [vertices_per_quad]Vertex = undefined;
    writeQuad(sprite, .up, &up);
    var down: [vertices_per_quad]Vertex = undefined;
    writeQuad(sprite, .down, &down);

    for (up, down) |a, b| {
        try testing.expectApproxEqAbs(a.position[0], b.position[0], 1e-6);
        try testing.expectApproxEqAbs(a.position[1], b.position[1], 1e-6);
    }
}

test "a positive rotation turns the same way on screen in both spaces" {
    // Stated as what a person would see rather than as an identity between matrices: the
    // corner to the right of the origin must swing *upward on the display* in both.
    var sprite = unitSprite();
    sprite.position = .zero;
    sprite.size = .init(1, 1);
    sprite.origin = .init(0, 0);
    sprite.rotation = 0.3;

    var up: [vertices_per_quad]Vertex = undefined;
    writeQuad(sprite, .up, &up);
    var down: [vertices_per_quad]Vertex = undefined;
    writeQuad(sprite, .down, &down);

    // Corner 1 is `bottom_right`, which with this origin starts at (1, 0).
    const right = @intFromEnum(Corner.bottom_right);
    // Y-up: upward on the display is a larger y.
    try testing.expect(up[right].position[1] > 0);
    // Y-down: upward on the display is a *smaller* y. Same apparent direction, opposite
    // sign — which is exactly what the flip inside `writeQuad` is for.
    try testing.expect(down[right].position[1] < 0);
    // And by the same magnitude, so it is a mirror rather than a different angle.
    try testing.expectApproxEqAbs(up[right].position[1], -down[right].position[1], 1e-6);
}

test "hit testing agrees with the quad in a Y-down space too" {
    // The same property the Y-up test checks, and the one a UI needs: a button is
    // clickable exactly where it was drawn.
    var rng: core.rng.Pcg32 = .init(0xD0_1234, 3);
    for (0..64) |_| {
        var sprite = unitSprite();
        sprite.position = .init((rng.float01() - 0.5) * 40, (rng.float01() - 0.5) * 40);
        sprite.size = .init(1 + rng.float01() * 8, 1 + rng.float01() * 8);
        sprite.rotation = (rng.float01() - 0.5) * 6;
        sprite.origin = .init(rng.float01(), rng.float01());

        var v: [vertices_per_quad]Vertex = undefined;
        writeQuad(sprite, .down, &v);

        var centroid: Vec2 = .zero;
        for (v) |vertex| centroid = centroid.add(.init(vertex.position[0], vertex.position[1]));
        centroid = centroid.scale(1.0 / @as(f32, vertices_per_quad));
        try testing.expect(containsPoint(sprite, centroid, .down));

        for (v) |vertex| {
            const corner: Vec2 = .init(vertex.position[0], vertex.position[1]);
            const toward = centroid.sub(corner);
            try testing.expect(containsPoint(sprite, corner.add(toward.scale(0.02)), .down));
            try testing.expect(!containsPoint(sprite, corner.sub(toward.scale(0.02)), .down));
        }
    }
}
