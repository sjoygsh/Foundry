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
//! It enforces **the eleven rules in `docs/design/rhi.md` §11 and nothing else.** It is not a
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
const lifetime = @import("../lifetime.zig");
const pipeline = @import("../pipeline.zig");
const resource = @import("../resource.zig");

const Allocator = std.mem.Allocator;
const assert = core.assert;
const log = core.log.scoped(.rhi);

/// Generous internal capacities. These are *not* contract limits — exceeding one is an
/// engine bug with no sensible behaviour to report, so it asserts rather than becoming a
/// violation. The real limits live in `pipeline.zig` and are enforced as rule 10.
const max_color_attachments = 8;
const max_frames_in_flight = 4;

/// A contract limit, unlike the two above: `pipeline.max_vertex_buffers` is what the RHI
/// guarantees, so exceeding it is a rule 10 violation rather than an assertion.
const max_vertex_buffers = pipeline.max_vertex_buffers;

/// The eleven rules of `docs/design/rhi.md` §11, numbered as they are there.
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
    /// A command was recorded through a destroyed handle, directly or through a bind group
    /// naming one. Destroying something unfinished recordings use is legal: the backend keeps
    /// its backing until they finish, which is the backend's promise rather than something a
    /// caller can get wrong, so tests observe it through `retiredCount` (ADR-0035).
    lifetime = 9,
    /// A documented limit was exceeded: more than four bind groups, or more inline
    /// constant bytes than 128 or than the bound pipeline's layout declares.
    limits = 10,
    /// A resource was used, or declared to enter a state, that its declared usage does not
    /// allow. Checked apart from rule 1: a correct state does not make up for a missing flag.
    usage = 11,
};

/// Failures a test can make the next call fail with, each consumed by the call it names. They
/// drive a caller's cleanup through the points a real device fails a frame — acquiring it,
/// submitting to it and finishing it — deterministically (`hardening.md` §7). Never set outside
/// a test.
pub const Faults = struct {
    begin_frame: ?interface.FrameError = null,
    submit: ?interface.CommandError = null,
    end_frame: ?interface.FrameError = null,
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
    /// The last recording that referenced this buffer, numbered as `lifetime.Timeline`
    /// numbers them, or 0 for none. Rule 3 turns on whether that recording has finished.
    last_used: u64 = 0,
};

const TextureState = struct {
    desc: resource.TextureDesc,
    state: resource.ResourceState,
    is_surface: bool = false,
    /// Transitions that declared `undefined` while the texture was tracked as something
    /// else. Legal — rule 1 says so — but each one tells a backend it may throw the
    /// contents away, so a caller that meant to keep them can be caught doing it.
    discarded: u32 = 0,
};

const SamplerState = struct { desc: resource.SamplerDesc };
const ShaderState = struct { label: []const u8, from_source: bool };

const BindGroupLayoutState = struct {
    entries: []pipeline.BindGroupLayoutEntry,
};

const BindGroupState = struct {
    layout: pipeline.BindGroupLayoutHandle,
    entries: []pipeline.BindGroupEntry,
};

const PipelineLayoutState = struct {
    bind_group_layouts: []pipeline.BindGroupLayoutHandle,
    inline_constant_bytes: u32,
};

const RenderPipelineState = struct {
    /// Identity only, for §9's rule that a layout change invalidates inline constants. What a
    /// draw is checked against is copied below: a pipeline owns what it was built from, so
    /// destroying its layout afterwards cannot change what the pipeline requires.
    layout: pipeline.PipelineLayoutHandle,
    bind_group_layouts: []pipeline.BindGroupLayoutHandle,
    inline_constant_bytes: u32,
    color_formats: []format.TextureFormat,
    depth_format: ?format.TextureFormat,
    vertex_buffer_count: u32,
};

