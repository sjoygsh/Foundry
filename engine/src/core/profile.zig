//! Frame timing: spans, a ring of frames, and the arithmetic over them.
//!
//! **This file holds no clock, and that is the design rather than an inconvenience.**
//! `core/time.zig` owns time's types and `platform` owns reading one, which is what makes
//! I9's "no wall-clock reads inside simulation" structural: an `Instant` can only be
//! *produced* by `platform`, and `scene` and `physics2d` do not depend on it. A profiler
//! is a wall clock with extra steps, so a recorder that carried a clock and was handed
//! down to subsystems would be a clock inside `scene` with a polite interface.
//!
//! Every timestamp here is therefore **handed in by the caller**, and the caller is
//! whoever already had the right to read one — `app` for the parts of the frame it owns,
//! the game for the parts it owns. What this file provides is storage that cannot fail
//! and summary arithmetic that does not allocate.
//!
//! Two properties are load-bearing and are tested rather than asserted:
//!
//! * **Nothing here allocates after `init`.** A profiler that could fail in the middle of
//!   the thing it is measuring would fail exactly when it was needed — the same property
//!   `audio.md` §5 required of the mix callback, for the same reason.
//! * **Every misuse is counted and survivable.** An unbalanced `close`, a frame with more
//!   spans than fit, a name table that is full: each is a number in the frame rather than
//!   a panic. From M7 the caller may be a mod (`CLAUDE.md` §7).
//!
//! Design: `docs/design/debug-overlay.md` §4.

const std = @import("std");
const time = @import("time.zig");

const Allocator = std.mem.Allocator;
const Instant = time.Instant;

/// Reserved name index meaning "the name table was full when this span opened".
pub const unnamed: u16 = std.math.maxInt(u16);

/// What `nameOf` answers for `unnamed`, and for an index that was never interned.
pub const unnamed_text = "?";

/// One timed region inside one frame.
///
/// Twelve bytes, and the shape is why: `name` is an index into the recorder's own table
/// rather than a slice, because a mod's string must not have to outlive the call that
/// supplied it; and the timestamps are **offsets from the frame's start** rather than
/// `Instant`s, because two absolute instants per span are sixteen bytes whose high half
/// is identical across the whole frame. A span longer than the 4.29 seconds a `u32` of
/// nanoseconds holds is not a measurement, it is a hang, and saturating says so more
/// usefully than a wider field would.
pub const Span = struct {
    name: u16,
    depth: u16,
    begin_ns: u32,
    end_ns: u32,

    pub fn durationNs(self: Span) u32 {
        return self.end_ns -| self.begin_ns;
    }
};

/// One finished frame, as a reader sees it.
///
/// `spans` borrows the recorder's storage and is valid until that slot is written again,
/// which is `history` frames from now. A reader that keeps one longer is keeping a
/// pointer into a ring, and this is the only lifetime rule in the file.
pub const Frame = struct {
    index: u64,
    total_ns: i64,
    spans: []const Span,
    /// Spans that did not fit — in the frame's span budget or in the open stack's depth.
    dropped: u16,
    /// `close` calls with nothing open, plus spans still open when the frame ended.
    unbalanced: u16,
};

pub const Options = struct {
    /// Spans recorded per frame before further ones are counted and dropped.
    max_spans_per_frame: u16 = 128,
    /// Frames kept. 240 is four seconds at 60Hz — long enough that a hitch is still on
    /// screen by the time somebody looks for it.
    history: u16 = 240,
    /// Distinct span names. A name is a category, not a value; a caller formatting one
    /// per entity is misusing this and will see `?` when the table fills.
    max_names: u16 = 64,
    /// Bytes for those names.
    name_bytes: u32 = 1024,
    /// Nesting depth. Deeper opens are counted and dropped, and their `close`s are
    /// matched correctly anyway — see `close`.
    max_depth: u8 = 16,
};

const NameRef = struct { offset: u32, len: u32 };

const FrameRecord = struct {
    index: u64 = 0,
    total_ns: i64 = 0,
    span_count: u16 = 0,
    dropped: u16 = 0,
    unbalanced: u16 = 0,
};

/// Sentinel pushed onto the open stack for a span that was dropped, so that its matching
/// `close` closes nothing instead of closing somebody else's span.
const dropped_slot: u32 = std.math.maxInt(u32);

