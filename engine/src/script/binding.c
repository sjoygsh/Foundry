/*
 * The `foundry` Lua module, binding version 1 (scripting.md §7).
 *
 * Every function here is **syntax and validation over the shared table** (ADR-0029 §5): it
 * checks its Lua arguments, builds a plain C request, calls one `FoundryApi_v2` entry, waits
 * for it to return, and only then builds Lua results or raises. No engine code runs while a
 * Lua error is in flight, and nothing here calls back into Lua from the engine side.
 *
 * Absence is a value and misuse is an error: `not_found`, `end`, `unavailable` and
 * `unsupported` return `nil, name`; a malformed argument, a stale handle, an ownership
 * violation or an exhausted budget raises, and the host catches it.
 */

#include "bridge_private.h"

#include "lauxlib.h"

#include <stdio.h>
#include <string.h>

#define VALUE_METATABLE "foundry.value"
#define MAX_TEMPLATE_COMPONENTS 32u
#define MAX_TEMPLATE_BYTES (64u * 1024u)

enum {
    TAG_ID = 1,
    TAG_SCHEMA,
    TAG_RECORD,
    TAG_CURSOR,
    TAG_ENTITY,
    TAG_COMPONENT_TYPE,
    TAG_PACKAGE,
    TAG_U64,
    TAG_RNG,
};

enum {
    CURSOR_CONTENT = 1,
    CURSOR_CONTENT_OF_SCHEMA,
    CURSOR_ENTITY,
};

/* Every value the bridge hands a script: immutable (except an RNG's state), tagged, and
 * holding values rather than pointers. No constructor accepts handle bits, so a script can
 * only hold a handle the engine gave it. `serial` scopes a record or cursor to the
 * invocation that made it; zero means the value outlives invocations. */
typedef struct ScriptValue {
    uint32_t tag;
    uint32_t kind;
    uint64_t serial;
    uint64_t bits;
    uint64_t extra;
} ScriptValue;

/* -- Failure --------------------------------------------------------------------------- */

static const char *result_label(FoundryResult result) {
    switch (result) {
        case FOUNDRY_OK: return "ok";
        case FOUNDRY_END: return "end";
        case FOUNDRY_ERR_INVALID_ARGUMENT: return "invalid_argument";
        case FOUNDRY_ERR_INVALID_HANDLE: return "stale_handle";
        case FOUNDRY_ERR_NOT_FOUND: return "not_found";
        case FOUNDRY_ERR_UNAVAILABLE: return "unavailable";
        case FOUNDRY_ERR_UNSUPPORTED: return "unsupported";
        case FOUNDRY_ERR_ALREADY_EXISTS: return "already_exists";
        case FOUNDRY_ERR_LIMIT: return "limit";
        case FOUNDRY_ERR_REFUSED: return "refused";
        case FOUNDRY_ERR_OUT_OF_MEMORY: return "memory_limit";
        default: return "internal";
    }
}

static int raise_budget(lua_State *state, FoundryScript *script, const char *fn,
                        const char *message) {
    script->failure = SCRIPT_FAILURE_NATIVE_WORK;
    script->terminal = 1;
    return luaL_error(state, "native_work_limit: %s: %s", fn, message);
}

static int raise_result(lua_State *state, FoundryScript *script, const char *fn,
                        FoundryResult result) {
    if (result == FOUNDRY_ERR_OUT_OF_MEMORY) {
        script->failure = SCRIPT_FAILURE_MEMORY;
    }
    return luaL_error(state, "%s: %s: the engine refused the call", result_label(result), fn);
}

/* `nil, name` for the answers that are normal absence; raises for everything else. */
static int absent(lua_State *state, FoundryScript *script, const char *fn,
                  FoundryResult result) {
    switch (result) {
        case FOUNDRY_END:
        case FOUNDRY_ERR_NOT_FOUND:
        case FOUNDRY_ERR_UNAVAILABLE:
        case FOUNDRY_ERR_UNSUPPORTED:
            lua_pushnil(state);
            lua_pushstring(state, result_label(result));
            return 2;
        default:
            return raise_result(state, script, fn, result);
    }
}

static int unsupported(lua_State *state) {
    lua_pushnil(state);
    lua_pushliteral(state, "unsupported");
    return 2;
}

/* -- The table ------------------------------------------------------------------------- */

static FoundryScript *enter(lua_State *state, const char *fn) {
    FoundryScript *script = foundry_script_from_state(state);
    if (script->terminal) {
        luaL_error(state, "native_work_limit: %s: this invocation already exhausted a budget", fn);
    }
    return script;
}

/* Every table call is charged before it is made, traversal included (scripting.md §8). */
static void charge(lua_State *state, FoundryScript *script, const char *fn) {
    if (script->abi_calls >= script->abi_call_limit) {
        raise_budget(state, script, fn, "this invocation made too many engine calls");
    }
    script->abi_calls += 1;
}

/* `foundry.h` promises no entry is ever NULL; a NULL in a test double reads as absent
 * rather than as a jump to address zero. */
#define CALL(state, script, fn, entry, args)                                            \
    (charge((state), (script), (fn)),                                                   \
     (script)->api->entry != NULL ? (script)->api->entry args : FOUNDRY_ERR_UNAVAILABLE)

static void require_update(lua_State *state, FoundryScript *script, const char *fn) {
    if (script->phase != FOUNDRY_SCRIPT_PHASE_UPDATE) {
        luaL_error(state, "contract: %s: only an update may change the world or write the log", fn);
    }
}

