//! Schemas: what a record type is, and the runtime registry that holds them.
//!
//! A schema is a named record type — an identifier, a version, and an ordered list of
//! typed fields. Content is instances of schemas (ADR-0006), and the schema is what turns
//! an untyped literal in a text file into a value with a size, a range and a place in a
//! compiled package.
//!
//! **The registry is a runtime table, and the engine's own schemas go in through the same
//! call a mod's `@schema` directive uses** (I6). There is no compile-time schema list, and
//! there is no privileged path — native code may use `comptime` helpers to *produce* a
//! `Schema`, but both roads end at `register`.
//!
//! See `docs/design/content-schemas.md` §3.

const std = @import("std");
const core = @import("core");
const id_mod = @import("id.zig");
const value_mod = @import("value.zig");
const limits_mod = @import("limits.zig");

const Allocator = std.mem.Allocator;
const SchemaId = id_mod.SchemaId;
const Value = value_mod.Value;
const Limits = limits_mod.Limits;
const log = core.log.scoped(.data);

/// The closed type list.
///
/// **Closed on purpose.** Every type costs three implementations that have to agree — a
/// text form, a binary form and a validator — and a type that reaches a compiled package
/// can never be removed. Small on purpose too: an inline struct composes, so a colour is
/// `{ r f32  g f32  b f32  a f32 }` and one type does the work of a dozen.
///
/// The tag names *are* the spelling in `.fdt`. `@tagName` is what the parser matches
/// against, so adding a primitive type means adding it here and nowhere else.
pub const FieldType = union(enum) {
    bool,
    i32,
    i64,
    u32,
    u64,
    f32,
    f64,
    string,
    /// A reference to another piece of content, by `ContentId`.
    id,
    /// `[T]`
    list: *const FieldType,
    /// `{ ... }` — named fields with no identity of their own. An inline struct cannot be
    /// referenced or overridden independently; anything a mod might want to override on
    /// its own is a record with a content ID.
    nested: []const Field,

    /// The `.fdt` spelling of a primitive type, or null for the composite ones, which
    /// have punctuation rather than a keyword.
    pub fn keyword(name: []const u8) ?FieldType {
        inline for (@typeInfo(FieldType).@"union".fields) |f| {
            if (f.type == void and std.mem.eql(u8, f.name, name)) {
                return @unionInit(FieldType, f.name, {});
            }
        }
        return null;
    }

    /// The `.fdt` spelling, for diagnostics. `inline else` over the tag names for the
    /// same reason `keyword` reads them: one table, so a type cannot be spelled one way
    /// in the parser and another in the message that rejects it.
    pub fn format(self: FieldType, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .list => |elem| {
                try writer.writeByte('[');
                try elem.format(writer);
                try writer.writeByte(']');
            },
            .nested => try writer.writeAll("{ ... }"),
            inline else => |_, tag| try writer.writeAll(@tagName(tag)),
        }
    }

    /// Whether two declared types are the same. Used to check that a schema version bump
    /// is additive rather than a reinterpretation of bytes already written.
    pub fn eql(a: FieldType, b: FieldType) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .list => eql(a.list.*, b.list.*),
            .nested => blk: {
                if (a.nested.len != b.nested.len) break :blk false;
                for (a.nested, b.nested) |x, y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            else => true,
        };
    }
};

/// Whether a field has to be present, and what absence means.
///
/// `optional` and `default` are deliberately different things. A missing optional field
/// reads as *absent*; a missing defaulted field reads as *the default*. Collapsing them
/// would make "this item drops nothing" and "this item's drop was never specified"
/// indistinguishable, which is the sort of conflation that is free to avoid now and
/// impossible to unpick later.
pub const Presence = union(enum) {
    required,
    optional,
    default: Value,
};

pub const Field = struct {
    name: []const u8,
    type: FieldType,
    presence: Presence = .required,
    /// The schema version that introduced this field. Fields added after version 1 must
    /// be `optional` or carry a `default`, or old content could not be read.
    since: u32 = 1,

    pub fn eql(a: Field, b: Field) bool {
        return std.mem.eql(u8, a.name, b.name) and a.type.eql(b.type);
    }
};

