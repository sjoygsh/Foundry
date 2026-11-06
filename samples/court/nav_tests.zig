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
const warden = @import("warden.zig");
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

// -- M33 Step 10: the warden sees and chases (`docs/design/agents.md` §11.2) ----------------------

/// A game in play with the player somewhere the warden is not looking.
fn hunted(env: *fixtures.TestEnv) !*game_mod.Game {
    const game = &env.game;
    try game.restart();
    try game.walk.teleport(.init(-4.5, 0.004, 7.5));
    return game;
}

/// Faces the warden along `x`, `z`, as if it had walked that way.
fn face(game: *game_mod.Game, x: f32, z: f32) void {
    game.warden.?.facing = .init(x, 0, z);
}

fn seesPlayer(game: *game_mod.Game) bool {
    const w = &game.warden.?;
    return w.sees(w.eye(), game.walk.eye(), game);
}

test "the warden sees ahead, within range, and not behind it, past its range or through the gate" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    const w = &game.warden.?;
    const s = w.settings.?;
    // It stands at (−2, 2.5), and the player is put round it.
    face(game, 1, 0);
    try game.walk.teleport(.init(1, 0.004, 2.5));
    try testing.expect(seesPlayer(game));
    // Inside the angle and outside it, at a distance.
    try game.walk.teleport(.init(1, 0.004, 4));
    try testing.expect(seesPlayer(game));
    try game.walk.teleport(.init(1, 0.004, 5.5));
    try testing.expect(!seesPlayer(game));
    // Behind it.
    face(game, -1, 0);
    try game.walk.teleport(.init(1, 0.004, 2.5));
    try testing.expect(!seesPlayer(game));
    // Beyond its range: on its own floor, straight ahead.
    face(game, 0, 1);
    try game.walk.teleport(.init(-2, 0.004, 2.5 + s.sight_range + 0.5));
    try testing.expect(!seesPlayer(game));
    // Over the low wall, which is below its eyes.
    face(game, 0, -1);
    try game.walk.teleport(.init(-2, 0.004, -0.5));
    try testing.expect(seesPlayer(game));
}

test "the gate hides the player, and open it does not" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    const from: core.math.Vec3 = .init(0, 1.5, -5);
    const to: core.math.Vec3 = .init(0, 1.5, -9);
    try testing.expect(!game.lineOfSight(from, to));
    // And the warden reads it: straight ahead, in range, and hidden.
    const w = &game.warden.?;
    _ = try game.walk.world.setCharacterFeet(gpa, w.character, .init(0, 0.004, -6));
    w.feet = .init(0, 0.004, -6);
    face(game, 0, -1);
    try game.walk.teleport(.init(0, 0.004, -8.6));
    try testing.expect(!seesPlayer(game));
    const g = &game.gate.?;
    g.progress = 1;
    g.current_pos = g.settings.open;
    _ = try game.walk.world.setPose(gpa, g.body, .{ .position = g.settings.open, .rotation = .identity });
    try testing.expect(seesPlayer(game));
}

test "seen, the warden chases at its chase speed and catches a player who stands" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    const w = &game.warden.?;
    face(game, 1, 0);
    w.wait_ticks = 0;
    try game.walk.teleport(.init(1.5, 0.004, 3));
    try game.step(.{}, fixtures.dt);
    try testing.expectEqual(warden.Mode.chasing, w.mode);
    var fastest: f32 = 0;
    var last = w.feet;
    for (0..600) |_| {
        try game.step(.{}, fixtures.dt);
        fastest = @max(fastest, w.feet.sub(last).length() / fixtures.dt);
        last = w.feet;
        if (game.phase != .playing) break;
    }
    try testing.expectEqual(game_mod.Phase.caught, game.phase);
    try testing.expectApproxEqAbs(w.settings.?.chase_speed, fastest, 0.1);
}