/* -- Values ---------------------------------------------------------------------------- */

static ScriptValue *push_value(lua_State *state, uint32_t tag, uint64_t bits, int scoped) {
    FoundryScript *script = foundry_script_from_state(state);
    ScriptValue *value = (ScriptValue *)lua_newuserdatauv(state, sizeof(ScriptValue), 0);
    value->tag = tag;
    value->kind = 0;
    value->serial = scoped ? script->invocation : 0;
    value->bits = bits;
    value->extra = 0;
    luaL_setmetatable(state, VALUE_METATABLE);
    return value;
}

static ScriptValue *test_value(lua_State *state, int index) {
    return (ScriptValue *)luaL_testudata(state, index, VALUE_METATABLE);
}

static const ScriptValue *check_value(lua_State *state, int index, uint32_t tag,
                                      const char *fn, const char *what) {
    const ScriptValue *value = test_value(state, index);
    if (value == NULL || value->tag != tag) {
        luaL_error(state, "invalid_argument: %s: argument %d must be %s", fn, index, what);
    }
    if (value->serial != 0 && value->serial != foundry_script_from_state(state)->invocation) {
        luaL_error(state,
                   "stale_handle: %s: argument %d belongs to an earlier invocation; look it up again",
                   fn, index);
    }
    return value;
}

static void push_u64(lua_State *state, uint64_t value) {
    if (value <= (uint64_t)INT64_MAX) {
        lua_pushinteger(state, (lua_Integer)value);
    } else {
        push_value(state, TAG_U64, value, 0);
    }
}

static uint64_t check_u64(lua_State *state, int index, const char *fn) {
    if (lua_isinteger(state, index)) {
        return (uint64_t)lua_tointeger(state, index);
    }
    return check_value(state, index, TAG_U64, fn, "an integer")->bits;
}

static uint32_t check_index(lua_State *state, int index, const char *fn) {
    lua_Integer value;
    if (!lua_isinteger(state, index)) {
        luaL_error(state, "invalid_argument: %s: argument %d must be an integer", fn, index);
    }
    value = lua_tointeger(state, index);
    if (value < 0 || (uint64_t)value > UINT32_MAX) {
        luaL_error(state, "invalid_argument: %s: argument %d is out of range", fn, index);
    }
    return (uint32_t)value;
}

static FoundryStr check_text(lua_State *state, FoundryScript *script, int index, const char *fn) {
    FoundryStr text;
    size_t length = 0;
    const char *bytes;
    if (lua_type(state, index) != LUA_TSTRING) {
        luaL_error(state, "invalid_argument: %s: argument %d must be a string", fn, index);
    }
    bytes = lua_tolstring(state, index, &length);
    if (length > FOUNDRY_SCRIPT_MAX_STRING) {
        raise_budget(state, script, fn, "a string argument is longer than 16 KiB");
    }
    text.ptr = (const uint8_t *)bytes;
    text.len = (uint64_t)length;
    return text;
}

static void push_text(lua_State *state, FoundryScript *script, FoundryStr text, const char *fn) {
    if (text.len > FOUNDRY_SCRIPT_MAX_STRING) {
        raise_budget(state, script, fn, "the engine answered a string longer than 16 KiB");
    }
    lua_pushlstring(state, (const char *)text.ptr, (size_t)text.len);
}

/* A content id: an id value, or a `namespace:name` string checked by the table. */
static FoundryContentId check_id(lua_State *state, FoundryScript *script, int index,
                                 const char *fn) {
    /* Zeroed because `luaL_error` is not declared noreturn: the compiler cannot see that
     * the refusal path below never reaches the return. */
    FoundryContentId id = {0};
    if (lua_type(state, index) == LUA_TSTRING) {
        FoundryStr text = check_text(state, script, index, fn);
        if (CALL(state, script, fn, id_from_string, (text, &id)) != FOUNDRY_OK) {
            luaL_error(state, "invalid_argument: %s: argument %d is not a namespace:name id",
                       fn, index);
        }
        return id;
    }
    id.hash = check_value(state, index, TAG_ID, fn, "a content id or an id string")->bits;
    return id;
}

/* A schema id: a schema value, or a `namespace:name` string whose spelling the table checks
 * before the header's own hash names it. */
static FoundrySchemaId check_schema(lua_State *state, FoundryScript *script, int index,
                                    const char *fn) {
    FoundrySchemaId schema = {0};
    if (lua_type(state, index) == LUA_TSTRING) {
        FoundryContentId checked = {0};
        FoundryStr text = check_text(state, script, index, fn);
        if (CALL(state, script, fn, id_from_string, (text, &checked)) != FOUNDRY_OK) {
            luaL_error(state, "invalid_argument: %s: argument %d is not a namespace:name schema",
                       fn, index);
        }
        return foundry_schema_id(text.ptr, (size_t)text.len);
    }
    schema.hash = check_value(state, index, TAG_SCHEMA, fn, "a schema id or a schema string")->bits;
    return schema;
}

static FoundryRecord check_record(lua_State *state, int index, const char *fn) {
    FoundryRecord record;
    record.bits = check_value(state, index, TAG_RECORD, fn, "a record")->bits;
    return record;
}

static FoundryEntity check_entity(lua_State *state, int index, const char *fn) {
    FoundryEntity entity;
    entity.bits = check_value(state, index, TAG_ENTITY, fn, "an entity")->bits;
    return entity;
}

