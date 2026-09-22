//! Authenticated byte streams: listeners, connections and TLS 1.3 sessions (M16 Step 2).
//!
//! `net` builds sessions out of what this file hands it, and this file is where every
//! socket, certificate and provider type stops (ADR-0045, `networking.md` §3). Nothing
//! above `platform` sees a descriptor, an Mbed TLS structure or a key: they see
//! generational handles (I1), a state, a byte count and a `Failure`.
//!
//! ## There is no plaintext path
//!
//! A stream is TLS from the first byte to the last. `read` and `write` refuse until the
//! handshake has verified the peer's chain, validity, role and — for a client — the
//! server's pinned key and name, and until both sides agreed on `fnet/1`. There is no
//! option that skips any of it and no stream kind that lacks it, so "no plaintext
//! fallback" is a property of the type rather than of a flag somebody remembered.
//!
//! ## Nothing waits
//!
//! Every call does a bounded amount of work and returns. Connecting reports completion
//! when it has happened; accepting takes one pending connection or none; a handshake
//! call is exactly one provider call (`networking.md` §4's per-pump budget), and a
//! stream that needs more than `handshake_call_limit` calls that actually moved bytes is
//! failed. One owning thread drives it all; no worker, no `Io` instance, no callback into
//! a caller.
//!
//! ## Why the sockets are C
//!
//! Zig 0.16's `std.Io.net` blocks: it has no would-block result, a connect with a
//! timeout is an unimplemented panic, and `std.os.windows.ws2_32` declares no Winsock
//! function. `transport/socket.c` calls each OS's own API — BSD sockets on macOS and
//! Linux, Winsock 2 on Windows — compiled against that target's headers, beside
//! `transport/tls.c` over the qualified provider. Both sit behind
//! `transport/foundry_transport.h`, whose only types are integers and opaque pointers.
//!
//! ## Two carriers
//!
//! A stream's ciphertext travels over the OS (`.system`) or over in-process pipes
//! (`.memory`), chosen per `Transport`. The memory carrier is the deterministic fake
//! `net`'s tests are built on: it fragments, stalls, resets and corrupts on command. It
//! carries the same TLS as a socket does — it replaces the wire, never the
//! authentication.
//!
//! Design: `docs/design/networking.md` §3–§4.1 and its Step 2 Resolution.

const std = @import("std");
const core = @import("core");

const c = @cImport({
    @cInclude("foundry_transport.h");
});

const Allocator = std.mem.Allocator;

/// The largest plaintext one TLS record carries; a retried write keeps this much.
const record_capacity: usize = 16 * 1024;

/// The most connections a memory listener can hold unaccepted.
pub const max_memory_backlog = 32;

/// Certificates a peer's chain may hold, root included. A deeper chain is refused.
pub const max_chain_certificates: u16 = c.FOUNDRY_TLS_MAX_CHAIN_CERTIFICATES;

/// The largest handshake message the provider accepts, so the most an encoded
/// certificate chain can occupy: every message must fit one input record.
pub const max_handshake_message_bytes: u32 = c.FOUNDRY_TLS_MAX_HANDSHAKE_MESSAGE;

// -- identity types -----------------------------------------------------------

pub const Listener = opaque {};
pub const Stream = opaque {};
pub const Credentials = opaque {};

pub const ListenerHandle = core.Handle(Listener);
pub const StreamHandle = core.Handle(Stream);
pub const CredentialsHandle = core.Handle(Credentials);

pub const Role = enum { server, client };

/// SHA-256 of a certificate's SubjectPublicKeyInfo — the key, not the certificate, so a
/// renewal that keeps its key keeps its identity. `openssl x509 -pubkey -noout | openssl
/// pkey -pubin -outform der | openssl dgst -sha256` computes the same value.
pub const KeyFingerprint = struct {
    sha256: [32]u8,

    pub fn eql(a: KeyFingerprint, b: KeyFingerprint) bool {
        return std.mem.eql(u8, &a.sha256, &b.sha256);
    }
};

/// A numeric IPv4 endpoint. No names and no IPv6: DNS and discovery are not hidden
/// requirements of this transport (`networking.md` §4).
pub const Endpoint = struct {
    address: [4]u8,
    port: u16,

    pub const ParseError = error{InvalidEndpoint};

    pub fn loopback(port: u16) Endpoint {
        return .{ .address = .{ 127, 0, 0, 1 }, .port = port };
    }

    /// `a.b.c.d:port` exactly: decimal, no leading zeros, no sign, no whitespace. Port 0
    /// parses, because a listener may ask the OS for one; `connect` refuses it.
    pub fn parse(text: []const u8) ParseError!Endpoint {
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidEndpoint;
        var address: [4]u8 = undefined;
        var parts = std.mem.splitScalar(u8, text[0..colon], '.');
        var count: usize = 0;
        while (parts.next()) |part| : (count += 1) {
            if (count == address.len) return error.InvalidEndpoint;
            address[count] = try parseDecimal(u8, part);
        }
        if (count != address.len) return error.InvalidEndpoint;
        return .{ .address = address, .port = try parseDecimal(u16, text[colon + 1 ..]) };
    }

    pub fn eql(a: Endpoint, b: Endpoint) bool {
        return a.port == b.port and std.mem.eql(u8, &a.address, &b.address);
    }

    pub fn format(self: Endpoint, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}.{d}:{d}", .{
            self.address[0], self.address[1], self.address[2], self.address[3], self.port,
        });
    }

    fn isUnspecified(self: Endpoint) bool {
        return std.mem.eql(u8, &self.address, &.{ 0, 0, 0, 0 });
    }

    /// Whether a connection may be addressed to it: a real port on a unicast address.
    pub fn isConnectable(self: Endpoint) bool {
        if (self.port == 0 or self.isUnspecified()) return false;
        if (self.address[0] >= 224) return false; // multicast, reserved and broadcast
        return true;
    }
};

fn parseDecimal(comptime T: type, digits: []const u8) Endpoint.ParseError!T {
    if (digits.len == 0 or digits.len > 5) return error.InvalidEndpoint;
    if (digits.len > 1 and digits[0] == '0') return error.InvalidEndpoint;
    var value: u32 = 0;
    for (digits) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidEndpoint;
        value = value * 10 + (digit - '0');
    }
    return std.math.cast(T, value) orelse error.InvalidEndpoint;
}

// -- configuration ------------------------------------------------------------

pub const Carrier = enum {
    /// The operating system's TCP.
    system,
    /// In-process pipes with deterministic fragmentation, stalls, resets and corruption.
    memory,
};

/// Where certificate validity is judged from.
pub const CivilClock = union(enum) {
    /// The OS civil clock, read before every handshake call. The only choice for a real
    /// session.
    system,
    /// A fixed instant in seconds since the Unix epoch, for proofs whose disposable
    /// identities have fixed validity windows. Never for a real session.
    fixed: i64,
};

pub const MemoryOptions = struct {
    /// Bytes one direction of a memory connection holds before its writer would block.
    capacity: u32 = 64 * 1024,
    /// The most bytes one carrier call moves. One delivers a byte at a time.
    max_transfer: u32 = 64 * 1024,
    /// Connections a memory listener holds unaccepted before refusing more.
    backlog: u8 = 8,
};

