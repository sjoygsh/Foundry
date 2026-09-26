//! The sandbox's connected host (`networking.md` §9, M16 Step 6).
//!
//! **Everything the demonstration's consumer cannot be trusted with lives here, and nothing
//! else does.** This file reads the operator's credential file, builds the transport and the
//! service, describes the loaded content for compatibility, publishes exactly one grant to
//! the table, pumps the network with real elapsed time, reads the keyboard or a scripted
//! plan, and paces a headless run. The shared markers themselves — sessions, channels,
//! authority, state, presentation — are `markers`, which sees only `foundry.h` and is handed
//! the table, an intent and a viewport.
//!
//! ## Launch
//!
//! ```
//! sandbox                                                   offline, as it always was
//! sandbox --serve <a.b.c.d:port> --credentials <file>       an authoritative server
//! sandbox --join  <a.b.c.d:port> --credentials <file>       a client of one
//! ```
//!
//! Endpoints are numeric, as `platform.transport.Endpoint` is: no name is resolved. There is
//! no mode without credentials and no switch that turns verification off, because the
//! transport has neither (ADR-0045).
//!
//! ## The credential file
//!
//! A host-only text file the operator provisions. It is never content, never crosses the
//! table, and its paths and keys are never logged:
//!
//! ```
//! foundry-credentials 1
//! role        server | client
//! trust       <PEM roots>            relative paths are the file's own directory's
//! certificate <PEM chain, leaf first>
//! key         <PEM private key>      unencrypted P-256; wiped from memory once loaded
//! server-name <name>                 client only: the name the server certificate carries
//! server-key  <64 hex>               client only: SHA-256 of the server's public key
//! allow       <64 hex> <principal>   server only, repeatable: a client key it admits
//! ```
//!
//! ## Headless and scripted runs
//!
//! Under the null platform there is no keyboard and the frame clock is synthetic, so a
//! connected headless run is paced: one fixed step of real sleep per frame, stated once in
//! the log, never a busy loop. The service always gets real elapsed time from
//! `Os.monotonicNanos`, windowed or not, because the peer across a socket is real.
//!
//! `FOUNDRY_SANDBOX_NET_PLAN` scripts a client's input, as a comma-separated list, each
//! step starting once the client is active: `left:N`, `right:N`, `up:N`, `down:N`, `idle:N`
//! hold a direction for N fixed steps; `await:N` waits until the view holds N markers;
//! `leave` disconnects and exits. `await` and `leave` first wait for every command sent to
//! be acknowledged by a state, so a step's effect is the server's before the next begins.
//! `loop`, last, starts the plan again. `FOUNDRY_SANDBOX_NET_UNTIL_DEPARTED=N` ends a server
//! once N peers that were active have left and none remain. `FOUNDRY_SANDBOX_NET_BALLAST=N`
//! pads a server's every state with N zero bytes, to measure at a payload size.
//! `FOUNDRY_SANDBOX_NET_MEASURE` has a client time each command from sending to the state that
//! shows it applied, and the gaps between states, and log both at exit. All are test inputs
//! and change nothing a player does.

const std = @import("std");
const abi = @import("abi");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const net = @import("net");
const platform = @import("platform");
const render2d = @import("render2d");
const ui = @import("ui");
const markers = @import("markers");
const mod = @import("mod");

const transport = platform.transport;
const Endpoint = transport.Endpoint;

const log = core.log.scoped(.network);

pub const usage =
    \\usage: sandbox [--serve <a.b.c.d:port> | --join <a.b.c.d:port>] --credentials <file>
    \\
    \\  (no arguments)          offline: the sandbox as it always was
    \\  --serve <endpoint>      be the authoritative server for shared markers, listening here
    \\  --join <endpoint>       join the server at this endpoint
    \\  --credentials <file>    the operator's credential file for that role (required)
    \\  --help                  this text
    \\
;

pub const Mode = enum { offline, serve, join };

