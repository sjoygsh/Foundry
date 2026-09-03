//! The null backend, which is a **validation backend**.
//!
//! It draws nothing. That is not what it is for. ADR-0003 accepts a real risk — an
//! abstraction validated against a single API is not validated, and Metal is the most
//! forgiving of the three — and this file is the agreed mitigation: it enforces the rules
//! Metal silently forgives, so that they are caught now rather than by a second backend
//! producing garbage months later with no obvious cause.
//!
//! ## Scope, deliberately fixed
//!
//! It enforces **the ten rules in `docs/design/rhi.md` §11 and nothing else.** It is not a
//! style checker and holds no opinions the abstraction does not state: a call the design
//! document permits must not be rejected here, however unwise it looks. Tightening a rule
//! means changing that document first — a validation backend that enforces more than the
//! interface promises makes the interface a fiction and turns the Metal backend into the
//! real specification, which is precisely the failure being avoided.
//!
//! **Contract violations become `Violation` records; engine programmer errors assert.**
//! The distinction is `core.assert`'s: a violated RHI rule is something a caller could
//! legitimately get wrong and needs to be *told* about, recorded so a test can assert on
//! it. Passing a bind group index of 900, or calling `deinit` twice, is a bug in engine
//! code with no defined behaviour to report, and asserts.
//!
//! Design: `docs/design/rhi.md` §11.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");

const command = @import("../command.zig");
const format = @import("../format.zig");
const interface = @import("../interface.zig");
const pipeline = @import("../pipeline.zig");
const resource = @import("../resource.zig");

const Allocator = std.mem.Allocator;
const assert = core.assert;
const log = core.log.scoped(.rhi);

/// Generous internal capacities. These are *not* contract limits — exceeding one is an
/// engine bug with no sensible behaviour to report, so it asserts rather than becoming a
/// violation. The two real limits are in `pipeline.zig` and are enforced as rule 10.
const max_color_attachments = 8;
const max_vertex_buffers = 16;
const max_frames_in_flight = 4;

/// The ten rules of `docs/design/rhi.md` §11, numbered as they are there.
///
/// Numbered rather than free-form so that a violation can be asserted on by identity in a
/// test, and so that the mapping between the document and the code stays checkable.
pub const Rule = enum(u8) {
    /// Every texture's state is tracked; a mismatch with a declared transition is an error.
    resource_state = 1,
    /// A `device_local` resource was mapped.
    device_local_mapped = 2,
    /// A per-frame resource was written while its slot was still in flight.
    frame_ring = 3,
    /// A bind group was built for a different layout than the pipeline declares.
    bind_group_compatibility = 4,
    /// A draw was missing a group, or inline constants, that the layout requires.
    incomplete_bindings = 5,
    /// A vertex buffer the pipeline's layout declares was not bound.
    vertex_layout = 6,
    /// A pass's attachment formats do not match the pipeline's.
    attachment_format = 7,
    /// Malformed recording structure: nested passes, unended passes, reused submissions.
    ///
    /// Read as covering recording structure at *every* level, the frame included, since a
    /// frame is the outermost recording scope. That reading is a clarification of the
    /// rule's scope rather than an eleventh rule.
    encoder_discipline = 8,
    /// A resource was destroyed while a frame referencing it was still in flight.
    lifetime = 9,
    /// A documented limit was exceeded: more than four bind groups, or more inline
    /// constant bytes than 128 or than the bound pipeline's layout declares.
    limits = 10,
};

pub const Violation = struct {
    rule: Rule,
    /// Owned by the device; freed by `clearViolations` and `deinit`.
    detail: []const u8,
};

// -- tracked resource state ----------------------------------------------------------

const BufferState = struct {
    desc: resource.BufferDesc,
    state: resource.ResourceState = .undefined,
    /// Real storage, so that `mapBuffer` returns memory a caller can actually write and
    /// a test can observe. The null backend models the contract, not the silicon.
    storage: []u8,
    mapped: bool = false,
    /// The last frame index in which a command buffer referenced this resource. Rules 3
    /// and 9 both turn on this number.
    last_frame_used: u64 = 0,
};

const TextureState = struct {
    desc: resource.TextureDesc,
    state: resource.ResourceState,
    last_frame_used: u64 = 0,
    is_surface: bool = false,
};

const SamplerState = struct { desc: resource.SamplerDesc };
const ShaderState = struct { label: []const u8, from_source: bool };

const BindGroupLayoutState = struct {
    entries: []pipeline.BindGroupLayoutEntry,
};

const BindGroupState = struct {
    layout: pipeline.BindGroupLayoutHandle,
    entries: []pipeline.BindGroupEntry,
    last_frame_used: u64 = 0,
};

const PipelineLayoutState = struct {
    bind_group_layouts: []pipeline.BindGroupLayoutHandle,
    inline_constant_bytes: u32,
};

const RenderPipelineState = struct {
    layout: pipeline.PipelineLayoutHandle,
    color_formats: []format.TextureFormat,
    depth_format: ?format.TextureFormat,
    vertex_buffer_count: u32,
};

// -- device --------------------------------------------------------------------------

