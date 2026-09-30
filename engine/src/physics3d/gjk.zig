//! GJK distance and EPA depth between two convex cores (`collision3d.md` §5.1).
//!
//! Both run on support functions alone, so one routine serves every pair of shapes. **Every loop
//! is bounded** by a constant that is part of the interface; a pair that has not converged when
//! its budget runs out returns the best answer found, never loops. Order is a function of the
//! input alone: the simplex and the polytope are walked in array order, ties go to the lower
//! index, and nothing depends on an address (I9).
//!
//! Radii are not seen here. `narrow.zig` subtracts them.

const std = @import("std");
const core = @import("core");

const shape = @import("shape.zig");

const Convex = shape.Convex;
const Vec3 = core.math.Vec3;

pub const max_gjk_iterations: u32 = 32;
pub const max_epa_iterations: u32 = 32;

/// GJK stops when its upper and lower bounds on the distance agree to this, metres.
///
/// `collision3d.md` §5.1 proposed 1e-7 m. That is below what an `f32` resolves at metre-scale
/// coordinates (an ulp at 1 m is 1.2e-7), so a bound that tight is only ever met by the
/// no-progress rule; 1e-6 m is the tightest bound the arithmetic can actually reach there.
pub const gjk_tolerance: f32 = 1e-6;

/// Core distances below this are treated as the cores meeting, metres.
pub const intersect_distance: f32 = 1e-6;

/// EPA stops when a new support point lies within this of the closest face, metres.
pub const epa_tolerance: f32 = 1e-5;

/// A point of the Minkowski difference `A − B`, with the support points it came from, so the
/// witnesses can be recovered from barycentric weights.
pub const Vertex = struct {
    w: Vec3,
    a: Vec3,
    b: Vec3,
};

pub const Simplex = struct {
    v: [4]Vertex = undefined,
    len: u8 = 0,
};

pub const Distance = struct {
    /// Between the cores. Zero when they meet.
    distance: f32,
    /// The closest points on each core. Equal-ish when the cores meet.
    point_a: Vec3,
    point_b: Vec3,
    /// From B's core toward A's, unit; meaningless when the cores meet. When the final simplex is
    /// a triangle — a face of `A − B` — this is that face's plane normal, which is exact however
    /// close the cores are. Otherwise it is the direction between the witnesses, which near
    /// contact is mostly rounding: an ulp at 100 m over a 10 µm gap is a tilt of nearly 1.
    normal: Vec3,
    intersect: bool,
    /// The final simplex, which EPA starts from when the cores meet.
    simplex: Simplex,
};

pub fn vertex(a: Convex, b: Convex, dir: Vec3) Vertex {
    const sa = a.support(dir);
    const sb = b.support(dir.neg());
    return .{ .w = sa.sub(sb), .a = sa, .b = sb };
}

/// The distance between two convex cores.
pub fn distance(a: Convex, b: Convex) Distance {
    var dir = a.pose.position.sub(b.pose.position);
    if (dir.lengthSquared() == 0) dir = Vec3.right;

    var simplex: Simplex = .{};
    simplex.v[0] = vertex(a, b, dir.neg());
    simplex.len = 1;
    var closest = simplex.v[0].w;
    var weights = [4]f32{ 1, 0, 0, 0 };

    var iteration: u32 = 0;
    while (iteration < max_gjk_iterations) : (iteration += 1) {
        const vv = closest.lengthSquared();
        if (vv <= intersect_distance * intersect_distance) {
            return finish(simplex, weights, true);
        }
        const next = vertex(a, b, closest.neg());
        // ‖v‖ − v·w/‖v‖ is the gap between the upper and lower bounds on the distance.
        if (vv - closest.dot(next.w) <= gjk_tolerance * @sqrt(vv)) break;
        var duplicate = false;
        for (simplex.v[0..simplex.len]) |existing| {
            if (existing.w.eql(next.w)) duplicate = true;
        }
        if (duplicate) break;

        var candidate = simplex;
        candidate.v[candidate.len] = next;
        candidate.len += 1;
        const reduced = closestOnSimplex(&candidate);
        if (reduced.inside) {
            return finish(candidate, reduced.weights, true);
        }
        // No progress means the arithmetic has run out; keep what we had.
        if (reduced.point.lengthSquared() >= vv) break;
        simplex = candidate;
        closest = reduced.point;
        weights = reduced.weights;
    }
    return finish(simplex, weights, false);
}

