//! Where a spatial voice is heard: distance, direction and occlusion turned into gains
//! (`docs/design/mixing.md` §5, ADR-0068).
//!
//! **Game-thread arithmetic, run once per `Mixer.update`.** Positions change at the frame rate,
//! so placing a voice per sample would buy nothing. The callback only interpolates what this
//! returns across its next buffer. Everything here is pure and checked without a device.
//!
//! **Presentation, never simulation** (I9): a game sets the listener and positions after its
//! tick, from the state the tick left, and nothing a tick computes reads them back.
//!
//! The pan law is `voice.panGains`'s constant-power one, computed with `core.math.trig` so a
//! spatial pin does not depend on which `sinf` a binary linked. The one-pole coefficient uses
//! `core.math.exp` for the same reason.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");

const Vec3 = core.math.Vec3;
const Attenuation = asset.mix.Attenuation;

/// Who hears, in ADR-0048's conventions: right-handed, +Y up, −Z forward, metres.
pub const Listener = struct {
    position: Vec3 = .zero,
    forward: Vec3 = .forward,
    up: Vec3 = .up,
};

/// A listener reduced to what placing needs: where it is and which way is right.
pub const Basis = struct {
    position: Vec3 = .zero,
    right: Vec3 = .right,
};

/// The listener's basis, or null for one that cannot be heard from: a non-finite vector, or a
/// `forward` with no direction or parallel to `up`.
pub fn basis(listener: Listener) ?Basis {
    if (!listener.position.isFinite() or !listener.forward.isFinite() or !listener.up.isFinite()) return null;
    const right = listener.forward.cross(listener.up);
    const length = right.length();
    if (!(length > 1e-6) or !std.math.isFinite(length)) return null;
    return .{ .position = listener.position, .right = right.scale(1 / length) };
}

/// What the callback interpolates to (`voice.Voice`'s spatial fields).
pub const Placed = struct {
    /// The constant-power pan's two gains.
    left: f32 = 1,
    right: f32 = 1,
    /// Distance gain times occlusion's gain: what a mono device hears, and what both pan
    /// gains are multiplied by.
    space: f32 = 1,
    /// The one-pole low-pass's coefficient; exactly 1 is no filter at all.
    lowpass: f32 = 1,

    pub fn eql(a: Placed, b: Placed) bool {
        return a.left == b.left and a.right == b.right and a.space == b.space and a.lowpass == b.lowpass;
    }
};

/// The open, unfiltered cutoff (`mixing.md` §5.4): occlusion moves down from here.
pub const open_cutoff: f32 = 20_000;

/// Distance gain for `d` metres (§5.2).
pub fn distanceGain(attenuation: Attenuation, d: f32) f32 {
    const near = attenuation.min_distance;
    const far = attenuation.max_distance;
    if (d <= near) return 1;
    if (d >= far) return 0;
    return switch (attenuation.model) {
        // 1/d, adjusted to reach zero at the far end rather than never: it stays within
        // near/(far − near) of full scale of 1/d everywhere.
        .inverse => (near / d - near / far) / (1 - near / far),
        .linear => 1 - (d - near) / (far - near),
    };
}

/// The low-pass cutoff for an occlusion amount, on a logarithmic scale from the open cutoff
/// to the attenuation's occluded one (§5.4).
pub fn cutoffFor(attenuation: Attenuation, occlusion: f32) f32 {
    const open = core.math.exp.log2(open_cutoff);
    const shut = core.math.exp.log2(attenuation.occluded_cutoff);
    return core.math.exp.exp2(open + (shut - open) * occlusion);
}

/// The one-pole coefficient `1 − e^(−2π·fc/fs)` for a cutoff at a device rate. A cutoff at or
/// above the open one is exactly 1, so an unoccluded voice is not filtered at all.
pub fn onePole(cutoff: f32, rate: u32) f32 {
    if (cutoff >= open_cutoff) return 1;
    const x = 2 * std.math.pi * cutoff / @as(f32, @floatFromInt(rate));
    // e^(−x) = 2^(−x·log2 e).
    return 1 - core.math.exp.exp2(-x * std.math.log2e);
}

