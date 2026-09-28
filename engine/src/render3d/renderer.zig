//! Foundry's 3D renderer: registered shading models, resident resources and ordered draws.
//!
//! Design: `docs/design/meshes.md` §7, ADR-0049 and ADR-0054.

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");
const asset = @import("asset");

const camera_mod = @import("camera.zig");
const Allocator = std.mem.Allocator;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;

pub const unlit_id = core.ContentId.fromString("foundry:shading.unlit");

pub const StreamSet = struct {
    bits: u8 = 0,

    pub fn has(self: StreamSet, semantic: asset.MeshSemantic) bool {
        return self.bits & (@as(u8, 1) << @intCast(semantic.slot())) != 0;
    }

    pub fn contains(self: StreamSet, required: StreamSet) bool {
        return self.bits & required.bits == required.bits;
    }

    pub fn of(comptime semantics: []const asset.MeshSemantic) StreamSet {
        var bits: u8 = 0;
        inline for (semantics) |semantic| bits |= @as(u8, 1) << @intCast(semantic.slot());
        return .{ .bits = bits };
    }
};

pub const MaterialFields = packed struct(u8) {
    base_color: bool = false,
    base_color_texture: bool = false,
    alpha: bool = false,
    _reserved: u5 = 0,
};

pub const ShaderStage = struct {
    bytes: []const u8,
    entry: []const u8,
};

pub const ShadingVariants = struct {
    /// Indexed by `(has_uv0 << 1) | has_color`.
    vertex: [4]ShaderStage,
    /// Opaque/blend share index 0; mask is index 1.
    fragment: [2]ShaderStage,
};

pub const ShadingModel = struct {
    id: core.ContentId,
    requires: StreamSet,
    optional: StreamSet = .{},
    reads: MaterialFields = .{},
    variants: ShadingVariants,
};

pub const AlphaMode = enum { @"opaque", mask, blend };
pub const Filter = enum { nearest, linear };
pub const Wrap = enum { clamp, repeat, mirror };

pub const Texture = opaque {};
pub const TextureHandle = core.Handle(Texture);
pub const TextureOptions = struct {
    filter: Filter = .linear,
    wrap: Wrap = .repeat,
    color_space: asset.ColorSpace = .srgb,
    mipmaps: bool = false,
    label: []const u8 = "render3d texture",
};

pub const Material = opaque {};
pub const MaterialHandle = core.Handle(Material);
pub const MaterialDesc = struct {
    shading: core.ContentId = unlit_id,
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    base_color_texture: TextureHandle = .none,
    alpha_mode: AlphaMode = .@"opaque",
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
};

fn builtinStage(comptime name: []const u8, comptime metal_entry: []const u8) ShaderStage {
    return switch (rhi.backend) {
        .metal => .{ .bytes = @embedFile("unlit_metallib"), .entry = metal_entry },
        .null => .{ .bytes = "null-backend-shader", .entry = metal_entry },
        .vulkan => .{ .bytes = @embedFile(name), .entry = "main" },
    };
}

fn unlitModel() ShadingModel {
    return .{
        .id = unlit_id,
        .requires = StreamSet.of(&.{.position}),
        .optional = StreamSet.of(&.{ .uv0, .color }),
        .reads = .{ .base_color = true, .base_color_texture = true, .alpha = true },
        .variants = .{
            .vertex = .{
                builtinStage("unlit_vertex_spirv", "vertexMain"),
                builtinStage("unlit_color_vertex_spirv", "vertexColor"),
                builtinStage("unlit_uv_vertex_spirv", "vertexUv"),
                builtinStage("unlit_uv_color_vertex_spirv", "vertexUvColor"),
            },
            .fragment = .{
                builtinStage("unlit_fragment_spirv", "fragmentMain"),
                builtinStage("unlit_mask_fragment_spirv", "fragmentMask"),
            },
        },
    };
}

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
    material: MaterialHandle,
    world: Mat4,
};

pub const Stats = struct {
    draws: u32 = 0,
    triangles: u32 = 0,
    pipeline_binds: u32 = 0,
    culled: u32 = 0,
    blended: u32 = 0,
};

pub const Error = error{
    InvalidConfig,
    InvalidCamera,
    InvalidMesh,
    InvalidMaterial,
    InvalidTexture,
    InvalidSubmesh,
    InvalidTransform,
    InvalidFrameSlot,
    MissingStream,
    UnknownShadingModel,
    DuplicateShadingModel,
    InvalidShadingModel,
    InvalidMaterialValue,
    WrongColorSpace,
    TextureTooLarge,
    NotRecording,
    DepthFormatUnsupported,
} || asset.MeshError || rhi.ResourceError || rhi.MapError || rhi.CommandError || Allocator.Error;

