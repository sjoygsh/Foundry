//! FNET wire protocol version 1 (`networking.md` §5, M16 Step 1).
//!
//! Every integer is explicit little-endian; no Zig or C layout crosses the
//! boundary. TLS authenticates and protects these bytes in Step 2. This codec
//! remains a pure bounded parser and treats every byte as hostile.

const std = @import("std");
const core = @import("core");
const channel = @import("channel.zig");
const limits_mod = @import("limits.zig");

pub const magic = "FNET";
pub const protocol_version: u16 = 1;
pub const header_size: usize = limits_mod.frame_header_bytes;
pub const no_channel: u64 = 0;

pub const Kind = enum(u16) {
    client_hello = 1,
    server_hello = 2,
    compatibility_item = 3,
    channel_descriptor = 4,
    negotiation_finished = 5,
    refusal = 6,
    baseline = 7,
    baseline_ack = 8,
    active = 9,
    command = 10,
    state = 11,
    heartbeat = 12,
    disconnect = 13,
};

pub const Header = struct {
    kind: Kind,
    total_bytes: u32,
    sequence: u64,
    channel_id: u64 = no_channel,
    tick: u64 = 0,
};

pub const Frame = struct {
    header: Header,
    payload: []const u8,
};

pub const Error = error{
    BufferTooSmall,
    BadMagic,
    UnsupportedVersion,
    UnknownKind,
    UnsupportedFlags,
    FrameTooSmall,
    FrameTooLarge,
    InvalidSequence,
    InvalidChannel,
    InvalidTick,
    WrongPayloadSize,
    InvalidReserved,
    InvalidEnum,
    InvalidId,
    InvalidCount,
    InvalidValue,
    FramePending,
    TruncatedFrame,
    SequenceExhausted,
};

pub fn encodeHeader(out: []u8, header: Header, max_frame_bytes: u32) Error!void {
    if (out.len < header_size) return error.BufferTooSmall;
    try validateHeader(header, max_frame_bytes);
    @memcpy(out[0..4], magic);
    writeInt(u16, out[4..6], protocol_version);
    writeInt(u16, out[6..8], @intFromEnum(header.kind));
    writeInt(u32, out[8..12], header.total_bytes);
    writeInt(u32, out[12..16], 0); // wire-v1 flags are all reserved
    writeInt(u64, out[16..24], header.sequence);
    writeInt(u64, out[24..32], header.channel_id);
    writeInt(u64, out[32..40], header.tick);
}

pub fn decodeHeader(bytes: []const u8, max_frame_bytes: u32) Error!Header {
    if (bytes.len < header_size) return error.BufferTooSmall;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    if (readInt(u16, bytes[4..6]) != protocol_version) return error.UnsupportedVersion;
    const kind = std.enums.fromInt(Kind, readInt(u16, bytes[6..8])) orelse
        return error.UnknownKind;
    if (readInt(u32, bytes[12..16]) != 0) return error.UnsupportedFlags;
    const header: Header = .{
        .kind = kind,
        .total_bytes = readInt(u32, bytes[8..12]),
        .sequence = readInt(u64, bytes[16..24]),
        .channel_id = readInt(u64, bytes[24..32]),
        .tick = readInt(u64, bytes[32..40]),
    };
    try validateHeader(header, max_frame_bytes);
    return header;
}

pub fn encodeFrame(out: []u8, header: Header, payload: []const u8, max_frame_bytes: u32) Error![]u8 {
    const total = header_size + payload.len;
    if (total > std.math.maxInt(u32)) return error.FrameTooLarge;
    var checked = header;
    checked.total_bytes = @intCast(total);
    if (out.len < total) return error.BufferTooSmall;
    try encodeHeader(out[0..header_size], checked, max_frame_bytes);
    @memcpy(out[header_size..total], payload);
    return out[0..total];
}

fn validateHeader(header: Header, max_frame_bytes: u32) Error!void {
    if (max_frame_bytes < header_size) return error.FrameTooSmall;
    if (max_frame_bytes > limits_mod.wire_v1_max_frame_bytes) return error.FrameTooLarge;
    if (header.total_bytes < header_size) return error.FrameTooSmall;
    if (header.total_bytes > max_frame_bytes) return error.FrameTooLarge;
    if (header.sequence == 0) return error.InvalidSequence;

    switch (header.kind) {
        .baseline, .state => {
            if (header.channel_id == no_channel) return error.InvalidChannel;
        },
        .command => {
            if (header.channel_id == no_channel) return error.InvalidChannel;
            if (header.tick != 0) return error.InvalidTick;
        },
        else => {
            if (header.channel_id != no_channel) return error.InvalidChannel;
            if (header.tick != 0) return error.InvalidTick;
        },
    }
}

