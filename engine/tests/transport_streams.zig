//! M16 Step 2: authenticated platform streams, proved end to end.
//!
//! Every identity here is generated for the run by `fixtures/tls_identities.c` — a fresh
//! P-256 key, fixed validity dates, never written to disk — so no key is committed and a
//! proof that injects a clock reaches the same verdict on every machine
//! (`networking.md` §4.1). The fixture is linked into this binary alone.
//!
//! The `.system` proofs open real loopback sockets on the machine running them; that is
//! the Step 2 evidence on macOS and Windows. The `.memory` proofs drive the same TLS over
//! the deterministic carrier `net`'s tests will use, which is how fragmentation, stalls,
//! resets and tampering are made to happen on command.

const std = @import("std");
const net = @import("net");
const platform = @import("platform");

const transport = platform.transport;
const Transport = transport.Transport;
const StreamHandle = transport.StreamHandle;
const ListenerHandle = transport.ListenerHandle;
const CredentialsHandle = transport.CredentialsHandle;
const State = transport.State;
const Failure = transport.Failure;

const testing = std.testing;

// -- disposable identities ------------------------------------------------------------

const pem_bytes = 4096;

const Authority = extern struct {
    name: [128]u8,
    certificate: [pem_bytes]u8,
    private_key: [pem_bytes]u8,
};

const Identity = extern struct {
    certificate: [pem_bytes]u8,
    private_key: [pem_bytes]u8,
    key_sha256: [32]u8,

    fn key(self: *const Identity) transport.KeyFingerprint {
        return .{ .sha256 = self.key_sha256 };
    }
};

extern fn foundry_test_authority_create(out: *Authority, parent: ?*const Authority, name: [*:0]const u8, serial: u8) c_int;
extern fn foundry_test_issue(
    out: *Identity,
    authority: *const Authority,
    subject: [*:0]const u8,
    dns_name: ?[*:0]const u8,
    usage: c_int,
    serial: u8,
    not_before: [*:0]const u8,
    not_after: [*:0]const u8,
) c_int;

const server_auth = 1;
const client_auth = 2;

/// 2026-09-21T00:00:00Z: inside every ordinary identity's validity.
const now: i64 = 1789948800;
/// 2027-09-01, after every ordinary leaf has expired; 2026-03-01, before any has begun.
const after_expiry: i64 = 1819843200;
const before_validity: i64 = 1772323200;
const leaf_from = "20260601000000";
const leaf_until = "20270601000000";
const server_name = "server.foundry.test";

const Pki = struct {
    root: Authority,
    foreign_root: Authority,
    intermediates: [3]Authority,
    server: Identity,
    client: Identity,
    foreign_client: Identity,
    expired_client: Identity,
    unmarked_client: Identity,
    shallow_server: Identity,
    deep_server: Identity,
    shallow_chain: [4 * pem_bytes]u8,
    deep_chain: [5 * pem_bytes]u8,
    shallow_len: usize,
    deep_len: usize,

    fn create() !*Pki {
        const pki = try testing.allocator.create(Pki);
        errdefer testing.allocator.destroy(pki);
        try ok(foundry_test_authority_create(&pki.root, null, "CN=Foundry Test Root,O=Foundry Test", 1));
        try ok(foundry_test_authority_create(&pki.foreign_root, null, "CN=Foreign Test Root,O=Elsewhere", 2));
        try ok(foundry_test_authority_create(&pki.intermediates[0], &pki.root, "CN=Foundry Test Intermediate 0,O=Foundry Test", 3));
        try ok(foundry_test_authority_create(&pki.intermediates[1], &pki.intermediates[0], "CN=Foundry Test Intermediate 1,O=Foundry Test", 4));
        try ok(foundry_test_authority_create(&pki.intermediates[2], &pki.intermediates[1], "CN=Foundry Test Intermediate 2,O=Foundry Test", 5));
        try ok(foundry_test_issue(&pki.server, &pki.root, "CN=Foundry test server,O=Foundry Test", server_name, server_auth, 10, leaf_from, leaf_until));
        try ok(foundry_test_issue(&pki.client, &pki.root, "CN=player-one,O=Foundry Test", null, client_auth, 11, leaf_from, leaf_until));
        try ok(foundry_test_issue(&pki.foreign_client, &pki.foreign_root, "CN=stranger,O=Elsewhere", null, client_auth, 12, leaf_from, leaf_until));
        try ok(foundry_test_issue(&pki.expired_client, &pki.root, "CN=lapsed,O=Foundry Test", null, client_auth, 13, "20260102000000", "20260301000000"));
        try ok(foundry_test_issue(&pki.unmarked_client, &pki.root, "CN=unmarked,O=Foundry Test", null, 0, 14, leaf_from, leaf_until));
        try ok(foundry_test_issue(&pki.shallow_server, &pki.intermediates[1], "CN=Foundry test server,O=Foundry Test", server_name, server_auth, 15, leaf_from, leaf_until));
        try ok(foundry_test_issue(&pki.deep_server, &pki.intermediates[2], "CN=Foundry test server,O=Foundry Test", server_name, server_auth, 16, leaf_from, leaf_until));
        pki.shallow_len = join(&pki.shallow_chain, &.{ pem(&pki.shallow_server.certificate), pem(&pki.intermediates[1].certificate), pem(&pki.intermediates[0].certificate) });
        pki.deep_len = join(&pki.deep_chain, &.{ pem(&pki.deep_server.certificate), pem(&pki.intermediates[2].certificate), pem(&pki.intermediates[1].certificate), pem(&pki.intermediates[0].certificate) });
        return pki;
    }

    fn destroy(pki: *Pki) void {
        // Private keys, even disposable ones, do not linger in freed memory.
        std.crypto.secureZero(u8, std.mem.asBytes(pki));
        testing.allocator.destroy(pki);
    }

    fn rootPem(pki: *const Pki) []const u8 {
        return pem(&pki.root.certificate);
    }
};

