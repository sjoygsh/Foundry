//! A mesh as coloured triangles, for a sample to draw (`navigation.md` §8).
//!
//! Plain positions and premultiplied colours: no renderer is named here. Each polygon's detail
//! triangles in its region's colour, lifted above the floor so they do not fight its depth, then
//! a strip along each boundary edge and a thinner one along each edge between neighbours.

const std = @import("std");
const core = @import("core");

const poly = @import("poly.zig");

const Vec3 = core.math.Vec3;

pub const lift: f32 = 0.02;
pub const boundary_width: f32 = 0.03;
pub const neighbour_width: f32 = 0.01;

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
    return n;
}

/// Writes the view into `out`, which holds `debugViewCount` vertices, and returns what it wrote.
pub fn debugView(mesh: *const poly.Mesh, out: []ViewVertex) []ViewVertex {
    var n: usize = 0;
    const up: Vec3 = .init(0, lift, 0);
    for (mesh.polygons, 0..) |*p, pi| {
        const fill = color(p.region, 1, 0.45);
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
