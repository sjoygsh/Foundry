//! M16 Step 3: sessions, and everything a connection passes through to become a peer.
//!
//! Each proof runs a server `net.Service` and one or more client services over one
//! `platform.Transport`, the way separate processes would, with identities generated for
//! the run (`fixtures/identities.zig`) and a monotonic clock the proof advances itself, so
//! every deadline is reached deterministically. The memory carrier is the network; one
//! proof repeats the join over real loopback sockets.
//!
//! A `Raw` client speaks FNET by hand over an authenticated stream. It is how a peer that
//! stalls, floods or breaks the protocol is made to exist: the service itself never
//! sends any of that.

const std = @import("std");
const core = @import("core");
const net = @import("net");
const platform = @import("platform");
const identities = @import("fixtures/identities.zig");

const transport = platform.transport;
const Transport = transport.Transport;
const CredentialsHandle = transport.CredentialsHandle;
const Service = net.Service;
const svc = net.service;
const Ending = svc.Ending;
const PeerHandle = svc.PeerHandle;
const SessionHandle = svc.SessionHandle;
const PeerState = svc.PeerState;
const Limits = net.limits.Limits;
const ContentId = core.ContentId;
const wire = net.wire;

const testing = std.testing;
const ms = std.time.ns_per_ms;
const none_index = std.math.maxInt(u16);

/// 2026-09-21T00:00:00Z, inside every leaf's validity; 2027-09-01, after all of them.
const civil_now: i64 = 1789948800;
const after_expiry: i64 = 1819843200;
const leaf_from = "20260601000000";
const leaf_until = "20270601000000";
const server_name = "server.foundry.test";

const server_endpoint = transport.Endpoint.loopback(7000);
const server_grant = ContentId.fromString("test:host");
const client_grant = ContentId.fromString("test:join");
const first_epoch: u64 = 41;

// -- identities -------------------------------------------------------------------------

const Pki = struct {
    root: identities.Authority,
    server: identities.Identity,
    replacement: identities.Identity,
    players: [3]identities.Identity,
    /// Issued by the trusted root for client use, and never admitted by the host.
    outsider: identities.Identity,

    fn create() !*Pki {
        const ok = identities.ok;
        const pki = try testing.allocator.create(Pki);
        errdefer testing.allocator.destroy(pki);
        try ok(identities.foundry_test_authority_create(&pki.root, null, "CN=Foundry Test Root,O=Foundry Test", 1));
        try ok(identities.foundry_test_issue(&pki.server, &pki.root, "CN=Foundry test server,O=Foundry Test", server_name, identities.server_auth, 10, leaf_from, leaf_until));
        try ok(identities.foundry_test_issue(&pki.replacement, &pki.root, "CN=Foundry test server,O=Foundry Test", server_name, identities.server_auth, 11, leaf_from, leaf_until));
        const names = [_][*:0]const u8{ "CN=player-one,O=Foundry Test", "CN=player-two,O=Foundry Test", "CN=player-three,O=Foundry Test" };
        for (&pki.players, names, 0..) |*player, name, index| {
            try ok(identities.foundry_test_issue(player, &pki.root, name, null, identities.client_auth, @intCast(20 + index), leaf_from, leaf_until));
        }
        try ok(identities.foundry_test_issue(&pki.outsider, &pki.root, "CN=outsider,O=Foundry Test", null, identities.client_auth, 30, leaf_from, leaf_until));
        return pki;
    }

    fn destroy(pki: *Pki) void {
        std.crypto.secureZero(u8, std.mem.asBytes(pki));
        testing.allocator.destroy(pki);
    }
};

fn clientCredentials(t: *Transport, pki: *const Pki, identity: *const identities.Identity, pin: transport.KeyFingerprint) !CredentialsHandle {
    return t.createCredentials(.{
        .role = .client,
        .trust_roots = identities.pem(&pki.root.certificate),
        .certificate_chain = identities.pem(&identity.certificate),
        .private_key = identities.pem(&identity.private_key),
        .server_name = server_name,
        .server_key = pin,
    });
}

fn serverCredentials(t: *Transport, pki: *const Pki, identity: *const identities.Identity) !CredentialsHandle {
    return t.createCredentials(.{
        .role = .server,
        .trust_roots = identities.pem(&pki.root.certificate),
        .certificate_chain = identities.pem(&identity.certificate),
        .private_key = identities.pem(&identity.private_key),
    });
}

// -- what both sides agree on -------------------------------------------------------------

const commands: net.channel.Descriptor = .{
    .id = ContentId.fromString("test:commands"),
    .revision = 1,
    .max_payload_bytes = 256,
    .direction = .client_to_server,
    .delivery = .reliable_ordered,
};
const state_channel: net.channel.Descriptor = .{
    .id = ContentId.fromString("test:state"),
    .revision = 1,
    .max_payload_bytes = 1024,
    .direction = .server_to_client,
    .delivery = .latest_complete_state,
};
const channels = [_]net.channel.Descriptor{ commands, state_channel };

const rules_inputs = [_]net.compatibility.Input{
    .{ .kind = .script_code, .id = ContentId.fromString("test:scripts/turn.lua"), .byte_count = 256, .sha256 = @splat(0x22) },
    .{ .kind = .gameplay_asset, .id = ContentId.fromString("test:rules.fdt"), .byte_count = 512, .sha256 = @splat(0x11) },
};
const packages = [_]net.compatibility.Package{
    .{ .id = ContentId.fromString("test:base"), .version = .{ .major = 1 }, .byte_count = 4096, .sha256 = @splat(0x33), .inputs = &rules_inputs },
    .{ .id = ContentId.fromString("test:extra"), .version = .{ .major = 2, .minor = 1 }, .byte_count = 1024, .sha256 = @splat(0x44) },
};
const description: net.compatibility.Description = .{
    .application = ContentId.fromString("test:app"),
    .application_revision = 3,
    .tick_rate_millihertz = 60_000,
    .compatibility_id = @splat(0x5a),
    .packages = &packages,
};

/// The reference envelope, with handshake starts relaxed so proofs can connect
/// repeatedly from one loopback address, and synchronization long enough that only a
/// proof about it reaches it. The proof about starts restores the real rates.
fn proofLimits() Limits {
    var limits: Limits = .{};
    limits.handshake_starts_per_second = 1000;
    limits.handshake_start_burst = 1000;
    limits.handshake_starts_per_source_per_second = 1000;
    limits.handshake_start_per_source_burst = 1000;
    limits.initial_sync_timeout_ms = 60_000;
    return limits;
}

// -- a world: one transport, one server, clients as separate services ----------------------

const WorldOptions = struct {
    limits: Limits = proofLimits(),
    memory: transport.MemoryOptions = .{},
};

const ClientOptions = struct {
    description: net.compatibility.Description = description,
    /// Registered in this order; the server registers them the other way round.
    channels: []const net.channel.Descriptor = &channels,
    limits: ?Limits = null,
    endpoint: transport.Endpoint = server_endpoint,
};