const MeshState = struct {
    vertex_buffers: [rhi.pipeline.max_vertex_buffers]rhi.BufferHandle = @splat(.none),
    formats: [rhi.pipeline.max_vertex_buffers]?asset.MeshVertexFormat = @splat(null),
    stream_mask: u8,
    index_buffer: rhi.BufferHandle,
    index_format: asset.MeshIndexFormat,
    submeshes: []asset.Submesh,
    bounds: asset.MeshAabb,
};

const TextureState = struct {
    gpu: rhi.TextureHandle,
    sampler: rhi.SamplerHandle,
    color_space: asset.ColorSpace,
    mipmaps: bool,
};

const SamplerKey = struct { filter: Filter, wrap: Wrap, mipmaps: bool };
const SamplerState = struct { key: SamplerKey, handle: rhi.SamplerHandle };

const MaterialUniform = extern struct {
    base_color: [4]f32,
    alpha_cutoff: f32,
    _padding: [3]f32 = @splat(0),
};

const MaterialState = struct {
    model: u32,
    desc: MaterialDesc,
    uniform: rhi.BufferHandle,
    group: rhi.BindGroupHandle,
};

const ModelState = struct {
    desc: ShadingModel,
    vertex: [4]rhi.ShaderModuleHandle,
    fragment: [2]rhi.ShaderModuleHandle,
};

const Cull = enum { back_ccw, back_cw, none };
const PipelineKey = struct {
    model: u32,
    /// bit 0 colour, bit 1 UV0, bit 2 float colour (rather than UNORM8).
    vertex_layout: u3,
    alpha: AlphaMode,
    cull: Cull,

    fn eql(a: PipelineKey, b: PipelineKey) bool {
        return a.model == b.model and a.vertex_layout == b.vertex_layout and a.alpha == b.alpha and a.cull == b.cull;
    }
};

const PipelineState = struct { key: PipelineKey, pipeline: rhi.RenderPipelineHandle };

const FrameSlot = struct {
    uniform: rhi.BufferHandle,
    group: rhi.BindGroupHandle,
};

const DrawItem = struct {
    mesh: MeshHandle,
    submesh: u32,
    world: Mat4,
    material: MaterialHandle,
    pipeline_key: PipelineKey,
    alpha: AlphaMode,
    depth: f32,
    submission: u32,
};