pub const Device = struct {
    gpa: Allocator,
    desc: interface.DeviceDesc,

    buffers: core.HandlePool(resource.Buffer, BufferState) = .empty,
    textures: core.HandlePool(resource.Texture, TextureState) = .empty,
    samplers: core.HandlePool(resource.Sampler, SamplerState) = .empty,
    shaders: core.HandlePool(resource.ShaderModule, ShaderState) = .empty,
    bind_group_layouts: core.HandlePool(pipeline.BindGroupLayout, BindGroupLayoutState) = .empty,
    bind_groups: core.HandlePool(pipeline.BindGroup, BindGroupState) = .empty,
    pipeline_layouts: core.HandlePool(pipeline.PipelineLayout, PipelineLayoutState) = .empty,
    pipelines: core.HandlePool(pipeline.RenderPipeline, RenderPipelineState) = .empty,

    violation_list: std.ArrayList(Violation) = .empty,
    /// Violations are logged at error level by default, which is what a developer wants.
    /// Tests that deliberately provoke one turn this off — Zig's test runner treats an
    /// error-level log as a test failure, correctly, and that is not something to opt out
    /// of globally just to keep a test quiet.
    log_violations: bool = true,

    surface_texture: resource.TextureHandle = .none,
    surface_size: resource.Extent2D,

    frame_index: u64 = 0,
    frame_slot: u32 = 0,
    in_frame: bool = false,

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

        const self = try gpa.create(Device);
        self.* = .{ .gpa = gpa, .desc = desc, .surface_size = desc.surface_size };

        // A headless device still has a target: a pass has to render somewhere, and
        // offscreen is the honest model for "no swapchain".
        self.surface_texture = self.createTexture(.{
            .label = "surface",
            .size = desc.surface_size,
            .format = .bgra8_unorm_srgb,
            .usage = .{ .render_target = true, .copy_src = true },
        }) catch {
            gpa.destroy(self);
            return error.OutOfMemory;
        };
        if (self.textures.get(self.surface_texture)) |t| t.is_surface = true;

        log.info("rhi backend: null (validating), {d} frames in flight", .{desc.frames_in_flight});
        return self;
    }

    pub fn deinit(self: *Device) void {
        const gpa = self.gpa;

        for (self.command_buffers.items) |cb| gpa.destroy(cb);
        for (self.render_passes.items) |rp| gpa.destroy(rp);
        self.command_buffers.deinit(gpa);
        self.free_command_buffers.deinit(gpa);
        self.render_passes.deinit(gpa);
        self.free_render_passes.deinit(gpa);

        var buffers = self.buffers.iterator();
        while (buffers.next()) |e| gpa.free(e.value.storage);
        var bgls = self.bind_group_layouts.iterator();
        while (bgls.next()) |e| gpa.free(e.value.entries);
        var bgs = self.bind_groups.iterator();
        while (bgs.next()) |e| gpa.free(e.value.entries);
        var pls = self.pipeline_layouts.iterator();
        while (pls.next()) |e| gpa.free(e.value.bind_group_layouts);
        var ps = self.pipelines.iterator();
        while (ps.next()) |e| gpa.free(e.value.color_formats);

        self.buffers.deinit(gpa);
        self.textures.deinit(gpa);
        self.samplers.deinit(gpa);
        self.shaders.deinit(gpa);
        self.bind_group_layouts.deinit(gpa);
        self.bind_groups.deinit(gpa);
        self.pipeline_layouts.deinit(gpa);
        self.pipelines.deinit(gpa);

        self.clearViolations();
        self.violation_list.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn capabilities(self: *Device) command.Capabilities {
        return .{
            .max_texture_dimension = 16384,
            .max_bind_groups = pipeline.max_bind_groups,
            .max_inline_constant_bytes = pipeline.max_inline_constant_bytes,
            .max_vertex_buffers = max_vertex_buffers,
            // Deliberately false. The null backend has no memory at all, and claiming
            // unified would invite exactly the habit rule 2 exists to prevent.
            .unified_memory = false,
            .runtime_shader_compilation = true,
            .surface_format = if (self.textures.getConst(self.surface_texture)) |t|
                t.desc.format
            else
                .bgra8_unorm_srgb,
        };
    }

    // -- violations ----------------------------------------------------------------

    fn violate(self: *Device, rule: Rule, comptime fmt: []const u8, args: anytype) void {
        const detail = std.fmt.allocPrint(self.gpa, fmt, args) catch "out of memory formatting violation";
        self.violation_list.append(self.gpa, .{ .rule = rule, .detail = detail }) catch {
            self.gpa.free(detail);
            return;
        };
        if (self.log_violations) {
            log.err("rhi validation: rule {d} ({t}): " ++ fmt, .{ @intFromEnum(rule), rule } ++ args);
        }
    }

    pub fn violations(self: *Device) []const Violation {
        return self.violation_list.items;
    }

    pub fn violationCount(self: *Device) usize {
        return self.violation_list.items.len;
    }

    pub fn hasViolation(self: *Device, rule: Rule) bool {
        for (self.violation_list.items) |v| {
            if (v.rule == rule) return true;
        }
        return false;
    }

    pub fn clearViolations(self: *Device) void {
        for (self.violation_list.items) |v| {
            if (!std.mem.eql(u8, v.detail, "out of memory formatting violation")) self.gpa.free(v.detail);
        }
        self.violation_list.clearRetainingCapacity();
    }

    /// The frame index the GPU is known to have finished.
    ///
    /// A real backend asks the GPU. Here it is exactly what the frame ring guarantees:
    /// by the time frame N begins, frame `N - frames_in_flight` must have completed,
    /// because `beginFrame` would otherwise have waited for it.
    fn completedFrame(self: *Device) u64 {
        return self.frame_index -| self.desc.frames_in_flight;
    }

    fn inFlight(self: *Device, last_used: u64) bool {
        return last_used > self.completedFrame();
    }

    // -- buffers -------------------------------------------------------------------

    pub fn createBuffer(self: *Device, desc: resource.BufferDesc) interface.ResourceError!resource.BufferHandle {
        // An invalid descriptor, reported through the error the interface already
        // defines for it. Deliberately *not* a violation record: the ten rules are the
        // validation backend's whole remit, and zero-size is not among them.
        if (desc.size == 0) return error.InvalidDescriptor;
        const storage = try self.gpa.alloc(u8, @intCast(desc.size));
        @memset(storage, 0);
        errdefer self.gpa.free(storage);
        return self.buffers.add(self.gpa, .{ .desc = desc, .storage = storage });
    }

    pub fn destroyBuffer(self: *Device, handle: resource.BufferHandle) void {
        const state = self.buffers.getConst(handle) orelse return;
        // Rule 9: a resource the GPU may still be reading must not be released.
        if (self.inFlight(state.last_frame_used)) {
            self.violate(.lifetime, "buffer '{s}' destroyed while frame {d} is in flight (completed: {d})", .{
                state.desc.label, state.last_frame_used, self.completedFrame(),
            });
        }
        self.gpa.free(state.storage);
        _ = self.buffers.remove(handle);
    }

    pub fn mapBuffer(self: *Device, handle: resource.BufferHandle) interface.MapError![]u8 {
        const state = self.buffers.get(handle) orelse return error.InvalidHandle;

        // Rule 2: the rule that stops unified memory from becoming a habit.
        if (!state.desc.memory.isMappable()) {
            self.violate(.device_local_mapped, "buffer '{s}' is device_local and cannot be mapped; use an upload buffer and a copy", .{state.desc.label});
            return error.NotMappable;
        }
        // Rule 3: writing to memory a frame still in flight may be reading.
        if (self.inFlight(state.last_frame_used)) {
            self.violate(.frame_ring, "buffer '{s}' mapped while frame {d} is still in flight (completed: {d})", .{
                state.desc.label, state.last_frame_used, self.completedFrame(),
            });
        }
        state.mapped = true;
        return state.storage;
    }

    pub fn unmapBuffer(self: *Device, handle: resource.BufferHandle) void {
        if (self.buffers.get(handle)) |state| state.mapped = false;
    }

    // -- textures ------------------------------------------------------------------

    pub fn createTexture(self: *Device, desc: resource.TextureDesc) interface.ResourceError!resource.TextureHandle {
        if (desc.size.isEmpty()) return error.InvalidDescriptor;
        return self.textures.add(self.gpa, .{ .desc = desc, .state = desc.initial_state });
    }

    pub fn destroyTexture(self: *Device, handle: resource.TextureHandle) void {
        const state = self.textures.getConst(handle) orelse return;
        if (self.inFlight(state.last_frame_used)) {
            self.violate(.lifetime, "texture '{s}' destroyed while frame {d} is in flight (completed: {d})", .{
                state.desc.label, state.last_frame_used, self.completedFrame(),
            });
        }
        _ = self.textures.remove(handle);
    }

    // -- samplers and shaders ------------------------------------------------------

    pub fn createSampler(self: *Device, desc: resource.SamplerDesc) interface.ResourceError!resource.SamplerHandle {
        return self.samplers.add(self.gpa, .{ .desc = desc });
    }

    pub fn destroySampler(self: *Device, handle: resource.SamplerHandle) void {
        _ = self.samplers.remove(handle);
    }

    pub fn createShaderModule(self: *Device, desc: resource.ShaderModuleDesc) interface.ResourceError!resource.ShaderModuleHandle {
        // The null backend compiles nothing, so any bytes are acceptable — but empty
        // bytes are a caller mistake worth reporting rather than accepting silently.
        if (desc.bytes.len == 0) return error.ShaderCompilationFailed;
        return self.shaders.add(self.gpa, .{ .label = desc.label, .from_source = false });
    }

    pub fn createShaderModuleFromSource(self: *Device, desc: resource.ShaderSourceDesc) interface.ResourceError!resource.ShaderModuleHandle {
        if (desc.source.len == 0) return error.ShaderCompilationFailed;
        return self.shaders.add(self.gpa, .{ .label = desc.label, .from_source = true });
    }

    pub fn destroyShaderModule(self: *Device, handle: resource.ShaderModuleHandle) void {
        _ = self.shaders.remove(handle);
    }

    // -- binding -------------------------------------------------------------------

    pub fn createBindGroupLayout(self: *Device, desc: pipeline.BindGroupLayoutDesc) interface.ResourceError!pipeline.BindGroupLayoutHandle {
        const entries = try self.gpa.dupe(pipeline.BindGroupLayoutEntry, desc.entries);
        errdefer self.gpa.free(entries);
        return self.bind_group_layouts.add(self.gpa, .{ .entries = entries });
    }

    pub fn destroyBindGroupLayout(self: *Device, handle: pipeline.BindGroupLayoutHandle) void {
        const state = self.bind_group_layouts.getConst(handle) orelse return;
        self.gpa.free(state.entries);
        _ = self.bind_group_layouts.remove(handle);
    }

    pub fn createBindGroup(self: *Device, desc: pipeline.BindGroupDesc) interface.ResourceError!pipeline.BindGroupHandle {
        const layout = self.bind_group_layouts.getConst(desc.layout) orelse return error.InvalidDescriptor;

        // Rule 4, at creation. Read as part of "built for the layout" rather than as a new
        // rule: a group whose entries do not satisfy its own layout was never built for it,
        // and Vulkan rejects exactly this when the descriptor set is written. Catching it
        // here gives a far better error than catching it at the draw.
        for (layout.entries) |want| {
            const found = for (desc.entries) |got| {
                if (got.binding == want.binding) break got;
            } else {
                self.violate(.bind_group_compatibility, "bind group '{s}' is missing binding {d} required by its layout", .{ desc.label, want.binding });
                return error.InvalidDescriptor;
            };
            if (@as(pipeline.BindingType, found.resource) != want.type) {
                self.violate(.bind_group_compatibility, "bind group '{s}' binding {d} is {t}, layout requires {t}", .{
                    desc.label, want.binding, @as(pipeline.BindingType, found.resource), want.type,
                });
                return error.InvalidDescriptor;
            }
        }

        const entries = try self.gpa.dupe(pipeline.BindGroupEntry, desc.entries);
        errdefer self.gpa.free(entries);
        return self.bind_groups.add(self.gpa, .{ .layout = desc.layout, .entries = entries });
    }

    pub fn destroyBindGroup(self: *Device, handle: pipeline.BindGroupHandle) void {
        const state = self.bind_groups.getConst(handle) orelse return;
        if (self.inFlight(state.last_frame_used)) {
            self.violate(.lifetime, "bind group destroyed while frame {d} is in flight (completed: {d})", .{
                state.last_frame_used, self.completedFrame(),
            });
        }
        self.gpa.free(state.entries);
        _ = self.bind_groups.remove(handle);
    }

    pub fn createPipelineLayout(self: *Device, desc: pipeline.PipelineLayoutDesc) interface.ResourceError!pipeline.PipelineLayoutHandle {
        // Rule 10, the half that is checkable up front.
        if (desc.bind_group_layouts.len > pipeline.max_bind_groups) {
            self.violate(.limits, "pipeline layout '{s}' declares {d} bind groups; at most {d} are guaranteed", .{
                desc.label, desc.bind_group_layouts.len, pipeline.max_bind_groups,
            });
            return error.InvalidDescriptor;
        }
        if (desc.inline_constant_bytes > pipeline.max_inline_constant_bytes) {
            self.violate(.limits, "pipeline layout '{s}' declares {d} inline constant bytes; at most {d} are guaranteed", .{
                desc.label, desc.inline_constant_bytes, pipeline.max_inline_constant_bytes,
            });
            return error.InvalidDescriptor;
        }

        const layouts = try self.gpa.dupe(pipeline.BindGroupLayoutHandle, desc.bind_group_layouts);
        errdefer self.gpa.free(layouts);
        return self.pipeline_layouts.add(self.gpa, .{
            .bind_group_layouts = layouts,
            .inline_constant_bytes = desc.inline_constant_bytes,
        });
    }

    pub fn destroyPipelineLayout(self: *Device, handle: pipeline.PipelineLayoutHandle) void {
        const state = self.pipeline_layouts.getConst(handle) orelse return;
        self.gpa.free(state.bind_group_layouts);
        _ = self.pipeline_layouts.remove(handle);
    }

    pub fn createRenderPipeline(self: *Device, desc: pipeline.RenderPipelineDesc) interface.ResourceError!pipeline.RenderPipelineHandle {
        if (self.pipeline_layouts.getConst(desc.layout) == null) return error.InvalidDescriptor;
        if (self.shaders.getConst(desc.vertex_shader) == null) return error.InvalidDescriptor;
        if (self.shaders.getConst(desc.fragment_shader) == null) return error.InvalidDescriptor;

        // A colour target with a depth format, or the reverse, is rejected by every real
        // backend; catching it at creation beats catching it as a pass mismatch.
        for (desc.color_targets) |t| {
            if (!t.format.isColor()) {
                self.violate(.attachment_format, "pipeline '{s}' uses depth format {t} as a colour target", .{ desc.label, t.format });
                return error.InvalidDescriptor;
            }
        }
        if (desc.depth_stencil) |d| {
            if (!d.format.isDepth()) {
                self.violate(.attachment_format, "pipeline '{s}' uses colour format {t} as a depth target", .{ desc.label, d.format });
                return error.InvalidDescriptor;
            }
        }

        const formats = try self.gpa.alloc(format.TextureFormat, desc.color_targets.len);
        errdefer self.gpa.free(formats);
        for (desc.color_targets, 0..) |t, i| formats[i] = t.format;

        return self.pipelines.add(self.gpa, .{
            .layout = desc.layout,
            .color_formats = formats,
            .depth_format = if (desc.depth_stencil) |d| d.format else null,
            .vertex_buffer_count = @intCast(desc.vertex_buffers.len),
        });
    }

    pub fn destroyRenderPipeline(self: *Device, handle: pipeline.RenderPipelineHandle) void {
        const state = self.pipelines.getConst(handle) orelse return;
        self.gpa.free(state.color_formats);
        _ = self.pipelines.remove(handle);
    }

    // -- the frame ring ------------------------------------------------------------

    pub fn beginFrame(self: *Device) interface.FrameError!command.FrameContext {
        // Rule 8, read as covering recording structure at every level. A frame is the
        // outermost recording scope.
        if (self.in_frame) {
            self.violate(.encoder_discipline, "beginFrame called while frame {d} is still open", .{self.frame_index});
        }
        self.in_frame = true;
        self.frame_index += 1;
        self.frame_slot = @intCast((self.frame_index - 1) % self.desc.frames_in_flight);

        // The surface arrives with nothing worth preserving, which is what makes the
        // first transition of the frame free on every backend.
        if (self.textures.get(self.surface_texture)) |t| t.state = .undefined;

        return .{
            .surface_texture = self.surface_texture,
            .slot = self.frame_slot,
            .index = self.frame_index,
        };
    }

    pub fn endFrame(self: *Device) interface.FrameError!void {
        if (!self.in_frame) {
            self.violate(.encoder_discipline, "endFrame called with no frame open", .{});
            return;
        }
        self.in_frame = false;
    }

    pub fn resizeSurface(self: *Device, size: resource.Extent2D) interface.FrameError!void {
        if (size.isEmpty()) return;
        self.surface_size = size;
        if (self.textures.get(self.surface_texture)) |t| {
            t.desc.size = size;
            t.state = .undefined;
        }
    }

    // -- recording -----------------------------------------------------------------

    pub fn beginCommandBuffer(self: *Device) interface.CommandError!*CommandBuffer {
        const cb = if (self.free_command_buffers.pop()) |reused| reused else blk: {
            const fresh = try self.gpa.create(CommandBuffer);
            try self.command_buffers.append(self.gpa, fresh);
            break :blk fresh;
        };
        cb.* = .{
            .device = self,
            .violations_at_start = self.violation_list.items.len,
        };
        return cb;
    }

    fn recycleCommandBuffer(self: *Device, cb: *CommandBuffer) void {
        self.free_command_buffers.append(self.gpa, cb) catch {};
    }

    fn acquireRenderPass(self: *Device) !*RenderPass {
        if (self.free_render_passes.pop()) |reused| return reused;
        const fresh = try self.gpa.create(RenderPass);
        try self.render_passes.append(self.gpa, fresh);
        return fresh;
    }

    fn touchBuffer(self: *Device, handle: resource.BufferHandle) void {
        if (self.buffers.get(handle)) |b| b.last_frame_used = self.frame_index;
    }

    fn touchTexture(self: *Device, handle: resource.TextureHandle) void {
        if (self.textures.get(handle)) |t| t.last_frame_used = self.frame_index;
    }
};