const Client = struct {
    service: *Service,
    session: SessionHandle,
    peer: PeerHandle = .none,
    /// A paused client is not pumped: a process that has stopped.
    paused: bool = false,

    fn connect(self: *Client) !void {
        self.peer = try self.service.connect(self.session);
    }

    fn state(self: *Client) ?PeerState {
        const info = self.service.peerInfo(self.peer) orelse return null;
        return info.state;
    }
};

const World = struct {
    t: *Transport,
    pki: *Pki,
    limits: Limits,
    server_credentials: CredentialsHandle,
    players: [3]CredentialsHandle,
    outsider: CredentialsHandle,
    server: *Service,
    session: SessionHandle,
    clients: [8]?*Client = @splat(null),
    now: u64 = ms,
    step: u64 = 10 * ms,
    rounds: u64 = 0,

    fn init(options: WorldOptions) !*World {
        var transport_options = svc.transportOptions(options.limits, .memory);
        transport_options.max_streams = 64;
        transport_options.max_listeners = 2;
        transport_options.max_credentials = 16;
        transport_options.civil_clock = .{ .fixed = civil_now };
        transport_options.memory = options.memory;
        const t = try Transport.init(testing.allocator, transport_options);
        errdefer t.deinit();
        const pki = try Pki.create();
        errdefer pki.destroy();

        const world = try testing.allocator.create(World);
        errdefer testing.allocator.destroy(world);
        world.* = .{
            .t = t,
            .pki = pki,
            .limits = options.limits,
            .server_credentials = try serverCredentials(t, pki, &pki.server),
            .players = undefined,
            .outsider = try clientCredentials(t, pki, &pki.outsider, pki.server.key()),
            .server = undefined,
            .session = undefined,
        };
        for (&world.players, &pki.players) |*credentials, *player| {
            credentials.* = try clientCredentials(t, pki, player, pki.server.key());
        }
        var allowed: [3]svc.Identity = undefined;
        for (&allowed, &pki.players, 0..) |*entry, *player, index| {
            entry.* = .{ .key = player.key(), .principal = @intCast(index + 1) };
        }
        world.server = try Service.init(testing.allocator, t, .{
            .limits = options.limits,
            .compatibility = description,
            .grants = &.{.{ .id = server_grant, .role = .server, .endpoint = server_endpoint, .credentials = world.server_credentials }},
            .identities = &allowed,
            .first_epoch = first_epoch,
        });
        errdefer world.server.deinit();
        world.session = try world.server.createSession(server_grant);
        try world.server.registerChannel(world.session, state_channel);
        try world.server.registerChannel(world.session, commands);
        try world.server.listen(world.session);
        return world;
    }

    fn deinit(self: *World) void {
        for (&self.clients) |*slot| {
            if (slot.*) |client| self.dropClient(client);
        }
        self.server.deinit();
        self.pki.destroy();
        self.t.deinit();
        testing.allocator.destroy(self);
    }

    fn addClient(self: *World, credentials: CredentialsHandle, options: ClientOptions) !*Client {
        const service = try Service.init(testing.allocator, self.t, .{
            .limits = options.limits orelse self.limits,
            .compatibility = options.description,
            .grants = &.{.{ .id = client_grant, .role = .client, .endpoint = options.endpoint, .credentials = credentials }},
        });
        errdefer service.deinit();
        const session = try service.createSession(client_grant);
        for (options.channels) |descriptor| try service.registerChannel(session, descriptor);
        const client = try testing.allocator.create(Client);
        client.* = .{ .service = service, .session = session };
        for (&self.clients) |*slot| {
            if (slot.* == null) {
                slot.* = client;
                return client;
            }
        }
        return error.TooManyClients;
    }

    fn dropClient(self: *World, client: *Client) void {
        for (&self.clients) |*slot| {
            if (slot.* == client) slot.* = null;
        }
        client.service.deinit();
        testing.allocator.destroy(client);
    }

    fn pump(self: *World, rounds: usize) void {
        for (0..rounds) |_| {
            self.server.pump(self.now);
            for (self.clients) |slot| {
                const client = slot orelse continue;
                if (!client.paused) client.service.pump(self.now);
            }
            self.now += self.step;
            self.rounds += 1;
        }
    }

    /// Pumps until `peer` of `service` is in `want`, or gone when `want` is null.
    fn until(self: *World, service: *Service, peer: PeerHandle, want: ?PeerState, rounds: usize) !void {
        for (0..rounds) |_| {
            const info = service.peerInfo(peer);
            if (want) |state| {
                if (info != null and info.?.state == state) return;
            } else if (info == null) return;
            self.pump(1);
        }
        return error.DidNotReach;
    }

    /// Pumps until `service` has an event, and returns it.
    fn event(self: *World, service: *Service, rounds: usize) !svc.Event {
        for (0..rounds) |_| {
            if (service.nextEvent()) |next| return next;
            self.pump(1);
        }
        return error.NoEvent;
    }

    /// Connects a client and pumps until both sides report its admission.
    fn join(self: *World, client: *Client) !struct { server: svc.Event, client: svc.Event } {
        try client.connect();
        try self.until(client.service, client.peer, .synchronizing, 2_000);
        return .{ .server = try admitted(try self.event(self.server, 10)), .client = try admitted(try self.event(client.service, 1)) };
    }
};

fn admitted(event: svc.Event) !svc.Event {
    return switch (event.kind) {
        .admitted => event,
        .ended => |ended| {
            std.debug.print("expected an admission, got an ending: {any}\n", .{ended.ending});
            return error.NotAdmitted;
        },
    };
}

fn departure(event: svc.Event) !svc.Departure {
    return switch (event.kind) {
        .ended => |value| value,
        .admitted => error.NotEnded,
    };
}

fn endingOf(world: *World, service: *Service) !Ending {
    return (try departure(try world.event(service, 2_000))).ending;
}

fn refusal(reason: wire.RefusalReason, detail: u16) wire.Refusal {
    return .{ .reason = reason, .detail_index = detail };
}

// -- a hand-driven client -------------------------------------------------------------------

