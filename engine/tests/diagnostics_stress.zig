//! What a session leaves behind when the process does not come back.
//!
//! **In child processes, under a host deadline**, because that is the only honest way to
//! exercise it: a test that called `exit` would take the test runner with it, and a test
//! that simulated an unclean exit would be testing the simulation. The child really opens a
//! session, really writes to a real directory, and really dies without closing it
//! (`distribution.md` §10).
//!
//! The deadline is the host's only contribution. Nothing here proves a crash was *caught* —
//! nothing catches one. What it proves is that the lines already drained are on disk
//! afterwards, that the marker says the session never closed, and that the next launch
//! starts beside the evidence rather than on top of it.

const std = @import("std");
const app = @import("app");
const platform = @import("platform");

pub const std_options = app.std_options;

const Session = app.diagnostics.Session;
const Os = platform.os.Os;

const Scenario = enum {
    /// Opens, says something, closes normally.
    clean,
    /// Opens, says something, and dies without closing.
    unclean,
    /// Fails the way a startup failure fails: a named cause, a `failed` marker, nonzero.
    startup_failure,
};

const child_deadline_seconds = 10;
const said = "the child got this far";
const cause = "content could not be loaded";

const build: app.diagnostics.Build = .{
    .application = "Diagnostics Child",
    .version = "0.0.1",
    .revision = "local",
    .target = "test",
    .platform_backend = "null",
    .rhi_backend = "null",
    .optimize = "Debug",
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    if (args.next()) |mode| {
        if (!std.mem.eql(u8, mode, "--child")) return 4;
        const scenario_text = args.next() orelse return 2;
        const home = args.next() orelse return 2;
        const scenario = std.meta.stringToEnum(Scenario, scenario_text) orelse return 3;
        return child(gpa, scenario, home);
    }
    return parent(gpa, init.io);
}

// -- the child --------------------------------------------------------------------------

fn child(gpa: std.mem.Allocator, scenario: Scenario, home: []const u8) !u8 {
    const env = [_]platform.os.EnvVar{
        .{ .name = "HOME", .value = home },
        .{ .name = "XDG_DATA_HOME", .value = home },
        .{ .name = "APPDATA", .value = home },
    };
    const os = try Os.init(gpa, .{ .app_name = "foundry-diagnostics-child", .env = &env });
    defer os.deinit();

    const session = try Session.open(gpa, os, build, .{});
    // No `defer session.deinit()`: two of these three never reach it, which is the point.

    session.setStage(.running);
    std.log.scoped(.child).info(said, .{});

    switch (scenario) {
        .clean => {
            session.finish(.clean);
            session.deinit();
            return 0;
        },
        .unclean => {
            // Drained, and then gone. Everything already on disk stays; the marker still
            // says `open`, because nobody ever said otherwise.
            session.drain();
            std.process.exit(3);
        },
        .startup_failure => {
            std.log.scoped(.child).err("could not start: {s}", .{cause});
            session.finish(.failed);
            session.deinit();
            return 1;
        },
    }
}

// -- the parent -------------------------------------------------------------------------