pub const Recorder = struct {
    options: Options = .{ .history = 0, .max_spans_per_frame = 0, .max_names = 0, .name_bytes = 0, .max_depth = 0 },

    spans: []Span = &.{},
    frame_pool: []FrameRecord = &.{},
    names: []NameRef = &.{},
    name_text: []u8 = &.{},
    stack: []u32 = &.{},

    /// Slot the next frame will be written into.
    next_slot: u16 = 0,
    /// Finished frames available to a reader, capped at `options.history`.
    recorded: u16 = 0,

    in_frame: bool = false,
    frame_index: u64 = 0,
    frame_begin_ns: i64 = 0,

    open_count: u8 = 0,
    /// Opens beyond `max_depth`. Counted separately so that their closes still pair up:
    /// anything deeper than the stack is always closed before anything on it.
    overflow_depth: u16 = 0,

    span_count: u16 = 0,
    dropped: u16 = 0,
    unbalanced: u16 = 0,

    name_count: u16 = 0,
    name_used: u32 = 0,

    /// A recorder that records nothing and costs nothing. Every call is a no-op and
    /// `enabled()` is false, which is what a release build and a headless tool get.
    pub const off: Recorder = .{};

    pub fn init(gpa: Allocator, options: Options) Allocator.Error!Recorder {
        if (options.history == 0 or options.max_spans_per_frame == 0) return off;

        const spans = try gpa.alloc(Span, @as(usize, options.history) * options.max_spans_per_frame);
        errdefer gpa.free(spans);
        const frame_pool = try gpa.alloc(FrameRecord, options.history);
        errdefer gpa.free(frame_pool);
        const names = try gpa.alloc(NameRef, options.max_names);
        errdefer gpa.free(names);
        const name_text = try gpa.alloc(u8, options.name_bytes);
        errdefer gpa.free(name_text);
        const stack = try gpa.alloc(u32, options.max_depth);

        @memset(frame_pool, .{});
        return .{
            .options = options,
            .spans = spans,
            .frame_pool = frame_pool,
            .names = names,
            .name_text = name_text,
            .stack = stack,
        };
    }

    pub fn deinit(self: *Recorder, gpa: Allocator) void {
        gpa.free(self.spans);
        gpa.free(self.frame_pool);
        gpa.free(self.names);
        gpa.free(self.name_text);
        gpa.free(self.stack);
        self.* = off;
    }

    /// Whether this recorder stores anything. Callers check it before reading a clock, so
    /// a disabled profiler costs one branch per scope and no syscall.
    pub fn enabled(self: *const Recorder) bool {
        return self.frame_pool.len != 0;
    }

    // -- writing -------------------------------------------------------------------

    /// Starts a frame. A frame left open by a missing `endFrame` is ended here, at this
    /// instant, rather than being abandoned.
    pub fn beginFrame(self: *Recorder, index: u64, at: Instant) void {
        if (!self.enabled()) return;
        if (self.in_frame) self.endFrame(at);

        self.in_frame = true;
        self.frame_index = index;
        self.frame_begin_ns = at.ns;
        self.open_count = 0;
        self.overflow_depth = 0;
        self.span_count = 0;
        self.dropped = 0;
        self.unbalanced = 0;
    }

    /// Opens a named span. Outside a frame this is ignored: there is nowhere to put it,
    /// and inventing a frame would make the timeline lie.
    pub fn open(self: *Recorder, name: []const u8, at: Instant) void {
        if (!self.in_frame) return;

        const depth: u16 = @intCast(@as(u32, self.open_count) + self.overflow_depth);

        if (self.open_count == self.stack.len) {
            self.overflow_depth +|= 1;
            self.dropped +|= 1;
            return;
        }
        if (self.span_count == self.options.max_spans_per_frame) {
            // Still pushed, as a sentinel: the matching `close` has to pop *something* or
            // it would close the span below this one.
            self.stack[self.open_count] = dropped_slot;
            self.open_count += 1;
            self.dropped +|= 1;
            return;
        }

        const slot = self.spanBase() + self.span_count;
        self.spans[slot] = .{
            .name = self.internName(name),
            .depth = depth,
            .begin_ns = self.offsetOf(at),
            .end_ns = self.offsetOf(at),
        };
        self.stack[self.open_count] = @intCast(slot);
        self.open_count += 1;
        self.span_count += 1;
    }

    /// Closes the innermost open span. A `close` with nothing open is counted, not fatal.
    pub fn close(self: *Recorder, at: Instant) void {
        if (!self.in_frame) return;

        if (self.overflow_depth > 0) {
            self.overflow_depth -= 1;
            return;
        }
        if (self.open_count == 0) {
            self.unbalanced +|= 1;
            return;
        }
        self.open_count -= 1;
        const slot = self.stack[self.open_count];
        if (slot == dropped_slot) return;
        self.spans[slot].end_ns = self.offsetOf(at);
    }

    /// Ends the frame, closing anything still open and counting it.
    pub fn endFrame(self: *Recorder, at: Instant) void {
        if (!self.in_frame) return;

        const still_open: u32 = @as(u32, self.open_count) + self.overflow_depth;
        while (self.open_count > 0 or self.overflow_depth > 0) self.close(at);
        self.unbalanced +|= std.math.lossyCast(u16, still_open);

        self.frame_pool[self.next_slot] = .{
            .index = self.frame_index,
            .total_ns = at.ns - self.frame_begin_ns,
            .span_count = self.span_count,
            .dropped = self.dropped,
            .unbalanced = self.unbalanced,
        };
        self.next_slot = (self.next_slot + 1) % @as(u16, @intCast(self.frame_pool.len));
        if (self.recorded < self.frame_pool.len) self.recorded += 1;
        self.in_frame = false;
    }

    // -- reading -------------------------------------------------------------------

    /// The text a span's `name` index stands for.
    pub fn nameOf(self: *const Recorder, name: u16) []const u8 {
        if (name >= self.name_count) return unnamed_text;
        const ref = self.names[name];
        return self.name_text[ref.offset..][0..ref.len];
    }

    /// How many finished frames are available.
    pub fn frameCount(self: *const Recorder) u16 {
        return self.recorded;
    }

    /// Finished frames, **oldest first**. A frame in progress is not among them.
    pub fn frames(self: *const Recorder) FrameIterator {
        return .{ .recorder = self };
    }

    /// The `n`-th oldest finished frame.
    pub fn frameAt(self: *const Recorder, n: u16) ?Frame {
        if (n >= self.recorded) return null;
        const oldest = (self.next_slot + self.frame_pool.len - self.recorded) % self.frame_pool.len;
        const slot: u16 = @intCast((oldest + n) % self.frame_pool.len);
        const rec = self.frame_pool[slot];
        const base = @as(usize, slot) * self.options.max_spans_per_frame;
        return .{
            .index = rec.index,
            .total_ns = rec.total_ns,
            .spans = self.spans[base..][0..rec.span_count],
            .dropped = rec.dropped,
            .unbalanced = rec.unbalanced,
        };
    }

    /// The most recently finished frame.
    pub fn latest(self: *const Recorder) ?Frame {
        if (self.recorded == 0) return null;
        return self.frameAt(self.recorded - 1);
    }

    /// Frame totals, oldest first, into a caller's buffer. What a plot is drawn from.
    ///
    /// Returns the prefix actually written: if `out` is shorter than the history, the
    /// **most recent** `out.len` frames are the ones that fit, because a plot showing the
    /// oldest quarter of a ring would be showing the wrong end of it.
    pub fn totalsMs(self: *const Recorder, out: []f32) []f32 {
        const n: u16 = @intCast(@min(out.len, self.recorded));
        const first = self.recorded - n;
        for (0..n) |i| {
            const frame = self.frameAt(first + @as(u16, @intCast(i))).?;
            out[i] = @as(f32, @floatFromInt(frame.total_ns)) / @as(f32, @floatFromInt(time.ns_per_ms));
        }
        return out[0..n];
    }

    pub const FrameIterator = struct {
        recorder: *const Recorder,
        at: u16 = 0,

        pub fn next(self: *FrameIterator) ?Frame {
            const frame = self.recorder.frameAt(self.at) orelse return null;
            self.at += 1;
            return frame;
        }
    };

    // -- internals -----------------------------------------------------------------

    fn spanBase(self: *const Recorder) u16 {
        return self.next_slot * self.options.max_spans_per_frame;
    }

    /// Nanoseconds since the frame began, saturating at both ends. A clock that went
    /// backwards produces zero rather than an enormous unsigned number.
    fn offsetOf(self: *const Recorder, at: Instant) u32 {
        const delta = at.ns - self.frame_begin_ns;
        if (delta <= 0) return 0;
        return std.math.lossyCast(u32, delta);
    }

    /// Finds a name, or copies it in. Linear, because a name is a category and there are
    /// tens of them; a hash map here would be machinery guarding nothing.
    fn internName(self: *Recorder, name: []const u8) u16 {
        for (self.names[0..self.name_count], 0..) |ref, i| {
            if (std.mem.eql(u8, self.name_text[ref.offset..][0..ref.len], name)) return @intCast(i);
        }
        if (self.name_count == self.names.len) return unnamed;
        if (name.len > self.name_text.len - self.name_used) return unnamed;

        const offset = self.name_used;
        @memcpy(self.name_text[offset..][0..name.len], name);
        self.name_used += @intCast(name.len);
        self.names[self.name_count] = .{ .offset = offset, .len = @intCast(name.len) };
        self.name_count += 1;
        return self.name_count - 1;
    }
};

