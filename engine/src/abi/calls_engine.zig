//! The engine's own capabilities, as the table publishes them: results, logging, content
//! identity, the frame, the profiler and the memory report.
//!
//! Everything here follows one shape, and the shape is the point:
//!
//!   1. Find the bound host. Nothing bound is `unavailable`, never a crash — a mod's library
//!      stays loaded for the life of the process (§14), so a call after teardown is a case
//!      that actually happens rather than a hypothetical.
//!   2. Find the subsystem. Absent is `unavailable` (ADR-0026).
//!   3. **Validate every argument.** Pointers null-checked, lengths bounded, strings
//!      UTF-8-validated, enumerations looked up rather than cast, handles resolved rather
//!      than indexed. Not asserted, not assumed, not documented as a precondition.
//!   4. Call exactly one thing, and translate its answer.
//!   5. **Write the out-parameter only on success**, so a call that fails leaves what the
//!      caller passed exactly as it was.
//!
//! No step here may panic and none may propagate a Zig error. That is not a convention: the
//! caller is a compiled binary from outside this repository, and the failure this rule
//! prevents is its bad argument crashing the host inside a subsystem three layers down.
//!
//! Design: `docs/design/public-abi.md` §6 and §9.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const app = @import("app");

const host_mod = @import("host.zig");
const types = @import("types.zig");

const ContentId = types.ContentId;
const Cursor = types.Cursor;
const LogRecord = types.LogRecord;
const MemoryCounter = types.MemoryCounter;
const MemoryStats = types.MemoryStats;
const Mod = types.Mod;
const Result = types.Result;
const Str = types.Str;

/// A mod's own log lines. One scope for all of them today; the mod's name joins the line at
/// step 6, when `abi` learns what a loaded mod is and `self` has something to resolve
/// against.
const mod_log = core.log.scoped(.mod);

/// The longest line a mod may write in one call.
///
/// Refused rather than truncated, because a mod that can split a message is better served by
/// being told than by discovering half of one in the console.
pub const max_log_message: u64 = 4096;

