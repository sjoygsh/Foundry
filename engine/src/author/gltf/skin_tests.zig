const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const document = @import("document.zig");
const translate = @import("translate.zig");
const fixture = @import("skin_fixture.zig");
const testing = std.testing;

fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, p: fixture.Parts, bin: []const u8, plus_z: bool, collision: bool, limits: document.Limits, diags: *data.Diagnostics) !translate.Result {
    const json = try fixture.json(arena, p);
    const doc = try document.parse(arena, json, limits);
    return translate.run(gpa, arena, &doc.value, &.{bin}, &.{}, .{ .model_id = "demo:rig", .source = "rig.gltf", .front = if (plus_z) .plus_z else .minus_z, .collision = collision }, limits, diags);
}
test "skin import closes hierarchy, remaps joints and emits canonical IDs and assets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diags = data.Diagnostics.init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    const result = try run(testing.allocator, arena.allocator(), .{}, &fixture.binary(), false, false, .default, &diags);
    try testing.expectEqual(@as(usize, 3), result.assets.len);
    const skeleton = try asset.skeleton.read(result.assets[1].bytes, .default);
    try testing.expectEqual(@as(u32, 3), skeleton.joint_count);
    try testing.expectEqual(asset.skeleton.no_parent, skeleton.parent(0));
    try testing.expectEqual(@as(u16, 0), skeleton.parent(1));
    try testing.expectEqual(@as(u16, 1), skeleton.parent(2));
    try testing.expectEqualStrings("bridge", skeleton.name(1));
    try testing.expectEqual(@as(f32, 10), skeleton.root.cols[3][0]);
    var mesh = try asset.mesh_file.read(result.assets[0].bytes, .default);
    try testing.expectEqual(@as(u32, 2), asset.mesh_file.versionOf(result.assets[0].bytes).?);
    const m = mesh.mesh();
    try testing.expectEqual(@as(usize, 3), m.joint_bounds.len);
    for (m.streams) |s| if (s.semantic == .joints) {
        try testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 }, s.bytes);
    };
    const clip = try asset.animation.read(result.assets[2].bytes, .default);
    try testing.expectEqual(@as(u16, 2), clip.track(0).joint);
    for ([_][]const u8{ "foundry:skeleton demo:rig.skeleton", "foundry:animation demo:rig.clip0", "skeleton demo:rig.skeleton", "name \"walk\" clip demo:rig.clip0", "translation { x 0 y 0 z 0 }" }) |needle| try testing.expect(std.mem.indexOf(u8, result.source, needle) != null);
    try testing.expect(!diags.failed and diags.items.items.len == 0);
    const again = try run(testing.allocator, arena.allocator(), .{}, &fixture.binary(), false, false, .default, &diags);
    try testing.expectEqualStrings(result.source, again.source);
    for (result.assets, again.assets) |a, b| try testing.expectEqualSlices(u8, a.bytes, b.bytes);
}

