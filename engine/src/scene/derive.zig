//! `comptime` registration: a Zig struct becomes a `ComponentTypeInfo`.
//!
//! ADR-0010 is precise about what this is allowed to be. Native code registers through
//! `comptime` helpers that **produce** the runtime registration data — it does not get a
//! second, faster registration path. Everything here ends up in the same struct a mod fills
//! in through the C ABI at M7, and the registry cannot tell them apart (I6). If this file
//! ever becomes the only way to register a component type, ADR-0010 has been undone.
//!
//! What it derives, from one struct:
//!
//! * the `data.Schema` — field names, types and defaults, so content and saves describe the
//!   component the same way the Zig type does;
//! * `deserialize`, which fills the struct from a record's fields;
//! * `serialize`, which writes it back into a field block — generated **beside**
//!   `deserialize` rather than separately, because two functions that disagree about which
//!   slot a field lives in produce a save that loads without complaint and is wrong;
//! * `construct`, when every field has a Zig default, so a component created without a value
//!   starts at those defaults rather than at zero.
//!
//! **A field that does not project onto the closed type list is a compile error naming it**
//! (`content-schemas.md` §3). That is the whole point of doing this at `comptime`: the
//! alternative is a component type that registers happily and then cannot be saved.
//!
//! Design: `docs/design/entity-storage.md` §3 and §6.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const component = @import("component.zig");
const entity_mod = @import("entity.zig");

const ComponentTypeInfo = component.ComponentTypeInfo;
const Entity = entity_mod.Entity;

pub const DeserializeError = component.DeserializeError;
pub const SerializeError = component.SerializeError;

/// Produces the registration data for a component type from a Zig struct.
///
/// The struct declares its own name:
///
/// ```zig
/// pub const Transform = struct {
///     pub const component = "foundry:transform";
///     x: f32 = 0,
///     y: f32 = 0,
/// };
///
/// const transform = try world.registerComponent(scene.componentType(Transform));
/// ```
///
/// `pub const component_version: u32` raises the schema version; it defaults to 1. Raising
/// it is how a component grows a field without invalidating content and saves written
/// against the old shape (I8) — and `data.Registry` refuses a version bump that is not
/// additive, so the mistake is caught at registration rather than at load.
pub fn componentType(comptime T: type) ComponentTypeInfo {
    return Info(T).value;
}

/// The registration data for `T`, as a `comptime` constant.
///
/// A container declaration rather than a function body, so everything below — the derived
/// field list, the nested defaults, the generated functions — is evaluated once at
/// `comptime` and anchored in static memory. A function computing it would have to return
/// pointers to its own locals.
fn Info(comptime T: type) type {
    return struct {
        const name = nameOf(T);
        const value: ComponentTypeInfo = .{
            .schema = .{
                .id = data.SchemaId.parse(name) catch @compileError(
                    "component name '" ++ name ++ "' on " ++ @typeName(T) ++
                        " is not a valid namespace:name",
                ),
                .version = if (@hasDecl(T, "component_version")) T.component_version else 1,
                .fields = fieldsOf(T),
            },
            .name = name,
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .construct = if (allDefaulted(T)) &Codec(T).construct else null,
            .deserialize = &Codec(T).deserialize,
            .serialize = &Codec(T).serialize,
        };
    };
}

fn nameOf(comptime T: type) []const u8 {
    if (!@hasDecl(T, "component")) @compileError(
        @typeName(T) ++ " has no `pub const component` naming it, so it cannot be a " ++
            "component type. Add one: `pub const component = \"namespace:name\";`",
    );
    return T.component;
}

/// Whether `T{}` is legal — every field has a default.
fn allDefaulted(comptime T: type) bool {
    for (@typeInfo(T).@"struct".fields) |f| {
        if (f.default_value_ptr == null) return false;
    }
    return true;
}

