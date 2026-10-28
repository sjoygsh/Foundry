//! Polygons: each region's contour ear-clipped, its vertices welded across regions, its
//! triangles merged into convex polygons, and every polygon edge linked to the polygon across
//! it (`navigation.md` §5.6, §6).
//!
//! **Integers to the end.** Vertices are grid corners, so convexity, shared edges and welding
//! are exact comparisons, and the same contours give the same mesh.

const std = @import("std");
const core = @import("core");

const contour = @import("contour.zig");
const config_mod = @import("config.zig");
const heightfield = @import("heightfield.zig");
const input = @import("input.zig");
const open_mod = @import("open.zig");
const regions = @import("regions.zig");
const detail_mod = @import("detail.zig");
const locate_mod = @import("locate.zig");

const Allocator = std.mem.Allocator;
const Vertex = contour.Vertex;
const Vec3 = core.math.Vec3;
const turn = contour.turn;

pub const max_polygon_vertices = config_mod.max_polygon_vertices;
/// No polygon, on a boundary edge or in an unused slot.
pub const none_polygon: u32 = std.math.maxInt(u32);
/// An unused vertex slot.
pub const none_vertex: u32 = std.math.maxInt(u32);

pub const Polygon = struct {
    vertices: [max_polygon_vertices]u32 = @splat(none_vertex),
    /// Across edge `i`, from `vertices[i]` to `vertices[i + 1]`: a polygon, or `none_polygon`.
    neighbours: [max_polygon_vertices]u32 = @splat(none_polygon),
    count: u8,
    region: u16,

    pub fn slice(self: *const Polygon) []const u32 {
        return self.vertices[0..self.count];
    }
};

/// A navigation mesh (§6): polygons over grid corners, linked, and each one's detail surface.
pub const Mesh = struct {
    origin: Vec3,
    cell_size: f32,
    cell_height: f32,
    /// Grid corners: x and z in columns, y in cells above `origin`.
    vertices: [][3]u16,
    polygons: []Polygon,
    /// Regions left out because their outline could not be made one loop or triangulated.
    skipped: u32 = 0,
    /// Empty from `buildPolygons`; `build` fills it.
    detail: detail_mod.Detail = .{},

    pub fn deinit(self: *Mesh, gpa: Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.polygons);
        self.detail.deinit(gpa);
        self.* = undefined;
    }

    pub const locate = locate_mod.locate;

    /// A vertex in the world.
    pub fn position(self: *const Mesh, v: u32) Vec3 {
        const c = self.vertices[v];
        return .init(
            self.origin.x + @as(f32, @floatFromInt(c[0])) * self.cell_size,
            self.origin.y + @as(f32, @floatFromInt(c[1])) * self.cell_height,
            self.origin.z + @as(f32, @floatFromInt(c[2])) * self.cell_size,
        );
    }

    /// The area of every polygon seen from +Y, square metres.
    pub fn area(self: *const Mesh) f64 {
        var cells2: i64 = 0;
        for (self.polygons) |*p| cells2 += polygonArea2(self, p);
        const cs: f64 = self.cell_size;
        return @as(f64, @floatFromInt(cells2)) * cs * cs / 2;
    }
};

fn corner(m: *const Mesh, v: u32) Vertex {
    const c = m.vertices[v];
    return .{ .x = c[0], .y = c[1], .z = c[2] };
}

pub fn polygonArea2(m: *const Mesh, p: *const Polygon) i64 {
    var loop: [max_polygon_vertices]Vertex = undefined;
    for (p.slice(), 0..) |v, i| loop[i] = corner(m, v);
    return contour.area2(loop[0..p.count]);
}

pub const BuildError = input.InputError || heightfield.Error || regions.Error;

/// The whole build: validate and measure, rasterise and filter, link and erode, partition,
/// trace, polygonise and add detail (§5), always in this order.
pub fn build(gpa: Allocator, config: config_mod.Config, sources: []const input.Source) BuildError!Mesh {
    return run(gpa, config, sources, true);
}

/// `build` without the detail surface, for the tests of the stages before it.
pub fn buildPolygons(gpa: Allocator, config: config_mod.Config, sources: []const input.Source) BuildError!Mesh {
    return run(gpa, config, sources, false);
}

