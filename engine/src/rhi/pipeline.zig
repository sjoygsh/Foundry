//! Pipelines, layouts, and the binding model.
//!
//! The two numbers below are the most consequential in the RHI, and neither comes from
//! Metal. They are Vulkan's **guaranteed minimums**, because those are the binding
//! constraint and the other two APIs are more generous. Designing to what Metal permits
//! would produce an engine that works on every machine we own and fails on hardware we
//! do not.
//!
//! Design: `docs/design/rhi.md` §9.

const std = @import("std");
const core = @import("core");
const format = @import("format.zig");
const resource = @import("resource.zig");

/// **Four bind groups, and not more, because Vulkan only guarantees
/// `maxBoundDescriptorSets >= 4`.**
///
/// Groups are ordered by update frequency, and that ordering is not decoration: Vulkan
/// invalidates every descriptor set from the first one whose layout changes, so putting
/// the least-frequently-changed data in group 0 is what makes rebinding cheap. Getting it
/// backwards costs nothing on Metal and is expensive everywhere else.
///
///   0 — per frame   (camera, time, global lighting)
///   1 — per pass    (pass targets and parameters)
///   2 — per material(textures, samplers, material constants)
///   3 — per draw    (instance data)
pub const max_bind_groups: u32 = 4;

/// **128 bytes of inline constants, because that is Vulkan's push-constant minimum.**
///
/// D3D12's root signature is 64 DWORDs in total and must also hold the descriptor tables;
/// Metal's `setVertexBytes:` is far more generous. 128 is the number all three can honour.
///
/// See `docs/design/rhi.md` §9 for the full semantics. In brief, and enforced here: the
/// block is part of the command stream rather than a resource, bytes are copied at the
/// call, its scope is one render pass, writes replace the whole block, and binding a
/// pipeline with a different layout invalidates it. It is **not** a parameter system —
/// anything with structure, or that must outlive a pass, or that exceeds 128 bytes,
/// belongs in a uniform buffer reached through a bind group.
pub const max_inline_constant_bytes: u32 = 128;

// -- identity ------------------------------------------------------------------------

pub const BindGroupLayout = opaque {};
pub const BindGroup = opaque {};
pub const PipelineLayout = opaque {};
pub const RenderPipeline = opaque {};

pub const BindGroupLayoutHandle = core.Handle(BindGroupLayout);
pub const BindGroupHandle = core.Handle(BindGroup);
pub const PipelineLayoutHandle = core.Handle(PipelineLayout);
pub const RenderPipelineHandle = core.Handle(RenderPipeline);

// -- bind groups ---------------------------------------------------------------------

