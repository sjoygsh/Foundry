//! Runtime scale and rotational sweeps (`collision-extras.md` §4, §5, M37 Step 2).
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;
const t = std.testing;
const gpa = t.allocator;

/// A small, closed, lopsided mesh: a wedge.
const wedge_points = [_]Vec3{ .init(-1, 0, -1), .init(1, 0, -1), .init(1, 0, 1), .init(-1, 0, 1), .init(-1, 1, -1), .init(-1, 1, 1) };
const wedge_indices = [_]u32{ 0, 1, 2, 0, 2, 3, 0, 4, 1, 3, 2, 5, 1, 4, 5, 1, 5, 2, 0, 3, 5, 0, 5, 4 };

const scale: Vec3 = .init(2, 1, 0.5);
const pose: p.Pose = .{ .position = .init(0.3, -0.2, 0.1), .rotation = .{ .x = 0.1, .y = 0.3, .z = 0, .w = 0.95 } };

fn scaled(points: []const Vec3, out: []Vec3) []Vec3 {
    for (points, 0..) |pt, i| out[i] = pt.mul(scale);
    return out[0..points.len];
}

test "scale: a scaled mesh answers rays, casts and contacts as the same mesh baked at that scale" {
    const rot = pose.rotation.normalize();
    const at: p.Pose = .{ .position = pose.position, .rotation = rot };
    var a: p.World = .empty;
    defer a.deinit(gpa);
    _ = try a.addBody(gpa, .{ .shape = .{ .mesh = try a.addMesh(gpa, &wedge_points, &wedge_indices) }, .pose = at, .scale = scale });
    var b: p.World = .empty;
    defer b.deinit(gpa);
    var buffer: [8]Vec3 = undefined;
    _ = try b.addBody(gpa, .{ .shape = .{ .mesh = try b.addMesh(gpa, scaled(&wedge_points, &buffer), &wedge_indices) }, .pose = at });

    var hits: u32 = 0;
    for (0..24) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * 0.26;
        const origin = Vec3.init(4 * @cos(angle), 0.4 + 0.1 * @as(f32, @floatFromInt(i % 5)), 4 * @sin(angle));
        const dir = pose.position.sub(origin).normalize();
        const ra = try a.raycast(origin, dir, 10, .{});
        const rb = try b.raycast(origin, dir, 10, .{});
        try t.expectEqual(ra != null, rb != null);
        if (ra) |x| {
            hits += 1;
            try t.expectApproxEqAbs(rb.?.distance, x.distance, 1e-5);
            try t.expect(x.normal.sub(rb.?.normal).length() < 1e-4);
            try t.expectEqual(rb.?.triangle, x.triangle);
        }
        const ca = try a.shapeCast(.{ .sphere = .{ .radius = 0.2 } }, .at(origin), dir.scale(6), .{});
        const cb = try b.shapeCast(.{ .sphere = .{ .radius = 0.2 } }, .at(origin), dir.scale(6), .{});
        try t.expectEqual(ca != null, cb != null);
        if (ca) |x| try t.expectApproxEqAbs(cb.?.fraction, x.fraction, 1e-5);
    }
    try t.expect(hits > 12);
    // Contacts of a box pushed into the scaled mesh: the same triangles, at the same depths.
    var oa: [16]p.Contact = undefined;
    var ob: [16]p.Contact = undefined;
    const box: p.Shape = .{ .box = .{ .half_extents = .init(0.4, 0.4, 0.4) } };
    const fa = try a.contacts(box, .at(pose.position.add(.init(1.6, 0.3, 0))), .{}, &oa);
    const fb = try b.contacts(box, .at(pose.position.add(.init(1.6, 0.3, 0))), .{}, &ob);
    try t.expectEqual(fb.count, fa.count);
    try t.expect(fa.count > 0);
    for (oa[0..fa.count], ob[0..fb.count]) |x, y| {
        try t.expectEqual(y.triangle, x.triangle);
        try t.expectApproxEqAbs(y.depth, x.depth, 1e-5);
    }
}

