//! Evaluation, the tick view and rebinding against a hand-written oracle over scripted snapshots
//! (`docs/design/input.md` §13), and the pinned digest of a 600-frame sequence.
//!
//! Every expected value below was worked out by hand from §7's rules, not read back from the
//! code. The digest is the exception: it folds every frame and tick view of a scripted sequence,
//! and is pinned so that the same inputs give the same answer on every platform (I9).

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const actions_mod = @import("actions.zig");
const map_mod = @import("map.zig");
const rebind = @import("rebind.zig");
const tick_mod = @import("tick.zig");
const source_mod = @import("source.zig");
const schemas = @import("schemas.zig");

const testing = std.testing;
const t_gpa = testing.allocator;
const ContentId = core.ContentId;
const Vec2 = core.math.Vec2;
const InputSnapshot = platform.InputSnapshot;
const Key = platform.Key;
const Map = map_mod.Map;
const Fixture = map_mod.Fixture;
const Actions = actions_mod.Actions;
const ActionState = actions_mod.ActionState;
const Frame = actions_mod.Frame;
const TickView = tick_mod.TickView;
const Source = source_mod.Source;

fn cid(text: []const u8) ContentId {
    return ContentId.fromString(text);
}

const game =
    \\foundry:input_context t:walk { priority 10 }
    \\foundry:input_context t:menu { priority 20 blocks true }
    \\foundry:input_action t:jump { kind "button" contexts [ t:walk ] bindings [
    \\    { source "key.space" } { source "pad.south" } { source "pad.right_trigger" threshold 0.5 }
    \\] }
    \\foundry:input_action t:crouch { kind "button" contexts [ t:walk ] bindings [
    \\    { source "pad.left_y" scale -1 threshold 0.6 }
    \\] }
    \\foundry:input_action t:move { kind "vector" contexts [ t:walk ] bindings [
    \\    { source "key.w" axis "y" scale 1 } { source "key.s" axis "y" scale -1 }
    \\    { source "key.a" axis "x" scale -1 } { source "key.d" axis "x" scale 1 }
    \\    { source "pad.left_stick" deadzone 0.2 }
    \\] }
    \\foundry:input_action t:throttle { kind "axis" contexts [ t:walk ] bindings [
    \\    { source "key.e" } { source "key.q" scale -1 } { source "pad.right_x" deadzone 0.2 }
    \\] }
    \\foundry:input_action t:look { kind "delta" contexts [ t:walk ] bindings [ { source "mouse.motion" scale 2 } ] }
    \\foundry:input_action t:turn { kind "axis" contexts [ t:walk ] bindings [
    \\    { source "key.left" scale -1 } { source "key.right" }
    \\] }
    \\foundry:input_action t:menu_left { kind "button" contexts [ t:menu ] bindings [ { source "key.left" } ] }
    \\foundry:input_action t:pause { kind "button" contexts [ t:walk t:menu ] bindings [ { source "key.escape" } ] rebindable false }
    \\foundry:input_action t:zoom { kind "button" contexts [ t:walk ] bindings [
    \\    { source "mouse.wheel_up" } { source "mouse.right" }
    \\] }
;

/// A map over `text`, with the fixture that holds its store.
const Built = struct {
    fixture: Fixture,
    map: Map,

    fn init(text: []const u8) !*Built {
        const self = try t_gpa.create(Built);
        errdefer t_gpa.destroy(self);
        self.fixture = Fixture.init();
        errdefer self.fixture.deinit();
        try self.fixture.add("t", text);
        self.map = try self.fixture.build();
        return self;
    }

    fn deinit(self: *Built) void {
        self.map.deinit(t_gpa);
        self.fixture.deinit();
        t_gpa.destroy(self);
    }
};

// -- snapshot scripting ------------------------------------------------------------

fn snap() InputSnapshot {
    return .{ .focused = true };
}
fn down(s: *InputSnapshot, k: Key) void {
    platform.key.setKey(&s.keys_held, k, true);
    platform.key.setKey(&s.keys_pressed, k, true);
}
fn hold(s: *InputSnapshot, k: Key) void {
    platform.key.setKey(&s.keys_held, k, true);
}
fn up(s: *InputSnapshot, k: Key) void {
    platform.key.setKey(&s.keys_released, k, true);
}
fn tap(s: *InputSnapshot, k: Key) void {
    platform.key.setKey(&s.keys_pressed, k, true);
    platform.key.setKey(&s.keys_released, k, true);
}
fn seat(s: *InputSnapshot, slot: usize) void {
    s.gamepads[slot].connected = true;
    s.gamepads[slot].handle = .{ .index = @intCast(slot), .generation = 1 };
}
fn padDown(s: *InputSnapshot, slot: usize, b: platform.GamepadButton) void {
    s.gamepads[slot].buttons_held.set(@intFromEnum(b));
    s.gamepads[slot].buttons_pressed.set(@intFromEnum(b));
}
fn padHold(s: *InputSnapshot, slot: usize, b: platform.GamepadButton) void {
    s.gamepads[slot].buttons_held.set(@intFromEnum(b));
}
fn padAxis(s: *InputSnapshot, slot: usize, a: platform.GamepadAxis, v: f32) void {
    s.gamepads[slot].axes[@intFromEnum(a)] = v;
}

fn expectState(frame: *const Frame, name: []const u8, held: bool, pressed: bool, released: bool) !void {
    const st = frame.state(cid(name));
    errdefer std.debug.print("{s}: held {} pressed {} released {}\n", .{ name, st.held, st.pressed, st.released });
    try testing.expectEqual(held, st.held);
    try testing.expectEqual(pressed, st.pressed);
    try testing.expectEqual(released, st.released);
}

fn expectValue(frame: *const Frame, name: []const u8, x: f32, y: f32) !void {
    const v = frame.state(cid(name)).value;
    errdefer std.debug.print("{s}: ({d}, {d})\n", .{ name, v.x, v.y });
    try testing.expectApproxEqAbs(x, v.x, 1e-6);
    try testing.expectApproxEqAbs(y, v.y, 1e-6);
}

