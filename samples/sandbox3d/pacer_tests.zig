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
            _ = try self.engine.store.add(gpa, std.fs.path.stem(path), bytes, &self.engine.schemas, &diags);
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
        try self.figure.evaluate(&self.orrery.world, &self.rigs, null, dt);
        self.figure.record(&self.orrery.world);
    }

    fn stack(self: *Fixture) *anim.Stack {
        return scene.animation.stack(&self.orrery.world, self.orrery.role(.pacer).?).?;
    }

    /// The head's layer off, so the pose is the base's alone, as M34's was.
    fn lookAway(self: *Fixture) !void {
        try anim.machine.set(self.stack(), self.figure.machineOf(&self.rigs).?.*, anim.clipName("look"), 0);
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
    try testing.expectEqualStrings("turn", report.rows[0].layers[0].channels[0].label());
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

test "pacer: on its machine, with the head still, it walks M34's walk to the bit, and with pacer_quick too" {
    if (comptime !options.available) return error.SkipZigTest;
    // The tour's replay pins from M34 (`animation-logic.md`, Step 7's Resolution): 600 ticks from
    // tick 100. The machine says what M34's code decided, so they hold.
    for ([_]struct { mod: ?[]const u8, pin: u64 }{
        .{ .mod = null, .pin = 0x47f67027ff3a12b0 },
        .{ .mod = options.pacer_quick_package, .pin = 0xef5c24337f5f2925 },
    }) |case| {
        var f: Fixture = undefined;
        try f.init(case.mod);
        defer f.deinit();
        try f.lookAway();
        for (0..100) |n| try f.tick(n);
        f.figure.hash = Figure.hash_seed;
        for (0..600) |n| try f.tick(100 + n);
        try testing.expectEqual(case.pin, f.figure.hash);
        try testing.expectEqual(@as(f32, 0), f.stack().layers[1].weight);
    }
}

test "pacer: the head looks about on a layer of its own, and leaves the feet where they were" {
    if (comptime !options.available) return error.SkipZigTest;
    var still: Fixture = undefined;
    try still.init(null);
    defer still.deinit();
    try still.lookAway();
    var looking: Fixture = undefined;
    try looking.init(null);
    defer looking.deinit();
    const head = 4;
    var turned: f32 = 0;
    for (0..300) |n| {
        try still.tick(n);
        try looking.tick(n);
        try testing.expectEqual(still.figure.feet, looking.figure.feet);
        const a = still.figure.pose[head].rotation;
        const b = looking.figure.pose[head].rotation;
        turned = @max(turned, 1 - @abs(a.dot(b)));
    }
    // Faded in over its second, and now a whole weight.
    try testing.expectEqual(@as(f32, 1), looking.stack().layers[1].weight);
    try testing.expect(turned > 1e-3);
    try testing.expect(still.figure.hash != looking.figure.hash);
    const report = &looking.figure.report;
    try testing.expect(report.rows[0].machine);
    try testing.expectEqualStrings("look", report.rows[0].layers[1].label());
    try testing.expectEqualStrings("look", report.rows[0].layers[1].stateLabel());
}

test "pacer: saved in mid-stride, mid-turn and mid-fade, a load does the same thing to the bit" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    // 100 and 150 are mid-stride and 30 mid-turn, as M34 had them. The first turn's last tick is
    // 47, and 52 is in the fade that follows it, with the head's layer still fading in too.
    for ([_]u64{ 100, 150, 30, 47, 52 }) |at| {
        var f: Fixture = undefined;
        try f.init(null);
        defer f.deinit();
        for (0..at) |n| try f.tick(n);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        _ = try f.orrery.save(&bytes);
        const footfalls = f.figure.footfalls;
        if (at == 30 or at == 47) try testing.expectEqual(anim.clipName("turn"), f.stack().layers[0].state);
        if (at == 52) {
            const base = &f.stack().players[0];
            try testing.expectEqual(anim.clipName("stride"), f.stack().layers[0].state);
            try testing.expect(base.channels[base.newest].weight < 1);
        }
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
            try figure.evaluate(&fresh.world, &f.rigs, null, dt);
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
    const before = f.stack().*;
    try f.refresh();
    try testing.expectEqual(feet, f.figure.feet);
    try testing.expectEqual(before, f.stack().*);

    // Held by a second handle, so `refresh` finds this rig and not a fresh one.
    const set = core.ContentId.fromString("sandbox3d:walker.set");
    const held = try f.rigs.acquire(set);
    defer f.rigs.release(held);
    const rig = @constCast(f.rigs.get(held).?);
    const joint = rig.motion_joint;
    rig.motion_joint = anim.no_parent;
    try testing.expectError(error.NoMotionJoint, f.refresh());
    rig.motion_joint = joint;
    // A machine that is not there, or that does not build against the set, is refused by name.
    const animator_now = scene.animation.animatorOf(&f.orrery.world, f.orrery.role(.pacer).?).?;
    const machine = animator_now.machine;
    animator_now.machine = core.ContentId.fromString("sandbox3d:no.such.machine");
    try testing.expectError(error.MissingMachine, f.refresh());
    try testing.expect(f.figure.machine.isNone() and f.figure.rig.isNone());
    animator_now.machine = core.ContentId.fromString("sandbox3d:walker.set");
    try testing.expectError(error.MissingMachine, f.refresh());
    animator_now.machine = machine;
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
    try f.figure.evaluate(&f.orrery.world, &f.rigs, null, dt);
}

test "pacer: an M34 save, from before machines, carries on to the bit, and the head fades in" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    // Saved at tick 100 by M34's tour code, at tag `m34`, before `foundry:animator` had version 2.
    const m34 = @embedFile("testdata/saves/pacer_m34.fsav");
    for ([_]bool{ false, true }) |looking| {
        var f: Fixture = undefined;
        try f.init(null);
        defer f.deinit();
        const fresh = try gpa.create(Orrery);
        defer gpa.destroy(fresh);
        try fresh.init(gpa, core.jobs.serial);
        defer fresh.deinit();
        fresh.roles = f.orrery.roles;
        try testing.expect(fresh.load(m34, &f.engine.store) != null);
        const animator = scene.animation.animatorOf(&fresh.world, fresh.role(.pacer).?).?;
        try testing.expect(animator.machine.isNone());
        const before = animator.player().*;

        var other: Walk = Walk.init(gpa);
        defer other.deinit(&f.engine.assets);
        other.refresh(&f.engine.store, &f.engine.assets, dt);
        const figure = try gpa.create(Figure);
        defer gpa.destroy(figure);
        figure.* = .{};
        defer figure.deinit(gpa, &other.world, null, &f.rigs);
        try figure.refresh(gpa, &fresh.world, fresh.role(.pacer), &other.world, null, &f.rigs);
        // It plays the pacer's machine now, from where M34's timing had it, with its player untouched.
        const stack = scene.animation.stack(&fresh.world, fresh.role(.pacer).?).?;
        try testing.expect(scene.animation.animatorOf(&fresh.world, fresh.role(.pacer).?).?.machine.eql(pacer_mod.machine_id));
        try testing.expectEqual(anim.clipName("stride"), stack.layers[0].state);
        try testing.expectEqual(before, stack.players[0]);
        if (!looking) try anim.machine.set(stack, figure.machineOf(&f.rigs).?.*, anim.clipName("look"), 0);

        for (0..600) |n| {
            try figure.step(gpa, &fresh.world, &other.world, &f.rigs, dt);
            fresh.step(.{ .tick = n, .delta = .fromNanos(16_666_667) });
            try figure.evaluate(&fresh.world, &f.rigs, null, dt);
            figure.record(&fresh.world);
            // No pop: the head's layer begins at nothing and comes in at its fade's rate.
            if (looking and n == 0) try testing.expectApproxEqAbs(dt, stack.layers[1].weight, 1e-6);
        }
        // With the head still, it is M34's run from that save, to the bit.
        if (!looking) try testing.expectEqual(@as(u64, 0x47f67027ff3a12b0), figure.hash);
        try testing.expect(pacer_mod.paceIn(&fresh.world, fresh.role(.pacer).?).?.corners >= 4);
    }
}

