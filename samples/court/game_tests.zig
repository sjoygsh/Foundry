//! M26 Step 3: the game's rules against the compiled package: the three scripted
//! play-throughs, same-binary replay, restart, each guard, and every refusal.
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
const play = @import("testdata/play.zig");
const menus_mod = @import("menus.zig");
const testing = std.testing;
const Vec3 = core.math.Vec3;

pub const dt: f32 = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

pub const TestEnv = struct {
    os: *platform.os.Os,
    diags: data.Diagnostics,
    schemas: data.Registry,
    store: data.Store,
    assets: asset.Registry,
    game: game_mod.Game,
    core_bytes: []u8,
    court_bytes: []u8,

    /// A game on its title screen, as a fresh process has it.
    pub fn init(gpa: std.mem.Allocator) !TestEnv {
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

    /// A game already in play, for tests of the rules that do not care how it began.
    pub fn initPlaying(gpa: std.mem.Allocator) !TestEnv {
        var env = try init(gpa);
        errdefer env.deinit(gpa);
        try env.game.restart();
        return env;
    }

    pub fn deinit(self: *TestEnv, gpa: std.mem.Allocator) void {
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

const max_ticks = 3000;

/// One scripted play-through, recorded: the intent of every tick and the hash after it.
/// A script's frame goes through the menus exactly as the host sends it: keys in, a
/// command out, and the command's action on the tick's intent.
pub const Recording = struct {
    intents: [max_ticks]walk_mod.Intent = undefined,
    hashes: [max_ticks]u64 = undefined,
    phases: [max_ticks]game_mod.Phase = undefined,
    /// Whether the tick advanced the world.
    world: [max_ticks]bool = undefined,
    len: usize = 0,
    quit: bool = false,
    events: std.EnumArray(game_mod.Event.Kind, u32) = .initFill(0),

    pub fn run(self: *Recording, game: *game_mod.Game, script: *const play.Script) !scripted.ScriptDriver {
        var driver: scripted.ScriptDriver = .{ .script = script };
        var menus: menus_mod.Menus = .{};
        var chosen: menus_mod.Options = .{};
        while (!driver.done) {
            const frame = driver.next(game);
            if (driver.failure != null) break;
            try testing.expect(self.len < max_ticks);
            const command = menus.update(game.phase, frame.keys, null, null, &chosen);
            if (command == .quit) self.quit = true;
            var intent = frame.intent;
            intent.action = command.action();
            const before = game.tick;
            self.intents[self.len] = intent;
            try game.step(intent, dt);
            for (game.tickEvents()) |event| self.events.set(event.kind, self.events.get(event.kind) + 1);
            self.hashes[self.len] = game.hashTick();
            self.phases[self.len] = game.phase;
            self.world[self.len] = game.tick == before + 1;
            self.len += 1;
        }
        return driver;
    }

    /// The ticks whose action began a game: Play and Restart.
    fn starts(self: *const Recording, out: []usize) []usize {
        var n: usize = 0;
        for (self.intents[0..self.len], 0..) |intent, i| {
            if (intent.action == .play or intent.action == .restart) {
                out[n] = i;
                n += 1;
            }
        }
        return out[0..n];
    }

    /// The hashes of the world ticks in `[from, to)`, in order.
    fn worldHashes(self: *const Recording, gpa: std.mem.Allocator, from: usize, to: usize) ![]u64 {
        var list: std.ArrayList(u64) = .empty;
        errdefer list.deinit(gpa);
        for (from..to) |i| if (self.world[i]) try list.append(gpa, self.hashes[i]);
        return list.toOwnedSlice(gpa);
    }

    fn sawPhase(self: *const Recording, phase: game_mod.Phase) bool {
        return std.mem.indexOfScalar(game_mod.Phase, self.phases[0..self.len], phase) != null;
    }

    /// A fresh world fed the same intents reaches the same hash at every tick (§10.3).
    fn expectReplays(self: *const Recording, gpa: std.mem.Allocator) !void {
        var fresh = try TestEnv.init(gpa);
        defer fresh.deinit(gpa);
        fresh.game.stride = 1.6;
        fresh.game.warden_stride = 0.9;
        for (self.intents[0..self.len], self.hashes[0..self.len]) |intent, expected| {
            try fresh.game.step(intent, dt);
            try testing.expectEqual(expected, fresh.game.hashTick());
        }
    }
};

test "court: the win script plays from the title, pauses, resumes, wins, restarts, wins the same way and quits" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);
    env.game.stride = 1.6;
    env.game.warden_stride = 0.9;

    try testing.expectEqual(@as(usize, 3), env.game.beacon_count);
    try testing.expect(env.game.gate != null and env.game.warden != null);
    try testing.expectEqual(game_mod.Phase.title, env.game.phase);

    const rec = try gpa.create(Recording);
    defer gpa.destroy(rec);
    rec.* = .{};
    const driver = try rec.run(&env.game, &play.win);
    try testing.expect(driver.succeeded());
    // Through the menus alone: it ended on the title, by Quit.
    try testing.expect(rec.quit);
    try testing.expectEqual(game_mod.Phase.title, env.game.phase);
    try testing.expect(rec.sawPhase(.paused));

    // Two games: Play from the title and Restart from the end screen. Each begins from the
    // same state, so restart returns to the true initial state (§10.3).
    var buffer: [8]usize = undefined;
    const begun = rec.starts(&buffer);
    try testing.expectEqual(@as(usize, 2), begun.len);
    try testing.expectEqual(walk_mod.Action.play, rec.intents[begun[0]].action);
    try testing.expectEqual(walk_mod.Action.restart, rec.intents[begun[1]].action);
    try testing.expectEqual(rec.hashes[begun[0]], rec.hashes[begun[1]]);
    try testing.expectEqual(game_mod.Phase.won, rec.phases[begun[1] - 1]);

    // The second win repeats the first tick for tick. The first was paused part-way: a
    // paused game is paused exactly, so the pause is not in the world's ticks at all.
    const first = try rec.worldHashes(gpa, begun[0], begun[1]);
    defer gpa.free(first);
    const second = try rec.worldHashes(gpa, begun[1], rec.len);
    defer gpa.free(second);
    try testing.expect(first.len > 500);
    try testing.expectEqualSlices(u64, first, second);

    // Every sound event of two wins, and none dropped (§10.2).
    try testing.expectEqual(@as(u32, 6), rec.events.get(.beacon));
    try testing.expectEqual(@as(u32, 2), rec.events.get(.gate));
    try testing.expectEqual(@as(u32, 2), rec.events.get(.won));
    // The low wall and the gap, in each game, and a landing for each real fall.
    try testing.expect(rec.events.get(.jump) >= 4 and rec.events.get(.jump) % 2 == 0);
    try testing.expect(rec.events.get(.land) >= 4 and rec.events.get(.land) % 2 == 0);
    try testing.expect(rec.events.get(.step) >= 10 and rec.events.get(.step) % 2 == 0);
    try testing.expect(rec.events.get(.warden_step) >= 10 and rec.events.get(.warden_step) % 2 == 0);
    try testing.expectEqual(@as(u32, 0), rec.events.get(.caught) + rec.events.get(.fell));
    try testing.expectEqual(@as(u32, 0), env.game.events_dropped);

    try rec.expectReplays(gpa);
}

test "court: the caught and fell scripts reach their endings and restart to the initial state" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const rec = try gpa.create(Recording);
    defer gpa.destroy(rec);
    const scripts = [_]*const play.Script{ &play.caught, &play.fell };
    const endings = [_]game_mod.Phase{ .caught, .fell };
    const kinds = [_]game_mod.Event.Kind{ .caught, .fell };
    for (scripts, endings, kinds) |script, ending, kind| {
        var env = try TestEnv.init(gpa);
        defer env.deinit(gpa);
        env.game.stride = 1.6;
        env.game.warden_stride = 0.9;
        rec.* = .{};
        const driver = try rec.run(&env.game, script);
        try testing.expect(driver.succeeded());
        try testing.expect(!rec.quit);
        var buffer: [8]usize = undefined;
        const begun = rec.starts(&buffer);
        try testing.expectEqual(@as(usize, 2), begun.len);
        try testing.expectEqual(ending, rec.phases[begun[1] - 1]);
        try testing.expectEqual(game_mod.Phase.playing, env.game.phase);
        // The warden had walked and the player had moved; restart undoes both.
        try testing.expect(rec.hashes[begun[1] - 1] != rec.hashes[begun[0]]);
        try testing.expectEqual(rec.hashes[begun[0]], rec.hashes[begun[1]]);
        try testing.expectEqual(@as(usize, 0), env.game.litCount());
        try testing.expectEqual(@as(u32, 1), rec.events.get(kind));
        try testing.expectEqual(@as(u32, 0), rec.events.get(.won));
        try rec.expectReplays(gpa);
    }
}

