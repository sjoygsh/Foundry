//! Reading a `foundry:mod` record out of a compiled package.
//!
//! **A candidate's manifest is read from its `.fpk` alone**, with nothing merged and no
//! store in existence. The store's own resolution established that a package can be read
//! with nothing but itself — every package carries the schemas its records use — and this
//! is the consumer that property was predicted for: finding out what is installed must not
//! require deciding what to load, because what to load is the answer.
//!
//! Everything here is untrusted input. A manifest arrives in a file somebody else wrote,
//! so every absence, every disagreement and every malformed field is a returned error
//! naming what was wrong, never an assertion (`CLAUDE.md` §7).
//!
//! Design: `docs/design/public-abi.md` §11 and §12.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const schemas = @import("schemas.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;

pub const Error = error{
    /// The package contains no `foundry:mod` record. Every package has one (ADR-0027),
    /// including the engine's own, so this is a package that was not compiled by a
    /// current `fpack` — or is not a Foundry package at all.
    NoManifest,
    /// More than one. A package describes itself once.
    MultipleManifests,
    /// The manifest record's content id is not the package's own id. The two are the same
    /// thing by construction, so a package where they differ has been edited by hand and
    /// nothing else it says can be believed.
    ManifestIdMismatch,
    /// The `version` field disagrees with the header. Same reasoning.
    ManifestVersionMismatch,
    /// The package's copy of `foundry:mod` is missing a field this build requires.
    ManifestSchemaMismatch,
    /// A required field is absent, or a field holds something its type cannot.
    ManifestMalformed,
    /// `native` is not a bare name — it has a separator, a dot, or is empty.
    ///
    /// Checked here rather than by whoever opens the library, because a manifest naming a
    /// path is a manifest to refuse, not a load to attempt carefully.
    InvalidNativeName,
} || Allocator.Error;

pub const Range = struct {
    min: u32 = 1,
    max: ?u32 = null,

    pub fn accepts(self: Range, version: u32) bool {
        if (version < self.min) return false;
        if (self.max) |m| if (version > m) return false;
        return true;
    }
};

/// What must load before this package.
///
/// **The id is a hash and carries no spelling**, because an `id`-typed field is eight
/// bytes in a compiled package and that is the format working as designed. `resolve`
/// recovers the name from whichever candidate has it; a dependency on a package *nobody*
/// has installed is the one diagnostic that can only print a number, which is recorded as
/// a known limitation in `public-abi.md` §18 rather than worked around here.
pub const Requirement = struct {
    id: ContentId,
    range: Range = .{},
};

/// A package's own description of itself, with every string owned by the caller's arena.
///
/// Owned rather than borrowed because the `.fpk` bytes it was read from are freed as soon
/// as discovery moves to the next candidate, and a manifest outlives that by design: the
/// whole point is to hold every candidate's manifest at once and then decide.
pub const Manifest = struct {
    /// The package's content id, which is its identity (I2, ADR-0027).
    id: ContentId,
    /// The spelling of `id`, from the package header.
    id_name: []const u8,
    /// The package's own version. Ranges in other packages' `requires` are against this.
    version: u32,

    name: []const u8,
    license: []const u8,
    summary: ?[]const u8 = null,
    url: ?[]const u8 = null,
    authors: []const []const u8 = &.{},
    requires: []const Requirement = &.{},
    abi: ?Range = null,
    native: ?[]const u8 = null,

    /// Whether this mod has code, which is the only thing that distinguishes a Tier 3 mod
    /// from a Tier 1 one (ADR-0027).
    pub fn hasCode(self: Manifest) bool {
        return self.native != null;
    }
};

