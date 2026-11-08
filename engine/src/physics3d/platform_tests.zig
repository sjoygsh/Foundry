//! Moving platforms and pushing (`collision-extras.md` §7, §8, M37 Step 4).
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;
const t = std.testing;
const gpa = t.allocator;

const config: p.CharacterConfig = .{ .radius = 0.3, .height = 1.8, .max_slope = std.math.pi / 4.0, .step_height = 0.35, .snap_distance = 0.3, .max_move = 10 };
const fall = Vec3.init(0, -0.01, 0);

fn box(w: *p.World, centre: Vec3, half: Vec3, kind: p.BodyKind, push: f32) !p.BodyHandle {
    return w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = half } }, .pose = .at(centre), .kind = kind, .push = push });
}

fn floor(w: *p.World) !p.BodyHandle {
    return box(w, .init(0, -0.5, 0), .init(20, 0.5, 20), .static, 0);
}

fn step(w: *p.World, c: p.CharacterHandle, by: Vec3) !p.CharacterMove {
    var hits: [8]p.Hit = undefined;
    return (try w.moveCharacter(gpa, c, by, &hits)).?;
}

fn feetOf(w: *p.World, c: p.CharacterHandle) Vec3 {
    return w.body(w.character(c).?.body).?.pose.position.sub(.init(0, config.height * 0.5, 0));
}

fn moveBy(w: *p.World, b: p.BodyHandle, by: Vec3) !p.BodyMove {
    var crushed: [4]p.CharacterHandle = undefined;
    return (try w.moveBody(gpa, b, w.body(b).?.pose.translated(by), &crushed)).?;
}

test "platforms: a character on a lift is carried up and down with it" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const lift = try box(&w, .init(0, 0.1, 0), .init(1, 0.1, 1), .kinematic, 0);
    // Settled from above, at the controller's resting gap.
    const c = try w.addCharacter(gpa, config, .init(0, 0.25, 0), 0);
    for (0..8) |_| _ = try step(&w, c, fall);
    try t.expect(w.character(c).?.ground.?.body.eql(lift));
    const gap = feetOf(&w, c).y - 0.2;
    for (0..80) |i| {
        const rise: f32 = if (i < 40) 0.05 else -0.05;
        _ = try moveBy(&w, lift, .init(0, rise, 0));
        const m = try step(&w, c, fall);
        try t.expect(m.grounded and m.ground.?.body.eql(lift));
        try t.expectApproxEqAbs(rise, m.carried.y, 1e-5);
        const top = w.body(lift).?.pose.position.y + 0.1;
        try t.expectApproxEqAbs(gap, feetOf(&w, c).y - top, 1e-5);
        // A second move in the tick is owed nothing: the serial is spent.
        try t.expect((try step(&w, c, fall)).carried.eql(.zero));
    }
}

test "platforms: a tilting platform does not tilt its rider, and turns it by none" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const deck = try box(&w, .init(0, 0.1, 0), .init(3, 0.1, 3), .kinematic, 0);
    const c = try w.addCharacter(gpa, config, .init(0, 0.25, 1), 0);
    for (0..8) |_| _ = try step(&w, c, fall);
    for (1..11) |i| {
        var crushed: [4]p.CharacterHandle = undefined;
        const tilt = Quat.fromAxisAngle(.init(1, 0, 0), 0.01 * @as(f32, @floatFromInt(i)));
        _ = (try w.moveBody(gpa, deck, .{ .position = .init(0, 0.1, 0), .rotation = tilt }, &crushed)).?;
        const m = try step(&w, c, fall);
        try t.expectEqual(@as(f32, 0), m.carried_yaw);
        // Only the translation, none here, and the turn about up are carried.
        try t.expect(m.carried.eql(.zero));
    }
    const capsule = w.body(w.character(c).?.body).?.pose.rotation;
    try t.expect(capsule.approxEql(.identity, 1e-6));
}

test "platforms: a turntable turns its rider, and reports the turn" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const table = try box(&w, .init(0, 0.1, 0), .init(3, 0.1, 3), .kinematic, 0);
    const c = try w.addCharacter(gpa, config, .init(2, 0.2, 0), 0);
    _ = try step(&w, c, fall);
    var yaw: f32 = 0;
    const ticks = 60;
    for (1..ticks + 1) |i| {
        const angle = std.math.pi / 2.0 * @as(f32, @floatFromInt(i)) / ticks;
        var crushed: [4]p.CharacterHandle = undefined;
        _ = (try w.moveBody(gpa, table, .{ .position = .init(0, 0.1, 0), .rotation = Quat.fromAxisAngle(.up, angle) }, &crushed)).?;
        const m = try step(&w, c, fall);
        try t.expect(m.grounded);
        yaw += m.carried_yaw;
    }
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), yaw, 1e-3);
    // A quarter turn counter-clockwise from above takes +x to −z.
    const f = feetOf(&w, c);
    try t.expectApproxEqAbs(@as(f32, 0), f.x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, -2), f.z, 1e-3);
}

