#include "bridge_private.h"

#include "lauxlib.h"

#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if LUA_INT_TYPE != LUA_INT_LONGLONG || LUA_FLOAT_TYPE != LUA_FLOAT_DOUBLE
#error "Foundry scripting requires Lua's default 64-bit integer and double configuration"
#endif

typedef char foundry_lua_integer_must_be_64_bit[(sizeof(lua_Integer) == 8) ? 1 : -1];
typedef char foundry_lua_number_must_be_double[(sizeof(lua_Number) == sizeof(double)) ? 1 : -1];

/* Keys one deterministic `pairs` walk may snapshot (scripting.md §9). */
#define FOUNDRY_SCRIPT_MAX_PAIRS 1024u
/* Values `string.byte` may return at once. */
#define FOUNDRY_SCRIPT_MAX_BYTES 256
/* A string `tonumber` will parse. */
#define FOUNDRY_SCRIPT_MAX_NUMERAL 64u

static int script_runner(lua_State *state);

/* The registry slots the author's module lives in. Their **addresses** are the keys, which
 * is why they are distinct objects and why nothing a script can name could collide with
 * them: the environment publishes no registry access at all (scripting.md §8). */
static const char module_registry_key = 0;
static const char state_registry_key = 0;

FoundryScript *foundry_script_from_state(lua_State *state) {
    FoundryScript *script = NULL;
    memcpy(&script, lua_getextraspace(state), sizeof(script));
    return script;
}

static void diagnostic_literal(FoundryScript *script, const char *message) {
    size_t length = strlen(message);
    if (length >= sizeof(script->diagnostic)) {
        length = sizeof(script->diagnostic) - 1;
    }
    memcpy(script->diagnostic, message, length);
    script->diagnostic[length] = '\0';
    script->diagnostic_length = length;
}

/* A failure the bridge names itself, rather than one a script raised: the category is known
 * here and is not read back off message text. The failure is a result failure because what
 * went wrong is the answer the script gave, not the execution that produced it. */
static void diagnostic_named(FoundryScript *script, FoundryScriptCategory category,
                             const char *fallback, const char *format, va_list args) {
    int written = vsnprintf(script->diagnostic, sizeof(script->diagnostic), format, args);
    if (written < 0) {
        diagnostic_literal(script, fallback);
    } else {
        script->diagnostic_length = (size_t)written >= sizeof(script->diagnostic)
            ? sizeof(script->diagnostic) - 1 : (size_t)written;
        script->diagnostic[script->diagnostic_length] = '\0';
    }
    script->failure = SCRIPT_FAILURE_RESULT;
    script->category = category;
}

/* A contract breach: the module or its state is not the shape §11 describes. Named rather
 * than raised, because the caller is the loader and not the script. */
static void diagnostic_contract(FoundryScript *script, const char *format, ...) {
    va_list args;
    va_start(args, format);
    diagnostic_named(script, FOUNDRY_SCRIPT_CATEGORY_CONTRACT,
                     "contract: the module is not what §11 describes", format, args);
    va_end(args);
}

/* A replacement's state could not be carried across (scripting.md §12). Its own category,
 * because the next move is the author's `migrate` and not the module's shape. */
static void diagnostic_migration(FoundryScript *script, const char *format, ...) {
    va_list args;
    va_start(args, format);
    diagnostic_named(script, FOUNDRY_SCRIPT_CATEGORY_MIGRATION,
                     "migration: the old state could not be carried across", format, args);
    va_end(args);
}

/* The category token every raise in this module and in `binding.c` puts first. An error a
 * script raised itself carries none, and is a plain runtime fault. */
static FoundryScriptCategory category_from_token(const char *text, size_t length) {
    static const struct {
        const char *token;
        FoundryScriptCategory category;
    } known[] = {
        {"contract", FOUNDRY_SCRIPT_CATEGORY_CONTRACT},
        {"invalid_argument", FOUNDRY_SCRIPT_CATEGORY_INVALID_ARGUMENT},
        {"stale_handle", FOUNDRY_SCRIPT_CATEGORY_STALE_HANDLE},
        {"unavailable", FOUNDRY_SCRIPT_CATEGORY_UNAVAILABLE},
        {"unsupported", FOUNDRY_SCRIPT_CATEGORY_UNAVAILABLE},
        {"refused", FOUNDRY_SCRIPT_CATEGORY_UNAVAILABLE},
        {"instruction_limit", FOUNDRY_SCRIPT_CATEGORY_INSTRUCTION_LIMIT},
        {"memory_limit", FOUNDRY_SCRIPT_CATEGORY_MEMORY_LIMIT},
        {"native_work_limit", FOUNDRY_SCRIPT_CATEGORY_NATIVE_WORK_LIMIT},
        /* A template refused for its shape is a bounded-work refusal, not a new class. */
        {"limit", FOUNDRY_SCRIPT_CATEGORY_NATIVE_WORK_LIMIT},
        {"migration", FOUNDRY_SCRIPT_CATEGORY_MIGRATION},
        {"source_rejected", FOUNDRY_SCRIPT_CATEGORY_SOURCE_REJECTED},
    };
    for (size_t i = 0; i < sizeof(known) / sizeof(known[0]); ++i) {
        if (strlen(known[i].token) == length && memcmp(known[i].token, text, length) == 0) {
            return known[i].category;
        }
    }
    return FOUNDRY_SCRIPT_CATEGORY_RUNTIME;
}

/* Reads `<chunk name>:<line>: ` off the front of a Lua error message, records the line and
 * returns what follows. The chunk name is `=`-prefixed, so Lua spells it literally and the
 * bridge knows exactly what it is looking at rather than guessing at a delimiter. */
static const char *skip_position(FoundryScript *script, const char *message, size_t *length) {
    const char *name = script->chunk_name + 1;
    size_t name_length = strlen(name);
    if (*length <= name_length + 1 || memcmp(message, name, name_length) != 0 ||
        message[name_length] != ':') {
        return message;
    }
    const char *cursor = message + name_length + 1;
    size_t remaining = *length - name_length - 1;
    uint64_t line = 0;
    size_t digits = 0;
    while (digits < remaining && cursor[digits] >= '0' && cursor[digits] <= '9') {
        if (line < UINT32_MAX) {
            line = line * 10 + (uint64_t)(cursor[digits] - '0');
        }
        digits++;
    }
    if (digits == 0 || digits >= remaining || cursor[digits] != ':') {
        return message;
    }
    script->error_line = line > UINT32_MAX ? UINT32_MAX : (uint32_t)line;
    cursor += digits + 1;
    remaining -= digits + 1;
    while (remaining > 0 && *cursor == ' ') {
        cursor++;
        remaining--;
    }
    *length = remaining;
    return cursor;
}

/* What a failed invocation was, as a category a host can branch on. A failure the bridge
 * already named outranks the message text; anything else is read off the raise's own
 * leading token. */
static void classify(FoundryScript *script, const char *message, size_t length) {
    switch (script->failure) {
        case SCRIPT_FAILURE_INSTRUCTION:
            script->category = FOUNDRY_SCRIPT_CATEGORY_INSTRUCTION_LIMIT;
            return;
        case SCRIPT_FAILURE_MEMORY:
            script->category = FOUNDRY_SCRIPT_CATEGORY_MEMORY_LIMIT;
            return;
        case SCRIPT_FAILURE_NATIVE_WORK:
            script->category = FOUNDRY_SCRIPT_CATEGORY_NATIVE_WORK_LIMIT;
            return;
        case SCRIPT_FAILURE_COMPILE:
            script->category = FOUNDRY_SCRIPT_CATEGORY_SYNTAX;
            return;
        case SCRIPT_FAILURE_RESULT:
            script->category = FOUNDRY_SCRIPT_CATEGORY_CONTRACT;
            return;
        default:
            break;
    }
    size_t token = 0;
    while (token < length && ((message[token] >= 'a' && message[token] <= 'z') ||
                              message[token] == '_')) {
        token++;
    }
    script->category = (token > 0 && token < length && message[token] == ':')
        ? category_from_token(message, token)
        : FOUNDRY_SCRIPT_CATEGORY_RUNTIME;
}

static void diagnostic_from_stack(FoundryScript *script, lua_State *state,
                                  const char *phase) {
    const char *message = NULL;
    size_t message_length = 0;
    if (lua_gettop(state) > 0 && lua_type(state, -1) == LUA_TSTRING) {
        message = lua_tolstring(state, -1, &message_length);
    }
    if (message == NULL) {
        const char *type = luaL_typename(state, -1);
        classify(script, "", 0);
        int written = snprintf(script->diagnostic, sizeof(script->diagnostic),
                               "%s: lua error (%s)", phase, type);
        if (written >= 0 && (size_t)written < sizeof(script->diagnostic)) {
            script->diagnostic_length = (size_t)written;
        } else {
            diagnostic_literal(script, phase);
        }
        return;
    }

    /* The position becomes the structured line; what stays in the text is the reason. */
    message = skip_position(script, message, &message_length);
    classify(script, message, message_length);
    int written = snprintf(script->diagnostic, sizeof(script->diagnostic),
                           "%s: %.*s", phase, (int)message_length, message);
    if (written < 0) {
        diagnostic_literal(script, phase);
    } else if ((size_t)written >= sizeof(script->diagnostic)) {
        script->diagnostic_length = sizeof(script->diagnostic) - 1;
        script->diagnostic[script->diagnostic_length] = '\0';
    } else {
        script->diagnostic_length = (size_t)written;
    }
}