const Raw = struct {
    world: *World,
    stream: transport.StreamHandle,
    sent: u64 = 0,
    storage: []u8,
    decoder: wire.Decoder,
    chunk: [16 * 1024]u8 = undefined,
    staged_start: usize = 0,
    staged_len: usize = 0,
    borrowed: bool = false,

    fn open(world: *World, credentials: CredentialsHandle) !*Raw {
        return adopt(world, try world.t.connect(server_endpoint, credentials));
    }

    /// Takes over a stream the proof opened or accepted itself.
    fn adopt(world: *World, stream: transport.StreamHandle) !*Raw {
        errdefer world.t.close(stream);
        const raw = try testing.allocator.create(Raw);
        errdefer testing.allocator.destroy(raw);
        const storage = try testing.allocator.alloc(u8, net.limits.wire_v1_max_frame_bytes);
        errdefer testing.allocator.free(storage);
        raw.* = .{
            .world = world,
            .stream = stream,
            .storage = storage,
            .decoder = try wire.Decoder.init(storage, net.limits.wire_v1_max_frame_bytes),
        };
        return raw;
    }

    fn close(self: *Raw) void {
        self.world.t.close(self.stream);
        testing.allocator.free(self.storage);
        testing.allocator.destroy(self);
    }

    fn establish(self: *Raw) !void {
        for (0..2_000) |_| {
            switch (try self.world.t.advance(self.stream)) {
                .established => return,
                .failed, .closed => return error.RawFailed,
                else => self.world.pump(1),
            }
        }
        return error.RawDidNotEstablish;
    }

    /// Hands every byte to the stream, pumping the world while it would block.
    fn write(self: *Raw, bytes: []const u8) !void {
        var sent: usize = 0;
        var rounds: usize = 0;
        while (sent < bytes.len) : (rounds += 1) {
            if (rounds > 20_000) return error.RawStalled;
            sent += try self.world.t.write(self.stream, bytes[sent..]);
            _ = try self.world.t.advance(self.stream);
            if (sent < bytes.len) self.world.pump(1);
        }
        _ = try self.world.t.advance(self.stream);
    }

    fn frame(self: *Raw, kind: wire.Kind, channel_id: u64, payload: []const u8) !void {
        var bytes: [wire.header_size + 128]u8 = undefined;
        const encoded = try wire.encodeFrame(&bytes, .{
            .kind = kind,
            .total_bytes = 0,
            .sequence = self.sent + 1,
            .channel_id = channel_id,
        }, payload, net.limits.wire_v1_max_frame_bytes);
        self.sent += 1;
        try self.write(encoded);
    }

    fn heartbeat(self: *Raw, epoch: u64, acknowledged: u64) !void {
        var payload: [wire.Heartbeat.encoded_size]u8 = undefined;
        try (wire.Heartbeat{ .session_epoch = epoch, .last_received_sequence = acknowledged }).encode(&payload);
        try self.frame(.heartbeat, 0, &payload);
    }

    /// Sends exactly what a matching client sends.
    fn negotiate(self: *Raw) !void {
        return self.negotiateClaiming(null);
    }

    /// The same, but finishing with a catalogue digest that disagrees with the entries.
    fn negotiateClaiming(self: *Raw, catalogue_digest: ?[32]u8) !void {
        var frozen = try net.compatibility.freeze(testing.allocator, description, self.world.limits);
        defer frozen.deinit(testing.allocator);
        var sorted = channels;
        const channel_digest = net.compatibility.freezeChannels(&sorted);
        var hello: [wire.ClientHello.encoded_size]u8 = undefined;
        try (wire.ClientHello{
            .application_id = frozen.application,
            .application_revision = frozen.application_revision,
            .tick_rate_millihertz = frozen.tick_rate_millihertz,
            .compatibility_id = frozen.compatibility_id,
            .catalogue_count = @intCast(frozen.items.len),
            .channel_count = sorted.len,
        }).encode(&hello);
        try self.frame(.client_hello, 0, &hello);
        var item: [wire.CompatibilityItem.encoded_size]u8 = undefined;
        for (frozen.items) |entry| {
            try entry.encode(&item);
            try self.frame(.compatibility_item, 0, &item);
        }
        var descriptor: [wire.ChannelPayload.encoded_size]u8 = undefined;
        for (sorted) |entry| {
            try wire.ChannelPayload.encode(entry, &descriptor);
            try self.frame(.channel_descriptor, 0, &descriptor);
        }
        var finished: [wire.NegotiationFinished.encoded_size]u8 = undefined;
        try (wire.NegotiationFinished{ .catalogue_digest = catalogue_digest orelse frozen.digest, .channel_digest = channel_digest }).encode(&finished);
        try self.frame(.negotiation_finished, 0, &finished);
    }

    /// The next frame the server sent, borrowed until the next call.
    fn next(self: *Raw) !wire.Frame {
        if (self.borrowed) {
            self.decoder.consumeFrame();
            self.borrowed = false;
        }
        for (0..5_000) |_| {
            while (self.staged_len > 0) {
                const progress = try self.decoder.feed(self.chunk[self.staged_start..][0..self.staged_len]);
                self.staged_start += progress.consumed;
                self.staged_len -= progress.consumed;
                if (progress.frame) |ready| {
                    self.borrowed = true;
                    return ready;
                }
            }
            _ = try self.world.t.advance(self.stream);
            switch (try self.world.t.read(self.stream, &self.chunk)) {
                .data => |count| {
                    self.staged_start = 0;
                    self.staged_len = count;
                },
                .would_block => self.world.pump(1),
                .closed => return error.RawClosed,
            }
        }
        return error.NoFrame;
    }
};

// -- the proofs -----------------------------------------------------------------------------

test "a service refuses what its grants, roles and state do not allow" {
    const world = try World.init(.{});
    defer world.deinit();
    const client = try world.addClient(world.players[0], .{});

    try testing.expectError(error.WrongRole, world.server.connect(world.session));
    try testing.expectError(error.WrongRole, client.service.listen(client.session));
    try testing.expectError(error.GrantInUse, world.server.createSession(server_grant));
    try testing.expectError(error.UnknownGrant, world.server.createSession(ContentId.fromString("test:nowhere")));
    try testing.expectError(error.AlreadyRunning, world.server.listen(world.session));
    try testing.expectError(error.ChannelsFrozen, world.server.registerChannel(world.session, commands));

    try testing.expectError(error.DuplicateChannel, client.service.registerChannel(client.session, commands));
    var second_state = state_channel;
    second_state.id = ContentId.fromString("test:other_state");
    try testing.expectError(error.TooManyStateChannels, client.service.registerChannel(client.session, second_state));

    const bare = try world.addClient(world.players[1], .{ .channels = &.{} });
    try testing.expectError(error.NoChannels, bare.service.connect(bare.session));

    try client.connect();
    try testing.expectError(error.AlreadyConnected, client.service.connect(client.session));
    try testing.expectError(error.ChannelsFrozen, client.service.registerChannel(client.session, second_state));

    try testing.expectEqual(@as(?svc.PeerInfo, null), world.server.peerInfo(.none));
    try testing.expectError(error.InvalidHandle, world.server.disconnect(.none, .closed));
    try testing.expectError(error.InvalidHandle, world.server.registerChannel(.none, commands));
    try testing.expectEqual(@as(?svc.SessionInfo, null), world.server.sessionInfo(.none));

    // What a consumer may see of a grant is its name, role and endpoint.
    const grant = world.server.grantAt(0).?;
    try testing.expect(grant.id.eql(server_grant));
    try testing.expectEqual(svc.Role.server, grant.role);
    try testing.expectEqual(@as(?svc.GrantInfo, null), world.server.grantAt(1));
}