pub fn nextSequence(current: u64) Error!u64 {
    if (current == std.math.maxInt(u64)) return error.SequenceExhausted;
    return current + 1;
}

/// A decoder owns no allocation. `frame.payload` borrows `storage` until the
/// caller calls `consumeFrame`; while it is borrowed, another feed is refused.
pub const Decoder = struct {
    storage: []u8,
    filled: usize = 0,
    expected: usize = 0,
    ready: bool = false,
    max_frame_bytes: u32,

    pub const Progress = struct {
        consumed: usize,
        frame: ?Frame,
    };

    pub fn init(storage: []u8, max_frame_bytes: u32) Error!Decoder {
        if (max_frame_bytes < header_size) return error.FrameTooSmall;
        if (max_frame_bytes > limits_mod.wire_v1_max_frame_bytes) return error.FrameTooLarge;
        if (storage.len < max_frame_bytes) return error.BufferTooSmall;
        return .{ .storage = storage, .max_frame_bytes = max_frame_bytes };
    }

    pub fn feed(self: *Decoder, input: []const u8) Error!Progress {
        if (self.ready) return error.FramePending;
        var consumed: usize = 0;

        if (self.filled < header_size) {
            const count = @min(header_size - self.filled, input.len);
            @memcpy(self.storage[self.filled..][0..count], input[0..count]);
            self.filled += count;
            consumed += count;
            if (self.filled < header_size) return .{ .consumed = consumed, .frame = null };
            const header = try decodeHeader(self.storage[0..header_size], self.max_frame_bytes);
            self.expected = header.total_bytes;
        }

        if (self.filled < self.expected) {
            const count = @min(self.expected - self.filled, input.len - consumed);
            @memcpy(self.storage[self.filled..][0..count], input[consumed..][0..count]);
            self.filled += count;
            consumed += count;
        }
        if (self.filled < self.expected) return .{ .consumed = consumed, .frame = null };

        const header = try decodeHeader(self.storage[0..header_size], self.max_frame_bytes);
        self.ready = true;
        return .{
            .consumed = consumed,
            .frame = .{ .header = header, .payload = self.storage[header_size..self.expected] },
        };
    }

    pub fn consumeFrame(self: *Decoder) void {
        std.debug.assert(self.ready);
        self.filled = 0;
        self.expected = 0;
        self.ready = false;
    }

    /// Call when the authenticated stream reaches EOF. A complete borrowed
    /// frame remains valid; any other buffered bytes are a protocol error.
    pub fn finish(self: *const Decoder) Error!void {
        if (!self.ready and self.filled != 0) return error.TruncatedFrame;
    }
};

pub const ClientHello = struct {
    pub const encoded_size = 56;
    application_id: core.ContentId,
    application_revision: u32,
    tick_rate_millihertz: u32,
    compatibility_id: [32]u8,
    catalogue_count: u16,
    channel_count: u16,

    pub fn encode(self: ClientHello, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        try self.validate();
        writeInt(u64, out[0..8], self.application_id.hash);
        writeInt(u32, out[8..12], self.application_revision);
        writeInt(u32, out[12..16], self.tick_rate_millihertz);
        @memcpy(out[16..48], &self.compatibility_id);
        writeInt(u16, out[48..50], self.catalogue_count);
        writeInt(u16, out[50..52], self.channel_count);
        writeInt(u32, out[52..56], 0);
    }

    pub fn decode(bytes: []const u8) Error!ClientHello {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        if (readInt(u32, bytes[52..56]) != 0) return error.InvalidReserved;
        var value: ClientHello = .{
            .application_id = .{ .hash = readInt(u64, bytes[0..8]) },
            .application_revision = readInt(u32, bytes[8..12]),
            .tick_rate_millihertz = readInt(u32, bytes[12..16]),
            .compatibility_id = undefined,
            .catalogue_count = readInt(u16, bytes[48..50]),
            .channel_count = readInt(u16, bytes[50..52]),
        };
        @memcpy(&value.compatibility_id, bytes[16..48]);
        try value.validate();
        return value;
    }

    fn validate(self: ClientHello) Error!void {
        if (self.application_id.isNone() or self.application_revision == 0) return error.InvalidId;
        if (self.catalogue_count > 256 or self.channel_count == 0 or self.channel_count > 256) {
            return error.InvalidCount;
        }
        if (self.tick_rate_millihertz == 0 or self.tick_rate_millihertz > 1_000_000) {
            return error.InvalidValue;
        }
    }
};

