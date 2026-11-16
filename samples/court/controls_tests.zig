//! M45 Step 8 (`input.md` §11): the court's actions against its compiled package, the menus' and
//! the walk's reading of them, the guard, a script's hands, the Controls screen's captures,
//! conflicts and reset, the prompt's label, the rumble record, and `southpaw`.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const input = @import("input");
const platform = @import("platform");
const options = @import("court_test_options");
const walk_mod = @import("walk.zig");
const controls = @import("controls.zig");
const rebinding = @import("rebinding.zig");
const text_mod = @import("text.zig");
const testing = std.testing;
const ids = walk_mod.actions;

/// The court's map and an `Actions` over it, from the compiled packages, with `southpaw`
/// optionally over the court.
pub const Actions = struct {
    os: *platform.os.Os,
    diags: data.Diagnostics,
    schemas: data.Registry,
    store: data.Store,
    bytes: [3]?[]u8 = @splat(null),
    map: *input.Map,
    actions: *input.Actions,

    pub fn init(gpa: std.mem.Allocator, southpaw: bool) !Actions {
        const os = try platform.os.Os.init(gpa, .{});
        errdefer os.deinit();
        var self: Actions = .{
            .os = os,
            .diags = .init(gpa, .default),
            .schemas = .init(gpa, .default),
            .store = .init(gpa, .default),
            .map = try gpa.create(input.Map),
            .actions = try gpa.create(input.Actions),
        };
        errdefer self.deinit(gpa);
        self.map.* = .empty;
        try input.schemas.registerAll(gpa, &self.schemas);
        const files = [_]struct { path: []const u8, name: []const u8 }{
            .{ .path = options.core_package, .name = "foundry:core" },
            .{ .path = options.package, .name = "court:content" },
            .{ .path = options.southpaw_package, .name = "southpaw:content" },
        };
        for (files[0..if (southpaw) 3 else 2], 0..) |f, i| {
            self.bytes[i] = try os.readFile(gpa, f.path, 16 * 1024 * 1024);
            _ = try self.store.add(gpa, f.name, self.bytes[i].?, &self.schemas, &self.diags);
        }
        self.map.* = try input.Map.build(gpa, &self.store);
        self.actions.* = .init(self.map);
        return self;
    }

    pub fn deinit(self: *Actions, gpa: std.mem.Allocator) void {
        self.map.deinit(gpa);
        gpa.destroy(self.map);
        gpa.destroy(self.actions);
        self.store.deinit(gpa);
        self.schemas.deinit(gpa);
        self.diags.deinit(gpa);
        for (self.bytes) |b| if (b) |bytes| gpa.free(bytes);
        self.os.deinit();
    }

    /// The walk's context enabled, as in play, and one frame evaluated.
    pub fn evaluate(self: *Actions, s: *const platform.InputSnapshot) *const input.Frame {
        _ = controls.syncContexts(self.actions, true);
        return self.actions.evaluate(s, .{});
    }
};

fn press(s: *platform.InputSnapshot, k: platform.Key) void {
    platform.key.setKey(&s.keys_pressed, k, true);
    platform.key.setKey(&s.keys_held, k, true);
}

fn hold(s: *platform.InputSnapshot, k: platform.Key) void {
    platform.key.setKey(&s.keys_held, k, true);
}

/// A pad in slot 0, PlayStation labels, with `button` pressed or only held.
fn pad(s: *platform.InputSnapshot, button: ?platform.GamepadButton, pressed: bool) void {
    s.gamepads[0].connected = true;
    s.gamepads[0].handle = .{ .index = 0, .generation = 1 };
    s.gamepads[0].kind = .playstation;
    s.gamepads[0].face = .{ .cross, .circle, .square, .triangle };
    if (button) |b| {
        s.gamepads[0].buttons_held.set(@intFromEnum(b));
        if (pressed) s.gamepads[0].buttons_pressed.set(@intFromEnum(b));
    }
}

