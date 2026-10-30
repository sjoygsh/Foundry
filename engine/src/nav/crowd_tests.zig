//! Agents without avoidance (`agents.md` §6, §13, Step 4): arriving, the three crossings, bodies
//! that stop short, a moving target, a rebuilt mesh, and everything refused.

const std = @import("std");
const core = @import("core");

const config_mod = @import("config.zig");
const crossing = @import("crossing.zig");
const crowd_mod = @import("crowd.zig");
const features = @import("features.zig");
const poly = @import("poly.zig");
const scenes = @import("scenes.zig");
const surface = @import("surface.zig");

const testing = std.testing;
const gpa = testing.allocator;
const AgentHandle = crowd_mod.AgentHandle;
const Crowd = crowd_mod.Crowd;
const Features = features.Features;
const Mesh = poly.Mesh;
const Vec3 = core.math.Vec3;
const walker = config_mod.walker;
const dt: f32 = 1.0 / 60.0;

const params: crowd_mod.AgentParams = .{ .radius = 0.3, .height = 1.8, .speed = 2, .acceleration = 8 };

fn built(scene: *scenes.Scene, f: Features) !Mesh {
    return poly.buildWith(gpa, walker, scene.sources(), f);
}

/// A crowd on `mesh`, stepped until `handle` has arrived or `ticks` run out, checking each tick
/// that it is on the mesh and within its speed. Answers the ticks taken.
fn walkTo(crowd: *Crowd, mesh: *const Mesh, handle: AgentHandle, target: Vec3, ticks: u32) !u32 {
    try testing.expect(crowd.setTarget(handle, target));
    for (0..ticks) |t| {
        crowd.step(dt);
        const v = crowd.agent(handle).?;
        if (v.state == .arrived) return @intCast(t + 1);
        if (v.state != .on_link) {
            try testing.expect(v.polygon < mesh.polygons.len);
            try testing.expect(surface.contains(mesh, v.polygon, v.position));
            try testing.expect(crowd.wish(handle).?.displacement.length() <= params.speed * dt * 2);
        }
    }
    return error.NeverArrived;
}

test "an agent walks across a floor, and arrives within its radius" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const a = try crowd.add(params, .init(2, 0, 2));
    try testing.expectEqual(crowd_mod.AgentState.idle, crowd.agent(a).?.state);
    const target: Vec3 = .init(8, 0, 7);
    const ticks = try walkTo(&crowd, &m, a, target, 600);
    const v = crowd.agent(a).?;
    try testing.expect(v.complete);
    try testing.expect(v.position.sub(target).length() <= params.arrival_radius + 0.05);
    // 7.8 m at 2 m/s is 3.9 s, and a little to start and stop.
    try testing.expect(ticks >= 200 and ticks <= 280);
    try testing.expectEqual(Vec3.zero, crowd.wish(a).?.displacement);
}

test "an agent goes up the steps and over the ramp, following the floor's height" {
    var scene: scenes.Scene = .{};
    scene.course();
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const a = try crowd.add(params, .init(0.8, 0, 2.5));
    _ = try walkTo(&crowd, &m, a, .init(2.7, 0.6, 2.5), 900);
    try testing.expectApproxEqAbs(@as(f32, 0.6), crowd.agent(a).?.position.y, 0.1);
    _ = try walkTo(&crowd, &m, a, .init(4.5, 0, 0.8), 900);
    try testing.expectApproxEqAbs(@as(f32, 0), crowd.agent(a).?.position.y, 0.1);
}

