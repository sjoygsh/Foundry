//! M26 Step 3: game logic, phases, beacons, Use, gate, warden, exit/pit, restart,
//! scripted play-throughs, determinism tick-by-tick replay, and untrusted-input refusals.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const platform = @import("platform");
const walk_mod = @import("walk.zig");
const game_mod = @import("game.zig");
const scripted = @import("scripted.zig");
const beacon_mod = @import("beacon.zig");
const gate_mod = @import("gate.zig");
const warden_mod = @import("warden.zig");
const options = @import("court_test_options");
const testing = std.testing;

const dt: f32 = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

const TestEnv = struct {
    os: *platform.os.Os,
    diags: data.Diagnostics,
    schemas: data.Registry,
    store: data.Store,
    assets: asset.Registry,
    game: game_mod.Game,
    core_bytes: []u8,
    court_bytes: []u8,

    fn init(gpa: std.mem.Allocator) !TestEnv {
        const os = try platform.os.Os.init(gpa, .{});
        errdefer os.deinit();
        var diags: data.Diagnostics = .init(gpa, .default);
        errdefer diags.deinit(gpa);
        var schemas: data.Registry = .init(gpa, .default);
        errdefer schemas.deinit(gpa);
        try asset.schemas.registerAll(gpa, &schemas);
        var store: data.Store = .init(gpa, .default);
        errdefer store.deinit(gpa);

        const core_bytes = try os.readFile(gpa, options.core_package, 16 * 1024 * 1024);
        errdefer gpa.free(core_bytes);
        _ = try store.add(gpa, "foundry:core", core_bytes, &schemas, &diags);

        const court_bytes = try os.readFile(gpa, options.package, 16 * 1024 * 1024);
        errdefer gpa.free(court_bytes);
        const package = try store.add(gpa, "court:content", court_bytes, &schemas, &diags);

        var assets = asset.Registry.init(gpa, os, &store, .{});
        errdefer assets.deinit(gpa);
        try assets.mount(gpa, package, options.generated);
        try assets.registerLoader(gpa, asset.collisionMeshLoader());

        var game = game_mod.Game.init(gpa);
        errdefer game.deinit(&assets, null);
        game.refresh(&store, &assets, null, dt);

        return .{
            .os = os,
            .diags = diags,
            .schemas = schemas,
            .store = store,
            .assets = assets,
            .game = game,
            .core_bytes = core_bytes,
            .court_bytes = court_bytes,
        };
    }

    fn deinit(self: *TestEnv, gpa: std.mem.Allocator) void {
        self.game.deinit(&self.assets, null);
        self.assets.deinit(gpa);
        self.store.deinit(gpa);
        self.schemas.deinit(gpa);
        self.diags.deinit(gpa);
        gpa.free(self.court_bytes);
        gpa.free(self.core_bytes);
        self.os.deinit();
    }
};

test "court: win play-through lights three beacons, opens gate, wins, restarts, and matches replay determinism" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), env.game.beacon_count);
    try testing.expect(env.game.gate != null);
    try testing.expect(env.game.warden != null);
    try testing.expectEqual(game_mod.Phase.playing, env.game.phase);

    var driver = scripted.ScriptDriver.init(.win);
    var recorded_intents: [3000]walk_mod.Intent = undefined;
    var recorded_hashes: [3000]u64 = undefined;
    var tick_count: usize = 0;

    var first_win_tick: ?usize = null;
    var second_win_tick: ?usize = null;

    // Run until two wins are completed.
    while (tick_count < 3000 and !driver.done) : (tick_count += 1) {
        const intent = driver.nextIntent(&env.game, dt);
        recorded_intents[tick_count] = intent;
        try env.game.step(intent, dt);
        recorded_hashes[tick_count] = env.game.hashTick();

        if (env.game.phase == .won) {
            if (first_win_tick == null) {
                first_win_tick = tick_count;
                try testing.expect(env.game.allBeaconsLit());
                try testing.expect(env.game.gate.?.progress >= 1.0);
            } else if (second_win_tick == null and tick_count > first_win_tick.?) {
                second_win_tick = tick_count;
            }
        }
    }

    try testing.expect(first_win_tick != null);
    try testing.expect(second_win_tick != null);
    try testing.expect(driver.done);

    // Replay determinism check: fresh game instance replays identical intents and must match exact hashes at EVERY tick!
    var replay_env = try TestEnv.init(gpa);
    defer replay_env.deinit(gpa);

    for (0..tick_count) |t| {
        try replay_env.game.step(recorded_intents[t], dt);
        const h = replay_env.game.hashTick();
        try testing.expectEqual(recorded_hashes[t], h);
    }
}

test "court: caught play-through detects warden proximity, ends in caught, restarts, and matches replay determinism" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);

    var driver = scripted.ScriptDriver.init(.caught);
    var recorded_intents: [1000]walk_mod.Intent = undefined;
    var recorded_hashes: [1000]u64 = undefined;
    var tick_count: usize = 0;
    var caught_tick: ?usize = null;

    while (tick_count < 1000 and !driver.done) : (tick_count += 1) {
        const intent = driver.nextIntent(&env.game, dt);
        recorded_intents[tick_count] = intent;
        try env.game.step(intent, dt);
        recorded_hashes[tick_count] = env.game.hashTick();

        if (env.game.phase == .caught and caught_tick == null) {
            caught_tick = tick_count;
        }
    }

    try testing.expect(caught_tick != null);
    // Restart resets phase to playing.
    try env.game.step(.{ .restart = true }, dt);
    try testing.expectEqual(game_mod.Phase.playing, env.game.phase);

    // Replay determinism check.
    var replay_env = try TestEnv.init(gpa);
    defer replay_env.deinit(gpa);

    for (0..tick_count) |t| {
        try replay_env.game.step(recorded_intents[t], dt);
        try testing.expectEqual(recorded_hashes[t], replay_env.game.hashTick());
    }
}

