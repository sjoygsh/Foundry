//! Work that outlives a frame: the interface, and the small graph that orders it.
//!
//! **Explicit, the way `Jobs` is** (ADR-0061). Any API that may start background work takes
//! a `Tasks`. There is no global pool, and code handed `immediate` runs every task the moment
//! it is started, on the calling thread — which is what every caller did before M27 and
//! what each still does by default.
//!
//! **Not a kind of `Jobs`.** A fork-join split promises to return having run everything; a
//! background task promises the opposite. A task never calls `forChunks` on the frame's
//! pool, which asserts one dispatcher and whose joins must not wait behind a decode; a task
//! that wants a `Jobs` is handed `jobs.serial`.
//!
//! `core` holds no thread. The executor with threads is `platform.Background`, created by
//! `app` beside the frame's pool.
//!
//! ## The graph
//!
//! A `Graph` is a fixed set of nodes, each run on a background thread or on the thread that
//! polls. A node names only nodes added before it as prerequisites, so a graph cannot have a
//! cycle. **Every piece of bookkeeping happens in `poll`, on one thread**: a worker writes
//! its own node's outcome and its `Done` flag and nothing else, so the graph needs no lock.
//!
//! What a node computes must not depend on when it runs. When it *arrives* may decide what
//! is drawn, never what is simulated (`docs/design/background.md` §5).
//!
//! **`Manual` exists to prove it.** It holds started tasks until a test runs them, in any
//! order and across as many polls as the test likes, on one thread, so a consumer that
//! depends on completion order fails an ordinary test rather than waiting for a race.
//!
//! Design: `docs/design/background.md` §3.

const std = @import("std");
const assert = @import("assert.zig");

const Allocator = std.mem.Allocator;

/// What an executor is handed: something to call once, and what to call it with.
pub const Task = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque) void,
};

/// Set once, by the executor, after its task has returned.
///
/// Release on the setting side and acquire on the reading side: whatever the task wrote
/// before returning is visible to whoever sees the flag set.
pub const Done = struct {
    value: std.atomic.Value(bool) = .init(false),

    pub fn set(self: *Done) void {
        self.value.store(true, .release);
    }

    pub fn isSet(self: *const Done) bool {
        return self.value.load(.acquire);
    }
};

pub const StartError = error{
    /// The executor's queue is full. Nothing was started; the caller tries again later.
    Full,
};

/// The capability to start background work. A pointer and a table, shaped like `Jobs`.
///
/// Like an allocator, it must not outlive whatever it was taken from.
pub const Tasks = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Calls `task.call(task.context)` once, now or later, on some thread, and then sets
        /// `done`. It never blocks the caller for the task's duration — except `immediate`,
        /// whose whole point is to run it then.
        start: *const fn (ptr: *anyopaque, task: Task, done: *Done) StartError!void,
        /// Returns when every task started through this executor has set its flag. For
        /// teardown and quiescing, never on a frame's path.
        wait: *const fn (ptr: *anyopaque) void,
    };

    pub fn start(self: Tasks, task: Task, done: *Done) StartError!void {
        return self.vtable.start(self.ptr, task, done);
    }

    pub fn wait(self: Tasks) void {
        self.vtable.wait(self.ptr);
    }
};

/// Runs each task inside `start`, on the calling thread. The default everywhere a `Tasks` is
/// taken, and the reference every background result is compared against.
///
/// Named `immediate` because `inline` is a Zig keyword (Step 1's Resolution).
pub const immediate: Tasks = .{ .ptr = undefined, .vtable = &immediate_vtable };

const immediate_vtable: Tasks.VTable = .{ .start = startImmediate, .wait = waitNothing };

fn startImmediate(_: *anyopaque, task: Task, done: *Done) StartError!void {
    task.call(task.context);
    done.set();
}

fn waitNothing(_: *anyopaque) void {}

