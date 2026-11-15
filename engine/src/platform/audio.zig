//! Audio devices: the buffer the OS asks Foundry to fill, and the rule about the thread
//! it asks on.
//!
//! This file holds no policy. What a *sound* is, what a voice is and how they mix belong
//! to `audio` at L3; what belongs here is the one thing only the platform knows — that
//! somewhere below us there is a device with a clock of its own, and it will call us.
//!
//! **The device speaks `f32` interleaved, always, and that is not negotiated.** A backend
//! is responsible for making it true, converting if the hardware wants `s16`. A sample
//! format in this interface would push a `switch` into the mixer's inner loop for a case
//! that exists only because a driver is old; both SDL3 and CoreAudio convert for free,
//! and on a backend where it is not free it is one pass over a 512-frame buffer, internal
//! to that backend. One representation end to end is ADR-0023's decision, and this
//! interface is where it is enforced.
//!
//! Design: `docs/design/audio.md` §3.

const std = @import("std");
const core = @import("core");

/// Phantom tag for `AudioDeviceHandle`. Never instantiated; it exists so an audio device
/// handle cannot be confused with any other handle type (I1).
pub const AudioDevice = opaque {};

/// A handle, not a singleton, even though there is exactly one output device today.
///
/// **A change of output is not a reopen.** Moving a device to other speakers, or falling back
/// when its chosen output is unplugged, binds the same stream to another OS device, so the handle,
/// its `AudioInfo` and the callback's clock all carry on (`Platform.setAudioOutput`).
///
/// Not because we expect many: because an output device is **closed and reopened in
/// normal use** — headphones are unplugged and the OS moves output elsewhere — and a
/// stale handle surviving that reopen is precisely the use-after-close a generation
/// exists to refuse. The window precedent costs nothing to follow and an exception would
/// need defending.
pub const AudioDeviceHandle = core.Handle(AudioDevice);

/// Fills `out` with `out.len / channels` frames of interleaved `f32`.
///
/// **This runs on a thread Foundry did not create, under a deadline measured in
/// milliseconds.** Inside it: no allocation, no lock, no logging, no filesystem, no
/// `core.log`, and no way to report an error. It fills `out` completely — silence is
/// zeroes, never a short write, because a short write is whatever the driver had in that
/// memory last.
///
/// Nothing enforces this and pretending otherwise would be worse than saying so
/// (ADR-0023). What the design does instead is remove every reason to reach for a
/// forbidden thing: `audio`'s command ring means no lock, its fixed voice pool means no
/// allocation, and everything that can fail was moved to the game thread.
pub const AudioCallback = *const fn (ctx: ?*anyopaque, out: []f32) void;

/// An output the OS can play through: speakers, headphones, an HDMI display.
///
/// **Valid for this session only.** SDL's device IDs, like the OS's beneath them, are not stable
/// across runs, so nothing persists one: a game that remembers a player's choice keeps the
/// output's name in its own preference file and looks it up again (`input.md` §5). A
/// non-exhaustive enum over a `u32` rather than a bare integer, so it cannot be confused with a
/// handle's index or a count.
pub const OutputId = enum(u32) {
    _,

    pub fn fromInt(value: u32) OutputId {
        return @enumFromInt(value);
    }

    pub fn toInt(self: OutputId) u32 {
        return @intFromEnum(self);
    }
};

/// Bytes an output's name keeps, in `OutputInfo`. Longer names are cut on a codepoint.
pub const max_output_name: usize = 128;

/// Outputs a caller is expected to ask for at once. A bound for arrays, not a limit the OS
/// knows: `audioOutputs` fills what it is given.
pub const max_outputs: usize = 32;

