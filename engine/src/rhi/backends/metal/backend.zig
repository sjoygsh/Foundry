//! The Metal backend (ADR-0003, ADR-0012).
//!
//! Everything above this file is API-neutral; everything below it is Metal. The Objective-C
//! shim next door is a pure mirror of Metal's API and holds no decisions, so this is where
//! all of them live: how a `TextureFormat` becomes an `MTLPixelFormat`, how an abstract bind
//! group becomes an argument-table index, when a frame waits, what a resize means.
//!
//! **This backend does not validate.** That is deliberate and is the whole architecture of
//! ADR-0003: the null backend enforces the ten rules of `docs/design/rhi.md` §11, and this
//! one trusts its caller. A real backend that also checked would be slower for no benefit
//! and, worse, would let the two implementations disagree about what the contract is.
//! Anything this file *would* have to check is a rule the null backend should be catching.
//!
//! Two things here are worth understanding before changing anything:
//!
//! * **The frame ring waits on command buffers, not on a semaphore.** Each slot keeps the
//!   command buffer that last used it; `beginFrame` waits for that one to complete before
//!   reusing the slot. Metal orders a queue, so waiting on a frame's last command buffer
//!   waits for all of it. This needs no atomics, no completion callbacks and no
//!   synchronisation primitive — which matters, since Zig 0.16 moved those under `std.Io`
//!   and `rhi` has no `Io` to hand.
//!
//! * **The surface texture handle is stable across frames**, and only the `MTLTexture`
//!   behind it changes. The null backend does the same, so code written against one behaves
//!   identically on the other — which is exactly the property that makes the null backend a
//!   useful check on this one.
//!
//! **On logging levels.** `err` is reserved for the engine failing: no Metal device, no
//! command queue. Everything a *caller* got wrong — an unusable surface kind, a shader that
//! will not compile, a pipeline Metal rejects — is reported at `warn` alongside the error
//! value, because it is invalid input rather than an engine fault. This is `CLAUDE.md` §7's
//! assert-versus-validate distinction applied to diagnostics: a shader failing to compile is
//! the *expected* case of the hot-reload path (ADR-0015), not a malfunction. The diagnostic
//! is still logged, because the compiler's own message is the useful part and no error enum
//! can carry it.
//!
//! Design: `docs/design/rhi.md`, §9 in particular for the binding index convention.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");

const command = @import("../../command.zig");
const format = @import("../../format.zig");
const interface = @import("../../interface.zig");
const pipeline = @import("../../pipeline.zig");
const resource = @import("../../resource.zig");

const c = @cImport({
    @cInclude("metal_shim.h");
});

const Allocator = std.mem.Allocator;
const assert = core.assert;
const log = core.log.scoped(.rhi);

/// Matches the null backend's, so that a `frames_in_flight` legal on one is legal on both.
const max_frames_in_flight = 4;

/// Metal's argument tables, spent as `docs/design/rhi.md` §9 describes. Vertex buffers take
/// the bottom of the buffer table, inline constants the slot immediately above them, and
/// bind group buffers everything after that.
const inline_constant_buffer_index: u32 = pipeline.max_vertex_buffers;
const first_bind_group_buffer_index: u32 = pipeline.max_vertex_buffers + 1;

/// Labels are for Xcode's frame capture, which is one of the reasons Metal is the first
/// backend. Truncating a long one is better than allocating per call.
const label_max = 127;

fn cLabel(buf: *[label_max + 1]u8, label: []const u8) [*:0]const u8 {
    const n = @min(label.len, label_max);
    @memcpy(buf[0..n], label[0..n]);
    buf[n] = 0;
    return @ptrCast(buf);
}

// -- translation ---------------------------------------------------------------------
//
// Foundry's enums to Metal's. Exhaustive switches throughout, with no `else` branch: adding
// a format or a blend factor should fail to compile here rather than silently fall through
// to a default that renders something almost right.

fn pixelFormat(f: format.TextureFormat) u32 {
    return switch (f) {
        .r8_unorm => c.FD_MTL_PIXEL_FORMAT_R8_UNORM,
        .rg8_unorm => c.FD_MTL_PIXEL_FORMAT_RG8_UNORM,
        .rgba8_unorm => c.FD_MTL_PIXEL_FORMAT_RGBA8_UNORM,
        .rgba8_unorm_srgb => c.FD_MTL_PIXEL_FORMAT_RGBA8_UNORM_SRGB,
        .bgra8_unorm => c.FD_MTL_PIXEL_FORMAT_BGRA8_UNORM,
        .bgra8_unorm_srgb => c.FD_MTL_PIXEL_FORMAT_BGRA8_UNORM_SRGB,
        .r16_float => c.FD_MTL_PIXEL_FORMAT_R16_FLOAT,
        .rgba16_float => c.FD_MTL_PIXEL_FORMAT_RGBA16_FLOAT,
        .r32_float => c.FD_MTL_PIXEL_FORMAT_R32_FLOAT,
        .rgba32_float => c.FD_MTL_PIXEL_FORMAT_RGBA32_FLOAT,
        .depth32_float => c.FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT,
        .depth32_float_stencil8 => c.FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT_STENCIL8,
    };
}

/// The inverse, for reading back what `CAMetalLayer` chose. Null for a format the RHI does
/// not name — reported rather than asserted, since it describes the machine, not the code.
fn textureFormatFromMetal(v: u32) ?format.TextureFormat {
    return switch (v) {
        c.FD_MTL_PIXEL_FORMAT_R8_UNORM => .r8_unorm,
        c.FD_MTL_PIXEL_FORMAT_RG8_UNORM => .rg8_unorm,
        c.FD_MTL_PIXEL_FORMAT_RGBA8_UNORM => .rgba8_unorm,
        c.FD_MTL_PIXEL_FORMAT_RGBA8_UNORM_SRGB => .rgba8_unorm_srgb,
        c.FD_MTL_PIXEL_FORMAT_BGRA8_UNORM => .bgra8_unorm,
        c.FD_MTL_PIXEL_FORMAT_BGRA8_UNORM_SRGB => .bgra8_unorm_srgb,
        c.FD_MTL_PIXEL_FORMAT_R16_FLOAT => .r16_float,
        c.FD_MTL_PIXEL_FORMAT_RGBA16_FLOAT => .rgba16_float,
        c.FD_MTL_PIXEL_FORMAT_R32_FLOAT => .r32_float,
        c.FD_MTL_PIXEL_FORMAT_RGBA32_FLOAT => .rgba32_float,
        c.FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT => .depth32_float,
        c.FD_MTL_PIXEL_FORMAT_DEPTH32_FLOAT_STENCIL8 => .depth32_float_stencil8,
        else => null,
    };
}

fn vertexFormat(f: format.VertexFormat) u32 {
    return switch (f) {
        .float32 => c.FD_MTL_VERTEX_FORMAT_FLOAT,
        .float32x2 => c.FD_MTL_VERTEX_FORMAT_FLOAT2,
        .float32x3 => c.FD_MTL_VERTEX_FORMAT_FLOAT3,
        .float32x4 => c.FD_MTL_VERTEX_FORMAT_FLOAT4,
        .unorm8x4 => c.FD_MTL_VERTEX_FORMAT_UCHAR4_NORMALIZED,
        .uint8x4 => c.FD_MTL_VERTEX_FORMAT_UCHAR4,
        .uint16x2 => c.FD_MTL_VERTEX_FORMAT_USHORT2,
        .uint32 => c.FD_MTL_VERTEX_FORMAT_UINT,
    };
}

fn indexType(f: format.IndexFormat) u32 {
    return switch (f) {
        .uint16 => c.FD_MTL_INDEX_TYPE_UINT16,
        .uint32 => c.FD_MTL_INDEX_TYPE_UINT32,
    };
}

fn loadAction(a: command.LoadAction) u32 {
    return switch (a) {
        .load => c.FD_MTL_LOAD_ACTION_LOAD,
        .clear => c.FD_MTL_LOAD_ACTION_CLEAR,
        .discard => c.FD_MTL_LOAD_ACTION_DONT_CARE,
    };
}

fn storeAction(a: command.StoreAction) u32 {
    return switch (a) {
        .store => c.FD_MTL_STORE_ACTION_STORE,
        .discard => c.FD_MTL_STORE_ACTION_DONT_CARE,
    };
}

