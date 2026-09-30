//! `collision3d.md` §11.1's query and shape tests, against analytic answers.
//!
//! Each scenario is written once in a canonical frame, where its answer is obvious, and checked
//! under several rigid transforms of the whole scene: distance is invariant, and normals and
//! points move with the transform. A narrowphase that only worked axis-aligned fails here.

const std = @import("std");
const core = @import("core");

const body_mod = @import("body.zig");
const narrow = @import("narrow.zig");
const shape = @import("shape.zig");
const world_mod = @import("world.zig");

const Convex = shape.Convex;
const Pose = shape.Pose;
const Quat = core.math.Quat;
const Shape = shape.Shape;
const Vec3 = core.math.Vec3;
const World = world_mod.World;

const testing = std.testing;
const gpa = testing.allocator;

const tolerance: f32 = 1e-5;
/// EPA's answers are good to its own stopping tolerance, not GJK's.
const depth_tolerance: f32 = 1e-4;

const Frame = struct {
    rotation: Quat,
    offset: Vec3,
    /// What an `f32` resolves at this frame's distance from the origin: an ulp at 1,200 m is
    /// 1.2e-4 m, and no narrowphase answers more finely than the coordinates it is given.
    tolerance: f32 = tolerance,

    fn point(self: Frame, p: Vec3) Vec3 {
        return self.offset.add(self.rotation.rotate(p));
    }
    fn dir(self: Frame, d: Vec3) Vec3 {
        return self.rotation.rotate(d);
    }
    fn pose(self: Frame, p: Pose) Pose {
        return .{ .position = self.point(p.position), .rotation = Quat.mul(self.rotation, p.rotation).normalize() };
    }
};

const frames = [_]Frame{
    .{ .rotation = .identity, .offset = .zero },
    .{ .rotation = Quat.fromAxisAngle(.init(1, 2, 3), 0.7), .offset = .init(5, -2, 7) },
    .{ .rotation = Quat.fromAxisAngle(.init(0, 1, 0), 2.1), .offset = .init(-100, 40, 3), .tolerance = 4e-5 },
    .{ .rotation = Quat.fromAxisAngle(.init(-2, 0.5, 1), -1.9), .offset = .init(900, -300, 1200), .tolerance = 5e-4 },
};

const cube_points = [_]Vec3{
    .init(-1, -1, -1), .init(1, -1, -1), .init(-1, 1, -1), .init(1, 1, -1),
    .init(-1, -1, 1),  .init(1, -1, 1),  .init(-1, 1, 1),  .init(1, 1, 1),
};
const tetra_points = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1) };

const quarter_z = Quat{ .x = 0, .y = 0, .z = std.math.sqrt1_2, .w = std.math.sqrt1_2 };
const eighth_y = Quat{ .x = 0, .y = 0.38268343, .z = 0, .w = 0.92387953 };

fn sphere(at: Vec3, r: f32) Convex {
    return .{ .core = .point, .radius = r, .pose = .at(at) };
}
fn capsule(pose: Pose, r: f32, h: f32) Convex {
    return .{ .core = .{ .segment = h }, .radius = r, .pose = pose };
}
fn box(pose: Pose, he: Vec3) Convex {
    return .{ .core = .{ .box = he }, .radius = 0, .pose = pose };
}
fn hull(pose: Pose, points: []const Vec3) Convex {
    return .{ .core = .{ .points = points }, .radius = 0, .pose = pose };
}

fn moved(c: Convex, f: Frame) Convex {
    var out = c;
    out.pose = f.pose(c.pose);
    return out;
}

fn expectVec(expected: Vec3, actual: Vec3, tol: f32) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tol);
    try testing.expectApproxEqAbs(expected.y, actual.y, tol);
    try testing.expectApproxEqAbs(expected.z, actual.z, tol);
}

const Case = struct {
    name: []const u8,
    a: Convex,
    b: Convex,
    distance: f32,
    /// Out of B toward A, canonical frame.
    normal: Vec3,
};

