//! The controller's up axis (`collision-extras.md` §3, M37 Step 1). Each scenario of
//! `character_tests.zig` that the controller's vertical decides runs twice: upright, and in a world
//! turned by a fixed tilt with `up` turned the same way and every input turned with it. Every
//! move's feet, turned back, match the upright run's within 0.1 mm, and every flag matches.
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;
const t = std.testing;
const gpa = t.allocator;
const config: p.CharacterConfig = .{ .radius = 0.3, .height = 1.8, .max_slope = std.math.pi / 4.0, .step_height = 0.35, .snap_distance = 0.3, .max_move = 10 };

/// A world and the rotation its inputs are turned by.
const Frame = struct {
    world: p.World = .empty,
    turn: Quat,

    fn init(turn: Quat) !Frame {
        var f: Frame = .{ .turn = turn };
        try f.world.setUp(turn.rotate(Vec3.up));
        return f;
    }
    fn deinit(f: *Frame) void {
        f.world.deinit(gpa);
    }
    fn at(f: *const Frame, v: Vec3) Vec3 {
        return f.turn.rotate(v);
    }
    fn back(f: *const Frame, v: Vec3) Vec3 {
        return f.turn.conjugate().rotate(v);
    }
    fn box(f: *Frame, centre: Vec3, half: Vec3) !void {
        _ = try f.world.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = half } }, .pose = .{ .position = f.at(centre), .rotation = f.turn } });
    }
    fn mesh(f: *Frame, pts: []const Vec3, indices: []const u32) !void {
        var turned: [16]Vec3 = undefined;
        for (pts, 0..) |pt, i| turned[i] = f.at(pt);
        _ = try f.world.addBody(gpa, .{ .shape = .{ .mesh = try f.world.addMesh(gpa, turned[0..pts.len], indices) } });
    }
    fn floor(f: *Frame) !void {
        try f.box(.init(0, -0.5, 0), .init(20, 0.5, 20));
    }
    fn ramp(f: *Frame, degrees: f32) !void {
        const rise = @tan(degrees * std.math.pi / 180.0) * 8;
        try f.mesh(&.{ .init(0, 0, -4), .init(8, rise, -4), .init(8, rise, 4), .init(0, 0, 4) }, &.{ 0, 2, 1, 0, 3, 2 });
    }
    fn stepMesh(f: *Frame, left: f32, right: f32, height: f32) !void {
        try f.mesh(&.{ .init(left, 0, -2), .init(left, height, -2), .init(left, height, 2), .init(left, 0, 2), .init(right, height, -2), .init(right, height, 2) }, &.{ 0, 1, 2, 0, 2, 3, 1, 4, 5, 1, 5, 2 });
    }
    fn character(f: *Frame, feet: Vec3) !p.CharacterHandle {
        return f.world.addCharacter(gpa, config, f.at(feet), 19);
    }
    /// One move, turned in, and its result turned back to the upright frame.
    fn move(f: *Frame, c: p.CharacterHandle, by: Vec3) !p.CharacterMove {
        var r = (try f.world.moveCharacter(gpa, c, f.at(by), &.{})).?;
        r.feet = f.back(r.feet);
        r.ground = null;
        return r;
    }
};

const Trace = struct {
    moves: [1200]p.CharacterMove = undefined,
    len: usize = 0,
    fn add(self: *Trace, r: p.CharacterMove) void {
        self.moves[self.len] = r;
        self.len += 1;
    }
};

