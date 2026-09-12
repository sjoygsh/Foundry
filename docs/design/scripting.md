# Scripting: the Tier 2 host

**Status:** designed 2026-09-09; **all 8 implementation steps complete, 2026-09-12. M8 is
done.** What remains open is §15, and nothing in it was closed by implementation.

Rests on [ADR-0028](../adr/0028-scripting-lua.md) (runtime),
[ADR-0029](../adr/0029-script-host-and-reload.md) (boundary and lifetime), and
[public-abi.md](public-abi.md) (the existing contract). Proposed symbols and defaults below
are specifications for implementation, not claims about what the current header supports.

## 1. What M8 owes

A mod author writes fixed-tick gameplay in text, packages it through the normal mod path,
and edits it while the host runs. Invalid source, bad arguments, runaway execution and
allocation failures produce a useful diagnostic while the host remains usable.

Needed now: one entry script per package, isolated VMs, bounded execution and state,
content/world bindings, safe replacement, and an independently followed author guide.
Design for later: more binding groups, another runtime, explicit state persistence.
Postpone: script rendering/UI/audio/collision bindings, arbitrary native component mutation,
script-defined component serialization, asynchronous scripts, debugger protocol, editor,
native hot reload, mod manager, WASM and M9 packaging. This is not a full Lua desktop host.

The runnable proof is a small **script-controlled encounter/spawn schedule**: the script
reads timing and template IDs from content, inspects the world, and spawns/removes its own
entities on fixed ticks. Existing native sample systems render and update those entities.
Changing the script changes gameplay timing/conditions, not just a logged number. The
sample owns those schemas, templates and rules; no encounter vocabulary enters the engine.

## 2. What exists, and what it forces

| Existing code | Consequence for this design |
| --- | --- |
| `mod/manifest.zig`, `schemas.zig`, `resolve.zig` | Manifest v1 knows native code only; add optional versioned script metadata and carry it through resolution. |
| `abi/api.zig` | V1 is frozen; source bytes need an additive version. |
| `abi/host.zig`: `issueMod`, `refuseMod`, `systemUpdate` | Host issues identity; scripts cannot invent it. Keep callback slots alive after a VM dies. |
| `scene/system.zig`, `abi/calls_scene.zig` | Systems run in registration order. No unregister or `before`/`after` support. |
| `abi/calls_scene.zig`: `worldSpawn`, `worldReadComponent` | Templates use host-registered component types; foreign components are readable only if describable. |
| `asset/registry.zig`: `reload`, `reloadChanged`, `reloadAll` | Source payload replacement and VM replacement are distinct transactions. |
| `platform/os.zig`: `isSafeRelativePath` | Lexical path checks exist; they do not establish symlink containment. |
| `build.zig` | Hosts own world and renderer; `app` cannot acquire a scripting host implicitly. |

No completed subsystem is redesigned. The new engine-facing work is the source asset and
its ABI publication, plus any narrowly demonstrated validation/resource-bound gaps below
the new bindings. A gap is documented before fixing it.

## 3. Module and ownership boundaries

```
application (owns engine/world/ABI host and the script manager)
  ├─ mod: discovery and deterministic resolution
  ├─ asset: script source loader, no Lua
  ├─ abi: supplies v1 and v2 over host-owned subsystems
  └─ script: core + foundry.h declarations + Lua
       └─ engine operations only through FoundryGetApi / FoundryApi_v2
```

`script` is L6 at the consumer boundary, with **no engine implementation imports** except
`core` for allocation, containers, IDs and explicit RNG. A small header-import module has no
link to `abi`; tests may supply fake tables. Lua types occur only under `engine/src/script/`.
The planned C bridge and its private header live there too; they are not a second public ABI.

The application registers the source loader, merges packages, creates the world and ABI
host, issues identities, and hands `script.Manager` copied descriptors:
`{package_id, package_name, entry_id, binding_version, self}`. `script` never reads a
`mod.Entry` or an asset payload directly. The application owns this conversion.

The manager, its per-package slots and ABI host have stable addresses. A slot owns its
source reference, VM, explicit state root, owned-entity ledger and diagnostics. It survives
VM replacement and becomes inert before a VM is destroyed. One manager is bound to one
world/ABI host lifetime; host rebinding with a live manager is rejected by host integration.

## 4. Runtime and the protected C boundary

Pin Lua **5.5.1** as specified in ADR-0028. Compile its library sources using Zig, excluding
the interpreter executable and excluding OS/package/I/O libraries from the exposed runtime.
Use the upstream default 64-bit integer and double configuration; compile-time checks must
reject a different configuration. Do not use fast-math. No system library lookup, CMake,
LuaJIT, generated machine code or loadable Lua modules.

**No Lua error may jump across an active Zig frame.** All operations that may allocate in
Lua, execute Lua, or raise a Lua error run inside a C-owned protected invocation. This
includes environment construction, chunk loading, argument/result conversion, traceback
construction, migration and teardown—not just the update function.

The C binding validates Lua arguments and builds bounded plain C requests. It calls the
table or a non-throwing Zig helper, waits for that function to return, then creates Lua
results or raises an error. A Zig helper never calls back into Lua. No reentrant script
invocation through an engine callback is allowed. Allocation callbacks return failure;
they never throw. No script finalizer, coroutine or comparator callback may enter Zig.

Reserve the diagnostic buffer before creating the VM. Failure before a protected context
exists returns a status without trying to format into Lua. Closing a VM runs no user
finalizers: user metatables, `__gc`, `__close` and weak tables are unavailable. All bridge
userdata are non-finalizing; resource release is explicit manager bookkeeping.

Step 1 must prove these properties with forced allocation failures during bootstrap,
argument/result conversion, error reporting and closing, and with nested errors/recursion.
An outer `lua_pcall` with an allocating Zig callback inside it is **not** an implementation
of this design. If the boundary cannot be made safe, stop at the gate and revise ADR-0028.

## 5. Script assets and manifest versioning

Add engine-declared asset schema **`foundry:script`, version 1** in `asset/schemas.zig`:
`source: string` (required, existing package-relative location convention),
`language: string` (required, exactly `lua-5.5`). `.lua` files derive records through
`fpack`'s existing asset mechanism, supplying that language; an explicit record can name a
different content ID or override the source. Runtime source is UTF-8 text, bounded before
read, with no binary chunk, embedded NUL or bytecode accepted. The source loader copies
text; it does not parse/execute Lua and does not make `fpack` depend on Lua.

The derivation in `tools/fpack/pack.zig` emits both `source` and the kind's required derived
string fields; `.lua` therefore adds `language "lua-5.5"`. Merely adding `.lua` to the
extension table would have been insufficient. Both derived and explicitly authored records
are tested.

Append optional **`script`**, `since = 2`, to `foundry:mod` and raise that schema to version
2. Its nested fields are `entry: id` and `binding: u32`, both required when present.
M8 accepts binding 1. Keep every existing field unchanged. V1 packages remain readable;
absent script means exactly today's behavior. Update the test that currently assumes all
manifest fields have `since = 1`; do not remove version checking.

Illustrative authoring record (validated against the implemented syntax in step 2):

