//! Foundry integration tests: what no single module can test on its own.
//!
//! Unit tests live beside the code they test (CLAUDE.md §7). What lands here is the
//! opposite case — a behaviour that only exists between two modules, where neither can
//! reach the other's test code because the layering deliberately does not let it.
//!
//! These stand where `app` and a game stand: above everything, composing it.

const std = @import("std");

pub const asset_pipeline = @import("asset_pipeline.zig");
pub const sprite_animation = @import("sprite_animation.zig");
pub const tilemap_pipeline = @import("tilemap_pipeline.zig");
pub const world_pipeline = @import("world_pipeline.zig");

test {
    _ = asset_pipeline;
    _ = sprite_animation;
    _ = tilemap_pipeline;
    _ = world_pipeline;
}
