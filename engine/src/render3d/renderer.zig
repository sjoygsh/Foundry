//! Foundry's 3D renderer: registered shading models, resident resources and ordered draws.
//!
//! Design: `docs/design/meshes.md` §7, ADR-0049 and ADR-0054.

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");
const asset = @import("asset");
const skinning = @import("skinning.zig");

const camera_mod = @import("camera.zig");
const frustum_mod = @import("frustum.zig");
const lighting = @import("lighting.zig");
pub const Light = lighting.Light;
pub const max_lights = lighting.max_lights;
const Allocator = std.mem.Allocator;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const log = core.log.scoped(.render3d);

pub const lit_id = core.ContentId.fromString("foundry:shading.lit");

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
    metallic_roughness: bool = false,
    normal: bool = false,
    occlusion: bool = false,
    emissive: bool = false,
    casts_shadow: bool = false,
};

pub const ShaderStage = struct {
    bytes: []const u8,
    entry: []const u8,
};

pub const ShadingVariants = struct {
    /// Optional subsets in colour, UV0, tangent order (required streams add no bit).
    /// Stage byte/entry storage is borrowed; registration copies the descriptor slices.
    vertex: []const ShaderStage,
    /// Opaque/blend share index 0; mask is index 1; normal mapping adds 2.
    fragment: []const ShaderStage,
};

pub const ShadingFeatures = struct { normal_mapping: bool = false };

pub const ShadingModel = struct {
    id: core.ContentId,
    requires: StreamSet,
    optional: StreamSet = .{},
    reads: MaterialFields = .{},
    features: ShadingFeatures = .{},
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

/// A rectangle of a texture's level 0, in texels from its top-left corner.
pub const TextureRegion = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
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
    metallic: f32 = 0,
    roughness: f32 = 1,
    metallic_roughness_texture: TextureHandle = .none,
    normal_texture: TextureHandle = .none,
    normal_scale: f32 = 1,
    occlusion_texture: TextureHandle = .none,
    occlusion_strength: f32 = 1,
    emissive: [3]f32 = .{ 0, 0, 0 },
    emissive_texture: TextureHandle = .none,
    emissive_strength: f32 = 1,
    casts_shadow: bool = true,
};

fn builtinStage(comptime name: []const u8, comptime metal_entry: []const u8) ShaderStage {
    return switch (rhi.backend) {
        .metal => .{ .bytes = @embedFile("unlit_metallib"), .entry = metal_entry },
        .null => .{ .bytes = "null-backend-shader", .entry = metal_entry },
        .vulkan => .{ .bytes = @embedFile(name), .entry = "main" },
    };
}

fn toneStage(comptime name: []const u8, comptime metal_entry: []const u8) ShaderStage {
    return switch (rhi.backend) {
        .metal => .{ .bytes = @embedFile("tone_metallib"), .entry = metal_entry },
        .null => .{ .bytes = "null-backend-shader", .entry = metal_entry },
        .vulkan => .{ .bytes = @embedFile(name), .entry = "main" },
    };
}

fn unlitModel() ShadingModel {
    return .{
        .id = unlit_id,
        .requires = StreamSet.of(&.{.position}),
        .optional = StreamSet.of(&.{ .uv0, .color }),
        .reads = .{ .base_color = true, .base_color_texture = true, .alpha = true, .casts_shadow = true },
        .variants = .{
            .vertex = comptime &.{
                builtinStage("unlit_vertex_spirv", "vertexMain"),
                builtinStage("unlit_color_vertex_spirv", "vertexColor"),
                builtinStage("unlit_uv_vertex_spirv", "vertexUv"),
                builtinStage("unlit_uv_color_vertex_spirv", "vertexUvColor"),
            },
            .fragment = comptime &.{
                builtinStage("unlit_fragment_spirv", "fragmentMain"),
                builtinStage("unlit_mask_fragment_spirv", "fragmentMask"),
            },
        },
    };
}

fn litStage(comptime name: []const u8, comptime entry: []const u8) ShaderStage {
    return switch (rhi.backend) {
        .metal => .{ .bytes = @embedFile("lit_metallib"), .entry = entry },
        .null => .{ .bytes = "null-backend-shader", .entry = entry },
        .vulkan => .{ .bytes = @embedFile(name), .entry = "main" },
    };
}

fn shadowStage(comptime name: []const u8, comptime entry: []const u8) ShaderStage {
    return switch (rhi.backend) {
        .metal => .{ .bytes = @embedFile("shadow_metallib"), .entry = entry },
        .null => .{ .bytes = "null-backend-shader", .entry = entry },
        .vulkan => .{ .bytes = @embedFile(name), .entry = "main" },
    };
}
fn shadowVertexStages() [4]ShaderStage {
    return .{ shadowStage("shadow_vertex_0_spirv", "vertexMain"), shadowStage("shadow_vertex_1_spirv", "vertexColor"), shadowStage("shadow_vertex_2_spirv", "vertexUv"), shadowStage("shadow_vertex_3_spirv", "vertexUvColor") };
}
fn shadowFragmentStages() [2]ShaderStage {
    return .{ shadowStage("shadow_fragment_0_spirv", "fragmentMain"), shadowStage("shadow_fragment_1_spirv", "fragmentMask") };
}