fn run(gpa: Allocator, config: config_mod.Config, sources: []const input.Source, with_detail: bool) BuildError!Mesh {
    var hf = try heightfield.solid(gpa, config, sources);
    defer hf.deinit(gpa);
    var field = try open_mod.OpenField.init(gpa, &hf);
    defer field.deinit(gpa);
    try field.erode(gpa);
    const count = try regions.build(gpa, &field, .of(config.region_min_area, config.region_merge_area, config.cell_size));
    var loops = try contour.build(gpa, &field, count, .of(config.edge_max_error, config.edge_max_length, config.cell_size));
    defer loops.deinit(gpa);
    var mesh = try polygonize(gpa, &loops, config.polygon_max_vertices, hf.grid);
    errdefer mesh.deinit(gpa);
    mesh.skipped += loops.skipped;
    if (with_detail) mesh.detail = try detail_mod.build(gpa, &mesh, &field, .of(config));
    return mesh;
}

/// Polygons from contours, at most `nvp` vertices each.
pub fn polygonize(gpa: Allocator, loops: *const contour.Contours, nvp: u32, grid: input.Grid) Allocator.Error!Mesh {
    var welder: Welder = .{};
    defer welder.deinit(gpa);
    var polygons: std.ArrayList(Polygon) = .empty;
    errdefer polygons.deinit(gpa);
    var tris: std.ArrayList([3]u32) = .empty;
    defer tris.deinit(gpa);
    var local: std.ArrayList(Polygon) = .empty;
    defer local.deinit(gpa);
    var welded: std.ArrayList(u32) = .empty;
    defer welded.deinit(gpa);
    var skipped: u32 = 0;

    for (loops.items) |c| {
        tris.clearRetainingCapacity();
        if (!try triangulate(gpa, c.vertices, &tris)) {
            skipped += 1;
            continue;
        }
        welded.clearRetainingCapacity();
        for (c.vertices) |v| try welded.append(gpa, try welder.add(gpa, v));
        local.clearRetainingCapacity();
        for (tris.items) |t| {
            const a = welded.items[t[0]];
            const b = welded.items[t[1]];
            const d = welded.items[t[2]];
            // A bridge's two ends weld to one vertex, and an ear may be three vertices in line;
            // a triangle with no area is no polygon.
            if (a == b or b == d or a == d) continue;
            if (turn(welder.at(a), welder.at(b), welder.at(d)) <= 0) continue;
            var p: Polygon = .{ .count = 3, .region = c.region };
            p.vertices[0..3].* = .{ a, b, d };
            try local.append(gpa, p);
        }
        if (nvp > 3) mergeAll(&welder, &local, nvp);
        try polygons.appendSlice(gpa, local.items);
    }

    const vertices = try welder.vertices.toOwnedSlice(gpa);
    errdefer gpa.free(vertices);
    var mesh: Mesh = .{
        .origin = grid.origin,
        .cell_size = grid.cell_size,
        .cell_height = grid.cell_height,
        .vertices = vertices,
        .polygons = try polygons.toOwnedSlice(gpa),
        .skipped = skipped,
    };
    errdefer gpa.free(mesh.polygons);
    try linkNeighbours(gpa, &mesh);
    return mesh;
}

// -- welding -------------------------------------------------------------------------

/// Vertices shared across regions by their corner, and by height within two cells: Recast's
/// tolerance, since two regions can measure a shared corner from different spans.
const Welder = struct {
    vertices: std.ArrayList([3]u16) = .empty,
    /// The first vertex at each corner, then a chain through `next`.
    first: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    next: std.ArrayList(u32) = .empty,

    fn deinit(self: *Welder, gpa: Allocator) void {
        self.vertices.deinit(gpa);
        self.first.deinit(gpa);
        self.next.deinit(gpa);
    }

    fn add(self: *Welder, gpa: Allocator, v: Vertex) Allocator.Error!u32 {
        const key: u32 = @as(u32, @intCast(v.x)) | @as(u32, @intCast(v.z)) << 16;
        const entry = try self.first.getOrPut(gpa, key);
        if (entry.found_existing) {
            var i = entry.value_ptr.*;
            while (true) {
                if (@abs(@as(i32, self.vertices.items[i][1]) - v.y) <= 2) return i;
                if (self.next.items[i] == none_vertex) break;
                i = self.next.items[i];
            }
            const index: u32 = @intCast(self.vertices.items.len);
            try self.vertices.append(gpa, .{ @intCast(v.x), @intCast(v.y), @intCast(v.z) });
            try self.next.append(gpa, none_vertex);
            self.next.items[i] = index;
            return index;
        }
        const index: u32 = @intCast(self.vertices.items.len);
        entry.value_ptr.* = index;
        try self.vertices.append(gpa, .{ @intCast(v.x), @intCast(v.y), @intCast(v.z) });
        try self.next.append(gpa, none_vertex);
        return index;
    }

    fn at(self: *const Welder, i: u32) Vertex {
        const c = self.vertices.items[i];
        return .{ .x = c[0], .y = c[1], .z = c[2] };
    }
};

// -- ear clipping --------------------------------------------------------------------