/* Charges the VM's own heap and, when one is shared, the host's aggregate budget, both
 * before the allocation is attempted. A refused resize leaves the block and both accounts
 * exactly as they were. */
static void *quota_allocator(void *userdata, void *pointer, size_t old_size,
                             size_t new_size) {
    FoundryScript *script = (FoundryScript *)userdata;
    FoundryScriptBudget *budget = script->budget;
    size_t accounted_old_size = pointer == NULL ? 0 : old_size;

    if (new_size == 0) {
        script->allocator(script->allocator_userdata, pointer, old_size, 0);
        script->heap_used = accounted_old_size >= script->heap_used ? 0 : script->heap_used - accounted_old_size;
        if (budget != NULL) {
            budget->used = accounted_old_size >= budget->used ? 0 : budget->used - accounted_old_size;
        }
        return NULL;
    }

    if (script->fail_after_allocations != FOUNDRY_SCRIPT_NEVER_FAIL &&
        script->allocation_count >= script->fail_after_allocations) {
        return NULL;
    }

    size_t base = accounted_old_size >= script->heap_used ? 0 : script->heap_used - accounted_old_size;
    size_t available = base < script->heap_limit ? script->heap_limit - base : 0;
    if (new_size > available) {
        return NULL;
    }
    size_t shared_base = 0;
    if (budget != NULL) {
        shared_base = accounted_old_size >= budget->used ? 0 : budget->used - accounted_old_size;
        size_t shared_available = shared_base < budget->limit ? budget->limit - shared_base : 0;
        if (new_size > shared_available) {
            return NULL;
        }
    }

    void *next = script->allocator(script->allocator_userdata, pointer,
                                   old_size, new_size);
    if (next == NULL) {
        return NULL;
    }

    script->allocation_count += 1;
    script->heap_used = base + new_size;
    if (script->heap_used > script->heap_peak) {
        script->heap_peak = script->heap_used;
    }
    if (budget != NULL) {
        budget->used = shared_base + new_size;
    }
    return next;
}

/* -- The base environment (scripting.md §8), built by allowlist ------------------------- */

static int base_assert(lua_State *state) {
    if (lua_toboolean(state, 1)) {
        return lua_gettop(state);
    }
    if (lua_gettop(state) >= 2) {
        lua_settop(state, 2);
        return lua_error(state);
    }
    return luaL_error(state, "assertion failed");
}

static int base_error(lua_State *state) {
    if (lua_gettop(state) == 0) {
        lua_pushliteral(state, "error");
    }
    return lua_error(state);
}

static int base_type(lua_State *state) {
    luaL_checkany(state, 1);
    lua_pushstring(state, luaL_typename(state, 1));
    return 1;
}

static int base_select(lua_State *state) {
    int top = lua_gettop(state);
    if (lua_type(state, 1) == LUA_TSTRING && strcmp(lua_tostring(state, 1), "#") == 0) {
        lua_pushinteger(state, top - 1);
        return 1;
    }
    if (!lua_isinteger(state, 1)) {
        return luaL_error(state, "invalid_argument: select: argument 1 must be an integer or '#'");
    }
    lua_Integer n = lua_tointeger(state, 1);
    if (n < 0) {
        n = top + n;
    } else if (n > top) {
        n = top;
    }
    if (n < 1) {
        return luaL_error(state, "invalid_argument: select: index out of range");
    }
    return top - (int)n;
}

/* Numbers, and short numerals. A parse is bounded by the length it may read. */
static int base_tonumber(lua_State *state) {
    if (lua_type(state, 1) == LUA_TNUMBER) {
        lua_settop(state, 1);
        return 1;
    }
    if (lua_type(state, 1) == LUA_TSTRING) {
        size_t length = 0;
        const char *text = lua_tolstring(state, 1, &length);
        if (length <= FOUNDRY_SCRIPT_MAX_NUMERAL && lua_stringtonumber(state, text) != 0) {
            return 1;
        }
    }
    lua_pushnil(state);
    return 1;
}

/* Scalars and the bridge's own values only: Lua's default formatting of a table, function
 * or userdata is its address, and an address is not something gameplay may observe. */
static int base_tostring(lua_State *state) {
    char text[64];
    luaL_checkany(state, 1);
    switch (lua_type(state, 1)) {
        case LUA_TSTRING:
            lua_settop(state, 1);
            return 1;
        case LUA_TNIL:
            lua_pushliteral(state, "nil");
            return 1;
        case LUA_TBOOLEAN:
            lua_pushstring(state, lua_toboolean(state, 1) ? "true" : "false");
            return 1;
        case LUA_TNUMBER:
            if (lua_isinteger(state, 1)) {
                snprintf(text, sizeof(text), "%lld", (long long)lua_tointeger(state, 1));
            } else {
                snprintf(text, sizeof(text), "%.17g", (double)lua_tonumber(state, 1));
            }
            lua_pushstring(state, text);
            return 1;
        case LUA_TUSERDATA:
            if (foundry_script_format_value(state, 1)) {
                return 1;
            }
            break;
        default:
            break;
    }
    return luaL_error(state, "invalid_argument: tostring is not available for this value");
}

static int ipairs_iterator(lua_State *state) {
    lua_Integer index = luaL_checkinteger(state, 2) + 1;
    lua_pushinteger(state, index);
    lua_gettable(state, 1);
    if (lua_isnil(state, -1)) {
        return 1;
    }
    lua_pushinteger(state, index);
    lua_insert(state, -2);
    return 2;
}

static int base_ipairs(lua_State *state) {
    luaL_checktype(state, 1, LUA_TTABLE);
    lua_pushcfunction(state, ipairs_iterator);
    lua_pushvalue(state, 1);
    lua_pushinteger(state, 0);
    return 3;
}

typedef struct PairKey {
    int is_string;
    lua_Integer integer;
    const char *text;
    size_t length;
} PairKey;

/* Integers ascending, then strings by unsigned byte order. Keys are unique, so this is a
 * total order and qsort's instability cannot show. */
static int compare_keys(const void *left, const void *right) {
    const PairKey *a = (const PairKey *)left;
    const PairKey *b = (const PairKey *)right;
    if (a->is_string != b->is_string) {
        return a->is_string ? 1 : -1;
    }
    if (!a->is_string) {
        return (a->integer > b->integer) - (a->integer < b->integer);
    }
    size_t shorter = a->length < b->length ? a->length : b->length;
    int order = memcmp(a->text, b->text, shorter);
    if (order != 0) {
        return order;
    }
    return (a->length > b->length) - (a->length < b->length);
}

/* Upvalues: the sorted key snapshot, the position, and the table being walked. */
static int pairs_iterator(lua_State *state) {
    lua_Integer position = lua_tointeger(state, lua_upvalueindex(2)) + 1;
    lua_pushinteger(state, position);
    lua_replace(state, lua_upvalueindex(2));
    if (lua_rawgeti(state, lua_upvalueindex(1), position) == LUA_TNIL) {
        return 1;
    }
    lua_pushvalue(state, -1);
    lua_rawget(state, lua_upvalueindex(3));
    return 2;
}

/* Walks a bounded snapshot of the table's keys in a documented order, so the same table
 * contents are visited in the same order on every machine and every run (I9). */
static int base_pairs(lua_State *state) {
    size_t count = 0, index = 0, i;
    PairKey *keys;

    luaL_checktype(state, 1, LUA_TTABLE);
    lua_settop(state, 1);
    lua_pushnil(state);
    while (lua_next(state, 1) != 0) {
        int type;
        lua_pop(state, 1);
        type = lua_type(state, -1);
        if (type != LUA_TSTRING && !(type == LUA_TNUMBER && lua_isinteger(state, -1))) {
            return luaL_error(state, "invalid_argument: pairs: keys must be integers or strings");
        }
        count += 1;
        if (count > FOUNDRY_SCRIPT_MAX_PAIRS) {
            return luaL_error(state, "native_work_limit: pairs: the table has more than 1024 keys");
        }
    }

    keys = (PairKey *)lua_newuserdatauv(state, (count == 0 ? 1 : count) * sizeof(PairKey), 0);
    lua_pushnil(state);
    while (lua_next(state, 1) != 0) {
        lua_pop(state, 1);
        if (lua_type(state, -1) == LUA_TSTRING) {
            keys[index].is_string = 1;
            keys[index].integer = 0;
            keys[index].text = lua_tolstring(state, -1, &keys[index].length);
        } else {
            keys[index].is_string = 0;
            keys[index].integer = lua_tointeger(state, -1);
            keys[index].text = NULL;
            keys[index].length = 0;
        }
        index += 1;
    }
    qsort(keys, count, sizeof(PairKey), compare_keys);

    lua_createtable(state, (int)count, 0);
    for (i = 0; i < count; ++i) {
        if (keys[i].is_string) {
            lua_pushlstring(state, keys[i].text, keys[i].length);
        } else {
            lua_pushinteger(state, keys[i].integer);
        }
        lua_rawseti(state, -2, (lua_Integer)i + 1);
    }
    lua_pushinteger(state, 0);
    lua_pushvalue(state, 1);
    lua_pushcclosure(state, pairs_iterator, 3);
    lua_pushvalue(state, 1);
    lua_pushnil(state);
    return 3;
}

static lua_Number check_number(lua_State *state, int index, const char *fn) {
    if (lua_type(state, index) != LUA_TNUMBER) {
        luaL_error(state, "invalid_argument: %s: argument %d must be a number", fn, index);
    }
    return lua_tonumber(state, index);
}

