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
//! Its clock advances by an exact amount per frame (per `pumpEvents`), never per reading,
//! so a loop test measures the logic rather than how fast the test machine happens to be.
//! Its event queue is scriptable, which is the seed of replay testing later — a direct
//! payoff of the snapshot design in `input.zig`.
//!
//! The functions below `-- test affordances --` are **not** part of the backend
//! interface. They are how a test plays the part of the operating system, and no
//! engine code above `platform` may use them.
//!
//! Design: `docs/design/platform-interface.md` §9.

const std = @import("std");
const core = @import("core");

const audio = @import("../audio.zig");
const event = @import("../event.zig");
const gamepad = @import("../gamepad.zig");
const input = @import("../input.zig");
const interface = @import("../interface.zig");
const key = @import("../key.zig");
const win = @import("../window.zig");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.platform);

const WindowState = struct {
    logical_size: win.Size,
    scale: f32,
    focused: bool,
    minimized: bool,
    /// Whether this window holds the pointer. Cleared when it loses keyboard focus.
    pointer_captured: bool = false,
    /// The size of the last icon accepted. There is no window manager to show it to.
    icon: ?win.Size = null,

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

/// A device that never runs. Nothing here has a thread, and that is the point: the
/// callback is invoked by `stepAudio`, synchronously, on the caller's thread.
const AudioState = struct {
    config: audio.AudioConfig,
    info: audio.AudioInfo,
    paused: bool,
    /// Sized on demand by `stepAudio`. The device owns the buffer, exactly as a real one
    /// does, so a test never has to supply the memory the OS would have supplied.
    buffer: std.ArrayList(f32) = .empty,
};

/// A pad a test has connected: what it reports itself as, and whether it has motors.
pub const PadDescription = struct {
    kind: gamepad.GamepadKind = .xbox,
    face: gamepad.FaceLabels = .{ .a, .b, .x, .y },
    rumble: bool = true,
};

/// The last rumble a seated pad was asked for, as the OS would have received it.
pub const Rumble = struct {
    low: f32,
    high: f32,
    duration_ms: u32,
};

const KnownPad = struct {
    device: gamepad.DeviceId,
    description: PadDescription,
};

pub const Platform = struct {
    gpa: Allocator,
    windows: core.HandlePool(win.Window, WindowState) = .empty,
    audio_devices: core.HandlePool(audio.AudioDevice, AudioState) = .empty,

    /// Events a test has queued but that have not been "delivered by the OS" yet.
    /// Separate from `ready` so that pushing an event mid-frame behaves the way a real
    /// OS does: it becomes visible at the next pump, not immediately.
    incoming: std.ArrayList(event.Event) = .empty,
    ready: std.ArrayList(event.Event) = .empty,
    cursor: usize = 0,

    accumulator: input.Accumulator = .init,

    /// How captured motion is measured. `raw` by default, as on every backend.
    motion_mode: input.MotionMode = .raw,
    /// Whether this "window system" can deliver raw counts. A test clears it to play a platform
    /// that cannot (`setRawMotionAvailable`); motion pushed while captured is then points.
    raw_motion_available: bool = true,

    clock_ns: i64 = 0,
    clock_step_ns: i64 = std.time.ns_per_ms,

    /// `InitOptions.gamepads`: off, a connected pad is ignored, as an SDL platform that never
    /// opened its gamepad subsystem would never hear of it.
    gamepads_enabled: bool = true,
    /// Which "device" sits in which slot, by the rule every backend shares.
    slots: gamepad.Slots = .empty,
    /// Every connected pad, seated or waiting, in connection order.
    known_pads: std.ArrayList(KnownPad) = .empty,
    /// Per slot, the last rumble its pad accepted.
    rumbles: [gamepad.max_gamepads]?Rumble = @splat(null),

    pub fn init(gpa: Allocator, options: interface.InitOptions) interface.InitError!*Platform {
        const self = try gpa.create(Platform);
        self.* = .{ .gpa = gpa, .gamepads_enabled = options.gamepads };
        self.syncMotionUnit();
        log.info("platform backend: null (headless)", .{});
        return self;
    }

    pub fn deinit(self: *Platform) void {
        const gpa = self.gpa;
        self.windows.deinit(gpa);

        var devices = self.audio_devices.iterator();
        while (devices.next()) |entry| entry.value.buffer.deinit(gpa);
        self.audio_devices.deinit(gpa);

        self.incoming.deinit(gpa);
        self.ready.deinit(gpa);
        self.known_pads.deinit(gpa);
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
        self.syncPointerCapture();
    }

    pub fn windowInfo(self: *Platform, handle: win.WindowHandle) ?win.WindowInfo {
        const state = self.windows.getConst(handle) orelse return null;
        return state.info();
    }

    /// Queues the resize the window manager would have sent, and **changes nothing yet**.
    ///
    /// The eager thing would be to update the window here and queue the event as a
    /// courtesy. This backend deliberately does not, for the same reason the null *rhi*
    /// backend enforces rules Metal forgives: the interface says a resize is observed by
    /// draining `window_resized`, and a caller that read the size straight back would work
    /// here, work on macOS, and desynchronise on a platform that resizes asynchronously.
    /// Making the strict contract the one that is easy to satisfy is this backend's job.
    ///
    /// The scale is carried over: a headless window has no second display to have moved
    /// between. `resizeWindow` below is the test-only counterpart that can change it.
    pub fn setWindowSize(self: *Platform, handle: win.WindowHandle, logical: win.Size) interface.WindowError!void {
        if (logical.isEmpty()) return error.InvalidWindowSize;
        const state = self.windows.getConst(handle) orelse return error.InvalidWindow;

        var pending = state.*;
        pending.logical_size = logical;

        self.pushEvent(.{ .window_resized = .{
            .window = handle,
            .logical_size = logical,
            .pixel_size = pending.pixelSize(),
            .scale = pending.scale,
        } }) catch return error.OutOfMemory;
    }

    /// Validates exactly as a real backend does, then remembers the size it accepted.
    /// There is no window manager to show it to, so the title is only validated.
    pub fn setWindowTitle(self: *Platform, handle: win.WindowHandle, title: []const u8) interface.WindowTitleError!void {
        if (self.windows.getConst(handle) == null) return error.InvalidWindow;
        if (!interface.validWindowTitle(title)) return error.InvalidWindowTitle;
    }

    pub fn setWindowIcon(self: *Platform, handle: win.WindowHandle, icon: win.WindowIcon) interface.WindowIconError!void {
        try icon.validate();
        const state = self.windows.get(handle) orelse return error.InvalidWindow;
        state.icon = .{ .width = icon.width, .height = icon.height };
    }

    /// Records the capture, effective at once: the next snapshot reports it, and motion pushed
    /// from here on moves no position. There is no window system to refuse, so this backend
    /// never answers `Unsupported`; a test of that answer names a host's handling, not this.
    pub fn setPointerCapture(self: *Platform, handle: win.WindowHandle, captured: bool) interface.PointerCaptureError!void {
        const state = self.windows.get(handle) orelse return error.InvalidWindow;
        state.pointer_captured = captured;
        self.syncPointerCapture();
    }

    /// The accumulator's flag is whether *any* window holds the pointer, recomputed rather
    /// than toggled so that closing a window or its losing focus cannot leave it stale.
    fn syncPointerCapture(self: *Platform) void {
        var any = false;
        var it = self.windows.iterator();
        while (it.next()) |entry| any = any or entry.value.pointer_captured;
        self.accumulator.captured = any;
    }

    /// Effective at once, for motion pushed from here on. The motion a test pushes is whatever
    /// it says it is; this backend only names it, as a real one names what its OS delivers.
    pub fn setCapturedMotion(self: *Platform, mode: input.MotionMode) void {
        self.motion_mode = mode;
        self.syncMotionUnit();
    }

    fn syncMotionUnit(self: *Platform) void {
        self.accumulator.captured_unit = input.capturedUnit(self.motion_mode, self.raw_motion_available);
    }

    /// There is no layout, so a key's label is its own physical name, and `unknown` has none.
    pub fn keyLabel(self: *Platform, k: key.Key, buf: *[key.label_capacity]u8) []const u8 {
        _ = self;
        if (k == .unknown) return buf[0..0];
        return key.boundedLabel(k.name(), buf);
    }

    /// Validates exactly as a real backend does, then records what the pad would have been told.
    pub fn setGamepadRumble(self: *Platform, pad: gamepad.GamepadHandle, low: f32, high: f32, duration_ms: u32) interface.GamepadRumbleError!void {
        const device = self.slots.deviceOf(pad) orelse return error.InvalidGamepad;
        if (!gamepad.rumbleValid(low, high, duration_ms)) return error.InvalidRumble;
        const known = self.knownPad(device) orelse return error.InvalidGamepad;
        if (!known.description.rumble) return error.Unsupported;
        self.rumbles[pad.index] = .{ .low = low, .high = high, .duration_ms = duration_ms };
    }

    fn knownPad(self: *Platform, device: gamepad.DeviceId) ?*KnownPad {
        for (self.known_pads.items) |*known| {
            if (known.device == device) return known;
        }
        return null;
    }

    pub fn nativeSurface(self: *Platform, handle: win.WindowHandle) ?win.NativeSurfaceHandle {
        if (!self.windows.contains(handle)) return null;
        // A live window with nothing behind it. `rhi`'s null backend accepts this;
        // any real backend will reject the `none` kind, which is correct.
        return .none;
    }

    pub fn pumpEvents(self: *Platform) void {
        // The frame's time passes here, once, however often the clock is read (`now`).
        self.clock_ns += self.clock_step_ns;
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

    /// **A headless device gives you exactly what you asked for**, which is what makes
    /// it a test instrument. A real backend answers with the device's own rate; this one
    /// has no device to disagree, so `AudioInfo` is the config back, and a test that
    /// pulls 512 frames gets 512 frames.
    pub fn openAudio(self: *Platform, config: audio.AudioConfig) interface.AudioError!audio.AudioDeviceHandle {
        if (!audio.supportable(config)) return error.AudioFormatUnsupported;
        return self.audio_devices.add(self.gpa, .{
            .config = config,
            .info = .{
                .sample_rate = config.sample_rate,
                .channels = config.channels,
                .buffer_frames = config.buffer_frames,
            },
            // A device opens running. `setAudioPaused` is for a game that wants silence,
            // not a step every backend has to remember — a device that opened paused
            // would be an engine that ships with no sound until someone noticed.
            .paused = false,
        });
    }

    pub fn closeAudio(self: *Platform, device: audio.AudioDeviceHandle) void {
        const state = self.audio_devices.get(device) orelse return;
        state.buffer.deinit(self.gpa);
        _ = self.audio_devices.remove(device);
    }

    pub fn audioInfo(self: *Platform, device: audio.AudioDeviceHandle) ?audio.AudioInfo {
        const state = self.audio_devices.getConst(device) orelse return null;
        return state.info;
    }

    pub fn setAudioPaused(self: *Platform, device: audio.AudioDeviceHandle, paused: bool) void {
        const state = self.audio_devices.get(device) orelse return;
        state.paused = paused;
    }

    /// The synthetic monotonic clock. Advances by exactly `clock_step_ns` per `pumpEvents`,
    /// so a loop driven by it runs the same number of steps on every machine.
    ///
    /// **Reading it does not move it.** It once advanced per reading, which made time a
    /// function of how often something looked: a profiler reading it eight times a frame
    /// made a headless game simulate eight steps a frame instead of one. A frame's time
    /// now passes once, where a real OS delivers the frame's input, and every reading
    /// within the frame sees the same instant.
    pub fn now(self: *Platform) core.time.Instant {
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
                if (self.windows.get(e.window)) |state| {
                    state.focused = false;
                    // Released, and not taken back when focus returns: the game asks again.
                    state.pointer_captured = false;
                }
                self.syncPointerCapture();
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

    /// Pulls `frames` frames from a device, synchronously, on the calling thread, and
    /// returns what the callback wrote.
    ///
    /// **Deliberately not on the interface** (`audio.md` §3): there is nothing sensible
    /// for a real backend to do with it, because the device thread is already calling
    /// the callback and cannot be asked to do it again on demand. A test that wants
    /// deterministic audio names `platform.null_backend` directly, exactly as `app`'s
    /// loop tests already name it for the synthetic clock.
    ///
    /// **What this proves and what it does not.** It proves the mixer's arithmetic, the
    /// command protocol's semantics and the voice lifecycle. It does *not* exercise a
    /// ring under real concurrency, because producer and consumer are this one thread.
    ///
    /// The returned slice is owned by the device and is valid until the next call.
    pub fn stepAudio(
        self: *Platform,
        device: audio.AudioDeviceHandle,
        frames: u32,
    ) Allocator.Error![]const f32 {
        const state = self.audio_devices.get(device) orelse return &.{};

        const samples = @as(usize, frames) * state.info.channels;
        try state.buffer.resize(self.gpa, samples);

        // A paused device does not call its callback at all; the hardware plays silence.
        // Emulating that rather than calling anyway is what lets a test tell "the mixer
        // produced nothing" apart from "the device was not running".
        if (state.paused) {
            @memset(state.buffer.items, 0);
        } else {
            state.config.callback(state.config.ctx, state.buffer.items);
        }
        return state.buffer.items;
    }

    /// Sets how far the synthetic clock moves per `pumpEvents`, which is to say per frame.
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

    /// The size of the icon a window last accepted, or null if it has none or is closed.
    pub fn windowIconSize(self: *Platform, handle: win.WindowHandle) ?win.Size {
        const state = self.windows.getConst(handle) orelse return null;
        return state.icon;
    }

    /// Whether a window holds the pointer, as the window system would know it.
    pub fn pointerCaptured(self: *Platform, handle: win.WindowHandle) ?bool {
        const state = self.windows.getConst(handle) orelse return null;
        return state.pointer_captured;
    }

    /// Plays a window system that cannot deliver raw counts (macOS's, `input.md` §3's
    /// Resolution), or one that can again. Captured motion is then reported as points in either
    /// mode, which is how a real backend answers when it cannot honour `raw`.
    pub fn setRawMotionAvailable(self: *Platform, available: bool) void {
        self.raw_motion_available = available;
        self.syncMotionUnit();
    }

    /// Connects a pad, as the OS would announce one. It is seated by `gamepad.Slots`, the rule
    /// the SDL backend uses, and its `gamepad_added` is queued; the handle is returned. A pad
    /// arriving with every slot taken waits and returns null, and so does any pad while gamepads
    /// are off. `device` is the test's own number for the pad, as SDL has its instance IDs.
    pub fn connectGamepad(self: *Platform, device: gamepad.DeviceId, description: PadDescription) Allocator.Error!?gamepad.GamepadHandle {
        if (!self.gamepads_enabled or self.knownPad(device) != null) return null;
        try self.known_pads.ensureUnusedCapacity(self.gpa, 1);
        try self.incoming.ensureUnusedCapacity(self.gpa, 1);
        switch (self.slots.connect(device)) {
            .seated => |pad| {
                self.known_pads.appendAssumeCapacity(.{ .device = device, .description = description });
                self.rumbles[pad.index] = null;
                self.incoming.appendAssumeCapacity(addedEvent(pad, description));
                return pad;
            },
            .waiting => self.known_pads.appendAssumeCapacity(.{ .device = device, .description = description }),
            .overflowed, .already => {},
        }
        return null;
    }

    /// Disconnects a pad. A seated one queues its `gamepad_removed`, and the first waiting pad
    /// takes its slot at once with a `gamepad_added` of its own.
    pub fn disconnectGamepad(self: *Platform, device: gamepad.DeviceId) Allocator.Error!void {
        const index = for (self.known_pads.items, 0..) |known, i| {
            if (known.device == device) break i;
        } else return;
        try self.incoming.ensureUnusedCapacity(self.gpa, 2);
        _ = self.known_pads.orderedRemove(index);
        const left = self.slots.disconnect(device);
        if (left.removed) |pad| self.incoming.appendAssumeCapacity(.{ .gamepad_removed = .{ .pad = pad } });
        if (left.promoted) |next| {
            self.rumbles[next.pad.index] = null;
            const description = self.knownPad(next.device).?.description;
            self.incoming.appendAssumeCapacity(addedEvent(next.pad, description));
        }
    }

    /// Presses or releases a button on a pad. A waiting or unknown pad's buttons go nowhere, as a
    /// real backend never opened it to hear them.
    pub fn setGamepadButton(self: *Platform, device: gamepad.DeviceId, button: gamepad.GamepadButton, down: bool) Allocator.Error!void {
        const pad = self.slots.handleOf(device) orelse return;
        const payload: event.GamepadButtonEvent = .{ .pad = pad, .button = button };
        try self.pushEvent(if (down) .{ .gamepad_button_down = payload } else .{ .gamepad_button_up = payload });
    }

    /// Moves an axis to a raw 16-bit reading, normalised as the SDL backend normalises one.
    pub fn setGamepadAxis(self: *Platform, device: gamepad.DeviceId, axis: gamepad.GamepadAxis, raw: i16) Allocator.Error!void {
        const pad = self.slots.handleOf(device) orelse return;
        try self.pushEvent(.{ .gamepad_axis = .{ .pad = pad, .axis = axis, .value = gamepad.normalizeAxis(axis, raw) } });
    }

    /// The last rumble the pad in a slot accepted, or null if none since it was seated.
    pub fn lastRumble(self: *Platform, pad: gamepad.GamepadHandle) ?Rumble {
        if (self.slots.deviceOf(pad) == null) return null;
        return self.rumbles[pad.index];
    }

    fn addedEvent(pad: gamepad.GamepadHandle, description: PadDescription) event.Event {
        return .{ .gamepad_added = .{ .pad = pad, .kind = description.kind, .face = description.face } };
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

test "setWindowSize resizes through the event queue, not behind it" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();

    const w = try p.openWindow(.{ .logical_width = 800, .logical_height = 600 });
    try p.setWindowSize(w, .{ .width = 1024, .height = 768 });

    // Still the old size: a resize is a request, and the interface says it is observed
    // by draining the queue. A backend that changed it here would let a caller get away
    // with never handling `window_resized`, which SDL would then punish.
    try testing.expect(p.windowInfo(w).?.logical_size.eql(.{ .width = 800, .height = 600 }));

    p.pumpEvents();
    const ev = p.nextEvent().?;
    try testing.expect(ev == .window_resized);
    try testing.expect(ev.window_resized.logical_size.eql(.{ .width = 1024, .height = 768 }));
    try testing.expect(p.windowInfo(w).?.logical_size.eql(.{ .width = 1024, .height = 768 }));
}

test "setWindowSize validates rather than asserts" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();

    const w = try p.openWindow(.{});

    // A resolution out of a settings file or a mod is untrusted input (`CLAUDE.md` §7).
    try testing.expectError(error.InvalidWindowSize, p.setWindowSize(w, .{ .width = 0, .height = 720 }));
    try testing.expectError(error.InvalidWindowSize, p.setWindowSize(w, .{ .width = 1280, .height = 0 }));

    // And a dead handle resolves to nothing rather than to whatever took its slot (I1).
    p.closeWindow(w);
    try testing.expectError(error.InvalidWindow, p.setWindowSize(w, .{ .width = 640, .height = 480 }));
}

test "setWindowIcon validates the application's bytes and borrows them only for the call" {
    const p = try open(testing.allocator);
    defer p.deinit();
    const w = try p.openWindow(.{});
    try testing.expectEqual(@as(?win.Size, null), p.windowIconSize(w));

    const pixels = try testing.allocator.alloc(u8, 32 * 32 * 4);
    @memset(pixels, 0x7f);
    try p.setWindowIcon(w, .{ .width = 32, .height = 32, .stride = 32 * 4, .pixels = pixels });
    // Freed before anything reads the window again: nothing kept the pointer.
    testing.allocator.free(pixels);
    try testing.expectEqual(win.Size{ .width = 32, .height = 32 }, p.windowIconSize(w).?);

    // A refused icon leaves the one already accepted.
    var few: [16]u8 = @splat(0);
    try testing.expectError(error.InvalidWindowIcon, p.setWindowIcon(w, .{ .width = 2, .height = 2, .stride = 8, .pixels = few[0..15] }));
    try testing.expectError(error.InvalidWindowIcon, p.setWindowIcon(w, .{ .width = 0, .height = 2, .stride = 8, .pixels = &few }));
    try testing.expectEqual(win.Size{ .width = 32, .height = 32 }, p.windowIconSize(w).?);

    p.closeWindow(w);
    try testing.expectError(error.InvalidWindow, p.setWindowIcon(w, .{ .width = 2, .height = 2, .stride = 8, .pixels = &few }));
    try testing.expectEqual(@as(?win.Size, null), p.windowIconSize(w));
}

test "a headless backend refuses to invent a GPU surface" {
    const p = try open(testing.allocator);
    defer p.deinit();
    try testing.expectError(error.SurfaceUnavailable, p.openWindow(.{ .surface = .metal_layer }));
    // Nor a native window, whichever window system is named: there is none behind it.
    for ([_]win.SurfaceKind{ .native_window, .win32_hwnd, .xlib_window, .wayland_surface }) |kind| {
        try testing.expectError(error.SurfaceUnavailable, p.openWindow(.{ .surface = kind }));
    }
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
    p.pumpEvents();
    const t1 = p.now();
    try testing.expectEqual(@as(i64, 16 * std.time.ns_per_ms), t1.since(t0).ns);

    const q = try open(testing.allocator);
    defer q.deinit();
    q.setClockStep(.fromMillis(16));
    q.pumpEvents();
    try testing.expectEqual(p.clock_ns, q.clock_ns);
}

test "the clock never goes backwards" {
    const p = try open(testing.allocator);
    defer p.deinit();

    var previous = p.now();
    for (0..64) |_| {
        p.pumpEvents();
        const current = p.now();
        try testing.expect(current.ns > previous.ns);
        previous = current;
    }
}

test "reading the clock does not advance it" {
    // A measurement must not change what it measures: a frame read once and a frame read
    // eight times by a profiler are the same length.
    const p = try open(testing.allocator);
    defer p.deinit();
    p.setClockStep(.fromMillis(16));

    const start = p.now();
    for (0..8) |_| try testing.expectEqual(start.ns, p.now().ns);
    p.pumpEvents();
    for (0..8) |_| try testing.expectEqual(@as(i64, 16 * std.time.ns_per_ms), p.now().since(start).ns);
}

/// Runs `frames` frames of a 60Hz simulation against a fresh null platform whose clock
/// ticks `frame_ns` per frame, and reports how many simulation steps came out.
fn runLoop(frame_ns: i64, frames: usize) !struct { steps: u32, leftover: i64 } {
    const p = try open(testing.allocator);
    defer p.deinit();
    p.setClockStep(.fromNanos(frame_ns));

    var stepper = core.time.FixedStepper.init(.fromHz(60));
    stepper.max_steps_per_frame = 1000;
    var previous = p.now();
    var steps: u32 = 0;

    for (0..frames) |_| {
        p.pumpEvents();
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

// -- audio ---------------------------------------------------------------------------

/// A callback that counts what it was asked for and writes a ramp, so a test can tell
/// which call produced which samples.
const Recorder = struct {
    calls: u32 = 0,
    last_len: usize = 0,
    next: f32 = 1.0,

    fn fill(ctx: ?*anyopaque, out: []f32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.last_len = out.len;
        for (out) |*sample| sample.* = self.next;
        self.next += 1.0;
    }

    fn config(self: *Recorder, channels: u8, frames: u32) audio.AudioConfig {
        return .{ .channels = channels, .buffer_frames = frames, .callback = fill, .ctx = self };
    }
};

test "a headless device answers with exactly what it was asked for" {
    const p = try open(testing.allocator);
    defer p.deinit();

    var rec: Recorder = .{};
    const d = try p.openAudio(rec.config(2, 512));
    defer p.closeAudio(d);

    const info = p.audioInfo(d).?;
    try testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u32, 512), info.buffer_frames);
    try testing.expectEqual(@as(usize, 1024), info.bufferSamples());
}

test "stepping a device calls the callback with the buffer it was promised" {
    const p = try open(testing.allocator);
    defer p.deinit();

    var rec: Recorder = .{};
    const d = try p.openAudio(rec.config(2, 4));
    defer p.closeAudio(d);

    const first = try p.stepAudio(d, 4);
    try testing.expectEqual(@as(u32, 1), rec.calls);
    // Samples, not frames: the length a mono/stereo mixing bug gets wrong.
    try testing.expectEqual(@as(usize, 8), rec.last_len);
    try testing.expectEqualSlices(f32, &[_]f32{1.0} ** 8, first);

    // And a second pull is a second callback, with the buffer reused.
    const second = try p.stepAudio(d, 4);
    try testing.expectEqual(@as(u32, 2), rec.calls);
    try testing.expectEqualSlices(f32, &[_]f32{2.0} ** 8, second);

    // The same number of steps produces the same samples every run, which is the whole
    // reason this device exists rather than a real one (I9, `audio.md` §8).
    var again: Recorder = .{};
    const e = try p.openAudio(again.config(2, 4));
    defer p.closeAudio(e);
    try testing.expectEqualSlices(f32, &[_]f32{1.0} ** 8, try p.stepAudio(e, 4));
}

test "a paused device plays silence and does not call back" {
    const p = try open(testing.allocator);
    defer p.deinit();

    var rec: Recorder = .{};
    const d = try p.openAudio(rec.config(1, 4));
    defer p.closeAudio(d);

    // A device opens running: nothing has to remember to start it.
    _ = try p.stepAudio(d, 4);
    try testing.expectEqual(@as(u32, 1), rec.calls);

    p.setAudioPaused(d, true);
    const quiet = try p.stepAudio(d, 4);
    try testing.expectEqual(@as(u32, 1), rec.calls);
    try testing.expectEqualSlices(f32, &[_]f32{0.0} ** 4, quiet);

    p.setAudioPaused(d, false);
    _ = try p.stepAudio(d, 4);
    try testing.expectEqual(@as(u32, 2), rec.calls);
}

test "a closed device's handle names nothing, and a reopen does not revive it" {
    const p = try open(testing.allocator);
    defer p.deinit();

    var rec: Recorder = .{};
    const stale = try p.openAudio(rec.config(2, 4));
    p.closeAudio(stale);
    try testing.expect(p.audioInfo(stale) == null);

    // The oldest bug in game audio, at the device level: unplugging headphones closes a
    // device and the next open takes its slot. A bare index would let a `setAudioPaused`
    // issued for the old one silence the new one (I1).
    const fresh = try p.openAudio(rec.config(1, 8));
    defer p.closeAudio(fresh);
    try testing.expectEqual(@as(u8, 1), p.audioInfo(fresh).?.channels);
    try testing.expect(p.audioInfo(stale) == null);

    // And every operation on the stale handle is a no-op rather than a hit on the slot.
    p.setAudioPaused(stale, true);
    try testing.expectEqual(@as(usize, 8), (try p.stepAudio(fresh, 8)).len);
    try testing.expectEqual(@as(u32, 1), rec.calls);
    p.closeAudio(stale);
}

test "a config no device could serve is refused rather than opened" {
    const p = try open(testing.allocator);
    defer p.deinit();

    var rec: Recorder = .{};
    // Untrusted input: these numbers come from a settings file, so they are validated at
    // the boundary rather than asserted, and refused before anything is allocated.
    try testing.expectError(error.AudioFormatUnsupported, p.openAudio(rec.config(0, 512)));
    try testing.expectError(error.AudioFormatUnsupported, p.openAudio(rec.config(2, 0)));
    try testing.expectError(
        error.AudioFormatUnsupported,
        p.openAudio(.{ .sample_rate = 0, .callback = Recorder.fill, .ctx = &rec }),
    );
}

test "a captured pointer reports relative motion and a position that does not move" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const w = try p.openWindow(.{});
    try p.setFocus(w, true);
    try p.pushEvent(.{ .mouse_moved = .{ .position = .init(100, 50), .position_pixels = .init(100, 50), .delta = .init(2, 2) } });
    p.pumpEvents();
    const before = p.captureInput();
    try testing.expect(!before.mouse.captured);

    try p.setPointerCapture(w, true);
    try testing.expectEqual(@as(?bool, true), p.pointerCaptured(w));
    // Asking for the state it already has is accepted, not an error.
    try p.setPointerCapture(w, true);

    // Further than any window is wide: a look that an edge would have stopped.
    try p.pushEvent(.{ .mouse_moved = .{ .position = .init(5000, 0), .delta = .init(4000, -10) } });
    try p.pushEvent(.{ .mouse_moved = .{ .position = .init(9000, 0), .delta = .init(4000, -10) } });
    p.pumpEvents();
    const held = p.captureInput();
    try testing.expect(held.mouse.captured);
    try testing.expectEqual(@as(f32, 8000), held.mouse.motion.x);
    try testing.expectEqual(@as(f32, -20), held.mouse.motion.y);
    try testing.expectEqual(before.mouse.position, held.mouse.position);
    try testing.expectEqual(before.mouse.position_pixels, held.mouse.position_pixels);

    // Plain data still: a snapshot copies and compares, capture included.
    const copy = held;
    try testing.expect(std.meta.eql(copy, held));

    try p.setPointerCapture(w, false);
    try p.setPointerCapture(w, false);
    try p.pushEvent(.{ .mouse_moved = .{ .position = .init(7, 8), .position_pixels = .init(7, 8), .delta = .init(1, 1) } });
    p.pumpEvents();
    const freed = p.captureInput();
    try testing.expect(!freed.mouse.captured);
    try testing.expectEqual(@as(f32, 7), freed.mouse.position.x);
}

test "losing keyboard focus releases the pointer, and regaining it does not take it back" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const w = try p.openWindow(.{});
    try p.setFocus(w, true);
    p.pumpEvents();
    _ = p.captureInput();

    try p.setPointerCapture(w, true);
    p.pumpEvents();
    try testing.expect(p.captureInput().mouse.captured);

    try p.setFocus(w, false);
    // Motion after the loss, in the same pump, is ordinary motion again.
    try p.pushEvent(.{ .mouse_moved = .{ .position = .init(33, 44), .position_pixels = .init(33, 44), .delta = .init(3, 4) } });
    p.pumpEvents();
    const lost = p.captureInput();
    try testing.expect(!lost.focused);
    try testing.expect(!lost.mouse.captured);
    try testing.expectEqual(@as(f32, 33), lost.mouse.position.x);
    try testing.expectEqual(@as(?bool, false), p.pointerCaptured(w));

    try p.setFocus(w, true);
    p.pumpEvents();
    const back = p.captureInput();
    try testing.expect(back.focused);
    try testing.expect(!back.mouse.captured);
}

test "setPointerCapture validates the window, and a closed window holds nothing" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    try testing.expectError(error.InvalidWindow, p.setPointerCapture(.none, true));

    const w = try p.openWindow(.{});
    try p.setPointerCapture(w, true);
    p.closeWindow(w);
    try testing.expectError(error.InvalidWindow, p.setPointerCapture(w, false));
    try testing.expectEqual(@as(?bool, null), p.pointerCaptured(w));
    p.pumpEvents();
    try testing.expect(!p.captureInput().mouse.captured);
}

