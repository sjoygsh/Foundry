//! Real native windows through the selected platform backend, on this machine's own window
//! system (M13 Step 2, `docs/design/vulkan.md` §4).
//!
//! **Not part of `zig build test`.** These tests open real windows, so they need a desktop
//! session, which the headless bar does not have. `zig build native-window-test` runs them,
//! and `check` compiles them so they cannot rot between the runs that need them. On macOS
//! only the refusal applies: Metal is macOS's backend, and no native window kind is offered.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");

const testing = std.testing;
const Platform = platform.Platform;
const SurfaceKind = platform.SurfaceKind;

/// Whether this OS has a window system that provides a native window kind.
const has_native_window = switch (builtin.os.tag) {
    .windows, .linux => true,
    else => false,
};

const native_kinds = [_]SurfaceKind{ .win32_hwnd, .xlib_window, .wayland_surface };

fn openNative(p: *Platform) platform.WindowError!platform.WindowHandle {
    return p.openWindow(.{
        .title = "Foundry native window test",
        .logical_width = 320,
        .logical_height = 240,
        .surface = .native_window,
    });
}

/// A surface's payload values, copied out so a later reading can be compared with them.
const Payload = union(enum) {
    win32: platform.Win32Window,
    xlib: platform.XlibWindow,
    wayland: platform.WaylandSurface,

    fn of(surface: platform.NativeSurfaceHandle) ?Payload {
        return switch (surface.kind) {
            .win32_hwnd => .{ .win32 = (surface.win32() orelse return null).* },
            .xlib_window => .{ .xlib = (surface.xlib() orelse return null).* },
            .wayland_surface => .{ .wayland = (surface.wayland() orelse return null).* },
            else => null,
        };
    }
};

test "an automatic request comes back as this window system's concrete kind" {
    if (!has_native_window) return error.SkipZigTest;
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();

    const w = try openNative(p);
    const surface = p.nativeSurface(w) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOfScalar(SurfaceKind, &native_kinds, surface.kind) != null);
    if (builtin.os.tag == .windows) try testing.expectEqual(SurfaceKind.win32_hwnd, surface.kind);

    const payload = Payload.of(surface) orelse return error.TestUnexpectedResult;
    if (payload == .xlib) try testing.expect(payload.xlib.window != 0);
}

test "an explicit request must name the kind the window system provides" {
    if (!has_native_window) return error.SkipZigTest;
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();

    const probe = try openNative(p);
    const provided = p.nativeSurface(probe).?.kind;
    p.closeWindow(probe);

    const w = try p.openWindow(.{ .logical_width = 320, .logical_height = 240, .surface = provided });
    try testing.expectEqual(provided, p.nativeSurface(w).?.kind);

    for (native_kinds) |kind| {
        if (kind == provided) continue;
        try testing.expectError(error.SurfaceUnavailable, p.openWindow(.{ .surface = kind }));
    }
    try testing.expectError(error.SurfaceUnavailable, p.openWindow(.{ .surface = .metal_layer }));
}

test "a payload keeps its address while the window pool grows, and dies with its window" {
    if (!has_native_window) return error.SkipZigTest;
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();

    const first = try openNative(p);
    const before = p.nativeSurface(first).?;
    const values = Payload.of(before).?;

    // Enough windows that the pool's storage is reallocated more than once.
    var others: [8]platform.WindowHandle = undefined;
    for (&others) |*handle| handle.* = try openNative(p);

    const after = p.nativeSurface(first).?;
    try testing.expectEqual(before.ptr, after.ptr);
    try testing.expect(std.meta.eql(values, Payload.of(after).?));

    p.closeWindow(first);
    try testing.expectEqual(@as(?platform.NativeSurfaceHandle, null), p.nativeSurface(first));
    for (others) |handle| p.closeWindow(handle);
}

