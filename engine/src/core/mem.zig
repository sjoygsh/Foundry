//! Allocator helpers.
//!
//! There is no global allocator. Every allocating API takes one explicitly; this file
//! only adds the arena wrapper that the frame and scratch lifetimes use.
//! See `docs/design/core-memory-and-handles.md` §1.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("assert.zig");

pub const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

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
    /// The largest capacity seen at a reset. See `highWater`.
    peak_bytes: usize = 0,

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
        // Sampled *before* the reset, because that is the only moment the number exists:
        // a safe build's `free_all` takes the capacity to zero, so asking afterwards would
        // always answer nothing.
        self.peak_bytes = @max(self.peak_bytes, self.inner.queryCapacity());
        _ = self.inner.reset(if (comptime assert.checks_enabled) .free_all else .retain_capacity);
    }

    /// The most this arena has ever held at a reset — the number that says what per-frame
    /// garbage actually costs.
    ///
    /// **It means slightly different things in the two build modes**, and the difference is
    /// worth knowing rather than papering over. A safe build resets with `free_all`, so
    /// each sample is exactly what *that* interval allocated and the maximum is the worst
    /// frame. A release build retains capacity, so a sample is the largest the arena has
    /// grown to — the same high-water mark, arrived at from the other side, but with no
    /// per-frame reading behind it.
    ///
    /// Capacity rather than bytes handed out: it is what the allocator actually holds from
    /// the child, and it costs nothing to ask. An exact per-allocation count is what
    /// `Counted` is for, and putting one here would add an indirection to every frame
    /// allocation to sharpen a debug number.
    pub fn highWater(self: *const Arena) usize {
        return @max(self.peak_bytes, self.inner.queryCapacity());
    }
};

/// An allocator that counts what passes through it, under a name.
///
/// **Opt-in, per owner.** There is no global allocator in Foundry (`CLAUDE.md` §7), so there
/// is nothing global to ask how much memory a subsystem is using — the owner of an
/// allocator is the only one who can answer, and this is how they choose to. It costs one
/// indirect call and a few additions per allocation, which is why nothing imposes it:
/// Foundry allocates in bulk and rarely, so a counter on a subsystem is cheap in exactly
/// the places it is interesting.
///
/// **Single-threaded.** The fields are plain integers, and a counter belongs to whoever
/// owns the allocator. Foundry's second thread does not allocate — `audio.md` made "nothing
/// in the callback can fail" a design property and no-allocation is half of what that
/// means — so making these atomic would cost every allocation in the engine to serve a
/// caller that does not exist. A job system changes that, and owes this an answer
/// (`debug-overlay.md` §15).
///
/// Design: `docs/design/debug-overlay.md` §5.
pub const Counted = struct {
    /// What a report calls this. Borrowed, and expected to outlive the counter — a literal
    /// in every current caller.
    name: []const u8,
    /// Where the memory actually comes from.
    child: Allocator,

    /// Bytes allocated through here and not yet freed.
    live_bytes: usize = 0,
    /// The largest `live_bytes` has ever been.
    peak_bytes: usize = 0,
    allocations: u64 = 0,
    frees: u64 = 0,
    /// Allocations the child refused. Worth a number of its own: a subsystem that is
    /// quietly failing to allocate looks identical to one that is not trying.
    failures: u64 = 0,

    pub fn init(name: []const u8, child: Allocator) Counted {
        return .{ .name = name, .child = child };
    }

    pub fn allocator(self: *Counted) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Zeroes the counts without touching the memory. For a caller that wants a number
    /// over an interval rather than over a lifetime; `live_bytes` is deliberately **not**
    /// reset, because the memory is still out there.
    pub fn resetCounts(self: *Counted) void {
        self.peak_bytes = self.live_bytes;
        self.allocations = 0;
        self.frees = 0;
        self.failures = 0;
    }

    const vtable: Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counted = @ptrCast(@alignCast(ctx));
        const bytes = self.child.rawAlloc(len, alignment, ret_addr) orelse {
            self.failures += 1;
            return null;
        };
        self.grow(len);
        self.allocations += 1;
        return bytes;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counted = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.adjust(memory.len, new_len);
        return true;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counted = @ptrCast(@alignCast(ctx));
        const bytes = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.adjust(memory.len, new_len);
        return bytes;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *Counted = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        // Saturating, and not because it is expected to matter: memory allocated before a
        // counter was wrapped around an allocator and freed after it would underflow, and
        // a report that says 18 exabytes is worse than one that says zero.
        self.live_bytes -|= memory.len;
        self.frees += 1;
    }

    fn grow(self: *Counted, len: usize) void {
        self.live_bytes += len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }

    /// A resize is neither an allocation nor a free — the count of live allocations is
    /// unchanged and only the bytes move.
    fn adjust(self: *Counted, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.grow(new_len - old_len);
        } else {
            self.live_bytes -|= old_len - new_len;
        }
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

