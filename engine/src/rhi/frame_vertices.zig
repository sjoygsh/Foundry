//! Bounded per-frame vertex data, staged into device-local memory (animation3d.md §8).
//! No mapped borrow escapes and no completion timeline is duplicated above the backend.
const std = @import("std");
const command = @import("command.zig");
const interface = @import("interface.zig");
const resource = @import("resource.zig");
const pipeline = @import("pipeline.zig");

pub const UpdateError = interface.MapError || interface.CommandError || error{
    InvalidFrame,
    InvalidSize,
    AlreadyUpdated,
};

/// Instantiated inside rhi for its selected backend. Do not copy an owning instance.
pub fn For(comptime Backend: type) type {
    return struct {
        const Self = @This();
        const Slot = struct {
            upload: resource.BufferHandle = .none,
            vertex: resource.BufferHandle = .none,
            state: resource.ResourceState = .undefined,
            updated: u64 = 0,
        };

        device: *Backend.Device,
        capacity: u64,
        slots: [4]Slot = @splat(.{}),
        slot_count: u32,
        live: bool = true,

        /// Capacity is bytes per slot, not a growing allocation. Uses the device's allocator.
        pub fn init(device: *Backend.Device, capacity: u64) interface.ResourceError!Self {
            if (capacity == 0 or capacity > std.math.maxInt(usize) or
                device.desc.frames_in_flight == 0 or device.desc.frames_in_flight > 4)
                return error.InvalidDescriptor;
            var self: Self = .{ .device = device, .capacity = capacity, .slot_count = device.desc.frames_in_flight };
            errdefer self.deinit();
            for (self.slots[0..self.slot_count]) |*slot| {
                slot.upload = try device.createBuffer(.{
                    .label = "frame vertices staging",
                    .size = capacity,
                    .usage = .{ .copy_src = true },
                    .memory = .upload,
                });
                slot.vertex = try device.createBuffer(.{
                    .label = "frame vertices",
                    .size = capacity,
                    .usage = .{ .vertex = true, .copy_dst = true },
                });
            }
            return self;
        }

        /// Handles die now; ordinary backend retirement retains their unfinished uses.
        pub fn deinit(self: *Self) void {
            if (!self.live) return;
            self.live = false;
            for (self.slots[0..self.slot_count]) |slot| {
                self.device.destroyBuffer(slot.upload);
                self.device.destroyBuffer(slot.vertex);
            }
        }

        /// On the RHI thread, after beginFrame and before render passes. Collect all this
        /// frame's instances first; bind the returned buffer with offsets into this prefix.
        /// The handle and written bytes are for this frame only. Buffer capacity never grows;
        /// ordinary command recording may allocate through the device.
        /// A recording failure consumes the update too: do not retry within this frame.
        pub fn update(self: *Self, frame: command.FrameContext, bytes: []const u8) UpdateError!resource.BufferHandle {
            if (!self.live) return error.InvalidHandle;
            const dev = self.device;
            if (!dev.in_frame or frame.index != dev.frame_index or frame.slot != dev.frame_slot or
                frame.slot >= self.slot_count or !frame.surface_texture.eql(dev.surface_texture))
                return error.InvalidFrame;
            if (bytes.len == 0 or bytes.len > self.capacity) return error.InvalidSize;
            const slot = &self.slots[frame.slot];
            if (slot.updated == frame.index) return error.AlreadyUpdated;
            slot.updated = frame.index;

            const mapped = try dev.mapBuffer(slot.upload);
            @memcpy(mapped[0..bytes.len], bytes);
            dev.unmapBuffer(slot.upload);

            const cmd = try dev.beginCommandBuffer();
            var consumed = false;
            defer if (!consumed) cmd.discard();
            try cmd.bufferBarrier(&.{.{ .buffer = slot.vertex, .from = slot.state, .to = .copy_dst }});
            slot.state = .copy_dst;
            try cmd.copyBufferToBuffer(.{ .src = slot.upload, .dst = slot.vertex, .size = bytes.len });
            try cmd.bufferBarrier(&.{.{ .buffer = slot.vertex, .from = .copy_dst, .to = .shader_read }});
            slot.state = .shader_read;
            consumed = true; // submit consumes even on failure
            try cmd.submit();
            return slot.vertex;
        }
    };
}

const testing = std.testing;
const Null = @import("backends/null.zig");

