//! The log sink, and the runtime level filter.
//!
//! `core.log` deliberately stops at defining the interface and the compile-time levels:
//! `core` is layer L0 and has no business deciding where output goes. Choosing a
//! destination is an application decision, so it is made here, and a game wires it up
//! with one line in its root source file:
//!
//!     pub const std_options = app.std_options;
//!
//! ## Two filters, and why both
//!
//! The **compile-time** level (`core.log.compiled_level`) decides what is *built*. A call
//! below it is not merely silenced — the call and the evaluation of its arguments are
//! compiled away, which is what makes a `trace` in a hot loop free in a release build.
//!
//! The **runtime** level below decides what a built call *prints*. That is what lets a
//! shipped build be made quiet or verbose without recompiling — the thing you want at
//! three in the morning when a player's log is the only evidence you have.
//!
//! Design: `docs/design/app-and-frame-loop.md` §5.

const std = @import("std");
const core = @import("core");

/// The most verbose level that will actually be printed.
///
/// Atomic because logging is reachable from any thread, and this is set rarely and read
/// often. It is the one piece of genuinely ambient state in Foundry, which is defensible
/// only because logging is ambient by nature: `std.log` reaches it from code that has no
/// engine pointer to ask.
var runtime_level: std.atomic.Value(u8) = .init(@intFromEnum(std.log.Level.debug));

/// Sets the most verbose level that will be printed. Safe to call at any time.
pub fn setLevel(new_level: core.log.Level) void {
    runtime_level.store(@intFromEnum(toStd(new_level)), .monotonic);
}

/// The current runtime level, as a `std.log.Level`.
pub fn level() std.log.Level {
    return @enumFromInt(runtime_level.load(.monotonic));
}

/// `core.log` has one level `std.log` does not. `trace` rides on `debug` with a marker,
/// so it cannot be separated at runtime — only at compile time, which is where the cost
/// of a trace call actually matters.
fn toStd(from: core.log.Level) std.log.Level {
    return switch (from) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug, .trace => .debug,
    };
}

/// Foundry's `logFn`.
///
/// Delegates the actual writing to `std.log.defaultLog` rather than reimplementing it.
/// That is deliberate: std already handles stderr locking, terminal detection and colour,
/// and duplicating those to change a prefix would be work with a maintenance cost and no
/// payoff. What this adds is the runtime filter, which std has no notion of.
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Severity is ordered most-severe-first, so a *lower* value passes a *lower* filter.
    if (@intFromEnum(message_level) > @intFromEnum(level())) return;
    std.log.defaultLog(message_level, scope, format, args);
}

/// Drop this into a game's root source file:
///
///     pub const std_options = app.std_options;
pub const std_options: std.Options = .{
    .logFn = logFn,
    // Everything reaches `logFn`; the runtime filter decides. Foundry's own compile-time
    // filtering already happened in `core.log`, which never builds the call at all below
    // `core.log.compiled_level`.
    .log_level = .debug,
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "the runtime level round-trips" {
    const restore = level();
    defer runtime_level.store(@intFromEnum(restore), .monotonic);

    setLevel(.err);
    try testing.expectEqual(std.log.Level.err, level());
    setLevel(.info);
    try testing.expectEqual(std.log.Level.info, level());
}

test "trace and debug share a runtime level" {
    // `core.log` has five levels and `std.log` has four. Recorded as a test so the
    // collapse is a known property rather than a surprise.
    const restore = level();
    defer runtime_level.store(@intFromEnum(restore), .monotonic);

    setLevel(.trace);
    try testing.expectEqual(std.log.Level.debug, level());
    setLevel(.debug);
    try testing.expectEqual(std.log.Level.debug, level());
}

test "a lower level suppresses the more verbose ones" {
    // Severity is ordered most-severe-first, which reads backwards and is exactly the
    // sort of comparison that gets inverted. `err` must pass an `err` filter; `info`
    // must not.
    const restore = level();
    defer runtime_level.store(@intFromEnum(restore), .monotonic);

    setLevel(.err);
    try testing.expect(@intFromEnum(std.log.Level.err) <= @intFromEnum(level()));
    try testing.expect(@intFromEnum(std.log.Level.warn) > @intFromEnum(level()));
    try testing.expect(@intFromEnum(std.log.Level.info) > @intFromEnum(level()));

    setLevel(.info);
    try testing.expect(@intFromEnum(std.log.Level.err) <= @intFromEnum(level()));
    try testing.expect(@intFromEnum(std.log.Level.warn) <= @intFromEnum(level()));
    try testing.expect(@intFromEnum(std.log.Level.debug) > @intFromEnum(level()));
}

test "the exported std_options names our sink" {
    try testing.expect(std_options.logFn == logFn);
}
