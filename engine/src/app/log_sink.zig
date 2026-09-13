//! The log sink, and the runtime level filter.
//!
//! `core.log` deliberately stops at defining the interface and the compile-time levels:
//! `core` is layer L0 and has no business deciding where output goes. Choosing a
//! destination is an application decision, so it is made here, and a game wires it up
//! with one line in its root source file:
//!
//!     pub const std_options = app.std_options;
//!
//! ## Two filters, and why both
//!
//! The **compile-time** level (`core.log.compiled_level`) decides what is *built*. A call
//! below it is not merely silenced — the call and the evaluation of its arguments are
//! compiled away, which is what makes a `trace` in a hot loop free in a release build.
//!
//! The **runtime** level below decides what a built call *prints*. That is what lets a
//! shipped build be made quiet or verbose without recompiling — the thing you want at
//! three in the morning when a player's log is the only evidence you have.
//!
//! Design: `docs/design/app-and-frame-loop.md` §5.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;

/// The most verbose level that will actually be printed.
///
/// Atomic because logging is reachable from any thread, and this is set rarely and read
/// often. It is the one piece of genuinely ambient state in Foundry, which is defensible
/// only because logging is ambient by nature: `std.log` reaches it from code that has no
/// engine pointer to ask.
var runtime_level: std.atomic.Value(u8) = .init(@intFromEnum(std.log.Level.debug));

/// Sets the most verbose level that will be printed. Safe to call at any time.
pub fn setLevel(new_level: core.log.Level) void {
    runtime_level.store(@intFromEnum(toStd(new_level)), .monotonic);
}

/// The current runtime level, as a `std.log.Level`.
pub fn level() std.log.Level {
    return @enumFromInt(runtime_level.load(.monotonic));
}

/// `core.log` has one level `std.log` does not. `trace` rides on `debug` with a marker,
/// so it cannot be separated at runtime — only at compile time, which is where the cost
/// of a trace call actually matters.
fn toStd(from: core.log.Level) std.log.Level {
    return switch (from) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug, .trace => .debug,
    };
}

/// Foundry's `logFn`.
///
/// Delegates the actual writing to `std.log.defaultLog` rather than reimplementing it.
/// That is deliberate: std already handles stderr locking, terminal detection and colour,
/// and duplicating those to change a prefix would be work with a maintenance cost and no
/// payoff. What this adds is the runtime filter, which std has no notion of, and the
/// in-memory ring below, which is what a log console reads.
///
/// **The two destinations are filtered independently**, and the ring's check comes first.
/// Quietening the terminal to `err` at three in the morning must not also blind the console
/// you opened to find out what happened.
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Severity is ordered most-severe-first, so a *lower* value passes a *lower* filter.
    const to_terminal = @intFromEnum(message_level) <= @intFromEnum(level());
    // The "off" sentinel is `0xff`, which is *larger* than every level — so it has to be
    // excluded explicitly rather than compared against. Severity being ordered
    // most-severe-first means there is no u8 below `err` for an off state to be.
    const capture_raw = captureLevelRaw();
    const to_ring = capture_raw != capture_off and @intFromEnum(message_level) <= capture_raw;
    const session_raw = session_level_raw.load(.monotonic);
    const to_session = session_raw != capture_off and @intFromEnum(message_level) <= session_raw;
    if (!to_terminal and !to_ring and !to_session) return;

    if (to_ring or to_session) capture(message_level, @tagName(scope), format, args, to_ring, to_session);
    if (to_terminal) std.log.defaultLog(message_level, scope, format, args);
}

// -- the in-memory ring ---------------------------------------------------------------
//
// A **second** destination, never a replacement: a crash loses the ring and does not lose
// the terminal, and the terminal is what a bug report contains.
//
// Ambient, like the runtime level above and for the same reason — `std.log` reaches this
// from code that has no engine pointer to ask — and **statically sized**, because an
// ambient thing has no owner to hand it an allocator. Nothing here allocates.
//
// Design: `docs/design/debug-overlay.md` §6.

/// Longest line kept. A longer one is truncated with a marker, because a truncated line is
/// a diagnostic and a failed one is a mystery.
pub const max_line = 512;

/// Text kept, in bytes, and records kept. Whichever runs out first evicts the oldest.
pub const text_capacity = 64 * 1024;
pub const record_capacity = 1024;