fn blendFactor(f: pipeline.BlendFactor) u32 {
    return switch (f) {
        .zero => c.FD_MTL_BLEND_FACTOR_ZERO,
        .one => c.FD_MTL_BLEND_FACTOR_ONE,
        .src_alpha => c.FD_MTL_BLEND_FACTOR_SRC_ALPHA,
        .one_minus_src_alpha => c.FD_MTL_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .dst_alpha => c.FD_MTL_BLEND_FACTOR_DST_ALPHA,
        .one_minus_dst_alpha => c.FD_MTL_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
        .src_color => c.FD_MTL_BLEND_FACTOR_SRC_COLOR,
        .one_minus_src_color => c.FD_MTL_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
    };
}

fn blendOp(o: pipeline.BlendOp) u32 {
    return switch (o) {
        .add => c.FD_MTL_BLEND_OP_ADD,
        .subtract => c.FD_MTL_BLEND_OP_SUBTRACT,
        .reverse_subtract => c.FD_MTL_BLEND_OP_REVERSE_SUBTRACT,
        .min => c.FD_MTL_BLEND_OP_MIN,
        .max => c.FD_MTL_BLEND_OP_MAX,
    };
}

/// Note the bit order: Metal puts red at `1 << 3` and alpha at `1 << 0`, which is the
/// reverse of the obvious guess. Getting it backwards writes the wrong channels.
fn colorWriteMask(m: pipeline.ColorWriteMask) u32 {
    var out: u32 = c.FD_MTL_COLOR_WRITE_MASK_NONE;
    if (m.r) out |= c.FD_MTL_COLOR_WRITE_MASK_RED;
    if (m.g) out |= c.FD_MTL_COLOR_WRITE_MASK_GREEN;
    if (m.b) out |= c.FD_MTL_COLOR_WRITE_MASK_BLUE;
    if (m.a) out |= c.FD_MTL_COLOR_WRITE_MASK_ALPHA;
    return out;
}

fn compareFunction(f: pipeline.CompareFunction) u32 {
    return switch (f) {
        .never => c.FD_MTL_COMPARE_NEVER,
        .less => c.FD_MTL_COMPARE_LESS,
        .equal => c.FD_MTL_COMPARE_EQUAL,
        .less_equal => c.FD_MTL_COMPARE_LESS_EQUAL,
        .greater => c.FD_MTL_COMPARE_GREATER,
        .not_equal => c.FD_MTL_COMPARE_NOT_EQUAL,
        .greater_equal => c.FD_MTL_COMPARE_GREATER_EQUAL,
        .always => c.FD_MTL_COMPARE_ALWAYS,
    };
}

fn cullMode(m: pipeline.CullMode) u32 {
    return switch (m) {
        .none => c.FD_MTL_CULL_MODE_NONE,
        .front => c.FD_MTL_CULL_MODE_FRONT,
        .back => c.FD_MTL_CULL_MODE_BACK,
    };
}

fn winding(f: pipeline.FrontFace) u32 {
    return switch (f) {
        .counter_clockwise => c.FD_MTL_WINDING_COUNTER_CLOCKWISE,
        .clockwise => c.FD_MTL_WINDING_CLOCKWISE,
    };
}

fn primitiveType(t: pipeline.PrimitiveTopology) u32 {
    return switch (t) {
        .triangle_list => c.FD_MTL_PRIMITIVE_TYPE_TRIANGLE,
        .triangle_strip => c.FD_MTL_PRIMITIVE_TYPE_TRIANGLE_STRIP,
        .line_list => c.FD_MTL_PRIMITIVE_TYPE_LINE,
        .point_list => c.FD_MTL_PRIMITIVE_TYPE_POINT,
    };
}

fn stepFunction(m: pipeline.VertexStepMode) u32 {
    return switch (m) {
        .vertex => c.FD_MTL_VERTEX_STEP_PER_VERTEX,
        .instance => c.FD_MTL_VERTEX_STEP_PER_INSTANCE,
    };
}

fn samplerFilter(f: resource.FilterMode) u32 {
    return switch (f) {
        .nearest => c.FD_MTL_SAMPLER_FILTER_NEAREST,
        .linear => c.FD_MTL_SAMPLER_FILTER_LINEAR,
    };
}

fn samplerMipFilter(f: resource.FilterMode) u32 {
    return switch (f) {
        .nearest => c.FD_MTL_SAMPLER_MIP_NEAREST,
        .linear => c.FD_MTL_SAMPLER_MIP_LINEAR,
    };
}

fn samplerAddress(m: resource.AddressMode) u32 {
    return switch (m) {
        .clamp_to_edge => c.FD_MTL_SAMPLER_ADDRESS_CLAMP_TO_EDGE,
        .repeat => c.FD_MTL_SAMPLER_ADDRESS_REPEAT,
        .mirror_repeat => c.FD_MTL_SAMPLER_ADDRESS_MIRROR_REPEAT,
    };
}

/// `MemoryIntent` to `MTLResourceOptions`.
///
/// `device_local` becomes private storage, which on Apple Silicon is *not* the cheapest
/// option — shared would avoid a copy, since the memory is unified. It is private anyway,
/// because `docs/design/rhi.md` §5 is explicit that the RHI must not let unified memory
/// become a habit that costs a fraction of the frame rate on a discrete GPU. Private
/// storage is also what makes `mapBuffer` genuinely impossible here rather than merely
/// forbidden, which is the stronger guarantee.
fn resourceOptions(m: resource.MemoryIntent) u32 {
    return switch (m) {
        .device_local => c.FD_MTL_RESOURCE_STORAGE_MODE_PRIVATE,
        .upload, .readback => c.FD_MTL_RESOURCE_STORAGE_MODE_SHARED,
    };
}

fn storageMode(m: resource.MemoryIntent) u32 {
    return switch (m) {
        .device_local => c.FD_MTL_STORAGE_MODE_PRIVATE,
        .upload, .readback => c.FD_MTL_STORAGE_MODE_SHARED,
    };
}

fn textureUsage(u: resource.TextureUsage) u32 {
    var out: u32 = 0;
    if (u.sampled) out |= c.FD_MTL_TEXTURE_USAGE_SHADER_READ;
    if (u.render_target or u.depth_stencil) out |= c.FD_MTL_TEXTURE_USAGE_RENDER_TARGET;
    // `copy_src` and `copy_dst` need no Metal usage bit: blit is always permitted.
    return out;
}

// -- stored state ---------------------------------------------------------------------

const BufferState = struct {
    mtl: *c.FdMtlBuffer,
    desc: resource.BufferDesc,
};

const TextureState = struct {
    /// Null only for the swapchain texture outside a frame, when there is no drawable.
    mtl: ?*c.FdMtlTexture,
    desc: resource.TextureDesc,
    /// Whether this handle is the stable swapchain handle, whose `mtl` is replaced each
    /// frame and must not be destroyed with the pool.
    is_surface: bool = false,
};

const SamplerState = struct { mtl: *c.FdMtlSampler };

const ShaderState = struct { mtl: *c.FdMtlLibrary };

const BindGroupLayoutState = struct {
    /// **Sorted by `binding`**, not stored in descriptor order. The flattening in §9 walks
    /// this, so sorting once here is what makes two identical layouts produce identical
    /// Metal indices however their descriptors were written.
    entries: []pipeline.BindGroupLayoutEntry,
};

const BindGroupState = struct {
    layout: pipeline.BindGroupLayoutHandle,
    entries: []pipeline.BindGroupEntry,
};

/// One binding, with the argument-table index it was assigned.
const BindingSlot = struct {
    group: u32,
    binding: u32,
    type: pipeline.BindingType,
    visibility: pipeline.ShaderStages,
    /// Index in whichever Metal table `type` names — buffer, texture or sampler.
    index: u32,
};

const PipelineLayoutState = struct {
    bind_group_layouts: []pipeline.BindGroupLayoutHandle,
    inline_constant_bytes: u32,
    /// The flattening, computed once at layout creation rather than per draw.
    slots: []BindingSlot,
};

const RenderPipelineState = struct {
    mtl: *c.FdMtlRenderPipeline,
    depth_state: ?*c.FdMtlDepthState,
    layout: pipeline.PipelineLayoutHandle,
    primitive: pipeline.PrimitiveState,
};

// -- device ----------------------------------------------------------------------------

