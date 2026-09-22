//! What two peers compare before either sees an application byte (`networking.md` §5,
//! M16 Step 3).
//!
//! The host describes its application and the content it runs — the ordered packages,
//! with the size and SHA-256 of their compiled bytes, and the external inputs a
//! simulation depends on — and `freeze` copies that into the wire's own entries, in a
//! canonical order, bounded and free of duplicates. `net` never reads a file or hashes
//! a package itself: the host hashes the confined bytes it actually loads, and a digest
//! here is compatibility evidence, never trust.
//!
//! Channels are frozen the same way, per session, when it starts (`freezeChannels`).

const std = @import("std");
const core = @import("core");
const channel = @import("channel.zig");
const limits_mod = @import("limits.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Wire-v1 hellos count at most this many catalogue entries.
pub const max_catalogue_items = 256;

pub const Version = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
};

/// A simulation-relevant input outside the package bytes themselves.
pub const InputKind = enum {
    gameplay_asset,
    native_code,
    script_code,

    fn wireKind(self: InputKind) wire.CompatibilityKind {
        return switch (self) {
            .gameplay_asset => .gameplay_asset,
            .native_code => .native_code,
            .script_code => .script_code,
        };
    }
};

pub const Input = struct {
    kind: InputKind,
    /// The namespaced content ID of the input's normalized package-relative identity.
    /// Never an absolute path, a handle or a load-order position.
    id: core.ContentId,
    byte_count: u64,
    sha256: [32]u8,
};

pub const Package = struct {
    id: core.ContentId,
    version: Version,
    /// Size and SHA-256 of the compiled `.fpk`, taken from the bytes the host loads.
    byte_count: u64,
    sha256: [32]u8,
    /// The package's external inputs, in any order: freezing sorts them.
    inputs: []const Input = &.{},
};

pub const Description = struct {
    application: core.ContentId,
    application_revision: u32,
    tick_rate_millihertz: u32,
    /// Host-declared: what native code or anything else the catalogue cannot prove
    /// alike is attested to be (`networking.md` §5).
    compatibility_id: [32]u8,
    /// In load order, which is part of what is compared.
    packages: []const Package = &.{},
};

pub const Error = error{
    InvalidApplication,
    InvalidTickRate,
    InvalidItem,
    DuplicateItem,
    TooManyItems,
    OutOfMemory,
} || limits_mod.Error;

/// A description as the wire carries it: owned, canonical and immutable.
pub const Frozen = struct {
    application: core.ContentId,
    application_revision: u32,
    tick_rate_millihertz: u32,
    compatibility_id: [32]u8,
    items: []const wire.CompatibilityItem,
    digest: [32]u8,

    pub fn deinit(self: *Frozen, gpa: Allocator) void {
        gpa.free(self.items);
        self.* = undefined;
    }

    /// Bytes the negotiation a client sends for this description occupies, with
    /// `channel_count` channels: its hello, every entry and its finish.
    pub fn negotiationBytes(self: *const Frozen, channel_count: usize) usize {
        return (wire.header_size + wire.ClientHello.encoded_size) +
            self.items.len * (wire.header_size + wire.CompatibilityItem.encoded_size) +
            channel_count * (wire.header_size + wire.ChannelPayload.encoded_size) +
            (wire.header_size + wire.NegotiationFinished.encoded_size);
    }
};

/// Copies `description` into its wire entries: each package in load order, then that
/// package's inputs by kind and then ID, so two hosts listing the same inputs in a
/// different order agree. Refuses an empty ID, a duplicate ID anywhere in the
/// catalogue, and more entries or bytes than `limits` or the wire allow.
pub fn freeze(gpa: Allocator, description: Description, limits: limits_mod.Limits) Error!Frozen {
    try limits.validate();
    if (description.application.isNone() or description.application_revision == 0) {
        return error.InvalidApplication;
    }
    if (description.tick_rate_millihertz == 0 or description.tick_rate_millihertz > 1_000_000) {
        return error.InvalidTickRate;
    }

    var count: usize = 0;
    for (description.packages) |package| count += 1 + package.inputs.len;
    const cap = @min(limits.compatibility_items, max_catalogue_items);
    if (count > cap or count * wire.CompatibilityItem.encoded_size > limits.compatibility_bytes) {
        return error.TooManyItems;
    }

    const items = try gpa.alloc(wire.CompatibilityItem, count);
    errdefer gpa.free(items);
    var at: usize = 0;
    for (description.packages) |package| {
        if (package.id.isNone()) return error.InvalidItem;
        items[at] = .{
            .kind = .package,
            .id = package.id,
            .version_major = package.version.major,
            .version_minor = package.version.minor,
            .version_patch = package.version.patch,
            .byte_count = package.byte_count,
            .digest = package.sha256,
        };
        at += 1;
        const first_input = at;
        for (package.inputs) |input| {
            if (input.id.isNone()) return error.InvalidItem;
            // An input has no version of its own: its bytes are its identity.
            items[at] = .{
                .kind = input.kind.wireKind(),
                .id = input.id,
                .version_major = 0,
                .version_minor = 0,
                .version_patch = 0,
                .byte_count = input.byte_count,
                .digest = input.sha256,
            };
            at += 1;
        }
        std.mem.sort(wire.CompatibilityItem, items[first_input..at], {}, inputLessThan);
    }

    for (items, 0..) |item, index| {
        for (items[0..index]) |earlier| {
            if (earlier.id.eql(item.id)) return error.DuplicateItem;
        }
    }

    return .{
        .application = description.application,
        .application_revision = description.application_revision,
        .tick_rate_millihertz = description.tick_rate_millihertz,
        .compatibility_id = description.compatibility_id,
        .items = items,
        .digest = catalogueDigest(items),
    };
}

