//! Shapes, bounds, and the closed-form tests between them.
//!
//! Every test here is a **Minkowski** formulation: the pair is reduced to one shape versus a
//! point, which is why `Shape.box` carries half-extents rather than corners
//! (`tilemaps-and-collision.md` §3). Half-extents make the reduction a sum; corners would make
//! it four subtractions at every call site.
//!
//! Nothing here iterates and nothing here converges. The reduction composes, so there is one
//! static test and one swept test — against a `Rounded`, the sum of the pair — and every shape
//! combination, plus a raycast, is that pair of functions asked a different question. That is
//! what ADR-0022's closed shape set buys.

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

    pub fn fromCenter(at: Vec2, half: Vec2) Bounds {
        return .{ .min = at.sub(half), .max = at.add(half) };
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

    pub fn center(self: Bounds) Vec2 {
        return self.min.add(self.max).scale(0.5);
    }

    pub fn halfExtents(self: Bounds) Vec2 {
        return self.max.sub(self.min).scale(0.5);
    }

    /// The bounds of this box swept along `motion`: everything it could touch on the way.
    pub fn sweptBy(self: Bounds, motion: Vec2) Bounds {
        const moved: Bounds = .{ .min = self.min.add(motion), .max = self.max.add(motion) };
        return self.merge(moved);
    }
};

