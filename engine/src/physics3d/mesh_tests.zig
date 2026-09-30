//! Static mesh evidence: analytic geometry, brute-force triangle oracles and ownership.
const std = @import("std");
const core = @import("core");
const physics = @import("root.zig");
const mesh_mod = @import("mesh.zig");
const Vec3 = core.math.Vec3;
const Quat = core.math.Quat;
const Pose = physics.Pose;
const Convex = physics.shape.Convex;
const World = physics.World;
const testing = std.testing;
const gpa = testing.allocator;
const floor = [_]Vec3{ .init(-10, 0, -10), .init(10, 0, -10), .init(0, 0, 10) };
const ix = [_]u32{ 0, 2, 1 }; // +Y face
const frames = [_]Pose{
    .identity,
    .{ .position = .init(5, -2, 7), .rotation = Quat.fromAxisAngle(.init(1, 2, 3), 0.7) },
    .{ .position = .init(900, -300, 1200), .rotation = Quat.fromAxisAngle(.init(-2, 0.5, 1), -1.9) },
};

fn expectVec(want: Vec3, got: Vec3, tolerance: f32) !void {
    try testing.expectApproxEqAbs(want.x, got.x, tolerance);
    try testing.expectApproxEqAbs(want.y, got.y, tolerance);
    try testing.expectApproxEqAbs(want.z, got.z, tolerance);
}

test "mesh: all convex kinds separate, cast and contact on both sides in rigid frames" {
    for (frames) |frame| {
        var w: World = .empty;
        defer w.deinit(gpa);
        const mesh = try w.addMesh(gpa, &floor, &ix);
        _ = try w.addBody(gpa, .{ .shape = .{ .mesh = mesh }, .pose = frame, .user = 91 });
        const hull = try w.addHull(gpa, &.{ .init(-0.5, -0.5, -0.5), .init(0.5, -0.5, -0.5), .init(0, 0.5, -0.5), .init(0, 0, 0.5) });
        const shapes = [_]physics.Shape{
            .{ .sphere = .{ .radius = 0.5 } },
            .{ .capsule = .{ .radius = 0.25, .half_height = 0.5 } },
            .{ .box = .{ .half_extents = .init(0.5, 0.5, 0.5) } },
            .{ .hull = hull },
        };
        for ([_]f32{ 1, -1 }) |side| {
            const ray = (try w.raycast(frame.apply(.init(0, 3 * side, 0)), frame.applyDirection(.init(0, -side, 0)), 6, .{})).?;
            try testing.expectApproxEqAbs(@as(f32, 3), ray.distance, 0.001);
            try expectVec(frame.applyDirection(.init(0, side, 0)), ray.normal, 0.003);
            try expectVec(frame.applyDirection(.init(0, side, 0)), ray.surface_normal, 0.003);
            try testing.expectEqual(@as(u32, 0), ray.triangle);
            for (shapes, 0..) |s, i| {
                const pose: Pose = .{ .position = frame.apply(.init(0, 3 * side, 0)), .rotation = frame.rotation };
                const reach: f32 = if (i == 1) 0.75 else 0.5;
                const moving = switch (s) {
                    .sphere => Convex{ .core = .point, .radius = 0.5, .pose = pose },
                    .capsule => Convex{ .core = .{ .segment = 0.5 }, .radius = 0.25, .pose = pose },
                    .box => Convex{ .core = .{ .box = .init(0.5, 0.5, 0.5) }, .radius = 0, .pose = pose },
                    .hull => Convex{ .core = .{ .points = w.hulls.get(hull).?.points }, .radius = 0, .pose = pose },
                    .mesh => unreachable,
                };
                const tri: Convex = .{ .core = .{ .triangle = .{ floor[0], floor[2], floor[1] } }, .radius = 0, .pose = frame };
                try testing.expectApproxEqAbs(3 - reach, physics.narrow.separation(moving, tri).distance, 0.002);
                const hit = (try w.shapeCast(s, pose, frame.applyDirection(.init(0, -6 * side, 0)), .{})).?;
                try testing.expectApproxEqAbs((3 - reach - physics.contact_skin) / 6, hit.fraction, 0.0005);
                try expectVec(frame.applyDirection(.init(0, side, 0)), hit.normal, 0.003);
                try expectVec(frame.applyDirection(.init(0, side, 0)), hit.surface_normal, 0.003);
                try testing.expectApproxEqAbs(@as(f32, 0), frame.inverseDirection(hit.point.sub(frame.position)).y, 0.002);
                try testing.expect(!hit.started_inside);
                var contact: [1]physics.Contact = undefined;
                const penetrating: Pose = .{ .position = frame.apply(.init(0, (reach - 0.1) * side, 0)), .rotation = frame.rotation };
                try testing.expectEqual(@as(u32, 1), (try w.contacts(s, penetrating, .{}, &contact)).total);
                try testing.expectApproxEqAbs(@as(f32, 0.1), contact[0].depth, 0.003);
                try expectVec(frame.applyDirection(.init(0, side, 0)), contact[0].normal, 0.003);
                const inside = (try w.shapeCast(s, penetrating, frame.applyDirection(.init(0, side, 0)), .{})).?;
                try testing.expect(inside.started_inside and inside.fraction == 0);
            }
        }
    }
}