/// Bounds, all of them checked at `init` and none of them derived from received bytes.
/// `net` supplies its session envelope here (`networking.md` §4's table).
pub const Options = struct {
    carrier: Carrier = .system,
    max_listeners: u8 = 1,
    /// Admitted peers and handshakes in progress, together.
    max_streams: u16 = 12,
    max_credentials: u8 = 4,
    /// The OS listen backlog.
    backlog: u16 = 16,
    /// Process-wide provider allocation, zeroized on free. The first live `Transport`'s
    /// value governs until the last one is gone.
    tls_allocation_limit: usize = 16 * 1024 * 1024,
    /// Provider handshake calls that moved bytes, per connection.
    handshake_call_limit: u16 = 64,
    civil_clock: CivilClock = .system,
    memory: MemoryOptions = .{},
};

pub const InitError = error{
    /// A bound is zero, out of range or inconsistent.
    InvalidOptions,
    OutOfMemory,
    /// The provider could not seed itself from the OS. Nothing is opened without it.
    EntropyUnavailable,
    /// The OS socket library would not start.
    NetworkUnavailable,
    ProviderUnavailable,
};

pub const CredentialConfig = struct {
    role: Role,
    /// Out-of-band trust roots, PEM (one or more certificates) or one DER certificate.
    trust_roots: []const u8,
    /// This side's certificate, leaf first, PEM or one DER certificate. It must carry an
    /// extendedKeyUsage naming `role`, and a P-256 key.
    certificate_chain: []const u8,
    /// The matching unencrypted private key, PEM or DER. Copied into zeroized provider
    /// memory; the caller should wipe its own copy once this returns.
    private_key: []const u8,
    /// Client only: the separately granted server identity, checked against the server
    /// certificate's names. A numeric destination never replaces it.
    server_name: []const u8 = "",
    /// Client only: the server key provisioned out of band. Required.
    server_key: ?KeyFingerprint = null,
};

pub const CredentialError = error{
    LimitReached,
    OutOfMemory,
    InvalidTrustRoots,
    InvalidCertificate,
    InvalidPrivateKey,
    /// The private key does not belong to the certificate.
    KeyMismatch,
    /// Not a P-256 key, the only kind the qualified signature algorithm can use.
    UnsupportedKey,
    /// The certificate's extendedKeyUsage does not name this role.
    WrongUsage,
    /// A client without a valid server name or pinned key, or a server with either.
    InvalidServerIdentity,
    EntropyUnavailable,
    ProviderUnavailable,
};

// -- streams --------------------------------------------------------------------

pub const State = enum {
    /// A client's TCP connect has not finished.
    connecting,
    /// TLS is in progress; nothing may be read or written.
    handshaking,
    /// Authenticated in both directions, as far as this side can know. A client learns
    /// that the server refused *its* certificate only on its first read, as
    /// `peer_refused`: TLS 1.3 finishes the client's handshake before the server has
    /// judged it. It stays established only while the peer's chain is valid: `advance`
    /// fails it as `certificate_expired` once the civil clock passes `Peer.valid_until`.
    established,
    /// The peer sent close_notify. Reading answers `closed`; writing is refused.
    closed,
    failed,
};

/// Why a stream failed. Every value is a category, never a secret or a certificate's
/// content, so it is safe to log and to hand upward.
pub const Failure = enum {
    refused,
    unreachable_address,
    timed_out,
    reset,
    /// The connection ended during the handshake.
    closed_early,
    /// The connection ended after the handshake without a close_notify.
    truncated,
    network_down,
    carrier,

    certificate_missing,
    certificate_untrusted,
    certificate_expired,
    certificate_not_yet_valid,
    certificate_wrong_usage,
    certificate_wrong_name,
    certificate_rejected,
    certificate_chain_too_long,
    server_key_mismatch,
    /// The peer ended the handshake with a fatal alert: it refused this side.
    peer_refused,
    /// A malformed, unexpected, tampered or replayed record, or no `fnet/1` agreement.
    protocol,

    handshake_budget,
    tls_memory,
    /// The civil clock was unavailable or implausibly early.
    clock_unavailable,
    internal,
};

pub const StreamError = error{
    InvalidHandle,
    /// Still connecting or handshaking.
    NotEstablished,
    /// The peer closed; nothing more may be written.
    StreamClosed,
    /// See `failure`.
    StreamFailed,
};

pub const Read = union(enum) {
    data: usize,
    would_block,
    /// The peer's close_notify: an orderly end.
    closed,
};

pub const Accepted = union(enum) {
    none,
    stream: StreamHandle,
    /// A pending connection was taken and closed because no stream or provider memory was
    /// left for it. Refusal before authentication is local, immediate and generic.
    shed,
};

pub const Peer = struct {
    key: KeyFingerprint,
    remote: Endpoint,
    /// The earliest notAfter in the verified chain, in seconds since the Unix epoch: the
    /// last instant this identity is valid, however long the connection lasts.
    valid_until: i64,
};

pub const ListenError = error{
    InvalidHandle,
    /// Listening needs server credentials.
    WrongRole,
    LimitReached,
    AddressInUse,
    AddressUnavailable,
    PermissionDenied,
    NetworkUnavailable,
    SystemResources,
    Unexpected,
};

pub const AcceptError = error{ InvalidHandle, SystemResources, NetworkUnavailable, Unexpected };

pub const ConnectError = error{
    InvalidHandle,
    /// Connecting needs client credentials.
    WrongRole,
    /// Port 0, an unspecified, multicast or broadcast address.
    InvalidEndpoint,
    LimitReached,
    /// No provider memory left for another session.
    TlsMemoryExhausted,
    SystemResources,
    NetworkUnavailable,
};

pub const Stats = struct {
    listeners: u32,
    streams: u32,
    credentials: u32,
    tls_allocated: usize,
    tls_allocation_peak: usize,
    /// Pending connections closed unauthenticated for want of room.
    shed: u64,
};

pub const MemoryError = error{ InvalidHandle, NotMemory, NothingInFlight };

// -- internals ------------------------------------------------------------------

const no_link = std.math.maxInt(u32);

/// `FOUNDRY_SOCKET_INVALID`, stated here rather than translated from a `UINT64_MAX` macro.
const invalid_socket: c.foundry_socket = std.math.maxInt(u64);

const CredentialSlot = struct {
    native: *c.foundry_tls_credentials,
    role: Role,
    /// Listeners and streams using it; destruction waits for none.
    users: u32 = 0,
};

const ListenerSlot = struct {
    credentials: CredentialsHandle,
    endpoint: Endpoint,
    socket: c.foundry_socket = invalid_socket,
    backlog: [max_memory_backlog]u32 = undefined,
    backlog_len: u8 = 0,
};

const StreamSlot = struct {
    state: State,
    role: Role,
    failure: ?Failure = null,
    credentials: CredentialsHandle,
    session: ?*c.foundry_tls_session = null,
    socket: c.foundry_socket = invalid_socket,
    link: u32 = no_link,
    side: u1 = 0,
    stalled: bool = false,
    remote: Endpoint,
    handshake_calls: u16 = 0,
    /// Plaintext already handed to the provider and awaiting its retry.
    pending: usize = 0,
    peer_key: ?KeyFingerprint = null,
    valid_until: i64 = 0,
    /// What the carrier last reported, so a provider failure it caused is named for it.
    carrier_failure: ?Failure = null,
};

/// What the provider's callbacks are handed: stable for the `Transport`'s life, one per
/// stream slot, and refreshed with the slot's current handle.
const CarrierContext = struct {
    transport: *Transport,
    stream: StreamHandle,
};

