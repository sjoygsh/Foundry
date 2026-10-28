//! The detail mesh: each polygon's surface triangulated to follow the floor within
//! `detail_max_error` (`navigation.md` §5.7).
//!
//! **Per polygon, in three passes.** Its edges are sampled every `detail_sample_distance` and
//! the samples that stray from the edge are kept; the interior is sampled on the same spacing and
//! the farthest sample from the surface is inserted while it strays; the points are triangulated
//! as a Delaunay triangulation that keeps the polygon's edges. A polygon is convex, so its
//! boundary with edge samples is its points' hull: the hull is ear-clipped, and interior points
//! go in by splitting the triangle they fall in and flipping edges until each is Delaunay,
//! never flipping a hull edge.
//!
//! **A shared edge is sampled the same from both sides**: in a fixed direction between its
//! two ends, with heights looked up by nearness to the edge's own height, never by region.
//!
//! Heights come from the open field, whose floors are within a cell height of the triangles.
//! Across a riser no sample can follow the floor; between samples the surface is a plane.

const std = @import("std");
const core = @import("core");

const config_mod = @import("config.zig");
const open_mod = @import("open.zig");
const poly = @import("poly.zig");

const Allocator = std.mem.Allocator;
const OpenField = open_mod.OpenField;
const Vec3 = core.math.Vec3;

/// The most detail vertices one polygon gets: its own, its edge samples and its interior.
pub const max_polygon_vertices: usize = 256;
/// The most samples kept along one edge, ends excluded.
pub const max_edge_samples: usize = 32;

pub const SubMesh = struct {
    vertex_base: u32,
    vertex_count: u32,
    triangle_base: u32,
    triangle_count: u32,
};

pub const Detail = struct {
    /// In the world. A polygon's own vertices come first in its range, in its order.
    vertices: []Vec3 = &.{},
    /// Indices into the polygon's range, counter-clockwise seen from +Y.
    triangles: [][3]u32 = &.{},
    /// One per polygon, in polygon order.
    meshes: []SubMesh = &.{},

    pub fn deinit(self: *Detail, gpa: Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.triangles);
        gpa.free(self.meshes);
        self.* = .{};
    }

    pub fn triangle(self: *const Detail, polygon: u32, t: u32) [3]Vec3 {
        const m = self.meshes[polygon];
        const tri = self.triangles[m.triangle_base + t];
        const v = self.vertices[m.vertex_base..];
        return .{ v[tri[0]], v[tri[1]], v[tri[2]] };
    }
};

pub const Settings = struct {
    sample_distance: f32,
    max_error: f32,

    pub fn of(c: config_mod.Config) Settings {
        return .{ .sample_distance = c.detail_sample_distance, .max_error = c.detail_max_error };
    }
};

pub fn build(gpa: Allocator, mesh: *const poly.Mesh, field: *const OpenField, settings: Settings) Allocator.Error!Detail {
    var vertices: std.ArrayList(Vec3) = .empty;
    errdefer vertices.deinit(gpa);
    var triangles: std.ArrayList([3]u32) = .empty;
    errdefer triangles.deinit(gpa);
    const meshes = try gpa.alloc(SubMesh, mesh.polygons.len);
    errdefer gpa.free(meshes);

    var work: Work = .{};
    defer work.deinit(gpa);
    for (mesh.polygons, meshes) |*p, *out| {
        try work.polygon(gpa, mesh, field, p, settings);
        out.* = .{
            .vertex_base = @intCast(vertices.items.len),
            .vertex_count = @intCast(work.points.items.len),
            .triangle_base = @intCast(triangles.items.len),
            .triangle_count = @intCast(work.tris.items.len),
        };
        try vertices.appendSlice(gpa, work.points.items);
        try triangles.appendSlice(gpa, work.tris.items);
    }
    const owned_vertices = try vertices.toOwnedSlice(gpa);
    errdefer gpa.free(owned_vertices);
    const owned_triangles = try triangles.toOwnedSlice(gpa);
    return .{ .vertices = owned_vertices, .triangles = owned_triangles, .meshes = meshes };
}

