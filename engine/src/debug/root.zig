//! Foundry `debug` — layer L5. The in-process debug overlay (ADR-0025).
//!
//! Depends on `core`, `data`, `ui`, `asset`, `render2d`, `scene`, `audio` and `app`, and
//! **nothing depends on it**. A game opts in by importing it, exactly as it opts into
//! `render2d` or `audio`; a game that does not import it does not build it.
//!
//! ## The rule this module exists to obey
//!
//! **Every call the overlay makes is one the public ABI could expose** (ADR-0025). The
//! overlay is the editor's first draft and it is being written a milestone before the ABI
//! the editor will stand on, so it is held to the ABI's shape now: identity is a handle or
//! a content id, enumeration has a documented order, reads are read-only, borrows last a
//! frame, and anything a mod could have supplied is validated rather than asserted.
//!
//! This is I3's argument applied to tooling. The base game is content package zero because
//! the only durable way to know the mod path works is to be on it ourselves; the overlay is
//! package zero for the introspection API for the same reason. If a panel wants something no
//! public call provides, the answer is to add the public call — never to reach around.
//!
//! **The introspection lives in the subsystem introspected, never here.** Enumerating
//! entities is `scene`'s to offer because `scene` owns the pool and its order. This module
//! composes those answers into panels and holds no privileged knowledge of anyone's
//! internals — which the module boundary makes checkable rather than aspirational.
//!
//! ## What it is not
//!
//! Not a framework. `app-and-frame-loop.md` established that `Engine` is a library you drive
//! rather than a framework that calls you back, and the overlay is the same: the game decides
//! when to describe it, where it sits and what key toggles it. **The overlay declares no
//! key** — `engine.zig` already refuses to intercept input on the grounds that what looks
//! like an obviously engine-level key today is a game's binding tomorrow, and grabbing F1
//! here would be that mistake one layer up.
//!
//! It draws nothing, either. Panels are `ui` widget calls, so the whole overlay inherits the
//! kernel's testability: it describes with no device, no window and no frame, and a test
//! asserts on the draw list.
//!
//! Design: `docs/design/debug-overlay.md`. Decision: `docs/adr/0025-debug-overlay-module.md`.

pub const overlay = @import("overlay.zig");

pub const console_panel = @import("console_panel.zig");
pub const content_panel = @import("content_panel.zig");
pub const entity_panel = @import("entity_panel.zig");
pub const memory_panel = @import("memory_panel.zig");
pub const profiler_panel = @import("profiler_panel.zig");

// The names a game sees today and a mod sees from M7, so renaming one is a compatibility
// decision rather than a tidy-up (CLAUDE.md §7).
pub const Overlay = overlay.Overlay;
pub const Options = overlay.Options;
pub const Panel = overlay.Panel;
pub const PanelHandle = overlay.PanelHandle;
/// What the engine knows, as a value a panel reads. See `overlay.zig` for why panels are
/// handed this rather than the engine itself.
pub const Frame = overlay.Frame;
/// What the engine does *not* own, and therefore what the game has to hand over.
pub const Sources = overlay.Sources;
pub const View = overlay.View;
pub const Window = overlay.Window;

/// The name of the span the overlay opens around itself, so the cost of describing the
/// panels is inside the profile they are drawing rather than hidden beside it.
pub const span = overlay.span;

test {
    _ = overlay;
    _ = console_panel;
    _ = content_panel;
    _ = entity_panel;
    _ = memory_panel;
    _ = profiler_panel;
}
