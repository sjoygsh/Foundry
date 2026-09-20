//! Exact values for content nobody is editing, and the node vocabulary every reader shares.
//!
//! Two kinds of content are read-only to an author and yet have to be browsable beside the
//! draft: a **dependency** definition, which an override is copied from, and the **loaded
//! preview** — what a successful build actually became once the host activated it
//! (`editor.md` §9, §11). Both are compiled records rather than source text, and both are
//! read here through `fpk.Fields.valueAt`, which is the same full-precision path
//! `edit.createOverride` already uses. Nothing goes through a runtime reader that narrows a
//! `u64` into a float or an `f64` into an `f32`.
//!
//! **One node vocabulary, three roots.** A field of a draft, a field of a dependency
//! definition and a field of the loaded snapshot are described by the same `NodeInfo` and
//! walked by the same `Selector` path, because a client that had to learn a second set of
//! typed field calls for read-only content would be a client the editor wrote twice. Source
//! resolution stays in `edit.zig`, over the parse and its spans; this file resolves the
//! other two, over stored values.
//!
//! **A snapshot borrows the reader it was read out of.** Its arena owns the values and the
//! two spellings; the schema it is laid out against belongs to the package, and the strings
//! inside a value may point into that package's bytes. A dependency set outlives the
//! workspace that loaded it and a preview's store is held alive by the host for exactly this
//! reason, so the borrow is stated rather than defended by a copy nobody would read.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const dependency = @import("dependency.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Field = data.Field;
const FieldType = data.FieldType;
const Presence = data.Presence;
const Schema = data.Schema;
const SchemaId = data.SchemaId;
const Value = data.Value;

pub const Error = error{
    /// The record's stored bytes disagree with the schema it names, or the package carries
    /// no schema for it at all. Untrusted input, so a diagnosis rather than an assertion.
    RecordInvalid,
} || Allocator.Error;

/// One structural step from a record to a field or a list element.
///
/// Deliberately the same shape `edit.Selector` has: a path that means one thing in a draft
/// and another in a dependency would be the second vocabulary this file exists to avoid.
pub const Selector = union(enum) {
    field: u32,
    item: u32,
};

/// What a reader can say about one node, whichever root it came from.
pub const NodeInfo = struct {
    /// The declared field name. Empty for a list element and for a record root, neither of
    /// which is a field of anything.
    name: []const u8 = "",
    field_type: FieldType,
    /// Null for a list element: required, optional and default are properties of a *field*
    /// declaration, and an element has no declaration of its own.
    presence: ?Presence,
    /// Whether the source or the stored record actually carries this node, as distinct from
    /// its schema having a default for it (`editor.md` §9).
    authored: bool,
    /// Fields of a nested block, elements of a list, zero for a scalar.
    child_count: u32,
    value: ?Value,
};

/// How many children a node of this type and value has.
///
/// A nested block's count comes from the **schema**, so an absent optional block still
/// describes the fields it would have — which is what lets a form offer them before
/// anything has been written. A list's comes from the value, because a list's length is
/// not declared.
pub fn childCount(field_type: FieldType, value: ?Value) u32 {
    return switch (field_type) {
        .nested => |fields| @intCast(fields.len),
        .list => switch (value orelse return 0) {
            .list => |items| @intCast(items.len),
            else => 0,
        },
        else => 0,
    };
}