pub const Device = struct {
    gpa: Allocator,
    desc: interface.DeviceDesc,

    dev: *c.FdMtlDevice,
    queue: *c.FdMtlQueue,
    /// The `CAMetalLayer`, or null when headless. Opaque here too: this file knows it is a
    /// Metal layer only because `platform` tagged it as one.
    layer: ?*anyopaque,

    surface_format: format.TextureFormat,
    surface_size: resource.Extent2D,
    surface_texture: resource.TextureHandle = .none,
    /// The headless render target, when there is no layer to get drawables from.
    offscreen: ?*c.FdMtlTexture = null,

    drawable: ?*c.FdMtlDrawable = null,

    frame_index: u64 = 0,
    frame_slot: u32 = 0,
    /// The command buffer that last used each slot. `beginFrame` waits on it before reusing
    /// the slot — this is the whole frame-ring mechanism.
    in_flight: [max_frames_in_flight]?*c.FdMtlCommandBuffer = @splat(null),

    buffers: core.HandlePool(resource.Buffer, BufferState) = .empty,
    textures: core.HandlePool(resource.Texture, TextureState) = .empty,
    samplers: core.HandlePool(resource.Sampler, SamplerState) = .empty,
    shaders: core.HandlePool(resource.ShaderModule, ShaderState) = .empty,
    bind_group_layouts: core.HandlePool(pipeline.BindGroupLayout, BindGroupLayoutState) = .empty,
    bind_groups: core.HandlePool(pipeline.BindGroup, BindGroupState) = .empty,
    pipeline_layouts: core.HandlePool(pipeline.PipelineLayout, PipelineLayoutState) = .empty,
    pipelines: core.HandlePool(pipeline.RenderPipeline, RenderPipelineState) = .empty,

    command_buffers: std.ArrayList(*CommandBuffer) = .empty,
    free_command_buffers: std.ArrayList(*CommandBuffer) = .empty,
    render_passes: std.ArrayList(*RenderPass) = .empty,
    free_render_passes: std.ArrayList(*RenderPass) = .empty,

    pub fn init(gpa: Allocator, desc: interface.DeviceDesc) interface.InitError!*Device {
        assert.debugOnly(
            desc.frames_in_flight >= 1 and desc.frames_in_flight <= max_frames_in_flight,
            "frames_in_flight must be 1..{d}, got {d}",
            .{ max_frames_in_flight, desc.frames_in_flight },
        );

        // A surface kind this backend cannot use is a configuration mistake — the wrong
        // platform backend, or a window created without asking for a Metal surface — so it
        // is reported rather than asserted (ADR-0002, ADR-0007).
        const layer: ?*anyopaque = switch (desc.surface.kind) {
            .none => null,
            .metal_layer => desc.surface.ptr,
            .win32_hwnd, .xlib_window, .wayland_surface => {
                log.warn("metal backend cannot use a '{t}' surface", .{desc.surface.kind});
                return error.SurfaceUnsupported;
            },
        };

        const dev = c.fd_mtl_device_create() orelse {
            log.err("no Metal device available on this machine", .{});
            return error.DeviceCreationFailed;
        };
        errdefer c.fd_mtl_device_destroy(dev);

        const queue = c.fd_mtl_queue_create(dev, "foundry") orelse {
            log.err("Metal command queue creation failed", .{});
            return error.DeviceCreationFailed;
        };
        errdefer c.fd_mtl_queue_destroy(queue);

        const self = try gpa.create(Device);
        errdefer gpa.destroy(self);

        // `bgra8_unorm_srgb` is what `CAMetalLayer` uses by default and what the RHI names
        // first among equals; configuring the layer explicitly means the format is Foundry's
        // decision rather than whatever the window system happened to pick.
        const wanted: format.TextureFormat = .bgra8_unorm_srgb;

        self.* = .{
            .gpa = gpa,
            .desc = desc,
            .dev = dev,
            .queue = queue,
            .layer = layer,
            .surface_format = wanted,
            .surface_size = desc.surface_size,
        };

        if (layer) |l| {
            c.fd_mtl_layer_configure(
                l,
                dev,
                pixelFormat(wanted),
                desc.surface_size.width,
                desc.surface_size.height,
                true,
            );
            // Read back rather than assume: the layer is free to have refused.
            self.surface_format = textureFormatFromMetal(c.fd_mtl_layer_pixel_format(l)) orelse wanted;
        }

        // The stable swapchain handle (see the file comment). Headless, it is backed by a
        // real offscreen texture; with a layer, its `mtl` is swapped in each frame.
        self.surface_texture = self.textures.add(gpa, .{
            .mtl = null,
            .desc = .{
                .label = "surface",
                .size = desc.surface_size,
                .format = self.surface_format,
                .usage = .{ .render_target = true, .copy_src = true },
            },
            .is_surface = true,
        }) catch {
            gpa.destroy(self);
            c.fd_mtl_queue_destroy(queue);
            c.fd_mtl_device_destroy(dev);
            return error.OutOfMemory;
        };

        if (layer == null) {
            self.offscreen = self.createOffscreen(desc.surface_size) orelse {
                self.deinit();
                return error.DeviceCreationFailed;
            };
            if (self.textures.get(self.surface_texture)) |t| t.mtl = self.offscreen;
        }

        var name_buf: [128]u8 = undefined;
        const name_len = c.fd_mtl_device_name(dev, &name_buf, name_buf.len);
        const name = if (name_len > 0) name_buf[0..@intCast(name_len)] else "unknown";
        log.info("rhi backend: metal on '{s}', {d} frames in flight, surface {t}", .{
            name,
            desc.frames_in_flight,
            self.surface_format,
        });

        return self;
    }

    fn createOffscreen(self: *Device, size: resource.Extent2D) ?*c.FdMtlTexture {
        const d: c.FdMtlTextureDesc = .{
            .pixel_format = pixelFormat(self.surface_format),
            .width = @max(size.width, 1),
            .height = @max(size.height, 1),
            .mip_levels = 1,
            .usage = c.FD_MTL_TEXTURE_USAGE_RENDER_TARGET | c.FD_MTL_TEXTURE_USAGE_SHADER_READ,
            .storage_mode = c.FD_MTL_STORAGE_MODE_PRIVATE,
        };
        return c.fd_mtl_texture_create(self.dev, &d, "surface (offscreen)");
    }

    /// Waits until the GPU has finished everything submitted so far.
    ///
    /// The frame ring's own mechanism answers this exactly: wait on every slot's last
    /// command buffer. Teardown needs it, and so does anything that must destroy a
    /// resource without knowing whether a frame still references it.
    pub fn waitIdle(self: *Device) void {
        for (&self.in_flight) |slot| {
            if (slot) |cb| c.fd_mtl_command_buffer_wait_until_completed(cb);
        }
    }

    pub fn deinit(self: *Device) void {
        const gpa = self.gpa;

        // Nothing may be released while the GPU might still read it.
        self.waitIdle();
        for (&self.in_flight) |*slot| {
            if (slot.*) |cb| {
                c.fd_mtl_command_buffer_destroy(cb);
                slot.* = null;
            }
        }
        self.releaseDrawable();

        for (self.command_buffers.items) |cb| gpa.destroy(cb);
        for (self.render_passes.items) |rp| gpa.destroy(rp);
        self.command_buffers.deinit(gpa);
        self.free_command_buffers.deinit(gpa);
        self.render_passes.deinit(gpa);
        self.free_render_passes.deinit(gpa);

        var buffers = self.buffers.iterator();
        while (buffers.next()) |e| c.fd_mtl_buffer_destroy(e.value.mtl);
        var textures = self.textures.iterator();
        while (textures.next()) |e| {
            // The swapchain handle's texture is either the drawable's, released with the
            // drawable, or the offscreen one, released just below.
            if (!e.value.is_surface) {
                if (e.value.mtl) |t| c.fd_mtl_texture_destroy(t);
            }
        }
        if (self.offscreen) |t| c.fd_mtl_texture_destroy(t);
        var samplers = self.samplers.iterator();
        while (samplers.next()) |e| c.fd_mtl_sampler_destroy(e.value.mtl);
        var shaders = self.shaders.iterator();
        while (shaders.next()) |e| c.fd_mtl_library_destroy(e.value.mtl);
        var pipes = self.pipelines.iterator();
        while (pipes.next()) |e| {
            c.fd_mtl_render_pipeline_destroy(e.value.mtl);
            if (e.value.depth_state) |d| c.fd_mtl_depth_state_destroy(d);
        }

        var bgls = self.bind_group_layouts.iterator();
        while (bgls.next()) |e| gpa.free(e.value.entries);
        var bgs = self.bind_groups.iterator();
        while (bgs.next()) |e| gpa.free(e.value.entries);
        var pls = self.pipeline_layouts.iterator();
        while (pls.next()) |e| {
            gpa.free(e.value.bind_group_layouts);
            gpa.free(e.value.slots);
        }

        self.buffers.deinit(gpa);
        self.textures.deinit(gpa);
        self.samplers.deinit(gpa);
        self.shaders.deinit(gpa);
        self.bind_group_layouts.deinit(gpa);
        self.bind_groups.deinit(gpa);
        self.pipeline_layouts.deinit(gpa);
        self.pipelines.deinit(gpa);

        c.fd_mtl_queue_destroy(self.queue);
        c.fd_mtl_device_destroy(self.dev);
        gpa.destroy(self);
    }

    pub fn capabilities(self: *Device) command.Capabilities {
        return .{
            .max_texture_dimension = c.fd_mtl_device_max_texture_dimension(self.dev),
            .max_bind_groups = pipeline.max_bind_groups,
            .max_inline_constant_bytes = pipeline.max_inline_constant_bytes,
            .max_vertex_buffers = pipeline.max_vertex_buffers,
            // Reported honestly, and deliberately not acted on: see `resourceOptions`.
            .unified_memory = c.fd_mtl_device_has_unified_memory(self.dev),
            .runtime_shader_compilation = true,
            .surface_format = self.surface_format,
        };
    }

    // -- buffers ---------------------------------------------------------------------

    pub fn createBuffer(self: *Device, desc: resource.BufferDesc) interface.ResourceError!resource.BufferHandle {
        if (desc.size == 0) return error.InvalidDescriptor;

        var buf: [label_max + 1]u8 = undefined;
        const mtl = c.fd_mtl_buffer_create(
            self.dev,
            desc.size,
            resourceOptions(desc.memory),
            cLabel(&buf, desc.label),
        ) orelse return error.OutOfDeviceMemory;
        errdefer c.fd_mtl_buffer_destroy(mtl);

        return try self.buffers.add(self.gpa, .{ .mtl = mtl, .desc = desc });
    }

    pub fn destroyBuffer(self: *Device, handle: resource.BufferHandle) void {
        const state = self.buffers.get(handle) orelse return;
        c.fd_mtl_buffer_destroy(state.mtl);
        _ = self.buffers.remove(handle);
    }

    pub fn mapBuffer(self: *Device, handle: resource.BufferHandle) interface.MapError![]u8 {
        const state = self.buffers.get(handle) orelse return error.InvalidHandle;
        // The rule from §5. Private storage means Metal would hand back null anyway, so this
        // is a guarantee rather than a policy the backend could quietly relax.
        if (!state.desc.memory.isMappable()) return error.NotMappable;

        const ptr = c.fd_mtl_buffer_contents(state.mtl) orelse return error.NotMappable;
        const bytes: [*]u8 = @ptrCast(ptr);
        return bytes[0..@intCast(state.desc.size)];
    }

    pub fn unmapBuffer(self: *Device, handle: resource.BufferHandle) void {
        const state = self.buffers.get(handle) orelse return;
        // A no-op for shared storage, and required for managed storage on a discrete GPU.
        // Called unconditionally so the code path does not differ per machine.
        c.fd_mtl_buffer_did_modify_range(state.mtl, 0, state.desc.size);
    }

    // -- textures --------------------------------------------------------------------

    pub fn createTexture(self: *Device, desc: resource.TextureDesc) interface.ResourceError!resource.TextureHandle {
        if (desc.size.isEmpty()) return error.InvalidDescriptor;

        const d: c.FdMtlTextureDesc = .{
            .pixel_format = pixelFormat(desc.format),
            .width = desc.size.width,
            .height = desc.size.height,
            .mip_levels = @max(desc.mip_levels, 1),
            .usage = textureUsage(desc.usage),
            .storage_mode = storageMode(desc.memory),
        };

        var buf: [label_max + 1]u8 = undefined;
        const mtl = c.fd_mtl_texture_create(self.dev, &d, cLabel(&buf, desc.label)) orelse
            return error.OutOfDeviceMemory;
        errdefer c.fd_mtl_texture_destroy(mtl);

        return try self.textures.add(self.gpa, .{ .mtl = mtl, .desc = desc });
    }

    pub fn destroyTexture(self: *Device, handle: resource.TextureHandle) void {
        const state = self.textures.get(handle) orelse return;
        // The swapchain handle is owned by the frame loop, not by its holder.
        if (state.is_surface) return;
        if (state.mtl) |t| c.fd_mtl_texture_destroy(t);
        _ = self.textures.remove(handle);
    }

    // -- samplers --------------------------------------------------------------------

    pub fn createSampler(self: *Device, desc: resource.SamplerDesc) interface.ResourceError!resource.SamplerHandle {
        const d: c.FdMtlSamplerDesc = .{
            .min_filter = samplerFilter(desc.min_filter),
            .mag_filter = samplerFilter(desc.mag_filter),
            .mip_filter = samplerMipFilter(desc.mip_filter),
            .address_u = samplerAddress(desc.address_u),
            .address_v = samplerAddress(desc.address_v),
        };

        var buf: [label_max + 1]u8 = undefined;
        const mtl = c.fd_mtl_sampler_create(self.dev, &d, cLabel(&buf, desc.label)) orelse
            return error.InvalidDescriptor;
        errdefer c.fd_mtl_sampler_destroy(mtl);

        return try self.samplers.add(self.gpa, .{ .mtl = mtl });
    }

    pub fn destroySampler(self: *Device, handle: resource.SamplerHandle) void {
        const state = self.samplers.get(handle) orelse return;
        c.fd_mtl_sampler_destroy(state.mtl);
        _ = self.samplers.remove(handle);
    }

    // -- shaders ---------------------------------------------------------------------

    pub fn createShaderModule(self: *Device, desc: resource.ShaderModuleDesc) interface.ResourceError!resource.ShaderModuleHandle {
        if (desc.bytes.len == 0) return error.InvalidDescriptor;

        var err: [512]u8 = undefined;
        const mtl = c.fd_mtl_library_from_data(
            self.dev,
            desc.bytes.ptr,
            desc.bytes.len,
            &err,
            err.len,
        ) orelse {
            log.warn("metallib '{s}' rejected: {s}", .{ desc.label, std.mem.sliceTo(&err, 0) });
            return error.ShaderCompilationFailed;
        };
        errdefer c.fd_mtl_library_destroy(mtl);

        return try self.shaders.add(self.gpa, .{ .mtl = mtl });
    }

    /// Runtime MSL compilation: shader hot reload today (ADR-0015), and the same mechanism
    /// mod-authored shaders will need at M7. Metal being able to do this at all is one of
    /// the reasons it is a good first backend.
    pub fn createShaderModuleFromSource(self: *Device, desc: resource.ShaderSourceDesc) interface.ResourceError!resource.ShaderModuleHandle {
        if (desc.source.len == 0) return error.InvalidDescriptor;

        const source = try self.gpa.dupeZ(u8, desc.source);
        defer self.gpa.free(source);

        var err: [1024]u8 = undefined;
        const mtl = c.fd_mtl_library_from_source(self.dev, source.ptr, &err, err.len) orelse {
            // The compiler's own words, not "compilation failed": this message is what a
            // shader author sees when hot reload rejects an edit.
            log.warn("MSL '{s}' failed to compile: {s}", .{ desc.label, std.mem.sliceTo(&err, 0) });
            return error.ShaderCompilationFailed;
        };
        errdefer c.fd_mtl_library_destroy(mtl);

        return try self.shaders.add(self.gpa, .{ .mtl = mtl });
    }

    pub fn destroyShaderModule(self: *Device, handle: resource.ShaderModuleHandle) void {
        const state = self.shaders.get(handle) orelse return;
        c.fd_mtl_library_destroy(state.mtl);
        _ = self.shaders.remove(handle);
    }

    // -- binding ---------------------------------------------------------------------

    fn bindingLessThan(_: void, a: pipeline.BindGroupLayoutEntry, b: pipeline.BindGroupLayoutEntry) bool {
        return a.binding < b.binding;
    }

    pub fn createBindGroupLayout(self: *Device, desc: pipeline.BindGroupLayoutDesc) interface.ResourceError!pipeline.BindGroupLayoutHandle {
        const entries = try self.gpa.dupe(pipeline.BindGroupLayoutEntry, desc.entries);
        errdefer self.gpa.free(entries);

        // Sorted once, here, so that the §9 walk is deterministic regardless of the order
        // the caller wrote its entries in.
        std.mem.sort(pipeline.BindGroupLayoutEntry, entries, {}, bindingLessThan);

        return try self.bind_group_layouts.add(self.gpa, .{ .entries = entries });
    }

    pub fn destroyBindGroupLayout(self: *Device, handle: pipeline.BindGroupLayoutHandle) void {
        const state = self.bind_group_layouts.get(handle) orelse return;
        self.gpa.free(state.entries);
        _ = self.bind_group_layouts.remove(handle);
    }

    pub fn createBindGroup(self: *Device, desc: pipeline.BindGroupDesc) interface.ResourceError!pipeline.BindGroupHandle {
        const entries = try self.gpa.dupe(pipeline.BindGroupEntry, desc.entries);
        errdefer self.gpa.free(entries);
        return try self.bind_groups.add(self.gpa, .{ .layout = desc.layout, .entries = entries });
    }

    pub fn destroyBindGroup(self: *Device, handle: pipeline.BindGroupHandle) void {
        const state = self.bind_groups.get(handle) orelse return;
        self.gpa.free(state.entries);
        _ = self.bind_groups.remove(handle);
    }

    /// Where the §9 flattening actually happens, once per layout rather than once per draw.
    pub fn createPipelineLayout(self: *Device, desc: pipeline.PipelineLayoutDesc) interface.ResourceError!pipeline.PipelineLayoutHandle {
        if (desc.bind_group_layouts.len > pipeline.max_bind_groups) return error.InvalidDescriptor;
        if (desc.inline_constant_bytes > pipeline.max_inline_constant_bytes) return error.InvalidDescriptor;

        const groups = try self.gpa.dupe(pipeline.BindGroupLayoutHandle, desc.bind_group_layouts);
        errdefer self.gpa.free(groups);

        var slots: std.ArrayList(BindingSlot) = .empty;
        errdefer slots.deinit(self.gpa);

        var next_buffer: u32 = first_bind_group_buffer_index;
        var next_texture: u32 = 0;
        var next_sampler: u32 = 0;

        for (groups, 0..) |group_handle, group_index| {
            const layout = self.bind_group_layouts.getConst(group_handle) orelse continue;
            for (layout.entries) |entry| {
                const index = switch (entry.type) {
                    .uniform_buffer, .storage_buffer => blk: {
                        defer next_buffer += 1;
                        break :blk next_buffer;
                    },
                    .sampled_texture => blk: {
                        defer next_texture += 1;
                        break :blk next_texture;
                    },
                    .sampler => blk: {
                        defer next_sampler += 1;
                        break :blk next_sampler;
                    },
                };
                try slots.append(self.gpa, .{
                    .group = @intCast(group_index),
                    .binding = entry.binding,
                    .type = entry.type,
                    .visibility = entry.visibility,
                    .index = index,
                });
            }
        }

        return try self.pipeline_layouts.add(self.gpa, .{
            .bind_group_layouts = groups,
            .inline_constant_bytes = desc.inline_constant_bytes,
            .slots = try slots.toOwnedSlice(self.gpa),
        });
    }

    pub fn destroyPipelineLayout(self: *Device, handle: pipeline.PipelineLayoutHandle) void {
        const state = self.pipeline_layouts.get(handle) orelse return;
        self.gpa.free(state.bind_group_layouts);
        self.gpa.free(state.slots);
        _ = self.pipeline_layouts.remove(handle);
    }

    // -- pipelines -------------------------------------------------------------------

    pub fn createRenderPipeline(self: *Device, desc: pipeline.RenderPipelineDesc) interface.ResourceError!pipeline.RenderPipelineHandle {
        const vertex_lib = self.shaders.getConst(desc.vertex_shader) orelse return error.InvalidDescriptor;
        const fragment_lib = self.shaders.getConst(desc.fragment_shader) orelse return error.InvalidDescriptor;

        var vname: [label_max + 1]u8 = undefined;
        var fname: [label_max + 1]u8 = undefined;
        const vfn = c.fd_mtl_library_function(vertex_lib.mtl, cLabel(&vname, desc.vertex_entry)) orelse {
            log.warn("pipeline '{s}': no vertex function named '{s}'", .{ desc.label, desc.vertex_entry });
            return error.InvalidDescriptor;
        };
        defer c.fd_mtl_function_destroy(vfn);

        const ffn = c.fd_mtl_library_function(fragment_lib.mtl, cLabel(&fname, desc.fragment_entry)) orelse {
            log.warn("pipeline '{s}': no fragment function named '{s}'", .{ desc.label, desc.fragment_entry });
            return error.InvalidDescriptor;
        };
        defer c.fd_mtl_function_destroy(ffn);

        if (desc.vertex_buffers.len > pipeline.max_vertex_buffers) return error.InvalidDescriptor;

        var attributes: std.ArrayList(c.FdMtlVertexAttribute) = .empty;
        defer attributes.deinit(self.gpa);
        var layouts: std.ArrayList(c.FdMtlVertexBufferLayout) = .empty;
        defer layouts.deinit(self.gpa);

        for (desc.vertex_buffers, 0..) |vb, slot| {
            // Vertex buffer slot `i` is Metal buffer index `i` — the fixed low block from
            // §9, so a shader's `[[buffer(0)]]` means slot 0 in every pipeline.
            try layouts.append(self.gpa, .{
                .buffer_index = @intCast(slot),
                .stride = vb.stride,
                .step_function = stepFunction(vb.step_mode),
            });
            for (vb.attributes) |attr| {
                try attributes.append(self.gpa, .{
                    .location = attr.location,
                    .format = vertexFormat(attr.format),
                    .offset = attr.offset,
                    .buffer_index = @intCast(slot),
                });
            }
        }

        var targets: std.ArrayList(c.FdMtlColorTarget) = .empty;
        defer targets.deinit(self.gpa);
        for (desc.color_targets) |t| {
            const b = t.blend orelse pipeline.BlendState{};
            try targets.append(self.gpa, .{
                .pixel_format = pixelFormat(t.format),
                .blending_enabled = t.blend != null,
                .src_rgb = blendFactor(b.color.src),
                .dst_rgb = blendFactor(b.color.dst),
                .rgb_op = blendOp(b.color.op),
                .src_alpha = blendFactor(b.alpha.src),
                .dst_alpha = blendFactor(b.alpha.dst),
                .alpha_op = blendOp(b.alpha.op),
                .write_mask = colorWriteMask(t.write_mask),
            });
        }

        var label_buf: [label_max + 1]u8 = undefined;
        const d: c.FdMtlRenderPipelineDesc = .{
            .vertex_function = vfn,
            .fragment_function = ffn,
            .attributes = attributes.items.ptr,
            .attribute_count = @intCast(attributes.items.len),
            .vertex_layouts = layouts.items.ptr,
            .vertex_layout_count = @intCast(layouts.items.len),
            .color_targets = targets.items.ptr,
            .color_target_count = @intCast(targets.items.len),
            .depth_pixel_format = if (desc.depth_stencil) |ds|
                pixelFormat(ds.format)
            else
                c.FD_MTL_PIXEL_FORMAT_INVALID,
            .label = cLabel(&label_buf, desc.label),
        };

        var err: [1024]u8 = undefined;
        const mtl = c.fd_mtl_render_pipeline_create(self.dev, &d, &err, err.len) orelse {
            log.warn("pipeline '{s}' rejected by Metal: {s}", .{ desc.label, std.mem.sliceTo(&err, 0) });
            return error.InvalidDescriptor;
        };
        errdefer c.fd_mtl_render_pipeline_destroy(mtl);

        var depth_state: ?*c.FdMtlDepthState = null;
        if (desc.depth_stencil) |ds| {
            const dsd: c.FdMtlDepthStateDesc = .{
                .compare = compareFunction(ds.depth_compare),
                .write_enabled = ds.depth_write_enabled,
            };
            depth_state = c.fd_mtl_depth_state_create(self.dev, &dsd);
        }
        errdefer if (depth_state) |s| c.fd_mtl_depth_state_destroy(s);

        return try self.pipelines.add(self.gpa, .{
            .mtl = mtl,
            .depth_state = depth_state,
            .layout = desc.layout,
            .primitive = desc.primitive,
        });
    }

    pub fn destroyRenderPipeline(self: *Device, handle: pipeline.RenderPipelineHandle) void {
        const state = self.pipelines.get(handle) orelse return;
        c.fd_mtl_render_pipeline_destroy(state.mtl);
        if (state.depth_state) |d| c.fd_mtl_depth_state_destroy(d);
        _ = self.pipelines.remove(handle);
    }

    // -- the frame ring --------------------------------------------------------------

    fn releaseDrawable(self: *Device) void {
        if (self.textures.get(self.surface_texture)) |t| {
            if (self.layer != null) {
                if (t.mtl) |tex| c.fd_mtl_texture_destroy(tex);
                t.mtl = null;
            }
        }
        if (self.drawable) |d| {
            c.fd_mtl_drawable_destroy(d);
            self.drawable = null;
        }
    }

    pub fn beginFrame(self: *Device) interface.FrameError!command.FrameContext {
        self.frame_index += 1;
        self.frame_slot = @intCast((self.frame_index - 1) % self.desc.frames_in_flight);

        // The frame ring, in three lines. Waiting on the command buffer that last used this
        // slot is what makes writing to the slot's per-frame resources safe.
        if (self.in_flight[self.frame_slot]) |cb| {
            c.fd_mtl_command_buffer_wait_until_completed(cb);
            c.fd_mtl_command_buffer_destroy(cb);
            self.in_flight[self.frame_slot] = null;
        }

        if (self.layer) |l| {
            const drawable = c.fd_mtl_layer_next_drawable(l) orelse {
                // Transient: a minimised or fully occluded window, or every drawable still
                // in flight. The RHI has one error for "the swapchain did not give us an
                // image", so this reports `SurfaceLost` and the caller skips the frame.
                self.frame_index -= 1;
                return error.SurfaceLost;
            };
            self.drawable = drawable;

            const texture = c.fd_mtl_drawable_texture(drawable) orelse {
                c.fd_mtl_drawable_destroy(drawable);
                self.drawable = null;
                self.frame_index -= 1;
                return error.SurfaceLost;
            };
            if (self.textures.get(self.surface_texture)) |t| {
                t.mtl = texture;
                t.desc.size = .{
                    .width = c.fd_mtl_texture_width(texture),
                    .height = c.fd_mtl_texture_height(texture),
                };
            }
        }

        return .{
            .surface_texture = self.surface_texture,
            .slot = self.frame_slot,
            .index = self.frame_index,
        };
    }

    pub fn endFrame(self: *Device) interface.FrameError!void {
        // A trailing command buffer, which does three jobs at once: it is where the present
        // is scheduled (Metal requires that before commit, and the caller's own command
        // buffers are already committed by then), it is what the slot waits on next time
        // round, and it keeps the headless path identical to the windowed one.
        const cb = c.fd_mtl_command_buffer_create(self.queue, "frame end") orelse
            return error.OutOfMemory;

        if (self.drawable) |d| c.fd_mtl_command_buffer_present(cb, d);
        c.fd_mtl_command_buffer_commit(cb);

        self.in_flight[self.frame_slot] = cb;
        self.releaseDrawable();
    }

    pub fn resizeSurface(self: *Device, size: resource.Extent2D) interface.FrameError!void {
        if (size.isEmpty()) return;
        self.surface_size = size;

        if (self.layer) |l| {
            c.fd_mtl_layer_configure(
                l,
                self.dev,
                pixelFormat(self.surface_format),
                size.width,
                size.height,
                true,
            );
        } else {
            // Headless: the offscreen target is the surface, so it has to be rebuilt. Wait
            // first — the old texture may still be in flight.
            for (&self.in_flight) |*slot| {
                if (slot.*) |cb| {
                    c.fd_mtl_command_buffer_wait_until_completed(cb);
                    c.fd_mtl_command_buffer_destroy(cb);
                    slot.* = null;
                }
            }
            if (self.offscreen) |t| c.fd_mtl_texture_destroy(t);
            self.offscreen = self.createOffscreen(size) orelse return error.SurfaceLost;
            if (self.textures.get(self.surface_texture)) |t| t.mtl = self.offscreen;
        }

        if (self.textures.get(self.surface_texture)) |t| t.desc.size = size;
    }

    // -- recording -------------------------------------------------------------------

    pub fn beginCommandBuffer(self: *Device) interface.CommandError!*CommandBuffer {
        const cb = if (self.free_command_buffers.pop()) |reused| reused else blk: {
            const fresh = try self.gpa.create(CommandBuffer);
            try self.command_buffers.append(self.gpa, fresh);
            break :blk fresh;
        };

        const mtl = c.fd_mtl_command_buffer_create(self.queue, "foundry") orelse
            return error.OutOfMemory;

        cb.* = .{ .device = self, .mtl = mtl };
        return cb;
    }
};