/// One output, as `Platform.audioOutputs` lists it.
///
/// **The name is host information**, and often a person's ("<name>'s headphones"). It is for a
/// game's own menu and nothing else: the log never prints one, and the public table does not
/// publish it (M48's "what a mod may learn about its host").
pub const OutputInfo = struct {
    id: OutputId,
    name_bytes: [max_output_name]u8 = @splat(0),
    name_len: u8 = 0,
    /// Whether this is the output a device following the system default plays through now.
    is_default: bool = false,

    /// Builds one from text the OS reported: bounded, cut on a codepoint, and empty if the text
    /// is not UTF-8 or holds a NUL, since it is external input (`CLAUDE.md` §7).
    pub fn init(id: OutputId, name_text: []const u8, is_default: bool) OutputInfo {
        var self: OutputInfo = .{ .id = id, .is_default = is_default };
        const kept = boundedName(name_text, &self.name_bytes);
        self.name_len = @intCast(kept.len);
        return self;
    }

    pub fn name(self: *const OutputInfo) []const u8 {
        return self.name_bytes[0..self.name_len];
    }
};

/// Copies an output's name into `buf`: valid UTF-8 with no NUL, cut on a codepoint boundary. Text
/// that is not valid, or holds a NUL, gives an empty name. Shared by every backend so the same
/// OS text is kept identically everywhere.
pub fn boundedName(text: []const u8, buf: *[max_output_name]u8) []const u8 {
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return buf[0..0];
    var end = @min(text.len, max_output_name);
    // Valid UTF-8 cut before a continuation byte would split a codepoint; step back to its lead.
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    @memcpy(buf[0..end], text[0..end]);
    return buf[0..end];
}

/// The one line a backend logs about outputs, built from numbers alone: how many there are, and
/// where in that list the device now plays, never what any is called (`input.md` §5). Taking no
/// name is what makes "no name reaches the log" structural rather than a habit.
pub fn describeChoice(buf: *[96]u8, count: usize, chosen: ?usize) []const u8 {
    return (if (chosen) |index|
        std.fmt.bufPrint(buf, "audio output: {d} of {d} chosen", .{ index + 1, count })
    else
        std.fmt.bufPrint(buf, "audio output: following the system default, {d} present", .{count})) catch buf[0..0];
}

/// What Foundry asks a device for. Two of these fields are negotiated and one is not.
pub const AudioConfig = struct {
    /// Frames per second. A *request*: the backend may answer with the device's own
    /// rate, and `AudioInfo` is what the mixer must believe.
    sample_rate: u32 = 48_000,
    /// Channels in `out`, interleaved. Also a request.
    channels: u8 = 2,
    /// Frames per callback — the latency knob. 512 at 48 kHz is about 10.7 ms.
    buffer_frames: u32 = 512,
    callback: AudioCallback,
    ctx: ?*anyopaque = null,
    /// The output to play through. Null **follows the system default**, moving when the OS's
    /// default moves; an ID plays there until `setAudioOutput` moves it or the output is lost,
    /// when the device falls back to following the default (`input.md` §5).
    output: ?OutputId = null,
};

/// What the device actually does. The mixer computes against these, never against what
/// it asked for.
pub const AudioInfo = struct {
    sample_rate: u32,
    channels: u8,
    buffer_frames: u32,

    /// Samples per callback: what `out.len` will be.
    pub fn bufferSamples(self: AudioInfo) usize {
        return @as(usize, self.buffer_frames) * self.channels;
    }
};

/// Bounds a backend applies before it allocates anything from these numbers. Generous,
/// because their job is to catch a settings file that says zero or a million, not to
/// have an opinion about latency.
pub const max_channels: u8 = 8;
pub const max_sample_rate: u32 = 768_000;
pub const max_buffer_frames: u32 = 1 << 16;

