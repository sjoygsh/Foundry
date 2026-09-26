//! Checked host limits for M16 networking (`networking.md` §4).

const std = @import("std");

pub const frame_header_bytes: u32 = 40;
pub const wire_v1_max_frame_bytes: u32 = 64 * 1024;

pub const Error = error{
    ZeroLimit,
    LimitTooLarge,
    FrameTooSmall,
    QueueCannotHoldFrame,
    TooManyFullStateChannels,
    AggregateOverflow,
};

/// Defaults are the accepted M16 reference envelope. A host may lower them;
/// raising a wire or structural bound requires a later protocol revision.
pub const Limits = struct {
    sessions: u16 = 1,
    peers_per_session: u16 = 4,
    pending_handshakes: u16 = 8,
    handshake_starts_per_second: u16 = 8,
    handshake_start_burst: u16 = 8,
    handshake_starts_per_source_per_second: u16 = 2,
    handshake_start_per_source_burst: u16 = 2,
    source_limiter_entries: u16 = 256,
    tls_allocation_bytes: u64 = 16 * 1024 * 1024,
    tls_handshake_calls_per_peer_per_pump: u8 = 1,
    tls_handshake_call_limit: u16 = 64,
    certificate_chain_count: u16 = 4,
    certificate_chain_bytes: u32 = 32 * 1024,
    compatibility_items: u16 = 256,
    compatibility_bytes: u32 = 16 * 1024,
    channels: u16 = 32,
    full_state_channels: u16 = 1,
    frame_bytes: u32 = wire_v1_max_frame_bytes,
    receive_bytes_per_peer: u32 = 256 * 1024,
    send_bytes_per_peer: u32 = 256 * 1024,
    queued_events: u16 = 256,
    /// Copied payload bytes a service holds outside connection storage: one server
    /// session's admitted command batch (Step 4).
    queued_event_payload_bytes: u32 = 1024 * 1024,
    pump_bytes_per_direction_per_peer: u32 = 64 * 1024,
    pump_frames_per_peer: u16 = 32,
    admission_timeout_ms: u32 = 5_000,
    initial_sync_timeout_ms: u32 = 5_000,
    no_progress_timeout_ms: u32 = 10_000,
    /// Admitted client identities a server's allowlist can hold (Step 3).
    identities: u16 = 256,
    /// How long a connection this side ended keeps reading and flushing, so its last
    /// refusal or disconnect is delivered rather than lost to a reset (Step 3).
    close_linger_ms: u32 = 1_000,
    /// Commands one peer may have admitted into one server tick's batch. What exceeds it
    /// waits, in order, in the peer's bounded inbox for a later tick (Step 4).
    commands_per_peer_per_tick: u16 = 16,

    /// The reference limits with one session resized for `peers` players, and the storage
    /// that follows from that count grown to match. Never smaller than the defaults.
    ///
    /// Taken from the first game's server, which ran 256 players this way: each connection,
    /// admitted or pending, reserves three events (`service.zig`), and holds about 96 KiB of
    /// TLS provider memory. The reference 16 MiB is sized for four.
    ///
    /// **Not raised: the per-source handshake rate.** Many handshakes from one address look
    /// like a flood because they usually are one. A host that expects players behind one
    /// address, or runs a load test from one machine, raises
    /// `handshake_starts_per_source_per_second` and its burst itself, knowing why. The
    /// allowlist is the host's too: `identities` must hold every `allow` line, which may be
    /// more than the players at once.
    pub fn forPeers(peers: u16) Limits {
        var limits: Limits = .{};
        limits.peers_per_session = peers;
        limits.identities = @max(limits.identities, peers);
        const connections: u32 = @as(u32, peers) + limits.pending_handshakes;
        limits.queued_events = @intCast(@max(limits.queued_events, 3 * connections + 64));
        limits.tls_allocation_bytes = @max(limits.tls_allocation_bytes, @as(u64, connections) * 96 * 1024);
        return limits;
    }

    pub fn validate(self: Limits) Error!void {
        if (self.sessions == 0 or self.peers_per_session == 0 or
            self.pending_handshakes == 0 or self.handshake_starts_per_second == 0 or
            self.handshake_start_burst == 0 or
            self.handshake_starts_per_source_per_second == 0 or
            self.handshake_start_per_source_burst == 0 or self.source_limiter_entries == 0 or
            self.tls_allocation_bytes == 0 or self.tls_handshake_calls_per_peer_per_pump == 0 or
            self.tls_handshake_call_limit == 0 or
            self.certificate_chain_count == 0 or self.certificate_chain_bytes == 0 or
            self.compatibility_items == 0 or self.compatibility_bytes == 0 or
            self.channels == 0 or self.frame_bytes == 0 or
            self.receive_bytes_per_peer == 0 or self.send_bytes_per_peer == 0 or
            self.queued_events == 0 or self.queued_event_payload_bytes == 0 or
            self.pump_bytes_per_direction_per_peer == 0 or self.pump_frames_per_peer == 0 or
            self.admission_timeout_ms == 0 or self.initial_sync_timeout_ms == 0 or
            self.no_progress_timeout_ms == 0 or self.identities == 0 or self.close_linger_ms == 0 or
            self.commands_per_peer_per_tick == 0)
        {
            return error.ZeroLimit;
        }
        if (self.sessions > 64 or self.peers_per_session > 256 or
            self.pending_handshakes > 256 or self.handshake_starts_per_second > 1024 or
            self.handshake_start_burst > 1024 or self.source_limiter_entries > 4096 or
            self.tls_handshake_calls_per_peer_per_pump > 16 or
            self.tls_handshake_call_limit > 4096 or self.certificate_chain_count > 16 or
            self.certificate_chain_bytes > 1024 * 1024 or self.compatibility_items > 1024 or
            self.compatibility_bytes > 16 * 1024 * 1024 or self.channels > 256 or
            self.queued_events > 4096 or self.pump_frames_per_peer > 1024 or
            self.identities > 4096 or self.close_linger_ms > self.no_progress_timeout_ms or
            self.commands_per_peer_per_tick > 1024)
        {
            return error.LimitTooLarge;
        }
        if (self.handshake_starts_per_source_per_second > self.handshake_starts_per_second or
            self.handshake_start_per_source_burst > self.handshake_start_burst)
        {
            return error.LimitTooLarge;
        }
        if (self.full_state_channels > 1) return error.TooManyFullStateChannels;
        if (self.frame_bytes < frame_header_bytes) return error.FrameTooSmall;
        if (self.frame_bytes > wire_v1_max_frame_bytes) return error.LimitTooLarge;
        if (self.receive_bytes_per_peer < self.frame_bytes or
            self.send_bytes_per_peer < self.frame_bytes)
        {
            return error.QueueCannotHoldFrame;
        }

        const peer_count = checkedMul(self.sessions, self.peers_per_session) orelse
            return error.AggregateOverflow;
        _ = checkedMul(peer_count, self.receive_bytes_per_peer) orelse
            return error.AggregateOverflow;
        _ = checkedMul(peer_count, self.send_bytes_per_peer) orelse
            return error.AggregateOverflow;
        _ = checkedMul(self.queued_events, self.frame_bytes) orelse
            return error.AggregateOverflow;
    }
};