/* A walk's position. Absent or nil is the beginning; otherwise it must be a cursor the same
 * walk issued in this invocation. */
static FoundryCursor check_cursor(lua_State *state, int index, uint32_t kind, uint64_t extra,
                                  const char *fn, int *resumed) {
    FoundryCursor cursor = FOUNDRY_CURSOR_BEGIN;
    const ScriptValue *value;
    *resumed = 0;
    if (lua_isnoneornil(state, index)) {
        return cursor;
    }
    value = check_value(state, index, TAG_CURSOR, fn, "a cursor from the same walk");
    if (value->kind != kind || value->extra != extra) {
        luaL_error(state, "invalid_argument: %s: argument %d is a cursor from a different walk",
                   fn, index);
    }
    cursor.bits = value->bits;
    *resumed = 1;
    return cursor;
}

static void push_cursor(lua_State *state, FoundryCursor cursor, uint32_t kind, uint64_t extra) {
    ScriptValue *value = push_value(state, TAG_CURSOR, cursor.bits, 1);
    value->kind = kind;
    value->extra = extra;
}

/* A walk whose container changed under it answers INVALID_ARGUMENT for a cursor that was
 * valid when issued; to a script that is a stale handle, not a malformed one. */
static int walk_failure(lua_State *state, FoundryScript *script, const char *fn,
                        FoundryResult result, int resumed) {
    if (resumed && result == FOUNDRY_ERR_INVALID_ARGUMENT) {
        return luaL_error(state, "stale_handle: %s: what this cursor walks changed; start again", fn);
    }
    return absent(state, script, fn, result);
}

/* -- Identity and pure helpers --------------------------------------------------------- */

static int f_id_from_string(lua_State *state) {
    const char *fn = "foundry.id_from_string";
    FoundryScript *script = enter(state, fn);
    FoundryContentId id;
    if (lua_type(state, 1) != LUA_TSTRING) {
        return luaL_error(state, "invalid_argument: %s: argument 1 must be a string", fn);
    }
    id = check_id(state, script, 1, fn);
    push_value(state, TAG_ID, id.hash, 0);
    return 1;
}

static int f_id_to_string(lua_State *state) {
    const char *fn = "foundry.id_to_string";
    FoundryScript *script = enter(state, fn);
    FoundryContentId id = check_id(state, script, 1, fn);
    FoundryStr text;
    FoundryResult result = CALL(state, script, fn, id_to_string, (id, &text));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_text(state, script, text, fn);
    return 1;
}

static int f_schema_id(lua_State *state) {
    const char *fn = "foundry.schema_id";
    FoundryScript *script = enter(state, fn);
    FoundrySchemaId schema;
    if (lua_type(state, 1) != LUA_TSTRING) {
        return luaL_error(state, "invalid_argument: %s: argument 1 must be a string", fn);
    }
    schema = check_schema(state, script, 1, fn);
    push_value(state, TAG_SCHEMA, schema.hash, 0);
    return 1;
}

/* `core.Pcg32`, written out again because the bridge is C. `root.zig` checks the two
 * produce the same sequence, the way `agreement.zig` checks the content hash. */
static uint32_t pcg32_next(uint64_t *state, uint64_t increment) {
    uint64_t old = *state;
    uint32_t xorshifted = (uint32_t)(((old >> 18) ^ old) >> 27);
    uint32_t rotation = (uint32_t)(old >> 59);
    *state = old * UINT64_C(6364136223846793005) + increment;
    return (xorshifted >> rotation) | (xorshifted << ((32u - rotation) & 31u));
}

static int f_rng(lua_State *state) {
    const char *fn = "foundry.rng";
    ScriptValue *value;
    uint64_t seed, stream, increment, generator = 0;
    (void)enter(state, fn);
    seed = check_u64(state, 1, fn);
    stream = check_u64(state, 2, fn);
    increment = (stream << 1) | 1u;
    (void)pcg32_next(&generator, increment);
    generator += seed;
    (void)pcg32_next(&generator, increment);
    value = push_value(state, TAG_RNG, generator, 0);
    value->extra = increment;
    return 1;
}

static int f_rng_next_u32(lua_State *state) {
    const char *fn = "rng:next_u32";
    ScriptValue *value;
    (void)enter(state, fn);
    value = test_value(state, 1);
    if (value == NULL || value->tag != TAG_RNG) {
        return luaL_error(state, "invalid_argument: %s: call it as rng:next_u32()", fn);
    }
    lua_pushinteger(state, (lua_Integer)pcg32_next(&value->bits, value->extra));
    return 1;
}

static int f_log_write(lua_State *state) {
    static const char *const levels[] = {"error", "warn", "info", "debug", "trace"};
    const char *fn = "foundry.log_write";
    FoundryScript *script = enter(state, fn);
    FoundryStr level_text, message;
    FoundryLogLevel level = -1;
    FoundryResult result;
    int i;
    require_update(state, script, fn);
    level_text = check_text(state, script, 1, fn);
    for (i = 0; i < 5; ++i) {
        if (strlen(levels[i]) == level_text.len &&
            memcmp(levels[i], level_text.ptr, (size_t)level_text.len) == 0) {
            level = (FoundryLogLevel)i;
        }
    }
    if (level < 0) {
        return luaL_error(state, "invalid_argument: %s: level must be error, warn, info, debug or trace", fn);
    }
    message = check_text(state, script, 2, fn);
    if (script->logs >= script->log_limit) {
        lua_pushnil(state);
        lua_pushliteral(state, "limit");
        return 2;
    }
    script->logs += 1;
    result = CALL(state, script, fn, log_write, (script->self, level, message));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushboolean(state, 1);
    return 1;
}

