//! Writing `.fdt`: values, fields and records, typed by the schema that declares them.
//!
//! The other direction from `parser.zig`, for an editor that has to put a value back into
//! source (M15, ADR-0043, `docs/design/editor.md` §5). Everything written here parses back
//! to exactly the value it was given, at the width its field declares:
//!
//! * integers in exact decimal, refused outside their type;
//! * floats in the shortest spelling that survives the compiler's reading — as an `f64`,
//!   narrowed to the field's width — always with a decimal point or an exponent, keeping
//!   the sign of zero; NaN and infinity are refused, since the format has no spelling for
//!   either;
//! * strings with exactly the parser's escapes, and nothing else;
//! * content IDs by the spelling they were written with, found by hash in a table the
//!   caller supplies. A hash with no known spelling cannot be written, because guessing one
//!   would change which content the source names.
//!
//! What cannot be written exactly is refused rather than approximated: an editor that
//! quietly changes a value when it saves is worse than one that says it cannot.
//!
//! Layout is deterministic. Scalars, and lists and structs holding only scalars, are written
//! on one line; anything deeper is a block, one element per line, indented four spaces past
//! the line it opens on. Line endings are the file's own (`Newline.detect`).
//!
//! Pure, like the rest of `data`: bytes out, nothing opened.

const std = @import("std");
const core = @import("core");

