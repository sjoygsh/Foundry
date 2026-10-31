//! Compiled package -> rig -> entity -> root motion through a controller -> save, load and a mod.
const std = @import("std");
const anim = @import("anim");
const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const scene = @import("scene");
const options = @import("walk_test_options");
const Figure = @import("pacer.zig").Figure;
const pacer_mod = @import("pacer.zig");
const Orrery = @import("orrery.zig").Orrery;
const Walk = @import("walk.zig").Walk;
const testing = std.testing;
const Vec3 = core.math.Vec3;
const dt = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

const Fixture = struct {
    engine: *app.Engine,
    rigs: asset.Rigs,
    walk: Walk,
    orrery: *Orrery,
    figure: *Figure,
    mod_bytes: ?[]u8 = null,

    fn init(self: *Fixture, mod: ?[]const u8) !void {
        const gpa = testing.allocator;
        self.mod_bytes = null;
        self.engine = try app.Engine.init(gpa, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
            .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
            .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
        } });
        try self.engine.assets.registerLoader(gpa, asset.collisionMeshLoader());
        if (mod) |path| {
            const bytes = try self.engine.os.readFile(gpa, path, 16 * 1024 * 1024);
            self.mod_bytes = bytes;
            var diags: data.Diagnostics = .init(gpa, .default);
            defer diags.deinit(gpa);
            _ = try self.engine.store.add(gpa, "pacer_quick:content", bytes, &self.engine.schemas, &diags);
        }
        self.rigs = asset.Rigs.init(gpa, &self.engine.assets);
        self.walk = Walk.init(gpa);
        self.walk.refresh(&self.engine.store, &self.engine.assets, dt);
        self.orrery = try gpa.create(Orrery);
        try self.orrery.init(gpa, core.jobs.serial);
        self.orrery.populate(&self.engine.store);
        self.figure = try gpa.create(Figure);
        self.figure.* = .{};
        try self.refresh();
    }

    fn refresh(self: *Fixture) !void {
        try self.figure.refresh(testing.allocator, &self.orrery.world, self.orrery.role(.pacer), &self.walk.world, null, &self.rigs);
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        self.figure.deinit(gpa, &self.walk.world, null, &self.rigs);
        gpa.destroy(self.figure);
        self.orrery.deinit();
        gpa.destroy(self.orrery);
        self.walk.deinit(&self.engine.assets);
        self.rigs.deinit();
        self.engine.deinit();
        if (self.mod_bytes) |bytes| gpa.free(bytes);
    }

    fn tick(self: *Fixture, n: u64) !void {
        try self.figure.step(testing.allocator, &self.orrery.world, &self.walk.world, &self.rigs, dt);
        self.orrery.step(.{ .tick = n, .delta = .fromNanos(16_666_667) });
        try self.figure.evaluate(&self.orrery.world, &self.rigs);
        self.figure.record(&self.orrery.world);
    }

    fn pace(self: *Fixture) *pacer_mod.Pace {
        return pacer_mod.paceIn(&self.orrery.world, self.orrery.role(.pacer).?).?;
    }

    /// Where it stood as each of `count` corners ended.
    fn corners(self: *Fixture, out: []Vec3) !void {
        var seen: u32 = 0;
        var n: u64 = 0;
        while (seen < out.len) : (n += 1) {
            try testing.expect(n < 20_000);
            try self.tick(n);
            if (self.pace().corners != seen) {
                out[seen] = self.figure.feet;
                seen += 1;
            }
        }
    }
};