test "court: a script that reaches the wrong ending, or none, fails" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const rec = try gpa.create(Recording);
    defer gpa.destroy(rec);
    const begin = [_]play.Step{ .{ .press = .accept }, .{ .expect = .playing } };

    // The `fell` moves, expecting to be caught.
    const wrong: play.Script = .{ .tick_limit = 500, .steps = &(begin ++ [_]play.Step{
        .{ .walk = .{ .to = .{ 0, 0, -1.7 }, .face = .{ 0, 1.65, -5 }, .within = 0.1 } },
        .{ .jump = .{ .to = .{ 0, 0, -2.6 }, .face = .{ 0, 1.65, -5 }, .land_z = -100 } },
        .{ .expect = .caught },
    }) };
    // Standing at the spawn, waiting for a win that never comes.
    const idle: play.Script = .{ .tick_limit = 20, .steps = &(begin ++ [_]play.Step{ .stand, .{ .expect = .won } }) };
    const unknown: play.Script = .{ .tick_limit = 20, .steps = &(begin ++ [_]play.Step{.{ .use = "court:beacon.absent" }}) };
    // Moves with no ending named after them: the game ended and nothing said it should.
    const unjudged: play.Script = .{ .tick_limit = 500, .steps = &(begin ++ [_]play.Step{
        .{ .walk = .{ .to = .{ 0, 0, -1.7 }, .face = .{ 0, 1.65, -5 }, .within = 0.1 } },
        .{ .jump = .{ .to = .{ 0, 0, -2.6 }, .face = .{ 0, 1.65, -5 }, .land_z = -100 } },
    }) };

    const cases = [_]struct { script: *const play.Script, why: scripted.ScriptDriver.Failure }{
        .{ .script = &wrong, .why = .wrong_ending },
        .{ .script = &idle, .why = .timed_out },
        .{ .script = &unknown, .why = .unknown_beacon },
        .{ .script = &unjudged, .why = .wrong_ending },
    };
    for (cases) |case| {
        var env = try TestEnv.init(gpa);
        defer env.deinit(gpa);
        rec.* = .{};
        const driver = try rec.run(&env.game, case.script);
        try testing.expect(!driver.succeeded());
        try testing.expectEqual(case.why, driver.failure.?);
    }
    try testing.expectEqual(@as(?scripted.ScriptKind, null), scripted.ScriptKind.parse("bogus"));
    try testing.expectEqual(@as(?scripted.ScriptKind, .win), scripted.ScriptKind.parse("win"));
}

