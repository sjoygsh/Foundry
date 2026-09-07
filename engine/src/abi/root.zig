//! Foundry `abi` — layer L5, a peer of `debug` rather than a layer over `app`.
//!
//! **The one public API surface** (Invariant I4). Native mods today, the scripting host at
//! M8, external tools and the editor after that all arrive through here, and engine code
//! never does — including the editor, which gets no private path
//! ([ADR-0004](../../../docs/adr/0004-public-c-abi.md)).
//!
//! It sits beside `debug` and not above `app` because two facts forbid the alternative
//! ([ADR-0026](../../../docs/adr/0026-abi-module-and-host.md)): `app` cannot see `scene`,
//! `audio` or `physics2d`, and it *owns* no world, renderer, mixer or collision world,
//! because the game does. So the host hands this module the subsystems it has, exactly as it
//! hands `debug.Sources` its own, and a capability whose subsystem is absent answers
//! `unavailable` rather than being a null function pointer.
//!
//! **It may only translate.** Validate, call one subsystem, return a code. A module that can
//! see the whole engine will otherwise accumulate the whole engine, and this one holds no
//! state to accumulate it in.
//!
//! Everything arriving from the other side is untrusted, and untrusted means *validated* —
//! not asserted, not assumed, not documented as a precondition. The boundary never panics
//! and never propagates a Zig error.
//!
//! **What is built so far:** the type layer (`public-abi.md` §19 step 2). The table itself,
//! the host, and the native loader are steps 3 to 6.
//!
//! Design: `docs/design/public-abi.md`. The header is `foundry.h`, beside this file, and it
//! is the specification rather than a description of what is here.

pub const types = @import("types.zig");

const agreement = @import("agreement.zig");

// The vocabulary of the boundary. Named here because a host writing a `get_api` and a loader
// reading a mod's symbols both need them, and neither should be reaching into a file.
pub const Bool = types.Bool;
pub const ContentId = types.ContentId;
pub const Cursor = types.Cursor;
pub const Result = types.Result;
pub const Str = types.Str;

pub const boolIn = types.boolIn;
pub const boolOut = types.boolOut;

/// The opaque handles, one type per kind (`public-abi.md` §5).
pub const Asset = types.Asset;
pub const Body = types.Body;
pub const ComponentType = types.ComponentType;
pub const Entity = types.Entity;
pub const Mod = types.Mod;
pub const Package = types.Package;
pub const Record = types.Record;
pub const Schema = types.Schema;
pub const Texture = types.Texture;
pub const View = types.View;
pub const Voice = types.Voice;

/// What a native mod exports, and the version of the table this build publishes.
pub const GetApi = types.GetApi;
pub const ModInit = types.ModInit;
pub const ModShutdown = types.ModShutdown;
pub const api_version_1 = types.api_version_1;
pub const init_symbol = types.init_symbol;
pub const shutdown_symbol = types.shutdown_symbol;

test {
    _ = types;
    _ = agreement;
}