/// One polygon's scratch, reused for the next.
const Work = struct {
    points: std.ArrayList(Vec3) = .empty,
    tris: std.ArrayList([3]u32) = .empty,
    hull: std.ArrayList(u32) = .empty,
    samples: std.ArrayList(Vec3) = .empty,
    kept: std.ArrayList(usize) = .empty,
    candidates: std.ArrayList(Vec3) = .empty,
    stack: std.ArrayList([2]u32) = .empty,

    fn deinit(self: *Work, gpa: Allocator) void {
        self.points.deinit(gpa);
        self.tris.deinit(gpa);
        self.hull.deinit(gpa);
        self.samples.deinit(gpa);
        self.kept.deinit(gpa);
        self.candidates.deinit(gpa);
        self.stack.deinit(gpa);
    }

    fn polygon(self: *Work, gpa: Allocator, mesh: *const poly.Mesh, field: *const OpenField, p: *const poly.Polygon, settings: Settings) Allocator.Error!void {
        self.points.clearRetainingCapacity();
        self.tris.clearRetainingCapacity();
        self.hull.clearRetainingCapacity();
        for (p.slice()) |v| try self.points.append(gpa, mesh.position(v));
        const own = p.count;

        // The hull: each vertex, then the kept samples of the edge leaving it.
        for (0..own) |i| {
            try self.hull.append(gpa, @intCast(i));
            if (settings.sample_distance == 0) continue;
            try self.edgeSamples(gpa, field, self.points.items[i], self.points.items[(i + 1) % own], settings);
            for (self.samples.items) |s| {
                if (self.points.items.len >= max_polygon_vertices) break;
                try self.hull.append(gpa, @intCast(self.points.items.len));
                try self.points.append(gpa, s);
            }
        }
        try self.triangulateHull(gpa);
        self.makeDelaunay();
        if (settings.sample_distance == 0) return;

        // The interior, farthest from the surface first, while it strays.
        self.candidates.clearRetainingCapacity();
        try self.interiorSamples(gpa, field, p, own, settings);
        while (self.points.items.len < max_polygon_vertices and self.candidates.items.len > 0) {
            var worst: ?usize = null;
            var worst_error: f32 = settings.max_error;
            for (self.candidates.items, 0..) |c, i| {
                const surface = self.heightAt(c.x, c.z) orelse continue;
                const e = @abs(surface - c.y);
                if (e > worst_error) {
                    worst_error = e;
                    worst = i;
                }
            }
            const chosen = worst orelse break;
            const point = self.candidates.orderedRemove(chosen);
            try self.insert(gpa, point);
        }
    }

    /// The samples kept along `a → b`, in that order, ends excluded.
    fn edgeSamples(self: *Work, gpa: Allocator, field: *const OpenField, a: Vec3, b: Vec3, settings: Settings) Allocator.Error!void {
        self.samples.clearRetainingCapacity();
        // In a fixed direction, so the edge shared with a neighbour gives the same samples.
        const forward = a.x < b.x or (a.x == b.x and a.z < b.z);
        const lo = if (forward) a else b;
        const hi = if (forward) b else a;
        const d = hi.sub(lo);
        const length = @sqrt(d.x * d.x + d.z * d.z);
        const n: usize = @min(@as(usize, @intFromFloat(@floor(length / settings.sample_distance))), max_edge_samples + 1);
        if (n < 2) return;
        var line: [max_edge_samples + 2]Vec3 = undefined;
        for (0..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            var s = lo.add(d.scale(t));
            if (i != 0 and i != n) s.y = sampleHeight(field, s, 0) orelse s.y;
            line[i] = s;
        }
        // Douglas–Peucker on height: the ends, then the farthest sample while it strays.
        self.kept.clearRetainingCapacity();
        try self.kept.appendSlice(gpa, &.{ 0, n });
        var k: usize = 0;
        while (k + 1 < self.kept.items.len) {
            const ia = self.kept.items[k];
            const ib = self.kept.items[k + 1];
            var farthest: ?usize = null;
            var deviation: f32 = settings.max_error;
            for (ia + 1..ib) |m| {
                const dev = distanceToSegment(line[m], line[ia], line[ib]);
                if (dev > deviation) {
                    deviation = dev;
                    farthest = m;
                }
            }
            if (farthest) |m| {
                if (self.kept.items.len - 2 >= max_edge_samples) break;
                try self.kept.insert(gpa, k + 1, m);
            } else k += 1;
        }
        const inner = self.kept.items[1 .. self.kept.items.len - 1];
        if (forward) {
            for (inner) |m| try self.samples.append(gpa, line[m]);
        } else {
            var r = inner.len;
            while (r > 0) {
                r -= 1;
                try self.samples.append(gpa, line[inner[r]]);
            }
        }
    }

    /// Grid points inside the polygon, at least half a spacing from its edges, with the
    /// height of the polygon's own region where it has one.
    fn interiorSamples(self: *Work, gpa: Allocator, field: *const OpenField, p: *const poly.Polygon, own: usize, settings: Settings) Allocator.Error!void {
        const pts = self.points.items[0..own];
        var lo = pts[0];
        var hi = pts[0];
        var average: f32 = 0;
        for (pts) |v| {
            lo = .init(@min(lo.x, v.x), 0, @min(lo.z, v.z));
            hi = .init(@max(hi.x, v.x), 0, @max(hi.z, v.z));
            average += v.y;
        }
        average /= @floatFromInt(own);
        const step = settings.sample_distance;
        const origin = field.grid.origin;
        // Aligned to the grid's origin, so neighbouring polygons sample one lattice.
        const x0 = @ceil((lo.x - origin.x) / step);
        const z0 = @ceil((lo.z - origin.z) / step);
        var zi = z0;
        while (origin.z + zi * step <= hi.z) : (zi += 1) {
            var xi = x0;
            while (origin.x + xi * step <= hi.x) : (xi += 1) {
                const x = origin.x + xi * step;
                const z = origin.z + zi * step;
                if (insideBy(pts, x, z) < step / 2) continue;
                const y = sampleHeight(field, .init(x, average, z), p.region) orelse continue;
                try self.candidates.append(gpa, .init(x, y, z));
            }
        }
    }

    fn triangulateHull(self: *Work, gpa: Allocator) Allocator.Error!void {
        // A convex loop, some vertices in line: clip strictly convex tips, shortest diagonal
        // first, lowest place among equals.
        var loop = self.hull;
        while (loop.items.len > 3) {
            const n = loop.items.len;
            var best: ?usize = null;
            var best_len: f32 = 0;
            for (0..n) |i| {
                const a = self.points.items[loop.items[(i + n - 1) % n]];
                const b = self.points.items[loop.items[i]];
                const c = self.points.items[loop.items[(i + 1) % n]];
                if (turnf(a, b, c) <= 0) continue;
                const len = (c.x - a.x) * (c.x - a.x) + (c.z - a.z) * (c.z - a.z);
                if (best == null or len < best_len) {
                    best = i;
                    best_len = len;
                }
            }
            const i = best orelse break;
            try self.tris.append(gpa, .{ loop.items[(i + n - 1) % n], loop.items[i], loop.items[(i + 1) % n] });
            _ = loop.orderedRemove(i);
        }
        if (loop.items.len == 3) {
            const t = [3]u32{ loop.items[0], loop.items[1], loop.items[2] };
            if (turnf(self.points.items[t[0]], self.points.items[t[1]], self.points.items[t[2]]) > 0) try self.tris.append(gpa, t);
        }
        self.hull = loop;
    }

    /// Lawson's flips over every interior edge until none is left with its far vertex inside the
    /// circle, so insertion starts from a Delaunay triangulation and keeps one. Each flip makes
    /// the triangulation strictly better, so it ends; the budget is a guard, never reached in the
    /// suite.
    fn makeDelaunay(self: *Work) void {
        var budget: usize = 4 * self.tris.items.len * self.tris.items.len + 16;
        var changed = true;
        while (changed and budget > 0) {
            changed = false;
            for (0..self.tris.items.len) |ti| for (0..3) |k| {
                if (budget == 0) return;
                const t = self.tris.items[ti];
                const a = t[k];
                const b = t[(k + 1) % 3];
                const c = t[(k + 2) % 3];
                const ui = self.across(b, a) orelse continue;
                const q = self.opposite(ui, b, a);
                const P = self.points.items;
                if (!inCircle(P[a], P[b], P[c], P[q])) continue;
                budget -= 1;
                self.tris.items[ti] = .{ a, q, c };
                self.tris.items[ui] = .{ q, b, c };
                changed = true;
                break;
            };
        }
    }

    /// Splits the triangle `point` falls in, or the two either side of the edge it falls on,
    /// and flips edges until every one is Delaunay again. A point on a vertex or on the hull is
    /// left out: interior samples keep half a spacing from it.
    fn insert(self: *Work, gpa: Allocator, point: Vec3) Allocator.Error!void {
        const eps: f32 = 1e-6;
        const pts = self.points.items;
        var found: ?usize = null;
        var on_edge: ?u2 = null;
        for (self.tris.items, 0..) |t, ti| {
            const w = [3]f32{
                turnf(pts[t[0]], pts[t[1]], point),
                turnf(pts[t[1]], pts[t[2]], point),
                turnf(pts[t[2]], pts[t[0]], point),
            };
            if (w[0] < -eps or w[1] < -eps or w[2] < -eps) continue;
            var zeros: u32 = 0;
            for (w, 0..) |value, k| if (@abs(value) <= eps) {
                zeros += 1;
                on_edge = @intCast(k);
            };
            if (zeros > 1) return;
            if (zeros == 0) on_edge = null;
            found = ti;
            break;
        }
        const ti = found orelse return;
        const p: u32 = @intCast(self.points.items.len);
        const t = self.tris.items[ti];
        self.stack.clearRetainingCapacity();
        if (on_edge) |k| {
            const a = t[k];
            const b = t[(@as(usize, k) + 1) % 3];
            const c = t[(@as(usize, k) + 2) % 3];
            const ui = self.across(b, a) orelse return;
            const q = self.opposite(ui, b, a);
            try self.points.append(gpa, point);
            self.tris.items[ti] = .{ b, c, p };
            self.tris.items[ui] = .{ c, a, p };
            try self.tris.append(gpa, .{ a, q, p });
            try self.tris.append(gpa, .{ q, b, p });
            try self.stack.appendSlice(gpa, &.{ .{ b, c }, .{ c, a }, .{ a, q }, .{ q, b } });
        } else {
            try self.points.append(gpa, point);
            self.tris.items[ti] = .{ t[0], t[1], p };
            try self.tris.append(gpa, .{ t[1], t[2], p });
            try self.tris.append(gpa, .{ t[2], t[0], p });
            try self.stack.appendSlice(gpa, &.{ .{ t[0], t[1] }, .{ t[1], t[2] }, .{ t[2], t[0] } });
        }
        // Lawson: each edge opposite the new point is flipped if the far vertex lies in the
        // circle; a hull edge has no far side and is never flipped.
        var budget: usize = 64 * self.tris.items.len + 64;
        while (self.stack.pop()) |e| {
            if (budget == 0) break;
            budget -= 1;
            const a = e[0];
            const b = e[1];
            const ti2 = self.withEdge(a, b, p) orelse continue;
            const ui = self.across(b, a) orelse continue;
            const q = self.opposite(ui, b, a);
            const P = self.points.items;
            if (!inCircle(P[a], P[b], P[p], P[q])) continue;
            self.tris.items[ti2] = .{ a, q, p };
            self.tris.items[ui] = .{ q, b, p };
            try self.stack.appendSlice(gpa, &.{ .{ a, q }, .{ q, b } });
        }
    }

    /// The triangle with directed edge `a → b`, if any.
    fn across(self: *const Work, a: u32, b: u32) ?usize {
        for (self.tris.items, 0..) |t, i| {
            for (0..3) |k| if (t[k] == a and t[(k + 1) % 3] == b) return i;
        }
        return null;
    }

    /// The triangle `a → b → p`.
    fn withEdge(self: *const Work, a: u32, b: u32, p: u32) ?usize {
        for (self.tris.items, 0..) |t, i| {
            for (0..3) |k| if (t[k] == a and t[(k + 1) % 3] == b and t[(k + 2) % 3] == p) return i;
        }
        return null;
    }

    fn opposite(self: *const Work, ti: usize, a: u32, b: u32) u32 {
        const t = self.tris.items[ti];
        for (t) |v| if (v != a and v != b) return v;
        unreachable; // a triangle has three distinct corners
    }

    /// The surface's height at `(x, z)`, from the triangle it falls most inside.
    fn heightAt(self: *const Work, x: f32, z: f32) ?f32 {
        return surfaceHeight(self.points.items, self.tris.items, x, z);
    }
};

