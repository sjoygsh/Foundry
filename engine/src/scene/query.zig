//! Queries: the entities that have a set of components, and their bytes.
//!
//! **This is where the interface either leaks the storage layout or does not.** ADR-0010
//! names archetype storage as the anticipated upgrade, and archetype storage has no sparse
//! array, no dense owner list and no per-type byte block. A query that handed any of those
//! out would make the upgrade a rewrite of every system. So a query yields entities and
//! component bytes, and nothing else.
//!
//! ## Order
//!
//! Iteration is driven by the dense array of the **first** named component, with the rest
//! resolved by sparse lookup and non-matches skipped.
//!
//! The conventional choice is to drive from the *smallest* store, which is faster. It is
//! rejected on I9 grounds: driving from the smallest makes iteration order a function of
//! the data, so the same query yields a different order once a mod adds forty sprites. That
//! is still deterministic in the strict sense, and it is impossible to reason about from
//! the code — "deterministic but unpredictable" is the property that turns an ordering bug
//! into a three-day bug. Driving from the first named component makes the order a property
//! of the query as written. **Name the most selective component first.**
//!
//! The order itself is that store's dense order: insertion order, perturbed by
//! swap-removal. A system whose *results* depend on order must sort, and `Entity` is the
//! key to sort by (`entity-storage.md` §5).
//!
//! ## Structural change during iteration
//!
//! Adding or removing a component, or creating or destroying an entity, invalidates a query
//! and every pointer it has handed out. That is an **assertion**, not a validation: it is a
//! programmer error in engine or game code, never untrusted input. The escape hatch is the
//! ordinary one — collect entities into a frame arena, then act on them after the loop.
//!
//! Design: `docs/design/entity-storage.md` §5.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const component = @import("component.zig");
const derive = @import("derive.zig");
const entity_mod = @import("entity.zig");
const store_mod = @import("store.zig");

const ComponentStore = store_mod.ComponentStore;
const ComponentType = component.ComponentType;
const Entity = entity_mod.Entity;
const assert = core.assert;

/// The most components one query may name.
///
/// The types are held inline rather than borrowed, so a `Query` is a self-contained value
/// with no lifetime rule of its own — which is what lets the typed wrapper below hold one
/// and be returned by value. Sixteen handles is 128 bytes on the stack of something built
/// once per system per frame, and it is past the point where naming another component is
/// the problem.
pub const max_components: usize = 16;

/// An iterator over the entities that have every named component.
///
/// The type-erased form, which is what a mod's system will use through the ABI. Native code
/// usually wants `World.queryOf`, which is this with the casts written for it.
pub const Query = struct {
    /// The world's stores, borrowed. Indexed by a component type handle's index, which is
    /// dense because nothing is ever unregistered. The slice stays valid for the life of
    /// the query because registering a type is refused once a world has entities — so the
    /// array this points into cannot grow while anything is iterating it.
    stores: []ComponentStore,
    /// The world's live mutation counter, and the value it had when the query was built.
    mutation: *const u64,
    mutation_at_start: u64,

    /// The named types, held by value. Naming one twice is legal and resolves twice.
    types: [max_components]ComponentType = undefined,
    type_count: u32 = 0,

    /// The store whose dense array drives iteration. Null when the query can never match —
    /// no types named, or one of them is not registered.
    driver: ?*ComponentStore = null,
    cursor: u32 = 0,
    /// Dense positions of the current match, one per named type.
    slots: [max_components]u32 = undefined,

    /// The next matching entity, or null when there are none left.
    pub fn next(self: *Query) ?Entity {
        const driver = self.driver orelse return null;
        assert.always(
            self.mutation_at_start == self.mutation.*,
            "the world changed shape while a query was iterating it; " ++
                "collect the entities first and act on them after the loop",
            .{},
        );

        outer: while (self.cursor < driver.count()) {
            const dense = self.cursor;
            self.cursor += 1;
            const entity = driver.ownerAt(dense);
            self.slots[0] = dense;

            for (self.types[1..self.type_count], 1..) |t, i| {
                const store = &self.stores[t.index];
                self.slots[i] = store.denseIndex(entity) orelse continue :outer;
            }
            return entity;
        }
        return null;
    }

    /// The bytes of the `index`-th named component of the current match.
    ///
    /// Valid until the next mutation of the world, which the iterator already refuses to
    /// survive. Calling it before `next` has returned an entity is a programmer error.
    pub fn bytes(self: *const Query, index: usize) []u8 {
        assert.debugOnly(
            index < self.type_count,
            "query component {d} of {d}",
            .{ index, self.type_count },
        );
        return self.stores[self.types[index].index].at(self.slots[index]);
    }
};

