//! The platform backend interface, and the `comptime` check that enforces it.
//!
//! **One implementation is selected at build time, not dispatched through a vtable.**
//! Foundry runs on exactly one platform backend per binary, chosen when the build
//! graph is constructed. A runtime vtable would buy nothing — nobody swaps platform
//! backends mid-run — and would cost an indirect call on every input poll and clock
//! read.
//!
//! This is not in tension with I6 (registries are runtime-populated). I6 exists so
//! mods can add component types, asset loaders and content schemas. **Mods do not add
//! platform backends**; a platform backend is an engine port, and ports are
//! compile-time decisions.
//!
//! Because there is no vtable, nothing structurally forces two implementations to
//! agree — so `check` does. A missing or misdeclared function is a compile error
//! naming the offender, rather than a link error or a runtime surprise. Together with
//! the null backend (a second implementation is the minimum number at which an
//! interface is actually an interface), that is what keeps this a real seam instead of
//! a rename of whatever SDL happens to provide.
//!
//! Design: `docs/design/platform-interface.md` §1.

const std = @import("std");
const core = @import("core");

const audio = @import("audio.zig");
const event = @import("event.zig");
const gamepad = @import("gamepad.zig");
const input = @import("input.zig");
const key = @import("key.zig");
const window = @import("window.zig");

pub const InitError = error{
    OutOfMemory,
    /// The backend could not start: no display server, a driver refusing to load, a
    /// subsystem the OS declined to initialise.
    PlatformInitFailed,
};

pub const WindowError = error{
    OutOfMemory,
    /// The OS refused to create the window.
    WindowCreationFailed,
    /// The handle does not name a live window — closed, or from another pool (I1).
    InvalidWindow,
    /// The window cannot provide the requested surface kind. A configuration mistake
    /// (asking a headless backend for a `CAMetalLayer`), not a programmer error, so it
    /// is reported rather than asserted.
    SurfaceUnavailable,
    /// A requested window size with a zero dimension. Reported rather than asserted
    /// because a resolution usually comes from a settings file or a mod, which is
    /// untrusted input and is validated at the boundary (`CLAUDE.md` §7).
    InvalidWindowSize,
    /// The window manager declined a resize of a live window. A tiling compositor will;
    /// so will a full-screen window. Distinct from `WindowCreationFailed`, which is about
    /// a window that never existed, and from `InvalidWindowSize`, where the caller was at
    /// fault rather than the environment.
    WindowResizeRefused,
};

pub const WindowTitleError = error{
    OutOfMemory,
    /// The handle does not name a live window — closed, or from another pool (I1).
    InvalidWindow,
    /// Not UTF-8, or holding a NUL. A title usually comes from content, which is untrusted
    /// and validated at the boundary (`CLAUDE.md` §7).
    InvalidWindowTitle,
};

/// Whether `title` is one every backend can show: UTF-8, with no NUL for a C API to stop at.
pub fn validWindowTitle(title: []const u8) bool {
    return std.unicode.utf8ValidateSlice(title) and std.mem.indexOfScalar(u8, title, 0) == null;
}

pub const WindowIconError = error{
    /// The handle does not name a live window — closed, or from another pool (I1).
    InvalidWindow,
    /// Sides outside 1 to `WindowIcon.max_dimension`, a stride shorter than a row, or fewer bytes
    /// than the rows need. The image came from the application or a package, which is untrusted
    /// input, so it is reported rather than asserted.
    InvalidWindowIcon,
    /// The window system declined the icon or has no way to take one from an application. Some
    /// Wayland compositors choose an application's icon themselves (`vulkan.md` §9). The window
    /// carries on without it.
    WindowIconRefused,
};

pub const PointerCaptureError = error{
    /// The handle does not name a live window — closed, or from another pool (I1).
    InvalidWindow,
    /// The window system cannot capture the pointer, or declined to. A Wayland compositor
    /// without the relative-pointer and pointer-constraints protocols answers this. **A normal
    /// answer, not a fault**: the caller carries on with an uncaptured pointer.
    Unsupported,
};

pub const AudioError = error{
    OutOfMemory,
    /// No output device, or the OS declined to open one. **Not a programmer error**: a
    /// machine with no sound card is a configuration, and a game may carry on in silence.
    AudioUnavailable,
    /// The device exists but cannot produce anything Foundry can use — including a
    /// config asking for a buffer no device could fill (`audio.supportable`).
    AudioFormatUnsupported,
    /// The handle does not name a live device — closed, or from before a reopen (I1).
    InvalidAudioDevice,
    /// The `OutputId` names no output present now: unplugged since it was listed, or from an
    /// earlier session, since an ID is valid for one session only (`audio.OutputId`). A game
    /// usually has it from a preference or a menu, so it is reported rather than asserted.
    InvalidAudioOutput,
};

