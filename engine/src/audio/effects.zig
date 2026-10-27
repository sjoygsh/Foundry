//! The engine's effects, run on a bus's buffer inside the mix callback (`docs/design/mixing.md`
//! §9, ADR-0067).
//!
//! **A fixed set of engine code.** Mods configure effects through records and never supply the
//! code that runs them: device-thread code a mod supplied is the one fault Foundry could not
//! contain (`audio.md` §10).
//!
//! **Allocated when the tree is built, never in the callback.** `Unit.init` takes everything an
//! effect will ever need on the game thread, sized by the fields that are fixed for a tree's
//! life (a delay's time, a reverb's size and predelay). `process` is arithmetic only:
//! `core.math.trig` and `core.math.exp`, never a linked math library, so a mix through these
//! hashes the same in every binary.
//!
//! Step 8 adds the compressor and the limiter. Until then they pass their buffer through.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");

const Allocator = std.mem.Allocator;
const mix = asset.mix;
const trig = core.math.trig;
const exp = core.math.exp;

/// One effect in a bus's chain, with its state.
pub const Unit = union(enum) {
    filter: Filter,
    delay: Delay,
    reverb: Reverb,
    /// Step 8's.
    compressor: mix.Compressor,
    /// Step 8's.
    limiter: mix.Limiter,

    pub fn init(gpa: Allocator, effect: mix.Effect, rate: u32, channels: u8) Allocator.Error!Unit {
        return switch (effect) {
            .filter => |f| .{ .filter = .init(f, rate) },
            .delay => |d| .{ .delay = try .init(gpa, d, rate, channels) },
            .reverb => |r| .{ .reverb = try .init(gpa, r, rate) },
            .compressor => |c| .{ .compressor = c },
            .limiter => |l| .{ .limiter = l },
        };
    }

    pub fn deinit(self: *Unit, gpa: Allocator) void {
        switch (self.*) {
            .delay => |*d| d.deinit(gpa),
            .reverb => |*r| r.deinit(gpa),
            else => {},
        }
    }

    /// `frames` frames of `channels` interleaved, in place.
    pub fn process(self: *Unit, buffer: []f32, channels: u8) void {
        switch (self.*) {
            .filter => |*f| f.process(buffer, channels),
            .delay => |*d| d.process(buffer, channels),
            .reverb => |*r| r.process(buffer, channels),
            .compressor, .limiter => {},
        }
    }

    /// New parameters of the same kind, ramped over `frames` where the effect ramps (a
    /// filter); the rest take them at once. The caller has checked `fixedEql`.
    pub fn set(self: *Unit, effect: mix.Effect, frames: u32) void {
        switch (self.*) {
            .filter => |*f| f.retarget(effect.filter, frames),
            .delay => |*d| d.params = effect.delay,
            .reverb => |*r| r.setParams(effect.reverb),
            .compressor => |*c| c.* = effect.compressor,
            .limiter => |*l| l.* = effect.limiter,
        }
    }
};

/// Whether `b` can replace `a` without a new tree: the same kind, and the same fields that size
/// memory (§8.3). A changed delay time, reverb size or predelay, or limiter lookahead, is a
/// change of shape.
pub fn fixedEql(a: mix.Effect, b: mix.Effect) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .delay => |d| d.time == b.delay.time,
        .reverb => |r| r.size == b.reverb.size and r.predelay == b.reverb.predelay,
        .limiter => |l| l.lookahead == b.limiter.lookahead,
        else => true,
    };
}

// -- the biquad ------------------------------------------------------------------------

/// Normalised biquad coefficients: `y = b0·x + b1·x₋₁ + b2·x₋₂ − a1·y₋₁ − a2·y₋₂`.
pub const Coefficients = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
};

