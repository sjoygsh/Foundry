//! The whole build: detail, `locate`, the task, the view, the sweeps, the course's pin and the
//! timing (`navigation.md` §11, Step 5).

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const config_mod = @import("config.zig");
const detail_mod = @import("detail.zig");
const input = @import("input.zig");
const poly = @import("poly.zig");
const poly_tests = @import("poly_tests.zig");
const scenes = @import("scenes.zig");
const task = @import("task.zig");
const view = @import("view.zig");

const testing = std.testing;
const Mesh = poly.Mesh;
const Vec3 = core.math.Vec3;
const walker = config_mod.walker;

fn built(scene: *scenes.Scene, c: config_mod.Config) !Mesh {
    return poly.build(testing.allocator, c, scene.sources());
}

/// The height of the source surface under `(x, z)` nearest `near`, by a vertical ray through
/// every triangle: what the detail is measured against.
fn sourceHeight(sources: []const input.Source, x: f32, z: f32, near: f32) ?f32 {
    var best: ?f32 = null;
    for (sources) |s| {
        var t: usize = 0;
        while (t < s.indices.len) : (t += 3) {
            const a = s.positions[s.indices[t]];
            const b = s.positions[s.indices[t + 1]];
            const c = s.positions[s.indices[t + 2]];
            const area = detail_mod.turnf(a, b, c);
            if (@abs(area) < 1e-9) continue;
            const p: Vec3 = .init(x, 0, z);
            const wa = detail_mod.turnf(b, c, p) / area;
            const wb = detail_mod.turnf(c, a, p) / area;
            const wc = detail_mod.turnf(a, b, p) / area;
            if (wa < -1e-5 or wb < -1e-5 or wc < -1e-5) continue;
            const y = wa * a.y + wb * b.y + wc * c.y;
            if (best == null or @abs(y - near) < @abs(best.? - near)) best = y;
        }
    }
    return best;
}

// -- detail --------------------------------------------------------------------------

test "every detail triangle lies over its polygon, counter-clockwise, and covers it" {
    var scene: scenes.Scene = .{};
    scene.course();
    var m = try built(&scene, walker);
    defer m.deinit(testing.allocator);
    try poly_tests.expectWellFormed(&m, 6);
    try testing.expectEqual(m.polygons.len, m.detail.meshes.len);
    for (m.polygons, 0..) |*p, pi| {
        var loop: [6]Vec3 = undefined;
        for (p.slice(), 0..) |v, i| loop[i] = m.position(v);
        var polygon_area: f32 = 0;
        for (1..p.count - 1) |i| polygon_area += detail_mod.turnf(loop[0], loop[i], loop[i + 1]);
        var covered: f32 = 0;
        const sub = m.detail.meshes[pi];
        try testing.expect(sub.vertex_count >= p.count and sub.vertex_count <= detail_mod.max_polygon_vertices);
        // A polygon's own vertices lead its range, in its order.
        for (p.slice(), 0..) |v, i| try testing.expectEqual(m.position(v), m.detail.vertices[sub.vertex_base + i]);
        for (0..sub.triangle_count) |t| {
            const tri = m.detail.triangle(@intCast(pi), @intCast(t));
            const a = detail_mod.turnf(tri[0], tri[1], tri[2]);
            try testing.expect(a > 0);
            covered += a;
            for (tri) |v| {
                for (0..p.count) |i| try testing.expect(detail_mod.turnf(loop[i], loop[(i + 1) % p.count], v) >= -1e-4);
            }
        }
        try testing.expectApproxEqRel(polygon_area, covered, 1e-4);
    }
}