/// The schema id of a component type named as a Zig type — the same id its registration
/// used, derived the same way, so the typed and erased paths cannot disagree about which
/// component they mean.
pub fn schemaIdOf(comptime T: type) data.SchemaId {
    return derive.componentType(T).schema.id;
}

/// `Query` with the component types named as Zig types and the casts written for you.
///
/// Sugar over the same iterator, in the way `componentType` is sugar over the same
/// registration. Nothing here reaches storage that the erased form cannot.
pub fn TypedQuery(comptime types: anytype) type {
    return struct {
        const Self = @This();
        const count = types.len;

        inner: Query,

        pub const Match = struct {
            entity: Entity,
            /// Captured when the match was found, so a `Match` outlives nothing it should
            /// not: it is a value, and the query it came from is still the thing that must
            /// not be mutated under it.
            ptrs: [count][*]u8,

            /// The component of type `T` on this entity.
            pub fn get(self: Match, comptime T: type) *T {
                return @ptrCast(@alignCast(self.ptrs[comptime indexOf(T)]));
            }
        };

        pub fn next(self: *Self) ?Match {
            const entity = self.inner.next() orelse return null;
            var ptrs: [count][*]u8 = undefined;
            inline for (0..count) |i| ptrs[i] = self.inner.bytes(i).ptr;
            return .{ .entity = entity, .ptrs = ptrs };
        }

        fn indexOf(comptime T: type) usize {
            inline for (types, 0..) |Named, i| {
                if (Named == T) return i;
            }
            @compileError(@typeName(T) ++ " is not one of the components this query names");
        }
    };
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "a query holds its types by value, so it has no lifetime of its own" {
    // The property the typed wrapper depends on: a `Query` can be returned, copied and
    // stored without anything it points at having to outlive the call that built it,
    // except the world itself.
    const q: Query = undefined;
    try testing.expectEqual(max_components, q.types.len);
    try testing.expectEqual(max_components, q.slots.len);
}

const world_mod = @import("world.zig");

const Pos = struct {
    pub const component = "test:pos";
    x: f32 = 0,
    y: f32 = 0,
};

const Vis = struct {
    pub const component = "test:vis";
    layer: u32 = 0,
};

const Fixture = struct {
    schemas: data.Registry,
    world: world_mod.World,

    fn init(gpa: std.mem.Allocator) !*Fixture {
        const f = try gpa.create(Fixture);
        f.* = .{ .schemas = .init(gpa, .default), .world = undefined };
        f.world = .init(gpa, &f.schemas, .default);
        return f;
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.world.deinit();
        self.schemas.deinit(gpa);
        gpa.destroy(self);
    }
};

fn collect(gpa: std.mem.Allocator, q: *Query) !std.ArrayList(Entity) {
    var out: std.ArrayList(Entity) = .empty;
    errdefer out.deinit(gpa);
    while (q.next()) |e| try out.append(gpa, e);
    return out;
}

test "a one-component query visits everything that has it" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const pos = try f.world.registerComponent(derive.componentType(Pos));
    const vis = try f.world.registerComponent(derive.componentType(Vis));

    const a = try f.world.create();
    const b = try f.world.create();
    const c = try f.world.create();
    for ([_]Entity{ a, b, c }) |e| _ = try f.world.addComponent(e, pos, null);
    _ = try f.world.addComponent(b, vis, null);

    var q = f.world.query(&.{pos});
    var seen = try collect(gpa, &q);
    defer seen.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), seen.items.len);
    try testing.expect(seen.items[0].eql(a));
    try testing.expect(seen.items[2].eql(c));
}

