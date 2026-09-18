//! The Vulkan backend (ADR-0033, ADR-0037, ADR-0038), being brought up in M13.
//!
//! **What exists through Step 5:** the system loader and dispatch tables; a validated device and
//! submission timeline; resources, copies and completion-backed retirement; and SPIR-V shader
//! modules, persistent descriptor sets, layouts and monolithic graphics pipelines. Pass commands
//! and presentation arrive in Steps 6–7. Until Step 7 completes `interface.check`, only
//! `zig build vulkan-test -Drhi=vulkan` builds this file (`docs/design/vulkan.md` §11).
//!
//! **Ownership.** A `Device` owns, in creation order: the loader, the instance, the validation
//! messenger, the surface, the logical device, the timeline semaphore and the command pool.
//! `teardown` releases whichever of those exist, newest first, and closes the loader last, so a
//! failed initialization and an ordinary `deinit` leave through the same code.
//!
//! **Completion.** Every submission signals the device's one timeline semaphore with its own
//! serial, the strictly increasing number `lifetime.Timeline` gives it. Waiting for serial S is
//! waiting for the semaphore to reach S, and since the queue executes in submission order that
//! covers everything before S as well. A command buffer is begun again only once a wait or a poll
//! has seen its submission finish, or when it never reached the queue.
//!
//! Design: `docs/design/vulkan.md` §§4–7.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const platform = @import("platform");

const command = @import("../../command.zig");
const format = @import("../../format.zig");
const interface = @import("../../interface.zig");
const lifetime = @import("../../lifetime.zig");
const pipeline = @import("../../pipeline.zig");
const resource = @import("../../resource.zig");
const dispatch = @import("dispatch.zig");
const layout = @import("layout.zig");
const memory = @import("memory.zig");
const selection = @import("selection.zig");
const spirv = @import("spirv.zig");
const vk = @import("vk.zig");
const c = vk.c;

const Allocator = std.mem.Allocator;
const assert = core.assert;
const log = core.log.scoped(.rhi);

pub const Validation = enum {
    /// No layer and no messenger. What `init` uses.
    off,
    /// `VK_LAYER_KHRONOS_validation` with synchronization validation, reported through
    /// `core.log`. Initialization fails if any of it is unavailable, rather than running
    /// unvalidated (ADR-0038). Errors are logged at error level, so Zig's test runner fails a test
    /// that provokes one.
    required,
};

/// The points initialization can be made to fail at, in the order it reaches them.
pub const Stage = enum {
    open_loader,
    load_global,
    instance_version,
    instance_layers,
    instance_extensions,
    create_instance,
    load_instance,
    create_messenger,
    create_surface,
    enumerate_devices,
    select_device,
    create_device,
    load_device,
    create_timeline,
    create_command_pool,
    create_empty_set_layout,
};

/// How a device is brought up. `init` takes the defaults.
pub const Options = struct {
    validation: Validation = .off,
    /// The layer `.required` validation asks for. Test only: naming one that is not installed is
    /// how the refusal is exercised on a machine that has the real one.
    validation_layer: [:0]const u8 = "VK_LAYER_KHRONOS_validation",
    /// Test only: the stage whose call is replaced by `fail_with`, so its cleanup runs on a
    /// healthy driver (`vulkan.md` §7). Never set outside a test.
    fail_at: ?Stage = null,
    fail_with: c.VkResult = c.VK_ERROR_INITIALIZATION_FAILED,
};

/// Results a test can make the next call return, each consumed by the call it names.
pub const Faults = struct {
    submit: ?c.VkResult = null,
    /// The next resource creation that reaches `stage` gets `result` instead of its Vulkan call.
    resource: ?ResourceFault = null,
};

/// The Vulkan calls creating a resource makes, in the order it makes them.
pub const ResourceStage = enum {
    create_buffer,
    create_image,
    allocate_memory,
    bind_memory,
    map_memory,
    create_view,
    create_sampler,
    initial_transition,
    create_shader,
    create_bind_group_layout,
    create_descriptor_pool,
    allocate_descriptor_set,
    create_pipeline_layout,
    create_render_pipeline,
};

pub const ResourceFault = struct { stage: ResourceStage, result: c.VkResult };

/// What the validation messenger has reported. Counted atomically, because a layer may call
/// back from a thread of its own.
pub const Messages = struct {
    errors: std.atomic.Value(u32) = .init(0),
    warnings: std.atomic.Value(u32) = .init(0),
    infos: std.atomic.Value(u32) = .init(0),
};

/// The physical device a `Device` runs on, as the driver described it.
pub const Adapter = struct {
    name_buf: [256]u8 = @splat(0),
    device_type: selection.DeviceType = .other,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    api_version: u32 = 0,
    driver_version: u32 = 0,

    pub fn name(self: *const Adapter) []const u8 {
        return std.mem.sliceTo(&self.name_buf, 0);
    }
};

// -- stored state ---------------------------------------------------------------------

const BufferState = struct {
    desc: resource.BufferDesc,
    native: c.VkBuffer,
    allocation: c.VkDeviceMemory,
    /// The persistent mapping of an upload or readback buffer; null for device-local memory,
    /// which is never mapped whatever its heap allows (§5.2).
    mapped: ?[*]u8,
    /// The memory is not host-coherent, so writes are flushed and readbacks invalidated.
    explicit_sync: bool,
    /// The newest recording that wrote it by a copy, or 0. A later transfer in the same recording
    /// is isolated from that write by a barrier, which the queue needs and the RHI does not ask for.
    last_write: u64 = 0,
};

const TextureState = struct {
    desc: resource.TextureDesc,
    image: c.VkImage,
    view: c.VkImageView,
    allocation: c.VkDeviceMemory,
    /// As `BufferState.last_write`.
    last_write: u64 = 0,
};

const SamplerState = struct { native: c.VkSampler };

const ShaderState = struct {
    native: c.VkShaderModule,
    /// Retained only to validate entry-point stage/name before pipeline creation. The driver
    /// copied the code during `vkCreateShaderModule`; no command ever reads this slice.
    bytes: []align(4) u8,
};

/// Native set layouts are shared by their public handle, every allocated set and every
/// pipeline-layout backing that names them. The small owner allocation stays until device
/// teardown so refcount cascades never leave dangling bookkeeping pointers.
const BindGroupLayoutBacking = struct {
    native: c.VkDescriptorSetLayout,
    entries: []pipeline.BindGroupLayoutEntry,
    refs: usize = 1,
    released: bool = false,
};

const BindGroupLayoutState = struct { backing: *BindGroupLayoutBacking };

const DescriptorPool = struct {
    native: c.VkDescriptorPool,
    live_sets: u32 = 0,
};

const BindGroupState = struct {
    native: c.VkDescriptorSet,
    pool: *DescriptorPool,
    layout: *BindGroupLayoutBacking,
    entries: []pipeline.BindGroupEntry,
};

/// A render pipeline retains this independently of the public pipeline-layout handle.
const PipelineLayoutBacking = struct {
    native: c.VkPipelineLayout,
    groups: []?*BindGroupLayoutBacking,
    inline_constant_bytes: u32,
    refs: usize = 1,
    released: bool = false,
};

const PipelineLayoutState = struct { backing: *PipelineLayoutBacking };

const RenderPipelineState = struct {
    native: c.VkPipeline,
    layout: *PipelineLayoutBacking,
    primitive: pipeline.PrimitiveState,
};

/// What a destroyed resource leaves behind until the recordings that could use it finish. The
/// staging buffer a repacked copy made is retired the same way, after that one recording.
const Retired = union(enum) {
    buffer: struct { native: c.VkBuffer, allocation: c.VkDeviceMemory },
    texture: struct { image: c.VkImage, view: c.VkImageView, allocation: c.VkDeviceMemory },
    sampler: c.VkSampler,
    shader: ShaderState,
    bind_group_layout: *BindGroupLayoutBacking,
    bind_group: BindGroupState,
    pipeline_layout: *PipelineLayoutBacking,
    render_pipeline: RenderPipelineState,

    fn release(self: Retired, dev: *Device) void {
        const fns = &dev.device_fns;
        switch (self) {
            .buffer => |b| {
                fns.vkDestroyBuffer(dev.device, b.native, null);
                dev.freeMemory(b.allocation);
            },
            .texture => |t| {
                fns.vkDestroyImageView(dev.device, t.view, null);
                fns.vkDestroyImage(dev.device, t.image, null);
                dev.freeMemory(t.allocation);
            },
            .sampler => |sampler| fns.vkDestroySampler(dev.device, sampler, null),
            .shader => |shader| {
                fns.vkDestroyShaderModule(dev.device, shader.native, null);
                dev.gpa.free(shader.bytes);
            },
            .bind_group_layout => |backing| dev.releaseBindGroupLayout(backing),
            .bind_group => |group| {
                const freed = fns.vkFreeDescriptorSets(dev.device, group.pool.native, 1, &group.native);
                if (freed != c.VK_SUCCESS) {
                    log.warn("vulkan: freeing a descriptor set failed: {s}", .{vk.resultName(freed)});
                } else {
                    group.pool.live_sets -= 1;
                }
                dev.gpa.free(group.entries);
                dev.dropBindGroupLayout(group.layout);
            },
            .pipeline_layout => |backing| dev.releasePipelineLayout(backing),
            .render_pipeline => |render_pipeline| {
                fns.vkDestroyPipeline(dev.device, render_pipeline.native, null);
                dev.dropPipelineLayout(render_pipeline.layout);
            },
        }
    }
};

