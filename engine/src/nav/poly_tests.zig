//! Criterion 2 on every mesh the suite builds, and each scene's area and islands against its
//! exact answer (`navigation.md` §11).

const std = @import("std");

const config_mod = @import("config.zig");
const contour = @import("contour.zig");
const poly = @import("poly.zig");
const scenes = @import("scenes.zig");

const testing = std.testing;
const Mesh = poly.Mesh;
const Vertex = contour.Vertex;
const walker = config_mod.walker;

fn at(m: *const Mesh, v: u32) Vertex {
    const c = m.vertices[v];
    return .{ .x = c[0], .y = c[1], .z = c[2] };
}

/// Criterion 2: every polygon convex, counter-clockwise from +Y and within its vertex count;
/// links symmetric and sharing both vertices of their edge; no vertex in the middle of a
/// boundary edge, which is how a T-junction between two regions would show.
pub fn expectWellFormed(m: *const Mesh, nvp: u32) !void {
    try testing.expectEqual(@as(u32, 0), m.skipped);
    for (m.polygons, 0..) |*p, pi| {
        try testing.expect(p.count >= 3 and p.count <= nvp);
        for (p.slice(), 0..) |v, i| {
            try testing.expect(v < m.vertices.len);
            for (p.slice()[i + 1 ..]) |w| try testing.expect(v != w);
        }
        try testing.expect(poly.polygonArea2(m, p) > 0);
        for (0..p.count) |i| {
            const a = at(m, p.vertices[(i + p.count - 1) % p.count]);
            const b = at(m, p.vertices[i]);
            const c = at(m, p.vertices[(i + 1) % p.count]);
            try testing.expect(contour.turn(a, b, c) >= 0);
        }
        for (0..p.count) |e| {
            const v0 = p.vertices[e];
            const v1 = p.vertices[(e + 1) % p.count];
            const q = p.neighbours[e];
            if (q == poly.none_polygon) {
                // A boundary edge has no vertex strictly inside it.
                for (0..m.vertices.len) |w| {
                    if (w == v0 or w == v1) continue;
                    const pw = at(m, @intCast(w));
                    if (@abs(pw.y - at(m, v0).y) > 8) continue;
                    if (contour.turn(at(m, v0), at(m, v1), pw) != 0) continue;
                    const lo_x = @min(at(m, v0).x, at(m, v1).x);
                    const hi_x = @max(at(m, v0).x, at(m, v1).x);
                    const lo_z = @min(at(m, v0).z, at(m, v1).z);
                    const hi_z = @max(at(m, v0).z, at(m, v1).z);
                    const inside = pw.x >= lo_x and pw.x <= hi_x and pw.z >= lo_z and pw.z <= hi_z and !pw.sameXz(at(m, v0)) and !pw.sameXz(at(m, v1));
                    try testing.expect(!inside);
                }
                continue;
            }
            const other = &m.polygons[q];
            var back = false;
            for (0..other.count) |f| {
                if (other.vertices[f] == v1 and other.vertices[(f + 1) % other.count] == v0) {
                    try testing.expectEqual(@as(u32, @intCast(pi)), other.neighbours[f]);
                    back = true;
                }
            }
            try testing.expect(back);
        }
    }
}

/// Connected sets of polygons, by their links.
pub fn islands(m: *const Mesh) !u32 {
    const gpa = testing.allocator;
    const seen = try gpa.alloc(bool, m.polygons.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var count: u32 = 0;
    for (0..m.polygons.len) |start| {
        if (seen[start]) continue;
        count += 1;
        seen[start] = true;
        try stack.append(gpa, @intCast(start));
        while (stack.pop()) |p| for (m.polygons[p].neighbours[0..m.polygons[p].count]) |q| {
            if (q == poly.none_polygon or seen[q]) continue;
            seen[q] = true;
            try stack.append(gpa, q);
        };
    }
    return count;
}

fn build(scene: *scenes.Scene, c: config_mod.Config) !Mesh {
    return poly.buildPolygons(testing.allocator, c, scene.sources());
}

/// Area within one cell's width around a perimeter of `perimeter` metres.
fn expectArea(m: *const Mesh, expected: f64, perimeter: f64) !void {
    const tolerance = perimeter * m.cell_size;
    try testing.expect(@abs(m.area() - expected) <= tolerance);
}

test "an open floor is one convex island of its eroded area" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var triangles: usize = 0;
    for ([_]u32{ 3, 4, 6 }) |nvp| {
        var c = walker;
        c.polygon_max_vertices = nvp;
        var m = try build(&scene, c);
        defer m.deinit(testing.allocator);
        try expectWellFormed(&m, nvp);
        try testing.expectEqual(@as(u32, 1), try islands(&m));
        // The ledge's cell and the radius's 3 at each edge: 9.2 m square.
        try expectArea(&m, 9.2 * 9.2, 4 * 9.2);
        if (nvp == 3) {
            for (m.polygons) |p| try testing.expectEqual(@as(u8, 3), p.count);
            triangles = m.polygons.len;
        } else {
            // Quads or hexagons take fewer polygons than triangles do. Not one: its 9.2 m walls
            // are split at the 6 m edge limit, and a split vertex is in line with its edge.
            try testing.expect(m.polygons.len < triangles);
        }
    }
}

