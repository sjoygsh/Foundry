//! Gamepad identity, per-frame state, and the slots pads are seated in.
//!
//! **Buttons are named by position, as keys are** (`key.zig`'s rule): `south` is the bottom face
//! button on an Xbox, a PlayStation and a Nintendo pad alike, so a binding means the same place on
//! each. What is printed on a button is presentation and is reported separately, as the pad's
//! `kind` and its four face labels, for prompts.
//!
//! **Four fixed slots.** A pad that connects takes the lowest free slot and keeps it until it
//! disconnects; a fifth waits, in order of connection, for the next slot to free. A
//! `GamepadHandle`'s index is its slot and its generation counts that slot's connections (I1), so
//! a game holding player two's handle learns that a different pad now sits in slot 1 because the
//! handle no longer matches. `Slots` is the one place that rule lives, and both backends use it,
//! so the same connection sequence gives the same slots everywhere: the accumulator's argument,
//! applied to devices.
//!
//! **Axes are normalised and unfiltered.** Sticks are in [-1, 1] with **+y up, away from the
//! player**, triggers in [0, 1]. No deadzone is applied here: what is near zero is a property of a
//! binding (ADR-0087), which is what lets one stick be read with two deadzones by two actions.
//! Mouse motion keeps its screen convention (+y down); the two differ on purpose.
//!
//! **These names are a compatibility surface** (`CLAUDE.md` §7), like `Key`'s: bindings and
//! saved preferences will name them. Append only.
//!
//! Design: `docs/design/input.md` §4, ADR-0089.

const std = @import("std");
const core = @import("core");

/// How many pads the snapshot holds at once. Its place in the snapshot is a compatibility
/// surface (ADR-0089); a game wanting more is that ADR's revisit trigger.
pub const max_gamepads: usize = 4;

/// Phantom tag for `GamepadHandle`. Never instantiated.
pub const Gamepad = opaque {};

/// A seated pad: its slot is `index`, and `generation` counts connections to that slot, so it
/// never repeats while the platform lives. `none` is the absent pad.
pub const GamepadHandle = core.Handle(Gamepad);

/// A pad button, by position. **Stable names, append only.**
pub const GamepadButton = enum(u8) {
    /// The bottom face button: Xbox `A`, PlayStation cross, Nintendo `B`.
    south = 0,
    /// The right face button: Xbox `B`, PlayStation circle, Nintendo `A`.
    east,
    /// The left face button: Xbox `X`, PlayStation square, Nintendo `Y`.
    west,
    /// The top face button: Xbox `Y`, PlayStation triangle, Nintendo `X`.
    north,
    back,
    guide,
    start,
    left_stick_press,
    right_stick_press,
    left_shoulder,
    right_shoulder,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    /// One extra button some pads have: a share, capture or microphone button.
    misc1,
    left_paddle1,
    left_paddle2,
    right_paddle1,
    right_paddle2,
    touchpad_press,

    pub const count: usize = @typeInfo(GamepadButton).@"enum".fields.len;

    /// The stable name used in configuration files and bindings.
    pub fn name(self: GamepadButton) []const u8 {
        return @tagName(self);
    }

    /// Parses a stable name; null for one this build does not know, which is external input to
    /// report and skip, not a reason to fail.
    pub fn fromName(text: []const u8) ?GamepadButton {
        return std.meta.stringToEnum(GamepadButton, text);
    }
};

/// A pad's analogue inputs. **Stable names, append only.**
pub const GamepadAxis = enum(u8) {
    left_x = 0,
    left_y,
    right_x,
    right_y,
    left_trigger,
    right_trigger,

    pub const count: usize = @typeInfo(GamepadAxis).@"enum".fields.len;

    pub fn name(self: GamepadAxis) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(text: []const u8) ?GamepadAxis {
        return std.meta.stringToEnum(GamepadAxis, text);
    }

    /// Triggers rest at 0 and travel to 1; sticks are centred.
    pub fn isTrigger(self: GamepadAxis) bool {
        return self == .left_trigger or self == .right_trigger;
    }
};

/// What family of pad this is, for a prompt's glyphs. Presentation only; nothing binds by it.
pub const GamepadKind = enum(u8) {
    /// A pad SDL maps but does not recognise as any family below, laid out like an Xbox pad.
    standard,
    xbox,
    playstation,
    nintendo,
    /// The window system could not say.
    other,
};