/// The marker a truncated line ends with.
const truncation_marker = "...";

/// Sentinel meaning "keep nothing". Not a level, so it cannot be confused with one.
const capture_off: u8 = 0xff;

var capture_level_raw: std.atomic.Value(u8) = .init(capture_off);

/// Guards everything below it.
///
/// **Not a new hazard:** `std.log.defaultLog` already takes a lock to write stderr, so
/// every logging call site already blocks on one. It does mean the rule `audio.md` §4
/// states — no logging from the device callback, ever — now has a second reason behind it,
/// and a rule with one forgotten reason is a rule someone eventually relaxes.
///
/// **A spin lock rather than `std.Io.Mutex`**, for the reason this whole file is ambient:
/// Zig 0.16 made locking an `Io` operation, and `logFn` is the one place in Foundry with
/// no instance to ask for one. The trade is defensible because contention is essentially
/// zero — the writer is the game thread, the reader is the game thread once a frame, and
/// the one other thread in the engine is forbidden from logging — and because the critical
/// section is a `memcpy` and some arithmetic. **What would change it** is a second thread
/// that legitimately logs: a job system's workers, say. Then this wants a real mutex, and
/// by then there will be an `Io` to hand it.
var ring_mutex: Spin = .{};

const Spin = struct {
    state: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Spin) void {
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Spin) void {
        self.state.store(false, .release);
    }
};

var text_ring: [text_capacity]u8 = undefined;
var entries: [record_capacity]Entry = undefined;
/// Index of the oldest live record.
var oldest: usize = 0;
var live: usize = 0;
/// Next byte to write.
var text_head: u32 = 0;
/// Bytes the live records occupy, including any tail skipped to keep a line contiguous.
var text_used: u32 = 0;
var next_sequence: u64 = 1;
var dropped_total: u64 = 0;
/// Published by `setStamp`, copied by `capture`.
var stamp: Stamp = .{};

const Entry = struct {
    level: std.log.Level,
    /// A `@tagName` of a comptime enum literal: a compile-time constant with a
    /// program-lifetime address, so there is nothing to copy and nothing to free.
    scope: []const u8,
    frame: u64,
    elapsed: ?core.time.Duration,
    sequence: u64,
    offset: u32,
    len: u32,
    /// `len` plus any tail skipped before it, which is what eviction gives back. Kept per
    /// record so that reclaiming space is exact arithmetic rather than a modular overlap
    /// test nobody can read.
    consumed: u32,
};

/// One line, as a reader sees it. `text` is the reader's copy.
pub const Record = struct {
    level: std.log.Level,
    scope: []const u8,
    /// The engine frame this was logged in. What lines a log line up against a profiler
    /// span.
    frame: u64,
    /// The host's most recent elapsed-time observation when this was logged, or null before
    /// one (`Stamp`). Lines logged between two observations share it.
    elapsed: ?core.time.Duration = null,
    /// Monotonic from 1, so a reader can tell whether it has seen a line before.
    sequence: u64,
    text: []const u8,
};

/// What a reader is looking for.
pub const Filter = struct {
    /// Most verbose level to include.
    level: core.log.Level = .trace,
    /// Substring the text or the scope must contain. Empty matches everything.
    contains: []const u8 = "",
};

/// A page of matching records, and how many matched in total.
pub const View = struct {
    /// Every record matching the filter, whether or not it fitted in `records`.
    total: usize,
    /// The requested window, oldest first.
    records: []Record,
};

/// Sets the most verbose level kept in the ring, or `null` to keep nothing.
///
/// Independent of `setLevel`, which is the terminal's. The cost of the two being separate
/// is stated rather than hidden: a line formatted for the ring and not printed is work
/// done for a reader who may never look.
pub fn setCaptureLevel(new_level: ?core.log.Level) void {
    const raw: u8 = if (new_level) |l| @intFromEnum(toStd(l)) else capture_off;
    capture_level_raw.store(raw, .monotonic);
}

/// The ring's level, or null when it is off.
pub fn captureLevel() ?std.log.Level {
    const raw = captureLevelRaw();
    if (raw == capture_off) return null;
    return @enumFromInt(raw);
}

fn captureLevelRaw() u8 {
    return capture_level_raw.load(.monotonic);
}