// -- command buffer ------------------------------------------------------------------

pub const CommandBuffer = struct {
    device: *Device,
    violations_at_start: usize = 0,
    open_pass: bool = false,
    submitted: bool = false,

    pub fn beginRenderPass(self: *CommandBuffer, desc: command.RenderPassDesc) interface.CommandError!*RenderPass {
        const dev = self.device;

        // Rule 8: Metal cannot nest encoders, so neither can the RHI.
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "render pass '{s}' begun while another is still open", .{desc.label});
        }
        if (self.submitted) {
            dev.violate(.encoder_discipline, "render pass '{s}' recorded into an already-submitted command buffer", .{desc.label});
        }
        assert.debugOnly(
            desc.color.len <= max_color_attachments,
            "render pass has {d} colour attachments; the backend supports {d}",
            .{ desc.color.len, max_color_attachments },
        );

        const pass = dev.acquireRenderPass() catch return error.OutOfMemory;
        pass.* = .{ .device = dev, .cmd = self, .label = desc.label };

        for (desc.color, 0..) |att, i| {
            const tex = dev.textures.get(att.texture) orelse {
                dev.violate(.lifetime, "render pass '{s}' colour attachment {d} names a destroyed texture", .{ desc.label, i });
                continue;
            };
            // Rule 7, the half about the attachment itself.
            if (!tex.desc.format.isColor()) {
                dev.violate(.attachment_format, "render pass '{s}' colour attachment {d} has depth format {t}", .{ desc.label, i, tex.desc.format });
            }
            checkTransition(dev, tex, att.initial_state, att.final_state, desc.label, "colour attachment");
            tex.last_frame_used = dev.frame_index;
            pass.color_formats[i] = tex.desc.format;
        }
        pass.color_count = desc.color.len;

        if (desc.depth) |att| {
            if (dev.textures.get(att.texture)) |tex| {
                if (!tex.desc.format.isDepth()) {
                    dev.violate(.attachment_format, "render pass '{s}' depth attachment has colour format {t}", .{ desc.label, tex.desc.format });
                }
                checkTransition(dev, tex, att.initial_state, att.final_state, desc.label, "depth attachment");
                tex.last_frame_used = dev.frame_index;
                pass.depth_format = tex.desc.format;
            }
        }

        self.open_pass = true;
        return pass;
    }

    /// Rule 1: the declared arrival state must match what has actually been tracked.
    fn checkTransition(
        dev: *Device,
        tex: *TextureState,
        initial: resource.ResourceState,
        final: resource.ResourceState,
        label: []const u8,
        what: []const u8,
    ) void {
        // Arriving as `undefined` is always legal: it says the contents are not worth
        // preserving, which cannot be wrong about what is already there.
        if (initial != .undefined and tex.state != initial) {
            dev.violate(.resource_state, "'{s}' {s} '{s}' declares initial state {t} but is tracked as {t}", .{
                label, what, tex.desc.label, initial, tex.state,
            });
        }
        tex.state = final;
    }

    pub fn textureBarrier(self: *CommandBuffer, barriers: []const command.TextureBarrier) interface.CommandError!void {
        const dev = self.device;
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "barrier recorded inside an open render pass", .{});
        }
        for (barriers) |b| {
            const tex = dev.textures.get(b.texture) orelse continue;
            if (b.from != .undefined and tex.state != b.from) {
                dev.violate(.resource_state, "barrier on '{s}' declares from {t} but it is tracked as {t}", .{
                    tex.desc.label, b.from, tex.state,
                });
            }
            tex.state = b.to;
            tex.last_frame_used = dev.frame_index;
        }
    }

    pub fn bufferBarrier(self: *CommandBuffer, barriers: []const command.BufferBarrier) interface.CommandError!void {
        const dev = self.device;
        for (barriers) |b| {
            const buf = dev.buffers.get(b.buffer) orelse continue;
            if (b.from != .undefined and buf.state != b.from) {
                dev.violate(.resource_state, "barrier on buffer '{s}' declares from {t} but it is tracked as {t}", .{
                    buf.desc.label, b.from, buf.state,
                });
            }
            buf.state = b.to;
            buf.last_frame_used = dev.frame_index;
        }
    }

    pub fn copyBufferToBuffer(self: *CommandBuffer, copy: command.BufferCopy) interface.CommandError!void {
        const dev = self.device;
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "copy recorded inside an open render pass", .{});
        }
        // Usage-flag conformance is deliberately unchecked. It is a genuine invariant of
        // the abstraction — Vulkan and D3D12 both treat a mismatch as undefined behaviour —
        // but it is not one of the ten documented rules, and enforcing it here would make
        // this backend stricter than the contract it exists to police. Recorded as an open
        // question in `docs/design/rhi.md` §13.
        dev.touchBuffer(copy.src);
        dev.touchBuffer(copy.dst);
    }

    pub fn copyBufferToTexture(self: *CommandBuffer, copy: command.BufferToTextureCopy) interface.CommandError!void {
        const dev = self.device;
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "copy recorded inside an open render pass", .{});
        }
        if (dev.textures.get(copy.dst)) |dst| {
            if (dst.state != .copy_dst) {
                dev.violate(.resource_state, "texture '{s}' is tracked as {t}, not copy_dst, at a buffer-to-texture copy", .{
                    dst.desc.label, dst.state,
                });
            }
            dst.last_frame_used = dev.frame_index;
        }
        dev.touchBuffer(copy.src);
    }

    pub fn submit(self: *CommandBuffer) interface.CommandError!void {
        const dev = self.device;
        // Rule 8: every pass ended, and nothing submitted twice.
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "command buffer submitted with a render pass still open", .{});
        }
        if (self.submitted) {
            dev.violate(.encoder_discipline, "command buffer submitted twice", .{});
        }
        self.submitted = true;

        const failed = dev.violation_list.items.len > self.violations_at_start;
        dev.recycleCommandBuffer(self);
        if (failed) return error.ValidationFailed;
    }
};