pub fn Of(comptime H: type) type {
    return struct {
        // -- Results -------------------------------------------------------------------

        /// The name of a result code, or the empty string for one this build never issued.
        ///
        /// Takes `i32` rather than `Result`: the argument comes from a mod, and a Zig enum
        /// holding a value the enum does not have is illegal before any check could run.
        /// Needs no host at all, which is deliberate — a mod that cannot find the engine
        /// still has to be able to say so legibly.
        pub fn resultName(result: i32) callconv(.c) Str {
            const known = Result.fromCode(result) orelse return .empty;
            return .from(known.name());
        }

        // -- Logging -------------------------------------------------------------------

        /// Writes one line to the engine's log.
        ///
        /// Available with no subsystems bound, for the same reason `result_name` is: this is
        /// what a mod refusing itself uses to explain why.
        pub fn logWrite(self: Mod, level: i32, message: Str) callconv(.c) Result {
            _ = self;
            const severity = types.LogLevel.fromCode(level) orelse return .invalid_argument;
            if (message.len > max_log_message) return .limit;
            const text = message.utf8() orelse return .invalid_argument;
            // A line with nothing in it is a mistake rather than a message, and refusing it
            // costs a mod nothing it wanted.
            if (text.len == 0) return .invalid_argument;

            switch (severity) {
                .err => mod_log.err("{s}", .{text}),
                .warn => mod_log.warn("{s}", .{text}),
                .info => mod_log.info("{s}", .{text}),
                .debug => mod_log.debug("{s}", .{text}),
                .trace => mod_log.trace("{s}", .{text}),
            }
            return .ok;
        }

        /// Walks the in-memory log ring, oldest first.
        ///
        /// The text is copied into the engine's frame arena, because the ring is free to
        /// overwrite its own storage the moment its lock is released — so the copy is what
        /// makes the borrow rule true here, and the frame arena is what makes it cost
        /// nothing to release.
        ///
        /// A ring drops its oldest lines, so a walk that pauses can miss some. `sequence` is
        /// monotonic and is how a reader tells; there is no generation to compare against,
        /// because the thing being walked is defined by forgetting.
        pub fn logNext(cursor: ?*Cursor, out: ?*LogRecord) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            if (c.generation() > 1) return .invalid_argument;

            var one: [1]app.LogRecord = undefined;
            const view = app.log_sink.readView(engine.frameAllocator(), &one, .{}, c.index()) catch |err| {
                return Result.fromError(err);
            };
            if (view.records.len == 0) return .end;

            const record = view.records[0];
            dst.* = .{
                .level = logLevelOf(record.level),
                .frame = record.frame,
                .sequence = record.sequence,
                .scope = .from(record.scope),
                .text = .from(record.text),
            };
            c.* = .at(1, c.index() +| 1);
            return .ok;
        }

        // -- Content identity ----------------------------------------------------------

        /// Hashes a `namespace:name`, validating its shape first.
        ///
        /// The header carries `foundry_content_id`, which hashes without validating, so that
        /// external tooling can compute an id without linking Foundry. This is the checked
        /// form: a string this refuses is one the content compiler would have refused too,
        /// which is the only useful definition of "valid" here.
        pub fn idFromString(text: Str, out: ?*ContentId) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const bytes = text.utf8() orelse return .invalid_argument;
            const id = data.contentId(bytes) catch return .invalid_argument;
            dst.* = id;
            return .ok;
        }

        /// The spelling of an id, borrowed from whichever package supplied it.
        ///
        /// A hash cannot be reversed, so this is a lookup and not a computation: an id
        /// nothing loaded carries has no name to give and answers `not_found`.
        pub fn idToString(id: ContentId, out: ?*Str) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            const name = spellingOf(engine, id) orelse return .not_found;
            dst.* = .from(name);
            return .ok;
        }

        /// The same spelling, copied into the caller's buffer.
        ///
        /// One of exactly two calls in `_v1` that copy rather than borrow, and the reason is
        /// the borrow rule: a name a mod wants to keep past the call has to be its own.
        /// `needed` is written whether or not it fitted, so `capacity` 0 with a null buffer
        /// is how a caller asks for the length; a buffer too small is `limit` rather than a
        /// truncated name, because a silently shortened identifier is a bug nobody can see.
        pub fn idCopyString(id: ContentId, buffer: ?[*]u8, capacity: u64, needed: ?*u64) callconv(.c) Result {
            const length = needed orelse return .invalid_argument;
            if (capacity > 0 and buffer == null) return .invalid_argument;
            if (capacity > Str.max_bytes) return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            const name = spellingOf(engine, id) orelse return .not_found;
            length.* = name.len;
            if (name.len > capacity) return .limit;
            if (name.len != 0) @memcpy(buffer.?[0..name.len], name);
            return .ok;
        }

        // -- The frame -----------------------------------------------------------------

        pub fn frameIndex(out: ?*u64) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            dst.* = engine.frame_index;
            return .ok;
        }

        /// Wall-clock length of the previous frame. Presentation only: a mod that integrates
        /// motion against this has made its behaviour depend on how fast the machine is,
        /// which is what the fixed timestep exists to prevent (I9).
        pub fn frameDeltaNs(out: ?*u64) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            dst.* = nanoseconds(engine.frameDelta());
            return .ok;
        }

        /// Total simulated time, which is an exact multiple of the tick and therefore the
        /// same number on every machine that ran the same ticks.
        pub fn elapsedNs(out: ?*u64) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            dst.* = nanoseconds(engine.elapsed());
            return .ok;
        }

        /// The exact length of one simulation step.
        ///
        /// Nanoseconds rather than a rate in hertz, and that is not a preference: the
        /// engine's timestep is an exact rational — `numerator / denominator` seconds — so a
        /// rate rounded to an integer would not reproduce it, and a mod that recomputed the
        /// step from a rounded rate would drift away from the simulation it is part of.
        pub fn tickDeltaNs(out: ?*u64) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            dst.* = nanoseconds(engine.step_delta);
            return .ok;
        }

        // -- The profiler --------------------------------------------------------------

        /// Opens a named span, so a mod's own work appears in the profiler beside the
        /// engine's.
        ///
        /// The recorder copies the name, so nothing is borrowed past this call. Opening
        /// while the profiler is off, or outside a frame, is a no-op down there — but the
        /// depth is still counted here, because `scope_end`'s refusal has to be symmetric
        /// whether or not anyone is recording.
        pub fn scopeBegin(name: Str) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            const text = name.utf8() orelse return .invalid_argument;
            if (text.len == 0) return .invalid_argument;
            if (h.scope_depth == host_mod.max_scope_depth) return .limit;

            _ = engine.beginScope(text);
            h.scope_depth += 1;
            return .ok;
        }

        /// Closes the innermost span *this boundary* opened.
        ///
        /// The count is the boundary's own rather than the recorder's, and that is what the
        /// count is for: the recorder cannot tell a mod's span from the engine's, so a mod
        /// with an unbalanced `scope_end` would otherwise close the frame's own skeleton and
        /// produce a profile nobody could read.
        pub fn scopeEnd() callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            if (h.scope_depth == 0) return .refused;

            engine.endScope();
            h.scope_depth -= 1;
            return .ok;
        }

        // -- Memory --------------------------------------------------------------------

        /// Opens a named counter in the engine's memory report.
        ///
        /// The ABI cannot wrap a mod's allocator — a native mod allocates however its own
        /// language does — so a mod that wants to be visible reports its own numbers. That
        /// is the same bargain the engine already makes with a game: it does not wrap the
        /// allocator it was handed either, and counting it is the caller's choice to make
        /// and the caller's to name.
        pub fn memoryCounterOpen(self: Mod, name: Str, out: ?*MemoryCounter) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const text = name.utf8() orelse return .invalid_argument;

            const handle = h.openCounter(self, text) catch |err| return switch (err) {
                error.Limit => .limit,
                error.Unavailable => .unavailable,
                error.OutOfMemory => .out_of_memory,
            };
            dst.* = handle;
            return .ok;
        }

        /// Publishes a mod's numbers into a counter it opened.
        pub fn memoryCounterSet(counter: MemoryCounter, stats: ?*const MemoryStats) callconv(.c) Result {
            const values = stats orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            // The engine is checked before the handle even though the counter is the host's,
            // because a counter only exists because an engine accepted its registration: on
            // a host with no engine there is nothing a handle here could ever have named,
            // and `invalid_handle` would send its author looking for a stale handle.
            _ = h.engine orelse return .unavailable;
            const entry = h.counter(counter) orelse return .invalid_handle;

            entry.counted.live_bytes = std.math.cast(usize, values.live_bytes) orelse return .invalid_argument;
            entry.counted.peak_bytes = std.math.cast(usize, values.peak_bytes) orelse return .invalid_argument;
            entry.counted.allocations = values.allocations;
            entry.counted.frees = values.frees;
            entry.counted.failures = values.failures;
            return .ok;
        }

        // -- internals -----------------------------------------------------------------

        /// The spelling of an id, from whatever loaded content carries one.
        ///
        /// Records first, then packages. Schemas are absent from this list because a schema
        /// keeps no spelling at runtime — `data.Schema` is an id, a version and its fields —
        /// which is the same shape the `mod` module's dependency diagnostics ran into and is
        /// recorded for the same reason: an `id` is eight bytes, working as designed.
        fn spellingOf(engine: anytype, id: ContentId) ?[]const u8 {
            if (id.isNone()) return null;
            if (engine.store.lookup(id)) |record| return record.name;
            if (engine.store.findPackage(id)) |handle| {
                if (engine.store.package(handle)) |loaded| return loaded.name;
            }
            return null;
        }
    };
}

