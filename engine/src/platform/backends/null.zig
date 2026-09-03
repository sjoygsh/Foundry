//! The headless platform backend: no window, no real input, a synthetic clock.
//!
//! It exists for two reasons, and the second is the important one.
//!
//! 1. **It makes `app` testable.** The fixed-timestep loop, subsystem ordering and
//!    clean shutdown can be exercised with no display server — in CI, over SSH, and on
//!    a build machine that has never had a GPU.
//! 2. **It makes the interface honest.** A second implementation is what turns a set
//!    of functions into an interface. Every change to the interface must satisfy this
//!    file too, so a signature that only makes sense for SDL cannot quietly become the
//!    interface. That is the same reasoning that earns the null RHI backend its place
//!    (ADR-0003).
//!
//! Its clock advances by an exact amount per reading, so a loop test measures the
//! logic rather than how fast the test machine happens to be. Its event queue is
//! scriptable, which is the seed of replay testing later — a direct payoff of the
//! snapshot design in `input.zig`.
//!
//! The functions below `-- test affordances --` are **not** part of the backend
//! interface. They are how a test plays the part of the operating system, and no
//! engine code above `platform` may use them.
//!
//! Design: `docs/design/platform-interface.md` §9.

const std = @import("std");
const core = @import("core");

const event = @import("../event.zig");
const input = @import("../input.zig");
const interface = @import("../interface.zig");
const win = @import("../window.zig");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.platform);

const WindowState = struct {
    logical_size: win.Size,
    scale: f32,
    focused: bool,
    minimized: bool,

    fn pixelSize(self: WindowState) win.Size {
        return .{
            .width = @intFromFloat(@round(@as(f32, @floatFromInt(self.logical_size.width)) * self.scale)),
            .height = @intFromFloat(@round(@as(f32, @floatFromInt(self.logical_size.height)) * self.scale)),
        };
    }

    fn info(self: WindowState) win.WindowInfo {
        return .{
            .logical_size = self.logical_size,
            .pixel_size = self.pixelSize(),
            .scale = self.scale,
            .focused = self.focused,
            .minimized = self.minimized,
        };
    }
};

