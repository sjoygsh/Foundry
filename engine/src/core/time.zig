//! Time types and the fixed-timestep model.
//!
//! The layering splits time deliberately (ADR-0007): `core` owns the types and the
//! arithmetic, `platform` owns reading the clock. That split is what makes I9's "no
//! wall-clock reads inside simulation" structural rather than a matter of discipline —
//! an `Instant` can only be produced by `platform`, and simulation code cannot reach it.
//!
//! See `docs/design/core-memory-and-handles.md` §7.

const std = @import("std");

pub const ns_per_us: i64 = 1_000;
pub const ns_per_ms: i64 = 1_000_000;
pub const ns_per_s: i64 = 1_000_000_000;

/// A span of time in nanoseconds. Signed, because durations get subtracted and a
/// negative result should be representable rather than catastrophic.
pub const Duration = struct {
    ns: i64 = 0,

    pub const zero: Duration = .{ .ns = 0 };

    pub fn fromNanos(n: i64) Duration {
        return .{ .ns = n };
    }
    pub fn fromMillis(ms: i64) Duration {
        return .{ .ns = ms * ns_per_ms };
    }
    pub fn fromSeconds(s: i64) Duration {
        return .{ .ns = s * ns_per_s };
    }
    pub fn toMillis(d: Duration) i64 {
        return @divTrunc(d.ns, ns_per_ms);
    }
    /// Lossy. For display and for the render step's interpolation, never for
    /// accumulating simulation time.
    pub fn toSecondsF32(d: Duration) f32 {
        return @as(f32, @floatFromInt(d.ns)) / @as(f32, @floatFromInt(ns_per_s));
    }
    pub fn add(a: Duration, b: Duration) Duration {
        return .{ .ns = a.ns + b.ns };
    }
    pub fn sub(a: Duration, b: Duration) Duration {
        return .{ .ns = a.ns - b.ns };
    }
    pub fn order(a: Duration, b: Duration) std.math.Order {
        return std.math.order(a.ns, b.ns);
    }
};

/// A point on the monotonic clock. Produced only by `platform`.
///
/// Not a wall-clock date, and not comparable across runs — the origin is arbitrary.
/// Anything that needs a calendar date wants `platform`'s separate wall-clock call,
/// which is a different type for exactly this reason.
pub const Instant = struct {
    ns: i64,

    pub fn since(later: Instant, earlier: Instant) Duration {
        return .{ .ns = later.ns - earlier.ns };
    }
};

/// The simulation's step length, as an exact rational number of seconds.
///
/// A rational, not a float: `1/60` has no exact binary representation, and an
/// accumulator that adds `0.016666...` sixty times does not arrive at one second.
/// Storing the ratio means tick `N` maps to an exact instant no matter how large `N`
/// gets, which is what I9 requires of simulation time.
pub const Timestep = struct {
    /// Seconds per tick = `numerator / denominator`.
    numerator: u32,
    denominator: u32,

    pub fn fromHz(hz: u32) Timestep {
        std.debug.assert(hz != 0);
        return .{ .numerator = 1, .denominator = hz };
    }

    /// Exact elapsed simulation time at a given tick. No drift, at any tick count.
    pub fn elapsedAt(self: Timestep, tick: u64) Duration {
        const n: i128 = @intCast(tick);
        const total = @divTrunc(n * self.numerator * ns_per_s, self.denominator);
        return .{ .ns = @intCast(total) };
    }
};

