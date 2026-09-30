//! Character scenarios from collision3d.md §11.2 and same-process replay (§11.3).
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const Vec3 = core.math.Vec3;
const t = std.testing;
const gpa = t.allocator;
const config: p.CharacterConfig = .{ .radius = 0.3, .height = 1.8, .max_slope = std.math.pi / 4.0, .step_height = 0.35, .snap_distance = 0.3, .max_move = 10 };

fn box(w: *p.World, at: Vec3, half: Vec3) !p.BodyHandle {
    return w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = half } }, .pose = .at(at) });
}
fn floor(w: *p.World) !p.BodyHandle {
    return box(w, .init(0, -0.5, 0), .init(20, 0.5, 20));
}
fn mesh(w: *p.World, pts: []const Vec3, indices: []const u32) !p.BodyHandle {
    return w.addBody(gpa, .{ .shape = .{ .mesh = try w.addMesh(gpa, pts, indices) } });
}
fn ramp(w: *p.World, degrees: f32) !p.BodyHandle {
    const rise = @tan(degrees * std.math.pi / 180.0) * 8;
    return mesh(w, &.{ .init(0, 0, -4), .init(8, rise, -4), .init(8, rise, 4), .init(0, 0, 4) }, &.{ 0, 2, 1, 0, 3, 2 });
}
fn stepMesh(w: *p.World, left: f32, right: f32, height: f32) !p.BodyHandle {
    return mesh(w, &.{ .init(left, 0, -2), .init(left, height, -2), .init(left, height, 2), .init(left, 0, 2), .init(right, height, -2), .init(right, height, 2) }, &.{ 0, 1, 2, 0, 2, 3, 1, 4, 5, 1, 5, 2 });
}
fn move(w: *p.World, c: p.CharacterHandle, by: Vec3) !p.CharacterMove {
    return (try w.moveCharacter(gpa, c, by, &.{})).?;
}
fn standing(w: *p.World, feet: Vec3) !p.CharacterHandle {
    const c = try w.addCharacter(gpa, config, feet, 19);
    const r = try move(w, c, .zero);
    try t.expect(r.grounded and !r.stuck);
    return c;
}

test "character slope limit: walks up 30 degrees grounded, never climbs 50 degrees" {
    for ([_]f32{ 30, 50 }) |degrees| {
        var w: p.World = .empty;
        defer w.deinit(gpa);
        _ = try floor(&w);
        _ = try ramp(&w, degrees);
        const c = try standing(&w, .init(-0.7, p.contact_skin, 0));
        var r: p.CharacterMove = undefined;
        for (0..600) |_| {
            r = try move(&w, c, .init(0.01, -0.003, 0));
            try t.expect(!r.stuck);
            if (degrees == 30) try t.expect(r.grounded);
        }
        if (degrees == 30) {
            // Projection onto the true plane shortens horizontal distance uphill.
            try t.expect(r.feet.x > 3 and r.feet.y > 1.7);
        } else {
            try t.expect(r.feet.y <= 2 * p.contact_skin);
        }
    }
}

test "character slope limit: falls onto steep mesh and slides down instead of hanging" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try ramp(&w, 50);
    const c = try w.addCharacter(gpa, config, .init(3, 5, 0), 0);
    var r: p.CharacterMove = undefined;
    var touched = false;
    for (0..120) |_| {
        r = try move(&w, c, .init(0, -0.05, 0));
        touched = touched or r.walls > 0;
        try t.expect(!r.stuck and !r.grounded);
    }
    try t.expect(touched and r.feet.x < 2 and r.feet.y < 2);
}

