//! The per-frame input snapshot, and the accumulator that builds it.
//!
//! **Input is captured once per frame into an immutable snapshot. Simulation reads
//! the snapshot and never queries the device.** This is not tidiness; it is the
//! mechanism that makes I9 achievable:
//!
//! * Two simulation ticks inside one frame see identical input, rather than whatever
//!   the OS happened to deliver between them.
//! * The simulation's inputs become a *value* that can be recorded, replayed, or
//!   eventually sent over a network — with no redesign.
//!
//! Live device state remains available to non-simulation code (debug tools, editor
//! UI), which is fine, because those do not affect simulation outcomes.
//!
//! The accumulator lives here rather than in a backend so that every backend produces
//! identical semantics from the same event sequence. A backend translates OS events
//! into `Event` values and feeds them in; it does not get to invent its own idea of
//! what "pressed this frame" means.
//!
//! Design: `docs/design/platform-interface.md` §4.

const std = @import("std");
const core = @import("core");
const key = @import("key.zig");
const event = @import("event.zig");
const window = @import("window.zig");

const Vec2 = core.math.Vec2;
const Key = key.Key;
const MouseButton = key.MouseButton;

/// Mouse state for one frame.
///
/// Position is reported in both units for the same reason window size is: UI layout
/// works in points and anything hit-testing the rendered image works in pixels, and
/// silently picking one is how the "off by the scale factor on a Retina display" bug
/// gets in (see `window.WindowInfo`).
pub const MouseState = struct {
    /// Logical position (points), relative to the focused window's top-left.
    position: Vec2 = .{},
    /// The same position in device pixels.
    position_pixels: Vec2 = .{},
    /// Total movement since the previous snapshot, in points. Summed across every
    /// motion event in the frame, so a fast flick is not lost to sampling.
    motion: Vec2 = .{},
    /// Total wheel movement since the previous snapshot, in notches.
    wheel: Vec2 = .{},

    buttons_held: key.ButtonSet = key.empty_buttons,
    buttons_pressed: key.ButtonSet = key.empty_buttons,
    buttons_released: key.ButtonSet = key.empty_buttons,

    pub fn isHeld(self: MouseState, b: MouseButton) bool {
        return key.buttonIsSet(self.buttons_held, b);
    }
    pub fn wasPressed(self: MouseState, b: MouseButton) bool {
        return key.buttonIsSet(self.buttons_pressed, b);
    }
    pub fn wasReleased(self: MouseState, b: MouseButton) bool {
        return key.buttonIsSet(self.buttons_released, b);
    }
};

/// One frame of input, by value.
///
/// Both kinds of information are here deliberately. *State* (`keys_held`) answers
/// "what is currently true"; deriving it from events alone makes every consumer keep
/// its own tracking and get focus loss wrong. *Edges* (`keys_pressed`,
/// `keys_released`) answer "what changed this frame"; deriving them from state alone
/// loses a press that begins and ends inside one frame.
///
/// Contains no pointers and no allocation, so it can be copied, stored for a replay
/// log, or compared against a recorded one.
pub const InputSnapshot = struct {
    keys_held: key.KeySet = key.empty_keys,
    keys_pressed: key.KeySet = key.empty_keys,
    keys_released: key.KeySet = key.empty_keys,
    modifiers: key.Modifiers = .{},
    mouse: MouseState = .{},
    /// True when a window had keyboard focus at capture time. Games pause on focus
    /// loss; without this they would need to track focus events themselves.
    focused: bool = false,

    pub fn isHeld(self: *const InputSnapshot, k: Key) bool {
        return key.keyIsSet(self.keys_held, k);
    }
    pub fn wasPressed(self: *const InputSnapshot, k: Key) bool {
        return key.keyIsSet(self.keys_pressed, k);
    }
    pub fn wasReleased(self: *const InputSnapshot, k: Key) bool {
        return key.keyIsSet(self.keys_released, k);
    }

    /// True when nothing at all is held or changed. Useful for tests and for asserting
    /// that a replay's first frame is clean.
    pub fn isIdle(self: *const InputSnapshot) bool {
        return self.keys_held.count() == 0 and
            self.keys_pressed.count() == 0 and
            self.keys_released.count() == 0 and
            self.mouse.buttons_held.count() == 0 and
            self.mouse.buttons_pressed.count() == 0 and
            self.mouse.buttons_released.count() == 0;
    }
};

