//! Presentation to real windows through the Vulkan backend (M13 Step 7, `docs/design/vulkan.md` §8).
//!
//! **Not part of `zig build test`.** A swapchain presents only in a desktop session, which the
//! headless bar does not have. `zig build vulkan-window-test -Drhi=vulkan` runs these, and `check`
//! compiles them. Validation is required throughout, so a validation error fails the test that
//! provoked it.
//!
//! They are white-box: §8's frame, image and submission identities are read from the backend's own
//! fields rather than through anything added to the RHI for a test (§10).

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const rhi = @import("rhi");

const testing = std.testing;
const Device = rhi.Device;

/// The backend's fault vocabulary, reached through the device's fields: none of it is RHI.
const PresentationFault = @typeInfo(@FieldType(@FieldType(Device, "faults"), "presentation")).optional.child;
const PresentationCall = @FieldType(PresentationFault, "call");
const PresentationResult = @FieldType(PresentationFault, "result");

/// `VkResult` values `Faults.submit` and `Faults.marker` take, without the Vulkan headers.
const vk_error_out_of_device_memory = -2;
const vk_error_device_lost = -4;

const gray = [4]f32{ 0.2, 0.2, 0.2, 1 };
const magenta = [4]f32{ 0.9, 0.1, 0.7, 1 };
const green = [4]f32{ 0.1, 0.8, 0.2, 1 };
const blue = [4]f32{ 0.1, 0.3, 0.9, 1 };

/// Minimise and restore, which `platform` does not offer, from the window system itself. Linux has
/// no one call for both window systems; Step 9 exercises it there by hand.
const user32 = struct {
    const sw_minimize = 6;
    const sw_restore = 9;
    extern "user32" fn ShowWindow(hwnd: *anyopaque, command: c_int) callconv(.winapi) c_int;
};

/// A real window, its native surface, and a validated device presenting to it.
const Fixture = struct {
    p: *platform.Platform,
    os: *platform.os.Os,
    window: platform.WindowHandle,
    surface: platform.NativeSurfaceHandle,
    dev: *Device,

    fn init(title: []const u8) !Fixture {
        const p = try platform.Platform.init(testing.allocator, .{});
        errdefer p.deinit();
        const os = try platform.os.Os.init(testing.allocator, .{ .app_name = "foundry-test" });
        errdefer os.deinit();
        const window = try p.openWindow(.{
            .title = title,
            .logical_width = 480,
            .logical_height = 320,
            .surface = .native_window,
        });
        errdefer p.closeWindow(window);
        p.pumpEvents();
        while (p.nextEvent()) |_| {}

        const surface = p.nativeSurface(window) orelse return error.TestUnexpectedResult;
        const size = (p.windowInfo(window) orelse return error.TestUnexpectedResult).pixel_size;
        const dev = try Device.initWith(testing.allocator, .{
            .surface = surface,
            .surface_size = .{ .width = size.width, .height = size.height },
        }, .{ .validation = .required });
        return .{ .p = p, .os = os, .window = window, .surface = surface, .dev = dev };
    }

    fn deinit(self: *Fixture) void {
        self.dev.deinit();
        self.p.closeWindow(self.window);
        self.os.deinit();
        self.p.deinit();
    }

    fn pump(self: *Fixture) void {
        self.p.pumpEvents();
        while (self.p.nextEvent()) |_| {}
    }

    fn pixelSize(self: *Fixture) rhi.Extent2D {
        const size = self.p.windowInfo(self.window).?.pixel_size;
        return .{ .width = size.width, .height = size.height };
    }

    /// Tells the device the window's size, as the engine does when the window reports a resize.
    fn resync(self: *Fixture) !void {
        try self.dev.resizeSurface(self.pixelSize());
    }

    fn setMinimized(self: *Fixture, minimized: bool) void {
        const hwnd = self.surface.win32().?.hwnd;
        _ = user32.ShowWindow(hwnd, if (minimized) user32.sw_minimize else user32.sw_restore);
        for (0..60) |_| {
            self.pump();
            if (self.p.windowInfo(self.window).?.minimized == minimized) return;
            self.os.sleep(.fromMillis(16));
        }
    }
};