pub const Schema = struct {
    id: SchemaId,
    version: u32 = 1,
    fields: []const Field,

    pub fn fieldIndex(self: Schema, name: []const u8) ?u32 {
        for (self.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) return @intCast(i);
        }
        return null;
    }
};

/// Phantom tag for `SchemaHandle` (I1).
pub const Schemas = opaque {};
pub const SchemaHandle = core.Handle(Schemas);

pub const RegisterError = error{
    /// The schema's own identifier is `none`.
    MissingSchemaId,
    /// Version 0. Versions start at 1 so that "unset" and "first" are distinguishable.
    InvalidVersion,
    /// A field name that is not `[a-z][a-z0-9_]*`.
    InvalidFieldName,
    DuplicateFieldName,
    TooManyFields,
    NestingTooDeep,
    /// `since` names a version the schema does not have.
    InvalidSince,
    /// A field introduced after version 1 that is neither optional nor defaulted. Old
    /// content has no value for it, so this is a breaking change, and it is reported here
    /// rather than when somebody's save fails to load.
    AddedFieldNeedsDefault,
    /// A default whose type is not the field's type.
    DefaultTypeMismatch,
    /// A *different* schema is already registered under this identifier at this version.
    /// Replacing a schema outright is refused: records already laid out against the old
    /// one would silently reinterpret their bytes. Re-registering the same one is not
    /// this error — it is how two packages that both use a schema each carry it (§6).
    DuplicateSchema,
    /// A version that disagrees with one already registered about a field they share, or
    /// that drops a field the other declares. Versions may only append.
    NonAdditiveChange,
} || value_mod.CloneError;