/// What is printed on a face button.
pub const ButtonLabel = enum(u8) {
    none,
    a,
    b,
    x,
    y,
    cross,
    circle,
    square,
    triangle,
};

/// The labels on the four face buttons, in `south east west north` order. Read from the pad
/// when it is seated, because pads of one kind differ: a GameCube pad and a Switch pad are both
/// `nintendo` and print different letters in the same places.
pub const FaceLabels = [4]ButtonLabel;

pub const no_face_labels: FaceLabels = @splat(.none);

/// A set of pad buttons. A value type, as `KeySet` is.
pub const ButtonSet = std.StaticBitSet(GamepadButton.count);

pub const empty_buttons: ButtonSet = ButtonSet.initEmpty();

/// One slot of the snapshot, for one frame.
pub const GamepadState = struct {
    /// Whether a pad sits in the slot. A pad removed this frame leaves `false` here and its
    /// handle below, with its held buttons reported released.
    connected: bool = false,
    /// The pad in the slot, or the one that last left it.
    handle: GamepadHandle = .none,
    kind: GamepadKind = .other,
    face: FaceLabels = no_face_labels,

    buttons_held: ButtonSet = empty_buttons,
    buttons_pressed: ButtonSet = empty_buttons,
    buttons_released: ButtonSet = empty_buttons,
    /// Indexed by `GamepadAxis`, normalised (`normalizeAxis`): the latest value, unfiltered.
    axes: [GamepadAxis.count]f32 = @splat(0),

    pub fn isHeld(self: GamepadState, b: GamepadButton) bool {
        return self.buttons_held.isSet(@intFromEnum(b));
    }
    pub fn wasPressed(self: GamepadState, b: GamepadButton) bool {
        return self.buttons_pressed.isSet(@intFromEnum(b));
    }
    pub fn wasReleased(self: GamepadState, b: GamepadButton) bool {
        return self.buttons_released.isSet(@intFromEnum(b));
    }
    pub fn axis(self: GamepadState, a: GamepadAxis) f32 {
        return self.axes[@intFromEnum(a)];
    }

    /// What is printed on `b`, for a prompt: a letter or a shape on a face button, `none` on any
    /// other, whose names say what they are.
    pub fn labelOf(self: GamepadState, b: GamepadButton) ButtonLabel {
        return switch (b) {
            .south => self.face[0],
            .east => self.face[1],
            .west => self.face[2],
            .north => self.face[3],
            else => .none,
        };
    }
};

/// A raw axis reading, as a 16-bit device reports it, in Foundry's convention:
/// - divided by 32,767 and clamped at -1, since the range has one more negative step than
///   positive;
/// - **a stick's y negated**, because devices report down as positive and Foundry's +y is up,
///   away from the player;
/// - a trigger clamped to [0, 1].
///
/// Shared by both backends, so a scripted reading means what a real one does.
pub fn normalizeAxis(a: GamepadAxis, raw: i16) f32 {
    const unit = @max(-1.0, @as(f32, @floatFromInt(raw)) / 32767.0);
    return switch (a) {
        .left_x, .right_x => unit,
        .left_y, .right_y => -unit,
        .left_trigger, .right_trigger => @max(0.0, unit),
    };
}

/// The longest rumble one call may ask for. Longer is a mistake, not a feature: a pad left
/// buzzing because its stop was lost is worse than a game that has to ask again.
pub const max_rumble_ms: u32 = 10_000;

/// Whether a rumble request is one every backend can honour: both strengths in [0, 1] (so NaN
/// is refused) and a duration up to `max_rumble_ms`. Zeros are valid, and stop the motors.
pub fn rumbleValid(low: f32, high: f32, duration_ms: u32) bool {
    return low >= 0 and low <= 1 and high >= 0 and high <= 1 and duration_ms <= max_rumble_ms;
}

/// A valid strength as a 16-bit motor level, the width SDL and the OS drivers take.
pub fn rumbleLevel(strength: f32) u16 {
    return @intFromFloat(@round(std.math.clamp(strength, 0, 1) * 65535.0));
}

