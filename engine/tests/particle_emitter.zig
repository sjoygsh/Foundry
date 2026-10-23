//! A `foundry:particle_emitter` record's rules against the simulation's own.
//!
//! `asset` refuses a record where it is compiled and loaded, and `particles` refuses a
//! description it is asked to step. ADR-0064 keeps the two modules apart, so each states the
//! rules itself; this stands above both and fails if they disagree on a limit, a default or a
//! refusal at any boundary.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");
const particles = @import("particles");

const testing = std.testing;
const Record = asset.ParticleEmitter;

/// Field for field, as `render3d` will convert a decoded record (`particles.md` §4).
fn convert(r: *const Record, bursts: []particles.Burst, sizes: []particles.Key, colors: []particles.ColorKey) particles.Emitter {
    for (r.bursts(), 0..) |b, i| bursts[i] = .{ .time = b.time, .count = b.count };
    for (r.sizeOverLife(), 0..) |k, i| sizes[i] = .{ .t = k.t, .value = k.value };
    for (r.colorOverLife(), 0..) |k, i| colors[i] = .{ .t = k.t, .color = k.color };
    return .{
        .capacity = r.capacity,
        .rate = r.rate,
        .bursts = bursts[0..r.burst_count],
        .duration = r.duration,
        .loop = r.loop,
        .lifetime = .{ .min = r.lifetime.min, .max = r.lifetime.max },
        .shape = .{
            .kind = std.meta.stringToEnum(particles.ShapeKind, @tagName(r.shape.kind)).?,
            .radius = r.shape.radius,
            .angle = r.shape.angle,
            .extent = r.shape.extent,
            .surface = r.shape.surface,
        },
        .speed = .{ .min = r.speed.min, .max = r.speed.max },
        .acceleration = r.acceleration,
        .drag = r.drag,
        .size = .{ .min = r.size.min, .max = r.size.max },
        .size_over_life = sizes[0..r.size_key_count],
        .rotation = .{ .min = r.rotation.min, .max = r.rotation.max },
        .spin = .{ .min = r.spin.min, .max = r.spin.max },
        .color_over_life = colors[0..r.color_key_count],
        .additive = r.additive,
        .facing = std.meta.stringToEnum(particles.Facing, @tagName(r.facing)).?,
        .stretch = r.stretch,
        .space = std.meta.stringToEnum(particles.Space, @tagName(r.space)).?,
        .sheet = .{ .columns = r.sheet.columns, .rows = r.sheet.rows, .frames = r.sheet.frames, .fps = r.sheet.fps },
        .seed = r.seed,
    };
}

/// Both validators' verdicts on one record, as error names ("" for accepted).
fn verdicts(r: *const Record) [2][]const u8 {
    var bursts: [particles.max_bursts]particles.Burst = undefined;
    var sizes: [particles.max_curve_keys]particles.Key = undefined;
    var colors: [particles.max_curve_keys]particles.ColorKey = undefined;
    const e = convert(r, &bursts, &sizes, &colors);
    const ours: []const u8 = if (r.validate()) "" else |err| @errorName(err);
    const theirs: []const u8 = if (e.validate()) "" else |err| @errorName(err);
    return .{ ours, theirs };
}

fn expectAgree(r: *const Record) !void {
    const v = verdicts(r);
    if (!std.mem.eql(u8, v[0], v[1])) {
        std.debug.print("record says '{s}', simulation says '{s}'\n", .{ v[0], v[1] });
        return error.TestExpectedEqual;
    }
}

test "the record's limits are the simulation's" {
    const e = particles.emitter;
    const r = asset.particle_emitter;
    try testing.expectEqual(e.max_capacity, r.max_capacity);
    try testing.expectEqual(e.max_curve_keys, r.max_curve_keys);
    try testing.expectEqual(e.max_bursts, r.max_bursts);
    try testing.expectEqual(e.max_sheet_side, r.max_sheet_side);
    try testing.expectEqual(e.max_sheet_frames, r.max_sheet_frames);
    inline for (.{ "max_rate", "max_seconds", "min_duration", "max_distance", "max_speed", "max_acceleration", "max_drag", "max_angle", "max_spin", "max_factor", "max_stretch", "max_fps" }) |name| {
        try testing.expectEqual(@field(e, name), @field(r, name));
    }
    // And the refusals have the same names: every record refusal is a simulation one.
    inline for (@typeInfo(asset.particle_emitter.Refusal).error_set.?) |err| {
        try testing.expectEqualStrings(err.name, @errorName(@field(particles.Error, err.name)));
    }
}

