//! An emitter's description: what it spawns, how each particle moves, and how it looks over its
//! life (`docs/design/particles.md` §3.1).
//!
//! A description is a plain value. Its slices — bursts and curves — are borrowed from the
//! caller, who keeps them alive while a system is stepped with it. It comes from content, and
//! later perhaps from a mod, so `validate` refuses by name. Stepping a description that was
//! never validated is a programmer error.
//!
//! **Every field name is `foundry:particle_emitter`'s** (§4), so this file and the record
//! cannot drift apart without a rename being visible in both.

const std = @import("std");

/// One `u16` index range of quads: 16,384 quads are 65,536 vertices (§3.3).
pub const max_capacity: u32 = 16_384;
pub const max_curve_keys: usize = 8;
pub const max_bursts: usize = 8;
pub const max_sheet_side: u32 = 64;
pub const max_sheet_frames: u32 = 4096;

/// Bounds on magnitudes, so a hostile record cannot ask for an overflow. Each is far past
/// anything an effect needs and well inside `f32`.
pub const max_rate: f32 = 100_000; // particles per second
pub const max_seconds: f32 = 3600;
/// A loop shorter than a millisecond would let one tick walk thousands of loops' bursts.
pub const min_duration: f32 = 0.001;
pub const max_distance: f32 = 10_000; // metres: sizes, radii, extents
pub const max_speed: f32 = 10_000; // m/s
pub const max_acceleration: f32 = 10_000; // m/s²
pub const max_drag: f32 = 1000; // per second
pub const max_angle: f32 = 10_000; // radians: initial rotation
pub const max_spin: f32 = 1000; // radians per second
pub const max_factor: f32 = 10_000; // curve values and colour channels
pub const max_stretch: f32 = 1000; // metres per m/s
pub const max_fps: f32 = 1000;

pub const Error = error{
    InvalidCapacity,
    InvalidRate,
    InvalidBurst,
    TooManyBursts,
    InvalidDuration,
    InvalidLifetime,
    InvalidShape,
    InvalidSpeed,
    InvalidAcceleration,
    InvalidDrag,
    InvalidSize,
    InvalidRotation,
    InvalidSpin,
    InvalidCurve,
    TooManyKeys,
    InvalidColor,
    InvalidAdditive,
    InvalidStretch,
    InvalidSheet,
};

/// A value drawn uniformly from `[min, max]` per particle.
pub const Range = struct {
    min: f32,
    max: f32,

    pub fn constant(value: f32) Range {
        return .{ .min = value, .max = value };
    }

    pub fn at(self: Range, u: f32) f32 {
        return self.min + (self.max - self.min) * u;
    }
};

pub const Burst = struct {
    /// Seconds into each loop.
    time: f32,
    count: u32,
};

/// A key of a scalar curve over normalized age.
pub const Key = struct { t: f32, value: f32 };
/// A key of the colour curve: linear RGB and opacity.
pub const ColorKey = struct { t: f32, color: [4]f32 };

pub const ShapeKind = enum { point, sphere, box, cone };

/// Where a particle starts and which way it leaves, in the emitter's local frame. The axis of
/// a cone and the direction of a box are local +Y (§3.1).
pub const Shape = struct {
    kind: ShapeKind = .point,
    /// A sphere's radius, or a cone's base radius.
    radius: f32 = 0,
    /// A cone's half-angle about +Y, in radians, from 0 to π.
    angle: f32 = 0,
    /// A box's half-extent.
    extent: [3]f32 = .{ 0, 0, 0 },
    /// A sphere spawns on its surface rather than through its volume.
    surface: bool = false,
};

pub const Facing = enum { camera, velocity, up };
pub const Space = enum { world, local };

/// A flipbook laid out row-major from the top left. `fps` 0 plays it once over each life.
pub const Sheet = struct {
    columns: u32 = 1,
    rows: u32 = 1,
    frames: u32 = 1,
    fps: f32 = 0,
};

