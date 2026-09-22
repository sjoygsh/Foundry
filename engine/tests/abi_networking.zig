//! M16 Step 5: networking through `FoundryApi_v5`, and through nothing else.
//!
//! One `net.Service` holds a server grant and a client grant over the memory carrier, so a
//! single process can be both ends of a session. The host builds it, publishes two of its
//! grants to the table and pumps it; everything else — sessions, channels, joining, the
//! baseline, commands, admission, state and endings — is done by calling the table exactly
//! as a C consumer would. A third grant the host keeps to itself shows what "insufficient
//! rights" means: refused, and its events left for the host.
//!
//! Identities are generated per run (`fixtures/identities.zig`) and the clock is the proof's.

const std = @import("std");
const core = @import("core");
const net = @import("net");
const abi = @import("abi");
const platform = @import("platform");
const identities = @import("fixtures/identities.zig");

const transport = platform.transport;
const Transport = transport.Transport;
const Service = net.Service;
const ContentId = core.ContentId;
const Result = abi.Result;
const N = abi.net;

const testing = std.testing;
const ms = std.time.ns_per_ms;

const Host = abi.Host;
const table = abi.TableOf(Host).v5;

const civil_now: i64 = 1789948800;
const server_name = "server.foundry.test";

const host_grant = ContentId.fromString("test:host");
const join_grant = ContentId.fromString("test:join");
const private_grant = ContentId.fromString("test:private");
const private_join = ContentId.fromString("test:private_join");
const published = [_]ContentId{ host_grant, join_grant };

const commands: N.ChannelDesc = .{
    .id = ContentId.fromString("test:commands"),
    .revision = 1,
    .max_payload_bytes = 64,
    .direction = N.direction_client_to_server,
    .delivery = N.delivery_reliable,
};
const state: N.ChannelDesc = .{
    .id = ContentId.fromString("test:state"),
    .revision = 1,
    .max_payload_bytes = 256,
    .direction = N.direction_server_to_client,
    .delivery = N.delivery_latest_state,
};

fn ok(result: Result) !void {
    if (result != .ok) {
        std.debug.print("expected FOUNDRY_OK, got {s}\n", .{result.name()});
        return error.NotOk;
    }
}

fn expect(expected: Result, actual: Result) !void {
    if (expected != actual) {
        std.debug.print("expected {s}, got {s}\n", .{ expected.name(), actual.name() });
        return error.WrongResult;
    }
}