/// Stands the player at `feet`, looking at `target`. A test's shortcut, not a player's.
fn standLooking(game: *game_mod.Game, feet: Vec3, target: Vec3) !void {
    try game.walk.teleport(feet);
    const to = target.sub(game.walk.eye());
    game.walk.yaw = @mod(std.math.atan2(-to.x, -to.z), 2 * std.math.pi);
    game.walk.pitch = std.math.atan2(to.y, @sqrt(to.x * to.x + to.z * to.z));
}

fn beaconById(game: *game_mod.Game, name: []const u8) *beacon_mod.Beacon {
    const id = core.ContentId.fromString(name);
    for (game.beacons[0..game.beacon_count]) |*b| if (b.id.eql(id)) return b;
    unreachable;
}

test "court: Use needs a beacon in the look and within reach, and lights only that one" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    const open = beaconById(game, "court:beacon.open");
    const reach = game.rules.?.reach;
    const centre = open.useCentre();
    const near_face = centre.x - open.settings.use_half.x;

    // In the look but just beyond reach: nothing, and no prompt.
    try standLooking(game, .init(near_face - reach - 0.3, 0.004, centre.z), centre);
    try game.step(.{ .use = true }, dt);
    try testing.expectEqual(@as(usize, 0), game.litCount());
    try testing.expectEqual(@as(?u8, null), game.aimed);
    // Within reach but looking away: nothing.
    try standLooking(game, .init(near_face - 1, 0.004, centre.z), centre.add(.init(-10, 0, 0)));
    try game.step(.{ .use = true }, dt);
    try testing.expectEqual(@as(usize, 0), game.litCount());
    // Within reach and in the look, without the press: nothing.
    try standLooking(game, .init(near_face - 1, 0.004, centre.z), centre);
    try game.step(.{}, dt);
    try testing.expectEqual(@as(usize, 0), game.litCount());
    // That is when the HUD offers the key.
    try testing.expect(game.aimed != null and &game.beacons[game.aimed.?] == open);
    // With it: that beacon, and no other. The gate waits for all three.
    try game.step(.{ .use = true }, dt);
    try testing.expect(open.lit);
    try testing.expectEqual(@as(usize, 1), game.tickEvents().len);
    try testing.expectEqual(game_mod.Event.Kind.beacon, game.tickEvents()[0].kind);
    // A lit beacon is not offered again.
    try testing.expectEqual(@as(?u8, null), game.aimed);
    try testing.expectEqual(@as(usize, 1), game.litCount());
    try testing.expect(!game.gate.?.opening);
    // A second press on a lit beacon changes nothing.
    try game.step(.{ .use = true }, dt);
    try testing.expectEqual(@as(usize, 1), game.litCount());
}

