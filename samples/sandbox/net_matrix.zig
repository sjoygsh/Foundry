//! M16 Step 7: refusal, authority and replay, through the sandbox's own consumer.
//!
//! Steps 2–5 proved the transport, the service and the table one layer at a time. This file
//! proves what an application built on them does when the other side is hostile, broken or
//! slow: the shared markers (`markers`, the header-only consumer the sandbox runs) against
//! forged commands, a lying server, revoked, rotated, unknown and replayed credentials and
//! records, a stalled and a flooding peer, and a replay of everything a session admitted.
//!
//! One `net.Service` holds a server grant and several client grants over the memory carrier,
//! so a single deterministic process is every end of a session. Honest views are `markers`
//! consumers; hostile ones are raw table calls on the same channels, so they negotiate as an
//! honest peer does and then misbehave. The host (this file) drains the table's one event
//! queue and offers each event to the consumer it belongs to, as `Markers.frame` documents.

const std = @import("std");
const core = @import("core");
const net = @import("net");
const abi = @import("abi");
const platform = @import("platform");
const identities = @import("identities");
const markers = @import("markers");
const c = @import("foundry_api").c;

const transport = platform.transport;
const Transport = transport.Transport;
const ContentId = core.ContentId;
const testing = std.testing;
const ms = std.time.ns_per_ms;

const civil_now: i64 = 1789948800;
const server_name = "server.foundry.test";
const tick_ns: u64 = std.time.ns_per_s / 60;

const serve = ContentId.fromString("matrix:serve");
const joins = [_]ContentId{
    ContentId.fromString("matrix:join1"),
    ContentId.fromString("matrix:join2"),
    ContentId.fromString("matrix:join3"),
    ContentId.fromString("matrix:join4"),
};
const stranger = ContentId.fromString("matrix:stranger");
const published = [_]ContentId{ serve, joins[0], joins[1], joins[2], joins[3], stranger };

const settings: markers.Settings = .{};

const Pki = struct {
    root: identities.Authority,
    server: identities.Identity,
    rotated: identities.Identity,
    players: [4]identities.Identity,
    unknown: identities.Identity,
};

/// A peer that speaks the protocol's channels through raw table calls, and can say anything.
const Raw = struct {
    session: c.FoundryNetSession = .{ .bits = 0 },
    peer: c.FoundryNetPeer = .{ .bits = 0 },
    participant: u32 = 0,
    active: bool = false,
    ended: bool = false,
    baseline_sent: bool = false,
};

