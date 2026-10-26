//! A streamed voice's frames: a ring one decode task fills and the mix callback reads.
//!
//! **One producer and one consumer, as `ring.zig`'s are**, though the producer moves. A stream
//! never has two decode tasks in flight (`music.md` §6.2), and the game thread starts the next
//! only after the last one's `Done`, whose release and acquire hand the producer's side from
//! one pool thread to the next. The consumer is always the callback.
//!
//! Positions are **absolute frames of the stream**, counted across every pass of a loop, never
//! ring indices. Frame `f` lives at ring index `f % capacity`. That is what lets an underrun
//! keep the timeline (§6.3): the voice moves on without frames, and the ones it skipped are
//! written later and never read.
//!
//! The ordering argument is `ring.zig`'s, once per counter:
//! - the producer writes frames, then stores `written` with release; the consumer loads it with
//!   acquire before reading them;
//! - the consumer stores `consumed` with release once it has finished with a frame; the
//!   producer loads it with acquire before overwriting the ring index the frame occupied.

const std = @import("std");

pub const Feed = struct {
    /// The ring's storage, allocated at the mixer's `init` at the most any stream needs and
    /// never resized. A stream uses `capacity * channels` of it.
    storage: []f32,
    /// Frames the ring holds: one second at the sound's own rate. Set when the stream is
    /// claimed, before its voice can see it.
    capacity: u64 = 0,
    channels: u8 = 1,

    /// Frames the producer has written: frames below it are readable, if the consumer has
    /// not passed them. Producer only.
    written: std.atomic.Value(u64) = .init(0),
    /// The lowest frame the consumer may still read. Frames below it may be overwritten.
    /// Consumer only.
    consumed: std.atomic.Value(u64) = .init(0),

    /// Ready for a new stream. Game thread, while neither side is using the feed.
    pub fn reset(self: *Feed, capacity: u64, channels: u8) void {
        std.debug.assert(capacity * channels <= self.storage.len);
        self.capacity = capacity;
        self.channels = channels;
        self.written.store(0, .monotonic);
        self.consumed.store(0, .monotonic);
    }

    /// Frames written and not yet passed by the consumer. Either thread; approximate while
    /// the other side runs, which is all a fill level needs.
    pub fn level(self: *const Feed) u64 {
        return self.written.load(.acquire) -| self.consumed.load(.monotonic);
    }

    /// One sample of absolute frame `frame`. Consumer only, for a frame below `written` and
    /// not below `consumed`.
    pub fn sample(self: *const Feed, frame: u64, channel: u8) f32 {
        const index: usize = @intCast(frame % self.capacity);
        return self.storage[index * self.channels + channel];
    }

    /// Where the producer writes next: up to the end of the ring or of the room the consumer
    /// leaves, whichever is nearer, as one contiguous piece. Empty when the ring is full.
    pub fn room(self: *const Feed, produced: u64) []f32 {
        const limit = self.consumed.load(.acquire) + self.capacity;
        if (produced >= limit) return &.{};
        const at = produced % self.capacity;
        const frames = @min(limit - produced, self.capacity - at);
        return self.storage[@intCast(at * self.channels)..][0..@intCast(frames * self.channels)];
    }

    /// Publishes frames up to `produced`. Producer only, after writing them.
    pub fn publish(self: *Feed, produced: u64) void {
        self.written.store(produced, .release);
    }

    /// The consumer has finished with every frame below `frame`. Consumer only.
    pub fn release(self: *Feed, frame: u64) void {
        self.consumed.store(frame, .release);
    }
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "the producer's room stops where the consumer would be overwritten" {
    var storage: [16]f32 = undefined;
    var feed: Feed = .{ .storage = &storage };
    feed.reset(8, 2);

    // Empty: the whole ring, in one piece.
    try testing.expectEqual(@as(usize, 16), feed.room(0).len);
    for (feed.room(0), 0..) |*s, i| s.* = @floatFromInt(i);
    feed.publish(8);
    try testing.expectEqual(@as(usize, 0), feed.room(8).len);
    try testing.expectEqual(@as(u64, 8), feed.level());

    // The consumer finishes with three frames: three frames of room, wrapping to index 0.
    feed.release(3);
    try testing.expectEqual(@as(usize, 6), feed.room(8).len);
    try testing.expectEqual(@as(f32, 6), feed.sample(3, 0));
    try testing.expectEqual(@as(f32, 15), feed.sample(7, 1));

    // Past the end of the ring, a piece stops at the end and the next starts at index 0.
    feed.release(8);
    feed.publish(10);
    try testing.expectEqual(@as(usize, 12), feed.room(10).len);
    try testing.expectEqual(@as(usize, 4), feed.room(14).len);

    // A consumer that ran ahead of the producer (an underrun) leaves a whole ring of room
    // past itself, and no level.
    feed.release(40);
    try testing.expectEqual(@as(u64, 0), feed.level());
    try testing.expectEqual(@as(usize, 12), feed.room(10).len);
}
