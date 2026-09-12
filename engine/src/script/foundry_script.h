#ifndef FOUNDRY_SCRIPT_H
#define FOUNDRY_SCRIPT_H

/*
 * The private contract between `script`'s Zig side and its C bridge. **Not** a public ABI:
 * nothing outside `engine/src/script/` includes this, and no mod ever sees it. The one public
 * contract a script reaches the engine through is `foundry.h`, included here for its types.
 */

#include <stddef.h>
#include <stdint.h>

#include "foundry.h"

typedef struct FoundryScript FoundryScript;

/* The bridge only uses realloc semantics. A zero new_size releases pointer and
 * returns NULL; a failed resize leaves pointer untouched. The callback must not
 * throw or call Lua. */
typedef void *(*FoundryScriptAllocator)(void *userdata, void *pointer,
                                        size_t old_size, size_t new_size);

typedef enum FoundryScriptStatus {
    FOUNDRY_SCRIPT_OK = 0,
    FOUNDRY_SCRIPT_INVALID_ARGUMENT = 1,
    FOUNDRY_SCRIPT_BOOTSTRAP_ERROR = 2,
    FOUNDRY_SCRIPT_COMPILE_ERROR = 3,
    FOUNDRY_SCRIPT_RUNTIME_ERROR = 4,
    FOUNDRY_SCRIPT_INSTRUCTION_LIMIT = 5,
    FOUNDRY_SCRIPT_MEMORY_LIMIT = 6,
    FOUNDRY_SCRIPT_RESULT_ERROR = 7,
    FOUNDRY_SCRIPT_TEARDOWN_ERROR = 8,
    /* A binding budget: engine calls, spawn attempts, owned entities or a copied string. */
    FOUNDRY_SCRIPT_NATIVE_WORK_LIMIT = 9,
    /* The host offered no table version this binding can use. */
    FOUNDRY_SCRIPT_UNSUPPORTED = 10,
} FoundryScriptStatus;

/* What an invocation may do. Preparation — top-level evaluation, and later `init` and
 * `migrate` — may read content and the world but may not change the world or log live
 * (scripting.md §11). Only an update may. */
typedef enum FoundryScriptPhase {
    FOUNDRY_SCRIPT_PHASE_PREPARE = 0,
    FOUNDRY_SCRIPT_PHASE_UPDATE = 1,
} FoundryScriptPhase;

/* A stable reason a script stopped, so a host can act on a class of failure rather than on
 * message text (scripting.md §13). The message keeps the underlying ABI result name; this
 * is the part that is safe to branch on. */
typedef enum FoundryScriptCategory {
    FOUNDRY_SCRIPT_CATEGORY_NONE = 0,
    FOUNDRY_SCRIPT_CATEGORY_SYNTAX = 1,
    FOUNDRY_SCRIPT_CATEGORY_CONTRACT = 2,
    FOUNDRY_SCRIPT_CATEGORY_INVALID_ARGUMENT = 3,
    FOUNDRY_SCRIPT_CATEGORY_STALE_HANDLE = 4,
    FOUNDRY_SCRIPT_CATEGORY_UNAVAILABLE = 5,
    FOUNDRY_SCRIPT_CATEGORY_INSTRUCTION_LIMIT = 6,
    FOUNDRY_SCRIPT_CATEGORY_MEMORY_LIMIT = 7,
    FOUNDRY_SCRIPT_CATEGORY_NATIVE_WORK_LIMIT = 8,
    FOUNDRY_SCRIPT_CATEGORY_MIGRATION = 9,
    FOUNDRY_SCRIPT_CATEGORY_SOURCE_REJECTED = 10,
    FOUNDRY_SCRIPT_CATEGORY_RUNTIME = 11,
} FoundryScriptCategory;

#define FOUNDRY_SCRIPT_MAX_OWNED 256u

/* The entities one script package spawned, and so the only ones it may destroy.
 *
 * **Caller-owned and stable**, deliberately not part of the VM: it belongs to the package,
 * not to whichever VM is running the package's code, so a VM can be replaced without the
 * package forgetting what it owns or gaining the power to claim what it does not
 * (scripting.md §11). Zero-initialise before first use. */
typedef struct FoundryScriptLedger {
    uint32_t count;
    uint32_t reserved;
    FoundryEntity entities[FOUNDRY_SCRIPT_MAX_OWNED];
} FoundryScriptLedger;

/* Memory shared by every VM a host runs, charged before each allocation (scripting.md §8).
 * Caller-owned; one per manager. */
typedef struct FoundryScriptBudget {
    size_t limit;
    size_t used;
} FoundryScriptBudget;