/// The RBJ Audio EQ Cookbook's coefficients for `f` at `rate`. A frequency at or above 0.49
/// of the rate is held there, below Nyquist, where every shape is still defined.
pub fn coefficients(f: mix.Filter, rate: u32) Coefficients {
    const fs: f64 = @floatFromInt(rate);
    const freq = @min(@as(f64, f.frequency), 0.49 * fs);
    const sc = trig.sinCosTurns(freq / fs);
    const sn = sc[0];
    const cs = sc[1];
    const alpha = sn / (2 * @as(f64, f.q));
    // A = 10^(gain/40), the shelves' and peak's amplitude.
    const a: f64 = exp.dbToGain(f.gain_db / 2);
    const sa = @sqrt(a);
    var b0: f64 = 0;
    var b1: f64 = 0;
    var b2: f64 = 0;
    var a0: f64 = 0;
    var a1: f64 = 0;
    var a2: f64 = 0;
    switch (f.shape) {
        .lowpass => {
            b0 = (1 - cs) / 2;
            b1 = 1 - cs;
            b2 = (1 - cs) / 2;
            a0 = 1 + alpha;
            a1 = -2 * cs;
            a2 = 1 - alpha;
        },
        .highpass => {
            b0 = (1 + cs) / 2;
            b1 = -(1 + cs);
            b2 = (1 + cs) / 2;
            a0 = 1 + alpha;
            a1 = -2 * cs;
            a2 = 1 - alpha;
        },
        .bandpass => {
            // Constant 0 dB peak gain.
            b0 = alpha;
            b1 = 0;
            b2 = -alpha;
            a0 = 1 + alpha;
            a1 = -2 * cs;
            a2 = 1 - alpha;
        },
        .peak => {
            b0 = 1 + alpha * a;
            b1 = -2 * cs;
            b2 = 1 - alpha * a;
            a0 = 1 + alpha / a;
            a1 = -2 * cs;
            a2 = 1 - alpha / a;
        },
        .lowshelf => {
            b0 = a * ((a + 1) - (a - 1) * cs + 2 * sa * alpha);
            b1 = 2 * a * ((a - 1) - (a + 1) * cs);
            b2 = a * ((a + 1) - (a - 1) * cs - 2 * sa * alpha);
            a0 = (a + 1) + (a - 1) * cs + 2 * sa * alpha;
            a1 = -2 * ((a - 1) + (a + 1) * cs);
            a2 = (a + 1) + (a - 1) * cs - 2 * sa * alpha;
        },
        .highshelf => {
            b0 = a * ((a + 1) + (a - 1) * cs + 2 * sa * alpha);
            b1 = -2 * a * ((a - 1) + (a + 1) * cs);
            b2 = a * ((a + 1) + (a - 1) * cs - 2 * sa * alpha);
            a0 = (a + 1) - (a - 1) * cs + 2 * sa * alpha;
            a1 = 2 * ((a - 1) - (a + 1) * cs);
            a2 = (a + 1) - (a - 1) * cs - 2 * sa * alpha;
        },
    }
    return .{
        .b0 = @floatCast(b0 / a0),
        .b1 = @floatCast(b1 / a0),
        .b2 = @floatCast(b2 / a0),
        .a1 = @floatCast(a1 / a0),
        .a2 = @floatCast(a2 / a0),
    };
}

