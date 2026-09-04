//! The schemas for the asset kinds the engine can load, and the extensions that derive one.
//!
//! An asset is content and its identity is its `ContentId` (ADR-0021), so a texture is a
//! record like any other and needs a record type. These are those types.
//!
//! **They are mechanisms, not content** (I5). An engine that can load a texture has not
//! thereby hardcoded a game: nothing here names an item, a level or a rule, and every one of
//! these schemas goes into the registry through the same `register` call a mod's `@schema`
//! directive uses (I6). A mod adding an asset kind the engine has never heard of registers
//! its own schema and its own loader and is not a special case.
//!
//! **Why the schema lives here and the loader does not.** `render2d` is L3 and owns what a
//! GPU texture *is*, so it registers the loader for `foundry:texture` at startup
//! (`assets.md` §5). But the *record* — a source path and, later, its sampling parameters —
//! is not a GPU concept, and `fpack` has to know it at compile time without linking a
//! renderer. So the schema is here, in the lowest module that can hold a `data.Schema`, and
//! the capability that consumes it points down at it from above.
//!
//! Design: `docs/design/assets.md` §2, §3 and §5.

const std = @import("std");
const data = @import("data");

const Allocator = std.mem.Allocator;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;

/// The field every asset kind has: where `fpack` reads the bytes from.
///
/// **Meaningful only at compile time.** It does not reach the runtime as identity, and no
/// runtime code resolves anything by it (ADR-0021). The name is frozen the moment content
/// outside this repository writes one.
pub const source_field = "source";

/// One asset kind: a record type, and the file extensions that produce one by derivation.
pub const Kind = struct {
    /// The schema's `namespace:name`, spelled out.
    ///
    /// A `SchemaId` is a hash and cannot be turned back into the name it came from, and
    /// this name is what `fpack` writes into a derived record and what a diagnostic uses to
    /// tell an author which record type to write by hand. The hash is derived from this
    /// string, so the two cannot drift apart.
    name: []const u8,
    schema: Schema,
    /// Lowercase, without the dot. A file with one of these extensions becomes a record of
    /// this kind unless an authored record already names it (`assets.md` §3).
    extensions: []const []const u8,
};

pub const texture_name = "foundry:texture";

/// An image loaded into a GPU texture.
///
/// One field for now. `assets.md` §2 sketches `filter` and `wrap` alongside it, and they
/// arrive with the loader that reads them — at which point the schema goes to version 2 with
/// defaults, which is precisely the case additive versioning exists for. Adding them now
/// would mean choosing how an enumeration is spelled in `.fdt` with nothing to check the
/// choice against, and the type list is closed (`content-schemas.md` §3).
pub const texture: Schema = .{
    .id = SchemaId.fromStringUnchecked(texture_name),
    .version = 1,
    .fields = &.{
        .{ .name = source_field, .type = .string },
    },
};

/// Every asset kind the engine itself defines, in a fixed order.
///
/// Fixed because `fpack` walks it to decide what a file becomes, and I9 wants that answer to
/// depend on the package and nothing else.
pub const kinds = [_]Kind{
    .{ .name = texture_name, .schema = texture, .extensions = &.{"png"} },
};

/// The kind a file extension derives, or null if that extension is not an asset.
///
/// `extension` is without the dot and is matched case-sensitively, because derivation
/// transforms nothing (`assets.md` §3): `SPRITES.PNG` is not a `png`, and saying so is
/// better than guessing which half of the name to lowercase.
pub fn kindForExtension(extension: []const u8) ?*const Kind {
    for (&kinds) |*kind| {
        for (kind.extensions) |candidate| {
            if (std.mem.eql(u8, candidate, extension)) return kind;
        }
    }
    return null;
}

/// The kind a schema id names, or null if it is not an asset kind at all.
pub fn kindForSchema(schema_id: SchemaId) ?*const Kind {
    for (&kinds) |*kind| {
        if (kind.schema.id.eql(schema_id)) return kind;
    }
    return null;
}

/// Registers every engine-defined asset schema.
///
/// Called by `fpack` before it compiles a package and by the engine before it loads one, so
/// that both see the same record types. Registering them twice is not an error — the
/// registry accepts a declaration that agrees with what it holds (`content-schemas.md` §3).
pub fn registerAll(gpa: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    for (&kinds) |kind| _ = try registry.register(gpa, kind.schema);
}

const testing = std.testing;

test "every asset kind has a source field, and it is field zero" {
    for (&kinds) |kind| {
        try testing.expectEqual(@as(?u32, 0), kind.schema.fieldIndex(source_field));
        try testing.expect(kind.schema.fields[0].type == .string);
    }
}

test "extensions map to kinds, and nothing else does" {
    try testing.expect(kindForExtension("png") == &kinds[0]);
    try testing.expect(kindForExtension("PNG") == null);
    try testing.expect(kindForExtension("txt") == null);
    try testing.expect(kindForExtension("") == null);
}

test "a kind's name and its id are the same fact twice" {
    for (&kinds) |*kind| {
        try testing.expect(kind.schema.id.eql(SchemaId.fromStringUnchecked(kind.name)));
        try testing.expect(kindForSchema(kind.schema.id) == kind);
    }
    try testing.expect(kindForSchema(SchemaId.fromStringUnchecked("foundry:item")) == null);
}

test "the engine's asset schemas register, and register twice without complaint" {
    const gpa = testing.allocator;
    var registry: Registry = .init(gpa, .default);
    defer registry.deinit(gpa);

    try registerAll(gpa, &registry);
    try testing.expectEqual(@as(u32, kinds.len), registry.count());

    // The engine registers these at startup and `fpack` registers them at compile time; a
    // process that does both must not be a conflict.
    try registerAll(gpa, &registry);
    try testing.expectEqual(@as(u32, kinds.len), registry.count());

    const found = registry.lookup(SchemaId.fromStringUnchecked("foundry:texture")).?;
    try testing.expectEqualStrings(source_field, found.fields[0].name);
}
