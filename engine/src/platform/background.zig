//! The background pool: threads behind `core.Tasks`.
//!
//! **Beside the frame's pool, never inside it** (ADR-0061). `Workers` must be idle between
//! splits, and its join waits for its slowest chunk; a decode queued on those threads would
//! hold a frame back behind it, which is the stall this pool exists to remove. So background
//! work has threads of its own, a bounded queue, and nothing in common with `Workers` but the
//! way it is started.
//!
//! ## How a task runs
//!
//! A fixed number of threads start with the pool and stop with it. `start` appends to a ring
//! under the pool's lock and wakes one worker; a full ring refuses with `error.Full`, and the
//! task graph tries again at its next poll. Starting allocates nothing. A worker takes the
//! oldest task, runs it outside the lock, then sets its `Done` — after the task's own writes,
//! so whoever sees the flag sees them too.
//!
//! **With no threads**, because none were asked for or none would start, `start` runs the task
//! on the caller. That is `core.tasks.immediate`'s behaviour, so an engine configured with
//! zero background workers is exactly an engine handed `immediate`.
//!
//! **Teardown runs what is queued.** `deinit` lets the workers finish every queued task before
//! they stop, because a task whose flag is never set leaves its graph forever unfinished and
//! unfreeable. The engine's owners quiesce before teardown, so in practice the queue is empty.
//!
//! ## Why the `Io` is handed in
//!
//! For `Workers`' reason: `Os` owns the process's `std.Io` and constructs this pool with it.
//! This file and `workers.zig` are the only ones naming `std.Thread` and `std.Io`'s mutex and
//! condition variable for a pool of Foundry's own (ADR-0001).
//!
//! Design: `docs/design/background.md` §4.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Tasks = core.tasks.Tasks;
const Task = core.tasks.Task;
const Done = core.tasks.Done;
const log = core.log.scoped(.platform);

pub const Options = struct {
    /// Background threads. Zero runs every task on the caller.
    count: u16,
    /// Tasks queued at once. Past it, `start` refuses and the caller tries again later.
    capacity: u32 = 256,
};

/// The most threads one background pool starts, for `Workers.max_count`'s reason.
pub const max_count: u16 = 16;

/// Two threads, or one on a machine with four logical CPUs or fewer, or one when the count
/// cannot be read. Background work competes with the frame's pool for cores, so this is small
/// on purpose; M27 Step 9's sweep measures it (`background.md` §4.1).
pub fn defaultCount() u16 {
    const cpus = std.Thread.getCpuCount() catch return 1;
    return if (cpus <= 4) 1 else 2;
}