/// What a captured line is stamped with: the frame it was logged in, and the most recent
/// elapsed time its host observed.
///
/// **Observed, never read.** `logFn` reads no clock. The engine publishes a reading it had
/// already taken for its frame delta, so every line between two publications carries the
/// earlier one and a burst of lines shares a time exactly. That is coarser than a clock read
/// per line, and it is the price of a sink that cannot change what the null platform's clock,
/// which advances per reading, hands the simulation (I9).
pub const Stamp = struct {
    frame: u64 = 0,
    /// Monotonic time since the host's origin — the engine's creation — in nanoseconds. Null
    /// until a host publishes one, and again once a session resets it: never an invented
    /// date, and never a previous session's.
    elapsed: ?core.time.Duration = null,
};

/// The stamp every line captured from now on carries, until the next call.
///
/// Called by the engine when it is created and twice a frame (`Engine.beginFrame`). **Under
/// the capture's lock** rather than as two atomics, so the frame and the time a line copies
/// always came from one publication.
pub fn setStamp(new: Stamp) void {
    // A monotonic reading measured from an earlier one. Negative is a host's bug, not input.
    if (new.elapsed) |elapsed| std.debug.assert(elapsed.ns >= 0);
    ring_mutex.lock();
    defer ring_mutex.unlock();
    stamp = new;
}

/// The stamp a line captured now would carry.
pub fn currentStamp() Stamp {
    ring_mutex.lock();
    defer ring_mutex.unlock();
    return stamp;
}

/// Lines evicted since the process started, because the ring filled.
pub fn dropped() u64 {
    ring_mutex.lock();
    defer ring_mutex.unlock();
    return dropped_total;
}

/// Live records.
pub fn count() usize {
    ring_mutex.lock();
    defer ring_mutex.unlock();
    return live;
}

/// Empties the ring. What a console's "clear" button calls; the drop count is kept,
/// because it is a fact about the run rather than about the view.
pub fn clear() void {
    ring_mutex.lock();
    defer ring_mutex.unlock();
    oldest = 0;
    live = 0;
    text_head = 0;
    text_used = 0;
}

/// Copies matching records into `out`, oldest first, starting at the `from`-th match.
///
/// **One lock, one pass**, so `total` and `records` describe the same instant — two calls
/// could disagree by a line that arrived between them, and a scroll bar computed from one
/// and filled from the other would jitter.
///
/// Text is copied into `arena` because the ring is free to overwrite it the moment the
/// lock is released. In a frame that arena is the frame's, and the copy is bounded by what
/// is on screen rather than by what is in the ring.
pub fn read(arena: Allocator, out: []Record, filter: Filter, from: usize) Allocator.Error![]Record {
    const view = try readView(arena, out, filter, from);
    return view.records;
}

/// As `read`, and also says how many records matched in total — the number a scroll range
/// is computed from.
pub fn readView(arena: Allocator, out: []Record, filter: Filter, from: usize) Allocator.Error!View {
    ring_mutex.lock();
    defer ring_mutex.unlock();

    const wanted = @intFromEnum(toStd(filter.level));
    var total: usize = 0;
    var written: usize = 0;

    for (0..live) |i| {
        const entry = entries[(oldest + i) % record_capacity];
        if (@intFromEnum(entry.level) > wanted) continue;
        const text = text_ring[entry.offset..][0..entry.len];
        if (filter.contains.len != 0 and
            std.mem.indexOf(u8, text, filter.contains) == null and
            std.mem.indexOf(u8, entry.scope, filter.contains) == null) continue;

        defer total += 1;
        if (total < from or written == out.len) continue;

        out[written] = .{
            .level = entry.level,
            .scope = entry.scope,
            .frame = entry.frame,
            .elapsed = entry.elapsed,
            .sequence = entry.sequence,
            .text = try arena.dupe(u8, text),
        };
        written += 1;
    }

    return .{ .total = total, .records = out[0..written] };
}