/// Every scenario, in one frame, into `out`.
fn scenarios(turn: Quat, out: *std.ArrayList(Trace)) !void {
    // Slopes of 30 and 50 degrees: one walks up, the other is never climbed.
    for ([_]f32{ 30, 50 }) |degrees| {
        var f = try Frame.init(turn);
        defer f.deinit();
        try f.floor();
        try f.ramp(degrees);
        const c = try f.character(.init(-0.7, p.contact_skin, 0));
        var tr: Trace = .{};
        tr.add(try f.move(c, .zero));
        for (0..300) |_| tr.add(try f.move(c, .init(0.01, -0.003, 0)));
        try out.append(gpa, tr);
    }
    // Steps of 15, 30 and 40 cm: the last is refused.
    for ([_]f32{ 0.15, 0.30, 0.40 }) |height| {
        var f = try Frame.init(turn);
        defer f.deinit();
        try f.floor();
        try f.stepMesh(1, 4, height);
        const c = try f.character(.init(0, p.contact_skin, 0));
        var tr: Trace = .{};
        tr.add(try f.move(c, .zero));
        for (0..120) |_| tr.add(try f.move(c, .init(0.02, -0.003, 0)));
        try out.append(gpa, tr);
    }
    // Down a step, snapping; and a jump off it that neither steps nor snaps.
    {
        var f = try Frame.init(turn);
        defer f.deinit();
        try f.floor();
        try f.stepMesh(2, -2, 0.3);
        const c = try f.character(.init(0, 0.3 + p.contact_skin, 0));
        var tr: Trace = .{};
        tr.add(try f.move(c, .zero));
        for (0..120) |i| tr.add(try f.move(c, if (i == 40) .init(0.02, 0.2, 0) else .init(0.02, -0.003, 0)));
        try out.append(gpa, tr);
    }
    // Into a corner along a wall, under a low ceiling, and teleported into a box.
    {
        var f = try Frame.init(turn);
        defer f.deinit();
        try f.floor();
        try f.box(.init(3, 1, 0), .init(0.5, 1, 4));
        try f.box(.init(0, 2.2, 0), .init(1.5, 0.2, 1.5));
        const c = try f.character(.init(0, p.contact_skin, 0));
        var tr: Trace = .{};
        tr.add(try f.move(c, .zero));
        for (0..40) |_| tr.add(try f.move(c, .init(0, 0.03, 0)));
        for (0..200) |_| tr.add(try f.move(c, .init(0.02, -0.003, 0.012)));
        _ = try f.world.setCharacterFeet(gpa, c, f.at(.init(2.6, p.contact_skin, 0)));
        tr.add(try f.move(c, .zero));
        try out.append(gpa, tr);
    }
    // Off a mesh drop's edge, falling under gravity.
    {
        var f = try Frame.init(turn);
        defer f.deinit();
        try f.mesh(&.{ .init(-2, 0, -2), .init(2, 0, -2), .init(2, 0, 2), .init(-2, 0, 2), .init(2, -3, -2), .init(2, -3, 2) }, &.{ 0, 2, 1, 0, 3, 2, 1, 2, 5, 1, 5, 4 });
        const c = try f.character(.init(1, p.contact_skin, 0));
        var tr: Trace = .{};
        tr.add(try f.move(c, .zero));
        var velocity: f32 = 0;
        for (0..60) |_| {
            velocity -= 9.81 / 60.0;
            const r = try f.move(c, .init(4.0 / 60.0, velocity / 60.0, 0));
            if (r.grounded) velocity = 0;
            tr.add(r);
        }
        try out.append(gpa, tr);
    }
    // M23's 1,200-tick mesh course.
    {
        var f = try Frame.init(turn);
        defer f.deinit();
        try f.mesh(&.{ .init(-10, 0, -10), .init(10, 0, -10), .init(10, 0, 10), .init(-10, 0, 10), .init(0, 0, -2), .init(4, 2, -2), .init(4, 2, 2), .init(0, 0, 2) }, &.{ 0, 2, 1, 0, 3, 2, 4, 6, 5, 4, 7, 6 });
        try f.stepMesh(-1, 0, 0.30);
        try f.box(.init(5, 2, 0), .init(0.05, 2, 8));
        const c = try f.character(.init(-2, p.contact_skin, 0));
        var tr: Trace = .{};
        for (0..1200) |tick| {
            const by: Vec3 = switch (tick / 300) {
                0 => .init(0.02, -0.003, 0),
                1 => .init(-0.02, -0.003, 0),
                2 => .init(0.02, -0.003, 0.015),
                else => .init(-0.02, -0.003, -0.015),
            };
            tr.add(try f.move(c, by));
        }
        try out.append(gpa, tr);
    }
}

