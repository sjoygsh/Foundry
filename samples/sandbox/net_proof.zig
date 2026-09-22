//! The connected sandbox, proven across processes (`networking.md` Step 6).
//!
//! Headless sandboxes on real loopback TCP, each its own process, each reaching the network
//! only through the path a windowed run uses: the command line, a credential file, the
//! service its host builds and the shared markers over `FoundryApi_v5`. In order:
//!
//! 1. a server listens on a port the system chooses;
//! 2. client A joins, moves right, and waits with every command acknowledged;
//! 3. client B joins late: its baseline must already hold A's marker where A left it;
//!    B moves, and leaves;
//! 4. A sees B's marker come and go, and leaves;
//! 5. client C, with one more package loaded, is refused by catalogue before it is a peer;
//! 6. A reconnects: a fresh participant and a fresh marker number, never the old ones;
//! 7. the server stops once three participants have come and gone.
//!
//! The identities are disposable, generated for this run by the same test-only fixture the
//! session proofs use, and written to a fresh directory under the system's temporary one
//! only because separate processes must read them; the directory is deleted at the end.
//! Each child has its own home in that directory, so no preference, profile or user
//! package on this machine reaches the evidence.

const std = @import("std");
const platform = @import("platform");
const identities = @import("identities");

const Os = platform.os.Os;

/// Ample for a paced headless run on a loaded machine; a hang is a failure, not a wait.
const child_deadline_ms: u64 = 90_000;
/// Hard upper bound on any child's frames, as a second guard behind the deadline.
const frame_bound = "9000";

var failures: u32 = 0;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const sandbox = try gpa.dupe(u8, args.next() orelse {
        std.log.err("usage: sandbox-net-proof <installed sandbox executable> [--provision <dir>]", .{});
        return 2;
    });
    defer gpa.free(sandbox);
    // `--provision <dir>` writes the same disposable identities and credential files into
    // an existing directory and stops, for a windowed run by hand. They are test identities
    // from a test-only fixture, valid for loopback demonstrations and nothing else.
    var provision_dir: ?[]u8 = null;
    defer if (provision_dir) |d| gpa.free(d);
    // `--envelope <seconds>` runs §10's controlled WAN envelope instead of the proof.
    var envelope_seconds: ?u32 = null;
    if (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--provision")) {
            provision_dir = try gpa.dupe(u8, args.next() orelse return 2);
        } else if (std.mem.eql(u8, flag, "--envelope")) {
            envelope_seconds = std.fmt.parseInt(u32, args.next() orelse return 2, 10) catch return 2;
        } else return 2;
    }

    var env_list: std.ArrayList(platform.os.EnvVar) = .empty;
    defer env_list.deinit(gpa);
    var entries = init.environ_map.array_hash_map.iterator();
    while (entries.next()) |entry| try env_list.append(gpa, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
    const env = env_list.items;
    const os = try Os.init(gpa, .{ .env = env, .app_name = "foundry-net-proof" });
    defer os.deinit();

    if (provision_dir) |target| {
        try provision(gpa, os, target);
        std.log.info("wrote server.cred, a.cred to d.cred and what they name", .{});
        return 0;
    }

    const base = try os.tempDirAlloc(gpa);
    defer gpa.free(base);
    const dir = try std.fmt.allocPrint(gpa, "{s}/foundry-net-proof-{x}", .{ base, @as(u64, @bitCast(os.wallClockNanos())) });
    defer gpa.free(dir);
    try os.createDirPath(dir);
    defer deleteDir(os, base, std.fs.path.basename(dir));

    try provision(gpa, os, dir);

    var proof: Proof = .{ .gpa = gpa, .io = io, .os = os, .dir = dir, .sandbox = sandbox, .parent = init.environ_map };
    const ran = if (envelope_seconds) |seconds| proof.envelope(seconds) else proof.run();
    ran catch |err| {
        std.log.err("the proof stopped: {t}", .{err});
        failures += 1;
    };
    proof.stopAll();

    if (failures != 0) {
        std.log.err("{d} check(s) failed; the children's logs follow", .{failures});
        for (proof.children[0..proof.count]) |*child| proof.dump(child.name);
        return 1;
    }
    // `FOUNDRY_NET_PROOF_SHOW` prints the evidence a passing run judged, too.
    if (init.environ_map.get("FOUNDRY_NET_PROOF_SHOW") != null) {
        for (proof.children[0..proof.count]) |*child| proof.dump(child.name);
    }
    std.log.info("connected sandbox proof: every check passed", .{});
    return 0;
}