fn walking(built: *Built) !Actions {
    var a = Actions.init(&built.map);
    try a.enable(cid("t:walk"));
    return a;
}

// -- evaluation ---------------------------------------------------------------------

test "a button presses, holds and releases, and a tap inside one frame is a press and a release" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var s = snap();
    down(&s, .space);
    try expectState(a.evaluate(&s, .{}), "t:jump", true, true, false);
    try expectValue(a.current(), "t:jump", 1, 0);
    s = snap();
    hold(&s, .space);
    try expectState(a.evaluate(&s, .{}), "t:jump", true, false, false);
    s = snap();
    up(&s, .space);
    try expectState(a.evaluate(&s, .{}), "t:jump", false, false, true);
    try expectValue(a.current(), "t:jump", 0, 0);
    s = snap();
    try expectState(a.evaluate(&s, .{}), "t:jump", false, false, false);
    s = snap();
    tap(&s, .space);
    try expectState(a.evaluate(&s, .{}), "t:jump", false, true, true);
    // A pad button feeds the same action.
    s = snap();
    seat(&s, 0);
    padDown(&s, 0, .south);
    try expectState(a.evaluate(&s, .{}), "t:jump", true, true, false);
}

test "while one binding holds a button steadily, another's press and release are not its edges" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var s = snap();
    down(&s, .space);
    _ = a.evaluate(&s, .{});
    s = snap();
    hold(&s, .space);
    seat(&s, 0);
    padDown(&s, 0, .south);
    try expectState(a.evaluate(&s, .{}), "t:jump", true, false, false);
    s = snap();
    hold(&s, .space);
    seat(&s, 0);
    s.gamepads[0].buttons_released.set(@intFromEnum(platform.GamepadButton.south));
    try expectState(a.evaluate(&s, .{}), "t:jump", true, false, false);
    // Handing over from one key to another in one frame is a release and a press.
    s = snap();
    up(&s, .space);
    seat(&s, 0);
    padDown(&s, 0, .south);
    try expectState(a.evaluate(&s, .{}), "t:jump", true, true, true);
}

test "edges are consistent over any sequence: no held change without its edge, no release without a press" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var rng = core.Pcg32.init(45, 5);
    var keys_down = false;
    var pad_down = false;
    var held_before = false;
    for (0..4000) |_| {
        var s = snap();
        seat(&s, 0);
        // The space key and the south button, each moving as a real one can.
        inline for (.{ &keys_down, &pad_down }, .{ 0, 1 }) |state, which| {
            const r = rng.below(4);
            const was = state.*;
            const now = switch (r) {
                0 => was,
                1 => !was,
                2 => false, // tapped if it was up, released if down
                else => true, // re-pressed inside the frame if it was down
            };
            const pressed = (!was and now) or (r == 2 and !was) or (r == 3 and was);
            const released = (was and !now) or (r == 2 and !was) or (r == 3 and was);
            state.* = now;
            if (which == 0) {
                if (now) hold(&s, .space);
                if (pressed) platform.key.setKey(&s.keys_pressed, .space, true);
                if (released) platform.key.setKey(&s.keys_released, .space, true);
            } else {
                if (now) padHold(&s, 0, .south);
                if (pressed) s.gamepads[0].buttons_pressed.set(@intFromEnum(platform.GamepadButton.south));
                if (released) s.gamepads[0].buttons_released.set(@intFromEnum(platform.GamepadButton.south));
            }
        }
        padAxis(&s, 0, .right_trigger, rng.float01());
        const st = a.evaluate(&s, .{}).state(cid("t:jump"));
        if (!held_before and st.held) try testing.expect(st.pressed);
        if (held_before and !st.held) try testing.expect(st.released);
        if (st.released) try testing.expect(held_before or st.pressed);
        if (st.pressed and !st.held) try testing.expect(st.released);
        held_before = st.held;
    }
}

test "an axis sums its bindings past a rescaled deadzone, and clamps to one" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var s = snap();
    seat(&s, 0);
    padAxis(&s, 0, .right_x, 0.6);
    // (0.6 - 0.2) / (1 - 0.2)
    try expectValue(a.evaluate(&s, .{}), "t:throttle", 0.5, 0);
    try expectState(a.current(), "t:throttle", true, true, false);
    padAxis(&s, 0, .right_x, -0.6);
    try expectValue(a.evaluate(&s, .{}), "t:throttle", -0.5, 0);
    padAxis(&s, 0, .right_x, 0.15);
    try expectValue(a.evaluate(&s, .{}), "t:throttle", 0, 0);
    try expectState(a.current(), "t:throttle", false, false, true);
    padAxis(&s, 0, .right_x, 1);
    try expectValue(a.evaluate(&s, .{}), "t:throttle", 1, 0);
    // A key and the axis together are clamped.
    padAxis(&s, 0, .right_x, 0.6);
    hold(&s, .e);
    try expectValue(a.evaluate(&s, .{}), "t:throttle", 1, 0);
    // Opposed keys cancel, and a value of zero is not held.
    s = snap();
    hold(&s, .e);
    hold(&s, .q);
    try expectValue(a.evaluate(&s, .{}), "t:throttle", 0, 0);
    try expectState(a.current(), "t:throttle", false, false, true);
}