fn ok(result: c_int) !void {
    if (result != 0) {
        std.debug.print("test identity generation failed: -0x{x}\n", .{-result});
        return error.IdentityGenerationFailed;
    }
}

fn pem(bytes: []const u8) []const u8 {
    return std.mem.sliceTo(bytes, 0);
}

fn join(out: []u8, parts: []const []const u8) usize {
    var length: usize = 0;
    for (parts) |part| {
        @memcpy(out[length..][0..part.len], part);
        length += part.len;
    }
    return length;
}

fn serverCredentials(t: *Transport, trust: []const u8, chain: []const u8, identity: *const Identity) !CredentialsHandle {
    return t.createCredentials(.{
        .role = .server,
        .trust_roots = trust,
        .certificate_chain = chain,
        .private_key = pem(&identity.private_key),
    });
}

fn clientCredentials(t: *Transport, trust: []const u8, identity: *const Identity, name: []const u8, pin: transport.KeyFingerprint) !CredentialsHandle {
    return t.createCredentials(.{
        .role = .client,
        .trust_roots = trust,
        .certificate_chain = pem(&identity.certificate),
        .private_key = pem(&identity.private_key),
        .server_name = name,
        .server_key = pin,
    });
}

// -- driving a connection --------------------------------------------------------------

const Pace = enum { memory, real_time };

