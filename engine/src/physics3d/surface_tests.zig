//! Surfaces and one-sided triangles (`collision-extras.md` §6, M37 Step 3).
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const Vec3 = core.math.Vec3;
const t = std.testing;
const gpa = t.allocator;

const grass = core.ContentId.fromString("test:surface.grass");
const stone = core.ContentId.fromString("test:surface.stone");
const wood = core.ContentId.fromString("test:surface.wood");

/// A 4 m square at height `y`, its two triangles wound to face +Y: triangle 0 over x < z, 1 over
/// x > z.
fn square(y: f32) [4]Vec3 {
    return .{ .init(-2, y, -2), .init(-2, y, 2), .init(2, y, 2), .init(2, y, -2) };
}
const square_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

const config: p.CharacterConfig = .{ .radius = 0.3, .height = 1.8, .max_slope = std.math.pi / 4.0, .step_height = 0.35, .snap_distance = 0.3, .max_move = 10 };

test "surfaces: every query reports a triangle's surface, and its body's where the triangle has none" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const pts = square(0);
    const mesh = try w.addMeshWith(gpa, &pts, &square_indices, .{
        .surfaces = &.{ wood, grass },
        .triangle_surfaces = &.{ 1, p.mesh.no_surface },
    });
    const floor = try w.addBody(gpa, .{ .shape = .{ .mesh = mesh }, .surface = stone });
    const crate = try w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = .init(0.5, 0.5, 0.5) } }, .pose = .at(.init(10, 0.5, 0)) });
    try t.expect(w.setSurface(crate, wood));
    try t.expect(!w.setSurface(p.BodyHandle.none, wood));

    // Triangle 0 lies over x < z, and has grass; triangle 1 has none, so its body's stone.
    const down = Vec3.init(0, -1, 0);
    const on_grass = (try w.raycast(.init(-1, 1, 1), down, 5, .{})).?;
    try t.expectEqual(@as(u32, 0), on_grass.triangle);
    try t.expect(on_grass.surface.eql(grass));
    const on_stone = (try w.raycast(.init(1, 1, -1), down, 5, .{})).?;
    try t.expectEqual(@as(u32, 1), on_stone.triangle);
    try t.expect(on_stone.surface.eql(stone));
    try t.expect((try w.raycast(.init(10, 3, 0), down, 5, .{})).?.surface.eql(wood));

    const ball: p.Shape = .{ .sphere = .{ .radius = 0.25 } };
    try t.expect((try w.shapeCast(ball, .at(.init(-1, 1, 1)), .init(0, -2, 0), .{})).?.surface.eql(grass));
    try t.expect((try w.shapeCast(ball, .at(.init(1, 1, -1)), .init(0, -2, 0), .{})).?.surface.eql(stone));
    try t.expect((try w.shapeSweep(ball, .at(.init(1, 1, -1)), .{ .position = .init(1, -1, -1), .rotation = .{ .x = 0, .y = 0.38268343, .z = 0, .w = 0.9238795 } }, .{})).?.surface.eql(stone));

    var contacts: [4]p.Contact = undefined;
    const found = try w.contacts(ball, .at(.init(-1, 0.1, 1)), .{}, &contacts);
    try t.expectEqual(@as(u32, 1), found.count);
    try t.expect(contacts[0].surface.eql(grass));
    var overlaps: [4]p.Overlap = undefined;
    _ = try w.overlap(ball, .at(.init(10, 1.1, 0)), .{}, &overlaps);
    try t.expect(overlaps[0].surface.eql(wood) and overlaps[0].body.eql(crate));

    // The ground a character stands on says what it is made of.
    const c = try w.addCharacter(gpa, config, .init(-1, 0.01, 1), 7);
    var hits: [8]p.Hit = undefined;
    const m = (try w.moveCharacter(gpa, c, .init(0, -0.05, 0), &hits)).?;
    try t.expect(m.grounded);
    try t.expect(m.ground.?.surface.eql(grass));
    try t.expect(m.ground.?.body.eql(floor));
    try t.expect(w.character(c).?.ground.?.surface.eql(grass));
}

test "surfaces: a mesh with none reports none, and its body's alone" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const pts = square(0);
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = try w.addMesh(gpa, &pts, &square_indices) } });
    try t.expect((try w.raycast(.init(0.5, 1, -0.5), .init(0, -1, 0), 5, .{})).?.surface.isNone());
}