pub const Launch = struct {
    mode: Mode = .offline,
    endpoint: Endpoint = .{ .address = .{ 0, 0, 0, 0 }, .port = 0 },
    credentials: []const u8 = "",
};

pub const ArgError = error{ Usage, Help };

/// Reads the sandbox's command line. Nothing but these three flags is accepted, so a typo is
/// an error rather than an offline run that looks like a failed connection.
pub fn parseArgs(argv: []const []const u8) ArgError!Launch {
    var launch: Launch = .{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help")) return error.Help;
        if (index + 1 >= argv.len) return error.Usage;
        const value = argv[index + 1];
        index += 1;
        if (std.mem.eql(u8, arg, "--serve") or std.mem.eql(u8, arg, "--join")) {
            if (launch.mode != .offline) return error.Usage;
            launch.mode = if (arg[2] == 's') .serve else .join;
            launch.endpoint = Endpoint.parse(value) catch return error.Usage;
        } else if (std.mem.eql(u8, arg, "--credentials")) {
            if (launch.credentials.len != 0) return error.Usage;
            launch.credentials = value;
        } else return error.Usage;
    }
    if ((launch.mode == .offline) != (launch.credentials.len == 0)) return error.Usage;
    return launch;
}

// -- credentials ----------------------------------------------------------------------------

/// The file itself is `net.credentials`'s format and reader, shared with every other host;
/// only what the sandbox says about a refusal is its own. A demonstration of four peers
/// asks for no more than it uses.
const credential_limits: net.credentials.Limits = .{ .file_bytes = 16 * 1024, .allowed = 64 };

pub const CredentialError = net.credentials.LoadError;

// -- the host --------------------------------------------------------------------------------

const max_plan_steps = 32;

const PlanStep = union(enum) {
    hold: struct { intent: markers.Intent, steps: u32 },
    await_markers: u32,
    leave,
    loop,
};

pub const PlanError = error{PlanMalformed};

fn parsePlan(text: []const u8, out: *[max_plan_steps]PlanStep) PlanError![]PlanStep {
    var count: usize = 0;
    var steps = std.mem.splitScalar(u8, text, ',');
    while (steps.next()) |raw| {
        const step = std.mem.trim(u8, raw, " ");
        if (step.len == 0) continue;
        if (count == max_plan_steps) return error.PlanMalformed;
        if (std.mem.eql(u8, step, "leave")) {
            out[count] = .leave;
        } else if (std.mem.eql(u8, step, "loop")) {
            out[count] = .loop;
        } else {
            const colon = std.mem.indexOfScalar(u8, step, ':') orelse return error.PlanMalformed;
            const name = step[0..colon];
            const n = std.fmt.parseInt(u32, step[colon + 1 ..], 10) catch return error.PlanMalformed;
            if (std.mem.eql(u8, name, "await")) {
                out[count] = .{ .await_markers = n };
            } else {
                const intent: markers.Intent = if (std.mem.eql(u8, name, "left"))
                    .{ .dx = -1 }
                else if (std.mem.eql(u8, name, "right"))
                    .{ .dx = 1 }
                else if (std.mem.eql(u8, name, "up"))
                    .{ .dy = 1 }
                else if (std.mem.eql(u8, name, "down"))
                    .{ .dy = -1 }
                else if (std.mem.eql(u8, name, "idle"))
                    .{}
                else
                    return error.PlanMalformed;
                out[count] = .{ .hold = .{ .intent = intent, .steps = n } };
            }
        }
        count += 1;
    }
    // A loop repeats what came before it, so it is last and something must come before it.
    for (out[0..count], 0..) |step, i| {
        if (step == .loop and (i + 1 != count or i == 0)) return error.PlanMalformed;
    }
    return out[0..count];
}

/// Test inputs, read once.
pub const Script = struct {
    plan: ?[]const u8 = null,
    until_departed: ?u32 = null,
    ballast: u32 = 0,
    measure: bool = false,
};