// -- render pass ---------------------------------------------------------------------

pub const RenderPass = struct {
    device: *Device,
    cmd: *CommandBuffer,
    label: []const u8 = "",

    color_formats: [max_color_attachments]format.TextureFormat = @splat(.rgba8_unorm),
    color_count: usize = 0,
    depth_format: ?format.TextureFormat = null,
    ended: bool = false,

    pipeline_handle: pipeline.RenderPipelineHandle = .none,
    bound_groups: [pipeline.max_bind_groups]pipeline.BindGroupHandle = @splat(.none),
    bound_vertex_buffers: [max_vertex_buffers]resource.BufferHandle = @splat(.none),
    index_buffer: resource.BufferHandle = .none,
    inline_constants_set: bool = false,
    inline_constant_bytes: u32 = 0,

    pub fn setPipeline(self: *RenderPass, handle: pipeline.RenderPipelineHandle) void {
        const dev = self.device;
        const new_layout = if (dev.pipelines.getConst(handle)) |p| p.layout else pipeline.PipelineLayoutHandle.none;
        const old_layout = if (dev.pipelines.getConst(self.pipeline_handle)) |p| p.layout else pipeline.PipelineLayoutHandle.none;

        // Inline constants are pipeline-layout-scoped in Vulkan: binding a pipeline with a
        // different layout invalidates them. Pretending otherwise would produce an engine
        // that works on Metal and renders garbage elsewhere (design §9).
        if (!self.pipeline_handle.isNone() and !new_layout.eql(old_layout)) {
            self.inline_constants_set = false;
        }
        self.pipeline_handle = handle;
    }

    pub fn setBindGroup(self: *RenderPass, index: u32, group: pipeline.BindGroupHandle) void {
        const dev = self.device;
        // Rule 10: at most four groups, because that is all Vulkan guarantees.
        if (index >= pipeline.max_bind_groups) {
            dev.violate(.limits, "bind group index {d} exceeds the guaranteed maximum of {d}", .{ index, pipeline.max_bind_groups });
            return;
        }
        self.bound_groups[index] = group;
        if (dev.bind_groups.get(group)) |g| {
            g.last_frame_used = dev.frame_index;
            // Rule 1: a texture bound for sampling must actually be in shader_read.
            for (g.entries) |e| {
                switch (e.resource) {
                    .sampled_texture => |t| {
                        if (dev.textures.getConst(t)) |tex| {
                            if (tex.state != .shader_read) {
                                dev.violate(.resource_state, "texture '{s}' is bound for sampling but is tracked as {t}, not shader_read", .{
                                    tex.desc.label, tex.state,
                                });
                            }
                        }
                        dev.touchTexture(t);
                    },
                    .uniform_buffer, .storage_buffer => |b| dev.touchBuffer(b.buffer),
                    .sampler => {},
                }
            }
        }
    }

    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: resource.BufferHandle, offset: u64) void {
        _ = offset;
        const dev = self.device;
        assert.debugOnly(slot < max_vertex_buffers, "vertex buffer slot {d} exceeds backend capacity {d}", .{ slot, max_vertex_buffers });
        if (slot >= max_vertex_buffers) return;

        self.bound_vertex_buffers[slot] = buffer;
        dev.touchBuffer(buffer);
    }

    pub fn setIndexBuffer(self: *RenderPass, buffer: resource.BufferHandle, index_format: format.IndexFormat, offset: u64) void {
        _ = index_format;
        _ = offset;
        const dev = self.device;
        self.index_buffer = buffer;
        dev.touchBuffer(buffer);
    }

    /// Push-constant-style, and nothing more. The bytes are copied at the call, the value
    /// is encoder state that does not survive the pass, and writes replace the whole
    /// block. See `pipeline.max_inline_constant_bytes` for the full contract.
    pub fn setInlineConstants(self: *RenderPass, bytes: []const u8) void {
        const dev = self.device;

        // Rule 10: never more than the guaranteed maximum...
        if (bytes.len > pipeline.max_inline_constant_bytes) {
            dev.violate(.limits, "{d} inline constant bytes exceeds the guaranteed maximum of {d}", .{
                bytes.len, pipeline.max_inline_constant_bytes,
            });
            return;
        }
        // ...and never more than the bound pipeline's layout declares.
        if (dev.pipelines.getConst(self.pipeline_handle)) |p| {
            if (dev.pipeline_layouts.getConst(p.layout)) |layout| {
                if (bytes.len > layout.inline_constant_bytes) {
                    dev.violate(.limits, "{d} inline constant bytes exceeds the {d} the bound pipeline's layout declares", .{
                        bytes.len, layout.inline_constant_bytes,
                    });
                    return;
                }
            }
        }
        self.inline_constants_set = true;
        self.inline_constant_bytes = @intCast(bytes.len);
    }

    pub fn setViewport(self: *RenderPass, viewport: command.Viewport) void {
        _ = self;
        _ = viewport;
    }

    pub fn setScissor(self: *RenderPass, rect: command.ScissorRect) void {
        _ = self;
        _ = rect;
    }

    pub fn draw(self: *RenderPass, params: command.Draw) void {
        _ = params;
        self.validateDraw(false);
    }

    pub fn drawIndexed(self: *RenderPass, params: command.DrawIndexed) void {
        _ = params;
        self.validateDraw(true);
    }

    /// Rules 5, 6 and 7, all of which are only checkable at the moment of a draw.
    fn validateDraw(self: *RenderPass, indexed: bool) void {
        const dev = self.device;

        if (self.ended) {
            dev.violate(.encoder_discipline, "draw recorded into pass '{s}' after it ended", .{self.label});
            return;
        }

        const pipe = dev.pipelines.getConst(self.pipeline_handle) orelse {
            dev.violate(.incomplete_bindings, "draw in pass '{s}' with no pipeline bound", .{self.label});
            return;
        };
        const layout = dev.pipeline_layouts.getConst(pipe.layout) orelse return;

        // Rule 7: the pass's attachment formats must match the pipeline's.
        if (pipe.color_formats.len != self.color_count) {
            dev.violate(.attachment_format, "pipeline expects {d} colour attachments, pass '{s}' has {d}", .{
                pipe.color_formats.len, self.label, self.color_count,
            });
        } else {
            for (pipe.color_formats, 0..) |want, i| {
                if (want != self.color_formats[i]) {
                    dev.violate(.attachment_format, "pipeline colour attachment {d} is {t}, pass '{s}' provides {t}", .{
                        i, want, self.label, self.color_formats[i],
                    });
                }
            }
        }
        if (pipe.depth_format) |want| {
            if (self.depth_format) |got| {
                if (want != got) {
                    dev.violate(.attachment_format, "pipeline depth format is {t}, pass '{s}' provides {t}", .{ want, self.label, got });
                }
            } else {
                dev.violate(.attachment_format, "pipeline expects a depth attachment, pass '{s}' has none", .{self.label});
            }
        }

        // Rule 5: every group the layout declares must be bound, and inline constants the
        // layout declares must have been set since the last layout-changing bind.
        for (layout.bind_group_layouts, 0..) |declared, i| {
            if (declared.isNone()) continue;
            const bound = self.bound_groups[i];
            if (bound.isNone()) {
                dev.violate(.incomplete_bindings, "draw in pass '{s}' with nothing bound to group {d}, which the layout requires", .{ self.label, i });
                continue;
            }
            // Rule 4: the group must have been built for the layout the pipeline declares.
            const group = dev.bind_groups.getConst(bound) orelse continue;
            if (!group.layout.eql(declared)) {
                dev.violate(.bind_group_compatibility, "group {d} in pass '{s}' was built for a different layout than the pipeline declares", .{ i, self.label });
            }
        }
        if (layout.inline_constant_bytes > 0 and !self.inline_constants_set) {
            dev.violate(.incomplete_bindings, "draw in pass '{s}' whose layout declares {d} inline constant bytes that were never set", .{
                self.label, layout.inline_constant_bytes,
            });
        }

        // Rule 6: every vertex buffer the pipeline declares must be bound.
        var slot: u32 = 0;
        while (slot < pipe.vertex_buffer_count) : (slot += 1) {
            if (self.bound_vertex_buffers[slot].isNone()) {
                dev.violate(.vertex_layout, "draw in pass '{s}' with no buffer bound to vertex slot {d}, which the pipeline declares", .{ self.label, slot });
            }
        }
        if (indexed and self.index_buffer.isNone()) {
            dev.violate(.vertex_layout, "indexed draw in pass '{s}' with no index buffer bound", .{self.label});
        }
    }

    pub fn end(self: *RenderPass) void {
        const dev = self.device;
        if (self.ended) {
            dev.violate(.encoder_discipline, "render pass '{s}' ended twice", .{self.label});
            return;
        }
        self.ended = true;
        self.cmd.open_pass = false;
        dev.free_render_passes.append(dev.gpa, self) catch {};
    }
};