const id_mod = @import("id.zig");
const limits_mod = @import("limits.zig");
const schema_mod = @import("schema.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Field = schema_mod.Field;
const FieldType = schema_mod.FieldType;
const Limits = limits_mod.Limits;
const Value = value_mod.Value;

/// A file's line ending.
pub const Newline = enum {
    lf,
    crlf,

    pub fn text(self: Newline) []const u8 {
        return switch (self) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    }

    /// A file's convention is its first line ending's. A file with none gets `\n`.
    pub fn detect(bytes: []const u8) Newline {
        const i = std.mem.indexOfScalar(u8, bytes, '\n') orelse return .lf;
        return if (i > 0 and bytes[i - 1] == '\r') .crlf else .lf;
    }
};

/// One level of a block, as new text writes it.
pub const indent_step = "    ";

/// Content IDs' spellings, by hash: `Document.strings`, or an editor's own table.
pub const Spellings = std.AutoHashMapUnmanaged(u64, []const u8);

pub const Context = struct {
    spellings: *const Spellings,
    newline: Newline = .lf,
    /// The leading whitespace of the line the text starts on. A block's inner lines go one
    /// `indent_step` deeper, and its closing bracket goes at this.
    indent: []const u8 = "",
    limits: Limits = .default,
};

pub const Error = error{
    /// A value of a different kind from its field's type.
    WrongType,
    IntegerOutOfRange,
    /// An integer in a float field that the float cannot hold exactly.
    FloatNotExact,
    /// NaN or an infinity, at the field's width — including a finite `f64` too large for
    /// an `f32` field.
    NotFinite,
    InvalidUtf8,
    /// A content ID whose spelling is not in the table, or whose spelling there hashes to
    /// something else.
    UnspelledId,
    /// A spelling that is not a valid `namespace:name`.
    InvalidId,
    /// A new spelling whose hash already belongs to a different one (ADR-0005).
    IdCollision,
    InvalidFieldName,
    UnknownField,
    DuplicateField,
    /// Record values that do not line up with the record's fields.
    FieldCountMismatch,
    /// Indentation that is not spaces and tabs.
    InvalidIndent,
    NestingTooDeep,
    ListTooLong,
    TooManyFields,
} || Allocator.Error;

/// Validates a spelling for a new content ID, and hashes it.
///
/// Refuses one whose hash is already in `spellings` under different text: two IDs that
/// hash alike would silently become one piece of content, which is why the parser makes
/// the same check on every ID it reads (ADR-0005).
pub fn checkSpelling(spellings: *const Spellings, text: []const u8) Error!ContentId {
    const content_id = id_mod.contentId(text) catch return error.InvalidId;
    if (spellings.get(content_id.hash)) |known| {
        if (!std.mem.eql(u8, known, text)) return error.IdCollision;
    }
    return content_id;
}

/// Appends `v`, typed by `t`.
pub fn writeValue(out: *std.ArrayList(u8), gpa: Allocator, ctx: Context, t: FieldType, v: Value) Error!void {
    try checkIndent(ctx.indent);
    try writeAt(out, gpa, ctx, t, v, 0, 0);
}

/// Appends `name value`.
pub fn writeField(out: *std.ArrayList(u8), gpa: Allocator, ctx: Context, name: []const u8, t: FieldType, v: Value) Error!void {
    try checkIndent(ctx.indent);
    try writeFieldAt(out, gpa, ctx, name, t, v, 0, 0);
}

/// Appends a whole record, from its schema name through its closing brace, with no line
/// ending after it.
///
/// `values` lines up with `fields`, the schema's: a null is a field the record does not
/// write, which leaves an optional field absent, a defaulted one at its default and a
/// required one missing — an incomplete draft the checker will name, rather than a value
/// invented to fill the gap (`editor.md` §10). Present fields are written in schema order.
pub fn writeRecord(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    ctx: Context,
    schema_text: []const u8,
    id_text: []const u8,
    fields: []const Field,
    values: []const ?Value,
) Error!void {
    try checkIndent(ctx.indent);
    if (values.len != fields.len) return error.FieldCountMismatch;
    // Schema names are written in full, so the text means the same thing in any package.
    id_mod.validate(schema_text) catch return error.InvalidId;
    _ = try checkSpelling(ctx.spellings, id_text);

    try out.appendSlice(gpa, schema_text);
    try out.append(gpa, ' ');
    try out.appendSlice(gpa, id_text);
    try out.appendSlice(gpa, " {");
    try out.appendSlice(gpa, ctx.newline.text());
    for (fields, values) |field, maybe| {
        const v = maybe orelse continue;
        try writeIndent(out, gpa, ctx, 1);
        try writeFieldAt(out, gpa, ctx, field.name, field.type, v, 0, 1);
        try out.appendSlice(gpa, ctx.newline.text());
    }
    try writeIndent(out, gpa, ctx, 0);
    try out.append(gpa, '}');
}

/// Appends `text` as a quoted string, escaped exactly as the parser reads it back.
pub fn writeString(out: *std.ArrayList(u8), gpa: Allocator, text: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    try out.append(gpa, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        // Every other control character by number. The parser would take most of them
        // raw, but a byte nobody can see is a byte nobody can review.
        0...8, 11, 12, 14...31, 127 => try out.print(gpa, "\\u{{{x}}}", .{c}),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

fn writeFieldAt(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    ctx: Context,
    name: []const u8,
    t: FieldType,
    v: Value,
    depth: u32,
    level: u32,
) Error!void {
    if (!id_mod.isValidSegment(name)) return error.InvalidFieldName;
    try out.appendSlice(gpa, name);
    try out.append(gpa, ' ');
    try writeAt(out, gpa, ctx, t, v, depth, level);
}

/// `depth` bounds recursion as the parser bounds it; `level` is how many steps past
/// `ctx.indent` the current line is.
fn writeAt(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    ctx: Context,
    t: FieldType,
    v: Value,
    depth: u32,
    level: u32,
) Error!void {
    if (depth >= ctx.limits.max_nesting_depth) return error.NestingTooDeep;
    switch (t) {
        .bool => {
            try checkLeaf(t, v, ctx.limits);
            try out.appendSlice(gpa, if (v.bool) "true" else "false");
        },
        .i32, .i64, .u32, .u64 => {
            try checkLeaf(t, v, ctx.limits);
            try out.print(gpa, "{d}", .{v.int});
        },
        .f32 => try writeFloat(f32, out, gpa, t, v, ctx.limits),
        .f64 => try writeFloat(f64, out, gpa, t, v, ctx.limits),
        .string => {
            if (v != .string) return error.WrongType;
            try writeString(out, gpa, v.string);
        },
        .id => {
            if (v != .id) return error.WrongType;
            const text = ctx.spellings.get(v.id.hash) orelse return error.UnspelledId;
            const spelled = id_mod.contentId(text) catch return error.UnspelledId;
            if (!spelled.eql(v.id)) return error.UnspelledId;
            try out.appendSlice(gpa, text);
        },
        .list => |elem| {
            if (v != .list) return error.WrongType;
            if (v.list.len > ctx.limits.max_list_elements) return error.ListTooLong;
            if (v.list.len == 0) return out.appendSlice(gpa, "[]");
            if (isScalar(elem.*)) {
                try out.append(gpa, '[');
                for (v.list, 0..) |item, i| {
                    if (i != 0) try out.append(gpa, ' ');
                    try writeAt(out, gpa, ctx, elem.*, item, depth + 1, level);
                }
                return out.append(gpa, ']');
            }
            try out.append(gpa, '[');
            for (v.list) |item| {
                try out.appendSlice(gpa, ctx.newline.text());
                try writeIndent(out, gpa, ctx, level + 1);
                try writeAt(out, gpa, ctx, elem.*, item, depth + 1, level + 1);
            }
            try out.appendSlice(gpa, ctx.newline.text());
            try writeIndent(out, gpa, ctx, level);
            try out.append(gpa, ']');
        },
        .nested => |fields| {
            if (v != .nested) return error.WrongType;
            if (v.nested.len > ctx.limits.max_fields_per_record) return error.TooManyFields;
            // Structure only: a missing field is allowed, as in a record, so a draft can be
            // written before it is complete. Each value's own type is checked as it is written.
            var flat = true;
            for (v.nested, 0..) |named, i| {
                for (v.nested[0..i]) |earlier| {
                    if (std.mem.eql(u8, earlier.name, named.name)) return error.DuplicateField;
                }
                const field = fieldNamed(fields, named.name) orelse return error.UnknownField;
                if (!isScalar(field.type)) flat = false;
            }
            if (v.nested.len == 0) return out.appendSlice(gpa, "{}");
            if (flat) {
                // Two spaces between fields, as `content-schemas.md` §4.1 writes them, so
                // each name stays visibly paired with its value.
                try out.appendSlice(gpa, "{ ");
                for (v.nested, 0..) |named, i| {
                    if (i != 0) try out.appendSlice(gpa, "  ");
                    const field = fieldNamed(fields, named.name).?;
                    try writeFieldAt(out, gpa, ctx, named.name, field.type, named.value, depth + 1, level);
                }
                return out.appendSlice(gpa, " }");
            }
            try out.append(gpa, '{');
            for (v.nested) |named| {
                const field = fieldNamed(fields, named.name).?;
                try out.appendSlice(gpa, ctx.newline.text());
                try writeIndent(out, gpa, ctx, level + 1);
                try writeFieldAt(out, gpa, ctx, named.name, field.type, named.value, depth + 1, level + 1);
            }
            try out.appendSlice(gpa, ctx.newline.text());
            try writeIndent(out, gpa, ctx, level);
            try out.append(gpa, '}');
        },
    }
}

fn writeFloat(
    comptime F: type,
    out: *std.ArrayList(u8),
    gpa: Allocator,
    t: FieldType,
    v: Value,
    limits: Limits,
) Error!void {
    const x: F = switch (v) {
        .float => |f| @floatCast(f),
        .int => |i| blk: {
            // Exactness is `schema.checkValue`'s rule, so it cannot differ from the checker's.
            try checkLeaf(t, v, limits);
            break :blk @floatFromInt(i);
        },
        else => return error.WrongType,
    };
    if (!std.math.isFinite(x)) return error.NotFinite;

    var buf: [float_buffer]u8 = undefined;
    const text = floatSpelling(F, x, &buf);
    try out.appendSlice(gpa, text);
    // A float token needs a decimal point or an exponent (`content-schemas.md` §4.3):
    // `2` would be read back as an integer.
    if (std.mem.indexOfAny(u8, text, ".e") == null) try out.appendSlice(gpa, ".0");
}

/// Enough for any `f64`, decimal or scientific, so rendering cannot fail.
const float_buffer = std.fmt.float.bufferSize(.decimal, f64);

/// The shortest spelling that the compiler reads back as `x` — parsed as an `f64`, then
/// narrowed to `F`, as `BlockWriter.putFloat` narrows it.
fn floatSpelling(comptime F: type, x: F, buf: *[float_buffer]u8) []const u8 {
    const shortest = render(F, x, buf);
    if (readsBackAs(F, shortest, x)) return shortest;
    // The shortest `f32` spelling is shortest when read *as* an `f32`. Read as an `f64`
    // first, a value near a halfway point can round the other way. The `f64` holding the
    // `f32` exactly always reads back, so that is the fallback.
    return render(f64, @as(f64, x), buf);
}

fn render(comptime F: type, x: F, buf: *[float_buffer]u8) []const u8 {
    const magnitude = @abs(x);
    // Plain decimals where they stay short; an exponent outside that, where a decimal
    // would be a run of zeros.
    const decimal = magnitude == 0 or (magnitude >= 1e-4 and magnitude < 1e15);
    // The buffer holds any `f64` in either mode (`float_buffer`), so this cannot fail.
    return std.fmt.float.render(buf, x, .{ .mode = if (decimal) .decimal else .scientific }) catch unreachable;
}

fn readsBackAs(comptime F: type, text: []const u8, x: F) bool {
    const wide = std.fmt.parseFloat(f64, text) catch return false;
    const narrow: F = @floatCast(wide);
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(F));
    return @as(Bits, @bitCast(narrow)) == @as(Bits, @bitCast(x));
}

fn checkLeaf(t: FieldType, v: Value, limits: Limits) Error!void {
    schema_mod.checkValue(t, v, limits, 0) catch |err| return switch (err) {
        error.WrongType => error.WrongType,
        error.IntegerOutOfRange => error.IntegerOutOfRange,
        error.FloatNotExact => error.FloatNotExact,
        // A leaf has no fields, elements or depth.
        error.UnknownField, error.MissingField, error.DuplicateField => error.WrongType,
        error.NestingTooDeep => error.NestingTooDeep,
        error.ListTooLong => error.ListTooLong,
    };
}

fn isScalar(t: FieldType) bool {
    return switch (t) {
        .list, .nested => false,
        else => true,
    };
}

fn fieldNamed(fields: []const Field, name: []const u8) ?Field {
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

fn checkIndent(indent: []const u8) Error!void {
    for (indent) |c| if (c != ' ' and c != '\t') return error.InvalidIndent;
}

fn writeIndent(out: *std.ArrayList(u8), gpa: Allocator, ctx: Context, level: u32) Error!void {
    try out.appendSlice(gpa, ctx.indent);
    for (0..level) |_| try out.appendSlice(gpa, indent_step);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");
const Diagnostics = @import("diagnostic.zig").Diagnostics;

const no_spellings: Spellings = .empty;

/// Writes `v` as the value of field `f` in a one-field record, and parses it back.
fn roundTrip(t: FieldType, v: Value, spellings: *const Spellings) !Value {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "x foundry:r { f ");
    try writeValue(&text, testing.allocator, .{ .spellings = spellings }, t, v);
    try text.appendSlice(testing.allocator, " }");

    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    var doc = try parser.parse(testing.allocator, "t.fdt", text.items, .{ .namespace = "foundry" }, &diags);
    defer doc.deinit(testing.allocator);
    return switch (doc.records[0].fields[0].value) {
        // Everything but these is borrowed from the document, so tests keep to scalars.
        .bool, .int, .float, .id => doc.records[0].fields[0].value,
        else => error.TestUnexpectedResult,
    };
}

fn written(t: FieldType, v: Value) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(testing.allocator);
    try writeValue(&text, testing.allocator, .{ .spellings = &no_spellings }, t, v);
    return text.toOwnedSlice(testing.allocator);
}

fn expectWritten(expected: []const u8, t: FieldType, v: Value) !void {
    const text = try written(t, v);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "every integer type's endpoints are written exactly, and one past them is refused" {
    inline for (.{ i32, i64, u32, u64 }) |T| {
        const t = @unionInit(FieldType, @typeName(T), {});
        for ([_]i128{ std.math.minInt(T), std.math.maxInt(T), 0 }) |n| {
            const back = try roundTrip(t, .{ .int = n }, &no_spellings);
            try testing.expectEqual(n, back.int);
        }
        try testing.expectError(error.IntegerOutOfRange, written(t, .{ .int = @as(i128, std.math.minInt(T)) - 1 }));
        try testing.expectError(error.IntegerOutOfRange, written(t, .{ .int = @as(i128, std.math.maxInt(T)) + 1 }));
    }
    try expectWritten("18446744073709551615", .u64, .{ .int = std.math.maxInt(u64) });
    try expectWritten("-9223372036854775808", .i64, .{ .int = std.math.minInt(i64) });
}

test "a float is written in its shortest exact spelling, and always reads back as a float" {
    try expectWritten("0.5", .f64, .{ .float = 0.5 });
    try expectWritten("2.0", .f64, .{ .float = 2.0 });
    try expectWritten("-0.0", .f64, .{ .float = -0.0 });
    try expectWritten("0.0", .f64, .{ .float = 0.0 });
    try expectWritten("0.1", .f32, .{ .float = 0.1 });
    // Narrowed first: an f32 field holds f32(0.1), whose shortest spelling is still 0.1.
    try expectWritten("0.1", .f32, .{ .float = @as(f32, 0.1) });
    try expectWritten("1e15", .f64, .{ .float = 1e15 });
    try expectWritten("1e-5", .f64, .{ .float = 1e-5 });
    try expectWritten("3.0", .f32, .{ .int = 3 });

    const f64s = [_]f64{
        0.1,                         1.0 / 3.0,              -1e300,
        std.math.floatMax(f64),      std.math.floatMin(f64), std.math.floatTrueMin(f64),
        -std.math.floatTrueMin(f64), 123456789012345.6,      1e-4,
        9.999999999999999e14,        -0.0,                   5e-324,
    };
    for (f64s) |x| {
        const back = try roundTrip(.f64, .{ .float = x }, &no_spellings);
        try testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(back.float)));
    }
}

test "every f32 read back through the compiler's f64 is the f32 that was written" {
    // The halfway cases this guards against are rare, so walk many bit patterns rather than
    // a hand-picked few. A fixed seed keeps the walk the same on every run.
    var prng: std.Random.DefaultPrng = .init(0x4d15_0001);
    const random = prng.random();
    var buf: [float_buffer]u8 = undefined;
    var checked: u32 = 0;
    while (checked < 200_000) {
        const x: f32 = @bitCast(random.int(u32));
        if (!std.math.isFinite(x)) continue;
        const text = floatSpelling(f32, x, &buf);
        const back: f32 = @floatCast(try std.fmt.parseFloat(f64, text));
        try testing.expectEqual(@as(u32, @bitCast(x)), @as(u32, @bitCast(back)));
        checked += 1;
    }
    // And the extremes, subnormals included.
    for ([_]f32{ std.math.floatMax(f32), std.math.floatMin(f32), std.math.floatTrueMin(f32), -0.0 }) |x| {
        const back = try roundTrip(.f32, .{ .float = x }, &no_spellings);
        try testing.expectEqual(@as(u32, @bitCast(x)), @as(u32, @bitCast(@as(f32, @floatCast(back.float)))));
    }
}

test "a float with no spelling, or an integer a float cannot hold, is refused" {
    try testing.expectError(error.NotFinite, written(.f64, .{ .float = std.math.nan(f64) }));
    try testing.expectError(error.NotFinite, written(.f64, .{ .float = std.math.inf(f64) }));
    try testing.expectError(error.NotFinite, written(.f64, .{ .float = -std.math.inf(f64) }));
    // Finite as an f64, infinite once it is the f32 the field stores.
    try testing.expectError(error.NotFinite, written(.f32, .{ .float = 1e300 }));
    try testing.expectError(error.FloatNotExact, written(.f32, .{ .int = 16_777_217 }));
    try testing.expectError(error.WrongType, written(.f32, .{ .string = "1.0" }));
}

test "a string is escaped with exactly the parser's escapes, and every character survives" {
    try expectWritten("\"say \\\"hi\\\"\\\\\\n\\r\\t\"", .string, .{ .string = "say \"hi\"\\\n\r\t" });
    try expectWritten("\"\\u{0}\\u{1b}\\u{7f}\"", .string, .{ .string = "\x00\x1b\x7f" });
    try expectWritten("\"é漢😀\"", .string, .{ .string = "é漢😀" });
    try testing.expectError(error.InvalidUtf8, written(.string, .{ .string = "\xff" }));

    var all: [128]u8 = undefined;
    for (&all, 0..) |*c, i| c.* = @intCast(i);
    const text = try written(.string, .{ .string = &all });
    defer testing.allocator.free(text);
    const source = try std.fmt.allocPrint(testing.allocator, "x foundry:r {{ f {s} }}", .{text});
    defer testing.allocator.free(source);
    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    var doc = try parser.parse(testing.allocator, "t.fdt", source, .{ .namespace = "foundry" }, &diags);
    defer doc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &all, doc.records[0].fields[0].value.string);
}