test "separation: every convex pair matches its analytic answer in rotated frames" {
    const unit_box = box(.identity, .init(1, 1, 1));
    const cube_hull = hull(.identity, &cube_points);
    const standing = capsule(.identity, 0.25, 1);
    const cases = [_]Case{
        .{ .name = "sphere-sphere", .a = sphere(.init(3, 0, 0), 0.5), .b = sphere(.zero, 1), .distance = 1.5, .normal = .init(1, 0, 0) },
        .{ .name = "sphere-capsule side", .a = sphere(.init(2, 0.3, 0), 0.5), .b = standing, .distance = 1.25, .normal = .init(1, 0, 0) },
        .{ .name = "sphere-capsule cap", .a = sphere(.init(0, 2, 0), 0.5), .b = standing, .distance = 0.25, .normal = .init(0, 1, 0) },
        .{ .name = "sphere-box face", .a = sphere(.init(2, 0.2, -0.4), 0.5), .b = unit_box, .distance = 0.5, .normal = .init(1, 0, 0) },
        .{ .name = "sphere-box corner", .a = sphere(.init(2, 2, 2), 0.5), .b = unit_box, .distance = @sqrt(3.0) - 0.5, .normal = Vec3.init(1, 1, 1).normalize() },
        .{ .name = "sphere-hull face", .a = sphere(.init(-1, 0.2, 0.2), 0.5), .b = hull(.identity, &tetra_points), .distance = 0.5, .normal = .init(-1, 0, 0) },
        .{ .name = "sphere-hull cube", .a = sphere(.init(0, -3, 0.5), 0.5), .b = cube_hull, .distance = 1.5, .normal = .init(0, -1, 0) },
        .{ .name = "capsule-capsule parallel", .a = capsule(.at(.init(1, 0.3, 0)), 0.25, 1), .b = standing, .distance = 0.5, .normal = .init(1, 0, 0) },
        .{ .name = "capsule-capsule crossed", .a = capsule(.{ .position = .init(0, 0, 2), .rotation = quarter_z }, 0.25, 1), .b = standing, .distance = 1.5, .normal = .init(0, 0, 1) },
        .{ .name = "capsule-box", .a = capsule(.{ .position = .init(0.3, 2, 0), .rotation = quarter_z }, 0.25, 0.5), .b = unit_box, .distance = 0.75, .normal = .init(0, 1, 0) },
        .{ .name = "capsule-hull", .a = capsule(.at(.init(0, 0, 3)), 0.25, 0.5), .b = cube_hull, .distance = 1.75, .normal = .init(0, 0, 1) },
        .{ .name = "box-box face", .a = box(.at(.init(3, 0.2, 0)), .init(1, 1, 1)), .b = unit_box, .distance = 1, .normal = .init(1, 0, 0) },
        .{ .name = "box-box turned", .a = box(.{ .position = .init(3.5, 0, 0), .rotation = eighth_y }, .init(1, 1, 1)), .b = unit_box, .distance = 3.5 - std.math.sqrt2 - 1, .normal = .init(1, 0, 0) },
        .{ .name = "box-hull", .a = box(.at(.init(0, 3, 0.2)), .init(0.5, 0.5, 0.5)), .b = cube_hull, .distance = 1.5, .normal = .init(0, 1, 0) },
        .{ .name = "hull-hull", .a = hull(.at(.init(-3, 0, 0)), &cube_points), .b = cube_hull, .distance = 1, .normal = .init(-1, 0, 0) },
    };
    for (cases) |c| {
        for (frames) |f| {
            const s = narrow.separation(moved(c.a, f), moved(c.b, f));
            errdefer std.debug.print("case {s}: distance {d}\n", .{ c.name, s.distance });
            try testing.expect(!s.cores_intersect);
            try testing.expectApproxEqAbs(c.distance, s.distance, f.tolerance);
            try expectVec(f.dir(c.normal), s.normal, f.tolerance * 10);
        }
    }
}

