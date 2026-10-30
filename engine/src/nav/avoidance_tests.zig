//! Agents keeping apart (`agents.md` §8, §13, Step 5): the scenes of criterion 3, the crowd's pin
//! and the budget.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const config_mod = @import("config.zig");
const crowd_mod = @import("crowd.zig");
const poly = @import("poly.zig");
const scenes = @import("scenes.zig");

const testing = std.testing;
const gpa = testing.allocator;
const AgentHandle = crowd_mod.AgentHandle;
const Crowd = crowd_mod.Crowd;
const Mesh = poly.Mesh;
const Vec3 = core.math.Vec3;
const walker = config_mod.walker;
const dt: f32 = 1.0 / 60.0;

/// The mesh is eroded by 0.3 m, and the agents are that wide.
const params: crowd_mod.AgentParams = .{ .radius = 0.3, .height = 1.8, .speed = 2, .acceleration = 20 };
const closest_allowed: f32 = 2 * 0.3 - 0.05;

fn built(scene: *scenes.Scene) !Mesh {
    return poly.build(gpa, walker, scene.sources());
}

/// Steps until every agent has arrived, asserting the separation bound on every tick, and answers
/// the closest any two came.
fn runAll(crowd: *Crowd, agents: []const AgentHandle, ticks: u32) !f32 {
    var closest = std.math.inf(f32);
    for (0..ticks) |_| {
        crowd.step(dt);
        var left: u32 = 0;
        for (agents, 0..) |a, i| {
            const va = crowd.agent(a).?;
            if (va.state != .arrived) left += 1;
            for (agents[i + 1 ..]) |b| {
                const d = va.position.sub(crowd.agent(b).?.position);
                closest = @min(closest, @sqrt(d.x * d.x + d.z * d.z));
            }
        }
        if (left == 0) return closest;
    }
    return error.NotAllArrived;
}

fn open(size: f32) scenes.Scene {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(size, 0, size), false);
    return scene;
}

test "two agents crossing at right angles keep apart and both arrive" {
    var scene = open(12);
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const a = try crowd.add(params, .init(2, 0, 6));
    const b = try crowd.add(params, .init(6, 0, 2));
    _ = crowd.setTarget(a, .init(10, 0, 6));
    _ = crowd.setTarget(b, .init(6, 0, 10));
    try testing.expect(try runAll(&crowd, &.{ a, b }, 900) >= closest_allowed);
}

test "two agents exactly head-on pass, each to its own side" {
    var scene = open(12);
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const a = try crowd.add(params, .init(2, 0, 6));
    const b = try crowd.add(params, .init(10, 0, 6));
    _ = crowd.setTarget(a, .init(10, 0, 6.5));
    _ = crowd.setTarget(b, .init(2, 0, 5.5));
    try testing.expect(try runAll(&crowd, &.{ a, b }, 900) >= closest_allowed);
}

test "a ring of 32 agents, each to the far side, keeps apart and arrives" {
    var scene = open(20);
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    var agents: [32]AgentHandle = undefined;
    addRing(&crowd, &agents, .init(10, 0, 10), 8.5);
    const closest = try runAll(&crowd, &agents, 3000);
    try testing.expect(closest >= closest_allowed);
}

fn addRing(crowd: *Crowd, agents: []AgentHandle, centre: Vec3, radius: f32) void {
    for (agents, 0..) |*h, i| {
        const sc = core.math.trig.sinCosTurns(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(agents.len)));
        const offset: Vec3 = .init(@as(f32, @floatCast(sc[1])) * radius, 0, @as(f32, @floatCast(sc[0])) * radius);
        h.* = crowd.add(params, centre.add(offset)) catch unreachable;
        _ = crowd.setTarget(h.*, centre.sub(offset));
    }
}

test "a passage wide enough for two is passed both ways" {
    var scene = open(12);
    // A wall across the room with a gap 2 m wide: 1.4 m of mesh, and two agents need 1.2.
    scene.box(.init(0, 0, 5.8), .init(5, 2, 6.2));
    scene.box(.init(7, 0, 5.8), .init(12, 2, 6.2));
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    var agents: [6]AgentHandle = undefined;
    for (agents[0..3], 0..) |*h, i| {
        const x = 4.5 + 1.5 * @as(f32, @floatFromInt(i));
        h.* = try crowd.add(params, .init(x, 0, 2));
        _ = crowd.setTarget(h.*, .init(x, 0, 10));
    }
    for (agents[3..], 0..) |*h, i| {
        const x = 5 + 1 * @as(f32, @floatFromInt(i));
        h.* = try crowd.add(params, .init(x, 0, 10.5));
        _ = crowd.setTarget(h.*, .init(x, 0, 1));
    }
    try testing.expect(try runAll(&crowd, &agents, 2400) >= closest_allowed);
}