test "scale: a scaled hull answers as the same hull baked at that scale, from one shared hull" {
    const cube = [_]Vec3{ .init(-1, -1, -1), .init(1, -1, -1), .init(1, 1, -1), .init(-1, 1, -1), .init(-1, -1, 1), .init(1, -1, 1), .init(1, 1, 1), .init(-1, 1, 1) };
    var a: p.World = .empty;
    defer a.deinit(gpa);
    const hull = try a.addHull(gpa, &cube);
    _ = try a.addBody(gpa, .{ .shape = .{ .hull = hull }, .scale = scale });
    // The same hull at its own size elsewhere: one hull, two sizes.
    _ = try a.addBody(gpa, .{ .shape = .{ .hull = hull }, .pose = .at(.init(20, 0, 0)) });
    try t.expectEqual(@as(u32, 1), a.hullCount());
    var b: p.World = .empty;
    defer b.deinit(gpa);
    var buffer: [8]Vec3 = undefined;
    _ = try b.addBody(gpa, .{ .shape = .{ .hull = try b.addHull(gpa, scaled(&cube, &buffer)) } });
    for ([_]Vec3{ .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1), Vec3.init(1, 1, 1).normalize() }) |dir| {
        const origin = dir.scale(-5);
        const ra = (try a.raycast(origin, dir, 10, .{})).?;
        const rb = (try b.raycast(origin, dir, 10, .{})).?;
        try t.expectApproxEqAbs(rb.distance, ra.distance, 1e-5);
    }
    // 2 m in X, 1 in Y, 0.5 in Z.
    try t.expectApproxEqAbs(@as(f32, 3), (try a.raycast(.init(-5, 0, 0), .init(1, 0, 0), 10, .{})).?.distance, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 4.5), (try a.raycast(.init(0, 0, -5), .init(0, 0, 1), 10, .{})).?.distance, 1e-5);
}

test "scale: refused unless positive, finite and in range, and only for a mesh or a hull" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const mesh = try w.addMesh(gpa, &wedge_points, &wedge_indices);
    for ([_]Vec3{ .init(-1, 1, 1), .init(0, 1, 1), .init(0.009, 1, 1), .init(1, 101, 1), .init(1, 1, std.math.nan(f32)), .init(std.math.inf(f32), 1, 1) }) |bad| {
        try t.expectError(error.InvalidShape, w.addBody(gpa, .{ .shape = .{ .mesh = mesh }, .scale = bad }));
    }
    for ([_]p.Shape{ .{ .sphere = .{ .radius = 1 } }, .{ .capsule = .{ .radius = 0.3, .half_height = 0.5 } }, .{ .box = .{ .half_extents = .one } } }) |shape| {
        try t.expectError(error.InvalidShape, w.addBody(gpa, .{ .shape = shape, .scale = .init(2, 2, 2) }));
        const ok = try w.addBody(gpa, .{ .shape = shape });
        try t.expectError(error.InvalidShape, w.setScale(gpa, ok, .init(2, 2, 2)));
        try t.expect(try w.setScale(gpa, ok, .one));
    }
    const body = try w.addBody(gpa, .{ .shape = .{ .mesh = mesh }, .scale = .init(0.01, 100, 1) });
    try t.expect(try w.setScale(gpa, body, .init(3, 3, 3)));
    try t.expectEqual(Vec3.init(3, 3, 3), w.body(body).?.scale);
    try t.expectError(error.InvalidShape, w.setScale(gpa, body, .init(-3, 3, 3)));
    // A scaled mesh body cannot become a box at that scale.
    try t.expectError(error.InvalidShape, w.setShape(gpa, body, .{ .box = .{ .half_extents = .one } }));
}

/// A door: a box 1 m wide, hinged at its left edge, swinging about +Y.
fn doorAt(angle: f32) p.Pose {
    const rot = Quat.fromAxisAngle(.up, angle);
    return .{ .position = rot.rotate(.init(0.5, 1, 0)), .rotation = rot };
}
const door: p.Shape = .{ .box = .{ .half_extents = .init(0.5, 1, 0.05) } };

test "sweep: a swinging door stops a skin short of a wall it would pass through" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    // A wall 0.5 m from the hinge, across the door's path between 0 and a half turn.
    _ = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(1, 1, 0.05) } }, .pose = .at(.init(0, 1, -0.6)) });
    const hit = (try w.shapeSweep(door, doorAt(0), doorAt(std.math.pi / 2.0), .{})).?;
    try t.expect(hit.fraction > 0.05 and hit.fraction < 0.95 and !hit.started_inside);
    // Where it stopped on the sweep's path, the positions lerped and the rotations slerped, it is
    // a skin from the wall, never into it. A hinge's arc is that path's limit over small steps,
    // which is how a game swings a door a tick at a time.
    const a = doorAt(0);
    const b = doorAt(std.math.pi / 2.0);
    const stopped: p.Pose = .{ .position = a.position.lerp(b.position, hit.fraction), .rotation = a.rotation.slerp(b.rotation, hit.fraction) };
    var out: [4]p.Contact = undefined;
    try t.expectEqual(@as(u32, 0), (try w.contacts(door, stopped, .{}, &out)).total);
    var gap: [4]p.Contact = undefined;
    const grown: p.Shape = .{ .box = .{ .half_extents = .init(0.5 + p.contact_skin + 1e-4, 1 + p.contact_skin + 1e-4, 0.05 + p.contact_skin + 1e-4) } };
    try t.expect((try w.contacts(grown, stopped, .{}, &gap)).total > 0);
    // Swung the other way, it meets nothing.
    try t.expect(try w.shapeSweep(door, doorAt(0), doorAt(-std.math.pi / 2.0), .{}) == null);
}