test "platforms: a carry into a wall slides, and the platform goes on under it" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const deck = try box(&w, .init(0, 0.1, 0), .init(3, 0.1, 3), .kinematic, 0);
    // A wall standing over the deck's path, its face at x = 1.5, from 0.5 m up.
    _ = try box(&w, .init(2, 2, 0), .init(0.5, 1.5, 5), .static, 0);
    const c = try w.addCharacter(gpa, config, .init(0, 0.2, 0), 0);
    _ = try step(&w, c, fall);
    for (0..40) |_| {
        _ = try moveBy(&w, deck, .init(0.05, 0, 0.02));
        _ = try step(&w, c, fall);
    }
    const f = feetOf(&w, c);
    try t.expect(f.x <= 1.5 - 0.3 + 1e-3 and f.x > 1.1);
    // It slid along the wall with the deck's sideways part, which the wall does not stop.
    try t.expectApproxEqAbs(@as(f32, 0.8), f.z, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 2), w.body(deck).?.pose.position.x, 1e-5);
}

test "platforms: setPose carries nobody, and cancels a carry owed" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const lift = try box(&w, .init(0, 0.1, 0), .init(3, 0.1, 3), .kinematic, 0);
    const c = try w.addCharacter(gpa, config, .init(0, 0.2, 0), 0);
    _ = try step(&w, c, fall);
    _ = try moveBy(&w, lift, .init(0.5, 0, 0));
    try t.expect(try w.setPose(gpa, lift, .at(.init(1, 0.1, 0))));
    const m = try step(&w, c, fall);
    try t.expect(m.carried.eql(.zero));
    try t.expectApproxEqAbs(@as(f32, 0), m.feet.x, 1e-6);
}

test "platforms: a body moved into a character pushes it, and one pinned to a wall is crushed" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    const ram = try box(&w, .init(-1, 1, 0), .init(0.5, 1, 0.5), .kinematic, 0);
    const c = try w.addCharacter(gpa, config, .init(0, 0, 0), 0);
    _ = try step(&w, c, fall);
    // The ram's face is at x = −0.5, the capsule's side at −0.3: 0.4 into it.
    const pushed = try moveBy(&w, ram, .init(0.4, 0, 0));
    try t.expectEqual(@as(u32, 1), pushed.pushed);
    try t.expectEqual(@as(u32, 0), pushed.crushed.total);
    try t.expectApproxEqAbs(@as(f32, 0.4), feetOf(&w, c).x, 1e-4);

    // A wall at x = 0.8: the capsule can go 0.1 more, and the ram goes 0.3.
    _ = try box(&w, .init(1.3, 1, 0), .init(0.5, 1, 2), .static, 0);
    var crushed: [4]p.CharacterHandle = undefined;
    const pinned = (try w.moveBody(gpa, ram, w.body(ram).?.pose.translated(.init(0.3, 0, 0)), &crushed)).?;
    try t.expectEqual(@as(u32, 1), pinned.crushed.total);
    try t.expectEqual(@as(u32, 1), pinned.crushed.count);
    try t.expect(crushed[0].eql(c));
    // The move stands: what a crushed rider means is the game's.
    try t.expectApproxEqAbs(@as(f32, -0.3), w.body(ram).?.pose.position.x, 1e-6);
    try t.expect(feetOf(&w, c).x < 0.5 + 1e-3);
}

test "platforms: moveBody refuses a static body and a bad pose, and a stale one is null" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const wall = try floor(&w);
    const lift = try box(&w, .init(0, 1, 0), .init(1, 0.1, 1), .kinematic, 0);
    var crushed: [1]p.CharacterHandle = undefined;
    try t.expectError(error.NotKinematic, w.moveBody(gpa, wall, .identity, &crushed));
    try t.expectError(error.InvalidPose, w.moveBody(gpa, lift, .at(.init(std.math.nan(f32), 0, 0)), &crushed));
    try t.expect(w.removeBody(gpa, lift));
    try t.expect(try w.moveBody(gpa, lift, .identity, &crushed) == null);
}

test "pushing: a crate at ratio 0.5 moves half the pusher's displacement, and so does the pusher" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    const crate = try box(&w, .init(2, 0.501, 0), .init(0.5, 0.5, 0.5), .kinematic, 0.5);
    const c = try w.addCharacter(gpa, config, .init(1, 0, 0), 0);
    _ = try step(&w, c, fall);
    // Up to the crate's face, then on into it.
    _ = try step(&w, c, .init(0.3, -0.01, 0));
    for (0..5) |_| {
        const crate_before = w.body(crate).?.pose.position.x;
        const feet_before = feetOf(&w, c).x;
        const m = try step(&w, c, .init(0.4, -0.01, 0));
        try t.expect(m.pushed.?.body.eql(crate));
        try t.expectApproxEqAbs(@as(f32, 0.2), w.body(crate).?.pose.position.x - crate_before, 1e-3);
        try t.expectApproxEqAbs(@as(f32, 0.2), feetOf(&w, c).x - feet_before, 1e-3);
        try t.expectApproxEqAbs(@as(f32, 0.2), m.pushed.?.distance, 1e-3);
    }
}