test "the detail follows the floor within its error and a cell" {
    var scene: scenes.Scene = .{};
    scene.course();
    var m = try built(&scene, walker);
    defer m.deinit(testing.allocator);
    const sources = scene.sources();
    // A vertex is a sample of a span's top: above the surface by at most a cell height, and by
    // what a 25° ramp rises across a cell.
    const slope_rise = walker.cell_size * @tan(25.0 * std.math.pi / 180.0);
    const bound = walker.detail_max_error + walker.cell_height + slope_rise + 1e-3;
    for (m.detail.vertices) |v| {
        const y = sourceHeight(sources, v.x, v.z, v.y) orelse continue;
        try testing.expect(v.y - y >= -1e-3 - walker.cell_height);
        try testing.expect(v.y - y <= bound);
    }
    // Between samples, on the floor and up the 25° ramp, away from any riser.
    var checked: u32 = 0;
    for ([_][2]f32{ .{ 4.5, 4.5 }, .{ 5, 1 }, .{ 1, 5.2 }, .{ 4.5, 0.8 }, .{ 2.7, 1.3 }, .{ 2.7, 1.0 } }) |at| {
        const located = m.locate(.init(at[0], 1, at[1]), .init(0.01, 2, 0.01)) orelse continue;
        const y = sourceHeight(sources, at[0], at[1], located.point.y) orelse continue;
        try testing.expect(@abs(located.point.y - y) <= bound);
        checked += 1;
    }
    try testing.expect(checked >= 5);
}

test "an edge two polygons share is sampled the same from both" {
    var scene: scenes.Scene = .{};
    scene.course();
    try sharedEdgesAgree(scene.sources());
    // Turned by its pose, so shared edges run at slants and their samples are not exact
    // multiples of anything.
    var turned_scene: scenes.Scene = .{};
    turned_scene.course();
    var turned = turned_scene.sources()[0];
    turned.pose = .{ .position = .init(20, 0, 20), .rotation = core.math.Quat.fromAxisAngle(.init(0, 1, 0), 0.6) };
    try sharedEdgesAgree(&.{turned});
}

fn sharedEdgesAgree(sources: []const input.Source) !void {
    var c = walker;
    c.region_merge_area = 0;
    // Fine enough that the ramps' and steps' shared edges keep samples of their own.
    c.detail_max_error = 0.005;
    c.detail_sample_distance = 0.2;
    var m = try poly.build(testing.allocator, c, sources);
    defer m.deinit(testing.allocator);
    var shared: u32 = 0;
    var samples: usize = 0;
    for (m.polygons, 0..) |*p, pi| for (0..p.count) |e| {
        const q = p.neighbours[e];
        if (q == poly.none_polygon or q < pi) continue;
        const a = m.position(p.vertices[e]);
        const b = m.position(p.vertices[(e + 1) % p.count]);
        var mine: [64]Vec3 = undefined;
        var theirs: [64]Vec3 = undefined;
        const n = onSegment(&m, @intCast(pi), a, b, &mine);
        const k = onSegment(&m, q, a, b, &theirs);
        try testing.expectEqual(n, k);
        samples += n - 2;
        for (mine[0..n]) |v| {
            var found = false;
            // To the bit: a shared vertex drawn or located from either side is one point.
            for (theirs[0..k]) |w| {
                if (v.x == w.x and v.y == w.y and v.z == w.z) found = true;
            }
            try testing.expect(found);
        }
        shared += 1;
    };
    try testing.expect(shared > 0);
    try testing.expect(samples > 0);
}

fn onSegment(m: *const Mesh, pi: u32, a: Vec3, b: Vec3, out: []Vec3) usize {
    const sub = m.detail.meshes[pi];
    var n: usize = 0;
    for (m.detail.vertices[sub.vertex_base..][0..sub.vertex_count]) |v| {
        if (@abs(detail_mod.turnf(a, b, v)) > 1e-5) continue;
        const t = (v.x - a.x) * (b.x - a.x) + (v.z - a.z) * (b.z - a.z);
        const len2 = (b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z);
        if (t < -1e-6 or t > len2 + 1e-6) continue;
        out[n] = v;
        n += 1;
    }
    return n;
}

test "without samples the detail is the polygon's own vertices" {
    var scene: scenes.Scene = .{};
    scene.course();
    var c = walker;
    c.detail_sample_distance = 0;
    var m = try built(&scene, c);
    defer m.deinit(testing.allocator);
    for (m.polygons, m.detail.meshes) |p, sub| {
        try testing.expectEqual(@as(u32, p.count), sub.vertex_count);
        try testing.expectEqual(@as(u32, p.count) - 2, sub.triangle_count);
    }
}

// -- locate --------------------------------------------------------------------------