/// Records one pass that clears the frame's image and leaves it ready to present.
fn drawClear(dev: *Device, frame: rhi.FrameContext, color: [4]f32) !void {
    const cb = try dev.beginCommandBuffer();
    const pass = try cb.beginRenderPass(.{ .color = &.{.{
        .texture = frame.surface_texture,
        .load = .{ .clear = .{ .color = color } },
        .initial_state = .undefined,
        .final_state = .present,
    }} });
    pass.end();
    try cb.submit();
}

/// Opens a frame, answering routine unavailability the way the engine does — skip it and try
/// again — at most `attempts` times.
fn openFrame(fx: *Fixture, attempts: u32) !rhi.FrameContext {
    for (0..attempts) |_| {
        fx.pump();
        return fx.dev.beginFrame() catch |err| switch (err) {
            error.SurfaceUnavailable => {
                fx.os.sleep(.fromMillis(16));
                continue;
            },
            else => return err,
        };
    }
    return error.TestUnexpectedResult;
}

/// One presented frame of `color`, skipping routine unavailability at most `attempts` times.
fn present(fx: *Fixture, color: [4]f32, attempts: u32) !rhi.FrameContext {
    for (0..attempts) |_| {
        const frame = try openFrame(fx, attempts);
        try drawClear(fx.dev, frame, color);
        fx.dev.endFrame() catch |err| switch (err) {
            // The frame closed and its presentation was skipped; the next one rebuilds.
            error.SurfaceUnavailable => continue,
            else => return err,
        };
        return frame;
    }
    return error.TestUnexpectedResult;
}

/// For a test about to latch an injected loss on a device whose queue is in fact still running:
/// a lost device waits for nothing at teardown, so nothing it releases may still be in use.
fn settle(dev: *Device) void {
    dev.waitIdle();
    _ = dev.device_fns.vkQueueWaitIdle(dev.queue);
}

fn expectValidationHeard(dev: *Device) !void {
    try testing.expectEqual(@as(u32, 0), dev.messages.errors.load(.monotonic));
    try testing.expect(dev.messages.infos.load(.monotonic) + dev.messages.warnings.load(.monotonic) > 0);
}

test "a real window clears and presents through its swapchain, frame after frame" {
    var fx = try Fixture.init("Foundry Vulkan presentation");
    defer fx.deinit();
    const dev = fx.dev;

    try testing.expect(dev.swapchain != null);
    try testing.expect(dev.swapchain_images.len >= 2);
    try testing.expect(dev.capabilities().surface_format.isSrgb());

    // One colour, held long enough to be seen and captured: process completion is not proof that
    // the window showed anything (§10).
    const start = fx.os.wallClockNanos();
    var presented: u32 = 0;
    var last_index: u64 = 0;
    while (fx.os.wallClockNanos() - start < 4 * std.time.ns_per_s or presented < 120) {
        const frame = try present(&fx, magenta, 60);
        try testing.expect(frame.index > last_index);
        try testing.expect(frame.slot < dev.desc.frames_in_flight);
        try testing.expect(frame.surface_texture.eql(dev.surface_texture));
        try testing.expect(dev.slot_markers[frame.slot] != 0);
        try testing.expect(dev.held == null and dev.acquired == null and !dev.acquire_pending);
        last_index = frame.index;
        presented += 1;
    }
    try expectValidationHeard(dev);
}