test "pushing: a crate pushed into a second stops, and so does its pusher; one at ratio 0 is a wall" {
    for ([_]f32{ 1, 0 }) |ratio| {
        var w: p.World = .empty;
        defer w.deinit(gpa);
        _ = try floor(&w);
        const first = try box(&w, .init(2, 0.501, 0), .init(0.5, 0.5, 0.5), .kinematic, ratio);
        // The second is pushable too, but a pushed crate pushes nothing.
        const second = try box(&w, .init(3.2, 0.501, 0), .init(0.5, 0.5, 0.5), .kinematic, 1);
        const c = try w.addCharacter(gpa, config, .init(1.19, 0, 0), 0);
        for (0..10) |_| _ = try step(&w, c, .init(0.1, -0.01, 0));
        try t.expectApproxEqAbs(@as(f32, 3.2), w.body(second).?.pose.position.x, 1e-6);
        const x = w.body(first).?.pose.position.x;
        if (ratio == 0) {
            try t.expectEqual(@as(f32, 2), x);
            try t.expect(feetOf(&w, c).x < 1.2 + 1e-3);
        } else {
            // Stopped a skin short of the second, its pusher a skin short of it.
            try t.expect(x > 2.19 and x < 2.2);
            try t.expect(feetOf(&w, c).x > x - 0.81 and feetOf(&w, c).x < x - 0.8);
        }
    }
}

test "pushing: a pushed character slides along a wall" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    var shoved = config;
    shoved.push = 1;
    const a = try w.addCharacter(gpa, config, .init(0, 0, 0), 0);
    const b = try w.addCharacter(gpa, shoved, .init(0.61, 0, 0), 1);
    // A wall across b's way at 45 degrees, so being pushed along +x it slides toward +z.
    const r = Quat.fromAxisAngle(.up, std.math.pi / 4.0);
    _ = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(0.5, 2, 4) } }, .pose = .{ .position = .init(2.2, 2, 0), .rotation = r } });
    _ = try step(&w, a, fall);
    _ = try step(&w, b, fall);
    var pushed = false;
    for (0..12) |_| {
        const m = try step(&w, a, .init(0.1, -0.01, 0));
        pushed = pushed or m.pushed != null;
    }
    try t.expect(pushed);
    const fb = feetOf(&w, b);
    try t.expect(fb.z > 0.05);
    try t.expect(fb.x > 0.7);
}

test "pushing: a pushed character pushes nothing itself" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    var shoved = config;
    shoved.push = 1;
    const a = try w.addCharacter(gpa, config, .init(0, 0, 0), 0);
    const b = try w.addCharacter(gpa, shoved, .init(0.61, 0, 0), 1);
    // A pushable crate 5 cm ahead of b.
    const crate = try box(&w, .init(1.26, 0.501, 0), .init(0.3, 0.5, 0.3), .kinematic, 1);
    _ = try step(&w, a, fall);
    _ = try step(&w, b, fall);
    for (0..6) |_| _ = try step(&w, a, .init(0.1, -0.01, 0));
    // b reached it and stopped at it; the crate stayed.
    try t.expect(feetOf(&w, b).x > 0.6 + 0.04);
    try t.expectEqual(@as(f32, 1.26), w.body(crate).?.pose.position.x);
}

test "pushing: a character standing on a pushed crate is carried with it" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    const crate = try box(&w, .init(2, 0.501, 0), .init(1, 0.5, 1), .kinematic, 1);
    const rider = try w.addCharacter(gpa, config, .init(2, 1.002, 0), 1);
    _ = try step(&w, rider, fall);
    try t.expect(w.character(rider).?.ground.?.body.eql(crate));
    const c = try w.addCharacter(gpa, config, .init(0.69, 0, 0), 0);
    _ = try step(&w, c, fall);
    const before = feetOf(&w, rider);
    const crate_before = w.body(crate).?.pose.position;
    _ = try step(&w, c, .init(0.3, -0.01, 0));
    const moved = w.body(crate).?.pose.position.sub(crate_before);
    try t.expect(moved.x > 0.25);
    const m = try step(&w, rider, fall);
    try t.expect(m.carried.sub(moved).length() < 1e-5);
    try t.expect(feetOf(&w, rider).sub(before).x - moved.x < 1e-4);
}