/// A backend's own name for a physical device: SDL's joystick instance ID, or a test's number on
/// the null backend. **Never leaves `platform`**: above it a pad is only its `GamepadHandle`.
pub const DeviceId = u32;

/// How many pads beyond the four may wait for a slot. A pad past those is ignored and counted,
/// rather than the queue growing without bound.
pub const max_waiting: usize = 12;

/// Which pad sits in which slot, and which wait. Plain fixed-size data, no allocation.
pub const Slots = struct {
    devices: [max_gamepads]?DeviceId = @splat(null),
    /// Each slot's last generation handed out. Zero means the slot was never filled; a handle's
    /// generation is therefore never zero, which keeps `none` distinct (I1).
    generations: [max_gamepads]u32 = @splat(0),
    waiting: [max_waiting]DeviceId = undefined,
    waiting_len: usize = 0,
    /// Pads that connected while every slot and the queue were full. Never seated, until they
    /// reconnect.
    overflowed: u32 = 0,

    pub const empty: Slots = .{};

    pub const Joined = union(enum) {
        /// The pad took this slot, and the handle is new.
        seated: GamepadHandle,
        /// Every slot is taken; the pad waits in connection order.
        waiting,
        /// Every slot and the queue are full; the pad is ignored and counted.
        overflowed,
        /// The device was already seated or waiting. Nothing changed.
        already,
    };

    /// A pad connects. The lowest free slot, or the back of the queue.
    pub fn connect(self: *Slots, device: DeviceId) Joined {
        if (self.handleOf(device) != null or self.isWaiting(device)) return .already;
        for (&self.devices, 0..) |*slot, index| {
            if (slot.* != null) continue;
            return .{ .seated = self.seat(index, device) };
        }
        if (self.waiting_len == max_waiting) {
            self.overflowed += 1;
            return .overflowed;
        }
        self.waiting[self.waiting_len] = device;
        self.waiting_len += 1;
        return .waiting;
    }

    pub const Promotion = struct { device: DeviceId, pad: GamepadHandle };

    pub const Left = struct {
        /// The handle the departing pad held, if it was seated.
        removed: ?GamepadHandle = null,
        /// The first waiting pad, now seated in the freed slot under a new handle.
        promoted: ?Promotion = null,
    };

    /// A pad disconnects. A seated pad frees its slot, which the first waiting pad takes at
    /// once; a waiting pad leaves the queue; an unknown device changes nothing.
    pub fn disconnect(self: *Slots, device: DeviceId) Left {
        for (&self.devices, 0..) |*slot, index| {
            if (slot.* != device) continue;
            const removed = handleAt(index, self.generations[index]);
            slot.* = null;
            if (self.waiting_len == 0) return .{ .removed = removed };
            const next = self.waiting[0];
            std.mem.copyForwards(DeviceId, self.waiting[0 .. self.waiting_len - 1], self.waiting[1..self.waiting_len]);
            self.waiting_len -= 1;
            return .{ .removed = removed, .promoted = .{ .device = next, .pad = self.seat(index, next) } };
        }
        for (self.waiting[0..self.waiting_len], 0..) |waiter, i| {
            if (waiter != device) continue;
            std.mem.copyForwards(DeviceId, self.waiting[i .. self.waiting_len - 1], self.waiting[i + 1 .. self.waiting_len]);
            self.waiting_len -= 1;
            break;
        }
        return .{};
    }

    /// The handle a seated device holds, or null for a waiting or unknown one.
    pub fn handleOf(self: *const Slots, device: DeviceId) ?GamepadHandle {
        for (self.devices, 0..) |slot, index| {
            if (slot == device) return handleAt(index, self.generations[index]);
        }
        return null;
    }

    /// The device a handle names, or null when the handle is stale, `none` or out of range.
    pub fn deviceOf(self: *const Slots, pad: GamepadHandle) ?DeviceId {
        if (pad.isNone() or pad.index >= max_gamepads) return null;
        if (self.generations[pad.index] != pad.generation) return null;
        return self.devices[pad.index];
    }

    fn isWaiting(self: *const Slots, device: DeviceId) bool {
        return std.mem.indexOfScalar(DeviceId, self.waiting[0..self.waiting_len], device) != null;
    }

    fn seat(self: *Slots, index: usize, device: DeviceId) GamepadHandle {
        self.devices[index] = device;
        // Skipping zero on wrap keeps a handle from ever equalling `none`.
        self.generations[index] +%= 1;
        if (self.generations[index] == 0) self.generations[index] = 1;
        return handleAt(index, self.generations[index]);
    }

    fn handleAt(index: usize, generation: u32) GamepadHandle {
        return .{ .index = @intCast(index), .generation = generation };
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "button and axis names round-trip, and are identifier-shaped" {
    for (std.enums.values(GamepadButton)) |b| {
        try testing.expectEqual(b, GamepadButton.fromName(b.name()).?);
        for (b.name()) |ch| try testing.expect((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_');
    }
    for (std.enums.values(GamepadAxis)) |a| try testing.expectEqual(a, GamepadAxis.fromName(a.name()).?);
    try testing.expectEqual(@as(?GamepadButton, null), GamepadButton.fromName("a"));
    // The compatibility surface's shape: positions first, in a fixed order.
    try testing.expectEqual(@as(usize, 21), GamepadButton.count);
    try testing.expectEqual(@as(u8, 0), @intFromEnum(GamepadButton.south));
    try testing.expectEqual(@as(usize, 6), GamepadAxis.count);
}

test "axes are normalised, sticks +y up, triggers from zero, and the extra negative step clamped" {
    try testing.expectEqual(@as(f32, 1), normalizeAxis(.left_x, 32767));
    try testing.expectEqual(@as(f32, -1), normalizeAxis(.left_x, -32768));
    try testing.expectEqual(@as(f32, 0), normalizeAxis(.right_x, 0));
    // A device's down is positive; Foundry's +y is up, away from the player.
    try testing.expectEqual(@as(f32, -1), normalizeAxis(.left_y, 32767));
    try testing.expectEqual(@as(f32, 1), normalizeAxis(.left_y, -32768));
    try testing.expectEqual(@as(f32, 1), normalizeAxis(.right_y, -32767));
    try testing.expectApproxEqAbs(@as(f32, -0.5), normalizeAxis(.right_y, 16384), 1e-4);
    try testing.expectEqual(@as(f32, 1), normalizeAxis(.left_trigger, 32767));
    try testing.expectEqual(@as(f32, 0), normalizeAxis(.right_trigger, -12));
    for (std.enums.values(GamepadAxis)) |a| {
        for ([_]i16{ -32768, -32767, -1, 0, 1, 32767 }) |raw| {
            const v = normalizeAxis(a, raw);
            try testing.expect(v >= -1 and v <= 1);
            if (a.isTrigger()) try testing.expect(v >= 0);
        }
    }
}

test "a face label is the slot's own, and other buttons print none" {
    const sony: GamepadState = .{ .kind = .playstation, .face = .{ .cross, .circle, .square, .triangle } };
    try testing.expectEqual(ButtonLabel.cross, sony.labelOf(.south));
    try testing.expectEqual(ButtonLabel.triangle, sony.labelOf(.north));
    try testing.expectEqual(ButtonLabel.none, sony.labelOf(.start));
    // A Nintendo pad's `east` is `A`: the binding is the place, the label the print.
    const switch_pro: GamepadState = .{ .kind = .nintendo, .face = .{ .b, .a, .y, .x } };
    try testing.expectEqual(ButtonLabel.a, switch_pro.labelOf(.east));
}

test "rumble requests are bounded, and levels span the motor's range" {
    try testing.expect(rumbleValid(0, 0, 0));
    try testing.expect(rumbleValid(1, 0.5, max_rumble_ms));
    try testing.expect(!rumbleValid(1.01, 0, 100));
    try testing.expect(!rumbleValid(0, -0.01, 100));
    try testing.expect(!rumbleValid(std.math.nan(f32), 0, 100));
    try testing.expect(!rumbleValid(0, std.math.inf(f32), 100));
    try testing.expect(!rumbleValid(0.5, 0.5, max_rumble_ms + 1));
    try testing.expectEqual(@as(u16, 0), rumbleLevel(0));
    try testing.expectEqual(@as(u16, 65535), rumbleLevel(1));
    try testing.expectEqual(@as(u16, 32768), rumbleLevel(0.5));
}

test "pads take the lowest free slot and keep it" {
    var slots: Slots = .empty;
    const a = slots.connect(100).seated;
    const b = slots.connect(200).seated;
    const c = slots.connect(300).seated;
    try testing.expectEqual(@as(u32, 0), a.index);
    try testing.expectEqual(@as(u32, 1), b.index);
    try testing.expectEqual(@as(u32, 2), c.index);
    try testing.expect(!a.isNone());

    // Player two leaves: player three keeps slot 2, and the next pad fills the gap.
    try testing.expect(slots.disconnect(200).removed.?.eql(b));
    try testing.expect(slots.handleOf(300).?.eql(c));
    const d = slots.connect(400).seated;
    try testing.expectEqual(@as(u32, 1), d.index);
    // Same slot, new pad: the old handle no longer names anything.
    try testing.expect(!d.eql(b));
    try testing.expectEqual(@as(?DeviceId, null), slots.deviceOf(b));
    try testing.expectEqual(@as(?DeviceId, 400), slots.deviceOf(d));
    try testing.expectEqual(Slots.Joined.already, slots.connect(400));
}

test "a fifth pad waits and takes the first slot to free, in connection order" {
    var slots: Slots = .empty;
    var seated: [max_gamepads]GamepadHandle = undefined;
    for (&seated, 0..) |*h, i| h.* = slots.connect(@intCast(10 + i)).seated;
    try testing.expectEqual(Slots.Joined.waiting, slots.connect(50));
    try testing.expectEqual(Slots.Joined.waiting, slots.connect(60));
    try testing.expectEqual(@as(?GamepadHandle, null), slots.handleOf(50));

    const left = slots.disconnect(12);
    try testing.expect(left.removed.?.eql(seated[2]));
    try testing.expectEqual(@as(DeviceId, 50), left.promoted.?.device);
    try testing.expectEqual(@as(u32, 2), left.promoted.?.pad.index);
    try testing.expect(!left.promoted.?.pad.eql(seated[2]));

    // A waiting pad that leaves before it is seated takes nothing with it.
    const gone = slots.disconnect(60);
    try testing.expectEqual(@as(?GamepadHandle, null), gone.removed);
    try testing.expectEqual(@as(usize, 0), slots.waiting_len);
    try testing.expectEqual(@as(?GamepadHandle, null), slots.disconnect(9999).removed);
}

test "the queue is bounded, and a pad past it is counted rather than kept" {
    var slots: Slots = .empty;
    for (0..max_gamepads + max_waiting) |i| try testing.expect(slots.connect(@intCast(i)) != .overflowed);
    try testing.expectEqual(Slots.Joined.overflowed, slots.connect(777));
    try testing.expectEqual(@as(u32, 1), slots.overflowed);
}

test "generations count a slot's connections, and a reconnect is a new handle" {
    var slots: Slots = .empty;
    const first = slots.connect(1).seated;
    _ = slots.disconnect(1);
    const again = slots.connect(1).seated;
    try testing.expectEqual(first.index, again.index);
    try testing.expectEqual(first.generation + 1, again.generation);
    try testing.expectEqual(@as(?DeviceId, null), slots.deviceOf(first));
    try testing.expectEqual(@as(?DeviceId, null), slots.deviceOf(.none));
    try testing.expectEqual(@as(?DeviceId, null), slots.deviceOf(.{ .index = max_gamepads, .generation = 1 }));
}

test "the same connection sequence gives the same slots" {
    const script = [_]struct { device: DeviceId, connect: bool }{
        .{ .device = 7, .connect = true }, .{ .device = 3, .connect = true },
        .{ .device = 9, .connect = true }, .{ .device = 3, .connect = false },
        .{ .device = 5, .connect = true }, .{ .device = 1, .connect = true },
        .{ .device = 2, .connect = true }, .{ .device = 7, .connect = false },
        .{ .device = 3, .connect = true },
    };
    var a: Slots = .empty;
    var b: Slots = .empty;
    for (script) |s| {
        if (s.connect) _ = a.connect(s.device) else _ = a.disconnect(s.device);
        if (s.connect) _ = b.connect(s.device) else _ = b.disconnect(s.device);
    }
    try testing.expectEqualDeep(a.devices, b.devices);
    try testing.expectEqualDeep(a.generations, b.generations);
    // 2 waited for 7's slot.
    try testing.expectEqual(@as(?DeviceId, 2), a.devices[0]);
}