comptime {
    interface.check(@This(), "null");
}

// -- tests ---------------------------------------------------------------------------
//
// One or more per rule in `docs/design/rhi.md` §11, plus positive tests for each, because
// a validation backend that rejects legal usage is worse than one that rejects nothing:
// it makes the interface a fiction and turns the first real backend into the actual
// specification, which is the failure ADR-0003 exists to prevent.

const testing = std.testing;

/// A device with violation logging off. These tests provoke violations deliberately, and
/// Zig's test runner treats an error-level log as a test failure — correctly, and not
/// something to opt out of globally just to keep a test quiet.
fn quietDevice() !*Device {
    const dev = try Device.init(testing.allocator, .{});
    dev.log_violations = false;
    return dev;
}

/// The smallest complete, valid setup: a pipeline that draws to the surface with no
/// bindings, no vertex buffers and no inline constants.
const Fixture = struct {
    dev: *Device,
    vs: resource.ShaderModuleHandle,
    fs: resource.ShaderModuleHandle,
    layout: pipeline.PipelineLayoutHandle,
    pipe: pipeline.RenderPipelineHandle,

    fn init() !Fixture {
        const dev = try quietDevice();
        const vs = try dev.createShaderModule(.{ .label = "vs", .bytes = "stub" });
        const fs = try dev.createShaderModule(.{ .label = "fs", .bytes = "stub" });
        const layout = try dev.createPipelineLayout(.{ .label = "empty" });
        const pipe = try dev.createRenderPipeline(.{
            .label = "simple",
            .layout = layout,
            .vertex_shader = vs,
            .fragment_shader = fs,
            .color_targets = &.{.{ .format = .bgra8_unorm_srgb }},
        });
        return .{ .dev = dev, .vs = vs, .fs = fs, .layout = layout, .pipe = pipe };
    }

    fn deinit(self: *Fixture) void {
        self.dev.deinit();
    }
};

test "a complete valid frame produces no violations" {
    // The most important test in the file. If this ever fails, the validation backend has
    // started holding an opinion the abstraction does not state.
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .label = "main",
        .color = &.{.{
            .texture = frame.surface_texture,
            .load = .{ .clear = .{ .color = .{ 0, 0, 0, 1 } } },
            .store = .store,
            .initial_state = .undefined,
            .final_state = .present,
        }},
    });
    pass.setViewport(.{ .width = 1280, .height = 720 });
    pass.setScissor(.{ .width = 1280, .height = 720 });
    pass.setPipeline(fx.pipe);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();
    try cmd.submit();
    try fx.dev.endFrame();

    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

test "legal but unusual usage is still legal" {
    // Guards the same property from the other direction: discarding instead of storing,
    // binding a vertex buffer no pipeline declared, and a layout that uses no groups at
    // all are all permitted by the design document, so none may be reported.
    var fx = try Fixture.init();
    defer fx.deinit();

    const spare = try fx.dev.createBuffer(.{ .label = "spare", .size = 64, .usage = .{ .vertex = true } });
    defer fx.dev.destroyBuffer(spare);

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{
            .texture = frame.surface_texture,
            .load = .discard,
            .store = .discard,
            .initial_state = .undefined,
            .final_state = .present,
        }},
    });
    pass.setPipeline(fx.pipe);
    pass.setVertexBuffer(0, spare, 0); // the pipeline declares none; binding one anyway is fine
    pass.draw(.{ .vertex_count = 3, .instance_count = 100 });
    pass.end();
    try cmd.submit();
    try fx.dev.endFrame();

    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

// -- rule 1: resource state ----------------------------------------------------------

test "rule 1: a pass declaring the wrong initial state is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    // beginFrame leaves the surface `undefined`; claiming it arrives as shader_read is
    // exactly the mistake Vulkan turns into garbage pixels and Metal ignores.
    var pass = try cmd.beginRenderPass(.{
        .label = "wrong-state",
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .shader_read, .final_state = .present }},
    });
    pass.end();
    try testing.expectError(error.ValidationFailed, cmd.submit());

    try testing.expect(fx.dev.hasViolation(.resource_state));
}

test "rule 1: sampling a texture that is still a render target is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const offscreen = try dev.createTexture(.{
        .label = "offscreen",
        .size = .{ .width = 64, .height = 64 },
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true, .sampled = true },
    });
    const bgl = try dev.createBindGroupLayout(.{
        .entries = &.{.{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } }},
    });
    const group = try dev.createBindGroup(.{
        .layout = bgl,
        .entries = &.{.{ .binding = 0, .resource = .{ .sampled_texture = offscreen } }},
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();

    // Render into it, leaving it as a render target...
    var first = try cmd.beginRenderPass(.{
        .label = "offscreen",
        .color = &.{.{ .texture = offscreen, .initial_state = .undefined, .final_state = .render_target }},
    });
    first.end();

    // ...then sample it without transitioning. The missing barrier is the bug.
    var second = try cmd.beginRenderPass(.{ .label = "sample", .color = &.{} });
    second.setBindGroup(0, group);
    second.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(dev.hasViolation(.resource_state));
}

test "rule 1: the correct render-then-sample sequence is accepted" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const offscreen = try dev.createTexture(.{
        .label = "offscreen",
        .size = .{ .width = 64, .height = 64 },
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true, .sampled = true },
    });
    const bgl = try dev.createBindGroupLayout(.{
        .entries = &.{.{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } }},
    });
    const group = try dev.createBindGroup(.{
        .layout = bgl,
        .entries = &.{.{ .binding = 0, .resource = .{ .sampled_texture = offscreen } }},
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();

    var first = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = offscreen, .initial_state = .undefined, .final_state = .render_target }},
    });
    first.end();

    // The barrier that makes it legal, declared between passes and not per draw.
    try cmd.textureBarrier(&.{.{ .texture = offscreen, .from = .render_target, .to = .shader_read }});

    var second = try cmd.beginRenderPass(.{ .color = &.{} });
    second.setBindGroup(0, group);
    second.end();

    try cmd.submit();
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "rule 1: a barrier declaring the wrong source state is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const tex = try dev.createTexture(.{
        .label = "tex",
        .size = .{ .width = 8, .height = 8 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    // It is `undefined`, not `render_target`.
    try cmd.textureBarrier(&.{.{ .texture = tex, .from = .render_target, .to = .shader_read }});
    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(dev.hasViolation(.resource_state));
}

