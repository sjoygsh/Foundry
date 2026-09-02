//! PCG32, and the rules for using it.
//!
//! Generators are passed in, never global (I9 and project convention). There is no
//! `core.random()`, deliberately: a shared implicit generator couples every system
//! that touches it, so adding one `nextInt` call in AI code would change the weather.
//!
//! The algorithm is specified here rather than delegated to `std.Random`, for the same
//! reason as the content hash: a seed is a reproducibility promise, and `std` is not a
//! stability contract in a pre-1.0 language.
//! See `docs/design/core-memory-and-handles.md` §8.

const std = @import("std");

/// PCG32 — permuted congruential generator, 64-bit state, 32-bit output.
///
///     state' = state * 6364136223846793005 + inc      (mod 2^64)
///     xorshifted = ((state >> 18) ^ state) >> 27      (low 32 bits)
///     rot        = state >> 59
///     output     = rotr32(xorshifted, rot)            (from the OLD state)
pub const Pcg32 = struct {
    state: u64,
    /// Always odd. Two generators differing only in `inc` produce genuinely
    /// independent sequences rather than offsets of one another.
    inc: u64,

    const multiplier: u64 = 6364136223846793005;

    /// `stream` selects an independent sequence. Streams are chosen deliberately and
    /// their identifiers are stable constants: changing one changes every sequence
    /// derived from it, which makes them behave like content IDs.
    pub fn init(seed: u64, stream: u64) Pcg32 {
        var self = Pcg32{ .state = 0, .inc = (stream << 1) | 1 };
        _ = self.next();
        self.state = self.state +% seed;
        _ = self.next();
        return self;
    }

    pub fn next(self: *Pcg32) u32 {
        const old = self.state;
        self.state = old *% multiplier +% self.inc;
        const xorshifted: u32 = @truncate(((old >> 18) ^ old) >> 27);
        const rot: u5 = @truncate(old >> 59);
        return std.math.rotr(u32, xorshifted, rot);
    }

    pub fn nextU64(self: *Pcg32) u64 {
        const hi: u64 = self.next();
        const lo: u64 = self.next();
        return (hi << 32) | lo;
    }

    /// Uniform in `[0, bound)`, without modulo bias. `bound` must be non-zero.
    pub fn below(self: *Pcg32, bound: u32) u32 {
        std.debug.assert(bound != 0);
        // Reject the values that would make `% bound` non-uniform.
        const threshold = (0 -% bound) % bound;
        while (true) {
            const r = self.next();
            if (r >= threshold) return r % bound;
        }
    }

    /// Uniform in `[0, 1)`, using 24 bits — the exactly representable range of f32.
    pub fn float01(self: *Pcg32) f32 {
        return @as(f32, @floatFromInt(self.next() >> 8)) * 0x1.0p-24;
    }

    pub fn boolean(self: *Pcg32) bool {
        return (self.next() >> 31) != 0;
    }

    /// Derives an independent child generator. Use this to give a subsystem its own
    /// stream rather than sharing one, so its draws cannot perturb anyone else's.
    pub fn split(self: *Pcg32, stream: u64) Pcg32 {
        return Pcg32.init(self.nextU64(), stream);
    }
};

const testing = std.testing;

test "pcg32 reference vector" {
    // PCG's own published output for seed 42, stream 54. If this fails, the generator
    // changed and every recorded seed in the project means something different.
    var r = Pcg32.init(42, 54);
    const expected = [_]u32{ 0xa15c02b7, 0x7b47f409, 0xba1d3330, 0x83d2f293, 0xbfa4784b, 0xcbed606e };
    for (expected) |want| try testing.expectEqual(want, r.next());
}

test "the same seed reproduces exactly" {
    var a = Pcg32.init(12345, 1);
    var b = Pcg32.init(12345, 1);
    for (0..256) |_| try testing.expectEqual(a.next(), b.next());
}

test "different streams from one seed diverge" {
    var a = Pcg32.init(999, 1);
    var b = Pcg32.init(999, 2);

    var identical: usize = 0;
    for (0..64) |_| {
        if (a.next() == b.next()) identical += 1;
    }
    try testing.expect(identical <= 1);
}

test "split produces an independent stream" {
    var parent = Pcg32.init(7, 0);
    var child_a = parent.split(1);
    var child_b = parent.split(2);

    var identical: usize = 0;
    for (0..64) |_| {
        if (child_a.next() == child_b.next()) identical += 1;
    }
    try testing.expect(identical <= 1);
}

test "below is in range and covers its range" {
    var r = Pcg32.init(1, 1);
    var seen = [_]bool{false} ** 6;
    for (0..4096) |_| {
        const v = r.below(6);
        try testing.expect(v < 6);
        seen[v] = true;
    }
    for (seen) |s| try testing.expect(s);
}

test "below(1) is always 0" {
    var r = Pcg32.init(3, 3);
    for (0..64) |_| try testing.expectEqual(@as(u32, 0), r.below(1));
}

test "float01 stays in [0,1)" {
    var r = Pcg32.init(2, 2);
    for (0..4096) |_| {
        const f = r.float01();
        try testing.expect(f >= 0.0);
        try testing.expect(f < 1.0);
    }
}