/// What a destroyed resource leaves behind until the recordings that could use it finish.
/// Every kind is retired, including kinds with nothing to free here, so that retention is
/// observable the same way for all of them and the list matches the one Metal keeps.
const Retired = union(enum) {
    buffer: []u8,
    texture,
    sampler,
    shader,
    bind_group_layout: []pipeline.BindGroupLayoutEntry,
    bind_group: []pipeline.BindGroupEntry,
    pipeline_layout: []pipeline.BindGroupLayoutHandle,
    render_pipeline: RenderPipelineState,

    fn release(self: Retired, gpa: Allocator) void {
        switch (self) {
            .buffer => |storage| gpa.free(storage),
            .texture, .sampler, .shader => {},
            .bind_group_layout => |entries| gpa.free(entries),
            .bind_group => |entries| gpa.free(entries),
            .pipeline_layout => |layouts| gpa.free(layouts),
            .render_pipeline => |p| {
                gpa.free(p.bind_group_layouts);
                gpa.free(p.color_formats);
            },
        }
    }
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
    /// What `capabilities` reports as `unified_memory`. False unless a test sets it: the null
    /// backend has no memory at all, and claiming unified by default would invite exactly the
    /// habit rule 2 exists to prevent. It exists so a caller's unified-memory branch can be
    /// validated as well as its staging-copy branch, deterministically, on any host.
    unified_memory: bool = false,
    faults: Faults = .{},

    surface_texture: resource.TextureHandle = .none,
    surface_size: resource.Extent2D,

    frame_index: u64 = 0,
    frame_slot: u32 = 0,
    in_frame: bool = false,

    /// Which recordings have finished. There is no GPU, so a submission finishes exactly when
    /// a real backend's wait would have covered it — a slot's marker, or `waitIdle` — and never
    /// because a frame ended or because the frame index is zero.
    timeline: lifetime.Timeline(void) = .{},
    /// The newest submission when each slot's previous frame ended, or 0. `beginFrame` waits
    /// through it before reusing the slot; Metal waits on a command buffer committed at that
    /// same point, so the two backends wait for the same work.
    slot_markers: [max_frames_in_flight]u64 = @splat(0),
    retired: lifetime.Retirement(Retired) = .{},

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
            self.retired.deinit(gpa);
            self.textures.deinit(gpa);
            gpa.destroy(self);
            return error.OutOfMemory;
        };
        if (self.textures.get(self.surface_texture)) |t| t.is_surface = true;

        log.info("rhi backend: null (validating), {d} frames in flight", .{desc.frames_in_flight});
        return self;
    }

    pub fn deinit(self: *Device) void {
        const gpa = self.gpa;

        // Teardown releases everything, finished or not: there is no queue left to wait on,
        // and a recording that was never submitted never will be.
        for (self.retired.entries.items) |entry| entry.backing.release(gpa);
        self.retired.deinit(gpa);
        self.timeline.deinit(gpa);

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
        while (ps.next()) |e| Retired.release(.{ .render_pipeline = e.value.* }, gpa);

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
            .unified_memory = self.unified_memory,
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

    /// Waits for everything submitted so far, uploads outside a frame included. There is no
    /// GPU, so waiting is knowing. It finishes nothing that was never submitted: an open
    /// recording stays open, and whatever it could use stays retained.
    pub fn waitIdle(self: *Device) void {
        self.waitThrough(self.timeline.submitted);
    }

    fn waitThrough(self: *Device, serial: u64) void {
        self.timeline.complete(serial);
        self.collect();
    }

    /// Releases every retired backing no unfinished recording could still use.
    fn collect(self: *Device) void {
        while (self.timeline.popCompleted()) |_| {}
        const through = self.timeline.resolvedThrough();
        while (self.retired.next(through)) |backing| backing.release(self.gpa);
    }

    /// Whether a recording that used something may still be executing.
    fn inFlight(self: *Device, recording: u64) bool {
        return recording > self.timeline.resolvedThrough();
    }

    /// Backings destroyed and not yet released. Not part of the interface: it is how a test
    /// sees that a destroy was deferred, and that the deferral ended.
    pub fn retiredCount(self: *const Device) usize {
        return self.retired.count();
    }

    /// How many recorded transitions declared a texture's tracked contents not worth
    /// keeping, or null for a handle that does not resolve. Tests only: a caller that
    /// preserves what a texture holds, an atlas in particular, should leave this at zero.
    pub fn contentsDiscarded(self: *Device, handle: resource.TextureHandle) ?u32 {
        const tex = self.textures.get(handle) orelse return null;
        return tex.discarded;
    }

    fn liveCount(self: *const Device) usize {
        return @as(usize, self.buffers.count()) + self.textures.count() + self.samplers.count() +
            self.shaders.count() + self.bind_group_layouts.count() + self.bind_groups.count() +
            self.pipeline_layouts.count() + self.pipelines.count();
    }

    /// Makes room to retire one more resource before it is published, so that destroying it
    /// can never fail, leak or release early for want of memory.
    fn reserveRetirement(self: *Device) Allocator.Error!void {
        try self.retired.reserve(self.gpa, self.liveCount() + 1);
    }

    /// The caller's half of a destroy is already done — the handle no longer resolves. This is
    /// the backend's half.
    fn retire(self: *Device, backing: Retired) void {
        self.retired.retire(backing, self.timeline.begun);
        self.collect();
    }

    /// Rule 9's caller half: `.none` names nothing, so only a handle that once resolved and no
    /// longer does is a use of something destroyed.
    fn deadBuffer(self: *const Device, handle: resource.BufferHandle) bool {
        return !handle.isNone() and !self.buffers.contains(handle);
    }

    /// The first binding of a group whose resource has been destroyed since the group was made.
    fn deadEntry(self: *const Device, group: *const BindGroupState) ?pipeline.BindGroupEntry {
        for (group.entries) |e| {
            const dead = switch (e.resource) {
                .sampled_texture => |t| !t.isNone() and !self.textures.contains(t),
                .uniform_buffer, .storage_buffer => |b| self.deadBuffer(b.buffer),
                .sampler => |s| !s.isNone() and !self.samplers.contains(s),
            };
            if (dead) return e;
        }
        return null;
    }

    /// Rule 11: whether a texture's usage allows it to enter `state`. `present` belongs to the
    /// device's surface alone, and `undefined` describes no operation.
    fn textureAllows(tex: *const TextureState, state: resource.ResourceState) bool {
        const u = tex.desc.usage;
        return switch (state) {
            .undefined => true,
            .shader_read => u.sampled,
            .render_target => u.render_target,
            .depth_stencil => u.depth_stencil,
            .copy_src => u.copy_src,
            .copy_dst => u.copy_dst,
            .present => tex.is_surface,
        };
    }

    /// Rule 11, for a buffer. Reading one on the GPU is any of the four ways it can be bound;
    /// it has no attachment or presentation state to enter.
    fn bufferAllows(usage: resource.BufferUsage, state: resource.ResourceState) bool {
        return switch (state) {
            .undefined => true,
            .shader_read => usage.vertex or usage.index or usage.uniform or usage.storage,
            .copy_src => usage.copy_src,
            .copy_dst => usage.copy_dst,
            .render_target, .depth_stencil, .present => false,
        };
    }

    // -- buffers -------------------------------------------------------------------

    pub fn createBuffer(self: *Device, desc: resource.BufferDesc) interface.ResourceError!resource.BufferHandle {
        // An invalid descriptor, reported through the error the interface already
        // defines for it. Deliberately *not* a violation record: the rules are the
        // validation backend's whole remit, and zero-size is not among them.
        if (desc.size == 0) return error.InvalidDescriptor;
        try self.reserveRetirement();
        const storage = try self.gpa.alloc(u8, @intCast(desc.size));
        @memset(storage, 0);
        errdefer self.gpa.free(storage);
        return self.buffers.add(self.gpa, .{ .desc = desc, .storage = storage });
    }

    pub fn destroyBuffer(self: *Device, handle: resource.BufferHandle) void {
        const state = self.buffers.getConst(handle) orelse return;
        const storage = state.storage;
        _ = self.buffers.remove(handle);
        self.retire(.{ .buffer = storage });
    }

    pub fn mapBuffer(self: *Device, handle: resource.BufferHandle) interface.MapError![]u8 {
        const state = self.buffers.get(handle) orelse return error.InvalidHandle;

        // Rule 2: the rule that stops unified memory from becoming a habit.
        if (!state.desc.memory.isMappable()) {
            self.violate(.device_local_mapped, "buffer '{s}' is device_local and cannot be mapped; use an upload buffer and a copy", .{state.desc.label});
            return error.NotMappable;
        }
        // Rule 3: writing to memory a frame still in flight may be reading.
        if (self.inFlight(state.last_used)) {
            self.violate(.frame_ring, "buffer '{s}' mapped while recording {d}, which uses it, is unfinished (finished through {d})", .{
                state.desc.label, state.last_used, self.timeline.resolvedThrough(),
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
        // Rule 11, at creation: a texture cannot start in a state its usage forbids.
        const candidate: TextureState = .{ .desc = desc, .state = desc.initial_state };
        if (!textureAllows(&candidate, desc.initial_state)) {
            self.violate(.usage, "texture '{s}' is created in {t}, which its usage does not allow", .{ desc.label, desc.initial_state });
            return error.InvalidDescriptor;
        }
        try self.reserveRetirement();
        return self.textures.add(self.gpa, candidate);
    }

    pub fn destroyTexture(self: *Device, handle: resource.TextureHandle) void {
        if (!self.textures.remove(handle)) return;
        self.retire(.texture);
    }

    // -- samplers and shaders ------------------------------------------------------

    pub fn createSampler(self: *Device, desc: resource.SamplerDesc) interface.ResourceError!resource.SamplerHandle {
        try self.reserveRetirement();
        return self.samplers.add(self.gpa, .{ .desc = desc });
    }

    pub fn destroySampler(self: *Device, handle: resource.SamplerHandle) void {
        if (!self.samplers.remove(handle)) return;
        self.retire(.sampler);
    }

    pub fn createShaderModule(self: *Device, desc: resource.ShaderModuleDesc) interface.ResourceError!resource.ShaderModuleHandle {
        // The null backend compiles nothing, so any bytes are acceptable — but empty
        // bytes are a caller mistake worth reporting rather than accepting silently.
        if (desc.bytes.len == 0) return error.ShaderCompilationFailed;
        try self.reserveRetirement();
        return self.shaders.add(self.gpa, .{ .label = desc.label, .from_source = false });
    }

    pub fn createShaderModuleFromSource(self: *Device, desc: resource.ShaderSourceDesc) interface.ResourceError!resource.ShaderModuleHandle {
        if (desc.source.len == 0) return error.ShaderCompilationFailed;
        try self.reserveRetirement();
        return self.shaders.add(self.gpa, .{ .label = desc.label, .from_source = true });
    }

    pub fn destroyShaderModule(self: *Device, handle: resource.ShaderModuleHandle) void {
        if (!self.shaders.remove(handle)) return;
        self.retire(.shader);
    }

    // -- binding -------------------------------------------------------------------

    pub fn createBindGroupLayout(self: *Device, desc: pipeline.BindGroupLayoutDesc) interface.ResourceError!pipeline.BindGroupLayoutHandle {
        try self.reserveRetirement();
        const entries = try self.gpa.dupe(pipeline.BindGroupLayoutEntry, desc.entries);
        errdefer self.gpa.free(entries);
        return self.bind_group_layouts.add(self.gpa, .{ .entries = entries });
    }

    pub fn destroyBindGroupLayout(self: *Device, handle: pipeline.BindGroupLayoutHandle) void {
        const state = self.bind_group_layouts.getConst(handle) orelse return;
        const entries = state.entries;
        _ = self.bind_group_layouts.remove(handle);
        self.retire(.{ .bind_group_layout = entries });
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

        // Rule 11, also at creation and for the same reason: usage never changes, so a group
        // binding a resource as something its usage forbids is wrong from the moment it exists.
        for (desc.entries) |e| {
            const allowed = switch (e.resource) {
                .uniform_buffer => |b| if (self.buffers.getConst(b.buffer)) |buf| buf.desc.usage.uniform else true,
                .storage_buffer => |b| if (self.buffers.getConst(b.buffer)) |buf| buf.desc.usage.storage else true,
                .sampled_texture => |t| if (self.textures.getConst(t)) |tex| tex.desc.usage.sampled else true,
                .sampler => true,
            };
            if (!allowed) {
                self.violate(.usage, "bind group '{s}' binding {d} is a {t}, which its resource's usage does not allow", .{
                    desc.label, e.binding, @as(pipeline.BindingType, e.resource),
                });
                return error.InvalidDescriptor;
            }
        }

        try self.reserveRetirement();
        const entries = try self.gpa.dupe(pipeline.BindGroupEntry, desc.entries);
        errdefer self.gpa.free(entries);
        return self.bind_groups.add(self.gpa, .{ .layout = desc.layout, .entries = entries });
    }

    pub fn destroyBindGroup(self: *Device, handle: pipeline.BindGroupHandle) void {
        const state = self.bind_groups.getConst(handle) orelse return;
        const entries = state.entries;
        _ = self.bind_groups.remove(handle);
        self.retire(.{ .bind_group = entries });
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

        try self.reserveRetirement();
        const layouts = try self.gpa.dupe(pipeline.BindGroupLayoutHandle, desc.bind_group_layouts);
        errdefer self.gpa.free(layouts);
        return self.pipeline_layouts.add(self.gpa, .{
            .bind_group_layouts = layouts,
            .inline_constant_bytes = desc.inline_constant_bytes,
        });
    }

    pub fn destroyPipelineLayout(self: *Device, handle: pipeline.PipelineLayoutHandle) void {
        const state = self.pipeline_layouts.getConst(handle) orelse return;
        const layouts = state.bind_group_layouts;
        _ = self.pipeline_layouts.remove(handle);
        self.retire(.{ .pipeline_layout = layouts });
    }

    pub fn createRenderPipeline(self: *Device, desc: pipeline.RenderPipelineDesc) interface.ResourceError!pipeline.RenderPipelineHandle {
        const layout = self.pipeline_layouts.getConst(desc.layout) orelse return error.InvalidDescriptor;
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

        try self.reserveRetirement();
        const layouts = try self.gpa.dupe(pipeline.BindGroupLayoutHandle, layout.bind_group_layouts);
        errdefer self.gpa.free(layouts);
        const formats = try self.gpa.alloc(format.TextureFormat, desc.color_targets.len);
        errdefer self.gpa.free(formats);
        for (desc.color_targets, 0..) |t, i| formats[i] = t.format;

        return self.pipelines.add(self.gpa, .{
            .layout = desc.layout,
            .bind_group_layouts = layouts,
            .inline_constant_bytes = layout.inline_constant_bytes,
            .color_formats = formats,
            .depth_format = if (desc.depth_stencil) |d| d.format else null,
            .vertex_buffer_count = @intCast(desc.vertex_buffers.len),
        });
    }

    pub fn destroyRenderPipeline(self: *Device, handle: pipeline.RenderPipelineHandle) void {
        const state = self.pipelines.getConst(handle) orelse return;
        const retired = state.*;
        _ = self.pipelines.remove(handle);
        self.retire(.{ .render_pipeline = retired });
    }

    // -- the frame ring ------------------------------------------------------------

    pub fn beginFrame(self: *Device) interface.FrameError!command.FrameContext {
        // Rule 8, read as covering recording structure at every level. A frame is the
        // outermost recording scope.
        if (self.in_frame) {
            self.violate(.encoder_discipline, "beginFrame called while frame {d} is still open", .{self.frame_index});
        }
        const index = self.frame_index + 1;
        const slot: u32 = @intCast((index - 1) % self.desc.frames_in_flight);

        // The ring's wait. Everything submitted before this slot's previous frame ended has
        // finished, and so has whatever was retired waiting on it. Before the image is asked
        // for, as on Metal, so a failed acquisition may still finish older work.
        const marker = self.slot_markers[slot];
        if (marker != 0) {
            self.slot_markers[slot] = 0;
            self.waitThrough(marker);
        }

        // A failed acquisition opens no frame and spends no frame index.
        if (self.faults.begin_frame) |err| {
            self.faults.begin_frame = null;
            return err;
        }
        self.in_frame = true;
        self.frame_index = index;
        self.frame_slot = slot;

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
        self.slot_markers[self.frame_slot] = self.timeline.submitted;
        // A frame that fails to finish still leaves its marker first: what it submitted is
        // queued, and whatever that uses must wait for it however the frame ended.
        if (self.faults.end_frame) |err| {
            self.faults.end_frame = null;
            return err;
        }
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
        const recording = try self.timeline.begin(self.gpa);
        errdefer self.timeline.discard(recording);

        const cb = if (self.free_command_buffers.pop()) |reused| reused else blk: {
            const fresh = try self.gpa.create(CommandBuffer);
            errdefer self.gpa.destroy(fresh);
            // Room to recycle it is reserved with it, so that returning it at submit cannot
            // fail — an allocation failure there would otherwise be swallowed.
            try self.free_command_buffers.ensureTotalCapacity(self.gpa, self.command_buffers.items.len + 1);
            try self.command_buffers.append(self.gpa, fresh);
            break :blk fresh;
        };
        cb.* = .{
            .device = self,
            .recording = recording,
            .violations_at_start = self.violation_list.items.len,
        };
        return cb;
    }

    fn recycleCommandBuffer(self: *Device, cb: *CommandBuffer) void {
        self.free_command_buffers.appendAssumeCapacity(cb);
    }

    fn acquireRenderPass(self: *Device) !*RenderPass {
        if (self.free_render_passes.pop()) |reused| return reused;
        const fresh = try self.gpa.create(RenderPass);
        errdefer self.gpa.destroy(fresh);
        try self.free_render_passes.ensureTotalCapacity(self.gpa, self.render_passes.items.len + 1);
        try self.render_passes.append(self.gpa, fresh);
        return fresh;
    }

    fn touchBuffer(self: *Device, handle: resource.BufferHandle, recording: u64) void {
        if (self.buffers.get(handle)) |b| b.last_used = recording;
    }
};

// -- command buffer ------------------------------------------------------------------

pub const CommandBuffer = struct {
    device: *Device,
    /// This recording's number in the device's timeline.
    recording: u64 = 0,
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
            // Rule 11: drawing into it is what `render_target` is for.
            if (!tex.desc.usage.render_target) {
                dev.violate(.usage, "render pass '{s}' colour attachment {d} '{s}' lacks render_target usage", .{ desc.label, i, tex.desc.label });
            }
            checkTransition(dev, tex, att.initial_state, att.final_state, desc.label, "colour attachment");
            pass.color_formats[i] = tex.desc.format;
        }
        pass.color_count = desc.color.len;

        if (desc.depth) |att| {
            if (dev.textures.get(att.texture)) |tex| {
                if (!tex.desc.format.isDepth()) {
                    dev.violate(.attachment_format, "render pass '{s}' depth attachment has colour format {t}", .{ desc.label, tex.desc.format });
                }
                if (!tex.desc.usage.depth_stencil) {
                    dev.violate(.usage, "render pass '{s}' depth attachment '{s}' lacks depth_stencil usage", .{ desc.label, tex.desc.label });
                }
                checkTransition(dev, tex, att.initial_state, att.final_state, desc.label, "depth attachment");
                pass.depth_format = tex.desc.format;
            } else if (!att.texture.isNone()) {
                dev.violate(.lifetime, "render pass '{s}' depth attachment names a destroyed texture", .{desc.label});
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
        if (initial == .undefined and tex.state != .undefined) tex.discarded += 1;
        // Rule 11: the state it is left in must be one its usage allows.
        if (!Device.textureAllows(tex, final)) {
            dev.violate(.usage, "'{s}' {s} '{s}' ends in {t}, which its usage does not allow", .{ label, what, tex.desc.label, final });
        }
        tex.state = final;
    }

    pub fn textureBarrier(self: *CommandBuffer, barriers: []const command.TextureBarrier) interface.CommandError!void {
        const dev = self.device;
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "barrier recorded inside an open render pass", .{});
        }
        for (barriers) |b| {
            const tex = dev.textures.get(b.texture) orelse {
                if (!b.texture.isNone()) dev.violate(.lifetime, "barrier names a destroyed texture", .{});
                continue;
            };
            if (b.from != .undefined and tex.state != b.from) {
                dev.violate(.resource_state, "barrier on '{s}' declares from {t} but it is tracked as {t}", .{
                    tex.desc.label, b.from, tex.state,
                });
            }
            if (b.from == .undefined and tex.state != .undefined) tex.discarded += 1;
            if (!Device.textureAllows(tex, b.to)) {
                dev.violate(.usage, "barrier moves texture '{s}' to {t}, which its usage does not allow", .{ tex.desc.label, b.to });
            }
            tex.state = b.to;
        }
    }

    pub fn bufferBarrier(self: *CommandBuffer, barriers: []const command.BufferBarrier) interface.CommandError!void {
        const dev = self.device;
        for (barriers) |b| {
            const buf = dev.buffers.get(b.buffer) orelse {
                if (!b.buffer.isNone()) dev.violate(.lifetime, "barrier names a destroyed buffer", .{});
                continue;
            };
            if (b.from != .undefined and buf.state != b.from) {
                dev.violate(.resource_state, "barrier on buffer '{s}' declares from {t} but it is tracked as {t}", .{
                    buf.desc.label, b.from, buf.state,
                });
            }
            if (!Device.bufferAllows(buf.desc.usage, b.to)) {
                dev.violate(.usage, "barrier moves buffer '{s}' to {t}, which its usage does not allow", .{ buf.desc.label, b.to });
            }
            buf.state = b.to;
            buf.last_used = self.recording;
        }
    }

    pub fn copyBufferToBuffer(self: *CommandBuffer, copy: command.BufferCopy) interface.CommandError!void {
        const dev = self.device;
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "copy recorded inside an open render pass", .{});
        }
        // Rule 11: reading needs `copy_src` and writing `copy_dst`, whatever state either is in.
        if (dev.buffers.getConst(copy.src)) |src| {
            if (!src.desc.usage.copy_src) dev.violate(.usage, "copy reads buffer '{s}', which lacks copy_src usage", .{src.desc.label});
        }
        if (dev.buffers.getConst(copy.dst)) |dst| {
            if (!dst.desc.usage.copy_dst) dev.violate(.usage, "copy writes buffer '{s}', which lacks copy_dst usage", .{dst.desc.label});
        }
        if (dev.deadBuffer(copy.src)) dev.violate(.lifetime, "copy reads a destroyed buffer", .{});
        if (dev.deadBuffer(copy.dst)) dev.violate(.lifetime, "copy writes a destroyed buffer", .{});
        dev.touchBuffer(copy.src, self.recording);
        dev.touchBuffer(copy.dst, self.recording);
    }

    pub fn copyBufferToTexture(self: *CommandBuffer, copy: command.BufferToTextureCopy) interface.CommandError!void {
        const dev = self.device;
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "copy recorded inside an open render pass", .{});
        }
        if (dev.textures.get(copy.dst)) |dst| {
            if (!dst.desc.usage.copy_dst) {
                dev.violate(.usage, "copy writes texture '{s}', which lacks copy_dst usage", .{dst.desc.label});
            }
            if (dst.state != .copy_dst) {
                dev.violate(.resource_state, "texture '{s}' is tracked as {t}, not copy_dst, at a buffer-to-texture copy", .{
                    dst.desc.label, dst.state,
                });
            }
            // Rule 10: the region must lie inside the level it addresses. Metal silently
            // clamps some of these and produces garbage for others; Vulkan and D3D12 call
            // an out-of-bounds region undefined behaviour. A destination origin makes this
            // reachable by ordinary code — an atlas packing one sprite too many — so it is
            // checked rather than trusted.
            if (copy.dst_mip_level >= dst.desc.mip_levels) {
                dev.violate(.limits, "copy targets mip level {d} of texture '{s}', which has {d}", .{
                    copy.dst_mip_level, dst.desc.label, dst.desc.mip_levels,
                });
            } else {
                const level = dst.desc.size.mipLevel(copy.dst_mip_level);
                const right = @as(u64, copy.dst_origin.x) + copy.size.width;
                const bottom = @as(u64, copy.dst_origin.y) + copy.size.height;
                if (right > level.width or bottom > level.height) {
                    dev.violate(.limits, "copy of {d}x{d} at ({d}, {d}) does not fit texture '{s}' level {d}, which is {d}x{d}", .{
                        copy.size.width,   copy.size.height, copy.dst_origin.x,
                        copy.dst_origin.y, dst.desc.label,   copy.dst_mip_level,
                        level.width,       level.height,
                    });
                }
            }
        } else if (!copy.dst.isNone()) {
            dev.violate(.lifetime, "copy writes a destroyed texture", .{});
        }
        if (dev.deadBuffer(copy.src)) dev.violate(.lifetime, "copy reads a destroyed buffer", .{});
        if (dev.buffers.getConst(copy.src)) |src| {
            if (!src.desc.usage.copy_src) dev.violate(.usage, "copy reads buffer '{s}', which lacks copy_src usage", .{src.desc.label});
        }
        dev.touchBuffer(copy.src, self.recording);
    }

    pub fn submit(self: *CommandBuffer) interface.CommandError!void {
        const dev = self.device;
        // Rule 8: every pass ended, and nothing submitted twice.
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "command buffer submitted with a render pass still open", .{});
        }
        if (self.submitted) {
            dev.violate(.encoder_discipline, "command buffer submitted twice", .{});
            return error.ValidationFailed;
        }
        if (dev.faults.submit) |err| {
            dev.faults.submit = null;
            // Refused before the queue took it, so nothing it recorded will run. `submit`
            // consumes a command buffer whatever it returns, so the recording is discarded here.
            self.submitted = true;
            dev.timeline.discard(self.recording);
            dev.recycleCommandBuffer(self);
            return err;
        }
        self.submitted = true;
        // Queued even when it broke a rule. The caller is told, but a recording that reached
        // submit is treated as executing, so what it could use stays retained until a wait
        // covers it; assuming otherwise would be the unsafe direction to be wrong in.
        _ = dev.timeline.submit(self.recording, {});

        const failed = dev.violation_list.items.len > self.violations_at_start;
        dev.recycleCommandBuffer(self);
        if (failed) return error.ValidationFailed;
    }

    /// Abandons a recording that will never be submitted. What it could have used stops
    /// waiting on it, and the command buffer is gone. Its passes must have ended first: a pass
    /// still open is rule 8 here, as it is at submission.
    pub fn discard(self: *CommandBuffer) void {
        const dev = self.device;
        if (self.open_pass) {
            dev.violate(.encoder_discipline, "command buffer discarded with a render pass still open", .{});
        }
        dev.timeline.discard(self.recording);
        dev.recycleCommandBuffer(self);
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
        if (!handle.isNone() and !dev.pipelines.contains(handle)) {
            dev.violate(.lifetime, "pass '{s}' binds a destroyed pipeline", .{self.label});
        }
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
        if (dev.bind_groups.getConst(group)) |g| {
            // Rule 9: a live group is not permission to use what it names once that is dead.
            if (dev.deadEntry(g)) |e| {
                dev.violate(.lifetime, "pass '{s}' binds a group whose binding {d} names a destroyed resource", .{ self.label, e.binding });
            }
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
                    },
                    .uniform_buffer, .storage_buffer => |b| dev.touchBuffer(b.buffer, self.cmd.recording),
                    .sampler => {},
                }
            }
        } else if (!group.isNone()) {
            dev.violate(.lifetime, "pass '{s}' binds a destroyed bind group", .{self.label});
        }
    }

    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: resource.BufferHandle, offset: u64) void {
        _ = offset;
        const dev = self.device;
        // Rule 10. A slot past the guarantee is a caller mistake with a defined answer —
        // the binding does not exist on a conforming backend — so it is reported, exactly
        // as an out-of-range bind group index is, rather than asserted.
        if (slot >= max_vertex_buffers) {
            dev.violate(.limits, "vertex buffer slot {d} exceeds the guaranteed maximum of {d}", .{ slot, max_vertex_buffers });
            return;
        }

        if (dev.deadBuffer(buffer)) dev.violate(.lifetime, "pass '{s}' binds a destroyed buffer to vertex slot {d}", .{ self.label, slot });
        if (dev.buffers.getConst(buffer)) |b| {
            // Rule 11. Reported now, and surfaced when the command buffer is submitted.
            if (!b.desc.usage.vertex) dev.violate(.usage, "pass '{s}' binds buffer '{s}' to vertex slot {d} without vertex usage", .{ self.label, b.desc.label, slot });
        }
        self.bound_vertex_buffers[slot] = buffer;
        dev.touchBuffer(buffer, self.cmd.recording);
    }

    pub fn setIndexBuffer(self: *RenderPass, buffer: resource.BufferHandle, index_format: format.IndexFormat, offset: u64) void {
        _ = index_format;
        _ = offset;
        const dev = self.device;
        if (dev.deadBuffer(buffer)) dev.violate(.lifetime, "pass '{s}' binds a destroyed index buffer", .{self.label});
        if (dev.buffers.getConst(buffer)) |b| {
            if (!b.desc.usage.index) dev.violate(.usage, "pass '{s}' binds buffer '{s}' as indices without index usage", .{ self.label, b.desc.label });
        }
        self.index_buffer = buffer;
        dev.touchBuffer(buffer, self.cmd.recording);
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
            if (bytes.len > p.inline_constant_bytes) {
                dev.violate(.limits, "{d} inline constant bytes exceeds the {d} the bound pipeline's layout declares", .{
                    bytes.len, p.inline_constant_bytes,
                });
                return;
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
            if (self.pipeline_handle.isNone()) {
                dev.violate(.incomplete_bindings, "draw in pass '{s}' with no pipeline bound", .{self.label});
            } else {
                dev.violate(.lifetime, "draw in pass '{s}' uses a pipeline destroyed since it was bound", .{self.label});
            }
            return;
        };

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
        for (pipe.bind_group_layouts, 0..) |declared, i| {
            if (declared.isNone()) continue;
            const bound = self.bound_groups[i];
            if (bound.isNone()) {
                dev.violate(.incomplete_bindings, "draw in pass '{s}' with nothing bound to group {d}, which the layout requires", .{ self.label, i });
                continue;
            }
            // Rule 9: the draw is a new use of the group and of everything it names.
            const group = dev.bind_groups.getConst(bound) orelse {
                dev.violate(.lifetime, "draw in pass '{s}' uses group {d}, destroyed since it was bound", .{ self.label, i });
                continue;
            };
            if (dev.deadEntry(group)) |e| {
                dev.violate(.lifetime, "draw in pass '{s}' uses group {d}, whose binding {d} names a destroyed resource", .{ self.label, i, e.binding });
            }
            // Rule 4: the group must have been built for the layout the pipeline declares.
            if (!group.layout.eql(declared)) {
                dev.violate(.bind_group_compatibility, "group {d} in pass '{s}' was built for a different layout than the pipeline declares", .{ i, self.label });
            }
        }
        if (pipe.inline_constant_bytes > 0 and !self.inline_constants_set) {
            dev.violate(.incomplete_bindings, "draw in pass '{s}' whose layout declares {d} inline constant bytes that were never set", .{
                self.label, pipe.inline_constant_bytes,
            });
        }

        // Rule 6: every vertex buffer the pipeline declares must be bound.
        var slot: u32 = 0;
        while (slot < pipe.vertex_buffer_count) : (slot += 1) {
            if (self.bound_vertex_buffers[slot].isNone()) {
                dev.violate(.vertex_layout, "draw in pass '{s}' with no buffer bound to vertex slot {d}, which the pipeline declares", .{ self.label, slot });
            } else if (dev.deadBuffer(self.bound_vertex_buffers[slot])) {
                dev.violate(.lifetime, "draw in pass '{s}' uses vertex slot {d}, whose buffer was destroyed since it was bound", .{ self.label, slot });
            }
        }
        if (indexed and self.index_buffer.isNone()) {
            dev.violate(.vertex_layout, "indexed draw in pass '{s}' with no index buffer bound", .{self.label});
        } else if (indexed and dev.deadBuffer(self.index_buffer)) {
            dev.violate(.lifetime, "indexed draw in pass '{s}' uses an index buffer destroyed since it was bound", .{self.label});
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
        // `acquireRenderPass` reserved this room when the pass was first allocated.
        dev.free_render_passes.appendAssumeCapacity(self);
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

    // Sampled as well: it is moved to `shader_read`, which rule 11 says only a texture shaders
    // may read can enter.
    const tex = try dev.createTexture(.{
        .size = .{ .width = 8, .height = 8 },
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true, .sampled = true },
        .initial_state = .render_target,
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    try cmd.textureBarrier(&.{.{ .texture = tex, .from = .undefined, .to = .shader_read }});
    try cmd.submit();
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "rule 1: declaring undefined over tracked contents is legal, and is counted as a discard" {
    // Legal, because it cannot be wrong about what is there. Counted, because it is wrong
    // about what the caller wanted whenever the caller meant to keep the contents, and no
    // rule can tell the two apart.
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const tex = try dev.createTexture(.{
        .size = .{ .width = 8, .height = 8 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .copy_dst = true },
    });

    var cmd = try dev.beginCommandBuffer();
    // A new texture holds nothing, so the first transition discards nothing.
    try cmd.textureBarrier(&.{.{ .texture = tex, .from = .undefined, .to = .copy_dst }});
    try cmd.textureBarrier(&.{.{ .texture = tex, .from = .copy_dst, .to = .shader_read }});
    try testing.expectEqual(@as(?u32, 0), dev.contentsDiscarded(tex));

    // Declaring what it is tracked as keeps the contents; declaring undefined does not.
    try cmd.textureBarrier(&.{.{ .texture = tex, .from = .shader_read, .to = .copy_dst }});
    try testing.expectEqual(@as(?u32, 0), dev.contentsDiscarded(tex));
    try cmd.textureBarrier(&.{.{ .texture = tex, .from = .undefined, .to = .shader_read }});
    try testing.expectEqual(@as(?u32, 1), dev.contentsDiscarded(tex));
    try cmd.submit();
    try testing.expectEqual(@as(usize, 0), dev.violationCount());

    dev.destroyTexture(tex);
    try testing.expectEqual(@as(?u32, null), dev.contentsDiscarded(tex));
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

    // Destroying it with frame 1 unfinished is legal; rule 9 keeps it until frame 1 is done.
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
//
// ADR-0035 split this rule. Destroying something unfinished work uses is legal: the backend
// keeps its backing until every recording that could use it has finished, and no caller can
// make it release early, so these tests watch the retention itself — `retiredCount` — rather
// than a violation. What a caller can get wrong is recording through the dead handle, and that
// is the violation.

test "rule 9: destroying a resource a frame in flight uses is legal, and its backing waits" {
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

    // Dead at once for callers...
    dev.destroyTexture(tex);
    try testing.expect(!dev.textures.contains(tex));
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
    // ...and kept for the GPU, which may still be reading it. Releasing it here is the error
    // that is unobservable in testing right up until it is a crash on someone else's machine.
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());

    // Frame 2 takes the other slot and waits on nothing of frame 1's.
    _ = try dev.beginFrame();
    try dev.endFrame();
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());

    // Frame 3 reuses frame 1's slot, so it waits for frame 1, and the backing goes.
    _ = try dev.beginFrame();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try dev.endFrame();
}

test "rule 9: destroying it after the frame completed releases it at once" {
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
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
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

test "rule 9: a recording open when a resource is destroyed holds it until that recording finishes" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const buffer = try dev.createBuffer(.{ .size = 16, .usage = .{ .vertex = true }, .memory = .upload });
    var cmd = try dev.beginCommandBuffer();
    dev.destroyBuffer(buffer);

    // `waitIdle` cannot finish a recording nobody has submitted.
    dev.waitIdle();
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());

    try cmd.submit();
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());
    dev.waitIdle();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
}