/// Consumes real elapsed time and emits fixed simulation steps.
///
/// The accumulator is kept in units of `nanoseconds * denominator`, so one step costs
/// exactly `numerator * 1e9` and the subtraction is exact integer arithmetic. There is
/// nowhere for rounding error to enter.
pub const FixedStepper = struct {
    step: Timestep,
    /// Upper bound on steps per frame. Without it, a frame that ran long produces more
    /// steps, which takes longer, which produces more steps — the spiral of death.
    /// Excess real time is discarded: the simulation runs slow rather than losing
    /// determinism, which is the right trade for I9.
    max_steps_per_frame: u32 = 8,

    accumulated: i64 = 0,
    tick: u64 = 0,

    pub fn init(step: Timestep) FixedStepper {
        return .{ .step = step };
    }

    fn stepCost(self: FixedStepper) i64 {
        return @as(i64, self.step.numerator) * ns_per_s;
    }

    /// Feeds real elapsed time in. Call once per frame, before draining steps.
    pub fn advance(self: *FixedStepper, real_time: Duration) void {
        // A monotonic clock should never go backwards; if one does, ignore it rather
        // than rewinding the accumulator.
        if (real_time.ns > 0) {
            self.accumulated += real_time.ns * @as(i64, self.step.denominator);
        }
        const ceiling = self.stepCost() * @as(i64, self.max_steps_per_frame);
        if (self.accumulated > ceiling) self.accumulated = ceiling;
    }

    /// Consumes one step if one is due. Drive with `while (stepper.next()) { ... }`.
    pub fn next(self: *FixedStepper) bool {
        const cost = self.stepCost();
        if (self.accumulated < cost) return false;
        self.accumulated -= cost;
        self.tick += 1;
        return true;
    }

    /// How far the next step has progressed, in `[0, 1)`.
    ///
    /// For interpolating the *render* between two simulation states. Presentation only:
    /// feeding this back into simulation state would make the simulation depend on
    /// frame timing, which is exactly what the fixed step exists to prevent.
    pub fn alpha(self: FixedStepper) f32 {
        const cost = self.stepCost();
        if (cost == 0) return 0;
        const a = @as(f32, @floatFromInt(self.accumulated)) / @as(f32, @floatFromInt(cost));
        return @min(a, 1.0);
    }

    /// Exact simulation time at the current tick.
    pub fn elapsed(self: FixedStepper) Duration {
        return self.step.elapsedAt(self.tick);
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "duration conversions" {
    try testing.expectEqual(@as(i64, 1_000_000), Duration.fromMillis(1).ns);
    try testing.expectEqual(@as(i64, 1_000), Duration.fromMillis(1000).toMillis());
    try testing.expectEqual(@as(i64, -5), Duration.fromNanos(5).sub(Duration.fromNanos(10)).ns);
}

test "instant differences are durations" {
    const a = Instant{ .ns = 1000 };
    const b = Instant{ .ns = 2500 };
    try testing.expectEqual(@as(i64, 1500), b.since(a).ns);
}

test "tick time is exact at 60Hz" {
    const step = Timestep.fromHz(60);
    try testing.expectEqual(@as(i64, 0), step.elapsedAt(0).ns);
    try testing.expectEqual(ns_per_s, step.elapsedAt(60).ns);
    try testing.expectEqual(ns_per_s * 60, step.elapsedAt(3600).ns);
    // One hour of simulation, to the nanosecond.
    try testing.expectEqual(ns_per_s * 3600, step.elapsedAt(216_000).ns);
}

test "tick time does not drift where a float accumulator would" {
    const step = Timestep.fromHz(60);
    const ticks: u64 = 216_000; // one hour at 60Hz

    // The exact answer.
    try testing.expectEqual(ns_per_s * 3600, step.elapsedAt(ticks).ns);

    // What a float accumulator produces, for contrast. This is the failure mode the
    // rational timestep exists to prevent, and the reason this test is here: if
    // someone "simplifies" Timestep into an f32, this assertion starts failing.
    var drifting: f32 = 0;
    for (0..ticks) |_| drifting += 1.0 / 60.0;
    const drifted_ns = @as(f64, drifting) * @as(f64, @floatFromInt(ns_per_s));
    const exact_ns = @as(f64, @floatFromInt(ns_per_s * 3600));
    try testing.expect(@abs(drifted_ns - exact_ns) > 1_000_000.0); // off by over a millisecond
}

test "one step needs a full step of real time, to the nanosecond" {
    // A 60Hz step is 16666666.67ns, which no integer nanosecond duration expresses
    // exactly. The accumulator is exact, so it declines to step on 16666666ns and
    // steps on 16666667ns. This is the boundary a float accumulator would smear.
    {
        var s = FixedStepper.init(Timestep.fromHz(60));
        s.advance(Duration.fromNanos(16_666_666));
        try testing.expect(!s.next());
        try testing.expectEqual(@as(u64, 0), s.tick);
    }
    {
        var s = FixedStepper.init(Timestep.fromHz(60));
        s.advance(Duration.fromNanos(16_666_667));
        try testing.expect(s.next());
        try testing.expect(!s.next());
        try testing.expectEqual(@as(u64, 1), s.tick);
    }
}

test "a whole second of real time yields exactly the tick rate" {
    var s = FixedStepper.init(Timestep.fromHz(60));
    s.max_steps_per_frame = 1000;

    s.advance(Duration.fromSeconds(1));
    var steps: u32 = 0;
    while (s.next()) steps += 1;

    try testing.expectEqual(@as(u32, 60), steps);
    try testing.expectEqual(@as(i64, 0), s.accumulated); // nothing left over
}

test "stepper emits the right number of steps over a long run" {
    var s = FixedStepper.init(Timestep.fromHz(60));
    s.max_steps_per_frame = 1000;

    // Ten seconds delivered in uneven 7ms slices.
    var delivered: i64 = 0;
    const total = ns_per_s * 10;
    while (delivered < total) {
        const slice = @min(@as(i64, 7 * ns_per_ms), total - delivered);
        s.advance(Duration.fromNanos(slice));
        delivered += slice;
        while (s.next()) {}
    }

    // 600 ticks in ten seconds at 60Hz, with no accumulated rounding loss.
    try testing.expectEqual(@as(u64, 600), s.tick);
    try testing.expectEqual(ns_per_s * 10, s.elapsed().ns);
}

test "stepper clamps rather than spiralling" {
    var s = FixedStepper.init(Timestep.fromHz(60));
    s.max_steps_per_frame = 4;

    // A ten second hitch — the debugger was paused, or the machine slept.
    s.advance(Duration.fromSeconds(10));

    var steps: u32 = 0;
    while (s.next()) steps += 1;
    try testing.expectEqual(@as(u32, 4), steps);
}

test "stepper ignores a clock that goes backwards" {
    var s = FixedStepper.init(Timestep.fromHz(60));
    s.advance(Duration.fromSeconds(-5));
    try testing.expect(!s.next());
    try testing.expectEqual(@as(i64, 0), s.accumulated);
}

test "alpha stays in [0,1]" {
    var s = FixedStepper.init(Timestep.fromHz(60));
    try testing.expectEqual(@as(f32, 0), s.alpha());

    s.advance(Duration.fromNanos(@divTrunc(ns_per_s, 120))); // half a step
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.alpha(), 1e-3);

    s.advance(Duration.fromSeconds(1));
    try testing.expect(s.alpha() <= 1.0);
}