/// One frame of captured motion through a platform, returning its snapshot.
fn moveOnce(p: *Platform, dx: f32) !input.InputSnapshot {
    try p.pushEvent(.{ .mouse_moved = .{ .delta = .init(dx, 0) } });
    p.pumpEvents();
    return p.captureInput();
}

test "captured motion is counts in raw, points in system, and points uncaptured" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const w = try p.openWindow(.{});
    try p.setFocus(w, true);

    const loose = try moveOnce(p, 3);
    try testing.expectEqual(input.MotionUnit.points, loose.mouse.motion_unit);

    // `raw` is the default: no call needed.
    try p.setPointerCapture(w, true);
    const raw = try moveOnce(p, 120);
    try testing.expect(raw.mouse.captured);
    try testing.expectEqual(input.MotionUnit.counts, raw.mouse.motion_unit);
    try testing.expectEqual(@as(f32, 120), raw.mouse.motion.x);

    p.setCapturedMotion(.system);
    const system = try moveOnce(p, 40);
    try testing.expectEqual(input.MotionUnit.points, system.mouse.motion_unit);
    try testing.expectEqual(@as(f32, 40), system.mouse.motion.x);

    p.setCapturedMotion(.raw);
    try testing.expectEqual(input.MotionUnit.counts, (try moveOnce(p, 1)).mouse.motion_unit);

    // Released, the same mode reports points again.
    try p.setPointerCapture(w, false);
    try testing.expectEqual(input.MotionUnit.points, (try moveOnce(p, 1)).mouse.motion_unit);
}

