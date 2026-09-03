//! The SDL3 platform backend.
//!
//! **This is the only file in Foundry that may name an SDL type** (ADR-0002, I7). The
//! build graph enforces it: no other module is linked against SDL, so no other module
//! can reference it even by accident.
//!
//! Its job is translation, not abstraction. Foundry's interface was designed against
//! the question *"would this still be the right shape if it were hand-written Cocoa and
//! Win32?"*, and this file's role is to answer it in SDL's terms — mapping SDL's
//! scancodes to Foundry's keys, SDL's several resize events to Foundry's one, SDL's
//! button numbering to Foundry's. Where SDL offers something Foundry does not model,
//! it is dropped here rather than passed upward to be ignored.
//!
//! Everything reachable through this file is deliberate. SDL's renderer, its GPU
//! abstraction, `SDL_image`, `SDL_ttf` and `SDL_mixer` are all excluded: the renderer is
//! Foundry's own (ADR-0003) and assets are Foundry's (ADR-0006).
//!
//! Design: `docs/design/platform-interface.md`

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const event = @import("../event.zig");
const input = @import("../input.zig");
const interface = @import("../interface.zig");
const key = @import("../key.zig");
const win = @import("../window.zig");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.platform);

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

/// The last error SDL recorded, for logging. Never surfaced to callers as a string:
/// Foundry's error sets are narrow on purpose, and an SDL message in an engine
/// signature would be exactly the leak this layer exists to prevent.
fn sdlError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

const WindowState = struct {
    ptr: *c.SDL_Window,
    id: c.SDL_WindowID,
    surface_kind: win.SurfaceKind,
    /// Owned by us, and destroyed *before* the window, as SDL requires.
    metal_view: c.SDL_MetalView = null,

    /// What was last reported upward, so that SDL's several overlapping resize events
    /// collapse into one Foundry event only when something actually changed.
    reported_logical: win.Size = .{},
    reported_pixel: win.Size = .{},

    fn logicalSize(self: WindowState) win.Size {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.ptr, &w, &h);
        return .{ .width = @intCast(@max(0, w)), .height = @intCast(@max(0, h)) };
    }

    fn pixelSize(self: WindowState) win.Size {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.ptr, &w, &h);
        return .{ .width = @intCast(@max(0, w)), .height = @intCast(@max(0, h)) };
    }

    fn info(self: WindowState) win.WindowInfo {
        const logical = self.logicalSize();
        const pixels = self.pixelSize();
        const flags = c.SDL_GetWindowFlags(self.ptr);
        return .{
            .logical_size = logical,
            .pixel_size = pixels,
            .scale = scaleOf(logical, pixels),
            .focused = (flags & c.SDL_WINDOW_INPUT_FOCUS) != 0,
            .minimized = (flags & c.SDL_WINDOW_MINIMIZED) != 0,
        };
    }
};

/// Derived from the two sizes rather than from `SDL_GetWindowPixelDensity`, so that the
/// reported scale is always exactly the ratio a caller would compute itself. A window
/// with a zero dimension (minimized on some systems) reports 1 instead of dividing by it.
fn scaleOf(logical: win.Size, pixels: win.Size) f32 {
    if (logical.width == 0) return 1.0;
    return @as(f32, @floatFromInt(pixels.width)) / @as(f32, @floatFromInt(logical.width));
}

