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

pub const animation = @import("animation.zig");
pub const atlas = @import("atlas.zig");
pub const batch = @import("batch.zig");
pub const camera = @import("camera.zig");
pub const color = @import("color.zig");
pub const loader = @import("loader.zig");
pub const renderer = @import("renderer.zig");
pub const sprite = @import("sprite.zig");
pub const text = @import("text.zig");
pub const texture = @import("texture.zig");
pub const tilemap = @import("tilemap.zig");
pub const view = @import("view.zig");

pub const AtlasHandle = atlas.AtlasHandle;
/// A rectangle of a texture. `Region.cell` cuts one into the grid a sprite sheet is, which
/// is what turns the frame index the two below return into something drawable.
pub const Region = atlas.Region;
/// Which frame of a clip is showing after so many ticks, when every frame is held the same
/// length. Pure integer arithmetic; see `animation` for why it is not a float accumulator.
pub const frameAt = animation.frameAt;
/// The same, when frames are held for different lengths.
pub const frameAtVarying = animation.frameAtVarying;
pub const Camera2D = camera.Camera2D;
pub const CameraError = camera.CameraError;
pub const Color = color.Color;
pub const BlendMode = color.BlendMode;
pub const Renderer = renderer.Renderer;
/// Everything a renderer call can fail with. Named here so a caller above — the UI walker
/// in `app` is the first — can declare it without reaching into the file it lives in.
pub const RendererError = renderer.Error;
/// The `foundry:texture` loader, to register with an `asset.Registry` at startup (I6).
pub const textureLoader = loader.textureLoader;
pub const Sprite = sprite.Sprite;
/// Hit-testing one sprite. Picking is the game's loop over its own objects; see
/// `sprite.containsPoint` for why the renderer does not own a "what is at this point".
pub const containsPoint = sprite.containsPoint;
pub const BitmapFont = text.BitmapFont;
pub const TextOptions = text.TextOptions;
/// The bounding box a string would occupy. Runs the layout the drawing runs.
pub const measureText = text.measure;
/// One drawable plane of a map. See `Renderer.drawTilemap`.
pub const TilemapLayer = tilemap.TilemapLayer;
/// The visible cells of a tilemap layer, as sprites. Public so a game can have the culled
/// span without drawing it.
pub const Tiles = tilemap.Tiles;
pub const ViewId = view.ViewId;
pub const ViewDesc = view.ViewDesc;
pub const Extent2D = texture.Extent2D;
pub const TextureHandle = texture.TextureHandle;
pub const TextureOptions = texture.TextureOptions;
pub const Filter = texture.Filter;
pub const Wrap = texture.Wrap;

test {
    _ = animation;
    _ = atlas;
    _ = batch;
    _ = camera;
    _ = color;
    _ = loader;
    _ = renderer;
    _ = sprite;
    _ = text;
    _ = texture;
    _ = tilemap;
    _ = view;
}
