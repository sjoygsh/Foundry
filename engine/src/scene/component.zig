//! Component types: what one is, and what the world keeps about it.
//!
//! ADR-0010's binding constraint is that component types are registered **at runtime** and
//! storage is type-erased, because a `comptime` component set — the natural and fastest
//! thing to write in Zig — makes mod-defined components impossible. Native code registers
//! through a `comptime` helper that *produces* one of these structs; a mod registers the
//! same structure through the C ABI at M7. The registry cannot tell them apart, which is
//! what I6 is asking for.
//!
//! **A component type is a schema** (`entity-storage.md` §3). Its identity is a `SchemaId`,
//! its fields are a `data.Schema`, and its versioning, checking and defaults are the ones
//! `data` already implements and tests. A separate component-type ID space would have to be
//! kept in lockstep with a schema for anything ever saved or authored, and "kept in
//! lockstep" is a synonym for "eventually diverges".
//!
//! Design: `docs/design/entity-storage.md` §3 and §6.

const std = @import("std");
const core = @import("core");
const data = @import("data");

pub const DeserializeError = error{
    /// A value the record holds that the component's field cannot represent — a `u32`
    /// field whose record says 5,000,000,000. Untrusted input, so it is refused rather
    /// than truncated.
    ValueOutOfRange,
} || data.fpk.ReadError;

/// Fills a component's bytes from a record's fields.
///
/// **Untrusted:** the fields came from a package or a save, and a field the schema says is
/// there may be absent, out of range, or a shape the block does not actually hold. Absence
/// is not an error — an omitted optional field and a field added in a later schema version
/// both arrive that way, and the value already in `out` is the right answer for both.
pub const DeserializeFn = *const fn (
    ctx: ?*anyopaque,
    fields: data.fpk.Fields,
    out: [*]u8,
) DeserializeError!void;

/// Phantom tag for `ComponentType` (I1).
pub const ComponentTypes = opaque {};

/// A registered component type.
///
/// A handle rather than a bare index, even though nothing unregisters a type today and so
/// nothing can go stale. Two reasons, and the second is the real one: it costs four bytes
/// and reuses a pool the engine already tests, and **unloading a mod unregisters its
/// component types**, at which point every index held anywhere becomes a dangling
/// reference and the generation is the thing that catches it. Adding the generation
/// afterwards would mean revisiting every holder.
///
/// Because nothing is ever removed, `index` is dense and is exactly the position of the
/// type's storage. That is an implementation convenience this module may rely on and no
/// caller may.
pub const ComponentType = core.Handle(ComponentTypes);

/// Everything the engine needs to store, construct, destroy and eventually serialize a
/// component type, described at runtime.
///
/// Deliberately C-ABI-shaped ahead of M7 (ADR-0004): `ctx` rather than a closure, plain
/// function pointers, no Zig-only types in the fields a mod would have to fill in.
///
/// **`serialize` is not here yet.** §3 of the design gives it, and it arrives with the save
/// format at step 6, because until there is a field writer for it to speak to, a signature
/// here would be a guess written into a struct that mods will implement.
pub const ComponentTypeInfo = struct {
    /// Identity and serialized shape, in one value so a component type cannot disagree
    /// with itself. Registration hands this to `data.Registry`, where the ordinary rules
    /// apply — additive versioning, no two packages disagreeing about one schema.
    schema: data.Schema,

    /// The authored spelling of `schema.id`, for diagnostics. Copied at registration, so
    /// a mod's string does not have to outlive the call.
    name: []const u8,

    /// Bytes per component. **Zero is legal and means a marker** — a component that
    /// records only that an entity has it. Storage keeps presence and no bytes, and such
    /// a type ordinarily declares an empty schema, since there is nothing to save.
    size: u32,
    /// A power of two, at least 1. For a native type this is `@alignOf` and the registry
    /// checks it against the Zig type it was derived from.
    alignment: u32,

    ctx: ?*anyopaque = null,
    /// Optional. Absent means zero-initialised is a valid component.
    construct: ?*const fn (ctx: ?*anyopaque, out: [*]u8) void = null,
    /// Optional. Absent means the component owns nothing that needs releasing.
    destruct: ?*const fn (ctx: ?*anyopaque, component: [*]u8) void = null,
    /// Optional. Absent means the type cannot be built from data: content naming it is
    /// refused rather than silently producing a zeroed component. `componentType` always
    /// supplies one; a hand-written registration for something purely internal need not.
    deserialize: ?DeserializeFn = null,
};

/// A component type as the world holds it, after registration.
///
/// It keeps the schema **handle**, never a copy of the schema. `data.Registry` updates a
/// schema in place behind its handle when a later package extends it, so everything
/// holding the handle follows the extension — and a copy taken here would be the one thing
/// that quietly did not.
pub const Registration = struct {
    id: data.SchemaId,
    schema: data.SchemaHandle,
    /// Owned by the world's arena.
    name: []const u8,

    size: u32,
    alignment: u32,
    /// `size` rounded up to `alignment`: the distance between consecutive components in a
    /// dense array. Computed once here rather than at every access.
    stride: u32,

    ctx: ?*anyopaque,
    construct: ?*const fn (ctx: ?*anyopaque, out: [*]u8) void,
    destruct: ?*const fn (ctx: ?*anyopaque, component: [*]u8) void,
    deserialize: ?DeserializeFn,
};

/// The stride a dense array of this type uses.
pub fn strideFor(size: u32, alignment: u32) u32 {
    if (size == 0) return 0;
    return std.mem.alignForward(u32, size, alignment);
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "stride rounds a component up to its alignment" {
    try testing.expectEqual(@as(u32, 4), strideFor(4, 4));
    try testing.expectEqual(@as(u32, 8), strideFor(5, 4));
    try testing.expectEqual(@as(u32, 16), strideFor(12, 8));
    // A marker occupies nothing, and its dense array is a length rather than bytes.
    try testing.expectEqual(@as(u32, 0), strideFor(0, 1));
}

test "a component type handle is distinct from an entity" {
    const entity = @import("entity.zig");
    try testing.expect(ComponentType != entity.Entity);
}