/// `std.log.Level` — which is what the ring stores — as the number that crosses.
fn logLevelOf(level: std.log.Level) types.LogLevel {
    return switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
}

/// A duration as unsigned nanoseconds. A negative one is not a value the engine produces,
/// and saturating rather than wrapping means a clock that went backwards reports zero
/// instead of a number near 2^64.
fn nanoseconds(duration: core.time.Duration) u64 {
    if (duration.ns <= 0) return 0;
    return @intCast(duration.ns);
}

// == Tests =============================================================================
//
// The table-wide properties — nothing crashes on garbage, an absent subsystem answers
// `unavailable` — are `sweep.zig`, which walks `Api_v1`'s fields so that a capability added
// without a refusal path fails rather than ships. What is here is the other half: what each
// call actually *answers* when it works.

const test_engine = @import("test_engine.zig");
const api = @import("api.zig");

const testing = std.testing;

const TestEngine = test_engine.TestEngine;
const Host = host_mod.HostOf(TestEngine);
const table = api.TableOf(Host).v1;

const package_source =
    \\@schema item { name string  weight f32 (default 1.0) }
    \\item mymod:item.lantern { name "Lantern"  weight 0.75 }
;

/// An engine, a host, and the binding, torn down in the right order.
const Fixture = struct {
    engine: TestEngine,
    host: Host,

    fn init() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        self.* = .{ .engine = try .init(testing.allocator), .host = .{} };
        self.engine.settle();
        self.host.engine = &self.engine;
        self.host.bind();
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.host.unbind();
        self.engine.deinit();
        testing.allocator.destroy(self);
    }
};