pub const Renderer = struct {
    gpa: Allocator,
    device: *rhi.Device,
    config: Config,
    surface_format: rhi.TextureFormat,

    frame_layout: rhi.BindGroupLayoutHandle,
    material_layout: rhi.BindGroupLayoutHandle,
    pipeline_layout: rhi.PipelineLayoutHandle,
    slots: []FrameSlot,

    models: std.ArrayList(ModelState),
    pipelines: std.ArrayList(PipelineState),
    samplers: std.ArrayList(SamplerState),
    meshes: core.HandlePool(Mesh, MeshState),
    textures: core.HandlePool(Texture, TextureState),
    materials: core.HandlePool(Material, MaterialState),
    white_texture: TextureHandle,
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

        const frame_layout = try device.createBindGroupLayout(.{
            .label = "render3d frame",
            .entries = &.{.{
                .binding = 0,
                .type = .uniform_buffer,
                .visibility = .{ .vertex = true },
            }},
        });
        errdefer device.destroyBindGroupLayout(frame_layout);

        const material_layout = try device.createBindGroupLayout(.{
            .label = "render3d material",
            .entries = &.{
                .{ .binding = 0, .type = .uniform_buffer, .visibility = .{ .fragment = true } },
                .{ .binding = 1, .type = .sampled_texture, .visibility = .{ .fragment = true } },
                .{ .binding = 2, .type = .sampler, .visibility = .{ .fragment = true } },
            },
        });
        errdefer device.destroyBindGroupLayout(material_layout);

        const pipeline_layout = try device.createPipelineLayout(.{
            .label = "render3d shading model",
            .bind_group_layouts = &.{ frame_layout, .none, material_layout },
            .inline_constant_bytes = @sizeOf(Mat4),
        });
        errdefer device.destroyPipelineLayout(pipeline_layout);

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

        var self: Self = .{
            .gpa = gpa,
            .device = device,
            .config = config,
            .surface_format = surface_format,
            .frame_layout = frame_layout,
            .material_layout = material_layout,
            .pipeline_layout = pipeline_layout,
            .slots = slots,
            .models = .empty,
            .pipelines = .empty,
            .samplers = .empty,
            .meshes = .empty,
            .textures = .empty,
            .materials = .empty,
            .white_texture = .none,
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
        errdefer self.deinit();
        try self.registerShadingModel(unlitModel());
        const white = asset.Image{ .width = 1, .height = 1, .pixels = @constCast(&[_]u8{ 255, 255, 255, 255 }) };
        self.white_texture = try self.createTexture(white, .{ .filter = .nearest, .wrap = .clamp, .label = "render3d white" });
        return self;
    }

    pub fn deinit(self: *Self) void {
        while (self.materials.count() != 0) {
            var it = self.materials.iterator();
            self.destroyMaterial(it.next().?.id);
        }
        self.materials.deinit(self.gpa);
        while (self.textures.count() != 0) {
            var it = self.textures.iterator();
            const entry = it.next().?;
            self.destroyTextureState(entry.value);
            _ = self.textures.remove(entry.id);
        }
        self.textures.deinit(self.gpa);
        for (self.samplers.items) |sampler| self.device.destroySampler(sampler.handle);
        self.samplers.deinit(self.gpa);
        while (self.meshes.count() != 0) {
            var it = self.meshes.iterator();
            const entry = it.next().?;
            self.destroyMesh(entry.id);
        }
        self.meshes.deinit(self.gpa);
        self.draws.deinit(self.gpa);
        self.order.deinit(self.gpa);
        for (self.pipelines.items) |entry| self.device.destroyRenderPipeline(entry.pipeline);
        self.pipelines.deinit(self.gpa);
        for (self.models.items) |model| self.destroyModel(model);
        self.models.deinit(self.gpa);

        if (!self.color_target.isNone()) self.device.destroyTexture(self.color_target);
        if (!self.depth_target.isNone()) self.device.destroyTexture(self.depth_target);
        for (self.slots) |slot| {
            self.device.destroyBindGroup(slot.group);
            self.device.destroyBuffer(slot.uniform);
        }
        self.gpa.free(self.slots);
        self.device.destroyPipelineLayout(self.pipeline_layout);
        self.device.destroyBindGroupLayout(self.material_layout);
        self.device.destroyBindGroupLayout(self.frame_layout);
        self.* = undefined;
    }

    pub fn registerShadingModel(self: *Self, model: ShadingModel) Error!void {
        for (self.models.items) |existing| if (existing.desc.id.eql(model.id)) return error.DuplicateShadingModel;
        if (model.requires.bits == 0 or model.requires.bits & model.optional.bits != 0 or
            !model.requires.has(.position) or
            (model.requires.bits | model.optional.bits) & ~StreamSet.of(&.{ .position, .uv0, .color }).bits != 0)
        {
            return error.InvalidShadingModel;
        }

        var state: ModelState = .{ .desc = model, .vertex = @splat(.none), .fragment = @splat(.none) };
        errdefer self.destroyModel(state);
        for (model.variants.vertex, 0..) |stage, i| {
            state.vertex[i] = try self.device.createShaderModule(.{ .label = "render3d vertex variant", .bytes = stage.bytes });
        }
        for (model.variants.fragment, 0..) |stage, i| {
            state.fragment[i] = try self.device.createShaderModule(.{ .label = "render3d fragment variant", .bytes = stage.bytes });
        }
        try self.models.append(self.gpa, state);
    }

    pub fn createTexture(self: *Self, image: asset.Image, options: TextureOptions) Error!TextureHandle {
        const caps = self.device.capabilities();
        if (image.width == 0 or image.height == 0 or image.width > caps.max_texture_dimension or image.height > caps.max_texture_dimension) {
            return error.TextureTooLarge;
        }

        var chain: ?asset.MipChain = if (options.mipmaps)
            try asset.mips.generate(self.gpa, image, options.color_space)
        else
            null;
        defer if (chain) |*value| value.deinit(self.gpa);
        const pixels = if (chain) |value| value.bytes else image.pixels;
        const levels: u32 = if (chain) |value| value.levelCount() else 1;

        const gpu = try self.device.createTexture(.{
            .label = options.label,
            .size = .{ .width = image.width, .height = image.height },
            .format = switch (options.color_space) {
                .srgb => .rgba8_unorm_srgb,
                .linear => .rgba8_unorm,
            },
            .usage = .{ .sampled = true, .copy_dst = true },
            .mip_levels = levels,
        });
        errdefer self.device.destroyTexture(gpu);
        const sampler = try self.samplerFor(.{ .filter = options.filter, .wrap = options.wrap, .mipmaps = levels > 1 }, options.label);
        const staging = try self.stagingBuffer(options.label, pixels);
        defer self.device.destroyBuffer(staging);

        const cmd = try self.device.beginCommandBuffer();
        try cmd.textureBarrier(&.{.{ .texture = gpu, .from = .undefined, .to = .copy_dst }});
        if (chain) |value| {
            for (value.levels, 0..) |level, i| try cmd.copyBufferToTexture(.{
                .src = staging,
                .src_offset = level.offset,
                .dst = gpu,
                .dst_mip_level = @intCast(i),
                .size = .{ .width = level.width, .height = level.height },
            });
        } else {
            try cmd.copyBufferToTexture(.{ .src = staging, .dst = gpu, .size = .{ .width = image.width, .height = image.height } });
        }
        try cmd.textureBarrier(&.{.{ .texture = gpu, .from = .copy_dst, .to = .shader_read }});
        try cmd.submit();

        return self.textures.add(self.gpa, .{
            .gpu = gpu,
            .sampler = sampler,
            .color_space = options.color_space,
            .mipmaps = levels > 1,
        });
    }

    pub fn destroyTexture(self: *Self, handle: TextureHandle) void {
        if (handle.eql(self.white_texture)) return;
        const state = self.textures.get(handle) orelse return;
        self.destroyTextureState(state);
        _ = self.textures.remove(handle);
    }

    pub fn createMaterial(self: *Self, desc: MaterialDesc, label: []const u8) Error!MaterialHandle {
        const model = self.modelIndex(desc.shading) orelse return error.UnknownShadingModel;
        for (desc.base_color) |channel| if (!std.math.isFinite(channel) or channel < 0 or channel > 1) return error.InvalidMaterialValue;
        if (!std.math.isFinite(desc.alpha_cutoff) or desc.alpha_cutoff < 0 or desc.alpha_cutoff > 1) return error.InvalidMaterialValue;

        const texture_handle = if (desc.base_color_texture.isNone()) self.white_texture else desc.base_color_texture;
        const texture = self.textures.get(texture_handle) orelse return error.InvalidTexture;
        if (texture.color_space != .srgb) return error.WrongColorSpace;

        const uniform = try self.device.createBuffer(.{
            .label = label,
            .size = @sizeOf(MaterialUniform),
            .usage = .{ .uniform = true },
            .memory = .upload,
        });
        errdefer self.device.destroyBuffer(uniform);
        const mapped = try self.device.mapBuffer(uniform);
        const value: MaterialUniform = .{ .base_color = desc.base_color, .alpha_cutoff = desc.alpha_cutoff };
        @memcpy(mapped[0..@sizeOf(MaterialUniform)], std.mem.asBytes(&value));
        self.device.unmapBuffer(uniform);

        const group = try self.device.createBindGroup(.{
            .label = label,
            .layout = self.material_layout,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .uniform_buffer = .{ .buffer = uniform, .size = @sizeOf(MaterialUniform) } } },
                .{ .binding = 1, .resource = .{ .sampled_texture = texture.gpu } },
                .{ .binding = 2, .resource = .{ .sampler = texture.sampler } },
            },
        });
        errdefer self.device.destroyBindGroup(group);
        return self.materials.add(self.gpa, .{ .model = model, .desc = desc, .uniform = uniform, .group = group });
    }

    pub fn destroyMaterial(self: *Self, handle: MaterialHandle) void {
        const state = self.materials.get(handle) orelse return;
        self.device.destroyBindGroup(state.group);
        self.device.destroyBuffer(state.uniform);
        _ = self.materials.remove(handle);
    }

    fn modelIndex(self: *const Self, id: core.ContentId) ?u32 {
        for (self.models.items, 0..) |model, i| if (model.desc.id.eql(id)) return @intCast(i);
        return null;
    }

    fn destroyModel(self: *Self, model: ModelState) void {
        for (model.vertex) |shader| if (!shader.isNone()) self.device.destroyShaderModule(shader);
        for (model.fragment) |shader| if (!shader.isNone()) self.device.destroyShaderModule(shader);
    }

    fn destroyTextureState(self: *Self, state: *TextureState) void {
        self.device.destroyTexture(state.gpu);
    }

    fn samplerFor(self: *Self, key: SamplerKey, label: []const u8) Error!rhi.SamplerHandle {
        for (self.samplers.items) |entry| if (std.meta.eql(entry.key, key)) return entry.handle;
        const filter: rhi.resource.FilterMode = switch (key.filter) {
            .nearest => .nearest,
            .linear => .linear,
        };
        const address: rhi.resource.AddressMode = switch (key.wrap) {
            .clamp => .clamp_to_edge,
            .repeat => .repeat,
            .mirror => .mirror_repeat,
        };
        const handle = try self.device.createSampler(.{
            .label = label,
            .min_filter = filter,
            .mag_filter = filter,
            .mip_filter = if (key.mipmaps) filter else .nearest,
            .address_u = address,
            .address_v = address,
        });
        errdefer self.device.destroySampler(handle);
        try self.samplers.append(self.gpa, .{ .key = key, .handle = handle });
        return handle;
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
            state.formats[slot] = stream.format;
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
        const material = self.materials.getConst(draw.material) orelse return error.InvalidMaterial;
        const model = self.models.items[material.model].desc;
        if (draw.submesh >= mesh.submeshes.len) return error.InvalidSubmesh;
        if (!matrixFinite(draw.world)) return error.InvalidTransform;
        if (!(StreamSet{ .bits = mesh.stream_mask }).contains(model.requires)) return error.MissingStream;

        const has_uv = model.optional.has(.uv0) and mesh.stream_mask & (@as(u8, 1) << @intFromEnum(asset.MeshSemantic.uv0)) != 0;
        const has_color = model.optional.has(.color) and mesh.stream_mask & (@as(u8, 1) << @intFromEnum(asset.MeshSemantic.color)) != 0;
        const float_color = has_color and mesh.formats[@intFromEnum(asset.MeshSemantic.color)].? == .float32x4;
        const vertex_layout: u3 = @as(u3, @intFromBool(has_color)) |
            (@as(u3, @intFromBool(has_uv)) << 1) |
            (@as(u3, @intFromBool(float_color)) << 2);
        const cull: Cull = if (material.desc.double_sided)
            .none
        else if (draw.world.determinant() < 0)
            .back_cw
        else
            .back_ccw;

        const center = mesh.bounds.min.add(mesh.bounds.max).scale(0.5);
        const view_center = self.view_matrix.mulPoint(draw.world.mulPoint(center));
        const sort_depth = if (std.math.isFinite(view_center.z)) -view_center.z else std.math.inf(f32);
        try self.draws.append(self.gpa, .{
            .mesh = draw.mesh,
            .submesh = draw.submesh,
            .world = draw.world,
            .material = draw.material,
            .pipeline_key = .{ .model = material.model, .vertex_layout = vertex_layout, .alpha = material.desc.alpha_mode, .cull = cull },
            .alpha = material.desc.alpha_mode,
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
        for (self.order.items) |draw_index| _ = try self.ensurePipeline(self.draws.items[draw_index].pipeline_key);

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
        var bound_pipeline = rhi.RenderPipelineHandle.none;

        for (self.order.items) |draw_index| {
            const item = self.draws.items[draw_index];
            const mesh = self.meshes.getConst(item.mesh) orelse continue;
            if (item.submesh >= mesh.submeshes.len) continue;
            const submesh = mesh.submeshes[item.submesh];
            const material = self.materials.getConst(item.material) orelse continue;
            const pipeline = self.pipelineFor(item.pipeline_key) orelse continue;

            if (!pipeline.eql(bound_pipeline)) {
                pass.setPipeline(pipeline);
                pass.setBindGroup(0, self.slots[frame.slot].group);
                bound_pipeline = pipeline;
                self.stats.pipeline_binds += 1;
            }
            pass.setBindGroup(2, material.group);

            pass.setInlineConstants(std.mem.asBytes(&item.world));
            pass.setVertexBuffer(0, mesh.vertex_buffers[0], 0);
            if (item.pipeline_key.vertex_layout & 2 != 0) pass.setVertexBuffer(3, mesh.vertex_buffers[3], 0);
            if (item.pipeline_key.vertex_layout & 1 != 0) pass.setVertexBuffer(5, mesh.vertex_buffers[5], 0);
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
            if (item.alpha == .blend) self.stats.blended += 1;
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

    fn ensurePipeline(self: *Self, key: PipelineKey) Error!rhi.RenderPipelineHandle {
        if (self.pipelineFor(key)) |pipeline| return pipeline;
        const model = self.models.items[key.model];
        const variant: usize = key.vertex_layout & 3;
        var layouts: [3]rhi.pipeline.VertexBufferLayout = undefined;
        var count: usize = 0;
        layouts[count] = .{
            .slot = @intFromEnum(asset.MeshSemantic.position),
            .stride = 12,
            .attributes = &.{.{ .location = 0, .offset = 0, .format = .float32x3 }},
        };
        count += 1;
        if (key.vertex_layout & 2 != 0) {
            layouts[count] = .{
                .slot = @intFromEnum(asset.MeshSemantic.uv0),
                .stride = 8,
                .attributes = &.{.{ .location = 3, .offset = 0, .format = .float32x2 }},
            };
            count += 1;
        }
        if (key.vertex_layout & 1 != 0) {
            const float_color = key.vertex_layout & 4 != 0;
            layouts[count] = .{
                .slot = @intFromEnum(asset.MeshSemantic.color),
                .stride = if (float_color) 16 else 4,
                .attributes = &.{.{ .location = 5, .offset = 0, .format = if (float_color) .float32x4 else .unorm8x4 }},
            };
            count += 1;
        }
        const pipeline = try self.device.createRenderPipeline(.{
            .label = "render3d shading variant",
            .layout = self.pipeline_layout,
            .vertex_shader = model.vertex[variant],
            .vertex_entry = model.desc.variants.vertex[variant].entry,
            .fragment_shader = model.fragment[if (key.alpha == .mask) 1 else 0],
            .fragment_entry = model.desc.variants.fragment[if (key.alpha == .mask) 1 else 0].entry,
            .vertex_buffers = layouts[0..count],
            .color_targets = &.{.{
                .format = self.surface_format,
                .blend = if (key.alpha == .blend) rhi.pipeline.BlendState.premultiplied_alpha else null,
            }},
            .depth_stencil = .{
                .format = .depth32_float,
                .depth_write_enabled = key.alpha != .blend,
                .depth_compare = .greater_equal,
            },
            .primitive = .{
                .topology = .triangle_list,
                .cull_mode = if (key.cull == .none) .none else .back,
                .front_face = if (key.cull == .back_cw) .clockwise else .counter_clockwise,
            },
            .sample_count = self.config.sample_count,
        });
        errdefer self.device.destroyRenderPipeline(pipeline);
        try self.pipelines.append(self.gpa, .{ .key = key, .pipeline = pipeline });
        return pipeline;
    }

    fn pipelineFor(self: *const Self, key: PipelineKey) ?rhi.RenderPipelineHandle {
        for (self.pipelines.items) |entry| if (entry.key.eql(key)) return entry.pipeline;
        return null;
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
    const left_blend = left.alpha == .blend;
    const right_blend = right.alpha == .blend;
    if (left_blend != right_blend) return !left_blend;
    if (left.depth != right.depth) return if (left_blend) left.depth > right.depth else left.depth < right.depth;
    return left.submission < right.submission;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const TestFixture = struct {
    device: *rhi.Device,
    renderer: Renderer,
    material: MaterialHandle,

    fn init(samples: u32, size: u32) !TestFixture {
        const device = try rhi.Device.init(testing.allocator, .{
            .surface_size = .{ .width = size, .height = size },
            .frames_in_flight = 2,
        });
        errdefer device.deinit();
        var renderer = try Renderer.init(testing.allocator, device, .{
            .frames_in_flight = 2,
            .sample_count = samples,
        });
        errdefer renderer.deinit();
        return .{
            .device = device,
            .material = try renderer.createMaterial(.{}, "test material"),
            .renderer = renderer,
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
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });
    try finishTestFrame(&fx);

    try testing.expectEqual(Stats{ .draws = 1, .triangles = 1, .pipeline_binds = 1 }, fx.renderer.frameStats());
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

test "planning is front-to-back with submission order as the exact tie break" {
    var fx = try TestFixture.init(1, 64);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, true);

    try fx.renderer.begin(testView(64));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(0, 0, -8)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(0, 0, -1)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(0, 0, -1)) });
    try fx.renderer.plan();

    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, fx.renderer.order.items);
}

test "shading models are data registrations and duplicate or malformed entries are refused" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    try testing.expectEqual(@as(usize, 1), fx.renderer.models.items.len);
    try testing.expectError(error.DuplicateShadingModel, fx.renderer.registerShadingModel(unlitModel()));

    var malformed = unlitModel();
    malformed.id = core.ContentId.fromString("test:shading.malformed");
    malformed.requires = .{};
    try testing.expectError(error.InvalidShadingModel, fx.renderer.registerShadingModel(malformed));
    try testing.expectEqual(@as(usize, 1), fx.renderer.models.items.len);
}

