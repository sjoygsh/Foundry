//! Entities: identity, and nothing else.
//!
//! An entity is a generational handle (I1, ADR-0010) and there is no entity *object*
//! anywhere in the engine. Nothing is stored on an entity; what it "has" lives in the
//! component stores, keyed by it. That is why this type is called `Entity` rather than
//! `EntityHandle` — everywhere else a handle names something that also exists in another
//! form, and `EntityHandle` would imply an `Entity` for the handle to point at.
//!
//! It is a name mods will see and a value that ends up inside save files, so both the
//! spelling and the width are compatibility decisions rather than implementation details
//! (CLAUDE.md §7).
//!
//! Design: `docs/design/entity-storage.md` §2.

const std = @import("std");
const core = @import("core");

/// Phantom tag for `Entity` (I1). Never instantiated.
pub const Entities = opaque {};

/// A handle to an entity. Stale handles resolve to nothing rather than to whatever now
/// occupies the slot, and failing to resolve is a normal condition — entity handles
/// arrive from saves, tools and mods (`core-memory-and-handles.md` §2).
pub const Entity = core.Handle(Entities);

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "an entity is eight bytes, and a zeroed one is none" {
    // Both facts are load-bearing rather than incidental. The width is what a save file
    // writes for an entity reference inside component data (§9), and all-zero meaning
    // *absent* is what makes a zeroed component's entity field safely empty rather than
    // a reference to slot 0.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Entity));
    try testing.expect(std.mem.zeroes(Entity).isNone());
    try testing.expectEqual(@as(u64, 0), Entity.none.bits());
}

test "an entity survives the packing a save writes it with" {
    const e: Entity = .{ .index = 12, .generation = 4 };
    try testing.expect(e.eql(Entity.fromBits(e.bits())));
}