// -- summarising -------------------------------------------------------------------

pub const Summary = struct {
    /// How many samples this describes. Zero means every other field is zero.
    count: u32 = 0,
    min_ns: i64 = 0,
    max_ns: i64 = 0,
    mean_ns: i64 = 0,
    median_ns: i64 = 0,
    p95_ns: i64 = 0,
};

/// Min, max, mean, median and p95 over `samples`, sorting into `scratch`.
///
/// **Allocates nothing**: a sort needs somewhere to put a copy, and `core` is not going to
/// take an allocator behind a caller's back for it. If `scratch` is shorter than
/// `samples`, the **most recent** `scratch.len` samples are summarised and `count` says
/// so — a partial answer about the newest frames is useful, and one about the oldest is
/// not.
///
/// Percentiles are nearest-rank: the p-th percentile of `n` sorted samples is the element
/// at `ceil(p*n/100) - 1`. Stated because there are several defensible definitions and a
/// number that changes meaning between builds is worse than either.
pub fn summarise(samples: []const i64, scratch: []i64) Summary {
    const n = @min(samples.len, scratch.len);
    if (n == 0) return .{};

    const src = samples[samples.len - n ..];
    @memcpy(scratch[0..n], src);
    const window = scratch[0..n];
    std.mem.sort(i64, window, {}, std.sort.asc(i64));

    var total: i128 = 0;
    for (window) |v| total += v;

    return .{
        .count = @intCast(n),
        .min_ns = window[0],
        .max_ns = window[n - 1],
        .mean_ns = @intCast(@divTrunc(total, @as(i128, @intCast(n)))),
        .median_ns = window[rankIndex(n, 50)],
        .p95_ns = window[rankIndex(n, 95)],
    };
}

