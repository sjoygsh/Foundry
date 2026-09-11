//! Binding 1 against a **fake table**: what the bridge does with what a table answers.
//!
//! Nothing here links an engine subsystem, which is the point — the isolated binding test
//! must not be able to pass because some real subsystem happened to be forgiving. The fake
//! records every entry the bridge calls, so the allowlist is checked by what a script can
//! reach *and* by what the bridge actually touches. The real table's semantics are proved
//! separately, in `engine/tests/script_bindings.zig`.

const std = @import("std");
const core = @import("core");
const script = @import("root.zig");

const c = script.c;
const testing = std.testing;

fn hashOf(comptime name: []const u8) u64 {
    return core.ContentId.fromString(name).hash;
}

const config_id = hashOf("fake:config");
const template_id = hashOf("fake:empty");
const config_schema = hashOf("fake:config");
const entity_schema = hashOf("foundry:entity");

const big_value: u64 = (@as(u64, 1) << 63) + 5;

/// A table that answers, and remembers being asked.
const Fake = struct {
    const max_entities = 300;

    var table: c.FoundryApi_v2 = undefined;
    var names: [1024][]const u8 = undefined;
    var name_count: usize = 0;
    var alive: [max_entities]bool = undefined;
    var generation: u64 = 7;
    var logs: u32 = 0;

    fn reset() void {
        table = std.mem.zeroes(c.FoundryApi_v2);
        table.version = 2;
        table.size = @sizeOf(c.FoundryApi_v2);
        table.id_from_string = &idFromString;
        table.id_to_string = &idToString;
        table.log_write = &logWrite;
        table.content_generation = &contentGeneration;
        table.content_find = &contentFind;
        table.content_next = &contentNext;
        table.record_schema = &recordSchema;
        table.record_field_count = &recordFieldCount;
        table.record_field_index = &recordFieldIndex;
        table.record_field_name = &recordFieldName;
        table.record_field_type = &recordFieldType;
        table.record_field_present = &recordFieldPresent;
        table.record_get_i64 = &recordGetI64;
        table.record_get_u64 = &recordGetU64;
        table.record_get_string = &recordGetString;
        table.record_get_id = &recordGetId;
        table.world_spawn = &worldSpawn;
        table.world_destroy_entity = &worldDestroyEntity;
        table.world_contains = &worldContains;
        table.world_entity_count = &worldEntityCount;
        table.world_next_entity = &worldNextEntity;
        names = undefined;
        name_count = 0;
        alive = @splat(false);
        generation = 7;
        logs = 0;
    }

    fn getApi(version: u32) callconv(.c) ?*const anyopaque {
        if (version != 2) return null;
        return &table;
    }

    fn noV2(version: u32) callconv(.c) ?*const anyopaque {
        _ = version;
        return null;
    }

    fn record(name: []const u8) void {
        if (name_count < names.len) {
            names[name_count] = name;
            name_count += 1;
        }
    }

    fn called(name: []const u8) bool {
        for (names[0..name_count]) |seen| {
            if (std.mem.eql(u8, seen, name)) return true;
        }
        return false;
    }

    fn text(bytes: []const u8) c.FoundryStr {
        return .{ .ptr = bytes.ptr, .len = bytes.len };
    }

    fn idFromString(value: c.FoundryStr, out: [*c]c.FoundryContentId) callconv(.c) c.FoundryResult {
        record("id_from_string");
        const bytes = value.ptr[0..value.len];
        if (std.mem.indexOfScalar(u8, bytes, ':') == null) return c.FOUNDRY_ERR_INVALID_ARGUMENT;
        out.*.hash = core.ContentId.fromString(bytes).hash;
        return c.FOUNDRY_OK;
    }

    fn idToString(id: c.FoundryContentId, out: [*c]c.FoundryStr) callconv(.c) c.FoundryResult {
        record("id_to_string");
        if (id.hash != config_id) return c.FOUNDRY_ERR_NOT_FOUND;
        out.* = text("fake:config");
        return c.FOUNDRY_OK;
    }

    fn logWrite(self: c.FoundryMod, level: c.FoundryLogLevel, message: c.FoundryStr) callconv(.c) c.FoundryResult {
        record("log_write");
        _ = level;
        _ = message;
        if (self.bits == 0) return c.FOUNDRY_ERR_INVALID_HANDLE;
        logs += 1;
        return c.FOUNDRY_OK;
    }

    fn contentGeneration(out: [*c]u64) callconv(.c) c.FoundryResult {
        record("content_generation");
        out.* = generation;
        return c.FOUNDRY_OK;
    }

    fn contentFind(id: c.FoundryContentId, out: [*c]c.FoundryRecord) callconv(.c) c.FoundryResult {
        record("content_find");
        if (id.hash == config_id) {
            out.*.bits = 1;
            return c.FOUNDRY_OK;
        }
        if (id.hash == template_id) {
            out.*.bits = 2;
            return c.FOUNDRY_OK;
        }
        return c.FOUNDRY_ERR_NOT_FOUND;
    }

    fn contentNext(cursor: [*c]c.FoundryCursor, out: [*c]c.FoundryRecord) callconv(.c) c.FoundryResult {
        record("content_next");
        const position = cursor.*.bits;
        if (position >= 2) return c.FOUNDRY_END;
        out.*.bits = position + 1;
        cursor.*.bits = position + 1;
        return c.FOUNDRY_OK;
    }

    fn recordSchema(handle: c.FoundryRecord, out: [*c]c.FoundrySchemaId) callconv(.c) c.FoundryResult {
        record("record_schema");
        out.*.hash = if (handle.bits == 1) config_schema else entity_schema;
        return c.FOUNDRY_OK;
    }

    fn recordFieldCount(handle: c.FoundryRecord, out: [*c]u32) callconv(.c) c.FoundryResult {
        record("record_field_count");
        out.* = if (handle.bits == 1) 4 else 1;
        return c.FOUNDRY_OK;
    }

    const config_fields = [_][]const u8{ "delay", "big", "label", "next" };

    fn recordFieldIndex(handle: c.FoundryRecord, name: c.FoundryStr, out: [*c]u32) callconv(.c) c.FoundryResult {
        record("record_field_index");
        const wanted = name.ptr[0..name.len];
        if (handle.bits == 1) {
            for (config_fields, 0..) |field, i| {
                if (std.mem.eql(u8, field, wanted)) {
                    out.* = @intCast(i);
                    return c.FOUNDRY_OK;
                }
            }
            return c.FOUNDRY_ERR_NOT_FOUND;
        }
        if (std.mem.eql(u8, wanted, "components")) {
            out.* = 0;
            return c.FOUNDRY_OK;
        }
        return c.FOUNDRY_ERR_NOT_FOUND;
    }

    fn recordFieldName(handle: c.FoundryRecord, field: u32, out: [*c]c.FoundryStr) callconv(.c) c.FoundryResult {
        record("record_field_name");
        if (handle.bits != 1 or field >= config_fields.len) return c.FOUNDRY_ERR_INVALID_ARGUMENT;
        out.* = text(config_fields[field]);
        return c.FOUNDRY_OK;
    }

    fn recordFieldType(handle: c.FoundryRecord, field: u32, out: [*c]c.FoundryFieldType) callconv(.c) c.FoundryResult {
        record("record_field_type");
        if (handle.bits != 1) {
            out.* = c.FOUNDRY_FIELD_LIST;
            return c.FOUNDRY_OK;
        }
        out.* = switch (field) {
            0 => c.FOUNDRY_FIELD_I64,
            1 => c.FOUNDRY_FIELD_U64,
            2 => c.FOUNDRY_FIELD_STRING,
            3 => c.FOUNDRY_FIELD_ID,
            else => return c.FOUNDRY_ERR_INVALID_ARGUMENT,
        };
        return c.FOUNDRY_OK;
    }

    fn recordFieldPresent(handle: c.FoundryRecord, field: u32, out: [*c]c.FoundryBool) callconv(.c) c.FoundryResult {
        record("record_field_present");
        _ = field;
        // The template carries no components, which is the smallest template a preflight
        // can accept and the one this fake exists to spawn.
        out.* = if (handle.bits == 1) 1 else 0;
        return c.FOUNDRY_OK;
    }

    fn recordGetI64(handle: c.FoundryRecord, field: u32, out: [*c]i64) callconv(.c) c.FoundryResult {
        record("record_get_i64");
        if (handle.bits != 1 or field != 0) return c.FOUNDRY_ERR_INVALID_ARGUMENT;
        out.* = 3;
        return c.FOUNDRY_OK;
    }

    fn recordGetU64(handle: c.FoundryRecord, field: u32, out: [*c]u64) callconv(.c) c.FoundryResult {
        record("record_get_u64");
        if (handle.bits != 1 or field != 1) return c.FOUNDRY_ERR_INVALID_ARGUMENT;
        out.* = big_value;
        return c.FOUNDRY_OK;
    }

    fn recordGetString(handle: c.FoundryRecord, field: u32, out: [*c]c.FoundryStr) callconv(.c) c.FoundryResult {
        record("record_get_string");
        if (handle.bits != 1 or field != 2) return c.FOUNDRY_ERR_INVALID_ARGUMENT;
        out.* = text("hello");
        return c.FOUNDRY_OK;
    }

    fn recordGetId(handle: c.FoundryRecord, field: u32, out: [*c]c.FoundryContentId) callconv(.c) c.FoundryResult {
        record("record_get_id");
        if (handle.bits != 1 or field != 3) return c.FOUNDRY_ERR_INVALID_ARGUMENT;
        out.*.hash = template_id;
        return c.FOUNDRY_OK;
    }

    fn worldSpawn(id: c.FoundryContentId, out: [*c]c.FoundryEntity) callconv(.c) c.FoundryResult {
        record("world_spawn");
        if (id.hash != template_id) return c.FOUNDRY_ERR_NOT_FOUND;
        for (&alive, 0..) |*slot, i| {
            if (slot.*) continue;
            slot.* = true;
            out.*.bits = i + 1;
            return c.FOUNDRY_OK;
        }
        return c.FOUNDRY_ERR_LIMIT;
    }

    fn slotOf(entity: c.FoundryEntity) ?usize {
        if (entity.bits == 0 or entity.bits > max_entities) return null;
        return @intCast(entity.bits - 1);
    }

    fn worldDestroyEntity(entity: c.FoundryEntity) callconv(.c) c.FoundryResult {
        record("world_destroy_entity");
        const slot = slotOf(entity) orelse return c.FOUNDRY_ERR_INVALID_HANDLE;
        if (!alive[slot]) return c.FOUNDRY_ERR_INVALID_HANDLE;
        alive[slot] = false;
        return c.FOUNDRY_OK;
    }

    fn worldContains(entity: c.FoundryEntity, out: [*c]c.FoundryBool) callconv(.c) c.FoundryResult {
        record("world_contains");
        const slot = slotOf(entity) orelse {
            out.* = 0;
            return c.FOUNDRY_OK;
        };
        out.* = @intFromBool(alive[slot]);
        return c.FOUNDRY_OK;
    }

    fn worldEntityCount(out: [*c]u32) callconv(.c) c.FoundryResult {
        record("world_entity_count");
        var count: u32 = 0;
        for (alive) |slot| {
            if (slot) count += 1;
        }
        out.* = count;
        return c.FOUNDRY_OK;
    }

    fn worldNextEntity(cursor: [*c]c.FoundryCursor, out: [*c]c.FoundryEntity) callconv(.c) c.FoundryResult {
        record("world_next_entity");
        var slot: usize = @intCast(cursor.*.bits);
        while (slot < max_entities) : (slot += 1) {
            if (!alive[slot]) continue;
            out.*.bits = slot + 1;
            cursor.*.bits = slot + 1;
            return c.FOUNDRY_OK;
        }
        return c.FOUNDRY_END;
    }
};

