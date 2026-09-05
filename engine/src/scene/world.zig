//! The world: entities, and the component types they can have.
//!
//! A world is a container you drive, not a framework that calls you back — the same
//! relationship `app` has with a game (`app-and-frame-loop.md` §1). It holds entity
//! identity and the runtime component type registry; storage, queries and systems arrive
//! in the steps after this one.
//!
//! **It borrows the schema registry rather than owning one.** A component type is a schema
//! (§3), and the schemas a world knows are the schemas the content system knows — one
//! registry, so a component type and the record that defines an instance of it cannot come
//! to disagree. Whether a world should own its own is `entity-storage.md` §13's sixth open
//! question, and the answer changes only when a tool wants two worlds at once.
//!
//! Design: `docs/design/entity-storage.md` §2, §6 and §12.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const component = @import("component.zig");
const entity_mod = @import("entity.zig");
const limits_mod = @import("limits.zig");
const query_mod = @import("query.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;
const ComponentStore = store_mod.ComponentStore;
const ComponentType = component.ComponentType;
const ComponentTypeInfo = component.ComponentTypeInfo;
const ComponentTypes = component.ComponentTypes;
const Entities = entity_mod.Entities;
const Entity = entity_mod.Entity;
const Limits = limits_mod.Limits;
const Query = query_mod.Query;
const Registration = component.Registration;
const log = core.log.scoped(.scene);

pub const CreateError = error{
    /// `Limits.max_entities`. Reachable from a save file, which says how many entities to
    /// create, so it is a refusal rather than an assertion.
    EntityLimit,
} || Allocator.Error;

pub const RegisterError = error{
    /// A component type is already registered for that schema. Adding is not replacing:
    /// a component type has exactly one owner, and resolving the ambiguous case by
    /// arrival order would make the winner depend on load order. Same reasoning as
    /// `asset.RegisterError.LoaderExists`.
    ComponentTypeExists,
    /// Zero, or not a power of two.
    InvalidComponentAlignment,
    /// `name` is not a valid `namespace:name`, or does not hash to `schema.id`. Checked
    /// so that the spelling a diagnostic prints is the one the schema actually has.
    InvalidComponentName,
    /// `Limits.max_component_types`.
    ComponentTypeLimit,
    /// Registration happens before entities exist. Storage is allocated per type, and a
    /// type appearing after entities do would silently have no data for the ones already
    /// there — an emptiness indistinguishable from "none of them has this component".
    WorldNotEmpty,
} || data.schema.RegisterError;

pub const ComponentError = error{
    /// The handle names no registered type. Reachable from content and from a save, both
    /// of which can name a component type this build does not have.
    UnknownComponentType,
    /// The entity is stale or was never created. Resolving a stale handle is not an error
    /// (§12) — but *adding* to one is, because there is no sensible thing to do instead.
    NoSuchEntity,
    /// The entity already has a component of that type. An entity has at most one.
    ComponentExists,
    /// The supplied bytes are not the type's size. A caller passing the wrong type's
    /// component would otherwise write past the slot.
    ComponentSizeMismatch,
} || Allocator.Error;

pub const World = struct {
    gpa: Allocator,
    /// Holds component type names. Never reset: registration happens at startup and what
    /// it keeps is measured in bytes.
    arena: core.Arena,
    /// Borrowed. Outlives the world.
    schemas: *data.Registry,
    limits: Limits,

    /// Entity slots. The payload is `void` on purpose: nothing is stored *on* an entity,
    /// and what it has is recorded in the component stores (§4).
    entities: core.HandlePool(Entities, void) = .empty,

    /// Registered component types. Nothing is ever removed, so `handle.index` is dense and
    /// is the position of the type's storage — which is why the stores can be a flat array
    /// indexed by it, and why unregistering one (mod unload) would need more than a
    /// removal.
    types: core.HandlePool(ComponentTypes, Registration) = .empty,
    by_schema: std.AutoHashMapUnmanaged(u64, ComponentType) = .empty,
    /// One store per registered type, at the position of that type's handle index. Kept
    /// beside the registry rather than inside it, so the registry stays a description and
    /// the storage stays a thing with a lifetime.
    stores: std.ArrayList(ComponentStore) = .empty,

    /// Bumped by every structural change: an entity created or destroyed, and from step 2
    /// a component added or removed. Query iterators capture it and assert it has not
    /// moved, because mutating storage during iteration invalidates the pointers already
    /// handed out. Wrapping is deliberate — it is compared for equality, never ordered.
    mutation: u64 = 0,

    pub fn init(gpa: Allocator, schemas: *data.Registry, limits: Limits) World {
        return .{
            .gpa = gpa,
            .arena = .init(gpa),
            .schemas = schemas,
            .limits = limits,
        };
    }

    pub fn deinit(self: *World) void {
        for (self.stores.items) |*store| store.deinit(self.gpa);
        self.stores.deinit(self.gpa);
        self.by_schema.deinit(self.gpa);
        self.types.deinit(self.gpa);
        self.entities.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    // -- entities ------------------------------------------------------------------

    pub fn entityCount(self: *const World) u32 {
        return self.entities.count();
    }

    /// Whether a handle refers to a live entity. A stale one is false, not an error.
    pub fn contains(self: *const World, entity: Entity) bool {
        return self.entities.contains(entity);
    }

    pub fn create(self: *World) CreateError!Entity {
        if (self.entities.count() >= self.limits.max_entities) return error.EntityLimit;
        const handle = try self.entities.add(self.gpa, {});
        self.mutation +%= 1;
        return handle;
    }

    /// Destroys an entity. Returns false if the handle was already stale, which is a
    /// normal condition and not an error — handles arrive from saves, tools and mods.
    ///
    /// From step 2 this also removes the entity from every component store. The order
    /// matters and is fixed now: components are released **before** the slot is freed, so
    /// a `destruct` running during teardown still sees a live entity.
    pub fn destroy(self: *World, entity: Entity) bool {
        if (!self.entities.contains(entity)) return false;
        // Components first, while the entity is still live: a `destruct` running here is
        // entitled to look the entity up. O(registered types), each a bounds check and an
        // array read — §4's stated cost, and §13's third open question.
        for (self.stores.items) |*store| _ = store.remove(entity);
        std.debug.assert(self.entities.remove(entity));
        self.mutation +%= 1;
        return true;
    }

    // -- component types -----------------------------------------------------------

    pub fn componentTypeCount(self: *const World) u32 {
        return self.types.count();
    }

    /// Registers a component type. See `RegisterError` for every way this refuses.
    ///
    /// The schema goes into the borrowed `data.Registry` under its ordinary rules, so a
    /// component type whose schema disagrees with one a package already carries is refused
    /// there rather than here, with the message a mod author would get for any other
    /// schema conflict.
    pub fn registerComponent(self: *World, info: ComponentTypeInfo) RegisterError!ComponentType {
        if (self.entities.capacity() != 0) return error.WorldNotEmpty;
        if (self.types.count() >= self.limits.max_component_types) return error.ComponentTypeLimit;
        if (info.alignment == 0 or !std.math.isPowerOfTwo(info.alignment)) {
            return error.InvalidComponentAlignment;
        }

        const spelled = data.SchemaId.parse(info.name) catch return error.InvalidComponentName;
        if (!spelled.eql(info.schema.id)) return error.InvalidComponentName;

        if (self.by_schema.contains(info.schema.id.hash)) return error.ComponentTypeExists;

        // Everything that can fail an allocation happens before the schema registry is
        // touched, so a refusal leaves the world exactly as it was. Registering the schema
        // is the one effect that could outlive a later failure, and it is harmless: the
        // registry accepts an identical schema again, which is how two packages that share
        // one both carry it.
        try self.types.ensureUnusedCapacity(self.gpa, 1);
        try self.by_schema.ensureUnusedCapacity(self.gpa, 1);
        try self.stores.ensureUnusedCapacity(self.gpa, 1);
        const name = try self.arena.allocator().dupe(u8, info.name);

        const schema_handle = try self.schemas.register(self.gpa, info.schema);

        const handle = try self.types.add(self.gpa, .{
            .id = info.schema.id,
            .schema = schema_handle,
            .name = name,
            .size = info.size,
            .alignment = info.alignment,
            .stride = component.strideFor(info.size, info.alignment),
            .ctx = info.ctx,
            .construct = info.construct,
            .destruct = info.destruct,
            .deserialize = info.deserialize,
        });
        self.by_schema.putAssumeCapacity(info.schema.id.hash, handle);
        // Nothing is ever unregistered, so `handle.index` is the next position and the
        // stores stay parallel to the types. An unregister would have to break that, which
        // is half of why removing a type is not a removal.
        std.debug.assert(handle.index == self.stores.items.len);
        self.stores.appendAssumeCapacity(.init(self.types.getConst(handle).?));

        log.debug("component type '{s}' registered: {d} bytes, align {d}, schema version {d}", .{
            name,
            info.size,
            info.alignment,
            info.schema.version,
        });
        return handle;
    }

    /// The component type registered for a schema, or null. This is the lookup that turns
    /// a record in content into a component (§8), so it is the one a mod's data reaches.
    pub fn findComponent(self: *const World, schema_id: data.SchemaId) ?ComponentType {
        return self.by_schema.get(schema_id.hash);
    }

    pub fn componentInfo(self: *const World, t: ComponentType) ?*const Registration {
        return self.types.getConst(t);
    }

    /// The type's schema **as the registry holds it now**, which may be a later version
    /// than the one registered here: a package loaded afterwards may have extended it, and
    /// following that extension is the point of keeping the handle rather than a copy.
    pub fn componentSchema(self: *World, t: ComponentType) ?*const data.Schema {
        const info = self.types.getConst(t) orelse return null;
        return self.schemas.get(info.schema);
    }

    // -- components ----------------------------------------------------------------

    /// The store for a registered type, or null if the handle names none. Private: the
    /// three arrays behind it are exactly what no caller may learn about (§4).
    fn storeFor(self: *World, t: ComponentType) ?*ComponentStore {
        if (!self.types.contains(t)) return null;
        return &self.stores.items[t.index];
    }

    /// Adds a component to an entity and returns its bytes.
    ///
    /// `initial` is either exactly the type's `size` bytes, which are copied, or null —
    /// in which case the type's constructor runs, or the bytes are zeroed if it has none.
    ///
    /// The returned slice is a **borrow, valid until the next mutation of this world**.
    pub fn addComponent(
        self: *World,
        entity: Entity,
        t: ComponentType,
        initial: ?[]const u8,
    ) ComponentError![]u8 {
        const store = self.storeFor(t) orelse return error.UnknownComponentType;
        // Arguments before state. Bytes of the wrong size mean the caller has the wrong
        // type entirely, which is a more fundamental mistake than adding a component
        // twice — and hearing "already has one" while holding the wrong struct sends
        // somebody to look in the wrong place.
        if (initial) |src| {
            if (src.len != store.size) return error.ComponentSizeMismatch;
        }
        if (!self.entities.contains(entity)) return error.NoSuchEntity;
        if (store.has(entity)) return error.ComponentExists;

        const bytes = try store.add(self.gpa, entity, initial);
        self.mutation +%= 1;
        return bytes;
    }

    /// An entity's component bytes, or null if it does not have one — which includes a
    /// stale entity and an unregistered type. Both are normal conditions.
    pub fn getComponent(self: *World, entity: Entity, t: ComponentType) ?[]u8 {
        const store = self.storeFor(t) orelse return null;
        return store.get(entity);
    }

    pub fn hasComponent(self: *World, entity: Entity, t: ComponentType) bool {
        const store = self.storeFor(t) orelse return false;
        return store.has(entity);
    }

    /// Removes a component. False if the entity did not have one, which is not an error.
    pub fn removeComponent(self: *World, entity: Entity, t: ComponentType) bool {
        const store = self.storeFor(t) orelse return false;
        if (!store.remove(entity)) return false;
        self.mutation +%= 1;
        return true;
    }

    /// How many entities have a component of this type. The number a query would visit.
    pub fn componentCount(self: *World, t: ComponentType) u32 {
        const store = self.storeFor(t) orelse return 0;
        return store.count();
    }

    // -- queries -------------------------------------------------------------------

    /// The entities that have every named component.
    ///
    /// Iteration is driven by the **first** named type's dense array, so name the most
    /// selective one first; `query.zig` says why that rather than the smallest. `types` is
    /// borrowed for the life of the iterator.
    ///
    /// The type-erased form, which is what a mod's system will use through the ABI. Native
    /// code usually wants `queryOf`, which is this with the casts written for it.
    pub fn query(self: *World, types: []const ComponentType) Query {
        core.assert.always(
            types.len <= query_mod.max_components,
            "a query named {d} components; the limit is {d}",
            .{ types.len, query_mod.max_components },
        );

        var q: Query = .{
            .stores = self.stores.items,
            .mutation = &self.mutation,
            .mutation_at_start = self.mutation,
            .type_count = @intCast(types.len),
        };
        for (types, 0..) |t, i| q.types[i] = t;

        if (types.len != 0) {
            q.driver = for (types) |t| {
                if (!self.types.contains(t)) {
                    // Not an error: a system that acts on a mod's component when the mod is
                    // present should do nothing when it is not, and say so by matching
                    // nothing.
                    log.debug("query names an unregistered component type; it matches nothing", .{});
                    break null;
                }
            } else &self.stores.items[types[0].index];
        }
        return q;
    }

    /// `query`, with the component types named as Zig types and the casts written for you.
    ///
    /// ```zig
    /// var it = world.queryOf(.{ Transform, Sprite });
    /// while (it.next()) |m| m.get(Transform).y += 1;
    /// ```
    ///
    /// Sugar over the same iterator, in the way `componentType` is sugar over the same
    /// registration: it resolves each type through the ordinary schema lookup, so a native
    /// system and a mod's system are asking the registry the same question.
    pub fn queryOf(self: *World, comptime types: anytype) query_mod.TypedQuery(types) {
        var handles: [types.len]ComponentType = undefined;
        inline for (types, 0..) |Component, i| {
            handles[i] = self.findComponent(query_mod.schemaIdOf(Component)) orelse .none;
        }
        return .{ .inner = self.query(&handles) };
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

/// A world and the registry it borrows, torn down together.
const Fixture = struct {
    schemas: data.Registry,
    world: World,

    fn init(gpa: Allocator, limits: Limits) !*Fixture {
        const f = try gpa.create(Fixture);
        f.* = .{
            .schemas = .init(gpa, .default),
            .world = undefined,
        };
        f.world = .init(gpa, &f.schemas, limits);
        return f;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.world.deinit();
        self.schemas.deinit(gpa);
        gpa.destroy(self);
    }
};

fn transformInfo() ComponentTypeInfo {
    return .{
        .schema = .{
            .id = data.SchemaId.fromStringUnchecked("foundry:transform"),
            .version = 1,
            .fields = &.{
                .{ .name = "x", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
                .{ .name = "y", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
            },
        },
        .name = "foundry:transform",
        .size = 8,
        .alignment = 4,
    };
}

test "entities are created, resolved and destroyed" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const a = try f.world.create();
    const b = try f.world.create();
    try testing.expectEqual(@as(u32, 2), f.world.entityCount());
    try testing.expect(f.world.contains(a));
    try testing.expect(f.world.contains(b));

    try testing.expect(f.world.destroy(a));
    try testing.expectEqual(@as(u32, 1), f.world.entityCount());
    try testing.expect(!f.world.contains(a));
    try testing.expect(f.world.contains(b));
}

test "a stale entity is refused rather than resolving to the slot's new occupant" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const first = try f.world.create();
    try testing.expect(f.world.destroy(first));

    const second = try f.world.create();
    try testing.expectEqual(first.index, second.index);
    try testing.expect(!f.world.contains(first));
    try testing.expect(f.world.contains(second));

    // And destroying a stale handle is false, not a crash and not a second removal.
    try testing.expect(!f.world.destroy(first));
    try testing.expect(!f.world.destroy(Entity.none));
    try testing.expect(f.world.contains(second));
}

test "structural changes move the mutation counter" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const before = f.world.mutation;
    const e = try f.world.create();
    try testing.expect(f.world.mutation != before);

    const after_create = f.world.mutation;
    try testing.expect(f.world.destroy(e));
    try testing.expect(f.world.mutation != after_create);

    // A refused destroy changed nothing, so it must not claim to have.
    const after_destroy = f.world.mutation;
    try testing.expect(!f.world.destroy(e));
    try testing.expectEqual(after_destroy, f.world.mutation);
}

test "the entity limit refuses rather than allocating" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .{ .max_entities = 2 });
    defer f.deinit(gpa);

    _ = try f.world.create();
    const second = try f.world.create();
    try testing.expectError(error.EntityLimit, f.world.create());

    // Freeing one makes room again: the limit counts live entities, not slots ever used.
    try testing.expect(f.world.destroy(second));
    _ = try f.world.create();
}

test "registering a component type registers its schema" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const transform = try f.world.registerComponent(transformInfo());
    try testing.expectEqual(@as(u32, 1), f.world.componentTypeCount());

    const info = f.world.componentInfo(transform).?;
    try testing.expectEqualStrings("foundry:transform", info.name);
    try testing.expectEqual(@as(u32, 8), info.size);
    try testing.expectEqual(@as(u32, 8), info.stride);

    // Findable by the schema id, which is the lookup content goes through.
    const found = f.world.findComponent(data.SchemaId.fromStringUnchecked("foundry:transform"));
    try testing.expect(found != null);
    try testing.expect(found.?.eql(transform));

    // And the schema is in the shared registry, where a package that defines an instance
    // of this component will find it.
    try testing.expect(f.schemas.lookup(info.id) != null);
    try testing.expectEqual(@as(u32, 2), f.schemas.lookup(info.id).?.fields.len);
}