fn rankIndex(n: usize, percentile: u32) usize {
    const rank = (percentile * n + 99) / 100;
    return @min(n - 1, if (rank == 0) 0 else rank - 1);
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

fn stamp(ns: i64) Instant {
    return .{ .ns = ns };
}

fn testRecorder(options: Options) !Recorder {
    return Recorder.init(testing.allocator, options);
}

test "a disabled recorder records nothing and never touches memory" {
    var r: Recorder = .off;
    try testing.expect(!r.enabled());

    r.beginFrame(1, stamp(0));
    r.open("a", stamp(1));
    r.close(stamp(2));
    r.endFrame(stamp(3));

    try testing.expectEqual(@as(u16, 0), r.frameCount());
    try testing.expect(r.latest() == null);
}

test "spans nest, and depth is where they were opened" {
    var r = try testRecorder(.{ .history = 4, .max_spans_per_frame = 8 });
    defer r.deinit(testing.allocator);

    r.beginFrame(7, stamp(1000));
    r.open("outer", stamp(1100));
    r.open("inner", stamp(1200));
    r.close(stamp(1500));
    r.close(stamp(1900));
    r.endFrame(stamp(2000));

    const frame = r.latest().?;
    try testing.expectEqual(@as(u64, 7), frame.index);
    try testing.expectEqual(@as(i64, 1000), frame.total_ns);
    try testing.expectEqual(@as(usize, 2), frame.spans.len);

    // Written in the order they were opened, so a walk of the slice is a walk of the tree.
    try testing.expectEqualStrings("outer", r.nameOf(frame.spans[0].name));
    try testing.expectEqual(@as(u16, 0), frame.spans[0].depth);
    try testing.expectEqual(@as(u32, 100), frame.spans[0].begin_ns);
    try testing.expectEqual(@as(u32, 900), frame.spans[0].end_ns);

    try testing.expectEqualStrings("inner", r.nameOf(frame.spans[1].name));
    try testing.expectEqual(@as(u16, 1), frame.spans[1].depth);
    try testing.expectEqual(@as(u32, 300), frame.spans[1].durationNs());
}

test "a name is interned once and shared by every span that uses it" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 8 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(0));
    r.open("step", stamp(1));
    r.close(stamp(2));
    r.open("step", stamp(3));
    r.close(stamp(4));
    r.endFrame(stamp(5));

    const frame = r.latest().?;
    try testing.expectEqual(frame.spans[0].name, frame.spans[1].name);
    try testing.expectEqual(@as(u16, 1), r.name_count);
}