test "contacts: core-intersecting boxes and hulls go through EPA, rounded ones do not" {
    const unit_box = box(.identity, .init(1, 1, 1));
    const cases = [_]Case{
        .{ .name = "box-box", .a = box(.at(.init(1.9, 0.3, 0.1)), .init(1, 1, 1)), .b = unit_box, .distance = -0.1, .normal = .init(1, 0, 0) },
        .{ .name = "sphere deep in box", .a = sphere(.init(0, 0.8, 0), 0.5), .b = unit_box, .distance = -0.7, .normal = .init(0, 1, 0) },
        .{ .name = "hull-hull", .a = hull(.at(.init(0, 0, -1.8)), &cube_points), .b = hull(.identity, &cube_points), .distance = -0.2, .normal = .init(0, 0, -1) },
        .{ .name = "capsule through box", .a = capsule(.at(.init(0, 0.5, 1.2)), 0.3, 1), .b = unit_box, .distance = -0.1, .normal = .init(0, 0, 1) },
    };
    for (cases) |c| {
        for (frames) |f| {
            const s = narrow.separation(moved(c.a, f), moved(c.b, f));
            errdefer std.debug.print("case {s}: distance {d}\n", .{ c.name, s.distance });
            try testing.expectApproxEqAbs(c.distance, s.distance, @max(depth_tolerance, f.tolerance));
            try expectVec(f.dir(c.normal), s.normal, @max(1e-3, f.tolerance * 10));
        }
    }
    const rounded = narrow.separation(sphere(.init(0.6, 0, 0), 0.5), capsule(.identity, 0.25, 1));
    try testing.expect(!rounded.cores_intersect);
    try testing.expectApproxEqAbs(@as(f32, -0.15), rounded.distance, tolerance);
}

/// A world holding one of each convex kind, far apart on X, for the query tests.
const Scene = struct {
    world: World = .empty,
    cube: shape.HullHandle = .none,
    sphere: body_mod.BodyHandle = .none,
    capsule: body_mod.BodyHandle = .none,
    box: body_mod.BodyHandle = .none,
    hull: body_mod.BodyHandle = .none,

    fn init(f: Frame) !Scene {
        var s: Scene = .{};
        errdefer s.world.deinit(gpa);
        s.cube = try s.world.addHull(gpa, &cube_points);
        s.sphere = try s.world.addBody(gpa, .{ .shape = .{ .sphere = .{ .radius = 1 } }, .pose = f.pose(.at(.init(0, 0, 0))), .user = 1 });
        s.capsule = try s.world.addBody(gpa, .{ .shape = .{ .capsule = .{ .radius = 0.5, .half_height = 1 } }, .pose = f.pose(.at(.init(10, 0, 0))), .user = 2 });
        s.box = try s.world.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(1, 1, 1) } }, .pose = f.pose(.at(.init(20, 0, 0))), .user = 3 });
        s.hull = try s.world.addBody(gpa, .{ .shape = .{ .hull = s.cube }, .pose = f.pose(.at(.init(30, 0, 0))), .user = 4 });
        return s;
    }
};

test "raycast: each kind at its analytic distance, in rotated frames" {
    for (frames) |f| {
        var s = try Scene.init(f);
        defer s.world.deinit(gpa);
        const rays = [_]struct { x: f32, y: f32, distance: f32, user: u64 }{
            .{ .x = 0, .y = 0, .distance = 4, .user = 1 },
            .{ .x = 10, .y = 0.5, .distance = 4.5, .user = 2 },
            .{ .x = 20, .y = 0.2, .distance = 4, .user = 3 },
            .{ .x = 30, .y = -0.7, .distance = 4, .user = 4 },
        };
        for (rays) |r| {
            const side = (try s.world.raycast(f.point(.init(r.x, r.y, -5)), f.dir(.init(0, 0, 1)), 10, .{})).?;
            try testing.expectEqual(r.user, side.user);
            try testing.expectApproxEqAbs(r.distance, side.distance, f.tolerance);
            try expectVec(f.dir(.init(0, 0, -1)), side.normal, f.tolerance * 10);
            try testing.expect(!side.started_inside);
        }
        try testing.expect((try s.world.raycast(f.point(.init(5, 0, -5)), f.dir(.init(0, 0, 1)), 10, .{})) == null);
        const inside = (try s.world.raycast(f.point(.zero), f.dir(.init(1, 0, 0)), 1, .{})).?;
        try testing.expect(inside.started_inside);
        try testing.expectEqual(@as(f32, 0), inside.distance);
    }
}