test "character step: climbs 15 and 30 cm but refuses 40 cm" {
    for ([_]bool{ false, true }) |is_mesh| {
        for ([_]f32{ 0.15, 0.30, 0.40 }) |height| {
            var w: p.World = .empty;
            defer w.deinit(gpa);
            _ = try floor(&w);
            if (is_mesh) {
                _ = try stepMesh(&w, 0, 3, height);
            } else _ = try box(&w, .init(1.5, height * 0.5, 0), .init(1.5, height * 0.5, 2));
            const c = try standing(&w, .init(-0.65, p.contact_skin, 0));
            var stepped: f32 = 0;
            var previous_y: f32 = p.contact_skin;
            var r: p.CharacterMove = undefined;
            for (0..100) |_| {
                r = try move(&w, c, .init(0.02, -0.005, 0));
                stepped += r.stepped;
                if (r.stepped > 0) try t.expectApproxEqAbs(r.feet.y - previous_y, r.stepped, p.contact_skin);
                previous_y = r.feet.y;
                try t.expect(!r.stuck and r.grounded);
            }
            if (height < config.step_height) {
                // A box's rounded corner may finish the ascent by ordinary walkable slide.
                try t.expect(stepped > 0 and stepped <= height + p.contact_skin);
                try t.expectApproxEqAbs(height + p.contact_skin, r.feet.y, p.contact_skin);
                try t.expect(r.feet.x > 1);
            } else {
                try t.expectEqual(@as(f32, 0), stepped);
                try t.expect(r.feet.x < 0 and r.feet.y <= 2 * p.contact_skin);
            }
        }
    }
}

test "character stair edge: ground uses face normal rather than tilted contact normal" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const b = try mesh(&w, &.{ .init(-2, 0, 0), .init(2, 0, 0), .init(2, 0, 4), .init(-2, 0, 4) }, &.{ 0, 2, 1, 0, 3, 2 });
    // Overhang puts the contact normal below the 45-degree threshold, but the tread is flat.
    const c = try w.addCharacter(gpa, config, .init(0, -0.114, -0.24), 0);
    const r = try move(&w, c, .zero);
    try t.expect(r.grounded and r.ground.?.body.eql(b));
    try t.expectApproxEqAbs(@as(f32, 1), r.ground.?.surface_normal.y, 1e-5);
}

test "character snap-down: descending stairs stays grounded and jumping never snaps or steps" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    _ = try stepMesh(&w, -2, 0, 0.45);
    _ = try stepMesh(&w, 0, 1, 0.30);
    _ = try stepMesh(&w, 1, 2, 0.15);
    const c = try standing(&w, .init(-0.8, 0.45 + p.contact_skin, 0));
    var snaps: u32 = 0;
    for (0..180) |_| {
        const r = try move(&w, c, .init(0.02, -0.001, 0));
        try t.expect(r.grounded and !r.stuck);
        if (r.snapped) snaps += 1;
    }
    try t.expect(snaps > 0);
    const jump = try move(&w, c, .init(0.02, 0.2, 0));
    try t.expect(!jump.grounded and !jump.snapped and jump.stepped == 0);
}

test "character snap-down: a 25 degree ramp remains grounded every tick" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try ramp(&w, 25);
    // Capsule rests a skin away along the slope normal, not vertically.
    const angle = 25 * std.math.pi / 180.0;
    const y = @tan(angle) * 5 + (config.radius + p.contact_skin) / @cos(angle) - config.radius;
    const c = try standing(&w, .init(5, y, 0));
    var snaps: u32 = 0;
    for (0..150) |_| {
        const r = try move(&w, c, .init(-0.02, -0.001, 0));
        try t.expect(r.grounded and !r.stuck);
        if (r.snapped) snaps += 1;
    }
    try t.expect(snaps > 0);
}

test "character wall slide: tangent progress and a stable corner" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    _ = try box(&w, .init(0.1, 2, 0), .init(0.1, 2, 10));
    _ = try box(&w, .init(-5, 2, 4.1), .init(5, 2, 0.1));
    const c = try standing(&w, .init(-0.31, p.contact_skin, 0));
    const by = Vec3.init(0.01, -0.002, 0.017320508);
    var r: p.CharacterMove = undefined;
    for (0..120) |_| r = try move(&w, c, by);
    try t.expect(r.feet.z >= 0.8 * by.z * 120 and r.feet.x < -0.3);
    for (0..200) |_| r = try move(&w, c, by);
    const end = r.feet;
    for (0..60) |_| {
        r = try move(&w, c, by);
        try t.expectApproxEqAbs(end.x, r.feet.x, 0.0001);
        try t.expectApproxEqAbs(end.z, r.feet.z, 0.0001);
        try t.expect(!r.stuck);
    }
}