/// Whether a config describes a buffer a backend could plausibly be asked to fill.
///
/// Shared by every backend so that the same nonsense is refused identically wherever
/// Foundry runs — a config usually comes from a settings file or a mod, which is
/// untrusted input and is validated at the boundary rather than asserted (CLAUDE.md §7).
pub fn supportable(config: AudioConfig) bool {
    return config.channels >= 1 and config.channels <= max_channels and
        config.sample_rate >= 1 and config.sample_rate <= max_sample_rate and
        config.buffer_frames >= 1 and config.buffer_frames <= max_buffer_frames;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

fn silence(ctx: ?*anyopaque, out: []f32) void {
    _ = ctx;
    @memset(out, 0);
}

test "a zeroed audio device handle is none" {
    const h: AudioDeviceHandle = std.mem.zeroes(AudioDeviceHandle);
    try testing.expect(h.isNone());
    try testing.expect(AudioDeviceHandle.none.isNone());
}

test "the buffer's length is frames times channels, not frames" {
    const info: AudioInfo = .{ .sample_rate = 48_000, .channels = 2, .buffer_frames = 512 };
    try testing.expectEqual(@as(usize, 1024), info.bufferSamples());
    // The distinction that a mono/stereo mixing bug is made of.
    const mono: AudioInfo = .{ .sample_rate = 48_000, .channels = 1, .buffer_frames = 512 };
    try testing.expectEqual(@as(usize, 512), mono.bufferSamples());
}

test "a config with a zero in it is refused rather than allocated from" {
    try testing.expect(supportable(.{ .callback = silence }));

    for ([_]AudioConfig{
        .{ .callback = silence, .channels = 0 },
        .{ .callback = silence, .sample_rate = 0 },
        .{ .callback = silence, .buffer_frames = 0 },
        .{ .callback = silence, .channels = max_channels + 1 },
        .{ .callback = silence, .sample_rate = max_sample_rate + 1 },
        .{ .callback = silence, .buffer_frames = max_buffer_frames + 1 },
    }) |config| {
        try testing.expect(!supportable(config));
    }
}

test "an output's name is bounded, cut on a codepoint, and empty when it is not text" {
    const short = OutputInfo.init(.fromInt(7), "MacBook Pro Speakers", true);
    try testing.expectEqualStrings("MacBook Pro Speakers", short.name());
    try testing.expectEqual(@as(u32, 7), short.id.toInt());
    try testing.expect(short.is_default);

    // Exactly the capacity, and one byte over it.
    const exact = "a" ** max_output_name;
    try testing.expectEqualStrings(exact, OutputInfo.init(.fromInt(1), exact, false).name());
    try testing.expectEqualStrings(exact, OutputInfo.init(.fromInt(1), exact ++ "b", false).name());

    // A two-byte `é` straddling the end goes whole, and so does a four-byte codepoint.
    const straddle = ("a" ** (max_output_name - 1)) ++ "\u{e9}";
    try testing.expectEqualStrings("a" ** (max_output_name - 1), OutputInfo.init(.fromInt(1), straddle, false).name());
    const wide = ("a" ** (max_output_name - 2)) ++ "\u{1F3A7}";
    const cut = OutputInfo.init(.fromInt(1), wide, false);
    try testing.expectEqual(max_output_name - 2, cut.name().len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut.name()));

    // External text that is not UTF-8, or that holds a NUL, gives nothing.
    try testing.expectEqualStrings("", OutputInfo.init(.fromInt(1), "\xff\xfe", false).name());
    try testing.expectEqualStrings("", OutputInfo.init(.fromInt(1), "head\x00phones", false).name());
}

test "the outputs' log line carries numbers and never a name" {
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("audio output: 2 of 3 chosen", describeChoice(&buf, 3, 1));
    try testing.expectEqualStrings("audio output: following the system default, 3 present", describeChoice(&buf, 3, null));
    // The largest numbers the line can be asked to carry still fit.
    try testing.expect(describeChoice(&buf, std.math.maxInt(usize), std.math.maxInt(usize) - 1).len > 0);
}

test "a config follows the system default unless it names an output" {
    const follows: AudioConfig = .{ .callback = silence };
    try testing.expect(follows.output == null);
    const chosen: AudioConfig = .{ .callback = silence, .output = .fromInt(3) };
    try testing.expectEqual(@as(u32, 3), chosen.output.?.toInt());
}
