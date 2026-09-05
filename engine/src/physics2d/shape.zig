//! Shapes, bounds, and the closed-form tests between them.
//!
//! Every test here is a **Minkowski** formulation: the pair is reduced to one shape versus a
//! point, which is why `Shape.box` carries half-extents rather than corners
//! (`tilemaps-and-collision.md` §3). Half-extents make the reduction a sum; corners would make
//! it four subtractions at every call site.
//!
//! Nothing here iterates and nothing here converges. Four static pair tests and one swept test
//! against an axis-aligned box, all closed-form, which is what ADR-0022's scope buys.

const std = @import("std");
const core = @import("core");

const Vec2 = core.math.Vec2;

/// The closed set of shapes `physics2d` understands.
///
/// A convex polygon is the obvious next member and is deliberately absent (ADR-0022). Adding
/// it changes no signature, because every entry point in the module takes a `Shape`.
pub const Shape = union(enum) {
    /// Half-extents. The body's position is always the shape's **centre**.
    box: Vec2,
    /// Radius.
    circle: f32,

    /// The half-extents of the shape's axis-aligned bounding box.
    pub fn halfExtents(self: Shape) Vec2 {
        return switch (self) {
            .box => |half| half,
            .circle => |radius| .{ .x = radius, .y = radius },
        };
    }

    pub fn bounds(self: Shape, at: Vec2) Bounds {
        const half = self.halfExtents();
        return .{ .min = at.sub(half), .max = at.add(half) };
    }

    /// Whether this shape is one the module can compute with.
    ///
    /// **Checked, not asserted.** A shape reaches this module from a game, and from M7 from a
    /// mod, so a zero-size box or a NaN radius is invalid input rather than a broken
    /// invariant (CLAUDE.md §7). A degenerate shape is refused at the boundary — `World.addBody`
    /// — so that nothing below has to defend against one.
    pub fn isValid(self: Shape) bool {
        return switch (self) {
            .box => |half| isPositiveFinite(half.x) and isPositiveFinite(half.y),
            .circle => |radius| isPositiveFinite(radius),
        };
    }
};

fn isPositiveFinite(value: f32) bool {
    return value > 0 and std.math.isFinite(value);
}

/// An axis-aligned box, as a min/max pair.
///
/// Distinct from `Shape.box` on purpose: a `Shape` is something a body *is*, and a `Bounds` is
/// a rectangle the module computes about one. Conflating them is how half-extents and corners
/// end up meaning the same field.
pub const Bounds = struct {
    min: Vec2,
    max: Vec2,

    pub fn fromCenter(center: Vec2, half: Vec2) Bounds {
        return .{ .min = center.sub(half), .max = center.add(half) };
    }

    pub fn overlaps(a: Bounds, b: Bounds) bool {
        return a.min.x < b.max.x and a.max.x > b.min.x and
            a.min.y < b.max.y and a.max.y > b.min.y;
    }

    pub fn contains(self: Bounds, p: Vec2) bool {
        return p.x >= self.min.x and p.x <= self.max.x and
            p.y >= self.min.y and p.y <= self.max.y;
    }

    pub fn merge(a: Bounds, b: Bounds) Bounds {
        return .{
            .min = .{ .x = @min(a.min.x, b.min.x), .y = @min(a.min.y, b.min.y) },
            .max = .{ .x = @max(a.max.x, b.max.x), .y = @max(a.max.y, b.max.y) },
        };
    }

    /// Grown by `half` on every side — the Minkowski sum with a box of those half-extents.
    pub fn expand(self: Bounds, half: Vec2) Bounds {
        return .{ .min = self.min.sub(half), .max = self.max.add(half) };
    }

    /// The bounds of this box swept along `motion`: everything it could touch on the way.
    pub fn sweptBy(self: Bounds, motion: Vec2) Bounds {
        const moved: Bounds = .{ .min = self.min.add(motion), .max = self.max.add(motion) };
        return self.merge(moved);
    }
};

