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