/// Resolves a path against a record's declared fields and its values.
///
/// Null rather than an error set, because every way this fails is the same answer to the
/// boundary above it: the path does not name a node. An empty path is the record itself and
/// is answered by `Record.root`, not here.
pub fn walk(fields: []const Field, values: []const ?Value, path: []const Selector) ?NodeInfo {
    if (path.len == 0) return null;

    // Three cursors rather than two, and the third is the reason there is no scratch
    // buffer here. A record's values arrive positioned by schema field; a nested block's
    // arrive as the named list the record was written with. Keeping both shapes means a
    // descent never has to build a positioned array to walk one step further down.
    const Cursor = union(enum) {
        record: struct { declared: []const Field, values: []const ?Value },
        nested: struct { declared: []const Field, named: []const data.NamedValue },
        list: struct { elem: FieldType, items: []const Value },
    };

    var cursor: Cursor = .{ .record = .{ .declared = fields, .values = values } };
    for (path, 0..) |selector, depth| {
        const info: NodeInfo = switch (cursor) {
            .record => |level| blk: {
                const index = switch (selector) {
                    .field => |i| i,
                    .item => return null,
                };
                if (index >= level.declared.len) return null;
                const field = level.declared[index];
                // A package written against an older version of the schema carries fewer
                // values than the schema declares; the fields it predates are absent.
                const held: ?Value = if (index < level.values.len) level.values[index] else null;
                break :blk fieldInfo(field, held);
            },
            .nested => |level| blk: {
                const index = switch (selector) {
                    .field => |i| i,
                    .item => return null,
                };
                if (index >= level.declared.len) return null;
                const field = level.declared[index];
                break :blk fieldInfo(field, namedValue(level.named, field.name));
            },
            .list => |level| blk: {
                const index = switch (selector) {
                    .item => |i| i,
                    .field => return null,
                };
                if (index >= level.items.len) return null;
                const held = level.items[index];
                break :blk .{
                    .field_type = level.elem,
                    .presence = null,
                    .authored = true,
                    .child_count = childCount(level.elem, held),
                    .value = held,
                };
            },
        };

        if (depth + 1 == path.len) return info;

        // Descending into something the record does not carry is not a dead end: an
        // optional nested block that was never written still has the fields its schema
        // declares, and a form has to be able to offer them before anything is there.
        // So an absent container descends into an empty one, and its children report
        // themselves as unauthored rather than as missing.
        cursor = switch (info.field_type) {
            .nested => |fields_of| .{ .nested = .{
                .declared = fields_of,
                .named = switch (info.value orelse Value{ .nested = &.{} }) {
                    .nested => |named| named,
                    else => return null,
                },
            } },
            .list => |elem| .{ .list = .{
                .elem = elem.*,
                .items = switch (info.value orelse Value{ .list = &.{} }) {
                    .list => |items| items,
                    else => return null,
                },
            } },
            else => return null,
        };
    }
    unreachable;
}

/// The same walk over declarations alone, with every value absent.
///
/// What a reader falls back to when the record carries nothing at the path: the node still
/// has a name, a type and a presence, and saying so is the difference between "this field
/// is not set" and "this field does not exist".
pub fn declared(fields: []const Field, path: []const Selector) ?NodeInfo {
    if (path.len == 0) return null;
    var level: []const Field = fields;
    var current: ?Field = null;

    for (path) |selector| {
        const index = switch (selector) {
            .field => |i| i,
            // A list with no value has no elements to describe, so a path that names one
            // names nothing. Its `child_count` is already zero, so nothing offers it.
            .item => return null,
        };
        if (index >= level.len) return null;
        current = level[index];
        level = switch (level[index].type) {
            .nested => |inner| inner,
            else => &.{},
        };
    }

    const field = current orelse return null;
    return .{
        .name = field.name,
        .field_type = field.type,
        .presence = field.presence,
        .authored = false,
        .child_count = childCount(field.type, null),
        .value = null,
    };
}

fn fieldInfo(field: Field, held: ?Value) NodeInfo {
    return .{
        .name = field.name,
        .field_type = field.type,
        .presence = field.presence,
        .authored = held != null,
        .child_count = childCount(field.type, held),
        .value = held,
    };
}

