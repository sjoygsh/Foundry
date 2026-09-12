//! A session's local evidence: what happened, kept where the person it happened to can find it.
//!
//! **This is not crash recovery.** A native crash is not a Lua fault and is not contained
//! like one: nothing here catches a signal, resumes a simulation, or tries to tear down or
//! save a world through state that may already be wrong. macOS writes a crash report and
//! Step 7 keeps the symbols that make it readable; what this adds is the log that was
//! already on disk when the process died, and the record of whether the last session closed
//! cleanly (`distribution.md` §10).
//!
//! **Opt-in, and started before everything.** A session opens before settings, before
//! discovery and before the engine, because the failures worth keeping evidence of are
//! exactly the ones that happen before there is an engine to ask.
//!
//! ## Why a second capture
//!
//! `log_sink`'s ring belongs to the overlay: a game filters it, clears it and usually leaves
//! it off. A release log that shared it would be a release log a closed console could empty.
//! So the capture this drains is its own buffer with its own level, and the only things the
//! two share are one lock and one formatting pass.
//!
//! ## What it does not collect
//!
//! No environment dump, no user name, no home path written deliberately, no source text, no
//! saves, no credentials, and nothing is ever uploaded. Subsystem messages can still name a
//! file a player chose, so the shipping guide asks a person to read a log before sending it
//! rather than promising redaction nobody can guarantee.
//!
//! Design: `docs/design/distribution.md` §10.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");

const log_sink = @import("log_sink.zig");

const Allocator = std.mem.Allocator;
const Os = platform.os.Os;

const log = core.log.scoped(.diagnostics);

/// Where sessions live, under the application's user-data directory.
pub const dir_name = "logs";

/// How many sessions are kept: one active and four previous (§10).
pub const slot_count = 5;

/// The log envelope's version. A reader that does not recognise it must not guess (I8).
pub const envelope_version: u32 = 1;

/// What is appended when the cap is reached, and nothing more is.
pub const truncation_marker = "-- truncated: this session reached its size cap --\n";

pub const Limits = struct {
    /// How large one session's log may grow.
    max_file_bytes: u64 = 1 << 20,
    /// The most verbose level kept in the file. `info` rather than `debug`: a release log
    /// is read by someone who was not there, and a debug-level log of a real session is
    /// mostly noise with the evidence buried in it.
    level: core.log.Level = .info,
    /// How recently another slot's log may have been written and still be treated as
    /// somebody's. A session that cannot claim a free slot retires the least recently
    /// active one, and this is what stops it retiring a slot that is live (§10).
    active_within_ns: i64 = 60 * std.time.ns_per_s,
    /// A bound on the marker, which is a handful of short lines.
    max_marker_bytes: usize = 4 << 10,
};

/// What a build is, for the log's header.
///
/// Supplied by the application rather than read from anywhere: the engine's ABI version is
/// not a product version (§4), and a header that guessed would be a header that is wrong on
/// the one build somebody asks about.
pub const Build = struct {
    application: []const u8,
    version: []const u8,
    /// The source revision, or `local`. Never inferred — the build runs no `git`.
    revision: []const u8 = "local",
    target: []const u8,
    platform_backend: []const u8,
    rhi_backend: []const u8,
    optimize: []const u8,
};

/// One loaded package, in resolved order. A copy of what the host already knows: `app` has
/// no `mod` and is not about to grow one for a header line.
pub const Package = struct {
    id: []const u8,
    version: u32,
};

/// How far a session got. Recorded in the marker, so an unclean one says where it stopped.
pub const Stage = enum {
    /// Open, and nothing else has happened yet.
    start,
    /// Reading settings, discovering and resolving packages.
    discovery,
    /// Creating the engine and loading content.
    startup,
    /// The frame loop.
    running,
    /// Normal teardown.
    shutdown,
};

/// How a session ended, as its marker records it.
pub const Outcome = enum {
    /// Still running, or the process died without saying otherwise.
    open,
    /// Finished normally.
    clean,
    /// Finished on a named failure. The log says which.
    failed,
};