fn parent(gpa: std.mem.Allocator, io: std.Io) !u8 {
    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);

    const os = try Os.init(gpa, .{});
    defer os.deinit();

    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = try makeHome(gpa, os, io, &home_buf);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    var failures: u8 = 0;

    // 1. An unclean exit. The child dies with its session open.
    const first = try runChild(gpa, io, executable, .unclean, home);
    defer gpa.free(first.stdout);
    defer gpa.free(first.stderr);
    failures += check("an unclean child exits with its own code", exited(first.term) == 3);

    const logs = try platform.os.joinPath(gpa, &.{ home, "Library/Application Support/foundry-diagnostics-child/logs" });
    defer gpa.free(logs);
    const fallback = try platform.os.joinPath(gpa, &.{ home, ".local/share/foundry-diagnostics-child/logs" });
    defer gpa.free(fallback);
    const dir = if (os.exists(logs)) logs else fallback;

    {
        const text = try read(gpa, os, dir, "session-1.log");
        defer gpa.free(text);
        failures += check("what it managed to say is on disk", std.mem.indexOf(u8, text, said) != null);
        failures += check("the header survived too", std.mem.startsWith(u8, text, "foundry-log 1\n"));

        const marker = try read(gpa, os, dir, "session-1.marker");
        defer gpa.free(marker);
        // Never "a crash was proven": a kill, a power loss and an overlapping session all
        // leave exactly this (§10).
        failures += check("the marker says it never closed", std.mem.indexOf(u8, marker, "\nstate open\n") != null);
        failures += check("and says where it stopped", std.mem.indexOf(u8, marker, "\nstage running\n") != null);
    }

    // 2. The next launch is healthy, starts beside the evidence, and says what it found.
    const second = try runChild(gpa, io, executable, .clean, home);
    defer gpa.free(second.stdout);
    defer gpa.free(second.stderr);
    failures += check("the next launch succeeds", exited(second.term) == 0);
    {
        const text = try read(gpa, os, dir, "session-2.log");
        defer gpa.free(text);
        failures += check("it took the next slot", std.mem.indexOf(u8, text, said) != null);
        failures += check(
            "and reported the session that never closed",
            std.mem.indexOf(u8, text, "previous-session slot 1 never said it finished") != null,
        );

        const marker = try read(gpa, os, dir, "session-2.marker");
        defer gpa.free(marker);
        failures += check("its own marker is clean", std.mem.indexOf(u8, marker, "\nstate clean\n") != null);

        // The first session's evidence is untouched. A new launch must not be able to erase
        // the one thing somebody needed.
        const kept = try read(gpa, os, dir, "session-1.log");
        defer gpa.free(kept);
        failures += check("the earlier log is intact", std.mem.indexOf(u8, kept, said) != null);
    }

    // 3. A startup failure: a named cause in the log, a `failed` marker, a nonzero exit.
    const third = try runChild(gpa, io, executable, .startup_failure, home);
    defer gpa.free(third.stdout);
    defer gpa.free(third.stderr);
    failures += check("a startup failure exits nonzero", exited(third.term) == 1);
    {
        const text = try read(gpa, os, dir, "session-3.log");
        defer gpa.free(text);
        failures += check("the cause is named in the log", std.mem.indexOf(u8, text, cause) != null);

        const marker = try read(gpa, os, dir, "session-3.marker");
        defer gpa.free(marker);
        failures += check("the marker says it failed", std.mem.indexOf(u8, marker, "\nstate failed\n") != null);
    }

    return failures;
}

fn makeHome(gpa: std.mem.Allocator, os: *Os, io: std.Io, buffer: []u8) ![]const u8 {
    const base = os.tempDirAlloc(gpa) catch |err| switch (err) {
        else => return err,
    };
    defer gpa.free(base);

    // Unique per run, so two of these in parallel never share a home. The clock is fine
    // here and would not be inside a simulation (I9): this is a file name, not a decision.
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("{s}/foundry-diagnostics-{x}", .{ base, @as(u64, @bitCast(os.wallClockNanos())) });
    const home = writer.buffered();
    try os.createDirPath(home);
    _ = io;
    return home;
}

fn runChild(
    gpa: std.mem.Allocator,
    io: std.Io,
    executable: []const u8,
    scenario: Scenario,
    home: []const u8,
) !std.process.RunResult {
    return std.process.run(gpa, io, .{
        .argv = &.{ executable, "--child", @tagName(scenario), home },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        // The host's only contribution. A child that hangs is a failure, not a test run
        // that never ends.
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(child_deadline_seconds) } },
    });
}

fn exited(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

fn read(gpa: std.mem.Allocator, os: *Os, dir: []const u8, name: []const u8) ![]u8 {
    const got = os.readFileConfined(gpa, dir, name, 4 << 20) catch |err| {
        std.log.err("could not read '{s}/{s}': {t}", .{ dir, name, err });
        return gpa.dupe(u8, "");
    };
    return got.bytes;
}

fn check(what: []const u8, ok: bool) u8 {
    if (ok) return 0;
    std.log.err("FAILED: {s}", .{what});
    return 1;
}
