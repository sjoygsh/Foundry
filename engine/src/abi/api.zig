//! `FoundryApi_v1`, and the query function a mod is handed.
//!
//! This file is the Zig half of the header's table. The C half is the specification; this
//! one has to match it exactly, and `agreement.zig` is what proves it does — every field's
//! offset, in order, so a capability added to one and not the other fails the build rather
//! than shifting every pointer after it.
//!
//! **The table is a value, not an interface.** It is built once per host type at comptime,
//! lives in static storage, and is handed out by pointer. `get_api` is the only way a mod
//! reaches it, which is what makes ADR-0004's "added alongside, never replacing"
//! implementable: a `_v2` is a second struct beside this one and a host offers both.
//!
//! Design: `docs/design/public-abi.md` §3 and §4.

const std = @import("std");

const engine_calls = @import("calls_engine.zig");
const types = @import("types.zig");

const ContentId = types.ContentId;
const Cursor = types.Cursor;
const LogRecord = types.LogRecord;
const MemoryCounter = types.MemoryCounter;
const MemoryStats = types.MemoryStats;
const Mod = types.Mod;
const Result = types.Result;
const Str = types.Str;

/// Everything a mod may call.
///
/// **Enumerations arrive as `i32`, never as a Zig enum**, and that is a rule rather than a
/// style. A value from the other side is untrusted, and an enum-typed parameter holding a
/// number the enum does not have is illegal behaviour in Zig before any validation can run —
/// so a number crosses as a number and is looked up. Enumerations *leaving* are enums,
/// because those the engine produces.
///
/// Field order is the contract. Append only, and never insert.
pub const Api_v1 = extern struct {
    version: u32,
    size: u32,

    // -- Results and logging -----------------------------------------------------------

    result_name: *const fn (result: i32) callconv(.c) Str,
    log_write: *const fn (self: Mod, level: i32, message: Str) callconv(.c) Result,
    log_next: *const fn (cursor: ?*Cursor, out: ?*LogRecord) callconv(.c) Result,

    // -- Content identity --------------------------------------------------------------

    id_from_string: *const fn (text: Str, out: ?*ContentId) callconv(.c) Result,
    id_to_string: *const fn (id: ContentId, out: ?*Str) callconv(.c) Result,
    id_copy_string: *const fn (id: ContentId, buffer: ?[*]u8, capacity: u64, needed: ?*u64) callconv(.c) Result,

    // -- The frame ---------------------------------------------------------------------

    frame_index: *const fn (out: ?*u64) callconv(.c) Result,
    frame_delta_ns: *const fn (out: ?*u64) callconv(.c) Result,
    elapsed_ns: *const fn (out: ?*u64) callconv(.c) Result,
    tick_delta_ns: *const fn (out: ?*u64) callconv(.c) Result,

    // -- The profiler ------------------------------------------------------------------

    scope_begin: *const fn (name: Str) callconv(.c) Result,
    scope_end: *const fn () callconv(.c) Result,

    // -- Memory ------------------------------------------------------------------------

    memory_counter_open: *const fn (self: Mod, name: Str, out: ?*MemoryCounter) callconv(.c) Result,
    memory_counter_set: *const fn (counter: MemoryCounter, stats: ?*const MemoryStats) callconv(.c) Result,
};

/// The table for one host type, and the `get_api` that hands it out.
pub fn TableOf(comptime H: type) type {
    const engine = engine_calls.Of(H);

    return struct {
        pub const v1: Api_v1 = .{
            .version = types.api_version_1,
            .size = @sizeOf(Api_v1),

            .result_name = engine.resultName,
            .log_write = engine.logWrite,
            .log_next = engine.logNext,

            .id_from_string = engine.idFromString,
            .id_to_string = engine.idToString,
            .id_copy_string = engine.idCopyString,

            .frame_index = engine.frameIndex,
            .frame_delta_ns = engine.frameDeltaNs,
            .elapsed_ns = engine.elapsedNs,
            .tick_delta_ns = engine.tickDeltaNs,

            .scope_begin = engine.scopeBegin,
            .scope_end = engine.scopeEnd,

            .memory_counter_open = engine.memoryCounterOpen,
            .memory_counter_set = engine.memoryCounterSet,
        };

        /// What a native mod is handed (§3). **Never a crash and never a Zig error** — a
        /// version this host does not offer is null, which is a legible refusal on the
        /// mod's side rather than a fault on ours.
        pub fn getApi(version: u32) callconv(.c) ?*const anyopaque {
            if (version == types.api_version_1) return @ptrCast(&v1);
            return null;
        }
    };
}

test {
    _ = engine_calls;
}