/* -- Content --------------------------------------------------------------------------- */

static int f_content_generation(lua_State *state) {
    const char *fn = "foundry.content_generation";
    FoundryScript *script = enter(state, fn);
    uint64_t generation = 0;
    FoundryResult result = CALL(state, script, fn, content_generation, (&generation));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_u64(state, generation);
    return 1;
}

static int f_content_find(lua_State *state) {
    const char *fn = "foundry.content_find";
    FoundryScript *script = enter(state, fn);
    FoundryContentId id = check_id(state, script, 1, fn);
    FoundryRecord record;
    FoundryResult result = CALL(state, script, fn, content_find, (id, &record));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_RECORD, record.bits, 1);
    return 1;
}

static int f_content_next(lua_State *state) {
    const char *fn = "foundry.content_next";
    FoundryScript *script = enter(state, fn);
    int resumed;
    FoundryCursor cursor = check_cursor(state, 1, CURSOR_CONTENT, 0, fn, &resumed);
    FoundryRecord record;
    FoundryResult result = CALL(state, script, fn, content_next, (&cursor, &record));
    if (result != FOUNDRY_OK) {
        return walk_failure(state, script, fn, result, resumed);
    }
    push_value(state, TAG_RECORD, record.bits, 1);
    push_cursor(state, cursor, CURSOR_CONTENT, 0);
    return 2;
}

static int f_content_next_of_schema(lua_State *state) {
    const char *fn = "foundry.content_next_of_schema";
    FoundryScript *script = enter(state, fn);
    FoundrySchemaId schema = check_schema(state, script, 1, fn);
    int resumed;
    FoundryCursor cursor = check_cursor(state, 2, CURSOR_CONTENT_OF_SCHEMA, schema.hash, fn, &resumed);
    FoundryRecord record;
    FoundryResult result = CALL(state, script, fn, content_next_of_schema, (schema, &cursor, &record));
    if (result != FOUNDRY_OK) {
        return walk_failure(state, script, fn, result, resumed);
    }
    push_value(state, TAG_RECORD, record.bits, 1);
    push_cursor(state, cursor, CURSOR_CONTENT_OF_SCHEMA, schema.hash);
    return 2;
}

/* -- Records --------------------------------------------------------------------------- */

static int f_record_id(lua_State *state) {
    const char *fn = "foundry.record_id";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    FoundryContentId id;
    FoundryResult result = CALL(state, script, fn, record_id, (record, &id));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_ID, id.hash, 0);
    return 1;
}

static int f_record_name(lua_State *state) {
    const char *fn = "foundry.record_name";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    FoundryStr text;
    FoundryResult result = CALL(state, script, fn, record_name, (record, &text));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_text(state, script, text, fn);
    return 1;
}

static int f_record_schema(lua_State *state) {
    const char *fn = "foundry.record_schema";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    FoundrySchemaId schema;
    FoundryResult result = CALL(state, script, fn, record_schema, (record, &schema));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_SCHEMA, schema.hash, 0);
    return 1;
}

static int f_record_package(lua_State *state) {
    const char *fn = "foundry.record_package";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    FoundryPackage package;
    FoundryResult result = CALL(state, script, fn, record_package, (record, &package));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_PACKAGE, package.bits, 1);
    return 1;
}

static int f_record_field_count(lua_State *state) {
    const char *fn = "foundry.record_field_count";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t count = 0;
    FoundryResult result = CALL(state, script, fn, record_field_count, (record, &count));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushinteger(state, (lua_Integer)count);
    return 1;
}

static int f_record_field_index(lua_State *state) {
    const char *fn = "foundry.record_field_index";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    FoundryStr name = check_text(state, script, 2, fn);
    uint32_t index = 0;
    FoundryResult result = CALL(state, script, fn, record_field_index, (record, name, &index));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushinteger(state, (lua_Integer)index);
    return 1;
}

static int f_record_field_name(lua_State *state) {
    const char *fn = "foundry.record_field_name";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    FoundryStr text;
    FoundryResult result = CALL(state, script, fn, record_field_name, (record, field, &text));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_text(state, script, text, fn);
    return 1;
}

static int f_record_field_type(lua_State *state) {
    static const char *const names[] = {"bool", "i32", "i64", "u32", "u64", "f32",
                                        "f64", "string", "id", "list", "nested"};
    const char *fn = "foundry.record_field_type";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    FoundryFieldType type = -1;
    FoundryResult result = CALL(state, script, fn, record_field_type, (record, field, &type));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    if (type < 0 || type > FOUNDRY_FIELD_NESTED) {
        return unsupported(state);
    }
    lua_pushstring(state, names[type]);
    return 1;
}

static int f_record_field_present(lua_State *state) {
    const char *fn = "foundry.record_field_present";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    FoundryBool present = FOUNDRY_FALSE;
    FoundryResult result = CALL(state, script, fn, record_field_present, (record, field, &present));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushboolean(state, present != FOUNDRY_FALSE);
    return 1;
}

static int f_record_get_bool(lua_State *state) {
    const char *fn = "foundry.record_get_bool";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    FoundryBool value = FOUNDRY_FALSE;
    FoundryResult result = CALL(state, script, fn, record_get_bool, (record, field, &value));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushboolean(state, value != FOUNDRY_FALSE);
    return 1;
}

