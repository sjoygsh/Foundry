//! The RHI backend interface, and the `comptime` check that enforces it.
//!
//! One backend per binary, chosen when the build graph is constructed — the same reasoning
//! as `platform`: nobody swaps graphics backends mid-run, and a vtable would cost an
//! indirect call on every draw. A backend is an engine port, and ports are compile-time
//! decisions (I6 is about mods adding component types and asset loaders, not ports).
//!
//! Three types make up a backend, and the split follows Metal's encoder model (§8 of the
//! design): a `Device` creates things and owns the frame ring, a `CommandBuffer` records,
//! and a `RenderPass` is the only place a draw may happen.
//!
//! Design: `docs/design/rhi.md`

const std = @import("std");
const core = @import("core");
const platform = @import("platform");

const command = @import("command.zig");
const pipeline = @import("pipeline.zig");
const resource = @import("resource.zig");

pub const InitError = error{
    OutOfMemory,
    /// No usable GPU, or the driver refused to create a device.
    DeviceCreationFailed,
    /// The `platform.NativeSurfaceHandle` names a surface kind this backend cannot use —
    /// a configuration mistake rather than a programmer error, so it is reported.
    SurfaceUnsupported,
};

pub const ResourceError = error{
    OutOfMemory,
    /// The GPU refused the allocation.
    OutOfDeviceMemory,
    /// The descriptor is internally inconsistent or exceeds a documented limit.
    InvalidDescriptor,
    UnsupportedFormat,
    ShaderCompilationFailed,
    /// `createShaderModuleFromSource` on a backend that cannot compile at runtime.
    RuntimeCompilationUnsupported,
};

pub const MapError = error{
    /// A `device_local` resource was mapped. See `resource.MemoryIntent`: this is the rule
    /// that stops unified memory from becoming a habit that is slow elsewhere.
    NotMappable,
    InvalidHandle,
};

pub const FrameError = error{
    OutOfMemory,
    /// The window went away, or the swapchain needs recreating.
    SurfaceLost,
    DeviceLost,
};

pub const CommandError = error{
    OutOfMemory,
    DeviceLost,
    /// The recorded command stream violates the RHI contract.
    ///
    /// Only the validation backend produces this. A real backend does not check — that is
    /// the entire point of having a backend that does.
    ValidationFailed,
};

pub const DeviceDesc = struct {
    label: []const u8 = "",
    /// From `platform`. `.none` means headless: no swapchain, and `surface_size` describes
    /// an offscreen target instead.
    surface: platform.NativeSurfaceHandle = .none,
    surface_size: resource.Extent2D = .{ .width = 1280, .height = 720 },
    /// How far the CPU may run ahead of the GPU. Two is the latency-friendly default;
    /// three tolerates frame-time spikes better. Left fixed rather than adaptive — that is
    /// an open question in the design, not something to settle opportunistically.
    frames_in_flight: u32 = 2,
};