const Link = struct {
    t: *Transport,
    listener: ListenerHandle,
    client: StreamHandle,
    server: ?StreamHandle = null,
    pace: Pace,

    fn open(t: *Transport, server_credentials: CredentialsHandle, client_credentials: CredentialsHandle, pace: Pace) !Link {
        const listener = try t.listen(transport.Endpoint.loopback(0), server_credentials);
        const client = try t.connect(t.listenerEndpoint(listener).?, client_credentials);
        return .{ .t = t, .listener = listener, .client = client, .pace = pace };
    }

    fn pump(self: *Link) !void {
        if (self.server == null) {
            switch (try self.t.accept(self.listener)) {
                .none => {},
                .stream => |stream| self.server = stream,
                .shed => return error.UnexpectedShed,
            }
        }
        _ = try self.t.advance(self.client);
        if (self.server) |stream| _ = try self.t.advance(stream);
    }

    fn clientState(self: *Link) State {
        return self.t.state(self.client).?;
    }

    fn serverState(self: *Link) ?State {
        return if (self.server) |stream| self.t.state(stream).? else null;
    }

    /// Pumps until the handshake is over on both ends — each established or failed — or
    /// until one end has failed and the other has nothing more to learn.
    fn settle(self: *Link) !void {
        var round: usize = 0;
        while (round < 20_000) : (round += 1) {
            try self.pump();
            const client = self.clientState();
            const server = self.serverState();
            const client_done = client == .established or client == .failed;
            const server_done = if (server) |s| s == .established or s == .failed else false;
            if (client_done and server_done) return;
            if (client == .failed and self.server == null and round > 64) return;
            if (self.pace == .real_time and round > 32) std.Io.sleep(testing.io, .fromNanoseconds(500 * std.time.ns_per_us), .awake) catch {};
        }
        return error.DidNotSettle;
    }

    /// Pumps both ends until `stream` has read exactly `out.len` bytes, or ends.
    fn receive(self: *Link, stream: StreamHandle, out: []u8) !void {
        var filled: usize = 0;
        var round: usize = 0;
        while (filled < out.len) : (round += 1) {
            if (round > 200_000) return error.DidNotArrive;
            try self.pump();
            switch (try self.t.read(stream, out[filled..])) {
                .data => |n| filled += n,
                .would_block => if (self.pace == .real_time and round > 32) {
                    std.Io.sleep(testing.io, .fromNanoseconds(200 * std.time.ns_per_us), .awake) catch {};
                },
                .closed => return error.ClosedEarly,
            }
        }
    }

    /// Moves `bytes` from one stream to the other, reading as it writes so neither
    /// direction's buffers can fill and wait on the other.
    fn transfer(self: *Link, from: StreamHandle, bytes: []const u8, to: StreamHandle, out: []u8) !void {
        var sent: usize = 0;
        var filled: usize = 0;
        var round: usize = 0;
        while (filled < out.len) : (round += 1) {
            if (round > 2_000_000) return error.TransferStalled;
            if (sent < bytes.len) sent += try self.t.write(from, bytes[sent..]);
            try self.pump();
            switch (try self.t.read(to, out[filled..])) {
                .data => |n| filled += n,
                .would_block => if (self.pace == .real_time and round > 32 and sent == bytes.len) {
                    std.Io.sleep(testing.io, .fromNanoseconds(100 * std.time.ns_per_us), .awake) catch {};
                },
                .closed => return error.ClosedEarly,
            }
        }
    }

    /// Hands all of `bytes` to `stream`, pumping while it would block.
    fn send(self: *Link, stream: StreamHandle, bytes: []const u8) !void {
        var sent: usize = 0;
        var round: usize = 0;
        while (sent < bytes.len) : (round += 1) {
            if (round > 200_000) return error.DidNotSend;
            sent += try self.t.write(stream, bytes[sent..]);
            try self.pump();
        }
    }
};

fn memoryTransport(options: transport.Options) !*Transport {
    var with_memory = options;
    with_memory.carrier = .memory;
    return Transport.init(testing.allocator, with_memory);
}

// -- real loopback --------------------------------------------------------------------

test "mutual TLS 1.3 over real loopback carries bytes both ways and closes in order" {
    const t = try Transport.init(testing.allocator, .{ .civil_clock = .{ .fixed = now }, .max_streams = 4 });
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();

    const server_credentials = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
    const client_credentials = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());
    const credentials_only = t.stats().tls_allocated;

    var link = try Link.open(t, server_credentials, client_credentials, .real_time);
    try testing.expectError(error.NotEstablished, t.read(link.client, &.{}));
    try testing.expectError(error.NotEstablished, t.write(link.client, "early"));
    try link.settle();
    try testing.expectEqual(State.established, link.clientState());
    try testing.expectEqual(State.established, link.serverState().?);

    // Each side holds the other's verified key, and nothing else.
    try testing.expect((try t.peer(link.client)).key.eql(pki.server.key()));
    const client_seen = try t.peer(link.server.?);
    try testing.expect(client_seen.key.eql(pki.client.key()));
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &client_seen.remote.address);

    const greeting = "hello from player one";
    try link.send(link.client, greeting);
    var received: [greeting.len]u8 = undefined;
    try link.receive(link.server.?, &received);
    try testing.expectEqualStrings(greeting, &received);

    // More than a socket buffer's worth, the other way: every byte, in order.
    const bulk = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(bulk);
    for (bulk, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);
    const echoed = try testing.allocator.alloc(u8, bulk.len);
    defer testing.allocator.free(echoed);
    try link.transfer(link.server.?, bulk, link.client, echoed);
    try testing.expectEqualSlices(u8, bulk, echoed);

    // An orderly close reaches the other end as `closed`, not as a failure.
    t.close(link.client);
    var tail: [1]u8 = undefined;
    var round: usize = 0;
    const outcome = while (round < 20_000) : (round += 1) {
        const result = try t.read(link.server.?, &tail);
        if (result != .would_block) break result;
        std.Io.sleep(testing.io, .fromNanoseconds(200 * std.time.ns_per_us), .awake) catch {};
    } else return error.CloseNeverArrived;
    try testing.expectEqual(transport.Read.closed, outcome);
    try testing.expectError(error.StreamClosed, t.write(link.server.?, "late"));
    try testing.expectError(error.InvalidHandle, t.advance(link.client));

    t.close(link.server.?);
    t.closeListener(link.listener);
    try testing.expectEqual(@as(u32, 0), t.stats().streams);

    // The provider's key store grows once, on first use, and is bounded; after that every
    // session gives back exactly what it took.
    const after_first = t.stats().tls_allocated;
    try testing.expect(after_first >= credentials_only and after_first - credentials_only <= 4096);
    var second = try Link.open(t, server_credentials, client_credentials, .real_time);
    try second.settle();
    try testing.expectEqual(State.established, second.clientState());
    t.close(second.client);
    t.close(second.server.?);
    t.closeListener(second.listener);
    try testing.expectEqual(after_first, t.stats().tls_allocated);
}