test "a vector's keyboard diagonal is length one, and a stick's deadzone is radial and rescaled" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var s = snap();
    hold(&s, .w);
    hold(&s, .d);
    const h = 1 / @sqrt(@as(f32, 2));
    try expectValue(a.evaluate(&s, .{}), "t:move", h, h);
    s = snap();
    hold(&s, .s);
    try expectValue(a.evaluate(&s, .{}), "t:move", 0, -1);
    s = snap();
    seat(&s, 0);
    padAxis(&s, 0, .left_x, 0.3);
    padAxis(&s, 0, .left_y, 0.4);
    // Length 0.5 becomes (0.5 - 0.2) / 0.8 = 0.375, along (0.6, 0.8).
    try expectValue(a.evaluate(&s, .{}), "t:move", 0.225, 0.3);
    padAxis(&s, 0, .left_x, 0.1);
    padAxis(&s, 0, .left_y, 0.15);
    // Each component is inside 0.2 and so is the length: nothing.
    try expectValue(a.evaluate(&s, .{}), "t:move", 0, 0);
    padAxis(&s, 0, .left_x, 0.19);
    padAxis(&s, 0, .left_y, 0.19);
    // Each component is inside 0.2 but the length (0.2687) is not, so it moves.
    const l: f32 = @sqrt(@as(f32, 0.19 * 0.19 * 2));
    const k = ((l - 0.2) / 0.8) / l;
    try expectValue(a.evaluate(&s, .{}), "t:move", 0.19 * k, 0.19 * k);
    padAxis(&s, 0, .left_x, 1);
    padAxis(&s, 0, .left_y, 1);
    // A pad's corner is longer than one, and is clamped.
    try expectValue(a.evaluate(&s, .{}), "t:move", h, h);
    // A stick and a key together are clamped too.
    padAxis(&s, 0, .left_x, 0);
    padAxis(&s, 0, .left_y, 1);
    hold(&s, .w);
    try expectValue(a.evaluate(&s, .{}), "t:move", 0, 1);
}

test "a delta is the frame's motion times its scale, unclamped, held while nonzero" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var s = snap();
    s.mouse.motion = .init(3, -40);
    try expectValue(a.evaluate(&s, .{}), "t:look", 6, -80);
    try expectState(a.current(), "t:look", true, true, false);
    s.mouse.motion = .init(1, 0);
    try expectState(a.evaluate(&s, .{}), "t:look", true, false, false);
    s = snap();
    try expectValue(a.evaluate(&s, .{}), "t:look", 0, 0);
    try expectState(a.current(), "t:look", false, false, true);
}

test "a pad axis holds a button from its threshold in its scale's direction, with edges as it crosses" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    const cases = [_]struct { v: f32, held: bool, pressed: bool, released: bool }{
        .{ .v = 0.4, .held = false, .pressed = false, .released = false },
        .{ .v = 0.5, .held = true, .pressed = true, .released = false },
        .{ .v = 0.9, .held = true, .pressed = false, .released = false },
        .{ .v = 0.49, .held = false, .pressed = false, .released = true },
        .{ .v = 1.0, .held = true, .pressed = true, .released = false },
    };
    for (cases) |c| {
        var s = snap();
        seat(&s, 0);
        padAxis(&s, 0, .right_trigger, c.v);
        try expectState(a.evaluate(&s, .{}), "t:jump", c.held, c.pressed, c.released);
    }
    // A negative scale reads the other way: crouch is the left stick pushed down past 0.6.
    var s = snap();
    seat(&s, 0);
    padAxis(&s, 0, .left_y, 0.9);
    try expectState(a.evaluate(&s, .{}), "t:crouch", false, false, false);
    padAxis(&s, 0, .left_y, -0.7);
    try expectState(a.evaluate(&s, .{}), "t:crouch", true, true, false);
    padAxis(&s, 0, .left_y, -0.5);
    try expectState(a.evaluate(&s, .{}), "t:crouch", false, false, true);
}

test "the wheel's directions are taps a button reads in the frame it turned" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var s = snap();
    s.mouse.wheel = .init(0, 1);
    try expectState(a.evaluate(&s, .{}), "t:zoom", false, true, true);
    s.mouse.wheel = .init(0, -1);
    try expectState(a.evaluate(&s, .{}), "t:zoom", false, false, false);
}

test "contexts are read by priority, and a blocking one hides every source it binds from lower ones" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var s = snap();
    hold(&s, .left);
    hold(&s, .escape);
    try expectValue(a.evaluate(&s, .{}), "t:turn", -1, 0);
    // The menu is not enabled, so its action is at rest.
    try expectState(a.current(), "t:menu_left", false, false, false);
    try a.enable(cid("t:menu"));
    // The menu owns the left arrow now: the walk's turn cannot see it, and loses it with a release.
    try expectValue(a.evaluate(&s, .{}), "t:turn", 0, 0);
    try expectState(a.current(), "t:turn", false, false, true);
    try expectState(a.current(), "t:menu_left", true, true, false);
    // Pause is in both, now read in the menu, which hides nothing from itself; held across the
    // change, so not pressed again.
    try expectState(a.current(), "t:pause", true, false, false);
    // The right arrow is not bound in the menu, so the walk still reads it, and only it.
    hold(&s, .right);
    try expectValue(a.evaluate(&s, .{}), "t:turn", 1, 0);
    s = snap();
    hold(&s, .right);
    try expectValue(a.evaluate(&s, .{}), "t:turn", 1, 0);
    // Hidden whether pressed or not: the menu binds the left arrow, so a press is not the walk's.
    s = snap();
    down(&s, .left);
    try expectValue(a.evaluate(&s, .{}), "t:turn", 0, 0);
    a.disable(cid("t:menu"));
    try expectValue(a.evaluate(&s, .{}), "t:turn", -1, 0);
    try expectState(a.current(), "t:menu_left", false, false, true);
}