test "a result names itself, and an invented code names nothing" {
    try testing.expectEqualStrings("FOUNDRY_OK", table.result_name(0).bytes().?);
    try testing.expectEqualStrings("FOUNDRY_END", table.result_name(1).bytes().?);
    try testing.expectEqualStrings("FOUNDRY_ERR_NOT_FOUND", table.result_name(-3).bytes().?);

    // An empty answer rather than an invented one: a mod may pass any `int32_t` at all.
    try testing.expectEqual(@as(u64, 0), table.result_name(2).len);
    try testing.expectEqual(@as(u64, 0), table.result_name(std.math.minInt(i32)).len);
}

test "a mod writes a log line at every level it is allowed to" {
    const f = try Fixture.init();
    defer f.deinit();

    // Every level except `err`, which is excluded for the reason `core/log.zig` already
    // gives: Zig's test runner fails a test that logs one, and that rule is correct.
    try testing.expectEqual(Result.ok, table.log_write(.none, 1, .from("a warning")));
    try testing.expectEqual(Result.ok, table.log_write(.none, 2, .from("something happened")));
    try testing.expectEqual(Result.ok, table.log_write(.none, 3, .from("detail")));
    try testing.expectEqual(Result.ok, table.log_write(.none, 4, .from("very fine detail")));
}

test "a log line that is not one is refused rather than written" {
    const f = try Fixture.init();
    defer f.deinit();

    // A level this build does not publish.
    try testing.expectEqual(Result.invalid_argument, table.log_write(.none, 5, .from("x")));
    try testing.expectEqual(Result.invalid_argument, table.log_write(.none, -1, .from("x")));

    // Bytes that are not UTF-8, and a message with nothing in it.
    const invalid = [_]u8{ 'a', 0xff };
    try testing.expectEqual(Result.invalid_argument, table.log_write(.none, 2, .from(&invalid)));
    try testing.expectEqual(Result.invalid_argument, table.log_write(.none, 2, .empty));

    // A length nothing could own, and one that is merely absurd. Neither is dereferenced.
    try testing.expectEqual(Result.limit, table.log_write(.none, 2, .{
        .ptr = @ptrFromInt(0x1000),
        .len = max_log_message + 1,
    }));
    try testing.expectEqual(Result.limit, table.log_write(.none, 2, .{
        .ptr = null,
        .len = std.math.maxInt(u64),
    }));
}