test "in a chase it runs, footfalls from the run, reaches when near, and heaves; the breath fades after" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    const w = &game.warden.?;
    const anim_mod = @import("anim");
    const run = anim_mod.clipName("run");
    const arms = &w.stack.layers[1];
    const breath = &w.stack.layers[2];
    face(game, 1, 0);
    w.wait_ticks = 0;
    try game.walk.teleport(.init(4, 0.004, 3));
    var ran_steps: u32 = 0;
    var far_ticks: u32 = 0;
    var reached = false;
    for (0..600) |_| {
        try game.step(.{}, fixtures.dt);
        if (game.phase != .playing) break;
        try testing.expectEqual(warden.Mode.chasing, w.mode);
        const body = w.body();
        if (body.channels[body.newest].clip == run) ran_steps += w.footfalls;
        const away = game.walk.result.feet.sub(w.feet).length();
        // Out of reach the arms stay down; within it they come up over their 0.3 s.
        if (away > w.settings.?.reach_distance + 0.1) {
            far_ticks += 1;
            try testing.expectEqual(@as(f32, 0), arms.target);
        } else if (arms.weight > 0) reached = true;
        // Winded from the chase's first tick, the breath coming in over 1.5 s.
        try testing.expectEqual(@as(f32, 1), breath.target);
    }
    try testing.expectEqual(game_mod.Phase.caught, game.phase);
    try testing.expect(far_ticks > 10 and reached);
    try testing.expect(ran_steps > 0);
    try testing.expect(breath.weight > 0);
    // The report names the layers and their states.
    const row = &w.report.rows[0];
    try testing.expect(row.machine);
    try testing.expectEqualStrings("arms", row.layers[1].label());
    try testing.expectEqualStrings("breath", row.layers[2].label());
    try testing.expectEqual(@as(u8, 5), row.param_count);

    // Out of sight, the chase ends, and the breath fades at a 1.5 s rate rather than at once.
    var again = try fixtures.TestEnv.init(gpa);
    defer again.deinit(gpa);
    const other = try hunted(&again);
    const v = &other.warden.?;
    face(other, 1, 0);
    v.wait_ticks = 0;
    try other.walk.teleport(.init(3.5, 0.004, 3));
    // A second of chase is two thirds of the way in.
    for (0..60) |_| try other.step(.{}, fixtures.dt);
    try testing.expectEqual(warden.Mode.chasing, v.mode);
    try testing.expectApproxEqAbs(@as(f32, 60 * fixtures.dt / 1.5), v.stack.layers[2].weight, 1e-4);
    try other.walk.teleport(.init(-5, 0.004, 7.5));
    while (v.mode == .chasing) try other.step(.{}, fixtures.dt);
    const held = v.stack.layers[2].weight;
    try other.step(.{}, fixtures.dt);
    try testing.expectApproxEqAbs(held - fixtures.dt / 1.5, v.stack.layers[2].weight, 1e-5);
    try testing.expectEqual(@as(f32, 0), v.stack.layers[2].target);
}

test "out of sight it goes to where it last saw the player, then back to its patrol" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    const w = &game.warden.?;
    face(game, 1, 0);
    w.wait_ticks = 0;
    try game.walk.teleport(.init(3.5, 0.004, 3));
    try game.step(.{}, fixtures.dt);
    try testing.expectEqual(warden.Mode.chasing, w.mode);
    const seen_at = w.last_seen;
    // The player is gone in a moment: behind the warden, far off.
    try game.walk.teleport(.init(-5, 0.004, 7.5));
    var saw_search = false;
    var searched_to = false;
    for (0..1500) |_| {
        try game.step(.{}, fixtures.dt);
        try testing.expectEqual(game_mod.Phase.playing, game.phase);
        if (w.mode == .searching) {
            saw_search = true;
            if (w.feet.sub(seen_at).length() < 0.3) searched_to = true;
        }
        if (saw_search and w.mode == .patrolling) break;
    }
    try testing.expect(saw_search and searched_to);
    try testing.expectEqual(warden.Mode.patrolling, w.mode);
    // Patrolling again, at its patrol speed, between its own waypoints.
    var fastest: f32 = 0;
    var last = w.feet;
    for (0..600) |_| {
        try game.step(.{}, fixtures.dt);
        fastest = @max(fastest, w.feet.sub(last).length() / fixtures.dt);
        last = w.feet;
    }
    try testing.expectApproxEqAbs(w.settings.?.speed, fastest, 0.05);
    try testing.expectApproxEqAbs(@as(f32, 2.5), w.feet.z, 0.1);
}