/* A float with an integral value that fits becomes an integer, as Lua's own floor does. */
static void push_integral(lua_State *state, lua_Number value) {
    if (value >= -9223372036854775808.0 && value < 9223372036854775808.0) {
        lua_pushinteger(state, (lua_Integer)value);
    } else {
        lua_pushnumber(state, value);
    }
}

static int math_abs(lua_State *state) {
    if (lua_isinteger(state, 1)) {
        lua_Integer value = lua_tointeger(state, 1);
        lua_pushinteger(state, value < 0 ? (lua_Integer)(0u - (lua_Unsigned)value) : value);
    } else {
        lua_pushnumber(state, fabs(check_number(state, 1, "math.abs")));
    }
    return 1;
}

static int math_floor(lua_State *state) {
    if (lua_isinteger(state, 1)) {
        lua_settop(state, 1);
    } else {
        push_integral(state, floor(check_number(state, 1, "math.floor")));
    }
    return 1;
}

static int math_ceil(lua_State *state) {
    if (lua_isinteger(state, 1)) {
        lua_settop(state, 1);
    } else {
        push_integral(state, ceil(check_number(state, 1, "math.ceil")));
    }
    return 1;
}

static int math_extreme(lua_State *state, const char *fn, int want_max) {
    int count = lua_gettop(state), best = 1, i;
    if (count < 1) {
        return luaL_error(state, "invalid_argument: %s: at least one number is required", fn);
    }
    for (i = 1; i <= count; ++i) {
        (void)check_number(state, i, fn);
    }
    for (i = 2; i <= count; ++i) {
        int beats = want_max ? lua_compare(state, best, i, LUA_OPLT)
                             : lua_compare(state, i, best, LUA_OPLT);
        if (beats) {
            best = i;
        }
    }
    lua_pushvalue(state, best);
    return 1;
}

static int math_min(lua_State *state) {
    return math_extreme(state, "math.min", 0);
}

static int math_max(lua_State *state) {
    return math_extreme(state, "math.max", 1);
}

static int math_sqrt(lua_State *state) {
    lua_pushnumber(state, sqrt(check_number(state, 1, "math.sqrt")));
    return 1;
}

static const char *check_string(lua_State *state, int index, size_t *length, const char *fn) {
    if (lua_type(state, index) != LUA_TSTRING) {
        luaL_error(state, "invalid_argument: %s: argument %d must be a string", fn, index);
    }
    return lua_tolstring(state, index, length);
}

static lua_Integer check_integer(lua_State *state, int index, lua_Integer fallback, const char *fn) {
    if (lua_isnoneornil(state, index)) {
        return fallback;
    }
    if (!lua_isinteger(state, index)) {
        luaL_error(state, "invalid_argument: %s: argument %d must be an integer", fn, index);
    }
    return lua_tointeger(state, index);
}

/* Lua's own relative-position rule, clamped to [1, length + 1]. */
static size_t start_position(lua_Integer position, size_t length) {
    if (position > 0) {
        return (size_t)position;
    }
    if (position == 0) {
        return 1;
    }
    if (position < -(lua_Integer)length) {
        return 1;
    }
    return length + (size_t)position + 1;
}

static size_t end_position(lua_Integer position, size_t length) {
    if (position > (lua_Integer)length) {
        return length;
    }
    if (position >= 0) {
        return (size_t)position;
    }
    if (position < -(lua_Integer)length) {
        return 0;
    }
    return length + (size_t)position + 1;
}

static int string_len(lua_State *state) {
    size_t length = 0;
    (void)check_string(state, 1, &length, "string.len");
    lua_pushinteger(state, (lua_Integer)length);
    return 1;
}

static int string_sub(lua_State *state) {
    size_t length = 0;
    const char *text = check_string(state, 1, &length, "string.sub");
    size_t first = start_position(check_integer(state, 2, 1, "string.sub"), length);
    size_t last = end_position(check_integer(state, 3, -1, "string.sub"), length);
    if (first > last) {
        lua_pushliteral(state, "");
        return 1;
    }
    if (last - first + 1 > FOUNDRY_SCRIPT_MAX_STRING) {
        return luaL_error(state, "native_work_limit: string.sub: the result is longer than 16 KiB");
    }
    lua_pushlstring(state, text + first - 1, last - first + 1);
    return 1;
}

static int string_byte(lua_State *state) {
    size_t length = 0, i;
    const char *text = check_string(state, 1, &length, "string.byte");
    lua_Integer from = check_integer(state, 2, 1, "string.byte");
    size_t first = start_position(from, length);
    size_t last = end_position(check_integer(state, 3, from, "string.byte"), length);
    if (first > last) {
        return 0;
    }
    if (last - first + 1 > FOUNDRY_SCRIPT_MAX_BYTES) {
        return luaL_error(state, "native_work_limit: string.byte: more than 256 values requested");
    }
    luaL_checkstack(state, (int)(last - first + 1), "string.byte");
    for (i = first; i <= last; ++i) {
        lua_pushinteger(state, (lua_Integer)(unsigned char)text[i - 1]);
    }
    return (int)(last - first + 1);
}

static int string_char(lua_State *state) {
    char buffer[FOUNDRY_SCRIPT_MAX_BYTES];
    int count = lua_gettop(state), i;
    if (count > FOUNDRY_SCRIPT_MAX_BYTES) {
        return luaL_error(state, "native_work_limit: string.char: more than 256 values");
    }
    for (i = 1; i <= count; ++i) {
        lua_Integer value = check_integer(state, i, 0, "string.char");
        if (value < 0 || value > 255) {
            return luaL_error(state, "invalid_argument: string.char: argument %d is not a byte", i);
        }
        buffer[i - 1] = (char)value;
    }
    lua_pushlstring(state, buffer, (size_t)count);
    return 1;
}

/* ASCII only, so the answer never depends on the host's locale. */
static int string_case(lua_State *state, const char *fn, int upper) {
    char buffer[FOUNDRY_SCRIPT_MAX_STRING];
    size_t length = 0, i;
    const char *text = check_string(state, 1, &length, fn);
    if (length > FOUNDRY_SCRIPT_MAX_STRING) {
        return luaL_error(state, "native_work_limit: %s: the string is longer than 16 KiB", fn);
    }
    for (i = 0; i < length; ++i) {
        char c = text[i];
        if (upper && c >= 'a' && c <= 'z') {
            c = (char)(c - 'a' + 'A');
        } else if (!upper && c >= 'A' && c <= 'Z') {
            c = (char)(c - 'A' + 'a');
        }
        buffer[i] = c;
    }
    lua_pushlstring(state, buffer, length);
    return 1;
}

static int string_lower(lua_State *state) {
    return string_case(state, "string.lower", 0);
}

static int string_upper(lua_State *state) {
    return string_case(state, "string.upper", 1);
}

static const luaL_Reg base_library[] = {
    {"assert", base_assert},
    {"error", base_error},
    {"type", base_type},
    {"select", base_select},
    {"tonumber", base_tonumber},
    {"tostring", base_tostring},
    {"ipairs", base_ipairs},
    {"pairs", base_pairs},
    {NULL, NULL},
};

static const luaL_Reg math_library[] = {
    {"abs", math_abs},
    {"ceil", math_ceil},
    {"floor", math_floor},
    {"min", math_min},
    {"max", math_max},
    {"sqrt", math_sqrt},
    {NULL, NULL},
};

static const luaL_Reg string_library[] = {
    {"len", string_len},
    {"sub", string_sub},
    {"byte", string_byte},
    {"char", string_char},
    {"lower", string_lower},
    {"upper", string_upper},
    {NULL, NULL},
};

/* No `luaL_openlibs` and no deletion afterwards: a name is present only because it is
 * listed here. Strings get no metatable, so `("x"):rep(...)` reaches nothing. */
static void install_environment(lua_State *state) {
    lua_pushglobaltable(state);
    luaL_setfuncs(state, base_library, 0);
    lua_pop(state, 1);
    lua_createtable(state, 0, 6);
    luaL_setfuncs(state, math_library, 0);
    lua_setglobal(state, "math");
    lua_createtable(state, 0, 6);
    luaL_setfuncs(state, string_library, 0);
    lua_setglobal(state, "string");
}

static void script_hook(lua_State *state, lua_Debug *debug) {
    (void)debug;
    FoundryScript *script = foundry_script_from_state(state);
    if (script->instructions > script->active_instruction_limit - script->hook_period) {
        script->failure = SCRIPT_FAILURE_INSTRUCTION;
        script->terminal = 1;
        luaL_error(state, "instruction_limit: this invocation exceeded its instruction budget");
    }
    script->instructions += script->hook_period;
}

static int bootstrap_function(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    install_environment(state);
    if (script->api != NULL) {
        foundry_script_open_binding(state);
    }
    return 0;
}

static int script_runner(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    if (script->inject_compile_failure != 0) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "compile: injected allocation failure");
        return 0;
    }
    int status = luaL_loadbufferx(state, (const char *)script->source,
                                  script->source_len, script->chunk_name, "t");
    if (status != LUA_OK) {
        script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_COMPILE;
        diagnostic_from_stack(script, state, "compile");
        lua_settop(state, 0);
        return 0;
    }

    status = lua_pcall(state, 0, 1, 0);
    if (status != LUA_OK) {
        /* The hook and the binding set the failure before raising, so theirs stands. */
        if (script->failure == SCRIPT_FAILURE_NONE) {
            script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_RUNTIME;
        }
        diagnostic_from_stack(script, state, "execute");
        lua_settop(state, 0);
        return 0;
    }

    if (script->inject_result_failure != 0 || !lua_isinteger(state, -1)) {
        script->failure = SCRIPT_FAILURE_RESULT;
        diagnostic_literal(script, "result: expected one integer");
        lua_settop(state, 0);
        return 0;
    }
    script->result = (int64_t)lua_tointeger(state, -1);
    script->result_is_integer = 1;
    lua_settop(state, 0);
    return 0;
}

