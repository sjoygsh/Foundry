//! Parallel work that cannot change a result: the interface, and the one way work is split.
//!
//! **Explicit, the way an allocator is** (ADR-0036). Any API that may split work takes a
//! `Jobs`. There is no global pool, no ambient thread count and no hidden worker, and code
//! handed `serial` runs on the calling thread in index order — which is what every call site
//! did before M12 and what each still does by default.
//!
//! `core` holds no thread. This file is data and function pointers; the implementation with
//! threads belongs to `platform`, is created by `app`, and is handed on by whoever owns the
//! work. That is what lets `scene` and `render2d`, which cannot see `platform`, be handed
//! parallelism rather than reach for it.
//!
//! ## The contract, and why it is deterministic
//!
//! `Jobs.forChunks` splits `0..len` into chunks of `grain` items. Chunk `i` covers
//! `[i * grain, min((i + 1) * grain, len))` — a function of `len` and `grain` alone, never of
//! how many workers there are — and the call returns when every chunk has returned.
//!
//! A chunk writes only what no other chunk reads or writes, allocates nothing, observes
//! neither its thread nor a clock, and leaves anything it produces in a slot the caller
//! preallocated for its index. The caller reads those slots in index order after the call.
//! Under those rules every interleaving computes the bytes a serial run in index order
//! computes, which is I9 with nothing borrowed from luck.
//!
//! **`reversed` exists to prove it.** It runs chunks last to first on the calling thread, so
//! a call site that secretly depends on order fails an ordinary test, on one thread, every
//! time — rather than waiting for a race to happen to occur.
//!
//! Design: `docs/design/jobs-and-threading.md` §3.

const std = @import("std");

/// One piece of a split: which piece it is, and the half-open range of items it covers.
pub const Chunk = struct {
    index: u32,
    begin: u32,
    end: u32,

    pub fn len(self: Chunk) u32 {
        return self.end - self.begin;
    }
};

/// What an executor is handed: something to call once per index, and what to call it with.
///
/// Type-erased because the executor is behind a table, and C-shaped on purpose — a count, a
/// context and a function taking an index is what a later ABI table could carry unchanged
/// (`jobs-and-threading.md` §7).
pub const Task = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, index: u32) void,
};

/// The capability to split work. A pointer and a one-function table, shaped like
/// `std.mem.Allocator`, and passed around the same way.
///
/// Like an allocator, it must not outlive whatever it was taken from.
pub const Jobs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Calls `task.call(task.context, i)` exactly once for every `i` in `0..count`,
        /// possibly concurrently and in any order, and returns after the last has returned.
        /// `count` may be zero, in which case nothing is called.
        run: *const fn (ptr: *anyopaque, count: u32, task: Task) void,
    };

    /// The raw form an executor implements. Call sites use `forChunks`.
    pub fn run(self: Jobs, count: u32, task: Task) void {
        self.vtable.run(self.ptr, count, task);
    }

    /// Splits `0..len` into chunks of `grain` items and calls `chunkFn(context, chunk)` once
    /// for each, returning when all have returned.
    ///
    /// `grain` is the call site's named constant, chosen for its work and never derived from
    /// a worker count. A `grain` of zero is a programmer error. `context` is shared by every
    /// chunk, so whatever it points to must either be read-only for the call or be indexed by
    /// chunk — see the module comment.
    pub fn forChunks(
        self: Jobs,
        len: u32,
        grain: u32,
        context: anytype,
        comptime chunkFn: fn (@TypeOf(context), Chunk) void,
    ) void {
        const count = chunkCount(len, grain);
        if (count == 0) return;

        const Split = struct {
            context: @TypeOf(context),
            len: u32,
            grain: u32,

            fn call(erased: *anyopaque, index: u32) void {
                const split: *const @This() = @ptrCast(@alignCast(erased));
                chunkFn(split.context, chunkAt(split.len, split.grain, index));
            }
        };
        // On this stack frame, which outlives every call because `run` joins before it
        // returns. That is the whole reason a split needs no allocation.
        var split: Split = .{ .context = context, .len = len, .grain = grain };
        self.run(count, .{ .context = &split, .call = Split.call });
    }
};

/// How many chunks `len` items make at `grain` apiece.
pub fn chunkCount(len: u32, grain: u32) u32 {
    std.debug.assert(grain > 0);
    // Not `(len + grain - 1) / grain`, which overflows for a length near the top of the range.
    return len / grain + @intFromBool(len % grain != 0);
}

/// The `index`-th chunk of `len` items at `grain` apiece.
pub fn chunkAt(len: u32, grain: u32, index: u32) Chunk {
    std.debug.assert(index < chunkCount(len, grain));
    // Wide, because the last chunk's `begin + grain` can pass the top of `u32` even though
    // its clamped end cannot.
    const begin: u64 = @as(u64, index) * grain;
    const end: u64 = @min(begin + grain, len);
    return .{ .index = index, .begin = @intCast(begin), .end = @intCast(end) };
}