const Bound = struct {
    runtime: script.Runtime = .{},
    ledger: script.Ledger = std.mem.zeroes(script.Ledger),

    fn init(self: *Bound, config: script.Config) !void {
        Fake.reset();
        var full = config;
        full.get_api = &Fake.getApi;
        full.self = 0x5000_0001;
        full.ledger = &self.ledger;
        try self.runtime.init(testing.allocator, full);
    }

    fn deinit(self: *Bound) void {
        self.runtime.deinit();
    }
};

test "the foundry module publishes exactly binding 1's allowlist" {
    var bound: Bound = .{};
    try bound.init(.{});
    defer bound.deinit();

    // Written out, because what a script can reach is a compatibility decision rather than
    // an implementation detail: a name added here is a name mods will hold us to.
    const source =
        \\local expected = {
        \\  id_from_string = true, id_to_string = true, schema_id = true, rng = true,
        \\  log_write = true, content_generation = true, content_find = true,
        \\  content_next = true, content_next_of_schema = true,
        \\  record_id = true, record_name = true, record_schema = true, record_package = true,
        \\  record_field_count = true, record_field_index = true, record_field_name = true,
        \\  record_field_type = true, record_field_present = true,
        \\  record_get_bool = true, record_get_i64 = true, record_get_u64 = true,
        \\  record_get_f32 = true, record_get_string = true, record_get_id = true,
        \\  record_nested = true, record_list_len = true, record_list_get_i64 = true,
        \\  record_list_get_f32 = true, record_list_get_string = true,
        \\  record_list_get_id = true, record_list_nested = true,
        \\  world_contains = true, world_entity_count = true, world_next_entity = true,
        \\  world_find_component_type = true, world_has_component = true,
        \\  world_read_component = true, world_spawn = true, world_destroy_entity = true,
        \\}
        \\local found = 0
        \\for name, value in pairs(foundry) do
        \\  assert(expected[name], "unexpected binding: " .. name)
        \\  assert(type(value) == "function", name)
        \\  found = found + 1
        \\end
        \\local wanted = 0
        \\for name in pairs(expected) do
        \\  assert(foundry[name], "missing binding: " .. name)
        \\  wanted = wanted + 1
        \\end
        \\assert(found == wanted, "counts differ")
        \\-- Nothing the allowlist does not name is reachable, including the register and
        \\-- raw-storage calls a native mod has.
        \\assert(foundry.world_register_component == nil and foundry.world_component_bytes == nil)
        \\assert(foundry.world_register_system == nil and foundry.asset_acquire == nil)
        \\assert(foundry.script_source_copy == nil and foundry.render_sprite == nil)
        \\return found
    ;
    try testing.expectEqual(@as(i64, 39), try bound.runtime.execute(source));
}