const Pipe = struct {
    bytes: []u8,
    start: usize = 0,
    len: usize = 0,

    fn write(self: *Pipe, data: []const u8) usize {
        const n = @min(data.len, self.bytes.len - self.len);
        var copied: usize = 0;
        while (copied < n) {
            const at = (self.start + self.len) % self.bytes.len;
            const run = @min(n - copied, self.bytes.len - at);
            @memcpy(self.bytes[at..][0..run], data[copied..][0..run]);
            copied += run;
            self.len += run;
        }
        return n;
    }

    fn read(self: *Pipe, out: []u8) usize {
        const n = @min(out.len, self.len);
        var copied: usize = 0;
        while (copied < n) {
            const run = @min(n - copied, self.bytes.len - self.start);
            @memcpy(out[copied..][0..run], self.bytes[self.start..][0..run]);
            copied += run;
            self.start = (self.start + run) % self.bytes.len;
            self.len -= run;
        }
        if (self.len == 0) self.start = 0;
        return n;
    }

    fn peek(self: *const Pipe, out: []u8) usize {
        var copy = self.*;
        return copy.read(out);
    }

    fn lastByte(self: *Pipe) ?*u8 {
        if (self.len == 0) return null;
        return &self.bytes[(self.start + self.len - 1) % self.bytes.len];
    }
};

/// One memory connection. `pipes[side]` carries what `side` wrote; side 0 connected,
/// side 1 accepted. It outlives either stream until both have closed, so a peer can
/// still drain what was written before a close.
const Link = struct {
    in_use: bool = false,
    pipes: [2]Pipe,
    open: [2]bool = .{ false, false },
    reset: bool = false,
};

const ListenerPool = core.HandlePool(Listener, ListenerSlot);
const StreamPool = core.HandlePool(Stream, StreamSlot);
const CredentialPool = core.HandlePool(Credentials, CredentialSlot);