test "rule 1: transitioning from undefined is always legal" {
    // `undefined` means "the contents are not worth preserving", which cannot be wrong
    // about what is already there. Free on every backend, and the correct way to start a
    // frame with a target about to be cleared.
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const tex = try dev.createTexture(.{
        .size = .{ .width = 8, .height = 8 },
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
        .initial_state = .render_target,
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    try cmd.textureBarrier(&.{.{ .texture = tex, .from = .undefined, .to = .shader_read }});
    try cmd.submit();
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

// -- rule 2: device_local is never mapped --------------------------------------------

test "rule 2: a device_local buffer cannot be mapped" {
    // The rule that stops unified memory from becoming a habit that is slow elsewhere.
    var fx = try Fixture.init();
    defer fx.deinit();

    const buf = try fx.dev.createBuffer(.{
        .label = "vertices",
        .size = 256,
        .usage = .{ .vertex = true, .copy_dst = true },
        .memory = .device_local,
    });
    defer fx.dev.destroyBuffer(buf);

    try testing.expectError(error.NotMappable, fx.dev.mapBuffer(buf));
    try testing.expect(fx.dev.hasViolation(.device_local_mapped));
}

test "rule 2: an upload buffer maps, and the memory is real" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const staging = try fx.dev.createBuffer(.{
        .label = "staging",
        .size = 16,
        .usage = .{ .copy_src = true },
        .memory = .upload,
    });
    defer fx.dev.destroyBuffer(staging);

    const bytes = try fx.dev.mapBuffer(staging);
    try testing.expectEqual(@as(usize, 16), bytes.len);
    bytes[0] = 0xAB;
    fx.dev.unmapBuffer(staging);

    // Mapping again returns the same storage, so a test can observe what it wrote.
    const again = try fx.dev.mapBuffer(staging);
    try testing.expectEqual(@as(u8, 0xAB), again[0]);
    fx.dev.unmapBuffer(staging);

    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

test "rule 2: readback memory is mappable too" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const buf = try fx.dev.createBuffer(.{ .size = 8, .usage = .{ .copy_dst = true }, .memory = .readback });
    defer fx.dev.destroyBuffer(buf);
    _ = try fx.dev.mapBuffer(buf);
    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

// -- rule 3: frame ring --------------------------------------------------------------

test "rule 3: writing to memory a frame in flight may be reading is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const staging = try dev.createBuffer(.{
        .label = "per-frame",
        .size = 64,
        .usage = .{ .vertex = true },
        .memory = .upload,
    });

    // Frame 1 references it.
    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(fx.pipe);
    pass.setVertexBuffer(0, staging, 0);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();
    try cmd.submit();
    try dev.endFrame();

    // ...and frame 1 has not completed, so writing it now would race the GPU. The map
    // itself succeeds — an upload buffer *is* mappable — and that is exactly why the
    // timing has to be reported rather than left to the caller to notice. This is the
    // error Metal's completion handlers make it easy to never think about.
    _ = try dev.mapBuffer(staging);
    try testing.expect(dev.hasViolation(.frame_ring));

    // Let the frame drain before tearing down, so this test does not also trip rule 9.
    _ = try dev.beginFrame();
    _ = try dev.beginFrame();
    dev.destroyBuffer(staging);
}

test "rule 3: the same write is fine once the frame has completed" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const staging = try dev.createBuffer(.{ .size = 64, .usage = .{ .vertex = true }, .memory = .upload });

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setVertexBuffer(0, staging, 0);
    pass.end();
    try cmd.submit();
    try dev.endFrame();

    // Two frames in flight, so after two more begins frame 1 is guaranteed complete —
    // which is precisely what beginFrame's wait promises.
    _ = try dev.beginFrame();
    try dev.endFrame();
    _ = try dev.beginFrame();
    try dev.endFrame();

    _ = try dev.mapBuffer(staging);
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
    dev.destroyBuffer(staging);
}

// -- rule 4: bind group compatibility ------------------------------------------------

const TwoLayouts = struct {
    fx: Fixture,
    bgl_a: pipeline.BindGroupLayoutHandle,
    bgl_b: pipeline.BindGroupLayoutHandle,
    group_a: pipeline.BindGroupHandle,
    group_b: pipeline.BindGroupHandle,
    pipe_a: pipeline.RenderPipelineHandle,
    buf: resource.BufferHandle,

    /// Two structurally identical layouts with different identities. Structurally
    /// identical on purpose: it is the *identity* the pipeline declares that matters, and
    /// a check that only compared shapes would pass where Vulkan and D3D12 would not.
    fn init() !TwoLayouts {
        const fx = try Fixture.init();
        const dev = fx.dev;
        const entry: pipeline.BindGroupLayoutEntry = .{
            .binding = 0,
            .type = .uniform_buffer,
            .visibility = .both,
        };
        const bgl_a = try dev.createBindGroupLayout(.{ .label = "a", .entries = &.{entry} });
        const bgl_b = try dev.createBindGroupLayout(.{ .label = "b", .entries = &.{entry} });
        const buf = try dev.createBuffer(.{ .size = 64, .usage = .{ .uniform = true }, .memory = .upload });

        const group_a = try dev.createBindGroup(.{
            .label = "group-a",
            .layout = bgl_a,
            .entries = &.{.{ .binding = 0, .resource = .{ .uniform_buffer = .{ .buffer = buf } } }},
        });
        const group_b = try dev.createBindGroup(.{
            .label = "group-b",
            .layout = bgl_b,
            .entries = &.{.{ .binding = 0, .resource = .{ .uniform_buffer = .{ .buffer = buf } } }},
        });

        const layout_a = try dev.createPipelineLayout(.{ .label = "layout-a", .bind_group_layouts = &.{bgl_a} });
        const pipe_a = try dev.createRenderPipeline(.{
            .label = "pipe-a",
            .layout = layout_a,
            .vertex_shader = fx.vs,
            .fragment_shader = fx.fs,
            .color_targets = &.{.{ .format = .bgra8_unorm_srgb }},
        });

        return .{ .fx = fx, .bgl_a = bgl_a, .bgl_b = bgl_b, .group_a = group_a, .group_b = group_b, .pipe_a = pipe_a, .buf = buf };
    }

    fn deinit(self: *TwoLayouts) void {
        self.fx.deinit();
    }
};

test "rule 4: a bind group built for another layout is caught" {
    var t = try TwoLayouts.init();
    defer t.deinit();
    const dev = t.fx.dev;

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(t.pipe_a);
    pass.setBindGroup(0, t.group_b); // built for bgl_b; the pipeline declares bgl_a
    pass.draw(.{ .vertex_count = 3 });
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(dev.hasViolation(.bind_group_compatibility));
}

test "rule 4: the matching group is accepted" {
    var t = try TwoLayouts.init();
    defer t.deinit();
    const dev = t.fx.dev;

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(t.pipe_a);
    pass.setBindGroup(0, t.group_a);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();
    try cmd.submit();

    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "rule 4: a group that does not satisfy its own layout is refused at creation" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const bgl = try dev.createBindGroupLayout(.{
        .label = "wants-a-texture",
        .entries = &.{.{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } }},
    });
    const buf = try dev.createBuffer(.{ .size = 16, .usage = .{ .uniform = true }, .memory = .upload });
    defer dev.destroyBuffer(buf);

    // A uniform buffer where the layout wants a texture. Vulkan rejects exactly this when
    // the descriptor set is written; catching it here gives a much better error.
    try testing.expectError(error.InvalidDescriptor, dev.createBindGroup(.{
        .layout = bgl,
        .entries = &.{.{ .binding = 0, .resource = .{ .uniform_buffer = .{ .buffer = buf } } }},
    }));
    try testing.expect(dev.hasViolation(.bind_group_compatibility));
}

test "rule 4: a group missing a binding its layout requires is refused" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const bgl = try dev.createBindGroupLayout(.{
        .entries = &.{
            .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
        },
    });
    const tex = try dev.createTexture(.{
        .size = .{ .width = 4, .height = 4 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });

    try testing.expectError(error.InvalidDescriptor, dev.createBindGroup(.{
        .layout = bgl,
        .entries = &.{.{ .binding = 0, .resource = .{ .sampled_texture = tex } }}, // no sampler
    }));
    try testing.expect(dev.hasViolation(.bind_group_compatibility));
}

// -- rule 5: complete bindings -------------------------------------------------------

