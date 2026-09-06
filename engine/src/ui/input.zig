//! One frame of input, as the UI sees it.
//!
//! The kernel is *given* input and never reads a device. `ui` depends on `platform`, so it
//! takes platform's own snapshot rather than restating it — the same value the game's
//! simulation sees, captured once in `app.beginFrame`, which is what makes the UI and the
//! game agree about what the user did (I9).
//!
//! Design: `docs/design/ui.md` §4.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");

const Vec2 = core.math.Vec2;

/// The button the UI treats as "the" pointer button. Right and middle reach widgets that
/// ask for them through `keys.mouse`; the kernel's hot/active model uses this one.
pub const primary: platform.MouseButton = .left;

pub const Input = struct {
    /// Keyboard and mouse state and edges. By value: `InputSnapshot` documents itself as
    /// containing no pointers and no allocation precisely so it can be copied.
    keys: platform.InputSnapshot = .{},
    /// Pointer position in **screen points, +Y down** — the same space as
    /// `render2d.ViewId.screen` and the same units `platform` reports, so a HUD is placed
    /// where the pointer is measured and no scale factor is applied twice.
    ///
    /// Separate from `keys.mouse.position` rather than derived from it, because a caller
    /// may need to offset the pointer into a sub-view before handing it to a UI.
    pointer: Vec2 = .{},
    /// Wheel movement this frame, in notches.
    wheel: Vec2 = .{},
    /// Characters typed this frame, in order. Already valid UTF-8 and already bounded by
    /// `platform.event.max_text_bytes`; the kernel validates anyway, because from M7 the
    /// caller may be a mod.
    text: []const platform.event.TextInput = &.{},
    /// A monotonically increasing frame number.
    ///
    /// **The kernel never reads a clock** (I9). Anything that has to animate — a blinking
    /// caret, a held-button repeat — counts frames, so a hundred frames of a test blink the
    /// same way on every run and on every machine.
    frame: u64 = 0,

    pub fn pointerHeld(self: *const Input) bool {
        return self.keys.mouse.isHeld(primary);
    }
    pub fn pointerPressed(self: *const Input) bool {
        return self.keys.mouse.wasPressed(primary);
    }
    pub fn pointerReleased(self: *const Input) bool {
        return self.keys.mouse.wasReleased(primary);
    }

    /// Convenience for tests and for a caller synthesising input: a pointer at `at` with
    /// the primary button in the given phase.
    pub fn at(position: Vec2, phase: enum { up, pressed, held, released }) Input {
        var self: Input = .{ .pointer = position };
        switch (phase) {
            .up => {},
            .pressed => {
                self.keys.mouse.buttons_held = setOf(primary);
                self.keys.mouse.buttons_pressed = setOf(primary);
            },
            .held => self.keys.mouse.buttons_held = setOf(primary),
            .released => self.keys.mouse.buttons_released = setOf(primary),
        }
        return self;
    }

    fn setOf(button: platform.MouseButton) platform.key.ButtonSet {
        var set = platform.key.empty_buttons;
        set.set(@intFromEnum(button));
        return set;
    }
};

const testing = std.testing;

test "the synthetic helper produces the edges a real backend would" {
    const pressed = Input.at(.init(4, 4), .pressed);
    try testing.expect(pressed.pointerPressed());
    try testing.expect(pressed.pointerHeld());
    try testing.expect(!pressed.pointerReleased());

    const held = Input.at(.init(4, 4), .held);
    try testing.expect(!held.pointerPressed());
    try testing.expect(held.pointerHeld());

    const released = Input.at(.init(4, 4), .released);
    try testing.expect(released.pointerReleased());
    try testing.expect(!released.pointerHeld());

    const up = Input.at(.init(4, 4), .up);
    try testing.expect(!up.pointerHeld());
    try testing.expect(!up.pointerPressed());
    try testing.expect(!up.pointerReleased());
}
