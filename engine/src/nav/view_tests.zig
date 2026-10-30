//! The view and the report (`agents.md` §10, Step 7).

const std = @import("std");
const core = @import("core");

const config_mod = @import("config.zig");
const crowd_mod = @import("crowd.zig");
const features = @import("features.zig");
const meshes_mod = @import("meshes.zig");
const poly = @import("poly.zig");
const report_mod = @import("report.zig");
const scenes = @import("scenes.zig");
const view = @import("view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Crowd = crowd_mod.Crowd;
const Features = features.Features;
const Mesh = poly.Mesh;
const Vec3 = core.math.Vec3;
const walker = config_mod.walker;
const dt: f32 = 1.0 / 60.0;

const params: crowd_mod.AgentParams = .{ .radius = 0.3, .height = 1.8, .speed = 2, .acceleration = 8 };

const links = [_]features.LinkInput{
    .{ .kind = .jump, .from = .init(1, 0, 1), .to = .init(4.5, 0, 2.5), .arc = 1 },
    .{ .kind = .ladder, .from = .init(1, 0, 1), .to = .init(2.7, 0.6, 2.5), .two_way = true },
    .{ .kind = .drop, .from = .init(2.7, 0.6, 2.5), .to = .init(4.5, 0, 2.5) },
};
const marked: Features = .{
    .costs = &.{ 1, 4 },
    .volumes = &.{.{ .area = 1, .min = .init(3.5, -0.5, 0.5), .max = .init(5.5, 0.5, 1.8) }},
    .links = &links,
};

fn writeView(m: *const Mesh) ![]view.ViewVertex {
    const out = try gpa.alloc(view.ViewVertex, view.debugViewCount(m));
    errdefer gpa.free(out);
    const written = view.debugView(m, out);
    try testing.expectEqual(out.len, written.len);
    return out;
}

test "the view counts every link's arc, and draws it high above the ends" {
    var scene: scenes.Scene = .{};
    scene.course();
    var plain = try poly.build(gpa, walker, scene.sources());
    defer plain.deinit(gpa);
    var m = try poly.buildWith(gpa, walker, scene.sources(), .{ .links = &links });
    defer m.deinit(gpa);
    try testing.expectEqual(view.debugViewCount(&plain) + 3 * 8 * 6, view.debugViewCount(&m));
    const out = try writeView(&m);
    defer gpa.free(out);
    // The jump's last strips are the last link's predecessor: find its peak among them all.
    var top: f32 = 0;
    for (out[out.len - 3 * 8 * 6 ..]) |v| top = @max(top, v.position.y);
    try testing.expectApproxEqAbs(@as(f32, 1.0), top, 0.1);
}

test "a marked floor is drawn in its area's colour, an unmarked one in its region's" {
    var scene: scenes.Scene = .{};
    scene.course();
    var plain = try poly.build(gpa, walker, scene.sources());
    defer plain.deinit(gpa);
    var m = try poly.buildWith(gpa, walker, scene.sources(), marked);
    defer m.deinit(gpa);
    const plain_view = try writeView(&plain);
    defer gpa.free(plain_view);
    const m_view = try writeView(&m);
    defer gpa.free(m_view);
    var strong: u32 = 0;
    for (m_view) |v| strong += @intFromBool(v.color[3] == 0.7);
    for (plain_view) |v| try testing.expect(v.color[3] != 0.7);
    try testing.expect(strong >= 3);
    for (m_view) |v| {
        try testing.expect(v.position.isFinite());
        // Premultiplied.
        for (v.color[0..3]) |c| try testing.expect(c <= v.color[3] + 1e-6);
    }
}

test "an agent's path and its target are drawn, in red when blocked, and nothing when idle" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 12), false);
    scene.box(.init(5, 0, 0), .init(6, 2, 9));
    var m = try poly.build(gpa, walker, scene.sources());
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{ .blocked_ticks = 5 });
    defer crowd.deinit();
    crowd.setMesh(&m);
    const start: Vec3 = .init(2, 0, 3);
    const a = try crowd.add(params, start);
    const out = try gpa.alloc(view.ViewVertex, view.debugAgentsCount(&crowd));
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 0), view.debugAgents(&crowd, out).len);
    _ = crowd.setTarget(a, .init(10, 0, 3));
    crowd.step(dt);
    const written = view.debugAgents(&crowd, out);
    // At least the two legs round the wall, and the ring's eight sides.
    try testing.expect(written.len >= (2 + 8) * 6);
    var far: f32 = 0;
    for (written) |v| {
        try testing.expect(v.position.isFinite());
        far = @max(far, v.position.z);
        try testing.expectEqual(@as(f32, 0.8), v.color[3]);
    }
    // The path goes round the wall's end, past z 9.
    try testing.expect(far > 9);
    for (0..8) |_| {
        crowd.step(dt);
        crowd.place(a, start);
    }
    try testing.expectEqual(crowd_mod.AgentState.blocked, crowd.agent(a).?.state);
    const blocked = view.debugAgents(&crowd, out);
    try testing.expectEqual(@as(f32, 0.9), blocked[0].color[3]);
}