test "court: every action and context loads with no warning, and the menus and the walk read them" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try Actions.init(gpa, false);
    defer env.deinit(gpa);
    try testing.expectEqual(@as(usize, 13), env.map.actions.len);
    try testing.expectEqual(@as(usize, 2), env.map.contexts.len);
    try testing.expectEqual(@as(usize, 0), env.map.warnings.len);
    try testing.expect(!env.map.action(ids.pause).?.rebindable and !env.map.action(ids.look).?.rebindable);
    for (rebinding.rows) |r| try testing.expect(env.map.action(r.id).?.rebindable);

    // The menus: the arrows, Enter and Escape, and the pad's d-pad, south and east.
    var guard: controls.Guard = .{};
    try testing.expect(controls.syncContexts(env.actions, false));
    try testing.expect(!controls.syncContexts(env.actions, false));
    var s: platform.InputSnapshot = .{};
    press(&s, .down);
    press(&s, .enter);
    var keys = controls.menuKeys(env.actions.evaluate(&s, .{}), &guard);
    try testing.expect(keys.down and keys.accept and !keys.up and !keys.back);
    s = .{};
    press(&s, .escape);
    try testing.expect(controls.menuKeys(env.actions.evaluate(&s, .{}), &guard).back);
    s = .{};
    pad(&s, .east, true);
    s.gamepads[0].buttons_pressed.set(@intFromEnum(platform.GamepadButton.dpad_up));
    keys = controls.menuKeys(env.actions.evaluate(&s, .{}), &guard);
    try testing.expect(keys.back and keys.up);
    // In a menu the walk reads nothing: Enter is not a jump, W walks nowhere.
    s = .{};
    press(&s, .space);
    hold(&s, .w);
    const in_menu = walk_mod.actionIntent(env.actions.evaluate(&s, .{}), .{});
    try testing.expect(!in_menu.jump and in_menu.direction.length() == 0);

    // In play: WASD and the stick walk, a diagonal at length 1, the arrows turn, E uses.
    s = .{};
    hold(&s, .w);
    hold(&s, .d);
    hold(&s, .left);
    press(&s, .e);
    const walking = walk_mod.actionIntent(env.evaluate(&s), .{});
    try testing.expectApproxEqAbs(@as(f32, 1), walking.direction.length(), 1e-6);
    try testing.expect(walking.direction.z < 0 and walking.direction.x > 0);
    try testing.expectEqual(@as(f32, 1), walking.turn);
    try testing.expect(walking.use and !walking.jump);
    s = .{};
    pad(&s, null, false);
    s.gamepads[0].axes[@intFromEnum(platform.GamepadAxis.left_y)] = 1;
    s.gamepads[0].axes[@intFromEnum(platform.GamepadAxis.right_y)] = 1;
    const stick = walk_mod.actionIntent(env.evaluate(&s), .{ .invert = true });
    try testing.expectApproxEqAbs(@as(f32, -1), stick.direction.z, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), stick.pitch, 1e-6);
    // Escape pauses in play: Pause is in both contexts.
    s = .{};
    press(&s, .escape);
    try testing.expect(controls.menuKeys(env.evaluate(&s), &guard).back);
}

test "court: a button held across a change of context is not pressed by it" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try Actions.init(gpa, false);
    defer env.deinit(gpa);
    var guard: controls.Guard = .{};
    _ = controls.syncContexts(env.actions, false);
    // South chooses Play on the title.
    var s: platform.InputSnapshot = .{};
    pad(&s, .south, true);
    var frame = env.actions.evaluate(&s, .{});
    guard.update(frame);
    try testing.expect(controls.menuKeys(frame, &guard).accept);
    // The game starts; south is still down when the walk's context comes on.
    try testing.expect(controls.syncContexts(env.actions, true));
    guard.arm(env.map, &s);
    s = .{};
    pad(&s, .south, false);
    frame = env.actions.evaluate(&s, .{});
    guard.update(frame);
    // The action itself reads a press: the guard is what keeps it from the walk.
    try testing.expect(frame.state(ids.jump).pressed);
    var intent = walk_mod.actionIntent(frame, .{});
    guard.apply(frame, &intent);
    try testing.expect(!intent.jump);
    // Let go, then pressed again: a jump.
    s = .{};
    pad(&s, null, false);
    guard.update(env.actions.evaluate(&s, .{}));
    pad(&s, .south, true);
    frame = env.actions.evaluate(&s, .{});
    guard.update(frame);
    intent = walk_mod.actionIntent(frame, .{});
    guard.apply(frame, &intent);
    try testing.expect(intent.jump);
    // A button not down at the change is never held back: Space pressed in the first frame.
    _ = controls.syncContexts(env.actions, false);
    _ = env.actions.evaluate(&platform.InputSnapshot{}, .{});
    s = .{};
    try testing.expect(controls.syncContexts(env.actions, true));
    guard.arm(env.map, &s);
    press(&s, .space);
    frame = env.actions.evaluate(&s, .{});
    guard.update(frame);
    intent = walk_mod.actionIntent(frame, .{});
    guard.apply(frame, &intent);
    try testing.expect(intent.jump);
}