test "refused, occupied and abandoned loopback connections fail with their own reasons" {
    const t = try Transport.init(testing.allocator, .{ .civil_clock = .{ .fixed = now }, .max_listeners = 2, .max_streams = 4 });
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();
    const server_credentials = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
    const client_credentials = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());

    // An address already listened on refuses a second listener.
    const first = try t.listen(transport.Endpoint.loopback(0), server_credentials);
    try testing.expectError(error.AddressInUse, t.listen(t.listenerEndpoint(first).?, server_credentials));

    // Nothing listening: the connect fails as refused, without blocking the caller.
    const vacated = t.listenerEndpoint(first).?;
    t.closeListener(first);
    const refused = try t.connect(vacated, client_credentials);
    var round: usize = 0;
    while (t.state(refused).? == .connecting) : (round += 1) {
        if (round > 20_000) return error.RefusalNeverArrived;
        _ = try t.advance(refused);
        std.Io.sleep(testing.io, .fromNanoseconds(500 * std.time.ns_per_us), .awake) catch {};
    }
    try testing.expectEqual(State.failed, t.state(refused).?);
    try testing.expectEqual(Failure.refused, t.failure(refused).?);
    t.close(refused);

    // The server gives up mid-handshake: the client learns the connection ended early.
    var link = try Link.open(t, server_credentials, client_credentials, .real_time);
    while (link.server == null) try link.pump();
    t.close(link.server.?);
    link.server = null;
    round = 0;
    while (link.clientState() != .failed) : (round += 1) {
        if (round > 20_000) return error.AbandonmentNeverArrived;
        _ = try t.advance(link.client);
        std.Io.sleep(testing.io, .fromNanoseconds(500 * std.time.ns_per_us), .awake) catch {};
    }
    const reason = t.failure(link.client).?;
    try testing.expect(reason == .closed_early or reason == .reset);
}

test "a plaintext peer is given neither bytes nor a session" {
    const t = try Transport.init(testing.allocator, .{ .civil_clock = .{ .fixed = now } });
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();
    const server_credentials = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
    const listener = try t.listen(transport.Endpoint.loopback(0), server_credentials);

    // An ordinary blocking socket speaking FNET in the clear, as a confused or hostile
    // client would.
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(t.listenerEndpoint(listener).?.port) };
    const raw = try address.connect(testing.io, .{ .mode = .stream });
    defer raw.close(testing.io);
    var buffer: [128]u8 = undefined;
    var writer = raw.writer(testing.io, &buffer);
    var frame: [net.wire.header_size]u8 = undefined;
    try net.wire.encodeHeader(&frame, .{ .kind = .heartbeat, .total_bytes = net.wire.header_size, .sequence = 1 }, net.limits.wire_v1_max_frame_bytes);
    try writer.interface.writeAll(&frame);
    try writer.interface.flush();

    var server: ?StreamHandle = null;
    var round: usize = 0;
    while (server == null or t.state(server.?).? == .handshaking) : (round += 1) {
        if (round > 20_000) return error.PlaintextNeverRefused;
        if (server == null) {
            switch (try t.accept(listener)) {
                .stream => |stream| server = stream,
                else => {},
            }
        } else _ = try t.advance(server.?);
        std.Io.sleep(testing.io, .fromNanoseconds(200 * std.time.ns_per_us), .awake) catch {};
    }
    try testing.expectEqual(State.failed, t.state(server.?).?);
    try testing.expectEqual(Failure.protocol, t.failure(server.?).?);
    var nothing: [64]u8 = undefined;
    try testing.expectError(error.StreamFailed, t.read(server.?, &nothing));
    try testing.expectError(error.NotEstablished, t.peer(server.?));
}

// -- the certificate matrix, over the memory carrier ----------------------------------