fn fieldsOf(comptime T: type) []const data.Field {
    comptime {
        const info = switch (@typeInfo(T)) {
            .@"struct" => |s| s,
            else => @compileError(@typeName(T) ++ " is not a struct, so it cannot be a component type"),
        };

        var fields: [info.fields.len]data.Field = undefined;
        for (info.fields, 0..) |f, i| {
            if (f.is_comptime) @compileError(
                "component field " ++ @typeName(T) ++ "." ++ f.name ++ " is comptime, " ++
                    "which has no runtime bytes to store or serialize",
            );
            if (!data.id.isValidSegment(f.name)) @compileError(
                "component field " ++ @typeName(T) ++ "." ++ f.name ++ " is not a legal " ++
                    "field name: lowercase letters, digits and underscores, starting with a letter",
            );
            fields[i] = .{
                .name = f.name,
                .type = fieldTypeOf(f.type, @typeName(T) ++ "." ++ f.name),
                .presence = presenceOf(f, @typeName(T) ++ "." ++ f.name),
            };
        }
        const frozen = fields;
        return &frozen;
    }
}

fn fieldTypeOf(comptime F: type, comptime where: []const u8) data.FieldType {
    // Both before the `@typeInfo` switch: each is an extern struct, and each means
    // something the struct's shape does not say.
    if (F == core.ContentId) return .id;
    // An entity reference is its handle's published 64-bit packing. This is safe only
    // because a save preserves entity identity exactly (§9) — without that guarantee it
    // would be a number that means nothing on the other side of a reload.
    if (F == Entity) return .u64;

    return switch (@typeInfo(F)) {
        .bool => .bool,
        .int => if (F == i32) .i32 else if (F == i64) .i64 else if (F == u32) .u32 else if (F == u64) .u64 else @compileError(
            where ++ " is " ++ @typeName(F) ++ ", which content cannot express. The integer " ++
                "types are i32, i64, u32 and u64 — the list is closed on purpose " ++
                "(content-schemas.md §3), and a narrower field would have to widen on the " ++
                "way out and range-check on the way back in",
        ),
        .float => if (F == f32) .f32 else if (F == f64) .f64 else @compileError(
            where ++ " is " ++ @typeName(F) ++ "; the float types are f32 and f64",
        ),
        .@"struct" => .{ .nested = fieldsOf(F) },
        .pointer => @compileError(
            where ++ " is a pointer or slice. A component holds no pointers (I1) and " ++
                "cannot allocate while being read, so variable-length data is referenced " ++
                "by content id instead: make it a `core.ContentId`",
        ),
        .array => @compileError(
            where ++ " is an array. Lists are not yet derivable, because a list's elements " ++
                "live outside the block that holds the rest of the component — that is part " ++
                "of the save format and arrives with it. A fixed set of named values is an " ++
                "inline struct today, which is also what content-schemas.md §3 prefers",
        ),
        else => @compileError(
            where ++ " is " ++ @typeName(F) ++ ", which does not project onto the closed " ++
                "type list. Give the type its own `deserialize` if it needs a representation " ++
                "of its own",
        ),
    };
}

fn presenceOf(comptime f: std.builtin.Type.StructField, comptime where: []const u8) data.Presence {
    const default = f.defaultValue() orelse return .required;
    return .{ .default = valueOf(f.type, default, where) };
}

/// A Zig default value as the `data.Value` the schema declares.
///
/// The two have to agree exactly: `data.Registry` checks a default against its field's type
/// and refuses a mismatch, and a schema whose default differs from the Zig one would mean
/// content and code disagreeing about what "unspecified" means.
fn valueOf(comptime F: type, comptime v: F, comptime where: []const u8) data.Value {
    if (F == core.ContentId) return .{ .id = v };
    if (F == Entity) return .{ .int = v.bits() };

    return switch (@typeInfo(F)) {
        .bool => .{ .bool = v },
        .int => .{ .int = v },
        .float => .{ .float = v },
        .@"struct" => comptime blk: {
            const info = @typeInfo(F).@"struct";
            var named: [info.fields.len]data.NamedValue = undefined;
            for (info.fields, 0..) |sub, i| {
                const sub_default = sub.defaultValue() orelse @compileError(
                    where ++ " has a default, but its field '" ++ sub.name ++ "' does not. " ++
                        "An inline struct's default has to name every value in it, so either " ++
                        "give that field a default too or drop the outer one",
                );
                named[i] = .{
                    .name = sub.name,
                    .value = valueOf(sub.type, sub_default, where ++ "." ++ sub.name),
                };
            }
            const frozen = named;
            break :blk .{ .nested = &frozen };
        },
        else => unreachable, // `fieldTypeOf` already refused everything else.
    };
}