```text
foundry:mod encounters:mod {
    name "Encounter example"
    version 1
    license "MIT"
    requires [ { id foundry:core min 1 } ]
    abi { min 2 max 2 }
    script { entry encounters:scripts.main binding 1 }
}
```

The author guide adds the actual sample dependency. An authored `foundry:script` record
maps that ID to `scripts/main.lua`; no path spelling in this example defines identity.
Script-bearing packages require an ABI range intersecting the host's offered versions and
containing v2 for this binding. Native-only v1 mods still work. Native loader compatibility
checks must consider **all offered versions**, not only its current hardcoded v1 constant.

M8 supports content+script and content+native packages. A manifest naming **both** code
tiers is diagnosed as unsupported for code activation, with its content retained; it must
never silently run native code under a sandbox label. Dependencies order content, not a
guarantee that another package's code initialized successfully. Script errors do not remove
content or silently reorder dependents.

Carry script metadata into `mod.Entry`, and make the native loader explicitly refuse an
entry carrying both code tiers before opening an image. Application filtering alone is not
sufficient: a native-only application calling the public loader must get the same refusal.

## 6. One public addition: source copying

Publish **`FoundryApi_v2`**, a separate flat table containing the 135 v1 function entries
in the same relative order, followed by:

```c
int32_t (*script_source_copy)(FoundryAsset asset,
    uint8_t *buffer, uint64_t capacity, uint64_t *needed, uint64_t *revision);
```

V2 begins with its own `version = 2` and `size`; it is not cast to v1. `get_api(1)` returns
the unchanged v1 table and `get_api(2)` returns v2. Existing callers keep querying v1.
The v2 common entries reuse the existing implementation functions. Agreement checks cover
both layouts, function signatures and cross-language calls. No v1 fields change.

The source is acquired using the existing `asset_acquire(id)` and balanced by
`asset_release`. This new call accepts only assets from the exact built-in script loader,
not merely any payload claiming the schema. Stale handle: `invalid_handle`; another asset
kind/loader: `unsupported`; missing engine: `unavailable`; invalid output pointers or
null buffer with nonzero capacity: `invalid_argument`.

`needed` and `revision` are required. On a valid asset they are written even if capacity
is insufficient, which returns `limit` and copies nothing. `(NULL, 0)` is the sizing probe.
Sufficient capacity copies exactly `needed` bytes, without a terminator, and returns `ok`.
Source is immutable for the duration of the call. A nonzero revision changes after each
successful payload replacement, including content override; it never depends on a pointer
or file timestamp. Exhausting the revision counter refuses replacement, never wraps.

The manager probes, checks its limit, allocates, copies and verifies the revision agrees;
all happen on the main thread outside reload, without calling user code between them.
Do not introduce retry loops into a fixed tick. It retains its own copy for compilation;
no borrowed ABI pointer is placed in a Lua value.

Source loading inherits asset override semantics: an entry ID may resolve to a later
package, just as a texture does. Diagnostics show both the consuming package and winning
source package. This grants source-reading capability, not arbitrary filesystem access.

**Containment before publication:** lexical `..` rejection is insufficient. The source read
rejects symlink/reparse components through a root-relative confined open in `platform.Os`.
It validates the opened object, not a `realpath` check followed by an unrelated open, and no
absolute machine path reaches a script diagnostic. Step 2 includes cross-target compilation
and adversarial host filesystem tests; the older lexical asset path check alone does not
establish this guarantee.

## 7. Binding 1: exact scope and value rules

The Lua module is **`foundry`**, binding version 1. Its function names below retain the
ABI spelling. The trusted manager uses source/asset/system/log APIs for its work; that does
not make them all script-callable. All unlisted table entries are unavailable in binding 1.

