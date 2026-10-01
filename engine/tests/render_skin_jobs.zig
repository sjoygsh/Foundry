//! The renderer's actual skinning call site under serial, reversed and real workers.
const std = @import("std");
const core = @import("core");
const asset = @import("asset");
const platform = @import("platform");
const render3d = @import("render3d");
const rhi = @import("rhi");
const testing = std.testing;
const Mat4 = core.math.Mat4;

fn run(jobs: core.Jobs, count: u32) ![]u8 {
    const gpa = testing.allocator;
    const device = try rhi.Device.init(gpa, .{ .surface_size = .{ .width = 8, .height = 8 } });
    defer device.deinit();
    var renderer = try render3d.Renderer.init(gpa, device, .{ .sample_count = 1, .shadow_size = 0, .max_skinned_vertices = count * 2, .jobs = jobs });
    defer renderer.deinit();
    const material = try renderer.createMaterial(.{ .double_sided = true }, "jobs skin");
    const positions = try gpa.alloc([3]f32, count);
    defer gpa.free(positions);
    const normals = try gpa.alloc([3]f32, count);
    defer gpa.free(normals);
    const tangents = try gpa.alloc([4]f32, count);
    defer gpa.free(tangents);
    const joints = try gpa.alloc([4]u8, count);
    defer gpa.free(joints);
    const weights = try gpa.alloc([4]f32, count);
    defer gpa.free(weights);
    for (positions, normals, tangents, joints, weights, 0..) |*p, *n, *t, *j, *w, i| {
        p.* = .{ @as(f32, @floatFromInt(i % 3)) - 1, @as(f32, @floatFromInt(i % 5)) / 4, -3 };
        n.* = .{ 0, 0, 1 };
        t.* = .{ 1, 0, 0, -1 };
        j.* = .{ 0, 1, 255, 255 };
        w.* = .{ 0.25, 0.75, 0, 0 };
    }
    const box: asset.MeshAabb = .{ .min = .init(-1, 0, -3), .max = .init(1, 1, -3) };
    const indices = [_]u16{ 0, 1, 2 };
    const mesh = try renderer.createMesh(.{ .vertex_count = count, .bounds = box, .joint_bounds = &.{ box, box }, .streams = &.{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(positions) },
        .{ .semantic = .normal, .format = .float32x3, .bytes = std.mem.sliceAsBytes(normals) },
        .{ .semantic = .tangent, .format = .float32x4, .bytes = std.mem.sliceAsBytes(tangents) },
        .{ .semantic = .joints, .format = .uint8x4, .bytes = std.mem.sliceAsBytes(joints) },
        .{ .semantic = .weights, .format = .float32x4, .bytes = std.mem.sliceAsBytes(weights) },
    }, .index_format = .uint16, .indices = std.mem.sliceAsBytes(&indices), .submeshes = &.{.{ .first_index = 0, .index_count = 3 }} }, "jobs bind");
    try renderer.begin(.{ .camera = .{}, .target_size = .{ .width = 8, .height = 8 } });
    for ([_]f32{ -0.5, 0.5 }) |x| {
        const matrices = [_]Mat4{ .identity, Mat4.translation(.init(x, 0, 0)) };
        try renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity, .skin = &matrices });
    }
    const frame = try device.beginFrame();
    const cmd = try device.beginCommandBuffer();
    try renderer.prepare(cmd, frame);
    try renderer.recordFrame(cmd, frame, false);
    try cmd.submit();
    try device.endFrame();
    try testing.expectEqual(count * 2, renderer.frameStats().skinned_vertices);
    try testing.expectEqual(@as(u32, 2), renderer.frameStats().skinned_draws);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), device.violationCount());
    return gpa.dupe(u8, renderer.skin_bytes[0 .. @as(usize, count) * 2 * 40]);
}

test "M24 render3d skin bytes agree serial reversed and on a real pool across the chunk boundary" {
    const gpa = testing.allocator;
    const os = try platform.Os.init(gpa, .{ .app_name = "foundry-skin-jobs", .env = &.{} });
    defer os.deinit();
    const workers = try os.startWorkers(gpa, .{ .count = 4 });
    defer workers.deinit();
    for ([_]u32{ 3, 1023, 1024, 1025, 2051 }) |count| {
        const reference = try run(core.jobs.serial, count);
        defer gpa.free(reference);
        for ([_]core.Jobs{ core.jobs.reversed, workers.jobs() }) |jobs| {
            const actual = try run(jobs, count);
            defer gpa.free(actual);
            try testing.expectEqualSlices(u8, reference, actual);
        }
    }
}
