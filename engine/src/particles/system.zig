//! One running emitter's particles, and the step that ages, moves and spawns them
//! (`docs/design/particles.md` §3.2).
//!
//! **Time is the caller's tick times its fixed delta.** Every age is `tick·dt − birth`, never an
//! accumulated sum, and every spawn count comes from a closed form over the interval a step
//! covers. So a run at any frame rate that steps the same ticks gives the same bytes, and a
//! replay from tick zero reproduces every particle (I9).
//!
//! **Order is part of the result.** Particles are kept in spawn order, and removal compacts
//! without reordering, because the sort's tie-break (§3.3) and a shrinking capacity both read
//! that order. A full store drops the new spawn and counts it; it never steals the oldest.

const std = @import("std");
const core = @import("core");
const emitter_mod = @import("emitter.zig");
const trig = @import("trig.zig");

const Allocator = std.mem.Allocator;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const Vec4 = core.math.Vec4;
const Emitter = emitter_mod.Emitter;
const Pcg32 = core.rng.Pcg32;

pub const Particle = struct {
    /// In world axes, or the emitter's frame for `local` space.
    position: [3]f32,
    velocity: [3]f32,
    /// Seconds since tick zero: the exact instant it was due, inside the tick that spawned it.
    birth: f64,
    lifetime: f32,
    /// Metres: the quad's side before `size_over_life`.
    size: f32,
    /// Radians at birth; `rotation + spin·age` is the angle at an age.
    rotation: f32,
    spin: f32,
    /// A per-particle draw, for anything that varies by particle at expansion.
    random: u32,
    /// Spawn order across the system's life; the sort's tie-break.
    serial: u64,
};

pub const Aabb = struct { min: [3]f32, max: [3]f32 };

/// What a step observed, for the counters `render3d` folds into `Stats` (§6).
pub const Counts = struct {
    spawned: u64 = 0,
    /// Spawns refused by a full store.
    dropped: u64 = 0,
    /// Particles removed, oldest first, because a description lowered the capacity.
    shrunk: u64 = 0,
};

