//! Renderer output under every kind of `core.Jobs`.
//!
//! `render2d` cannot see `platform`, so its own tests cannot reach the real pool. This test
//! stands where a game does and proves the two products of preparation — batch lists and
//! vertex bytes — are identical when chunks run forwards, backwards or on four threads
//! (`jobs-and-threading.md` §11, Step 5).
const std = @import("std");
const asset = @import("asset");
const core = @import("core");
const platform = @import("platform");
const render2d = @import("render2d");
const rhi = @import("rhi");

const testing = std.testing;
const Batch = render2d.batch.Batch;
const Vertex = render2d.sprite.Vertex;

const quads_per_buffer: u32 = 257;
const vertex_grain: u32 = 4 * 1024;

const Result = struct {
    vertices: []u8,
    order: []u32,
    batches: []Batch,
    stats: render2d.Stats,
    violations: usize,

    fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.order);
        gpa.free(self.batches);
    }
};

fn run(gpa: std.mem.Allocator, jobs: core.Jobs, count: u32) !Result {
    const device = try rhi.Device.init(gpa, .{});
    defer device.deinit();
    var renderer = try render2d.Renderer.init(gpa, device, .{
        .quads_per_buffer = quads_per_buffer,
        .jobs = jobs,
    });
    defer renderer.deinit();

    var image = try asset.Image.alloc(gpa, 2, 2);
    defer image.deinit(gpa);
    @memset(image.pixels, 0xff);
    const first = try renderer.createTexture(image, .{ .label = "jobs first" });
    const second = try renderer.createTexture(image, .{ .label = "jobs second" });

    const frame_view: render2d.renderer.FrameView = .{
        .camera = .{ .viewport = .init(0, 0, 1280, 720) },
    };
    try renderer.begin(frame_view);
    const extra = try renderer.addView(.{ .screen = .init(40, 30, 320, 180) });

    const layers = [_]i16{ std.math.maxInt(i16), -7, 0, std.math.minInt(i16), 12, -7 };
    for (0..count) |i| {
        const view: render2d.ViewId = switch (i % 3) {
            0 => .screen,
            1 => .world,
            else => extra,
        };
        try renderer.setView(view);
        try renderer.drawSprite(.{
            .texture = if (i % 5 == 0) second else first,
            .position = .init(@floatFromInt(i % 113), @floatFromInt(i % 79)),
            .size = .init(2 + @as(f32, @floatFromInt(i % 3)), 3),
            .rotation = @as(f32, @floatFromInt(i % 17)) / 10,
            .layer = layers[i % layers.len],
            .blend = if (i % 11 == 0) .additive else .alpha,
        });
    }

    const frame = try device.beginFrame();
    const cmd = try device.beginCommandBuffer();
    try renderer.prepare(cmd, frame);
    const pass = try cmd.beginRenderPass(.{
        .label = "render jobs",
        .color = &.{.{
            .texture = frame.surface_texture,
            .load = .{ .clear = .{ .color = .{ 0, 0, 0, 1 } } },
            .store = .store,
            .initial_state = .undefined,
            .final_state = .present,
        }},
    });
    try renderer.record(pass);
    pass.end();
    try cmd.submit();
    try device.endFrame();
    device.waitIdle();

    var vertex_bytes: std.ArrayList(u8) = .empty;
    errdefer vertex_bytes.deinit(gpa);
    const slot = &renderer.slots[frame.slot];
    for (slot.buffers.items[0..renderer.frameStats().buffers_used], 0..) |buffer, i| {
        const first_quad = @as(u32, @intCast(i)) * quads_per_buffer;
        const quads: usize = @intCast(@min(quads_per_buffer, count - first_quad));
        const bytes = try device.mapBuffer(buffer.upload);
        {
            defer device.unmapBuffer(buffer.upload);
            const byte_count = quads * render2d.sprite.vertices_per_quad * @sizeOf(Vertex);
            try vertex_bytes.appendSlice(gpa, bytes[0..byte_count]);
        }
    }

    const vertices = try vertex_bytes.toOwnedSlice(gpa);
    errdefer gpa.free(vertices);
    const order = try gpa.dupe(u32, renderer.batcher.order.items);
    errdefer gpa.free(order);
    const batches = try gpa.dupe(Batch, renderer.batcher.batches.items);
    errdefer gpa.free(batches);
    return .{
        .vertices = vertices,
        .order = order,
        .batches = batches,
        .stats = renderer.frameStats(),
        .violations = if (rhi.backend == .null) device.violationCount() else 0,
    };
}

test "vertex bytes and batches are identical forwards, backwards and on a real pool" {
    const gpa = testing.allocator;
    const os = try platform.Os.init(gpa, .{ .app_name = "foundry-render-jobs-test", .env = &.{} });
    defer os.deinit();
    const workers = try os.startWorkers(gpa, .{ .count = 4 });
    defer workers.deinit();
    try testing.expectEqual(@as(u16, 4), workers.threadCount());

    // Empty and one; every side of a buffer boundary; every side of the chunk grain.
    const counts = [_]u32{
        0,
        1,
        quads_per_buffer - 1,
        quads_per_buffer,
        quads_per_buffer + 1,
        vertex_grain - 1,
        vertex_grain,
        vertex_grain + 1,
    };
    for (counts) |count| {
        const reference = try run(gpa, core.jobs.serial, count);
        defer reference.deinit(gpa);

        for ([_]core.Jobs{ core.jobs.reversed, workers.jobs() }) |jobs| {
            const actual = try run(gpa, jobs, count);
            defer actual.deinit(gpa);
            try testing.expectEqualSlices(u8, reference.vertices, actual.vertices);
            try testing.expectEqualSlices(u32, reference.order, actual.order);
            try testing.expectEqualSlices(Batch, reference.batches, actual.batches);
            try testing.expectEqual(reference.stats, actual.stats);
            try testing.expectEqual(@as(usize, 0), actual.violations);
        }
        try testing.expectEqual(@as(usize, 0), reference.violations);
    }
}