// -- command buffer ---------------------------------------------------------------------

pub const CommandBuffer = struct {
    device: *Device,
    mtl: *c.FdMtlCommandBuffer,

    pub fn beginRenderPass(self: *CommandBuffer, desc: command.RenderPassDesc) interface.CommandError!*RenderPass {
        const dev = self.device;

        var color: [8]c.FdMtlColorAttachment = undefined;
        const color_count = @min(desc.color.len, color.len);
        for (desc.color[0..color_count], 0..) |a, i| {
            const texture = if (dev.textures.getConst(a.texture)) |t| t.mtl else null;
            const clear: [4]f32 = switch (a.load) {
                .clear => |v| switch (v) {
                    .color => |rgba| rgba,
                    .depth_stencil => .{ 0, 0, 0, 1 },
                },
                else => .{ 0, 0, 0, 1 },
            };
            color[i] = .{
                .texture = texture,
                .load_action = loadAction(a.load),
                .store_action = storeAction(a.store),
                .clear_r = clear[0],
                .clear_g = clear[1],
                .clear_b = clear[2],
                .clear_a = clear[3],
            };
        }

        var depth: c.FdMtlDepthAttachment = undefined;
        var depth_ptr: ?*const c.FdMtlDepthAttachment = null;
        if (desc.depth) |d| {
            const texture = if (dev.textures.getConst(d.texture)) |t| t.mtl else null;
            const clear_depth: f32 = switch (d.load) {
                .clear => |v| switch (v) {
                    .depth_stencil => |ds| ds.depth,
                    .color => 1.0,
                },
                else => 1.0,
            };
            depth = .{
                .texture = texture,
                .load_action = loadAction(d.load),
                .store_action = storeAction(d.store),
                .clear_depth = clear_depth,
            };
            depth_ptr = &depth;
        }

        var label_buf: [label_max + 1]u8 = undefined;
        const pass_desc: c.FdMtlRenderPassDesc = .{
            .color = &color,
            .color_count = @intCast(color_count),
            .depth = depth_ptr,
            .label = cLabel(&label_buf, desc.label),
        };

        const enc = c.fd_mtl_render_encoder_begin(self.mtl, &pass_desc) orelse
            return error.OutOfMemory;

        const pass = if (dev.free_render_passes.pop()) |reused| reused else blk: {
            const fresh = try dev.gpa.create(RenderPass);
            try dev.render_passes.append(dev.gpa, fresh);
            break :blk fresh;
        };
        pass.* = .{ .device = dev, .cmd = self, .enc = enc };
        return pass;
    }

    /// Barriers exist in the interface because Vulkan and D3D12 cannot function without
    /// them and go catastrophically wrong when one is missed. Metal tracks the same
    /// dependencies itself, so this backend discards them — and the null backend checks
    /// they were declared correctly, which is what keeps the interface honest while Metal
    /// is the only real implementation (`rhi.md` §6).
    pub fn textureBarrier(self: *CommandBuffer, barriers: []const command.TextureBarrier) interface.CommandError!void {
        _ = self;
        _ = barriers;
    }

    pub fn bufferBarrier(self: *CommandBuffer, barriers: []const command.BufferBarrier) interface.CommandError!void {
        _ = self;
        _ = barriers;
    }

    pub fn copyBufferToBuffer(self: *CommandBuffer, copy: command.BufferCopy) interface.CommandError!void {
        const dev = self.device;
        const src = dev.buffers.getConst(copy.src) orelse return;
        const dst = dev.buffers.getConst(copy.dst) orelse return;

        const enc = c.fd_mtl_blit_encoder_begin(self.mtl) orelse return error.OutOfMemory;
        defer c.fd_mtl_blit_encoder_destroy(enc);
        c.fd_mtl_blit_copy_buffer(enc, src.mtl, copy.src_offset, dst.mtl, copy.dst_offset, copy.size);
        c.fd_mtl_blit_encoder_end(enc);
    }

    pub fn copyBufferToTexture(self: *CommandBuffer, copy: command.BufferToTextureCopy) interface.CommandError!void {
        const dev = self.device;
        const src = dev.buffers.getConst(copy.src) orelse return;
        const dst = dev.textures.getConst(copy.dst) orelse return;
        const dst_mtl = dst.mtl orelse return;

        // Zero means tightly packed, which the format already knows.
        const bytes_per_row = if (copy.src_bytes_per_row != 0)
            copy.src_bytes_per_row
        else
            copy.size.width * dst.desc.format.bytesPerTexel();

        const enc = c.fd_mtl_blit_encoder_begin(self.mtl) orelse return error.OutOfMemory;
        defer c.fd_mtl_blit_encoder_destroy(enc);
        c.fd_mtl_blit_copy_buffer_to_texture(
            enc,
            src.mtl,
            copy.src_offset,
            bytes_per_row,
            dst_mtl,
            copy.dst_mip_level,
            copy.size.width,
            copy.size.height,
        );
        c.fd_mtl_blit_encoder_end(enc);
    }

    pub fn submit(self: *CommandBuffer) interface.CommandError!void {
        const dev = self.device;
        c.fd_mtl_command_buffer_commit(self.mtl);
        // Releasing our reference is safe the moment it is committed: Metal keeps the
        // command buffer alive itself until the GPU is done with it.
        c.fd_mtl_command_buffer_destroy(self.mtl);
        dev.free_command_buffers.append(dev.gpa, self) catch {};
    }
};