typedef struct FoundryScriptConfig {
    FoundryScriptAllocator allocator;
    void *allocator_userdata;
    size_t heap_limit;
    uint64_t instruction_limit;
    /* Instructions one preparation — module load, `init`, later `migrate` — may execute.
     * Preparation happens outside simulation and compiles a whole file, so it gets its own
     * larger budget (scripting.md §8). Zero spends `instruction_limit` in both phases. */
    uint64_t prepare_instruction_limit;
    uint32_t hook_period;
    size_t fail_after_allocations;
    uint8_t inject_teardown_failure;
    uint8_t inject_result_failure;
    uint8_t inject_compile_failure;
    /* Optional shared budget; NULL charges the VM's own heap limit alone. */
    FoundryScriptBudget *budget;
    /* The table query a native mod is handed, and the identity the host issued this
     * package. NULL `get_api` builds the bare fixture environment with no `foundry` module;
     * otherwise version 2 is required and `ledger` must be supplied. */
    FoundryGetApi get_api;
    FoundryMod self;
    FoundryScriptLedger *ledger;
    /* Per-invocation budgets (scripting.md §8). Zero takes the default. */
    uint32_t abi_call_limit;
    uint32_t spawn_limit;
    uint32_t log_limit;
} FoundryScriptConfig;

/* Step 1's fixture result: the chunk returns one integer. The module contract that replaces
 * it for real packages is step 5's. */
typedef struct FoundryScriptResult {
    int64_t integer;
} FoundryScriptResult;

#define FOUNDRY_SCRIPT_DEFAULT_HEAP_LIMIT (8u * 1024u * 1024u)
#define FOUNDRY_SCRIPT_DEFAULT_INSTRUCTION_LIMIT 100000u
#define FOUNDRY_SCRIPT_DEFAULT_PREPARE_INSTRUCTION_LIMIT 1000000u
#define FOUNDRY_SCRIPT_DEFAULT_HOOK_PERIOD 100u
#define FOUNDRY_SCRIPT_DEFAULT_ABI_CALLS 2048u
#define FOUNDRY_SCRIPT_DEFAULT_SPAWNS 8u
#define FOUNDRY_SCRIPT_DEFAULT_LOGS 8u
#define FOUNDRY_SCRIPT_NEVER_FAIL ((size_t)-1)
/* The longest chunk name a host may give a module, which is what a diagnostic names the
 * script by. A package's entry content ID is far shorter than this. */
#define FOUNDRY_SCRIPT_MAX_CHUNK_NAME 128u
/* The persistent state bounds of scripting.md §8, checked when a state table is validated. */
#define FOUNDRY_SCRIPT_MAX_STATE_DEPTH 16u
#define FOUNDRY_SCRIPT_MAX_STATE_ENTRIES 1024u
#define FOUNDRY_SCRIPT_MAX_STATE_BYTES (64u * 1024u)

/* The allocator and userdata remain caller-owned until destroy returns. */
FoundryScriptStatus foundry_script_create(FoundryScript **out,
                                          const FoundryScriptConfig *config);
FoundryScriptStatus foundry_script_execute(FoundryScript *script,
                                           const uint8_t *source,
                                           size_t source_len,
                                           FoundryScriptPhase phase,
                                           FoundryScriptResult *result);
/* -- The author's module (scripting.md §11) -------------------------------------------
 *
 * Three calls replace the fixture's text-in/integer-out for a real package. Each is one
 * protected invocation: `load_module` evaluates the chunk and validates the table it
 * returns, `init_state` calls `init()` and validates the state it returns, and `update`
 * calls `update(state, step)`. Load and init are preparation and may not change the world;
 * only `update` may. `chunk_name` is what diagnostics call this script and is required.
 */
FoundryScriptStatus foundry_script_load_module(FoundryScript *script,
                                               const uint8_t *source,
                                               size_t source_len,
                                               const char *chunk_name);
FoundryScriptStatus foundry_script_init_state(FoundryScript *script);
FoundryScriptStatus foundry_script_update(FoundryScript *script, const FoundryStep *step);
/* The `state_version` the loaded module declared, or zero before one is loaded. */
uint32_t foundry_script_state_version(const FoundryScript *script);

FoundryScriptStatus foundry_script_teardown(FoundryScript *script);
void foundry_script_destroy(FoundryScript *script);
void foundry_script_fail_next_allocation(FoundryScript *script);
void foundry_script_clear_allocation_failure(FoundryScript *script);
void foundry_script_inject_result_failure(FoundryScript *script, uint8_t enabled);
void foundry_script_inject_compile_failure(FoundryScript *script, uint8_t enabled);
const char *foundry_script_diagnostic(const FoundryScript *script,
                                      size_t *length);
/* Why the last invocation stopped, and the source line it stopped on when Lua knew one.
 * Zero means no line was available, which a diagnostic reports as an absence. */
FoundryScriptCategory foundry_script_category(const FoundryScript *script);
uint32_t foundry_script_error_line(const FoundryScript *script);
/* Engine calls the most recent invocation made. For tests and the budget's own evidence. */
uint32_t foundry_script_abi_calls(const FoundryScript *script);

#endif