test "a jump arcs, a drop falls, and a ladder climbs, each to the link's far end" {
    const Case = struct { kind: features.LinkKind, from: Vec3, to: Vec3 };
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(5, 0, 5), false);
    scene.floor(.init(7, 1, 0), .init(12, 1, 5), false);
    const cases = [_]Case{
        .{ .kind = .jump, .from = .init(4.5, 0, 2.5), .to = .init(7.5, 1, 2.5) },
        .{ .kind = .ladder, .from = .init(4.5, 0, 2.5), .to = .init(7.5, 1, 2.5) },
        .{ .kind = .drop, .from = .init(7.5, 1, 2.5), .to = .init(4.5, 0, 2.5) },
    };
    for (cases) |case| {
        var m = try built(&scene, .{ .links = &.{.{ .kind = case.kind, .from = case.from, .to = case.to, .snap = 1, .arc = 0.5 }} });
        defer m.deinit(gpa);
        var crowd = try Crowd.init(gpa, .{});
        defer crowd.deinit();
        crowd.setMesh(&m);
        const start: Vec3 = if (case.kind == .drop) .init(10, 1, 2.5) else .init(2, 0, 2.5);
        const goal: Vec3 = if (case.kind == .drop) .init(2, 0, 2.5) else .init(10, 1, 2.5);
        const a = try crowd.add(params, start);
        try testing.expect(crowd.setTarget(a, goal));
        var top = -std.math.inf(f32);
        var seen_link = false;
        var x_at_mid: f32 = 0;
        var arrived = false;
        for (0..1200) |_| {
            crowd.step(dt);
            const v = crowd.agent(a).?;
            if (v.state == .on_link) {
                seen_link = true;
                try testing.expect(crowd.wish(a).?.on_link);
                top = @max(top, v.position.y);
                if (v.link_t < 0.5) x_at_mid = v.position.x;
            }
            if (v.state == .arrived) {
                arrived = true;
                break;
            }
        }
        try testing.expect(seen_link and arrived);
        try testing.expect(crowd.agent(a).?.position.sub(goal).length() < 0.35);
        switch (case.kind) {
            .jump => try testing.expectApproxEqAbs(@as(f32, 1.5), top, 0.05),
            // Up first, over the lower end.
            .ladder => try testing.expect(x_at_mid < 5),
            .drop => try testing.expect(top <= 1.05),
        }
    }
}

test "a crossing's curve starts and ends at its ends, and is continuous" {
    const a: Vec3 = .init(0, 0, 0);
    const b: Vec3 = .init(3, 1.5, 1);
    const cases = [_]struct { from: Vec3, to: Vec3 }{ .{ .from = a, .to = b }, .{ .from = b, .to = a } };
    for (cases) |case| {
        for ([_]features.LinkKind{ .jump, .drop, .ladder }) |kind| {
            for ([_]f32{ 0, 0.5, 2 }) |arc| {
                try testing.expect(crossing.at(kind, case.from, case.to, arc, 2, 0).sub(case.from).length() < 1e-4);
                try testing.expect(crossing.at(kind, case.from, case.to, arc, 2, 1).sub(case.to).length() < 1e-4);
                var last = case.from;
                for (1..201) |i| {
                    const p = crossing.at(kind, case.from, case.to, arc, 2, @as(f32, @floatFromInt(i)) / 200);
                    try testing.expect(p.sub(last).length() < 0.3);
                    last = p;
                }
            }
            try testing.expect(crossing.duration(kind, case.from, case.to, 2) > 0);
        }
    }
}

test "a body the controller stops short stays on its corridor and gets there" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 12), false);
    scene.box(.init(5, 0, 0), .init(6, 2, 9));
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const a = try crowd.add(params, .init(2, 0, 3));
    try testing.expect(crowd.setTarget(a, .init(10, 0, 3)));
    var feet: Vec3 = .init(2, 0, 3);
    var arrived = false;
    for (0..2400) |_| {
        crowd.step(dt);
        const v = crowd.agent(a).?;
        if (v.state == .arrived) {
            arrived = true;
            break;
        }
        // A body that goes half as far as it was asked.
        feet = feet.add(crowd.wish(a).?.displacement.scale(0.5));
        crowd.place(a, feet);
        try testing.expect(crowd.agent(a).?.state != .off_mesh);
    }
    try testing.expect(arrived);
    // One search: being short never lost the corridor.
    try testing.expectEqual(@as(u64, 1), crowd.searches_total);
}