test "rule 9: a recording begun after the destroy holds nothing back" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const buffer = try dev.createBuffer(.{ .size = 16, .usage = .{ .vertex = true }, .memory = .upload });
    var used = try dev.beginCommandBuffer();
    try used.submit();
    dev.destroyBuffer(buffer);

    // Open, but begun after the handle died, so it cannot legally use it.
    var later = try dev.beginCommandBuffer();
    dev.waitIdle();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try later.submit();
}

test "rule 9: every kind of resource is retained while a recording that could use it is unfinished" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const buffer = try dev.createBuffer(.{ .size = 16, .usage = .{ .uniform = true }, .memory = .upload });
    const texture = try dev.createTexture(.{ .size = .{ .width = 4, .height = 4 }, .format = .rgba8_unorm, .usage = .{ .sampled = true } });
    const sampler = try dev.createSampler(.{});
    const shader = try dev.createShaderModule(.{ .bytes = "stub" });
    const group_layout = try dev.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .type = .uniform_buffer, .visibility = .both },
    } });
    const group = try dev.createBindGroup(.{ .layout = group_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .uniform_buffer = .{ .buffer = buffer } } },
    } });
    const layout = try dev.createPipelineLayout(.{ .bind_group_layouts = &.{group_layout} });
    const pipe = try dev.createRenderPipeline(.{
        .layout = layout,
        .vertex_shader = shader,
        .fragment_shader = shader,
        .color_targets = &.{.{ .format = .bgra8_unorm_srgb }},
    });

    // One recording, submitted and not yet waited for.
    var cmd = try dev.beginCommandBuffer();
    try cmd.submit();

    dev.destroyRenderPipeline(pipe);
    dev.destroyPipelineLayout(layout);
    dev.destroyBindGroup(group);
    dev.destroyBindGroupLayout(group_layout);
    dev.destroyShaderModule(shader);
    dev.destroySampler(sampler);
    dev.destroyTexture(texture);
    dev.destroyBuffer(buffer);
    try testing.expectEqual(@as(usize, 8), dev.retiredCount());

    // Destroying twice is harmless and retires nothing twice. Teardown under
    // `testing.allocator` catches any backing released more than once.
    dev.destroyBuffer(buffer);
    try testing.expectEqual(@as(usize, 8), dev.retiredCount());
    try testing.expectEqual(@as(usize, 0), dev.violationCount());

    dev.waitIdle();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
}