test "shapeCast: a sphere into a box face stops a skin short, with the face as surface normal" {
    for (frames) |f| {
        var s = try Scene.init(f);
        defer s.world.deinit(gpa);
        const probe: Shape = .{ .sphere = .{ .radius = 0.5 } };
        const hit = (try s.world.shapeCast(probe, f.pose(.at(.init(20, 0.3, -5))), f.dir(.init(0, 0, 10)), .{})).?;
        try testing.expect(hit.body.eql(s.box));
        try testing.expectApproxEqAbs((3.5 - narrow.contact_skin) / 10, hit.fraction, f.tolerance);
        try expectVec(f.dir(.init(0, 0, -1)), hit.normal, f.tolerance * 10);
        try expectVec(f.dir(.init(0, 0, -1)), hit.surface_normal, 1e-4);
        try expectVec(f.point(.init(20, 0.3, -1)), hit.point, @max(1e-3, f.tolerance * 10));
    }
}

test "shapeCast: an edge contact tilts the normal but the surface normal stays the face" {
    var s = try Scene.init(frames[0]);
    defer s.world.deinit(gpa);
    // A sphere sliding off the box's top edge toward +X, dropping onto the corner region.
    const hit = (try s.world.shapeCast(.{ .sphere = .{ .radius = 0.5 } }, .at(.init(21.3, 1.3, 0)), .init(0, -2, 0), .{})).?;
    try testing.expect(hit.body.eql(s.box));
    try testing.expect(hit.normal.x > 0.1 and hit.normal.y > 0.1);
    try testing.expect(hit.surface_normal.eql(.init(0, 1, 0)) or hit.surface_normal.eql(.init(1, 0, 0)));
    // Exactly diagonal: the tie goes to the lowest axis.
    const box_convex = box(.at(.init(20, 0, 0)), .init(1, 1, 1));
    try testing.expect(box_convex.surfaceNormal(Vec3.init(1, 1, 0).normalize()).eql(.init(1, 0, 0)));
}

test "shapeCast: capsules, boxes and hulls cast too, and nothing passes a thin plate" {
    for (frames) |f| {
        var s = try Scene.init(f);
        defer s.world.deinit(gpa);
        const cap = (try s.world.shapeCast(.{ .capsule = .{ .radius = 0.25, .half_height = 0.5 } }, f.pose(.at(.init(30, 0, 6))), f.dir(.init(0, 0, -10)), .{})).?;
        try testing.expect(cap.body.eql(s.hull));
        try testing.expectApproxEqAbs((4.75 - narrow.contact_skin) / 10, cap.fraction, f.tolerance);
        const bx = (try s.world.shapeCast(.{ .box = .{ .half_extents = .init(0.5, 0.5, 0.5) } }, f.pose(.at(.init(10, 5, 0))), f.dir(.init(0, -10, 0)), .{})).?;
        try testing.expect(bx.body.eql(s.capsule));
        try testing.expectApproxEqAbs((5 - 1.5 - 0.5 - narrow.contact_skin) / 10, bx.fraction, f.tolerance);
        const hl = (try s.world.shapeCast(.{ .hull = s.cube }, f.pose(.at(.init(0, 0, -8))), f.dir(.init(0, 0, 10)), .{})).?;
        try testing.expect(hl.body.eql(s.sphere));
        try testing.expectApproxEqAbs((6 - narrow.contact_skin) / 10, hl.fraction, f.tolerance);
    }
    var w: World = .empty;
    defer w.deinit(gpa);
    _ = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(0.005, 3, 3) } } });
    for ([_]f32{ -1, 1 }) |side| {
        const hit = (try w.shapeCast(.{ .capsule = .{ .radius = 0.3, .half_height = 0.6 } }, .at(.init(-40 * side, 0, 0)), .init(80 * side, 0, 0), .{})).?;
        const stop = -40 * side + 80 * side * hit.fraction;
        try testing.expect(stop * side < -0.3);
    }
}

