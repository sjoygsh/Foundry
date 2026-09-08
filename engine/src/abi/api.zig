//! `FoundryApi_v1`, and the query function a mod is handed.
//!
//! This file is the Zig half of the header's table. The C half is the specification; this
//! one has to match it exactly, and `agreement.zig` is what proves it does — every field's
//! offset, in order, so a capability added to one and not the other fails the build rather
//! than shifting every pointer after it.
//!
//! **The table is a value, not an interface.** It is built once per host type at comptime,
//! lives in static storage, and is handed out by pointer. `get_api` is the only way a mod
//! reaches it, which is what makes ADR-0004's "added alongside, never replacing"
//! implementable: a `_v2` is a second struct beside this one and a host offers both.
//!
//! Design: `docs/design/public-abi.md` §3 and §4.

const std = @import("std");

const asset_calls = @import("calls_asset.zig");
const content_calls = @import("calls_content.zig");
const engine_calls = @import("calls_engine.zig");
const scene_calls = @import("calls_scene.zig");
const types = @import("types.zig");

const Asset = types.Asset;
const Bool = types.Bool;
const ComponentDesc = types.ComponentDesc;
const ComponentType = types.ComponentType;
const ContentId = types.ContentId;
const Cursor = types.Cursor;
const Entity = types.Entity;
const FieldType = types.FieldType;
const Package = types.Package;
const Record = types.Record;
const Schema = types.Schema;
const SchemaId = types.SchemaId;
const LogRecord = types.LogRecord;
const MemoryCounter = types.MemoryCounter;
const MemoryStats = types.MemoryStats;
const Mod = types.Mod;
const Result = types.Result;
const Str = types.Str;
const SystemDesc = types.SystemDesc;