test "court: winning needs every beacon lit, the gate fully open and the feet in the exit" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    const rules = game.rules.?;
    const exit = rules.exit_min.add(rules.exit_max).scale(0.5);
    const inside: Vec3 = .init(exit.x, 0.004, exit.z);

    // In the exit volume with nothing lit and the gate shut.
    try game.walk.teleport(inside);
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    // Two of three lit and the gate forced open: still not a win.
    for (game.beacons[0 .. game.beacon_count - 1]) |*b| b.lit = true;
    game.gate.?.opening = true;
    const travel: usize = @intFromFloat(@ceil(game.gate.?.settings.travel_time / dt));
    for (0..travel + 2) |_| try game.step(.{}, dt);
    try testing.expect(game.gate.?.progress >= 1.0);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    // All lit but the gate shut: still not a win.
    try game.gate.?.reset(gpa, &game.walk.world);
    game.beacons[game.beacon_count - 1].lit = true;
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    // All lit and the gate part-way: still not.
    game.gate.?.opening = true;
    try game.step(.{}, dt);
    try testing.expect(game.gate.?.progress > 0 and game.gate.?.progress < 1);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    // All lit, gate open, but standing outside the volume: still not.
    try game.walk.teleport(rules.spawn);
    for (0..travel + 2) |_| try game.step(.{}, dt);
    try testing.expect(game.gate.?.progress >= 1.0);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    // Everything at once.
    try game.walk.teleport(inside);
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.won, game.phase);
    // An ended game does not advance.
    const ended = game.hashTick();
    try game.step(.{ .direction = .forward, .jump = true, .use = true }, dt);
    try testing.expectEqual(ended, game.hashTick());
}

