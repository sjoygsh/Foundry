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