const Expectation = struct {
    client: ?Failure = null,
    server: ?Failure = null,
    /// TLS 1.3 finishes the client's handshake before the server judges the client's
    /// certificate, so the client learns of that refusal on its first read.
    client_refused_on_read: bool = false,
};

fn expectOutcome(
    pki: *const Pki,
    clock: i64,
    server_chain: []const u8,
    server_identity: *const Identity,
    client_trust: []const u8,
    client_identity: *const Identity,
    name: []const u8,
    pin: transport.KeyFingerprint,
    expected: Expectation,
) !void {
    const t = try memoryTransport(.{ .civil_clock = .{ .fixed = clock } });
    defer t.deinit();
    const server_credentials = try serverCredentials(t, pki.rootPem(), server_chain, server_identity);
    const client_credentials = try clientCredentials(t, client_trust, client_identity, name, pin);
    var link = try Link.open(t, server_credentials, client_credentials, .memory);
    try link.settle();

    if (expected.client) |reason| {
        try testing.expectEqual(State.failed, link.clientState());
        try testing.expectEqual(reason, t.failure(link.client).?);
        // The server fails too, but cannot always know why: a client that refuses the
        // server's certificate has not installed its handshake keys yet, so its alert
        // travels unprotected (RFC 8446 §6) and a server already reading encrypted
        // records cannot authenticate it. Only the refusing side names the reason.
        try testing.expectEqual(State.failed, link.serverState().?);
        const seen = t.failure(link.server.?).?;
        try testing.expect(seen == .peer_refused or seen == .protocol);
    }
    if (expected.server) |reason| {
        try testing.expectEqual(State.failed, link.serverState().?);
        try testing.expectEqual(reason, t.failure(link.server.?).?);
    }
    if (expected.client_refused_on_read) {
        try testing.expectEqual(State.established, link.clientState());
        var scratch: [16]u8 = undefined;
        var round: usize = 0;
        while (true) : (round += 1) {
            if (round > 1000) return error.RefusalNeverReachedClient;
            const result = t.read(link.client, &scratch) catch break;
            try testing.expect(result == .would_block);
        }
        // Refused, but not always legibly: the server's alert is protected with keys the
        // client has already moved past, so the client may see only a record it cannot
        // authenticate. The server named the reason; the client cannot use the stream.
        const seen = t.failure(link.client).?;
        try testing.expect(seen == .peer_refused or seen == .protocol);
    }
    if (expected.client == null and expected.server == null and !expected.client_refused_on_read) {
        try testing.expectEqual(State.established, link.clientState());
        try testing.expectEqual(State.established, link.serverState().?);
    }
}

test "every certificate refusal is named by the side that refused it" {
    const pki = pki: {
        // The fixture uses the provider, so it runs while a Transport holds it.
        const holder = try memoryTransport(.{});
        defer holder.deinit();
        break :pki try Pki.create();
    };
    defer pki.destroy();
    const server_pem = pem(&pki.server.certificate);
    const root = pki.rootPem();
    const foreign = pem(&pki.foreign_root.certificate);
    const pin = pki.server.key();

    // The positive control: the same machinery, nothing wrong.
    try expectOutcome(pki, now, server_pem, &pki.server, root, &pki.client, server_name, pin, .{});

    // What the client refuses about the server.
    try expectOutcome(pki, now, server_pem, &pki.server, foreign, &pki.client, server_name, pin, .{ .client = .certificate_untrusted });
    try expectOutcome(pki, after_expiry, server_pem, &pki.server, root, &pki.client, server_name, pin, .{ .client = .certificate_expired });
    try expectOutcome(pki, before_validity, server_pem, &pki.server, root, &pki.client, server_name, pin, .{ .client = .certificate_not_yet_valid });
    try expectOutcome(pki, now, server_pem, &pki.server, root, &pki.client, "other.foundry.test", pin, .{ .client = .certificate_wrong_name });
    try expectOutcome(pki, now, server_pem, &pki.server, root, &pki.client, server_name, pki.client.key(), .{ .client = .server_key_mismatch });

    // Four certificates are the most a chain may have; five are refused by length.
    const shallow = pki.shallow_chain[0..pki.shallow_len];
    const deep = pki.deep_chain[0..pki.deep_len];
    try expectOutcome(pki, now, shallow, &pki.shallow_server, root, &pki.client, server_name, pki.shallow_server.key(), .{});
    try expectOutcome(pki, now, deep, &pki.deep_server, root, &pki.client, server_name, pki.deep_server.key(), .{ .client = .certificate_chain_too_long });

    // What the server refuses about the client.
    try expectOutcome(pki, now, server_pem, &pki.server, root, &pki.foreign_client, server_name, pin, .{ .server = .certificate_untrusted, .client_refused_on_read = true });
    try expectOutcome(pki, now, server_pem, &pki.server, root, &pki.expired_client, server_name, pin, .{ .server = .certificate_expired, .client_refused_on_read = true });
}