test "a body that does not move is blocked, and keeps trying" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{ .blocked_ticks = 30 });
    defer crowd.deinit();
    crowd.setMesh(&m);
    const start: Vec3 = .init(2, 0, 2);
    const a = try crowd.add(params, start);
    try testing.expect(crowd.setTarget(a, .init(8, 0, 2)));
    for (0..29) |_| {
        crowd.step(dt);
        crowd.place(a, start);
    }
    try testing.expectEqual(crowd_mod.AgentState.walking, crowd.agent(a).?.state);
    for (0..3) |_| {
        crowd.step(dt);
        crowd.place(a, start);
    }
    try testing.expectEqual(crowd_mod.AgentState.blocked, crowd.agent(a).?.state);
    try testing.expect(crowd.wish(a).?.displacement.length() > 0);
    // Freed, it walks on.
    for (0..10) |_| crowd.step(dt);
    try testing.expectEqual(crowd_mod.AgentState.walking, crowd.agent(a).?.state);
}

test "feet off the mesh ask for nothing, until a floor is found" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    const before = try crowd.add(params, .init(2, 0, 2));
    try testing.expectEqual(crowd_mod.AgentState.off_mesh, crowd.agent(before).?.state);
    crowd.setMesh(&m);
    try testing.expectEqual(crowd_mod.AgentState.idle, crowd.agent(before).?.state);
    try testing.expect(crowd.setTarget(before, .init(8, 0, 8)));
    crowd.step(dt);
    crowd.place(before, .init(5, -9, 5));
    try testing.expectEqual(crowd_mod.AgentState.off_mesh, crowd.agent(before).?.state);
    try testing.expectEqual(poly.none_polygon, crowd.agent(before).?.polygon);
    crowd.step(dt);
    try testing.expectEqual(Vec3.zero, crowd.wish(before).?.displacement);
    crowd.place(before, .init(5, 0, 5));
    try testing.expectEqual(crowd_mod.AgentState.walking, crowd.agent(before).?.state);
    _ = try walkTo(&crowd, &m, before, .init(8, 0, 8), 600);
}

test "a target out of reach is walked to its nearest place, and says so" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(5, 0, 5), false);
    scene.floor(.init(7, 0, 0), .init(12, 0, 5), false);
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const a = try crowd.add(params, .init(1, 0, 2.5));
    _ = try walkTo(&crowd, &m, a, .init(10, 0, 2.5), 900);
    const v = crowd.agent(a).?;
    try testing.expect(!v.complete);
    try testing.expect(v.position.x > 4.3 and v.position.x < 5);
}

test "a moving target costs a search each `replan_ticks` at most, and is caught" {
    var scene: scenes.Scene = .{};
    scene.yard();
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    var p = params;
    p.speed = 3;
    p.replan_ticks = 15;
    const a = try crowd.add(p, .init(2, 0, 2));
    var target: Vec3 = .init(25, 0, 3);
    for (0..1200) |_| {
        target.x -= 1.0 * dt;
        try testing.expect(crowd.setTarget(a, target));
        crowd.step(dt);
        try testing.expect(crowd.searches_last_step <= 1);
        if (crowd.agent(a).?.state == .arrived) break;
    }
    try testing.expectEqual(crowd_mod.AgentState.arrived, crowd.agent(a).?.state);
    try testing.expect(crowd.searches_total <= 1200 / 15 + 1);
}

test "a target that jumps about still costs one search each `replan_ticks`" {
    var scene: scenes.Scene = .{};
    scene.yard();
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    var p = params;
    p.replan_ticks = 15;
    const a = try crowd.add(p, .init(10, 0, 2));
    for (0..300) |t| {
        const far: Vec3 = if (t % 2 == 0) .init(3, 0, 18) else .init(27, 0, 2);
        try testing.expect(crowd.setTarget(a, far));
        crowd.step(dt);
    }
    try testing.expect(crowd.searches_total >= 300 / 15 - 1 and crowd.searches_total <= 300 / 15 + 1);
}

