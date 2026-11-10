//! Separation and casts between two rounded convex shapes (`collision3d.md` §5).
//!
//! `gjk.zig` measures cores; this file adds the radii back, chooses a normal, and turns distance
//! into a cast by conservative advancement. Every normal here points **out of B, toward A**: the
//! way A would be pushed to leave B.
//!
//! **Three pairs do not go to GJK** (`collision-scale.md` §8, ADR-0078). A point core or a
//! segment core against a triangle is measured by `pairs.zig`'s closed forms, and a ray against a
//! triangle is answered in one step. What a cast means does not change: it is still conservative
//! advancement to the same skin and tolerance, asking a closed form for each distance. When the
//! cores meet, the pair goes to GJK and EPA as every other pair does. `separationGeneral` and
//! `castGeneral` are the one routine for every pair, kept as it was: the reference in tests.

const std = @import("std");
const core = @import("core");

const gjk = @import("gjk.zig");
const pairs = @import("pairs.zig");
const shape = @import("shape.zig");

const Convex = shape.Convex;
const Vec3 = core.math.Vec3;

pub const max_cast_iterations: u32 = 32;

/// A cast stops when the gap to its target separation is under this, metres.
pub const cast_tolerance: f32 = 1e-5;

/// How far a shape cast stops short of contact, measured along the contact normal, metres. An
/// interface constant: a caller sees a character stand this far off a wall (§5.2).
pub const contact_skin: f32 = 0.005;

pub const Separation = struct {
    /// Between the rounded surfaces. Negative when they overlap, by the depth.
    distance: f32,
    /// Out of B, toward A. Unit.
    normal: Vec3,
    /// On A's and B's rounded surfaces.
    point_a: Vec3,
    point_b: Vec3,
    /// The cores themselves met, so the normal and depth came from EPA or its fallback.
    cores_intersect: bool,
};

pub fn separation(a: Convex, b: Convex) Separation {
    return closedSeparation(a, b) orelse separationGeneral(a, b);
}

/// Whether `separation` measures this pair by a closed form while its cores are apart.
pub fn closedPair(a: Convex, b: Convex) bool {
    return b.core == .triangle and (a.core == .point or a.core == .segment);
}

/// A point or a segment against a triangle, by `pairs.zig`. Null for any other pair, and when
/// the cores are within GJK's own `intersect_distance`: then they meet, and depth is EPA's.
fn closedSeparation(a: Convex, b: Convex) ?Separation {
    if (b.core != .triangle) return null;
    const local = b.core.triangle;
    const triangle = [3]Vec3{ b.pose.apply(local[0]), b.pose.apply(local[1]), b.pose.apply(local[2]) };
    const nearest = switch (a.core) {
        .point => pairs.pointTriangle(a.pose.position, triangle),
        .segment => |h| pairs.segmentTriangle(a.pose.apply(.init(0, h, 0)), a.pose.apply(.init(0, -h, 0)), triangle),
        else => return null,
    };
    if (!(nearest.distance > gjk.intersect_distance)) return null;
    // Over the face the normal is the face's own, exact however small the gap. Elsewhere it
    // is the line between the two points.
    const n = if (nearest.face) b.surfaceNormal(nearest.toward_core, nearest.on_triangle) else nearest.toward_core;
    return .{
        .distance = nearest.distance - (a.radius + b.radius),
        .normal = n,
        .point_a = nearest.on_core.sub(n.scale(a.radius)),
        .point_b = nearest.on_triangle.add(n.scale(b.radius)),
        .cores_intersect = false,
    };
}

