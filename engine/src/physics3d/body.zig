//! Bodies, and the filter that decides which pairs and queries consider each other.

const std = @import("std");
const core = @import("core");

const shape_mod = @import("shape.zig");

const Pose = shape_mod.Pose;
const Shape = shape_mod.Shape;
const Vec3 = core.math.Vec3;

/// Phantom tag for `BodyHandle`. Never instantiated (I1).
pub const Bodies = opaque {};

/// How a body is addressed everywhere outside this module.
pub const BodyHandle = core.Handle(Bodies);

pub const BodyKind = enum {
    /// Solid and expected not to move often. `setPose` may still move one, as a teleport:
    /// "static" describes a frequency, not a prohibition.
    static,
    /// Solid, and moved by the caller's casts or by a character.
    kinematic,
};

/// There is no trigger kind (`collision3d.md` §3). A trigger is a body on a layer the character's
/// mask omits: it blocks nothing, and an overlap query whose mask includes that layer finds it.
pub const Body = struct {
    shape: Shape,
    pose: Pose = .identity,
    kind: BodyKind = .static,
    /// Which layer this body is on. One bit, conventionally.
    layer: u32 = 1,
    /// Which layers it collides with. Any bits.
    mask: u32 = ~@as(u32, 0),
    /// Opaque: the game's own identifier, `entity.bits()` in practice. The whole coupling
    /// between `physics3d` and the rest of the engine, as in `physics2d`.
    user: u64 = 0,
    /// A mesh's or hull's size at runtime (`collision-extras.md` §4), applied before the pose,
    /// which stays rigid. Non-uniform, each axis in [`min_scale`, `max_scale`]; any other shape
    /// says its size in its own dimensions and refuses a scale but one.
    scale: Vec3 = .one,
    /// What the body is made of (`collision-extras.md` §6): a content ID every hit on it reports,
    /// and `physics3d` never interprets (I5). A mesh triangle's own surface wins over it.
    surface: core.ContentId = .none,
    /// How a character's move pushes it (`collision-extras.md` §8): a ratio in [0, 1], 0 for not
    /// at all. Only a kinematic body may be pushed, since a push is a `World.moveBody`.
    push: f32 = 0,
    /// Kept by the world, and whatever `addBody` is given is replaced: the body's last motion,
    /// from the pose before its last `moveBody` to the one after, and a serial counting its moves
    /// (§7). A character standing on it is carried by the motion when the serial is new to it.
    motion: Motion = .{},
    serial: u32 = 0,
};

/// A body's last move, from one pose to the next (`collision-extras.md` §7).
pub const Motion = struct {
    from: Pose = .identity,
    to: Pose = .identity,
};

/// Whether a body may have `push`: a ratio in [0, 1], and none but 0 on a static body.
pub fn pushValid(kind: BodyKind, push: f32) bool {
    if (!std.math.isFinite(push) or push < 0 or push > 1) return false;
    return push == 0 or kind == .kinematic;
}

pub const min_scale: f32 = 0.01;
pub const max_scale: f32 = 100;

/// Whether `scale` may be given to `shape`.
pub fn scaleValid(shape: Shape, scale: Vec3) bool {
    if (!scale.isFinite()) return false;
    const unit = scale.eql(Vec3.one);
    return switch (shape) {
        .mesh, .hull => within(scale.x) and within(scale.y) and within(scale.z),
        else => unit,
    };
}

fn within(v: f32) bool {
    return v >= min_scale and v <= max_scale;
}

/// Whether two bodies admit each other. **Symmetric**: both sides must agree, as in 2D.
pub fn filtersAdmit(a: Body, b: Body) bool {
    return a.mask & b.layer != 0 and b.mask & a.layer != 0;
}

/// Whether a query with `mask` considers `body`. One-sided: a query has no layer of its own.
pub fn maskAdmits(mask: u32, body: Body) bool {
    return mask & body.layer != 0;
}

/// What a query or a cast considers.
pub const Filter = struct {
    mask: u32 = ~@as(u32, 0),
    /// A body to leave out — the one doing the asking, typically.
    ignore: ?BodyHandle = null,
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

fn on(layer: u32, mask: u32) Body {
    return .{ .shape = .{ .sphere = .{ .radius = 1 } }, .layer = layer, .mask = mask };
}

test "the pair filter is symmetric" {
    const player = on(0b001, 0b010);
    const wall = on(0b010, 0b001);
    try testing.expect(filtersAdmit(player, wall) and filtersAdmit(wall, player));
    const deaf = on(0b010, 0b100);
    try testing.expect(!filtersAdmit(player, deaf) and !filtersAdmit(deaf, player));
}

test "a query mask has one side, and a body's own mask does not hide it" {
    const wall = on(0b010, 0);
    try testing.expect(maskAdmits(0b010, wall));
    try testing.expect(!maskAdmits(0b001, wall));
}

test "a body handle is the generational kind" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(BodyHandle));
    try testing.expect(BodyHandle.none.isNone());
}
