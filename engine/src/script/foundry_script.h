#ifndef FOUNDRY_SCRIPT_H
#define FOUNDRY_SCRIPT_H

#include <stddef.h>
#include <stdint.h>

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
} FoundryScriptStatus;

/* Step 1 is a fixture-only contract: execution accepts source text and returns one
 * integer. The C bridge owns every Lua protected invocation; no caller may expose
 * these declarations as a gameplay or mod ABI. */
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
} FoundryScriptConfig;

typedef struct FoundryScriptResult {
    int64_t integer;
} FoundryScriptResult;

#define FOUNDRY_SCRIPT_DEFAULT_HEAP_LIMIT (8u * 1024u * 1024u)
#define FOUNDRY_SCRIPT_DEFAULT_INSTRUCTION_LIMIT 100000u
#define FOUNDRY_SCRIPT_DEFAULT_HOOK_PERIOD 100u
#define FOUNDRY_SCRIPT_NEVER_FAIL ((size_t)-1)

/* The allocator and userdata remain caller-owned until destroy returns. */
FoundryScriptStatus foundry_script_create(FoundryScript **out,
                                          const FoundryScriptConfig *config);
FoundryScriptStatus foundry_script_execute(FoundryScript *script,
                                           const uint8_t *source,
                                           size_t source_len,
                                           FoundryScriptResult *result);
FoundryScriptStatus foundry_script_teardown(FoundryScript *script);
void foundry_script_destroy(FoundryScript *script);
void foundry_script_fail_next_allocation(FoundryScript *script);
void foundry_script_clear_allocation_failure(FoundryScript *script);
void foundry_script_inject_result_failure(FoundryScript *script, uint8_t enabled);
void foundry_script_inject_compile_failure(FoundryScript *script, uint8_t enabled);
const char *foundry_script_diagnostic(const FoundryScript *script,
                                      size_t *length);

#endif