/// Runs every index on the calling thread, in order. The default everywhere a `Jobs` is
/// taken, and the reference every parallel result is compared against.
pub const serial: Jobs = .{ .ptr = undefined, .vtable = &serial_vtable };

/// Runs every index on the calling thread, last to first.
///
/// **For tests.** It is a legal executor — the contract allows any order — and the most
/// adversarial one that needs no threads: a call site whose result differs under it depends
/// on an order it was never promised.
pub const reversed: Jobs = .{ .ptr = undefined, .vtable = &reversed_vtable };

const serial_vtable: Jobs.VTable = .{ .run = runSerial };
const reversed_vtable: Jobs.VTable = .{ .run = runReversed };

fn runSerial(_: *anyopaque, count: u32, task: Task) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) task.call(task.context, i);
}

fn runReversed(_: *anyopaque, count: u32, task: Task) void {
    var i = count;
    while (i > 0) {
        i -= 1;
        task.call(task.context, i);
    }
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const executors = [_]struct { name: []const u8, jobs: Jobs }{
    .{ .name = "serial", .jobs = serial },
    .{ .name = "reversed", .jobs = reversed },
};

test "chunk boundaries depend on the length and the grain, and on nothing else" {
    const grain: u32 = 4;
    // Empty, one, just under, exactly, just over, and a multiple of the grain.
    const cases = [_]struct { len: u32, count: u32 }{
        .{ .len = 0, .count = 0 },
        .{ .len = 1, .count = 1 },
        .{ .len = grain - 1, .count = 1 },
        .{ .len = grain, .count = 1 },
        .{ .len = grain + 1, .count = 2 },
        .{ .len = 3 * grain, .count = 3 },
    };
    for (cases) |case| {
        const count = chunkCount(case.len, grain);
        try testing.expectEqual(case.count, count);

        // Contiguous from zero to `len`, every chunk non-empty, every chunk but the last
        // exactly `grain` long.
        var expected_begin: u32 = 0;
        for (0..count) |i| {
            const chunk = chunkAt(case.len, grain, @intCast(i));
            try testing.expectEqual(@as(u32, @intCast(i)), chunk.index);
            try testing.expectEqual(expected_begin, chunk.begin);
            try testing.expect(chunk.len() > 0);
            if (i + 1 < count) try testing.expectEqual(grain, chunk.len());
            try testing.expect(chunk.len() <= grain);
            expected_begin = chunk.end;
        }
        try testing.expectEqual(case.len, expected_begin);
    }
}

test "the widest length splits without overflowing" {
    const max = std.math.maxInt(u32);

    try testing.expectEqual(@as(u32, 1), chunkCount(max, max));
    try testing.expectEqual(Chunk{ .index = 0, .begin = 0, .end = max }, chunkAt(max, max, 0));

    // The last chunk's unclamped end is past the top of `u32`.
    const half: u32 = 1 << 31;
    try testing.expectEqual(@as(u32, 2), chunkCount(max, half));
    try testing.expectEqual(Chunk{ .index = 1, .begin = half, .end = max }, chunkAt(max, half, 1));

    const count = chunkCount(max, 3);
    try testing.expectEqual(@as(u32, 1_431_655_765), count);
    try testing.expectEqual(max, chunkAt(max, 3, count - 1).end);
}

test "every item is visited exactly once, by exactly one chunk, under either executor" {
    const grain: u32 = 8;
    const Visits = struct {
        by_item: [3 * 8 + 1]u8 = @splat(0),
        by_chunk: [4]u8 = @splat(0),

        fn visit(self: *@This(), chunk: Chunk) void {
            self.by_chunk[chunk.index] += 1;
            for (chunk.begin..chunk.end) |i| self.by_item[i] += 1;
        }
    };

    for (executors) |executor| {
        for ([_]u32{ 0, 1, grain - 1, grain, grain + 1, 3 * grain, 3 * grain + 1 }) |len| {
            var visits: Visits = .{};
            executor.jobs.forChunks(len, grain, &visits, Visits.visit);

            for (visits.by_item, 0..) |n, i| {
                try testing.expectEqual(@as(u8, @intFromBool(i < len)), n);
            }
            for (visits.by_chunk, 0..) |n, i| {
                try testing.expectEqual(@as(u8, @intFromBool(i < chunkCount(len, grain))), n);
            }
        }
    }
}

test "serial runs chunks in index order and reversed in the opposite order" {
    const Order = struct {
        seen: [5]u32 = undefined,
        n: usize = 0,

        fn note(self: *@This(), chunk: Chunk) void {
            self.seen[self.n] = chunk.index;
            self.n += 1;
        }
    };

    var forward: Order = .{};
    serial.forChunks(10, 2, &forward, Order.note);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, forward.seen[0..forward.n]);

    var backward: Order = .{};
    reversed.forChunks(10, 2, &backward, Order.note);
    try testing.expectEqualSlices(u32, &.{ 4, 3, 2, 1, 0 }, backward.seen[0..backward.n]);
}