/// Triangles of a counter-clockwise loop, as indices into it: at each step the ear with the
/// shortest new diagonal, the lowest index among equals. Falls back to loose tests when a
/// strict ear cannot be found; false if neither can.
pub fn triangulate(gpa: Allocator, loop: []const Vertex, out: *std.ArrayList([3]u32)) Allocator.Error!bool {
    var idx: std.ArrayList(u32) = .empty;
    defer idx.deinit(gpa);
    var ear: std.ArrayList(bool) = .empty;
    defer ear.deinit(gpa);
    for (0..loop.len) |i| {
        try idx.append(gpa, @intCast(i));
        try ear.append(gpa, false);
    }
    var n = loop.len;
    if (n < 3) return false;
    for (0..n) |i| ear.items[(i + 1) % n] = diagonal(loop, idx.items, i, (i + 2) % n, .strict);

    while (n > 3) {
        var best: ?usize = null;
        var best_len: i64 = 0;
        for ([_]Strictness{ .strict, .loose }) |mode| {
            for (0..n) |i| {
                const tip = (i + 1) % n;
                const ok = if (mode == .strict) ear.items[tip] else diagonal(loop, idx.items, i, (i + 2) % n, .loose);
                if (!ok) continue;
                const a = loop[idx.items[i]];
                const c = loop[idx.items[(i + 2) % n]];
                const dx: i64 = c.x - a.x;
                const dz: i64 = c.z - a.z;
                const len = dx * dx + dz * dz;
                if (best == null or len < best_len) {
                    best = i;
                    best_len = len;
                }
            }
            if (best != null) break;
        }
        const chosen = best orelse return false;
        var tip = (chosen + 1) % n;
        try out.append(gpa, .{ idx.items[chosen], idx.items[tip], idx.items[(chosen + 2) % n] });
        _ = idx.orderedRemove(tip);
        _ = ear.orderedRemove(tip);
        n -= 1;
        // The tip's old place now holds its successor; its predecessor is one before.
        if (tip >= n) tip = 0;
        const i = (tip + n - 1) % n;
        ear.items[i] = diagonal(loop, idx.items, (i + n - 1) % n, tip, .strict);
        ear.items[tip] = diagonal(loop, idx.items, i, (tip + 1) % n, .strict);
    }
    try out.append(gpa, .{ idx.items[0], idx.items[1], idx.items[2] });
    return true;
}

const Strictness = enum { strict, loose };

/// Whether `i`–`j` is a diagonal, so the vertex between them is an ear.
fn diagonal(loop: []const Vertex, idx: []const u32, i: usize, j: usize, mode: Strictness) bool {
    // In the cone at both ends, as O'Rourke's test has it: with a vertex repeated, which copy a
    // diagonal ends at decides which side of the bridge it lies on.
    return inCone(loop, idx, i, j, mode) and inCone(loop, idx, j, i, mode) and clear(loop, idx, i, j, mode);
}

fn inCone(loop: []const Vertex, idx: []const u32, i: usize, j: usize, mode: Strictness) bool {
    const n = idx.len;
    const a = loop[idx[i]];
    const b = loop[idx[j]];
    const next = loop[idx[(i + 1) % n]];
    const prev = loop[idx[(i + n - 1) % n]];
    if (mode == .loose) {
        if (turn(prev, a, next) >= 0) return turn(a, b, prev) >= 0 and turn(b, a, next) >= 0;
        return !(turn(a, b, next) >= 0 and turn(b, a, prev) >= 0);
    }
    if (turn(prev, a, next) >= 0) return turn(a, b, prev) > 0 and turn(b, a, next) > 0;
    return !(turn(a, b, next) >= 0 and turn(b, a, prev) >= 0);
}

/// No edge of the loop meets the diagonal, except edges at its ends or at a vertex in the same
/// place as an end, which a bridge makes.
fn clear(loop: []const Vertex, idx: []const u32, i: usize, j: usize, mode: Strictness) bool {
    const n = idx.len;
    const d0 = loop[idx[i]];
    const d1 = loop[idx[j]];
    for (0..n) |k| {
        const k1 = (k + 1) % n;
        if (k == i or k1 == i or k == j or k1 == j) continue;
        const p0 = loop[idx[k]];
        const p1 = loop[idx[k1]];
        if (d0.sameXz(p0) or d1.sameXz(p0) or d0.sameXz(p1) or d1.sameXz(p1)) continue;
        const hit = if (mode == .strict) contour.intersects(d0, d1, p0, p1) else properly(d0, d1, p0, p1);
        if (hit) return false;
    }
    return true;
}