test "pacer: walks a square of 0.9 m that its clips decide, and closes it" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const start = f.figure.feet;
    try testing.expectEqual(@as(f32, 2.65), start.x);
    var at: [5]Vec3 = undefined;
    try f.corners(&at);
    // A first turn on the spot, seen on the tick the next side has begun to fade in.
    try testing.expectApproxEqAbs(start.x, at[0].x, 3e-3);
    try testing.expectApproxEqAbs(start.z, at[0].z, 3e-3);
    // West, south, east, north: a left turn at each corner.
    const side = [_]Vec3{ .init(-1, 0, 0), .init(0, 0, 1), .init(1, 0, 0), .init(0, 0, -1) };
    for (0..4) |i| {
        const moved = at[i + 1].sub(at[i]);
        const along = moved.dot(side[i]);
        try testing.expect(along > 0.85 and along < 0.9);
        try testing.expectApproxEqAbs(@as(f32, 0), moved.sub(side[i].scale(along)).length(), 3e-3);
    }
    // Every side is the same, so it comes back to where it began.
    try testing.expectApproxEqAbs(@as(f32, 0), at[4].sub(at[0]).length(), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.004), at[4].y, 1e-3);
    try testing.expect(f.figure.footfalls >= 12);
    // Five quarter turns have gone past a whole one, and a saved heading stays small.
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), f.pace().yaw, 1e-4);
    // Facing west again, and that is what is drawn: its right is north.
    const world = scene.hierarchy.worldTransform(&f.orrery.world, f.orrery.role(.pacer).?).?;
    try testing.expectApproxEqAbs(@as(f32, -1), world.cols[0][2], 1e-4);
    const report = &f.figure.report;
    try testing.expectEqual(@as(u32, 1), report.players);
    try testing.expectEqualStrings("turn", report.rows[0].channels[0].label());
}

test "pacer: a mod that doubles stride's speed doubles the square, with no code" {
    if (comptime !options.available) return error.SkipZigTest;
    var base: Fixture = undefined;
    try base.init(null);
    defer base.deinit();
    var quick: Fixture = undefined;
    try quick.init(options.pacer_quick_package);
    defer quick.deinit();
    var plain: [3]Vec3 = undefined;
    var wide: [3]Vec3 = undefined;
    try base.corners(&plain);
    try quick.corners(&wide);
    // Each loses the ticks of its fade, which at twice the speed is twice the ground.
    const ratio = wide[1].sub(wide[0]).length() / plain[1].sub(plain[0]).length();
    try testing.expectApproxEqAbs(@as(f32, 2), ratio, 1e-3);
    // It still turns a clean corner, and its footfall moved with no change to what the record says.
    try testing.expectApproxEqAbs(@as(f32, 0), wide[2].sub(wide[1]).dot(wide[1].sub(wide[0])), 1e-3);
    try testing.expectEqual(quick.pace().strides, base.pace().strides);
}

test "pacer: saved in mid-stride, a load does the same thing to the bit" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    for ([_]u64{ 100, 150, 30 }) |at| {
        var f: Fixture = undefined;
        try f.init(null);
        defer f.deinit();
        for (0..at) |n| try f.tick(n);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        _ = try f.orrery.save(&bytes);
        const footfalls = f.figure.footfalls;
        f.figure.hash = Figure.hash_seed;
        for (0..600) |n| try f.tick(at + n);
        const run = f.figure.hash;
        try testing.expect(f.figure.footfalls > footfalls);

        // A fresh world, and a fresh walk world with no player or walker in it.
        var other: Walk = Walk.init(gpa);
        defer other.deinit(&f.engine.assets);
        other.refresh(&f.engine.store, &f.engine.assets, dt);
        const fresh = try gpa.create(Orrery);
        defer gpa.destroy(fresh);
        try fresh.init(gpa, core.jobs.serial);
        defer fresh.deinit();
        fresh.roles = f.orrery.roles;
        try testing.expect(fresh.load(bytes.items, &f.engine.store) != null);
        const figure = try gpa.create(Figure);
        defer gpa.destroy(figure);
        figure.* = .{};
        defer figure.deinit(gpa, &other.world, null, &f.rigs);
        try figure.refresh(gpa, &fresh.world, fresh.role(.pacer), &other.world, null, &f.rigs);
        for (0..600) |n| {
            try figure.step(gpa, &fresh.world, &other.world, &f.rigs, dt);
            fresh.step(.{ .tick = n, .delta = .fromNanos(16_666_667) });
            try figure.evaluate(&fresh.world, &f.rigs);
            figure.record(&fresh.world);
        }
        try testing.expectEqual(run, figure.hash);
        // No pose in a save: it is no bigger for having walked.
        var later: std.ArrayList(u8) = .empty;
        defer later.deinit(gpa);
        _ = try f.orrery.save(&later);
        try testing.expectEqual(bytes.items.len, later.items.len);
    }
}