test "rule 9: recording through a destroyed handle is caught, including through a live bind group" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const texture = try dev.createTexture(.{
        .size = .{ .width = 4, .height = 4 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
        .initial_state = .shader_read,
    });
    const group_layout = try dev.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
    } });
    const group = try dev.createBindGroup(.{ .layout = group_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .sampled_texture = texture } },
    } });
    const vertices = try dev.createBuffer(.{ .size = 64, .usage = .{ .vertex = true, .copy_dst = true } });
    const staging = try dev.createBuffer(.{ .size = 64, .usage = .{ .copy_src = true }, .memory = .upload });

    dev.destroyTexture(texture);
    dev.destroyBuffer(vertices);
    dev.destroyBuffer(staging);
    try testing.expectEqual(@as(usize, 0), dev.violationCount());

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    try cmd.copyBufferToBuffer(.{ .src = staging, .dst = vertices, .size = 64 });
    try testing.expectEqual(@as(usize, 2), dev.violationCount());

    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    // The group is alive. What it names is not.
    pass.setBindGroup(0, group);
    try testing.expectEqual(@as(usize, 3), dev.violationCount());
    pass.setVertexBuffer(0, vertices, 0);
    try testing.expectEqual(@as(usize, 4), dev.violationCount());
    pass.end();

    try testing.expectError(error.ValidationFailed, cmd.submit());
    for (dev.violations()) |v| try testing.expectEqual(Rule.lifetime, v.rule);
}