fn finish(simplex: Simplex, weights: [4]f32, intersect: bool) Distance {
    var pa: Vec3 = .zero;
    var pb: Vec3 = .zero;
    for (simplex.v[0..simplex.len], weights[0..simplex.len]) |v, w| {
        pa = pa.add(v.a.scale(w));
        pb = pb.add(v.b.scale(w));
    }
    const between = pa.sub(pb);
    var normal = between.normalize();
    if (!intersect and simplex.len == 3) {
        const face = Vec3.cross(simplex.v[1].w.sub(simplex.v[0].w), simplex.v[2].w.sub(simplex.v[0].w)).normalize();
        if (!face.eql(Vec3.zero)) normal = if (face.dot(between) < 0) face.neg() else face;
    }
    return .{
        .distance = if (intersect) 0 else between.length(),
        .point_a = pa,
        .point_b = pb,
        .normal = normal,
        .intersect = intersect,
        .simplex = simplex,
    };
}

const Reduced = struct {
    point: Vec3,
    weights: [4]f32,
    inside: bool = false,
};

/// The point of the simplex closest to the origin, with the simplex reduced in place to the
/// vertices that carry it.
fn closestOnSimplex(s: *Simplex) Reduced {
    return switch (s.len) {
        1 => .{ .point = s.v[0].w, .weights = .{ 1, 0, 0, 0 } },
        2 => segment(s),
        3 => triangle(s),
        4 => tetrahedron(s),
        else => unreachable,
    };
}

fn keep(s: *Simplex, which: []const u8, w: []const f32) Reduced {
    var out: Simplex = .{};
    var weights = [4]f32{ 0, 0, 0, 0 };
    var point: Vec3 = .zero;
    for (which, w, 0..) |index, weight, i| {
        out.v[i] = s.v[index];
        weights[i] = weight;
        point = point.add(s.v[index].w.scale(weight));
    }
    out.len = @intCast(which.len);
    s.* = out;
    return .{ .point = point, .weights = weights };
}

fn segment(s: *Simplex) Reduced {
    const a = s.v[0].w;
    const b = s.v[1].w;
    const ab = b.sub(a);
    const len2 = ab.lengthSquared();
    if (len2 == 0) return keep(s, &.{0}, &.{1});
    const t = -a.dot(ab) / len2;
    if (t <= 0) return keep(s, &.{0}, &.{1});
    if (t >= 1) return keep(s, &.{1}, &.{1});
    return keep(s, &.{ 0, 1 }, &.{ 1 - t, t });
}

/// Ericson's closest point on a triangle (Real-Time Collision Detection §5.1.5), with the origin
/// as the query point and a degenerate triangle falling back to its best edge.
fn triangle(s: *Simplex) Reduced {
    const a = s.v[0].w;
    const b = s.v[1].w;
    const c = s.v[2].w;
    const ab = b.sub(a);
    const ac = c.sub(a);
    const ap = a.neg();
    const d1 = ab.dot(ap);
    const d2 = ac.dot(ap);
    if (d1 <= 0 and d2 <= 0) return keep(s, &.{0}, &.{1});

    const bp = b.neg();
    const d3 = ab.dot(bp);
    const d4 = ac.dot(bp);
    if (d3 >= 0 and d4 <= d3) return keep(s, &.{1}, &.{1});

    const vc = d1 * d4 - d3 * d2;
    if (vc <= 0 and d1 >= 0 and d3 <= 0) {
        const den = d1 - d3;
        if (den == 0) return keep(s, &.{0}, &.{1});
        const v = d1 / den;
        return keep(s, &.{ 0, 1 }, &.{ 1 - v, v });
    }

    const cp = c.neg();
    const d5 = ab.dot(cp);
    const d6 = ac.dot(cp);
    if (d6 >= 0 and d5 <= d6) return keep(s, &.{2}, &.{1});

    const vb = d5 * d2 - d1 * d6;
    if (vb <= 0 and d2 >= 0 and d6 <= 0) {
        const den = d2 - d6;
        if (den == 0) return keep(s, &.{0}, &.{1});
        const w = d2 / den;
        return keep(s, &.{ 0, 2 }, &.{ 1 - w, w });
    }

    const va = d3 * d6 - d5 * d4;
    if (va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0) {
        const den = (d4 - d3) + (d5 - d6);
        if (den == 0) return keep(s, &.{1}, &.{1});
        const w = (d4 - d3) / den;
        return keep(s, &.{ 1, 2 }, &.{ 1 - w, w });
    }

    const sum = va + vb + vc;
    if (!(sum > 0)) return bestEdge(s);
    const v = vb / sum;
    const w = vc / sum;
    return keep(s, &.{ 0, 1, 2 }, &.{ 1 - v - w, v, w });
}