/// Owns every registered schema.
///
/// Schemas are deep-copied in, so a caller may register a `comptime` literal, a schema
/// parsed into scratch memory, or one supplied by a mod, and none of them has to outlive
/// the call. The arena is never reset: schema registration happens at load, extension is
/// rare, and the memory a superseded version leaves behind is measured in bytes.
pub const Registry = struct {
    arena: core.Arena,
    schemas: core.HandlePool(Schemas, Schema) = .empty,
    by_id: std.AutoHashMapUnmanaged(u64, SchemaHandle) = .empty,
    limits: Limits,

    pub fn init(gpa: Allocator, limits: Limits) Registry {
        return .{ .arena = .init(gpa), .limits = limits };
    }

    pub fn deinit(self: *Registry, gpa: Allocator) void {
        self.schemas.deinit(gpa);
        self.by_id.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Registry) u32 {
        return self.schemas.count();
    }

    pub fn find(self: *const Registry, schema_id: SchemaId) ?SchemaHandle {
        return self.by_id.get(schema_id.hash);
    }

    pub fn get(self: *Registry, handle: SchemaHandle) ?*const Schema {
        return self.schemas.getConst(handle);
    }

    pub fn lookup(self: *Registry, schema_id: SchemaId) ?*const Schema {
        return self.schemas.getConst(self.find(schema_id) orelse return null);
    }

    /// Registers a schema, extends one already registered, or accepts a copy of one.
    ///
    /// Three things can arrive under an identifier the registry already holds, and only
    /// the middle one changes anything:
    ///
    /// * **An older or equal version.** A second package carrying the same schema as it
    ///   was when *that* package was compiled. Accepted if it is a prefix of what is held
    ///   — which is what additive-only versioning guarantees it will be — and the
    ///   registry keeps the newer copy. This is the ordinary case for any two packages
    ///   that share a schema, and it is why the registry holds the *newest* version
    ///   rather than the first one it saw.
    /// * **A higher version.** An extension. Permitted only when additive: the existing
    ///   fields must be unchanged and in the same order, because the layout of every
    ///   already-compiled package depends on it. A later package *adding* a field is a
    ///   legitimate and important thing for a mod to do; a later package *reinterpreting*
    ///   one is a corruption with a friendly face.
    /// * **A different schema at the same version.** Two packages that disagree about
    ///   what `foundry:item` is. Refused, because nothing else is safe.
    ///
    /// Extending updates the schema behind the existing handle rather than issuing a new
    /// one, so everything already holding it follows — the same property that makes hot
    /// reload work (I1).
    pub fn register(self: *Registry, gpa: Allocator, schema: Schema) RegisterError!SchemaHandle {
        try self.validate(schema);

        if (self.by_id.get(schema.id.hash)) |existing_handle| {
            const existing = self.schemas.get(existing_handle).?;
            if (schema.version > existing.version) {
                try checkAdditive(existing.*, schema);
                // Cloned only once the decision to install it is made, so a package that
                // merely restates a schema costs the registry's arena nothing.
                existing.* = try self.clone(schema);
            } else if (schema.version == existing.version) {
                if (!sameFields(schema.fields, existing.fields)) return error.DuplicateSchema;
            } else {
                try checkAdditive(schema, existing.*);
            }
            return existing_handle;
        }

        const handle = try self.schemas.add(gpa, try self.clone(schema));
        try self.by_id.put(gpa, schema.id.hash, handle);
        return handle;
    }

    fn validate(self: *const Registry, schema: Schema) RegisterError!void {
        if (schema.id.isNone()) return error.MissingSchemaId;
        if (schema.version == 0) return error.InvalidVersion;
        try self.validateFields(schema.fields, schema.version, 0);
    }

    fn validateFields(
        self: *const Registry,
        fields: []const Field,
        version: u32,
        depth: u32,
    ) RegisterError!void {
        if (depth >= self.limits.max_nesting_depth) return error.NestingTooDeep;
        if (fields.len > self.limits.max_fields_per_schema) return error.TooManyFields;

        for (fields, 0..) |f, i| {
            if (!id_mod.isValidSegment(f.name)) return error.InvalidFieldName;
            for (fields[0..i]) |earlier| {
                if (std.mem.eql(u8, earlier.name, f.name)) return error.DuplicateFieldName;
            }
            if (f.since == 0 or f.since > version) return error.InvalidSince;
            if (f.since > 1 and f.presence == .required) return error.AddedFieldNeedsDefault;

            switch (f.presence) {
                .required, .optional => {},
                .default => |d| checkValue(f.type, d, self.limits, depth + 1) catch
                    return error.DefaultTypeMismatch,
            }

            switch (f.type) {
                .nested => |nested| try self.validateFields(nested, version, depth + 1),
                .list => |elem| if (elem.* == .nested)
                    try self.validateFields(elem.nested, version, depth + 1),
                else => {},
            }
        }
    }

    /// Whether two declarations of the same version are the same declaration.
    ///
    /// `Field.eql` compares name and type and not presence, because that is what layout
    /// depends on; here the whole declaration has to match, since two packages disagreeing
    /// about a default disagree about what content means.
    fn sameFields(a: []const Field, b: []const Field) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!x.eql(y) or x.since != y.since) return false;
            if (std.meta.activeTag(x.presence) != std.meta.activeTag(y.presence)) return false;
            switch (x.presence) {
                .default => |d| if (!d.eql(y.presence.default)) return false,
                else => {},
            }
        }
        return true;
    }

    fn checkAdditive(old: Schema, new: Schema) RegisterError!void {
        if (new.fields.len < old.fields.len) return error.NonAdditiveChange;
        for (old.fields, new.fields[0..old.fields.len]) |a, b| {
            if (!a.eql(b)) return error.NonAdditiveChange;
        }
        for (new.fields[old.fields.len..]) |f| {
            // A field appended by a later version has to be readable in content written
            // before it existed.
            if (f.presence == .required) return error.AddedFieldNeedsDefault;
        }
    }

    fn clone(self: *Registry, schema: Schema) RegisterError!Schema {
        return .{
            .id = schema.id,
            .version = schema.version,
            .fields = try self.cloneFields(schema.fields, 0),
        };
    }

    fn cloneFields(self: *Registry, fields: []const Field, depth: u32) RegisterError![]const Field {
        if (depth >= self.limits.max_nesting_depth) return error.NestingTooDeep;
        const arena = self.arena.allocator();
        const out = try arena.alloc(Field, fields.len);
        for (fields, out) |src, *dst| {
            dst.* = .{
                .name = try arena.dupe(u8, src.name),
                .type = try self.cloneType(src.type, depth),
                .presence = switch (src.presence) {
                    .required => .required,
                    .optional => .optional,
                    .default => |d| .{ .default = try d.clone(arena, self.limits) },
                },
                .since = src.since,
            };
        }
        return out;
    }

    fn cloneType(self: *Registry, t: FieldType, depth: u32) RegisterError!FieldType {
        const arena = self.arena.allocator();
        return switch (t) {
            .list => |elem| blk: {
                const copy = try arena.create(FieldType);
                copy.* = try self.cloneType(elem.*, depth + 1);
                break :blk .{ .list = copy };
            },
            .nested => |fields| .{ .nested = try self.cloneFields(fields, depth + 1) },
            else => t,
        };
    }
};