/// Formats one line into the ring. Called with the lock **not** held.
fn capture(
    comptime message_level: std.log.Level,
    scope: []const u8,
    comptime format: []const u8,
    args: anytype,
    to_ring: bool,
    to_session: bool,
) void {
    // On the stack, because `logFn` has no allocator and must not acquire one. A line that
    // does not fit keeps what fitted and says so.
    var buffer: [max_line]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const complete = if (writer.print(format, args)) |_| true else |_| false;
    var text = writer.buffered();
    if (!complete and text.len >= truncation_marker.len) {
        @memcpy(text[text.len - truncation_marker.len ..], truncation_marker);
    }

    ring_mutex.lock();
    defer ring_mutex.unlock();

    // Formatted once, kept twice. One lock rather than two, because the thing that must be
    // independent is the *state* — a console that is closed, or filtered to `err`, must not
    // be able to empty a release log — and that is two buffers and two levels, not two
    // locks.
    // Copied once, under the lock `setStamp` takes, so the two captures cannot disagree.
    const at = stamp;
    if (to_session) appendSession(message_level, scope, text, at);
    if (!to_ring) return;

    const offset = reserve(@intCast(text.len));
    @memcpy(text_ring[offset.at..][0..text.len], text);

    if (live == record_capacity) evictOldest();
    entries[(oldest + live) % record_capacity] = .{
        .level = message_level,
        .scope = scope,
        .frame = at.frame,
        .elapsed = at.elapsed,
        .sequence = next_sequence,
        .offset = offset.at,
        .len = @intCast(text.len),
        .consumed = offset.consumed,
    };
    live += 1;
    next_sequence += 1;
}

const Reservation = struct { at: u32, consumed: u32 };

/// Makes room for `len` contiguous bytes, evicting the oldest records until there is some.
///
/// **A message never straddles the end of the ring.** If it does not fit in the tail, the
/// tail is skipped and the message starts at the beginning: that wastes a few bytes and
/// buys the property a console needs, which is that every line is one slice — so a
/// substring filter matches against one slice and `read`'s copy is one `memcpy`.
fn reserve(len: u32) Reservation {
    if (len > text_capacity) unreachable; // `max_line` is far below `text_capacity`.

    const gap: u32 = if (text_head + len > text_capacity) text_capacity - text_head else 0;
    const need = len + gap;

    while (live > 0 and text_used + need > text_capacity) evictOldest();
    if (live == 0) {
        // Nothing is live, so the ring is a clean slate: the line goes at the start, and
        // the head and the used count follow it. **Forgetting to advance them here is the
        // bug this branch was written with** — every line then lands at offset zero, each
        // one overwriting the last, and the older records' slices quietly start reading the
        // newer one's bytes. The test below that logs numbered lines and checks they stay
        // distinct is the one that catches it.
        text_head = len;
        text_used = len;
        return .{ .at = 0, .consumed = len };
    }

    if (gap > 0) text_head = 0;
    const at = text_head;
    text_head += len;
    text_used += need;
    return .{ .at = at, .consumed = need };
}

fn evictOldest() void {
    if (live == 0) return;
    text_used -= entries[oldest].consumed;
    oldest = (oldest + 1) % record_capacity;
    live -= 1;
    dropped_total += 1;
}

// -- the session capture ---------------------------------------------------------------
//
// **A second bounded capture, and deliberately not the ring above.** The ring belongs to the
// overlay: a game filters it, clears it, and usually leaves it off. None of that may reach a
// release log, because the log is the only evidence a player's failed launch produces
// (`distribution.md` §10). So this is its own buffer, its own level and its own counter, and
// the only thing the two share is the lock and the single formatting pass.
//
// **A queue, not a ring.** Something drains this to a file at least once a frame, so it
// overflows only when one frame logs more than it holds. Then the right answer is to drop
// what does not fit and say how much — evicting the oldest instead would renumber a stream
// whose whole value is being in order.

/// How much one frame may produce. Also the drain's bound, since a full buffer is what a
/// drain empties: "no more than 64 KiB per frame" is a property of the buffer rather than a
/// rule something has to remember (§10).
pub const session_capacity = 64 * 1024;

var session_level_raw: std.atomic.Value(u8) = .init(capture_off);
var session_text: [session_capacity]u8 = undefined;
var session_used: u32 = 0;
var session_dropped: u64 = 0;

/// What a drain got, and what it cost.
pub const Drained = struct {
    /// Bytes copied into the caller's buffer.
    len: usize,
    /// Records dropped since the session started, cumulative.
    dropped: u64,
};

/// Turns the session capture on at `new_level`, or off. Called by `app.diagnostics`.
pub fn setSessionLevel(new_level: ?core.log.Level) void {
    session_level_raw.store(
        if (new_level) |l| @intFromEnum(toStd(l)) else capture_off,
        .monotonic,
    );
}