test "a counted allocator follows a known sequence exactly" {
    var counted = Counted.init("test", std.testing.allocator);
    const gpa = counted.allocator();

    const a = try gpa.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), counted.live_bytes);
    try std.testing.expectEqual(@as(u64, 1), counted.allocations);

    const b = try gpa.alloc(u8, 60);
    try std.testing.expectEqual(@as(usize, 160), counted.live_bytes);
    try std.testing.expectEqual(@as(usize, 160), counted.peak_bytes);

    gpa.free(b);
    try std.testing.expectEqual(@as(usize, 100), counted.live_bytes);
    try std.testing.expectEqual(@as(u64, 1), counted.frees);
    // The peak is the point: it survives the free that follows it, because "how much did
    // this ever hold" is the question a memory report is asked.
    try std.testing.expectEqual(@as(usize, 160), counted.peak_bytes);

    gpa.free(a);
    try std.testing.expectEqual(@as(usize, 0), counted.live_bytes);
    try std.testing.expectEqual(@as(u64, 2), counted.allocations);
    try std.testing.expectEqual(@as(u64, 2), counted.frees);
    try std.testing.expectEqual(@as(u64, 0), counted.failures);
}

test "a resize moves bytes without moving the allocation count" {
    var counted = Counted.init("test", std.testing.allocator);
    const gpa = counted.allocator();

    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);

    // Enough appends to force at least one growth, whichever strategy the list uses.
    for (0..256) |i| try list.append(gpa, @intCast(i));
    try std.testing.expect(counted.live_bytes >= 256 * @sizeOf(u32));
    try std.testing.expect(counted.peak_bytes >= counted.live_bytes);

    const before = counted.allocations + counted.frees;
    list.clearAndFree(gpa);
    try std.testing.expectEqual(@as(usize, 0), counted.live_bytes);
    try std.testing.expect(counted.allocations + counted.frees > before);
}

test "a refused allocation is counted and is not a live byte" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var counted = Counted.init("test", failing.allocator());
    const gpa = counted.allocator();

    const ok = try gpa.alloc(u8, 32);
    try std.testing.expectEqual(@as(usize, 32), counted.live_bytes);

    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 32));
    try std.testing.expectEqual(@as(u64, 1), counted.failures);
    // The failure changed nothing else: a report that counted memory nobody got would be
    // worse than no report.
    try std.testing.expectEqual(@as(usize, 32), counted.live_bytes);
    try std.testing.expectEqual(@as(u64, 1), counted.allocations);

    gpa.free(ok);
}

test "counts reset without pretending the memory went away" {
    var counted = Counted.init("test", std.testing.allocator);
    const gpa = counted.allocator();

    const held = try gpa.alloc(u8, 48);
    defer gpa.free(held);
    const gone = try gpa.alloc(u8, 200);
    gpa.free(gone);
    try std.testing.expectEqual(@as(usize, 248), counted.peak_bytes);

    counted.resetCounts();
    try std.testing.expectEqual(@as(usize, 48), counted.live_bytes);
    try std.testing.expectEqual(@as(usize, 48), counted.peak_bytes);
    try std.testing.expectEqual(@as(u64, 0), counted.allocations);
}

test "the arena reports the most it has ever held" {
    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), arena.highWater());

    _ = try arena.allocator().alloc(u8, 4096);
    try std.testing.expect(arena.highWater() >= 4096);
    arena.reset();

    // Still the peak after the reset that emptied it, in both reset modes: a safe build
    // freed everything and a release build retained the capacity, and the high-water mark
    // is the same number either way.
    try std.testing.expect(arena.highWater() >= 4096);

    _ = try arena.allocator().alloc(u8, 128);
    arena.reset();
    try std.testing.expect(arena.highWater() >= 4096);
}

test "a counted arena is exact where the arena's own number is approximate" {
    // The composition `debug-overlay.md` §5 points at: an arena's capacity is what it holds
    // from its child, and a `Counted` underneath it is what it actually asked for.
    var counted = Counted.init("frame", std.testing.allocator);
    var arena = Arena.init(counted.allocator());
    defer arena.deinit();

    _ = try arena.allocator().alloc(u8, 1024);
    try std.testing.expect(counted.live_bytes >= 1024);
    try std.testing.expect(arena.highWater() >= 1024);
}