test "contexts of equal priority are read by content ID, and priority comes before it" {
    const text =
        \\foundry:input_context t:a { priority 5 blocks true }
        \\foundry:input_context t:b { priority 5 blocks true }
        \\foundry:input_action t:in_a { kind "button" contexts [ t:a ] bindings [ { source "key.x" } ] }
        \\foundry:input_action t:in_b { kind "button" contexts [ t:b ] bindings [ { source "key.x" } ] }
    ;
    const b = try Built.init(text);
    defer b.deinit();
    var a = Actions.init(&b.map);
    try a.enable(cid("t:b"));
    try a.enable(cid("t:a"));
    var s = snap();
    hold(&s, .x);
    const a_first = cid("t:a").hash < cid("t:b").hash;
    const f = a.evaluate(&s, .{});
    try testing.expectEqual(a_first, f.state(cid("t:in_a")).held);
    try testing.expectEqual(!a_first, f.state(cid("t:in_b")).held);

    // Priority first: whichever of the two reads second by ID is given the higher priority, so
    // an order by ID alone would read the other.
    var text_buf: [512]u8 = undefined;
    const later = if (a_first) "t:in_b" else "t:in_a";
    const raised_text = try std.fmt.bufPrint(&text_buf,
        \\foundry:input_context t:a {{ priority {d} blocks true }}
        \\foundry:input_context t:b {{ priority {d} blocks true }}
        \\foundry:input_action t:in_a {{ kind "button" contexts [ t:a ] bindings [ {{ source "key.x" }} ] }}
        \\foundry:input_action t:in_b {{ kind "button" contexts [ t:b ] bindings [ {{ source "key.x" }} ] }}
    , .{ @as(i32, if (a_first) 5 else 6), @as(i32, if (a_first) 6 else 5) });
    const raised = try Built.init(raised_text);
    defer raised.deinit();
    var r = Actions.init(&raised.map);
    try r.enable(cid("t:a"));
    try r.enable(cid("t:b"));
    const g = r.evaluate(&s, .{});
    try testing.expect(g.state(cid(later)).held);
    try testing.expect(!g.state(cid(if (a_first) "t:in_a" else "t:in_b")).held);
}

test "an action in no enabled context reads as rest, with a release if it was held" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var s = snap();
    hold(&s, .w);
    down(&s, .space);
    _ = a.evaluate(&s, .{});
    a.disable(cid("t:walk"));
    try expectState(a.evaluate(&s, .{}), "t:jump", false, false, true);
    try expectState(a.current(), "t:move", false, false, true);
    try expectValue(a.current(), "t:move", 0, 0);
    try expectState(a.evaluate(&s, .{}), "t:jump", false, false, false);
    // Enabled again with the key still held: a press, since the action was at rest.
    try a.enable(cid("t:walk"));
    s = snap();
    hold(&s, .space);
    try expectState(a.evaluate(&s, .{}), "t:jump", true, true, false);
    // A key let go in the frame its context returns ends no press the action made.
    a.disable(cid("t:walk"));
    _ = a.evaluate(&s, .{});
    try a.enable(cid("t:walk"));
    s = snap();
    up(&s, .space);
    try expectState(a.evaluate(&s, .{}), "t:jump", false, false, false);
}

test "at most eight contexts are enabled, idempotently, and an unknown one is inert" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = Actions.init(&b.map);
    try a.enable(cid("t:walk"));
    try a.enable(cid("t:walk"));
    try testing.expectEqual(@as(usize, 1), a.enabled().len);
    var names: [7][16]u8 = undefined;
    for (0..7) |i| try a.enable(cid(try std.fmt.bufPrint(&names[i], "t:other{d}", .{i})));
    try testing.expectError(error.TooManyEnabled, a.enable(cid("t:menu")));
    var s = snap();
    hold(&s, .space);
    try expectState(a.evaluate(&s, .{}), "t:jump", true, true, false);
    a.disableAll();
    try testing.expectEqual(@as(usize, 0), a.enabled().len);
}

test "devices select the keyboard, the mouse and pad slots, and blocking hides keys or the pointer" {
    const b = try Built.init(game);
    defer b.deinit();
    var one = try walking(b);
    var two = try walking(b);
    var s = snap();
    hold(&s, .space);
    s.mouse.motion = .init(1, 1);
    seat(&s, 0);
    seat(&s, 1);
    padHold(&s, 1, .south);
    padAxis(&s, 0, .right_x, 0.6);
    padAxis(&s, 1, .right_x, -1);

    // Two players over one snapshot: the keyboard and pad 0, and pad 1 alone.
    const p1 = one.evaluate(&s, .{ .devices = .{ .pads = 0b0001 } });
    const p2 = two.evaluate(&s, .{ .devices = .{ .keyboard = false, .mouse = false, .pads = 0b0010 } });
    try expectValue(p1, "t:throttle", 0.5, 0);
    try expectValue(p2, "t:throttle", -1, 0);
    try testing.expect(p1.state(cid("t:jump")).held);
    try testing.expect(p2.state(cid("t:jump")).held);
    try testing.expect(p1.state(cid("t:look")).held);
    try testing.expect(!p2.state(cid("t:look")).held);

    // Every pad: the axis from the slot pushed furthest.
    var all = try walking(b);
    try expectValue(all.evaluate(&s, .{}), "t:throttle", -1, 0);

    // A pad that is not connected is not read, even when selected.
    s.gamepads[1].connected = false;
    try expectValue(all.evaluate(&s, .{}), "t:throttle", 0.5, 0);

    var blocked = try walking(b);
    const f = blocked.evaluate(&s, .{ .blocked = .{ .keyboard = true, .pointer = true }, .devices = .{ .pads = 0 } });
    try testing.expect(!f.state(cid("t:jump")).held);
    try testing.expect(!f.state(cid("t:look")).held);
    s = snap();
    s.mouse.motion = .init(1, 1);
    hold(&s, .space);
    const g = blocked.evaluate(&s, .{ .blocked = .{ .pointer = true } });
    try testing.expect(g.state(cid("t:jump")).held);
    try testing.expect(!g.state(cid("t:look")).held);
}

test "a new map keeps each surviving action's held state, so it invents no press" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var s = snap();
    down(&s, .space);
    hold(&s, .w);
    _ = a.evaluate(&s, .{});
    const grown = try Built.init(game ++
        \\
        \\foundry:input_action t:wave { kind "button" contexts [ t:walk ] bindings [ { source "key.space" } ] }
    );
    defer grown.deinit();
    a.setMap(&grown.map);
    // Until the next evaluation, the frame is the old one's, by ID.
    try expectState(a.current(), "t:jump", true, true, false);
    try expectState(a.current(), "t:wave", false, false, false);
    s = snap();
    hold(&s, .space);
    hold(&s, .w);
    const f = a.evaluate(&s, .{});
    try expectState(f, "t:jump", true, false, false);
    try expectState(f, "t:move", true, false, false);
    // An action new to the map was not held, so it is pressed.
    try expectState(f, "t:wave", true, true, false);
    // A trigger held through a new map is held, not pressed again, though its threshold
    // memory belonged to the old bindings.
    s = snap();
    seat(&s, 0);
    padAxis(&s, 0, .right_trigger, 0.8);
    _ = a.evaluate(&s, .{});
    a.setMap(&grown.map);
    try expectState(a.evaluate(&s, .{}), "t:jump", true, false, false);
    padAxis(&s, 0, .right_trigger, 0.1);
    try expectState(a.evaluate(&s, .{}), "t:jump", false, false, true);
    // And one that went is gone, found by nothing.
    a.setMap(&b.map);
    try testing.expect(a.current().find(cid("t:wave")) == null);
}

