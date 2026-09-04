//! Foundry `rhi` — layer L2. The render hardware interface.
//!
//! Depends on `core` and `platform`. **Graphics API symbols appear nowhere outside this
//! module** (I7, enforced by the build graph).
//!
//! `rhi` is **engine-internal**. Games and mods never see it (ADR-0003). There are two
//! rendering boundaries and conflating them is the most likely way to get this wrong:
//! the *Renderer API* (`render2d`, later `render3d`) is what games use, and the RHI is
//! what the renderer is built on. A consequence worth knowing: since the RHI is not
//! public, no mod can issue draw calls directly — mod rendering goes through the renderer
//! and mod-authored shaders through the material system.
//!
//! Every decision here is taken from the **strictest** of Metal, Vulkan and D3D12 rather
//! than from the one implemented first, because an abstraction validated against a single
//! API is not validated and Metal is the most forgiving of the three.
//!
//! Design: `docs/design/rhi.md`

const std = @import("std");
const build_options = @import("build_options");

pub const command = @import("command.zig");
pub const format = @import("format.zig");
pub const interface = @import("interface.zig");
pub const pipeline = @import("pipeline.zig");
pub const resource = @import("resource.zig");

/// The graphics backends Foundry can be built against.
///
/// A backend is an engine port, chosen when the build graph is constructed. Metal joins
/// this list at M1 (ADR-0003); Vulkan and D3D12 are unscheduled and start when there is a
/// reason, not when the roadmap reaches them.
pub const Backend = enum {
    /// Draws nothing, validates everything. See `backends/null.zig`.
    null,
    /// Metal, via the Objective-C shim (ADR-0012). macOS only.
    metal,
};

pub const backend: Backend = std.meta.stringToEnum(Backend, build_options.rhi_backend) orelse
    @compileError("unknown rhi backend '" ++ build_options.rhi_backend ++ "'");

/// The validation backend, reachable by name as well as by selection.
///
/// Exposed because it is what makes rendering-adjacent code testable headlessly, and
/// because its `Rule` enum is how a test asserts *which* contract a change broke.
pub const null_backend = @import("backends/null.zig");

/// Imported inside the switch rather than at the top level, so that a null build never
/// analyses it. The Metal backend `@cImport`s the shim header, which is only on the include
/// path when the build graph selected Metal.
const selected = switch (backend) {
    .null => null_backend,
    .metal => @import("backends/metal/backend.zig"),
};

comptime {
    interface.check(selected, @tagName(backend));
    // The validation backend must satisfy the interface too, always. It is the reference
    // implementation, and an interface change that only suits the graphics API of the day
    // fails here rather than at M1.
    interface.check(null_backend, "null");
}

pub const Device = selected.Device;
pub const CommandBuffer = selected.CommandBuffer;
pub const RenderPass = selected.RenderPass;

// The names reached for most often.
pub const BufferHandle = resource.BufferHandle;
pub const TextureHandle = resource.TextureHandle;
pub const SamplerHandle = resource.SamplerHandle;
pub const ShaderModuleHandle = resource.ShaderModuleHandle;
pub const BindGroupHandle = pipeline.BindGroupHandle;
pub const BindGroupLayoutHandle = pipeline.BindGroupLayoutHandle;
pub const PipelineLayoutHandle = pipeline.PipelineLayoutHandle;
pub const RenderPipelineHandle = pipeline.RenderPipelineHandle;

pub const Extent2D = resource.Extent2D;
pub const MemoryIntent = resource.MemoryIntent;
pub const ResourceState = resource.ResourceState;
pub const TextureFormat = format.TextureFormat;
pub const VertexFormat = format.VertexFormat;
pub const IndexFormat = format.IndexFormat;
pub const Capabilities = command.Capabilities;
pub const ClipSpace = command.ClipSpace;
pub const clip_space = command.clip_space;
pub const FrameContext = command.FrameContext;
pub const RenderPassDesc = command.RenderPassDesc;

pub const DeviceDesc = interface.DeviceDesc;
pub const InitError = interface.InitError;
pub const ResourceError = interface.ResourceError;
pub const MapError = interface.MapError;
pub const FrameError = interface.FrameError;
pub const CommandError = interface.CommandError;

pub const max_bind_groups = pipeline.max_bind_groups;
pub const max_inline_constant_bytes = pipeline.max_inline_constant_bytes;

test {
    _ = command;
    _ = format;
    _ = interface;
    _ = pipeline;
    _ = resource;
    // Always tested, whichever backend is selected — a file imported only for its types
    // contributes no tests.
    _ = null_backend;
    // And the selected one, which for Metal means the tests that need a real device. Not a
    // duplicate when the selection *is* null: Zig collects tests per file.
    _ = selected;
}
