//! Hull faces in the world (`collision-scale.md` §6, M38 Step 4).
//!
//! A hit on a hull says which face it lies on, and a character at a hull's rim stands on its
//! top, as it does on a box's. Distances, casts and depths still read the points alone.
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;
const t = std.testing;
const gpa = t.allocator;
const config: p.CharacterConfig = .{ .radius = 0.3, .height = 1.8, .max_slope = std.math.pi / 4.0, .step_height = 0.35, .snap_distance = 0.3, .max_move = 10 };

const unit_cube = [_]Vec3{
    .init(-1, -1, -1), .init(1, -1, -1), .init(1, 1, -1), .init(-1, 1, -1),
    .init(-1, -1, 1),  .init(1, -1, 1),  .init(1, 1, 1),  .init(-1, 1, 1),
};

fn expectVec(want: Vec3, got: Vec3, tolerance: f32) !void {
    try t.expectApproxEqAbs(want.x, got.x, tolerance);
    try t.expectApproxEqAbs(want.y, got.y, tolerance);
    try t.expectApproxEqAbs(want.z, got.z, tolerance);
}

fn move(w: *p.World, c: p.CharacterHandle, by: Vec3) !p.CharacterMove {
    return (try w.moveCharacter(gpa, c, by, &.{})).?;
}

test "hull faces: a character on a hull ramp is told the face, and so is a ray and a cast" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    // A wedge rising 25 degrees along +X.
    const rise: f32 = @tan(25.0 * std.math.pi / 180.0) * 8.0;
    const wedge = try w.addHull(gpa, &.{ .init(0, 0, -4), .init(8, 0, -4), .init(8, rise, -4), .init(0, 0, 4), .init(8, 0, 4), .init(8, rise, 4) });
    const body = try w.addBody(gpa, .{ .shape = .{ .hull = wedge }, .user = 7 });
    try t.expectEqual(@as(usize, 5), w.hullFaces(wedge).?.len);
    try t.expectEqual(@as(u32, 5), w.report().hull_faces);
    const slope = Vec3.init(-rise, 8, 0).normalize();

    const c = try w.addCharacter(gpa, config, .init(4, rise / 2 + p.contact_skin, 0), 0);
    var r = try move(&w, c, .zero);
    try t.expect(r.grounded and !r.stuck);
    var ground = w.character(c).?.ground.?;
    try t.expect(ground.body.eql(body));
    try expectVec(slope, ground.surface_normal, 2e-6);
    // Walking up it, every tick.
    for (0..60) |_| {
        r = try move(&w, c, .init(0.02, -0.01, 0));
        try t.expect(r.grounded);
        ground = w.character(c).?.ground.?;
        try expectVec(slope, ground.surface_normal, 2e-6);
    }

    const ray = (try w.raycast(.init(3, 5, 1), .init(0, -1, 0), 10, .{})).?;
    try expectVec(slope, ray.surface_normal, 2e-6);
    const cast = (try w.shapeCast(.{ .sphere = .{ .radius = 0.25 } }, .at(.init(5, 6, -2)), .init(0, -8, 0), .{})).?;
    try expectVec(slope, cast.surface_normal, 2e-6);
    try expectVec(slope, cast.normal, 1e-3);
    // The tall end, from the side.
    const side = (try w.raycast(.init(12, 1, 0), .init(-1, 0, 0), 10, .{})).?;
    try expectVec(.init(1, 0, 0), side.surface_normal, 2e-6);
    // A sweep that turns as it goes ends on the same face.
    const sweep = (try w.shapeSweep(.{ .box = .{ .half_extents = .init(0.2, 0.2, 0.2) } }, .at(.init(4, 6, 0)), .{ .position = .init(4, 0, 0), .rotation = Quat.fromAxisAngle(.init(0, 1, 0), 1) }, .{})).?;
    try expectVec(slope, sweep.surface_normal, 2e-6);
}

