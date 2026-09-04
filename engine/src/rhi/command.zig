//! Render passes, barriers and draws — the things recorded into a command buffer.
//!
//! The recording structure follows **Metal's** shape, which is the one place among the
//! three APIs where Metal is the *strictest*: you cannot record a draw outside a
//! `MTLRenderCommandEncoder` and you cannot have two open at once. Vulkan and D3D12 both
//! permit sloppier structures, so taking Metal's model here costs them nothing and buys a
//! structure that is trivially valid everywhere.
//!
//! Design: `docs/design/rhi.md` §6, §8.

const std = @import("std");
const format = @import("format.zig");
const resource = @import("resource.zig");

/// What to do with an attachment's existing contents when a pass begins.
pub const LoadAction = union(enum) {
    /// Preserve what is there. The most expensive option on a tiler, because it must read
    /// the whole attachment back into tile memory.
    load,
    clear: ClearValue,
    /// The contents are not needed. Free everywhere, and on a tiler it avoids the read.
    discard,
};

pub const ClearValue = union(enum) {
    color: [4]f32,
    depth_stencil: struct { depth: f32 = 1.0, stencil: u32 = 0 },
};

/// What to do with an attachment's contents when a pass ends.
///
/// **`discard` is not a micro-optimisation on a tiler.** On Apple Silicon, and on every
/// mobile GPU, discarding a depth buffer nothing will read saves the entire cost of
/// writing it back to memory. It is free to express and expensive to retrofit, so it is in
/// the interface from the first pass.
///
/// `resolve`, for MSAA, does not exist yet. This enum is shaped to gain it without
/// disturbing anything that already uses it.
pub const StoreAction = enum { store, discard };

/// One colour attachment of a render pass.
///
/// `initial_state` and `final_state` are what make resource transitions explicit without
/// scattering barriers through the draw loop. The pass declares the state the attachment
/// arrives in and the state it leaves in; the Metal backend discards both, and the
/// validation backend checks them against what it has tracked.
pub const ColorAttachment = struct {
    texture: resource.TextureHandle,
    load: LoadAction = .{ .clear = .{ .color = .{ 0, 0, 0, 1 } } },
    store: StoreAction = .store,
    initial_state: resource.ResourceState = .undefined,
    final_state: resource.ResourceState = .render_target,
};

pub const DepthAttachment = struct {
    texture: resource.TextureHandle,
    load: LoadAction = .{ .clear = .{ .depth_stencil = .{} } },
    store: StoreAction = .discard,
    initial_state: resource.ResourceState = .undefined,
    final_state: resource.ResourceState = .depth_stencil,
};

pub const RenderPassDesc = struct {
    label: []const u8 = "",
    color: []const ColorAttachment = &.{},
    depth: ?DepthAttachment = null,
};

/// A state transition for a texture, recorded between passes.
///
/// The usual case is a texture a pass rendered into that the next pass samples. Barriers
/// are declared at pass boundaries and never per draw: per-draw is the shape that makes
/// Vulkan slow, because each barrier breaks GPU overlap, and batching them at boundaries
/// is what every real renderer converges on anyway.
pub const TextureBarrier = struct {
    texture: resource.TextureHandle,
    from: resource.ResourceState,
    to: resource.ResourceState,
};

pub const BufferBarrier = struct {
    buffer: resource.BufferHandle,
    from: resource.ResourceState,
    to: resource.ResourceState,
};

/// The clip space every backend must present to a shader.
///
/// This is a **shader-visible contract**, in the same sense as the binding indices in
/// `docs/design/rhi.md` §9: a vertex shader's output is only meaningful relative to a
/// convention, and a backend that quietly used a different one would not fail loudly — it
/// would draw the world upside down, which reads as a bug in the game.
///
/// Metal and D3D12 present this natively. Vulkan's clip space has +Y down and corrects it
/// with a negative-height viewport, which that API provides for the purpose.
pub const ClipSpace = struct {
    /// Which way +Y points in normalised device coordinates.
    y_axis: enum { up, down },
    /// The range `z` is mapped into. `[0, 1]` is what Metal, Vulkan and D3D12 all use;
    /// OpenGL's `[-1, 1]` is the outlier and is not a target.
    depth_range: enum { zero_to_one, minus_one_to_one },
};

/// Exposed as a value rather than left implicit so the renderer reads the convention
/// instead of hardcoding it. Every backend conforms today, so this costs nothing — and if
/// one ever genuinely cannot, the change is this value plus a sign in one matrix rather
/// than an archaeology exercise across every shader and camera in the engine.
pub const clip_space: ClipSpace = .{ .y_axis = .up, .depth_range = .zero_to_one };