pub const ServerHello = struct {
    pub const encoded_size = 72;
    application_id: core.ContentId,
    application_revision: u32,
    tick_rate_millihertz: u32,
    compatibility_id: [32]u8,
    session_epoch: u64,
    participant_number: u32,
    catalogue_count: u16,
    channel_count: u16,
    peer_limit: u16,

    pub fn encode(self: ServerHello, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        try self.validate();
        writeInt(u64, out[0..8], self.application_id.hash);
        writeInt(u32, out[8..12], self.application_revision);
        writeInt(u32, out[12..16], self.tick_rate_millihertz);
        @memcpy(out[16..48], &self.compatibility_id);
        writeInt(u64, out[48..56], self.session_epoch);
        writeInt(u32, out[56..60], self.participant_number);
        writeInt(u16, out[60..62], self.catalogue_count);
        writeInt(u16, out[62..64], self.channel_count);
        writeInt(u16, out[64..66], self.peer_limit);
        @memset(out[66..72], 0);
    }

    pub fn decode(bytes: []const u8) Error!ServerHello {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        if (!allZero(bytes[66..72])) return error.InvalidReserved;
        var value: ServerHello = .{
            .application_id = .{ .hash = readInt(u64, bytes[0..8]) },
            .application_revision = readInt(u32, bytes[8..12]),
            .tick_rate_millihertz = readInt(u32, bytes[12..16]),
            .compatibility_id = undefined,
            .session_epoch = readInt(u64, bytes[48..56]),
            .participant_number = readInt(u32, bytes[56..60]),
            .catalogue_count = readInt(u16, bytes[60..62]),
            .channel_count = readInt(u16, bytes[62..64]),
            .peer_limit = readInt(u16, bytes[64..66]),
        };
        @memcpy(&value.compatibility_id, bytes[16..48]);
        try value.validate();
        return value;
    }

    fn validate(self: ServerHello) Error!void {
        if (self.application_id.isNone() or self.application_revision == 0 or
            self.session_epoch == 0 or self.participant_number == 0)
        {
            return error.InvalidId;
        }
        if (self.catalogue_count > 256 or self.channel_count == 0 or
            self.channel_count > 256 or self.peer_limit == 0 or self.peer_limit > 256)
        {
            return error.InvalidCount;
        }
        if (self.tick_rate_millihertz == 0 or self.tick_rate_millihertz > 1_000_000) {
            return error.InvalidValue;
        }
    }
};

pub const CompatibilityKind = enum(u8) {
    package = 1,
    gameplay_asset = 2,
    native_code = 3,
    script_code = 4,
};

pub const CompatibilityItem = struct {
    pub const encoded_size = 64;
    kind: CompatibilityKind,
    id: core.ContentId,
    version_major: u32,
    version_minor: u32,
    version_patch: u32,
    byte_count: u64,
    digest: [32]u8,

    pub fn encode(self: CompatibilityItem, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        if (self.id.isNone()) return error.InvalidId;
        out[0] = @intFromEnum(self.kind);
        @memset(out[1..4], 0);
        writeInt(u64, out[4..12], self.id.hash);
        writeInt(u32, out[12..16], self.version_major);
        writeInt(u32, out[16..20], self.version_minor);
        writeInt(u32, out[20..24], self.version_patch);
        writeInt(u64, out[24..32], self.byte_count);
        @memcpy(out[32..64], &self.digest);
    }

    pub fn decode(bytes: []const u8) Error!CompatibilityItem {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        if (!allZero(bytes[1..4])) return error.InvalidReserved;
        const kind = std.enums.fromInt(CompatibilityKind, bytes[0]) orelse
            return error.InvalidEnum;
        var value: CompatibilityItem = .{
            .kind = kind,
            .id = .{ .hash = readInt(u64, bytes[4..12]) },
            .version_major = readInt(u32, bytes[12..16]),
            .version_minor = readInt(u32, bytes[16..20]),
            .version_patch = readInt(u32, bytes[20..24]),
            .byte_count = readInt(u64, bytes[24..32]),
            .digest = undefined,
        };
        if (value.id.isNone()) return error.InvalidId;
        @memcpy(&value.digest, bytes[32..64]);
        return value;
    }
};