pub const Platform = struct {
    gpa: Allocator,
    windows: core.HandlePool(win.Window, WindowState) = .empty,

    ready: std.ArrayList(event.Event) = .empty,
    cursor: usize = 0,
    accumulator: input.Accumulator = .init,

    pub fn init(gpa: Allocator, options: interface.InitOptions) interface.InitError!*Platform {
        _ = options;

        // Video implies events. Audio is not requested: the audio decision is postponed
        // to M5, and initialising a subsystem nothing uses would open a device and a
        // thread for nothing.
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            log.err("SDL_Init failed: {s}", .{sdlError()});
            return error.PlatformInitFailed;
        }
        errdefer c.SDL_Quit();

        const self = try gpa.create(Platform);
        self.* = .{ .gpa = gpa };

        log.info("platform backend: SDL3 {d}.{d}.{d}, video driver '{s}'", .{
            c.SDL_VERSIONNUM_MAJOR(c.SDL_GetVersion()),
            c.SDL_VERSIONNUM_MINOR(c.SDL_GetVersion()),
            c.SDL_VERSIONNUM_MICRO(c.SDL_GetVersion()),
            c.SDL_GetCurrentVideoDriver(),
        });
        return self;
    }

    pub fn deinit(self: *Platform) void {
        const gpa = self.gpa;

        // Windows first, then SDL: no platform resource may require another subsystem
        // to still be alive in order to be destroyed, and that applies within this one.
        var it = self.windows.iterator();
        while (it.next()) |entry| destroyWindow(entry.value);
        self.windows.deinit(gpa);

        self.ready.deinit(gpa);
        c.SDL_Quit();
        gpa.destroy(self);
    }

    fn destroyWindow(state: *WindowState) void {
        // SDL requires the Metal view to go before the window it belongs to.
        if (state.metal_view != null) c.SDL_Metal_DestroyView(state.metal_view);
        c.SDL_DestroyWindow(state.ptr);
    }

    pub fn openWindow(self: *Platform, config: win.WindowConfig) interface.WindowError!win.WindowHandle {
        var flags: c.SDL_WindowFlags = 0;
        if (config.resizable) flags |= c.SDL_WINDOW_RESIZABLE;
        if (config.high_dpi) flags |= c.SDL_WINDOW_HIGH_PIXEL_DENSITY;

        switch (config.surface) {
            .none => {},
            .metal_layer => {
                // A Metal window is not a window that later grows a CAMetalLayer, which
                // is why the surface kind is part of the window's configuration.
                if (!metal_supported) return error.SurfaceUnavailable;
                flags |= c.SDL_WINDOW_METAL;
            },
            // These arrive with the backends that consume them. Reporting rather than
            // asserting, because asking for the wrong surface is a configuration
            // mistake, not a programmer error.
            .win32_hwnd, .xlib_window, .wayland_surface => {
                log.err("surface kind '{t}' is not implemented by the SDL3 backend yet", .{config.surface});
                return error.SurfaceUnavailable;
            },
        }

        // SDL wants a NUL-terminated title; Foundry's strings are not.
        const title = self.gpa.dupeZ(u8, config.title) catch return error.OutOfMemory;
        defer self.gpa.free(title);

        const ptr = c.SDL_CreateWindow(
            title.ptr,
            @intCast(config.logical_width),
            @intCast(config.logical_height),
            flags,
        ) orelse {
            log.err("SDL_CreateWindow failed: {s}", .{sdlError()});
            return error.WindowCreationFailed;
        };
        errdefer c.SDL_DestroyWindow(ptr);

        var state: WindowState = .{
            .ptr = ptr,
            .id = c.SDL_GetWindowID(ptr),
            .surface_kind = config.surface,
        };

        if (config.surface == .metal_layer) {
            state.metal_view = c.SDL_Metal_CreateView(ptr) orelse {
                log.err("SDL_Metal_CreateView failed: {s}", .{sdlError()});
                return error.SurfaceUnavailable;
            };
        }
        errdefer if (state.metal_view != null) c.SDL_Metal_DestroyView(state.metal_view);

        state.reported_logical = state.logicalSize();
        state.reported_pixel = state.pixelSize();

        // Text input is enabled for the window's lifetime. SDL3 requires it explicitly,
        // and without it `text_input` events never arrive at all. Per-window IME control
        // — enabling it only while a text field has focus — is a UI concern that arrives
        // with the UI system (M6); until then, always-on is the behaviour that makes the
        // event variant real rather than dead.
        _ = c.SDL_StartTextInput(ptr);

        return self.windows.add(self.gpa, state);
    }

    pub fn closeWindow(self: *Platform, handle: win.WindowHandle) void {
        const state = self.windows.get(handle) orelse return;
        destroyWindow(state);
        _ = self.windows.remove(handle);
    }

    pub fn windowInfo(self: *Platform, handle: win.WindowHandle) ?win.WindowInfo {
        const state = self.windows.getConst(handle) orelse return null;
        return state.info();
    }

    /// Asks the window manager for a new **logical** size.
    ///
    /// SDL applies this asynchronously on some platforms and synchronously on others, so
    /// the size is deliberately *not* read back here. The window manager's
    /// `SDL_EVENT_WINDOW_RESIZED` is what `pumpEvents` turns into Foundry's
    /// `window_resized`, and that is the one path a resize takes whether it came from
    /// here or from a user dragging an edge. A caller that trusted a read-back instead
    /// would work on this machine and desynchronise on the next one.
    pub fn setWindowSize(self: *Platform, handle: win.WindowHandle, logical: win.Size) interface.WindowError!void {
        if (logical.isEmpty()) return error.InvalidWindowSize;
        const state = self.windows.getConst(handle) orelse return error.InvalidWindow;
        if (!c.SDL_SetWindowSize(state.ptr, @intCast(logical.width), @intCast(logical.height))) {
            // The window manager declining is not a programmer error — a tiling
            // compositor may simply refuse — so it is reported and the caller carries on.
            log.warn("SDL_SetWindowSize({d}x{d}) failed: {s}", .{ logical.width, logical.height, sdlError() });
            return error.WindowResizeRefused;
        }
    }

    pub fn nativeSurface(self: *Platform, handle: win.WindowHandle) ?win.NativeSurfaceHandle {
        const state = self.windows.getConst(handle) orelse return null;
        return switch (state.surface_kind) {
            .metal_layer => .{
                .kind = .metal_layer,
                // The CAMetalLayer. `rhi` interprets this; `platform` never does, and
                // has no idea what Metal is (ADR-0002, ADR-0012).
                .ptr = c.SDL_Metal_GetLayer(state.metal_view),
            },
            else => .none,
        };
    }

    /// Looks up the Foundry handle for an SDL window id.
    ///
    /// A linear scan: there is one window, and the editor (M6+) might make it a few.
    /// An index would be more code than the scan costs.
    fn handleForId(self: *Platform, id: c.SDL_WindowID) win.WindowHandle {
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            if (entry.value.id == id) return entry.id;
        }
        return .none;
    }

    pub fn pumpEvents(self: *Platform) void {
        self.ready.clearRetainingCapacity();
        self.cursor = 0;

        var raw: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&raw)) {
            self.translate(raw);
        }
    }

    fn emit(self: *Platform, ev: event.Event) void {
        self.accumulator.apply(ev);
        self.ready.append(self.gpa, ev) catch {
            // Dropping input silently would be worse than saying so: a lost key-up
            // leaves the game holding a key forever, which is exactly the class of bug
            // the accumulator's focus handling exists to prevent.
            log.err("dropped a platform event: out of memory", .{});
        };
    }

    fn translate(self: *Platform, raw: c.SDL_Event) void {
        switch (raw.type) {
            c.SDL_EVENT_QUIT => self.emit(.quit_requested),

            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.emit(.{
                .window_closed = .{ .window = self.handleForId(raw.window.windowID) },
            }),
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => self.emit(.{
                .window_focus_gained = .{ .window = self.handleForId(raw.window.windowID) },
            }),
            c.SDL_EVENT_WINDOW_FOCUS_LOST => self.emit(.{
                .window_focus_lost = .{ .window = self.handleForId(raw.window.windowID) },
            }),

            // SDL reports a logical resize, a pixel-size change and a display-scale
            // change separately, and a single drag between monitors can produce all
            // three. Foundry has one event carrying both sizes, because every consumer
            // reacts identically — so these collapse, and only when something moved.
            c.SDL_EVENT_WINDOW_RESIZED,
            c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
            c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
            => self.emitResizeIfChanged(raw.window.windowID),

            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                const k = keyFromScancode(raw.key.scancode);
                const payload: event.KeyEvent = .{
                    .key = k,
                    .modifiers = modifiersFromSdl(raw.key.mod),
                    .repeat = raw.key.repeat,
                };
                self.emit(if (raw.key.down)
                    .{ .key_down = payload }
                else
                    .{ .key_up = payload });
            },

            c.SDL_EVENT_TEXT_INPUT => {
                // SDL owns this string and it expires; Foundry's event carries its own
                // copy. Invalid UTF-8 is dropped rather than propagated — text from an
                // input method is external input, validated, not asserted.
                const text = std.mem.span(raw.text.text);
                if (event.TextInput.fromSlice(text)) |payload| {
                    self.emit(.{ .text_input = payload });
                } else {
                    log.warn("dropped text input that was not valid UTF-8", .{});
                }
            },

            c.SDL_EVENT_MOUSE_MOTION => {
                const density = self.pixelDensity(raw.motion.windowID);
                self.emit(.{ .mouse_moved = .{
                    .position = .init(raw.motion.x, raw.motion.y),
                    .position_pixels = .init(raw.motion.x * density, raw.motion.y * density),
                    .delta = .init(raw.motion.xrel, raw.motion.yrel),
                } });
            },

            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                const button = mouseButtonFromSdl(raw.button.button) orelse return;
                const payload: event.MouseButtonEvent = .{
                    .button = button,
                    .modifiers = modifiersFromSdl(c.SDL_GetModState()),
                    .position = .init(raw.button.x, raw.button.y),
                };
                self.emit(if (raw.button.down)
                    .{ .mouse_button_down = payload }
                else
                    .{ .mouse_button_up = payload });
            },

            c.SDL_EVENT_MOUSE_WHEEL => {
                // SDL may report the axes inverted depending on OS settings, and says so
                // rather than normalising. Foundry's contract is fixed — positive y
                // scrolls away from the user — so it is normalised here.
                const sign: f32 = if (raw.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                self.emit(.{ .mouse_wheel = .{
                    .delta = .init(raw.wheel.x * sign, raw.wheel.y * sign),
                } });
            },

            // Everything else SDL reports, Foundry has no use for: joystick and gamepad
            // events (deferred to M5), pen and touch, audio and camera device changes,
            // clipboard, drop, render targets reset. Dropped here rather than passed
            // upward to be ignored.
            else => {},
        }
    }

    fn emitResizeIfChanged(self: *Platform, id: c.SDL_WindowID) void {
        const handle = self.handleForId(id);
        const state = self.windows.get(handle) orelse return;

        const logical = state.logicalSize();
        const pixels = state.pixelSize();
        if (logical.eql(state.reported_logical) and pixels.eql(state.reported_pixel)) return;

        state.reported_logical = logical;
        state.reported_pixel = pixels;
        self.emit(.{ .window_resized = .{
            .window = handle,
            .logical_size = logical,
            .pixel_size = pixels,
            .scale = scaleOf(logical, pixels),
        } });
    }

    fn pixelDensity(self: *Platform, id: c.SDL_WindowID) f32 {
        const state = self.windows.getConst(self.handleForId(id)) orelse return 1.0;
        return scaleOf(state.logicalSize(), state.pixelSize());
    }

    pub fn nextEvent(self: *Platform) ?event.Event {
        if (self.cursor >= self.ready.items.len) return null;
        defer self.cursor += 1;
        return self.ready.items[self.cursor];
    }

    pub fn captureInput(self: *Platform) input.InputSnapshot {
        return self.accumulator.capture();
    }

    /// Monotonic time since SDL was initialised.
    ///
    /// `SDL_GetTicksNS` and not the wall clock: the origin is arbitrary and it never
    /// goes backwards, which is what `core.time.Instant` promises. Wall-clock time is a
    /// different call on a different object, returning a different type (`Os`), so the
    /// two cannot be mixed up (I9).
    pub fn now(self: *Platform) core.time.Instant {
        _ = self;
        return .{ .ns = @intCast(c.SDL_GetTicksNS()) };
    }
};