test "a content id is written by its spelling, and one with no spelling is refused" {
    var spellings: Spellings = .empty;
    defer spellings.deinit(testing.allocator);
    const ash = ContentId.fromString("foundry:item.ash");
    try spellings.put(testing.allocator, ash.hash, "foundry:item.ash");

    const back = try roundTrip(.id, .{ .id = ash }, &spellings);
    try testing.expect(back.id.eql(ash));

    const torch = ContentId.fromString("foundry:item.torch");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try testing.expectError(error.UnspelledId, writeValue(&text, testing.allocator, .{ .spellings = &spellings }, .id, .{ .id = torch }));

    // A table whose spelling does not hash to the value's hash is not trusted.
    try spellings.put(testing.allocator, torch.hash, "foundry:item.wrong");
    try testing.expectError(error.UnspelledId, writeValue(&text, testing.allocator, .{ .spellings = &spellings }, .id, .{ .id = torch }));
}

test "a new spelling is checked for shape and for colliding with a different one" {
    var spellings: Spellings = .empty;
    defer spellings.deinit(testing.allocator);
    const ash = try checkSpelling(&spellings, "foundry:item.ash");
    try testing.expect(ash.eql(ContentId.fromString("foundry:item.ash")));

    try testing.expectError(error.InvalidId, checkSpelling(&spellings, "Foundry:ash"));
    try testing.expectError(error.InvalidId, checkSpelling(&spellings, "ash"));

    // Genuine 64-bit collisions are not to hand, so the table is given one.
    try spellings.put(testing.allocator, ash.hash, "foundry:item.other");
    try testing.expectError(error.IdCollision, checkSpelling(&spellings, "foundry:item.ash"));
}

