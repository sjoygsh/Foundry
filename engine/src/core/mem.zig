//! Allocator helpers.
//!
//! There is no global allocator. Every allocating API takes one explicitly; this file
//! only adds the arena wrapper that the frame and scratch lifetimes use.
//! See `docs/design/core-memory-and-handles.md` §1.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("assert.zig");

pub const Allocator = std.mem.Allocator;

/// A bulk-reset region, for memory whose lifetime is exactly one frame or one call.
///
/// **Nothing allocated here may outlive the reset.** Storing a pointer from a frame
/// arena in persistent state is the single most likely misuse of the allocator model,
/// and it presents as memory corruption rather than as a lifetime error — so in safe
/// builds `reset` releases the memory to the child allocator instead of retaining it,
/// letting a leak-checking allocator catch the use-after-reset at the point of use.
/// Release builds retain capacity, so steady state performs no syscalls.
pub const Arena = struct {
    inner: std.heap.ArenaAllocator,

    pub fn init(child: Allocator) Arena {
        return .{ .inner = std.heap.ArenaAllocator.init(child) };
    }

    pub fn deinit(self: *Arena) void {
        self.inner.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Arena) Allocator {
        return self.inner.allocator();
    }

    /// Invalidates every allocation made since the last reset.
    pub fn reset(self: *Arena) void {
        _ = self.inner.reset(if (comptime assert.checks_enabled) .free_all else .retain_capacity);
    }
};

test "arena hands out memory and reuses it after reset" {
    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    const a = try arena.allocator().alloc(u8, 128);
    @memset(a, 1);
    try std.testing.expectEqual(@as(u8, 1), a[127]);

    arena.reset();

    const b = try arena.allocator().alloc(u8, 128);
    @memset(b, 2);
    try std.testing.expectEqual(@as(u8, 2), b[127]);
}

test "arena survives many reset cycles without leaking" {
    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        _ = try arena.allocator().alloc(u64, i + 1);
        arena.reset();
    }
    // testing.allocator fails the test on leak, which is the actual assertion here.
}