static int f_record_get_i64(lua_State *state) {
    const char *fn = "foundry.record_get_i64";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    int64_t value = 0;
    FoundryResult result = CALL(state, script, fn, record_get_i64, (record, field, &value));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushinteger(state, (lua_Integer)value);
    return 1;
}

static int f_record_get_u64(lua_State *state) {
    const char *fn = "foundry.record_get_u64";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    uint64_t value = 0;
    FoundryResult result = CALL(state, script, fn, record_get_u64, (record, field, &value));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_u64(state, value);
    return 1;
}

static int f_record_get_f32(lua_State *state) {
    const char *fn = "foundry.record_get_f32";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    float value = 0;
    FoundryResult result = CALL(state, script, fn, record_get_f32, (record, field, &value));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushnumber(state, (lua_Number)value);
    return 1;
}

static int f_record_get_string(lua_State *state) {
    const char *fn = "foundry.record_get_string";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    FoundryStr text;
    FoundryResult result = CALL(state, script, fn, record_get_string, (record, field, &text));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_text(state, script, text, fn);
    return 1;
}

static int f_record_get_id(lua_State *state) {
    const char *fn = "foundry.record_get_id";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    FoundryContentId id;
    FoundryResult result = CALL(state, script, fn, record_get_id, (record, field, &id));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_ID, id.hash, 0);
    return 1;
}

static int f_record_nested(lua_State *state) {
    const char *fn = "foundry.record_nested";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    FoundryRecord nested;
    FoundryResult result = CALL(state, script, fn, record_nested, (record, field, &nested));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_RECORD, nested.bits, 1);
    return 1;
}

static int f_record_list_len(lua_State *state) {
    const char *fn = "foundry.record_list_len";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    uint32_t length = 0;
    FoundryResult result = CALL(state, script, fn, record_list_len, (record, field, &length));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushinteger(state, (lua_Integer)length);
    return 1;
}

static int f_record_list_get_i64(lua_State *state) {
    const char *fn = "foundry.record_list_get_i64";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    uint32_t index = check_index(state, 3, fn);
    int64_t value = 0;
    FoundryResult result = CALL(state, script, fn, record_list_get_i64, (record, field, index, &value));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushinteger(state, (lua_Integer)value);
    return 1;
}

static int f_record_list_get_f32(lua_State *state) {
    const char *fn = "foundry.record_list_get_f32";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    uint32_t index = check_index(state, 3, fn);
    float value = 0;
    FoundryResult result = CALL(state, script, fn, record_list_get_f32, (record, field, index, &value));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushnumber(state, (lua_Number)value);
    return 1;
}

static int f_record_list_get_string(lua_State *state) {
    const char *fn = "foundry.record_list_get_string";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    uint32_t index = check_index(state, 3, fn);
    FoundryStr text;
    FoundryResult result = CALL(state, script, fn, record_list_get_string, (record, field, index, &text));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_text(state, script, text, fn);
    return 1;
}

static int f_record_list_get_id(lua_State *state) {
    const char *fn = "foundry.record_list_get_id";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    uint32_t index = check_index(state, 3, fn);
    FoundryContentId id;
    FoundryResult result = CALL(state, script, fn, record_list_get_id, (record, field, index, &id));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_ID, id.hash, 0);
    return 1;
}

static int f_record_list_nested(lua_State *state) {
    const char *fn = "foundry.record_list_nested";
    FoundryScript *script = enter(state, fn);
    FoundryRecord record = check_record(state, 1, fn);
    uint32_t field = check_index(state, 2, fn);
    uint32_t index = check_index(state, 3, fn);
    FoundryRecord nested;
    FoundryResult result = CALL(state, script, fn, record_list_nested, (record, field, index, &nested));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_RECORD, nested.bits, 1);
    return 1;
}

/* -- World inspection ------------------------------------------------------------------ */

static int f_world_contains(lua_State *state) {
    const char *fn = "foundry.world_contains";
    FoundryScript *script = enter(state, fn);
    FoundryEntity entity = check_entity(state, 1, fn);
    FoundryBool alive = FOUNDRY_FALSE;
    FoundryResult result = CALL(state, script, fn, world_contains, (entity, &alive));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushboolean(state, alive != FOUNDRY_FALSE);
    return 1;
}

static int f_world_entity_count(lua_State *state) {
    const char *fn = "foundry.world_entity_count";
    FoundryScript *script = enter(state, fn);
    uint32_t count = 0;
    FoundryResult result = CALL(state, script, fn, world_entity_count, (&count));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushinteger(state, (lua_Integer)count);
    return 1;
}

static int f_world_next_entity(lua_State *state) {
    const char *fn = "foundry.world_next_entity";
    FoundryScript *script = enter(state, fn);
    int resumed;
    FoundryCursor cursor = check_cursor(state, 1, CURSOR_ENTITY, 0, fn, &resumed);
    FoundryEntity entity;
    FoundryResult result = CALL(state, script, fn, world_next_entity, (&cursor, &entity));
    if (result != FOUNDRY_OK) {
        return walk_failure(state, script, fn, result, resumed);
    }
    push_value(state, TAG_ENTITY, entity.bits, 0);
    push_cursor(state, cursor, CURSOR_ENTITY, 0);
    return 2;
}