// -- render pass --------------------------------------------------------------------------

pub const RenderPass = struct {
    device: *Device,
    cmd: *CommandBuffer,
    enc: ?*c.FdMtlRenderEncoder,

    pipeline_handle: pipeline.RenderPipelineHandle = .none,
    bound_groups: [pipeline.max_bind_groups]pipeline.BindGroupHandle = @splat(.none),
    index_buffer: resource.BufferHandle = .none,
    index_format: format.IndexFormat = .uint16,
    index_offset: u64 = 0,

    pub fn setPipeline(self: *RenderPass, handle: pipeline.RenderPipelineHandle) void {
        const enc = self.enc orelse return;
        const state = self.device.pipelines.getConst(handle) orelse return;

        self.pipeline_handle = handle;
        c.fd_mtl_render_encoder_set_pipeline(enc, state.mtl);
        c.fd_mtl_render_encoder_set_cull_mode(enc, cullMode(state.primitive.cull_mode));
        c.fd_mtl_render_encoder_set_front_face(enc, winding(state.primitive.front_face));
        if (state.depth_state) |d| c.fd_mtl_render_encoder_set_depth_state(enc, d);
    }

    /// Recorded rather than bound, because the argument-table index depends on the bound
    /// pipeline's layout and a group may legitimately be set before a pipeline is. The
    /// actual binds happen in `flushBindings` at draw time.
    pub fn setBindGroup(self: *RenderPass, index: u32, group: pipeline.BindGroupHandle) void {
        if (index >= pipeline.max_bind_groups) return;
        self.bound_groups[index] = group;
    }

    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: resource.BufferHandle, offset: u64) void {
        const enc = self.enc orelse return;
        if (slot >= pipeline.max_vertex_buffers) return;
        const state = self.device.buffers.getConst(buffer) orelse return;
        // A vertex buffer's Metal index is its slot, always — the fixed block from §9.
        c.fd_mtl_render_encoder_set_vertex_buffer(enc, state.mtl, offset, slot);
    }

    pub fn setIndexBuffer(self: *RenderPass, buffer: resource.BufferHandle, index_format: format.IndexFormat, offset: u64) void {
        // Metal takes the index buffer at the draw call rather than as encoder state, so it
        // is remembered here and passed through by `drawIndexed`.
        self.index_buffer = buffer;
        self.index_format = index_format;
        self.index_offset = offset;
    }

    /// Push-constant-style, exactly as `rhi.md` §9 specifies: copied at the call, scoped to
    /// this pass, whole-block. `setVertexBytes:` is Metal's equivalent and is why the block
    /// is small — it is command stream data, not a resource.
    pub fn setInlineConstants(self: *RenderPass, bytes: []const u8) void {
        const enc = self.enc orelse return;
        if (bytes.len == 0 or bytes.len > pipeline.max_inline_constant_bytes) return;
        c.fd_mtl_render_encoder_set_vertex_bytes(enc, bytes.ptr, bytes.len, inline_constant_buffer_index);
        c.fd_mtl_render_encoder_set_fragment_bytes(enc, bytes.ptr, bytes.len, inline_constant_buffer_index);
    }

    pub fn setViewport(self: *RenderPass, viewport: command.Viewport) void {
        const enc = self.enc orelse return;
        c.fd_mtl_render_encoder_set_viewport(
            enc,
            viewport.x,
            viewport.y,
            viewport.width,
            viewport.height,
            viewport.min_depth,
            viewport.max_depth,
        );
    }

    pub fn setScissor(self: *RenderPass, rect: command.ScissorRect) void {
        const enc = self.enc orelse return;
        c.fd_mtl_render_encoder_set_scissor(enc, rect.x, rect.y, rect.width, rect.height);
    }

    fn findEntry(entries: []const pipeline.BindGroupEntry, binding: u32) ?pipeline.BindGroupEntry {
        for (entries) |e| {
            if (e.binding == binding) return e;
        }
        return null;
    }

    /// Applies the §9 flattening. Walks the layout's precomputed slots and binds whatever
    /// the corresponding group holds, into each stage the binding is visible to.
    fn flushBindings(self: *RenderPass) void {
        const enc = self.enc orelse return;
        const dev = self.device;

        const pso = dev.pipelines.getConst(self.pipeline_handle) orelse return;
        const layout = dev.pipeline_layouts.getConst(pso.layout) orelse return;

        for (layout.slots) |slot| {
            const group = dev.bind_groups.getConst(self.bound_groups[slot.group]) orelse continue;
            const entry = findEntry(group.entries, slot.binding) orelse continue;

            switch (entry.resource) {
                .uniform_buffer, .storage_buffer => |binding| {
                    const buffer = dev.buffers.getConst(binding.buffer) orelse continue;
                    if (slot.visibility.vertex) {
                        c.fd_mtl_render_encoder_set_vertex_buffer(enc, buffer.mtl, binding.offset, slot.index);
                    }
                    if (slot.visibility.fragment) {
                        c.fd_mtl_render_encoder_set_fragment_buffer(enc, buffer.mtl, binding.offset, slot.index);
                    }
                },
                .sampled_texture => |handle| {
                    const texture = dev.textures.getConst(handle) orelse continue;
                    const mtl = texture.mtl orelse continue;
                    if (slot.visibility.vertex) {
                        c.fd_mtl_render_encoder_set_vertex_texture(enc, mtl, slot.index);
                    }
                    if (slot.visibility.fragment) {
                        c.fd_mtl_render_encoder_set_fragment_texture(enc, mtl, slot.index);
                    }
                },
                .sampler => |handle| {
                    const sampler = dev.samplers.getConst(handle) orelse continue;
                    if (slot.visibility.vertex) {
                        c.fd_mtl_render_encoder_set_vertex_sampler(enc, sampler.mtl, slot.index);
                    }
                    if (slot.visibility.fragment) {
                        c.fd_mtl_render_encoder_set_fragment_sampler(enc, sampler.mtl, slot.index);
                    }
                },
            }
        }
    }

    pub fn draw(self: *RenderPass, params: command.Draw) void {
        const enc = self.enc orelse return;
        const pso = self.device.pipelines.getConst(self.pipeline_handle) orelse return;
        self.flushBindings();
        c.fd_mtl_render_encoder_draw(
            enc,
            primitiveType(pso.primitive.topology),
            params.first_vertex,
            params.vertex_count,
            params.instance_count,
            params.first_instance,
        );
    }

    pub fn drawIndexed(self: *RenderPass, params: command.DrawIndexed) void {
        const enc = self.enc orelse return;
        const pso = self.device.pipelines.getConst(self.pipeline_handle) orelse return;
        const index_buffer = self.device.buffers.getConst(self.index_buffer) orelse return;
        self.flushBindings();

        const offset = self.index_offset + @as(u64, params.first_index) * self.index_format.size();
        c.fd_mtl_render_encoder_draw_indexed(
            enc,
            primitiveType(pso.primitive.topology),
            params.index_count,
            indexType(self.index_format),
            index_buffer.mtl,
            offset,
            params.instance_count,
            params.base_vertex,
            params.first_instance,
        );
    }

    pub fn end(self: *RenderPass) void {
        const dev = self.device;
        if (self.enc) |enc| {
            c.fd_mtl_render_encoder_end(enc);
            c.fd_mtl_render_encoder_destroy(enc);
            self.enc = null;
        }
        dev.free_render_passes.append(dev.gpa, self) catch {};
    }
};

