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
const data = @import("data");

const api = @import("api.zig");
const types = @import("types.zig");

const testing = std.testing;

/// **The header, as a build input.**
///
/// Not decoration: `agreement.c`'s object is cached against the C file, and a change to
/// `foundry.h` *alone* left that cache warm — so the one edit the agreement exists to catch
/// was the one edit that did not re-run it. Embedding the header here makes it an input of
/// this Zig module, whose recompilation does re-run the C half.
///
/// The two assertions below are what stop this from being an unexplained `@embedFile`: they
/// read the numbers out of the text and check them against the ones the engine publishes.
const header = @embedFile("foundry.h");

test "the header declares the version and the entry points this build publishes" {
    try testing.expect(std.mem.indexOf(u8, header, "#define FOUNDRY_API_VERSION_1 1u") != null);
    try testing.expect(std.mem.indexOf(u8, header, types.init_symbol) != null);
    try testing.expect(std.mem.indexOf(u8, header, types.shutdown_symbol) != null);
}

test "no parameter in the header is a name C++ cannot compile" {
    // A parameter name is documentation rather than ABI, which is what makes this cheap to
    // obey and easy to break: `world_spawn(FoundryContentId template, ...)` compiled as C
    // for as long as nobody tried it from C++, and mods get written in C++.
    //
    // Only the keywords C++ has and C does not — a C keyword here would already have failed
    // `agreement.c`. Names are checked where they appear as parameters, so a keyword inside
    // a comment or a type is not a false alarm.
    const cxx_only = [_][]const u8{
        "and",       "and_eq",       "asm",       "bitand",     "bitor",
        "bool",      "catch",        "class",     "compl",      "concept",
        "consteval", "constexpr",    "constinit", "const_cast", "decltype",
        "delete",    "dynamic_cast", "explicit",  "export",     "false",
        "friend",    "mutable",      "namespace", "new",        "noexcept",
        "not",       "not_eq",       "nullptr",   "operator",   "or",
        "or_eq",     "private",      "protected", "public",     "reinterpret_cast",
        "requires",  "static_cast",  "template",  "this",       "throw",
        "true",      "try",          "typeid",    "typename",   "using",
        "virtual",   "wchar_t",      "xor",       "xor_eq",
    };

    for (cxx_only) |word| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, header, at, word)) |found| {
            at = found + word.len;
            // A parameter is preceded by a space and followed by `,` or `)`.
            if (found == 0 or at >= header.len) continue;
            if (header[found - 1] != ' ') continue;
            if (header[at] != ',' and header[at] != ')') continue;
            std.debug.print(
                "the header uses '{s}' as a parameter name, which C++ cannot compile\n",
                .{word},
            );
            return error.TestUnexpectedResult;
        }
    }
}

test "the header names every table entry, in the table's own order" {
    @setEvalBranchQuota(64 * @typeInfo(api.Api_v1).@"struct".fields.len);

    // A weaker check than `agreement.c`'s offsets and a differently-shaped one: that walks
    // the compiled struct, this walks the text a mod author actually reads. A member added
    // to one and not the other fails here first, and says which name is missing.
    var at: usize = std.mem.indexOf(u8, header, "typedef struct FoundryApi_v1 {").?;
    inline for (@typeInfo(api.Api_v1).@"struct".fields) |field| {
        // `version` and `size` are plain integers; every other member is a call, and a call
        // is spelled `(*name)` in C.
        if (comptime @typeInfo(field.type) == .pointer) {
            const spelled = "*" ++ field.name ++ ")";
            const found = std.mem.indexOfPos(u8, header, at, spelled) orelse {
                std.debug.print(
                    "the header does not declare '{s}' after the entry before it\n",
                    .{field.name},
                );
                return error.TestUnexpectedResult;
            };
            at = found;
        }
    }
}

// `agreement.c`, which the build attaches to this module. Referenced only from tests, so a
// build of `abi` that is not a test never needs the object at all.
extern fn foundry_agreement_content_id(bytes: ?*const anyopaque, len: usize) u64;
extern fn foundry_agreement_schema_id(bytes: ?*const anyopaque, len: usize) u64;
extern fn foundry_agreement_str_len(s: types.Str) u64;
extern fn foundry_agreement_str_byte(s: types.Str, index: u64) u8;
extern fn foundry_agreement_entity_bits(entity: types.Entity) u64;
extern fn foundry_agreement_entity_from_bits(bits: u64) types.Entity;
extern fn foundry_agreement_cursor_begin() types.Cursor;
extern fn foundry_agreement_api_v1_size() u64;
extern fn foundry_agreement_api_v1_count() u64;
extern fn foundry_agreement_api_v1_offset(index: u64) u64;
extern fn foundry_agreement_api_v1_name(index: u64) ?[*:0]const u8;

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
        types.View,  types.Voice,   types.Body,          types.Grid,
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

        // The other identifier space, which is the same algorithm over the same bytes into
        // a different C type. A mod naming its own schema has no other way to compute one,
        // so this drifting would break registration and nothing else would say why.
        const schema_from_header = foundry_agreement_schema_id(v.ptr, v.len);
        try testing.expectEqual(data.SchemaId.fromStringUnchecked(v).hash, schema_from_header);
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