test "a backend that cannot honour raw reports points rather than calling them counts" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const w = try p.openWindow(.{});
    try p.setFocus(w, true);
    try p.setPointerCapture(w, true);

    p.setRawMotionAvailable(false);
    for ([_]input.MotionMode{ .raw, .system }) |mode| {
        p.setCapturedMotion(mode);
        const snap = try moveOnce(p, 9);
        try testing.expect(snap.mouse.captured);
        try testing.expectEqual(input.MotionUnit.points, snap.mouse.motion_unit);
    }

    p.setRawMotionAvailable(true);
    p.setCapturedMotion(.raw);
    try testing.expectEqual(input.MotionUnit.counts, (try moveOnce(p, 9)).mouse.motion_unit);
}

test "losing focus ends a capture's counts with it" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const w = try p.openWindow(.{});
    try p.setFocus(w, true);
    try p.setPointerCapture(w, true);
    try testing.expectEqual(input.MotionUnit.counts, (try moveOnce(p, 50)).mouse.motion_unit);

    // Counts, then the loss, then desktop motion in the same pump: the counts are dropped
    // rather than added to points.
    try p.pushEvent(.{ .mouse_moved = .{ .delta = .init(50, 0) } });
    try p.setFocus(w, false);
    try p.pushEvent(.{ .mouse_moved = .{ .delta = .init(2, 0) } });
    p.pumpEvents();
    const lost = p.captureInput();
    try testing.expect(!lost.mouse.captured);
    try testing.expectEqual(input.MotionUnit.points, lost.mouse.motion_unit);
    try testing.expectEqual(@as(f32, 2), lost.mouse.motion.x);
}