fn deleteDir(os: *Os, base: []const u8, name: []const u8) void {
    os.deleteTreeConfined(base, name) catch |err| std.log.warn("could not remove the proof's directory: {t}", .{err});
}

// -- identities ----------------------------------------------------------------------------

/// A root, a server identity and two players, as PEM files and four credential files.
fn provision(gpa: std.mem.Allocator, os: *Os, dir: []const u8) !void {
    // The fixture runs under the allocation hooks a live `Transport` installs.
    const t = try platform.transport.Transport.init(gpa, .{ .carrier = .memory });
    defer t.deinit();

    const pki = try gpa.create(struct {
        root: identities.Authority,
        server: identities.Identity,
        players: [4]identities.Identity,
    });
    defer {
        std.crypto.secureZero(u8, std.mem.asBytes(pki));
        gpa.destroy(pki);
    }
    const not_before = "20250101000000";
    const not_after = "20350101000000";
    try identities.ok(identities.foundry_test_authority_create(&pki.root, null, "CN=Foundry Proof Root,O=Foundry Test", 1));
    try identities.ok(identities.foundry_test_issue(&pki.server, &pki.root, "CN=proof server,O=Foundry Test", "server.foundry.test", identities.server_auth, 10, not_before, not_after));
    for (&pki.players, 0..) |*player, i| {
        try identities.ok(identities.foundry_test_issue(player, &pki.root, "CN=player,O=Foundry Test", null, identities.client_auth, @intCast(20 + i), not_before, not_after));
    }

    try put(gpa, os, dir, "root.pem", identities.pem(&pki.root.certificate));
    try put(gpa, os, dir, "server.pem", identities.pem(&pki.server.certificate));
    try put(gpa, os, dir, "server.key", identities.pem(&pki.server.private_key));
    const names = [_][]const u8{ "a", "b", "c", "d" };
    var keys: [4][64]u8 = undefined;
    for (names, &pki.players, &keys) |who, *player, *key| {
        var name: [8]u8 = undefined;
        try put(gpa, os, dir, try std.fmt.bufPrint(&name, "{s}.pem", .{who}), identities.pem(&player.certificate));
        try put(gpa, os, dir, try std.fmt.bufPrint(&name, "{s}.key", .{who}), identities.pem(&player.private_key));
        key.* = std.fmt.bytesToHex(player.key_sha256, .lower);
    }
    const server_key = std.fmt.bytesToHex(pki.server.key_sha256, .lower);

    var text: [2048]u8 = undefined;
    try put(gpa, os, dir, "server.cred", try std.fmt.bufPrint(&text,
        \\foundry-credentials 1
        \\role server
        \\trust root.pem
        \\certificate server.pem
        \\key server.key
        \\allow {s} 1
        \\allow {s} 2
        \\allow {s} 3
        \\allow {s} 4
        \\
    , .{ keys[0], keys[1], keys[2], keys[3] }));
    inline for (.{ "a", "b", "c", "d" }) |who| {
        try put(gpa, os, dir, who ++ ".cred", try std.fmt.bufPrint(&text,
            \\foundry-credentials 1
            \\role client
            \\trust root.pem
            \\certificate {s}.pem
            \\key {s}.key
            \\server-name server.foundry.test
            \\server-key {s}
            \\
        , .{ who, who, server_key }));
    }
}

fn put(gpa: std.mem.Allocator, os: *Os, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    try os.writeFile(path, bytes);
}

// -- processes ----------------------------------------------------------------------------

const Child = struct {
    name: []const u8,
    process: std.process.Child,
    running: bool,
};

