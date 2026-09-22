//! Sessions, the peers in them, and everything a connection passes through before it
//! is one (`networking.md` §3–§6, M16 Step 3).
//!
//! A `Service` runs over a `platform.Transport` it does not own. The host builds it
//! from **grants** — a role, an endpoint and credentials the host already constructed
//! — an **allowlist** mapping client keys to host-local principals, and a frozen
//! **compatibility description**. Sessions are created by grant, so nothing reaching
//! a service can name an address, a file or a key of its own choosing (§8).
//!
//! ## What a connection passes through
//!
//! A server accepts, charges the handshake-start limiter, and authenticates in a
//! pending pool of its own, separate from its admitted peers. TLS verifies the peer;
//! the allowlist then decides whether that key is a principal this host admits, and a
//! principal already connected is refused rather than allowed to displace itself. Only
//! then does FNET input reach negotiation: the client sends its hello, every
//! compatibility entry, every channel and the digests of both; the server compares
//! each against its own and either refuses — naming the category and the first entry
//! that differs — or assigns a participant number and answers. The client checks that
//! answer against its own description before it believes it. Both sides are then
//! **synchronizing**: admitted, heartbeating, and waiting for the initial state Step 4
//! delivers.
//!
//! ## Bounds
//!
//! Everything is sized at `init` from `limits` and nothing is allocated after it. Each
//! pump gives every connection at most its per-peer budget — one TLS handshake call,
//! 64 KiB and 32 frames in, 64 KiB out — starting from a rotating position, so no peer
//! is always first. Every non-active state has a deadline: admission (accept or
//! connect to admitted), initial synchronization, no progress (no complete frame for
//! the timeout, however slowly bytes drip) and write stall (queued output the peer will
//! not take). Heartbeats keep an idle peer alive and never extend either of the last
//! two. Events are reserved when a connection could produce them, so the queue never
//! overflows and nothing is dropped: a host that stops draining it stops admitting.
//!
//! ## What this does not do
//!
//! No command, state, baseline or activation — Step 4. No ECS, no world, no package
//! fetching, no public ABI, and no logging: every outcome is a counter or an event.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const channel = @import("channel.zig");
const compatibility = @import("compatibility.zig");
const limiter_mod = @import("limiter.zig");
const limits_mod = @import("limits.zig");
const wire = @import("wire.zig");

const transport = platform.transport;
const Transport = transport.Transport;
const Allocator = std.mem.Allocator;
const Limits = limits_mod.Limits;

pub const Session = opaque {};
pub const Peer = opaque {};
pub const SessionHandle = core.Handle(Session);
pub const PeerHandle = core.Handle(Peer);

pub const Role = transport.Role;

/// Grants a service can hold. Structural, not a tuning limit: a host has a handful.
pub const max_grants = 16;

/// Plaintext staged from one TLS read: one record.
const staging_bytes: usize = 16 * 1024;

// -- configuration --------------------------------------------------------------------

/// What a host allows one session to be: a role, where, and as whom. The credentials
/// were created on the service's transport by the host; the service never sees a key.
pub const Grant = struct {
    /// How the grant is named, by the host and eventually through the public API.
    id: core.ContentId,
    role: Role,
    /// Where a server listens, or the server a client connects to.
    endpoint: transport.Endpoint,
    credentials: transport.CredentialsHandle,
};

/// A client key a server admits, and the host-local principal it stands for. Several
/// keys may stand for one principal; one principal has at most one live connection.
pub const Identity = struct {
    key: transport.KeyFingerprint,
    principal: u32,
};

pub const Config = struct {
    limits: Limits = .{},
    compatibility: compatibility.Description,
    grants: []const Grant = &.{},
    identities: []const Identity = &.{},
    /// The first server session's epoch; each later server session takes the next.
    /// The host makes it unique across restarts — from its clock, say — so a client
    /// reconnecting to a restarted server sees a new epoch.
    first_epoch: u64 = 1,
};

pub const InitError = error{
    OutOfMemory,
    InvalidGrant,
    DuplicateGrant,
    TooManyGrants,
    InvalidIdentity,
    DuplicateIdentity,
    TooManyIdentities,
    InvalidEpoch,
    /// The transport would admit more work, or hold fewer streams, than these limits.
    TransportMismatch,
    /// A limit is stricter than the transport can enforce.
    LimitUnenforceable,
    /// A queue cannot hold what the protocol must put in it.
    QueueTooSmall,
} || compatibility.Error;

/// Transport bounds that match `limits`: enough streams and listeners for its sessions
/// and no looser a handshake or allocation budget. The host adds its clock, carrier
/// details and credential count.
pub fn transportOptions(limits: Limits, carrier: transport.Carrier) transport.Options {
    const streams = @as(u32, limits.sessions) * (@as(u32, limits.peers_per_session) + limits.pending_handshakes);
    return .{
        .carrier = carrier,
        .max_listeners = @intCast(@min(limits.sessions, std.math.maxInt(u8))),
        .max_streams = @intCast(@min(streams, 1024)),
        .tls_allocation_limit = limits.tls_allocation_bytes,
        .handshake_call_limit = limits.tls_handshake_call_limit,
    };
}

// -- observable state -----------------------------------------------------------------

pub const SessionState = enum {
    /// Channels may still be registered.
    configuring,
    /// Channels are frozen; a server is listening, a client may connect.
    running,
};

pub const PeerState = enum {
    /// A client's TCP connect has not finished.
    connecting,
    /// TLS is verifying both sides. A server's connection here is not yet a peer.
    authenticating,
    /// Authenticated and authorized; comparing compatibility.
    negotiating,
    /// Admitted with a participant number, awaiting initial state.
    synchronizing,
    /// Ended; delivering a last refusal or disconnect before the connection closes.
    closing,
};

pub const Deadline = enum { admission, initial_sync, no_progress, write_stall };

pub const Fault = enum {
    /// A frame or payload the codec refused.
    malformed,
    /// A frame this role, state or negotiation stage does not accept.
    unexpected,
    /// A sequence other than exactly the previous one plus one.
    sequence,
    /// The stream ended inside a frame.
    truncated,
    /// A well-formed claim that contradicts what this side knows: a server's hello or
    /// digests that differ from the description it admitted, a heartbeat for another
    /// epoch or acknowledging a frame never sent.
    mismatch,
};

/// Why a connection ended. A category, never a payload or a certificate's content.
pub const Ending = union(enum) {
    /// This side's host ended it.
    local: wire.DisconnectReason,
    /// The peer said why it was leaving.
    peer_disconnected: wire.DisconnectReason,
    /// The peer ended the stream without saying why.
    peer_closed,
    /// This side refused the peer during negotiation. The refusing side's reason is the
    /// authoritative one (Step 2 Resolution).
    refused: wire.Refusal,
    /// The peer refused this side.
    refused_by_peer: wire.Refusal,
    /// The peer's identity was withdrawn from the allowlist or mapped to another
    /// principal.
    revoked,
    /// This side's credentials were replaced; everything they authenticated ends.
    rotated,
    timed_out: Deadline,
    protocol: Fault,
    /// The authenticated stream failed, including a peer certificate that expired.
    transport: transport.Failure,
    /// The peer let a queue this side must fill run out.
    overloaded,
};

pub const Admission = struct {
    participant: u32,
    epoch: u64,
    /// The allowlisted principal on a server; 0 on a client.
    principal: u32,
};

pub const Departure = struct {
    /// 0 if it was never admitted.
    participant: u32,
    principal: u32,
    ending: Ending,
};

pub const Event = struct {
    session: SessionHandle,
    peer: PeerHandle,
    kind: union(enum) {
        admitted: Admission,
        /// The handle is stale, or becomes so once a last notice has been delivered.
        ended: Departure,
    },
};

/// A grant as a consumer may see it: never its credentials.
pub const GrantInfo = struct {
    id: core.ContentId,
    role: Role,
    endpoint: transport.Endpoint,
};

pub const PeerInfo = struct {
    session: SessionHandle,
    state: PeerState,
    principal: u32,
    participant: u32,
    epoch: u64,
    /// An abuse signal, never an identity.
    remote: transport.Endpoint,
};

pub const SessionInfo = struct {
    grant: core.ContentId,
    role: Role,
    state: SessionState,
    epoch: u64,
    channels: u16,
    pending: u16,
    peers: u16,
    listening: ?transport.Endpoint,
};

pub const Shed = struct {
    /// The transport had no stream or provider memory for it.
    transport: u64 = 0,
    /// The pending-handshake pool was full.
    pending_full: u64 = 0,
    source_rate: u64 = 0,
    global_rate: u64 = 0,
};