test "surfaces: a table past 65,535, an index past its table, and slices of the wrong length are refused" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const pts = square(0);
    const table = try gpa.alloc(core.ContentId, p.mesh.max_surfaces + 1);
    defer gpa.free(table);
    @memset(table, stone);
    try t.expectError(error.InvalidMesh, w.addMeshWith(gpa, &pts, &square_indices, .{ .surfaces = table }));
    // The fullest table is admitted, and its last index reaches its last entry.
    table[p.mesh.max_surfaces - 1] = wood;
    const full = try w.addMeshWith(gpa, &pts, &square_indices, .{ .surfaces = table[0..p.mesh.max_surfaces], .triangle_surfaces = &.{ 0, p.mesh.max_surfaces - 1 } });
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = full } });
    try t.expect((try w.raycast(.init(1, 1, -1), .init(0, -1, 0), 5, .{})).?.surface.eql(wood));

    try t.expectError(error.InvalidMesh, w.addMeshWith(gpa, &pts, &square_indices, .{ .surfaces = &.{grass}, .triangle_surfaces = &.{ 0, 1 } }));
    try t.expectError(error.InvalidMesh, w.addMeshWith(gpa, &pts, &square_indices, .{ .triangle_surfaces = &.{ 0, p.mesh.no_surface } }));
    try t.expectError(error.InvalidMesh, w.addMeshWith(gpa, &pts, &square_indices, .{ .surfaces = &.{grass}, .triangle_surfaces = &.{0} }));
    try t.expectError(error.InvalidMesh, w.addMeshWith(gpa, &pts, &square_indices, .{ .one_sided = &.{true} }));
    try t.expectEqual(@as(u32, 1), w.meshCount());
}

/// A world holding the square at `y` as one body, one-sided or not.
fn slab(w: *p.World, y: f32, one_sided: bool, pose: p.Pose) !p.BodyHandle {
    const pts = square(y);
    const sides = [_]bool{ one_sided, one_sided };
    const mesh = try w.addMeshWith(gpa, &pts, &square_indices, .{ .surfaces = &.{wood}, .triangle_surfaces = &.{ 0, 0 }, .one_sided = &sides });
    return w.addBody(gpa, .{ .shape = .{ .mesh = mesh }, .pose = pose });
}

test "one-sided: a ray and a cast through the back pass, and through the front hit" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try slab(&w, 0, true, .identity);
    const up = Vec3.init(0, 1, 0);
    const down = Vec3.init(0, -1, 0);
    try t.expect(try w.raycast(.init(0.5, -1, 0), up, 5, .{}) == null);
    try t.expectApproxEqAbs(@as(f32, 1), (try w.raycast(.init(0.5, 1, 0), down, 5, .{})).?.distance, 1e-5);
    const ball: p.Shape = .{ .sphere = .{ .radius = 0.25 } };
    try t.expect(try w.shapeCast(ball, .at(.init(0.5, -1, 0)), .init(0, 2, 0), .{}) == null);
    try t.expect(try w.shapeCast(ball, .at(.init(0.5, 1, 0)), .init(0, -2, 0), .{}) != null);
    try t.expect(try w.shapeSweep(ball, .at(.init(0.5, -1, 0)), .at(.init(0.5, 1, 0)), .{}) == null);
    try t.expect(try w.shapeSweep(ball, .at(.init(0.5, 1, 0)), .at(.init(0.5, -1, 0)), .{}) != null);
    // A pole whose centre starts in front, beside the square, rising into its edge from under it:
    // moving out through the back, so it passes.
    const pole: p.Shape = .{ .capsule = .{ .radius = 0.2, .half_height = 1 } };
    try t.expect(try w.shapeCast(pole, .at(.init(3, 0.1, 0)), .init(-2, 0.5, 0), .{}) == null);

    // Two-sided, the same square stops both.
    var both: p.World = .empty;
    defer both.deinit(gpa);
    _ = try slab(&both, 0, false, .identity);
    try t.expect(try both.raycast(.init(0.5, -1, 0), up, 5, .{}) != null);
    try t.expect(try both.shapeCast(ball, .at(.init(0.5, -1, 0)), .init(0, 2, 0), .{}) != null);
    try t.expect(try both.shapeCast(pole, .at(.init(3, 0.1, 0)), .init(-2, 0.5, 0), .{}) != null);
}

test "one-sided: a body's pose turns which way its faces look" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    // A half turn about x: the square now faces down.
    _ = try slab(&w, 0, true, .{ .rotation = .{ .x = 1, .y = 0, .z = 0, .w = 0 } });
    try t.expect(try w.raycast(.init(0.5, 1, 0), .init(0, -1, 0), 5, .{}) == null);
    try t.expect(try w.raycast(.init(0.5, -1, 0), .init(0, 1, 0), 5, .{}) != null);
}

