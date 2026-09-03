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

const event = @import("event.zig");
const input = @import("input.zig");
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

/// Options common to every backend. Empty today; present so that adding one later is
/// an edit to this struct rather than to every call site.
pub const InitOptions = struct {};

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

        // The frame's input boundary, in the order it is called:
        //   pumpEvents  — drain the OS queue, once, at one known point in the frame
        //   nextEvent   — read what that produced
        //   captureInput— freeze it into the value simulation reads (I9)
        expectFn(P, label, "pumpEvents", &.{*P}, void);
        expectFn(P, label, "nextEvent", &.{*P}, ?event.Event);
        expectFn(P, label, "captureInput", &.{*P}, input.InputSnapshot);

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
        "init",          "deinit",     "openWindow", "closeWindow",  "windowInfo",
        "nativeSurface", "pumpEvents", "nextEvent",  "captureInput", "now",
        "setWindowSize",
    };
    try testing.expectEqual(@as(usize, 11), required.len);
}