test "the warden follows a player it can see across the gap, by the jump, and does not fall" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    const w = &game.warden.?;
    w.wait_ticks = 0;
    try game.walk.teleport(.init(0.4, 0.004, -5));
    // At the gap's edge, facing the ledge, with the player in view across it.
    _ = try game.walk.world.setCharacterFeet(gpa, w.character, .init(0, 0.004, -1));
    w.feet = .init(0, 0.004, -1);
    game.crowd.?.place(w.agent, w.feet);
    face(game, 0, -1);
    var crossed = false;
    var lowest: f32 = 0;
    var top: f32 = 0;
    for (0..600) |_| {
        try game.step(.{}, fixtures.dt);
        lowest = @min(lowest, w.feet.y);
        top = @max(top, w.feet.y);
        if (game.crowd.?.agent(w.agent).?.state == .on_link) crossed = true;
        if (game.phase != .playing) break;
    }
    try testing.expect(crossed);
    try testing.expectEqual(game_mod.Phase.caught, game.phase);
    try testing.expect(w.feet.z < -3.2);
    try testing.expect(lowest > -0.1);
    try testing.expect(top > 0.4);
}

/// The warden at the gap with the player across it, for a run over the jump.
fn atTheGap(game: *game_mod.Game, gpa: std.mem.Allocator) !void {
    const w = &game.warden.?;
    w.wait_ticks = 0;
    try game.walk.teleport(.init(0.4, 0.004, -5));
    _ = try game.walk.world.setCharacterFeet(gpa, w.character, .init(0, 0.004, -1));
    w.feet = .init(0, 0.004, -1);
    game.crowd.?.place(w.agent, w.feet);
    face(game, 0, -1);
}

/// One run over the jump, at `speed` if given, with a replay beside it. Answers its ticks on the link.
fn overTheJump(gpa: std.mem.Allocator, speed: ?f32) !u32 {
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    var fresh = try fixtures.TestEnv.init(gpa);
    defer fresh.deinit(gpa);
    const game = try hunted(&env);
    const again = try hunted(&fresh);
    try atTheGap(game, gpa);
    try atTheGap(again, gpa);
    const w = &game.warden.?;
    if (speed) |v| {
        w.settings.?.chase_speed = v;
        again.warden.?.settings.?.chase_speed = v;
    }
    const jump = @import("anim").clipName("jump");
    const rig = game.rigs.?.get(w.rig).?;
    const duration = rig.find(jump).?.clip.duration;
    var ticks: u32 = 0;
    var landed: u32 = 0;
    var landed_tick: ?u32 = null;
    var n: u32 = 0;
    var was_crossing = false;
    var left_at: u32 = 0;
    while (n < 1800 and game.phase == .playing) : (n += 1) {
        try game.step(.{}, fixtures.dt);
        try again.step(.{}, fixtures.dt);
        try testing.expectEqualSlices(u8, std.mem.asBytes(&w.stack), std.mem.asBytes(&again.warden.?.stack));
        const view = game.crowd.?.agent(w.agent).?;
        const crossing = view.state == .on_link;
        if (crossing) {
            // The first tick fades in, so a clip never snaps on at the edge.
            if (ticks == 0) try testing.expect(w.stack.players[0].channels[w.stack.players[0].newest].weight < 1);
            ticks += 1;
            try testing.expect(w.stack.players[0].playing(jump));
            try testing.expectApproxEqAbs(view.link_t * duration, w.stack.players[0].seconds(rig.*, w.stack.players[0].newest), 1e-3);
            try testing.expectEqual(@as(u32, 0), w.footfalls);
        } else if (was_crossing) {
            left_at = n;
        }
        was_crossing = crossing;
        for (game.tickEvents()) |event| {
            if (event.kind != .warden_land) continue;
            landed += 1;
            landed_tick = n;
            try testing.expectEqual(w.feet, event.position);
        }
    }
    try testing.expect(ticks > 5);
    // One landing, on the tick the crowd let go of the crossing.
    try testing.expectEqual(@as(u32, 1), landed);
    try testing.expectEqual(left_at, landed_tick.?);
    try testing.expectEqual(@as(f32, 0), w.link);
    // After it, it walks again.
    try testing.expect(!w.stack.players[0].playing(jump));
    return ticks;
}