test "a frame that draws nothing holds its image, and the next frame that draws presents it" {
    var fx = try Fixture.init("Foundry Vulkan held image");
    defer fx.deinit();
    const dev = fx.dev;
    _ = try present(&fx, gray, 60);

    // Nothing used the image, so the marker consumes the acquire signal.
    const empty = try openFrame(&fx, 60);
    const image = dev.acquired.?;
    try testing.expect(dev.acquire_pending);
    try dev.endFrame();
    try testing.expectEqual(@as(?u32, image), dev.held);
    try testing.expect(!dev.acquire_pending);
    try testing.expect(dev.slot_markers[empty.slot] != 0);

    // Empty frames after it reuse the held image and acquire nothing.
    for (0..3) |_| {
        _ = try dev.beginFrame();
        try testing.expectEqual(@as(?u32, image), dev.acquired);
        try testing.expect(dev.held == null and !dev.acquire_pending);
        try dev.endFrame();
        try testing.expectEqual(@as(?u32, image), dev.held);
    }

    // A draw that never reached the queue has not rendered the image.
    {
        const frame = try dev.beginFrame();
        const cb = try dev.beginCommandBuffer();
        const pass = try cb.beginRenderPass(.{ .color = &.{.{
            .texture = frame.surface_texture,
            .initial_state = .undefined,
            .final_state = .present,
        }} });
        pass.end();
        cb.discard();
        try dev.endFrame();
        try testing.expectEqual(@as(?u32, image), dev.held);
    }

    // The next frame that draws presents the same image.
    {
        const frame = try dev.beginFrame();
        try testing.expectEqual(@as(?u32, image), dev.acquired);
        try drawClear(dev, frame, green);
        try testing.expect(dev.frame_drew);
        try dev.endFrame();
        try testing.expect(dev.held == null and dev.acquired == null);
    }

    // A barrier alone uses a newly acquired image without drawing into it: that submission
    // consumes the acquire signal, and the image is still held rather than presented undrawn.
    {
        const frame = try openFrame(&fx, 60);
        try testing.expect(dev.acquire_pending);
        const cb = try dev.beginCommandBuffer();
        try cb.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .undefined, .to = .present }});
        try cb.submit();
        try testing.expect(!dev.acquire_pending);
        try dev.endFrame();
        try testing.expect(dev.held != null);
    }

    // A rebuild discards a held image with its swapchain.
    const old = dev.swapchain;
    dev.rebuild_pending = true;
    _ = try present(&fx, green, 60);
    try testing.expect(dev.swapchain != old);
    try testing.expect(dev.held == null);
    try expectValidationHeard(dev);
}

test "resizing, suspending, minimising and restoring rebuild the swapchain between frames" {
    var fx = try Fixture.init("Foundry Vulkan resize");
    defer fx.deinit();
    const dev = fx.dev;
    _ = try present(&fx, gray, 60);

    for ([_]platform.Size{
        .{ .width = 640, .height = 400 },
        .{ .width = 320, .height = 240 },
        .{ .width = 720, .height = 200 },
        .{ .width = 200, .height = 520 },
        .{ .width = 480, .height = 320 },
    }) |logical| {
        try fx.p.setWindowSize(fx.window, logical);
        fx.pump();
        try fx.resync();
        for (0..10) |_| _ = try present(&fx, blue, 60);
        try testing.expect(!dev.rebuild_pending);
        try testing.expect(dev.textures.getConst(dev.surface_texture).?.desc.size.eql(fx.pixelSize()));
    }

    // A zero extent suspends the window: nothing opens and no frame index is spent.
    const index = dev.frame_index;
    try dev.resizeSurface(.{ .width = 0, .height = 0 });
    try testing.expectError(error.SurfaceUnavailable, dev.beginFrame());
    try testing.expectEqual(index, dev.frame_index);
    try fx.resync();
    _ = try present(&fx, green, 60);

    if (builtin.os.tag == .windows) {
        for (0..3) |_| {
            fx.setMinimized(true);
            // A minimised window has no extent. Its frames are skipped, never failed.
            var skipped: u32 = 0;
            for (0..20) |_| {
                fx.pump();
                const frame = dev.beginFrame() catch |err| switch (err) {
                    error.SurfaceUnavailable => {
                        skipped += 1;
                        fx.os.sleep(.fromMillis(16));
                        continue;
                    },
                    else => return err,
                };
                try drawClear(dev, frame, magenta);
                dev.endFrame() catch |err| switch (err) {
                    error.SurfaceUnavailable => skipped += 1,
                    else => return err,
                };
            }
            try testing.expect(skipped > 0);
            fx.setMinimized(false);
            try fx.resync();
            for (0..10) |_| _ = try present(&fx, blue, 60);
            try testing.expect(dev.textures.getConst(dev.surface_texture).?.desc.size.eql(fx.pixelSize()));
        }
    }
    try expectValidationHeard(dev);
}