pub const Stats = struct {
    sessions: u32 = 0,
    peers: u32 = 0,
    pending: u32 = 0,
    queued_events: u32 = 0,
    reserved_events: u32 = 0,
    accepted: u64 = 0,
    accept_errors: u64 = 0,
    shed: Shed = .{},
    /// Server handshakes that failed before a peer existed, by the transport's category.
    handshake_failures: std.EnumArray(transport.Failure, u32) = .initFill(0),
    pending_timeouts: u64 = 0,
    /// Verified keys the allowlist does not hold.
    denied: u64 = 0,
    /// Principals refused because they already had a live connection.
    duplicates: u64 = 0,
    /// Allowlisted principals refused for want of a peer slot or event room.
    capacity_refusals: u64 = 0,
    /// Negotiations refused for a compatibility difference.
    refused: u64 = 0,
    admitted: u64 = 0,
    frames_received: u64 = 0,
    frames_sent: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    peak_frames_in_per_pump: u32 = 0,
    peak_bytes_in_per_pump: u32 = 0,
    peak_bytes_out_per_pump: u32 = 0,
    peak_send_queue: u32 = 0,
    peak_events: u32 = 0,
};

// -- errors ---------------------------------------------------------------------------

pub const SessionError = error{ UnknownGrant, GrantInUse, LimitReached };

pub const ChannelError = error{ InvalidHandle, ChannelsFrozen } || channel.Error;

pub const ListenError = error{
    InvalidHandle,
    WrongRole,
    AlreadyRunning,
    NoChannels,
    EpochExhausted,
    InvalidGrant,
    LimitReached,
    AddressInUse,
    AddressUnavailable,
    PermissionDenied,
    NetworkUnavailable,
    SystemResources,
    Unexpected,
};

pub const ConnectError = error{
    InvalidHandle,
    WrongRole,
    AlreadyConnected,
    NoChannels,
    LimitReached,
    EventQueueFull,
    InvalidGrant,
    TlsMemoryExhausted,
    SystemResources,
    NetworkUnavailable,
};

pub const PolicyError = error{ InvalidIdentity, DuplicateIdentity, TooManyIdentities };

pub const RotateError = error{ UnknownGrant, InvalidCredentials, WrongRole };

// -- internals ------------------------------------------------------------------------

const Pool = enum { pending, admitted };
const Stage = enum { hello, items, channels, finished };

/// What one side says on its way out.
const Notice = union(enum) {
    refusal: wire.Refusal,
    disconnect: wire.DisconnectReason,
};

/// A byte ring over storage the connection's buffer owns. Frames enter whole; the
/// transport takes them in whatever pieces it can.
const Ring = struct {
    start: usize = 0,
    len: usize = 0,

    fn write(self: *Ring, storage: []u8, bytes: []const u8) void {
        std.debug.assert(bytes.len <= storage.len - self.len);
        var copied: usize = 0;
        while (copied < bytes.len) {
            const at = (self.start + self.len) % storage.len;
            const run = @min(bytes.len - copied, storage.len - at);
            @memcpy(storage[at..][0..run], bytes[copied..][0..run]);
            copied += run;
            self.len += run;
        }
    }

    fn head(self: *const Ring, storage: []const u8) []const u8 {
        return storage[self.start..][0..@min(self.len, storage.len - self.start)];
    }

    fn consume(self: *Ring, capacity: usize, count: usize) void {
        self.start = (self.start + count) % capacity;
        self.len -= count;
        if (self.len == 0) self.start = 0;
    }
};

const SessionSlot = struct {
    grant: u32,
    role: Role,
    state: SessionState = .configuring,
    channel_count: u16 = 0,
    channel_digest: [32]u8 = undefined,
    listener: transport.ListenerHandle = .none,
    epoch: u64 = 0,
    next_participant: u32 = 1,
    pending: u16 = 0,
    admitted: u16 = 0,
};

const Connection = struct {
    session: SessionHandle,
    stream: transport.StreamHandle,
    state: PeerState,
    pool: Pool,
    remote: transport.Endpoint,
    /// Stamped by the first pump that sees it; the admission deadline runs from here.
    born: ?u64 = null,
    authenticated: bool = false,
    key: transport.KeyFingerprint = .{ .sha256 = @splat(0) },
    principal: u32 = 0,
    admitted: bool = false,
    participant: u32 = 0,
    epoch: u64 = 0,
    buffer: ?u32 = null,
    stage: Stage = .hello,
    index: u16 = 0,
    sent: u64 = 0,
    received: u64 = 0,
    admitted_at: u64 = 0,
    last_received_at: u64 = 0,
    last_sent_at: u64 = 0,
    stalled_since: ?u64 = null,
    closing_since: u64 = 0,
    ring: Ring = .{},
    decoder: wire.Decoder = undefined,
    staged_start: usize = 0,
    staged_len: usize = 0,
    /// Event slots held for this connection: its admission and its ending.
    reserved: u2 = 0,
};

const SessionPool = core.HandlePool(Session, SessionSlot);
const ConnectionPool = core.HandlePool(Peer, Connection);

const Out = struct {
    failed: ?transport.Failure = null,
    closed: bool = false,
};

