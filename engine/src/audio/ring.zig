//! A single-producer, single-consumer queue. The whole of Foundry's concurrency design.
//!
//! Two of these carry everything between the game thread and the device thread: commands
//! one way, retirements the other. Each has exactly one writer and exactly one reader, and
//! that is what makes a lock unnecessary rather than merely undesirable — the callback may
//! not take one (`docs/design/audio.md` §3), so "unnecessary" is the only acceptable answer.
//!
//! **The one memory-ordering argument in Foundry**, written down because it is invisible
//! and a future session will otherwise simplify it away:
//!
//! * `push` writes the slot, then stores the tail with **release**.
//! * `pop` loads the tail with **acquire**, then reads the slot.
//!
//! The release/acquire pair is what makes the slot's contents visible to the reader. For
//! the retirement ring it does more than that: it is what makes the callback thread's last
//! read of a sound's samples happen-before the game thread's free of them (§7). Nothing
//! else in this module needs anything beyond it, and if a second ordering argument ever
//! appears, that is a sign the thread split has been broken.
//!
//! **A full ring drops and counts.** It cannot block — the producer may be the callback
//! thread. It cannot grow — that would be an allocation. And it cannot report to a caller
//! who is on the other thread. So the drop is counted, the count is readable from either
//! side, and a non-zero value means the ring is too small or the game is issuing commands
//! faster than a callback period. Both are the game's to fix, which is why `Options`
//! exposes the size.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn Ring(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        /// `capacity - 1`. The capacity is a power of two so that the wrapping index
        /// arithmetic below is a mask rather than a modulo — and, more importantly, so
        /// that `tail -% head` stays the true occupancy when the counters wrap.
        mask: usize,

        /// Written only by the consumer, read by both. On its own cache line, because
        /// two threads writing adjacent words is the one performance mistake here that
        /// would show up as an audio glitch rather than as a slower frame.
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
        /// Written only by the producer, read by both.
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),

        /// Pushes refused because the ring was full. Monotonic: it is a diagnostic, and
        /// no decision is made from it on either thread.
        dropped: std.atomic.Value(u32) = .init(0),

        /// Rounds `wanted` up to a power of two, with a floor of two.
        ///
        /// Rounding rather than refusing: a game asking for 300 commands wants "at least
        /// 300", and a build that failed over it would be enforcing an implementation
        /// detail of the index arithmetic.
        pub fn init(gpa: Allocator, wanted: usize) Allocator.Error!Self {
            const rounded = std.math.ceilPowerOfTwoAssert(usize, @max(2, wanted));
            return .{ .items = try gpa.alloc(T, rounded), .mask = rounded - 1 };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.items);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.items.len;
        }

        /// **Producer only.** Returns false if the ring was full, having counted the drop.
        pub fn push(self: *Self, value: T) bool {
            // The producer owns `tail`, so it needs no ordering to read its own value.
            const tail = self.tail.load(.monotonic);
            // But it must see how far the consumer has got, or it would refuse a push
            // into a slot that was freed a moment ago.
            const head = self.head.load(.acquire);

            if (tail -% head >= self.items.len) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return false;
            }

            self.items[tail & self.mask] = value;
            // Release: everything written above, including the slot, is visible to a
            // consumer that acquires this tail. Publishing must be the last thing.
            self.tail.store(tail +% 1, .release);
            return true;
        }

        /// **Consumer only.** Returns null when the ring is empty.
        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) return null;

            const value = self.items[head & self.mask];
            // Release: the slot is not free for the producer to overwrite until this
            // store, and this store says the read above already happened.
            self.head.store(head +% 1, .release);
            return value;
        }

        /// How many pushes have been refused. Readable from either thread.
        pub fn dropCount(self: *const Self) u32 {
            return self.dropped.load(.monotonic);
        }

        /// Approximate, and honestly so: on a live ring the other thread may move between
        /// the two loads. For a diagnostic, and for tests where only one thread is running.
        pub fn len(self: *const Self) usize {
            return self.tail.load(.acquire) -% self.head.load(.acquire);
        }
    };
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

const Ints = Ring(u32);

test "a ring rounds its capacity up to a power of two, with a floor" {
    const gpa = testing.allocator;
    for ([_]struct { asked: usize, got: usize }{
        .{ .asked = 0, .got = 2 },
        .{ .asked = 1, .got = 2 },
        .{ .asked = 2, .got = 2 },
        .{ .asked = 3, .got = 4 },
        .{ .asked = 300, .got = 512 },
        .{ .asked = 1024, .got = 1024 },
    }) |case| {
        var ring: Ints = try .init(gpa, case.asked);
        defer ring.deinit(gpa);
        try testing.expectEqual(case.got, ring.capacity());
    }
}