test "an acquisition that fails transiently opens nothing, and the next frame presents" {
    var fx = try Fixture.init("Foundry Vulkan acquisition faults");
    defer fx.deinit();
    const dev = fx.dev;
    _ = try present(&fx, gray, 60);

    const Case = struct { result: PresentationResult, err: anyerror };
    for ([_]Case{
        .{ .result = .timeout, .err = error.SurfaceUnavailable },
        .{ .result = .out_of_date, .err = error.SurfaceUnavailable },
        .{ .result = .out_of_memory, .err = error.OutOfMemory },
    }) |case| {
        const index = dev.frame_index;
        const old = dev.swapchain;
        dev.faults.presentation = .{ .call = .acquire, .result = case.result };
        try testing.expectError(case.err, dev.beginFrame());
        try testing.expectEqual(index, dev.frame_index);
        try testing.expect(!dev.in_frame and dev.acquired == null and !dev.acquire_pending);
        try testing.expectEqual(case.result == .out_of_date, dev.rebuild_pending);
        _ = try present(&fx, green, 60);
        try testing.expectEqual(case.result == .out_of_date, dev.swapchain != old);
    }

    // Suboptimal still acquired an image: the frame finishes on it, keeping its acquire signal,
    // and the rebuild waits until the frame has closed.
    const old = dev.swapchain;
    dev.faults.presentation = .{ .call = .acquire, .result = .suboptimal };
    const frame = try dev.beginFrame();
    try testing.expect(dev.rebuild_pending and dev.acquire_pending and dev.swapchain == old);
    try drawClear(dev, frame, blue);
    try dev.endFrame();
    _ = try present(&fx, blue, 60);
    try testing.expect(dev.swapchain != old and !dev.rebuild_pending);
    try expectValidationHeard(dev);
}

test "a presentation that fails closes its frame with the marker, and a rebuild follows" {
    var fx = try Fixture.init("Foundry Vulkan presentation faults");
    defer fx.deinit();
    const dev = fx.dev;
    _ = try present(&fx, gray, 60);

    const Case = struct { result: PresentationResult, err: ?anyerror };
    for ([_]Case{
        .{ .result = .suboptimal, .err = null },
        .{ .result = .out_of_date, .err = error.SurfaceUnavailable },
        .{ .result = .out_of_memory, .err = error.OutOfMemory },
    }) |case| {
        const frame = try openFrame(&fx, 60);
        try drawClear(dev, frame, magenta);
        const submitted = dev.timeline.submitted;
        dev.faults.presentation = .{ .call = .present, .result = case.result };
        if (case.err) |err| try testing.expectError(err, dev.endFrame()) else try dev.endFrame();
        try testing.expect(!dev.in_frame and dev.acquired == null and dev.held == null);
        try testing.expect(dev.slot_markers[frame.slot] > submitted);
        try testing.expect(dev.rebuild_pending);

        const old = dev.swapchain;
        _ = try present(&fx, green, 60);
        try testing.expect(dev.swapchain != old);
    }
    try expectValidationHeard(dev);
}

test "a draw the queue refuses leaves the acquire signal to the marker, and nothing undrawn is presented" {
    var fx = try Fixture.init("Foundry Vulkan submission faults");
    defer fx.deinit();
    const dev = fx.dev;
    _ = try present(&fx, gray, 60);

    const frame = try openFrame(&fx, 60);
    try testing.expect(dev.acquire_pending);
    dev.faults.submit = vk_error_out_of_device_memory;
    try testing.expectError(error.OutOfMemory, drawClear(dev, frame, magenta));
    try testing.expect(dev.acquire_pending and !dev.frame_drew);
    try dev.endFrame();
    try testing.expect(dev.held != null and !dev.acquire_pending);
    try testing.expect(dev.slot_markers[frame.slot] != 0);

    _ = try present(&fx, green, 60);
    try testing.expect(dev.held == null);
    try expectValidationHeard(dev);
}

test "a swapchain that cannot be rebuilt leaves none, and the next frame builds one" {
    var fx = try Fixture.init("Foundry Vulkan rebuild faults");
    defer fx.deinit();
    const dev = fx.dev;
    _ = try present(&fx, gray, 60);

    dev.rebuild_pending = true;
    dev.faults.presentation = .{ .call = .create_swapchain, .result = .out_of_memory };
    try testing.expectError(error.OutOfMemory, dev.beginFrame());
    try testing.expect(dev.swapchain == null and dev.swapchain_images.len == 0);
    try testing.expect(dev.rebuild_pending and !dev.in_frame);

    _ = try present(&fx, green, 60);
    try testing.expect(dev.swapchain != null and !dev.rebuild_pending);
    try expectValidationHeard(dev);
}