test "content reads convert values and answer absence with nil" {
    var bound: Bound = .{};
    try bound.init(.{});
    defer bound.deinit();

    const source =
        \\local record = foundry.content_find("fake:config")
        \\assert(foundry.record_field_count(record) == 4)
        \\assert(foundry.record_field_name(record, 0) == "delay")
        \\assert(foundry.record_field_type(record, 0) == "i64")
        \\assert(foundry.record_field_present(record, 0) == true)
        \\assert(foundry.record_get_i64(record, 0) == 3)
        \\assert(foundry.record_get_string(record, 2) == "hello")
        \\
        \\-- A u64 above INT64_MAX stays exact instead of becoming a lossy float.
        \\local big = foundry.record_get_u64(record, 1)
        \\assert(type(big) == "userdata")
        \\assert(tostring(big) == "9223372036854775813")
        \\assert(big > 9223372036854775807 and big > 0 and not (big < 0))
        \\
        \\-- Ids are values: equal by content, and the same id twice compares equal.
        \\local id = foundry.record_get_id(record, 3)
        \\assert(id == foundry.id_from_string("fake:empty"))
        \\assert(id ~= foundry.id_from_string("fake:config"))
        \\assert(foundry.id_to_string(foundry.id_from_string("fake:config")) == "fake:config")
        \\
        \\-- Absence is a value, not an error.
        \\local missing, why = foundry.content_find("fake:nothing")
        \\assert(missing == nil and why == "not_found")
        \\local no_field, field_why = foundry.record_field_index(record, "absent")
        \\assert(no_field == nil and field_why == "not_found")
        \\local gone, gone_why = foundry.id_to_string(foundry.id_from_string("fake:empty"))
        \\assert(gone == nil and gone_why == "not_found")
        \\
        \\-- A walk ends rather than failing, and its cursor is immutable.
        \\local seen = 0
        \\local cursor = nil
        \\while true do
        \\  local found, next_cursor = foundry.content_next(cursor)
        \\  if found == nil then assert(next_cursor == "end") break end
        \\  cursor = next_cursor
        \\  seen = seen + 1
        \\end
        \\assert(seen == 2)
        \\return seen
    ;
    try testing.expectEqual(@as(i64, 2), try bound.runtime.execute(source));
    try testing.expect(Fake.called("record_get_u64"));
    try testing.expect(Fake.called("content_next"));
    try testing.expect(!Fake.called("world_spawn"));
}

