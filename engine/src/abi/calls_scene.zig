//! `scene`, as the table publishes it: component types, entities, systems and queries.
//!
//! The boundary owns no world. A host supplies one, and every entry below is deliberately
//! only validation, one subsystem call and error translation. The host also owns the small
//! amount of stable callback/query metadata the C ABI needs, so `scene` remains unaware that
//! its ordinary runtime registrations arrived from native code.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const scene = @import("scene");

const host_mod = @import("host.zig");
const types = @import("types.zig");

const Bool = types.Bool;
const ComponentDesc = types.ComponentDesc;
const ComponentType = types.ComponentType;
const ContentId = types.ContentId;
const Cursor = types.Cursor;
const Entity = types.Entity;
const Mod = types.Mod;
const Record = types.Record;
const Result = types.Result;
const SchemaId = types.SchemaId;
const Str = types.Str;
const SystemDesc = types.SystemDesc;

pub fn Of(comptime H: type) type {
    return struct {
        // -- Component types -----------------------------------------------------------

        pub fn worldRegisterComponent(self: Mod, desc: ?*const ComponentDesc, out: ?*ComponentType) callconv(.c) Result {
            const supplied = desc orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;

            if (self.isNone() or supplied.schema.isNone()) return .invalid_argument;
            if (h.modId(self) == null) return .invalid_handle;
            const name = supplied.name.utf8() orelse return .invalid_argument;
            if (name.len == 0) return .invalid_argument;
            if (supplied.alignment == 0 or !std.math.isPowerOfTwo(supplied.alignment)) {
                return .invalid_argument;
            }

            const schema = world.schemas.lookup(supplied.schema) orelse return .not_found;
            const slot = h.openComponent(self, supplied.*) orelse return .limit;

            const t = world.registerComponent(.{
                .schema = schema.*,
                .name = name,
                .size = supplied.size,
                .alignment = supplied.alignment,
                .ctx = slot,
                .construct = if (supplied.construct != null) &H.componentConstruct else null,
                .destruct = if (supplied.destruct != null) &H.componentDestruct else null,
            }) catch |err| {
                h.closeComponent(slot);
                return registerFailure(err);
            };

            slot.type = t;
            destination.* = .wrap(t);
            return .ok;
        }

        pub fn worldFindComponentType(schema: SchemaId, out: ?*ComponentType) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;
            if (schema.isNone()) return .invalid_argument;

            const t = world.findComponent(schema) orelse return .not_found;
            destination.* = .wrap(t);
            return .ok;
        }

        pub fn worldComponentTypeNext(cursor: ?*Cursor, out: ?*ComponentType) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;

            const generation = walkGeneration(world.componentTypeGeneration());
            if (!c.isBegin() and c.generation() != generation) return .invalid_argument;

            // The cursor stamp above is what actually catches a registration mid-walk: the
            // iterator is rebuilt on every call, so its own guard cannot fire here. It is
            // still the checked form, because **no entry point may call an API that can
            // assert** — a rule that survives someone later hoisting the iterator.
            var it = world.componentTypes();
            it.slot = c.index();
            const info = it.nextChecked() catch return .invalid_argument;
            const found = info orelse return .end;
            destination.* = .wrap(found.type);
            c.* = .at(generation, it.slot);
            return .ok;
        }

        pub fn worldComponentTypeSchema(t: ComponentType, out: ?*SchemaId) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const info = typeInfo(t) catch |err| return componentRefusal(err);
            destination.* = info.id;
            return .ok;
        }

        pub fn worldComponentTypeName(t: ComponentType, out: ?*Str) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const info = typeInfo(t) catch |err| return componentRefusal(err);
            destination.* = .from(info.name);
            return .ok;
        }

        pub fn worldComponentTypeSize(t: ComponentType, out: ?*u32) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const info = typeInfo(t) catch |err| return componentRefusal(err);
            destination.* = info.size;
            return .ok;
        }

        pub fn worldComponentTypeAlignment(t: ComponentType, out: ?*u32) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const info = typeInfo(t) catch |err| return componentRefusal(err);
            destination.* = info.alignment;
            return .ok;
        }

        pub fn worldComponentTypeCount(t: ComponentType, out: ?*u32) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const info = typeInfo(t) catch |err| return componentRefusal(err);
            destination.* = info.count;
            return .ok;
        }

        pub fn worldComponentTypeSavable(t: ComponentType, out: ?*Bool) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const info = typeInfo(t) catch |err| return componentRefusal(err);
            destination.* = types.boolOut(info.savable);
            return .ok;
        }

        // -- Entities ------------------------------------------------------------------

        pub fn worldCreateEntity(out: ?*Entity) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;

            const entity = world.create() catch |err| return createFailure(err);
            destination.* = .wrap(entity);
            return .ok;
        }

        pub fn worldDestroyEntity(entity: Entity) callconv(.c) Result {
            const world = boundWorld() orelse return .unavailable;
            if (!world.destroy(entity.unwrap(scene.Entity))) return .invalid_handle;
            return .ok;
        }

        pub fn worldContains(entity: Entity, out: ?*Bool) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const world = boundWorld() orelse return .unavailable;
            destination.* = types.boolOut(world.contains(entity.unwrap(scene.Entity)));
            return .ok;
        }

        pub fn worldEntityCount(out: ?*u32) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const world = boundWorld() orelse return .unavailable;
            destination.* = world.entityCount();
            return .ok;
        }

        pub fn worldNextEntity(cursor: ?*Cursor, out: ?*Entity) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const world = boundWorld() orelse return .unavailable;

            const generation = walkGeneration(world.mutationGeneration());
            if (!c.isBegin() and c.generation() != generation) return .invalid_argument;

            // Checked for the reason `world_component_type_next` gives: the stamp is the
            // guard, and the boundary still never calls a form that can assert.
            var it = world.liveEntities();
            it.slot = c.index();
            const found = it.nextChecked() catch return .invalid_argument;
            const entity = found orelse return .end;
            destination.* = .wrap(entity);
            c.* = .at(generation, it.slot);
            return .ok;
        }

        // -- Components ----------------------------------------------------------------

        pub fn worldAddComponent(
            entity: Entity,
            t: ComponentType,
            initial: ?[*]const u8,
            initial_size: u32,
        ) callconv(.c) Result {
            const world = boundWorld() orelse return .unavailable;
            const component = t.unwrap(scene.ComponentType);
            const info = world.componentInfo(component) orelse return .invalid_handle;

            const source: ?[]const u8 = if (initial) |ptr| blk: {
                if (initial_size != info.size) return .invalid_argument;
                break :blk ptr[0..initial_size];
            } else blk: {
                if (initial_size != 0) return .invalid_argument;
                break :blk null;
            };

            _ = world.addComponent(entity.unwrap(scene.Entity), component, source) catch |err| return componentFailure(err);
            return .ok;
        }

        pub fn worldRemoveComponent(entity: Entity, t: ComponentType) callconv(.c) Result {
            const world = boundWorld() orelse return .unavailable;
            const component = t.unwrap(scene.ComponentType);
            _ = world.componentInfo(component) orelse return .invalid_handle;
            if (!world.contains(entity.unwrap(scene.Entity))) return .invalid_handle;
            if (!world.removeComponent(entity.unwrap(scene.Entity), component)) return .not_found;
            return .ok;
        }

        pub fn worldHasComponent(entity: Entity, t: ComponentType, out: ?*Bool) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const world = boundWorld() orelse return .unavailable;
            const component = t.unwrap(scene.ComponentType);
            _ = world.componentInfo(component) orelse return .invalid_handle;
            const e = entity.unwrap(scene.Entity);
            if (!world.contains(e)) return .invalid_handle;
            destination.* = types.boolOut(world.hasComponent(e, component));
            return .ok;
        }

        // -- Systems and queries -------------------------------------------------------

        pub fn worldRegisterSystem(self: Mod, desc: ?*const SystemDesc) callconv(.c) Result {
            const supplied = desc orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;

            if (self.isNone() or supplied.id.isNone() or supplied.update == null) return .invalid_argument;
            if (h.modId(self) == null) return .invalid_handle;
            const name = supplied.name.utf8() orelse return .invalid_argument;
            if (name.len == 0) return .invalid_argument;
            const named = data.contentId(name) catch return .invalid_argument;
            if (!named.eql(supplied.id)) return .invalid_argument;

            const slot = h.openSystem(self, supplied.*) orelse return .limit;
            _ = world.registerSystem(.{
                .id = supplied.id,
                .name = name,
                .ctx = slot,
                .update = H.systemUpdate,
            }) catch |err| {
                h.closeSystem(slot);
                return systemFailure(err);
            };
            return .ok;
        }

        pub fn worldQueryBegin(types_in: ?[*]const ComponentType, count: u32, out: ?*Cursor) callconv(.c) Result {
            const raw = types_in orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;
            if (count == 0 or count > scene.query.max_components) return .invalid_argument;

            // `World.query` deliberately treats an unregistered type as "matches nothing",
            // for a system that should be inert when the mod owning its component is absent.
            // At this boundary that reasoning does not apply — a mod cannot hold a handle to
            // a type nobody registered — so a handle the world does not know is a mistake,
            // and saying so beats an empty walk the author has to explain to themselves.
            var named: [scene.query.max_components]scene.ComponentType = undefined;
            for (raw[0..count], 0..) |t, i| {
                named[i] = t.unwrap(scene.ComponentType);
                if (world.componentInfo(named[i]) == null) return .invalid_handle;
            }
            destination.* = h.openQuery(world.query(named[0..count]));
            return .ok;
        }

        pub fn worldQueryNext(cursor: ?*Cursor, out: ?*Entity) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            _ = h.world orelse return .unavailable;

            const query = h.query(c.*) orelse return .invalid_handle;
            const found = query.inner.nextChecked() catch return .invalid_argument;
            const entity = found orelse return .end;
            destination.* = .wrap(entity);
            return .ok;
        }

        // -- Content-backed components -------------------------------------------------

        pub fn worldSpawn(template: ContentId, out: ?*Entity) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            if (template.isNone()) return .invalid_argument;

            const entity = world.spawn(&engine.store, template) catch |err| return spawnFailure(err);
            destination.* = .wrap(entity);
            return .ok;
        }

        pub fn worldSpawnScene(scene_id: ContentId, out: ?*u32) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            if (scene_id.isNone()) return .invalid_argument;

            destination.* = world.spawnScene(&engine.store, scene_id) catch |err| return spawnFailure(err);
            return .ok;
        }

        pub fn worldReadComponent(entity: Entity, t: ComponentType, out: ?*Record) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            const component = t.unwrap(scene.ComponentType);
            const schema = world.componentSchema(component) orelse return .invalid_handle;

            const fields = world.describeComponent(engine.frameAllocator(), entity.unwrap(scene.Entity), component) catch |err| return switch (err) {
                error.NotSavable => .unsupported,
                error.OutOfMemory => .out_of_memory,
                else => .internal,
            };
            // The frame, because `describeComponent` allocated into the frame arena: this
            // view is legitimately dead at the next `beginFrame`, unlike one into a package.
            destination.* = h.openNested(
                engine.contentGeneration(),
                engine.frame_index,
                fields orelse return .not_found,
                schema.*,
            );
            return .ok;
        }

        pub fn worldComponentBytes(
            self: Mod,
            entity: Entity,
            t: ComponentType,
            out: ?*?*anyopaque,
            size: ?*u32,
        ) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const extent = size orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const world = h.world orelse return .unavailable;
            if (self.isNone()) return .invalid_argument;
            if (h.modId(self) == null) return .invalid_handle;
            const component = t.unwrap(scene.ComponentType);
            const info = world.componentInfo(component) orelse return .invalid_handle;
            if (!h.ownComponent(self, component)) return .refused;

            const e = entity.unwrap(scene.Entity);
            if (!world.contains(e)) return .invalid_handle;
            const bytes = world.getComponent(e, component) orelse return .not_found;
            destination.* = if (bytes.len == 0) null else @ptrCast(@as(*u8, @ptrCast(bytes.ptr)));
            extent.* = info.size;
            return .ok;
        }

        // -- Helpers -------------------------------------------------------------------

        const ComponentRefusal = error{ Unavailable, InvalidHandle };

        fn boundWorld() ?*scene.World {
            const h = H.current() orelse return null;
            return h.world;
        }

        fn typeInfo(t: ComponentType) ComponentRefusal!scene.World.TypeInfo {
            const h = H.current() orelse return error.Unavailable;
            const world = h.world orelse return error.Unavailable;
            return world.typeInfo(t.unwrap(scene.ComponentType)) orelse error.InvalidHandle;
        }

        fn componentRefusal(err: ComponentRefusal) Result {
            return switch (err) {
                error.Unavailable => .unavailable,
                error.InvalidHandle => .invalid_handle,
            };
        }

        /// The cursor's stamp for a walk over the world.
        ///
        /// Only the mutation counter, unlike `calls_content`'s, which has to fold in a count:
        /// `scene` keeps a real counter that bumps on every structural change, so there is
        /// nothing left for a length to catch. Two changes 2^32 apart are indistinguishable
        /// in a cursor's thirty-two bits, which is the same bound every walk here has.
        fn walkGeneration(generation: u64) u32 {
            const folded: u32 = @truncate(generation);
            // Zero is `begin`, so it is the one value a live walk may not have.
            return if (folded == 0) std.math.maxInt(u32) else folded;
        }

        fn registerFailure(err: anyerror) Result {
            return switch (err) {
                error.ComponentTypeExists => .already_exists,
                error.InvalidComponentAlignment, error.InvalidComponentName => .invalid_argument,
                // Well formed and permitted in general, but not now: component types are
                // startup-only, so a world that already holds an entity is past the point.
                error.WorldNotEmpty => .refused,
                error.ComponentTypeLimit => .limit,
                error.OutOfMemory => .out_of_memory,
                else => .internal,
            };
        }

        fn createFailure(err: anyerror) Result {
            return switch (err) {
                error.EntityLimit => .limit,
                error.OutOfMemory => .out_of_memory,
                else => .internal,
            };
        }

        fn componentFailure(err: anyerror) Result {
            return switch (err) {
                error.UnknownComponentType, error.NoSuchEntity => .invalid_handle,
                error.ComponentExists => .already_exists,
                error.ComponentSizeMismatch => .invalid_argument,
                error.OutOfMemory => .out_of_memory,
                else => .internal,
            };
        }

        fn systemFailure(err: anyerror) Result {
            return switch (err) {
                error.SystemExists => .already_exists,
                error.SystemLimit => .limit,
                error.MissingSystemId => .invalid_argument,
                error.OutOfMemory => .out_of_memory,
                else => .internal,
            };
        }

        fn spawnFailure(err: anyerror) Result {
            return switch (err) {
                error.NoSuchRecord => .not_found,
                error.NotAnEntityTemplate, error.NotAScene, error.DuplicateComponent, error.ComponentSchemaMismatch => .invalid_argument,
                error.NotConstructibleFromData => .unsupported,
                error.UnknownComponentType => .not_found,
                error.EntityLimit => .limit,
                error.NoSuchEntity => .invalid_handle,
                error.ComponentExists, error.ComponentSizeMismatch => .invalid_argument,
                error.OutOfMemory => .out_of_memory,
                else => .internal,
            };
        }
    };
}

