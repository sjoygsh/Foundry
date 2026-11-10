//! M38's yard from the compiled package an install ships (`collision-scale.md` §11, §14): the
//! hillside arrives with its baked tree and the boulder as its hull, the stage passes and replays
//! byte for byte, and the tilted stage matches the upright one.
const std = @import("std");
const app = @import("app");
const core = @import("core");
const asset = @import("asset");
const physics = @import("physics3d");
const render3d = @import("render3d");
const Walk = @import("walk.zig").Walk;
const yard_mod = @import("yard.zig");
const Yard = yard_mod.Yard;
const YardTour = @import("yard_tour.zig").YardTour;
const corner_tour = @import("corner_tour.zig");
const options = @import("walk_test_options");
const testing = std.testing;
const Vec3 = core.math.Vec3;
const dt = core.time.Timestep.fromHz(60).elapsedAt(1).toSecondsF32();

fn engineInit() !*app.Engine {
    const engine = try app.Engine.init(testing.allocator, .{ .headless = true, .workers = 0, .content_dir = options.generated, .content = &.{
        .{ .base_dir = std.fs.path.dirname(options.core_package).?, .file = std.fs.path.basename(options.core_package), .root = "core-assets" },
        .{ .base_dir = std.fs.path.dirname(options.package).?, .file = std.fs.path.basename(options.package), .root = "sandbox3d-assets" },
    } });
    errdefer engine.deinit();
    try engine.assets.registerLoader(testing.allocator, asset.collisionMeshLoader());
    try engine.assets.registerLoader(testing.allocator, asset.collisionHullLoader());
    return engine;
}

/// A walk and its yard, turned by `frame`, and the stage run in it.
const Run = struct {
    walk: Walk,
    yard: Yard,
    tour: YardTour = .{ .emit = false },

    fn init(self: *Run, engine: *app.Engine, frame: core.math.Quat) !void {
        self.* = .{ .walk = Walk.init(testing.allocator), .yard = .{ .frame = frame } };
        self.walk.frame = frame;
        self.walk.refresh(&engine.store, &engine.assets, dt);
        self.yard.refresh(testing.allocator, &engine.store, &self.walk.world, &engine.assets, null, null);
        if (self.yard.settings == null) return error.NoYard;
        while (!self.tour.done()) try self.tour.advance(&self.walk, &self.yard, dt);
    }
    fn deinit(self: *Run, engine: *app.Engine) void {
        self.yard.deinit(testing.allocator, &self.walk.world, &engine.assets, null);
        self.walk.deinit(&engine.assets);
    }
};

test "yard: the stage passes, turned aside and up the boulder's ramp, and replays byte for byte" {
    if (comptime !options.available) return error.SkipZigTest;
    const engine = try engineInit();
    defer engine.deinit();
    const first = try testing.allocator.create(Run);
    defer testing.allocator.destroy(first);
    try first.init(engine, .identity);
    defer first.deinit(engine);
    try testing.expect(first.tour.failed == null);
    try testing.expectEqual(YardTour.names.len, first.tour.stage);
    try testing.expectEqual(@as(u64, 0x1052a9ae891b0d27), first.tour.hash);
    const second = try testing.allocator.create(Run);
    defer testing.allocator.destroy(second);
    try second.init(engine, .identity);
    defer second.deinit(engine);
    try testing.expectEqual(first.tour.hash, second.tour.hash);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(first.tour.trace[0..first.tour.len]), std.mem.sliceAsBytes(second.tour.trace[0..second.tour.len]));
}

test "yard: the tilted stage, its world and up turned, matches the upright one every tick" {
    if (comptime !options.available) return error.SkipZigTest;
    const engine = try engineInit();
    defer engine.deinit();
    const upright = try testing.allocator.create(Run);
    defer testing.allocator.destroy(upright);
    try upright.init(engine, .identity);
    defer upright.deinit(engine);
    const tilted = try testing.allocator.create(Run);
    defer testing.allocator.destroy(tilted);
    try tilted.init(engine, corner_tour.tilt());
    defer tilted.deinit(engine);
    // M37's corner holds 5 mm on its flat stages. Down the hillside, a tick that snaps the feet to
    // the ground in one world falls a tick in the other, a centimetre at most, and the two meet
    // again within a few ticks: so 15 mm on any tick, and 2 mm where it ends.
    const match = corner_tour.compare(upright.tour.trace[0..upright.tour.len], tilted.tour.trace[0..tilted.tour.len], 15e-3);
    try testing.expect(match.matches);
    const last = upright.tour.len - 1;
    try testing.expect(upright.tour.trace[last].sub(tilted.tour.trace[last]).length() <= 2e-3);
    try testing.expect(tilted.tour.failed == null);
    // The tilted hillside still carries its tree: the body is turned, not the triangles.
    try testing.expectEqual(@as(u32, 1), tilted.walk.world.report().meshes_baked);
}