/// Whether this build can produce a `CAMetalLayer`. Compile-time, because the answer is
/// a property of the target rather than of the machine.
const metal_supported = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .visionos => true,
    else => false,
};

fn modifiersFromSdl(mod: c.SDL_Keymod) key.Modifiers {
    return .{
        .shift = (mod & c.SDL_KMOD_SHIFT) != 0,
        .ctrl = (mod & c.SDL_KMOD_CTRL) != 0,
        .alt = (mod & c.SDL_KMOD_ALT) != 0,
        .super = (mod & c.SDL_KMOD_GUI) != 0,
        .caps_lock = (mod & c.SDL_KMOD_CAPS) != 0,
        .num_lock = (mod & c.SDL_KMOD_NUM) != 0,
    };
}

/// SDL numbers buttons from 1, in the order left, **middle**, right — not the order the
/// names are usually said in. Getting this wrong swaps right-click and middle-click,
/// which is the sort of bug that survives a long time because both still "work".
fn mouseButtonFromSdl(button: u8) ?key.MouseButton {
    return switch (button) {
        c.SDL_BUTTON_LEFT => .left,
        c.SDL_BUTTON_MIDDLE => .middle,
        c.SDL_BUTTON_RIGHT => .right,
        c.SDL_BUTTON_X1 => .back,
        c.SDL_BUTTON_X2 => .forward,
        // Mice with more buttons than Foundry names. Dropped, not invented.
        else => null,
    };
}