test "court: the gate's body blocks the passage until it has opened" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    const closed = game.gate.?.settings.closed;
    try game.walk.teleport(.init(closed.x, 0.004, closed.z + 1.5));
    game.walk.yaw = 0;
    for (0..120) |_| try game.step(.{ .direction = .forward }, dt);
    try testing.expect(game.walk.result.feet.z > closed.z);
    for (game.beacons[0..game.beacon_count]) |*b| b.lit = true;
    game.gate.?.opening = true;
    for (0..240) |_| try game.step(.{ .direction = .forward }, dt);
    try testing.expectEqual(game_mod.Phase.won, game.phase);
    try testing.expect(game.walk.result.feet.z < closed.z);
}

test "court: the pit ends the game only below its height, and the warden only within its distance" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    const rules = game.rules.?;

    try game.walk.teleport(.init(0, rules.pit_height + 0.5, -2.6));
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    try game.walk.teleport(.init(0, rules.pit_height - 0.2, -2.6));
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.fell, game.phase);

    try game.restart();
    const warden = game.warden.?.feet;
    try game.walk.teleport(warden.add(.init(0, 0, rules.catch_distance + 0.3)));
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    try game.walk.teleport(warden.add(.init(0, 0, rules.catch_distance - 0.3)));
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.caught, game.phase);
}

test "court: the warden waits, patrols between its waypoints and restart puts it back" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    const w = &game.warden.?;
    const s = w.settings.?;
    try testing.expectEqual(@as(u32, @intFromFloat(@round(s.pause / dt))), w.pause_ticks);
    // Keep the player far from the patrol.
    try game.walk.teleport(.init(4.5, 0.004, 6.5));
    for (0..w.pause_ticks) |_| try game.step(.{}, dt);
    try testing.expectApproxEqAbs(s.waypoints[0].x, w.feet.x, 1e-3);
    var min_x = w.feet.x;
    var max_x = w.feet.x;
    // The longest stand after the first step is the pause at a waypoint, plus the tick
    // that arrives there.
    var still: u32 = 0;
    var longest: u32 = 0;
    for (0..900) |_| {
        const before = w.feet.x;
        try game.step(.{}, dt);
        min_x = @min(min_x, w.feet.x);
        max_x = @max(max_x, w.feet.x);
        still = if (w.feet.x == before) still + 1 else 0;
        longest = @max(longest, still);
    }
    try testing.expectEqual(w.pause_ticks + 1, longest);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    try testing.expectApproxEqAbs(@min(s.waypoints[0].x, s.waypoints[1].x), min_x, 0.05);
    try testing.expectApproxEqAbs(@max(s.waypoints[0].x, s.waypoints[1].x), max_x, 0.05);
    try game.restart();
    try testing.expectEqualDeep(s.waypoints[0], w.feet);
    try testing.expectEqual(w.pause_ticks, w.wait_ticks);
    try testing.expectEqual(@as(usize, 1), w.waypoint);
}

fn fieldOffset(fields: []const data.schema.Field, index: usize) usize {
    var cursor: usize = data.fpk.presenceBytes(fields.len);
    for (fields, 0..) |field, i| {
        cursor = std.mem.alignForward(usize, cursor, data.fpk.alignOf(field.type));
        if (i == index) return cursor;
        cursor += data.fpk.sizeOf(field.type);
    }
    unreachable;
}

fn fieldIndex(fields: data.fpk.Fields, name: []const u8) u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    unreachable;
}

const non_finite = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };

