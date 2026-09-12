#ifndef FOUNDRY_SCRIPT_BRIDGE_PRIVATE_H
#define FOUNDRY_SCRIPT_BRIDGE_PRIVATE_H

/* Shared between `bridge.c` (the VM) and `binding.c` (the `foundry` module). Lua types
 * appear only under `engine/src/script/` (scripting.md §3). */

#include "foundry_script.h"

#include "lua.h"

#define FOUNDRY_SCRIPT_DIAGNOSTIC_CAPACITY 4096u
#define FOUNDRY_SCRIPT_MAX_SOURCE (256u * 1024u)
/* The longest string a binding copies in or out (scripting.md §8). */
#define FOUNDRY_SCRIPT_MAX_STRING (16u * 1024u)
#define FOUNDRY_SCRIPT_TEMPLATE_CACHE 8u

typedef enum ScriptFailure {
    SCRIPT_FAILURE_NONE = 0,
    SCRIPT_FAILURE_COMPILE,
    SCRIPT_FAILURE_RUNTIME,
    SCRIPT_FAILURE_INSTRUCTION,
    SCRIPT_FAILURE_MEMORY,
    SCRIPT_FAILURE_RESULT,
    SCRIPT_FAILURE_NATIVE_WORK,
} ScriptFailure;

/* A template that passed preflight, for as long as content has not changed under it.
 * Component types are registered at startup only, so the content generation is the whole
 * of what can invalidate the answer. */
typedef struct TemplateCacheEntry {
    uint64_t id;
    uint64_t generation;
    uint8_t valid;
} TemplateCacheEntry;

/* The bounded value tree one VM's state crosses to the next in (scripting.md §11), and where
 * the running invocation has got to in it. Exactly one direction is in flight at a time:
 * `out` writes — NULL measures instead — and `in` reads. The buffer is the caller's. */
typedef struct ScriptSnapshot {
    uint8_t *out;
    const uint8_t *in;
    size_t capacity;
    /* Bytes written so far, or the input's length. */
    size_t length;
    /* Read position within `in`. */
    size_t cursor;
    uint8_t overflow;
} ScriptSnapshot;

struct FoundryScript {
    lua_State *state;
    FoundryScriptAllocator allocator;
    void *allocator_userdata;
    FoundryScriptBudget *budget;
    size_t heap_limit;
    size_t heap_used;
    size_t heap_peak;
    size_t allocation_count;
    size_t fail_after_allocations;
    uint64_t instruction_limit;
    uint64_t prepare_instruction_limit;
    /* Whichever of the two the current invocation is spending. */
    uint64_t active_instruction_limit;
    uint64_t instructions;
    uint32_t hook_period;
    uint8_t inject_teardown_failure;
    uint8_t inject_result_failure;
    uint8_t inject_compile_failure;
    /* Set before a budget error is raised; every binding refuses work while it is set. */
    uint8_t terminal;
    ScriptFailure failure;
    const uint8_t *source;
    size_t source_len;
    int64_t result;
    int result_is_integer;

    /* -- The `foundry` module ------------------------------------------------------ */
    const FoundryApi_v2 *api;
    FoundryMod self;
    FoundryScriptLedger *ledger;
    FoundryScriptPhase phase;
    /* Bumped by every invocation. A record or cursor carries the one it was made in and is
     * refused in any other (scripting.md §7). Starts at 1, so zero means "unscoped". */
    uint64_t invocation;
    uint32_t abi_call_limit;
    uint32_t spawn_limit;
    uint32_t log_limit;
    uint32_t abi_calls;
    uint32_t spawns;
    uint32_t logs;
    uint64_t prepare_instructions_peak;
    uint64_t update_instructions_peak;
    uint32_t abi_calls_peak;
    uint32_t spawns_peak;
    uint32_t logs_peak;
    uint32_t template_cache_next;
    TemplateCacheEntry template_cache[FOUNDRY_SCRIPT_TEMPLATE_CACHE];

    /* -- The author's module (scripting.md §11) ------------------------------------ */
    /* The loaded module table and its state table live in the registry, not on the stack:
     * they outlive every invocation, and nothing a script can reach names the registry. */
    /* The inner function one protected invocation runs; see `invoke` in bridge.c. */
    lua_CFunction pending;
    uint8_t has_module;
    uint8_t has_state;
    uint32_t state_version;
    /* The step the running update was handed, copied before the invocation begins. */
    FoundryStep step;
    /* The state tree being written or read, and the version a migration is coming from. */
    ScriptSnapshot snapshot;
    uint32_t migrate_from;
    /* What a diagnostic calls this script. `=`-prefixed for Lua, so its own messages spell
     * the name literally rather than wrapping it in `[string "..."]`. */
    char chunk_name[FOUNDRY_SCRIPT_MAX_CHUNK_NAME + 2];

    FoundryScriptCategory category;
    uint32_t error_line;
    size_t diagnostic_length;
    char diagnostic[FOUNDRY_SCRIPT_DIAGNOSTIC_CAPACITY];
};

FoundryScript *foundry_script_from_state(lua_State *state);

/* Installs the `foundry` table into the global environment. Runs inside the bootstrap's
 * protected call. */
void foundry_script_open_binding(lua_State *state);

/* Whether the value at `index` is a bridge value that may live in a script's persistent
 * state and therefore survive into another VM (scripting.md §11): an id, a schema id, an
 * unsigned value, an RNG, or an entity this package still owns. A record, cursor, package
 * or component type is not, because none of them outlives the invocation that made it. */
int foundry_script_value_is_persistable(lua_State *state, int index, const FoundryScript *script);

/* Reads a persistable bridge value at `index` into the three words a snapshot stores, and
 * pushes one back in another VM. `push` re-checks ownership, so a snapshot cannot be the way
 * a package acquires an entity it does not own (scripting.md §11). Both return 0 for a value
 * that is not persistable, having pushed nothing. */
int foundry_script_read_persisted(lua_State *state, int index, const FoundryScript *script,
                                  uint8_t *tag, uint64_t *bits, uint64_t *extra);
int foundry_script_push_persisted(lua_State *state, const FoundryScript *script,
                                  uint8_t tag, uint64_t bits, uint64_t extra);

/* The shared value metatable's formatter, for the environment's scalar-only `tostring`.
 * Pushes a string and returns 1 when `index` is a bridge value, else pushes nothing and
 * returns 0. Never invokes a metamethod. */
int foundry_script_format_value(lua_State *state, int index);

#endif