/// A biquad in transposed direct form II, whose parameters ramp: the frequency on a
/// logarithmic scale, Q and gain linearly, the coefficients recomputed every `sub_block` frames
/// while a ramp runs (§9).
pub const Filter = struct {
    rate: u32,
    from: mix.Filter,
    to: mix.Filter,
    /// Frames into the ramp, and its length; a finished ramp holds `to`.
    done: u32 = 0,
    frames: u32 = 0,
    c: Coefficients,
    /// Per channel: the two state words of TDF-II.
    z: [2][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 } },

    /// Frames between coefficient updates during a ramp.
    pub const sub_block = 32;

    pub fn init(f: mix.Filter, rate: u32) Filter {
        return .{ .rate = rate, .from = f, .to = f, .c = coefficients(f, rate) };
    }

    /// Ramps from wherever the filter is now to `f` over `frames`; 0 sets it at once.
    pub fn retarget(self: *Filter, f: mix.Filter, frames: u32) void {
        self.from = self.current();
        self.to = f;
        self.done = 0;
        self.frames = frames;
        if (frames == 0) self.c = coefficients(f, self.rate);
    }

    /// The parameters at this point of the ramp.
    pub fn current(self: *const Filter) mix.Filter {
        if (self.done >= self.frames) return self.to;
        const t: f32 = @as(f32, @floatFromInt(self.done)) / @as(f32, @floatFromInt(self.frames));
        const lf = exp.log2(self.from.frequency);
        const lt = exp.log2(self.to.frequency);
        return .{
            .shape = self.to.shape,
            .frequency = exp.exp2(lf + (lt - lf) * t),
            .q = self.from.q + (self.to.q - self.from.q) * t,
            .gain_db = self.from.gain_db + (self.to.gain_db - self.from.gain_db) * t,
        };
    }

    pub fn process(self: *Filter, buffer: []f32, channels: u8) void {
        const frames = buffer.len / channels;
        var f: usize = 0;
        while (f < frames) {
            const ramping = self.done < self.frames;
            const n = if (ramping) @min(frames - f, sub_block) else frames - f;
            if (ramping) self.c = coefficients(self.current(), self.rate);
            const c = self.c;
            for (0..channels) |ch| {
                var z1 = self.z[ch][0];
                var z2 = self.z[ch][1];
                for (f..f + n) |i| {
                    const x = buffer[i * channels + ch];
                    const y = c.b0 * x + z1;
                    z1 = c.b1 * x - c.a1 * y + z2;
                    z2 = c.b2 * x - c.a2 * y;
                    buffer[i * channels + ch] = y;
                }
                self.z[ch] = .{ z1, z2 };
            }
            if (ramping) {
                self.done = @min(self.done + @as(u32, @intCast(n)), self.frames);
                if (self.done >= self.frames) self.c = coefficients(self.to, self.rate);
            }
            f += n;
        }
    }
};

// -- the delay -------------------------------------------------------------------------

/// One line per channel, `time` long, with feedback: `y = dry·x + wet·d`, and the line takes
/// `x + feedback·d`, where `d` is what went in `time` ago.
pub const Delay = struct {
    params: mix.Delay,
    length: usize,
    line: []f32,
    at: usize = 0,

    pub fn init(gpa: Allocator, d: mix.Delay, rate: u32, channels: u8) Allocator.Error!Delay {
        const length: usize = @max(1, @as(usize, @intFromFloat(@round(d.time * @as(f32, @floatFromInt(rate))))));
        const line = try gpa.alloc(f32, length * channels);
        @memset(line, 0);
        return .{ .params = d, .length = length, .line = line };
    }

    pub fn deinit(self: *Delay, gpa: Allocator) void {
        gpa.free(self.line);
    }

    pub fn process(self: *Delay, buffer: []f32, channels: u8) void {
        const p = self.params;
        const frames = buffer.len / channels;
        for (0..frames) |f| {
            for (0..channels) |ch| {
                const slot = &self.line[self.at * channels + ch];
                const x = buffer[f * channels + ch];
                const d = slot.*;
                slot.* = x + p.feedback * d;
                buffer[f * channels + ch] = p.dry * x + p.wet * d;
            }
            self.at += 1;
            if (self.at == self.length) self.at = 0;
        }
    }
};

// -- the reverb ------------------------------------------------------------------------

