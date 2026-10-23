//! The step's contract (`docs/design/particles.md` §11): spawn counts against their closed form,
//! ages from ticks, order kept through removal, a full store dropping, shapes, play and stop,
//! space, and the pinned hash with its replay.

const std = @import("std");
const core = @import("core");
const particles = @import("root.zig");
const trig = @import("trig.zig");

const testing = std.testing;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const Emitter = particles.Emitter;
const System = particles.System;

/// A power of two, so tick times are exact and the closed forms below are too.
const dt: f32 = 1.0 / 64.0;

fn run(system: *System, emitter: *const Emitter, first: u64, ticks: u64, transform: Mat4) void {
    for (first..first + ticks) |tick| system.step(emitter, tick, dt, transform);
}

test "continuous spawns match the closed form tick by tick, from tick zero" {
    const emitter: Emitter = .{ .capacity = 4096, .rate = 37, .lifetime = .constant(100) };
    try emitter.validate();
    var system = try System.init(testing.allocator, emitter.capacity, 1, 0);
    defer system.deinit();
    var spawned: u64 = 0;
    for (0..300) |tick| {
        system.step(&emitter, tick, dt, .identity);
        const n: f64 = @floatFromInt(tick + 1);
        const expected: u64 = @intFromFloat(@ceil(37 * n * dt) - @ceil(37 * (n - 1) * dt));
        try testing.expectEqual(spawned + expected, system.counts.spawned);
        spawned = system.counts.spawned;
    }
    // Spawns `m` at `m / rate` for every `m / rate` before 300 ticks.
    try testing.expectEqual(@as(u64, @intFromFloat(@ceil(37.0 * 300.0 * dt))), system.counts.spawned);
}

test "bursts repeat each loop, interleave with the rate in time order, and stop without loop" {
    const bursts = [_]particles.Burst{ .{ .time = 0.25, .count = 2 }, .{ .time = 0, .count = 5 } };
    const looping: Emitter = .{ .capacity = 4096, .rate = 32, .bursts = &bursts, .duration = 0.5, .lifetime = .constant(100) };
    try looping.validate();
    var system = try System.init(testing.allocator, looping.capacity, 1, 0);
    defer system.deinit();
    run(&system, &looping, 0, 64, .identity);
    // One second, two loops: 32 continuous spawns, and the bursts at 0, 0.25, 0.5 and 0.75.
    try testing.expectEqual(@as(u64, 32 + 2 * 7), system.counts.spawned);
    // Births never decrease along spawn order, and a burst precedes a coinciding rate spawn.
    const births = system.particles.items(.birth);
    for (births[1..], births[0 .. births.len - 1]) |b, a| try testing.expect(b >= a);
    // A timeline first stepped at tick 0 begins a tick earlier, so its time zero is −dt: the
    // burst of five and the rate's m = 0 are born together, and m = 1 is the first after.
    for (births[0..6]) |b| try testing.expectEqual(@as(f64, -dt), b);
    try testing.expect(births[6] > -dt);

    var once = looping;
    once.loop = false;
    var single = try System.init(testing.allocator, once.capacity, 1, 0);
    defer single.deinit();
    run(&single, &once, 0, 128, .identity);
    // Half a second of rate, and each burst once.
    try testing.expectEqual(@as(u64, 16 + 7), single.counts.spawned);
}

test "age comes from ticks, and removal keeps spawn order" {
    const emitter: Emitter = .{ .capacity = 512, .rate = 64, .lifetime = .{ .min = 0.1, .max = 0.6 } };
    var system = try System.init(testing.allocator, emitter.capacity, 9, 0);
    defer system.deinit();
    for (0..200) |tick| {
        system.step(&emitter, tick, dt, .identity);
        const now = @as(f64, @floatFromInt(tick)) * dt;
        const s = system.particles.slice();
        for (s.items(.birth), s.items(.lifetime)) |birth, lifetime| try testing.expect(now - birth < lifetime);
        const serials = s.items(.serial);
        if (serials.len > 1) for (serials[1..], serials[0 .. serials.len - 1]) |b, a| try testing.expect(b > a);
    }
    // Lifetimes vary, so some younger particles died before older ones.
    try testing.expect(system.liveCount() < system.counts.spawned);
}