pub const Device = struct {
    gpa: Allocator,
    desc: interface.DeviceDesc,
    options: Options,
    faults: Faults = .{},

    loader: ?platform.os.Library = null,
    get_instance_proc_addr: ?dispatch.GetInstanceProcAddr = null,
    global: dispatch.Global = undefined,

    instance: c.VkInstance = null,
    /// Resolved the moment the instance exists, so a failure loading the rest of the instance
    /// table can still destroy it.
    destroy_instance: ?dispatch.Fn(c.PFN_vkDestroyInstance) = null,
    instance_fns: dispatch.Instance = undefined,

    debug_fns: dispatch.DebugUtils = undefined,
    messenger: c.VkDebugUtilsMessengerEXT = null,
    /// Borrowed by both messengers — the one covering instance creation and destruction, and the
    /// one for everything between — so it lives exactly as long as the device does.
    messages: Messages = .{},

    surface_fns: dispatch.Surface = undefined,
    surface: c.VkSurfaceKHR = null,

    physical: c.VkPhysicalDevice = null,
    adapter: Adapter = .{},
    queue_family: u32 = 0,

    device: c.VkDevice = null,
    device_fns: dispatch.Device = undefined,
    queue: c.VkQueue = null,
    timeline_semaphore: c.VkSemaphore = null,
    command_pool: c.VkCommandPool = null,

    /// Every submission in queue order, each holding its native command buffer until a wait or
    /// a poll has seen it finish.
    timeline: lifetime.Timeline(c.VkCommandBuffer) = .{},
    /// Sticky. A lost device is waited on for nothing and begins nothing more (§8).
    lost: bool = false,

    command_buffers: std.ArrayList(*CommandBuffer) = .empty,
    free_command_buffers: std.ArrayList(*CommandBuffer) = .empty,
    render_passes: std.ArrayList(*RenderPass) = .empty,
    free_render_passes: std.ArrayList(*RenderPass) = .empty,
    /// How many native command buffers the pool has allocated. `free_native` always has room for
    /// all of them, so returning one can never fail.
    native_count: usize = 0,
    free_native: std.ArrayList(c.VkCommandBuffer) = .empty,

    /// The chosen device's limits and memory types, read once when it is chosen.
    limits: c.VkPhysicalDeviceLimits = undefined,
    memory_types: [32]memory.TypeFlags = @splat(.{}),
    memory_type_count: u32 = 0,
    /// Live `VkDeviceMemory` allocations, held under `maxMemoryAllocationCount` (§5.2).
    allocations: u32 = 0,
    /// Test only: what `capabilities` reports as `unified_memory`, so both of the renderer's
    /// memory paths can be exercised on one machine.
    unified_override: ?bool = null,

    buffers: core.HandlePool(resource.Buffer, BufferState) = .empty,
    textures: core.HandlePool(resource.Texture, TextureState) = .empty,
    samplers: core.HandlePool(resource.Sampler, SamplerState) = .empty,
    shaders: core.HandlePool(resource.ShaderModule, ShaderState) = .empty,
    bind_group_layouts: core.HandlePool(pipeline.BindGroupLayout, BindGroupLayoutState) = .empty,
    bind_groups: core.HandlePool(pipeline.BindGroup, BindGroupState) = .empty,
    pipeline_layouts: core.HandlePool(pipeline.PipelineLayout, PipelineLayoutState) = .empty,
    pipelines: core.HandlePool(pipeline.RenderPipeline, RenderPipelineState) = .empty,
    descriptor_pools: std.ArrayList(*DescriptorPool) = .empty,
    bind_group_layout_backings: std.ArrayList(*BindGroupLayoutBacking) = .empty,
    pipeline_layout_backings: std.ArrayList(*PipelineLayoutBacking) = .empty,
    /// The immutable empty layout occupies holes without renumbering later descriptor sets.
    empty_set_layout: c.VkDescriptorSetLayout = null,
    tearing_down: bool = false,
    retired: lifetime.Retirement(Retired) = .{},

    pub fn init(gpa: Allocator, desc: interface.DeviceDesc) interface.InitError!*Device {
        return initWith(gpa, desc, .{});
    }

    pub fn initWith(gpa: Allocator, desc: interface.DeviceDesc, options: Options) interface.InitError!*Device {
        const wsi = try surfaceExtension(desc.surface);

        const self = try gpa.create(Device);
        self.* = .{ .gpa = gpa, .desc = desc, .options = options };
        errdefer self.teardown();

        try self.openLoader();
        try self.createInstance(wsi);
        if (options.validation == .required) try self.createMessenger();
        if (wsi != null) try self.createSurface();
        try self.chooseDevice(wsi != null);
        try self.createDevice(wsi != null);
        try self.createQueueObjects();
        try self.createEmptySetLayout();

        log.info("rhi backend: vulkan on '{s}' ({t}, Vulkan {d}.{d}), queue family {d}, {s}{s}", .{
            self.adapter.name(),
            self.adapter.device_type,
            selection.versionMajor(self.adapter.api_version),
            selection.versionMinor(self.adapter.api_version),
            self.queue_family,
            if (wsi != null) "presenting" else "offscreen",
            if (options.validation == .required) ", validation required" else "",
        });
        return self;
    }

    pub fn capabilities(self: *Device) command.Capabilities {
        const limits = &self.limits;
        return .{
            .max_texture_dimension = limits.maxImageDimension2D,
            .max_bind_groups = pipeline.max_bind_groups,
            .max_inline_constant_bytes = pipeline.max_inline_constant_bytes,
            .max_vertex_buffers = pipeline.max_vertex_buffers,
            .unified_memory = self.unified_override orelse memory.unified(self.memory_types[0..self.memory_type_count]),
            // SPIR-V is compiled at build time; there is no runtime compiler (ADR-0038).
            .runtime_shader_compilation = false,
            // Negotiated with a swapchain in Step 7. Offscreen, the format a surface would prefer.
            .surface_format = .bgra8_unorm_srgb,
            .uniform_buffer_offset_alignment = @intCast(limits.minUniformBufferOffsetAlignment),
            .storage_buffer_offset_alignment = @intCast(limits.minStorageBufferOffsetAlignment),
            .max_uniform_buffer_binding_size = limits.maxUniformBufferRange,
            .max_storage_buffer_binding_size = limits.maxStorageBufferRange,
        };
    }

    /// Waits for everything submitted, discards what was never submitted, waits for the queue to
    /// go idle, and releases the lot.
    pub fn deinit(self: *Device) void {
        self.waitIdle();
        // A recording never submitted never will be; nothing it could use waits for it any longer.
        for (self.command_buffers.items) |cb| {
            if (cb.open) {
                self.timeline.discard(cb.recording);
                cb.open = false;
            }
        }
        self.collect();
        if (!self.lost) {
            // The timeline covers submissions. Queue idleness after it is the boundary §8 names for
            // teardown; with nothing presented yet it adds no wait, and it is where that wait will be.
            const idle = self.device_fns.vkDeviceWaitIdle(self.device);
            if (idle == c.VK_ERROR_DEVICE_LOST) self.markLost("vkDeviceWaitIdle", false);
        }
        self.teardown();
    }

    /// Waits until the queue has finished everything submitted so far and recycles what that frees.
    /// It finishes nothing that was never submitted, and waits for nothing on a lost device.
    pub fn waitIdle(self: *Device) void {
        self.waitThrough(self.timeline.submitted);
    }

    fn waitThrough(self: *Device, serial: u64) void {
        if (!self.lost and self.timeline.waitTarget(serial) != null) {
            const info: c.VkSemaphoreWaitInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                .semaphoreCount = 1,
                .pSemaphores = &self.timeline_semaphore,
                .pValues = &serial,
            };
            const waited = self.device_fns.vkWaitSemaphores(self.device, &info, std.math.maxInt(u64));
            if (waited == c.VK_SUCCESS) {
                self.timeline.complete(serial);
            } else if (waited == c.VK_ERROR_DEVICE_LOST) {
                self.markLost("vkWaitSemaphores", false);
            } else {
                log.warn("vulkan: waiting for submission {d} failed: {s}; nothing it used is released", .{
                    serial,
                    vk.resultName(waited),
                });
            }
        }
        self.collect();
    }

    /// Records whatever the queue has already finished, without waiting.
    fn poll(self: *Device) void {
        if (self.lost or self.timeline.completed == self.timeline.submitted) return;
        var value: u64 = 0;
        const read = self.device_fns.vkGetSemaphoreCounterValue(self.device, self.timeline_semaphore, &value);
        if (read == c.VK_SUCCESS) {
            self.timeline.complete(value);
        } else if (read == c.VK_ERROR_DEVICE_LOST) {
            self.markLost("vkGetSemaphoreCounterValue", false);
        }
        self.collect();
    }

    /// Returns every finished submission's command buffer to the free list, then releases every
    /// retired backing no unfinished recording could still use.
    fn collect(self: *Device) void {
        while (self.timeline.popCompleted()) |submission| self.free_native.appendAssumeCapacity(submission.token);
        const through = self.timeline.resolvedThrough();
        while (self.retired.next(through)) |backing| backing.release(self);
    }

    /// Backings destroyed and not yet released. Not part of the interface; tests read it.
    pub fn retiredCount(self: *const Device) usize {
        return self.retired.count();
    }

    fn markLost(self: *Device, comptime what: []const u8, was_injected: bool) void {
        if (!self.lost) {
            // Injected by a test, which expects it; an error-level line would fail that test.
            if (was_injected) {
                log.warn("vulkan: device lost at " ++ what ++ " (injected)", .{});
            } else {
                log.err("vulkan: device lost at " ++ what ++ "; nothing more can be rendered", .{});
            }
        }
        self.lost = true;
    }

    // -- resources -----------------------------------------------------------------------

    fn liveCount(self: *const Device) usize {
        return @as(usize, self.buffers.count()) + self.textures.count() + self.samplers.count() +
            self.shaders.count() + self.bind_group_layouts.count() + self.bind_groups.count() +
            self.pipeline_layouts.count() + self.pipelines.count();
    }

    /// Makes room to retire everything live plus `extra` more, before anything is published, so a
    /// destroy can never fail, leak or release early for want of memory.
    fn reserveRetirement(self: *Device, extra: usize) Allocator.Error!void {
        try self.retired.reserve(self.gpa, self.liveCount() + extra);
    }

    /// The caller's half of a destroy is done; the backing waits for every recording begun before it.
    fn retire(self: *Device, backing: Retired) void {
        self.retired.retire(backing, self.timeline.begun);
        self.collect();
    }

    /// The result a test substituted for `stage`, consumed.
    fn injectedResource(self: *Device, stage: ResourceStage) ?c.VkResult {
        const fault = self.faults.resource orelse return null;
        if (fault.stage != stage) return null;
        self.faults.resource = null;
        return fault.result;
    }

    const Allocation = struct { memory: c.VkDeviceMemory, type_index: u32 };
    const MemoryOwner = union(enum) { buffer: c.VkBuffer, image: c.VkImage };

    /// One allocation for one resource, from the best type its requirements allow (§5.2).
    fn allocate(
        self: *Device,
        requirements: c.VkMemoryRequirements,
        dedicated: c.VkMemoryDedicatedRequirements,
        owner: MemoryOwner,
        intent: resource.MemoryIntent,
    ) interface.ResourceError!Allocation {
        if (self.allocations >= self.limits.maxMemoryAllocationCount) {
            log.warn("vulkan: {d} memory allocations already reach the device's limit", .{self.allocations});
            return error.OutOfDeviceMemory;
        }
        const type_index = memory.chooseType(self.memory_types[0..self.memory_type_count], requirements.memoryTypeBits, intent) orelse {
            log.warn("vulkan: no memory type this resource allows can serve {t}", .{intent});
            return error.OutOfDeviceMemory;
        };
        const dedicated_info: c.VkMemoryDedicatedAllocateInfo = switch (owner) {
            .buffer => |b| .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .buffer = b },
            .image => |i| .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .image = i },
        };
        const use_dedicated = dedicated.requiresDedicatedAllocation != 0 or dedicated.prefersDedicatedAllocation != 0;
        const info: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = if (use_dedicated) &dedicated_info else null,
            .allocationSize = requirements.size,
            .memoryTypeIndex = type_index,
        };
        var allocation: c.VkDeviceMemory = null;
        const allocated = self.injectedResource(.allocate_memory) orelse
            self.device_fns.vkAllocateMemory(self.device, &info, null, &allocation);
        if (allocated != c.VK_SUCCESS) return resourceFailure(allocated, "vkAllocateMemory");
        self.allocations += 1;
        return .{ .memory = allocation, .type_index = type_index };
    }

    fn freeMemory(self: *Device, allocation: c.VkDeviceMemory) void {
        self.device_fns.vkFreeMemory(self.device, allocation, null);
        self.allocations -= 1;
    }

    const MadeBuffer = struct {
        native: c.VkBuffer,
        allocation: c.VkDeviceMemory,
        mapped: ?[*]u8,
        explicit_sync: bool,
    };

    /// A buffer bound to its own memory and, when mappable, mapped for its whole life.
    fn makeBuffer(self: *Device, size: u64, usage: u32, intent: resource.MemoryIntent) interface.ResourceError!MadeBuffer {
        const fns = &self.device_fns;
        const info: c.VkBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };
        var native: c.VkBuffer = null;
        const created = self.injectedResource(.create_buffer) orelse fns.vkCreateBuffer(self.device, &info, null, &native);
        if (created != c.VK_SUCCESS) return resourceFailure(created, "vkCreateBuffer");
        errdefer fns.vkDestroyBuffer(self.device, native, null);

        var dedicated: c.VkMemoryDedicatedRequirements = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS };
        var requirements: c.VkMemoryRequirements2 = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2, .pNext = &dedicated };
        const asked: c.VkBufferMemoryRequirementsInfo2 = .{ .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_REQUIREMENTS_INFO_2, .buffer = native };
        fns.vkGetBufferMemoryRequirements2(self.device, &asked, &requirements);

        const allocation = try self.allocate(requirements.memoryRequirements, dedicated, .{ .buffer = native }, intent);
        errdefer self.freeMemory(allocation.memory);
        const bound = self.injectedResource(.bind_memory) orelse fns.vkBindBufferMemory(self.device, native, allocation.memory, 0);
        if (bound != c.VK_SUCCESS) return resourceFailure(bound, "vkBindBufferMemory");

        var mapped: ?[*]u8 = null;
        if (intent.isMappable()) {
            var data: ?*anyopaque = null;
            const mapping = self.injectedResource(.map_memory) orelse
                fns.vkMapMemory(self.device, allocation.memory, 0, c.VK_WHOLE_SIZE, 0, &data);
            if (mapping != c.VK_SUCCESS) return resourceFailure(mapping, "vkMapMemory");
            mapped = @ptrCast(data);
        }
        return .{
            .native = native,
            .allocation = allocation.memory,
            .mapped = mapped,
            .explicit_sync = mapped != null and !self.memory_types[allocation.type_index].host_coherent,
        };
    }

    pub fn createBuffer(self: *Device, desc: resource.BufferDesc) interface.ResourceError!resource.BufferHandle {
        if (desc.size == 0 or !desc.usage.any()) return error.InvalidDescriptor;
        try self.reserveRetirement(1);
        const made = try self.makeBuffer(desc.size, bufferUsage(desc.usage), desc.memory);
        errdefer Retired.release(.{ .buffer = .{ .native = made.native, .allocation = made.allocation } }, self);
        return self.buffers.add(self.gpa, .{
            .desc = desc,
            .native = made.native,
            .allocation = made.allocation,
            .mapped = made.mapped,
            .explicit_sync = made.explicit_sync,
        });
    }

    pub fn destroyBuffer(self: *Device, handle: resource.BufferHandle) void {
        const state = self.buffers.getConst(handle) orelse return;
        const backing: Retired = .{ .buffer = .{ .native = state.native, .allocation = state.allocation } };
        _ = self.buffers.remove(handle);
        self.retire(backing);
    }

    /// The whole buffer. A readback in memory that is not host-coherent is invalidated first, so
    /// completed work's bytes are what the caller reads (§5.2).
    pub fn mapBuffer(self: *Device, handle: resource.BufferHandle) interface.MapError![]u8 {
        const state = self.buffers.getConst(handle) orelse return error.InvalidHandle;
        const bytes = state.mapped orelse return error.NotMappable;
        if (state.explicit_sync and state.desc.memory == .readback) self.syncMapping(state.allocation, .invalidate);
        return bytes[0..@intCast(state.desc.size)];
    }

    /// The mapping stays; an upload in memory that is not host-coherent is flushed, so the queue
    /// sees what was written.
    pub fn unmapBuffer(self: *Device, handle: resource.BufferHandle) void {
        const state = self.buffers.getConst(handle) orelse return;
        if (state.explicit_sync and state.desc.memory == .upload) self.syncMapping(state.allocation, .flush);
    }

    /// Always the whole mapping: a superset of any range rounded to the device's atom, and always valid.
    fn syncMapping(self: *Device, allocation: c.VkDeviceMemory, direction: enum { flush, invalidate }) void {
        const range: c.VkMappedMemoryRange = .{
            .sType = c.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = allocation,
            .size = c.VK_WHOLE_SIZE,
        };
        const synced = switch (direction) {
            .flush => self.device_fns.vkFlushMappedMemoryRanges(self.device, 1, &range),
            .invalidate => self.device_fns.vkInvalidateMappedMemoryRanges(self.device, 1, &range),
        };
        if (synced != c.VK_SUCCESS) log.warn("vulkan: {t} of a mapping failed: {s}", .{ direction, vk.resultName(synced) });
    }

    pub fn createTexture(self: *Device, desc: resource.TextureDesc) interface.ResourceError!resource.TextureHandle {
        if (desc.size.isEmpty() or !desc.usage.any()) return error.InvalidDescriptor;
        const levels = @max(desc.mip_levels, 1);
        if (levels > maxMipLevels(desc.size)) return error.InvalidDescriptor;
        if (desc.size.width > self.limits.maxImageDimension2D or desc.size.height > self.limits.maxImageDimension2D) {
            return error.InvalidDescriptor;
        }
        const vk_format = vkFormat(desc.format);
        var properties: c.VkFormatProperties = undefined;
        self.instance_fns.vkGetPhysicalDeviceFormatProperties(self.physical, vk_format, &properties);
        const needed = formatFeatures(desc.usage);
        if (properties.optimalTilingFeatures & needed != needed) {
            log.warn("vulkan: this device cannot use {t} for everything texture '{s}' declares", .{ desc.format, desc.label });
            return error.UnsupportedFormat;
        }
        try self.reserveRetirement(1);

        const fns = &self.device_fns;
        const info: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = vk_format,
            .extent = .{ .width = desc.size.width, .height = desc.size.height, .depth = 1 },
            .mipLevels = levels,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = imageUsage(desc.usage),
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var image: c.VkImage = null;
        const created = self.injectedResource(.create_image) orelse fns.vkCreateImage(self.device, &info, null, &image);
        if (created != c.VK_SUCCESS) return resourceFailure(created, "vkCreateImage");
        errdefer fns.vkDestroyImage(self.device, image, null);

        var dedicated: c.VkMemoryDedicatedRequirements = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS };
        var requirements: c.VkMemoryRequirements2 = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2, .pNext = &dedicated };
        const asked: c.VkImageMemoryRequirementsInfo2 = .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2, .image = image };
        fns.vkGetImageMemoryRequirements2(self.device, &asked, &requirements);

        // No RHI call maps a texture, so its memory is device-local whatever the descriptor's intent.
        const allocation = try self.allocate(requirements.memoryRequirements, dedicated, .{ .image = image }, .device_local);
        errdefer self.freeMemory(allocation.memory);
        const bound = self.injectedResource(.bind_memory) orelse fns.vkBindImageMemory(self.device, image, allocation.memory, 0);
        if (bound != c.VK_SUCCESS) return resourceFailure(bound, "vkBindImageMemory");

        // A view only for an image something reads through one — sampled, or an attachment. Vulkan
        // refuses a view of an image declared for copies alone, and nothing would use one.
        var view: c.VkImageView = null;
        errdefer if (view != null) fns.vkDestroyImageView(self.device, view, null);
        if (desc.usage.sampled or desc.usage.render_target or desc.usage.depth_stencil) {
            // Every level and the format's own aspects, as the descriptor declares them (§5.2).
            const view_info: c.VkImageViewCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = vk_format,
                .subresourceRange = .{ .aspectMask = aspectMask(desc.format), .levelCount = levels, .layerCount = 1 },
            };
            const viewed = self.injectedResource(.create_view) orelse fns.vkCreateImageView(self.device, &view_info, null, &view);
            if (viewed != c.VK_SUCCESS) {
                view = null;
                return resourceFailure(viewed, "vkCreateImageView");
            }
        }

        const state: TextureState = .{ .desc = desc, .image = image, .view = view, .allocation = allocation.memory };
        // An image starts undefined; any other declared state is reached by a transition of its own,
        // queued in order before anything that could use the texture (§5.2).
        if (desc.initial_state != .undefined) try self.transitionAtCreation(&state);
        return self.textures.add(self.gpa, state) catch |err| {
            // The transition may be queued: wait it out before the errdefers release the image.
            self.waitIdle();
            return err;
        };
    }

    fn transitionAtCreation(self: *Device, state: *const TextureState) interface.ResourceError!void {
        const cb = self.beginCommandBuffer() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.DeviceLost, error.ValidationFailed => error.OutOfDeviceMemory,
        };
        const barrier = [_]c.VkImageMemoryBarrier2{imageBarrier(state, .undefined, state.desc.initial_state)};
        const dependency: c.VkDependencyInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = barrier.len,
            .pImageMemoryBarriers = &barrier,
        };
        self.device_fns.vkCmdPipelineBarrier2(cb.native, &dependency);
        if (self.injectedResource(.initial_transition)) |result| {
            cb.discard();
            return resourceFailure(result, "queueing a texture's initial transition");
        }
        cb.submit() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.DeviceLost, error.ValidationFailed => error.OutOfDeviceMemory,
        };
    }

    pub fn destroyTexture(self: *Device, handle: resource.TextureHandle) void {
        const state = self.textures.getConst(handle) orelse return;
        const backing: Retired = .{ .texture = .{ .image = state.image, .view = state.view, .allocation = state.allocation } };
        _ = self.textures.remove(handle);
        self.retire(backing);
    }

    pub fn createSampler(self: *Device, desc: resource.SamplerDesc) interface.ResourceError!resource.SamplerHandle {
        try self.reserveRetirement(1);
        const info: c.VkSamplerCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = samplerFilter(desc.mag_filter),
            .minFilter = samplerFilter(desc.min_filter),
            .mipmapMode = samplerMipmap(desc.mip_filter),
            .addressModeU = samplerAddress(desc.address_u),
            .addressModeV = samplerAddress(desc.address_v),
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            // Every level, as Metal's default clamp allows.
            .maxLod = c.VK_LOD_CLAMP_NONE,
        };
        var native: c.VkSampler = null;
        const created = self.injectedResource(.create_sampler) orelse
            self.device_fns.vkCreateSampler(self.device, &info, null, &native);
        if (created != c.VK_SUCCESS) return resourceFailure(created, "vkCreateSampler");
        errdefer self.device_fns.vkDestroySampler(self.device, native, null);
        return self.samplers.add(self.gpa, .{ .native = native });
    }

    pub fn destroySampler(self: *Device, handle: resource.SamplerHandle) void {
        const state = self.samplers.getConst(handle) orelse return;
        const native = state.native;
        _ = self.samplers.remove(handle);
        self.retire(.{ .sampler = native });
    }

    // -- shaders and persistent bindings ----------------------------------------------

    pub fn createShaderModule(self: *Device, desc: resource.ShaderModuleDesc) interface.ResourceError!resource.ShaderModuleHandle {
        spirv.validate(desc.bytes) catch {
            log.warn("vulkan: shader module '{s}' is not a bounded SPIR-V 1.6-or-earlier envelope", .{desc.label});
            return error.ShaderCompilationFailed;
        };
        try self.reserveRetirement(1);

        // VkShaderModuleCreateInfo requires a four-byte-aligned pCode even though the RHI
        // accepts an ordinary byte slice. Retaining this copy also lets pipeline creation
        // validate the selected entry without asking the driver to diagnose caller input.
        const bytes = try self.gpa.alignedAlloc(u8, .fromByteUnits(4), desc.bytes.len);
        errdefer self.gpa.free(bytes);
        @memcpy(bytes, desc.bytes);
        const info: c.VkShaderModuleCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = bytes.len,
            .pCode = @ptrCast(bytes.ptr),
        };
        var native: c.VkShaderModule = null;
        const created = self.injectedResource(.create_shader) orelse
            self.device_fns.vkCreateShaderModule(self.device, &info, null, &native);
        if (created != c.VK_SUCCESS) return shaderFailure(created, "vkCreateShaderModule");
        errdefer self.device_fns.vkDestroyShaderModule(self.device, native, null);
        return self.shaders.add(self.gpa, .{ .native = native, .bytes = bytes });
    }

    pub fn createShaderModuleFromSource(_: *Device, _: resource.ShaderSourceDesc) interface.ResourceError!resource.ShaderModuleHandle {
        return error.RuntimeCompilationUnsupported;
    }

    pub fn destroyShaderModule(self: *Device, handle: resource.ShaderModuleHandle) void {
        const state = self.shaders.getConst(handle) orelse return;
        const retired = state.*;
        _ = self.shaders.remove(handle);
        self.retire(.{ .shader = retired });
    }

    fn releaseBindGroupLayout(self: *Device, backing: *BindGroupLayoutBacking) void {
        if (backing.released or self.tearing_down) return;
        self.device_fns.vkDestroyDescriptorSetLayout(self.device, backing.native, null);
        self.gpa.free(backing.entries);
        backing.released = true;
        backing.native = null;
    }

    fn dropBindGroupLayout(self: *Device, backing: *BindGroupLayoutBacking) void {
        assert.debugOnly(backing.refs > 0, "bind-group layout reference underflow", .{});
        backing.refs -= 1;
        if (backing.refs == 0 and !self.tearing_down) {
            self.retired.retire(.{ .bind_group_layout = backing }, self.timeline.begun);
        }
    }

    pub fn createBindGroupLayout(self: *Device, desc: pipeline.BindGroupLayoutDesc) interface.ResourceError!pipeline.BindGroupLayoutHandle {
        for (desc.entries, 0..) |entry, i| {
            if (!entry.visibility.any()) return error.InvalidDescriptor;
            for (desc.entries[0..i]) |earlier| {
                if (earlier.binding == entry.binding) return error.InvalidDescriptor;
            }
        }
        if (!layoutWithinLimits(&self.limits, desc.entries)) return error.InvalidDescriptor;
        try self.reserveRetirement(1);

        const entries = try self.gpa.dupe(pipeline.BindGroupLayoutEntry, desc.entries);
        var entries_owned_by_backing = false;
        errdefer if (!entries_owned_by_backing) self.gpa.free(entries);
        const native_entries = try self.gpa.alloc(c.VkDescriptorSetLayoutBinding, entries.len);
        defer self.gpa.free(native_entries);
        for (entries, native_entries) |entry, *native| {
            native.* = .{
                .binding = entry.binding,
                .descriptorType = descriptorType(entry.type),
                .descriptorCount = 1,
                .stageFlags = shaderStages(entry.visibility),
            };
        }
        const info: c.VkDescriptorSetLayoutCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = @intCast(native_entries.len),
            .pBindings = native_entries.ptr,
        };
        var native: c.VkDescriptorSetLayout = null;
        const created = self.injectedResource(.create_bind_group_layout) orelse
            self.device_fns.vkCreateDescriptorSetLayout(self.device, &info, null, &native);
        if (created != c.VK_SUCCESS) return descriptorFailure(created, "vkCreateDescriptorSetLayout");
        var native_owned_by_backing = false;
        errdefer if (!native_owned_by_backing) self.device_fns.vkDestroyDescriptorSetLayout(self.device, native, null);

        const backing = try self.gpa.create(BindGroupLayoutBacking);
        var backing_tracked = false;
        errdefer if (!backing_tracked) self.gpa.destroy(backing);
        backing.* = .{ .native = native, .entries = entries };
        try self.bind_group_layout_backings.append(self.gpa, backing);
        backing_tracked = true;
        entries_owned_by_backing = true;
        native_owned_by_backing = true;
        return self.bind_group_layouts.add(self.gpa, .{ .backing = backing }) catch |err| {
            self.releaseBindGroupLayout(backing);
            return err;
        };
    }

    pub fn destroyBindGroupLayout(self: *Device, handle: pipeline.BindGroupLayoutHandle) void {
        const state = self.bind_group_layouts.getConst(handle) orelse return;
        const backing = state.backing;
        _ = self.bind_group_layouts.remove(handle);
        self.dropBindGroupLayout(backing);
        self.collect();
    }

    const descriptor_sets_per_pool: u32 = 64;
    const descriptors_per_kind_per_pool: u32 = 256;

    fn createDescriptorPool(self: *Device) interface.ResourceError!*DescriptorPool {
        const sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = descriptors_per_kind_per_pool },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = descriptors_per_kind_per_pool },
            .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = descriptors_per_kind_per_pool },
            .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = descriptors_per_kind_per_pool },
        };
        const info: c.VkDescriptorPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .flags = @as(u32, c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT),
            .maxSets = descriptor_sets_per_pool,
            .poolSizeCount = sizes.len,
            .pPoolSizes = &sizes,
        };
        var native: c.VkDescriptorPool = null;
        const created = self.injectedResource(.create_descriptor_pool) orelse
            self.device_fns.vkCreateDescriptorPool(self.device, &info, null, &native);
        if (created != c.VK_SUCCESS) return descriptorFailure(created, "vkCreateDescriptorPool");
        errdefer self.device_fns.vkDestroyDescriptorPool(self.device, native, null);
        const pool = try self.gpa.create(DescriptorPool);
        errdefer self.gpa.destroy(pool);
        pool.* = .{ .native = native };
        try self.descriptor_pools.append(self.gpa, pool);
        return pool;
    }

    fn allocateDescriptorSet(
        self: *Device,
        set_layout: c.VkDescriptorSetLayout,
    ) interface.ResourceError!struct { set: c.VkDescriptorSet, pool: *DescriptorPool } {
        if (self.injectedResource(.allocate_descriptor_set)) |result| {
            return descriptorFailure(result, "vkAllocateDescriptorSets");
        }
        for (self.descriptor_pools.items) |pool| {
            if (pool.live_sets == descriptor_sets_per_pool) continue;
            const info: c.VkDescriptorSetAllocateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .descriptorPool = pool.native,
                .descriptorSetCount = 1,
                .pSetLayouts = &set_layout,
            };
            var set: c.VkDescriptorSet = null;
            const allocated = self.device_fns.vkAllocateDescriptorSets(self.device, &info, &set);
            if (allocated == c.VK_SUCCESS) {
                pool.live_sets += 1;
                return .{ .set = set, .pool = pool };
            }
            if (allocated != c.VK_ERROR_OUT_OF_POOL_MEMORY and allocated != c.VK_ERROR_FRAGMENTED_POOL) {
                return descriptorFailure(allocated, "vkAllocateDescriptorSets");
            }
        }

        const pool = try self.createDescriptorPool();
        const info: c.VkDescriptorSetAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool.native,
            .descriptorSetCount = 1,
            .pSetLayouts = &set_layout,
        };
        var set: c.VkDescriptorSet = null;
        const allocated = self.device_fns.vkAllocateDescriptorSets(self.device, &info, &set);
        if (allocated != c.VK_SUCCESS) return descriptorFailure(allocated, "vkAllocateDescriptorSets from a fresh pool");
        pool.live_sets = 1;
        return .{ .set = set, .pool = pool };
    }

    pub fn createBindGroup(self: *Device, desc: pipeline.BindGroupDesc) interface.ResourceError!pipeline.BindGroupHandle {
        const layout_state = self.bind_group_layouts.getConst(desc.layout) orelse return error.InvalidDescriptor;
        const layout_backing = layout_state.backing;
        if (desc.entries.len != layout_backing.entries.len) return error.InvalidDescriptor;

        for (layout_backing.entries) |wanted| {
            const found = findBindGroupEntry(desc.entries, wanted.binding) orelse return error.InvalidDescriptor;
            if (@as(pipeline.BindingType, found.resource) != wanted.type) return error.InvalidDescriptor;
        }
        for (desc.entries, 0..) |entry, i| {
            for (desc.entries[0..i]) |earlier| {
                if (earlier.binding == entry.binding) return error.InvalidDescriptor;
            }
            try self.validateBinding(entry);
        }
        try self.reserveRetirement(1);

        const entries = try self.gpa.dupe(pipeline.BindGroupEntry, desc.entries);
        errdefer self.gpa.free(entries);
        const allocated = try self.allocateDescriptorSet(layout_backing.native);
        errdefer {
            _ = self.device_fns.vkFreeDescriptorSets(self.device, allocated.pool.native, 1, &allocated.set);
            allocated.pool.live_sets -= 1;
        }

        const writes = try self.gpa.alloc(c.VkWriteDescriptorSet, entries.len);
        defer self.gpa.free(writes);
        const buffers = try self.gpa.alloc(c.VkDescriptorBufferInfo, entries.len);
        defer self.gpa.free(buffers);
        const images = try self.gpa.alloc(c.VkDescriptorImageInfo, entries.len);
        defer self.gpa.free(images);
        for (entries, 0..) |entry, i| {
            writes[i] = .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = allocated.set,
                .dstBinding = entry.binding,
                .descriptorCount = 1,
                .descriptorType = descriptorType(@as(pipeline.BindingType, entry.resource)),
            };
            switch (entry.resource) {
                .uniform_buffer, .storage_buffer => |binding| {
                    const state = self.buffers.getConst(binding.buffer).?;
                    buffers[i] = .{
                        .buffer = state.native,
                        .offset = binding.offset,
                        .range = resolvedBindingSize(binding, state.desc.size).?,
                    };
                    writes[i].pBufferInfo = &buffers[i];
                },
                .sampled_texture => |handle| {
                    images[i] = .{
                        .imageView = self.textures.getConst(handle).?.view,
                        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    };
                    writes[i].pImageInfo = &images[i];
                },
                .sampler => |handle| {
                    images[i] = .{ .sampler = self.samplers.getConst(handle).?.native };
                    writes[i].pImageInfo = &images[i];
                },
            }
        }
        self.device_fns.vkUpdateDescriptorSets(self.device, @intCast(writes.len), writes.ptr, 0, null);

        layout_backing.refs += 1;
        return self.bind_groups.add(self.gpa, .{
            .native = allocated.set,
            .pool = allocated.pool,
            .layout = layout_backing,
            .entries = entries,
        }) catch |err| {
            layout_backing.refs -= 1;
            return err;
        };
    }

    fn validateBinding(self: *Device, entry: pipeline.BindGroupEntry) interface.ResourceError!void {
        switch (entry.resource) {
            .uniform_buffer => |binding| {
                const state = self.buffers.getConst(binding.buffer) orelse return error.InvalidDescriptor;
                if (!state.desc.usage.uniform or
                    !bindingRangeValid(binding, state.desc.size, self.capabilities().uniform_buffer_offset_alignment, self.capabilities().max_uniform_buffer_binding_size))
                    return error.InvalidDescriptor;
            },
            .storage_buffer => |binding| {
                const state = self.buffers.getConst(binding.buffer) orelse return error.InvalidDescriptor;
                if (!state.desc.usage.storage or
                    !bindingRangeValid(binding, state.desc.size, self.capabilities().storage_buffer_offset_alignment, self.capabilities().max_storage_buffer_binding_size))
                    return error.InvalidDescriptor;
            },
            .sampled_texture => |handle| {
                const state = self.textures.getConst(handle) orelse return error.InvalidDescriptor;
                if (!state.desc.usage.sampled or state.view == null) return error.InvalidDescriptor;
            },
            .sampler => |handle| if (self.samplers.getConst(handle) == null) return error.InvalidDescriptor,
        }
    }

    pub fn destroyBindGroup(self: *Device, handle: pipeline.BindGroupHandle) void {
        const state = self.bind_groups.getConst(handle) orelse return;
        const retired = state.*;
        _ = self.bind_groups.remove(handle);
        self.retire(.{ .bind_group = retired });
    }

    fn releasePipelineLayout(self: *Device, backing: *PipelineLayoutBacking) void {
        if (backing.released or self.tearing_down) return;
        self.device_fns.vkDestroyPipelineLayout(self.device, backing.native, null);
        for (backing.groups) |group| {
            if (group) |present| self.dropBindGroupLayout(present);
        }
        self.gpa.free(backing.groups);
        backing.released = true;
        backing.native = null;
    }

    fn dropPipelineLayout(self: *Device, backing: *PipelineLayoutBacking) void {
        assert.debugOnly(backing.refs > 0, "pipeline layout reference underflow", .{});
        backing.refs -= 1;
        if (backing.refs == 0 and !self.tearing_down) {
            self.retired.retire(.{ .pipeline_layout = backing }, self.timeline.begun);
        }
    }

    pub fn createPipelineLayout(self: *Device, desc: pipeline.PipelineLayoutDesc) interface.ResourceError!pipeline.PipelineLayoutHandle {
        if (desc.bind_group_layouts.len > pipeline.max_bind_groups or
            desc.inline_constant_bytes > pipeline.max_inline_constant_bytes) return error.InvalidDescriptor;
        try self.reserveRetirement(1);

        const groups = try self.gpa.alloc(?*BindGroupLayoutBacking, desc.bind_group_layouts.len);
        var groups_owned_by_backing = false;
        errdefer if (!groups_owned_by_backing) self.gpa.free(groups);
        const native_groups = try self.gpa.alloc(c.VkDescriptorSetLayout, groups.len);
        defer self.gpa.free(native_groups);
        for (desc.bind_group_layouts, groups, native_groups) |handle, *group, *native| {
            if (handle.isNone()) {
                group.* = null;
                native.* = self.empty_set_layout;
            } else {
                const state = self.bind_group_layouts.getConst(handle) orelse return error.InvalidDescriptor;
                group.* = state.backing;
                native.* = state.backing.native;
            }
        }
        if (!pipelineLayoutWithinLimits(&self.limits, groups)) return error.InvalidDescriptor;

        const padded_constants = std.mem.alignForward(u32, desc.inline_constant_bytes, 4);
        const push_range: c.VkPushConstantRange = .{
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .size = padded_constants,
        };
        const info: c.VkPipelineLayoutCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = @intCast(native_groups.len),
            .pSetLayouts = native_groups.ptr,
            .pushConstantRangeCount = if (padded_constants == 0) 0 else 1,
            .pPushConstantRanges = if (padded_constants == 0) null else &push_range,
        };
        var native: c.VkPipelineLayout = null;
        const created = self.injectedResource(.create_pipeline_layout) orelse
            self.device_fns.vkCreatePipelineLayout(self.device, &info, null, &native);
        if (created != c.VK_SUCCESS) return descriptorFailure(created, "vkCreatePipelineLayout");
        var native_owned_by_backing = false;
        errdefer if (!native_owned_by_backing) self.device_fns.vkDestroyPipelineLayout(self.device, native, null);

        const backing = try self.gpa.create(PipelineLayoutBacking);
        var backing_tracked = false;
        errdefer if (!backing_tracked) self.gpa.destroy(backing);
        backing.* = .{
            .native = native,
            .groups = groups,
            .inline_constant_bytes = desc.inline_constant_bytes,
        };
        try self.pipeline_layout_backings.append(self.gpa, backing);
        backing_tracked = true;
        groups_owned_by_backing = true;
        native_owned_by_backing = true;
        for (groups) |group| {
            if (group) |present| present.refs += 1;
        }
        return self.pipeline_layouts.add(self.gpa, .{ .backing = backing }) catch |err| {
            self.releasePipelineLayout(backing);
            return err;
        };
    }

    pub fn destroyPipelineLayout(self: *Device, handle: pipeline.PipelineLayoutHandle) void {
        const state = self.pipeline_layouts.getConst(handle) orelse return;
        const backing = state.backing;
        _ = self.pipeline_layouts.remove(handle);
        self.dropPipelineLayout(backing);
        self.collect();
    }

    pub fn createRenderPipeline(self: *Device, desc: pipeline.RenderPipelineDesc) interface.ResourceError!pipeline.RenderPipelineHandle {
        const vertex_shader = self.shaders.getConst(desc.vertex_shader) orelse return error.InvalidDescriptor;
        const fragment_shader = self.shaders.getConst(desc.fragment_shader) orelse return error.InvalidDescriptor;
        const layout_backing = (self.pipeline_layouts.getConst(desc.layout) orelse return error.InvalidDescriptor).backing;
        if (!(spirv.hasEntry(vertex_shader.bytes, .vertex, desc.vertex_entry) catch false) or
            !(spirv.hasEntry(fragment_shader.bytes, .fragment, desc.fragment_entry) catch false))
        {
            log.warn("vulkan: pipeline '{s}' selects a missing or wrong-stage shader entry", .{desc.label});
            return error.InvalidDescriptor;
        }
        if (!pipelineDescriptorValid(&self.limits, desc)) return error.InvalidDescriptor;
        try self.reserveRetirement(1);

        const vertex_name = try self.gpa.dupeZ(u8, desc.vertex_entry);
        defer self.gpa.free(vertex_name);
        const fragment_name = try self.gpa.dupeZ(u8, desc.fragment_entry);
        defer self.gpa.free(fragment_name);
        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vertex_shader.native,
                .pName = vertex_name.ptr,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = fragment_shader.native,
                .pName = fragment_name.ptr,
            },
        };

        const bindings = try self.gpa.alloc(c.VkVertexInputBindingDescription, desc.vertex_buffers.len);
        defer self.gpa.free(bindings);
        var attribute_count: usize = 0;
        for (desc.vertex_buffers) |binding| attribute_count += binding.attributes.len;
        const attributes = try self.gpa.alloc(c.VkVertexInputAttributeDescription, attribute_count);
        defer self.gpa.free(attributes);
        var next_attribute: usize = 0;
        for (desc.vertex_buffers, 0..) |binding, binding_index| {
            bindings[binding_index] = .{
                .binding = @intCast(binding_index),
                .stride = binding.stride,
                .inputRate = vertexStep(binding.step_mode),
            };
            for (binding.attributes) |attribute| {
                attributes[next_attribute] = .{
                    .location = attribute.location,
                    .binding = @intCast(binding_index),
                    .format = vertexFormat(attribute.format),
                    .offset = attribute.offset,
                };
                next_attribute += 1;
            }
        }
        const vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = @intCast(bindings.len),
            .pVertexBindingDescriptions = bindings.ptr,
            .vertexAttributeDescriptionCount = @intCast(attributes.len),
            .pVertexAttributeDescriptions = attributes.ptr,
        };
        const assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = primitiveTopology(desc.primitive.topology),
        };
        const viewport: c.VkPipelineViewportStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
        };
        const raster: c.VkPipelineRasterizationStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = cullMode(desc.primitive.cull_mode),
            // Vulkan judges facing in framebuffer coordinates, after the viewport. The negative-height
            // viewport (§6) already turns Foundry's y-up winding into the same winding there, so the
            // descriptor's front face maps directly (Step 6 Resolution).
            .frontFace = frontFace(desc.primitive.front_face),
            .lineWidth = 1,
        };
        const multisample: c.VkPipelineMultisampleStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        };
        const depth_desc = desc.depth_stencil orelse pipeline.DepthStencilState{ .format = .depth32_float };
        const depth_stencil: c.VkPipelineDepthStencilStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .depthTestEnable = if (desc.depth_stencil != null) c.VK_TRUE else c.VK_FALSE,
            .depthWriteEnable = if (depth_desc.depth_write_enabled) c.VK_TRUE else c.VK_FALSE,
            .depthCompareOp = compareFunction(depth_desc.depth_compare),
        };

        const targets = try self.gpa.alloc(c.VkPipelineColorBlendAttachmentState, desc.color_targets.len);
        defer self.gpa.free(targets);
        const color_formats = try self.gpa.alloc(c.VkFormat, desc.color_targets.len);
        defer self.gpa.free(color_formats);
        for (desc.color_targets, targets, color_formats) |target, *native, *native_format| {
            const blend = target.blend orelse pipeline.BlendState{};
            native.* = .{
                .blendEnable = if (target.blend != null) c.VK_TRUE else c.VK_FALSE,
                .srcColorBlendFactor = blendFactor(blend.color.src),
                .dstColorBlendFactor = blendFactor(blend.color.dst),
                .colorBlendOp = blendOp(blend.color.op),
                .srcAlphaBlendFactor = blendFactor(blend.alpha.src),
                .dstAlphaBlendFactor = blendFactor(blend.alpha.dst),
                .alphaBlendOp = blendOp(blend.alpha.op),
                .colorWriteMask = colorWriteMask(target.write_mask),
            };
            native_format.* = vkFormat(target.format);
        }
        const color_blend: c.VkPipelineColorBlendStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = @intCast(targets.len),
            .pAttachments = targets.ptr,
        };
        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic: c.VkPipelineDynamicStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };
        const depth_format = if (desc.depth_stencil) |depth| vkFormat(depth.format) else c.VK_FORMAT_UNDEFINED;
        const rendering: c.VkPipelineRenderingCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .colorAttachmentCount = @intCast(color_formats.len),
            .pColorAttachmentFormats = color_formats.ptr,
            .depthAttachmentFormat = depth_format,
            .stencilAttachmentFormat = if (desc.depth_stencil) |depth|
                if (depth.format.hasStencil()) depth_format else c.VK_FORMAT_UNDEFINED
            else
                c.VK_FORMAT_UNDEFINED,
        };
        const info: c.VkGraphicsPipelineCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &assembly,
            .pViewportState = &viewport,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &color_blend,
            .pDynamicState = &dynamic,
            .layout = layout_backing.native,
        };
        var native: c.VkPipeline = null;
        const created = self.injectedResource(.create_render_pipeline) orelse
            self.device_fns.vkCreateGraphicsPipelines(self.device, null, 1, &info, null, &native);
        if (created != c.VK_SUCCESS) return pipelineFailure(created, "vkCreateGraphicsPipelines");
        errdefer self.device_fns.vkDestroyPipeline(self.device, native, null);

        layout_backing.refs += 1;
        return self.pipelines.add(self.gpa, .{
            .native = native,
            .layout = layout_backing,
            .primitive = desc.primitive,
        }) catch |err| {
            layout_backing.refs -= 1;
            return err;
        };
    }

    pub fn destroyRenderPipeline(self: *Device, handle: pipeline.RenderPipelineHandle) void {
        const state = self.pipelines.getConst(handle) orelse return;
        const retired = state.*;
        _ = self.pipelines.remove(handle);
        self.retire(.{ .render_pipeline = retired });
    }

    // -- recording -----------------------------------------------------------------

    pub fn beginCommandBuffer(self: *Device) interface.CommandError!*CommandBuffer {
        if (self.lost) return error.DeviceLost;
        // Work that finished since the last look frees its command buffer for this recording, so
        // uploads outside a frame recycle without waiting for one.
        self.poll();

        const gpa = self.gpa;
        const recording = try self.timeline.begin(gpa);
        errdefer self.timeline.discard(recording);

        const cb = if (self.free_command_buffers.pop()) |reused| reused else blk: {
            const fresh = try gpa.create(CommandBuffer);
            errdefer gpa.destroy(fresh);
            // Room to recycle it is reserved with it, so returning it can never fail.
            try self.free_command_buffers.ensureTotalCapacity(gpa, self.command_buffers.items.len + 1);
            try self.command_buffers.append(gpa, fresh);
            break :blk fresh;
        };
        cb.* = .{ .device = self, .native = null, .recording = recording, .open = false };
        errdefer self.free_command_buffers.appendAssumeCapacity(cb);

        const native = try self.acquireNative();
        errdefer self.free_native.appendAssumeCapacity(native);

        const begin_info: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = @as(u32, c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT),
        };
        const begun = self.device_fns.vkBeginCommandBuffer(native, &begin_info);
        if (begun != c.VK_SUCCESS) return self.commandFailure(begun, "vkBeginCommandBuffer", false);

        cb.native = native;
        cb.open = true;
        // Queue order is only an execution dependency. Make every earlier submission's writes
        // available and visible to this one, irrespective of the order recordings were begun.
        cb.memoryBarrier(
            c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
            c.VK_ACCESS_2_MEMORY_WRITE_BIT,
            c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
            c.VK_ACCESS_2_MEMORY_READ_BIT | c.VK_ACCESS_2_MEMORY_WRITE_BIT,
        );
        return cb;
    }

    /// A native command buffer ready to begin: a finished or unsubmitted one, or a new one. The
    /// pool resets a finished buffer when it is begun again.
    fn acquireNative(self: *Device) interface.CommandError!c.VkCommandBuffer {
        if (self.free_native.pop()) |reused| return reused;

        try self.free_native.ensureTotalCapacity(self.gpa, self.native_count + 1);
        const info: c.VkCommandBufferAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var native: c.VkCommandBuffer = null;
        const allocated = self.device_fns.vkAllocateCommandBuffers(self.device, &info, &native);
        if (allocated != c.VK_SUCCESS) return self.commandFailure(allocated, "vkAllocateCommandBuffers", false);
        self.native_count += 1;
        return native;
    }

    /// A recording the queue will never run: closing or submitting it failed. `submit` consumes a
    /// command buffer whatever it returns, so the recording is discarded here. A submission that
    /// fails leaves its command buffer unexecuted, and beginning it again resets it.
    fn refuseSubmission(
        self: *Device,
        cb: *CommandBuffer,
        result: c.VkResult,
        comptime what: []const u8,
        was_injected: bool,
    ) interface.CommandError {
        self.timeline.discard(cb.recording);
        self.free_native.appendAssumeCapacity(cb.native);
        self.free_command_buffers.appendAssumeCapacity(cb);
        return self.commandFailure(result, what, was_injected);
    }

    /// The error a failed recording call maps to. Apart from device loss, those calls only fail
    /// for want of host or device memory.
    fn commandFailure(self: *Device, result: c.VkResult, comptime what: []const u8, was_injected: bool) interface.CommandError {
        if (result == c.VK_ERROR_DEVICE_LOST) {
            self.markLost(what, was_injected);
            return error.DeviceLost;
        }
        log.warn("vulkan: " ++ what ++ " failed: {s}", .{vk.resultName(result)});
        return error.OutOfMemory;
    }

    // -- initialization ------------------------------------------------------------

    /// The result a test substituted for `stage`, if any.
    fn injected(self: *const Device, stage: Stage) ?c.VkResult {
        const at = self.options.fail_at orelse return null;
        return if (at == stage) self.options.fail_with else null;
    }

    /// The instance extension a surface kind needs, or null offscreen. A kind this backend cannot
    /// use, or one whose payload is missing, is refused before anything is loaded.
    fn surfaceExtension(surface: platform.NativeSurfaceHandle) interface.InitError!?[*:0]const u8 {
        switch (surface.kind) {
            .none => return null,
            .win32_hwnd => if (comptime builtin.os.tag == .windows) {
                if (surface.win32() != null) return c.VK_KHR_WIN32_SURFACE_EXTENSION_NAME;
            },
            .xlib_window => if (comptime builtin.os.tag == .linux) {
                if (surface.xlib() != null) return c.VK_KHR_XLIB_SURFACE_EXTENSION_NAME;
            },
            .wayland_surface => if (comptime builtin.os.tag == .linux) {
                if (surface.wayland() != null) return c.VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME;
            },
            // `native_window` is a request; no handle carries it.
            .metal_layer, .native_window => {},
        }
        log.warn("vulkan backend cannot use a '{t}' surface on this system", .{surface.kind});
        return error.SurfaceUnsupported;
    }

    fn openLoader(self: *Device) interface.InitError!void {
        if (self.injected(.open_loader) != null) {
            log.warn("vulkan: the system Vulkan loader could not be opened (injected)", .{});
            return error.DeviceCreationFailed;
        }
        self.loader = platform.os.Library.openSystem(self.gpa, dispatch.loader_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("vulkan: no system Vulkan loader ('{s}': {t}); a Vulkan driver is not installed", .{
                    dispatch.loader_name,
                    err,
                });
                return error.DeviceCreationFailed;
            },
        };

        const get = (if (self.injected(.load_global) != null) null else self.loader.?.symbol(
            dispatch.GetInstanceProcAddr,
            "vkGetInstanceProcAddr",
        )) orelse {
            log.warn("vulkan: '{s}' exports no vkGetInstanceProcAddr", .{dispatch.loader_name});
            return error.DeviceCreationFailed;
        };
        self.get_instance_proc_addr = get;
        self.global = dispatch.load(dispatch.Global, get, @as(c.VkInstance, null)) catch
            return error.DeviceCreationFailed;
    }

    fn createInstance(self: *Device, wsi: ?[*:0]const u8) interface.InitError!void {
        const gpa = self.gpa;
        const validation = self.options.validation == .required;
        const layer = self.options.validation_layer;

        var version: u32 = 0;
        const versioned = self.injected(.instance_version) orelse self.global.vkEnumerateInstanceVersion(&version);
        if (versioned != c.VK_SUCCESS) return failed(versioned, "vkEnumerateInstanceVersion");
        if (!selection.meetsFloor(version)) {
            log.warn("vulkan: the loader offers Vulkan {d}.{d}, and Foundry needs 1.3", .{
                selection.versionMajor(version),
                selection.versionMinor(version),
            });
            return error.DeviceCreationFailed;
        }

        if (validation) {
            const layers = try self.listLayers();
            defer gpa.free(layers);
            if (!named("layerName", layers, layer)) {
                log.warn("vulkan: validation was required, and '{s}' is not installed", .{layer});
                return error.DeviceCreationFailed;
            }
        }

        var wanted_buf: [4][*:0]const u8 = undefined;
        var wanted_len: usize = 0;
        if (wsi) |extension| {
            wanted_buf[wanted_len] = c.VK_KHR_SURFACE_EXTENSION_NAME;
            wanted_buf[wanted_len + 1] = extension;
            wanted_len += 2;
        }
        if (validation) {
            wanted_buf[wanted_len] = c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
            wanted_buf[wanted_len + 1] = c.VK_EXT_LAYER_SETTINGS_EXTENSION_NAME;
            wanted_len += 2;
        }
        const wanted = wanted_buf[0..wanted_len];

        if (wanted.len > 0) {
            const available = try self.listInstanceExtensions(null);
            defer gpa.free(available);
            // The layer's own extensions, `VK_EXT_layer_settings` among them, are listed by the layer.
            const from_layer = if (validation) try self.listInstanceExtensions(layer.ptr) else try gpa.alloc(c.VkExtensionProperties, 0);
            defer gpa.free(from_layer);

            var missing = false;
            for (wanted) |extension| {
                if (named("extensionName", available, std.mem.span(extension))) continue;
                if (named("extensionName", from_layer, std.mem.span(extension))) continue;
                log.warn("vulkan: instance extension '{s}' is not available", .{extension});
                missing = true;
            }
            if (missing) return error.DeviceCreationFailed;
        }

        const app: c.VkApplicationInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "Foundry",
            .pEngineName = "Foundry",
            .apiVersion = selection.min_api_version,
        };
        const layer_names = [_][*:0]const u8{layer.ptr};
        const sync_on: c.VkBool32 = c.VK_TRUE;
        const settings = [_]c.VkLayerSettingEXT{.{
            .pLayerName = layer.ptr,
            .pSettingName = "validate_sync",
            .type = c.VK_LAYER_SETTING_TYPE_BOOL32_EXT,
            .valueCount = 1,
            .pValues = &sync_on,
        }};
        const settings_info: c.VkLayerSettingsCreateInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT,
            .settingCount = settings.len,
            .pSettings = &settings,
        };
        // Reports what happens inside `vkCreateInstance` and `vkDestroyInstance`, which the
        // persistent messenger cannot see: that is where leaked objects are reported.
        const creation_messenger = self.messengerInfo(&settings_info);
        const info: c.VkInstanceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = if (validation) &creation_messenger else null,
            .pApplicationInfo = &app,
            .enabledLayerCount = if (validation) 1 else 0,
            .ppEnabledLayerNames = @ptrCast(&layer_names),
            .enabledExtensionCount = @intCast(wanted.len),
            .ppEnabledExtensionNames = @ptrCast(wanted.ptr),
        };
        const created = self.injected(.create_instance) orelse self.global.vkCreateInstance(&info, null, &self.instance);
        if (created != c.VK_SUCCESS) {
            self.instance = null;
            return failed(created, "vkCreateInstance");
        }

        const get = self.get_instance_proc_addr.?;
        self.destroy_instance = dispatch.lookup(c.PFN_vkDestroyInstance, get, self.instance, "vkDestroyInstance");
        if (self.injected(.load_instance)) |result| return failed(result, "loading instance functions");
        self.instance_fns = dispatch.load(dispatch.Instance, get, self.instance) catch
            return error.DeviceCreationFailed;
    }

    fn messengerInfo(self: *Device, next: ?*const anyopaque) c.VkDebugUtilsMessengerCreateInfoEXT {
        return .{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .pNext = next,
            .messageSeverity = @as(u32, c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) |
                @as(u32, c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) |
                @as(u32, c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT),
            .messageType = @as(u32, c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT) |
                @as(u32, c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) |
                @as(u32, c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT),
            .pfnUserCallback = &onMessage,
            .pUserData = &self.messages,
        };
    }

    fn createMessenger(self: *Device) interface.InitError!void {
        self.debug_fns = dispatch.load(dispatch.DebugUtils, self.get_instance_proc_addr.?, self.instance) catch
            return error.DeviceCreationFailed;
        const info = self.messengerInfo(null);
        const created = self.injected(.create_messenger) orelse
            self.debug_fns.vkCreateDebugUtilsMessengerEXT(self.instance, &info, null, &self.messenger);
        if (created != c.VK_SUCCESS) {
            self.messenger = null;
            return failed(created, "vkCreateDebugUtilsMessengerEXT");
        }
    }

    fn createSurface(self: *Device) interface.InitError!void {
        const get = self.get_instance_proc_addr.?;
        self.surface_fns = dispatch.load(dispatch.Surface, get, self.instance) catch
            return error.DeviceCreationFailed;
        if (self.injected(.create_surface)) |result| return failed(result, "creating the window surface");

        const window = self.desc.surface;
        const created: c.VkResult = switch (window.kind) {
            .win32_hwnd => if (comptime builtin.os.tag == .windows) blk: {
                const fns = dispatch.load(dispatch.Win32Surface, get, self.instance) catch
                    return error.DeviceCreationFailed;
                const payload = window.win32().?;
                var info: c.VkWin32SurfaceCreateInfoKHR = .{ .sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR };
                // `HINSTANCE` and `HWND` are handles, not addresses of the structs `windows.h`
                // types them as, so their values have no alignment to check: copy the bits.
                handleInto(&info.hinstance, payload.hinstance);
                handleInto(&info.hwnd, payload.hwnd);
                break :blk fns.vkCreateWin32SurfaceKHR(self.instance, &info, null, &self.surface);
            } else unreachable,
            .xlib_window => if (comptime builtin.os.tag == .linux) blk: {
                const fns = dispatch.load(dispatch.XlibSurface, get, self.instance) catch
                    return error.DeviceCreationFailed;
                const payload = window.xlib().?;
                const info: c.VkXlibSurfaceCreateInfoKHR = .{
                    .sType = c.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,
                    .dpy = @ptrCast(payload.display),
                    .window = @intCast(payload.window),
                };
                break :blk fns.vkCreateXlibSurfaceKHR(self.instance, &info, null, &self.surface);
            } else unreachable,
            .wayland_surface => if (comptime builtin.os.tag == .linux) blk: {
                const fns = dispatch.load(dispatch.WaylandSurface, get, self.instance) catch
                    return error.DeviceCreationFailed;
                const payload = window.wayland().?;
                const info: c.VkWaylandSurfaceCreateInfoKHR = .{
                    .sType = c.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
                    .display = @ptrCast(payload.display),
                    .surface = @ptrCast(payload.surface),
                };
                break :blk fns.vkCreateWaylandSurfaceKHR(self.instance, &info, null, &self.surface);
            } else unreachable,
            // `surfaceExtension` refused every other kind before anything was created.
            .none, .metal_layer, .native_window => unreachable,
        };
        if (created != c.VK_SUCCESS) {
            self.surface = null;
            return failed(created, "creating the window surface");
        }
    }

    fn chooseDevice(self: *Device, presenting: bool) interface.InitError!void {
        const gpa = self.gpa;
        const needs: selection.Needs = .{ .present = presenting };

        const physicals = try self.listPhysicalDevices();
        defer gpa.free(physicals);

        const candidates = try gpa.alloc(selection.Candidate, physicals.len);
        defer gpa.free(candidates);
        for (physicals, candidates, 0..) |physical, *candidate, i| {
            candidate.* = try self.readCandidate(physical, @intCast(i), needs);
        }

        const chosen = if (self.injected(.select_device) != null) null else selection.choose(candidates, needs);
        for (physicals, candidates) |physical, candidate| {
            const lacking = selection.unmet(candidate, needs);
            if (lacking.none()) continue;
            var props: c.VkPhysicalDeviceProperties = undefined;
            self.instance_fns.vkGetPhysicalDeviceProperties(physical, &props);
            var reasons: [256]u8 = undefined;
            log.info("vulkan: '{s}' is refused; it lacks {s}", .{
                std.mem.sliceTo(&props.deviceName, 0),
                lacking.describe(&reasons),
            });
        }
        const index = chosen orelse {
            if (self.injected(.select_device) != null) {
                log.warn("vulkan: device selection refused every device (injected)", .{});
            } else {
                log.warn("vulkan: none of the {d} Vulkan devices meets Foundry's floor{s}", .{
                    physicals.len,
                    if (presenting) " and presents to this window" else "",
                });
            }
            return error.DeviceCreationFailed;
        };

        self.physical = physicals[index];
        self.queue_family = candidates[index].queue_family.?;
        var props: c.VkPhysicalDeviceProperties = undefined;
        self.instance_fns.vkGetPhysicalDeviceProperties(self.physical, &props);
        self.adapter = .{
            .name_buf = props.deviceName,
            .device_type = candidates[index].device_type,
            .vendor_id = props.vendorID,
            .device_id = props.deviceID,
            .api_version = props.apiVersion,
            .driver_version = props.driverVersion,
        };
        self.limits = props.limits;

        var properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        self.instance_fns.vkGetPhysicalDeviceMemoryProperties(self.physical, &properties);
        self.memory_type_count = @min(properties.memoryTypeCount, self.memory_types.len);
        for (properties.memoryTypes[0..self.memory_type_count], self.memory_types[0..self.memory_type_count]) |native, *flags| {
            const bits = native.propertyFlags;
            flags.* = .{
                .device_local = bits & @as(u32, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0,
                .host_visible = bits & @as(u32, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0,
                .host_coherent = bits & @as(u32, c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0,
                .host_cached = bits & @as(u32, c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT) != 0,
            };
        }
    }

    fn readCandidate(
        self: *Device,
        physical: c.VkPhysicalDevice,
        index: u32,
        needs: selection.Needs,
    ) interface.InitError!selection.Candidate {
        const gpa = self.gpa;
        var props: c.VkPhysicalDeviceProperties = undefined;
        self.instance_fns.vkGetPhysicalDeviceProperties(physical, &props);

        var candidate: selection.Candidate = .{
            .index = index,
            .device_type = deviceType(props.deviceType),
            .vendor_id = props.vendorID,
            .device_id = props.deviceID,
            .api_version = props.apiVersion,
            .dynamic_rendering = false,
            .synchronization2 = false,
            .timeline_semaphore = false,
            .swapchain = false,
            .graphics = false,
            .queue_family = null,
        };

        // The 1.2 and 1.3 feature structures may only be passed to a device that has them.
        if (selection.meetsFloor(props.apiVersion)) {
            var v13: c.VkPhysicalDeviceVulkan13Features = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
            var v12: c.VkPhysicalDeviceVulkan12Features = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &v13 };
            var features: c.VkPhysicalDeviceFeatures2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &v12 };
            self.instance_fns.vkGetPhysicalDeviceFeatures2(physical, &features);
            candidate.dynamic_rendering = v13.dynamicRendering != 0;
            candidate.synchronization2 = v13.synchronization2 != 0;
            candidate.timeline_semaphore = v12.timelineSemaphore != 0;
        }

        const families = try self.listQueueFamilies(physical);
        defer gpa.free(families);
        const usable = try gpa.alloc(selection.QueueFamily, families.len);
        defer gpa.free(usable);
        for (families, usable, 0..) |family, *entry, i| {
            entry.* = .{ .graphics = (family.queueFlags & @as(u32, c.VK_QUEUE_GRAPHICS_BIT)) != 0 };
            if (entry.graphics) candidate.graphics = true;
            if (needs.present) entry.present = self.presentsTo(physical, @intCast(i));
        }
        candidate.queue_family = selection.queueFamily(usable, needs);

        if (needs.present) {
            const extensions = try self.listDeviceExtensions(physical);
            defer gpa.free(extensions);
            candidate.swapchain = named("extensionName", extensions, c.VK_KHR_SWAPCHAIN_EXTENSION_NAME);
        }
        return candidate;
    }

    fn presentsTo(self: *Device, physical: c.VkPhysicalDevice, family: u32) bool {
        var supported: c.VkBool32 = c.VK_FALSE;
        const asked = self.surface_fns.vkGetPhysicalDeviceSurfaceSupportKHR(physical, family, self.surface, &supported);
        if (asked != c.VK_SUCCESS) {
            log.info("vulkan: could not ask whether queue family {d} presents: {s}", .{ family, vk.resultName(asked) });
            return false;
        }
        return supported != 0;
    }

    fn createDevice(self: *Device, presenting: bool) interface.InitError!void {
        const priority: f32 = 1.0;
        const queue_info: c.VkDeviceQueueCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = self.queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        // Exactly the floor's features, and no optional one nothing uses (§5.1).
        var v13: c.VkPhysicalDeviceVulkan13Features = .{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .synchronization2 = c.VK_TRUE,
            .dynamicRendering = c.VK_TRUE,
        };
        var v12: c.VkPhysicalDeviceVulkan12Features = .{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
            .pNext = &v13,
            .timelineSemaphore = c.VK_TRUE,
        };
        var features: c.VkPhysicalDeviceFeatures2 = .{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &v12,
        };
        const extensions = [_][*:0]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
        const info: c.VkDeviceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &features,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = if (presenting) extensions.len else 0,
            .ppEnabledExtensionNames = @ptrCast(&extensions),
        };
        const created = self.injected(.create_device) orelse
            self.instance_fns.vkCreateDevice(self.physical, &info, null, &self.device);
        if (created != c.VK_SUCCESS) {
            self.device = null;
            return failed(created, "vkCreateDevice");
        }

        if (self.injected(.load_device)) |result| return failed(result, "loading device functions");
        self.device_fns = dispatch.load(dispatch.Device, self.instance_fns.vkGetDeviceProcAddr, self.device) catch
            return error.DeviceCreationFailed;
        self.device_fns.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
    }

    fn createQueueObjects(self: *Device) interface.InitError!void {
        const type_info: c.VkSemaphoreTypeCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .semaphoreType = c.VK_SEMAPHORE_TYPE_TIMELINE,
            .initialValue = 0,
        };
        const semaphore_info: c.VkSemaphoreCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &type_info,
        };
        const timed = self.injected(.create_timeline) orelse
            self.device_fns.vkCreateSemaphore(self.device, &semaphore_info, null, &self.timeline_semaphore);
        if (timed != c.VK_SUCCESS) {
            self.timeline_semaphore = null;
            return failed(timed, "creating the timeline semaphore");
        }

        const pool_info: c.VkCommandPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = @as(u32, c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT),
            .queueFamilyIndex = self.queue_family,
        };
        const pooled = self.injected(.create_command_pool) orelse
            self.device_fns.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool);
        if (pooled != c.VK_SUCCESS) {
            self.command_pool = null;
            return failed(pooled, "vkCreateCommandPool");
        }
    }

    fn createEmptySetLayout(self: *Device) interface.InitError!void {
        const info: c.VkDescriptorSetLayoutCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        };
        const created = self.injected(.create_empty_set_layout) orelse
            self.device_fns.vkCreateDescriptorSetLayout(self.device, &info, null, &self.empty_set_layout);
        if (created != c.VK_SUCCESS) {
            self.empty_set_layout = null;
            return failed(created, "creating the empty descriptor-set layout");
        }
    }

    /// Releases everything this device created, newest first, then the device itself. Waits for
    /// nothing: `deinit` has already waited, and a device that failed to initialize submitted
    /// nothing. Destroying the pool frees every command buffer it allocated.
    fn teardown(self: *Device) void {
        const gpa = self.gpa;
        if (self.device != null) {
            // Dependency backings are destroyed in one ordered sweep below. A lost device may
            // leave retirement entries unresolved, so ref drops during this sweep must not append
            // new entries or destroy a set layout ahead of a descriptor pool that still uses it.
            self.tearing_down = true;
            // Only a device whose table loaded can have made a resource, so these loops are empty
            // on every path that could not call them.
            for (self.retired.entries.items) |entry| entry.backing.release(self);

            var pipelines = self.pipelines.iterator();
            while (pipelines.next()) |entry| self.device_fns.vkDestroyPipeline(self.device, entry.value.native, null);
            var shaders = self.shaders.iterator();
            while (shaders.next()) |entry| {
                self.device_fns.vkDestroyShaderModule(self.device, entry.value.native, null);
                gpa.free(entry.value.bytes);
            }
            var bind_groups = self.bind_groups.iterator();
            while (bind_groups.next()) |entry| {
                _ = self.device_fns.vkFreeDescriptorSets(self.device, entry.value.pool.native, 1, &entry.value.native);
                gpa.free(entry.value.entries);
            }
            for (self.descriptor_pools.items) |pool| {
                self.device_fns.vkDestroyDescriptorPool(self.device, pool.native, null);
                gpa.destroy(pool);
            }
            // Pipeline layouts before the descriptor-set layouts they contain.
            for (self.pipeline_layout_backings.items) |backing| {
                if (!backing.released) {
                    self.device_fns.vkDestroyPipelineLayout(self.device, backing.native, null);
                    gpa.free(backing.groups);
                }
                gpa.destroy(backing);
            }
            for (self.bind_group_layout_backings.items) |backing| {
                if (!backing.released) {
                    self.device_fns.vkDestroyDescriptorSetLayout(self.device, backing.native, null);
                    gpa.free(backing.entries);
                }
                gpa.destroy(backing);
            }
            if (self.empty_set_layout != null) {
                self.device_fns.vkDestroyDescriptorSetLayout(self.device, self.empty_set_layout, null);
            }

            var buffers = self.buffers.iterator();
            while (buffers.next()) |e| Retired.release(.{ .buffer = .{ .native = e.value.native, .allocation = e.value.allocation } }, self);
            var textures = self.textures.iterator();
            while (textures.next()) |e| Retired.release(.{ .texture = .{
                .image = e.value.image,
                .view = e.value.view,
                .allocation = e.value.allocation,
            } }, self);
            var samplers = self.samplers.iterator();
            while (samplers.next()) |e| Retired.release(.{ .sampler = e.value.native }, self);
            if (self.command_pool != null) self.device_fns.vkDestroyCommandPool(self.device, self.command_pool, null);
            if (self.timeline_semaphore != null) self.device_fns.vkDestroySemaphore(self.device, self.timeline_semaphore, null);
            self.instance_fns.vkDestroyDevice(self.device, null);
        }
        if (self.surface != null) self.surface_fns.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (self.messenger != null) self.debug_fns.vkDestroyDebugUtilsMessengerEXT(self.instance, self.messenger, null);
        if (self.instance != null) {
            if (self.destroy_instance) |destroy| {
                destroy(self.instance, null);
            } else {
                log.warn("vulkan: the loader provides no 'vkDestroyInstance', so the instance leaks", .{});
            }
        }
        // Last: every function called above lives in it.
        if (self.loader) |*library| library.close();

        self.timeline.deinit(gpa);
        for (self.command_buffers.items) |cb| gpa.destroy(cb);
        self.command_buffers.deinit(gpa);
        self.free_command_buffers.deinit(gpa);
        for (self.render_passes.items) |rp| gpa.destroy(rp);
        self.render_passes.deinit(gpa);
        self.free_render_passes.deinit(gpa);
        self.free_native.deinit(gpa);
        self.retired.deinit(gpa);
        self.buffers.deinit(gpa);
        self.textures.deinit(gpa);
        self.samplers.deinit(gpa);
        self.shaders.deinit(gpa);
        self.bind_group_layouts.deinit(gpa);
        self.bind_groups.deinit(gpa);
        self.pipeline_layouts.deinit(gpa);
        self.pipelines.deinit(gpa);
        self.descriptor_pools.deinit(gpa);
        self.bind_group_layout_backings.deinit(gpa);
        self.pipeline_layout_backings.deinit(gpa);
        gpa.destroy(self);
    }

    // -- enumeration -----------------------------------------------------------------

    fn listLayers(self: *Device) interface.InitError![]c.VkLayerProperties {
        const Fetch = struct {
            fn call(device: *Device, count: *u32, items: ?[*]c.VkLayerProperties) c.VkResult {
                return device.injected(.instance_layers) orelse
                    device.global.vkEnumerateInstanceLayerProperties(count, items);
            }
        };
        return enumerate(self.gpa, c.VkLayerProperties, self, Fetch.call, "vkEnumerateInstanceLayerProperties");
    }

    fn listInstanceExtensions(self: *Device, layer: ?[*:0]const u8) interface.InitError![]c.VkExtensionProperties {
        const Context = struct { device: *Device, layer: ?[*:0]const u8 };
        const Fetch = struct {
            fn call(context: Context, count: *u32, items: ?[*]c.VkExtensionProperties) c.VkResult {
                return context.device.injected(.instance_extensions) orelse
                    context.device.global.vkEnumerateInstanceExtensionProperties(context.layer, count, items);
            }
        };
        const context: Context = .{ .device = self, .layer = layer };
        return enumerate(self.gpa, c.VkExtensionProperties, context, Fetch.call, "vkEnumerateInstanceExtensionProperties");
    }

    fn listPhysicalDevices(self: *Device) interface.InitError![]c.VkPhysicalDevice {
        const Fetch = struct {
            fn call(device: *Device, count: *u32, items: ?[*]c.VkPhysicalDevice) c.VkResult {
                return device.injected(.enumerate_devices) orelse
                    device.instance_fns.vkEnumeratePhysicalDevices(device.instance, count, items);
            }
        };
        return enumerate(self.gpa, c.VkPhysicalDevice, self, Fetch.call, "vkEnumeratePhysicalDevices");
    }

    fn listQueueFamilies(self: *Device, physical: c.VkPhysicalDevice) interface.InitError![]c.VkQueueFamilyProperties {
        const Context = struct { device: *Device, physical: c.VkPhysicalDevice };
        const Fetch = struct {
            fn call(context: Context, count: *u32, items: ?[*]c.VkQueueFamilyProperties) c.VkResult {
                context.device.instance_fns.vkGetPhysicalDeviceQueueFamilyProperties(context.physical, count, items);
                return c.VK_SUCCESS;
            }
        };
        const context: Context = .{ .device = self, .physical = physical };
        return enumerate(self.gpa, c.VkQueueFamilyProperties, context, Fetch.call, "vkGetPhysicalDeviceQueueFamilyProperties");
    }

    fn listDeviceExtensions(self: *Device, physical: c.VkPhysicalDevice) interface.InitError![]c.VkExtensionProperties {
        const Context = struct { device: *Device, physical: c.VkPhysicalDevice };
        const Fetch = struct {
            fn call(context: Context, count: *u32, items: ?[*]c.VkExtensionProperties) c.VkResult {
                return context.device.instance_fns.vkEnumerateDeviceExtensionProperties(context.physical, null, count, items);
            }
        };
        const context: Context = .{ .device = self, .physical = physical };
        return enumerate(self.gpa, c.VkExtensionProperties, context, Fetch.call, "vkEnumerateDeviceExtensionProperties");
    }
};

