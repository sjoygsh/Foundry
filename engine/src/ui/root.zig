//! Foundry `ui` — layer L1. Depends on **`core` and `platform`, and nothing else**.
//!
//! An immediate-mode UI kernel that **draws nothing**. It reads input, decides what is hot,
//! lays out, clips — and then *describes* what should appear as a list of rectangles, text
//! runs and clip rectangles. Something above walks that list into renderer calls (ADR-0024).
//!
//! **Why it is below the renderer rather than above it.** The deciding argument was that
//! `render2d.BitmapFont` has six fields of which exactly one is a renderer thing and the
//! rest is arithmetic, so measuring text needs no renderer at all. What that buys is the
//! whole interaction model being testable with no device, no window and no frame — the
//! same reason the null RHI backend and the stepped null audio device exist. What it costs
//! is two draw vocabularies and a walker in `app`, whose one real hazard is the kernel
//! measuring text differently from the renderer drawing it; `ui.md` §8 answers that with a
//! single sanctioned conversion and a test that measures a corpus both ways.
//!
//! **One kernel, two widget sets** (ADR-0024). A debug panel and a game's HUD differ in
//! presentation and authoring, not in mechanism, so the identity/hot-active/layout/clip core
//! is written once. The rule that keeps the second widget set possible is that **no colour,
//! font, metric or string here is a literal**: style is a value passed in, text is a slice
//! the caller supplies. A kernel that obeys that can be given a content-driven theme later
//! without being rewritten; one that does not would violate I5 the moment a game used it.
//!
//! **Identity and display text are separate parameters, always** — see `id.zig` for the
//! localisation bug that rule exists to prevent.
//!
//! Everything reaching this module comes from a game, and from M7 from a mod, so ids,
//! labels, rectangles and style values are **validated and reported, never asserted**
//! (CLAUDE.md §7). `core.assert` is for kernel-internal invariants only.
//!
//! Design: `docs/design/ui.md`

pub const context = @import("context.zig");
pub const draw = @import("draw.zig");
pub const id = @import("id.zig");
pub const input = @import("input.zig");
pub const style = @import("style.zig");
pub const widget = @import("widget.zig");

// The names reached for most often. These are seen by people we do not control — a game
// today, compiled mods from M7 — so renaming one is a compatibility decision rather than a
// tidy-up (CLAUDE.md §7).
pub const Color = style.Color;
pub const Command = draw.Command;
pub const Context = context.Context;
pub const DrawList = draw.DrawList;
pub const FontMetrics = style.FontMetrics;
/// A widget's identity. **Not a `ContentId`** — see `id.zig` for why the resemblance is a
/// trap and why this deliberately does not call `core.id.fnv1a64`.
pub const Id = id.Id;
pub const Input = input.Input;
pub const Interaction = context.Interaction;
pub const Style = style.Style;
pub const TextRef = draw.TextRef;

/// A clickable rectangle with a centred label. The only widget at step 1; the rest of the
/// debug set arrives at step 5 of `ui.md` §16.
pub const button = widget.button;

test {
    _ = context;
    _ = draw;
    _ = id;
    _ = input;
    _ = style;
    _ = widget;
}
