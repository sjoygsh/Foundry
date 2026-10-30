//! M32 Step 7 (`docs/design/navigation.md` §9.2): the warden's navigation mesh from the compiled
//! court, checked against the level `scripts/m26/make_court.py` builds: the court floor over
//! z −2 to 8, the 1.2 m gap to z −3.2 with the pit floor 4.5 m down, the ledge beyond it, and
//! the 0.65 m low wall over x −5 to −1 at z 1.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const nav = @import("nav");
const platform = @import("platform");
const nav_mod = @import("nav.zig");
const game_mod = @import("game.zig");
const walk = @import("walk.zig");
const fixtures = @import("game_tests.zig");
const options = @import("court_test_options");
const testing = std.testing;

const Level = struct {
    os: *platform.os.Os,
    schemas: data.Registry,
    store: data.Store,
    assets: asset.Registry,
    base: []u8,
    bytes: []u8,

    fn init(self: *Level) !void {
        const gpa = testing.allocator;
        self.os = try platform.os.Os.init(gpa, .{});
        self.schemas = .init(gpa, .default);
        try asset.schemas.registerAll(gpa, &self.schemas);
        try asset.nav_mesh.registerAll(gpa, &self.schemas);
        var diags: data.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);
        self.store = .init(gpa, .default);
        self.base = try self.os.readFile(gpa, options.core_package, 16 * 1024 * 1024);
        _ = try self.store.add(gpa, "foundry:core", self.base, &self.schemas, &diags);
        self.bytes = try self.os.readFile(gpa, options.package, 16 * 1024 * 1024);
        const package = try self.store.add(gpa, "court:content", self.bytes, &self.schemas, &diags);
        self.assets = asset.Registry.init(gpa, self.os, &self.store, .{});
        try self.assets.mount(gpa, package, options.generated);
        try self.assets.registerLoader(gpa, asset.collisionMeshLoader());
    }

    fn deinit(self: *Level) void {
        const gpa = testing.allocator;
        self.assets.deinit(gpa);
        self.store.deinit(gpa);
        self.schemas.deinit(gpa);
        gpa.free(self.bytes);
        gpa.free(self.base);
        self.os.deinit();
    }

    fn build(self: *Level) !nav.Mesh {
        const gpa = testing.allocator;
        var sources: std.ArrayList(nav.Source) = .empty;
        defer sources.deinit(gpa);
        var held: std.ArrayList(asset.AssetHandle) = .empty;
        defer {
            for (held.items) |h| self.assets.release(h);
            held.deinit(gpa);
        }
        var features: nav_mod.Features = .{};
        const config = try nav_mod.gather(gpa, &self.store, &self.assets, &sources, &held, &features);
        return nav.buildWith(gpa, config, sources.items, features.view());
    }
};

fn on(m: *const nav.Mesh, x: f32, y: f32, z: f32) ?nav.Located {
    return m.locate(.init(x, y, z), .init(0.05, 0.15, 0.05));
}

/// Whether polygon `to` is reachable from `from` by links.
fn joined(m: *const nav.Mesh, from: u32, to: u32) !bool {
    const seen = try testing.allocator.alloc(bool, m.polygons.len);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(testing.allocator);
    try stack.append(testing.allocator, from);
    seen[from] = true;
    while (stack.pop()) |p| {
        if (p == to) return true;
        for (m.polygons[p].neighbours[0..m.polygons[p].count]) |q| {
            if (q == nav.none_polygon or seen[q]) continue;
            seen[q] = true;
            try stack.append(testing.allocator, q);
        }
    }
    return false;
}