// -- tests ------------------------------------------------------------------------------
//
// These run only when the Metal backend is the one selected, because they need a real GPU.
// The RHI's behaviour is tested exhaustively against the null backend, which is headless and
// runs everywhere; what is worth testing *here* is the part that only a device can answer —
// that the translation tables produce descriptors Metal accepts, that runtime MSL
// compilation works, and that the frame ring completes.

const testing = std.testing;

fn headlessDevice() !*Device {
    return try Device.init(testing.allocator, .{
        .label = "test",
        .surface = .none,
        .surface_size = .{ .width = 64, .height = 64 },
        .frames_in_flight = 2,
    });
}

test "a headless device comes up and reports capabilities" {
    const dev = try headlessDevice();
    defer dev.deinit();

    const caps = dev.capabilities();
    try testing.expectEqual(pipeline.max_bind_groups, caps.max_bind_groups);
    try testing.expectEqual(pipeline.max_inline_constant_bytes, caps.max_inline_constant_bytes);
    try testing.expectEqual(pipeline.max_vertex_buffers, caps.max_vertex_buffers);
    try testing.expect(caps.runtime_shader_compilation);
    // Every Metal device Foundry targets supports at least this.
    try testing.expect(caps.max_texture_dimension >= 8192);
}

test "device_local buffers are not mappable, upload buffers are" {
    // The §5 rule, checked against the real API rather than only against the validator.
    // Private storage means Metal itself has no contents to hand back, which is a stronger
    // guarantee than a check the backend could relax.
    const dev = try headlessDevice();
    defer dev.deinit();

    const device_local = try dev.createBuffer(.{ .size = 256, .usage = .{ .vertex = true } });
    defer dev.destroyBuffer(device_local);
    try testing.expectError(error.NotMappable, dev.mapBuffer(device_local));

    const upload = try dev.createBuffer(.{
        .size = 256,
        .usage = .{ .copy_src = true },
        .memory = .upload,
    });
    defer dev.destroyBuffer(upload);

    const mapped = try dev.mapBuffer(upload);
    try testing.expectEqual(@as(usize, 256), mapped.len);
    mapped[0] = 0xAB;
    dev.unmapBuffer(upload);
    try testing.expectEqual(@as(u8, 0xAB), (try dev.mapBuffer(upload))[0]);
}

