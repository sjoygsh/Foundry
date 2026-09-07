//! Foundry `mod` — layer L2. Depends on `core`, `data` and `platform`.
//!
//! **What is installed, and in what order it loads.** Nothing else. It opens no library,
//! runs no code and knows nothing about the ABI, which is why it sits *below* the engine
//! loop rather than above it: a Tier 1 mod list has to be computable by a game that loads
//! no code at all, and most games hosting mods never will
//! ([ADR-0027](../../../docs/adr/0027-mods-are-content-packages.md)).
//!
//! Its output is exactly the ordered list `app.Config.content` already takes, so
//! `content-schemas.md` §6 stands unchanged: **`data` consumes a load order and does not
//! compute one.** Something else computes it now, and that something is not the engine
//! either.
//!
//! A mod is a content package. Tier 1 is that package alone and has worked since M3; Tier 3
//! is the same package with a native library its manifest names; Tier 2 adds scripts at M8.
//! So there is one identity — the package's content id (I2) — one version, and one file
//! that can never disagree with the package it describes.
//!
//! Everything it reads comes from a directory a player has been putting files into, which
//! makes all of it untrusted input: validated and reported, never asserted.
//!
//! Design: `docs/design/public-abi.md` §11 and §12.

pub const discover_mod = @import("discover.zig");
pub const manifest = @import("manifest.zig");
pub const resolve_mod = @import("resolve.zig");
pub const schemas = @import("schemas.zig");

// The names reached for most often. A mod author never sees these — they see the manifest
// fields, which `schemas.zig` freezes — but a host does, and a host is a consumer we do
// not control either (CLAUDE.md §7).
pub const Candidate = discover_mod.Candidate;
pub const Discovery = discover_mod.Discovery;
pub const Entry = resolve_mod.Entry;
pub const Manifest = manifest.Manifest;
pub const Range = manifest.Range;
pub const Request = resolve_mod.Request;
pub const Requirement = manifest.Requirement;
pub const Resolution = resolve_mod.Resolution;
pub const Skip = resolve_mod.Skip;
pub const SkipReason = resolve_mod.SkipReason;

/// Read every package in a directory.
pub const discover = discover_mod.discover;
/// Turn candidates and a player's enabled list into a load order.
pub const resolve = resolve_mod.resolve;

test {
    _ = discover_mod;
    _ = manifest;
    _ = resolve_mod;
    _ = schemas;
}