test "rule 5: a draw missing a required bind group is caught" {
    var t = try TwoLayouts.init();
    defer t.deinit();
    const dev = t.fx.dev;

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(t.pipe_a);
    pass.draw(.{ .vertex_count = 3 }); // group 0 never bound
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(dev.hasViolation(.incomplete_bindings));
}

test "rule 5: a draw with no pipeline at all is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.draw(.{ .vertex_count = 3 });
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(fx.dev.hasViolation(.incomplete_bindings));
}

/// A pipeline whose layout declares inline constants and nothing else.
fn inlinePipeline(fx: *Fixture, bytes: u32, label: []const u8) !pipeline.RenderPipelineHandle {
    const layout = try fx.dev.createPipelineLayout(.{ .label = label, .inline_constant_bytes = bytes });
    return fx.dev.createRenderPipeline(.{
        .label = label,
        .layout = layout,
        .vertex_shader = fx.vs,
        .fragment_shader = fx.fs,
        .color_targets = &.{.{ .format = .bgra8_unorm_srgb }},
    });
}

test "rule 5: a draw missing required inline constants is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pipe = try inlinePipeline(&fx, 64, "wants-constants");

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(pipe);
    pass.draw(.{ .vertex_count = 3 }); // constants never set
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(fx.dev.hasViolation(.incomplete_bindings));
}

test "rule 5: changing to a pipeline with a different layout invalidates inline constants" {
    // Vulkan's real behaviour: push constants are pipeline-layout-scoped. Pretending
    // otherwise produces an engine that works on Metal and renders garbage elsewhere.
    var fx = try Fixture.init();
    defer fx.deinit();
    const first = try inlinePipeline(&fx, 64, "first");
    const second = try inlinePipeline(&fx, 64, "second"); // same size, different layout

    const matrix: [64]u8 = @splat(0);

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(first);
    pass.setInlineConstants(&matrix);
    pass.draw(.{ .vertex_count = 3 }); // fine

    pass.setPipeline(second); // different layout: the block is now invalid
    pass.draw(.{ .vertex_count = 3 }); // not fine
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(fx.dev.hasViolation(.incomplete_bindings));
}

test "rule 5: re-binding the same pipeline does not invalidate inline constants" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pipe = try inlinePipeline(&fx, 64, "stable");
    const matrix: [64]u8 = @splat(0);

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(pipe);
    pass.setInlineConstants(&matrix);
    pass.draw(.{ .vertex_count = 3 });
    pass.setPipeline(pipe); // same layout: still valid
    pass.draw(.{ .vertex_count = 3 });
    pass.end();
    try cmd.submit();

    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

test "rule 5: a pipeline declaring no constants does not require them" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(fx.pipe);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();
    try cmd.submit();
    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

// -- rule 6: vertex layout -----------------------------------------------------------

test "rule 6: a draw missing a declared vertex buffer is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const pipe = try dev.createRenderPipeline(.{
        .label = "needs-vertices",
        .layout = fx.layout,
        .vertex_shader = fx.vs,
        .fragment_shader = fx.fs,
        .vertex_buffers = &.{.{
            .stride = 16,
            .attributes = &.{.{ .location = 0, .offset = 0, .format = .float32x4 }},
        }},
        .color_targets = &.{.{ .format = .bgra8_unorm_srgb }},
    });

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(pipe);
    pass.draw(.{ .vertex_count = 3 }); // slot 0 never bound
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(dev.hasViolation(.vertex_layout));
}

test "rule 6: an indexed draw with no index buffer is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(fx.pipe);
    pass.drawIndexed(.{ .index_count = 6 });
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(fx.dev.hasViolation(.vertex_layout));
}

test "rule 6: a complete indexed draw is accepted" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const indices = try dev.createBuffer(.{ .size = 12, .usage = .{ .index = true }, .memory = .upload });

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(fx.pipe);
    pass.setIndexBuffer(indices, .uint16, 0);
    pass.drawIndexed(.{ .index_count = 6 });
    pass.end();
    try cmd.submit();

    try testing.expectEqual(@as(usize, 0), dev.violationCount());
    try dev.endFrame();
    _ = try dev.beginFrame();
    _ = try dev.beginFrame();
    dev.destroyBuffer(indices);
}

// -- rule 7: attachment formats ------------------------------------------------------

test "rule 7: a pipeline whose colour format differs from the pass is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    // The surface is bgra8_unorm_srgb; this pipeline claims rgba8_unorm.
    const pipe = try dev.createRenderPipeline(.{
        .label = "wrong-format",
        .layout = fx.layout,
        .vertex_shader = fx.vs,
        .fragment_shader = fx.fs,
        .color_targets = &.{.{ .format = .rgba8_unorm }},
    });

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(pipe);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(dev.hasViolation(.attachment_format));
}

test "rule 7: an attachment count mismatch is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    _ = frame;
    var cmd = try fx.dev.beginCommandBuffer();
    // The pipeline declares one colour target; this pass has none.
    var pass = try cmd.beginRenderPass(.{ .label = "no-colour", .color = &.{} });
    pass.setPipeline(fx.pipe);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(fx.dev.hasViolation(.attachment_format));
}

test "rule 7: a pipeline expecting depth in a pass without it is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const pipe = try dev.createRenderPipeline(.{
        .label = "needs-depth",
        .layout = fx.layout,
        .vertex_shader = fx.vs,
        .fragment_shader = fx.fs,
        .color_targets = &.{.{ .format = .bgra8_unorm_srgb }},
        .depth_stencil = .{ .format = .depth32_float, .depth_write_enabled = true, .depth_compare = .less },
    });

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(pipe);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(dev.hasViolation(.attachment_format));
}

test "rule 7: a depth format as a colour target is refused at pipeline creation" {
    var fx = try Fixture.init();
    defer fx.deinit();

    try testing.expectError(error.InvalidDescriptor, fx.dev.createRenderPipeline(.{
        .label = "confused",
        .layout = fx.layout,
        .vertex_shader = fx.vs,
        .fragment_shader = fx.fs,
        .color_targets = &.{.{ .format = .depth32_float }},
    }));
    try testing.expect(fx.dev.hasViolation(.attachment_format));
}

test "rule 7: a matching depth pass is accepted" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const depth = try dev.createTexture(.{
        .label = "depth",
        .size = .{ .width = 1280, .height = 720 },
        .format = .depth32_float,
        .usage = .{ .depth_stencil = true },
    });
    const pipe = try dev.createRenderPipeline(.{
        .layout = fx.layout,
        .vertex_shader = fx.vs,
        .fragment_shader = fx.fs,
        .color_targets = &.{.{ .format = .bgra8_unorm_srgb }},
        .depth_stencil = .{ .format = .depth32_float },
    });

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
        .depth = .{ .texture = depth, .initial_state = .undefined, .final_state = .depth_stencil },
    });
    pass.setPipeline(pipe);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();
    try cmd.submit();

    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

// -- rule 8: encoder discipline ------------------------------------------------------

test "rule 8: nested render passes are caught" {
    // Metal cannot nest encoders, so neither can the RHI. Vulkan and D3D12 would allow
    // the sloppier structure, which is exactly why the strictest shape is the one kept.
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var first = try cmd.beginRenderPass(.{
        .label = "outer",
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    var second = try cmd.beginRenderPass(.{ .label = "inner", .color = &.{} });
    second.end();
    first.end();

    try testing.expect(fx.dev.hasViolation(.encoder_discipline));
}

test "rule 8: submitting with a pass still open is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    // Deliberately left open.
    _ = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });

    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(fx.dev.hasViolation(.encoder_discipline));
}

test "rule 8: submitting twice is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();

    _ = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    try cmd.submit();
    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(fx.dev.hasViolation(.encoder_discipline));
}

test "rule 8: ending a pass twice is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.end();
    pass.end();

    try testing.expect(fx.dev.hasViolation(.encoder_discipline));
}

test "rule 8: drawing after the pass ended is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(fx.pipe);
    pass.end();
    pass.draw(.{ .vertex_count = 3 });

    try testing.expect(fx.dev.hasViolation(.encoder_discipline));
}

test "rule 8: beginFrame while a frame is open is caught" {
    // The frame is the outermost recording scope, so the same rule covers it.
    var fx = try Fixture.init();
    defer fx.deinit();

    _ = try fx.dev.beginFrame();
    _ = try fx.dev.beginFrame();
    try testing.expect(fx.dev.hasViolation(.encoder_discipline));
}

test "rule 8: endFrame with no frame open is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.dev.endFrame();
    try testing.expect(fx.dev.hasViolation(.encoder_discipline));
}

test "rule 8: a barrier inside an open pass is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const tex = try dev.createTexture(.{
        .size = .{ .width = 4, .height = 4 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    try cmd.textureBarrier(&.{.{ .texture = tex, .from = .undefined, .to = .shader_read }});
    pass.end();

    try testing.expect(dev.hasViolation(.encoder_discipline));
}