fn litModel() ShadingModel {
    return .{
        .id = lit_id,
        .requires = StreamSet.of(&.{ .position, .normal }),
        .optional = StreamSet.of(&.{ .color, .uv0, .tangent }),
        .reads = .{ .base_color = true, .base_color_texture = true, .alpha = true, .metallic_roughness = true, .normal = true, .occlusion = true, .emissive = true, .casts_shadow = true },
        .features = .{ .normal_mapping = true },
        .variants = .{
            .vertex = comptime &.{
                litStage("lit_vertex_0_spirv", "vertexLit0"),
                litStage("lit_vertex_1_spirv", "vertexLit1"),
                litStage("lit_vertex_2_spirv", "vertexLit2"),
                litStage("lit_vertex_3_spirv", "vertexLit3"),
                litStage("lit_vertex_4_spirv", "vertexLit4"),
                litStage("lit_vertex_5_spirv", "vertexLit5"),
                litStage("lit_vertex_6_spirv", "vertexLit6"),
                litStage("lit_vertex_7_spirv", "vertexLit7"),
            },
            .fragment = comptime &.{
                litStage("lit_fragment_0_spirv", "fragmentLit0"),
                litStage("lit_fragment_1_spirv", "fragmentLit1"),
                litStage("lit_fragment_2_spirv", "fragmentLit2"),
                litStage("lit_fragment_3_spirv", "fragmentLit3"),
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
    jobs: core.Jobs = core.jobs.serial,
    max_skinned_vertices: u32 = 262_144,
    frames_in_flight: u32 = 2,
    sample_count: u32 = 4,
    /// Frustum culling (§7.6). Off exists for the equivalence test and a sample's
    /// `--cull=off`; it is not a game setting, because culling never changes a pixel.
    cull: bool = true,
    shadow_size: u32 = 2048,
    /// Reversed-Z depth moves away from the light with negative raster bias.
    shadow_bias_constant: f32 = -1,
    shadow_bias_slope: f32 = -1,
    shadow_bias_clamp: f32 = 0,
    /// Receiver offset in world-space shadow texels, along its geometric normal.
    shadow_normal_offset: f32 = 1.5,
    /// Anisotropic filtering for linear, mipmapped material textures, 1 (none) to 16: a floor
    /// seen at a grazing angle stays sharp instead of blurring to its smallest level. A device
    /// that has less samples with what it has (`rhi.resource.SamplerDesc.max_anisotropy`).
    max_anisotropy: u8 = 8,
};

pub const FrameView = struct {
    camera: camera_mod.Camera,
    target_size: Extent2D,
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },
    exposure_ev100: ?f32 = null,
    ambient: [3]f32 = .{ 0, 0, 0 },
    shadow_distance: f32 = 25,
};

pub const Mesh = opaque {};
pub const MeshHandle = core.Handle(Mesh);

pub const MeshDraw = struct {
    mesh: MeshHandle,
    submesh: u32 = 0,
    material: MaterialHandle,
    world: Mat4,
    /// Copied at submission; required exactly for a skinned mesh.
    skin: ?[]const Mat4 = null,
};

pub const Stats = struct {
    draws: u32 = 0,
    triangles: u32 = 0,
    pipeline_binds: u32 = 0,
    culled: u32 = 0,
    blended: u32 = 0,
    lights: u32 = 0,
    shadow_draws: u32 = 0,
    shadow_culled: u32 = 0,
    skinned_draws: u32 = 0,
    skinned_vertices: u32 = 0,
    skin_budget_dropped: u32 = 0,
    /// Retained lights the frame had no room for (`Instances.submit`).
    instance_lights_dropped: u32 = 0,
    /// Retained instances a reload left undrawable this frame (`Instances.submit`).
    instances_refused: u32 = 0,
    /// Draws of a requested model whose parts were still loading (`Content.drawModel`), which
    /// submitted nothing.
    pending_models: u32 = 0,
    /// Since the previous `begin` (`runtime-geometry.md` §4.3): uploads happen between frames,
    /// so they are counted into the frame that follows them.
    mesh_updates: u32 = 0,
    texture_writes: u32 = 0,
    uploaded_bytes: u64 = 0,
};

/// What `begin` folds into the frame's `Stats`.
const UploadCounts = struct {
    mesh_updates: u32 = 0,
    texture_writes: u32 = 0,
    uploaded_bytes: u64 = 0,
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
    InvalidLight,
    TooManyLights,
    InvalidShadowCaster,
    MissingStream,
    UnknownShadingModel,
    DuplicateShadingModel,
    InvalidShadingModel,
    InvalidMaterialValue,
    WrongColorSpace,
    TextureTooLarge,
    NotRecording,
    DepthFormatUnsupported,
    InvalidSkinCount,
    InvalidSkinMatrix,
    UnexpectedSkin,
    MissingSkin,
    /// A write between `begin` and the end of `recordFrame` (`runtime-geometry.md` §4.2).
    InFrame,
    /// `writeTexture` on a mipmapped texture, whose chain one region cannot keep consistent.
    HasMips,
    /// `writeTextureChain` on a texture made without mips.
    NoMips,
    InvalidRegion,
    InvalidPixelLength,
    TextureSizeMismatch,
    InvalidMipChain,
} || asset.MeshError || rhi.ResourceError || rhi.MapError || rhi.CommandError || rhi.VertexUpdateError || Allocator.Error;

/// A kept upload buffer (M27 Step 10). `reusable_from` is the first frame in which no
/// submitted copy can still be reading it.
const Staging = struct {
    buffer: rhi.BufferHandle,
    size: u64,
    reserved: bool = false,
    mapped: bool = false,
    reusable_from: u64 = 0,
};

/// Mapped upload memory a staged load holds from its prepare to its finish.
pub const StagingReservation = struct {
    buffer: rhi.BufferHandle,
    bytes: []u8,
};

/// What the staging buffers kept between loads may hold: a few 2048² chains, which the gallery
/// loads two at a time on the default pool.
const max_kept_staging: u64 = 64 << 20;
/// Frames without a reservation after which every idle staging buffer is given back.
const staging_idle_frames: u64 = 300;
/// Where each of a mesh's streams starts in its staging buffer: a multiple of every texel and
/// index size, and of the 4 bytes Vulkan asks of a copy's offset.
const staging_alignment: u64 = 16;

const MeshState = struct {
    vertex_buffers: [rhi.pipeline.max_vertex_buffers]rhi.BufferHandle = @splat(.none),
    /// What each vertex buffer holds, which an update may fill with fewer bytes (§5.1).
    vertex_capacity: [rhi.pipeline.max_vertex_buffers]u64 = @splat(0),
    formats: [rhi.pipeline.max_vertex_buffers]?asset.MeshVertexFormat = @splat(null),
    stream_mask: u8,
    index_buffer: rhi.BufferHandle,
    index_capacity: u64 = 0,
    index_format: asset.MeshIndexFormat,
    submeshes: []asset.Submesh,
    bounds: asset.MeshAabb,
    /// One box per submesh, over the positions its indices reach: what a rigid draw is culled
    /// and sorted by, since one draw is one submesh. Computed at upload (`meshes.md` §13).
    submesh_bounds: []asset.MeshAabb = &.{},
    skin: ?skinning.Bind = null,
    /// Destroyed inside a frame's submission window: no longer drawable, still recorded for
    /// the draws already submitted, and freed when the window closes (§4.2).
    doomed: bool = false,
};

/// Each submesh's box, over exactly the positions its indices reach. `mesh` is validated, so
/// every index is in range and every position finite.
fn submeshBounds(gpa: Allocator, mesh: asset.Mesh) Allocator.Error![]asset.MeshAabb {
    const positions = for (mesh.streams) |stream| {
        if (stream.semantic == .position) break stream.bytes;
    } else unreachable; // `validate` requires a position stream.
    const out = try gpa.alloc(asset.MeshAabb, mesh.submeshes.len);
    const width = mesh.index_format.size();
    for (mesh.submeshes, out) |submesh, *box| {
        var first = true;
        for (0..submesh.index_count) |n| {
            const at = (@as(usize, submesh.first_index) + n) * width;
            const index: usize = switch (mesh.index_format) {
                .uint16 => std.mem.readInt(u16, mesh.indices[at..][0..2], .little),
                .uint32 => std.mem.readInt(u32, mesh.indices[at..][0..4], .little),
            };
            const bytes = positions[index * 12 ..][0..12];
            const p = Vec3.init(
                @bitCast(std.mem.readInt(u32, bytes[0..4], .little)),
                @bitCast(std.mem.readInt(u32, bytes[4..8], .little)),
                @bitCast(std.mem.readInt(u32, bytes[8..12], .little)),
            );
            if (first) {
                box.* = .{ .min = p, .max = p };
                first = false;
            } else {
                box.min = Vec3.init(@min(box.min.x, p.x), @min(box.min.y, p.y), @min(box.min.z, p.z));
                box.max = Vec3.init(@max(box.max.x, p.x), @max(box.max.y, p.y), @max(box.max.z, p.z));
            }
        }
        // A submesh with no index draws nothing; the mesh's box is the safe answer.
        if (first) box.* = mesh.bounds;
    }
    return out;
}

const TextureState = struct {
    gpu: rhi.TextureHandle,
    sampler: rhi.SamplerHandle,
    color_space: asset.ColorSpace,
    mipmaps: bool,
    /// Fixed for the texture's life: a write changes texels, never these (§5.2).
    size: rhi.resource.Extent2D,
    levels: u32,
    /// Live materials whose bind group names this texture (`runtime-geometry.md` §4.1).
    binds: u32 = 0,
    /// Destroyed while bound: its handle answers nothing, and its GPU object goes with the
    /// last material that binds it.
    released: bool = false,
};

const SamplerKey = struct { filter: Filter, wrap: Wrap, mipmaps: bool };
const SamplerState = struct { key: SamplerKey, handle: rhi.SamplerHandle };

const MaterialUniform = extern struct {
    base_color: [4]f32,
    alpha_cutoff: f32,
    _padding: [3]f32 = @splat(0),
    surface: [4]f32,
    emissive_strength: [4]f32,
};

const MaterialState = struct {
    model: u32,
    desc: MaterialDesc,
    uniform: rhi.BufferHandle,
    group: rhi.BindGroupHandle,
    /// The textures `group` names, defaults included; each holds one of their `binds`.
    bound: [5]TextureHandle,
    /// As `MeshState.doomed`.
    doomed: bool = false,
};

const ModelState = struct {
    desc: ShadingModel,
    vertex: [8]rhi.ShaderModuleHandle,
    fragment: [4]rhi.ShaderModuleHandle,
};

const Cull = enum { back_ccw, back_cw, none };
const PipelineKey = struct {
    model: u32,
    /// Colour, UV0, float colour, required normal, tangent; not the variant index.
    vertex_layout: u5,
    normal_map: bool = false,
    shadow: bool = false,
    alpha: AlphaMode,
    cull: Cull,

    fn eql(a: PipelineKey, b: PipelineKey) bool {
        return a.model == b.model and a.vertex_layout == b.vertex_layout and a.alpha == b.alpha and a.cull == b.cull and a.normal_map == b.normal_map and a.shadow == b.shadow;
    }
};

const PipelineState = struct { key: PipelineKey, pipeline: rhi.RenderPipelineHandle };

const FrameSlot = struct {
    uniform: rhi.BufferHandle,
    group: rhi.BindGroupHandle,
    shadow_group: rhi.BindGroupHandle = .none,
};

const DrawConstants = extern struct {
    world: Mat4,
    cofactor: [3][4]f32,
};

fn unitValue(value: f32) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 1;
}

fn drawConstants(world: Mat4) DrawConstants {
    const x = Vec3.init(world.cols[0][0], world.cols[0][1], world.cols[0][2]);
    const y = Vec3.init(world.cols[1][0], world.cols[1][1], world.cols[1][2]);
    const z = Vec3.init(world.cols[2][0], world.cols[2][1], world.cols[2][2]);
    const columns = [3]Vec3{ Vec3.cross(y, z), Vec3.cross(z, x), Vec3.cross(x, y) };
    var result: DrawConstants = .{ .world = world, .cofactor = undefined };
    for (columns, 0..) |column, i| result.cofactor[i] = .{ column.x, column.y, column.z, 0 };
    return result;
}

const DrawItem = struct {
    mesh: MeshHandle,
    submesh: u32,
    world: Mat4,
    material: MaterialHandle,
    pipeline_key: PipelineKey,
    alpha: AlphaMode,
    depth: f32,
    bounds: frustum_mod.Bounds,
    submission: u32,
    palette_offset: usize = 0,
    skin_offset: ?u32 = null,
    kept: bool = false,
    budget_dropped: bool = false,
};

pub const Renderer = struct {
    gpa: Allocator,
    device: *rhi.Device,
    config: Config,
    surface_format: rhi.TextureFormat,
    /// What the texture loader's decode may read off the main thread: this device's limit,
    /// copied at `init`, so no background thread reaches the device (ADR-0061, decision 5).
    texture_limits: asset.texture_decode.Limits,

    frame_layout: rhi.BindGroupLayoutHandle,
    material_layout: rhi.BindGroupLayoutHandle,
    pipeline_layout: rhi.PipelineLayoutHandle,
    slots: []FrameSlot,
    shadow_fallback: rhi.TextureHandle,
    shadow_sampler: rhi.SamplerHandle,
    shadow_target: rhi.TextureHandle = .none,
    shadow_vertex: [4]rhi.ShaderModuleHandle = @splat(.none),
    shadow_fragment: [2]rhi.ShaderModuleHandle = @splat(.none),
    shadow_fit: ?lighting.ShadowFit = null,
    shadow_order: std.ArrayList(u32) = .empty,
    tone_layout: rhi.BindGroupLayoutHandle,
    tone_pipeline_layout: rhi.PipelineLayoutHandle,
    tone_vertex: rhi.ShaderModuleHandle,
    tone_fragment: rhi.ShaderModuleHandle,
    tone_pipeline: rhi.RenderPipelineHandle,
    tone_sampler: rhi.SamplerHandle,
    tone_group: rhi.BindGroupHandle,

    models: std.ArrayList(ModelState),
    pipelines: std.ArrayList(PipelineState),
    samplers: std.ArrayList(SamplerState),
    meshes: core.HandlePool(Mesh, MeshState),
    textures: core.HandlePool(Texture, TextureState),
    materials: core.HandlePool(Material, MaterialState),
    white_texture: TextureHandle,
    linear_white: TextureHandle,
    flat_normal: TextureHandle,
    draws: std.ArrayList(DrawItem),
    order: std.ArrayList(u32),
    planned_draws: ?u32,
    palettes: std.ArrayList(Mat4) = .empty,
    skin_buffer: ?rhi.FrameVertexBuffer = null,
    skin_bytes: []align(16) u8 = &.{},
    skin_vertex: rhi.BufferHandle = .none,
    skin_frame: ?u64 = null,
    /// Upload buffers a staged texture load copied through, kept for the next (M27 Step 10).
    staging: std.ArrayList(Staging) = .empty,
    /// The newest frame this renderer has prepared: what a staging buffer's reuse is timed by.
    latest_frame: u64 = 0,
    /// The frame of the last reservation, so a burst's buffers are given back after it.
    last_reservation: u64 = 0,
    /// Meshes and materials destroyed inside the submission window, freed when it closes.
    doomed_meshes: std.ArrayList(MeshHandle) = .empty,
    doomed_materials: std.ArrayList(MaterialHandle) = .empty,
    uploads: UploadCounts = .{},

    color_target: rhi.TextureHandle,
    hdr_target: rhi.TextureHandle,
    depth_target: rhi.TextureHandle,
    target_size: Extent2D,
    pass_color: [1]rhi.command.ColorAttachment,

    view: FrameView,
    view_matrix: Mat4,
    view_projection: Mat4,
    frustum: frustum_mod.Frustum,
    recording: bool,
    frame: ?rhi.FrameContext,
    stats: Stats,
    last_stats: Stats,
    lights: [max_lights]Light,
    light_count: u32,
    has_shadow_caster: bool,

    const Self = @This();

    /// HDR world targets and a tone map to the device's surface format are renderer-owned.
    pub fn init(gpa: Allocator, device: *rhi.Device, config: Config) Error!Self {
        var self = try initResources(gpa, device, config);
        errdefer self.deinit();
        try self.registerShadingModel(unlitModel());
        try self.registerShadingModel(litModel());
        const white = asset.Image{ .width = 1, .height = 1, .pixels = @constCast(&[_]u8{ 255, 255, 255, 255 }) };
        self.white_texture = try self.createTexture(white, .{ .filter = .nearest, .wrap = .clamp, .label = "render3d white" });
        self.linear_white = try self.createTexture(white, .{ .color_space = .linear, .filter = .nearest, .wrap = .clamp });
        const normal = asset.Image{ .width = 1, .height = 1, .pixels = @constCast(&[_]u8{ 128, 128, 255, 255 }) };
        self.flat_normal = try self.createTexture(normal, .{ .color_space = .linear, .filter = .nearest, .wrap = .clamp });
        return self;
    }

    /// Resource ownership transfers once: later model/texture failures use `deinit`,
    /// never both `deinit` and these construction errdefers.
    fn initResources(gpa: Allocator, device: *rhi.Device, config: Config) Error!Self {
        if (config.frames_in_flight == 0 or !rhi.isValidSampleCount(config.sample_count) or @as(u64, config.max_skinned_vertices) * 40 > std.math.maxInt(usize)) {
            return error.InvalidConfig;
        }
        if (config.shadow_size != 0 and config.shadow_size != 1024 and config.shadow_size != 2048 and config.shadow_size != 4096) return error.InvalidConfig;
        if (config.max_anisotropy < 1 or config.max_anisotropy > rhi.resource.SamplerDesc.max_anisotropy_limit) return error.InvalidConfig;
        for ([_]f32{ config.shadow_bias_constant, config.shadow_bias_slope, config.shadow_bias_clamp, config.shadow_normal_offset }) |value| {
            if (!std.math.isFinite(value)) return error.InvalidConfig;
        }
        const surface_format = device.capabilities().surface_format;

        const frame_layout = try device.createBindGroupLayout(.{
            .label = "render3d frame",
            .entries = &.{
                .{ .binding = 0, .type = .uniform_buffer, .visibility = .{ .vertex = true, .fragment = true } },
                .{ .binding = 1, .type = .sampled_texture, .texture = .depth, .visibility = .{ .fragment = true } },
                .{ .binding = 2, .type = .sampler, .sampler = .comparison, .visibility = .{ .fragment = true } },
            },
        });
        errdefer device.destroyBindGroupLayout(frame_layout);

        const material_layout = try device.createBindGroupLayout(.{
            .label = "render3d material",
            .entries = &.{
                .{ .binding = 0, .type = .uniform_buffer, .visibility = .{ .fragment = true } },
                .{ .binding = 1, .type = .sampled_texture, .visibility = .{ .fragment = true } },
                .{ .binding = 2, .type = .sampler, .visibility = .{ .fragment = true } },
                .{ .binding = 3, .type = .sampled_texture, .visibility = .{ .fragment = true } },
                .{ .binding = 4, .type = .sampler, .visibility = .{ .fragment = true } },
                .{ .binding = 5, .type = .sampled_texture, .visibility = .{ .fragment = true } },
                .{ .binding = 6, .type = .sampler, .visibility = .{ .fragment = true } },
                .{ .binding = 7, .type = .sampled_texture, .visibility = .{ .fragment = true } },
                .{ .binding = 8, .type = .sampler, .visibility = .{ .fragment = true } },
                .{ .binding = 9, .type = .sampled_texture, .visibility = .{ .fragment = true } },
                .{ .binding = 10, .type = .sampler, .visibility = .{ .fragment = true } },
            },
        });
        errdefer device.destroyBindGroupLayout(material_layout);

        const pipeline_layout = try device.createPipelineLayout(.{
            .label = "render3d shading model",
            .bind_group_layouts = &.{ frame_layout, .none, material_layout },
            .inline_constant_bytes = @sizeOf(DrawConstants),
        });
        errdefer device.destroyPipelineLayout(pipeline_layout);

        const shadow_fallback = try device.createTexture(.{
            .label = "render3d empty shadow",
            .size = .{ .width = 1, .height = 1 },
            .format = .depth32_float,
            .usage = .{ .depth_stencil = true, .sampled = true },
        });
        errdefer device.destroyTexture(shadow_fallback);
        const shadow_sampler = try device.createSampler(.{ .label = "render3d shadow comparison", .compare = .greater_equal, .min_filter = .linear, .mag_filter = .linear });
        errdefer device.destroySampler(shadow_sampler);
        // Initialise even though Step 3's uniform always disables shadow lookup.
        const shadow_cmd = try device.beginCommandBuffer();
        var shadow_consumed = false;
        errdefer if (!shadow_consumed) shadow_cmd.discard();
        const shadow_pass = try shadow_cmd.beginRenderPass(.{
            .label = "render3d empty shadow",
            .color = &.{},
            .depth = .{ .texture = shadow_fallback, .load = .{ .clear = .{ .depth_stencil = .{ .depth = 0 } } }, .store = .store, .initial_state = .undefined, .final_state = .shader_read },
        });
        shadow_pass.end();
        shadow_consumed = true;
        try shadow_cmd.submit();

        const tone_layout = try device.createBindGroupLayout(.{
            .label = "render3d tone map",
            .entries = &.{
                .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
                .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
            },
        });
        errdefer device.destroyBindGroupLayout(tone_layout);
        const tone_pipeline_layout = try device.createPipelineLayout(.{ .label = "render3d tone map", .bind_group_layouts = &.{tone_layout} });
        errdefer device.destroyPipelineLayout(tone_pipeline_layout);
        const tone_vertex_stage = toneStage("tone_vertex_spirv", "toneVertex");
        const tone_fragment_stage = toneStage("tone_fragment_spirv", "toneFragment");
        const tone_vertex = try device.createShaderModule(.{ .label = "render3d tone vertex", .bytes = tone_vertex_stage.bytes });
        errdefer device.destroyShaderModule(tone_vertex);
        const tone_fragment = try device.createShaderModule(.{ .label = "render3d tone fragment", .bytes = tone_fragment_stage.bytes });
        errdefer device.destroyShaderModule(tone_fragment);
        const tone_pipeline = try device.createRenderPipeline(.{
            .label = "render3d tone map",
            .layout = tone_pipeline_layout,
            .vertex_shader = tone_vertex,
            .vertex_entry = tone_vertex_stage.entry,
            .fragment_shader = tone_fragment,
            .fragment_entry = tone_fragment_stage.entry,
            .vertex_buffers = &.{},
            .color_targets = &.{.{ .format = surface_format }},
            .primitive = .{ .cull_mode = .none },
            .sample_count = 1,
        });
        errdefer device.destroyRenderPipeline(tone_pipeline);
        const tone_sampler = try device.createSampler(.{ .label = "render3d HDR sampler" });
        errdefer device.destroySampler(tone_sampler);

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
                .size = @sizeOf(lighting.FrameUniform),
                .usage = .{ .uniform = true },
                .memory = .upload,
            });
            errdefer device.destroyBuffer(uniform);
            const group = try device.createBindGroup(.{
                .label = "render3d frame",
                .layout = frame_layout,
                .entries = &.{
                    .{ .binding = 0, .resource = .{ .uniform_buffer = .{ .buffer = uniform, .size = @sizeOf(lighting.FrameUniform) } } },
                    .{ .binding = 1, .resource = .{ .sampled_texture = shadow_fallback } },
                    .{ .binding = 2, .resource = .{ .sampler = shadow_sampler } },
                },
            });
            slot.* = .{ .uniform = uniform, .group = group };
            built_slots += 1;
        }

        return .{
            .gpa = gpa,
            .device = device,
            .config = config,
            .surface_format = surface_format,
            .texture_limits = .{ .max_dimension = device.capabilities().max_texture_dimension },
            .frame_layout = frame_layout,
            .material_layout = material_layout,
            .pipeline_layout = pipeline_layout,
            .slots = slots,
            .shadow_fallback = shadow_fallback,
            .shadow_sampler = shadow_sampler,
            .tone_layout = tone_layout,
            .tone_pipeline_layout = tone_pipeline_layout,
            .tone_vertex = tone_vertex,
            .tone_fragment = tone_fragment,
            .tone_pipeline = tone_pipeline,
            .tone_sampler = tone_sampler,
            .tone_group = .none,
            .models = .empty,
            .pipelines = .empty,
            .samplers = .empty,
            .meshes = .empty,
            .textures = .empty,
            .materials = .empty,
            .white_texture = .none,
            .linear_white = .none,
            .flat_normal = .none,
            .draws = .empty,
            .order = .empty,
            .planned_draws = null,
            .color_target = .none,
            .hdr_target = .none,
            .depth_target = .none,
            .target_size = .{ .width = 0, .height = 0 },
            .pass_color = undefined,
            .view = .{ .camera = .{}, .target_size = .{ .width = 1, .height = 1 } },
            .view_matrix = .identity,
            .view_projection = .identity,
            .frustum = .fromViewProjection(.identity),
            .recording = false,
            .frame = null,
            .stats = .{},
            .last_stats = .{},
            .lights = undefined,
            .light_count = 0,
            .has_shadow_caster = false,
        };
    }

    /// Frees every entry directly, doomed or not, rather than through the destroys: a destroy
    /// passes over a doomed entry, so a teardown built on it would never empty its pool.
    pub fn deinit(self: *Self) void {
        self.recording = false;
        self.doomed_meshes.deinit(self.gpa);
        self.doomed_materials.deinit(self.gpa);
        if (self.skin_buffer) |*buffer| buffer.deinit();
        self.gpa.free(self.skin_bytes);
        self.palettes.deinit(self.gpa);
        for (self.staging.items) |entry| {
            // The registry is torn down first, and gives back every reservation it held.
            std.debug.assert(!entry.reserved);
            self.device.destroyBuffer(entry.buffer);
        }
        self.staging.deinit(self.gpa);
        while (self.materials.count() != 0) {
            var it = self.materials.iterator();
            const entry = it.next().?;
            self.destroyMaterialState(entry.value);
            _ = self.materials.remove(entry.id);
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
            self.destroyMeshState(entry.value);
            _ = self.meshes.remove(entry.id);
        }
        self.meshes.deinit(self.gpa);
        self.draws.deinit(self.gpa);
        self.order.deinit(self.gpa);
        self.shadow_order.deinit(self.gpa);
        for (self.pipelines.items) |entry| self.device.destroyRenderPipeline(entry.pipeline);
        self.pipelines.deinit(self.gpa);
        for (self.models.items) |model| self.destroyModel(model);
        self.models.deinit(self.gpa);
        for (self.shadow_vertex) |shader| if (!shader.isNone()) self.device.destroyShaderModule(shader);
        for (self.shadow_fragment) |shader| if (!shader.isNone()) self.device.destroyShaderModule(shader);

        if (!self.color_target.isNone()) self.device.destroyTexture(self.color_target);
        if (!self.tone_group.isNone()) self.device.destroyBindGroup(self.tone_group);
        if (!self.hdr_target.isNone()) self.device.destroyTexture(self.hdr_target);
        if (!self.depth_target.isNone()) self.device.destroyTexture(self.depth_target);
        for (self.slots) |slot| {
            self.device.destroyBindGroup(slot.group);
            if (!slot.shadow_group.isNone()) self.device.destroyBindGroup(slot.shadow_group);
            self.device.destroyBuffer(slot.uniform);
        }
        self.gpa.free(self.slots);
        if (!self.shadow_target.isNone()) self.device.destroyTexture(self.shadow_target);
        self.device.destroyTexture(self.shadow_fallback);
        self.device.destroySampler(self.shadow_sampler);
        self.device.destroyRenderPipeline(self.tone_pipeline);
        self.device.destroyShaderModule(self.tone_vertex);
        self.device.destroyShaderModule(self.tone_fragment);
        self.device.destroyPipelineLayout(self.tone_pipeline_layout);
        self.device.destroyBindGroupLayout(self.tone_layout);
        self.device.destroySampler(self.tone_sampler);
        self.device.destroyPipelineLayout(self.pipeline_layout);
        self.device.destroyBindGroupLayout(self.material_layout);
        self.device.destroyBindGroupLayout(self.frame_layout);
        self.* = undefined;
    }

    pub fn registerShadingModel(self: *Self, model: ShadingModel) Error!void {
        for (self.models.items) |existing| if (existing.desc.id.eql(model.id)) return error.DuplicateShadingModel;
        if (model.requires.bits == 0 or model.requires.bits & model.optional.bits != 0 or
            !model.requires.has(.position) or
            (model.requires.bits | model.optional.bits) & ~StreamSet.of(&.{ .position, .normal, .tangent, .uv0, .color }).bits != 0)
        {
            return error.InvalidShadingModel;
        }

        if (model.optional.bits & ~StreamSet.of(&.{ .uv0, .color, .tangent }).bits != 0 or
            model.variants.vertex.len != (@as(usize, 1) << @intCast(@popCount(model.optional.bits))) or
            model.variants.fragment.len != (if (model.features.normal_mapping) @as(usize, 4) else 2) or
            (model.features.normal_mapping and !model.requires.has(.normal))) return error.InvalidShadingModel;
        var owned = model;
        owned.variants.vertex = try self.gpa.dupe(ShaderStage, model.variants.vertex);
        errdefer self.gpa.free(owned.variants.vertex);
        owned.variants.fragment = try self.gpa.dupe(ShaderStage, model.variants.fragment);
        // destroyModel owns both slices once the state is constructed.
        var state: ModelState = .{ .desc = owned, .vertex = @splat(.none), .fragment = @splat(.none) };
        errdefer {
            for (state.vertex) |shader| if (!shader.isNone()) self.device.destroyShaderModule(shader);
            for (state.fragment) |shader| if (!shader.isNone()) self.device.destroyShaderModule(shader);
            self.gpa.free(owned.variants.fragment);
        }
        for (model.variants.vertex, 0..) |stage, i| {
            state.vertex[i] = try self.device.createShaderModule(.{ .label = "render3d vertex variant", .bytes = stage.bytes });
        }
        for (model.variants.fragment, 0..) |stage, i| {
            state.fragment[i] = try self.device.createShaderModule(.{ .label = "render3d fragment variant", .bytes = stage.bytes });
        }
        try self.models.append(self.gpa, state);
    }

    /// Uploads a decoded image, generating its mip chain first if `options.mipmaps` asks:
    /// `asset.mips.generate` followed by `createTextureFromChain`, which is what the texture
    /// loader's decode and finish do on their two threads (`background.md` §7).
    pub fn createTexture(self: *Self, image: asset.Image, options: TextureOptions) Error!TextureHandle {
        try self.checkTextureSize(image.width, image.height);
        if (!options.mipmaps) return self.uploadTexture(image.width, image.height, image.pixels, null, null, options);
        var chain = try asset.mips.generate(self.gpa, image, options.color_space);
        defer chain.deinit(self.gpa);
        return self.createTextureFromChain(chain, options);
    }

    /// Uploads a chain made by `asset.mips.generate` in `options.color_space`: every level,
    /// one staging copy and one submit. The chain stays the caller's.
    pub fn createTextureFromChain(self: *Self, chain: asset.MipChain, options: TextureOptions) Error!TextureHandle {
        const base = chain.level(0);
        try self.checkTextureSize(base.width, base.height);
        return self.uploadTexture(base.width, base.height, chain.bytes, chain, null, options);
    }

    /// A texture whose bytes are already in `staged`, which `reserveStaging` made and a fill
    /// wrote off the main thread (M27 Step 10). The reservation is consumed whatever this
    /// returns: so is every reservation handed to a finish.
    pub fn createTextureFromStaged(self: *Self, width: u32, height: u32, chain: ?asset.MipChain, staged: StagingReservation, options: TextureOptions) Error!TextureHandle {
        self.checkTextureSize(width, height) catch |err| {
            self.returnStaging(staged, false);
            return err;
        };
        return self.uploadTexture(width, height, &.{}, chain, staged, options);
    }

    /// Mapped upload memory of at least `size` bytes, for a fill to write on another thread.
    /// A kept buffer is reused once the frame ring has passed every frame that could have
    /// read it, and a new one is made only when none is free.
    pub fn reserveStaging(self: *Self, label: []const u8, size: usize) Error!StagingReservation {
        self.last_reservation = self.latest_frame;
        var best: ?usize = null;
        for (self.staging.items, 0..) |entry, i| {
            if (entry.reserved or entry.size < size or entry.reusable_from > self.latest_frame) continue;
            if (best == null or entry.size < self.staging.items[best.?].size) best = i;
        }
        const index = best orelse made: {
            try self.staging.ensureUnusedCapacity(self.gpa, 1);
            const buffer = try self.device.createBuffer(.{ .label = label, .size = size, .usage = .{ .copy_src = true }, .memory = .upload });
            self.staging.appendAssumeCapacity(.{ .buffer = buffer, .size = size });
            break :made self.staging.items.len - 1;
        };
        const entry = &self.staging.items[index];
        // Not reserved if this fails, so it is kept or trimmed like any idle buffer.
        const mapped = try self.device.mapBuffer(entry.buffer);
        entry.reserved = true;
        entry.mapped = true;
        return .{ .buffer = entry.buffer, .bytes = mapped[0..size] };
    }

    /// Gives a reservation back. `used` says a submitted copy may read it, so it waits out the
    /// frame ring; otherwise it is free at once.
    pub fn returnStaging(self: *Self, staged: StagingReservation, used: bool) void {
        const entry = for (self.staging.items) |*entry| {
            if (entry.buffer.eql(staged.buffer)) break entry;
        } else unreachable; // Only `reserveStaging` makes one.
        std.debug.assert(entry.reserved);
        self.unmapStaging(staged);
        entry.reserved = false;
        // A copy submitted now is ordered before the submission of the frame after the newest
        // one prepared, and one queue completes in order (`rhi/lifetime.zig`). That frame's
        // slot is waited for by the frame `frames_in_flight` after it (`FrameContext.slot`).
        if (used) entry.reusable_from = self.latest_frame + 1 + self.slots.len;
        self.trimStaging(max_kept_staging);
    }

    /// Ends a reservation's mapping, once: before its copy is recorded, or when it is given back.
    fn unmapStaging(self: *Self, staged: StagingReservation) void {
        for (self.staging.items) |*entry| if (entry.buffer.eql(staged.buffer)) {
            if (entry.mapped) self.device.unmapBuffer(entry.buffer);
            entry.mapped = false;
        };
    }

    /// Keeps at most `limit` bytes of buffers nobody has reserved, giving back the ones that
    /// can be reused last first. A destroy is deferred past their copies (ADR-0035).
    fn trimStaging(self: *Self, limit: u64) void {
        while (true) {
            var kept: u64 = 0;
            var last: ?usize = null;
            for (self.staging.items, 0..) |entry, i| {
                if (entry.reserved) continue;
                kept += entry.size;
                if (last == null or entry.reusable_from >= self.staging.items[last.?].reusable_from) last = i;
            }
            if (kept <= limit) return;
            self.device.destroyBuffer(self.staging.items[last.?].buffer);
            _ = self.staging.swapRemove(last.?);
        }
    }

    /// Records the newest frame, and once a burst of reservations is long over gives every
    /// idle staging buffer back, so a finished load does not hold upload memory for good.
    fn seeFrame(self: *Self, index: u64) void {
        self.latest_frame = @max(self.latest_frame, index);
        if (self.staging.items.len != 0 and self.latest_frame - self.last_reservation > staging_idle_frames) self.trimStaging(0);
    }

    fn checkTextureSize(self: *Self, width: u32, height: u32) Error!void {
        const caps = self.device.capabilities();
        if (width == 0 or height == 0 or width > caps.max_texture_dimension or height > caps.max_texture_dimension) {
            return error.TextureTooLarge;
        }
    }

    fn uploadTexture(self: *Self, width: u32, height: u32, pixels: []const u8, chain: ?asset.MipChain, staged: ?StagingReservation, options: TextureOptions) Error!TextureHandle {
        // Consumed on every path: unused if nothing was submitted, used once something was.
        var submitted = false;
        defer if (staged) |reservation| self.returnStaging(reservation, submitted);
        const levels: u32 = if (chain) |value| value.levelCount() else 1;

        const gpu = try self.device.createTexture(.{
            .label = options.label,
            .size = .{ .width = width, .height = height },
            .format = switch (options.color_space) {
                .srgb => .rgba8_unorm_srgb,
                .linear => .rgba8_unorm,
            },
            // `copy_src` so a texture's levels can be read back and compared: M27 Step 5 pins
            // that both loading paths upload the same bytes.
            .usage = .{ .sampled = true, .copy_dst = true, .copy_src = true },
            .mip_levels = levels,
        });
        errdefer self.device.destroyTexture(gpu);
        const sampler = try self.samplerFor(.{ .filter = options.filter, .wrap = options.wrap, .mipmaps = levels > 1 }, options.label);
        const staging = if (staged) |reservation| reservation.buffer else try self.stagingBuffer(options.label, pixels);
        defer if (staged == null) self.device.destroyBuffer(staging);
        if (staged) |reservation| self.unmapStaging(reservation);

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
            try cmd.copyBufferToTexture(.{ .src = staging, .dst = gpu, .size = .{ .width = width, .height = height } });
        }
        try cmd.textureBarrier(&.{.{ .texture = gpu, .from = .copy_dst, .to = .shader_read }});
        // Whatever `submit` answers, the queue may have the copy.
        submitted = true;
        try cmd.submit();
        self.uploads.uploaded_bytes += if (staged) |reservation| reservation.bytes.len else if (chain) |value| value.bytes.len else pixels.len;

        return self.textures.add(self.gpa, .{
            .gpu = gpu,
            .sampler = sampler,
            .color_space = options.color_space,
            .mipmaps = levels > 1,
            .size = .{ .width = width, .height = height },
            .levels = levels,
        });
    }

    /// Writes an RGBA8 rectangle into a texture made without mips (`runtime-geometry.md` §5.2).
    /// `pixels` is exactly `region.width * region.height * 4` bytes, rows top first. The GPU
    /// texture is the same object afterwards, so every material that binds it stays valid.
    /// Refused inside a frame's submission window (§4.2); a refusal writes nothing.
    pub fn writeTexture(self: *Self, handle: TextureHandle, region: TextureRegion, pixels: []const u8) Error!void {
        if (self.recording) return error.InFrame;
        const state = self.writableTexture(handle) orelse return error.InvalidTexture;
        // One region of a chain cannot be kept consistent without regenerating every level.
        if (state.mipmaps) return error.HasMips;
        const right = @as(u64, region.x) + region.width;
        const bottom = @as(u64, region.y) + region.height;
        if (region.width == 0 or region.height == 0 or right > state.size.width or bottom > state.size.height) return error.InvalidRegion;
        if (pixels.len != @as(u64, region.width) * region.height * asset.Image.channels) return error.InvalidPixelLength;
        const levels = [1]asset.mips.Level{.{ .width = region.width, .height = region.height, .offset = 0 }};
        try self.copyIntoTexture(state.*, pixels, &levels, .{ .x = region.x, .y = region.y });
    }

    /// Replaces every level of a mipmapped texture with `chain`, made by `asset.mips.generate`
    /// in `color_space` from an image of the texture's own size (§5.2). Size, format and
    /// colour space never change; a texture that must is made new. Refused inside a frame's
    /// submission window (§4.2); a refusal writes nothing.
    pub fn writeTextureChain(self: *Self, handle: TextureHandle, chain: asset.MipChain, color_space: asset.ColorSpace) Error!void {
        if (self.recording) return error.InFrame;
        const state = self.writableTexture(handle) orelse return error.InvalidTexture;
        if (!state.mipmaps) return error.NoMips;
        if (color_space != state.color_space) return error.WrongColorSpace;
        if (chain.levels.len == 0) return error.InvalidMipChain;
        if (chain.levels[0].width != state.size.width or chain.levels[0].height != state.size.height) return error.TextureSizeMismatch;
        if (chain.levels.len != state.levels) return error.InvalidMipChain;
        for (chain.levels, 0..) |level, i| {
            const expected = state.size.mipLevel(@intCast(i));
            if (level.width != expected.width or level.height != expected.height) return error.InvalidMipChain;
            if (level.offset > chain.bytes.len or level.byteSize() > chain.bytes.len - level.offset) return error.InvalidMipChain;
        }
        try self.copyIntoTexture(state.*, chain.bytes, chain.levels, .{});
    }

    /// A live texture a caller made: the renderer's own defaults are every material's fallback,
    /// so writing one would recolour materials that never named it.
    fn writableTexture(self: *Self, handle: TextureHandle) ?*TextureState {
        if (handle.eql(self.white_texture) or handle.eql(self.linear_white) or handle.eql(self.flat_normal)) return null;
        return self.liveTexture(handle);
    }

    /// Copies `levels` of `bytes` into `state`'s texture through one kept staging buffer. Its
    /// barrier from `shader_read` waits, on one queue, for every earlier submission's reads.
    fn copyIntoTexture(self: *Self, state: TextureState, bytes: []const u8, levels: []const asset.mips.Level, origin: rhi.resource.Origin2D) Error!void {
        const staged = try self.reserveStaging("render3d texture write", bytes.len);
        var submitted = false;
        defer self.returnStaging(staged, submitted);
        @memcpy(staged.bytes, bytes);
        self.unmapStaging(staged);

        const cmd = try self.device.beginCommandBuffer();
        var consumed = false;
        errdefer if (!consumed) cmd.discard();
        try cmd.textureBarrier(&.{.{ .texture = state.gpu, .from = .shader_read, .to = .copy_dst }});
        for (levels, 0..) |level, i| try cmd.copyBufferToTexture(.{
            .src = staged.buffer,
            .src_offset = level.offset,
            .dst = state.gpu,
            .dst_mip_level = @intCast(i),
            .dst_origin = origin,
            .size = .{ .width = level.width, .height = level.height },
        });
        try cmd.textureBarrier(&.{.{ .texture = state.gpu, .from = .copy_dst, .to = .shader_read }});
        consumed = true;
        submitted = true;
        try cmd.submit();
        self.uploads.texture_writes += 1;
        self.uploads.uploaded_bytes += bytes.len;
    }

    /// The handle answers nothing from now on. **A texture a live material binds keeps its GPU
    /// object** until the last such material is destroyed or rebuilt without it (§4.1), so a
    /// caller may destroy textures and materials in either order.
    pub fn destroyTexture(self: *Self, handle: TextureHandle) void {
        if (handle.eql(self.white_texture) or handle.eql(self.linear_white) or handle.eql(self.flat_normal)) return;
        const state = self.liveTexture(handle) orelse return;
        if (state.binds != 0) {
            state.released = true;
            return;
        }
        self.destroyTextureState(state);
        _ = self.textures.remove(handle);
    }

    /// A texture a caller may still name: issued, and not destroyed.
    fn liveTexture(self: *Self, handle: TextureHandle) ?*TextureState {
        const state = self.textures.get(handle) orelse return null;
        return if (state.released) null else state;
    }

    /// One material no longer binds `handle`; a released texture goes with its last binding.
    fn unbindTexture(self: *Self, handle: TextureHandle) void {
        const state = self.textures.get(handle).?; // A binding keeps its entry.
        state.binds -= 1;
        if (!state.released or state.binds != 0) return;
        self.destroyTextureState(state);
        _ = self.textures.remove(handle);
    }

    pub fn createMaterial(self: *Self, desc: MaterialDesc, label: []const u8) Error!MaterialHandle {
        var state = try self.buildMaterial(desc, label);
        errdefer self.destroyMaterialState(&state);
        return self.materials.add(self.gpa, state);
    }

    /// Replaces a live material's description, keeping its handle.
    ///
    /// **Validated exactly as `createMaterial` is, and a refusal changes nothing**: the new
    /// uniform and bind group are built before the old ones are released. This is how an
    /// owner that follows content — `Content`, after a record or its texture reloads —
    /// keeps the handle it gave out. A draw already submitted this frame keeps its pipeline
    /// key and binds the new group when it is recorded.
    pub fn updateMaterial(self: *Self, handle: MaterialHandle, desc: MaterialDesc, label: []const u8) Error!void {
        if (!self.isMaterial(handle)) return error.InvalidMaterial;
        const state = try self.buildMaterial(desc, label);
        const slot = self.materials.get(handle).?;
        self.destroyMaterialState(slot);
        slot.* = state;
    }

    /// Issued and not destroyed, so a draw may name it.
    pub fn isMaterial(self: *const Self, handle: MaterialHandle) bool {
        const state = self.materials.getConst(handle) orelse return false;
        return !state.doomed;
    }

    fn buildMaterial(self: *Self, desc: MaterialDesc, label: []const u8) Error!MaterialState {
        const model = self.modelIndex(desc.shading) orelse return error.UnknownShadingModel;
        for (desc.base_color) |channel| if (!std.math.isFinite(channel) or channel < 0 or channel > 1) return error.InvalidMaterialValue;
        if (!std.math.isFinite(desc.alpha_cutoff) or desc.alpha_cutoff < 0 or desc.alpha_cutoff > 1) return error.InvalidMaterialValue;

        const reads = self.models.items[model].desc.reads;
        if (reads.metallic_roughness and (!unitValue(desc.metallic) or !unitValue(desc.roughness))) return error.InvalidMaterialValue;
        if (reads.normal and !std.math.isFinite(desc.normal_scale)) return error.InvalidMaterialValue;
        if (reads.occlusion and !unitValue(desc.occlusion_strength)) return error.InvalidMaterialValue;
        if (reads.emissive) {
            for (desc.emissive) |channel| if (!unitValue(channel)) return error.InvalidMaterialValue;
            if (!std.math.isFinite(desc.emissive_strength) or desc.emissive_strength < 0) return error.InvalidMaterialValue;
        }
        const requested = [5]TextureHandle{
            if (reads.base_color_texture) desc.base_color_texture else .none,
            if (reads.metallic_roughness) desc.metallic_roughness_texture else .none,
            if (reads.normal) desc.normal_texture else .none,
            if (reads.occlusion) desc.occlusion_texture else .none,
            if (reads.emissive) desc.emissive_texture else .none,
        };
        const defaults = [5]TextureHandle{ self.white_texture, self.linear_white, self.flat_normal, self.linear_white, self.white_texture };
        var textures: [5]TextureState = undefined;
        var bound: [5]TextureHandle = undefined;
        for (requested, defaults, 0..) |handle, fallback, i| {
            bound[i] = if (handle.isNone()) fallback else handle;
            const texture = self.liveTexture(bound[i]) orelse return error.InvalidTexture;
            const expected: asset.ColorSpace = if (i == 0 or i == 4) .srgb else .linear;
            if (texture.color_space != expected) return error.WrongColorSpace;
            textures[i] = texture.*;
        }
        const uniform = try self.device.createBuffer(.{
            .label = label,
            .size = @sizeOf(MaterialUniform),
            .usage = .{ .uniform = true },
            .memory = .upload,
        });
        errdefer self.device.destroyBuffer(uniform);
        const mapped = try self.device.mapBuffer(uniform);
        const value: MaterialUniform = .{
            .base_color = desc.base_color,
            .alpha_cutoff = desc.alpha_cutoff,
            .surface = .{ desc.metallic, desc.roughness, desc.normal_scale, desc.occlusion_strength },
            .emissive_strength = .{ desc.emissive[0], desc.emissive[1], desc.emissive[2], desc.emissive_strength },
        };
        @memcpy(mapped[0..@sizeOf(MaterialUniform)], std.mem.asBytes(&value));
        self.device.unmapBuffer(uniform);

        var entries: [11]rhi.pipeline.BindGroupEntry = undefined;
        entries[0] = .{ .binding = 0, .resource = .{ .uniform_buffer = .{ .buffer = uniform, .size = @sizeOf(MaterialUniform) } } };
        for (textures, 0..) |texture, i| {
            entries[1 + 2 * i] = .{ .binding = @intCast(1 + 2 * i), .resource = .{ .sampled_texture = texture.gpu } };
            entries[2 + 2 * i] = .{ .binding = @intCast(2 + 2 * i), .resource = .{ .sampler = texture.sampler } };
        }
        const group = try self.device.createBindGroup(.{
            .label = label,
            .layout = self.material_layout,
            .entries = &entries,
        });
        // Nothing after this can fail, so a refusal never leaves a binding counted.
        for (bound) |handle| self.textures.get(handle).?.binds += 1;
        return .{ .model = model, .desc = desc, .uniform = uniform, .group = group, .bound = bound };
    }

    /// Inside a frame's submission window the material is only doomed: a draw already
    /// submitted with it is still recorded, a new one is refused, and it is freed when the
    /// window closes (§4.2).
    pub fn destroyMaterial(self: *Self, handle: MaterialHandle) void {
        const state = self.materials.get(handle) orelse return;
        if (state.doomed) return;
        if (self.recording) {
            if (self.doomed_materials.append(self.gpa, handle)) |_| {
                state.doomed = true;
                return;
            } else |_| {
                // No room to remember it: freed now, and a draw already submitted with it is
                // skipped at recording, as any draw of a gone material is.
                log.warn("material destroyed mid-frame without room to defer it; freed now", .{});
            }
        }
        self.destroyMaterialState(state);
        _ = self.materials.remove(handle);
    }

    fn destroyMaterialState(self: *Self, state: *MaterialState) void {
        self.device.destroyBindGroup(state.group);
        self.device.destroyBuffer(state.uniform);
        for (state.bound) |texture| self.unbindTexture(texture);
    }

    pub fn materialFields(self: *const Self, id: core.ContentId) ?MaterialFields {
        return self.models.items[self.modelIndex(id) orelse return null].desc.reads;
    }

    fn modelIndex(self: *const Self, id: core.ContentId) ?u32 {
        for (self.models.items, 0..) |model, i| if (model.desc.id.eql(id)) return @intCast(i);
        return null;
    }

    fn destroyModel(self: *Self, model: ModelState) void {
        self.gpa.free(model.desc.variants.vertex);
        self.gpa.free(model.desc.variants.fragment);
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
            // Only a linear, mipmapped texture has a footprint to filter along; a nearest
            // texture is pixel art and keeps its texels.
            .max_anisotropy = if (key.filter == .linear and key.mipmaps) self.config.max_anisotropy else 1,
        });
        errdefer self.device.destroySampler(handle);
        try self.samplers.append(self.gpa, .{ .key = key, .handle = handle });
        return handle;
    }

    pub fn createMesh(self: *Self, mesh: asset.Mesh, label: []const u8) Error!MeshHandle {
        var state = try self.uploadMesh(mesh, label, null);
        errdefer self.destroyMeshState(&state);
        return self.meshes.add(self.gpa, state);
    }

    /// Replaces a mesh's contents and keeps its handle (`runtime-geometry.md` §5.1). `mesh` may
    /// differ in every respect. A stream that fits its buffer — same slot and format, no more
    /// bytes than it holds — is copied into it; any other is given a new buffer, and the old
    /// one is retired behind ADR-0035's deferral. **A refusal changes nothing.** Refused inside
    /// a frame's submission window, where a draw validated against the old contents may still
    /// be recorded (§4.2).
    pub fn updateMesh(self: *Self, handle: MeshHandle, mesh: asset.Mesh, label: []const u8) Error!void {
        if (self.recording) return error.InFrame;
        // A mesh is doomed only inside the window, so one reached here never is.
        const old = self.meshes.get(handle) orelse return error.InvalidMesh;
        const next = try self.uploadMesh(mesh, label, old);
        for (old.vertex_buffers, next.vertex_buffers) |was, now| {
            if (!was.isNone() and !was.eql(now)) self.device.destroyBuffer(was);
        }
        if (!old.index_buffer.eql(next.index_buffer)) self.device.destroyBuffer(old.index_buffer);
        if (old.skin) |bind| bind.deinit(self.gpa);
        self.gpa.free(old.submeshes);
        self.gpa.free(old.submesh_bounds);
        old.* = next;
        self.uploads.mesh_updates += 1;
    }

    /// A validated mesh's GPU and CPU state, its bytes copied through one kept staging buffer
    /// (§5.3). With `reuse`, a stream that fits that mesh's buffer is copied into it; the
    /// caller retires the buffers the result no longer names. On failure, only what this made
    /// is freed, and `reuse` is untouched.
    fn uploadMesh(self: *Self, mesh: asset.Mesh, label: []const u8, reuse: ?*const MeshState) Error!MeshState {
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
        // Buffers this call made, as opposed to ones `reuse` lends it.
        var made: [rhi.pipeline.max_vertex_buffers + 1]rhi.BufferHandle = @splat(.none);
        errdefer {
            for (made) |buffer| if (!buffer.isNone()) self.device.destroyBuffer(buffer);
            if (state.skin) |bind| bind.deinit(self.gpa);
            self.gpa.free(state.submeshes);
            self.gpa.free(state.submesh_bounds);
        }
        state.submesh_bounds = try submeshBounds(self.gpa, mesh);
        if (mesh.joint_bounds.len != 0) state.skin = skinning.Bind.init(self.gpa, mesh) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSkinCount,
        };

        const Upload = struct {
            destination: rhi.BufferHandle,
            bytes: []const u8,
            offset: u64,
            /// Reused, so its contents are what earlier frames read.
            kept: bool,
        };
        var uploads: [rhi.pipeline.max_vertex_buffers + 1]Upload = undefined;
        var upload_count: usize = 0;
        var staged_size: u64 = 0;

        for (mesh.streams) |stream| {
            const slot: usize = stream.semantic.slot();
            state.formats[slot] = stream.format;
            // Influences never enter a pipeline; bind TRS streams remain CPU-only too.
            if (stream.semantic == .joints or stream.semantic == .weights) continue;
            state.stream_mask |= @as(u8, 1) << @intCast(slot);
            if (state.skin != null and slot <= 2) continue;
            const fits = if (reuse) |old|
                !old.vertex_buffers[slot].isNone() and old.formats[slot] == stream.format and stream.bytes.len <= old.vertex_capacity[slot]
            else
                false;
            if (fits) {
                state.vertex_buffers[slot] = reuse.?.vertex_buffers[slot];
                state.vertex_capacity[slot] = reuse.?.vertex_capacity[slot];
            } else {
                state.vertex_buffers[slot] = try self.device.createBuffer(.{
                    .label = label,
                    .size = stream.bytes.len,
                    .usage = .{ .vertex = true, .copy_dst = true },
                    .memory = .device_local,
                });
                state.vertex_capacity[slot] = stream.bytes.len;
                made[slot] = state.vertex_buffers[slot];
            }
            uploads[upload_count] = .{ .destination = state.vertex_buffers[slot], .bytes = stream.bytes, .offset = staged_size, .kept = fits };
            upload_count += 1;
            staged_size += std.mem.alignForward(u64, stream.bytes.len, staging_alignment);
        }

        const index_fits = if (reuse) |old| mesh.indices.len <= old.index_capacity else false;
        if (index_fits) {
            state.index_buffer = reuse.?.index_buffer;
            state.index_capacity = reuse.?.index_capacity;
        } else {
            state.index_buffer = try self.device.createBuffer(.{
                .label = label,
                .size = mesh.indices.len,
                .usage = .{ .index = true, .copy_dst = true },
                .memory = .device_local,
            });
            state.index_capacity = mesh.indices.len;
            made[made.len - 1] = state.index_buffer;
        }
        uploads[upload_count] = .{ .destination = state.index_buffer, .bytes = mesh.indices, .offset = staged_size, .kept = index_fits };
        upload_count += 1;
        staged_size += mesh.indices.len;

        const staged = try self.reserveStaging(label, staged_size);
        // Consumed on every path: unused if nothing was submitted, used once something was.
        var submitted = false;
        defer self.returnStaging(staged, submitted);
        for (uploads[0..upload_count]) |upload| @memcpy(staged.bytes[upload.offset..][0..upload.bytes.len], upload.bytes);
        self.unmapStaging(staged);

        // A kept buffer was last left for shaders to read; on one queue its barrier waits for
        // every earlier submission's reads, so a frame already submitted never sees this copy.
        var barriers: [rhi.pipeline.max_vertex_buffers + 1]rhi.command.BufferBarrier = undefined;
        for (uploads[0..upload_count], 0..) |upload, i| {
            barriers[i] = .{ .buffer = upload.destination, .from = if (upload.kept) .shader_read else .undefined, .to = .copy_dst };
        }
        const cmd = try self.device.beginCommandBuffer();
        var consumed = false;
        errdefer if (!consumed) cmd.discard();
        try cmd.bufferBarrier(barriers[0..upload_count]);
        for (uploads[0..upload_count]) |upload| {
            try cmd.copyBufferToBuffer(.{
                .src = staged.buffer,
                .src_offset = upload.offset,
                .dst = upload.destination,
                .size = upload.bytes.len,
            });
        }
        for (barriers[0..upload_count]) |*barrier| {
            barrier.from = .copy_dst;
            barrier.to = .shader_read;
        }
        try cmd.bufferBarrier(barriers[0..upload_count]);
        consumed = true;
        // Whatever `submit` answers, the queue may have the copy.
        submitted = true;
        try cmd.submit();
        for (uploads[0..upload_count]) |upload| self.uploads.uploaded_bytes += upload.bytes.len;
        return state;
    }

    /// Inside a frame's submission window the mesh is only doomed, as `destroyMaterial`'s is.
    pub fn destroyMesh(self: *Self, handle: MeshHandle) void {
        const state = self.meshes.get(handle) orelse return;
        if (state.doomed) return;
        if (self.recording) {
            if (self.doomed_meshes.append(self.gpa, handle)) |_| {
                state.doomed = true;
                return;
            } else |_| {
                log.warn("mesh destroyed mid-frame without room to defer it; freed now", .{});
            }
        }
        self.destroyMeshState(state);
        _ = self.meshes.remove(handle);
    }

    /// Frees what was destroyed inside the window, once nothing can still record it: when
    /// `recordFrame` ends, when a frame is abandoned by the next `begin`, and at `deinit`.
    fn freeDoomed(self: *Self) void {
        for (self.doomed_materials.items) |handle| {
            const state = self.materials.get(handle).?;
            self.destroyMaterialState(state);
            _ = self.materials.remove(handle);
        }
        self.doomed_materials.clearRetainingCapacity();
        for (self.doomed_meshes.items) |handle| {
            const state = self.meshes.get(handle).?;
            self.destroyMeshState(state);
            _ = self.meshes.remove(handle);
        }
        self.doomed_meshes.clearRetainingCapacity();
    }

    pub fn begin(self: *Self, view: FrameView) Error!void {
        if (!view.camera.isValid() or view.target_size.isEmpty()) return error.InvalidCamera;
        for (view.clear_color) |channel| {
            if (!std.math.isFinite(channel) or channel < 0 or channel > 65504) return error.InvalidCamera;
        }
        if (view.clear_color[3] > 1) return error.InvalidCamera;
        if (view.exposure_ev100) |ev| {
            const scale = lighting.exposureScale(ev);
            if (!std.math.isFinite(ev) or !std.math.isFinite(scale) or scale <= 0) return error.InvalidCamera;
        }
        for (view.ambient) |channel| if (!std.math.isFinite(channel) or channel < 0) return error.InvalidCamera;
        if (!std.math.isFinite(view.shadow_distance) or view.shadow_distance <= 0) return error.InvalidCamera;
        // A frame begun and never recorded is abandoned: nothing will record its draws.
        self.freeDoomed();
        self.view = view;
        self.view_matrix = view.camera.viewMatrix();
        self.view_projection = view.camera.viewProjection(view.target_size.width, view.target_size.height);
        self.frustum = .fromViewProjection(self.view_projection);
        self.draws.clearRetainingCapacity();
        self.palettes.clearRetainingCapacity();
        self.skin_frame = null;
        self.skin_vertex = .none;
        self.order.clearRetainingCapacity();
        self.planned_draws = null;
        self.frame = null;
        self.stats = .{
            .mesh_updates = self.uploads.mesh_updates,
            .texture_writes = self.uploads.texture_writes,
            .uploaded_bytes = self.uploads.uploaded_bytes,
        };
        self.uploads = .{};
        self.light_count = 0;
        self.has_shadow_caster = false;
        self.recording = true;
    }

    /// Submission-order values; every refusal leaves the frame untouched.
    pub fn addLight(self: *Self, light: Light) Error!void {
        if (!self.recording or self.planned_draws != null or self.frame != null or self.skin_frame != null) return error.NotRecording;
        if (!lighting.valid(light)) return error.InvalidLight;
        if (light.casts_shadow and (light.kind != .directional or self.has_shadow_caster)) return error.InvalidShadowCaster;
        if (self.light_count == max_lights) return error.TooManyLights;
        self.lights[self.light_count] = light;
        self.light_count += 1;
        self.has_shadow_caster = self.has_shadow_caster or light.casts_shadow;
        self.stats.lights = self.light_count;
        self.planned_draws = null;
    }

    pub fn drawMesh(self: *Self, draw: MeshDraw) Error!void {
        if (!self.recording or self.frame != null or self.skin_frame != null) return error.NotRecording;
        const mesh = self.liveMesh(draw.mesh) orelse return error.InvalidMesh;
        const material = self.materials.getConst(draw.material) orelse return error.InvalidMaterial;
        if (material.doomed) return error.InvalidMaterial;
        const model = self.models.items[material.model].desc;
        if (draw.submesh >= mesh.submeshes.len) return error.InvalidSubmesh;
        if (!matrixFinite(draw.world)) return error.InvalidTransform;
        if (!(StreamSet{ .bits = mesh.stream_mask }).contains(model.requires)) return error.MissingStream;
        try self.validateSkin(draw.mesh, draw.skin);

        const has_uv = (model.optional.has(.uv0) or model.requires.has(.uv0)) and mesh.stream_mask & (@as(u8, 1) << @intFromEnum(asset.MeshSemantic.uv0)) != 0;
        const has_color = (model.optional.has(.color) or model.requires.has(.color)) and mesh.stream_mask & (@as(u8, 1) << @intFromEnum(asset.MeshSemantic.color)) != 0;
        const float_color = has_color and mesh.formats[@intFromEnum(asset.MeshSemantic.color)].? == .float32x4;
        const has_normal = model.requires.has(.normal);
        const has_tangent = (model.optional.has(.tangent) or model.requires.has(.tangent)) and mesh.stream_mask & 4 != 0;
        const normal_map = model.features.normal_mapping and !material.desc.normal_texture.isNone();
        if (normal_map and !has_tangent) return error.MissingStream;
        const vertex_layout: u5 = @as(u5, @intFromBool(has_color)) |
            (@as(u5, @intFromBool(has_uv)) << 1) |
            (@as(u5, @intFromBool(float_color)) << 2) |
            (@as(u5, @intFromBool(has_normal)) << 3) |
            (@as(u5, @intFromBool(has_tangent)) << 4);
        const cull: Cull = if (material.desc.double_sided)
            .none
        else if (draw.world.determinant() < 0)
            .back_cw
        else
            .back_ccw;

        const bounds = if (mesh.skin) |bind| skinning.posedBounds(bind.bounds, draw.skin.?, draw.world) else frustum_mod.Bounds.transformed(mesh.submesh_bounds[draw.submesh], draw.world);
        const view_center = self.view_matrix.mulPoint(bounds.center);
        const sort_depth = if (std.math.isFinite(view_center.z)) -view_center.z else std.math.inf(f32);
        try self.draws.ensureUnusedCapacity(self.gpa, 1);
        const palette_offset = self.palettes.items.len;
        if (draw.skin) |matrices| try self.palettes.appendSlice(self.gpa, matrices);
        self.draws.appendAssumeCapacity(.{
            .mesh = draw.mesh,
            .submesh = draw.submesh,
            .world = draw.world,
            .material = draw.material,
            .pipeline_key = .{ .model = material.model, .vertex_layout = vertex_layout, .normal_map = normal_map, .alpha = material.desc.alpha_mode, .cull = cull },
            .alpha = material.desc.alpha_mode,
            .depth = sort_depth,
            .bounds = bounds,
            .submission = @intCast(self.draws.items.len),
            .palette_offset = palette_offset,
        });
        self.planned_draws = null;
    }

    pub fn plan(self: *Self) Error!void {
        if (!self.recording or self.frame != null or self.skin_frame != null) return error.NotRecording;
        for (self.draws.items) |*item| {
            item.kept = false;
            item.skin_offset = null;
            item.budget_dropped = false;
        }
        self.order.clearRetainingCapacity();
        try self.order.ensureTotalCapacity(self.gpa, self.draws.items.len);
        var culled: u32 = 0;
        for (self.draws.items, 0..) |item, i| {
            if (self.config.cull and self.frustum.excludes(item.bounds)) {
                culled += 1;
                continue;
            }
            self.order.appendAssumeCapacity(@intCast(i));
        }
        std.mem.sort(u32, self.order.items, self.draws.items, drawLessThan);
        self.stats.culled = culled;
        self.shadow_fit = null;
        self.shadow_order.clearRetainingCapacity();
        self.stats.shadow_culled = 0;
        if (self.config.shadow_size != 0) for (self.lights[0..self.light_count]) |light| {
            if (!light.casts_shadow) continue;
            var fit = lighting.fitShadow(self.view.camera, @as(f32, @floatFromInt(self.view.target_size.width)) / @as(f32, @floatFromInt(self.view.target_size.height)), self.view.shadow_distance, light.world, self.config.shadow_size);
            // Inspect ALL submissions, not the camera's visible order: off-camera
            // objects above the receiver volume can still cast into it.
            for (self.draws.items) |item| {
                const material = self.materials.getConst(item.material) orelse continue;
                if (item.alpha != .blend and material.desc.casts_shadow) fit.includeCaster(item.bounds);
            }
            if (!matrixFinite(fit.matrix()) or !std.math.isFinite(fit.radius) or !std.math.isFinite(fit.max_z - fit.min_z) or !std.math.isFinite(fit.min_z) or !std.math.isFinite(fit.max_z) or !std.math.isFinite(fit.texel) or fit.texel <= 0) return error.InvalidCamera;
            if (!std.math.isFinite(self.config.shadow_normal_offset * fit.texel)) return error.InvalidConfig;
            const light_frustum = frustum_mod.Frustum.fromViewProjection(fit.matrix());
            try self.shadow_order.ensureTotalCapacity(self.gpa, self.draws.items.len);
            for (self.draws.items, 0..) |item, i| {
                const material = self.materials.getConst(item.material) orelse continue;
                if (item.alpha == .blend or !material.desc.casts_shadow) continue;
                if (self.config.cull and light_frustum.excludes(item.bounds)) {
                    self.stats.shadow_culled += 1;
                    continue;
                }
                self.shadow_order.appendAssumeCapacity(@intCast(i));
            }
            self.shadow_fit = fit;
        };
        for (self.order.items) |i| self.draws.items[i].kept = true;
        for (self.shadow_order.items) |i| self.draws.items[i].kept = true;
        self.stats.skinned_draws = 0;
        self.stats.skinned_vertices = 0;
        self.stats.skin_budget_dropped = 0;
        // Budget order is submission order, never the pipeline/depth sort or worker order.
        for (self.draws.items) |*item| {
            if (!item.kept) continue;
            const mesh = self.meshes.getConst(item.mesh) orelse continue;
            const bind = mesh.skin orelse continue;
            const count: u32 = @intCast(bind.positions.len);
            if (count > self.config.max_skinned_vertices - self.stats.skinned_vertices) {
                item.budget_dropped = true;
                self.stats.skin_budget_dropped += 1;
                continue;
            }
            item.skin_offset = self.stats.skinned_vertices;
            self.stats.skinned_vertices += count;
            self.stats.skinned_draws += 1;
        }
        self.removeBudgetDrops(&self.order);
        self.removeBudgetDrops(&self.shadow_order);
        self.planned_draws = @intCast(self.draws.items.len);
    }

    pub fn validateSkin(self: *const Self, handle: MeshHandle, matrices: ?[]const Mat4) Error!void {
        const mesh = self.liveMesh(handle) orelse return error.InvalidMesh;
        if (mesh.skin) |bind| {
            try skinning.validate(matrices orelse return error.MissingSkin, bind.bounds.len);
        } else if (matrices != null) return error.UnexpectedSkin;
    }

    pub fn meshJointCount(self: *const Self, handle: MeshHandle) ?usize {
        const mesh = self.liveMesh(handle) orelse return null;
        return if (mesh.skin) |bind| bind.bounds.len else 0;
    }

    /// A doomed mesh answers nothing, as a destroyed one does; only recording still reads it.
    fn liveMesh(self: *const Self, handle: MeshHandle) ?*const MeshState {
        const state = self.meshes.getConst(handle) orelse return null;
        return if (state.doomed) null else state;
    }

    fn removeBudgetDrops(self: *Self, order: *std.ArrayList(u32)) void {
        var len: usize = 0;
        for (order.items) |i| if (!self.draws.items[i].budget_dropped) {
            order.items[len] = i;
            len += 1;
        };
        order.items.len = len;
    }

    /// Optional host timing seam; `prepare` also calls it, without repeating completed work.
    /// It joins all jobs and submits copies before any pass is opened.
    /// Skins this frame's admitted vertices on the CPU and records their copy into `cmd`, the
    /// frame's own command buffer, ahead of the passes recorded after it.
    pub fn prepareSkin(self: *Self, cmd: *rhi.CommandBuffer, frame: rhi.FrameContext) Error!void {
        if (!self.recording) return error.NotRecording;
        if (frame.slot >= self.slots.len) return error.InvalidFrameSlot;
        if (!self.device.in_frame or frame.index != self.device.frame_index or frame.slot != self.device.frame_slot or !frame.surface_texture.eql(self.device.surface_texture)) return error.InvalidFrame;
        if (self.skin_frame) |index| {
            if (index != frame.index) return error.InvalidFrame;
            if (self.stats.skinned_vertices != 0 and self.skin_vertex.isNone()) return error.NotRecording;
            return;
        }
        if (self.planned_draws == null or self.planned_draws.? != self.draws.items.len) try self.plan();
        const count = self.stats.skinned_vertices;
        if (count != 0) {
            if (self.skin_buffer == null) {
                const bytes = try self.gpa.alignedAlloc(u8, .@"16", @as(usize, self.config.max_skinned_vertices) * 40);
                errdefer self.gpa.free(bytes);
                const buffer = try rhi.FrameVertexBuffer.init(self.device, bytes.len);
                self.skin_bytes = bytes;
                self.skin_buffer = buffer;
            }
            // Separate contiguous streams, packed to this frame's admitted vertex count.
            const positions = std.mem.bytesAsSlice([3]f32, self.skin_bytes[0 .. @as(usize, count) * 12]);
            const normals = std.mem.bytesAsSlice([3]f32, @as([]align(4) u8, @alignCast(self.skin_bytes[@as(usize, count) * 12 .. @as(usize, count) * 24])));
            const tangents = std.mem.bytesAsSlice([4]f32, @as([]align(4) u8, @alignCast(self.skin_bytes[@as(usize, count) * 24 .. @as(usize, count) * 40])));
            @memset(self.skin_bytes[0 .. @as(usize, count) * 40], 0);
            for (self.draws.items) |item| {
                const offset = item.skin_offset orelse continue;
                const mesh = self.meshes.getConst(item.mesh) orelse continue;
                const bind = mesh.skin.?;
                const end = offset + bind.positions.len;
                const write: skinning.Write = .{
                    .input = bind.input(),
                    .matrices = self.palettes.items[item.palette_offset..][0..bind.bounds.len],
                    .output = .{ .positions = positions[offset..end], .normals = if (bind.normals != null) normals[offset..end] else null, .tangents = if (bind.tangents != null) tangents[offset..end] else null },
                };
                self.config.jobs.forChunks(@intCast(bind.positions.len), skinning.grain, &write, skinning.Write.chunk);
            }
            // Failure is consumed, just like the underlying frame helper's update.
            self.skin_frame = frame.index;
            self.skin_vertex = try self.skin_buffer.?.updateIn(cmd, frame, self.skin_bytes[0 .. @as(usize, count) * 40]);
        }
        self.skin_frame = frame.index;
    }

    pub fn prepare(self: *Self, cmd: *rhi.CommandBuffer, frame: rhi.FrameContext) Error!void {
        if (!self.recording) return error.NotRecording;
        if (frame.slot >= self.slots.len) return error.InvalidFrameSlot;
        self.seeFrame(frame.index);
        if (self.planned_draws == null or self.planned_draws.? != self.draws.items.len) try self.plan();
        try self.prepareSkin(cmd, frame);
        try self.ensureTargets(self.view.target_size);
        for (self.order.items) |draw_index| _ = try self.ensurePipeline(self.draws.items[draw_index].pipeline_key);
        if (self.shadow_fit != null) {
            try self.ensureShadowResources();
            for (self.shadow_order.items) |i| _ = try self.ensurePipeline(self.shadowKey(self.draws.items[i]));
        }

        const slot = self.slots[frame.slot];
        const bytes = try self.device.mapBuffer(slot.uniform);
        var uniform = lighting.packFrame(self.view_projection, self.view.camera.position, self.view.exposure_ev100, self.view.ambient, self.lights[0..self.light_count]);
        if (self.shadow_fit) |fit| {
            uniform.counts[1] = 1;
            uniform.shadow_matrix = fit.matrix();
            uniform.shadow_parameters = .{ 1 / @as(f32, @floatFromInt(self.config.shadow_size)), self.config.shadow_normal_offset * fit.texel, 0, 0 };
        }
        @memcpy(bytes[0..@sizeOf(lighting.FrameUniform)], std.mem.asBytes(&uniform));
        self.device.unmapBuffer(slot.uniform);
        self.frame = frame;
    }

    fn worldPassDesc(self: *Self) rhi.RenderPassDesc {
        if (self.config.sample_count == 1) {
            self.pass_color[0] = .{
                .texture = self.hdr_target,
                .load = .{ .clear = .{ .color = self.view.clear_color } },
                .store = .store,
                .initial_state = .undefined,
                .final_state = .shader_read,
            };
        } else {
            self.pass_color[0] = .{
                .texture = self.color_target,
                .load = .{ .clear = .{ .color = self.view.clear_color } },
                .store = .discard,
                .initial_state = .undefined,
                .final_state = .render_target,
                .resolve = .{
                    .texture = self.hdr_target,
                    .initial_state = .undefined,
                    .final_state = .shader_read,
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

    pub fn recordFrame(self: *Self, cmd: *rhi.CommandBuffer, frame: rhi.FrameContext, overlay: bool) Error!void {
        if (!self.recording) return error.NotRecording;
        const prepared = self.frame orelse return error.NotRecording;
        if (prepared.slot != frame.slot or prepared.index != frame.index or !prepared.surface_texture.eql(frame.surface_texture)) return error.InvalidFrameSlot;
        defer {
            self.recording = false;
            self.last_stats = self.stats;
            self.freeDoomed();
        }
        if (self.shadow_fit != null) {
            const shadow_pass = try cmd.beginRenderPass(.{
                .label = "render3d shadow",
                .color = &.{},
                .depth = .{ .texture = self.shadow_target, .load = .{ .clear = .{ .depth_stencil = .{ .depth = 0 } } }, .store = .store, .initial_state = .undefined, .final_state = .shader_read },
            });
            defer shadow_pass.end();
            try self.recordShadow(shadow_pass);
        }
        {
            const pass = try cmd.beginRenderPass(self.worldPassDesc());
            defer pass.end();
            try self.recordWorld(pass);
        }
        const tone = try cmd.beginRenderPass(.{
            .label = "render3d tone map",
            .color = &.{.{ .texture = frame.surface_texture, .load = .discard, .store = .store, .initial_state = .undefined, .final_state = if (overlay) .render_target else .present }},
        });
        defer tone.end();
        tone.setViewport(.{ .width = @floatFromInt(self.view.target_size.width), .height = @floatFromInt(self.view.target_size.height) });
        tone.setScissor(.{ .width = self.view.target_size.width, .height = self.view.target_size.height });
        tone.setPipeline(self.tone_pipeline);
        tone.setBindGroup(0, self.tone_group);
        tone.draw(.{ .vertex_count = 3 });
    }

    fn recordWorld(self: *Self, pass: *rhi.RenderPass) Error!void {
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
                const slot = self.slots[frame.slot];
                pass.setBindGroup(0, if (self.shadow_fit == null and !slot.shadow_group.isNone()) slot.shadow_group else slot.group);
                bound_pipeline = pipeline;
                self.stats.pipeline_binds += 1;
            }
            pass.setBindGroup(2, material.group);

            const constants = drawConstants(item.world);
            pass.setInlineConstants(std.mem.asBytes(&constants));
            self.bindStream(pass, mesh, item, 0);
            if (item.pipeline_key.vertex_layout & 8 != 0) self.bindStream(pass, mesh, item, 1);
            if (item.pipeline_key.vertex_layout & 16 != 0) self.bindStream(pass, mesh, item, 2);
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

    fn shadowKey(self: *const Self, item: DrawItem) PipelineKey {
        const mesh = self.meshes.getConst(item.mesh).?;
        const color = item.alpha == .mask and mesh.stream_mask & (1 << 5) != 0;
        const uv = item.alpha == .mask and mesh.stream_mask & (1 << 3) != 0;
        return .{ .model = item.pipeline_key.model, .vertex_layout = @as(u5, @intFromBool(color)) | (@as(u5, @intFromBool(uv)) << 1) | (@as(u5, @intFromBool(color and mesh.formats[5].? == .float32x4)) << 2), .alpha = item.alpha, .cull = item.pipeline_key.cull, .shadow = true };
    }

    fn ensureShadowResources(self: *Self) Error!void {
        if (!self.shadow_target.isNone()) return;
        // Build a complete candidate before replacing any live group. The caster
        // group samples the fallback, avoiding attachment/sampling feedback even
        // on the strict null backend; the world group samples the real map.
        const target = try self.device.createTexture(.{ .label = "render3d directional shadow", .size = .{ .width = self.config.shadow_size, .height = self.config.shadow_size }, .format = .depth32_float, .usage = .{ .depth_stencil = true, .sampled = true } });
        errdefer self.device.destroyTexture(target);
        const groups = try self.gpa.alloc(rhi.BindGroupHandle, self.slots.len);
        defer self.gpa.free(groups);
        var built: usize = 0;
        errdefer for (groups[0..built]) |group| self.device.destroyBindGroup(group);
        for (self.slots, groups) |slot, *group| {
            group.* = try self.device.createBindGroup(.{ .layout = self.frame_layout, .entries = &.{
                .{ .binding = 0, .resource = .{ .uniform_buffer = .{ .buffer = slot.uniform, .size = @sizeOf(lighting.FrameUniform) } } },
                .{ .binding = 1, .resource = .{ .sampled_texture = target } },
                .{ .binding = 2, .resource = .{ .sampler = self.shadow_sampler } },
            } });
            built += 1;
        }
        var vertex: [4]rhi.ShaderModuleHandle = @splat(.none);
        var fragment: [2]rhi.ShaderModuleHandle = @splat(.none);
        errdefer {
            for (vertex) |shader| if (!shader.isNone()) self.device.destroyShaderModule(shader);
            for (fragment) |shader| if (!shader.isNone()) self.device.destroyShaderModule(shader);
        }
        for (shadowVertexStages(), &vertex) |stage, *shader| shader.* = try self.device.createShaderModule(.{ .bytes = stage.bytes });
        // An opaque caster's shadow pipeline is depth-only: its fragment stage shaded nothing
        // (`fragmentMain` was empty), so it has none, and `fragment[0]` stays `.none`. Only a
        // masked caster, whose alpha test discards, keeps one (`light.md` §14).
        fragment[1] = try self.device.createShaderModule(.{ .bytes = shadowFragmentStages()[1].bytes });
        for (self.slots, groups) |*slot, group| {
            slot.shadow_group = slot.group;
            slot.group = group;
        }
        self.shadow_vertex = vertex;
        self.shadow_fragment = fragment;
        self.shadow_target = target;
    }

    fn recordShadow(self: *Self, pass: *rhi.RenderPass) Error!void {
        const frame = self.frame orelse return error.NotRecording;
        const size = self.config.shadow_size;
        pass.setViewport(.{ .width = @floatFromInt(size), .height = @floatFromInt(size) });
        pass.setScissor(.{ .width = size, .height = size });
        for (self.shadow_order.items) |i| {
            const item = self.draws.items[i];
            const mesh = self.meshes.getConst(item.mesh) orelse continue;
            const material = self.materials.getConst(item.material) orelse continue;
            const key = self.shadowKey(item);
            pass.setPipeline(self.pipelineFor(key).?);
            pass.setBindGroup(0, self.slots[frame.slot].shadow_group);
            pass.setBindGroup(2, material.group);
            const constants = drawConstants(item.world);
            pass.setInlineConstants(std.mem.asBytes(&constants));
            self.bindStream(pass, mesh, item, 0);
            if (key.vertex_layout & 2 != 0) pass.setVertexBuffer(3, mesh.vertex_buffers[3], 0);
            if (key.vertex_layout & 1 != 0) pass.setVertexBuffer(5, mesh.vertex_buffers[5], 0);
            pass.setIndexBuffer(mesh.index_buffer, if (mesh.index_format == .uint16) .uint16 else .uint32, 0);
            const submesh = mesh.submeshes[item.submesh];
            pass.drawIndexed(.{ .index_count = submesh.index_count, .first_index = submesh.first_index });
            self.stats.shadow_draws += 1;
        }
    }

    pub fn frameStats(self: *const Self) Stats {
        return self.last_stats;
    }

    fn bindStream(self: *const Self, pass: *rhi.RenderPass, mesh: *const MeshState, item: DrawItem, slot: u32) void {
        if (item.skin_offset) |offset| {
            const count: u64 = self.stats.skinned_vertices;
            const byte_offset: u64 = switch (slot) {
                0 => @as(u64, offset) * 12,
                1 => (count + offset) * 12,
                2 => count * 24 + @as(u64, offset) * 16,
                else => unreachable,
            };
            pass.setVertexBuffer(slot, self.skin_vertex, byte_offset);
        } else pass.setVertexBuffer(slot, mesh.vertex_buffers[slot], 0);
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
        var variant: usize = 0;
        var variant_bit: u3 = 0;
        inline for (.{ .{ asset.MeshSemantic.color, @as(u5, 1) }, .{ asset.MeshSemantic.uv0, @as(u5, 2) }, .{ asset.MeshSemantic.tangent, @as(u5, 16) } }) |item| {
            if (model.desc.optional.has(item[0])) {
                if (key.vertex_layout & item[1] != 0) variant |= @as(usize, 1) << variant_bit;
                variant_bit += 1;
            }
        }
        if (key.shadow) variant = @as(usize, key.vertex_layout & 3);
        const fragment_variant: usize = @as(usize, @intFromBool(key.alpha == .mask)) + 2 * @as(usize, @intFromBool(key.normal_map));
        var layouts: [5]rhi.pipeline.VertexBufferLayout = undefined;
        var count: usize = 0;
        layouts[count] = .{
            .slot = @intFromEnum(asset.MeshSemantic.position),
            .stride = 12,
            .attributes = &.{.{ .location = 0, .offset = 0, .format = .float32x3 }},
        };
        count += 1;
        if (key.vertex_layout & 8 != 0) {
            layouts[count] = .{ .slot = 1, .stride = 12, .attributes = &.{.{ .location = 1, .offset = 0, .format = .float32x3 }} };
            count += 1;
        }
        if (key.vertex_layout & 16 != 0) {
            layouts[count] = .{ .slot = 2, .stride = 16, .attributes = &.{.{ .location = 2, .offset = 0, .format = .float32x4 }} };
            count += 1;
        }
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
            .vertex_shader = if (key.shadow) self.shadow_vertex[variant] else model.vertex[variant],
            .vertex_entry = if (key.shadow) shadowVertexStages()[variant].entry else model.desc.variants.vertex[variant].entry,
            .fragment_shader = if (key.shadow) self.shadow_fragment[fragment_variant] else model.fragment[fragment_variant],
            .fragment_entry = if (key.shadow) shadowFragmentStages()[fragment_variant].entry else model.desc.variants.fragment[fragment_variant].entry,
            .vertex_buffers = layouts[0..count],
            .color_targets = if (key.shadow) &.{} else &.{.{
                .format = .rgba16_float,
                .blend = if (key.alpha == .blend) rhi.pipeline.BlendState.premultiplied_alpha else null,
            }},
            .depth_stencil = .{
                .format = .depth32_float,
                .depth_write_enabled = key.alpha != .blend,
                .depth_compare = .greater_equal,
                .bias = if (key.shadow) .{ .constant = self.config.shadow_bias_constant, .slope = self.config.shadow_bias_slope, .clamp = self.config.shadow_bias_clamp } else .{},
            },
            .primitive = .{
                .topology = .triangle_list,
                .cull_mode = if (key.cull == .none) .none else .back,
                .front_face = if (key.cull == .back_cw) .clockwise else .counter_clockwise,
            },
            .sample_count = if (key.shadow) 1 else self.config.sample_count,
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
        if (state.skin) |bind| bind.deinit(self.gpa);
        for (state.vertex_buffers) |buffer| if (!buffer.isNone()) self.device.destroyBuffer(buffer);
        if (!state.index_buffer.isNone()) self.device.destroyBuffer(state.index_buffer);
        self.gpa.free(state.submeshes);
        self.gpa.free(state.submesh_bounds);
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
                .format = .rgba16_float,
                .usage = .{ .render_target = true },
                .sample_count = self.config.sample_count,
            });
        errdefer if (!color.isNone()) self.device.destroyTexture(color);

        const hdr = try self.device.createTexture(.{
            .label = "render3d HDR",
            .size = .{ .width = size.width, .height = size.height },
            .format = .rgba16_float,
            .usage = .{ .render_target = true, .sampled = true },
        });
        errdefer self.device.destroyTexture(hdr);
        const tone_group = try self.device.createBindGroup(.{
            .label = "render3d tone map",
            .layout = self.tone_layout,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .sampled_texture = hdr } },
                .{ .binding = 1, .resource = .{ .sampler = self.tone_sampler } },
            },
        });

        if (!self.color_target.isNone()) self.device.destroyTexture(self.color_target);
        if (!self.depth_target.isNone()) self.device.destroyTexture(self.depth_target);
        if (!self.tone_group.isNone()) self.device.destroyBindGroup(self.tone_group);
        if (!self.hdr_target.isNone()) self.device.destroyTexture(self.hdr_target);
        self.hdr_target = hdr;
        self.tone_group = tone_group;
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
        return initConfig(.{ .frames_in_flight = 2, .sample_count = samples }, size);
    }

    fn initConfig(config: Config, size: u32) !TestFixture {
        const device = try rhi.Device.init(testing.allocator, .{
            .surface_size = .{ .width = size, .height = size },
            .frames_in_flight = 2,
        });
        errdefer device.deinit();
        var renderer = try Renderer.init(testing.allocator, device, config);
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
    try fx.renderer.recordFrame(cmd, frame, false);
    try cmd.submit();
    try fx.device.endFrame();
}

