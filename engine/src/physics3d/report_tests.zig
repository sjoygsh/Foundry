//! The report and its counters (`collision-scale.md` §3, M38 Step 1).
const std = @import("std");
const core = @import("core");
const p = @import("root.zig");
const Vec3 = core.math.Vec3;
const t = std.testing;
const gpa = t.allocator;

const config: p.CharacterConfig = .{ .radius = 0.3, .height = 1.8, .max_slope = std.math.pi / 4.0, .step_height = 0.35, .snap_distance = 0.3, .max_move = 10 };

fn box(w: *p.World, centre: Vec3, half: Vec3, kind: p.BodyKind) !p.BodyHandle {
    return w.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = half } }, .pose = .at(centre), .kind = kind });
}

/// A floor of two triangles, two static boxes, a kinematic box, a hull nobody names and a character.
const Yard = struct {
    w: p.World = .empty,
    character: p.CharacterHandle = .none,

    fn init(self: *Yard) !void {
        const positions = [_]Vec3{ .init(-10, 0, -10), .init(10, 0, -10), .init(10, 0, 10), .init(-10, 0, 10) };
        const indices = [_]u32{ 0, 2, 1, 0, 3, 2 };
        const ground = try self.w.addMesh(gpa, &positions, &indices);
        _ = try self.w.addBody(gpa, .{ .shape = .{ .mesh = ground }, .kind = .static });
        _ = try box(&self.w, .init(5, 0.5, 0), .init(0.5, 0.5, 0.5), .static);
        _ = try box(&self.w, .init(-5, 0.5, 0), .init(0.5, 0.5, 0.5), .static);
        _ = try box(&self.w, .init(0, 0.5, 5), .init(0.5, 0.5, 0.5), .kinematic);
        const corners = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1) };
        _ = try self.w.addHull(gpa, &corners);
        self.character = try self.w.addCharacter(gpa, config, .init(0, 0.01, 0), 0);
    }
};

test "report: the counts are what the world holds" {
    var y: Yard = .{};
    defer y.w.deinit(gpa);
    try t.expectEqual(p.Report{}, y.w.report());
    try y.init();
    const r = y.w.report();
    try t.expectEqual(@as(u32, 3), r.bodies_static);
    // The box, and the character's own body.
    try t.expectEqual(@as(u32, 2), r.bodies_kinematic);
    try t.expectEqual(@as(u32, 1), r.characters);
    try t.expectEqual(@as(u32, 1), r.meshes);
    try t.expectEqual(@as(u64, 2), r.triangles);
    try t.expectEqual(@as(u32, 1), r.hulls);
    // What later steps fill, and nothing fills yet.
    try t.expectEqual(@as(u32, 0), r.meshes_baked + r.hull_faces + r.tree_nodes + r.tree_height + r.pairs_closed + r.refits);
}