test "yard: the hillside arrives with its tree, the boulder as its hull, and every piece is drawn" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    const engine = try engineInit();
    defer engine.deinit();
    var renderer = try render3d.Renderer.init(gpa, engine.gpu, .{ .cull = false });
    defer renderer.deinit();
    var content = render3d.Content.init(gpa, &renderer, &engine.assets, .default);
    defer content.deinit();
    var walk = Walk.init(gpa);
    defer walk.deinit(&engine.assets);
    walk.refresh(&engine.store, &engine.assets, dt);
    var yard: Yard = .{};
    defer yard.deinit(gpa, &walk.world, &engine.assets, &content);
    yard.refresh(gpa, &engine.store, &walk.world, &engine.assets, &content, null);
    const s = yard.settings orelse return error.NoYard;

    // The hillside: 32,258 triangles from a version 3 `.fcol`, taken with its tree.
    try testing.expectEqual(@as(usize, 32_258), yard.triangles);
    const report = walk.world.report();
    try testing.expectEqual(@as(u32, 1), report.meshes_baked);
    try testing.expectEqual(@as(usize, 2048), yard.stones.items.len);
    try testing.expectEqual(@as(usize, 64), yard.movers.items.len);
    try testing.expect(report.bodies_static + report.bodies_kinematic >= 2100);

    // The boulder: its hull's corners, the inside point left out, and the ramp a face 20° from up.
    try testing.expectEqual(@as(usize, 16), yard.hull_points.len);
    const ramp_mid = yard.point(yard_mod.boulderPose().position.add(.init(1.25, 2, 0)));
    const down = try walk.world.raycast(ramp_mid, .init(0, -1, 0), 4, .{});
    try testing.expect(down.?.body.eql(yard.boulder));
    try testing.expectApproxEqAbs(@as(f32, 20), std.math.radiansToDegrees(std.math.acos(down.?.surface_normal.y)), 0.01);
    try testing.expect(down.?.surface.eql(s.stone_surface));

    // Stones stand on the hillside, sunk a little into it; a ray down the middle lane meets the
    // hillside and nothing else.
    const lane = yard_mod.laneZ(yard_mod.middleLane(s.rows), s.rows);
    const ground = try walk.world.raycast(yard.point(.init(-10, 5, lane)), .init(0, -1, 0), 10, .{});
    try testing.expect(ground.?.body.eql(yard.ground));
    try testing.expect(ground.?.surface.eql(core.ContentId.fromString("sandbox3d:surface.grass")));
    try testing.expectApproxEqAbs(yard_mod.height(-10, lane), ground.?.point.y, 0.05);
    const stone = yard_mod.stoneAt(10, 3, s.rows);
    const on = try walk.world.raycast(yard.point(stone.position.add(.init(0, 2, 0))), .init(0, -1, 0), 4, .{});
    try testing.expect(yard_mod.isStone(on.?.user));

    // A mover is kinematic, moves on its circle, and is drawn with everything else.
    try testing.expectEqual(physics.BodyKind.kinematic, walk.world.body(yard.movers.items[0]).?.kind);
    const before = walk.world.body(yard.movers.items[0]).?.pose.position;
    try yard.step(gpa, &walk.world, null);
    try testing.expect(walk.world.body(yard.movers.items[0]).?.pose.position.sub(before).length() > 0);
    try testing.expect(!yard.stone_mesh.isNone());
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    yard.draw(&walk.world, &content);
    try testing.expect(!yard.reported);
    try testing.expect(renderer.draws.items.len >= 3 + yard.movers.items.len);
}