test "pacer: a footfall is in the hash, by what it is" {
    if (comptime !options.available) return error.SkipZigTest;
    var plain: Fixture = undefined;
    try plain.init(null);
    defer plain.deinit();
    var other: Fixture = undefined;
    try other.init(null);
    defer other.deinit();
    const entry = other.rigs.get(other.figure.rig).?.find(anim.clipName("stride")).?;
    @constCast(&entry.events[0]).id = core.ContentId.fromString("sandbox3d:event.other");
    for (0..200) |n| {
        try plain.tick(n);
        try other.tick(n);
    }
    // The same pose and the same feet, for a different event.
    try testing.expectEqual(plain.figure.feet, other.figure.feet);
    try testing.expect(plain.figure.hash != other.figure.hash);
}

test "pacer: it falls to the floor, no faster than its limit, and stops falling" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const id = f.orrery.world.findComponent(scene.query.schemaIdOf(scene.hierarchy.Transform)).?;
    const transform: *scene.hierarchy.Transform = @ptrCast(@alignCast(f.orrery.world.getComponent(f.orrery.role(.pacer).?, id).?.ptr));
    transform.translation.y = 40;
    try f.refresh();
    var fastest: f32 = 0;
    for (0..400) |n| {
        try f.tick(n);
        fastest = @min(fastest, f.pace().velocity);
        // Falling, for as long as it is in the air.
        if (n == 0) try testing.expect(f.figure.feet.y < 40);
    }
    try testing.expectEqual(@as(f32, -20), fastest);
    try testing.expectApproxEqAbs(@as(f32, 0.004), f.figure.feet.y, 1e-2);
    try testing.expectEqual(@as(f32, 0), f.pace().velocity);
}

test "pacer: a reload's refresh keeps its place, and what it can't play is refused by name" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    for (0..100) |n| try f.tick(n);
    const feet = f.figure.feet;
    const ticks = f.pace().ticks;
    try f.refresh();
    try testing.expectEqual(feet, f.figure.feet);
    try testing.expectEqual(ticks, f.pace().ticks);

    // Held by a second handle, so `refresh` finds this rig and not a fresh one.
    const set = core.ContentId.fromString("sandbox3d:walker.set");
    const held = try f.rigs.acquire(set);
    defer f.rigs.release(held);
    const rig = @constCast(f.rigs.get(held).?);
    const clips = @constCast(rig.clips);
    const turn = @constCast(rig.find(anim.clipName("turn")).?);
    turn.loop = true;
    try testing.expectError(error.TurnLoops, f.refresh());
    turn.loop = false;
    const joint = rig.motion_joint;
    rig.motion_joint = anim.no_parent;
    try testing.expectError(error.NoMotionJoint, f.refresh());
    rig.motion_joint = joint;
    // A name out of the rig, by shifting each past the search's reach.
    for ([_]struct { name: []const u8, refusal: anyerror }{
        .{ .name = "stride", .refusal = error.MissingStride },
        .{ .name = "turn", .refusal = error.MissingTurn },
    }) |case| {
        const entry = @constCast(rig.find(anim.clipName(case.name)).?);
        const name = entry.name;
        entry.name +%= 1;
        try testing.expectError(case.refusal, f.refresh());
        entry.name = name;
    }
    _ = clips;
    try f.refresh();
    try testing.expect(!f.figure.character.isNone());

    // No such set: the figure stands down, and the world is untouched.
    const animator = scene.animation.animatorOf(&f.orrery.world, f.orrery.role(.pacer).?).?;
    const saved = animator.set;
    animator.set = core.ContentId.fromString("sandbox3d:no.such.set");
    try testing.expectError(error.MissingSet, f.refresh());
    try testing.expect(f.figure.character.isNone() and f.figure.rig.isNone());
    animator.set = saved;
    try f.refresh();

    // A save's values are refused before they reach the arithmetic.
    const pace = f.pace();
    const good = pace.*;
    for ([_]pacer_mod.Pace{
        .{ .strides = std.math.nan(f32) },
        .{ .strides = 0 },
        .{ .strides = 65 },
        .{ .yaw = std.math.inf(f32) },
        .{ .velocity = std.math.nan(f32) },
        .{ .velocity = -21 },
    }) |bad| {
        pace.* = bad;
        try testing.expectError(error.InvalidPacer, f.refresh());
    }
    pace.* = good;
    try f.refresh();

    // No entity: nothing to do, and no error. A package with no pacer is a fine package.
    try f.figure.refresh(testing.allocator, &f.orrery.world, null, &f.walk.world, null, &f.rigs);
    try f.figure.step(testing.allocator, &f.orrery.world, &f.walk.world, &f.rigs, dt);
    try f.figure.evaluate(&f.orrery.world, &f.rigs);
}