test "court: a script's hands reach its ticks as M26's Pending gave them" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try Actions.init(gpa, false);
    defer env.deinit(gpa);
    const hands = try gpa.create(input.TickView);
    defer gpa.destroy(hands);
    hands.* = .empty;
    const snapshot: platform.InputSnapshot = .{};
    const direction: core.math.Vec3 = .init(0.6, 0, -0.8);
    // A frame with no tick: Jump and a flick, then another frame's walk and flick.
    var frame = controls.handsFrame(env.map, .{ .direction = direction, .jump = true, .look_dx = 2, .look_dy = -1 });
    hands.feed(&frame, &snapshot);
    frame = controls.handsFrame(env.map, .{ .direction = direction, .look_dx = 0.5 });
    hands.feed(&frame, &snapshot);
    const first = walk_mod.actionIntent(hands.take().actions, .{});
    try testing.expect(first.jump and !first.use);
    try testing.expectEqual(@as(f32, 2.5), first.look_dx);
    try testing.expectEqual(@as(f32, -1), first.look_dy);
    // The direction is the script's to the bit.
    try testing.expectEqual(direction.x, first.direction.x);
    try testing.expectEqual(direction.z, first.direction.z);
    try testing.expectEqual(@as(f32, 0), first.turn);
    // A second tick in the frame: the walk again, no jump, no flick.
    const second = walk_mod.actionIntent(hands.take().actions, .{});
    try testing.expect(!second.jump and second.look_dx == 0 and second.look_dy == 0);
    try testing.expectEqual(direction.z, second.direction.z);
}

test "court: evaluating the court's actions and feeding the tick view is a small part of the input span" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try Actions.init(gpa, false);
    defer env.deinit(gpa);
    const view = try gpa.create(input.TickView);
    defer gpa.destroy(view);
    view.* = .empty;
    // A busy frame: keys, motion and a pad with both sticks pushed.
    var s: platform.InputSnapshot = .{};
    hold(&s, .w);
    hold(&s, .d);
    press(&s, .space);
    s.mouse.captured = true;
    s.mouse.motion = .{ .x = 3, .y = 1 };
    pad(&s, .west, true);
    s.gamepads[0].axes[@intFromEnum(platform.GamepadAxis.left_x)] = 0.7;
    s.gamepads[0].axes[@intFromEnum(platform.GamepadAxis.right_y)] = -0.4;
    _ = controls.syncContexts(env.actions, true);
    const rounds = 2048;
    var times: [rounds]i64 = undefined;
    var scratch: [rounds]i64 = undefined;
    for (&times) |*t| {
        const began = env.os.monotonicNanos();
        view.feed(env.actions.evaluate(&s, .{}), &s);
        _ = view.take();
        t.* = @intCast(env.os.monotonicNanos() - began);
    }
    const summary = core.profile.summarise(&times, &scratch);
    std.debug.print("court actions: evaluate, feed and take, median {d:.4}ms p95 {d:.4}ms over {d}\n", .{
        @as(f64, @floatFromInt(summary.median_ns)) / core.time.ns_per_ms, @as(f64, @floatFromInt(summary.p95_ns)) / core.time.ns_per_ms, rounds,
    });
    // Measured only optimized; a Debug build is many times slower and proves nothing here.
    if (@import("builtin").mode != .Debug) try testing.expect(summary.p95_ns < 50 * std.time.ns_per_us);
}