test "rule 9: a draw after destroying what is bound is a new use of it" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(fx.pipe);
    dev.destroyRenderPipeline(fx.pipe);
    try testing.expectEqual(@as(usize, 0), dev.violationCount());

    pass.draw(.{ .vertex_count = 3 });
    try testing.expect(dev.hasViolation(.lifetime));
    pass.end();
    try testing.expectError(error.ValidationFailed, cmd.submit());
}

test "a pipeline keeps what it was built from after its layout is destroyed" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const layout = try dev.createPipelineLayout(.{ .label = "constants", .inline_constant_bytes = 16 });
    const pipe = try dev.createRenderPipeline(.{
        .label = "needs constants",
        .layout = layout,
        .vertex_shader = fx.vs,
        .fragment_shader = fx.fs,
        .color_targets = &.{.{ .format = .bgra8_unorm_srgb }},
    });
    dev.destroyPipelineLayout(layout);

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(pipe);
    pass.draw(.{ .vertex_count = 3 });
    // Rule 5 still knows the pipeline needs 16 bytes of constants. Rule 9 has nothing to say:
    // the pipeline is alive, and using it is not a use of the layout it was built from.
    try testing.expect(dev.hasViolation(.incomplete_bindings));
    try testing.expect(!dev.hasViolation(.lifetime));
    pass.end();
    try testing.expectError(error.ValidationFailed, cmd.submit());
}