test "locate finds the floor under a point, the nearer of two floors, and nothing far away" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(6, 0, 6), false);
    scene.box(.init(1.05, 2.5, 1.05), .init(5.05, 2.7, 5.05));
    var m = try built(&scene, walker);
    defer m.deinit(testing.allocator);
    const extent: Vec3 = .init(0.5, 1, 0.5);
    // On the floor away from the slab, and under the slab.
    const open_floor = m.locate(.init(0.8, 0.3, 3), extent).?;
    try testing.expectApproxEqAbs(@as(f32, 0.8), open_floor.point.x, 1e-4);
    try testing.expect(open_floor.point.y < 0.1);
    const under = m.locate(.init(3, 0.3, 3), extent).?;
    try testing.expect(under.point.y < 0.1);
    // With an extent tall enough to hold both floors, the one nearer in height wins: above the
    // slab its top, just over the floor the floor.
    const both: Vec3 = .init(0.5, 4, 0.5);
    const over = m.locate(.init(3, 2.9, 3), both).?;
    try testing.expect(over.point.y > 2.6);
    try testing.expect(over.polygon != under.polygon);
    const low = m.locate(.init(3, 0.4, 3), both).?;
    try testing.expect(low.point.y < 0.1);
    // Off the mesh within the extent: the nearest boundary point.
    const beside = m.locate(.init(0.1, 0, 3), extent).?;
    try testing.expect(beside.point.x >= 0.39);
    // Beyond the extent, and refusals.
    try testing.expect(m.locate(.init(-3, 0, 3), extent) == null);
    try testing.expect(m.locate(.init(3, 1.4, 3), .init(0.5, 0.1, 0.5)) == null);
    try testing.expect(m.locate(.init(std.math.nan(f32), 0, 3), extent) == null);
    try testing.expect(m.locate(.init(3, 0, 3), .init(-1, 1, 1)) == null);
    try testing.expect(m.locate(.init(3, 0, 3), .init(std.math.inf(f32), 1, 1)) == null);
}

// -- the task ------------------------------------------------------------------------

test "a build on the pool answers nothing until it has run, and copies its sources" {
    const gpa = testing.allocator;
    var manual = try core.tasks.Manual.init(gpa, 4);
    defer manual.deinit();
    var scene: scenes.Scene = .{};
    scene.course();
    var b = try task.Build.start(manual.tasks(), gpa, walker, scene.sources());
    // The caller's geometry is spoiled at once; the build copied it.
    for (scene.positions[0..scene.position_count]) |*p| p.* = .init(std.math.nan(f32), 0, 0);
    try testing.expect(!b.ready());
    try testing.expect(b.take() == null);
    manual.runAll();
    try testing.expect(b.ready());
    var m = try b.take().?;
    defer m.deinit(gpa);
    try testing.expect(b.take() == null);
    b.deinit();
    try poly_tests.expectWellFormed(&m, 6);
    var fresh: scenes.Scene = .{};
    fresh.course();
    var direct = try built(&fresh, walker);
    defer direct.deinit(gpa);
    try testing.expectEqual(hashMesh(&direct), hashMesh(&m));
}

test "a stale build is discarded untaken, and a failed one answers its error" {
    const gpa = testing.allocator;
    var manual = try core.tasks.Manual.init(gpa, 4);
    defer manual.deinit();
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(3, 0, 3), false);
    var stale = try task.Build.start(manual.tasks(), gpa, walker, scene.sources());
    var bad = walker;
    bad.cell_size = 0;
    var refused = try task.Build.start(manual.tasks(), gpa, bad, scene.sources());
    manual.runAll();
    stale.deinit();
    try testing.expectError(error.InvalidConfig, refused.take().?);
    refused.deinit();
}

test "a full executor refuses the start and frees what it copied" {
    const gpa = testing.allocator;
    var manual = try core.tasks.Manual.init(gpa, 1);
    defer manual.deinit();
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(3, 0, 3), false);
    var first = try task.Build.start(manual.tasks(), gpa, walker, scene.sources());
    try testing.expectError(error.Full, task.Build.start(manual.tasks(), gpa, walker, scene.sources()));
    manual.runAll();
    first.deinit();
}