test "a record that names only its material converts to the simulation's default emitter" {
    const record: Record = .{ .material = core.ContentId.fromString("t:m") };
    var bursts: [particles.max_bursts]particles.Burst = undefined;
    var sizes: [particles.max_curve_keys]particles.Key = undefined;
    var colors: [particles.max_curve_keys]particles.ColorKey = undefined;
    const converted = convert(&record, &bursts, &sizes, &colors);
    const default: particles.Emitter = .{};
    inline for (@typeInfo(particles.Emitter).@"struct".fields) |field| {
        const a = @field(converted, field.name);
        const b = @field(default, field.name);
        switch (@typeInfo(field.type)) {
            .pointer => try testing.expectEqual(b.len, a.len),
            else => try testing.expectEqual(b, a),
        }
    }
}

test "both refuse, and accept, the same records at every boundary" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const base: Record = .{ .material = core.ContentId.fromString("t:m") };
    try expectAgree(&base);

    // Every scalar field at and around its bounds, and at the values that are not numbers.
    const probes = [_]f32{ -inf, -20_000, -1, -0.0005, 0, 0.0005, 0.001, 0.5, 1, 1.5, 3.2, 1000, 1001, 3600, 3601, 10_000, 10_001, 100_000, 100_001, inf, nan };
    inline for (.{ "rate", "duration", "drag", "additive", "stretch" }) |name| {
        for (probes) |p| {
            var r = base;
            @field(r, name) = p;
            try expectAgree(&r);
        }
    }
    inline for (.{ "lifetime", "speed", "size", "rotation", "spin" }) |name| {
        for (probes) |lo| for ([_]f32{ -1, 0, 0.5, 1, 2, 10_001, nan }) |hi| {
            var r = base;
            @field(r, name) = .{ .min = lo, .max = hi };
            try expectAgree(&r);
        };
    }
    for (probes) |p| {
        var r = base;
        r.shape.radius = p;
        try expectAgree(&r);
        r = base;
        r.shape.angle = p;
        try expectAgree(&r);
        r = base;
        r.shape.extent = .{ 0, p, 0 };
        try expectAgree(&r);
        r = base;
        r.acceleration = .{ p, 0, 0 };
        try expectAgree(&r);
        r = base;
        r.sheet.fps = p;
        try expectAgree(&r);
    }
    for ([_]u32{ 0, 1, 64, 16_384, 16_385 }) |c| {
        var r = base;
        r.capacity = c;
        try expectAgree(&r);
    }
    for ([_][3]u32{ .{ 0, 1, 1 }, .{ 1, 0, 1 }, .{ 2, 2, 4 }, .{ 2, 2, 5 }, .{ 64, 64, 4096 }, .{ 64, 64, 4097 }, .{ 65, 1, 1 }, .{ 1, 1, 0 } }) |s| {
        var r = base;
        r.sheet = .{ .columns = s[0], .rows = s[1], .frames = s[2] };
        try expectAgree(&r);
    }
    // Bursts: times against the loop, counts against the store.
    for ([_]f32{ -0.1, 0, 0.99, 1, nan }) |time| for ([_]u32{ 0, 1, 16_384, 16_385 }) |count| {
        var r = base;
        r.burst_buffer[0] = .{ .time = time, .count = count };
        r.burst_count = 1;
        try expectAgree(&r);
    };
    // Curves: key counts, order, ends and values.
    const shapes = [_][]const [2]f32{
        &.{.{ 0, 1 }},
        &.{ .{ 0, 1 }, .{ 1, 1 } },
        &.{ .{ 0.1, 1 }, .{ 1, 1 } },
        &.{ .{ 0, 1 }, .{ 0.9, 1 } },
        &.{ .{ 0, 1 }, .{ 0.5, 1 }, .{ 0.5, 1 }, .{ 1, 1 } },
        &.{ .{ 0, -1 }, .{ 1, 1 } },
        &.{ .{ 0, 10_001 }, .{ 1, 1 } },
        &.{ .{ 0, 1 }, .{ nan, 1 }, .{ 1, 1 } },
        &.{ .{ 0, 1 }, .{ 0.1, 1 }, .{ 0.2, 1 }, .{ 0.3, 1 }, .{ 0.4, 1 }, .{ 0.5, 1 }, .{ 0.6, 1 }, .{ 1, 1 } },
    };
    for (shapes) |keys| {
        var r = base;
        for (keys, 0..) |k, i| r.size_key_buffer[i] = .{ .t = k[0], .value = k[1] };
        r.size_key_count = @intCast(keys.len);
        try expectAgree(&r);
        r = base;
        for (keys, 0..) |k, i| r.color_key_buffer[i] = .{ .t = k[0], .color = .{ k[1], 1, 1, @min(1, @abs(k[1])) } };
        r.color_key_count = @intCast(keys.len);
        try expectAgree(&r);
    }
    for ([_]f32{ -0.1, 0, 1, 1.1, nan }) |alpha| {
        var r = base;
        r.color_key_buffer[0] = .{ .t = 0, .color = .{ 1, 1, 1, alpha } };
        r.color_key_buffer[1] = .{ .t = 1, .color = .{ 1, 1, 1, 1 } };
        r.color_key_count = 2;
        try expectAgree(&r);
    }
}
