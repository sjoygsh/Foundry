#include "foundry_script.h"

#include "lauxlib.h"
#include "lua.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if LUA_INT_TYPE != LUA_INT_LONGLONG || LUA_FLOAT_TYPE != LUA_FLOAT_DOUBLE
#error "Foundry scripting requires Lua's default 64-bit integer and double configuration"
#endif

typedef char foundry_lua_integer_must_be_64_bit[(sizeof(lua_Integer) == 8) ? 1 : -1];
typedef char foundry_lua_number_must_be_double[(sizeof(lua_Number) == sizeof(double)) ? 1 : -1];

#define FOUNDRY_SCRIPT_DIAGNOSTIC_CAPACITY 4096u
#define FOUNDRY_SCRIPT_MAX_SOURCE (256u * 1024u)

typedef enum ScriptFailure {
    SCRIPT_FAILURE_NONE = 0,
    SCRIPT_FAILURE_COMPILE,
    SCRIPT_FAILURE_RUNTIME,
    SCRIPT_FAILURE_INSTRUCTION,
    SCRIPT_FAILURE_MEMORY,
    SCRIPT_FAILURE_RESULT,
} ScriptFailure;

struct FoundryScript {
    lua_State *state;
    FoundryScriptAllocator allocator;
    void *allocator_userdata;
    size_t heap_limit;
    size_t heap_used;
    size_t heap_peak;
    size_t allocation_count;
    size_t fail_after_allocations;
    uint64_t instruction_limit;
    uint64_t instructions;
    uint32_t hook_period;
    uint8_t inject_teardown_failure;
    uint8_t inject_result_failure;
    uint8_t inject_compile_failure;
    ScriptFailure failure;
    const uint8_t *source;
    size_t source_len;
    int64_t result;
    int result_is_integer;
    size_t diagnostic_length;
    char diagnostic[FOUNDRY_SCRIPT_DIAGNOSTIC_CAPACITY];
};

static int script_runner(lua_State *state);

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

static void *quota_allocator(void *userdata, void *pointer, size_t old_size,
                             size_t new_size) {
    FoundryScript *script = (FoundryScript *)userdata;
    size_t accounted_old_size = pointer == NULL ? 0 : old_size;

    if (new_size == 0) {
        script->allocator(script->allocator_userdata, pointer, old_size, 0);
        if (accounted_old_size >= script->heap_used) {
            script->heap_used = 0;
        } else {
            script->heap_used -= accounted_old_size;
        }
        return NULL;
    }

    if (script->fail_after_allocations != FOUNDRY_SCRIPT_NEVER_FAIL &&
        script->allocation_count >= script->fail_after_allocations) {
        return NULL;
    }

    size_t base = script->heap_used;
    if (accounted_old_size >= base) {
        base = 0;
    } else {
        base -= accounted_old_size;
    }
    size_t available = base < script->heap_limit ? script->heap_limit - base : 0;
    if (new_size > available) {
        return NULL;
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
    return next;
}

static FoundryScript *script_from_state(lua_State *state) {
    FoundryScript *script = NULL;
    memcpy(&script, lua_getextraspace(state), sizeof(script));
    return script;
}

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
    lua_pushstring(state, luaL_typename(state, 1));
    return 1;
}

static int base_tonumber(lua_State *state) {
    int is_number = 0;
    lua_Number number = lua_tonumberx(state, 1, &is_number);
    if (!is_number) {
        return 0;
    }
    lua_pushnumber(state, number);
    return 1;
}

static int base_tostring(lua_State *state) {
    if (lua_type(state, 1) == LUA_TSTRING) {
        lua_pushvalue(state, 1);
        return 1;
    }
    if (lua_isnil(state, 1)) {
        lua_pushliteral(state, "nil");
        return 1;
    }
    if (lua_isboolean(state, 1)) {
        lua_pushstring(state, lua_toboolean(state, 1) ? "true" : "false");
        return 1;
    }
    if (lua_isnumber(state, 1)) {
        lua_pushfstring(state, "%.17g", lua_tonumber(state, 1));
        return 1;
    }
    return luaL_error(state, "tostring is not available for this value");
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

static void install_environment(lua_State *state) {
    lua_pushcfunction(state, base_assert);
    lua_setglobal(state, "assert");
    lua_pushcfunction(state, base_error);
    lua_setglobal(state, "error");
    lua_pushcfunction(state, base_type);
    lua_setglobal(state, "type");
    lua_pushcfunction(state, base_tonumber);
    lua_setglobal(state, "tonumber");
    lua_pushcfunction(state, base_tostring);
    lua_setglobal(state, "tostring");
    lua_pushcfunction(state, base_ipairs);
    lua_setglobal(state, "ipairs");
}

static void script_hook(lua_State *state, lua_Debug *debug) {
    (void)debug;
    FoundryScript *script = script_from_state(state);
    if (script->instructions > script->instruction_limit - script->hook_period) {
        script->failure = SCRIPT_FAILURE_INSTRUCTION;
        luaL_error(state, "instruction limit exceeded");
    }
    script->instructions += script->hook_period;
}

static int bootstrap_function(lua_State *state) {
    FoundryScript *script = script_from_state(state);
    install_environment(state);
    (void)script;
    return 0;
}

static int script_runner(lua_State *state) {
    FoundryScript *script = script_from_state(state);
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
        if (script->failure == SCRIPT_FAILURE_INSTRUCTION) {
            diagnostic_from_stack(script, state, "execute");
        } else {
            script->failure = status == LUA_ERRMEM ? SCRIPT_FAILURE_MEMORY : SCRIPT_FAILURE_RUNTIME;
            diagnostic_from_stack(script, state, "execute");
        }
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
    FoundryScript *script = script_from_state(state);
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
    }
    return FOUNDRY_SCRIPT_RUNTIME_ERROR;
}

FoundryScriptStatus foundry_script_create(FoundryScript **out,
                                          const FoundryScriptConfig *config) {
    if (out == NULL || config == NULL || config->heap_limit == 0 ||
        config->instruction_limit == 0 || config->hook_period == 0 ||
        config->hook_period > config->instruction_limit ||
        config->hook_period > (uint32_t)INT_MAX || config->allocator == NULL) {
        return FOUNDRY_SCRIPT_INVALID_ARGUMENT;
    }
    *out = NULL;

    FoundryScript *script = (FoundryScript *)config->allocator(
        config->allocator_userdata, NULL, 0, sizeof(*script));
    if (script == NULL) {
        return FOUNDRY_SCRIPT_BOOTSTRAP_ERROR;
    }
    memset(script, 0, sizeof(*script));
    script->allocator = config->allocator;
    script->allocator_userdata = config->allocator_userdata;
    script->heap_limit = config->heap_limit;
    script->fail_after_allocations = config->fail_after_allocations;
    script->instruction_limit = config->instruction_limit;
    script->hook_period = config->hook_period;
    script->inject_teardown_failure = config->inject_teardown_failure;
    script->inject_result_failure = config->inject_result_failure;
    script->inject_compile_failure = config->inject_compile_failure;
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
                                           FoundryScriptResult *result) {
    if (script == NULL || script->state == NULL || source == NULL || result == NULL ||
        source_len == 0 || source_len > FOUNDRY_SCRIPT_MAX_SOURCE ||
        memchr(source, '\0', source_len) != NULL) {
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
    script->result_is_integer = 0;
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
