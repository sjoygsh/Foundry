//! Areas and links in the build (`agents.md` §4, §13, Step 2).

const std = @import("std");
const core = @import("core");

const build_tests = @import("build_tests.zig");
const config_mod = @import("config.zig");
const features = @import("features.zig");
const heightfield = @import("heightfield.zig");
const link = @import("link.zig");
const open = @import("open.zig");
const poly = @import("poly.zig");
const poly_tests = @import("poly_tests.zig");
const scenes = @import("scenes.zig");
const task = @import("task.zig");

const testing = std.testing;
const Features = features.Features;
const Mesh = poly.Mesh;
const Vec3 = core.math.Vec3;
const walker = config_mod.walker;

fn floor10(scene: *scenes.Scene) void {
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
}

fn built(scene: *scenes.Scene, f: Features) !Mesh {
    return poly.buildWith(testing.allocator, walker, scene.sources(), f);
}

/// The area of the polygons of one area, seen from +Y, square metres.
fn areaOf(m: *const Mesh, area: u8) f64 {
    var cells2: i64 = 0;
    for (m.polygons) |*p| {
        if (p.area == area) cells2 += poly.polygonArea2(m, p);
    }
    const cs: f64 = m.cell_size;
    return @as(f64, @floatFromInt(cells2)) * cs * cs / 2;
}

const mud: features.Volume = .{ .area = 1, .min = .init(3, -1, 3), .max = .init(7, 1, 7) };

test "a volume makes polygons of its area, and together they are the same floor" {
    var scene: scenes.Scene = .{};
    floor10(&scene);
    var plain = try built(&scene, .{});
    defer plain.deinit(testing.allocator);
    var m = try built(&scene, .{ .costs = &.{ 1, 4 }, .volumes = &.{mud} });
    defer m.deinit(testing.allocator);
    try poly_tests.expectWellFormed(&m, 6);
    try testing.expectApproxEqAbs(@as(f64, 16), areaOf(&m, 1), 0.8);
    try testing.expectApproxEqAbs(plain.area(), m.area(), 0.2);
    try testing.expectEqual(@as(u32, 1), m.islands);
    try testing.expectEqualSlices(f32, &.{ 1, 4 }, m.costs);
    for (0..m.polygons.len) |p| {
        const want: f32 = if (m.polygons[p].area == 1) 4 else 1;
        try testing.expectEqual(want, m.costOf(@intCast(p)));
    }
}

test "marking follows erosion: an area never moves where an agent fits" {
    var scene: scenes.Scene = .{};
    floor10(&scene);
    scene.box(.init(4.5, 0, 4.5), .init(5.5, 1, 5.5));
    var hf = try heightfield.solid(testing.allocator, walker, scene.sources());
    defer hf.deinit(testing.allocator);
    var plain = try open.OpenField.init(testing.allocator, &hf);
    defer plain.deinit(testing.allocator);
    try plain.erode(testing.allocator);
    var marked = try open.OpenField.init(testing.allocator, &hf);
    defer marked.deinit(testing.allocator);
    try marked.erode(testing.allocator);
    marked.markAreas(&.{mud});
    var inside: u32 = 0;
    for (plain.spans, marked.spans) |a, b| {
        try testing.expectEqual(a.area == open.unwalkable, b.area == open.unwalkable);
        if (b.area > open.walkable) inside += 1;
    }
    try testing.expect(inside > 1000);
}

test "a region is one area, and a small area keeps its own polygons" {
    var scene: scenes.Scene = .{};
    floor10(&scene);
    // 1 m² is under the 4 m² merge area, so only the area rule keeps it apart.
    const small: features.Volume = .{ .area = 1, .min = .init(4, -1, 4), .max = .init(5, 1, 5) };
    var m = try built(&scene, .{ .costs = &.{ 1, 3 }, .volumes = &.{small} });
    defer m.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 1), areaOf(&m, 1), 0.3);
    for (m.polygons) |p| for (m.polygons) |q| {
        if (p.region == q.region) try testing.expectEqual(p.area, q.area);
    };
}