test "an empty map gives an empty frame" {
    const b = try Built.init("");
    defer b.deinit();
    var a = Actions.init(&b.map);
    var s = snap();
    down(&s, .space);
    const f = a.evaluate(&s, .{});
    try testing.expectEqual(@as(u16, 0), f.count);
    try testing.expectEqual(ActionState.rest, f.state(cid("t:jump")));
}

// -- the tick view ------------------------------------------------------------------

/// Runs `frames`, each with its own number of steps, and counts the presses steps saw.
fn countPresses(b: *Built, steps: []const u8) !u32 {
    var a = try walking(b);
    var view: TickView = .empty;
    var seen: u32 = 0;
    for (steps, 0..) |n, i| {
        var s = snap();
        if (i == 1) down(&s, .space) else if (i > 1) hold(&s, .space);
        view.feed(a.evaluate(&s, .{}), &s);
        for (0..n) |_| {
            const t = view.take();
            if (t.actions.state(cid("t:jump")).pressed) seen += 1;
            if (t.input.wasPressed(.space)) seen += 1;
        }
    }
    return seen;
}

test "zero, one or three steps in a frame see a press exactly once" {
    const b = try Built.init(game);
    defer b.deinit();
    // Once by the action and once by the raw snapshot, so two.
    try testing.expectEqual(@as(u32, 2), try countPresses(b, &.{ 1, 1, 1, 1 }));
    try testing.expectEqual(@as(u32, 2), try countPresses(b, &.{ 1, 3, 3, 3 }));
    try testing.expectEqual(@as(u32, 2), try countPresses(b, &.{ 1, 0, 0, 1 }));
    try testing.expectEqual(@as(u32, 2), try countPresses(b, &.{ 0, 0, 3, 0, 1 }));
    // Never a step after it: never seen.
    try testing.expectEqual(@as(u32, 0), try countPresses(b, &.{ 1, 0, 0, 0 }));
}

test "the first step sees the edges and later steps in the frame see held state only" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var view: TickView = .empty;
    var s = snap();
    down(&s, .space);
    hold(&s, .d);
    view.feed(a.evaluate(&s, .{}), &s);
    const first = view.take();
    try expectState(first.actions, "t:jump", true, true, false);
    try expectState(first.actions, "t:move", true, true, false);
    const second = view.take();
    try expectState(second.actions, "t:jump", true, false, false);
    try expectState(second.actions, "t:move", true, false, false);
    try expectValue(second.actions, "t:move", 1, 0);
    try testing.expect(second.input.isHeld(.space));
    try testing.expect(!second.input.wasPressed(.space));
}

test "a press and a release in two frames with no step between reach the next step together" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var view: TickView = .empty;
    var s = snap();
    down(&s, .space);
    view.feed(a.evaluate(&s, .{}), &s);
    s = snap();
    up(&s, .space);
    view.feed(a.evaluate(&s, .{}), &s);
    const t = view.take();
    try expectState(t.actions, "t:jump", false, true, true);
    try testing.expect(t.input.wasPressed(.space) and t.input.wasReleased(.space) and !t.input.isHeld(.space));
}

test "motion summed across frames with no step arrives whole at the next, and once" {
    const b = try Built.init(game);
    defer b.deinit();
    var a = try walking(b);
    var view: TickView = .empty;
    var s = snap();
    s.mouse.motion = .init(1, -2);
    s.mouse.wheel = .init(0, 1);
    view.feed(a.evaluate(&s, .{}), &s);
    s.mouse.motion = .init(2, 0);
    s.mouse.wheel = .init(0, 0.5);
    view.feed(a.evaluate(&s, .{}), &s);
    const t = view.take();
    try expectValue(t.actions, "t:look", 6, -4);
    try expectState(t.actions, "t:look", true, true, false);
    try testing.expectEqual(Vec2.init(3, -2), t.input.mouse.motion);
    try testing.expectEqual(Vec2.init(0, 1.5), t.input.mouse.wheel);
    const later = view.take();
    try expectValue(later.actions, "t:look", 0, 0);
    try expectState(later.actions, "t:look", false, false, false);
    try testing.expectEqual(Vec2.zero, later.input.mouse.motion);
}

test "motion in one unit is dropped when motion in another arrives, and a new pad's edges start again" {
    var view: TickView = .empty;
    const empty: Frame = .empty;
    var s = snap();
    s.mouse.motion = .init(5, 5);
    s.mouse.motion_unit = .points;
    seat(&s, 0);
    padDown(&s, 0, .south);
    view.feed(&empty, &s);
    s = snap();
    s.mouse.motion = .init(1, 0);
    s.mouse.motion_unit = .counts;
    seat(&s, 0);
    s.gamepads[0].handle.generation = 2;
    view.feed(&empty, &s);
    const t = view.take();
    try testing.expectEqual(Vec2.init(1, 0), t.input.mouse.motion);
    try testing.expectEqual(platform.MotionUnit.counts, t.input.mouse.motion_unit);
    try testing.expect(!t.input.gamepads[0].wasPressed(.south));
}

