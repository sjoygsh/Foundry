//! The expansion's contract (`docs/design/particles.md` §11): each facing's corners, the sort and
//! its tie-break, premultiplied colour, sheet frames, bounds, `local` space, and the same bytes at
//! every worker count, pinned per facing.

const std = @import("std");
const core = @import("core");
const particles = @import("root.zig");
const expand = @import("expand.zig");
const system_mod = @import("system.zig");

const testing = std.testing;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const Emitter = particles.Emitter;
const System = particles.System;
const View = particles.View;

const dt: f32 = 1.0 / 64.0;

/// The camera at the origin looking down −Z: right +X, up +Y.
const front: View = .fromCamera(.identity);

/// Owned buffers for `quads` quads.
const Buffers = struct {
    positions: [][3]f32,
    uvs: [][2]f32,
    colors: [][4]f32,
    indices: []u16,

    fn init(quads: usize) !Buffers {
        const gpa = testing.allocator;
        return .{
            .positions = try gpa.alloc([3]f32, quads * 4),
            .uvs = try gpa.alloc([2]f32, quads * 4),
            .colors = try gpa.alloc([4]f32, quads * 4),
            .indices = try gpa.alloc(u16, quads * 6),
        };
    }

    fn deinit(self: Buffers) void {
        const gpa = testing.allocator;
        gpa.free(self.positions);
        gpa.free(self.uvs);
        gpa.free(self.colors);
        gpa.free(self.indices);
    }

    fn output(self: Buffers) particles.Output {
        return .{ .positions = self.positions, .uvs = self.uvs, .colors = self.colors, .indices = self.indices };
    }

    /// FNV-1a over the first `quads` quads of every stream, in stream order.
    fn hash(self: Buffers, quads: usize) u64 {
        var h: system_mod.Fnv = .{};
        h.add(std.mem.sliceAsBytes(self.positions[0 .. quads * 4]));
        h.add(std.mem.sliceAsBytes(self.uvs[0 .. quads * 4]));
        h.add(std.mem.sliceAsBytes(self.colors[0 .. quads * 4]));
        h.add(std.mem.sliceAsBytes(self.indices[0 .. quads * 6]));
        return h.state;
    }
};

/// A system holding exactly `list`, as if last stepped at `tick`.
fn holding(list: []const system_mod.Particle, tick: u64) !System {
    var system = try System.init(testing.allocator, 64, 0, 0);
    for (list) |p| system.particles.appendAssumeCapacity(p);
    system.last_tick = tick;
    system.dt = dt;
    return system;
}

fn particle(position: [3]f32, serial: u64) system_mod.Particle {
    return .{ .position = position, .velocity = .{ 0, 0, 0 }, .birth = 0, .lifetime = 10, .size = 2, .rotation = 0, .spin = 0, .random = 0, .serial = serial };
}

fn expandOnce(system: *const System, emitter: *const Emitter, view: View, options: particles.Expander.Options, buffers: Buffers) !particles.Expanded {
    var expander = try particles.Expander.init(testing.allocator, system.capacity);
    defer expander.deinit();
    return expander.expand(system, emitter, view, options, buffers.output(), core.jobs.serial);
}

test "a camera-facing quad spans the view's right and up, and turns with rotation and spin" {
    const emitter: Emitter = .{};
    var p = particle(.{ 0, 0, -5 }, 0);
    var system = try holding(&.{p}, 0);
    defer system.deinit();
    const buffers = try Buffers.init(1);
    defer buffers.deinit();
    const result = try expandOnce(&system, &emitter, front, .{ .sorted = false }, buffers);
    try testing.expectEqual(@as(u32, 1), result.quads);
    try testing.expectEqualSlices([3]f32, &.{ .{ -1, -1, -5 }, .{ 1, -1, -5 }, .{ 1, 1, -5 }, .{ -1, 1, -5 } }, buffers.positions[0..4]);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 0, 2, 3 }, buffers.indices[0..6]);
    try testing.expectEqualSlices([2]f32, &.{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } }, buffers.uvs[0..4]);
    try testing.expectEqual(particles.Aabb{ .min = .{ -1, -1, -5 }, .max = .{ 1, 1, -5 } }, result.bounds.?);

    // A quarter turn, half from the birth rotation and half from spin over one second of age.
    p.rotation = std.math.pi / 4.0;
    p.spin = std.math.pi / 4.0;
    var turned = try holding(&.{p}, 64);
    defer turned.deinit();
    _ = try expandOnce(&turned, &emitter, front, .{ .sorted = false }, buffers);
    const expected = [4][3]f32{ .{ 1, -1, -5 }, .{ 1, 1, -5 }, .{ -1, 1, -5 }, .{ -1, -1, -5 } };
    for (expected, buffers.positions[0..4]) |e, got| for (e, got) |a, b| try testing.expectApproxEqAbs(a, b, 1e-6);
}