const Rig = struct {
    t: *Transport,
    service: *net.Service,
    host: abi.Host,
    pki: *Pki,
    api: *const markers.Api,
    now: u64 = ms,
    server: ?markers.Markers = null,
    clients: [5]?markers.Markers = @splat(null),
    intents: [5]markers.Intent = @splat(.{}),
    raws: [2]Raw = @splat(.{}),
    server_intent: markers.Intent = .{},
    /// Every lifecycle event and batch the server consumer saw, in order, for replay.
    log: std.ArrayList(Input) = .empty,
    states: std.ArrayList([markers.max_state_bytes]u8) = .empty,
    sizes: std.ArrayList(u32) = .empty,
    record: bool = false,

    const Input = union(enum) {
        spawn: u32,
        remove: u32,
        command: struct { participant: u32, number: u64, bytes: [markers.command_bytes]u8, len: u8 },
        /// A tick, and the server's own intent for it.
        tick: markers.Intent,
    };

    fn init() !*Rig {
        var limits: net.limits.Limits = .{};
        limits.sessions = 8;
        limits.handshake_starts_per_second = 1000;
        limits.handshake_start_burst = 1000;
        limits.handshake_starts_per_source_per_second = 1000;
        limits.handshake_start_per_source_burst = 1000;
        var options = net.service.transportOptions(limits, .memory);
        options.max_credentials = 10;
        options.civil_clock = .{ .fixed = civil_now };
        const t = try Transport.init(testing.allocator, options);
        errdefer t.deinit();

        const pki = try testing.allocator.create(Pki);
        errdefer testing.allocator.destroy(pki);
        const from = "20260601000000";
        const not_after = "20270601000000";
        try identities.ok(identities.foundry_test_authority_create(&pki.root, null, "CN=Matrix Root,O=Foundry Test", 1));
        try identities.ok(identities.foundry_test_issue(&pki.server, &pki.root, "CN=matrix server,O=Foundry Test", server_name, identities.server_auth, 10, from, not_after));
        try identities.ok(identities.foundry_test_issue(&pki.rotated, &pki.root, "CN=matrix server 2,O=Foundry Test", server_name, identities.server_auth, 11, from, not_after));
        for (&pki.players, 0..) |*player, i| {
            try identities.ok(identities.foundry_test_issue(player, &pki.root, "CN=player,O=Foundry Test", null, identities.client_auth, @intCast(20 + i), from, not_after));
        }
        try identities.ok(identities.foundry_test_issue(&pki.unknown, &pki.root, "CN=unknown,O=Foundry Test", null, identities.client_auth, 30, from, not_after));

        const endpoint = transport.Endpoint.loopback(7300);
        var grants: [6]net.service.Grant = undefined;
        grants[0] = .{ .id = serve, .role = .server, .endpoint = endpoint, .credentials = try t.createCredentials(.{
            .role = .server,
            .trust_roots = identities.pem(&pki.root.certificate),
            .certificate_chain = identities.pem(&pki.server.certificate),
            .private_key = identities.pem(&pki.server.private_key),
        }) };
        for (0..5) |i| {
            const who = if (i < 4) &pki.players[i] else &pki.unknown;
            grants[i + 1] = .{ .id = published[i + 1], .role = .client, .endpoint = endpoint, .credentials = try t.createCredentials(.{
                .role = .client,
                .trust_roots = identities.pem(&pki.root.certificate),
                .certificate_chain = identities.pem(&who.certificate),
                .private_key = identities.pem(&who.private_key),
                .server_name = server_name,
                .server_key = pki.server.key(),
            }) };
        }
        var allowed: [4]net.service.Identity = undefined;
        for (&allowed, 0..) |*entry, i| entry.* = .{ .key = pki.players[i].key(), .principal = @intCast(i + 1) };

        const service = try net.Service.init(testing.allocator, t, .{
            .limits = limits,
            .compatibility = .{
                .application = ContentId.fromString("matrix:app"),
                .application_revision = markers.protocol_revision,
                .tick_rate_millihertz = 60_000,
                .compatibility_id = @splat(0x5a),
            },
            .grants = &grants,
            .identities = &allowed,
            .first_epoch = 11,
        });
        errdefer service.deinit();

        const rig = try testing.allocator.create(Rig);
        rig.* = .{
            .t = t,
            .service = service,
            .host = .{ .net_service = service, .net_grants = &published },
            .pki = pki,
            .api = undefined,
        };
        rig.host.bind();
        rig.api = @ptrCast(@alignCast(abi.TableOf(abi.Host).getApi(abi.api_version_5).?));
        return rig;
    }

    fn deinit(self: *Rig) void {
        if (self.server) |*s| s.deinit();
        for (&self.clients) |*slot| if (slot.*) |*v| v.deinit();
        for (&self.raws) |raw| if (raw.session.bits != 0) {
            _ = self.api.net_session_close.?(raw.session);
        };
        self.log.deinit(testing.allocator);
        self.states.deinit(testing.allocator);
        self.sizes.deinit(testing.allocator);
        self.host.unbind();
        self.service.deinit();
        self.t.deinit();
        std.crypto.secureZero(u8, std.mem.asBytes(self.pki));
        testing.allocator.destroy(self.pki);
        testing.allocator.destroy(self);
    }

    fn startServer(self: *Rig) !void {
        self.server = try markers.Markers.initWith(self.api, .{ .grant = .{ .hash = serve.hash }, .settings = settings, .tick_ns = tick_ns, .draw = false });
    }

    fn join(self: *Rig, slot: usize, grant: ContentId) !void {
        self.clients[slot] = try markers.Markers.initWith(self.api, .{ .grant = .{ .hash = grant.hash }, .settings = settings, .tick_ns = tick_ns, .draw = false });
    }

    /// A raw client on `grant`, negotiating with the protocol's own channels.
    fn rawJoin(self: *Rig, slot: usize, grant: ContentId) !void {
        const raw = &self.raws[slot];
        raw.* = .{};
        try ok(self.api.net_session_create.?(.{ .hash = grant.hash }, &raw.session));
        for (&markers.channels()) |*desc| try ok(self.api.net_channel_register.?(raw.session, desc));
        try ok(self.api.net_session_connect.?(raw.session, &raw.peer));
    }

    /// A raw server on the serve grant, which says whatever the test tells it to.
    fn rawServe(self: *Rig, slot: usize) !void {
        const raw = &self.raws[slot];
        raw.* = .{};
        try ok(self.api.net_session_create.?(.{ .hash = serve.hash }, &raw.session));
        for (&markers.channels()) |*desc| try ok(self.api.net_channel_register.?(raw.session, desc));
        try ok(self.api.net_session_listen.?(raw.session));
    }

    /// One frame and one tick, the way the sandbox runs them: pump, events, deliveries,
    /// the server's step and every client's, pump.
    fn round(self: *Rig) void {
        self.pump();
        self.dispatch();
        for (&self.clients) |*slot| if (slot.*) |*v| v.receive();
        for (&self.raws) |*raw| self.rawReceive(raw);
        if (self.server) |*s| {
            s.step(self.server_intent);
            if (self.record) self.noteTick(s) catch @panic("record");
        }
        for (&self.clients, self.intents) |*slot, intent| if (slot.*) |*v| v.step(intent);
        self.pump();
    }

    fn rounds(self: *Rig, n: usize) void {
        for (0..n) |_| self.round();
    }

    /// Rounds until `done` holds, or fails after a bound.
    fn until(self: *Rig, comptime what: []const u8, context: anytype, comptime done: fn (@TypeOf(context), *Rig) bool) !void {
        for (0..3000) |_| {
            if (done(context, self)) return;
            self.round();
        }
        std.debug.print("never: {s}\n", .{what});
        return error.Timeout;
    }

    fn pump(self: *Rig) void {
        self.service.pump(self.now);
        self.now += 10 * ms;
    }

    fn dispatch(self: *Rig) void {
        var event: c.FoundryNetEvent = undefined;
        while (self.api.net_event_next.?(&event) == c.FOUNDRY_OK) {
            if (self.server) |*s| if (s.handle(event)) {
                if (self.record) self.noteEvent(event) catch @panic("record");
                continue;
            };
            var taken = false;
            for (&self.clients) |*slot| if (slot.*) |*v| {
                if (v.handle(event)) {
                    taken = true;
                    break;
                }
            };
            if (taken) continue;
            for (&self.raws) |*raw| if (raw.session.bits == event.session.bits) self.rawEvent(raw, event);
        }
    }

    fn rawEvent(_: *Rig, raw: *Raw, event: c.FoundryNetEvent) void {
        switch (event.kind) {
            c.FOUNDRY_NET_EVENT_ADMITTED => raw.participant = event.participant,
            c.FOUNDRY_NET_EVENT_ACTIVATED => {
                if (event.peer.bits == raw.peer.bits or raw.peer.bits == 0) raw.active = true;
                if (raw.peer.bits == 0) raw.peer = event.peer;
            },
            c.FOUNDRY_NET_EVENT_ENDED => raw.ended = true,
            else => {},
        }
    }

    /// A raw client acknowledges its baseline, so it becomes active and may send.
    fn rawReceive(self: *Rig, raw: *Raw) void {
        if (raw.session.bits == 0 or raw.ended) return;
        var info: c.FoundryNetSessionInfo = undefined;
        if (self.api.net_session_info.?(raw.session, &info) != c.FOUNDRY_OK or info.role != c.FOUNDRY_NET_CLIENT) return;
        var buffer: [markers.max_state_bytes]u8 = undefined;
        var needed: u64 = 0;
        var delivery: c.FoundryNetDelivery = undefined;
        while (self.api.net_delivery_take.?(raw.peer, &buffer, buffer.len, &needed, &delivery) == c.FOUNDRY_OK) {
            if (delivery.kind == c.FOUNDRY_NET_DELIVERY_BASELINE) {
                _ = self.api.net_baseline_acknowledge.?(raw.peer, delivery.sequence, delivery.tick);
            }
        }
    }

    fn rawSend(self: *Rig, raw: *const Raw, bytes: []const u8) !void {
        var number: u64 = 0;
        try ok(self.api.net_command_send.?(raw.peer, markers.moveChannel(), bytes.ptr, @intCast(bytes.len), &number));
    }

    fn noteEvent(self: *Rig, event: c.FoundryNetEvent) !void {
        switch (event.kind) {
            c.FOUNDRY_NET_EVENT_ACTIVATED => try self.log.append(testing.allocator, .{ .spawn = event.participant }),
            c.FOUNDRY_NET_EVENT_ENDED => if (event.participant != 0) try self.log.append(testing.allocator, .{ .remove = event.participant }),
            else => {},
        }
    }

    /// After the server's step: the batch it admitted, read back through the table exactly
    /// as the consumer read it, then the state it made.
    fn noteTick(self: *Rig, s: *markers.Markers) !void {
        for (0..s.batch_count) |i| {
            var command: c.FoundryNetCommand = undefined;
            try ok(self.api.net_batch_command.?(s.session, @intCast(i), &command));
            var entry: Input = .{ .command = .{ .participant = command.participant, .number = command.number, .bytes = @splat(0), .len = 0 } };
            var needed: u64 = 0;
            const copied = self.api.net_batch_copy.?(s.session, @intCast(i), &entry.command.bytes, markers.command_bytes, &needed);
            entry.command.len = if (copied == c.FOUNDRY_OK) @intCast(needed) else 0;
            try self.log.append(testing.allocator, entry);
        }
        try self.log.append(testing.allocator, .{ .tick = self.server_intent });
        var bytes: [markers.max_state_bytes]u8 = undefined;
        try self.sizes.append(testing.allocator, s.authority.encode(0, &bytes));
        try self.states.append(testing.allocator, bytes);
    }

    fn view(self: *Rig, slot: usize) *markers.Markers {
        return &self.clients[slot].?;
    }

    fn streamOf(self: *Rig, peer: c.FoundryNetPeer) transport.StreamHandle {
        return self.service.streamOf((abi.NetPeer{ .bits = peer.bits }).unwrap(net.service.PeerHandle)).?;
    }

    /// The server-side peer whose participant is `participant`.
    fn serverPeer(self: *Rig, participant: u32) ?c.FoundryNetPeer {
        const session = self.server.?.session;
        var cursor: c.FoundryCursor = .{ .bits = 0 };
        var peer: c.FoundryNetPeer = undefined;
        while (self.api.net_peer_next.?(session, &cursor, &peer) == c.FOUNDRY_OK) {
            var info: c.FoundryNetPeerInfo = undefined;
            if (self.api.net_peer_info.?(peer, &info) == c.FOUNDRY_OK and info.participant == participant) return peer;
        }
        return null;
    }
};