test "a key's label is its own name here, bounded, and empty for unknown" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    var buf: [key.label_capacity]u8 = undefined;
    try testing.expectEqualStrings("q", p.keyLabel(.q, &buf));
    try testing.expectEqualStrings("right_bracket", p.keyLabel(.right_bracket, &buf));
    try testing.expectEqualStrings("", p.keyLabel(.unknown, &buf));
    for (std.enums.values(key.Key)) |k| {
        const label = p.keyLabel(k, &buf);
        try testing.expect(label.len <= key.label_capacity);
        try testing.expect(std.unicode.utf8ValidateSlice(label));
        try testing.expectEqual(k == .unknown, label.len == 0);
    }
}

// -- gamepads ------------------------------------------------------------------------

test "scripted pads are seated by slot, and their buttons and axes reach the snapshot" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();

    const first = (try p.connectGamepad(41, .{})).?;
    const second = (try p.connectGamepad(7, .{ .kind = .playstation, .face = .{ .cross, .circle, .square, .triangle } })).?;
    try testing.expectEqual(@as(u32, 0), first.index);
    try testing.expectEqual(@as(u32, 1), second.index);
    // Not yet: like any event, a connection is seen at the next pump.
    try testing.expect(!p.captureInput().gamepads[0].connected);

    try p.setGamepadButton(41, .south, true);
    try p.setGamepadAxis(41, .left_y, -32768);
    try p.setGamepadAxis(7, .right_trigger, 32767);
    p.pumpEvents();
    var saw_added: u32 = 0;
    while (p.nextEvent()) |ev| if (ev == .gamepad_added) {
        saw_added += 1;
    };
    try testing.expectEqual(@as(u32, 2), saw_added);

    const snap = p.captureInput();
    const one = snap.gamepadState(first).?;
    try testing.expect(one.wasPressed(.south));
    // Pulled toward the player, which a device reports as positive: Foundry's -y.
    try testing.expectEqual(@as(f32, 1), one.axis(.left_y));
    const two = snap.gamepadState(second).?;
    try testing.expectEqual(gamepad.GamepadKind.playstation, two.kind);
    try testing.expectEqual(gamepad.ButtonLabel.circle, two.labelOf(.east));
    try testing.expectEqual(@as(f32, 1), two.axis(.right_trigger));
}