pub const Transport = struct {
    gpa: Allocator,
    options: Options,
    listeners: ListenerPool = .empty,
    streams: StreamPool = .empty,
    credentials: CredentialPool = .empty,
    carriers: []CarrierContext,
    pending: []u8,
    links: []Link = &.{},
    link_storage: []u8 = &.{},
    next_memory_port: u16 = 49152,
    shed: u64 = 0,
    sockets_started: bool = false,

    /// Heap-allocated because the provider holds pointers into it for every stream.
    pub fn init(gpa: Allocator, options: Options) InitError!*Transport {
        try validateOptions(options);

        const self = try gpa.create(Transport);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .options = options,
            .carriers = &.{},
            .pending = &.{},
        };
        errdefer self.freeStorage();

        try self.listeners.ensureUnusedCapacity(gpa, options.max_listeners);
        try self.streams.ensureUnusedCapacity(gpa, options.max_streams);
        try self.credentials.ensureUnusedCapacity(gpa, options.max_credentials);
        self.carriers = try gpa.alloc(CarrierContext, options.max_streams);
        for (self.carriers) |*context| context.* = .{ .transport = self, .stream = .none };
        self.pending = try gpa.alloc(u8, @as(usize, options.max_streams) * record_capacity);

        if (options.carrier == .memory) {
            const link_count = @as(usize, options.max_streams) +
                @as(usize, options.max_listeners) * options.memory.backlog;
            const pipe_bytes = @as(usize, options.memory.capacity);
            self.links = try gpa.alloc(Link, link_count);
            self.link_storage = try gpa.alloc(u8, link_count * 2 * pipe_bytes);
            for (self.links, 0..) |*link, index| {
                const base = index * 2 * pipe_bytes;
                link.* = .{ .pipes = .{
                    .{ .bytes = self.link_storage[base..][0..pipe_bytes] },
                    .{ .bytes = self.link_storage[base + pipe_bytes ..][0..pipe_bytes] },
                } };
            }
        }

        switch (c.foundry_tls_runtime_acquire(options.tls_allocation_limit)) {
            c.FOUNDRY_TLS_CREDENTIALS_OK => {},
            c.FOUNDRY_TLS_CREDENTIALS_MEMORY => return error.OutOfMemory,
            c.FOUNDRY_TLS_CREDENTIALS_ENTROPY => return error.EntropyUnavailable,
            else => return error.ProviderUnavailable,
        }
        errdefer c.foundry_tls_runtime_release();

        if (options.carrier == .system) {
            if (c.foundry_socket_startup() != c.FOUNDRY_SOCKET_OK) return error.NetworkUnavailable;
            self.sockets_started = true;
        }
        return self;
    }

    /// Closes every stream and listener and destroys every credential. Local and bounded:
    /// one close_notify attempt per established stream, and no waiting for a peer.
    pub fn deinit(self: *Transport) void {
        var streams = self.streams.iterator();
        while (streams.next()) |entry| self.releaseStream(entry.value);
        var listeners = self.listeners.iterator();
        while (listeners.next()) |entry| self.releaseListener(entry.value);
        var credentials = self.credentials.iterator();
        while (credentials.next()) |entry| c.foundry_tls_credentials_destroy(entry.value.native);

        if (self.sockets_started) c.foundry_socket_cleanup();
        c.foundry_tls_runtime_release();
        const gpa = self.gpa;
        self.freeStorage();
        gpa.destroy(self);
    }

    fn freeStorage(self: *Transport) void {
        const gpa = self.gpa;
        self.listeners.deinit(gpa);
        self.streams.deinit(gpa);
        self.credentials.deinit(gpa);
        gpa.free(self.carriers);
        gpa.free(self.pending);
        gpa.free(self.links);
        gpa.free(self.link_storage);
    }

    pub fn stats(self: *const Transport) Stats {
        return .{
            .listeners = self.listeners.count(),
            .streams = self.streams.count(),
            .credentials = self.credentials.count(),
            .tls_allocated = c.foundry_tls_allocated_bytes(),
            .tls_allocation_peak = c.foundry_tls_allocation_peak(),
            .shed = self.shed,
        };
    }

    // -- credentials ----------------------------------------------------------------

    pub fn createCredentials(self: *Transport, config: CredentialConfig) CredentialError!CredentialsHandle {
        if (self.credentials.count() >= self.options.max_credentials) return error.LimitReached;
        const server_key: ?*const [32]u8 = if (config.server_key) |*key| &key.sha256 else null;
        const source: c.foundry_tls_credential_source = .{
            .role = switch (config.role) {
                .server => c.FOUNDRY_TLS_ROLE_SERVER,
                .client => c.FOUNDRY_TLS_ROLE_CLIENT,
            },
            .trust = config.trust_roots.ptr,
            .trust_length = config.trust_roots.len,
            .certificate = config.certificate_chain.ptr,
            .certificate_length = config.certificate_chain.len,
            .private_key = config.private_key.ptr,
            .private_key_length = config.private_key.len,
            .server_name = config.server_name.ptr,
            .server_name_length = config.server_name.len,
            .server_key = if (server_key) |key| key else null,
        };
        var native: ?*c.foundry_tls_credentials = null;
        switch (c.foundry_tls_credentials_create(&source, &native)) {
            c.FOUNDRY_TLS_CREDENTIALS_OK => {},
            c.FOUNDRY_TLS_CREDENTIALS_INVALID_ARGUMENT => return error.InvalidServerIdentity,
            c.FOUNDRY_TLS_CREDENTIALS_INVALID_TRUST => return error.InvalidTrustRoots,
            c.FOUNDRY_TLS_CREDENTIALS_INVALID_CERTIFICATE => return error.InvalidCertificate,
            c.FOUNDRY_TLS_CREDENTIALS_INVALID_KEY => return error.InvalidPrivateKey,
            c.FOUNDRY_TLS_CREDENTIALS_KEY_MISMATCH => return error.KeyMismatch,
            c.FOUNDRY_TLS_CREDENTIALS_UNSUPPORTED_KEY => return error.UnsupportedKey,
            c.FOUNDRY_TLS_CREDENTIALS_WRONG_USAGE => return error.WrongUsage,
            c.FOUNDRY_TLS_CREDENTIALS_MEMORY => return error.OutOfMemory,
            c.FOUNDRY_TLS_CREDENTIALS_ENTROPY => return error.EntropyUnavailable,
            else => return error.ProviderUnavailable,
        }
        // Capacity was reserved at `init`, so this cannot allocate.
        return self.credentials.add(self.gpa, .{ .native = native.?, .role = config.role }) catch unreachable;
    }

    /// The role credentials were created for, or null for a stale handle.
    pub fn credentialsRole(self: *Transport, handle: CredentialsHandle) ?Role {
        const slot = self.credentials.get(handle) orelse return null;
        return slot.role;
    }

    /// Refused while a listener or stream still uses them: close those first.
    pub fn destroyCredentials(self: *Transport, handle: CredentialsHandle) error{ InvalidHandle, CredentialsInUse }!void {
        const slot = self.credentials.get(handle) orelse return error.InvalidHandle;
        if (slot.users != 0) return error.CredentialsInUse;
        c.foundry_tls_credentials_destroy(slot.native);
        _ = self.credentials.remove(handle);
    }

    // -- listeners ------------------------------------------------------------------

    pub fn listen(self: *Transport, endpoint: Endpoint, credentials: CredentialsHandle) ListenError!ListenerHandle {
        const creds = self.credentials.get(credentials) orelse return error.InvalidHandle;
        if (creds.role != .server) return error.WrongRole;
        if (self.listeners.count() >= self.options.max_listeners) return error.LimitReached;

        var slot: ListenerSlot = .{ .credentials = credentials, .endpoint = endpoint };
        switch (self.options.carrier) {
            .system => {
                var port: u16 = 0;
                const result = c.foundry_socket_listen(&endpoint.address, endpoint.port, self.options.backlog, &slot.socket, &port);
                if (result != c.FOUNDRY_SOCKET_OK) return listenError(result);
                slot.endpoint.port = port;
            },
            .memory => slot.endpoint.port = try self.claimMemoryPort(endpoint),
        }
        creds.users += 1;
        return self.listeners.add(self.gpa, slot) catch unreachable;
    }

    /// The bound endpoint, with the port the OS chose when 0 was asked for.
    pub fn listenerEndpoint(self: *Transport, listener: ListenerHandle) ?Endpoint {
        const slot = self.listeners.get(listener) orelse return null;
        return slot.endpoint;
    }

    /// Connections accepted from now on authenticate with `credentials`; streams already
    /// accepted keep what they were accepted with. How a server rotates its identity
    /// without giving up its port.
    pub fn setListenerCredentials(self: *Transport, listener: ListenerHandle, credentials: CredentialsHandle) ListenError!void {
        const slot = self.listeners.get(listener) orelse return error.InvalidHandle;
        const creds = self.credentials.get(credentials) orelse return error.InvalidHandle;
        if (creds.role != .server) return error.WrongRole;
        creds.users += 1;
        if (self.credentials.get(slot.credentials)) |old| old.users -= 1;
        slot.credentials = credentials;
    }

    /// Stops listening. Accepted streams are unaffected; memory connections still
    /// waiting to be accepted are reset, as TCP resets them.
    pub fn closeListener(self: *Transport, listener: ListenerHandle) void {
        const slot = self.listeners.get(listener) orelse return;
        self.releaseListener(slot);
        _ = self.listeners.remove(listener);
    }

    /// Takes at most one pending connection. The new stream is handshaking.
    pub fn accept(self: *Transport, listener: ListenerHandle) AcceptError!Accepted {
        const listener_slot = self.listeners.get(listener) orelse return error.InvalidHandle;
        switch (self.options.carrier) {
            .system => {
                var socket: c.foundry_socket = invalid_socket;
                var address: [4]u8 = undefined;
                var port: u16 = 0;
                const result = c.foundry_socket_accept(listener_slot.socket, &socket, &address, &port);
                switch (result) {
                    c.FOUNDRY_SOCKET_OK => {},
                    c.FOUNDRY_SOCKET_WOULD_BLOCK => return .none,
                    c.FOUNDRY_SOCKET_RESOURCES => return error.SystemResources,
                    c.FOUNDRY_SOCKET_NETWORK_DOWN => return error.NetworkUnavailable,
                    else => return error.Unexpected,
                }
                const stream = self.addStream(.{
                    .state = .handshaking,
                    .role = .server,
                    .credentials = listener_slot.credentials,
                    .socket = socket,
                    .remote = .{ .address = address, .port = port },
                }) orelse {
                    c.foundry_socket_close(socket);
                    self.shed += 1;
                    return .shed;
                };
                return .{ .stream = stream };
            },
            .memory => {
                if (listener_slot.backlog_len == 0) return .none;
                const link = listener_slot.backlog[0];
                for (1..listener_slot.backlog_len) |index| {
                    listener_slot.backlog[index - 1] = listener_slot.backlog[index];
                }
                listener_slot.backlog_len -= 1;
                const stream = self.addStream(.{
                    .state = .handshaking,
                    .role = .server,
                    .credentials = listener_slot.credentials,
                    .link = link,
                    .side = 1,
                    .remote = .{ .address = .{ 127, 0, 0, 1 }, .port = @intCast(40000 + (link % 20000)) },
                }) orelse {
                    self.links[link].reset = true;
                    self.closeLinkSide(link, 1);
                    self.shed += 1;
                    return .shed;
                };
                return .{ .stream = stream };
            },
        }
    }

    // -- streams --------------------------------------------------------------------

    /// Starts connecting. The stream is `connecting`, or already `failed` when the OS
    /// refused at once; either way `advance` reports what happens next.
    pub fn connect(self: *Transport, endpoint: Endpoint, credentials: CredentialsHandle) ConnectError!StreamHandle {
        const creds = self.credentials.get(credentials) orelse return error.InvalidHandle;
        if (creds.role != .client) return error.WrongRole;
        if (!endpoint.isConnectable()) return error.InvalidEndpoint;
        if (self.streams.count() >= self.options.max_streams) return error.LimitReached;

        switch (self.options.carrier) {
            .system => {
                var socket: c.foundry_socket = invalid_socket;
                const result = c.foundry_socket_connect(&endpoint.address, endpoint.port, &socket);
                var slot: StreamSlot = .{
                    .state = .connecting,
                    .role = .client,
                    .credentials = credentials,
                    .socket = socket,
                    .remote = endpoint,
                };
                switch (result) {
                    c.FOUNDRY_SOCKET_OK, c.FOUNDRY_SOCKET_IN_PROGRESS => {},
                    c.FOUNDRY_SOCKET_RESOURCES => return error.SystemResources,
                    c.FOUNDRY_SOCKET_NETWORK_DOWN => return error.NetworkUnavailable,
                    else => {
                        slot.state = .failed;
                        slot.failure = socketFailure(result);
                    },
                }
                return self.addStream(slot) orelse {
                    c.foundry_socket_close(socket);
                    return error.TlsMemoryExhausted;
                };
            },
            .memory => {
                var slot: StreamSlot = .{
                    .state = .connecting,
                    .role = .client,
                    .credentials = credentials,
                    .remote = endpoint,
                };
                const listener = self.memoryListenerAt(endpoint);
                const link = if (listener != null) self.claimLink() else null;
                if (listener != null and link != null and listener.?.backlog_len < self.options.memory.backlog) {
                    slot.link = link.?;
                } else {
                    if (link) |unused| self.links[unused].in_use = false;
                    slot.state = .failed;
                    slot.failure = .refused;
                }
                const stream = self.addStream(slot) orelse {
                    if (slot.link != no_link) self.links[slot.link].in_use = false;
                    return error.TlsMemoryExhausted;
                };
                if (slot.link != no_link) {
                    const target = listener.?;
                    target.backlog[target.backlog_len] = slot.link;
                    target.backlog_len += 1;
                }
                return stream;
            },
        }
    }

    /// One bounded step: finish a connect, make one provider handshake call, or retry a
    /// pending write. Returns the resulting state.
    pub fn advance(self: *Transport, stream: StreamHandle) StreamError!State {
        const slot = self.streams.get(stream) orelse return error.InvalidHandle;
        switch (slot.state) {
            .connecting => {
                switch (self.options.carrier) {
                    .system => {
                        const result = c.foundry_socket_connect_result(slot.socket);
                        switch (result) {
                            c.FOUNDRY_SOCKET_OK => {},
                            c.FOUNDRY_SOCKET_IN_PROGRESS => return .connecting,
                            else => {
                                self.fail(slot, socketFailure(result));
                                return .failed;
                            },
                        }
                    },
                    .memory => {},
                }
                slot.state = .handshaking;
                return self.handshakeStep(slot);
            },
            .handshaking => return self.handshakeStep(slot),
            .established => {
                self.flushPending(stream, slot);
                if (slot.state == .established) self.checkValidity(slot);
                return slot.state;
            },
            .closed, .failed => return slot.state,
        }
    }

    pub fn state(self: *Transport, stream: StreamHandle) ?State {
        const slot = self.streams.get(stream) orelse return null;
        return slot.state;
    }

    pub fn failure(self: *Transport, stream: StreamHandle) ?Failure {
        const slot = self.streams.get(stream) orelse return null;
        return slot.failure;
    }

    /// The verified peer, once established.
    pub fn peer(self: *Transport, stream: StreamHandle) StreamError!Peer {
        const slot = self.streams.get(stream) orelse return error.InvalidHandle;
        if (slot.state != .established and slot.state != .closed) return error.NotEstablished;
        return .{ .key = slot.peer_key.?, .remote = slot.remote, .valid_until = slot.valid_until };
    }

    /// The remote address as the network reported it: an abuse signal, never an
    /// identity (`networking.md` §4).
    pub fn remote(self: *Transport, stream: StreamHandle) ?Endpoint {
        const slot = self.streams.get(stream) orelse return null;
        return slot.remote;
    }

    /// At most one record's plaintext.
    pub fn read(self: *Transport, stream: StreamHandle, buffer: []u8) StreamError!Read {
        const slot = self.streams.get(stream) orelse return error.InvalidHandle;
        switch (slot.state) {
            .connecting, .handshaking => return error.NotEstablished,
            .closed => return .closed,
            .failed => return error.StreamFailed,
            .established => {},
        }
        if (buffer.len == 0) return .{ .data = 0 };
        var length: usize = 0;
        const result = c.foundry_tls_session_read(slot.session.?, buffer.ptr, buffer.len, &length);
        switch (result) {
            c.FOUNDRY_TLS_DONE => return .{ .data = length },
            c.FOUNDRY_TLS_WANT_READ, c.FOUNDRY_TLS_WANT_WRITE => return .would_block,
            c.FOUNDRY_TLS_CLOSED => {
                slot.state = .closed;
                return .closed;
            },
            else => {
                self.fail(slot, self.tlsFailure(slot, result));
                return error.StreamFailed;
            },
        }
    }

    /// Hands up to one record of `bytes` to the stream and returns how many it took; 0
    /// means would-block. Bytes taken belong to the stream: if the carrier cannot take
    /// the encrypted record yet, the stream keeps them and retries on `advance` or the
    /// next `write`, and a submitted record is never changed (`networking.md` §4).
    pub fn write(self: *Transport, stream: StreamHandle, bytes: []const u8) StreamError!usize {
        const slot = self.streams.get(stream) orelse return error.InvalidHandle;
        switch (slot.state) {
            .connecting, .handshaking => return error.NotEstablished,
            .closed => return error.StreamClosed,
            .failed => return error.StreamFailed,
            .established => {},
        }
        self.flushPending(stream, slot);
        switch (slot.state) {
            .established => {},
            .failed => return error.StreamFailed,
            else => unreachable,
        }
        if (slot.pending != 0 or bytes.len == 0) return 0;

        const session = slot.session.?;
        const chunk = bytes[0..@min(bytes.len, record_capacity, c.foundry_tls_session_max_write(session))];
        var written: usize = 0;
        const result = c.foundry_tls_session_write(session, chunk.ptr, chunk.len, &written);
        switch (result) {
            c.FOUNDRY_TLS_DONE => return written,
            c.FOUNDRY_TLS_WANT_WRITE, c.FOUNDRY_TLS_WANT_READ => {
                // The provider has already encrypted `chunk`; its contract is to be
                // called again with the same bytes, so the stream keeps them.
                @memcpy(self.pendingBuffer(stream)[0..chunk.len], chunk);
                slot.pending = chunk.len;
                return chunk.len;
            },
            else => {
                self.fail(slot, self.tlsFailure(slot, result));
                return error.StreamFailed;
            },
        }
    }

    /// Plaintext the stream has taken but not yet handed to the carrier.
    pub fn pendingBytes(self: *Transport, stream: StreamHandle) StreamError!usize {
        const slot = self.streams.get(stream) orelse return error.InvalidHandle;
        return slot.pending;
    }

    /// Ends the stream. One close_notify attempt if established, then the connection
    /// closes and the handle goes stale. Never waits for the peer.
    pub fn close(self: *Transport, stream: StreamHandle) void {
        const slot = self.streams.get(stream) orelse return;
        self.releaseStream(slot);
        _ = self.streams.remove(stream);
        self.carriers[stream.index].stream = .none;
    }

    /// Moves a proof's fixed certificate clock. Established streams are judged against
    /// it on their next `advance`, and sessions created afterwards handshake at it; a
    /// handshake already under way keeps the instant it began with. The system clock
    /// cannot be moved, so a real session never reaches this.
    pub fn setFixedClock(self: *Transport, seconds: i64) error{ NotFixed, InvalidClock }!void {
        switch (self.options.civil_clock) {
            .system => return error.NotFixed,
            .fixed => {},
        }
        if (seconds <= 0) return error.InvalidClock;
        self.options.civil_clock = .{ .fixed = seconds };
    }

    // -- memory carrier controls ----------------------------------------------------

    /// While stalled, a memory stream's carrier moves nothing in either direction.
    pub fn memoryStall(self: *Transport, stream: StreamHandle, stalled: bool) MemoryError!void {
        const slot = try self.memorySlot(stream);
        slot.stalled = stalled;
    }

    /// Resets the connection under a memory stream; both ends observe it.
    pub fn memoryReset(self: *Transport, stream: StreamHandle) MemoryError!void {
        const slot = try self.memorySlot(stream);
        self.links[slot.link].reset = true;
    }

    /// Flips one bit of the last byte waiting to be read by `stream`, as an on-path
    /// attacker would.
    pub fn memoryCorruptInbound(self: *Transport, stream: StreamHandle) MemoryError!void {
        const slot = try self.memorySlot(stream);
        const byte = self.links[slot.link].pipes[1 - slot.side].lastByte() orelse return error.NothingInFlight;
        byte.* ^= 0x01;
    }

    /// Copies what `stream` has sent that its peer has not yet read: the bytes on the wire.
    pub fn memoryInFlight(self: *Transport, stream: StreamHandle, out: []u8) MemoryError!usize {
        const slot = try self.memorySlot(stream);
        return self.links[slot.link].pipes[slot.side].peek(out);
    }

    // -- internal: streams ----------------------------------------------------------

    /// Adds a stream with its TLS session, or null when no stream slot or provider memory
    /// is left. A stream born failed gets no session.
    fn addStream(self: *Transport, slot_value: StreamSlot) ?StreamHandle {
        if (self.streams.count() >= self.options.max_streams) return null;
        const creds = self.credentials.get(slot_value.credentials).?;
        const handle = self.streams.add(self.gpa, slot_value) catch unreachable;
        const slot = self.streams.get(handle).?;
        const context = &self.carriers[handle.index];
        context.stream = handle;
        if (slot.state != .failed) {
            const fixed_time: i64 = switch (self.options.civil_clock) {
                .system => 0,
                .fixed => |seconds| seconds,
            };
            var session: ?*c.foundry_tls_session = null;
            if (c.foundry_tls_session_create(creds.native, fixed_time, context, carrierSend, carrierReceive, &session) != c.FOUNDRY_TLS_DONE) {
                context.stream = .none;
                _ = self.streams.remove(handle);
                return null;
            }
            slot.session = session;
        }
        if (slot.link != no_link) self.links[slot.link].open[slot.side] = true;
        creds.users += 1;
        return handle;
    }

    fn releaseStream(self: *Transport, slot: *StreamSlot) void {
        if (slot.session) |session| {
            if (slot.state == .established) c.foundry_tls_session_close_notify(session);
            c.foundry_tls_session_destroy(session);
            slot.session = null;
        }
        if (slot.socket != invalid_socket) {
            c.foundry_socket_close(slot.socket);
            slot.socket = invalid_socket;
        }
        if (slot.link != no_link) {
            self.closeLinkSide(slot.link, slot.side);
            slot.link = no_link;
        }
        if (self.credentials.get(slot.credentials)) |creds| creds.users -= 1;
    }

    fn releaseListener(self: *Transport, slot: *ListenerSlot) void {
        if (slot.socket != invalid_socket) {
            c.foundry_socket_close(slot.socket);
            slot.socket = invalid_socket;
        }
        for (slot.backlog[0..slot.backlog_len]) |link| {
            self.links[link].reset = true;
            self.closeLinkSide(link, 1);
        }
        slot.backlog_len = 0;
        if (self.credentials.get(slot.credentials)) |creds| creds.users -= 1;
    }

    fn handshakeStep(self: *Transport, slot: *StreamSlot) State {
        var progressed: c_int = 0;
        const result = c.foundry_tls_session_handshake(slot.session.?, &progressed);
        if (progressed != 0) slot.handshake_calls +|= 1;
        if (slot.handshake_calls > self.options.handshake_call_limit) {
            self.fail(slot, .handshake_budget);
            return .failed;
        }
        switch (result) {
            c.FOUNDRY_TLS_DONE => {
                var key: KeyFingerprint = undefined;
                var valid_until: i64 = 0;
                if (c.foundry_tls_session_peer_key(slot.session.?, &key.sha256) != 0 or
                    c.foundry_tls_session_valid_until(slot.session.?, &valid_until) != 0)
                {
                    self.fail(slot, .internal);
                    return .failed;
                }
                slot.peer_key = key;
                slot.valid_until = valid_until;
                slot.state = .established;
            },
            c.FOUNDRY_TLS_WANT_READ, c.FOUNDRY_TLS_WANT_WRITE => {},
            else => self.fail(slot, self.tlsFailure(slot, result)),
        }
        return slot.state;
    }

    /// A verified identity does not stay verified: once the civil clock passes the
    /// chain's earliest notAfter the stream fails, and a clock that can no longer be
    /// trusted fails it too rather than letting it run unjudged (`networking.md` §4.1).
    fn checkValidity(self: *Transport, slot: *StreamSlot) void {
        const fixed: i64 = switch (self.options.civil_clock) {
            .system => 0,
            .fixed => |seconds| seconds,
        };
        var now: i64 = 0;
        if (c.foundry_tls_civil_time(fixed, &now) == 0) {
            self.fail(slot, .clock_unavailable);
        } else if (now > slot.valid_until) {
            self.fail(slot, .certificate_expired);
        }
    }

    fn flushPending(self: *Transport, stream: StreamHandle, slot: *StreamSlot) void {
        if (slot.pending == 0 or slot.state != .established) return;
        var written: usize = 0;
        const result = c.foundry_tls_session_write(slot.session.?, self.pendingBuffer(stream).ptr, slot.pending, &written);
        switch (result) {
            c.FOUNDRY_TLS_DONE => slot.pending = 0,
            c.FOUNDRY_TLS_WANT_WRITE, c.FOUNDRY_TLS_WANT_READ => {},
            else => self.fail(slot, self.tlsFailure(slot, result)),
        }
    }

    fn pendingBuffer(self: *Transport, stream: StreamHandle) []u8 {
        return self.pending[@as(usize, stream.index) * record_capacity ..][0..record_capacity];
    }

    fn fail(self: *Transport, slot: *StreamSlot, reason: Failure) void {
        _ = self;
        slot.state = .failed;
        if (slot.failure == null) slot.failure = reason;
        slot.pending = 0;
    }

    fn tlsFailure(self: *Transport, slot: *StreamSlot, result: c_int) Failure {
        _ = self;
        return switch (result) {
            c.FOUNDRY_TLS_FAILED_CERTIFICATE => certificateFailure(c.foundry_tls_session_certificate_problem(slot.session.?)),
            c.FOUNDRY_TLS_FAILED_SERVER_KEY => .server_key_mismatch,
            c.FOUNDRY_TLS_FAILED_CHAIN_LENGTH => .certificate_chain_too_long,
            c.FOUNDRY_TLS_FAILED_PEER_ALERT => .peer_refused,
            c.FOUNDRY_TLS_FAILED_PROTOCOL => .protocol,
            c.FOUNDRY_TLS_FAILED_CARRIER_EOF => if (slot.state == .established) .truncated else .closed_early,
            c.FOUNDRY_TLS_FAILED_CARRIER_RESET => .reset,
            c.FOUNDRY_TLS_FAILED_CARRIER => slot.carrier_failure orelse .carrier,
            c.FOUNDRY_TLS_FAILED_MEMORY => .tls_memory,
            c.FOUNDRY_TLS_FAILED_CLOCK => .clock_unavailable,
            else => .internal,
        };
    }

    // -- internal: carriers ---------------------------------------------------------

    fn carrierSend(context: ?*anyopaque, bytes: [*c]const u8, length: usize) callconv(.c) c_int {
        const carrier: *CarrierContext = @ptrCast(@alignCast(context.?));
        const self = carrier.transport;
        const slot = self.streams.get(carrier.stream) orelse return c.FOUNDRY_TLS_IO_FAILED;
        switch (self.options.carrier) {
            .system => {
                const sent = c.foundry_socket_send(slot.socket, bytes, length);
                if (sent > 0) return @intCast(sent);
                if (sent == 0 or sent == c.FOUNDRY_SOCKET_WOULD_BLOCK) return c.FOUNDRY_TLS_IO_WOULD_BLOCK;
                return self.carrierFailed(slot, @intCast(sent));
            },
            .memory => {
                if (slot.stalled) return c.FOUNDRY_TLS_IO_WOULD_BLOCK;
                const link = &self.links[slot.link];
                if (link.reset or !link.open[1 - slot.side]) {
                    slot.carrier_failure = .reset;
                    return c.FOUNDRY_TLS_IO_RESET;
                }
                const limit = @min(length, self.options.memory.max_transfer);
                const moved = link.pipes[slot.side].write(bytes[0..limit]);
                return if (moved == 0) c.FOUNDRY_TLS_IO_WOULD_BLOCK else @intCast(moved);
            },
        }
    }

    fn carrierReceive(context: ?*anyopaque, bytes: [*c]u8, capacity: usize) callconv(.c) c_int {
        const carrier: *CarrierContext = @ptrCast(@alignCast(context.?));
        const self = carrier.transport;
        const slot = self.streams.get(carrier.stream) orelse return c.FOUNDRY_TLS_IO_FAILED;
        switch (self.options.carrier) {
            .system => {
                const received = c.foundry_socket_receive(slot.socket, bytes, capacity);
                if (received > 0) return @intCast(received);
                if (received == 0) return c.FOUNDRY_TLS_IO_EOF;
                if (received == c.FOUNDRY_SOCKET_WOULD_BLOCK) return c.FOUNDRY_TLS_IO_WOULD_BLOCK;
                return self.carrierFailed(slot, @intCast(received));
            },
            .memory => {
                if (slot.stalled) return c.FOUNDRY_TLS_IO_WOULD_BLOCK;
                const link = &self.links[slot.link];
                if (link.reset) {
                    slot.carrier_failure = .reset;
                    return c.FOUNDRY_TLS_IO_RESET;
                }
                const inbound = &link.pipes[1 - slot.side];
                if (inbound.len != 0) {
                    const limit = @min(capacity, self.options.memory.max_transfer);
                    return @intCast(inbound.read(bytes[0..limit]));
                }
                if (!link.open[1 - slot.side]) return c.FOUNDRY_TLS_IO_EOF;
                return c.FOUNDRY_TLS_IO_WOULD_BLOCK;
            },
        }
    }

    fn carrierFailed(self: *Transport, slot: *StreamSlot, code: c_int) c_int {
        _ = self;
        const reason = socketFailure(code);
        slot.carrier_failure = reason;
        return if (reason == .reset) c.FOUNDRY_TLS_IO_RESET else c.FOUNDRY_TLS_IO_FAILED;
    }

    // -- internal: the memory network -----------------------------------------------

    fn memorySlot(self: *Transport, stream: StreamHandle) MemoryError!*StreamSlot {
        if (self.options.carrier != .memory) return error.NotMemory;
        const slot = self.streams.get(stream) orelse return error.InvalidHandle;
        if (slot.link == no_link) return error.NotMemory;
        return slot;
    }

    fn claimMemoryPort(self: *Transport, endpoint: Endpoint) ListenError!u16 {
        if (endpoint.port != 0) {
            if (self.memoryListenerAt(endpoint) != null) return error.AddressInUse;
            return endpoint.port;
        }
        var attempts: u32 = 0;
        while (attempts < 16384) : (attempts += 1) {
            const port = self.next_memory_port;
            self.next_memory_port = if (port == std.math.maxInt(u16)) 49152 else port + 1;
            if (self.memoryListenerAt(.{ .address = endpoint.address, .port = port }) == null) return port;
        }
        return error.AddressUnavailable;
    }

    fn memoryListenerAt(self: *Transport, endpoint: Endpoint) ?*ListenerSlot {
        var listeners = self.listeners.iterator();
        while (listeners.next()) |entry| {
            const bound = entry.value.endpoint;
            if (bound.port != endpoint.port) continue;
            if (bound.isUnspecified() or endpoint.isUnspecified() or std.mem.eql(u8, &bound.address, &endpoint.address)) {
                return entry.value;
            }
        }
        return null;
    }

    fn claimLink(self: *Transport) ?u32 {
        for (self.links, 0..) |*link, index| {
            if (link.in_use) continue;
            link.in_use = true;
            link.open = .{ false, true }; // the accepting side exists until a listener says otherwise
            link.reset = false;
            for (&link.pipes) |*pipe| {
                pipe.start = 0;
                pipe.len = 0;
            }
            return @intCast(index);
        }
        return null;
    }

    fn closeLinkSide(self: *Transport, index: u32, side: u1) void {
        const link = &self.links[index];
        link.open[side] = false;
        if (!link.open[0] and !link.open[1]) link.in_use = false;
    }
};