static int f_world_find_component_type(lua_State *state) {
    const char *fn = "foundry.world_find_component_type";
    FoundryScript *script = enter(state, fn);
    FoundrySchemaId schema = check_schema(state, script, 1, fn);
    FoundryComponentType type;
    FoundryResult result = CALL(state, script, fn, world_find_component_type, (schema, &type));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_COMPONENT_TYPE, type.bits, 0);
    return 1;
}

static FoundryComponentType check_component_type(lua_State *state, int index, const char *fn) {
    FoundryComponentType type;
    type.bits = check_value(state, index, TAG_COMPONENT_TYPE, fn, "a component type")->bits;
    return type;
}

static int f_world_has_component(lua_State *state) {
    const char *fn = "foundry.world_has_component";
    FoundryScript *script = enter(state, fn);
    FoundryEntity entity = check_entity(state, 1, fn);
    FoundryComponentType type = check_component_type(state, 2, fn);
    FoundryBool has = FOUNDRY_FALSE;
    FoundryResult result = CALL(state, script, fn, world_has_component, (entity, type, &has));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    lua_pushboolean(state, has != FOUNDRY_FALSE);
    return 1;
}

static int f_world_read_component(lua_State *state) {
    const char *fn = "foundry.world_read_component";
    FoundryScript *script = enter(state, fn);
    FoundryEntity entity = check_entity(state, 1, fn);
    FoundryComponentType type = check_component_type(state, 2, fn);
    FoundryRecord record;
    FoundryResult result = CALL(state, script, fn, world_read_component, (entity, type, &record));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    push_value(state, TAG_RECORD, record.bits, 1);
    return 1;
}

/* -- Gameplay mutations ---------------------------------------------------------------- */

/* Checks a template against §8's limits through the same content and type calls a script
 * could make, and refuses a shape the world could only half-build. A component type the
 * world does not know, or one with no deserializer, cannot come from content. Returns 0
 * when the template may be spawned; otherwise it has pushed `nil, name`. */
static int preflight(lua_State *state, FoundryScript *script, FoundryContentId template_id,
                     const char *fn) {
    static const char entity_schema[] = "foundry:entity";
    static const char components_name[] = "components";
    uint64_t generation = 0, footprint = 0;
    uint32_t field = 0, count = 0, i;
    FoundryRecord record;
    FoundrySchemaId schema;
    FoundryStr components;
    FoundryResult result;

    result = CALL(state, script, fn, content_generation, (&generation));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    for (i = 0; i < FOUNDRY_SCRIPT_TEMPLATE_CACHE; ++i) {
        const TemplateCacheEntry *entry = &script->template_cache[i];
        if (entry->valid && entry->id == template_id.hash && entry->generation == generation) {
            return 0;
        }
    }

    result = CALL(state, script, fn, content_find, (template_id, &record));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    result = CALL(state, script, fn, record_schema, (record, &schema));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    if (schema.hash != foundry_schema_id(entity_schema, sizeof(entity_schema) - 1).hash) {
        return luaL_error(state, "invalid_argument: %s: the id does not name a foundry:entity template", fn);
    }

    components.ptr = (const uint8_t *)components_name;
    components.len = sizeof(components_name) - 1;
    result = CALL(state, script, fn, record_field_index, (record, components, &field));
    if (result == FOUNDRY_OK) {
        FoundryBool present = FOUNDRY_FALSE;
        result = CALL(state, script, fn, record_field_present, (record, field, &present));
        if (result != FOUNDRY_OK) {
            return absent(state, script, fn, result);
        }
        if (present) {
            result = CALL(state, script, fn, record_list_len, (record, field, &count));
            if (result != FOUNDRY_OK) {
                return absent(state, script, fn, result);
            }
        }
    } else if (result != FOUNDRY_ERR_NOT_FOUND) {
        return absent(state, script, fn, result);
    }
    if (count > MAX_TEMPLATE_COMPONENTS) {
        return luaL_error(state, "limit: %s: the template has more than 32 components", fn);
    }

    for (i = 0; i < count; ++i) {
        FoundryContentId component_id;
        FoundryRecord component;
        FoundrySchemaId component_schema;
        FoundryComponentType type;
        FoundryBool savable = FOUNDRY_FALSE;
        uint32_t size = 0, alignment = 0;

        result = CALL(state, script, fn, record_list_get_id, (record, field, i, &component_id));
        if (result != FOUNDRY_OK) {
            return absent(state, script, fn, result);
        }
        result = CALL(state, script, fn, content_find, (component_id, &component));
        if (result != FOUNDRY_OK) {
            return absent(state, script, fn, result);
        }
        result = CALL(state, script, fn, record_schema, (component, &component_schema));
        if (result != FOUNDRY_OK) {
            return absent(state, script, fn, result);
        }
        result = CALL(state, script, fn, world_find_component_type, (component_schema, &type));
        if (result == FOUNDRY_ERR_NOT_FOUND) {
            return unsupported(state);
        }
        if (result != FOUNDRY_OK) {
            return absent(state, script, fn, result);
        }
        /* Savable is the conservative proof both serialization directions exist; a type a
         * mod registered raw has neither and cannot be built from a record. */
        result = CALL(state, script, fn, world_component_type_savable, (type, &savable));
        if (result != FOUNDRY_OK) {
            return absent(state, script, fn, result);
        }
        if (!savable) {
            return unsupported(state);
        }
        result = CALL(state, script, fn, world_component_type_size, (type, &size));
        if (result != FOUNDRY_OK) {
            return absent(state, script, fn, result);
        }
        result = CALL(state, script, fn, world_component_type_alignment, (type, &alignment));
        if (result != FOUNDRY_OK) {
            return absent(state, script, fn, result);
        }
        if (alignment == 0) {
            alignment = 1;
        }
        /* At most 32 components of at most 4 GiB each: no overflow in 64 bits. */
        footprint = (footprint + alignment - 1u) / alignment * alignment + size;
        if (footprint > MAX_TEMPLATE_BYTES) {
            return luaL_error(state, "limit: %s: the template needs more than 64 KiB per instance", fn);
        }
    }

    script->template_cache[script->template_cache_next].id = template_id.hash;
    script->template_cache[script->template_cache_next].generation = generation;
    script->template_cache[script->template_cache_next].valid = 1;
    script->template_cache_next = (script->template_cache_next + 1u) % FOUNDRY_SCRIPT_TEMPLATE_CACHE;
    return 0;
}