/// Every field of `fields`, at any depth below it, refuses when it is absent or is a
/// non-finite number. `reader` reads the whole record; the bytes are restored after each.
fn expectFieldsRefused(fields: data.fpk.Fields, comptime reader: anytype, expected: anyerror) !void {
    const block = @constCast(fields.block);
    for (fields.fields, 0..) |field, i| {
        const bit = @as(u8, 1) << @intCast(i % 8);
        block[i / 8] &= ~bit;
        try testing.expectError(expected, reader.call());
        block[i / 8] |= bit;
        const offset = fieldOffset(fields.fields, i);
        switch (field.type) {
            .f32 => {
                const old: [4]u8 = block[offset..][0..4].*;
                for (non_finite) |v| {
                    std.mem.writeInt(u32, block[offset..][0..4], @bitCast(v), .little);
                    try testing.expectError(expected, reader.call());
                }
                @memcpy(block[offset..][0..4], &old);
            },
            .nested => try expectFieldsRefused((try fields.nestedAt(@intCast(i))).?, reader, expected),
            .list => |elem| if (elem.* == .nested) {
                const list = (try fields.listAt(@intCast(i))).?;
                for (0..list.len) |n| try expectFieldsRefused((try list.nestedAt(@intCast(n))).?, reader, expected);
            },
            else => {},
        }
    }
    try reader.call();
}

/// Writes `value` over the f32 at `path` (field names, outermost first), expects the
/// refusal, and restores it.
fn expectValueRefused(fields: data.fpk.Fields, path: []const []const u8, value: f32, comptime reader: anytype, expected: anyerror) !void {
    var at = fields;
    for (path[0 .. path.len - 1]) |name| at = (try at.nestedAt(fieldIndex(at, name))).?;
    const offset = fieldOffset(at.fields, fieldIndex(at, path[path.len - 1]));
    const bytes = @constCast(at.block)[offset..][0..4];
    const old: [4]u8 = bytes.*;
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
    try testing.expectError(expected, reader.call());
    bytes.* = old;
    try reader.call();
}