const World = struct {
    t: *Transport,
    service: *Service,
    host: Host,
    now: u64 = ms,
    pki: *Pki,

    const Pki = struct {
        root: identities.Authority,
        server: identities.Identity,
        player: identities.Identity,
        /// The host's own client, on its private grant: another principal.
        other: identities.Identity,
    };

    fn init() !*World {
        var limits: net.limits.Limits = .{};
        limits.sessions = 4;
        limits.handshake_starts_per_second = 1000;
        limits.handshake_start_burst = 1000;
        limits.handshake_starts_per_source_per_second = 1000;
        limits.handshake_start_per_source_burst = 1000;
        limits.initial_sync_timeout_ms = 60_000;
        var options = net.service.transportOptions(limits, .memory);
        options.max_credentials = 8;
        options.civil_clock = .{ .fixed = civil_now };
        const t = try Transport.init(testing.allocator, options);
        errdefer t.deinit();

        const pki = try testing.allocator.create(Pki);
        errdefer testing.allocator.destroy(pki);
        try identities.ok(identities.foundry_test_authority_create(&pki.root, null, "CN=Foundry Test Root,O=Foundry Test", 1));
        try identities.ok(identities.foundry_test_issue(&pki.server, &pki.root, "CN=Foundry test server,O=Foundry Test", server_name, identities.server_auth, 10, "20260601000000", "20270601000000"));
        try identities.ok(identities.foundry_test_issue(&pki.player, &pki.root, "CN=player,O=Foundry Test", null, identities.client_auth, 20, "20260601000000", "20270601000000"));
        try identities.ok(identities.foundry_test_issue(&pki.other, &pki.root, "CN=other,O=Foundry Test", null, identities.client_auth, 21, "20260601000000", "20270601000000"));

        const server_credentials = try t.createCredentials(.{
            .role = .server,
            .trust_roots = identities.pem(&pki.root.certificate),
            .certificate_chain = identities.pem(&pki.server.certificate),
            .private_key = identities.pem(&pki.server.private_key),
        });
        const client_credentials = try t.createCredentials(.{
            .role = .client,
            .trust_roots = identities.pem(&pki.root.certificate),
            .certificate_chain = identities.pem(&pki.player.certificate),
            .private_key = identities.pem(&pki.player.private_key),
            .server_name = server_name,
            .server_key = pki.server.key(),
        });
        const other_credentials = try t.createCredentials(.{
            .role = .client,
            .trust_roots = identities.pem(&pki.root.certificate),
            .certificate_chain = identities.pem(&pki.other.certificate),
            .private_key = identities.pem(&pki.other.private_key),
            .server_name = server_name,
            .server_key = pki.server.key(),
        });
        const service = try Service.init(testing.allocator, t, .{
            .limits = limits,
            .compatibility = .{
                .application = ContentId.fromString("test:app"),
                .application_revision = 1,
                .tick_rate_millihertz = 60_000,
                .compatibility_id = @splat(0x42),
            },
            .grants = &.{
                .{ .id = host_grant, .role = .server, .endpoint = transport.Endpoint.loopback(7100), .credentials = server_credentials },
                .{ .id = join_grant, .role = .client, .endpoint = transport.Endpoint.loopback(7100), .credentials = client_credentials },
                .{ .id = private_grant, .role = .server, .endpoint = transport.Endpoint.loopback(7200), .credentials = server_credentials },
                .{ .id = private_join, .role = .client, .endpoint = transport.Endpoint.loopback(7200), .credentials = other_credentials },
            },
            .identities = &.{ .{ .key = pki.player.key(), .principal = 1 }, .{ .key = pki.other.key(), .principal = 2 } },
            .first_epoch = 7,
        });
        errdefer service.deinit();

        const world = try testing.allocator.create(World);
        world.* = .{ .t = t, .service = service, .host = .{ .net_service = service, .net_grants = &published }, .pki = pki };
        world.host.bind();
        return world;
    }

    fn deinit(self: *World) void {
        self.host.unbind();
        self.service.deinit();
        self.t.deinit();
        std.crypto.secureZero(u8, std.mem.asBytes(self.pki));
        testing.allocator.destroy(self.pki);
        testing.allocator.destroy(self);
    }

    fn pump(self: *World, rounds: usize) void {
        for (0..rounds) |_| {
            self.service.pump(self.now);
            self.now += 10 * ms;
        }
    }

    /// Pumps until the table has an event of `kind`, and returns it.
    fn event(self: *World, kind: i32) !N.Event {
        for (0..2_000) |_| {
            var out: N.Event = .{};
            const result = table.net_event_next(&out);
            if (result == .ok) {
                if (out.kind != kind) {
                    std.debug.print("expected event {d}, got {d} (ending {d}/{d})\n", .{ kind, out.kind, out.ending.kind, out.ending.code });
                    return error.WrongEvent;
                }
                return out;
            }
            try expect(.end, result);
            self.pump(1);
        }
        return error.NoEvent;
    }
};

fn register(session: abi.NetSession) !void {
    try ok(table.net_channel_register(session, &commands));
    try ok(table.net_channel_register(session, &state));
}

/// Joins a client session to a listening server session through the table, returning the
/// server's and the client's handles for the connection.
fn join(world: *World, server: abi.NetSession, client: abi.NetSession) !struct { server: abi.NetPeer, client: abi.NetPeer } {
    var peer: abi.NetPeer = .none;
    try ok(table.net_session_connect(client, &peer));
    var server_peer: abi.NetPeer = .none;
    var seen: u8 = 0;
    while (seen != 3) {
        const admitted = try world.event(N.event_admitted);
        if (admitted.session.eql(server)) {
            server_peer = admitted.peer;
            seen |= 1;
        } else {
            try testing.expect(admitted.session.eql(client) and admitted.peer.eql(peer));
            seen |= 2;
        }
    }
    return .{ .server = server_peer, .client = peer };
}