/// Places a source at `position` for the listener `at`, with occlusion 0 (open) to 1 (fully
/// occluded), on a device at `rate` (§5.2–§5.4).
pub fn place(at: Basis, position: Vec3, attenuation: Attenuation, occlusion: f32, rate: u32) Placed {
    const delta = position.sub(at.position);
    const d = delta.length();
    var pan: f32 = 0;
    // On top of the listener there is no direction to pan toward.
    if (d > 1e-6) {
        pan = std.math.clamp(delta.scale(1 / d).dot(at.right), -1, 1);
        // Inside the near distance the pan narrows to the centre, so walking through a source
        // moves it across the middle rather than flipping it from one side to the other.
        if (d < attenuation.min_distance) pan *= d / attenuation.min_distance;
    }
    // `voice.panGains`'s law: θ = (pan + 1)·π/4, left cos θ, right sin θ; in turns, (pan+1)/8.
    const sc = core.math.trig.sinCosTurns((@as(f64, pan) + 1) / 8);
    const amount = std.math.clamp(occlusion, 0, 1);
    const shade = 1 + (attenuation.occluded_gain - 1) * amount;
    return .{
        .left = @floatCast(sc[1]),
        .right = @floatCast(sc[0]),
        .space = distanceGain(attenuation, d) * shade,
        .lowpass = if (amount == 0) 1 else onePole(cutoffFor(attenuation, amount), rate),
    };
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

const centre: Basis = .{};

test "distance: full inside the near distance, silent at the far one, both models between" {
    const inverse: Attenuation = .{ .min_distance = 1, .max_distance = 30 };
    const linear: Attenuation = .{ .model = .linear, .min_distance = 1, .max_distance = 30 };
    for ([_]Attenuation{ inverse, linear }) |a| {
        try testing.expectEqual(@as(f32, 1), distanceGain(a, 0));
        try testing.expectEqual(@as(f32, 1), distanceGain(a, 1));
        try testing.expectEqual(@as(f32, 0), distanceGain(a, 30));
        try testing.expectEqual(@as(f32, 0), distanceGain(a, 1000));
    }
    // Linear: a third of the way is two thirds; half way is a half.
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), distanceGain(linear, 1 + 29.0 / 3.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), distanceGain(linear, 15.5), 1e-6);
    // Inverse: (1/d − 1/30)/(1 − 1/30). It differs from 1/d by (d − 1)/(29·d), so never by
    // more than near/(far − near) of full scale, 1/29 here (Step 4's correction to §5.2).
    try testing.expectApproxEqAbs(@as(f32, (0.5 - 1.0 / 30.0) / (1 - 1.0 / 30.0)), distanceGain(inverse, 2), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, (1.0 / 15.5 - 1.0 / 30.0) / (1 - 1.0 / 30.0)), distanceGain(inverse, 15.5), 1e-6);
    var d: f32 = 1;
    while (d <= 30) : (d += 0.25) {
        const g = distanceGain(inverse, d);
        try testing.expect(@abs(g - 1 / d) <= 1.0 / 29.0 + 1e-6);
    }
    // And it falls the whole way, never rising.
    var last: f32 = 1;
    d = 1;
    while (d <= 31) : (d += 0.1) {
        const g = distanceGain(inverse, d);
        try testing.expect(g <= last);
        last = g;
    }
}

test "direction: right is right, left is left, ahead, behind and overhead are centred" {
    const far: Attenuation = .{ .min_distance = 1, .max_distance = 100 };
    const right = place(centre, .init(5, 0, 0), far, 0, 48_000);
    try testing.expectApproxEqAbs(@as(f32, 0), right.left, 1e-7);
    try testing.expectApproxEqAbs(@as(f32, 1), right.right, 1e-7);
    const left = place(centre, .init(-5, 0, 0), far, 0, 48_000);
    try testing.expectApproxEqAbs(@as(f32, 1), left.left, 1e-7);
    try testing.expectApproxEqAbs(@as(f32, 0), left.right, 1e-7);
    // Ahead (−Z), behind and overhead: the centre, which is stereo's limit (§5.3).
    for ([_]Vec3{ .init(0, 0, -5), .init(0, 0, 5), .init(0, 5, 0) }) |p| {
        const at = place(centre, p, far, 0, 48_000);
        try testing.expectApproxEqAbs(@as(f32, std.math.sqrt1_2), at.left, 1e-7);
        try testing.expectApproxEqAbs(@as(f32, std.math.sqrt1_2), at.right, 1e-7);
    }
    // A listener turned to face +X hears a source at +X ahead, and one at +Z on its right.
    const turned = basis(.{ .forward = .init(1, 0, 0) }).?;
    const ahead = place(turned, .init(5, 0, 0), far, 0, 48_000);
    try testing.expectApproxEqAbs(ahead.left, ahead.right, 1e-7);
    const side = place(turned, .init(0, 0, 5), far, 0, 48_000);
    try testing.expectApproxEqAbs(@as(f32, 1), side.right, 1e-7);
}