test "court: beacon, gate, warden and rules records refuse missing, non-finite and out-of-bounds fields" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);
    const S = struct {
        var beacon: data.fpk.Fields = undefined;
        var gate: data.fpk.Fields = undefined;
        var warden: data.fpk.Fields = undefined;
        var rules: data.fpk.Fields = undefined;
        const Beacon = struct {
            fn call() !void {
                _ = try beacon_mod.BeaconSettings.read(beacon);
            }
        };
        const Gate = struct {
            fn call() !void {
                _ = try gate_mod.GateSettings.read(gate);
            }
        };
        const Warden = struct {
            fn call() !void {
                _ = try warden_mod.WardenSettings.read(warden);
            }
        };
        const Rules = struct {
            fn call() !void {
                _ = try walk_mod.Settings.read(rules, dt);
            }
        };
    };
    S.beacon = env.store.lookup(core.ContentId.fromString("court:beacon.open")).?.fields;
    S.gate = env.store.lookup(core.ContentId.fromString("court:gate.main")).?.fields;
    S.warden = env.store.lookup(core.ContentId.fromString("court:warden.main")).?.fields;
    S.rules = env.store.lookup(core.ContentId.fromString("court:rules.main")).?.fields;

    try expectFieldsRefused(S.beacon, S.Beacon, error.InvalidBeacon);
    try expectFieldsRefused(S.gate, S.Gate, error.InvalidGate);
    try expectFieldsRefused(S.warden, S.Warden, error.InvalidWarden);

    // Zero and negative sizes, and values past their bounds.
    for ([_]f32{ 0, -1, 6 }) |v| for ([_][]const u8{ "x", "y", "z" }) |axis|
        try expectValueRefused(S.beacon, &.{ "use_half", axis }, v, S.Beacon, error.InvalidBeacon);
    for ([_]f32{ 0, -5, 20000 }) |v| try expectValueRefused(S.beacon, &.{ "light", "intensity" }, v, S.Beacon, error.InvalidBeacon);
    for ([_]f32{ 0, -1, 200 }) |v| try expectValueRefused(S.beacon, &.{ "light", "range" }, v, S.Beacon, error.InvalidBeacon);
    for ([_]f32{ -0.1, 11 }) |v| try expectValueRefused(S.beacon, &.{ "light", "height" }, v, S.Beacon, error.InvalidBeacon);
    for ([_]f32{ -0.1, 101 }) |v| try expectValueRefused(S.beacon, &.{ "light", "color", "r" }, v, S.Beacon, error.InvalidBeacon);
    try expectValueRefused(S.beacon, &.{ "position", "y" }, 1e30, S.Beacon, error.InvalidBeacon);

    for ([_]f32{ 0, -1, 61 }) |v| try expectValueRefused(S.gate, &.{"travel_time"}, v, S.Gate, error.InvalidGate);
    for ([_]f32{ 0, -1, 21 }) |v| for ([_][]const u8{ "x", "y", "z" }) |axis|
        try expectValueRefused(S.gate, &.{ "half_extents", axis }, v, S.Gate, error.InvalidGate);
    try expectValueRefused(S.gate, &.{ "open", "y" }, 1e30, S.Gate, error.InvalidGate);

    for ([_]f32{ 0, -1, 11 }) |v| try expectValueRefused(S.warden, &.{"speed"}, v, S.Warden, error.InvalidWarden);
    for ([_]f32{ 0, -1, 6 }) |v| try expectValueRefused(S.warden, &.{"cross_fade"}, v, S.Warden, error.InvalidWarden);
    for ([_]f32{ 0, -1, 3 }) |v| try expectValueRefused(S.warden, &.{"radius"}, v, S.Warden, error.InvalidWarden);
    // A capsule shorter than its own two caps.
    for ([_]f32{ 0, -1, 0.3, 5 }) |v| try expectValueRefused(S.warden, &.{"height"}, v, S.Warden, error.InvalidWarden);
    for ([_]f32{ -1, 61 }) |v| try expectValueRefused(S.warden, &.{"pause"}, v, S.Warden, error.InvalidWarden);
    // Two waypoints in the same place are no patrol.
    {
        const list = (try S.warden.listAt(fieldIndex(S.warden, "waypoints"))).?;
        const first = (try list.nestedAt(0)).?;
        const second = (try list.nestedAt(1)).?;
        const bytes = @constCast(first.block);
        const old = try gpa.dupe(u8, bytes);
        defer gpa.free(old);
        @memcpy(bytes, second.block);
        try testing.expectError(error.InvalidWarden, S.Warden.call());
        @memcpy(bytes, old);
        try S.Warden.call();
    }

    // The rules fields Step 3 added.
    for ([_]f32{ 0, -1, 21 }) |v| try expectValueRefused(S.rules, &.{"reach"}, v, S.Rules, error.InvalidWalk);
    for ([_]f32{ 0, -1, 11 }) |v| try expectValueRefused(S.rules, &.{"catch_distance"}, v, S.Rules, error.InvalidWalk);
    for ([_]f32{ -101, 101, std.math.nan(f32) }) |v| try expectValueRefused(S.rules, &.{"pit_height"}, v, S.Rules, error.InvalidWalk);
    // An exit volume turned inside out on any axis, or with a non-finite corner.
    for ([_][]const u8{ "x", "y", "z" }) |axis| {
        try expectValueRefused(S.rules, &.{ "exit_min", axis }, 50, S.Rules, error.InvalidWalk);
        try expectValueRefused(S.rules, &.{ "exit_max", axis }, std.math.inf(f32), S.Rules, error.InvalidWalk);
    }
}