/// A registration failure as a clause that follows a schema's name — "schema 'foundry:item'
/// <this>". One table, because the same failures arrive from a `.fdt` being compiled and
/// from a `.fpk` being loaded, and a mod author should not meet two vocabularies for one
/// refusal.
pub fn describeRegisterError(err: RegisterError) []const u8 {
    return switch (err) {
        error.MissingSchemaId => "has no identifier",
        error.InvalidVersion => "has version 0; versions start at 1",
        error.InvalidFieldName => "has a field name that is not lowercase letters, digits and underscores starting with a letter",
        error.DuplicateFieldName => "declares the same field twice",
        error.TooManyFields => "has more fields than the limit allows",
        error.NestingTooDeep => "nests deeper than the limit allows",
        error.InvalidSince => "has a field whose 'since' names a version the schema does not have",
        error.AddedFieldNeedsDefault => "adds a field that is neither optional nor defaulted, which content written before it existed could not satisfy",
        error.DefaultTypeMismatch => "has a default whose type is not the field's",
        error.DuplicateSchema => "is already registered at this version with a different declaration; two packages cannot disagree about what one schema is",
        error.NonAdditiveChange => "disagrees with the version already registered about a field they share, or drops one it declares; a version may only append",
        error.ListTooLong => "has a default list longer than the limit allows",
        error.OutOfMemory => "could not be registered: out of memory",
    };
}

pub const TypeError = error{
    WrongType,
    IntegerOutOfRange,
    /// An integer literal in a float field that the float cannot hold exactly.
    FloatNotExact,
    UnknownField,
    MissingField,
    DuplicateField,
    NestingTooDeep,
    ListTooLong,
};

/// Checks a value against a declared type.
///
/// This is the one place the typing rules of `content-schemas.md` §4.3 live, so the
/// parser, the schema registry and `fpack` cannot come to disagree about them.
pub fn checkValue(t: FieldType, v: Value, limits: Limits, depth: u32) TypeError!void {
    if (depth >= limits.max_nesting_depth) return error.NestingTooDeep;

    switch (t) {
        .bool => if (v != .bool) return error.WrongType,
        .string => if (v != .string) return error.WrongType,
        .id => if (v != .id) return error.WrongType,

        .i32 => try checkInt(i32, v),
        .i64 => try checkInt(i64, v),
        .u32 => try checkInt(u32, v),
        .u64 => try checkInt(u64, v),

        .f32 => try checkFloat(f32, v),
        .f64 => try checkFloat(f64, v),

        .list => |elem| {
            if (v != .list) return error.WrongType;
            if (v.list.len > limits.max_list_elements) return error.ListTooLong;
            for (v.list) |item| try checkValue(elem.*, item, limits, depth + 1);
        },

        .nested => |fields| {
            if (v != .nested) return error.WrongType;
            for (v.nested, 0..) |named, i| {
                for (v.nested[0..i]) |earlier| {
                    if (std.mem.eql(u8, earlier.name, named.name)) return error.DuplicateField;
                }
                const index = indexOfField(fields, named.name) orelse return error.UnknownField;
                try checkValue(fields[index].type, named.value, limits, depth + 1);
            }
            for (fields) |f| {
                if (f.presence != .required) continue;
                if (indexOfNamed(v.nested, f.name) == null) return error.MissingField;
            }
        },
    }
}