test "a crossing plays its clip at link_t, with no footfall, and lands once at its end, at any speed" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const usual = try overTheJump(gpa, null);
    const slow = try overTheJump(gpa, 0.5);
    try testing.expect(slow > usual * 2);
    // Far quicker than the clip: only finishing it by hand reaches its last moment.
    const quick = try overTheJump(gpa, 6);
    try testing.expect(quick * 2 < usual);
}

test "a link gone from under a crossing asks for no clip" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    try atTheGap(game, gpa);
    const w = &game.warden.?;
    const crowd = &game.crowd.?;
    while (crowd.agent(w.agent).?.state != .on_link) try game.step(.{}, fixtures.dt);
    try testing.expect(w.crossing(crowd) != null);
    var empty = crowd.mesh.?.*;
    empty.links = &.{};
    const real = crowd.mesh;
    crowd.mesh = &empty;
    defer crowd.mesh = real;
    try testing.expect(w.crossing(crowd) == null);
}

test "a restart forgets a crossing, and the machine's place with it" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    try atTheGap(game, gpa);
    const w = &game.warden.?;
    while (game.crowd.?.agent(w.agent).?.state != .on_link) try game.step(.{}, fixtures.dt);
    try game.step(.{}, fixtures.dt);
    try testing.expectEqual(@as(f32, 1), w.link);
    try testing.expectEqual(@import("anim").clipName("jump"), w.stack.layers[0].state);
    try game.restart();
    try testing.expectEqual(@as(f32, 0), w.link);
    // A cut to `idle`, with no state yet: the first tick takes the one that plays it.
    try testing.expectEqual(@as(u64, 0), w.stack.layers[0].state);
    try testing.expect(w.body().playing(warden.idle));
}

test "how far it has faded into a stride is part of the hash" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const w = &env.game.warden.?;
    while (w.walkWeight() == 0) try env.game.step(.{}, fixtures.dt);
    const before = env.game.hashTick();
    const channel = &w.stack.players[0].channels[w.stack.players[0].newest];
    channel.weight /= 2;
    try testing.expect(env.game.hashTick() != before);
}

test "what the warden is doing is part of the hash" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    const before = game.hashTick();
    game.warden.?.mode = .searching;
    try testing.expect(game.hashTick() != before);
}

test "with the gate shut it stops at the gate, and with it open it follows through" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    const w = &game.warden.?;
    const start: core.math.Vec3 = .init(0, 0.004, -5);
    const beyond: core.math.Vec3 = .init(0, 0.004, -8.6);

    // Shut: told to go beyond it, it gets to the gate and no further.
    _ = try game.walk.world.setCharacterFeet(gpa, w.character, start);
    w.feet = start;
    game.crowd.?.place(w.agent, start);
    w.wait_ticks = 100_000;
    _ = game.crowd.?.setSpeed(w.agent, 2.4);
    _ = game.crowd.?.setTarget(w.agent, beyond);
    for (0..300) |_| {
        game.crowd.?.step(fixtures.dt);
    }
    const stopped = game.crowd.?.agent(w.agent).?;
    try testing.expect(!stopped.complete);
    try testing.expect(stopped.position.z > -7.7);
    try testing.expect(stopped.position.z < -6.5);

    // Open: the same order reaches it.
    const g = &game.gate.?;
    g.current_pos = g.settings.open;
    const open = try env.meshes.add(try fixtures.buildMesh(gpa, &env.store, &env.assets, game));
    try game.step(.{ .navigation = open }, fixtures.dt);
    for (0..300) |_| game.crowd.?.step(fixtures.dt);
    const through = game.crowd.?.agent(w.agent).?;
    try testing.expect(through.complete);
    try testing.expect(through.position.z < -8);
}

