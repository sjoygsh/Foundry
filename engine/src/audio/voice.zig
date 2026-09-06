//! One playing sound, as the device thread sees it — and the arithmetic behind it.
//!
//! **Everything in this file runs inside the mix callback.** No allocation, no lock, no
//! logging, no error return (`docs/design/audio.md` §3). What is *not* here is as
//! deliberate: a voice holds no content id, no asset handle and no allocator, because it
//! is not allowed to resolve, acquire or free anything.
//!
//! The pure functions are separated from `mix` so that panning and resampling can be
//! checked without a device at all — which is also what makes their answers arguable
//! rather than merely observed.

const std = @import("std");

/// The two gains a pan produces. Computed once per `set_pan`, never per sample: the
/// trigonometry is not what the callback rule forbids, but doing it 48,000 times a
/// second for a value that changes when the player turns would be silly.
pub const PanGains = struct {
    left: f32,
    right: f32,
};

/// **Constant-power panning.** With `theta = (pan + 1) * pi/4`, left is `cos theta` and
/// right is `sin theta`, so `left^2 + right^2` is 1 everywhere.
///
/// Linear panning is one line shorter and dips about 3 dB in the centre, which is audible
/// as a sound getting quieter as it crosses in front of the player — the exact opposite of
/// what panning is for.
pub fn panGains(pan: f32) PanGains {
    // Clamped rather than asserted: a pan usually comes from gameplay arithmetic, and a
    // position slightly off the end of a room should not be a crash.
    const clamped = std.math.clamp(pan, -1.0, 1.0);
    const theta = (clamped + 1.0) * (std.math.pi / 4.0);
    return .{ .left = @cos(theta), .right = @sin(theta) };
}

/// Pitch is clamped to this range. Zero or negative would make a voice immortal or make
/// it read backwards, neither of which is a thing to discover from a stuck sound.
pub const min_pitch: f32 = 1.0 / 64.0;
pub const max_pitch: f32 = 64.0;

/// Source frames consumed per output frame.
///
/// **A 44.1 kHz sound on a 48 kHz device and a sound played at 0.9x are the same
/// operation**, which is exactly why this lives in the voice rather than at load
/// (ADR-0023): building it once serves both, and neither can be turned off.
pub fn stepFor(source_rate: u32, device_rate: u32, pitch: f32) f64 {
    if (device_rate == 0) return 1.0;
    const ratio = @as(f64, @floatFromInt(source_rate)) / @as(f64, @floatFromInt(device_rate));
    return ratio * std.math.clamp(pitch, min_pitch, max_pitch);
}

