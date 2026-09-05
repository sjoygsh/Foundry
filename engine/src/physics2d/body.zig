//! Bodies: what the world holds, and the filter that decides which pairs are considered.

const std = @import("std");
const core = @import("core");

const shape_mod = @import("shape.zig");

const Bounds = shape_mod.Bounds;
const Shape = shape_mod.Shape;
const Vec2 = core.math.Vec2;

/// Phantom tag for `BodyHandle`. Never instantiated (I1).
pub const Bodies = opaque {};

/// How a body is addressed everywhere outside this module.
pub const BodyHandle = core.Handle(Bodies);

pub const BodyKind = enum {
    /// Solid, and expected not to move often. It may still be repositioned — a door opening —
    /// and "static" describes a frequency rather than a prohibition
    /// (`tilemaps-and-collision.md` §2).
    static,
    /// Solid, and moved by the game through `moveAndSlide`.
    movable,
    /// Not solid. Reports overlap, blocks nothing.
    trigger,
};

pub const Body = struct {
    shape: Shape,
    /// The shape's **centre**, always. Not a corner, not an origin the game chose.
    position: Vec2,
    kind: BodyKind,
    /// Which layer this body is on. One bit, conventionally.
    layer: u32 = 1,
    /// Which layers it collides with. Any bits.
    mask: u32 = ~@as(u32, 0),
    /// Opaque. The game's own identifier, never interpreted here.
    ///
    /// **This is the entire coupling between `physics2d` and the rest of the engine.** The
    /// module cannot name an `Entity` — `scene` is above it — so a game stores `entity.bits()`
    /// here and reads it back out of a contact. Sixty-four bits wide, which is what a
    /// generational handle costs, and why collision works with no ECS at all.
    user: u64 = 0,

    pub fn bounds(self: Body) Bounds {
        return self.shape.bounds(self.position);
    }
};

/// Whether two bodies' filters admit the pair.
///
/// **Symmetric on purpose**: both sides must agree. A one-sided filter produces the situation
/// where A is pushed by B but B is not pushed by A, which looks like a physics bug and is
/// really a content mistake nobody can see (`tilemaps-and-collision.md` §2).
///
/// Plain integers rather than a registry of named layers, because a filter a mod has to
/// register is a filter that fails at load time instead of at compile time.
pub fn filtersAdmit(a: Body, b: Body) bool {
    return a.mask & b.layer != 0 and b.mask & a.layer != 0;
}

/// Whether a query with `mask` considers `body`.
///
/// One-sided, and that is not an inconsistency with `filtersAdmit`: a query is not a body and
/// has no layer of its own, so there is no second side to agree.
pub fn maskAdmits(mask: u32, body: Body) bool {
    return mask & body.layer != 0;
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

fn bodyOn(layer: u32, mask: u32) Body {
    return .{
        .shape = .{ .box = .{ .x = 1, .y = 1 } },
        .position = .zero,
        .kind = .movable,
        .layer = layer,
        .mask = mask,
    };
}

test "the filter is symmetric, so a one-sided pairing cannot happen" {
    const player = bodyOn(0b001, 0b010);
    const wall = bodyOn(0b010, 0b001);
    try testing.expect(filtersAdmit(player, wall));
    try testing.expect(filtersAdmit(wall, player));

    // The wall stops caring about the player. Neither direction survives.
    const deaf_wall = bodyOn(0b010, 0b100);
    try testing.expect(!filtersAdmit(player, deaf_wall));
    try testing.expect(!filtersAdmit(deaf_wall, player));
}

test "a query mask has only one side to satisfy" {
    const wall = bodyOn(0b010, 0b000);
    try testing.expect(maskAdmits(0b010, wall));
    try testing.expect(!maskAdmits(0b001, wall));
    // The body's own mask is empty and the query still finds it: a query asks where things
    // are, it does not collide with them.
    try testing.expect(maskAdmits(~@as(u32, 0), wall));
}

test "a body's bounds follow its shape and centre" {
    var body = bodyOn(1, 1);
    body.position = .{ .x = 10, .y = -4 };
    const b = body.bounds();
    try testing.expectEqual(@as(f32, 9), b.min.x);
    try testing.expectEqual(@as(f32, -5), b.min.y);
    try testing.expectEqual(@as(f32, 11), b.max.x);
    try testing.expectEqual(@as(f32, -3), b.max.y);
}

test "a body handle is the generational kind, and none is not a body" {
    try testing.expect(BodyHandle.none.isNone());
    try testing.expectEqual(@as(usize, 8), @sizeOf(BodyHandle));
}