pub const Options = struct {
    /// Whether this run may write anything at all.
    ///
    /// **Off for a frame-budgeted or headless run**, which is the same rule preferences
    /// follow and for the same reason: a scripted run that wrote to the machine running it
    /// would make the bar depend on what is on that machine (I9, §4). A session that keeps
    /// nothing still has stages and still ends — the only difference is where it goes.
    enabled: bool = true,
    limits: Limits = .{},
};

/// A session: one slot, one log, one marker.
///
/// Heap-allocated because it owns a 64 KiB drain buffer and a stable address for the whole
/// run, exactly as `platform.Os` does.
pub const Session = struct {
    gpa: Allocator,
    os: *Os,
    limits: Limits,

    /// The absolute `logs` directory, or empty when there is nowhere to write.
    dir: []u8 = &.{},
    slot: u8 = 0,
    file: ?platform.os.AppendFile = null,
    /// `session-N.log`, owned.
    log_name: []u8 = &.{},
    /// `session-N.marker`, owned.
    marker_name: []u8 = &.{},

    stage: Stage = .start,
    /// Set once the cap is reached; nothing more is appended after the marker.
    capped: bool = false,
    /// Set when a write failed. The sink is disabled exactly once and the terminal and the
    /// overlay's ring go on working (§10).
    failed_sink: bool = false,
    /// The drain buffer. Sized to the capture, so a drain always empties it.
    buffer: []u8 = &.{},

    pub const OpenError = error{OutOfMemory};

    /// Opens a session. **Never fails because of the filesystem.**
    ///
    /// A game that would not start because a log file could not be opened would be a game
    /// whose diagnostics are worse than none. Every filesystem problem below leaves the
    /// session alive with no file, and the terminal keeps working.
    pub fn open(gpa: Allocator, os: *Os, build: Build, options: Options) OpenError!*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .os = os, .limits = options.limits };

        self.buffer = try gpa.alloc(u8, log_sink.session_capacity);
        errdefer gpa.free(self.buffer);

        // From here on nothing is fatal. A session with no file still carries the stage, and
        // the terminal still carries the lines.
        log_sink.resetSession();
        if (!options.enabled) return self;
        self.openDir() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("no local log this session: {t}", .{err});
                return self;
            },
        };
        self.claim() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("no local log this session: no free slot in '{s}' ({t})", .{ dir_name, err });
                return self;
            },
        };

        self.writeHeader(build);
        log_sink.setSessionLevel(options.limits.level);
        self.reportAbandoned();
        return self;
    }

    /// Closes the session, recording how it ended.
    ///
    /// Drains once more first, because the lines describing a failure are logged immediately
    /// before this is called and would otherwise be exactly the ones lost.
    pub fn finish(self: *Session, outcome: Outcome) void {
        self.drain();
        log_sink.setSessionLevel(null);
        self.writeMarker(outcome);
        if (self.file) |*file| {
            file.sync() catch {};
            file.close();
            self.file = null;
        }
    }

    pub fn deinit(self: *Session) void {
        if (self.file) |*file| {
            // A session destroyed without `finish` leaves its marker saying `open`, which is
            // the truthful answer: nobody said it ended.
            file.sync() catch {};
            file.close();
        }
        log_sink.setSessionLevel(null);
        self.gpa.free(self.buffer);
        self.gpa.free(self.dir);
        self.gpa.free(self.log_name);
        self.gpa.free(self.marker_name);
        self.gpa.destroy(self);
    }

    /// Records how far the session has got.
    ///
    /// **The marker is rewritten here, not only at the end**, which is the whole reason it
    /// is useful: a session that never reaches `finish` is exactly the one somebody needs
    /// the stage of, and a marker written only at the end would say `start` for every crash
    /// (§10). It is a handful of short lines through `replaceFileConfined`, five times in a
    /// session, so the cost is nothing and the alternative answers nothing.
    pub fn setStage(self: *Session, stage: Stage) void {
        self.stage = stage;
        self.drain();
        self.writeMarker(.open);
    }

    /// Writes the resolved load order into the header's tail.
    ///
    /// Not at `open`, because packages are not known then: a session starts before discovery
    /// precisely so that a discovery failure has somewhere to be recorded.
    pub fn notePackages(self: *Session, packages: []const Package) void {
        if (self.file == null) return;
        var line: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line);
        writer.print("packages {d}\n", .{packages.len}) catch {};
        self.append(writer.buffered());
        for (packages) |package| {
            writer = .fixed(&line);
            writer.print("  {s} {d}\n", .{ package.id, package.version }) catch {};
            self.append(writer.buffered());
        }
    }

    /// Moves whatever the capture holds into the file. Called at least once per frame.
    pub fn drain(self: *Session) void {
        const got = log_sink.drainSession(self.buffer);
        if (self.file == null or got.len == 0) return;
        self.append(self.buffer[0..got.len]);
    }

    /// Where this session's log is, for a message telling a person where to look.
    pub fn logPath(self: *const Session) ?[]const u8 {
        if (self.file == null) return null;
        return self.log_name;
    }

    pub fn directory(self: *const Session) ?[]const u8 {
        return if (self.dir.len == 0) null else self.dir;
    }

    // -- the parts nothing outside calls ------------------------------------------------

    fn openDir(self: *Session) (platform.os.PathError || platform.os.FileError)!void {
        const data = try self.os.userDataDirAlloc(self.gpa);
        defer self.gpa.free(data);
        self.dir = try platform.os.joinPath(self.gpa, &.{ data, dir_name });
        errdefer {
            self.gpa.free(self.dir);
            self.dir = &.{};
        }
        try self.os.createDirPath(self.dir);
    }

    /// Takes a slot, by exclusive creation.
    ///
    /// **Exclusive creation is the whole of the concurrency story.** Two processes racing
    /// for one name cannot both win, so the loser moves to the next name rather than sharing
    /// a file, and a symlink planted at a name is refused rather than followed — both
    /// without a lock, and both on every system Foundry targets (§10).
    fn claim(self: *Session) (Allocator.Error || platform.os.FileError)!void {
        var slot: u8 = 1;
        while (slot <= slot_count) : (slot += 1) {
            if (try self.tryClaim(slot)) return;
        }

        // Every slot is taken. Retire the least recently active one — but never one that was
        // written recently, because that is somebody else's session and this is precisely
        // the case §10 says must not be mistaken for a dead one.
        const now = self.os.wallClockNanos();
        var attempts: u8 = 0;
        while (attempts < slot_count) : (attempts += 1) {
            const oldest = self.leastRecent() orelse return error.AccessDenied;
            if (now -| oldest.modified_ns < self.limits.active_within_ns) return error.AccessDenied;

            var name: [32]u8 = undefined;
            self.os.deleteFileConfined(self.dir, slotName(&name, oldest.slot, ".log")) catch {};
            self.os.deleteFileConfined(self.dir, slotName(&name, oldest.slot, ".marker")) catch {};
            // A race here loses the create and tries the next candidate, which is what
            // "retention races must fail harmlessly" asks for.
            if (try self.tryClaim(oldest.slot)) return;
        }
        return error.AccessDenied;
    }

    fn tryClaim(self: *Session, slot: u8) (Allocator.Error || platform.os.FileError)!bool {
        var name: [32]u8 = undefined;
        const log_name = slotName(&name, slot, ".log");
        // Taken, by a live session or a previous one — or unreachable for some other
        // reason. Either way it is not this session's to touch, and the next name is tried.
        const file = self.os.createAppendConfined(self.dir, log_name) catch return false;

        self.slot = slot;
        self.file = file;
        self.log_name = try self.gpa.dupe(u8, log_name);
        errdefer {
            self.gpa.free(self.log_name);
            self.log_name = &.{};
        }
        var marker: [32]u8 = undefined;
        self.marker_name = try self.gpa.dupe(u8, slotName(&marker, slot, ".marker"));
        return true;
    }

    const Candidate = struct { slot: u8, modified_ns: i64 };

    fn leastRecent(self: *Session) ?Candidate {
        var found: ?Candidate = null;
        var slot: u8 = 1;
        while (slot <= slot_count) : (slot += 1) {
            var name: [32]u8 = undefined;
            const info = self.os.statFileConfined(self.dir, slotName(&name, slot, ".log")) catch continue;
            if (found == null or info.modified_ns < found.?.modified_ns) {
                found = .{ .slot = slot, .modified_ns = info.modified_ns };
            }
        }
        return found;
    }

    fn writeHeader(self: *Session, build: Build) void {
        var line: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line);
        writer.print(
            \\foundry-log {d}
            \\application {s} {s}
            \\revision {s}
            \\target {s}
            \\backend {s}/{s}
            \\optimize {s}
            \\slot {d} of {d}
            \\
        , .{
            envelope_version,
            build.application,
            build.version,
            build.revision,
            build.target,
            build.platform_backend,
            build.rhi_backend,
            build.optimize,
            self.slot,
            slot_count,
        }) catch {};
        self.append(writer.buffered());
        self.writeMarker(.open);
        if (self.file) |*file| file.sync() catch {};
    }

    /// The marker: one session's answer to "did it close?".
    ///
    /// Written through `replaceFileConfined`, so it is never observed half-written and a
    /// symlink at its name is overwritten rather than followed (§6). An abandoned one means
    /// the session did not close cleanly — **not** that a crash was proven. A SIGKILL, a
    /// power loss and a machine that was simply switched off all leave the same mark.
    fn writeMarker(self: *Session, outcome: Outcome) void {
        if (self.marker_name.len == 0) return;
        var line: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line);
        writer.print("foundry-session {d}\nstate {t}\nstage {t}\n", .{
            envelope_version, outcome, self.stage,
        }) catch return;
        _ = self.os.replaceFileConfined(
            self.dir,
            self.marker_name,
            writer.buffered(),
            self.limits.max_marker_bytes,
        ) catch {};
    }

    /// Says which other slots hold a session that never said it finished.
    fn reportAbandoned(self: *Session) void {
        var slot: u8 = 1;
        while (slot <= slot_count) : (slot += 1) {
            if (slot == self.slot) continue;
            var name: [32]u8 = undefined;
            const read = self.os.readFileConfined(
                self.gpa,
                self.dir,
                slotName(&name, slot, ".marker"),
                self.limits.max_marker_bytes,
            ) catch continue;
            defer self.gpa.free(read.bytes);
            if (std.mem.indexOf(u8, read.bytes, "\nstate open\n") == null) continue;

            // Into the file directly as well as through the log. It is a fact about *this*
            // session's header — what it found when it started — and a header that depended
            // on whether the host had installed `app.std_options` would be a header missing
            // from exactly the builds nobody controls.
            var line: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&line);
            writer.print("previous-session slot {d} never said it finished\n", .{slot}) catch {};
            self.append(writer.buffered());
            log.warn(
                "a previous session in slot {d} never said it finished; it may have been killed, or it may still be running",
                .{slot},
            );
        }
    }

    /// Appends to the file, applying the cap and disabling the sink on a failure.
    fn append(self: *Session, bytes: []const u8) void {
        if (self.capped or bytes.len == 0 or self.file == null) return;
        // A pointer *into* the optional, not to a copy of it: `AppendFile` counts what it
        // has written and a copy would count on the caller's behalf and then be discarded.
        const file = &self.file.?;

        if (file.written + bytes.len > self.limits.max_file_bytes) {
            // Stop where the cap is rather than writing a partial line, and say so once. A
            // log that simply stopped would be indistinguishable from a process that did.
            self.capped = true;
            _ = file.append(truncation_marker) catch {};
            log_sink.setSessionLevel(null);
            return;
        }

        file.append(bytes) catch |err| {
            self.failSink(err);
            return;
        };
    }

    /// Turns the file sink off, once, and says why on the paths that still work.
    fn failSink(self: *Session, err: platform.os.FileError) void {
        if (self.failed_sink) return;
        self.failed_sink = true;

        // **Off before the message.** The report must not re-enter the sink that just failed,
        // and turning capture off is what makes that structural rather than a rule (§10).
        log_sink.setSessionLevel(null);
        if (self.file) |*file| {
            file.close();
            self.file = null;
        }
        log.warn("the local log could not be written ({t}); the terminal is unaffected", .{err});
    }
};

