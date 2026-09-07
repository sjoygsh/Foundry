//! Foundry integration tests: what no single module can test on its own.
//!
//! Unit tests live beside the code they test (CLAUDE.md §7). What lands here is the
//! opposite case — a behaviour that only exists between two modules, where neither can
//! reach the other's test code because the layering deliberately does not let it.
//!
//! These stand where `app` and a game stand: above everything, composing it.

const std = @import("std");

const app = @import("app");

/// Foundry's logging, installed the way a game installs it.
///
/// A root source file is the only place `std.log` can be routed from, and this binary is
/// one. Without it the engine's own lines go to the default handler and never reach the
/// in-memory ring — which `debug_overlay.zig` reads, and which is exactly the wiring that
/// is only testable from above.
pub const std_options = app.std_options;

pub const asset_pipeline = @import("asset_pipeline.zig");
pub const debug_overlay = @import("debug_overlay.zig");
pub const overlay_batches = @import("overlay_batches.zig");
pub const sound_pipeline = @import("sound_pipeline.zig");
pub const sprite_animation = @import("sprite_animation.zig");
pub const tilemap_pipeline = @import("tilemap_pipeline.zig");
pub const ui_text = @import("ui_text.zig");
pub const world_pipeline = @import("world_pipeline.zig");

test {
    _ = asset_pipeline;
    _ = debug_overlay;
    _ = overlay_batches;
    _ = sound_pipeline;
    _ = sprite_animation;
    _ = tilemap_pipeline;
    _ = ui_text;
    _ = world_pipeline;
}
