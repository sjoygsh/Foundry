//! `foundry:mod` — the manifest record type.
//!
//! **A mechanism, not content** (I5), and registered at runtime through the same call a
//! mod's `@schema` directive uses (I6). It sits beside `foundry:texture` and
//! `foundry:entity` for the reason `asset/schemas.zig` gives for those: `fpack` has to
//! know the record type to check a package, and the thing that *consumes* the record —
//! discovery, and later the native loader in `abi` — is somewhere else entirely.
//!
//! [ADR-0027](../../../docs/adr/0027-mods-are-content-packages.md) says a mod is a content
//! package and its manifest is a record inside it. This is that record.
//!
//! **Every field name here is frozen** the moment a package outside this repository writes
//! one, which is `CLAUDE.md` §7's rule at its sharpest: a manifest is the *first* thing a
//! mod author writes and the last thing that can be renamed.
//!
//! Design: `docs/design/public-abi.md` §11.

const std = @import("std");
const data = @import("data");

const Allocator = std.mem.Allocator;
const Field = data.Field;
const FieldType = data.FieldType;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;

pub const manifest_name = "foundry:mod";

// Field names, spelled once. A diagnostic and a reader both need them and a typo in either
// would be a field that silently reads as absent.
pub const name_field = "name";
pub const version_field = "version";
pub const license_field = "license";
pub const summary_field = "summary";
pub const authors_field = "authors";
pub const url_field = "url";
pub const requires_field = "requires";
pub const abi_field = "abi";
pub const native_field = "native";

/// One entry of `requires`: what must load first, and at what versions.
///
/// `min` defaults to 1 rather than being required, because "any version of it" is what a
/// dependency usually means and making every author write `min 1` would be ceremony. `max`
/// is optional and absent means unbounded — a mod author who has not tested against a
/// future version should not have to predict one.
pub const requirement_fields = [_]Field{
    .{ .name = "id", .type = .id },
    .{ .name = "min", .type = .u32, .presence = .{ .default = .{ .int = 1 } } },
    .{ .name = "max", .type = .u32, .presence = .optional },
};

const requirement_type: FieldType = .{ .nested = &requirement_fields };
const requires_type: FieldType = .{ .list = &requirement_type };

/// The ABI versions a mod's code was built against. Absent for a content-only mod.
///
/// **Against the ABI, not the engine release.** What a compiled mod is fragile against is
/// the table, and versioning against the thing that actually breaks is the difference
/// between a range that means something and one an author guesses at
/// (`public-abi.md` §11.1).
pub const abi_fields = [_]Field{
    .{ .name = "min", .type = .u32 },
    .{ .name = "max", .type = .u32, .presence = .optional },
};

const string_list: FieldType = .string;

/// A package's own description of itself.
///
/// The record's **content id is the package's content id** — not a separate name, not a
/// derived one. A package is identified by exactly one thing (I2), and the manifest is
/// where that one thing is written down; `fpack` reads the package's name and version from
/// here and there is nowhere else for them to disagree with it.
pub const manifest: Schema = .{
    .id = SchemaId.fromStringUnchecked(manifest_name),
    .version = 1,
    .fields = &.{
        .{ .name = name_field, .type = .string },
        .{ .name = version_field, .type = .u32 },
        // ADR-0016 asks for this, so that a mod author can state their terms and anyone
        // redistributing a pack knows what they are redistributing. Required, and not
        // defaulted: a license nobody chose is the one thing a default must not invent.
        .{ .name = license_field, .type = .string },
        .{ .name = summary_field, .type = .string, .presence = .optional },
        .{ .name = authors_field, .type = .{ .list = &string_list }, .presence = .optional },
        .{ .name = url_field, .type = .string, .presence = .optional },
        .{ .name = requires_field, .type = requires_type, .presence = .optional },
        .{ .name = abi_field, .type = .{ .nested = &abi_fields }, .presence = .optional },
        // The **base name** of the native library: no `lib`, no extension, no separator.
        // The loader decorates it per platform, so one package works on all three and no
        // mod author writes a platform conditional into content (`public-abi.md` §11.1).
        .{ .name = native_field, .type = .string, .presence = .optional },
    },
};

/// Registers `foundry:mod`.
///
/// Called by `fpack` before it compiles a package and by anything reading one, so both see
/// the same record type. Registering twice is not an error — the registry accepts a
/// declaration that agrees with what it holds (`content-schemas.md` §3).
pub fn registerAll(gpa: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    _ = try registry.register(gpa, manifest);
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "the manifest schema registers, and registering it twice agrees" {
    var registry: Registry = .init(testing.allocator, .default);
    defer registry.deinit(testing.allocator);

    try registerAll(testing.allocator, &registry);
    try registerAll(testing.allocator, &registry);
    try testing.expect(registry.find(manifest.id) != null);
}

test "name, version and license are required and are the first three fields" {
    // Their order is not load-bearing for reading — fields are found by name — but a
    // manifest that omitted any of the three would be a package nobody can order, credit
    // or redistribute, so the requirement itself is.
    try testing.expectEqual(@as(?u32, 0), manifest.fieldIndex(name_field));
    try testing.expectEqual(@as(?u32, 1), manifest.fieldIndex(version_field));
    try testing.expectEqual(@as(?u32, 2), manifest.fieldIndex(license_field));
    for (manifest.fields[0..3]) |f| try testing.expect(f.presence == .required);
}

test "every field after the required three is optional, and every field is version 1" {
    for (manifest.fields[3..]) |f| try testing.expect(f.presence != .required);
    // Nothing has been added yet, so nothing carries a `since`. The test exists to make
    // the next addition state one deliberately rather than inherit 1 by accident (I8).
    for (manifest.fields) |f| try testing.expectEqual(@as(u32, 1), f.since);
}

test "a requirement defaults to any version at or above one" {
    const min = requirement_fields[1];
    try testing.expect(min.presence == .default);
    try testing.expectEqual(@as(i128, 1), min.presence.default.int);
    try testing.expect(requirement_fields[2].presence == .optional);
}