test "character ceiling: upward motion ends a skin below a low ceiling" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try box(&w, .init(0, 2.1, 0), .init(5, 0.1, 5));
    const c = try w.addCharacter(gpa, config, .zero, 0);
    var hits: [1]p.Hit = undefined;
    const r = (try w.moveCharacter(gpa, c, .init(0, 1, 0), &hits)).?;
    try t.expect(r.ceiling and !r.grounded);
    try t.expectApproxEqAbs(2 - config.height - p.contact_skin, r.feet.y, 1e-4);
    try t.expect(r.hit_count == 1 and r.total_hits >= r.hit_count);
}

test "character depenetration: box and mesh teleport, sealed room reports stuck" {
    for ([_]bool{ false, true }) |is_mesh| {
        var w: p.World = .empty;
        defer w.deinit(gpa);
        if (is_mesh) {
            _ = try mesh(&w, &.{ .init(0, -3, -3), .init(0, 4, -3), .init(0, 4, 3), .init(0, -3, 3) }, &.{ 0, 1, 2, 0, 2, 3 });
        } else _ = try box(&w, .init(0.5, 1, 0), .init(0.5, 2, 3));
        const c = try w.addCharacter(gpa, config, .init(-1, 0, 0), 0);
        try t.expect(try w.setCharacterFeet(gpa, c, .init(-0.15, 0, 0)));
        const r = try move(&w, c, .zero);
        try t.expect(r.depenetrated and !r.stuck and r.feet.x <= -0.3);
    }
    var w: p.World = .empty;
    defer w.deinit(gpa);
    // A cavity narrower than the capsule forces alternating deepest contacts.
    _ = try box(&w, .init(-0.6, 1, 0), .init(0.5, 4, 4));
    _ = try box(&w, .init(0.6, 1, 0), .init(0.5, 4, 4));
    _ = try box(&w, .init(0, -1, 0), .init(4, 1, 4));
    _ = try box(&w, .init(0, 3, 0), .init(4, 1, 4));
    const c = try w.addCharacter(gpa, config, .zero, 0);
    const r = try move(&w, c, .init(0, 0, 1));
    try t.expect(r.stuck and r.depenetrated and r.feet.z == 0 and r.total_hits == 0);
}

test "character tunnelling: max_move stops at thin box and two-sided mesh both ways" {
    for ([_]bool{ false, true }) |is_mesh| {
        var w: p.World = .empty;
        defer w.deinit(gpa);
        if (is_mesh) {
            _ = try mesh(&w, &.{ .init(0, -3, -3), .init(0, 4, -3), .init(0, 4, 3), .init(0, -3, 3) }, &.{ 0, 1, 2, 0, 2, 3 });
        } else _ = try box(&w, .init(0, 1, 0), .init(0.005, 3, 3));
        for ([_]f32{ -1, 1 }) |side| {
            const c = try w.addCharacter(gpa, config, .init(5 * side, 0, 0), 0);
            const r = try move(&w, c, .init(-config.max_move * side, 0, 0));
            try t.expect(r.feet.x * side >= config.radius and !r.stuck);
            try t.expect(w.removeCharacter(gpa, c));
        }
    }
}

test "characters block without pushing, pair filters are symmetric and hits report truncation" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const a = try w.addCharacter(gpa, config, .init(-2, 0, 0), 1);
    const b = try w.addCharacter(gpa, config, .zero, 2);
    const body = w.body(w.character(b).?.body).?.*;
    const r = try move(&w, a, .init(4, 0, 0));
    try t.expect(r.feet.x < -0.6 and r.hit_count == 0 and r.total_hits > 0);
    try t.expectEqualDeep(body, w.body(w.character(b).?.body).?.*);
    try t.expect(w.setFilter(w.character(b).?.body, 1, 0));
    const pass = try move(&w, a, .init(2, 0, 0));
    try t.expect(pass.feet.x > 1 and pass.total_hits == 0);
}