test "mesh: an edge contact has a tilted normal and a two-sided face normal" {
    var w: World = .empty;
    defer w.deinit(gpa);
    const mesh = try w.addMesh(gpa, &.{ .init(-2, 0, 0), .init(2, 0, 0), .init(0, 0, 4) }, &.{ 0, 2, 1 });
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = mesh } });
    for ([_]f32{ 1, -1 }) |side| {
        const hit = (try w.shapeCast(.{ .sphere = .{ .radius = 0.5 } }, .at(.init(0, 2 * side, -0.3)), .init(0, -4 * side, 0), .{})).?;
        try testing.expect(hit.normal.y * side > 0.7 and hit.normal.z < -0.5);
        try expectVec(.init(0, side, 0), hit.surface_normal, 1e-5);
    }
}

test "mesh: a fast capsule stops at a zero-thickness wall from either side" {
    var w: World = .empty;
    defer w.deinit(gpa);
    const m = try w.addMesh(gpa, &.{ .init(0, -5, -5), .init(0, 5, -5), .init(0, 0, 5) }, &.{ 0, 1, 2 });
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = m } });
    for ([_]f32{ -1, 1 }) |side| {
        const hit = (try w.shapeCast(.{ .capsule = .{ .radius = 0.3, .half_height = 0.6 } }, .at(.init(side * 50, 0, 0)), .init(-side * 100, 0, 0), .{})).?;
        const stopped = side * (side * 50 - side * 100 * hit.fraction);
        try testing.expectApproxEqAbs(@as(f32, 0.305), stopped, 0.001);
    }
}

