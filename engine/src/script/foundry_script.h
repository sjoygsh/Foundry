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
#define FOUNDRY_SCRIPT_DEFAULT_HOOK_PERIOD 100u
#define FOUNDRY_SCRIPT_DEFAULT_ABI_CALLS 2048u
#define FOUNDRY_SCRIPT_DEFAULT_SPAWNS 8u
#define FOUNDRY_SCRIPT_DEFAULT_LOGS 8u
#define FOUNDRY_SCRIPT_NEVER_FAIL ((size_t)-1)

/* The allocator and userdata remain caller-owned until destroy returns. */
FoundryScriptStatus foundry_script_create(FoundryScript **out,
                                          const FoundryScriptConfig *config);
FoundryScriptStatus foundry_script_execute(FoundryScript *script,
                                           const uint8_t *source,
                                           size_t source_len,
                                           FoundryScriptPhase phase,
                                           FoundryScriptResult *result);
FoundryScriptStatus foundry_script_teardown(FoundryScript *script);
void foundry_script_destroy(FoundryScript *script);
void foundry_script_fail_next_allocation(FoundryScript *script);
void foundry_script_clear_allocation_failure(FoundryScript *script);
void foundry_script_inject_result_failure(FoundryScript *script, uint8_t enabled);
void foundry_script_inject_compile_failure(FoundryScript *script, uint8_t enabled);
const char *foundry_script_diagnostic(const FoundryScript *script,
                                      size_t *length);
/* Engine calls the most recent invocation made. For tests and the budget's own evidence. */
uint32_t foundry_script_abi_calls(const FoundryScript *script);

#endif