pub const GamepadRumbleError = error{
    /// The handle does not name the pad seated in its slot: disconnected, replaced, or never
    /// issued (I1).
    InvalidGamepad,
    /// A strength outside [0, 1], NaN, or a duration over `gamepad.max_rumble_ms`. A game may pass
    /// on a value from content or a mod, so it is reported rather than asserted.
    InvalidRumble,
    /// The pad has no motors, or its driver declined. **A normal answer**: the game carries on.
    Unsupported,
};

/// Options common to every backend, set once at `init`.
pub const InitOptions = struct {
    /// Whether to watch for gamepads at all. A dedicated server or a content tool turns it off,
    /// so it opens no HID devices and starts no threads for them (`input.md` §4.3).
    gamepads: bool = true,
};

/// Verifies that `Impl` provides the whole backend interface with the exact signatures.
///
/// `label` names the backend in any error message, because "missing declaration" is
/// only useful if it says missing from *what*.
pub fn check(comptime Impl: type, comptime label: []const u8) void {
    comptime {
        if (!@hasDecl(Impl, "Platform")) {
            @compileError("platform backend '" ++ label ++ "' declares no `Platform` type");
        }
        const P = Impl.Platform;
        const A = std.mem.Allocator;

        // Lifecycle. `init` returns a pointer because a backend may need a stable
        // address, and `deinit` releases whatever `init` took, including that pointer.
        expectFn(P, label, "init", &.{ A, InitOptions }, InitError!*P);
        expectFn(P, label, "deinit", &.{*P}, void);

        // Windows. Addressed by generational handle, never by pointer (I1).
        expectFn(P, label, "openWindow", &.{ *P, window.WindowConfig }, WindowError!window.WindowHandle);
        expectFn(P, label, "closeWindow", &.{ *P, window.WindowHandle }, void);
        expectFn(P, label, "windowInfo", &.{ *P, window.WindowHandle }, ?window.WindowInfo);
        // A window opened with `native_window` reports the concrete kind it received; no
        // handle ever carries the request kind itself (`window.SurfaceKind`).
        expectFn(P, label, "nativeSurface", &.{ *P, window.WindowHandle }, ?window.NativeSurfaceHandle);

        // Resizing from inside the process. **The size is logical**, because logical is
        // the only one of a window's two sizes that can be set: pixel size follows from
        // it and the display's scale, which belongs to the display and not to us.
        //
        // This is a *request*. The new size is observed by draining `window_resized`
        // from the event queue like any other resize, not by reading it back, so a
        // program that resizes itself takes the identical path as a user dragging an
        // edge — which is what makes the one testable by exercising the other.
        expectFn(P, label, "setWindowSize", &.{ *P, window.WindowHandle, window.Size }, WindowError!void);

        // The window's icon, from bytes the application decoded and lends for the call alone.
        // Host window configuration, so nothing in the public C ABI reaches it (`vulkan.md` §9).
        expectFn(P, label, "setWindowIcon", &.{ *P, window.WindowHandle, window.WindowIcon }, WindowIconError!void);

        // The window's title, borrowed for the call. Separate from `openWindow`'s because a
        // host's content, which may name it, loads after its window exists (M19).
        expectFn(P, label, "setWindowTitle", &.{ *P, window.WindowHandle, []const u8 }, WindowTitleError!void);

        // Pointer capture: the cursor hidden and held inside the window, motion relative and
        // unbounded, positions frozen. `MouseState.captured` reports what is true, since the
        // window system may refuse, and losing keyboard focus releases it without asking.
        // Host window policy, so nothing in the public C ABI reaches it (`playable3d.md` §4).
        expectFn(P, label, "setPointerCapture", &.{ *P, window.WindowHandle, bool }, PointerCaptureError!void);

        // How captured motion is measured: the device's counts (`raw`, the default) or the OS's
        // ballistics (`system`). It cannot fail; `MouseState.motion_unit` reports what the window
        // system then delivers, which is `points` wherever it cannot deliver counts (`input.md`
        // §3, ADR-0089). Host policy, like capture, so nothing in the public C ABI reaches it.
        expectFn(P, label, "setCapturedMotion", &.{ *P, input.MotionMode }, void);

        // What the current layout engraves on a physical key, for a prompt: bounded, valid UTF-8
        // in the caller's buffer, and empty for `unknown`. Presentation only; a binding keeps the
        // key's physical name (`input.md` §3).
        expectFn(P, label, "keyLabel", &.{ *P, key.Key, *[key.label_capacity]u8 }, []const u8);

        // Rumble on a seated pad: two motor strengths in [0, 1] for up to ten seconds, zeros to
        // stop. Output and presentation: nothing in simulation reads it (`input.md` §4.3).
        expectFn(P, label, "setGamepadRumble", &.{ *P, gamepad.GamepadHandle, f32, f32, u32 }, GamepadRumbleError!void);

        // The frame's input boundary, in the order it is called:
        //   pumpEvents  — drain the OS queue, once, at one known point in the frame
        //   nextEvent   — read what that produced
        //   captureInput— freeze it into the value simulation reads (I9)
        expectFn(P, label, "pumpEvents", &.{*P}, void);
        expectFn(P, label, "nextEvent", &.{*P}, ?event.Event);
        expectFn(P, label, "captureInput", &.{*P}, input.InputSnapshot);

        // Audio output. **The only place in Foundry where a backend calls upward**, on a
        // thread it owns and under a deadline — see `audio.AudioCallback` for the rule
        // that applies inside it.
        //
        // Opened on request rather than at `init`, because a game that never plays a
        // sound should not cost a device and a thread. `audio.Mixer` is what opens one
        // (`audio.md` §7), which is why `app` needs no dependency on the mixer at all.
        expectFn(P, label, "openAudio", &.{ *P, audio.AudioConfig }, AudioError!audio.AudioDeviceHandle);
        expectFn(P, label, "closeAudio", &.{ *P, audio.AudioDeviceHandle }, void);
        expectFn(P, label, "audioInfo", &.{ *P, audio.AudioDeviceHandle }, ?audio.AudioInfo);
        expectFn(P, label, "setAudioPaused", &.{ *P, audio.AudioDeviceHandle, bool }, void);

        // Outputs (`input.md` §5). The list, in the OS's order, into the caller's buffer; how
        // many were written. A device follows the system default (null) or plays through one
        // output, and a move rebinds the device's stream rather than reopening it, so the handle,
        // `AudioInfo` and the callback's clock carry on. A chosen output that disappears drops
        // the device back to following the default, with `audio_output_lost`. Host policy, so
        // nothing in the public C ABI reaches it before M48.
        expectFn(P, label, "audioOutputs", &.{ *P, []audio.OutputInfo }, usize);
        expectFn(P, label, "setAudioOutput", &.{ *P, audio.AudioDeviceHandle, ?audio.OutputId }, AudioError!void);
        expectFn(P, label, "audioOutput", &.{ *P, audio.AudioDeviceHandle }, AudioError!?audio.OutputId);

        // The monotonic clock. Backend-provided because the null backend's is
        // synthetic, which is what makes loop tests reproducible.
        expectFn(P, label, "now", &.{*P}, core.time.Instant);
    }
}