/// In pixels, with the origin at the **top-left** and `y` increasing downward. This does
/// not contradict `clip_space.y_axis` being `up`: they are different spaces, and the
/// projection matrix is what bridges them.
pub const Viewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub const ScissorRect = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
};

pub const Draw = struct {
    vertex_count: u32,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
};

pub const DrawIndexed = struct {
    index_count: u32,
    instance_count: u32 = 1,
    first_index: u32 = 0,
    base_vertex: i32 = 0,
    first_instance: u32 = 0,
};

pub const BufferCopy = struct {
    src: resource.BufferHandle,
    src_offset: u64 = 0,
    dst: resource.BufferHandle,
    dst_offset: u64 = 0,
    size: u64,
};

/// The staging upload path. `device_local` textures cannot be written directly, so getting
/// pixels into one means filling an `upload` buffer and recording this.
pub const BufferToTextureCopy = struct {
    src: resource.BufferHandle,
    src_offset: u64 = 0,
    /// Zero means tightly packed: `width * bytesPerTexel`.
    src_bytes_per_row: u32 = 0,
    dst: resource.TextureHandle,
    dst_mip_level: u32 = 0,
    size: resource.Extent2D,
};

/// What `beginFrame` hands back.
pub const FrameContext = struct {
    /// This frame's swapchain image, already in `undefined` state and expecting to end in
    /// `present`.
    surface_texture: resource.TextureHandle,
    /// Which slot of the frame ring this frame occupies. Anything written per-frame —
    /// upload buffers, transient bind groups — is indexed by this, and writing to it is
    /// safe precisely because `beginFrame` waited for the previous use of the slot.
    slot: u32,
    /// Monotonically increasing from 1.
    index: u64,
};

/// What a backend can actually do.
///
/// Foundry targets the guaranteed minimums; capabilities exist so a backend can report
/// something *better*, never so a caller can discover something worse than it designed
/// for. In particular `unified_memory` is not a licence to skip staging — it is there so a
/// backend can take a shortcut internally, and so profiling can explain a difference
/// between two machines.
pub const Capabilities = struct {
    max_texture_dimension: u32,
    max_bind_groups: u32,
    max_inline_constant_bytes: u32,
    max_vertex_buffers: u32,
    unified_memory: bool,
    /// Whether `createShaderModuleFromSource` works, which is what shader hot reload and
    /// eventually mod-authored shaders need (ADR-0015).
    runtime_shader_compilation: bool,
    /// The swapchain's pixel format, which a pipeline drawing to it must match.
    surface_format: format.TextureFormat,
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "a default colour attachment clears to opaque black and stores" {
    const a: ColorAttachment = .{ .texture = .none };
    try testing.expect(a.load == .clear);
    try testing.expectEqual(StoreAction.store, a.store);
    try testing.expectEqual(resource.ResourceState.undefined, a.initial_state);
    try testing.expectEqual(resource.ResourceState.render_target, a.final_state);
}

test "a default depth attachment discards, because almost nothing reads it back" {
    // The tiler-friendly default. Anything that genuinely needs the depth buffer after the
    // pass has to say so, which is the right way round.
    const d: DepthAttachment = .{ .texture = .none };
    try testing.expectEqual(StoreAction.discard, d.store);
    try testing.expect(d.load == .clear);
    try testing.expect(d.load.clear == .depth_stencil);
    try testing.expectEqual(@as(f32, 1.0), d.load.clear.depth_stencil.depth);
}

test "load actions distinguish clear from discard from load" {
    // Three genuinely different costs on a tiler, and the reason this is not a bool.
    const l: LoadAction = .load;
    const c: LoadAction = .{ .clear = .{ .color = .{ 1, 0, 0, 1 } } };
    const d: LoadAction = .discard;
    try testing.expect(l == .load);
    try testing.expect(c == .clear);
    try testing.expect(d == .discard);
}

test "a draw defaults to one instance" {
    const d: Draw = .{ .vertex_count = 6 };
    try testing.expectEqual(@as(u32, 1), d.instance_count);
    try testing.expectEqual(@as(u32, 0), d.first_vertex);
}

test "tightly packed is expressible as zero rather than as a computation" {
    // So the common case does not require the caller to recompute what the backend
    // already knows from the format.
    const c: BufferToTextureCopy = .{ .src = .none, .dst = .none, .size = .{ .width = 8, .height = 8 } };
    try testing.expectEqual(@as(u32, 0), c.src_bytes_per_row);
}

test "clip space is pinned, because changing it silently flips the world" {
    // Not a tautology: this is the contract in `docs/design/rhi.md` §9, and a shader,
    // every projection matrix and every backend depend on it. Changing it should require
    // deleting a test that says why, not editing a constant in passing.
    try testing.expectEqual(ClipSpace{ .y_axis = .up, .depth_range = .zero_to_one }, clip_space);
}
