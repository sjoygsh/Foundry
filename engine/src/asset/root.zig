//! Foundry `asset` — layer L2. Bytes on disk become things the engine can use.
//!
//! Depends on `core`, `data` and `platform` — the module with both a filesystem and the
//! content model, which is what makes it the seam between them. **`data` cannot open a file
//! and `render2d` should not, so opening files on content's behalf is this module's job and
//! nobody else's.**
//!
//! Everything is addressed by `ContentId` and nothing by path (ADR-0021). `Registry.acquire`
//! is the only entry point, and there is no way to ask what is at a path — a record found by
//! ID may say where its own bytes live, and that is location rather than identity.
//!
//! The split with `render2d` is that this module owns nothing on the GPU. It decodes an
//! `Image` in ordinary memory and holds a loader's product as one opaque word; the renderer
//! turns an image into a texture and owns it from there (`docs/design/render2d.md` §8).
//!
//! Everything here parses input from files, which means input from mods, which means
//! **untrusted input**: validated and refused, never asserted (CLAUDE.md §5).
//!
//! Design: `docs/design/assets.md`.

const std = @import("std");
const data = @import("data");

pub const image = @import("image.zig");
pub const png = @import("png.zig");
pub const registry = @import("registry.zig");
pub const schemas = @import("schemas.zig");
pub const sound = @import("sound.zig");
pub const tilegrid = @import("tilegrid.zig");
pub const tilemap = @import("tilemap.zig");
pub const wav = @import("wav.zig");

pub const Image = image.Image;
pub const DecodeError = png.DecodeError;
pub const Limits = png.Limits;

pub const Sound = sound.Sound;
/// Prefixed, because `png` already owns the unqualified names at this level. The two are
/// deliberately separate sets: a corrupt image and a corrupt sound have nothing in common
/// but the sentence they produce.
pub const SoundDecodeError = wav.DecodeError;
pub const SoundLimits = wav.Limits;

pub const AcquireError = registry.AcquireError;
pub const Asset = registry.Asset;
pub const AssetHandle = registry.AssetHandle;
pub const LoadError = registry.LoadError;
pub const Loader = registry.Loader;
pub const Payload = registry.Payload;
pub const Registry = registry.Registry;

pub const TileGrid = tilegrid.TileGrid;
/// The loader for `foundry:tilegrid`. Registered by whoever wants grids (I6); it needs no
/// renderer, because a grid of tile ids is not a GPU object.
pub const tilegridLoader = tilegrid.tilegridLoader;

/// One merged content record, as a loader is handed it.
///
/// Re-exported because `render2d` is granted `asset` and not `data` (ADR-0007), and a
/// module that registers a loader has to be able to name what its `load` receives.
pub const Record = data.store.Record;

/// The merged content store a registry reads records from.
///
/// Re-exported for the same reason and one step further: `Registry.init` takes one, so
/// without this a module granted `asset` and not `data` cannot name a parameter of this
/// module's own public constructor.
pub const Store = data.store.Store;

test {
    _ = image;
    _ = png;
    _ = registry;
    _ = schemas;
    _ = sound;
    _ = tilegrid;
    _ = tilemap;
    _ = wav;
}