/// Everything a mod may call.
///
/// **Enumerations arrive as `i32`, never as a Zig enum**, and that is a rule rather than a
/// style. A value from the other side is untrusted, and an enum-typed parameter holding a
/// number the enum does not have is illegal behaviour in Zig before any validation can run —
/// so a number crosses as a number and is looked up. Enumerations *leaving* are enums,
/// because those the engine produces.
///
/// Field order is the contract. Append only, and never insert.
pub const Api_v1 = extern struct {
    version: u32,
    size: u32,

    // -- Results and logging -----------------------------------------------------------

    result_name: *const fn (result: i32) callconv(.c) Str,
    log_write: *const fn (self: Mod, level: i32, message: Str) callconv(.c) Result,
    log_next: *const fn (cursor: ?*Cursor, out: ?*LogRecord) callconv(.c) Result,

    // -- Content identity --------------------------------------------------------------

    id_from_string: *const fn (text: Str, out: ?*ContentId) callconv(.c) Result,
    id_to_string: *const fn (id: ContentId, out: ?*Str) callconv(.c) Result,
    id_copy_string: *const fn (id: ContentId, buffer: ?[*]u8, capacity: u64, needed: ?*u64) callconv(.c) Result,

    // -- The frame ---------------------------------------------------------------------

    frame_index: *const fn (out: ?*u64) callconv(.c) Result,
    frame_delta_ns: *const fn (out: ?*u64) callconv(.c) Result,
    elapsed_ns: *const fn (out: ?*u64) callconv(.c) Result,
    tick_delta_ns: *const fn (out: ?*u64) callconv(.c) Result,

    // -- The profiler ------------------------------------------------------------------

    scope_begin: *const fn (name: Str) callconv(.c) Result,
    scope_end: *const fn () callconv(.c) Result,

    // -- Memory ------------------------------------------------------------------------

    memory_counter_open: *const fn (self: Mod, name: Str, out: ?*MemoryCounter) callconv(.c) Result,
    memory_counter_set: *const fn (counter: MemoryCounter, stats: ?*const MemoryStats) callconv(.c) Result,

    // -- Content -----------------------------------------------------------------------

    content_generation: *const fn (out: ?*u64) callconv(.c) Result,
    content_find: *const fn (id: ContentId, out: ?*Record) callconv(.c) Result,
    content_next: *const fn (cursor: ?*Cursor, out: ?*Record) callconv(.c) Result,
    content_next_of_schema: *const fn (schema: SchemaId, cursor: ?*Cursor, out: ?*Record) callconv(.c) Result,

    // -- Reading a record --------------------------------------------------------------

    record_id: *const fn (record: Record, out: ?*ContentId) callconv(.c) Result,
    record_name: *const fn (record: Record, out: ?*Str) callconv(.c) Result,
    record_schema: *const fn (record: Record, out: ?*SchemaId) callconv(.c) Result,
    record_package: *const fn (record: Record, out: ?*Package) callconv(.c) Result,

    record_field_count: *const fn (record: Record, out: ?*u32) callconv(.c) Result,
    record_field_index: *const fn (record: Record, name: Str, out: ?*u32) callconv(.c) Result,
    record_field_name: *const fn (record: Record, field: u32, out: ?*Str) callconv(.c) Result,
    record_field_type: *const fn (record: Record, field: u32, out: ?*FieldType) callconv(.c) Result,
    record_field_present: *const fn (record: Record, field: u32, out: ?*Bool) callconv(.c) Result,

    record_get_bool: *const fn (record: Record, field: u32, out: ?*Bool) callconv(.c) Result,
    record_get_i64: *const fn (record: Record, field: u32, out: ?*i64) callconv(.c) Result,
    record_get_u64: *const fn (record: Record, field: u32, out: ?*u64) callconv(.c) Result,
    record_get_f32: *const fn (record: Record, field: u32, out: ?*f32) callconv(.c) Result,
    record_get_string: *const fn (record: Record, field: u32, out: ?*Str) callconv(.c) Result,
    record_copy_string: *const fn (record: Record, field: u32, buffer: ?[*]u8, capacity: u64, needed: ?*u64) callconv(.c) Result,
    record_get_id: *const fn (record: Record, field: u32, out: ?*ContentId) callconv(.c) Result,
    record_nested: *const fn (record: Record, field: u32, out: ?*Record) callconv(.c) Result,

    record_list_len: *const fn (record: Record, field: u32, out: ?*u32) callconv(.c) Result,
    record_list_get_i64: *const fn (record: Record, field: u32, index: u32, out: ?*i64) callconv(.c) Result,
    record_list_get_f32: *const fn (record: Record, field: u32, index: u32, out: ?*f32) callconv(.c) Result,
    record_list_get_string: *const fn (record: Record, field: u32, index: u32, out: ?*Str) callconv(.c) Result,
    record_list_get_id: *const fn (record: Record, field: u32, index: u32, out: ?*ContentId) callconv(.c) Result,
    record_list_nested: *const fn (record: Record, field: u32, index: u32, out: ?*Record) callconv(.c) Result,

    // -- Packages ----------------------------------------------------------------------

    package_count: *const fn (out: ?*u32) callconv(.c) Result,
    package_next: *const fn (cursor: ?*Cursor, out: ?*Package) callconv(.c) Result,
    package_find: *const fn (id: ContentId, out: ?*Package) callconv(.c) Result,
    package_id: *const fn (package: Package, out: ?*ContentId) callconv(.c) Result,
    package_name: *const fn (package: Package, out: ?*Str) callconv(.c) Result,
    package_version: *const fn (package: Package, out: ?*u32) callconv(.c) Result,
    package_order: *const fn (package: Package, out: ?*u32) callconv(.c) Result,

    // -- Schemas -----------------------------------------------------------------------

    schema_count: *const fn (out: ?*u32) callconv(.c) Result,
    schema_next: *const fn (cursor: ?*Cursor, out: ?*Schema) callconv(.c) Result,
    schema_find: *const fn (id: SchemaId, out: ?*Schema) callconv(.c) Result,
    schema_id: *const fn (schema: Schema, out: ?*SchemaId) callconv(.c) Result,
    schema_version: *const fn (schema: Schema, out: ?*u32) callconv(.c) Result,
    schema_field_count: *const fn (schema: Schema, out: ?*u32) callconv(.c) Result,
    schema_field_name: *const fn (schema: Schema, field: u32, out: ?*Str) callconv(.c) Result,
    schema_field_type: *const fn (schema: Schema, field: u32, out: ?*FieldType) callconv(.c) Result,

    // -- Assets ------------------------------------------------------------------------

    asset_acquire: *const fn (id: ContentId, out: ?*Asset) callconv(.c) Result,
    asset_release: *const fn (handle: Asset) callconv(.c) Result,
    asset_find: *const fn (id: ContentId, out: ?*Asset) callconv(.c) Result,
    asset_next: *const fn (cursor: ?*Cursor, out: ?*Asset) callconv(.c) Result,
    asset_content_id: *const fn (handle: Asset, out: ?*ContentId) callconv(.c) Result,
    asset_schema: *const fn (handle: Asset, out: ?*SchemaId) callconv(.c) Result,
    asset_refcount: *const fn (handle: Asset, out: ?*u32) callconv(.c) Result,

    // -- Scene -------------------------------------------------------------------------

    world_register_component: *const fn (self: Mod, desc: ?*const ComponentDesc, out: ?*ComponentType) callconv(.c) Result,
    world_find_component_type: *const fn (schema: SchemaId, out: ?*ComponentType) callconv(.c) Result,
    world_component_type_next: *const fn (cursor: ?*Cursor, out: ?*ComponentType) callconv(.c) Result,
    world_component_type_schema: *const fn (t: ComponentType, out: ?*SchemaId) callconv(.c) Result,
    world_component_type_name: *const fn (t: ComponentType, out: ?*Str) callconv(.c) Result,
    world_component_type_size: *const fn (t: ComponentType, out: ?*u32) callconv(.c) Result,
    world_component_type_alignment: *const fn (t: ComponentType, out: ?*u32) callconv(.c) Result,
    world_component_type_count: *const fn (t: ComponentType, out: ?*u32) callconv(.c) Result,
    world_component_type_savable: *const fn (t: ComponentType, out: ?*Bool) callconv(.c) Result,

    world_create_entity: *const fn (out: ?*Entity) callconv(.c) Result,
    world_destroy_entity: *const fn (entity: Entity) callconv(.c) Result,
    world_contains: *const fn (entity: Entity, out: ?*Bool) callconv(.c) Result,
    world_entity_count: *const fn (out: ?*u32) callconv(.c) Result,
    world_next_entity: *const fn (cursor: ?*Cursor, out: ?*Entity) callconv(.c) Result,

    world_add_component: *const fn (entity: Entity, t: ComponentType, initial: ?[*]const u8, initial_size: u32) callconv(.c) Result,
    world_remove_component: *const fn (entity: Entity, t: ComponentType) callconv(.c) Result,
    world_has_component: *const fn (entity: Entity, t: ComponentType, out: ?*Bool) callconv(.c) Result,

    world_register_system: *const fn (self: Mod, desc: ?*const SystemDesc) callconv(.c) Result,
    world_query_begin: *const fn (wanted: ?[*]const ComponentType, count: u32, out: ?*Cursor) callconv(.c) Result,
    world_query_next: *const fn (cursor: ?*Cursor, out: ?*Entity) callconv(.c) Result,

    world_spawn: *const fn (template: ContentId, out: ?*Entity) callconv(.c) Result,
    world_spawn_scene: *const fn (id: ContentId, out: ?*u32) callconv(.c) Result,
    world_read_component: *const fn (entity: Entity, t: ComponentType, out: ?*Record) callconv(.c) Result,
    world_component_bytes: *const fn (self: Mod, entity: Entity, t: ComponentType, out: ?*?*anyopaque, size: ?*u32) callconv(.c) Result,
};