test "mesh: validation reports the first bad triangle and refuses counts, coordinates and use" {
    var w: World = .empty;
    defer w.deinit(gpa);
    try testing.expectError(error.InvalidMesh, w.addMesh(gpa, &floor, &.{}));
    try testing.expectError(error.InvalidMesh, w.addMesh(gpa, &floor, &.{ 0, 1 }));
    try testing.expectError(error.InvalidMesh, w.addMesh(gpa, &.{}, &ix));
    try testing.expectError(error.InvalidMesh, w.addMesh(gpa, &floor, &.{ 0, 1, 3 }));
    const diagnostic = mesh_mod.validate(&floor, &.{ 0, 1, 2, 0, 1, 9 });
    try testing.expect(!diagnostic.valid);
    try testing.expectEqual(@as(?u32, 1), diagnostic.triangle);
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), 8193 }) |bad| {
        var p = floor;
        p[1].x = bad;
        try testing.expectError(error.InvalidMesh, w.addMesh(gpa, &p, &ix));
    }
    // Even a vertex not referenced by a triangle is validated.
    try testing.expectError(error.InvalidMesh, w.addMesh(gpa, &.{ floor[0], floor[1], floor[2], .init(0, 9000, 0) }, &ix));
    const too_many_ix = try gpa.alloc(u32, (mesh_mod.max_triangles + 1) * 3);
    defer gpa.free(too_many_ix);
    try testing.expectError(error.InvalidMesh, w.addMesh(gpa, &floor, too_many_ix));
    const too_many_pts = try gpa.alloc(Vec3, mesh_mod.max_positions + 1);
    defer gpa.free(too_many_pts);
    try testing.expectError(error.InvalidMesh, w.addMesh(gpa, too_many_pts, &ix));
    const m = try w.addMesh(gpa, &floor, &ix);
    const s: physics.Shape = .{ .mesh = m };
    try testing.expectError(error.InvalidShape, w.addBody(gpa, .{ .shape = s, .kind = .kinematic }));
    const body = try w.addBody(gpa, .{ .shape = s });
    try testing.expectError(error.InvalidShape, w.setKind(body, .kinematic));
    try testing.expectEqual(physics.BodyKind.static, w.body(body).?.kind);
    const moving = try w.addBody(gpa, .{ .shape = .{ .sphere = .{ .radius = 1 } }, .kind = .kinematic });
    try testing.expectError(error.InvalidShape, w.setShape(gpa, moving, s));
    try testing.expectError(error.InvalidShape, w.shapeCast(s, .identity, .zero, .{}));
    try testing.expectError(error.InvalidShape, w.overlap(s, .identity, .{}, &.{}));
    try testing.expectError(error.InvalidShape, w.contacts(s, .identity, .{}, &.{}));
    try testing.expectError(error.InUse, w.removeMesh(gpa, m));
    try testing.expect(w.removeBody(gpa, body));
    try testing.expect(try w.removeMesh(gpa, m));
    try testing.expect(!(try w.removeMesh(gpa, m)));
    const reused = try w.addMesh(gpa, &floor, &ix);
    try testing.expect(!m.eql(reused));
    try testing.expectError(error.InvalidShape, w.addBody(gpa, .{ .shape = s }));
}

test "mesh: copying, shared references, shape replacement and teleport keep geometry valid" {
    var w: World = .empty;
    defer w.deinit(gpa);
    var positions = floor;
    var indices = ix;
    const m = try w.addMesh(gpa, &positions, &indices);
    positions = @splat(Vec3.zero);
    indices = @splat(0);
    const a = try w.addBody(gpa, .{ .shape = .{ .mesh = m } });
    const b = try w.addBody(gpa, .{ .shape = .{ .mesh = m }, .pose = .at(.init(0, 10, 0)) });
    try testing.expect(w.removeBody(gpa, a));
    try testing.expectError(error.InUse, w.removeMesh(gpa, m));
    try testing.expectApproxEqAbs(@as(f32, 10), (try w.raycast(.init(0, 20, 0), .init(0, -1, 0), 30, .{})).?.distance, 1e-4);
    try testing.expect(try w.setPose(gpa, b, .at(.init(0, 12, 0))));
    try testing.expectApproxEqAbs(@as(f32, 12), w.boundsOf(b).?.min.y, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 8), (try w.raycast(.init(0, 20, 0), .init(0, -1, 0), 30, .{})).?.distance, 1e-4);
    try testing.expect(try w.setShape(gpa, b, .{ .sphere = .{ .radius = 1 } }));
    try testing.expect(try w.removeMesh(gpa, m));
    try testing.expectEqual(@as(u32, 0), w.meshCount());
}

test "mesh: degenerates remain copied but cannot hit, overlap or contact" {
    var w: World = .empty;
    defer w.deinit(gpa);
    const m = try w.addMesh(gpa, &floor, &.{ 0, 0, 0, 0, 1, 2 });
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = m } });
    try testing.expectEqual(@as(u32, 1), (try w.raycast(.init(0, 3, 0), .init(0, -1, 0), 6, .{})).?.triangle);
    var overlap: [2]physics.Overlap = undefined;
    var contacts: [2]physics.Contact = undefined;
    const s: physics.Shape = .{ .sphere = .{ .radius = 0.5 } };
    try testing.expectEqual(@as(u32, 1), (try w.overlap(s, .identity, .{}, &overlap)).total);
    try testing.expectEqual(@as(u32, 1), overlap[0].triangle);
    try testing.expectEqual(@as(u32, 1), (try w.contacts(s, .identity, .{}, &contacts)).total);
    try testing.expectEqual(@as(u32, 1), contacts[0].triangle);
    const degenerate = try w.addMesh(gpa, &floor, &.{ 0, 0, 0 });
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = degenerate }, .pose = .at(.init(0, 20, 0)) });
    try testing.expect((try w.raycast(.init(-10, 21, -10), .init(0, -1, 0), 2, .{})) == null);
}