test "a tick view matches a changed map by ID, keeping what survives" {
    const b = try Built.init(game);
    defer b.deinit();
    const grown = try Built.init(game ++
        \\
        \\foundry:input_action t:wave { kind "button" contexts [ t:walk ] bindings [ { source "key.space" } ] }
    );
    defer grown.deinit();
    var a = try walking(b);
    var view: TickView = .empty;
    var s = snap();
    down(&s, .space);
    view.feed(a.evaluate(&s, .{}), &s);
    a.setMap(&grown.map);
    s = snap();
    hold(&s, .space);
    view.feed(a.evaluate(&s, .{}), &s);
    const t = view.take();
    try expectState(t.actions, "t:jump", true, true, false);
    try expectState(t.actions, "t:wave", true, true, false);
}

// -- rebinding ----------------------------------------------------------------------

const mod_text =
    \\foundry:input_action t:jump { kind "button" contexts [ t:walk ] bindings [ { source "pad.east" } ] }
;

fn bindingsOf(map: *const Map, name: []const u8) []const schemas.Binding {
    return map.action(cid(name)).?.bindings();
}

test "the player's override comes before the last package's record, which comes before the game's" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("t", game);
    try f.add("m", mod_text);
    var map = try f.build();
    defer map.deinit(t_gpa);
    // The mod's record over the game's.
    try testing.expect(bindingsOf(&map, "t:jump")[0].source.eql(.{ .pad_button = .east }));

    var overrides: rebind.Overrides = .empty;
    defer overrides.deinit(t_gpa);
    try overrides.set(t_gpa, cid("t:jump"), &.{ .{ .source = .{ .key = .j } }, .{ .source = .{ .pad_button = .north } } });
    var effective = try map.apply(t_gpa, &overrides);
    defer effective.deinit(t_gpa);
    try testing.expectEqual(@as(usize, 0), effective.warnings.len);
    const jump = bindingsOf(&effective, "t:jump");
    try testing.expectEqual(@as(usize, 2), jump.len);
    try testing.expect(jump[0].source.eql(.{ .key = .j }));
    try testing.expect(jump[1].source.eql(.{ .pad_button = .north }));
    // Whole: nothing of the mod's binding is left.
    for (jump) |bd| try testing.expect(!bd.source.eql(.{ .pad_button = .east }));
    // The rest of the map is the map's.
    try testing.expectEqual(map.actions.len, effective.actions.len);
    try testing.expectEqual(bindingsOf(&map, "t:move").len, bindingsOf(&effective, "t:move").len);

    // Removed, the mod's defaults stand again.
    try testing.expect(overrides.remove(cid("t:jump")));
    try testing.expect(!overrides.remove(cid("t:jump")));
    var back = try map.apply(t_gpa, &overrides);
    defer back.deinit(t_gpa);
    try testing.expect(bindingsOf(&back, "t:jump")[0].source.eql(.{ .pad_button = .east }));

    // An empty override unbinds.
    try overrides.set(t_gpa, cid("t:jump"), &.{});
    var none = try map.apply(t_gpa, &overrides);
    defer none.deinit(t_gpa);
    try testing.expectEqual(@as(usize, 0), bindingsOf(&none, "t:jump").len);
}

test "an override of a rebindable-false action is ignored and said once, and a bad one is refused alone" {
    const b = try Built.init(game);
    defer b.deinit();
    var overrides: rebind.Overrides = .empty;
    defer overrides.deinit(t_gpa);
    try overrides.set(t_gpa, cid("t:pause"), &.{.{ .source = .{ .key = .p } }});
    // A stick cannot feed a button.
    try overrides.set(t_gpa, cid("t:jump"), &.{ .{ .source = .{ .key = .j } }, .{ .source = .{ .pad_stick = .left } } });
    try overrides.set(t_gpa, cid("t:zoom"), &.{.{ .source = .{ .key = .z } }});
    // For content that is not loaded: kept by the caller, ignored here.
    try overrides.set(t_gpa, cid("t:gone"), &.{.{ .source = .{ .key = .g } }});
    var effective = try b.map.apply(t_gpa, &overrides);
    defer effective.deinit(t_gpa);
    try testing.expectEqual(@as(usize, 2), effective.warnings.len);
    var not_rebindable: usize = 0;
    for (effective.warnings) |w| {
        if (w.problem == error.NotRebindable) {
            not_rebindable += 1;
            try testing.expect(w.record.eql(cid("t:pause")));
        } else {
            try testing.expectEqual(error.SourceCannotFeedKind, w.problem);
            try testing.expect(w.record.eql(cid("t:jump")));
            try testing.expectEqual(@as(?u8, 1), w.binding);
        }
    }
    try testing.expectEqual(@as(usize, 1), not_rebindable);
    try testing.expect(bindingsOf(&effective, "t:pause")[0].source.eql(.{ .key = .escape }));
    try testing.expect(bindingsOf(&effective, "t:jump")[0].source.eql(.{ .key = .space }));
    try testing.expect(bindingsOf(&effective, "t:zoom")[0].source.eql(.{ .key = .z }));
    try testing.expectEqualStrings("is not rebindable; the player's override is ignored", map_mod.describe(error.NotRebindable));
}

test "overrides are bounded, validated and kept in content-ID order" {
    var overrides: rebind.Overrides = .empty;
    defer overrides.deinit(t_gpa);
    const nine: [9]schemas.Binding = @splat(.{ .source = .{ .key = .a } });
    try testing.expectError(error.TooManyBindings, overrides.set(t_gpa, cid("t:a"), &nine));
    try testing.expectError(error.InvalidDeadzone, overrides.set(t_gpa, cid("t:a"), &.{.{ .source = .{ .key = .a }, .deadzone = 2 }}));
    try testing.expectError(error.InvalidScale, overrides.set(t_gpa, cid("t:a"), &.{.{ .source = .{ .key = .a }, .scale = 0 }}));
    try testing.expectError(error.InvalidThreshold, overrides.set(t_gpa, cid("t:a"), &.{.{ .source = .{ .key = .a }, .threshold = std.math.nan(f32) }}));
    var names: [rebind.max_overrides][16]u8 = undefined;
    for (0..rebind.max_overrides) |i| try overrides.set(t_gpa, cid(try std.fmt.bufPrint(&names[i], "t:a{d}", .{i})), &.{});
    try testing.expectError(error.TooManyOverrides, overrides.set(t_gpa, cid("t:one_more"), &.{}));
    // Replacing one already there is not past the bound.
    try overrides.set(t_gpa, cid("t:a7"), &.{.{ .source = .{ .key = .b } }});
    try testing.expect(overrides.get(cid("t:a7")).?.bindings()[0].source.eql(.{ .key = .b }));
    const all = overrides.slice();
    for (all[1..], all[0 .. all.len - 1]) |later, earlier| try testing.expect(earlier.action.hash < later.action.hash);
}

