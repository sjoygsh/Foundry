//! Closed forms for the pairs a walking character spends its time in (`collision-scale.md` §8,
//! ADR-0078): a point, a segment and a ray against one triangle.
//!
//! Each answers what `gjk.zig` would, in a few dozen operations and exactly to rounding, where
//! GJK iterates to a tolerance. They measure cores only. `narrow.zig` adds the radii, chooses the
//! normal, and still owns the cast: these give it the distance each advance asks for. When the
//! cores meet, `narrow.zig` asks GJK and EPA as before, so depth is not answered here.
//!
//! **They work in f64.** The arguments and the answers are f32, and the arithmetic between is
//! not: a point's place on a thin triangle is a difference of products that f32 loses most of.
//! In f64 the answers are exact to the last bit of an f32 or near it, which GJK is not.
//!
//! Every routine is a pure function of its arguments, with ties broken by the order written
//! here (I9).
const std = @import("std");
const core = @import("core");
const Vec3 = core.math.Vec3;
const D3 = @import("wide.zig").D3;

/// The nearest points of a core and a triangle.
pub const Closest = struct {
    /// Between them. Zero when they touch or cross.
    distance: f32,
    /// On the core: the point itself, or a point of the segment.
    on_core: Vec3,
    on_triangle: Vec3,
    /// From the triangle's point to the core's, unit. Zero when the distance is. It is found
    /// before the points are rounded to f32, so it is unit however far from the origin they are.
    toward_core: Vec3,
    /// Whether `on_triangle` is inside the face, and not on an edge or at a corner. Then the
    /// way from one to the other is the face's own normal, however near they are.
    face: bool,
};

/// `Closest`, before it is rounded to f32.
const Wide = struct {
    distance: f64,
    on_core: D3,
    on_triangle: D3,
    face: bool,

    fn narrow(self: Wide) Closest {
        const between = self.on_core.sub(self.on_triangle);
        return .{
            .distance = @floatCast(self.distance),
            .on_core = self.on_core.vec(),
            .on_triangle = self.on_triangle.vec(),
            .toward_core = if (self.distance > 0) between.scale(1 / self.distance).vec() else .zero,
            .face = self.face,
        };
    }
};

fn wide(t: [3]Vec3) [3]D3 {
    return .{ D3.of(t[0]), D3.of(t[1]), D3.of(t[2]) };
}

/// The point of triangle `t` nearest to `p`, by which of the triangle's seven regions `p` is
/// over: a corner, an edge or the face. (Ericson, Real-Time Collision Detection, 5.1.5.)
pub fn pointTriangle(p: Vec3, t: [3]Vec3) Closest {
    return pointTriangleWide(D3.of(p), wide(t)).narrow();
}

fn pointTriangleWide(p: D3, t: [3]D3) Wide {
    const ab = t[1].sub(t[0]);
    const ac = t[2].sub(t[0]);
    const ap = p.sub(t[0]);
    const d1 = ab.dot(ap);
    const d2 = ac.dot(ap);
    if (d1 <= 0 and d2 <= 0) return at(p, t[0], false);

    const bp = p.sub(t[1]);
    const d3 = ab.dot(bp);
    const d4 = ac.dot(bp);
    if (d3 >= 0 and d4 <= d3) return at(p, t[1], false);

    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) return at(p, t[0].add(ab.scale(d1 / (d1 - d3))), false);

    const cp = p.sub(t[2]);
    const d5 = ab.dot(cp);
    const d6 = ac.dot(cp);
    if (d6 >= 0 and d5 <= d6) return at(p, t[2], false);

    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) return at(p, t[0].add(ac.scale(d2 / (d2 - d6))), false);

    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and d4 - d3 >= 0 and d5 - d6 >= 0) {
        return at(p, t[1].add(t[2].sub(t[1]).scale((d4 - d3) / ((d4 - d3) + (d5 - d6)))), false);
    }

    const sum = va + vb + vc;
    // A triangle with no area has no face. The world never sends one (`Mesh.usable`).
    if (!(sum > 0)) return at(p, t[0], false);
    const v = vb / sum;
    const w = vc / sum;
    return at(p, t[0].add(ab.scale(v)).add(ac.scale(w)), true);
}

fn at(p: D3, q: D3, face: bool) Wide {
    const between = p.sub(q);
    return .{ .distance = @sqrt(between.dot(between)), .on_core = p, .on_triangle = q, .face = face };
}