test "frame vertices refuse non-live frames, overflow, repeated updates and dead owners" {
    const dev = try Null.Device.init(testing.allocator, .{});
    defer dev.deinit();
    dev.log_violations = false;
    try testing.expectError(error.InvalidDescriptor, For(Null).init(dev, 0));
    var vertices = try For(Null).init(dev, 16);
    defer vertices.deinit();
    const empty: command.FrameContext = .{ .surface_texture = dev.surface_texture, .index = 0, .slot = 0 };
    try testing.expectError(error.InvalidFrame, vertices.update(empty, "x"));
    const frame = try dev.beginFrame();
    var wrong = frame;
    wrong.slot = 4;
    try testing.expectError(error.InvalidFrame, vertices.update(wrong, "x"));
    wrong.slot = 1;
    try testing.expectError(error.InvalidFrame, vertices.update(wrong, "x"));
    wrong = frame;
    wrong.index += 1;
    try testing.expectError(error.InvalidFrame, vertices.update(wrong, "x"));
    wrong = frame;
    wrong.surface_texture = .none;
    try testing.expectError(error.InvalidFrame, vertices.update(wrong, "x"));
    try testing.expectError(error.InvalidSize, vertices.update(frame, ""));
    try testing.expectError(error.InvalidSize, vertices.update(frame, "0123456789abcdefX"));
    const handle = try vertices.update(frame, "0123456789abcdef");
    try testing.expectError(error.AlreadyUpdated, vertices.update(frame, "x"));
    try dev.endFrame();
    try testing.expectError(error.InvalidFrame, vertices.update(frame, "x"));
    const next = try dev.beginFrame();
    try testing.expectError(error.InvalidFrame, vertices.update(frame, "x"));
    _ = try vertices.update(next, "short");
    try dev.endFrame();
    vertices.deinit();
    try testing.expectError(error.InvalidHandle, dev.mapBuffer(handle));
    try testing.expectError(error.InvalidHandle, vertices.update(next, "x"));
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "frame vertex updates use only their waited slot and explicit device-local copy state" {
    const dev = try Null.Device.init(testing.allocator, .{});
    defer dev.deinit();
    dev.log_violations = false;
    var vertices = try For(Null).init(dev, 16);
    defer vertices.deinit();
    for (0..12) |i| {
        const frame = try dev.beginFrame();
        const handle = try vertices.update(frame, "vertices");
        const slot = vertices.slots[frame.slot];
        try testing.expect(handle.eql(slot.vertex));
        try testing.expectEqual(resource.MemoryIntent.device_local, dev.buffers.getConst(handle).?.desc.memory);
        try testing.expectEqual(resource.ResourceState.shader_read, dev.buffers.getConst(handle).?.state);
        try testing.expect(!dev.buffers.getConst(slot.upload).?.mapped);
        try testing.expectEqualSlices(u8, "vertices", dev.buffers.getConst(slot.upload).?.storage[0..8]);
        if (i == 0) {
            // Copy submissions, not only vertex binds, protect staging from premature writes.
            _ = try dev.mapBuffer(slot.upload);
            try testing.expect(dev.hasViolation(.frame_ring));
            dev.unmapBuffer(slot.upload);
            dev.clearViolations();
        }
        try dev.endFrame();
    }
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "a failed vertex upload consumes its recording and next waited frame can recover" {
    const dev = try Null.Device.init(testing.allocator, .{ .frames_in_flight = 1 });
    defer dev.deinit();
    dev.log_violations = false;
    var vertices = try For(Null).init(dev, 16);
    defer vertices.deinit();
    const first = try dev.beginFrame();
    dev.faults.submit = error.DeviceLost;
    try testing.expectError(error.DeviceLost, vertices.update(first, "fail"));
    try testing.expectError(error.AlreadyUpdated, vertices.update(first, "retry"));
    try testing.expectEqual(@as(usize, 0), dev.timeline.open.items.len);
    try dev.endFrame();
    const second = try dev.beginFrame();
    _ = try vertices.update(second, "healthy");
    try dev.endFrame();
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

fn allocationProof(gpa: std.mem.Allocator) !void {
    const dev = try Null.Device.init(gpa, .{});
    defer dev.deinit();
    dev.log_violations = false;
    var vertices = try For(Null).init(dev, 64);
    defer vertices.deinit();
    const frame = try dev.beginFrame();
    defer dev.endFrame() catch {}; // close even when an injected allocation refuses recording
    _ = try vertices.update(frame, "allocation failure proof");
}

test "frame vertices clean up every allocation refusal" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationProof, .{});
}

/// Compiles the update path against each real backend; native Vulkan execution is M24 Step 7.
pub fn updateProof(comptime Backend: type) !void {
    for ([_]u32{ 1, 2, 4 }) |count| {
        const dev = try Backend.Device.init(testing.allocator, .{ .surface_size = .{ .width = 8, .height = 8 }, .frames_in_flight = count });
        defer dev.deinit();
        var vertices = try For(Backend).init(dev, 64);
        defer vertices.deinit();
        for (0..12) |i| {
            const frame = try dev.beginFrame();
            var bytes: [64]u8 = undefined;
            @memset(&bytes, @intCast(i));
            _ = try vertices.update(frame, &bytes);
            try dev.endFrame();
        }
    }
}

const vertex_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct In { float2 p [[attribute(0)]]; float4 c [[attribute(1)]]; };
    \\struct Out { float4 p [[position]]; float4 c; };
    \\vertex Out vertexMain(In in [[stage_in]]) { return { float4(in.p, 0, 1), in.c }; }
    \\fragment float4 fragmentMain(Out in [[stage_in]]) { return in.c; }
;

/// Twelve asynchronous frames, distinct images retained until one wait at the end. Alternating
/// positions and per-frame colours detect stale data, shared slots and missing upload work.
pub fn drawProof(comptime Backend: type, comptime pixels: bool) !void {
    const extent: resource.Extent2D = .{ .width = 8, .height = 8 };
    const dev = try Backend.Device.init(testing.allocator, .{ .surface_size = extent });
    defer dev.deinit();
    if (!pixels) dev.log_violations = false;
    var vertices = try For(Backend).init(dev, 6 * 6 * @sizeOf(f32));
    defer vertices.deinit();
    const shader = try dev.createShaderModuleFromSource(.{ .source = vertex_msl });
    defer dev.destroyShaderModule(shader);
    const layout = try dev.createPipelineLayout(.{});
    defer dev.destroyPipelineLayout(layout);
    const pipe = try dev.createRenderPipeline(.{
        .layout = layout,
        .vertex_shader = shader,
        .fragment_shader = shader,
        .vertex_buffers = &.{.{ .slot = 0, .stride = 24, .attributes = &.{
            .{ .location = 0, .format = .float32x2, .offset = 0 },
            .{ .location = 1, .format = .float32x4, .offset = 8 },
        } }},
        .color_targets = &.{.{ .format = .rgba8_unorm }},
    });
    defer dev.destroyRenderPipeline(pipe);
    var images: [12]resource.TextureHandle = @splat(.none);
    defer for (images) |handle| dev.destroyTexture(handle);
    var readbacks: [12]resource.BufferHandle = @splat(.none);
    defer for (readbacks) |handle| dev.destroyBuffer(handle);
    for (0..12) |i| {
        images[i] = try dev.createTexture(.{ .size = extent, .format = .rgba8_unorm, .usage = .{ .render_target = true, .copy_src = true } });
        readbacks[i] = try dev.createBuffer(.{ .size = 256, .usage = .{ .copy_dst = true }, .memory = .readback });
        const frame = try dev.beginFrame();
        var frame_closed = false;
        defer if (!frame_closed) dev.endFrame() catch {};
        const left: f32 = if (i % 2 == 0) -1 else 0;
        const right = left + 1;
        const red = @as(f32, @floatFromInt((i + 1) * 20)) / 255;
        const points = [6][2]f32{ .{ left, -1 }, .{ right, -1 }, .{ right, 1 }, .{ left, -1 }, .{ right, 1 }, .{ left, 1 } };
        var data: [6][6]f32 = undefined;
        for (&data, points) |*v, p| v.* = .{ p[0], p[1], red, 0, 0, 1 };
        const buffer = try vertices.update(frame, std.mem.asBytes(&data));
        const cmd = try dev.beginCommandBuffer();
        var consumed = false;
        defer if (!consumed) cmd.discard();
        const pass = try cmd.beginRenderPass(.{ .color = &.{.{ .texture = images[i], .final_state = .copy_src }} });
        pass.setPipeline(pipe);
        pass.setVertexBuffer(0, buffer, 0);
        pass.draw(.{ .vertex_count = 6 });
        pass.end();
        try cmd.copyTextureToBuffer(.{ .src = images[i], .dst = readbacks[i], .size = extent });
        consumed = true;
        try cmd.submit();
        frame_closed = true;
        try dev.endFrame();
        try testing.expectError(error.InvalidFrame, vertices.update(frame, std.mem.asBytes(&data)));
    }
    // Retire before waiting: outstanding reads keep their backings, not their handles.
    vertices.deinit();
    dev.waitIdle();
    if (pixels) {
        for (readbacks, 0..) |handle, i| {
            const bytes = try dev.mapBuffer(handle);
            defer dev.unmapBuffer(handle);
            const lit_x: usize = if (i % 2 == 0) 1 else 6;
            const dark_x: usize = if (i % 2 == 0) 6 else 1;
            try testing.expectEqual([4]u8{ @intCast((i + 1) * 20), 0, 0, 255 }, bytes[(4 * 8 + lit_x) * 4 ..][0..4].*);
            try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, bytes[(4 * 8 + dark_x) * 4 ..][0..4].*);
        }
    } else try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "null accepts the staged per-frame vertex draw protocol across two slots" {
    try drawProof(Null, false);
}

test "frame vertices follow every supported ring size" {
    try updateProof(Null);
}