fn inputLessThan(_: void, a: wire.CompatibilityItem, b: wire.CompatibilityItem) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return a.id.hash < b.id.hash;
}

/// SHA-256 over the catalogue's encoded 64-byte entries, in order.
pub fn catalogueDigest(items: []const wire.CompatibilityItem) [32]u8 {
    var hash = Sha256.init(.{});
    var bytes: [wire.CompatibilityItem.encoded_size]u8 = undefined;
    for (items) |item| {
        // Every entry here was built from a validated description.
        item.encode(&bytes) catch unreachable;
        hash.update(&bytes);
    }
    return hash.finalResult();
}

pub fn itemsEqual(a: wire.CompatibilityItem, b: wire.CompatibilityItem) bool {
    return a.kind == b.kind and a.id.eql(b.id) and a.version_major == b.version_major and
        a.version_minor == b.version_minor and a.version_patch == b.version_patch and
        a.byte_count == b.byte_count and std.mem.eql(u8, &a.digest, &b.digest);
}

/// Puts a session's channels in their canonical order — by ID — and returns the SHA-256
/// over their encoded 24-byte descriptors. Registration order is not part of the
/// contract, so two hosts registering the same channels differently still agree.
pub fn freezeChannels(descriptors: []channel.Descriptor) [32]u8 {
    std.mem.sort(channel.Descriptor, descriptors, {}, channelLessThan);
    var hash = Sha256.init(.{});
    var bytes: [wire.ChannelPayload.encoded_size]u8 = undefined;
    for (descriptors) |descriptor| {
        // Every descriptor here was validated when it was registered.
        wire.ChannelPayload.encode(descriptor, &bytes) catch unreachable;
        hash.update(&bytes);
    }
    return hash.finalResult();
}

fn channelLessThan(_: void, a: channel.Descriptor, b: channel.Descriptor) bool {
    return a.id.hash < b.id.hash;
}

pub fn channelsEqual(a: channel.Descriptor, b: channel.Descriptor) bool {
    return a.id.eql(b.id) and a.revision == b.revision and
        a.max_payload_bytes == b.max_payload_bytes and a.direction == b.direction and
        a.delivery == b.delivery;
}

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;

fn digestOf(byte: u8) [32]u8 {
    return @splat(byte);
}

test "a description freezes into canonical, bounded wire entries" {
    const inputs = [_]Input{
        .{ .kind = .script_code, .id = core.ContentId.fromString("test:scripts/b.lua"), .byte_count = 3, .sha256 = digestOf(3) },
        .{ .kind = .gameplay_asset, .id = core.ContentId.fromString("test:rules.fdt"), .byte_count = 1, .sha256 = digestOf(1) },
        .{ .kind = .script_code, .id = core.ContentId.fromString("test:scripts/a.lua"), .byte_count = 2, .sha256 = digestOf(2) },
    };
    const reordered = [_]Input{ inputs[2], inputs[0], inputs[1] };
    const packages = [_]Package{
        .{ .id = core.ContentId.fromString("test:base"), .version = .{ .major = 1, .minor = 2 }, .byte_count = 100, .sha256 = digestOf(9), .inputs = &inputs },
        .{ .id = core.ContentId.fromString("test:extra"), .version = .{ .major = 3 }, .byte_count = 50, .sha256 = digestOf(8) },
    };
    const description: Description = .{
        .application = core.ContentId.fromString("test:app"),
        .application_revision = 1,
        .tick_rate_millihertz = 60_000,
        .compatibility_id = digestOf(0xaa),
        .packages = &packages,
    };
    var frozen = try freeze(testing.allocator, description, .{});
    defer frozen.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), frozen.items.len);
    try testing.expectEqual(wire.CompatibilityKind.package, frozen.items[0].kind);
    try testing.expect(frozen.items[0].id.eql(packages[0].id));
    try testing.expectEqual(@as(u32, 2), frozen.items[0].version_minor);
    try testing.expectEqual(wire.CompatibilityKind.gameplay_asset, frozen.items[1].kind);
    try testing.expectEqual(wire.CompatibilityKind.script_code, frozen.items[2].kind);
    try testing.expect(frozen.items[2].id.hash < frozen.items[3].id.hash);
    try testing.expectEqual(@as(u32, 0), frozen.items[2].version_major);
    try testing.expect(frozen.items[4].id.eql(packages[1].id));

    // The same inputs listed differently freeze to the same catalogue.
    var other_packages = packages;
    other_packages[0].inputs = &reordered;
    var other_description = description;
    other_description.packages = &other_packages;
    var same = try freeze(testing.allocator, other_description, .{});
    defer same.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &frozen.digest, &same.digest);

    // Package order is load order, and is compared.
    const swapped = [_]Package{ packages[1], packages[0] };
    other_description.packages = &swapped;
    var moved = try freeze(testing.allocator, other_description, .{});
    defer moved.deinit(testing.allocator);
    try testing.expect(!std.mem.eql(u8, &frozen.digest, &moved.digest));

    try testing.expectEqual(
        (40 + 56) + 5 * (40 + 64) + 2 * (40 + 24) + (40 + 64),
        frozen.negotiationBytes(2),
    );
}