test "a target that drifts into the next polygon extends the corridor, with no search" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    try testing.expect(m.polygons.len >= 2);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    const a = try crowd.add(params, .init(1, 0, 1));
    // From the corner polygon, into the one beside it, by small moves.
    var target: Vec3 = .init(1.5, 0, 1.5);
    var polygons_seen: u32 = 0;
    var last_polygon: u32 = poly.none_polygon;
    for (0..240) |_| {
        target = target.add(.init(0.03, 0, 0.03));
        try testing.expect(crowd.setTarget(a, target));
        crowd.step(dt);
        const here = m.locate(target, .init(0.1, 1, 0.1)).?.polygon;
        if (here != last_polygon) polygons_seen += 1;
        last_polygon = here;
    }
    try testing.expect(polygons_seen >= 2);
    try testing.expectEqual(@as(u64, 1), crowd.searches_total);
}

test "speed changes by at most the acceleration, and never passes the speed" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    var p = params;
    p.acceleration = 3;
    const a = try crowd.add(p, .init(1, 0, 5));
    try testing.expect(crowd.setTarget(a, .init(9, 0, 5)));
    var last: Vec3 = .zero;
    for (0..400) |_| {
        crowd.step(dt);
        const v = crowd.agent(a).?;
        if (v.state == .arrived) break;
        try testing.expect(v.velocity.sub(last).length() <= p.acceleration * dt + 1e-4);
        try testing.expect(v.velocity.length() <= p.speed + 1e-4);
        last = v.velocity;
    }
}

test "a move into a wall slides along it, and a long move crosses polygons" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    const start = m.locate(.init(2, 0, 2), .init(0.1, 1, 0.1)).?;
    // Past the −X edge at 0.4, at a slant: it stops at the edge, and keeps its way along it.
    const slid = surface.move(&m, start.polygon, start.point, .init(-3, 0, 4));
    try testing.expect(slid.slid);
    try testing.expectApproxEqAbs(@as(f32, 0.4), slid.point.x, 0.01);
    try testing.expect(slid.point.z > 3.5 and slid.point.z < 4.5);
    try testing.expect(surface.contains(&m, slid.polygon, slid.point));
    // Into the far corner, past two walls.
    const corner = surface.move(&m, start.polygon, start.point, .init(20, 0, 20));
    try testing.expect(corner.point.x <= 9.61 and corner.point.z <= 9.61);
    try testing.expect(surface.contains(&m, corner.polygon, corner.point));
    // Clear across, and exactly there.
    const across = surface.move(&m, start.polygon, start.point, .init(8, 0, 7));
    try testing.expect(!across.slid);
    try testing.expect(across.polygon != start.polygon);
    try testing.expectEqual(@as(f32, 8), across.point.x);
}

