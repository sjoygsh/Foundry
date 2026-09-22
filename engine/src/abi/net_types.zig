//! The values the v5 networking surface crosses with (`networking.md` §8, M16 Step 5).
//!
//! Every struct is `extern`, every reserved byte is written as zero, and every size is
//! stated three times — here, in `agreement.c` and in `agreement.zig` — so a drift fails the
//! build on whichever side moved.
//!
//! **Enumerations are numbers, written down.** `net.service`'s enums are free to be
//! reordered; these values are what a compiled consumer holds, and the functions below are
//! the only mapping between the two. Two of them — a channel's direction and delivery, and
//! a disconnect reason — arrive from the caller, so they cross as `i32` and are looked up.
//!
//! **What never crosses:** a key, a certificate, a credential, a principal or a remote
//! address. A peer is its participant number within its session's epoch (§4.1).

const std = @import("std");
const net = @import("net");
const platform = @import("platform");

const types = @import("types.zig");

const ContentId = types.ContentId;
const svc = net.service;
const wire = net.wire;
const transport = platform.transport;

pub const Session = types.NetSession;
pub const Peer = types.NetPeer;

pub const role_server: i32 = 1;
pub const role_client: i32 = 2;

pub const direction_client_to_server: i32 = 1;
pub const direction_server_to_client: i32 = 2;
pub const direction_bidirectional: i32 = 3;

pub const delivery_reliable: i32 = 1;
pub const delivery_latest_state: i32 = 2;

pub const session_configuring: i32 = 1;
pub const session_running: i32 = 2;

pub const event_admitted: i32 = 1;
pub const event_activated: i32 = 2;
pub const event_ended: i32 = 3;

pub const delivery_kind_baseline: i32 = 1;
pub const delivery_kind_state: i32 = 2;
pub const delivery_kind_message: i32 = 3;

pub const ending_local: i32 = 1;
pub const ending_peer_disconnected: i32 = 2;
pub const ending_peer_closed: i32 = 3;
pub const ending_refused: i32 = 4;
pub const ending_refused_by_peer: i32 = 5;
pub const ending_revoked: i32 = 6;
pub const ending_rotated: i32 = 7;
pub const ending_timed_out: i32 = 8;
pub const ending_protocol: i32 = 9;
pub const ending_transport: i32 = 10;
pub const ending_overloaded: i32 = 11;

/// A refusal that names no entry.
pub const no_index: u32 = 0xFFFF;

pub const Endpoint = extern struct {
    address: [4]u8 = @splat(0),
    port: u16 = 0,
    reserved: u16 = 0,

    pub fn of(endpoint: transport.Endpoint) Endpoint {
        return .{ .address = endpoint.address, .port = endpoint.port };
    }
};

pub const GrantInfo = extern struct {
    id: ContentId = .none,
    role: i32 = 0,
    reserved: u32 = 0,
    endpoint: Endpoint = .{},
};

pub const ChannelDesc = extern struct {
    id: ContentId = .none,
    revision: u32 = 0,
    max_payload_bytes: u32 = 0,
    direction: i32 = 0,
    delivery: i32 = 0,
};

pub const SessionInfo = extern struct {
    grant: ContentId = .none,
    role: i32 = 0,
    state: i32 = 0,
    epoch: u64 = 0,
    channels: u16 = 0,
    pending: u16 = 0,
    peers: u16 = 0,
    listening: types.Bool = 0,
    reserved: u8 = 0,
    listen_endpoint: Endpoint = .{},
};

pub const PeerInfo = extern struct {
    session: Session = .none,
    state: i32 = 0,
    participant: u32 = 0,
    epoch: u64 = 0,
};

pub const Ending = extern struct {
    kind: i32 = 0,
    code: i32 = 0,
    index: u32 = no_index,
    reserved: u32 = 0,
};

pub const Event = extern struct {
    session: Session = .none,
    peer: Peer = .none,
    kind: i32 = 0,
    participant: u32 = 0,
    epoch: u64 = 0,
    ending: Ending = .{},
};

pub const Delivery = extern struct {
    kind: i32 = 0,
    bytes: u32 = 0,
    channel: ContentId = .none,
    tick: u64 = 0,
    sequence: u64 = 0,
};

pub const Command = extern struct {
    peer: Peer = .none,
    participant: u32 = 0,
    bytes: u32 = 0,
    number: u64 = 0,
    channel: ContentId = .none,
};

