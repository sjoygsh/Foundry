//! The Vulkan backend (ADR-0033, ADR-0037, ADR-0038), being brought up in M13.
//!
//! **What exists from Step 3:** the system loader and its dispatch tables, an instance with
//! validation that can be required, a surface for a native window, device selection, one logical
//! device with its one queue, and the submission timeline — enough to record, submit and wait for
//! empty work, and to tear all of it down. Resources, bindings, passes and presentation arrive in
//! Steps 4–7. Until Step 7 completes `interface.check`, only `zig build vulkan-test -Drhi=vulkan`
//! builds this file (`docs/design/vulkan.md` §11).
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
//! Design: `docs/design/vulkan.md` §§4, 5 and 7.

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

/// What a destroyed resource leaves behind until the recordings that could use it finish. The
/// staging buffer a repacked copy made is retired the same way, after that one recording.
const Retired = union(enum) {
    buffer: struct { native: c.VkBuffer, allocation: c.VkDeviceMemory },
    texture: struct { image: c.VkImage, view: c.VkImageView, allocation: c.VkDeviceMemory },
    sampler: c.VkSampler,

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
        return @as(usize, self.buffers.count()) + self.textures.count() + self.samplers.count();
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

    /// Releases everything this device created, newest first, then the device itself. Waits for
    /// nothing: `deinit` has already waited, and a device that failed to initialize submitted
    /// nothing. Destroying the pool frees every command buffer it allocated.
    fn teardown(self: *Device) void {
        const gpa = self.gpa;
        if (self.device != null) {
            // Only a device whose table loaded can have made a resource, so these loops are empty
            // on every path that could not call them.
            for (self.retired.entries.items) |entry| entry.backing.release(self);
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
        self.free_native.deinit(gpa);
        self.retired.deinit(gpa);
        self.buffers.deinit(gpa);
        self.textures.deinit(gpa);
        self.samplers.deinit(gpa);
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