/// `session-<n><suffix>`, into a caller's buffer. No allocation: this is called from the
/// claim loop, where the answer lives for one comparison.
fn slotName(buffer: []u8, slot: u8, suffix: []const u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("session-{d}{s}", .{ slot, suffix }) catch unreachable;
    return writer.buffered();
}

// -- tests -------------------------------------------------------------------------------

const testing = std.testing;

/// A real user-data directory, on a real filesystem.
///
/// Real because everything this module does is filesystem behaviour: an exclusive create
/// that loses a race, a symlink that is refused, a marker that survives a process. A fake
/// would be a test of the fake.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    /// Held by the fixture, because `Os` borrows the environment it is given and the
    /// fixture is what has to outlive it.
    env: [3]platform.os.EnvVar = undefined,
    os: *Os = undefined,

    fn init() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);

        self.* = .{ .tmp = testing.tmpDir(.{}), .home = &.{} };
        errdefer self.tmp.cleanup();

        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(testing.io, &buf);
        self.home = try testing.allocator.dupe(u8, buf[0..len]);
        errdefer testing.allocator.free(self.home);

        // The three variables `userDataDirAlloc` reads, so the test is the same shape on
        // every system it runs on.
        self.env = .{
            .{ .name = "HOME", .value = self.home },
            .{ .name = "XDG_DATA_HOME", .value = self.home },
            .{ .name = "APPDATA", .value = self.home },
        };
        self.os = try Os.init(testing.allocator, .{ .app_name = "foundry-test", .env = &self.env });
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.os.deinit();
        testing.allocator.free(self.home);
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }
};