fn validateOptions(options: Options) InitError!void {
    if (options.max_listeners == 0 or options.max_streams == 0 or options.max_credentials == 0) return error.InvalidOptions;
    if (options.max_streams > 1024 or options.backlog == 0 or options.backlog > 1024) return error.InvalidOptions;
    if (options.tls_allocation_limit == 0 or options.handshake_call_limit == 0) return error.InvalidOptions;
    switch (options.civil_clock) {
        .system => {},
        .fixed => |seconds| if (seconds <= 0) return error.InvalidOptions,
    }
    if (options.carrier == .memory) {
        const memory = options.memory;
        if (memory.capacity == 0 or memory.max_transfer == 0) return error.InvalidOptions;
        if (memory.backlog == 0 or memory.backlog > max_memory_backlog) return error.InvalidOptions;
    }
}

fn listenError(code: c_int) ListenError {
    return switch (code) {
        c.FOUNDRY_SOCKET_ADDRESS_IN_USE => error.AddressInUse,
        c.FOUNDRY_SOCKET_ADDRESS_UNAVAILABLE => error.AddressUnavailable,
        c.FOUNDRY_SOCKET_PERMISSION => error.PermissionDenied,
        c.FOUNDRY_SOCKET_NETWORK_DOWN => error.NetworkUnavailable,
        c.FOUNDRY_SOCKET_RESOURCES => error.SystemResources,
        else => error.Unexpected,
    };
}

