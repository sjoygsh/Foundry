//! M41's scenery (`scenery.zig`): the shipped record as the sample reads it, the room's walls
//! choosing the environment, each refusal, and the sphere facing out.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const scenery = @import("scenery.zig");
const Settings = scenery.Settings;
const Vec3 = core.math.Vec3;
const testing = std.testing;

const shipped = @embedFile("content/scenery.fdt");

/// Compiles `source` as the sample's package and reads `sandbox3d:scenery.main` from it.
fn readSource(source: []const u8) !Settings {
    const gpa = testing.allocator;
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    try asset.schemas.registerAll(gpa, &schemas);
    var doc = try data.parser.parse(gpa, "scenery.fdt", source, .{ .namespace = "sandbox3d" }, &diags);
    defer doc.deinit(gpa);
    var pkg = try data.check.Package.init(gpa, "sandbox3d:content", 1, .default);
    defer pkg.deinit(gpa);
    try pkg.addDocument(gpa, &doc, &schemas, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &pkg, &schemas, &bytes);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    _ = try store.add(gpa, "sandbox3d:content", bytes.items, &schemas, &diags);
    return Settings.read(store.lookup(scenery.record_id).?.fields);
}

fn id(text: []const u8) core.ContentId {
    return core.ContentId.fromString(text);
}

test "the shipped scenery names both environments, fourteen sphere materials and the lamp" {
    const s = try readSource(shipped);
    try testing.expect(s.outdoors.eql(id("sandbox3d:environments.day")));
    try testing.expect(s.indoors.eql(id("sandbox3d:environments.room")));
    try testing.expect(s.lamp.eql(id("sandbox3d:models.lamp")));
    try testing.expect(s.dielectric[0].eql(id("sandbox3d:materials.sphere.d0")));
    try testing.expect(s.metal[6].eql(id("sandbox3d:materials.sphere.m6")));
    try testing.expectEqual(@as(f32, 0.35), s.sphere_radius);
    // Both rows stand on the strip of hillside west of the yard's first stones (x 38 to 41).
    for (0..2) |row| for (0..scenery.row_len) |i| {
        const at = s.sphereAt(row, i);
        try testing.expect(at.x > 38 and at.x < 41 and @abs(at.z) <= 3);
    };
}

test "the camera inside the room's walls is indoors, and anywhere else outdoors" {
    const s = try readSource(shipped);
    // The player standing in the room, and at its walls' very edge.
    try testing.expect(s.environmentFor(.init(0, 1.6, 0)).eql(s.indoors));
    try testing.expect(s.environmentFor(.init(2.9, 1.6, -2.9)).eql(s.indoors));
    // The orbit, outside the walls; above the room; the yard; M37's corner.
    try testing.expect(s.environmentFor(.init(4, 2.4, 0)).eql(s.outdoors));
    try testing.expect(s.environmentFor(.init(0, 3.5, 0)).eql(s.outdoors));
    try testing.expect(s.environmentFor(.init(70, 1.6, 0)).eql(s.outdoors));
    try testing.expect(s.environmentFor(.init(-20, 1.6, 0)).eql(s.outdoors));
    // A record without one has none there.
    const without = try std.mem.replaceOwned(u8, testing.allocator, shipped, "    indoors  sandbox3d:environments.room\n", "");
    defer testing.allocator.free(without);
    try testing.expect((try readSource(without)).environmentFor(.init(0, 1.6, 0)).isNone());
}

test "a scenery record out of bounds is refused whole" {
    const changes = [_][2][]const u8{
        .{ "sphere_radius 0.35", "sphere_radius 0" },
        .{ "sphere_radius 0.35", "sphere_radius 3" },
        .{ "lamp_yaw 3.1416", "lamp_yaw 3.1416 indoors_half 0" },
        .{ "lamp_yaw 3.1416", "lamp_yaw 3.1416 indoors_height -1" },
        .{ "lamp_position { x -17 y 0 z 2.5 }", "lamp_position { x -17 y 0 z 2500 }" },
        .{ "sphere_step   { x 0 y 0 z 1 }", "sphere_step   { x 0 y 0 z 1e30 }" },
        // A row one short, and one long.
        .{ "        sandbox3d:materials.sphere.d6\n", "" },
        .{ "        sandbox3d:materials.sphere.d6\n", "        sandbox3d:materials.sphere.d6 sandbox3d:materials.sphere.d5\n" },
    };
    for (changes) |change| {
        const bad = try std.mem.replaceOwned(u8, testing.allocator, shipped, change[0], change[1]);
        defer testing.allocator.free(bad);
        try testing.expect(!std.mem.eql(u8, bad, shipped));
        try testing.expectError(error.InvalidScenery, readSource(bad));
    }
}

test "the sphere's every vertex is on it, its normals point out, and its triangles face out" {
    var sphere = try scenery.sphereGeometry(testing.allocator, 0.35);
    defer sphere.deinit(testing.allocator);
    const positions = sphere.positions.items;
    const normals = sphere.normals.items;
    const indices = sphere.indices.items;
    try testing.expectEqual(@as(usize, 17 * 33), positions.len);
    try testing.expectEqual(@as(usize, 16 * 32 * 6), indices.len);
    for (positions, normals) |p, n| {
        try testing.expectApproxEqAbs(@as(f32, 0.35), p.length(), 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 1), n.length(), 1e-5);
        try testing.expect(p.dot(n) > 0);
    }
    // Counter-clockwise seen from outside is the pipeline's front: each triangle that is not
    // degenerate at a pole has its face normal pointing away from the centre.
    var facing: usize = 0;
    var i: usize = 0;
    while (i < indices.len) : (i += 3) {
        const a = positions[indices[i]];
        const b = positions[indices[i + 1]];
        const c = positions[indices[i + 2]];
        const face = b.sub(a).cross(c.sub(a));
        if (face.length() < 1e-7) continue;
        try testing.expect(face.dot(a.add(b).add(c)) > 0);
        facing += 1;
    }
    try testing.expect(facing >= 16 * 32 * 2 - 2 * 32);
}