fn readIn(fx: *Fixture, dir: []const u8, name: []const u8) ![]u8 {
    const got = try fx.os.readFileConfined(testing.allocator, dir, name, 4 << 20);
    return got.bytes;
}

/// Logs the way a real build does.
///
/// **Not `log.info`.** In a test binary the root source file is the test runner, so
/// `std.log` is routed to std's default and never reaches this sink at all (AGENTS.md §4).
/// Calling the function `app.std_options` installs is the same path a game takes, and the
/// only one a test can take.
fn say(comptime format: []const u8, args: anytype) void {
    log_sink.logFn(.info, .diagnostics, format, args);
}

const test_build: Build = .{
    .application = "Test",
    .version = "1.0.0",
    .revision = "local",
    .target = "aarch64-macos",
    .platform_backend = "null",
    .rhi_backend = "null",
    .optimize = "Debug",
};

test "a session writes a header, the lines that follow it, and a marker saying it closed" {
    const fx = try Fixture.init();
    defer fx.deinit();

    const session = try Session.open(testing.allocator, fx.os, test_build, .{});
    defer session.deinit();
    try testing.expectEqualStrings("session-1.log", session.logPath().?);

    session.setStage(.discovery);
    session.notePackages(&.{ .{ .id = "foundry:core", .version = 1 }, .{ .id = "demo:pack", .version = 3 } });
    say("a line that belongs in the file", .{});
    session.setStage(.running);
    session.finish(.clean);

    const text = try readIn(fx, session.dir, "session-1.log");
    defer testing.allocator.free(text);

    // The envelope, which is what makes a log readable by someone who was not there.
    try testing.expect(std.mem.startsWith(u8, text, "foundry-log 1\n"));
    try testing.expect(std.mem.indexOf(u8, text, "application Test 1.0.0\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "revision local\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "backend null/null\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "packages 2\n  foundry:core 1\n  demo:pack 3\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "a line that belongs in the file") != null);

    const marker = try readIn(fx, session.dir, "session-1.marker");
    defer testing.allocator.free(marker);
    try testing.expect(std.mem.indexOf(u8, marker, "\nstate clean\n") != null);
    try testing.expect(std.mem.indexOf(u8, marker, "\nstage running\n") != null);
}