test "a session is made, joined and played entirely through the table" {
    const world = try World.init();
    defer world.deinit();

    // Only the published grants are there to be seen, with their role and endpoint.
    var cursor: abi.Cursor = .begin;
    var grant: N.GrantInfo = .{};
    try ok(table.net_grant_next(&cursor, &grant));
    try testing.expect(grant.id.eql(host_grant));
    try testing.expectEqual(N.role_server, grant.role);
    try testing.expectEqual(@as(u16, 7100), grant.endpoint.port);
    try ok(table.net_grant_next(&cursor, &grant));
    try testing.expect(grant.id.eql(join_grant));
    try testing.expectEqual(N.role_client, grant.role);
    try expect(.end, table.net_grant_next(&cursor, &grant));

    var server: abi.NetSession = .none;
    try ok(table.net_session_create(host_grant, &server));
    try register(server);
    var channels: abi.Cursor = .begin;
    var channel: N.ChannelDesc = .{};
    try ok(table.net_channel_next(server, &channels, &channel));
    try testing.expect(channel.id.eql(commands.id));
    try ok(table.net_session_listen(server));
    var info: N.SessionInfo = .{};
    try ok(table.net_session_info(server, &info));
    try testing.expectEqual(N.session_running, info.state);
    try testing.expectEqual(@as(u64, 7), info.epoch);
    try testing.expectEqual(@as(abi.Bool, 1), info.listening);
    try testing.expectEqual(@as(u16, 7100), info.listen_endpoint.port);

    var client: abi.NetSession = .none;
    try ok(table.net_session_create(join_grant, &client));
    try register(client);
    const peers = try join(world, server, client);

    // The baseline: sent, seen, refused into a short buffer without being taken, taken,
    // acknowledged by name — and only then are both sides active.
    const hello = "the world at 1";
    try ok(table.net_baseline_send(peers.server, 1, hello.ptr, hello.len));
    var delivery: N.Delivery = .{};
    for (0..200) |_| {
        if (table.net_delivery_next(peers.client, &delivery) == .ok) break;
        world.pump(1);
    }
    try testing.expectEqual(N.delivery_kind_baseline, delivery.kind);
    var buffer: [256]u8 = undefined;
    var needed: u64 = 0;
    try expect(.limit, table.net_delivery_take(peers.client, &buffer, 3, &needed, &delivery));
    try testing.expectEqual(@as(u64, hello.len), needed);
    try ok(table.net_delivery_take(peers.client, &buffer, buffer.len, &needed, &delivery));
    try testing.expectEqualStrings(hello, buffer[0..delivery.bytes]);
    try expect(.end, table.net_delivery_next(peers.client, &delivery));
    try ok(table.net_baseline_acknowledge(peers.client, delivery.sequence, delivery.tick));
    const on_server = try world.event(N.event_activated);
    const on_client = try world.event(N.event_activated);
    try testing.expect(on_server.peer.eql(peers.server) or on_client.peer.eql(peers.server));
    var peer_info: N.PeerInfo = .{};
    try ok(table.net_peer_info(peers.server, &peer_info));
    try testing.expectEqual(@as(i32, 5), peer_info.state);
    try testing.expectEqual(@as(u32, 1), peer_info.participant);
    try testing.expect(peer_info.session.eql(server));

    // A command, admitted for a tick and read back out of the batch.
    var number: u64 = 0;
    try ok(table.net_command_send(peers.client, commands.id, "go", 2, &number));
    try testing.expectEqual(@as(u64, 1), number);
    var count: u32 = 0;
    for (0..200) |tick| {
        world.pump(1);
        try ok(table.net_batch_admit(server, tick + 1, &count));
        if (count > 0) break;
    }
    try testing.expectEqual(@as(u32, 1), count);
    var command: N.Command = .{};
    try ok(table.net_batch_command(server, 0, &command));
    try testing.expectEqual(@as(u32, 1), command.participant);
    try testing.expectEqual(@as(u64, 1), command.number);
    try testing.expect(command.peer.eql(peers.server));
    try expect(.limit, table.net_batch_copy(server, 0, &buffer, 1, &needed));
    try testing.expectEqual(@as(u64, 2), needed);
    try ok(table.net_batch_copy(server, 0, &buffer, buffer.len, &needed));
    try testing.expectEqualStrings("go", buffer[0..2]);
    try expect(.not_found, table.net_batch_command(server, 1, &command));

    // State, published and received as the newest view.
    try ok(table.net_state_publish(peers.server, 300, "state at 300", 12));
    for (0..200) |_| {
        if (table.net_delivery_take(peers.client, &buffer, buffer.len, &needed, &delivery) == .ok) break;
        world.pump(1);
    }
    try testing.expectEqual(N.delivery_kind_state, delivery.kind);
    try testing.expectEqual(@as(u64, 300), delivery.tick);
    try testing.expectEqualStrings("state at 300", buffer[0..delivery.bytes]);

    var walk: abi.Cursor = .begin;
    var listed: abi.NetPeer = .none;
    try ok(table.net_peer_next(server, &walk, &listed));
    try testing.expect(listed.eql(peers.server));
    try expect(.end, table.net_peer_next(server, &walk, &listed));

    var stats: N.Stats = .{};
    try ok(table.net_stats(&stats));
    try testing.expectEqual(@as(u64, 2), stats.activations);
    try testing.expectEqual(@as(u64, 1), stats.commands_admitted);

    // The client leaves with a reason; each side's ending says it.
    try ok(table.net_peer_disconnect(peers.client, 6));
    var saw_local = false;
    var saw_peer = false;
    while (!saw_local or !saw_peer) {
        const ended = try world.event(N.event_ended);
        if (ended.ending.kind == N.ending_local) saw_local = true;
        if (ended.ending.kind == N.ending_peer_disconnected) saw_peer = true;
        try testing.expectEqual(@as(i32, 6), ended.ending.code);
    }

    try ok(table.net_session_close(client));
    try ok(table.net_session_close(server));
    try expect(.invalid_handle, table.net_session_info(server, &info));
    var last: N.Event = .{};
    try expect(.end, table.net_event_next(&last));
}