/// Holds started tasks until the test runs them. **For tests.**
///
/// It is a legal executor — the contract allows a task to complete at any time, in any order
/// — and the most adversarial one that needs no threads. Its capacity is fixed at `init`, so
/// a full queue can be tested too.
pub const Manual = struct {
    gpa: Allocator,
    held: std.ArrayList(Held),

    const Held = struct { task: Task, done: *Done };

    pub fn init(gpa: Allocator, capacity: u32) Allocator.Error!Manual {
        return .{ .gpa = gpa, .held = try .initCapacity(gpa, capacity) };
    }

    /// Asserts nothing is still held: a test that leaves a task unrun has not finished.
    pub fn deinit(self: *Manual) void {
        assert.always(self.held.items.len == 0, "{d} manual task(s) were never run", .{self.held.items.len});
        self.held.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn tasks(self: *Manual) Tasks {
        return .{ .ptr = self, .vtable = &manual_vtable };
    }

    pub fn pending(self: *const Manual) u32 {
        return @intCast(self.held.items.len);
    }

    /// Runs the oldest held task.
    pub fn runNext(self: *Manual) void {
        self.runAt(0);
    }

    /// Runs the newest held task.
    pub fn runLast(self: *Manual) void {
        self.runAt(self.pending() - 1);
    }

    /// Runs the `index`-th oldest held task.
    pub fn runAt(self: *Manual, index: u32) void {
        const held = self.held.orderedRemove(index);
        held.task.call(held.task.context);
        held.done.set();
    }

    /// Runs everything held, oldest first.
    pub fn runAll(self: *Manual) void {
        while (self.pending() > 0) self.runNext();
    }

    const manual_vtable: Tasks.VTable = .{ .start = startManual, .wait = waitManual };

    fn startManual(ptr: *anyopaque, task: Task, done: *Done) StartError!void {
        const self: *Manual = @ptrCast(@alignCast(ptr));
        if (self.held.items.len == self.held.capacity) return error.Full;
        self.held.appendAssumeCapacity(.{ .task = task, .done = done });
    }

    /// Waiting on a manual executor runs what it holds: nothing else ever would.
    fn waitManual(ptr: *anyopaque) void {
        const self: *Manual = @ptrCast(@alignCast(ptr));
        self.runAll();
    }
};

// -- the graph ----------------------------------------------------------------------

/// Where a node runs.
pub const Kind = enum {
    /// Through the graph's `Tasks`, on whatever thread the executor chooses.
    background,
    /// Inside `poll`, on the polling thread.
    main,
};

/// What a node reports. Its own detailed reason, if it has one, lives in its context: the
/// graph orders work and does not interpret errors.
pub const Outcome = enum { ok, failed };

/// What a poll may spend. A main node charges it; a background node is handed one it may
/// ignore. `poll` stops running main nodes once it is spent — **but always runs the first
/// ready one under it**, so a single large finish cannot wait forever. "First" is counted by
/// the budget (`ran`), not by the poll, so one budget handed to several graphs' polls —
/// the asset registry's pump — runs one finish past its limit, not one per graph.
pub const Budget = struct {
    bytes: u64 = std.math.maxInt(u64),
    nodes: u32 = std.math.maxInt(u32),
    spent_bytes: u64 = 0,
    ran: u32 = 0,

    pub const unlimited: Budget = .{};

    pub fn charge(self: *Budget, bytes: u64) void {
        self.spent_bytes +|= bytes;
    }

    pub fn exhausted(self: *const Budget) bool {
        return self.spent_bytes >= self.bytes or self.ran >= self.nodes;
    }
};

pub const Node = struct {
    kind: Kind,
    context: *anyopaque,
    call: *const fn (context: *anyopaque, budget: *Budget) Outcome,
    /// Called once, at a poll, for a node that finished `ok` after its graph was cancelled,
    /// or that had finished `ok` when it was. It frees what nobody will use. Optional.
    discard: ?*const fn (context: *anyopaque) void = null,
    /// Indices of nodes added earlier that must finish `ok` first.
    after: []const u32 = &.{},
};

pub const Status = enum {
    /// Something is waiting or running.
    pending,
    /// Every node finished `ok`.
    done,
    /// Nothing is waiting or running, and at least one node failed or was skipped.
    failed,
    /// Cancelled, and nothing is running any more.
    cancelled,
};

pub const AddError = error{
    /// The graph's node or prerequisite capacity is used up.
    Full,
    /// A prerequisite is not a node added before this one.
    InvalidPrerequisite,
    /// The graph was cancelled; nothing more may be added.
    Cancelled,
};

pub const Limits = struct {
    nodes: u32,
    /// Prerequisite entries across every node.
    edges: u32 = 0,
};

pub const Graph = struct {
    gpa: Allocator,
    tasks: Tasks,
    slots: []Slot,
    edges: []u32,
    node_count: u32 = 0,
    edge_count: u32 = 0,
    cancelled: bool = false,

    const State = enum { waiting, running, ok, failed, skipped, cancelled, discarded };

    /// Fixed in memory for the graph's life, because an executor holds a pointer to it while
    /// its node runs.
    const Slot = struct {
        node: Node,
        state: State = .waiting,
        /// Written by whichever thread runs a background node, before `done` is set.
        outcome: Outcome = .ok,
        done: Done = .{},
        first_edge: u32 = 0,
        edge_len: u32 = 0,
    };

    /// Allocates everything the graph will ever need; nothing later does.
    pub fn init(gpa: Allocator, tasks: Tasks, limits: Limits) Allocator.Error!Graph {
        const slots = try gpa.alloc(Slot, limits.nodes);
        errdefer gpa.free(slots);
        const edges = try gpa.alloc(u32, limits.edges);
        return .{ .gpa = gpa, .tasks = tasks, .slots = slots, .edges = edges };
    }

    /// A running node would write into freed memory, so this is a programmer error. Cancel,
    /// then poll until `idle`.
    pub fn deinit(self: *Graph) void {
        assert.always(self.idle(), "a task graph was freed while a node was still running", .{});
        self.gpa.free(self.edges);
        self.gpa.free(self.slots);
        self.* = undefined;
    }

    /// Adds a node and returns its index. Allocates nothing.
    pub fn add(self: *Graph, node: Node) AddError!u32 {
        if (self.cancelled) return error.Cancelled;
        if (self.node_count == self.slots.len) return error.Full;
        if (node.after.len > self.edges.len - self.edge_count) return error.Full;
        for (node.after) |p| if (p >= self.node_count) return error.InvalidPrerequisite;

        const first = self.edge_count;
        @memcpy(self.edges[first..][0..node.after.len], node.after);
        self.edge_count += @intCast(node.after.len);

        const index = self.node_count;
        var stored = node;
        stored.after = &.{};
        self.slots[index] = .{ .node = stored, .first_edge = first, .edge_len = @intCast(node.after.len) };
        self.node_count += 1;
        return index;
    }

    pub fn count(self: *const Graph) u32 {
        return self.node_count;
    }

    /// Advances everything that can advance, in one ascending pass:
    /// - a running background node whose flag is set takes its outcome;
    /// - a waiting node whose prerequisites all finished `ok` starts, if it is background, or
    ///   runs now, if it is main and the budget allows;
    /// - a waiting node with a prerequisite that failed or was skipped is skipped.
    ///
    /// Because prerequisites always come earlier, one pass carries every consequence of the
    /// pass as far as it can go: with `immediate`, a whole graph completes in one poll. A full
    /// executor stops further starts for this poll, and they are tried at the next.
    pub fn poll(self: *Graph, budget: *Budget) Status {
        var starts_refused = false;
        for (self.slots[0..self.node_count]) |*slot| {
            if (slot.state == .running) self.settle(slot);
            if (self.cancelled) {
                self.cancelSlot(slot);
                continue;
            }
            if (slot.state != .waiting) continue;

            switch (self.readiness(slot)) {
                .blocked => continue,
                .doomed => {
                    slot.state = .skipped;
                    continue;
                },
                .ready => {},
            }
            switch (slot.node.kind) {
                .background => {
                    if (starts_refused) continue;
                    self.tasks.start(.{ .context = slot, .call = runSlot }, &slot.done) catch {
                        starts_refused = true;
                        continue;
                    };
                    slot.state = .running;
                    // `immediate` has already run it; take the outcome now so that what
                    // depends on it can run in this same pass.
                    if (slot.done.isSet()) self.settle(slot);
                },
                .main => {
                    if (budget.ran > 0 and budget.exhausted()) continue;
                    slot.outcome = slot.node.call(slot.node.context, budget);
                    slot.state = if (slot.outcome == .ok) .ok else .failed;
                    budget.ran += 1;
                },
            }
        }
        return self.status();
    }

    /// Stops anything new from starting. A running node finishes, and its output is handed
    /// to its `discard` at the next poll; a node that already finished `ok` is discarded at
    /// the next poll too. The graph is freed only once `idle`.
    pub fn cancel(self: *Graph) void {
        self.cancelled = true;
    }

    /// Whether no node is running. The only state in which `deinit` is allowed.
    pub fn idle(self: *const Graph) bool {
        for (self.slots[0..self.node_count]) |slot| {
            if (slot.state == .running and !slot.done.isSet()) return false;
        }
        return true;
    }

    pub fn status(self: *const Graph) Status {
        var all_ok = true;
        for (self.slots[0..self.node_count]) |slot| switch (slot.state) {
            .waiting, .running => return .pending,
            .ok => {},
            .failed, .skipped => all_ok = false,
            .cancelled, .discarded => {},
        };
        if (self.cancelled) return .cancelled;
        return if (all_ok) .done else .failed;
    }

    /// The lowest-indexed node that failed, if any: the graph's failure.
    pub fn firstFailure(self: *const Graph) ?u32 {
        for (self.slots[0..self.node_count], 0..) |slot, i| {
            if (slot.state == .failed) return @intCast(i);
        }
        return null;
    }

    /// Whether node `index` has left waiting: started, run, skipped or cancelled. A caller
    /// that only wants to settle work already begun polls only when this is true, because a
    /// poll also starts what is ready.
    pub fn started(self: *const Graph, index: u32) bool {
        return self.slots[index].state != .waiting;
    }

    /// Whether node `index` has finished `ok`.
    pub fn finished(self: *const Graph, index: u32) bool {
        return self.slots[index].state == .ok;
    }

    const Readiness = enum { ready, blocked, doomed };

    fn readiness(self: *const Graph, slot: *const Slot) Readiness {
        var ready = true;
        for (self.edges[slot.first_edge..][0..slot.edge_len]) |p| switch (self.slots[p].state) {
            .ok => {},
            .failed, .skipped => return .doomed,
            else => ready = false,
        };
        return if (ready) .ready else .blocked;
    }

    fn settle(_: *Graph, slot: *Slot) void {
        if (!slot.done.isSet()) return;
        slot.state = if (slot.outcome == .ok) .ok else .failed;
    }

    fn cancelSlot(_: *Graph, slot: *Slot) void {
        switch (slot.state) {
            .waiting => slot.state = .cancelled,
            .ok => {
                if (slot.node.discard) |discard| discard(slot.node.context);
                slot.state = .discarded;
            },
            .running, .failed, .skipped, .cancelled, .discarded => {},
        }
    }

    /// What an executor calls: the node's own function, then its outcome, before `done`.
    fn runSlot(erased: *anyopaque) void {
        const slot: *Slot = @ptrCast(@alignCast(erased));
        var budget: Budget = .unlimited;
        slot.outcome = slot.node.call(slot.node.context, &budget);
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

/// A node that appends its tag to a shared log when it runs, and can be told to fail. The
/// log is touched only on the polling thread or under `Manual`, so a plain list is safe.
const Probe = struct {
    tag: u8,
    log: *std.ArrayList(u8),
    fail: bool = false,
    charge: u64 = 0,
    discarded: bool = false,

    fn node(self: *Probe, kind: Kind, after: []const u32) Node {
        return .{ .kind = kind, .context = self, .call = call, .discard = discard, .after = after };
    }

    fn call(erased: *anyopaque, budget: *Budget) Outcome {
        const self: *Probe = @ptrCast(@alignCast(erased));
        self.log.appendAssumeCapacity(self.tag);
        budget.charge(self.charge);
        return if (self.fail) .failed else .ok;
    }

    fn discard(erased: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(erased));
        self.discarded = true;
    }
};

fn pollOnce(graph: *Graph) Status {
    var budget: Budget = .unlimited;
    return graph.poll(&budget);
}

test "a graph runs each node once, after its prerequisites, and in one poll under immediate" {
    var log: std.ArrayList(u8) = try .initCapacity(testing.allocator, 16);
    defer log.deinit(testing.allocator);
    var graph = try Graph.init(testing.allocator, immediate, .{ .nodes = 4, .edges = 4 });
    defer graph.deinit();

    var a: Probe = .{ .tag = 'a', .log = &log };
    var b: Probe = .{ .tag = 'b', .log = &log };
    var c: Probe = .{ .tag = 'c', .log = &log };
    var d: Probe = .{ .tag = 'd', .log = &log };
    const ia = try graph.add(a.node(.background, &.{}));
    const ib = try graph.add(b.node(.background, &.{}));
    const ic = try graph.add(c.node(.main, &.{ ia, ib }));
    _ = try graph.add(d.node(.main, &.{ic}));

    try testing.expectEqual(Status.done, pollOnce(&graph));
    try testing.expectEqualStrings("abcd", log.items);
    // Nothing runs twice.
    try testing.expectEqual(Status.done, pollOnce(&graph));
    try testing.expectEqualStrings("abcd", log.items);
}

test "background nodes may complete in any order and across polls; main nodes still run in index order" {
    const orders = [_][]const u8{ "forward", "reverse", "held" };
    for (orders) |order| {
        var log: std.ArrayList(u8) = try .initCapacity(testing.allocator, 16);
        defer log.deinit(testing.allocator);
        var manual = try Manual.init(testing.allocator, 4);
        defer manual.deinit();
        var graph = try Graph.init(testing.allocator, manual.tasks(), .{ .nodes = 5, .edges = 4 });
        defer graph.deinit();

        var x: Probe = .{ .tag = 'x', .log = &log };
        var y: Probe = .{ .tag = 'y', .log = &log };
        var p: Probe = .{ .tag = 'p', .log = &log };
        var q: Probe = .{ .tag = 'q', .log = &log };
        var r: Probe = .{ .tag = 'r', .log = &log };
        const ix = try graph.add(x.node(.background, &.{}));
        const iy = try graph.add(y.node(.background, &.{}));
        // Main nodes that become ready together: the later-indexed waits for the earlier.
        _ = try graph.add(p.node(.main, &.{ix}));
        _ = try graph.add(q.node(.main, &.{iy}));
        _ = try graph.add(r.node(.main, &.{ ix, iy }));

        try testing.expectEqual(Status.pending, pollOnce(&graph));
        try testing.expectEqual(@as(u32, 2), manual.pending());
        try testing.expectEqualStrings("", log.items);

        if (std.mem.eql(u8, order, "forward")) {
            manual.runNext();
            manual.runNext();
            try testing.expectEqualStrings("xy", log.items);
        } else if (std.mem.eql(u8, order, "reverse")) {
            manual.runLast();
            manual.runLast();
            try testing.expectEqualStrings("yx", log.items);
        } else {
            // One finishes, and the graph is polled several times before the other does.
            manual.runLast();
            try testing.expectEqual(Status.pending, pollOnce(&graph));
            try testing.expectEqual(Status.pending, pollOnce(&graph));
            try testing.expectEqualStrings("yq", log.items);
            manual.runNext();
        }
        try testing.expectEqual(Status.done, pollOnce(&graph));
        // Whatever the completion order, main nodes ready at one poll ran in index order.
        const mains = log.items[2..];
        if (std.mem.eql(u8, order, "held")) {
            try testing.expectEqualStrings("pr", log.items[3..]);
        } else {
            try testing.expectEqualStrings("pqr", mains);
        }
    }
}

test "the first failure by index is the graph's, its dependants are skipped, and the rest still runs" {
    var log: std.ArrayList(u8) = try .initCapacity(testing.allocator, 16);
    defer log.deinit(testing.allocator);
    var graph = try Graph.init(testing.allocator, immediate, .{ .nodes = 6, .edges = 5 });
    defer graph.deinit();

    var ok: Probe = .{ .tag = 'o', .log = &log };
    var bad1: Probe = .{ .tag = '1', .log = &log, .fail = true };
    var bad2: Probe = .{ .tag = '2', .log = &log, .fail = true };
    var after_bad: Probe = .{ .tag = 'x', .log = &log };
    var after_skip: Probe = .{ .tag = 'z', .log = &log };
    var independent: Probe = .{ .tag = 'i', .log = &log };
    const io = try graph.add(ok.node(.background, &.{}));
    const ib1 = try graph.add(bad1.node(.background, &.{}));
    _ = try graph.add(bad2.node(.main, &.{io}));
    const ix = try graph.add(after_bad.node(.main, &.{ ib1, io }));
    _ = try graph.add(after_skip.node(.background, &.{ix}));
    _ = try graph.add(independent.node(.main, &.{io}));

    try testing.expectEqual(Status.failed, pollOnce(&graph));
    try testing.expectEqualStrings("o12i", log.items);
    try testing.expectEqual(@as(?u32, ib1), graph.firstFailure());
    try testing.expect(!graph.finished(ix));
}

test "a cancelled graph discards what finished, starts nothing new, and is idle only when nothing runs" {
    var log: std.ArrayList(u8) = try .initCapacity(testing.allocator, 16);
    defer log.deinit(testing.allocator);
    var manual = try Manual.init(testing.allocator, 4);
    defer manual.deinit();
    var graph = try Graph.init(testing.allocator, manual.tasks(), .{ .nodes = 4, .edges = 2 });
    defer graph.deinit();

    var early: Probe = .{ .tag = 'e', .log = &log };
    var late: Probe = .{ .tag = 'l', .log = &log };
    var next: Probe = .{ .tag = 'n', .log = &log };
    var never: Probe = .{ .tag = 'v', .log = &log };
    const ie = try graph.add(early.node(.background, &.{}));
    const il = try graph.add(late.node(.background, &.{}));
    _ = try graph.add(next.node(.main, &.{ie}));
    _ = try graph.add(never.node(.background, &.{il}));

    try testing.expectEqual(Status.pending, pollOnce(&graph));
    manual.runNext(); // `early` finishes before the cancel...
    try testing.expectEqual(Status.pending, pollOnce(&graph)); // ...and `next` runs on it.
    try testing.expectEqualStrings("en", log.items);

    graph.cancel();
    try testing.expectError(error.Cancelled, graph.add(never.node(.main, &.{})));
    try testing.expect(!graph.idle()); // `late` is still held, so still running.
    try testing.expectEqual(Status.pending, pollOnce(&graph));
    try testing.expect(early.discarded and next.discarded);
    try testing.expect(!late.discarded);

    manual.runNext(); // `late` finishes after the cancel.
    try testing.expect(graph.idle());
    try testing.expectEqual(Status.cancelled, pollOnce(&graph));
    try testing.expect(late.discarded);
    try testing.expect(!never.discarded);
    try testing.expectEqualStrings("enl", log.items); // `never` never ran.
}

test "a budget defers main nodes to the next poll, but never the first of a poll" {
    var log: std.ArrayList(u8) = try .initCapacity(testing.allocator, 16);
    defer log.deinit(testing.allocator);
    var graph = try Graph.init(testing.allocator, immediate, .{ .nodes = 3 });
    defer graph.deinit();

    var big: Probe = .{ .tag = 'b', .log = &log, .charge = 100 };
    var small: Probe = .{ .tag = 's', .log = &log, .charge = 1 };
    var last: Probe = .{ .tag = 'l', .log = &log, .charge = 1 };
    _ = try graph.add(big.node(.main, &.{}));
    _ = try graph.add(small.node(.main, &.{}));
    _ = try graph.add(last.node(.main, &.{}));

    // The first is larger than the whole budget and still runs; the rest wait.
    var budget: Budget = .{ .bytes = 10 };
    try testing.expectEqual(Status.pending, graph.poll(&budget));
    try testing.expectEqualStrings("b", log.items);

    // A budget spent before the poll begins still runs the poll's first ready node.
    budget = .{ .bytes = 0, .nodes = 1 };
    try testing.expectEqual(Status.pending, graph.poll(&budget));
    try testing.expectEqualStrings("bs", log.items);

    budget = .unlimited;
    try testing.expectEqual(Status.done, graph.poll(&budget));
    try testing.expectEqualStrings("bsl", log.items);
}

test "a full executor defers starts to the next poll" {
    var log: std.ArrayList(u8) = try .initCapacity(testing.allocator, 16);
    defer log.deinit(testing.allocator);
    var manual = try Manual.init(testing.allocator, 1);
    defer manual.deinit();
    var graph = try Graph.init(testing.allocator, manual.tasks(), .{ .nodes = 2 });
    defer graph.deinit();

    var a: Probe = .{ .tag = 'a', .log = &log };
    var b: Probe = .{ .tag = 'b', .log = &log };
    _ = try graph.add(a.node(.background, &.{}));
    _ = try graph.add(b.node(.background, &.{}));

    try testing.expectEqual(Status.pending, pollOnce(&graph));
    try testing.expectEqual(@as(u32, 1), manual.pending());
    manual.runNext();
    try testing.expectEqual(Status.pending, pollOnce(&graph)); // `a` settles, `b` starts.
    try testing.expectEqual(@as(u32, 1), manual.pending());
    manual.runNext();
    try testing.expectEqual(Status.done, pollOnce(&graph));
    try testing.expectEqualStrings("ab", log.items);
}

test "adding past capacity, or naming a later node, is refused" {
    var log: std.ArrayList(u8) = try .initCapacity(testing.allocator, 4);
    defer log.deinit(testing.allocator);
    var graph = try Graph.init(testing.allocator, immediate, .{ .nodes = 2, .edges = 1 });
    defer graph.deinit();
    var p: Probe = .{ .tag = 'p', .log = &log };

    try testing.expectError(error.InvalidPrerequisite, graph.add(p.node(.main, &.{0})));
    const first = try graph.add(p.node(.main, &.{}));
    try testing.expectError(error.InvalidPrerequisite, graph.add(p.node(.main, &.{1})));
    try testing.expectError(error.Full, graph.add(p.node(.main, &.{ first, first })));
    _ = try graph.add(p.node(.main, &.{first}));
    try testing.expectError(error.Full, graph.add(p.node(.main, &.{})));
    try testing.expectEqual(@as(u32, 2), graph.count());
}

test "an empty graph is done at once" {
    var graph = try Graph.init(testing.allocator, immediate, .{ .nodes = 0 });
    defer graph.deinit();
    try testing.expectEqual(Status.done, pollOnce(&graph));
    try testing.expect(graph.idle());
}

test "manual tasks run in whatever order the test chooses, and refuse past capacity" {
    var manual = try Manual.init(testing.allocator, 3);
    defer manual.deinit();
    var log: std.ArrayList(u8) = try .initCapacity(testing.allocator, 4);
    defer log.deinit(testing.allocator);

    const Append = struct {
        tag: u8,
        log: *std.ArrayList(u8),
        fn call(erased: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            self.log.appendAssumeCapacity(self.tag);
        }
    };
    var a: Append = .{ .tag = 'a', .log = &log };
    var b: Append = .{ .tag = 'b', .log = &log };
    var c: Append = .{ .tag = 'c', .log = &log };
    var done: [4]Done = .{ .{}, .{}, .{}, .{} };
    const t = manual.tasks();
    try t.start(.{ .context = &a, .call = Append.call }, &done[0]);
    try t.start(.{ .context = &b, .call = Append.call }, &done[1]);
    try t.start(.{ .context = &c, .call = Append.call }, &done[2]);
    try testing.expectError(error.Full, t.start(.{ .context = &c, .call = Append.call }, &done[3]));

    manual.runAt(1);
    try testing.expect(done[1].isSet() and !done[0].isSet());
    manual.runLast();
    t.wait();
    try testing.expectEqualStrings("bca", log.items);
    try testing.expect(done[0].isSet() and done[2].isSet() and !done[3].isSet());
}

test "one budget handed to several graphs runs one main node past its limit, not one per graph" {
    var log: std.ArrayList(u8) = try .initCapacity(testing.allocator, 8);
    defer log.deinit(testing.allocator);
    var probes: [3]Probe = .{
        .{ .tag = 'a', .log = &log, .charge = 10 },
        .{ .tag = 'b', .log = &log, .charge = 10 },
        .{ .tag = 'c', .log = &log, .charge = 10 },
    };
    var graphs: [3]Graph = undefined;
    for (&graphs, &probes) |*g, *p| {
        g.* = try Graph.init(testing.allocator, immediate, .{ .nodes = 1 });
        _ = try g.add(p.node(.main, &.{}));
    }
    defer for (&graphs) |*g| g.deinit();

    // A one-byte budget: the first graph's node runs regardless, and nothing after it.
    var budget: Budget = .{ .bytes = 1 };
    for (&graphs) |*g| _ = g.poll(&budget);
    try testing.expectEqualStrings("a", log.items);
    try testing.expect(!graphs[1].started(0));
    // A fresh budget is a fresh "first".
    budget = .{ .bytes = 1 };
    for (graphs[1..]) |*g| _ = g.poll(&budget);
    try testing.expectEqualStrings("ab", log.items);
    try testing.expect(graphs[0].started(0) and graphs[1].started(0) and !graphs[2].started(0));
    budget = .unlimited;
    _ = graphs[2].poll(&budget);
}
