//! Assertions, and the distinction that matters more than the mechanism.
//!
//! An assertion guards against **our** bug. Validation guards against **their** bad
//! input. Confusing the two is a security bug, not a tidiness issue: asserting on
//! content, mod, save or file data turns a malformed input into a crash — or, with
//! assertions compiled out, into undefined behaviour.
//!
//! Anything that came from outside the engine is validated and returns an error.
//! Nothing here is appropriate for it. See `docs/design/core-memory-and-handles.md` §5.

const std = @import("std");
const builtin = @import("builtin");

/// True in build modes where safety checks are already enabled.
pub const checks_enabled = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// A programmer-error invariant, compiled out in unsafe release modes.
///
/// The condition must be free of side effects: in release builds it is never evaluated.
pub inline fn debugOnly(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (comptime checks_enabled) {
        if (!ok) fail(fmt, args);
    }
}

/// A programmer-error invariant retained in every build mode.
///
/// Reserved for violations that would mean memory corruption or silent data loss —
/// cases where continuing is worse than stopping. Every use is a deliberate choice to
/// crash rather than proceed, so there should not be many.
pub inline fn always(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (!ok) fail(fmt, args);
}

/// Reached code that should be unreachable. Retained in every build mode.
pub inline fn unreachableCode(comptime fmt: []const u8, args: anytype) noreturn {
    fail(fmt, args);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    std.debug.panic("foundry assertion failed: " ++ fmt, args);
}

test "checks_enabled matches build mode" {
    // Tests run in Debug or ReleaseSafe, both of which keep checks on.
    try std.testing.expect(checks_enabled == (builtin.mode == .Debug or builtin.mode == .ReleaseSafe));
}

test "assertions that hold do not fire" {
    debugOnly(1 + 1 == 2, "arithmetic is broken", .{});
    always(1 + 1 == 2, "arithmetic is broken", .{});
}