test "what goes in comes out, in order" {
    const gpa = testing.allocator;
    var ring: Ints = try .init(gpa, 8);
    defer ring.deinit(gpa);

    try testing.expect(ring.pop() == null);
    for (0..8) |i| try testing.expect(ring.push(@intCast(i)));
    try testing.expectEqual(@as(usize, 8), ring.len());

    for (0..8) |i| try testing.expectEqual(@as(?u32, @intCast(i)), ring.pop());
    try testing.expect(ring.pop() == null);
    try testing.expectEqual(@as(u32, 0), ring.dropCount());
}

test "a full ring drops and counts, and keeps working afterwards" {
    const gpa = testing.allocator;
    var ring: Ints = try .init(gpa, 4);
    defer ring.deinit(gpa);

    for (0..4) |i| try testing.expect(ring.push(@intCast(i)));
    // Full. It cannot block, cannot grow and cannot tell the caller — who is on the
    // other thread — so it counts.
    try testing.expect(!ring.push(99));
    try testing.expect(!ring.push(99));
    try testing.expectEqual(@as(u32, 2), ring.dropCount());

    // The dropped values are gone; the queued ones are not. Losing the *oldest* command
    // instead would be far worse: a `play` overwritten by a `set_gain` for it.
    try testing.expectEqual(@as(?u32, 0), ring.pop());
    try testing.expect(ring.push(100));
    for (1..4) |i| try testing.expectEqual(@as(?u32, @intCast(i)), ring.pop());
    try testing.expectEqual(@as(?u32, 100), ring.pop());
}

test "indices wrap without the ring losing count" {
    const gpa = testing.allocator;
    var ring: Ints = try .init(gpa, 4);
    defer ring.deinit(gpa);

    // Far more traffic than the ring holds, one in and one out, so the physical slots
    // are reused many times over.
    for (0..1000) |i| {
        try testing.expect(ring.push(@intCast(i)));
        try testing.expectEqual(@as(?u32, @intCast(i)), ring.pop());
    }
    try testing.expectEqual(@as(usize, 0), ring.len());
    try testing.expectEqual(@as(u32, 0), ring.dropCount());
}

test "a ring survives its counters wrapping past the end of usize" {
    // Reached by hand rather than by pushing 2^64 times. `tail -% head` is the occupancy
    // only because both counters wrap the same way; a `tail - head` written in a later
    // session would pass every test above and deadlock here.
    const gpa = testing.allocator;
    var ring: Ints = try .init(gpa, 4);
    defer ring.deinit(gpa);

    const near_end = std.math.maxInt(usize) - 1;
    ring.head.store(near_end, .monotonic);
    ring.tail.store(near_end, .monotonic);

    for (0..8) |i| {
        try testing.expect(ring.push(@intCast(i)));
        try testing.expectEqual(@as(?u32, @intCast(i)), ring.pop());
    }
    try testing.expectEqual(@as(u32, 0), ring.dropCount());
    // And the counters really did pass zero.
    try testing.expect(ring.tail.load(.monotonic) < near_end);
}

test "a producer and a consumer on two real threads lose nothing" {
    // The stepped device makes producer and consumer the same thread, which is the one
    // thing it cannot test. This is not proof of the ordering — no test is — but it is
    // the difference between reasoning that was reviewed and reasoning nobody ran.
    const gpa = testing.allocator;
    var ring: Ints = try .init(gpa, 64);
    defer ring.deinit(gpa);

    const total: u32 = 100_000;
    const Producer = struct {
        fn run(r: *Ints, n: u32) void {
            var i: u32 = 0;
            while (i < n) {
                if (r.push(i)) i += 1;
                // Full: spin. A real producer drops instead — this one must not, or the
                // consumer's sequence check would have nothing to check.
            }
        }
    };

    var thread = try std.Thread.spawn(.{}, Producer.run, .{ &ring, total });
    var expected: u32 = 0;
    while (expected < total) {
        if (ring.pop()) |value| {
            // In order, none missing, none duplicated.
            try testing.expectEqual(expected, value);
            expected += 1;
        }
    }
    thread.join();
    try testing.expectEqual(total, expected);
}