// -- completion outside the frame ring -------------------------------------------------
//
// `hardening.md` §5.1. An upload made outside a frame is ordinary queue work: it finishes when
// a wait covers it, never because the frame index is zero and never because a frame ended.

/// An upload the way a renderer makes one: fill a staging buffer, copy, submit, destroy.
fn upload(dev: *Device) !void {
    const staging = try dev.createBuffer(.{ .label = "staging", .size = 16, .usage = .{ .copy_src = true }, .memory = .upload });
    const target = try dev.createBuffer(.{ .label = "target", .size = 16, .usage = .{ .copy_dst = true } });
    @memset(try dev.mapBuffer(staging), 0xAB);
    dev.unmapBuffer(staging);

    var cmd = try dev.beginCommandBuffer();
    try cmd.copyBufferToBuffer(.{ .src = staging, .dst = target, .size = 16 });
    try cmd.submit();
    dev.destroyBuffer(staging);
}

/// An empty frame, which is how the ring turns.
fn idleFrame(dev: *Device) !void {
    _ = try dev.beginFrame();
    try dev.endFrame();
}

test "an upload before the first frame is unfinished until a slot's wait covers it" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    try upload(dev);
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());

    // Ending a frame is not a wait, and neither slot has waited on anything yet.
    try idleFrame(dev);
    try idleFrame(dev);
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());

    // Frame 3 reuses frame 1's slot, and frame 1 ended after the upload.
    _ = try dev.beginFrame();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try dev.endFrame();
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "an upload between two frames waits for the first frame that ended after it" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    try idleFrame(dev); // frame 1, slot 0: ends before the upload
    try upload(dev);
    try idleFrame(dev); // frame 2, slot 1: ends after it

    _ = try dev.beginFrame(); // frame 3 waits on frame 1, which does not cover it
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());
    try dev.endFrame();

    _ = try dev.beginFrame(); // frame 4 waits on frame 2, which does
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try dev.endFrame();
}

test "an upload after the last frame is finished by waitIdle" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    try idleFrame(dev);
    try idleFrame(dev);
    try upload(dev);
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());

    dev.waitIdle();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
}

test "every submission made during a frame is covered by that frame's wait" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    _ = try dev.beginFrame(); // frame 1, slot 0
    try upload(dev);
    try upload(dev);
    try dev.endFrame();
    try testing.expectEqual(@as(usize, 2), dev.retiredCount());

    try idleFrame(dev);
    _ = try dev.beginFrame();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try dev.endFrame();
}

test "rule 3: a buffer an upload used is not writable until a wait covers the upload" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const staging = try dev.createBuffer(.{ .size = 16, .usage = .{ .copy_src = true }, .memory = .upload });
    const target = try dev.createBuffer(.{ .size = 16, .usage = .{ .copy_dst = true } });
    var cmd = try dev.beginCommandBuffer();
    try cmd.copyBufferToBuffer(.{ .src = staging, .dst = target, .size = 16 });
    try cmd.submit();

    // No frame has begun, so a model built on frame indices would call this safe. The copy may
    // still be reading it.
    _ = try dev.mapBuffer(staging);
    try testing.expect(dev.hasViolation(.frame_ring));

    dev.clearViolations();
    dev.waitIdle();
    _ = try dev.mapBuffer(staging);
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

/// Every kind of resource created, used in a frame and destroyed with that frame unfinished,
/// against whatever allocator it is handed.
fn createUseAndRetire(gpa: Allocator) !void {
    const dev = try Device.init(gpa, .{});
    defer dev.deinit();

    const staging = try dev.createBuffer(.{ .size = 16, .usage = .{ .copy_src = true }, .memory = .upload });
    const uniforms = try dev.createBuffer(.{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
    const texture = try dev.createTexture(.{
        .size = .{ .width = 4, .height = 4 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
        .initial_state = .shader_read,
    });
    const sampler = try dev.createSampler(.{});
    const shader = try dev.createShaderModuleFromSource(.{ .source = "stub" });
    const group_layout = try dev.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .type = .uniform_buffer, .visibility = .both },
        .{ .binding = 1, .type = .sampled_texture, .visibility = .{ .fragment = true } },
        .{ .binding = 2, .type = .sampler, .visibility = .{ .fragment = true } },
    } });
    const group = try dev.createBindGroup(.{ .layout = group_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .uniform_buffer = .{ .buffer = uniforms } } },
        .{ .binding = 1, .resource = .{ .sampled_texture = texture } },
        .{ .binding = 2, .resource = .{ .sampler = sampler } },
    } });
    const layout = try dev.createPipelineLayout(.{ .bind_group_layouts = &.{group_layout} });
    const pipe = try dev.createRenderPipeline(.{
        .layout = layout,
        .vertex_shader = shader,
        .fragment_shader = shader,
        .color_targets = &.{.{ .format = .bgra8_unorm_srgb }},
    });

    const frame = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    try cmd.copyBufferToBuffer(.{ .src = staging, .dst = uniforms, .size = 16 });
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setPipeline(pipe);
    pass.setBindGroup(0, group);
    pass.draw(.{ .vertex_count = 3 });
    pass.end();
    try cmd.submit();
    try dev.endFrame();

    // None of these may allocate: a destroy has no error to report a failure with, so a run
    // that failed an allocation inside one would surface as a swallowed failure.
    dev.destroyRenderPipeline(pipe);
    dev.destroyPipelineLayout(layout);
    dev.destroyBindGroup(group);
    dev.destroyBindGroupLayout(group_layout);
    dev.destroyShaderModule(shader);
    dev.destroySampler(sampler);
    dev.destroyTexture(texture);
    dev.destroyBuffer(uniforms);
    dev.destroyBuffer(staging);
    try testing.expectEqual(@as(usize, 9), dev.retiredCount());
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "no allocation failure leaks, and no destroy needs an allocation" {
    try std.testing.checkAllAllocationFailures(testing.allocator, createUseAndRetire, .{});
}

// -- failed frames and abandoned recordings -------------------------------------------