pub const Service = struct {
    gpa: Allocator,
    transport: *Transport,
    limits: Limits,
    compatibility: compatibility.Frozen,
    grants: []Grant,
    identities: []Identity,
    candidates: []Identity,
    identity_count: usize = 0,
    sessions: SessionPool = .empty,
    connections: ConnectionPool = .empty,
    order: []PeerHandle,
    channels: []channel.Descriptor,
    slab: []u8,
    free_buffers: []u32,
    free_buffer_count: usize,
    events: []Event,
    event_start: usize = 0,
    event_len: usize = 0,
    event_reserved: usize = 0,
    drain: []u8,
    limiter: limiter_mod.Limiter,
    next_epoch: u64,
    now: u64 = 0,
    rotation: u32 = 0,
    counters: Stats = .{},

    /// Heap-allocated so its address is stable for the host that holds it.
    pub fn init(gpa: Allocator, streams: *Transport, config: Config) InitError!*Service {
        const limits = config.limits;
        try limits.validate();
        if (config.first_epoch == 0) return error.InvalidEpoch;
        if (config.grants.len > max_grants) return error.TooManyGrants;
        if (config.identities.len > limits.identities) return error.TooManyIdentities;
        if (limits.receive_bytes_per_peer < @as(u64, limits.frame_bytes) + staging_bytes) return error.QueueTooSmall;

        var server_grants: u32 = 0;
        var client_grants: u32 = 0;
        for (config.grants, 0..) |grant, index| {
            if (grant.id.isNone()) return error.InvalidGrant;
            for (config.grants[0..index]) |earlier| {
                if (earlier.id.eql(grant.id)) return error.DuplicateGrant;
            }
            const role = streams.credentialsRole(grant.credentials) orelse return error.InvalidGrant;
            if (role != grant.role) return error.InvalidGrant;
            switch (grant.role) {
                .server => server_grants += 1,
                .client => {
                    if (!grant.endpoint.isConnectable()) return error.InvalidGrant;
                    client_grants += 1;
                },
            }
        }
        const server_sessions = @min(limits.sessions, server_grants);
        const client_sessions = @min(limits.sessions, client_grants);
        const connection_count = server_sessions * (@as(u32, limits.peers_per_session) + limits.pending_handshakes) + client_sessions;
        const buffer_count = server_sessions * @as(u32, limits.peers_per_session) + client_sessions;

        const options = streams.options;
        if (options.max_streams < connection_count or options.max_listeners < server_sessions) return error.TransportMismatch;
        if (options.handshake_call_limit > limits.tls_handshake_call_limit or
            options.tls_allocation_limit > limits.tls_allocation_bytes)
        {
            return error.TransportMismatch;
        }
        if (transport.max_chain_certificates > limits.certificate_chain_count or
            transport.max_handshake_message_bytes > limits.certificate_chain_bytes)
        {
            return error.LimitUnenforceable;
        }

        var frozen = try compatibility.freeze(gpa, config.compatibility, limits);
        errdefer frozen.deinit(gpa);
        if (frozen.negotiationBytes(limits.channels) > limits.send_bytes_per_peer) return error.QueueTooSmall;

        const self = try gpa.create(Service);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .transport = streams,
            .limits = limits,
            .compatibility = frozen,
            .grants = &.{},
            .identities = &.{},
            .candidates = &.{},
            .order = &.{},
            .channels = &.{},
            .slab = &.{},
            .free_buffers = &.{},
            .free_buffer_count = 0,
            .events = &.{},
            .drain = &.{},
            .limiter = undefined,
            .next_epoch = config.first_epoch,
        };
        errdefer self.freeStorage();

        self.limiter = try limiter_mod.Limiter.init(gpa, limits);
        errdefer self.limiter.deinit(gpa);
        self.grants = try gpa.dupe(Grant, config.grants);
        self.identities = try gpa.alloc(Identity, limits.identities);
        self.candidates = try gpa.alloc(Identity, limits.identities);
        try self.sessions.ensureUnusedCapacity(gpa, limits.sessions);
        try self.connections.ensureUnusedCapacity(gpa, connection_count);
        self.order = try gpa.alloc(PeerHandle, connection_count);
        self.channels = try gpa.alloc(channel.Descriptor, @as(usize, limits.sessions) * limits.channels);
        self.slab = try gpa.alloc(u8, @as(usize, buffer_count) * self.bufferStride());
        self.free_buffers = try gpa.alloc(u32, buffer_count);
        for (self.free_buffers, 0..) |*slot, index| slot.* = @intCast(buffer_count - 1 - index);
        self.free_buffer_count = buffer_count;
        self.events = try gpa.alloc(Event, limits.queued_events);
        self.drain = try gpa.alloc(u8, staging_bytes);

        try self.replaceAllowlist(config.identities);
        return self;
    }

    /// Closes every session, locally and at once: one disconnect and one close_notify
    /// attempt per peer, never a wait (`networking.md` §4).
    pub fn deinit(self: *Service) void {
        var sessions = self.sessions.iterator();
        while (sessions.next()) |entry| self.closeSession(entry.id);
        self.limiter.deinit(self.gpa);
        self.freeStorage();
        var frozen = self.compatibility;
        frozen.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn freeStorage(self: *Service) void {
        const gpa = self.gpa;
        gpa.free(self.grants);
        gpa.free(self.identities);
        gpa.free(self.candidates);
        self.sessions.deinit(gpa);
        self.connections.deinit(gpa);
        gpa.free(self.order);
        gpa.free(self.channels);
        gpa.free(self.slab);
        gpa.free(self.free_buffers);
        gpa.free(self.events);
        gpa.free(self.drain);
    }

    // -- grants and policy ------------------------------------------------------------

    pub fn grantCount(self: *const Service) usize {
        return self.grants.len;
    }

    /// The grants in the order the host gave them: what a consumer may ask for.
    pub fn grantAt(self: *const Service, index: usize) ?GrantInfo {
        if (index >= self.grants.len) return null;
        const grant = self.grants[index];
        return .{ .id = grant.id, .role = grant.role, .endpoint = grant.endpoint };
    }

    /// Replaces the allowlist whole, or not at all: an invalid replacement is refused
    /// and the last valid one stays in force. Every live peer whose key is no longer
    /// listed, or now names another principal, is ended as `revoked`.
    pub fn replaceAllowlist(self: *Service, entries: []const Identity) PolicyError!void {
        if (entries.len > self.identities.len) return error.TooManyIdentities;
        const candidates = self.candidates[0..entries.len];
        @memcpy(candidates, entries);
        std.mem.sort(Identity, candidates, {}, identityLessThan);
        for (candidates, 0..) |entry, index| {
            if (entry.principal == 0) return error.InvalidIdentity;
            if (index > 0 and candidates[index - 1].key.eql(entry.key)) return error.DuplicateIdentity;
        }
        std.mem.swap([]Identity, &self.identities, &self.candidates);
        self.identity_count = entries.len;
        self.revalidate();
    }

    /// Withdraws one key. Its live peers end as `revoked`. False if it was not listed.
    pub fn revoke(self: *Service, key: transport.KeyFingerprint) bool {
        const listed = self.identities[0..self.identity_count];
        for (listed, 0..) |entry, index| {
            if (!entry.key.eql(key)) continue;
            std.mem.copyForwards(Identity, listed[index .. listed.len - 1], listed[index + 1 ..]);
            self.identity_count -= 1;
            self.revalidate();
            return true;
        }
        return false;
    }

    /// Points a grant at new credentials. Everything its session's old ones
    /// authenticated ends as `rotated`, pending handshakes included, and every later
    /// connection authenticates with the new ones. Refused, changing nothing, for an
    /// unknown grant or credentials of the wrong role.
    pub fn replaceCredentials(self: *Service, grant_id: core.ContentId, credentials: transport.CredentialsHandle) RotateError!void {
        const index = self.grantIndex(grant_id) orelse return error.UnknownGrant;
        const role = self.transport.credentialsRole(credentials) orelse return error.InvalidCredentials;
        if (role != self.grants[index].role) return error.WrongRole;
        if (self.sessionOfGrant(index)) |session_id| {
            const session = self.sessions.get(session_id).?;
            if (!session.listener.isNone()) {
                self.transport.setListenerCredentials(session.listener, credentials) catch return error.InvalidCredentials;
            }
            for (self.collect()) |id| {
                const conn = self.connections.get(id) orelse continue;
                if (!conn.session.eql(session_id)) continue;
                if (conn.pool == .pending) self.finalize(id) else self.end(id, .rotated);
            }
        }
        self.grants[index].credentials = credentials;
    }

    // -- sessions -----------------------------------------------------------------------

    pub fn createSession(self: *Service, grant_id: core.ContentId) SessionError!SessionHandle {
        const index = self.grantIndex(grant_id) orelse return error.UnknownGrant;
        if (self.sessionOfGrant(index) != null) return error.GrantInUse;
        if (self.sessions.count() >= self.limits.sessions) return error.LimitReached;
        return self.sessions.add(self.gpa, .{ .grant = @intCast(index), .role = self.grants[index].role }) catch unreachable;
    }

    /// Registers a channel while the session is configuring. Validated alone and against
    /// the set: unique, bounded, at most one full-state channel.
    pub fn registerChannel(self: *Service, session_id: SessionHandle, descriptor: channel.Descriptor) ChannelError!void {
        const session = self.sessions.get(session_id) orelse return error.InvalidHandle;
        if (session.state != .configuring) return error.ChannelsFrozen;
        const storage = self.sessionChannels(session_id);
        if (session.channel_count >= storage.len) return error.TooManyChannels;
        storage[session.channel_count] = descriptor;
        try channel.validateSet(storage[0 .. session.channel_count + 1], self.limits);
        session.channel_count += 1;
    }

    /// The session's channels: in registration order while configuring, canonical
    /// order once frozen.
    pub fn channelsOf(self: *Service, session_id: SessionHandle) []const channel.Descriptor {
        const session = self.sessions.get(session_id) orelse return &.{};
        return self.sessionChannels(session_id)[0..session.channel_count];
    }

    /// Starts a server session listening at its grant's endpoint, freezing its channels
    /// and taking its epoch.
    pub fn listen(self: *Service, session_id: SessionHandle) ListenError!void {
        const session = self.sessions.get(session_id) orelse return error.InvalidHandle;
        if (session.role != .server) return error.WrongRole;
        if (session.state != .configuring) return error.AlreadyRunning;
        if (session.channel_count == 0) return error.NoChannels;
        const epoch = self.next_epoch;
        const next = std.math.add(u64, epoch, 1) catch return error.EpochExhausted;
        const grant = self.grants[session.grant];
        session.listener = self.transport.listen(grant.endpoint, grant.credentials) catch |err| return switch (err) {
            error.InvalidHandle, error.WrongRole => error.InvalidGrant,
            error.LimitReached => error.LimitReached,
            error.AddressInUse => error.AddressInUse,
            error.AddressUnavailable => error.AddressUnavailable,
            error.PermissionDenied => error.PermissionDenied,
            error.NetworkUnavailable => error.NetworkUnavailable,
            error.SystemResources => error.SystemResources,
            error.Unexpected => error.Unexpected,
        };
        self.next_epoch = next;
        session.epoch = epoch;
        self.freeze(session_id, session);
    }

    /// Starts a client session's connection to its grant's server. A session connects
    /// again once its last connection has ended, as a fresh participant.
    pub fn connect(self: *Service, session_id: SessionHandle) ConnectError!PeerHandle {
        const session = self.sessions.get(session_id) orelse return error.InvalidHandle;
        if (session.role != .client) return error.WrongRole;
        if (session.admitted != 0) return error.AlreadyConnected;
        if (session.channel_count == 0) return error.NoChannels;
        if (self.free_buffer_count == 0) return error.LimitReached;
        if (!self.reserveEvents(2)) return error.EventQueueFull;
        errdefer self.releaseEvents(2);
        const grant = self.grants[session.grant];
        const stream = self.transport.connect(grant.endpoint, grant.credentials) catch |err| return switch (err) {
            error.InvalidHandle, error.WrongRole, error.InvalidEndpoint => error.InvalidGrant,
            error.LimitReached => error.LimitReached,
            error.TlsMemoryExhausted => error.TlsMemoryExhausted,
            error.SystemResources => error.SystemResources,
            error.NetworkUnavailable => error.NetworkUnavailable,
        };
        if (session.state == .configuring) self.freeze(session_id, session);
        const id = self.connections.add(self.gpa, .{
            .session = session_id,
            .stream = stream,
            .state = .connecting,
            .pool = .admitted,
            .remote = grant.endpoint,
            .reserved = 2,
        }) catch unreachable;
        self.attachBuffer(self.connections.get(id).?);
        session.admitted += 1;
        return id;
    }

    /// Ends the session now: its listener, every connection and every event it still
    /// had queued. Handles into it are stale afterwards.
    pub fn closeSession(self: *Service, session_id: SessionHandle) void {
        const session = self.sessions.get(session_id) orelse return;
        for (self.collect()) |id| {
            const conn = self.connections.get(id) orelse continue;
            if (!conn.session.eql(session_id)) continue;
            if (conn.state == .negotiating or conn.state == .synchronizing) {
                if (self.enqueueNotice(conn, .{ .disconnect = .closed })) _ = self.pushOut(conn);
            }
            self.finalize(id);
        }
        if (!session.listener.isNone()) self.transport.closeListener(session.listener);
        self.purgeEvents(session_id);
        _ = self.sessions.remove(session_id);
    }

    pub fn sessionInfo(self: *Service, session_id: SessionHandle) ?SessionInfo {
        const session = self.sessions.get(session_id) orelse return null;
        return .{
            .grant = self.grants[session.grant].id,
            .role = session.role,
            .state = session.state,
            .epoch = session.epoch,
            .channels = session.channel_count,
            .pending = session.pending,
            .peers = session.admitted,
            .listening = if (session.listener.isNone()) null else self.transport.listenerEndpoint(session.listener),
        };
    }

    /// A session's peers — authorized connections, closing ones included — in slot
    /// order. Returns how many there are, which may exceed `out.len`.
    pub fn sessionPeers(self: *Service, session_id: SessionHandle, out: []PeerHandle) usize {
        var count: usize = 0;
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (!entry.value.session.eql(session_id) or entry.value.pool != .admitted) continue;
            if (count < out.len) out[count] = entry.id;
            count += 1;
        }
        return count;
    }

    // -- peers --------------------------------------------------------------------------

    pub fn peerInfo(self: *Service, peer: PeerHandle) ?PeerInfo {
        const conn = self.connections.get(peer) orelse return null;
        return .{
            .session = conn.session,
            .state = conn.state,
            .principal = conn.principal,
            .participant = if (conn.admitted) conn.participant else 0,
            .epoch = if (conn.admitted) conn.epoch else 0,
            .remote = conn.remote,
        };
    }

    /// Ends a peer with `reason`, which it is told if it can still be.
    pub fn disconnect(self: *Service, peer: PeerHandle, reason: wire.DisconnectReason) error{InvalidHandle}!void {
        const conn = self.connections.get(peer) orelse return error.InvalidHandle;
        if (conn.state == .closing) return;
        if (conn.pool == .pending) return self.finalize(peer);
        self.end(peer, .{ .local = reason });
    }

    // -- events and stats ---------------------------------------------------------------

    pub fn nextEvent(self: *Service) ?Event {
        if (self.event_len == 0) return null;
        const event = self.events[self.event_start];
        self.event_start = (self.event_start + 1) % self.events.len;
        self.event_len -= 1;
        return event;
    }

    pub fn stats(self: *Service) Stats {
        var result = self.counters;
        result.sessions = self.sessions.count();
        result.queued_events = @intCast(self.event_len);
        result.reserved_events = @intCast(self.event_reserved);
        var it = self.connections.iterator();
        while (it.next()) |entry| switch (entry.value.pool) {
            .pending => result.pending += 1,
            .admitted => result.peers += 1,
        };
        return result;
    }

    // -- the pump -----------------------------------------------------------------------

    /// Does one bounded round of work at monotonic time `now` (nanoseconds; a value
    /// earlier than the last is treated as no time passing). Accepts, then gives every
    /// connection its budget, starting one further along each pump.
    pub fn pump(self: *Service, now: u64) void {
        if (now > self.now) self.now = now;
        var sessions = self.sessions.iterator();
        while (sessions.next()) |entry| {
            if (entry.value.role == .server and entry.value.state == .running) self.acceptFrom(entry.id);
        }
        const order = self.collect();
        if (order.len == 0) return;
        const first = self.rotation % order.len;
        for (0..order.len) |offset| self.step(order[(first + offset) % order.len]);
        self.rotation +%= 1;
    }

    fn acceptFrom(self: *Service, session_id: SessionHandle) void {
        var budget = self.limits.pending_handshakes;
        while (budget > 0) : (budget -= 1) {
            const session = self.sessions.get(session_id).?;
            const accepted = self.transport.accept(session.listener) catch {
                self.counters.accept_errors += 1;
                return;
            };
            const stream = switch (accepted) {
                .none => return,
                .shed => {
                    self.counters.shed.transport += 1;
                    continue;
                },
                .stream => |stream| stream,
            };
            self.counters.accepted += 1;
            const remote = self.transport.remote(stream).?;
            // Full or rate-limited, the connection is taken and closed before any
            // handshake call, so a flood neither waits in the backlog nor costs crypto.
            if (session.pending >= self.limits.pending_handshakes) {
                self.transport.close(stream);
                self.counters.shed.pending_full += 1;
                continue;
            }
            switch (self.limiter.admit(remote.address, self.now)) {
                .allowed => {},
                .source_rate => {
                    self.transport.close(stream);
                    self.counters.shed.source_rate += 1;
                    continue;
                },
                .global_rate => {
                    self.transport.close(stream);
                    self.counters.shed.global_rate += 1;
                    continue;
                },
            }
            _ = self.connections.add(self.gpa, .{
                .session = session_id,
                .stream = stream,
                .state = .authenticating,
                .pool = .pending,
                .remote = remote,
                .born = self.now,
            }) catch unreachable;
            session.pending += 1;
        }
    }

    fn step(self: *Service, id: PeerHandle) void {
        const conn = self.connections.get(id) orelse return;
        if (conn.born == null) conn.born = self.now;
        switch (conn.state) {
            .connecting, .authenticating => self.stepHandshake(id),
            .negotiating, .synchronizing => self.stepExchange(id),
            .closing => self.stepClosing(id),
        }
    }

    fn stepHandshake(self: *Service, id: PeerHandle) void {
        var calls: u8 = 0;
        while (calls < self.limits.tls_handshake_calls_per_peer_per_pump) : (calls += 1) {
            const conn = self.connections.get(id).?;
            const state = self.transport.advance(conn.stream) catch .failed;
            switch (state) {
                .connecting => {
                    conn.state = .connecting;
                    break;
                },
                .handshaking => conn.state = .authenticating,
                .established, .closed => {
                    self.authenticated(id);
                    return;
                },
                .failed => {
                    self.handshakeFailed(id, self.transport.failure(conn.stream) orelse .internal);
                    return;
                },
            }
        }
        const conn = self.connections.get(id).?;
        if (self.elapsed(conn.born.?) >= ms(self.limits.admission_timeout_ms)) {
            if (conn.pool == .pending) {
                self.counters.pending_timeouts += 1;
                self.finalize(id);
            } else {
                self.end(id, .{ .timed_out = .admission });
            }
        }
    }

    fn handshakeFailed(self: *Service, id: PeerHandle, failure: transport.Failure) void {
        const conn = self.connections.get(id).?;
        if (conn.pool == .pending) {
            self.counters.handshake_failures.getPtr(failure).* +|= 1;
            self.finalize(id);
        } else {
            self.end(id, .{ .transport = failure });
        }
    }

    /// TLS has verified the peer. A server now decides whether it is a peer at all; a
    /// client starts negotiating.
    fn authenticated(self: *Service, id: PeerHandle) void {
        const conn = self.connections.get(id).?;
        const verified = self.transport.peer(conn.stream) catch {
            self.handshakeFailed(id, .internal);
            return;
        };
        conn.authenticated = true;
        conn.key = verified.key;
        const session = self.sessions.get(conn.session).?;
        switch (session.role) {
            .server => {
                const principal = self.principalOf(verified.key) orelse {
                    self.counters.denied += 1;
                    return self.refuseUnauthorized(id, .policy);
                };
                if (self.principalConnected(principal)) {
                    self.counters.duplicates += 1;
                    return self.refuseUnauthorized(id, .policy);
                }
                if (session.admitted >= self.limits.peers_per_session or self.free_buffer_count == 0 or
                    !self.reserveEvents(2))
                {
                    self.counters.capacity_refusals += 1;
                    return self.refuseUnauthorized(id, .capacity);
                }
                session.pending -= 1;
                session.admitted += 1;
                conn.pool = .admitted;
                conn.principal = principal;
                conn.reserved = 2;
                self.attachBuffer(conn);
                conn.state = .negotiating;
            },
            .client => {
                conn.state = .negotiating;
                self.sendNegotiation(conn, conn.session);
            },
        }
        self.stepExchange(id);
    }

    /// A verified key this host does not admit, a principal already connected, or no
    /// room: the refusal is written straight to the stream, since such a connection
    /// never gets a queue, and the connection lingers only to deliver it.
    fn refuseUnauthorized(self: *Service, id: PeerHandle, reason: wire.RefusalReason) void {
        const conn = self.connections.get(id).?;
        var payload: [wire.Refusal.encoded_size]u8 = undefined;
        (wire.Refusal{ .reason = reason }).encode(&payload) catch unreachable;
        var bytes: [wire.header_size + wire.Refusal.encoded_size]u8 = undefined;
        const frame = wire.encodeFrame(&bytes, .{ .kind = .refusal, .total_bytes = 0, .sequence = 1 }, &payload, self.limits.frame_bytes) catch unreachable;
        const taken = self.transport.write(conn.stream, frame) catch 0;
        if (taken != frame.len) return self.finalize(id);
        conn.sent = 1;
        conn.state = .closing;
        conn.closing_since = self.now;
    }

    fn sendNegotiation(self: *Service, conn: *Connection, session_id: SessionHandle) void {
        const session = self.sessions.get(session_id).?;
        const frozen = &self.compatibility;
        var hello: [wire.ClientHello.encoded_size]u8 = undefined;
        (wire.ClientHello{
            .application_id = frozen.application,
            .application_revision = frozen.application_revision,
            .tick_rate_millihertz = frozen.tick_rate_millihertz,
            .compatibility_id = frozen.compatibility_id,
            .catalogue_count = @intCast(frozen.items.len),
            .channel_count = session.channel_count,
        }).encode(&hello) catch unreachable;
        // `init` checked that the whole negotiation fits an empty queue.
        std.debug.assert(self.enqueue(conn, .client_hello, &hello));
        var item: [wire.CompatibilityItem.encoded_size]u8 = undefined;
        for (frozen.items) |entry| {
            entry.encode(&item) catch unreachable;
            std.debug.assert(self.enqueue(conn, .compatibility_item, &item));
        }
        var descriptor: [wire.ChannelPayload.encoded_size]u8 = undefined;
        for (self.sessionChannels(session_id)[0..session.channel_count]) |entry| {
            wire.ChannelPayload.encode(entry, &descriptor) catch unreachable;
            std.debug.assert(self.enqueue(conn, .channel_descriptor, &descriptor));
        }
        var finished: [wire.NegotiationFinished.encoded_size]u8 = undefined;
        (wire.NegotiationFinished{ .catalogue_digest = frozen.digest, .channel_digest = session.channel_digest }).encode(&finished) catch unreachable;
        std.debug.assert(self.enqueue(conn, .negotiation_finished, &finished));
    }

    fn stepExchange(self: *Service, id: PeerHandle) void {
        // The peer is judged before anything more it sent is read: `advance` fails a
        // stream whose peer's chain has expired, so no byte arrives from an identity
        // after it stops being valid, whatever the other side has already done.
        const conn = self.connections.get(id).?;
        if ((self.transport.advance(conn.stream) catch .failed) == .failed) {
            return self.end(id, .{ .transport = self.transport.failure(conn.stream) orelse .internal });
        }
        if (!self.receive(id)) return;
        if (!self.timers(id)) return;
        const out = self.pushOut(self.connections.get(id).?);
        if (out.failed) |failure| return self.end(id, .{ .transport = failure });
        if (out.closed) return self.end(id, .peer_closed);
    }

    /// Reads and decodes within the per-pump budget, handling each frame as it
    /// completes. Bytes read beyond the frame budget stay staged for the next pump.
    /// Returns whether the connection is still exchanging.
    fn receive(self: *Service, id: PeerHandle) bool {
        const byte_budget = self.limits.pump_bytes_per_direction_per_peer;
        const frame_budget = self.limits.pump_frames_per_peer;
        var bytes: u32 = 0;
        var frames: u16 = 0;
        defer {
            self.counters.peak_bytes_in_per_pump = @max(self.counters.peak_bytes_in_per_pump, bytes);
            self.counters.peak_frames_in_per_pump = @max(self.counters.peak_frames_in_per_pump, frames);
        }
        while (true) {
            var conn = self.connections.get(id) orelse return false;
            if (conn.state == .closing) return false;
            const staging = self.stagingStorage(conn.buffer.?);
            if (conn.staged_len == 0) {
                if (frames >= frame_budget or bytes >= byte_budget) return true;
                const room = @min(staging.len, byte_budget - bytes);
                const result = self.transport.read(conn.stream, staging[0..room]) catch {
                    self.end(id, .{ .transport = self.transport.failure(conn.stream) orelse .internal });
                    return false;
                };
                switch (result) {
                    .would_block => return true,
                    .closed => {
                        const ending: Ending = if (conn.decoder.finish()) |_| .peer_closed else |_| .{ .protocol = .truncated };
                        self.end(id, ending);
                        return false;
                    },
                    .data => |count| {
                        if (count == 0) return true;
                        conn.staged_start = 0;
                        conn.staged_len = count;
                        bytes += @intCast(count);
                        self.counters.bytes_received += count;
                    },
                }
            }
            while (conn.staged_len > 0 and frames < frame_budget) {
                const progress = conn.decoder.feed(staging[conn.staged_start..][0..conn.staged_len]) catch |err| {
                    self.malformed(id, err);
                    return false;
                };
                conn.staged_start += progress.consumed;
                conn.staged_len -= progress.consumed;
                const frame = progress.frame orelse continue;
                frames += 1;
                if (!self.handleFrame(id, frame)) return false;
                conn = self.connections.get(id).?;
                conn.decoder.consumeFrame();
            }
            // What the frame budget left staged waits for the next pump.
            if (frames >= frame_budget) return true;
        }
    }

    fn malformed(self: *Service, id: PeerHandle, err: wire.Error) void {
        const conn = self.connections.get(id).?;
        const session = self.sessions.get(conn.session).?;
        // A peer speaking another wire version is told so, in version 1, before it says
        // anything else; anything else unparseable is a protocol fault.
        if (err == error.UnsupportedVersion and session.role == .server and conn.received == 0) {
            return self.refuse(id, .version, null);
        }
        self.end(id, .{ .protocol = .malformed });
    }

    /// Returns whether the connection is still exchanging.
    fn handleFrame(self: *Service, id: PeerHandle, frame: wire.Frame) bool {
        const conn = self.connections.get(id).?;
        const expected = wire.nextSequence(conn.received) catch return self.fault(id, .sequence);
        if (frame.header.sequence != expected) return self.fault(id, .sequence);
        conn.received = expected;
        conn.last_received_at = self.now;
        self.counters.frames_received += 1;

        if (frame.header.kind == .disconnect) {
            const notice = wire.Disconnect.decode(frame.payload) catch return self.fault(id, .malformed);
            self.end(id, .{ .peer_disconnected = notice.reason });
            return false;
        }
        const session = self.sessions.get(conn.session).?;
        return switch (conn.state) {
            .negotiating => switch (session.role) {
                .server => self.serverNegotiation(id, frame),
                .client => self.clientNegotiation(id, frame),
            },
            .synchronizing => self.synchronizing(id, frame),
            else => false,
        };
    }

    fn serverNegotiation(self: *Service, id: PeerHandle, frame: wire.Frame) bool {
        const conn = self.connections.get(id).?;
        const session = self.sessions.get(conn.session).?;
        const frozen = &self.compatibility;
        const kind = frame.header.kind;
        switch (conn.stage) {
            .hello => {
                if (kind != .client_hello) return self.fault(id, .unexpected);
                const hello = wire.ClientHello.decode(frame.payload) catch return self.fault(id, .malformed);
                if (!hello.application_id.eql(frozen.application) or hello.application_revision != frozen.application_revision) {
                    return self.refuseNegotiation(id, .application, null);
                }
                if (hello.tick_rate_millihertz != frozen.tick_rate_millihertz or
                    !std.mem.eql(u8, &hello.compatibility_id, &frozen.compatibility_id))
                {
                    return self.refuseNegotiation(id, .compatibility, null);
                }
                if (hello.catalogue_count != frozen.items.len) return self.refuseNegotiation(id, .catalogue, null);
                if (hello.channel_count != session.channel_count) return self.refuseNegotiation(id, .channel, null);
                conn.stage = if (frozen.items.len > 0) .items else .channels;
                conn.index = 0;
            },
            .items => {
                if (kind != .compatibility_item) return self.fault(id, .unexpected);
                const item = wire.CompatibilityItem.decode(frame.payload) catch return self.fault(id, .malformed);
                if (!compatibility.itemsEqual(item, frozen.items[conn.index])) {
                    return self.refuseNegotiation(id, .catalogue, conn.index);
                }
                conn.index += 1;
                if (conn.index == frozen.items.len) {
                    conn.stage = .channels;
                    conn.index = 0;
                }
            },
            .channels => {
                if (kind != .channel_descriptor) return self.fault(id, .unexpected);
                const descriptor = wire.ChannelPayload.decode(frame.payload) catch return self.fault(id, .malformed);
                if (!compatibility.channelsEqual(descriptor, self.sessionChannels(conn.session)[conn.index])) {
                    return self.refuseNegotiation(id, .channel, conn.index);
                }
                conn.index += 1;
                if (conn.index == session.channel_count) conn.stage = .finished;
            },
            .finished => {
                if (kind != .negotiation_finished) return self.fault(id, .unexpected);
                const finished = wire.NegotiationFinished.decode(frame.payload) catch return self.fault(id, .malformed);
                if (!std.mem.eql(u8, &finished.catalogue_digest, &frozen.digest)) return self.refuseNegotiation(id, .catalogue, null);
                if (!std.mem.eql(u8, &finished.channel_digest, &session.channel_digest)) return self.refuseNegotiation(id, .channel, null);
                return self.admit(id);
            },
        }
        return true;
    }

    /// Compatibility passed: the peer becomes a participant with a number never used
    /// before in this session, and is told so.
    fn admit(self: *Service, id: PeerHandle) bool {
        const conn = self.connections.get(id).?;
        const session = self.sessions.get(conn.session).?;
        const participant = session.next_participant;
        if (participant == std.math.maxInt(u32)) return self.refuseNegotiation(id, .capacity, null);
        session.next_participant += 1;

        const frozen = &self.compatibility;
        var hello: [wire.ServerHello.encoded_size]u8 = undefined;
        (wire.ServerHello{
            .application_id = frozen.application,
            .application_revision = frozen.application_revision,
            .tick_rate_millihertz = frozen.tick_rate_millihertz,
            .compatibility_id = frozen.compatibility_id,
            .session_epoch = session.epoch,
            .participant_number = participant,
            .catalogue_count = @intCast(frozen.items.len),
            .channel_count = session.channel_count,
            .peer_limit = self.limits.peers_per_session,
        }).encode(&hello) catch unreachable;
        var finished: [wire.NegotiationFinished.encoded_size]u8 = undefined;
        (wire.NegotiationFinished{ .catalogue_digest = frozen.digest, .channel_digest = session.channel_digest }).encode(&finished) catch unreachable;
        if (!self.enqueue(conn, .server_hello, &hello) or !self.enqueue(conn, .negotiation_finished, &finished)) {
            self.end(id, .overloaded);
            return false;
        }
        self.enterSynchronizing(id, conn, participant, session.epoch);
        return true;
    }

    fn clientNegotiation(self: *Service, id: PeerHandle, frame: wire.Frame) bool {
        const conn = self.connections.get(id).?;
        const session = self.sessions.get(conn.session).?;
        const frozen = &self.compatibility;
        const kind = frame.header.kind;
        switch (conn.stage) {
            .hello => {
                if (kind == .refusal) {
                    const refusal = wire.Refusal.decode(frame.payload) catch return self.fault(id, .malformed);
                    self.end(id, .{ .refused_by_peer = refusal });
                    return false;
                }
                if (kind != .server_hello) return self.fault(id, .unexpected);
                const hello = wire.ServerHello.decode(frame.payload) catch return self.fault(id, .malformed);
                // The server has already compared; a client still checks the answer
                // against what it sent before believing it was admitted.
                if (!hello.application_id.eql(frozen.application) or
                    hello.application_revision != frozen.application_revision or
                    hello.tick_rate_millihertz != frozen.tick_rate_millihertz or
                    !std.mem.eql(u8, &hello.compatibility_id, &frozen.compatibility_id) or
                    hello.catalogue_count != frozen.items.len or hello.channel_count != session.channel_count)
                {
                    return self.fault(id, .mismatch);
                }
                conn.epoch = hello.session_epoch;
                conn.participant = hello.participant_number;
                conn.stage = .finished;
            },
            .finished => {
                if (kind != .negotiation_finished) return self.fault(id, .unexpected);
                const finished = wire.NegotiationFinished.decode(frame.payload) catch return self.fault(id, .malformed);
                if (!std.mem.eql(u8, &finished.catalogue_digest, &frozen.digest) or
                    !std.mem.eql(u8, &finished.channel_digest, &session.channel_digest))
                {
                    return self.fault(id, .mismatch);
                }
                self.enterSynchronizing(id, conn, conn.participant, conn.epoch);
            },
            .items, .channels => return self.fault(id, .unexpected),
        }
        return true;
    }

    fn enterSynchronizing(self: *Service, id: PeerHandle, conn: *Connection, participant: u32, epoch: u64) void {
        conn.admitted = true;
        conn.participant = participant;
        conn.epoch = epoch;
        conn.state = .synchronizing;
        conn.admitted_at = self.now;
        conn.last_received_at = self.now;
        conn.last_sent_at = self.now;
        self.counters.admitted += 1;
        conn.reserved -= 1;
        self.pushEvent(.{ .session = conn.session, .peer = id, .kind = .{ .admitted = .{
            .participant = participant,
            .epoch = epoch,
            .principal = conn.principal,
        } } });
    }

    fn synchronizing(self: *Service, id: PeerHandle, frame: wire.Frame) bool {
        const conn = self.connections.get(id).?;
        switch (frame.header.kind) {
            .heartbeat => {
                const heartbeat = wire.Heartbeat.decode(frame.payload) catch return self.fault(id, .malformed);
                if (heartbeat.session_epoch != conn.epoch or heartbeat.last_received_sequence > conn.sent) {
                    return self.fault(id, .mismatch);
                }
                return true;
            },
            else => return self.fault(id, .unexpected),
        }
    }

    /// Returns whether the connection is still exchanging.
    fn timers(self: *Service, id: PeerHandle) bool {
        const conn = self.connections.get(id).?;
        const limits = self.limits;
        switch (conn.state) {
            .negotiating => if (self.elapsed(conn.born.?) >= ms(limits.admission_timeout_ms)) {
                self.end(id, .{ .timed_out = .admission });
                return false;
            },
            .synchronizing => {
                if (self.elapsed(conn.admitted_at) >= ms(limits.initial_sync_timeout_ms)) {
                    self.end(id, .{ .timed_out = .initial_sync });
                    return false;
                }
                if (self.elapsed(conn.last_received_at) >= ms(limits.no_progress_timeout_ms)) {
                    self.end(id, .{ .timed_out = .no_progress });
                    return false;
                }
                if (self.elapsed(conn.last_sent_at) >= self.heartbeatInterval()) {
                    var payload: [wire.Heartbeat.encoded_size]u8 = undefined;
                    (wire.Heartbeat{ .session_epoch = conn.epoch, .last_received_sequence = conn.received }).encode(&payload) catch unreachable;
                    if (!self.enqueue(conn, .heartbeat, &payload)) {
                        self.end(id, .overloaded);
                        return false;
                    }
                }
            },
            else => {},
        }
        if (conn.stalled_since) |since| {
            if (self.elapsed(since) >= ms(limits.no_progress_timeout_ms)) {
                self.end(id, .{ .timed_out = .write_stall });
                return false;
            }
        }
        return true;
    }

    fn heartbeatInterval(self: *const Service) u64 {
        return ms(self.limits.no_progress_timeout_ms) / 4;
    }

    /// Delivers what is queued, keeps reading only to discard, and closes once the peer
    /// has gone or the linger has run out.
    fn stepClosing(self: *Service, id: PeerHandle) void {
        const conn = self.connections.get(id).?;
        const out = self.pushOut(conn);
        var gone = out.failed != null or out.closed;
        var drained: usize = 0;
        while (!gone and drained < self.limits.pump_bytes_per_direction_per_peer) {
            const result = self.transport.read(conn.stream, self.drain) catch {
                gone = true;
                break;
            };
            switch (result) {
                .data => |count| {
                    if (count == 0) break;
                    drained += count;
                },
                .would_block => break,
                .closed => gone = true,
            }
        }
        if (gone or self.elapsed(conn.closing_since) >= ms(self.limits.close_linger_ms)) self.finalize(id);
    }

    // -- ending ---------------------------------------------------------------------------

    fn fault(self: *Service, id: PeerHandle, kind: Fault) bool {
        self.end(id, .{ .protocol = kind });
        return false;
    }

    fn refuseNegotiation(self: *Service, id: PeerHandle, reason: wire.RefusalReason, detail: ?u16) bool {
        self.refuse(id, reason, detail);
        return false;
    }

    fn refuse(self: *Service, id: PeerHandle, reason: wire.RefusalReason, detail: ?u16) void {
        self.counters.refused += 1;
        self.end(id, .{ .refused = .{ .reason = reason, .detail_index = detail orelse std.math.maxInt(u16) } });
    }

    /// Records why, reports it, says it to the peer if there is anything to say and a
    /// stream to say it on, and then closes — at once, or after lingering to deliver it.
    fn end(self: *Service, id: PeerHandle, ending: Ending) void {
        const conn = self.connections.get(id).?;
        if (conn.state == .closing) return;
        if (conn.reserved > 0) {
            if (!conn.admitted) {
                self.releaseEvents(1);
                conn.reserved -= 1;
            }
            conn.reserved -= 1;
            self.pushEvent(.{ .session = conn.session, .peer = id, .kind = .{ .ended = .{
                .participant = if (conn.admitted) conn.participant else 0,
                .principal = conn.principal,
                .ending = ending,
            } } });
        }
        const session = self.sessions.get(conn.session).?;
        if (noticeFor(conn, session.role, ending)) |notice| {
            if (self.enqueueNotice(conn, notice)) {
                conn.state = .closing;
                conn.closing_since = self.now;
                return;
            }
        }
        self.finalize(id);
    }

    fn noticeFor(conn: *const Connection, role: Role, ending: Ending) ?Notice {
        if (conn.state != .negotiating and conn.state != .synchronizing) return null;
        return switch (ending) {
            .local => |reason| .{ .disconnect = reason },
            .refused => |refusal| .{ .refusal = refusal },
            .revoked, .rotated => .{ .disconnect = .policy },
            .timed_out => if (role == .server and conn.state == .negotiating)
                .{ .refusal = .{ .reason = .timeout } }
            else
                .{ .disconnect = .timeout },
            .protocol => .{ .disconnect = .protocol },
            .overloaded => .{ .disconnect = .capacity },
            .peer_disconnected, .peer_closed, .refused_by_peer, .transport => null,
        };
    }

    fn enqueueNotice(self: *Service, conn: *Connection, notice: Notice) bool {
        switch (notice) {
            .refusal => |refusal| {
                var payload: [wire.Refusal.encoded_size]u8 = undefined;
                refusal.encode(&payload) catch unreachable;
                return self.enqueue(conn, .refusal, &payload);
            },
            .disconnect => |reason| {
                var payload: [wire.Disconnect.encoded_size]u8 = undefined;
                (wire.Disconnect{ .reason = reason }).encode(&payload) catch unreachable;
                return self.enqueue(conn, .disconnect, &payload);
            },
        }
    }

    /// Releases everything the connection held. Its handle is stale afterwards.
    fn finalize(self: *Service, id: PeerHandle) void {
        const conn = self.connections.get(id).?;
        const session = self.sessions.get(conn.session).?;
        self.transport.close(conn.stream);
        if (conn.buffer) |buffer| {
            self.free_buffers[self.free_buffer_count] = buffer;
            self.free_buffer_count += 1;
        }
        if (conn.reserved > 0) self.releaseEvents(conn.reserved);
        switch (conn.pool) {
            .pending => session.pending -= 1,
            .admitted => session.admitted -= 1,
        }
        _ = self.connections.remove(id);
    }

    /// Ends every server-side peer the current allowlist no longer admits as the
    /// principal it was admitted as.
    fn revalidate(self: *Service) void {
        for (self.collect()) |id| {
            const conn = self.connections.get(id) orelse continue;
            if (conn.pool != .admitted or !conn.authenticated or conn.state == .closing) continue;
            const session = self.sessions.get(conn.session).?;
            if (session.role != .server) continue;
            const principal = self.principalOf(conn.key);
            if (principal == null or principal.? != conn.principal) self.end(id, .revoked);
        }
    }

    // -- queues ---------------------------------------------------------------------------

    /// Appends one whole frame, numbered with the next sequence. False, changing
    /// nothing, when the queue cannot hold it.
    fn enqueue(self: *Service, conn: *Connection, kind: wire.Kind, payload: []const u8) bool {
        const buffer = conn.buffer orelse return false;
        const total = wire.header_size + payload.len;
        const storage = self.sendStorage(buffer);
        if (storage.len - conn.ring.len < total) return false;
        const sequence = wire.nextSequence(conn.sent) catch return false;
        var header: [wire.header_size]u8 = undefined;
        wire.encodeHeader(&header, .{ .kind = kind, .total_bytes = @intCast(total), .sequence = sequence }, self.limits.frame_bytes) catch return false;
        conn.ring.write(storage, &header);
        conn.ring.write(storage, payload);
        conn.sent = sequence;
        conn.last_sent_at = self.now;
        self.counters.frames_sent += 1;
        self.counters.peak_send_queue = @max(self.counters.peak_send_queue, @as(u32, @intCast(conn.ring.len)));
        return true;
    }

    /// Hands queued bytes to the transport within the per-pump budget and advances the
    /// stream, which retries a held record and judges the peer's certificate validity.
    /// Tracks whether output is stalled for the write-stall deadline.
    fn pushOut(self: *Service, conn: *Connection) Out {
        const budget = self.limits.pump_bytes_per_direction_per_peer;
        const held_before = self.transport.pendingBytes(conn.stream) catch 0;
        var moved: usize = 0;
        if (conn.buffer) |buffer| {
            const storage = self.sendStorage(buffer);
            while (conn.ring.len > 0 and moved < budget) {
                const run = conn.ring.head(storage);
                const taken = self.transport.write(conn.stream, run[0..@min(run.len, budget - moved)]) catch |err| switch (err) {
                    error.StreamClosed => return .{ .closed = true },
                    error.StreamFailed => return .{ .failed = self.transport.failure(conn.stream) orelse .internal },
                    error.NotEstablished, error.InvalidHandle => return .{ .failed = .internal },
                };
                if (taken == 0) break;
                conn.ring.consume(storage.len, taken);
                moved += taken;
            }
        }
        self.counters.bytes_sent += moved;
        self.counters.peak_bytes_out_per_pump = @max(self.counters.peak_bytes_out_per_pump, @as(u32, @intCast(moved)));
        const state = self.transport.advance(conn.stream) catch .failed;
        switch (state) {
            .failed => return .{ .failed = self.transport.failure(conn.stream) orelse .internal },
            .closed => if (conn.ring.len > 0) return .{ .closed = true },
            else => {},
        }
        const held_after = self.transport.pendingBytes(conn.stream) catch 0;
        const unsent = conn.ring.len + held_after;
        if (unsent == 0 or moved > 0 or held_after < held_before) {
            conn.stalled_since = if (unsent == 0) null else self.now;
        } else if (conn.stalled_since == null) {
            conn.stalled_since = self.now;
        }
        return .{};
    }

    fn reserveEvents(self: *Service, count: usize) bool {
        if (self.event_len + self.event_reserved + count > self.events.len) return false;
        self.event_reserved += count;
        return true;
    }

    fn releaseEvents(self: *Service, count: usize) void {
        self.event_reserved -= count;
    }

    /// Always has room: every event was reserved when its connection could first
    /// produce it.
    fn pushEvent(self: *Service, event: Event) void {
        std.debug.assert(self.event_reserved > 0);
        self.event_reserved -= 1;
        self.events[(self.event_start + self.event_len) % self.events.len] = event;
        self.event_len += 1;
        self.counters.peak_events = @max(self.counters.peak_events, @as(u32, @intCast(self.event_len)));
    }

    fn purgeEvents(self: *Service, session_id: SessionHandle) void {
        var kept: usize = 0;
        for (0..self.event_len) |offset| {
            const event = self.events[(self.event_start + offset) % self.events.len];
            if (event.session.eql(session_id)) continue;
            self.events[(self.event_start + kept) % self.events.len] = event;
            kept += 1;
        }
        self.event_len = kept;
    }

    // -- lookups and storage ----------------------------------------------------------------

    fn collect(self: *Service) []PeerHandle {
        var count: usize = 0;
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            self.order[count] = entry.id;
            count += 1;
        }
        return self.order[0..count];
    }

    fn freeze(self: *Service, session_id: SessionHandle, session: *SessionSlot) void {
        session.channel_digest = compatibility.freezeChannels(self.sessionChannels(session_id)[0..session.channel_count]);
        session.state = .running;
    }

    fn grantIndex(self: *const Service, id: core.ContentId) ?usize {
        for (self.grants, 0..) |grant, index| {
            if (grant.id.eql(id)) return index;
        }
        return null;
    }

    fn sessionOfGrant(self: *Service, grant: usize) ?SessionHandle {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value.grant == grant) return entry.id;
        }
        return null;
    }

    fn principalOf(self: *const Service, key: transport.KeyFingerprint) ?u32 {
        for (self.identities[0..self.identity_count]) |entry| {
            if (entry.key.eql(key)) return entry.principal;
        }
        return null;
    }

    /// Whether a live, not-yet-ended connection already stands for `principal`.
    fn principalConnected(self: *Service, principal: u32) bool {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            const conn = entry.value;
            if (conn.pool == .admitted and conn.principal == principal and conn.state != .closing) return true;
        }
        return false;
    }

    fn sessionChannels(self: *Service, session_id: SessionHandle) []channel.Descriptor {
        const per = self.limits.channels;
        return self.channels[@as(usize, session_id.index) * per ..][0..per];
    }

    fn bufferStride(self: *const Service) usize {
        return @as(usize, self.limits.send_bytes_per_peer) + self.limits.frame_bytes + staging_bytes;
    }

    fn attachBuffer(self: *Service, conn: *Connection) void {
        self.free_buffer_count -= 1;
        const buffer = self.free_buffers[self.free_buffer_count];
        conn.buffer = buffer;
        conn.ring = .{};
        conn.staged_start = 0;
        conn.staged_len = 0;
        conn.decoder = wire.Decoder.init(self.frameStorage(buffer), self.limits.frame_bytes) catch unreachable;
    }

    fn sendStorage(self: *Service, buffer: u32) []u8 {
        return self.slab[@as(usize, buffer) * self.bufferStride() ..][0..self.limits.send_bytes_per_peer];
    }

    fn frameStorage(self: *Service, buffer: u32) []u8 {
        return self.slab[@as(usize, buffer) * self.bufferStride() + self.limits.send_bytes_per_peer ..][0..self.limits.frame_bytes];
    }

    fn stagingStorage(self: *Service, buffer: u32) []u8 {
        const offset = @as(usize, buffer) * self.bufferStride() + self.limits.send_bytes_per_peer + self.limits.frame_bytes;
        return self.slab[offset..][0..staging_bytes];
    }

    fn elapsed(self: *const Service, since: u64) u64 {
        return self.now -| since;
    }
};