test "an up-facing quad lies in the emitter's XZ plane" {
    const emitter: Emitter = .{ .facing = .up };
    var system = try holding(&.{particle(.{ 0, 0, 0 }, 0)}, 0);
    defer system.deinit();
    const buffers = try Buffers.init(1);
    defer buffers.deinit();
    _ = try expandOnce(&system, &emitter, front, .{ .sorted = false }, buffers);
    try testing.expectEqualSlices([3]f32, &.{ .{ -1, 0, -1 }, .{ 1, 0, -1 }, .{ 1, 0, 1 }, .{ -1, 0, 1 } }, buffers.positions[0..4]);
    // A tilted emitter tilts its quads: a quarter turn about X stands the plane up in XY.
    _ = try expandOnce(&system, &emitter, front, .{ .sorted = false, .transform = Mat4.rotationX(std.math.pi / 2.0) }, buffers);
    for ([4][3]f32{ .{ -1, 1, 0 }, .{ 1, 1, 0 }, .{ 1, -1, 0 }, .{ -1, -1, 0 } }, buffers.positions[0..4]) |e, got| for (e, got) |a, b| try testing.expectApproxEqAbs(a, b, 1e-6);
}

test "a velocity-facing quad stretches along its screen-space motion" {
    const emitter: Emitter = .{ .facing = .velocity, .stretch = 0.5 };
    var p = particle(.{ 0, 0, -5 }, 0);
    p.velocity = .{ 0, 2, -3 }; // Its motion along the view does not stretch it.
    var system = try holding(&.{p}, 0);
    defer system.deinit();
    const buffers = try Buffers.init(1);
    defer buffers.deinit();
    _ = try expandOnce(&system, &emitter, front, .{ .sorted = false }, buffers);
    // Long axis +Y at half 1 + 0.5·|v|/2; wide axis forward × long = +X at half 1.
    const long = 1 + 0.5 * @sqrt(@as(f32, 13)) / 2;
    const expected = [4][3]f32{ .{ -1, -long, -5 }, .{ -1, long, -5 }, .{ 1, long, -5 }, .{ 1, -long, -5 } };
    for (expected, buffers.positions[0..4]) |e, got| for (e, got) |a, b| try testing.expectApproxEqAbs(a, b, 1e-5);

    // Moving straight at the camera, there is nothing to stretch along: it faces the camera.
    p.velocity = .{ 0, 0, 4 };
    var head_on = try holding(&.{p}, 0);
    defer head_on.deinit();
    _ = try expandOnce(&head_on, &emitter, front, .{ .sorted = false }, buffers);
    try testing.expectEqualSlices([3]f32, &.{ .{ -1, -1, -5 }, .{ 1, -1, -5 }, .{ 1, 1, -5 }, .{ -1, 1, -5 } }, buffers.positions[0..4]);
}

test "blended quads draw far to near with ties by serial; unsorted keeps spawn order" {
    const emitter: Emitter = .{};
    // Depths along −Z: 2, 9, and 5 twice. A store is in spawn order (Step 1), so serials
    // ascend with position in it, and the tie between the two at 5 goes to the earlier.
    var system = try holding(&.{
        particle(.{ 0, 0, -2 }, 10),
        particle(.{ 0, 0, -9 }, 11),
        particle(.{ 3, 0, -5 }, 12),
        particle(.{ -3, 0, -5 }, 13),
    }, 0);
    defer system.deinit();
    const buffers = try Buffers.init(4);
    defer buffers.deinit();
    _ = try expandOnce(&system, &emitter, front, .{ .sorted = true }, buffers);
    const centre_x = [_]f32{ 0, 3, -3, 0 };
    const centre_z = [_]f32{ -9, -5, -5, -2 };
    for (0..4) |q| {
        try testing.expectEqual(centre_x[q], (buffers.positions[q * 4][0] + buffers.positions[q * 4 + 2][0]) / 2);
        try testing.expectEqual(centre_z[q], buffers.positions[q * 4][2]);
    }
    _ = try expandOnce(&system, &emitter, front, .{ .sorted = false }, buffers);
    for ([_]f32{ -2, -9, -5, -5 }, 0..) |z, q| try testing.expectEqual(z, buffers.positions[q * 4][2]);
}