/* The outer half of every protected invocation. The inner half is whatever the entry point
 * set as pending; nesting them is what makes a script fault distinguishable from a failure
 * of the machinery that was running it. */
static int execute_function(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    if (!lua_checkstack(state, LUA_MINSTACK)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "invoke: stack limit exceeded");
        return 0;
    }
    lua_pushcfunction(state, script->pending);
    int status = lua_pcall(state, 0, 0, 0);
    if (status != LUA_OK) {
        if (script->failure == SCRIPT_FAILURE_NONE) {
            script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_RUNTIME;
        }
        diagnostic_from_stack(script, state, "invoke");
        lua_settop(state, 0);
    }
    return 0;
}

static FoundryScriptStatus status_from_failure(ScriptFailure failure) {
    switch (failure) {
        case SCRIPT_FAILURE_NONE:
            return FOUNDRY_SCRIPT_OK;
        case SCRIPT_FAILURE_COMPILE:
            return FOUNDRY_SCRIPT_COMPILE_ERROR;
        case SCRIPT_FAILURE_RUNTIME:
            return FOUNDRY_SCRIPT_RUNTIME_ERROR;
        case SCRIPT_FAILURE_INSTRUCTION:
            return FOUNDRY_SCRIPT_INSTRUCTION_LIMIT;
        case SCRIPT_FAILURE_MEMORY:
            return FOUNDRY_SCRIPT_MEMORY_LIMIT;
        case SCRIPT_FAILURE_RESULT:
            return FOUNDRY_SCRIPT_RESULT_ERROR;
        case SCRIPT_FAILURE_NATIVE_WORK:
            return FOUNDRY_SCRIPT_NATIVE_WORK_LIMIT;
    }
    return FOUNDRY_SCRIPT_RUNTIME_ERROR;
}

/* A new invocation: this phase's instruction budget, fresh per-invocation counters, and
 * every record or cursor the last one made now stale (scripting.md §7). */
static void begin_invocation(FoundryScript *script, FoundryScriptPhase phase) {
    script->instructions = 0;
    script->active_instruction_limit = phase == FOUNDRY_SCRIPT_PHASE_PREPARE
        ? script->prepare_instruction_limit : script->instruction_limit;
    script->failure = SCRIPT_FAILURE_NONE;
    script->terminal = 0;
    script->phase = phase;
    script->invocation += 1;
    script->abi_calls = 0;
    script->spawns = 0;
    script->logs = 0;
    script->category = FOUNDRY_SCRIPT_CATEGORY_NONE;
    script->error_line = 0;
    diagnostic_literal(script, "");
    lua_settop(script->state, 0);
}

/* Runs `inner` as one protected invocation in `phase`. No Lua error reaches the caller:
 * the two nested protected calls are what §4 requires, and this is the only way in. */
static FoundryScriptStatus invoke(FoundryScript *script, lua_CFunction inner,
                                  FoundryScriptPhase phase) {
    begin_invocation(script, phase);
    script->pending = inner;
    if (!lua_checkstack(script->state, LUA_MINSTACK)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        script->category = FOUNDRY_SCRIPT_CATEGORY_MEMORY_LIMIT;
        diagnostic_literal(script, "invoke: stack limit exceeded");
        return FOUNDRY_SCRIPT_MEMORY_LIMIT;
    }
    lua_pushcfunction(script->state, execute_function);
    int status = lua_pcall(script->state, 0, 0, 0);
    if (status != LUA_OK && script->failure == SCRIPT_FAILURE_NONE) {
        script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_RUNTIME;
        diagnostic_literal(script, status == LUA_ERRMEM ?
            "invoke: memory limit exceeded" : "invoke: failed");
    }
    /* A failure named by a literal diagnostic still owes the host a category. */
    if (script->failure != SCRIPT_FAILURE_NONE &&
        script->category == FOUNDRY_SCRIPT_CATEGORY_NONE) {
        classify(script, "", 0);
    }
    return status_from_failure(script->failure);
}

static uint32_t limit_or_default(uint32_t value, uint32_t fallback) {
    uint32_t chosen = value == 0 ? fallback : value;
    return chosen > (uint32_t)INT_MAX ? (uint32_t)INT_MAX : chosen;
}

FoundryScriptStatus foundry_script_create(FoundryScript **out,
                                          const FoundryScriptConfig *config) {
    const FoundryApi_v2 *api = NULL;
    if (out == NULL || config == NULL || config->heap_limit == 0 ||
        config->instruction_limit == 0 || config->hook_period == 0 ||
        config->hook_period > config->instruction_limit ||
        config->hook_period > (uint32_t)INT_MAX || config->allocator == NULL ||
        (config->prepare_instruction_limit != 0 &&
         config->hook_period > config->prepare_instruction_limit)) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    *out = NULL;
    /* The binding is a v2 consumer like any other: it asks, and checks what it was given
     * rather than trusting the answer's shape. */
    if (config->get_api != NULL) {
        if (config->ledger == NULL || config->self.bits == 0) {
            return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
        }
        api = (const FoundryApi_v2 *)config->get_api(FOUNDRY_API_VERSION_2);
        if (api == NULL || api->version != FOUNDRY_API_VERSION_2 ||
            api->size < (uint32_t)sizeof(FoundryApi_v2)) {
            return FOUNDRY_SCRIPT_UNSUPPORTED;
        }
    }

    FoundryScript *script = (FoundryScript *)config->allocator(
        config->allocator_userdata, NULL, 0, sizeof(*script));
    if (script == NULL) {
        return FOUNDRY_SCRIPT_BOOTSTRAP_ERROR;
    }
    memset(script, 0, sizeof(*script));
    script->allocator = config->allocator;
    script->allocator_userdata = config->allocator_userdata;
    script->budget = config->budget;
    script->heap_limit = config->heap_limit;
    script->fail_after_allocations = config->fail_after_allocations;
    script->instruction_limit = config->instruction_limit;
    /* Zero means one budget for both phases, which is what a zeroed C config asks for. */
    script->prepare_instruction_limit = config->prepare_instruction_limit == 0
        ? config->instruction_limit : config->prepare_instruction_limit;
    script->active_instruction_limit = script->instruction_limit;
    script->hook_period = config->hook_period;
    /* `=` so Lua spells the name literally in its own messages rather than wrapping it in
     * `[string "..."]`; a host names a real package through `load_module`. */
    memcpy(script->chunk_name, "=foundry-script", sizeof("=foundry-script"));
    script->inject_teardown_failure = config->inject_teardown_failure;
    script->inject_result_failure = config->inject_result_failure;
    script->inject_compile_failure = config->inject_compile_failure;
    script->api = api;
    script->self = config->self;
    script->ledger = config->ledger;
    script->abi_call_limit = limit_or_default(config->abi_call_limit, FOUNDRY_SCRIPT_DEFAULT_ABI_CALLS);
    script->spawn_limit = limit_or_default(config->spawn_limit, FOUNDRY_SCRIPT_DEFAULT_SPAWNS);
    script->log_limit = limit_or_default(config->log_limit, FOUNDRY_SCRIPT_DEFAULT_LOGS);
    diagnostic_literal(script, "");

    script->state = lua_newstate(quota_allocator, script, 0);
    if (script->state == NULL) {
        diagnostic_literal(script, "bootstrap: memory limit exceeded");
        script->allocator(script->allocator_userdata, script, sizeof(*script), 0);
        return FOUNDRY_SCRIPT_BOOTSTRAP_ERROR;
    }
    memcpy(lua_getextraspace(script->state), &script, sizeof(script));
    lua_sethook(script->state, script_hook, LUA_MASKCOUNT, script->hook_period);

    if (!lua_checkstack(script->state, LUA_MINSTACK)) {
        diagnostic_literal(script, "bootstrap: stack limit exceeded");
        lua_close(script->state);
        script->allocator(script->allocator_userdata, script, sizeof(*script), 0);
        return FOUNDRY_SCRIPT_BOOTSTRAP_ERROR;
    }
    lua_pushcfunction(script->state, bootstrap_function);
    int status = lua_pcall(script->state, 0, 0, 0);
    if (status != LUA_OK) {
        diagnostic_literal(script, status == LUA_ERRMEM ?
            "bootstrap: memory limit exceeded" : "bootstrap: failed");
        lua_close(script->state);
        script->allocator(script->allocator_userdata, script, sizeof(*script), 0);
        return FOUNDRY_SCRIPT_BOOTSTRAP_ERROR;
    }

    *out = script;
    return FOUNDRY_SCRIPT_OK;
}

FoundryScriptStatus foundry_script_execute(FoundryScript *script,
                                           const uint8_t *source,
                                           size_t source_len,
                                           FoundryScriptPhase phase,
                                           FoundryScriptResult *result) {
    if (script == NULL || script->state == NULL || source == NULL || result == NULL ||
        source_len == 0 || source_len > FOUNDRY_SCRIPT_MAX_SOURCE ||
        memchr(source, '\0', source_len) != NULL ||
        (phase != FOUNDRY_SCRIPT_PHASE_PREPARE && phase != FOUNDRY_SCRIPT_PHASE_UPDATE)) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    if (source_len >= sizeof(LUA_SIGNATURE) - 1 &&
        memcmp(source, LUA_SIGNATURE, sizeof(LUA_SIGNATURE) - 1) == 0) {
        diagnostic_literal(script, "compile: binary chunks are not accepted");
        return FOUNDRY_SCRIPT_COMPILE_ERROR;
    }

    script->source = source;
    script->source_len = source_len;
    script->result_is_integer = 0;

    FoundryScriptStatus result_status = invoke(script, script_runner, phase);
    if (result_status != FOUNDRY_SCRIPT_OK) {
        return result_status;
    }
    if (!script->result_is_integer) {
        diagnostic_literal(script, "result: missing integer");
        script->category = FOUNDRY_SCRIPT_CATEGORY_CONTRACT;
        return FOUNDRY_SCRIPT_RESULT_ERROR;
    }
    result->integer = script->result;
    return FOUNDRY_SCRIPT_OK;
}