test "a later volume wins, and a volume marks only the floors inside it" {
    var scene: scenes.Scene = .{};
    floor10(&scene);
    scene.floor(.init(0, 2.2, 0), .init(10, 2.2, 10), false);
    const over: features.Volume = .{ .area = 2, .min = .init(3, -1, 3), .max = .init(5, 1, 5) };
    var m = try built(&scene, .{ .costs = &.{ 1, 3, 9 }, .volumes = &.{ mud, over } });
    defer m.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 4), areaOf(&m, 2), 0.5);
    try testing.expectApproxEqAbs(@as(f64, 12), areaOf(&m, 1), 0.8);
    // The floor above is outside both boxes' height, and is all unmarked.
    for (m.polygons, 0..) |p, pi| {
        if (m.position(p.vertices[0]).y > 1) {
            try testing.expectEqual(@as(u8, 0), p.area);
            try testing.expectEqual(@as(f32, 1), m.costOf(@intCast(pi)));
        }
    }
}

test "each kind of link attaches, and a two-way link is listed at both ends" {
    var scene: scenes.Scene = .{};
    scene.course();
    const inputs = [_]features.LinkInput{
        .{ .kind = .ladder, .from = .init(1, 0, 1), .to = .init(2.7, 0.6, 2.5), .two_way = true, .cost = 2 },
        .{ .kind = .drop, .from = .init(2.7, 0.6, 2.5), .to = .init(4.5, 0, 2.5) },
        .{ .kind = .jump, .from = .init(1, 0, 1), .to = .init(4.5, 0, 2.5), .arc = 1 },
    };
    var m = try built(&scene, .{ .links = &inputs });
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), m.links.len);
    try testing.expectEqual(@as(u32, 0), m.links_unattached);
    const ladder = m.links[0];
    try testing.expectEqual(features.LinkKind.ladder, ladder.kind);
    try testing.expectApproxEqAbs(@as(f32, 0.6), ladder.to.y, 0.1);
    try testing.expectEqual(ladder.from_polygon, m.locate(.init(1, 0, 1), .init(0.1, 0.1, 0.1)).?.polygon);
    try testing.expectEqual(ladder.to_polygon, m.locate(.init(2.7, 0.6, 2.5), .init(0.1, 0.1, 0.1)).?.polygon);
    try testing.expectEqual(@as(f32, 2), ladder.cost);
    try testing.expectEqual(@as(f32, 1), m.links[2].arc);

    var listed: [3]u32 = @splat(0);
    for (0..m.polygons.len) |p| for (m.linksFrom(@intCast(p))) |l| {
        listed[l] += 1;
        const it = m.links[l];
        try testing.expect(it.from_polygon == p or (it.two_way and it.to_polygon == p));
    };
    try testing.expectEqual(@as(u32, 2), listed[0]);
    try testing.expectEqual(@as(u32, 1), listed[1]);
    try testing.expectEqual(@as(u32, 1), listed[2]);
}

test "a link joins islands for search, and the count of islands ignores it" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(5, 0, 5), false);
    scene.floor(.init(7, 0, 0), .init(12, 0, 5), false);
    var m = try built(&scene, .{ .links = &.{.{ .kind = .jump, .from = .init(4.5, 0, 2.5), .to = .init(7.5, 0, 2.5), .snap = 1 }} });
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), m.islands);
    try testing.expectEqual(@as(usize, 1), m.links.len);
}

test "a link with an end on no polygon is counted, not fatal" {
    var scene: scenes.Scene = .{};
    floor10(&scene);
    const inputs = [_]features.LinkInput{
        .{ .kind = .jump, .from = .init(5, 0, 5), .to = .init(5, 30, 5) },
        .{ .kind = .jump, .from = .init(5, 0, 5), .to = .init(20, 0, 5) },
        .{ .kind = .jump, .from = .init(2, 0, 2), .to = .init(8, 0, 8) },
    };
    var m = try built(&scene, .{ .links = &inputs });
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), m.links_unattached);
    try testing.expectEqual(@as(usize, 1), m.links.len);
    // All left out: a mesh with no links answers empty, and has no tables.
    var none = try built(&scene, .{ .links = inputs[0..2] });
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), none.links_unattached);
    try testing.expectEqual(@as(usize, 0), none.linksFrom(0).len);
    try testing.expectEqual(@as(usize, 0), none.link_first.len);
}

test "the islands the build counts are the islands a flood finds" {
    for (0..2) |which| {
        var scene: scenes.Scene = .{};
        if (which == 0) scene.course() else scene.yard();
        var m = try built(&scene, .{});
        defer m.deinit(testing.allocator);
        try testing.expectEqual(try poly_tests.islands(&m), m.islands);
    }
}