const strip_palette = [2]Mat4{ .identity, .{ .cols = .{ .{ 0.8, 0.6, 0, 0 }, .{ -0.6, 0.8, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0.5, 0, 0, 1 } } } };

/// Six vertices with a blended middle row. The rigid reference is computed independently
/// from the two-joint weighted transform, not by calling the skinning kernel under test.
fn testStrip(renderer: *Renderer, reference: bool) !MeshHandle {
    var positions = [_][3]f32{ .{ -0.6, -1, -3 }, .{ 0.6, -1, -3 }, .{ -0.6, 0, -3 }, .{ 0.6, 0, -3 }, .{ -0.6, 1, -3 }, .{ 0.6, 1, -3 } };
    var normals = [_][3]f32{.{ 0, 0.6, 0.8 }} ** 6;
    var tangents = [_][4]f32{.{ 1, 0, 0, -1 }} ** 6;
    const joints = [_][4]u8{.{ 0, 1, 0, 0 }} ** 6;
    const weights = [_][4]f32{ .{ 1, 0, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 0.5, 0.5, 0, 0 }, .{ 0.5, 0.5, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 1, 0, 0 } };
    if (reference) for (&positions, &normals, &tangents, weights) |*p, *n, *t, w| {
        const a = 1 - 0.2 * w[1];
        const b = 0.6 * w[1];
        const x = p[0];
        const y = p[1];
        p.* = .{ a * x - b * y + 0.5 * w[1], b * x + a * y, p[2] };
        const direction = Vec3.init(-b * 0.6, a * 0.6, 0.8).normalize();
        n.* = .{ direction.x, direction.y, direction.z };
        const tangent = Vec3.init(a, b, 0).normalize();
        t.* = .{ tangent.x, tangent.y, tangent.z, -1 };
    };
    const indices = [_]u16{ 0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4 };
    const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = indices.len }};
    const boxes = [_]asset.MeshAabb{
        .{ .min = .init(-0.6, -1, -3), .max = .init(0.6, 0, -3) },
        .{ .min = .init(-0.6, 0, -3), .max = .init(0.6, 1, -3) },
    };
    var streams = [_]asset.MeshStream{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) },
        .{ .semantic = .normal, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&normals) },
        .{ .semantic = .tangent, .format = .float32x4, .bytes = std.mem.sliceAsBytes(&tangents) },
        .{ .semantic = .joints, .format = .uint8x4, .bytes = std.mem.sliceAsBytes(&joints) },
        .{ .semantic = .weights, .format = .float32x4, .bytes = std.mem.sliceAsBytes(&weights) },
    };
    const position_vectors: []const Vec3 = @ptrCast(&positions);
    return renderer.createMesh(.{ .vertex_count = positions.len, .streams = streams[0..if (reference) 3 else 5], .index_format = .uint16, .indices = std.mem.sliceAsBytes(&indices), .submeshes = &submeshes, .bounds = try asset.Mesh.computeBounds(position_vectors), .joint_bounds = if (reference) &.{} else &boxes }, "bent strip");
}