fn ok(result: c.FoundryResult) !void {
    if (result != c.FOUNDRY_OK) {
        std.debug.print("expected FOUNDRY_OK, got {d}\n", .{result});
        return error.NotOk;
    }
}

fn markerOf(v: *const markers.Markers, owner: u32) ?markers.Marker {
    for (v.shown()) |m| if (m.owner == owner) return m;
    return null;
}

fn active(slot: usize, rig: *Rig) bool {
    return rig.view(slot).phase == .active;
}

fn ended(slot: usize, rig: *Rig) bool {
    return rig.view(slot).phase == .ended;
}

fn serverHas(count: u32, rig: *Rig) bool {
    return rig.server.?.authority.objects.count == count;
}

fn viewHas(pair: [2]u32, rig: *Rig) bool {
    return rig.view(pair[0]).view.count == pair[1];
}

fn rawActive(slot: usize, rig: *Rig) bool {
    return rig.raws[slot].active;
}

// -- the matrix ----------------------------------------------------------------------------

test "forged commands move nothing, and a peer can move only its own marker" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.startServer();
    try rig.join(0, joins[0]);
    try rig.until("the honest client is active", @as(usize, 0), active);
    try rig.rawJoin(0, joins[1]);
    try rig.until("the raw client is active", @as(usize, 0), rawActive);
    try rig.until("the server holds three markers", @as(u32, 3), serverHas);

    const honest_before = markerOf(&rig.server.?, 1).?;
    const raw_before = markerOf(&rig.server.?, 2).?;
    // Out of range, reserved bytes set, short: none is an intent, and each is counted.
    try rig.rawSend(&rig.raws[0], &.{ 5, 0, 0, 0 });
    try rig.rawSend(&rig.raws[0], &.{ 1, 0, 1, 0 });
    try rig.rawSend(&rig.raws[0], &.{ 1, 0, 0 });
    rig.rounds(10);
    try testing.expectEqual(@as(u32, 3), rig.server.?.authority.rejected);
    try testing.expectEqual(raw_before.x, markerOf(&rig.server.?, 2).?.x);

    // A valid intent moves the sender's marker, and only the sender's: there is no field
    // in a command that could name another.
    try rig.rawSend(&rig.raws[0], &markers.encodeCommand(.{ .dx = 1 }));
    rig.rounds(20);
    try testing.expect(markerOf(&rig.server.?, 2).?.x > raw_before.x);
    try testing.expectEqual(honest_before.x, markerOf(&rig.server.?, 1).?.x);
    try testing.expectEqual(honest_before.y, markerOf(&rig.server.?, 1).?.y);
    // And the honest view saw it, from the server's state alone.
    try testing.expect(markerOf(rig.view(0), 2).?.x > raw_before.x);
    try testing.expect(!rig.raws[0].ended);
}