test "capture takes the first source that becomes active, in source order, with an axis's sign" {
    var c: rebind.Capture = .{};
    var s = snap();
    // Not armed: nothing.
    down(&s, .k);
    try testing.expect(c.feed(&s) == null);

    try c.start(.{});
    s = snap();
    seat(&s, 0);
    padDown(&s, 0, .south);
    s.mouse.buttons_pressed.set(@intFromEnum(platform.MouseButton.right));
    down(&s, .z);
    down(&s, .b);
    // Keys first, in enum order.
    try testing.expect(c.feed(&s).?.source.eql(.{ .key = .b }));
    // Disarmed once it answers.
    try testing.expect(c.feed(&s) == null);

    try c.start(.{});
    s = snap();
    seat(&s, 0);
    padDown(&s, 0, .south);
    s.mouse.buttons_pressed.set(@intFromEnum(platform.MouseButton.right));
    try testing.expect(c.feed(&s).?.source.eql(.{ .mouse_button = .right }));

    try c.start(.{});
    s = snap();
    seat(&s, 0);
    seat(&s, 2);
    padDown(&s, 2, .north);
    padDown(&s, 0, .west);
    s.mouse.wheel = .init(0, -1);
    try testing.expect(c.feed(&s).?.source.eql(.{ .wheel = .down }));
    s.mouse.wheel = .zero;
    try c.start(.{});
    const got = c.feed(&s).?;
    try testing.expect(got.source.eql(.{ .pad_button = .west }));
    try testing.expectEqual(@as(?u8, 0), got.pad);

    // Pads by slot, and only the slots asked for.
    try c.start(.{ .pads = 0b0100, .keyboard_mouse = false });
    down(&s, .z);
    const third = c.feed(&s).?;
    try testing.expect(third.source.eql(.{ .pad_button = .north }));
    try testing.expectEqual(@as(?u8, 2), third.pad);
}

test "capture ignores motion and the caller's cancel source, and an axis must leave rest" {
    var c: rebind.Capture = .{};
    try c.start(.{ .ignore = &.{ .{ .key = .escape }, .{ .pad_stick = .right } } });
    var s = snap();
    seat(&s, 0);
    s.mouse.motion = .init(100, 100);
    down(&s, .escape);
    // A stick held when capture began has no rest to leave yet.
    padAxis(&s, 0, .left_x, -0.9);
    try testing.expect(c.feed(&s) == null);
    // Still held: still nothing.
    try testing.expect(c.feed(&s) == null);
    // The ignored stick is ignored by its axes too.
    padAxis(&s, 0, .right_y, 1);
    try testing.expect(c.feed(&s) == null);
    // Back to rest, then out again the other way: an axis with a negative sign.
    padAxis(&s, 0, .left_x, 0);
    try testing.expect(c.feed(&s) == null);
    padAxis(&s, 0, .left_x, -0.6);
    const got = c.feed(&s).?;
    try testing.expect(got.source.eql(.{ .pad_axis = .left_x }));
    try testing.expectEqual(@as(f32, -1), got.scale);

    // A trigger, positive.
    try c.start(.{});
    s = snap();
    seat(&s, 1);
    try testing.expect(c.feed(&s) == null);
    padAxis(&s, 1, .right_trigger, 0.51);
    const trigger = c.feed(&s).?;
    try testing.expect(trigger.source.eql(.{ .pad_axis = .right_trigger }));
    try testing.expectEqual(@as(f32, 1), trigger.scale);

    // A pad seated while capturing sets its rest first.
    try c.start(.{});
    s = snap();
    try testing.expect(c.feed(&s) == null);
    seat(&s, 3);
    padAxis(&s, 3, .left_y, 1);
    try testing.expect(c.feed(&s) == null);

    try testing.expectError(error.TooManyIgnored, c.start(.{ .ignore = &([_]Source{.mouse_motion} ** 9) }));
    c.cancel();
    down(&s, .k);
    try testing.expect(c.feed(&s) == null);
}

test "conflicts are the actions sharing a source in contexts enabled together, unless one blocks it" {
    const text =
        \\foundry:input_context t:walk { priority 10 }
        \\foundry:input_context t:drive { priority 15 }
        \\foundry:input_context t:menu { priority 20 blocks true }
        \\foundry:input_action t:jump { kind "button" contexts [ t:walk ] bindings [ { source "key.space" } ] }
        \\foundry:input_action t:wave { kind "button" contexts [ t:walk ] bindings [ { source "key.q" } ] }
        \\foundry:input_action t:horn { kind "button" contexts [ t:drive ] bindings [ { source "key.space" } ] }
        \\foundry:input_action t:confirm { kind "button" contexts [ t:menu ] bindings [ { source "key.space" } ] }
        \\foundry:input_action t:steer { kind "vector" contexts [ t:drive ] bindings [ { source "pad.left_stick" } ] }
        \\foundry:input_action t:lean { kind "axis" contexts [ t:walk ] bindings [ { source "pad.left_x" } ] }
    ;
    const b = try Built.init(text);
    defer b.deinit();
    var buf: [8]ContentId = undefined;
    // Rebinding wave to space: jump (same context) and horn (drive does not block); the menu blocks.
    const found = b.map.conflicts(.{ .key = .space }, cid("t:wave"), &buf);
    try testing.expectEqual(@as(usize, 2), found.len);
    var saw_jump = false;
    var saw_horn = false;
    for (found) |id| {
        saw_jump = saw_jump or id.eql(cid("t:jump"));
        saw_horn = saw_horn or id.eql(cid("t:horn"));
    }
    try testing.expect(saw_jump and saw_horn);
    try testing.expect(found[0].hash < found[1].hash);
    // From the menu's side, too: it hides space from both.
    try testing.expectEqual(@as(usize, 0), b.map.conflicts(.{ .key = .space }, cid("t:confirm"), &buf).len);
    // Not itself.
    try testing.expectEqual(@as(usize, 1), b.map.conflicts(.{ .key = .q }, cid("t:jump"), &buf).len);
    // A stick shares its axes.
    const axes = b.map.conflicts(.{ .pad_axis = .left_x }, cid("t:jump"), &buf);
    try testing.expectEqual(@as(usize, 2), axes.len);
    // An unknown action conflicts with nothing, and `out` bounds the answer.
    try testing.expectEqual(@as(usize, 0), b.map.conflicts(.{ .key = .space }, cid("t:fly"), &buf).len);
    try testing.expectEqual(@as(usize, 1), b.map.conflicts(.{ .key = .space }, cid("t:wave"), buf[0..1]).len);
}