// -- the view ------------------------------------------------------------------------

test "the view writes exactly its count, lifted, premultiplied" {
    var scene: scenes.Scene = .{};
    scene.course();
    var m = try built(&scene, walker);
    defer m.deinit(testing.allocator);
    const n = view.debugViewCount(&m);
    const out = try testing.allocator.alloc(view.ViewVertex, n);
    defer testing.allocator.free(out);
    const written = view.debugView(&m, out);
    try testing.expectEqual(n, written.len);
    try testing.expect(n % 3 == 0);
    for (written) |v| {
        try testing.expect(v.position.isFinite());
        for (v.color[0..3]) |c| try testing.expect(c <= v.color[3] + 1e-6);
        try testing.expect(v.position.y >= m.origin.y);
    }
}

// -- sweeps --------------------------------------------------------------------------

test "a thousand mutated inputs neither panic nor hang" {
    const gpa = testing.allocator;
    var rng = core.rng.Pcg32.init(32, 6);
    const specials = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 1e9, -8192, 8192, 8192.5, 0, -0.0, 1e-30 };
    var built_ok: u32 = 0;
    for (0..1000) |_| {
        var scene: scenes.Scene = .{};
        scene.floor(.init(0, 0, 0), .init(2, 0, 2), false);
        scene.box(.init(0.6, 0, 0.6), .init(1.1, 0.5, 1.1));
        scene.ramp(.init(0, 0, 2), 1, 1.5, 30);
        const changes = 1 + rng.below(4);
        for (0..changes) |_| switch (rng.below(5)) {
            0 => {
                const i = rng.below(@intCast(scene.position_count));
                const axis = rng.below(3);
                const v = specials[rng.below(specials.len)];
                switch (axis) {
                    0 => scene.positions[i].x = v,
                    1 => scene.positions[i].y = v,
                    else => scene.positions[i].z = v,
                }
            },
            1 => scene.indices[rng.below(@intCast(scene.index_count))] = rng.below(@intCast(scene.position_count + 4)),
            2 => {
                const i = rng.below(@intCast(scene.position_count));
                scene.positions[i] = .init(@as(f32, @floatFromInt(rng.below(400))) / 100, @as(f32, @floatFromInt(rng.below(300))) / 100, @as(f32, @floatFromInt(rng.below(400))) / 100);
            },
            3 => scene.index_count -= @min(scene.index_count, rng.below(7)),
            else => {
                const a = rng.below(@intCast(scene.index_count));
                const b = rng.below(@intCast(scene.index_count));
                std.mem.swap(u32, &scene.indices[a], &scene.indices[b]);
            },
        };
        if (poly.build(gpa, walker, scene.sources())) |m_| {
            var m = m_;
            built_ok += 1;
            m.deinit(gpa);
        } else |_| {}
    }
    try testing.expect(built_ok > 0);
}

test "every allocation failure in a whole build is reported, and nothing leaks" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(2, 0, 2), false);
    scene.ramp(.init(0, 0, 2), 1, 1.2, 25);
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, s: *scenes.Scene) !void {
            var m = try poly.build(gpa, walker, s.sources());
            m.deinit(gpa);
        }
    }.run, .{&scene});
}

// -- the pin -------------------------------------------------------------------------

/// Every field of a mesh, field by field so no padding is read.
pub fn hashMesh(m: *const Mesh) u64 {
    var h = std.hash.Wyhash.init(0);
    for (m.vertices) |v| h.update(std.mem.asBytes(&v));
    for (m.polygons) |p| {
        h.update(std.mem.asBytes(&p.vertices));
        h.update(std.mem.asBytes(&p.neighbours));
        h.update(std.mem.asBytes(&p.count));
        h.update(std.mem.asBytes(&p.region));
    }
    for (m.detail.vertices) |v| {
        for ([_]f32{ v.x, v.y, v.z }) |f| h.update(std.mem.asBytes(&@as(u32, @bitCast(f))));
    }
    for (m.detail.triangles) |t| h.update(std.mem.asBytes(&t));
    for (m.detail.meshes) |s| {
        for ([_]u32{ s.vertex_base, s.vertex_count, s.triangle_base, s.triangle_count }) |w| h.update(std.mem.asBytes(&w));
    }
    return h.final();
}

