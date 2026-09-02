//! Content identity: stable, namespaced, never derived from load order (I2, ADR-0005).
//!
//! Content is named `namespace:name` — `foundry:item.torch` — and hashed to a stable
//! 64-bit value. The hash reaches compiled content and save files, so **this algorithm
//! can never change**. It is specified here rather than delegated to `std`, because
//! `std` is not a stability contract in a pre-1.0 language: a rename or re-specification
//! there would silently invalidate every save. The pinned test vectors below turn that
//! into a failing test instead.
//!
//! See `docs/design/core-memory-and-handles.md` §3.

const std = @import("std");

/// FNV-1a, 64-bit. Specified in full so an external mod tool can reproduce it exactly:
///
///     offset basis = 0xcbf29ce484222325
///     prime        = 0x00000100000001b3
///     for each byte b:  hash ^= b;  hash *= prime   (mod 2^64)
pub fn fnv1a64(bytes: []const u8) u64 {
    const offset_basis: u64 = 0xcbf29ce484222325;
    const prime: u64 = 0x00000100000001b3;

    var hash: u64 = offset_basis;
    for (bytes) |b| {
        hash ^= b;
        hash = hash *% prime;
    }
    return hash;
}

/// A hashed `namespace:name` content identifier.
///
/// `extern struct` because content IDs cross the public C ABI at M7 (ADR-0004), which
/// makes their representation a compatibility decision rather than an implementation
/// detail.
pub const ContentId = extern struct {
    hash: u64 = 0,

    /// The absence of an ID. Hash 0 is reserved: the content compiler rejects any
    /// string that hashes to it, so `none` can never collide with real content.
    pub const none: ContentId = .{ .hash = 0 };

    /// Hashes the exact UTF-8 bytes of the full `namespace:name` string, including the
    /// colon, with no normalisation — no case folding, no trimming, no Unicode
    /// normalisation. Normalisation would be a second specification every modding tool
    /// would have to reimplement identically, and any divergence would produce IDs that
    /// differ invisibly. Shape validation belongs to `data`, not here.
    pub fn fromString(s: []const u8) ContentId {
        return .{ .hash = fnv1a64(s) };
    }

    pub fn isNone(self: ContentId) bool {
        return self.hash == 0;
    }

    pub fn eql(a: ContentId, b: ContentId) bool {
        return a.hash == b.hash;
    }

    pub fn format(self: ContentId, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.isNone()) return writer.writeAll("content(none)");
        try writer.print("content(0x{x:0>16})", .{self.hash});
    }
};

test "fnv1a64 pinned vectors" {
    // These values are the specification. If this test fails after a Zig upgrade,
    // `std` moved under us or the implementation was changed — either way, every
    // compiled content file and save that already exists would be invalidated.
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a64(""));
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fnv1a64("a"));
    try std.testing.expectEqual(@as(u64, 0x85944171f73967e8), fnv1a64("foobar"));
    try std.testing.expectEqual(@as(u64, 0x6194c021015aae87), fnv1a64("foundry:item.torch"));
    try std.testing.expectEqual(@as(u64, 0xe6c9a3c91df32f3f), fnv1a64("foundry:core"));
}

test "fnv1a64 agrees with std's implementation" {
    // Cross-check, not a definition. std may rename or remove this; the vectors above
    // are what actually binds us.
    try std.testing.expectEqual(std.hash.Fnv1a_64.hash("foundry:item.torch"), fnv1a64("foundry:item.torch"));
}

test "ContentId identity" {
    const a = ContentId.fromString("foundry:item.torch");
    const b = ContentId.fromString("foundry:item.torch");
    const c = ContentId.fromString("foundry:item.lantern");

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.isNone());
    try std.testing.expect(ContentId.none.isNone());
}

test "ContentId is case sensitive and unnormalised" {
    try std.testing.expect(!ContentId.fromString("foundry:Torch").eql(ContentId.fromString("foundry:torch")));
    try std.testing.expect(!ContentId.fromString(" foundry:torch").eql(ContentId.fromString("foundry:torch")));
}

test "a zeroed ContentId is none" {
    const zeroed: ContentId = .{};
    try std.testing.expect(zeroed.isNone());
}