fn socketFailure(code: c_int) Failure {
    return switch (code) {
        c.FOUNDRY_SOCKET_REFUSED => .refused,
        c.FOUNDRY_SOCKET_UNREACHABLE, c.FOUNDRY_SOCKET_ADDRESS_UNAVAILABLE => .unreachable_address,
        c.FOUNDRY_SOCKET_TIMED_OUT => .timed_out,
        c.FOUNDRY_SOCKET_RESET => .reset,
        c.FOUNDRY_SOCKET_NETWORK_DOWN => .network_down,
        else => .carrier,
    };
}

fn certificateFailure(problem: c_int) Failure {
    return switch (problem) {
        c.FOUNDRY_TLS_CERTIFICATE_MISSING => .certificate_missing,
        c.FOUNDRY_TLS_CERTIFICATE_UNTRUSTED => .certificate_untrusted,
        c.FOUNDRY_TLS_CERTIFICATE_EXPIRED => .certificate_expired,
        c.FOUNDRY_TLS_CERTIFICATE_NOT_YET_VALID => .certificate_not_yet_valid,
        c.FOUNDRY_TLS_CERTIFICATE_WRONG_USAGE => .certificate_wrong_usage,
        c.FOUNDRY_TLS_CERTIFICATE_WRONG_NAME => .certificate_wrong_name,
        else => .certificate_rejected,
    };
}