test "a matching client is admitted, and a reconnect is a fresh participant" {
    // Whole transfers, then seven bytes at a time through a 512-byte pipe.
    const carriers = [_]transport.MemoryOptions{ .{}, .{ .capacity = 512, .max_transfer = 7 } };
    for (carriers) |memory| {
        const world = try World.init(.{ .memory = memory });
        defer world.deinit();
        world.step = ms;
        const client = try world.addClient(world.players[0], .{});

        const first = try world.join(client);
        const on_server = first.server.kind.admitted;
        try testing.expectEqual(@as(u32, 1), on_server.participant);
        try testing.expectEqual(@as(u32, 1), on_server.principal);
        try testing.expectEqual(first_epoch, on_server.epoch);
        const on_client = first.client.kind.admitted;
        try testing.expect(first.client.peer.eql(client.peer));
        try testing.expectEqual(@as(u32, 1), on_client.participant);
        try testing.expectEqual(first_epoch, on_client.epoch);
        try testing.expectEqual(@as(u32, 0), on_client.principal);

        const server_peer = first.server.peer;
        const info = world.server.peerInfo(server_peer).?;
        try testing.expectEqual(PeerState.synchronizing, info.state);
        try testing.expectEqual(@as(u32, 1), info.participant);
        try testing.expectEqual(@as(u16, 1), world.server.sessionInfo(world.session).?.peers);
        var listed: [4]PeerHandle = undefined;
        try testing.expectEqual(@as(usize, 1), world.server.sessionPeers(world.session, &listed));
        try testing.expect(listed[0].eql(server_peer));

        // The client leaves, and says so.
        const old_client_peer = client.peer;
        try client.service.disconnect(client.peer, .closed);
        try testing.expectEqual(Ending{ .local = .closed }, (try departure(client.service.nextEvent().?)).ending);
        const left = try departure(try world.event(world.server, 2_000));
        try testing.expectEqual(Ending{ .peer_disconnected = .closed }, left.ending);
        try testing.expectEqual(@as(u32, 1), left.participant);
        try testing.expectEqual(@as(u32, 1), left.principal);
        try world.until(client.service, old_client_peer, null, 2_000);

        // Coming back is a new participant through new handles; the old ones stay stale.
        const second = try world.join(client);
        try testing.expectEqual(@as(u32, 2), second.server.kind.admitted.participant);
        try testing.expectEqual(@as(u32, 2), second.client.kind.admitted.participant);
        try testing.expect(!second.server.peer.eql(server_peer));
        try testing.expectEqual(@as(?svc.PeerInfo, null), world.server.peerInfo(server_peer));
        try testing.expectEqual(@as(?svc.PeerInfo, null), client.service.peerInfo(old_client_peer));
        try testing.expectEqual(@as(u64, 2), world.server.stats().admitted);
    }
}

test "every compatibility difference is refused, and named by the side that refused it" {
    const world = try World.init(.{});
    defer world.deinit();

    // Canonical orders: base, its gameplay asset, its script, extra; channels by ID.
    var sorted = channels;
    _ = net.compatibility.freezeChannels(&sorted);
    const state_index: u16 = if (sorted[0].id.eql(state_channel.id)) 0 else 1;
    const commands_index: u16 = 1 - state_index;

    var other_application = description;
    other_application.application = ContentId.fromString("test:other_app");
    var other_revision = description;
    other_revision.application_revision += 1;
    var other_tick = description;
    other_tick.tick_rate_millihertz = 30_000;
    var other_attestation = description;
    other_attestation.compatibility_id = @splat(0x5b);

    var changed_package = packages;
    changed_package[1].sha256[0] ^= 1;
    var package_changed = description;
    package_changed.packages = &changed_package;

    var changed_inputs = rules_inputs;
    changed_inputs[0].byte_count += 1;
    var input_packages = packages;
    input_packages[0].inputs = &changed_inputs;
    var input_changed = description;
    input_changed.packages = &input_packages;

    var fewer_packages = packages;
    fewer_packages[0].inputs = rules_inputs[0..1];
    var input_missing = description;
    input_missing.packages = &fewer_packages;

    const reordered_packages = [_]net.compatibility.Package{ packages[1], packages[0] };
    var reordered = description;
    reordered.packages = &reordered_packages;

    var newer_state = state_channel;
    newer_state.revision = 2;
    var smaller_commands = commands;
    smaller_commands.max_payload_bytes = 128;

    const Case = struct {
        description: net.compatibility.Description = description,
        channels: []const net.channel.Descriptor = &channels,
        expected: wire.Refusal,
    };
    const cases = [_]Case{
        .{ .description = other_application, .expected = refusal(.application, none_index) },
        .{ .description = other_revision, .expected = refusal(.application, none_index) },
        .{ .description = other_tick, .expected = refusal(.compatibility, none_index) },
        .{ .description = other_attestation, .expected = refusal(.compatibility, none_index) },
        .{ .description = package_changed, .expected = refusal(.catalogue, 3) },
        .{ .description = input_changed, .expected = refusal(.catalogue, 2) },
        .{ .description = input_missing, .expected = refusal(.catalogue, none_index) },
        .{ .description = reordered, .expected = refusal(.catalogue, 0) },
        .{ .channels = &.{ commands, newer_state }, .expected = refusal(.channel, state_index) },
        .{ .channels = &.{ smaller_commands, state_channel }, .expected = refusal(.channel, commands_index) },
        .{ .channels = &.{commands}, .expected = refusal(.channel, none_index) },
    };

    for (cases) |case| {
        const client = try world.addClient(world.players[0], .{ .description = case.description, .channels = case.channels });
        try client.connect();
        try testing.expectEqual(Ending{ .refused = case.expected }, try endingOf(world, world.server));
        try testing.expectEqual(Ending{ .refused_by_peer = case.expected }, try endingOf(world, client.service));
        world.dropClient(client);
        world.pump(5);
    }
    try testing.expectEqual(@as(u64, cases.len), world.server.stats().refused);

    // No refusal took a participant number.
    const matching = try world.addClient(world.players[0], .{});
    const joined = try world.join(matching);
    try testing.expectEqual(@as(u32, 1), joined.server.kind.admitted.participant);
}

