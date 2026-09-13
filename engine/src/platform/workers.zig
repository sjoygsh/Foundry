//! The worker pool: threads behind `core.Jobs`.
//!
//! **The one place Foundry starts threads to do its own work** (ADR-0036). Everything that
//! splits work is handed a `core.Jobs` and never learns whether threads are behind it. That is
//! what makes this pool and `core.jobs.serial` interchangeable, and it is `core.jobs`'s
//! contract — not care taken here — that makes their results identical.
//!
//! ## How a split runs
//!
//! A fixed number of threads start with the pool and stop with it. Nothing is created per
//! split, and a split allocates nothing. `run` publishes a job under the pool's lock and wakes
//! every worker. Every participant, the calling thread included, claims the next chunk index
//! with one atomic increment until none remain. The caller then waits, under the lock, until
//! every worker that entered the job has left it, so a job never outlives the stack frame it
//! lives in.
//!
//! Idle workers wait on a condition variable rather than spinning (`jobs-and-threading.md`
//! §12, and Step 2's Resolution for the measurement behind that).
//!
//! **A split inside a chunk runs inline**, on that chunk's thread and in index order, detected
//! by a thread-local flag. The result is the same by the contract, and a pool cannot deadlock
//! waiting on itself. A split of one chunk runs inline too, since there is nobody to share it
//! with.
//!
//! **One dispatcher at a time.** A pool is driven by the thread that owns it. Two threads
//! dispatching into one pool at once is a programmer error, and is asserted.
//!
//! ## Why the `Io` is handed in
//!
//! Blocking belongs to `std.Io` in Zig 0.16. `Os` owns the process's instance and never lets
//! it out, so `Os.startWorkers` constructs the pool and passes its own. This file names
//! `std.Thread` and `std.Io`'s mutex and condition variable, and nothing else in Foundry does,
//! so the next `std` move changes this file (ADR-0001).
//!
//! Design: `docs/design/jobs-and-threading.md` §4.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Jobs = core.jobs.Jobs;
const Task = core.jobs.Task;
const log = core.log.scoped(.platform);

pub const Options = struct {
    /// Threads besides the one that calls `run`. Zero is serial.
    count: u16,
};

/// The most threads one pool starts. Past any machine this runs on; it exists so that a
/// mistaken count costs a warning rather than the process's thread quota.
pub const max_count: u16 = 64;

/// One fewer than the logical CPUs, leaving the calling thread its own — or zero when the count
/// cannot be read. The engine's default. M12's exit sweep kept it on a CPU with efficiency cores:
/// every split span got faster with each added worker (`jobs-and-threading.md`, Step 6).
pub fn defaultCount() u16 {
    const cpus = std.Thread.getCpuCount() catch return 0;
    return @intCast(@min(cpus -| 1, max_count));
}

/// True on a thread while it runs a chunk, so that a split inside one runs inline.
threadlocal var in_chunk: bool = false;