test "skin import diagnostics name every unsupported or malformed skin and clip" {
    const Case = struct { p: fixture.Parts = .{}, offset: ?usize = null, value: f32 = 0, byte: ?u8 = null, needle: []const u8 };
    const cases = [_]Case{
        .{ .p = .{ .attributes = "\"POSITION\":0,\"WEIGHTS_0\":3" }, .needle = "JOINTS_0" },
        .{ .p = .{ .attributes = "\"POSITION\":0,\"JOINTS_0\":2" }, .needle = "WEIGHTS_0" },
        .{ .p = .{ .attributes = "\"POSITION\":0,\"JOINTS_0\":0,\"WEIGHTS_0\":3" }, .needle = "UNSIGNED_BYTE/SHORT" },
        .{ .p = .{ .attributes = "\"POSITION\":0,\"JOINTS_0\":2,\"WEIGHTS_0\":0" }, .needle = "WEIGHTS_0 must" },
        .{ .p = .{ .attributes = fixture.attributes ++ ",\"JOINTS_1\":2" }, .needle = "exceeds four" },
        .{ .p = .{ .attributes = fixture.attributes ++ ",\"WEIGHTS_1\":3" }, .needle = "exceeds four" },
        .{ .offset = 44, .byte = 2, .needle = "outside the skin" },
        .{ .offset = 45, .byte = 2, .needle = "outside the skin" },
        .{ .offset = 60, .value = 0.5, .needle = "repeats a weighted joint" },
        .{ .offset = 56, .value = 0, .needle = "all-zero" },
        .{ .offset = 56, .value = -1, .needle = "negative or non-finite weights" },
        .{ .offset = 56, .value = std.math.nan(f32), .needle = "negative or non-finite weights" },
        .{ .offset = 104, .value = 0, .needle = "non-invertible" },
        .{ .offset = 116, .value = 1, .needle = "non-affine" },
        .{ .p = .{ .skin = "{\"joints\":[0,0]}" }, .needle = "repeats joint" },
        .{ .p = .{ .skin = "{\"joints\":[0,4]}" }, .needle = "one tree" },
        .{ .p = .{ .skin = "{\"joints\":[99]}" }, .needle = "missing from the default scene" },
        .{ .p = .{ .skin = "{\"joints\":[2,0],\"skeleton\":4}" }, .needle = "not an ancestor" },
        .{ .p = .{ .nodes = fixture.nodes ++ ",{\"mesh\":0}", .roots = "3,4,5" }, .needle = "both rigidly and skinned" },
        .{ .p = .{ .nodes = fixture.nodes ++ ",{\"mesh\":0,\"skin\":1}", .roots = "3,4,5", .skin = fixture.skin ++ "," ++ fixture.skin }, .needle = "more than one skin" },
        .{ .p = .{ .animation = "{\"samplers\":[],\"channels\":[]}" }, .needle = "unnamed" },
        .{ .p = .{ .animation = fixture.animation ++ "," ++ fixture.animation }, .needle = "duplicate name" },
        .{ .p = .{ .animation = "{\"name\":\"walk\",\"samplers\":[{\"input\":5,\"output\":6,\"interpolation\":\"CUBICSPLINE\"}],\"channels\":[]}" }, .needle = "bake to linear" },
        .{ .offset = 236, .value = 0, .needle = "key times are unsorted" },
        .{ .offset = 232, .value = -1, .needle = "key times are unsorted" },
        .{ .offset = 236, .value = std.math.nan(f32), .needle = "key times are unsorted" },
        .{ .offset = 240, .value = std.math.inf(f32), .needle = "non-finite key values" },
        .{ .p = .{ .animation = "{\"name\":\"walk\",\"samplers\":[{\"input\":5,\"output\":6}],\"channels\":[{\"sampler\":0,\"target\":{\"node\":2,\"path\":\"translation\"}},{\"sampler\":0,\"target\":{\"node\":2,\"path\":\"translation\"}}]}" }, .needle = "duplicates a joint/path" },
        .{ .p = .{ .animation = "{\"name\":\"walk\",\"samplers\":[{\"input\":5,\"output\":6}],\"channels\":[{\"sampler\":1,\"target\":{\"node\":2,\"path\":\"translation\"}}]}" }, .needle = "missing sampler" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var diags = data.Diagnostics.init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        var bin = fixture.binary();
        if (case.offset) |at| {
            if (case.byte) |b| bin[at] = b else fixture.putFloat(&bin, at, case.value);
        }
        try testing.expectError(error.ContentInvalid, run(testing.allocator, arena.allocator(), case.p, &bin, false, false, .default, &diags));
        var found = false;
        for (diags.items.items) |diag| if (std.mem.indexOf(u8, diag.message, case.needle) != null) {
            found = true;
        };
        try testing.expect(found and diags.failed);
    }
}

test "skin import counts normalization and dropped channels, and omitted binds are identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diags = data.Diagnostics.init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    var bin = fixture.binary();
    fixture.putFloat(&bin, 56, 2);
    const result = try run(testing.allocator, arena.allocator(), .{
        .skin = "{\"joints\":[2,0]}",
        .animation = "{\"name\":\"walk\",\"samplers\":[{\"input\":5,\"output\":6,\"interpolation\":\"STEP\"}],\"channels\":[{\"sampler\":0,\"target\":{\"node\":2,\"path\":\"translation\"}},{\"sampler\":0,\"target\":{\"node\":3,\"path\":\"translation\"}},{\"sampler\":0,\"target\":{\"node\":4,\"path\":\"translation\"}},{\"sampler\":0,\"target\":{\"node\":2,\"path\":\"weights\"}}]}",
    }, &bin, false, true, .default, &diags);
    try testing.expectEqual(@as(usize, 4), diags.items.items.len);
    const needles = [_][]const u8{ "normalized weights for 1", "treated as static", "outside the skeleton", "morph weights" };
    for (needles) |needle| {
        var found = false;
        for (diags.items.items) |diag| if (std.mem.indexOf(u8, diag.message, needle) != null) {
            found = true;
        };
        try testing.expect(found);
    }
    const skel = try asset.skeleton.read(result.assets[2].bytes, .default);
    try testing.expectEqualDeep(core.math.Mat4.identity, skel.inverseBind(2));
    const col = try asset.collision_mesh.read(result.assets[1].bytes, .default);
    try testing.expectEqual(@as(f32, 10), col.positions[0].x);
    try testing.expectEqual(@as(f32, 3), col.positions[0].y);
    const clip = try asset.animation.read(result.assets[3].bytes, .default);
    try testing.expectEqual(asset.animation.Interpolation.step, clip.track(0).interpolation);
}