test "report: each query is counted by its kind, with the bodies and triangles it tested" {
    var y: Yard = .{};
    defer y.w.deinit(gpa);
    try y.init();
    _ = y.w.takeCounters();
    const ball: p.Shape = .{ .sphere = .{ .radius = 0.25 } };

    // Straight down onto the floor, far from every box: five bodies are visited and their
    // bounds tested, and only the floor's two triangles reach the narrowphase.
    try t.expect((try y.w.raycast(.init(2, 3, 2), .init(0, -1, 0), 10, .{})) != null);
    var r = y.w.report();
    try t.expectEqual(@as(u32, 1), r.count(.ray));
    try t.expectEqual(@as(u32, 5), r.bodies_visited);
    try t.expectEqual(@as(u32, 5), r.bodies_tested);
    try t.expectEqual(@as(u32, 2), r.triangles_tested);
    try t.expectEqual(@as(u32, 2), r.pairs_gjk);

    // A mask that admits nothing visits every body and tests none.
    _ = y.w.takeCounters();
    try t.expect((try y.w.raycast(.init(2, 3, 2), .init(0, -1, 0), 10, .{ .mask = 0 })) == null);
    r = y.w.report();
    try t.expectEqual(@as(u32, 5), r.bodies_visited);
    try t.expectEqual(@as(u32, 0), r.bodies_tested);
    try t.expectEqual(@as(u32, 0), r.pairs_gjk);

    // A ball inside a box is one pair, and no triangle.
    _ = y.w.takeCounters();
    var overlaps: [4]p.Overlap = undefined;
    try t.expectEqual(@as(u32, 1), (try y.w.overlap(ball, .at(.init(5, 0.5, 0)), .{}, &overlaps)).total);
    var contacts: [4]p.Contact = undefined;
    _ = try y.w.contacts(ball, .at(.init(5, 0.5, 0)), .{}, &contacts);
    _ = try y.w.shapeCast(ball, .at(.init(2, 3, 2)), .init(0, -5, 0), .{});
    _ = try y.w.shapeSweep(ball, .at(.init(2, 3, 2)), .{ .position = .init(2, 1, 2), .rotation = core.math.Quat.fromAxisAngle(.init(0, 1, 0), 1) }, .{});
    var hits: [8]p.Hit = undefined;
    _ = try y.w.moveCharacter(gpa, y.character, .init(0.1, -0.01, 0), &hits);
    r = y.w.report();
    try t.expectEqual(@as(u32, 0), r.count(.ray));
    inline for (.{ .overlap, .contacts, .cast, .sweep, .move }) |kind| try t.expectEqual(@as(u32, 1), r.count(kind));
    try t.expect(r.pairs_gjk > r.triangles_tested and r.triangles_tested > 0);

    // A refused query counts nothing.
    _ = y.w.takeCounters();
    try t.expectError(error.InvalidQuery, y.w.raycast(.zero, .init(0, 2, 0), 1, .{}));
    try t.expectError(error.InvalidShape, y.w.overlap(.{ .sphere = .{ .radius = -1 } }, .identity, .{}, &overlaps));
    try t.expectError(error.InvalidMove, y.w.moveCharacter(gpa, y.character, .init(100, 0, 0), &hits));
    try t.expectEqual(p.Counters{}, y.w.takeCounters());
}

test "report: taking the counters returns them and leaves zero, and the counts stay" {
    var y: Yard = .{};
    defer y.w.deinit(gpa);
    try y.init();
    _ = y.w.takeCounters();
    _ = try y.w.raycast(.init(2, 3, 2), .init(0, -1, 0), 10, .{});
    _ = try y.w.raycast(.init(2, 3, 2), .init(0, -1, 0), 10, .{});
    const taken = y.w.takeCounters();
    try t.expectEqual(@as(u32, 2), taken.queries[@intFromEnum(p.QueryKind.ray)]);
    try t.expectEqual(@as(u32, 10), taken.bodies_tested);
    try t.expectEqual(p.Counters{}, y.w.takeCounters());
    const r = y.w.report();
    try t.expectEqual(@as(u32, 0), r.count(.ray));
    try t.expectEqual(@as(u32, 3), r.bodies_static);
    // A game's own tick, put back into a report.
    try t.expectEqual(@as(u32, 2), r.withCounters(taken).count(.ray));
}

test "report: counting changes no answer, and two worlds asked alike count alike" {
    var a: Yard = .{};
    defer a.w.deinit(gpa);
    try a.init();
    var b: Yard = .{};
    defer b.w.deinit(gpa);
    try b.init();
    var hits: [8]p.Hit = undefined;
    for (0..120) |i| {
        const by: Vec3 = .init(0.03, -0.01, if (i < 60) 0.02 else -0.02);
        const ma = (try a.w.moveCharacter(gpa, a.character, by, &hits)).?;
        // One world's counters are taken every tick and the other's never.
        _ = a.w.takeCounters();
        const mb = (try b.w.moveCharacter(gpa, b.character, by, &hits)).?;
        try t.expectEqualSlices(u8, std.mem.asBytes(&ma.feet), std.mem.asBytes(&mb.feet));
    }
    var c: Yard = .{};
    defer c.w.deinit(gpa);
    try c.init();
    for (0..120) |i| _ = try c.w.moveCharacter(gpa, c.character, .init(0.03, -0.01, if (i < 60) 0.02 else -0.02), &hits);
    try t.expectEqual(b.w.report(), c.w.report());
}