fn ms(value: u32) u64 {
    return @as(u64, value) * std.time.ns_per_ms;
}

fn identityLessThan(_: void, a: Identity, b: Identity) bool {
    return std.mem.order(u8, &a.key.sha256, &b.key.sha256) == .lt;
}

// -- tests ----------------------------------------------------------------------------
//
// What needs no identity is tested here. Sessions that authenticate need disposable
// certificates, which only `engine/tests/net_sessions.zig` generates.

const testing = std.testing;

const test_description: compatibility.Description = .{
    .application = core.ContentId.fromString("test:app"),
    .application_revision = 1,
    .tick_rate_millihertz = 60_000,
    .compatibility_id = @splat(0),
};

test "a byte ring wraps and hands out contiguous runs" {
    var storage: [8]u8 = undefined;
    var ring: Ring = .{};
    ring.write(&storage, "abcdef");
    ring.consume(storage.len, 4);
    ring.write(&storage, "ghijk");
    try testing.expectEqualStrings("efgh", ring.head(&storage));
    ring.consume(storage.len, 4);
    try testing.expectEqualStrings("ijk", ring.head(&storage));
    ring.consume(storage.len, 3);
    try testing.expectEqual(@as(usize, 0), ring.len);
    try testing.expectEqual(@as(usize, 0), ring.start);
}