/// `separation` by GJK and EPA alone, for any pair.
pub fn separationGeneral(a: Convex, b: Convex) Separation {
    const d = gjk.distance(a, b);
    const radii = a.radius + b.radius;
    if (!d.intersect) {
        const n = d.normal;
        return .{
            .distance = d.distance - radii,
            .normal = n,
            .point_a = d.point_a.sub(n.scale(a.radius)),
            .point_b = d.point_b.add(n.scale(b.radius)),
            .cores_intersect = false,
        };
    }
    if (gjk.penetration(a, b, d.simplex)) |p| {
        const n = p.normal.neg();
        return .{
            .distance = -(p.depth + radii),
            .normal = n,
            .point_a = p.point_a.sub(n.scale(a.radius)),
            .point_b = p.point_b.add(n.scale(b.radius)),
            .cores_intersect = true,
        };
    }
    // Cores whose difference has no volume: points and segments exactly meeting, which only
    // sphere/capsule pairs and points on triangles produce. Push apart along the line between
    // centres, or up when they coincide; a triangle instead uses its face toward the core's
    // centre. Deterministic, and resolved by the radii alone.
    var n = a.pose.position.sub(b.pose.position);
    n = if (n.lengthSquared() > 0) n.normalize() else Vec3.up;
    if (b.core == .triangle) {
        const pts = b.core.triangle;
        n = b.surfaceNormal(a.pose.position.sub(b.pose.apply(pts[0])), b.pose.position);
    }
    return .{
        .distance = -radii,
        .normal = n,
        .point_a = d.point_a.sub(n.scale(a.radius)),
        .point_b = d.point_b.add(n.scale(b.radius)),
        .cores_intersect = true,
    };
}

pub const Cast = struct {
    /// Of the displacement, in [0, 1].
    fraction: f32,
    normal: Vec3,
    /// On B's surface.
    point: Vec3,
    started_inside: bool,
};

/// Where A, translated by `displacement`, first comes within `target` of B. Null if it never
/// does over the whole displacement.
///
/// Conservative advancement: the distance between two convex sets under a translation is a
/// convex function of time, so advancing by the gap over the closing speed along the current
/// normal can never step past contact. A cast that uses its whole budget reports its last safe
/// fraction — short, never through.
pub fn cast(a: Convex, displacement: Vec3, b: Convex, target: f32) ?Cast {
    return advance(a, displacement, b, target, true);
}

/// `cast` by GJK and EPA alone, for any pair.
pub fn castGeneral(a: Convex, displacement: Vec3, b: Convex, target: f32) ?Cast {
    return advance(a, displacement, b, target, false);
}

fn advance(a: Convex, displacement: Vec3, b: Convex, target: f32, closed: bool) ?Cast {
    var s = if (closed) separation(a, b) else separationGeneral(a, b);
    if (s.distance < 0) {
        return .{ .fraction = 0, .normal = s.normal, .point = s.point_b, .started_inside = true };
    }
    // A ray against a triangle is one step, not an advance. A ray that starts within the
    // tolerance of the triangle has already arrived, and one that grazes an edge or lies in the
    // triangle's plane is not one step's to call: those are the loop's, below, which hits what
    // the ray comes within the tolerance of, as it always did.
    if (closed and a.core == .point and a.radius == 0 and target == 0 and b.core == .triangle and s.distance > cast_tolerance) {
        // In the triangle's own space, so every triangle of a mesh sees the same ray and the
        // same corners, and the seams between them are watertight (`pairs.rayTriangle`).
        const origin = b.pose.inverseDirection(a.pose.position.sub(b.pose.position));
        const along = b.pose.inverseDirection(displacement);
        switch (pairs.rayTriangle(origin, along, b.core.triangle, cast_tolerance)) {
            .miss => return null,
            .hit => |crossing| {
                const point = b.pose.apply(crossing.point);
                return .{ .fraction = crossing.fraction, .normal = b.surfaceNormal(displacement.neg(), point), .point = point, .started_inside = false };
            },
            .unsure => {},
        }
    }
    var t: f32 = 0;
    var iteration: u32 = 0;
    while (iteration < max_cast_iterations) : (iteration += 1) {
        const gap = s.distance - target;
        if (gap <= cast_tolerance) break;
        const closing = -displacement.dot(s.normal);
        if (!(closing > 1e-12)) return null;
        const next_t = t + gap / closing;
        if (next_t > 1) return null;
        const moved = a.translated(displacement.scale(next_t));
        var next = if (closed) separation(moved, b) else separationGeneral(moved, b);
        // A point exactly on a two-sided triangle has no side. Preserve the approach side
        // from the last separated iterate rather than choosing the triangle's winding.
        if (b.core == .triangle and next.distance <= cast_tolerance and target == 0 and a.radius == 0)
            next.normal = b.surfaceNormal(s.normal, b.pose.position);
        // A step aimed exactly at the surface (a raycast's target is 0) lands on it only to
        // rounding, sometimes a hair inside: that is the contact. Anything deeper is not a
        // step convexity allows, and the last safe answer stands.
        if (next.distance < 0) {
            if (next.distance >= -cast_tolerance) {
                t = next_t;
                s = next;
            }
            break;
        }
        t = next_t;
        s = next;
    }
    return .{ .fraction = t, .normal = s.normal, .point = s.point_b, .started_inside = false };
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;
const Quat = core.math.Quat;

fn sphere(at: Vec3, r: f32) Convex {
    return .{ .core = .point, .radius = r, .pose = .at(at) };
}

fn capsule(at: Vec3, r: f32, h: f32, rotation: Quat) Convex {
    return .{ .core = .{ .segment = h }, .radius = r, .pose = .{ .position = at, .rotation = rotation } };
}

fn box(at: Vec3, he: Vec3, rotation: Quat) Convex {
    return .{ .core = .{ .box = he }, .radius = 0, .pose = .{ .position = at, .rotation = rotation } };
}

test "separation: spheres, and capsules whose segments are skew" {
    const s = separation(sphere(.init(3, 0, 0), 1), sphere(.zero, 0.5));
    try testing.expectApproxEqAbs(@as(f32, 1.5), s.distance, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), s.normal.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.point_b.x, 1e-5);

    // A vertical capsule and one lying along X, 2 m apart in Z: segment distance 2.
    const lying = capsule(.init(0, 0.4, 2), 0.25, 1, Quat.fromAxisAngle(.init(0, 0, 1), std.math.pi / 2.0));
    const standing = capsule(.zero, 0.25, 1, .identity);
    try testing.expectApproxEqAbs(@as(f32, 1.5), separation(lying, standing).distance, 1e-5);
}