test "M24 camera and shadow survivors share one budgeted skin evaluation in submission order" {
    for ([_]u32{ 0, 6, 12 }) |budget| {
        var fx = try TestFixture.initConfig(.{ .sample_count = 1, .shadow_size = 1024, .max_skinned_vertices = budget }, 32);
        defer fx.deinit();
        const mesh = try testStrip(&fx.renderer, false);
        try fx.renderer.begin(testView(32));
        try fx.renderer.addLight(.{ .kind = .directional, .intensity = 1, .world = .identity, .casts_shadow = true });
        // Shadow-only survivor first; camera-only optimization must not lose it.
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(0, 0, 100)), .skin = &strip_palette });
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity, .skin = &strip_palette });
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(1000, 0, 0)), .skin = &strip_palette });
        try finishTestFrame(&fx);
        const stats = fx.renderer.frameStats();
        try testing.expectEqual(budget / 6, stats.skinned_draws);
        try testing.expectEqual(budget, stats.skinned_vertices);
        try testing.expectEqual(2 - budget / 6, stats.skin_budget_dropped);
        try testing.expectEqual(budget / 6, stats.shadow_draws);
        try testing.expectEqual(@as(u32, @intFromBool(budget == 12)), stats.draws);
        if (budget != 0) {
            const input = fx.renderer.meshes.getConst(mesh).?.skin.?;
            var expected: [6][3]f32 = undefined;
            var expected_n: [6][3]f32 = undefined;
            var expected_t: [6][4]f32 = undefined;
            @import("anim").skin(input.input(), &strip_palette, 0, 6, .{ .positions = &expected, .normals = &expected_n, .tangents = &expected_t });
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), fx.renderer.skin_bytes[0..72]);
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected_n), fx.renderer.skin_bytes[@as(usize, budget) * 12 ..][0..72]);
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected_t), fx.renderer.skin_bytes[@as(usize, budget) * 24 ..][0..96]);
        } else try testing.expect(fx.renderer.skin_buffer == null);
        if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
    }
}

test "M24 posed culling keeps a skin moved inside and culls one moved outside" {
    var fx = try TestFixture.initConfig(.{ .sample_count = 1, .shadow_size = 0, .max_skinned_vertices = 12 }, 32);
    defer fx.deinit();
    const mesh = try testStrip(&fx.renderer, false);
    try fx.renderer.begin(testView(32));
    const to_left = [_]Mat4{Mat4.translation(.init(-10, 0, 0))} ** 2;
    const to_right = [_]Mat4{Mat4.translation(.init(10, 0, 0))} ** 2;
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(10, 0, 0)), .skin = &to_left });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity, .skin = &to_right });
    try fx.renderer.plan();
    try testing.expectEqualSlices(u32, &.{0}, fx.renderer.order.items);
    // Same bound centre is used for transparent sorting, not the original bind box.
    try testing.expectApproxEqAbs(@as(f32, 0), fx.renderer.draws.items[0].bounds.center.x, 0.02);
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u32, 6), fx.renderer.frameStats().skinned_vertices);
}