test "the name is checked against the schema it claims to spell" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    var mismatched = transformInfo();
    mismatched.name = "foundry:sprite";
    try testing.expectError(error.InvalidComponentName, f.world.registerComponent(mismatched));

    var not_an_id = transformInfo();
    not_an_id.name = "Foundry:Transform";
    try testing.expectError(error.InvalidComponentName, f.world.registerComponent(not_an_id));

    try testing.expectEqual(@as(u32, 0), f.world.componentTypeCount());
}

test "a component type is registered once, and adding is not replacing" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    _ = try f.world.registerComponent(transformInfo());

    // The identical registration is refused too. Re-registering a *schema* is ordinary —
    // two packages carrying the same one — but a component type has one owner, and
    // silently accepting a second would make the winner depend on arrival order.
    try testing.expectError(error.ComponentTypeExists, f.world.registerComponent(transformInfo()));
    try testing.expectEqual(@as(u32, 1), f.world.componentTypeCount());
}

test "a marker component has no bytes and is legal" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const marker = try f.world.registerComponent(.{
        .schema = .{
            .id = data.SchemaId.fromStringUnchecked("sandbox:selected"),
            .version = 1,
            .fields = &.{},
        },
        .name = "sandbox:selected",
        .size = 0,
        .alignment = 1,
    });

    const info = f.world.componentInfo(marker).?;
    try testing.expectEqual(@as(u32, 0), info.size);
    try testing.expectEqual(@as(u32, 0), info.stride);
}