/* -- The author's module (scripting.md §11) --------------------------------------------
 *
 * `load_module` evaluates the chunk and keeps the table it returned; `init_state` calls
 * `init()` and keeps the table it returned; `update` calls `update(state, step)`. Both
 * tables live in the registry across invocations, which nothing in the script environment
 * can name. A breach of the contract is diagnosed by name rather than raised: a misspelled
 * lifecycle field is an ordinary authoring mistake and deserves to be told, not traced.
 */

static const char *const module_fields[] = {"state_version", "init", "update", "migrate"};

static int recognised_field(const char *name, size_t length) {
    for (size_t i = 0; i < sizeof(module_fields) / sizeof(module_fields[0]); ++i) {
        if (strlen(module_fields[i]) == length && memcmp(module_fields[i], name, length) == 0) {
            return 1;
        }
    }
    return 0;
}

static int validate_module(lua_State *state, FoundryScript *script, int index) {
    /* Every field the module publishes must be one this version recognises, which is what
     * turns `udpate = function...` into a message instead of a script that never runs. */
    lua_pushnil(state);
    while (lua_next(state, index) != 0) {
        if (lua_type(state, -2) != LUA_TSTRING) {
            diagnostic_contract(script, "contract: the module is keyed by a %s; §11 names four fields",
                                luaL_typename(state, -2));
            lua_pop(state, 2);
            return 0;
        }
        size_t length = 0;
        const char *name = lua_tolstring(state, -2, &length);
        if (!recognised_field(name, length)) {
            diagnostic_contract(script,
                                "contract: the module has no field '%.*s'; §11 recognises "
                                "state_version, init, update and migrate",
                                (int)length, name);
            lua_pop(state, 2);
            return 0;
        }
        lua_pop(state, 1);
    }

    lua_getfield(state, index, "state_version");
    if (!lua_isinteger(state, -1)) {
        diagnostic_contract(script, "contract: state_version must be a positive integer");
        lua_pop(state, 1);
        return 0;
    }
    lua_Integer version = lua_tointeger(state, -1);
    lua_pop(state, 1);
    if (version <= 0 || version > (lua_Integer)UINT32_MAX) {
        diagnostic_contract(script, "contract: state_version must be between 1 and 4294967295");
        return 0;
    }

    for (size_t i = 1; i <= 2; ++i) {
        lua_getfield(state, index, module_fields[i]);
        int is_function = lua_isfunction(state, -1);
        lua_pop(state, 1);
        if (!is_function) {
            diagnostic_contract(script, "contract: %s must be a function", module_fields[i]);
            return 0;
        }
    }

    int migrate = lua_getfield(state, index, "migrate");
    lua_pop(state, 1);
    if (migrate != LUA_TNIL && migrate != LUA_TFUNCTION) {
        diagnostic_contract(script, "contract: migrate must be a function when it is present");
        return 0;
    }

    script->state_version = (uint32_t)version;
    return 1;
}

/* -- The persistent state (scripting.md §11) ------------------------------------------- */

typedef struct StateWalk {
    uint32_t entries;
    size_t bytes;
    /* Absolute index of the table recording which tables this walk has already entered. */
    int seen;
} StateWalk;

static int validate_state_value(lua_State *state, FoundryScript *script, int index,
                                uint32_t depth, StateWalk *walk);

static int validate_state_table(lua_State *state, FoundryScript *script, int index,
                                uint32_t depth, StateWalk *walk) {
    if (depth > FOUNDRY_SCRIPT_MAX_STATE_DEPTH) {
        diagnostic_contract(script, "contract: state nests deeper than %u tables",
                            (unsigned)FOUNDRY_SCRIPT_MAX_STATE_DEPTH);
        return 0;
    }
    /* One walk, one visit. A cycle and a table stored in two places fail the same check,
     * deliberately: the representation a reload copies preserves neither (§11). */
    lua_pushvalue(state, index);
    lua_rawget(state, walk->seen);
    int repeated = !lua_isnil(state, -1);
    lua_pop(state, 1);
    if (repeated) {
        diagnostic_contract(script, "contract: state holds the same table twice, or a cycle");
        return 0;
    }
    lua_pushvalue(state, index);
    lua_pushboolean(state, 1);
    lua_rawset(state, walk->seen);

    lua_pushnil(state);
    while (lua_next(state, index) != 0) {
        int key_type = lua_type(state, -2);
        if (key_type == LUA_TSTRING) {
            size_t length = 0;
            (void)lua_tolstring(state, -2, &length);
            walk->bytes += length;
        } else if (key_type != LUA_TNUMBER || !lua_isinteger(state, -2)) {
            diagnostic_contract(script, "contract: state is keyed by a %s; only integers and strings persist",
                                luaL_typename(state, -2));
            lua_pop(state, 2);
            return 0;
        }
        walk->entries += 1;
        if (walk->entries > FOUNDRY_SCRIPT_MAX_STATE_ENTRIES) {
            diagnostic_contract(script, "contract: state holds more than %u entries",
                                (unsigned)FOUNDRY_SCRIPT_MAX_STATE_ENTRIES);
            lua_pop(state, 2);
            return 0;
        }
        if (!validate_state_value(state, script, lua_gettop(state), depth + 1, walk)) {
            lua_pop(state, 2);
            return 0;
        }
        lua_pop(state, 1);
    }
    return 1;
}

static int validate_state_value(lua_State *state, FoundryScript *script, int index,
                                uint32_t depth, StateWalk *walk) {
    switch (lua_type(state, index)) {
        case LUA_TBOOLEAN:
            walk->bytes += 8;
            break;
        case LUA_TNUMBER:
            if (!lua_isinteger(state, index) && !isfinite((double)lua_tonumber(state, index))) {
                diagnostic_contract(script, "contract: state holds a number that is not finite");
                return 0;
            }
            walk->bytes += 8;
            break;
        case LUA_TSTRING: {
            size_t length = 0;
            (void)lua_tolstring(state, index, &length);
            if (length > FOUNDRY_SCRIPT_MAX_STRING) {
                diagnostic_contract(script, "contract: state holds a string longer than %u bytes",
                                    (unsigned)FOUNDRY_SCRIPT_MAX_STRING);
                return 0;
            }
            walk->bytes += length;
            break;
        }
        case LUA_TTABLE:
            if (!validate_state_table(state, script, index, depth, walk)) {
                return 0;
            }
            break;
        case LUA_TUSERDATA:
            if (!foundry_script_value_is_persistable(state, index, script)) {
                diagnostic_contract(script,
                                    "contract: state holds a value that cannot outlive this "
                                    "invocation; records, cursors, packages and component "
                                    "types must be found again");
                return 0;
            }
            /* What one bridge value costs in the bounded representation §11 describes:
             * a tag and the two words behind it, whatever Lua spends on the box. */
            walk->bytes += 32;
            break;
        default:
            diagnostic_contract(script, "contract: state holds a %s, which cannot persist",
                                luaL_typename(state, index));
            return 0;
    }
    if (walk->bytes > FOUNDRY_SCRIPT_MAX_STATE_BYTES) {
        diagnostic_contract(script, "contract: state is larger than %u bytes",
                            (unsigned)FOUNDRY_SCRIPT_MAX_STATE_BYTES);
        return 0;
    }
    return 1;
}

/* Validates the table on the top of the stack as a persistent state root, leaving it there. */
static int validate_state_root(lua_State *state, FoundryScript *script) {
    if (!lua_checkstack(state, 8)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "state: stack limit exceeded");
        return 0;
    }
    int root = lua_gettop(state);
    lua_newtable(state);
    StateWalk walk = {0, 0, lua_gettop(state)};
    int ok = validate_state_table(state, script, root, 1, &walk);
    /* The `seen` table goes whatever happened; the root stays for the caller to store. */
    lua_remove(state, walk.seen);
    return ok;
}

/* -- The three entry points ------------------------------------------------------------ */

static int module_loader(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    if (script->inject_compile_failure != 0) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "load: injected allocation failure");
        return 0;
    }
    int status = luaL_loadbufferx(state, (const char *)script->source, script->source_len,
                                  script->chunk_name, "t");
    if (status != LUA_OK) {
        script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_COMPILE;
        diagnostic_from_stack(script, state, "load");
        lua_settop(state, 0);
        return 0;
    }
    status = lua_pcall(state, 0, 1, 0);
    if (status != LUA_OK) {
        if (script->failure == SCRIPT_FAILURE_NONE) {
            script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_RUNTIME;
        }
        diagnostic_from_stack(script, state, "load");
        lua_settop(state, 0);
        return 0;
    }
    if (!lua_istable(state, -1)) {
        diagnostic_contract(script, "contract: the script must return a table; it returned a %s",
                            luaL_typename(state, -1));
        lua_settop(state, 0);
        return 0;
    }
    if (!validate_module(state, script, lua_gettop(state))) {
        lua_settop(state, 0);
        return 0;
    }
    lua_rawsetp(state, LUA_REGISTRYINDEX, &module_registry_key);
    script->has_module = 1;
    return 0;
}