test "a session that never finishes leaves a marker saying so, and the next one reports it" {
    const fx = try Fixture.init();
    defer fx.deinit();

    // Destroyed without `finish`, which is what a killed process leaves behind.
    const abandoned = try Session.open(testing.allocator, fx.os, test_build, .{});
    const dir = try testing.allocator.dupe(u8, abandoned.dir);
    defer testing.allocator.free(dir);
    say("the last thing it managed to say", .{});
    abandoned.drain();
    abandoned.deinit();

    const marker = try readIn(fx, dir, "session-1.marker");
    defer testing.allocator.free(marker);
    try testing.expect(std.mem.indexOf(u8, marker, "\nstate open\n") != null);
    // And how far it got, which is what a marker written only at the end could never say.
    try testing.expect(std.mem.indexOf(u8, marker, "\nstage start\n") != null);

    // The next session takes the next slot — it does not touch somebody else's evidence —
    // and says what it found.
    const next = try Session.open(testing.allocator, fx.os, test_build, .{});
    defer next.deinit();
    try testing.expectEqualStrings("session-2.log", next.logPath().?);
    next.finish(.clean);

    const text = try readIn(fx, dir, "session-2.log");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "previous-session slot 1 never said it finished") != null);

    // And the abandoned log is still there, with its last line.
    const kept = try readIn(fx, dir, "session-1.log");
    defer testing.allocator.free(kept);
    try testing.expect(std.mem.indexOf(u8, kept, "the last thing it managed to say") != null);
}