/// An eight-line feedback delay network (Jot): mutually prime line lengths scaled by `size`, an
/// 8×8 Hadamard mixing matrix, a per-line gain that falls 60 dB in `decay` seconds, a one-pole
/// low-pass per line from `damping`, and a predelay. Stereo out from alternate lines (§9).
pub const Reverb = struct {
    params: mix.Reverb,
    rate: u32,
    /// All eight lines, end to end, then the predelay.
    storage: []f32,
    lines: [8][]f32,
    at: [8]usize = @splat(0),
    gains: [8]f32 = @splat(0),
    damped: [8]f32 = @splat(0),
    damp: f32 = 1,
    predelay: []f32,
    pre_at: usize = 0,

    /// The lines' nominal lengths at size 1, in milliseconds (§9).
    pub const base_ms = [8]f32{ 29.7, 37.1, 41.1, 43.7, 53.0, 59.9, 67.7, 79.3 };

    pub fn init(gpa: Allocator, r: mix.Reverb, rate: u32) Allocator.Error!Reverb {
        var lengths: [8]usize = undefined;
        var total: usize = 0;
        for (base_ms, 0..) |ms, i| {
            // The next prime at or above the nominal length, and above the previous line's:
            // primes are mutually prime, so the lines' echoes never pile up on one frame.
            var n: usize = @max(2, @as(usize, @intFromFloat(@round(ms * r.size * @as(f32, @floatFromInt(rate)) / 1000))));
            if (i > 0) n = @max(n, lengths[i - 1] + 1);
            while (!isPrime(n)) n += 1;
            lengths[i] = n;
            total += n;
        }
        const pre: usize = @max(1, @as(usize, @intFromFloat(@round(r.predelay * @as(f32, @floatFromInt(rate))))));
        const storage = try gpa.alloc(f32, total + pre);
        @memset(storage, 0);
        var self: Reverb = .{ .params = r, .rate = rate, .storage = storage, .lines = undefined, .predelay = storage[total..] };
        var offset: usize = 0;
        for (&self.lines, lengths) |*line, n| {
            line.* = storage[offset..][0..n];
            offset += n;
        }
        self.setParams(r);
        return self;
    }

    pub fn deinit(self: *Reverb, gpa: Allocator) void {
        gpa.free(self.storage);
    }

    /// The parameters that need no memory: decay, damping, wet and dry.
    pub fn setParams(self: *Reverb, r: mix.Reverb) void {
        self.params.decay = r.decay;
        self.params.damping = r.damping;
        self.params.wet = r.wet;
        self.params.dry = r.dry;
        const fs: f32 = @floatFromInt(self.rate);
        // Each line loses 60 dB over `decay`, in proportion to its length.
        for (self.lines, &self.gains) |line, *g| {
            g.* = exp.dbToGain(-60 * @as(f32, @floatFromInt(line.len)) / (r.decay * fs));
        }
        self.damp = 1 - 0.8 * r.damping;
    }

    pub fn process(self: *Reverb, buffer: []f32, channels: u8) void {
        const p = self.params;
        const frames = buffer.len / channels;
        // 1/√8 keeps the Hadamard matrix orthogonal, so the network loses energy only by its
        // gains.
        const norm: f32 = 0.35355339059327373;
        for (0..frames) |f| {
            var input: f32 = buffer[f * channels];
            if (channels == 2) input = 0.5 * (input + buffer[f * channels + 1]);
            const delayed = self.predelay[self.pre_at];
            self.predelay[self.pre_at] = input;
            self.pre_at += 1;
            if (self.pre_at == self.predelay.len) self.pre_at = 0;

            var v: [8]f32 = undefined;
            for (0..8) |i| {
                const out = self.lines[i][self.at[i]];
                // A one-pole per line: high frequencies lose more on each pass.
                self.damped[i] += self.damp * (out - self.damped[i]);
                v[i] = self.damped[i] * self.gains[i];
            }
            const left = (v[0] + v[2] + v[4] + v[6]) * 0.5;
            const right = (v[1] + v[3] + v[5] + v[7]) * 0.5;
            hadamard(&v);
            for (0..8) |i| {
                self.lines[i][self.at[i]] = v[i] * norm + delayed;
                self.at[i] += 1;
                if (self.at[i] == self.lines[i].len) self.at[i] = 0;
            }
            if (channels == 2) {
                buffer[f * 2] = p.dry * buffer[f * 2] + p.wet * left;
                buffer[f * 2 + 1] = p.dry * buffer[f * 2 + 1] + p.wet * right;
            } else {
                buffer[f] = p.dry * buffer[f] + p.wet * 0.5 * (left + right);
            }
        }
    }

    /// The unnormalised 8-point Walsh–Hadamard transform, in place: three butterfly stages.
    fn hadamard(v: *[8]f32) void {
        var h: usize = 1;
        while (h < 8) : (h *= 2) {
            var i: usize = 0;
            while (i < 8) : (i += 2 * h) {
                for (i..i + h) |j| {
                    const a = v[j];
                    const b = v[j + h];
                    v[j] = a + b;
                    v[j + h] = a - b;
                }
            }
        }
    }
};

