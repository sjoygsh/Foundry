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

const interface = @import("../../interface.zig");
const lifetime = @import("../../lifetime.zig");
const dispatch = @import("dispatch.zig");
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
};

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

    /// Returns every finished submission's command buffer to the free list.
    fn collect(self: *Device) void {
        while (self.timeline.popCompleted()) |submission| self.free_native.appendAssumeCapacity(submission.token);
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