test "a full store drops new spawns and counts them, never stealing the oldest" {
    const emitter: Emitter = .{ .capacity = 10, .rate = 640, .lifetime = .constant(100) };
    var system = try System.init(testing.allocator, emitter.capacity, 3, 0);
    defer system.deinit();
    run(&system, &emitter, 0, 4, .identity);
    try testing.expectEqual(@as(u32, 10), system.liveCount());
    try testing.expectEqual(@as(u64, 10), system.counts.spawned);
    try testing.expectEqual(@as(u64, 40 - 10), system.counts.dropped);
    try testing.expectEqual(@as(u64, 0), system.particles.items(.serial)[0]);
}

test "a lower capacity removes the oldest first" {
    var emitter: Emitter = .{ .capacity = 100, .rate = 64, .lifetime = .constant(100) };
    var system = try System.init(testing.allocator, emitter.capacity, 3, 0);
    defer system.deinit();
    run(&system, &emitter, 0, 64, .identity);
    try testing.expectEqual(@as(u32, 64), system.liveCount());
    emitter.capacity = 20;
    emitter.rate = 0;
    system.step(&emitter, 64, dt, .identity);
    try testing.expectEqual(@as(u32, 20), system.liveCount());
    try testing.expectEqual(@as(u64, 44), system.counts.shrunk);
    try testing.expectEqual(@as(u64, 44), system.particles.items(.serial)[0]);
}

test "shapes start inside their bounds and leave in their directions" {
    const cases = [_]particles.Shape{
        .{ .kind = .point },
        .{ .kind = .sphere, .radius = 2 },
        .{ .kind = .sphere, .radius = 2, .surface = true },
        .{ .kind = .box, .extent = .{ 1, 2, 3 } },
        .{ .kind = .cone, .radius = 0.5, .angle = 0.4 },
    };
    for (cases) |shape| {
        // Speed 1, no acceleration or drag, and a step of exactly one birth, so a particle's
        // start is its position less its velocity times its time since birth.
        const emitter: Emitter = .{ .capacity = 2048, .rate = 64 * 8, .shape = shape, .lifetime = .constant(100) };
        try emitter.validate();
        var system = try System.init(testing.allocator, emitter.capacity, 5, 0);
        defer system.deinit();
        run(&system, &emitter, 0, 4, .identity);
        const s = system.particles.slice();
        // The timeline began a tick before tick 0, so tick 3 ends at three ticks' time.
        const end_time: f64 = 3 * dt;
        for (s.items(.position), s.items(.velocity), s.items(.birth)) |p, v, birth| {
            const velocity = Vec3.init(v[0], v[1], v[2]);
            try testing.expectApproxEqAbs(@as(f32, 1), velocity.length(), 1e-4);
            const t: f32 = @floatCast(end_time - birth);
            const start = Vec3.init(p[0], p[1], p[2]).sub(velocity.scale(t));
            switch (shape.kind) {
                .point => try testing.expect(start.length() < 1e-5),
                .sphere => {
                    try testing.expect(start.length() <= shape.radius + 1e-4);
                    if (shape.surface) try testing.expectApproxEqAbs(shape.radius, start.length(), 1e-4);
                },
                .box => {
                    try testing.expect(@abs(start.x) <= 1 + 1e-5 and @abs(start.y) <= 2 + 1e-5 and @abs(start.z) <= 3 + 1e-5);
                    try testing.expectEqual(Vec3.up, velocity);
                },
                .cone => {
                    try testing.expect(@abs(start.y) < 1e-5 and Vec3.init(start.x, 0, start.z).length() <= 0.5 + 1e-5);
                    try testing.expect(velocity.y >= @cos(shape.angle) - 1e-5);
                },
            }
        }
    }
}