pub fn sessionLevel() ?std.log.Level {
    const raw = session_level_raw.load(.monotonic);
    return if (raw == capture_off) null else @enumFromInt(raw);
}

/// Empties the capture into `into`, and returns how much and what was lost.
///
/// The copy happens under the lock and the *writing* does not, which is the whole reason
/// this hands bytes back instead of taking a file: a drain that wrote to a disk with the log
/// lock held would stall every thread that logs for as long as the disk took (§10).
pub fn drainSession(into: []u8) Drained {
    ring_mutex.lock();
    defer ring_mutex.unlock();

    const len = @min(into.len, session_used);
    @memcpy(into[0..len], session_text[0..len]);
    if (len < session_used) {
        // Only possible if a caller brought a smaller buffer than the capacity. Keep the
        // remainder in order rather than dropping it.
        std.mem.copyForwards(u8, session_text[0 .. session_used - len], session_text[len..session_used]);
        session_used -= @intCast(len);
    } else {
        session_used = 0;
    }
    return .{ .len = len, .dropped = session_dropped };
}

/// Discards whatever the capture holds, and the stamp. Called when a session opens, so that it
/// inherits neither lines nor a frame and a time from whatever ran before it.
pub fn resetSession() void {
    ring_mutex.lock();
    defer ring_mutex.unlock();
    session_used = 0;
    session_dropped = 0;
    stamp = .{};
}

/// How a session line is laid out. The session header states it, so a log tells its reader
/// how to read it (`diagnostics.envelope_version` 2).
pub const session_line_format = "f<frame> <elapsed> <level>(<scope>): <text>";

/// Room on a session line for everything but its text. The widest frame and elapsed time take
/// 40 bytes and a level with the punctuation 11, which leaves a scope name 77.
const session_line_overhead = 128;

/// Appends one already-formatted line. Called with the lock held.
fn appendSession(message_level: std.log.Level, scope: []const u8, text: []const u8, at: Stamp) void {
    var line: [max_line + session_line_overhead]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&line);
    // The frame is the timeline a release log is read against, and the elapsed time is what
    // lines it up against a person's account of the session. Neither costs a clock read.
    const complete = if (writeSessionLine(&writer, message_level, scope, text, at)) |_| true else |_| false;
    const formatted = writer.buffered();
    // Only a scope name longer than any Foundry uses can overflow. What fitted is kept, and it
    // still ends a line, so the next line is never read as part of this one.
    if (!complete and formatted.len > 0) formatted[formatted.len - 1] = '\n';

    if (session_used + formatted.len > session_capacity) {
        session_dropped += 1;
        return;
    }
    @memcpy(session_text[session_used..][0..formatted.len], formatted);
    session_used += @intCast(formatted.len);
}

fn writeSessionLine(
    writer: *std.Io.Writer,
    message_level: std.log.Level,
    scope: []const u8,
    text: []const u8,
    at: Stamp,
) std.Io.Writer.Error!void {
    try writer.print("f{d} ", .{at.frame});
    if (at.elapsed) |elapsed| {
        // Seconds to the microsecond, with the unit written. The value is sampled once a
        // frame, so further digits would claim a precision it does not have.
        const ns: u64 = @intCast(elapsed.ns);
        try writer.print("{d}.{d:0>6}s", .{ ns / std.time.ns_per_s, ns % std.time.ns_per_s / std.time.ns_per_us });
    } else {
        try writer.writeByte('-');
    }
    try writer.print(" {s}({s}): {s}\n", .{ @tagName(message_level), scope, text });
}

/// Drop this into a game's root source file:
///
///     pub const std_options = app.std_options;
pub const std_options: std.Options = .{
    .logFn = logFn,
    // Everything reaches `logFn`; the runtime filter decides. Foundry's own compile-time
    // filtering already happened in `core.log`, which never builds the call at all below
    // `core.log.compiled_level`.
    .log_level = .debug,
};

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "the runtime level round-trips" {
    const restore = level();
    defer runtime_level.store(@intFromEnum(restore), .monotonic);

    setLevel(.err);
    try testing.expectEqual(std.log.Level.err, level());
    setLevel(.info);
    try testing.expectEqual(std.log.Level.info, level());
}

