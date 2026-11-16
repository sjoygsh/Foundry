//! The v8 input values (`docs/design/input.md` §10, ADR-0090), exactly as `foundry.h` states
//! them. Every one is `extern`, every enumeration crosses as an integer with its numbers written
//! out, and `agreement.zig` and `agreement.c` hold both languages to the same layout.

const std = @import("std");
const platform = @import("platform");
const input = @import("input");
const types = @import("types.zig");

const Bool = types.Bool;
const Str = types.Str;

/// Key numbers are `platform.Key`'s values; 256 bits holds every one, with room to append.
pub const key_words: usize = 4;

/// `FoundryKeyboardState`. Bit `n % 64` of word `n / 64` is key number `n`.
pub const KeyboardState = extern struct {
    held: [key_words]u64 = @splat(0),
    pressed: [key_words]u64 = @splat(0),
    released: [key_words]u64 = @splat(0),
    /// `FOUNDRY_MODIFIER_*` bits.
    modifiers: u32 = 0,
    focused: Bool = 0,
    reserved: [3]u8 = @splat(0),
};

/// `FoundryMouseState`. Positions in points and pixels; motion in `motion_unit`; the wheel in
/// notches; buttons as `FOUNDRY_MOUSE_*` bits.
pub const MouseState = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    pixel_x: f32 = 0,
    pixel_y: f32 = 0,
    motion_x: f32 = 0,
    motion_y: f32 = 0,
    wheel_x: f32 = 0,
    wheel_y: f32 = 0,
    /// `FOUNDRY_MOTION_POINTS` or `FOUNDRY_MOTION_COUNTS`.
    motion_unit: i32 = 0,
    buttons_held: u32 = 0,
    buttons_pressed: u32 = 0,
    buttons_released: u32 = 0,
    captured: Bool = 0,
    reserved: [7]u8 = @splat(0),
};

/// `FoundryGamepadState`, one slot. Buttons as `FOUNDRY_PAD_*` bits, axes by
/// `FOUNDRY_PAD_AXIS_*`, sticks +y up, triggers in [0, 1], unfiltered.
pub const GamepadState = extern struct {
    connected: Bool = 0,
    reserved0: [3]u8 = @splat(0),
    /// `FOUNDRY_PAD_KIND_*`.
    kind: i32 = 0,
    /// Counts connections to this slot: a different number is a different pad. Zero for a
    /// slot no pad has sat in.
    generation: u32 = 0,
    buttons_held: u32 = 0,
    buttons_pressed: u32 = 0,
    buttons_released: u32 = 0,
    axes: [6]f32 = @splat(0),
    /// `FOUNDRY_PAD_LABEL_*` for the south, east, west and north buttons, in that order.
    face: [4]u8 = @splat(0),
    reserved: [4]u8 = @splat(0),
};

/// `FoundryActionState`.
pub const ActionState = extern struct {
    held: Bool = 0,
    pressed: Bool = 0,
    released: Bool = 0,
    reserved: u8 = 0,
    /// `FOUNDRY_ACTION_*`.
    kind: i32 = 0,
    value_x: f32 = 0,
    value_y: f32 = 0,
};

/// `FoundryBinding`: one effective binding. `source` is borrowed until the next
/// `input_action_binding` call.
pub const Binding = extern struct {
    source: Str = .empty,
    /// `FOUNDRY_AXIS_X` or `FOUNDRY_AXIS_Y`.
    axis: i32 = 0,
    scale: f32 = 0,
    threshold: f32 = 0,
    deadzone: f32 = 0,
    overridden: Bool = 0,
    reserved: [7]u8 = @splat(0),
};

pub const modifier_shift: u32 = 1 << 0;
pub const modifier_ctrl: u32 = 1 << 1;
pub const modifier_alt: u32 = 1 << 2;
pub const modifier_super: u32 = 1 << 3;
pub const modifier_caps_lock: u32 = 1 << 4;
pub const modifier_num_lock: u32 = 1 << 5;

pub const motion_points: i32 = 0;
pub const motion_counts: i32 = 1;

pub const axis_x: i32 = 0;
pub const axis_y: i32 = 1;

pub const gamepad_slots: u32 = platform.gamepad.max_gamepads;