/// What `FOUNDRY_SANDBOX_NET_MEASURE` records, in real time from `Os.monotonicNanos`: each
/// command from the step that sent it to the frame whose state shows it applied, and the
/// longest time between two states that changed the view's tick.
const Measure = struct {
    const ring = 256;
    const buckets = 5001;
    sent_at: [ring]u64 = @splat(0),
    last_sent: u64 = 0,
    last_acknowledged: u64 = 0,
    /// Milliseconds, one bucket each; the last holds everything longer.
    histogram: [buckets]u32 = @splat(0),
    count: u64 = 0,
    max_ns: u64 = 0,
    last_tick: u64 = 0,
    last_tick_at: u64 = 0,
    max_gap_ns: u64 = 0,
    states: u64 = 0,

    fn sent(self: *Measure, number: u64, now: u64) void {
        if (number <= self.last_sent) return;
        self.sent_at[number % ring] = now;
        self.last_sent = number;
    }

    fn observe(self: *Measure, status: markers.Status, now: u64) void {
        if (status.phase != .active) return;
        const acknowledged = @min(status.acknowledged, self.last_sent);
        while (self.last_acknowledged < acknowledged) {
            self.last_acknowledged += 1;
            const latency = now -| self.sent_at[self.last_acknowledged % ring];
            self.histogram[@min(latency / std.time.ns_per_ms, buckets - 1)] += 1;
            self.count += 1;
            self.max_ns = @max(self.max_ns, latency);
        }
        if (status.tick != self.last_tick) {
            if (self.last_tick_at != 0) self.max_gap_ns = @max(self.max_gap_ns, now - self.last_tick_at);
            self.last_tick = status.tick;
            self.last_tick_at = now;
            self.states += 1;
        }
    }

    fn percentile(self: *const Measure, fraction: f64) u64 {
        if (self.count == 0) return 0;
        const rank: u64 = @intFromFloat(@ceil(fraction * @as(f64, @floatFromInt(self.count))));
        var seen: u64 = 0;
        for (self.histogram, 0..) |n, ms| {
            seen += n;
            if (seen >= rank) return ms;
        }
        return buckets - 1;
    }
};