test "a pillar's hole is bridged into its floor's outline" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    scene.box(.init(4.55, 0, 4.55), .init(5.55, 3, 5.55));
    var m = try build(&scene, walker);
    defer m.deinit(testing.allocator);
    try expectWellFormed(&m, 6);
    try testing.expectEqual(@as(u32, 1), try islands(&m));
    // The floor less the pillar's 11 columns and the radius around them: 1.7 m square.
    try expectArea(&m, 9.2 * 9.2 - 1.7 * 1.7, 4 * 9.2 + 4 * 1.7);
    // Nothing covers the pillar's middle.
    for (m.polygons) |*p| {
        var inside = true;
        const cx: i32 = @intFromFloat(@round((5.05 - m.origin.x) / m.cell_size));
        const cz: i32 = @intFromFloat(@round((5.05 - m.origin.z) / m.cell_size));
        const centre: Vertex = .{ .x = cx, .y = 0, .z = cz };
        for (0..p.count) |i| {
            if (contour.turn(at(&m, p.vertices[i]), at(&m, p.vertices[(i + 1) % p.count]), centre) < 0) inside = false;
        }
        try testing.expect(!inside);
    }
}

test "a floor and a platform it cannot reach are two islands, and a step joins them" {
    for ([_]struct { height: f32, islands: u32 }{ .{ .height = 1, .islands = 2 }, .{ .height = 0.15, .islands = 1 } }) |case| {
        var scene: scenes.Scene = .{};
        scene.floor(.init(0, 0, 0), .init(8, 0, 8), false);
        scene.box(.init(2.05, 0, 2.05), .init(5.05, case.height, 5.05));
        var m = try build(&scene, walker);
        defer m.deinit(testing.allocator);
        try expectWellFormed(&m, 6);
        try testing.expectEqual(case.islands, try islands(&m));
    }
}

test "an L of corridors, cut into regions, is one island with matching borders" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 2), false);
    scene.floor(.init(0, 0, 2), .init(2, 0, 12), false);
    var c = walker;
    c.region_merge_area = 0;
    var m = try build(&scene, c);
    defer m.deinit(testing.allocator);
    try expectWellFormed(&m, 6);
    try testing.expectEqual(@as(u32, 1), try islands(&m));
    // Three regions, the corner and the two arms, so polygons of several regions meet along
    // their borders.
    var regions: [8]bool = @splat(false);
    for (m.polygons) |p| regions[p.region] = true;
    var distinct: u32 = 0;
    for (regions) |r| distinct += @intFromBool(r);
    try testing.expectEqual(@as(u32, 3), distinct);
    // Each corridor is 12 m by 2 m, less the ledge and radius: 1.2 m wide, 11.2 m long from the
    // shared corner's outer edge, and the corner counted once.
    try expectArea(&m, 11.2 * 1.2 + 10.0 * 1.2, 2 * (11.2 + 11.2) + 2 * 1.2);
}

test "two floors one above the other are two islands that overlap seen from above" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(6, 0, 6), false);
    scene.box(.init(1.05, 2.5, 1.05), .init(5.05, 2.7, 5.05));
    var m = try build(&scene, walker);
    defer m.deinit(testing.allocator);
    try expectWellFormed(&m, 6);
    try testing.expectEqual(@as(u32, 2), try islands(&m));
}

test "a long wall is split, and every split edge stays within the limit" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(20, 0, 2), false);
    var c = walker;
    c.edge_max_length = 3;
    c.region_merge_area = 1000;
    var m = try build(&scene, c);
    defer m.deinit(testing.allocator);
    try expectWellFormed(&m, 6);
    for (m.polygons) |*p| for (0..p.count) |e| {
        if (p.neighbours[e] != poly.none_polygon) continue;
        const a = m.position(p.vertices[e]);
        const b = m.position(p.vertices[(e + 1) % p.count]);
        try testing.expect(a.sub(b).length() <= 3 + 1e-4);
    };
}

test "every allocation failure in polygonising is reported, and nothing leaks" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(2, 0, 2), false);
    scene.box(.init(0.85, 0, 0.85), .init(1.15, 2, 1.15));
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, s: *scenes.Scene) !void {
            var m = try poly.buildPolygons(gpa, walker, s.sources());
            m.deinit(gpa);
        }
    }.run, .{&scene});
}

