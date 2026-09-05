//! The engine's own content types for describing entities.
//!
//! Two record types, and deliberately no more: **an entity template** is a list of component
//! records, and **a scene** is a list of templates. Both are expressible in `.fdt` with no
//! new syntax, because the closed type list already has `[id]` (ADR-0020 is settled, and
//! content written today has to keep parsing).
//!
//! ```fdt
//! # Each component instance is a record, with its own content id.
//! foundry:transform  sandbox:player.transform  { x 0  y 0 }
//! foundry:sprite     sandbox:player.sprite     { texture sandbox:textures.hero }
//!
//! foundry:entity sandbox:entity.player {
//!     components [ sandbox:player.transform  sandbox:player.sprite ]
//! }
//!
//! foundry:scene sandbox:scene.main {
//!     entities [ sandbox:entity.player  sandbox:entity.goblin  sandbox:entity.goblin ]
//! }
//! ```
//!
//! **Why a component instance is its own record rather than an inline block.** Because
//! `content-schemas.md` §7's rule answers it: anything a mod might want to override on its
//! own is a record with a content id, and anything it would not is an inline struct. A mod
//! that wants the player's sprite changed overrides `sandbox:player.sprite` — one record —
//! and never mentions the template. With an inline block it would have to restate the whole
//! entity, and every future field of every other component on it, to change one texture.
//!
//! These are engine-owned, so `fpack` registers them before it compiles anything and an
//! author never declares them — the same treatment `asset.schemas` gets, for the same reason.
//!
//! Design: `docs/design/entity-storage.md` §8.

const std = @import("std");
const data = @import("data");

const Allocator = std.mem.Allocator;
const Schema = data.Schema;

/// An entity template: what components an entity gets, by content id.
///
/// The list order is the order the components are added, which is the order the stores hold
/// them, which is one of the two orders a query can iterate in. It is what the author wrote,
/// in a file, in order — not a hash map's iteration (I9).
pub const entity: Schema = .{
    .id = data.SchemaId.fromStringUnchecked("foundry:entity"),
    .version = 1,
    .fields = &.{
        .{ .name = "components", .type = .{ .list = &.id }, .presence = .optional },
    },
};

/// A scene: which templates to spawn, in order. Naming one twice spawns it twice.
pub const scene: Schema = .{
    .id = data.SchemaId.fromStringUnchecked("foundry:scene"),
    .version = 1,
    .fields = &.{
        .{ .name = "entities", .type = .{ .list = &.id }, .presence = .optional },
    },
};

pub const all = [_]Schema{ entity, scene };

/// Registers both into a registry, so content can use them without declaring them.
///
/// Called by `fpack` before it compiles a package, exactly as it calls
/// `asset.schemas.registerAll`. Re-registering an identical schema is how two packages that
/// share one both carry it, so calling this twice is not an error.
pub fn registerAll(gpa: Allocator, registry: *data.Registry) (data.schema.RegisterError || Allocator.Error)!void {
    for (&all) |s| _ = try registry.register(gpa, s);
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "the engine's entity schemas register, and are what content will be checked against" {
    const gpa = testing.allocator;
    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);

    try registerAll(gpa, &registry);
    try testing.expectEqual(@as(u32, 2), registry.count());

    // Idempotent, because two packages that both use one each carry a copy of it.
    try registerAll(gpa, &registry);
    try testing.expectEqual(@as(u32, 2), registry.count());

    const held = registry.lookup(entity.id).?;
    try testing.expectEqualStrings("components", held.fields[0].name);
    try testing.expect(held.fields[0].type == .list);
    try testing.expect(held.fields[0].type.list.* == .id);
}