pub const Emitter = struct {
    capacity: u32 = 64,
    /// Particles per second, spawned continuously while playing.
    rate: f32 = 0,
    bursts: []const Burst = &.{},
    /// Seconds in one loop. Bursts repeat each loop; without `loop`, nothing spawns after it.
    duration: f32 = 1,
    loop: bool = true,
    lifetime: Range = .constant(1),
    shape: Shape = .{},
    speed: Range = .constant(1),
    /// m/s², in `space`'s axes.
    acceleration: [3]f32 = .{ 0, 0, 0 },
    drag: f32 = 0,
    /// Metres: the quad's side.
    size: Range = .constant(0.1),
    /// A factor on `size` over normalized age. Empty is constant 1.
    size_over_life: []const Key = &.{},
    rotation: Range = .constant(0),
    spin: Range = .constant(0),
    /// Empty is constant white and opaque.
    color_over_life: []const ColorKey = &.{},
    /// 0 covers what is behind, 1 adds to it (§5).
    additive: f32 = 0,
    facing: Facing = .camera,
    stretch: f32 = 0,
    space: Space = .world,
    sheet: Sheet = .{},
    seed: u64 = 0,

    pub fn validate(self: Emitter) Error!void {
        if (self.capacity == 0 or self.capacity > max_capacity) return error.InvalidCapacity;
        if (!within(self.rate, 0, max_rate)) return error.InvalidRate;
        if (!within(self.duration, min_duration, max_seconds)) return error.InvalidDuration;
        if (self.bursts.len > max_bursts) return error.TooManyBursts;
        for (self.bursts) |burst| {
            if (!within(burst.time, 0, max_seconds) or burst.time >= self.duration) return error.InvalidBurst;
            if (burst.count == 0 or burst.count > max_capacity) return error.InvalidBurst;
        }
        if (!range(self.lifetime, 0, max_seconds) or self.lifetime.min == 0) return error.InvalidLifetime;
        try validateShape(self.shape);
        if (!range(self.speed, 0, max_speed)) return error.InvalidSpeed;
        for (self.acceleration) |a| if (!within(a, -max_acceleration, max_acceleration)) return error.InvalidAcceleration;
        if (!within(self.drag, 0, max_drag)) return error.InvalidDrag;
        if (!range(self.size, 0, max_distance)) return error.InvalidSize;
        try validateKeys(Key, self.size_over_life);
        for (self.size_over_life) |key| if (!within(key.value, 0, max_factor)) return error.InvalidCurve;
        if (!range(self.rotation, -max_angle, max_angle)) return error.InvalidRotation;
        if (!range(self.spin, -max_spin, max_spin)) return error.InvalidSpin;
        try validateKeys(ColorKey, self.color_over_life);
        for (self.color_over_life) |key| {
            for (key.color[0..3]) |c| if (!within(c, 0, max_factor)) return error.InvalidColor;
            if (!within(key.color[3], 0, 1)) return error.InvalidColor;
        }
        if (!within(self.additive, 0, 1)) return error.InvalidAdditive;
        if (!within(self.stretch, 0, max_stretch)) return error.InvalidStretch;
        const sheet = self.sheet;
        if (sheet.columns == 0 or sheet.columns > max_sheet_side or sheet.rows == 0 or sheet.rows > max_sheet_side) return error.InvalidSheet;
        if (sheet.frames == 0 or sheet.frames > sheet.columns * sheet.rows or sheet.frames > max_sheet_frames) return error.InvalidSheet;
        if (!within(sheet.fps, 0, max_fps)) return error.InvalidSheet;
    }

    /// `size_over_life` at normalized age `t`.
    pub fn sizeAt(self: *const Emitter, t: f32) f32 {
        const keys = self.size_over_life;
        if (keys.len == 0) return 1;
        const i = segment(Key, keys, t);
        if (i + 1 == keys.len) return keys[i].value;
        const f = fraction(keys[i].t, keys[i + 1].t, t);
        return keys[i].value + (keys[i + 1].value - keys[i].value) * f;
    }

    /// `color_over_life` at normalized age `t`.
    pub fn colorAt(self: *const Emitter, t: f32) [4]f32 {
        const keys = self.color_over_life;
        if (keys.len == 0) return .{ 1, 1, 1, 1 };
        const i = segment(ColorKey, keys, t);
        if (i + 1 == keys.len) return keys[i].color;
        const f = fraction(keys[i].t, keys[i + 1].t, t);
        var out: [4]f32 = undefined;
        for (&out, keys[i].color, keys[i + 1].color) |*o, a, b| o.* = a + (b - a) * f;
        return out;
    }

    /// The largest value `size_over_life` reaches, for bounds.
    pub fn maxSizeFactor(self: *const Emitter) f32 {
        if (self.size_over_life.len == 0) return 1;
        var most: f32 = 0;
        for (self.size_over_life) |key| most = @max(most, key.value);
        return most;
    }
};