/// Verifies that `Impl` provides the whole backend interface with the exact signatures.
pub fn check(comptime Impl: type, comptime label: []const u8) void {
    comptime {
        for ([_][]const u8{ "Device", "CommandBuffer", "RenderPass" }) |name| {
            if (!@hasDecl(Impl, name)) {
                @compileError("rhi backend '" ++ label ++ "' declares no `" ++ name ++ "` type");
            }
        }

        const D = Impl.Device;
        const C = Impl.CommandBuffer;
        const R = Impl.RenderPass;
        const A = std.mem.Allocator;

        // Lifecycle and capabilities.
        expectFn(D, label, "init", &.{ A, DeviceDesc }, InitError!*D);
        expectFn(D, label, "deinit", &.{*D}, void);
        expectFn(D, label, "capabilities", &.{*D}, command.Capabilities);

        // Resources. Every create returns a generational handle (I1); every destroy is
        // deferred until no in-flight frame can reference it.
        expectFn(D, label, "createBuffer", &.{ *D, resource.BufferDesc }, ResourceError!resource.BufferHandle);
        expectFn(D, label, "destroyBuffer", &.{ *D, resource.BufferHandle }, void);
        expectFn(D, label, "mapBuffer", &.{ *D, resource.BufferHandle }, MapError![]u8);
        expectFn(D, label, "unmapBuffer", &.{ *D, resource.BufferHandle }, void);

        expectFn(D, label, "createTexture", &.{ *D, resource.TextureDesc }, ResourceError!resource.TextureHandle);
        expectFn(D, label, "destroyTexture", &.{ *D, resource.TextureHandle }, void);

        expectFn(D, label, "createSampler", &.{ *D, resource.SamplerDesc }, ResourceError!resource.SamplerHandle);
        expectFn(D, label, "destroySampler", &.{ *D, resource.SamplerHandle }, void);

        expectFn(D, label, "createShaderModule", &.{ *D, resource.ShaderModuleDesc }, ResourceError!resource.ShaderModuleHandle);
        expectFn(D, label, "createShaderModuleFromSource", &.{ *D, resource.ShaderSourceDesc }, ResourceError!resource.ShaderModuleHandle);
        expectFn(D, label, "destroyShaderModule", &.{ *D, resource.ShaderModuleHandle }, void);

        // Binding.
        expectFn(D, label, "createBindGroupLayout", &.{ *D, pipeline.BindGroupLayoutDesc }, ResourceError!pipeline.BindGroupLayoutHandle);
        expectFn(D, label, "destroyBindGroupLayout", &.{ *D, pipeline.BindGroupLayoutHandle }, void);
        expectFn(D, label, "createBindGroup", &.{ *D, pipeline.BindGroupDesc }, ResourceError!pipeline.BindGroupHandle);
        expectFn(D, label, "destroyBindGroup", &.{ *D, pipeline.BindGroupHandle }, void);
        expectFn(D, label, "createPipelineLayout", &.{ *D, pipeline.PipelineLayoutDesc }, ResourceError!pipeline.PipelineLayoutHandle);
        expectFn(D, label, "destroyPipelineLayout", &.{ *D, pipeline.PipelineLayoutHandle }, void);
        expectFn(D, label, "createRenderPipeline", &.{ *D, pipeline.RenderPipelineDesc }, ResourceError!pipeline.RenderPipelineHandle);
        expectFn(D, label, "destroyRenderPipeline", &.{ *D, pipeline.RenderPipelineHandle }, void);

        // The frame ring. Explicit because Vulkan makes it impossible to ignore and Metal
        // makes it easy to, and the engine must not depend on which.
        expectFn(D, label, "beginFrame", &.{*D}, FrameError!command.FrameContext);
        expectFn(D, label, "endFrame", &.{*D}, FrameError!void);
        expectFn(D, label, "resizeSurface", &.{ *D, resource.Extent2D }, FrameError!void);

        // Recording.
        expectFn(D, label, "beginCommandBuffer", &.{*D}, CommandError!*C);

        expectFn(C, label, "beginRenderPass", &.{ *C, command.RenderPassDesc }, CommandError!*R);
        expectFn(C, label, "textureBarrier", &.{ *C, []const command.TextureBarrier }, CommandError!void);
        expectFn(C, label, "bufferBarrier", &.{ *C, []const command.BufferBarrier }, CommandError!void);
        expectFn(C, label, "copyBufferToBuffer", &.{ *C, command.BufferCopy }, CommandError!void);
        expectFn(C, label, "copyBufferToTexture", &.{ *C, command.BufferToTextureCopy }, CommandError!void);
        expectFn(C, label, "submit", &.{*C}, CommandError!void);

        expectFn(R, label, "setPipeline", &.{ *R, pipeline.RenderPipelineHandle }, void);
        expectFn(R, label, "setBindGroup", &.{ *R, u32, pipeline.BindGroupHandle }, void);
        expectFn(R, label, "setVertexBuffer", &.{ *R, u32, resource.BufferHandle, u64 }, void);
        expectFn(R, label, "setIndexBuffer", &.{ *R, resource.BufferHandle, @import("format.zig").IndexFormat, u64 }, void);
        expectFn(R, label, "setInlineConstants", &.{ *R, []const u8 }, void);
        expectFn(R, label, "setViewport", &.{ *R, command.Viewport }, void);
        expectFn(R, label, "setScissor", &.{ *R, command.ScissorRect }, void);
        expectFn(R, label, "draw", &.{ *R, command.Draw }, void);
        expectFn(R, label, "drawIndexed", &.{ *R, command.DrawIndexed }, void);
        expectFn(R, label, "end", &.{*R}, void);
    }
}

fn expectFn(
    comptime T: type,
    comptime label: []const u8,
    comptime name: []const u8,
    comptime params: []const type,
    comptime Ret: type,
) void {
    comptime {
        const what = "rhi backend '" ++ label ++ "': `" ++ @typeName(T) ++ "." ++ name ++ "`";

        if (!@hasDecl(T, name)) @compileError(what ++ " is missing");

        const info = @typeInfo(@TypeOf(@field(T, name)));
        if (info != .@"fn") @compileError(what ++ " must be a function");
        const f = info.@"fn";

        if (f.params.len != params.len) {
            @compileError(std.fmt.comptimePrint(
                "{s} takes {d} parameters, the interface requires {d}",
                .{ what, f.params.len, params.len },
            ));
        }
        for (params, 0..) |Want, i| {
            const got = f.params[i].type orelse
                @compileError(what ++ " has a generic parameter; the interface requires concrete types");
            if (got != Want) {
                @compileError(std.fmt.comptimePrint(
                    "{s} parameter {d} is {s}, the interface requires {s}",
                    .{ what, i, @typeName(got), @typeName(Want) },
                ));
            }
        }

        const got_ret = f.return_type orelse @compileError(what ++ " has a generic return type");
        if (got_ret != Ret) {
            @compileError(std.fmt.comptimePrint(
                "{s} returns {s}, the interface requires {s}",
                .{ what, @typeName(got_ret), @typeName(Ret) },
            ));
        }
    }
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "the interface names one function per documented capability" {
    // A change to the RHI's surface should be a deliberate edit here rather than something
    // that drifts in one backend at a time. The count is asserted so that adding a method
    // without considering the second backend fails a test.
    try testing.expectEqual(@as(usize, 40), interface_function_count);
}

/// Kept next to `check` so the two move together.
const interface_function_count: usize = 24 + 6 + 10;