test "trace and debug share a runtime level" {
    // `core.log` has five levels and `std.log` has four. Recorded as a test so the
    // collapse is a known property rather than a surprise.
    const restore = level();
    defer runtime_level.store(@intFromEnum(restore), .monotonic);

    setLevel(.trace);
    try testing.expectEqual(std.log.Level.debug, level());
    setLevel(.debug);
    try testing.expectEqual(std.log.Level.debug, level());
}

test "a lower level suppresses the more verbose ones" {
    // Severity is ordered most-severe-first, which reads backwards and is exactly the
    // sort of comparison that gets inverted. `err` must pass an `err` filter; `info`
    // must not.
    const restore = level();
    defer runtime_level.store(@intFromEnum(restore), .monotonic);

    setLevel(.err);
    try testing.expect(@intFromEnum(std.log.Level.err) <= @intFromEnum(level()));
    try testing.expect(@intFromEnum(std.log.Level.warn) > @intFromEnum(level()));
    try testing.expect(@intFromEnum(std.log.Level.info) > @intFromEnum(level()));

    setLevel(.info);
    try testing.expect(@intFromEnum(std.log.Level.err) <= @intFromEnum(level()));
    try testing.expect(@intFromEnum(std.log.Level.warn) <= @intFromEnum(level()));
    try testing.expect(@intFromEnum(std.log.Level.debug) > @intFromEnum(level()));
}

/// Puts the sink back the way a test found it, whatever the test did to it.
///
/// The ring is ambient, so tests share it; each one that touches it restores the levels
/// and empties it, in that order.
fn restoreSink(previous_terminal: std.log.Level, previous_capture: ?core.log.Level) void {
    runtime_level.store(@intFromEnum(previous_terminal), .monotonic);
    setCaptureLevel(previous_capture);
    clear();
}

/// The state a ring test wants: nothing printed, everything captured, ring empty.
fn quietCapture() void {
    setLevel(.err);
    setCaptureLevel(.debug);
    clear();
    setStamp(.{});
}

test "the ring keeps what the terminal is too quiet to print" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);

    quietCapture();
    logFn(.info, .sink_test, "hello {d}", .{7});

    try testing.expectEqual(@as(usize, 1), count());

    var out: [4]Record = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try read(arena.allocator(), &out, .{}, 0);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("hello 7", got[0].text);
    try testing.expectEqualStrings("sink_test", got[0].scope);
    try testing.expectEqual(std.log.Level.info, got[0].level);
    try testing.expectEqual(@as(u64, 0), got[0].frame);
}

test "the ring's level is its own" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);

    setLevel(.err);
    setCaptureLevel(.warn);
    clear();

    logFn(.info, .sink_test, "not kept", .{});
    logFn(.warn, .sink_test, "kept", .{});
    try testing.expectEqual(@as(usize, 1), count());

    // Off keeps nothing at all. At `warn` rather than `err` so that nothing reaches the
    // terminal either — the runtime level above is `err`, and a test that prints is a test
    // whose output somebody has to learn to ignore.
    setCaptureLevel(null);
    logFn(.warn, .sink_test, "still nothing", .{});
    try testing.expectEqual(@as(usize, 1), count());
    try testing.expect(captureLevel() == null);
}

test "a record carries its frame and the time observed before it, or no time before any" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);

    quietCapture();
    setStamp(.{ .frame = 41 });
    logFn(.info, .sink_test, "before anything was observed", .{});
    setStamp(.{ .frame = 42, .elapsed = .fromMillis(1500) });
    logFn(.info, .sink_test, "the next one", .{});
    logFn(.info, .sink_test, "and one sharing its observation", .{});

    var out: [4]Record = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try read(arena.allocator(), &out, .{}, 0);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(@as(u64, 41), got[0].frame);
    try testing.expect(got[0].elapsed == null);
    try testing.expectEqual(@as(u64, 42), got[1].frame);
    try testing.expectEqual(@as(i64, 1500 * std.time.ns_per_ms), got[1].elapsed.?.ns);
    // Sampled, not read: two lines between observations carry the same one exactly.
    try testing.expectEqual(got[1].elapsed.?.ns, got[2].elapsed.?.ns);
    // Sequence numbers are monotonic, which is how a reader tells a line it has seen.
    try testing.expect(got[1].sequence > got[0].sequence);
}