// -- command buffer ------------------------------------------------------------------

pub const CommandBuffer = struct {
    device: *Device,
    native: c.VkCommandBuffer,
    /// This recording's number in the device's timeline.
    recording: u64,
    /// Begun, and neither submitted nor discarded.
    open: bool,

    /// Closes the recording and hands it to the queue, signalling the timeline with its serial.
    /// Consumes the command buffer whatever it returns. A second submit is a caller's mistake the
    /// null backend reports as rule 8; this backend queues nothing twice.
    pub fn submit(self: *CommandBuffer) interface.CommandError!void {
        if (!self.open) return;
        const dev = self.device;
        self.open = false;
        if (dev.lost) return dev.refuseSubmission(self, c.VK_ERROR_DEVICE_LOST, "submit", false);

        const ended = dev.device_fns.vkEndCommandBuffer(self.native);
        if (ended != c.VK_SUCCESS) return dev.refuseSubmission(self, ended, "vkEndCommandBuffer", false);

        const serial = dev.timeline.submitted + 1;
        const buffers = [_]c.VkCommandBufferSubmitInfo{.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = self.native,
        }};
        const signals = [_]c.VkSemaphoreSubmitInfo{.{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = dev.timeline_semaphore,
            .value = serial,
            .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        }};
        const info: c.VkSubmitInfo2 = .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .commandBufferInfoCount = buffers.len,
            .pCommandBufferInfos = &buffers,
            .signalSemaphoreInfoCount = signals.len,
            .pSignalSemaphoreInfos = &signals,
        };
        const fault = dev.faults.submit;
        dev.faults.submit = null;
        const queued = fault orelse dev.device_fns.vkQueueSubmit2(dev.queue, 1, &info, null);
        if (queued != c.VK_SUCCESS) return dev.refuseSubmission(self, queued, "vkQueueSubmit2", fault != null);

        const submitted = dev.timeline.submit(self.recording, self.native);
        assert.debugOnly(submitted == serial, "submission {d} signalled timeline value {d}", .{ submitted, serial });
        dev.free_command_buffers.appendAssumeCapacity(self);
    }

    /// Opens a dynamic-rendering pass. Each attachment first moves from the state it is declared to
    /// arrive in to its attachment layout, and `end` moves it to its declared final state (§7). The
    /// render area is the attachments' common extent, and viewport and scissor start covering it,
    /// as Metal's do.
    pub fn beginRenderPass(self: *CommandBuffer, desc: command.RenderPassDesc) interface.CommandError!*RenderPass {
        const dev = self.device;
        const gpa = dev.gpa;
        const pass = if (dev.free_render_passes.pop()) |reused| reused else blk: {
            const fresh = try gpa.create(RenderPass);
            errdefer gpa.destroy(fresh);
            // Room to recycle it is reserved with it, so `end` can never fail to return it.
            try dev.free_render_passes.ensureTotalCapacity(gpa, dev.render_passes.items.len + 1);
            try dev.render_passes.append(gpa, fresh);
            break :blk fresh;
        };
        pass.* = .{ .device = dev, .cmd = self, .live = self.open };
        if (!self.open) return pass;

        var barriers: [max_attachments + 1]c.VkImageMemoryBarrier2 = undefined;
        var barrier_count: usize = 0;
        var area: ?resource.Extent2D = null;

        var colors: [max_attachments]c.VkRenderingAttachmentInfo = undefined;
        const color_count = @min(desc.color.len, max_attachments);
        for (desc.color[0..color_count], colors[0..color_count]) |attachment, *native| {
            const state = dev.textures.get(attachment.texture);
            native.* = .{
                .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                .imageView = if (state) |s| s.view else null,
                .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .loadOp = loadOp(attachment.load),
                .storeOp = storeOp(attachment.store),
                .clearValue = clearValue(attachment.load),
            };
            const s = state orelse continue;
            if (attachment.initial_state != .render_target) {
                barriers[barrier_count] = imageBarrier(s, attachment.initial_state, .render_target);
                barrier_count += 1;
            }
            // The barrier into the attachment layout isolates the pass from any earlier transfer.
            s.last_write = 0;
            area = commonExtent(area, s.desc.size);
            pass.addFinal(attachment.texture, .render_target, attachment.final_state);
        }

        var depth: c.VkRenderingAttachmentInfo = undefined;
        var depth_ptr: ?*const c.VkRenderingAttachmentInfo = null;
        var stencil_ptr: ?*const c.VkRenderingAttachmentInfo = null;
        if (desc.depth) |attachment| {
            if (dev.textures.get(attachment.texture)) |s| {
                depth = .{
                    .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                    .imageView = s.view,
                    .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    .loadOp = loadOp(attachment.load),
                    .storeOp = storeOp(attachment.store),
                    .clearValue = clearValue(attachment.load),
                };
                depth_ptr = &depth;
                if (s.desc.format.hasStencil()) stencil_ptr = &depth;
                if (attachment.initial_state != .depth_stencil) {
                    barriers[barrier_count] = imageBarrier(s, attachment.initial_state, .depth_stencil);
                    barrier_count += 1;
                }
                s.last_write = 0;
                area = commonExtent(area, s.desc.size);
                pass.addFinal(attachment.texture, .depth_stencil, attachment.final_state);
            }
        }
        if (barrier_count > 0) self.imageBarriers(barriers[0..barrier_count]);

        const extent = area orelse resource.Extent2D{ .width = 1, .height = 1 };
        const info: c.VkRenderingInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = .{ .extent = .{ .width = extent.width, .height = extent.height } },
            .layerCount = 1,
            .colorAttachmentCount = @intCast(color_count),
            .pColorAttachments = &colors,
            .pDepthAttachment = depth_ptr,
            .pStencilAttachment = stencil_ptr,
        };
        dev.device_fns.vkCmdBeginRendering(self.native, &info);
        pass.setViewport(.{ .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height) });
        pass.setScissor(.{ .width = extent.width, .height = extent.height });
        return pass;
    }

    /// §7's texture states as synchronization2 barriers, recorded in batches.
    pub fn textureBarrier(self: *CommandBuffer, barriers: []const command.TextureBarrier) interface.CommandError!void {
        if (!self.open) return;
        const dev = self.device;
        var batch: [16]c.VkImageMemoryBarrier2 = undefined;
        var len: usize = 0;
        for (barriers) |b| {
            // A dead handle is rule 9's to report; a real backend records nothing through it.
            const state = dev.textures.getConst(b.texture) orelse continue;
            batch[len] = imageBarrier(state, b.from, b.to);
            len += 1;
            if (len == batch.len) {
                self.imageBarriers(batch[0..len]);
                len = 0;
            }
        }
        if (len > 0) self.imageBarriers(batch[0..len]);
    }

    fn imageBarriers(self: *CommandBuffer, barriers: []const c.VkImageMemoryBarrier2) void {
        const dependency: c.VkDependencyInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .imageMemoryBarrierCount = @intCast(barriers.len),
            .pImageMemoryBarriers = barriers.ptr,
        };
        self.device.device_fns.vkCmdPipelineBarrier2(self.native, &dependency);
    }

    fn memoryBarrier(self: *CommandBuffer, src_stage: u64, src_access: u64, dst_stage: u64, dst_access: u64) void {
        const barrier: c.VkMemoryBarrier2 = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
            .srcStageMask = src_stage,
            .srcAccessMask = src_access,
            .dstStageMask = dst_stage,
            .dstAccessMask = dst_access,
        };
        const dependency: c.VkDependencyInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .memoryBarrierCount = 1,
            .pMemoryBarriers = &barrier,
        };
        self.device.device_fns.vkCmdPipelineBarrier2(self.native, &dependency);
    }

    fn transferWriteBarrier(self: *CommandBuffer) void {
        self.memoryBarrier(
            c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
            c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            c.VK_ACCESS_2_TRANSFER_READ_BIT | c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        );
    }

    /// Buffers have no layouts and the one queue needs no ownership transfer, but their declared
    /// state still supplies the memory dependency between a copy and its consumer (§7).
    pub fn bufferBarrier(self: *CommandBuffer, barriers: []const command.BufferBarrier) interface.CommandError!void {
        if (!self.open) return;
        const dev = self.device;
        var batch: [16]c.VkBufferMemoryBarrier2 = undefined;
        var len: usize = 0;
        for (barriers) |b| {
            const state = dev.buffers.getConst(b.buffer) orelse continue;
            const src = bufferState(b.from, state.desc.usage);
            const dst = bufferState(b.to, state.desc.usage);
            batch[len] = .{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2,
                .srcStageMask = src.stages,
                .srcAccessMask = src.access,
                .dstStageMask = dst.stages,
                .dstAccessMask = dst.access,
                .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .buffer = state.native,
                .size = c.VK_WHOLE_SIZE,
            };
            len += 1;
            if (len == batch.len) {
                self.bufferBarriers(batch[0..len]);
                len = 0;
            }
        }
        if (len > 0) self.bufferBarriers(batch[0..len]);
    }

    fn bufferBarriers(self: *CommandBuffer, barriers: []const c.VkBufferMemoryBarrier2) void {
        const dependency: c.VkDependencyInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .bufferMemoryBarrierCount = @intCast(barriers.len),
            .pBufferMemoryBarriers = barriers.ptr,
        };
        self.device.device_fns.vkCmdPipelineBarrier2(self.native, &dependency);
    }

    pub fn copyBufferToBuffer(self: *CommandBuffer, copy: command.BufferCopy) interface.CommandError!void {
        // A zero-sized copy copies nothing, and Vulkan does not accept one.
        if (!self.open or copy.size == 0) return;
        const dev = self.device;
        const src = dev.buffers.getConst(copy.src) orelse return;
        const dst = dev.buffers.getConst(copy.dst) orelse return;
        if (src.last_write == self.recording or dst.last_write == self.recording) self.transferWriteBarrier();
        const region = [_]c.VkBufferCopy{.{ .srcOffset = copy.src_offset, .dstOffset = copy.dst_offset, .size = copy.size }};
        dev.device_fns.vkCmdCopyBuffer(self.native, src.native, dst.native, region.len, &region);
        dev.buffers.get(copy.dst).?.last_write = self.recording;
    }

    /// A texture upload. A source layout Vulkan cannot express — a stride or offset that is not a
    /// whole number of texels — is first repacked on the GPU into a staging buffer this recording
    /// owns, and that buffer is retired with the recording (§5.3, `layout.zig`).
    pub fn copyBufferToTexture(self: *CommandBuffer, copy: command.BufferToTextureCopy) interface.CommandError!void {
        if (!self.open or copy.size.isEmpty()) return;
        const dev = self.device;
        const fns = &dev.device_fns;
        const src = dev.buffers.getConst(copy.src) orelse return;
        const dst = dev.textures.getConst(copy.dst) orelse return;
        const bytes_per_texel = dst.desc.format.bytesPerTexel();

        if (src.last_write == self.recording or dst.last_write == self.recording) self.transferWriteBarrier();

        var source_buffer = src.native;
        var source_offset: u64 = 0;
        var row_texels: u32 = copy.size.width;
        switch (layout.plan(copy.src_offset, copy.src_bytes_per_row, copy.size.width, copy.size.height, bytes_per_texel)) {
            .direct => |direct| {
                source_offset = direct.offset;
                row_texels = direct.row_texels;
            },
            .repack => |repack| {
                dev.reserveRetirement(1) catch return error.OutOfMemory;
                const usage = @as(u32, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT) | @as(u32, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
                const staging = dev.makeBuffer(repack.packed_size, usage, .device_local) catch return error.OutOfMemory;
                // After this recording, never before it: released once it finishes or is discarded.
                dev.retired.retire(.{ .buffer = .{ .native = staging.native, .allocation = staging.allocation } }, self.recording);

                var regions: [64]c.VkBufferCopy = undefined;
                var row: u32 = 0;
                while (row < repack.rows) {
                    const count: u32 = @min(regions.len, repack.rows - row);
                    for (regions[0..count], row..) |*region, at| {
                        region.* = .{
                            .srcOffset = layout.rowOffset(copy.src_offset, repack.stride, @intCast(at)),
                            .dstOffset = @as(u64, @intCast(at)) * repack.row_bytes,
                            .size = repack.row_bytes,
                        };
                    }
                    fns.vkCmdCopyBuffer(self.native, src.native, staging.native, count, &regions);
                    row += count;
                }
                // The row copies wrote this staging buffer; the image copy below reads it.
                self.transferWriteBarrier();
                source_buffer = staging.native;
            },
        }

        // A copy writes one aspect; a depth format's is its depth.
        const aspect: u32 = if (dst.desc.format.isDepth()) @as(u32, c.VK_IMAGE_ASPECT_DEPTH_BIT) else @as(u32, c.VK_IMAGE_ASPECT_COLOR_BIT);
        const region = [_]c.VkBufferImageCopy{.{
            .bufferOffset = source_offset,
            .bufferRowLength = row_texels,
            .imageSubresource = .{ .aspectMask = aspect, .mipLevel = copy.dst_mip_level, .layerCount = 1 },
            .imageOffset = .{ .x = @intCast(copy.dst_origin.x), .y = @intCast(copy.dst_origin.y) },
            .imageExtent = .{ .width = copy.size.width, .height = copy.size.height, .depth = 1 },
        }};
        fns.vkCmdCopyBufferToImage(self.native, source_buffer, dst.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, region.len, &region);
        dev.textures.get(copy.dst).?.last_write = self.recording;
    }

    /// Abandons a recording that will never be submitted. Nothing on the queue refers to its
    /// command buffer, so it is reset and free to begin again at once.
    pub fn discard(self: *CommandBuffer) void {
        if (!self.open) return;
        const dev = self.device;
        self.open = false;
        dev.timeline.discard(self.recording);
        if (!dev.lost) {
            const reset = dev.device_fns.vkResetCommandBuffer(self.native, 0);
            if (reset == c.VK_ERROR_DEVICE_LOST) dev.markLost("vkResetCommandBuffer", false);
        }
        dev.free_native.appendAssumeCapacity(self.native);
        dev.free_command_buffers.appendAssumeCapacity(self);
    }
};

