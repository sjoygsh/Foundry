//! Running obstacles and adoption (`agents.md` §9, §13, Step 6): a box source is a static box to
//! the byte, rebuilds coalesce, and a mesh reaches a crowd only as an input.

const std = @import("std");
const core = @import("core");

const build_tests = @import("build_tests.zig");
const config_mod = @import("config.zig");
const crowd_mod = @import("crowd.zig");
const input = @import("input.zig");
const meshes_mod = @import("meshes.zig");
const poly = @import("poly.zig");
const scenes = @import("scenes.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Crowd = crowd_mod.Crowd;
const Meshes = meshes_mod.Meshes;
const Mesh = poly.Mesh;
const Source = input.Source;
const Vec3 = core.math.Vec3;
const walker = config_mod.walker;
const dt: f32 = 1.0 / 60.0;

const params: crowd_mod.AgentParams = .{ .radius = 0.3, .height = 1.8, .speed = 2, .acceleration = 8 };

fn level(scene: *scenes.Scene) void {
    scene.floor(.init(0, 0, 0), .init(12, 0, 12), false);
}

/// `level`'s sources with a box at `centre`, if any.
fn withBox(scene: *scenes.Scene, box: *meshes_mod.BoxGeometry, half: Vec3, centre: ?Vec3, out: *[2]Source) []const Source {
    out[0] = scene.sources()[0];
    const c = centre orelse return out[0..1];
    out[1] = meshes_mod.boxSource(half, .{ .position = c, .rotation = .identity }, box);
    return out[0..2];
}

test "a box source gives the mesh a static box in the same place gives, to the byte" {
    const half: Vec3 = .init(1.5, 1, 0.5);
    for ([_]Vec3{ .init(6, 1, 6), .init(3, 1, 9), .init(6, 3, 6), .init(6, -2, 6) }) |c| {
        var plain: scenes.Scene = .{};
        level(&plain);
        var box: meshes_mod.BoxGeometry = undefined;
        var sources: [2]Source = undefined;
        var moved = try poly.build(gpa, walker, withBox(&plain, &box, half, c, &sources));
        defer moved.deinit(gpa);

        var fixed: scenes.Scene = .{};
        level(&fixed);
        fixed.box(c.sub(half), c.add(half));
        var static = try poly.build(gpa, walker, fixed.sources());
        defer static.deinit(gpa);
        try testing.expectEqual(build_tests.hashMesh(&static), build_tests.hashMesh(&moved));
    }
}

test "a box removed gives back the mesh with no box, and one under the floor or overhead cuts nothing" {
    var scene: scenes.Scene = .{};
    level(&scene);
    var box: meshes_mod.BoxGeometry = undefined;
    var sources: [2]Source = undefined;
    var none = try poly.build(gpa, walker, withBox(&scene, &box, .zero, null, &sources));
    defer none.deinit(gpa);
    var again = try poly.build(gpa, walker, scene.sources());
    defer again.deinit(gpa);
    try testing.expectEqual(build_tests.hashMesh(&none), build_tests.hashMesh(&again));

    // A gate's two places: across the way it cuts; sunk, its top under the floor, it does not.
    const half: Vec3 = .init(6, 1.25, 0.08);
    var closed = try poly.build(gpa, walker, withBox(&scene, &box, half, .init(6, 1.25, 6), &sources));
    defer closed.deinit(gpa);
    var open = try poly.build(gpa, walker, withBox(&scene, &box, half, .init(6, -1.4, 6), &sources));
    defer open.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), closed.islands);
    try testing.expectEqual(@as(u32, 1), open.islands);
    // Sunk, its top is the floor's own height less 0.15, and it is not part of the walking.
    try testing.expectApproxEqAbs(none.area(), open.area(), 0.3);
}