/// `game_tests.zig`'s digest, with every tick's intent taken the way the court's host now takes a
/// script's: its hands as actions, through a tick view, read by `walk.actionIntent`.
fn handsDigest(gpa: std.mem.Allocator, map: *const input.Map, game: *@import("game.zig").Game, script: *const @import("testdata/play.zig").Script) !struct { ticks: usize, body: u64 } {
    const scripted = @import("scripted.zig");
    const menus_mod = @import("menus.zig");
    var body: u64 = 0xcbf29ce484222325;
    var ticks: usize = 0;
    var driver: scripted.ScriptDriver = .{ .script = script };
    var menus: menus_mod.Menus = .{};
    var chosen: menus_mod.Options = .{};
    var owed: walk_mod.Owed = .{};
    const hands = try gpa.create(input.TickView);
    defer gpa.destroy(hands);
    hands.* = .empty;
    const snapshot: platform.InputSnapshot = .{};
    const fold = struct {
        fn f(h: *u64, bytes: []const u8) void {
            for (bytes) |b| h.* = (h.* ^ b) *% 0x100000001b3;
        }
    }.f;
    while (!driver.done) {
        var frame = driver.next(game);
        if (driver.failure != null) return error.ScriptFailed;
        const pressed = controls.handsFrame(map, frame.intent);
        hands.feed(&pressed, &snapshot);
        frame.intent.action = menus.update(game.phase, frame.keys, null, null, &chosen).action();
        owed.feed(frame.intent);
        var intent = walk_mod.actionIntent(hands.take().actions, .{});
        intent.action = owed.take().action;
        try game.step(intent, @import("game_tests.zig").dt);
        for (game.tickEvents()) |event| {
            if (event.kind == .warden_step) continue;
            const kind: u8 = @intFromEnum(event.kind);
            fold(&body, std.mem.asBytes(&kind));
            fold(&body, std.mem.asBytes(&event.position));
            fold(&body, std.mem.asBytes(&event.beacon));
        }
        const hash = game.bodyHash();
        fold(&body, std.mem.asBytes(&hash));
        ticks += 1;
    }
    return .{ .ticks = ticks, .body = body };
}

test "court: a script pressing the court's actions keeps every M40 digest, tick for tick" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const play = @import("testdata/play.zig");
    var env = try Actions.init(gpa, false);
    defer env.deinit(gpa);
    // `game_tests.zig`'s pins, which the court's scripted runs now reach through actions.
    for ([_]struct { script: *const play.Script, ticks: usize, digest: u64 }{
        .{ .script = &play.win, .ticks = 2441, .digest = 0x4cea12a2d26686ba },
        .{ .script = &play.caught, .ticks = 92, .digest = 0x448a83a95a46f1af },
        .{ .script = &play.fell, .ticks = 185, .digest = 0x489ec244f5946487 },
        .{ .script = &play.soundtrack, .ticks = 42023, .digest = 0x38ee55e6ad5b65da },
    }) |case| {
        var fixture = try @import("game_tests.zig").TestEnv.init(gpa);
        defer fixture.deinit(gpa);
        fixture.game.stride = 1.6;
        const got = try handsDigest(gpa, env.map, &fixture.game, case.script);
        try testing.expectEqual(case.ticks, got.ticks);
        try testing.expectEqual(case.digest, got.body);
    }
}

/// The Controls screen's one frame, with no pointer.
fn step(c: *rebinding.Controls, keys: @import("menus.zig").Keys, s: *const platform.InputSnapshot, map: *const input.Map) rebinding.Result {
    return c.update(keys, s, map, null, null);
}

fn source(text: []const u8) input.Source {
    return input.Source.parse(text).?;
}