test "alignment must be a power of two" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    var zero = transformInfo();
    zero.alignment = 0;
    try testing.expectError(error.InvalidComponentAlignment, f.world.registerComponent(zero));

    var odd = transformInfo();
    odd.alignment = 6;
    try testing.expectError(error.InvalidComponentAlignment, f.world.registerComponent(odd));
}

test "component types are registered before entities exist" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    _ = try f.world.create();
    try testing.expectError(error.WorldNotEmpty, f.world.registerComponent(transformInfo()));

    // Still refused once the entity is gone: the slot was used, and a type arriving now
    // would have no data for anything created before it.
    try testing.expect(f.world.destroy(.{ .index = 0, .generation = 1 }));
    try testing.expectError(error.WorldNotEmpty, f.world.registerComponent(transformInfo()));
}

test "the component type limit refuses" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .{ .max_component_types = 1 });
    defer f.deinit(gpa);

    _ = try f.world.registerComponent(transformInfo());

    var second = transformInfo();
    second.schema.id = data.SchemaId.fromStringUnchecked("foundry:sprite");
    second.name = "foundry:sprite";
    try testing.expectError(error.ComponentTypeLimit, f.world.registerComponent(second));
}

test "a schema extended after registration is followed, not shadowed" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const transform = try f.world.registerComponent(transformInfo());
    try testing.expectEqual(@as(u32, 1), f.world.componentSchema(transform).?.version);

    // A package loaded later extends the schema, additively, as a mod adding a field
    // would. The registry updates it in place behind the handle...
    _ = try f.schemas.register(gpa, .{
        .id = data.SchemaId.fromStringUnchecked("foundry:transform"),
        .version = 2,
        .fields = &.{
            .{ .name = "x", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
            .{ .name = "y", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
            .{ .name = "rotation", .type = .f32, .presence = .{ .default = .{ .float = 0 } }, .since = 2 },
        },
    });

    // ...so the component type sees the extension without being re-registered. Holding a
    // copy of the schema here is the one thing that would quietly not.
    const schema = f.world.componentSchema(transform).?;
    try testing.expectEqual(@as(u32, 2), schema.version);
    try testing.expectEqual(@as(usize, 3), schema.fields.len);
}

test "a refused registration leaves the world unchanged" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    // A schema the registry itself refuses: version 0.
    var bad = transformInfo();
    bad.schema.version = 0;
    try testing.expectError(error.InvalidVersion, f.world.registerComponent(bad));

    try testing.expectEqual(@as(u32, 0), f.world.componentTypeCount());
    try testing.expect(f.world.findComponent(bad.schema.id) == null);

    // And the good one still registers afterwards.
    _ = try f.world.registerComponent(transformInfo());
    try testing.expectEqual(@as(u32, 1), f.world.componentTypeCount());
}