test "mesh: BVH output matches individual triangle cores, sorted by original index" {
    var w: World = .empty;
    defer w.deinit(gpa);
    // Scramble spatial order deliberately. All triangles share an overlapping central area,
    // but their centroids force BVH order to differ from input order.
    var positions: [48]Vec3 = undefined;
    var indices: [48]u32 = undefined;
    for (0..16) |t| {
        const x: f32 = @floatFromInt((t * 7) % 16);
        positions[t * 3] = .init(-20, 0, -20);
        positions[t * 3 + 1] = .init(20 + x, 0, -20);
        positions[t * 3 + 2] = .init(0, 0, 20);
        for (0..3) |v| indices[t * 3 + v] = @intCast(t * 3 + v);
    }
    const m = try w.addMesh(gpa, &positions, &indices);
    const first = try w.addBody(gpa, .{ .shape = .{ .mesh = m }, .user = 3, .layer = 2 });
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = m }, .user = 4, .layer = 4 });
    const mesh = w.meshes.get(m).?;
    var repeat = try mesh_mod.Mesh.init(gpa, &positions, &indices);
    defer repeat.deinit(gpa);
    try testing.expectEqualSlices(u32, mesh.order, repeat.order);
    try testing.expectEqual(mesh.node_count, repeat.node_count);
    for (mesh.nodes[0..mesh.node_count], repeat.nodes[0..repeat.node_count]) |a, b| try testing.expectEqualDeep(a, b);
    for (mesh.nodes[0..mesh.node_count]) |node| try testing.expect(node.count <= 4);
    const s: physics.Shape = .{ .sphere = .{ .radius = 0.5 } };
    var contacts: [40]physics.Contact = undefined;
    const found = try w.contacts(s, .at(.init(0, 0.2, 0)), .{}, &contacts);
    try testing.expectEqual(@as(u32, 32), found.total);
    for (contacts[0..found.count], 0..) |c, i| {
        try testing.expectEqual(@as(u32, @intCast(i % 16)), c.triangle);
        try testing.expectEqual(@as(u64, if (i < 16) 3 else 4), c.user);
        const tri: Convex = .{ .core = .{ .triangle = mesh.triangle(c.triangle) }, .radius = 0, .pose = .identity };
        // Oracle: a separate, flat point-set core (not a public hull, which must have volume).
        const pts = mesh.triangle(c.triangle);
        const flat: Convex = .{ .core = .{ .points = &pts }, .radius = 0, .pose = .identity };
        const query: Convex = .{ .core = .point, .radius = 0.5, .pose = .at(.init(0, 0.2, 0)) };
        try testing.expectApproxEqAbs(physics.narrow.separation(query, flat).distance, -c.depth, 1e-5);
        try expectVec(physics.narrow.separation(query, tri).normal, c.normal, 1e-5);
        const oracle = physics.narrow.cast(.{ .core = .point, .radius = 0.5, .pose = .at(.init(0, 3, 0)) }, .init(0, -6, 0), flat, physics.contact_skin).?;
        const hit = (try w.shapeCast(s, .at(.init(0, 3, 0)), .init(0, -6, 0), .{})).?;
        try testing.expectApproxEqAbs(oracle.fraction, hit.fraction, 1e-5);
        var best_fraction: f32 = 2;
        var best_triangle: u32 = physics.none_triangle;
        for (0..16) |t| {
            const vertices = mesh.triangle(@intCast(t));
            const individual: Convex = .{ .core = .{ .points = &vertices }, .radius = 0, .pose = .identity };
            const individual_hit = physics.narrow.cast(.{ .core = .point, .radius = 0.5, .pose = .at(.init(0, 3, 0)) }, .init(0, -6, 0), individual, physics.contact_skin).?;
            if (individual_hit.fraction < best_fraction) {
                best_fraction = individual_hit.fraction;
                best_triangle = @intCast(t);
            }
        }
        try testing.expect(hit.body.eql(first) and hit.triangle == best_triangle);
    }
    try testing.expectEqual(@as(u32, 32), (try w.contacts(s, .at(.init(0, 0.2, 0)), .{}, contacts[0..1])).total);
    try testing.expectEqual(@as(u32, 32), (try w.contacts(s, .at(.init(0, 0.2, 0)), .{}, &.{})).total);
    var overlaps: [1]physics.Overlap = undefined;
    const found_overlap = try w.overlap(s, .at(.init(0, 0.2, 0)), .{}, &overlaps);
    try testing.expectEqualDeep(physics.Found{ .count = 1, .total = 2 }, found_overlap);
    try testing.expect(overlaps[0].body.eql(first) and overlaps[0].triangle == 0);
    const masked = (try w.raycast(.init(0, 3, 0), .init(0, -1, 0), 6, .{ .mask = 4 })).?;
    try testing.expectEqual(@as(u64, 4), masked.user);
    try testing.expectEqual(@as(u64, 4), (try w.shapeCast(s, .at(.init(0, 3, 0)), .init(0, -6, 0), .{ .ignore = first })).?.user);
    try testing.expect(w.removeBody(gpa, first));
    const reused = try w.addBody(gpa, .{ .shape = .{ .mesh = m }, .user = 5 });
    try testing.expect((try w.raycast(.init(0, 3, 0), .init(0, -1, 0), 6, .{})).?.body.eql(reused));
}