// -- helpers -------------------------------------------------------------------------

/// Logs why initialization stopped at a Vulkan call, and returns the error that maps to.
fn failed(result: c.VkResult, comptime what: []const u8) interface.InitError {
    if (result == c.VK_ERROR_OUT_OF_HOST_MEMORY) return error.OutOfMemory;
    log.warn("vulkan: " ++ what ++ " failed: {s} ({d})", .{ vk.resultName(result), result });
    return error.DeviceCreationFailed;
}

/// Vulkan's two-call enumeration: ask how many, allocate, fetch, and start again if the set
/// changed in between. The caller frees the result.
fn enumerate(
    gpa: Allocator,
    comptime T: type,
    context: anytype,
    comptime fetch: fn (@TypeOf(context), *u32, ?[*]T) c.VkResult,
    comptime what: []const u8,
) interface.InitError![]T {
    for (0..8) |_| {
        var count: u32 = 0;
        const counted = fetch(context, &count, null);
        if (counted != c.VK_SUCCESS) return failed(counted, what);

        const items = try gpa.alloc(T, count);
        var written = count;
        const fetched = fetch(context, &written, items.ptr);
        if (fetched == c.VK_SUCCESS and written == count) return items;
        gpa.free(items);
        if (fetched != c.VK_SUCCESS and fetched != c.VK_INCOMPLETE) return failed(fetched, what);
    }
    log.warn("vulkan: " ++ what ++ " kept changing while it was read", .{});
    return error.DeviceCreationFailed;
}