/// Maps SDL's physical scancode to Foundry's key.
///
/// Both are physical-position models, so this is a renaming rather than a translation —
/// which is the point: Foundry's enum is smaller and stable, and SDL's is neither
/// Foundry's to version nor safe to persist. Anything Foundry does not name becomes
/// `unknown`, which the input accumulator discards.
fn keyFromScancode(scancode: c.SDL_Scancode) key.Key {
    return switch (scancode) {
        c.SDL_SCANCODE_A => .a,
        c.SDL_SCANCODE_B => .b,
        c.SDL_SCANCODE_C => .c,
        c.SDL_SCANCODE_D => .d,
        c.SDL_SCANCODE_E => .e,
        c.SDL_SCANCODE_F => .f,
        c.SDL_SCANCODE_G => .g,
        c.SDL_SCANCODE_H => .h,
        c.SDL_SCANCODE_I => .i,
        c.SDL_SCANCODE_J => .j,
        c.SDL_SCANCODE_K => .k,
        c.SDL_SCANCODE_L => .l,
        c.SDL_SCANCODE_M => .m,
        c.SDL_SCANCODE_N => .n,
        c.SDL_SCANCODE_O => .o,
        c.SDL_SCANCODE_P => .p,
        c.SDL_SCANCODE_Q => .q,
        c.SDL_SCANCODE_R => .r,
        c.SDL_SCANCODE_S => .s,
        c.SDL_SCANCODE_T => .t,
        c.SDL_SCANCODE_U => .u,
        c.SDL_SCANCODE_V => .v,
        c.SDL_SCANCODE_W => .w,
        c.SDL_SCANCODE_X => .x,
        c.SDL_SCANCODE_Y => .y,
        c.SDL_SCANCODE_Z => .z,

        c.SDL_SCANCODE_0 => .digit_0,
        c.SDL_SCANCODE_1 => .digit_1,
        c.SDL_SCANCODE_2 => .digit_2,
        c.SDL_SCANCODE_3 => .digit_3,
        c.SDL_SCANCODE_4 => .digit_4,
        c.SDL_SCANCODE_5 => .digit_5,
        c.SDL_SCANCODE_6 => .digit_6,
        c.SDL_SCANCODE_7 => .digit_7,
        c.SDL_SCANCODE_8 => .digit_8,
        c.SDL_SCANCODE_9 => .digit_9,

        c.SDL_SCANCODE_GRAVE => .grave,
        c.SDL_SCANCODE_MINUS => .minus,
        c.SDL_SCANCODE_EQUALS => .equal,
        c.SDL_SCANCODE_LEFTBRACKET => .left_bracket,
        c.SDL_SCANCODE_RIGHTBRACKET => .right_bracket,
        c.SDL_SCANCODE_BACKSLASH => .backslash,
        c.SDL_SCANCODE_SEMICOLON => .semicolon,
        c.SDL_SCANCODE_APOSTROPHE => .apostrophe,
        c.SDL_SCANCODE_COMMA => .comma,
        c.SDL_SCANCODE_PERIOD => .period,
        c.SDL_SCANCODE_SLASH => .slash,

        c.SDL_SCANCODE_ESCAPE => .escape,
        c.SDL_SCANCODE_RETURN => .enter,
        c.SDL_SCANCODE_TAB => .tab,
        c.SDL_SCANCODE_SPACE => .space,
        c.SDL_SCANCODE_BACKSPACE => .backspace,
        c.SDL_SCANCODE_DELETE => .delete,
        c.SDL_SCANCODE_INSERT => .insert,

        c.SDL_SCANCODE_LEFT => .left,
        c.SDL_SCANCODE_RIGHT => .right,
        c.SDL_SCANCODE_UP => .up,
        c.SDL_SCANCODE_DOWN => .down,
        c.SDL_SCANCODE_HOME => .home,
        c.SDL_SCANCODE_END => .end,
        c.SDL_SCANCODE_PAGEUP => .page_up,
        c.SDL_SCANCODE_PAGEDOWN => .page_down,

        c.SDL_SCANCODE_LSHIFT => .left_shift,
        c.SDL_SCANCODE_RSHIFT => .right_shift,
        c.SDL_SCANCODE_LCTRL => .left_ctrl,
        c.SDL_SCANCODE_RCTRL => .right_ctrl,
        c.SDL_SCANCODE_LALT => .left_alt,
        c.SDL_SCANCODE_RALT => .right_alt,
        c.SDL_SCANCODE_LGUI => .left_super,
        c.SDL_SCANCODE_RGUI => .right_super,
        c.SDL_SCANCODE_CAPSLOCK => .caps_lock,

        c.SDL_SCANCODE_F1 => .f1,
        c.SDL_SCANCODE_F2 => .f2,
        c.SDL_SCANCODE_F3 => .f3,
        c.SDL_SCANCODE_F4 => .f4,
        c.SDL_SCANCODE_F5 => .f5,
        c.SDL_SCANCODE_F6 => .f6,
        c.SDL_SCANCODE_F7 => .f7,
        c.SDL_SCANCODE_F8 => .f8,
        c.SDL_SCANCODE_F9 => .f9,
        c.SDL_SCANCODE_F10 => .f10,
        c.SDL_SCANCODE_F11 => .f11,
        c.SDL_SCANCODE_F12 => .f12,

        c.SDL_SCANCODE_KP_0 => .kp_0,
        c.SDL_SCANCODE_KP_1 => .kp_1,
        c.SDL_SCANCODE_KP_2 => .kp_2,
        c.SDL_SCANCODE_KP_3 => .kp_3,
        c.SDL_SCANCODE_KP_4 => .kp_4,
        c.SDL_SCANCODE_KP_5 => .kp_5,
        c.SDL_SCANCODE_KP_6 => .kp_6,
        c.SDL_SCANCODE_KP_7 => .kp_7,
        c.SDL_SCANCODE_KP_8 => .kp_8,
        c.SDL_SCANCODE_KP_9 => .kp_9,
        c.SDL_SCANCODE_KP_DIVIDE => .kp_divide,
        c.SDL_SCANCODE_KP_MULTIPLY => .kp_multiply,
        c.SDL_SCANCODE_KP_MINUS => .kp_minus,
        c.SDL_SCANCODE_KP_PLUS => .kp_plus,
        c.SDL_SCANCODE_KP_ENTER => .kp_enter,
        c.SDL_SCANCODE_KP_PERIOD => .kp_period,
        c.SDL_SCANCODE_KP_EQUALS => .kp_equal,
        c.SDL_SCANCODE_NUMLOCKCLEAR => .num_lock,

        c.SDL_SCANCODE_PRINTSCREEN => .print_screen,
        c.SDL_SCANCODE_SCROLLLOCK => .scroll_lock,
        c.SDL_SCANCODE_PAUSE => .pause,
        c.SDL_SCANCODE_APPLICATION => .menu,

        else => .unknown,
    };
}