test "mesh: exact ties select the lower body then triangle, not BVH traversal order" {
    var w: World = .empty;
    defer w.deinit(gpa);
    const m = try w.addMesh(gpa, &floor, &.{ 0, 2, 1, 0, 2, 1, 0, 2, 1, 0, 2, 1, 0, 2, 1 });
    const a = try w.addBody(gpa, .{ .shape = .{ .mesh = m } });
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = m } });
    // Reverse the private leaf order: sorting at the query boundary must restore the contract.
    std.mem.reverse(u32, w.meshes.get(m).?.order);
    const ray = (try w.raycast(.init(0, 3, 0), .init(0, -1, 0), 6, .{})).?;
    const cast = (try w.shapeCast(.{ .sphere = .{ .radius = 0.5 } }, .at(.init(0, 3, 0)), .init(0, -6, 0), .{})).?;
    try testing.expect(ray.body.eql(a) and ray.triangle == 0);
    try testing.expect(cast.body.eql(a) and cast.triangle == 0);
}

fn allocationProof(allocator: std.mem.Allocator) !void {
    var w: World = .empty;
    defer w.deinit(allocator);
    const mesh = try w.addMesh(allocator, &floor, &ix);
    _ = try w.addBody(allocator, .{ .shape = .{ .mesh = mesh } });
    try testing.expect((try w.raycast(.init(0, 3, 0), .init(0, -1, 0), 6, .{})) != null);
}

test "mesh: every allocation failure unwinds without leaking geometry" {
    try testing.checkAllAllocationFailures(gpa, allocationProof, .{});
}

test "mesh: core-intersecting capsules and boxes depenetrate toward their centre's side" {
    for (frames) |frame| {
        var w: World = .empty;
        defer w.deinit(gpa);
        const m = try w.addMesh(gpa, &floor, &ix);
        _ = try w.addBody(gpa, .{ .shape = .{ .mesh = m }, .pose = frame });
        for ([_]f32{ -1, 1 }) |side| {
            for ([_]physics.Shape{
                .{ .capsule = .{ .radius = 0.25, .half_height = 0.5 } },
                .{ .box = .{ .half_extents = .init(0.5, 0.5, 0.5) } },
            }, 0..) |s, i| {
                var out: [1]physics.Contact = undefined;
                const pose: Pose = .{ .position = frame.apply(.init(0, 0.2 * side, 0)), .rotation = frame.rotation };
                try testing.expectEqual(@as(u32, 1), (try w.contacts(s, pose, .{}, &out)).total);
                try testing.expectApproxEqAbs(@as(f32, if (i == 0) 0.55 else 0.3), out[0].depth, 0.002);
                try expectVec(frame.applyDirection(.init(0, side, 0)), out[0].normal, 0.003);
            }
        }
    }
}