test "separation: a rounded overlap does not need EPA, a core one does" {
    const shallow = separation(sphere(.init(0, 1.4, 0), 0.5), box(.zero, .init(1, 1, 1), .identity));
    try testing.expect(!shallow.cores_intersect);
    try testing.expectApproxEqAbs(@as(f32, -0.1), shallow.distance, 1e-5);
    const deep = separation(sphere(.init(0, 0.8, 0), 0.5), box(.zero, .init(1, 1, 1), .identity));
    try testing.expect(deep.cores_intersect);
    try testing.expectApproxEqAbs(@as(f32, -0.7), deep.distance, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), deep.normal.y, 1e-4);
}

test "separation: coincident spheres fall back to up, deterministically" {
    const s = separation(sphere(.zero, 0.5), sphere(.zero, 0.5));
    try testing.expect(s.cores_intersect);
    try testing.expectEqual(@as(f32, -1), s.distance);
    try testing.expect(s.normal.eql(Vec3.up));
}

test "cast: a sphere into a box face stops a skin short" {
    const c = cast(sphere(.init(-5, 0, 0), 0.5), .init(10, 0, 0), box(.zero, .init(1, 1, 1), .identity), contact_skin).?;
    // Contact at centre x = −1.5, a skin short at −1.505: fraction 3.495 / 10.
    try testing.expectApproxEqAbs(@as(f32, 0.3495), c.fraction, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), c.normal.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), c.point.x, 1e-5);
    try testing.expect(!c.started_inside);
}

test "cast: moving away or past never hits, and a start inside is reported" {
    const b = box(.zero, .init(1, 1, 1), .identity);
    try testing.expect(cast(sphere(.init(-5, 0, 0), 0.5), .init(-10, 0, 0), b, contact_skin) == null);
    try testing.expect(cast(sphere(.init(-5, 3, 0), 0.5), .init(10, 0, 0), b, contact_skin) == null);
    try testing.expect(cast(sphere(.init(-5, 0, 0), 0.5), .init(2, 0, 0), b, contact_skin) == null);
    const inside = cast(sphere(.init(0, 0.8, 0), 0.5), .init(1, 0, 0), b, contact_skin).?;
    try testing.expect(inside.started_inside);
    try testing.expectEqual(@as(f32, 0), inside.fraction);
}

test "cast: a fast sphere never passes a 1 cm plate" {
    const plate = box(.zero, .init(0.005, 2, 2), .identity);
    const c = cast(sphere(.init(-50, 0, 0), 0.1), .init(100, 0, 0), plate, contact_skin).?;
    const stop = -50 + 100 * c.fraction;
    try testing.expect(stop < -0.1);
    try testing.expectApproxEqAbs(@as(f32, -0.11), stop, 1e-3);
}