comptime {
    // The header's 256 bits and 32-bit masks hold every key, mouse button and pad button.
    if (platform.Key.count > key_words * 64) @compileError("FoundryKeyboardState holds 256 keys");
    if (platform.MouseButton.count > 32) @compileError("mouse buttons are a uint32_t mask");
    if (platform.GamepadButton.count > 32) @compileError("pad buttons are a uint32_t mask");
    if (platform.GamepadAxis.count != 6) @compileError("FoundryGamepadState has six axes");
}

fn keyWords(set: platform.key.KeySet) [key_words]u64 {
    var out: [key_words]u64 = @splat(0);
    var it = set.iterator(.{});
    while (it.next()) |n| out[n / 64] |= @as(u64, 1) << @intCast(n % 64);
    return out;
}

fn mask(set: anytype) u32 {
    var out: u32 = 0;
    var it = set.iterator(.{});
    while (it.next()) |n| out |= @as(u32, 1) << @intCast(n);
    return out;
}

pub fn keyboardOf(s: *const platform.InputSnapshot) KeyboardState {
    const m = s.modifiers;
    var bits: u32 = 0;
    if (m.shift) bits |= modifier_shift;
    if (m.ctrl) bits |= modifier_ctrl;
    if (m.alt) bits |= modifier_alt;
    if (m.super) bits |= modifier_super;
    if (m.caps_lock) bits |= modifier_caps_lock;
    if (m.num_lock) bits |= modifier_num_lock;
    return .{
        .held = keyWords(s.keys_held),
        .pressed = keyWords(s.keys_pressed),
        .released = keyWords(s.keys_released),
        .modifiers = bits,
        .focused = types.boolOut(s.focused),
    };
}

pub fn mouseOf(s: *const platform.InputSnapshot) MouseState {
    const m = s.mouse;
    return .{
        .x = m.position.x,
        .y = m.position.y,
        .pixel_x = m.position_pixels.x,
        .pixel_y = m.position_pixels.y,
        .motion_x = m.motion.x,
        .motion_y = m.motion.y,
        .wheel_x = m.wheel.x,
        .wheel_y = m.wheel.y,
        .motion_unit = switch (m.motion_unit) {
            .points => motion_points,
            .counts => motion_counts,
        },
        .buttons_held = mask(m.buttons_held),
        .buttons_pressed = mask(m.buttons_pressed),
        .buttons_released = mask(m.buttons_released),
        .captured = types.boolOut(m.captured),
    };
}

pub fn gamepadOf(pad: *const platform.GamepadState) GamepadState {
    var out: GamepadState = .{
        .connected = types.boolOut(pad.connected),
        .kind = @intFromEnum(pad.kind),
        .generation = if (pad.handle.isNone()) 0 else pad.handle.generation,
        .buttons_held = mask(pad.buttons_held),
        .buttons_pressed = mask(pad.buttons_pressed),
        .buttons_released = mask(pad.buttons_released),
        .axes = pad.axes,
    };
    for (pad.face, &out.face) |label, *slot| slot.* = @intFromEnum(label);
    return out;
}

pub fn actionOf(state: input.ActionState, kind: input.Kind) ActionState {
    return .{
        .held = types.boolOut(state.held),
        .pressed = types.boolOut(state.pressed),
        .released = types.boolOut(state.released),
        .kind = @intFromEnum(kind),
        .value_x = state.value.x,
        .value_y = state.value.y,
    };
}

test "a snapshot's sets become the header's bits by number" {
    var s: platform.InputSnapshot = .{ .focused = true };
    platform.key.setKey(&s.keys_held, .menu, true);
    platform.key.setKey(&s.keys_pressed, .a, true);
    s.modifiers.ctrl = true;
    platform.key.setButton(&s.mouse.buttons_held, .forward, true);
    const k = keyboardOf(&s);
    const menu: usize = @intFromEnum(platform.Key.menu);
    try std.testing.expect(k.held[menu / 64] & (@as(u64, 1) << @intCast(menu % 64)) != 0);
    try std.testing.expectEqual(@as(u64, 2), k.pressed[0]);
    try std.testing.expectEqual(modifier_ctrl, k.modifiers);
    try std.testing.expectEqual(@as(Bool, 1), k.focused);
    try std.testing.expectEqual(@as(u32, 1 << 4), mouseOf(&s).buttons_held);
}