test "court navigation: the warden's waypoints and the spawn are one island; the gap, the pit and the low wall are not on it" {
    if (comptime !options.available) return error.SkipZigTest;
    var level: Level = undefined;
    try level.init();
    defer level.deinit();
    var m = try level.build();
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), m.skipped);

    // `court:warden.main`'s two waypoints and `court:rules.main`'s spawn.
    const west = on(&m, -2, 0, 2.5) orelse return error.WaypointNotOnMesh;
    const east = on(&m, 2, 0, 2.5) orelse return error.WaypointNotOnMesh;
    const spawn = on(&m, 0, 0, 5) orelse return error.SpawnNotOnMesh;
    try testing.expect(try joined(&m, spawn.polygon, west.polygon));
    try testing.expect(try joined(&m, spawn.polygon, east.polygon));

    // The gap has no floor at the court's height.
    try testing.expect(on(&m, 0, 0, -2.6) == null);
    // The pit's floor is walkable, and an island of its own.
    const pit = on(&m, 0, -4.5, -2.6) orelse return error.PitNotOnMesh;
    try testing.expect(!try joined(&m, spawn.polygon, pit.polygon));
    // The ledge is across the gap: the warden, who cannot jump, cannot reach it.
    const ledge = on(&m, 0, 0, -5) orelse return error.LedgeNotOnMesh;
    try testing.expect(!try joined(&m, spawn.polygon, ledge.polygon));

    // The low wall is higher than the warden's climb and too thin to stand on: nothing at its
    // middle at any height up to its top, though the floor either side is joined round its ends.
    try testing.expect(m.locate(.init(-3, 0.3, 1), .init(0.05, 0.4, 0.05)) == null);
    const south = on(&m, -3, 0, 1.6) orelse return error.FloorNotOnMesh;
    const north = on(&m, -3, 0, 0.4) orelse return error.FloorNotOnMesh;
    try testing.expect(try joined(&m, south.polygon, north.polygon));
}

test "court navigation: the warden's level builds within criterion 5, single-threaded, printed" {
    if (comptime !options.available) return error.SkipZigTest;
    if (builtin.mode == .Debug) return error.SkipZigTest;
    var level: Level = undefined;
    try level.init();
    defer level.deinit();
    var best: u64 = std.math.maxInt(u64);
    var polygons: usize = 0;
    for (0..5) |_| {
        const start = std.Io.Clock.awake.now(testing.io);
        var m = try level.build();
        const ns: u64 = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
        polygons = m.polygons.len;
        m.deinit(testing.allocator);
        best = @min(best, ns);
    }
    const ms = @as(f64, @floatFromInt(best)) / 1e6;
    std.debug.print("court navigation build ({t}): {d:.2} ms, {d} polygons\n", .{ builtin.mode, ms, polygons });
    try testing.expect(ms <= 50);
}

// -- M33 Step 9: the warden on the mesh (`docs/design/agents.md` §9, §11.2) ------------------------

/// Whether a path of polygons runs between two points on `m`.
fn pathBetween(m: *const nav.Mesh, a: nav.Located, b: nav.Located) !bool {
    var query = try nav.Query.init(testing.allocator, 1024);
    defer query.deinit();
    var steps: [256]nav.Step = undefined;
    const filter: nav.Filter = .{};
    return query.find(m, &filter, a, b, &steps).complete;
}

const ledge_point: [3]f32 = .{ 0, 0, -6 };
const exit_point: [3]f32 = .{ 0, 0, -8.6 };

test "the gate shut cuts the exit from the ledge, and open joins them" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    const shut = env.meshes.get(1).?;
    const a = on(shut, ledge_point[0], ledge_point[1], ledge_point[2]) orelse return error.LedgeNotOnMesh;
    const b = on(shut, exit_point[0], exit_point[1], exit_point[2]) orelse return error.ExitNotOnMesh;
    try testing.expect(!try pathBetween(shut, a, b));
    const g = &game.gate.?;
    g.current_pos = g.settings.open;
    var open = try fixtures.buildMesh(gpa, &env.store, &env.assets, game);
    defer open.deinit(gpa);
    const c = on(&open, ledge_point[0], ledge_point[1], ledge_point[2]).?;
    const d = on(&open, exit_point[0], exit_point[1], exit_point[2]).?;
    try testing.expect(try pathBetween(&open, c, d));
    try testing.expectEqual(shut.islands, open.islands + 1);
}

