//! Moving along a mesh's surface (`agents.md` §6.2): a segment walked polygon by polygon, sliding
//! along a boundary it meets, so whatever an agent asks for it stays on the mesh.
//!
//! **Allocates nothing and always ends:** at most `max_visits` polygons or slides a move. A move
//! is a tick's worth, so it crosses a few polygons at most.

const std = @import("std");
const core = @import("core");

const detail = @import("detail.zig");
const locate = @import("locate.zig");
const poly = @import("poly.zig");

const Mesh = poly.Mesh;
const Vec3 = core.math.Vec3;
const turnf = detail.turnf;

pub const max_visits = 16;
/// How far outside an edge still counts as on it, in `turnf`'s square metres.
const tolerance: f32 = 1e-5;

pub const Moved = struct {
    polygon: u32,
    point: Vec3,
    /// Whether a boundary shortened the move.
    slid: bool = false,
};

/// Whether `(x, z)` of `point` is inside polygon `pi`, edges included.
pub fn contains(mesh: *const Mesh, pi: u32, point: Vec3) bool {
    const p = &mesh.polygons[pi];
    for (0..p.count) |e| {
        const a = mesh.position(p.vertices[e]);
        const b = mesh.position(p.vertices[(e + 1) % p.count]);
        if (turnf(a, b, point) < -tolerance) return false;
    }
    return true;
}

/// From `from`, in polygon `start`, toward `to`. Answers where it stopped, on the surface.
pub fn move(mesh: *const Mesh, start: u32, from: Vec3, to: Vec3) Moved {
    var polygon = start;
    var at = from;
    var goal = to;
    var slid = false;
    var visits: u32 = 0;
    while (visits < max_visits) : (visits += 1) {
        if (contains(mesh, polygon, goal)) {
            at = goal;
            break;
        }
        const p = &mesh.polygons[polygon];
        // The first edge the segment leaves through.
        var exit: ?usize = null;
        var exit_t: f32 = std.math.inf(f32);
        for (0..p.count) |e| {
            const a = mesh.position(p.vertices[e]);
            const b = mesh.position(p.vertices[(e + 1) % p.count]);
            const d_to = turnf(a, b, goal);
            if (d_to >= 0) continue;
            const d_from = @max(turnf(a, b, at), 0);
            const t = d_from / (d_from - d_to);
            if (t < exit_t) {
                exit_t = t;
                exit = e;
            }
        }
        const e = exit orelse break;
        at = at.add(goal.sub(at).scale(exit_t));
        const next = p.neighbours[e];
        if (next != poly.none_polygon) {
            polygon = next;
            continue;
        }
        // A wall: what is left of the move, along it.
        slid = true;
        const a = mesh.position(p.vertices[e]);
        const b = mesh.position(p.vertices[(e + 1) % p.count]);
        const ex = b.x - a.x;
        const ez = b.z - a.z;
        const len2 = ex * ex + ez * ez;
        if (len2 == 0) break;
        const along = std.math.clamp(((goal.x - a.x) * ex + (goal.z - a.z) * ez) / len2, 0, 1);
        goal = .init(a.x + along * ex, at.y, a.z + along * ez);
    }
    const y = locate.heightOn(mesh, polygon, at.x, at.z) orelse at.y;
    return .{ .polygon = polygon, .point = .init(at.x, y, at.z), .slid = slid };
}