test "the enumerations are the numbers the header states" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(types.LogLevel));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(types.LogLevel.err));
    try testing.expectEqual(@as(i32, 4), @intFromEnum(types.LogLevel.trace));

    try testing.expectEqual(@as(usize, 4), @sizeOf(types.FieldType));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(types.FieldType.bool));
    try testing.expectEqual(@as(i32, 7), @intFromEnum(types.FieldType.string));
    try testing.expectEqual(@as(i32, 8), @intFromEnum(types.FieldType.id));
    try testing.expectEqual(@as(i32, 10), @intFromEnum(types.FieldType.nested));

    // Every field type `data` can describe has a number here. Adding one to the union
    // without publishing it would otherwise be discovered by a mod.
    inline for (@typeInfo(@import("data").FieldType).@"union".fields) |f| {
        _ = std.meta.stringToEnum(types.FieldType, f.name) orelse {
            std.debug.print("data.FieldType.{s} has no number at the boundary\n", .{f.name});
            return error.TestUnexpectedResult;
        };
    }
}

test "FoundryLogRecord and FoundryMemoryStats are the shapes the header states" {
    try testing.expectEqual(@as(usize, 56), @sizeOf(types.LogRecord));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.LogRecord, "level"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(types.LogRecord, "reserved"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.LogRecord, "frame"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(types.LogRecord, "sequence"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(types.LogRecord, "scope"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(types.LogRecord, "text"));

    try testing.expectEqual(@as(usize, 40), @sizeOf(types.MemoryStats));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.MemoryStats, "live_bytes"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(types.MemoryStats, "failures"));

    try testing.expectEqual(@as(usize, 8), @sizeOf(types.MemoryCounter));
}

test "the scene descriptors are the shapes the header states" {
    // Widths beside offsets, for step 2's reason: `alignment` narrowing to `u16` moves no
    // offset around it, because `ctx` is eight-aligned and the padding absorbs the change.
    try testing.expectEqual(@as(usize, 16), @sizeOf(types.Step));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.Step, "tick"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.Step, "delta_ns"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.Step, "tick")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.Step, "delta_ns")));

    try testing.expectEqual(@as(usize, 56), @sizeOf(types.ComponentDesc));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.ComponentDesc, "schema"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.ComponentDesc, "name"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(types.ComponentDesc, "size"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(types.ComponentDesc, "alignment"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(types.ComponentDesc, "ctx"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(types.ComponentDesc, "construct"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(types.ComponentDesc, "destruct"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.ComponentDesc, "schema")));
    try testing.expectEqual(@as(usize, 16), @sizeOf(@FieldType(types.ComponentDesc, "name")));
    try testing.expectEqual(@as(usize, 4), @sizeOf(@FieldType(types.ComponentDesc, "size")));
    try testing.expectEqual(@as(usize, 4), @sizeOf(@FieldType(types.ComponentDesc, "alignment")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.ComponentDesc, "ctx")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.ComponentDesc, "construct")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.ComponentDesc, "destruct")));

    try testing.expectEqual(@as(usize, 40), @sizeOf(types.SystemDesc));
    try testing.expectEqual(@as(usize, 0), @offsetOf(types.SystemDesc, "id"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(types.SystemDesc, "name"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(types.SystemDesc, "ctx"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(types.SystemDesc, "update"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.SystemDesc, "id")));
    try testing.expectEqual(@as(usize, 16), @sizeOf(@FieldType(types.SystemDesc, "name")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.SystemDesc, "ctx")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(@FieldType(types.SystemDesc, "update")));
}

test "the table has the same members, in the same places, in both languages" {
    const fields = @typeInfo(api.Api_v1).@"struct".fields;

    // A capability in one and not the other is a different count, which is the cheap half.
    try testing.expectEqual(@as(u64, fields.len), foundry_agreement_api_v1_count());
    try testing.expectEqual(@as(u64, @sizeOf(api.Api_v1)), foundry_agreement_api_v1_size());

    // The expensive half: every member is where the other language thinks it is. Every entry
    // is eight bytes wide, so two swapped in the header keep the same *set* of offsets —
    // comparing them position by position is what makes a reordering fail rather than pass.
    inline for (fields, 0..) |field, i| {
        const from_header = foundry_agreement_api_v1_offset(i);
        testing.expectEqual(@as(u64, @offsetOf(api.Api_v1, field.name)), from_header) catch |err| {
            std.debug.print(
                "the table disagrees about '{s}': Zig puts it at {d}, the header at {d}\n",
                .{ field.name, @offsetOf(api.Api_v1, field.name), from_header },
            );
            return err;
        };

        const spelled = foundry_agreement_api_v1_name(i) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(field.name, std.mem.span(spelled));
    }

    // Out of range is answered rather than read past, in the file whose whole subject is
    // what happens when two sides disagree about a length.
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), foundry_agreement_api_v1_offset(fields.len));
    try testing.expectEqual(@as(?[*:0]const u8, null), foundry_agreement_api_v1_name(fields.len));
}