test "a service is checked against its transport and its policy before it exists" {
    const t = try Transport.init(testing.allocator, transportOptions(.{}, .memory));
    defer t.deinit();

    const service = try Service.init(testing.allocator, t, .{ .compatibility = test_description });
    service.deinit();

    // A grant must name credentials of its own role on this transport.
    try testing.expectError(error.InvalidGrant, Service.init(testing.allocator, t, .{
        .compatibility = test_description,
        .grants = &.{.{ .id = core.ContentId.fromString("test:server"), .role = .server, .endpoint = transport.Endpoint.loopback(0), .credentials = .none }},
    }));
    try testing.expectError(error.InvalidEpoch, Service.init(testing.allocator, t, .{ .compatibility = test_description, .first_epoch = 0 }));

    const key: transport.KeyFingerprint = .{ .sha256 = @splat(7) };
    try testing.expectError(error.DuplicateIdentity, Service.init(testing.allocator, t, .{
        .compatibility = test_description,
        .identities = &.{ .{ .key = key, .principal = 1 }, .{ .key = key, .principal = 2 } },
    }));
    try testing.expectError(error.InvalidIdentity, Service.init(testing.allocator, t, .{
        .compatibility = test_description,
        .identities = &.{.{ .key = key, .principal = 0 }},
    }));

    // Limits stricter than the transport can enforce are refused rather than assumed.
    var strict: Limits = .{};
    strict.certificate_chain_count = transport.max_chain_certificates - 1;
    try testing.expectError(error.LimitUnenforceable, Service.init(testing.allocator, t, .{ .limits = strict, .compatibility = test_description }));
    strict = .{};
    strict.tls_handshake_call_limit = 32;
    try testing.expectError(error.TransportMismatch, Service.init(testing.allocator, t, .{ .limits = strict, .compatibility = test_description }));
    strict = .{};
    strict.receive_bytes_per_peer = strict.frame_bytes;
    try testing.expectError(error.QueueTooSmall, Service.init(testing.allocator, t, .{ .limits = strict, .compatibility = test_description }));
    strict = .{};
    strict.frame_bytes = 1024;
    strict.send_bytes_per_peer = 1024;
    strict.receive_bytes_per_peer = 1024 + staging_bytes;
    try testing.expectError(error.QueueTooSmall, Service.init(testing.allocator, t, .{ .limits = strict, .compatibility = test_description }));
}