/// A triangle with no area: the nearest of its three edges.
fn bestEdge(s: *Simplex) Reduced {
    const pairs = [_][2]u8{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 2 } };
    var best: ?Reduced = null;
    var best_simplex: Simplex = undefined;
    for (pairs) |pair| {
        var edge: Simplex = .{ .len = 2 };
        edge.v[0] = s.v[pair[0]];
        edge.v[1] = s.v[pair[1]];
        const r = segment(&edge);
        if (best == null or r.point.lengthSquared() < best.?.point.lengthSquared()) {
            best = r;
            best_simplex = edge;
        }
    }
    s.* = best_simplex;
    return best.?;
}

fn tetrahedron(s: *Simplex) Reduced {
    const faces = [_][4]u8{
        .{ 0, 1, 2, 3 }, // face, then the vertex opposite it
        .{ 0, 1, 3, 2 },
        .{ 0, 2, 3, 1 },
        .{ 1, 2, 3, 0 },
    };
    var best: ?Reduced = null;
    var best_simplex: Simplex = undefined;
    var outside_any = false;
    for (faces) |f| {
        const a = s.v[f[0]].w;
        const n = Vec3.cross(s.v[f[1]].w.sub(a), s.v[f[2]].w.sub(a));
        const origin_side = n.dot(a.neg());
        const other_side = n.dot(s.v[f[3]].w.sub(a));
        // A flat tetrahedron gives every face a zero `other_side`; then every face is a
        // candidate and the origin is never declared inside it.
        const outside = other_side == 0 or origin_side * other_side < 0;
        if (!outside) continue;
        outside_any = true;
        var tri: Simplex = .{ .len = 3 };
        tri.v[0] = s.v[f[0]];
        tri.v[1] = s.v[f[1]];
        tri.v[2] = s.v[f[2]];
        const r = triangle(&tri);
        if (best == null or r.point.lengthSquared() < best.?.point.lengthSquared()) {
            best = r;
            best_simplex = tri;
        }
    }
    if (!outside_any) {
        return .{ .point = .zero, .weights = .{ 0.25, 0.25, 0.25, 0.25 }, .inside = true };
    }
    s.* = best_simplex;
    return best.?;
}

// -- EPA -------------------------------------------------------------------------------

pub const Penetration = struct {
    /// How far the cores overlap along `normal`.
    depth: f32,
    /// The direction in `A − B` from the origin to the nearest boundary: translating A by
    /// `−normal · depth` separates the cores.
    normal: Vec3,
    point_a: Vec3,
    point_b: Vec3,
};

const max_vertices = 64;
const max_faces = 128;
const max_edges = 192;

const Face = struct {
    i: [3]u8,
    normal: Vec3,
    distance: f32,
};

/// The fixed directions a degenerate starting simplex is grown along, in this order.
const search_directions = [_]Vec3{
    .init(1, 0, 0),   .init(-1, 0, 0),  .init(0, 1, 0), .init(0, -1, 0),
    .init(0, 0, 1),   .init(0, 0, -1),  .init(1, 1, 1), .init(-1, -1, 1),
    .init(1, -1, -1), .init(-1, 1, -1),
};

