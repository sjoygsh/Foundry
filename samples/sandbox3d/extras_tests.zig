//! M37's corner from the compiled package an install ships (`collision-extras.md` §11, §16):
//! M23's five stages keep their pin with the corner's ground in the walk world, the corner's six
//! pass after them and replay byte for byte, and the tilted tour matches the upright one.
const std = @import("std");
const app = @import("app");
const core = @import("core");
const asset = @import("asset");
const physics = @import("physics3d");
const render3d = @import("render3d");
const Walk = @import("walk.zig").Walk;
const Tour = @import("tour.zig").Tour;
const extras_mod = @import("extras.zig");
const Extras = extras_mod.Extras;
const corner_tour = @import("corner_tour.zig");
const CornerTour = corner_tour.CornerTour;
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
    return engine;
}

/// A walk and its corner, turned by `frame`, and both tours run in it.
const Run = struct {
    walk: Walk,
    extras: Extras,
    tour: Tour = .{ .emit = false },
    corner: CornerTour = .{ .emit = false },

    fn init(self: *Run, engine: *app.Engine, frame: core.math.Quat) !void {
        self.* = .{ .walk = Walk.init(testing.allocator), .extras = .{ .frame = frame } };
        self.walk.frame = frame;
        self.walk.refresh(&engine.store, &engine.assets, dt);
        self.extras.refresh(testing.allocator, &engine.store, &self.walk.world, &engine.assets, null);
        if (self.extras.settings == null) return error.NoCorner;
        while (!self.tour.done()) try self.tour.advance(&self.walk, dt);
        while (!self.corner.done()) try self.corner.advance(&self.walk, &self.extras, dt);
    }
    fn deinit(self: *Run, engine: *app.Engine) void {
        self.extras.deinit(testing.allocator, &self.walk.world, &engine.assets, null);
        self.walk.deinit(&engine.assets);
    }
};

test "extras: M23's five stages keep their pin beside the corner, whose six pass and replay byte for byte" {
    if (comptime !options.available) return error.SkipZigTest;
    const engine = try engineInit();
    defer engine.deinit();
    const first = try testing.allocator.create(Run);
    defer testing.allocator.destroy(first);
    try first.init(engine, .identity);
    defer first.deinit(engine);
    try testing.expectEqual(@as(usize, 3), first.walk.settings.?.len);
    try testing.expect(first.tour.failed == null);
    try testing.expectEqual(@as(u64, 0xb85b52c97d259db4), first.tour.hash);
    try testing.expect(first.corner.failed == null);
    try testing.expectEqual(CornerTour.names.len, first.corner.stage);
    try testing.expectEqual(@as(u64, 0xe2992f93e5323345), first.corner.hash);
    const second = try testing.allocator.create(Run);
    defer testing.allocator.destroy(second);
    try second.init(engine, .identity);
    defer second.deinit(engine);
    try testing.expectEqual(first.corner.hash, second.corner.hash);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(first.corner.trace[0..first.corner.len]), std.mem.sliceAsBytes(second.corner.trace[0..second.corner.len]));
}

test "extras: the tilted tour, its world and up turned, matches the upright one every tick" {
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
    try testing.expect(tilted.walk.world.up.sub(corner_tour.tilt().rotate(.up)).length() < 1e-6);
    const five = corner_tour.compare(upright.tour.trace[0..upright.tour.len], tilted.tour.trace[0..tilted.tour.len], 5e-3);
    const six = corner_tour.compare(upright.corner.trace[0..upright.corner.len], tilted.corner.trace[0..tilted.corner.len], 5e-3);
    try testing.expect(five.matches and six.matches);
    try testing.expect(tilted.tour.failed == null and tilted.corner.failed == null);
}

test "extras: the corner's ground is version 2, the rock collides as its scaled proxy, and every piece is drawn" {
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
    var extras: Extras = .{};
    defer extras.deinit(gpa, &walk.world, &engine.assets, &content);
    extras.refresh(gpa, &engine.store, &walk.world, &engine.assets, &content);
    try testing.expect(extras.settings != null);
    // Stone underfoot in the corner, by the triangle's surface; wood on the ledge from above, and
    // nothing from below, where it is one-sided.
    const stone = core.ContentId.fromString("sandbox3d:surface.stone");
    const wood = core.ContentId.fromString("sandbox3d:surface.wood");
    const down = try walk.world.raycast(extras_mod.origin.add(.init(2, 0.5, 0)), .init(0, -1, 0), 1, .{});
    try testing.expect(down.?.surface.eql(stone));
    const onto = try walk.world.raycast(extras_mod.ledge_centre.add(.init(0, 0.5, 0)), .init(0, -1, 0), 1, .{});
    try testing.expect(onto.?.surface.eql(wood));
    const under = try walk.world.raycast(extras_mod.ledge_centre.add(.init(0, -0.5, 0)), .init(0, 1, 0), 1, .{});
    try testing.expect(under == null);
    try testing.expectEqualStrings("stone", extras_mod.surfaceName(&engine.store, stone));
    try testing.expectEqualStrings("none", extras_mod.surfaceName(&engine.store, .none));
    // The rock: its proxy's 24 triangles at scale 1.5, and its drawn model far denser.
    const rock = walk.world.body(extras.rock).?;
    try testing.expectEqual(@as(usize, 24), extras.rock_triangles);
    try testing.expectEqualDeep(Vec3.init(1.5, 1.5, 1.5), rock.scale);
    const face = try walk.world.raycast(.init(-20, 0.3, 0), .init(0, 0, 1), 5, .{});
    try testing.expect(face.?.body.eql(extras.rock));
    try testing.expectApproxEqAbs(@as(f32, 3 - 1.5 * 0.47), face.?.point.z, 1e-4);
    try testing.expect(face.?.surface.eql(stone));
    // Moving pieces are kinematic, and the crate alone is pushed.
    try testing.expectEqual(physics.BodyKind.kinematic, walk.world.body(extras.lift).?.kind);
    try testing.expectEqual(@as(f32, 0.5), walk.world.body(extras.crate).?.push);
    try testing.expectEqual(@as(f32, 0), walk.world.body(extras.door).?.push);
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 64, .height = 64 } });
    extras.draw(&walk.world, &content);
    try testing.expect(!extras.reported);
    try testing.expect(renderer.draws.items.len >= 5);
}