test "five sessions fill the slots and a sixth retires the least recently active" {
    const fx = try Fixture.init();
    defer fx.deinit();

    var dir: []u8 = &.{};
    defer testing.allocator.free(dir);

    var taken: u8 = 0;
    while (taken < slot_count) : (taken += 1) {
        const session = try Session.open(testing.allocator, fx.os, test_build, .{});
        if (dir.len == 0) dir = try testing.allocator.dupe(u8, session.dir);
        session.finish(.clean);
        session.deinit();
    }

    // Slot 1 is the oldest. With the activity window at zero, nothing counts as live and the
    // oldest is retired — which is the only case in which a log is ever deleted.
    const sixth = try Session.open(testing.allocator, fx.os, test_build, .{ .limits = .{ .active_within_ns = 0 } });
    defer sixth.deinit();
    try testing.expectEqualStrings("session-1.log", sixth.logPath().?);
    sixth.finish(.clean);

    // And exactly five remain: one active and four previous (§10).
    var slot: u8 = 1;
    var present: u8 = 0;
    while (slot <= slot_count) : (slot += 1) {
        var name: [32]u8 = undefined;
        if (fx.os.statFileConfined(dir, slotName(&name, slot, ".log"))) |_| present += 1 else |_| {}
    }
    try testing.expectEqual(@as(u8, slot_count), present);
}

test "a session refuses to retire a slot that was written recently, and runs without a file" {
    const fx = try Fixture.init();
    defer fx.deinit();

    // Five sessions still holding their files: exactly the parallel case §10 says must not
    // be mislabelled, and must not have its log rotated out from under it.
    var held: [slot_count]*Session = undefined;
    for (&held) |*slot| slot.* = try Session.open(testing.allocator, fx.os, test_build, .{});
    defer for (held) |slot| slot.deinit();
    for (held, 1..) |slot, want| try testing.expectEqual(@as(u8, @intCast(want)), slot.slot);

    const sixth = try Session.open(testing.allocator, fx.os, test_build, .{});
    defer sixth.deinit();

    // No file, and still a session: a game must not fail to start because a log could not be
    // opened, and the terminal is unaffected.
    try testing.expect(sixth.logPath() == null);
    try testing.expect(sixth.directory() != null);
    sixth.setStage(.running);
    sixth.finish(.failed);
}

test "a log stops at its cap and says that it stopped" {
    const fx = try Fixture.init();
    defer fx.deinit();

    const session = try Session.open(testing.allocator, fx.os, test_build, .{ .limits = .{ .max_file_bytes = 2048 } });
    defer session.deinit();

    var wrote: u32 = 0;
    while (wrote < 200) : (wrote += 1) {
        say("line {d} of a session that talks far too much for the room it has", .{wrote});
        session.drain();
    }
    // Written after the cap, and through the path that does *not* go via the capture — so
    // it is the one write that the level switch cannot stop and only the cap itself does.
    session.notePackages(&.{.{ .id = "demo:pack", .version = 1 }});
    session.finish(.clean);

    const text = try readIn(fx, session.dir, "session-1.log");
    defer testing.allocator.free(text);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, truncation_marker));
    try testing.expect(text.len <= 2048 + truncation_marker.len);
    try testing.expect(std.mem.endsWith(u8, text, truncation_marker));
    // What it did keep is the beginning, header included: the build a log came from is worth
    // more than the two hundredth line of it.
    try testing.expect(std.mem.startsWith(u8, text, "foundry-log 1\n"));
}