/// The generated functions for `T`. A struct rather than free functions so each `T` gets
/// its own instantiation and the function pointers are distinct.
fn Codec(comptime T: type) type {
    return struct {
        fn construct(_: ?*anyopaque, out: [*]u8) void {
            const value: *T = @ptrCast(@alignCast(out));
            value.* = .{};
        }

        fn deserialize(_: ?*anyopaque, fields: data.fpk.Fields, out: [*]u8) DeserializeError!void {
            const value: *T = @ptrCast(@alignCast(out));
            try readStruct(T, value, fields);
        }

        fn serialize(_: ?*anyopaque, bytes: [*]const u8, block: data.fpk.Block) SerializeError!void {
            const value: *const T = @ptrCast(@alignCast(bytes));
            try writeStruct(T, value.*, block);
        }
    };
}

/// Writes every field of `value` into `block`, matching by **position**.
///
/// The exact mirror of `readStruct`, and the reason the pair is generated together: a
/// serializer and a deserializer that disagree about which slot a field lives in produce a
/// file that loads without complaint and is wrong. Here neither can drift, because both
/// walk the same struct in the same order against the same derived schema.
///
/// A block laid out for a **later** version of the schema has fields this struct does not:
/// they are left unset, which reads back as absent, which is what the reader already
/// treats as "keep the default".
fn writeStruct(comptime S: type, value: S, block: data.fpk.Block) SerializeError!void {
    const count = block.fields.len;
    inline for (@typeInfo(S).@"struct".fields, 0..) |f, i| {
        if (i < count) try writeField(f.type, @field(value, f.name), block, i);
    }
}

fn writeField(comptime F: type, value: F, block: data.fpk.Block, index: usize) SerializeError!void {
    if (F == core.ContentId) return block.set(index, .{ .id = value });
    // The published 64-bit packing, and it survives a reload only because a save preserves
    // entity identity exactly (§9). `readField` unpacks the same way.
    if (F == Entity) return block.set(index, .{ .int = value.bits() });

    switch (@typeInfo(F)) {
        .bool => try block.set(index, .{ .bool = value }),
        .int => try block.set(index, .{ .int = value }),
        .float => try block.set(index, .{ .float = value }),
        .@"struct" => try writeStruct(F, value, try block.nested(index)),
        else => unreachable,
    }
}

/// Fills `out` from `fields`, matching by **position**.
///
/// Position, not name, because a schema may only ever append (`content-schemas.md` §3), so
/// field *i* is field *i* in every version that has it. A record written against an older
/// version simply has fewer fields, and the ones it does not have keep whatever `construct`
/// put there — which is the Zig default when the type has one. That is the whole of I8's
/// forward compatibility for components, and it costs one comparison.
fn readStruct(comptime S: type, out: *S, fields: data.fpk.Fields) DeserializeError!void {
    const count = fields.count();
    inline for (@typeInfo(S).@"struct".fields, 0..) |f, i| {
        if (i < count) try readField(f.type, &@field(out, f.name), fields, @intCast(i));
    }
}