fn stateAt(x: f32, owner_marker: u32) [markers.max_state_bytes]u8 {
    var out: [markers.max_state_bytes]u8 = undefined;
    const list = [_]markers.Marker{
        .{ .number = 1, .owner = 0, .x = 0, .y = 0 },
        .{ .number = owner_marker, .owner = 1, .x = x, .y = 0 },
    };
    _ = markers.encodeState(&list, 0, &out);
    return out;
}

test "a lying server's state is refused whole, and the last complete view stands" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.rawServe(0);
    try rig.join(0, joins[0]);

    // Serve honestly until the view is active: a baseline, then activation.
    const raw = &rig.raws[0];
    const good = stateAt(10, 2);
    const size = markers.state_header_bytes + 2 * markers.marker_bytes;
    for (0..3000) |_| {
        if (rig.view(0).phase == .active) break;
        rig.round();
        var cursor: c.FoundryCursor = .{ .bits = 0 };
        var peer: c.FoundryNetPeer = undefined;
        while (rig.api.net_peer_next.?(raw.session, &cursor, &peer) == c.FOUNDRY_OK) {
            var info: c.FoundryNetPeerInfo = undefined;
            if (rig.api.net_peer_info.?(peer, &info) != c.FOUNDRY_OK) continue;
            if (info.state == c.FOUNDRY_NET_PEER_SYNCHRONIZING and !raw.baseline_sent) {
                try ok(rig.api.net_baseline_send.?(peer, 1, &good, size));
                raw.baseline_sent = true;
                raw.peer = peer;
            }
        }
    }
    try testing.expectEqual(markers.Phase.active, rig.view(0).phase);
    try testing.expectEqual(@as(f32, 10), markerOf(rig.view(0), 1).?.x);

    // Then lie: a marker far outside the arena.
    const bad = stateAt(1000, 2);
    try ok(rig.api.net_state_publish.?(raw.peer, 5, &bad, size));
    try rig.until("the view refuses and leaves", @as(usize, 0), ended);
    try testing.expectEqual(@as(u32, 1), rig.view(0).refused_states);
    try testing.expectEqual(@as(f32, 10), markerOf(rig.view(0), 1).?.x);
    try testing.expectEqual(@as(u64, 1), rig.view(0).view_tick);
}

