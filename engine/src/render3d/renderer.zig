//! The first 3D renderer: resident meshes, one unlit pipeline and depth-correct frames.
//!
//! Design: `docs/design/render3d.md` §6 and ADR-0054.

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");
const asset = @import("asset");

const camera_mod = @import("camera.zig");
const Allocator = std.mem.Allocator;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;

const ShaderStages = struct {
    vertex: []const u8,
    vertex_entry: []const u8,
    fragment: []const u8,
    fragment_entry: []const u8,
};

const unlit_stages: ShaderStages = switch (rhi.backend) {
    .metal => .{
        .vertex = @embedFile("unlit_color_metallib"),
        .vertex_entry = "vertexMain",
        .fragment = @embedFile("unlit_color_metallib"),
        .fragment_entry = "fragmentMain",
    },
    .null => .{
        .vertex = "null-backend-shader",
        .vertex_entry = "vertexMain",
        .fragment = "null-backend-shader",
        .fragment_entry = "fragmentMain",
    },
    .vulkan => .{
        .vertex = @embedFile("unlit_color_vertex_spirv"),
        .vertex_entry = "main",
        .fragment = @embedFile("unlit_color_fragment_spirv"),
        .fragment_entry = "main",
    },
};

pub const Extent2D = struct {
    width: u32,
    height: u32,

    pub fn isEmpty(self: Extent2D) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn eql(a: Extent2D, b: Extent2D) bool {
        return a.width == b.width and a.height == b.height;
    }
};

pub const Config = struct {
    frames_in_flight: u32 = 2,
    sample_count: u32 = 4,
};

pub const FrameView = struct {
    camera: camera_mod.Camera,
    target_size: Extent2D,
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },
};

pub const Mesh = opaque {};
pub const MeshHandle = core.Handle(Mesh);

pub const MeshDraw = struct {
    mesh: MeshHandle,
    submesh: u32 = 0,
    world: Mat4,
};

pub const Stats = struct {
    draws: u32 = 0,
    triangles: u32 = 0,
    pipeline_binds: u32 = 0,
};

pub const Error = error{
    InvalidConfig,
    InvalidCamera,
    InvalidMesh,
    InvalidSubmesh,
    InvalidTransform,
    InvalidFrameSlot,
    MissingStream,
    NotRecording,
    DepthFormatUnsupported,
} || asset.MeshError || rhi.ResourceError || rhi.MapError || rhi.CommandError || Allocator.Error;

const MeshState = struct {
    vertex_buffers: [rhi.pipeline.max_vertex_buffers]rhi.BufferHandle = @splat(.none),
    stream_mask: u8,
    index_buffer: rhi.BufferHandle,
    index_format: asset.MeshIndexFormat,
    submeshes: []asset.Submesh,
    bounds: asset.MeshAabb,
};

const FrameSlot = struct {
    uniform: rhi.BufferHandle,
    group: rhi.BindGroupHandle,
};

const DrawItem = struct {
    mesh: MeshHandle,
    submesh: u32,
    world: Mat4,
    depth: f32,
    submission: u32,
};

