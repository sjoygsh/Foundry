//! A mesh as coloured triangles, for a sample to draw (`navigation.md` §8).
//!
//! Plain positions and premultiplied colours: no renderer is named here. Each polygon's detail
//! triangles in its region's colour, or its area's if it has one, lifted above the floor so they
//! do not fight its depth, then a strip along each boundary edge and a thinner one along each
//! edge between neighbours, and each link as an arc. `debugAgents` writes each agent's path and
//! target as a mesh of their own, because they change far more often.

const std = @import("std");
const core = @import("core");

const crossing = @import("crossing.zig");
const crowd_mod = @import("crowd.zig");
const funnel = @import("funnel.zig");
const poly = @import("poly.zig");

const Vec3 = core.math.Vec3;

pub const lift: f32 = 0.02;
pub const boundary_width: f32 = 0.03;
pub const neighbour_width: f32 = 0.01;
pub const link_width: f32 = 0.05;
pub const path_width: f32 = 0.04;
/// Strips an arc is drawn with.
const link_segments = 8;
/// Corners of one agent's path that are drawn, and sides of the ring at its target.
const path_corners = 16;
const ring_sides = 8;
const ring_radius: f32 = 0.2;

pub const ViewVertex = struct {
    position: Vec3,
    /// Premultiplied by its alpha.
    color: [4]f32,
};

/// Twelve distinguishable colours, indexed by region.
const palette = [12][3]f32{
    .{ 0.90, 0.30, 0.25 }, .{ 0.25, 0.65, 0.90 }, .{ 0.35, 0.80, 0.35 }, .{ 0.95, 0.75, 0.20 },
    .{ 0.70, 0.40, 0.90 }, .{ 0.20, 0.80, 0.75 }, .{ 0.95, 0.50, 0.70 }, .{ 0.60, 0.60, 0.25 },
    .{ 0.40, 0.45, 0.95 }, .{ 0.85, 0.55, 0.30 }, .{ 0.45, 0.85, 0.60 }, .{ 0.75, 0.75, 0.75 },
};

/// Each area above unmarked floor, so that a cost shows at a glance. Indexed by area, less one.
const area_palette = [8][3]f32{
    .{ 0.55, 0.35, 0.15 }, .{ 0.15, 0.45, 0.85 }, .{ 0.75, 0.20, 0.55 }, .{ 0.85, 0.85, 0.20 },
    .{ 0.20, 0.75, 0.30 }, .{ 0.90, 0.45, 0.10 }, .{ 0.50, 0.50, 0.90 }, .{ 0.30, 0.30, 0.30 },
};

fn premultiplied(c: [3]f32, alpha: f32) [4]f32 {
    return .{ c[0] * alpha, c[1] * alpha, c[2] * alpha, alpha };
}

fn linkColor(link: *const @import("link.zig").Link) [4]f32 {
    return premultiplied(switch (link.kind) {
        .jump => .{ 1.0, 0.6, 0.1 },
        .drop => .{ 0.95, 0.2, 0.2 },
        .ladder => .{ 0.2, 0.9, 0.4 },
    }, 0.9);
}

fn fillOf(p: *const poly.Polygon) [4]f32 {
    if (p.area == 0) return color(p.region, 1, 0.45);
    return premultiplied(area_palette[(p.area - 1) % area_palette.len], 0.7);
}

fn color(region: u16, darken: f32, alpha: f32) [4]f32 {
    const c = palette[region % palette.len];
    return .{ c[0] * darken * alpha, c[1] * darken * alpha, c[2] * darken * alpha, alpha };
}

/// How many vertices `debugView` writes.
pub fn debugViewCount(mesh: *const poly.Mesh) usize {
    var n: usize = 0;
    for (mesh.polygons, 0..) |*p, pi| {
        n += 3 * if (mesh.detail.meshes.len > pi) mesh.detail.meshes[pi].triangle_count else @as(u32, p.count) - 2;
        for (p.neighbours[0..p.count]) |q| {
            if (q == poly.none_polygon or q > pi) n += 6;
        }
    }
    return n + mesh.links.len * link_segments * 6;
}

