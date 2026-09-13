//! When a backend may release what a destroyed handle named.
//!
//! Backend-neutral bookkeeping that every backend runs the same way, so that the validation
//! backend's answer and a real backend's cannot drift apart (ADR-0035). Nothing here waits and
//! nothing reads a clock: a backend waits in its own way and then reports what the wait covered.
//!
//! Two numberings, because one queue has two orders:
//!
//! * A **recording** is numbered when it begins. Recordings can be open together and reach
//!   the queue in any order.
//! * A **submission** is numbered when it reaches the queue. The queue executes in that
//!   order, so knowing submission S has finished means every submission up to S has.
//!
//! Retirement is decided by recordings. A resource destroyed after recording R began may be
//! used by R, and by nothing begun later — a command recorded through a dead handle is a rule
//! 9 violation, not a use. Completion is decided by submissions. `resolvedThrough` joins the
//! two.
//!
//! Design: `docs/design/hardening.md` §5.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const assert = core.assert;

/// The completion order of one queue. `Token` is what the backend waits on: a command buffer
/// on Metal, nothing at all on the null backend.
pub fn Timeline(comptime Token: type) type {
    return struct {
        const Self = @This();

        pub const Submission = struct {
            serial: u64,
            /// The recording it came from, or 0 for a backend's own marker, which uses nothing
            /// a caller could have destroyed.
            recording: u64,
            token: Token,
        };

        /// Recordings begun, which is also the newest recording's number.
        begun: u64 = 0,
        /// Submissions made, which is also the newest submission's number.
        submitted: u64 = 0,
        /// Every submission up to this one is known to have finished.
        completed: u64 = 0,
        /// Recordings begun and neither submitted nor discarded.
        open: std.ArrayList(u64) = .empty,
        /// Submissions the backend has not yet released, oldest first. Those above
        /// `completed` may still be executing.
        pending: std.ArrayList(Submission) = .empty,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.open.deinit(gpa);
            self.pending.deinit(gpa);
            self.* = .{};
        }

        /// Opens a recording and returns its number. Reserves what its submission will need,
        /// so that `submit` cannot fail once the queue has the work.
        pub fn begin(self: *Self, gpa: Allocator) Allocator.Error!u64 {
            try self.open.ensureUnusedCapacity(gpa, 1);
            // Room for every open recording, this one included, to submit.
            try self.pending.ensureTotalCapacity(gpa, self.pending.items.len + self.open.items.len + 1);
            self.begun += 1;
            self.open.appendAssumeCapacity(self.begun);
            return self.begun;
        }

        /// Records that a recording reached the queue, and returns its submission number.
        pub fn submit(self: *Self, recording: u64, token: Token) u64 {
            self.close(recording);
            self.submitted += 1;
            self.pending.appendAssumeCapacity(.{ .serial = self.submitted, .recording = recording, .token = token });
            return self.submitted;
        }

        /// Abandons a recording that will never reach the queue. Whatever it could have used
        /// stops waiting on it.
        pub fn discard(self: *Self, recording: u64) void {
            self.close(recording);
        }

        /// Makes room for a marker the backend is about to submit on its own behalf.
        pub fn reserveMarker(self: *Self, gpa: Allocator) Allocator.Error!void {
            try self.pending.ensureTotalCapacity(gpa, self.pending.items.len + self.open.items.len + 1);
        }

        /// Cannot fail: `reserveMarker` made the room.
        pub fn submitMarker(self: *Self, token: Token) u64 {
            self.submitted += 1;
            self.pending.appendAssumeCapacity(.{ .serial = self.submitted, .recording = 0, .token = token });
            return self.submitted;
        }

        /// What to wait on so that everything up to `serial` has finished: the newest
        /// unfinished submission at or before it. Null when nothing up to `serial` is
        /// unfinished, which includes a `serial` of 0.
        pub fn waitTarget(self: *const Self, serial: u64) ?Token {
            var target: ?Token = null;
            for (self.pending.items) |s| {
                if (s.serial > serial) break;
                if (s.serial > self.completed) target = s.token;
            }
            return target;
        }

        /// Records that everything up to `serial` has finished. Only a backend that has
        /// waited for it may say so, and it can never run past what was actually submitted.
        pub fn complete(self: *Self, serial: u64) void {
            self.completed = @max(self.completed, @min(serial, self.submitted));
        }

        /// The oldest finished submission the backend has not released yet, removed.
        pub fn popCompleted(self: *Self) ?Submission {
            if (self.pending.items.len == 0) return null;
            if (self.pending.items[0].serial > self.completed) return null;
            return self.pending.orderedRemove(0);
        }

        /// Every recording numbered at or below this has finished executing or was discarded.
        pub fn resolvedThrough(self: *const Self) u64 {
            var oldest = self.begun + 1;
            for (self.open.items) |recording| oldest = @min(oldest, recording);
            for (self.pending.items) |s| {
                if (s.serial > self.completed and s.recording != 0) oldest = @min(oldest, s.recording);
            }
            return oldest - 1;
        }

        fn close(self: *Self, recording: u64) void {
            const index = std.mem.indexOfScalar(u64, self.open.items, recording);
            assert.always(index != null, "recording {d} is not open", .{recording});
            _ = self.open.swapRemove(index.?);
        }
    };
}