test "court: a refused beacon, gate or warden is left out with the game still standing" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;

    // Refuse the beacon that sorts first, so every survivor's slot differs from its
    // place among the records. Use must still light the beacon it hits.
    const first = game.beacons[0].id;
    const first_fields = env.store.lookup(first).?.fields;
    const half = (try first_fields.nestedAt(fieldIndex(first_fields, "use_half"))).?;
    const half_bytes = @constCast(half.block)[fieldOffset(half.fields, 0)..][0..4];
    const old_half: [4]u8 = half_bytes.*;
    std.mem.writeInt(u32, half_bytes, @bitCast(@as(f32, -1)), .little);
    game.refresh(&env.store, &env.assets, null, dt);
    try testing.expectEqual(@as(usize, 2), game.beacon_count);
    for (game.beacons[0..game.beacon_count]) |*b| try testing.expect(!b.id.eql(first));
    for (0..game.beacon_count) |n| {
        const target = &game.beacons[n];
        const centre = target.useCentre();
        try standLooking(game, centre.add(.init(0, 0, target.settings.use_half.z + 1)), centre);
        game.walk.result.feet.y = centre.y - game.rules.?.eye_height;
        try game.walk.teleport(.init(centre.x, centre.y - game.rules.?.eye_height, centre.z + target.settings.use_half.z + 1));
        game.walk.pitch = 0;
        game.walk.yaw = 0;
        // Only the ray matters here; the walk is not stepped.
        const hit = (try game.walk.world.raycast(game.walk.eye(), game.walk.rotation().rotate(.forward), game.rules.?.reach, .{ .mask = beacon_mod.beacon_layer })).?;
        try testing.expectEqual(@as(u64, n), hit.user);
        try testing.expect(hit.body.eql(target.body));
    }
    half_bytes.* = old_half;

    // A model field naming something that is not a model: the beacon is left out.
    const model_bytes = @constCast(first_fields.block)[fieldOffset(first_fields.fields, fieldIndex(first_fields, "model"))..][0..8];
    const old_model: [8]u8 = model_bytes.*;
    std.mem.writeInt(u64, model_bytes, core.ContentId.fromString("court:rules.main").hash, .little);
    game.refresh(&env.store, &env.assets, null, dt);
    try testing.expectEqual(@as(usize, 2), game.beacon_count);
    model_bytes.* = old_model;
    game.refresh(&env.store, &env.assets, null, dt);
    try testing.expectEqual(@as(usize, 3), game.beacon_count);

    // A refused gate: the court stands, cannot be finished, and winning stays impossible.
    const gate_fields = env.store.lookup(core.ContentId.fromString("court:gate.main")).?.fields;
    const travel = @constCast(gate_fields.block)[fieldOffset(gate_fields.fields, fieldIndex(gate_fields, "travel_time"))..][0..4];
    const old_travel: [4]u8 = travel.*;
    std.mem.writeInt(u32, travel, @bitCast(@as(f32, 0)), .little);
    game.refresh(&env.store, &env.assets, null, dt);
    try testing.expect(game.gate == null);
    for (game.beacons[0..game.beacon_count]) |*b| b.lit = true;
    const rules = game.rules.?;
    const exit = rules.exit_min.add(rules.exit_max).scale(0.5);
    try game.walk.teleport(.init(exit.x, 0.004, exit.z));
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    travel.* = old_travel;

    // A refused warden: no patrol, and nothing catches the player.
    const warden_fields = env.store.lookup(core.ContentId.fromString("court:warden.main")).?.fields;
    const speed = @constCast(warden_fields.block)[fieldOffset(warden_fields.fields, fieldIndex(warden_fields, "speed"))..][0..4];
    const old_speed: [4]u8 = speed.*;
    std.mem.writeInt(u32, speed, @bitCast(std.math.nan(f32)), .little);
    game.refresh(&env.store, &env.assets, null, dt);
    try testing.expect(game.warden == null and game.gate != null);
    try game.restart();
    try game.walk.teleport(.init(-2, 0.004, 2.5));
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    speed.* = old_speed;
    game.refresh(&env.store, &env.assets, null, dt);
    try testing.expect(game.warden != null);
}