pub const Renderer = struct {
    gpa: Allocator,
    device: *rhi.Device,
    config: Config,
    surface_format: rhi.TextureFormat,

    vertex_shader: rhi.ShaderModuleHandle,
    fragment_shader: rhi.ShaderModuleHandle,
    frame_layout: rhi.BindGroupLayoutHandle,
    pipeline_layout: rhi.PipelineLayoutHandle,
    pipeline: rhi.RenderPipelineHandle,
    slots: []FrameSlot,

    meshes: core.HandlePool(Mesh, MeshState),
    draws: std.ArrayList(DrawItem),
    order: std.ArrayList(u32),
    planned_draws: ?u32,

    color_target: rhi.TextureHandle,
    depth_target: rhi.TextureHandle,
    target_size: Extent2D,
    pass_color: [1]rhi.command.ColorAttachment,

    view: FrameView,
    view_matrix: Mat4,
    view_projection: Mat4,
    recording: bool,
    frame: ?rhi.FrameContext,
    stats: Stats,
    last_stats: Stats,

    const Self = @This();

    /// The colour target is the device's surface format, read here as `render2d` reads it,
    /// so a game never names an RHI format.
    pub fn init(gpa: Allocator, device: *rhi.Device, config: Config) Error!Self {
        if (config.frames_in_flight == 0 or !rhi.isValidSampleCount(config.sample_count)) {
            return error.InvalidConfig;
        }
        const surface_format = device.capabilities().surface_format;

        const vertex_shader = try device.createShaderModule(.{
            .label = "render3d unlit vertex",
            .bytes = unlit_stages.vertex,
        });
        errdefer device.destroyShaderModule(vertex_shader);
        const shares_shader = unlit_stages.vertex.ptr == unlit_stages.fragment.ptr and
            unlit_stages.vertex.len == unlit_stages.fragment.len;
        const fragment_shader = if (shares_shader)
            vertex_shader
        else
            try device.createShaderModule(.{
                .label = "render3d unlit fragment",
                .bytes = unlit_stages.fragment,
            });
        errdefer if (!fragment_shader.eql(vertex_shader)) device.destroyShaderModule(fragment_shader);

        const frame_layout = try device.createBindGroupLayout(.{
            .label = "render3d frame",
            .entries = &.{.{
                .binding = 0,
                .type = .uniform_buffer,
                .visibility = .{ .vertex = true },
            }},
        });
        errdefer device.destroyBindGroupLayout(frame_layout);

        const pipeline_layout = try device.createPipelineLayout(.{
            .label = "render3d unlit",
            .bind_group_layouts = &.{frame_layout},
            .inline_constant_bytes = @sizeOf(Mat4),
        });
        errdefer device.destroyPipelineLayout(pipeline_layout);

        const pipeline = try device.createRenderPipeline(.{
            .label = "render3d unlit vertex colour",
            .layout = pipeline_layout,
            .vertex_shader = vertex_shader,
            .vertex_entry = unlit_stages.vertex_entry,
            .fragment_shader = fragment_shader,
            .fragment_entry = unlit_stages.fragment_entry,
            .vertex_buffers = &.{
                .{
                    .slot = @intFromEnum(asset.MeshSemantic.position),
                    .stride = @sizeOf(Vec3),
                    .attributes = &.{.{ .location = 0, .offset = 0, .format = .float32x3 }},
                },
                .{
                    .slot = @intFromEnum(asset.MeshSemantic.color),
                    .stride = 4,
                    .attributes = &.{.{ .location = 5, .offset = 0, .format = .unorm8x4 }},
                },
            },
            .color_targets = &.{.{ .format = surface_format }},
            .depth_stencil = .{
                .format = .depth32_float,
                .depth_write_enabled = true,
                .depth_compare = .greater_equal,
            },
            .primitive = .{
                .topology = .triangle_list,
                .cull_mode = .back,
                .front_face = .counter_clockwise,
            },
            .sample_count = config.sample_count,
        });
        errdefer device.destroyRenderPipeline(pipeline);

        const slots = try gpa.alloc(FrameSlot, config.frames_in_flight);
        errdefer gpa.free(slots);
        var built_slots: usize = 0;
        errdefer for (slots[0..built_slots]) |slot| {
            device.destroyBindGroup(slot.group);
            device.destroyBuffer(slot.uniform);
        };
        for (slots) |*slot| {
            const uniform = try device.createBuffer(.{
                .label = "render3d frame uniform",
                .size = @sizeOf(Mat4),
                .usage = .{ .uniform = true },
                .memory = .upload,
            });
            errdefer device.destroyBuffer(uniform);
            const group = try device.createBindGroup(.{
                .label = "render3d frame",
                .layout = frame_layout,
                .entries = &.{.{
                    .binding = 0,
                    .resource = .{ .uniform_buffer = .{ .buffer = uniform, .size = @sizeOf(Mat4) } },
                }},
            });
            slot.* = .{ .uniform = uniform, .group = group };
            built_slots += 1;
        }

        return .{
            .gpa = gpa,
            .device = device,
            .config = config,
            .surface_format = surface_format,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .frame_layout = frame_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .slots = slots,
            .meshes = .empty,
            .draws = .empty,
            .order = .empty,
            .planned_draws = null,
            .color_target = .none,
            .depth_target = .none,
            .target_size = .{ .width = 0, .height = 0 },
            .pass_color = undefined,
            .view = .{ .camera = .{}, .target_size = .{ .width = 1, .height = 1 } },
            .view_matrix = .identity,
            .view_projection = .identity,
            .recording = false,
            .frame = null,
            .stats = .{},
            .last_stats = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        while (self.meshes.count() != 0) {
            var it = self.meshes.iterator();
            const entry = it.next().?;
            self.destroyMesh(entry.id);
        }
        self.meshes.deinit(self.gpa);
        self.draws.deinit(self.gpa);
        self.order.deinit(self.gpa);

        if (!self.color_target.isNone()) self.device.destroyTexture(self.color_target);
        if (!self.depth_target.isNone()) self.device.destroyTexture(self.depth_target);
        for (self.slots) |slot| {
            self.device.destroyBindGroup(slot.group);
            self.device.destroyBuffer(slot.uniform);
        }
        self.gpa.free(self.slots);
        self.device.destroyRenderPipeline(self.pipeline);
        self.device.destroyPipelineLayout(self.pipeline_layout);
        self.device.destroyBindGroupLayout(self.frame_layout);
        if (!self.fragment_shader.eql(self.vertex_shader)) self.device.destroyShaderModule(self.fragment_shader);
        self.device.destroyShaderModule(self.vertex_shader);
        self.* = undefined;
    }

    pub fn createMesh(self: *Self, mesh: asset.Mesh, label: []const u8) Error!MeshHandle {
        try mesh.validate();
        // Owned by `state` from here on; its errdefer frees it, so this one must not.
        const submeshes = try self.gpa.alloc(asset.Submesh, mesh.submeshes.len);
        for (mesh.submeshes, submeshes) |source, *destination| destination.* = source;

        var state: MeshState = .{
            .stream_mask = 0,
            .index_buffer = .none,
            .index_format = mesh.index_format,
            .submeshes = submeshes,
            .bounds = mesh.bounds,
        };
        errdefer self.destroyMeshState(&state);

        const Upload = struct {
            staging: rhi.BufferHandle,
            destination: rhi.BufferHandle,
            bytes: []const u8,
        };
        var uploads: [rhi.pipeline.max_vertex_buffers + 1]Upload = undefined;
        var upload_count: usize = 0;
        defer for (uploads[0..upload_count]) |upload| self.device.destroyBuffer(upload.staging);

        for (mesh.streams) |stream| {
            const slot: usize = stream.semantic.slot();
            const staging = try self.stagingBuffer(label, stream.bytes);
            const destination = self.device.createBuffer(.{
                .label = label,
                .size = stream.bytes.len,
                .usage = .{ .vertex = true, .copy_dst = true },
                .memory = .device_local,
            }) catch |err| {
                self.device.destroyBuffer(staging);
                return err;
            };
            state.vertex_buffers[slot] = destination;
            state.stream_mask |= @as(u8, 1) << @intCast(slot);
            uploads[upload_count] = .{ .staging = staging, .destination = destination, .bytes = stream.bytes };
            upload_count += 1;
        }

        const index_staging = try self.stagingBuffer(label, mesh.indices);
        state.index_buffer = self.device.createBuffer(.{
            .label = label,
            .size = mesh.indices.len,
            .usage = .{ .index = true, .copy_dst = true },
            .memory = .device_local,
        }) catch |err| {
            self.device.destroyBuffer(index_staging);
            return err;
        };
        uploads[upload_count] = .{
            .staging = index_staging,
            .destination = state.index_buffer,
            .bytes = mesh.indices,
        };
        upload_count += 1;

        var barriers: [rhi.pipeline.max_vertex_buffers + 1]rhi.command.BufferBarrier = undefined;
        for (uploads[0..upload_count], 0..) |upload, i| {
            barriers[i] = .{ .buffer = upload.destination, .from = .undefined, .to = .copy_dst };
        }
        const cmd = try self.device.beginCommandBuffer();
        try cmd.bufferBarrier(barriers[0..upload_count]);
        for (uploads[0..upload_count]) |upload| {
            try cmd.copyBufferToBuffer(.{
                .src = upload.staging,
                .dst = upload.destination,
                .size = upload.bytes.len,
            });
        }
        for (barriers[0..upload_count]) |*barrier| {
            barrier.from = .copy_dst;
            barrier.to = .shader_read;
        }
        try cmd.bufferBarrier(barriers[0..upload_count]);
        try cmd.submit();

        return self.meshes.add(self.gpa, state);
    }

    pub fn destroyMesh(self: *Self, handle: MeshHandle) void {
        const state = self.meshes.get(handle) orelse return;
        self.destroyMeshState(state);
        _ = self.meshes.remove(handle);
    }

    pub fn begin(self: *Self, view: FrameView) Error!void {
        if (!view.camera.isValid() or view.target_size.isEmpty()) return error.InvalidCamera;
        for (view.clear_color) |channel| {
            if (!std.math.isFinite(channel)) return error.InvalidCamera;
        }
        self.view = view;
        self.view_matrix = view.camera.viewMatrix();
        self.view_projection = view.camera.viewProjection(view.target_size.width, view.target_size.height);
        self.draws.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.planned_draws = null;
        self.frame = null;
        self.stats = .{};
        self.recording = true;
    }

    pub fn drawMesh(self: *Self, draw: MeshDraw) Error!void {
        if (!self.recording) return error.NotRecording;
        const mesh = self.meshes.getConst(draw.mesh) orelse return error.InvalidMesh;
        if (draw.submesh >= mesh.submeshes.len) return error.InvalidSubmesh;
        if (!matrixFinite(draw.world)) return error.InvalidTransform;
        const required = (@as(u8, 1) << @intFromEnum(asset.MeshSemantic.position)) |
            (@as(u8, 1) << @intFromEnum(asset.MeshSemantic.color));
        if (mesh.stream_mask & required != required) return error.MissingStream;

        const center = mesh.bounds.min.add(mesh.bounds.max).scale(0.5);
        const view_center = self.view_matrix.mulPoint(draw.world.mulPoint(center));
        const sort_depth = if (std.math.isFinite(view_center.z)) -view_center.z else std.math.inf(f32);
        try self.draws.append(self.gpa, .{
            .mesh = draw.mesh,
            .submesh = draw.submesh,
            .world = draw.world,
            .depth = sort_depth,
            .submission = @intCast(self.draws.items.len),
        });
        self.planned_draws = null;
    }

    pub fn plan(self: *Self) Error!void {
        if (!self.recording) return error.NotRecording;
        self.order.clearRetainingCapacity();
        try self.order.ensureTotalCapacity(self.gpa, self.draws.items.len);
        for (self.draws.items, 0..) |_, i| self.order.appendAssumeCapacity(@intCast(i));
        std.mem.sort(u32, self.order.items, self.draws.items, drawLessThan);
        self.planned_draws = @intCast(self.draws.items.len);
    }

    pub fn prepare(self: *Self, cmd: *rhi.CommandBuffer, frame: rhi.FrameContext) Error!void {
        _ = cmd;
        if (!self.recording) return error.NotRecording;
        if (frame.slot >= self.slots.len) return error.InvalidFrameSlot;
        if (self.planned_draws == null or self.planned_draws.? != self.draws.items.len) try self.plan();
        try self.ensureTargets(self.view.target_size);

        const slot = self.slots[frame.slot];
        const bytes = try self.device.mapBuffer(slot.uniform);
        @memcpy(bytes[0..@sizeOf(Mat4)], std.mem.asBytes(&self.view_projection));
        self.device.unmapBuffer(slot.uniform);
        self.frame = frame;
    }

    pub fn passDesc(self: *Self, frame: rhi.FrameContext, overlay: bool) rhi.RenderPassDesc {
        const surface_final: rhi.ResourceState = if (overlay) .render_target else .present;
        if (self.config.sample_count == 1) {
            self.pass_color[0] = .{
                .texture = frame.surface_texture,
                .load = .{ .clear = .{ .color = self.view.clear_color } },
                .store = .store,
                .initial_state = .undefined,
                .final_state = surface_final,
            };
        } else {
            self.pass_color[0] = .{
                .texture = self.color_target,
                .load = .{ .clear = .{ .color = self.view.clear_color } },
                .store = .discard,
                .initial_state = .undefined,
                .final_state = .render_target,
                .resolve = .{
                    .texture = frame.surface_texture,
                    .initial_state = .undefined,
                    .final_state = surface_final,
                },
            };
        }
        return .{
            .label = "render3d world",
            .color = &self.pass_color,
            .depth = .{
                .texture = self.depth_target,
                .load = .{ .clear = .{ .depth_stencil = .{ .depth = 0 } } },
                .store = .discard,
                .initial_state = .undefined,
                .final_state = .depth_stencil,
            },
        };
    }

    pub fn record(self: *Self, pass: *rhi.RenderPass) Error!void {
        if (!self.recording) return error.NotRecording;
        defer {
            self.recording = false;
            self.last_stats = self.stats;
        }
        const frame = self.frame orelse return error.NotRecording;
        if (self.order.items.len == 0) return;

        pass.setViewport(.{
            .width = @floatFromInt(self.view.target_size.width),
            .height = @floatFromInt(self.view.target_size.height),
        });
        pass.setScissor(.{
            .width = self.view.target_size.width,
            .height = self.view.target_size.height,
        });
        pass.setPipeline(self.pipeline);
        pass.setBindGroup(0, self.slots[frame.slot].group);
        self.stats.pipeline_binds = 1;

        for (self.order.items) |draw_index| {
            const item = self.draws.items[draw_index];
            const mesh = self.meshes.getConst(item.mesh) orelse continue;
            if (item.submesh >= mesh.submeshes.len) continue;
            const submesh = mesh.submeshes[item.submesh];

            pass.setInlineConstants(std.mem.asBytes(&item.world));
            pass.setVertexBuffer(0, mesh.vertex_buffers[0], 0);
            pass.setVertexBuffer(5, mesh.vertex_buffers[5], 0);
            pass.setIndexBuffer(mesh.index_buffer, switch (mesh.index_format) {
                .uint16 => .uint16,
                .uint32 => .uint32,
            }, 0);
            pass.drawIndexed(.{
                .index_count = submesh.index_count,
                .first_index = submesh.first_index,
            });
            self.stats.draws += 1;
            self.stats.triangles += submesh.index_count / 3;
        }
    }

    pub fn frameStats(self: *const Self) Stats {
        return self.last_stats;
    }

    fn stagingBuffer(self: *Self, label: []const u8, contents: []const u8) Error!rhi.BufferHandle {
        const staging = try self.device.createBuffer(.{
            .label = label,
            .size = contents.len,
            .usage = .{ .copy_src = true },
            .memory = .upload,
        });
        errdefer self.device.destroyBuffer(staging);
        const mapped = try self.device.mapBuffer(staging);
        @memcpy(mapped[0..contents.len], contents);
        self.device.unmapBuffer(staging);
        return staging;
    }

    fn destroyMeshState(self: *Self, state: *MeshState) void {
        for (state.vertex_buffers) |buffer| if (!buffer.isNone()) self.device.destroyBuffer(buffer);
        if (!state.index_buffer.isNone()) self.device.destroyBuffer(state.index_buffer);
        self.gpa.free(state.submeshes);
    }

    fn ensureTargets(self: *Self, size: Extent2D) Error!void {
        if (self.target_size.eql(size) and !self.depth_target.isNone()) return;

        const depth = self.device.createTexture(.{
            .label = "render3d depth",
            .size = .{ .width = size.width, .height = size.height },
            .format = .depth32_float,
            .usage = .{ .depth_stencil = true },
            .sample_count = self.config.sample_count,
        }) catch |err| switch (err) {
            error.UnsupportedFormat => return error.DepthFormatUnsupported,
            else => return err,
        };
        errdefer self.device.destroyTexture(depth);

        const color = if (self.config.sample_count == 1)
            rhi.TextureHandle.none
        else
            try self.device.createTexture(.{
                .label = "render3d multisampled colour",
                .size = .{ .width = size.width, .height = size.height },
                .format = self.surface_format,
                .usage = .{ .render_target = true },
                .sample_count = self.config.sample_count,
            });

        if (!self.color_target.isNone()) self.device.destroyTexture(self.color_target);
        if (!self.depth_target.isNone()) self.device.destroyTexture(self.depth_target);
        self.color_target = color;
        self.depth_target = depth;
        self.target_size = size;
    }
};

fn matrixFinite(matrix: Mat4) bool {
    for (matrix.cols) |column| for (column) |value| {
        if (!std.math.isFinite(value)) return false;
    };
    return true;
}

fn drawLessThan(draws: []const DrawItem, a: u32, b: u32) bool {
    const left = draws[a];
    const right = draws[b];
    if (left.depth != right.depth) return left.depth < right.depth;
    return left.submission < right.submission;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const TestFixture = struct {
    device: *rhi.Device,
    renderer: Renderer,

    fn init(samples: u32, size: u32) !TestFixture {
        const device = try rhi.Device.init(testing.allocator, .{
            .surface_size = .{ .width = size, .height = size },
            .frames_in_flight = 2,
        });
        errdefer device.deinit();
        return .{
            .device = device,
            .renderer = try Renderer.init(testing.allocator, device, .{
                .frames_in_flight = 2,
                .sample_count = samples,
            }),
        };
    }

    fn deinit(self: *TestFixture) void {
        self.renderer.deinit();
        self.device.deinit();
    }
};

fn testMesh(renderer: *Renderer, include_color: bool) !MeshHandle {
    const positions = [_]Vec3{
        .init(-1, -1, -2),
        .init(1, -1, -2),
        .init(0, 1, -2),
    };
    const colors = [_][4]u8{
        .{ 255, 0, 0, 255 },
        .{ 0, 255, 0, 255 },
        .{ 0, 0, 255, 255 },
    };
    const indices = [_]u16{ 0, 1, 2 };
    const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = 3 }};
    var streams = [_]asset.MeshStream{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) },
        .{ .semantic = .color, .format = .unorm8x4, .bytes = std.mem.sliceAsBytes(&colors) },
    };
    return renderer.createMesh(.{
        .vertex_count = positions.len,
        .streams = streams[0..if (include_color) 2 else 1],
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&indices),
        .submeshes = &submeshes,
        .bounds = try asset.Mesh.computeBounds(&positions),
    }, "render3d test mesh");
}