test "material creation validates its model values texture and colour space" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    try testing.expectError(error.UnknownShadingModel, fx.renderer.createMaterial(.{
        .shading = core.ContentId.fromString("test:shading.absent"),
    }, "unknown"));
    try testing.expectError(error.InvalidMaterialValue, fx.renderer.createMaterial(.{
        .base_color = .{ 1, 1, 1, 1.1 },
    }, "bad colour"));
    try testing.expectError(error.InvalidMaterialValue, fx.renderer.createMaterial(.{
        .alpha_cutoff = std.math.nan(f32),
    }, "bad cutoff"));
    try testing.expectError(error.InvalidTexture, fx.renderer.createMaterial(.{
        .base_color_texture = TextureHandle.fromBits(0x0000_0001_0000_0001),
    }, "stale texture"));

    var pixels = [_]u8{ 255, 255, 255, 255 };
    const linear = try fx.renderer.createTexture(.{ .width = 1, .height = 1, .pixels = &pixels }, .{ .color_space = .linear });
    defer fx.renderer.destroyTexture(linear);
    try testing.expectError(error.WrongColorSpace, fx.renderer.createMaterial(.{ .base_color_texture = linear }, "linear texture"));
}

test "planning places transparent draws last and back to front, and reflection changes only cull winding" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, true);
    const mask = try fx.renderer.createMaterial(.{ .alpha_mode = .mask }, "mask");
    const blend = try fx.renderer.createMaterial(.{ .alpha_mode = .blend }, "blend");
    const double_sided = try fx.renderer.createMaterial(.{ .double_sided = true }, "double sided");
    defer fx.renderer.destroyMaterial(mask);
    defer fx.renderer.destroyMaterial(blend);
    defer fx.renderer.destroyMaterial(double_sided);

    try fx.renderer.begin(testView(32));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = blend, .world = Mat4.translation(.init(0, 0, -2)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(0, 0, -4)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = mask, .world = Mat4.translation(.init(0, 0, -1)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = blend, .world = Mat4.translation(.init(0, 0, -8)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.scaling(.init(-1, 1, 1)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = double_sided, .world = Mat4.translation(.init(0, 0, -3)) });
    try fx.renderer.plan();
    try testing.expectEqualSlices(u32, &.{ 4, 2, 5, 1, 3, 0 }, fx.renderer.order.items);
    try testing.expectEqual(Cull.back_cw, fx.renderer.draws.items[4].pipeline_key.cull);
    try testing.expectEqual(Cull.back_ccw, fx.renderer.draws.items[1].pipeline_key.cull);
    try testing.expectEqual(Cull.none, fx.renderer.draws.items[5].pipeline_key.cull);

    try finishTestFrame(&fx);
    try testing.expectEqual(@as(usize, 5), fx.renderer.pipelines.items.len);
    var saw_mask = false;
    var saw_blend = false;
    var saw_clockwise = false;
    var saw_double_sided = false;
    for (fx.renderer.pipelines.items) |entry| {
        saw_mask = saw_mask or entry.key.alpha == .mask;
        saw_blend = saw_blend or entry.key.alpha == .blend;
        saw_clockwise = saw_clockwise or entry.key.cull == .back_cw;
        saw_double_sided = saw_double_sided or entry.key.cull == .none;
    }
    try testing.expect(saw_mask and saw_blend and saw_clockwise and saw_double_sided);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

test "draw submission refuses stale handles materials submeshes and transforms" {
    var fx = try TestFixture.init(1, 64);
    defer fx.deinit();
    const colored = try testMesh(&fx.renderer, true);
    const no_color = try testMesh(&fx.renderer, false);

    try testing.expectError(error.NotRecording, fx.renderer.drawMesh(.{ .mesh = colored, .material = fx.material, .world = .identity }));
    try fx.renderer.begin(testView(64));
    try testing.expectError(error.InvalidMesh, fx.renderer.drawMesh(.{ .mesh = .none, .material = fx.material, .world = .identity }));
    try testing.expectError(error.InvalidMaterial, fx.renderer.drawMesh(.{ .mesh = colored, .material = .none, .world = .identity }));
    try testing.expectError(error.InvalidSubmesh, fx.renderer.drawMesh(.{ .mesh = colored, .material = fx.material, .submesh = 1, .world = .identity }));
    var bad = Mat4.identity;
    bad.cols[2][1] = std.math.nan(f32);
    try testing.expectError(error.InvalidTransform, fx.renderer.drawMesh(.{ .mesh = colored, .material = fx.material, .world = bad }));
    try fx.renderer.drawMesh(.{ .mesh = no_color, .material = fx.material, .world = .identity });

    var uv_model = unlitModel();
    uv_model.id = core.ContentId.fromString("test:shading.requires_uv");
    uv_model.requires = StreamSet.of(&.{ .position, .uv0 });
    uv_model.optional = StreamSet.of(&.{.color});
    try fx.renderer.registerShadingModel(uv_model);
    const uv_material = try fx.renderer.createMaterial(.{ .shading = uv_model.id }, "requires uv");
    defer fx.renderer.destroyMaterial(uv_material);
    try testing.expectError(error.MissingStream, fx.renderer.drawMesh(.{
        .mesh = no_color,
        .material = uv_material,
        .world = .identity,
    }));

    fx.renderer.destroyMesh(colored);
    try testing.expectError(error.InvalidMesh, fx.renderer.drawMesh(.{ .mesh = colored, .material = fx.material, .world = .identity }));
    try testing.expectEqual(@as(usize, 1), fx.renderer.draws.items.len);
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
    try testing.expectError(error.InvalidMesh, fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity }));
}