test "a rebuilt mesh re-paths every agent, within the search budget, and a crossing finishes first" {
    var a_scene: scenes.Scene = .{};
    a_scene.floor(.init(0, 0, 0), .init(5, 0, 30), false);
    a_scene.floor(.init(7, 0, 0), .init(12, 0, 30), false);
    const across: features.LinkInput = .{ .kind = .jump, .from = .init(4.5, 0, 2.5), .to = .init(7.5, 0, 2.5), .snap = 1 };
    var first = try built(&a_scene, .{ .links = &.{across} });
    defer first.deinit(gpa);
    var b_scene: scenes.Scene = .{};
    b_scene.floor(.init(0, 0, 0), .init(5, 0, 30), false);
    b_scene.floor(.init(7, 0, 0), .init(12, 0, 30), false);
    b_scene.box(.init(2.2, 0, 10), .init(2.8, 2, 11));
    var second = try built(&b_scene, .{ .links = &.{across} });
    defer second.deinit(gpa);

    var crowd = try Crowd.init(gpa, .{ .max_searches_per_step = 8 });
    defer crowd.deinit();
    crowd.setMesh(&first);
    var agents: [32]AgentHandle = undefined;
    for (&agents, 0..) |*h, i| {
        // Apart, and each with a place of its own: two agents cannot both stand on one point.
        const x = 0.8 + @as(f32, @floatFromInt(i % 5)) * 0.7;
        const z = 4 + @as(f32, @floatFromInt(i / 5)) * 0.7;
        h.* = try crowd.add(params, .init(x, 0, z));
        try testing.expect(crowd.setTarget(h.*, .init(x, 0, z + 20)));
    }
    const jumper = try crowd.add(params, .init(4.3, 0, 2));
    try testing.expect(crowd.setTarget(jumper, .init(10, 0, 2.5)));
    var ticks: u32 = 0;
    while (crowd.agent(jumper).?.state != .on_link) : (ticks += 1) {
        try testing.expect(ticks < 200);
        crowd.step(dt);
    }
    crowd.setMesh(&second);
    var most: u32 = 0;
    for (0..12) |_| {
        crowd.step(dt);
        most = @max(most, crowd.searches_last_step);
    }
    try testing.expectEqual(@as(u32, 8), most);
    var left: u32 = 0;
    for (0..2400) |_| {
        crowd.step(dt);
        // Past the new box. Not all at their places: those that stop first stand 0.7 m apart, which
        // those behind them, 0.6 m wide, cannot pass.
        left = 0;
        for (agents) |h| left += @intFromBool(crowd.agent(h).?.position.z < 11.5);
        if (left == 0) break;
    }
    try testing.expectEqual(@as(u32, 0), left);
    try testing.expect(crowd.agent(jumper).?.position.x > 7);
}

test "a stale handle, a full crowd and bad numbers are refused" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{ .max_agents = 2 });
    defer crowd.deinit();
    crowd.setMesh(&m);
    const nan = std.math.nan(f32);
    const a = try crowd.add(params, .init(2, 0, 2));
    const b = try crowd.add(params, .init(3, 0, 3));
    try testing.expectError(error.Full, crowd.add(params, .init(4, 0, 4)));
    try testing.expect(!crowd.setTarget(a, .init(nan, 0, 0)));
    crowd.place(a, .init(nan, 0, 0));
    try testing.expect(crowd.agent(a).?.position.isFinite());
    try testing.expect(crowd.remove(a));
    try testing.expect(!crowd.remove(a));
    try testing.expect(crowd.agent(a) == null and crowd.wish(a) == null);
    try testing.expect(!crowd.setTarget(a, .init(1, 0, 1)));
    try testing.expect(!crowd.setTarget(.none, .init(1, 0, 1)));
    try testing.expect(!crowd.setTarget(.{ .index = 99, .generation = 1 }, .init(1, 0, 1)));
    crowd.place(a, .init(1, 0, 1));
    const c = try crowd.add(params, .init(2, 0, 2));
    try testing.expectEqual(a.index, c.index);
    try testing.expect(!c.eql(a));
    try testing.expect(crowd.agent(a) == null and crowd.agent(c) != null and crowd.agent(b) != null);

    for ([_]crowd_mod.AgentParams{
        .{ .radius = 0, .height = 1, .speed = 1, .acceleration = 1 },
        .{ .radius = 0.3, .height = nan, .speed = 1, .acceleration = 1 },
        .{ .radius = 0.3, .height = 1, .speed = 0, .acceleration = 1 },
        .{ .radius = 0.3, .height = 1, .speed = 1, .acceleration = -1 },
        .{ .radius = 0.3, .height = 1, .speed = 1, .acceleration = 1, .arrival_radius = 0 },
        .{ .radius = 0.3, .height = 1, .speed = 1, .acceleration = 1, .replan_ticks = 0 },
        .{ .radius = 0.3, .height = 1, .speed = 1, .acceleration = 1, .target_extent = .init(nan, 1, 1) },
    }) |bad| {
        _ = crowd.remove(c);
        try testing.expectError(error.InvalidAgent, crowd.add(bad, .init(1, 0, 1)));
    }
    try testing.expectError(error.InvalidPose, crowd.add(params, .init(nan, 0, 0)));
    try testing.expectError(error.InvalidOptions, Crowd.init(gpa, .{ .max_agents = 0 }));
    try testing.expectError(error.InvalidOptions, Crowd.init(gpa, .{ .max_agents = 257 }));
    try testing.expectError(error.InvalidOptions, Crowd.init(gpa, .{ .max_searches_per_step = 0 }));
    const before = crowd.hash();
    crowd.step(nan);
    crowd.step(0);
    crowd.step(-1);
    try testing.expectEqual(before, crowd.hash());
}