/// Reads one field, or leaves the value alone if the record does not have it.
///
/// Absence is not an error: an optional field the author omitted, and a field added in a
/// later schema version, both arrive this way. The existing value is the right answer for
/// both, which is why `construct` runs first.
fn readField(comptime F: type, out: *F, fields: data.fpk.Fields, index: u32) DeserializeError!void {
    if (F == core.ContentId) {
        if (try fields.idAt(index)) |v| out.* = v;
        return;
    }
    if (F == Entity) {
        if (try fields.intAt(index)) |v| {
            out.* = Entity.fromBits(std.math.cast(u64, v) orelse return error.ValueOutOfRange);
        }
        return;
    }

    switch (@typeInfo(F)) {
        .bool => if (try fields.boolAt(index)) |v| {
            out.* = v;
        },
        .int => if (try fields.intAt(index)) |v| {
            out.* = std.math.cast(F, v) orelse return error.ValueOutOfRange;
        },
        // Narrowing to f32 cannot lose a value that belongs there: the checker validated
        // the literal against f32 when the content was compiled, and a save writes an f32
        // back out. A value that does not belong there is a malformed file, and it arrives
        // as an infinity rather than as a wrong number.
        .float => if (try fields.floatAt(index)) |v| {
            out.* = @floatCast(v);
        },
        .@"struct" => if (try fields.nestedAt(index)) |nested| {
            try readStruct(F, out, nested);
        },
        else => unreachable,
    }
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const world_mod = @import("world.zig");

const Vec2 = struct { x: f32 = 0, y: f32 = 0 };

const Transform = struct {
    pub const component = "test:transform";
    x: f32 = 0,
    y: f32 = 0,
    flags: u32 = 0,
};

const Body = struct {
    pub const component = "test:body";
    position: Vec2 = .{},
    mass: f64 = 1.0,
    solid: bool = true,
    texture: core.ContentId = .none,
    target: Entity = .none,
};

/// The whole content pipeline, the way `fpack` and the engine run it: a derived schema
/// registered, text compiled against it, and a package read back. Nothing here is a stub —
/// the records these tests deserialize came out of a real `.fpk`.
const Harness = struct {
    gpa: std.mem.Allocator,
    registry: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: std.ArrayList(u8) = .empty,

    fn init(gpa: std.mem.Allocator) Harness {
        return .{
            .gpa = gpa,
            .registry = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
        };
    }

    fn deinit(self: *Harness) void {
        self.store.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        self.registry.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
    }

    fn registerSchema(self: *Harness, schema: data.Schema) !void {
        _ = try self.registry.register(self.gpa, schema);
    }

    /// Compiles `source` in namespace `test` and loads it. The records use schemas already
    /// in the registry and declare none of their own, which is exactly the shape of content
    /// that uses engine component types.
    fn load(self: *Harness, source: []const u8) !void {
        var doc = try data.parser.parse(self.gpa, "test.fdt", source, .{ .namespace = "test" }, &self.diags);
        defer doc.deinit(self.gpa);

        var pkg = try data.check.Package.init(self.gpa, "test:content", 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.registry, &self.diags);
        try data.fpk.write(self.gpa, &pkg, &self.registry, &self.bytes);

        _ = try self.store.add(self.gpa, "test:content", self.bytes.items, &self.registry, &self.diags);
    }

    fn record(self: *Harness, id: []const u8) !data.store.Record {
        return self.store.lookup(try data.id.contentId(id)) orelse error.NoSuchRecord;
    }
};

test "a schema is derived from a struct" {
    const info = componentType(Transform);

    try testing.expectEqualStrings("test:transform", info.name);
    try testing.expectEqual(@as(u32, 1), info.schema.version);
    try testing.expectEqual(@as(usize, 8 + 4), info.size);
    try testing.expectEqual(@as(usize, 3), info.schema.fields.len);

    try testing.expectEqualStrings("x", info.schema.fields[0].name);
    try testing.expect(info.schema.fields[0].type == .f32);
    try testing.expectEqualStrings("flags", info.schema.fields[2].name);
    try testing.expect(info.schema.fields[2].type == .u32);

    // A Zig default becomes the schema's default, so content and code cannot disagree
    // about what "unspecified" means.
    try testing.expect(info.schema.fields[0].presence == .default);
    try testing.expectEqual(@as(f64, 0), info.schema.fields[0].presence.default.float);

    // Every field has a default, so `T{}` is legal and the constructor is generated.
    try testing.expect(info.construct != null);
    try testing.expect(info.deserialize != null);
}

test "composite fields derive the types content can express" {
    const info = componentType(Body);
    const fields = info.schema.fields;

    try testing.expectEqual(@as(usize, 5), fields.len);
    // An inline struct, which is what content-schemas.md §3 prefers over a vector type.
    try testing.expect(fields[0].type == .nested);
    try testing.expectEqual(@as(usize, 2), fields[0].type.nested.len);
    try testing.expectEqualStrings("x", fields[0].type.nested[0].name);

    try testing.expect(fields[1].type == .f64);
    try testing.expect(fields[2].type == .bool);
    // An asset reference is a content id, because that is what an asset's identity is
    // (ADR-0021) — the runtime handle means nothing outside the process that issued it.
    try testing.expect(fields[3].type == .id);
    // An entity reference is its handle's packing, which only works because a save
    // preserves entity identity exactly.
    try testing.expect(fields[4].type == .u64);

    // The nested default names every value in it, which is what `checkValue` requires.
    try testing.expect(fields[0].presence == .default);
    try testing.expectEqual(@as(usize, 2), fields[0].presence.default.nested.len);
}

test "a derived schema is accepted by the registry that content is checked against" {
    const gpa = testing.allocator;
    var h: Harness = .init(gpa);
    defer h.deinit();

    // The real check: `data.Registry` validates field names, defaults and versioning, and
    // a derived schema has to pass exactly what a hand-written one does.
    try h.registerSchema(componentType(Transform).schema);
    try h.registerSchema(componentType(Body).schema);
    try testing.expectEqual(@as(u32, 2), h.registry.count());
}

test "a component is read out of a compiled package" {
    const gpa = testing.allocator;
    var h: Harness = .init(gpa);
    defer h.deinit();

    try h.registerSchema(componentType(Transform).schema);
    try h.load(
        \\transform test:player.transform { x 1.5  y -2.5  flags 7 }
    );

    const rec = try h.record("test:player.transform");
    var value: Transform = .{};
    try componentType(Transform).deserialize.?(null, rec.fields, @ptrCast(&value));

    try testing.expectEqual(@as(f32, 1.5), value.x);
    try testing.expectEqual(@as(f32, -2.5), value.y);
    try testing.expectEqual(@as(u32, 7), value.flags);
}

test "composite fields survive the round trip through a package" {
    const gpa = testing.allocator;
    var h: Harness = .init(gpa);
    defer h.deinit();

    try h.registerSchema(componentType(Body).schema);
    try h.load(
        \\body test:player.body {
        \\    position { x 3.0  y 4.0 }
        \\    mass     2.5
        \\    solid    false
        \\    texture  test:textures.hero
        \\    target   17179869187
        \\}
    );

    const rec = try h.record("test:player.body");
    var value: Body = .{};
    try componentType(Body).deserialize.?(null, rec.fields, @ptrCast(&value));

    try testing.expectEqual(@as(f32, 3.0), value.position.x);
    try testing.expectEqual(@as(f32, 4.0), value.position.y);
    try testing.expectEqual(@as(f64, 2.5), value.mass);
    try testing.expectEqual(false, value.solid);
    try testing.expect(value.texture.eql(try data.id.contentId("test:textures.hero")));
    // 17179869187 == (4 << 32) | 3 — entity 3, generation 4.
    try testing.expectEqual(@as(u32, 3), value.target.index);
    try testing.expectEqual(@as(u32, 4), value.target.generation);
}

test "a field the content omits keeps the value construct left" {
    const gpa = testing.allocator;
    var h: Harness = .init(gpa);
    defer h.deinit();

    try h.registerSchema(componentType(Body).schema);
    try h.load(
        \\body test:sparse.body { mass 9.0 }
    );

    const rec = try h.record("test:sparse.body");
    var value: Body = .{};
    componentType(Body).construct.?(null, @ptrCast(&value));
    try componentType(Body).deserialize.?(null, rec.fields, @ptrCast(&value));

    try testing.expectEqual(@as(f64, 9.0), value.mass);
    // The rest came from the schema's defaults, which are the struct's defaults — and
    // `solid` proves it, because zeroed bytes would have made it false.
    try testing.expectEqual(true, value.solid);
    try testing.expectEqual(@as(f32, 0), value.position.x);
    try testing.expect(value.target.isNone());
}

test "content written against an older schema version leaves the newer field alone" {
    const gpa = testing.allocator;
    var h: Harness = .init(gpa);
    defer h.deinit();

    // Version 1 of a component: two fields. Content is compiled against exactly this.
    const V1 = struct {
        pub const component = "test:health";
        current: u32 = 10,
        max: u32 = 10,
    };
    try h.registerSchema(componentType(V1).schema);
    try h.load(
        \\health test:goblin.health { current 4  max 6 }
    );
    const rec = try h.record("test:goblin.health");

    // This build has grown a third field. The record predates it, so the record simply has
    // fewer fields — and position matching means the two it does have still line up.
    const V2 = struct {
        pub const component = "test:health";
        pub const component_version: u32 = 2;
        current: u32 = 10,
        max: u32 = 10,
        regen: f32 = 1.5,
    };
    var value: V2 = .{};
    componentType(V2).construct.?(null, @ptrCast(&value));
    try componentType(V2).deserialize.?(null, rec.fields, @ptrCast(&value));

    try testing.expectEqual(@as(u32, 4), value.current);
    try testing.expectEqual(@as(u32, 6), value.max);
    try testing.expectEqual(@as(f32, 1.5), value.regen);

    // And the extension itself is legal: `data.Registry` refuses a non-additive bump, so
    // this passing is the proof that a derived version 2 appends rather than reinterprets.
    try h.registerSchema(componentType(V2).schema);
}

test "a value the field cannot hold is refused, not truncated" {
    const gpa = testing.allocator;
    var h: Harness = .init(gpa);
    defer h.deinit();

    // A package whose schema is *wider* than this build's struct — which is what a save or
    // a package from a build with a different definition looks like. The content is legal
    // against its own schema; the struct is what cannot hold it.
    try h.registerSchema(.{
        .id = try data.id.SchemaId.parse("test:wide"),
        .version = 1,
        .fields = &.{.{ .name = "n", .type = .i64, .presence = .{ .default = .{ .int = 0 } } }},
    });
    try h.load(
        \\wide test:big.value { n 5000000000 }
    );
    const rec = try h.record("test:big.value");

    const Narrow = struct {
        pub const component = "test:wide";
        n: i32 = 0,
    };
    var value: Narrow = .{};
    try testing.expectError(
        error.ValueOutOfRange,
        componentType(Narrow).deserialize.?(null, rec.fields, @ptrCast(&value)),
    );
}

test "a derived type registers and constructs through the world" {
    const gpa = testing.allocator;
    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);

    var world: world_mod.World = .init(gpa, &registry, .default);
    defer world.deinit();

    const body = try world.registerComponent(componentType(Body));
    const e = try world.create();

    // No initial value, so the generated constructor runs — and the Zig defaults are what
    // the component starts at, not zeroes. `mass` is the one that shows it.
    const bytes = try world.addComponent(e, body, null);
    const value: *Body = @ptrCast(@alignCast(bytes.ptr));
    try testing.expectEqual(@as(f64, 1.0), value.mass);
    try testing.expectEqual(true, value.solid);

    // And the registration is the ordinary one: its schema is in the same registry content
    // is checked against.
    try testing.expect(registry.lookup(try data.id.SchemaId.parse("test:body")) != null);
}