fn validateShape(shape: Shape) Error!void {
    if (!within(shape.radius, 0, max_distance)) return error.InvalidShape;
    if (!within(shape.angle, 0, std.math.pi)) return error.InvalidShape;
    for (shape.extent) |e| if (!within(e, 0, max_distance)) return error.InvalidShape;
}

/// Empty, or at least two keys strictly increasing in `t` from exactly 0 to exactly 1.
fn validateKeys(comptime K: type, keys: []const K) Error!void {
    if (keys.len == 0) return;
    if (keys.len > max_curve_keys) return error.TooManyKeys;
    if (keys.len < 2 or keys[0].t != 0 or keys[keys.len - 1].t != 1) return error.InvalidCurve;
    for (keys[1..], keys[0 .. keys.len - 1]) |key, previous| {
        if (!std.math.isFinite(key.t) or key.t <= previous.t) return error.InvalidCurve;
    }
}

/// The last key whose `t` is at or below `t`; keys are validated, so the first is at 0.
fn segment(comptime K: type, keys: []const K, t: f32) usize {
    var i: usize = 0;
    while (i + 1 < keys.len and keys[i + 1].t <= t) i += 1;
    return i;
}

fn fraction(a: f32, b: f32, t: f32) f32 {
    return std.math.clamp((t - a) / (b - a), 0, 1);
}

/// Finite and in `[lo, hi]`; NaN fails both comparisons and so is refused.
fn within(value: f32, lo: f32, hi: f32) bool {
    return std.math.isFinite(value) and value >= lo and value <= hi;
}