test "results read from slots in index order agree under any order; a shared running total does not" {
    // The two ways to combine a split's results, side by side. Each chunk folds its own items
    // into an order-sensitive hash: once into its own slot, and once into a hash every chunk
    // shares. The slots are folded in index order afterwards. **Only the slots may be used**,
    // and this is the test that says why: under `reversed`, the shared total changes.
    const Combine = struct {
        const grain = 16;
        slots: [4]u64 = @splat(0),
        shared: u64 = offset,

        const offset: u64 = 0xcbf29ce484222325;
        const prime: u64 = 0x100000001b3;

        fn fold(hash: u64, value: u64) u64 {
            return (hash ^ value) *% prime;
        }

        fn chunk(self: *@This(), c: Chunk) void {
            var own: u64 = offset;
            for (c.begin..c.end) |i| {
                own = fold(own, i * i);
                self.shared = fold(self.shared, i * i);
            }
            self.slots[c.index] = own;
        }

        fn combined(self: *const @This()) u64 {
            var hash: u64 = offset;
            for (self.slots) |slot| hash = fold(hash, slot);
            return hash;
        }
    };

    const len = 4 * Combine.grain - 3;
    var forward: Combine = .{};
    serial.forChunks(len, Combine.grain, &forward, Combine.chunk);
    var backward: Combine = .{};
    reversed.forChunks(len, Combine.grain, &backward, Combine.chunk);

    try testing.expectEqual(forward.combined(), backward.combined());
    try testing.expect(forward.shared != backward.shared);
}

test "a split inside a chunk computes what a flat loop computes" {
    // A grid filled row-chunk by row-chunk, each row split again by column. Every cell is
    // written by exactly one inner chunk, so the result must equal a flat loop's.
    const Grid = struct {
        const rows = 7;
        const cols = 11;
        const row_grain = 3;
        const col_grain = 4;

        cells: [rows * cols]u32 = @splat(0),
        jobs: Jobs,

        const Row = struct { grid: *Grid, row: u32 };
        const Grid = @This();

        fn rowChunk(self: *Grid, chunk: Chunk) void {
            for (chunk.begin..chunk.end) |r| {
                const row: Row = .{ .grid = self, .row = @intCast(r) };
                self.jobs.forChunks(cols, col_grain, row, colChunk);
            }
        }

        fn colChunk(row: Row, chunk: Chunk) void {
            for (chunk.begin..chunk.end) |c| {
                row.grid.cells[row.row * cols + c] = row.row * 100 + @as(u32, @intCast(c));
            }
        }
    };

    var flat: [Grid.rows * Grid.cols]u32 = undefined;
    for (0..Grid.rows) |r| {
        for (0..Grid.cols) |c| flat[r * Grid.cols + c] = @intCast(r * 100 + c);
    }

    for (executors) |executor| {
        var grid: Grid = .{ .jobs = executor.jobs };
        executor.jobs.forChunks(Grid.rows, Grid.row_grain, &grid, Grid.rowChunk);
        try testing.expectEqualSlices(u32, &flat, &grid.cells);
    }
}

test "an executor is handed only a count and a task, and the task maps each index to its chunk" {
    // What `platform`'s pool will implement, reduced to its contract: this executor sees
    // nothing but the table's arguments, and runs the indices in an order of its own choosing.
    const Shuffled = struct {
        counts_seen: [2]u32 = undefined,
        calls: usize = 0,

        fn jobs(self: *@This()) Jobs {
            return .{ .ptr = self, .vtable = &.{ .run = run } };
        }

        fn run(ptr: *anyopaque, count: u32, task: Task) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.counts_seen[self.calls] = count;
            self.calls += 1;
            // Evens ascending, then odds descending.
            var i: u32 = 0;
            while (i < count) : (i += 2) task.call(task.context, i);
            var j: u32 = if (count % 2 == 0) count else count - 1;
            while (j > 0) {
                j -= 1;
                if (j % 2 == 1) task.call(task.context, j);
            }
        }
    };
    const Seen = struct {
        chunks: [5]?Chunk = @splat(null),

        fn note(self: *@This(), chunk: Chunk) void {
            std.debug.assert(self.chunks[chunk.index] == null);
            self.chunks[chunk.index] = chunk;
        }
    };

    var executor: Shuffled = .{};
    var seen: Seen = .{};
    executor.jobs().forChunks(13, 3, &seen, Seen.note);
    // Zero items never reach the executor at all.
    executor.jobs().forChunks(0, 3, &seen, Seen.note);

    try testing.expectEqual(@as(usize, 1), executor.calls);
    try testing.expectEqual(@as(u32, 5), executor.counts_seen[0]);
    for (seen.chunks, 0..) |chunk, i| {
        try testing.expectEqual(chunkAt(13, 3, @intCast(i)), chunk.?);
    }
}