test "credentials are checked against their role, their key and their use before any peer sees them" {
    const t = try memoryTransport(.{ .max_credentials = 2, .civil_clock = .{ .fixed = now } });
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();
    const root = pki.rootPem();

    // An identity presents only in the role its extendedKeyUsage names.
    try testing.expectError(error.WrongUsage, serverCredentials(t, root, pem(&pki.client.certificate), &pki.client));
    try testing.expectError(error.WrongUsage, clientCredentials(t, root, &pki.server, server_name, pki.server.key()));
    try testing.expectError(error.WrongUsage, clientCredentials(t, root, &pki.unmarked_client, server_name, pki.server.key()));
    // A key that is not the certificate's.
    try testing.expectError(error.KeyMismatch, serverCredentials(t, root, pem(&pki.server.certificate), &pki.client));
    try testing.expectEqual(@as(u32, 0), t.stats().credentials);

    const server_credentials = try serverCredentials(t, root, pem(&pki.server.certificate), &pki.server);
    const client_credentials = try clientCredentials(t, root, &pki.client, server_name, pki.server.key());
    try testing.expectError(error.LimitReached, serverCredentials(t, root, pem(&pki.server.certificate), &pki.server));

    try testing.expectError(error.WrongRole, t.listen(transport.Endpoint.loopback(0), client_credentials));
    try testing.expectError(error.WrongRole, t.connect(transport.Endpoint.loopback(9), server_credentials));
    try testing.expectError(error.InvalidEndpoint, t.connect(transport.Endpoint.loopback(0), client_credentials));
    try testing.expectError(error.InvalidEndpoint, t.connect(try transport.Endpoint.parse("255.255.255.255:9"), client_credentials));

    // Credentials outlive every listener and stream that uses them.
    const listener = try t.listen(transport.Endpoint.loopback(0), server_credentials);
    try testing.expectError(error.CredentialsInUse, t.destroyCredentials(server_credentials));
    t.closeListener(listener);
    try t.destroyCredentials(server_credentials);
    try testing.expectError(error.InvalidHandle, t.destroyCredentials(server_credentials));
}

// -- the memory carrier's faults ------------------------------------------------------

fn establishedMemoryLink(t: *Transport, pki: *const Pki) !Link {
    const server_credentials = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
    const client_credentials = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());
    var link = try Link.open(t, server_credentials, client_credentials, .memory);
    try link.settle();
    try testing.expectEqual(State.established, link.clientState());
    try testing.expectEqual(State.established, link.serverState().?);
    return link;
}

test "the wire carries ciphertext only, and a tampered record fails the stream that reads it" {
    const t = try memoryTransport(.{ .civil_clock = .{ .fixed = now } });
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();
    var link = try establishedMemoryLink(t, pki);

    const marker = "FNET-PLAINTEXT-MARKER-0123456789";
    try testing.expectEqual(marker.len, try t.write(link.client, marker));
    var wire: [4096]u8 = undefined;
    const on_wire = wire[0..try t.memoryInFlight(link.client, &wire)];
    try testing.expect(on_wire.len > marker.len);
    try testing.expect(std.mem.indexOf(u8, on_wire, marker) == null);
    var clear: [marker.len]u8 = undefined;
    try link.receive(link.server.?, &clear);
    try testing.expectEqualStrings(marker, &clear);

    // One flipped bit in flight: the record fails authentication and the stream ends.
    try testing.expectEqual(marker.len, try t.write(link.client, marker));
    try t.memoryCorruptInbound(link.server.?);
    try testing.expectError(error.StreamFailed, t.read(link.server.?, &clear));
    try testing.expectEqual(Failure.protocol, t.failure(link.server.?).?);
}