test "one-sided: overlap, contacts and depenetration ignore a face whose plane the centre is behind" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    _ = try slab(&w, 0, true, .identity);
    const ball: p.Shape = .{ .sphere = .{ .radius = 0.25 } };
    var contacts: [4]p.Contact = undefined;
    var overlaps: [4]p.Overlap = undefined;
    try t.expectEqual(@as(u32, 0), (try w.contacts(ball, .at(.init(0.5, -0.1, 0)), .{}, &contacts)).total);
    try t.expectEqual(@as(u32, 0), (try w.overlap(ball, .at(.init(0.5, -0.1, 0)), .{}, &overlaps)).total);
    try t.expectEqual(@as(u32, 1), (try w.contacts(ball, .at(.init(0.5, 0.1, 0)), .{}, &contacts)).total);
    try t.expectEqual(@as(u32, 1), (try w.overlap(ball, .at(.init(0.5, 0.1, 0)), .{}, &overlaps)).total);
    // In front, it is pushed out by the front: up by its depth below the plane, even when a
    // capsule's way out through the back would be shorter.
    try t.expect(contacts[0].normal.sub(.init(0, 1, 0)).length() < 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.15), contacts[0].depth, 1e-5);
    const pole: p.Shape = .{ .capsule = .{ .radius = 0.2, .half_height = 1 } };
    _ = try w.contacts(pole, .at(.init(0.5, 0.05, 0)), .{}, &contacts);
    try t.expect(contacts[0].normal.sub(.init(0, 1, 0)).length() < 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1.15), contacts[0].depth, 1e-5);

    // A capsule whose centre is below the slab, its head through it, is left where it is.
    const c = try w.addCharacter(gpa, config, .init(0.5, -1.2, 0), 0);
    var hits: [8]p.Hit = undefined;
    const m = (try w.moveCharacter(gpa, c, .zero, &hits)).?;
    try t.expect(!m.depenetrated and !m.stuck);
    try t.expectEqual(@as(f32, -1.2), m.feet.y);
}

test "one-sided: a character jumps up through a one-sided slab, and lands on it" {
    for ([_]bool{ true, false }) |one_sided| {
        var w: p.World = .empty;
        defer w.deinit(gpa);
        const floor = square(0);
        _ = try w.addBody(gpa, .{ .shape = .{ .mesh = try w.addMesh(gpa, &floor, &square_indices) } });
        // The ledge is 2.2 m up, over the head of a character standing under it.
        const ledge = try slab(&w, 2.2, one_sided, .at(.init(2, 0, 0)));
        // Well inside its edge: a capsule half through it leaves by the shortest way, which near
        // an edge is sideways.
        const c = try w.addCharacter(gpa, config, .init(1.5, 0, 0), 0);
        var hits: [8]p.Hit = undefined;
        var ceiling = false;
        for (0..35) |_| {
            const m = (try w.moveCharacter(gpa, c, .init(0, 0.1, 0), &hits)).?;
            ceiling = ceiling or m.ceiling;
        }
        var last: p.CharacterMove = undefined;
        for (0..40) |_| last = (try w.moveCharacter(gpa, c, .init(0, -0.1, 0), &hits)).?;
        if (one_sided) {
            // Up through it, unhindered, and down onto it.
            try t.expect(!ceiling);
            try t.expect(last.grounded);
            try t.expect(last.ground.?.body.eql(ledge));
            try t.expect(last.ground.?.surface.eql(wood));
            try t.expectApproxEqAbs(@as(f32, 2.2), last.feet.y, 0.01);
            try t.expectApproxEqAbs(@as(f32, 1.5), last.feet.x, 1e-4);
        } else {
            // Two-sided, it is a ceiling, and the character comes back down to the floor.
            try t.expect(ceiling);
            try t.expect(last.grounded);
            try t.expectApproxEqAbs(@as(f32, 0), last.feet.y, 0.01);
        }
    }
}

test "one-sided: a one-sided wall lets a character through one way only" {
    var w: p.World = .empty;
    defer w.deinit(gpa);
    const floor = square(0);
    _ = try w.addBody(gpa, .{ .shape = .{ .mesh = try w.addMesh(gpa, &floor, &square_indices) } });
    // The square stood up at x = 0, facing −x: a quarter turn about z takes +Y to −X.
    const r = std.math.sqrt1_2;
    _ = try slab(&w, 0, true, .{ .position = .init(0, 1, 0), .rotation = .{ .x = 0, .y = 0, .z = r, .w = r } });
    var hits: [8]p.Hit = undefined;
    // From +x, behind it, the character walks through to −x.
    const c = try w.addCharacter(gpa, config, .init(1, 0, 0), 0);
    for (0..20) |_| _ = (try w.moveCharacter(gpa, c, .init(-0.1, 0, 0), &hits)).?;
    const through = w.body(w.character(c).?.body).?.pose.position.x;
    try t.expect(through < -0.5);
    // Back the other way, it meets the wall's front and stops a radius short.
    for (0..20) |_| _ = (try w.moveCharacter(gpa, c, .init(0.1, 0, 0), &hits)).?;
    const stopped = w.body(w.character(c).?.body).?.pose.position.x;
    try t.expect(stopped < -0.29 and stopped > -0.32);
}