pub const Platform = struct {
    gpa: Allocator,
    windows: core.HandlePool(win.Window, WindowState) = .empty,

    /// Events a test has queued but that have not been "delivered by the OS" yet.
    /// Separate from `ready` so that pushing an event mid-frame behaves the way a real
    /// OS does: it becomes visible at the next pump, not immediately.
    incoming: std.ArrayList(event.Event) = .empty,
    ready: std.ArrayList(event.Event) = .empty,
    cursor: usize = 0,

    accumulator: input.Accumulator = .init,

    clock_ns: i64 = 0,
    clock_step_ns: i64 = std.time.ns_per_ms,

    pub fn init(gpa: Allocator, options: interface.InitOptions) interface.InitError!*Platform {
        _ = options;
        const self = try gpa.create(Platform);
        self.* = .{ .gpa = gpa };
        log.info("platform backend: null (headless)", .{});
        return self;
    }

    pub fn deinit(self: *Platform) void {
        const gpa = self.gpa;
        self.windows.deinit(gpa);
        self.incoming.deinit(gpa);
        self.ready.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn openWindow(self: *Platform, config: win.WindowConfig) interface.WindowError!win.WindowHandle {
        // A headless backend cannot produce a real GPU surface, and pretending
        // otherwise would hand `rhi` a pointer to nothing. Refusing is the honest
        // answer, and it is a configuration mistake rather than a programmer error, so
        // it is reported rather than asserted.
        if (config.surface != .none) return error.SurfaceUnavailable;

        return self.windows.add(self.gpa, .{
            .logical_size = .{ .width = config.logical_width, .height = config.logical_height },
            .scale = 1.0,
            .focused = false,
            .minimized = false,
        });
    }

    pub fn closeWindow(self: *Platform, handle: win.WindowHandle) void {
        _ = self.windows.remove(handle);
    }

    pub fn windowInfo(self: *Platform, handle: win.WindowHandle) ?win.WindowInfo {
        const state = self.windows.getConst(handle) orelse return null;
        return state.info();
    }

    pub fn nativeSurface(self: *Platform, handle: win.WindowHandle) ?win.NativeSurfaceHandle {
        if (!self.windows.contains(handle)) return null;
        // A live window with nothing behind it. `rhi`'s null backend accepts this;
        // any real backend will reject the `none` kind, which is correct.
        return .none;
    }

    pub fn pumpEvents(self: *Platform) void {
        self.ready.clearRetainingCapacity();
        self.cursor = 0;

        for (self.incoming.items) |ev| {
            self.applyToWindowState(ev);
            self.accumulator.apply(ev);
            // The queue was sized when the event was pushed, so this cannot fail; if
            // it somehow did, dropping input silently would be worse than saying so.
            self.ready.append(self.gpa, ev) catch {
                log.err("null backend dropped an event: out of memory", .{});
                break;
            };
        }
        self.incoming.clearRetainingCapacity();
    }

    pub fn nextEvent(self: *Platform) ?event.Event {
        if (self.cursor >= self.ready.items.len) return null;
        defer self.cursor += 1;
        return self.ready.items[self.cursor];
    }

    pub fn captureInput(self: *Platform) input.InputSnapshot {
        return self.accumulator.capture();
    }

    /// The synthetic monotonic clock. Advances by exactly `clock_step_ns` per reading,
    /// so a loop driven by it runs the same number of steps on every machine.
    pub fn now(self: *Platform) core.time.Instant {
        self.clock_ns += self.clock_step_ns;
        return .{ .ns = self.clock_ns };
    }

    fn applyToWindowState(self: *Platform, ev: event.Event) void {
        switch (ev) {
            .window_resized => |e| {
                const state = self.windows.get(e.window) orelse return;
                state.logical_size = e.logical_size;
                state.scale = e.scale;
            },
            .window_focus_gained => |e| {
                if (self.windows.get(e.window)) |state| state.focused = true;
            },
            .window_focus_lost => |e| {
                if (self.windows.get(e.window)) |state| state.focused = false;
            },
            else => {},
        }
    }

    // -- test affordances ----------------------------------------------------------
    //
    // How a test plays the part of the operating system. Not part of the backend
    // interface, and not reachable from engine code above `platform`.

    /// Queues an event as though the OS had produced it. Visible after the next
    /// `pumpEvents`, exactly as a real event would be.
    pub fn pushEvent(self: *Platform, ev: event.Event) Allocator.Error!void {
        try self.incoming.append(self.gpa, ev);
    }

    /// Sets how far the synthetic clock moves per reading.
    pub fn setClockStep(self: *Platform, step: core.time.Duration) void {
        self.clock_step_ns = step.ns;
    }

    /// Resizes a window and queues the resulting event, the way a window manager would.
    pub fn resizeWindow(
        self: *Platform,
        handle: win.WindowHandle,
        logical_size: win.Size,
        scale: f32,
    ) Allocator.Error!void {
        const state = self.windows.get(handle) orelse return;
        state.logical_size = logical_size;
        state.scale = scale;
        try self.pushEvent(.{ .window_resized = .{
            .window = handle,
            .logical_size = logical_size,
            .pixel_size = state.pixelSize(),
            .scale = scale,
        } });
    }

    /// Gives or takes keyboard focus, queueing the matching event.
    pub fn setFocus(self: *Platform, handle: win.WindowHandle, focused: bool) Allocator.Error!void {
        try self.pushEvent(if (focused)
            .{ .window_focus_gained = .{ .window = handle } }
        else
            .{ .window_focus_lost = .{ .window = handle } });
    }
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

fn open(gpa: Allocator) !*Platform {
    return Platform.init(gpa, .{});
}

test "the null backend satisfies the interface" {
    comptime interface.check(@This(), "null");
}

test "lifecycle leaves nothing behind" {
    const p = try open(testing.allocator);
    defer p.deinit();
    // testing.allocator fails the test on leak, which is the actual assertion.
}

test "a window reports logical and pixel size separately" {
    const p = try open(testing.allocator);
    defer p.deinit();

    const w = try p.openWindow(.{ .logical_width = 1280, .logical_height = 720 });
    const info = p.windowInfo(w).?;
    try testing.expect(info.logical_size.eql(.{ .width = 1280, .height = 720 }));
    try testing.expect(info.pixel_size.eql(.{ .width = 1280, .height = 720 }));
    try testing.expectEqual(@as(f32, 1.0), info.scale);
}

test "both sizes survive a resize, and a scale change moves only one of them" {
    // The Retina bug in miniature: moving to a 2x display changes the pixel size and
    // the scale while the logical size stays put. Code that kept one number would
    // render at half resolution and never know.
    const p = try open(testing.allocator);
    defer p.deinit();

    const w = try p.openWindow(.{ .logical_width = 800, .logical_height = 600 });

    try p.resizeWindow(w, .{ .width = 1024, .height = 768 }, 1.0);
    p.pumpEvents();
    var info = p.windowInfo(w).?;
    try testing.expect(info.logical_size.eql(.{ .width = 1024, .height = 768 }));
    try testing.expect(info.pixel_size.eql(.{ .width = 1024, .height = 768 }));

    // Dragged onto a 2x display: same logical size, twice the pixels.
    try p.resizeWindow(w, .{ .width = 1024, .height = 768 }, 2.0);
    p.pumpEvents();
    info = p.windowInfo(w).?;
    try testing.expect(info.logical_size.eql(.{ .width = 1024, .height = 768 }));
    try testing.expect(info.pixel_size.eql(.{ .width = 2048, .height = 1536 }));
    try testing.expectEqual(@as(f32, 2.0), info.scale);

    // And the event carried both, so a renderer never has to ask.
    var saw_resize = false;
    while (p.nextEvent()) |ev| switch (ev) {
        .window_resized => |e| {
            saw_resize = true;
            try testing.expect(e.pixel_size.eql(.{ .width = 2048, .height = 1536 }));
        },
        else => {},
    };
    try testing.expect(saw_resize);
}

test "a closed window's handle resolves to nothing" {
    // I1: a stale handle is safely dead, not a pointer to whatever took its place.
    const p = try open(testing.allocator);
    defer p.deinit();

    const w = try p.openWindow(.{});
    try testing.expect(p.windowInfo(w) != null);

    p.closeWindow(w);
    try testing.expectEqual(@as(?win.WindowInfo, null), p.windowInfo(w));
    try testing.expectEqual(@as(?win.NativeSurfaceHandle, null), p.nativeSurface(w));

    // Reusing the slot must not resurrect the old handle.
    const w2 = try p.openWindow(.{});
    try testing.expect(!w.eql(w2));
    try testing.expectEqual(@as(?win.WindowInfo, null), p.windowInfo(w));
}

test "a headless backend refuses to invent a GPU surface" {
    const p = try open(testing.allocator);
    defer p.deinit();
    try testing.expectError(error.SurfaceUnavailable, p.openWindow(.{ .surface = .metal_layer }));
}

test "events become visible at the pump, not when they happen" {
    // Matching a real backend: the OS queue is drained at one known point in the frame.
    const p = try open(testing.allocator);
    defer p.deinit();

    try p.pushEvent(.quit_requested);
    try testing.expectEqual(@as(?event.Event, null), p.nextEvent());

    p.pumpEvents();
    try testing.expect(p.nextEvent().? == .quit_requested);
    try testing.expectEqual(@as(?event.Event, null), p.nextEvent());
}

test "a scripted sequence produces the expected snapshot" {
    const p = try open(testing.allocator);
    defer p.deinit();

    const w = try p.openWindow(.{});
    try p.setFocus(w, true);
    try p.pushEvent(.{ .key_down = .{ .key = .w } });
    try p.pushEvent(.{ .key_down = .{ .key = .space } });
    try p.pushEvent(.{ .key_up = .{ .key = .space } }); // pressed and released in one frame
    p.pumpEvents();

    const snap = p.captureInput();
    try testing.expect(snap.focused);
    try testing.expect(snap.isHeld(.w));
    try testing.expect(snap.wasPressed(.space));
    try testing.expect(snap.wasReleased(.space));
    try testing.expect(!snap.isHeld(.space));
}

test "the synthetic clock is exactly reproducible" {
    // The whole point: a loop test measures the logic, not the machine.
    const p = try open(testing.allocator);
    defer p.deinit();
    p.setClockStep(.fromMillis(16));

    const t0 = p.now();
    const t1 = p.now();
    try testing.expectEqual(@as(i64, 16 * std.time.ns_per_ms), t1.since(t0).ns);

    const q = try open(testing.allocator);
    defer q.deinit();
    q.setClockStep(.fromMillis(16));
    _ = q.now();
    try testing.expectEqual(p.clock_ns - 16 * std.time.ns_per_ms, q.clock_ns);
}

test "the clock never goes backwards" {
    const p = try open(testing.allocator);
    defer p.deinit();

    var previous = p.now();
    for (0..64) |_| {
        const current = p.now();
        try testing.expect(current.ns > previous.ns);
        previous = current;
    }
}

/// Runs `frames` frames of a 60Hz simulation against a fresh null platform whose clock
/// ticks `frame_ns` per reading, and reports how many simulation steps came out.
fn runLoop(frame_ns: i64, frames: usize) !struct { steps: u32, leftover: i64 } {
    const p = try open(testing.allocator);
    defer p.deinit();
    p.setClockStep(.fromNanos(frame_ns));

    var stepper = core.time.FixedStepper.init(.fromHz(60));
    stepper.max_steps_per_frame = 1000;
    var previous = p.now();
    var steps: u32 = 0;

    for (0..frames) |_| {
        const current = p.now();
        stepper.advance(current.since(previous));
        previous = current;
        while (stepper.next()) steps += 1;
    }
    return .{ .steps = steps, .leftover = stepper.accumulated };
}

test "the synthetic clock drives a fixed-timestep loop exactly" {
    // The reason the clock belongs to the backend rather than being read from the OS:
    // this measures the loop, not how fast the machine running it is.
    //
    // One thousand 1ms frames is exactly one second, which at 60Hz is exactly 60 steps
    // with nothing left over. Not an approximation — the accumulator is integer
    // arithmetic in units of nanoseconds x denominator, so "nothing left over" is
    // literal (`core.time`).
    const result = try runLoop(std.time.ns_per_ms, 1000);
    try testing.expectEqual(@as(u32, 60), result.steps);
    try testing.expectEqual(@as(i64, 0), result.leftover);
}

test "the same frame timings always produce the same number of steps" {
    // I9 at the level `app` will actually depend on. Two identical runs, and a third
    // with a deliberately awkward frame length, all reproducible.
    const a = try runLoop(std.time.ns_per_ms, 1000);
    const b = try runLoop(std.time.ns_per_ms, 1000);
    try testing.expectEqual(a.steps, b.steps);
    try testing.expectEqual(a.leftover, b.leftover);

    const odd_a = try runLoop(7_777_777, 333);
    const odd_b = try runLoop(7_777_777, 333);
    try testing.expectEqual(odd_a.steps, odd_b.steps);
    try testing.expectEqual(odd_a.leftover, odd_b.leftover);
}

test "a frame length that does not divide the step loses nothing over time" {
    // 1/120s truncates to 8333333ns, which is 0.33ns short of half a step. Over 120
    // frames that deficit is real — 59 steps, not 60 — and the exact accumulator
    // reports it rather than smearing it away. A float accumulator would give an
    // answer that drifted differently on different machines.
    const short = try runLoop(@divTrunc(std.time.ns_per_s, 120), 120);
    try testing.expectEqual(@as(u32, 59), short.steps);

    // Rounding the frame length up instead recovers the step, deterministically.
    const rounded = try runLoop(@divTrunc(std.time.ns_per_s, 120) + 1, 120);
    try testing.expectEqual(@as(u32, 60), rounded.steps);
}