const material_test_size = 32;
const material_test_bytes = material_test_size * material_test_size * 4;

fn materialQuad(renderer: *Renderer) !MeshHandle {
    const positions = [_]Vec3{
        .init(-0.8, -0.8, -2), .init(0.8, -0.8, -2),
        .init(0.8, 0.8, -2),   .init(-0.8, 0.8, -2),
    };
    const uvs = [_][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = 6 }};
    const streams = [_]asset.MeshStream{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) },
        .{ .semantic = .uv0, .format = .float32x2, .bytes = std.mem.sliceAsBytes(&uvs) },
    };
    return renderer.createMesh(.{
        .vertex_count = positions.len,
        .streams = &streams,
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&indices),
        .submeshes = &submeshes,
        .bounds = try asset.Mesh.computeBounds(&positions),
    }, "material readback quad");
}

const MaterialCase = enum { mask, blend, mirrored };
const MaterialImage = struct { pixels: [material_test_bytes]u8, format: rhi.TextureFormat };

fn renderMaterialCase(samples: u32, case: MaterialCase) !MaterialImage {
    var fx = try TestFixture.init(samples, material_test_size);
    defer fx.deinit();
    const mesh = try materialQuad(&fx.renderer);

    var texture_pixels = [_]u8{ 255, 0, 0, 0, 0, 255, 0, 255 };
    const texture = try fx.renderer.createTexture(.{ .width = 2, .height = 1, .pixels = &texture_pixels }, .{
        .filter = .nearest,
        .wrap = .clamp,
    });
    defer fx.renderer.destroyTexture(texture);
    const material = switch (case) {
        .mask => try fx.renderer.createMaterial(.{
            .base_color_texture = texture,
            .alpha_mode = .mask,
            .alpha_cutoff = 0.5,
            .double_sided = true,
        }, "mask readback"),
        .blend => try fx.renderer.createMaterial(.{
            .base_color = .{ 1, 0, 0, 0.5 },
            .alpha_mode = .blend,
            .double_sided = true,
        }, "blend readback"),
        .mirrored => try fx.renderer.createMaterial(.{
            .base_color = .{ 0, 1, 0, 1 },
        }, "mirrored readback"),
    };
    defer fx.renderer.destroyMaterial(material);

    const readback = try fx.device.createBuffer(.{
        .label = "material readback",
        .size = material_test_bytes,
        .usage = .{ .copy_dst = true },
        .memory = .readback,
    });
    defer fx.device.destroyBuffer(readback);

    try fx.renderer.begin(.{
        .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 },
        .target_size = .{ .width = material_test_size, .height = material_test_size },
        // Blue, so a discarded fragment is told apart from the black of an unmasked,
        // premultiplied transparent texel.
        .clear_color = .{ 0, 0, 1, 1 },
    });
    try fx.renderer.drawMesh(.{
        .mesh = mesh,
        .material = material,
        .world = if (case == .mirrored) Mat4.scaling(.init(-1, 1, 1)) else .identity,
    });
    const frame = try fx.device.beginFrame();
    var cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, frame);
    var pass = try cmd.beginRenderPass(fx.renderer.passDesc(frame, false));
    try fx.renderer.record(pass);
    pass.end();
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
    try cmd.copyTextureToBuffer(.{
        .src = frame.surface_texture,
        .size = .{ .width = material_test_size, .height = material_test_size },
        .dst = readback,
    });
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
    try cmd.submit();
    try fx.device.endFrame();
    fx.device.waitIdle();

    var pixels: [material_test_bytes]u8 = undefined;
    const mapped = try fx.device.mapBuffer(readback);
    @memcpy(&pixels, mapped[0..material_test_bytes]);
    fx.device.unmapBuffer(readback);
    return .{ .pixels = pixels, .format = fx.device.capabilities().surface_format };
}

