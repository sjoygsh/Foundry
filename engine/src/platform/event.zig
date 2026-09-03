//! Foundry's event type.
//!
//! **Not a renamed SDL union.** It carries only what the engine acts on, and every
//! variant is one Foundry could deliver from a hand-written Cocoa or Win32 backend.
//! Events the OS reports that Foundry has no use for are dropped in the backend
//! rather than passed upward to be ignored.
//!
//! Events are drained once per frame, at one known point, rather than delivered by
//! callback. Callbacks would run engine code at arbitrary points inside the OS event
//! loop and make the ordering of state changes depend on the platform's dispatch
//! behaviour — exactly the kind of dependency I9 forbids.
//!
//! Design: `docs/design/platform-interface.md` §4.

const std = @import("std");
const core = @import("core");
const key = @import("key.zig");
const window = @import("window.zig");

const Vec2 = core.math.Vec2;

/// The maximum UTF-8 bytes one `text_input` event carries.
///
/// Text is delivered by value, not as a pointer into backend-owned memory that expires
/// on the next poll — an event that is only valid until the next call is a trap, and
/// events here can be queued, copied and recorded. Input longer than this arrives as
/// consecutive events, which is correct for every consumer that appends to a buffer.
pub const max_text_bytes = 32;

/// Committed text from the OS's input method, as UTF-8.
///
/// This is the *only* correct source of characters: dead keys, accent composition and
/// CJK input methods cannot be reconstructed from key events, and a key event carries
/// a physical position rather than a character in the first place.
pub const TextInput = struct {
    bytes: [max_text_bytes]u8 = @splat(0),
    len: u8 = 0,

    pub fn text(self: *const TextInput) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Builds an event from a UTF-8 slice, truncating on a codepoint boundary if the
    /// slice does not fit. Returns null for input that is not valid UTF-8 — text from
    /// the OS is external input and is validated, never asserted.
    pub fn fromSlice(utf8: []const u8) ?TextInput {
        if (!std.unicode.utf8ValidateSlice(utf8)) return null;

        var end = @min(utf8.len, max_text_bytes);
        // Back off to the last codepoint boundary so a truncated event is still valid
        // UTF-8 rather than a broken sequence someone downstream has to cope with.
        while (end > 0 and (utf8[end - 1] & 0b1100_0000) == 0b1000_0000) end -= 1;
        if (end > 0 and end < utf8.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(utf8[end - 1]) catch 1;
            if (seq_len > 1) end -= 1;
        }

        var self: TextInput = .{ .len = @intCast(end) };
        @memcpy(self.bytes[0..end], utf8[0..end]);
        return self;
    }
};

pub const KeyEvent = struct {
    key: key.Key,
    modifiers: key.Modifiers = .{},
    /// True when the OS is auto-repeating a held key. Text fields want repeats;
    /// gameplay almost never does, which is why it is reported rather than filtered.
    repeat: bool = false,
};

pub const MouseButtonEvent = struct {
    button: key.MouseButton,
    modifiers: key.Modifiers = .{},
    /// Logical position (points) at the time of the press.
    position: Vec2 = .{},
};

pub const MouseMotion = struct {
    /// Logical position (points), relative to the focused window's top-left.
    position: Vec2 = .{},
    /// Device pixels, for code working against the rendered image.
    position_pixels: Vec2 = .{},
    /// Movement since the previous motion event, in points.
    delta: Vec2 = .{},
};

pub const MouseWheel = struct {
    /// Positive y scrolls away from the user. Units are notches, which are fractional
    /// on trackpads and precise mice.
    delta: Vec2 = .{},
};

pub const WindowEvent = struct {
    window: window.WindowHandle,
};

pub const WindowResized = struct {
    window: window.WindowHandle,
    logical_size: window.Size,
    pixel_size: window.Size,
    scale: f32,
};

/// Something the engine acts on.
pub const Event = union(enum) {
    /// The user asked the application to close — the dock, a window manager, Cmd-Q.
    /// A request, not an order: the engine decides what to do about it.
    quit_requested,

    window_closed: WindowEvent,
    /// Covers a genuine resize, a move between displays of different densities, and a
    /// scale-factor change. All three change what the renderer must do, and no
    /// consumer benefits from telling them apart.
    window_resized: WindowResized,
    window_focus_gained: WindowEvent,
    /// Held input is dropped when focus is lost — see `input.Accumulator`.
    window_focus_lost: WindowEvent,

    key_down: KeyEvent,
    key_up: KeyEvent,
    text_input: TextInput,

    mouse_moved: MouseMotion,
    mouse_button_down: MouseButtonEvent,
    mouse_button_up: MouseButtonEvent,
    mouse_wheel: MouseWheel,
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "text input carries its bytes by value" {
    const t = TextInput.fromSlice("hi").?;
    try testing.expectEqualStrings("hi", t.text());

    // Copying must not alias: an event can be queued and outlive the poll that made it.
    var copy = t;
    copy.bytes[0] = 'H';
    try testing.expectEqualStrings("hi", t.text());
    try testing.expectEqualStrings("Hi", copy.text());
}

test "text input rejects invalid UTF-8 rather than passing it on" {
    // OS text is external input: validated, not asserted.
    try testing.expectEqual(@as(?TextInput, null), TextInput.fromSlice("\xff\xfe"));
}

test "over-long text truncates on a codepoint boundary" {
    // Multi-byte characters filling past the limit: the result must still be valid
    // UTF-8, never a severed sequence.
    const long = "é" ** 40; // 80 bytes
    const t = TextInput.fromSlice(long).?;
    try testing.expect(t.len <= max_text_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(t.text()));
    try testing.expectEqual(@as(usize, 0), t.text().len % 2); // whole 2-byte chars only
}

test "empty text is representable" {
    const t = TextInput.fromSlice("").?;
    try testing.expectEqual(@as(usize, 0), t.text().len);
}

test "a default event value is inert" {
    // Zeroed or defaulted payloads must not look like real input.
    const e: Event = .{ .key_down = .{ .key = .unknown } };
    switch (e) {
        .key_down => |k| {
            try testing.expectEqual(key.Key.unknown, k.key);
            try testing.expect(!k.repeat);
        },
        else => unreachable,
    }
}