// -- the pinned digest --------------------------------------------------------------

fn foldFrame(h: *std.hash.Fnv1a_64, frame: *const Frame) void {
    for (frame.ids[0..frame.count], frame.states[0..frame.count]) |id, st| {
        h.update(std.mem.asBytes(&id.hash));
        h.update(&.{ @intFromBool(st.held), @intFromBool(st.pressed), @intFromBool(st.released) });
        h.update(std.mem.asBytes(&@as(u32, @bitCast(st.value.x))));
        h.update(std.mem.asBytes(&@as(u32, @bitCast(st.value.y))));
    }
}

fn foldSet(h: *std.hash.Fnv1a_64, set: anytype) void {
    var it = set.iterator(.{});
    while (it.next()) |i| h.update(std.mem.asBytes(&@as(u32, @intCast(i))));
    h.update(&.{0xff});
}

fn foldInput(h: *std.hash.Fnv1a_64, s: *const InputSnapshot) void {
    foldSet(h, s.keys_held);
    foldSet(h, s.keys_pressed);
    foldSet(h, s.keys_released);
    h.update(std.mem.asBytes(&@as(u32, @bitCast(s.mouse.motion.x))));
    h.update(std.mem.asBytes(&@as(u32, @bitCast(s.mouse.motion.y))));
    for (s.gamepads) |pad| {
        foldSet(h, pad.buttons_pressed);
        for (pad.axes) |v| h.update(std.mem.asBytes(&@as(u32, @bitCast(v))));
    }
}

/// 600 frames of scripted input, contexts toggled and an override applied at frame 300, folded
/// from every frame and every tick view.
fn sequenceDigest() !u64 {
    const b = try Built.init(game);
    defer b.deinit();
    var overrides: rebind.Overrides = .empty;
    defer overrides.deinit(t_gpa);
    try overrides.set(t_gpa, cid("t:jump"), &.{ .{ .source = .{ .key = .j } }, .{ .source = .{ .pad_axis = .left_trigger }, .threshold = 0.3 } });
    try overrides.set(t_gpa, cid("t:move"), &.{ .{ .source = .{ .pad_stick = .right }, .deadzone = 0.1, .scale = 0.5 }, .{ .source = .{ .key = .up }, .axis = .y } });
    var effective = try b.map.apply(t_gpa, &overrides);
    defer effective.deinit(t_gpa);

    var a = try walking(b);
    var view: TickView = .empty;
    var rng = core.Pcg32.init(0x45, 0x05);
    var h = std.hash.Fnv1a_64.init();
    const keys = [_]Key{ .space, .w, .a, .s, .d, .e, .q, .left, .right, .escape, .j, .up };
    var held: [keys.len]bool = @splat(false);
    var pad_south = false;
    for (0..600) |frame| {
        if (frame == 300) a.setMap(&effective);
        if (frame % 97 == 50) try a.enable(cid("t:menu"));
        if (frame % 97 == 80) a.disable(cid("t:menu"));
        var s = snap();
        seat(&s, 0);
        if (frame >= 400) seat(&s, 1);
        for (keys, &held) |k, *is| {
            const r = rng.below(16);
            const was = is.*;
            if (r == 0) is.* = !was;
            if (is.*) hold(&s, k);
            if (is.* and !was) platform.key.setKey(&s.keys_pressed, k, true);
            if (!is.* and was) up(&s, k);
            if (r == 1 and !is.*) tap(&s, k);
        }
        if (rng.below(8) == 0) pad_south = !pad_south;
        if (pad_south) padHold(&s, 0, .south);
        for (std.enums.values(platform.GamepadAxis)) |ax| {
            padAxis(&s, 0, ax, rng.float01() * 2 - 1);
            if (frame >= 400) padAxis(&s, 1, ax, rng.float01());
        }
        s.mouse.motion = .init(@floatFromInt(@as(i32, @intCast(rng.below(21))) - 10), @floatFromInt(@as(i32, @intCast(rng.below(7))) - 3));
        if (rng.below(5) == 0) s.mouse.wheel = .init(0, if (rng.boolean()) 1 else -1);
        const options: actions_mod.Options = .{ .blocked = .{ .keyboard = frame % 150 == 149 }, .devices = .{ .pads = if (frame >= 500) 0b0010 else 0b1111 } };
        const f = a.evaluate(&s, options);
        foldFrame(&h, f);
        view.feed(f, &s);
        for (0..rng.below(4)) |_| {
            const t = view.take();
            foldFrame(&h, t.actions);
            foldInput(&h, t.input);
        }
    }
    return h.final();
}

test "a 600-frame scripted sequence folds to its pinned digest, the same twice" {
    const first = try sequenceDigest();
    try testing.expectEqual(first, try sequenceDigest());
    errdefer std.debug.print("input digest: 0x{x:0>16}\n", .{first});
    try testing.expectEqual(@as(u64, 0x003888cb676c2786), first);
}