test "stop ends spawning and lets particles finish; play starts a new timeline; clear empties" {
    const bursts = [_]particles.Burst{.{ .time = 0, .count = 3 }};
    const emitter: Emitter = .{ .capacity = 64, .bursts = &bursts, .duration = 10, .lifetime = .constant(0.5) };
    var system = try System.init(testing.allocator, emitter.capacity, 2, 0);
    defer system.deinit();
    run(&system, &emitter, 0, 2, .identity);
    try testing.expectEqual(@as(u32, 3), system.liveCount());
    system.stop();
    run(&system, &emitter, 2, 64, .identity);
    try testing.expectEqual(@as(u32, 0), system.liveCount());
    system.play();
    // The new timeline's time zero fires the burst again, at this tick.
    system.step(&emitter, 66, dt, .identity);
    try testing.expectEqual(@as(u32, 3), system.liveCount());
    try testing.expectEqual(@as(f64, 65 * dt), system.particles.items(.birth)[0]);
    system.clear();
    system.stop();
    system.step(&emitter, 67, dt, .identity);
    try testing.expectEqual(@as(u32, 0), system.liveCount());
}

test "world space leaves particles behind a moving emitter, local space carries them" {
    const world: Emitter = .{ .capacity = 256, .rate = 128, .speed = .constant(0), .lifetime = .constant(100) };
    var local = world;
    local.space = .local;
    var a = try System.init(testing.allocator, 256, 4, 0);
    defer a.deinit();
    var b = try System.init(testing.allocator, 256, 4, 0);
    defer b.deinit();
    for (0..64) |tick| {
        const at = Mat4.translation(.init(@as(f32, @floatFromInt(tick)), 0, 0));
        a.step(&world, tick, dt, at);
        b.step(&local, tick, dt, at);
    }
    // World: two births a tick, at its start and halfway, placed between the transforms they
    // fell between.
    const xs = a.particles.items(.position);
    for (xs[1..], xs[0 .. xs.len - 1]) |p, q| try testing.expect(p[0] >= q[0]);
    try testing.expectEqual(@as(usize, 128), xs.len);
    try testing.expectEqual(@as(f32, 0), xs[0][0]);
    try testing.expectEqual(@as(f32, 62.5), xs[xs.len - 1][0]);
    // Local: every particle is at the emitter's origin in its own frame.
    for (b.particles.items(.position)) |p| try testing.expectEqual([3]f32{ 0, 0, 0 }, p);
    try testing.expect(a.bounds != null and a.bounds.?.max[0] > 62);
}

/// A description that touches every part of the step: rate and bursts over loops, a cone,
/// acceleration, drag, varied lifetimes and sizes, and a moving transform, with a burst at each
/// loop's start that coincides with a continuous spawn.
const pinned_bursts = [_]particles.Burst{ .{ .time = 0.2, .count = 12 }, .{ .time = 0, .count = 3 }, .{ .time = 0.7, .count = 4 } };
const pinned: Emitter = .{
    .capacity = 600,
    .rate = 120,
    .bursts = &pinned_bursts,
    .duration = 1.5,
    .lifetime = .{ .min = 0.4, .max = 2.2 },
    .shape = .{ .kind = .cone, .radius = 0.2, .angle = 0.5 },
    .speed = .{ .min = 1, .max = 3 },
    .acceleration = .{ 0, -9.81, 0 },
    .drag = 0.4,
    .size = .{ .min = 0.05, .max = 0.2 },
    .rotation = .{ .min = 0, .max = 6.2832 },
    .spin = .{ .min = -2, .max = 2 },
    .seed = 0x5eed,
};

fn pinnedRun(stream: u64) !u64 {
    try pinned.validate();
    var system = try System.init(testing.allocator, pinned.capacity, pinned.seed, stream);
    defer system.deinit();
    for (0..600) |tick| {
        const t: f32 = @floatFromInt(tick);
        // `trig`, not `@sin`, for the reason `trig.zig` gives: this input is part of the pin.
        const sway: f32 = @floatCast(trig.sinCosTurns(t / 128)[0]);
        system.step(&pinned, tick, dt, Mat4.translation(.init(sway, 0, t * 0.01)));
    }
    return system.hash();
}

test "600 ticks from a seed match the pinned hash, again and on replay" {
    const pinned_hash: u64 = 0xc9fa8e13b9c40c85;
    const first = try pinnedRun(1);
    try testing.expectEqual(pinned_hash, first);
    try testing.expectEqual(first, try pinnedRun(1));
    // Another instance stream is another sequence.
    try testing.expect(first != try pinnedRun(2));
}