static int ledger_find(const FoundryScriptLedger *ledger, FoundryEntity entity) {
    uint32_t i;
    for (i = 0; i < ledger->count; ++i) {
        if (ledger->entities[i].bits == entity.bits) {
            return (int)i;
        }
    }
    return -1;
}

/* Ordered, so the ledger stays in spawn order and pruning is deterministic. */
static void ledger_remove(FoundryScriptLedger *ledger, uint32_t index) {
    memmove(&ledger->entities[index], &ledger->entities[index + 1],
            (size_t)(ledger->count - index - 1u) * sizeof(FoundryEntity));
    ledger->count -= 1;
}

/* Forgets owned entities the world no longer has. The budget is checked for the whole walk
 * first, so a limit cannot stop it half-compacted. */
static void ledger_prune(lua_State *state, FoundryScript *script, const char *fn) {
    FoundryScriptLedger *ledger = script->ledger;
    uint32_t i, kept = 0;
    if (script->abi_call_limit - script->abi_calls < ledger->count) {
        raise_budget(state, script, fn, "this invocation made too many engine calls");
    }
    for (i = 0; i < ledger->count; ++i) {
        FoundryBool alive = FOUNDRY_FALSE;
        FoundryResult result = CALL(state, script, fn, world_contains, (ledger->entities[i], &alive));
        if (result != FOUNDRY_OK) {
            alive = FOUNDRY_TRUE; /* Keep what cannot be checked; never forget ownership. */
        }
        if (alive) {
            ledger->entities[kept] = ledger->entities[i];
            kept += 1;
        }
    }
    ledger->count = kept;
}

static int f_world_spawn(lua_State *state) {
    const char *fn = "foundry.world_spawn";
    FoundryScript *script = enter(state, fn);
    FoundryContentId template_id;
    FoundryEntity entity;
    FoundryResult result;
    int pushed;

    require_update(state, script, fn);
    template_id = check_id(state, script, 1, fn);
    if (script->spawns >= script->spawn_limit) {
        return raise_budget(state, script, fn, "this update attempted too many spawns");
    }
    script->spawns += 1;
    /* The ledger entry is reserved before the world is asked, so a successful spawn can
     * never produce an entity the package does not own. */
    if (script->ledger->count >= FOUNDRY_SCRIPT_MAX_OWNED) {
        ledger_prune(state, script, fn);
        if (script->ledger->count >= FOUNDRY_SCRIPT_MAX_OWNED) {
            return raise_budget(state, script, fn, "this script already owns 256 live entities");
        }
    }
    pushed = preflight(state, script, template_id, fn);
    if (pushed != 0) {
        return pushed;
    }

    entity.bits = 0;
    result = CALL(state, script, fn, world_spawn, (template_id, &entity));
    if (result != FOUNDRY_OK) {
        return absent(state, script, fn, result);
    }
    script->ledger->entities[script->ledger->count] = entity;
    script->ledger->count += 1;
    push_value(state, TAG_ENTITY, entity.bits, 0);
    return 1;
}

static int f_world_destroy_entity(lua_State *state) {
    const char *fn = "foundry.world_destroy_entity";
    FoundryScript *script = enter(state, fn);
    FoundryEntity entity;
    FoundryResult result;
    int owned;

    require_update(state, script, fn);
    entity = check_entity(state, 1, fn);
    owned = ledger_find(script->ledger, entity);
    if (owned < 0) {
        return luaL_error(state, "contract: %s: this entity was not spawned by this script", fn);
    }
    result = CALL(state, script, fn, world_destroy_entity, (entity));
    if (result == FOUNDRY_OK || result == FOUNDRY_ERR_INVALID_HANDLE) {
        ledger_remove(script->ledger, (uint32_t)owned);
    }
    if (result == FOUNDRY_OK) {
        lua_pushboolean(state, 1);
        return 1;
    }
    if (result == FOUNDRY_ERR_INVALID_HANDLE) {
        lua_pushnil(state);
        lua_pushliteral(state, "not_found");
        return 2;
    }
    return absent(state, script, fn, result);
}

/* -- The value metatable --------------------------------------------------------------- */

static int value_eq(lua_State *state) {
    const ScriptValue *a = test_value(state, 1);
    const ScriptValue *b = test_value(state, 2);
    if (a == NULL || b == NULL) {
        lua_pushboolean(state, 0);
    } else if (a->tag == TAG_RNG || b->tag == TAG_RNG) {
        lua_pushboolean(state, a == b);
    } else {
        lua_pushboolean(state, a->tag == b->tag && a->kind == b->kind && a->bits == b->bits &&
                                   a->extra == b->extra);
    }
    return 1;
}