test {
    _ = host_mod;
    _ = core;
}

const testing = std.testing;
const test_engine = @import("test_engine.zig");
const api = @import("api.zig");

const TestEngine = test_engine.TestEngine;
const TestHost = host_mod.HostOf(TestEngine);
const test_table = api.TableOf(TestHost).v1;

const Fixture = struct {
    engine: TestEngine,
    world: scene.World,
    host: TestHost,

    fn init() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        self.* = .{
            .engine = try .init(testing.allocator),
            .world = undefined,
            .host = .{},
        };
        self.engine.settle();
        self.world = .init(testing.allocator, &self.engine.schemas, .default);
        self.host = .{ .engine = &self.engine, .world = &self.world };
        self.host.bind();
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.host.unbind();
        self.world.deinit();
        self.engine.deinit();
        testing.allocator.destroy(self);
    }

    fn issueMod(self: *Fixture) Mod {
        return self.host.issueMod(core.ContentId.fromString("mymod:mod"), "mymod:mod") catch unreachable;
    }
};

const Constructed = struct {
    calls: u32 = 0,
};

fn constructCounter(ctx: ?*anyopaque, out: ?*anyopaque) callconv(.c) void {
    const state: *Constructed = @ptrCast(@alignCast(ctx.?));
    state.calls += 1;
    const value: *u32 = @ptrCast(@alignCast(out.?));
    value.* = 42;
}