test "with no mesh the warden stands, and the game plays on" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    game.meshes = null;
    if (game.crowd) |*c| c.mesh = null;
    const w = &game.warden.?;
    const start = w.feet;
    try game.walk.teleport(.init(4.5, 0.004, 6.5));
    for (0..300) |_| try game.step(.{}, fixtures.dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    try testing.expectApproxEqAbs(start.x, w.feet.x, 1e-3);
}

/// A run in which the gate opens at `open_tick`, and the open mesh is adopted `late` ticks after
/// the gate came to rest, as a build's arrival would decide. Answers each tick's hash.
fn gateRun(env: *fixtures.TestEnv, open_generation: u32, late: u32, ticks: u32, inputs: []u32, hashes: []u64) !void {
    const game = &env.game;
    try game.restart();
    try game.walk.teleport(.init(4.5, 0.004, 6.5));
    for (game.beacons[0..game.beacon_count]) |*b| b.lit = true;
    game.gate.?.opening = true;
    var owed: ?u32 = null;
    for (0..ticks) |t| {
        var intent: walk.Intent = .{};
        if (owed) |left| {
            if (left == 0) {
                intent.navigation = open_generation;
                owed = null;
            } else owed = left - 1;
        }
        inputs[t] = intent.navigation;
        try game.step(intent, fixtures.dt);
        if (game.gate_rested) owed = late;
        hashes[t] = game.hashTick();
    }
}

test "the open gate's mesh arrives as an input: each run replays, and restart goes back to the first" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const g = &env.game.gate.?;
    const closed = g.current_pos;
    g.current_pos = g.settings.open;
    const open_generation = try env.meshes.add(try fixtures.buildMesh(gpa, &env.store, &env.assets, &env.game));
    g.current_pos = closed;
    try testing.expectEqual(@as(u32, 2), open_generation);

    const ticks = 300;
    var first: [ticks]u64 = undefined;
    var again: [ticks]u64 = undefined;
    var later: [ticks]u64 = undefined;
    var inputs: [ticks]u32 = undefined;
    for ([_]u32{ 1, 37 }) |late| {
        try gateRun(&env, open_generation, late, ticks, &inputs, &first);
        try testing.expectEqual(open_generation, env.game.generation);
        // The replay: the same inputs into a fresh game, reading the same meshes.
        var fresh = try fixtures.TestEnv.init(gpa);
        defer fresh.deinit(gpa);
        fresh.game.meshes = env.meshes;
        try fresh.game.restart();
        try fresh.game.walk.teleport(.init(4.5, 0.004, 6.5));
        for (fresh.game.beacons[0..fresh.game.beacon_count]) |*b| b.lit = true;
        fresh.game.gate.?.opening = true;
        for (0..ticks) |t| {
            try fresh.game.step(.{ .navigation = inputs[t] }, fixtures.dt);
            again[t] = fresh.game.hashTick();
        }
        try testing.expectEqualSlices(u64, &first, &again);
    }
    // A different arrival is a different input, and a different run.
    try gateRun(&env, open_generation, 1, ticks, &inputs, &later);
    try testing.expect(later[ticks - 1] != first[ticks - 1]);
    // Restart: the gate is shut, and the mesh is the first again, with no build.
    try env.game.restart();
    try testing.expectEqual(@as(u32, 1), env.game.generation);
}

test "the frame's generation waits for a tick: a frame with none keeps it for the next" {
    var pending: walk.Pending = .{};
    pending.feed(.{ .navigation = 2 });
    pending.feed(.{});
    try testing.expectEqual(@as(u32, 2), pending.take().navigation);
    pending.feed(.{});
    try testing.expectEqual(@as(u32, 0), pending.take().navigation);
}