test "a two-component query visits the intersection, in the first named one's order" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const pos = try f.world.registerComponent(derive.componentType(Pos));
    const vis = try f.world.registerComponent(derive.componentType(Vis));

    const a = try f.world.create();
    const b = try f.world.create();
    const c = try f.world.create();
    for ([_]Entity{ a, b, c }) |e| _ = try f.world.addComponent(e, pos, null);

    // Deliberately the other way round, so the two stores' dense orders differ and the
    // choice of driver is visible in the result rather than hidden by agreement.
    _ = try f.world.addComponent(c, vis, null);
    _ = try f.world.addComponent(b, vis, null);

    {
        var q = f.world.query(&.{ pos, vis });
        var seen = try collect(gpa, &q);
        defer seen.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), seen.items.len);
        try testing.expect(seen.items[0].eql(b));
        try testing.expect(seen.items[1].eql(c));
    }
    {
        // Same set, different order. **This is the decision, made visible**: the order is a
        // property of the query as written, not of which store happens to be smaller.
        var q = f.world.query(&.{ vis, pos });
        var seen = try collect(gpa, &q);
        defer seen.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), seen.items.len);
        try testing.expect(seen.items[0].eql(c));
        try testing.expect(seen.items[1].eql(b));
    }
}

test "a query matches nothing when it can never match" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const pos = try f.world.registerComponent(derive.componentType(Pos));
    const e = try f.world.create();
    _ = try f.world.addComponent(e, pos, null);

    // Naming no components at all.
    var empty = f.world.query(&.{});
    try testing.expect(empty.next() == null);

    // Naming a component type this world does not have — which is what a system written
    // against a mod that is not loaded looks like. Not an error: it simply does nothing.
    const foreign: ComponentType = .{ .index = 42, .generation = 1 };
    var missing = f.world.query(&.{ pos, foreign });
    try testing.expect(missing.next() == null);
}

test "a removal is visible to the next query, and reorders the dense array" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const pos = try f.world.registerComponent(derive.componentType(Pos));
    const a = try f.world.create();
    const b = try f.world.create();
    const c = try f.world.create();
    for ([_]Entity{ a, b, c }) |e| _ = try f.world.addComponent(e, pos, null);

    try testing.expect(f.world.removeComponent(a, pos));

    var q = f.world.query(&.{pos});
    var seen = try collect(gpa, &q);
    defer seen.deinit(gpa);

    // §5's caveat, seen from the outside: swap-removal put the last element where the
    // first was. Reproducible, documented, and not entity order.
    try testing.expectEqual(@as(usize, 2), seen.items.len);
    try testing.expect(seen.items[0].eql(c));
    try testing.expect(seen.items[1].eql(b));
}

test "the typed query hands back the components it names" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const pos = try f.world.registerComponent(derive.componentType(Pos));
    const vis = try f.world.registerComponent(derive.componentType(Vis));

    const a = try f.world.create();
    const b = try f.world.create();
    var start: Pos = .{ .x = 1, .y = 2 };
    _ = try f.world.addComponent(a, pos, std.mem.asBytes(&start));
    _ = try f.world.addComponent(b, pos, std.mem.asBytes(&start));
    var layer: Vis = .{ .layer = 3 };
    _ = try f.world.addComponent(b, vis, std.mem.asBytes(&layer));

    var visited: u32 = 0;
    var it = f.world.queryOf(.{ Pos, Vis });
    while (it.next()) |m| {
        visited += 1;
        try testing.expect(m.entity.eql(b));
        try testing.expectEqual(@as(u32, 3), m.get(Vis).layer);
        // The borrow is writable, and it is the world's memory.
        m.get(Pos).y += 10;
    }
    try testing.expectEqual(@as(u32, 1), visited);

    const after: *const Pos = @ptrCast(@alignCast(f.world.getComponent(b, pos).?.ptr));
    try testing.expectEqual(@as(f32, 12), after.y);
    // The entity the query skipped was not touched.
    const untouched: *const Pos = @ptrCast(@alignCast(f.world.getComponent(a, pos).?.ptr));
    try testing.expectEqual(@as(f32, 2), untouched.y);
}

test "a typed query over a type this world lacks matches nothing" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    _ = try f.world.registerComponent(derive.componentType(Pos));
    const e = try f.world.create();
    _ = try f.world.addComponent(e, f.world.findComponent(schemaIdOf(Pos)).?, null);

    var it = f.world.queryOf(.{ Pos, Vis });
    try testing.expect(it.next() == null);
}
