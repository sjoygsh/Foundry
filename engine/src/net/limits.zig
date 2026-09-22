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
            self.no_progress_timeout_ms == 0 or self.identities == 0 or self.close_linger_ms == 0)
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
            self.identities > 4096 or self.close_linger_ms > self.no_progress_timeout_ms)
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
