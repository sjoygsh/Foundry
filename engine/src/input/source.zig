//! Source names: what a binding reads (`docs/design/input.md` §6.3).
//!
//! **A compatibility surface.** Every name is on authors' disks and in players' bindings files
//! (CLAUDE.md §7), so each is spelled from a name `platform` already freezes:
//! - `key.<Key>`: `key.w`, `key.space`, `key.left_shift`;
//! - `mouse.<MouseButton>`: `mouse.left`; `mouse.motion` and `mouse.wheel`, two 2D deltas; and
//!   `mouse.wheel_up`, `mouse.wheel_down`, `mouse.wheel_left` and `mouse.wheel_right`, buttons
//!   pressed and released in the frame the wheel turned;
//! - `pad.<GamepadButton>`, `pad.<GamepadAxis>`, and `pad.left_stick` and `pad.right_stick`, the
//!   two sticks as one 2D value each.
//!
//! A name this build does not know parses to null. That is not a refusal: content written for a
//! later engine names sources this one lacks, and §6.5 skips those bindings with a warning.

const std = @import("std");
const platform = @import("platform");

const Key = platform.Key;
const MouseButton = platform.MouseButton;
const GamepadButton = platform.GamepadButton;
const GamepadAxis = platform.GamepadAxis;

/// The longest source name a record may carry (§6.5). Every name this build knows fits.
pub const max_name: usize = 32;

/// The wheel's four directions, read as buttons.
pub const WheelDirection = enum(u8) {
    up = 0,
    down,
    left,
    right,

    pub fn name(self: WheelDirection) []const u8 {
        return @tagName(self);
    }
};

/// The two sticks, each read as one radial 2D value.
pub const Stick = enum(u8) {
    left = 0,
    right,

    /// Its axes, `x` then `y`.
    pub fn axes(self: Stick) [2]GamepadAxis {
        return switch (self) {
            .left => .{ .left_x, .left_y },
            .right => .{ .right_x, .right_y },
        };
    }
};

/// What a source delivers, which decides the kinds it may feed (§6.5's table).
pub const Class = enum {
    /// Held or not: a key, a mouse button, a wheel direction, a pad button.
    button,
    /// One value: a pad axis, a stick's component or a trigger.
    axis,
    /// Two values on one radial deadzone: a stick.
    stick,
    /// An unbounded 2D change in the frame: the mouse's motion or its wheel.
    delta,
};

/// One input a binding reads. A value, so a binding can be copied, compared and hashed.
pub const Source = union(enum) {
    key: Key,
    mouse_button: MouseButton,
    mouse_motion,
    mouse_wheel,
    wheel: WheelDirection,
    pad_button: GamepadButton,
    pad_axis: GamepadAxis,
    pad_stick: Stick,

    pub fn class(self: Source) Class {
        return switch (self) {
            .key, .mouse_button, .wheel, .pad_button => .button,
            .pad_axis => .axis,
            .pad_stick => .stick,
            .mouse_motion, .mouse_wheel => .delta,
        };
    }

    pub fn eql(a: Source, b: Source) bool {
        return std.meta.eql(a, b);
    }

    /// Parses a source name, or null for one this build does not know.
    ///
    /// `key.unknown` is not a name: `platform` says that key is never bound, so it reads as a
    /// source this build does not know rather than as one every unmapped key would press.
    pub fn parse(text: []const u8) ?Source {
        if (text.len > max_name) return null;
        if (std.mem.startsWith(u8, text, "key.")) {
            const k = Key.fromName(text["key.".len..]) orelse return null;
            if (k == .unknown) return null;
            return .{ .key = k };
        }
        if (std.mem.startsWith(u8, text, "mouse.")) {
            const rest = text["mouse.".len..];
            if (std.mem.eql(u8, rest, "motion")) return .mouse_motion;
            if (std.mem.eql(u8, rest, "wheel")) return .mouse_wheel;
            if (std.mem.startsWith(u8, rest, "wheel_")) {
                return .{ .wheel = std.meta.stringToEnum(WheelDirection, rest["wheel_".len..]) orelse return null };
            }
            return .{ .mouse_button = MouseButton.fromName(rest) orelse return null };
        }
        if (std.mem.startsWith(u8, text, "pad.")) {
            const rest = text["pad.".len..];
            if (std.mem.eql(u8, rest, "left_stick")) return .{ .pad_stick = .left };
            if (std.mem.eql(u8, rest, "right_stick")) return .{ .pad_stick = .right };
            if (GamepadButton.fromName(rest)) |button| return .{ .pad_button = button };
            if (GamepadAxis.fromName(rest)) |axis| return .{ .pad_axis = axis };
            return null;
        }
        return null;
    }

    /// Writes the name `parse` reads back, into `buf`.
    pub fn name(self: Source, buf: *[max_name]u8) []const u8 {
        return switch (self) {
            .key => |k| join(buf, "key.", k.name()),
            .mouse_button => |b| join(buf, "mouse.", b.name()),
            .mouse_motion => join(buf, "mouse.", "motion"),
            .mouse_wheel => join(buf, "mouse.", "wheel"),
            .wheel => |d| join(buf, "mouse.wheel_", d.name()),
            .pad_button => |b| join(buf, "pad.", b.name()),
            .pad_axis => |a| join(buf, "pad.", a.name()),
            .pad_stick => |s| join(buf, "pad.", if (s == .left) "left_stick" else "right_stick"),
        };
    }
};