test "a pose turns and moves a box" {
    var scene: scenes.Scene = .{};
    level(&scene);
    var box: meshes_mod.BoxGeometry = undefined;
    const source = meshes_mod.boxSource(.init(2, 1, 0.1), .{ .position = .init(6, 1, 6), .rotation = core.math.Quat.fromAxisAngle(.up, std.math.pi / 2.0) }, &box);
    var m = try poly.build(gpa, walker, &.{ scene.sources()[0], source });
    defer m.deinit(gpa);
    // Long on Z now, so it blocks there and not on X.
    try testing.expect(m.locate(.init(6, 0, 7.5), .init(0.1, 0.5, 0.1)) == null);
    try testing.expect(m.locate(.init(7.5, 0, 6), .init(0.1, 0.5, 0.1)) != null);
}

test "rebuilds coalesce: one at a time, the next reading the poses as they are by then" {
    var manual = try core.tasks.Manual.init(gpa, 4);
    defer manual.deinit();
    var meshes = Meshes.init(gpa, .{});
    defer meshes.deinit(manual.tasks());
    var scene: scenes.Scene = .{};
    level(&scene);
    const half: Vec3 = .init(1, 1, 1);
    var box: meshes_mod.BoxGeometry = undefined;
    var sources: [2]Source = undefined;

    var builds: u32 = 0;
    var last: ?Vec3 = null;
    for (0..30) |t| {
        const x = 2 + @as(f32, @floatFromInt(t)) * 0.25;
        last = .init(x, 1, 6);
        meshes.markDirty();
        if (meshes.wantsBuild()) {
            try meshes.start(manual.tasks(), walker, withBox(&scene, &box, half, last, &sources), .{});
            builds += 1;
        }
        // The pool finishes one build in the time the box moves ten times.
        if (t % 10 == 9) manual.runNext();
        _ = meshes.pump();
    }
    try testing.expect(builds >= 3 and builds <= 4);
    // The last change is still owed, and the mesh that settles is the last pose's.
    if (meshes.pending != null) manual.runNext();
    _ = meshes.pump();
    try testing.expect(meshes.wantsBuild());
    try meshes.start(manual.tasks(), walker, withBox(&scene, &box, half, last, &sources), .{});
    try testing.expect(!meshes.wantsBuild());
    manual.runNext();
    const arrival = meshes.pump().?;
    const settled = meshes.get(arrival.generation).?;
    var direct = try poly.build(gpa, walker, withBox(&scene, &box, half, last, &sources));
    defer direct.deinit(gpa);
    try testing.expectEqual(build_tests.hashMesh(&direct), build_tests.hashMesh(settled));
    try testing.expect(meshes.pump() == null);
}

test "a full executor leaves the change owed, and a failed build says so" {
    var manual = try core.tasks.Manual.init(gpa, 1);
    defer manual.deinit();
    var other = try core.tasks.Manual.init(gpa, 1);
    defer other.deinit();
    var meshes = Meshes.init(gpa, .{});
    defer meshes.deinit(other.tasks());
    var scene: scenes.Scene = .{};
    level(&scene);
    var blocker = Meshes.init(gpa, .{});
    defer blocker.deinit(manual.tasks());
    blocker.markDirty();
    try blocker.start(manual.tasks(), walker, scene.sources(), .{});
    meshes.markDirty();
    try testing.expectError(error.Full, meshes.start(manual.tasks(), walker, scene.sources(), .{}));
    try testing.expect(meshes.wantsBuild());
    manual.runNext();
    try testing.expect(blocker.pump().?.generation == 1);

    var bad = walker;
    bad.agent_height = -1;
    try meshes.start(other.tasks(), bad, scene.sources(), .{});
    other.runNext();
    const arrival = meshes.pump().?;
    try testing.expectEqual(error.InvalidConfig, arrival.failed);
    try testing.expect(meshes.get(1) == null and meshes.get(0) == null);
}

test "a list with a limit keeps the first, the one in use and the newest" {
    var scene: scenes.Scene = .{};
    level(&scene);
    var meshes = Meshes.init(gpa, .{ .keep = 3 });
    defer meshes.deinit(core.tasks.immediate);
    for (1..7) |g| {
        const generation = try meshes.add(try poly.build(gpa, walker, scene.sources()));
        try testing.expectEqual(@as(u32, @intCast(g)), generation);
        if (g == 2) meshes.use(2);
    }
    try testing.expect(meshes.get(1) != null and meshes.get(2) != null and meshes.get(6) != null);
    try testing.expect(meshes.get(3) == null and meshes.get(4) == null and meshes.get(5) == null);
    try testing.expect(meshes.get(7) == null);
}