test "cost: a path over the court's mesh, and a tick of the chase, single-threaded, printed" {
    if (comptime !options.available) return error.SkipZigTest;
    if (builtin.mode == .Debug) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const m = env.meshes.get(1).?;

    var query = try nav.Query.init(gpa, 1024);
    defer query.deinit();
    var steps: [256]nav.Step = undefined;
    var corners: [32]nav.Corner = undefined;
    const filter: nav.Filter = .{};
    var path_ns: [512]u64 = undefined;
    var prng = std.Random.DefaultPrng.init(9);
    const r = prng.random();
    var keep: usize = 0;
    var n: usize = 0;
    while (n < path_ns.len) {
        const a = m.locate(.init(r.float(f32) * 11 - 5.5, 0, r.float(f32) * 9.5 - 1.8), .init(0.05, 0.3, 0.05)) orelse continue;
        const b = m.locate(.init(r.float(f32) * 11 - 5.5, 0, r.float(f32) * 13 - 7.3), .init(0.05, 0.3, 0.05)) orelse continue;
        const start = std.Io.Clock.awake.now(testing.io);
        const path = query.find(m, &filter, a, b, &steps);
        keep += nav.corners(m, steps[0..path.count], a.point, path.end, &corners).len;
        path_ns[n] = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
        n += 1;
    }
    std.mem.sort(u64, &path_ns, {}, std.sort.asc(u64));

    // A whole tick of the game during a chase is an upper bound on what the warden adds.
    const game = try hunted(&env);
    const w = &game.warden.?;
    face(game, 1, 0);
    w.wait_ticks = 0;
    try game.walk.teleport(.init(4, 0.004, 3));
    var tick_ns: [200]u64 = undefined;
    for (&tick_ns) |*t| {
        // Kept ahead of it, so that it chases and never catches.
        try game.walk.teleport(w.feet.add(.init(2.5, 0.2, 0.3)).add(.init(0, -0.196 - w.feet.y, 0)));
        const start = std.Io.Clock.awake.now(testing.io);
        try game.step(.{}, fixtures.dt);
        t.* = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
    }
    try testing.expectEqual(warden.Mode.chasing, w.mode);
    std.mem.sort(u64, &tick_ns, {}, std.sort.asc(u64));
    const path_p95 = @as(f64, @floatFromInt(path_ns[486])) / 1e3;
    const tick_p95 = @as(f64, @floatFromInt(tick_ns[190])) / 1e6;
    std.debug.print("court: {d} polygons, path p95 {d:.1} us; a chase tick p95 {d:.3} ms, worst {d:.3} ms ({d})\n", .{ m.polygons.len, path_p95, tick_p95, @as(f64, @floatFromInt(tick_ns[199])) / 1e6, keep });
    try testing.expect(path_p95 < 50);
}