test "an identity is admitted only while it is allowed, and only once at a time" {
    const world = try World.init(.{});
    defer world.deinit();

    // Trusted by the root, never admitted by this host: refused after TLS, with no event.
    const stranger = try world.addClient(world.outsider, .{});
    try stranger.connect();
    try testing.expectEqual(Ending{ .refused_by_peer = refusal(.policy, none_index) }, try endingOf(world, stranger.service));
    try testing.expectEqual(@as(u64, 1), world.server.stats().denied);
    try testing.expectEqual(@as(?svc.Event, null), world.server.nextEvent());
    world.dropClient(stranger);

    const first = try world.addClient(world.players[0], .{});
    _ = try world.join(first);

    // One principal, one connection: a second is refused and the first carries on.
    const again = try world.addClient(world.players[0], .{});
    try again.connect();
    try testing.expectEqual(Ending{ .refused_by_peer = refusal(.policy, none_index) }, try endingOf(world, again.service));
    try testing.expectEqual(@as(u64, 1), world.server.stats().duplicates);
    world.dropClient(again);
    try testing.expectEqual(PeerState.synchronizing, first.state().?);

    const second = try world.addClient(world.players[1], .{});
    _ = try world.join(second);

    // An invalid replacement is refused whole and the last valid allowlist stays.
    const one = world.pki.players[0].key();
    const two = world.pki.players[1].key();
    try testing.expectError(error.DuplicateIdentity, world.server.replaceAllowlist(&.{ .{ .key = one, .principal = 1 }, .{ .key = one, .principal = 9 } }));
    world.pump(20);
    try testing.expectEqual(PeerState.synchronizing, first.state().?);
    try testing.expectEqual(PeerState.synchronizing, second.state().?);

    // Withdrawing a key ends its live peer on both sides, and only that peer.
    try testing.expect(world.server.revoke(one));
    const revoked = try departure(world.server.nextEvent().?);
    try testing.expectEqual(Ending.revoked, revoked.ending);
    try testing.expectEqual(@as(u32, 1), revoked.principal);
    try testing.expectEqual(Ending{ .peer_disconnected = .policy }, try endingOf(world, first.service));
    try testing.expectEqual(PeerState.synchronizing, second.state().?);

    // A key remapped to another principal ends too: the participant was the old one's.
    try world.server.replaceAllowlist(&.{.{ .key = two, .principal = 7 }});
    try testing.expectEqual(Ending.revoked, (try departure(world.server.nextEvent().?)).ending);
    try testing.expectEqual(Ending{ .peer_disconnected = .policy }, try endingOf(world, second.service));

    // The withdrawn key cannot come back; the remapped one comes back as its new principal.
    try first.connect();
    try testing.expectEqual(Ending{ .refused_by_peer = refusal(.policy, none_index) }, try endingOf(world, first.service));
    const back = try world.join(second);
    try testing.expectEqual(@as(u32, 7), back.server.kind.admitted.principal);
    try testing.expectEqual(@as(u32, 3), back.server.kind.admitted.participant);
}

test "handshakes are bounded before anyone is authenticated" {
    {
        var limits = proofLimits();
        limits.pending_handshakes = 2;
        const world = try World.init(.{ .limits = limits });
        defer world.deinit();
        const player = try world.addClient(world.players[0], .{});
        _ = try world.join(player);
        const streams_before = world.t.stats().streams;
        const accepted_before = world.server.stats().accepted;

        // Three clients that connect and never say anything: two fill the pending pool,
        // the third is taken and closed at once. A pump accepts at most as many as the
        // pool holds, so the third is taken on the second.
        var stalled: [3]transport.StreamHandle = undefined;
        for (&stalled) |*stream| stream.* = try world.t.connect(server_endpoint, world.players[2]);
        world.pump(1);
        try testing.expectEqual(accepted_before + 2, world.server.stats().accepted);
        world.pump(1);
        var stats = world.server.stats();
        try testing.expectEqual(accepted_before + 3, stats.accepted);
        try testing.expectEqual(@as(u32, 2), stats.pending);
        try testing.expectEqual(@as(u64, 1), stats.shed.pending_full);

        // They hold nothing past the admission deadline, and never became peers.
        world.pump(510);
        stats = world.server.stats();
        try testing.expectEqual(@as(u32, 0), stats.pending);
        try testing.expectEqual(@as(u64, 2), stats.pending_timeouts);
        try testing.expectEqual(@as(?svc.Event, null), world.server.nextEvent());
        try testing.expectEqual(PeerState.synchronizing, player.state().?);
        for (stalled) |stream| world.t.close(stream);
        try testing.expectEqual(streams_before, world.t.stats().streams);
    }
    {
        // The reference rates: two starts per source per second, burst two.
        var limits = proofLimits();
        const reference: Limits = .{};
        limits.handshake_starts_per_source_per_second = reference.handshake_starts_per_source_per_second;
        limits.handshake_start_per_source_burst = reference.handshake_start_per_source_burst;
        limits.handshake_starts_per_second = reference.handshake_starts_per_second;
        limits.handshake_start_burst = reference.handshake_start_burst;
        const world = try World.init(.{ .limits = limits });
        defer world.deinit();

        var streams: [4]transport.StreamHandle = undefined;
        for (streams[0..3]) |*stream| stream.* = try world.t.connect(server_endpoint, world.players[2]);
        world.pump(1);
        var stats = world.server.stats();
        try testing.expectEqual(@as(u32, 2), stats.pending);
        try testing.expectEqual(@as(u64, 1), stats.shed.source_rate);

        // Half a second restores exactly one start.
        world.step = 500 * ms;
        world.pump(1);
        streams[3] = try world.t.connect(server_endpoint, world.players[2]);
        world.step = ms;
        world.pump(1);
        stats = world.server.stats();
        try testing.expectEqual(@as(u32, 3), stats.pending);
        try testing.expectEqual(@as(u64, 1), stats.shed.source_rate);
        for (streams) |stream| world.t.close(stream);
    }
}

test "deadlines end what stops making progress, and heartbeats keep an idle peer" {
    {
        // Idle but alive: thirty seconds of nothing but heartbeats.
        const world = try World.init(.{});
        defer world.deinit();
        world.step = 100 * ms;
        const client = try world.addClient(world.players[0], .{});
        const joined = try world.join(client);
        const before = world.server.stats().frames_received;
        world.pump(300);
        try testing.expectEqual(PeerState.synchronizing, client.state().?);
        try testing.expectEqual(PeerState.synchronizing, world.server.peerInfo(joined.server.peer).?.state);
        try testing.expect(world.server.stats().frames_received - before >= 10);

        // A client that stops is ended once nothing complete has arrived for the timeout.
        client.paused = true;
        try testing.expectEqual(Ending{ .timed_out = .no_progress }, try endingOf(world, world.server));
        client.paused = false;
        try testing.expectEqual(Ending{ .peer_disconnected = .timeout }, try endingOf(world, client.service));
    }
    {
        // Admitted but never given its initial state, which Step 4 delivers.
        var limits = proofLimits();
        limits.initial_sync_timeout_ms = 5_000;
        const world = try World.init(.{ .limits = limits });
        defer world.deinit();
        world.step = 100 * ms;
        const client = try world.addClient(world.players[0], .{});
        _ = try world.join(client);
        try testing.expectEqual(Ending{ .timed_out = .initial_sync }, try endingOf(world, world.server));
        const client_ending = try endingOf(world, client.service);
        try testing.expect(std.meta.eql(client_ending, Ending{ .peer_disconnected = .timeout }) or
            std.meta.eql(client_ending, Ending{ .timed_out = .initial_sync }));
    }
    {
        // Authenticated and silent: refused at the admission deadline, and told why.
        const world = try World.init(.{});
        defer world.deinit();
        world.step = 100 * ms;
        const raw = try Raw.open(world, world.players[0]);
        defer raw.close();
        try raw.establish();
        world.pump(60);
        try testing.expectEqual(Ending{ .timed_out = .admission }, try endingOf(world, world.server));
        const told = try raw.next();
        try testing.expectEqual(wire.Kind.refusal, told.header.kind);
        try testing.expectEqual(wire.RefusalReason.timeout, (try wire.Refusal.decode(told.payload)).reason);
    }
    {
        // Talking but not reading: the server's output backs up and the write stalls.
        const world = try World.init(.{ .memory = .{ .capacity = 512 } });
        defer world.deinit();
        world.step = 100 * ms;
        const raw = try Raw.open(world, world.players[0]);
        defer raw.close();
        try raw.establish();
        try raw.negotiate();
        _ = try admitted(try world.event(world.server, 50));
        var ending: ?Ending = null;
        for (0..60) |_| {
            try raw.heartbeat(first_epoch, 0);
            world.pump(10);
            if (world.server.nextEvent()) |next| {
                ending = (try departure(next)).ending;
                break;
            }
        }
        try testing.expectEqual(Ending{ .timed_out = .write_stall }, ending.?);
    }
}