test "a passage one wide reports blocked, and nothing breaks" {
    var scene = open(12);
    scene.box(.init(0, 0, 5.8), .init(5.5, 2, 6.2));
    scene.box(.init(6.5, 0, 5.8), .init(12, 2, 6.2));
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{ .blocked_ticks = 30 });
    defer crowd.deinit();
    crowd.setMesh(&m);
    const a = try crowd.add(params, .init(6, 0, 4));
    const b = try crowd.add(params, .init(6, 0, 8));
    _ = crowd.setTarget(a, .init(6, 0, 10));
    _ = crowd.setTarget(b, .init(6, 0, 2));
    var saw_blocked = false;
    for (0..900) |_| {
        crowd.step(dt);
        for ([_]AgentHandle{ a, b }) |h| {
            const v = crowd.agent(h).?;
            try testing.expect(v.position.isFinite() and v.velocity.isFinite());
            if (v.state == .blocked) saw_blocked = true;
        }
    }
    try testing.expect(saw_blocked);
}

test "a crowd flows round one standing still, who is not moved" {
    var scene = open(12);
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const standing = try crowd.add(params, .init(6, 0, 6));
    const a = try crowd.add(params, .init(2, 0, 6));
    _ = crowd.setTarget(a, .init(10, 0, 6));
    var closest = std.math.inf(f32);
    for (0..600) |_| {
        crowd.step(dt);
        const d = crowd.agent(a).?.position.sub(crowd.agent(standing).?.position);
        closest = @min(closest, @sqrt(d.x * d.x + d.z * d.z));
        if (crowd.agent(a).?.state == .arrived) break;
    }
    try testing.expectEqual(crowd_mod.AgentState.arrived, crowd.agent(a).?.state);
    try testing.expect(closest >= closest_allowed);
    try testing.expectEqual(Vec3.init(6, 0, 6).x, crowd.agent(standing).?.position.x);
}

test "many agents sent to one point: one arrives, and the rest stand off" {
    var scene = open(12);
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    var agents: [6]AgentHandle = undefined;
    for (&agents, 0..) |*h, i| {
        h.* = try crowd.add(params, .init(2 + @as(f32, @floatFromInt(i)) * 1.5, 0, 2));
        _ = crowd.setTarget(h.*, .init(6, 0, 9));
    }
    for (0..900) |_| crowd.step(dt);
    var arrived: u32 = 0;
    for (agents, 0..) |a, i| {
        const v = crowd.agent(a).?;
        arrived += @intFromBool(v.state == .arrived);
        for (agents[i + 1 ..]) |b| {
            const d = v.position.sub(crowd.agent(b).?.position);
            try testing.expect(@sqrt(d.x * d.x + d.z * d.z) >= closest_allowed);
        }
    }
    try testing.expect(arrived >= 1);
}

test "two agents at one point come apart" {
    var scene = open(12);
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const a = try crowd.add(params, .init(6, 0, 6));
    const b = try crowd.add(params, .init(6, 0, 6));
    _ = crowd.setTarget(a, .init(2, 0, 6));
    _ = crowd.setTarget(b, .init(2.5, 0, 6));
    for (0..120) |_| crowd.step(dt);
    const d = crowd.agent(a).?.position.sub(crowd.agent(b).?.position);
    try testing.expect(@sqrt(d.x * d.x + d.z * d.z) >= closest_allowed);
}

test "agents on different floors do not avoid each other" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 12), false);
    scene.floor(.init(0, 2.5, 0), .init(12, 2.5, 12), false);
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const below = try crowd.add(params, .init(2, 0, 6));
    const above = try crowd.add(params, .init(10, 2.5, 6));
    _ = crowd.setTarget(below, .init(10, 0, 6));
    _ = crowd.setTarget(above, .init(2, 2.5, 6));
    for (0..600) |_| {
        crowd.step(dt);
        try testing.expectApproxEqAbs(@as(f32, 6), crowd.agent(below).?.position.z, 0.01);
    }
}