test "the warden's feet keep up with its body, on patrol and in a chase" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = try hunted(&env);
    const w = &game.warden.?;
    const stride = @import("anim").clipName("stride");
    const run = @import("anim").clipName("run");
    const rig = game.rigs.?.get(w.rig).?;
    // Its rig's own ground speed, and what each tick's channel asks of it.
    try testing.expectApproxEqAbs(@as(f32, 0.6), w.stride_speed, 1e-5);
    var patrol: u32 = 0;
    var chase: u32 = 0;
    face(game, 1, 0);
    w.wait_ticks = 0;
    for (0..400) |n| {
        // First left to walk its patrol, then seen, then kept ahead of it.
        if (n >= 200) try game.walk.teleport(w.feet.add(.init(2.5, 0.2, 0.3)).add(.init(0, -0.196 - w.feet.y, 0)));
        const was = w.feet;
        try game.step(.{}, fixtures.dt);
        // Walk or run, whichever leads, at the rate its own travel asks. A rate past ±16 is the
        // machine's to clamp (`machine_tests.zig`).
        const body = w.body();
        const channel = body.channels[body.newest];
        if (channel.clip != stride and channel.clip != run) continue;
        var moved = w.feet.sub(was);
        moved.y = 0;
        if (moved.length() == 0) continue;
        const rate = moved.length() / fixtures.dt;
        try testing.expectApproxEqAbs(rate, channel.speed * rig.motionSpeed(channel.clip), 1e-4);
        if (rate > 2.3) {
            chase += 1;
            // A chase runs, and a patrol walks.
            try testing.expectEqual(run, channel.clip);
        } else if (rate > 0.9 and rate < 1.6) {
            patrol += 1;
            try testing.expectEqual(stride, channel.clip);
        }
    }
    try testing.expect(chase > 50 and patrol > 20);
}

test "a replay plays the same player on the same ticks, and only events make a warden_step" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    var fresh = try fixtures.TestEnv.initPlaying(gpa);
    defer fresh.deinit(gpa);
    var steps: u32 = 0;
    var stood: u32 = 0;
    // It begins on `idle`, before a tick.
    try testing.expect(env.game.warden.?.stack.players[0].playing(warden.idle));
    const stride = @import("anim").clipName("stride");
    var first_stride = true;
    for (0..600) |_| {
        const was = env.game.warden.?.feet;
        const held = env.game.warden.?.stack.players[0].seconds(env.game.rigs.?.get(env.game.warden.?.rig).?.*, env.game.warden.?.stack.players[0].newest);
        try env.game.step(.{}, fixtures.dt);
        try fresh.game.step(.{}, fixtures.dt);
        const w = &env.game.warden.?;
        const r = &fresh.game.warden.?;
        if (w.feet.x == was.x and w.feet.z == was.z) {
            try testing.expect(w.stack.players[0].playing(warden.idle));
            stood += 1;
        } else if (first_stride) {
            // It takes up the time it stood at, so a pause never restarts a foot.
            try testing.expect(w.stack.players[0].playing(stride));
            try testing.expectApproxEqAbs(held, w.stack.players[0].channels[w.stack.players[0].newest].anchor, 1e-3);
            try testing.expect(held > 0.1);
            first_stride = false;
        }
        try testing.expectEqualSlices(u8, std.mem.asBytes(&w.stack), std.mem.asBytes(&r.stack));
        var heard: u32 = 0;
        for (env.game.tickEvents()) |event| {
            if (event.kind != .warden_step) continue;
            heard += 1;
            try testing.expectEqual(w.feet, event.position);
        }
        try testing.expectEqual(w.footfalls, heard);
        try testing.expectEqual(@as(u32, 1), w.report.players);
        try testing.expectEqualStrings("warden", w.report.rows[0].label());
        steps += heard;
    }
    // Two a lap, at the 1.67 laps a second its 1 m/s asks for, in the time it spends walking.
    try testing.expect(steps >= 20 and stood > 60);
}

test "a warden with no rig plays the same game, in silence, undrawn" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    var silent = try fixtures.TestEnv.initPlaying(gpa);
    defer silent.deinit(gpa);
    const w = &silent.game.warden.?;
    w.stride_speed = 0;
    w.stack = .{};
    for (0..300) |_| {
        try env.game.step(.{}, fixtures.dt);
        try silent.game.step(.{}, fixtures.dt);
        try testing.expectEqual(env.game.warden.?.feet, w.feet);
        try testing.expectEqual(env.game.walk.result.feet, silent.game.walk.result.feet);
        try testing.expectEqual(@as(u32, 0), w.footfalls);
    }
    w.evaluate(if (silent.game.rigs) |*r| r else null);
    try testing.expectEqual(@as(usize, 0), w.joint_count);
    const posed = &env.game.warden.?;
    posed.evaluate(if (env.game.rigs) |*r| r else null);
    try testing.expectEqual(@as(usize, 19), posed.joint_count);
    // One that loses its rig stops drawing what it had.
    posed.stride_speed = 0;
    posed.evaluate(if (env.game.rigs) |*r| r else null);
    try testing.expectEqual(@as(usize, 0), posed.joint_count);
}