/// Whether any of `items` has `field`, a NUL-padded name array, equal to `name`.
fn named(comptime field: []const u8, items: anytype, name: []const u8) bool {
    for (items) |*item| {
        if (std.mem.eql(u8, std.mem.sliceTo(&@field(item, field), 0), name)) return true;
    }
    return false;
}

/// The error a failed resource call maps to, logged unless it is plain host exhaustion.
fn resourceFailure(result: c.VkResult, comptime what: []const u8) interface.ResourceError {
    return switch (result) {
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfMemory,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => error.UnsupportedFormat,
        else => blk: {
            log.warn("vulkan: " ++ what ++ " failed: {s}", .{vk.resultName(result)});
            break :blk error.OutOfDeviceMemory;
        },
    };
}

fn shaderFailure(result: c.VkResult, comptime what: []const u8) interface.ResourceError {
    return switch (result) {
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfMemory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
        else => blk: {
            log.warn("vulkan: " ++ what ++ " rejected SPIR-V: {s}", .{vk.resultName(result)});
            break :blk error.ShaderCompilationFailed;
        },
    };
}

fn descriptorFailure(result: c.VkResult, comptime what: []const u8) interface.ResourceError {
    return switch (result) {
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfMemory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY, c.VK_ERROR_OUT_OF_POOL_MEMORY, c.VK_ERROR_FRAGMENTED_POOL => error.OutOfDeviceMemory,
        else => blk: {
            log.warn("vulkan: " ++ what ++ " failed: {s}", .{vk.resultName(result)});
            break :blk error.InvalidDescriptor;
        },
    };
}

fn pipelineFailure(result: c.VkResult, comptime what: []const u8) interface.ResourceError {
    return switch (result) {
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfMemory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
        else => blk: {
            log.warn("vulkan: " ++ what ++ " rejected the pipeline: {s}", .{vk.resultName(result)});
            break :blk error.InvalidDescriptor;
        },
    };
}

fn descriptorType(binding_type: pipeline.BindingType) c.VkDescriptorType {
    return switch (binding_type) {
        .uniform_buffer => c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .storage_buffer => c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .sampled_texture => c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .sampler => c.VK_DESCRIPTOR_TYPE_SAMPLER,
    };
}

fn shaderStages(stages: pipeline.ShaderStages) c.VkShaderStageFlags {
    var flags: u32 = 0;
    if (stages.vertex) flags |= @as(u32, c.VK_SHADER_STAGE_VERTEX_BIT);
    if (stages.fragment) flags |= @as(u32, c.VK_SHADER_STAGE_FRAGMENT_BIT);
    return flags;
}

// -- render pass --------------------------------------------------------------------

/// Colour attachments a pass may name; the RHI's other backends allow the same eight.
const max_attachments = 8;

pub const RenderPass = struct {
    device: *Device,
    cmd: *CommandBuffer,
    /// False once ended, and for a pass begun on a recording that was no longer open: nothing more
    /// is recorded through it.
    live: bool,
    ended: bool = false,
    finals: [max_attachments + 1]command.TextureBarrier = undefined,
    final_count: usize = 0,

    /// The bound pipeline's layout. Vulkan scopes set bindings and push constants to it (§9).
    layout: ?*PipelineLayoutBacking = null,
    groups: [pipeline.max_bind_groups]pipeline.BindGroupHandle = @splat(.none),
    dirty_groups: u8 = 0,
    /// The caller's bytes, padded privately to Vulkan's four-byte granularity (§6).
    constants: [pipeline.max_inline_constant_bytes]u8 = @splat(0),
    constant_bytes: u32 = 0,
    constants_dirty: bool = false,

    fn addFinal(self: *RenderPass, texture: resource.TextureHandle, from: resource.ResourceState, to: resource.ResourceState) void {
        self.finals[self.final_count] = .{ .texture = texture, .from = from, .to = to };
        self.final_count += 1;
    }

    pub fn setPipeline(self: *RenderPass, handle: pipeline.RenderPipelineHandle) void {
        if (!self.live) return;
        const state = self.device.pipelines.getConst(handle) orelse return;
        if (self.layout != state.layout) {
            // A different layout invalidates what the old one scoped: every group is bound again,
            // and the constants must be set again before the next draw (`rhi.md` §9).
            self.layout = state.layout;
            self.dirty_groups = (1 << pipeline.max_bind_groups) - 1;
            self.constant_bytes = 0;
            self.constants_dirty = false;
        }
        self.device.device_fns.vkCmdBindPipeline(self.cmd.native, c.VK_PIPELINE_BIND_POINT_GRAPHICS, state.native);
    }

    /// Remembered, and bound at the next draw against whichever layout is bound then.
    pub fn setBindGroup(self: *RenderPass, index: u32, group: pipeline.BindGroupHandle) void {
        if (!self.live or index >= pipeline.max_bind_groups) return;
        self.groups[index] = group;
        self.dirty_groups |= @as(u8, 1) << @intCast(index);
    }

    pub fn setVertexBuffer(self: *RenderPass, slot: u32, buffer: resource.BufferHandle, offset: u64) void {
        if (!self.live or slot >= pipeline.max_vertex_buffers) return;
        const state = self.device.buffers.getConst(buffer) orelse return;
        const natives = [_]c.VkBuffer{state.native};
        const offsets = [_]u64{offset};
        self.device.device_fns.vkCmdBindVertexBuffers(self.cmd.native, slot, 1, &natives, &offsets);
    }

    pub fn setIndexBuffer(self: *RenderPass, buffer: resource.BufferHandle, index_format: format.IndexFormat, offset: u64) void {
        if (!self.live) return;
        const state = self.device.buffers.getConst(buffer) orelse return;
        self.device.device_fns.vkCmdBindIndexBuffer(self.cmd.native, state.native, offset, indexType(index_format));
    }

    /// Copied at the call, whole-block. Pushed at the next draw, when the layout it belongs to is
    /// known; nothing past the caller's slice is read.
    pub fn setInlineConstants(self: *RenderPass, bytes: []const u8) void {
        if (!self.live or bytes.len > pipeline.max_inline_constant_bytes) return;
        @memcpy(self.constants[0..bytes.len], bytes);
        const padded = std.mem.alignForward(usize, bytes.len, 4);
        @memset(self.constants[bytes.len..padded], 0);
        self.constant_bytes = @intCast(padded);
        self.constants_dirty = true;
    }

    /// Foundry's clip space is y-up and Vulkan's y-down. A viewport of negative height anchored at
    /// the rectangle's bottom edge maps one onto the other, and pipelines invert their front face
    /// to match (§6).
    pub fn setViewport(self: *RenderPass, viewport: command.Viewport) void {
        if (!self.live) return;
        const native = [_]c.VkViewport{.{
            .x = viewport.x,
            .y = viewport.y + viewport.height,
            .width = viewport.width,
            .height = -viewport.height,
            .minDepth = viewport.min_depth,
            .maxDepth = viewport.max_depth,
        }};
        self.device.device_fns.vkCmdSetViewport(self.cmd.native, 0, 1, &native);
    }

    /// Framebuffer coordinates, top-left origin, which the viewport's flip does not move.
    pub fn setScissor(self: *RenderPass, rect: command.ScissorRect) void {
        if (!self.live) return;
        const native = [_]c.VkRect2D{.{
            .offset = .{ .x = std.math.cast(i32, rect.x) orelse std.math.maxInt(i32), .y = std.math.cast(i32, rect.y) orelse std.math.maxInt(i32) },
            .extent = .{ .width = rect.width, .height = rect.height },
        }};
        self.device.device_fns.vkCmdSetScissor(self.cmd.native, 0, 1, &native);
    }

    pub fn draw(self: *RenderPass, params: command.Draw) void {
        if (!self.flush()) return;
        self.device.device_fns.vkCmdDraw(self.cmd.native, params.vertex_count, params.instance_count, params.first_vertex, params.first_instance);
    }

    pub fn drawIndexed(self: *RenderPass, params: command.DrawIndexed) void {
        if (!self.flush()) return;
        self.device.device_fns.vkCmdDrawIndexed(
            self.cmd.native,
            params.index_count,
            params.instance_count,
            params.first_index,
            params.base_vertex,
            params.first_instance,
        );
    }

    /// Binds what changed since the last draw against the bound layout. False when nothing valid
    /// could be drawn: no pipeline, or a pass that records nothing.
    fn flush(self: *RenderPass) bool {
        if (!self.live) return false;
        const bound_layout = self.layout orelse return false;
        const dev = self.device;
        for (0..pipeline.max_bind_groups) |i| {
            if ((self.dirty_groups >> @intCast(i)) & 1 == 0) continue;
            // A hole in the layout is an empty set nothing reads; nothing is bound there.
            if (i >= bound_layout.groups.len or bound_layout.groups[i] == null) continue;
            const group = dev.bind_groups.getConst(self.groups[i]) orelse continue;
            const set = [_]c.VkDescriptorSet{group.native};
            dev.device_fns.vkCmdBindDescriptorSets(self.cmd.native, c.VK_PIPELINE_BIND_POINT_GRAPHICS, bound_layout.native, @intCast(i), 1, &set, 0, null);
        }
        self.dirty_groups = 0;
        if (self.constants_dirty) {
            self.constants_dirty = false;
            // Bytes a layout does not declare go nowhere (`rhi.md` §9).
            const size = @min(self.constant_bytes, std.mem.alignForward(u32, bound_layout.inline_constant_bytes, 4));
            if (size > 0) {
                dev.device_fns.vkCmdPushConstants(
                    self.cmd.native,
                    bound_layout.native,
                    c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
                    0,
                    size,
                    &self.constants,
                );
            }
        }
        return true;
    }

    /// Ends rendering, moves each attachment to its declared final state, and returns the pass.
    pub fn end(self: *RenderPass) void {
        if (self.ended) return;
        self.ended = true;
        const dev = self.device;
        if (self.live) {
            self.live = false;
            dev.device_fns.vkCmdEndRendering(self.cmd.native);
            var barriers: [max_attachments + 1]c.VkImageMemoryBarrier2 = undefined;
            var count: usize = 0;
            for (self.finals[0..self.final_count]) |final| {
                if (final.from == final.to) continue;
                // Destroyed during the pass: its backing waits for this recording, and nothing can
                // name it again, so no layout is owed.
                const state = dev.textures.getConst(final.texture) orelse continue;
                barriers[count] = imageBarrier(state, final.from, final.to);
                count += 1;
            }
            if (count > 0) self.cmd.imageBarriers(barriers[0..count]);
        }
        dev.free_render_passes.appendAssumeCapacity(self);
    }
};

fn commonExtent(so_far: ?resource.Extent2D, size: resource.Extent2D) resource.Extent2D {
    const current = so_far orelse return size;
    return .{ .width = @min(current.width, size.width), .height = @min(current.height, size.height) };
}

fn loadOp(action: command.LoadAction) c.VkAttachmentLoadOp {
    return switch (action) {
        .load => c.VK_ATTACHMENT_LOAD_OP_LOAD,
        .clear => c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .discard => c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
    };
}

fn storeOp(action: command.StoreAction) c.VkAttachmentStoreOp {
    return switch (action) {
        .store => c.VK_ATTACHMENT_STORE_OP_STORE,
        .discard => c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
    };
}

fn clearValue(action: command.LoadAction) c.VkClearValue {
    return switch (action) {
        .clear => |value| switch (value) {
            .color => |rgba| .{ .color = .{ .float32 = rgba } },
            .depth_stencil => |ds| .{ .depthStencil = .{ .depth = ds.depth, .stencil = ds.stencil } },
        },
        .load, .discard => std.mem.zeroes(c.VkClearValue),
    };
}

fn indexType(index_format: format.IndexFormat) c.VkIndexType {
    return switch (index_format) {
        .uint16 => c.VK_INDEX_TYPE_UINT16,
        .uint32 => c.VK_INDEX_TYPE_UINT32,
    };
}

const DescriptorCounts = struct {
    uniform: u32 = 0,
    storage: u32 = 0,
    image: u32 = 0,
    sampler: u32 = 0,
    resources: u32 = 0,
};

fn addLayoutCounts(
    entries: []const pipeline.BindGroupLayoutEntry,
    total: *DescriptorCounts,
    vertex: *DescriptorCounts,
    fragment: *DescriptorCounts,
) void {
    for (entries) |entry| {
        switch (entry.type) {
            .uniform_buffer => {
                total.uniform += 1;
                if (entry.visibility.vertex) vertex.uniform += 1;
                if (entry.visibility.fragment) fragment.uniform += 1;
            },
            .storage_buffer => {
                total.storage += 1;
                if (entry.visibility.vertex) vertex.storage += 1;
                if (entry.visibility.fragment) fragment.storage += 1;
            },
            .sampled_texture => {
                total.image += 1;
                if (entry.visibility.vertex) vertex.image += 1;
                if (entry.visibility.fragment) fragment.image += 1;
            },
            .sampler => {
                total.sampler += 1;
                if (entry.visibility.vertex) vertex.sampler += 1;
                if (entry.visibility.fragment) fragment.sampler += 1;
            },
        }
        if (entry.visibility.vertex) vertex.resources += 1;
        if (entry.visibility.fragment) fragment.resources += 1;
    }
}

fn countsWithinLimits(
    limits: *const c.VkPhysicalDeviceLimits,
    total: DescriptorCounts,
    vertex: DescriptorCounts,
    fragment: DescriptorCounts,
) bool {
    if (total.uniform > limits.maxDescriptorSetUniformBuffers or
        total.storage > limits.maxDescriptorSetStorageBuffers or
        total.image > limits.maxDescriptorSetSampledImages or
        total.sampler > limits.maxDescriptorSetSamplers) return false;
    for ([_]DescriptorCounts{ vertex, fragment }) |stage| {
        if (stage.uniform > limits.maxPerStageDescriptorUniformBuffers or
            stage.storage > limits.maxPerStageDescriptorStorageBuffers or
            stage.image > limits.maxPerStageDescriptorSampledImages or
            stage.sampler > limits.maxPerStageDescriptorSamplers or
            stage.resources > limits.maxPerStageResources) return false;
    }
    return true;
}

fn layoutWithinLimits(limits: *const c.VkPhysicalDeviceLimits, entries: []const pipeline.BindGroupLayoutEntry) bool {
    var total: DescriptorCounts = .{};
    var vertex: DescriptorCounts = .{};
    var fragment: DescriptorCounts = .{};
    addLayoutCounts(entries, &total, &vertex, &fragment);
    return countsWithinLimits(limits, total, vertex, fragment);
}

/// Vulkan's descriptor-set limits apply to the sum of every set in a pipeline layout, not
/// merely to each set layout in isolation. Keep this refusal ahead of the validation layer.
fn pipelineLayoutWithinLimits(limits: *const c.VkPhysicalDeviceLimits, groups: []const ?*BindGroupLayoutBacking) bool {
    var total: DescriptorCounts = .{};
    var vertex: DescriptorCounts = .{};
    var fragment: DescriptorCounts = .{};
    for (groups) |group| {
        if (group) |present| addLayoutCounts(present.entries, &total, &vertex, &fragment);
    }
    return countsWithinLimits(limits, total, vertex, fragment);
}

fn findBindGroupEntry(entries: []const pipeline.BindGroupEntry, binding: u32) ?pipeline.BindGroupEntry {
    for (entries) |entry| {
        if (entry.binding == binding) return entry;
    }
    return null;
}

fn resolvedBindingSize(binding: pipeline.BufferBinding, buffer_size: u64) ?u64 {
    if (binding.offset >= buffer_size) return null;
    const remaining = buffer_size - binding.offset;
    const size = if (binding.size == 0) remaining else binding.size;
    if (size == 0 or size > remaining) return null;
    return size;
}

fn bindingRangeValid(binding: pipeline.BufferBinding, buffer_size: u64, alignment: u32, maximum: u64) bool {
    if (alignment == 0 or binding.offset % alignment != 0) return false;
    const size = resolvedBindingSize(binding, buffer_size) orelse return false;
    return size <= maximum;
}

fn pipelineDescriptorValid(limits: *const c.VkPhysicalDeviceLimits, desc: pipeline.RenderPipelineDesc) bool {
    if (desc.vertex_buffers.len > pipeline.max_vertex_buffers or
        desc.vertex_buffers.len > limits.maxVertexInputBindings or
        desc.color_targets.len > limits.maxColorAttachments) return false;

    var attribute_count: usize = 0;
    for (desc.vertex_buffers) |binding| {
        if (binding.stride == 0 or binding.stride > limits.maxVertexInputBindingStride) return false;
        attribute_count += binding.attributes.len;
        for (binding.attributes, 0..) |attribute, i| {
            if (attribute.location >= limits.maxVertexInputAttributes or
                attribute.offset > limits.maxVertexInputAttributeOffset or
                attribute.offset +| attribute.format.size() > binding.stride) return false;
            for (binding.attributes[0..i]) |earlier| {
                if (earlier.location == attribute.location) return false;
            }
        }
    }
    if (attribute_count > limits.maxVertexInputAttributes) return false;
    // Locations are one namespace across all vertex buffers.
    for (desc.vertex_buffers, 0..) |binding, binding_index| {
        for (binding.attributes) |attribute| {
            for (desc.vertex_buffers[0..binding_index]) |earlier_binding| {
                for (earlier_binding.attributes) |earlier| {
                    if (earlier.location == attribute.location) return false;
                }
            }
        }
    }
    for (desc.color_targets) |target| {
        if (!target.format.isColor()) return false;
    }
    if (desc.depth_stencil) |depth| if (!depth.format.isDepth()) return false;
    return true;
}