test "colour is premultiplied, with alpha scaled away by the additive weight" {
    const keys = [_]particles.ColorKey{ .{ .t = 0, .color = .{ 1, 0.5, 0.25, 0.5 } }, .{ .t = 1, .color = .{ 1, 0.5, 0.25, 0.5 } } };
    const buffers = try Buffers.init(1);
    defer buffers.deinit();
    var system = try holding(&.{particle(.{ 0, 0, -1 }, 0)}, 0);
    defer system.deinit();
    for ([_]f32{ 0, 0.5, 1 }, [_]f32{ 0.5, 0.25, 0 }) |additive, alpha| {
        const emitter: Emitter = .{ .color_over_life = &keys, .additive = additive };
        try emitter.validate();
        _ = try expandOnce(&system, &emitter, front, .{ .sorted = false }, buffers);
        for (buffers.colors[0..4]) |c| try testing.expectEqual([4]f32{ 0.5, 0.25, 0.125, alpha }, c);
    }
}

test "sheet frames play once over a life at fps 0, and loop at a rate otherwise" {
    const once: particles.Sheet = .{ .columns = 4, .rows = 4, .frames = 16 };
    try testing.expectEqual(@as(u32, 0), expand.sheetFrame(once, 0, 0));
    try testing.expectEqual(@as(u32, 8), expand.sheetFrame(once, 0.5, 9));
    try testing.expectEqual(@as(u32, 15), expand.sheetFrame(once, 0.999, 9));
    try testing.expectEqual(@as(u32, 15), expand.sheetFrame(once, 1, 9));
    const looping: particles.Sheet = .{ .columns = 2, .rows = 2, .frames = 4, .fps = 10 };
    try testing.expectEqual(@as(u32, 1), expand.sheetFrame(looping, 0.9, 0.55));
    try testing.expectEqual(@as(u32, 0), expand.sheetFrame(looping, 0.1, 0.4));

    // Frame 6 of a 4×4 sheet is column 2, row 1, from the top left.
    const emitter: Emitter = .{ .sheet = once };
    var p = particle(.{ 0, 0, -1 }, 0);
    p.lifetime = 16;
    var system = try holding(&.{p}, 6 * 64 + 32);
    defer system.deinit();
    const buffers = try Buffers.init(1);
    defer buffers.deinit();
    _ = try expandOnce(&system, &emitter, front, .{ .sorted = false }, buffers);
    try testing.expectEqualSlices([2]f32, &.{ .{ 0.5, 0.5 }, .{ 0.75, 0.5 }, .{ 0.75, 0.25 }, .{ 0.5, 0.25 } }, buffers.uvs[0..4]);
}

test "local particles are carried by the transform, and bounds are the vertices' own" {
    const emitter: Emitter = .{ .space = .local };
    var system = try holding(&.{ particle(.{ 0, 0, 0 }, 0), particle(.{ 1, 0, 0 }, 1) }, 0);
    defer system.deinit();
    const buffers = try Buffers.init(2);
    defer buffers.deinit();
    const result = try expandOnce(&system, &emitter, front, .{ .sorted = false, .transform = Mat4.translation(.init(10, 0, -4)) }, buffers);
    try testing.expectEqualSlices([3]f32, &.{ .{ 9, -1, -4 }, .{ 11, -1, -4 }, .{ 11, 1, -4 }, .{ 9, 1, -4 } }, buffers.positions[0..4]);
    try testing.expectEqual(particles.Aabb{ .min = .{ 9, -1, -4 }, .max = .{ 12, 1, -4 } }, result.bounds.?);
    // An empty system writes nothing and has no bounds.
    var empty = try holding(&.{}, 0);
    defer empty.deinit();
    const none = try expandOnce(&empty, &emitter, front, .{ .sorted = true }, buffers);
    try testing.expectEqual(@as(u32, 0), none.quads);
    try testing.expect(none.bounds == null);
}