test "mesh: triangle cores themselves have analytic separation and casts" {
    const pts: [3]Vec3 = .{ floor[0], floor[2], floor[1] };
    for (frames) |frame| {
        const fixed: Convex = .{ .core = .{ .triangle = pts }, .radius = 0, .pose = frame };
        const moving: Convex = .{ .core = .{ .triangle = pts }, .radius = 0, .pose = .{ .position = frame.apply(.init(0, 2, 0)), .rotation = frame.rotation } };
        const sep = physics.narrow.separation(moving, fixed);
        try testing.expectApproxEqAbs(@as(f32, 2), sep.distance, 0.001);
        const hit = physics.narrow.cast(moving, frame.applyDirection(.init(0, -4, 0)), fixed, physics.contact_skin).?;
        try testing.expectApproxEqAbs(@as(f32, (2 - physics.contact_skin) / 4), hit.fraction, 0.0005);
    }
}

test "mesh: a spatially split BVH matches a brute-force oracle including misses and replay" {
    const count = 1024;
    const positions = try gpa.alloc(Vec3, count * 3);
    defer gpa.free(positions);
    const indices = try gpa.alloc(u32, count * 3);
    defer gpa.free(indices);
    for (0..count) |t| {
        const shuffled = (t * 613) % count;
        const x: f32 = @as(f32, @floatFromInt(shuffled % 32)) * 3;
        const z: f32 = @as(f32, @floatFromInt(shuffled / 32)) * 3;
        positions[t * 3] = .init(x, 0, z);
        positions[t * 3 + 1] = .init(x + 1, 0, z);
        positions[t * 3 + 2] = .init(x, 0, z + 1);
        for (0..3) |v| indices[t * 3 + v] = @intCast(t * 3 + v);
    }
    var hashes: [2]u64 = undefined;
    for (&hashes) |*hash| {
        hash.* = 0;
        var w: World = .empty;
        defer w.deinit(gpa);
        const m = try w.addMesh(gpa, positions, indices);
        const frame = frames[1];
        _ = try w.addBody(gpa, .{ .shape = .{ .mesh = m }, .pose = frame });
        const mesh = w.meshes.get(m).?;
        // A whole-mesh query exercises the full scratch capacity and every tree branch.
        const all = mesh.candidates(frame, .{ .min = .init(-1000, -1000, -1000), .max = .init(1000, 1000, 1000) }, w.triangle_scratch);
        try testing.expectEqual(@as(usize, count), all.len);
        for (all, 0..) |t, i| try testing.expectEqual(@as(u32, @intCast(i)), t);
        for (0..40) |q| {
            const local: Vec3 = .init(@as(f32, @floatFromInt(q % 8)) * 12 + (if (q % 2 == 0) @as(f32, 0.2) else 1.8), 3, @as(f32, @floatFromInt(q / 8)) * 12 + 0.2);
            const origin = frame.apply(local);
            const direction = frame.applyDirection(.init(0, -1, 0));
            const ray = (try w.raycast(origin, direction, 6, .{}));
            const moving: Convex = .{ .core = .point, .radius = 0, .pose = .at(origin) };
            var best: ?physics.narrow.Cast = null;
            var best_triangle: u32 = physics.none_triangle;
            for (0..count) |t| {
                const pts = mesh.triangle(@intCast(t));
                const flat: Convex = .{ .core = .{ .points = &pts }, .radius = 0, .pose = frame };
                if (physics.narrow.cast(moving, direction.scale(6), flat, 0)) |hit| {
                    if (best == null or hit.fraction < best.?.fraction) {
                        best = hit;
                        best_triangle = @intCast(t);
                    }
                }
            }
            try testing.expectEqual(best != null, ray != null);
            if (ray) |hit| {
                try testing.expectEqual(best_triangle, hit.triangle);
                try testing.expectApproxEqAbs(best.?.fraction * 6, hit.distance, 0.001);
                // Hash individual fields, not struct padding.
                hash.* ^= core.id.fnv1a64(std.mem.asBytes(&hit.distance));
                hash.* = hash.* *% 1099511628211 ^ hit.triangle;
            }
        }
    }
    try testing.expectEqual(hashes[0], hashes[1]);
}