const light_fields = [_]Field{
    .{ .name = "radius", .type = .f32 },
    .{ .name = "falloff", .type = .f32, .presence = .{ .default = .{ .float = 2.0 } } },
};
const tag_type: FieldType = .string;
const rows_elem: FieldType = .{ .list = &tag_type };
const item_fields = [_]Field{
    .{ .name = "name", .type = .string },
    .{ .name = "weight", .type = .f32, .presence = .optional },
    .{ .name = "tags", .type = .{ .list = &tag_type }, .presence = .optional },
    .{ .name = "light", .type = .{ .nested = &light_fields }, .presence = .optional },
    .{ .name = "rows", .type = .{ .list = &rows_elem }, .presence = .optional },
};

test "flat containers stay on one line; deeper ones become blocks in the file's line ending" {
    try expectWritten("[\"light\" \"fuel\"]", .{ .list = &tag_type }, .{ .list = &.{ .{ .string = "light" }, .{ .string = "fuel" } } });
    try expectWritten("[]", .{ .list = &tag_type }, .{ .list = &.{} });
    try expectWritten("{ radius 6.0  falloff 2.0 }", .{ .nested = &light_fields }, .{ .nested = &.{
        .{ .name = "radius", .value = .{ .float = 6.0 } },
        .{ .name = "falloff", .value = .{ .float = 2.0 } },
    } });
    // A struct may leave a field out, as a record may: drafts are written before they are whole.
    try expectWritten("{ radius 1.5 }", .{ .nested = &light_fields }, .{ .nested = &.{
        .{ .name = "radius", .value = .{ .float = 1.5 } },
    } });

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try writeValue(&text, testing.allocator, .{ .spellings = &no_spellings, .newline = .crlf, .indent = "  " }, .{ .list = &rows_elem }, .{ .list = &.{
        .{ .list = &.{.{ .string = "a" }} },
        .{ .list = &.{} },
    } });
    try testing.expectEqualStrings("[\r\n      [\"a\"]\r\n      []\r\n  ]", text.items);
}