// -- component storage, through the world ------------------------------------------

fn spriteInfo() ComponentTypeInfo {
    return .{
        .schema = .{
            .id = data.SchemaId.fromStringUnchecked("foundry:sprite"),
            .version = 1,
            .fields = &.{
                .{ .name = "texture", .type = .id, .presence = .optional },
            },
        },
        .name = "foundry:sprite",
        .size = 4,
        .alignment = 4,
    };
}

const Transform = extern struct { x: f32, y: f32 };

fn transformOf(bytes: []u8) *Transform {
    return @ptrCast(@alignCast(bytes.ptr));
}

test "a component is added to an entity and read back" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const transform = try f.world.registerComponent(transformInfo());
    const e = try f.world.create();

    var value: Transform = .{ .x = 3, .y = 4 };
    const bytes = try f.world.addComponent(e, transform, std.mem.asBytes(&value));
    try testing.expectEqual(@as(f32, 3), transformOf(bytes).x);

    try testing.expect(f.world.hasComponent(e, transform));
    try testing.expectEqual(@as(f32, 4), transformOf(f.world.getComponent(e, transform).?).y);
    try testing.expectEqual(@as(u32, 1), f.world.componentCount(transform));

    // The borrow is writable, and the world is where the value lives.
    transformOf(f.world.getComponent(e, transform).?).x = 9;
    try testing.expectEqual(@as(f32, 9), transformOf(f.world.getComponent(e, transform).?).x);

    try testing.expect(f.world.removeComponent(e, transform));
    try testing.expect(!f.world.hasComponent(e, transform));
    try testing.expect(f.world.getComponent(e, transform) == null);
    try testing.expect(!f.world.removeComponent(e, transform));
}