/// The nearest points of the segment from `p` to `q` and triangle `t`. They are found at one of
/// the segment's ends, or on one of the triangle's edges, unless the segment passes through the
/// face, where the distance is zero. Among equals the first wins: `p`, then `q`, then the edges
/// from corner 0, 1 and 2.
pub fn segmentTriangle(p: Vec3, q: Vec3, t: [3]Vec3) Closest {
    return segmentTriangleWide(D3.of(p), D3.of(q), wide(t)).narrow();
}

fn segmentTriangleWide(p: D3, q: D3, t: [3]D3) Wide {
    // Through the face: the ends are on opposite sides of its plane, and the crossing is inside.
    const normal = t[1].sub(t[0]).cross(t[2].sub(t[0]));
    const hp = normal.dot(p.sub(t[0]));
    const hq = normal.dot(q.sub(t[0]));
    if ((hp > 0 and hq < 0) or (hp < 0 and hq > 0)) {
        const through = p.add(q.sub(p).scale(hp / (hp - hq)));
        const on = pointTriangleWide(through, t);
        if (on.face) return .{ .distance = 0, .on_core = on.on_triangle, .on_triangle = on.on_triangle, .face = true };
    }

    var best = pointTriangleWide(p, t);
    const other = pointTriangleWide(q, t);
    if (other.distance < best.distance) best = other;
    for (0..3) |i| {
        const edge = segmentSegment(p, q, t[i], t[(i + 1) % 3]);
        if (edge.distance < best.distance) best = edge;
    }
    return best;
}

/// The nearest points of two segments, the first from `p1` to `q1`. (Ericson 5.1.9.)
fn segmentSegment(p1: D3, q1: D3, p2: D3, q2: D3) Wide {
    const d1 = q1.sub(p1);
    const d2 = q2.sub(p2);
    const r = p1.sub(p2);
    const a = d1.dot(d1);
    const e = d2.dot(d2);
    const f = d2.dot(r);
    var s: f64 = 0;
    var u: f64 = 0;
    if (a > 0 and e > 0) {
        const c = d1.dot(r);
        const b = d1.dot(d2);
        const denominator = a * e - b * b;
        // Parallel segments have no one nearest pair. The first segment's start is taken.
        if (denominator > 0) s = std.math.clamp((b * f - c * e) / denominator, 0, 1);
        u = (b * s + f) / e;
        if (u < 0) {
            u = 0;
            s = std.math.clamp(-c / a, 0, 1);
        } else if (u > 1) {
            u = 1;
            s = std.math.clamp((b - c) / a, 0, 1);
        }
    } else if (e > 0) {
        u = std.math.clamp(f / e, 0, 1);
    } else if (a > 0) {
        s = std.math.clamp(-d1.dot(r) / a, 0, 1);
    }
    return at(p1.add(d1.scale(s)), p2.add(d2.scale(u)), false);
}

pub const Crossing = struct {
    /// Of `along`, in [0, 1].
    fraction: f32,
    /// On the triangle, as its corners weighed by where the ray passes between them. So a
    /// crossing of a level triangle is at the triangle's own height, exactly.
    point: Vec3,
};

/// Where a ray meets a triangle.
pub const Ray = union(enum) {
    hit: Crossing,
    miss,
    /// Too near an edge, a corner or the triangle's own plane for one step to say. The caller
    /// falls back to the general cast, which hits whatever the ray comes within its tolerance of.
    unsure,
};

/// Where the ray from `origin` over `along` crosses triangle `t`, from either side. One step:
/// the three edge tests, then the plane.
///
/// **No ray slips through a seam.** Each edge test is a scalar triple product of the ray and the
/// edge's two corners, and swapping the corners negates it exactly, so two triangles sharing an
/// edge never both call a ray outside it. At a corner that is not enough: several edges meet
/// there, and each test's sign is then rounding. So a ray that passes an edge by less than
/// `tolerance`, or by less than rounding can vouch for, is `unsure` and never a miss. The caller
/// must give every triangle of one mesh the same `origin` and `along`, bit for bit, and each
/// shared corner the same value.
pub fn rayTriangle(origin: Vec3, along: Vec3, t: [3]Vec3, tolerance: f32) Ray {
    const o = D3.of(origin);
    const d = D3.of(along);
    const a = D3.of(t[0]).sub(o);
    const b = D3.of(t[1]).sub(o);
    const c = D3.of(t[2]).sub(o);
    // Each is the ray's side of the edge opposite a corner: of b-c, c-a and a-b.
    const u = d.dot(b.cross(c));
    const v = d.dot(c.cross(a));
    const w = d.dot(a.cross(b));
    if ((u < 0 or v < 0 or w < 0) and (u > 0 or v > 0 or w > 0)) {
        // Outside. By how much? A test's value is the ray's length, times the edge's, times at
        // most the distance by which the ray's line passes the edge's. One side's tests are all
        // that small when the ray only grazes.
        const near = [3]bool{
            grazes(u, d, c.sub(b), b, c, tolerance),
            grazes(v, d, a.sub(c), c, a, tolerance),
            grazes(w, d, b.sub(a), a, b, tolerance),
        };
        var below_near = true;
        var above_near = true;
        for ([3]f64{ u, v, w }, near) |value, grazing| {
            if (value < 0 and !grazing) below_near = false;
            if (value > 0 and !grazing) above_near = false;
        }
        return if (below_near or above_near) .unsure else .miss;
    }
    const sum = u + v + w;
    if (sum == 0) return .unsure;
    // The crossing, from the origin, as the corners weighed by the edge tests.
    const crossing = a.scale(u).add(b.scale(v)).add(c.scale(w)).scale(1 / sum);
    const fraction: f32 = @floatCast(crossing.dot(d) / d.dot(d));
    if (!(fraction >= 0 and fraction <= 1)) return .miss;
    const corners = wide(t);
    const point = corners[0].scale(u).add(corners[1].scale(v)).add(corners[2].scale(w)).scale(1 / sum);
    return .{ .hit = .{ .fraction = fraction, .point = point.vec() } };
}