fn indexOfField(fields: []const Field, name: []const u8) ?usize {
    for (fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    return null;
}

fn indexOfNamed(values: []const value_mod.NamedValue, name: []const u8) ?usize {
    for (values, 0..) |nv, i| if (std.mem.eql(u8, nv.name, name)) return i;
    return null;
}

fn checkInt(comptime T: type, v: Value) TypeError!void {
    if (v != .int) return error.WrongType;
    if (v.int < std.math.minInt(T) or v.int > std.math.maxInt(T)) return error.IntegerOutOfRange;
}

fn checkFloat(comptime F: type, v: Value) TypeError!void {
    switch (v) {
        .float => {},
        // An integer literal is accepted in a float field when the conversion is exact,
        // and refused otherwise. Refusing `0` for a float would be pedantry; the ambiguity
        // ADR-0006 objected to in JSON is the *reader's* inability to tell an integer from
        // a float, and here the schema always can.
        .int => |i| if (!exactlyRepresentable(F, i)) return error.FloatNotExact,
        else => return error.WrongType,
    }
}

/// Whether `i` survives a trip through `F` unchanged.
///
/// Done in integer arithmetic rather than by converting and converting back, because the
/// round trip is only well-defined over part of `i128`'s range and the edges are exactly
/// where a wrong answer would be least visible. An integer is exact in a binary float when
/// its significant bits fit the mantissa and its magnitude fits the exponent.
fn exactlyRepresentable(comptime F: type, i: i128) bool {
    if (i == 0) return true;

    const mantissa_bits: u32 = std.math.floatMantissaBits(F) + 1; // plus the implicit bit
    const magnitude: u128 = @abs(i);
    const highest_bit: u32 = 127 - @as(u32, @clz(magnitude));

    // Not reachable for `f32` or `f64` from an `i128`: the largest magnitude an `i128`
    // holds is 2^127, and `f32`'s maximum exponent is already 127. The branch stays
    // because it is one third of what "exactly representable" means, and dropping it would
    // leave the function silently correct only for the types it happens to be called with.
    if (highest_bit > std.math.floatExponentMax(F)) return false;
    if (highest_bit < mantissa_bits) return true;

    const low_bits: u7 = @intCast(highest_bit + 1 - mantissa_bits);
    const mask = (@as(u128, 1) << low_bits) - 1;
    return magnitude & mask == 0;
}

const testing = std.testing;

fn testSchemaId(s: []const u8) SchemaId {
    return SchemaId.fromStringUnchecked(s);
}

test "the tag names are the .fdt spelling, so there is one table not two" {
    try testing.expect(FieldType.keyword("f32").? == .f32);
    try testing.expect(FieldType.keyword("string").? == .string);
    try testing.expect(FieldType.keyword("id").? == .id);
    // The composite types have punctuation, not keywords.
    try testing.expect(FieldType.keyword("list") == null);
    try testing.expect(FieldType.keyword("nested") == null);
    try testing.expect(FieldType.keyword("float") == null);
}

test "a registered schema is owned by the registry, not by its caller" {
    var registry: Registry = .init(testing.allocator, .default);
    defer registry.deinit(testing.allocator);

    var name_buf: [6]u8 = "weight".*;
    const handle = try registry.register(testing.allocator, .{
        .id = testSchemaId("foundry:item"),
        .fields = &.{.{ .name = &name_buf, .type = .f32, .presence = .{ .default = .{ .float = 0.0 } } }},
    });

    @memset(&name_buf, 'x');
    const stored = registry.get(handle).?;
    try testing.expectEqualStrings("weight", stored.fields[0].name);
    try testing.expectEqual(@as(u32, 1), registry.count());
    try testing.expectEqual(handle, registry.find(testSchemaId("foundry:item")).?);
}

test "a schema is refused before it is stored, and each refusal says which rule" {
    var registry: Registry = .init(testing.allocator, .default);
    defer registry.deinit(testing.allocator);
    const gpa = testing.allocator;
    const item = testSchemaId("foundry:item");

    try testing.expectError(error.MissingSchemaId, registry.register(gpa, .{
        .id = .none,
        .fields = &.{},
    }));
    try testing.expectError(error.InvalidVersion, registry.register(gpa, .{
        .id = item,
        .version = 0,
        .fields = &.{},
    }));
    try testing.expectError(error.InvalidFieldName, registry.register(gpa, .{
        .id = item,
        .fields = &.{.{ .name = "Weight", .type = .f32 }},
    }));
    try testing.expectError(error.DuplicateFieldName, registry.register(gpa, .{
        .id = item,
        .fields = &.{ .{ .name = "a", .type = .f32 }, .{ .name = "a", .type = .i32 } },
    }));
    try testing.expectError(error.DefaultTypeMismatch, registry.register(gpa, .{
        .id = item,
        .fields = &.{.{ .name = "a", .type = .f32, .presence = .{ .default = .{ .string = "x" } } }},
    }));
    try testing.expectError(error.InvalidSince, registry.register(gpa, .{
        .id = item,
        .version = 1,
        .fields = &.{.{ .name = "a", .type = .f32, .since = 2 }},
    }));
    try testing.expectError(error.AddedFieldNeedsDefault, registry.register(gpa, .{
        .id = item,
        .version = 2,
        .fields = &.{.{ .name = "a", .type = .f32, .since = 2 }},
    }));

    // Nothing above was stored.
    try testing.expectEqual(@as(u32, 0), registry.count());
}

test "a later version may append fields, and may not touch the ones already written" {
    var registry: Registry = .init(testing.allocator, .default);
    defer registry.deinit(testing.allocator);
    const gpa = testing.allocator;
    const item = testSchemaId("foundry:item");

    const v1: Schema = .{
        .id = item,
        .version = 1,
        .fields = &.{.{ .name = "weight", .type = .f32 }},
    };
    const handle = try registry.register(gpa, v1);

    // The same schema again is the same schema: two packages that both carry it agree,
    // and agreeing is not a conflict.
    try testing.expect(handle.eql(try registry.register(gpa, v1)));
    try testing.expectEqual(@as(u32, 1), registry.count());

    // A *different* one at the same version is two packages disagreeing about what
    // `foundry:item` is, and there is no safe answer to that.
    try testing.expectError(error.DuplicateSchema, registry.register(gpa, .{
        .id = item,
        .version = 1,
        .fields = &.{.{ .name = "different", .type = .string }},
    }));

    // Retyping an existing field would reinterpret bytes already compiled.
    try testing.expectError(error.NonAdditiveChange, registry.register(gpa, .{
        .id = item,
        .version = 2,
        .fields = &.{.{ .name = "weight", .type = .i32 }},
    }));
    // So would dropping one.
    try testing.expectError(error.NonAdditiveChange, registry.register(gpa, .{
        .id = item,
        .version = 2,
        .fields = &.{},
    }));
    // And an appended field with no value for old content is a break, not an extension.
    try testing.expectError(error.AddedFieldNeedsDefault, registry.register(gpa, .{
        .id = item,
        .version = 2,
        .fields = &.{
            .{ .name = "weight", .type = .f32 },
            .{ .name = "stack", .type = .u32, .since = 2 },
        },
    }));

    // Appending something old content can be read without is the one thing allowed.
    const extended = try registry.register(gpa, .{
        .id = item,
        .version = 2,
        .fields = &.{
            .{ .name = "weight", .type = .f32 },
            .{ .name = "stack", .type = .u32, .since = 2, .presence = .{ .default = .{ .int = 1 } } },
        },
    });

    // The same handle: everything already holding it follows to the new version.
    try testing.expectEqual(handle, extended);
    try testing.expectEqual(@as(u32, 1), registry.count());
    try testing.expectEqual(@as(u32, 2), registry.get(handle).?.version);
    try testing.expectEqual(@as(usize, 2), registry.get(handle).?.fields.len);
}

test "integer literals are range-checked against the field's actual type" {
    const l: Limits = .default;
    try checkValue(.i32, .{ .int = 2147483647 }, l, 0);
    try testing.expectError(error.IntegerOutOfRange, checkValue(.i32, .{ .int = 2147483648 }, l, 0));
    try checkValue(.u32, .{ .int = 4294967295 }, l, 0);
    try testing.expectError(error.IntegerOutOfRange, checkValue(.u32, .{ .int = -1 }, l, 0));
    try checkValue(.u64, .{ .int = std.math.maxInt(u64) }, l, 0);
    try checkValue(.i64, .{ .int = std.math.minInt(i64) }, l, 0);
    try testing.expectError(error.WrongType, checkValue(.i32, .{ .float = 1.0 }, l, 0));
}

test "an integer literal is accepted in a float field exactly when it survives the trip" {
    const l: Limits = .default;

    try checkValue(.f32, .{ .int = 0 }, l, 0);
    try checkValue(.f32, .{ .int = -1 }, l, 0);
    try checkValue(.f32, .{ .int = 16777216 }, l, 0); // 2^24, the last contiguous integer
    try testing.expectError(error.FloatNotExact, checkValue(.f32, .{ .int = 16777217 }, l, 0));
    // Large, but with enough trailing zeros to be exact — the case a naive range check
    // would refuse and a naive round-trip would get wrong at the edges.
    try checkValue(.f32, .{ .int = 1 << 100 }, l, 0);
    try testing.expectError(error.FloatNotExact, checkValue(.f32, .{ .int = (1 << 100) + 1 }, l, 0));
    // 2^126 is a single significant bit inside f32's exponent range, so it is exact —
    // which is also why the exponent branch in `exactlyRepresentable` cannot fire from an
    // i128, and is commented there rather than tested here.
    try checkValue(.f32, .{ .int = 1 << 126 }, l, 0);

    try checkValue(.f64, .{ .int = 9007199254740992 }, l, 0); // 2^53
    try testing.expectError(error.FloatNotExact, checkValue(.f64, .{ .int = 9007199254740993 }, l, 0));
    try checkValue(.f64, .{ .int = 1 << 126 }, l, 0);
    try checkValue(.f64, .{ .int = std.math.minInt(i64) }, l, 0);
}

test "an inline struct is checked field by field, both ways" {
    const l: Limits = .default;
    const light: FieldType = .{ .nested = &.{
        .{ .name = "radius", .type = .f32 },
        .{ .name = "colour", .type = .string, .presence = .optional },
    } };

    try checkValue(light, .{ .nested = &.{.{ .name = "radius", .value = .{ .float = 6.0 } }} }, l, 0);
    try testing.expectError(error.MissingField, checkValue(light, .{ .nested = &.{} }, l, 0));
    try testing.expectError(error.UnknownField, checkValue(light, .{ .nested = &.{
        .{ .name = "radius", .value = .{ .float = 6.0 } },
        .{ .name = "raidus", .value = .{ .float = 6.0 } },
    } }, l, 0));
    try testing.expectError(error.DuplicateField, checkValue(light, .{ .nested = &.{
        .{ .name = "radius", .value = .{ .float = 6.0 } },
        .{ .name = "radius", .value = .{ .float = 7.0 } },
    } }, l, 0));
    try testing.expectError(error.WrongType, checkValue(light, .{ .float = 6.0 }, l, 0));
}

test "a list checks every element against the element type" {
    const l: Limits = .default;
    const strings: FieldType = .{ .list = &.string };

    try checkValue(strings, .{ .list = &.{ .{ .string = "light" }, .{ .string = "fuel" } } }, l, 0);
    try checkValue(strings, .{ .list = &.{} }, l, 0);
    try testing.expectError(error.WrongType, checkValue(strings, .{ .list = &.{.{ .int = 1 }} }, l, 0));
    try testing.expectError(error.WrongType, checkValue(strings, .{ .string = "light" }, l, 0));
}

test "nesting is bounded, because the structure came out of a file" {
    var registry: Registry = .init(testing.allocator, .{ .max_nesting_depth = 3 });
    defer registry.deinit(testing.allocator);

    const deep: FieldType = .{ .nested = &.{.{ .name = "a", .type = .{ .nested = &.{
        .{ .name = "b", .type = .{ .nested = &.{.{ .name = "c", .type = .f32 }} } },
    } } }} };

    try testing.expectError(error.NestingTooDeep, registry.register(testing.allocator, .{
        .id = testSchemaId("foundry:deep"),
        .fields = &.{.{ .name = "root", .type = deep }},
    }));
}