test "a native component is a world component and only its owner gets raw bytes" {
    const f = try Fixture.init();
    defer f.deinit();

    _ = try f.engine.loadPackage("mymod:content",
        \\@schema mymod:counter { value u32 }
    );

    var constructed: Constructed = .{};
    var desc: ComponentDesc = .{
        .schema = data.SchemaId.fromStringUnchecked("mymod:counter"),
        .name = .from("mymod:counter"),
        .size = @sizeOf(u32),
        .alignment = @alignOf(u32),
        .ctx = &constructed,
        .construct = &constructCounter,
    };
    const owner = f.issueMod();
    var t: ComponentType = .none;
    try testing.expectEqual(Result.ok, test_table.world_register_component(owner, &desc, &t));

    var count: u32 = 0;
    try testing.expectEqual(Result.ok, test_table.world_component_type_count(t, &count));
    try testing.expectEqual(@as(u32, 0), count);

    var entity: Entity = .none;
    try testing.expectEqual(Result.ok, test_table.world_create_entity(&entity));
    try testing.expectEqual(Result.ok, test_table.world_add_component(entity, t, null, 0));
    try testing.expectEqual(@as(u32, 1), constructed.calls);

    var raw: ?*anyopaque = null;
    var bytes: u32 = 0;
    try testing.expectEqual(Result.ok, test_table.world_component_bytes(owner, entity, t, &raw, &bytes));
    try testing.expectEqual(@as(u32, @sizeOf(u32)), bytes);
    const value: *u32 = @ptrCast(@alignCast(raw.?));
    try testing.expectEqual(@as(u32, 42), value.*);

    try testing.expectEqual(
        Result.invalid_handle,
        test_table.world_component_bytes(.{ .bits = 2 }, entity, t, &raw, &bytes),
    );
    var described: Record = .none;
    try testing.expectEqual(Result.unsupported, test_table.world_read_component(entity, t, &described));
}