fn testView(size: u32) FrameView {
    return .{
        .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 100 },
        .target_size = .{ .width = size, .height = size },
        .clear_color = .{ 0.02, 0.03, 0.04, 1 },
    };
}

fn finishTestFrame(fx: *TestFixture) !void {
    const frame = try fx.device.beginFrame();
    var cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, frame);
    var pass = try cmd.beginRenderPass(fx.renderer.passDesc(frame, false));
    try fx.renderer.record(pass);
    pass.end();
    try cmd.submit();
    try fx.device.endFrame();
}

test "renderer configuration is bounded, and the colour target is the surface's format" {
    const device = try rhi.Device.init(testing.allocator, .{});
    defer device.deinit();
    try testing.expectError(error.InvalidConfig, Renderer.init(testing.allocator, device, .{
        .frames_in_flight = 0,
    }));
    try testing.expectError(error.InvalidConfig, Renderer.init(testing.allocator, device, .{
        .sample_count = 2,
    }));
    var renderer = try Renderer.init(testing.allocator, device, .{});
    defer renderer.deinit();
    try testing.expectEqual(device.capabilities().surface_format, renderer.surface_format);
}

test "resident mesh records a depth pass and reports the completed work" {
    var fx = try TestFixture.init(1, 64);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, true);

    try fx.renderer.begin(testView(64));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .world = .identity });
    try finishTestFrame(&fx);

    try testing.expectEqual(Stats{ .draws = 1, .triangles = 1, .pipeline_binds = 1 }, fx.renderer.frameStats());
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