fn isPrime(n: usize) bool {
    if (n < 2) return false;
    var d: usize = 2;
    while (d * d <= n) : (d += 1) if (n % d == 0) return false;
    return true;
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;
const test_rate = 48_000;

/// |H| at `freq` for `c`, in f64 through `std.math`: the reference the filter is held to.
fn magnitude(c: Coefficients, freq: f64) f64 {
    const w = 2 * std.math.pi * freq / test_rate;
    const re_num = c.b0 + c.b1 * @cos(w) + c.b2 * @cos(2 * w);
    const im_num = -(c.b1 * @sin(w) + c.b2 * @sin(2 * w));
    const re_den = 1 + c.a1 * @cos(w) + c.a2 * @cos(2 * w);
    const im_den = -(c.a1 * @sin(w) + c.a2 * @sin(2 * w));
    return @sqrt((re_num * re_num + im_num * im_num) / (re_den * re_den + im_den * im_den));
}

/// The RBJ formula's own magnitude, in f64 with `std.math`, for the shape at `freq`.
fn rbjMagnitude(f: mix.Filter, freq: f64) f64 {
    const w0 = 2 * std.math.pi * @as(f64, f.frequency) / test_rate;
    const alpha = @sin(w0) / (2 * @as(f64, f.q));
    const cs = @cos(w0);
    const a = std.math.pow(f64, 10, @as(f64, f.gain_db) / 40);
    const sa = @sqrt(a);
    var b: [3]f64 = undefined;
    var d: [3]f64 = undefined;
    switch (f.shape) {
        .lowpass => {
            b = .{ (1 - cs) / 2, 1 - cs, (1 - cs) / 2 };
            d = .{ 1 + alpha, -2 * cs, 1 - alpha };
        },
        .highpass => {
            b = .{ (1 + cs) / 2, -(1 + cs), (1 + cs) / 2 };
            d = .{ 1 + alpha, -2 * cs, 1 - alpha };
        },
        .bandpass => {
            b = .{ alpha, 0, -alpha };
            d = .{ 1 + alpha, -2 * cs, 1 - alpha };
        },
        .peak => {
            b = .{ 1 + alpha * a, -2 * cs, 1 - alpha * a };
            d = .{ 1 + alpha / a, -2 * cs, 1 - alpha / a };
        },
        .lowshelf => {
            b = .{ a * ((a + 1) - (a - 1) * cs + 2 * sa * alpha), 2 * a * ((a - 1) - (a + 1) * cs), a * ((a + 1) - (a - 1) * cs - 2 * sa * alpha) };
            d = .{ (a + 1) + (a - 1) * cs + 2 * sa * alpha, -2 * ((a - 1) + (a + 1) * cs), (a + 1) + (a - 1) * cs - 2 * sa * alpha };
        },
        .highshelf => {
            b = .{ a * ((a + 1) + (a - 1) * cs + 2 * sa * alpha), -2 * a * ((a - 1) + (a + 1) * cs), a * ((a + 1) + (a - 1) * cs - 2 * sa * alpha) };
            d = .{ (a + 1) - (a - 1) * cs + 2 * sa * alpha, 2 * ((a - 1) - (a + 1) * cs), (a + 1) - (a - 1) * cs - 2 * sa * alpha };
        },
    }
    const c: Coefficients = .{
        .b0 = @floatCast(b[0] / d[0]),
        .b1 = @floatCast(b[1] / d[0]),
        .b2 = @floatCast(b[2] / d[0]),
        .a1 = @floatCast(d[1] / d[0]),
        .a2 = @floatCast(d[2] / d[0]),
    };
    return magnitude(c, freq);
}

/// A steady sine at `freq` through `unit`, settled, as a gain in decibels.
fn measuredDb(unit: *Unit, freq: f64) f64 {
    var buffer: [4800]f32 = undefined;
    var phase: f64 = 0;
    var energy: f64 = 0;
    var reference: f64 = 0;
    for (0..20) |block| {
        for (&buffer) |*s| {
            s.* = @floatCast(0.25 * trig.sinCosTurns(phase)[0]);
            phase += freq / test_rate;
        }
        var dry: [4800]f32 = buffer;
        unit.process(&buffer, 1);
        if (block < 10) continue;
        for (buffer, &dry) |y, *x| {
            energy += @as(f64, y) * y;
            reference += @as(f64, x.*) * x.*;
        }
    }
    return 10 * std.math.log10(energy / reference);
}

test "each filter shape's magnitude is the RBJ formula's within 0.1 dB at f0/2, f0 and 2f0" {
    for (std.enums.values(mix.Shape)) |shape| {
        const f: mix.Filter = .{ .shape = shape, .frequency = 1000, .q = 0.7071, .gain_db = 6 };
        for ([_]f64{ 500, 1000, 2000 }) |freq| {
            var unit = try Unit.init(testing.allocator, .{ .filter = f }, test_rate, 1);
            defer unit.deinit(testing.allocator);
            const want = 20 * std.math.log10(rbjMagnitude(f, freq));
            const got = measuredDb(&unit, freq);
            if (@abs(got - want) > 0.1) {
                std.debug.print("{t} at {d} Hz: {d:.3} dB against {d:.3}\n", .{ shape, freq, got, want });
                return error.TestExpectedApproxEqAbs;
            }
            // And the written-out coefficients agree with the reference's to f32 rounding.
            try testing.expectApproxEqAbs(rbjMagnitude(f, freq), magnitude(coefficients(f, test_rate), freq), 1e-5);
        }
    }
}

test "a filter ramps to its target without a jump, and holds it after" {
    var f = Filter.init(.{ .shape = .lowpass, .frequency = 20_000 }, test_rate);
    f.retarget(.{ .shape = .lowpass, .frequency = 800 }, 12_000);
    var buffer: [512]f32 = undefined;
    var frames: usize = 0;
    while (frames < 24_000) : (frames += 512) {
        for (&buffer, 0..) |*s, i| s.* = if ((frames + i) % 2 == 0) 0.5 else -0.5;
        f.process(&buffer, 1);
        for (buffer) |s| try testing.expect(std.math.isFinite(s) and @abs(s) < 1);
    }
    try testing.expectEqual(f.to, f.current());
    try testing.expectEqual(coefficients(f.to, test_rate), f.c);
}

test "the delay echoes at exactly its time, at its wet gain, and again at its feedback" {
    var unit = try Unit.init(testing.allocator, .{ .delay = .{ .time = 0.01, .feedback = 0.5, .wet = 0.4, .dry = 1 } }, test_rate, 2);
    defer unit.deinit(testing.allocator);
    var buffer: [2 * 1500]f32 = @splat(0);
    buffer[0] = 1;
    buffer[1] = -1;
    unit.process(&buffer, 2);
    try testing.expectEqual(@as(f32, 1), buffer[0]);
    try testing.expectEqual(@as(f32, 0.4), buffer[480 * 2]);
    try testing.expectEqual(@as(f32, -0.4), buffer[480 * 2 + 1]);
    try testing.expectEqual(@as(f32, 0.4 * 0.5), buffer[960 * 2]);
    for (buffer, 0..) |s, i| {
        const frame = i / 2;
        if (frame != 0 and frame != 480 and frame != 960 and frame != 1440) try testing.expectEqual(@as(f32, 0), s);
    }
}

/// The reverb's decay from its impulse response: the Schroeder integral, from −5 dB to −35 dB,
/// extrapolated to 60 (T30).
fn measuredDecay(decay: f32, damping: f32) !f64 {
    var unit = try Unit.init(testing.allocator, .{ .reverb = .{ .decay = decay, .damping = damping, .size = 1, .predelay = 0.01, .wet = 1, .dry = 0 } }, test_rate, 1);
    defer unit.deinit(testing.allocator);
    const total: usize = @intFromFloat(@ceil(decay * 1.5 * test_rate));
    const energy = try testing.allocator.alloc(f64, total);
    defer testing.allocator.free(energy);
    var buffer: [480]f32 = undefined;
    var at: usize = 0;
    while (at < total) {
        @memset(&buffer, 0);
        if (at == 0) buffer[0] = 1;
        unit.process(&buffer, 1);
        for (buffer) |s| {
            if (at < total) energy[at] = @as(f64, s) * s;
            at += 1;
        }
    }
    // Backward integration, then the times the curve crosses −5 and −35 dB.
    var i = total;
    var sum: f64 = 0;
    while (i > 0) {
        i -= 1;
        sum += energy[i];
        energy[i] = sum;
    }
    const top = energy[0];
    var t5: ?usize = null;
    var t35: ?usize = null;
    for (energy, 0..) |e, n| {
        const db = 10 * std.math.log10(e / top);
        if (t5 == null and db <= -5) t5 = n;
        if (t35 == null and db <= -35) {
            t35 = n;
            break;
        }
    }
    return 2 * @as(f64, @floatFromInt(t35.? - t5.?)) / test_rate;
}

test "the reverb falls 60 dB in its decay, within 10%, from 0.3 to 5 seconds" {
    for ([_]f32{ 0.3, 0.6, 1.5, 3, 5 }) |decay| {
        const got = try measuredDecay(decay, 0);
        if (@abs(got - decay) > 0.1 * decay) {
            std.debug.print("decay {d}: measured {d:.3} s\n", .{ decay, got });
            return error.TestExpectedApproxEqRel;
        }
    }
    // Damping makes high frequencies die sooner, so the broadband tail is shorter.
    try testing.expect(try measuredDecay(1.5, 1) < try measuredDecay(1.5, 0));
}

test "the reverb's two outputs differ, and every sample stays finite" {
    var unit = try Unit.init(testing.allocator, .{ .reverb = .{ .wet = 1, .dry = 0 } }, test_rate, 2);
    defer unit.deinit(testing.allocator);
    var buffer: [2 * 4800]f32 = @splat(0);
    buffer[0] = 1;
    buffer[1] = 1;
    unit.process(&buffer, 2);
    var differ = false;
    for (0..4800) |f| {
        try testing.expect(std.math.isFinite(buffer[f * 2]));
        differ = differ or buffer[f * 2] != buffer[f * 2 + 1];
    }
    try testing.expect(differ);
}

test "a delay time, a reverb size or predelay, or a limiter lookahead is a change of shape" {
    try testing.expect(fixedEql(.{ .delay = .{ .time = 0.2 } }, .{ .delay = .{ .time = 0.2, .wet = 0.9 } }));
    try testing.expect(!fixedEql(.{ .delay = .{ .time = 0.2 } }, .{ .delay = .{ .time = 0.3 } }));
    try testing.expect(fixedEql(.{ .reverb = .{} }, .{ .reverb = .{ .decay = 4, .wet = 0.1 } }));
    try testing.expect(!fixedEql(.{ .reverb = .{} }, .{ .reverb = .{ .size = 1.5 } }));
    try testing.expect(!fixedEql(.{ .reverb = .{} }, .{ .reverb = .{ .predelay = 0.05 } }));
    try testing.expect(!fixedEql(.{ .limiter = .{} }, .{ .limiter = .{ .lookahead = 0.005 } }));
    try testing.expect(!fixedEql(.{ .limiter = .{} }, .{ .compressor = .{} }));
    try testing.expect(fixedEql(.{ .filter = .{ .shape = .lowpass, .frequency = 900 } }, .{ .filter = .{ .shape = .highpass, .frequency = 90 } }));
}