pub const Connected = struct {
    gpa: std.mem.Allocator,
    os: *platform.os.Os,
    t: *transport.Transport,
    service: *net.Service,
    grants: [1]core.ContentId,
    /// The host this process already bound — the scripts' — or our own.
    own_host: abi.Host = .{},
    host: *abi.Host,
    borrowed: bool,
    /// What a borrowed host held before, restored on close.
    saved: Saved = .{},
    context: ui.Context,
    client: markers.Markers,
    keys: [4]?platform.Key = @splat(null),

    plan_storage: [max_plan_steps]PlanStep = undefined,
    plan: []PlanStep = &.{},
    plan_index: usize = 0,
    plan_left: u32 = 0,
    announced: bool = false,
    left: bool = false,
    until_departed: ?u32 = null,
    quit: bool = false,
    headless: bool,
    measure: ?Measure = null,

    const Saved = struct {
        net_service: ?*net.Service = null,
        net_grants: []const core.ContentId = &.{},
        renderer: ?*render2d.Renderer = null,
        ui_context: ?*ui.Context = null,
        ui_input: ?ui.Input = null,
    };

    pub const OpenError = CredentialError || PlanError || markers.InitError ||
        transport.InitError || transport.CredentialError || net.service.InitError ||
        std.mem.Allocator.Error || error{ PackageUnreadable, NoContent };

    /// Everything a connected run needs, in the order its failures should be reported: the
    /// operator's file, then the content description, then the transport and the service,
    /// then the consumer's own start.
    pub fn open(
        gpa: std.mem.Allocator,
        os: *platform.os.Os,
        engine: *app.Engine,
        renderer: *render2d.Renderer,
        style: ui.Style,
        launch: Launch,
        packages: []const mod.Entry,
        script: Script,
        headless: bool,
    ) OpenError!*Connected {
        std.debug.assert(launch.mode != .offline);
        const role: transport.Role = if (launch.mode == .serve) .server else .client;

        var diagnostic: net.credentials.Diagnostic = .{};
        var file = net.credentials.load(gpa, os, launch.credentials, role, credential_limits, &diagnostic) catch |err| {
            switch (err) {
                error.FileUnreadable => log.err("the credential file could not be read", .{}),
                error.RoleMismatch => log.err("the credential file is for the other role; this run is a {t}", .{role}),
                error.PartUnreadable => log.err("the credential file's {t} could not be read", .{diagnostic.part.?}),
                error.TooManyAllowed => log.err("the credential file allows more keys than the sandbox admits, at line {d}", .{diagnostic.line}),
                error.Malformed => if (diagnostic.line != 0) {
                    log.err("the credential file is malformed at line {d}", .{diagnostic.line});
                } else {
                    log.err("the credential file needs a header, a role, trust, certificate and key; a client's names the server and its key and allows no one, and a server's the opposite", .{});
                },
                error.OutOfMemory => {},
            }
            return err;
        };
        defer file.deinit(gpa);

        var limits: net.limits.Limits = .{};
        limits.sessions = 1;
        const t = try transport.Transport.init(gpa, net.service.transportOptions(limits, .system));
        errdefer t.deinit();

        const credentials = t.createCredentials(file.config()) catch |err| {
            log.err("the credentials were refused: {t}", .{err});
            return err;
        };
        // The provider holds its own zeroized copy now; this one is wiped at once.
        file.wipeKey(gpa);

        var description = try describeContent(gpa, os, packages);
        defer description.deinit(gpa);
        const grant_id = data.contentId(if (role == .server) "sandbox:net.serve" else "sandbox:net.join") catch unreachable;
        const service = net.Service.init(gpa, t, .{
            .limits = limits,
            .compatibility = description.value(engine),
            .grants = &.{.{ .id = grant_id, .role = role, .endpoint = launch.endpoint, .credentials = credentials }},
            .identities = file.allowed,
            // Unique across restarts, so a client reconnecting to a restarted server sees
            // a new epoch. A file-name-grade use of the clock, not a simulation input (I9).
            .first_epoch = @max(1, @as(u64, @bitCast(os.wallClockNanos())) / std.time.ns_per_ms),
        }) catch |err| {
            log.err("the network service would not start: {t}", .{err});
            return err;
        };
        errdefer service.deinit();

        const self = try gpa.create(Connected);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .os = os,
            .t = t,
            .service = service,
            .grants = .{grant_id},
            .host = undefined,
            .borrowed = false,
            .context = .init(gpa, style),
            .client = undefined,
            .headless = headless,
            .until_departed = script.until_departed,
            .measure = if (script.measure) .{} else null,
        };
        errdefer self.context.deinit();

        // **One table per process** (`abi.Host.bind`). Where scripts already bound theirs,
        // networking joins it rather than replacing it; otherwise this host is the table.
        if (abi.Host.current()) |existing| {
            self.host = existing;
            self.borrowed = true;
            self.saved = .{
                .net_service = existing.net_service,
                .net_grants = existing.net_grants,
                .renderer = existing.renderer,
                .ui_context = existing.ui_context,
                .ui_input = existing.ui_input,
            };
        } else {
            self.own_host = .{ .engine = engine };
            self.host = &self.own_host;
            self.host.bind();
        }
        self.host.net_service = service;
        self.host.net_grants = &self.grants;
        self.host.renderer = renderer;
        self.host.ui_context = &self.context;
        errdefer self.release();

        if (script.plan) |plan_text| {
            self.plan = parsePlan(plan_text, &self.plan_storage) catch {
                log.err("FOUNDRY_SANDBOX_NET_PLAN is not a plan", .{});
                return error.PlanMalformed;
            };
        }

        const public = abi.TableOf(abi.Host).getApi(abi.api_version_5) orelse unreachable;
        self.client = markers.Markers.initWith(@ptrCast(@alignCast(public)), .{ .ballast = script.ballast }) catch |err| {
            log.err("the shared markers would not start: {t}", .{err});
            return err;
        };
        for (std.enums.values(markers.Direction), 0..) |direction, i| {
            const name = self.client.settings.keyName(direction);
            self.keys[i] = platform.Key.fromName(name) orelse blk: {
                log.warn("'{s}' is not a key; {t} is unbound", .{ name, direction });
                break :blk null;
            };
        }

        log.info("{t} for shared markers: {d} package(s) described, {d} key(s) allowed, protocol {d}", .{
            role, packages.len, file.allowed.len, markers.protocol_revision,
        });
        if (headless) log.info("headless: paced at one fixed step of real time per frame", .{});
        return self;
    }

    pub fn close(self: *Connected) void {
        if (self.measure) |*m| {
            const now = self.client.status();
            log.info("measure: {d} command(s) acknowledged, p50 {d} ms, p95 {d} ms, max {d} ms; {d} state(s), longest gap {d} ms; ended unexpectedly: {s}", .{
                m.count,
                m.percentile(0.50),
                m.percentile(0.95),
                m.max_ns / std.time.ns_per_ms,
                m.states,
                m.max_gap_ns / std.time.ns_per_ms,
                if (now.phase == .ended and !self.left) "yes" else "no",
            });
        }
        self.client.deinit();
        // One last pump, so a close is sent rather than merely decided.
        self.service.pump(self.os.monotonicNanos());
        const stats = self.service.stats();
        log.info("network closed: {d} admitted, {d} refused, {d} denied; {d} command(s) sent, {d} admitted; {d} state(s) sent, {d} replaced; peak send queue {d} B", .{
            stats.admitted,        stats.refused,           stats.denied,
            stats.commands_sent,   stats.commands_admitted, stats.states_sent,
            stats.states_replaced, stats.peak_send_queue,
        });
        log.info("network peaks per pump: {d} frame(s) and {d} B in, {d} B out; events {d}, inbox {d} B, batch {d} command(s) / {d} B; {d} B sent, {d} B received", .{
            stats.peak_frames_in_per_pump, stats.peak_bytes_in_per_pump, stats.peak_bytes_out_per_pump,
            stats.peak_events,             stats.peak_inbox_bytes,       stats.peak_batch_commands,
            stats.peak_batch_bytes,        stats.bytes_sent,             stats.bytes_received,
        });
        self.release();
        self.context.deinit();
        self.service.deinit();
        self.t.deinit();
        self.gpa.destroy(self);
    }

    fn release(self: *Connected) void {
        if (self.borrowed) {
            self.host.net_service = self.saved.net_service;
            self.host.net_grants = self.saved.net_grants;
            self.host.renderer = self.saved.renderer;
            self.host.ui_context = self.saved.ui_context;
            self.host.ui_input = self.saved.ui_input;
        } else {
            self.own_host.unbind();
        }
    }

    /// Top of the frame: the network moves, then the consumer reads what it brought.
    pub fn frame(self: *Connected) void {
        self.service.pump(self.os.monotonicNanos());
        self.client.frame();
        if (self.measure) |*m| m.observe(self.client.status(), self.os.monotonicNanos());

        const now = self.client.status();
        if (now.role == .client and now.phase == .ended and (self.headless or self.plan.len != 0)) {
            if (!self.quit) log.info("the connection is over; a scripted run ends here", .{});
            self.quit = true;
        }
        if (self.until_departed) |n| {
            if (now.departed >= n and now.peers == 0 and !self.quit) {
                log.info("{d} participant(s) came and went; the server stops", .{now.departed});
                self.quit = true;
            }
        }
    }

    /// Once per fixed step: this view's intent, from its keys or its plan.
    pub fn step(self: *Connected, step_input: *const platform.InputSnapshot, keyboard_free: bool) void {
        const intent = if (self.plan.len != 0) self.planned() else if (keyboard_free) self.keyed(step_input) else markers.Intent{};
        self.client.step(intent);
        if (self.measure) |*m| m.sent(self.client.sent, self.os.monotonicNanos());
    }

    /// After the frame's steps: what they queued goes to the network now, not next frame.
    pub fn flush(self: *Connected) void {
        self.service.pump(self.os.monotonicNanos());
    }

    pub fn wantsQuit(self: *const Connected) bool {
        return self.quit;
    }

    /// Inside the renderer's frame: the consumer draws, then its panel is walked.
    pub fn draw(self: *Connected, engine: *app.Engine, renderer: *render2d.Renderer, font: app.UiFont, solid: ?render2d.Region) !void {
        const info = engine.windowInfo();
        const width: f32 = if (info) |i| @floatFromInt(i.logical_size.width) else 1280;
        const height: f32 = if (info) |i| @floatFromInt(i.logical_size.height) else 720;
        self.host.ui_input = .{
            .keys = engine.input,
            .pointer = engine.input.mouse.position,
            .frame = engine.frame_index,
        };
        self.client.draw(.{ .x = 0, .y = 0, .w = width, .h = height });
        try app.drawUi(&self.context.list, renderer, font, .screen, .{ .solid = solid });
    }

    fn keyed(self: *const Connected, input: *const platform.InputSnapshot) markers.Intent {
        var intent: markers.Intent = .{};
        const held = struct {
            fn f(in: *const platform.InputSnapshot, key: ?platform.Key) bool {
                return if (key) |k| in.isHeld(k) else false;
            }
        }.f;
        if (held(input, self.keys[@intFromEnum(markers.Direction.up)])) intent.dy += 1;
        if (held(input, self.keys[@intFromEnum(markers.Direction.down)])) intent.dy -= 1;
        if (held(input, self.keys[@intFromEnum(markers.Direction.left)])) intent.dx -= 1;
        if (held(input, self.keys[@intFromEnum(markers.Direction.right)])) intent.dx += 1;
        return intent;
    }

    fn planned(self: *Connected) markers.Intent {
        const now = self.client.status();
        if (now.phase != .active or self.plan_index >= self.plan.len) return .{};
        switch (self.plan[self.plan_index]) {
            .hold => |hold| {
                if (self.plan_left == 0) self.plan_left = hold.steps;
                self.plan_left -= 1;
                if (self.plan_left == 0) self.advance();
                return hold.intent;
            },
            .await_markers => |n| {
                if (!self.settled(now)) return .{};
                if (!self.announced) {
                    log.info("plan: every command acknowledged ({d}); waiting for {d} marker(s)", .{ now.sent, n });
                    self.announced = true;
                }
                if (now.markers == n) {
                    log.info("plan: {d} marker(s) seen", .{n});
                    self.advance();
                }
            },
            .loop => {
                self.plan_index = 0;
                self.plan_left = 0;
                return self.planned();
            },
            .leave => if (self.settled(now) and !self.left) {
                log.info("plan: every command acknowledged ({d}); leaving", .{now.sent});
                self.left = true;
                self.client.leave();
            },
        }
        return .{};
    }

    /// The previous step's input is over: the stop has been sent, and the server has
    /// applied everything this view sent.
    fn settled(self: *const Connected, now: markers.Status) bool {
        return self.client.sent_intent.eql(.{}) and !now.pending();
    }

    fn advance(self: *Connected) void {
        self.plan_index += 1;
        self.plan_left = 0;
        self.announced = false;
    }
};