const Proof = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    os: *Os,
    dir: []const u8,
    sandbox: []const u8,
    parent: *std.process.Environ.Map,
    children: [8]Child = undefined,
    count: usize = 0,
    port: u16 = 0,
    found: [128]u8 = undefined,

    fn run(self: *Proof) !void {
        _ = try self.start("server", &.{ "--serve", "127.0.0.1:0", "--credentials", "server.cred" }, &.{
            .{ "FOUNDRY_SANDBOX_NET_UNTIL_DEPARTED", "3" },
        });
        const serving = try self.waitFor("server", "markers: serving on 127.0.0.1:");
        self.port = std.fmt.parseInt(u16, std.mem.sliceTo(serving, '\n'), 10) catch return error.NoPort;
        var endpoint_buffer: [32]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "127.0.0.1:{d}", .{self.port});
        std.log.info("the server chose port {d}", .{self.port});

        // A joins and moves, and says when the server has applied all of it.
        _ = try self.start("a", &.{ "--join", endpoint, "--credentials", "a.cred" }, &.{
            .{ "FOUNDRY_SANDBOX_NET_PLAN", "right:40,await:3,await:2,leave" },
        });
        _ = try self.waitFor("a", "plan: every command acknowledged (2); waiting for 3 marker(s)");

        // B joins late, moves and leaves.
        _ = try self.start("b", &.{ "--join", endpoint, "--credentials", "b.cred" }, &.{
            .{ "FOUNDRY_SANDBOX_NET_PLAN", "down:30,leave" },
        });
        try self.finish("b");
        try self.finish("a");

        // C loads one more package than the server and is refused by catalogue.
        _ = try self.start("c", &.{ "--join", endpoint, "--credentials", "b.cred" }, &.{
            .{ "FOUNDRY_SANDBOX_PACKAGES", "room:content" },
        });
        try self.finish("c");

        // A again: a fresh participant.
        _ = try self.start("a-again", &.{ "--join", endpoint, "--credentials", "a.cred" }, &.{
            .{ "FOUNDRY_SANDBOX_NET_PLAN", "left:10,leave" },
        });
        try self.finish("a-again");
        try self.finish("server");

        try self.judge();
    }

    /// Reads the logs once every process has ended, and checks what the path promised.
    fn judge(self: *Proof) !void {
        const server = try self.log("server");
        defer self.gpa.free(server);
        const a = try self.log("a");
        defer self.gpa.free(a);
        const b = try self.log("b");
        defer self.gpa.free(b);
        const c = try self.log("c");
        defer self.gpa.free(c);
        const again = try self.log("a-again");
        defer self.gpa.free(again);

        check("the server made the server's own marker first", has(server, "markers: serving on 127.0.0.1:"));
        check("A was admitted and activated as participant 1", has(a, "markers: admitted as participant 1") and has(a, "markers: active as participant 1"));
        check("the server activated A as marker #2", has(server, "markers: participant 1 active as marker #2"));

        // Where the server says A was when A left — A was idle from before B joined.
        const a_final = after(server, "markers: participant 1 left (") orelse "";
        const a_at = between(a_final, "marker #2 last at ", "\n") orelse "";
        check("the server recorded where A's marker ended", a_at.len != 0);
        var want: [96]u8 = undefined;
        const in_baseline = std.fmt.bufPrint(&want, "#2 p1 {s}", .{a_at}) catch "";
        const b_baseline = between(b, "markers: baseline tick ", "\n") orelse "";
        check("B's baseline held the server's marker and A's, as the server last had it", has(b_baseline, "2 marker(s) #1 p0 (") and has(b_baseline, in_baseline));
        check("A had moved before B joined", !has(a_at, "(24.000, 0.000)") and a_at.len != 0);
        check("B was a fresh participant 2 on marker #3", has(b, "markers: active as participant 2") and has(server, "markers: participant 2 active as marker #3"));
        check("B's input was acknowledged and B left by choice", has(b, "plan: every command acknowledged (2); leaving") and has(server, "markers: participant 2 left ("));
        // B's commands moved B's marker and nobody else's: straight down from its spawn.
        const b_at = between(after(server, "markers: participant 2 left (") orelse "", "marker #3 last at (", ")") orelse "";
        check("B's commands moved only B's marker, and only down", std.mem.startsWith(u8, b_at, "-24.000, -") and !std.mem.eql(u8, b_at, "-24.000, -0.000"));
        check("A saw B's marker arrive", has(a, "plan: 3 marker(s) seen"));
        check("A saw B's marker removed, and its own where the server had it", has(a, "plan: 2 marker(s) seen") and has(a, in_baseline));
        check("C was refused by catalogue before it was a peer", has(c, "markers: connection ended (refused by the server: catalogue") and !has(c, "markers: active"));
        check("the server refused C before activation", has(server, "markers: a connection ended before it was active (refused: catalogue"));
        check("A came back as a fresh participant 3 on a fresh marker #4", has(again, "markers: active as participant 3") and has(server, "markers: participant 3 active as marker #4"));
        check("the server stopped after three came and went", has(server, "3 participant(s) came and went; the server stops"));
        check("the server's commands were admitted by batch", has(server, "network closed: 3 admitted, 1 refused, 0 denied"));
        for ([_][]const u8{ server, a, b, c, again }) |text| {
            check("every process exited cleanly", has(text, "clean exit after"));
            check("no process logged a credential path or key", !has(text, self.dir) and !has(text, "PRIVATE KEY"));
        }
    }

    /// §10's controlled envelope: four peers, states padded near 1 KiB at 20 Hz from a 60 Hz
    /// server, each client's stream through a shaper that delays, jitters, limits and stalls
    /// it, for `seconds`. Each client times its commands and state gaps and logs them at exit.
    fn envelope(self: *Proof, seconds: u32) !void {
        const frames = try std.fmt.allocPrint(self.gpa, "{d}", .{@as(u64, seconds) * 60});
        defer self.gpa.free(frames);
        const server_frames = try std.fmt.allocPrint(self.gpa, "{d}", .{@as(u64, seconds + 120) * 60});
        defer self.gpa.free(server_frames);
        _ = try self.start("server", &.{ "--serve", "127.0.0.1:0", "--credentials", "server.cred" }, &.{
            .{ "FOUNDRY_SANDBOX_NET_UNTIL_DEPARTED", "4" },
            // 8 + 5 × 24 bytes of markers and 824 of ballast: 952 bytes a state.
            .{ "FOUNDRY_SANDBOX_NET_BALLAST", "824" },
            .{ "FOUNDRY_SANDBOX_FRAMES", server_frames },
        });
        const serving = try self.waitFor("server", "markers: serving on 127.0.0.1:");
        const port = std.fmt.parseInt(u16, std.mem.sliceTo(serving, '\n'), 10) catch return error.NoPort;

        // For the life of the process: its relay threads are detached and outlive this call.
        const shaper = try std.heap.page_allocator.create(Shaper);
        shaper.* = .{ .io = self.io, .upstream = port };
        const front = try shaper.start();
        defer shaper.stop();
        var endpoint_buffer: [32]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "127.0.0.1:{d}", .{front});
        std.log.info("server on {d}, shaper on {d}; {d} s", .{ port, front, seconds });

        const plans = [_][]const u8{
            "right:30,left:30,loop",
            "up:30,down:30,loop",
            "left:20,up:20,right:20,down:20,loop",
            "down:45,up:45,loop",
        };
        const names = [_][]const u8{ "a", "b", "c", "d" };
        for (names, plans, 0..) |who, plan, i| {
            // Joins a little apart: behind this one relay every client shares a source
            // address, and the server admits at most two handshake starts a second from one
            // (`Limits.handshake_starts_per_source_per_second`), as it should.
            if (i != 0) self.os.sleep(.fromMillis(1200));
            var cred: [8]u8 = undefined;
            _ = try self.start(who, &.{ "--join", endpoint, "--credentials", try std.fmt.bufPrint(&cred, "{s}.cred", .{who}) }, &.{
                .{ "FOUNDRY_SANDBOX_NET_PLAN", plan },
                .{ "FOUNDRY_SANDBOX_NET_MEASURE", "1" },
                .{ "FOUNDRY_SANDBOX_FRAMES", frames },
            });
        }
        // Frames are paced to real time; the bound allows for a loaded machine, not for a hang.
        const deadline = (@as(u64, seconds) * 3 / 2 + 60) * 1000;
        for (names) |who| try self.finishWithin(who, deadline);
        try self.finishWithin("server", 120_000);

        std.log.info("shaper: {d} connection(s), {d} B forwarded, {d} stall(s)", .{ shaper.connections.load(.monotonic), shaper.bytes.load(.monotonic), shaper.stalls.load(.monotonic) });
        for (names) |who| {
            const text = try self.log(who);
            defer self.gpa.free(text);
            const line = between(text, "measure: ", "\n") orelse "";
            std.log.info("{s}: {s}", .{ who, line });
            check("the client measured its commands", line.len != 0);
            check("no unintended disconnect", has(line, "ended unexpectedly: no"));
            // A floor as well as a ceiling: nothing can be acknowledged faster than the round
            // trip the shaper imposes, so a p50 below it means the shaper or the measure broke.
            const p50 = number(between(line, "p50 ", " ms") orelse "") orelse 0;
            check("p50 is at least the imposed 150 ms round trip", p50 >= 150);
            const p95 = number(between(line, "p95 ", " ms") orelse "") orelse 99_999;
            check("p95 command-to-visible-acknowledgement is at most 500 ms", p95 <= 500);
            const gap = number(between(line, "longest gap ", " ms") orelse "") orelse 99_999;
            check("no state older than two seconds", gap <= 2000);
        }
        const server = try self.log("server");
        defer self.gpa.free(server);
        std.log.info("server: {s}", .{between(server, "network closed: ", "\n") orelse ""});
        std.log.info("server: {s}", .{between(server, "network peaks per pump: ", "\n") orelse ""});
        check("every client was admitted and left", has(server, "4 participant(s) came and went"));
    }

    fn finishWithin(self: *Proof, name: []const u8, deadline_ms: u64) !void {
        _ = self.waitForWithin(name, "clean exit after", deadline_ms) catch |err| {
            self.stop(name);
            return err;
        };
        const child = self.find(name) orelse return error.NoSuchChild;
        const term = try child.process.wait(self.io);
        child.running = false;
        check("a child exited 0", switch (term) {
            .exited => |code| code == 0,
            else => false,
        });
    }

    fn start(self: *Proof, name: []const u8, args: []const []const u8, extra: []const [2][]const u8) !*Child {
        var argv: [8][]const u8 = undefined;
        argv[0] = self.sandbox;
        for (args, 1..) |arg, i| {
            // A credential file is named relative to the proof's directory.
            argv[i] = if (std.mem.endsWith(u8, arg, ".cred")) try std.fs.path.join(self.gpa, &.{ self.dir, arg }) else arg;
        }
        defer for (args, 1..) |arg, i| if (std.mem.endsWith(u8, arg, ".cred")) self.gpa.free(argv[i]);

        var environ = try self.parent.clone(self.gpa);
        defer environ.deinit();
        const home = try std.fs.path.join(self.gpa, &.{ self.dir, name });
        defer self.gpa.free(home);
        try self.os.createDirPath(home);
        // Every place this platform keeps per-user data, pointed at a directory of its own.
        for ([_][]const u8{ "HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "APPDATA", "LOCALAPPDATA", "USERPROFILE" }) |key| try environ.put(key, home);
        try environ.put("FOUNDRY_SANDBOX_FRAMES", frame_bound);
        for (extra) |pair| try environ.put(pair[0], pair[1]);

        const log_path = try self.logPath(name);
        defer self.gpa.free(log_path);
        const file = try std.Io.Dir.createFileAbsolute(self.io, log_path, .{});
        defer file.close(self.io);

        const child = &self.children[self.count];
        child.* = .{
            .name = name,
            .process = try std.process.spawn(self.io, .{
                .argv = argv[0 .. args.len + 1],
                .environ_map = &environ,
                .stdin = .ignore,
                .stdout = .{ .file = file },
                .stderr = .{ .file = file },
            }),
            .running = true,
        };
        self.count += 1;
        std.log.info("started {s}", .{name});
        return child;
    }

    /// Polls a child's log until `needle` appears, and returns what follows it.
    fn waitFor(self: *Proof, name: []const u8, needle: []const u8) ![]const u8 {
        return self.waitForWithin(name, needle, child_deadline_ms);
    }

    fn waitForWithin(self: *Proof, name: []const u8, needle: []const u8, deadline_ms: u64) ![]const u8 {
        var waited: u64 = 0;
        while (waited < deadline_ms) : (waited += 50) {
            const text = try self.log(name);
            defer self.gpa.free(text);
            if (std.mem.indexOf(u8, text, needle)) |at| {
                const rest = text[at + needle.len ..];
                const line = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
                @memcpy(self.found[0..@min(line.len, self.found.len)], line[0..@min(line.len, self.found.len)]);
                return self.found[0..@min(line.len, self.found.len)];
            }
            if (std.mem.indexOf(u8, text, "error(sandbox)") != null) {
                std.log.err("{s} failed while the proof waited for '{s}'", .{ name, needle });
                return error.ChildFailed;
            }
            self.os.sleep(.fromMillis(50));
        }
        std.log.err("{s} never logged '{s}'", .{ name, needle });
        return error.Timeout;
    }

    /// Waits for a child to say it is done, then reaps it and checks it exited 0.
    fn finish(self: *Proof, name: []const u8) !void {
        _ = self.waitFor(name, "clean exit after") catch |err| {
            self.stop(name);
            return err;
        };
        const child = self.find(name) orelse return error.NoSuchChild;
        const term = try child.process.wait(self.io);
        child.running = false;
        const code: ?u8 = switch (term) {
            .exited => |exit| exit,
            else => null,
        };
        check("a child exited 0", code == 0);
        std.log.info("{s} finished", .{name});
    }

    fn stop(self: *Proof, name: []const u8) void {
        const child = self.find(name) orelse return;
        if (!child.running) return;
        child.process.kill(self.io);
        child.running = false;
    }

    fn stopAll(self: *Proof) void {
        for (self.children[0..self.count]) |*child| if (child.running) {
            child.process.kill(self.io);
            child.running = false;
        };
    }

    fn find(self: *Proof, name: []const u8) ?*Child {
        for (self.children[0..self.count]) |*child| if (std.mem.eql(u8, child.name, name)) return child;
        return null;
    }

    fn logPath(self: *Proof, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}.log", .{ self.dir, name });
    }

    fn log(self: *Proof, name: []const u8) ![]u8 {
        const path = try self.logPath(name);
        defer self.gpa.free(path);
        return self.os.readFile(self.gpa, path, 16 << 20);
    }

    fn dump(self: *Proof, name: []const u8) void {
        const text = self.log(name) catch return;
        defer self.gpa.free(text);
        // The network and markers lines, which is what the checks read.
        std.debug.print("---- {s} ----\n", .{name});
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (has(line, "markers:") or has(line, "network") or has(line, "plan:") or has(line, "error") or has(line, "clean exit")) {
                std.debug.print("{s}\n", .{line});
            }
        }
    }
};