pub const ChannelPayload = struct {
    pub const encoded_size = 24;

    pub fn encode(descriptor: channel.Descriptor, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        descriptor.validate(.{}) catch return error.InvalidValue;
        writeInt(u64, out[0..8], descriptor.id.hash);
        writeInt(u32, out[8..12], descriptor.revision);
        writeInt(u32, out[12..16], descriptor.max_payload_bytes);
        out[16] = @intFromEnum(descriptor.direction);
        out[17] = @intFromEnum(descriptor.delivery);
        @memset(out[18..24], 0);
    }

    pub fn decode(bytes: []const u8) Error!channel.Descriptor {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        if (!allZero(bytes[18..24])) return error.InvalidReserved;
        const descriptor: channel.Descriptor = .{
            .id = .{ .hash = readInt(u64, bytes[0..8]) },
            .revision = readInt(u32, bytes[8..12]),
            .max_payload_bytes = readInt(u32, bytes[12..16]),
            .direction = std.enums.fromInt(channel.Direction, bytes[16]) orelse
                return error.InvalidEnum,
            .delivery = std.enums.fromInt(channel.Delivery, bytes[17]) orelse
                return error.InvalidEnum,
        };
        descriptor.validate(.{}) catch return error.InvalidValue;
        return descriptor;
    }
};

pub const NegotiationFinished = struct {
    pub const encoded_size = 64;
    catalogue_digest: [32]u8,
    channel_digest: [32]u8,

    pub fn encode(self: NegotiationFinished, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        @memcpy(out[0..32], &self.catalogue_digest);
        @memcpy(out[32..64], &self.channel_digest);
    }

    pub fn decode(bytes: []const u8) Error!NegotiationFinished {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        var value: NegotiationFinished = undefined;
        @memcpy(&value.catalogue_digest, bytes[0..32]);
        @memcpy(&value.channel_digest, bytes[32..64]);
        return value;
    }
};

pub const RefusalReason = enum(u16) {
    generic = 1,
    version = 2,
    application = 3,
    compatibility = 4,
    catalogue = 5,
    channel = 6,
    capacity = 7,
    policy = 8,
    timeout = 9,
};

pub const Refusal = struct {
    pub const encoded_size = 8;
    reason: RefusalReason,
    detail_index: u16 = std.math.maxInt(u16),

    pub fn encode(self: Refusal, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        writeInt(u16, out[0..2], @intFromEnum(self.reason));
        writeInt(u16, out[2..4], self.detail_index);
        writeInt(u32, out[4..8], 0);
    }

    pub fn decode(bytes: []const u8) Error!Refusal {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        if (readInt(u32, bytes[4..8]) != 0) return error.InvalidReserved;
        return .{
            .reason = std.enums.fromInt(RefusalReason, readInt(u16, bytes[0..2])) orelse
                return error.InvalidEnum,
            .detail_index = readInt(u16, bytes[2..4]),
        };
    }
};

pub const BaselineAck = struct {
    pub const encoded_size = 24;
    session_epoch: u64,
    baseline_sequence: u64,
    baseline_tick: u64,

    pub fn encode(self: BaselineAck, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        if (self.session_epoch == 0 or self.baseline_sequence == 0) return error.InvalidValue;
        writeInt(u64, out[0..8], self.session_epoch);
        writeInt(u64, out[8..16], self.baseline_sequence);
        writeInt(u64, out[16..24], self.baseline_tick);
    }

    pub fn decode(bytes: []const u8) Error!BaselineAck {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        const value: BaselineAck = .{
            .session_epoch = readInt(u64, bytes[0..8]),
            .baseline_sequence = readInt(u64, bytes[8..16]),
            .baseline_tick = readInt(u64, bytes[16..24]),
        };
        if (value.session_epoch == 0 or value.baseline_sequence == 0) return error.InvalidValue;
        return value;
    }
};

pub const Active = struct {
    pub const encoded_size = 16;
    session_epoch: u64,
    participant_number: u32,

    pub fn encode(self: Active, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        if (self.session_epoch == 0 or self.participant_number == 0) return error.InvalidValue;
        writeInt(u64, out[0..8], self.session_epoch);
        writeInt(u32, out[8..12], self.participant_number);
        writeInt(u32, out[12..16], 0);
    }

    pub fn decode(bytes: []const u8) Error!Active {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        if (readInt(u32, bytes[12..16]) != 0) return error.InvalidReserved;
        const value: Active = .{
            .session_epoch = readInt(u64, bytes[0..8]),
            .participant_number = readInt(u32, bytes[8..12]),
        };
        if (value.session_epoch == 0 or value.participant_number == 0) return error.InvalidValue;
        return value;
    }
};