| Lua exposure | ABI calls / behavior |
| --- | --- |
| Identity | `id_from_string`, `id_to_string`; copied names, opaque IDs. |
| Pure helpers | `schema_id(name)` from the public header; `rng(seed, stream)` with `next_u32()` returning a u32; neither accesses engine state. |
| Logging | `log_write`; package identity supplied by the bridge, never by Lua. |
| Content walks | `content_generation`, `content_find`, `content_next`, `content_next_of_schema`. |
| Record identity | `record_id`, `record_name`, `record_schema`, `record_package`. |
| Field inspection | `record_field_count`, `record_field_index`, `record_field_name`, `record_field_type`, `record_field_present`. |
| Scalar/nested reads | `record_get_bool`, `record_get_i64`, `record_get_u64`, `record_get_f32`, `record_get_string`, `record_get_id`, `record_nested`. |
| List reads | `record_list_len`, `record_list_get_i64`, `record_list_get_f32`, `record_list_get_string`, `record_list_get_id`, `record_list_nested`. |
| World inspection | `world_contains`, `world_entity_count`, `world_next_entity`, `world_find_component_type`, `world_has_component`, `world_read_component`. |
| Gameplay mutations | `world_spawn` (one validated template), `world_destroy_entity` (only entities in this package's ledger). |

`foundry.schema_id(name)` wraps the public header's `foundry_schema_id` helper after
validating the namespaced spelling; it produces tagged SchemaId userdata, not a ContentId
cast. Schema IDs can be compared, passed to the schema/type calls and migrated as values.
This is a pure identity helper, like `foundry.rng`, not a private engine capability.

Successful scalar calls return a value; successful mutation with no result returns `true`.
Normal absence (`not_found`), exhausted iteration (`end`), or a documented unavailable/
unsupported capability returns `nil, error_name`. Malformed arguments, stale handles,
ownership violations and resource exhaustion raise a script error caught by the host.
Callers cannot pass raw result buffers, callback pointers, a `self` value or a byte offset.
Nonzero-based Lua convenience conversions are not implicit: field/list indices retain the
ABI's **zero-based** semantics; ordinary Lua arrays remain one-based.

Handles/IDs/cursors are immutable tagged full userdata containing values, never exposed
light userdata or floating-point numbers. Verify the tag, owning manager and lifetime on
each use. No constructor accepts handle bits. Content IDs are value-equal; runtime handles
also retain their subsystem generation. Signed integers stay integers. A `u64` above
`INT64_MAX` becomes opaque unsigned-value userdata with comparison and decimal formatting,
not a lossy float; no general arithmetic is required in binding 1. Reject non-finite floats
at the boundary, and validate before narrowing to f32/integer/enum.

Strings and record results are copied while the ABI borrow is valid. A nested record or
cursor userdata is additionally scoped to the current invocation; using it in the next tick
is an error even when the underlying ABI handle happens to survive. Reacquire records by
content ID. Migration never preserves record, package, component-type or cursor handles.

`world_spawn` uses a content template with types the host already registered. Before each
spawn, a preflight through the content and type-inspection ABI validates the template's
shape, component count and per-instance footprint against §8. The manager may use the
v1 `world_component_type_size` / `alignment` calls internally for this preflight; they are
not an excuse to publish raw storage. Cache only with the content generation and type
identity; refuse a changed/unsupported shape. Preallocate the ownership ledger entry before
calling spawn, so success cannot create an unaccounted entity. If engine spawn can leave a
partial entity on failure, step 4 must correct that validation/cleanup defect below the ABI.

Also require `world_component_type_savable` during preflight: it conservatively establishes
that both serialization directions exist. M7 ABI-registered transient types lack a
deserializer and cannot be spawned from content. The existing `World.spawn` already uses
`errdefer` to destroy a partial entity; retain that behavior and verify it under exhaustion.
Schema compatibility and deserialization remain the engine's validation responsibility,
not a second schema implementation in the binding.

Destroying an entity the package did not spawn is refused. A missing previously owned entity
is pruned from the ledger. World reads are shared; script sandboxes isolate runtime memory
and host access, not the gameplay effects of legitimately enabled mods.

## 8. Resource model and sandbox environment

These are conservative **initial defaults to implement and measure**, not benchmark results.
Host configuration may lower them; raising them requires explicit host configuration and
never a value written by a mod. All arithmetic for limits is checked.

| Bound | Initial default |
| --- | --- |
| Enabled script packages | 16, also subject to existing ABI mod/system capacities |
| Source bytes / package | 256 KiB, one file; no dynamic `require` or `load` |
| Lua heap / VM | 8 MiB including compilation, strings, stacks and state |
| Manager aggregate committed/reserved script memory | 160 MiB, including source, bridge scratch, migration and one candidate VM |
| Executed Lua instructions / update | 100,000; hook every 100 instructions |
| Instructions / preparation or migration | 1,000,000; outside simulation, one candidate at a time |
| ABI calls / package / tick | 2,048; traversal calls count too |
| String returned or formatted by a binding | 16 KiB |
| Persistent state snapshot | 64 KiB, depth 16, 1,024 entries total |
| Live entities owned by one script | 256; at most 8 spawn attempts per tick |
| Spawn template | 32 components; 64 KiB total instance storage including alignment |
| Diagnostic | 4 KiB, at most 16 traceback frames; logs 8 lines / tick / package |

Reserve aggregate budget **before** allocation. A failed realloc leaves the previous block
and accounting unchanged. Release source/snapshot/candidate charges on every failure path.
Successful reload returns to steady-state allocation; repeating it may not consume slots
or monotonically retain memory. A source asset's initial read is separately bounded by
the source loader before allocation; active source refs and host asset memory have explicit
host budgets, not an assumption that the Lua allocator sees them.

VM memory and ABI call counts do not bound engine allocations. Script-capable sample/host
configuration must also use bounded allocators for the world and source asset storage
(initial sample budgets: 64 MiB world, 16 MiB source storage). Allocation refusal must return
through the ABI. Existing host entities consume that budget too. Entity count/footprint
limits reduce pressure; they do not replace allocator limits or handle externally retained
entity destruction callbacks. Audit every enabled binding's call chain before enabling it.

Build the environment by allowlist, **not `luaL_openlibs` followed by deletion**:

* Base: `assert`, `error`, `type`, `select`, bounded `tonumber`, scalar-only `tostring`,
  `ipairs`, and Foundry's deterministic `pairs` replacement.
* Math: `abs`, `ceil`, `floor`, `min`, `max`, `sqrt`; no `random`/`randomseed`. Use an
  explicit `foundry.rng(seed, stream)` backed by `core`'s specified RNG; its state can migrate.
* Strings: bounded `len`, `sub`, `byte`, `char`, `lower`, `upper`; no patterns, formatting
  engine, `dump`, `rep`, binary packing or arbitrary native-work loops.
* Tables: no native table library initially. Ordinary Lua tables, numeric loops and
  `ipairs` suffice. No user-comparator sort that could catch/propagate an error through C.

Absent: `io`, `os`, `package`, `debug`, `coroutine`, `load`, `loadfile`, `dofile`, `require`,
`pcall`, `xpcall`, `collectgarbage`, `next`, `rawset`, `getmetatable`, `setmetatable`, native
plugins and FFI. Do not expose `_G` pointing to a richer environment, registry access,
hidden library tables through string metatables, or a function whose upvalues reveal them.
Script errors go to the host; no script `pcall` can repeatedly catch a budget exception.

The instruction hook sets a host-owned terminal flag before raising its preallocated error.
Bindings refuse further work if that flag is set. C helpers perform bounded work and invoke
no user callback. Source length and the runtime's checked parser/stack limits constrain
compilation; instruction hooks alone do not meter parsing or garbage collection. Stress
these paths at their actual limits. This is a bounded-work policy, **not a hard realtime
deadline**. No wall-clock timeout drives simulation behavior; future process isolation is
a separate architecture if a stronger failure boundary becomes necessary.

## 9. Deterministic-friendly execution

`update(state, step)` receives `{tick, delta_ns}` copied from `FoundryStep`, never elapsed
wall time, frame delta, profiler readings or pointer values. Register one dispatcher per
package in resolved order after native initialization. The application documents where
this group sits among its own systems; M8 adds no system dependency scheduler.

`pairs` collects only integer and string keys, sorts integers ascending then strings by
unsigned byte order, and walks that bounded snapshot. It rejects unsupported key kinds
and more than 1,024 keys. No raw `next`. Modifying values is allowed; insertion/deletion
during a walk is documented as affecting only a subsequent snapshot. Helpers never order
objects by address. `tostring` rejects tables/functions/userdata except the bridge's own
value-formatters; it cannot expose Lua's default pointer strings. No weak tables or user
finalizers make GC timing observable as gameplay.

RNGs are explicit, seeded by integers/content rather than the clock; migration preserves
their algorithm state. Hash-table implementation order is not part of the contract.
Tests run the same script/scenario/seed in separate fresh VMs and compare entity actions,
state snapshots and diagnostic categories. Different frame pacing with the same fixed
ticks must agree. Reload is an explicit development input applied at a named tick boundary;
ordinary deterministic runs disable automatic reload.

## 10. Package startup and shutdown

1. Discover/resolve/merge through M7. After `Engine.init`, register the source loader before
   the first script asset acquisition (assets are lazy; no pre-init injection is needed).
   Register world component types and bind the ABI host. Prepare all stable script slot
   storage before publishing callbacks.
2. Initialize native packages in their existing resolved order. Script initialization then
   follows resolved order; cross-tier code-init dependencies are not promised. Content
   dependencies already exist. A host may omit native loading entirely for Tier 2 use.
3. For each script descriptor, acquire/copy its source through v2, create a candidate VM,
   execute the chunk in preparation mode, and validate the returned module contract (§11).
   Call `init()` without world mutation, then validate its state snapshot.
4. Issue/use a valid package identity via the application's `abi.Host`; register a system
   through `world_register_system` with **the package ID and package name** as its identity.
   IDs are separate registry domains; no path-derived or reserved suffix is needed. A name
   collision with an existing system is a diagnosed activation refusal.
5. Publish the active VM only after registration succeeds. Failed startup releases all
   candidate storage/source refs and leaves content loaded. A retained callback is inert.

The manager rejects activation if the ABI world is absent. Host-issued handles are obtained
before any attributed log/system call; on pre-registration failure the host may refuse them.
Once registered, keep the identity and slot for the world lifetime, including script faults.
Never use `Host.refuseMod` as the reload operation.

At teardown: stop ticking and reload; mark every slot inert; close VMs and release source
references while the ABI is bound; shut down native mods by the existing lifecycle.
**Unbind the ABI host to neutralize its native component/system callbacks**,
then destroy the world while ABI and manager storage still exists; finally destroy the
host and release stable manager slots. Native shutdown may have freed state its component
destructors once used, so world destruction before callback neutralization is unsafe.
Script code receives no shutdown callback. Engine
entities are world-owned and die with the world; closing Lua does not destroy gameplay
entities or run arbitrary finalizers. Faulted scripts leave their prior effects in place.

## 11. Author contract and state

The entry chunk returns a table with exactly these recognized fields:

```lua
return {
    state_version = 1,
    init = function() return { next_tick = 1 } end,
    update = function(state, step)
        -- Read content, inspect the world, spawn a template when its condition is met.
        -- All state needed after reload belongs in state, not hidden in an upvalue.
    end,
    -- optional: migrate = function(old_state, old_version) return new_state end
}
```

`state_version` is a positive u32; `init` and `update` are required functions; `migrate`
is optional. Unsupported named lifecycle fields are diagnosed, catching misspellings.
One file initially: authors factor local functions within it. Module loading is a future
scope increase with its own dependency snapshot rules.

Top-level evaluation, `init` and `migrate` may use pure helpers and read content, but cannot
mutate world state, open resources, emit live logs or observe profiler/frame state.
Preparation diagnostics are buffered. `update` gets the persistent state table; its return
value is ignored. Mutating globals/upvalues is legal Lua but those values are rebuilt on
reload; the guide must not imply they are saved.

The migration representation is an in-memory bounded value tree: nil, booleans, signed
integers, finite doubles, byte strings, tables keyed by integer/string, content IDs,
schema IDs, unsigned-value userdata, explicit RNG state, and this package's owned entity handles.
Reject cycles, repeated table references (no alias preservation), functions, arbitrary
userdata and excessive depth/size. Serialize keys in §9 order. Read the old state directly
without invoking old script code or metamethods. The snapshot is not a save format.

Entity handle migration preserves generation and manager ownership; rewrap it in the new
VM. Stale owned handles remain detectably stale, never rebound to another entity. The
ownership ledger itself belongs to the stable manager slot and is not recreated from what
the script elects to retain in its state. Migrating cannot acquire ownership of foreign
entities by providing a fabricated handle.

## 12. Hot reload transaction

Automatic source/asset change detection is development-only and remains the host's job.
`script.Manager.pollReload` runs after content/asset reload and before the next world update,
with no active callback, query or borrowed script value. Do not reload from an asset loader
callback or in the middle of a tick. Process changed packages in resolved order, one
candidate per host boundary, to bound peak memory/work.

1. Observe the source revision through v2. Remember the last attempted revision so broken
   text is not compiled and logged every frame; explicit retry is a host action.
2. Keep the old VM live but idle. Copy the new source and snapshot the old state under the
   aggregate quota. If either fails, retain the old VM unchanged.
3. Create/evaluate the candidate with mutation disabled. If state versions match, copy the
   snapshot directly. If they differ, require `migrate(old_state, old_version)` and validate
   its result. A version change without migration refuses reload; there is no implicit reset.
4. Validate the module, state and binding version. All candidate work so far may fail
   without changing the active VM, ledger, registrations or world.
5. Swap the slot's active VM/state and accepted revision. This commit must allocate nothing
   and execute no user code. Close the old VM; the next fixed tick runs the replacement.

`init()` runs at initial activation only. A replacement with unchanged state version never
respawns initial entities. A source/compile/migration/OOM failure keeps the old code/state;
there is no whole-world rollback. A **later active update** that errors faults the new VM
and leaves any earlier effects of that update in the world. Do not fall back to an old VM
that expects a world those effects have not touched.

Content reload is independent: a failed script replacement does not undo already merged
content. The old script sees new content and must handle missing/changed records. A changed
manifest entry, binding, package enabled set, dependency graph or native library requires
host restart in M8; source changes and state migration are the supported iteration loop.
Removal of a source retains the last working VM and reports the problem. Faulted packages
can attempt replacement on a new revision; invalid old state requires explicit host restart,
not silently calling `init` over an existing world.

## 13. Errors and diagnostics

Report package spelling, entry content ID, winning source package, logical source filename,
line when available, phase (`load`, `init`, `update`, `migrate`), fixed tick for updates,
and a stable error category plus suggested action. Example:

```text
encounters:mod / encounters:scripts.main / scripts/main.lua:18
update, tick 240: instruction_limit — this update exceeded 100000 instructions.
The script is disabled. Check for an unbounded loop; edit the file to retry.
```

Categories include syntax, contract, invalid_argument, stale_handle, unavailable,
instruction_limit, memory_limit, native_work_limit, migration and source_rejected. Preserve
the underlying ABI result name. Do not turn an expected `not_found` into a generic crash.
If a Lua error value is not a string, describe its type without invoking `tostring` or a
metamethod. Traceback failure/OOM falls back to the preallocated category/message buffer.

Use existing attributed logging and log sink, with bounded repeated-error suppression.
The diagnostic record is stored even if terminal logging is filtered. No new overlay panel
or editor framework is needed. Test formatting separately from `err` logging as M7 does.

## 14. Verification, including attempts to break the guards

Every step runs AGENTS.md §3 before committing. ABI edits additionally compile real C99 and
C++17 consumers against the installed header on the host and both cross targets. New
runtime C translation units must be reached by `zig build check`, not merely by tests.

Required evidence accumulated through the steps:

* Fail allocation at every allocation point in bootstrap, compile, update conversion,
  snapshot, migration and teardown. Assert status, unchanged accounting, and a healthy
  subsequent package/tick. Run runtime stress tests in a child process with a host-side
  deadline so a regressed guard cannot hang the whole test runner.
* Infinite loop, recursion, excessive native calls, huge strings/tables, binary chunk,
  invalid UTF-8/NUL, attempted `pcall` budget escape, library/metatable escape, arbitrary
  userdata/handle, non-finite float and oversized integer. No host assertion/abort.
* Escaping paths and symlinks, wrong loader provenance, stale source asset, missing source,
  changed source size/revision, failed source read and content override from another root.
* V1-only native mod still loads; v2 negotiation works; wrong version/refusal is legible;
  header layout/width/signature drift must fail after deliberate mutations in either half.
* Deliberately remove the hook, bypass the quota or admit a forbidden function one at a
  time in temporary test edits; the corresponding guard test must fail. Restore only the
  exact edit made, preserving concurrent work. Record the evidence in dated Resolutions.
* Fake table records every binding call; no direct subsystem implementation is linked to
  the isolated binding test. A deliberate forbidden module import fails the build graph.
* Two packages cannot share Lua globals, state, quotas or entity mutation ownership.
  A failing one does not consume the other's budget or prevent its next update.
* More reloads than the ABI system-slot limit preserve registration count/order, entity
  identity and bounded memory. Old VM sentinels prove no callbacks execute after destruction.
* Bad syntax, migration errors, incompatible versions and candidate OOM retain old code
  **and old state**. Successful migration changes behavior next tick without duplicate init.
* Two fresh runs agree on state/actions with identical input/ticks/seed and different frame
  pacing. Host exhaustion in a spawn is returned and creates no leaked/partial entity.
* A null-backend full pipeline and a windowed sample prove gameplay, visible code reload,
  error recovery and continued controls. An outside-tree package repeats the author guide.

No fixed new test count is promised. Keep the actual passing count in PROJECT_STATE.md.

## 15. Open questions and limits kept open

1. Script-defined serializable components and durable script saves. Trigger: a real script
   must survive a process restart. Requires ABI serializer/migration design, not VM dumping.
2. More bindings, especially foreign component writes, input, rendering, UI, collision and
   audio. Trigger: the next concrete scripted feature the current surface cannot express.
   A missing engine capability must become public before it becomes script-callable.
3. Multiple script modules and cross-package imports. Trigger: one-file authoring becomes a
   demonstrated burden; requires an atomic dependency snapshot and import cycle semantics.
4. Live package enable/disable and independent system scheduling. Trigger: a mod manager or
   actual ordering dependency. World registrations remain fixed in M8.
5. Per-mod C ABI tables/capability policy remain `public-abi.md` §18 question 4. Restricting
   Lua bindings does not grant native v1 code new isolation or close that wider question.
6. OS-process isolation, formal security guarantees and hard deadlines. Trigger: deployment
   requires containment of an unknown native runtime defect, rather than script faults.

M7's native unloading, mod-owned filesystem storage, host identification and threading
questions stay open. Its Tier 2 sandbox question is addressed by this document and ADR-0028;
it must not be read as a promise of sandboxing native code.

## 16. Implementation order

**Eight steps. Stop after each completed step:** run the bar, update PROJECT_STATE.md,
append a dated Resolution for any design correction, commit, and hand back. Do not combine
steps simply because a session has budget. This planning commit completes none of them.

1. **Prove the runtime boundary.** Add the exact Lua dependency/license and optional build
   wiring; implement the private C bridge, quota allocator and minimal allowlisted VM.
   No gameplay bindings or sample migration. Gate: all targets compile; a headless fixture
   executes text, stops a runaway, contains recursion/OOM and proves no Lua nonlocal exit
   crosses Zig. Include compile/bootstrap/result/teardown failure injection. If it fails,
   revise the architecture before proceeding. Runnable result: protected script fixture.
2. **Make scripts ordinary package assets. Complete 2026-09-10.** Add script schema/source loader, confined
   source reads, fpack derivation and manifest v2 metadata through discovery/resolution.
   Source revisions and override/refusal tests; neither fpack nor content-only hosts links
   Lua. Runnable result: compile/discover a script-bearing package and read its bounded
   source asset through an asset test host. Old packages still compile/load.
3. **Publish source through ABI v2. Complete 2026-09-10.** Add the table and typed copy call, retain v1 exactly,
   update native version-range selection and install header agreement. Test a native C
   consumer reading the asset, both versions side by side, empty host, stale/provenance
   refusals and deliberate agreement breaks. Runnable result: an external C-shaped consumer
   reads a packaged script without engine types. No Lua gameplay yet.
4. **Bind bounded content and gameplay operations. Complete 2026-09-12.** Implement §7's conversions and exact
   allowlist against fake and real ABI tables; stable iteration/RNG and entity ownership.
   Implement/check template preflight, aggregate/native memory policy and atomic spawn
   refusal. Runnable result: a protected script reads content and spawns/removes an entity
   through a fake-table test and a real null-world integration fixture. No package scheduler.
5. **Wire the package lifecycle. Complete 2026-09-12.** Stable manager slots, issued identities, one system per
   package, activation/fault/teardown and diagnostics; integrate the minimal scripted
   encounter in the sandbox's own package. Support an opt-in host with no native loader.
   Test mixed packages, version failures, capacity and one script failing beside a healthy
   one. Runnable result: visible fixed-tick behavior driven by an ordinary script package.
6. **Replace code without replacing the world. Complete 2026-09-12.** Implement snapshots,
   versioned migration, candidate validation, source revision polling and nonallocating
   commit. Test rollback, fault recovery and repeated reload beyond slot capacity. Runnable
   result: edit gameplay conditions live and retain state/entities, then introduce bad source
   and keep the old behavior. Document content-reload independence explicitly.
7. **Prove isolation and reproducibility end to end. Complete 2026-09-12.** Complete the
   adversarial matrix in §14, guard-breaking evidence, bounded native-work/OOM paths,
   deterministic scenarios, source confinement and windowed recovery. Measure the default
   budgets with the runnable sample and record any justified adjustment before changing them.
   Runnable result: a deliberately broken mod beside healthy gameplay, with a useful error
   and working controls.
8. **Execute the author exit criterion. Complete 2026-09-12.** Write `docs/modding/script-mods.md` by creating
   a package outside the engine tree, following it from installed tools to scripted gameplay,
   source edit, migration and intentional failure/recovery. Verify it independently by
   following the exact guide. Update indices/status/actual test count and mark M8 complete
   only with that evidence; commit/tag `m8`. Stop before M9.

## 17. Planning handoff

Architecture and sequence are written, and **all eight steps are complete**. They prove the
Lua/C/Zig containment boundary, package/source integration, additive public source access,
binding 1's bounded content/world surface, the package lifecycle that drives it on a fixed
tick, the candidate-VM replacement that changes a package's code while its world, its state
and its entities stay, the end-to-end isolation, bounded-failure, reproducibility,
confinement and live recovery evidence, and the author guide written by building a script
package outside the engine tree and then reproduced from its own listings.

M8 is closed. What this document leaves open is §15's list, and nothing in it was closed by
implementation. M9 is now designed in [distribution.md](distribution.md), with no steps
implemented; no further scripting work is authorized by this document.

## Resolution — 2026-09-10, step 1

Lua 5.5.1 builds directly from its pinned official archive on the host, Linux and Windows
targets. The optional L6 module imports `core` and links Lua privately; existing engine modules,
tools and samples do not import it. A C-owned outer `lua_pcall` contains bootstrap and each
execution, with a nested protected call distinguishing script faults. The bridge uses only
Lua's public headers/API. `lua_newstate` contains its own initialization failure internally,
and closing can run no author finalizer because this environment publishes neither metatables
nor finalizable userdata.

The step-1 fixture exposes only `assert`, `error`, `type`, bounded scalar `tonumber`/`tostring`
and `ipairs`, enough to prove allowlist construction, execution and failure recovery. Its
single integer result is a test seam, not §11's module contract. `select`, deterministic
`pairs`, the bounded math/string groups and `foundry` bindings remain due when step 4 installs
the authored environment; this does not narrow §8's final allowlist.

The Zig wrapper allocates a stable allocator context so moving its `Runtime` value cannot leave
C with a pointer into moved Zig storage. Lua allocations are charged before being attempted;
replacement allocation preserves the old block on failure. Tests walk allocation refusal from
index zero until bootstrap plus execution succeeds, separately exhaust a real 64 KiB quota,
and require same-VM recovery. Teardown injection leaves the state owned so ordinary `deinit`
still closes and frees it.

The three guards were also broken one at a time. Disabling the instruction hook made the
headless fixture exceed a host-side three-second process deadline; bypassing the quota changed
the heap-limit test from `memory_limit` to success; and publishing a forbidden `debug` global
broke the allowlist test. The exact temporary edits were restored before verification.

## Resolution — 2026-09-10, step 2

The design required no architectural correction. `foundry:script` version 1 has required
`source` and `language` fields; the registered source loader accepts exactly `lua-5.5`, copies
valid UTF-8 text, rejects NUL and binary chunks, and owns a nonzero monotonic revision. Its
256 KiB limit is a loader property applied by the registry before file allocation/read, so
large binary asset kinds keep their existing host ceiling without making script source large.
Revision exhaustion refuses replacement rather than wrapping, and a failed replacement leaves
the prior bytes and revision active.

Package-selected source paths now use `platform.Os` handle-relative traversal. Each component
below the mounted root is opened with symlink/reparse following disabled; bytes and the initial
stamp come from the same opened object. The same primitive also closes fpack's import-read hole.
This is stricter than resolving symlinks that remain inside a package, deliberately choosing the
design's permitted reject-all policy and avoiding a check/open race. Temporarily enabling
symlink following made the adversarial confinement test fail; restoring it returned the focused
platform suite to green.

Asset kinds gained declarative derived string fields rather than a script-name branch in fpack,
so `.lua` emits `language "lua-5.5"` through the ordinary derivation path. Manifest v2 appends
optional `{entry, binding}` script metadata, accepts binding 1 only, requires a declared range
containing ABI v2, and carries the descriptor unchanged through deterministic resolution.
Schema-v1 manifests still read. A package carrying native and script code remains discoverable
as content, while the native loader diagnoses and refuses code activation before opening its
image. Its compatibility predicate now examines the set of offered tables, ready for v2 to join
that set in step 3 without dropping v1-only native mods.

The runnable proof compiles a script-bearing package with fpack, discovers and resolves it,
mounts its ordinary package root in an asset-only host, and reads the bounded source through the
registered loader. Neither that host nor fpack imports or links Lua. The suite is 1142 headless
tests after this step. ABI v2, public source copying and every gameplay binding remain untouched.

## Resolution — 2026-09-10, step 3

The design required no architectural correction. `FoundryApi_v2` is a separate flat table:
its 135 common calls retain v1's types, relative order and implementation functions, followed
by `script_source_copy`. The Zig type is constructed from v1's field metadata so common-table
drift cannot originate in one Zig declaration, while the independently hand-written C header
still declares the full flat v2 layout and remains the public specification. `get_api` returns
stable, distinct v1 and v2 table addresses; unknown versions remain null.

The application lends `abi.Host` the stable address of the exact `ScriptSourceLoader` it
registered. The copy call first distinguishes a stale handle from a live payload with the wrong
loader provenance, then writes required length and nonzero revision on a valid sizing refusal,
copies nothing on insufficient capacity and copies exactly the source bytes with no terminator
on success. A source reload keeps the asset handle and advances the observed revision. An empty
host reports `unavailable`; malformed outputs, stale handles and another loader report their
specified result codes without exposing an asset payload pointer.

The C agreement now covers v2's complete name/order/offset list, all common function signatures
against v1 and the appended call's exact signature. A C99 consumer built only from `foundry.h`
queries v2, acquires a packaged script asset, probes and copies the source, and balances its
reference. Narrowing the C capacity parameter made the compile-time signature assignment fail;
swapping two same-typed Zig entries made the textual-order, compiled-offset and side-by-side
table checks fail. Both temporary mutations were restored. The suite declares 1155 tests,
which is 1147 headless after the documented 8 Metal-only tests. Gameplay bindings, Lua-facing
API construction, package scheduling and every step-4 capability remain untouched.

## Resolution — 2026-09-12, step 4

The design needed **one correction, and §11 named the thing it collided with.** The ownership
ledger "belongs to the stable manager slot", and that slot does not exist until step 5; a
ledger owned by the VM would also be lost at step 6's VM replacement, which is the loss §11
forbids. So the ledger and the aggregate memory budget are **caller-owned C structs passed to
the VM by pointer** (`FoundryScriptLedger`, `FoundryScriptBudget`). Step 5's slot becomes
their owner by holding them, with no change to the VM's contract, and step 6 can swap a VM
beneath a package that still knows what it owns. Nothing else in §§7–9 changed.

The bindings are C, beside the bridge in `binding.c`, because §4's rule is that the argument
check, the table call and the result construction happen in C frames with no Zig frame between
them. Each validates, builds a plain C request, calls exactly one table entry, waits for it to
return, and only then pushes results or raises. No Zig helper is reachable from Lua, and the
`foundry` table is built by allowlist rather than by deletion.

**Three shapes the design gave in ABI terms had to become Lua terms**, each following from
§7's own rule that handles are immutable values. An in/out cursor cannot be immutable, so a
walk is `record, cursor = foundry.content_next(cursor)`, with `nil` to begin and `nil, "end"`
at the end — the ABI's spelling, not its calling convention. A `u64` above `INT64_MAX` is
opaque unsigned userdata that compares and formats in decimal rather than a lossy float. And a
field type is its name (`"i64"`, `"nested"`), because the integer would make every script
carry its own copy of an enum this header may extend.

Records, cursors and packages are stamped with the invocation that produced them and refused
in any other — stricter than the ABI beneath them, deliberately: a content record's engine
handle survives the tick and a described component's dies with the frame, so the
script-visible rule is the shorter of the two rather than two rules an author must tell apart.
Ids, schema ids, entities and component types are values and carry no stamp.

**Absence is a value; misuse raises.** `end`, `not_found`, `unavailable` and `unsupported`
return `nil, name`; a malformed argument, a stale handle, a phase violation, an ownership
violation and every budget raise with a category and the ABI's own result name. A mutation or
a log line attempted during preparation is a `contract` error rather than a quiet no-op, so
§11's "init cannot touch the world" rule is visible the first time it is broken.

`world_spawn` preflights through the same public calls a script could make — the schema is
`foundry:entity`, at most 32 components, every one a registered **savable** type, at most
64 KiB of instance storage — and reserves its ledger entry before asking the world, so a
successful spawn cannot produce an entity the package does not own. The answer is cached
against the content generation, and the integration test asserts that spawning the same
template a second time costs fewer engine calls. `world_destroy_entity` refuses an entity the
package did not spawn, and prunes one the world has already lost.

`foundry.rng` is `core.Pcg32` written out in C and pinned by a test to `core`'s own sequence,
for the reason the content hash is written out in `foundry.h`: a seed is a reproducibility
promise, and two implementations of one generator must not be able to drift. `pairs` walks a
sorted bounded snapshot — integers ascending, then strings by unsigned byte order — and
`tostring` formats scalars and bridge values only, so no address is observable as gameplay.
Writing it also fixed a defect inherited from step 1: integers were formatted through a double
and lost precision above 2^53.

**Verified by breaking each new guard in turn**, restoring the exact edit each time: letting
preparation mutate the world failed the phase test; not stamping a record with its invocation
failed the stale-handle test; removing the per-call charge failed the budget test; and
publishing one extra entry in the table failed the allowlist test. The suite is **1172
declared, 1164 headless** after the documented 8 Metal-only tests, and the full AGENTS.md §3
bar passes on the host, `x86_64-linux-gnu` and `x86_64-windows-gnu`, with both samples.

What step 4 deliberately does **not** do: no script package runs. Nothing registers a system,
nothing drives a tick, and an invocation is still the fixture's text-in/integer-out with a
phase beside it. §11's module contract, stable callbacks, activation and teardown are step 5's,
and none of them was smuggled in early.

## Resolution — 2026-09-12, step 5

A script package now runs. The module contract of §11 is three C entry points beside the
fixture's — `load_module` evaluates the chunk and validates the table it returned,
`init_state` calls `init()` and validates the state it returned, `update` calls
`update(state, step)` — and each is one protected invocation on the same two nested
`lua_pcall`s step 1 built. `script.Manager` in Zig holds one stable slot per package, and
the slot is what the world's system callback points at, forever. What changes underneath it
is which VM, or none; the registration, the issued identity and the ownership ledger do not.

**Preparation earned its own instruction budget**, which §8 always specified and steps 1
through 4 had no phase to spend it in. A zero `prepare_instruction_limit` still means "one
budget for both", so a zeroed C config is valid; the Zig `Config` defaults it to §8's
1,000,000. The step-1 runaway test now names both, because with only the update budget named
it would have stopped a preparation at a limit it was no longer being given.

**Diagnostics are structured, not scraped.** Every failure carries a `FoundryScriptCategory`
a host can branch on and the source line when Lua knew one. The category comes from the
failure kind when the bridge already knows it and otherwise from the leading token every
raise in `bridge.c` and `binding.c` already wrote; `limit` maps onto `native_work_limit`
rather than becoming a category §13 does not name. Reading the line at all is why chunks are
now compiled under a `=`-prefixed name: Lua then spells the name literally instead of
wrapping it in `[string "..."]`, and the parse is exact rather than a guess at a delimiter.

**§13 asks for a logical source filename and this step cannot give one.** The public ABI
publishes a script's bytes and its revision, not the path they were read from, and adding a
call for it would be a public ABI design rather than a lifecycle step. So a diagnostic names
the package and the **entry record's own spelling**, which the manager reads out of content
through `content_find` and `record_name` — the same calls a script reads content with, and
the reason no `entry_name` had to be added to the descriptor §3 specifies. A filename, if it
is ever worth having, is the ABI's to publish.

**Ownership of the four pieces is the application's, and the sandbox is now the reference
for that.** `samples/sandbox/scripting.zig` registers the source loader, binds an `abi.Host`
over the sample's own engine and world, issues one identity per package and holds the
manager; it is the only file in the sample that names `abi` or `script`, and the
`mod.Entry` → `script.Descriptor` conversion lives there because that is the code that owns
both. A build without the pinned Lua gets `scripting_absent.zig`, which answers the same
calls and does nothing, so the sample still builds, loads and runs with no Lua linked at all.

**One sample-level limit, stated rather than papered over.** A manager belongs to one world's
lifetime (§3), and loading a save rebuilds the world. The sandbox therefore stops its scripts
once, with a log line saying why, instead of appearing to run while nothing calls them.
Reactivating across a world swap would need a lifecycle M8 has not specified — it consumes a
fresh ABI system slot per swap and has to decide what a script owns in a world it never saw
— and inventing one here would be the wrong place to decide it.

The scripted encounter is `samples/sandbox/content/scripts/encounter.lua`: it reads
`sandbox:encounter.main` at load, keeps its interval and its owned entities in state, lights
four beacons around the world origin half a second apart and then puts them out. The beacons
are content — a transform, a visual and a `foundry:entity` each — because binding 1 cannot
write a component, so *where* they are and what they look like is the package's and the
script only decides when. In a headless null run their sprites appear in the frame's own
batch count and disappear again, which is the claim "visible fixed-tick behavior driven by
an ordinary script package" reduced to a number a test could read.

**Verified by breaking each new guard in turn**, restoring the exact edit each time:
accepting an unrecognised lifecycle field failed the module-shape test; letting a state table
be reached twice failed the state-tree test; publishing a slot whether or not the world took
its system failed the capacity test; never releasing a source reference failed the teardown
test; and accepting any binding version failed the binding test. The suite is **1187
declared, 1179 headless** after the documented 8 Metal-only tests, and the full AGENTS.md §3
bar passes on the host, `x86_64-linux-gnu` and `x86_64-windows-gnu`, with both samples. The
public ABI did not change, so `foundry.h` is byte-for-byte what step 3 left.

What step 5 deliberately does **not** do: no reload. Nothing polls a source revision, nothing
snapshots state, nothing migrates and nothing swaps a VM. The state validation written here
is the *shape* check §10 asks for at `init`, not the copy step 6 owes, and `migrate` is
validated as a field and never called.

## Resolution — 2026-09-12, step 6

A package's code can be replaced while its world, its state and its entities stay. The
transaction §12 describes is `script.Manager.pollReload`, and everything before its last
step builds a complete replacement beside the running one: a failure at any point leaves the
VM, the state, the ledger, the registration and the world exactly as they were. The commit
moves a `Runtime` value into the slot and closes the old one — no allocation, no script code
— and the next fixed tick runs the replacement.

**State crosses as bytes, because two VMs share no heap.** `foundry_script_snapshot_state`
writes the bounded value tree of §11 into a caller buffer (a NULL buffer measures instead,
the same sizing probe `script_source_copy` has); `restore_state` reads one back as the new
VM's state when the state version is unchanged, and `migrate_state` reads it back as a plain
table, hands it to `migrate(old_state, old_version)` and validates what comes back. The tree
carries no version and no header: it never leaves the process, and durable script saves stay
§15's first open question rather than being answered by accident here.

**The walk that writes the tree is also the last check that the state is still state.** An
`update` may put a function, a cycle, an alias or a foreign entity into a table `init` handed
over clean, and §11's rules are enforced at the moment the state is asked to move rather than
only when it was made. A state that cannot be written is a package that cannot be replaced —
which is exactly §12's "explicit host restart", said at the point where it is still useful.
Keys are written in §9's order, so the same state produces the same bytes on any machine and
in any run; a test builds one table two ways and compares the bytes.

**A fault snapshots before it closes the VM, and that is a decision step 6 had to make.**
§12 says a faulted package may attempt replacement on a new revision, and forbids calling
`init` over a world the package has already changed. A faulted VM is gone, so the only honest
thing to hand its replacement is the state the fault left behind: the slot keeps it, bounded
by §8's own state limit and charged to the aggregate budget, and drops it the moment a VM
holds the state again. The result is the loop an author actually has — a script errors, the
error names the line, the file is fixed, and the next poll resumes from where it stopped.

**A package that never registered is re-activated, not replaced.** It has no state, no owned
entities and no system, so what a fixed source earns it is the activation that failed, `init`
included — which is not "init over an existing world" for a package that has never run. Its
source reference was released with everything else a failed startup took (§10), so the
revision probe acquires, asks and releases rather than quietly holding one on its behalf.

**Two smaller things the implementation decided.** A refused *replacement* is logged at
warning level and says "the last working version is still running", because a package that is
still running is not an error — `core.log`'s own definition of the two levels is the whole
argument, and a fault that disables a package still logs at error. And the diagnostic of a
candidate carries the *candidate's* line, not the running VM's, which is a different VM and a
different error.

**Content reload is independent, and now says so in three places**: `pollReload`'s own
documentation, a fake-host test in which content moves under a script whose replacement is
refused and the old code goes on reading the new content, and the fact that nothing in the
transaction touches the store. A failed script replacement does not undo merged content, and
the old script must cope with a record that changed under it — the same obligation it already
had towards a package that overrode one.

**The sandbox needs no new key.** The engine already watches its content in a debug build and
re-reads what changed at the top of a frame, so the sample's fixed step polls before
`world.update` and editing `content/sandbox/scripts/encounter.lua` beside the executable is
the whole loop. A headless run of it is the runnable proof: beacons 1, 2 and 3 light on the
original code; the file is edited; the log says the package *is running new code*; the next
message is **beacon 4**, not beacon 1, so the state crossed and `init` did not run; the
following cycle destroys all four, including the three the previous VM spawned, so the ledger
and the handles in state crossed with it. Then the file is replaced with text that does not
compile, and the warning says the last working version is still running while the beacons
keep their cadence.

**Verified by breaking each new guard in turn**, restoring the exact edit each time: losing
the attempted-revision memo failed the refused-source test; running `init` instead of
carrying the state failed the state-crossing test; treating a changed state version as
unchanged failed the no-migrate test; not closing the replaced VM failed the repeated-reload
test's memory assertion (and leaked 2,896 allocations); re-activating instead of replacing
failed both real-world reload tests by registering a second system; accepting a value the
snapshot cannot persist failed the corrupted-state test; and running `migrate` as an update
failed the preparation test. The suite is **1200 declared, 1192 headless** after the
documented 8 Metal-only tests, and the full AGENTS.md §3 bar passes on the host,
`x86_64-linux-gnu` and `x86_64-windows-gnu`, with both samples. The public ABI did not
change, so `foundry.h` is still byte-for-byte what step 3 left.

What step 6 deliberately does **not** do: the adversarial matrix of §14 — allocation failure
at every point of snapshot and migration, the escape attempts, the determinism scenarios and
the windowed recovery — is step 7's, and no part of it was claimed early. Nor does anything
here make a script's state durable across a process restart: §15's first question stays open,
and the snapshot is not a save format.

## Resolution — 2026-09-12, step 7

The §14 matrix is complete. Exhaustive allocation-index injection now covers snapshot and
migration in addition to step 1's bootstrap/compile/invocation/teardown paths; every refused
operation returns a memory-limit status, retains no new aggregate charge and leaves a usable
VM or old package. The runtime cases cover forbidden globals, protected-call and library/
metatable escape attempts, bounded `pairs` and string helpers, recursion, runaway execution,
heap exhaustion, oversized state, functions in state, NaN and both infinities. A separate
executable runs the three cases that could hang or exhaust their test process as children
under a three-second awake-clock deadline. That deadline is a test-harness backstop only and
does not enter simulation or change §8's bounded-work policy.

One defect was found by the matrix: bounded base-library helpers emitted the
`native_work_limit` diagnostic token but left the bridge's failure kind at generic runtime,
so the host received `RuntimeFailed` rather than `NativeWorkLimit`. The helpers now set the
native-work failure before raising, preserving §13's structured category. This changes no
public ABI and adds no Lua capability.

Real-table/world tests prove two package VMs share neither globals, state, heap quota nor
entity ownership; a failure in one leaves both its next invocation and the other package
healthy. Two fresh worlds driven through twelve identical fixed ticks with different frame
pacing produce byte-identical state snapshots, identical entity-handle action sequences and
the same error category/line. The real asset/manager path refuses missing and escaping
symlinked source without advancing the running revision, continues the old code, and accepts
the next confined regular-file revision.

The sample's new measurements are private host diagnostics: no public table changed, Lua
cannot read them and simulation does not branch on them. Its 2,918-byte script reached about
34 KiB peak VM heap and 54 KiB peak aggregate memory during the live bad-edit/recovery run;
the busiest invocation used 100 metered update instructions, 22 ABI calls, one spawn and one
log. These are well below every applicable §8 default, so **no default is adjusted**.

The windowed proof edited only the installed source. Invalid text produced its record, line,
phase and syntax category while the old VM kept the beacon cadence and the window and controls
remained live; restoring the confined file logged that the package was running new code and
the same world continued to a clean bounded exit. Deliberately disabling the instruction hook
made the child harness reach its deadline, and deliberately changing bounded-native-work to a
generic runtime category failed the exact status assertion; both edits were restored. The full
bar passes with **1,207 declared / 1,199 headless tests**, host/Linux/Windows compilation and
both null-backend samples. The remaining step is the independently executed outside-tree
author guide; it has not begun.

## Resolution — 2026-09-12, step 8

The author exit criterion was executed rather than described. A script package — manifest,
content, one `.lua` — was written in a directory outside this repository, compiled by the
installed `fpack`, installed as a `.fpk` and its own directory beside it, and enabled by
content ID in the shipped sandbox. It ran beside the sandbox's own script package and was then
edited, migrated to a new `state_version`, broken and repaired while it ran.
`docs/modding/script-mods.md` is that guide.

**The sandbox is a script-capable host, and that changed what step 8 could be.** M7's native
guide had to tell an author to write a host, because the sandbox binds no native loader. Tier 2
needs no such caveat: the sample publishes its subsystems through the public ABI, registers the
source loader and runs up to four script packages, so an author's first script mod runs in the
program this repository ships. That is I3 for Tier 2 — the path we are on ourselves is the path
the author is on — and it is why the guide's every command is one a reader can run.

**The guide was verified by rebuilding the package from its own listings.** `mod.fdt`,
`wisp.fdt` and `main.lua` were extracted from the page, the migrated module was assembled from
§7 exactly as that section describes, and the commands in §4 and §5 were run again from a clean
install. The result reproduced the first run line for line: the same 2,070-byte `.fpk`, the same
first-run output, the counter continuing at 13 across the edit and at 26 across the migration,
the same warning naming the same source line, and the same recovery. Every output block on the
page is from that second run, so the page cannot drift from the behaviour it documents without
a test of the rebuild failing.

One measurement artifact is worth recording, because it will otherwise be read as a defect. The
instruction counter advances by `hook_period` at each hook, so a reported peak is quantized to
100 and a preparation that executes fewer than 100 VM instructions reports zero. Metering and
enforcement are unaffected — a runaway is stopped at the next hook — but the *reported* number
is a lower bound rounded down, not an exact count.

Nothing was decided here and no engine code changed: step 8 is documentation and an execution
record. §15's six open questions are all still open, durable script state first among them.
M8 is complete.