test "hull faces: at a rim a character stands on the top, as it does on a box" {
    // The same slab twice: once a box, once a hull of a cube's corners scaled to the box.
    const half: Vec3 = .init(2, 0.5, 2);
    const poses = [_]p.Pose{
        .at(.init(0, -0.5, 0)),
        .{ .position = .init(3, -0.5, -1), .rotation = Quat.fromAxisAngle(.init(0, 1, 0), 0.5) },
    };
    for (poses) |pose| {
        var boxed: p.World = .empty;
        defer boxed.deinit(gpa);
        var hulled: p.World = .empty;
        defer hulled.deinit(gpa);
        _ = try boxed.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = half } }, .pose = pose });
        const cube = try hulled.addHull(gpa, &unit_cube);
        _ = try hulled.addBody(gpa, .{ .shape = .{ .hull = cube }, .pose = pose, .scale = half });

        var past_the_slope: usize = 0;
        // The capsule's axis from just inside the rim to almost its radius past it, resting on
        // the rim's edge. Past about 0.21 m the contact's own normal is steeper than the slope
        // limit, and only the face the contact lies on says the character is on the top.
        for (0..15) |i| {
            const out = -0.02 + 0.02 * @as(f32, @floatFromInt(i));
            const over = @max(out, 0);
            const reach = config.radius + p.contact_skin;
            const sunk = reach - @sqrt(reach * reach - over * over);
            const feet = pose.apply(.init(half.x + out, half.y + p.contact_skin - sunk, 0.3));
            var grounded: [2]bool = undefined;
            var at: [2]Vec3 = undefined;
            var normal: [2]Vec3 = undefined;
            for ([_]*p.World{ &boxed, &hulled }, 0..) |w, k| {
                const c = try w.addCharacter(gpa, config, feet, 0);
                const r = try move(w, c, .zero);
                grounded[k] = r.grounded;
                at[k] = r.feet;
                normal[k] = if (w.character(c).?.ground) |g| g.surface_normal else .zero;
                try t.expect(w.removeCharacter(gpa, c));
            }
            try t.expectEqual(grounded[0], grounded[1]);
            try expectVec(at[0], at[1], 1e-4);
            try expectVec(normal[0], normal[1], 2e-6);
            if (grounded[1]) try expectVec(.init(0, 1, 0), normal[1], 2e-6);
            past_the_slope += @intFromBool(grounded[1] and out > 0.3 * @sin(config.max_slope));
        }
        try t.expect(past_the_slope >= 2);

        // Walking off the rim, the two fall alike.
        var feet: [2]Vec3 = undefined;
        for ([_]*p.World{ &boxed, &hulled }, 0..) |w, k| {
            const c = try w.addCharacter(gpa, config, pose.apply(.init(1, half.y + p.contact_skin, 0)), 0);
            var r = try move(w, c, .zero);
            try t.expect(r.grounded);
            const forward = pose.applyDirection(.init(0.05, 0, 0));
            for (0..60) |_| r = try move(w, c, forward.add(.init(0, -0.05, 0)));
            try t.expect(!r.grounded);
            feet[k] = r.feet;
        }
        try expectVec(feet[0], feet[1], 1e-3);
    }
}