test "a floor turned by its pose keeps its eroded area, within the staircase's error" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(-4, 0, -4), .init(4, 0, 4), false);
    var turned = scene.sources()[0];
    turned.pose = .{ .position = .init(10, 0, 10), .rotation = @import("core").math.Quat.fromAxisAngle(.init(0, 1, 0), std.math.pi / 6.0) };
    var m = try poly.buildPolygons(testing.allocator, walker, &.{turned});
    defer m.deinit(testing.allocator);
    try expectWellFormed(&m, 6);
    try testing.expectEqual(@as(u32, 1), try islands(&m));
    // 8 m less about 0.4 m at each edge, the ledge's cell and the radius. A diagonal edge's
    // cells and its 1.3-cell simplification each cost up to a cell along the perimeter.
    try expectArea(&m, 7.2 * 7.2, 2 * 4 * 7.2);
}

test "a slope cut into many regions welds its shared corners and stays one island" {
    var scene: scenes.Scene = .{};
    // A T: a wide floor, and a 40° ramp rising from the middle of its long side.
    scene.floor(.init(0, 0, -4), .init(8, 0, 0), false);
    scene.ramp(.init(2.5, 0, 0), 3, 6, 40);
    var c = walker;
    c.region_merge_area = 0;
    c.region_min_area = 0;
    var m = try build(&scene, c);
    defer m.deinit(testing.allocator);
    try expectWellFormed(&m, 6);
    try testing.expectEqual(@as(u32, 1), try islands(&m));
    var regions: [64]bool = @splat(false);
    for (m.polygons) |p| regions[p.region] = true;
    var distinct: u32 = 0;
    for (regions) |r| distinct += @intFromBool(r);
    try testing.expect(distinct >= 2);
}

test "a hole's bridge never crosses another hole, and the triangles cover exactly the loop" {
    const gpa = testing.allocator;
    // By hand, in cells: a 40-cell outline with only its corners, and two holes whose shortest
    // bridges lead to the corner beyond the other hole.
    var outline = [_]Vertex{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 40 }, .{ .x = 40, .y = 0, .z = 40 }, .{ .x = 40, .y = 0, .z = 0 } };
    var first = [_]Vertex{ .{ .x = 30, .y = 0, .z = 30 }, .{ .x = 32, .y = 0, .z = 30 }, .{ .x = 32, .y = 0, .z = 32 }, .{ .x = 30, .y = 0, .z = 32 } };
    var second = [_]Vertex{ .{ .x = 34, .y = 0, .z = 34 }, .{ .x = 36, .y = 0, .z = 34 }, .{ .x = 36, .y = 0, .z = 36 }, .{ .x = 34, .y = 0, .z = 36 } };
    const loops = [_]contour.Contour{
        .{ .region = 1, .vertices = &outline },
        .{ .region = 1, .vertices = &first },
        .{ .region = 1, .vertices = &second },
    };
    try testing.expect(contour.area2(&outline) > 0 and contour.area2(&first) < 0 and contour.area2(&second) < 0);
    var out: std.ArrayList(contour.Contour) = .empty;
    defer {
        for (out.items) |o| gpa.free(o.vertices);
        out.deinit(gpa);
    }
    try testing.expect(try contour.joinRegion(gpa, &loops, 1, &out));
    const joined = out.items[0].vertices;
    // The loop is simple: no two edges cross unless they meet at a bridge's repeated corner.
    for (joined, 0..) |a, i| {
        const b = joined[(i + 1) % joined.len];
        for (joined, 0..) |c, j| {
            if (j == i or (j + 1) % joined.len == i or (i + 1) % joined.len == j) continue;
            const d = joined[(j + 1) % joined.len];
            if (a.sameXz(c) or a.sameXz(d) or b.sameXz(c) or b.sameXz(d)) continue;
            try testing.expect(!contour.intersects(a, b, c, d));
        }
    }
    // Each bridge brings the hole's loop closed on itself and its outline vertex again.
    try testing.expectEqual(@as(usize, 4 + 6 + 6), joined.len);
    var tris: std.ArrayList([3]u32) = .empty;
    defer tris.deinit(gpa);
    try testing.expect(try poly.triangulate(gpa, joined, &tris));
    var covered: i64 = 0;
    for (tris.items) |t| {
        const a2 = contour.turn(joined[t[0]], joined[t[1]], joined[t[2]]);
        // Every triangle counter-clockwise; none folded over.
        try testing.expect(a2 >= 0);
        covered += a2;
    }
    try testing.expectEqual(contour.area2(&outline) + contour.area2(&first) + contour.area2(&second), covered);
    // No triangle covers either hole's middle.
    for ([_]Vertex{ .{ .x = 31, .y = 0, .z = 31 }, .{ .x = 35, .y = 0, .z = 35 } }) |inside| for (tris.items) |t| {
        const a = joined[t[0]];
        const b = joined[t[1]];
        const c = joined[t[2]];
        const covers = contour.turn(a, b, inside) > 0 and contour.turn(b, c, inside) > 0 and contour.turn(c, a, inside) > 0;
        try testing.expect(!covers);
    };
}

