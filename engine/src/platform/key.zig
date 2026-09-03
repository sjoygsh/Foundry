//! Key and mouse-button identity.
//!
//! **Keys are identified by physical position, never by the character the current
//! keyboard layout produces.** WASD must be the same three-across-plus-one-above
//! cluster on AZERTY as on QWERTY, and a binding saved on one layout must mean the
//! same thing on another. Characters come from `text_input` events instead, which is
//! the only correct way to handle dead keys, composition and CJK input methods.
//!
//! The names below describe *where a key is*, using the US QWERTY layout as the
//! reference for naming only. `Key.q` is "the key at the top-left of the letter
//! block" — on AZERTY that key is engraved `A`, and it is still `Key.q` here.
//!
//! **These names are a compatibility surface** (`CLAUDE.md` §7). They will appear in
//! configuration files and in mod-authored bindings, so they are chosen with more care
//! than internal identifiers and are not renamed casually. `name` and `fromName` are
//! the round-trip used for persistence; adding an alias later is cheap, renaming is not.
//!
//! Design: `docs/design/platform-interface.md` §4.

const std = @import("std");

/// A key, by physical position. Deliberately smaller than any OS scancode table: it
/// covers the keys Foundry reports, and backends map the rest to `unknown` rather than
/// passing through a platform-shaped enumeration.
pub const Key = enum(u16) {
    /// A key the backend recognised but Foundry does not name. Never bound; never
    /// serialized as anything meaningful.
    unknown = 0,

    // Letter block, named for US QWERTY positions.
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    // Number row. Named `digit_*` rather than `0`-`9` so they never collide with the
    // keypad and so the identifier is a legal bare enum name.
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,

    // Punctuation, again at US QWERTY positions.
    grave,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,

    // Whitespace and editing.
    escape,
    enter,
    tab,
    space,
    backspace,
    delete,
    insert,

    // Navigation.
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,

    // Modifiers. Left and right are distinct because games bind them distinctly;
    // code that does not care asks `Modifiers` instead.
    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    left_super,
    right_super,
    caps_lock,

    // Function keys.
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    // Keypad. A separate physical cluster, so separate identities.
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_divide,
    kp_multiply,
    kp_minus,
    kp_plus,
    kp_enter,
    kp_period,
    kp_equal,
    num_lock,

    // System keys.
    print_screen,
    scroll_lock,
    pause,
    menu,

    /// Number of distinct keys, including `unknown`. `KeySet` is sized from this, so
    /// adding a key at the end costs nothing; inserting one in the middle renumbers
    /// every key after it and is therefore a save-compatibility change, not a tidy-up.
    pub const count: usize = @typeInfo(Key).@"enum".fields.len;

    /// The stable name used in configuration files and mod bindings.
    pub fn name(self: Key) []const u8 {
        return @tagName(self);
    }

    /// Parses a stable name. Returns null rather than erroring: an unrecognised key
    /// name in a config file is bad external input, to be reported and skipped, not a
    /// reason to fail loading (`docs/design/core-memory-and-handles.md` §5).
    pub fn fromName(text: []const u8) ?Key {
        return std.meta.stringToEnum(Key, text);
    }
};

/// A set of keys. A value type, so an input snapshot can be copied, stored and
/// compared — which is what makes replay possible (I9).
pub const KeySet = std.StaticBitSet(Key.count);

pub const empty_keys: KeySet = KeySet.initEmpty();

pub fn keyIsSet(set: KeySet, k: Key) bool {
    return set.isSet(@intFromEnum(k));
}

pub fn setKey(set: *KeySet, k: Key, value: bool) void {
    set.setValue(@intFromEnum(k), value);
}

/// Mouse buttons. `back` and `forward` are the side buttons; higher-numbered buttons
/// that some mice report are mapped to nothing rather than invented here.
pub const MouseButton = enum(u8) {
    left = 0,
    right,
    middle,
    back,
    forward,

    pub const count: usize = @typeInfo(MouseButton).@"enum".fields.len;

    pub fn name(self: MouseButton) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(text: []const u8) ?MouseButton {
        return std.meta.stringToEnum(MouseButton, text);
    }
};

pub const ButtonSet = std.StaticBitSet(MouseButton.count);

pub const empty_buttons: ButtonSet = ButtonSet.initEmpty();

pub fn buttonIsSet(set: ButtonSet, b: MouseButton) bool {
    return set.isSet(@intFromEnum(b));
}

pub fn setButton(set: *ButtonSet, b: MouseButton, value: bool) void {
    set.setValue(@intFromEnum(b), value);
}

/// Modifier state at the moment an event was produced.
///
/// Separate from held keys because `caps_lock` and `num_lock` are *latched states*,
/// not held keys, and because consumers usually want "any shift" rather than a
/// specific side. A packed struct with an explicit backing integer, so its layout is
/// fixed and it can be recorded for replay without a serializer.
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Command on macOS, Windows key elsewhere.
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _reserved: u2 = 0,

    pub const none: Modifiers = .{};

    pub fn eql(a: Modifiers, b: Modifiers) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "unknown is zero, so a zeroed key is not a real key" {
    try testing.expectEqual(@as(u16, 0), @intFromEnum(Key.unknown));
}

test "every key name round-trips" {
    // The persistence contract: a key written to a config file reads back as the same
    // key. If a rename ever breaks this, it breaks saved bindings, so it is checked.
    for (std.enums.values(Key)) |k| {
        const parsed = Key.fromName(k.name()) orelse return error.NameDidNotParse;
        try testing.expectEqual(k, parsed);
    }
    for (std.enums.values(MouseButton)) |b| {
        try testing.expectEqual(b, MouseButton.fromName(b.name()).?);
    }
}

test "an unrecognised key name is null, not an error" {
    try testing.expectEqual(@as(?Key, null), Key.fromName("nonsense"));
    try testing.expectEqual(@as(?Key, null), Key.fromName(""));
}

test "key names are lowercase and identifier-shaped" {
    // These names go into content and config that mod authors write by hand, so a
    // stray capital or space would be a compatibility wart discovered years later.
    for (std.enums.values(Key)) |k| {
        for (k.name()) |c| {
            try testing.expect((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_');
        }
    }
}

test "key sets hold what is put in them" {
    var set = empty_keys;
    try testing.expect(!keyIsSet(set, .w));
    setKey(&set, .w, true);
    try testing.expect(keyIsSet(set, .w));
    try testing.expect(!keyIsSet(set, .a));
    setKey(&set, .w, false);
    try testing.expect(!keyIsSet(set, .w));
}

test "key sets are values, not references" {
    // Copying a snapshot must not alias it — this is the property that lets a
    // simulation tick hold onto its input while the next frame is captured.
    var a = empty_keys;
    setKey(&a, .space, true);
    var b = a;
    setKey(&b, .space, false);
    try testing.expect(keyIsSet(a, .space));
    try testing.expect(!keyIsSet(b, .space));
}

test "modifiers are one byte with a fixed layout" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(Modifiers));
    const m: Modifiers = .{ .shift = true, .ctrl = true };
    try testing.expectEqual(@as(u8, 0b0000_0011), @as(u8, @bitCast(m)));
    try testing.expect(m.eql(.{ .shift = true, .ctrl = true }));
    try testing.expect(!m.eql(.{ .shift = true }));
}