test "scene cursors and queries refuse a structural mutation" {
    const f = try Fixture.init();
    defer f.deinit();

    _ = try f.engine.loadPackage("mymod:content",
        \\@schema mymod:tag { value u32 }
    );
    var desc: ComponentDesc = .{
        .schema = data.SchemaId.fromStringUnchecked("mymod:tag"),
        .name = .from("mymod:tag"),
        .size = 0,
        .alignment = 1,
    };
    var t: ComponentType = .none;
    try testing.expectEqual(Result.ok, test_table.world_register_component(f.issueMod(), &desc, &t));

    var first: Entity = .none;
    try testing.expectEqual(Result.ok, test_table.world_create_entity(&first));
    try testing.expectEqual(Result.ok, test_table.world_add_component(first, t, null, 0));

    var entities: Cursor = .begin;
    var seen: Entity = .none;
    try testing.expectEqual(Result.ok, test_table.world_next_entity(&entities, &seen));
    var second: Entity = .none;
    try testing.expectEqual(Result.ok, test_table.world_create_entity(&second));
    try testing.expectEqual(Result.invalid_argument, test_table.world_next_entity(&entities, &seen));

    var query: Cursor = .begin;
    var wanted = [_]ComponentType{t};
    try testing.expectEqual(Result.ok, test_table.world_query_begin(&wanted, @intCast(wanted.len), &query));
    try testing.expectEqual(Result.ok, test_table.world_query_next(&query, &seen));
    try testing.expectEqual(Result.ok, test_table.world_add_component(second, t, null, 0));
    try testing.expectEqual(Result.invalid_argument, test_table.world_query_next(&query, &seen));
}