test "M24 posed bounds cover tolerance endpoints under translated reflected placement" {
    const box = asset.MeshAabb{ .min = .init(10000, 0, -3), .max = .init(10000, 0, -3) };
    const world = Mat4.mul(Mat4.translation(.init(-10000, 0, 0)), Mat4.scaling(.init(-1, 2, 1)));
    const bound = skinning.posedBounds(&.{box}, &.{.identity}, world);
    for ([_]f32{ 0.999, 1.001 }) |sum| {
        const p = world.mulPoint(box.min.scale(sum));
        try testing.expect(@abs(p.x - bound.center.x) <= bound.extent.x);
        try testing.expect(@abs(p.z - bound.center.z) <= bound.extent.z);
    }
}

test "M24 transparent skins sort by posed centres and prepared palettes cannot be changed" {
    var fx = try TestFixture.initConfig(.{ .sample_count = 1, .shadow_size = 0, .max_skinned_vertices = 12 }, 32);
    defer fx.deinit();
    const mesh = try testStrip(&fx.renderer, false);
    const material = try fx.renderer.createMaterial(.{ .alpha_mode = .blend, .casts_shadow = false }, "skin blend");
    try fx.renderer.begin(testView(32));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity, .skin = &strip_palette });
    const farther = [_]Mat4{Mat4.translation(.init(0, 0, -3))} ** 2;
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity, .skin = &farther });
    try fx.renderer.plan();
    try testing.expectEqualSlices(u32, &.{ 1, 0 }, fx.renderer.order.items);
    const frame = try fx.device.beginFrame();
    const cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepareSkin(cmd, frame);
    try fx.renderer.prepareSkin(cmd, frame);
    try testing.expectError(error.NotRecording, fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity, .skin = &strip_palette }));
    try testing.expectError(error.NotRecording, fx.renderer.addLight(.{ .kind = .directional, .intensity = 1, .world = .identity }));
    try fx.renderer.prepare(cmd, frame);
    try fx.renderer.recordFrame(cmd, frame, false);
    try cmd.submit();
    try fx.device.endFrame();
    try testing.expectEqual(@as(u32, 2), fx.renderer.frameStats().blended);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

fn skinAllocationProof(gpa: Allocator) !void {
    const device = try rhi.Device.init(gpa, .{ .surface_size = .{ .width = 8, .height = 8 } });
    defer device.deinit();
    var renderer = try Renderer.init(gpa, device, .{ .sample_count = 1, .shadow_size = 0, .max_skinned_vertices = 6 });
    defer renderer.deinit();
    const material = try renderer.createMaterial(.{}, "skin OOM");
    const mesh = try testStrip(&renderer, false);
    try renderer.begin(testView(8));
    try renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity, .skin = &strip_palette });
    const frame = try device.beginFrame();
    var ended = false;
    defer if (!ended) device.endFrame() catch {}; // Preserve the allocation refusal.
    const cmd = try device.beginCommandBuffer();
    var consumed = false;
    defer if (!consumed) cmd.discard();
    try renderer.prepare(cmd, frame);
    try renderer.recordFrame(cmd, frame, false);
    consumed = true;
    try cmd.submit();
    ended = true;
    try device.endFrame();
}

test "M24 skin residency palette and frame storage clean up every allocation refusal" {
    if (rhi.backend != .null) return;
    try testing.checkAllAllocationFailures(testing.allocator, skinAllocationProof, .{});
}

test "M24 a failed vertex submission cannot be retried as a prepared skin" {
    if (rhi.backend != .null) return;
    var fx = try TestFixture.initConfig(.{ .sample_count = 1, .shadow_size = 0, .max_skinned_vertices = 6 }, 8);
    defer fx.deinit();
    const mesh = try testStrip(&fx.renderer, false);
    try fx.renderer.begin(testView(8));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity, .skin = &strip_palette });
    const frame = try fx.device.beginFrame();
    const cmd = try fx.device.beginCommandBuffer();
    // The copy is recorded into the frame's own command buffer (M26 Step 12), so a submission
    // that fails is that frame's, and the skin it carried is not prepared a second time.
    try fx.renderer.prepareSkin(cmd, frame);
    try fx.renderer.prepareSkin(cmd, frame);
    try testing.expectError(error.AlreadyUpdated, fx.renderer.skin_buffer.?.updateIn(cmd, frame, fx.renderer.skin_bytes[0..40]));
    fx.device.faults.submit = error.DeviceLost;
    try testing.expectError(error.DeviceLost, cmd.submit());
    fx.device.faults.submit = null;
    try fx.device.endFrame();
    try fx.renderer.begin(testView(8));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity, .skin = &strip_palette });
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

fn stripReadback(fx: *TestFixture, mesh: MeshHandle, reference: bool, shadow: bool, shifted: bool) ![material_test_bytes]u8 {
    const material = try fx.renderer.createMaterial(.{ .shading = lit_id, .base_color = .{ 0.6, 0.3, 0.1, 1 }, .roughness = 0.7, .double_sided = true }, "strip lit");
    defer fx.renderer.destroyMaterial(material);
    const readback = try fx.device.createBuffer(.{ .size = material_test_bytes, .usage = .{ .copy_dst = true }, .memory = .readback });
    defer fx.device.destroyBuffer(readback);
    var view = testView(material_test_size);
    view.ambient = .{ 0.2, 0.3, 0.4 };
    view.shadow_distance = 6;
    try fx.renderer.begin(view);
    const light: Light = .{ .kind = .directional, .intensity = 2, .casts_shadow = shadow, .world = Mat4.fromQuat(core.math.Quat.lookRotation(.init(-1, 0, -1), .up).?) };
    try fx.renderer.addLight(light);
    if (shadow) {
        const receiver = try litQuad(&fx.renderer, 0);
        defer fx.renderer.destroyMesh(receiver);
        // Keep it alive through command recording below, so retirement is exercised too.
        try fx.renderer.drawMesh(.{ .mesh = receiver, .material = material, .world = Mat4.mul(Mat4.translation(.init(0, 0, -2)), Mat4.scaling(.init(3, 3, 1))) });
        // Cannot destroy a submitted-but-not-yet-recorded handle.
        try stripFrame(fx, mesh, material, reference, shadow, shifted, readback);
    } else try stripFrame(fx, mesh, material, reference, shadow, shifted, readback);
    fx.device.waitIdle();
    var pixels: [material_test_bytes]u8 = undefined;
    const mapped = try fx.device.mapBuffer(readback);
    @memcpy(&pixels, mapped[0..pixels.len]);
    fx.device.unmapBuffer(readback);
    return pixels;
}

fn stripFrame(fx: *TestFixture, mesh: MeshHandle, material: MaterialHandle, reference: bool, shadow: bool, shifted: bool, readback: rhi.BufferHandle) !void {
    var palette = strip_palette;
    if (shifted) for (&palette) |*matrix| {
        matrix.* = Mat4.mul(Mat4.translation(.init(5, 0, 0)), matrix.*);
    };
    const world = if (shadow) Mat4.translation(.init(3, 0, 2)) else Mat4.identity;
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = if (reference and shifted) Mat4.mul(world, Mat4.translation(.init(5, 0, 0))) else world, .skin = if (reference) null else &palette });
    const frame = try fx.device.beginFrame();
    const cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, frame);
    try fx.renderer.recordFrame(cmd, frame, false);
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
    try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = material_test_size, .height = material_test_size }, .dst = readback });
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
    try cmd.submit();
    try fx.device.endFrame();
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

test "M24 bent strip pixels match the independent CPU reference lit and in shadow at 1x and 4x" {
    for ([_]u32{ 1, 4 }) |samples| {
        var fx = try TestFixture.initConfig(.{ .sample_count = samples, .shadow_size = 1024, .max_skinned_vertices = 6 }, material_test_size);
        defer fx.deinit();
        const mesh = try testStrip(&fx.renderer, false);
        const reference = try testStrip(&fx.renderer, true);
        for ([_]bool{ false, true }) |shadow| {
            const expected = try stripReadback(&fx, reference, true, shadow, false);
            const actual = try stripReadback(&fx, mesh, false, shadow, false);
            const moved = try stripReadback(&fx, mesh, false, shadow, true);
            if (rhi.backend != .null) {
                for (0..material_test_size) |y| for (0..material_test_size) |x| {
                    const e = materialTexel(&expected, x, y);
                    const a = materialTexel(&actual, x, y);
                    try expectDisplayTexel(e, a);
                };
                // Positive witnesses: a lit strip covers pixels, and its posed shadow
                // changes receiver pixels. A blank render cannot satisfy this proof.
                try testing.expect(!std.mem.eql(u8, &actual, &moved));
            }
            // More than two frames across both passes reuses the waited ring slots.
            const again = try stripReadback(&fx, mesh, false, shadow, false);
            try testing.expectEqualSlices(u8, &actual, &again);
        }
    }
}

test "M24 distinct skin instances bind their own position normal and tangent prefixes" {
    var fx = try TestFixture.initConfig(.{ .sample_count = 1, .shadow_size = 0, .max_skinned_vertices = 12 }, material_test_size);
    defer fx.deinit();
    const mesh = try testStrip(&fx.renderer, false);
    const reference = try testStrip(&fx.renderer, true);
    const material = try fx.renderer.createMaterial(.{ .shading = lit_id, .double_sided = true }, "skin instances");
    const readback = try fx.device.createBuffer(.{ .size = material_test_bytes, .usage = .{ .copy_dst = true }, .memory = .readback });
    defer fx.device.destroyBuffer(readback);
    var images: [2][material_test_bytes]u8 = undefined;
    for ([_]bool{ true, false }, &images) |rigid, *image| {
        var view = testView(material_test_size);
        view.ambient = .{ 0.4, 0.3, 0.2 };
        try fx.renderer.begin(view);
        try fx.renderer.addLight(.{ .kind = .directional, .intensity = 2, .world = .identity });
        for ([_]f32{ -1.1, 1.1 }) |x| {
            var palette = strip_palette;
            for (&palette) |*matrix| matrix.* = Mat4.mul(Mat4.translation(.init(x, 0, 0)), matrix.*);
            try fx.renderer.drawMesh(.{ .mesh = if (rigid) reference else mesh, .material = material, .world = if (rigid) Mat4.translation(.init(x, 0, 0)) else .identity, .skin = if (rigid) null else &palette });
        }
        const frame = try fx.device.beginFrame();
        const cmd = try fx.device.beginCommandBuffer();
        try fx.renderer.prepare(cmd, frame);
        try fx.renderer.recordFrame(cmd, frame, false);
        try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
        try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = material_test_size, .height = material_test_size }, .dst = readback });
        try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
        try cmd.submit();
        try fx.device.endFrame();
        fx.device.waitIdle();
        const bytes = try fx.device.mapBuffer(readback);
        @memcpy(image, bytes[0..image.len]);
        fx.device.unmapBuffer(readback);
    }
    if (rhi.backend != .null) for (0..material_test_size) |y| for (0..material_test_size) |x| {
        try expectDisplayTexel(materialTexel(&images[0], x, y), materialTexel(&images[1], x, y));
    };
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

test "renderer configuration is bounded, and the tone map targets the surface's format" {
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

test "M24 skin residency owns bind data and refuses missing wrong unexpected or invalid palettes" {
    var fx = try TestFixture.init(1, 8);
    defer fx.deinit();
    const positions = [_]Vec3{ .init(-1, -1, -2), .init(1, -1, -2), .init(0, 1, -2) };
    const joints = [_][4]u8{.{ 0, 255, 255, 255 }} ** 3;
    const weights = [_][4]f32{.{ 1, 0, 0, 0 }} ** 3;
    const indices = [_]u16{ 0, 1, 2 };
    const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = 3 }};
    const bounds = try asset.Mesh.computeBounds(&positions);
    const mesh = try fx.renderer.createMesh(.{
        .vertex_count = 3,
        .streams = &.{
            .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) },
            .{ .semantic = .joints, .format = .uint8x4, .bytes = std.mem.sliceAsBytes(&joints) },
            .{ .semantic = .weights, .format = .float32x4, .bytes = std.mem.sliceAsBytes(&weights) },
        },
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&indices),
        .submeshes = &submeshes,
        .bounds = bounds,
        .joint_bounds = &.{bounds},
    }, "resident skin");
    try fx.renderer.begin(testView(8));
    const base: MeshDraw = .{ .mesh = mesh, .material = fx.material, .world = .identity };
    try testing.expectError(error.MissingSkin, fx.renderer.drawMesh(base));
    var draw = base;
    draw.skin = &.{};
    try testing.expectError(error.InvalidSkinCount, fx.renderer.drawMesh(draw));
    var invalid = Mat4.identity;
    invalid.cols[0][3] = 1;
    draw.skin = &.{invalid};
    try testing.expectError(error.InvalidSkinMatrix, fx.renderer.drawMesh(draw));
    invalid = .identity;
    invalid.cols[0][0] = std.math.nan(f32);
    draw.skin = &.{invalid};
    try testing.expectError(error.InvalidSkinMatrix, fx.renderer.drawMesh(draw));
    const rigid = try testMesh(&fx.renderer, false);
    draw.mesh = rigid;
    draw.skin = &.{.identity};
    try testing.expectError(error.UnexpectedSkin, fx.renderer.drawMesh(draw));
    try testing.expectEqual(@as(usize, 0), fx.renderer.draws.items.len);
    draw.mesh = mesh;
    const submitted = Mat4.translation(.init(0.5, 0, 0));
    var palette = [_]Mat4{submitted};
    draw.skin = &palette;
    try fx.renderer.drawMesh(draw);
    palette[0] = Mat4.translation(.init(100, 0, 0));
    try testing.expectEqual(submitted, fx.renderer.palettes.items[0]);
    const bind = fx.renderer.meshes.getConst(mesh).?.skin.?;
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&positions), std.mem.sliceAsBytes(bind.positions));
    try testing.expect(@intFromPtr(bind.positions.ptr) != @intFromPtr(&positions));
    for (fx.renderer.meshes.getConst(mesh).?.vertex_buffers) |buffer| try testing.expect(buffer.isNone());
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u32, 3), fx.renderer.frameStats().skinned_vertices);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

test "resident mesh records a depth pass and reports the completed work" {
    var fx = try TestFixture.init(1, 64);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, true);

    try fx.renderer.begin(testView(64));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });
    try finishTestFrame(&fx);

    // The first frame also carries every upload before it: the renderer's three 1×1
    // defaults and the mesh's position, colour and index bytes (`runtime-geometry.md` §4.3).
    try testing.expectEqual(Stats{ .draws = 1, .triangles = 1, .pipeline_binds = 1, .uploaded_bytes = 3 * 4 + 36 + 12 + 6 }, fx.renderer.frameStats());
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
    try testing.expectEqual(@as(usize, 2), fx.renderer.models.items.len);
    try testing.expectError(error.DuplicateShadingModel, fx.renderer.registerShadingModel(unlitModel()));

    var malformed = unlitModel();
    malformed.id = core.ContentId.fromString("test:shading.malformed");
    malformed.requires = .{};
    try testing.expectError(error.InvalidShadingModel, fx.renderer.registerShadingModel(malformed));
    try testing.expectEqual(@as(usize, 2), fx.renderer.models.items.len);
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
        .base_color_texture = TextureHandle.fromBits(0x0000_0001_ffff_ffff),
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
    uv_model.variants.vertex = uv_model.variants.vertex[0..2];
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
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -200, 200 }) |ev| {
        view = testView(64);
        view.exposure_ev100 = ev;
        try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
    }
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -1 }) |bad| {
        view = testView(64);
        view.ambient[1] = bad;
        try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
        view = testView(64);
        view.shadow_distance = bad;
        try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
    }
    view = testView(64);
    view.shadow_distance = 0;
    try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
    view = testView(64);
    view.clear_color[0] = -1;
    try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
    view.clear_color[0] = 65505;
    try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
    view = testView(64);
    view.clear_color[3] = 2;
    try testing.expectError(error.InvalidCamera, fx.renderer.begin(view));
}

test "light refusals leave the submitted frame unchanged" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const good: Light = .{ .kind = .directional, .intensity = 400, .world = .identity };
    try testing.expectError(error.NotRecording, fx.renderer.addLight(good));
    try fx.renderer.begin(testView(32));
    try fx.renderer.addLight(good);
    const saved = fx.renderer.lights[0];
    const saved_stats = fx.renderer.stats;
    var cases = [_]Light{good} ** 17;
    cases[0].color[0] = -1;
    cases[1].color[1] = 2;
    cases[2].color[2] = std.math.nan(f32);
    cases[3].intensity = -1;
    cases[4].intensity = std.math.inf(f32);
    cases[5].range = -1;
    cases[6].range = std.math.nan(f32);
    cases[7].inner_cone = -1;
    cases[8].inner_cone = cases[8].outer_cone;
    cases[9].inner_cone = std.math.nan(f32);
    cases[10].outer_cone = std.math.pi;
    cases[11].outer_cone = std.math.inf(f32);
    cases[12].world.cols[2] = .{ 0, 0, 0, 0 };
    cases[13].world.cols[3][0] = std.math.inf(f32);
    cases[14].world.cols[0][1] = std.math.nan(f32);
    cases[15].outer_cone = 0;
    cases[16].inner_cone = cases[16].outer_cone + 0.1;
    for (cases) |bad| {
        try testing.expectError(error.InvalidLight, fx.renderer.addLight(bad));
        try testing.expectEqual(@as(u32, 1), fx.renderer.light_count);
        try testing.expectEqualDeep(saved, fx.renderer.lights[0]);
        try testing.expectEqual(saved_stats, fx.renderer.stats);
        try testing.expect(!fx.renderer.has_shadow_caster);
        try testing.expectEqual(@as(usize, 0), fx.renderer.draws.items.len);
        try testing.expect(fx.renderer.planned_draws == null);
    }
    var shadow = good;
    shadow.casts_shadow = true;
    shadow.kind = .point;
    try testing.expectError(error.InvalidShadowCaster, fx.renderer.addLight(shadow));
    shadow.kind = .spot;
    try testing.expectError(error.InvalidShadowCaster, fx.renderer.addLight(shadow));
    try testing.expectEqual(@as(u32, 1), fx.renderer.light_count);
    shadow.kind = .directional;
    try fx.renderer.addLight(shadow);
    try testing.expectError(error.InvalidShadowCaster, fx.renderer.addLight(shadow));
    try testing.expectEqual(@as(u32, 2), fx.renderer.light_count);
    for (2..max_lights) |i| {
        var light = good;
        light.intensity = @floatFromInt(i);
        try fx.renderer.addLight(light);
    }
    try testing.expectError(error.TooManyLights, fx.renderer.addLight(good));
    try testing.expectEqual(@as(u32, max_lights), fx.renderer.light_count);
    for (2..max_lights) |i| try testing.expectEqual(@as(f32, @floatFromInt(i)), fx.renderer.lights[i].intensity);
    try fx.renderer.plan();
    try testing.expectError(error.NotRecording, fx.renderer.addLight(good));
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u32, max_lights), fx.renderer.frameStats().lights);
    try testing.expectError(error.NotRecording, fx.renderer.addLight(good));
    try fx.renderer.begin(testView(32));
    try testing.expectEqual(@as(u32, 0), fx.renderer.light_count);
    try testing.expect(!fx.renderer.has_shadow_caster);
}

test "light direction packing survives finite extreme scales" {
    for ([_]f32{ 1e30, 1e-30 }) |scale| {
        const light: Light = .{ .kind = .directional, .intensity = 1, .world = Mat4.scaling(.init(scale, scale, scale)) };
        try testing.expect(lighting.valid(light));
        try testing.expectEqual(Vec3.forward, lighting.direction(light.world));
    }
}

test "frame preparation uploads the pinned lighting uniform" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    var view = testView(32);
    view.ambient = .{ 3, 4, 5 };
    view.exposure_ev100 = 15;
    try fx.renderer.begin(view);
    try fx.renderer.addLight(.{ .kind = .point, .intensity = 70, .world = Mat4.translation(.init(1, 2, 3)) });
    const frame = try fx.device.beginFrame();
    const cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, frame);
    const mapped = try fx.device.mapBuffer(fx.renderer.slots[frame.slot].uniform);
    const expected = lighting.packFrame(fx.renderer.view_projection, view.camera.position, 15, view.ambient, fx.renderer.lights[0..1]);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&expected), mapped[0..@sizeOf(lighting.FrameUniform)]);
    fx.device.unmapBuffer(fx.renderer.slots[frame.slot].uniform);
    var wrong = frame;
    wrong.slot += 1;
    try testing.expectError(error.InvalidFrameSlot, fx.renderer.recordFrame(cmd, wrong, true));
    wrong = frame;
    wrong.index += 1;
    try testing.expectError(error.InvalidFrameSlot, fx.renderer.recordFrame(cmd, wrong, true));
    wrong = frame;
    wrong.surface_texture = .none;
    try testing.expectError(error.InvalidFrameSlot, fx.renderer.recordFrame(cmd, wrong, true));
    try fx.renderer.recordFrame(cmd, frame, true);
    // Loading the surface and sampling HDR proves the two final states on null.
    const overlay = try cmd.beginRenderPass(.{ .color = &.{.{ .texture = frame.surface_texture, .load = .load, .initial_state = .render_target, .final_state = .present }} });
    overlay.end();
    try cmd.submit();
    try fx.device.endFrame();
}

test "targets follow sample count and rebuild on resize" {
    var single = try TestFixture.init(1, 64);
    defer single.deinit();
    try single.renderer.begin(testView(64));
    const single_frame = try single.device.beginFrame();
    var single_cmd = try single.device.beginCommandBuffer();
    try single.renderer.prepare(single_cmd, single_frame);
    try testing.expect(single.renderer.color_target.isNone());
    try testing.expect(!single.renderer.hdr_target.isNone());
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
    const old_hdr = multi.renderer.hdr_target;
    const old_group = multi.renderer.tone_group;
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
    try testing.expect(!multi.renderer.hdr_target.eql(old_hdr));
    try testing.expect(!multi.renderer.tone_group.eql(old_group));
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

/// Four vertices on a plane, optional semantic subsets in the registry's bit order.
fn litQuad(renderer: *Renderer, optional: u3) !MeshHandle {
    return litQuadAlpha(renderer, optional, 1);
}

fn litQuadAlpha(renderer: *Renderer, optional: u3, alpha: f32) !MeshHandle {
    const positions = [_]Vec3{ .init(-1, -1, -2), .init(1, -1, -2), .init(1, 1, -2), .init(-1, 1, -2) };
    const normals = [_]Vec3{.init(0, 0, 1)} ** 4;
    const tangents = [_][4]f32{.{ 1, 0, 0, 1 }} ** 4;
    const uvs = [_][2]f32{.{ 0.5, 0.5 }} ** 4;
    const colors = [_][4]f32{.{ 1, 1, 1, alpha }} ** 4;
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    var streams: [5]asset.MeshStream = undefined;
    streams[0] = .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) };
    streams[1] = .{ .semantic = .normal, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&normals) };
    var count: usize = 2;
    if (optional & 1 != 0) {
        streams[count] = .{ .semantic = .color, .format = .float32x4, .bytes = std.mem.sliceAsBytes(&colors) };
        count += 1;
    }
    if (optional & 2 != 0) {
        streams[count] = .{ .semantic = .uv0, .format = .float32x2, .bytes = std.mem.sliceAsBytes(&uvs) };
        count += 1;
    }
    if (optional & 4 != 0) {
        streams[count] = .{ .semantic = .tangent, .format = .float32x4, .bytes = std.mem.sliceAsBytes(&tangents) };
        count += 1;
    }
    return renderer.createMesh(.{
        .vertex_count = 4,
        .streams = streams[0..count],
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&indices),
        .submeshes = &.{.{ .first_index = 0, .index_count = 6 }},
        .bounds = try asset.Mesh.computeBounds(&positions),
    }, "lit reference plane");
}