pub const System = struct {
    gpa: Allocator,
    particles: std.MultiArrayList(Particle) = .empty,
    /// The store's size, fixed at `init`. A description may ask for less, never more.
    capacity: u32,
    rng: Pcg32,
    next_serial: u64 = 0,
    playing: bool = true,
    /// The tick before the current emission timeline's first; set by the first step after
    /// `play`. Signed, because a system first stepped at tick 0 starts its timeline at −1.
    origin: ?i64 = null,
    /// The last tick stepped, and the delta it was stepped with.
    last_tick: ?u64 = null,
    dt: ?f32 = null,
    /// The emitter's transform at the previous step, so spawns inside a tick follow its motion.
    previous: ?Mat4 = null,
    pending_clear: bool = false,
    bounds: ?Aabb = null,
    counts: Counts = .{},

    /// `stream` separates instances of one description, as `Pcg32` streams do: it is a stable
    /// constant the caller chooses, never a creation order (I2's reasoning).
    pub fn init(gpa: Allocator, capacity: u32, seed: u64, stream: u64) Allocator.Error!System {
        std.debug.assert(capacity > 0 and capacity <= emitter_mod.max_capacity);
        var self: System = .{ .gpa = gpa, .capacity = capacity, .rng = .init(seed, stream) };
        try self.particles.setCapacity(gpa, capacity);
        return self;
    }

    pub fn deinit(self: *System) void {
        self.particles.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn liveCount(self: *const System) u32 {
        return @intCast(self.particles.len);
    }

    /// Starts a new emission timeline at the next step. Live particles are kept.
    pub fn play(self: *System) void {
        if (self.playing) return;
        self.playing = true;
        self.origin = null;
    }

    /// Ends spawning; live particles finish their lives.
    pub fn stop(self: *System) void {
        self.playing = false;
        self.origin = null;
    }

    /// Removes every live particle at the next step.
    pub fn clear(self: *System) void {
        self.pending_clear = true;
    }

    /// Advances to `tick`, which must be later than the last one stepped, with the same fixed
    /// `dt` every time. `transform` is the emitter's world transform at this tick. A gap of
    /// several ticks is one interval: it moves and spawns exactly what each tick would have
    /// spawned, but integrates survivors in one stride.
    pub fn step(self: *System, emitter: *const Emitter, tick: u64, dt: f32, transform: Mat4) void {
        std.debug.assert(std.math.isFinite(dt) and dt > 0);
        if (self.dt) |fixed| std.debug.assert(fixed == dt) else self.dt = dt;
        if (self.last_tick) |last| std.debug.assert(tick > last);
        const elapsed_ticks: u64 = if (self.last_tick) |last| tick - last else 1;
        const now = seconds(tick, dt);

        if (self.pending_clear) {
            self.particles.shrinkRetainingCapacity(0);
            self.pending_clear = false;
        }
        const limit = @min(emitter.capacity, self.capacity);
        if (self.particles.len > limit) {
            const excess = self.particles.len - limit;
            self.removeOldest(excess);
            self.counts.shrunk += excess;
        }

        self.age(now);
        self.integrate(emitter, @floatCast(seconds(elapsed_ticks, dt)));
        if (self.playing) {
            const at: i64 = @intCast(tick);
            const origin = self.origin orelse at - @as(i64, @intCast(elapsed_ticks));
            self.origin = origin;
            self.spawn(emitter, .{
                .origin = signedSeconds(origin, dt),
                .from = signedSeconds(at - @as(i64, @intCast(elapsed_ticks)) - origin, dt),
                .to = signedSeconds(at - origin, dt),
                .limit = limit,
                .previous = self.previous orelse transform,
                .current = transform,
            });
        }
        self.previous = transform;
        self.last_tick = tick;
        self.refit(emitter);
    }

    /// FNV-1a over the live particles, in order: the value tests and samples pin (§12).
    pub fn hash(self: *const System) u64 {
        var h: Fnv = .{};
        h.add(std.mem.asBytes(&@as(u32, @intCast(self.particles.len))));
        const s = self.particles.slice();
        for (0..s.len) |i| {
            const p = s.get(i);
            h.add(std.mem.sliceAsBytes(&p.position));
            h.add(std.mem.sliceAsBytes(&p.velocity));
            h.add(std.mem.asBytes(&p.birth));
            h.add(std.mem.asBytes(&p.lifetime));
            h.add(std.mem.asBytes(&p.size));
            h.add(std.mem.asBytes(&p.rotation));
            h.add(std.mem.asBytes(&p.spin));
            h.add(std.mem.asBytes(&p.random));
            h.add(std.mem.asBytes(&p.serial));
        }
        return h.state;
    }

    /// Removes particles whose age at `now` has reached their lifetime, keeping the order of
    /// the rest.
    fn age(self: *System, now: f64) void {
        var s = self.particles.slice();
        const births = s.items(.birth);
        const lifetimes = s.items(.lifetime);
        var kept: usize = 0;
        for (0..s.len) |i| {
            if (now - births[i] >= lifetimes[i]) continue;
            if (kept != i) s.set(kept, s.get(i));
            kept += 1;
        }
        self.particles.shrinkRetainingCapacity(kept);
    }

    /// The first `count` particles are the oldest, because order is spawn order.
    fn removeOldest(self: *System, count: usize) void {
        var s = self.particles.slice();
        for (count..s.len) |i| s.set(i - count, s.get(i));
        self.particles.shrinkRetainingCapacity(s.len - count);
    }

    fn integrate(self: *System, emitter: *const Emitter, stride: f32) void {
        const s = self.particles.slice();
        for (s.items(.position), s.items(.velocity)) |*p, *v| move(emitter, p, v, stride);
    }

    const Interval = struct {
        /// The timeline's tick zero, in seconds since tick zero.
        origin: f64,
        /// `[from, to)`, in seconds on the timeline.
        from: f64,
        to: f64,
        limit: u32,
        previous: Mat4,
        current: Mat4,
    };

    /// Everything due in `[from, to)`, in birth order: continuous spawns at `m / rate` and
    /// bursts at `k·duration + time`. Which goes first when the two coincide cannot be observed:
    /// particles born at one instant draw and are stored alike, whatever spawned them.
    fn spawn(self: *System, emitter: *const Emitter, interval: Interval) void {
        const duration: f64 = emitter.duration;
        const end = if (emitter.loop) interval.to else @min(interval.to, duration);
        if (interval.from >= end) return;

        const rate: f64 = emitter.rate;
        var m: f64 = if (rate > 0) @ceil(rate * interval.from) else 0;
        const m_end: f64 = if (rate > 0) @ceil(rate * end) else 0;
        const order = burstOrder(emitter);
        const bursts = order.indices[0..emitter.bursts.len];

        // Loops are visited in order and bursts within a loop by time, and every burst's time is
        // below `duration`, so the walk is in time order and can stop at the first one past `end`.
        const first_loop: u64 = if (emitter.loop) @intFromFloat(@floor(interval.from / duration)) else 0;
        const last_loop: u64 = if (emitter.loop) @intFromFloat(@floor(end / duration)) else 0;
        var k = first_loop;
        walk: while (k <= last_loop) : (k += 1) {
            for (bursts) |index| {
                const burst = emitter.bursts[index];
                const at = @as(f64, @floatFromInt(k)) * duration + burst.time;
                if (at < interval.from) continue;
                if (at >= end) break :walk;
                while (m < m_end and m / rate < at) : (m += 1) self.spawnOne(emitter, interval, m / rate);
                for (0..burst.count) |_| self.spawnOne(emitter, interval, at);
            }
        }
        while (m < m_end) : (m += 1) self.spawnOne(emitter, interval, m / rate);
    }

    const BurstOrder = struct { indices: [emitter_mod.max_bursts]usize };

    /// Bursts by `(time, stored index)`, a total order; at most eight, so an insertion sort.
    fn burstOrder(emitter: *const Emitter) BurstOrder {
        var out: BurstOrder = .{ .indices = undefined };
        const n = emitter.bursts.len;
        for (0..n) |i| out.indices[i] = i;
        if (n > 1) for (1..n) |i| {
            var j = i;
            while (j > 0 and emitter.bursts[out.indices[j - 1]].time > emitter.bursts[out.indices[j]].time) : (j -= 1) {
                std.mem.swap(usize, &out.indices[j - 1], &out.indices[j]);
            }
        };
        return out;
    }

    /// One particle born at timeline second `at`. Its draws are made in a fixed order whether
    /// or not it survives to be stored, so a short life never shifts the next particle's.
    fn spawnOne(self: *System, emitter: *const Emitter, interval: Interval, at: f64) void {
        if (self.particles.len >= interval.limit) {
            self.counts.dropped += 1;
            return;
        }
        const rng = &self.rng;
        const lifetime = emitter.lifetime.at(rng.float01());
        const speed = emitter.speed.at(rng.float01());
        const size = emitter.size.at(rng.float01());
        const rotation = emitter.rotation.at(rng.float01());
        const spin = emitter.spin.at(rng.float01());
        const random = rng.next();
        const start = shapeSample(emitter.shape, .{ rng.float01(), rng.float01(), rng.float01(), rng.float01() });

        var position = start.position;
        var velocity = start.direction.scale(speed);
        if (emitter.space == .world) {
            // Where the emitter was at `at`, between its previous and current transforms.
            const span = interval.to - interval.from;
            const f: f32 = if (span > 0) @floatCast((at - interval.from) / span) else 1;
            const was = interval.previous.mulVec4(.fromPoint(position)).xyz();
            const is = interval.current.mulVec4(.fromPoint(position)).xyz();
            position = was.lerp(is, f);
            velocity = interval.current.mulVec4(.fromDirection(velocity)).xyz();
        }
        // Integrated from its birth to the end of the tick, so a stream from a moving emitter is
        // continuous rather than clumped at tick boundaries.
        const remaining: f32 = @floatCast(interval.to - at);
        if (remaining >= lifetime) return;
        var p: [3]f32 = .{ position.x, position.y, position.z };
        var v: [3]f32 = .{ velocity.x, velocity.y, velocity.z };
        move(emitter, &p, &v, remaining);
        self.particles.appendAssumeCapacity(.{
            .position = p,
            .velocity = v,
            .birth = interval.origin + at,
            .lifetime = lifetime,
            .size = size,
            .rotation = rotation,
            .spin = spin,
            .random = random,
            .serial = self.next_serial,
        });
        self.next_serial += 1;
        self.counts.spawned += 1;
    }

    /// Live positions, padded by the largest quad's half-diagonal and any velocity stretch, in
    /// the space positions are kept in.
    fn refit(self: *System, emitter: *const Emitter) void {
        const s = self.particles.slice();
        if (s.len == 0) {
            self.bounds = null;
            return;
        }
        var lo: [3]f32 = s.items(.position)[0];
        var hi: [3]f32 = lo;
        var largest: f32 = 0;
        var fastest: f32 = 0;
        for (s.items(.position), s.items(.velocity), s.items(.size)) |p, v, size| {
            for (0..3) |axis| {
                lo[axis] = @min(lo[axis], p[axis]);
                hi[axis] = @max(hi[axis], p[axis]);
            }
            largest = @max(largest, size);
            fastest = @max(fastest, Vec3.init(v[0], v[1], v[2]).length());
        }
        const pad = largest * emitter.maxSizeFactor() * std.math.sqrt1_2 + emitter.stretch * fastest;
        for (0..3) |axis| {
            lo[axis] -= pad;
            hi[axis] += pad;
        }
        self.bounds = .{ .min = lo, .max = hi };
    }
};

/// Semi-implicit Euler with linear drag: `v += a·dt`, `v *= 1/(1 + drag·dt)`, `p += v·dt`.
fn move(emitter: *const Emitter, p: *[3]f32, v: *[3]f32, dt: f32) void {
    const damp = 1 / (1 + emitter.drag * dt);
    for (0..3) |axis| {
        v[axis] = (v[axis] + emitter.acceleration[axis] * dt) * damp;
        p[axis] += v[axis] * dt;
    }
}

fn seconds(ticks: u64, dt: f32) f64 {
    return @as(f64, @floatFromInt(ticks)) * @as(f64, dt);
}

fn signedSeconds(ticks: i64, dt: f32) f64 {
    return @as(f64, @floatFromInt(ticks)) * @as(f64, dt);
}

const Start = struct { position: Vec3, direction: Vec3 };

/// A start in the emitter's local frame from four uniform draws, always four, so every shape
/// consumes the generator alike. Angles go through `trig`, never `@sin`, so the start does not
/// depend on the math library a binary linked.
fn shapeSample(shape: emitter_mod.Shape, u: [4]f32) Start {
    switch (shape.kind) {
        .point => return .{ .position = .zero, .direction = sphereDirection(u[0], u[1]) },
        .sphere => {
            const direction = sphereDirection(u[0], u[1]);
            const r = if (shape.surface) shape.radius else shape.radius * std.math.cbrt(u[2]);
            return .{ .position = direction.scale(r), .direction = direction };
        },
        .box => return .{
            .position = .init((2 * u[0] - 1) * shape.extent[0], (2 * u[1] - 1) * shape.extent[1], (2 * u[2] - 1) * shape.extent[2]),
            .direction = .up,
        },
        .cone => {
            const r = shape.radius * @sqrt(u[0]);
            const theta = trig.sinCosTurns(u[1]);
            // Uniform over the spherical cap of half-angle `angle` about +Y.
            const cos_angle: f32 = @floatCast(trig.sinCosTurns(shape.angle / (2 * std.math.pi))[1]);
            const cos_a = 1 - u[2] * (1 - cos_angle);
            const sin_a = @sqrt(@max(0, 1 - cos_a * cos_a));
            const phi = trig.sinCosTurns(u[3]);
            return .{
                .position = .init(r * narrow(theta[1]), 0, r * narrow(theta[0])),
                .direction = .init(sin_a * narrow(phi[1]), cos_a, sin_a * narrow(phi[0])),
            };
        },
    }
}

/// Uniform on the unit sphere.
fn sphereDirection(u: f32, v: f32) Vec3 {
    const y = 2 * u - 1;
    const r = @sqrt(@max(0, 1 - y * y));
    const phi = trig.sinCosTurns(v);
    return .init(r * narrow(phi[1]), y, r * narrow(phi[0]));
}

fn narrow(value: f64) f32 {
    return @floatCast(value);
}

/// FNV-1a, 64-bit, written out rather than taken from `std` for `core.rng`'s reason: a pinned
/// hash is a promise, and `std` is not a stability contract.
const Fnv = struct {
    state: u64 = 0xcbf29ce484222325,

    fn add(self: *Fnv, bytes: []const u8) void {
        for (bytes) |b| {
            self.state ^= b;
            self.state *%= 0x100000001b3;
        }
    }
};