/// Joins and triangulates one outline with its holes, and checks the loop is simple, no
/// triangle covers a hole's middle, every triangle is counter-clockwise, and they cover the
/// outline less the holes exactly.
fn expectBridgedAndCovered(outline: []const Vertex, holes: []const []const Vertex) !void {
    const gpa = testing.allocator;
    var loops: std.ArrayList(contour.Contour) = .empty;
    defer loops.deinit(gpa);
    try loops.append(gpa, .{ .region = 1, .vertices = @constCast(outline) });
    for (holes) |h| try loops.append(gpa, .{ .region = 1, .vertices = @constCast(h) });
    var out: std.ArrayList(contour.Contour) = .empty;
    defer {
        for (out.items) |o| gpa.free(o.vertices);
        out.deinit(gpa);
    }
    try testing.expect(try contour.joinRegion(gpa, loops.items, 1, &out));
    const joined = out.items[0].vertices;
    for (joined, 0..) |a, i| {
        const b = joined[(i + 1) % joined.len];
        for (joined, 0..) |c, j| {
            if (j == i or (j + 1) % joined.len == i or (i + 1) % joined.len == j) continue;
            const d = joined[(j + 1) % joined.len];
            if (a.sameXz(c) or a.sameXz(d) or b.sameXz(c) or b.sameXz(d)) continue;
            try testing.expect(!contour.intersects(a, b, c, d));
        }
    }
    var tris: std.ArrayList([3]u32) = .empty;
    defer tris.deinit(gpa);
    try testing.expect(try poly.triangulate(gpa, joined, &tris));
    var covered: i64 = 0;
    var expected: i64 = contour.area2(outline);
    for (holes) |h| expected += contour.area2(h);
    for (tris.items) |t| {
        const a2 = contour.turn(joined[t[0]], joined[t[1]], joined[t[2]]);
        try testing.expect(a2 >= 0);
        covered += a2;
    }
    try testing.expectEqual(expected, covered);
    for (holes) |h| {
        // Twice-scaled middle, so it lies strictly inside even a 1-cell hole.
        var mx: i32 = 0;
        var mz: i32 = 0;
        for (h) |v| {
            mx += v.x;
            mz += v.z;
        }
        const n: i32 = @intCast(h.len);
        for (tris.items) |t| {
            const s = struct {
                fn doubled(v: Vertex, by: i32) Vertex {
                    return .{ .x = v.x * by, .y = 0, .z = v.z * by };
                }
            };
            const a = s.doubled(joined[t[0]], n);
            const b = s.doubled(joined[t[1]], n);
            const c = s.doubled(joined[t[2]], n);
            const m: Vertex = .{ .x = mx, .y = 0, .z = mz };
            try testing.expect(!(contour.turn(a, b, m) > 0 and contour.turn(b, c, m) > 0 and contour.turn(c, a, m) > 0));
        }
    }
}

test "random holes are bridged and covered correctly" {
    var rng = @import("core").rng.Pcg32.init(32, 5);
    const outline = [_]Vertex{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 100 }, .{ .x = 100, .y = 0, .z = 100 }, .{ .x = 100, .y = 0, .z = 0 } };
    var storage: [6][4]Vertex = undefined;
    var holes: [6][]const Vertex = undefined;
    for (0..2000) |_| {
        var count: usize = 0;
        var attempts: u32 = 0;
        while (count < 6 and attempts < 40) : (attempts += 1) {
            const x: i32 = @intCast(4 + rng.below(88));
            const z: i32 = @intCast(4 + rng.below(88));
            const w: i32 = @intCast(1 + rng.below(6));
            const d: i32 = @intCast(1 + rng.below(6));
            var clear = true;
            for (storage[0..count]) |h| {
                if (x <= h[1].x + 2 and x + w + 2 >= h[0].x and z <= h[2].z + 2 and z + d + 2 >= h[0].z) clear = false;
            }
            if (!clear) continue;
            // Clockwise seen from +Y: a hole.
            storage[count] = .{ .{ .x = x, .y = 0, .z = z }, .{ .x = x + w, .y = 0, .z = z }, .{ .x = x + w, .y = 0, .z = z + d }, .{ .x = x, .y = 0, .z = z + d } };
            holes[count] = &storage[count];
            count += 1;
        }
        try expectBridgedAndCovered(&outline, holes[0..count]);
    }
}