/// Real threads pulling indices from a shared counter, so chunks run concurrently and in
/// whatever order the scheduler picks.
const Threaded = struct {
    workers: u32,

    fn jobs(self: *Threaded) core.Jobs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: core.Jobs.VTable = .{ .run = run };

    fn run(ptr: *anyopaque, count: u32, task: core.jobs.Task) void {
        const self: *Threaded = @ptrCast(@alignCast(ptr));
        var next = std.atomic.Value(u32).init(0);
        var threads: [8]std.Thread = undefined;
        const extra = self.workers - 1;
        for (threads[0..extra]) |*thread| thread.* = std.Thread.spawn(.{}, pull, .{ &next, count, task }) catch @panic("test thread");
        pull(&next, count, task);
        for (threads[0..extra]) |thread| thread.join();
    }

    fn pull(next: *std.atomic.Value(u32), count: u32, task: core.jobs.Task) void {
        while (true) {
            const i = next.fetchAdd(1, .monotonic);
            if (i >= count) return;
            task.call(task.context, i);
        }
    }
};

/// Several chunks of live particles from every part of the step, seen from an angle.
const many: Emitter = .{
    .capacity = 3000,
    .rate = 4000,
    .lifetime = .{ .min = 0.3, .max = 0.7 },
    .shape = .{ .kind = .sphere, .radius = 1 },
    .speed = .{ .min = 0.5, .max = 2 },
    .acceleration = .{ 0, -2, 0 },
    .size = .{ .min = 0.1, .max = 0.3 },
    .size_over_life = &.{ .{ .t = 0, .value = 0.5 }, .{ .t = 1, .value = 1.5 } },
    .rotation = .{ .min = 0, .max = 6 },
    .spin = .{ .min = -3, .max = 3 },
    .color_over_life = &.{ .{ .t = 0, .color = .{ 1, 0.8, 0.2, 1 } }, .{ .t = 1, .color = .{ 0.2, 0.1, 0, 0 } } },
    .additive = 0.3,
    .stretch = 0.2,
    .sheet = .{ .columns = 4, .rows = 2, .frames = 8 },
    .seed = 77,
};

fn expandWith(facing: particles.Facing, jobs: core.Jobs, buffers: Buffers) !u32 {
    var emitter = many;
    emitter.facing = facing;
    try emitter.validate();
    var system = try System.init(testing.allocator, emitter.capacity, emitter.seed, 0);
    defer system.deinit();
    for (0..96) |tick| system.step(&emitter, tick, dt, Mat4.translation(.init(0, 0, -6)));
    var expander = try particles.Expander.init(testing.allocator, emitter.capacity);
    defer expander.deinit();
    const view = View.fromCamera(Mat4.translation(.init(1, 2, 3)).mul(Mat4.rotationX(-0.3)));
    const result = expander.expand(&system, &emitter, view, .{ .sorted = true, .transform = Mat4.translation(.init(0, 0, -6)) }, buffers.output(), jobs);
    // Every vertex written is inside the bounds returned.
    for (buffers.positions[0 .. result.quads * 4]) |p| for (0..3) |axis| {
        try testing.expect(p[axis] >= result.bounds.?.min[axis] and p[axis] <= result.bounds.?.max[axis]);
    };
    return result.quads;
}

test "every worker count writes the same bytes, pinned per facing" {
    const pins = [_]struct { facing: particles.Facing, hash: u64 }{
        .{ .facing = .camera, .hash = 0x1fd9087640e501cb },
        .{ .facing = .velocity, .hash = 0xe06311a79d0f8f5e },
        .{ .facing = .up, .hash = 0x762af06190750a2f },
    };
    const buffers = try Buffers.init(3000);
    defer buffers.deinit();
    for (pins) |pin| {
        const quads = try expandWith(pin.facing, core.jobs.serial, buffers);
        try testing.expect(quads > 4 * expand.grain);
        const expected = buffers.hash(quads);
        try testing.expectEqual(pin.hash, expected);
        var two: Threaded = .{ .workers = 2 };
        var four: Threaded = .{ .workers = 4 };
        for ([_]core.Jobs{ core.jobs.reversed, two.jobs(), four.jobs() }) |jobs| {
            @memset(buffers.positions, .{ 0, 0, 0 });
            try testing.expectEqual(quads, try expandWith(pin.facing, jobs, buffers));
            try testing.expectEqual(expected, buffers.hash(quads));
        }
    }
}
