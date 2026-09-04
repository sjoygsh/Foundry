//! Foundry `render2d` — layer L3. The 2D renderer.
//!
//! Depends on `core`, `rhi` and `asset`. **This is the first game-facing rendering
//! boundary** (CLAUDE.md §4.2): games, tools and eventually mods use it, and they never
//! touch the RHI beneath it.
//!
//! That makes the names here compatibility decisions rather than style ones. The RHI has
//! one consumer, which we write, and can be changed on both sides in a single commit; this
//! will have consumers in other repositories and, from M7, mods compiled against a frozen
//! ABI. Renaming `drawSprite` later breaks other people's code.
//!
//! Design: `docs/design/render2d.md`.

const std = @import("std");

pub const batch = @import("batch.zig");
pub const camera = @import("camera.zig");
pub const color = @import("color.zig");
pub const renderer = @import("renderer.zig");
pub const sprite = @import("sprite.zig");
pub const texture = @import("texture.zig");

pub const Camera2D = camera.Camera2D;
pub const CameraError = camera.CameraError;
pub const Color = color.Color;
pub const BlendMode = color.BlendMode;
pub const Renderer = renderer.Renderer;
pub const Sprite = sprite.Sprite;
pub const TextureHandle = texture.TextureHandle;
pub const TextureOptions = texture.TextureOptions;
pub const Filter = texture.Filter;
pub const Wrap = texture.Wrap;

test {
    _ = batch;
    _ = camera;
    _ = color;
    _ = renderer;
    _ = sprite;
    _ = texture;
}