test "a failed acquisition opens no frame and spends no frame index" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    inline for (.{ error.SurfaceUnavailable, error.SurfaceLost, error.DeviceLost }) |outcome| {
        dev.faults.begin_frame = outcome;
        try testing.expectError(outcome, dev.beginFrame());
        try testing.expect(!dev.in_frame);
        try testing.expectEqual(@as(u64, 0), dev.frame_index);
    }
    // Nothing is owed to `endFrame` for them, and the next acquisition is frame 1.
    const frame = try dev.beginFrame();
    try testing.expectEqual(@as(u64, 1), frame.index);
    try dev.endFrame();
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "a frame that fails to finish still leaves the marker its submissions are waited through" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const buffer = try dev.createBuffer(.{ .size = 16, .usage = .{ .vertex = true } });
    _ = try dev.beginFrame();
    const cmd = try dev.beginCommandBuffer();
    try cmd.bufferBarrier(&.{.{ .buffer = buffer, .from = .undefined, .to = .shader_read }});
    try cmd.submit();
    dev.faults.end_frame = error.DeviceLost;
    try testing.expectError(error.DeviceLost, dev.endFrame());
    try testing.expect(!dev.in_frame);

    dev.destroyBuffer(buffer);
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());
    // Round the ring to the failed frame's slot. The frame between waits for nothing of it;
    // the slot's own wait covers its submission, and only then is the buffer released.
    for ([_]usize{ 1, 0 }) |retained| {
        _ = try dev.beginFrame();
        try testing.expectEqual(retained, dev.retiredCount());
        try dev.endFrame();
    }
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "a submission the device refuses consumes the command buffer and holds nothing back" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const buffer = try dev.createBuffer(.{ .size = 16, .usage = .{ .vertex = true } });
    const cmd = try dev.beginCommandBuffer();
    dev.destroyBuffer(buffer);
    dev.faults.submit = error.DeviceLost;
    try testing.expectError(error.DeviceLost, cmd.submit());

    try testing.expectEqual(@as(usize, 0), dev.timeline.open.items.len);
    try testing.expectEqual(@as(u64, 0), dev.timeline.submitted);
    dev.waitIdle();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
}

test "a discarded recording holds nothing back" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const buffer = try dev.createBuffer(.{ .size = 16, .usage = .{ .vertex = true } });
    const cmd = try dev.beginCommandBuffer();
    dev.destroyBuffer(buffer);
    // Open when the buffer was destroyed, so it could have used it.
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());

    cmd.discard();
    try testing.expectEqual(@as(usize, 0), dev.timeline.open.items.len);
    // Nothing was submitted, so the wait has nothing to finish and the buffer goes.
    dev.waitIdle();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "rule 8: a recording is discarded only once its passes have ended" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const frame = try dev.beginFrame();
    const cmd = try dev.beginCommandBuffer();
    _ = try cmd.beginRenderPass(.{ .color = &.{.{ .texture = frame.surface_texture, .final_state = .present }} });
    cmd.discard();
    try testing.expect(dev.hasViolation(.encoder_discipline));
    try dev.endFrame();
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

test "rule 10: a vertex buffer slot beyond the guaranteed maximum is caught" {
    // Eight is a contract limit, not a backend capacity (`rhi.md` §9): Metal's argument
    // table is shared, so a ninth slot has nowhere to go on a conforming backend.
    var fx = try Fixture.init();
    defer fx.deinit();

    const spare = try fx.dev.createBuffer(.{ .size = 64, .usage = .{ .vertex = true } });
    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setVertexBuffer(pipeline.max_vertex_buffers, spare, 0);
    pass.end();

    try testing.expect(fx.dev.hasViolation(.limits));
}