test "a peer that breaks the protocol is ended, and only that peer" {
    const world = try World.init(.{});
    defer world.deinit();
    const player = try world.addClient(world.players[0], .{});
    _ = try world.join(player);

    const Breach = enum {
        heartbeat_first,
        sequence_gap,
        other_version,
        bad_magic,
        hello_twice,
        server_hello,
        oversized,
        truncated,
        command_before_active,
        foreign_epoch,
        unsent_acknowledged,
        wrong_digest,
    };
    for (std.enums.values(Breach)) |breach| {
        const raw = try Raw.open(world, world.players[1]);
        try raw.establish();
        var hello: [wire.ClientHello.encoded_size]u8 = @splat(0);
        const expected: Ending = switch (breach) {
            .heartbeat_first => blk: {
                try raw.heartbeat(first_epoch, 0);
                break :blk .{ .protocol = .unexpected };
            },
            .sequence_gap => blk: {
                raw.sent = 1;
                try raw.heartbeat(first_epoch, 0);
                break :blk .{ .protocol = .sequence };
            },
            .other_version => blk: {
                var header: [wire.header_size]u8 = undefined;
                try wire.encodeHeader(&header, .{ .kind = .client_hello, .total_bytes = wire.header_size, .sequence = 1 }, net.limits.wire_v1_max_frame_bytes);
                header[4] = 2;
                try raw.write(&header);
                break :blk .{ .refused = refusal(.version, none_index) };
            },
            .bad_magic => blk: {
                var header: [wire.header_size]u8 = undefined;
                try wire.encodeHeader(&header, .{ .kind = .client_hello, .total_bytes = wire.header_size, .sequence = 1 }, net.limits.wire_v1_max_frame_bytes);
                header[0] = 'G';
                try raw.write(&header);
                break :blk .{ .protocol = .malformed };
            },
            .hello_twice => blk: {
                try raw.negotiate();
                _ = try admitted(try world.event(world.server, 50));
                try (wire.ClientHello{
                    .application_id = description.application,
                    .application_revision = description.application_revision,
                    .tick_rate_millihertz = description.tick_rate_millihertz,
                    .compatibility_id = description.compatibility_id,
                    .catalogue_count = 4,
                    .channel_count = 2,
                }).encode(&hello);
                try raw.frame(.client_hello, 0, &hello);
                break :blk .{ .protocol = .unexpected };
            },
            .server_hello => blk: {
                var payload: [wire.ServerHello.encoded_size]u8 = undefined;
                try (wire.ServerHello{
                    .application_id = description.application,
                    .application_revision = description.application_revision,
                    .tick_rate_millihertz = description.tick_rate_millihertz,
                    .compatibility_id = description.compatibility_id,
                    .session_epoch = first_epoch,
                    .participant_number = 1,
                    .catalogue_count = 4,
                    .channel_count = 2,
                    .peer_limit = 4,
                }).encode(&payload);
                try raw.frame(.server_hello, 0, &payload);
                break :blk .{ .protocol = .unexpected };
            },
            .oversized => blk: {
                var header: [wire.header_size]u8 = undefined;
                try wire.encodeHeader(&header, .{ .kind = .client_hello, .total_bytes = wire.header_size, .sequence = 1 }, net.limits.wire_v1_max_frame_bytes);
                std.mem.writeInt(u32, header[8..12], net.limits.wire_v1_max_frame_bytes + 1, .little);
                try raw.write(&header);
                break :blk .{ .protocol = .malformed };
            },
            .truncated => blk: {
                var bytes: [wire.header_size + wire.ClientHello.encoded_size]u8 = undefined;
                const whole = try wire.encodeFrame(&bytes, .{ .kind = .client_hello, .total_bytes = 0, .sequence = 1 }, &hello, net.limits.wire_v1_max_frame_bytes);
                try raw.write(whole[0 .. whole.len - 10]);
                world.t.close(raw.stream);
                raw.stream = .none;
                break :blk .{ .protocol = .truncated };
            },
            .command_before_active => blk: {
                try raw.negotiate();
                _ = try admitted(try world.event(world.server, 50));
                try raw.frame(.command, commands.id.hash, "move");
                break :blk .{ .protocol = .unexpected };
            },
            .foreign_epoch => blk: {
                try raw.negotiate();
                _ = try admitted(try world.event(world.server, 50));
                try raw.heartbeat(first_epoch + 1, 0);
                break :blk .{ .protocol = .mismatch };
            },
            .wrong_digest => blk: {
                // Every entry matches, but the digest over them does not.
                try raw.negotiateClaiming(@splat(0xee));
                break :blk .{ .refused = refusal(.catalogue, none_index) };
            },
            .unsent_acknowledged => blk: {
                try raw.negotiate();
                _ = try admitted(try world.event(world.server, 50));
                try raw.heartbeat(first_epoch, 99);
                break :blk .{ .protocol = .mismatch };
            },
        };
        const ending = try endingOf(world, world.server);
        if (!std.meta.eql(expected, ending)) {
            std.debug.print("{s}: expected {any}, got {any}\n", .{ @tagName(breach), expected, ending });
            return error.WrongEnding;
        }
        if (breach == .other_version) {
            // Told in wire version 1, which any later version can still read.
            const told = try raw.next();
            try testing.expectEqual(wire.RefusalReason.version, (try wire.Refusal.decode(told.payload)).reason);
        }
        raw.close();
        world.pump(5);
        try testing.expectEqual(PeerState.synchronizing, player.state().?);
    }
    try testing.expectEqual(@as(u32, 1), world.server.stats().peers);
}