test "component types are independent of each other" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const transform = try f.world.registerComponent(transformInfo());
    const sprite = try f.world.registerComponent(spriteInfo());

    const both = try f.world.create();
    const only_transform = try f.world.create();

    var value: Transform = .{ .x = 1, .y = 2 };
    _ = try f.world.addComponent(both, transform, std.mem.asBytes(&value));
    _ = try f.world.addComponent(both, sprite, null);
    _ = try f.world.addComponent(only_transform, transform, std.mem.asBytes(&value));

    try testing.expect(f.world.hasComponent(both, sprite));
    try testing.expect(!f.world.hasComponent(only_transform, sprite));
    try testing.expectEqual(@as(u32, 2), f.world.componentCount(transform));
    try testing.expectEqual(@as(u32, 1), f.world.componentCount(sprite));

    // Removing one leaves the other alone.
    try testing.expect(f.world.removeComponent(both, sprite));
    try testing.expect(f.world.hasComponent(both, transform));
}

test "adding a component refuses what it cannot do" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const transform = try f.world.registerComponent(transformInfo());
    const e = try f.world.create();
    var value: Transform = .{ .x = 0, .y = 0 };

    _ = try f.world.addComponent(e, transform, std.mem.asBytes(&value));
    try testing.expectError(
        error.ComponentExists,
        f.world.addComponent(e, transform, std.mem.asBytes(&value)),
    );

    // A handle naming no registered type — which is what content or a save can hand over.
    const foreign: ComponentType = .{ .index = 99, .generation = 1 };
    try testing.expectError(error.UnknownComponentType, f.world.addComponent(e, foreign, null));
    try testing.expect(f.world.getComponent(e, foreign) == null);
    try testing.expect(!f.world.hasComponent(e, foreign));
    try testing.expect(!f.world.removeComponent(e, foreign));

    // A stale entity.
    const dead = try f.world.create();
    try testing.expect(f.world.destroy(dead));
    try testing.expectError(error.NoSuchEntity, f.world.addComponent(dead, transform, null));
    try testing.expectError(error.NoSuchEntity, f.world.addComponent(Entity.none, transform, null));

    // Bytes that are not the type's size — a transform is eight — which would otherwise
    // write past the slot.
    var wrong: u32 = 0;
    try testing.expectError(
        error.ComponentSizeMismatch,
        f.world.addComponent(e, transform, std.mem.asBytes(&wrong)),
    );
}