test "a resize arrives as an event and leaves the payload alone" {
    if (!has_native_window) return error.SkipZigTest;
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();

    const w = try openNative(p);
    const before = p.nativeSurface(w).?;
    const values = Payload.of(before).?;

    const wanted: platform.Size = .{ .width = 400, .height = 300 };
    try p.setWindowSize(w, wanted);

    // Bounded: a window manager that never answers fails the test instead of hanging it.
    const deadline = p.now().ns + 3 * std.time.ns_per_s;
    var resized = false;
    while (!resized and p.now().ns < deadline) {
        p.pumpEvents();
        while (p.nextEvent()) |ev| switch (ev) {
            .window_resized => |r| {
                if (r.window.eql(w) and r.logical_size.eql(wanted)) resized = true;
            },
            else => {},
        };
    }
    try testing.expect(resized);

    const after = p.nativeSurface(w).?;
    try testing.expectEqual(before.ptr, after.ptr);
    try testing.expect(std.meta.eql(values, Payload.of(after).?));
}

/// Win32 calls that read an icon back out of a window, so a test can see what the window
/// system was given rather than only that nothing failed.
const icon_readback = struct {
    const wm_geticon: u32 = 0x007f;
    const icon_small: usize = 0;
    const icon_big: usize = 1;
    const dib_rgb_colors: u32 = 0;

    const IconInfo = extern struct {
        is_icon: i32,
        hotspot_x: u32,
        hotspot_y: u32,
        mask: ?*anyopaque,
        color: ?*anyopaque,
    };
    const Bitmap = extern struct {
        kind: i32,
        width: i32,
        height: i32,
        width_bytes: i32,
        planes: u16,
        bits_per_pixel: u16,
        bits: ?*anyopaque,
    };
    const BitmapInfo = extern struct {
        size: u32 = @sizeOf(BitmapInfo) - 4,
        width: i32,
        height: i32,
        planes: u16 = 1,
        bit_count: u16 = 32,
        compression: u32 = 0,
        size_image: u32 = 0,
        x_per_meter: i32 = 0,
        y_per_meter: i32 = 0,
        colors_used: u32 = 0,
        colors_important: u32 = 0,
        colors: [1]u32 = .{0},
    };

    extern "user32" fn SendMessageW(hwnd: *anyopaque, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize;
    extern "user32" fn GetIconInfo(icon: *anyopaque, info: *IconInfo) callconv(.winapi) i32;
    extern "user32" fn GetDC(hwnd: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "user32" fn ReleaseDC(hwnd: ?*anyopaque, dc: *anyopaque) callconv(.winapi) i32;
    extern "gdi32" fn GetObjectW(object: *anyopaque, size: i32, out: *anyopaque) callconv(.winapi) i32;
    extern "gdi32" fn GetDIBits(dc: *anyopaque, bitmap: *anyopaque, start: u32, lines: u32, bits: ?*anyopaque, info: *BitmapInfo, usage: u32) callconv(.winapi) i32;
    extern "gdi32" fn DeleteObject(object: *anyopaque) callconv(.winapi) i32;

    /// The window's icon of one size, as top-down BGRA rows, and its side.
    fn read(gpa: std.mem.Allocator, hwnd: *anyopaque, which: usize) !struct { side: u32, bgra: []u8 } {
        const raw = SendMessageW(hwnd, wm_geticon, which, 0);
        if (raw == 0) return error.NoIcon;
        var info: IconInfo = undefined;
        if (GetIconInfo(@ptrFromInt(@as(usize, @bitCast(raw))), &info) == 0) return error.NoIconInfo;
        defer if (info.mask) |m| {
            _ = DeleteObject(m);
        };
        const color = info.color orelse return error.MonochromeIcon;
        defer _ = DeleteObject(color);

        var bitmap: Bitmap = undefined;
        if (GetObjectW(color, @sizeOf(Bitmap), &bitmap) == 0) return error.NoBitmap;
        if (bitmap.width <= 0 or bitmap.width != bitmap.height) return error.UnexpectedIconShape;
        const side: u32 = @intCast(bitmap.width);

        const bgra = try gpa.alloc(u8, @as(usize, side) * side * 4);
        errdefer gpa.free(bgra);
        const dc = GetDC(null) orelse return error.NoDeviceContext;
        defer _ = ReleaseDC(null, dc);
        // A negative height asks for rows top to bottom.
        var request: BitmapInfo = .{ .width = bitmap.width, .height = -bitmap.height };
        if (GetDIBits(dc, color, 0, side, bgra.ptr, &request, dib_rgb_colors) != bitmap.height) return error.NoBits;
        return .{ .side = side, .bgra = bgra };
    }
};

test "an application's icon reaches the window with its channels in order, borrowed only for the call" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const w = try p.openWindow(.{ .title = "Foundry icon test", .logical_width = 320, .logical_height = 240 });

    // Red on the left, blue on the right: a swapped red and blue would show, and so would a
    // mirrored or transposed copy.
    const side = 32;
    const pixels = try testing.allocator.alloc(u8, side * side * 4);
    for (0..side) |y| for (0..side) |x| {
        const texel = pixels[(y * side + x) * 4 ..][0..4];
        texel.* = if (x < side / 2) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 };
    };
    try p.setWindowIcon(w, .{ .width = side, .height = side, .stride = side * 4, .pixels = pixels });
    // Gone before anything reads the icon back, so the window system cannot be reading it.
    testing.allocator.free(pixels);

    // Refused before the window system is asked: bad bytes, then a closed window.
    var few: [15]u8 = @splat(0);
    try testing.expectError(error.InvalidWindowIcon, p.setWindowIcon(w, .{ .width = 2, .height = 2, .stride = 8, .pixels = &few }));

    p.closeWindow(w);
    try testing.expectError(error.InvalidWindow, p.setWindowIcon(w, .{ .width = 1, .height = 1, .stride = 4, .pixels = &few }));
}

