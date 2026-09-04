//! A content value, as authored.
//!
//! This is the **authoring-side** representation: what a literal in a `.fdt` file becomes
//! before it is checked against a schema and written into a package. It is not what the
//! engine reads at runtime — a compiled record's fields are laid out by their schema and
//! read at a computed offset (`content-schemas.md` §5), precisely so that no runtime path
//! walks a tree of tagged unions.
//!
//! Integers are held as `i128` because a literal has no type until a schema gives it one,
//! and one storage has to cover the whole of `i64` and the whole of `u64`. Narrowing to
//! the field's declared type is validation's job, and a literal that does not fit is an
//! error naming both the value and the type.

const std = @import("std");
const core = @import("core");
const limits_mod = @import("limits.zig");

const Allocator = std.mem.Allocator;
const Limits = limits_mod.Limits;

pub const Value = union(enum) {
    bool: bool,
    /// Wide enough for every integer type in `FieldType`, signed or unsigned.
    int: i128,
    float: f64,
    string: []const u8,
    id: core.ContentId,
    list: []const Value,
    /// An inline struct: named fields with no identity of their own. Anything a mod might
    /// want to override independently is a record with a content ID instead, and choosing
    /// between the two is a schema author's most consequential decision.
    nested: []const NamedValue,

    /// Deep-copies into `arena`. The copy owns nothing the original owned, so the source
    /// may be a parser's scratch memory, a `comptime` literal or another arena's value.
    ///
    /// Depth-bounded rather than trusting the input: this walks a structure that came out
    /// of a file, and unbounded recursion on untrusted input is a stack overflow with
    /// extra steps.
    pub fn clone(self: Value, arena: Allocator, limits: Limits) CloneError!Value {
        return cloneDepth(self, arena, limits, 0);
    }

    fn cloneDepth(self: Value, arena: Allocator, limits: Limits, depth: u32) CloneError!Value {
        if (depth >= limits.max_nesting_depth) return error.NestingTooDeep;
        return switch (self) {
            .bool, .int, .float, .id => self,
            .string => |s| .{ .string = try arena.dupe(u8, s) },
            .list => |items| blk: {
                if (items.len > limits.max_list_elements) return error.ListTooLong;
                const out = try arena.alloc(Value, items.len);
                for (items, out) |src, *dst| dst.* = try cloneDepth(src, arena, limits, depth + 1);
                break :blk .{ .list = out };
            },
            .nested => |fields| blk: {
                if (fields.len > limits.max_fields_per_record) return error.TooManyFields;
                const out = try arena.alloc(NamedValue, fields.len);
                for (fields, out) |src, *dst| dst.* = .{
                    .name = try arena.dupe(u8, src.name),
                    .value = try cloneDepth(src.value, arena, limits, depth + 1),
                };
                break :blk .{ .nested = out };
            },
        };
    }

    /// Structural equality. Used to compare a schema's declared defaults across versions,
    /// where a silently changed default is a compatibility break worth catching.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .bool => a.bool == b.bool,
            .int => a.int == b.int,
            // Bit equality, not numeric: this compares two *authored literals* for having
            // been written the same way, and `0.0 == -0.0` being true would hide a change.
            // NaN never reaches here — the format refuses to parse one.
            .float => @as(u64, @bitCast(a.float)) == @as(u64, @bitCast(b.float)),
            .string => std.mem.eql(u8, a.string, b.string),
            .id => a.id.eql(b.id),
            .list => blk: {
                if (a.list.len != b.list.len) break :blk false;
                for (a.list, b.list) |x, y| if (!eql(x, y)) break :blk false;
                break :blk true;
            },
            .nested => blk: {
                if (a.nested.len != b.nested.len) break :blk false;
                for (a.nested, b.nested) |x, y| {
                    if (!std.mem.eql(u8, x.name, y.name)) break :blk false;
                    if (!eql(x.value, y.value)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

pub const NamedValue = struct {
    name: []const u8,
    value: Value,
};

pub const CloneError = error{
    NestingTooDeep,
    ListTooLong,
    TooManyFields,
} || Allocator.Error;

const testing = std.testing;

test "cloning owns everything, so the source can go away" {
    var arena: core.Arena = .init(testing.allocator);
    defer arena.deinit();

    var name_buf: [4]u8 = "name".*;
    var text_buf: [5]u8 = "Torch".*;
    const source: Value = .{ .nested = &.{
        .{ .name = &name_buf, .value = .{ .string = &text_buf } },
        .{ .name = "tags", .value = .{ .list = &.{
            .{ .string = "light" },
            .{ .int = 3 },
        } } },
    } };

    const copy = try source.clone(arena.allocator(), .default);
    try testing.expect(copy.eql(source));

    // Scribble over the originals. A shallow copy would now compare unequal to itself.
    @memset(&name_buf, 'x');
    @memset(&text_buf, 'x');
    try testing.expectEqualStrings("name", copy.nested[0].name);
    try testing.expectEqualStrings("Torch", copy.nested[0].value.string);
}

test "cloning refuses to recurse forever on a structure from a file" {
    var arena: core.Arena = .init(testing.allocator);
    defer arena.deinit();

    // Build a list nested deeper than the limit allows.
    const shallow: Limits = .{ .max_nesting_depth = 4 };
    var v: Value = .{ .int = 1 };
    var buf: [8]Value = undefined;
    for (0..6) |i| {
        buf[i] = v;
        v = .{ .list = buf[i .. i + 1] };
    }
    try testing.expectError(error.NestingTooDeep, v.clone(arena.allocator(), shallow));

    // And accepts what fits.
    try testing.expect((try buf[2].clone(arena.allocator(), shallow)).eql(buf[2]));
}

test "equality is structural, and distinguishes a changed default from an unchanged one" {
    try testing.expect(Value.eql(.{ .int = 3 }, .{ .int = 3 }));
    try testing.expect(!Value.eql(.{ .int = 3 }, .{ .float = 3.0 }));
    try testing.expect(!Value.eql(.{ .float = 0.0 }, .{ .float = -0.0 }));
    try testing.expect(Value.eql(
        .{ .list = &.{ .{ .string = "a" }, .{ .bool = true } } },
        .{ .list = &.{ .{ .string = "a" }, .{ .bool = true } } },
    ));
    try testing.expect(!Value.eql(
        .{ .list = &.{.{ .string = "a" }} },
        .{ .list = &.{.{ .string = "b" }} },
    ));
}

test "an integer literal has room for the whole of i64 and the whole of u64" {
    // A single storage for untyped literals only works if it covers both ends.
    const v_min: Value = .{ .int = std.math.minInt(i64) };
    const v_max: Value = .{ .int = std.math.maxInt(u64) };
    try testing.expectEqual(@as(i128, std.math.minInt(i64)), v_min.int);
    try testing.expectEqual(@as(i128, std.math.maxInt(u64)), v_max.int);
}