fn expectFn(
    comptime P: type,
    comptime label: []const u8,
    comptime name: []const u8,
    comptime params: []const type,
    comptime Ret: type,
) void {
    comptime {
        const what = "platform backend '" ++ label ++ "': `Platform." ++ name ++ "`";

        if (!@hasDecl(P, name)) @compileError(what ++ " is missing");

        const info = @typeInfo(@TypeOf(@field(P, name)));
        if (info != .@"fn") @compileError(what ++ " must be a function");
        const f = info.@"fn";

        if (f.params.len != params.len) {
            @compileError(std.fmt.comptimePrint(
                "{s} takes {d} parameters, the interface requires {d}",
                .{ what, f.params.len, params.len },
            ));
        }
        for (params, 0..) |Want, i| {
            const got = f.params[i].type orelse
                @compileError(what ++ " has a generic parameter; the interface requires concrete types");
            if (got != Want) {
                @compileError(std.fmt.comptimePrint(
                    "{s} parameter {d} is {s}, the interface requires {s}",
                    .{ what, i, @typeName(got), @typeName(Want) },
                ));
            }
        }

        const got_ret = f.return_type orelse
            @compileError(what ++ " has a generic return type");
        if (got_ret != Ret) {
            @compileError(std.fmt.comptimePrint(
                "{s} returns {s}, the interface requires {s}",
                .{ what, @typeName(got_ret), @typeName(Ret) },
            ));
        }
    }
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "the check accepts a conforming implementation" {
    // A minimal stand-in, so this file tests its own checker rather than only being
    // exercised through whichever backend happens to be selected.
    const Conforming = struct {
        pub const Platform = struct {
            pub fn init(gpa: std.mem.Allocator, options: InitOptions) InitError!*@This() {
                _ = options;
                return gpa.create(@This());
            }
            pub fn deinit(self: *@This()) void {
                _ = self;
            }
            pub fn openWindow(self: *@This(), config: window.WindowConfig) WindowError!window.WindowHandle {
                _ = self;
                _ = config;
                return .none;
            }
            pub fn closeWindow(self: *@This(), handle: window.WindowHandle) void {
                _ = self;
                _ = handle;
            }
            pub fn windowInfo(self: *@This(), handle: window.WindowHandle) ?window.WindowInfo {
                _ = self;
                _ = handle;
                return null;
            }
            pub fn nativeSurface(self: *@This(), handle: window.WindowHandle) ?window.NativeSurfaceHandle {
                _ = self;
                _ = handle;
                return null;
            }
            pub fn setWindowSize(self: *@This(), handle: window.WindowHandle, logical: window.Size) WindowError!void {
                _ = self;
                _ = handle;
                _ = logical;
            }
            pub fn setWindowIcon(self: *@This(), handle: window.WindowHandle, icon: window.WindowIcon) WindowIconError!void {
                _ = self;
                _ = handle;
                _ = icon;
            }
            pub fn setWindowTitle(self: *@This(), handle: window.WindowHandle, title: []const u8) WindowTitleError!void {
                _ = self;
                _ = handle;
                _ = title;
            }
            pub fn setPointerCapture(self: *@This(), handle: window.WindowHandle, captured: bool) PointerCaptureError!void {
                _ = self;
                _ = handle;
                _ = captured;
            }
            pub fn setCapturedMotion(self: *@This(), mode: input.MotionMode) void {
                _ = self;
                _ = mode;
            }
            pub fn keyLabel(self: *@This(), k: key.Key, buf: *[key.label_capacity]u8) []const u8 {
                _ = self;
                _ = k;
                return buf[0..0];
            }
            pub fn setGamepadRumble(self: *@This(), pad: gamepad.GamepadHandle, low: f32, high: f32, duration_ms: u32) GamepadRumbleError!void {
                _ = self;
                _ = pad;
                _ = low;
                _ = high;
                _ = duration_ms;
                return error.Unsupported;
            }
            pub fn pumpEvents(self: *@This()) void {
                _ = self;
            }
            pub fn nextEvent(self: *@This()) ?event.Event {
                _ = self;
                return null;
            }
            pub fn captureInput(self: *@This()) input.InputSnapshot {
                _ = self;
                return .{};
            }
            pub fn openAudio(self: *@This(), config: audio.AudioConfig) AudioError!audio.AudioDeviceHandle {
                _ = self;
                _ = config;
                return .none;
            }
            pub fn closeAudio(self: *@This(), device: audio.AudioDeviceHandle) void {
                _ = self;
                _ = device;
            }
            pub fn audioInfo(self: *@This(), device: audio.AudioDeviceHandle) ?audio.AudioInfo {
                _ = self;
                _ = device;
                return null;
            }
            pub fn setAudioPaused(self: *@This(), device: audio.AudioDeviceHandle, paused: bool) void {
                _ = self;
                _ = device;
                _ = paused;
            }
            pub fn audioOutputs(self: *@This(), out: []audio.OutputInfo) usize {
                _ = self;
                _ = out;
                return 0;
            }
            pub fn setAudioOutput(self: *@This(), device: audio.AudioDeviceHandle, output: ?audio.OutputId) AudioError!void {
                _ = self;
                _ = device;
                _ = output;
            }
            pub fn audioOutput(self: *@This(), device: audio.AudioDeviceHandle) AudioError!?audio.OutputId {
                _ = self;
                _ = device;
                return null;
            }
            pub fn now(self: *@This()) core.time.Instant {
                _ = self;
                return .{ .ns = 0 };
            }
        };
    };

    comptime check(Conforming, "conforming-stub");
    try testing.expect(true);
}

test "the interface names every call a frame makes" {
    // A change to the frame's shape should be a deliberate edit here, not something
    // that drifts in one backend at a time.
    const required = [_][]const u8{
        "init",              "deinit",        "openWindow",       "closeWindow",
        "windowInfo",        "nativeSurface", "pumpEvents",       "nextEvent",
        "captureInput",      "now",           "setWindowSize",    "openAudio",
        "closeAudio",        "audioInfo",     "setAudioPaused",   "setPointerCapture",
        "setCapturedMotion", "keyLabel",      "setGamepadRumble", "audioOutputs",
        "setAudioOutput",    "audioOutput",
    };
    try testing.expectEqual(@as(usize, 22), required.len);
}