pub const Workers = struct {
    gpa: Allocator,
    io: Io,
    threads: []std.Thread,
    /// How many of `threads` actually started.
    started: u16 = 0,

    mutex: Io.Mutex = .init,
    /// Workers wait here for a new job, or to stop.
    work: Io.Condition = .init,
    /// The dispatching thread waits here for a job's workers to leave it.
    left: Io.Condition = .init,

    // Guarded by `mutex`.
    job: ?*Job = null,
    generation: u64 = 0,
    stopping: bool = false,

    dispatching: std.atomic.Value(bool) = .init(false),

    const Job = struct {
        task: Task,
        chunks: u32,
        /// The next unclaimed index. Wide, so each participant's one failed claim can never wrap
        /// it back into range.
        next: std.atomic.Value(u64) = .init(0),
        /// Workers inside this job. Guarded by `Workers.mutex`.
        workers: u32 = 0,
    };

    /// Starts `options.count` threads, or as many as the system will give.
    ///
    /// **A thread that cannot start is a warning, not a failure.** Fewer workers compute the
    /// same bytes more slowly (`core.jobs`), so refusing to start the engine over it would trade
    /// a slower game for no game.
    pub fn init(gpa: Allocator, io: Io, options: Options) Allocator.Error!*Workers {
        const wanted = @min(options.count, max_count);
        if (wanted < options.count) {
            log.warn("{d} worker threads asked for; starting {d}", .{ options.count, wanted });
        }

        const self = try gpa.create(Workers);
        errdefer gpa.destroy(self);
        const threads = try gpa.alloc(std.Thread, wanted);
        self.* = .{ .gpa = gpa, .io = io, .threads = threads };

        for (threads) |*thread| {
            thread.* = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
                log.warn("started {d} of {d} worker threads ({t}); splits run on fewer", .{
                    self.started,
                    wanted,
                    err,
                });
                break;
            };
            self.started += 1;
        }
        return self;
    }

    /// Stops and joins every worker. No split may be running.
    pub fn deinit(self: *Workers) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        self.work.broadcast(self.io);

        for (self.threads[0..self.started]) |thread| thread.join();
        const gpa = self.gpa;
        gpa.free(self.threads);
        gpa.destroy(self);
    }

    /// The capability to hand to whatever splits work. Must not outlive the pool.
    pub fn jobs(self: *Workers) Jobs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Threads besides the caller's that actually started.
    pub fn threadCount(self: *const Workers) u16 {
        return self.started;
    }

    const vtable: Jobs.VTable = .{ .run = run };

    fn run(ptr: *anyopaque, chunks: u32, task: Task) void {
        const self: *Workers = @ptrCast(@alignCast(ptr));
        if (chunks == 0) return;

        if (self.started == 0 or chunks == 1 or in_chunk) {
            var i: u32 = 0;
            while (i < chunks) : (i += 1) task.call(task.context, i);
            return;
        }

        core.assert.always(
            self.dispatching.cmpxchgStrong(false, true, .acquire, .monotonic) == null,
            "a worker pool takes one split at a time, from the thread that drives it",
            .{},
        );
        defer self.dispatching.store(false, .release);

        var job: Job = .{ .task = task, .chunks = chunks };
        self.mutex.lockUncancelable(self.io);
        self.job = &job;
        self.generation += 1;
        self.mutex.unlock(self.io);
        self.work.broadcast(self.io);

        drain(&job);

        // Every chunk is claimed, so any worker still inside is finishing its last one. Only
        // once they have all left may `job` — on this stack frame — go out of scope.
        self.mutex.lockUncancelable(self.io);
        while (job.workers != 0) self.left.waitUncancelable(self.io, &self.mutex);
        self.job = null;
        self.mutex.unlock(self.io);
    }

    fn drain(job: *Job) void {
        const outer = in_chunk;
        in_chunk = true;
        defer in_chunk = outer;

        while (true) {
            const index = job.next.fetchAdd(1, .monotonic);
            if (index >= job.chunks) return;
            job.task.call(job.task.context, @intCast(index));
        }
    }

    fn workerMain(self: *Workers) void {
        var seen: u64 = 0;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (true) {
            while (!self.stopping and self.generation == seen) {
                self.work.waitUncancelable(self.io, &self.mutex);
            }
            if (self.stopping) return;
            seen = self.generation;
            // Already withdrawn when the caller claimed every chunk before this worker woke.
            const job = self.job orelse continue;

            job.workers += 1;
            self.mutex.unlock(self.io);
            drain(job);
            self.mutex.lockUncancelable(self.io);
            job.workers -= 1;
            if (job.workers == 0) self.left.signal(self.io);
        }
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

/// A pool on an `Io` of its own, the way `Os.startWorkers` makes one on the process's. Must not
/// move once started: the `Io` publishes its own address.
const TestPool = struct {
    threaded: Io.Threaded,
    workers: *Workers,

    fn start(self: *TestPool, count: u16) !void {
        self.threaded = .init(testing.allocator, .{});
        errdefer self.threaded.deinit();
        self.workers = try Workers.init(testing.allocator, self.threaded.io(), .{ .count = count });
    }

    fn stop(self: *TestPool) void {
        self.workers.deinit();
        self.threaded.deinit();
    }
};

test "every index runs exactly once across real threads, split after split" {
    var pool: TestPool = undefined;
    try pool.start(4);
    defer pool.stop();

    const hits = try testing.allocator.alloc(u8, 70_000);
    defer testing.allocator.free(hits);

    const Mark = struct {
        fn call(context: *anyopaque, index: u32) void {
            const out: [*]u8 = @ptrCast(context);
            // Each index is its own byte, so chunks on different threads never share one.
            out[index] += 1;
        }
    };

    // Around the worker count, where claiming is most contested, and then large enough to
    // spread across every thread.
    for ([_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 64, 1000, 70_000 }) |chunks| {
        const repeats: usize = if (chunks <= 64) 200 else 10;
        for (0..repeats) |_| {
            @memset(hits[0..chunks], 0);
            pool.workers.jobs().run(chunks, .{ .context = @ptrCast(hits.ptr), .call = Mark.call });
            for (hits[0..chunks]) |n| try testing.expectEqual(@as(u8, 1), n);
        }
    }
}

test "a split through the pool computes the bytes a serial split computes" {
    var pool: TestPool = undefined;
    try pool.start(4);
    defer pool.stop();

    const Hash = struct {
        slots: [64]u64 = @splat(0),

        fn chunk(self: *@This(), c: core.jobs.Chunk) void {
            var h: u64 = 0xcbf29ce484222325;
            for (c.begin..c.end) |i| h = (h ^ (@as(u64, i) *% 0x9e3779b97f4a7c15)) *% 0x100000001b3;
            self.slots[c.index] = h;
        }
    };

    const len = 63 * 1024 + 17;
    var reference: Hash = .{};
    core.jobs.serial.forChunks(len, 1024, &reference, Hash.chunk);

    for (0..50) |_| {
        var parallel: Hash = .{};
        pool.workers.jobs().forChunks(len, 1024, &parallel, Hash.chunk);
        try testing.expectEqualSlices(u64, &reference.slots, &parallel.slots);
    }
}

test "two chunks of one split really do run at the same time" {
    var pool: TestPool = undefined;
    try pool.start(1);
    defer pool.stop();

    // Each chunk arrives and then waits for the other. Run one after the other, neither could
    // ever see the other arrive, so the wait is bounded rather than trusted: a serial pool fails
    // this test in ten seconds instead of hanging it.
    const Meet = struct {
        io: Io,
        arrived: [2]std.atomic.Value(bool) = .{ .init(false), .init(false) },
        met: [2]bool = .{ false, false },

        fn call(context: *anyopaque, index: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.arrived[index].store(true, .release);
            const start = Io.Clock.awake.now(self.io);
            while (!self.arrived[1 - index].load(.acquire)) {
                const waited = start.durationTo(Io.Clock.awake.now(self.io)).toNanoseconds();
                if (waited > 10_000_000_000) return;
                std.Thread.yield() catch {};
            }
            self.met[index] = true;
        }
    };

    var meet: Meet = .{ .io = pool.threaded.io() };
    pool.workers.jobs().run(2, .{ .context = &meet, .call = Meet.call });
    try testing.expect(meet.met[0] and meet.met[1]);
}

test "a split inside a chunk runs inline, on that chunk's thread, in order" {
    var pool: TestPool = undefined;
    try pool.start(3);
    defer pool.stop();

    const rows = 8;
    const cols = 16;
    const Grid = struct {
        const Self = @This();
        const Row = struct { grid: *Self, row: u32 };

        jobs: Jobs,
        outer_thread: [rows]std.Thread.Id = undefined,
        inner_thread: [rows * cols]std.Thread.Id = undefined,
        order: [rows][cols]u32 = undefined,
        seen: [rows]u32 = @splat(0),

        fn rowChunk(self: *Self, c: core.jobs.Chunk) void {
            for (c.begin..c.end) |r| {
                self.outer_thread[r] = std.Thread.getCurrentId();
                self.jobs.forChunks(cols, 1, Row{ .grid = self, .row = @intCast(r) }, colChunk);
            }
        }

        fn colChunk(row: Row, c: core.jobs.Chunk) void {
            const grid = row.grid;
            grid.inner_thread[row.row * cols + c.begin] = std.Thread.getCurrentId();
            grid.order[row.row][grid.seen[row.row]] = c.index;
            grid.seen[row.row] += 1;
        }
    };

    for (0..20) |_| {
        var grid: Grid = .{ .jobs = pool.workers.jobs() };
        grid.jobs.forChunks(rows, 1, &grid, Grid.rowChunk);

        for (0..rows) |r| {
            try testing.expectEqual(@as(u32, cols), grid.seen[r]);
            for (0..cols) |k| {
                try testing.expectEqual(@as(u32, @intCast(k)), grid.order[r][k]);
                try testing.expectEqual(grid.outer_thread[r], grid.inner_thread[r * cols + k]);
            }
        }
    }
}

test "a pool of zero workers runs every chunk on the calling thread, in order" {
    var pool: TestPool = undefined;
    try pool.start(0);
    defer pool.stop();
    try testing.expectEqual(@as(u16, 0), pool.workers.threadCount());

    const Record = struct {
        caller: std.Thread.Id,
        order: [10]u32 = undefined,
        n: usize = 0,
        elsewhere: bool = false,

        fn call(context: *anyopaque, index: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.Thread.getCurrentId() != self.caller) self.elsewhere = true;
            self.order[self.n] = index;
            self.n += 1;
        }
    };

    var record: Record = .{ .caller = std.Thread.getCurrentId() };
    pool.workers.jobs().run(10, .{ .context = &record, .call = Record.call });
    try testing.expect(!record.elsewhere);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, record.order[0..record.n]);
}

test "pools start and stop cleanly, whether or not they split anything" {
    const Sum = struct {
        fn call(context: *anyopaque, index: u32) void {
            const slots: [*]u64 = @ptrCast(@alignCast(context));
            slots[index] = index;
        }
    };

    for (0..20) |round| {
        const count: u16 = @intCast(1 + round % 8);
        var pool: TestPool = undefined;
        try pool.start(count);
        defer pool.stop();
        try testing.expectEqual(count, pool.workers.threadCount());

        if (round % 2 == 1) {
            var slots: [32]u64 = @splat(0);
            pool.workers.jobs().run(slots.len, .{ .context = @ptrCast(&slots), .call = Sum.call });
            for (slots, 0..) |v, i| try testing.expectEqual(@as(u64, i), v);
        }
    }

    const cpus = std.Thread.getCpuCount() catch 1;
    try testing.expectEqual(@as(u16, @intCast(@min(cpus -| 1, max_count))), defaultCount());
}