fn vertexFormat(vertex_format: format.VertexFormat) c.VkFormat {
    return switch (vertex_format) {
        .float32 => c.VK_FORMAT_R32_SFLOAT,
        .float32x2 => c.VK_FORMAT_R32G32_SFLOAT,
        .float32x3 => c.VK_FORMAT_R32G32B32_SFLOAT,
        .float32x4 => c.VK_FORMAT_R32G32B32A32_SFLOAT,
        .unorm8x4 => c.VK_FORMAT_R8G8B8A8_UNORM,
        .uint8x4 => c.VK_FORMAT_R8G8B8A8_UINT,
        .uint16x2 => c.VK_FORMAT_R16G16_UINT,
        .uint32 => c.VK_FORMAT_R32_UINT,
    };
}

fn vertexStep(step: pipeline.VertexStepMode) c.VkVertexInputRate {
    return switch (step) {
        .vertex => c.VK_VERTEX_INPUT_RATE_VERTEX,
        .instance => c.VK_VERTEX_INPUT_RATE_INSTANCE,
    };
}

fn primitiveTopology(topology: pipeline.PrimitiveTopology) c.VkPrimitiveTopology {
    return switch (topology) {
        .triangle_list => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .triangle_strip => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
        .line_list => c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
        .point_list => c.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
    };
}

fn cullMode(mode: pipeline.CullMode) c.VkCullModeFlags {
    return switch (mode) {
        .none => c.VK_CULL_MODE_NONE,
        .front => c.VK_CULL_MODE_FRONT_BIT,
        .back => c.VK_CULL_MODE_BACK_BIT,
    };
}

fn frontFace(face: pipeline.FrontFace) c.VkFrontFace {
    return switch (face) {
        .counter_clockwise => c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .clockwise => c.VK_FRONT_FACE_CLOCKWISE,
    };
}

fn compareFunction(compare: pipeline.CompareFunction) c.VkCompareOp {
    return switch (compare) {
        .never => c.VK_COMPARE_OP_NEVER,
        .less => c.VK_COMPARE_OP_LESS,
        .equal => c.VK_COMPARE_OP_EQUAL,
        .less_equal => c.VK_COMPARE_OP_LESS_OR_EQUAL,
        .greater => c.VK_COMPARE_OP_GREATER,
        .not_equal => c.VK_COMPARE_OP_NOT_EQUAL,
        .greater_equal => c.VK_COMPARE_OP_GREATER_OR_EQUAL,
        .always => c.VK_COMPARE_OP_ALWAYS,
    };
}

fn blendFactor(factor: pipeline.BlendFactor) c.VkBlendFactor {
    return switch (factor) {
        .zero => c.VK_BLEND_FACTOR_ZERO,
        .one => c.VK_BLEND_FACTOR_ONE,
        .src_alpha => c.VK_BLEND_FACTOR_SRC_ALPHA,
        .one_minus_src_alpha => c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .dst_alpha => c.VK_BLEND_FACTOR_DST_ALPHA,
        .one_minus_dst_alpha => c.VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
        .src_color => c.VK_BLEND_FACTOR_SRC_COLOR,
        .one_minus_src_color => c.VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
    };
}

fn blendOp(op: pipeline.BlendOp) c.VkBlendOp {
    return switch (op) {
        .add => c.VK_BLEND_OP_ADD,
        .subtract => c.VK_BLEND_OP_SUBTRACT,
        .reverse_subtract => c.VK_BLEND_OP_REVERSE_SUBTRACT,
        .min => c.VK_BLEND_OP_MIN,
        .max => c.VK_BLEND_OP_MAX,
    };
}

fn colorWriteMask(mask: pipeline.ColorWriteMask) c.VkColorComponentFlags {
    var flags: u32 = 0;
    if (mask.r) flags |= @as(u32, c.VK_COLOR_COMPONENT_R_BIT);
    if (mask.g) flags |= @as(u32, c.VK_COLOR_COMPONENT_G_BIT);
    if (mask.b) flags |= @as(u32, c.VK_COLOR_COMPONENT_B_BIT);
    if (mask.a) flags |= @as(u32, c.VK_COLOR_COMPONENT_A_BIT);
    return flags;
}

/// The most mip levels an extent can have: down to 1x1, and never more.
fn maxMipLevels(size: resource.Extent2D) u32 {
    return std.math.log2_int(u32, @max(size.width, size.height)) + 1;
}

fn imageBarrier(state: *const TextureState, from: resource.ResourceState, to: resource.ResourceState) c.VkImageMemoryBarrier2 {
    const src = textureState(from);
    const dst = textureState(to);
    return .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = src.stages,
        .srcAccessMask = src.access,
        .dstStageMask = dst.stages,
        .dstAccessMask = dst.access,
        .oldLayout = src.layout,
        .newLayout = dst.layout,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = state.image,
        .subresourceRange = .{
            .aspectMask = aspectMask(state.desc.format),
            .levelCount = @max(state.desc.mip_levels, 1),
            .layerCount = 1,
        },
    };
}

fn vkFormat(f: format.TextureFormat) c.VkFormat {
    return switch (f) {
        .r8_unorm => c.VK_FORMAT_R8_UNORM,
        .rg8_unorm => c.VK_FORMAT_R8G8_UNORM,
        .rgba8_unorm => c.VK_FORMAT_R8G8B8A8_UNORM,
        .rgba8_unorm_srgb => c.VK_FORMAT_R8G8B8A8_SRGB,
        .bgra8_unorm => c.VK_FORMAT_B8G8R8A8_UNORM,
        .bgra8_unorm_srgb => c.VK_FORMAT_B8G8R8A8_SRGB,
        .r16_float => c.VK_FORMAT_R16_SFLOAT,
        .rgba16_float => c.VK_FORMAT_R16G16B16A16_SFLOAT,
        .r32_float => c.VK_FORMAT_R32_SFLOAT,
        .rgba32_float => c.VK_FORMAT_R32G32B32A32_SFLOAT,
        .depth32_float => c.VK_FORMAT_D32_SFLOAT,
        .depth32_float_stencil8 => c.VK_FORMAT_D32_SFLOAT_S8_UINT,
    };
}

