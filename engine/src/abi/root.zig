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
//! **What is built so far:** the type layer and the skeleton (`public-abi.md` §19 steps 2
//! and 3) — `Host`, `get_api`, and a `FoundryApi_v1` carrying what `app` and `data` already
//! answer. The `scene`, `render2d`, `ui`, `audio` and `physics2d` groups are steps 4 and 5;
//! the native loader is step 6.
//!
//! Design: `docs/design/public-abi.md`. The header is `foundry.h`, beside this file, and it
//! is the specification rather than a description of what is here.

pub const api = @import("api.zig");
pub const host = @import("host.zig");
pub const types = @import("types.zig");

const agreement = @import("agreement.zig");
const calls_engine = @import("calls_engine.zig");

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

/// What the host hands over, and what it gets back.
///
/// `Host` is the concrete one a game wants; `HostOf` is what makes a test able to bind a
/// fake engine and run every entry point with no window, no device and no frame.
pub const Host = host.HostOf(@import("app").Engine);
pub const HostOf = host.HostOf;

/// The table itself, and the enumerations and structs that cross with it.
pub const Api_v1 = api.Api_v1;
pub const FieldType = types.FieldType;
pub const LogLevel = types.LogLevel;
pub const LogRecord = types.LogRecord;
pub const MemoryCounter = types.MemoryCounter;
pub const MemoryStats = types.MemoryStats;

/// What a native mod exports, and the version of the table this build publishes.
pub const GetApi = types.GetApi;
pub const ModInit = types.ModInit;
pub const ModShutdown = types.ModShutdown;
pub const api_version_1 = types.api_version_1;
pub const init_symbol = types.init_symbol;
pub const shutdown_symbol = types.shutdown_symbol;

test {
    _ = agreement;
    _ = api;
    _ = calls_engine;
    _ = host;
    _ = types;
    _ = @import("sweep.zig");
}