test "court: Controls captures, asks about a conflict and swaps, takes four for a walk, and resets" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try Actions.init(gpa, false);
    defer env.deinit(gpa);
    const map = env.map;
    var c: rebinding.Controls = .{};
    c.open();
    const none: platform.InputSnapshot = .{};
    // To Jump's keyboard cell, and capture: Enter's own press is not taken.
    _ = step(&c, .{ .down = true }, &none, map);
    _ = step(&c, .{ .down = true }, &none, map);
    try testing.expectEqual(@as(u8, 2), c.focus);
    _ = step(&c, .{ .accept = true }, &none, map);
    try testing.expectEqual(rebinding.Mode.capturing, c.mode);
    // Escape is Pause's, so it cancels and is never bound.
    var s: platform.InputSnapshot = .{};
    press(&s, .escape);
    _ = step(&c, .{ .back = true }, &s, map);
    try testing.expectEqual(rebinding.Mode.browse, c.mode);
    // F is free: Jump's keyboard binding becomes F, and its pad binding stays.
    _ = step(&c, .{ .accept = true }, &none, map);
    s = .{};
    press(&s, .f);
    var r = step(&c, .{}, &s, map);
    const jump = r.change.?.slice()[0];
    try testing.expect(jump.action.eql(ids.jump));
    try testing.expectEqual(@as(usize, 2), jump.bindings().len);
    try testing.expect(jump.bindings()[0].source.eql(source("pad.south")));
    try testing.expect(jump.bindings()[1].source.eql(source("key.f")));

    // E is Use's: the screen asks, and Accept swaps, giving Use Space.
    _ = step(&c, .{ .accept = true }, &none, map);
    s = .{};
    press(&s, .e);
    r = step(&c, .{}, &s, map);
    try testing.expect(r.change == null);
    try testing.expectEqual(rebinding.Mode.conflict, c.mode);
    try testing.expect(c.conflicts()[0].eql(ids.use));
    r = step(&c, .{ .accept = true }, &none, map);
    const swapped = r.change.?;
    try testing.expectEqual(@as(usize, 2), swapped.slice().len);
    try testing.expect(swapped.slice()[1].action.eql(ids.use));
    try testing.expect(swapped.slice()[1].bindings()[0].source.eql(source("key.space")));
    try testing.expect(swapped.slice()[1].bindings()[1].source.eql(source("pad.west")));
    // Back in a conflict keeps the old bindings.
    _ = step(&c, .{ .accept = true }, &none, map);
    _ = step(&c, .{}, &s, map);
    try testing.expectEqual(rebinding.Mode.conflict, c.mode);
    try testing.expect(step(&c, .{ .back = true }, &none, map).change == null);

    // Move on the keyboard takes four keys, forward, back, left and right.
    c.focus = 0;
    _ = step(&c, .{ .accept = true }, &none, map);
    for ([_]platform.Key{ .i, .k, .j, .l }, 0..) |k, n| {
        try testing.expectEqual(@as(?usize, n), c.asking());
        s = .{};
        press(&s, k);
        r = step(&c, .{}, &s, map);
    }
    const move = r.change.?.slice()[0];
    try testing.expectEqual(@as(usize, 5), move.bindings().len);
    try testing.expect(move.bindings()[0].source.eql(source("pad.left_stick")));
    try testing.expect(move.bindings()[1].source.eql(source("key.i")) and move.bindings()[1].axis == .y and move.bindings()[1].scale == 1);
    try testing.expect(move.bindings()[4].source.eql(source("key.l")) and move.bindings()[4].axis == .x and move.bindings()[4].scale == 1);
    // On the pad, a stick pushed is the whole stick.
    _ = step(&c, .{ .right = true }, &none, map);
    _ = step(&c, .{ .accept = true }, &none, map);
    s = .{};
    pad(&s, null, false);
    _ = step(&c, .{}, &s, map);
    s.gamepads[0].axes[@intFromEnum(platform.GamepadAxis.right_x)] = 0.9;
    r = step(&c, .{}, &s, map);
    // The right stick is Look's: asked, and swapped for the left.
    try testing.expectEqual(rebinding.Mode.conflict, c.mode);
    r = step(&c, .{ .accept = true }, &none, map);
    const sticks = r.change.?;
    try testing.expect(sticks.slice()[0].bindings()[4].source.eql(source("pad.right_stick")));
    try testing.expectEqual(@as(f32, 0.2), sticks.slice()[0].bindings()[4].deadzone);
    try testing.expect(sticks.slice()[1].action.eql(ids.look_stick));
    try testing.expect(sticks.slice()[1].bindings()[4].source.eql(source("pad.left_stick")));

    // The player's set: the change laid over what they had, and Reset clears it.
    var mine: input.Overrides = .empty;
    defer mine.deinit(gpa);
    try mine.set(gpa, ids.panels, &.{.{ .source = source("key.f2") }});
    var next = try rebinding.overridesWith(gpa, &mine, &sticks);
    defer next.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), next.slice().len);
    c.focus = rebinding.reset_row;
    r = step(&c, .{ .accept = true }, &none, map);
    var cleared = try rebinding.overridesWith(gpa, &next, &r.change.?);
    defer cleared.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), cleared.slice().len);
    // Back closes the screen.
    try testing.expect(step(&c, .{ .back = true }, &none, map).closed);
}