/// A run: an agent crossing the room, and a wall dropped across its way at tick 60. `adopt` says
/// on which tick each generation is adopted, recorded as an input.
const Input = struct { tick: u32, generation: u32 };

fn play(meshes: *const Meshes, inputs: []const Input, ticks: u32, hashes: []u64) !void {
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(meshes.get(1).?);
    const a = try crowd.add(params, .init(2, 0, 3));
    const b = try crowd.add(params, .init(4, 0, 2));
    _ = crowd.setTarget(a, .init(2, 0, 10));
    _ = crowd.setTarget(b, .init(4, 0, 10));
    var next: usize = 0;
    for (0..ticks) |t| {
        // First in the tick, as `Game.step` will.
        if (next < inputs.len and inputs[next].tick == t) {
            crowd.setMesh(meshes.get(inputs[next].generation).?);
            next += 1;
        }
        crowd.step(dt);
        hashes[t] = crowd.hash();
    }
}

const Order = enum { immediate, forward, held };

/// Runs the frame loop under `order`, recording when each mesh was adopted.
fn record(order: Order, inputs: *std.ArrayList(Input), hashes: []u64) !Meshes {
    var manual = try core.tasks.Manual.init(gpa, 2);
    defer manual.deinit();
    const tasks = if (order == .immediate) core.tasks.immediate else manual.tasks();
    var meshes = Meshes.init(gpa, .{});
    errdefer meshes.deinit(tasks);
    var scene: scenes.Scene = .{};
    level(&scene);
    var box: meshes_mod.BoxGeometry = undefined;
    var sources: [2]Source = undefined;
    const half: Vec3 = .init(3, 1, 0.2);
    const first = try meshes.add(try poly.build(gpa, walker, withBox(&scene, &box, half, null, &sources)));
    try testing.expectEqual(@as(u32, 1), first);

    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(meshes.get(1).?);
    const a = try crowd.add(params, .init(2, 0, 3));
    const b = try crowd.add(params, .init(4, 0, 2));
    _ = crowd.setTarget(a, .init(2, 0, 10));
    _ = crowd.setTarget(b, .init(4, 0, 10));
    var owed: u32 = 0;
    const hold: u32 = if (order == .held) 37 else 3;
    var held: u32 = 0;
    for (0..hashes.len) |t| {
        if (t == 60) meshes.markDirty();
        if (meshes.wantsBuild()) try meshes.start(tasks, walker, withBox(&scene, &box, half, .init(3, 1, 6), &sources), .{});
        if (order != .immediate and manual.pending() > 0) {
            held += 1;
            if (held >= hold) {
                manual.runNext();
                held = 0;
            }
        }
        if (meshes.pump()) |arrival| owed = arrival.generation;
        if (owed != 0) {
            try inputs.append(gpa, .{ .tick = @intCast(t), .generation = owed });
            crowd.setMesh(meshes.get(owed).?);
            owed = 0;
        }
        crowd.step(dt);
        hashes[t] = crowd.hash();
    }
    return meshes;
}

test "a mesh reaches a crowd only as an input: each run replays exactly, however late it arrived" {
    const ticks = 600;
    for ([_]Order{ .immediate, .forward, .held }) |order| {
        var inputs: std.ArrayList(Input) = .empty;
        defer inputs.deinit(gpa);
        const live = try gpa.alloc(u64, ticks);
        defer gpa.free(live);
        const again = try gpa.alloc(u64, ticks);
        defer gpa.free(again);
        var meshes = try record(order, &inputs, live);
        defer meshes.deinit(core.tasks.immediate);
        try testing.expectEqual(@as(usize, 1), inputs.items.len);
        try play(&meshes, inputs.items, ticks, again);
        try testing.expectEqualSlices(u64, live, again);
    }
}