test "a line longer than the buffer is truncated with a marker" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);

    quietCapture();
    const long = "x" ** (max_line * 2);
    logFn(.info, .sink_test, "{s}", .{long});

    var out: [1]Record = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try read(arena.allocator(), &out, .{}, 0);
    try testing.expectEqual(@as(usize, max_line), got[0].text.len);
    try testing.expectEqualStrings(truncation_marker, got[0].text[max_line - truncation_marker.len ..]);
}

test "the oldest lines are evicted first, and the drops are counted" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);

    quietCapture();
    const before = dropped();

    // Enough long lines to wrap the byte ring several times over.
    const chunk = "y" ** 400;
    const lines = (text_capacity / 400) * 3;
    for (0..lines) |i| logFn(.info, .sink_test, "{d} {s}", .{ i, chunk });

    try testing.expect(dropped() > before);
    try testing.expect(count() < lines);

    var out: [1]Record = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // What survives is the newest, and it is intact: the last line's number is still on it.
    const view = try readView(arena.allocator(), &out, .{}, count() - 1);
    try testing.expectEqual(@as(usize, 1), view.records.len);
    var expected: [16]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&expected, "{d} y", .{lines - 1});
    try testing.expect(std.mem.startsWith(u8, view.records[0].text, prefix));
}

test "each line keeps its own bytes, however the ring wrapped" {
    // Two properties at once, and the second is the one that catches a real bug. Every
    // line is a single contiguous slice, which is what the straddle-free rule buys — and
    // every line still holds *what it was given*, which fails the moment two records are
    // handed the same offset. Checking only the shape is not enough: an overwritten line
    // still looks like a line.
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);

    quietCapture();
    var length: usize = 1;
    for (0..600) |i| {
        length = (length * 7 + 13) % 400 + 1;
        logFn(.info, .sink_test, "{d}:{s}", .{ i, ("z" ** 400)[0..length] });
    }

    var out: [record_capacity]Record = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try read(arena.allocator(), &out, .{}, 0);
    try testing.expect(got.len > 0);

    var previous: ?usize = null;
    for (got) |record| {
        const colon = std.mem.indexOfScalar(u8, record.text, ':').?;
        const index = try std.fmt.parseInt(usize, record.text[0..colon], 10);

        // Distinct, in order, and none of them overwritten by a later one.
        if (previous) |p| try testing.expectEqual(p + 1, index);
        previous = index;

        // And the payload is the length that line was logged with, not a neighbour's.
        for (record.text[colon + 1 ..]) |c| try testing.expectEqual(@as(u8, 'z'), c);
    }
    // The last line logged is the last line kept.
    try testing.expectEqual(@as(usize, 599), previous.?);
}

test "a filter matches text or scope, and paging agrees with the total" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);

    quietCapture();
    logFn(.info, .render, "drew a thing", .{});
    logFn(.info, .audio, "played a thing", .{});
    logFn(.warn, .render, "dropped a thing", .{});

    var out: [8]Record = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // By scope.
    const by_scope = try read(gpa, &out, .{ .contains = "render" }, 0);
    try testing.expectEqual(@as(usize, 2), by_scope.len);

    // By text.
    const by_text = try read(gpa, &out, .{ .contains = "played" }, 0);
    try testing.expectEqual(@as(usize, 1), by_text.len);

    // By level.
    const by_level = try read(gpa, &out, .{ .level = .warn }, 0);
    try testing.expectEqual(@as(usize, 1), by_level.len);
    try testing.expectEqualStrings("dropped a thing", by_level[0].text);

    // A window into the middle, with the total describing the same instant as the page —
    // which is what one lock and one pass is for.
    var page: [1]Record = undefined;
    const view = try readView(gpa, &page, .{}, 1);
    try testing.expectEqual(@as(usize, 3), view.total);
    try testing.expectEqual(@as(usize, 1), view.records.len);
    try testing.expectEqualStrings("played a thing", view.records[0].text);
}

test "clear empties the ring and keeps the drop count" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);

    quietCapture();
    logFn(.info, .sink_test, "something", .{});
    try testing.expectEqual(@as(usize, 1), count());

    const drops = dropped();
    clear();
    try testing.expectEqual(@as(usize, 0), count());
    // A fact about the run, not about the view.
    try testing.expectEqual(drops, dropped());
}