static int init_runner(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    lua_rawgetp(state, LUA_REGISTRYINDEX, &module_registry_key);
    lua_getfield(state, -1, "init");
    lua_remove(state, -2);
    int status = lua_pcall(state, 0, 1, 0);
    if (status != LUA_OK) {
        if (script->failure == SCRIPT_FAILURE_NONE) {
            script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_RUNTIME;
        }
        diagnostic_from_stack(script, state, "init");
        lua_settop(state, 0);
        return 0;
    }
    if (!lua_istable(state, -1)) {
        diagnostic_contract(script, "contract: init must return a table; it returned a %s",
                            luaL_typename(state, -1));
        lua_settop(state, 0);
        return 0;
    }
    if (!validate_state_root(state, script)) {
        lua_settop(state, 0);
        return 0;
    }
    lua_rawsetp(state, LUA_REGISTRYINDEX, &state_registry_key);
    script->has_state = 1;
    return 0;
}

static int update_runner(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    lua_rawgetp(state, LUA_REGISTRYINDEX, &module_registry_key);
    lua_getfield(state, -1, "update");
    lua_remove(state, -2);
    lua_rawgetp(state, LUA_REGISTRYINDEX, &state_registry_key);
    /* The step, and nothing else: no clock, no frame delta, no interpolation alpha (§9). */
    lua_createtable(state, 0, 2);
    lua_pushinteger(state, (lua_Integer)script->step.tick);
    lua_setfield(state, -2, "tick");
    lua_pushinteger(state, (lua_Integer)script->step.delta_ns);
    lua_setfield(state, -2, "delta_ns");
    int status = lua_pcall(state, 2, 0, 0);
    if (status != LUA_OK) {
        if (script->failure == SCRIPT_FAILURE_NONE) {
            script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_RUNTIME;
        }
        diagnostic_from_stack(script, state, "update");
        lua_settop(state, 0);
    }
    return 0;
}

FoundryScriptStatus foundry_script_load_module(FoundryScript *script, const uint8_t *source,
                                               size_t source_len, const char *chunk_name) {
    if (script == NULL || script->state == NULL || source == NULL || chunk_name == NULL ||
        source_len == 0 || source_len > FOUNDRY_SCRIPT_MAX_SOURCE ||
        memchr(source, '\0', source_len) != NULL) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    size_t name_length = strlen(chunk_name);
    if (name_length == 0 || name_length > FOUNDRY_SCRIPT_MAX_CHUNK_NAME) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    if (source_len >= sizeof(LUA_SIGNATURE) - 1 &&
        memcmp(source, LUA_SIGNATURE, sizeof(LUA_SIGNATURE) - 1) == 0) {
        diagnostic_literal(script, "compile: binary chunks are not accepted");
        script->category = FOUNDRY_SCRIPT_CATEGORY_SOURCE_REJECTED;
        return FOUNDRY_SCRIPT_COMPILE_ERROR;
    }
    script->chunk_name[0] = '=';
    memcpy(script->chunk_name + 1, chunk_name, name_length);
    script->chunk_name[name_length + 1] = '\0';
    script->source = source;
    script->source_len = source_len;
    script->has_module = 0;
    script->has_state = 0;
    script->state_version = 0;
    return invoke(script, module_loader, FOUNDRY_SCRIPT_PHASE_PREPARE);
}

FoundryScriptStatus foundry_script_init_state(FoundryScript *script) {
    if (script == NULL || script->state == NULL || script->has_module == 0) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    script->has_state = 0;
    return invoke(script, init_runner, FOUNDRY_SCRIPT_PHASE_PREPARE);
}

FoundryScriptStatus foundry_script_update(FoundryScript *script, const FoundryStep *step) {
    if (script == NULL || script->state == NULL || step == NULL ||
        script->has_module == 0 || script->has_state == 0 ||
        step->tick > (uint64_t)INT64_MAX || step->delta_ns > (uint64_t)INT64_MAX) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    script->step = *step;
    return invoke(script, update_runner, FOUNDRY_SCRIPT_PHASE_UPDATE);
}

uint32_t foundry_script_state_version(const FoundryScript *script) {
    return script == NULL ? 0 : script->state_version;
}

/* -- State as bytes: what crosses between two VMs (scripting.md §11, §12) ---------------
 *
 * Two VMs share no heap, so a replacement cannot be handed a Lua value: the state is written
 * out as a bounded tagged tree and read back into the new VM. It carries no version and no
 * header because it never leaves the process and is never a save format — `docs/design/
 * scripting.md` §15 keeps durable script saves an open question, and this is not it.
 *
 * The walk is also the check. It reads the live table directly, invoking no script code and
 * no metamethod, and refuses everything §11 says cannot persist — which is how state an
 * `update` has corrupted since `init` validated it gets caught, at the moment it matters.
 */

enum {
    SNAP_FALSE = 1,
    SNAP_TRUE,
    SNAP_INT,
    SNAP_NUMBER,
    SNAP_STRING,
    SNAP_TABLE,
    SNAP_VALUE,
};

/* A NULL `out` measures instead of writing, which is how the caller sizes its buffer. */
static void snapshot_put(FoundryScript *script, const void *bytes, size_t length) {
    ScriptSnapshot *snap = &script->snapshot;
    if (snap->out != NULL) {
        if (length > snap->capacity - snap->length) {
            snap->overflow = 1;
            return;
        }
        memcpy(snap->out + snap->length, bytes, length);
    }
    snap->length += length;
}

static void snapshot_put_u8(FoundryScript *script, uint8_t value) {
    snapshot_put(script, &value, 1);
}

/* Written a byte at a time, little end first: the tree is read back by the same code on the
 * same machine, but a width or an endianness assumption spelled out costs nothing. */
static void snapshot_put_u32(FoundryScript *script, uint32_t value) {
    uint8_t bytes[4];
    for (size_t i = 0; i < sizeof(bytes); ++i) {
        bytes[i] = (uint8_t)(value >> (8 * i));
    }
    snapshot_put(script, bytes, sizeof(bytes));
}

static void snapshot_put_u64(FoundryScript *script, uint64_t value) {
    uint8_t bytes[8];
    for (size_t i = 0; i < sizeof(bytes); ++i) {
        bytes[i] = (uint8_t)(value >> (8 * i));
    }
    snapshot_put(script, bytes, sizeof(bytes));
}

static int snapshot_take(FoundryScript *script, void *out, size_t length) {
    ScriptSnapshot *snap = &script->snapshot;
    if (snap->in == NULL || length > snap->length - snap->cursor) {
        return 0;
    }
    memcpy(out, snap->in + snap->cursor, length);
    snap->cursor += length;
    return 1;
}

static int snapshot_take_u32(FoundryScript *script, uint32_t *out) {
    uint8_t bytes[4];
    uint32_t value = 0;
    if (!snapshot_take(script, bytes, sizeof(bytes))) {
        return 0;
    }
    for (size_t i = sizeof(bytes); i > 0; --i) {
        value = (value << 8) | bytes[i - 1];
    }
    *out = value;
    return 1;
}

static int snapshot_take_u64(FoundryScript *script, uint64_t *out) {
    uint8_t bytes[8];
    uint64_t value = 0;
    if (!snapshot_take(script, bytes, sizeof(bytes))) {
        return 0;
    }
    for (size_t i = sizeof(bytes); i > 0; --i) {
        value = (value << 8) | bytes[i - 1];
    }
    *out = value;
    return 1;
}

static int snapshot_truncated(FoundryScript *script) {
    diagnostic_migration(script, "migration: the carried state ends in the middle of a value");
    return 0;
}

static int snapshot_table(lua_State *state, FoundryScript *script, int index,
                          uint32_t depth, StateWalk *walk);

/* Encodes one value, accounting for it exactly as `validate_state_value` does, so the two
 * walks agree about what fits. */
static int snapshot_value(lua_State *state, FoundryScript *script, int index,
                          uint32_t depth, StateWalk *walk) {
    switch (lua_type(state, index)) {
        case LUA_TBOOLEAN:
            snapshot_put_u8(script, lua_toboolean(state, index) ? SNAP_TRUE : SNAP_FALSE);
            walk->bytes += 8;
            break;
        case LUA_TNUMBER:
            if (lua_isinteger(state, index)) {
                snapshot_put_u8(script, SNAP_INT);
                snapshot_put_u64(script, (uint64_t)lua_tointeger(state, index));
            } else {
                double number = (double)lua_tonumber(state, index);
                uint64_t word = 0;
                if (!isfinite(number)) {
                    diagnostic_contract(script, "contract: state holds a number that is not finite");
                    return 0;
                }
                memcpy(&word, &number, sizeof(number) < sizeof(word) ? sizeof(number) : sizeof(word));
                snapshot_put_u8(script, SNAP_NUMBER);
                snapshot_put_u64(script, word);
            }
            walk->bytes += 8;
            break;
        case LUA_TSTRING: {
            size_t length = 0;
            const char *text = lua_tolstring(state, index, &length);
            if (length > FOUNDRY_SCRIPT_MAX_STRING) {
                diagnostic_contract(script, "contract: state holds a string longer than %u bytes",
                                    (unsigned)FOUNDRY_SCRIPT_MAX_STRING);
                return 0;
            }
            snapshot_put_u8(script, SNAP_STRING);
            snapshot_put_u32(script, (uint32_t)length);
            snapshot_put(script, text, length);
            walk->bytes += length;
            break;
        }
        case LUA_TTABLE:
            return snapshot_table(state, script, index, depth, walk);
        case LUA_TUSERDATA: {
            uint8_t tag = 0;
            uint64_t bits = 0, extra = 0;
            if (!foundry_script_read_persisted(state, index, script, &tag, &bits, &extra)) {
                diagnostic_contract(script,
                                    "contract: state holds a value that cannot outlive this "
                                    "invocation; records, cursors, packages and component "
                                    "types must be found again");
                return 0;
            }
            snapshot_put_u8(script, SNAP_VALUE);
            snapshot_put_u8(script, tag);
            snapshot_put_u64(script, bits);
            snapshot_put_u64(script, extra);
            walk->bytes += 32;
            break;
        }
        default:
            diagnostic_contract(script, "contract: state holds a %s, which cannot persist",
                                luaL_typename(state, index));
            return 0;
    }
    if (walk->bytes > FOUNDRY_SCRIPT_MAX_STATE_BYTES) {
        diagnostic_contract(script, "contract: state is larger than %u bytes",
                            (unsigned)FOUNDRY_SCRIPT_MAX_STATE_BYTES);
        return 0;
    }
    return 1;
}