test "a lying server cannot bring a removed marker back" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.rawServe(0);
    try rig.join(0, joins[0]);
    const raw = &rig.raws[0];
    const size2 = markers.state_header_bytes + 2 * markers.marker_bytes;
    const size1 = markers.state_header_bytes + markers.marker_bytes;
    const two = stateAt(0, 2);
    for (0..3000) |_| {
        if (rig.view(0).phase == .active) break;
        rig.round();
        var cursor: c.FoundryCursor = .{ .bits = 0 };
        var peer: c.FoundryNetPeer = undefined;
        while (rig.api.net_peer_next.?(raw.session, &cursor, &peer) == c.FOUNDRY_OK) {
            var info: c.FoundryNetPeerInfo = undefined;
            if (rig.api.net_peer_info.?(peer, &info) != c.FOUNDRY_OK) continue;
            if (info.state == c.FOUNDRY_NET_PEER_SYNCHRONIZING and !raw.baseline_sent) {
                try ok(rig.api.net_baseline_send.?(peer, 1, &two, size2));
                raw.baseline_sent = true;
                raw.peer = peer;
            }
        }
    }
    // Marker #2 goes, then comes back under the same number.
    var one: [markers.max_state_bytes]u8 = undefined;
    _ = markers.encodeState(&.{.{ .number = 1, .owner = 0, .x = 0, .y = 0 }}, 0, &one);
    try ok(rig.api.net_state_publish.?(raw.peer, 3, &one, size1));
    try rig.until("the view drops marker #2", [2]u32{ 0, 1 }, viewHas);
    try ok(rig.api.net_state_publish.?(raw.peer, 6, &two, size2));
    try rig.until("the view refuses and leaves", @as(usize, 0), ended);
    try testing.expectEqual(@as(u32, 1), rig.view(0).refused_states);
    try testing.expectEqual(@as(u32, 1), rig.view(0).view.count);
}