/// Reads the manifest out of an already-opened package.
///
/// `arena` owns every string in the result. `reader` is borrowed and may be closed the
/// moment this returns.
pub fn read(arena: Allocator, reader: *const data.fpk.Reader) Error!Manifest {
    const schema = reader.schemaFor(schemas.manifest.id) orelse return error.NoManifest;

    var found: ?data.fpk.RecordView = null;
    var index: u32 = 0;
    while (index < reader.record_count) : (index += 1) {
        const view = reader.record(index) orelse return error.ManifestMalformed;
        if (!view.schema_id.eql(schemas.manifest.id)) continue;
        if (found != null) return error.MultipleManifests;
        found = view;
    }
    const view = found orelse return error.NoManifest;

    // The manifest record *is* the package's identity, so these two cannot be allowed to
    // disagree: everything downstream — the load order, the override chain, a mod
    // manager's list — keys off one id, and a package holding two is a package that means
    // different things to different readers.
    if (!view.id.eql(reader.id)) return error.ManifestIdMismatch;

    const fields = reader.fieldsOf(view, schema.*);

    var out: Manifest = .{
        .id = reader.id,
        .id_name = try arena.dupe(u8, reader.name),
        .version = reader.version,
        .name = "",
        .license = "",
    };

    out.name = try requiredString(arena, schema.*, fields, schemas.name_field);
    out.license = try requiredString(arena, schema.*, fields, schemas.license_field);

    const declared = try requiredInt(schema.*, fields, schemas.version_field);
    if (declared < 0 or declared > std.math.maxInt(u32)) return error.ManifestMalformed;
    if (@as(u32, @intCast(declared)) != reader.version) return error.ManifestVersionMismatch;

    out.summary = try optionalString(arena, schema.*, fields, schemas.summary_field);
    out.url = try optionalString(arena, schema.*, fields, schemas.url_field);
    out.authors = try readAuthors(arena, schema.*, fields);
    out.requires = try readRequires(arena, schema.*, fields);
    out.abi = try readAbi(schema.*, fields);
    out.native = try readNative(arena, schema.*, fields);

    return out;
}

// -- field readers -----------------------------------------------------------------
//
// Each takes the *package's own* copy of the schema rather than this build's, because a
// package is read against the version it was compiled with (`content-schemas.md` §6). A
// field this build knows and that copy lacks is absent, which is exactly right for an
// optional one and a schema disagreement for a required one.

fn indexOf(schema: data.Schema, name: []const u8) ?u32 {
    return schema.fieldIndex(name);
}

fn requiredString(arena: Allocator, schema: data.Schema, fields: data.fpk.Fields, name: []const u8) Error![]const u8 {
    const i = indexOf(schema, name) orelse return error.ManifestSchemaMismatch;
    const text = (fields.stringAt(i) catch return error.ManifestMalformed) orelse return error.ManifestMalformed;
    return arena.dupe(u8, text);
}

fn optionalString(arena: Allocator, schema: data.Schema, fields: data.fpk.Fields, name: []const u8) Error!?[]const u8 {
    const i = indexOf(schema, name) orelse return null;
    const text = (fields.stringAt(i) catch return error.ManifestMalformed) orelse return null;
    return try arena.dupe(u8, text);
}

fn requiredInt(schema: data.Schema, fields: data.fpk.Fields, name: []const u8) Error!i128 {
    const i = indexOf(schema, name) orelse return error.ManifestSchemaMismatch;
    return (fields.intAt(i) catch return error.ManifestMalformed) orelse return error.ManifestMalformed;
}

fn u32At(fields: data.fpk.Fields, i: u32) Error!?u32 {
    const raw = (fields.intAt(i) catch return error.ManifestMalformed) orelse return null;
    if (raw < 0 or raw > std.math.maxInt(u32)) return error.ManifestMalformed;
    return @intCast(raw);
}

fn readAuthors(arena: Allocator, schema: data.Schema, fields: data.fpk.Fields) Error![]const []const u8 {
    const i = indexOf(schema, schemas.authors_field) orelse return &.{};
    const list = (fields.listAt(i) catch return error.ManifestMalformed) orelse return &.{};

    const out = try arena.alloc([]const u8, list.len);
    for (out, 0..) |*slot, n| {
        const v = (list.valueAt(arena, @intCast(n)) catch return error.ManifestMalformed) orelse
            return error.ManifestMalformed;
        slot.* = switch (v) {
            .string => |text| text,
            else => return error.ManifestMalformed,
        };
    }
    return out;
}