test "the course's mesh is the same every time, and pinned" {
    var a_scene: scenes.Scene = .{};
    a_scene.course();
    var a = try built(&a_scene, walker);
    defer a.deinit(testing.allocator);
    var b_scene: scenes.Scene = .{};
    b_scene.course();
    var b = try built(&b_scene, walker);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(hashMesh(&a), hashMesh(&b));
    // Recorded at Step 5, equal in Debug, ReleaseSafe and x86_64 under Rosetta. A change to any
    // stage moves it; a deliberate one updates it here and says why in its Resolution.
    try testing.expectEqual(@as(u64, 14865720887737603270), hashMesh(&a));
    try testing.expectEqual(@as(usize, 15), a.polygons.len);
    try testing.expectEqual(@as(usize, 35), a.detail.triangles.len);
}

test "every detail triangulation is Delaunay, and a fine error makes it sample" {
    var scene: scenes.Scene = .{};
    scene.course();
    var c = walker;
    c.detail_max_error = 0.005;
    c.detail_sample_distance = 0.3;
    var m = try built(&scene, c);
    defer m.deinit(testing.allocator);
    var added: u32 = 0;
    var interior_edges: u32 = 0;
    for (m.polygons, m.detail.meshes, 0..) |p, sub, pi| {
        added += sub.vertex_count - p.count;
        const pts = m.detail.vertices[sub.vertex_base..][0..sub.vertex_count];
        const tris = m.detail.triangles[sub.triangle_base..][0..sub.triangle_count];
        _ = pi;
        for (tris, 0..) |t, ti| for (0..3) |k| {
            const a = t[k];
            const b = t[(k + 1) % 3];
            for (tris, 0..) |u, ui| {
                if (ui == ti) continue;
                for (0..3) |j| if (u[j] == b and u[(j + 1) % 3] == a) {
                    interior_edges += 1;
                    const q = u[(j + 2) % 3];
                    try testing.expect(!strictlyInCircle(pts[t[0]], pts[t[1]], pts[t[2]], pts[q]));
                };
            }
        };
    }
    try testing.expect(added > 0);
    try testing.expect(interior_edges > 0);
}

/// The textbook test with a tolerance a little wider than the build's, so a cocircular four
/// that the build left either way passes.
fn strictlyInCircle(a: Vec3, b: Vec3, c: Vec3, d: Vec3) bool {
    const ax: f64 = a.x - d.x;
    const ay: f64 = -(a.z - d.z);
    const bx: f64 = b.x - d.x;
    const by: f64 = -(b.z - d.z);
    const cx: f64 = c.x - d.x;
    const cy: f64 = -(c.z - d.z);
    const det = (ax * ax + ay * ay) * (bx * cy - cx * by) -
        (bx * bx + by * by) * (ax * cy - cx * ay) +
        (cx * cx + cy * cy) * (ax * by - bx * ay);
    return det > 1e-9;
}

// -- timing --------------------------------------------------------------------------

test "build time: the course and a court-sized yard, single-threaded, printed" {
    // Criterion 5's figures come from the samples' own levels in Steps 6 and 7; these scenes
    // are their stand-ins. Debug measures nothing worth reading.
    if (builtin.mode == .Debug) return error.SkipZigTest;
    const names = [_][]const u8{ "course", "yard" };
    for (names) |name| {
        var scene: scenes.Scene = .{};
        if (std.mem.eql(u8, name, "course")) scene.course() else scene.yard();
        var best: u64 = std.math.maxInt(u64);
        var polygons: usize = 0;
        for (0..5) |_| {
            const start = std.Io.Clock.awake.now(testing.io);
            var m = try built(&scene, walker);
            const ns: u64 = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
            polygons = m.polygons.len;
            m.deinit(testing.allocator);
            best = @min(best, ns);
        }
        std.debug.print("nav build time ({t}): {s} {d:.2} ms, {d} polygons\n", .{ builtin.mode, name, @as(f64, @floatFromInt(best)) / 1e6, polygons });
    }
}