test "a mod walks the log ring and reaches the end of it" {
    const f = try Fixture.init();
    defer f.deinit();

    // Seeded through the sink directly rather than through `log_write`, and the reason is a
    // fact about test binaries rather than about this code: `std.log` reaches `log_sink`
    // only when a *root* source file installs it, and in a test binary the root is the test
    // runner. So `log_write` here goes to the runner's own handler — which is what makes an
    // `err` line a failed test, and is worth keeping. What this test is for is the walk.
    const previous = app.log_sink.captureLevel();
    defer app.log_sink.setCaptureLevel(if (previous) |_| .trace else null);
    app.log_sink.setCaptureLevel(.trace);
    app.log_sink.clear();
    defer app.log_sink.clear();

    app.log_sink.logFn(.info, .mod, "{s}", .{"first"});
    app.log_sink.logFn(.info, .mod, "{s}", .{"second"});

    var cursor: Cursor = .begin;
    var record: LogRecord = .{};

    try testing.expectEqual(Result.ok, table.log_next(&cursor, &record));
    try testing.expectEqualStrings("first", record.text.bytes().?);
    try testing.expectEqualStrings("mod", record.scope.bytes().?);
    try testing.expectEqual(types.LogLevel.info, record.level);
    try testing.expect(record.sequence != 0);
    try testing.expect(!cursor.isBegin());

    const first_sequence = record.sequence;
    try testing.expectEqual(Result.ok, table.log_next(&cursor, &record));
    try testing.expectEqualStrings("second", record.text.bytes().?);
    try testing.expectEqual(first_sequence + 1, record.sequence);

    // The end of a walk is not an error, which is what makes the `while` loop in the header
    // correct without a special case.
    try testing.expectEqual(Result.end, table.log_next(&cursor, &record));
    try testing.expect(!Result.end.isError());
}

test "a cursor from a walk the boundary never issued is refused" {
    const f = try Fixture.init();
    defer f.deinit();

    var cursor: Cursor = .at(7, 0);
    var record: LogRecord = .{};
    try testing.expectEqual(Result.invalid_argument, table.log_next(&cursor, &record));
}

test "an id is hashed only if it is one" {
    const f = try Fixture.init();
    defer f.deinit();

    var id: ContentId = .none;
    try testing.expectEqual(Result.ok, table.id_from_string(.from("mymod:item.lantern"), &id));
    try testing.expectEqual(core.ContentId.fromString("mymod:item.lantern").hash, id.hash);

    // Everything `data` refuses, refused here — the same validation the content compiler
    // applies, so a string this refuses would never have compiled either.
    for ([_][]const u8{ "", "lantern", "MyMod:lantern", "mymod:", ":lantern", "mymod:a:b", "mymod:1st" }) |bad| {
        var out: ContentId = .none;
        try testing.expectEqual(Result.invalid_argument, table.id_from_string(.from(bad), &out));
        // Untouched, because an out-parameter is written only on success.
        try testing.expect(out.isNone());
    }
}

test "an id spells itself back, from the package that supplied it" {
    const f = try Fixture.init();
    defer f.deinit();
    _ = try f.engine.loadPackage("mymod:content", package_source);

    var text: Str = .empty;
    const record_id = core.ContentId.fromString("mymod:item.lantern");
    try testing.expectEqual(Result.ok, table.id_to_string(record_id, &text));
    try testing.expectEqualStrings("mymod:item.lantern", text.bytes().?);

    // A package spells itself too, which is what makes a load-order diagnostic readable.
    try testing.expectEqual(Result.ok, table.id_to_string(core.ContentId.fromString("mymod:content"), &text));
    try testing.expectEqualStrings("mymod:content", text.bytes().?);

    // A hash cannot be reversed, so an id nothing loaded carries has no name to give.
    try testing.expectEqual(Result.not_found, table.id_to_string(core.ContentId.fromString("mymod:absent"), &text));
    try testing.expectEqual(Result.not_found, table.id_to_string(.none, &text));
}