const SystemCalls = struct {
    ticks: u32 = 0,
    last_tick: u64 = 0,
};

fn countSystem(ctx: ?*anyopaque, step: ?*const types.Step) callconv(.c) void {
    const calls: *SystemCalls = @ptrCast(@alignCast(ctx.?));
    calls.ticks += 1;
    calls.last_tick = step.?.tick;
}

test "a native system receives the fixed step through the ABI bridge" {
    const f = try Fixture.init();
    defer f.deinit();

    var calls: SystemCalls = .{};
    var desc: SystemDesc = .{
        .id = core.ContentId.fromString("mymod:system"),
        .name = .from("mymod:system"),
        .ctx = &calls,
        .update = &countSystem,
    };
    try testing.expectEqual(Result.ok, test_table.world_register_system(f.issueMod(), &desc));
    f.world.update(.{ .tick = 7, .delta = .fromMillis(16) });
    try testing.expectEqual(@as(u32, 1), calls.ticks);
    try testing.expectEqual(@as(u64, 7), calls.last_tick);
}

/// An engine-shaped component: derived, and therefore savable, which is what makes it the
/// one a mod can read through its schema. A mod's own raw type deliberately cannot be.
const Position = struct {
    pub const component = "test:position";
    x: f32 = 0,
    y: f32 = 0,
};