test "revoking a key and rotating the server's credentials end peers, and their markers go" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.startServer();
    try rig.join(0, joins[0]);
    try rig.join(1, joins[1]);
    try rig.until("both clients are active", @as(usize, 0), active);
    try rig.until("the second too", @as(usize, 1), active);
    try rig.until("three markers", @as(u32, 3), serverHas);

    const revoked = rig.view(0).participant;
    try testing.expect(rig.service.revoke(rig.pki.players[0].key()));
    try rig.until("the revoked client has ended", @as(usize, 0), ended);
    try rig.until("its marker is gone", @as(u32, 2), serverHas);
    try testing.expect(markerOf(&rig.server.?, revoked) == null);
    try testing.expect(markerOf(&rig.server.?, rig.view(1).participant) != null);
    // The other peer plays on and sees the removal.
    try rig.until("the other view sees two markers", [2]u32{ 1, 2 }, viewHas);
    try testing.expectEqual(markers.Phase.active, rig.view(1).phase);
    const before = rig.view(1).view_tick;
    rig.rounds(12);
    try testing.expect(rig.view(1).view_tick > before);

    // Rotation ends everyone; the server keeps serving its own marker.
    const rotated = try rig.t.createCredentials(.{
        .role = .server,
        .trust_roots = identities.pem(&rig.pki.root.certificate),
        .certificate_chain = identities.pem(&rig.pki.rotated.certificate),
        .private_key = identities.pem(&rig.pki.rotated.private_key),
    });
    try rig.service.replaceCredentials(serve, rotated);
    try rig.until("the last client has ended", @as(usize, 1), ended);
    try rig.until("only the server's marker is left", @as(u32, 1), serverHas);
    try testing.expectEqual(markers.Phase.serving, rig.server.?.phase);
    try testing.expectEqual(@as(u32, 2), rig.server.?.departed);
}

test "a key the server does not allow is refused before it is a participant" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.startServer();
    try rig.join(0, stranger);
    try rig.until("the stranger has ended", @as(usize, 0), ended);
    try testing.expectEqual(@as(u32, 0), rig.view(0).participant);
    try testing.expectEqual(@as(u32, 1), rig.server.?.authority.objects.count);
    try testing.expectEqual(@as(u32, 0), rig.server.?.departed);
    try testing.expect(rig.service.stats().denied >= 1);
}

test "a replayed TLS record ends only the connection it was replayed into" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.startServer();
    try rig.join(0, joins[0]);
    try rig.join(1, joins[1]);
    try rig.until("both clients are active", @as(usize, 0), active);
    try rig.until("the second too", @as(usize, 1), active);

    // Hold the server's end, so client 0's next command record waits on the wire whole.
    const stream = rig.streamOf(rig.view(0).peer);
    const server_stream = rig.streamOf(rig.serverPeer(rig.view(0).participant).?);
    rig.rounds(5);
    try rig.t.memoryStall(server_stream, true);
    rig.view(0).step(.{ .dx = 1 });
    rig.pump();
    var record: [512]u8 = undefined;
    const len = try rig.t.memoryInFlight(stream, &record);
    try testing.expect(len > 0);
    // Let it deliver and be applied, then replay the same bytes into the server's end.
    try rig.t.memoryStall(server_stream, false);
    rig.intents[0] = .{ .dx = 1 };
    rig.rounds(10);
    try testing.expect(markerOf(&rig.server.?, rig.view(0).participant).?.applied >= 1);
    try testing.expectEqual(len, try rig.t.memoryInjectInbound(server_stream, record[0..len]));
    try rig.until("the replaying connection has ended", @as(usize, 0), ended);
    try testing.expectEqual(markers.Phase.active, rig.view(1).phase);
    try rig.until("its marker is gone", @as(u32, 2), serverHas);
    const before = rig.view(1).view_tick;
    rig.rounds(12);
    try testing.expect(rig.view(1).view_tick > before);
}