pub const Heartbeat = struct {
    pub const encoded_size = 16;
    session_epoch: u64,
    last_received_sequence: u64,

    pub fn encode(self: Heartbeat, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        if (self.session_epoch == 0) return error.InvalidValue;
        writeInt(u64, out[0..8], self.session_epoch);
        writeInt(u64, out[8..16], self.last_received_sequence);
    }

    pub fn decode(bytes: []const u8) Error!Heartbeat {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        const value: Heartbeat = .{
            .session_epoch = readInt(u64, bytes[0..8]),
            .last_received_sequence = readInt(u64, bytes[8..16]),
        };
        if (value.session_epoch == 0) return error.InvalidValue;
        return value;
    }
};

pub const DisconnectReason = enum(u16) {
    closed = 1,
    protocol = 2,
    policy = 3,
    timeout = 4,
    capacity = 5,
    application = 6,
};

pub const Disconnect = struct {
    pub const encoded_size = 8;
    reason: DisconnectReason,

    pub fn encode(self: Disconnect, out: []u8) Error!void {
        if (out.len < encoded_size) return error.BufferTooSmall;
        writeInt(u16, out[0..2], @intFromEnum(self.reason));
        @memset(out[2..8], 0);
    }

    pub fn decode(bytes: []const u8) Error!Disconnect {
        if (bytes.len != encoded_size) return error.WrongPayloadSize;
        if (!allZero(bytes[2..8])) return error.InvalidReserved;
        return .{
            .reason = std.enums.fromInt(DisconnectReason, readInt(u16, bytes[0..2])) orelse
                return error.InvalidEnum,
        };
    }
};

fn writeInt(comptime T: type, out: []u8, value: T) void {
    std.mem.writeInt(T, out[0..@sizeOf(T)], value, .little);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

test "wire-v1 header has pinned golden bytes" {
    var bytes: [header_size]u8 = undefined;
    try encodeHeader(&bytes, .{
        .kind = .state,
        .total_bytes = header_size + 3,
        .sequence = 0x0102030405060708,
        .channel_id = 0x1112131415161718,
        .tick = 0x2122232425262728,
    }, limits_mod.wire_v1_max_frame_bytes);

    const expected = [_]u8{
        'F',  'N',  'E',  'T',  1,    0,    11,   0,    43,   0,    0,    0,    0,    0,    0,    0,
        8,    7,    6,    5,    4,    3,    2,    1,    0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21,
    };
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
    const decoded = try decodeHeader(&bytes, limits_mod.wire_v1_max_frame_bytes);
    try std.testing.expectEqual(Kind.state, decoded.kind);
    try std.testing.expectEqual(@as(u64, 0x1112131415161718), decoded.channel_id);

    const kinds = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
    inline for (std.meta.fields(Kind), kinds) |field, number| {
        try std.testing.expectEqual(number, @intFromEnum(@field(Kind, field.name)));
    }
}

test "every truncated header and invalid structural field is refused" {
    var bytes: [header_size]u8 = undefined;
    try encodeHeader(&bytes, .{
        .kind = .heartbeat,
        .total_bytes = header_size,
        .sequence = 1,
    }, limits_mod.wire_v1_max_frame_bytes);
    for (0..header_size) |length| {
        try std.testing.expectError(
            error.BufferTooSmall,
            decodeHeader(bytes[0..length], limits_mod.wire_v1_max_frame_bytes),
        );
    }

    var changed = bytes;
    changed[0] = 'X';
    try std.testing.expectError(error.BadMagic, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));
    changed = bytes;
    changed[4] = 2;
    try std.testing.expectError(error.UnsupportedVersion, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));
    changed = bytes;
    changed[6] = 99;
    try std.testing.expectError(error.UnknownKind, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));
    changed = bytes;
    changed[12] = 1;
    try std.testing.expectError(error.UnsupportedFlags, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));
    changed = bytes;
    @memset(changed[16..24], 0);
    try std.testing.expectError(error.InvalidSequence, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));

    changed = bytes;
    writeInt(u32, changed[8..12], header_size - 1);
    try std.testing.expectError(error.FrameTooSmall, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));
    changed = bytes;
    writeInt(u32, changed[8..12], limits_mod.wire_v1_max_frame_bytes + 1);
    try std.testing.expectError(error.FrameTooLarge, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));
    changed = bytes;
    writeInt(u32, changed[8..12], limits_mod.wire_v1_max_frame_bytes);
    try std.testing.expectEqual(
        limits_mod.wire_v1_max_frame_bytes,
        (try decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes)).total_bytes,
    );
    try std.testing.expectError(error.FrameTooSmall, decodeHeader(&bytes, header_size - 1));
    try std.testing.expectError(
        error.FrameTooLarge,
        decodeHeader(&bytes, limits_mod.wire_v1_max_frame_bytes + 1),
    );

    changed = bytes;
    writeInt(u16, changed[6..8], @intFromEnum(Kind.state));
    try std.testing.expectError(error.InvalidChannel, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));
    changed = bytes;
    writeInt(u64, changed[24..32], 1);
    try std.testing.expectError(error.InvalidChannel, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));
    changed = bytes;
    writeInt(u16, changed[6..8], @intFromEnum(Kind.command));
    writeInt(u64, changed[24..32], 1);
    writeInt(u64, changed[32..40], 1);
    try std.testing.expectError(error.InvalidTick, decodeHeader(&changed, limits_mod.wire_v1_max_frame_bytes));
}