test "a savable component is readable through its schema, one field at a time" {
    const f = try Fixture.init();
    defer f.deinit();

    const registered = try f.world.registerComponent(scene.componentType(Position));
    const entity = try f.world.create();
    const bytes = try f.world.addComponent(entity, registered, std.mem.asBytes(&Position{ .x = 3, .y = -4 }));
    _ = bytes;

    const t: ComponentType = .wrap(registered);
    var savable: Bool = 0;
    try testing.expectEqual(Result.ok, test_table.world_component_type_savable(t, &savable));
    try testing.expect(types.boolIn(savable));

    // The read a mod does: a record handle, then the schema's own field names. Nothing here
    // knows `Position`'s layout, which is the whole point — the same calls work for a type
    // this build was never compiled against.
    var record: Record = .none;
    try testing.expectEqual(Result.ok, test_table.world_read_component(.wrap(entity), t, &record));

    var count: u32 = 0;
    try testing.expectEqual(Result.ok, test_table.record_field_count(record, &count));
    try testing.expectEqual(@as(u32, 2), count);

    var field: u32 = 0;
    try testing.expectEqual(Result.ok, test_table.record_field_index(record, .from("y"), &field));
    var y: f32 = 0;
    try testing.expectEqual(Result.ok, test_table.record_get_f32(record, field, &y));
    try testing.expectEqual(@as(f32, -4), y);

    try testing.expectEqual(Result.ok, test_table.record_field_index(record, .from("x"), &field));
    var x: f32 = 0;
    try testing.expectEqual(Result.ok, test_table.record_get_f32(record, field, &x));
    try testing.expectEqual(@as(f32, 3), x);
}

test "a described component dies with the frame that serialized it" {
    const f = try Fixture.init();
    defer f.deinit();

    const registered = try f.world.registerComponent(scene.componentType(Position));
    const entity = try f.world.create();
    _ = try f.world.addComponent(entity, registered, std.mem.asBytes(&Position{ .x = 1, .y = 2 }));

    var record: Record = .none;
    try testing.expectEqual(
        Result.ok,
        test_table.world_read_component(.wrap(entity), .wrap(registered), &record),
    );
    var field: u32 = 0;
    try testing.expectEqual(Result.ok, test_table.record_field_index(record, .from("x"), &field));

    // The bytes it borrows belong to the frame arena, so the next frame owns them. Nothing
    // about the content generation changed — this is the second lifetime a nested view has,
    // and the only reason a described component is safe to hand out at all.
    f.engine.nextFrame();
    try testing.expectEqual(Result.invalid_handle, test_table.record_field_index(record, .from("x"), &field));

    // And a view into a package is untouched by the same frame, because its bytes are not
    // the arena's. The two lifetimes are genuinely two.
    _ = try f.engine.loadPackage("later:content",
        \\@schema thing { inner { n i32 } }
        \\thing later:one { inner { n 7 } }
    );
    var outer: Record = .none;
    try testing.expectEqual(Result.ok, test_table.content_find(core.ContentId.fromString("later:one"), &outer));
    var inner: Record = .none;
    try testing.expectEqual(Result.ok, test_table.record_field_index(outer, .from("inner"), &field));
    try testing.expectEqual(Result.ok, test_table.record_nested(outer, field, &inner));
    f.engine.nextFrame();
    try testing.expectEqual(Result.ok, test_table.record_field_index(inner, .from("n"), &field));
    var n: i64 = 0;
    try testing.expectEqual(Result.ok, test_table.record_get_i64(inner, field, &n));
    try testing.expectEqual(@as(i64, 7), n);
}

test "the component type accessors describe a type the caller never declared" {
    const f = try Fixture.init();
    defer f.deinit();

    const registered = try f.world.registerComponent(scene.componentType(Position));
    const t: ComponentType = .wrap(registered);

    var schema: SchemaId = .none;
    try testing.expectEqual(Result.ok, test_table.world_component_type_schema(t, &schema));
    try testing.expect(schema.eql(data.SchemaId.fromStringUnchecked("test:position")));

    var found: ComponentType = .none;
    try testing.expectEqual(Result.ok, test_table.world_find_component_type(schema, &found));
    try testing.expect(found.eql(t));

    var name: Str = .empty;
    try testing.expectEqual(Result.ok, test_table.world_component_type_name(t, &name));
    try testing.expectEqualStrings("test:position", name.bytes().?);

    var size: u32 = 0;
    var alignment: u32 = 0;
    try testing.expectEqual(Result.ok, test_table.world_component_type_size(t, &size));
    try testing.expectEqual(Result.ok, test_table.world_component_type_alignment(t, &alignment));
    try testing.expectEqual(@as(u32, @sizeOf(Position)), size);
    try testing.expectEqual(@as(u32, @alignOf(Position)), alignment);

    // The count is entities-with-one, and it follows the world rather than being a snapshot.
    var count: u32 = 0;
    try testing.expectEqual(Result.ok, test_table.world_component_type_count(t, &count));
    try testing.expectEqual(@as(u32, 0), count);
    const entity = try f.world.create();
    _ = try f.world.addComponent(entity, registered, null);
    try testing.expectEqual(Result.ok, test_table.world_component_type_count(t, &count));
    try testing.expectEqual(@as(u32, 1), count);

    // The walk reaches it, and a stale handle is refused rather than answered.
    var cursor: Cursor = .begin;
    var walked: ComponentType = .none;
    try testing.expectEqual(Result.ok, test_table.world_component_type_next(&cursor, &walked));
    try testing.expect(walked.eql(t));
    try testing.expectEqual(Result.end, test_table.world_component_type_next(&cursor, &walked));

    try testing.expectEqual(
        Result.invalid_handle,
        test_table.world_component_type_name(.{ .bits = 0xdead_beef }, &name),
    );
}

