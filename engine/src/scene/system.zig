//! Systems: the code that runs over a world, once per fixed step.
//!
//! Runtime-registered like everything else here (I6), because a mod adding behaviour is the
//! whole point of a mod and a `comptime` list of systems would make it impossible. A system
//! is a plain struct of an identifier, a context pointer and a function — deliberately
//! C-ABI-shaped ahead of M7, so a native mod's system and the engine's are the same thing.
//!
//! ## What a system is given, and what it is not
//!
//! It receives the world and a `Tick`. It does **not** receive input, and it cannot read a
//! clock: `platform` is not below `scene` and never will be. Input reaches a system as data
//! the game wrote into the world or into the system's own context — which is not a
//! workaround for the layering but the thing that makes replay possible later, because the
//! simulation's inputs become values that were written down (`platform-interface.md`).
//!
//! It also does not receive `alpha`. Interpolating a render is the renderer's business and
//! has no place inside a fixed step (`app-and-frame-loop.md` §2).
//!
//! ## Order
//!
//! Registration order, front to back. That is the simplest thing that works and it is honest
//! about what M4 needs: every system in existence today is registered by one program that
//! knows what it wants.
//!
//! It is not sufficient forever, and the successor is known — `before` and `after`
//! constraints naming other systems by content id, with a deterministic topological sort,
//! which is what a mod needs to insert a system between two engine ones. It is purely
//! additive: a system registered with no constraints keeps its registration-order position.
//! It is not built now because there is no second registrant to have a constraint with, and
//! a scheduler with one client is a scheduler designed against a guess
//! (`entity-storage.md` §13, first open question).
//!
//! Design: `docs/design/entity-storage.md` §7.

const std = @import("std");
const core = @import("core");

const world_mod = @import("world.zig");

/// One fixed simulation step, as a system sees it.
///
/// `scene`'s own, not `app.Step`: `app` is L4 and cannot be imported from here, and the
/// part of a step a system is entitled to is the tick number and the fixed delta. Simulation
/// time is the integer tick, never a float (`core-memory-and-handles.md`).
pub const Tick = struct {
    /// Monotonically increasing from 1.
    tick: u64,
    /// The exact length of one step. Fixed, which is what makes a run reproducible (I9).
    delta: core.time.Duration,
};

/// Phantom tag for `SystemHandle` (I1).
pub const Systems = opaque {};
pub const SystemHandle = core.Handle(Systems);

pub const System = struct {
    /// Identity, so a system can be named — by a constraint later, by a profiler at M6, and
    /// by a mod that wants to replace one. `namespace:name`, like all content (I2).
    id: core.ContentId,
    /// The authored spelling of `id`. Copied at registration.
    name: []const u8,
    ctx: ?*anyopaque = null,
    update: *const fn (ctx: ?*anyopaque, world: *world_mod.World, tick: Tick) void,
};

// -- tests -------------------------------------------------------------------------

const std_testing = std.testing;
const data = @import("data");
const derive = @import("derive.zig");
const entity_mod = @import("entity.zig");

const Entity = entity_mod.Entity;
const World = world_mod.World;

const Pos = struct {
    pub const component = "test:pos";
    x: f32 = 0,
    y: f32 = 0,
};

const Vel = struct {
    pub const component = "test:vel";
    dx: f32 = 0,
    dy: f32 = 0,
};

const Fixture = struct {
    schemas: data.Registry,
    world: World,

    fn init(gpa: std.mem.Allocator) !*Fixture {
        const f = try gpa.create(Fixture);
        f.* = .{ .schemas = .init(gpa, .default), .world = undefined };
        f.world = .init(gpa, &f.schemas, .default);
        return f;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.world.deinit();
        self.schemas.deinit(gpa);
        gpa.destroy(self);
    }
};

/// Records the order systems ran in, and what tick they saw.
const Recorder = struct {
    order: std.ArrayList(u8) = .empty,
    ticks: std.ArrayList(u64) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *Recorder) void {
        self.order.deinit(self.gpa);
        self.ticks.deinit(self.gpa);
    }

    fn note(self: *Recorder, letter: u8, tick: u64) void {
        self.order.append(self.gpa, letter) catch unreachable;
        self.ticks.append(self.gpa, tick) catch unreachable;
    }
};

fn noteA(ctx: ?*anyopaque, _: *World, tick: Tick) void {
    const rec: *Recorder = @ptrCast(@alignCast(ctx.?));
    rec.note('a', tick.tick);
}

fn noteB(ctx: ?*anyopaque, _: *World, tick: Tick) void {
    const rec: *Recorder = @ptrCast(@alignCast(ctx.?));
    rec.note('b', tick.tick);
}

fn noteC(ctx: ?*anyopaque, _: *World, tick: Tick) void {
    const rec: *Recorder = @ptrCast(@alignCast(ctx.?));
    rec.note('c', tick.tick);
}

fn systemOf(id: []const u8, ctx: *Recorder, update: anytype) System {
    return .{
        .id = data.id.contentId(id) catch unreachable,
        .name = id,
        .ctx = ctx,
        .update = update,
    };
}