test "a copied id reports the length it needed rather than truncating" {
    const f = try Fixture.init();
    defer f.deinit();
    _ = try f.engine.loadPackage("mymod:content", package_source);

    const id = core.ContentId.fromString("mymod:item.lantern");
    var buffer: [64]u8 = undefined;
    var needed: u64 = 0;

    try testing.expectEqual(Result.ok, table.id_copy_string(id, &buffer, buffer.len, &needed));
    try testing.expectEqual(@as(u64, "mymod:item.lantern".len), needed);
    try testing.expectEqualStrings("mymod:item.lantern", buffer[0..needed]);

    // Asking for the length alone: no buffer, no capacity, and the answer anyway.
    needed = 0;
    try testing.expectEqual(Result.limit, table.id_copy_string(id, null, 0, &needed));
    try testing.expectEqual(@as(u64, "mymod:item.lantern".len), needed);

    // A buffer one byte short is a refusal, not a shortened name.
    needed = 0;
    try testing.expectEqual(Result.limit, table.id_copy_string(id, &buffer, "mymod:item.lantern".len - 1, &needed));
    try testing.expectEqual(@as(u64, "mymod:item.lantern".len), needed);

    // A capacity with nothing behind it is refused before anything is written to it.
    try testing.expectEqual(Result.invalid_argument, table.id_copy_string(id, null, 32, &needed));
}

test "the frame answers what the engine knows about it" {
    const f = try Fixture.init();
    defer f.deinit();

    f.engine.frame_index = 42;
    f.engine.frame_delta = .{ .ns = 16_000_000 };
    f.engine.total_elapsed = .{ .ns = 700_000_000 };
    f.engine.step_delta = .{ .ns = 16_666_666 };

    var value: u64 = 0;
    try testing.expectEqual(Result.ok, table.frame_index(&value));
    try testing.expectEqual(@as(u64, 42), value);

    try testing.expectEqual(Result.ok, table.frame_delta_ns(&value));
    try testing.expectEqual(@as(u64, 16_000_000), value);

    try testing.expectEqual(Result.ok, table.elapsed_ns(&value));
    try testing.expectEqual(@as(u64, 700_000_000), value);

    try testing.expectEqual(Result.ok, table.tick_delta_ns(&value));
    try testing.expectEqual(@as(u64, 16_666_666), value);

    // A clock that went backwards reports zero rather than a number near 2^64, which is what
    // an unsigned nanosecond count would otherwise make of a negative duration.
    f.engine.frame_delta = .{ .ns = -5 };
    try testing.expectEqual(Result.ok, table.frame_delta_ns(&value));
    try testing.expectEqual(@as(u64, 0), value);
}

test "a mod's spans nest, and it cannot close one it did not open" {
    const f = try Fixture.init();
    defer f.deinit();

    try testing.expectEqual(Result.refused, table.scope_end());

    try testing.expectEqual(Result.ok, table.scope_begin(.from("mymod:think")));
    try testing.expectEqual(Result.ok, table.scope_begin(.from("mymod:think.inner")));
    try testing.expectEqual(@as(u32, 2), f.engine.open_scopes);
    try testing.expectEqualStrings("mymod:think.inner", f.engine.scope_names.items[1]);

    try testing.expectEqual(Result.ok, table.scope_end());
    try testing.expectEqual(Result.ok, table.scope_end());
    try testing.expectEqual(@as(u32, 0), f.engine.open_scopes);

    // One close too many stops at the boundary. The recorder cannot tell a mod's span from
    // the engine's, so a mod that miscounted would otherwise close the frame's own skeleton.
    try testing.expectEqual(Result.refused, table.scope_end());
    try testing.expectEqual(@as(u32, 0), f.engine.open_scopes);
}