/// A resolved overlap between two shapes.
///
/// **`normal` points from `b` toward `a`**: moving `a` by `normal.scale(depth)` separates the
/// pair, touching exactly. Every normal this module produces uses that convention, including
/// the grid's, where the cell plays the part of `b`.
pub const Contact = struct {
    normal: Vec2,
    depth: f32,
};

/// The static test between any two shapes, or null when they do not overlap.
///
/// Touching exactly is **not** an overlap. That matters more than it looks: a body resting
/// flush against a wall must not report a contact every tick, and `moveAndSlide` deliberately
/// stops bodies flush against what they hit.
pub fn overlap(a: Shape, a_at: Vec2, b: Shape, b_at: Vec2) ?Contact {
    return switch (a) {
        .box => |a_half| switch (b) {
            .box => |b_half| boxBox(a_at, a_half, b_at, b_half),
            .circle => |b_radius| boxCircle(a_at, a_half, b_at, b_radius),
        },
        .circle => |a_radius| switch (b) {
            // The flip, rather than a fourth body of arithmetic that can disagree with the
            // third. `boxCircle` answers for the box as `a`, so the normal is negated back.
            .box => |b_half| flip(boxCircle(b_at, b_half, a_at, a_radius)),
            .circle => |b_radius| circleCircle(a_at, a_radius, b_at, b_radius),
        },
    };
}

fn flip(contact: ?Contact) ?Contact {
    const c = contact orelse return null;
    return .{ .normal = c.normal.neg(), .depth = c.depth };
}

fn boxBox(a_at: Vec2, a_half: Vec2, b_at: Vec2, b_half: Vec2) ?Contact {
    const delta = a_at.sub(b_at);
    const combined = a_half.add(b_half);

    const overlap_x = combined.x - @abs(delta.x);
    if (overlap_x <= 0) return null;
    const overlap_y = combined.y - @abs(delta.y);
    if (overlap_y <= 0) return null;

    // The axis of minimum penetration, which is the shortest way out. Ties go to X, so the
    // answer for a perfectly square overlap is a stated one rather than whichever comparison
    // the optimiser happened to emit (I9 rule 5 is about pointers; the same discipline).
    if (overlap_x <= overlap_y) {
        return .{ .normal = .{ .x = if (delta.x < 0) -1 else 1, .y = 0 }, .depth = overlap_x };
    }
    return .{ .normal = .{ .x = 0, .y = if (delta.y < 0) -1 else 1 }, .depth = overlap_y };
}

fn circleCircle(a_at: Vec2, a_radius: f32, b_at: Vec2, b_radius: f32) ?Contact {
    const delta = a_at.sub(b_at);
    const combined = a_radius + b_radius;
    const distance_squared = delta.lengthSquared();
    if (distance_squared >= combined * combined) return null;

    // Concentric circles have no separating direction, so one is chosen rather than dividing
    // by zero. +X because it has to be something, and something documented beats something
    // that depends on the input's last bit.
    if (distance_squared == 0) return .{ .normal = .{ .x = 1, .y = 0 }, .depth = combined };

    const distance = @sqrt(distance_squared);
    return .{ .normal = delta.scale(1 / distance), .depth = combined - distance };
}