test "planning is front-to-back with submission order as the exact tie break" {
    var fx = try TestFixture.init(1, 64);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, true);

    try fx.renderer.begin(testView(64));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .world = Mat4.translation(.init(0, 0, -8)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .world = Mat4.translation(.init(0, 0, -1)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .world = Mat4.translation(.init(0, 0, -1)) });
    try fx.renderer.plan();

    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, fx.renderer.order.items);
}

test "draw submission refuses stale handles submeshes transforms and absent colour" {
    var fx = try TestFixture.init(1, 64);
    defer fx.deinit();
    const colored = try testMesh(&fx.renderer, true);
    const no_color = try testMesh(&fx.renderer, false);

    try testing.expectError(error.NotRecording, fx.renderer.drawMesh(.{ .mesh = colored, .world = .identity }));
    try fx.renderer.begin(testView(64));
    try testing.expectError(error.InvalidMesh, fx.renderer.drawMesh(.{ .mesh = .none, .world = .identity }));
    try testing.expectError(error.InvalidSubmesh, fx.renderer.drawMesh(.{ .mesh = colored, .submesh = 1, .world = .identity }));
    var bad = Mat4.identity;
    bad.cols[2][1] = std.math.nan(f32);
    try testing.expectError(error.InvalidTransform, fx.renderer.drawMesh(.{ .mesh = colored, .world = bad }));
    try testing.expectError(error.MissingStream, fx.renderer.drawMesh(.{ .mesh = no_color, .world = .identity }));

    fx.renderer.destroyMesh(colored);
    try testing.expectError(error.InvalidMesh, fx.renderer.drawMesh(.{ .mesh = colored, .world = .identity }));
    try testing.expectEqual(@as(usize, 0), fx.renderer.draws.items.len);
}