test "rule 10: the last guaranteed vertex buffer slot is accepted" {
    // The other half of the rule, and the half that catches an off-by-one that would make
    // the engine reject a binding every conforming backend must support.
    var fx = try Fixture.init();
    defer fx.deinit();

    const spare = try fx.dev.createBuffer(.{ .size = 64, .usage = .{ .vertex = true } });
    const frame = try fx.dev.beginFrame();
    var cmd = try fx.dev.beginCommandBuffer();
    var pass = try cmd.beginRenderPass(.{
        .color = &.{.{ .texture = frame.surface_texture, .initial_state = .undefined, .final_state = .present }},
    });
    pass.setVertexBuffer(pipeline.max_vertex_buffers - 1, spare, 0);
    pass.end();
    try cmd.submit();
    try fx.dev.endFrame();

    try testing.expectEqual(@as(usize, 0), fx.dev.violationCount());
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

test "rule 10: a copy region that does not fit the destination is caught" {
    // The failure a runtime-packed atlas reaches by packing one sprite too many. Metal
    // clamps some of these and produces garbage for the rest; Vulkan and D3D12 call it
    // undefined behaviour. Here it is a named rule with the numbers in the message.
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const atlas = try dev.createTexture(.{
        .label = "atlas",
        .size = .{ .width = 64, .height = 64 },
        .format = .rgba8_unorm_srgb,
        .usage = .{ .sampled = true, .copy_dst = true },
    });
    const staging = try dev.createBuffer(.{
        .size = 16 * 16 * 4,
        .usage = .{ .copy_src = true },
        .memory = .upload,
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    try cmd.textureBarrier(&.{.{ .texture = atlas, .from = .undefined, .to = .copy_dst }});
    // 16 wide at x=56 runs eight texels past the right edge. One axis is enough.
    try cmd.copyBufferToTexture(.{
        .src = staging,
        .dst = atlas,
        .dst_origin = .{ .x = 56, .y = 0 },
        .size = .{ .width = 16, .height = 16 },
    });
    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(dev.hasViolation(.limits));
}

test "rule 10: a copy that exactly reaches the far edge is accepted" {
    // The boundary is the interesting case: an off-by-one here would reject the last
    // shelf of every atlas, which is precisely the packing a packer aims for.
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const atlas = try dev.createTexture(.{
        .label = "atlas",
        .size = .{ .width = 64, .height = 64 },
        .format = .rgba8_unorm_srgb,
        .usage = .{ .sampled = true, .copy_dst = true },
    });
    const staging = try dev.createBuffer(.{
        .size = 16 * 16 * 4,
        .usage = .{ .copy_src = true },
        .memory = .upload,
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    try cmd.textureBarrier(&.{.{ .texture = atlas, .from = .undefined, .to = .copy_dst }});
    try cmd.copyBufferToTexture(.{
        .src = staging,
        .dst = atlas,
        .dst_origin = .{ .x = 48, .y = 48 },
        .size = .{ .width = 16, .height = 16 },
    });
    try cmd.submit();
    try testing.expectEqual(@as(usize, 0), dev.violationCount());
}

test "rule 10: a copy naming a mip level the texture does not have is caught" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const tex = try dev.createTexture(.{
        .label = "one-level",
        .size = .{ .width = 8, .height = 8 },
        .format = .rgba8_unorm,
        .usage = .{ .copy_dst = true },
    });
    const staging = try dev.createBuffer(.{
        .size = 4,
        .usage = .{ .copy_src = true },
        .memory = .upload,
    });

    _ = try dev.beginFrame();
    var cmd = try dev.beginCommandBuffer();
    try cmd.textureBarrier(&.{.{ .texture = tex, .from = .undefined, .to = .copy_dst }});
    try cmd.copyBufferToTexture(.{
        .src = staging,
        .dst = tex,
        .dst_mip_level = 1,
        .size = .{ .width = 1, .height = 1 },
    });
    try testing.expectError(error.ValidationFailed, cmd.submit());
    try testing.expect(dev.hasViolation(.limits));
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

// -- rule 11: usage ------------------------------------------------------------------
//
// Every row is tested both ways, on two resources that differ only in the flag the row is
// about, so the legal case is evidence that the check reads that flag and nothing else.

fn bufferWith(dev: *Device, comptime flag: []const u8, has: bool) !resource.BufferHandle {
    var usage: resource.BufferUsage = .{};
    @field(usage, flag) = has;
    return dev.createBuffer(.{ .label = flag, .size = 64, .usage = usage });
}

fn textureWith(dev: *Device, comptime flag: []const u8, has: bool, texture_format: format.TextureFormat) !resource.TextureHandle {
    var usage: resource.TextureUsage = .{};
    @field(usage, flag) = has;
    return dev.createTexture(.{
        .label = flag,
        .size = .{ .width = 8, .height = 8 },
        .format = texture_format,
        .usage = usage,
    });
}

/// Submits `cmd` and returns how many violations its recording produced. Every one must be
/// rule 11, and submission must have failed exactly when there were any. Clears them, so the
/// next case starts clean.
fn usageViolations(dev: *Device, cmd: *CommandBuffer) !usize {
    const failed = if (cmd.submit()) |_| false else |_| true;
    const count = dev.violationCount();
    for (dev.violations()) |v| try testing.expectEqual(Rule.usage, v.rule);
    try testing.expectEqual(count > 0, failed);
    dev.clearViolations();
    return count;
}

test "rule 11: vertex and index bindings need vertex and index usage" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    inline for (.{ "vertex", "index" }) |flag| {
        for ([_]bool{ true, false }) |has| {
            const buffer = try bufferWith(dev, flag, has);
            const frame = try dev.beginFrame();
            const cmd = try dev.beginCommandBuffer();
            const pass = try cmd.beginRenderPass(.{
                .color = &.{.{ .texture = frame.surface_texture, .final_state = .present }},
            });
            if (comptime std.mem.eql(u8, flag, "vertex")) {
                pass.setVertexBuffer(0, buffer, 0);
            } else {
                pass.setIndexBuffer(buffer, .uint32, 0);
            }
            pass.end();
            // A setter returns nothing, so submission is where the recorder hears of it.
            try testing.expectEqual(@as(usize, if (has) 0 else 1), try usageViolations(dev, cmd));
            try dev.endFrame();
        }
    }
}

test "rule 11: uniform, storage and sampled bindings need the matching usage" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    inline for (.{
        .{ "uniform", pipeline.BindingType.uniform_buffer },
        .{ "storage", pipeline.BindingType.storage_buffer },
        .{ "sampled", pipeline.BindingType.sampled_texture },
    }) |row| {
        const layout = try dev.createBindGroupLayout(.{
            .entries = &.{.{ .binding = 0, .type = row[1], .visibility = .both }},
        });
        for ([_]bool{ true, false }) |has| {
            const bound: pipeline.BindingResource = switch (row[1]) {
                .uniform_buffer => .{ .uniform_buffer = .{ .buffer = try bufferWith(dev, row[0], has) } },
                .storage_buffer => .{ .storage_buffer = .{ .buffer = try bufferWith(dev, row[0], has) } },
                .sampled_texture => .{ .sampled_texture = try textureWith(dev, row[0], has, .rgba8_unorm) },
                .sampler => unreachable,
            };
            const result = dev.createBindGroup(.{ .layout = layout, .entries = &.{.{ .binding = 0, .resource = bound }} });
            if (has) {
                _ = try result;
                try testing.expectEqual(@as(usize, 0), dev.violationCount());
            } else {
                // A descriptor, so refused as a group breaking rule 4 is, and named as rule 11.
                try testing.expectError(error.InvalidDescriptor, result);
                try testing.expectEqual(@as(usize, 1), dev.violationCount());
                try testing.expect(dev.hasViolation(.usage));
                dev.clearViolations();
            }
        }
    }
}

test "rule 11: a buffer copy needs copy_src on its source and copy_dst on its destination" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    for ([_][2]bool{ .{ true, true }, .{ false, true }, .{ true, false } }) |has| {
        const src = try bufferWith(dev, "copy_src", has[0]);
        const dst = try bufferWith(dev, "copy_dst", has[1]);
        const cmd = try dev.beginCommandBuffer();
        try cmd.copyBufferToBuffer(.{ .src = src, .dst = dst, .size = 64 });
        try testing.expectEqual(@as(usize, if (has[0] and has[1]) 0 else 1), try usageViolations(dev, cmd));
    }
}

test "rule 11: a buffer-to-texture copy needs copy_src on the buffer and copy_dst on the texture" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    for ([_][2]bool{ .{ true, true }, .{ false, true }, .{ true, false } }) |has| {
        const src = try bufferWith(dev, "copy_src", has[0]);
        const dst = try textureWith(dev, "copy_dst", has[1], .rgba8_unorm);
        const cmd = try dev.beginCommandBuffer();
        // The barrier is how a texture reaches copy_dst, and it is refused as well when the flag
        // is missing: no state a caller can reach legally stands in for the usage.
        try cmd.textureBarrier(&.{.{ .texture = dst, .from = .undefined, .to = .copy_dst }});
        try cmd.copyBufferToTexture(.{ .src = src, .dst = dst, .size = .{ .width = 4, .height = 4 } });
        const expected: usize = if (!has[0]) 1 else if (!has[1]) 2 else 0;
        try testing.expectEqual(expected, try usageViolations(dev, cmd));
    }
}

test "rule 11: colour and depth attachments need render_target and depth_stencil usage" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    for ([_]bool{ true, false }) |has| {
        const target = try textureWith(dev, "render_target", has, .rgba8_unorm);
        const cmd = try dev.beginCommandBuffer();
        const pass = try cmd.beginRenderPass(.{
            .color = &.{.{ .texture = target, .final_state = .render_target }},
        });
        pass.end();
        // Without the flag the pass both draws into it and leaves it in render_target.
        try testing.expectEqual(@as(usize, if (has) 0 else 2), try usageViolations(dev, cmd));
    }
    for ([_]bool{ true, false }) |has| {
        const colour = try textureWith(dev, "render_target", true, .rgba8_unorm);
        const depth = try textureWith(dev, "depth_stencil", has, .depth32_float);
        const cmd = try dev.beginCommandBuffer();
        const pass = try cmd.beginRenderPass(.{
            .color = &.{.{ .texture = colour, .final_state = .render_target }},
            .depth = .{ .texture = depth, .final_state = .depth_stencil },
        });
        pass.end();
        try testing.expectEqual(@as(usize, if (has) 0 else 2), try usageViolations(dev, cmd));
    }
}

test "rule 11: a state a resource is declared to enter needs the usage that state describes" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    // Through a barrier: a texture that shaders read needs `sampled`...
    for ([_]bool{ true, false }) |has| {
        const tex = try textureWith(dev, "sampled", has, .rgba8_unorm);
        const cmd = try dev.beginCommandBuffer();
        try cmd.textureBarrier(&.{.{ .texture = tex, .from = .undefined, .to = .shader_read }});
        try testing.expectEqual(@as(usize, if (has) 0 else 1), try usageViolations(dev, cmd));
    }
    // ...and a buffer the GPU reads needs one of the ways a buffer can be bound.
    for ([_]bool{ true, false }) |has| {
        const buf = try bufferWith(dev, "uniform", has);
        const cmd = try dev.beginCommandBuffer();
        try cmd.bufferBarrier(&.{.{ .buffer = buf, .from = .undefined, .to = .shader_read }});
        try testing.expectEqual(@as(usize, if (has) 0 else 1), try usageViolations(dev, cmd));
    }
    // At creation, where the state is part of a descriptor and so is refused.
    for ([_]bool{ true, false }) |has| {
        const result = dev.createTexture(.{
            .size = .{ .width = 8, .height = 8 },
            .format = .rgba8_unorm,
            .usage = .{ .sampled = has },
            .initial_state = .shader_read,
        });
        if (has) {
            _ = try result;
            try testing.expectEqual(@as(usize, 0), dev.violationCount());
        } else {
            try testing.expectError(error.InvalidDescriptor, result);
            try testing.expect(dev.hasViolation(.usage));
            dev.clearViolations();
        }
    }
}

test "rule 11: only the device's surface is presented, whatever another texture's usage" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const dev = fx.dev;

    const offscreen = try dev.createTexture(.{
        .label = "offscreen",
        .size = .{ .width = 8, .height = 8 },
        .format = .bgra8_unorm_srgb,
        .usage = .{ .sampled = true, .render_target = true, .copy_src = true, .copy_dst = true },
    });

    // The surface's own descriptor is what lets a frame draw into it and present it.
    const frame = try dev.beginFrame();
    for ([_]resource.TextureHandle{ frame.surface_texture, offscreen }, [_]usize{ 0, 1 }) |target, expected| {
        const cmd = try dev.beginCommandBuffer();
        const pass = try cmd.beginRenderPass(.{ .color = &.{.{ .texture = target, .final_state = .present }} });
        pass.end();
        try testing.expectEqual(expected, try usageViolations(dev, cmd));
    }
    try dev.endFrame();
}

// -- the mechanism itself ------------------------------------------------------------

test "the rules are exactly the eleven the design document lists" {
    // If a rule is added or removed, that is a contract change and belongs in
    // `docs/design/rhi.md` §11 first. Asserted so a casual edit fails a test.
    const rules = std.enums.values(Rule);
    try testing.expectEqual(@as(usize, 11), rules.len);
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