fn readRequires(arena: Allocator, schema: data.Schema, fields: data.fpk.Fields) Error![]const Requirement {
    const i = indexOf(schema, schemas.requires_field) orelse return &.{};
    const list = (fields.listAt(i) catch return error.ManifestMalformed) orelse return &.{};

    const out = try arena.alloc(Requirement, list.len);
    for (out, 0..) |*slot, n| {
        const nested = (list.nestedAt(@intCast(n)) catch return error.ManifestMalformed) orelse
            return error.ManifestMalformed;
        slot.* = .{
            .id = (nested.idAt(0) catch return error.ManifestMalformed) orelse return error.ManifestMalformed,
            .range = .{
                .min = (try u32At(nested, 1)) orelse 1,
                .max = try u32At(nested, 2),
            },
        };
        if (slot.range.max) |m| if (m < slot.range.min) return error.ManifestMalformed;
    }
    return out;
}

fn readAbi(schema: data.Schema, fields: data.fpk.Fields) Error!?Range {
    const i = indexOf(schema, schemas.abi_field) orelse return null;
    const nested = (fields.nestedAt(i) catch return error.ManifestMalformed) orelse return null;
    const range: Range = .{
        .min = (try u32At(nested, 0)) orelse return error.ManifestMalformed,
        .max = try u32At(nested, 1),
    };
    if (range.max) |m| if (m < range.min) return error.ManifestMalformed;
    return range;
}

fn readNative(arena: Allocator, schema: data.Schema, fields: data.fpk.Fields) Error!?[]const u8 {
    const text = try optionalString(arena, schema, fields, schemas.native_field) orelse return null;
    if (!isBareName(text)) return error.InvalidNativeName;
    return text;
}

/// Whether a `native` value is a bare library name.
///
/// The loader decorates it — `libfoo.dylib`, `foo.dll`, `libfoo.so` — so what belongs here
/// is `foo` and nothing else. A separator, a dot or an empty string is refused **at the
/// manifest**, which is the difference between "this package is not one we will load" and
/// "we tried to open something outside the mod's directory and it went well enough".
pub fn isBareName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "a bare native name is letters, digits, underscore and dash, and nothing else" {
    try testing.expect(isBareName("brighter"));
    try testing.expect(isBareName("my_mod-2"));

    // Every one of these is a path trying to look like a name.
    try testing.expect(!isBareName(""));
    try testing.expect(!isBareName("libbrighter.dylib"));
    try testing.expect(!isBareName("../evil"));
    try testing.expect(!isBareName("dir/mod"));
    try testing.expect(!isBareName("dir\\mod"));
    try testing.expect(!isBareName("mod.so"));
    try testing.expect(!isBareName("a" ** 65));
}

test "a range with no maximum accepts everything at or above its minimum" {
    const any: Range = .{ .min = 1 };
    try testing.expect(any.accepts(1));
    try testing.expect(any.accepts(std.math.maxInt(u32)));
    try testing.expect(!any.accepts(0));

    const bounded: Range = .{ .min = 2, .max = 4 };
    try testing.expect(!bounded.accepts(1));
    try testing.expect(bounded.accepts(2));
    try testing.expect(bounded.accepts(4));
    try testing.expect(!bounded.accepts(5));
}

test "a manifest with no code is a Tier 1 mod, which is most of them" {
    const content_only: Manifest = .{ .id = .{ .hash = 1 }, .id_name = "a:b", .version = 1, .name = "A", .license = "MIT" };
    try testing.expect(!content_only.hasCode());

    var with_code = content_only;
    with_code.native = "brighter";
    try testing.expect(with_code.hasCode());
}