test "a description with a hole, a duplicate or too much in it is refused whole" {
    const good: Description = .{
        .application = core.ContentId.fromString("test:app"),
        .application_revision = 1,
        .tick_rate_millihertz = 60_000,
        .compatibility_id = digestOf(0),
    };
    var bad = good;
    bad.application = .{};
    try testing.expectError(error.InvalidApplication, freeze(testing.allocator, bad, .{}));
    bad = good;
    bad.application_revision = 0;
    try testing.expectError(error.InvalidApplication, freeze(testing.allocator, bad, .{}));
    bad = good;
    bad.tick_rate_millihertz = 1_000_001;
    try testing.expectError(error.InvalidTickRate, freeze(testing.allocator, bad, .{}));

    const clash = [_]Input{.{ .kind = .gameplay_asset, .id = core.ContentId.fromString("test:base"), .byte_count = 1, .sha256 = digestOf(1) }};
    const duplicate = [_]Package{.{ .id = core.ContentId.fromString("test:base"), .version = .{}, .byte_count = 1, .sha256 = digestOf(0), .inputs = &clash }};
    bad = good;
    bad.packages = &duplicate;
    try testing.expectError(error.DuplicateItem, freeze(testing.allocator, bad, .{}));

    const empty_id = [_]Package{.{ .id = .{}, .version = .{}, .byte_count = 1, .sha256 = digestOf(0) }};
    bad.packages = &empty_id;
    try testing.expectError(error.InvalidItem, freeze(testing.allocator, bad, .{}));

    var many: [max_catalogue_items + 1]Package = undefined;
    var names: [max_catalogue_items + 1][16]u8 = undefined;
    for (&many, &names, 0..) |*package, *name, index| {
        const text = try std.fmt.bufPrint(name, "test:p{d}", .{index});
        package.* = .{ .id = core.ContentId.fromString(text), .version = .{}, .byte_count = 1, .sha256 = digestOf(0) };
    }
    bad.packages = &many;
    try testing.expectError(error.TooManyItems, freeze(testing.allocator, bad, .{}));
    bad.packages = many[0..3];
    var tight: limits_mod.Limits = .{};
    tight.compatibility_items = 2;
    try testing.expectError(error.TooManyItems, freeze(testing.allocator, bad, tight));
    tight = .{};
    tight.compatibility_bytes = 2 * wire.CompatibilityItem.encoded_size;
    try testing.expectError(error.TooManyItems, freeze(testing.allocator, bad, tight));
    var frozen = try freeze(testing.allocator, bad, .{});
    frozen.deinit(testing.allocator);
}

test "channels freeze in ID order, whatever order they were registered in" {
    var first = [_]channel.Descriptor{
        .{ .id = core.ContentId.fromString("test:state"), .revision = 1, .max_payload_bytes = 1024, .direction = .server_to_client, .delivery = .latest_complete_state },
        .{ .id = core.ContentId.fromString("test:commands"), .revision = 2, .max_payload_bytes = 64, .direction = .client_to_server, .delivery = .reliable_ordered },
    };
    var second = [_]channel.Descriptor{ first[1], first[0] };
    const a = freezeChannels(&first);
    const b = freezeChannels(&second);
    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expect(first[0].id.hash < first[1].id.hash);
    try testing.expect(channelsEqual(first[0], second[0]));

    second[1].revision += 1;
    try testing.expect(!channelsEqual(first[1], second[1]));
    try testing.expect(!std.mem.eql(u8, &a, &freezeChannels(&second)));
}
