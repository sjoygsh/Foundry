//! What a content identifier is allowed to look like, and the separate space schema
//! identifiers live in.
//!
//! `core/id.zig` owns the hash and **refuses to normalise**: it hashes the exact UTF-8
//! bytes, with no case folding, no trimming and no Unicode normalisation, because a
//! normalisation rule would be a second specification every external mod tool has to
//! reimplement identically — and any divergence produces IDs that differ invisibly.
//!
//! This file is the other half of that decision. **`core` refuses to normalise, so `data`
//! refuses to accept anything that would need normalising.** `Foundry:Torch` is not a
//! differently-cased spelling of `foundry:torch`; it is not an identifier at all, and it
//! is rejected where it is written, with a reason. The trap that case-sensitive hashing
//! would otherwise set is removed without either half having to guess at the other's
//! intent.
//!
//! See `docs/design/content-schemas.md` §2.

const std = @import("std");
const core = @import("core");

/// The longest an identifier may be, in bytes, including the colon.
///
/// Identifiers reach compiled packages, save files and diagnostics. A bound here means
/// every one of those can size a buffer without asking, and it costs nothing real: an
/// identifier a human cannot read in one glance has already failed at its job.
pub const max_bytes: usize = 255;

/// Why a string is not an identifier.
///
/// Each case names something an author can act on without reading the spec, because these
/// reach mod authors through diagnostics and "invalid identifier" helps nobody.
pub const Error = error{
    /// The empty string.
    EmptyId,
    /// Longer than `max_bytes`.
    IdTooLong,
    /// No `:` at all — `item.torch` rather than `foundry:item.torch`.
    MissingNamespace,
    /// More than one `:`.
    MultipleColons,
    /// Nothing before the colon.
    EmptyNamespace,
    /// Nothing after the colon.
    EmptyName,
    /// A `..`, or a leading or trailing `.` in the name.
    EmptySegment,
    /// A segment beginning with a digit or an underscore.
    SegmentMustStartWithLetter,
    /// Anything outside `[a-z0-9_]` — which includes every uppercase letter, and that is
    /// the case worth having its own message.
    UppercaseNotAllowed,
    /// Anything else outside the permitted set: punctuation, spaces, non-ASCII.
    InvalidCharacter,
    /// The string is well-formed but hashes to zero, which `ContentId.none` reserves for
    /// the absence of an identifier. Content may not collide with absence.
    ///
    /// Astronomically unlikely and checked anyway, because the alternative to checking is
    /// a piece of content that exists and can never be found.
    ReservedHash,
};

/// Validates the `namespace:name` shape.
///
///     id        := namespace ":" name
///     namespace := [a-z] [a-z0-9_]*
///     name      := segment ("." segment)*
///     segment   := [a-z] [a-z0-9_]*
pub fn validate(s: []const u8) Error!void {
    if (s.len == 0) return error.EmptyId;
    if (s.len > max_bytes) return error.IdTooLong;

    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.MissingNamespace;
    if (std.mem.indexOfScalarPos(u8, s, colon + 1, ':') != null) return error.MultipleColons;

    const namespace = s[0..colon];
    const name = s[colon + 1 ..];
    if (namespace.len == 0) return error.EmptyNamespace;
    if (name.len == 0) return error.EmptyName;

    try validateSegment(namespace);

    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |segment| try validateSegment(segment);
}

fn validateSegment(segment: []const u8) Error!void {
    if (segment.len == 0) return error.EmptySegment;

    for (segment, 0..) |c, i| {
        switch (c) {
            'a'...'z' => {},
            '0'...'9', '_' => if (i == 0) return error.SegmentMustStartWithLetter,
            'A'...'Z' => return error.UppercaseNotAllowed,
            else => return error.InvalidCharacter,
        }
    }
}

/// Whether a single segment — a field name, a type name, an attribute — is well-formed.
///
/// Field names use the same character set as identifier segments, deliberately: one rule
/// to learn and one to implement rather than two that are nearly the same.
pub fn isValidSegment(segment: []const u8) bool {
    validateSegment(segment) catch return false;
    return true;
}

/// Validates, then hashes. The only way `data` produces a `ContentId` from text.
pub fn contentId(s: []const u8) Error!core.ContentId {
    try validate(s);
    const id = core.ContentId.fromString(s);
    if (id.isNone()) return error.ReservedHash;
    return id;
}

