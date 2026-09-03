//! Windows, their two different sizes, and the native surface seam.
//!
//! Design: `docs/design/platform-interface.md` §3.

const std = @import("std");
const core = @import("core");

/// Phantom tag for `WindowHandle`. Never instantiated; it exists so a window handle
/// cannot be confused with any other handle type (I1).
pub const Window = opaque {};

/// Windows are addressed by generational handle, not by pointer (I1). A closed
/// window's handle resolves to nothing rather than to whatever was reallocated in its
/// place, and multiple windows need no interface change to support (§11).
pub const WindowHandle = core.Handle(Window);

/// A size in whichever unit the field name says. There is deliberately no bare
/// `Size` field anywhere in this interface.
pub const Size = extern struct {
    width: u32 = 0,
    height: u32 = 0,

    pub fn eql(a: Size, b: Size) bool {
        return a.width == b.width and a.height == b.height;
    }

    pub fn isEmpty(s: Size) bool {
        return s.width == 0 or s.height == 0;
    }
};

/// What kind of native surface a window should be able to provide.
///
/// Requested at creation because it changes how the window is created — a Metal
/// window is not a window that later grows a `CAMetalLayer`.
pub const SurfaceKind = enum(u32) {
    /// No GPU surface. Headless, or a window used only for input.
    none = 0,
    /// `CAMetalLayer` (macOS, iOS).
    metal_layer,
    /// `HWND` (Windows).
    win32_hwnd,
    /// Xlib `Window` (Linux/X11).
    xlib_window,
    /// `wl_surface` (Linux/Wayland).
    wayland_surface,
};

/// The one thing `platform` hands to `rhi`, and the only place the two meet.
///
/// Opaque and tagged: `platform` does not know what Metal is, and `rhi` does not know
/// what SDL is. `rhi` switches on `kind` and interprets `ptr` per backend. An `rhi`
/// backend that meets a `kind` it does not handle returns an error — that combination
/// is a configuration mistake, not a programmer error, so it is not asserted
/// (ADR-0002, ADR-0007).
///
/// `extern` because this eventually crosses the C ABI into the Metal shim (ADR-0012),
/// so its layout is a compatibility decision rather than an implementation detail.
pub const NativeSurfaceHandle = extern struct {
    kind: SurfaceKind = .none,
    ptr: ?*anyopaque = null,

    pub const none: NativeSurfaceHandle = .{};

    pub fn isNone(self: NativeSurfaceHandle) bool {
        return self.kind == .none or self.ptr == null;
    }
};

/// How to create a window. Sizes here are **logical**: a 1280x720 request is 1280x720
/// points, which is 2560x1440 device pixels on a 2x display.
pub const WindowConfig = struct {
    title: []const u8 = "Foundry",
    logical_width: u32 = 1280,
    logical_height: u32 = 720,
    resizable: bool = true,
    /// Whether the window should use the display's full pixel density. Off means the
    /// OS upscales a lower-resolution surface, which is occasionally wanted for
    /// performance and never wanted by default.
    high_dpi: bool = true,
    /// The surface the renderer will want from this window.
    surface: SurfaceKind = .none,
};

/// The current state of a window.
///
/// **`logical_size` and `pixel_size` are different numbers and neither is "the size".**
/// Logical drives UI layout and input coordinates; pixel drives the swapchain and
/// viewport. They differ by the display's scale factor, and they change independently
/// when a window moves between monitors of different densities. Conflating them is the
/// "everything is half-size on my laptop but fine on my monitor" bug, and it is far
/// cheaper to avoid here than to unpick once a renderer depends on it.
pub const WindowInfo = struct {
    logical_size: Size,
    pixel_size: Size,
    /// `pixel_size / logical_size`. Provided because callers converting a single
    /// coordinate should not have to divide two sizes and hope neither is zero.
    scale: f32,
    focused: bool,
    minimized: bool,
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "a zeroed window handle is none" {
    const h: WindowHandle = std.mem.zeroes(WindowHandle);
    try testing.expect(h.isNone());
    try testing.expect(WindowHandle.none.isNone());
}

test "a zeroed native surface handle is none" {
    const s: NativeSurfaceHandle = std.mem.zeroes(NativeSurfaceHandle);
    try testing.expect(s.isNone());
    // A tagged handle with a null pointer is still nothing, whatever the tag claims.
    try testing.expect((NativeSurfaceHandle{ .kind = .metal_layer, .ptr = null }).isNone());
}

test "surface kind none is zero" {
    // So that a zeroed NativeSurfaceHandle is `none` by construction rather than by
    // convention, matching how core's handles work.
    try testing.expectEqual(@as(u32, 0), @intFromEnum(SurfaceKind.none));
}

test "size comparison" {
    try testing.expect((Size{ .width = 1280, .height = 720 }).eql(.{ .width = 1280, .height = 720 }));
    try testing.expect(!(Size{ .width = 1280, .height = 720 }).eql(.{ .width = 1280, .height = 721 }));
    try testing.expect((Size{ .width = 0, .height = 720 }).isEmpty());
}