test "character refusals: each config bound, nonfinite fields and moves leave body unchanged" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    inline for (.{ "radius", "height", "max_slope", "step_height", "snap_distance", "max_move" }) |field| {
        for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -1 }) |bad| {
            var cfg = config;
            @field(cfg, field) = bad;
            try t.expectError(error.InvalidCharacter, w.addCharacter(gpa, cfg, .zero, 0));
        }
    }
    for ([_]p.CharacterConfig{
        blk: {
            var c = config;
            c.radius = 0;
            break :blk c;
        },
        blk: {
            var c = config;
            c.height = 0.5;
            break :blk c;
        },
        blk: {
            var c = config;
            c.max_slope = 0;
            break :blk c;
        },
        blk: {
            var c = config;
            c.max_slope = std.math.pi / 2.0;
            break :blk c;
        },
        blk: {
            var c = config;
            c.step_height = 1.3;
            break :blk c;
        },
        blk: {
            var c = config;
            c.snap_distance = 1.9;
            break :blk c;
        },
        blk: {
            var c = config;
            c.max_move = 0;
            break :blk c;
        },
    }) |cfg| try t.expectError(error.InvalidCharacter, w.addCharacter(gpa, cfg, .zero, 0));
    try t.expectEqual(@as(u32, 0), w.bodyCount());
    const c = try w.addCharacter(gpa, config, .zero, 0);
    const before = w.body(w.character(c).?.body).?.*;
    for ([_]Vec3{ .init(std.math.nan(f32), 0, 0), .init(0, std.math.inf(f32), 0), .init(10.01, 0, 0), .init(8, 8, 0), .init(std.math.floatMax(f32), 0, 0) }) |by| {
        try t.expectError(error.InvalidMove, w.moveCharacter(gpa, c, by, &.{}));
        try t.expectEqualDeep(before, w.body(w.character(c).?.body).?.*);
    }
    try t.expectError(error.InvalidPose, w.setCharacterFeet(gpa, c, .init(0, 8192, 0)));
    try t.expectError(error.InvalidPose, w.setCharacterFeet(gpa, c, .init(0, -8192.5, 0)));
    try t.expectError(error.InvalidPose, w.addCharacter(gpa, config, .init(std.math.nan(f32), 0, 0), 0));
    try t.expectEqualDeep(before, w.body(w.character(c).?.body).?.*);
}

test "character lifecycle: clears ground on teleport, stale generations, allocation failures" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    const c = try standing(&w, .init(0, p.contact_skin, 0));
    try t.expect(w.character(c).?.ground != null);
    try t.expect(try w.setCharacterFeet(gpa, c, .init(0, 3, 0)));
    try t.expect(w.character(c).?.ground == null);
    const b = w.character(c).?.body;
    try t.expect(w.removeCharacter(gpa, c));
    try t.expect(w.body(b) == null and w.character(c) == null);
    const replacement = try w.addCharacter(gpa, config, .zero, 0);
    try t.expect(!replacement.eql(c));
    try t.expect(try w.moveCharacter(gpa, c, .zero, &.{}) == null);
    try t.expect(!try w.setCharacterFeet(gpa, c, .zero));
    try t.expect(!w.removeCharacter(gpa, c));
    try t.checkAllAllocationFailures(gpa, allocationCase, .{});
}
test "character moves allocate nothing and refuse coordinate escape transactionally" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    const c = try standing(&w, .init(0, p.contact_skin, 0));
    var failing = t.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const r = (try w.moveCharacter(failing.allocator(), c, .init(0.1, -0.003, 0), &.{})).?;
    try t.expect(r.grounded and r.feet.x > 0.09);
    try t.expect(try w.setCharacterFeet(gpa, c, .init(8191, 0, 0)));
    const before = w.body(w.character(c).?.body).?.*;
    try t.expectError(error.InvalidMove, w.moveCharacter(gpa, c, .init(2, 0, 0), &.{}));
    try t.expectEqualDeep(before, w.body(w.character(c).?.body).?.*);
    // Exact boundary config: a zero-segment capsule, no step and no snap is valid.
    var sphere = config;
    sphere.height = 2 * sphere.radius;
    sphere.step_height = 0;
    sphere.snap_distance = 0;
    _ = try w.addCharacter(gpa, sphere, .zero, 0);
}