test "pacer: pacer_back walks every other side backward, with no code, and a pin holds it" {
    if (comptime !options.available) return error.SkipZigTest;
    var base: Fixture = undefined;
    try base.init(null);
    defer base.deinit();
    var back: Fixture = undefined;
    try back.init(options.pacer_back_package);
    defer back.deinit();
    try base.lookAway();
    try back.lookAway();
    var plain: [5]Vec3 = undefined;
    var turned: [5]Vec3 = undefined;
    try base.corners(&plain);
    try back.corners(&turned);
    // The first side is the same walk west. A corner is seen on the tick the next side has begun,
    // which here is a step back, so the two differ by that tick's travel.
    try testing.expectApproxEqAbs(@as(f32, 0), turned[1].sub(plain[1]).length(), 5e-3);
    // The second faces south, as before, and goes north.
    const second = turned[2].sub(turned[1]);
    try testing.expect(second.dot(.init(0, 0, -1)) > 0.85);
    try testing.expect(plain[2].sub(plain[1]).dot(.init(0, 0, 1)) > 0.85);
    // Backward sides with left turns: the square is the plain one mirrored across its first side,
    // north of it instead of south, and it still closes.
    for (plain, turned) |a, b| {
        try testing.expectApproxEqAbs(a.x, b.x, 5e-3);
        try testing.expectApproxEqAbs(2 * plain[0].z - a.z, b.z, 5e-3);
    }
    try testing.expectApproxEqAbs(@as(f32, 0), turned[4].sub(turned[0]).length(), 1e-3);
    try testing.expect(back.figure.machineOf(&back.rigs).?.layers[0].states.len == 4);

    // Pinned: 600 ticks on from its fifth corner, with the head still, so the pin is the walk's.
    back.figure.hash = Figure.hash_seed;
    for (0..600) |n| try back.tick(20_000 + n);
    try testing.expectEqual(@as(u64, 0x59632bcff2461113), back.figure.hash);
}

