//! `exp2` and `log2` written out, for the reason `trig.zig` writes out sine: a result pinned by
//! hash must depend on the binary's arithmetic, not on which math library it linked.
//!
//! The mixer's records speak decibels, and its compressor and limiter work in them, so turning
//! a level into a gain and back runs on the device thread and inside the mix that M31's pin
//! hashes (`mixing.md` §3, ADR-0067). `@exp2` and `@log2` resolve to whatever the binary
//! links. These use only `+`, `−`, `×`, `/`, `floor` and the bits of an `f64`, each exactly
//! rounded by IEEE 754, so the same inputs give the same bits in every optimization mode.
//!
//! Both work in `f64` and return `f32`, so the series' own error is far below the `f32`
//! rounding of the result.

const std = @import("std");

/// `2^x`. Below 2⁻¹⁴⁹ it is 0, and above 2¹²⁸ it is infinity, as `f32` would round them.
/// A NaN gives a NaN.
pub fn exp2(x: f32) f32 {
    if (std.math.isNan(x)) return x;
    if (x < -150) return 0;
    if (x >= 128) return std.math.inf(f32);
    // x = n + f with |f| ≤ ½, and 2^f = e^(f·ln 2) with |f·ln 2| ≤ 0.347.
    const wide: f64 = x;
    const n = @floor(wide + 0.5);
    const y = (wide - n) * std.math.ln2;
    return @floatCast(expSmall(y) * pow2(@intFromFloat(n)));
}

/// `log2(x)`. Zero is negative infinity, a negative number or a NaN is a NaN, and infinity
/// is infinity, as `std.math.log2` answers.
pub fn log2(x: f32) f32 {
    if (std.math.isNan(x) or x < 0) return std.math.nan(f32);
    if (x == 0) return -std.math.inf(f32);
    if (std.math.isInf(x)) return x;
    // x = m · 2^e with m in [√½, √2), so that s below is at most 0.172.
    const bits: u64 = @bitCast(@as(f64, x));
    var e: i32 = @as(i32, @intCast((bits >> 52) & 0x7ff)) - 1023;
    var m: f64 = @bitCast((bits & 0x000f_ffff_ffff_ffff) | 0x3ff0_0000_0000_0000);
    if (m > std.math.sqrt2) {
        m /= 2;
        e += 1;
    }
    // ln m = 2·atanh(s) with s = (m − 1)/(m + 1): s + s³/3 + s⁵/5 + …, whose first omitted
    // term here is below 1e-16.
    const s = (m - 1) / (m + 1);
    const q = s * s;
    var p: f64 = 1.0 / 17.0;
    p = 1.0 / 15.0 + q * p;
    p = 1.0 / 13.0 + q * p;
    p = 1.0 / 11.0 + q * p;
    p = 1.0 / 9.0 + q * p;
    p = 1.0 / 7.0 + q * p;
    p = 1.0 / 5.0 + q * p;
    p = 1.0 / 3.0 + q * p;
    p = 1.0 + q * p;
    const ln_m = 2 * s * p;
    return @floatCast(@as(f64, @floatFromInt(e)) + ln_m / std.math.ln2);
}

/// `log2(10) / 20`: decibels to the exponent of two.
const db_to_log2: f32 = 0.16609640474436813;
/// `20 / log2(10)`.
const log2_to_db: f32 = 6.020599913279624;

/// Below this gain a level reads as `floor_db`, never as negative infinity. 2⁻³⁰ is about
/// −180.6 dB, far below anything a 24-bit converter can represent.
pub const floor_gain: f32 = 1.0 / 1073741824.0;
pub const floor_db: f32 = -180;

/// The gain `db` decibels describes: 0 dB is 1, −6.02 dB is ½.
pub fn dbToGain(db: f32) f32 {
    return exp2(db * db_to_log2);
}

/// The decibels a gain describes. A gain below `floor_gain` (silence, or a negative input)
/// is `floor_db`, so arithmetic on a level never meets an infinity.
pub fn gainToDb(gain: f32) f32 {
    if (!(gain >= floor_gain)) return floor_db;
    return log2(gain) * log2_to_db;
}