/// Writes the view into `out`, which holds `debugViewCount` vertices, and returns what it wrote.
pub fn debugView(mesh: *const poly.Mesh, out: []ViewVertex) []ViewVertex {
    var n: usize = 0;
    const up: Vec3 = .init(0, lift, 0);
    for (mesh.polygons, 0..) |*p, pi| {
        const fill = fillOf(p);
        if (mesh.detail.meshes.len > pi) {
            for (0..mesh.detail.meshes[pi].triangle_count) |t| {
                for (mesh.detail.triangle(@intCast(pi), @intCast(t))) |v| {
                    out[n] = .{ .position = v.add(up), .color = fill };
                    n += 1;
                }
            }
        } else {
            for (1..p.count - 1) |i| {
                for ([_]u32{ p.vertices[0], p.vertices[i], p.vertices[i + 1] }) |v| {
                    out[n] = .{ .position = mesh.position(v).add(up), .color = fill };
                    n += 1;
                }
            }
        }
        for (0..p.count) |e| {
            const q = p.neighbours[e];
            if (q != poly.none_polygon and q < pi) continue;
            const boundary = q == poly.none_polygon;
            const a = mesh.position(p.vertices[e]).add(up.scale(1.25));
            const b = mesh.position(p.vertices[(e + 1) % p.count]).add(up.scale(1.25));
            const width = if (boundary) boundary_width else neighbour_width;
            const c = if (boundary) color(p.region, 0.5, 0.9) else color(p.region, 1, 0.3);
            n += strip(out[n..], a, b, width, c);
        }
    }
    for (mesh.links) |*l| {
        const c = linkColor(l);
        var last = l.from;
        for (1..link_segments + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / link_segments;
            const at = crossing.at(l.kind, l.from, l.to, l.arc, arc_speed, t);
            n += strip(out[n..], last.add(up.scale(2)), at.add(up.scale(2)), link_width, c);
            last = at;
        }
    }
    return out[0..n];
}

/// Any speed: it shapes only where a drop or ladder turns, and a view has none to give.
const arc_speed: f32 = 2;

/// How many vertices `debugAgents` can write: every agent's whole allowance.
pub fn debugAgentsCount(crowd: *const crowd_mod.Crowd) usize {
    var agents: usize = 0;
    for (crowd.agents) |*a| agents += @intFromBool(a.used);
    return agents * (path_corners + ring_sides) * 6;
}

/// Each agent's path from where it is, and a ring at its goal, in `out`, which holds
/// `debugAgentsCount` vertices. Answers what it wrote. Allocates nothing.
pub fn debugAgents(crowd: *const crowd_mod.Crowd, out: []ViewVertex) []ViewVertex {
    const mesh = crowd.mesh orelse return out[0..0];
    const path_color = premultiplied(.{ 1, 1, 1 }, 0.8);
    const blocked_color = premultiplied(.{ 1, 0.15, 0.1 }, 0.9);
    const up: Vec3 = .init(0, lift * 3, 0);
    // A unit circle, by the rotation of one side, so no trig is read.
    const step_cos: f32 = 0.70710678;
    const step_sin: f32 = 0.70710678;
    var n: usize = 0;
    for (crowd.agents) |*a| {
        if (!a.used or a.count == a.head) continue;
        const c = if (a.state == .blocked) blocked_color else path_color;
        var corners: [path_corners]funnel.Corner = undefined;
        var last = a.position;
        for (funnel.corners(mesh, a.corridor(), a.position, a.goal.point, &corners)) |corner| {
            n += strip(out[n..], last.add(up), corner.point.add(up), path_width, c);
            last = corner.point;
        }
        var x: f32 = ring_radius;
        var z: f32 = 0;
        const centre = a.goal.point.add(up);
        for (0..ring_sides) |_| {
            const next_x = x * step_cos - z * step_sin;
            const next_z = x * step_sin + z * step_cos;
            n += strip(out[n..], centre.add(.init(x, 0, z)), centre.add(.init(next_x, 0, next_z)), path_width, c);
            x = next_x;
            z = next_z;
        }
    }
    return out[0..n];
}

/// A flat quad of `width` centred on `a → b`, as two triangles counter-clockwise from +Y.
fn strip(out: []ViewVertex, a: Vec3, b: Vec3, width: f32, c: [4]f32) usize {
    const dx = b.x - a.x;
    const dz = b.z - a.z;
    const len = @sqrt(dx * dx + dz * dz);
    const side: Vec3 = if (len > 0) .init(dz / len * width / 2, 0, -dx / len * width / 2) else .zero;
    const quad = [4]Vec3{ a.sub(side), b.sub(side), b.add(side), a.add(side) };
    for ([_]usize{ 0, 1, 2, 0, 2, 3 }, 0..) |k, i| out[i] = .{ .position = quad[k], .color = c };
    return 6;
}