test "no features is `build`, to the byte, and M32's pin holds" {
    var scene: scenes.Scene = .{};
    scene.course();
    var a = try poly.build(testing.allocator, walker, scene.sources());
    defer a.deinit(testing.allocator);
    var b = try built(&scene, .{});
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 14865720887737603270), build_tests.hashMesh(&a));
    try testing.expectEqual(build_tests.hashMesh(&a), build_tests.hashMesh(&b));
}

test "features out of bounds are refused before anything is allocated" {
    var scene: scenes.Scene = .{};
    floor10(&scene);
    var no_memory = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const bad: []const Features = &.{
        .{ .costs = &.{ 1, 0.5 } },
        .{ .costs = &.{1}, .volumes = &.{mud} },
        .{ .links = &.{.{ .kind = .jump, .from = .zero, .to = .zero }} },
    };
    for (bad) |f| {
        try testing.expectError(error.InvalidFeatures, poly.buildWith(no_memory.allocator(), walker, scene.sources(), f));
    }
    try testing.expectEqual(@as(usize, 0), no_memory.allocated_bytes);
}

const course_links = [_]features.LinkInput{
    .{ .kind = .ladder, .from = .init(1, 0, 1), .to = .init(2.7, 0.6, 2.5), .two_way = true },
    .{ .kind = .drop, .from = .init(2.7, 0.6, 2.5), .to = .init(4.5, 0, 2.5) },
};
const course_volume: features.Volume = .{ .area = 1, .min = .init(3.5, -0.5, 0.5), .max = .init(5.5, 0.5, 1.8) };

test "a build with features survives every allocation failure" {
    const S = struct {
        fn run(gpa: std.mem.Allocator, scene: *scenes.Scene) !void {
            var m = try poly.buildWith(gpa, walker, scene.sources(), .{ .costs = &.{ 1, 4 }, .volumes = &.{course_volume}, .links = &course_links });
            m.deinit(gpa);
        }
    };
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(6, 0, 6), false);
    scene.box(.init(2.2, 0, 2), .init(3.2, 0.6, 3));
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{&scene});
}

test "the task copies its features, and builds with them" {
    var manual = try core.tasks.Manual.init(testing.allocator, 2);
    defer manual.deinit();
    var scene: scenes.Scene = .{};
    scene.course();
    const costs = try testing.allocator.dupe(f32, &.{ 1, 4 });
    const volumes = try testing.allocator.dupe(features.Volume, &.{course_volume});
    const links = try testing.allocator.dupe(features.LinkInput, &course_links);
    var b = try task.Build.startWith(manual.tasks(), testing.allocator, walker, scene.sources(), .{ .costs = costs, .volumes = volumes, .links = links });
    defer b.deinit();
    @memset(costs, 99);
    testing.allocator.free(costs);
    testing.allocator.free(volumes);
    testing.allocator.free(links);
    manual.runNext();
    var m = try b.take().?;
    defer m.deinit(testing.allocator);
    try testing.expectEqualSlices(f32, &.{ 1, 4 }, m.costs);
    try testing.expectEqual(@as(usize, 2), m.links.len);
    var direct = try built(&scene, .{ .costs = &.{ 1, 4 }, .volumes = &.{course_volume}, .links = &course_links });
    defer direct.deinit(testing.allocator);
    try testing.expectEqual(build_tests.hashMesh(&direct), build_tests.hashMesh(&m));
}

test "the course with an area and links is the same every time, and pinned" {
    var scene: scenes.Scene = .{};
    scene.course();
    const f: Features = .{ .costs = &.{ 1, 4 }, .volumes = &.{course_volume}, .links = &course_links };
    var a = try built(&scene, f);
    defer a.deinit(testing.allocator);
    var b = try built(&scene, f);
    defer b.deinit(testing.allocator);
    try poly_tests.expectWellFormed(&a, 6);
    try testing.expectEqual(build_tests.hashMesh(&a), build_tests.hashMesh(&b));
    try testing.expect(build_tests.hashMesh(&a) != 14865720887737603270);
    // Recorded at M33 Step 2, equal in Debug, ReleaseSafe and x86_64 under Rosetta.
    try testing.expectEqual(@as(u64, 14748995640725302437), build_tests.hashMesh(&a));
}