fn materialTexel(image: *const [material_test_bytes]u8, x: usize, y: usize) [4]u8 {
    const offset = (y * material_test_size + x) * 4;
    return image[offset..][0..4].*;
}

test "textured mask blend and mirrored winding read back at 1x and 4x" {
    if (rhi.backend == .null) return;
    for ([_]u32{ 1, 4 }) |samples| {
        const masked = try renderMaterialCase(samples, .mask);
        const bgra = masked.format == .bgra8_unorm or masked.format == .bgra8_unorm_srgb;
        const clear: [4]u8 = if (bgra) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 };
        const green = [4]u8{ 0, 255, 0, 255 };
        try testing.expectEqual(clear, materialTexel(&masked.pixels, 12, 16));
        try testing.expectEqual(green, materialTexel(&masked.pixels, 20, 16));
        // At 1x a cutout has no edge blend: every pixel is the clear colour or the texel.
        if (samples == 1) for (0..material_test_size) |y| for (0..material_test_size) |x| {
            const texel = materialTexel(&masked.pixels, x, y);
            try testing.expect(std.mem.eql(u8, &texel, &clear) or std.mem.eql(u8, &texel, &green));
        };

        const blended = try renderMaterialCase(samples, .blend);
        const pixel = materialTexel(&blended.pixels, 16, 16);
        const red_index: usize = if (bgra) 2 else 0;
        const blue_index: usize = if (bgra) 0 else 2;
        try testing.expect(pixel[red_index] >= 187 and pixel[red_index] <= 189);
        try testing.expect(pixel[blue_index] >= 187 and pixel[blue_index] <= 189);
        try testing.expectEqual(@as(u8, 255), pixel[3]);

        const mirrored = try renderMaterialCase(samples, .mirrored);
        try testing.expectEqual(green, materialTexel(&mirrored.pixels, 16, 16));
        try testing.expectEqual(clear, materialTexel(&mirrored.pixels, 1, 1));
    }
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
    for (order) |mesh| try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });

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