test "destroying an entity takes its components with it" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const transform = try f.world.registerComponent(transformInfo());
    const sprite = try f.world.registerComponent(spriteInfo());

    const e = try f.world.create();
    var value: Transform = .{ .x = 5, .y = 6 };
    _ = try f.world.addComponent(e, transform, std.mem.asBytes(&value));
    _ = try f.world.addComponent(e, sprite, null);
    try testing.expectEqual(@as(u32, 1), f.world.componentCount(transform));

    try testing.expect(f.world.destroy(e));
    try testing.expectEqual(@as(u32, 0), f.world.componentCount(transform));
    try testing.expectEqual(@as(u32, 0), f.world.componentCount(sprite));

    // And the entity that reuses the slot starts empty rather than inheriting them.
    const reused = try f.world.create();
    try testing.expectEqual(e.index, reused.index);
    try testing.expect(!f.world.hasComponent(reused, transform));
    try testing.expect(!f.world.hasComponent(reused, sprite));
}

test "adding and removing a component moves the mutation counter" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, .default);
    defer f.deinit(gpa);

    const transform = try f.world.registerComponent(transformInfo());
    const e = try f.world.create();

    const before = f.world.mutation;
    _ = try f.world.addComponent(e, transform, null);
    try testing.expect(f.world.mutation != before);

    const after_add = f.world.mutation;
    try testing.expect(f.world.removeComponent(e, transform));
    try testing.expect(f.world.mutation != after_add);

    // A removal that removed nothing changed nothing.
    const after_remove = f.world.mutation;
    try testing.expect(!f.world.removeComponent(e, transform));
    try testing.expectEqual(after_remove, f.world.mutation);
}