fn range(r: Range, lo: f32, hi: f32) bool {
    return within(r.min, lo, hi) and within(r.max, lo, hi) and r.min <= r.max;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "the default emitter is valid, and every refusal names its field" {
    try (Emitter{}).validate();

    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const cases = [_]struct { emitter: Emitter, err: Error }{
        .{ .emitter = .{ .capacity = 0 }, .err = error.InvalidCapacity },
        .{ .emitter = .{ .capacity = max_capacity + 1 }, .err = error.InvalidCapacity },
        .{ .emitter = .{ .rate = -1 }, .err = error.InvalidRate },
        .{ .emitter = .{ .rate = nan }, .err = error.InvalidRate },
        .{ .emitter = .{ .rate = max_rate * 2 }, .err = error.InvalidRate },
        .{ .emitter = .{ .duration = 0 }, .err = error.InvalidDuration },
        .{ .emitter = .{ .duration = min_duration / 2 }, .err = error.InvalidDuration },
        .{ .emitter = .{ .duration = inf }, .err = error.InvalidDuration },
        .{ .emitter = .{ .bursts = &([_]Burst{.{ .time = 0, .count = 1 }} ** (max_bursts + 1)) }, .err = error.TooManyBursts },
        .{ .emitter = .{ .bursts = &.{.{ .time = 1, .count = 1 }} }, .err = error.InvalidBurst },
        .{ .emitter = .{ .bursts = &.{.{ .time = -0.5, .count = 1 }} }, .err = error.InvalidBurst },
        .{ .emitter = .{ .bursts = &.{.{ .time = 0, .count = 0 }} }, .err = error.InvalidBurst },
        .{ .emitter = .{ .bursts = &.{.{ .time = 0, .count = max_capacity + 1 }} }, .err = error.InvalidBurst },
        .{ .emitter = .{ .lifetime = .constant(0) }, .err = error.InvalidLifetime },
        .{ .emitter = .{ .lifetime = .{ .min = 2, .max = 1 } }, .err = error.InvalidLifetime },
        .{ .emitter = .{ .lifetime = .{ .min = 1, .max = nan } }, .err = error.InvalidLifetime },
        .{ .emitter = .{ .shape = .{ .radius = -1 } }, .err = error.InvalidShape },
        .{ .emitter = .{ .shape = .{ .angle = 4 } }, .err = error.InvalidShape },
        .{ .emitter = .{ .shape = .{ .extent = .{ 0, nan, 0 } } }, .err = error.InvalidShape },
        .{ .emitter = .{ .speed = .constant(-1) }, .err = error.InvalidSpeed },
        .{ .emitter = .{ .acceleration = .{ 0, -inf, 0 } }, .err = error.InvalidAcceleration },
        .{ .emitter = .{ .drag = -0.1 }, .err = error.InvalidDrag },
        .{ .emitter = .{ .size = .constant(-0.1) }, .err = error.InvalidSize },
        .{ .emitter = .{ .size_over_life = &.{.{ .t = 0, .value = 1 }} }, .err = error.InvalidCurve },
        .{ .emitter = .{ .size_over_life = &.{ .{ .t = 0.1, .value = 1 }, .{ .t = 1, .value = 1 } } }, .err = error.InvalidCurve },
        .{ .emitter = .{ .size_over_life = &.{ .{ .t = 0, .value = 1 }, .{ .t = 0.9, .value = 1 } } }, .err = error.InvalidCurve },
        .{ .emitter = .{ .size_over_life = &.{ .{ .t = 0, .value = 1 }, .{ .t = 0.5, .value = 1 }, .{ .t = 0.5, .value = 1 }, .{ .t = 1, .value = 1 } } }, .err = error.InvalidCurve },
        .{ .emitter = .{ .size_over_life = &.{ .{ .t = 0, .value = -1 }, .{ .t = 1, .value = 1 } } }, .err = error.InvalidCurve },
        .{ .emitter = .{ .size_over_life = &([_]Key{.{ .t = 0, .value = 1 }} ** (max_curve_keys + 1)) }, .err = error.TooManyKeys },
        .{ .emitter = .{ .rotation = .{ .min = 1, .max = 0 } }, .err = error.InvalidRotation },
        .{ .emitter = .{ .spin = .constant(max_spin * 2) }, .err = error.InvalidSpin },
        .{ .emitter = .{ .color_over_life = &.{ .{ .t = 0, .color = .{ 1, 1, 1, 1.5 } }, .{ .t = 1, .color = .{ 1, 1, 1, 1 } } } }, .err = error.InvalidColor },
        .{ .emitter = .{ .color_over_life = &.{ .{ .t = 0, .color = .{ nan, 1, 1, 1 } }, .{ .t = 1, .color = .{ 1, 1, 1, 1 } } } }, .err = error.InvalidColor },
        .{ .emitter = .{ .color_over_life = &.{ .{ .t = 1, .color = .{ 1, 1, 1, 1 } }, .{ .t = 0, .color = .{ 1, 1, 1, 1 } } } }, .err = error.InvalidCurve },
        .{ .emitter = .{ .additive = 1.5 }, .err = error.InvalidAdditive },
        .{ .emitter = .{ .stretch = -1 }, .err = error.InvalidStretch },
        .{ .emitter = .{ .sheet = .{ .columns = 0 } }, .err = error.InvalidSheet },
        .{ .emitter = .{ .sheet = .{ .rows = max_sheet_side + 1 } }, .err = error.InvalidSheet },
        .{ .emitter = .{ .sheet = .{ .columns = 2, .rows = 2, .frames = 5 } }, .err = error.InvalidSheet },
        .{ .emitter = .{ .sheet = .{ .frames = 0 } }, .err = error.InvalidSheet },
        .{ .emitter = .{ .sheet = .{ .fps = -1 } }, .err = error.InvalidSheet },
    };
    for (cases) |case| try testing.expectError(case.err, case.emitter.validate());
}

test "curves are linear between keys and hold their ends" {
    const emitter: Emitter = .{
        .size_over_life = &.{ .{ .t = 0, .value = 0 }, .{ .t = 0.25, .value = 2 }, .{ .t = 1, .value = 1 } },
        .color_over_life = &.{ .{ .t = 0, .color = .{ 1, 0, 0, 0 } }, .{ .t = 1, .color = .{ 0, 0, 1, 1 } } },
    };
    try emitter.validate();
    try testing.expectEqual(@as(f32, 0), emitter.sizeAt(0));
    try testing.expectEqual(@as(f32, 1), emitter.sizeAt(0.125));
    try testing.expectEqual(@as(f32, 2), emitter.sizeAt(0.25));
    try testing.expectEqual(@as(f32, 1.5), emitter.sizeAt(0.625));
    try testing.expectEqual(@as(f32, 1), emitter.sizeAt(1));
    try testing.expectEqual(@as(f32, 2), emitter.maxSizeFactor());
    try testing.expectEqual([4]f32{ 0.5, 0, 0.5, 0.5 }, emitter.colorAt(0.5));
    try testing.expectEqual([4]f32{ 0, 0, 1, 1 }, emitter.colorAt(1));
    const plain: Emitter = .{};
    try testing.expectEqual(@as(f32, 1), plain.sizeAt(0.3));
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, plain.colorAt(0.3));
}