test "incremental decoder handles every split and leaves coalesced bytes to the caller" {
    const payload = "three";
    var encoded: [header_size + payload.len]u8 = undefined;
    const frame = try encodeFrame(&encoded, .{
        .kind = .command,
        .total_bytes = 0,
        .sequence = 7,
        .channel_id = core.ContentId.fromString("test:commands").hash,
    }, payload, limits_mod.wire_v1_max_frame_bytes);

    for (0..frame.len + 1) |split| {
        var storage: [limits_mod.wire_v1_max_frame_bytes]u8 = undefined;
        var decoder = try Decoder.init(&storage, limits_mod.wire_v1_max_frame_bytes);
        const first = try decoder.feed(frame[0..split]);
        try std.testing.expectEqual(split, first.consumed);
        const decoded = if (split == frame.len)
            first.frame orelse return error.TestUnexpectedResult
        else block: {
            try std.testing.expect(first.frame == null);
            const second = try decoder.feed(frame[split..]);
            break :block second.frame orelse return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualSlices(u8, payload, decoded.payload);
    }

    var two: [encoded.len * 2]u8 = undefined;
    @memcpy(two[0..encoded.len], &encoded);
    @memcpy(two[encoded.len..], &encoded);
    var storage: [limits_mod.wire_v1_max_frame_bytes]u8 = undefined;
    var decoder = try Decoder.init(&storage, limits_mod.wire_v1_max_frame_bytes);
    const first = try decoder.feed(&two);
    try std.testing.expectEqual(encoded.len, first.consumed);
    try std.testing.expect(first.frame != null);
    try std.testing.expectError(error.FramePending, decoder.feed(two[first.consumed..]));
    decoder.consumeFrame();
    const second = try decoder.feed(two[first.consumed..]);
    try std.testing.expect(second.frame != null);
}

test "incremental decoder refuses every truncated EOF and checked storage bound" {
    const payload = "bounded";
    var encoded: [header_size + payload.len]u8 = undefined;
    const frame = try encodeFrame(&encoded, .{
        .kind = .command,
        .total_bytes = 0,
        .sequence = 1,
        .channel_id = 1,
    }, payload, limits_mod.wire_v1_max_frame_bytes);

    for (1..frame.len) |length| {
        var storage: [limits_mod.wire_v1_max_frame_bytes]u8 = undefined;
        var decoder = try Decoder.init(&storage, limits_mod.wire_v1_max_frame_bytes);
        _ = try decoder.feed(frame[0..length]);
        try std.testing.expectError(error.TruncatedFrame, decoder.finish());
    }

    var small: [header_size - 1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, Decoder.init(&small, header_size));
}

test "wire-v1 control payloads have pinned golden bytes" {
    const client_hello: ClientHello = .{
        .application_id = .{ .hash = 0x0102030405060708 },
        .application_revision = 7,
        .tick_rate_millihertz = 60_000,
        .compatibility_id = [_]u8{0xaa} ** 32,
        .catalogue_count = 2,
        .channel_count = 3,
    };
    var client_hello_bytes: [ClientHello.encoded_size]u8 = undefined;
    try client_hello.encode(&client_hello_bytes);
    const client_hello_golden = [_]u8{
        8,    7,    6,    5,    4,    3,    2,    1,    7,    0,    0,    0,    0x60, 0xea,
        0,    0,    0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 2,    0,    3,    0,    0,    0,    0,    0,
    };
    try std.testing.expectEqualSlices(u8, &client_hello_golden, &client_hello_bytes);
    try std.testing.expectEqualDeep(client_hello, try ClientHello.decode(&client_hello_bytes));

    const server_hello: ServerHello = .{
        .application_id = .{ .hash = 0x0102030405060708 },
        .application_revision = 7,
        .tick_rate_millihertz = 60_000,
        .compatibility_id = [_]u8{0xbb} ** 32,
        .session_epoch = 0x1112131415161718,
        .participant_number = 4,
        .catalogue_count = 2,
        .channel_count = 3,
        .peer_limit = 4,
    };
    var server_hello_bytes: [ServerHello.encoded_size]u8 = undefined;
    try server_hello.encode(&server_hello_bytes);
    const server_hello_golden = [_]u8{
        8,    7,    6,    5,    4,    3,    2,    1,    7,    0,    0,    0,    0x60, 0xea,
        0,    0,    0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb,
        0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb,
        0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        4,    0,    0,    0,    2,    0,    3,    0,    4,    0,    0,    0,    0,    0,
        0,    0,
    };
    try std.testing.expectEqualSlices(u8, &server_hello_golden, &server_hello_bytes);
    try std.testing.expectEqualDeep(server_hello, try ServerHello.decode(&server_hello_bytes));

    const compatibility: CompatibilityItem = .{
        .kind = .gameplay_asset,
        .id = .{ .hash = 0x0102030405060708 },
        .version_major = 1,
        .version_minor = 2,
        .version_patch = 3,
        .byte_count = 0x1112131415161718,
        .digest = [_]u8{0xcc} ** 32,
    };
    var compatibility_bytes: [CompatibilityItem.encoded_size]u8 = undefined;
    try compatibility.encode(&compatibility_bytes);
    const compatibility_golden = [_]u8{
        2,    0,    0,    0,    8,    7,    6,    5,    4,    3,    2,    1,    1,    0,
        0,    0,    2,    0,    0,    0,    3,    0,    0,    0,    0x18, 0x17, 0x16, 0x15,
        0x14, 0x13, 0x12, 0x11, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc,
        0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc,
        0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc,
    };
    try std.testing.expectEqualSlices(u8, &compatibility_golden, &compatibility_bytes);
    try std.testing.expectEqualDeep(compatibility, try CompatibilityItem.decode(&compatibility_bytes));

    const descriptor: channel.Descriptor = .{
        .id = .{ .hash = 0x0102030405060708 },
        .revision = 3,
        .max_payload_bytes = 1024,
        .direction = .server_to_client,
        .delivery = .latest_complete_state,
    };
    var channel_bytes: [ChannelPayload.encoded_size]u8 = undefined;
    try ChannelPayload.encode(descriptor, &channel_bytes);
    const channel_golden = [_]u8{
        8, 7, 6, 5, 4, 3, 2, 1, 3, 0, 0, 0, 0, 4, 0, 0, 2, 2, 0, 0, 0, 0, 0, 0,
    };
    try std.testing.expectEqualSlices(u8, &channel_golden, &channel_bytes);
    try std.testing.expectEqualDeep(descriptor, try ChannelPayload.decode(&channel_bytes));

    const finished: NegotiationFinished = .{
        .catalogue_digest = [_]u8{0xdd} ** 32,
        .channel_digest = [_]u8{0xee} ** 32,
    };
    var finished_bytes: [NegotiationFinished.encoded_size]u8 = undefined;
    try finished.encode(&finished_bytes);
    const finished_golden = [_]u8{0xdd} ** 32 ++ [_]u8{0xee} ** 32;
    try std.testing.expectEqualSlices(u8, &finished_golden, &finished_bytes);
    try std.testing.expectEqualDeep(finished, try NegotiationFinished.decode(&finished_bytes));

    var refusal_bytes: [Refusal.encoded_size]u8 = undefined;
    try (Refusal{ .reason = .compatibility, .detail_index = 7 }).encode(&refusal_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 7, 0, 0, 0, 0, 0 }, &refusal_bytes);

    const ack: BaselineAck = .{ .session_epoch = 8, .baseline_sequence = 9, .baseline_tick = 10 };
    var ack_bytes: [BaselineAck.encoded_size]u8 = undefined;
    try ack.encode(&ack_bytes);
    try std.testing.expectEqualSlices(u8, &.{
        8, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0,
    }, &ack_bytes);
    try std.testing.expectEqualDeep(ack, try BaselineAck.decode(&ack_bytes));

    const active: Active = .{ .session_epoch = 8, .participant_number = 2 };
    var active_bytes: [Active.encoded_size]u8 = undefined;
    try active.encode(&active_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0 }, &active_bytes);
    try std.testing.expectEqualDeep(active, try Active.decode(&active_bytes));

    const heartbeat: Heartbeat = .{ .session_epoch = 8, .last_received_sequence = 90 };
    var heartbeat_bytes: [Heartbeat.encoded_size]u8 = undefined;
    try heartbeat.encode(&heartbeat_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 8, 0, 0, 0, 0, 0, 0, 0, 90, 0, 0, 0, 0, 0, 0, 0 }, &heartbeat_bytes);
    try std.testing.expectEqualDeep(heartbeat, try Heartbeat.decode(&heartbeat_bytes));

    var disconnect_bytes: [Disconnect.encoded_size]u8 = undefined;
    try (Disconnect{ .reason = .timeout }).encode(&disconnect_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 0, 0, 0, 0, 0, 0 }, &disconnect_bytes);
}