// -- serialize ---------------------------------------------------------------------

/// Writes `value` into a block and reads it straight back, which is what a save does with
/// a file in between. The block writer and the block reader are `data`'s, so what this
/// exercises is the generated pair rather than a stand-in for it.
fn roundTrip(gpa: std.mem.Allocator, comptime T: type, value: T) !T {
    const info = componentType(T);

    var w: data.BlockWriter = .{ .gpa = gpa };
    defer w.deinit();
    const block = try w.begin(info.schema.fields);
    try info.serialize.?(null, @ptrCast(&value), block);

    const blocks: data.Blocks = .{ .fields = w.fields.items, .strings = w.strings.items };
    var out: T = undefined;
    if (info.construct) |construct| construct(null, @ptrCast(&out)) else out = std.mem.zeroes(T);
    try info.deserialize.?(null, blocks.blockAt(block.base, info.schema.fields).?, @ptrCast(&out));
    return out;
}

test "a component survives a round trip through its own generated pair" {
    const gpa = testing.allocator;
    const value: Body = .{
        .position = .{ .x = 1.5, .y = -2.25 },
        .mass = 12.5,
        .solid = false,
        .texture = try data.id.contentId("test:tex.stone"),
        .target = .{ .index = 41, .generation = 7 },
    };
    const back = try roundTrip(gpa, Body, value);

    try testing.expectEqual(value.position.x, back.position.x);
    try testing.expectEqual(value.position.y, back.position.y);
    try testing.expectEqual(value.mass, back.mass);
    try testing.expectEqual(value.solid, back.solid);
    try testing.expect(value.texture.eql(back.texture));
    // The one that matters most: an entity reference is a number that only means anything
    // because a save preserves identity exactly (§9), so it has to come back bit-identical.
    try testing.expect(value.target.eql(back.target));
}