test "a content change rebuilds the warden's rig before a tick, and a set that stops building leaves it patrolling" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    // A `TestEnv` was moved after its registry was made.
    env.assets.store = &env.store;
    const game = &env.game;
    const w = &game.warden.?;
    for (0..100) |_| try game.step(.{}, fixtures.dt);
    // A real reload replaces what the rig borrows, and the seam is what makes it safe to read.
    try testing.expect(env.assets.reloadAll(gpa) > 0);
    try game.contentChanged(&env.assets);
    w.evaluate(if (game.rigs) |*r| r else null);
    try testing.expectEqual(@as(usize, 19), w.joint_count);
    try testing.expectApproxEqAbs(@as(f32, 0.6), w.stride_speed, 1e-5);
    for (0..10) |_| try game.step(.{}, fixtures.dt);

    // A set that no longer says anything of `stride` moving.
    const held = game.rigs.?.get(w.rig).?;
    const entry = @constCast(held.find(@import("anim").clipName("stride")).?);
    entry.motion = false;
    w.bind(&game.rigs.?);
    try testing.expectEqual(@as(f32, 0), w.stride_speed);
    entry.motion = true;
    const idle = @constCast(held.find(warden.idle).?);
    const name = idle.name;
    idle.name +%= 1;
    w.bind(&game.rigs.?);
    try testing.expectEqual(@as(f32, 0), w.stride_speed);
    idle.name = name;
    // A machine that did not build leaves it unanimated too, as `bind` says.
    const machine = w.machine;
    w.machine = .none;
    w.bind(&game.rigs.?);
    try testing.expectEqual(@as(f32, 0), w.stride_speed);
    w.machine = machine;
    w.bind(&game.rigs.?);
    try testing.expect(w.stride_speed > 0);
    w.stride_speed = 0;
    for (0..10) |_| try game.step(.{}, fixtures.dt);
    try testing.expectEqual(@as(u32, 0), w.footfalls);
    try game.contentChanged(&env.assets);
    try testing.expect(w.stride_speed > 0);

    // Only a footfall is a footstep, whatever else a set names.
    const walked = game.rigs.?.get(w.rig).?.find(@import("anim").clipName("stride")).?;
    for (walked.events) |*event| @constCast(event).id = core.ContentId.fromString("court:event.other");
    for (0..300) |_| {
        try game.step(.{}, fixtures.dt);
        try testing.expectEqual(@as(u32, 0), w.footfalls);
    }
}

test "a warden's record has to name a set" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try fixtures.TestEnv.init(gpa);
    defer env.deinit(gpa);
    // On the title screen too, with no game begun.
    try testing.expect(env.game.warden.?.stack.players[0].playing(warden.idle));
    const fields = env.store.lookup(core.ContentId.fromString("court:warden.main")).?.fields;
    const settings = try warden.WardenSettings.read(fields);
    try testing.expect(settings.set.eql(core.ContentId.fromString("court:warden.set")));
    const copied = try gpa.dupe(u8, fields.block);
    defer gpa.free(copied);
    var edited = fields;
    edited.block = copied;
    // The presence bits, then the three IDs: a set and a machine are each required.
    @memset(copied[16..24], 0);
    try testing.expectError(error.InvalidWarden, warden.WardenSettings.read(edited));
    @memcpy(copied, fields.block);
    @memset(copied[24..32], 0);
    try testing.expectError(error.InvalidWarden, warden.WardenSettings.read(edited));
    try testing.expect(settings.machine.eql(core.ContentId.fromString("court:warden.machine")));
}