test "a record cannot be used by the invocation after the one that read it" {
    var bound: Bound = .{};
    try bound.init(.{});
    defer bound.deinit();

    _ = try bound.runtime.execute("saved = foundry.content_find(\"fake:config\") return 1");
    try testing.expectError(error.RuntimeFailed, bound.runtime.execute("return foundry.record_field_count(saved)"));
    try testing.expect(std.mem.indexOf(u8, bound.runtime.diagnostic(), "stale_handle") != null);

    // Reading it again in this invocation works, which is the documented way back.
    try testing.expectEqual(@as(i64, 4), try bound.runtime.execute(
        "saved = foundry.content_find(\"fake:config\") return foundry.record_field_count(saved)",
    ));
}

test "preparation may read the world but never change it or log" {
    var bound: Bound = .{};
    try bound.init(.{});
    defer bound.deinit();

    try testing.expectEqual(@as(i64, 0), try bound.runtime.run("return foundry.world_entity_count()", .prepare));

    try testing.expectError(error.RuntimeFailed, bound.runtime.run("return foundry.world_spawn(\"fake:empty\")", .prepare));
    try testing.expect(std.mem.indexOf(u8, bound.runtime.diagnostic(), "contract") != null);
    try testing.expect(!Fake.called("world_spawn"));

    try testing.expectError(error.RuntimeFailed, bound.runtime.run("return foundry.log_write(\"info\", \"hi\")", .prepare));
    try testing.expect(std.mem.indexOf(u8, bound.runtime.diagnostic(), "contract") != null);
    try testing.expectEqual(@as(u32, 0), Fake.logs);
}