/// A rounded box: the Minkowski sum of an axis-aligned box with a disc.
///
/// **This is the one shape the module actually computes with.** Every pair in `Shape` reduces
/// to one, and the reduction composes — the sum of two rounded boxes is a rounded box whose
/// half-extents and radius are the sums — so the four pair tests, the swept tests and a
/// raycast are all one implementation asked different questions:
///
/// | moving | target | obstacle |
/// | --- | --- | --- |
/// | box | box | `{ half = ha + hb, radius = 0 }` — a plain box |
/// | box | circle | `{ half = ha, radius = rb }` |
/// | circle | box | `{ half = hb, radius = ra }` |
/// | circle | circle | `{ half = 0, radius = ra + rb }` — a disc |
/// | *a point* | anything | the target's own rounded form |
///
/// The alternative — a body of arithmetic per pair — is what `flip` used to exist to guard
/// against, and this removes the thing it was guarding.
pub const Rounded = struct {
    half: Vec2 = .zero,
    radius: f32 = 0,

    /// A point. What a raycast sweeps.
    pub const point: Rounded = .{};

    pub fn of(s: Shape) Rounded {
        return switch (s) {
            .box => |half| .{ .half = half, .radius = 0 },
            .circle => |radius| .{ .half = .zero, .radius = radius },
        };
    }

    /// The Minkowski sum. Both members are symmetric about their centre, so no reflection is
    /// needed and configuration space is this sum rather than a difference.
    pub fn sum(a: Rounded, b: Rounded) Rounded {
        return .{ .half = a.half.add(b.half), .radius = a.radius + b.radius };
    }

    /// The half-extents of the bounding box.
    pub fn halfExtents(self: Rounded) Vec2 {
        return .{ .x = self.half.x + self.radius, .y = self.half.y + self.radius };
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
    return overlapRounded(Rounded.of(a).sum(Rounded.of(b)), a_at, b_at, .all);
}

/// Whether `p` is inside the rounded box `o` centred at `center`, and the shortest push out.
///
/// The normal points from the obstacle toward `p`, which is the `Contact` convention with the
/// obstacle playing the part of `b`.
///
/// `faces` restricts which directions the push may take, and exists for the grid: pushing out
/// of the middle of a wall along an interior face would move the body *further* into the wall.
/// A diagonal push through a corner requires **both** of its adjacent faces, because a corner
/// whose neighbour in either direction is solid is inside the wall's surface, not on it.
pub fn overlapRounded(o: Rounded, p: Vec2, center: Vec2, faces: FaceMask) ?Contact {
    const d = p.sub(center);
    const nearest: Vec2 = .{
        .x = std.math.clamp(d.x, -o.half.x, o.half.x),
        .y = std.math.clamp(d.y, -o.half.y, o.half.y),
    };
    const delta = d.sub(nearest);
    const distance_squared = delta.lengthSquared();

    if (distance_squared > 0) {
        // Outside the core box: the overlap, if there is one, is with the rounded skirt, and
        // the way out is directly away from the nearest point on the box.
        if (distance_squared >= o.radius * o.radius) return null;
        const distance = @sqrt(distance_squared);
        const normal = delta.scale(1 / distance);
        if (!facesAdmit(faces, normal)) return null;
        return .{ .normal = normal, .depth = o.radius - distance };
    }

    // Inside the core box: leave through the nearest admitted face. The order is fixed rather
    // than incidental, so a square overlap resolves the same way every time — X before Y, and
    // positive before negative (I9 asks for documented order wherever order reaches a result).
    const candidates = [4]struct { Face, f32 }{
        .{ .pos_x, o.half.x + o.radius - d.x },
        .{ .neg_x, o.half.x + o.radius + d.x },
        .{ .pos_y, o.half.y + o.radius - d.y },
        .{ .neg_y, o.half.y + o.radius + d.y },
    };
    var best: f32 = std.math.inf(f32);
    var face: ?Face = null;
    for (candidates) |candidate| {
        if (!faces.has(candidate[0])) continue;
        if (candidate[1] < best) {
            best = candidate[1];
            face = candidate[0];
        }
    }
    const chosen = face orelse return null;
    // Zero depth is exact touching, which is not an overlap. The comparison is written this
    // way round so that a NaN depth is refused rather than reported.
    if (!(best > 0)) return null;
    return .{ .normal = normalOf(chosen), .depth = best };
}

/// Whether a push in `normal`'s direction is through faces the mask admits.
fn facesAdmit(faces: FaceMask, normal: Vec2) bool {
    if (normal.x > 0 and !faces.pos_x) return false;
    if (normal.x < 0 and !faces.neg_x) return false;
    if (normal.y > 0 and !faces.pos_y) return false;
    if (normal.y < 0 and !faces.neg_y) return false;
    return true;
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
///
/// `face` names the axis-aligned face entered, and is null when the contact was on a **rounded
/// corner** — which only happens when one of the two shapes is a circle — as well as when the
/// sweep started inside. `startedInside` distinguishes them; the normal is what a caller
/// actually needs, and it is always unit length for a real contact.
pub const Sweep = struct {
    fraction: f32,
    normal: Vec2,
    face: ?Face,

    pub fn startedInside(self: Sweep) bool {
        return self.normal.eql(.zero);
    }
};

/// Sweeps `moving` from `from` along `motion` against `target` standing at `target_at`.
pub fn sweepShape(moving: Shape, from: Vec2, motion: Vec2, target: Shape, target_at: Vec2) ?Sweep {
    return sweepRounded(Rounded.of(moving).sum(Rounded.of(target)), from, motion, target_at, .all);
}

/// Sweeps a box of half-extents `half` from `from` along `motion` against the box `target`.
pub fn sweepBox(half: Vec2, from: Vec2, motion: Vec2, target: Bounds) ?Sweep {
    return sweepRounded(
        .{ .half = half.add(target.halfExtents()) },
        from,
        motion,
        target.center(),
        .all,
    );
}

/// Sweeps a point along `motion` against the rounded box `o` centred at `center`.
///
/// The Minkowski reduction, in its general form: the pair has already been folded into `o` by
/// `Rounded.sum`, so what remains is a ray against one convex shape. No iteration.
///
/// A rounded box with a non-zero radius is treated as the **union** of two overlapping boxes
/// and four corner discs. Entering a union happens at the earliest entry into any of its
/// parts, so the minimum over the parts is the answer and no part has to be clipped to the arc
/// it actually contributes. Ties go to the part listed first: flat sides before corners, X
/// before Y.
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
///
/// `faces` culls parts of the surface, and is the grid's internal-edge fix (`grid.zig`). A
/// corner disc needs both of its adjacent faces, for the reason `overlapRounded` gives.
pub fn sweepRounded(o: Rounded, from: Vec2, motion: Vec2, center: Vec2, faces: FaceMask) ?Sweep {
    const origin = from.sub(center);

    // Already inside when the sweep began. Reported rather than clamped, so that the caller
    // can tell "stuck" from "hit immediately" and reach for `resolveOverlaps` instead.
    if (insideRounded(o, origin)) return .{ .fraction = 0, .normal = .zero, .face = null };

    var best: ?Sweep = null;

    if (!(o.radius > 0)) {
        const entry = slabEntry(origin, motion, o.half) orelse return null;
        if (!faces.has(entry.face)) return null;
        return .{ .fraction = entry.t, .normal = normalOf(entry.face), .face = entry.face };
    }

    // The two flat sides. Each box contributes only the pair of faces that lie on the rounded
    // boundary; an entry through the other pair is on a part of the box the corner discs and
    // the sibling box already cover, and would be reached later than whichever of those the
    // ray really entered first.
    if (slabEntry(origin, motion, .{ .x = o.half.x + o.radius, .y = o.half.y })) |entry| {
        switch (entry.face) {
            .neg_x, .pos_x => if (faces.has(entry.face)) {
                consider(&best, entry.t, normalOf(entry.face), entry.face);
            },
            .neg_y, .pos_y => {},
        }
    }
    if (slabEntry(origin, motion, .{ .x = o.half.x, .y = o.half.y + o.radius })) |entry| {
        switch (entry.face) {
            .neg_y, .pos_y => if (faces.has(entry.face)) {
                consider(&best, entry.t, normalOf(entry.face), entry.face);
            },
            .neg_x, .pos_x => {},
        }
    }

    const corners = [4]struct { Vec2, Face, Face }{
        .{ .{ .x = o.half.x, .y = o.half.y }, .pos_x, .pos_y },
        .{ .{ .x = -o.half.x, .y = o.half.y }, .neg_x, .pos_y },
        .{ .{ .x = o.half.x, .y = -o.half.y }, .pos_x, .neg_y },
        .{ .{ .x = -o.half.x, .y = -o.half.y }, .neg_x, .neg_y },
    };
    for (corners) |corner| {
        if (!faces.has(corner[1]) or !faces.has(corner[2])) continue;
        const entry = discEntry(origin, motion, corner[0], o.radius) orelse continue;
        consider(&best, entry.t, entry.normal, null);
    }

    return best;
}

fn consider(best: *?Sweep, t: f32, normal: Vec2, face: ?Face) void {
    if (best.*) |current| {
        if (!(t < current.fraction)) return;
    }
    best.* = .{ .fraction = t, .normal = normal, .face = face };
}

/// Whether `d`, relative to the obstacle's centre, is strictly inside it.
///
/// Strict on both branches, which is the same rule `overlapRounded` uses: touching exactly is
/// not being inside.
fn insideRounded(o: Rounded, d: Vec2) bool {
    if (!(o.radius > 0)) {
        return @abs(d.x) < o.half.x and @abs(d.y) < o.half.y;
    }
    const nearest: Vec2 = .{
        .x = std.math.clamp(d.x, -o.half.x, o.half.x),
        .y = std.math.clamp(d.y, -o.half.y, o.half.y),
    };
    return d.sub(nearest).lengthSquared() < o.radius * o.radius;
}

const SlabEntry = struct { t: f32, face: Face };

/// The slab method against a box of half-extents `half` centred at the origin.
///
/// Returns null for a miss, for a graze, and for a ray that began inside — the last because
/// `sweepRounded` has already answered that question for the shape as a whole, and a part of
/// a union reporting it again would be noise.
fn slabEntry(origin: Vec2, motion: Vec2, half: Vec2) ?SlabEntry {
    var t_near: f32 = -std.math.inf(f32);
    var t_far: f32 = std.math.inf(f32);
    var face: ?Face = null;

    inline for (0..2) |i| {
        const o = if (i == 0) origin.x else origin.y;
        const delta = if (i == 0) motion.x else motion.y;
        const h = if (i == 0) half.x else half.y;

        if (delta == 0) {
            if (o <= -h or o >= h) return null;
        } else {
            const inverse = 1 / delta;
            var enter = (-h - o) * inverse;
            var exit = (h - o) * inverse;
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
    if (t_near < 0) return null;
    return .{ .t = t_near, .face = face orelse return null };
}

const DiscEntry = struct { t: f32, normal: Vec2 };

/// A ray against a disc of radius `radius` centred at `center`. The near root only; a tangent
/// is a graze and therefore a miss, by the same convention the slab uses.
fn discEntry(origin: Vec2, motion: Vec2, center: Vec2, radius: f32) ?DiscEntry {
    const p = origin.sub(center);
    const a = motion.lengthSquared();
    if (a == 0) return null;
    const b = 2 * p.dot(motion);
    const c = p.lengthSquared() - radius * radius;
    const discriminant = b * b - 4 * a * c;
    if (!(discriminant > 0)) return null;
    const t = (-b - @sqrt(discriminant)) / (2 * a);
    if (t < 0 or t > 1) return null;
    const contact = p.add(motion.scale(t));
    const length = contact.length();
    if (!(length > 0)) return null;
    return .{ .t = t, .normal = contact.scale(1 / length) };
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

fn boxOf(half: Vec2) Shape {
    return .{ .box = half };
}

fn circleOf(radius: f32) Shape {
    return .{ .circle = radius };
}

test "box against box resolves along the shallower axis" {
    // Overlapping by 0.5 in x and 1.5 in y, so the way out is x.
    const contact = overlap(boxOf(v(1, 1)), v(1.5, 0), boxOf(v(1, 1)), v(0, 0)).?;
    try testing.expectEqual(v(1, 0), contact.normal);
    try testing.expectApproxEqAbs(@as(f32, 0.5), contact.depth, 1e-6);

    // ...and the mirror image points the other way.
    const mirrored = overlap(boxOf(v(1, 1)), v(-1.5, 0), boxOf(v(1, 1)), v(0, 0)).?;
    try testing.expectEqual(v(-1, 0), mirrored.normal);
}

test "touching exactly is not an overlap" {
    // A body resting flush against a wall must report nothing, every tick, forever.
    const none = @as(?Contact, null);
    try testing.expectEqual(none, overlap(boxOf(v(1, 1)), v(2, 0), boxOf(v(1, 1)), v(0, 0)));
    try testing.expectEqual(none, overlap(circleOf(1), v(2, 0), circleOf(1), v(0, 0)));
    try testing.expectEqual(none, overlap(boxOf(v(1, 1)), v(0, 0), circleOf(1), v(2, 0)));
}

test "circle against circle, including the concentric case" {
    const contact = overlap(circleOf(1), v(1, 0), circleOf(1), v(0, 0)).?;
    try testing.expectEqual(v(1, 0), contact.normal);
    try testing.expectApproxEqAbs(@as(f32, 1), contact.depth, 1e-6);

    // No separating direction exists, so one is chosen rather than divided by zero, and the
    // choice is documented rather than left to the input's last bit.
    const concentric = overlap(circleOf(2), v(3, 3), circleOf(1), v(3, 3)).?;
    try testing.expectEqual(v(1, 0), concentric.normal);
    try testing.expectApproxEqAbs(@as(f32, 3), concentric.depth, 1e-6);
}

test "box against circle, outside and inside" {
    // Circle centre to the right of the box, overlapping by 0.25.
    const outside = overlap(boxOf(v(1, 1)), v(0, 0), circleOf(1), v(1.75, 0)).?;
    try testing.expectEqual(v(-1, 0), outside.normal);
    try testing.expectApproxEqAbs(@as(f32, 0.25), outside.depth, 1e-6);

    // Centre inside, nearest the box's -y face, so the box escapes upward.
    const inside = overlap(boxOf(v(2, 2)), v(0, 0), circleOf(0.5), v(0, -1.5)).?;
    try testing.expectEqual(v(0, 1), inside.normal);
    try testing.expectApproxEqAbs(@as(f32, 1), inside.depth, 1e-6);
}

test "the pair test is symmetric under swapping its arguments" {
    // Both orders reduce to the same `Rounded`, so agreement is structural rather than two
    // bodies of arithmetic that happen to match.
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

test "a sweep onto a rounded corner reports a diagonal normal" {
    // The one thing a pure slab test cannot do. A circle approaching a box's corner meets a
    // quarter disc, not a face, and the normal it deserves is neither axis.
    const box: Shape = .{ .box = v(1, 1) };
    const circle: Shape = .{ .circle = 0.5 };

    const hit = sweepShape(circle, v(3, 3), v(-3, -3), box, v(0, 0)).?;
    // p(t) - (1,1) has length 0.5 along the diagonal, so t = (2 - 0.5/sqrt2) / 3.
    try testing.expectApproxEqAbs(@as(f32, 0.5488155), hit.fraction, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), hit.normal.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), hit.normal.y, 1e-5);
    // A corner is not a face, and that is what the null says.
    try testing.expectEqual(@as(?Face, null), hit.face);
    try testing.expect(!hit.startedInside());
}

test "a swept circle against a circle is a ray against the sum of their radii" {
    const a: Shape = .{ .circle = 1 };
    const b: Shape = .{ .circle = 1 };
    const hit = sweepShape(a, v(0, 0), v(10, 0), b, v(5, 0)).?;
    try testing.expectApproxEqAbs(@as(f32, 0.3), hit.fraction, 1e-6);
    try testing.expectEqual(v(-1, 0), hit.normal);
}

test "a sweep against a flat side of a rounded box still reports the face" {
    // The corner discs must not steal a contact that belongs to a flat side.
    const box: Shape = .{ .box = v(1, 1) };
    const circle: Shape = .{ .circle = 0.5 };
    const hit = sweepShape(circle, v(-10, 0), v(20, 0), box, v(0, 0)).?;
    // The left flat side sits at x = -1.5.
    try testing.expectApproxEqAbs(@as(f32, 0.425), hit.fraction, 1e-6);
    try testing.expectEqual(v(-1, 0), hit.normal);
    try testing.expectEqual(Face.neg_x, hit.face.?);
}

test "a culled face is not hit, and culling a corner needs both of its faces" {
    const o: Rounded = .{ .half = v(1, 1), .radius = 0.5 };

    // Straight at the left flat side, with that face culled: nothing.
    try testing.expectEqual(
        @as(?Sweep, null),
        sweepRounded(o, v(-10, 0), v(20, 0), v(0, 0), .{ .neg_x = false }),
    );

    // At the lower-left corner, with only the -x face culled: still nothing, because a corner
    // whose neighbour in either direction is solid is inside the wall's surface.
    try testing.expectEqual(
        @as(?Sweep, null),
        sweepRounded(o, v(-3, -3), v(3, 3), v(0, 0), .{ .neg_x = false }),
    );
    // With both of its faces exposed the same corner is hit.
    try testing.expect(sweepRounded(o, v(-3, -3), v(3, 3), v(0, 0), .all) != null);
}

test "a point sweep is a raycast, and needs no shape of its own" {
    const target: Shape = .{ .box = v(1, 1) };
    const hit = sweepRounded(Rounded.point.sum(.of(target)), v(-10, 0), v(20, 0), v(0, 0), .all).?;
    try testing.expectApproxEqAbs(@as(f32, 0.45), hit.fraction, 1e-6);
    try testing.expectEqual(v(-1, 0), hit.normal);
}

test "a circle that begins inside says so, whichever part of the boundary it is under" {
    const o: Rounded = .{ .half = v(1, 1), .radius = 0.5 };
    // Under a flat side.
    try testing.expect(sweepRounded(o, v(1.25, 0), v(5, 0), v(0, 0), .all).?.startedInside());
    // And under a corner disc: (1.3, 1.3) is 0.424 from the corner at (1,1).
    try testing.expect(sweepRounded(o, v(1.3, 1.3), v(5, 0), v(0, 0), .all).?.startedInside());
    // Just outside the same corner is not inside: 0.4*sqrt2 is 0.566, and the disc is 0.5.
    // The motion heads back in, so there is a contact to distinguish from a penetration.
    try testing.expect(!sweepRounded(o, v(1.4, 1.4), v(-1, -1), v(0, 0), .all).?.startedInside());
}

test "the Minkowski sum composes, so every pair is the same obstacle" {
    const box: Rounded = .{ .half = v(2, 3) };
    const circle: Rounded = .{ .radius = 1 };
    const combined = box.sum(circle);
    try testing.expectEqual(v(2, 3), combined.half);
    try testing.expectEqual(@as(f32, 1), combined.radius);
    try testing.expectEqual(v(3, 4), combined.halfExtents());

    // A point adds nothing, which is what makes a raycast the same code path.
    try testing.expectEqual(combined, combined.sum(.point));
}