test "a crowd survives every allocation failure at init" {
    const S = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var crowd = try Crowd.init(allocator, .{ .max_agents = 4, .max_nodes = 32 });
            crowd.deinit();
        }
    };
    try testing.checkAllAllocationFailures(gpa, S.run, .{});
}

/// A run with a body, two targets and a removal, as its hash.
fn scriptedRun(m: *const Mesh) !u64 {
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(m);
    const a = try crowd.add(params, .init(2, 0, 2));
    const b = try crowd.add(params, .init(25, 0, 2));
    _ = crowd.setTarget(a, .init(25, 0, 18));
    _ = crowd.setTarget(b, .init(3, 0, 18));
    for (0..600) |t| {
        crowd.step(dt);
        if (t == 300) _ = crowd.setTarget(a, .init(3, 0, 18));
        if (t == 400) _ = crowd.remove(b);
    }
    return crowd.hash();
}

test "the same inputs give the same crowd" {
    var scene: scenes.Scene = .{};
    scene.yard();
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    try testing.expectEqual(try scriptedRun(&m), try scriptedRun(&m));
}

test "a thousand seeded abuses neither panic nor hang, and agents stay finite" {
    var scene: scenes.Scene = .{};
    scene.course();
    var m = try built(&scene, .{ .links = &.{
        .{ .kind = .ladder, .from = .init(1, 0, 1), .to = .init(2.7, 0.6, 2.5), .two_way = true },
        .{ .kind = .drop, .from = .init(2.7, 0.6, 2.5), .to = .init(4.5, 0, 2.5) },
    } });
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{ .max_agents = 8, .max_nodes = 64 });
    defer crowd.deinit();
    crowd.setMesh(&m);
    var prng = std.Random.DefaultPrng.init(0x4444);
    const r = prng.random();
    var handles: [8]AgentHandle = @splat(.none);
    const special = [_]f32{ 0, -1, 1e6, std.math.nan(f32), std.math.inf(f32), 3 };
    for (0..1000) |_| {
        const h = handles[r.uintLessThan(usize, 8)];
        const point: Vec3 = .init(r.float(f32) * 7 - 0.5, r.float(f32) * 2 - 1, r.float(f32) * 7 - 0.5);
        const odd: Vec3 = .init(special[r.uintLessThan(usize, 6)], special[r.uintLessThan(usize, 6)], special[r.uintLessThan(usize, 6)]);
        switch (r.uintLessThan(u32, 8)) {
            0 => {
                const i = r.uintLessThan(usize, 8);
                if (handles[i].isNone()) handles[i] = crowd.add(params, point) catch .none;
            },
            1 => {
                const i = r.uintLessThan(usize, 8);
                _ = crowd.remove(handles[i]);
            },
            2 => _ = crowd.setTarget(h, point),
            3 => _ = crowd.setTarget(h, odd),
            4 => crowd.place(h, point),
            5 => crowd.place(h, odd),
            6 => _ = crowd.clearTarget(h),
            else => {},
        }
        for (0..3) |_| crowd.step(dt);
        for (handles) |live| {
            if (crowd.agent(live)) |v| try testing.expect(v.position.isFinite());
        }
    }
}