test "control payloads reject wrong sizes, unknown values and reserved bytes" {
    var client_bytes = [_]u8{0} ** ClientHello.encoded_size;
    try std.testing.expectError(error.WrongPayloadSize, ClientHello.decode(client_bytes[0 .. client_bytes.len - 1]));
    writeInt(u64, client_bytes[0..8], 1);
    writeInt(u32, client_bytes[8..12], 1);
    writeInt(u32, client_bytes[12..16], 60_000);
    writeInt(u16, client_bytes[50..52], 1);
    client_bytes[52] = 1;
    try std.testing.expectError(error.InvalidReserved, ClientHello.decode(&client_bytes));

    var compatibility_bytes = [_]u8{0} ** CompatibilityItem.encoded_size;
    compatibility_bytes[0] = 255;
    writeInt(u64, compatibility_bytes[4..12], 1);
    try std.testing.expectError(error.InvalidEnum, CompatibilityItem.decode(&compatibility_bytes));

    var channel_bytes = [_]u8{0} ** ChannelPayload.encoded_size;
    writeInt(u64, channel_bytes[0..8], 1);
    writeInt(u32, channel_bytes[8..12], 1);
    writeInt(u32, channel_bytes[12..16], 1);
    channel_bytes[16] = 255;
    channel_bytes[17] = @intFromEnum(channel.Delivery.reliable_ordered);
    try std.testing.expectError(error.InvalidEnum, ChannelPayload.decode(&channel_bytes));

    var refusal_bytes = [_]u8{0} ** Refusal.encoded_size;
    writeInt(u16, refusal_bytes[0..2], 255);
    try std.testing.expectError(error.InvalidEnum, Refusal.decode(&refusal_bytes));
    refusal_bytes = [_]u8{0} ** Refusal.encoded_size;
    writeInt(u16, refusal_bytes[0..2], @intFromEnum(RefusalReason.generic));
    refusal_bytes[7] = 1;
    try std.testing.expectError(error.InvalidReserved, Refusal.decode(&refusal_bytes));

    var disconnect_bytes = [_]u8{0} ** Disconnect.encoded_size;
    writeInt(u16, disconnect_bytes[0..2], 255);
    try std.testing.expectError(error.InvalidEnum, Disconnect.decode(&disconnect_bytes));
}

test "random hostile headers never allocate or escape validation" {
    var state: u64 = 0x9e3779b97f4a7c15;
    var bytes: [header_size]u8 = undefined;
    for (0..4096) |_| {
        for (&bytes) |*byte| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(state >> 32);
        }
        _ = decodeHeader(&bytes, limits_mod.wire_v1_max_frame_bytes) catch continue;
    }
}

test "sequence counters refuse wrap" {
    try std.testing.expectEqual(@as(u64, 1), try nextSequence(0));
    try std.testing.expectError(error.SequenceExhausted, nextSequence(std.math.maxInt(u64)));
}
