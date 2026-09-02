//! Scoped logging.
//!
//! This wraps `std.log` rather than exposing it. Callers use `core.log`, never
//! `std.log` directly — `std`'s logging API has moved between Zig releases and will
//! move again, and concentrating that churn in one file is the point of L0 (ADR-0001).
//!
//! `std.debug.print` in committed code is a convention violation, not a style preference.

const std = @import("std");
const builtin = @import("builtin");

/// Ordered most severe to least. `trace` has no `std.log` equivalent and is emitted at
/// debug level with a marker.
pub const Level = enum(u3) { err, warn, info, debug, trace };

/// The most verbose level retained by this build. Anything below it is not merely
/// silenced — the call, and the evaluation of its arguments, is compiled away.
pub const compiled_level: Level = switch (builtin.mode) {
    .Debug => .trace,
    .ReleaseSafe => .debug,
    .ReleaseFast, .ReleaseSmall => .info,
};

pub inline fn enabled(comptime level: Level) bool {
    return @intFromEnum(level) <= @intFromEnum(compiled_level);
}

/// A logger bound to one subsystem. Scopes are the filtering mechanism:
///
///     const log = core.log.scoped(.rhi);
///     log.warn("swapchain resize failed: {s}", .{reason});
pub fn scoped(comptime scope: @EnumLiteral()) type {
    const inner = std.log.scoped(scope);

    return struct {
        /// Something went wrong that the engine could not handle here.
        pub inline fn err(comptime fmt: []const u8, args: anytype) void {
            if (comptime enabled(.err)) inner.err(fmt, args);
        }

        /// Something is wrong but recoverable, or a sign of a latent problem.
        pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
            if (comptime enabled(.warn)) inner.warn(fmt, args);
        }

        /// Notable, low-frequency events: subsystem lifecycle, device selection.
        pub inline fn info(comptime fmt: []const u8, args: anytype) void {
            if (comptime enabled(.info)) inner.info(fmt, args);
        }

        /// Development detail. Compiled out of unsafe release builds.
        pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
            if (comptime enabled(.debug)) inner.debug(fmt, args);
        }

        /// Very high frequency detail — per-draw, per-entity. Debug builds only.
        ///
        /// The `comptime enabled` guard means a disabled call never constructs its
        /// argument tuple, so formatting work in a hot loop costs nothing when the
        /// level is off. That is the whole reason this is not just `std.log`.
        pub inline fn trace(comptime fmt: []const u8, args: anytype) void {
            if (comptime enabled(.trace)) inner.debug("[trace] " ++ fmt, args);
        }
    };
}

test "level ordering" {
    try std.testing.expect(@intFromEnum(Level.err) < @intFromEnum(Level.warn));
    try std.testing.expect(@intFromEnum(Level.debug) < @intFromEnum(Level.trace));
    // err is never compiled out, whatever the mode.
    try std.testing.expect(enabled(.err));
}

test "scoped logger compiles for every level" {
    const log = scoped(.core_test);

    // Guarded by a runtime-false condition the compiler cannot fold away: the calls
    // are still semantically analysed, so a signature mistake is a compile error, but
    // nothing is emitted. Zig's test runner fails a test that logs at `err` level,
    // which is correct behaviour and not something to opt out of just to prove that a
    // format string compiles.
    var never = false;
    _ = &never;
    if (never) {
        log.err("err {d}", .{1});
        log.warn("warn {d}", .{2});
        log.info("info {d}", .{3});
        log.debug("debug {d}", .{4});
        log.trace("trace {d}", .{5});
    }
}