/// The height of the triangulated surface at `(x, z)`: the triangle whose smallest barycentric
/// weight is largest, its weights clamped, so a point on or just outside the boundary still
/// reads the nearest triangle.
pub fn surfaceHeight(points: []const Vec3, tris: []const [3]u32, x: f32, z: f32) ?f32 {
    var best: ?f32 = null;
    var best_min: f32 = -std.math.inf(f32);
    const p: Vec3 = .init(x, 0, z);
    for (tris) |t| {
        const a = points[t[0]];
        const b = points[t[1]];
        const c = points[t[2]];
        const area = turnf(a, b, c);
        if (area <= 0) continue;
        var wa = turnf(b, c, p) / area;
        var wb = turnf(c, a, p) / area;
        var wc = turnf(a, b, p) / area;
        const m = @min(wa, wb, wc);
        if (m <= best_min) continue;
        best_min = m;
        wa = @max(wa, 0);
        wb = @max(wb, 0);
        wc = @max(wc, 0);
        const sum = wa + wb + wc;
        best = (wa * a.y + wb * b.y + wc * c.y) / sum;
    }
    return best;
}

/// The floor nearest in height to `near.y` in the column under `near`, or the nearest ring of
/// columns that has one, up to two out. With `region` nonzero, that region's floors are
/// preferred in each ring; with zero, any walkable floor counts, which is what makes a shared
/// edge read the same from both of its polygons.
fn sampleHeight(field: *const OpenField, near: Vec3, region: u16) ?f32 {
    const g = field.grid;
    const cx: i64 = @intFromFloat(@floor((near.x - g.origin.x) / g.cell_size));
    const cz: i64 = @intFromFloat(@floor((near.z - g.origin.z) / g.cell_size));
    const want = (near.y - g.origin.y) / g.cell_height;
    var ring: i64 = 0;
    while (ring <= 2) : (ring += 1) {
        var best: ?f32 = null;
        var best_d: f32 = std.math.inf(f32);
        var best_preferred = false;
        var dz: i64 = -ring;
        while (dz <= ring) : (dz += 1) {
            var dx: i64 = -ring;
            while (dx <= ring) : (dx += 1) {
                if (@max(@abs(dx), @abs(dz)) != ring) continue;
                const x = cx + dx;
                const z = cz + dz;
                if (x < 0 or z < 0 or x >= g.width or z >= g.depth) continue;
                const c = field.column(@intCast(x), @intCast(z));
                for (field.spans[c.first..][0..c.count]) |s| {
                    if (s.region == 0) continue;
                    const preferred = region == 0 or s.region == region;
                    const d = @abs(@as(f32, @floatFromInt(s.y)) - want);
                    if ((preferred and !best_preferred) or (preferred == best_preferred and d < best_d)) {
                        best = @floatFromInt(s.y);
                        best_d = d;
                        best_preferred = preferred;
                    }
                }
            }
        }
        if (best) |y| return g.origin.y + y * g.cell_height;
    }
    return null;
}