test "a script destroys what it spawned and nothing else" {
    var bound: Bound = .{};
    try bound.init(.{});
    defer bound.deinit();

    // An entity the host owns, which the script will find by walking and must not be able
    // to remove: a sandbox isolates ownership, not visibility.
    Fake.alive[100] = true;

    try testing.expectEqual(@as(i64, 1), try bound.runtime.run(
        \\local mine = foundry.world_spawn("fake:empty")
        \\assert(foundry.world_contains(mine))
        \\assert(foundry.world_destroy_entity(mine) == true)
        \\assert(foundry.world_contains(mine) == false)
        \\return 1
    , .update));
    try testing.expectEqual(@as(u32, 0), bound.ledger.count);

    // A foreign entity is visible and not destroyable.
    try testing.expectError(error.RuntimeFailed, bound.runtime.run(
        \\local found = foundry.world_next_entity(nil)
        \\return foundry.world_destroy_entity(found)
    , .update));
    try testing.expect(std.mem.indexOf(u8, bound.runtime.diagnostic(), "contract") != null);
    try testing.expect(Fake.alive[100]);

    // And a destroyed entity the ledger still names is pruned rather than mourned.
    _ = try bound.runtime.run("owned = foundry.world_spawn(\"fake:empty\") return 1", .update);
    try testing.expectEqual(@as(u32, 1), bound.ledger.count);
    Fake.alive[@intCast(bound.ledger.entities[0].bits - 1)] = false;
    try testing.expectEqual(@as(i64, 1), try bound.runtime.run(
        \\local mine = foundry.world_spawn("fake:empty")
        \\local gone, why = foundry.world_destroy_entity(mine)
        \\return 1
    , .update));
}

test "each invocation gets its own spawn and engine-call budget" {
    var bound: Bound = .{};
    try bound.init(.{ .spawn_limit = 2 });
    defer bound.deinit();

    try testing.expectError(error.NativeWorkLimit, bound.runtime.run(
        \\for i = 1, 3 do foundry.world_spawn("fake:empty") end
        \\return 1
    , .update));
    try testing.expect(std.mem.indexOf(u8, bound.runtime.diagnostic(), "native_work_limit") != null);
    try testing.expectEqual(@as(u32, 2), bound.ledger.count);

    // The budget is per invocation, so the next tick may spawn again.
    try testing.expectEqual(@as(i64, 1), try bound.runtime.run("foundry.world_spawn(\"fake:empty\") return 1", .update));
    try testing.expectEqual(@as(u32, 3), bound.ledger.count);

    var counted: Bound = .{};
    try counted.init(.{ .abi_call_limit = 4 });
    defer counted.deinit();
    try testing.expectError(error.NativeWorkLimit, counted.runtime.execute(
        \\for i = 1, 10 do foundry.content_find("fake:config") end
        \\return 1
    ));
    try testing.expectEqual(@as(u32, 4), counted.runtime.abiCalls());
}