test "power stays constant across a sweep, and the near field narrows toward the centre" {
    const a: Attenuation = .{ .min_distance = 2, .max_distance = 100 };
    var i: i32 = 0;
    while (i < 360) : (i += 5) {
        const sc = core.math.trig.sinCosTurns(@as(f64, @floatFromInt(i)) / 360);
        const p = place(centre, .init(@floatCast(sc[0] * 10), 0, @floatCast(sc[1] * 10)), a, 0, 48_000);
        try testing.expectApproxEqAbs(@as(f32, 1), p.left * p.left + p.right * p.right, 1e-6);
    }
    // Hard right at 10 m; at half the near distance, half the pan; on top of the listener, none.
    const edge = place(centre, .init(2, 0, 0), a, 0, 48_000);
    const half = place(centre, .init(1, 0, 0), a, 0, 48_000);
    const on = place(centre, .zero, a, 0, 48_000);
    try testing.expectApproxEqAbs(@as(f32, 1), edge.right, 1e-7);
    const expected = core.math.trig.sinCosTurns(1.5 / 8.0);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(expected[0])), half.right, 1e-7);
    try testing.expectApproxEqAbs(on.left, on.right, 1e-7);
    try testing.expectEqual(@as(f32, 1), on.space);
}

test "occlusion lowers the gain and closes the low-pass, and open is no filter at all" {
    const a: Attenuation = .{ .occluded_gain = 0.25, .occluded_cutoff = 1200 };
    const open = place(centre, .init(0, 0, -0.5), a, 0, 48_000);
    try testing.expectEqual(@as(f32, 1), open.lowpass);
    try testing.expectEqual(@as(f32, 1), open.space);
    const shut = place(centre, .init(0, 0, -0.5), a, 1, 48_000);
    try testing.expectApproxEqAbs(@as(f32, 0.25), shut.space, 1e-7);
    try testing.expectApproxEqAbs(@as(f32, 1 - @exp(-2 * std.math.pi * 1200.0 / 48_000.0)), shut.lowpass, 1e-6);
    // Half occluded: half the gain's way, and the cutoff at the geometric mean.
    const halfway = place(centre, .init(0, 0, -0.5), a, 0.5, 48_000);
    try testing.expectApproxEqAbs(@as(f32, 0.625), halfway.space, 1e-7);
    try testing.expectApproxEqRel(@as(f32, @sqrt(20_000.0 * 1200.0)), cutoffFor(a, 0.5), 1e-5);
    // Out of range is clamped: occlusion is gameplay arithmetic.
    try testing.expect(place(centre, .zero, a, 7, 48_000).eql(shut));
    try testing.expect(place(centre, .zero, a, -3, 48_000).eql(open));
}

test "a listener that cannot be heard from has no basis" {
    try testing.expect(basis(.{}) != null);
    try testing.expect(basis(.{ .forward = .up }) == null);
    try testing.expect(basis(.{ .forward = .zero }) == null);
    try testing.expect(basis(.{ .position = .init(std.math.nan(f32), 0, 0) }) == null);
    try testing.expect(basis(.{ .up = .init(0, std.math.inf(f32), 0) }) == null);
    // A forward that is not unit length still has a unit right.
    const b = basis(.{ .forward = .init(0, 0, -7) }).?;
    try testing.expectApproxEqAbs(@as(f32, 1), b.right.x, 1e-7);
}