test "overlap and contacts: handle order, and a short buffer reports the total" {
    var w: World = .empty;
    defer w.deinit(gpa);
    var handles: [3]body_mod.BodyHandle = undefined;
    for (&handles, 0..) |*h, i| {
        h.* = try w.addBody(gpa, .{ .shape = .{ .sphere = .{ .radius = 1 } }, .pose = .at(.init(@floatFromInt(i), 0, 0)), .user = i });
    }
    _ = try w.addBody(gpa, .{ .shape = .{ .sphere = .{ .radius = 1 } }, .pose = .at(.init(50, 0, 0)) });
    var out: [2]world_mod.Overlap = undefined;
    const found = try w.overlap(.{ .box = .{ .half_extents = .init(2, 0.5, 0.5) } }, .at(.init(1, 0, 0)), .{}, &out);
    try testing.expectEqual(@as(u32, 2), found.count);
    try testing.expectEqual(@as(u32, 3), found.total);
    try testing.expect(out[0].body.eql(handles[0]) and out[1].body.eql(handles[1]));

    var cs: [4]world_mod.Contact = undefined;
    const got = try w.contacts(.{ .sphere = .{ .radius = 0.5 } }, .at(.init(0, 1.3, 0)), .{}, &cs);
    try testing.expectEqual(@as(u32, 1), got.total);
    try testing.expect(cs[0].body.eql(handles[0]));
    try testing.expectApproxEqAbs(@as(f32, 0.2), cs[0].depth, tolerance);
    try expectVec(.init(0, 1, 0), cs[0].normal, tolerance);
    // Touching is not overlapping.
    try testing.expectEqual(@as(u32, 0), (try w.overlap(.{ .sphere = .{ .radius = 1 } }, .at(.init(0, 2, 0)), .{}, &out)).total);
}

test "ties go to the lower handle index" {
    var w: World = .empty;
    defer w.deinit(gpa);
    const wall: body_mod.Body = .{ .shape = .{ .box = .{ .half_extents = .init(0.5, 2, 2) } }, .pose = .at(.init(3, 0, 0)) };
    const first = try w.addBody(gpa, wall);
    const second = try w.addBody(gpa, wall);
    const probe: Shape = .{ .sphere = .{ .radius = 0.5 } };
    const hit = (try w.shapeCast(probe, .identity, .init(10, 0, 0), .{})).?;
    try testing.expect(hit.body.eql(first));
    // The slot is reused with a new generation; its index still sorts first.
    _ = w.removeBody(gpa, first);
    const reused = try w.addBody(gpa, wall);
    try testing.expect(!reused.eql(first));
    const again = (try w.shapeCast(probe, .identity, .init(10, 0, 0), .{})).?;
    try testing.expect(again.body.eql(reused));
    try testing.expect(!again.body.eql(second));
    const ray = (try w.raycast(.zero, .init(1, 0, 0), 10, .{})).?;
    try testing.expect(ray.body.eql(reused));
}

test "filters: a query mask, an ignored body, and a trigger as a layer" {
    var w: World = .empty;
    defer w.deinit(gpa);
    const solid = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(0.5, 2, 2) } }, .pose = .at(.init(3, 0, 0)), .layer = 0b01 });
    const trigger = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(0.5, 2, 2) } }, .pose = .at(.init(1.5, 0, 0)), .layer = 0b10 });
    const probe: Shape = .{ .sphere = .{ .radius = 0.25 } };
    // A character-like mask that omits the trigger's layer passes through it to the wall.
    const through = (try w.shapeCast(probe, .identity, .init(10, 0, 0), .{ .mask = 0b01 })).?;
    try testing.expect(through.body.eql(solid));
    // An overlap that asks for the trigger's layer finds it.
    var out: [2]world_mod.Overlap = undefined;
    const inside = try w.overlap(probe, .at(.init(1.5, 0, 0)), .{ .mask = 0b10 }, &out);
    try testing.expectEqual(@as(u32, 1), inside.total);
    try testing.expect(out[0].body.eql(trigger));
    const ignored = (try w.shapeCast(probe, .identity, .init(10, 0, 0), .{ .ignore = trigger })).?;
    try testing.expect(ignored.body.eql(solid));
    try testing.expect((try w.shapeCast(probe, .identity, .init(10, 0, 0), .{ .mask = 0b100 })) == null);
}