// -- tests ----------------------------------------------------------------------------
//
// What needs no identity is tested here. Handshakes, loopback sockets and the failure
// matrix need disposable certificates, and those are generated only in
// `engine/tests/transport_streams.zig`, so no issuing code enters this module.

const testing = std.testing;

test "an endpoint is four decimal octets and a port, and nothing else" {
    const parsed = try Endpoint.parse("203.0.113.7:40404");
    try testing.expectEqualSlices(u8, &.{ 203, 0, 113, 7 }, &parsed.address);
    try testing.expectEqual(@as(u16, 40404), parsed.port);
    try testing.expect(parsed.eql(.{ .address = .{ 203, 0, 113, 7 }, .port = 40404 }));
    try testing.expectEqual(@as(u16, 0), (try Endpoint.parse("0.0.0.0:0")).port);
    try testing.expectEqual(@as(u16, 65535), (try Endpoint.parse("127.0.0.1:65535")).port);

    var text: [32]u8 = undefined;
    try testing.expectEqualStrings("127.0.0.1:9", try std.fmt.bufPrint(&text, "{f}", .{Endpoint.loopback(9)}));

    for ([_][]const u8{
        "",              "127.0.0.1",      ":80",           "127.0.0.1:",
        "127.0.0:80",    "127.0.0.1.1:80", "256.0.0.1:80",  "127.0.0.1:65536",
        "127.0.0.01:80", "127.0.0.1:080",  "127.0.0.1:+80", "127.0.0.1:-1",
        " 127.0.0.1:80", "127.0.0.1:80 ",  "localhost:80",  "[::1]:80",
        "127..0.1:80",   "1.2.3.4:5:6",    "0x7f.0.0.1:80", "127.0.0.1:123456",
    }) |bad| {
        try testing.expectError(error.InvalidEndpoint, Endpoint.parse(bad));
    }
}