fn checkedMul(a: anytype, b: anytype) ?u64 {
    const lhs: u64 = @intCast(a);
    const rhs: u64 = @intCast(b);
    if (lhs != 0 and rhs > std.math.maxInt(u64) / lhs) return null;
    return lhs * rhs;
}

test "reference limits are valid and preserve the wire cap" {
    const limits: Limits = .{};
    try limits.validate();
    try std.testing.expectEqual(@as(u32, 64 * 1024), limits.frame_bytes);
}

test "every required limit rejects zero" {
    inline for (std.meta.fields(Limits)) |field| {
        if (!std.mem.eql(u8, field.name, "full_state_channels")) {
            var limits: Limits = .{};
            @field(limits, field.name) = 0;
            try std.testing.expectError(error.ZeroLimit, limits.validate());
        }
    }
}

test "limits reject structural excess and inconsistent storage" {
    var limits: Limits = .{};
    limits.frame_bytes += 1;
    try std.testing.expectError(error.LimitTooLarge, limits.validate());

    limits = .{};
    limits.receive_bytes_per_peer = limits.frame_bytes - 1;
    try std.testing.expectError(error.QueueCannotHoldFrame, limits.validate());

    limits = .{};
    limits.full_state_channels = 2;
    try std.testing.expectError(error.TooManyFullStateChannels, limits.validate());

    limits = .{};
    limits.handshake_starts_per_source_per_second = limits.handshake_starts_per_second + 1;
    try std.testing.expectError(error.LimitTooLarge, limits.validate());

    try std.testing.expect(checkedMul(std.math.maxInt(u64), 2) == null);
}

test "limits for many peers grow what follows from the count, and stay valid" {
    try std.testing.expectEqual(Limits{}, Limits.forPeers(4));
    for ([_]u16{ 1, 4, 16, 64, 255, 256 }) |peers| {
        const limits = Limits.forPeers(peers);
        try limits.validate();
        try std.testing.expectEqual(peers, limits.peers_per_session);
        // Every connection, admitted or pending, can reserve its three events.
        try std.testing.expect(limits.queued_events >= 3 * (@as(u32, peers) + limits.pending_handshakes));
        try std.testing.expect(limits.identities >= peers);
    }
    const large = Limits.forPeers(256);
    try std.testing.expect(large.tls_allocation_bytes > (Limits{}).tls_allocation_bytes);
    // A flood from one address is still a flood.
    try std.testing.expectEqual((Limits{}).handshake_starts_per_source_per_second, large.handshake_starts_per_source_per_second);
}