/// The box is `a`, so the normal points from the circle toward the box.
fn boxCircle(box_at: Vec2, box_half: Vec2, circle_at: Vec2, radius: f32) ?Contact {
    const min = box_at.sub(box_half);
    const max = box_at.add(box_half);

    const closest: Vec2 = .{
        .x = std.math.clamp(circle_at.x, min.x, max.x),
        .y = std.math.clamp(circle_at.y, min.y, max.y),
    };

    if (!closest.eql(circle_at)) {
        // Centre outside the box. `closest` is the part of the box nearest the circle, so
        // moving the box along `closest - centre` is moving it away.
        const delta = closest.sub(circle_at);
        const distance_squared = delta.lengthSquared();
        if (distance_squared >= radius * radius) return null;
        const distance = @sqrt(distance_squared);
        return .{ .normal = delta.scale(1 / distance), .depth = radius - distance };
    }

    // Centre inside the box. The circle leaves through the nearest face, so the box moves the
    // other way — the face's distance plus the whole radius.
    const to_min_x = circle_at.x - min.x;
    const to_max_x = max.x - circle_at.x;
    const to_min_y = circle_at.y - min.y;
    const to_max_y = max.y - circle_at.y;

    var best = to_min_x;
    var normal: Vec2 = .{ .x = 1, .y = 0 };
    if (to_max_x < best) {
        best = to_max_x;
        normal = .{ .x = -1, .y = 0 };
    }
    if (to_min_y < best) {
        best = to_min_y;
        normal = .{ .x = 0, .y = 1 };
    }
    if (to_max_y < best) {
        best = to_max_y;
        normal = .{ .x = 0, .y = -1 };
    }
    return .{ .normal = normal, .depth = best + radius };
}

/// Which face of an axis-aligned box a sweep entered through.
pub const Face = enum { neg_x, pos_x, neg_y, pos_y };

/// A face set, used to ignore faces that are interior to a wall (`grid.zig`).
pub const FaceMask = packed struct(u4) {
    neg_x: bool = true,
    pos_x: bool = true,
    neg_y: bool = true,
    pos_y: bool = true,

    pub const all: FaceMask = .{};

    pub fn has(self: FaceMask, face: Face) bool {
        return switch (face) {
            .neg_x => self.neg_x,
            .pos_x => self.pos_x,
            .neg_y => self.neg_y,
            .pos_y => self.pos_y,
        };
    }
};

/// The result of a swept test.
///
/// **A zero `normal` means the sweep started already overlapping**, and `fraction` is then 0.
/// That is a distinct answer from a hit at fraction 0, and callers must treat it as one: a
/// sweep cannot resolve a penetration that is behind it, which is why depenetration is a
/// separate call (`tilemaps-and-collision.md` §6).
pub const Sweep = struct {
    fraction: f32,
    normal: Vec2,
    face: ?Face,

    pub fn startedInside(self: Sweep) bool {
        return self.face == null;
    }
};

/// Sweeps a box of half-extents `half` from `from` along `motion` against the box `target`.
///
/// The Minkowski reduction: `target` is grown by `half` and the moving box becomes the ray
/// `from + t * motion`. One slab test, no iteration.
///
/// Two conventions, both chosen so that a body sliding along a flat wall reports nothing:
///
/// * A sweep that only *grazes* — entering and leaving at the same instant — is a miss.
/// * On an axis with no motion, being exactly on the slab boundary counts as outside.
///
/// The alternative convention would report a contact for a body flush against a wall and
/// moving parallel to it, every cell, every tick. The case it gives up in exchange — motion
/// exactly along a face plane, straight at the wall — is unreachable in practice because
/// `moveAndSlide` stops a body an epsilon short of what it hits.
pub fn sweepBox(half: Vec2, from: Vec2, motion: Vec2, target: Bounds) ?Sweep {
    const expanded = target.expand(half);

    var t_near: f32 = -std.math.inf(f32);
    var t_far: f32 = std.math.inf(f32);
    var face: ?Face = null;

    inline for (0..2) |i| {
        const origin = if (i == 0) from.x else from.y;
        const delta = if (i == 0) motion.x else motion.y;
        const lo = if (i == 0) expanded.min.x else expanded.min.y;
        const hi = if (i == 0) expanded.max.x else expanded.max.y;

        if (delta == 0) {
            if (origin <= lo or origin >= hi) return null;
        } else {
            const inverse = 1 / delta;
            var enter = (lo - origin) * inverse;
            var exit = (hi - origin) * inverse;
            var entered: Face = if (i == 0) .neg_x else .neg_y;
            if (enter > exit) {
                const swap = enter;
                enter = exit;
                exit = swap;
                entered = if (i == 0) .pos_x else .pos_y;
            }
            if (enter > t_near) {
                t_near = enter;
                face = entered;
            }
            t_far = @min(t_far, exit);
        }
    }

    if (t_near >= t_far) return null;
    if (t_near > 1 or t_far < 0) return null;
    // Already inside when the sweep began. Reported rather than clamped, so that the caller
    // can tell "stuck" from "hit immediately" and reach for `resolveOverlaps` instead.
    if (t_near < 0) return .{ .fraction = 0, .normal = .zero, .face = null };

    const f = face orelse return null;
    return .{ .fraction = t_near, .normal = normalOf(f), .face = f };
}