test "a record is written in schema order, leaving out what it does not set" {
    var spellings: Spellings = .empty;
    defer spellings.deinit(testing.allocator);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);

    try writeRecord(&text, testing.allocator, .{ .spellings = &spellings }, "foundry:item", "foundry:item.torch", &item_fields, &.{
        .{ .string = "Torch" },
        null,
        .{ .list = &.{.{ .string = "light" }} },
        .{ .nested = &.{.{ .name = "radius", .value = .{ .float = 6.0 } }} },
        .{ .list = &.{.{ .list = &.{.{ .string = "x" }} }} },
    });
    try testing.expectEqualStrings(
        \\foundry:item foundry:item.torch {
        \\    name "Torch"
        \\    tags ["light"]
        \\    light { radius 6.0 }
        \\    rows [
        \\        ["x"]
        \\    ]
        \\}
    , text.items);

    // A new record with nothing set is an empty body, ready for fields to be added to it.
    text.clearRetainingCapacity();
    try writeRecord(&text, testing.allocator, .{ .spellings = &spellings }, "foundry:item", "foundry:item.new", &item_fields, &.{ null, null, null, null, null });
    try testing.expectEqualStrings("foundry:item foundry:item.new {\n}", text.items);

    try testing.expectError(error.FieldCountMismatch, writeRecord(&text, testing.allocator, .{ .spellings = &spellings }, "foundry:item", "foundry:item.new", &item_fields, &.{null}));
    try testing.expectError(error.InvalidId, writeRecord(&text, testing.allocator, .{ .spellings = &spellings }, "item", "foundry:item.new", &item_fields, &.{ null, null, null, null, null }));
}

