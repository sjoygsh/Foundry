//! Runtime-registered application channels. Names are stable content IDs; the
//! engine assigns no meaning to their payload bytes (ADR-0044).

const std = @import("std");
const core = @import("core");
const limits_mod = @import("limits.zig");

pub const Direction = enum(u8) {
    client_to_server = 1,
    server_to_client = 2,
    bidirectional = 3,
};

pub const Delivery = enum(u8) {
    reliable_ordered = 1,
    latest_complete_state = 2,
};

pub const Descriptor = struct {
    id: core.ContentId,
    revision: u32,
    max_payload_bytes: u32,
    direction: Direction,
    delivery: Delivery,

    pub fn validate(self: Descriptor, limits: limits_mod.Limits) Error!void {
        try limits.validate();
        if (self.id.isNone() or self.revision == 0 or self.max_payload_bytes == 0) {
            return error.InvalidDescriptor;
        }
        if (self.max_payload_bytes > limits.frame_bytes - limits_mod.frame_header_bytes) {
            return error.PayloadTooLarge;
        }
        if (self.delivery == .latest_complete_state and self.direction != .server_to_client) {
            return error.InvalidStateChannel;
        }
    }
};

pub const Error = limits_mod.Error || error{
    InvalidDescriptor,
    PayloadTooLarge,
    TooManyChannels,
    DuplicateChannel,
    TooManyStateChannels,
    InvalidStateChannel,
};

pub fn validateSet(descriptors: []const Descriptor, limits: limits_mod.Limits) Error!void {
    try limits.validate();
    if (descriptors.len > limits.channels) return error.TooManyChannels;
    var state_channels: usize = 0;
    for (descriptors, 0..) |descriptor, index| {
        try descriptor.validate(limits);
        if (descriptor.delivery == .latest_complete_state) state_channels += 1;
        for (descriptors[0..index]) |earlier| {
            if (earlier.id.eql(descriptor.id)) return error.DuplicateChannel;
        }
    }
    if (state_channels > limits.full_state_channels) return error.TooManyStateChannels;
}

test "channel sets are runtime-named, unique and bounded" {
    const limits: limits_mod.Limits = .{};
    const channels = [_]Descriptor{
        .{
            .id = core.ContentId.fromString("test:commands"),
            .revision = 1,
            .max_payload_bytes = 128,
            .direction = .client_to_server,
            .delivery = .reliable_ordered,
        },
        .{
            .id = core.ContentId.fromString("test:state"),
            .revision = 2,
            .max_payload_bytes = 1024,
            .direction = .server_to_client,
            .delivery = .latest_complete_state,
        },
    };
    try validateSet(&channels, limits);

    const duplicate = [_]Descriptor{ channels[0], channels[0] };
    try std.testing.expectError(error.DuplicateChannel, validateSet(&duplicate, limits));
}

test "replaceable state is server to client only" {
    const invalid: Descriptor = .{
        .id = core.ContentId.fromString("test:state"),
        .revision = 1,
        .max_payload_bytes = 32,
        .direction = .bidirectional,
        .delivery = .latest_complete_state,
    };
    try std.testing.expectError(error.InvalidStateChannel, invalid.validate(.{}));
}

test "channel payload and set counts cannot exceed checked limits" {
    const descriptor: Descriptor = .{
        .id = core.ContentId.fromString("test:commands"),
        .revision = 1,
        .max_payload_bytes = limits_mod.wire_v1_max_frame_bytes,
        .direction = .client_to_server,
        .delivery = .reliable_ordered,
    };
    try std.testing.expectError(error.PayloadTooLarge, descriptor.validate(.{}));

    var invalid_limits: limits_mod.Limits = .{};
    invalid_limits.frame_bytes = 0;
    try std.testing.expectError(error.ZeroLimit, descriptor.validate(invalid_limits));

    const too_many = [_]Descriptor{.{
        .id = core.ContentId.fromString("test:commands"),
        .revision = 1,
        .max_payload_bytes = 1,
        .direction = .client_to_server,
        .delivery = .reliable_ordered,
    }} ** 33;
    var limits: limits_mod.Limits = .{};
    limits.channels = 32;
    try std.testing.expectError(error.TooManyChannels, validateSet(&too_many, limits));
}