/// Whether an edge test's value is within what `tolerance` of distance, or the rounding of the
/// products that made it, could account for.
fn grazes(value: f64, along: D3, edge: D3, from: D3, to: D3, tolerance: f64) bool {
    const rounding = 16 * std.math.floatEps(f64);
    const slack = @max(tolerance * tolerance * edge.dot(edge), rounding * rounding * from.dot(from) * to.dot(to));
    return value * value <= slack * along.dot(along);
}

const testing = std.testing;
const tri = [3]Vec3{ .init(0, 0, 0), .init(4, 0, 0), .init(0, 0, 4) };

fn expectVec(want: Vec3, got: Vec3) !void {
    try testing.expectApproxEqAbs(want.x, got.x, 1e-6);
    try testing.expectApproxEqAbs(want.y, got.y, 1e-6);
    try testing.expectApproxEqAbs(want.z, got.z, 1e-6);
}

test "pairs: a point over each of a triangle's seven regions" {
    const cases = [_]struct { p: Vec3, on: Vec3, face: bool }{
        .{ .p = .init(1, 2, 1), .on = .init(1, 0, 1), .face = true },
        .{ .p = .init(1, -2, 1), .on = .init(1, 0, 1), .face = true },
        .{ .p = .init(-1, 1, -1), .on = .init(0, 0, 0), .face = false },
        .{ .p = .init(6, 1, -1), .on = .init(4, 0, 0), .face = false },
        .{ .p = .init(-1, 1, 6), .on = .init(0, 0, 4), .face = false },
        .{ .p = .init(2, 1, -3), .on = .init(2, 0, 0), .face = false },
        .{ .p = .init(-3, 1, 2), .on = .init(0, 0, 2), .face = false },
        .{ .p = .init(3, 1, 3), .on = .init(2, 0, 2), .face = false },
    };
    for (cases) |case| {
        const found = pointTriangle(case.p, tri);
        try expectVec(case.on, found.on_triangle);
        try testing.expect(found.on_core.eql(case.p));
        try testing.expectEqual(case.face, found.face);
        try testing.expectApproxEqAbs(case.p.sub(case.on).length(), found.distance, 1e-6);
    }
    // On the face itself the distance is zero and it is still the face.
    const on = pointTriangle(.init(1, 0, 1), tri);
    try testing.expectEqual(@as(f32, 0), on.distance);
    try testing.expect(on.face);
}