test "the allowlist is replaced whole or not at all" {
    const t = try Transport.init(testing.allocator, transportOptions(.{}, .memory));
    defer t.deinit();
    const a: transport.KeyFingerprint = .{ .sha256 = @splat(1) };
    const b: transport.KeyFingerprint = .{ .sha256 = @splat(2) };
    const service = try Service.init(testing.allocator, t, .{
        .compatibility = test_description,
        .identities = &.{ .{ .key = b, .principal = 2 }, .{ .key = a, .principal = 1 } },
    });
    defer service.deinit();
    try testing.expectEqual(@as(?u32, 1), service.principalOf(a));

    try testing.expectError(error.DuplicateIdentity, service.replaceAllowlist(&.{ .{ .key = a, .principal = 3 }, .{ .key = a, .principal = 4 } }));
    try testing.expectEqual(@as(?u32, 1), service.principalOf(a));
    try testing.expectEqual(@as(?u32, 2), service.principalOf(b));

    try testing.expect(service.revoke(a));
    try testing.expect(!service.revoke(a));
    try testing.expectEqual(@as(?u32, null), service.principalOf(a));
    try testing.expectEqual(@as(?u32, 2), service.principalOf(b));
}

fn initAndDeinit(gpa: Allocator, t: *Transport) !void {
    const packages = [_]compatibility.Package{.{ .id = core.ContentId.fromString("test:base"), .version = .{}, .byte_count = 1, .sha256 = @splat(3) }};
    var description = test_description;
    description.packages = &packages;
    const service = try Service.init(gpa, t, .{
        .compatibility = description,
        .identities = &.{.{ .key = .{ .sha256 = @splat(1) }, .principal = 1 }},
    });
    service.deinit();
}

test "a service that cannot allocate unwinds whole" {
    const t = try Transport.init(testing.allocator, transportOptions(.{}, .memory));
    defer t.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, initAndDeinit, .{t});
}
