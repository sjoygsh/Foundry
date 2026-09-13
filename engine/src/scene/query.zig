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

    pub const NextError = error{Mutated};

    /// The next matching entity, or null when there are none left.
    pub fn next(self: *Query) ?Entity {
        assert.always(
            self.mutation_at_start == self.mutation.*,
            "the world changed shape while a query was iterating it; " ++
                "collect the entities first and act on them after the loop",
            .{},
        );
        return self.nextUnchecked();
    }

    /// The next matching entity, or `error.Mutated` when a structural change invalidated
    /// this query. The ABI uses this form because a mod can make that mistake and must get
    /// a refusal rather than bring down its host.
    pub fn nextChecked(self: *Query) NextError!?Entity {
        if (self.mutation_at_start != self.mutation.*) return error.Mutated;
        return self.nextUnchecked();
    }

    fn nextUnchecked(self: *Query) ?Entity {
        const driver = self.driver orelse return null;
        return advance(self.stores, self.types[0..self.type_count], driver, &self.cursor, driver.count(), &self.slots);
    }

    // -- splitting -----------------------------------------------------------------

    /// One chunk of a split query: the matches whose position in the driving store lies in
    /// the chunk, in the order `next` would visit them.
    ///
    /// **A view, not a world.** Its stores are `const`, so nothing reached through it can
    /// add, remove, create or destroy; it iterates its own range and hands out component
    /// bytes, which a chunk may write because no other chunk's range holds the same entity
    /// (`jobs-and-threading.md` §6.1). Its fields are not API — Zig has no private fields.
    pub const Part = struct {
        stores: []const ComponentStore,
        types: [max_components]ComponentType,
        type_count: u32,
        driver: *const ComponentStore,
        cursor: u32,
        end: u32,
        /// Which chunk this is, for a caller that keeps a result slot per chunk.
        index: u32,
        slots: [max_components]u32 = undefined,

        pub fn next(self: *Part) ?Entity {
            return advance(self.stores, self.types[0..self.type_count], self.driver, &self.cursor, self.end, &self.slots);
        }

        /// The bytes of the `index`-th named component of the current match.
        pub fn bytes(self: *const Part, which: usize) []u8 {
            assert.debugOnly(
                which < self.type_count,
                "query component {d} of {d}",
                .{ which, self.type_count },
            );
            return self.stores[self.types[which].index].at(self.slots[which]);
        }
    };

    /// Splits the matches across `jobs` in chunks of `grain` positions of the driving store,
    /// and calls `chunkFn(context, part)` once for each, returning when all have returned.
    ///
    /// The checked form, as `nextChecked` is: a world whose shape changed since this query
    /// was built is refused before anything runs, and one that changed during the split —
    /// which a chunk can only do by breaking the rules through its context — is reported
    /// after. The typed wrapper's `forChunks` asserts instead.
    pub fn forChunksChecked(
        self: *const Query,
        jobs: core.Jobs,
        grain: u32,
        context: anytype,
        comptime chunkFn: fn (@TypeOf(context), *Part) void,
    ) NextError!void {
        if (!self.unchanged()) return error.Mutated;
        self.split(jobs, grain, context, chunkFn);
        if (!self.unchanged()) return error.Mutated;
    }

    fn unchanged(self: *const Query) bool {
        return self.mutation_at_start == self.mutation.*;
    }

    fn split(
        self: *const Query,
        jobs: core.Jobs,
        grain: u32,
        context: anytype,
        comptime chunkFn: fn (@TypeOf(context), *Part) void,
    ) void {
        const driver = self.driver orelse return;
        const Shared = struct { query: *const Query, context: @TypeOf(context) };
        const Chunked = struct {
            fn run(shared: Shared, chunk: core.jobs.Chunk) void {
                var part = shared.query.partOf(chunk);
                chunkFn(shared.context, &part);
            }
        };
        jobs.forChunks(driver.count(), grain, Shared{ .query = self, .context = context }, Chunked.run);
    }

    fn partOf(self: *const Query, chunk: core.jobs.Chunk) Part {
        return .{
            .stores = self.stores,
            .types = self.types,
            .type_count = self.type_count,
            .driver = self.driver.?,
            .cursor = chunk.begin,
            .end = chunk.end,
            .index = chunk.index,
        };
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

/// The next match at or after `cursor` and before `end`, advancing `cursor` past it.
///
/// The one walk both `Query.next` and a chunk's `Part.next` take, so a split cannot visit
/// anything the loop would not, or visit it in another order.
fn advance(
    stores: []const ComponentStore,
    types: []const ComponentType,
    driver: *const ComponentStore,
    cursor: *u32,
    end: u32,
    slots: *[max_components]u32,
) ?Entity {
    const limit = @min(end, driver.count());
    outer: while (cursor.* < limit) {
        const dense = cursor.*;
        cursor.* += 1;
        const entity = driver.ownerAt(dense);
        slots[0] = dense;

        for (types[1..], 1..) |t, i| {
            slots[i] = stores[t.index].denseIndex(entity) orelse continue :outer;
        }
        return entity;
    }
    return null;
}

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

        /// One chunk of a split, with the casts written for you. See `Query.Part`.
        pub const Part = struct {
            inner: *Query.Part,

            pub fn next(self: *Part) ?Match {
                const entity = self.inner.next() orelse return null;
                var ptrs: [count][*]u8 = undefined;
                inline for (0..count) |i| ptrs[i] = self.inner.bytes(i).ptr;
                return .{ .entity = entity, .ptrs = ptrs };
            }

            /// Which chunk this is, for a caller that keeps a result slot per chunk.
            pub fn index(self: *const Part) u32 {
                return self.inner.index;
            }
        };

        /// Splits this query's matches across `jobs` in chunks of `grain` positions of the
        /// driving store — the order `next` walks — and calls `chunkFn(context, part)` once per
        /// chunk, returning when every chunk has returned.
        ///
        /// A chunk writes only the components its own part hands it, allocates nothing and
        /// reaches nothing else that another chunk writes (`jobs-and-threading.md` §3.3). Then
        /// any `jobs`, `serial` included, leaves the world in the same bytes. A world that changed
        /// shape before or during the call is a programmer error, asserted as `next` asserts it.
        pub fn forChunks(
            self: *const Self,
            jobs: core.Jobs,
            grain: u32,
            context: anytype,
            comptime chunkFn: fn (@TypeOf(context), *Part) void,
        ) void {
            const Typed = struct {
                fn run(ctx: @TypeOf(context), part: *Query.Part) void {
                    var typed: Part = .{ .inner = part };
                    chunkFn(ctx, &typed);
                }
            };
            assert.always(
                self.inner.unchanged(),
                "the world changed shape between building a query and splitting it",
                .{},
            );
            self.inner.split(jobs, grain, context, Typed.run);
            assert.always(
                self.inner.unchanged(),
                "a chunk of a split query changed the world's shape; a chunk may only write " ++
                    "the components its part hands it",
                .{},
            );
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

test "a split query visits what its loop visits, each chunk its own range, in the same order" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const pos = try f.world.registerComponent(derive.componentType(Pos));
    const vis = try f.world.registerComponent(derive.componentType(Vis));

    var made: [40]Entity = undefined;
    for (&made, 0..) |*e, i| {
        e.* = try f.world.create();
        _ = try f.world.addComponent(e.*, pos, null);
        if (i % 3 != 1) _ = try f.world.addComponent(e.*, vis, null);
    }
    // Removals reorder the driving store, so chunk ranges and entity order disagree.
    for (made, 0..) |e, i| {
        if (i % 5 == 2) _ = f.world.destroy(e);
    }

    var loop = f.world.query(&.{ pos, vis });
    var expected = try collect(gpa, &loop);
    defer expected.deinit(gpa);

    const Seen = struct {
        const grain = 6;
        by_chunk: [7][grain]Entity = undefined,
        counts: [7]usize = @splat(0),

        fn chunk(self: *@This(), part: *Query.Part) void {
            while (part.next()) |e| {
                self.by_chunk[part.index][self.counts[part.index]] = e;
                self.counts[part.index] += 1;
            }
        }
    };

    for ([_]core.Jobs{ core.jobs.serial, core.jobs.reversed }) |jobs| {
        var seen: Seen = .{};
        const q = f.world.query(&.{ pos, vis });
        try q.forChunksChecked(jobs, Seen.grain, &seen, Seen.chunk);

        var at: usize = 0;
        for (seen.by_chunk, seen.counts) |entities, n| {
            for (entities[0..n]) |e| {
                try testing.expect(e.eql(expected.items[at]));
                at += 1;
            }
        }
        try testing.expectEqual(expected.items.len, at);
    }
}

test "chunks write through their parts, and either order leaves the world in the same bytes" {
    const gpa = testing.allocator;

    const Double = struct {
        fn chunk(_: void, part: *TypedQuery(.{Pos}).Part) void {
            while (part.next()) |m| {
                const p = m.get(Pos);
                p.x = p.x * 2 + p.y;
                p.y = p.y - p.x * 0.5;
            }
        }
    };

    var saves: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&saves) |*s| s.deinit(gpa);

    for ([_]core.Jobs{ core.jobs.serial, core.jobs.reversed }, &saves) |jobs, *save| {
        const f = try Fixture.init(gpa);
        defer f.deinit(gpa);
        const pos = try f.world.registerComponent(derive.componentType(Pos));
        for (0..50) |i| {
            const e = try f.world.create();
            _ = try f.world.addComponent(e, pos, null);
            if (i % 4 == 0) _ = f.world.destroy(e);
        }
        var n: f32 = 0;
        var init = f.world.queryOf(.{Pos});
        while (init.next()) |m| {
            m.get(Pos).* = .{ .x = n * 0.25, .y = 3 - n };
            n += 1;
        }

        for (0..10) |_| f.world.queryOf(.{Pos}).forChunks(jobs, 4, {}, Double.chunk);
        try f.world.save(save);
    }

    try testing.expect(saves[0].items.len > 0);
    try testing.expectEqualSlices(u8, saves[0].items, saves[1].items);
}

