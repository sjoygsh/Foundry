//! Sine and cosine written out, so a result depends on the binary's arithmetic and not on
//! which math library it linked.
//!
//! `@sin` and `@cos` lower to whatever `sinf` a binary resolves: Zig's compiler runtime in one
//! build, the platform's libm in another (`public3d.md` §10's Step 5 math-pin correction, where
//! the walker's pin had to accept two variants). Anything pinned by hash uses this instead: it
//! uses only `+`, `−`, `×` and `floor` in `f64`, each exactly rounded by IEEE 754, so the same
//! inputs give the same bits in every optimization mode. It is the same reasoning as `core.rng`
//! owning its algorithm. Particles (M29) and the Vorbis decoder's window and twiddles (M30,
//! `music.md` §3.3) use it; M29 wrote it in `particles`, and M30 moved it here unchanged.

const std = @import("std");

/// `sin(2π·turns)` and `cos(2π·turns)` for any finite `turns`.
pub fn sinCosTurns(turns: f64) [2]f64 {
    // The nearest quarter turn, and the remainder within an eighth of a turn of it.
    const t = turns - @floor(turns);
    const quarter = @floor(t * 4 + 0.5);
    const r = (t - quarter / 4) * (2 * std.math.pi);
    const s = sinSmall(r);
    const c = cosSmall(r);
    return switch (@as(u2, @intFromFloat(@mod(quarter, 4)))) {
        0 => .{ s, c },
        1 => .{ c, -s },
        2 => .{ -s, -c },
        3 => .{ -c, s },
    };
}

/// Taylor series in Horner form for `|r| ≤ π/4`: the first omitted term is below 1e-17.
fn sinSmall(r: f64) f64 {
    const x = r * r;
    var p: f64 = 1 - x / 342;
    p = 1 - x / 272 * p;
    p = 1 - x / 210 * p;
    p = 1 - x / 156 * p;
    p = 1 - x / 110 * p;
    p = 1 - x / 72 * p;
    p = 1 - x / 42 * p;
    p = 1 - x / 20 * p;
    p = 1 - x / 6 * p;
    return r * p;
}

fn cosSmall(r: f64) f64 {
    const x = r * r;
    var p: f64 = 1 - x / 306;
    p = 1 - x / 240 * p;
    p = 1 - x / 182 * p;
    p = 1 - x / 132 * p;
    p = 1 - x / 90 * p;
    p = 1 - x / 56 * p;
    p = 1 - x / 30 * p;
    p = 1 - x / 12 * p;
    p = 1 - x / 2 * p;
    return p;
}

test "the written-out sine and cosine agree with std to f64 rounding" {
    var i: i32 = -2000;
    while (i <= 2000) : (i += 1) {
        const turns = @as(f64, @floatFromInt(i)) / 997.0;
        const sc = sinCosTurns(turns);
        const angle = turns * 2 * std.math.pi;
        try std.testing.expectApproxEqAbs(@sin(angle), sc[0], 1e-14);
        try std.testing.expectApproxEqAbs(@cos(angle), sc[1], 1e-14);
    }
    try std.testing.expectEqual([2]f64{ 0, 1 }, sinCosTurns(0));
    try std.testing.expectEqual([2]f64{ 1, 0 }, sinCosTurns(0.25));
    try std.testing.expectEqual([2]f64{ 0, 1 }, sinCosTurns(3));
}