pub const Voice = struct {
    active: bool = false,
    /// The generation of the handle this voice was started for. A command carrying a
    /// different one is refused — see `audio.VoiceHandle`.
    generation: u32 = 0,

    /// **Borrowed, and alive for the voice's whole life.** Two independent mechanisms
    /// guarantee that and both are on the game thread: the mixer holds the asset
    /// reference until the voice retires, and a hot reload marks a sound retired rather
    /// than freeing it (`audio.md` §7).
    samples: []const f32 = &.{},
    channels: u8 = 1,
    frames: usize = 0,

    /// Position in *source frames*. `f64` because a three-minute sound is 8.6 million
    /// frames — far inside the exact-integer range, with ample fractional precision left.
    /// A fixed-point cursor is the upgrade if streaming ever makes lengths unbounded, and
    /// it changes nothing else.
    cursor: f64 = 0,
    step: f64 = 1,

    gain: f32 = 1,
    left: f32 = 1,
    right: f32 = 1,
    looping: bool = false,

    /// Adds this voice's contribution to `out`, which is already zeroed.
    ///
    /// Returns whether it is still playing. A `false` return means it ended during this
    /// buffer and its slot is owed a retirement.
    pub fn mix(self: *Voice, out: []f32, device_channels: u8) bool {
        if (!self.active or self.frames == 0) return false;

        const total: f64 = @floatFromInt(self.frames);
        const frames_out = out.len / device_channels;

        var f: usize = 0;
        while (f < frames_out) : (f += 1) {
            const index: usize = @intFromFloat(self.cursor);
            const frac: f32 = @floatCast(self.cursor - @floor(self.cursor));
            const next = self.neighbour(index);

            var left = self.lerp(index, next, 0, frac);
            var right = if (self.channels == 1) left else self.lerp(index, next, 1, frac);

            if (device_channels == 1) {
                // **Pan is ignored on a mono device**, rather than applied and then
                // summed. Constant-power gains summed to one channel would make a
                // centred sound 3 dB quieter than a hard-panned one, which is a strange
                // thing for panning to do to a listener who has one speaker.
                out[f] += 0.5 * (left + right) * self.gain;
            } else {
                left *= self.left;
                right *= self.right;
                out[f * 2] += left * self.gain;
                out[f * 2 + 1] += right * self.gain;
            }

            self.cursor += self.step;
            if (self.cursor >= total) {
                if (!self.looping) {
                    // **The voice ends in the buffer it runs out in**, not the one after.
                    // Checking before writing instead would hold a finished slot for one
                    // more callback, which is a latency nobody can see and a lifetime
                    // rule nobody can state.
                    self.active = false;
                    return false;
                }
                // **Wrapped, not reset to zero**, so a loop does not accumulate a
                // fractional-frame error on every pass. A `while` rather than an `if`
                // because a high pitch can carry the cursor past the end more than once
                // on a very short sound.
                while (self.cursor >= total) self.cursor -= total;
            }
        }
        return true;
    }

    /// The frame after `index`, for interpolation. A loop reads across its own seam; a
    /// one-shot holds its last frame rather than interpolating towards silence, which
    /// would put a click at the end of every sound that does not fade out itself.
    fn neighbour(self: *const Voice, index: usize) usize {
        if (index + 1 < self.frames) return index + 1;
        return if (self.looping) 0 else index;
    }

    fn lerp(self: *const Voice, a: usize, b: usize, channel: u8, frac: f32) f32 {
        const first = self.samples[a * self.channels + channel];
        const second = self.samples[b * self.channels + channel];
        return first + (second - first) * frac;
    }
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "panning holds power constant, and the ends are hard" {
    const centre = panGains(0);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), centre.left, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), centre.right, 1e-6);

    const left = panGains(-1);
    try testing.expectApproxEqAbs(@as(f32, 1.0), left.left, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), left.right, 1e-6);

    const right = panGains(1);
    try testing.expectApproxEqAbs(@as(f32, 0.0), right.left, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), right.right, 1e-6);

    // The property the whole choice is about: no dip as a sound crosses the centre. A
    // linear pan would read 0.5 here and fail.
    var pan: f32 = -1.0;
    while (pan <= 1.0) : (pan += 0.05) {
        const g = panGains(pan);
        try testing.expectApproxEqAbs(@as(f32, 1.0), g.left * g.left + g.right * g.right, 1e-5);
    }

    // Out of range is clamped, not asserted: a pan comes from gameplay arithmetic.
    try testing.expectEqual(panGains(-1).left, panGains(-4).left);
    try testing.expectEqual(panGains(1).right, panGains(9).right);
}

test "the step is the rate ratio times the pitch" {
    try testing.expectEqual(@as(f64, 1.0), stepFor(48_000, 48_000, 1.0));
    try testing.expectEqual(@as(f64, 2.0), stepFor(96_000, 48_000, 1.0));
    try testing.expectEqual(@as(f64, 0.5), stepFor(24_000, 48_000, 1.0));
    // A rate conversion and a pitch shift are one multiplication, which is the point.
    try testing.expectEqual(@as(f64, 1.0), stepFor(24_000, 48_000, 2.0));
    try testing.expectApproxEqAbs(@as(f64, 0.91875), stepFor(44_100, 48_000, 1.0), 1e-12);

    // A pitch of zero would make a voice immortal; a negative one would read backwards.
    try testing.expectEqual(stepFor(48_000, 48_000, min_pitch), stepFor(48_000, 48_000, 0));
    try testing.expectEqual(stepFor(48_000, 48_000, min_pitch), stepFor(48_000, 48_000, -3));
    try testing.expectEqual(stepFor(48_000, 48_000, max_pitch), stepFor(48_000, 48_000, 1000));
}

fn monoVoice(samples: []const f32, looping: bool) Voice {
    return .{
        .active = true,
        .samples = samples,
        .channels = 1,
        .frames = samples.len,
        .looping = looping,
        .left = 1,
        .right = 1,
    };
}

test "at the device's own rate a voice reproduces its samples exactly" {
    const source = [_]f32{ 0.25, -0.5, 0.75, -1.0 };
    var v = monoVoice(&source, false);

    var out = [_]f32{0} ** 8;
    // Four frames into a four-frame buffer: every sample is written, and the voice is
    // finished by the end of it — a one-shot ends in the buffer it runs out in.
    try testing.expect(!v.mix(&out, 2));
    try testing.expect(!v.active);

    // Same rate, unity pitch: no interpolation happens at all, and the values must be
    // bit-identical rather than close. An approximate check here would pass for a
    // resampler that was subtly off by half a frame.
    for (source, 0..) |sample, i| {
        try testing.expectEqual(sample, out[i * 2]);
        try testing.expectEqual(sample, out[i * 2 + 1]);
    }
}

