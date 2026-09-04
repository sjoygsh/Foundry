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

pub const Image = image.Image;
pub const DecodeError = png.DecodeError;
pub const Limits = png.Limits;

pub const AcquireError = registry.AcquireError;
pub const Asset = registry.Asset;
pub const AssetHandle = registry.AssetHandle;
pub const LoadError = registry.LoadError;
pub const Loader = registry.Loader;
pub const Payload = registry.Payload;
pub const Registry = registry.Registry;

/// One merged content record, as a loader is handed it.
///
/// Re-exported because `render2d` is granted `asset` and not `data` (ADR-0007), and a
/// module that registers a loader has to be able to name what its `load` receives.
pub const Record = data.store.Record;

test {
    _ = image;
    _ = png;
    _ = registry;
    _ = schemas;
}
