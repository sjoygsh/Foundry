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
const Feed = @import("stream.zig").Feed;

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

/// How a ramp moves between its ends (`music.md` §5.3).
pub const Curve = enum(u8) {
    /// Amplitude moves linearly. Two of these crossing dip 3 dB at the middle.
    linear,
    /// `√t` going up and `√(1 − t)` going down, so two uncorrelated tracks crossing at the
    /// same length keep their summed power. `@sqrt` is exactly rounded by IEEE 754, so the
    /// curve depends on no linked math library.
    equal_power,
};

/// One gain, moving towards a target over a fixed number of mixer frames.
///
/// **A function of the mixer frame**, never of a count the voice keeps, so a voice that
/// is skipped for a buffer cannot fall out of step with the clock. Arithmetic only, which
/// is what the callback rule allows.
///
/// A ramp started while another runs waits as `next` until its begin frame. The running
/// one carries on until then, and the new one starts from wherever that one had got to,
/// so a fade scheduled ahead never jumps. A third replaces the waiting one.
pub const Ramp = struct {
    from: f32 = 1,
    to: f32 = 1,
    /// The mixer frame the ramp begins on.
    begin: u64 = 0,
    /// Zero holds `to`.
    frames: u32 = 0,
    curve: Curve = .linear,
    /// The voice retires when this ramp ends.
    stop: bool = false,
    next: ?Next = null,

    pub const Next = struct {
        begin: u64,
        frames: u32,
        to: f32,
        curve: Curve,
        stop: bool,
    };

    pub fn hold(value: f32) Ramp {
        return .{ .from = value, .to = value };
    }

    /// Queues a ramp to `to` beginning at mixer frame `begin`. Zero frames sets the gain
    /// at `begin`.
    pub fn start(self: *Ramp, next: Next) void {
        self.next = next;
    }

    /// The gain at mixer frame `frame`. Frames are visited in increasing order.
    pub fn at(self: *Ramp, frame: u64) f32 {
        if (self.next) |n| if (frame >= n.begin) {
            self.* = .{
                .from = self.eval(n.begin),
                .to = n.to,
                .begin = n.begin,
                .frames = n.frames,
                .curve = n.curve,
                .stop = n.stop,
            };
        };
        return self.eval(frame);
    }

    /// Whether a stopping ramp has ended by `frame`. Call after `at` for that frame.
    pub fn stopped(self: *const Ramp, frame: u64) bool {
        return self.stop and frame >= self.begin and frame - self.begin >= self.frames;
    }

    fn eval(self: *const Ramp, frame: u64) f32 {
        if (frame <= self.begin) return if (self.frames == 0) self.to else self.from;
        const done = frame - self.begin;
        // The end is the target exactly, not wherever the arithmetic rounded to.
        if (done >= self.frames) return self.to;
        const t: f32 = @floatCast(@as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(self.frames)));
        return self.from + (self.to - self.from) * shape(self.curve, t, self.to >= self.from);
    }
};