test "the most a view of agents can write fits what its count says" {
    var scene: scenes.Scene = .{};
    scene.yard();
    var m = try poly.build(gpa, walker, scene.sources());
    defer m.deinit(gpa);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(&m);
    for (0..8) |i| {
        const a = try crowd.add(params, .init(2 + @as(f32, @floatFromInt(i)) * 1.5, 0, 2));
        _ = crowd.setTarget(a, .init(27, 0, 18));
    }
    crowd.step(dt);
    const out = try gpa.alloc(view.ViewVertex, view.debugAgentsCount(&crowd));
    defer gpa.free(out);
    try testing.expect(view.debugAgents(&crowd, out).len <= out.len);
}

test "a report reads a mesh, its generations and a crowd" {
    var scene: scenes.Scene = .{};
    scene.course();
    var meshes = meshes_mod.Meshes.init(gpa, .{});
    defer meshes.deinit(core.tasks.immediate);
    const generation = try meshes.add(try poly.buildWith(gpa, walker, scene.sources(), marked));
    const m = meshes.get(generation).?;
    meshes.markDirty();
    try meshes.start(core.tasks.immediate, walker, scene.sources(), marked);
    try testing.expectEqual(@as(u32, 2), meshes.pump().?.generation);
    var crowd = try Crowd.init(gpa, .{});
    defer crowd.deinit();
    crowd.setMesh(m);
    const a = try crowd.add(params, .init(5, 0, 3.5));
    _ = try crowd.add(params, .init(1.5, 0, 5));
    _ = crowd.setTarget(a, .init(5, 0, 5));
    crowd.step(dt);

    var r: report_mod.Report = .{};
    r.readMesh(m);
    r.readMeshes(&meshes, 2);
    r.readCrowd(&crowd);
    try testing.expect(r.has_mesh);
    try testing.expectEqual(@as(u32, @intCast(m.polygons.len)), r.polygons);
    try testing.expectEqual(m.islands, r.islands);
    try testing.expectEqual(@as(u32, 3), r.links);
    try testing.expectEqual(@as(u32, 2), r.area_count);
    try testing.expect(r.area_m2[1] > 1 and r.area_m2[1] < 3);
    try testing.expectApproxEqAbs(@as(f32, @floatCast(m.area())), r.area_m2[0] + r.area_m2[1], 0.01);
    try testing.expectEqual(@as(u32, 2), r.generation);
    try testing.expectEqual(@as(u32, 1), r.rebuilds);
    try testing.expect(!r.building);
    try testing.expectEqual(@as(u32, 2), r.agents);
    try testing.expectEqual(@as(u32, 1), r.agents_in[@intFromEnum(crowd_mod.AgentState.walking)]);
    try testing.expectEqual(@as(u32, 1), r.agents_in[@intFromEnum(crowd_mod.AgentState.idle)]);
    try testing.expectEqual(@as(u32, 1), r.searches_this_tick);
    try testing.expectEqual(@as(u32, 1), r.searches_most);
    try testing.expectEqual(@as(u64, 1), r.searches_total);
}