test "the ownership ledger is bounded and forgets only what the world lost" {
    var bound: Bound = .{};
    try bound.init(.{ .spawn_limit = 64 });
    defer bound.deinit();

    // A full ledger of live entities cannot grow, however many the world would allow.
    bound.ledger.count = 256;
    for (0..256) |i| {
        bound.ledger.entities[i] = .{ .bits = i + 1 };
        Fake.alive[i] = true;
    }
    try testing.expectError(error.NativeWorkLimit, bound.runtime.run("return foundry.world_spawn(\"fake:empty\")", .update));
    try testing.expectEqual(@as(u32, 256), bound.ledger.count);

    // Entities the world no longer has are pruned, and the room they free is usable. The
    // ledger keeps spawn order, so which entry goes is not a matter of hashing.
    Fake.alive[3] = false;
    Fake.alive[9] = false;
    try testing.expectEqual(@as(i64, 1), try bound.runtime.run("owned = foundry.world_spawn(\"fake:empty\") return 1", .update));
    try testing.expectEqual(@as(u32, 255), bound.ledger.count);
    try testing.expectEqual(@as(u64, 1), bound.ledger.entities[0].bits);
    try testing.expectEqual(@as(u64, 3), bound.ledger.entities[2].bits);
    try testing.expectEqual(@as(u64, 5), bound.ledger.entities[3].bits);
}

test "the script rng is core's generator, seeded explicitly" {
    var bound: Bound = .{};
    try bound.init(.{});
    defer bound.deinit();

    var expected: core.Pcg32 = .init(42, 54);
    const first = expected.next();
    const second = expected.next();

    try testing.expectEqual(@as(i64, first), try bound.runtime.execute(
        \\rolls = foundry.rng(42, 54)
        \\return rolls:next_u32()
    ));
    try testing.expectEqual(@as(i64, second), try bound.runtime.execute("return rolls:next_u32()"));

    // Two generators with the same seed agree; there is no ambient generator to disturb.
    try testing.expectEqual(@as(i64, 1), try bound.runtime.execute(
        \\local a, b = foundry.rng(7, 1), foundry.rng(7, 1)
        \\for i = 1, 8 do assert(a:next_u32() == b:next_u32()) end
        \\return 1
    ));
}

test "no handle can be forged and no argument is coerced into one" {
    var bound: Bound = .{};
    try bound.init(.{});
    defer bound.deinit();

    const cases = [_][]const u8{
        "return foundry.world_destroy_entity(12345)",
        "return foundry.world_contains(0)",
        "return foundry.record_field_count(1)",
        "return foundry.record_get_i64(foundry.content_find(\"fake:config\"), 1.5)",
        "return foundry.record_get_i64(foundry.content_find(\"fake:config\"), -1)",
        "return foundry.content_find(foundry.rng(1, 1))",
        "return foundry.id_from_string(\"no-namespace\")",
        "return foundry.content_next(foundry.content_find(\"fake:config\"))",
    };
    for (cases) |source| {
        try testing.expectError(error.RuntimeFailed, bound.runtime.run(source, .update));
        const diagnostic = bound.runtime.diagnostic();
        try testing.expect(std.mem.indexOf(u8, diagnostic, "invalid_argument") != null or
            std.mem.indexOf(u8, diagnostic, "stale_handle") != null);
    }
    try testing.expect(!Fake.called("world_destroy_entity"));
}

test "a host that cannot offer v2 is refused before a VM exists" {
    Fake.reset();
    var ledger: script.Ledger = std.mem.zeroes(script.Ledger);
    var runtime: script.Runtime = .{};
    try testing.expectError(error.UnsupportedApi, runtime.init(testing.allocator, .{
        .get_api = &Fake.noV2,
        .self = 1,
        .ledger = &ledger,
    }));

    // And a binding without the identity or ledger its calls need is a caller mistake.
    var missing: script.Runtime = .{};
    try testing.expectError(error.InvalidArgument, missing.init(testing.allocator, .{
        .get_api = &Fake.getApi,
        .self = 0,
        .ledger = &ledger,
    }));
}