/// A hashed schema identifier.
///
/// **A distinct type from `ContentId`, deliberately.** Schemas and content occupy separate
/// identifier spaces (`content-schemas.md` §2), so the schema `foundry:item` and a record
/// named `foundry:item` can coexist without either shadowing the other. Making that a Zig
/// type difference rather than a convention means the most confusable pair of values in
/// the whole content system cannot be swapped by accident — including at the C ABI, which
/// is why this is `extern struct`.
///
/// The hash is `core.id.fnv1a64`, the same function and the same pinned specification.
/// Two spaces, one algorithm: there is nothing extra for an external tool to reimplement.
pub const SchemaId = extern struct {
    hash: u64 = 0,

    pub const none: SchemaId = .{ .hash = 0 };

    /// Validates, then hashes.
    pub fn parse(s: []const u8) Error!SchemaId {
        try validate(s);
        const id: SchemaId = .{ .hash = core.id.fnv1a64(s) };
        if (id.isNone()) return error.ReservedHash;
        return id;
    }

    /// Hashes without validating. For test fixtures and for reading a compiled package,
    /// where validation already happened at the point the string existed.
    pub fn fromStringUnchecked(s: []const u8) SchemaId {
        return .{ .hash = core.id.fnv1a64(s) };
    }

    pub fn isNone(self: SchemaId) bool {
        return self.hash == 0;
    }

    pub fn eql(a: SchemaId, b: SchemaId) bool {
        return a.hash == b.hash;
    }

    pub fn format(self: SchemaId, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.isNone()) return writer.writeAll("schema(none)");
        try writer.print("schema(0x{x:0>16})", .{self.hash});
    }
};

const testing = std.testing;

test "the shape a valid identifier has" {
    try validate("foundry:item.torch");
    try validate("foundry:core");
    try validate("a:b");
    try validate("my_mod:item.light.torch_2");
    try validate("mod2:x9_");
}

test "an identifier that would need normalising is refused, not normalised" {
    // The whole point of this file. `core` hashes exact bytes, so if these were accepted
    // they would be four different pieces of content that look like one.
    try testing.expectError(error.UppercaseNotAllowed, validate("Foundry:torch"));
    try testing.expectError(error.UppercaseNotAllowed, validate("foundry:Torch"));
    try testing.expectError(error.InvalidCharacter, validate(" foundry:torch"));
    try testing.expectError(error.InvalidCharacter, validate("foundry:torch "));
}

test "each way of being malformed has its own reason" {
    // These strings reach mod authors as diagnostics, so the distinctions are the feature.
    try testing.expectError(error.EmptyId, validate(""));
    try testing.expectError(error.MissingNamespace, validate("item.torch"));
    try testing.expectError(error.MultipleColons, validate("foundry:item:torch"));
    try testing.expectError(error.EmptyNamespace, validate(":torch"));
    try testing.expectError(error.EmptyName, validate("foundry:"));
    try testing.expectError(error.EmptySegment, validate("foundry:item..torch"));
    try testing.expectError(error.EmptySegment, validate("foundry:.torch"));
    try testing.expectError(error.EmptySegment, validate("foundry:torch."));
    try testing.expectError(error.SegmentMustStartWithLetter, validate("foundry:2torch"));
    try testing.expectError(error.SegmentMustStartWithLetter, validate("foundry:_torch"));
    try testing.expectError(error.SegmentMustStartWithLetter, validate("2foundry:torch"));
    try testing.expectError(error.InvalidCharacter, validate("foundry:item-torch"));
    try testing.expectError(error.InvalidCharacter, validate("foundry:item/torch"));
    try testing.expectError(error.InvalidCharacter, validate("foundry:tørch"));
}

test "length is bounded, at the boundary" {
    var buf: [max_bytes + 1]u8 = undefined;
    @memcpy(buf[0..2], "a:");
    @memset(buf[2..], 'b');

    try validate(buf[0..max_bytes]);
    try testing.expectError(error.IdTooLong, validate(buf[0 .. max_bytes + 1]));
}

test "a validated identifier hashes exactly as core says it does" {
    // No transformation happens between validation and hashing. If one were ever added,
    // this test is what fails.
    const id = try contentId("foundry:item.torch");
    try testing.expectEqual(@as(u64, 0x6194c021015aae87), id.hash);
    try testing.expect(id.eql(core.ContentId.fromString("foundry:item.torch")));
}

test "schema identifiers and content identifiers are different types over one algorithm" {
    const schema = try SchemaId.parse("foundry:item");
    const content = try contentId("foundry:item");

    // Same string, same hash — and the type system still will not let one be used where
    // the other belongs, which is the point of the separation.
    try testing.expectEqual(content.hash, schema.hash);
    try testing.expect(!@hasDecl(@TypeOf(schema), "fromString"));

    try testing.expect(SchemaId.none.isNone());
    try testing.expectError(error.UppercaseNotAllowed, SchemaId.parse("Foundry:item"));
}

test "field names use the identifier segment rule, and nothing else" {
    try testing.expect(isValidSegment("weight"));
    try testing.expect(isValidSegment("burns_for_2"));
    try testing.expect(!isValidSegment("Weight"));
    try testing.expect(!isValidSegment("2weight"));
    try testing.expect(!isValidSegment("burns-for"));
    try testing.expect(!isValidSegment(""));
    try testing.expect(!isValidSegment("light.radius"));
}