test "begin refuses malformed cameras targets and clear colours" {
    var fx = try TestFixture.init(1, 64);
    defer fx.deinit();

    var view = testView(64);
    view.camera.near = 0;
    try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
    view = testView(64);
    view.target_size.width = 0;
    try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
    view = testView(64);
    view.clear_color[0] = std.math.inf(f32);
    try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
}

test "targets follow sample count and rebuild on resize" {
    var single = try TestFixture.init(1, 64);
    defer single.deinit();
    try single.renderer.begin(testView(64));
    const single_frame = try single.device.beginFrame();
    var single_cmd = try single.device.beginCommandBuffer();
    try single.renderer.prepare(single_cmd, single_frame);
    try testing.expect(single.renderer.color_target.isNone());
    try testing.expect(!single.renderer.depth_target.isNone());
    single_cmd.discard();
    try single.device.endFrame();

    var multi = try TestFixture.init(4, 64);
    defer multi.deinit();
    try multi.renderer.begin(testView(64));
    const first_frame = try multi.device.beginFrame();
    var first_cmd = try multi.device.beginCommandBuffer();
    try multi.renderer.prepare(first_cmd, first_frame);
    const old_color = multi.renderer.color_target;
    const old_depth = multi.renderer.depth_target;
    try testing.expect(!old_color.isNone());
    try testing.expect(!old_depth.isNone());
    first_cmd.discard();
    try multi.device.endFrame();

    try multi.renderer.begin(testView(32));
    const second_frame = try multi.device.beginFrame();
    var second_cmd = try multi.device.beginCommandBuffer();
    try multi.renderer.prepare(second_cmd, second_frame);
    try testing.expect(!multi.renderer.color_target.eql(old_color));
    try testing.expect(!multi.renderer.depth_target.eql(old_depth));
    second_cmd.discard();
    try multi.device.endFrame();
}