/// The table for one host type, and the `get_api` that hands it out.
pub fn TableOf(comptime H: type) type {
    const engine = engine_calls.Of(H);
    const content = content_calls.Of(H);
    const assets = asset_calls.Of(H);
    const world = scene_calls.Of(H);

    return struct {
        pub const v1: Api_v1 = .{
            .version = types.api_version_1,
            .size = @sizeOf(Api_v1),

            .result_name = engine.resultName,
            .log_write = engine.logWrite,
            .log_next = engine.logNext,

            .id_from_string = engine.idFromString,
            .id_to_string = engine.idToString,
            .id_copy_string = engine.idCopyString,

            .frame_index = engine.frameIndex,
            .frame_delta_ns = engine.frameDeltaNs,
            .elapsed_ns = engine.elapsedNs,
            .tick_delta_ns = engine.tickDeltaNs,

            .scope_begin = engine.scopeBegin,
            .scope_end = engine.scopeEnd,

            .memory_counter_open = engine.memoryCounterOpen,
            .memory_counter_set = engine.memoryCounterSet,

            .content_generation = content.contentGeneration,
            .content_find = content.contentFind,
            .content_next = content.contentNext,
            .content_next_of_schema = content.contentNextOfSchema,

            .record_id = content.recordId,
            .record_name = content.recordName,
            .record_schema = content.recordSchema,
            .record_package = content.recordPackage,

            .record_field_count = content.recordFieldCount,
            .record_field_index = content.recordFieldIndex,
            .record_field_name = content.recordFieldName,
            .record_field_type = content.recordFieldType,
            .record_field_present = content.recordFieldPresent,

            .record_get_bool = content.recordGetBool,
            .record_get_i64 = content.recordGetI64,
            .record_get_u64 = content.recordGetU64,
            .record_get_f32 = content.recordGetF32,
            .record_get_string = content.recordGetString,
            .record_copy_string = content.recordCopyString,
            .record_get_id = content.recordGetId,
            .record_nested = content.recordNested,

            .record_list_len = content.recordListLen,
            .record_list_get_i64 = content.recordListGetI64,
            .record_list_get_f32 = content.recordListGetF32,
            .record_list_get_string = content.recordListGetString,
            .record_list_get_id = content.recordListGetId,
            .record_list_nested = content.recordListNested,

            .package_count = content.packageCount,
            .package_next = content.packageNext,
            .package_find = content.packageFind,
            .package_id = content.packageId,
            .package_name = content.packageName,
            .package_version = content.packageVersion,
            .package_order = content.packageOrder,

            .schema_count = content.schemaCount,
            .schema_next = content.schemaNext,
            .schema_find = content.schemaFind,
            .schema_id = content.schemaId,
            .schema_version = content.schemaVersion,
            .schema_field_count = content.schemaFieldCount,
            .schema_field_name = content.schemaFieldName,
            .schema_field_type = content.schemaFieldType,

            .asset_acquire = assets.assetAcquire,
            .asset_release = assets.assetRelease,
            .asset_find = assets.assetFind,
            .asset_next = assets.assetNext,
            .asset_content_id = assets.assetContentId,
            .asset_schema = assets.assetSchema,
            .asset_refcount = assets.assetRefcount,

            .world_register_component = world.worldRegisterComponent,
            .world_find_component_type = world.worldFindComponentType,
            .world_component_type_next = world.worldComponentTypeNext,
            .world_component_type_schema = world.worldComponentTypeSchema,
            .world_component_type_name = world.worldComponentTypeName,
            .world_component_type_size = world.worldComponentTypeSize,
            .world_component_type_alignment = world.worldComponentTypeAlignment,
            .world_component_type_count = world.worldComponentTypeCount,
            .world_component_type_savable = world.worldComponentTypeSavable,

            .world_create_entity = world.worldCreateEntity,
            .world_destroy_entity = world.worldDestroyEntity,
            .world_contains = world.worldContains,
            .world_entity_count = world.worldEntityCount,
            .world_next_entity = world.worldNextEntity,

            .world_add_component = world.worldAddComponent,
            .world_remove_component = world.worldRemoveComponent,
            .world_has_component = world.worldHasComponent,

            .world_register_system = world.worldRegisterSystem,
            .world_query_begin = world.worldQueryBegin,
            .world_query_next = world.worldQueryNext,

            .world_spawn = world.worldSpawn,
            .world_spawn_scene = world.worldSpawnScene,
            .world_read_component = world.worldReadComponent,
            .world_component_bytes = world.worldComponentBytes,
        };

        /// What a native mod is handed (§3). **Never a crash and never a Zig error** — a
        /// version this host does not offer is null, which is a legible refusal on the
        /// mod's side rather than a fault on ours.
        pub fn getApi(version: u32) callconv(.c) ?*const anyopaque {
            if (version == types.api_version_1) return @ptrCast(&v1);
            return null;
        }
    };
}

test {
    _ = asset_calls;
    _ = content_calls;
    _ = engine_calls;
    _ = scene_calls;
}