// -- rule 9: lifetime ----------------------------------------------------------------

test "rule 9: destroying a resource a frame in flight references is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const tex = try dev.createTexture(.{
        .label = "target",
        .size = .{ .width = 64, .height = 64 },
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = tex, .initial_state = .undefined, .final_state = .render_target }},
    });
    pass.end();
    try cmd.submit();
    try dev.endFrame();

    // The GPU may still be reading it. This is the error that is unobservable in testing
    // right up until it is a crash on someone else's machine.
    dev.destroyTexture(tex);
    try testing.expect(dev.hasViolation(.lifetime));
}

test "rule 9: destroying it after the frame completed is fine" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const tex = try dev.createTexture(.{
        .size = .{ .width = 64, .height = 64 },
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = tex, .initial_state = .undefined, .final_state = .render_target }},
    });
    pass.end();
    try cmd.submit();
    try dev.endFrame();

    _ = try dev.beginFrame();
    try dev.endFrame();
    _ = try dev.beginFrame();
    try dev.endFrame();

    dev.destroyTexture(tex);
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "rule 9: a pass naming a destroyed texture is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const tex = try dev.createTexture(.{
        .size = .{ .width = 8, .height = 8 },
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
    });
    dev.destroyTexture(tex);

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .label = "dangling",
        .color = &.{.{ .texture = tex, .initial_state = .undefined, .final_state = .render_target }},
    });
    pass.end();

    try testing.expect(dev.hasViolation(.lifetime));
}

// -- rule 10: limits -----------------------------------------------------------------

test "rule 10: more than four bind groups is refused" {
    // Four is what Vulkan guarantees. A five-group design would work on every desktop GPU
    // and fail on hardware nobody here owns.
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const bgl = try dev.createBindGroupLayout(.{ .entries = &.{} });
    try testing.expectError(error.InvalidDescriptor, dev.createPipelineLayout(.{
        .label = "too-many",
        .bind_group_layouts = &.{ bgl, bgl, bgl, bgl, bgl },
    }));
    try testing.expect(dev.hasViolation(.limits));
}

test "rule 10: exactly four bind groups is accepted" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const bgl = try dev.createBindGroupLayout(.{ .entries = &.{} });
    _ = try dev.createPipelineLayout(.{ .bind_group_layouts = &.{ bgl, bgl, bgl, bgl } });
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "rule 10: more than 128 inline constant bytes is refused" {
    var fx = try Fixture.init();
    defer fx.deinit();

    try testing.expectError(error.InvalidDescriptor, fx.dev.createPipelineLayout(.{
        .label = "too-big",
        .inline_constant_bytes = pipeline.max_inline_constant_bytes + 1,
    }));
    try testing.expect(fx.dev.hasViolation(.limits));

    fx.dev.clearViolations();
    _ = try fx.dev.createPipelineLayout(.{ .inline_constant_bytes = pipeline.max_inline_constant_bytes });
    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

test "rule 10: a bind group index beyond the guaranteed maximum is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setBindGroup(pipeline.max_bind_groups, .none);
    pass.end();

    try testing.expect(fx.dev.hasViolation(.limits));
}

test "rule 10: writing more inline bytes than the layout declares is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const pipe = try inlinePipeline(&fx, 16, "small");
    const too_much: [32]u8 = @splat(0);

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(pipe);
    pass.setInlineConstants(&too_much);
    pass.end();

    try testing.expect(fx.dev.hasViolation(.limits));
}

test "rule 10: writing more than 128 bytes is caught even with no pipeline bound" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const enormous: [256]u8 = @splat(0);

    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setInlineConstants(&enormous);
    pass.end();

    try testing.expect(fx.dev.hasViolation(.limits));
}

// -- the mechanism itself ------------------------------------------------------------

test "the rules are exactly the ten the design document lists" {
    // If a rule is added or removed, that is a contract change and belongs in
    // `docs/design/rhi.md` §11 first. Asserted so a casual edit fails a test.
    const rules = std.enums.values(Rule);
    try testing.expectEqual(@as(usize, 10), rules.len);
    for (rules, 1..) |rule, expected| {
        try testing.expectEqual(@as(u8, @intCast(expected)), @intFromEnum(rule));
    }
}

test "submit reports failure exactly when something was violated" {
    var fx = try Fixture.init();
    defer fx.deinit();

    // A clean command buffer submits cleanly...
    _ = try fx.dev.beginFrame();
    var clean = try fx.dev.beginCommandBuffer();
    try clean.submit();

    // ...and a later violation does not retroactively fail it, because each command
    // buffer is judged against the violations recorded during its own recording.
    var dirty = try fx.dev.beginCommandBuffer();
    var pass = try dirty.beginRenderPass(.{ .color = &.{} });
    pass.setBindGroup(99, .none); // rule 10
    pass.end();
    try testing.expectError(error.ValidationFailed, dirty.submit());

    var clean_again = try fx.dev.beginCommandBuffer();
    try clean_again.submit();
}

test "violations carry a readable detail and can be cleared" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const buf = try fx.dev.createBuffer(.{ .label = "gpu-only", .size = 16, .usage = .{ .vertex = true } });
    defer fx.dev.destroyBuffer(buf);
    _ = fx.dev.mapBuffer(buf) catch {};

    const list = fx.dev.violations();
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(Rule.device_local_mapped, list[0].rule);
    // The label is in the message, because "a buffer" is not a diagnosis.
    try testing.expect(std.mem.indexOf(u8, list[0].detail, "gpu-only") != null);

    fx.dev.clearViolations();
    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

test "the frame ring cycles slots and the index only rises" {
    var fx = try Fixture.init();
    defer fx.deinit();

    var seen: [4]bool = @splat(false);
    var previous: u64 = 0;
    for (0..8) |_| {
        const frame = try fx.dev.beginFrame();
        try testing.expect(frame.index > previous);
        previous = frame.index;
        try testing.expect(frame.slot < fx.dev.desc.frames_in_flight);
        seen[frame.slot] = true;
        try fx.dev.endFrame();
    }
    // Two frames in flight means exactly two slots are used, alternately.
    try testing.expect(seen[0] and seen[1]);
    try testing.expect(!seen[2] and !seen[3]);
    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

test "capabilities report the guaranteed minimums, not something better" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const caps = fx.dev.capabilities();
    try testing.expectEqual(pipeline.max_bind_groups, caps.max_bind_groups);
    try testing.expectEqual(pipeline.max_inline_constant_bytes, caps.max_inline_constant_bytes);
    // Deliberately false: the null backend has no memory at all, and claiming unified
    // would invite exactly the habit rule 2 exists to prevent.
    try testing.expect(!caps.unified_memory);
    try testing.expect(caps.runtime_shader_compilation);
    try testing.expectEqual(format.TextureFormat.bgra8_unorm_srgb, caps.surface_format);
}

test "a destroyed resource's handle resolves to nothing" {
    // I1 in practice: a stale handle is safely dead rather than pointing at whatever took
    // its slot. Against a GPU, where the CPU runs two frames ahead, this is the difference
    // between a diagnosable error and a corrupted command buffer.
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const buf = try dev.createBuffer(.{ .size = 16, .usage = .{ .uniform = true }, .memory = .upload });
    _ = try dev.mapBuffer(buf);
    dev.destroyBuffer(buf);

    try testing.expectError(error.InvalidHandle, dev.mapBuffer(buf));

    // And the slot's reuse does not resurrect the old handle.
    const replacement = try dev.createBuffer(.{ .size = 16, .usage = .{ .uniform = true }, .memory = .upload });
    defer dev.destroyBuffer(replacement);
    try testing.expect(!buf.eql(replacement));
    try testing.expectError(error.InvalidHandle, dev.mapBuffer(buf));
}

test "resizing the surface updates it and resets its state" {
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.dev.resizeSurface(.{ .width = 640, .height = 480 });
    try testing.expect(fx.dev.surface_size.eql(.{ .width = 640, .height = 480 }));

    // A resize is explicit rather than detected inside beginFrame, because it invalidates
    // textures the caller may hold handles to — a fact the caller must be told.
    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(fx.pipe);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();
    try cmd.submit();
    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
}

test "runtime shader compilation is available and distinguishable" {
    // ADR-0015: the same mechanism shader hot reload and eventually mod-authored shaders
    // need. A backend may report it unsupported; this one supports it.
    var fx = try Fixture.init();
    defer fx.deinit();

    const from_source = try fx.dev.createShaderModuleFromSource(.{ .label = "hot", .source = "vertex void x() {}" });
    try testing.expect(fx.dev.shaders.getConst(from_source).?.from_source);
    try testing.expect(!fx.dev.shaders.getConst(fx.vs).?.from_source);

    try testing.expectError(error.ShaderCompilationFailed, fx.dev.createShaderModuleFromSource(.{ .source = "" }));
}