/// How far along a ramp the gain is at `t` in [0, 1): 0 is `from` and 1 is `to`.
pub fn shape(curve: Curve, t: f32, rising: bool) f32 {
    return switch (curve) {
        .linear => t,
        // Falling, the gain is `to + (from − to)·√(1 − t)`, which is this shape.
        .equal_power => if (rising) @sqrt(t) else 1.0 - @sqrt(1.0 - t),
    };
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
    /// The loop region, in source frames (`mixing.md` §6.3): a looping voice plays to
    /// `loop_end` and wraps to `loop_start`. A one-shot plays to `frames` and ignores it. A
    /// sound with no loop points has the whole file, `0` to `frames`.
    loop_start: usize = 0,
    loop_end: usize = 0,
    /// The source frame the voice began on (`PlayParams.start_frame`), which a streamed
    /// voice's ring counts from.
    start: usize = 0,

    /// Position in *source frames*. `f64` because a three-minute sound is 8.6 million
    /// frames — far inside the exact-integer range, with ample fractional precision left.
    /// A fixed-point cursor is the upgrade if streaming ever makes lengths unbounded, and
    /// it changes nothing else.
    cursor: f64 = 0,
    step: f64 = 1,

    /// How loud the voice is meant to be: what `setGain` sets and `fadeGain` ramps. Its
    /// output gain is `level × envelope` (`music.md` §5.3).
    level: Ramp = .{},
    /// The voice's shape over time: fades in and out, and crossfades. A stopping fade
    /// retires the voice where it ends.
    envelope: Ramp = .{},
    left: f32 = 1,
    right: f32 = 1,
    looping: bool = false,

    /// Not yet started: the mixer holds it until the buffer that contains `start_at`.
    pending: bool = false,
    /// The mixer frame its first sample lands on.
    start_at: u64 = 0,

    /// A streamed voice reads its frames from here rather than from `samples`
    /// (`music.md` §6.1). The stream outlives the voice: the game thread frees it only after
    /// the retirement this voice pushes, and after its decode task's `Done`.
    feed: ?*Feed = null,
    /// A streamed voice whose start was not scheduled waits for its first frames, since there
    /// is no timeline to keep yet. A scheduled one keeps its frame and underruns instead.
    wait_for_feed: bool = false,
    /// Completed passes of a loop, for a streamed voice's absolute frame (`streamFrame`).
    pass: u64 = 0,
    /// Set by `mix` when a streamed voice found a frame it needed missing, and wrote silence
    /// for it instead (§6.3). The mixer counts it and clears it.
    underran: bool = false,

    /// A spatial voice (`mixing.md` §5): its source is summed to mono, filtered by a one-pole
    /// low-pass, and placed by `left`, `right` and `space`, which the game thread recomputes
    /// each frame. `left` and `right` are the pan's gains here, as they are for any voice.
    spatial: bool = false,
    /// Distance gain times occlusion's gain.
    space: f32 = 1,
    /// The one-pole's coefficient; exactly 1 passes the sample through untouched.
    lowpass: f32 = 1,
    /// The one-pole's memory.
    filtered: f32 = 0,
    /// New placement, reached by the end of the next buffer: each value moves linearly across
    /// it, so a moving source has no step at a buffer's edge (§5.5).
    glide: ?Glide = null,

    /// A stolen voice fading in a fade voice (`mixing.md` §7): the slot whose zombie it is,
    /// which its retirement is reported for. Null for a voice in its own slot.
    owner: ?u32 = null,

    pub const Glide = struct { left: f32, right: f32, space: f32, lowpass: f32 };

    /// Adds this voice's contribution to `out`, which is already zeroed. `frame` is the
    /// mixer frame of `out`'s first frame, which is what the ramps are timed against.
    ///
    /// Returns whether it is still playing. A `false` return means it ended during this
    /// buffer and its slot is owed a retirement.
    pub fn mix(self: *Voice, out: []f32, device_channels: u8, frame: u64) bool {
        if (!self.active or self.frames == 0) return false;

        // A loop wraps at its region's end; a one-shot ends at the file's.
        const end: f64 = @floatFromInt(if (self.looping) self.loop_end else self.frames);
        const region: f64 = @floatFromInt(self.loop_end - self.loop_start);
        const frames_out = out.len / device_channels;
        // Read once per buffer: frames the producer adds meanwhile wait for the next one.
        const available: u64 = if (self.feed) |feed| feed.written.load(.acquire) else 0;
        // However the buffer ends, the stream learns how far this voice has got.
        defer if (self.feed) |feed| feed.release(self.streamFrame(self.pass, @intFromFloat(self.cursor)));

        // A glide's start, held for the buffer; the voice holds its end once the buffer is done.
        const from: Glide = .{ .left = self.left, .right = self.right, .space = self.space, .lowpass = self.lowpass };
        defer if (self.glide) |to| {
            self.left = to.left;
            self.right = to.right;
            self.space = to.space;
            self.lowpass = to.lowpass;
            self.glide = null;
        };

        var f: usize = 0;
        while (f < frames_out) : (f += 1) {
            const now = frame + f;
            const gain = self.level.at(now) * self.envelope.at(now);
            if (self.envelope.stopped(now)) {
                // **A stopping fade retires on its end frame**, which would hold its
                // target, rather than writing it.
                self.active = false;
                return false;
            }
            const index: usize = @intFromFloat(self.cursor);
            const frac: f32 = @floatCast(self.cursor - @floor(self.cursor));
            const next = self.neighbour(index);
            // Positions in the stream for a streamed voice, where a loop's seam reads the next
            // pass's first frame; indices into `samples` otherwise.
            var a: u64 = index;
            var b: u64 = next;
            if (self.feed != null) {
                a = self.streamFrame(self.pass, index);
                b = if (self.looping and index + 1 >= self.loop_end) self.streamFrame(self.pass + 1, next) else self.streamFrame(self.pass, next);
            }

            if (self.feed != null and b >= available) {
                // **An underrun keeps the timeline** (`music.md` §6.3): silence, and the
                // cursor moves on as if the frame had been there.
                self.underran = true;
            } else if (self.spatial) {
                // A point has one position, so a stereo source is summed to mono (§5.6).
                const l = self.lerp(a, b, 0, frac);
                var m = if (self.channels == 1) l else 0.5 * (l + self.lerp(a, b, 1, frac));
                var p = from;
                if (self.glide) |to| {
                    // Reaching `to` exactly on the buffer's last frame.
                    const t: f32 = @as(f32, @floatFromInt(f + 1)) / @as(f32, @floatFromInt(frames_out));
                    p = .{
                        .left = from.left + (to.left - from.left) * t,
                        .right = from.right + (to.right - from.right) * t,
                        .space = from.space + (to.space - from.space) * t,
                        .lowpass = from.lowpass + (to.lowpass - from.lowpass) * t,
                    };
                }
                // A one-pole stays stable under any coefficient in (0, 1], however it is swept.
                if (p.lowpass == 1) self.filtered = m else self.filtered += p.lowpass * (m - self.filtered);
                m = self.filtered;
                if (device_channels == 1) {
                    out[f] += m * p.space * gain;
                } else {
                    out[f * 2] += m * p.left * p.space * gain;
                    out[f * 2 + 1] += m * p.right * p.space * gain;
                }
            } else {
                var left = self.lerp(a, b, 0, frac);
                var right = if (self.channels == 1) left else self.lerp(a, b, 1, frac);

                if (device_channels == 1) {
                    // **Pan is ignored on a mono device**, rather than applied and then
                    // summed. Constant-power gains summed to one channel would make a
                    // centred sound 3 dB quieter than a hard-panned one, which is a strange
                    // thing for panning to do to a listener who has one speaker.
                    out[f] += 0.5 * (left + right) * gain;
                } else {
                    left *= self.left;
                    right *= self.right;
                    out[f * 2] += left * gain;
                    out[f * 2 + 1] += right * gain;
                }
            }

            self.cursor += self.step;
            if (self.cursor >= end) {
                if (!self.looping) {
                    // **The voice ends in the buffer it runs out in**, not the one after.
                    // Checking before writing instead would hold a finished slot for one
                    // more callback, which is a latency nobody can see and a lifetime
                    // rule nobody can state.
                    self.active = false;
                    return false;
                }
                // **Wrapped by the region's length, not reset to its start**, so a loop does
                // not accumulate a fractional-frame error on every pass. A `while` rather
                // than an `if` because a high pitch can carry the cursor past the end more
                // than once on a very short region.
                while (self.cursor >= end) {
                    self.cursor -= region;
                    self.pass += 1;
                }
            }
        }
        return true;
    }

    /// The frame after `index`, for interpolation. A loop reads across its own seam; a
    /// one-shot holds its last frame rather than interpolating towards silence, which
    /// would put a click at the end of every sound that does not fade out itself.
    fn neighbour(self: *const Voice, index: usize) usize {
        if (index + 1 < (if (self.looping) self.loop_end else self.frames)) return index + 1;
        return if (self.looping) self.loop_start else index;
    }

    /// The streamed ring's frame for source frame `index` on pass `pass`. The ring counts from
    /// `start`: the first pass runs from there to `loop_end`, and each later one is the region
    /// again (`mixing.md` §6.3). With the whole file and no start offset it is
    /// `pass * frames + index`, M30's count.
    fn streamFrame(self: *const Voice, pass: u64, index: usize) u64 {
        if (pass == 0) return index - self.start;
        const region: u64 = self.loop_end - self.loop_start;
        return (self.loop_end - self.start) + (pass - 1) * region + (index - self.loop_start);
    }

    fn lerp(self: *const Voice, a: u64, b: u64, channel: u8, frac: f32) f32 {
        const first = self.source(a, channel);
        const second = self.source(b, channel);
        return first + (second - first) * frac;
    }

    fn source(self: *const Voice, frame: u64, channel: u8) f32 {
        if (self.feed) |feed| return feed.sample(frame, channel);
        return self.samples[@as(usize, @intCast(frame)) * self.channels + channel];
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
        // The whole file as the region, as the mixer gives a sound with no loop points.
        .loop_end = samples.len,
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
    try testing.expect(!v.mix(&out, 2, 0));
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
    try testing.expect(!v.mix(&out, 2, 0));
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
        try testing.expect(v.mix(&out, 2, 0));
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
    _ = fast.mix(&out, 2, 0);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    try testing.expectEqual(@as(f32, 2.0), out[2]);

    var slow = monoVoice(&source, false);
    slow.step = 0.5;
    var wide = [_]f32{0} ** 8;
    _ = slow.mix(&wide, 2, 0);
    // Exactly halfway between neighbours, which is what linear interpolation promises.
    try testing.expectEqual(@as(f32, 0.0), wide[0]);
    try testing.expectEqual(@as(f32, 0.5), wide[2]);
    try testing.expectEqual(@as(f32, 1.0), wide[4]);
    try testing.expectEqual(@as(f32, 1.5), wide[6]);
}

test "gain scales, and pan splits without changing the total power" {
    const source = [_]f32{1.0};

    var v = monoVoice(&source, false);
    v.level = .hold(0.25);
    var out = [_]f32{0} ** 2;
    _ = v.mix(&out, 2, 0);
    try testing.expectEqual(@as(f32, 0.25), out[0]);

    const gains = panGains(-1);
    var hard = monoVoice(&source, false);
    hard.left = gains.left;
    hard.right = gains.right;
    var stereo = [_]f32{0} ** 2;
    _ = hard.mix(&stereo, 2, 0);
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
    _ = v.mix(&out, 2, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.35355338), out[1], 1e-6);

    // On one speaker the channels are averaged and the pan gains are not applied, so a
    // centred sound is not quieter than a hard-panned one.
    var mono = v;
    mono.active = true;
    mono.cursor = 0;
    var single = [_]f32{0};
    _ = mono.mix(&single, 1, 0);
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
    _ = first.mix(&out, 2, 0);
    _ = second.mix(&out, 2, 0);
    try testing.expectEqual(@as(f32, 0.75), out[0]);
}