test "a fifth pad waits, takes the first slot freed, and a reconnect is a new handle" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    var handles: [gamepad.max_gamepads]gamepad.GamepadHandle = undefined;
    for (&handles, 0..) |*h, i| h.* = (try p.connectGamepad(@intCast(i + 1), .{})).?;
    try testing.expectEqual(@as(?gamepad.GamepadHandle, null), try p.connectGamepad(5, .{ .kind = .nintendo }));
    // A waiting pad's buttons go nowhere.
    try p.setGamepadButton(5, .north, true);
    try p.setGamepadButton(2, .east, true);
    p.pumpEvents();
    const before = p.captureInput();
    try testing.expect(before.gamepadState(handles[1]).?.isHeld(.east));
    for (before.gamepads) |pad| try testing.expect(!pad.isHeld(.north));

    try p.disconnectGamepad(2);
    p.pumpEvents();
    const after = p.captureInput();
    // The removed pad's button is released in the frame it leaves...
    // ...but the waiting pad took slot 1 in the same frame, so the slot is the new pad's now.
    try testing.expectEqual(@as(?*const gamepad.GamepadState, null), after.gamepadState(handles[1]));
    const fifth = after.gamepads[1];
    try testing.expect(fifth.connected);
    try testing.expectEqual(gamepad.GamepadKind.nintendo, fifth.kind);
    try testing.expect(!fifth.handle.eql(handles[1]));
    try testing.expect(!fifth.isHeld(.east));

    // Pad 4 reconnects: the lowest free slot, a generation it has not had before.
    try p.disconnectGamepad(4);
    const back = (try p.connectGamepad(4, .{})).?;
    try testing.expectEqual(handles[3].index, back.index);
    try testing.expectEqual(handles[3].generation + 1, back.generation);
}