/// Usage maps exactly (§5.2): one Vulkan bit per declared RHI flag, and nothing inferred.
fn bufferUsage(u: resource.BufferUsage) u32 {
    var bits: u32 = 0;
    if (u.vertex) bits |= @as(u32, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    if (u.index) bits |= @as(u32, c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    if (u.uniform) bits |= @as(u32, c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
    if (u.storage) bits |= @as(u32, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    if (u.copy_src) bits |= @as(u32, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    if (u.copy_dst) bits |= @as(u32, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    return bits;
}

fn imageUsage(u: resource.TextureUsage) u32 {
    var bits: u32 = 0;
    if (u.sampled) bits |= @as(u32, c.VK_IMAGE_USAGE_SAMPLED_BIT);
    if (u.render_target) bits |= @as(u32, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
    if (u.depth_stencil) bits |= @as(u32, c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT);
    if (u.copy_src) bits |= @as(u32, c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    if (u.copy_dst) bits |= @as(u32, c.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    return bits;
}

/// The format features a texture's declared usage needs, checked against the device (§5.2).
fn formatFeatures(u: resource.TextureUsage) u32 {
    var bits: u32 = 0;
    if (u.sampled) bits |= @as(u32, c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT);
    if (u.render_target) bits |= @as(u32, c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT);
    if (u.depth_stencil) bits |= @as(u32, c.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT);
    if (u.copy_src) bits |= @as(u32, c.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT);
    if (u.copy_dst) bits |= @as(u32, c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT);
    return bits;
}

fn aspectMask(f: format.TextureFormat) u32 {
    if (f.hasStencil()) return @as(u32, c.VK_IMAGE_ASPECT_DEPTH_BIT) | @as(u32, c.VK_IMAGE_ASPECT_STENCIL_BIT);
    if (f.isDepth()) return @as(u32, c.VK_IMAGE_ASPECT_DEPTH_BIT);
    return @as(u32, c.VK_IMAGE_ASPECT_COLOR_BIT);
}

fn samplerFilter(f: resource.FilterMode) c.VkFilter {
    return switch (f) {
        .nearest => c.VK_FILTER_NEAREST,
        .linear => c.VK_FILTER_LINEAR,
    };
}

fn samplerMipmap(f: resource.FilterMode) c.VkSamplerMipmapMode {
    return switch (f) {
        .nearest => c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .linear => c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
    };
}

fn samplerAddress(m: resource.AddressMode) c.VkSamplerAddressMode {
    return switch (m) {
        .clamp_to_edge => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .repeat => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .mirror_repeat => c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
    };
}

/// §7's table: the layout, access and pipeline stages a declared texture state means.
const StateAccess = struct { layout: c.VkImageLayout, access: u64, stages: u64 };

fn textureState(state: resource.ResourceState) StateAccess {
    return switch (state) {
        // No preserved content and no access: the source of a transition that discards.
        .undefined => .{ .layout = c.VK_IMAGE_LAYOUT_UNDEFINED, .access = 0, .stages = 0 },
        .render_target => .{
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .access = c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            .stages = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        },
        .depth_stencil => .{
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            .access = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .stages = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
        },
        // Either graphics stage may sample, since a binding's visibility is not known here.
        .shader_read => .{
            .layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .access = c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            .stages = c.VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
        },
        .copy_src => .{
            .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .access = c.VK_ACCESS_2_TRANSFER_READ_BIT,
            .stages = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
        },
        .copy_dst => .{
            .layout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .access = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
            .stages = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
        },
        // A WSI semaphore dependency, not a shader access; presentation arrives in Step 7.
        .present => .{ .layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, .access = 0, .stages = 0 },
    };
}

/// A buffer state has no layout, but still determines the access and pipeline stages on either
/// side of a memory dependency. Rule 11 has already rejected a state its usage cannot support.
fn bufferState(state: resource.ResourceState, usage: resource.BufferUsage) StateAccess {
    return switch (state) {
        .undefined => .{ .layout = c.VK_IMAGE_LAYOUT_UNDEFINED, .access = 0, .stages = 0 },
        .copy_src => .{
            .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .access = c.VK_ACCESS_2_TRANSFER_READ_BIT,
            .stages = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
        },
        .copy_dst => .{
            .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .access = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
            .stages = c.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
        },
        .shader_read => blk: {
            var access: u64 = 0;
            var stages: u64 = 0;
            if (usage.vertex) {
                access |= c.VK_ACCESS_2_VERTEX_ATTRIBUTE_READ_BIT;
                stages |= c.VK_PIPELINE_STAGE_2_VERTEX_ATTRIBUTE_INPUT_BIT;
            }
            if (usage.index) {
                access |= c.VK_ACCESS_2_INDEX_READ_BIT;
                stages |= c.VK_PIPELINE_STAGE_2_INDEX_INPUT_BIT;
            }
            if (usage.uniform) {
                access |= c.VK_ACCESS_2_UNIFORM_READ_BIT;
                stages |= c.VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
            }
            if (usage.storage) {
                access |= c.VK_ACCESS_2_SHADER_STORAGE_READ_BIT;
                stages |= c.VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
            }
            break :blk .{ .layout = c.VK_IMAGE_LAYOUT_UNDEFINED, .access = access, .stages = stages };
        },
        // The validation backend refuses these for buffers. Stay conservative if invalid input
        // nevertheless reaches a release Vulkan build; do not assert on a caller-controlled enum.
        .render_target, .depth_stencil, .present => .{
            .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .access = c.VK_ACCESS_2_MEMORY_READ_BIT | c.VK_ACCESS_2_MEMORY_WRITE_BIT,
            .stages = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        },
    };
}

/// Stores an opaque OS handle in a field the C headers type as a pointer to a struct.
fn handleInto(field: anytype, handle: *anyopaque) void {
    const bits: *usize = @ptrCast(field);
    bits.* = @intFromPtr(handle);
}

fn deviceType(device_type: c.VkPhysicalDeviceType) selection.DeviceType {
    return switch (device_type) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => .discrete,
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => .integrated,
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => .virtual,
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => .cpu,
        else => .other,
    };
}

/// Validation's voice. Copies nothing it is given past the call: the message is formatted into
/// the log line before this returns (§10).
fn onMessage(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    types: c.VkDebugUtilsMessageTypeFlagsEXT,
    data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    user: ?*anyopaque,
) callconv(.c) c.VkBool32 {
    _ = types;
    const messages: *Messages = @ptrCast(@alignCast(user orelse return c.VK_FALSE));
    const text: []const u8 = if (data != null and data.*.pMessage != null)
        std.mem.span(@as([*:0]const u8, @ptrCast(data.*.pMessage)))
    else
        "(no message)";

    const bits: u32 = @bitCast(severity);
    if ((bits & @as(u32, c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)) != 0) {
        _ = messages.errors.fetchAdd(1, .monotonic);
        log.err("vulkan validation: {s}", .{text});
    } else if ((bits & @as(u32, c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT)) != 0) {
        _ = messages.warnings.fetchAdd(1, .monotonic);
        log.warn("vulkan validation: {s}", .{text});
    } else {
        // Counted, not printed: the loader describes every layer and driver it considers.
        _ = messages.infos.fetchAdd(1, .monotonic);
    }
    // Never abort the call that was reported; the report is the point.
    return c.VK_FALSE;
}

// -- tests ---------------------------------------------------------------------------
//
// Against this machine's real driver, with validation required: a test that provokes a
// validation error fails through Zig's test runner, and one on a machine without the layer
// fails rather than skipping (`vulkan.md` §10).

const testing = std.testing;

fn validated(desc: interface.DeviceDesc) !*Device {
    return Device.initWith(testing.allocator, desc, .{ .validation = .required });
}

/// No error so far, and the messenger was live: a quiet run that heard nothing proves nothing.
/// Errors raised during teardown are still caught, by the test runner, through `log.err`.
fn expectValidationHeard(dev: *Device) !void {
    try testing.expectEqual(@as(u32, 0), dev.messages.errors.load(.monotonic));
    try testing.expect(dev.messages.infos.load(.monotonic) + dev.messages.warnings.load(.monotonic) > 0);
}

test "an offscreen device comes up under required validation, names its adapter, and tears down clean" {
    const dev = try validated(.{});
    defer dev.deinit();

    try testing.expect(dev.adapter.name().len > 0);
    try testing.expect(selection.meetsFloor(dev.adapter.api_version));
    try testing.expect(dev.surface == null);
    try testing.expect(dev.queue != null);
    try testing.expect(dev.timeline_semaphore != null);
    try testing.expect(dev.command_pool != null);
    try expectValidationHeard(dev);
}

test "empty work is submitted, waited for, and its command buffer begun again" {
    const dev = try validated(.{});
    defer dev.deinit();

    const cb = try dev.beginCommandBuffer();
    const recording = cb.recording;
    try cb.submit();
    try testing.expectEqual(@as(u64, 1), dev.timeline.submitted);

    dev.waitIdle();
    try testing.expectEqual(@as(u64, 1), dev.timeline.completed);
    try testing.expectEqual(recording, dev.timeline.resolvedThrough());

    const again = try dev.beginCommandBuffer();
    try testing.expectEqual(@as(usize, 1), dev.native_count);
    try again.submit();
    dev.waitIdle();
    try testing.expectEqual(@as(u64, 2), dev.timeline.completed);
    try expectValidationHeard(dev);
}

test "recordings finish in the order they began, whatever order they reach the queue" {
    const dev = try validated(.{});
    defer dev.deinit();

    const first = try dev.beginCommandBuffer();
    const second = try dev.beginCommandBuffer();
    const second_recording = second.recording;
    try second.submit();
    dev.waitIdle();
    // The second has finished, but the first is still open and may use anything destroyed
    // since it began.
    try testing.expectEqual(@as(u64, 1), dev.timeline.completed);
    try testing.expectEqual(@as(u64, 0), dev.timeline.resolvedThrough());

    try first.submit();
    dev.waitIdle();
    try testing.expectEqual(second_recording, dev.timeline.resolvedThrough());
    try testing.expectEqual(@as(usize, 2), dev.native_count);
    try expectValidationHeard(dev);
}

test "finished work is reclaimed by the next recording without a wait of its own" {
    const dev = try validated(.{});
    defer dev.deinit();

    const cb = try dev.beginCommandBuffer();
    try cb.submit();
    // Wait on the semaphore directly, as time passing would, without telling the timeline.
    const serial: u64 = 1;
    const info: c.VkSemaphoreWaitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
        .semaphoreCount = 1,
        .pSemaphores = &dev.timeline_semaphore,
        .pValues = &serial,
    };
    try testing.expectEqual(c.VK_SUCCESS, dev.device_fns.vkWaitSemaphores(dev.device, &info, std.math.maxInt(u64)));
    try testing.expectEqual(@as(u64, 0), dev.timeline.completed);

    const next = try dev.beginCommandBuffer();
    try testing.expectEqual(@as(u64, 1), dev.timeline.completed);
    try testing.expectEqual(@as(usize, 1), dev.native_count);
    next.discard();
    try expectValidationHeard(dev);
}

test "a discarded recording holds nothing back, and its command buffer begins again at once" {
    const dev = try validated(.{});
    defer dev.deinit();

    const cb = try dev.beginCommandBuffer();
    const recording = cb.recording;
    cb.discard();
    try testing.expectEqual(recording, dev.timeline.resolvedThrough());
    try testing.expectEqual(@as(u64, 0), dev.timeline.submitted);

    const again = try dev.beginCommandBuffer();
    try testing.expectEqual(@as(usize, 1), dev.native_count);
    try again.submit();
    dev.waitIdle();
    try testing.expectEqual(@as(u64, 1), dev.timeline.completed);
    try expectValidationHeard(dev);
}

test "a recording still open at teardown is discarded, not waited for" {
    const dev = try validated(.{});
    defer dev.deinit();
    _ = try dev.beginCommandBuffer();
    try expectValidationHeard(dev);
}

test "a submission the queue refuses is consumed and holds nothing back" {
    const dev = try validated(.{});
    defer dev.deinit();

    const cb = try dev.beginCommandBuffer();
    const recording = cb.recording;
    dev.faults.submit = c.VK_ERROR_OUT_OF_DEVICE_MEMORY;
    try testing.expectError(error.OutOfMemory, cb.submit());
    try testing.expectEqual(@as(u64, 0), dev.timeline.submitted);
    try testing.expectEqual(recording, dev.timeline.resolvedThrough());
    try testing.expect(!dev.lost);

    // The device still works, and the refused command buffer is the one that begins next.
    const next = try dev.beginCommandBuffer();
    try testing.expectEqual(@as(usize, 1), dev.native_count);
    try next.submit();
    dev.waitIdle();
    try testing.expectEqual(@as(u64, 1), dev.timeline.completed);
    try expectValidationHeard(dev);
}

test "a lost device is sticky: nothing more begins, and nothing is waited for" {
    const dev = try validated(.{});
    defer dev.deinit();

    const finished = try dev.beginCommandBuffer();
    try finished.submit();
    // Real work completes first, so tearing down without waiting is still valid on this healthy
    // driver.
    dev.waitIdle();

    const cb = try dev.beginCommandBuffer();
    dev.faults.submit = c.VK_ERROR_DEVICE_LOST;
    try testing.expectError(error.DeviceLost, cb.submit());
    try testing.expect(dev.lost);
    try testing.expectError(error.DeviceLost, dev.beginCommandBuffer());
    dev.waitIdle();
    try expectValidationHeard(dev);
}

test "initialization that fails at any stage unwinds everything before it" {
    inline for (@typeInfo(Stage).@"enum".fields) |field| {
        const stage = @field(Stage, field.name);
        const result = Device.initWith(testing.allocator, .{}, .{ .validation = .required, .fail_at = stage });
        if (stage == .create_surface) {
            // Offscreen, there is no surface stage to fail; the window test covers it.
            (try result).deinit();
        } else {
            try testing.expectError(error.DeviceCreationFailed, result);
        }
    }
    // A driver out of host memory is reported as exactly that.
    try testing.expectError(error.OutOfMemory, Device.initWith(testing.allocator, .{}, .{
        .validation = .required,
        .fail_at = .create_device,
        .fail_with = c.VK_ERROR_OUT_OF_HOST_MEMORY,
    }));
}

test "validation that was required and is not installed is refused, not skipped" {
    try testing.expectError(error.DeviceCreationFailed, Device.initWith(testing.allocator, .{}, .{
        .validation = .required,
        .validation_layer = "VK_LAYER_FOUNDRY_not_installed",
    }));
}

test "every host allocation initialization makes can fail without leaking" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        if (Device.initWith(failing.allocator(), .{}, .{ .validation = .required })) |dev| {
            dev.deinit();
            try testing.expect(fail_index > 0);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "a recording that cannot begin for want of memory leaves nothing open" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const dev = try Device.initWith(failing.allocator(), .{}, .{ .validation = .required });
    defer dev.deinit();

    var extra: usize = 0;
    while (true) : (extra += 1) {
        failing.fail_index = failing.alloc_index + extra;
        const cb = dev.beginCommandBuffer() catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), dev.timeline.open.items.len);
            continue;
        };
        failing.fail_index = std.math.maxInt(usize);
        try cb.submit();
        dev.waitIdle();
        break;
    }
    try testing.expectEqual(@as(u64, 1), dev.timeline.completed);
}

test "a surface this backend cannot use is refused before anything is loaded" {
    var not_a_window: u8 = 0;
    const foreign: platform.SurfaceKind = if (builtin.os.tag == .windows) .xlib_window else .win32_hwnd;
    for ([_]platform.SurfaceKind{ .metal_layer, .native_window, foreign }) |kind| {
        try testing.expectError(error.SurfaceUnsupported, Device.init(testing.allocator, .{
            .surface = .{ .kind = kind, .ptr = &not_a_window },
        }));
    }
}

test "a device for a real window takes a queue that presents to it" {
    const p = try platform.Platform.init(testing.allocator, .{});
    defer p.deinit();
    const window = try p.openWindow(.{
        .title = "Foundry Vulkan device test",
        .logical_width = 320,
        .logical_height = 240,
        .surface = .native_window,
    });
    defer p.closeWindow(window);
    const surface = p.nativeSurface(window) orelse return error.TestUnexpectedResult;

    {
        const dev = try validated(.{ .surface = surface, .surface_size = .{ .width = 320, .height = 240 } });
        defer dev.deinit();

        try testing.expect(dev.surface != null);
        var presents: c.VkBool32 = c.VK_FALSE;
        try testing.expectEqual(c.VK_SUCCESS, dev.surface_fns.vkGetPhysicalDeviceSurfaceSupportKHR(
            dev.physical,
            dev.queue_family,
            dev.surface,
            &presents,
        ));
        try testing.expect(presents != 0);

        const cb = try dev.beginCommandBuffer();
        try cb.submit();
        dev.waitIdle();
        try expectValidationHeard(dev);
    }

    // Failing at the surface, and after it, unwinds the surface too.
    for ([_]Stage{ .create_surface, .select_device, .create_command_pool }) |stage| {
        try testing.expectError(error.DeviceCreationFailed, Device.initWith(testing.allocator, .{ .surface = surface }, .{
            .validation = .required,
            .fail_at = stage,
        }));
    }
}

// -- resources, copies and retirement (Step 4) ----------------------------------------

fn finish(dev: *Device, cb: *CommandBuffer) !void {
    try cb.submit();
    dev.waitIdle();
}

fn fill(dev: *Device, buffer: resource.BufferHandle, bytes: []const u8) !void {
    const mapped = try dev.mapBuffer(buffer);
    @memcpy(mapped[0..bytes.len], bytes);
    dev.unmapBuffer(buffer);
}

/// One level of `texture`, read back through a copy no RHI operation offers; §10 allows a private
/// helper for exactly this. Expects the texture in `copy_dst`, and leaves it there. The caller frees.
fn readTexels(dev: *Device, texture: resource.TextureHandle, level: u32) ![]u8 {
    const desc = dev.textures.getConst(texture).?.desc;
    const extent = desc.size.mipLevel(level);
    const size = @as(u64, extent.width) * extent.height * desc.format.bytesPerTexel();
    const readback = try dev.createBuffer(.{ .label = "texel readback", .size = size, .usage = .{ .copy_dst = true }, .memory = .readback });
    defer dev.destroyBuffer(readback);

    const cb = try dev.beginCommandBuffer();
    try cb.textureBarrier(&.{.{ .texture = texture, .from = .copy_dst, .to = .copy_src }});
    const region = [_]c.VkBufferImageCopy{.{
        .imageSubresource = .{ .aspectMask = aspectMask(desc.format), .mipLevel = level, .layerCount = 1 },
        .imageExtent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
    }};
    dev.device_fns.vkCmdCopyImageToBuffer(
        cb.native,
        dev.textures.getConst(texture).?.image,
        c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        dev.buffers.getConst(readback).?.native,
        region.len,
        &region,
    );
    try cb.textureBarrier(&.{.{ .texture = texture, .from = .copy_src, .to = .copy_dst }});
    try finish(dev, cb);
    return testing.allocator.dupe(u8, try dev.mapBuffer(readback));
}

test "bytes written to an upload buffer reach a readback buffer through device-local memory" {
    const dev = try validated(.{});
    defer dev.deinit();

    var pattern: [256]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);

    const upload = try dev.createBuffer(.{ .label = "upload", .size = 256, .usage = .{ .copy_src = true }, .memory = .upload });
    const device_local = try dev.createBuffer(.{ .label = "device", .size = 300, .usage = .{ .copy_src = true, .copy_dst = true } });
    const readback = try dev.createBuffer(.{ .label = "readback", .size = 256, .usage = .{ .copy_dst = true }, .memory = .readback });
    try testing.expectError(error.NotMappable, dev.mapBuffer(device_local));
    try fill(dev, upload, &pattern);

    // Two independent uploads outside a frame: the second submission's opening dependency makes
    // the first one's transfer writes visible even though no host wait separates them.
    const upload_cb = try dev.beginCommandBuffer();
    try upload_cb.copyBufferToBuffer(.{ .src = upload, .dst = device_local, .dst_offset = 17, .size = 256 });
    try upload_cb.submit();
    const readback_cb = try dev.beginCommandBuffer();
    try readback_cb.copyBufferToBuffer(.{ .src = device_local, .src_offset = 20, .dst = readback, .dst_offset = 3, .size = 253 });
    // Nothing, recorded as nothing.
    try readback_cb.copyBufferToBuffer(.{ .src = upload, .dst = readback, .size = 0 });
    try finish(dev, readback_cb);

    try testing.expectEqualSlices(u8, pattern[3..], (try dev.mapBuffer(readback))[3..256]);
    try expectValidationHeard(dev);
}

test "flushing an upload and invalidating a readback are valid wherever memory needs them" {
    const dev = try validated(.{});
    defer dev.deinit();

    const pattern = "memory that is not host-coherent is flushed and invalidated";
    const upload = try dev.createBuffer(.{ .size = pattern.len, .usage = .{ .copy_src = true }, .memory = .upload });
    const readback = try dev.createBuffer(.{ .size = pattern.len, .usage = .{ .copy_dst = true }, .memory = .readback });
    // Forced: this machine's host-visible memory may well be coherent, and the path must still run.
    dev.buffers.get(upload).?.explicit_sync = true;
    dev.buffers.get(readback).?.explicit_sync = true;
    try fill(dev, upload, pattern);

    const cb = try dev.beginCommandBuffer();
    try cb.copyBufferToBuffer(.{ .src = upload, .dst = readback, .size = pattern.len });
    try finish(dev, cb);
    try testing.expectEqualStrings(pattern, try dev.mapBuffer(readback));
    try expectValidationHeard(dev);
}

test "a texture receives exactly the texels a copy names, however its source rows are laid out" {
    const dev = try validated(.{});
    defer dev.deinit();

    // Created in `copy_dst`, so its initial transition runs too.
    const texture = try dev.createTexture(.{
        .label = "target",
        .size = .{ .width = 5, .height = 3 },
        .format = .rgba8_unorm,
        .usage = .{ .copy_src = true, .copy_dst = true },
        .mip_levels = 2,
        .initial_state = .copy_dst,
    });

    // Level 0 whole, tightly packed: read where it is.
    var tight: [5 * 3 * 4]u8 = undefined;
    for (&tight, 0..) |*b, i| b.* = @truncate(i + 1);
    // 4x2 at (1, 1), three bytes in and rows 22 bytes apart: two bytes of padding a row, repacked.
    var padded: [3 + 22 + 16]u8 = @splat(0xee);
    for (0..2) |row| {
        for (0..16) |k| padded[3 + row * 22 + k] = @truncate(200 + row * 16 + k);
    }
    // Level 1, 2x1, rows a whole texel apart: read where it is.
    var level_one: [12 + 8]u8 = @splat(0xdd);
    for (0..8) |k| level_one[k] = @truncate(100 + k);

    var expected = tight;
    for (0..2) |row| {
        for (0..4) |col| {
            for (0..4) |k| expected[((1 + row) * 5 + 1 + col) * 4 + k] = padded[3 + row * 22 + col * 4 + k];
        }
    }

    const sources = [_][]const u8{ &tight, &padded, &level_one };
    var buffers: [3]resource.BufferHandle = undefined;
    for (sources, &buffers) |bytes, *buffer| {
        buffer.* = try dev.createBuffer(.{ .size = bytes.len, .usage = .{ .copy_src = true }, .memory = .upload });
        try fill(dev, buffer.*, bytes);
    }

    const cb = try dev.beginCommandBuffer();
    try cb.copyBufferToTexture(.{ .src = buffers[0], .dst = texture, .size = .{ .width = 5, .height = 3 } });
    try cb.copyBufferToTexture(.{
        .src = buffers[1],
        .src_offset = 3,
        .src_bytes_per_row = 22,
        .dst = texture,
        .dst_origin = .{ .x = 1, .y = 1 },
        .size = .{ .width = 4, .height = 2 },
    });
    try cb.copyBufferToTexture(.{
        .src = buffers[2],
        .src_bytes_per_row = 12,
        .dst = texture,
        .dst_mip_level = 1,
        .size = .{ .width = 2, .height = 1 },
    });
    try testing.expectEqual(@as(usize, 1), dev.retiredCount());
    try finish(dev, cb);
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());

    const level0 = try readTexels(dev, texture, 0);
    defer testing.allocator.free(level0);
    try testing.expectEqualSlices(u8, &expected, level0);
    const level1 = try readTexels(dev, texture, 1);
    defer testing.allocator.free(level1);
    try testing.expectEqualSlices(u8, level_one[0..8], level1);
    try expectValidationHeard(dev);
}

test "a resource destroyed while a recording uses it waits for that recording, submitted or discarded" {
    const dev = try validated(.{});
    defer dev.deinit();

    for ([_]bool{ true, false }) |submitted| {
        const src = try dev.createBuffer(.{ .size = 64, .usage = .{ .copy_src = true }, .memory = .upload });
        const dst = try dev.createBuffer(.{ .size = 64, .usage = .{ .copy_dst = true } });
        const texture = try dev.createTexture(.{
            .size = .{ .width = 4, .height = 4 },
            .format = .rgba8_unorm,
            .usage = .{ .copy_dst = true },
            .initial_state = .copy_dst,
        });
        const sampler = try dev.createSampler(.{});
        dev.waitIdle();

        const cb = try dev.beginCommandBuffer();
        try cb.copyBufferToBuffer(.{ .src = src, .dst = dst, .size = 64 });
        try cb.copyBufferToTexture(.{ .src = src, .dst = texture, .size = .{ .width = 4, .height = 4 } });
        dev.destroyBuffer(src);
        dev.destroyBuffer(dst);
        dev.destroyTexture(texture);
        dev.destroySampler(sampler);
        try testing.expectEqual(@as(usize, 4), dev.retiredCount());

        if (submitted) try cb.submit() else cb.discard();
        // Queued or abandoned, nothing has looked since: everything still waits.
        try testing.expectEqual(@as(usize, 4), dev.retiredCount());
        dev.waitIdle();
        try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    }
    try testing.expectEqual(@as(usize, 0), dev.liveCount());
    try expectValidationHeard(dev);
}

test "a resource whose creation fails at any Vulkan call leaves nothing behind" {
    const dev = try validated(.{});
    defer dev.deinit();
    const baseline = dev.allocations;

    for ([_]struct { result: c.VkResult, err: interface.ResourceError }{
        .{ .result = c.VK_ERROR_OUT_OF_DEVICE_MEMORY, .err = error.OutOfDeviceMemory },
        .{ .result = c.VK_ERROR_OUT_OF_HOST_MEMORY, .err = error.OutOfMemory },
    }) |injected| {
        for ([_]ResourceStage{ .create_buffer, .allocate_memory, .bind_memory, .map_memory }) |stage| {
            dev.faults.resource = .{ .stage = stage, .result = injected.result };
            try testing.expectError(injected.err, dev.createBuffer(.{ .size = 64, .usage = .{ .copy_src = true }, .memory = .upload }));
            try testing.expect(dev.faults.resource == null);
        }
        for ([_]ResourceStage{ .create_image, .allocate_memory, .bind_memory, .create_view, .initial_transition }) |stage| {
            dev.faults.resource = .{ .stage = stage, .result = injected.result };
            try testing.expectError(injected.err, dev.createTexture(.{
                .size = .{ .width = 8, .height = 8 },
                .format = .rgba8_unorm,
                .usage = .{ .sampled = true, .copy_dst = true },
                .initial_state = .copy_dst,
            }));
            try testing.expect(dev.faults.resource == null);
        }
        dev.faults.resource = .{ .stage = .create_sampler, .result = injected.result };
        try testing.expectError(injected.err, dev.createSampler(.{}));
    }
    dev.waitIdle();
    try testing.expectEqual(baseline, dev.allocations);
    try testing.expectEqual(@as(usize, 0), dev.liveCount());
    try expectValidationHeard(dev);
}

fn resourcesUnderPressure(dev: *Device, upload: resource.BufferHandle) !void {
    const buffer = try dev.createBuffer(.{ .size = 64, .usage = .{ .copy_dst = true } });
    defer dev.destroyBuffer(buffer);
    const texture = try dev.createTexture(.{
        .size = .{ .width = 2, .height = 2 },
        .format = .rgba8_unorm,
        .usage = .{ .copy_dst = true },
        .initial_state = .copy_dst,
    });
    defer dev.destroyTexture(texture);
    const sampler = try dev.createSampler(.{});
    defer dev.destroySampler(sampler);

    const cb = try dev.beginCommandBuffer();
    errdefer cb.discard();
    // Three bytes in: the repacked path, with its staging buffer.
    try cb.copyBufferToTexture(.{ .src = upload, .src_offset = 3, .dst = texture, .size = .{ .width = 2, .height = 2 } });
    try cb.submit();
}

test "every host allocation creating resources or repacking a copy makes can fail without leaking" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const dev = try Device.initWith(failing.allocator(), .{}, .{ .validation = .required });
    defer dev.deinit();
    const upload = try dev.createBuffer(.{ .size = 3 + 16, .usage = .{ .copy_src = true }, .memory = .upload });

    var extra: usize = 0;
    while (true) : (extra += 1) {
        failing.fail_index = failing.alloc_index + extra;
        const outcome = resourcesUnderPressure(dev, upload);
        failing.fail_index = std.math.maxInt(usize);
        dev.waitIdle();
        if (outcome) |_| break else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try testing.expectEqual(@as(usize, 1), dev.liveCount());
}

test "capabilities report this device's own limits, and no runtime shader compiler" {
    const dev = try validated(.{});
    defer dev.deinit();

    const caps = dev.capabilities();
    try testing.expect(caps.max_texture_dimension >= 4096);
    for ([_]u32{ caps.uniform_buffer_offset_alignment, caps.storage_buffer_offset_alignment }) |alignment| {
        try testing.expect(std.math.isPowerOfTwo(alignment) and alignment <= 256);
    }
    try testing.expect(caps.max_uniform_buffer_binding_size >= 16384);
    try testing.expect(caps.max_storage_buffer_binding_size >= 1 << 27);
    try testing.expect(!caps.runtime_shader_compilation);
    try testing.expectEqual(memory.unified(dev.memory_types[0..dev.memory_type_count]), caps.unified_memory);

    // Both of the renderer's memory paths can be asked for on one machine.
    dev.unified_override = true;
    try testing.expect(dev.capabilities().unified_memory);
    dev.unified_override = false;
    try testing.expect(!dev.capabilities().unified_memory);
}

test "a descriptor Vulkan cannot build is refused before anything is created" {
    const dev = try validated(.{});
    defer dev.deinit();
    const baseline = dev.allocations;
    const max = dev.limits.maxImageDimension2D;

    for ([_]resource.TextureDesc{
        .{ .size = .{ .width = 0, .height = 4 }, .format = .rgba8_unorm, .usage = .{ .sampled = true } },
        .{ .size = .{ .width = 4, .height = 4 }, .format = .rgba8_unorm, .usage = .{} },
        // 8x8 has four levels, down to 1x1.
        .{ .size = .{ .width = 8, .height = 8 }, .format = .rgba8_unorm, .usage = .{ .sampled = true }, .mip_levels = 5 },
        .{ .size = .{ .width = max + 1, .height = 1 }, .format = .rgba8_unorm, .usage = .{ .sampled = true } },
    }) |desc| try testing.expectError(error.InvalidDescriptor, dev.createTexture(desc));
    try testing.expectError(error.InvalidDescriptor, dev.createBuffer(.{ .size = 0, .usage = .{ .vertex = true } }));
    try testing.expectError(error.InvalidDescriptor, dev.createBuffer(.{ .size = 16, .usage = .{} }));

    // The VkBuffer itself is cleaned up when its one allocation would exceed the device's count.
    {
        dev.allocations = dev.limits.maxMemoryAllocationCount;
        defer dev.allocations = baseline;
        try testing.expectError(error.OutOfDeviceMemory, dev.createBuffer(.{ .size = 16, .usage = .{ .copy_dst = true } }));
    }

    try testing.expectEqual(baseline, dev.allocations);
    try testing.expectEqual(@as(usize, 0), dev.liveCount());
    try expectValidationHeard(dev);
}

// -- shaders, persistent bindings and pipelines (Step 5) ------------------------------

const builtin_stages = struct {
    const sprite_vertex = @embedFile("sprite_vertex_spirv");
    const sprite_fragment = @embedFile("sprite_fragment_spirv");
    const quad_vertex = @embedFile("quad_vertex_spirv");
    const quad_fragment = @embedFile("quad_fragment_spirv");
};

fn createSpritePipeline(
    dev: *Device,
    pipeline_layout: pipeline.PipelineLayoutHandle,
    vertex: resource.ShaderModuleHandle,
    fragment: resource.ShaderModuleHandle,
) !pipeline.RenderPipelineHandle {
    return dev.createRenderPipeline(.{
        .label = "sprite pipeline",
        .layout = pipeline_layout,
        .vertex_shader = vertex,
        .vertex_entry = "main",
        .fragment_shader = fragment,
        .fragment_entry = "main",
        .vertex_buffers = &.{.{
            .stride = 20,
            .attributes = &.{
                .{ .location = 0, .offset = 0, .format = .float32x2 },
                .{ .location = 1, .offset = 8, .format = .float32x2 },
                .{ .location = 2, .offset = 16, .format = .unorm8x4 },
            },
        }},
        .color_targets = &.{.{
            .format = .bgra8_unorm_srgb,
            .blend = pipeline.BlendState.premultiplied_alpha,
        }},
    });
}

test "the four produced stages carry the documented shader ABI" {
    try spirv.validateProfile(builtin_stages.sprite_vertex, .sprite_vertex);
    try spirv.validateProfile(builtin_stages.sprite_fragment, .sprite_fragment);
    try spirv.validateProfile(builtin_stages.quad_vertex, .quad_vertex);
    try spirv.validateProfile(builtin_stages.quad_fragment, .quad_fragment);
}

test "malformed shader envelopes and wrong-stage entries are refused before a pipeline call" {
    const dev = try validated(.{});
    defer dev.deinit();

    try testing.expectError(error.ShaderCompilationFailed, dev.createShaderModule(.{ .bytes = "not SPIR-V" }));
    var corrupted = builtin_stages.sprite_vertex[0..24].*;
    corrupted[0] = 0;
    try testing.expectError(error.ShaderCompilationFailed, dev.createShaderModule(.{ .bytes = &corrupted }));
    try testing.expectError(error.RuntimeCompilationUnsupported, dev.createShaderModuleFromSource(.{ .source = "void main(){}" }));

    const vertex = try dev.createShaderModule(.{ .label = "sprite vertex", .bytes = builtin_stages.sprite_vertex });
    const fragment = try dev.createShaderModule(.{ .label = "sprite fragment", .bytes = builtin_stages.sprite_fragment });
    const group_layout = try dev.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
        .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
    } });
    const layout_handle = try dev.createPipelineLayout(.{
        .bind_group_layouts = &.{group_layout},
        .inline_constant_bytes = 64,
    });
    try testing.expectError(error.InvalidDescriptor, dev.createRenderPipeline(.{
        .layout = layout_handle,
        .vertex_shader = vertex,
        .vertex_entry = "vertexMain",
        .fragment_shader = fragment,
        .fragment_entry = "main",
    }));
    try testing.expectError(error.InvalidDescriptor, dev.createRenderPipeline(.{
        .layout = layout_handle,
        .vertex_shader = fragment,
        .vertex_entry = "main",
        .fragment_shader = fragment,
        .fragment_entry = "main",
    }));

    dev.destroyPipelineLayout(layout_handle);
    dev.destroyBindGroupLayout(group_layout);
    dev.destroyShaderModule(fragment);
    dev.destroyShaderModule(vertex);
    try expectValidationHeard(dev);
}

test "persistent descriptor sets preserve holes, aligned ranges and dependency lifetimes" {
    const dev = try validated(.{});
    defer dev.deinit();

    const vertex = try dev.createShaderModule(.{ .label = "sprite vertex", .bytes = builtin_stages.sprite_vertex });
    const fragment = try dev.createShaderModule(.{ .label = "sprite fragment", .bytes = builtin_stages.sprite_fragment });
    const group_layout = try dev.createBindGroupLayout(.{ .label = "material", .entries = &.{
        .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
        .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
    } });
    const pipeline_layout = try dev.createPipelineLayout(.{
        .bind_group_layouts = &.{group_layout},
        .inline_constant_bytes = 64,
    });
    const hole_layout = try dev.createPipelineLayout(.{ .bind_group_layouts = &.{ .none, .none, group_layout } });
    const hole_backing = dev.pipeline_layouts.getConst(hole_layout).?.backing;
    try testing.expect(hole_backing.groups[0] == null and hole_backing.groups[1] == null);
    try testing.expect(hole_backing.groups[2].? == dev.bind_group_layouts.getConst(group_layout).?.backing);

    const texture = try dev.createTexture(.{
        .size = .{ .width = 4, .height = 4 },
        .format = .rgba8_unorm_srgb,
        .usage = .{ .sampled = true },
        .initial_state = .shader_read,
    });
    const sampler = try dev.createSampler(.{});
    const group = try dev.createBindGroup(.{ .layout = group_layout, .entries = &.{
        .{ .binding = 1, .resource = .{ .sampler = sampler } },
        .{ .binding = 0, .resource = .{ .sampled_texture = texture } },
    } });
    const render_pipeline = try createSpritePipeline(dev, pipeline_layout, vertex, fragment);
    dev.waitIdle();

    // Handles die now; backings wait for the open recording and for their dependency refs.
    const cb = try dev.beginCommandBuffer();
    dev.destroyRenderPipeline(render_pipeline);
    dev.destroyPipelineLayout(pipeline_layout);
    dev.destroyPipelineLayout(hole_layout);
    dev.destroyBindGroup(group);
    dev.destroyBindGroupLayout(group_layout);
    dev.destroyShaderModule(vertex);
    dev.destroyShaderModule(fragment);
    dev.destroyTexture(texture);
    dev.destroySampler(sampler);
    try testing.expect(dev.retiredCount() > 0);
    try cb.submit();
    dev.waitIdle();
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try testing.expectEqual(@as(usize, 0), dev.liveCount());
    try expectValidationHeard(dev);
}

test "buffer bindings use resolved aligned ranges and descriptor pools grow without resetting live sets" {
    const dev = try validated(.{});
    defer dev.deinit();
    const caps = dev.capabilities();
    const alignment = @max(caps.uniform_buffer_offset_alignment, caps.storage_buffer_offset_alignment);
    const buffer_size = @as(u64, alignment) * 2 + 16;
    const buffer = try dev.createBuffer(.{
        .size = buffer_size,
        .usage = .{ .uniform = true, .storage = true },
        .memory = .upload,
    });
    const layout_handle = try dev.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 7, .type = .uniform_buffer, .visibility = .both },
        .{ .binding = 9, .type = .storage_buffer, .visibility = .{ .vertex = true } },
    } });
    try testing.expectError(error.InvalidDescriptor, dev.createBindGroup(.{ .layout = layout_handle, .entries = &.{
        .{ .binding = 7, .resource = .{ .uniform_buffer = .{ .buffer = buffer, .offset = 1, .size = 16 } } },
        .{ .binding = 9, .resource = .{ .storage_buffer = .{ .buffer = buffer, .offset = alignment, .size = 16 } } },
    } }));
    const group = try dev.createBindGroup(.{ .layout = layout_handle, .entries = &.{
        .{ .binding = 7, .resource = .{ .uniform_buffer = .{ .buffer = buffer, .offset = alignment, .size = 0 } } },
        .{ .binding = 9, .resource = .{ .storage_buffer = .{ .buffer = buffer, .offset = alignment, .size = 16 } } },
    } });
    const stored_binding = dev.bind_groups.getConst(group).?.entries[0].resource.uniform_buffer;
    try testing.expectEqual(buffer_size - alignment, resolvedBindingSize(stored_binding, buffer_size).?);

    // Each set is legal alone, but Vulkan applies maxDescriptorSet* to their aggregate in a
    // pipeline layout. A backend must refuse that caller-controlled descriptor before the driver.
    const saved_uniform_limit = dev.limits.maxDescriptorSetUniformBuffers;
    dev.limits.maxDescriptorSetUniformBuffers = 1;
    try testing.expectError(error.InvalidDescriptor, dev.createPipelineLayout(.{
        .bind_group_layouts = &.{ layout_handle, layout_handle },
    }));
    dev.limits.maxDescriptorSetUniformBuffers = saved_uniform_limit;

    const empty_layout = try dev.createBindGroupLayout(.{ .entries = &.{} });
    var groups: [Device.descriptor_sets_per_pool + 1]pipeline.BindGroupHandle = undefined;
    for (&groups) |*handle| handle.* = try dev.createBindGroup(.{ .layout = empty_layout, .entries = &.{} });
    try testing.expectEqual(@as(usize, 2), dev.descriptor_pools.items.len);
    try testing.expectEqual(Device.descriptor_sets_per_pool, dev.descriptor_pools.items[0].live_sets);
    for (groups) |handle| dev.destroyBindGroup(handle);
    dev.destroyBindGroup(group);
    dev.destroyBindGroupLayout(empty_layout);
    dev.destroyBindGroupLayout(layout_handle);
    dev.destroyBuffer(buffer);
    try testing.expectEqual(@as(u32, 0), dev.descriptor_pools.items[0].live_sets);
    try expectValidationHeard(dev);
}