test "what the table may not do, it refuses — and says which refusal" {
    const world = try World.init();
    defer world.deinit();
    var session: abi.NetSession = .none;
    var event: N.Event = .{};

    // Rights: a grant the service holds and the host did not publish, and one it does not
    // hold at all.
    try expect(.refused, table.net_session_create(private_grant, &session));
    try expect(.not_found, table.net_session_create(ContentId.fromString("test:nowhere"), &session));

    // The host's own session on its private grant is invisible to the table: its handle is
    // refused and its events stay queued for the host, behind and ahead of the table's own.
    const private_server = try world.service.createSession(private_grant);
    try world.service.registerChannel(private_server, .{ .id = commands.id, .revision = 1, .max_payload_bytes = 64, .direction = .client_to_server, .delivery = .reliable_ordered });
    try world.service.registerChannel(private_server, .{ .id = state.id, .revision = 1, .max_payload_bytes = 256, .direction = .server_to_client, .delivery = .latest_complete_state });
    try world.service.listen(private_server);
    const private_client = try world.service.createSession(private_join);
    try world.service.registerChannel(private_client, .{ .id = commands.id, .revision = 1, .max_payload_bytes = 64, .direction = .client_to_server, .delivery = .reliable_ordered });
    try world.service.registerChannel(private_client, .{ .id = state.id, .revision = 1, .max_payload_bytes = 256, .direction = .server_to_client, .delivery = .latest_complete_state });
    _ = try world.service.connect(private_client);
    var info: N.SessionInfo = .{};
    try expect(.refused, table.net_session_info(.wrap(private_server), &info));
    try expect(.refused, table.net_session_close(.wrap(private_server)));

    var server: abi.NetSession = .none;
    try ok(table.net_session_create(host_grant, &server));
    try expect(.already_exists, table.net_session_create(host_grant, &session));
    try register(server);
    try ok(table.net_session_listen(server));
    var client: abi.NetSession = .none;
    try ok(table.net_session_create(join_grant, &client));
    try register(client);
    const peers = try join(world, server, client);
    // Both private admissions were there all along, and are still there, in order.
    var private_events: usize = 0;
    while (world.service.nextEvent()) |next| {
        try testing.expect(next.session.eql(private_server) or next.session.eql(private_client));
        private_events += 1;
    }
    try testing.expectEqual(@as(usize, 2), private_events);

    // Channels: bad enumerations, duplicates, a second state channel, and too late.
    var bad = commands;
    bad.id = ContentId.fromString("test:bad");
    bad.direction = 0;
    try expect(.invalid_argument, table.net_channel_register(client, &bad));
    bad.direction = 4;
    try expect(.invalid_argument, table.net_channel_register(client, &bad));
    bad.direction = N.direction_client_to_server;
    bad.delivery = 3;
    try expect(.invalid_argument, table.net_channel_register(client, &bad));
    try expect(.refused, table.net_channel_register(server, &commands));

    // Roles and states.
    var peer: abi.NetPeer = .none;
    var count: u32 = 0;
    var delivery: N.Delivery = .{};
    try expect(.refused, table.net_session_connect(server, &peer));
    try expect(.refused, table.net_session_listen(client));
    try expect(.refused, table.net_session_connect(client, &peer));
    try expect(.refused, table.net_batch_admit(client, 1, &count));
    try expect(.refused, table.net_delivery_next(peers.server, &delivery));
    try expect(.refused, table.net_baseline_send(peers.client, 1, "x", 1));
    try expect(.refused, table.net_state_publish(peers.server, 1, "early", 5));
    var number: u64 = 0;
    try expect(.refused, table.net_command_send(peers.client, commands.id, "early", 5, &number));
    try expect(.refused, table.net_baseline_acknowledge(peers.client, 3, 1));

    // Buffers and payloads from a caller that cannot be trusted with one.
    var needed: u64 = 0;
    var buffer: [8]u8 = undefined;
    try expect(.invalid_argument, table.net_baseline_send(peers.server, 1, null, 4));
    try expect(.invalid_argument, table.net_delivery_take(peers.client, null, 8, &needed, &delivery));
    try expect(.invalid_argument, table.net_delivery_take(peers.client, &buffer, 8, null, &delivery));
    try expect(.invalid_argument, table.net_batch_copy(server, 0, null, 8, &needed));
    var oversized: [257]u8 = @splat(0);
    try expect(.invalid_argument, table.net_baseline_send(peers.server, 1, &oversized, oversized.len));
    try expect(.invalid_argument, table.net_peer_disconnect(peers.client, 0));
    try expect(.invalid_argument, table.net_peer_disconnect(peers.client, 7));

    // Activate, then the channel and tick refusals.
    try ok(table.net_baseline_send(peers.server, 5, "b", 1));
    for (0..200) |_| {
        if (table.net_delivery_take(peers.client, &buffer, buffer.len, &needed, &delivery) == .ok) break;
        world.pump(1);
    }
    try expect(.refused, table.net_baseline_acknowledge(peers.client, delivery.sequence + 1, delivery.tick));
    try ok(table.net_baseline_acknowledge(peers.client, delivery.sequence, delivery.tick));
    _ = try world.event(N.event_activated);
    _ = try world.event(N.event_activated);
    try expect(.refused, table.net_command_send(peers.client, state.id, "s", 1, &number));
    try expect(.not_found, table.net_command_send(peers.client, ContentId.fromString("test:nowhere"), "s", 1, &number));
    var long: [65]u8 = @splat(1);
    try expect(.invalid_argument, table.net_command_send(peers.client, commands.id, &long, long.len, &number));
    try expect(.invalid_argument, table.net_command_send(peers.client, commands.id, "s", 1, null));
    try ok(table.net_batch_admit(server, 10, &count));
    try expect(.refused, table.net_batch_admit(server, 10, &count));
    try ok(table.net_state_publish(peers.server, 10, "s", 1));
    try expect(.refused, table.net_state_publish(peers.server, 9, "s", 1));

    // A walk whose peers changed under it is refused rather than resynchronised.
    var scratch: N.PeerInfo = .{};
    var walk: abi.Cursor = .begin;
    var listed: abi.NetPeer = .none;
    try ok(table.net_peer_next(server, &walk, &listed));
    try ok(table.net_peer_disconnect(peers.server, 1));
    for (0..300) |_| {
        if (table.net_peer_info(peers.server, &scratch) == .invalid_handle) break;
        world.pump(1);
    }
    try expect(.invalid_argument, table.net_peer_next(server, &walk, &listed));

    // Stale and invented handles.
    try expect(.invalid_handle, table.net_peer_info(peers.server, &scratch));
    try expect(.invalid_handle, table.net_session_info(.{ .bits = 0xDEAD_BEEF }, &info));
    try expect(.invalid_handle, table.net_peer_disconnect(.{ .bits = 0xDEAD_BEEF }, 1));

    // Without a service, and without rights, the same calls answer distinctly.
    world.host.net_grants = &.{};
    try expect(.refused, table.net_session_info(server, &info));
    var cursor: abi.Cursor = .begin;
    var nothing: N.GrantInfo = .{};
    try expect(.end, table.net_grant_next(&cursor, &nothing));
    world.host.net_service = null;
    try expect(.unavailable, table.net_session_info(server, &info));
    try expect(.unavailable, table.net_event_next(&event));
    world.host.net_service = world.service;
    world.host.net_grants = &published;
}