test "pacer: a crate on its first side holds it up, and it turns there and walks the next" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var plain: Fixture = undefined;
    try plain.init(null);
    defer plain.deinit();
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    var block: pacer_mod.Block = .{};
    defer block.deinit(gpa, &f.walk.world, null);
    block.refresh(gpa, &f.engine.store, &f.walk.world, null);
    try testing.expect(block.ready and !block.down());
    try block.toggle(gpa, &f.walk.world);
    try testing.expect(block.down());

    var free: [3]Vec3 = undefined;
    var held: [3]Vec3 = undefined;
    try plain.corners(&free);
    try f.corners(&held);
    // Unblocked, the first side ends 0.9 m west. Held up by the crate, it turns where the crate
    // stops it: the crate's east face, less the controller's radius.
    try testing.expect(free[1].x < 1.85);
    const stop = block.position.x + block.half.x + 0.22;
    try testing.expectApproxEqAbs(stop, held[1].x, 0.03);
    try testing.expect(f.figure.blocks >= 1 and plain.figure.blocks == 0);
    // Then it walks the next side south, clear of the crate, as it does on any corner.
    const next = held[2].sub(held[1]);
    try testing.expect(next.dot(.init(0, 0, 1)) > 0.85);
    // The count is the machine's, so it is saved; once it has turned it is back at nothing.
    const machine = f.figure.machineOf(&f.rigs).?.*;
    try testing.expectEqual(@as(f32, 0), anim.machine.get(f.stack(), machine, anim.clipName("blocked")).?);

    // Lifted, it is gone from the walk world.
    try block.toggle(gpa, &f.walk.world);
    try testing.expect(!block.down());
}

test "pacer: it looks at a camera within reach, and lets go of one beyond it" {
    if (comptime !options.available) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    for (0..30) |n| try f.tick(n);
    const world = scene.hierarchy.worldTransform(&f.orrery.world, f.orrery.role(.pacer).?).?;
    // A camera a little to its left, ahead, at its eyes' height, inside 3 m.
    const near = world.mulPoint(.init(-0.8, 1.6, -1.5));
    for (0..30) |_| try f.figure.evaluate(&f.orrery.world, &f.rigs, near, dt);
    try testing.expectEqual(@as(f32, 1), f.figure.aim.weight);
    try testing.expect(!f.figure.aim.beyond);
    const looking = f.figure.matrices[4];
    try f.figure.evaluate(&f.orrery.world, &f.rigs, null, 0);
    // A gaze that fades out over 0.3 s is still on its way; with no camera and no time it holds.
    const far = world.mulPoint(.init(0, 1.6, -4));
    for (0..30) |_| try f.figure.evaluate(&f.orrery.world, &f.rigs, far, dt);
    try testing.expectEqual(@as(f32, 0), f.figure.aim.weight);
    // Let go, the head is the clip's again; looking, it was not.
    var clip: Figure = f.figure.*;
    clip.aim = .{};
    try clip.evaluate(&f.orrery.world, &f.rigs, null, 0);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&clip.matrices[4]), std.mem.asBytes(&f.figure.matrices[4]));
    try testing.expect(!std.mem.eql(u8, std.mem.asBytes(&looking), std.mem.asBytes(&f.figure.matrices[4])));
}