test "a span with no name is refused, and so is one nested past the bound" {
    const f = try Fixture.init();
    defer f.deinit();

    try testing.expectEqual(Result.invalid_argument, table.scope_begin(.empty));
    const invalid = [_]u8{ 'a', 0x80 };
    try testing.expectEqual(Result.invalid_argument, table.scope_begin(.from(&invalid)));

    for (0..host_mod.max_scope_depth) |_| {
        try testing.expectEqual(Result.ok, table.scope_begin(.from("deep")));
    }
    try testing.expectEqual(Result.limit, table.scope_begin(.from("deeper")));
    for (0..host_mod.max_scope_depth) |_| {
        try testing.expectEqual(Result.ok, table.scope_end());
    }
}

test "a mod's memory counter reaches the engine's report" {
    const f = try Fixture.init();
    defer f.deinit();

    var counter: types.MemoryCounter = .none;
    try testing.expectEqual(Result.ok, table.memory_counter_open(.none, .from("mymod"), &counter));
    try testing.expect(!counter.isNone());
    try testing.expectEqual(@as(u32, 1), f.engine.registeredCount());

    const stats: MemoryStats = .{
        .live_bytes = 4096,
        .peak_bytes = 8192,
        .allocations = 12,
        .frees = 9,
        .failures = 1,
    };
    try testing.expectEqual(Result.ok, table.memory_counter_set(counter, &stats));

    const reported = f.engine.counterNamed("mymod") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 4096), reported.live_bytes);
    try testing.expectEqual(@as(usize, 8192), reported.peak_bytes);
    try testing.expectEqual(@as(u64, 12), reported.allocations);
    try testing.expectEqual(@as(u64, 9), reported.frees);
    try testing.expectEqual(@as(u64, 1), reported.failures);
}

test "a counter handle nobody issued resolves to nothing" {
    const f = try Fixture.init();
    defer f.deinit();

    const stats: MemoryStats = .{};
    try testing.expectEqual(Result.invalid_handle, table.memory_counter_set(.{ .bits = 1 }, &stats));
    try testing.expectEqual(Result.invalid_handle, table.memory_counter_set(.none, &stats));
    try testing.expectEqual(
        Result.invalid_handle,
        table.memory_counter_set(.{ .bits = std.math.maxInt(u64) }, &stats),
    );
}

test "a name too long for a counter is refused, and so is the counter after the last" {
    const f = try Fixture.init();
    defer f.deinit();

    var counter: types.MemoryCounter = .none;
    const long: [host_mod.max_counter_name + 1]u8 = @splat('n');
    try testing.expectEqual(Result.limit, table.memory_counter_open(.none, .from(&long), &counter));
    try testing.expectEqual(Result.limit, table.memory_counter_open(.none, .empty, &counter));

    for (0..host_mod.max_counters) |_| {
        try testing.expectEqual(Result.ok, table.memory_counter_open(.none, .from("mymod"), &counter));
    }
    try testing.expectEqual(Result.limit, table.memory_counter_open(.none, .from("mymod"), &counter));
}

test "unbinding hands back everything the boundary registered" {
    var engine: TestEngine = try .init(testing.allocator);
    defer engine.deinit();
    engine.settle();

    var host: Host = .{ .engine = &engine };
    host.bind();

    var counter: types.MemoryCounter = .none;
    try testing.expectEqual(Result.ok, table.memory_counter_open(.none, .from("mymod"), &counter));
    try testing.expectEqual(@as(u32, 1), engine.registeredCount());

    // The engine holds a pointer into the host's own storage, so a host that went away
    // without taking its counters with it would leave exactly the dangling pointer this
    // whole module exists to make impossible.
    host.unbind();
    try testing.expectEqual(@as(u32, 0), engine.registeredCount());
}