pub fn normalOf(face: Face) Vec2 {
    return switch (face) {
        .neg_x => .{ .x = -1, .y = 0 },
        .pos_x => .{ .x = 1, .y = 0 },
        .neg_y => .{ .x = 0, .y = -1 },
        .pos_y => .{ .x = 0, .y = 1 },
    };
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

fn v(x: f32, y: f32) Vec2 {
    return .{ .x = x, .y = y };
}

test "a shape from content is validated rather than trusted" {
    try testing.expect((Shape{ .box = v(1, 1) }).isValid());
    try testing.expect((Shape{ .circle = 0.5 }).isValid());

    try testing.expect(!(Shape{ .box = v(0, 1) }).isValid());
    try testing.expect(!(Shape{ .box = v(1, -1) }).isValid());
    try testing.expect(!(Shape{ .circle = 0 }).isValid());
    try testing.expect(!(Shape{ .circle = std.math.nan(f32) }).isValid());
    try testing.expect(!(Shape{ .box = v(std.math.inf(f32), 1) }).isValid());
}

test "bounds sweep covers both ends and everything between" {
    const start: Bounds = .fromCenter(v(0, 0), v(1, 1));
    const swept = start.sweptBy(v(4, -2));
    try testing.expectEqual(v(-1, -3), swept.min);
    try testing.expectEqual(v(5, 1), swept.max);
}

test "box against box resolves along the shallower axis" {
    // Overlapping by 0.5 in x and 1.5 in y, so the way out is x.
    const contact = boxBox(v(1.5, 0), v(1, 1), v(0, 0), v(1, 1)).?;
    try testing.expectEqual(v(1, 0), contact.normal);
    try testing.expectApproxEqAbs(@as(f32, 0.5), contact.depth, 1e-6);

    // ...and the mirror image points the other way.
    const mirrored = boxBox(v(-1.5, 0), v(1, 1), v(0, 0), v(1, 1)).?;
    try testing.expectEqual(v(-1, 0), mirrored.normal);
}

test "touching exactly is not an overlap" {
    // A body resting flush against a wall must report nothing, every tick, forever.
    try testing.expectEqual(@as(?Contact, null), boxBox(v(2, 0), v(1, 1), v(0, 0), v(1, 1)));
    try testing.expectEqual(@as(?Contact, null), circleCircle(v(2, 0), 1, v(0, 0), 1));
    try testing.expectEqual(@as(?Contact, null), boxCircle(v(0, 0), v(1, 1), v(2, 0), 1));
}

test "circle against circle, including the concentric case" {
    const contact = circleCircle(v(1, 0), 1, v(0, 0), 1).?;
    try testing.expectEqual(v(1, 0), contact.normal);
    try testing.expectApproxEqAbs(@as(f32, 1), contact.depth, 1e-6);

    const concentric = circleCircle(v(3, 3), 2, v(3, 3), 1).?;
    try testing.expectEqual(v(1, 0), concentric.normal);
    try testing.expectApproxEqAbs(@as(f32, 3), concentric.depth, 1e-6);
}

test "box against circle, outside and inside" {
    // Circle centre to the right of the box, overlapping by 0.25.
    const outside = boxCircle(v(0, 0), v(1, 1), v(1.75, 0), 1).?;
    try testing.expectEqual(v(-1, 0), outside.normal);
    try testing.expectApproxEqAbs(@as(f32, 0.25), outside.depth, 1e-6);

    // Centre inside, nearest the box's -y face, so the box escapes upward.
    const inside = boxCircle(v(0, 0), v(2, 2), v(0, -1.5), 0.5).?;
    try testing.expectEqual(v(0, 1), inside.normal);
    try testing.expectApproxEqAbs(@as(f32, 1), inside.depth, 1e-6);
}

test "the pair test is symmetric under swapping its arguments" {
    // The circle-versus-box case is the flip of the box-versus-circle one rather than its own
    // arithmetic, and this is what says the two agree.
    const box: Shape = .{ .box = v(1, 1) };
    const circle: Shape = .{ .circle = 1 };

    const forward = overlap(box, v(0, 0), circle, v(1.5, 0)).?;
    const reverse = overlap(circle, v(1.5, 0), box, v(0, 0)).?;
    try testing.expectEqual(forward.normal.neg(), reverse.normal);
    try testing.expectApproxEqAbs(forward.depth, reverse.depth, 1e-6);
}

test "moving a body by the contact leaves it exactly touching" {
    // The property that makes `Contact` usable: applying it separates, and separating twice
    // does not push further.
    const a: Shape = .{ .box = v(1, 1) };
    const b: Shape = .{ .box = v(1, 1) };
    const contact = overlap(a, v(1.25, 0), b, v(0, 0)).?;
    const separated = v(1.25, 0).add(contact.normal.scale(contact.depth));
    try testing.expectEqual(@as(?Contact, null), overlap(a, separated, b, v(0, 0)));
}

test "a sweep reports the face it entered through" {
    const target: Bounds = .fromCenter(v(5, 0), v(1, 1));
    const hit = sweepBox(v(0.5, 0.5), v(0, 0), v(10, 0), target).?;
    // The expanded box starts at x = 3.5, so half the requested motion.
    try testing.expectApproxEqAbs(@as(f32, 0.35), hit.fraction, 1e-6);
    try testing.expectEqual(v(-1, 0), hit.normal);
    try testing.expectEqual(Face.neg_x, hit.face.?);
    try testing.expect(!hit.startedInside());
}

test "a sweep that stops short of the target misses" {
    const target: Bounds = .fromCenter(v(5, 0), v(1, 1));
    try testing.expectEqual(@as(?Sweep, null), sweepBox(v(0.5, 0.5), v(0, 0), v(3, 0), target));
}

test "sliding flush along a wall reports nothing" {
    // The convention that matters most in a tile game. The mover's right edge is exactly on
    // the wall's left face and it is travelling straight up.
    const wall: Bounds = .{ .min = v(1, -100), .max = v(3, 100) };
    try testing.expectEqual(@as(?Sweep, null), sweepBox(v(0.5, 0.5), v(0.5, 0), v(0, 10), wall));
}

test "a sweep that begins inside says so instead of pretending to hit" {
    const target: Bounds = .fromCenter(v(0, 0), v(1, 1));
    const hit = sweepBox(v(0.5, 0.5), v(0, 0), v(1, 0), target).?;
    try testing.expect(hit.startedInside());
    try testing.expectEqual(@as(f32, 0), hit.fraction);
    try testing.expectEqual(Vec2.zero, hit.normal);
}

test "a face mask names faces rather than indices" {
    var mask: FaceMask = .all;
    try testing.expect(mask.has(.neg_x));
    mask.neg_x = false;
    try testing.expect(!mask.has(.neg_x));
    try testing.expect(mask.has(.pos_x));
}