test "a client does not believe a server whose answer disagrees with what it sent" {
    const world = try World.init(.{});
    defer world.deinit();
    // A listener the service knows nothing about, holding the real server identity and
    // answering by hand: a misconfigured server, not an impostor, since TLS would stop one.
    const elsewhere = transport.Endpoint.loopback(7001);
    const listener = try world.t.listen(elsewhere, world.server_credentials);
    defer world.t.closeListener(listener);
    var frozen = try net.compatibility.freeze(testing.allocator, description, world.limits);
    defer frozen.deinit(testing.allocator);
    var sorted = channels;
    const channel_digest = net.compatibility.freezeChannels(&sorted);

    const Lie = enum { revision, catalogue_count, channel_count, catalogue_digest, channel_digest };
    for (std.enums.values(Lie)) |lie| {
        const client = try world.addClient(world.players[0], .{ .endpoint = elsewhere });
        try client.connect();
        const stream = switch (try world.t.accept(listener)) {
            .stream => |accepted| accepted,
            else => return error.NotAccepted,
        };
        const raw = try Raw.adopt(world, stream);
        defer raw.close();
        try raw.establish();
        // The client's whole negotiation: hello, four entries, two channels, finish.
        for (0..8) |_| _ = try raw.next();

        var hello: wire.ServerHello = .{
            .application_id = frozen.application,
            .application_revision = frozen.application_revision,
            .tick_rate_millihertz = frozen.tick_rate_millihertz,
            .compatibility_id = frozen.compatibility_id,
            .session_epoch = first_epoch,
            .participant_number = 1,
            .catalogue_count = @intCast(frozen.items.len),
            .channel_count = sorted.len,
            .peer_limit = 4,
        };
        var finished: wire.NegotiationFinished = .{ .catalogue_digest = frozen.digest, .channel_digest = channel_digest };
        switch (lie) {
            .revision => hello.application_revision += 1,
            .catalogue_count => hello.catalogue_count -= 1,
            .channel_count => hello.channel_count += 1,
            .catalogue_digest => finished.catalogue_digest[0] ^= 1,
            .channel_digest => finished.channel_digest[31] ^= 1,
        }
        var hello_bytes: [wire.ServerHello.encoded_size]u8 = undefined;
        try hello.encode(&hello_bytes);
        try raw.frame(.server_hello, 0, &hello_bytes);
        var finished_bytes: [wire.NegotiationFinished.encoded_size]u8 = undefined;
        try finished.encode(&finished_bytes);
        try raw.frame(.negotiation_finished, 0, &finished_bytes);

        try testing.expectEqual(Ending{ .protocol = .mismatch }, try endingOf(world, client.service));
        world.dropClient(client);
    }
}

test "a noisy peer gets its budget each pump and no more, beside a quiet one" {
    const world = try World.init(.{});
    defer world.deinit();
    const quiet = try world.addClient(world.players[0], .{});
    _ = try world.join(quiet);
    const raw = try Raw.open(world, world.players[1]);
    defer raw.close();
    try raw.establish();
    try raw.negotiate();
    const noisy = (try admitted(try world.event(world.server, 50))).peer;

    // A thousand valid heartbeats at once: every one a frame the server must decode.
    var flood: [1000 * (wire.header_size + wire.Heartbeat.encoded_size)]u8 = undefined;
    var at: usize = 0;
    var payload: [wire.Heartbeat.encoded_size]u8 = undefined;
    try (wire.Heartbeat{ .session_epoch = first_epoch, .last_received_sequence = 2 }).encode(&payload);
    for (0..1000) |_| {
        raw.sent += 1;
        at += (try wire.encodeFrame(flood[at..], .{ .kind = .heartbeat, .total_bytes = 0, .sequence = raw.sent }, &payload, net.limits.wire_v1_max_frame_bytes)).len;
    }
    const before = world.server.stats().frames_received;
    const rounds_before = world.rounds;
    try raw.write(flood[0..at]);
    const budget = world.limits.pump_frames_per_peer;
    var pumps: usize = 0;
    var last = world.server.stats().frames_received;
    while (world.server.stats().frames_received - before < 1000) : (pumps += 1) {
        if (pumps > 200) return error.FloodNotDrained;
        world.pump(1);
        const now_received = world.server.stats().frames_received;
        // The quiet peer's heartbeats are all that can arrive beside the noisy budget.
        try testing.expect(now_received - last <= budget + 2);
        last = now_received;
    }
    try testing.expect(world.rounds - rounds_before >= 1000 / budget);
    const stats = world.server.stats();
    try testing.expect(stats.peak_frames_in_per_pump <= budget);
    try testing.expect(stats.peak_bytes_in_per_pump <= world.limits.pump_bytes_per_direction_per_peer);
    // Valid traffic is not a violation: both peers carry on.
    try testing.expectEqual(PeerState.synchronizing, world.server.peerInfo(noisy).?.state);
    try testing.expectEqual(PeerState.synchronizing, quiet.state().?);
}

test "events are reserved, so a host that stops reading them stops admitting" {
    {
        var limits = proofLimits();
        limits.queued_events = 4;
        const world = try World.init(.{ .limits = limits });
        defer world.deinit();
        const one = try world.addClient(world.players[0], .{ .limits = proofLimits() });
        const two = try world.addClient(world.players[1], .{ .limits = proofLimits() });
        const three = try world.addClient(world.players[2], .{ .limits = proofLimits() });
        for ([_]*Client{ one, two }) |client| {
            try client.connect();
            try world.until(client.service, client.peer, .synchronizing, 2_000);
        }
        // Two admissions queued, two endings held for them: nothing is left to promise.
        const stats = world.server.stats();
        try testing.expectEqual(@as(u32, 2), stats.queued_events);
        try testing.expectEqual(@as(u32, 2), stats.reserved_events);
        try three.connect();
        try testing.expectEqual(Ending{ .refused_by_peer = refusal(.capacity, none_index) }, try endingOf(world, three.service));
        try testing.expectEqual(@as(u64, 1), world.server.stats().capacity_refusals);

        // Reading them makes room again.
        _ = try admitted(world.server.nextEvent().?);
        _ = try admitted(world.server.nextEvent().?);
        _ = try world.join(three);
    }
    {
        var limits = proofLimits();
        limits.peers_per_session = 2;
        const world = try World.init(.{ .limits = limits });
        defer world.deinit();
        const one = try world.addClient(world.players[0], .{ .limits = proofLimits() });
        const two = try world.addClient(world.players[1], .{ .limits = proofLimits() });
        const three = try world.addClient(world.players[2], .{ .limits = proofLimits() });
        _ = try world.join(one);
        _ = try world.join(two);
        try three.connect();
        try testing.expectEqual(Ending{ .refused_by_peer = refusal(.capacity, none_index) }, try endingOf(world, three.service));
        // A departure frees its place.
        try one.service.disconnect(one.peer, .closed);
        try testing.expectEqual(Ending{ .peer_disconnected = .closed }, try endingOf(world, world.server));
        try world.until(one.service, one.peer, null, 2_000);
        _ = try world.join(three);
    }
}