/// The physical inputs a source reads, one bit each: every key, every mouse button, the
/// mouse's motion, its wheel, every pad button and every pad axis.
///
/// **Sources overlap where their inputs do.** A stick is its two axes, so blocking
/// `pad.left_stick` hides `pad.left_x`, and the wheel's four directions are the one wheel,
/// so blocking `mouse.wheel_up` hides `mouse.wheel` and `mouse.wheel_down` too. Blocking
/// (§7), conflicts (§8) and a capture's `ignore` all compare sources this way, so a source
/// cannot dodge a rule by being spelled differently. A pad source is every slot's: which pad
/// is a device selection, not a source.
pub const Physical = std.StaticBitSet(physical_count);

const physical_keys: usize = 0;
const physical_mouse: usize = physical_keys + Key.count;
const physical_motion: usize = physical_mouse + MouseButton.count;
const physical_wheel: usize = physical_motion + 1;
const physical_pad_buttons: usize = physical_wheel + 1;
const physical_pad_axes: usize = physical_pad_buttons + GamepadButton.count;
pub const physical_count: usize = physical_pad_axes + GamepadAxis.count;

pub const no_physical: Physical = Physical.initEmpty();

/// Marks the physical inputs `source` reads in `set`.
pub fn markPhysical(set: *Physical, source: Source) void {
    switch (source) {
        .key => |k| set.set(physical_keys + @intFromEnum(k)),
        .mouse_button => |b| set.set(physical_mouse + @intFromEnum(b)),
        .mouse_motion => set.set(physical_motion),
        .mouse_wheel, .wheel => set.set(physical_wheel),
        .pad_button => |b| set.set(physical_pad_buttons + @intFromEnum(b)),
        .pad_axis => |a| set.set(physical_pad_axes + @intFromEnum(a)),
        .pad_stick => |s| for (s.axes()) |a| set.set(physical_pad_axes + @intFromEnum(a)),
    }
}

/// The physical inputs `source` reads.
pub fn physicalOf(source: Source) Physical {
    var set = no_physical;
    markPhysical(&set, source);
    return set;
}

/// Whether two sources read any physical input in common.
pub fn overlaps(a: Source, b: Source) bool {
    return physicalOf(a).intersectWith(physicalOf(b)).count() != 0;
}

fn join(buf: *[max_name]u8, prefix: []const u8, rest: []const u8) []const u8 {
    // Every name this build spells fits; the test below holds that for every one.
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..rest.len], rest);
    return buf[0 .. prefix.len + rest.len];
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

fn expectRoundTrip(source: Source) !void {
    var buf: [max_name]u8 = undefined;
    const text = source.name(&buf);
    try testing.expect(text.len <= max_name);
    const back = Source.parse(text) orelse return error.TestUnexpectedResult;
    try testing.expect(back.eql(source));
}

test "every source this build knows writes a name that parses back to it, within 32 bytes" {
    for (std.enums.values(Key)) |k| {
        if (k == .unknown) continue;
        try expectRoundTrip(.{ .key = k });
    }
    for (std.enums.values(MouseButton)) |b| try expectRoundTrip(.{ .mouse_button = b });
    for (std.enums.values(WheelDirection)) |d| try expectRoundTrip(.{ .wheel = d });
    for (std.enums.values(GamepadButton)) |b| try expectRoundTrip(.{ .pad_button = b });
    for (std.enums.values(GamepadAxis)) |a| try expectRoundTrip(.{ .pad_axis = a });
    try expectRoundTrip(.mouse_motion);
    try expectRoundTrip(.mouse_wheel);
    try expectRoundTrip(.{ .pad_stick = .left });
    try expectRoundTrip(.{ .pad_stick = .right });
}