/// The loaded packages as compatibility compares them: each in load order with its version
/// and the size and SHA-256 of the exact bytes loaded. Two hosts that loaded anything
/// different are refused by catalogue and first difference before they share a marker.
const Described = struct {
    packages: []net.compatibility.Package,
    attestation: [32]u8,

    fn value(self: *const Described, engine: *app.Engine) net.compatibility.Description {
        return .{
            .application = data.contentId("sandbox:application") catch unreachable,
            .application_revision = markers.protocol_revision,
            .tick_rate_millihertz = @intCast(@divTrunc(std.time.ns_per_s * 1000, @as(u64, @intCast(engine.step_delta.ns)))),
            .compatibility_id = self.attestation,
            .packages = self.packages,
        };
    }

    fn deinit(self: *Described, gpa: std.mem.Allocator) void {
        gpa.free(self.packages);
    }
};

fn describeContent(gpa: std.mem.Allocator, os: *platform.os.Os, packages: []const mod.Entry) error{ OutOfMemory, PackageUnreadable, NoContent }!Described {
    if (packages.len == 0) return error.NoContent;
    const out = try gpa.alloc(net.compatibility.Package, packages.len);
    errdefer gpa.free(out);
    for (packages, out) |entry, *package| {
        const read = os.readFileConfined(gpa, entry.base_dir, entry.file, 256 << 20) catch {
            log.err("package '{s}' could not be read to describe it", .{entry.name});
            return error.PackageUnreadable;
        };
        defer gpa.free(read.bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(read.bytes, &digest, .{});
        package.* = .{
            .id = entry.id,
            .version = .{ .major = entry.version },
            .byte_count = read.bytes.len,
            .sha256 = digest,
        };
    }
    // What the catalogue cannot see, attested: this application and this protocol. The
    // sandbox loads no native code, and its scripts are inside the packages hashed above.
    var attestation: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("foundry-sandbox shared markers, protocol 1", &attestation, .{});
    return .{ .packages = out, .attestation = attestation };
}

// -- tests --------------------------------------------------------------------------------

const testing = std.testing;

test "the command line has three modes and no insecure one" {
    try testing.expectEqual(Mode.offline, (try parseArgs(&.{"sandbox"})).mode);
    const serve = try parseArgs(&.{ "sandbox", "--serve", "127.0.0.1:7777", "--credentials", "a.txt" });
    try testing.expectEqual(Mode.serve, serve.mode);
    try testing.expectEqual(@as(u16, 7777), serve.endpoint.port);
    try testing.expectEqualStrings("a.txt", serve.credentials);
    try testing.expectEqual(Mode.join, (try parseArgs(&.{ "sandbox", "--credentials", "a", "--join", "10.0.0.1:1" })).mode);

    try testing.expectError(error.Usage, parseArgs(&.{ "sandbox", "--serve", "127.0.0.1:7777" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "sandbox", "--credentials", "a" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "sandbox", "--serve", "localhost:7777", "--credentials", "a" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "sandbox", "--serve", "127.0.0.1:1", "--join", "127.0.0.1:1", "--credentials", "a" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "sandbox", "--insecure", "yes" }));
    try testing.expectError(error.Usage, parseArgs(&.{ "sandbox", "--serve" }));
    try testing.expectError(error.Help, parseArgs(&.{ "sandbox", "--help" }));
}

test "a plan is directions, waits and a leave" {
    var storage: [max_plan_steps]PlanStep = undefined;
    const plan = try parsePlan("right:40, await:3,down:2,leave", &storage);
    try testing.expectEqual(@as(usize, 4), plan.len);
    try testing.expectEqual(@as(i8, 1), plan[0].hold.intent.dx);
    try testing.expectEqual(@as(u32, 3), plan[1].await_markers);
    try testing.expectEqual(@as(i8, -1), plan[2].hold.intent.dy);
    try testing.expect(plan[3] == .leave);
    try testing.expectError(error.PlanMalformed, parsePlan("sideways:3", &storage));
    try testing.expectError(error.PlanMalformed, parsePlan("right", &storage));
    try testing.expect((try parsePlan("right:3,left:3,loop", &storage))[2] == .loop);
    try testing.expectError(error.PlanMalformed, parsePlan("loop", &storage));
    try testing.expectError(error.PlanMalformed, parsePlan("loop,right:3", &storage));
}