test "entities are created, asked about and destroyed through the table" {
    const f = try Fixture.init();
    defer f.deinit();

    const registered = try f.world.registerComponent(scene.componentType(Position));
    const t: ComponentType = .wrap(registered);

    var entity: Entity = .none;
    try testing.expectEqual(Result.ok, test_table.world_create_entity(&entity));

    var count: u32 = 0;
    try testing.expectEqual(Result.ok, test_table.world_entity_count(&count));
    try testing.expectEqual(@as(u32, 1), count);

    var present: Bool = 0;
    try testing.expectEqual(Result.ok, test_table.world_has_component(entity, t, &present));
    try testing.expect(!types.boolIn(present));

    try testing.expectEqual(Result.ok, test_table.world_add_component(entity, t, null, 0));
    try testing.expectEqual(Result.ok, test_table.world_has_component(entity, t, &present));
    try testing.expect(types.boolIn(present));

    // A second one is `already_exists`, and bytes of the wrong length are the caller holding
    // a different struct than the one it registered — a more fundamental mistake, and a
    // different answer.
    try testing.expectEqual(Result.already_exists, test_table.world_add_component(entity, t, null, 0));
    var wrong: [3]u8 = @splat(0);
    var other: Entity = .none;
    try testing.expectEqual(Result.ok, test_table.world_create_entity(&other));
    try testing.expectEqual(
        Result.invalid_argument,
        test_table.world_add_component(other, t, &wrong, wrong.len),
    );

    try testing.expectEqual(Result.ok, test_table.world_remove_component(entity, t));
    try testing.expectEqual(Result.not_found, test_table.world_remove_component(entity, t));

    var contains: Bool = 0;
    try testing.expectEqual(Result.ok, test_table.world_destroy_entity(entity));
    try testing.expectEqual(Result.ok, test_table.world_contains(entity, &contains));
    try testing.expect(!types.boolIn(contains));
    // A stale handle is a normal condition for `contains` and a refusal for `destroy`: one
    // is a question and the other is an instruction.
    try testing.expectEqual(Result.invalid_handle, test_table.world_destroy_entity(entity));
}

test "registration refuses everything a mod can get wrong about a component type" {
    const f = try Fixture.init();
    defer f.deinit();

    _ = try f.engine.loadPackage("mymod:content",
        \\@schema mymod:counter { value u32 }
    );
    const owner = f.issueMod();
    const schema = data.SchemaId.fromStringUnchecked("mymod:counter");
    var t: ComponentType = .none;

    const good: ComponentDesc = .{
        .schema = schema,
        .name = .from("mymod:counter"),
        .size = 4,
        .alignment = 4,
    };

    var no_mod = good;
    try testing.expectEqual(
        Result.invalid_argument,
        test_table.world_register_component(.none, &no_mod, &t),
    );
    try testing.expectEqual(
        Result.invalid_handle,
        test_table.world_register_component(.{ .bits = 1 }, &no_mod, &t),
    );

    var unaligned = good;
    unaligned.alignment = 3;
    try testing.expectEqual(
        Result.invalid_argument,
        test_table.world_register_component(owner, &unaligned, &t),
    );

    var unnamed = good;
    unnamed.name = .empty;
    try testing.expectEqual(
        Result.invalid_argument,
        test_table.world_register_component(owner, &unnamed, &t),
    );

    // A name that is not the schema's spelling. The world checks this, not the boundary, and
    // it reaches a mod as a refusal either way.
    var mismatched = good;
    mismatched.name = .from("mymod:other");
    try testing.expectEqual(
        Result.invalid_argument,
        test_table.world_register_component(owner, &mismatched, &t),
    );

    var unknown = good;
    unknown.schema = data.SchemaId.fromStringUnchecked("mymod:absent");
    unknown.name = .from("mymod:absent");
    try testing.expectEqual(
        Result.not_found,
        test_table.world_register_component(owner, &unknown, &t),
    );

    var accepted = good;
    try testing.expectEqual(Result.ok, test_table.world_register_component(owner, &accepted, &t));
    try testing.expectEqual(
        Result.already_exists,
        test_table.world_register_component(owner, &accepted, &t),
    );

    // Registration is startup-only. Once the world holds an entity the answer changes, and
    // `refused` rather than `invalid_argument` is what that means: the call is well formed
    // and permitted in general, just not now.
    _ = try f.engine.loadPackage("mymod:more",
        \\@schema mymod:later { value u32 }
    );
    _ = try f.world.create();
    var late = good;
    late.schema = data.SchemaId.fromStringUnchecked("mymod:later");
    late.name = .from("mymod:later");
    try testing.expectEqual(
        Result.refused,
        test_table.world_register_component(owner, &late, &t),
    );
}

