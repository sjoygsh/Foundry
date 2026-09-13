//! A world stepped by a system that splits its own query, under every kind of `core.Jobs`.
//!
//! `scene` cannot see `platform`, so its own tests split only with `serial` and `reversed`. A
//! real pool is reachable from here, where a game stands. The claim is ADR-0036's: the same
//! scenario leaves byte-identical saves whether its system loops, splits in order, splits
//! backwards or splits across real threads (`jobs-and-threading.md` §11, Step 4).
const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const scene = @import("scene");

const testing = std.testing;

const Body = struct {
    pub const component = "test:body";
    x: f32 = 0,
    y: f32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    phase: f32 = 0,
};

const population = 10_000;
const ticks = 120;
/// Small, and not a divisor of what survives, so there are many chunks and the last is partial.
const grain = 257;

const Mode = enum { loop, serial, reversed, pool };

/// Turns each body a little, by an amount that depends on its own phase and the time, and moves
/// it. Floating point on purpose: the claim includes arithmetic whose result depends on order
/// if anything is shared.
fn stepBody(body: *Body, seconds: f32) void {
    const turn = @sin(body.phase + seconds) * 0.05;
    const c = @cos(turn);
    const s = @sin(turn);
    const dx = body.dx * c - body.dy * s;
    const dy = body.dx * s + body.dy * c;
    body.dx = dx;
    body.dy = dy;
    body.x += dx / 60.0;
    body.y += dy / 60.0;
}

fn secondsOf(tick: scene.Tick) f32 {
    return @as(f32, @floatFromInt(tick.tick)) * tick.delta.toSecondsF32();
}

fn loopSystem(_: ?*anyopaque, world: *scene.World, tick: scene.Tick) void {
    const seconds = secondsOf(tick);
    var it = world.queryOf(.{Body});
    while (it.next()) |m| stepBody(m.get(Body), seconds);
}

const BodyQuery = scene.query.TypedQuery(.{Body});

fn splitSystem(_: ?*anyopaque, world: *scene.World, tick: scene.Tick) void {
    const bodies = world.queryOf(.{Body});
    bodies.forChunks(world.jobs(), grain, secondsOf(tick), bodyChunk);
}

fn bodyChunk(seconds: f32, part: *BodyQuery.Part) void {
    while (part.next()) |m| stepBody(m.get(Body), seconds);
}

/// Builds the scenario, steps it, and returns the world's save.
fn run(gpa: std.mem.Allocator, mode: Mode, pool: core.Jobs) ![]u8 {
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    var world: scene.World = .init(gpa, &schemas, .default);
    defer world.deinit();

    const body = try world.registerComponent(scene.componentType(Body));
    world.setJobs(switch (mode) {
        .loop, .serial => core.jobs.serial,
        .reversed => core.jobs.reversed,
        .pool => pool,
    });
    _ = try world.registerSystem(.{
        .id = try data.contentId("test:system.bodies"),
        .name = "test:system.bodies",
        .update = if (mode == .loop) &loopSystem else &splitSystem,
    });

    var made: [population]scene.Entity = undefined;
    for (&made) |*e| {
        e.* = try world.create();
        _ = try world.addComponent(e.*, body, null);
    }
    // Destroyed out of creation order, so the store's dense order is shaped by the removals.
    for (made, 0..) |e, i| {
        if (i % 7 == 3) _ = world.destroy(e);
    }

    var rng = core.Pcg32.init(0x4d3132, 4);
    var it = world.queryOf(.{Body});
    while (it.next()) |m| {
        m.get(Body).* = .{
            .x = @as(f32, @floatFromInt(rng.below(2000))) - 1000,
            .y = @as(f32, @floatFromInt(rng.below(2000))) - 1000,
            .dx = @as(f32, @floatFromInt(rng.below(200))) - 100,
            .dy = @as(f32, @floatFromInt(rng.below(200))) - 100,
            .phase = @as(f32, @floatFromInt(rng.below(6283))) / 1000,
        };
    }

    for (1..ticks + 1) |t| world.update(.{ .tick = t, .delta = .fromMillis(16) });

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try world.save(&out);
    return out.toOwnedSlice(gpa);
}

test "a system that splits its query leaves the save its loop leaves, on one thread or several" {
    const gpa = testing.allocator;
    const os = try platform.Os.init(gpa, .{ .app_name = "foundry-world-jobs-test", .env = &.{} });
    defer os.deinit();
    const workers = try os.startWorkers(gpa, .{ .count = 4 });
    defer workers.deinit();
    try testing.expectEqual(@as(u16, 4), workers.threadCount());

    const reference = try run(gpa, .loop, core.jobs.serial);
    defer gpa.free(reference);

    for ([_]Mode{ .serial, .reversed, .pool }) |mode| {
        const bytes = try run(gpa, mode, workers.jobs());
        defer gpa.free(bytes);
        try testing.expectEqualSlices(u8, reference, bytes);
    }

    // Again on the pool, where how chunks land on threads differs every time.
    for (0..4) |_| {
        const bytes = try run(gpa, .pool, workers.jobs());
        defer gpa.free(bytes);
        try testing.expectEqualSlices(u8, reference, bytes);
    }
}