test "pushing: a ratio outside [0, 1], or on a static body, is refused" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    try t.expectError(error.InvalidShape, box(&w, .zero, .init(1, 1, 1), .kinematic, 1.5));
    try t.expectError(error.InvalidShape, box(&w, .zero, .init(1, 1, 1), .kinematic, -0.1));
    try t.expectError(error.InvalidShape, box(&w, .zero, .init(1, 1, 1), .kinematic, std.math.nan(f32)));
    try t.expectError(error.InvalidShape, box(&w, .zero, .init(1, 1, 1), .static, 0.5));
    const crate = try box(&w, .zero, .init(1, 1, 1), .kinematic, 0.5);
    try t.expectError(error.InvalidShape, w.setKind(crate, .static));
    try t.expectError(error.InvalidShape, w.setPush(crate, 2));
    try t.expect(try w.setPush(crate, 0));
    try t.expect(try w.setKind(crate, .static));
    var bad = config;
    bad.push = 1.5;
    try t.expectError(error.InvalidCharacter, w.addCharacter(gpa, bad, .zero, 0));
}

/// A world of platforms, pushes, sweeps and characters, stepped `ticks` times in §13's order,
/// hashed as it goes.
fn replay(ticks: usize) !u64 {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    const lift = try box(&w, .init(4, 0.1, 0), .init(1, 0.1, 1), .kinematic, 0);
    const table = try box(&w, .init(-4, 0.1, 0), .init(1.5, 0.1, 1.5), .kinematic, 0);
    _ = try box(&w, .init(0, 0.501, 3), .init(0.4, 0.5, 0.4), .kinematic, 0.5);
    const door_shape: p.Shape = .{ .box = .{ .half_extents = .init(0.6, 1, 0.05) } };
    const door = try w.addBody(gpa, .{ .shape = door_shape, .pose = .at(.init(0.6, 1, -3)), .kind = .kinematic });
    var shoved = config;
    shoved.push = 0.5;
    const riders = [_]p.CharacterHandle{
        try w.addCharacter(gpa, config, .init(4, 0.2, 0), 0),
        try w.addCharacter(gpa, config, .init(-3, 0.2, 0), 1),
        try w.addCharacter(gpa, shoved, .init(0, 0, 0), 2),
        try w.addCharacter(gpa, config, .init(0, 0, 1.5), 3),
    };
    var hash: u64 = 0xcbf29ce484222325;
    var crushed: [4]p.CharacterHandle = undefined;
    var hits: [8]p.Hit = undefined;
    for (0..ticks) |i| {
        const f: f32 = @floatFromInt(i);
        // 1. Kinematic bodies: the lift up and down, the table round, the door swung by a sweep.
        const height = 0.1 + 1.5 * @abs(@mod(f / 120, 2) - 1);
        _ = try w.moveBody(gpa, lift, .at(.init(4, height, 0)), &crushed);
        _ = try w.moveBody(gpa, table, .{ .position = .init(-4, 0.1, 0), .rotation = Quat.fromAxisAngle(.up, f * 0.01) }, &crushed);
        const swing = Quat.fromAxisAngle(.up, 0.8 * @sin(f * 0.02));
        const hinge = Vec3.init(0, 1, -3);
        const to: p.Pose = .{ .position = hinge.add(swing.rotate(.init(0.6, 0, 0))), .rotation = swing };
        const blocked = try w.shapeSweep(door_shape, w.body(door).?.pose, to, .{ .ignore = door });
        if (blocked == null) _ = try w.moveBody(gpa, door, to, &crushed);
        // 2. Characters, in a fixed order.
        for (riders, 0..) |c, k| {
            const kf: f32 = @floatFromInt(k);
            const by = Vec3.init(0.04 * @cos(f * 0.03 + kf), -0.02, 0.04 * @sin(f * 0.05 + kf));
            const m = (try w.moveCharacter(gpa, c, by, &hits)).?;
            for ([_]Vec3{ m.feet, m.carried }) |v| fold(&hash, std.mem.asBytes(&v));
            fold(&hash, std.mem.asBytes(&m.carried_yaw));
            fold(&hash, &.{ @intFromBool(m.grounded), @intFromBool(m.pushed != null) });
        }
        var it = w.bodyIterator();
        while (it.next()) |entry| fold(&hash, std.mem.asBytes(&entry.value.pose));
    }
    return hash;
}

fn fold(hash: *u64, bytes: []const u8) void {
    for (bytes) |b| hash.* = (hash.* ^ b) *% 0x100000001b3;
}

test "determinism: two worlds stepping 1,200 ticks of platforms, pushes, sweeps and characters agree" {
    const a = try replay(1200);
    const b = try replay(1200);
    try t.expectEqual(a, b);
    try t.expect(a != try replay(1199));
}