test "runtime MSL compilation succeeds and reports failure with the compiler's message" {
    const dev = try headlessDevice();
    defer dev.deinit();

    const good = try dev.createShaderModuleFromSource(.{
        .label = "test.msl",
        .source =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\vertex float4 vertexMain(uint vid [[vertex_id]]) {
        \\    return float4(0, 0, 0, 1);
        \\}
        \\fragment float4 fragmentMain() { return float4(1, 0, 1, 1); }
        ,
    });
    dev.destroyShaderModule(good);

    // The hot-reload path's unhappy case, which must be an error and not a crash: an author
    // saving a broken shader is the expected case, not an exceptional one (ADR-0015).
    try testing.expectError(error.ShaderCompilationFailed, dev.createShaderModuleFromSource(.{
        .label = "broken.msl",
        .source = "this is not MSL",
    }));
}

test "a pipeline builds and a frame of it completes" {
    const dev = try headlessDevice();
    defer dev.deinit();

    const shader = try dev.createShaderModuleFromSource(.{
        .label = "triangle",
        .source =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\vertex float4 vertexMain(uint vid [[vertex_id]]) {
        \\    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        \\    return float4(p[vid], 0, 1);
        \\}
        \\fragment float4 fragmentMain() { return float4(0, 1, 0, 1); }
        ,
    });
    defer dev.destroyShaderModule(shader);

    const layout = try dev.createPipelineLayout(.{ .label = "empty" });
    defer dev.destroyPipelineLayout(layout);

    const pso = try dev.createRenderPipeline(.{
        .label = "triangle",
        .layout = layout,
        .vertex_shader = shader,
        .fragment_shader = shader,
        .color_targets = &.{.{ .format = dev.capabilities().surface_format }},
    });
    defer dev.destroyRenderPipeline(pso);

    const frame = try dev.beginFrame();
    try testing.expectEqual(@as(u64, 1), frame.index);

    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .label = "main",
        .color = &.{.{
            .texture = frame.surface_texture,
            .load = .{ .clear = .{ .color = .{ 0.1, 0.2, 0.3, 1 } } },
            .initial_state = .undefined,
            .final_state = .present,
        }},
    });
    pass.setPipeline(pso);
    pass.setViewport(.{ .width = 64, .height = 64 });
    pass.draw(.{ .vertex_count = 3 });
    pass.end();
    try cmd.submit();
    try dev.endFrame();

    // The ring's own wait is the proof the GPU finished: a second frame in the same slot
    // cannot begin until it has.
    _ = try dev.beginFrame();
    try dev.endFrame();
}