test "a mesh that fails after upload releases everything exactly once" {
    var fx = try TestFixture.init(1, 64);
    defer fx.deinit();
    // The submesh copy succeeds and the handle pool's first growth fails, after the upload
    // has been submitted. The testing allocator reports a leak or a double free.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    fx.renderer.gpa = failing.allocator();
    defer fx.renderer.gpa = testing.allocator;
    try testing.expectError(error.OutOfMemory, testMesh(&fx.renderer, true));
    try testing.expectEqual(@as(usize, 0), fx.renderer.meshes.count());
}

test "destroying a resident mesh invalidates its handle immediately" {
    var fx = try TestFixture.init(1, 64);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, true);
    fx.renderer.destroyMesh(mesh);
    fx.renderer.destroyMesh(mesh);
    try fx.renderer.begin(testView(64));
    try testing.expectError(error.InvalidMesh, fx.renderer.drawMesh(.{ .mesh = mesh, .world = .identity }));
}

const crossing_size = 64;
const crossing_bytes = crossing_size * crossing_size * 4;

fn crossingMesh(renderer: *Renderer, red: bool) !MeshHandle {
    // fov=90, aspect=1: x/y multiplied by distance project exactly to these NDC edges.
    // The two depth planes cross at x=32.3 px, away from the pixel centre and every 4x
    // sample position. No sample tie can make submission order observable.
    const left_distance: f32 = if (red) 1.0 else 3.0;
    const right_distance: f32 = if (red) 3.0 else 1.01296;
    const positions = [_]Vec3{
        .init(-left_distance, -left_distance, -left_distance),
        .init(right_distance, -right_distance, -right_distance),
        .init(right_distance, right_distance, -right_distance),
        .init(-left_distance, left_distance, -left_distance),
    };
    const rgba = if (red) [4]u8{ 255, 0, 0, 255 } else [4]u8{ 0, 0, 255, 255 };
    const colors = [_][4]u8{ rgba, rgba, rgba, rgba };
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = 6 }};
    const streams = [_]asset.MeshStream{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) },
        .{ .semantic = .color, .format = .unorm8x4, .bytes = std.mem.sliceAsBytes(&colors) },
    };
    return renderer.createMesh(.{
        .vertex_count = positions.len,
        .streams = &streams,
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&indices),
        .submeshes = &submeshes,
        .bounds = try asset.Mesh.computeBounds(&positions),
    }, if (red) "red crossing quad" else "blue crossing quad");
}

