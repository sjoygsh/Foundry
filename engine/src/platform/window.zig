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
    /// `HWND` and `HINSTANCE` (Windows). `ptr` points at a `Win32Window`.
    win32_hwnd,
    /// Xlib `Display` and `Window` (Linux/X11). `ptr` points at an `XlibWindow`.
    xlib_window,
    /// `wl_display` and `wl_surface` (Linux/Wayland). `ptr` points at a `WaylandSurface`.
    wayland_surface,
    /// **A request, never a surface.** Whichever of `win32_hwnd`, `xlib_window` and
    /// `wayland_surface` the running window system provides — which on Linux is only known
    /// at runtime. A window opened with it reports the concrete kind it got; no
    /// `NativeSurfaceHandle` ever carries this one. Appended, so no existing value moved.
    native_window,
};

/// The OS handles behind a `win32_hwnd` surface. A graphics API needs the module instance
/// as well as the window, so both travel together. Opaque here: `platform` hands them on
/// and never calls Win32 with them.
pub const Win32Window = extern struct {
    hinstance: *anyopaque,
    hwnd: *anyopaque,
};

/// The OS handles behind an `xlib_window` surface. An X11 window ID means nothing without
/// the display connection it belongs to. The ID is an XID: an unsigned integer as wide as
/// a pointer on the supported targets.
pub const XlibWindow = extern struct {
    display: *anyopaque,
    window: usize,
};

/// The OS handles behind a `wayland_surface` surface: the surface and its display.
pub const WaylandSurface = extern struct {
    display: *anyopaque,
    surface: *anyopaque,
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
///
/// For `metal_layer`, `ptr` is the layer itself. For the three native window kinds it
/// points at a payload `platform` owns — `Win32Window`, `XlibWindow` or `WaylandSurface` —
/// whose address is stable until the window closes. A consumer copies the values it needs
/// when it takes the handle, and is destroyed before the window is (`vulkan.md` §4).
pub const NativeSurfaceHandle = extern struct {
    kind: SurfaceKind = .none,
    ptr: ?*anyopaque = null,

    pub const none: NativeSurfaceHandle = .{};

    pub fn isNone(self: NativeSurfaceHandle) bool {
        return self.kind == .none or self.ptr == null;
    }

    /// The Win32 handles, if this is a `win32_hwnd` surface.
    pub fn win32(self: NativeSurfaceHandle) ?*const Win32Window {
        if (self.kind != .win32_hwnd) return null;
        return @ptrCast(@alignCast(self.ptr orelse return null));
    }

    /// The Xlib handles, if this is an `xlib_window` surface.
    pub fn xlib(self: NativeSurfaceHandle) ?*const XlibWindow {
        if (self.kind != .xlib_window) return null;
        return @ptrCast(@alignCast(self.ptr orelse return null));
    }

    /// The Wayland handles, if this is a `wayland_surface` surface.
    pub fn wayland(self: NativeSurfaceHandle) ?*const WaylandSurface {
        if (self.kind != .wayland_surface) return null;
        return @ptrCast(@alignCast(self.ptr orelse return null));
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
    /// The surface the renderer will want from this window. `native_window` asks for
    /// whatever this machine's window system provides.
    surface: SurfaceKind = .none,
};

/// An icon for a window, supplied by the application (`vulkan.md` §9).
///
/// **8-bit RGBA, straight alpha, sRGB, rows top to bottom**: the layout Foundry's image decoders
/// produce, so a decoded image is handed over as it is. The engine supplies no default mark, reads
/// no icon file and decodes nothing here. The application owns its icon, decodes it wherever it
/// decodes images, and lends the bytes for one call; no backend keeps the pointer. Every field is
/// untrusted, because a package may have supplied the image, so `validate` refuses rather than
/// asserts.
pub const WindowIcon = struct {
    width: u32,
    height: u32,
    /// Bytes from the start of one row to the next: at least `width * 4`, and no more than a
    /// signed 32-bit pitch holds.
    stride: u32,
    /// At least `stride * (height - 1) + width * 4` bytes, borrowed for the call.
    pixels: []const u8,

    /// The largest side accepted. Window systems draw icons at 16 to 256 pixels and Windows' own
    /// icon format stops at 256, so a larger image only costs a copy on its way to being shrunk.
    pub const max_dimension: u32 = 256;
    pub const bytes_per_pixel: u32 = 4;

    /// Whether the fields describe an image of a size an icon may have, readable without leaving
    /// `pixels`.
    pub fn validate(self: WindowIcon) error{InvalidWindowIcon}!void {
        if (self.width == 0 or self.height == 0) return error.InvalidWindowIcon;
        if (self.width > max_dimension or self.height > max_dimension) return error.InvalidWindowIcon;
        const row: u64 = @as(u64, self.width) * bytes_per_pixel;
        if (self.stride < row or self.stride > std.math.maxInt(i32)) return error.InvalidWindowIcon;
        const needed: u64 = @as(u64, self.stride) * (self.height - 1) + row;
        if (self.pixels.len < needed) return error.InvalidWindowIcon;
    }
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

test "an icon is validated against its bound, its stride and its bytes" {
    var bytes: [8 * 3 * 4]u8 = @splat(0);
    const good: WindowIcon = .{ .width = 2, .height = 3, .stride = 8 * 4, .pixels = &bytes };
    try good.validate();
    // Exactly enough: the last row needs only its own pixels, not a whole stride.
    var tight = good;
    tight.pixels = bytes[0 .. 8 * 4 * 2 + 2 * 4];
    try tight.validate();

    var short = good;
    short.pixels = bytes[0 .. 8 * 4 * 2 + 2 * 4 - 1];
    try testing.expectError(error.InvalidWindowIcon, short.validate());
    var narrow = good;
    narrow.stride = 2 * 4 - 1;
    try testing.expectError(error.InvalidWindowIcon, narrow.validate());
    var empty = good;
    empty.width = 0;
    try testing.expectError(error.InvalidWindowIcon, empty.validate());
    empty = good;
    empty.height = 0;
    try testing.expectError(error.InvalidWindowIcon, empty.validate());
    var wide = good;
    wide.width = WindowIcon.max_dimension + 1;
    try testing.expectError(error.InvalidWindowIcon, wide.validate());
    var tall = good;
    tall.height = WindowIcon.max_dimension + 1;
    try testing.expectError(error.InvalidWindowIcon, tall.validate());
    // A stride no pitch can carry is refused even when one row would fit.
    var huge = good;
    huge.height = 1;
    huge.stride = @as(u32, std.math.maxInt(i32)) + 1;
    try testing.expectError(error.InvalidWindowIcon, huge.validate());

    // The largest icon, exactly.
    const side = WindowIcon.max_dimension;
    const big = try testing.allocator.alloc(u8, side * side * 4);
    defer testing.allocator.free(big);
    try (WindowIcon{ .width = side, .height = side, .stride = side * 4, .pixels = big }).validate();
}

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

test "surface kinds keep their values" {
    // The handle's layout is a compatibility decision, so a new kind is appended rather
    // than inserted: every value a compiled consumer already knows stays where it was.
    try testing.expectEqual(@as(u32, 1), @intFromEnum(SurfaceKind.metal_layer));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(SurfaceKind.win32_hwnd));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(SurfaceKind.xlib_window));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(SurfaceKind.wayland_surface));
    try testing.expectEqual(@as(u32, 5), @intFromEnum(SurfaceKind.native_window));
}