test "fragmented, stalled and saturated carriers still deliver every byte in order" {
    const t = try memoryTransport(.{
        .civil_clock = .{ .fixed = now },
        .memory = .{ .capacity = 512, .max_transfer = 7 },
    });
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();

    const server_credentials = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
    const client_credentials = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());
    var link = try Link.open(t, server_credentials, client_credentials, .memory);

    // A stalled client makes no progress, and waiting is not counted against it.
    try link.pump();
    try t.memoryStall(link.client, true);
    for (0..500) |_| try link.pump();
    try testing.expectEqual(State.handshaking, link.clientState());
    try t.memoryStall(link.client, false);
    try link.settle();
    try testing.expectEqual(State.established, link.clientState());
    try testing.expectEqual(State.established, link.serverState().?);

    // 64 KiB through a 512-byte pipe, seven bytes a call: the stream must hold records the
    // carrier cannot take yet, and deliver them unchanged.
    const bulk = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(bulk);
    for (bulk, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% 17);
    const received = try testing.allocator.alloc(u8, bulk.len);
    defer testing.allocator.free(received);

    var sent: usize = 0;
    var filled: usize = 0;
    var held_back = false;
    var round: usize = 0;
    while (filled < bulk.len) : (round += 1) {
        if (round > 1_000_000) return error.BulkNeverArrived;
        if (sent < bulk.len) sent += try t.write(link.client, bulk[sent..]);
        if (try t.pendingBytes(link.client) != 0) held_back = true;
        _ = try t.advance(link.client);
        switch (try t.read(link.server.?, received[filled..])) {
            .data => |n| filled += n,
            .would_block => {},
            .closed => return error.ClosedEarly,
        }
    }
    try testing.expect(held_back);
    try testing.expectEqualSlices(u8, bulk, received);
}

test "a peer that trickles its handshake exhausts the call budget, and only the budget stops it" {
    const pki = pki: {
        const holder = try memoryTransport(.{});
        defer holder.deinit();
        break :pki try Pki.create();
    };
    defer pki.destroy();

    inline for (.{ @as(u16, 64), @as(u16, 4096) }) |limit| {
        const t = try memoryTransport(.{
            .civil_clock = .{ .fixed = now },
            .handshake_call_limit = limit,
            .memory = .{ .capacity = 8 },
        });
        defer t.deinit();
        const server_credentials = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
        const client_credentials = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());
        var link = try Link.open(t, server_credentials, client_credentials, .memory);
        var round: usize = 0;
        while (round < 100_000) : (round += 1) {
            try link.pump();
            const client = link.clientState();
            const server = link.serverState() orelse continue;
            if (client == .failed or server == .failed) break;
            if (client == .established and server == .established) break;
        }
        if (limit == 64) {
            const budget_hit = t.failure(link.client) == .handshake_budget or
                (link.server != null and t.failure(link.server.?) == .handshake_budget);
            try testing.expect(budget_hit);
        } else {
            try testing.expectEqual(State.established, link.clientState());
            try testing.expectEqual(State.established, link.serverState().?);
        }
    }
}

test "a reset connection fails both ends as a reset, during and after the handshake" {
    const t = try memoryTransport(.{ .civil_clock = .{ .fixed = now } });
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();
    const server_credentials = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
    const client_credentials = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());

    var during = try Link.open(t, server_credentials, client_credentials, .memory);
    try during.pump();
    try testing.expectEqual(State.handshaking, during.clientState());
    try testing.expectEqual(State.handshaking, during.serverState().?);
    try t.memoryReset(during.client);
    try during.pump();
    try testing.expectEqual(Failure.reset, t.failure(during.client).?);
    try testing.expectEqual(Failure.reset, t.failure(during.server.?).?);
    t.close(during.client);
    t.close(during.server.?);
    t.closeListener(during.listener);

    var after = try Link.open(t, server_credentials, client_credentials, .memory);
    try after.settle();
    try t.memoryReset(after.server.?);
    var scratch: [8]u8 = undefined;
    try testing.expectError(error.StreamFailed, t.read(after.client, &scratch));
    try testing.expectEqual(Failure.reset, t.failure(after.client).?);
}

test "a clock that cannot be trusted refuses the handshake" {
    const pki = pki: {
        const holder = try memoryTransport(.{});
        defer holder.deinit();
        break :pki try Pki.create();
    };
    defer pki.destroy();
    // 2001: a machine whose clock was never set.
    const t = try memoryTransport(.{ .civil_clock = .{ .fixed = 1_000_000_000 } });
    defer t.deinit();
    const server_credentials = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
    const client_credentials = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());
    var link = try Link.open(t, server_credentials, client_credentials, .memory);
    try link.pump();
    try testing.expectEqual(State.failed, link.clientState());
    try testing.expectEqual(Failure.clock_unavailable, t.failure(link.client).?);
}