/* An unsigned value or an integer, for ordering. A negative integer orders below every
 * unsigned value; anything else is refused rather than ordered by address. */
static void order_operand(lua_State *state, int index, uint64_t *value, int *negative) {
    const ScriptValue *held;
    *negative = 0;
    if (lua_isinteger(state, index)) {
        lua_Integer integer = lua_tointeger(state, index);
        *negative = integer < 0;
        *value = (uint64_t)integer;
        return;
    }
    held = test_value(state, index);
    if (held == NULL || held->tag != TAG_U64) {
        luaL_error(state, "invalid_argument: only integers and unsigned values can be ordered");
    }
    *value = held->bits;
}

static int value_compare(lua_State *state, int or_equal) {
    uint64_t a, b;
    int a_negative, b_negative, less;
    order_operand(state, 1, &a, &a_negative);
    order_operand(state, 2, &b, &b_negative);
    if (a_negative != b_negative) {
        less = a_negative;
    } else {
        less = a < b;
    }
    lua_pushboolean(state, less || (or_equal && a == b && a_negative == b_negative));
    return 1;
}

static int value_lt(lua_State *state) {
    return value_compare(state, 0);
}

static int value_le(lua_State *state) {
    return value_compare(state, 1);
}

int foundry_script_format_value(lua_State *state, int index) {
    char text[48];
    const ScriptValue *value = test_value(state, index);
    if (value == NULL) {
        return 0;
    }
    switch (value->tag) {
        case TAG_ID: snprintf(text, sizeof(text), "id:%016llx", (unsigned long long)value->bits); break;
        case TAG_SCHEMA: snprintf(text, sizeof(text), "schema:%016llx", (unsigned long long)value->bits); break;
        case TAG_ENTITY: snprintf(text, sizeof(text), "entity:%016llx", (unsigned long long)value->bits); break;
        case TAG_COMPONENT_TYPE:
            snprintf(text, sizeof(text), "component_type:%016llx", (unsigned long long)value->bits);
            break;
        case TAG_U64: snprintf(text, sizeof(text), "%llu", (unsigned long long)value->bits); break;
        case TAG_RECORD: snprintf(text, sizeof(text), "record"); break;
        case TAG_CURSOR: snprintf(text, sizeof(text), "cursor"); break;
        case TAG_PACKAGE: snprintf(text, sizeof(text), "package"); break;
        default: snprintf(text, sizeof(text), "rng"); break;
    }
    lua_pushstring(state, text);
    return 1;
}

/* -- Installation ---------------------------------------------------------------------- */

/* Binding version 1's complete allowlist. Every entry not named here is absent. */
static const luaL_Reg binding_v1[] = {
    {"id_from_string", f_id_from_string},
    {"id_to_string", f_id_to_string},
    {"schema_id", f_schema_id},
    {"rng", f_rng},
    {"log_write", f_log_write},
    {"content_generation", f_content_generation},
    {"content_find", f_content_find},
    {"content_next", f_content_next},
    {"content_next_of_schema", f_content_next_of_schema},
    {"record_id", f_record_id},
    {"record_name", f_record_name},
    {"record_schema", f_record_schema},
    {"record_package", f_record_package},
    {"record_field_count", f_record_field_count},
    {"record_field_index", f_record_field_index},
    {"record_field_name", f_record_field_name},
    {"record_field_type", f_record_field_type},
    {"record_field_present", f_record_field_present},
    {"record_get_bool", f_record_get_bool},
    {"record_get_i64", f_record_get_i64},
    {"record_get_u64", f_record_get_u64},
    {"record_get_f32", f_record_get_f32},
    {"record_get_string", f_record_get_string},
    {"record_get_id", f_record_get_id},
    {"record_nested", f_record_nested},
    {"record_list_len", f_record_list_len},
    {"record_list_get_i64", f_record_list_get_i64},
    {"record_list_get_f32", f_record_list_get_f32},
    {"record_list_get_string", f_record_list_get_string},
    {"record_list_get_id", f_record_list_get_id},
    {"record_list_nested", f_record_list_nested},
    {"world_contains", f_world_contains},
    {"world_entity_count", f_world_entity_count},
    {"world_next_entity", f_world_next_entity},
    {"world_find_component_type", f_world_find_component_type},
    {"world_has_component", f_world_has_component},
    {"world_read_component", f_world_read_component},
    {"world_spawn", f_world_spawn},
    {"world_destroy_entity", f_world_destroy_entity},
    {NULL, NULL},
};

void foundry_script_open_binding(lua_State *state) {
    luaL_newmetatable(state, VALUE_METATABLE);
    lua_pushcfunction(state, value_eq);
    lua_setfield(state, -2, "__eq");
    lua_pushcfunction(state, value_lt);
    lua_setfield(state, -2, "__lt");
    lua_pushcfunction(state, value_le);
    lua_setfield(state, -2, "__le");
    lua_createtable(state, 0, 1);
    lua_pushcfunction(state, f_rng_next_u32);
    lua_setfield(state, -2, "next_u32");
    lua_setfield(state, -2, "__index");
    /* Nothing publishes getmetatable, but the lock costs nothing. */
    lua_pushboolean(state, 0);
    lua_setfield(state, -2, "__metatable");
    lua_pop(state, 1);

    lua_createtable(state, 0, (int)(sizeof(binding_v1) / sizeof(binding_v1[0]) - 1u));
    luaL_setfuncs(state, binding_v1, 0);
    lua_setglobal(state, "foundry");
}