test "lit registration bounds variant slices before creating shaders" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    var model = litModel();
    model.id = core.ContentId.fromString("test:shading.variant_guard");
    model.variants.vertex = model.variants.vertex[0..7];
    try testing.expectError(error.InvalidShadingModel, fx.renderer.registerShadingModel(model));
    model = litModel();
    model.id = core.ContentId.fromString("test:shading.variant_guard");
    model.variants.fragment = model.variants.fragment[0..3];
    try testing.expectError(error.InvalidShadingModel, fx.renderer.registerShadingModel(model));
    model = litModel();
    model.id = core.ContentId.fromString("test:shading.variant_guard");
    model.requires = StreamSet.of(&.{.position});
    try testing.expectError(error.InvalidShadingModel, fx.renderer.registerShadingModel(model));
    try testing.expectEqual(@as(usize, 2), fx.renderer.models.items.len);
    try testing.expectEqual(@as(usize, 64), @sizeOf(MaterialUniform));
    try testing.expectEqual(@as(usize, 32), @offsetOf(MaterialUniform, "surface"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(MaterialUniform, "emissive_strength"));
}

test "lit values and all texture colour spaces are checked while unlit ignores unread fields" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    inline for (.{ "metallic", "roughness", "occlusion_strength", "emissive_strength", "normal_scale" }) |field| {
        var desc: MaterialDesc = .{ .shading = lit_id };
        @field(desc, field) = std.math.nan(f32);
        try testing.expectError(error.InvalidMaterialValue, fx.renderer.createMaterial(desc, "not finite"));
    }
    inline for (.{ "metallic", "roughness", "occlusion_strength" }) |field| {
        for ([_]f32{ -0.1, 1.1 }) |value| {
            var desc: MaterialDesc = .{ .shading = lit_id };
            @field(desc, field) = value;
            try testing.expectError(error.InvalidMaterialValue, fx.renderer.createMaterial(desc, "not unit"));
        }
    }
    try testing.expectError(error.InvalidMaterialValue, fx.renderer.createMaterial(.{ .shading = lit_id, .emissive_strength = -1 }, "negative emission"));
    try testing.expectError(error.InvalidMaterialValue, fx.renderer.createMaterial(.{ .shading = lit_id, .emissive = .{ 0, 1.01, 0 } }, "emission factor"));
    inline for (.{ "base_color_texture", "metallic_roughness_texture", "normal_texture", "occlusion_texture", "emissive_texture" }, 0..) |field, i| {
        var desc: MaterialDesc = .{ .shading = lit_id };
        @field(desc, field) = if (i == 0 or i == 4) fx.renderer.linear_white else fx.renderer.white_texture;
        try testing.expectError(error.WrongColorSpace, fx.renderer.createMaterial(desc, "wrong colour space"));
        @field(desc, field) = TextureHandle.fromBits(0x0000_0001_ffff_ffff);
        try testing.expectError(error.InvalidTexture, fx.renderer.createMaterial(desc, "stale slot"));
    }
    const ignored = try fx.renderer.createMaterial(.{ .metallic = std.math.nan(f32), .normal_texture = TextureHandle.fromBits(0x0000_0001_ffff_ffff) }, "unread");
    defer fx.renderer.destroyMaterial(ignored);
    const valid = try fx.renderer.createMaterial(.{ .shading = lit_id, .roughness = 0, .normal_scale = -1, .emissive_strength = 100000 }, "finite extended ranges");
    defer fx.renderer.destroyMaterial(valid);
}

test "lit draws require normals and mapped draws require tangents; every variant records" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const no_normal = try testMesh(&fx.renderer, false);
    const material = try fx.renderer.createMaterial(.{ .shading = lit_id }, "lit");
    const mapped = try fx.renderer.createMaterial(.{ .shading = lit_id, .normal_texture = fx.renderer.flat_normal }, "mapped");
    defer fx.renderer.destroyMaterial(material);
    defer fx.renderer.destroyMaterial(mapped);
    try fx.renderer.begin(testView(32));
    try testing.expectError(error.MissingStream, fx.renderer.drawMesh(.{ .mesh = no_normal, .material = material, .world = .identity }));
    for (0..8) |i| {
        const mesh = try litQuad(&fx.renderer, @intCast(i));
        if (i & 4 == 0) try testing.expectError(error.MissingStream, fx.renderer.drawMesh(.{ .mesh = mesh, .material = mapped, .world = .identity }));
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity });
        if (i & 4 != 0) try fx.renderer.drawMesh(.{ .mesh = mesh, .material = mapped, .world = .identity });
    }
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(usize, 12), fx.renderer.pipelines.items.len);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

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

test "shadow configuration accepts only bounded map sizes and finite biases" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    for ([_]u32{ 1, 512, 2049, 8192 }) |size| {
        try testing.expectError(error.InvalidConfig, Renderer.init(testing.allocator, fx.device, .{ .shadow_size = size }));
    }
    inline for (.{ "shadow_bias_constant", "shadow_bias_slope", "shadow_bias_clamp", "shadow_normal_offset" }) |field| {
        var config: Config = .{};
        @field(config, field) = std.math.nan(f32);
        try testing.expectError(error.InvalidConfig, Renderer.init(testing.allocator, fx.device, config));
    }
    for ([_]u32{ 0, 1024, 2048, 4096 }) |size| {
        var renderer = try Renderer.init(testing.allocator, fx.device, .{ .shadow_size = size });
        renderer.deinit();
    }
}

test "anisotropy is configured 1 to 16 and asked for only by linear mipmapped textures" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    for ([_]u8{ 0, 17 }) |n| {
        try testing.expectError(error.InvalidConfig, Renderer.init(testing.allocator, fx.device, .{ .max_anisotropy = n }));
    }
    for ([_]u8{ 1, 16 }) |n| {
        var renderer = try Renderer.init(testing.allocator, fx.device, .{ .max_anisotropy = n });
        renderer.deinit();
    }
    if (rhi.backend != .null) return;
    var renderer = try Renderer.init(testing.allocator, fx.device, .{ .max_anisotropy = 4 });
    defer renderer.deinit();
    var pixels = [_]u8{255} ** (4 * 4 * 4);
    const image = asset.Image{ .width = 4, .height = 4, .pixels = &pixels };
    const Case = struct { filter: Filter, mipmaps: bool, want: u8 };
    for ([_]Case{
        .{ .filter = .linear, .mipmaps = true, .want = 4 },
        .{ .filter = .linear, .mipmaps = false, .want = 1 },
        .{ .filter = .nearest, .mipmaps = true, .want = 1 },
    }) |case| {
        const handle = try renderer.createTexture(image, .{ .filter = case.filter, .mipmaps = case.mipmaps, .wrap = .repeat });
        const state = renderer.textures.get(handle).?;
        try testing.expectEqual(case.want, fx.device.samplers.getConst(state.sampler).?.desc.max_anisotropy);
    }
}

test "disabled shadow map and abandoned caster preparation leave healthy unshadowed frames" {
    for ([_]u32{ 0, 1024 }) |size| {
        var fx = try TestFixture.initConfig(.{ .sample_count = 1, .shadow_size = size }, 32);
        defer fx.deinit();
        const mesh = try litQuad(&fx.renderer, 0);
        try fx.renderer.begin(testView(32));
        try fx.renderer.addLight(.{ .kind = .directional, .intensity = 1, .casts_shadow = true, .world = .identity });
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });
        const frame = try fx.device.beginFrame();
        const cmd = try fx.device.beginCommandBuffer();
        try fx.renderer.prepare(cmd, frame);
        cmd.discard();
        try fx.device.endFrame();
        try testing.expectEqual(size == 0, fx.renderer.shadow_fit == null);
        try testing.expectEqual(size == 0, fx.renderer.shadow_target.isNone());
        try fx.renderer.begin(testView(32));
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });
        try finishTestFrame(&fx);
        if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
    }
}

fn shadowAllocationProof(gpa: Allocator) !void {
    const device = try rhi.Device.init(gpa, .{ .surface_size = .{ .width = 32, .height = 32 } });
    defer device.deinit();
    var renderer = try Renderer.init(gpa, device, .{ .sample_count = 1, .shadow_size = 1024 });
    defer renderer.deinit();
    // Includes per-slot replacement groups, all shaders, and candidate rollback.
    try renderer.ensureShadowResources();
}

test "shadow resource construction releases each partial candidate on allocation failure" {
    if (rhi.backend != .null) return;
    try testing.checkAllAllocationFailures(testing.allocator, shadowAllocationProof, .{});
}

test "unrepresentable shadow fit and receiver offset are refused before upload" {
    var fx = try TestFixture.initConfig(.{ .sample_count = 1, .shadow_size = 1024, .shadow_normal_offset = std.math.floatMax(f32) }, 32);
    defer fx.deinit();
    var view = testView(32);
    view.camera.far = 1e31;
    view.shadow_distance = 1e30;
    try fx.renderer.begin(view);
    try fx.renderer.addLight(.{ .kind = .directional, .intensity = 1, .casts_shadow = true, .world = .identity });
    try testing.expectError(error.InvalidCamera, fx.renderer.plan());
    view.camera.far = 2000;
    view.shadow_distance = 1000;
    try fx.renderer.begin(view);
    try fx.renderer.addLight(.{ .kind = .directional, .intensity = 1, .casts_shadow = true, .world = .identity });
    try testing.expectError(error.InvalidConfig, fx.renderer.plan());
}

test "shadow selects off-camera opaque and masked casters but never blend or disabled material" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const mesh = try litQuad(&fx.renderer, 3);
    const mask = try fx.renderer.createMaterial(.{ .alpha_mode = .mask }, "mask caster");
    const blend = try fx.renderer.createMaterial(.{ .alpha_mode = .blend }, "blend not caster");
    const disabled = try fx.renderer.createMaterial(.{ .casts_shadow = false }, "disabled caster");
    try fx.renderer.begin(testView(32));
    // Both are behind the camera; the first reaches the receiver box along light Z.
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(0, 0, 100)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(1000, 0, 100)) });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = mask, .world = .identity });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = blend, .world = .identity });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = disabled, .world = .identity });
    try fx.renderer.addLight(.{ .kind = .directional, .intensity = 1, .world = .identity, .casts_shadow = true });
    try fx.renderer.plan();
    try finishTestFrame(&fx);
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, fx.renderer.shadow_order.items);
    try testing.expectEqual(@as(u32, 2), fx.renderer.frameStats().shadow_draws);
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().shadow_culled);
    try testing.expectEqual(@as(u32, 2), fx.renderer.frameStats().culled);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
    // No-caster next frame skips both the pass and lookup, even after map creation.
    try fx.renderer.begin(testView(32));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u32, 0), fx.renderer.frameStats().shadow_draws);
    try testing.expect(fx.renderer.shadow_fit == null);
}

test "directional shadow readbacks track off-camera masked mirrored moving occluders at 1x and 4x" {
    if (rhi.backend == .null) return;
    for ([_]u32{ 1, 4 }) |samples| {
        var fx = try TestFixture.init(samples, 32);
        defer fx.deinit();
        const mesh = try litQuad(&fx.renderer, 3);
        const vertex_hole = try litQuadAlpha(&fx.renderer, 3, 0.2);
        const surface: lighting.Surface = .{ .base = .{ 0.6, 0.3, 0.1 }, .roughness = 0.7 };
        const receiver = try fx.renderer.createMaterial(.{ .shading = lit_id, .base_color = .{ 0.6, 0.3, 0.1, 1 }, .roughness = 0.7 }, "receiver");
        const light: Light = .{ .kind = .directional, .intensity = 2, .casts_shadow = true, .world = Mat4.fromQuat(core.math.Quat.lookRotation(.init(-1, 0, -1), .up).?) };
        const readback = try fx.device.createBuffer(.{ .size = material_test_bytes, .usage = .{ .copy_dst = true }, .memory = .readback });
        defer fx.device.destroyBuffer(readback);
        var hole_pixel = [_]u8{ 255, 255, 255, 0 };
        const hole = try fx.renderer.createTexture(.{ .width = 1, .height = 1, .pixels = &hole_pixel }, .{ .filter = .nearest });
        for ([_]struct { mode: AlphaMode = .@"opaque", hole: bool = false, vertex_hole: bool = false, factor_hole: bool = false, mirror: bool = false, moved: bool = false, casts: bool = true, disabled: bool = false }{
            .{},                                     .{ .mirror = true },                     .{ .mode = .mask }, .{ .mode = .mask, .hole = true },
            .{ .mode = .blend },                     .{ .casts = false },                     .{ .moved = true }, .{ .disabled = true },
            .{ .mode = .mask, .vertex_hole = true }, .{ .mode = .mask, .factor_hole = true },
        }) |case| {
            const caster = try fx.renderer.createMaterial(.{ .base_color = .{ 1, 1, 1, if (case.factor_hole) 0.2 else 1 }, .base_color_texture = if (case.hole) hole else .none, .alpha_mode = case.mode, .casts_shadow = case.casts }, "occluder");
            defer fx.renderer.destroyMaterial(caster);
            var view = testView(32);
            view.ambient = .{ 0.2, 0.3, 0.4 };
            view.shadow_distance = 6;
            try fx.renderer.begin(view);
            var submitted = light;
            submitted.casts_shadow = !case.disabled;
            try fx.renderer.addLight(submitted);
            try fx.renderer.drawMesh(.{ .mesh = mesh, .material = receiver, .world = Mat4.mul(Mat4.translation(.init(0, 0, -2)), Mat4.scaling(.init(3, 3, 1))) });
            // x=3,z=-1 is wholly outside the camera, but casts at x=0,z=-4.
            try fx.renderer.drawMesh(.{ .mesh = if (case.vertex_hole) vertex_hole else mesh, .material = caster, .world = Mat4.mul(Mat4.translation(.init(if (case.moved) 4.5 else 3, 0, 1)), Mat4.scaling(.init(if (case.mirror) -0.5 else 0.5, 0.8, 1))) });
            const frame = try fx.device.beginFrame();
            const cmd = try fx.device.beginCommandBuffer();
            try fx.renderer.prepare(cmd, frame);
            try fx.renderer.recordFrame(cmd, frame, false);
            try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
            try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = 32, .height = 32 }, .dst = readback });
            try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
            try cmd.submit();
            try fx.device.endFrame();
            fx.device.waitIdle();
            const bytes = try fx.device.mapBuffer(readback);
            defer fx.device.unmapBuffer(readback);
            const occluded = !case.hole and !case.vertex_hole and !case.factor_hole and case.mode != .blend and case.casts and !case.disabled;
            for ([_]usize{ 16, 22 }) |x| {
                const p = Vec3.init(((@as(f32, @floatFromInt(x)) + 0.5) / 16 - 1) * 4, -4.0 / 32.0, -4);
                const shadowed = occluded and (if (case.moved) x == 22 else x == 16);
                const expected = lighting.shade(surface, p, .init(0, 0, 1), .zero, if (shadowed) &.{} else &.{light}, view.ambient, null);
                try expectDisplayTexel(displayTexel(fx.device.capabilities().surface_format, expected), bytes[(16 * 32 + x) * 4 ..][0..4].*);
            }
        }
    }
}

fn litBox(renderer: *Renderer) !MeshHandle {
    var positions: [24]Vec3 = undefined;
    var normals: [24]Vec3 = undefined;
    var indices: [36]u16 = undefined;
    const center = Vec3.init(0, 0, -2.2);
    const axes = [_]Vec3{ .init(0, 0, 1), .init(0, 0, -1), .init(1, 0, 0), .init(-1, 0, 0), .init(0, 1, 0), .init(0, -1, 0) };
    for (axes, 0..) |n, face| {
        const t = if (@abs(n.y) == 1) Vec3.init(1, 0, 0) else Vec3.cross(.init(0, 1, 0), n);
        const b = Vec3.cross(n, t);
        for ([_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } }, 0..) |corner, i| {
            positions[4 * face + i] = Vec3.add(center, Vec3.scale(Vec3.add(n, Vec3.add(Vec3.scale(t, corner[0]), Vec3.scale(b, corner[1]))), 0.4));
            normals[4 * face + i] = n;
        }
        for ([_]u16{ 0, 1, 2, 0, 2, 3 }, 0..) |index, i| indices[6 * face + i] = @intCast(4 * face + index);
    }
    return renderer.createMesh(.{
        .vertex_count = 24,
        .streams = &.{
            .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) },
            .{ .semantic = .normal, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&normals) },
        },
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&indices),
        .submeshes = &.{.{ .first_index = 0, .index_count = 36 }},
        .bounds = try asset.Mesh.computeBounds(&positions),
    }, "lit reference box");
}

test "lit reference plane and box match CPU dielectric metal emission ambient and exposure" {
    if (rhi.backend == .null) return;
    for ([_]u32{ 1, 4 }) |samples| {
        var fx = try TestFixture.init(samples, material_test_size);
        defer fx.deinit();
        const plane = try litQuad(&fx.renderer, 0);
        const box = try litBox(&fx.renderer);
        const readback = try fx.device.createBuffer(.{ .size = material_test_bytes, .usage = .{ .copy_dst = true }, .memory = .readback });
        defer fx.device.destroyBuffer(readback);
        const cases = [_]struct { surface: lighting.Surface, ambient: [3]f32 = .{ 0.2, 0.3, 0.4 }, ev: ?f32 = null, mirror: bool = false }{
            .{ .surface = .{ .base = .{ 0.6, 0.2, 0.1 }, .roughness = 0.7 } },
            .{ .surface = .{ .base = .{ 0.7, 0.5, 0.2 }, .metallic = 1, .roughness = 0.45 } },
            .{ .surface = .{ .base = .{ 0.2, 0.5, 0.7 }, .metallic = 0.4, .roughness = 0.8 }, .mirror = true },
            .{ .surface = .{ .base = .{ 0, 0, 0 }, .emissive = .{ 12, 2, 0.3 } }, .ev = 2 },
            .{ .surface = .{ .base = .{ 0.5, 0.4, 0.3 }, .metallic = 1 }, .ev = -1 },
            .{ .surface = .{ .base = .{ 0, 0, 0 }, .metallic = 1 } },
        };
        const lights = [_]Light{
            .{ .kind = .directional, .color = .{ 1, 0.9, 0.8 }, .intensity = 2, .world = .identity },
            .{ .kind = .point, .color = .{ 0.3, 0.6, 1 }, .intensity = 3, .range = 5, .world = Mat4.translation(.init(0, 0.5, -0.5)) },
            .{ .kind = .spot, .color = .{ 0.7, 0.2, 0.1 }, .intensity = 2, .range = 4, .world = .identity },
        };
        for (cases) |case| {
            const material = try fx.renderer.createMaterial(.{
                .shading = lit_id,
                .base_color = .{ case.surface.base[0], case.surface.base[1], case.surface.base[2], 1 },
                .metallic = case.surface.metallic,
                .roughness = case.surface.roughness,
                .emissive = if (case.surface.emissive[0] != 0) .{ 1, 1.0 / 6.0, 0.025 } else .{ 0, 0, 0 },
                .emissive_strength = 12,
            }, "lit reference");
            defer fx.renderer.destroyMaterial(material);
            var view = testView(material_test_size);
            view.ambient = case.ambient;
            view.exposure_ev100 = case.ev;
            try fx.renderer.begin(view);
            for (lights) |light| try fx.renderer.addLight(light);
            const sign: f32 = if (case.mirror) -1 else 1;
            try fx.renderer.drawMesh(.{ .mesh = plane, .material = material, .world = Mat4.mul(Mat4.translation(.init(0.65, 0, 0)), Mat4.scaling(.init(0.45 * sign, 0.8, 1))) });
            try fx.renderer.drawMesh(.{ .mesh = box, .material = material, .world = Mat4.mul(Mat4.translation(.init(-0.65, 0, 0)), Mat4.scaling(.init(sign, 1, 1))) });
            const frame = try fx.device.beginFrame();
            const cmd = try fx.device.beginCommandBuffer();
            try fx.renderer.prepare(cmd, frame);
            try fx.renderer.recordFrame(cmd, frame, false);
            try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
            try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = material_test_size, .height = material_test_size }, .dst = readback });
            try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
            try cmd.submit();
            try fx.device.endFrame();
            fx.device.waitIdle();
            const bytes = try fx.device.mapBuffer(readback);
            defer fx.device.unmapBuffer(readback);
            for ([_]struct { x: usize, depth: f32 }{ .{ .x = 22, .depth = 2 }, .{ .x = 10, .depth = 1.8 } }) |pixel| {
                const p = Vec3.init(((@as(f32, @floatFromInt(pixel.x)) + 0.5) / 16 - 1) * pixel.depth, -pixel.depth / 32, -pixel.depth);
                const expected = lighting.shade(case.surface, p, .init(0, 0, 1), .zero, &lights, case.ambient, case.ev);
                try expectDisplayTexel(displayTexel(fx.device.capabilities().surface_format, expected), bytes[(16 * material_test_size + pixel.x) * 4 ..][0..4].*);
            }
        }
    }
}

test "lit five texture slots and all fragment variants match effective CPU texels" {
    if (rhi.backend == .null) return;
    var fx = try TestFixture.init(1, material_test_size);
    defer fx.deinit();
    const mesh = try litQuad(&fx.renderer, 7);
    const pixels = [_][4]u8{ .{ 180, 120, 60, 255 }, .{ 255, 160, 190, 255 }, .{ 128, 190, 240, 255 }, .{ 70, 0, 0, 255 }, .{ 100, 160, 220, 255 } };
    var textures: [5]TextureHandle = undefined;
    for (pixels, &textures, 0..) |pixel, *texture, i| {
        var bytes = pixel;
        texture.* = try fx.renderer.createTexture(.{ .width = 1, .height = 1, .pixels = &bytes }, .{ .color_space = if (i == 0 or i == 4) .srgb else .linear });
    }
    defer for (textures) |texture| fx.renderer.destroyTexture(texture);
    const readback = try fx.device.createBuffer(.{ .size = material_test_bytes, .usage = .{ .copy_dst = true }, .memory = .readback });
    defer fx.device.destroyBuffer(readback);
    const light = Light{ .kind = .directional, .intensity = 2, .world = .identity };
    for ([_]struct { mode: AlphaMode, coverage: f32 }{
        .{ .mode = .@"opaque", .coverage = 1 },
        .{ .mode = .mask, .coverage = 1 },
        .{ .mode = .mask, .coverage = 0.25 },
        .{ .mode = .blend, .coverage = 0.4 },
    }) |alpha_case| for ([_]bool{ false, true }) |mapped| for ([_]bool{ false, true }) |mirror| {
        const alpha = alpha_case.mode;
        const material = try fx.renderer.createMaterial(.{
            .shading = lit_id,
            .base_color = .{ 0.7, 0.8, 0.9, alpha_case.coverage },
            .base_color_texture = textures[0],
            .metallic = 0.6,
            .roughness = 0.9,
            .metallic_roughness_texture = textures[1],
            .normal_texture = if (mapped) textures[2] else .none,
            .normal_scale = 0.7,
            .occlusion_texture = textures[3],
            .occlusion_strength = 0.8,
            .emissive = .{ 0.2, 0.3, 0.4 },
            .emissive_texture = textures[4],
            .emissive_strength = 2,
            .alpha_mode = alpha,
        }, "five slot lit");
        defer fx.renderer.destroyMaterial(material);
        var view = testView(material_test_size);
        view.ambient = .{ 0.3, 0.4, 0.5 };
        try fx.renderer.begin(view);
        try fx.renderer.addLight(light);
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = Mat4.scaling(.init(if (mirror) -1 else 1, 1, 1)) });
        const frame = try fx.device.beginFrame();
        const cmd = try fx.device.beginCommandBuffer();
        try fx.renderer.prepare(cmd, frame);
        try fx.renderer.recordFrame(cmd, frame, false);
        try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
        try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = material_test_size, .height = material_test_size }, .dst = readback });
        try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
        try cmd.submit();
        try fx.device.endFrame();
        fx.device.waitIdle();
        var surface: lighting.Surface = .{ .metallic = 0.6 * 190 / 255.0, .roughness = 0.9 * 160 / 255.0, .occlusion = 1 + 0.8 * (70.0 / 255.0 - 1) };
        for (&surface.base, pixels[0][0..3], [_]f32{ 0.7, 0.8, 0.9 }) |*value, byte, factor| value.* = srgbToLinear(byte) * factor;
        for (&surface.emissive, pixels[4][0..3], [_]f32{ 0.2, 0.3, 0.4 }) |*value, byte, factor| value.* = srgbToLinear(byte) * factor * 2;
        const normal: Vec3 = if (mapped) .init((128.0 / 255.0 * 2 - 1) * 0.7 * (if (mirror) @as(f32, -1) else 1), (190.0 / 255.0 * 2 - 1) * 0.7, 240.0 / 255.0 * 2 - 1) else .init(0, 0, 1);
        var expected = lighting.shade(surface, .init(0.0625, -0.0625, -2), normal, .zero, &.{light}, view.ambient, null);
        if (alpha == .blend) for (&expected, view.clear_color[0..3]) |*value, clear| {
            value.* = value.* * 0.4 + clear * 0.6;
        };
        if (alpha == .mask and alpha_case.coverage < 0.5) expected = view.clear_color[0..3].*;
        const bytes = try fx.device.mapBuffer(readback);
        defer fx.device.unmapBuffer(readback);
        try expectDisplayTexel(displayTexel(fx.device.capabilities().surface_format, expected), bytes[(16 * material_test_size + 16) * 4 ..][0..4].*);
    };
}