test "an empty sound is not playable, and says so rather than dividing by zero" {
    var v = monoVoice(&.{}, true);
    var out = [_]f32{0} ** 2;
    try testing.expect(!v.mix(&out, 2, 0));
}

test "each ramp's curve at its start, middle and end" {
    // Linear, rising from 0 to 1 over 4 frames beginning at frame 10.
    var up: Ramp = .hold(0);
    up.start(.{ .begin = 10, .frames = 4, .to = 1, .curve = .linear, .stop = false });
    try testing.expectEqual(@as(f32, 0), up.at(9)); // before it begins, it holds
    try testing.expectEqual(@as(f32, 0), up.at(10));
    try testing.expectEqual(@as(f32, 0.5), up.at(12));
    try testing.expectEqual(@as(f32, 1), up.at(14)); // the end is the target exactly
    try testing.expectEqual(@as(f32, 1), up.at(99));

    // Equal power: √t rising and √(1 − t) falling, so the middle is √½ either way.
    var rise: Ramp = .hold(0);
    rise.start(.{ .begin = 0, .frames = 4, .to = 1, .curve = .equal_power, .stop = false });
    var fall: Ramp = .hold(1);
    fall.start(.{ .begin = 0, .frames = 4, .to = 0, .curve = .equal_power, .stop = false });
    try testing.expectEqual(@as(f32, 0), rise.at(0));
    try testing.expectEqual(@as(f32, 1), fall.at(0));
    try testing.expectApproxEqAbs(@sqrt(@as(f32, 0.5)), rise.at(2), 1e-7);
    try testing.expectApproxEqAbs(@sqrt(@as(f32, 0.5)), fall.at(2), 1e-7);
    try testing.expectEqual(@as(f32, 1), rise.at(4));
    try testing.expectEqual(@as(f32, 0), fall.at(4));

    // A ramp queued ahead lets the running one carry on, then starts from where it got.
    var chain: Ramp = .hold(0);
    chain.start(.{ .begin = 0, .frames = 8, .to = 1, .curve = .linear, .stop = false });
    try testing.expectEqual(@as(f32, 0.125), chain.at(1));
    chain.start(.{ .begin = 4, .frames = 2, .to = 0, .curve = .linear, .stop = false });
    try testing.expectEqual(@as(f32, 0.375), chain.at(3));
    try testing.expectEqual(@as(f32, 0.5), chain.at(4));
    try testing.expectEqual(@as(f32, 0.25), chain.at(5));
    try testing.expectEqual(@as(f32, 0), chain.at(6));

    // Visited late, a queued ramp still begins from where the old one was at its begin.
    var late: Ramp = .hold(0);
    late.start(.{ .begin = 0, .frames = 4, .to = 1, .curve = .linear, .stop = false });
    try testing.expectEqual(@as(f32, 0), late.at(0));
    late.start(.{ .begin = 2, .frames = 4, .to = 0, .curve = .linear, .stop = false });
    try testing.expectEqual(@as(f32, 0.25), late.at(4));

    // Zero frames sets the value at its begin frame.
    var snap: Ramp = .hold(0.3);
    snap.start(.{ .begin = 5, .frames = 0, .to = 0.7, .curve = .equal_power, .stop = false });
    try testing.expectEqual(@as(f32, 0.3), snap.at(4));
    try testing.expectEqual(@as(f32, 0.7), snap.at(5));
}

test "level and envelope multiply, each on its own ramp" {
    const source = [_]f32{ 1, 1, 1, 1, 1 };
    var v = monoVoice(&source, false);
    v.level = .hold(0.5);
    v.envelope = .hold(0);
    v.envelope.start(.{ .begin = 0, .frames = 4, .to = 1, .curve = .linear, .stop = false });

    var out = [_]f32{0} ** 5;
    _ = v.mix(&out, 1, 0);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0.125, 0.25, 0.375, 0.5 }, &out);
}

test "a stopping fade retires the voice at its end, having written its ramp" {
    const source = [_]f32{ 1, 1, 1, 1, 1, 1, 1, 1 };
    var v = monoVoice(&source, true);
    v.envelope.start(.{ .begin = 2, .frames = 4, .to = 0, .curve = .linear, .stop = true });

    var out = [_]f32{0} ** 8;
    try testing.expect(!v.mix(&out, 1, 0));
    try testing.expect(!v.active);
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 1, 1, 0.75, 0.5, 0.25, 0, 0 }, &out);
}