test "refusals: shapes, poses, hulls and queries, each by name" {
    var w: World = .empty;
    defer w.deinit(gpa);
    const bad_shapes = [_]Shape{
        .{ .sphere = .{ .radius = 0 } },
        .{ .sphere = .{ .radius = -1 } },
        .{ .sphere = .{ .radius = std.math.nan(f32) } },
        .{ .capsule = .{ .radius = 0.3, .half_height = -0.1 } },
        .{ .box = .{ .half_extents = .init(1, std.math.inf(f32), 1) } },
        .{ .hull = .none },
    };
    for (bad_shapes) |s| {
        try testing.expectError(error.InvalidShape, w.addBody(gpa, .{ .shape = s }));
        try testing.expectError(error.InvalidShape, w.shapeCast(s, .identity, .init(1, 0, 0), .{}));
    }
    const ok: Shape = .{ .sphere = .{ .radius = 1 } };
    try testing.expectError(error.InvalidPose, w.addBody(gpa, .{ .shape = ok, .pose = .at(.init(9000, 0, 0)) }));
    try testing.expectError(error.InvalidPose, w.addBody(gpa, .{ .shape = ok, .pose = .{ .rotation = .{ .x = 0.5, .y = 0, .z = 0, .w = 0.5 } } }));
    try testing.expectError(error.InvalidPose, w.addBody(gpa, .{ .shape = ok, .pose = .at(.init(std.math.nan(f32), 0, 0)) }));

    try testing.expectError(error.InvalidShape, w.addHull(gpa, cube_points[0..3]));
    var many: [257]Vec3 = undefined;
    for (&many, 0..) |*p, i| p.* = .init(@floatFromInt(i % 7), @floatFromInt(i % 5), @floatFromInt(i % 3));
    try testing.expectError(error.InvalidShape, w.addHull(gpa, &many));
    const coplanar = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 0, 1), .init(1, 0, 1), .init(0.5, 0, 0.3) };
    try testing.expectError(error.InvalidShape, w.addHull(gpa, &coplanar));
    const nan_point = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, std.math.nan(f32)) };
    try testing.expectError(error.InvalidShape, w.addHull(gpa, &nan_point));

    const cube = try w.addHull(gpa, &cube_points);
    const user = try w.addBody(gpa, .{ .shape = .{ .hull = cube } });
    try testing.expectError(error.InUse, w.removeHull(gpa, cube));
    try testing.expect(try w.setShape(gpa, user, ok));
    try testing.expect(try w.removeHull(gpa, cube));
    try testing.expect(!(try w.removeHull(gpa, cube)));
    // A stale hull handle is not a shape.
    try testing.expectError(error.InvalidShape, w.addBody(gpa, .{ .shape = .{ .hull = cube } }));

    try testing.expectError(error.InvalidQuery, w.raycast(.zero, .init(2, 0, 0), 1, .{}));
    try testing.expectError(error.InvalidQuery, w.raycast(.zero, .init(1, 0, 0), -1, .{}));
    try testing.expectError(error.InvalidQuery, w.raycast(.zero, .init(1, 0, 0), std.math.inf(f32), .{}));
    try testing.expectError(error.InvalidPose, w.raycast(.init(0, 9000, 0), .init(1, 0, 0), 1, .{}));
    try testing.expectError(error.InvalidQuery, w.shapeCast(ok, .identity, .init(std.math.nan(f32), 0, 0), .{}));
    try testing.expectError(error.InvalidPose, w.setPose(gpa, user, .at(.init(0, 0, -9000))));
    try testing.expect(!(try w.setPose(gpa, .none, .identity)));
}

test "the same calls give the same bytes" {
    var results: [2][64]world_mod.Hit = undefined;
    for (&results) |*out| {
        var s = try Scene.init(frames[1]);
        defer s.world.deinit(gpa);
        for (out, 0..) |*slot, i| {
            const t: f32 = @floatFromInt(i);
            const from = frames[1].point(.init(t * 0.5 - 1, @sin(t) * 0.8, -6));
            slot.* = (try s.world.shapeCast(
                .{ .capsule = .{ .radius = 0.3, .half_height = 0.4 } },
                .{ .position = from, .rotation = Quat.fromAxisAngle(.init(1, 0, 0), t * 0.1) },
                frames[1].dir(.init(0, 0, 12)),
                .{},
            )) orelse std.mem.zeroes(world_mod.Hit);
        }
    }
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&results[0]), std.mem.sliceAsBytes(&results[1]));
}