/// The penetration of two cores GJK found meeting. Null when the difference has no volume — a
/// point, segment or flat set, which only sphere and capsule pairs produce — and the caller
/// falls back (`narrow.zig`).
pub fn penetration(a: Convex, b: Convex, start: Simplex) ?Penetration {
    var verts: [max_vertices]Vertex = undefined;
    var count: usize = 0;
    for (start.v[0..start.len]) |v| {
        verts[count] = v;
        count += 1;
    }
    // Grow to a tetrahedron with volume, adding fixed-direction supports that raise the
    // dimension. The order of `search_directions` makes the result a function of the input.
    for (search_directions) |dir| {
        if (count == 4) break;
        const v = vertex(a, b, dir);
        if (raisesDimension(verts[0..count], v.w)) {
            verts[count] = v;
            count += 1;
        }
    }
    if (count < 4) return null;
    const volume = Vec3.cross(verts[1].w.sub(verts[0].w), verts[2].w.sub(verts[0].w)).dot(verts[3].w.sub(verts[0].w));
    if (@abs(volume) < 1e-12) return null;

    var interior: Vec3 = .zero;
    for (verts[0..4]) |v| interior = interior.add(v.w);
    interior = interior.scale(0.25);

    var faces: [max_faces]Face = undefined;
    var face_count: usize = 0;
    for ([_][3]u8{ .{ 0, 1, 2 }, .{ 0, 1, 3 }, .{ 0, 2, 3 }, .{ 1, 2, 3 } }) |tri| {
        faces[face_count] = makeFace(&verts, tri, interior) orelse return null;
        face_count += 1;
    }

    var iteration: u32 = 0;
    var best: usize = 0;
    while (true) : (iteration += 1) {
        best = 0;
        for (faces[1..face_count], 1..) |f, i| {
            if (f.distance < faces[best].distance) best = i;
        }
        if (iteration >= max_epa_iterations or count >= max_vertices) break;
        const face = faces[best];
        const next = vertex(a, b, face.normal);
        if (next.w.dot(face.normal) - face.distance <= epa_tolerance) break;

        // Remove every face the new point sees, remembering the horizon: the edges of removed
        // faces that no other removed face shares.
        var edges: [max_edges][2]u8 = undefined;
        var edge_count: usize = 0;
        var write: usize = 0;
        for (faces[0..face_count]) |f| {
            if (f.normal.dot(next.w.sub(verts[f.i[0]].w)) > 0) {
                for ([_][2]u8{ .{ f.i[0], f.i[1] }, .{ f.i[1], f.i[2] }, .{ f.i[2], f.i[0] } }) |e| {
                    var shared: ?usize = null;
                    for (edges[0..edge_count], 0..) |existing, k| {
                        if ((existing[0] == e[0] and existing[1] == e[1]) or (existing[0] == e[1] and existing[1] == e[0])) shared = k;
                    }
                    if (shared) |k| {
                        edges[k] = edges[edge_count - 1];
                        edge_count -= 1;
                    } else {
                        if (edge_count == max_edges) return result(verts[0..count], face);
                        edges[edge_count] = e;
                        edge_count += 1;
                    }
                }
            } else {
                faces[write] = f;
                write += 1;
            }
        }
        face_count = write;
        const index: u8 = @intCast(count);
        verts[count] = next;
        count += 1;
        for (edges[0..edge_count]) |e| {
            if (face_count == max_faces) break;
            faces[face_count] = makeFace(&verts, .{ e[0], e[1], index }, interior) orelse continue;
            face_count += 1;
        }
        if (face_count == 0) return null;
    }
    return result(verts[0..count], faces[best]);
}

fn raisesDimension(existing: []const Vertex, p: Vec3) bool {
    const eps: f32 = 1e-9;
    switch (existing.len) {
        0 => return true,
        1 => return p.sub(existing[0].w).lengthSquared() > eps,
        2 => {
            const d = existing[1].w.sub(existing[0].w);
            return Vec3.cross(d, p.sub(existing[0].w)).lengthSquared() > eps * d.lengthSquared();
        },
        3 => {
            const n = Vec3.cross(existing[1].w.sub(existing[0].w), existing[2].w.sub(existing[0].w));
            const off = n.dot(p.sub(existing[0].w));
            return off * off > eps * n.lengthSquared();
        },
        else => return false,
    }
}

fn makeFace(verts: []const Vertex, tri: [3]u8, interior: Vec3) ?Face {
    const a = verts[tri[0]].w;
    var n = Vec3.cross(verts[tri[1]].w.sub(a), verts[tri[2]].w.sub(a));
    const len = n.length();
    if (!(len > 1e-12)) return null;
    n = n.scale(1 / len);
    var i = tri;
    if (n.dot(a.sub(interior)) < 0) {
        n = n.neg();
        i = .{ tri[0], tri[2], tri[1] };
    }
    return .{ .i = i, .normal = n, .distance = n.dot(a) };
}