test "surface loss and device loss are sticky wherever presentation meets them, and still tear down" {
    const Case = struct { call: PresentationCall, result: PresentationResult, err: anyerror };
    for ([_]Case{
        .{ .call = .acquire, .result = .surface_lost, .err = error.SurfaceLost },
        .{ .call = .acquire, .result = .device_lost, .err = error.DeviceLost },
        .{ .call = .present, .result = .surface_lost, .err = error.SurfaceLost },
        .{ .call = .present, .result = .device_lost, .err = error.DeviceLost },
        .{ .call = .create_swapchain, .result = .surface_lost, .err = error.SurfaceLost },
        .{ .call = .create_swapchain, .result = .device_lost, .err = error.DeviceLost },
    }) |case| {
        var fx = try Fixture.init("Foundry Vulkan fatal presentation");
        defer fx.deinit();
        const dev = fx.dev;
        _ = try present(&fx, gray, 60);
        settle(dev);

        dev.faults.presentation = .{ .call = case.call, .result = case.result };
        switch (case.call) {
            .acquire => try testing.expectError(case.err, dev.beginFrame()),
            .create_swapchain => {
                dev.rebuild_pending = true;
                try testing.expectError(case.err, dev.beginFrame());
            },
            .present => {
                const frame = try openFrame(&fx, 60);
                try drawClear(dev, frame, magenta);
                try testing.expectError(case.err, dev.endFrame());
                try testing.expect(dev.slot_markers[frame.slot] != 0);
                // The presentation really happened; only its result was replaced.
                settle(dev);
            },
        }
        try testing.expect(!dev.in_frame);
        try testing.expectError(case.err, dev.beginFrame());
        try testing.expectError(case.err, dev.resizeSurface(.{ .width = 64, .height = 64 }));
        try testing.expectEqual(@as(u32, 0), dev.messages.errors.load(.monotonic));
    }
}

test "a frame that cannot leave its marker latches the device as failed" {
    var fx = try Fixture.init("Foundry Vulkan marker fault");
    defer fx.deinit();
    const dev = fx.dev;
    _ = try present(&fx, gray, 60);

    const frame = try openFrame(&fx, 60);
    try drawClear(dev, frame, magenta);
    settle(dev);
    dev.faults.marker = vk_error_out_of_device_memory;
    try testing.expectError(error.OutOfMemory, dev.endFrame());
    try testing.expect(dev.lost and !dev.in_frame);
    // Synchronization that frame promised was never signalled, so nothing waits on it again.
    try testing.expectError(error.DeviceLost, dev.beginFrame());
    try testing.expectEqual(@as(u32, 0), dev.messages.errors.load(.monotonic));

    // And a submission lost with the device: the frame still closes, and loss is what it reports.
    var other = try Fixture.init("Foundry Vulkan submission loss");
    defer other.deinit();
    _ = try present(&other, gray, 60);
    const next = try openFrame(&other, 60);
    settle(other.dev);
    other.dev.faults.submit = vk_error_device_lost;
    try testing.expectError(error.DeviceLost, drawClear(other.dev, next, magenta));
    try testing.expectError(error.DeviceLost, other.dev.endFrame());
    try testing.expect(!other.dev.in_frame);
    try testing.expectEqual(@as(u32, 0), other.dev.messages.errors.load(.monotonic));
}

test "a device torn down with a frame open or an image held releases everything" {
    {
        var fx = try Fixture.init("Foundry Vulkan teardown in a frame");
        defer fx.deinit();
        _ = try present(&fx, gray, 60);
        const frame = try openFrame(&fx, 60);
        try drawClear(fx.dev, frame, magenta);
        try testing.expect(fx.dev.in_frame);
    }
    {
        var fx = try Fixture.init("Foundry Vulkan teardown holding an image");
        defer fx.deinit();
        _ = try present(&fx, gray, 60);
        _ = try openFrame(&fx, 60);
        try fx.dev.endFrame();
        try testing.expect(fx.dev.held != null);
    }
}