/// `e^y` for `|y| ≤ 0.35`: the Taylor series in Horner form, first omitted term below 2e-16.
fn expSmall(y: f64) f64 {
    var p: f64 = 1 + y / 12;
    p = 1 + y / 11 * p;
    p = 1 + y / 10 * p;
    p = 1 + y / 9 * p;
    p = 1 + y / 8 * p;
    p = 1 + y / 7 * p;
    p = 1 + y / 6 * p;
    p = 1 + y / 5 * p;
    p = 1 + y / 4 * p;
    p = 1 + y / 3 * p;
    p = 1 + y / 2 * p;
    return 1 + y * p;
}

/// `2^n` exactly, for `n` in [−150, 128], built from its bits. An `f64` holds every one of
/// these as a normal number, so no step of it rounds.
fn pow2(n: i32) f64 {
    const biased: u64 = @intCast(n + 1023);
    return @bitCast(biased << 52);
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

/// The design's bound (`mixing.md` §3): relative error at most 2e-7, or absolute where the
/// answer is near zero and a relative error means nothing.
fn expectClose(expected: f64, actual: f32) !void {
    const err = @abs(@as(f64, actual) - expected);
    const scale = @max(1.0, @abs(expected));
    if (err > 2e-7 * scale) {
        std.debug.print("expected {d}, got {d} (error {e})\n", .{ expected, actual, err / scale });
        return error.TestExpectedApproxEqRel;
    }
}

test "exp2 agrees with std across the range the mixer uses, and is exact at integers" {
    // A fine sweep of −40 to 10: every gain a record or a compressor can ask for.
    var i: i32 = -40_000;
    while (i <= 10_000) : (i += 7) {
        const x: f32 = @as(f32, @floatFromInt(i)) / 1000;
        const expected = std.math.exp2(@as(f64, x));
        const err = @abs(@as(f64, exp2(x)) - expected) / expected;
        try testing.expect(err <= 2e-7);
    }
    // Every power of two is the power of two, bit for bit.
    var n: i32 = -149;
    while (n <= 127) : (n += 1) {
        const x: f32 = @floatFromInt(n);
        try testing.expectEqual(std.math.exp2(x), exp2(x));
    }
    try testing.expectEqual(@as(f32, 0), exp2(-151));
    try testing.expect(std.math.isPositiveInf(exp2(128)));
    try testing.expect(std.math.isNan(exp2(std.math.nan(f32))));
}

test "log2 agrees with std from 2^-30 to 2^8, and is exact at powers of two" {
    var i: i32 = 0;
    while (i <= 38_000) : (i += 3) {
        // Spread logarithmically, so the bottom of the range is sampled as densely as the top.
        const x = std.math.exp2(@as(f32, @floatFromInt(i)) / 1000 - 30);
        try expectClose(std.math.log2(@as(f64, x)), log2(x));
    }
    var n: i32 = -149;
    while (n <= 127) : (n += 1) {
        try testing.expectEqual(@as(f32, @floatFromInt(n)), log2(std.math.exp2(@as(f32, @floatFromInt(n)))));
    }
    try testing.expect(std.math.isNegativeInf(log2(0)));
    try testing.expect(std.math.isNan(log2(-1)));
    try testing.expect(std.math.isPositiveInf(log2(std.math.inf(f32))));
}

test "decibels round trip, and silence is a floor rather than an infinity" {
    try testing.expectEqual(@as(f32, 1), dbToGain(0));
    try testing.expectEqual(@as(f32, 0), gainToDb(1));
    try expectClose(0.5, dbToGain(-6.020599913279624));
    try expectClose(std.math.pow(f64, 10, -1.0 / 20.0), dbToGain(-1));
    // The records' defaults, through and back.
    for ([_]f32{ -1, -18, -20, -24, 6, 24, -60, 0.5 }) |db| {
        const back = gainToDb(dbToGain(db));
        try testing.expect(@abs(back - db) <= 1e-5);
    }
    try testing.expectEqual(floor_db, gainToDb(0));
    try testing.expectEqual(floor_db, gainToDb(-0.5));
    try testing.expectEqual(floor_db, gainToDb(std.math.nan(f32)));
    try testing.expect(gainToDb(floor_gain) > floor_db - 1);
}