test "systems run in registration order, once per update" {
    const gpa = std_testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();

    _ = try f.world.registerSystem(systemOf("test:system.b", &rec, &noteB));
    _ = try f.world.registerSystem(systemOf("test:system.a", &rec, &noteA));
    _ = try f.world.registerSystem(systemOf("test:system.c", &rec, &noteC));

    f.world.update(.{ .tick = 1, .delta = .fromMillis(16) });
    f.world.update(.{ .tick = 2, .delta = .fromMillis(16) });

    // Registration order, not alphabetical and not the pool's — the schedule is kept
    // explicitly for exactly this reason.
    try std_testing.expectEqualSlices(u8, "bacbac", rec.order.items);
    try std_testing.expectEqualSlices(u64, &.{ 1, 1, 1, 2, 2, 2 }, rec.ticks.items);
    try std_testing.expectEqual(@as(u32, 3), f.world.systemCount());
}

test "a system is registered once, under an id that must exist" {
    const gpa = std_testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();

    const handle = try f.world.registerSystem(systemOf("test:system.a", &rec, &noteA));
    try std_testing.expectError(
        error.SystemExists,
        f.world.registerSystem(systemOf("test:system.a", &rec, &noteB)),
    );

    try std_testing.expectError(error.MissingSystemId, f.world.registerSystem(.{
        .id = .none,
        .name = "",
        .ctx = &rec,
        .update = &noteA,
    }));

    const found = f.world.findSystem(try data.id.contentId("test:system.a"));
    try std_testing.expect(found != null and found.?.eql(handle));
    try std_testing.expectEqual(@as(u32, 1), f.world.systemCount());
}

test "the system limit refuses" {
    const gpa = std_testing.allocator;
    const f = try Fixture.init(gpa);
    f.world.limits.max_systems = 1;
    defer f.deinit(gpa);

    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();

    _ = try f.world.registerSystem(systemOf("test:system.a", &rec, &noteA));
    try std_testing.expectError(
        error.SystemLimit,
        f.world.registerSystem(systemOf("test:system.b", &rec, &noteB)),
    );
}

/// Registers another system the first time it runs, to prove the schedule is not iterated
/// while it is being appended to.
const Spawner = struct {
    rec: *Recorder,
    done: bool = false,

    fn update(ctx: ?*anyopaque, world: *World, tick: Tick) void {
        const self: *Spawner = @ptrCast(@alignCast(ctx.?));
        self.rec.note('s', tick.tick);
        if (self.done) return;
        self.done = true;
        _ = world.registerSystem(systemOf("test:system.late", self.rec, &noteA)) catch unreachable;
    }
};

test "a system registered during update first runs on the next tick" {
    const gpa = std_testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    var spawner: Spawner = .{ .rec = &rec };

    _ = try f.world.registerSystem(.{
        .id = try data.id.contentId("test:system.spawner"),
        .name = "test:system.spawner",
        .ctx = &spawner,
        .update = &Spawner.update,
    });

    f.world.update(.{ .tick = 1, .delta = .fromMillis(16) });
    f.world.update(.{ .tick = 2, .delta = .fromMillis(16) });

    try std_testing.expectEqualSlices(u8, "ssa", rec.order.items);
}

/// Integrates velocity into position. The whole of a simulation, for the purpose of
/// showing that one runs the same way twice.
fn integrate(_: ?*anyopaque, world: *World, tick: Tick) void {
    const seconds: f32 = @floatFromInt(tick.delta.ns);
    const dt = seconds / 1_000_000_000.0;
    var it = world.queryOf(.{ Pos, Vel });
    while (it.next()) |m| {
        const p = m.get(Pos);
        const v = m.get(Vel);
        p.x += v.dx * dt;
        p.y += v.dy * dt;
    }
}

fn runScenario(gpa: std.mem.Allocator, out: *std.ArrayList(f32)) !void {
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const pos = try f.world.registerComponent(derive.componentType(Pos));
    const vel = try f.world.registerComponent(derive.componentType(Vel));
    _ = try f.world.registerSystem(.{
        .id = try data.id.contentId("test:system.integrate"),
        .name = "test:system.integrate",
        .update = &integrate,
    });

    // A fixed scenario: no clock, no global RNG, no wall time. Every input is written here.
    for (0..16) |i| {
        const e = try f.world.create();
        var p: Pos = .{ .x = @floatFromInt(i), .y = 0 };
        var v: Vel = .{ .dx = 1, .dy = @as(f32, @floatFromInt(i)) * 0.5 };
        _ = try f.world.addComponent(e, pos, std.mem.asBytes(&p));
        // Every third entity has no velocity, so the query actually has to skip some.
        if (i % 3 != 0) _ = try f.world.addComponent(e, vel, std.mem.asBytes(&v));
    }

    for (1..61) |t| f.world.update(.{ .tick = t, .delta = .fromMillis(16) });

    var it = f.world.query(&.{pos});
    while (it.next()) |_| {
        try out.append(gpa, @as(*const Pos, @ptrCast(@alignCast(it.bytes(0).ptr))).x);
    }
}

test "the same scenario run twice produces identical state" {
    const gpa = std_testing.allocator;

    var first: std.ArrayList(f32) = .empty;
    defer first.deinit(gpa);
    var second: std.ArrayList(f32) = .empty;
    defer second.deinit(gpa);

    try runScenario(gpa, &first);
    try runScenario(gpa, &second);

    // Not just equal values — equal in the same order, because iteration order is part of
    // what I9 is promising and a system's results are allowed to depend on it.
    try std_testing.expectEqual(@as(usize, 16), first.items.len);
    try std_testing.expectEqualSlices(f32, first.items, second.items);

    // And something actually moved, so the comparison is not of two empty runs.
    try std_testing.expect(first.items[1] != 1.0);
}