test "closing a session ends everything it held, and a new one starts fresh" {
    const world = try World.init(.{});
    defer world.deinit();
    const one = try world.addClient(world.players[0], .{});
    const two = try world.addClient(world.players[1], .{});
    const first = try world.join(one);
    _ = try world.join(two);
    // One pending handshake and one undrained event are part of what it holds.
    const stalled = try world.t.connect(server_endpoint, world.players[2]);
    world.pump(1);
    try testing.expect(world.server.revoke(world.pki.players[1].key()));
    try testing.expectEqual(@as(u32, 1), world.server.stats().pending);

    world.server.closeSession(world.session);
    try testing.expectEqual(@as(?svc.SessionInfo, null), world.server.sessionInfo(world.session));
    try testing.expectEqual(@as(?svc.PeerInfo, null), world.server.peerInfo(first.server.peer));
    try testing.expectEqual(@as(?svc.Event, null), world.server.nextEvent());
    const stats = world.server.stats();
    try testing.expectEqual(@as(u32, 0), stats.sessions + stats.peers + stats.pending + stats.reserved_events);
    try testing.expectEqual(@as(u32, 0), world.t.stats().listeners);
    try testing.expectEqual(Ending{ .peer_disconnected = .closed }, try endingOf(world, one.service));
    world.t.close(stalled);

    // The grant can start another session, which takes the next epoch and numbers its
    // participants from one.
    world.session = try world.server.createSession(server_grant);
    try world.server.registerChannel(world.session, commands);
    try world.server.registerChannel(world.session, state_channel);
    try world.server.listen(world.session);
    try testing.expectEqual(first_epoch + 1, world.server.sessionInfo(world.session).?.epoch);
    try world.until(one.service, one.peer, null, 2_000);
    const again = try world.join(one);
    try testing.expectEqual(first_epoch + 1, again.client.kind.admitted.epoch);
    try testing.expectEqual(@as(u32, 1), again.server.kind.admitted.participant);
}

test "a peer whose certificate expires mid-session is ended, and cannot rejoin" {
    const world = try World.init(.{});
    defer world.deinit();
    const client = try world.addClient(world.players[0], .{});
    _ = try world.join(client);

    try world.t.setFixedClock(after_expiry);
    try testing.expectEqual(Ending{ .transport = .certificate_expired }, try endingOf(world, world.server));
    try testing.expectEqual(Ending{ .transport = .certificate_expired }, try endingOf(world, client.service));

    // A new attempt at that time fails TLS, on the client, before any negotiation.
    try world.until(client.service, client.peer, null, 100);
    try client.connect();
    try testing.expectEqual(Ending{ .transport = .certificate_expired }, try endingOf(world, client.service));
    world.pump(20);
    try testing.expectEqual(@as(?svc.Event, null), world.server.nextEvent());
}

test "rotating a server's credentials ends every connection, and only the new key is trusted after" {
    const world = try World.init(.{});
    defer world.deinit();
    const client = try world.addClient(world.players[0], .{});
    _ = try world.join(client);

    // Refused rotations change nothing.
    try testing.expectError(error.UnknownGrant, world.server.replaceCredentials(ContentId.fromString("test:nowhere"), world.server_credentials));
    try testing.expectError(error.WrongRole, world.server.replaceCredentials(server_grant, world.players[0]));
    try testing.expectError(error.InvalidCredentials, world.server.replaceCredentials(server_grant, .none));
    world.pump(10);
    try testing.expectEqual(PeerState.synchronizing, client.state().?);

    const replacement = try serverCredentials(world.t, world.pki, &world.pki.replacement);
    try world.server.replaceCredentials(server_grant, replacement);
    try testing.expectEqual(Ending.rotated, try endingOf(world, world.server));
    try testing.expectEqual(Ending{ .peer_disconnected = .policy }, try endingOf(world, client.service));
    // Nothing uses the old identity once the connection it authenticated is gone.
    try world.until(client.service, client.peer, null, 2_000);
    for (0..100) |_| {
        if (world.server.stats().peers == 0) break;
        world.pump(1);
    }
    try world.t.destroyCredentials(world.server_credentials);

    // A client still pinning the old key refuses the new server itself.
    try client.connect();
    try testing.expectEqual(Ending{ .transport = .server_key_mismatch }, try endingOf(world, client.service));

    const repinned = try clientCredentials(world.t, world.pki, &world.pki.players[0], world.pki.replacement.key());
    const updated = try world.addClient(repinned, .{});
    const joined = try world.join(updated);
    try testing.expectEqual(@as(u32, 2), joined.server.kind.admitted.participant);
}

test "a session admits over real loopback sockets" {
    const limits = proofLimits();
    var options = svc.transportOptions(limits, .system);
    options.max_streams = 16;
    options.civil_clock = .{ .fixed = civil_now };
    const t = try Transport.init(testing.allocator, options);
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();

    const server_credentials = try serverCredentials(t, pki, &pki.server);
    const server = try Service.init(testing.allocator, t, .{
        .limits = limits,
        .compatibility = description,
        .grants = &.{.{ .id = server_grant, .role = .server, .endpoint = transport.Endpoint.loopback(0), .credentials = server_credentials }},
        .identities = &.{.{ .key = pki.players[0].key(), .principal = 1 }},
    });
    defer server.deinit();
    const session = try server.createSession(server_grant);
    try server.registerChannel(session, commands);
    try server.registerChannel(session, state_channel);
    try server.listen(session);
    const bound = server.sessionInfo(session).?.listening.?;
    try testing.expect(bound.port != 0);

    const client_credentials = try clientCredentials(t, pki, &pki.players[0], pki.server.key());
    const client = try Service.init(testing.allocator, t, .{
        .limits = limits,
        .compatibility = description,
        .grants = &.{.{ .id = client_grant, .role = .client, .endpoint = bound, .credentials = client_credentials }},
    });
    defer client.deinit();
    const client_session = try client.createSession(client_grant);
    try client.registerChannel(client_session, state_channel);
    try client.registerChannel(client_session, commands);
    const peer = try client.connect(client_session);

    var clock: u64 = ms;
    var admissions: usize = 0;
    var round: usize = 0;
    while (admissions < 2) : (round += 1) {
        if (round > 20_000) return error.DidNotAdmit;
        server.pump(clock);
        client.pump(clock);
        clock += ms / 4;
        for ([_]*Service{ server, client }) |service| {
            if (service.nextEvent()) |event| {
                _ = try admitted(event);
                admissions += 1;
            }
        }
        if (round > 32) std.Io.sleep(testing.io, .fromNanoseconds(200 * std.time.ns_per_us), .awake) catch {};
    }
    try testing.expectEqual(PeerState.synchronizing, client.peerInfo(peer).?.state);

    try client.disconnect(peer, .closed);
    var left: ?svc.Departure = null;
    round = 0;
    while (left == null) : (round += 1) {
        if (round > 20_000) return error.DidNotLeave;
        server.pump(clock);
        client.pump(clock);
        clock += ms / 4;
        if (server.nextEvent()) |event| left = try departure(event);
        if (round > 32) std.Io.sleep(testing.io, .fromNanoseconds(200 * std.time.ns_per_us), .awake) catch {};
    }
    try testing.expectEqual(Ending{ .peer_disconnected = .closed }, left.?.ending);
}
