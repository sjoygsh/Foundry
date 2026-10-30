//! A rebuilt mesh from the real background pool (`docs/design/agents.md` §13, Step 6). `nav`'s own
//! tests prove adoption under `immediate` and `Manual`; only here is there a pool with threads,
//! because `nav` sits on `core` alone. Its bytes must equal a build on the calling thread's.

const std = @import("std");
const core = @import("core");
const nav = @import("nav");
const platform = @import("platform");

const testing = std.testing;
const Vec3 = core.math.Vec3;

const floor_positions = [_]Vec3{ .init(0, 0, 0), .init(12, 0, 0), .init(12, 0, 12), .init(0, 0, 12) };
const floor_indices = [_]u32{ 0, 2, 1, 0, 3, 2 };
const walker: nav.Config = .{ .agent_radius = 0.3, .agent_height = 1.8, .agent_climb = 0.35, .agent_slope = 0.785398 };

fn same(a: *const nav.Mesh, b: *const nav.Mesh) !void {
    try testing.expectEqual(a.polygons.len, b.polygons.len);
    try testing.expectEqualSlices([3]u16, a.vertices, b.vertices);
    for (a.polygons, b.polygons) |p, q| try testing.expectEqual(p, q);
    try testing.expectEqual(a.detail.vertices.len, b.detail.vertices.len);
    for (a.detail.vertices, b.detail.vertices) |v, w| try testing.expectEqual(v, w);
}

test "a mesh rebuilt on the real pool has the bytes of one built here, and a replay agrees" {
    const gpa = testing.allocator;
    const os = try platform.os.Os.init(gpa, .{});
    defer os.deinit();
    const pool = try os.startBackground(gpa, .{ .count = 2 });
    defer pool.deinit();
    const tasks = pool.tasks();

    var meshes = nav.Meshes.init(gpa, .{});
    defer meshes.deinit(tasks);
    const level: nav.Source = .{ .positions = &floor_positions, .indices = &floor_indices };
    _ = try meshes.add(try nav.build(gpa, walker, &.{level}));

    var box: nav.BoxGeometry = undefined;
    const pose: nav.Pose = .{ .position = .init(6, 1, 6), .rotation = .identity };
    const sources = [_]nav.Source{ level, nav.boxSource(.init(3, 1, 0.2), pose, &box) };
    meshes.markDirty();
    try meshes.start(tasks, walker, &sources, .{});
    var arrival: ?nav.Arrival = null;
    while (arrival == null) arrival = meshes.pump();
    const generation = arrival.?.generation;
    var direct = try nav.build(gpa, walker, &sources);
    defer direct.deinit(gpa);
    try same(&direct, meshes.get(generation).?);

    // A run adopting at the tick it arrived, and its replay from the recorded tick.
    const Run = struct {
        fn hash(mesh_a: *const nav.Mesh, mesh_b: *const nav.Mesh, adopt: u32) !u64 {
            var crowd = try nav.Crowd.init(testing.allocator, .{});
            defer crowd.deinit();
            crowd.setMesh(mesh_a);
            const a = try crowd.add(.{ .radius = 0.3, .height = 1.8, .speed = 2, .acceleration = 8 }, .init(6, 0, 2));
            _ = crowd.setTarget(a, .init(6, 0, 10));
            for (0..600) |t| {
                if (t == adopt) crowd.setMesh(mesh_b);
                crowd.step(1.0 / 60.0);
            }
            return crowd.hash();
        }
    };
    const first = try Run.hash(meshes.get(1).?, meshes.get(generation).?, 90);
    try testing.expectEqual(first, try Run.hash(meshes.get(1).?, meshes.get(generation).?, 90));
}
