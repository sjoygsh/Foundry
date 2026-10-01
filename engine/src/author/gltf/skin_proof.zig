//! Cross-layer proof, built separately: author is never granted anim to implement import.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const anim = @import("anim");
const translate = @import("translate.zig");
const document = @import("document.zig");
const fixture = @import("skin_fixture.zig");

test "imported glTF samples and skins to a known pose, with front applied exactly once" {
    const testing = std.testing;
    for ([_]translate.Front{ .minus_z, .plus_z }) |front| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var diags = data.Diagnostics.init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        const parsed = try document.parse(a, try fixture.json(a, .{}), .default);
        const result = try translate.run(testing.allocator, a, &parsed.value, &.{&fixture.binary()}, &.{}, .{ .model_id = "demo:rig", .source = "rig.gltf", .front = front }, .default, &diags);
        var s = try (try asset.skeleton.read(result.assets[1].bytes, .default)).copy(testing.allocator);
        defer s.deinit(testing.allocator);
        var c = try (try asset.animation.read(result.assets[2].bytes, .default)).copy(testing.allocator);
        defer c.deinit(testing.allocator);
        const skeleton: anim.Skeleton = .{ .parents = s.parents, .rest = s.rest, .inverse_bind = s.inverse_bind, .root = s.root };
        try skeleton.validate();
        const t = c.tracks[0];
        const tracks = [_]anim.Track{.{ .joint = t.joint, .path = @enumFromInt(@intFromEnum(t.path)), .interpolation = @enumFromInt(@intFromEnum(t.interpolation)), .times = t.times, .values = t.values }};
        const clip: anim.Clip = .{ .duration = c.duration, .tracks = &tracks };
        try clip.validate(s.parents.len);
        var transforms: [3]core.math.Transform = undefined;
        var matrices: [3]core.math.Mat4 = undefined;
        const pose: anim.Pose = .{ .local = &transforms };
        anim.sample(skeleton, clip, 0.5, pose);
        anim.skinMatrices(skeleton, pose, &matrices);
        var mv = try asset.mesh_file.read(result.assets[0].bytes, .default);
        const m = mv.mesh();
        var positions: [3][3]f32 = undefined;
        var joints: [3][4]u8 = undefined;
        var weights: [3][4]f32 = undefined;
        for (m.streams) |stream| switch (stream.semantic) {
            .position => @memcpy(std.mem.asBytes(&positions), stream.bytes),
            .joints => @memcpy(std.mem.asBytes(&joints), stream.bytes),
            .weights => @memcpy(std.mem.asBytes(&weights), stream.bytes),
            else => {},
        };
        try anim.validateInfluences(&joints, &weights, 3);
        var output: [3][3]f32 = undefined;
        anim.skin(.{ .positions = &positions, .joints = &joints, .weights = &weights }, &matrices, 0, 3, .{ .positions = &output });
        for (output, positions) |p, bind| {
            const sign: f32 = if (front == .plus_z) -1 else 1;
            try testing.expectApproxEqAbs(sign * (bind[0] + 1), p[0], 1e-5);
            try testing.expectApproxEqAbs(bind[1], p[1], 1e-5);
            try testing.expectApproxEqAbs(@as(f32, 0), p[2], 1e-5);
        }
    }
}