test "a tampered record ends only that connection" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.startServer();
    try rig.join(0, joins[0]);
    try rig.join(1, joins[1]);
    try rig.until("both clients are active", @as(usize, 0), active);
    try rig.until("the second too", @as(usize, 1), active);

    // Hold the server's end so the record waits on the wire, then flip one bit of it.
    const server_stream = rig.streamOf(rig.serverPeer(rig.view(0).participant).?);
    rig.rounds(5);
    try rig.t.memoryStall(server_stream, true);
    rig.view(0).step(.{ .dy = 1 });
    rig.pump();
    try rig.t.memoryCorruptInbound(server_stream);
    try rig.t.memoryStall(server_stream, false);
    try rig.until("the tampering connection has ended", @as(usize, 0), ended);
    try testing.expectEqual(markers.Phase.active, rig.view(1).phase);
    try rig.until("its marker is gone", @as(u32, 2), serverHas);
}

test "a stalled client does not stall the server, and gets the newest state when it resumes" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.startServer();
    try rig.join(0, joins[0]);
    try rig.join(1, joins[1]);
    try rig.until("both clients are active", @as(usize, 0), active);
    try rig.until("the second too", @as(usize, 1), active);

    // Both ends of the link: the carrier moves nothing either way, as a stalled path would.
    const stream = rig.streamOf(rig.view(0).peer);
    const server_stream = rig.streamOf(rig.serverPeer(rig.view(0).participant).?);
    try rig.t.memoryStall(stream, true);
    try rig.t.memoryStall(server_stream, true);
    const stalled_at = rig.view(0).view_tick;
    const server_at = rig.server.?.tick;
    // Well inside the no-progress deadline: the server ticks on and the other view follows.
    rig.intents[1] = .{ .dx = 1 };
    rig.rounds(60);
    try testing.expectEqual(stalled_at, rig.view(0).view_tick);
    try testing.expectEqual(server_at + 60, rig.server.?.tick);
    try testing.expect(rig.view(1).view_tick > stalled_at + 30);

    try rig.t.memoryStall(stream, false);
    try rig.t.memoryStall(server_stream, false);
    rig.intents[1] = .{};
    rig.rounds(30);
    try testing.expectEqual(markers.Phase.active, rig.view(0).phase);
    // It catches up to the newest state, not through every one it missed.
    try testing.expect(rig.view(0).view_tick + 6 >= rig.server.?.tick);
    try testing.expectEqual(markerOf(rig.view(1), rig.view(1).participant).?.x, markerOf(rig.view(0), rig.view(1).participant).?.x);
    try testing.expect(rig.service.stats().states_replaced > 0);
}

test "a flooding peer is admitted its budget per tick, and a quiet peer still lands" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.startServer();
    try rig.join(0, joins[0]);
    try rig.until("the quiet client is active", @as(usize, 0), active);
    try rig.rawJoin(0, joins[1]);
    try rig.until("the flooding client is active", @as(usize, 0), rawActive);
    try rig.until("three markers", @as(u32, 3), serverHas);

    // Forty intents at once from the flood, one from the quiet peer.
    for (0..40) |i| try rig.rawSend(&rig.raws[0], &markers.encodeCommand(.{ .dx = if (i % 2 == 0) 1 else -1 }));
    rig.intents[0] = .{ .dy = 1 };
    rig.pump();
    rig.dispatch();
    rig.view(0).step(rig.intents[0]);
    const sent = rig.view(0).sent;
    rig.pump();
    rig.pump();

    // The first tick that admits anything admits the quiet peer's command beside at most
    // the budget of the flood's, in participant order.
    const limit = (net.limits.Limits{}).commands_per_peer_per_tick;
    var saw_quiet = false;
    for (0..20) |_| {
        rig.server.?.step(.{});
        const count = rig.server.?.batch_count;
        var from_flood: u32 = 0;
        for (0..count) |i| {
            var command: c.FoundryNetCommand = undefined;
            try ok(rig.api.net_batch_command.?(rig.server.?.session, @intCast(i), &command));
            if (command.participant == 2) from_flood += 1;
            if (command.participant == 1 and command.number == sent) saw_quiet = true;
        }
        try testing.expect(from_flood <= limit);
        if (saw_quiet) break;
        rig.pump();
    }
    try testing.expect(saw_quiet);
    try testing.expect(!rig.raws[0].ended);
}