test "a full name table yields spans that are still timed but unnamed" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 8, .max_names = 1 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(0));
    r.open("first", stamp(10));
    r.close(stamp(20));
    r.open("second", stamp(30));
    r.close(stamp(60));
    r.endFrame(stamp(100));

    const frame = r.latest().?;
    try testing.expectEqualStrings("first", r.nameOf(frame.spans[0].name));
    try testing.expectEqual(unnamed, frame.spans[1].name);
    try testing.expectEqualStrings(unnamed_text, r.nameOf(frame.spans[1].name));
    // The measurement survives losing the label, which is the right way round.
    try testing.expectEqual(@as(u32, 30), frame.spans[1].durationNs());
}

test "a name too long for the remaining bytes is unnamed rather than truncated" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 4, .max_names = 8, .name_bytes = 4 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(0));
    r.open("abcd", stamp(1));
    r.close(stamp(2));
    r.open("e", stamp(3));
    r.close(stamp(4));
    r.endFrame(stamp(5));

    const frame = r.latest().?;
    try testing.expectEqualStrings("abcd", r.nameOf(frame.spans[0].name));
    try testing.expectEqual(unnamed, frame.spans[1].name);
}

test "an unbalanced close is counted, not fatal" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 4 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(0));
    r.close(stamp(10));
    r.close(stamp(20));
    r.open("real", stamp(30));
    r.close(stamp(40));
    r.endFrame(stamp(50));

    const frame = r.latest().?;
    try testing.expectEqual(@as(u16, 2), frame.unbalanced);
    try testing.expectEqual(@as(usize, 1), frame.spans.len);
    try testing.expectEqual(@as(u32, 10), frame.spans[0].durationNs());
}

test "a span left open at the end of a frame is closed there and counted" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 4 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(0));
    r.open("leaked", stamp(100));
    r.endFrame(stamp(900));

    const frame = r.latest().?;
    try testing.expectEqual(@as(u16, 1), frame.unbalanced);
    try testing.expectEqual(@as(u32, 800), frame.spans[0].durationNs());
}

test "an overflowing frame keeps the spans that fit and counts the rest" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 2 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(0));
    for (0..5) |i| {
        const t: i64 = @intCast(i * 10);
        r.open("x", stamp(t));
        r.close(stamp(t + 5));
    }
    r.endFrame(stamp(100));

    const frame = r.latest().?;
    try testing.expectEqual(@as(usize, 2), frame.spans.len);
    try testing.expectEqual(@as(u16, 3), frame.dropped);
    // The dropped spans' closes matched their own opens, so nothing is reported
    // unbalanced and no surviving span had its end overwritten.
    try testing.expectEqual(@as(u16, 0), frame.unbalanced);
    try testing.expectEqual(@as(u32, 5), frame.spans[0].durationNs());
    try testing.expectEqual(@as(u32, 5), frame.spans[1].durationNs());
}