test "Play waits for the first mesh" {
    const gpa = testing.allocator;
    var navigation = nav_mod.Navigation.init(gpa);
    defer navigation.deinit(core.tasks.immediate, null, null);
    try testing.expect(!navigation.ready);
    // Nothing built yet, and nothing owed for the first mesh: Play adopts that itself.
    try testing.expectEqual(@as(u32, 0), navigation.takeOwed());
    navigation.off = true;
    navigation.request(core.tasks.immediate, undefined, undefined, null, 1);
    try testing.expect(navigation.ready);
}

test "the gate's two meshes: built once, reused, and left unadopted if a restart shut the gate" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    var manual = try core.tasks.Manual.init(gpa, 4);
    defer manual.deinit();
    var navigation = nav_mod.Navigation.init(gpa);
    defer navigation.deinit(manual.tasks(), null, null);
    const g = &env.game.gate.?;
    const shut: nav_mod.GateBox = .{ .half_extents = g.settings.half_extents, .position = g.settings.closed };
    const open: nav_mod.GateBox = .{ .half_extents = g.settings.half_extents, .position = g.settings.open };

    // Before the first mesh there is nothing to wait for, and nothing is owed.
    navigation.gateOpened(manual.tasks(), &env.store, &env.assets, open, 0);
    try testing.expectEqual(@as(u32, 0), manual.pending());
    navigation.request(manual.tasks(), &env.store, &env.assets, shut, 0);
    try testing.expect(!navigation.ready);
    navigation.pump(1, 0, false);
    try testing.expect(!navigation.ready);
    manual.runNext();
    navigation.pump(2, 0, false);
    try testing.expect(navigation.ready);
    try testing.expectEqual(@as(u32, 0), navigation.takeOwed());
    navigation.noteAdopted(1);

    // The first opening builds, and a restart before it lands keeps the mesh and adopts nothing.
    navigation.gateOpened(manual.tasks(), &env.store, &env.assets, open, 0);
    try testing.expectEqual(@as(u32, 1), manual.pending());
    manual.runNext();
    navigation.pump(3, 0, false);
    try testing.expectEqual(@as(u32, 0), navigation.takeOwed());
    try testing.expectEqual(@as(u32, 2), navigation.open_generation);

    // The second opening builds nothing, and owes it at once.
    navigation.gateOpened(manual.tasks(), &env.store, &env.assets, open, 0);
    try testing.expectEqual(@as(u32, 0), manual.pending());
    try testing.expectEqual(@as(u32, 2), navigation.takeOwed());
    try testing.expectEqual(@as(u32, 0), navigation.takeOwed());

    // The gate's box reached each build.
    const first = navigation.meshes.get(1).?;
    const second = navigation.meshes.get(2).?;
    try testing.expectEqual(first.islands, second.islands + 1);
    try testing.expectEqual(@as(u32, 2), navigation.meshes.rebuilds);
}

test "the warden's agent follows its body: the controller has the last word" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    try game.walk.teleport(.init(4.5, 0.004, 6.5));
    const w = &game.warden.?;
    for (0..90) |_| try game.step(.{}, fixtures.dt);
    // Something moves the body, as a push would.
    const pushed: core.math.Vec3 = .init(w.feet.x + 0.5, w.feet.y, w.feet.z + 0.5);
    _ = try game.walk.world.setCharacterFeet(gpa, w.character, pushed);
    w.feet = pushed;
    try game.step(.{}, fixtures.dt);
    const view = game.crowd.?.agent(w.agent).?;
    try testing.expectApproxEqAbs(w.feet.x, view.position.x, 1e-3);
    try testing.expectApproxEqAbs(w.feet.z, view.position.z, 1e-3);
}

test "the adopted generation is part of the hash" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    // The same mesh twice: only the number differs, so only the hash's own field can tell.
    const same = try env.meshes.add(try fixtures.buildMesh(gpa, &env.store, &env.assets, &env.game));
    var other = try fixtures.TestEnv.initPlaying(gpa);
    defer other.deinit(gpa);
    try testing.expectEqual(env.game.hashTick(), other.game.hashTick());
    other.game.meshes = env.meshes;
    env.game.generation = same;
    try testing.expect(env.game.hashTick() != other.game.hashTick());
}