/// Backings whose handles are dead and whose release waits on recordings.
pub fn Retirement(comptime Backing: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            backing: Backing,
            /// The newest recording that could use it: the last one begun before the destroy.
            after: u64,
        };

        entries: std.ArrayList(Entry) = .empty,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.entries.deinit(gpa);
            self.* = .{};
        }

        /// Makes room for `live` resources on top of everything already retired, so that
        /// retiring any of them allocates nothing. Called before a resource is published,
        /// with the number that will then be live.
        pub fn reserve(self: *Self, gpa: Allocator, live: usize) Allocator.Error!void {
            try self.entries.ensureTotalCapacity(gpa, self.entries.items.len + live);
        }

        /// Cannot fail, allocate or release anything: `reserve` made the room.
        pub fn retire(self: *Self, backing: Backing, after: u64) void {
            self.entries.appendAssumeCapacity(.{ .backing = backing, .after = after });
        }

        /// Removes and returns one backing no unfinished recording could use, given that every
        /// recording up to `resolved_through` has finished. Null when there is none.
        pub fn next(self: *Self, resolved_through: u64) ?Backing {
            for (self.entries.items, 0..) |entry, i| {
                if (entry.after <= resolved_through) return self.entries.swapRemove(i).backing;
            }
            return null;
        }

        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }
    };
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

/// Tokens are small numbers, so a test can see which submission a wait would block on.
const Queue = Timeline(u8);

test "a submission finishes only when a wait covers it" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    const recording = try q.begin(testing.allocator);
    const serial = q.submit(recording, 7);
    // Submitted is not finished: nothing has waited.
    try testing.expectEqual(@as(u64, 0), q.resolvedThrough());
    try testing.expectEqual(@as(?u8, 7), q.waitTarget(serial));
    try testing.expect(q.popCompleted() == null);

    q.complete(serial);
    try testing.expectEqual(recording, q.resolvedThrough());
    try testing.expectEqual(@as(?u8, null), q.waitTarget(serial));
    try testing.expectEqual(@as(u8, 7), q.popCompleted().?.token);
    try testing.expect(q.popCompleted() == null);
}

test "recordings finish in the order they began, whatever order they submit in" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    const first = try q.begin(testing.allocator);
    const second = try q.begin(testing.allocator);
    q.complete(q.submit(second, 2));
    // The second has finished, but the first is still open and may use anything destroyed
    // since it began.
    try testing.expectEqual(@as(u64, 0), q.resolvedThrough());

    const serial = q.submit(first, 1);
    try testing.expectEqual(@as(u64, 0), q.resolvedThrough());
    q.complete(serial);
    try testing.expectEqual(second, q.resolvedThrough());
}

test "waiting finishes nothing that was never submitted, and a discard holds nothing" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    const recording = try q.begin(testing.allocator);
    q.complete(q.submitted);
    try testing.expectEqual(@as(u64, 0), q.completed);
    try testing.expectEqual(@as(u64, 0), q.resolvedThrough());

    q.discard(recording);
    try testing.expectEqual(recording, q.resolvedThrough());
}

test "completion never runs past what was submitted" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    q.complete(99);
    try testing.expectEqual(@as(u64, 0), q.completed);

    _ = q.submit(try q.begin(testing.allocator), 0);
    q.complete(99);
    try testing.expectEqual(@as(u64, 1), q.completed);
}

test "the wait target is the newest unfinished submission at or before the serial" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    for (1..4) |token| _ = q.submit(try q.begin(testing.allocator), @intCast(token));
    try q.reserveMarker(testing.allocator);
    const marker = q.submitMarker(9);

    try testing.expectEqual(@as(?u8, 2), q.waitTarget(2));
    try testing.expectEqual(@as(?u8, 9), q.waitTarget(marker));
    q.complete(2);
    try testing.expectEqual(@as(?u8, null), q.waitTarget(2));
    try testing.expectEqual(@as(?u8, 9), q.waitTarget(marker));

    // A marker uses nothing, so an unfinished one holds no recording back.
    q.complete(3);
    try testing.expectEqual(@as(u64, 3), q.resolvedThrough());
}

test "a retired backing waits for every recording begun before it was retired" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);
    var retired: Retirement(u8) = .{};
    defer retired.deinit(testing.allocator);
    try retired.reserve(testing.allocator, 1);

    const before = try q.begin(testing.allocator);
    retired.retire(1, q.begun);
    _ = try q.begin(testing.allocator);

    try testing.expectEqual(@as(?u8, null), retired.next(q.resolvedThrough()));
    const serial = q.submit(before, 0);
    try testing.expectEqual(@as(?u8, null), retired.next(q.resolvedThrough()));

    // Finished. The recording begun after the retirement is still open, and holds nothing.
    q.complete(serial);
    try testing.expectEqual(@as(?u8, 1), retired.next(q.resolvedThrough()));
    try testing.expectEqual(@as(usize, 0), retired.count());
}

test "submitting and retiring need no allocation once begin and reserve have succeeded" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();

    var q: Queue = .{};
    defer q.deinit(gpa);
    var retired: Retirement(u8) = .{};
    defer retired.deinit(gpa);

    const recording = try q.begin(gpa);
    try retired.reserve(gpa, 1);

    // Every allocation from here on fails. A safe build also checks each append's capacity,
    // so a reservation that fell short fails this test rather than passing by luck.
    failing.fail_index = failing.alloc_index;
    q.complete(q.submit(recording, 3));
    retired.retire(5, q.begun);
    try testing.expectEqual(@as(?u8, 5), retired.next(q.resolvedThrough()));
    try testing.expectEqual(@as(u8, 3), q.popCompleted().?.token);
}
