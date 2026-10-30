//! String pulling: the corners of the shortest line through a path's portals, by the simple
//! stupid funnel algorithm on X and Z (`agents.md` §5).
//!
//! A portal is the whole edge two polygons share, drawn in a little where it ends at a wall, so a
//! corner is rounded by a hair and an agent never walks a boundary's own line. A link ends the
//! funnel at the end it leaves by, and a new one starts where it lands.

const std = @import("std");
const core = @import("core");

const detail = @import("detail.zig");
const poly = @import("poly.zig");
const search = @import("search.zig");

const Mesh = poly.Mesh;
const Step = search.Step;
const Vec3 = core.math.Vec3;
const none_link = search.none_link;
const turnf = detail.turnf;

/// How far a portal is drawn in at a wall, metres, and at most this share of its length.
const inset: f32 = 0.02;
const inset_share: f32 = 0.1;

pub const Corner = struct {
    point: Vec3,
    /// The polygon the path is in when it leaves this corner.
    polygon: u32,
    /// The link this corner begins, or `none_link`.
    link: u32 = none_link,
    /// Whether that link is crossed from its `to` end.
    reversed: bool = false,
};

/// The corners from `from`, which is not one of them, to `to`, which is the last, written to `out`
/// and cut off when it is full. `path` is what `Query.find` wrote. A path that does not belong to
/// `mesh` stops at the step that does not join.
pub fn corners(mesh: *const Mesh, path: []const Step, from: Vec3, to: Vec3, out: []Corner) []Corner {
    var n: usize = 0;
    if (path.len == 0 or out.len == 0) return out[0..0];
    var begin: usize = 0;
    var apex = from;
    while (n < out.len) {
        var end = begin;
        while (end + 1 < path.len and path[end + 1].link == none_link) end += 1;
        const crossing = if (end + 1 < path.len) path[end + 1] else null;
        var stop = to;
        var land = to;
        if (crossing) |c| {
            const l = &mesh.links[c.link];
            stop = if (c.reversed) l.to else l.from;
            land = if (c.reversed) l.from else l.to;
        }
        const pulled = pull(mesh, path[begin .. end + 1], apex, stop, out, n) orelse return out[0..n];
        n = pulled;
        const c = crossing orelse return out[0..n];
        if (n == 0 or n > out.len) return out[0..n];
        out[n - 1].link = c.link;
        out[n - 1].reversed = c.reversed;
        out[n - 1].polygon = path[end].polygon;
        apex = land;
        begin = end + 1;
    }
    return out[0..n];
}

const Portal = struct { left: Vec3, right: Vec3 };

/// The portal from `a` into `b`, or null if they share no edge.
fn portalBetween(mesh: *const Mesh, a: u32, b: u32) ?Portal {
    const p = &mesh.polygons[a];
    const edge = std.mem.indexOfScalar(u32, p.neighbours[0..p.count], b) orelse return null;
    const right_vertex = p.vertices[edge];
    const left_vertex = p.vertices[(edge + 1) % p.count];
    var right = mesh.position(right_vertex);
    var left = mesh.position(left_vertex);
    const span = left.sub(right);
    const length = span.length();
    if (length > 0) {
        const by = @min(inset, length * inset_share) / length;
        if (atWall(mesh, a, b, right_vertex)) right = right.add(span.scale(by));
        if (atWall(mesh, a, b, left_vertex)) left = left.sub(span.scale(by));
    }
    return .{ .left = left, .right = right };
}

/// Whether either polygon of a portal has a boundary edge at vertex `v`.
fn atWall(mesh: *const Mesh, a: u32, b: u32, v: u32) bool {
    for ([_]u32{ a, b }) |pi| {
        const p = &mesh.polygons[pi];
        for (0..p.count) |e| {
            if (p.neighbours[e] != poly.none_polygon) continue;
            if (p.vertices[e] == v or p.vertices[(e + 1) % p.count] == v) return true;
        }
    }
    return false;
}

fn same(a: Vec3, b: Vec3) bool {
    return a.x == b.x and a.z == b.z;
}

/// One funnel through `path`, from `start` to `stop`, appended to `out` at `n`. Answers the new
/// count, or null if the path does not join.
fn pull(mesh: *const Mesh, path: []const Step, start: Vec3, stop: Vec3, out: []Corner, at: usize) ?usize {
    var n = at;
    const last_polygon = path[path.len - 1].polygon;
    const portals = path.len; // The last is the stop.
    var apex = start;
    var left = start;
    var right = start;
    var left_i: usize = 0;
    var right_i: usize = 0;
    var i: usize = 0;
    var emitted_from = start;
    // Each restart moves the apex on a portal, so this is never reached by a path that joins. It
    // runs inside a tick, and a tick must end whatever it is handed.
    var restarts = 2 * portals + 8;
    while (i < portals and n < out.len and restarts > 0) : (i += 1) {
        var portal: Portal = .{ .left = stop, .right = stop };
        if (i + 1 < portals) portal = portalBetween(mesh, path[i].polygon, path[i + 1].polygon) orelse return null;
        if (turnf(apex, right, portal.right) >= 0) {
            if (same(apex, right) or turnf(apex, left, portal.right) < 0) {
                right = portal.right;
                right_i = i;
            } else {
                if (!same(left, emitted_from)) {
                    out[n] = .{ .point = left, .polygon = path[@min(left_i + 1, path.len - 1)].polygon };
                    n += 1;
                    emitted_from = left;
                }
                restarts -= 1;
                apex = left;
                right = left;
                right_i = left_i;
                i = left_i;
                continue;
            }
        }
        if (turnf(apex, left, portal.left) <= 0) {
            if (same(apex, left) or turnf(apex, right, portal.left) > 0) {
                left = portal.left;
                left_i = i;
            } else {
                if (!same(right, emitted_from)) {
                    out[n] = .{ .point = right, .polygon = path[@min(right_i + 1, path.len - 1)].polygon };
                    n += 1;
                    emitted_from = right;
                }
                restarts -= 1;
                apex = right;
                left = right;
                left_i = right_i;
                i = right_i;
                continue;
            }
        }
    }
    // The last portal is the stop on both sides, so the funnel may already have emitted it.
    if (n < out.len and !(n > at and same(out[n - 1].point, stop))) {
        out[n] = .{ .point = stop, .polygon = last_polygon };
        n += 1;
    }
    return n;
}