test "native payloads are two pointer-width fields" {
    try testing.expectEqual(2 * @sizeOf(usize), @sizeOf(Win32Window));
    try testing.expectEqual(2 * @sizeOf(usize), @sizeOf(XlibWindow));
    try testing.expectEqual(2 * @sizeOf(usize), @sizeOf(WaylandSurface));
}

test "a surface exposes only the payload its kind names" {
    var handles: Win32Window = .{ .hinstance = @ptrFromInt(0x1000), .hwnd = @ptrFromInt(0x2000) };
    const surface: NativeSurfaceHandle = .{ .kind = .win32_hwnd, .ptr = &handles };
    try testing.expectEqual(@as(usize, 0x2000), @intFromPtr(surface.win32().?.hwnd));
    try testing.expectEqual(@as(?*const XlibWindow, null), surface.xlib());
    try testing.expectEqual(@as(?*const WaylandSurface, null), surface.wayland());

    // A kind with no pointer behind it has no payload, whatever the tag claims.
    const empty: NativeSurfaceHandle = .{ .kind = .xlib_window, .ptr = null };
    try testing.expectEqual(@as(?*const XlibWindow, null), empty.xlib());
}

test "the request-only kind is never read as a surface" {
    var handles: WaylandSurface = .{ .display = @ptrFromInt(0x1000), .surface = @ptrFromInt(0x2000) };
    const surface: NativeSurfaceHandle = .{ .kind = .native_window, .ptr = &handles };
    try testing.expectEqual(@as(?*const Win32Window, null), surface.win32());
    try testing.expectEqual(@as(?*const XlibWindow, null), surface.xlib());
    try testing.expectEqual(@as(?*const WaylandSurface, null), surface.wayland());
}