fn srgbToLinear(byte: u8) f32 {
    const v = @as(f32, @floatFromInt(byte)) / 255;
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
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
    try fx.renderer.recordFrame(cmd, frame, false);
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

fn displayTexel(format: rhi.TextureFormat, linear: [3]f32) [4]u8 {
    const mapped = lighting.toneMap(linear);
    var out: [4]u8 = .{ 0, 0, 0, 255 };
    const srgb = format == .rgba8_unorm_srgb or format == .bgra8_unorm_srgb;
    for (mapped, 0..) |v, i| {
        const encoded = if (!srgb) v else if (v <= 0.0031308) 12.92 * v else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
        out[i] = @intFromFloat(@round(std.math.clamp(encoded, 0, 1) * 255));
    }
    if (format == .bgra8_unorm or format == .bgra8_unorm_srgb) std.mem.swap(u8, &out[0], &out[2]);
    return out;
}

fn texelMatches(expected: [4]u8, actual: [4]u8) bool {
    const tolerance: i16 = if (rhi.backend == .vulkan) 3 else 2;
    for (expected[0..3], actual[0..3]) |e, a| if (@abs(@as(i16, e) - @as(i16, a)) > tolerance) return false;
    return expected[3] == actual[3];
}

fn expectDisplayTexel(expected: [4]u8, actual: [4]u8) !void {
    try testing.expect(texelMatches(expected, actual));
}

test "HDR tone map reads back toe midtones highlights and unexposed unlit output" {
    if (rhi.backend == .null) return;
    for ([_]u32{ 1, 4 }) |samples| {
        var fx = try TestFixture.init(samples, material_test_size);
        defer fx.deinit();
        const mesh = try testMesh(&fx.renderer, false);
        defer fx.renderer.destroyMesh(mesh);
        const material = try fx.renderer.createMaterial(.{ .base_color = .{ 0.4, 0.2, 0.1, 1 } }, "unexposed unlit");
        defer fx.renderer.destroyMaterial(material);
        const readback = try fx.device.createBuffer(.{ .size = material_test_bytes, .usage = .{ .copy_dst = true }, .memory = .readback });
        defer fx.device.destroyBuffer(readback);
        const cases = [_]struct { color: [3]f32, ev: ?f32 }{
            .{ .color = .{ 0.04, 0.04, 0.04 }, .ev = null },
            .{ .color = .{ 0.5, 0.3, 0.2 }, .ev = 0 },
            .{ .color = .{ 1, 1, 1 }, .ev = 15 },
            .{ .color = .{ 100, 10, 1 }, .ev = -4 },
        };
        for (cases) |case| {
            var view = testView(material_test_size);
            view.clear_color = .{ case.color[0], case.color[1], case.color[2], 1 };
            view.exposure_ev100 = case.ev;
            try fx.renderer.begin(view);
            try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity });
            const frame = try fx.device.beginFrame();
            const cmd = try fx.device.beginCommandBuffer();
            try fx.renderer.prepare(cmd, frame);
            try fx.renderer.recordFrame(cmd, frame, false);
            try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
            try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = material_test_size, .height = material_test_size }, .dst = readback });
            try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
            try cmd.submit();
            try fx.device.endFrame();
            fx.device.waitIdle();
            const bytes = try fx.device.mapBuffer(readback);
            defer fx.device.unmapBuffer(readback);
            const format = fx.device.capabilities().surface_format;
            try expectDisplayTexel(displayTexel(format, case.color), bytes[0..4].*);
            const centre = (16 * material_test_size + 16) * 4;
            try expectDisplayTexel(displayTexel(format, .{ 0.4, 0.2, 0.1 }), bytes[centre..][0..4].*);
            // The lower wide part of the triangle must not be flipped into its narrow top.
            const lower = (20 * material_test_size + 21) * 4;
            const upper = (10 * material_test_size + 21) * 4;
            try expectDisplayTexel(displayTexel(format, .{ 0.4, 0.2, 0.1 }), bytes[lower..][0..4].*);
            try expectDisplayTexel(displayTexel(format, case.color), bytes[upper..][0..4].*);
        }
    }
}

test "draw constants pin the world and cofactor columns including singular transforms" {
    try testing.expectEqual(@as(usize, 112), @sizeOf(DrawConstants));
    try testing.expectEqual(@as(usize, 64), @offsetOf(DrawConstants, "cofactor"));
    const reflected = drawConstants(Mat4.scaling(.init(-2, 3, 4)));
    try testing.expectEqual([3][4]f32{ .{ 12, 0, 0, 0 }, .{ 0, -8, 0, 0 }, .{ 0, 0, -6, 0 } }, reflected.cofactor);
    const singular = drawConstants(Mat4.scaling(.init(0, 3, 4)));
    try testing.expectEqual(@as(f32, 12), singular.cofactor[0][0]);
    for (singular.cofactor) |column| for (column) |v| try testing.expect(std.math.isFinite(v));
}

fn initAllocationProof(gpa: Allocator) !void {
    const device = try rhi.Device.init(testing.allocator, .{});
    defer device.deinit();
    var renderer = try Renderer.init(gpa, device, .{});
    defer renderer.deinit();
}

test "renderer construction releases resources at every allocator failure" {
    if (rhi.backend != .null) return;
    try testing.checkAllAllocationFailures(testing.allocator, initAllocationProof, .{});
}

test "an HDR target rebuild failure preserves the live targets and group" {
    if (rhi.backend != .null) return;
    var fx = try TestFixture.init(4, 32);
    defer fx.deinit();
    try fx.renderer.ensureTargets(.{ .width = 32, .height = 32 });
    const old_hdr = fx.renderer.hdr_target;
    const old_color = fx.renderer.color_target;
    const old_depth = fx.renderer.depth_target;
    const old_group = fx.renderer.tone_group;
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    fx.device.gpa = failing.allocator();
    defer fx.device.gpa = testing.allocator;
    try testing.expectError(error.OutOfMemory, fx.renderer.ensureTargets(.{ .width = 64, .height = 64 }));
    try testing.expectEqual(old_hdr, fx.renderer.hdr_target);
    try testing.expectEqual(old_color, fx.renderer.color_target);
    try testing.expectEqual(old_depth, fx.renderer.depth_target);
    try testing.expectEqual(old_group, fx.renderer.tone_group);
    try testing.expectEqual(Extent2D{ .width = 32, .height = 32 }, fx.renderer.target_size);
}

test "textured mask blend and mirrored winding read back at 1x and 4x" {
    if (rhi.backend == .null) return;
    for ([_]u32{ 1, 4 }) |samples| {
        const masked = try renderMaterialCase(samples, .mask);
        const clear = displayTexel(masked.format, .{ 0, 0, 1 });
        const green = displayTexel(masked.format, .{ 0, 1, 0 });
        try expectDisplayTexel(clear, materialTexel(&masked.pixels, 12, 16));
        try expectDisplayTexel(green, materialTexel(&masked.pixels, 20, 16));
        // At 1x a cutout has no edge blend: every pixel is the clear colour or the texel.
        if (samples == 1) for (0..material_test_size) |y| for (0..material_test_size) |x| {
            const texel = materialTexel(&masked.pixels, x, y);
            try testing.expect(texelMatches(clear, texel) or texelMatches(green, texel));
        };

        const blended = try renderMaterialCase(samples, .blend);
        const pixel = materialTexel(&blended.pixels, 16, 16);
        try expectDisplayTexel(displayTexel(blended.format, .{ 0.5, 0, 0.5 }), pixel);

        const mirrored = try renderMaterialCase(samples, .mirrored);
        try expectDisplayTexel(green, materialTexel(&mirrored.pixels, 16, 16));
        try expectDisplayTexel(clear, materialTexel(&mirrored.pixels, 1, 1));
    }
}

const grazing_size = 64;
const grazing_bytes = grazing_size * grazing_size * 4;

/// A floor running away from the camera, textured with 2-texel stripes across it, read back
/// at the given anisotropy (`meshes.md` §13). Between 2.7 and 8 m away a pixel covers about
/// one texel across the stripes and four along the floor.
fn renderGrazing(max_anisotropy: u8) ![grazing_bytes]u8 {
    var fx = try TestFixture.initConfig(.{ .sample_count = 1, .max_anisotropy = max_anisotropy }, grazing_size);
    defer fx.deinit();
    const positions = [_]Vec3{ .init(-8, -1, -0.5), .init(8, -1, -0.5), .init(8, -1, -40), .init(-8, -1, -40) };
    // Two repeats over 16 m across (8 texels a metre), and 8 texels a metre along.
    const uvs = [_][2]f32{ .{ 0, 0.5 / 8.0 }, .{ 2, 0.5 / 8.0 }, .{ 2, 40.0 / 8.0 }, .{ 0, 40.0 / 8.0 } };
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = 6 }};
    const streams = [_]asset.MeshStream{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) },
        .{ .semantic = .uv0, .format = .float32x2, .bytes = std.mem.sliceAsBytes(&uvs) },
    };
    const mesh = try fx.renderer.createMesh(.{
        .vertex_count = positions.len,
        .streams = &streams,
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&indices),
        .submeshes = &submeshes,
        .bounds = try asset.Mesh.computeBounds(&positions),
    }, "grazing floor");
    var stripes: [64 * 64 * 4]u8 = undefined;
    for (0..64) |y| for (0..64) |x| {
        const v: u8 = if ((x / 2) % 2 == 0) 255 else 0;
        stripes[(y * 64 + x) * 4 ..][0..4].* = .{ v, v, v, 255 };
    };
    const texture = try fx.renderer.createTexture(.{ .width = 64, .height = 64, .pixels = &stripes }, .{
        .filter = .linear,
        .mipmaps = true,
        .wrap = .repeat,
    });
    defer fx.renderer.destroyTexture(texture);
    const material = try fx.renderer.createMaterial(.{ .base_color_texture = texture, .double_sided = true }, "grazing stripes");
    defer fx.renderer.destroyMaterial(material);
    const readback = try fx.device.createBuffer(.{ .label = "grazing readback", .size = grazing_bytes, .usage = .{ .copy_dst = true }, .memory = .readback });
    defer fx.device.destroyBuffer(readback);

    try fx.renderer.begin(.{
        .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 100 },
        .target_size = .{ .width = grazing_size, .height = grazing_size },
        .clear_color = .{ 0, 0, 0, 1 },
    });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity });
    const frame = try fx.device.beginFrame();
    var cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, frame);
    try fx.renderer.recordFrame(cmd, frame, false);
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
    try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = grazing_size, .height = grazing_size }, .dst = readback });
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
    try cmd.submit();
    try fx.device.endFrame();
    fx.device.waitIdle();
    var pixels: [grazing_bytes]u8 = undefined;
    const mapped = try fx.device.mapBuffer(readback);
    @memcpy(&pixels, mapped[0..grazing_bytes]);
    fx.device.unmapBuffer(readback);
    return pixels;
}

/// The summed difference between neighbouring pixels' first channel, across rows 36 to 44:
/// the floor 8 to 2.7 m away, where the stripes are what changes along a row.
fn grazingContrast(pixels: *const [grazing_bytes]u8) u32 {
    var total: u32 = 0;
    for (36..45) |y| for (1..grazing_size) |x| {
        const a: i32 = pixels[(y * grazing_size + x) * 4];
        const b: i32 = pixels[(y * grazing_size + x - 1) * 4];
        total += @abs(a - b);
    };
    return total;
}

test "anisotropic filtering keeps a grazing floor's stripes that isotropic filtering blurs away" {
    if (rhi.backend == .null) return;
    const isotropic = try renderGrazing(1);
    const anisotropic = try renderGrazing(16);
    const flat = grazingContrast(&isotropic);
    const sharp = grazingContrast(&anisotropic);
    std.log.scoped(.render3d).info("grazing stripe contrast: isotropic {d}, anisotropic {d}", .{ flat, sharp });
    try testing.expect(sharp > flat * 2);
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
    try fx.renderer.recordFrame(cmd, frame, false);
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
    return displayTexel(format, if (red) .{ 1, 0, 0 } else .{ 0, 0, 1 });
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
            try expectDisplayTexel(red, crossingTexel(&red_first.pixels, 8, y));
            try expectDisplayTexel(blue, crossingTexel(&red_first.pixels, 55, y));
        }

        const crossing = crossingTexel(&red_first.pixels, 32, crossing_size / 2);
        if (samples == 1) {
            try expectDisplayTexel(blue, crossing);
        } else {
            const red_channel: usize = if (surface_format == .bgra8_unorm_srgb) 2 else 0;
            const blue_channel: usize = if (surface_format == .bgra8_unorm_srgb) 0 else 2;
            try testing.expect(crossing[red_channel] > 0 and crossing[red_channel] < 255);
            try testing.expect(crossing[blue_channel] > 0 and crossing[blue_channel] < 255);
            try testing.expectEqual(@as(u8, 255), crossing[3]);
        }
    }
}

test "culling drops only draws wholly outside the frustum, and counts them" {
    for ([_]bool{ true, false }) |cull| {
        var fx = try TestFixture.initConfig(.{ .sample_count = 1, .cull = cull }, 64);
        defer fx.deinit();
        const mesh = try testMesh(&fx.renderer, true);

        try fx.renderer.begin(testView(64));
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });
        // Behind the camera, and far to the left: wholly outside one plane each.
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(0, 0, 10)) });
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(-50, 0, 0)) });
        // Straddling the left plane at z = -2 (x = -2).
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(.init(-2, 0, 0)) });
        try finishTestFrame(&fx);

        const stats = fx.renderer.frameStats();
        if (cull) {
            try testing.expectEqual(@as(u32, 2), stats.culled);
            try testing.expectEqual(@as(u32, 2), stats.draws);
            try testing.expectEqualSlices(u32, &.{ 0, 3 }, fx.renderer.order.items);
        } else {
            try testing.expectEqual(@as(u32, 0), stats.culled);
            try testing.expectEqual(@as(u32, 4), stats.draws);
        }
        if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
    }
}

test "a submesh is culled by its own bounds, not the whole mesh's" {
    var fx = try TestFixture.initConfig(.{ .sample_count = 1 }, 64);
    defer fx.deinit();
    // Two triangles in one mesh: one in front of the camera, one 50 m to its left.
    const positions = [_]Vec3{
        .init(-1, -1, -2),  .init(1, -1, -2),   .init(0, 1, -2),
        .init(-51, -1, -2), .init(-49, -1, -2), .init(-50, 1, -2),
    };
    const indices = [_]u32{ 0, 1, 2, 3, 4, 5 };
    const submeshes = [_]asset.Submesh{ .{ .first_index = 0, .index_count = 3 }, .{ .first_index = 3, .index_count = 3 } };
    var streams = [_]asset.MeshStream{.{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) }};
    const mesh = try fx.renderer.createMesh(.{
        .vertex_count = positions.len,
        .streams = &streams,
        .index_format = .uint32,
        .indices = std.mem.sliceAsBytes(&indices),
        .submeshes = &submeshes,
        .bounds = try asset.Mesh.computeBounds(&positions),
    }, "render3d two submeshes");
    const state = fx.renderer.meshes.get(mesh).?;
    try testing.expectEqual(Vec3.init(-1, -1, -2), state.submesh_bounds[0].min);
    try testing.expectEqual(Vec3.init(-49, 1, -2), state.submesh_bounds[1].max);

    try fx.renderer.begin(testView(64));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .submesh = 0, .material = fx.material, .world = .identity });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .submesh = 1, .material = fx.material, .world = .identity });
    try finishTestFrame(&fx);
    const stats = fx.renderer.frameStats();
    try testing.expectEqual(@as(u32, 1), stats.culled);
    try testing.expectEqual(@as(u32, 1), stats.draws);
    try testing.expectEqualSlices(u32, &.{0}, fx.renderer.order.items);
}

test "updating a material keeps its handle, and a refused update changes nothing" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const handle = try fx.renderer.createMaterial(.{ .base_color = .{ 1, 0, 0, 1 } }, "update");
    try fx.renderer.updateMaterial(handle, .{ .base_color = .{ 0, 1, 0, 1 }, .alpha_mode = .blend }, "update");
    try testing.expectEqual(AlphaMode.blend, fx.renderer.materials.getConst(handle).?.desc.alpha_mode);

    var pixels = [_]u8{ 255, 255, 255, 255 };
    const linear = try fx.renderer.createTexture(.{ .width = 1, .height = 1, .pixels = &pixels }, .{ .color_space = .linear });
    const before = fx.renderer.materials.getConst(handle).?.*;
    try testing.expectError(error.WrongColorSpace, fx.renderer.updateMaterial(handle, .{ .base_color_texture = linear }, "update"));
    try testing.expectError(error.InvalidMaterialValue, fx.renderer.updateMaterial(handle, .{ .alpha_cutoff = 2 }, "update"));
    const after = fx.renderer.materials.getConst(handle).?.*;
    try testing.expect(before.group.eql(after.group) and before.uniform.eql(after.uniform));
    try testing.expectEqual(AlphaMode.blend, after.desc.alpha_mode);

    try testing.expectError(error.InvalidMaterial, fx.renderer.updateMaterial(.none, .{}, "update"));
    fx.renderer.destroyMaterial(handle);
    try testing.expect(!fx.renderer.isMaterial(handle));
    try testing.expectError(error.InvalidMaterial, fx.renderer.updateMaterial(handle, .{}, "update"));
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

const cull_size = 32;
const cull_bytes = cull_size * cull_size * 4;

fn renderCullScene(samples: u32, cull: bool) !struct { pixels: [cull_bytes]u8, culled: u32 } {
    var fx = try TestFixture.initConfig(.{ .sample_count = samples, .cull = cull }, cull_size);
    defer fx.deinit();
    const device = fx.device;
    const mesh = try testMesh(&fx.renderer, true);
    const readback = try device.createBuffer(.{
        .label = "cull equivalence readback",
        .size = cull_bytes,
        .usage = .{ .copy_dst = true },
        .memory = .readback,
    });
    defer device.destroyBuffer(readback);

    try fx.renderer.begin(testView(cull_size));
    // Inside, straddling the right edge, and three wholly outside: behind, beyond far, above.
    for ([_]Vec3{ .init(0, 0, 0), .init(2, 0, 0), .init(0, 0, 4), .init(0, 0, -200), .init(0, 40, 0) }) |at| {
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = Mat4.translation(at) });
    }
    const frame = try device.beginFrame();
    var cmd = try device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, frame);
    try fx.renderer.recordFrame(cmd, frame, false);
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
    try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = cull_size, .height = cull_size }, .dst = readback });
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
    try cmd.submit();
    try device.endFrame();
    device.waitIdle();

    var pixels: [cull_bytes]u8 = undefined;
    const mapped = try device.mapBuffer(readback);
    @memcpy(&pixels, mapped[0..cull_bytes]);
    device.unmapBuffer(readback);
    return .{ .pixels = pixels, .culled = fx.renderer.frameStats().culled };
}

test "culling changes no pixel: a scene reads back identically with it on and off" {
    if (rhi.backend == .null) return;
    for ([_]u32{ 1, 4 }) |samples| {
        const on = try renderCullScene(samples, true);
        const off = try renderCullScene(samples, false);
        try testing.expectEqual(@as(u32, 3), on.culled);
        try testing.expectEqual(@as(u32, 0), off.culled);
        try testing.expectEqualSlices(u8, &off.pixels, &on.pixels);
        // The straddling draw reached the image: its right half is clipped, not culled.
        const background = on.pixels[0..4];
        var lit: usize = 0;
        for (0..cull_size) |y| {
            const offset = (y * cull_size + cull_size - 2) * 4;
            if (!std.mem.eql(u8, on.pixels[offset..][0..4], background)) lit += 1;
        }
        try testing.expect(lit > 0);
    }
}

test "a staging buffer is reused only once the frame ring has passed its copy, and idle ones are given back" {
    var fx = try TestFixture.init(1, 16);
    defer fx.deinit();
    const r = &fx.renderer;
    const ring: u64 = @intCast(r.slots.len);

    // A copy may read the first until the frame after the next one's slot is waited for.
    const first = try r.reserveStaging("first", 64);
    r.returnStaging(first, true);
    const second = try r.reserveStaging("second", 64);
    try testing.expect(!second.buffer.eql(first.buffer));
    // Never submitted: free at once.
    r.returnStaging(second, false);
    const again = try r.reserveStaging("again", 64);
    try testing.expect(again.buffer.eql(second.buffer));
    r.returnStaging(again, true);

    // One frame short of the ring, neither is free; at it, both are, and the smaller of what
    // fits is taken.
    r.seeFrame(ring);
    const third = try r.reserveStaging("third", 64);
    try testing.expectEqual(@as(usize, 3), r.staging.items.len);
    r.returnStaging(third, false);
    r.seeFrame(ring + 1);
    const reused = try r.reserveStaging("reused", 32);
    try testing.expectEqual(@as(usize, 3), r.staging.items.len);
    try testing.expectEqual(@as(usize, 32), reused.bytes.len);
    r.returnStaging(reused, false);

    // Kept to a byte limit, giving back what would be free last.
    const big = try r.reserveStaging("big", 256);
    r.returnStaging(big, true);
    r.trimStaging(3 * 64);
    try testing.expectEqual(@as(usize, 3), r.staging.items.len);
    for (r.staging.items) |entry| try testing.expect(!entry.buffer.eql(big.buffer));

    // And once no load has reserved for long enough, every idle one goes.
    r.seeFrame(r.last_reservation + staging_idle_frames + 1);
    try testing.expectEqual(@as(usize, 0), r.staging.items.len);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

// -- M28 Step 2: lifetime and the write window (`runtime-geometry.md` §4) -------------

fn whiteTexture(renderer: *Renderer) !TextureHandle {
    var pixels = [_]u8{ 255, 255, 255, 255 };
    return renderer.createTexture(.{ .width = 1, .height = 1, .pixels = &pixels }, .{});
}

test "a texture a material binds outlives its handle until its last material goes" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const texture = try whiteTexture(&fx.renderer);
    const first = try fx.renderer.createMaterial(.{ .base_color_texture = texture }, "first");
    const second = try fx.renderer.createMaterial(.{ .base_color_texture = texture }, "second");
    const live = fx.device.textures.count();

    fx.renderer.destroyTexture(texture);
    // The handle answers nothing at once; the GPU object is still there for both materials.
    try testing.expectError(error.InvalidTexture, fx.renderer.createMaterial(.{ .base_color_texture = texture }, "late"));
    try testing.expectEqual(live, fx.device.textures.count());
    fx.renderer.destroyTexture(texture); // Twice is nothing.
    try testing.expectEqual(live, fx.device.textures.count());

    fx.renderer.destroyMaterial(first);
    try testing.expectEqual(live, fx.device.textures.count());
    // Rebuilt without it, the last binding goes, and the texture with it.
    try fx.renderer.updateMaterial(second, .{}, "second");
    try testing.expectEqual(live - 1, fx.device.textures.count());
    fx.renderer.destroyMaterial(second);
}

test "an unbound texture goes at once, and a refused material counts no binding" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const texture = try whiteTexture(&fx.renderer);
    const live = fx.device.textures.count();
    // Refused after the texture was found: the binding must not have been counted.
    try testing.expectError(error.InvalidMaterialValue, fx.renderer.createMaterial(.{ .base_color_texture = texture, .alpha_cutoff = 2 }, "refused"));
    try testing.expectError(error.WrongColorSpace, fx.renderer.createMaterial(.{ .base_color_texture = fx.renderer.linear_white }, "wrong space"));
    fx.renderer.destroyTexture(texture);
    try testing.expectEqual(live - 1, fx.device.textures.count());
}

test "a material rebuilt onto a texture binds the new one before it lets go of the old" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const texture = try whiteTexture(&fx.renderer);
    const material = try fx.renderer.createMaterial(.{ .base_color_texture = texture }, "material");
    fx.renderer.destroyTexture(texture);
    const live = fx.device.textures.count();
    // The same released texture cannot be named again, so a rebuild onto it is refused and
    // changes nothing: the old binding still holds it.
    try testing.expectError(error.InvalidTexture, fx.renderer.updateMaterial(material, .{ .base_color_texture = texture }, "material"));
    try testing.expectEqual(live, fx.device.textures.count());
    fx.renderer.destroyMaterial(material);
    try testing.expectEqual(live - 1, fx.device.textures.count());
}