/// Which shader stages may see a binding.
///
/// Declared because Vulkan and D3D12 both require it and use it to place the binding;
/// Metal infers it from the shader. Another case of stating what the strictest API needs.
pub const ShaderStages = packed struct(u8) {
    vertex: bool = false,
    fragment: bool = false,
    _reserved: u6 = 0,

    pub const both: ShaderStages = .{ .vertex = true, .fragment = true };

    pub fn any(self: ShaderStages) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

pub const BindingType = enum {
    uniform_buffer,
    storage_buffer,
    sampled_texture,
    sampler,
};

pub const BindGroupLayoutEntry = struct {
    binding: u32,
    type: BindingType,
    visibility: ShaderStages,
};

pub const BindGroupLayoutDesc = struct {
    label: []const u8 = "",
    entries: []const BindGroupLayoutEntry,
};

pub const BufferBinding = struct {
    buffer: resource.BufferHandle,
    offset: u64 = 0,
    /// Zero means "the rest of the buffer from `offset`".
    size: u64 = 0,
};

pub const BindingResource = union(BindingType) {
    uniform_buffer: BufferBinding,
    storage_buffer: BufferBinding,
    sampled_texture: resource.TextureHandle,
    sampler: resource.SamplerHandle,
};

pub const BindGroupEntry = struct {
    binding: u32,
    resource: BindingResource,
};

pub const BindGroupDesc = struct {
    label: []const u8 = "",
    /// The layout this group is built for. A group may only be bound to a pipeline whose
    /// layout declares this same layout for that group index — checked, because in Vulkan
    /// and D3D12 a mismatch is undefined behaviour rather than an error.
    layout: BindGroupLayoutHandle,
    entries: []const BindGroupEntry,
};

// -- pipeline layout -----------------------------------------------------------------

/// What a pipeline expects to have bound.
///
/// Metal does not need this and its backend will mostly ignore it; Vulkan
/// (`VkPipelineLayout`) and D3D12 (`ID3D12RootSignature`) cannot function without it.
/// Declaring it up front is what makes a bind group's compatibility checkable rather than
/// discovered as corruption.
pub const PipelineLayoutDesc = struct {
    label: []const u8 = "",
    /// Group `i`'s layout. A `none` handle means group `i` is unused, which is legal and
    /// is how a pipeline that only wants per-frame and per-material data is expressed.
    /// At most `max_bind_groups` entries.
    bind_group_layouts: []const BindGroupLayoutHandle = &.{},
    /// How many bytes of inline constants this pipeline reads. At most
    /// `max_inline_constant_bytes`. Zero means the pipeline reads none, and setting them
    /// for such a pipeline is pointless but not an error — the bytes simply go nowhere.
    inline_constant_bytes: u32 = 0,
};

// -- render pipeline -----------------------------------------------------------------

pub const VertexStepMode = enum { vertex, instance };

pub const VertexAttribute = struct {
    /// Matches the attribute index the shader declares.
    location: u32,
    offset: u32,
    format: format.VertexFormat,
};

pub const VertexBufferLayout = struct {
    stride: u32,
    step_mode: VertexStepMode = .vertex,
    attributes: []const VertexAttribute,
};

pub const PrimitiveTopology = enum { triangle_list, triangle_strip, line_list, point_list };
pub const CullMode = enum { none, front, back };
pub const FrontFace = enum { counter_clockwise, clockwise };

pub const PrimitiveState = struct {
    topology: PrimitiveTopology = .triangle_list,
    cull_mode: CullMode = .none,
    front_face: FrontFace = .counter_clockwise,
};

pub const BlendFactor = enum {
    zero,
    one,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,
    src_color,
    one_minus_src_color,
};

pub const BlendOp = enum { add, subtract, reverse_subtract, min, max };

pub const BlendComponent = struct {
    src: BlendFactor = .one,
    dst: BlendFactor = .zero,
    op: BlendOp = .add,
};

pub const BlendState = struct {
    color: BlendComponent = .{},
    alpha: BlendComponent = .{},

    /// Straight alpha blending, which is what almost every 2D sprite wants.
    pub const alpha_blend: BlendState = .{
        .color = .{ .src = .src_alpha, .dst = .one_minus_src_alpha, .op = .add },
        .alpha = .{ .src = .one, .dst = .one_minus_src_alpha, .op = .add },
    };
};

pub const ColorTargetState = struct {
    format: format.TextureFormat,
    /// `null` means blending is disabled and the source replaces the destination.
    blend: ?BlendState = null,
    write_mask: ColorWriteMask = .{ .r = true, .g = true, .b = true, .a = true },
};

pub const ColorWriteMask = packed struct(u8) {
    r: bool = false,
    g: bool = false,
    b: bool = false,
    a: bool = false,
    _reserved: u4 = 0,
};

pub const CompareFunction = enum {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,
};

pub const DepthStencilState = struct {
    format: format.TextureFormat,
    depth_write_enabled: bool = false,
    depth_compare: CompareFunction = .always,
};

/// Monolithic, because all three APIs are monolithic here. Created ahead of time and never
/// mutated: `MTLRenderPipelineState`, `VkPipeline` and `ID3D12PipelineState` are all
/// immutable once built.
pub const RenderPipelineDesc = struct {
    label: []const u8 = "",
    layout: PipelineLayoutHandle,

    vertex_shader: resource.ShaderModuleHandle,
    vertex_entry: []const u8 = "vertexMain",
    fragment_shader: resource.ShaderModuleHandle,
    fragment_entry: []const u8 = "fragmentMain",

    vertex_buffers: []const VertexBufferLayout = &.{},
    /// Must match the formats of the render pass this pipeline is used in.
    color_targets: []const ColorTargetState = &.{},
    depth_stencil: ?DepthStencilState = null,
    primitive: PrimitiveState = .{},
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "the limits are the ones the strictest API guarantees" {
    // If either of these ever changes, it is a contract change and belongs in the design
    // document first. They are asserted here so that a casual edit fails a test.
    try testing.expectEqual(@as(u32, 4), max_bind_groups);
    try testing.expectEqual(@as(u32, 128), max_inline_constant_bytes);
}

test "128 bytes holds what it is meant to hold" {
    // The intended use is a per-draw transform and a couple of scalars. A 4x4 matrix is 64
    // bytes, leaving room for a colour and some indices. Anything approaching the limit
    // wanted a uniform buffer instead.
    try testing.expectEqual(@as(usize, 64), @sizeOf(core.math.Mat4));
    try testing.expect(@sizeOf(core.math.Mat4) * 2 == max_inline_constant_bytes);
}

test "an unused bind group is expressible" {
    // A pipeline wanting only per-frame and per-material data should not have to invent
    // layouts for groups 1 and 3.
    const desc: PipelineLayoutDesc = .{};
    try testing.expectEqual(@as(usize, 0), desc.bind_group_layouts.len);
    try testing.expectEqual(@as(u32, 0), desc.inline_constant_bytes);
}

test "shader stage flags pack and combine" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(ShaderStages));
    try testing.expect(ShaderStages.both.vertex and ShaderStages.both.fragment);
    try testing.expect(!(ShaderStages{}).any());
    try testing.expect((ShaderStages{ .fragment = true }).any());
}

test "the binding resource union is tagged by binding type" {
    // So that a layout entry and the resource bound to it can be compared directly, which
    // is what rule 4 (bind group compatibility) checks.
    const r: BindingResource = .{ .sampled_texture = .none };
    try testing.expectEqual(BindingType.sampled_texture, @as(BindingType, r));
}

test "alpha blending is available as a named state" {
    // Because getting premultiplied and straight alpha the wrong way round is a bug that
    // looks almost right, and every 2D renderer needs this exact state.
    const b = BlendState.alpha_blend;
    try testing.expectEqual(BlendFactor.src_alpha, b.color.src);
    try testing.expectEqual(BlendFactor.one_minus_src_alpha, b.color.dst);
}

test "pipeline handles are distinct types from resource handles" {
    try testing.expect(RenderPipelineHandle != resource.BufferHandle);
    try testing.expect(BindGroupHandle != BindGroupLayoutHandle);
    try testing.expect(PipelineLayoutHandle != RenderPipelineHandle);
}