test "a removed pad with nothing waiting reports its held buttons released" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const pad = (try p.connectGamepad(3, .{})).?;
    try p.setGamepadButton(3, .left_shoulder, true);
    try p.setGamepadAxis(3, .right_x, 20000);
    p.pumpEvents();
    _ = p.captureInput();

    try p.disconnectGamepad(3);
    p.pumpEvents();
    const left = p.captureInput().gamepads[pad.index];
    try testing.expect(!left.connected);
    try testing.expect(left.wasReleased(.left_shoulder));
    try testing.expectEqual(@as(f32, 0), left.axis(.right_x));
}

test "rumble is refused for a stale handle, an out-of-range request, or a pad without motors" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const pad = (try p.connectGamepad(1, .{})).?;
    try p.setGamepadRumble(pad, 0.25, 1, 400);
    try testing.expectEqual(Rumble{ .low = 0.25, .high = 1, .duration_ms = 400 }, p.lastRumble(pad).?);

    try testing.expectError(error.InvalidRumble, p.setGamepadRumble(pad, 1.5, 0, 100));
    try testing.expectError(error.InvalidRumble, p.setGamepadRumble(pad, 0, -0.1, 100));
    try testing.expectError(error.InvalidRumble, p.setGamepadRumble(pad, std.math.nan(f32), 0, 100));
    try testing.expectError(error.InvalidRumble, p.setGamepadRumble(pad, 0, 0, gamepad.max_rumble_ms + 1));
    // A refusal leaves the last accepted request.
    try testing.expectEqual(@as(f32, 0.25), p.lastRumble(pad).?.low);
    // Zeros stop the motors, and are accepted.
    try p.setGamepadRumble(pad, 0, 0, 0);

    try testing.expectError(error.InvalidGamepad, p.setGamepadRumble(.none, 0.5, 0.5, 100));
    try p.disconnectGamepad(1);
    try testing.expectError(error.InvalidGamepad, p.setGamepadRumble(pad, 0.5, 0.5, 100));
    const again = (try p.connectGamepad(1, .{})).?;
    try testing.expectError(error.InvalidGamepad, p.setGamepadRumble(pad, 0.5, 0.5, 100));
    try testing.expectEqual(@as(?Rumble, null), p.lastRumble(again));

    const still = (try p.connectGamepad(2, .{ .rumble = false })).?;
    try testing.expectError(error.Unsupported, p.setGamepadRumble(still, 0.5, 0.5, 100));
}