test "a one-shot ends, holds nothing over, and reports its own retirement" {
    const source = [_]f32{ 1.0, 1.0 };
    var v = monoVoice(&source, false);

    var out = [_]f32{0} ** 8;
    // Four output frames for a two-frame sound: it ends halfway through the buffer.
    try testing.expect(!v.mix(&out, 2));
    try testing.expect(!v.active);

    try testing.expectEqual(@as(f32, 1.0), out[0]);
    try testing.expectEqual(@as(f32, 1.0), out[2]);
    // And it wrote nothing after it ended, rather than repeating its last frame.
    try testing.expectEqual(@as(f32, 0.0), out[4]);
    try testing.expectEqual(@as(f32, 0.0), out[6]);
}

test "a loop wraps without drifting" {
    // Three frames at a step that never lands on the seam, run for a long time. A loop
    // that reset the cursor to zero instead of subtracting the length would lose the
    // fraction on every pass, and after a thousand passes be a whole frame out.
    const source = [_]f32{ 0.0, 1.0, 2.0 };
    var v = monoVoice(&source, true);
    v.step = stepFor(44_100, 48_000, 1.0);

    var out = [_]f32{0} ** 2;
    var frames: usize = 0;
    while (frames < 30_000) : (frames += 1) {
        out = .{ 0, 0 };
        try testing.expect(v.mix(&out, 2));
    }

    // Where the cursor should be, computed independently: total advance modulo length.
    const expected = @mod(v.step * @as(f64, @floatFromInt(frames)), 3.0);
    try testing.expectApproxEqAbs(expected, v.cursor, 1e-6);
    try testing.expect(v.active);
}

test "a 2:1 resample takes every other frame, and half-rate interpolates between them" {
    const source = [_]f32{ 0.0, 1.0, 2.0, 3.0 };

    var fast = monoVoice(&source, false);
    fast.step = 2.0;
    var out = [_]f32{0} ** 4;
    _ = fast.mix(&out, 2);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    try testing.expectEqual(@as(f32, 2.0), out[2]);

    var slow = monoVoice(&source, false);
    slow.step = 0.5;
    var wide = [_]f32{0} ** 8;
    _ = slow.mix(&wide, 2);
    // Exactly halfway between neighbours, which is what linear interpolation promises.
    try testing.expectEqual(@as(f32, 0.0), wide[0]);
    try testing.expectEqual(@as(f32, 0.5), wide[2]);
    try testing.expectEqual(@as(f32, 1.0), wide[4]);
    try testing.expectEqual(@as(f32, 1.5), wide[6]);
}

test "gain scales, and pan splits without changing the total power" {
    const source = [_]f32{1.0};

    var v = monoVoice(&source, false);
    v.gain = 0.25;
    var out = [_]f32{0} ** 2;
    _ = v.mix(&out, 2);
    try testing.expectEqual(@as(f32, 0.25), out[0]);

    const gains = panGains(-1);
    var hard = monoVoice(&source, false);
    hard.left = gains.left;
    hard.right = gains.right;
    var stereo = [_]f32{0} ** 2;
    _ = hard.mix(&stereo, 2);
    try testing.expectEqual(@as(f32, 1.0), stereo[0]);
    try testing.expectEqual(@as(f32, 0.0), stereo[1]);
}

test "a stereo source is a balance, and a mono device ignores pan entirely" {
    const source = [_]f32{ 1.0, 0.5 }; // one frame: left 1.0, right 0.5
    var v: Voice = .{
        .active = true,
        .samples = &source,
        .channels = 2,
        .frames = 1,
        .left = panGains(0).left,
        .right = panGains(0).right,
    };

    var out = [_]f32{0} ** 2;
    _ = v.mix(&out, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.35355338), out[1], 1e-6);

    // On one speaker the channels are averaged and the pan gains are not applied, so a
    // centred sound is not quieter than a hard-panned one.
    var mono = v;
    mono.active = true;
    mono.cursor = 0;
    var single = [_]f32{0};
    _ = mono.mix(&single, 1);
    try testing.expectEqual(@as(f32, 0.75), single[0]);
}

test "voices sum into the buffer rather than replacing it" {
    // The reason `mix` adds: two voices in one buffer, and the second must not erase
    // the first.
    const a = [_]f32{0.25};
    const b = [_]f32{0.5};
    var first = monoVoice(&a, false);
    var second = monoVoice(&b, false);

    var out = [_]f32{0} ** 2;
    _ = first.mix(&out, 2);
    _ = second.mix(&out, 2);
    try testing.expectEqual(@as(f32, 0.75), out[0]);
}

test "an empty sound is not playable, and says so rather than dividing by zero" {
    var v = monoVoice(&.{}, true);
    var out = [_]f32{0} ** 2;
    try testing.expect(!v.mix(&out, 2));
}