test "hull faces: a scaled hull's face is the one a person sees, and a flat hull has none" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const rise: f32 = 2.0;
    const wedge = try w.addHull(gpa, &.{ .init(0, 0, -1), .init(4, 0, -1), .init(4, rise, -1), .init(0, 0, 1), .init(4, 0, 1), .init(4, rise, 1) });
    const rotation = Quat.fromAxisAngle(.init(0, 1, 0), 0.7);
    const body = try w.addBody(gpa, .{ .shape = .{ .hull = wedge }, .pose = .{ .position = .init(1, 2, 3), .rotation = rotation }, .scale = .init(1, 3, 2) });
    // Scaled three times taller, the slope's normal leans further over.
    const slope = rotation.rotate(Vec3.init(-rise * 3, 4, 0).normalize());
    const above = (p.Pose{ .position = .init(1, 2, 3), .rotation = rotation }).apply(.init(2, 12, 0.5));
    const ray = (try w.raycast(above, .init(0, -1, 0), 20, .{})).?;
    try t.expect(ray.body.eql(body));
    try expectVec(slope, ray.surface_normal, 3e-6);
    try expectVec(slope, ray.normal, 1e-3);

    // A sheet a tenth of a millimetre thick and a hundred metres wide is a hull by its volume,
    // and flat by its faces' tolerance. It collides as before, and reports the contact normal.
    const sheet = try w.addHull(gpa, &.{ .init(0, 0, 0), .init(100, 0, 0), .init(0, 0, 100), .init(100, 1e-4, 100) });
    try t.expectEqual(@as(usize, 0), w.hullFaces(sheet).?.len);
    _ = try w.addBody(gpa, .{ .shape = .{ .hull = sheet }, .pose = .at(.init(-200, 0, 0)) });
    const flat = (try w.raycast(.init(-170, 5, 30), .init(0, -1, 0), 10, .{})).?;
    try t.expect(flat.surface_normal.eql(flat.normal));
    try t.expectApproxEqAbs(@as(f32, 5), flat.distance, 1e-3);
    try t.expectEqual(@as(u32, 5), w.report().hull_faces);
}

test "hull faces: the face is one the contact lies on, not merely the one facing the same way" {
    const faces = try p.hull.faces(gpa, &unit_cube);
    defer gpa.free(faces);
    const pose: p.Pose = .{ .position = .init(3, 1, -2), .rotation = Quat.fromAxisAngle(.init(0, 0, 1), 0.3) };
    const cube: p.shape.Convex = .{ .core = .{ .points = &unit_cube }, .radius = 0, .pose = pose, .faces = faces };
    const top = pose.applyDirection(.init(0, 1, 0));
    const side = pose.applyDirection(.init(1, 0, 0));
    // In the middle of the top, whatever the contact normal says.
    try expectVec(top, cube.surfaceNormal(side, pose.apply(.init(0.2, 1, -0.4))), 2e-6);
    try expectVec(top, cube.surfaceNormal(top.neg(), pose.apply(.init(0.2, 1, -0.4))), 2e-6);
    // On the edge the top and the side share, the contact normal chooses between the two.
    const edge = pose.apply(.init(1, 1, 0.5));
    try expectVec(top, cube.surfaceNormal(Vec3.init(0.4, 0.9, 0).normalize(), edge), 2e-6);
    try expectVec(pose.applyDirection(.init(1, 0, 0)), cube.surfaceNormal(pose.applyDirection(Vec3.init(0.9, 0.4, 0).normalize()), edge), 2e-6);
    // A tie goes to the first face. At a corner three faces tie for a normal along the diagonal.
    const corner = cube.surfaceNormal(pose.applyDirection(Vec3.init(1, 1, 1).normalize()), pose.apply(.init(1, 1, 1)));
    var first: ?Vec3 = null;
    for (0..faces.len) |i| {
        const f = cube.face(i, pose.apply(.init(1, 1, 1)));
        if (first == null and @abs(f.height) < 1e-5) first = f.normal;
    }
    try t.expect(corner.eql(first.?));
    // A point just off the surface is still told its nearest face.
    try expectVec(top, cube.surfaceNormal(top, pose.apply(.init(0, 1.004, 0))), 2e-6);
}