test "a world that changed shape after the query was built is refused before any chunk runs" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const pos = try f.world.registerComponent(derive.componentType(Pos));
    for (0..8) |_| {
        const e = try f.world.create();
        _ = try f.world.addComponent(e, pos, null);
    }

    const Count = struct {
        fn chunk(calls: *usize, _: *Query.Part) void {
            calls.* += 1;
        }
    };

    const q = f.world.query(&.{pos});
    _ = try f.world.create();
    var calls: usize = 0;
    try testing.expectError(error.Mutated, q.forChunksChecked(core.jobs.serial, 2, &calls, Count.chunk));
    try testing.expectEqual(@as(usize, 0), calls);
}

test "a query that can never match splits into nothing" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const pos = try f.world.registerComponent(derive.componentType(Pos));
    const e = try f.world.create();
    _ = try f.world.addComponent(e, pos, null);

    const Count = struct {
        fn chunk(calls: *usize, _: *Query.Part) void {
            calls.* += 1;
        }
    };

    // `Vis` is never registered, so the query has no driver.
    var calls: usize = 0;
    const q = f.world.query(&.{ pos, .none });
    try q.forChunksChecked(core.jobs.serial, 1, &calls, Count.chunk);
    try testing.expectEqual(@as(usize, 0), calls);
}