test "character landing probe never selects a hidden floor beyond an earlier wall" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try floor(&w);
    const steep = try mesh(&w, &.{ .init(0, 0, -4), .init(8, 8, -4), .init(8, 8, 4), .init(0, 0, 4) }, &.{ 0, 2, 1, 0, 3, 2 });
    var cfg = config;
    cfg.max_slope = std.math.pi / 6.0;
    const c = try w.addCharacter(gpa, cfg, .init(1, 1.2, 0), 0);
    const r = try move(&w, c, .zero);
    try t.expect(!r.grounded);
    const capsule: p.shape.Convex = .{ .core = .{ .segment = 0.6 }, .radius = 0.3, .pose = .at(.init(1, 3.9, 0)) };
    const h = w.characterProbe(capsule, .init(0, -5, 0), w.character(c).?.body, @cos(cfg.max_slope)).?;
    try t.expect(h.body.eql(steep) and h.surface_normal.y < @cos(cfg.max_slope));
}

test "character box grounding needs a witness on the walkable face, not merely a face above" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const rotation = core.math.Quat.fromAxisAngle(.init(0, 0, 1), 25 * std.math.pi / 180.0);
    _ = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(1, 3, 3) } }, .pose = .{ .rotation = rotation } });
    const lower_core = rotation.rotate(.init(1 + config.radius + p.contact_skin, 1, 0));
    const c = try w.addCharacter(gpa, config, lower_core.sub(.init(0, config.radius, 0)), 0);
    const capsule: p.shape.Convex = .{ .core = .{ .segment = 0.6 }, .radius = 0.3, .pose = w.body(w.character(c).?.body).?.pose };
    const h = w.characterProbe(capsule, .init(0, -0.01, 0), w.character(c).?.body, @cos(config.max_slope)).?;
    try t.expect(h.surface_normal.y < @cos(config.max_slope));
    const r = try move(&w, c, .zero);
    try t.expect(!r.grounded and !r.stuck);
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var w: p.World = .empty;
    defer w.deinit(allocator);
    _ = try w.addCharacter(allocator, config, .zero, 0);
}

fn replay(out: *[1200]Vec3) !u64 {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try mesh(&w, &.{ .init(-10, 0, -10), .init(10, 0, -10), .init(10, 0, 10), .init(-10, 0, 10), .init(0, 0, -2), .init(4, 2, -2), .init(4, 2, 2), .init(0, 0, 2) }, &.{ 0, 2, 1, 0, 3, 2, 4, 6, 5, 4, 7, 6 });
    _ = try stepMesh(&w, -1, 0, 0.30);
    _ = try box(&w, .init(5, 2, 0), .init(0.05, 2, 8));
    const c = try standing(&w, .init(-2, p.contact_skin, 0));
    for (out, 0..) |*feet, tick| {
        const by: Vec3 = switch (tick / 300) {
            0 => .init(0.02, -0.003, 0),
            1 => .init(-0.02, -0.003, 0),
            2 => .init(0.02, -0.003, 0.015),
            else => .init(-0.02, -0.003, -0.015),
        };
        const r = try move(&w, c, by);
        try t.expect(!r.stuck);
        feet.* = r.feet;
    }
    return core.id.fnv1a64(std.mem.asBytes(out));
}
test "character replay: 1200 tick mesh course has byte-identical feet and hashes" {
    var first: [1200]Vec3 = undefined;
    var second: [1200]Vec3 = undefined;
    try t.expectEqual(try replay(&first), try replay(&second));
    try t.expectEqualSlices(u8, std.mem.asBytes(&first), std.mem.asBytes(&second));
    try t.expect(first[0].sub(first[299]).length() > 1);
}