test "losing focus releases the pads' buttons and zeroes their axes" {
    const p = try Platform.init(testing.allocator, .{});
    defer p.deinit();
    const w = try p.openWindow(.{});
    try p.setFocus(w, true);
    const pad = (try p.connectGamepad(9, .{})).?;
    try p.setGamepadButton(9, .south, true);
    try p.setGamepadAxis(9, .left_x, 32767);
    p.pumpEvents();
    try testing.expect(p.captureInput().gamepadState(pad).?.isHeld(.south));

    try p.setFocus(w, false);
    p.pumpEvents();
    const lost = p.captureInput().gamepadState(pad).?;
    try testing.expect(lost.wasReleased(.south) and !lost.isHeld(.south));
    try testing.expectEqual(@as(f32, 0), lost.axis(.left_x));
}

test "with gamepads off, a pad is never seated" {
    const p = try Platform.init(testing.allocator, .{ .gamepads = false });
    defer p.deinit();
    try testing.expectEqual(@as(?gamepad.GamepadHandle, null), try p.connectGamepad(1, .{}));
    try p.setGamepadButton(1, .south, true);
    p.pumpEvents();
    try testing.expect(p.captureInput().isIdle());
}

test "the same pad script gives the same snapshots" {
    var snaps: [2][3]input.InputSnapshot = undefined;
    for (&snaps) |*run| {
        const p = try Platform.init(testing.allocator, .{});
        defer p.deinit();
        _ = try p.connectGamepad(30, .{});
        _ = try p.connectGamepad(31, .{ .kind = .nintendo, .face = .{ .b, .a, .y, .x } });
        try p.setGamepadAxis(31, .left_x, -1200);
        p.pumpEvents();
        run[0] = p.captureInput();
        try p.setGamepadButton(30, .dpad_down, true);
        try p.disconnectGamepad(30);
        p.pumpEvents();
        run[1] = p.captureInput();
        _ = try p.connectGamepad(30, .{});
        p.pumpEvents();
        run[2] = p.captureInput();
    }
    try testing.expectEqualDeep(snaps[0], snaps[1]);
}
