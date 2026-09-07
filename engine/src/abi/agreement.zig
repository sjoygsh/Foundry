//! The engine's half of the agreement with `foundry.h`.
//!
//! `agreement.c` states every size and offset the specification claims and fails to compile
//! if C disagrees. This states the same numbers and fails the test if Zig disagrees. Neither
//! file describes the other: both describe the contract, which is what makes a disagreement
//! land on whoever changed one side rather than on a mod author six months later.
//!
//! It also does the part no static assertion can. Matching numbers prove two layouts are the
//! same shape; pushing a value through the boundary and reading it back proves they are the
//! same *layout*. Four values make that crossing here — a string, a handle in each
//! direction, and a cursor — and the header's own hash function is called from Zig and
//! compared against the one the content compiler uses, because those are two independent
//! implementations of FNV-1a and nothing else would stop them drifting.
//!
//! Design: `docs/design/public-abi.md` §5 and §16.

const std = @import("std");
const core = @import("core");
const types = @import("types.zig");

const testing = std.testing;

// `agreement.c`, which the build attaches to this module. Referenced only from tests, so a
// build of `abi` that is not a test never needs the object at all.
extern fn foundry_agreement_content_id(bytes: ?*const anyopaque, len: usize) u64;
extern fn foundry_agreement_str_len(s: types.Str) u64;
extern fn foundry_agreement_str_byte(s: types.Str, index: u64) u8;
extern fn foundry_agreement_entity_bits(entity: types.Entity) u64;
extern fn foundry_agreement_entity_from_bits(bits: u64) types.Entity;
extern fn foundry_agreement_cursor_begin() types.Cursor;

test "the scalars are the widths the header states" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(types.Result));
    try testing.expectEqual(@as(usize, 1), @sizeOf(types.Bool));
    try testing.expectEqual(i32, @typeInfo(types.Result).@"enum".tag_type);
}

test "FoundryStr is sixteen bytes, pointer first" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(types.Str));
    try testing.expectEqual(@as(usize, 8), @alignOf(types.Str));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.Str, "ptr"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.Str, "len"));
}

test "FoundryContentId is eight bytes of hash" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(types.ContentId));
    try testing.expectEqual(@as(usize, 8), @alignOf(types.ContentId));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.ContentId, "hash"));
}

test "every handle kind is eight opaque bytes" {
    inline for (.{
        types.Mod,   types.Package, types.Schema,        types.Record,
        types.Asset, types.Entity,  types.ComponentType, types.Texture,
        types.View,  types.Voice,   types.Body,
    }) |Handle| {
        try testing.expectEqual(@as(usize, 8), @sizeOf(Handle));
        try testing.expectEqual(@as(usize, 8), @alignOf(Handle));
        try testing.expectEqual(@as(usize, 0), @offsetOf(Handle, "bits"));
    }
}

test "FoundryCursor is eight bytes of position" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(types.Cursor));
    try testing.expectEqual(@as(usize, 8), @alignOf(types.Cursor));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.Cursor, "bits"));
}

test "the header's hash is the engine's hash" {
    // The vectors `core` pins, asked of the header instead. If these ever disagree, every
    // compiled package and every save written by a tool that used the header is wrong, and
    // it would be wrong invisibly — the ids would merely fail to match.
    const vectors = [_][]const u8{
        "",
        "a",
        "foobar",
        "foundry:item.torch",
        "foundry:core",
        "sandbox:content",
        // Non-ASCII, because the specification says "the exact UTF-8 bytes" and a hash that
        // treated a byte as signed would agree on everything above and nothing here.
        "foundry:café.münze",
    };

    for (vectors) |v| {
        const from_header = foundry_agreement_content_id(v.ptr, v.len);
        try testing.expectEqual(core.ContentId.fromString(v).hash, from_header);
    }

    // And the empty case, where a mod may legitimately pass a null pointer.
    try testing.expectEqual(core.ContentId.fromString("").hash, foundry_agreement_content_id(null, 0));
}

test "a string built in Zig is the same bytes in C" {
    const message = "the crossing is a cast";
    const s = types.Str.from(message);

    try testing.expectEqual(@as(u64, message.len), foundry_agreement_str_len(s));
    for (message, 0..) |byte, i| {
        try testing.expectEqual(byte, foundry_agreement_str_byte(s, i));
    }
}

test "a handle survives being passed by value in both directions" {
    const Thing = struct {};
    const handle: core.Handle(Thing) = .{ .index = 12345, .generation = 678 };

    const out = types.Entity.wrap(handle);
    try testing.expectEqual(out.bits, foundry_agreement_entity_bits(out));

    const back = foundry_agreement_entity_from_bits(out.bits);
    try testing.expect(handle.eql(back.unwrap(core.Handle(Thing))));

    try testing.expect(foundry_agreement_entity_from_bits(0).isNone());
}

test "the header's cursor initialiser is the engine's begin" {
    try testing.expectEqual(types.Cursor.begin.bits, foundry_agreement_cursor_begin().bits);
    try testing.expect(foundry_agreement_cursor_begin().isBegin());
}