test "hull faces: grounding needs a witness on the walkable face, not merely a face above" {
    // The box test of the same name, on a hull: a slab tilted 25 degrees, and a capsule against
    // its lower side. The slab has a walkable top, and the capsule is not on it.
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const rotation = Quat.fromAxisAngle(.init(0, 0, 1), 25.0 * std.math.pi / 180.0);
    const cube = try w.addHull(gpa, &unit_cube);
    _ = try w.addBody(gpa, .{ .shape = .{ .hull = cube }, .pose = .{ .rotation = rotation }, .scale = .init(1, 3, 3) });
    const lower_core = rotation.rotate(.init(1 + config.radius + p.contact_skin, 1, 0));
    const c = try w.addCharacter(gpa, config, lower_core.sub(.init(0, config.radius, 0)), 0);
    const capsule: p.shape.Convex = .{ .core = .{ .segment = 0.6 }, .radius = 0.3, .pose = w.body(w.character(c).?.body).?.pose };
    const h = w.characterProbe(capsule, .init(0, -0.01, 0), w.character(c).?.body, @cos(config.max_slope)).?;
    try t.expect(h.surface_normal.y < @cos(config.max_slope));
    try expectVec(rotation.rotate(.init(1, 0, 0)), h.surface_normal, 2e-6);
    const r = try move(&w, c, .zero);
    try t.expect(!r.grounded and !r.stuck);
}

test "hull faces: the faces change no distance, cast or depth" {
    // A drum met from many sides by a hull that carries its faces and by its bare points.
    var drum: [32]Vec3 = undefined;
    for (0..16) |i| {
        const angle = @as(f32, @floatFromInt(i)) * std.math.tau / 16.0;
        drum[i] = .init(2 * @cos(angle), 0, 2 * @sin(angle));
        drum[16 + i] = .init(1.5 * @cos(angle), 0.5, 1.5 * @sin(angle));
    }
    const faces = try p.hull.faces(gpa, &drum);
    defer gpa.free(faces);
    try t.expectEqual(@as(usize, 18), faces.len);
    var rng = core.rng.Pcg32.init(6, 38);
    for (0..300) |_| {
        const pose: p.Pose = .{ .position = .init(rng.float01(), rng.float01(), rng.float01()), .rotation = Quat.fromAxisAngle(.init(0.3, 1, 0.2), rng.float01() * 6) };
        const bare: p.shape.Convex = .{ .core = .{ .points = &drum }, .radius = 0, .pose = pose, .scale = .init(1, 2, 1) };
        var faced = bare;
        faced.faces = faces;
        const probe: p.shape.Convex = .{ .core = .{ .segment = 0.5 }, .radius = 0.3, .pose = .at(.init(rng.float01() * 6 - 3, rng.float01() * 4 - 1, rng.float01() * 6 - 3)) };
        const a = p.narrow.separation(probe, bare);
        const b = p.narrow.separation(probe, faced);
        try t.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
        const by: Vec3 = .init(rng.float01() - 0.5, -rng.float01(), rng.float01() - 0.5);
        const ca = p.narrow.cast(probe, by.scale(4), bare, p.contact_skin);
        const cb = p.narrow.cast(probe, by.scale(4), faced, p.contact_skin);
        try t.expectEqualDeep(ca, cb);
    }
}

test "hull faces: a hull's faces live and die with it" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const cube = try w.addHull(gpa, &unit_cube);
    const faces = w.hullFaces(cube).?;
    try t.expectEqual(@as(usize, 6), faces.len);
    for (faces) |face| try t.expectEqual(@as(f32, 1), face.offset);
    const again = try w.addHull(gpa, &unit_cube);
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(faces), std.mem.sliceAsBytes(w.hullFaces(again).?));
    try t.expectEqual(@as(u32, 12), w.report().hull_faces);
    try t.expect(try w.removeHull(gpa, cube));
    try t.expectEqual(@as(?[]const p.HullPlane, null), w.hullFaces(cube));
    try t.expectEqual(@as(u32, 6), w.report().hull_faces);

    const Try = struct {
        fn add(allocator: std.mem.Allocator) !void {
            var world: p.World = .empty;
            defer world.deinit(allocator);
            _ = try world.addHull(allocator, &unit_cube);
        }
    };
    try t.checkAllAllocationFailures(gpa, Try.add, .{});
}