/// Puts the session capture back the way a test found it: off and empty.
fn restoreSession() void {
    setSessionLevel(null);
    resetSession();
}

test "both captures copy one stamp, whatever each one's level keeps" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);
    defer restoreSession();
    const buffer = try testing.allocator.alloc(u8, session_capacity);
    defer testing.allocator.free(buffer);

    quietCapture();
    resetSession();
    // The ring keeps `warn` and the session `info`, so each keeps a line the other does not.
    setCaptureLevel(.warn);
    setSessionLevel(.info);
    setStamp(.{ .frame = 5, .elapsed = .fromNanos(250_000) });
    logFn(.info, .sink_test, "the session's only", .{});
    logFn(.warn, .sink_test, "both", .{});

    // And the other way round, with the session off.
    setSessionLevel(null);
    setCaptureLevel(.debug);
    setStamp(.{ .frame = 6, .elapsed = .fromSeconds(2) });
    logFn(.info, .sink_test, "the ring's only", .{});

    const got = drainSession(buffer);
    try testing.expectEqualStrings(
        "f5 0.000250s info(sink_test): the session's only\n" ++
            "f5 0.000250s warn(sink_test): both\n",
        buffer[0..got.len],
    );

    var out: [4]Record = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const records = try read(arena.allocator(), &out, .{}, 0);
    try testing.expectEqual(@as(usize, 2), records.len);
    try testing.expectEqualStrings("both", records[0].text);
    try testing.expectEqual(@as(u64, 5), records[0].frame);
    try testing.expectEqual(@as(i64, 250_000), records[0].elapsed.?.ns);
    try testing.expectEqualStrings("the ring's only", records[1].text);
    try testing.expectEqual(@as(u64, 6), records[1].frame);
    try testing.expectEqual(@as(i64, 2 * std.time.ns_per_s), records[1].elapsed.?.ns);
}

test "a session reset forgets the stamp, and a line before any observation says so" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);
    defer restoreSession();
    const buffer = try testing.allocator.alloc(u8, session_capacity);
    defer testing.allocator.free(buffer);

    quietCapture();
    // Whatever ran before — an engine, or a previous session's frames — left a stamp behind.
    setStamp(.{ .frame = 90, .elapsed = .fromSeconds(3) });
    resetSession();
    try testing.expectEqual(Stamp{}, currentStamp());

    setSessionLevel(.info);
    logFn(.info, .sink_test, "nothing observed yet", .{});
    const got = drainSession(buffer);
    try testing.expectEqualStrings("f0 - info(sink_test): nothing observed yet\n", buffer[0..got.len]);
}

test "a session line keeps its stamp when its text is truncated, and always ends its line" {
    const terminal = level();
    const kept = captureLevel();
    defer restoreSink(terminal, if (kept != null) .debug else null);
    defer restoreSession();
    const buffer = try testing.allocator.alloc(u8, session_capacity);
    defer testing.allocator.free(buffer);

    quietCapture();
    resetSession();
    setSessionLevel(.info);
    // The widest stamp there is.
    setStamp(.{ .frame = std.math.maxInt(u64), .elapsed = .fromNanos(std.math.maxInt(i64)) });
    logFn(.info, .sink_test, "{s}", .{"x" ** (max_line * 2)});

    var got = drainSession(buffer);
    const prefix = "f18446744073709551615 9223372036.854775s info(sink_test): ";
    try testing.expect(std.mem.startsWith(u8, buffer[0..got.len], prefix));
    try testing.expectEqual(prefix.len + max_line + 1, got.len);
    try testing.expect(std.mem.endsWith(u8, buffer[0..got.len], truncation_marker ++ "\n"));

    // A scope too long for the line — nothing forbids naming one — loses the end of what it
    // said, and still ends its line.
    logFn(.info, .a_scope_named_at_such_length_that_its_line_cannot_hold_the_stamp_the_scope_and_all_of_the_text, "{s}", .{"y" ** max_line});
    got = drainSession(buffer);
    try testing.expect(got.len <= max_line + session_line_overhead);
    try testing.expect(std.mem.startsWith(u8, buffer[0..got.len], "f18446744073709551615 "));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, buffer[0..got.len], "\n"));
    try testing.expect(std.mem.endsWith(u8, buffer[0..got.len], "\n"));
}

test "the exported std_options names our sink" {
    try testing.expect(std_options.logFn == logFn);
}