test "pairs: a segment by its end, by an edge, through the face and beside it" {
    // Standing over the face: the lower end.
    var found = segmentTriangle(.init(1, 3, 1), .init(1, 1, 1), tri);
    try testing.expectApproxEqAbs(@as(f32, 1), found.distance, 1e-6);
    try expectVec(.init(1, 1, 1), found.on_core);
    try expectVec(.init(1, 0, 1), found.on_triangle);
    try testing.expect(found.face);

    // Lying across a corner of the triangle, above its long edge: a point inside the segment.
    found = segmentTriangle(.init(4, 1, 4), .init(0, 1, 0), tri);
    try testing.expectApproxEqAbs(@as(f32, 1), found.distance, 1e-6);
    try testing.expect(found.on_triangle.y == 0);

    // Beside the triangle and level with it: nearest an edge, between its ends.
    found = segmentTriangle(.init(1, -1, -2), .init(3, 1, -2), tri);
    try testing.expectApproxEqAbs(@as(f32, 2), found.distance, 1e-6);
    try expectVec(.init(2, 0, -2), found.on_core);
    try expectVec(.init(2, 0, 0), found.on_triangle);
    try testing.expect(!found.face);

    // Through the face.
    found = segmentTriangle(.init(1, 1, 1), .init(1.5, -1, 0.5), tri);
    try testing.expectEqual(@as(f32, 0), found.distance);
    try expectVec(.init(1.25, 0, 0.75), found.on_triangle);

    // Through the plane and past the triangle: not zero.
    found = segmentTriangle(.init(5, 1, 5), .init(5, -1, 5), tri);
    try testing.expectApproxEqAbs(@sqrt(18.0), found.distance, 1e-5);
    try expectVec(.init(5, 0, 5), found.on_core);

    // Level over the face, both ends as near: the first end wins.
    found = segmentTriangle(.init(1, 1, 1), .init(2, 1, 1), tri);
    try testing.expectApproxEqAbs(@as(f32, 1), found.distance, 1e-6);
    try expectVec(.init(1, 1, 1), found.on_core);

    // A segment of no length is its point.
    found = segmentTriangle(.init(6, 1, -1), .init(6, 1, -1), tri);
    try expectVec(.init(4, 0, 0), found.on_triangle);
}

test "pairs: a ray crosses from either side, misses, stops short and lies in the plane" {
    const tol: f32 = 1e-5;
    try testing.expectApproxEqAbs(@as(f32, 0.25), rayTriangle(.init(1, 1, 1), .init(0, -4, 0), tri, tol).hit.fraction, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rayTriangle(.init(1, -2, 1), .init(0, 4, 0), tri, tol).hit.fraction, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rayTriangle(.init(0, 1, 2), .init(2, -2, -2), tri, tol).hit.fraction, 1e-6);
    // Beside it, short of it, and pointing away.
    try testing.expectEqual(Ray.miss, rayTriangle(.init(3, 1, 3), .init(0, -4, 0), tri, tol));
    try testing.expectEqual(Ray.miss, rayTriangle(.init(1, 3, 1), .init(0, -2, 0), tri, tol));
    try testing.expectEqual(Ray.miss, rayTriangle(.init(1, 1, 1), .init(0, 4, 0), tri, tol));
    // Ending on the face and starting on it are both hits.
    try testing.expectEqual(@as(f32, 1), rayTriangle(.init(1, 2, 1), .init(0, -2, 0), tri, tol).hit.fraction);
    // The crossing is on the triangle exactly, not where the ray's arithmetic lands near it.
    const slanted = rayTriangle(.init(0.3, 1.7, 0.9), .init(0.7, -3.1, 0.2), tri, tol).hit;
    try testing.expectEqual(@as(f32, 0), slanted.point.y);
    try expectVec(Vec3.init(0.3, 1.7, 0.9).add(Vec3.init(0.7, -3.1, 0.2).scale(slanted.fraction)), slanted.point);
    try testing.expectEqual(@as(f32, 0), rayTriangle(.init(1, 0, 1), .init(0, -2, 0), tri, tol).hit.fraction);
    // In the plane, toward the triangle or along an edge of it.
    try testing.expectEqual(Ray.unsure, rayTriangle(.init(-2, 0, 1), .init(4, 0, 0), tri, tol));
    try testing.expectEqual(Ray.unsure, rayTriangle(.init(-2, 0, 0), .init(8, 0, 0), tri, tol));
    // Level, above the plane, is a miss and not a question.
    try testing.expectEqual(Ray.miss, rayTriangle(.init(-2, 1, 1), .init(4, 0, 0), tri, tol));
    // Past an edge by a hair is a question, and by a millimetre is a miss. Just inside is a hit.
    try testing.expectEqual(Ray.unsure, rayTriangle(.init(2, 1, -2e-6), .init(0, -4, 0), tri, tol));
    try testing.expectEqual(Ray.miss, rayTriangle(.init(2, 1, -1e-3), .init(0, -4, 0), tri, tol));
    try testing.expectApproxEqAbs(@as(f32, 0.25), rayTriangle(.init(2, 1, 2e-6), .init(0, -4, 0), tri, tol).hit.fraction, 1e-6);
    // Past a corner by a hair, on the outside of two edges at once.
    try testing.expectEqual(Ray.unsure, rayTriangle(.init(-2e-6, 1, -2e-6), .init(0, -4, 0), tri, tol));
    try testing.expectEqual(Ray.miss, rayTriangle(.init(-1e-3, 1, -1e-3), .init(0, -4, 0), tri, tol));
}