test "the same adoption tick gives the same bytes under every executor, and a later one does not" {
    const ticks = 600;
    var hashes: [3][]u64 = undefined;
    var ticks_adopted: [3]u32 = undefined;
    const orders = [_]Order{ .immediate, .forward, .held };
    for (orders, 0..) |order, i| {
        hashes[i] = try gpa.alloc(u64, ticks);
        var inputs: std.ArrayList(Input) = .empty;
        defer inputs.deinit(gpa);
        const live = try gpa.alloc(u64, ticks);
        defer gpa.free(live);
        var meshes = try record(order, &inputs, live);
        defer meshes.deinit(core.tasks.immediate);
        ticks_adopted[i] = inputs.items[0].tick;
        // Forced to one tick, whichever executor made the mesh.
        try play(&meshes, &.{.{ .tick = 200, .generation = 2 }}, ticks, hashes[i]);
    }
    defer for (hashes) |h| gpa.free(h);
    try testing.expectEqualSlices(u64, hashes[0], hashes[1]);
    try testing.expectEqualSlices(u64, hashes[0], hashes[2]);
    // They really did arrive at different times.
    try testing.expect(ticks_adopted[0] < ticks_adopted[1] and ticks_adopted[1] < ticks_adopted[2]);

    var inputs: std.ArrayList(Input) = .empty;
    defer inputs.deinit(gpa);
    const live = try gpa.alloc(u64, ticks);
    defer gpa.free(live);
    var meshes = try record(.immediate, &inputs, live);
    defer meshes.deinit(core.tasks.immediate);
    const later = try gpa.alloc(u64, ticks);
    defer gpa.free(later);
    try play(&meshes, &.{.{ .tick = 230, .generation = 2 }}, ticks, later);
    try testing.expect(later[ticks - 1] != hashes[0][ticks - 1]);
}

test "agents re-route round a box adopted into the running mesh" {
    var scene: scenes.Scene = .{};
    level(&scene);
    var box: meshes_mod.BoxGeometry = undefined;
    var sources: [2]Source = undefined;
    var first = try poly.build(gpa, walker, withBox(&scene, &box, .zero, null, &sources));
    defer first.deinit(gpa);
    var cut = try poly.build(gpa, walker, withBox(&scene, &box, .init(4, 1, 0.2), .init(5, 1, 6), &sources));
    defer cut.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&first);
    const a = try crowd.add(params, .init(5, 0, 2));
    _ = crowd.setTarget(a, .init(5, 0, 10));
    for (0..30) |_| crowd.step(dt);
    crowd.setMesh(&cut);
    var round = false;
    for (0..900) |_| {
        crowd.step(dt);
        const v = crowd.agent(a).?;
        if (v.position.x > 8.5 or v.position.x < 1.5) round = true;
        if (v.state == .arrived) break;
    }
    try testing.expect(round);
    try testing.expectEqual(crowd_mod.AgentState.arrived, crowd.agent(a).?.state);
}

test "a new mesh drops every corridor: a rebuild renumbers polygons" {
    // From a big mesh to a smaller one, so an old polygon number is past the new mesh's end.
    var big: scenes.Scene = .{};
    big.yard();
    var first = try poly.build(gpa, walker, big.sources());
    defer first.deinit(gpa);
    var small: scenes.Scene = .{};
    small.floor(.init(0, 0, 0), .init(30, 0, 20), false);
    var second = try poly.build(gpa, walker, small.sources());
    defer second.deinit(gpa);
    try testing.expect(second.polygons.len < first.polygons.len / 4);

    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&first);
    const a = try crowd.add(params, .init(2, 0, 2));
    _ = crowd.setTarget(a, .init(27, 0, 18));
    for (0..60) |_| crowd.step(dt);
    try testing.expectEqual(@as(u64, 1), crowd.searches_total);
    crowd.setMesh(&second);
    crowd.step(dt);
    try testing.expectEqual(@as(u64, 2), crowd.searches_total);
    for (0..1200) |_| {
        crowd.step(dt);
        if (crowd.agent(a).?.state == .arrived) break;
    }
    try testing.expectEqual(crowd_mod.AgentState.arrived, crowd.agent(a).?.state);
    try testing.expect(crowd.agent(a).?.position.sub(.init(27, 0, 18)).length() < 0.4);
}