test "the extremes of every scalar type survive the round trip" {
    const gpa = testing.allocator;
    const Wide = struct {
        pub const component = "test:wide.scalars";
        a: i32 = 0,
        b: i64 = 0,
        c: u32 = 0,
        d: u64 = 0,
        e: f32 = 0,
        f: f64 = 0,
        g: bool = false,
    };
    const value: Wide = .{
        .a = std.math.minInt(i32),
        .b = std.math.minInt(i64),
        .c = std.math.maxInt(u32),
        .d = std.math.maxInt(u64),
        .e = 3.4028235e38,
        .f = -1.7976931348623157e308,
        .g = true,
    };
    const back = try roundTrip(gpa, Wide, value);
    try testing.expectEqual(value, back);
}

test "a marker component round-trips as an empty block" {
    const gpa = testing.allocator;
    const Marker = struct {
        pub const component = "test:marker.player";
    };
    _ = try roundTrip(gpa, Marker, .{});
    // What matters is that a type with no fields is not a special case anywhere: it lays
    // out a zero-length block and reads nothing back out of it.
    try testing.expectEqual(@as(usize, 0), componentType(Marker).schema.fields.len);
}

test "a component written by an older build keeps its defaults for the new fields" {
    const gpa = testing.allocator;
    // Version 1 of a component type, as an older build had it...
    const V1 = struct {
        pub const component = "test:grown";
        x: f32 = 0,
    };
    // ...and version 2, which appended a field with a default that is not zero.
    const V2 = struct {
        pub const component = "test:grown";
        pub const component_version: u32 = 2;
        x: f32 = 0,
        solid: bool = true,
    };

    var w: data.BlockWriter = .{ .gpa = gpa };
    defer w.deinit();
    const old = componentType(V1);
    const block = try w.begin(old.schema.fields);
    try old.serialize.?(null, @ptrCast(&V1{ .x = 4 }), block);

    // The new build reads the old block against the old schema the file carries — which is
    // what §9's type table is for — and the field the file predates keeps the *type's*
    // default rather than falling to zero.
    const blocks: data.Blocks = .{ .fields = w.fields.items, .strings = w.strings.items };
    const new = componentType(V2);
    var out: V2 = undefined;
    new.construct.?(null, @ptrCast(&out));
    try new.deserialize.?(null, blocks.blockAt(block.base, old.schema.fields).?, @ptrCast(&out));

    try testing.expectEqual(@as(f32, 4), out.x);
    try testing.expectEqual(true, out.solid);
}