// -- tests ---------------------------------------------------------------------------
//
// These run headlessly: nothing here calls SDL_Init, so the suite does not need a
// display. Anything that would need a window belongs in a sample, not a unit test.

const testing = std.testing;

test "the SDL3 backend satisfies the interface" {
    comptime interface.check(@This(), "sdl3");
}

test "every Foundry key is reachable from some scancode" {
    // The mapping is only useful if it is total in the direction that matters. Without
    // this, adding a key to `key.Key` and forgetting the scancode arm would leave a key
    // that can be bound in a config file but never actually pressed.
    var reached = key.empty_keys;
    var scancode: c.SDL_Scancode = 0;
    while (scancode < c.SDL_SCANCODE_COUNT) : (scancode += 1) {
        key.setKey(&reached, keyFromScancode(scancode), true);
    }

    var missing: usize = 0;
    for (std.enums.values(key.Key)) |k| {
        if (k == .unknown) continue;
        if (!key.keyIsSet(reached, k)) {
            std.debug.print("no scancode maps to key '{s}'\n", .{k.name()});
            missing += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "the scancode mapping is injective" {
    // Two scancodes mapping to one key would make a physical key un-bindable and its
    // twin fire twice. Only `unknown` may be produced more than once.
    var seen = key.empty_keys;
    var scancode: c.SDL_Scancode = 0;
    while (scancode < c.SDL_SCANCODE_COUNT) : (scancode += 1) {
        const k = keyFromScancode(scancode);
        if (k == .unknown) continue;
        try testing.expect(!key.keyIsSet(seen, k));
        key.setKey(&seen, k, true);
    }
}

test "unmapped scancodes become unknown, not a wrong key" {
    // SDL_SCANCODE_UNKNOWN, and a scancode Foundry deliberately does not name.
    try testing.expectEqual(key.Key.unknown, keyFromScancode(c.SDL_SCANCODE_UNKNOWN));
    try testing.expectEqual(key.Key.unknown, keyFromScancode(c.SDL_SCANCODE_KP_EQUALSAS400));
}

test "WASD is the physical cluster, whatever the layout prints on it" {
    // The whole reason keys are physical: these four scancodes are the same four
    // positions on QWERTY, AZERTY and Dvorak.
    try testing.expectEqual(key.Key.w, keyFromScancode(c.SDL_SCANCODE_W));
    try testing.expectEqual(key.Key.a, keyFromScancode(c.SDL_SCANCODE_A));
    try testing.expectEqual(key.Key.s, keyFromScancode(c.SDL_SCANCODE_S));
    try testing.expectEqual(key.Key.d, keyFromScancode(c.SDL_SCANCODE_D));
}

test "mouse buttons keep SDL's numbering straight" {
    // SDL orders them left, middle, right. Swapping the last two is a bug that survives
    // a long time, because both buttons still do something.
    try testing.expectEqual(key.MouseButton.left, mouseButtonFromSdl(c.SDL_BUTTON_LEFT).?);
    try testing.expectEqual(key.MouseButton.middle, mouseButtonFromSdl(c.SDL_BUTTON_MIDDLE).?);
    try testing.expectEqual(key.MouseButton.right, mouseButtonFromSdl(c.SDL_BUTTON_RIGHT).?);
    try testing.expectEqual(key.MouseButton.back, mouseButtonFromSdl(c.SDL_BUTTON_X1).?);
    try testing.expectEqual(key.MouseButton.forward, mouseButtonFromSdl(c.SDL_BUTTON_X2).?);
    try testing.expectEqual(@as(?key.MouseButton, null), mouseButtonFromSdl(9));
}

test "modifier translation" {
    try testing.expect(modifiersFromSdl(c.SDL_KMOD_NONE).eql(.none));

    // Either side of a modifier reports the same flag.
    try testing.expect(modifiersFromSdl(c.SDL_KMOD_LSHIFT).shift);
    try testing.expect(modifiersFromSdl(c.SDL_KMOD_RSHIFT).shift);
    try testing.expect(modifiersFromSdl(c.SDL_KMOD_LGUI).super);

    const both = modifiersFromSdl(c.SDL_KMOD_LCTRL | c.SDL_KMOD_CAPS);
    try testing.expect(both.ctrl);
    try testing.expect(both.caps_lock);
    try testing.expect(!both.alt);
}

test "scale is the ratio of the two sizes, and never divides by zero" {
    try testing.expectEqual(@as(f32, 2.0), scaleOf(.{ .width = 800, .height = 600 }, .{ .width = 1600, .height = 1200 }));
    try testing.expectEqual(@as(f32, 1.0), scaleOf(.{ .width = 800, .height = 600 }, .{ .width = 800, .height = 600 }));
    try testing.expectEqual(@as(f32, 1.0), scaleOf(.{ .width = 0, .height = 0 }, .{ .width = 0, .height = 0 }));
}