test "every Vulkan call added for shaders bindings and pipelines unwinds before publishing a handle" {
    const dev = try validated(.{});
    defer dev.deinit();

    dev.faults.resource = .{ .stage = .create_shader, .result = c.VK_ERROR_OUT_OF_DEVICE_MEMORY };
    try testing.expectError(error.OutOfDeviceMemory, dev.createShaderModule(.{ .bytes = builtin_stages.sprite_vertex }));
    dev.faults.resource = .{ .stage = .create_bind_group_layout, .result = c.VK_ERROR_OUT_OF_HOST_MEMORY };
    try testing.expectError(error.OutOfMemory, dev.createBindGroupLayout(.{ .entries = &.{} }));

    const vertex = try dev.createShaderModule(.{ .bytes = builtin_stages.sprite_vertex });
    const fragment = try dev.createShaderModule(.{ .bytes = builtin_stages.sprite_fragment });
    const group_layout = try dev.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
        .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
    } });
    const texture = try dev.createTexture(.{
        .size = .{ .width = 2, .height = 2 },
        .format = .rgba8_unorm_srgb,
        .usage = .{ .sampled = true },
        .initial_state = .shader_read,
    });
    const sampler = try dev.createSampler(.{});
    const group_desc: pipeline.BindGroupDesc = .{ .layout = group_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .sampled_texture = texture } },
        .{ .binding = 1, .resource = .{ .sampler = sampler } },
    } };

    dev.faults.resource = .{ .stage = .create_descriptor_pool, .result = c.VK_ERROR_OUT_OF_DEVICE_MEMORY };
    try testing.expectError(error.OutOfDeviceMemory, dev.createBindGroup(group_desc));
    dev.faults.resource = .{ .stage = .allocate_descriptor_set, .result = c.VK_ERROR_OUT_OF_HOST_MEMORY };
    try testing.expectError(error.OutOfMemory, dev.createBindGroup(group_desc));
    const group = try dev.createBindGroup(group_desc);

    const layout_desc: pipeline.PipelineLayoutDesc = .{
        .bind_group_layouts = &.{group_layout},
        .inline_constant_bytes = 64,
    };
    dev.faults.resource = .{ .stage = .create_pipeline_layout, .result = c.VK_ERROR_OUT_OF_DEVICE_MEMORY };
    try testing.expectError(error.OutOfDeviceMemory, dev.createPipelineLayout(layout_desc));
    const pipeline_layout = try dev.createPipelineLayout(layout_desc);
    dev.faults.resource = .{ .stage = .create_render_pipeline, .result = c.VK_ERROR_OUT_OF_HOST_MEMORY };
    try testing.expectError(error.OutOfMemory, createSpritePipeline(dev, pipeline_layout, vertex, fragment));
    try testing.expect(dev.faults.resource == null);

    dev.destroyPipelineLayout(pipeline_layout);
    dev.destroyBindGroup(group);
    dev.destroySampler(sampler);
    dev.destroyTexture(texture);
    dev.destroyBindGroupLayout(group_layout);
    dev.destroyShaderModule(fragment);
    dev.destroyShaderModule(vertex);
    dev.waitIdle();
    try testing.expectEqual(@as(usize, 0), dev.liveCount());
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try expectValidationHeard(dev);
}

fn step5ObjectsUnderPressure(dev: *Device) !void {
    const vertex = try dev.createShaderModule(.{ .bytes = builtin_stages.sprite_vertex });
    defer dev.destroyShaderModule(vertex);
    const fragment = try dev.createShaderModule(.{ .bytes = builtin_stages.sprite_fragment });
    defer dev.destroyShaderModule(fragment);
    const group_layout = try dev.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
        .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
    } });
    defer dev.destroyBindGroupLayout(group_layout);
    const texture = try dev.createTexture(.{
        .size = .{ .width = 2, .height = 2 },
        .format = .rgba8_unorm_srgb,
        .usage = .{ .sampled = true },
        .initial_state = .shader_read,
    });
    defer dev.destroyTexture(texture);
    const sampler = try dev.createSampler(.{});
    defer dev.destroySampler(sampler);
    const group = try dev.createBindGroup(.{ .layout = group_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .sampled_texture = texture } },
        .{ .binding = 1, .resource = .{ .sampler = sampler } },
    } });
    defer dev.destroyBindGroup(group);
    const pipeline_layout = try dev.createPipelineLayout(.{
        .bind_group_layouts = &.{group_layout},
        .inline_constant_bytes = 64,
    });
    defer dev.destroyPipelineLayout(pipeline_layout);
    const render_pipeline = try createSpritePipeline(dev, pipeline_layout, vertex, fragment);
    defer dev.destroyRenderPipeline(render_pipeline);
}

test "every host allocation in the Step 5 object graph can fail without a leak" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const dev = try Device.initWith(failing.allocator(), .{}, .{ .validation = .required });
    defer dev.deinit();

    var extra: usize = 0;
    while (true) : (extra += 1) {
        failing.fail_index = failing.alloc_index + extra;
        const outcome = step5ObjectsUnderPressure(dev);
        failing.fail_index = std.math.maxInt(usize);
        dev.waitIdle();
        if (outcome) |_| break else |err| try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqual(@as(usize, 0), dev.liveCount());
        try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    }
    try testing.expectEqual(@as(usize, 0), dev.liveCount());
    try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    try expectValidationHeard(dev);
}

// -- drawing offscreen (Step 6) -------------------------------------------------------

const SpriteVertex = extern struct { position: [2]f32, uv: [2]f32, color: [4]u8 };

/// Column-major, as the sprite stage reads its push block.
fn scaleMatrix(x: f32, y: f32) [64]u8 {
    return @bitCast([16]f32{ x, 0, 0, 0, 0, y, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 });
}

fn corner(x: f32, y: f32, u: f32, v: f32, color: [4]u8) SpriteVertex {
    return .{ .position = .{ x, y }, .uv = .{ u, v }, .color = color };
}

/// Two triangles, counter-clockwise with +y up, covering the clip-space rectangle.
fn quad(x0: f32, y0: f32, x1: f32, y1: f32, color: [4]u8) [6]SpriteVertex {
    return .{
        corner(x0, y0, 0, 1, color), corner(x1, y0, 1, 1, color), corner(x1, y1, 1, 0, color),
        corner(x0, y0, 0, 1, color), corner(x1, y1, 1, 0, color), corner(x0, y1, 0, 0, color),
    };
}

fn texelAt(pixels: []const u8, size: u32, x: u32, y: u32) [4]u8 {
    const at = (y * size + x) * 4;
    return pixels[at..][0..4].*;
}

/// render2d's sprite contract on a device — its two produced stages, its material layout, a
/// 64-byte constant block and a nearest sampler — with what the probes draw with.
const Canvas = struct {
    dev: *Device,
    vertex: resource.ShaderModuleHandle,
    fragment: resource.ShaderModuleHandle,
    group_layout: pipeline.BindGroupLayoutHandle,
    pipeline_layout: pipeline.PipelineLayoutHandle,
    sampler: resource.SamplerHandle,

    fn init(dev: *Device) !Canvas {
        const group_layout = try dev.createBindGroupLayout(.{ .label = "material", .entries = &.{
            .{ .binding = 0, .type = .sampled_texture, .visibility = .{ .fragment = true } },
            .{ .binding = 1, .type = .sampler, .visibility = .{ .fragment = true } },
        } });
        return .{
            .dev = dev,
            .vertex = try dev.createShaderModule(.{ .label = "sprite vertex", .bytes = builtin_stages.sprite_vertex }),
            .fragment = try dev.createShaderModule(.{ .label = "sprite fragment", .bytes = builtin_stages.sprite_fragment }),
            .group_layout = group_layout,
            .pipeline_layout = try dev.createPipelineLayout(.{ .bind_group_layouts = &.{group_layout}, .inline_constant_bytes = 64 }),
            .sampler = try dev.createSampler(.{}),
        };
    }

    const PipelineOptions = struct {
        target: format.TextureFormat = .rgba8_unorm,
        blend: ?pipeline.BlendState = null,
        depth: ?pipeline.DepthStencilState = null,
        cull: pipeline.CullMode = .none,
    };

    fn pipelineWith(self: Canvas, options: PipelineOptions) !pipeline.RenderPipelineHandle {
        return self.dev.createRenderPipeline(.{
            .label = "probe sprite",
            .layout = self.pipeline_layout,
            .vertex_shader = self.vertex,
            .vertex_entry = "main",
            .fragment_shader = self.fragment,
            .fragment_entry = "main",
            .vertex_buffers = &.{.{ .stride = @sizeOf(SpriteVertex), .attributes = &.{
                .{ .location = 0, .offset = 0, .format = .float32x2 },
                .{ .location = 1, .offset = 8, .format = .float32x2 },
                .{ .location = 2, .offset = 16, .format = .unorm8x4 },
            } }},
            .color_targets = &.{.{ .format = options.target, .blend = options.blend }},
            .depth_stencil = options.depth,
            .primitive = .{ .cull_mode = options.cull },
        });
    }

    /// A 1x1 texture holding `texel`, uploaded, made readable and grouped with the sampler.
    fn swatch(self: Canvas, texture_format: format.TextureFormat, texel: [4]u8) !pipeline.BindGroupHandle {
        const dev = self.dev;
        const texture = try dev.createTexture(.{
            .label = "swatch",
            .size = .{ .width = 1, .height = 1 },
            .format = texture_format,
            .usage = .{ .sampled = true, .copy_dst = true },
            .initial_state = .copy_dst,
        });
        const upload = try dev.createBuffer(.{ .size = 4, .usage = .{ .copy_src = true }, .memory = .upload });
        defer dev.destroyBuffer(upload);
        try fill(dev, upload, &texel);
        const cb = try dev.beginCommandBuffer();
        try cb.copyBufferToTexture(.{ .src = upload, .dst = texture, .size = .{ .width = 1, .height = 1 } });
        try cb.textureBarrier(&.{.{ .texture = texture, .from = .copy_dst, .to = .shader_read }});
        try finish(dev, cb);
        return self.group(texture);
    }

    fn group(self: Canvas, texture: resource.TextureHandle) !pipeline.BindGroupHandle {
        return self.dev.createBindGroup(.{ .layout = self.group_layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .sampled_texture = texture } },
            .{ .binding = 1, .resource = .{ .sampler = self.sampler } },
        } });
    }

    /// A target the probes render into and read back. It rests in `copy_dst` between passes.
    fn target(self: Canvas, size: u32, target_format: format.TextureFormat) !resource.TextureHandle {
        return self.dev.createTexture(.{
            .label = "probe target",
            .size = .{ .width = size, .height = size },
            .format = target_format,
            .usage = .{ .render_target = true, .sampled = true, .copy_src = true, .copy_dst = true },
            .initial_state = .copy_dst,
        });
    }

    /// Host-visible vertices, bound where they are: the direct path a unified-memory renderer takes.
    fn vertices(self: Canvas, list: []const SpriteVertex) !resource.BufferHandle {
        const buffer = try self.dev.createBuffer(.{ .size = @sizeOf(SpriteVertex) * list.len, .usage = .{ .vertex = true }, .memory = .upload });
        try fill(self.dev, buffer, std.mem.sliceAsBytes(list));
        return buffer;
    }
};

const Probe = struct {
    target: resource.TextureHandle,
    render_pipeline: pipeline.RenderPipelineHandle = .none,
    group: pipeline.BindGroupHandle = .none,
    vertices: resource.BufferHandle = .none,
    vertex_count: u32 = 6,
    constants: [64]u8 = scaleMatrix(1, 1),
    depth: ?command.DepthAttachment = null,
    load: command.LoadAction = .{ .clear = .{ .color = .{ 0, 0, 0, 1 } } },
    draw: bool = true,
};

/// One recording: a pass over `probe.target` that draws once, then level 0 read back.
fn render(dev: *Device, probe: Probe) ![]u8 {
    const cb = try dev.beginCommandBuffer();
    const pass = try cb.beginRenderPass(.{
        .color = &.{.{ .texture = probe.target, .load = probe.load, .initial_state = .copy_dst, .final_state = .copy_dst }},
        .depth = probe.depth,
    });
    if (probe.draw) {
        pass.setPipeline(probe.render_pipeline);
        pass.setBindGroup(0, probe.group);
        pass.setVertexBuffer(0, probe.vertices, 0);
        pass.setInlineConstants(&probe.constants);
        pass.draw(.{ .vertex_count = probe.vertex_count });
    }
    pass.end();
    try finish(dev, cb);
    return readTexels(dev, probe.target, 0);
}

const red = [4]u8{ 255, 0, 0, 255 };
const green = [4]u8{ 0, 255, 0, 255 };
const blue = [4]u8{ 0, 0, 255, 255 };
const black = [4]u8{ 0, 0, 0, 255 };
const white = [4]u8{ 255, 255, 255, 255 };

test "a sprite lands where Foundry's clip space puts it, the right way up" {
    const dev = try validated(.{});
    defer dev.deinit();
    const canvas = try Canvas.init(dev);

    // The top-left quadrant of clip space: x from -1 to 0 and y from 0 to +1, with +y up.
    const top_left = quad(-1, 0, 0, 1, red);
    const pixels = try render(dev, .{
        .target = try canvas.target(16, .rgba8_unorm),
        .render_pipeline = try canvas.pipelineWith(.{}),
        .group = try canvas.swatch(.rgba8_unorm, white),
        .vertices = try canvas.vertices(&top_left),
    });
    defer testing.allocator.free(pixels);

    try testing.expectEqual(red, texelAt(pixels, 16, 0, 0));
    try testing.expectEqual(red, texelAt(pixels, 16, 7, 7));
    try testing.expectEqual(black, texelAt(pixels, 16, 8, 7));
    try testing.expectEqual(black, texelAt(pixels, 16, 7, 8));
    try testing.expectEqual(black, texelAt(pixels, 16, 15, 15));
    try expectValidationHeard(dev);
}

test "an indexed draw takes its constants, and a scissor clips it" {
    const dev = try validated(.{});
    defer dev.deinit();
    const canvas = try Canvas.init(dev);
    const target = try canvas.target(16, .rgba8_unorm);

    const corners = [_]SpriteVertex{
        corner(-1, -1, 0, 1, green), corner(1, -1, 1, 1, green),
        corner(1, 1, 1, 0, green),   corner(-1, 1, 0, 0, green),
    };
    const vertices = try canvas.vertices(&corners);
    const indices = try dev.createBuffer(.{ .size = 12, .usage = .{ .index = true }, .memory = .upload });
    try fill(dev, indices, std.mem.sliceAsBytes(&[_]u16{ 0, 1, 2, 0, 2, 3 }));
    const halved = scaleMatrix(0.5, 0.5);

    const cb = try dev.beginCommandBuffer();
    const pass = try cb.beginRenderPass(.{
        .color = &.{.{ .texture = target, .initial_state = .copy_dst, .final_state = .copy_dst }},
    });
    pass.setPipeline(try canvas.pipelineWith(.{}));
    pass.setBindGroup(0, try canvas.swatch(.rgba8_unorm, white));
    pass.setVertexBuffer(0, vertices, 0);
    pass.setIndexBuffer(indices, .uint16, 0);
    pass.setInlineConstants(&halved);
    pass.setScissor(.{ .x = 0, .y = 0, .width = 8, .height = 16 });
    pass.drawIndexed(.{ .index_count = 6 });
    pass.end();
    try finish(dev, cb);
    const pixels = try readTexels(dev, target, 0);
    defer testing.allocator.free(pixels);

    // Halved, the quad covers pixels 4 to 11 on both axes, and the scissor keeps columns below 8.
    try testing.expectEqual(green, texelAt(pixels, 16, 4, 4));
    try testing.expectEqual(green, texelAt(pixels, 16, 7, 11));
    try testing.expectEqual(black, texelAt(pixels, 16, 8, 4));
    try testing.expectEqual(black, texelAt(pixels, 16, 3, 4));
    try testing.expectEqual(black, texelAt(pixels, 16, 4, 12));
    try expectValidationHeard(dev);
}

fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f32) f32 {
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

test "sRGB decodes when sampled, blends premultiplied in linear light, and encodes when written" {
    const dev = try validated(.{});
    defer dev.deinit();
    const canvas = try Canvas.init(dev);

    const everywhere = quad(-1, -1, 1, 1, white);
    const pixels = try render(dev, .{
        .target = try canvas.target(4, .rgba8_unorm_srgb),
        .render_pipeline = try canvas.pipelineWith(.{ .target = .rgba8_unorm_srgb, .blend = pipeline.BlendState.premultiplied_alpha }),
        .group = try canvas.swatch(.rgba8_unorm_srgb, .{ 188, 188, 188, 128 }),
        .vertices = try canvas.vertices(&everywhere),
    });
    defer testing.allocator.free(pixels);

    // The fragment stage premultiplies the decoded texel; the blend lays it over opaque black.
    const alpha: f32 = 128.0 / 255.0;
    const expected: f32 = linearToSrgb(srgbToLinear(188.0 / 255.0) * alpha) * 255.0;
    const got = texelAt(pixels, 4, 1, 1);
    for (got[0..3]) |channel| try testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(channel)), 2.0);
    try testing.expectEqual(@as(u8, 255), got[3]);
    try expectValidationHeard(dev);
}

test "a depth attachment clears, and its test decides what draws" {
    const dev = try validated(.{});
    defer dev.deinit();
    const canvas = try Canvas.init(dev);
    const target = try canvas.target(4, .rgba8_unorm);
    const depth = try dev.createTexture(.{
        .label = "probe depth",
        .size = .{ .width = 4, .height = 4 },
        .format = .depth32_float,
        .usage = .{ .depth_stencil = true },
    });
    const render_pipeline = try canvas.pipelineWith(.{ .depth = .{ .format = .depth32_float, .depth_compare = .less } });
    const group = try canvas.swatch(.rgba8_unorm, white);
    const everywhere = quad(-1, -1, 1, 1, red);
    const vertices = try canvas.vertices(&everywhere);

    // The sprite stage writes depth 0: nearer than a clear of 1, and not nearer than a clear of 0.
    for ([_]struct { clear: f32, expected: [4]u8 }{
        .{ .clear = 1.0, .expected = red },
        .{ .clear = 0.0, .expected = black },
    }) |case| {
        const pixels = try render(dev, .{
            .target = target,
            .render_pipeline = render_pipeline,
            .group = group,
            .vertices = vertices,
            .depth = .{ .texture = depth, .load = .{ .clear = .{ .depth_stencil = .{ .depth = case.clear } } } },
        });
        defer testing.allocator.free(pixels);
        try testing.expectEqual(case.expected, texelAt(pixels, 4, 1, 2));
    }
    try expectValidationHeard(dev);
}

test "back faces are culled by Foundry's winding, not by Vulkan's" {
    const dev = try validated(.{});
    defer dev.deinit();
    const canvas = try Canvas.init(dev);
    const target = try canvas.target(16, .rgba8_unorm);
    const group = try canvas.swatch(.rgba8_unorm, white);
    // Left: counter-clockwise with +y up. Right: clockwise.
    const triangles = [_]SpriteVertex{
        corner(-1, -1, 0, 1, blue),  corner(0, -1, 0, 1, blue),  corner(-1, 1, 0, 1, blue),
        corner(0.2, -1, 0, 1, blue), corner(0.2, 1, 0, 1, blue), corner(1, -1, 0, 1, blue),
    };
    const vertices = try canvas.vertices(&triangles);

    for ([_]struct { cull: pipeline.CullMode, right: [4]u8 }{
        .{ .cull = .none, .right = blue },
        .{ .cull = .back, .right = black },
    }) |case| {
        const pixels = try render(dev, .{
            .target = target,
            .render_pipeline = try canvas.pipelineWith(.{ .cull = case.cull }),
            .group = group,
            .vertices = vertices,
        });
        defer testing.allocator.free(pixels);
        // +y is up, so both triangles' interiors sit near the bottom row.
        try testing.expectEqual(blue, texelAt(pixels, 16, 1, 14));
        try testing.expectEqual(case.right, texelAt(pixels, 16, 14, 14));
    }
    try expectValidationHeard(dev);
}

test "a stored target is loaded by a later pass and sampled by another" {
    const dev = try validated(.{});
    defer dev.deinit();
    const canvas = try Canvas.init(dev);
    const source = try canvas.target(4, .rgba8_unorm);

    const cleared = try render(dev, .{ .target = source, .draw = false, .load = .{ .clear = .{ .color = .{ 1, 0, 0, 1 } } } });
    defer testing.allocator.free(cleared);
    try testing.expectEqual(red, texelAt(cleared, 4, 3, 3));
    const loaded = try render(dev, .{ .target = source, .draw = false, .load = .load });
    defer testing.allocator.free(loaded);
    try testing.expectEqualSlices(u8, cleared, loaded);

    const cb = try dev.beginCommandBuffer();
    try cb.textureBarrier(&.{.{ .texture = source, .from = .copy_dst, .to = .shader_read }});
    try finish(dev, cb);
    const everywhere = quad(-1, -1, 1, 1, white);
    const sampled = try render(dev, .{
        .target = try canvas.target(4, .rgba8_unorm),
        .render_pipeline = try canvas.pipelineWith(.{}),
        .group = try canvas.group(source),
        .vertices = try canvas.vertices(&everywhere),
    });
    defer testing.allocator.free(sampled);
    try testing.expectEqual(red, texelAt(sampled, 4, 2, 1));
    try expectValidationHeard(dev);
}

test "a drawing recording that is refused or discarded releases what it used, and nothing sooner" {
    const dev = try validated(.{});
    defer dev.deinit();
    const canvas = try Canvas.init(dev);

    for ([_]bool{ true, false }) |refused| {
        const target = try canvas.target(4, .rgba8_unorm);
        const render_pipeline = try canvas.pipelineWith(.{});
        const group = try canvas.swatch(.rgba8_unorm, white);
        const everywhere = quad(-1, -1, 1, 1, red);
        const vertices = try canvas.vertices(&everywhere);
        const halved = scaleMatrix(0.5, 0.5);

        const cb = try dev.beginCommandBuffer();
        const pass = try cb.beginRenderPass(.{
            .color = &.{.{ .texture = target, .initial_state = .copy_dst, .final_state = .copy_dst }},
        });
        pass.setPipeline(render_pipeline);
        pass.setBindGroup(0, group);
        pass.setVertexBuffer(0, vertices, 0);
        pass.setInlineConstants(&halved);
        pass.draw(.{ .vertex_count = 6 });
        pass.end();

        dev.destroyRenderPipeline(render_pipeline);
        dev.destroyBindGroup(group);
        dev.destroyBuffer(vertices);
        dev.destroyTexture(target);
        try testing.expect(dev.retiredCount() >= 4);

        if (refused) {
            dev.faults.submit = c.VK_ERROR_OUT_OF_DEVICE_MEMORY;
            try testing.expectError(error.OutOfMemory, cb.submit());
        } else {
            cb.discard();
        }
        try testing.expect(dev.retiredCount() >= 4);
        dev.waitIdle();
        try testing.expectEqual(@as(usize, 0), dev.retiredCount());
    }
    try expectValidationHeard(dev);
}

test "a pass that cannot be allocated leaves its recording discardable" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const dev = try Device.initWith(failing.allocator(), .{}, .{ .validation = .required });
    defer dev.deinit();

    const cb = try dev.beginCommandBuffer();
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, cb.beginRenderPass(.{}));
    failing.fail_index = std.math.maxInt(usize);
    cb.discard();
    dev.waitIdle();
    try testing.expectEqual(@as(u64, 0), dev.timeline.submitted);
}