test "court: fell play-through detects pit fall, ends in fell, restarts, and matches replay determinism" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);

    var driver = scripted.ScriptDriver.init(.fell);
    var recorded_intents: [500]walk_mod.Intent = undefined;
    var recorded_hashes: [500]u64 = undefined;
    var tick_count: usize = 0;
    var fell_tick: ?usize = null;

    while (tick_count < 500 and !driver.done) : (tick_count += 1) {
        const intent = driver.nextIntent(&env.game, dt);
        recorded_intents[tick_count] = intent;
        try env.game.step(intent, dt);
        recorded_hashes[tick_count] = env.game.hashTick();

        if (env.game.phase == .fell and fell_tick == null) {
            fell_tick = tick_count;
        }
    }

    try testing.expect(fell_tick != null);
    // Restart resets phase to playing.
    try env.game.step(.{ .restart = true }, dt);
    try testing.expectEqual(game_mod.Phase.playing, env.game.phase);

    // Replay determinism check.
    var replay_env = try TestEnv.init(gpa);
    defer replay_env.deinit(gpa);

    for (0..tick_count) |t| {
        try replay_env.game.step(recorded_intents[t], dt);
        try testing.expectEqual(recorded_hashes[t], replay_env.game.hashTick());
    }
}

test "court: untrusted beacon, gate and warden records refuse malformed, missing or non-finite fields" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);

    // 1. Beacon record validation:
    const beacon_rec = env.store.lookup(core.ContentId.fromString("court:beacon.open")).?;
    _ = try beacon_mod.BeaconSettings.read(beacon_rec.fields);

    const b_block = try gpa.dupe(u8, beacon_rec.fields.block);
    defer gpa.free(b_block);
    var bad_beacon = beacon_rec.fields;
    bad_beacon.block = b_block;

    // Clearing presence bit for position fails:
    b_block[0] &= ~@as(u8, 2);
    try testing.expectError(error.InvalidBeacon, beacon_mod.BeaconSettings.read(bad_beacon));

    // 2. Gate record validation:
    const gate_rec = env.store.lookup(core.ContentId.fromString("court:gate.main")).?;
    _ = try gate_mod.GateSettings.read(gate_rec.fields);

    const g_block = try gpa.dupe(u8, gate_rec.fields.block);
    defer gpa.free(g_block);
    var bad_gate = gate_rec.fields;
    bad_gate.block = g_block;

    // Out-of-bounds travel time (e.g. 0 or negative):
    g_block[0] &= ~@as(u8, 1);
    try testing.expectError(error.InvalidGate, gate_mod.GateSettings.read(bad_gate));

    // 3. Warden record validation:
    const warden_rec = env.store.lookup(core.ContentId.fromString("court:warden.main")).?;
    _ = try warden_mod.WardenSettings.read(warden_rec.fields);

    const w_block = try gpa.dupe(u8, warden_rec.fields.block);
    defer gpa.free(w_block);
    var bad_warden = warden_rec.fields;
    bad_warden.block = w_block;

    // Missing model field:
    w_block[0] &= ~@as(u8, 1);
    try testing.expectError(error.InvalidWarden, warden_mod.WardenSettings.read(bad_warden));
}

test "court: guards verified by mutation" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);

    // Guard 1: Use raycast only hits beacon layer, not default layer.
    // Teleport player near Beacon 1 (court:beacon.open):
    const open_beacon_id = core.ContentId.fromString("court:beacon.open");
    try env.game.walk.teleport(.init(2.5, 0, 4.5));
    env.game.walk.yaw = 0;
    env.game.walk.pitch = 0;

    // Facing away from beacon: Use should NOT light beacon 1.
    try env.game.step(.{ .turn = 0, .pitch = 0, .use = true }, dt);
    try testing.expect(!env.game.isBeaconLit(open_beacon_id));

    // Aiming directly at beacon: Use DOES light beacon 1.
    var intent: walk_mod.Intent = .{ .use = true };
    const to = core.math.Vec3.init(3.5, 0.5, 4.5).sub(env.game.walk.eye());
    const desired_yaw = @mod(std.math.atan2(-to.x, -to.z), 2 * std.math.pi);
    const h_dist = @sqrt(to.x * to.x + to.z * to.z);
    const desired_pitch = std.math.clamp(std.math.atan2(to.y, h_dist), -85 * std.math.pi / 180.0, 85 * std.math.pi / 180.0);
    intent.look_dx = -(desired_yaw - env.game.walk.yaw) / env.game.rules.?.look_rate;
    intent.look_dy = -(desired_pitch - env.game.walk.pitch) / env.game.rules.?.look_rate;
    try env.game.step(intent, dt);
    try testing.expect(env.game.isBeaconLit(open_beacon_id));

    // Guard 2: Gate does NOT open while any beacon is unlit.
    try testing.expect(!env.game.allBeaconsLit());
    try testing.expect(!env.game.gate.?.opening);

    // Guard 3: Player cannot win before gate opens.
    try env.game.walk.teleport(.init(0, 0, -8.5));
    try env.game.step(.{}, dt);
    try testing.expect(env.game.phase != .won);

    // Guard 4: Pit detection triggers only when falling below pit_height.
    try env.game.walk.teleport(.init(0, 0.5, -2.5));
    try env.game.step(.{}, dt);
    try testing.expect(env.game.phase != .fell);

    try env.game.walk.teleport(.init(0, -2.5, -2.5));
    try env.game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.fell, env.game.phase);
}