test "only a real port on a unicast address can be connected to" {
    try testing.expect(Endpoint.loopback(1).isConnectable());
    try testing.expect((try Endpoint.parse("198.51.100.20:443")).isConnectable());
    for ([_][]const u8{ "127.0.0.1:0", "0.0.0.0:80", "224.0.0.1:80", "239.1.2.3:80", "255.255.255.255:80", "240.0.0.1:80" }) |text| {
        try testing.expect(!(try Endpoint.parse(text)).isConnectable());
    }
}

test "a memory pipe wraps, drains in order and never takes more than it holds" {
    var storage: [8]u8 = undefined;
    var pipe: Pipe = .{ .bytes = &storage };
    try testing.expectEqual(@as(usize, 5), pipe.write("abcde"));
    var out: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), pipe.read(out[0..3]));
    try testing.expectEqualStrings("abc", out[0..3]);
    // Wraps: 2 held at offset 3, 6 free, 5 written across the end.
    try testing.expectEqual(@as(usize, 5), pipe.write("fghij"));
    try testing.expectEqual(@as(usize, 1), pipe.write("klm"));
    try testing.expectEqual(@as(usize, 0), pipe.write("n"));
    try testing.expectEqual(@as(u8, 'k'), pipe.lastByte().?.*);
    try testing.expectEqual(@as(usize, 8), pipe.peek(&out));
    try testing.expectEqualStrings("defghijk", &out);
    try testing.expectEqual(@as(usize, 8), pipe.read(&out));
    try testing.expectEqualStrings("defghijk", &out);
    try testing.expectEqual(@as(usize, 0), pipe.read(&out));
    try testing.expectEqual(@as(?*u8, null), pipe.lastByte());
}

test "options are checked before anything is allocated or opened" {
    const bad = [_]Options{
        .{ .max_listeners = 0 },
        .{ .max_streams = 0 },
        .{ .max_streams = 1025 },
        .{ .max_credentials = 0 },
        .{ .backlog = 0 },
        .{ .tls_allocation_limit = 0 },
        .{ .handshake_call_limit = 0 },
        .{ .civil_clock = .{ .fixed = 0 } },
        .{ .carrier = .memory, .memory = .{ .capacity = 0 } },
        .{ .carrier = .memory, .memory = .{ .max_transfer = 0 } },
        .{ .carrier = .memory, .memory = .{ .backlog = 0 } },
        .{ .carrier = .memory, .memory = .{ .backlog = max_memory_backlog + 1 } },
    };
    for (bad) |options| {
        try testing.expectError(error.InvalidOptions, Transport.init(testing.allocator, options));
    }
}

test "an empty transport starts, refuses what it does not hold, and stops" {
    inline for (.{ Carrier.system, Carrier.memory }) |carrier| {
        const transport = try Transport.init(testing.allocator, .{ .carrier = carrier });
        defer transport.deinit();

        const stats = transport.stats();
        try testing.expectEqual(@as(u32, 0), stats.streams + stats.listeners + stats.credentials);

        const stale_stream: StreamHandle = .{ .index = 0, .generation = 7 };
        try testing.expectError(error.InvalidHandle, transport.advance(stale_stream));
        try testing.expectError(error.InvalidHandle, transport.read(stale_stream, &.{}));
        try testing.expectError(error.InvalidHandle, transport.write(stale_stream, "x"));
        try testing.expectError(error.InvalidHandle, transport.peer(stale_stream));
        try testing.expectEqual(@as(?State, null), transport.state(stale_stream));
        transport.close(stale_stream);

        const no_credentials: CredentialsHandle = .none;
        try testing.expectError(error.InvalidHandle, transport.connect(Endpoint.loopback(1), no_credentials));
        try testing.expectError(error.InvalidHandle, transport.listen(Endpoint.loopback(0), no_credentials));
        try testing.expectError(error.InvalidHandle, transport.destroyCredentials(no_credentials));
        try testing.expectError(error.InvalidHandle, transport.accept(.none));
        transport.closeListener(.none);
    }
}

test "credentials that cannot be parsed are refused with a reason, and hold nothing" {
    const transport = try Transport.init(testing.allocator, .{ .carrier = .memory });
    defer transport.deinit();
    const before = transport.stats().tls_allocated;

    try testing.expectError(error.InvalidTrustRoots, transport.createCredentials(.{
        .role = .server,
        .trust_roots = "not a certificate",
        .certificate_chain = "",
        .private_key = "",
    }));
    try testing.expectError(error.InvalidTrustRoots, transport.createCredentials(.{
        .role = .server,
        .trust_roots = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n",
        .certificate_chain = "",
        .private_key = "",
    }));
    // A client must name the server and pin its key; a server must do neither.
    try testing.expectError(error.InvalidServerIdentity, transport.createCredentials(.{
        .role = .client,
        .trust_roots = "x",
        .certificate_chain = "x",
        .private_key = "x",
        .server_name = "server.test",
    }));
    try testing.expectError(error.InvalidServerIdentity, transport.createCredentials(.{
        .role = .client,
        .trust_roots = "x",
        .certificate_chain = "x",
        .private_key = "x",
        .server_name = "bad name",
        .server_key = .{ .sha256 = @splat(0) },
    }));
    try testing.expectError(error.InvalidServerIdentity, transport.createCredentials(.{
        .role = .server,
        .trust_roots = "x",
        .certificate_chain = "x",
        .private_key = "x",
        .server_name = "server.test",
    }));
    try testing.expectEqual(@as(u32, 0), transport.stats().credentials);
    try testing.expectEqual(before, transport.stats().tls_allocated);
}