/* Keys in §9's order — integers ascending, then strings by unsigned byte order — because two
 * runs of the same simulation must produce the same bytes (I9). */
static int snapshot_table(lua_State *state, FoundryScript *script, int index,
                          uint32_t depth, StateWalk *walk) {
    size_t count = 0, filled = 0, i;
    PairKey *keys;

    if (depth > FOUNDRY_SCRIPT_MAX_STATE_DEPTH) {
        diagnostic_contract(script, "contract: state nests deeper than %u tables",
                            (unsigned)FOUNDRY_SCRIPT_MAX_STATE_DEPTH);
        return 0;
    }
    if (!lua_checkstack(state, 8)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "snapshot: stack limit exceeded");
        return 0;
    }

    /* One walk, one visit. A cycle and a table stored in two places fail the same check,
     * because the tree written here preserves neither (§11) — and an `update` is free to
     * have introduced either since `init` was validated, so this is checked every time. */
    lua_pushvalue(state, index);
    lua_rawget(state, walk->seen);
    if (!lua_isnil(state, -1)) {
        lua_pop(state, 1);
        diagnostic_contract(script, "contract: state holds the same table twice, or a cycle");
        return 0;
    }
    lua_pop(state, 1);
    lua_pushvalue(state, index);
    lua_pushboolean(state, 1);
    lua_rawset(state, walk->seen);

    lua_pushnil(state);
    while (lua_next(state, index) != 0) {
        int key_type;
        lua_pop(state, 1);
        key_type = lua_type(state, -1);
        if (key_type != LUA_TSTRING && !(key_type == LUA_TNUMBER && lua_isinteger(state, -1))) {
            diagnostic_contract(script, "contract: state is keyed by a %s; only integers and strings persist",
                                luaL_typename(state, -1));
            lua_pop(state, 1);
            return 0;
        }
        count += 1;
        if (count > FOUNDRY_SCRIPT_MAX_STATE_ENTRIES) {
            diagnostic_contract(script, "contract: state holds more than %u entries",
                                (unsigned)FOUNDRY_SCRIPT_MAX_STATE_ENTRIES);
            lua_pop(state, 2);
            return 0;
        }
    }
    walk->entries += (uint32_t)count;
    if (walk->entries > FOUNDRY_SCRIPT_MAX_STATE_ENTRIES) {
        diagnostic_contract(script, "contract: state holds more than %u entries",
                            (unsigned)FOUNDRY_SCRIPT_MAX_STATE_ENTRIES);
        return 0;
    }

    keys = (PairKey *)lua_newuserdatauv(state, (count == 0 ? 1 : count) * sizeof(PairKey), 0);
    lua_pushnil(state);
    while (lua_next(state, index) != 0) {
        lua_pop(state, 1);
        if (lua_type(state, -1) == LUA_TSTRING) {
            keys[filled].is_string = 1;
            keys[filled].integer = 0;
            keys[filled].text = lua_tolstring(state, -1, &keys[filled].length);
        } else {
            keys[filled].is_string = 0;
            keys[filled].integer = lua_tointeger(state, -1);
            keys[filled].text = NULL;
            keys[filled].length = 0;
        }
        filled += 1;
    }
    qsort(keys, count, sizeof(PairKey), compare_keys);

    snapshot_put_u8(script, SNAP_TABLE);
    snapshot_put_u32(script, (uint32_t)count);
    for (i = 0; i < count; ++i) {
        if (keys[i].is_string) {
            if (keys[i].length > FOUNDRY_SCRIPT_MAX_STRING) {
                diagnostic_contract(script, "contract: state holds a key longer than %u bytes",
                                    (unsigned)FOUNDRY_SCRIPT_MAX_STRING);
                return 0;
            }
            snapshot_put_u8(script, SNAP_STRING);
            snapshot_put_u32(script, (uint32_t)keys[i].length);
            snapshot_put(script, keys[i].text, keys[i].length);
            walk->bytes += keys[i].length;
            lua_pushlstring(state, keys[i].text, keys[i].length);
        } else {
            snapshot_put_u8(script, SNAP_INT);
            snapshot_put_u64(script, (uint64_t)keys[i].integer);
            lua_pushinteger(state, keys[i].integer);
        }
        if (walk->bytes > FOUNDRY_SCRIPT_MAX_STATE_BYTES) {
            diagnostic_contract(script, "contract: state is larger than %u bytes",
                                (unsigned)FOUNDRY_SCRIPT_MAX_STATE_BYTES);
            lua_pop(state, 1);
            return 0;
        }
        lua_rawget(state, index);
        if (!snapshot_value(state, script, lua_gettop(state), depth + 1, walk)) {
            lua_pop(state, 1);
            return 0;
        }
        lua_pop(state, 1);
    }
    lua_pop(state, 1);
    return 1;
}

static int restore_value(lua_State *state, FoundryScript *script, uint32_t depth, StateWalk *walk);

static int restore_table(lua_State *state, FoundryScript *script, uint32_t depth, StateWalk *walk) {
    uint32_t count = 0, i;
    if (depth > FOUNDRY_SCRIPT_MAX_STATE_DEPTH) {
        diagnostic_migration(script, "migration: the carried state nests deeper than %u tables",
                             (unsigned)FOUNDRY_SCRIPT_MAX_STATE_DEPTH);
        return 0;
    }
    if (!snapshot_take_u32(script, &count)) {
        return snapshot_truncated(script);
    }
    if (count > FOUNDRY_SCRIPT_MAX_STATE_ENTRIES ||
        walk->entries > FOUNDRY_SCRIPT_MAX_STATE_ENTRIES - count) {
        diagnostic_migration(script, "migration: the carried state holds more than %u entries",
                             (unsigned)FOUNDRY_SCRIPT_MAX_STATE_ENTRIES);
        return 0;
    }
    walk->entries += count;
    if (!lua_checkstack(state, 8)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "migrate: stack limit exceeded");
        return 0;
    }
    lua_createtable(state, 0, (int)count);
    for (i = 0; i < count; ++i) {
        if (!restore_value(state, script, depth + 1, walk)) {
            lua_pop(state, 1);
            return 0;
        }
        if (lua_type(state, -1) != LUA_TSTRING && !lua_isinteger(state, -1)) {
            diagnostic_migration(script, "migration: the carried state is keyed by a %s",
                                 luaL_typename(state, -1));
            lua_pop(state, 2);
            return 0;
        }
        if (!restore_value(state, script, depth + 1, walk)) {
            lua_pop(state, 2);
            return 0;
        }
        lua_rawset(state, -3);
    }
    return 1;
}

static int restore_value(lua_State *state, FoundryScript *script, uint32_t depth, StateWalk *walk) {
    uint8_t tag = 0;
    if (!snapshot_take(script, &tag, 1)) {
        return snapshot_truncated(script);
    }
    switch (tag) {
        case SNAP_FALSE:
            lua_pushboolean(state, 0);
            break;
        case SNAP_TRUE:
            lua_pushboolean(state, 1);
            break;
        case SNAP_INT: {
            uint64_t word = 0;
            if (!snapshot_take_u64(script, &word)) {
                return snapshot_truncated(script);
            }
            lua_pushinteger(state, (lua_Integer)word);
            break;
        }
        case SNAP_NUMBER: {
            uint64_t word = 0;
            double number = 0;
            if (!snapshot_take_u64(script, &word)) {
                return snapshot_truncated(script);
            }
            memcpy(&number, &word, sizeof(number) < sizeof(word) ? sizeof(number) : sizeof(word));
            if (!isfinite(number)) {
                diagnostic_migration(script, "migration: the carried state holds a number that is not finite");
                return 0;
            }
            lua_pushnumber(state, (lua_Number)number);
            break;
        }
        case SNAP_STRING: {
            uint32_t length = 0;
            ScriptSnapshot *snap = &script->snapshot;
            if (!snapshot_take_u32(script, &length)) {
                return snapshot_truncated(script);
            }
            if (length > FOUNDRY_SCRIPT_MAX_STRING || length > snap->length - snap->cursor) {
                return snapshot_truncated(script);
            }
            lua_pushlstring(state, (const char *)snap->in + snap->cursor, length);
            snap->cursor += length;
            break;
        }
        case SNAP_TABLE:
            return restore_table(state, script, depth, walk);
        case SNAP_VALUE: {
            uint8_t kind = 0;
            uint64_t bits = 0, extra = 0;
            if (!snapshot_take(script, &kind, 1) || !snapshot_take_u64(script, &bits) ||
                !snapshot_take_u64(script, &extra)) {
                return snapshot_truncated(script);
            }
            /* The ledger is the stable slot's and has not changed, so an entity that was
             * owned when it was written is owned now. One that is not is refused rather
             * than rewrapped: state is not how a package claims an entity (§11). */
            if (!foundry_script_push_persisted(state, script, kind, bits, extra)) {
                diagnostic_migration(script,
                                     "migration: the carried state names an entity this package does not own");
                return 0;
            }
            break;
        }
        default:
            diagnostic_migration(script, "migration: the carried state holds an unknown value");
            return 0;
    }
    return 1;
}

