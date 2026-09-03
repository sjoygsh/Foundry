//! Foundry `platform` — layer L1. Depends on `core` and nothing else.
//!
//! The only module in Foundry that may reference SDL3 (I7, enforced by the build
//! graph). Nothing above this layer knows what a window library is, and nothing here
//! knows what a renderer is.
//!
//! This module exists because of a risk named in ADR-0002: *"Foundry's platform
//! interface will initially be shaped by what SDL provides. Watch for SDL concepts
//! leaking into the interface's design, not just its implementation."* A wrapper that
//! renames SDL's types and calls it abstraction is worse than using SDL directly,
//! because it pays the indirection cost without buying replaceability.
//!
//! The test applied to every open design choice here: *would this interface still be
//! the right shape if it were implemented by hand-written Cocoa and Win32, with no SDL
//! anywhere?*
//!
//! ## Two objects, on purpose
//!
//! * `Platform` — window, surface, events, input, monotonic clock. Backend-specific,
//!   selected at build time.
//! * `Os` — filesystem, base directories, dynamic libraries, wall clock. The same code
//!   under every backend, so it is not behind the backend seam. See `os.zig`.
//!
//! `app` owns both, initialises `platform` first and tears it down last, and no
//! platform resource requires another subsystem to still be alive in order to be
//! destroyed.
//!
//! Design: `docs/design/platform-interface.md`

const std = @import("std");
const build_options = @import("build_options");

pub const event = @import("event.zig");
pub const input = @import("input.zig");
pub const interface = @import("interface.zig");
pub const key = @import("key.zig");
pub const library = @import("library.zig");
pub const os = @import("os.zig");
pub const window = @import("window.zig");

/// The platform backends Foundry can be built against.
///
/// A backend is an *engine port*, not a registry entry: it is chosen when the build
/// graph is constructed and cannot change at runtime. That is deliberately unlike
/// component types and asset loaders, which I6 requires be runtime-registered so mods
/// can add them. Mods do not add platform backends.
pub const Backend = enum {
    /// Headless. No window, no real input, a synthetic clock.
    null,
};

pub const backend: Backend = std.meta.stringToEnum(Backend, build_options.platform_backend) orelse
    @compileError("unknown platform backend '" ++ build_options.platform_backend ++ "'");

const null_backend = @import("backends/null.zig");

const selected = switch (backend) {
    .null => null_backend,
};

comptime {
    // The selected backend must satisfy the interface...
    interface.check(selected, @tagName(backend));
    // ...and so must the null backend, always. A second implementation is what makes
    // this an interface rather than a description of one implementation, so an
    // interface change that only suits the windowing backend of the day fails here.
    interface.check(null_backend, "null");
}

/// The selected platform backend. One implementation per binary, no vtable.
pub const Platform = selected.Platform;

// The types a caller reaches for, re-exported so `platform.Event` reads better than
// `platform.event.Event` at every call site.
pub const Event = event.Event;
pub const InputSnapshot = input.InputSnapshot;
pub const Key = key.Key;
pub const Modifiers = key.Modifiers;
pub const MouseButton = key.MouseButton;
pub const NativeSurfaceHandle = window.NativeSurfaceHandle;
pub const Os = os.Os;
pub const Size = window.Size;
pub const SurfaceKind = window.SurfaceKind;
pub const WindowConfig = window.WindowConfig;
pub const WindowHandle = window.WindowHandle;
pub const WindowInfo = window.WindowInfo;

pub const InitError = interface.InitError;
pub const InitOptions = interface.InitOptions;
pub const WindowError = interface.WindowError;
pub const FileError = os.FileError;
pub const PathError = os.PathError;
pub const LibraryError = os.LibraryError;

test {
    // Every file, listed explicitly. A file imported only for its *types* contributes
    // no tests: Zig collects tests from files reached through a test block, and
    // `os.zig` importing `library.zig` for `Library` does not reach it. Discovered by
    // breaking the Windows loader on purpose and watching the suite stay green.
    _ = event;
    _ = input;
    _ = interface;
    _ = key;
    _ = library;
    _ = os;
    _ = window;
    // Always tested, whichever backend is selected — it is the reference
    // implementation of the interface and the one CI can always run.
    _ = null_backend;
}