pub const Stats = extern struct {
    sessions: u32 = 0,
    peers: u32 = 0,
    pending: u32 = 0,
    queued_events: u32 = 0,
    reserved_events: u32 = 0,
    reserved: u32 = 0,
    accepted: u64 = 0,
    /// Every connection closed before a handshake call, for whichever reason.
    shed: u64 = 0,
    /// Every handshake that failed before a peer existed, whatever its category.
    handshake_failures: u64 = 0,
    pending_timeouts: u64 = 0,
    denied: u64 = 0,
    duplicates: u64 = 0,
    capacity_refusals: u64 = 0,
    refused: u64 = 0,
    admitted: u64 = 0,
    activations: u64 = 0,
    baselines_sent: u64 = 0,
    commands_sent: u64 = 0,
    commands_received: u64 = 0,
    commands_admitted: u64 = 0,
    states_sent: u64 = 0,
    states_replaced: u64 = 0,
    frames_received: u64 = 0,
    frames_sent: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,

    pub fn of(stats: svc.Stats) Stats {
        var failures: u64 = 0;
        for (stats.handshake_failures.values) |count| failures += count;
        return .{
            .sessions = stats.sessions,
            .peers = stats.peers,
            .pending = stats.pending,
            .queued_events = stats.queued_events,
            .reserved_events = stats.reserved_events,
            .accepted = stats.accepted,
            .shed = stats.shed.transport + stats.shed.pending_full + stats.shed.source_rate + stats.shed.global_rate,
            .handshake_failures = failures,
            .pending_timeouts = stats.pending_timeouts,
            .denied = stats.denied,
            .duplicates = stats.duplicates,
            .capacity_refusals = stats.capacity_refusals,
            .refused = stats.refused,
            .admitted = stats.admitted,
            .activations = stats.activations,
            .baselines_sent = stats.baselines_sent,
            .commands_sent = stats.commands_sent,
            .commands_received = stats.commands_received,
            .commands_admitted = stats.commands_admitted,
            .states_sent = stats.states_sent,
            .states_replaced = stats.states_replaced,
            .frames_received = stats.frames_received,
            .frames_sent = stats.frames_sent,
            .bytes_received = stats.bytes_received,
            .bytes_sent = stats.bytes_sent,
        };
    }
};

// -- mappings ---------------------------------------------------------------------------

pub fn role(value: svc.Role) i32 {
    return switch (value) {
        .server => role_server,
        .client => role_client,
    };
}

pub fn sessionState(value: svc.SessionState) i32 {
    return switch (value) {
        .configuring => session_configuring,
        .running => session_running,
    };
}

pub fn peerState(value: svc.PeerState) i32 {
    return switch (value) {
        .connecting => 1,
        .authenticating => 2,
        .negotiating => 3,
        .synchronizing => 4,
        .active => 5,
        .closing => 6,
    };
}

pub fn direction(value: net.channel.Direction) i32 {
    return switch (value) {
        .client_to_server => direction_client_to_server,
        .server_to_client => direction_server_to_client,
        .bidirectional => direction_bidirectional,
    };
}

pub fn directionIn(code: i32) ?net.channel.Direction {
    return switch (code) {
        direction_client_to_server => .client_to_server,
        direction_server_to_client => .server_to_client,
        direction_bidirectional => .bidirectional,
        else => null,
    };
}

pub fn delivery(value: net.channel.Delivery) i32 {
    return switch (value) {
        .reliable_ordered => delivery_reliable,
        .latest_complete_state => delivery_latest_state,
    };
}

pub fn deliveryIn(code: i32) ?net.channel.Delivery {
    return switch (code) {
        delivery_reliable => .reliable_ordered,
        delivery_latest_state => .latest_complete_state,
        else => null,
    };
}

pub fn deliveryKind(value: svc.Delivery.Kind) i32 {
    return switch (value) {
        .baseline => delivery_kind_baseline,
        .state => delivery_kind_state,
        .message => delivery_kind_message,
    };
}

pub fn disconnectReason(value: wire.DisconnectReason) i32 {
    return switch (value) {
        .closed => 1,
        .protocol => 2,
        .policy => 3,
        .timeout => 4,
        .capacity => 5,
        .application => 6,
    };
}

pub fn disconnectReasonIn(code: i32) ?wire.DisconnectReason {
    return switch (code) {
        1 => .closed,
        2 => .protocol,
        3 => .policy,
        4 => .timeout,
        5 => .capacity,
        6 => .application,
        else => null,
    };
}

