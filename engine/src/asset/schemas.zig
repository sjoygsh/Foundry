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
const Record = data.store.Record;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;
const Value = data.Value;

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

/// How the sampler filters and how it addresses outside `[0,1]`.
///
/// **Strings, because the type list is closed** (`content-schemas.md` §3): there is no enum
/// type and adding one would cost a text form, a binary form and a validator for a case an
/// inline struct does not compose. So the domain is checked by the loader that reads them
/// rather than by the checker, and an unrecognised spelling is a warning naming the legal
/// set, not a texture that fails to appear (§4: a failed load must stay diagnosable, and a
/// missing sprite is less diagnosable than a wrong-looking one).
pub const filter_field = "filter";
pub const wrap_field = "wrap";

pub const texture_name = "foundry:texture";

/// An image loaded into a GPU texture.
///
/// **Version 2, and version 1 content still loads.** `source` was the whole of version 1;
/// `filter` and `wrap` arrived with the loader that reads them, appended with defaults —
/// which is exactly the case additive versioning exists for and the cheap half of I8. A
/// package compiled before they existed is read against the version it carries and fills
/// the rest from these defaults (`store.Record.missingDefault`), so nothing has to be
/// recompiled to keep working.
pub const texture: Schema = .{
    .id = SchemaId.fromStringUnchecked(texture_name),
    .version = 2,
    .fields = &.{
        .{ .name = source_field, .type = .string },
        .{ .name = filter_field, .type = .string, .since = 2, .presence = .{ .default = .{ .string = "nearest" } } },
        .{ .name = wrap_field, .type = .string, .since = 2, .presence = .{ .default = .{ .string = "clamp" } } },
    },
};

pub const tilegrid_name = "foundry:tilegrid";

/// A grid of tile ids: the bulk of a tilemap, kept out of content text.
///
/// The record is nothing but a `source`, because everything else about a grid — its width,
/// its height, its numbers — is in the file the source names, where a hundred thousand
/// integers belong (`tilemaps-and-collision.md` §9). What the grid *means* is a
/// `foundry:tilemap.layer`'s business, not this record's: the same grid drawn with two
/// tilesets is two layers over one asset.
pub const tilegrid: Schema = .{
    .id = SchemaId.fromStringUnchecked(tilegrid_name),
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
    .{ .name = tilegrid_name, .schema = tilegrid, .extensions = &.{"fgrid"} },
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

/// A string field of `record`, read against `newest` and filled from its default when the
/// record's own package predates the field.
///
/// A loader is compiled against the newest schema it knows — the constants above — while a
/// record it is handed was laid out against whatever version its package shipped. That gap
/// is what I8's additive versioning is for, and this is the two-line composition that
/// closes it: `Fields` can only answer for the fields its own version had, and
/// `missingDefault` supplies the rest.
///
/// **Here rather than in `data`.** It composes two of that module's primitives and adds no
/// third; `data`'s surface is seen by mod authors and is a compatibility decision
/// (CLAUDE.md §7), so a convenience with one consumer lives with the consumer.
pub fn stringField(record: Record, newest: Schema, name: []const u8) ?[]const u8 {
    const index = newest.fieldIndex(name) orelse return null;
    // A malformed block is the package's problem, not this call's: report absence and let
    // the loader's own read of `source` be the one that refuses the record.
    if (record.fields.stringAt(index) catch null) |present| return present;
    return switch (record.missingDefault(newest, index) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

const testing = std.testing;

test "every asset kind has a source field, and it is field zero" {
    for (&kinds) |kind| {
        try testing.expectEqual(@as(?u32, 0), kind.schema.fieldIndex(source_field));
        try testing.expect(kind.schema.fields[0].type == .string);
        // Field zero is `source` in every version, because versioning is additive: a
        // reader of version 1 content finds it at the same offset a version 2 reader does.
        try testing.expectEqual(@as(u32, 1), kind.schema.fields[0].since);
    }
}

test "a field added after version 1 carries a default, or old content could not be read" {
    for (&kinds) |kind| {
        for (kind.schema.fields) |field| {
            if (field.since == 1) continue;
            try testing.expect(field.presence != .required);
        }
    }
}

test "extensions map to kinds, and nothing else does" {
    try testing.expect(kindForExtension("png") == &kinds[0]);
    try testing.expect(kindForExtension("fgrid") == &kinds[1]);
    try testing.expect(kindForExtension("PNG") == null);
    try testing.expect(kindForExtension("txt") == null);
    try testing.expect(kindForExtension("") == null);
}

test "no two asset kinds claim the same extension" {
    // A file would otherwise become whichever kind is listed first, which is a coin toss
    // decided by the order of a table nobody thinks about.
    for (&kinds, 0..) |kind, i| {
        for (kind.extensions) |extension| {
            for (kinds[i + 1 ..]) |other| {
                for (other.extensions) |candidate| {
                    try testing.expect(!std.mem.eql(u8, extension, candidate));
                }
            }
        }
    }
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