test "a dropped span's close does not close the span underneath it" {
    // The bug this exists to prevent: `outer` ending at 20 instead of 900, because the
    // dropped `inner`'s close popped it.
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 1 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(0));
    r.open("outer", stamp(10));
    r.open("inner", stamp(15));
    r.close(stamp(20));
    r.close(stamp(900));
    r.endFrame(stamp(1000));

    const frame = r.latest().?;
    try testing.expectEqual(@as(usize, 1), frame.spans.len);
    try testing.expectEqualStrings("outer", r.nameOf(frame.spans[0].name));
    try testing.expectEqual(@as(u32, 890), frame.spans[0].durationNs());
    try testing.expectEqual(@as(u16, 0), frame.unbalanced);
}

test "nesting deeper than the stack is dropped and still pairs up" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 16, .max_depth = 2 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(0));
    r.open("a", stamp(10)); // depth 0, kept
    r.open("b", stamp(20)); // depth 1, kept
    r.open("c", stamp(30)); // depth 2, dropped
    r.open("d", stamp(40)); // depth 3, dropped
    r.close(stamp(50)); // d
    r.close(stamp(60)); // c
    r.close(stamp(70)); // b
    r.close(stamp(80)); // a
    r.endFrame(stamp(90));

    const frame = r.latest().?;
    try testing.expectEqual(@as(usize, 2), frame.spans.len);
    try testing.expectEqual(@as(u16, 2), frame.dropped);
    try testing.expectEqual(@as(u16, 0), frame.unbalanced);
    try testing.expectEqual(@as(u32, 70), frame.spans[0].durationNs()); // a: 10..80
    try testing.expectEqual(@as(u32, 50), frame.spans[1].durationNs()); // b: 20..70
}

test "the history ring wraps and the oldest frame is the one lost" {
    var r = try testRecorder(.{ .history = 3, .max_spans_per_frame = 2 });
    defer r.deinit(testing.allocator);

    for (1..6) |i| {
        const base: i64 = @intCast(i * 1000);
        r.beginFrame(i, stamp(base));
        r.open("f", stamp(base + 1));
        r.close(stamp(base + 2));
        r.endFrame(stamp(base + 100));
    }

    try testing.expectEqual(@as(u16, 3), r.frameCount());
    // Oldest first: frames 3, 4, 5. Frames 1 and 2 have been overwritten.
    try testing.expectEqual(@as(u64, 3), r.frameAt(0).?.index);
    try testing.expectEqual(@as(u64, 4), r.frameAt(1).?.index);
    try testing.expectEqual(@as(u64, 5), r.frameAt(2).?.index);
    try testing.expectEqual(@as(u64, 5), r.latest().?.index);
    try testing.expect(r.frameAt(3) == null);

    // Each surviving frame still owns its own spans rather than a neighbour's.
    var it = r.frames();
    var seen: u32 = 0;
    while (it.next()) |frame| : (seen += 1) {
        try testing.expectEqual(@as(usize, 1), frame.spans.len);
        try testing.expectEqual(@as(u32, 1), frame.spans[0].durationNs());
    }
    try testing.expectEqual(@as(u32, 3), seen);
}

test "a frame left open is ended by the next beginFrame" {
    var r = try testRecorder(.{ .history = 4, .max_spans_per_frame = 4 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(0));
    r.open("work", stamp(10));
    r.beginFrame(2, stamp(500));
    r.endFrame(stamp(600));

    try testing.expectEqual(@as(u16, 2), r.frameCount());
    const first = r.frameAt(0).?;
    try testing.expectEqual(@as(u64, 1), first.index);
    try testing.expectEqual(@as(i64, 500), first.total_ns);
    try testing.expectEqual(@as(u16, 1), first.unbalanced);
}

test "a span outside a frame is ignored rather than invented" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 4 });
    defer r.deinit(testing.allocator);

    r.open("nowhere", stamp(10));
    r.close(stamp(20));
    try testing.expectEqual(@as(u16, 0), r.frameCount());

    r.beginFrame(1, stamp(0));
    r.endFrame(stamp(10));
    try testing.expectEqual(@as(usize, 0), r.latest().?.spans.len);
}

test "a clock that goes backwards saturates at zero rather than wrapping" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 4 });
    defer r.deinit(testing.allocator);

    r.beginFrame(1, stamp(1000));
    r.open("backwards", stamp(900));
    r.close(stamp(800));
    r.endFrame(stamp(1100));

    const frame = r.latest().?;
    try testing.expectEqual(@as(u32, 0), frame.spans[0].begin_ns);
    try testing.expectEqual(@as(u32, 0), frame.spans[0].end_ns);
}