/// How far `(x, z)` is inside a convex counter-clockwise loop: the least distance to an edge,
/// negative outside.
fn insideBy(loop: []const Vec3, x: f32, z: f32) f32 {
    var least = std.math.inf(f32);
    for (loop, 0..) |a, i| {
        const b = loop[(i + 1) % loop.len];
        const ex = b.x - a.x;
        const ez = b.z - a.z;
        const len = @sqrt(ex * ex + ez * ez);
        if (len == 0) continue;
        // Left of a → b is inside.
        const side = (ez * (x - a.x) - ex * (z - a.z)) / len;
        least = @min(least, side);
    }
    return least;
}

/// `> 0` when `c` is left of `a → b` seen from +Y, as `contour.turn`.
pub fn turnf(a: Vec3, b: Vec3, c: Vec3) f32 {
    return (b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z);
}

/// Whether `d` is strictly inside the circle through counter-clockwise `a b c`. Mapped to
/// `(x, −z)`, where counter-clockwise from +Y is the textbook orientation.
fn inCircle(a: Vec3, b: Vec3, c: Vec3, d: Vec3) bool {
    const ax: f64 = a.x - d.x;
    const ay: f64 = -(a.z - d.z);
    const bx: f64 = b.x - d.x;
    const by: f64 = -(b.z - d.z);
    const cx: f64 = c.x - d.x;
    const cy: f64 = -(c.z - d.z);
    const det = (ax * ax + ay * ay) * (bx * cy - cx * by) -
        (bx * bx + by * by) * (ax * cy - cx * ay) +
        (cx * cx + cy * cy) * (ax * by - bx * ay);
    return det > 1e-12;
}

fn distanceToSegment(p: Vec3, a: Vec3, b: Vec3) f32 {
    const d = b.sub(a);
    const len2 = d.lengthSquared();
    const t = if (len2 > 0) std.math.clamp(p.sub(a).dot(d) / len2, 0, 1) else 0;
    return p.sub(a.add(d.scale(t))).length();
}