test "skin import rejects unequal counts and non-unit rotation keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const replacements = [_]struct { from: []const u8, to: []const u8, needle: []const u8 }{
        .{ .from = "\"bufferView\":2,\"componentType\":5121,\"count\":3", .to = "\"bufferView\":2,\"componentType\":5121,\"count\":2", .needle = "POSITION's count" },
        .{ .from = "\"bufferView\":3,\"componentType\":5126,\"count\":3", .to = "\"bufferView\":3,\"componentType\":5126,\"count\":2", .needle = "POSITION's count" },
    };
    for (replacements) |r| {
        var diags = data.Diagnostics.init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        const replaced = try std.mem.replaceOwned(u8, arena.allocator(), fixture.accessors, r.from, r.to);
        try testing.expectError(error.ContentInvalid, run(testing.allocator, arena.allocator(), .{ .accessors = replaced }, &fixture.binary(), false, false, .default, &diags));
        try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, r.needle) != null);
    }
    // Two tightly packed vec4 keys fit by borrowing the larger weights buffer view.
    const accessors = try std.mem.replaceOwned(u8, arena.allocator(), fixture.accessors, "\"bufferView\":6,\"componentType\":5126,\"count\":2,\"type\":\"VEC3\"", "\"bufferView\":3,\"componentType\":5126,\"count\":2,\"type\":\"VEC4\"");
    const animation = try std.mem.replaceOwned(u8, arena.allocator(), fixture.animation, "translation", "rotation");
    var bin = fixture.binary();
    fixture.putFloat(&bin, 56, 2);
    var diags = data.Diagnostics.init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    try testing.expectError(error.ContentInvalid, run(testing.allocator, arena.allocator(), .{ .accessors = accessors, .animation = animation }, &bin, false, false, .default, &diags));
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "non-unit rotation") != null);
}

test "skin import bounds closure and JSON skin animation counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 256 original siblings plus their non-influencing common root needs 257 joints.
    var nodes: std.ArrayList(u8) = .empty;
    var joints: std.ArrayList(u8) = .empty;
    for (0..256) |i| {
        if (i != 0) try joints.appendSlice(arena.allocator(), ",");
        try joints.print(arena.allocator(), "{d}", .{i});
        try nodes.appendSlice(arena.allocator(), "{},");
    }
    try nodes.print(arena.allocator(), "{{\"children\":[{s}]}},{{\"mesh\":0,\"skin\":0}}", .{joints.items});
    const skin = try std.fmt.allocPrint(arena.allocator(), "{{\"joints\":[{s}]}}", .{joints.items});
    var diags = data.Diagnostics.init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    try testing.expectError(error.ContentInvalid, run(testing.allocator, arena.allocator(), .{ .nodes = nodes.items, .roots = "256,257", .skin = skin }, &fixture.binary(), false, false, .default, &diags));
    try testing.expect(std.mem.indexOf(u8, diags.items.items[0].message, "after hierarchy closure") != null);
    const json = try fixture.json(arena.allocator(), .{});
    try testing.expectError(error.OverLimit, document.parse(arena.allocator(), json, .{ .max_skins = 0 }));
    try testing.expectError(error.OverLimit, document.parse(arena.allocator(), json, .{ .max_animations = 0 }));
    try testing.expectError(error.OverLimit, document.parse(arena.allocator(), json, .{ .max_animation_channels = 0 }));
    var key_diags = data.Diagnostics.init(testing.allocator, .default);
    defer key_diags.deinit(testing.allocator);
    try testing.expectError(error.ContentInvalid, run(testing.allocator, arena.allocator(), .{}, &fixture.binary(), false, false, .{ .max_animation_keys = 1 }, &key_diags));
    try testing.expect(std.mem.indexOf(u8, key_diags.items.items[0].message, "import-wide key limit") != null);
}

test "skin import preserves sibling order and accepts quantized weights and u16 joints" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = data.Diagnostics.init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    const sibling_nodes = try std.mem.replaceOwned(u8, a, fixture.nodes, "\"children\":[1]", "\"children\":[2,1]");
    const nodes = try std.mem.replaceOwned(u8, a, sibling_nodes, ",\"children\":[2]", "");
    const result = try run(testing.allocator, a, .{ .nodes = nodes, .skin = "{\"joints\":[2,1]}" }, &fixture.binary(), false, false, .default, &diags);
    const s = try asset.skeleton.read(result.assets[1].bytes, .default);
    try testing.expectEqualStrings("tip", s.name(1));
    try testing.expectEqualStrings("bridge", s.name(2));
    var bin = fixture.binary();
    @memset(bin[56..68], 0);
    for (0..3) |v| bin[56 + v * 4] = 255;
    // Use the unused bind view for u16 joint indices, avoiding an overlapping fixture.
    @memset(bin[104..128], 0);
    const ws = try std.mem.replaceOwned(u8, a, fixture.accessors, "\"bufferView\":3,\"componentType\":5126,\"count\":3", "\"bufferView\":3,\"componentType\":5121,\"normalized\":true,\"count\":3");
    const accessors = try std.mem.replaceOwned(u8, a, ws, "\"bufferView\":2,\"componentType\":5121", "\"bufferView\":4,\"componentType\":5123");
    _ = try run(testing.allocator, a, .{ .accessors = accessors, .skin = "{\"joints\":[2,0]}" }, &bin, false, false, .default, &diags);
    try testing.expect(!diags.failed);
}

fn allocationProof(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diags = data.Diagnostics.init(gpa, .default);
    defer diags.deinit(gpa);
    _ = try run(gpa, arena.allocator(), .{}, &fixture.binary(), false, true, .default, &diags);
}
test "skin import releases all allocations at every failure point" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationProof, .{});
}