test "the provider's memory is capped, counted and given back" {
    const pki = pki: {
        const holder = try memoryTransport(.{});
        defer holder.deinit();
        break :pki try Pki.create();
    };
    defer pki.destroy();

    // Measure what two sets of credentials cost, then grant only a little more than that.
    const credentials_cost = cost: {
        const t = try memoryTransport(.{ .civil_clock = .{ .fixed = now } });
        defer t.deinit();
        _ = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
        _ = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());
        break :cost t.stats().tls_allocated;
    };

    const limit = credentials_cost + 8 * 1024;
    const t = try memoryTransport(.{ .civil_clock = .{ .fixed = now }, .tls_allocation_limit = limit });
    defer t.deinit();
    const server_credentials = try serverCredentials(t, pki.rootPem(), pem(&pki.server.certificate), &pki.server);
    const client_credentials = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());
    const listener = try t.listen(transport.Endpoint.loopback(0), server_credentials);
    // A session's record buffers do not fit: the connect is refused locally, whole.
    try testing.expectError(error.TlsMemoryExhausted, t.connect(t.listenerEndpoint(listener).?, client_credentials));
    try testing.expectEqual(@as(u32, 0), t.stats().streams);
    try testing.expect(t.stats().tls_allocation_peak <= limit);
    try testing.expectEqual(credentials_cost, t.stats().tls_allocated);
}

test "streams beyond capacity are shed before authentication, and handles do not outlive them" {
    const t = try memoryTransport(.{ .civil_clock = .{ .fixed = now }, .max_streams = 3 });
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();
    const link = try establishedMemoryLink(t, pki);
    const client_credentials = try clientCredentials(t, pki.rootPem(), &pki.client, server_name, pki.server.key());

    // The third stream is a connecting client; there is no room to accept it.
    const extra = try t.connect(t.listenerEndpoint(link.listener).?, client_credentials);
    try testing.expectError(error.LimitReached, t.connect(t.listenerEndpoint(link.listener).?, client_credentials));
    try testing.expectEqual(transport.Accepted.shed, try t.accept(link.listener));
    try testing.expectEqual(@as(u64, 1), t.stats().shed);
    _ = try t.advance(extra);
    try testing.expectEqual(Failure.reset, t.failure(extra).?);

    // A closed stream's handle is stale forever, even once its slot is reused.
    t.close(extra);
    try testing.expectError(error.InvalidHandle, t.advance(extra));
    const reused = try t.connect(t.listenerEndpoint(link.listener).?, client_credentials);
    try testing.expectEqual(extra.index, reused.index);
    try testing.expect(extra.generation != reused.generation);
    try testing.expectError(error.InvalidHandle, t.advance(extra));

    // A listener that closes resets the connections it never accepted.
    t.closeListener(link.listener);
    _ = try t.advance(reused);
    try testing.expectEqual(Failure.reset, t.failure(reused).?);
    // Accepted streams are not the listener's to end.
    try testing.expectEqual(State.established, t.state(link.server.?).?);
}

test "an FNET frame crosses an authenticated stream intact" {
    const t = try memoryTransport(.{ .civil_clock = .{ .fixed = now }, .memory = .{ .max_transfer = 13 } });
    defer t.deinit();
    const pki = try Pki.create();
    defer pki.destroy();
    var link = try establishedMemoryLink(t, pki);

    const heartbeat: net.wire.Heartbeat = .{ .session_epoch = 7, .last_received_sequence = 41 };
    var payload: [net.wire.Heartbeat.encoded_size]u8 = undefined;
    try heartbeat.encode(&payload);
    var out: [net.wire.header_size + payload.len]u8 = undefined;
    const frame = try net.wire.encodeFrame(&out, .{
        .kind = .heartbeat,
        .total_bytes = out.len,
        .sequence = 1,
    }, &payload, net.limits.wire_v1_max_frame_bytes);
    try link.send(link.client, frame);

    const storage = try testing.allocator.alloc(u8, net.limits.wire_v1_max_frame_bytes);
    defer testing.allocator.free(storage);
    var decoder = try net.wire.Decoder.init(storage, net.limits.wire_v1_max_frame_bytes);
    var chunk: [5]u8 = undefined;
    var round: usize = 0;
    const decoded = while (round < 100_000) : (round += 1) {
        try link.pump();
        switch (try t.read(link.server.?, &chunk)) {
            .data => |n| {
                const progress = try decoder.feed(chunk[0..n]);
                try testing.expectEqual(n, progress.consumed);
                if (progress.frame) |complete| break complete;
            },
            .would_block => {},
            .closed => return error.ClosedEarly,
        }
    } else return error.FrameNeverArrived;
    try testing.expectEqual(net.wire.Kind.heartbeat, decoded.header.kind);
    try testing.expectEqual(heartbeat, try net.wire.Heartbeat.decode(decoded.payload));
}
