//! `locate`: the polygon under a point, and the nearest point on its detail surface
//! (`navigation.md` §6).
//!
//! **Allocates nothing, refuses nothing by error.** A point or extent that is not finite, or an
//! extent below zero, locates nothing. Polygons are scanned in index order and ties go to the
//! lower index (I9). M33 decides whether its agents need something faster than a scan.

const std = @import("std");
const core = @import("core");

const detail_mod = @import("detail.zig");
const poly = @import("poly.zig");

const Vec3 = core.math.Vec3;
const turnf = detail_mod.turnf;

pub const Located = struct {
    polygon: u32,
    /// On the polygon's detail surface.
    point: Vec3,
};

/// The polygon nearest `point` whose nearest point lies within `extent` of it on every axis, and
/// that nearest point. Over two floors, the one nearer in height wins.
pub fn locate(mesh: *const poly.Mesh, point: Vec3, extent: Vec3) ?Located {
    if (!point.isFinite() or !extent.isFinite()) return null;
    if (extent.x < 0 or extent.y < 0 or extent.z < 0) return null;
    var best: ?Located = null;
    var best_d = std.math.inf(f32);
    var loop: [poly.max_polygon_vertices]Vec3 = undefined;
    for (mesh.polygons, 0..) |*p, pi| {
        for (p.slice(), 0..) |v, i| loop[i] = mesh.position(v);
        const pts = loop[0..p.count];
        var lo = pts[0];
        var hi = pts[0];
        for (pts[1..]) |v| {
            lo = .init(@min(lo.x, v.x), @min(lo.y, v.y), @min(lo.z, v.z));
            hi = .init(@max(hi.x, v.x), @max(hi.y, v.y), @max(hi.z, v.z));
        }
        if (point.x + extent.x < lo.x or point.x - extent.x > hi.x or point.z + extent.z < lo.z or point.z - extent.z > hi.z) continue;
        const xz = nearestInside(pts, point.x, point.z);
        const y = heightOn(mesh, @intCast(pi), xz[0], xz[1]) orelse continue;
        const near: Vec3 = .init(xz[0], y, xz[1]);
        const d = near.sub(point);
        if (@abs(d.x) > extent.x or @abs(d.y) > extent.y or @abs(d.z) > extent.z) continue;
        const dist = d.lengthSquared();
        if (dist < best_d) {
            best_d = dist;
            best = .{ .polygon = @intCast(pi), .point = near };
        }
    }
    return best;
}

/// The height of polygon `pi`'s surface at `(x, z)`: its detail where it has one, otherwise the
/// plane of its own vertices.
pub fn heightOn(mesh: *const poly.Mesh, pi: u32, x: f32, z: f32) ?f32 {
    if (mesh.detail.meshes.len > pi) {
        const m = mesh.detail.meshes[pi];
        return detail_mod.surfaceHeight(
            mesh.detail.vertices[m.vertex_base..][0..m.vertex_count],
            mesh.detail.triangles[m.triangle_base..][0..m.triangle_count],
            x,
            z,
        );
    }
    const p = &mesh.polygons[pi];
    var pts: [poly.max_polygon_vertices]Vec3 = undefined;
    var tris: [poly.max_polygon_vertices][3]u32 = undefined;
    for (p.slice(), 0..) |v, i| pts[i] = mesh.position(v);
    for (0..p.count - 2) |i| tris[i] = .{ 0, @intCast(i + 1), @intCast(i + 2) };
    return detail_mod.surfaceHeight(pts[0..p.count], tris[0 .. p.count - 2], x, z);
}

/// `(x, z)` itself if it is inside the convex counter-clockwise loop, otherwise the nearest
/// point on its boundary.
fn nearestInside(loop: []const Vec3, x: f32, z: f32) [2]f32 {
    const p: Vec3 = .init(x, 0, z);
    var inside = true;
    for (loop, 0..) |a, i| {
        if (turnf(a, loop[(i + 1) % loop.len], p) < 0) inside = false;
    }
    if (inside) return .{ x, z };
    var best: [2]f32 = .{ loop[0].x, loop[0].z };
    var best_d = std.math.inf(f32);
    for (loop, 0..) |a, i| {
        const b = loop[(i + 1) % loop.len];
        const ex = b.x - a.x;
        const ez = b.z - a.z;
        const len2 = ex * ex + ez * ez;
        const t = if (len2 > 0) std.math.clamp(((x - a.x) * ex + (z - a.z) * ez) / len2, 0, 1) else 0;
        const qx = a.x + t * ex;
        const qz = a.z + t * ez;
        const d = (qx - x) * (qx - x) + (qz - z) * (qz - z);
        if (d < best_d) {
            best_d = d;
            best = .{ qx, qz };
        }
    }
    return best;
}