test "replaying a session's admitted inputs rebuilds every state it sent, byte for byte" {
    var rig = try Rig.init();
    defer rig.deinit();
    rig.record = true;
    try rig.startServer();
    try rig.join(0, joins[0]);
    try rig.until("the first client is active", @as(usize, 0), active);

    // A session with everything in it: moves, a late join, a departure, a rejoin and the
    // server's own input.
    rig.intents[0] = .{ .dx = 1 };
    rig.rounds(25);
    try rig.join(1, joins[1]);
    rig.intents[0] = .{ .dy = -1 };
    rig.server_intent = .{ .dx = -1 };
    try rig.until("the second client is active", @as(usize, 1), active);
    rig.intents[1] = .{ .dx = -1, .dy = 1 };
    rig.rounds(30);
    rig.view(0).leave();
    rig.intents[1] = .{};
    rig.server_intent = .{};
    try rig.until("the first is gone", @as(u32, 2), serverHas);
    rig.view(0).deinit();
    rig.clients[0] = null;
    try rig.join(0, joins[0]);
    try rig.until("it rejoined", @as(usize, 0), active);
    rig.intents[0] = .{ .dy = 1 };
    rig.rounds(20);
    rig.record = false;

    // A fresh authority, fed the same inputs in the same order.
    var replay: markers.Authority = .init(&settings);
    var tick: usize = 0;
    for (rig.log.items) |input| switch (input) {
        .spawn => |p| _ = replay.spawn(p),
        .remove => |p| _ = replay.remove(p),
        .command => |cmd| _ = replay.command(cmd.participant, cmd.number, cmd.bytes[0..cmd.len]),
        .tick => |own| {
            replay.advance(own, @as(f32, @floatFromInt(tick_ns)) / 1e9);
            var bytes: [markers.max_state_bytes]u8 = undefined;
            const size = replay.encode(0, &bytes);
            try testing.expectEqualSlices(u8, rig.states.items[tick][0..rig.sizes.items[tick]], bytes[0..size]);
            tick += 1;
        },
    };
    try testing.expectEqual(rig.states.items.len, tick);
    try testing.expect(tick > 60);
    try testing.expectEqual(rig.server.?.authority.rejected, replay.rejected);
}

test "a pre-authentication flood is shed while active peers keep their state" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.startServer();
    try rig.join(0, joins[0]);
    try rig.until("the client is active", @as(usize, 0), active);

    // Connections that open and never finish a handshake, far more than the server holds.
    // They reach the carrier as streams and the service as pending work, and nowhere else.
    const endpoint = transport.Endpoint.loopback(7300);
    const credentials = try rig.t.createCredentials(.{
        .role = .client,
        .trust_roots = identities.pem(&rig.pki.root.certificate),
        .certificate_chain = identities.pem(&rig.pki.unknown.certificate),
        .private_key = identities.pem(&rig.pki.unknown.private_key),
        .server_name = server_name,
        .server_key = rig.pki.server.key(),
    });
    var opened: u32 = 0;
    for (0..24) |_| {
        _ = rig.t.connect(endpoint, credentials) catch break;
        opened += 1;
    }
    try testing.expect(opened > 0);

    const before = rig.view(0).view_tick;
    rig.intents[0] = .{ .dx = 1 };
    rig.rounds(90);
    try testing.expectEqual(markers.Phase.active, rig.view(0).phase);
    try testing.expect(rig.view(0).view_tick > before + 60);
    try testing.expect(markerOf(rig.view(0), rig.view(0).participant).?.applied >= 1);
    // The flood holds no more than the pending pool — the rest wait in the bounded backlog —
    // and the admission deadline clears it, admitting no one.
    const limits: net.limits.Limits = .{};
    try testing.expect(rig.service.stats().pending <= limits.pending_handshakes);
    rig.rounds(300);
    const stats = rig.service.stats();
    try testing.expect(stats.pending_timeouts >= limits.pending_handshakes);
    try testing.expectEqual(markers.Phase.active, rig.view(0).phase);
    try testing.expectEqual(@as(u16, 1), rig.server.?.status().peers);
    try testing.expectEqual(@as(u32, 2), rig.server.?.authority.objects.count);
}
