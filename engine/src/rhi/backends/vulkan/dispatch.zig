//! Tables of Vulkan functions, filled from the system loader at runtime (ADR-0038).
//!
//! Vulkan resolves a function at the scope that owns it: global functions before an instance
//! exists, instance and physical-device functions from the instance, device functions from the
//! device, and an extension's functions only once that extension is enabled. Each table here is
//! one such set, and a field's name is the function it holds, so `load` needs no second list that
//! could disagree with the first. A function the loader does not provide is an initialization
//! failure naming it, never a null pointer called later.
//!
//! No Volk and no generated binding: the backend needs a few dozen functions, and the headers
//! already declare their exact types.

const builtin = @import("builtin");
const core = @import("core");

const c = @import("vk.zig").c;

const log = core.log.scoped(.rhi);

/// The system loader's file name, opened from the system location only (ADR-0038,
/// `platform.os.Library.openSystem`).
pub const loader_name = switch (builtin.os.tag) {
    .windows => "vulkan-1.dll",
    else => "libvulkan.so.1",
};

/// The function pointer type behind a header's optional `PFN_` typedef.
pub fn Fn(comptime Pfn: type) type {
    return @typeInfo(Pfn).optional.child;
}

pub const GetInstanceProcAddr = Fn(c.PFN_vkGetInstanceProcAddr);

/// Callable before an instance exists.
pub const Global = struct {
    vkEnumerateInstanceVersion: Fn(c.PFN_vkEnumerateInstanceVersion),
    vkEnumerateInstanceLayerProperties: Fn(c.PFN_vkEnumerateInstanceLayerProperties),
    vkEnumerateInstanceExtensionProperties: Fn(c.PFN_vkEnumerateInstanceExtensionProperties),
    vkCreateInstance: Fn(c.PFN_vkCreateInstance),
};

/// Core instance and physical-device functions. `vkDestroyDevice` is taken from the instance
/// as well, so a device whose own table failed to load can still be destroyed.
pub const Instance = struct {
    vkEnumeratePhysicalDevices: Fn(c.PFN_vkEnumeratePhysicalDevices),
    vkGetPhysicalDeviceProperties: Fn(c.PFN_vkGetPhysicalDeviceProperties),
    vkGetPhysicalDeviceFeatures2: Fn(c.PFN_vkGetPhysicalDeviceFeatures2),
    vkGetPhysicalDeviceQueueFamilyProperties: Fn(c.PFN_vkGetPhysicalDeviceQueueFamilyProperties),
    vkEnumerateDeviceExtensionProperties: Fn(c.PFN_vkEnumerateDeviceExtensionProperties),
    vkCreateDevice: Fn(c.PFN_vkCreateDevice),
    vkGetDeviceProcAddr: Fn(c.PFN_vkGetDeviceProcAddr),
    vkDestroyDevice: Fn(c.PFN_vkDestroyDevice),
};

/// `VK_EXT_debug_utils`, when validation is required.
pub const DebugUtils = struct {
    vkCreateDebugUtilsMessengerEXT: Fn(c.PFN_vkCreateDebugUtilsMessengerEXT),
    vkDestroyDebugUtilsMessengerEXT: Fn(c.PFN_vkDestroyDebugUtilsMessengerEXT),
};

/// `VK_KHR_surface`, when the device is created for a window.
pub const Surface = struct {
    vkDestroySurfaceKHR: Fn(c.PFN_vkDestroySurfaceKHR),
    vkGetPhysicalDeviceSurfaceSupportKHR: Fn(c.PFN_vkGetPhysicalDeviceSurfaceSupportKHR),
};

pub const Win32Surface = if (builtin.os.tag == .windows) struct {
    vkCreateWin32SurfaceKHR: Fn(c.PFN_vkCreateWin32SurfaceKHR),
} else struct {};

pub const XlibSurface = if (builtin.os.tag == .linux) struct {
    vkCreateXlibSurfaceKHR: Fn(c.PFN_vkCreateXlibSurfaceKHR),
} else struct {};

pub const WaylandSurface = if (builtin.os.tag == .linux) struct {
    vkCreateWaylandSurfaceKHR: Fn(c.PFN_vkCreateWaylandSurfaceKHR),
} else struct {};

/// Device functions, resolved from the device itself so calls skip the loader's trampolines.
pub const Device = struct {
    vkGetDeviceQueue: Fn(c.PFN_vkGetDeviceQueue),
    vkDeviceWaitIdle: Fn(c.PFN_vkDeviceWaitIdle),
    vkCreateSemaphore: Fn(c.PFN_vkCreateSemaphore),
    vkDestroySemaphore: Fn(c.PFN_vkDestroySemaphore),
    vkWaitSemaphores: Fn(c.PFN_vkWaitSemaphores),
    vkGetSemaphoreCounterValue: Fn(c.PFN_vkGetSemaphoreCounterValue),
    vkCreateCommandPool: Fn(c.PFN_vkCreateCommandPool),
    vkDestroyCommandPool: Fn(c.PFN_vkDestroyCommandPool),
    vkAllocateCommandBuffers: Fn(c.PFN_vkAllocateCommandBuffers),
    vkBeginCommandBuffer: Fn(c.PFN_vkBeginCommandBuffer),
    vkEndCommandBuffer: Fn(c.PFN_vkEndCommandBuffer),
    vkResetCommandBuffer: Fn(c.PFN_vkResetCommandBuffer),
    vkQueueSubmit2: Fn(c.PFN_vkQueueSubmit2),
};

pub const LoadError = error{MissingFunction};

/// Fills every field of `Table` by name through `get` — `vkGetInstanceProcAddr` or
/// `vkGetDeviceProcAddr` — for `handle`.
pub fn load(comptime Table: type, get: anytype, handle: anytype) LoadError!Table {
    var table: Table = undefined;
    inline for (@typeInfo(Table).@"struct".fields) |field| {
        const raw = get(handle, field.name.ptr) orelse {
            log.warn("vulkan: the loader provides no '{s}'", .{field.name});
            return error.MissingFunction;
        };
        @field(table, field.name) = @ptrCast(raw);
    }
    return table;
}

/// One function by name, or null when the loader does not provide it.
pub fn lookup(comptime Pfn: type, get: anytype, handle: anytype, name: [:0]const u8) ?Fn(Pfn) {
    const raw = get(handle, name.ptr) orelse return null;
    return @ptrCast(raw);
}