test "a mesh and a material destroyed inside the window still record their submitted draw" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, false);
    const material = try fx.renderer.createMaterial(.{}, "doomed");
    const index_buffer = fx.renderer.meshes.getConst(mesh).?.index_buffer;
    const group = fx.renderer.materials.getConst(material).?.group;

    try fx.renderer.begin(testView(32));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity });
    fx.renderer.destroyMesh(mesh);
    fx.renderer.destroyMaterial(material);
    // No longer drawable, and still present for the draw already submitted.
    try testing.expectError(error.InvalidMesh, fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity }));
    try testing.expectError(error.InvalidMaterial, fx.renderer.drawMesh(.{ .mesh = try testMesh(&fx.renderer, false), .material = material, .world = .identity }));
    try testing.expect(!fx.renderer.isMaterial(material));
    try testing.expectError(error.InvalidMaterial, fx.renderer.updateMaterial(material, .{}, "doomed"));
    // A doomed mesh answers queries as a destroyed one does.
    try testing.expectEqual(@as(?usize, null), fx.renderer.meshJointCount(mesh));
    try testing.expectError(error.InvalidMesh, fx.renderer.validateSkin(mesh, null));
    try testing.expect(fx.device.bind_groups.getConst(group) != null);
    try testing.expect(fx.device.buffers.getConst(index_buffer) != null);
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().draws);
    // Freed when the window closed.
    try testing.expect(fx.device.bind_groups.getConst(group) == null);
    try testing.expect(fx.device.buffers.getConst(index_buffer) == null);
    try testing.expect(fx.renderer.meshes.getConst(mesh) == null);
    try testing.expect(fx.renderer.materials.getConst(material) == null);
    // Destroying them again, now gone, is nothing.
    fx.renderer.destroyMesh(mesh);
    fx.renderer.destroyMaterial(material);
}

test "a destroy outside the window is immediate, and an abandoned frame frees what it doomed" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const material = try fx.renderer.createMaterial(.{}, "now");
    const now_group = fx.renderer.materials.getConst(material).?.group;
    fx.renderer.destroyMaterial(material);
    try testing.expect(fx.device.bind_groups.getConst(now_group) == null);

    const doomed = try fx.renderer.createMaterial(.{}, "abandoned");
    const group = fx.renderer.materials.getConst(doomed).?.group;
    try fx.renderer.begin(testView(32));
    fx.renderer.destroyMaterial(doomed);
    try testing.expect(fx.device.bind_groups.getConst(group) != null);
    // Begun again without recording: nothing will record the first frame's draws.
    try fx.renderer.begin(testView(32));
    try testing.expect(fx.device.bind_groups.getConst(group) == null);
    try finishTestFrame(&fx);
}

test "deinit frees what a frame left doomed" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, false);
    try fx.renderer.begin(testView(32));
    fx.renderer.destroyMesh(mesh);
    // The testing allocator reports anything `deinit` leaves behind.
}

test "uploads are counted into the frame that follows them" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    // The first frame carries the renderer's own defaults; the second carries nothing.
    for ([_]u64{ 3 * 4, 0 }) |want| {
        try fx.renderer.begin(testView(32));
        try finishTestFrame(&fx);
        try testing.expectEqual(want, fx.renderer.frameStats().uploaded_bytes);
    }

    _ = try testMesh(&fx.renderer, true); // 36 + 12 + 6 bytes
    _ = try whiteTexture(&fx.renderer); // 4 bytes
    try fx.renderer.begin(testView(32));
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u64, 36 + 12 + 6 + 4), fx.renderer.frameStats().uploaded_bytes);
    try fx.renderer.begin(testView(32));
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u64, 0), fx.renderer.frameStats().uploaded_bytes);
}

test "destroying a material leaves a texture that is still live untouched" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const texture = try whiteTexture(&fx.renderer);
    const material = try fx.renderer.createMaterial(.{ .base_color_texture = texture }, "material");
    const live = fx.device.textures.count();
    fx.renderer.destroyMaterial(material);
    try testing.expectEqual(live, fx.device.textures.count());
    fx.renderer.destroyMaterial(try fx.renderer.createMaterial(.{ .base_color_texture = texture }, "again"));
    fx.renderer.destroyTexture(texture);
    try testing.expectEqual(live - 1, fx.device.textures.count());
}

// -- M28 Step 3: changes that keep the handle (`runtime-geometry.md` §5) --------------

/// A triangle, or with `quad` a square, of positions only, optionally with a colour stream.
fn shapeMesh(positions: []const Vec3, indices: []const u16, colors: ?[]const [4]u8, streams: *[2]asset.MeshStream, submeshes: *[1]asset.Submesh) !asset.Mesh {
    streams[0] = .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(positions) };
    if (colors) |values| streams[1] = .{ .semantic = .color, .format = .unorm8x4, .bytes = std.mem.sliceAsBytes(values) };
    submeshes[0] = .{ .first_index = 0, .index_count = @intCast(indices.len) };
    return .{
        .vertex_count = @intCast(positions.len),
        .streams = streams[0..if (colors != null) 2 else 1],
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(indices),
        .submeshes = submeshes,
        .bounds = try asset.Mesh.computeBounds(positions),
    };
}

const small_triangle = [_]Vec3{ .init(-0.5, -0.5, -2), .init(0.5, -0.5, -2), .init(0, 0.5, -2) };
const triangle_indices = [_]u16{ 0, 1, 2 };
const wide_quad = [_]Vec3{ .init(-1, -1, -3), .init(1, -1, -3), .init(1, 1, -3), .init(-1, 1, -3) };
const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

test "an updated mesh keeps its handle, fits in place or reallocates, and retires what it replaced" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, false);
    const color_slot = asset.MeshSemantic.color.slot();
    const first = fx.renderer.meshes.getConst(mesh).?.*;
    var streams: [2]asset.MeshStream = undefined;
    var submeshes: [1]asset.Submesh = undefined;

    // The same counts fit: the same buffers, the new bounds.
    try fx.renderer.updateMesh(mesh, try shapeMesh(&small_triangle, &triangle_indices, null, &streams, &submeshes), "fit");
    var now = fx.renderer.meshes.getConst(mesh).?.*;
    try testing.expect(now.vertex_buffers[0].eql(first.vertex_buffers[0]));
    try testing.expect(now.index_buffer.eql(first.index_buffer));
    try testing.expectEqual(@as(f32, 0.5), now.bounds.max.y);
    // Copied in place, waiting on what earlier frames read rather than discarding it.
    if (rhi.backend == .null) {
        try testing.expectEqual(@as(?u32, 0), fx.device.bufferContentsDiscarded(now.vertex_buffers[0]));
        try testing.expectEqual(@as(?u32, 0), fx.device.bufferContentsDiscarded(now.index_buffer));
    }

    // More vertices and indices, and a new stream: new buffers, the old ones retired.
    const colors = [_][4]u8{@splat(255)} ** 4;
    try fx.renderer.updateMesh(mesh, try shapeMesh(&wide_quad, &quad_indices, &colors, &streams, &submeshes), "grow");
    now = fx.renderer.meshes.getConst(mesh).?.*;
    try testing.expect(!now.vertex_buffers[0].eql(first.vertex_buffers[0]));
    try testing.expect(!now.index_buffer.eql(first.index_buffer));
    try testing.expect(fx.device.buffers.getConst(first.vertex_buffers[0]) == null);
    try testing.expect(fx.device.buffers.getConst(first.index_buffer) == null);
    try testing.expect(!now.vertex_buffers[color_slot].isNone());
    try testing.expectEqual(@as(usize, 6), now.submeshes[0].index_count);
    const grown = now;

    // Fewer again fits into the larger buffers, and a stream left out goes.
    try fx.renderer.updateMesh(mesh, try shapeMesh(&small_triangle, &triangle_indices, null, &streams, &submeshes), "shrink");
    now = fx.renderer.meshes.getConst(mesh).?.*;
    try testing.expect(now.vertex_buffers[0].eql(grown.vertex_buffers[0]));
    try testing.expect(now.index_buffer.eql(grown.index_buffer));
    try testing.expectEqual(grown.vertex_capacity[0], now.vertex_capacity[0]);
    try testing.expect(now.vertex_buffers[color_slot].isNone());
    try testing.expect(fx.device.buffers.getConst(grown.vertex_buffers[color_slot]) == null);
    try testing.expect(!StreamSet.has(.{ .bits = now.stream_mask }, .color));

    // A draw of the updated mesh records cleanly, and the next frame counts the updates.
    try fx.renderer.begin(testView(32));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u32, 3), fx.renderer.frameStats().mesh_updates);
    try testing.expect(fx.renderer.frameStats().uploaded_bytes > 0);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

test "a refused mesh update changes nothing, and none is accepted inside the window" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, true);
    const before = fx.renderer.meshes.getConst(mesh).?.*;
    const before_submesh = before.submeshes[0];
    const buffers = fx.device.buffers.count();
    var streams: [2]asset.MeshStream = undefined;
    var submeshes: [1]asset.Submesh = undefined;
    const valid = try shapeMesh(&wide_quad, &quad_indices, null, &streams, &submeshes);

    var broken = valid;
    const out_of_range = [_]u16{ 0, 1, 9 };
    broken.indices = std.mem.sliceAsBytes(&out_of_range);
    broken.submeshes = &.{.{ .first_index = 0, .index_count = 3 }};
    try testing.expectError(error.IndexOutOfRange, fx.renderer.updateMesh(mesh, broken, "broken"));

    try fx.renderer.begin(testView(32));
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });
    try testing.expectError(error.InFrame, fx.renderer.updateMesh(mesh, valid, "in frame"));
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().draws);

    // Nothing moved: the same buffers, streams, counts and boxes, and no buffer was made.
    const after = fx.renderer.meshes.getConst(mesh).?.*;
    try testing.expect(std.meta.eql(before.vertex_buffers, after.vertex_buffers));
    try testing.expect(before.index_buffer.eql(after.index_buffer));
    try testing.expectEqual(before.stream_mask, after.stream_mask);
    try testing.expectEqual(before_submesh, after.submeshes[0]);
    try testing.expect(std.meta.eql(before.bounds, after.bounds));
    try testing.expectEqual(buffers, fx.device.buffers.count());

    // Outside the window the same update is accepted; a gone or doomed handle never is.
    try fx.renderer.updateMesh(mesh, valid, "after");
    try testing.expectError(error.InvalidMesh, fx.renderer.updateMesh(.none, valid, "none"));
    try fx.renderer.begin(testView(32));
    fx.renderer.destroyMesh(mesh);
    try finishTestFrame(&fx);
    try testing.expectError(error.InvalidMesh, fx.renderer.updateMesh(mesh, valid, "gone"));
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

test "kept staging serves a mesh rewritten every frame without making new buffers" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    const mesh = try testMesh(&fx.renderer, false);
    var streams: [2]asset.MeshStream = undefined;
    var submeshes: [1]asset.Submesh = undefined;
    const update = try shapeMesh(&small_triangle, &triangle_indices, null, &streams, &submeshes);
    var settled: ?usize = null;
    for (0..12) |frame| {
        try fx.renderer.updateMesh(mesh, update, "water");
        try fx.renderer.begin(testView(32));
        try fx.renderer.drawMesh(.{ .mesh = mesh, .material = fx.material, .world = .identity });
        try finishTestFrame(&fx);
        // Once the ring has turned, the same few buffers are reused and nothing is made.
        if (frame == 2 * fx.renderer.slots.len) settled = fx.device.buffers.count();
        if (settled) |count| try testing.expectEqual(count, fx.device.buffers.count());
    }
    try testing.expect(fx.renderer.staging.items.len <= fx.renderer.slots.len + 2);
}

test "a texture region write keeps the texture and its materials, and refuses what it cannot write" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    var pixels: [4 * 4 * 4]u8 = @splat(255);
    const texture = try fx.renderer.createTexture(.{ .width = 4, .height = 4, .pixels = &pixels }, .{});
    const material = try fx.renderer.createMaterial(.{ .base_color_texture = texture }, "canvas");
    const gpu = fx.renderer.textures.getConst(texture).?.gpu;
    const group = fx.renderer.materials.getConst(material).?.group;
    const red = [_]u8{ 255, 0, 0, 255 } ** 4;
    var mipped_pixels: [4 * 4 * 4]u8 = @splat(255);
    const mipped = try fx.renderer.createTexture(.{ .width = 4, .height = 4, .pixels = &mipped_pixels }, .{ .mipmaps = true });
    // A frame, so the next counts the write alone and not the creations' uploads.
    try fx.renderer.begin(testView(32));
    try finishTestFrame(&fx);

    try fx.renderer.writeTexture(texture, .{ .x = 2, .y = 2, .width = 2, .height = 2 }, &red);
    try testing.expect(fx.renderer.textures.getConst(texture).?.gpu.eql(gpu));
    // The texels outside the region are kept: the write discards nothing.
    if (rhi.backend == .null) try testing.expectEqual(@as(?u32, 0), fx.device.contentsDiscarded(gpu));
    try testing.expect(fx.renderer.materials.getConst(material).?.group.eql(group));

    try testing.expectError(error.InvalidRegion, fx.renderer.writeTexture(texture, .{ .x = 3, .y = 2, .width = 2, .height = 2 }, &red));
    try testing.expectError(error.InvalidRegion, fx.renderer.writeTexture(texture, .{ .x = 0, .y = 3, .width = 1, .height = 2 }, red[0..8]));
    try testing.expectError(error.InvalidRegion, fx.renderer.writeTexture(texture, .{ .x = std.math.maxInt(u32), .width = 2, .height = 1 }, red[0..8]));
    try testing.expectError(error.InvalidRegion, fx.renderer.writeTexture(texture, .{ .width = 0, .height = 2 }, &.{}));
    try testing.expectError(error.InvalidPixelLength, fx.renderer.writeTexture(texture, .{ .width = 2, .height = 2 }, red[0..12]));
    try testing.expectError(error.InvalidTexture, fx.renderer.writeTexture(fx.renderer.white_texture, .{ .width = 1, .height = 1 }, red[0..4]));
    try testing.expectError(error.InvalidTexture, fx.renderer.writeTexture(.none, .{ .width = 1, .height = 1 }, red[0..4]));

    try testing.expectError(error.HasMips, fx.renderer.writeTexture(mipped, .{ .width = 1, .height = 1 }, red[0..4]));

    try fx.renderer.begin(testView(32));
    try testing.expectError(error.InFrame, fx.renderer.writeTexture(texture, .{ .width = 1, .height = 1 }, red[0..4]));
    try finishTestFrame(&fx);
    // One write was accepted, and the frame after it counts it.
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().texture_writes);
    try testing.expectEqual(@as(u64, red.len), fx.renderer.frameStats().uploaded_bytes);

    // A destroyed texture a material still binds keeps its GPU object, never its writes.
    fx.renderer.destroyTexture(texture);
    try testing.expectError(error.InvalidTexture, fx.renderer.writeTexture(texture, .{ .width = 1, .height = 1 }, red[0..4]));
    fx.renderer.destroyMaterial(material);
    fx.renderer.destroyTexture(mipped);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

test "a chain write replaces every level, and refuses another size, colour space or shape" {
    var fx = try TestFixture.init(1, 32);
    defer fx.deinit();
    var pixels: [4 * 4 * 4]u8 = @splat(255);
    const texture = try fx.renderer.createTexture(.{ .width = 4, .height = 4, .pixels = &pixels }, .{ .mipmaps = true });
    const gpu = fx.renderer.textures.getConst(texture).?.gpu;
    var green: [4 * 4 * 4]u8 = undefined;
    for (0..16) |i| green[i * 4 ..][0..4].* = .{ 0, 255, 0, 255 };
    var chain = try asset.mips.generate(testing.allocator, .{ .width = 4, .height = 4, .pixels = &green }, .srgb);
    defer chain.deinit(testing.allocator);
    var flat_pixels: [4 * 4 * 4]u8 = @splat(255);
    const flat = try fx.renderer.createTexture(.{ .width = 4, .height = 4, .pixels = &flat_pixels }, .{});
    try fx.renderer.begin(testView(32));
    try finishTestFrame(&fx);

    try fx.renderer.writeTextureChain(texture, chain, .srgb);
    try testing.expect(fx.renderer.textures.getConst(texture).?.gpu.eql(gpu));

    try testing.expectError(error.WrongColorSpace, fx.renderer.writeTextureChain(texture, chain, .linear));
    var larger_pixels: [8 * 8 * 4]u8 = @splat(0);
    var larger = try asset.mips.generate(testing.allocator, .{ .width = 8, .height = 8, .pixels = &larger_pixels }, .srgb);
    defer larger.deinit(testing.allocator);
    try testing.expectError(error.TextureSizeMismatch, fx.renderer.writeTextureChain(texture, larger, .srgb));

    // A chain that lies about itself: a level missing, the wrong size, bytes past the end.
    var short = chain;
    short.levels = chain.levels[0 .. chain.levels.len - 1];
    try testing.expectError(error.InvalidMipChain, fx.renderer.writeTextureChain(texture, short, .srgb));
    var levels: [3]asset.mips.Level = chain.levels[0..3].*;
    var lying = chain;
    lying.levels = &levels;
    levels[1].width = 1;
    try testing.expectError(error.InvalidMipChain, fx.renderer.writeTextureChain(texture, lying, .srgb));
    levels[1].width = 2;
    levels[2].offset = chain.bytes.len;
    try testing.expectError(error.InvalidMipChain, fx.renderer.writeTextureChain(texture, lying, .srgb));
    var empty = chain;
    empty.levels = &.{};
    try testing.expectError(error.InvalidMipChain, fx.renderer.writeTextureChain(texture, empty, .srgb));

    try testing.expectError(error.NoMips, fx.renderer.writeTextureChain(flat, chain, .srgb));

    try fx.renderer.begin(testView(32));
    try testing.expectError(error.InFrame, fx.renderer.writeTextureChain(texture, chain, .srgb));
    try finishTestFrame(&fx);
    try testing.expectEqual(@as(u32, 1), fx.renderer.frameStats().texture_writes);
    try testing.expectEqual(@as(u64, chain.bytes.len), fx.renderer.frameStats().uploaded_bytes);
    fx.renderer.destroyTexture(texture);
    fx.renderer.destroyTexture(flat);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), fx.device.violationCount());
}

const write_size = 32;
const write_bytes = write_size * write_size * 4;

/// Records and submits one frame of `mesh` with `material`, copying the surface into
/// `readback`, and does not wait: the next write lands while this frame may still be running.
fn submitWriteFrame(fx: *TestFixture, mesh: MeshHandle, material: MaterialHandle, readback: rhi.BufferHandle) !void {
    try fx.renderer.begin(.{
        .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 },
        .target_size = .{ .width = write_size, .height = write_size },
        .clear_color = .{ 0, 0, 1, 1 },
    });
    try fx.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity });
    const frame = try fx.device.beginFrame();
    var cmd = try fx.device.beginCommandBuffer();
    try fx.renderer.prepare(cmd, frame);
    try fx.renderer.recordFrame(cmd, frame, false);
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
    try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = write_size, .height = write_size }, .dst = readback });
    try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
    try cmd.submit();
    try fx.device.endFrame();
}

fn writeTexel(fx: *TestFixture, readback: rhi.BufferHandle, x: usize, y: usize) ![4]u8 {
    const mapped = try fx.device.mapBuffer(readback);
    defer fx.device.unmapBuffer(readback);
    return mapped[(y * write_size + x) * 4 ..][0..4].*;
}

test "a frame submitted before a write reads back unchanged, and the next one shows it" {
    // The null backend proves the commands and refusals above; pixels are Metal's evidence
    // here, and Vulkan's on the Windows target (Step 7).
    if (rhi.backend == .null) return;
    var fx = try TestFixture.init(1, write_size);
    defer fx.deinit();
    const format = fx.device.capabilities().surface_format;
    var readbacks: [6]rhi.BufferHandle = undefined;
    for (&readbacks) |*readback| readback.* = try fx.device.createBuffer(.{
        .label = "write readback",
        .size = write_bytes,
        .usage = .{ .copy_dst = true },
        .memory = .readback,
    });
    defer for (readbacks) |readback| fx.device.destroyBuffer(readback);
    const red = try fx.renderer.createMaterial(.{ .base_color = .{ 1, 0, 0, 1 }, .double_sided = true }, "red");
    var streams: [2]asset.MeshStream = undefined;
    var submeshes: [1]asset.Submesh = undefined;

    // A mesh: the left half, then the right half, in the same buffers.
    const left = [_]Vec3{ .init(-2, -2, -1), .init(0, -2, -1), .init(0, 2, -1), .init(-2, 2, -1) };
    const right = [_]Vec3{ .init(0, -2, -1), .init(2, -2, -1), .init(2, 2, -1), .init(0, 2, -1) };
    const mesh = try fx.renderer.createMesh(try shapeMesh(&left, &quad_indices, null, &streams, &submeshes), "moving half");
    try submitWriteFrame(&fx, mesh, red, readbacks[0]);
    try fx.renderer.updateMesh(mesh, try shapeMesh(&right, &quad_indices, null, &streams, &submeshes), "moving half");
    try submitWriteFrame(&fx, mesh, red, readbacks[1]);

    // A region: the right texel of a 2×1 white texture turned green.
    const quad = try materialQuad(&fx.renderer);
    var white = [_]u8{255} ** 8;
    const canvas = try fx.renderer.createTexture(.{ .width = 2, .height = 1, .pixels = &white }, .{ .filter = .nearest, .wrap = .clamp });
    const painted = try fx.renderer.createMaterial(.{ .base_color_texture = canvas, .double_sided = true }, "canvas");
    try submitWriteFrame(&fx, quad, painted, readbacks[2]);
    try fx.renderer.writeTexture(canvas, .{ .x = 1, .width = 1, .height = 1 }, &.{ 0, 255, 0, 255 });
    try submitWriteFrame(&fx, quad, painted, readbacks[3]);

    // A chain: a mipmapped white texture replaced whole by red.
    var white_square = [_]u8{255} ** (4 * 4 * 4);
    const mipped = try fx.renderer.createTexture(.{ .width = 4, .height = 4, .pixels = &white_square }, .{ .filter = .nearest, .mipmaps = true });
    const chained = try fx.renderer.createMaterial(.{ .base_color_texture = mipped, .double_sided = true }, "chained");
    var red_square: [4 * 4 * 4]u8 = undefined;
    for (0..16) |i| red_square[i * 4 ..][0..4].* = .{ 255, 0, 0, 255 };
    var chain = try asset.mips.generate(testing.allocator, .{ .width = 4, .height = 4, .pixels = &red_square }, .srgb);
    defer chain.deinit(testing.allocator);
    try submitWriteFrame(&fx, quad, chained, readbacks[4]);
    try fx.renderer.writeTextureChain(mipped, chain, .srgb);
    try submitWriteFrame(&fx, quad, chained, readbacks[5]);
    fx.device.waitIdle();

    const blue = displayTexel(format, .{ 0, 0, 1 });
    const solid_red = displayTexel(format, .{ 1, 0, 0 });
    const solid_white = displayTexel(format, .{ 1, 1, 1 });
    const solid_green = displayTexel(format, .{ 0, 1, 0 });
    try expectDisplayTexel(solid_red, try writeTexel(&fx, readbacks[0], 4, 16));
    try expectDisplayTexel(blue, try writeTexel(&fx, readbacks[0], 27, 16));
    try expectDisplayTexel(blue, try writeTexel(&fx, readbacks[1], 4, 16));
    try expectDisplayTexel(solid_red, try writeTexel(&fx, readbacks[1], 27, 16));
    // The quad spans about x 10 to 22; its texture's left texel is drawn left of 16.
    try expectDisplayTexel(solid_white, try writeTexel(&fx, readbacks[2], 19, 16));
    try expectDisplayTexel(solid_white, try writeTexel(&fx, readbacks[3], 13, 16));
    try expectDisplayTexel(solid_green, try writeTexel(&fx, readbacks[3], 19, 16));
    try expectDisplayTexel(solid_white, try writeTexel(&fx, readbacks[4], 16, 16));
    try expectDisplayTexel(solid_red, try writeTexel(&fx, readbacks[5], 16, 16));

    fx.renderer.destroyMaterial(painted);
    fx.renderer.destroyMaterial(chained);
    fx.renderer.destroyMaterial(red);
    fx.renderer.destroyTexture(canvas);
    fx.renderer.destroyTexture(mipped);
}