test "sweep: a thin pole between two angles is never passed, and a sweep with no turn is shapeCast" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    // A pole 2 cm thick at 45 degrees, 0.8 m from the hinge: a sample at each end would miss it.
    const at = Quat.fromAxisAngle(.up, std.math.pi / 4.0).rotate(.init(0.8, 1, 0));
    _ = try w.addBody(gpa, .{ .shape = .{ .capsule = .{ .radius = 0.01, .half_height = 1 } }, .pose = .at(at) });
    const hit = (try w.shapeSweep(door, doorAt(0), doorAt(std.math.pi / 2.0), .{})).?;
    try t.expect(hit.fraction > 0.3 and hit.fraction < 0.5);
    // No turn: the same answer as a cast along the same line, at a crate in its way.
    _ = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(0.3, 0.3, 0.3) } }, .pose = .at(.init(2, 1, 0.3)) });
    const from: p.Pose = .at(.init(-2, 1, 0.3));
    const to: p.Pose = .at(.init(3, 1, 0.3));
    const swept = (try w.shapeSweep(.{ .sphere = .{ .radius = 0.2 } }, from, to, .{})).?;
    const cast = (try w.shapeCast(.{ .sphere = .{ .radius = 0.2 } }, from, to.position.sub(from.position), .{})).?;
    try t.expectApproxEqAbs(cast.fraction, swept.fraction, 1e-4);
    // What it refuses: a mesh, and a pose that is not one.
    const mesh = try w.addMesh(gpa, &wedge_points, &wedge_indices);
    try t.expectError(error.InvalidShape, w.shapeSweep(.{ .mesh = mesh }, from, to, .{}));
    try t.expectError(error.InvalidPose, w.shapeSweep(door, from, .{ .position = .init(std.math.nan(f32), 0, 0) }, .{}));
}

test "sweep: two worlds sweeping the same doors are equal to the bit" {
    var hashes: [2]u64 = undefined;
    for (&hashes) |*h| {
        var w: p.World = .empty;
        defer w.deinit(gpa);
        _ = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(1, 1, 0.05) } }, .pose = .at(.init(0, 1, -0.6)) });
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        for (0..64) |i| {
            const a: f32 = @as(f32, @floatFromInt(i)) * 0.03;
            if (try w.shapeSweep(door, doorAt(-a), doorAt(a + 1.2), .{})) |hit| try bytes.appendSlice(gpa, std.mem.asBytes(&hit.fraction));
        }
        h.* = std.hash.Fnv1a_64.hash(bytes.items);
    }
    try t.expectEqual(hashes[0], hashes[1]);
}

test "scale: a fine grid scaled tenfold is found where it is drawn, and nowhere else" {
    // A 1 m square of 400 triangles, placed at ten times its size: the search for candidates must
    // look in the mesh's own, unscaled space, or every ray past the first metre finds nothing.
    var points: [21 * 21]Vec3 = undefined;
    for (0..21) |i| for (0..21) |j| {
        points[i * 21 + j] = .init(@as(f32, @floatFromInt(j)) / 20, 0, @as(f32, @floatFromInt(i)) / 20);
    };
    var indices: [20 * 20 * 6]u32 = undefined;
    var n: usize = 0;
    for (0..20) |i| for (0..20) |j| {
        const a: u32 = @intCast(i * 21 + j);
        for ([_]u32{ a, a + 21, a + 1, a + 1, a + 21, a + 22 }) |v| {
            indices[n] = v;
            n += 1;
        }
    };
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = try w.addMesh(gpa, &points, &indices) }, .scale = .init(10, 1, 10) });
    for ([_][2]f32{ .{ 7.3, 8.1 }, .{ 0.2, 9.9 }, .{ 9.6, 0.4 }, .{ 5, 5 } }) |xz| {
        const hit = (try w.raycast(.init(xz[0], 5, xz[1]), .init(0, -1, 0), 10, .{})).?;
        try t.expectApproxEqAbs(@as(f32, 5), hit.distance, 1e-5);
    }
    try t.expect(try w.raycast(.init(10.5, 5, 5), .init(0, -1, 0), 10, .{}) == null);
}