test "court: the prompt names Use's binding on the device in use" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try Actions.init(gpa, false);
    defer env.deinit(gpa);
    const names = text_mod.SourceNames.read(&env.store);
    var buf: [controls.label_capacity]u8 = undefined;
    var device: controls.LastDevice = .{};
    var s: platform.InputSnapshot = .{};
    // No layout here, so a key is its own name; the platform's label is the layout's (§3).
    try testing.expectEqualStrings("e", controls.useLabel(&buf, env.map, device, &s, null, names));
    pad(&s, .south, true);
    device.note(&s);
    try testing.expectEqual(@as(?u8, 0), device.pad);
    try testing.expectEqualStrings("Square", controls.useLabel(&buf, env.map, device, &s, null, names));
    s.gamepads[0].face = .{ .a, .b, .x, .y };
    try testing.expectEqualStrings("X", controls.useLabel(&buf, env.map, device, &s, null, names));
    // A key again, and the keyboard's label is back.
    s = .{};
    pad(&s, null, false);
    press(&s, .w);
    device.note(&s);
    try testing.expectEqual(@as(?u8, null), device.pad);
    // A listed source is named, an unlisted one by its own name.
    try testing.expectEqualStrings("Left stick", controls.sourceLabel(&buf, source("pad.left_stick"), null, names, null));
    try testing.expectEqualStrings("South", controls.sourceLabel(&buf, source("pad.south"), null, names, null));
    try testing.expectEqualStrings("mouse.wheel", controls.sourceLabel(&buf, source("mouse.wheel"), null, names, null));
    // A vector's keyboard cell lists its keys.
    try testing.expectEqualStrings("w s a d", controls.columnLabel(&buf, env.map.action(ids.move).?, .keyboard, null, names, null));
    // And the rumble record reads.
    const rumble = controls.Rumble.read(&env.store);
    try testing.expectEqual(@as(u32, 450), rumble.ms);
}

test "court: southpaw walks on the right hand with no code, and a player's rebinding still wins" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try Actions.init(gpa, true);
    defer env.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), env.map.warnings.len);
    const move = env.map.action(ids.move).?;
    try testing.expect(move.bindings()[0].source.eql(source("key.i")));
    try testing.expect(move.bindings()[4].source.eql(source("pad.right_stick")));
    try testing.expect(env.map.action(ids.look_stick).?.bindings()[4].source.eql(source("pad.left_stick")));
    // I walks forward; W no longer does.
    var s: platform.InputSnapshot = .{};
    hold(&s, .i);
    try testing.expect(walk_mod.actionIntent(env.evaluate(&s), .{}).direction.z < 0);
    s = .{};
    hold(&s, .w);
    try testing.expectEqual(@as(f32, 0), walk_mod.actionIntent(env.evaluate(&s), .{}).direction.length());

    // The player's Jump on G, and their Move on T F G H: both theirs, over the mod's.
    var mine: input.Overrides = .empty;
    defer mine.deinit(gpa);
    try mine.set(gpa, ids.jump, &.{.{ .source = source("key.g") }});
    var applied = try env.map.apply(gpa, &mine);
    defer applied.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), applied.warnings.len);
    try testing.expect(applied.action(ids.jump).?.bindings()[0].source.eql(source("key.g")));
    try testing.expectEqual(@as(usize, 1), applied.action(ids.jump).?.bindings().len);
    try testing.expect(applied.action(ids.move).?.bindings()[0].source.eql(source("key.i")));
    env.actions.setMap(&applied);
    s = .{};
    press(&s, .g);
    try testing.expect(walk_mod.actionIntent(env.evaluate(&s), .{}).jump);
    s = .{};
    press(&s, .space);
    try testing.expect(!walk_mod.actionIntent(env.evaluate(&s), .{}).jump);
    env.actions.setMap(env.map);
}