/// Turns a stream of events into snapshots.
///
/// Held state persists across frames; edges and deltas accumulate within a frame and
/// are cleared by `capture`. A backend calls `apply` for every event it produces
/// during its event pump, then `capture` once.
pub const Accumulator = struct {
    /// Continuous state, carried between frames.
    held: key.KeySet = key.empty_keys,
    buttons_held: key.ButtonSet = key.empty_buttons,
    modifiers: key.Modifiers = .{},
    position: Vec2 = .{},
    position_pixels: Vec2 = .{},
    focused: bool = false,

    /// Edges and deltas, cleared every `capture`.
    pressed: key.KeySet = key.empty_keys,
    released: key.KeySet = key.empty_keys,
    buttons_pressed: key.ButtonSet = key.empty_buttons,
    buttons_released: key.ButtonSet = key.empty_buttons,
    motion: Vec2 = .{},
    wheel: Vec2 = .{},

    pub const init: Accumulator = .{};

    pub fn apply(self: *Accumulator, ev: event.Event) void {
        switch (ev) {
            .key_down => |e| {
                self.modifiers = e.modifiers;
                if (e.key == .unknown) return;
                // An auto-repeat is not a new press. Text fields want repeats and read
                // the event stream for them; gameplay asking "was it pressed this
                // frame" must not see a held key fire sixty times.
                if (e.repeat) return;
                key.setKey(&self.pressed, e.key, true);
                key.setKey(&self.held, e.key, true);
            },
            .key_up => |e| {
                self.modifiers = e.modifiers;
                if (e.key == .unknown) return;
                key.setKey(&self.released, e.key, true);
                key.setKey(&self.held, e.key, false);
            },
            .mouse_button_down => |e| {
                self.modifiers = e.modifiers;
                self.position = e.position;
                key.setButton(&self.buttons_pressed, e.button, true);
                key.setButton(&self.buttons_held, e.button, true);
            },
            .mouse_button_up => |e| {
                self.modifiers = e.modifiers;
                self.position = e.position;
                key.setButton(&self.buttons_released, e.button, true);
                key.setButton(&self.buttons_held, e.button, false);
            },
            .mouse_moved => |e| {
                self.position = e.position;
                self.position_pixels = e.position_pixels;
                self.motion = self.motion.add(e.delta);
            },
            .mouse_wheel => |e| self.wheel = self.wheel.add(e.delta),
            .window_focus_gained => self.focused = true,
            .window_focus_lost => {
                self.focused = false;
                self.dropHeldInput();
            },
            // Nothing here changes input state. Listed rather than caught by `else` so
            // that adding an event variant is a compile error until it is considered.
            .quit_requested, .window_closed, .window_resized, .text_input => {},
        }
    }

    /// Releases everything currently held, reporting each as a release edge.
    ///
    /// Called on focus loss, and this is the specific bug that state-from-events gets
    /// wrong: the OS stops delivering key-up for a key that was down when the window
    /// lost focus, so without this the player alt-tabs away and comes back still
    /// walking left forever.
    pub fn dropHeldInput(self: *Accumulator) void {
        var it = self.held.iterator(.{});
        while (it.next()) |index| self.released.set(index);
        self.held = key.empty_keys;

        var bit = self.buttons_held.iterator(.{});
        while (bit.next()) |index| self.buttons_released.set(index);
        self.buttons_held = key.empty_buttons;

        self.modifiers = .{};
    }

    /// Produces this frame's snapshot and starts the next frame.
    pub fn capture(self: *Accumulator) InputSnapshot {
        const snapshot: InputSnapshot = .{
            .keys_held = self.held,
            .keys_pressed = self.pressed,
            .keys_released = self.released,
            .modifiers = self.modifiers,
            .focused = self.focused,
            .mouse = .{
                .position = self.position,
                .position_pixels = self.position_pixels,
                .motion = self.motion,
                .wheel = self.wheel,
                .buttons_held = self.buttons_held,
                .buttons_pressed = self.buttons_pressed,
                .buttons_released = self.buttons_released,
            },
        };

        self.pressed = key.empty_keys;
        self.released = key.empty_keys;
        self.buttons_pressed = key.empty_buttons;
        self.buttons_released = key.empty_buttons;
        self.motion = .{};
        self.wheel = .{};

        return snapshot;
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

fn keyDown(k: Key) event.Event {
    return .{ .key_down = .{ .key = k } };
}
fn keyUp(k: Key) event.Event {
    return .{ .key_up = .{ .key = k } };
}

test "a press is an edge once, and held state persists" {
    var acc: Accumulator = .init;
    acc.apply(keyDown(.w));

    const first = acc.capture();
    try testing.expect(first.wasPressed(.w));
    try testing.expect(first.isHeld(.w));
    try testing.expect(!first.wasReleased(.w));

    // Next frame with no events: still held, no longer a new press.
    const second = acc.capture();
    try testing.expect(!second.wasPressed(.w));
    try testing.expect(second.isHeld(.w));
}

test "a press and release inside one frame is not lost" {
    // The named reason edges exist as well as state. A snapshot built only from held
    // state would show nothing happened at all.
    var acc: Accumulator = .init;
    acc.apply(keyDown(.space));
    acc.apply(keyUp(.space));

    const snap = acc.capture();
    try testing.expect(snap.wasPressed(.space));
    try testing.expect(snap.wasReleased(.space));
    try testing.expect(!snap.isHeld(.space));
}

test "auto-repeat is not a new press" {
    var acc: Accumulator = .init;
    acc.apply(keyDown(.a));
    _ = acc.capture();

    acc.apply(.{ .key_down = .{ .key = .a, .repeat = true } });
    const snap = acc.capture();
    try testing.expect(!snap.wasPressed(.a));
    try testing.expect(snap.isHeld(.a)); // still down, though
}

test "losing focus releases everything that was held" {
    // Without this the player alt-tabs away mid-stride and returns still walking.
    var acc: Accumulator = .init;
    acc.apply(.{ .window_focus_gained = .{ .window = .none } });
    acc.apply(keyDown(.a));
    acc.apply(.{ .mouse_button_down = .{ .button = .left } });
    _ = acc.capture();

    acc.apply(.{ .window_focus_lost = .{ .window = .none } });
    const snap = acc.capture();

    try testing.expect(!snap.focused);
    try testing.expect(!snap.isHeld(.a));
    try testing.expect(snap.wasReleased(.a));
    try testing.expect(!snap.mouse.isHeld(.left));
    try testing.expect(snap.mouse.wasReleased(.left));
    try testing.expect(snap.modifiers.eql(.none));
}

test "unknown keys never enter the snapshot" {
    var acc: Accumulator = .init;
    acc.apply(keyDown(.unknown));
    const snap = acc.capture();
    try testing.expect(snap.isIdle());
}

test "motion and wheel accumulate across a frame, then reset" {
    var acc: Accumulator = .init;
    acc.apply(.{ .mouse_moved = .{
        .position = .init(10, 10),
        .position_pixels = .init(20, 20),
        .delta = .init(3, 0),
    } });
    acc.apply(.{ .mouse_moved = .{
        .position = .init(14, 10),
        .position_pixels = .init(28, 20),
        .delta = .init(4, 1),
    } });
    acc.apply(.{ .mouse_wheel = .{ .delta = .init(0, 1) } });
    acc.apply(.{ .mouse_wheel = .{ .delta = .init(0, 2) } });

    const snap = acc.capture();
    // A fast flick delivered as several events must not be sampled down to the last one.
    try testing.expectEqual(@as(f32, 7), snap.mouse.motion.x);
    try testing.expectEqual(@as(f32, 1), snap.mouse.motion.y);
    try testing.expectEqual(@as(f32, 3), snap.mouse.wheel.y);
    // Position is the latest value, in both units.
    try testing.expectEqual(@as(f32, 14), snap.mouse.position.x);
    try testing.expectEqual(@as(f32, 28), snap.mouse.position_pixels.x);

    const next = acc.capture();
    try testing.expectEqual(@as(f32, 0), next.mouse.motion.x);
    try testing.expectEqual(@as(f32, 0), next.mouse.wheel.y);
    // ...but position is state, so it persists.
    try testing.expectEqual(@as(f32, 14), next.mouse.position.x);
}

test "a snapshot is a value that outlives the frame that made it" {
    // This is the property replay depends on: hold a snapshot, keep feeding the
    // accumulator, and the held snapshot must not change underneath.
    var acc: Accumulator = .init;
    acc.apply(keyDown(.q));
    const held_snapshot = acc.capture();

    acc.apply(keyUp(.q));
    acc.apply(keyDown(.z));
    _ = acc.capture();

    try testing.expect(held_snapshot.isHeld(.q));
    try testing.expect(!held_snapshot.isHeld(.z));
}

test "the same event sequence always produces the same snapshot" {
    // I9 in miniature: identical inputs, identical result. If this ever fails, replay
    // and lockstep are both off the table.
    const script = [_]event.Event{
        .{ .window_focus_gained = .{ .window = .none } },
        keyDown(.w),
        .{ .mouse_moved = .{ .position = .init(5, 6), .delta = .init(5, 6) } },
        keyDown(.left_shift),
        keyUp(.w),
        .{ .mouse_button_down = .{ .button = .right } },
    };

    var a: Accumulator = .init;
    var b: Accumulator = .init;
    for (script) |ev| a.apply(ev);
    for (script) |ev| b.apply(ev);

    const sa = a.capture();
    const sb = b.capture();
    try testing.expectEqualDeep(sa, sb);
}

test "an idle accumulator produces an idle snapshot" {
    var acc: Accumulator = .init;
    const snap = acc.capture();
    try testing.expect(snap.isIdle());
    try testing.expect(!snap.focused);
}