fn result(verts: []const Vertex, face: Face) Penetration {
    // The origin's projection on the face, in barycentric terms, carries the witnesses.
    const p = face.normal.scale(face.distance);
    const a = verts[face.i[0]];
    const b = verts[face.i[1]];
    const c = verts[face.i[2]];
    const v0 = b.w.sub(a.w);
    const v1 = c.w.sub(a.w);
    const v2 = p.sub(a.w);
    const d00 = v0.dot(v0);
    const d01 = v0.dot(v1);
    const d11 = v1.dot(v1);
    const d20 = v2.dot(v0);
    const d21 = v2.dot(v1);
    const den = d00 * d11 - d01 * d01;
    var v: f32 = 0;
    var w: f32 = 0;
    if (den != 0) {
        v = (d11 * d20 - d01 * d21) / den;
        w = (d00 * d21 - d01 * d20) / den;
    }
    const u = 1 - v - w;
    return .{
        // A starting tetrahedron grown from fixed directions may leave the origin just outside
        // a face when the cores barely meet; that is a touch, not a negative depth.
        .depth = @max(face.distance, 0),
        .normal = face.normal,
        .point_a = a.a.scale(u).add(b.a.scale(v)).add(c.a.scale(w)),
        .point_b = a.b.scale(u).add(b.b.scale(v)).add(c.b.scale(w)),
    };
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;
const Quat = core.math.Quat;

fn box(at: Vec3, he: Vec3, rotation: Quat) Convex {
    return .{ .core = .{ .box = he }, .radius = 0, .pose = .{ .position = at, .rotation = rotation } };
}

fn pointAt(at: Vec3) Convex {
    return .{ .core = .point, .radius = 0, .pose = .at(at) };
}

test "gjk: a point's distance to a rotated box is the analytic one" {
    const b = box(.zero, .init(1, 1, 1), Quat.fromAxisAngle(Vec3.up, 0.6));
    // Along the box's own +X face normal, 2 m out: distance 1.
    const n = Quat.fromAxisAngle(Vec3.up, 0.6).rotate(Vec3.right);
    const d = distance(pointAt(n.scale(2)), b);
    try testing.expect(!d.intersect);
    try testing.expectApproxEqAbs(@as(f32, 1), d.distance, 1e-5);
    // Out past a corner: the distance to the corner.
    const corner = Quat.fromAxisAngle(Vec3.up, 0.6).rotate(.init(1, 1, 1));
    const out = corner.add(corner.normalize().scale(0.5));
    try testing.expectApproxEqAbs(@as(f32, 0.5), distance(pointAt(out), b).distance, 1e-5);
}

test "gjk: two separated boxes, and two overlapping ones" {
    const a = box(.init(3, 0.2, 0), .init(1, 1, 1), .identity);
    const b = box(.zero, .init(1, 1, 1), .identity);
    const d = distance(a, b);
    try testing.expectApproxEqAbs(@as(f32, 1), d.distance, 1e-5);
    try testing.expect(distance(box(.init(1.5, 0, 0), .init(1, 1, 1), .identity), b).intersect);
}

test "epa: overlapping boxes report their shallow axis and depth" {
    const a = box(.init(1.9, 0.3, 0.1), .init(1, 1, 1), .identity);
    const b = box(.zero, .init(1, 1, 1), .identity);
    const d = distance(a, b);
    try testing.expect(d.intersect);
    const p = penetration(a, b, d.simplex).?;
    try testing.expectApproxEqAbs(@as(f32, 0.1), p.depth, 1e-4);
    // Pushing A along −normal separates it; the shallow axis is −X in A − B.
    try testing.expectApproxEqAbs(@as(f32, -1), p.normal.x, 1e-4);
}

test "epa: a point deep inside a box escapes through the nearest face" {
    const b = box(.zero, .init(1, 2, 3), .identity);
    const d = distance(pointAt(.init(0.7, 0, 0)), b);
    try testing.expect(d.intersect);
    const p = penetration(pointAt(.init(0.7, 0, 0)), b, d.simplex).?;
    try testing.expectApproxEqAbs(@as(f32, 0.3), p.depth, 1e-4);
}

test "epa: a difference with no volume returns null for the caller's fallback" {
    const d = distance(pointAt(.zero), pointAt(.zero));
    try testing.expect(d.intersect);
    try testing.expect(penetration(pointAt(.zero), pointAt(.zero), d.simplex) == null);
}