pub fn refusalReason(value: wire.RefusalReason) i32 {
    return switch (value) {
        .generic => 1,
        .version => 2,
        .application => 3,
        .compatibility => 4,
        .catalogue => 5,
        .channel => 6,
        .capacity => 7,
        .policy => 8,
        .timeout => 9,
    };
}

pub fn deadline(value: svc.Deadline) i32 {
    return switch (value) {
        .admission => 1,
        .initial_sync => 2,
        .no_progress => 3,
        .write_stall => 4,
    };
}

pub fn fault(value: svc.Fault) i32 {
    return switch (value) {
        .malformed => 1,
        .unexpected => 2,
        .sequence => 3,
        .truncated => 4,
        .mismatch => 5,
    };
}

/// Written out rather than `@intFromEnum + 1`: the platform's enum may gain or reorder a
/// category, and a compiled consumer's numbers may not move with it.
pub fn failure(value: transport.Failure) i32 {
    return switch (value) {
        .refused => 1,
        .unreachable_address => 2,
        .timed_out => 3,
        .reset => 4,
        .closed_early => 5,
        .truncated => 6,
        .network_down => 7,
        .carrier => 8,
        .certificate_missing => 9,
        .certificate_untrusted => 10,
        .certificate_expired => 11,
        .certificate_not_yet_valid => 12,
        .certificate_wrong_usage => 13,
        .certificate_wrong_name => 14,
        .certificate_rejected => 15,
        .certificate_chain_too_long => 16,
        .server_key_mismatch => 17,
        .peer_refused => 18,
        .protocol => 19,
        .handshake_budget => 20,
        .tls_memory => 21,
        .clock_unavailable => 22,
        .internal => 23,
    };
}

pub fn ending(value: svc.Ending) Ending {
    return switch (value) {
        .local => |reason| .{ .kind = ending_local, .code = disconnectReason(reason) },
        .peer_disconnected => |reason| .{ .kind = ending_peer_disconnected, .code = disconnectReason(reason) },
        .peer_closed => .{ .kind = ending_peer_closed },
        .refused => |refusal| .{ .kind = ending_refused, .code = refusalReason(refusal.reason), .index = refusal.detail_index },
        .refused_by_peer => |refusal| .{ .kind = ending_refused_by_peer, .code = refusalReason(refusal.reason), .index = refusal.detail_index },
        .revoked => .{ .kind = ending_revoked },
        .rotated => .{ .kind = ending_rotated },
        .timed_out => |which| .{ .kind = ending_timed_out, .code = deadline(which) },
        .protocol => |which| .{ .kind = ending_protocol, .code = fault(which) },
        .transport => |which| .{ .kind = ending_transport, .code = failure(which) },
        .overloaded => .{ .kind = ending_overloaded },
    };
}

// -- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "the networking values are the shapes the header states" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Endpoint));
    try testing.expectEqual(@as(usize, 24), @sizeOf(GrantInfo));
    try testing.expectEqual(@as(usize, 24), @sizeOf(ChannelDesc));
    try testing.expectEqual(@as(usize, 40), @sizeOf(SessionInfo));
    try testing.expectEqual(@as(usize, 24), @sizeOf(PeerInfo));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Ending));
    try testing.expectEqual(@as(usize, 48), @sizeOf(Event));
    try testing.expectEqual(@as(usize, 32), @sizeOf(Delivery));
    try testing.expectEqual(@as(usize, 32), @sizeOf(Command));
    try testing.expectEqual(@as(usize, 184), @sizeOf(Stats));
}

test "every category has its own number, and an unknown number is refused" {
    var seen: [32]bool = @splat(false);
    for (std.enums.values(transport.Failure)) |value| {
        const code: usize = @intCast(failure(value));
        try testing.expect(code >= 1 and !seen[code]);
        seen[code] = true;
    }
    for ([_]i32{ 0, 4, -1, std.math.maxInt(i32) }) |code| try testing.expectEqual(@as(?net.channel.Direction, null), directionIn(code));
    for ([_]i32{ 0, 3, -1 }) |code| try testing.expectEqual(@as(?net.channel.Delivery, null), deliveryIn(code));
    for ([_]i32{ 0, 7, -6 }) |code| try testing.expectEqual(@as(?wire.DisconnectReason, null), disconnectReasonIn(code));
    for (std.enums.values(wire.DisconnectReason)) |value| try testing.expectEqual(value, disconnectReasonIn(disconnectReason(value)).?);
}