pub const Background = struct {
    gpa: Allocator,
    io: Io,
    threads: []std.Thread,
    /// How many of `threads` actually started.
    started: u16 = 0,

    mutex: Io.Mutex = .init,
    /// Workers wait here for a task, or to stop.
    work: Io.Condition = .init,
    /// `wait` waits here for the queue to empty and every running task to finish.
    settled: Io.Condition = .init,

    // Guarded by `mutex`.
    ring: []Entry,
    head: u32 = 0,
    queued: u32 = 0,
    running: u32 = 0,
    stopping: bool = false,

    const Entry = struct { task: Task, done: *Done };

    /// Starts `options.count` threads, or as many as the system will give. A thread that
    /// cannot start is a warning: fewer threads compute the same results more slowly, and none
    /// at all is the immediate executor.
    pub fn init(gpa: Allocator, io: Io, options: Options) Allocator.Error!*Background {
        const wanted = @min(options.count, max_count);
        if (wanted < options.count) {
            log.warn("{d} background threads asked for; starting {d}", .{ options.count, wanted });
        }

        const self = try gpa.create(Background);
        errdefer gpa.destroy(self);
        const threads = try gpa.alloc(std.Thread, wanted);
        errdefer gpa.free(threads);
        const ring = try gpa.alloc(Entry, @max(options.capacity, 1));
        self.* = .{ .gpa = gpa, .io = io, .threads = threads, .ring = ring };

        for (threads) |*thread| {
            thread.* = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
                log.warn("started {d} of {d} background threads ({t}); tasks run on fewer", .{
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

    /// Runs whatever is still queued, then stops and joins every thread.
    pub fn deinit(self: *Background) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        self.work.broadcast(self.io);

        for (self.threads[0..self.started]) |thread| thread.join();
        const gpa = self.gpa;
        gpa.free(self.ring);
        gpa.free(self.threads);
        gpa.destroy(self);
    }

    /// The capability to hand to whatever starts background work. Must not outlive the pool.
    pub fn tasks(self: *Background) Tasks {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Threads that actually started.
    pub fn threadCount(self: *const Background) u16 {
        return self.started;
    }

    const vtable: Tasks.VTable = .{ .start = start, .wait = wait };

    fn start(ptr: *anyopaque, task: Task, done: *Done) core.tasks.StartError!void {
        const self: *Background = @ptrCast(@alignCast(ptr));
        if (self.started == 0) {
            task.call(task.context);
            done.set();
            return;
        }

        self.mutex.lockUncancelable(self.io);
        core.assert.always(!self.stopping, "a task was started on a background pool that is stopping", .{});
        if (self.queued == self.ring.len) {
            self.mutex.unlock(self.io);
            return error.Full;
        }
        const tail = (self.head + self.queued) % @as(u32, @intCast(self.ring.len));
        self.ring[tail] = .{ .task = task, .done = done };
        self.queued += 1;
        self.mutex.unlock(self.io);
        self.work.signal(self.io);
    }

    fn wait(ptr: *anyopaque) void {
        const self: *Background = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.queued != 0 or self.running != 0) self.settled.waitUncancelable(self.io, &self.mutex);
    }

    fn workerMain(self: *Background) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (true) {
            while (!self.stopping and self.queued == 0) self.work.waitUncancelable(self.io, &self.mutex);
            // Stopping, but the queue is drained first: see the module comment.
            if (self.queued == 0) return;

            const entry = self.ring[self.head];
            self.head = (self.head + 1) % @as(u32, @intCast(self.ring.len));
            self.queued -= 1;
            self.running += 1;
            self.mutex.unlock(self.io);

            entry.task.call(entry.task.context);
            entry.done.set();

            self.mutex.lockUncancelable(self.io);
            self.running -= 1;
            if (self.queued == 0 and self.running == 0) self.settled.broadcast(self.io);
        }
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

/// A pool on an `Io` of its own, as `Os.startBackground` makes one on the process's. Must not
/// move once started: the `Io` publishes its own address.
const TestPool = struct {
    threaded: Io.Threaded,
    pool: *Background,

    fn start(self: *TestPool, options: Options) !void {
        self.threaded = .init(testing.allocator, .{});
        errdefer self.threaded.deinit();
        self.pool = try Background.init(testing.allocator, self.threaded.io(), options);
    }

    fn stop(self: *TestPool) void {
        self.pool.deinit();
        self.threaded.deinit();
    }
};

const Count = struct {
    hits: std.atomic.Value(u32) = .init(0),

    fn call(erased: *anyopaque) void {
        const self: *Count = @ptrCast(@alignCast(erased));
        _ = self.hits.fetchAdd(1, .monotonic);
    }
};

test "every task runs exactly once across real threads, start after start" {
    for ([_]u16{ 1, 2, 4 }) |threads| {
        var pool: TestPool = undefined;
        try pool.start(.{ .count = threads, .capacity = 64 });
        defer pool.stop();
        try testing.expectEqual(threads, pool.pool.threadCount());

        var counts: [64]Count = @splat(.{});
        for (0..50) |_| {
            var done: [64]Done = @splat(.{});
            for (&counts, &done) |*c, *d| try pool.pool.tasks().start(.{ .context = c, .call = Count.call }, d);
            pool.pool.tasks().wait();
            for (done) |d| try testing.expect(d.isSet());
        }
        for (counts) |c| try testing.expectEqual(@as(u32, 50), c.hits.load(.monotonic));
    }
}

test "a full queue refuses, and accepts again once a task is taken" {
    var pool: TestPool = undefined;
    try pool.start(.{ .count = 1, .capacity = 2 });
    defer pool.stop();

    // A task that holds the only thread until released, so the queue fills behind it.
    const Gate = struct {
        entered: std.atomic.Value(bool) = .init(false),
        open: std.atomic.Value(bool) = .init(false),
        fn call(erased: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            self.entered.store(true, .release);
            while (!self.open.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    var gate: Gate = .{};
    // Opened on any exit, so a failing expectation below fails rather than hangs the join.
    defer gate.open.store(true, .release);
    var gate_done: Done = .{};
    const t = pool.pool.tasks();
    try t.start(.{ .context = &gate, .call = Gate.call }, &gate_done);
    while (!gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    var counts: [3]Count = @splat(.{});
    var done: [3]Done = @splat(.{});
    try t.start(.{ .context = &counts[0], .call = Count.call }, &done[0]);
    try t.start(.{ .context = &counts[1], .call = Count.call }, &done[1]);
    try testing.expectError(error.Full, t.start(.{ .context = &counts[2], .call = Count.call }, &done[2]));
    try testing.expect(!done[2].isSet());

    gate.open.store(true, .release);
    t.wait();
    try t.start(.{ .context = &counts[2], .call = Count.call }, &done[2]);
    t.wait();
    for (done) |d| try testing.expect(d.isSet());
    try testing.expect(gate_done.isSet());
}

test "wait returns only after a task already taken from the queue has finished" {
    var pool: TestPool = undefined;
    try pool.start(.{ .count = 1 });
    defer pool.stop();

    const Slow = struct {
        entered: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),
        fn call(erased: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            self.entered.store(true, .release);
            // Long enough that a `wait` which did not wait would return first.
            var spins: u64 = 0;
            while (spins < 20_000_000) : (spins += 1) std.atomic.spinLoopHint();
            self.finished.store(true, .release);
        }
    };
    for (0..3) |_| {
        var slow: Slow = .{};
        var done: Done = .{};
        try pool.pool.tasks().start(.{ .context = &slow, .call = Slow.call }, &done);
        // The queue is empty once the task is taken; only the running count is left to wait on.
        while (!slow.entered.load(.acquire)) std.atomic.spinLoopHint();
        pool.pool.tasks().wait();
        try testing.expect(slow.finished.load(.acquire));
        try testing.expect(done.isSet());
    }
}

test "zero threads runs each task on the caller, inside start" {
    var pool: TestPool = undefined;
    try pool.start(.{ .count = 0 });
    defer pool.stop();
    try testing.expectEqual(@as(u16, 0), pool.pool.threadCount());

    const Here = struct {
        thread: std.Thread.Id = 0,
        fn call(erased: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            self.thread = std.Thread.getCurrentId();
        }
    };
    var here: Here = .{};
    var done: Done = .{};
    try pool.pool.tasks().start(.{ .context = &here, .call = Here.call }, &done);
    try testing.expect(done.isSet());
    try testing.expectEqual(std.Thread.getCurrentId(), here.thread);
}

test "a task graph on the pool computes what it computes under immediate" {
    const Square = struct {
        in: u64,
        out: u64 = 0,
        fn call(erased: *anyopaque, _: *core.tasks.Budget) core.tasks.Outcome {
            const self: *@This() = @ptrCast(@alignCast(erased));
            var x = self.in;
            for (0..1000) |_| x = x *% 6364136223846793005 +% 1442695040888963407;
            self.out = x;
            return .ok;
        }
    };
    const Sum = struct {
        parts: []const Square,
        total: u64 = 0,
        fn call(erased: *anyopaque, _: *core.tasks.Budget) core.tasks.Outcome {
            const self: *@This() = @ptrCast(@alignCast(erased));
            for (self.parts) |p| self.total +%= p.out;
            return .ok;
        }
    };

    const run = struct {
        fn total(tasks: Tasks) !u64 {
            var squares: [32]Square = undefined;
            for (&squares, 0..) |*s, i| s.* = .{ .in = i };
            var sum: Sum = .{ .parts = &squares };
            var graph = try core.tasks.Graph.init(testing.allocator, tasks, .{ .nodes = 33, .edges = 32 });
            defer graph.deinit();
            var after: [32]u32 = undefined;
            for (&squares, 0..) |*s, i| after[i] = try graph.add(.{ .kind = .background, .context = s, .call = Square.call });
            _ = try graph.add(.{ .kind = .main, .context = &sum, .call = Sum.call, .after = &after });
            var budget: core.tasks.Budget = .unlimited;
            while (graph.poll(&budget) == .pending) budget = .unlimited;
            try testing.expectEqual(core.tasks.Status.done, graph.status());
            return sum.total;
        }
    };

    const reference = try run.total(core.tasks.immediate);
    var pool: TestPool = undefined;
    try pool.start(.{ .count = 2, .capacity = 8 });
    defer pool.stop();
    for (0..20) |_| try testing.expectEqual(reference, try run.total(pool.pool.tasks()));
}

test "stopping runs what is queued, and a pool may start and stop with nothing to do" {
    for (0..20) |round| {
        var pool: TestPool = undefined;
        try pool.start(.{ .count = @intCast(1 + round % 3), .capacity = 32 });
        var counts: [32]Count = @splat(.{});
        var done: [32]Done = @splat(.{});
        const queue = round % 2 == 1;
        if (queue) for (&counts, &done) |*c, *d| try pool.pool.tasks().start(.{ .context = c, .call = Count.call }, d);
        pool.stop();
        if (queue) for (done) |d| try testing.expect(d.isSet());
    }
    try testing.expect(defaultCount() >= 1 and defaultCount() <= 2);
}