fn number(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " "), 10) catch null;
}

// -- the shaper -----------------------------------------------------------------------------

/// A TCP relay in front of the server that makes loopback behave like the envelope's path
/// (`networking.md` §10), in each direction of each connection:
///
/// - 75 ms one-way delay plus 0–15 ms of jitter, so 150 ms round trip and up to 30 ms more;
///   bytes keep their order, as TCP's do, so jitter delays and never reorders;
/// - 1 Mbit/s: a chunk is released no sooner than its size allows after the last one;
/// - one 250 ms head-of-line stall every 5 s, during which nothing is released.
///
/// It models a stream's delays and stalls, not packet loss, which TCP would turn into
/// exactly these. Blocking sockets and two threads per direction: a test harness, never
/// engine code.
const Shaper = struct {
    io: std.Io,
    upstream: u16,
    listener: std.Io.net.Server = undefined,
    accept_thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    connections: std.atomic.Value(u32) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    stalls: std.atomic.Value(u32) = .init(0),

    const one_way_ns: u64 = 75 * std.time.ns_per_ms;
    const jitter_ns: u64 = 15 * std.time.ns_per_ms;
    const bytes_per_second: u64 = 1_000_000 / 8;
    const stall_every_ns: u64 = 5 * std.time.ns_per_s;
    const stall_ns: u64 = 250 * std.time.ns_per_ms;

    fn start(self: *Shaper) !u16 {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.listener = try address.listen(self.io, .{ .reuse_address = true });
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self.listener.socket.address.getPort();
    }

    fn stop(self: *Shaper) void {
        self.stopping.store(true, .monotonic);
        // The accept loop blocks; the process ending reaps it and every relay thread.
        if (self.accept_thread) |thread| thread.detach();
    }

    fn acceptLoop(self: *Shaper) void {
        var seed: u64 = 0x5eed;
        while (!self.stopping.load(.monotonic)) {
            const downstream = self.listener.accept(self.io) catch return;
            const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.upstream) catch return;
            const upstream = address.connect(self.io, .{ .mode = .stream }) catch {
                downstream.close(self.io);
                continue;
            };
            _ = self.connections.fetchAdd(1, .monotonic);
            seed +%= 0x9e3779b97f4a7c15;
            for ([_][2]std.Io.net.Stream{ .{ downstream, upstream }, .{ upstream, downstream } }, 0..) |pair, i| {
                const direction = std.heap.page_allocator.create(Direction) catch return;
                direction.* = .{ .shaper = self, .from = pair[0], .to = pair[1], .rng = .init(seed +% i) };
                const reader = std.Thread.spawn(.{}, Direction.read, .{direction}) catch return;
                reader.detach();
                const writer = std.Thread.spawn(.{}, Direction.write, .{direction}) catch return;
                writer.detach();
            }
        }
    }

    fn now(self: *Shaper) u64 {
        return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
    }

    /// One direction of one connection: a bounded queue of timestamped chunks between a
    /// thread that reads as fast as bytes arrive and one that releases them on schedule.
    const Direction = struct {
        shaper: *Shaper,
        from: std.Io.net.Stream,
        to: std.Io.net.Stream,
        rng: std.Random.DefaultPrng,
        mutex: std.Io.Mutex = .init,
        chunks: [4096]Chunk = undefined,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,
        last_release: u64 = 0,

        const Chunk = struct { due: u64, len: u16, bytes: [2048]u8 };

        fn read(self: *Direction) void {
            const io = self.shaper.io;
            var buffer: [2048]u8 = undefined;
            var reader = self.from.reader(io, &buffer);
            while (true) {
                reader.interface.fillMore() catch break;
                const data = reader.interface.buffered();
                const jitter = self.rng.random().uintLessThan(u64, jitter_ns + 1);
                const arrive = self.shaper.now();
                while (true) {
                    self.mutex.lockUncancelable(io);
                    if (self.len < self.chunks.len) break;
                    self.mutex.unlock(io);
                    io.sleep(.fromMilliseconds(1), .awake) catch {};
                }
                // In order, as TCP delivers: never due before the chunk ahead of it.
                const previous = if (self.len == 0) 0 else self.chunks[(self.head + self.len - 1) % self.chunks.len].due;
                const slot = &self.chunks[(self.head + self.len) % self.chunks.len];
                slot.due = @max(arrive + one_way_ns + jitter, previous);
                slot.len = @intCast(data.len);
                @memcpy(slot.bytes[0..data.len], data);
                self.len += 1;
                self.mutex.unlock(io);
                reader.interface.toss(data.len);
            }
            self.mutex.lockUncancelable(io);
            self.closed = true;
            self.mutex.unlock(io);
        }

        fn write(self: *Direction) void {
            const io = self.shaper.io;
            var buffer: [2048]u8 = undefined;
            var writer = self.to.writer(io, &buffer);
            const epoch = self.shaper.now();
            var stalled_in: u64 = std.math.maxInt(u64);
            while (true) {
                const t = self.shaper.now();
                // The head-of-line stall: the first 250 ms of every 5 s release nothing.
                const phase = (t - epoch) % stall_every_ns;
                if (phase < stall_ns) {
                    const window = (t - epoch) / stall_every_ns;
                    if (window != stalled_in) {
                        stalled_in = window;
                        _ = self.shaper.stalls.fetchAdd(1, .monotonic);
                    }
                    io.sleep(.fromNanoseconds(@intCast(stall_ns - phase)), .awake) catch {};
                    continue;
                }
                self.mutex.lockUncancelable(io);
                if (self.len == 0) {
                    const done = self.closed;
                    self.mutex.unlock(io);
                    if (done) break;
                    io.sleep(.fromMilliseconds(1), .awake) catch {};
                    continue;
                }
                const chunk = &self.chunks[self.head];
                const ready = @max(chunk.due, self.last_release);
                if (ready > t) {
                    self.mutex.unlock(io);
                    io.sleep(.fromNanoseconds(@intCast(@min(ready - t, std.time.ns_per_ms))), .awake) catch {};
                    continue;
                }
                var out: [2048]u8 = undefined;
                const n = chunk.len;
                @memcpy(out[0..n], chunk.bytes[0..n]);
                self.head = (self.head + 1) % self.chunks.len;
                self.len -= 1;
                // 1 Mbit/s: the next chunk waits for this one's bytes to have "sent".
                self.last_release = t + @as(u64, n) * std.time.ns_per_s / bytes_per_second;
                self.mutex.unlock(io);
                writer.interface.writeAll(out[0..n]) catch break;
                writer.interface.flush() catch break;
                _ = self.shaper.bytes.fetchAdd(n, .monotonic);
            }
            self.to.shutdown(io, .send) catch {};
        }
    };
};

fn check(what: []const u8, ok: bool) void {
    if (ok) return;
    std.log.err("FAILED: {s}", .{what});
    failures += 1;
}

fn has(text: []const u8, needle: []const u8) bool {
    return needle.len != 0 and std.mem.indexOf(u8, text, needle) != null;
}

fn after(text: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    return text[at + needle.len ..];
}

fn between(text: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const rest = after(text, start) orelse return null;
    return rest[0 .. std.mem.indexOf(u8, rest, end) orelse rest.len];
}