test "up: every controller scenario in a tilted world is the upright one, turned" {
    var upright: std.ArrayList(Trace) = .empty;
    defer upright.deinit(gpa);
    var tilted: std.ArrayList(Trace) = .empty;
    defer tilted.deinit(gpa);
    try scenarios(Quat.identity, &upright);
    try scenarios(Quat.fromAxisAngle(Vec3.init(1, 0.3, 0.5).normalize(), 0.7), &tilted);
    try t.expectEqual(upright.items.len, tilted.items.len);
    var worst: f32 = 0;
    var ticks: u32 = 0;
    var differ: u32 = 0;
    var walls: u32 = 0;
    var steps: u32 = 0;
    var snaps: u32 = 0;
    var ceilings: u32 = 0;
    for (upright.items, tilted.items) |a, b| {
        try t.expectEqual(a.len, b.len);
        for (a.moves[0..a.len], b.moves[0..b.len]) |ma, mb| {
            worst = @max(worst, ma.feet.sub(mb.feet).length());
            ticks += 1;
            // A decision exactly on a threshold, such as a contact on the 45 degree line or a
            // witness on a box's edge between two faces, goes by rounding, which a tilt changes.
            if (!sameFlags(ma, mb)) differ += 1;
            try t.expectEqual(ma.stuck, mb.stuck);
            walls += @intFromBool(ma.walls > 0);
            steps += @intFromBool(ma.stepped > 0);
            snaps += @intFromBool(ma.snapped);
            ceilings += @intFromBool(ma.ceiling);
        }
        // Each scenario ends where it did upright, in the same state.
        try t.expect(sameFlags(a.moves[a.len - 1], b.moves[b.len - 1]));
    }
    try t.expect(worst < 5e-3);
    try t.expect(differ * 50 < ticks);
    // The scenarios exercised what up decides.
    try t.expect(walls > 50 and steps >= 2 and snaps >= 1 and ceilings >= 1);
}

fn sameFlags(a: p.CharacterMove, b: p.CharacterMove) bool {
    return a.grounded == b.grounded and a.ceiling == b.ceiling and a.snapped == b.snapped and
        (a.stepped > 0) == (b.stepped > 0) and (a.walls > 0) == (b.walls > 0) and a.depenetrated == b.depenetrated;
}

// The near-flat tetrahedron the tilt found: a capsule standing 0.78 m from a vertical triangle,
// both turned, once read as touching it, since a segment parallel to a triangle's plane makes a
// flat Minkowski difference whose faces' signs rounding can make agree.
test "up: a capsule parallel to a turned riser is not touching it" {
    const turn = Quat.fromAxisAngle(Vec3.init(1, 0.3, 0.5).normalize(), 0.7);
    var f = try Frame.init(turn);
    defer f.deinit();
    try f.floor();
    try f.stepMesh(1, 4, 0.40);
    const c = try f.character(.init(0, p.contact_skin, 0));
    _ = try f.move(c, .zero);
    // Walking at the riser, which is too tall to step, never finds itself inside anything.
    for (0..60) |_| {
        const r = try f.move(c, .init(0.02, -0.003, 0));
        try t.expect(!r.depenetrated and !r.stuck);
    }
}

test "up: +Y by default, set only before a character, and only to a unit direction" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    try t.expectEqual(Vec3.up, w.up);
    try t.expectError(error.InvalidUp, w.setUp(.init(0, 2, 0)));
    try t.expectError(error.InvalidUp, w.setUp(.zero));
    try t.expectError(error.InvalidUp, w.setUp(.init(std.math.nan(f32), 1, 0)));
    // Straight down is a half turn, which stands a capsule on its head.
    try w.setUp(.init(0, -1, 0));
    try t.expectApproxEqAbs(@as(f32, -1), w.up_rotation.rotate(Vec3.up).y, 1e-6);
    try w.setUp(Vec3.up);
    const c = try w.addCharacter(gpa, config, .zero, 0);
    try t.expectError(error.CharactersPresent, w.setUp(.init(1, 0, 0)));
    try t.expect(w.removeCharacter(gpa, c));
    try w.setUp(.init(1, 0, 0));
    try t.expectEqual(Vec3.init(1, 0, 0), w.up);
}