test "the result does not depend on which slot an agent is in" {
    var scene = open(12);
    var m = try built(&scene);
    defer m.deinit(gpa);
    const starts = [_]Vec3{ .init(2, 0, 3), .init(10, 0, 4), .init(5, 0, 9.5), .init(7, 0, 1.5), .init(1.5, 0, 8) };
    const goals = [_]Vec3{ .init(10, 0, 8), .init(2, 0, 7), .init(6, 0, 1), .init(5, 0, 10), .init(10, 0, 2) };
    var forward = try Crowd.init(gpa, .{});
    defer forward.deinit();
    var backward = try Crowd.init(gpa, .{});
    defer backward.deinit();
    forward.setMesh(&m);
    backward.setMesh(&m);
    var f: [5]AgentHandle = undefined;
    var b: [5]AgentHandle = undefined;
    for (0..5) |i| {
        f[i] = try forward.add(params, starts[i]);
        _ = forward.setTarget(f[i], goals[i]);
    }
    var i: usize = 5;
    while (i > 0) {
        i -= 1;
        b[i] = try backward.add(params, starts[i]);
        _ = backward.setTarget(b[i], goals[i]);
    }
    for (0..300) |_| {
        forward.step(dt);
        backward.step(dt);
        for (f, b) |x, y| try testing.expectEqual(forward.agent(x).?.position, backward.agent(y).?.position);
    }
}

fn ringOnCourse(m: *const Mesh) !u64 {
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(m);
    var added: [16]AgentHandle = undefined;
    var count: usize = 0;
    for (0..16) |i| {
        const sc = core.math.trig.sinCosTurns(@as(f64, @floatFromInt(i)) / 16);
        const offset: Vec3 = .init(@as(f32, @floatCast(sc[1])) * 2.4, 0, @as(f32, @floatCast(sc[0])) * 2.4);
        const centre: Vec3 = .init(3, 0, 3);
        const at = centre.add(offset);
        if (m.locate(at, .init(0.1, 0.2, 0.1)) == null) continue;
        added[count] = try crowd.add(params, at);
        _ = crowd.setTarget(added[count], centre.sub(offset));
        count += 1;
    }
    try testing.expect(count >= 8);
    for (0..600) |_| crowd.step(dt);
    return crowd.hash();
}

test "the ring on the course is the same every time, and pinned" {
    var scene: scenes.Scene = .{};
    scene.course();
    var m = try built(&scene);
    defer m.deinit(gpa);
    const first = try ringOnCourse(&m);
    try testing.expectEqual(first, try ringOnCourse(&m));
    // Recorded at M33 Step 5, equal in Debug, ReleaseSafe and x86_64 under Rosetta.
    try testing.expectEqual(@as(u64, 9298260793551547065), first);
}

test "crowd step time: 32 agents in a ring, single-threaded, printed" {
    if (builtin.mode == .Debug) return error.SkipZigTest;
    var scene = open(20);
    var m = try built(&scene);
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    var agents: [32]AgentHandle = undefined;
    addRing(&crowd, &agents, .init(10, 0, 10), 8.5);
    // Only ticks with most of the crowd still walking, so idle ticks do not flatter the figure.
    var times: [900]u64 = undefined;
    var timed: usize = 0;
    var keep: u64 = 0;
    var crowded_lines: u32 = 0;
    while (timed < times.len and crowd.tick < 2000) {
        const start = std.Io.Clock.awake.now(testing.io);
        crowd.step(dt);
        const ns: u64 = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
        var walking: u32 = 0;
        var nearest = std.math.inf(f32);
        for (agents) |a| {
            const v = crowd.agent(a).?;
            walking += @intFromBool(v.state == .walking or v.state == .blocked);
            keep +%= @as(u32, @bitCast(v.position.x));
            nearest = @min(nearest, v.position.sub(.init(10, 0, 10)).length());
        }
        if (nearest < 3) crowded_lines += 1;
        if (walking < 24) continue;
        times[timed] = ns;
        timed += 1;
    }
    try testing.expect(timed >= 200);
    const used = times[0..timed];
    std.mem.sort(u64, used, {}, std.sort.asc(u64));
    const p95 = used[timed * 95 / 100];
    std.debug.print("crowd step time ({t}): 32 agents over {d} walking ticks, {d} crowded, p95 {d:.3} ms, worst {d:.3} ms ({d})\n", .{
        builtin.mode, timed, crowded_lines, @as(f64, @floatFromInt(p95)) / 1e6, @as(f64, @floatFromInt(used[timed - 1])) / 1e6, keep,
    });
    try testing.expect(p95 < 1_000_000);
}