test "the design's names parse to what they say, each in its class" {
    const cases = [_]struct { text: []const u8, source: Source, class: Class }{
        .{ .text = "key.w", .source = .{ .key = .w }, .class = .button },
        .{ .text = "key.space", .source = .{ .key = .space }, .class = .button },
        .{ .text = "key.left_shift", .source = .{ .key = .left_shift }, .class = .button },
        .{ .text = "mouse.left", .source = .{ .mouse_button = .left }, .class = .button },
        .{ .text = "mouse.motion", .source = .mouse_motion, .class = .delta },
        .{ .text = "mouse.wheel", .source = .mouse_wheel, .class = .delta },
        .{ .text = "mouse.wheel_up", .source = .{ .wheel = .up }, .class = .button },
        .{ .text = "mouse.wheel_right", .source = .{ .wheel = .right }, .class = .button },
        .{ .text = "pad.south", .source = .{ .pad_button = .south }, .class = .button },
        .{ .text = "pad.left_stick_press", .source = .{ .pad_button = .left_stick_press }, .class = .button },
        .{ .text = "pad.right_trigger", .source = .{ .pad_axis = .right_trigger }, .class = .axis },
        .{ .text = "pad.left_y", .source = .{ .pad_axis = .left_y }, .class = .axis },
        .{ .text = "pad.left_stick", .source = .{ .pad_stick = .left }, .class = .stick },
        .{ .text = "pad.right_stick", .source = .{ .pad_stick = .right }, .class = .stick },
    };
    for (cases) |case| {
        const parsed = Source.parse(case.text) orelse return error.TestUnexpectedResult;
        try testing.expect(parsed.eql(case.source));
        try testing.expectEqual(case.class, parsed.class());
    }
}

test "a name this build does not know parses to nothing, never to a near miss" {
    const unknown = [_][]const u8{
        "",       "key.",            "key.unknown",    "key.W",        "keyw",
        "key.w ", "mouse.",          "mouse.button6",  "mouse.wheel_", "mouse.wheel_in",
        "pad.",   "pad.left_stick2", "pad.gyro",       "pad.South",    "touch.0",
        "Key.w",  "pad.misc2",       "mouse.motion.x",
        "key.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", // 33 bytes
    };
    for (unknown) |text| try testing.expect(Source.parse(text) == null);
}

test "a stick's axes are its x and then its y" {
    try testing.expectEqual([2]GamepadAxis{ .left_x, .left_y }, Stick.left.axes());
    try testing.expectEqual([2]GamepadAxis{ .right_x, .right_y }, Stick.right.axes());
}

test "sources overlap where their inputs do, and nowhere else" {
    const left_stick: Source = .{ .pad_stick = .left };
    try testing.expect(overlaps(left_stick, .{ .pad_axis = .left_x }));
    try testing.expect(overlaps(left_stick, .{ .pad_axis = .left_y }));
    try testing.expect(!overlaps(left_stick, .{ .pad_axis = .right_x }));
    try testing.expect(!overlaps(left_stick, .{ .pad_stick = .right }));
    try testing.expect(overlaps(.{ .wheel = .up }, .{ .wheel = .down }));
    try testing.expect(overlaps(.{ .wheel = .up }, .mouse_wheel));
    try testing.expect(!overlaps(.mouse_wheel, .mouse_motion));
    try testing.expect(!overlaps(.{ .key = .a }, .{ .key = .b }));
    try testing.expect(overlaps(.{ .key = .a }, .{ .key = .a }));
    try testing.expect(!overlaps(.{ .mouse_button = .left }, .{ .pad_button = .south }));
    try testing.expect(!overlaps(.{ .pad_button = .south }, .{ .pad_axis = .left_x }));
    // Every source this build knows has a bit of its own somewhere.
    for (std.enums.values(Key)) |k| try testing.expectEqual(@as(usize, 1), physicalOf(.{ .key = k }).count());
    try testing.expectEqual(@as(usize, 2), physicalOf(left_stick).count());
}
