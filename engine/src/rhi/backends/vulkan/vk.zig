//! The Khronos C declarations the Vulkan backend is written against (ADR-0038).
//!
//! `VK_NO_PROTOTYPES`: no Vulkan function is linked. Every call goes through a table filled
//! from the system loader at runtime (`dispatch.zig`), so a machine without a Vulkan driver
//! starts, says so, and refuses the device, rather than failing to launch.
//!
//! Windows reaches its surface declarations through `vulkan.h`, which includes `windows.h` for
//! `HINSTANCE` and `HWND`. Linux names only the core, Wayland and Xlib headers, with Xlib's three
//! types declared opaquely (`xlib_opaque.h`), so no build needs system window-system headers. The
//! include paths are attached to `rhi` alone, and only by `-Drhi=vulkan` (`build.zig`).

const builtin = @import("builtin");

comptime {
    switch (builtin.os.tag) {
        .windows, .linux => {},
        else => @compileError("the Vulkan backend targets Windows and Linux (ADR-0033)"),
    }
}

pub const c = @cImport({
    // As in the SDL3 backend: MinGW's fortified wrappers, which an optimized Windows build
    // enables, do not survive Zig 0.16.0's translation, and a declaration needs none of them.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("VK_NO_PROTOTYPES", "1");
    if (builtin.os.tag == .windows) {
        @cDefine("WIN32_LEAN_AND_MEAN", "1");
        @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
        @cInclude("vulkan/vulkan.h");
    } else {
        @cInclude("vulkan/vulkan_core.h");
        @cInclude("vulkan/vulkan_wayland.h");
        @cInclude("xlib_opaque.h");
        @cInclude("vulkan/vulkan_xlib.h");
    }
});

comptime {
    // The headers `build.zig.zon` pins. A different set on the include path would still compile,
    // and then disagree with the tools and the target Step 1 qualified.
    if (c.VK_HEADER_VERSION != 357) @compileError("expected Vulkan-Headers 1.4.357");
}

/// A result's name for a log line. Covers what initialization, submission and waiting return.
pub fn resultName(result: c.VkResult) []const u8 {
    return switch (result) {
        c.VK_SUCCESS => "VK_SUCCESS",
        c.VK_NOT_READY => "VK_NOT_READY",
        c.VK_TIMEOUT => "VK_TIMEOUT",
        c.VK_INCOMPLETE => "VK_INCOMPLETE",
        c.VK_ERROR_OUT_OF_HOST_MEMORY => "VK_ERROR_OUT_OF_HOST_MEMORY",
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => "VK_ERROR_OUT_OF_DEVICE_MEMORY",
        c.VK_ERROR_INITIALIZATION_FAILED => "VK_ERROR_INITIALIZATION_FAILED",
        c.VK_ERROR_DEVICE_LOST => "VK_ERROR_DEVICE_LOST",
        c.VK_ERROR_LAYER_NOT_PRESENT => "VK_ERROR_LAYER_NOT_PRESENT",
        c.VK_ERROR_EXTENSION_NOT_PRESENT => "VK_ERROR_EXTENSION_NOT_PRESENT",
        c.VK_ERROR_FEATURE_NOT_PRESENT => "VK_ERROR_FEATURE_NOT_PRESENT",
        c.VK_ERROR_INCOMPATIBLE_DRIVER => "VK_ERROR_INCOMPATIBLE_DRIVER",
        c.VK_ERROR_TOO_MANY_OBJECTS => "VK_ERROR_TOO_MANY_OBJECTS",
        c.VK_ERROR_UNKNOWN => "VK_ERROR_UNKNOWN",
        c.VK_ERROR_SURFACE_LOST_KHR => "VK_ERROR_SURFACE_LOST_KHR",
        c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR",
        else => "an unlisted result",
    };
}