test "structure is checked as it is written: names, repeats, kinds and indentation" {
    try testing.expectError(error.UnknownField, written(.{ .nested = &light_fields }, .{ .nested = &.{
        .{ .name = "colour", .value = .{ .float = 1.0 } },
    } }));
    try testing.expectError(error.DuplicateField, written(.{ .nested = &light_fields }, .{ .nested = &.{
        .{ .name = "radius", .value = .{ .float = 1.0 } },
        .{ .name = "radius", .value = .{ .float = 2.0 } },
    } }));
    try testing.expectError(error.WrongType, written(.{ .list = &tag_type }, .{ .string = "x" }));
    try testing.expectError(error.WrongType, written(.{ .list = &tag_type }, .{ .list = &.{.{ .int = 1 }} }));
    try testing.expectError(error.WrongType, written(.bool, .{ .int = 1 }));

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try testing.expectError(error.InvalidIndent, writeValue(&text, testing.allocator, .{ .spellings = &no_spellings, .indent = "#" }, .bool, .{ .bool = true }));
    try testing.expectError(error.InvalidFieldName, writeField(&text, testing.allocator, .{ .spellings = &no_spellings }, "Name", .bool, .{ .bool = true }));
}

test "writing is bounded by the same limits as reading" {
    const shallow: Limits = .{ .max_nesting_depth = 3, .max_list_elements = 2 };
    const inner: FieldType = .{ .list = &tag_type };
    const middle: FieldType = .{ .list = &inner };
    const outer: FieldType = .{ .list = &middle };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    const deep: Value = .{ .list = &.{.{ .list = &.{.{ .list = &.{.{ .string = "x" }} }} }} };
    try testing.expectError(error.NestingTooDeep, writeValue(&text, testing.allocator, .{ .spellings = &no_spellings, .limits = shallow }, outer, deep));
    try testing.expectError(error.ListTooLong, writeValue(&text, testing.allocator, .{ .spellings = &no_spellings, .limits = shallow }, .{ .list = &tag_type }, .{ .list = &.{
        .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" },
    } }));
}

fn writeEverything(gpa: Allocator) !void {
    var spellings: Spellings = .empty;
    defer spellings.deinit(gpa);
    try spellings.put(gpa, ContentId.fromString("foundry:item.torch").hash, "foundry:item.torch");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try writeRecord(&text, gpa, .{ .spellings = &spellings, .newline = .crlf }, "foundry:item", "foundry:item.torch", &item_fields, &.{
        .{ .string = "T\u{e9}\n" },
        .{ .float = 0.1 },
        .{ .list = &.{ .{ .string = "a" }, .{ .string = "b" } } },
        .{ .nested = &.{ .{ .name = "radius", .value = .{ .float = 6.0 } }, .{ .name = "falloff", .value = .{ .int = 2 } } } },
        .{ .list = &.{ .{ .list = &.{.{ .string = "x" }} }, .{ .list = &.{} } } },
    });
}

test "running out of memory anywhere while writing is an error, never a panic or a leak" {
    try testing.checkAllAllocationFailures(testing.allocator, writeEverything, .{});
}