test "on Windows the icon a window wears is the one the application supplied" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const w = try openNative(p);
    const hwnd = p.nativeSurface(w).?.win32().?.hwnd;

    const side = 32;
    var pixels: [side * side * 4]u8 = undefined;
    for (0..side) |y| for (0..side) |x| {
        const texel = pixels[(y * side + x) * 4 ..][0..4];
        texel.* = if (x < side / 2) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 };
    };
    try p.setWindowIcon(w, .{ .width = side, .height = side, .stride = side * 4, .pixels = &pixels });
    @memset(&pixels, 0);

    // Both sizes the window system asks for, each scaled to its own metric by Windows, so the
    // probes sit a quarter in from each side rather than at fixed texels.
    for ([_]usize{ icon_readback.icon_small, icon_readback.icon_big }) |which| {
        const icon = try icon_readback.read(testing.allocator, hwnd, which);
        defer testing.allocator.free(icon.bgra);
        const row = icon.side / 2;
        const left = icon.bgra[(row * icon.side + icon.side / 4) * 4 ..][0..4];
        const right = icon.bgra[(row * icon.side + icon.side * 3 / 4) * 4 ..][0..4];
        try testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, left[0..3]);
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, right[0..3]);
    }
}

test "running out of memory while opening a native window releases everything" {
    if (!has_native_window) return error.SkipZigTest;
    // Fail each allocation in turn, including the payload's, which comes after the OS window
    // already exists. The testing allocator underneath reports anything left behind.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        const p = Platform.init(failing.allocator(), .{}) catch |err| {
            try testing.expect(err == error.OutOfMemory);
            continue;
        };
        defer p.deinit();

        const w = openNative(p) catch |err| {
            try testing.expect(err == error.OutOfMemory);
            continue;
        };
        try testing.expect(p.nativeSurface(w) != null);
        break;
    }
    // The platform, the title, the payload and the pool slot were each refused once.
    try testing.expect(fail_index >= 4);
}

test "a window system without a native window kind refuses every native request" {
    if (has_native_window) return error.SkipZigTest;
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();

    for ([_]SurfaceKind{ .native_window, .win32_hwnd, .xlib_window, .wayland_surface }) |kind| {
        try testing.expectError(error.SurfaceUnavailable, p.openWindow(.{ .surface = kind }));
    }
}

test "the system Vulkan loader opens by name from the system location" {
    const name = switch (builtin.os.tag) {
        .windows => "vulkan-1.dll",
        .linux => "libvulkan.so.1",
        else => return error.SkipZigTest,
    };
    var lib = try platform.os.Library.openSystem(testing.allocator, name);
    defer lib.close();
    try testing.expect(lib.symbol(*const fn () callconv(.c) void, "vkGetInstanceProcAddr") != null);
}