test "the binding flattening follows the documented walk order" {
    // The contract from `rhi.md` §9. Asserted on the computed slots rather than on rendered
    // output, because this is what a shader author compiles against: groups ascending, then
    // bindings ascending *by value*, never in descriptor order.
    const dev = try headlessDevice();
    defer dev.deinit();

    // Deliberately written out of order, to prove the sort is what decides.
    const group0 = try dev.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 2, .type = .sampled_texture, .visibility = .{ .fragment = true } },
        .{ .binding = 0, .type = .uniform_buffer, .visibility = .both },
    } });
    defer dev.destroyBindGroupLayout(group0);

    const group1 = try dev.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
        .{ .binding = 0, .type = .uniform_buffer, .visibility = .{ .vertex = true } },
    } });
    defer dev.destroyBindGroupLayout(group1);

    const layout = try dev.createPipelineLayout(.{ .bind_group_layouts = &.{ group0, group1 } });
    defer dev.destroyPipelineLayout(layout);

    const state = dev.pipeline_layouts.getConst(layout).?;
    try testing.expectEqual(@as(usize, 4), state.slots.len);

    // Group 0, binding 0: the first buffer, so the first index above the reserved block.
    try testing.expectEqual(@as(u32, 0), state.slots[0].group);
    try testing.expectEqual(@as(u32, 0), state.slots[0].binding);
    try testing.expectEqual(first_bind_group_buffer_index, state.slots[0].index);

    // Group 0, binding 2: the first texture, so texture index 0. Table counters are
    // independent, which is why this is 0 and not 1.
    try testing.expectEqual(@as(u32, 2), state.slots[1].binding);
    try testing.expectEqual(@as(u32, 0), state.slots[1].index);

    // Group 1, binding 0: the second buffer.
    try testing.expectEqual(@as(u32, 1), state.slots[2].group);
    try testing.expectEqual(first_bind_group_buffer_index + 1, state.slots[2].index);

    // Group 1, binding 1: the first sampler.
    try testing.expectEqual(pipeline.BindingType.sampler, state.slots[3].type);
    try testing.expectEqual(@as(u32, 0), state.slots[3].index);
}

test "the reserved index blocks do not overlap" {
    // The arithmetic the whole convention rests on, asserted rather than assumed: a vertex
    // buffer must never land on the inline constant slot or on a bind group's buffer.
    try testing.expect(inline_constant_buffer_index >= pipeline.max_vertex_buffers);
    try testing.expect(first_bind_group_buffer_index > inline_constant_buffer_index);
}

test "an unsupported surface kind is reported, not asserted" {
    // A configuration mistake — the wrong platform backend for this graphics backend —
    // rather than a programmer error, so it comes back as an error the caller can log.
    try testing.expectError(error.SurfaceUnsupported, Device.init(testing.allocator, .{
        .surface = .{ .kind = .win32_hwnd, .ptr = @ptrFromInt(0x1000) },
    }));
}

test "a resize rebuilds the headless target and the surface handle survives it" {
    // The handle must be stable across a resize for the same reason it is stable across a
    // frame: anything holding it would otherwise be broken by a window drag.
    const dev = try headlessDevice();
    defer dev.deinit();

    const before = dev.surface_texture;
    try dev.resizeSurface(.{ .width = 128, .height = 96 });

    try testing.expectEqual(before, dev.surface_texture);
    try testing.expect(dev.surface_size.eql(.{ .width = 128, .height = 96 }));

    const state = dev.textures.getConst(dev.surface_texture).?;
    try testing.expect(state.desc.size.eql(.{ .width = 128, .height = 96 }));
    try testing.expect(state.mtl != null);
}
