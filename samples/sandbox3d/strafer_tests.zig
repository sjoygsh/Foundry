//! M36 Step 7 (`animation-ik.md` §12): the strafer on the compiled walker, circling on `walk8` with
//! its feet on the walk world's floor and its head on a camera.
const std = @import("std");
const anim = @import("anim");
const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const options = @import("walk_test_options");
const Strafer = @import("strafer.zig").Strafer;
const Walk = @import("walk.zig").Walk;
const testing = std.testing;
const Vec3 = core.math.Vec3;
const dt = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

const Fixture = struct {
    engine: *app.Engine,
    rigs: asset.Rigs,
    walk: Walk,

    fn init(self: *Fixture) !void {
        const gpa = testing.allocator;
        self.engine = try app.Engine.init(gpa, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
            .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
            .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
        } });
        errdefer self.engine.deinit();
        try self.engine.assets.registerLoader(gpa, asset.collisionMeshLoader());
        self.rigs = asset.Rigs.init(gpa, &self.engine.assets);
        self.walk = Walk.init(gpa);
        self.walk.refresh(&self.engine.store, &self.engine.assets, dt);
    }

    fn deinit(self: *Fixture) void {
        self.walk.deinit(&self.engine.assets);
        self.rigs.deinit();
        self.engine.deinit();
    }
};

fn models(rig: *const anim.Rig, s: *const Strafer, out: []Vec3) void {
    for (out, 0..) |*p, j| p.* = anim.ik.positionOf(anim.ik.modelOf(rig.skeleton, .{ .local = @constCast(s.pose[0..out.len]) }, @intCast(j)));
}

fn fresh(f: *Fixture) !*Strafer {
    const s = try testing.allocator.create(Strafer);
    s.* = .{};
    s.refresh(&f.engine.store, &f.rigs, null);
    try testing.expect(s.active());
    return s;
}

fn release(f: *Fixture, s: *Strafer) void {
    s.deinit(&f.rigs, null);
    testing.allocator.destroy(s);
}

test "strafer: circles on walk8 through every direction, its feet on the floor and the pose the blend's, with no jump" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const s = try fresh(&f);
    defer release(&f, s);
    // The same figure with no ground to stand on: its pose is the blend's alone.
    const bare = try fresh(&f);
    defer release(&f, bare);
    const rig = f.rigs.get(s.rig).?;
    var sectors = [_]bool{false} ** 8;
    var before: [19]Vec3 = undefined;
    var now: [19]Vec3 = undefined;
    var fastest: f32 = 0;
    // Two laps, at 0.9 m/s round a 0.6 m circle, and on into a third.
    for (0..1200) |t| {
        try s.step(&f.rigs, &f.walk.world, null, dt);
        try bare.step(&f.rigs, null, null, dt);
        // Its velocity in its own frame, by which eighth of a turn it points.
        try testing.expectApproxEqAbs(@as(f32, 0.9), @sqrt(s.at[0] * s.at[0] + s.at[1] * s.at[1]), 1e-4);
        const heading = std.math.atan2(s.at[0], s.at[1]);
        sectors[@intFromFloat(@mod(@floor((heading + std.math.pi / 8.0) / (std.math.pi / 4.0)), 8))] = true;
        // Flat floor under every foot, so the feet correct nothing, to the bit.
        for (s.grounds[0..2]) |ground| {
            try testing.expect(ground.hit);
            try testing.expectApproxEqAbs(@as(f32, 0), ground.point.y, 1e-4);
        }
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(bare.pose[0..19]), std.mem.sliceAsBytes(s.pose[0..19]));
        // Between any two ticks no joint moves, in the model, faster than 3 m/s: a swinging foot's
        // pace, and no pop as the blend's place crosses the grid.
        models(rig, s, &now);
        if (t > 0) for (before, now) |a, b| {
            fastest = @max(fastest, b.sub(a).length());
        };
        before = now;
    }
    for (sectors) |seen| try testing.expect(seen);
    try testing.expect(fastest < 3.0 * dt);
    try testing.expect(fastest > 1.0 * dt);
}

test "strafer: replays to the bit, and a pin holds its sweep" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = try fresh(&f);
    defer release(&f, a);
    const b = try fresh(&f);
    defer release(&f, b);
    for (0..1200) |_| {
        try a.step(&f.rigs, &f.walk.world, null, dt);
        try b.step(&f.rigs, &f.walk.world, null, dt);
    }
    try testing.expectEqual(a.hash, b.hash);
    try testing.expectEqual(@as(u64, 0x27f549beaaf0e20b), a.hash);
}

test "strafer: its head turns to a camera, and lets it go behind" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const s = try fresh(&f);
    defer release(&f, s);
    const bare = try fresh(&f);
    defer release(&f, bare);
    const ahead = core.math.Mat4.trs(s.position, core.math.Quat.fromAxisAngle(.up, s.yaw), .one).mulPoint(.init(0.5, 1.6, -2));
    for (0..30) |_| {
        // A camera held where it was first seen, ahead of where it starts.
        try s.step(&f.rigs, &f.walk.world, ahead, dt);
        try bare.step(&f.rigs, &f.walk.world, null, dt);
    }
    try testing.expectEqual(@as(f32, 1), s.aim.weight);
    try testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(bare.pose[0..19]), std.mem.sliceAsBytes(s.pose[0..19])));
    // Going round, it comes to have the camera behind it, and lets go.
    var let_go = false;
    for (0..400) |_| {
        try s.step(&f.rigs, &f.walk.world, ahead, dt);
        if (s.aim.beyond and s.aim.weight == 0) let_go = true;
    }
    try testing.expect(let_go);
}

test "strafer: a set without walk8, or no record, is no strafer" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var s: Strafer = .{};
    defer s.deinit(&f.rigs, null);
    var empty: @import("data").Store = .init(testing.allocator, .default);
    defer empty.deinit(testing.allocator);
    s.refresh(&empty, &f.rigs, null);
    try testing.expect(!s.active());
    try s.step(&f.rigs, &f.walk.world, null, dt);
    try testing.expectEqual(@as(u64, 0), s.ticks);
}