const CrossingImage = struct {
    pixels: [crossing_bytes]u8,
    format: rhi.TextureFormat,
};

fn renderCrossing(samples: u32, red_first: bool) !CrossingImage {
    var fx = try TestFixture.init(samples, crossing_size);
    defer fx.deinit();
    const red = try crossingMesh(&fx.renderer, true);
    const blue = try crossingMesh(&fx.renderer, false);
    const readback = try fx.device.createBuffer(.{
        .label = "render3d crossing readback",
        .size = crossing_bytes,
        .usage = .{ .copy_dst = true },
        .memory = .readback,
    });
    defer fx.device.destroyBuffer(readback);

    try fx.renderer.begin(.{
        .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 },
        .target_size = .{ .width = crossing_size, .height = crossing_size },
    });
    const order = if (red_first) [2]MeshHandle{ red, blue } else [2]MeshHandle{ blue, red };
    for (order) |mesh| try fx.renderer.drawMesh(.{ .mesh = mesh, .world = .identity });

    const frame = try fx.device.beginFrame();
    var cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, frame);
    var pass = try cmd.beginRenderPass(fx.renderer.passDesc(frame, false));
    try fx.renderer.record(pass);
    pass.end();
    try cmd.textureBarrier(&.{.{
        .texture = frame.surface_texture,
        .from = .present,
        .to = .copy_src,
    }});
    try cmd.copyTextureToBuffer(.{
        .src = frame.surface_texture,
        .size = .{ .width = crossing_size, .height = crossing_size },
        .dst = readback,
    });
    try cmd.textureBarrier(&.{.{
        .texture = frame.surface_texture,
        .from = .copy_src,
        .to = .present,
    }});
    try cmd.submit();
    try fx.device.endFrame();
    fx.device.waitIdle();

    var result: [crossing_bytes]u8 = undefined;
    const mapped = try fx.device.mapBuffer(readback);
    @memcpy(&result, mapped[0..crossing_bytes]);
    fx.device.unmapBuffer(readback);
    return .{ .pixels = result, .format = fx.device.capabilities().surface_format };
}