/* -- The three reload entry points ----------------------------------------------------- */

static int snapshot_runner(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    StateWalk walk;
    int root, ok;
    if (!lua_checkstack(state, 8)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "snapshot: stack limit exceeded");
        return 0;
    }
    lua_rawgetp(state, LUA_REGISTRYINDEX, &state_registry_key);
    if (!lua_istable(state, -1)) {
        diagnostic_contract(script, "contract: this script has no state to carry across");
        lua_settop(state, 0);
        return 0;
    }
    root = lua_gettop(state);
    lua_newtable(state);
    walk.entries = 0;
    walk.bytes = 0;
    walk.seen = lua_gettop(state);
    ok = snapshot_table(state, script, root, 1, &walk);
    lua_settop(state, 0);
    if (ok && script->snapshot.overflow) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "snapshot: the state did not fit the buffer it was given");
    }
    return 0;
}

static int restore_runner(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    StateWalk walk;
    walk.entries = 0;
    walk.bytes = 0;
    walk.seen = 0;
    if (!lua_checkstack(state, 8)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "restore: stack limit exceeded");
        return 0;
    }
    if (!restore_value(state, script, 1, &walk)) {
        lua_settop(state, 0);
        return 0;
    }
    if (!lua_istable(state, -1) || script->snapshot.cursor != script->snapshot.length) {
        diagnostic_migration(script, "migration: the carried state is not a readable table");
        lua_settop(state, 0);
        return 0;
    }
    /* Validated on the way in as well as on the way out. The decoder's job is reading and
     * the validator's is §11's policy; keeping the policy in one place is worth one more
     * bounded walk over a table that holds at most a thousand entries. */
    if (!validate_state_root(state, script)) {
        lua_settop(state, 0);
        return 0;
    }
    lua_rawsetp(state, LUA_REGISTRYINDEX, &state_registry_key);
    script->has_state = 1;
    return 0;
}

static int migrate_runner(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    StateWalk walk;
    int status;
    walk.entries = 0;
    walk.bytes = 0;
    walk.seen = 0;
    if (!lua_checkstack(state, 8)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "migrate: stack limit exceeded");
        return 0;
    }
    lua_rawgetp(state, LUA_REGISTRYINDEX, &module_registry_key);
    if (lua_getfield(state, -1, "migrate") != LUA_TFUNCTION) {
        /* §12: a version change without a migration refuses the replacement. There is no
         * implicit reset, because the world the old state describes is still there. */
        diagnostic_migration(script,
                             "migration: state_version went from %u to %u and this module has no migrate",
                             (unsigned)script->migrate_from, (unsigned)script->state_version);
        lua_settop(state, 0);
        return 0;
    }
    lua_remove(state, -2);
    if (!restore_value(state, script, 1, &walk)) {
        lua_settop(state, 0);
        return 0;
    }
    if (!lua_istable(state, -1) || script->snapshot.cursor != script->snapshot.length) {
        diagnostic_migration(script, "migration: the carried state is not a readable table");
        lua_settop(state, 0);
        return 0;
    }
    lua_pushinteger(state, (lua_Integer)script->migrate_from);
    status = lua_pcall(state, 2, 1, 0);
    if (status != LUA_OK) {
        if (script->failure == SCRIPT_FAILURE_NONE) {
            script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_RUNTIME;
        }
        diagnostic_from_stack(script, state, "migrate");
        /* A migrate that simply failed is a migration failure; a budget it exhausted is
         * more useful named as the budget. */
        if (script->category == FOUNDRY_SCRIPT_CATEGORY_RUNTIME) {
            script->category = FOUNDRY_SCRIPT_CATEGORY_MIGRATION;
        }
        lua_settop(state, 0);
        return 0;
    }
    if (!lua_istable(state, -1)) {
        diagnostic_migration(script, "migration: migrate must return a table; it returned a %s",
                             luaL_typename(state, -1));
        lua_settop(state, 0);
        return 0;
    }
    if (!validate_state_root(state, script)) {
        script->category = FOUNDRY_SCRIPT_CATEGORY_MIGRATION;
        lua_settop(state, 0);
        return 0;
    }
    lua_rawsetp(state, LUA_REGISTRYINDEX, &state_registry_key);
    script->has_state = 1;
    return 0;
}

FoundryScriptStatus foundry_script_snapshot_state(FoundryScript *script, uint8_t *buffer,
                                                  size_t capacity, size_t *needed) {
    FoundryScriptStatus status;
    if (script == NULL || script->state == NULL || needed == NULL ||
        script->has_module == 0 || script->has_state == 0 ||
        (buffer == NULL && capacity != 0) || capacity > FOUNDRY_SCRIPT_MAX_SNAPSHOT) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    script->snapshot.out = buffer;
    script->snapshot.in = NULL;
    script->snapshot.capacity = buffer == NULL ? 0 : capacity;
    script->snapshot.length = 0;
    script->snapshot.cursor = 0;
    script->snapshot.overflow = 0;
    status = invoke(script, snapshot_runner, FOUNDRY_SCRIPT_PHASE_PREPARE);
    /* Written whatever happened, exactly as the ABI's own sizing probe does: a caller that
     * asked how big the state is gets the answer even when the copy did not fit. */
    *needed = script->snapshot.length;
    script->snapshot.out = NULL;
    script->snapshot.capacity = 0;
    return status;
}

static FoundryScriptStatus read_snapshot(FoundryScript *script, lua_CFunction runner,
                                         const uint8_t *snapshot, size_t length) {
    FoundryScriptStatus status;
    script->snapshot.out = NULL;
    script->snapshot.in = snapshot;
    script->snapshot.capacity = 0;
    script->snapshot.length = length;
    script->snapshot.cursor = 0;
    script->snapshot.overflow = 0;
    script->has_state = 0;
    status = invoke(script, runner, FOUNDRY_SCRIPT_PHASE_PREPARE);
    script->snapshot.in = NULL;
    script->snapshot.length = 0;
    script->snapshot.cursor = 0;
    return status;
}

FoundryScriptStatus foundry_script_restore_state(FoundryScript *script,
                                                 const uint8_t *snapshot, size_t length) {
    if (script == NULL || script->state == NULL || snapshot == NULL || length == 0 ||
        length > FOUNDRY_SCRIPT_MAX_SNAPSHOT || script->has_module == 0) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    return read_snapshot(script, restore_runner, snapshot, length);
}

FoundryScriptStatus foundry_script_migrate_state(FoundryScript *script,
                                                 const uint8_t *snapshot, size_t length,
                                                 uint32_t old_version) {
    if (script == NULL || script->state == NULL || snapshot == NULL || length == 0 ||
        length > FOUNDRY_SCRIPT_MAX_SNAPSHOT || script->has_module == 0 || old_version == 0) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    script->migrate_from = old_version;
    return read_snapshot(script, migrate_runner, snapshot, length);
}

FoundryScriptStatus foundry_script_teardown(FoundryScript *script) {
    if (script == NULL || script->state == NULL) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    if (script->inject_teardown_failure != 0) {
        diagnostic_literal(script, "teardown: injected failure");
        return FOUNDRY_SCRIPT_TEARDOWN_ERROR;
    }
    lua_close(script->state);
    script->state = NULL;
    return FOUNDRY_SCRIPT_OK;
}

void foundry_script_destroy(FoundryScript *script) {
    if (script == NULL) {
        return;
    }
    if (script->state != NULL) {
        lua_close(script->state);
    }
    script->allocator(script->allocator_userdata, script, sizeof(*script), 0);
}

void foundry_script_fail_next_allocation(FoundryScript *script) {
    if (script != NULL) {
        script->fail_after_allocations = script->allocation_count;
    }
}

void foundry_script_clear_allocation_failure(FoundryScript *script) {
    if (script != NULL) {
        script->fail_after_allocations = FOUNDRY_SCRIPT_NEVER_FAIL;
    }
}

void foundry_script_inject_result_failure(FoundryScript *script, uint8_t enabled) {
    if (script != NULL) {
        script->inject_result_failure = enabled;
    }
}

void foundry_script_inject_compile_failure(FoundryScript *script, uint8_t enabled) {
    if (script != NULL) {
        script->inject_compile_failure = enabled;
    }
}

const char *foundry_script_diagnostic(const FoundryScript *script, size_t *length) {
    if (length != NULL) {
        *length = script == NULL ? 0 : script->diagnostic_length;
    }
    return script == NULL ? "" : script->diagnostic;
}

FoundryScriptCategory foundry_script_category(const FoundryScript *script) {
    return script == NULL ? FOUNDRY_SCRIPT_CATEGORY_NONE : script->category;
}

uint32_t foundry_script_error_line(const FoundryScript *script) {
    return script == NULL ? 0 : script->error_line;
}

uint32_t foundry_script_abi_calls(const FoundryScript *script) {
    return script == NULL ? 0 : script->abi_calls;
}