fn properly(a: Vertex, b: Vertex, c: Vertex, d: Vertex) bool {
    const t1 = turn(a, b, c);
    const t2 = turn(a, b, d);
    const t3 = turn(c, d, a);
    const t4 = turn(c, d, b);
    if (t1 == 0 or t2 == 0 or t3 == 0 or t4 == 0) return false;
    return ((t1 > 0) != (t2 > 0)) and ((t3 > 0) != (t4 > 0));
}

// -- merging -------------------------------------------------------------------------

/// Merges pairs of polygons in one region while any pair shares an edge and would stay convex
/// within `nvp` vertices, always the pair whose shared edge is longest, the first found among
/// equals.
fn mergeAll(welder: *const Welder, polys: *std.ArrayList(Polygon), nvp: u32) void {
    while (true) {
        var best: i64 = 0;
        var pa: usize = 0;
        var pb: usize = 0;
        var ea: usize = 0;
        var eb: usize = 0;
        for (polys.items, 0..) |*a, i| for (polys.items[i + 1 ..], i + 1..) |*b, j| {
            const m = mergeValue(welder, a, b, nvp) orelse continue;
            if (m.value > best) {
                best = m.value;
                pa = i;
                pb = j;
                ea = m.ea;
                eb = m.eb;
            }
        };
        if (best == 0) return;
        const a = polys.items[pa];
        const b = polys.items[pb];
        var merged: Polygon = .{ .count = @intCast(a.count + b.count - 2), .region = a.region };
        var n: usize = 0;
        for (0..a.count - 1) |k| {
            merged.vertices[n] = a.vertices[(ea + 1 + k) % a.count];
            n += 1;
        }
        for (0..b.count - 1) |k| {
            merged.vertices[n] = b.vertices[(eb + 1 + k) % b.count];
            n += 1;
        }
        polys.items[pa] = merged;
        _ = polys.orderedRemove(pb);
    }
}

const Merge = struct { value: i64, ea: usize, eb: usize };

fn mergeValue(welder: *const Welder, a: *const Polygon, b: *const Polygon, nvp: u32) ?Merge {
    const na = a.count;
    const nb = b.count;
    if (na + nb - 2 > nvp) return null;
    var ea: ?usize = null;
    var eb: usize = 0;
    outer: for (0..na) |i| {
        const a0 = a.vertices[i];
        const a1 = a.vertices[(i + 1) % na];
        for (0..nb) |j| {
            if (b.vertices[j] == a1 and b.vertices[(j + 1) % nb] == a0) {
                ea = i;
                eb = j;
                break :outer;
            }
        }
    }
    const e = ea orelse return null;
    const at = struct {
        fn f(w: *const Welder, v: u32) Vertex {
            return w.at(v);
        }
    }.f;
    // Convex at both ends of the edge once it is gone.
    if (turn(at(welder, a.vertices[(e + na - 1) % na]), at(welder, a.vertices[e]), at(welder, b.vertices[(eb + 2) % nb])) <= 0) return null;
    if (turn(at(welder, b.vertices[(eb + nb - 1) % nb]), at(welder, b.vertices[eb]), at(welder, a.vertices[(e + 2) % na])) <= 0) return null;
    const p = at(welder, a.vertices[e]);
    const q = at(welder, a.vertices[(e + 1) % na]);
    const dx: i64 = q.x - p.x;
    const dz: i64 = q.z - p.z;
    return .{ .value = dx * dx + dz * dz, .ea = e, .eb = eb };
}

// -- adjacency -----------------------------------------------------------------------

/// Links each edge to the polygon that has it the other way round.
fn linkNeighbours(gpa: Allocator, mesh: *Mesh) Allocator.Error!void {
    var edges: std.AutoHashMapUnmanaged(u64, [2]u32) = .empty;
    defer edges.deinit(gpa);
    for (mesh.polygons, 0..) |*p, pi| for (0..p.count) |e| {
        const v0 = p.vertices[e];
        const v1 = p.vertices[(e + 1) % p.count];
        if (v0 < v1) {
            const entry = try edges.getOrPut(gpa, @as(u64, v0) << 32 | v1);
            if (!entry.found_existing) entry.value_ptr.* = .{ @intCast(pi), @intCast(e) };
        }
    };
    for (mesh.polygons, 0..) |*p, pi| for (0..p.count) |e| {
        const v0 = p.vertices[e];
        const v1 = p.vertices[(e + 1) % p.count];
        if (v0 <= v1) continue;
        const found = edges.get(@as(u64, v1) << 32 | v0) orelse continue;
        const other = &mesh.polygons[found[0]];
        if (other.neighbours[found[1]] != none_polygon) continue;
        other.neighbours[found[1]] = @intCast(pi);
        p.neighbours[e] = found[0];
    };
}