fn crossingTexel(image: *const [crossing_bytes]u8, x: usize, y: usize) [4]u8 {
    const offset = (y * crossing_size + x) * 4;
    return image[offset..][0..4].*;
}

fn solidTexel(format: rhi.TextureFormat, red: bool) [4]u8 {
    return switch (format) {
        .bgra8_unorm, .bgra8_unorm_srgb => if (red)
            .{ 0, 0, 255, 255 }
        else
            .{ 255, 0, 0, 255 },
        else => if (red) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 },
    };
}

test "depth decides the crossing at 1x and 4x independently of submission order" {
    // The null backend proves the command contract above; pixels are the distinct evidence
    // supplied by Metal here and Vulkan on the Windows qualification target.
    if (rhi.backend == .null) return;

    for ([_]u32{ 1, 4 }) |samples| {
        const red_first = try renderCrossing(samples, true);
        const blue_first = try renderCrossing(samples, false);
        try testing.expectEqual(red_first.format, blue_first.format);
        try testing.expectEqualSlices(u8, &red_first.pixels, &blue_first.pixels);

        const surface_format = red_first.format;
        const red = solidTexel(surface_format, true);
        const blue = solidTexel(surface_format, false);
        for (0..crossing_size) |y| {
            try testing.expectEqual(red, crossingTexel(&red_first.pixels, 8, y));
            try testing.expectEqual(blue, crossingTexel(&red_first.pixels, 55, y));
        }

        const crossing = crossingTexel(&red_first.pixels, 32, crossing_size / 2);
        if (samples == 1) {
            try testing.expectEqual(blue, crossing);
        } else {
            const red_channel: usize = if (surface_format == .bgra8_unorm_srgb) 2 else 0;
            const blue_channel: usize = if (surface_format == .bgra8_unorm_srgb) 0 else 2;
            try testing.expect(crossing[red_channel] > 0 and crossing[red_channel] < 255);
            try testing.expect(crossing[blue_channel] > 0 and crossing[blue_channel] < 255);
            try testing.expectEqual(@as(u8, 255), crossing[3]);
        }
    }
}