test "lines produced faster than they are drained are dropped, and counted" {
    const fx = try Fixture.init();
    defer fx.deinit();

    const session = try Session.open(testing.allocator, fx.os, test_build, .{});
    defer session.deinit();

    // More than one frame's worth without a drain between them, which is the only way the
    // capture overflows: something empties it every frame.
    var wrote: u32 = 0;
    while (wrote < 4000) : (wrote += 1) {
        say("line {d} of a burst nobody drained", .{wrote});
    }

    const got = log_sink.drainSession(session.buffer);
    try testing.expect(got.dropped > 0);
    try testing.expect(got.len <= log_sink.session_capacity);
    session.finish(.clean);
}

test "a closed console cannot empty the release log" {
    const fx = try Fixture.init();
    defer fx.deinit();

    const session = try Session.open(testing.allocator, fx.os, test_build, .{});
    defer session.deinit();

    // The overlay's ring, turned off and emptied — which is its ordinary state in a release
    // build. None of it may reach the file (§10).
    log_sink.setCaptureLevel(null);
    log_sink.clear();
    say("a line the console will never see", .{});
    log_sink.clear();
    session.finish(.clean);

    const text = try readIn(fx, session.dir, "session-1.log");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "a line the console will never see") != null);
}

test "a run that must not write keeps nothing, and still has a session" {
    const fx = try Fixture.init();
    defer fx.deinit();

    // The shape of every frame-budgeted and headless run: stages, lines and an ending, and
    // nothing on the machine that ran it (I9).
    const session = try Session.open(testing.allocator, fx.os, test_build, .{ .enabled = false });
    defer session.deinit();

    session.setStage(.running);
    say("a line with nowhere to go", .{});
    session.notePackages(&.{.{ .id = "demo:pack", .version = 1 }});
    session.finish(.clean);

    try testing.expect(session.logPath() == null);
    try testing.expect(session.directory() == null);

    // Not even the directory, which is what "touches no user directory at all" means.
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writer.print("Library/Application Support/foundry-test/{s}", .{dir_name});
    try testing.expectError(error.FileNotFound, fx.os.statFileConfined(fx.home, writer.buffered()));
}

test "storage that cannot be written does not stop the session, or the game" {
    // POSIX modes only. Windows decides access by ACL and has no bit to clear here; the
    // behaviour under test is the same, but the way to provoke it is not.
    if (!platform.os.FileMode.has_bit) return;

    const fx = try Fixture.init();
    defer fx.deinit();

    // A first session, to create the directory, and then the directory made read-only —
    // which is what a locked-down machine, a full disk or a synced folder looks like from
    // in here.
    const first = try Session.open(testing.allocator, fx.os, test_build, .{});
    const dir = try testing.allocator.dupe(u8, first.dir);
    defer testing.allocator.free(dir);
    first.finish(.clean);
    first.deinit();

    var handle = try std.Io.Dir.openFileAbsolute(testing.io, dir, .{ .allow_directory = true });
    try handle.setPermissions(testing.io, .fromMode(0o500));
    handle.close(testing.io);
    // Restored whatever happens, or the temporary directory cannot be cleaned up.
    defer {
        if (std.Io.Dir.openFileAbsolute(testing.io, dir, .{ .allow_directory = true })) |opened| {
            var restore = opened;
            restore.setPermissions(testing.io, .fromMode(0o700)) catch {};
            restore.close(testing.io);
        } else |_| {}
    }

    const session = try Session.open(testing.allocator, fx.os, test_build, .{});
    defer session.deinit();

    // No file, and a session that works: every call below is one a game makes every frame,
    // and a game that stopped because a log could not be written would have diagnostics
    // worse than none (§10, §14 step 6).
    try testing.expect(session.logPath() == null);
    session.setStage(.running);
    say("a line with nowhere to go", .{});
    session.drain();
    session.notePackages(&.{.{ .id = "demo:pack", .version = 1 }});
    session.finish(.clean);
}