test "a span longer than a u32 of nanoseconds saturates" {
    var r = try testRecorder(.{ .history = 2, .max_spans_per_frame = 4 });
    defer r.deinit(testing.allocator);

    const ten_seconds = 10 * time.ns_per_s;
    r.beginFrame(1, stamp(0));
    r.open("hang", stamp(0));
    r.close(stamp(ten_seconds));
    r.endFrame(stamp(ten_seconds));

    const frame = r.latest().?;
    try testing.expectEqual(std.math.maxInt(u32), frame.spans[0].end_ns);
    // The frame total is an i64 and is not saturated, so the two disagreeing is itself
    // the signal that a span ran off the end of its field.
    try testing.expectEqual(ten_seconds, frame.total_ns);
}

test "frame totals come out newest-aligned when the buffer is short" {
    var r = try testRecorder(.{ .history = 8, .max_spans_per_frame = 2 });
    defer r.deinit(testing.allocator);

    for (1..6) |i| {
        const base: i64 = @intCast(i * 1_000_000); // 1ms, 2ms, ...
        r.beginFrame(i, stamp(0));
        r.endFrame(stamp(base));
    }

    var buf: [3]f32 = undefined;
    const totals = r.totalsMs(&buf);
    try testing.expectEqual(@as(usize, 3), totals.len);
    try testing.expectApproxEqAbs(@as(f32, 3), totals[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 4), totals[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5), totals[2], 1e-5);
}

test "summarise over a known set" {
    const samples = [_]i64{ 5, 1, 4, 2, 3 };
    var scratch: [5]i64 = undefined;
    const s = summarise(&samples, &scratch);

    try testing.expectEqual(@as(u32, 5), s.count);
    try testing.expectEqual(@as(i64, 1), s.min_ns);
    try testing.expectEqual(@as(i64, 5), s.max_ns);
    try testing.expectEqual(@as(i64, 3), s.mean_ns);
    try testing.expectEqual(@as(i64, 3), s.median_ns); // ceil(50*5/100)=3 -> index 2
    try testing.expectEqual(@as(i64, 5), s.p95_ns); // ceil(95*5/100)=5 -> index 4

    // The caller's samples are not reordered: a plot drawn from the same array afterwards
    // must still be in time order.
    try testing.expectEqual(@as(i64, 5), samples[0]);
}

test "summarise degenerate cases" {
    var scratch: [8]i64 = undefined;

    try testing.expectEqual(@as(u32, 0), summarise(&.{}, &scratch).count);
    try testing.expectEqual(@as(u32, 0), summarise(&[_]i64{1}, scratch[0..0]).count);

    const one = summarise(&[_]i64{42}, &scratch);
    try testing.expectEqual(@as(i64, 42), one.min_ns);
    try testing.expectEqual(@as(i64, 42), one.p95_ns);

    const flat = summarise(&[_]i64{ 7, 7, 7, 7 }, &scratch);
    try testing.expectEqual(@as(i64, 7), flat.median_ns);
    try testing.expectEqual(@as(i64, 7), flat.mean_ns);
}

test "a short scratch summarises the newest samples" {
    const samples = [_]i64{ 100, 200, 300, 1, 2 };
    var scratch: [2]i64 = undefined;
    const s = summarise(&samples, &scratch);

    try testing.expectEqual(@as(u32, 2), s.count);
    try testing.expectEqual(@as(i64, 1), s.min_ns);
    try testing.expectEqual(@as(i64, 2), s.max_ns);
}

test "p95 of a hundred samples is the ninety-fifth" {
    var samples: [100]i64 = undefined;
    for (&samples, 0..) |*v, i| v.* = @intCast(i + 1);
    var scratch: [100]i64 = undefined;

    const s = summarise(&samples, &scratch);
    try testing.expectEqual(@as(i64, 95), s.p95_ns);
    try testing.expectEqual(@as(i64, 50), s.median_ns);
}

test "init refuses to allocate for a history nobody asked for" {
    var r = try testRecorder(.{ .history = 0 });
    defer r.deinit(testing.allocator);
    try testing.expect(!r.enabled());
}