/// A nested block is written as the fields the author supplied, in their order; a path
/// names the field the *schema* declares. This is where the two orders meet, and it is a
/// scan because `data.Limits` bounds how many fields a block can have.
fn namedValue(named: []const data.NamedValue, name: []const u8) ?Value {
    for (named) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

/// One read-only record, with every stored field read out exactly.
pub const Record = struct {
    arena: core.Arena,
    id: ContentId,
    /// The record's spelling, copied — a client needs the text, and the package's bytes
    /// outlive this only while its owner does.
    name: []const u8,
    /// Its schema's spelling, copied. Empty when the package carries no name for it, which
    /// a compiled package should never do and an untrusted one may.
    schema_name: []const u8,
    schema_id: SchemaId,
    /// The schema the values are laid out against, **borrowed** from the package reader
    /// this was read out of, whose lifetime the caller owns.
    schema: Schema,
    /// One per schema field, in declaration order. Null is absent.
    values: []const ?Value,

    pub fn deinit(self: *Record) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The record itself, described in the same vocabulary as one of its fields.
    pub fn root(self: *const Record) NodeInfo {
        return .{
            .name = self.name,
            .field_type = .{ .nested = self.schema.fields },
            .presence = null,
            .authored = true,
            .child_count = @intCast(self.schema.fields.len),
            .value = null,
        };
    }

    pub fn node(self: *const Record, path: []const Selector) ?NodeInfo {
        if (path.len == 0) return self.root();
        return walk(self.schema.fields, self.values, path);
    }
};

/// One definition in a host-granted dependency package.
pub fn ofDependency(gpa: Allocator, package: *const dependency.Package, index: u32) Error!Record {
    const view = package.reader.record(index) orelse return error.RecordInvalid;
    const schema = package.reader.schemaFor(view.schema_id) orelse return error.RecordInvalid;
    return build(gpa, view.id, view.name, schemaNameIn(&package.reader, view.schema_id), schema.*, package.reader.fieldsOf(view, schema.*));
}

/// One record in a runtime store — the loaded preview's root (`editor.md` §9).
///
/// The store's own `Record` already names the schema the *supplying package* carries, which
/// is the one its bytes are laid out against and not necessarily the registry's newest. A
/// field a newer version added therefore reads as absent, exactly as it does at load.
pub fn ofStore(gpa: Allocator, store: *const data.Store, record: data.store.Record) Error!Record {
    const loaded = store.package(record.package) orelse return error.RecordInvalid;
    return build(gpa, record.id, record.name, schemaNameIn(loaded.reader, record.schema_id), record.schema, record.fields);
}

fn build(
    gpa: Allocator,
    id: ContentId,
    name: []const u8,
    schema_name: ?[]const u8,
    schema: Schema,
    fields: data.fpk.Fields,
) Error!Record {
    var arena: core.Arena = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const values = try a.alloc(?Value, schema.fields.len);
    for (values, 0..) |*slot, i| {
        slot.* = fields.valueAt(a, @intCast(i)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.RecordInvalid,
        };
    }

    return .{
        .arena = arena,
        .id = id,
        .name = try a.dupe(u8, name),
        .schema_name = try a.dupe(u8, schema_name orelse ""),
        .schema_id = schema.id,
        .schema = schema,
        .values = values,
    };
}

/// The spelling a package carries for one of its schemas. `edit.zig` asks the same question
/// of the same two parallel arrays; a package with neither is one no override can be made
/// from, which is why the answer is optional rather than asserted.
pub fn schemaNameIn(reader: *const data.fpk.Reader, schema_id: SchemaId) ?[]const u8 {
    for (reader.schemas, reader.schema_names) |candidate, name| {
        if (candidate.id.eql(schema_id)) return name;
    }
    return null;
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "a node path walks fields, nested blocks and list elements alike" {
    const inner = [_]Field{
        .{ .name = "x", .type = .i32 },
        .{ .name = "y", .type = .i32, .presence = .optional },
    };
    const elem: FieldType = .i32;
    const fields = [_]Field{
        .{ .name = "count", .type = .u32 },
        .{ .name = "where", .type = .{ .nested = &inner } },
        .{ .name = "steps", .type = .{ .list = &elem }, .presence = .optional },
        .{ .name = "label", .type = .string, .presence = .{ .default = .{ .string = "none" } } },
    };

    const nested_values = [_]data.NamedValue{.{ .name = "x", .value = .{ .int = 7 } }};
    const items = [_]Value{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } };
    const values = [_]?Value{
        .{ .int = 4 },
        .{ .nested = &nested_values },
        .{ .list = &items },
        null,
    };

    // A scalar field: authored, no children, its presence is the schema's.
    const count = walk(&fields, &values, &.{.{ .field = 0 }}).?;
    try testing.expectEqualStrings("count", count.name);
    try testing.expect(count.authored);
    try testing.expectEqual(@as(u32, 0), count.child_count);
    try testing.expectEqual(@as(i128, 4), count.value.?.int);

    // A nested block describes every field the schema declares, and the one the record
    // omitted is absent rather than missing from the walk.
    const where = walk(&fields, &values, &.{.{ .field = 1 }}).?;
    try testing.expectEqual(@as(u32, 2), where.child_count);
    const x = walk(&fields, &values, &.{ .{ .field = 1 }, .{ .field = 0 } }).?;
    try testing.expectEqual(@as(i128, 7), x.value.?.int);
    const y = walk(&fields, &values, &.{ .{ .field = 1 }, .{ .field = 1 } }).?;
    try testing.expect(!y.authored);
    try testing.expectEqual(@as(?Value, null), y.value);

    // A list's length comes from its value, and an element has no presence of its own.
    const steps = walk(&fields, &values, &.{.{ .field = 2 }}).?;
    try testing.expectEqual(@as(u32, 3), steps.child_count);
    const second = walk(&fields, &values, &.{ .{ .field = 2 }, .{ .item = 1 } }).?;
    try testing.expectEqual(@as(i128, 2), second.value.?.int);
    try testing.expectEqual(@as(?Presence, null), second.presence);

    // Unset and default stay distinct: the field is not authored, and the schema still
    // says what it would read as.
    const label = walk(&fields, &values, &.{.{ .field = 3 }}).?;
    try testing.expect(!label.authored);
    try testing.expectEqualStrings("none", label.presence.?.default.string);

    // Every way a path can be wrong is the same answer.
    try testing.expectEqual(@as(?NodeInfo, null), walk(&fields, &values, &.{}));
    try testing.expectEqual(@as(?NodeInfo, null), walk(&fields, &values, &.{.{ .field = 4 }}));
    try testing.expectEqual(@as(?NodeInfo, null), walk(&fields, &values, &.{.{ .item = 0 }}));
    try testing.expectEqual(@as(?NodeInfo, null), walk(&fields, &values, &.{ .{ .field = 0 }, .{ .field = 0 } }));
    try testing.expectEqual(@as(?NodeInfo, null), walk(&fields, &values, &.{ .{ .field = 2 }, .{ .item = 3 } }));
    try testing.expectEqual(@as(?NodeInfo, null), walk(&fields, &values, &.{ .{ .field = 1 }, .{ .item = 0 } }));
}

test "an absent nested block still describes the fields it would have" {
    const inner = [_]Field{.{ .name = "x", .type = .i32 }};
    const fields = [_]Field{.{ .name = "where", .type = .{ .nested = &inner }, .presence = .optional }};
    const values = [_]?Value{null};

    const where = walk(&fields, &values, &.{.{ .field = 0 }}).?;
    try testing.expect(!where.authored);
    try testing.expectEqual(@as(u32, 1), where.child_count);

    // Descending into it answers from the declaration rather than refusing: a form has to
    // be able to lay out the fields of an unset optional block before anything is in it,
    // and every one of them reads as unauthored.
    const x = walk(&fields, &values, &.{ .{ .field = 0 }, .{ .field = 0 } }).?;
    try testing.expectEqualStrings("x", x.name);
    try testing.expect(!x.authored);
    try testing.expectEqual(@as(?Value, null), x.value);

    // A field the schema does not declare is still nothing, absent block or not.
    try testing.expectEqual(@as(?NodeInfo, null), walk(&fields, &values, &.{ .{ .field = 0 }, .{ .field = 1 } }));
}