test "a query refuses an unknown type and a recycled cursor" {
    const f = try Fixture.init();
    defer f.deinit();

    const registered = try f.world.registerComponent(scene.componentType(Position));
    const t: ComponentType = .wrap(registered);
    const entity = try f.world.create();
    _ = try f.world.addComponent(entity, registered, null);

    var cursor: Cursor = .begin;
    var wanted = [_]ComponentType{.{ .bits = 0xdead_beef }};
    try testing.expectEqual(
        Result.invalid_handle,
        test_table.world_query_begin(&wanted, 1, &cursor),
    );

    wanted[0] = t;
    try testing.expectEqual(Result.invalid_argument, test_table.world_query_begin(&wanted, 0, &cursor));
    try testing.expectEqual(
        Result.invalid_argument,
        test_table.world_query_begin(&wanted, scene.query.max_components + 1, &cursor),
    );

    try testing.expectEqual(Result.ok, test_table.world_query_begin(&wanted, 1, &cursor));
    var seen: Entity = .none;
    try testing.expectEqual(Result.ok, test_table.world_query_next(&cursor, &seen));
    try testing.expect(seen.eql(.wrap(entity)));
    try testing.expectEqual(Result.end, test_table.world_query_next(&cursor, &seen));

    // The slots are a ring, so a mod that opens more than the host holds loses the oldest —
    // and hears about it, rather than walking somebody else's query.
    const first = cursor;
    var spare: Cursor = .begin;
    for (0..host_mod.max_queries) |_| {
        try testing.expectEqual(Result.ok, test_table.world_query_begin(&wanted, 1, &spare));
    }
    var lost = first;
    try testing.expectEqual(Result.invalid_handle, test_table.world_query_next(&lost, &seen));
}

test "a system is refused when its id and its name disagree, or when it is registered twice" {
    const f = try Fixture.init();
    defer f.deinit();

    var calls: SystemCalls = .{};
    const owner = f.issueMod();
    const good: SystemDesc = .{
        .id = core.ContentId.fromString("mymod:tick"),
        .name = .from("mymod:tick"),
        .ctx = &calls,
        .update = &countSystem,
    };

    // The id has no spelling at runtime, so the name is the only thing that can say what it
    // was — and the two disagreeing is a mod that will be impossible to diagnose later.
    var lying = good;
    lying.name = .from("mymod:other");
    try testing.expectEqual(Result.invalid_argument, test_table.world_register_system(owner, &lying));

    var unqualified = good;
    unqualified.id = core.ContentId.fromString("tick");
    unqualified.name = .from("tick");
    try testing.expectEqual(
        Result.invalid_argument,
        test_table.world_register_system(owner, &unqualified),
    );

    var headless = good;
    headless.update = null;
    try testing.expectEqual(
        Result.invalid_argument,
        test_table.world_register_system(owner, &headless),
    );

    var accepted = good;
    try testing.expectEqual(Result.ok, test_table.world_register_system(owner, &accepted));
    try testing.expectEqual(
        Result.already_exists,
        test_table.world_register_system(owner, &accepted),
    );
}

test "a world the host was never lent answers unavailable, not not_found" {
    var engine: TestEngine = try .init(testing.allocator);
    defer engine.deinit();
    engine.settle();

    var host: TestHost = .{ .engine = &engine };
    host.bind();
    defer host.unbind();

    // An engine without a world is a legitimate host — a content tool, a headless checker —
    // and every `scene` entry has to say which of the two things is missing.
    var entity: Entity = .none;
    try testing.expectEqual(Result.unavailable, test_table.world_create_entity(&entity));
    var count: u32 = 0;
    try testing.expectEqual(Result.unavailable, test_table.world_entity_count(&count));
    var t: ComponentType = .none;
    try testing.expectEqual(
        Result.unavailable,
        test_table.world_find_component_type(data.SchemaId.fromStringUnchecked("a:b"), &t),
    );
}
