#include "bridge_private.h"

#include "lauxlib.h"

#include <limits.h>
#include <math.h>
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

static void diagnostic_from_stack(FoundryScript *script, lua_State *state,
                                  const char *phase) {
    const char *message = NULL;
    size_t message_length = 0;
    if (lua_gettop(state) > 0 && lua_type(state, -1) == LUA_TSTRING) {
        message = lua_tolstring(state, -1, &message_length);
    }
    if (message == NULL) {
        const char *type = luaL_typename(state, -1);
        int written = snprintf(script->diagnostic, sizeof(script->diagnostic),
                               "%s: lua error (%s)", phase, type);
        if (written >= 0 && (size_t)written < sizeof(script->diagnostic)) {
            script->diagnostic_length = (size_t)written;
        } else {
            diagnostic_literal(script, phase);
        }
        return;
    }

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
    if (script->instructions > script->instruction_limit - script->hook_period) {
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
                                  script->source_len, "foundry-script", "t");
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

static int execute_function(lua_State *state) {
    FoundryScript *script = foundry_script_from_state(state);
    if (!lua_checkstack(state, LUA_MINSTACK)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
        diagnostic_literal(script, "invoke: stack limit exceeded");
        return 0;
    }
    lua_pushcfunction(state, script_runner);
    int status = lua_pcall(state, 0, 0, 0);
    if (status != LUA_OK) {
        script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_RUNTIME;
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
        config->hook_period > (uint32_t)INT_MAX || config->allocator == NULL) {
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
    script->hook_period = config->hook_period;
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
    script->instructions = 0;
    script->failure = SCRIPT_FAILURE_NONE;
    script->terminal = 0;
    script->result_is_integer = 0;
    /* A new invocation: fresh per-invocation budgets, and every record or cursor from the
     * last one is now stale. */
    script->phase = phase;
    script->invocation += 1;
    script->abi_calls = 0;
    script->spawns = 0;
    script->logs = 0;
    diagnostic_literal(script, "");
    lua_settop(script->state, 0);

    if (!lua_checkstack(script->state, LUA_MINSTACK)) {
        script->failure = SCRIPT_FAILURE_MEMORY;
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
    FoundryScriptStatus result_status = status_from_failure(script->failure);
    if (result_status != FOUNDRY_SCRIPT_OK) {
        return result_status;
    }
    if (!script->result_is_integer) {
        diagnostic_literal(script, "result: missing integer");
        return FOUNDRY_SCRIPT_RESULT_ERROR;
    }
    result->integer = script->result;
    return FOUNDRY_SCRIPT_OK;
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

uint32_t foundry_script_abi_calls(const FoundryScript *script) {
    return script == NULL ? 0 : script->abi_calls;
}
