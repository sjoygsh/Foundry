# Scripting: the Tier 2 host

**Status:** designed 2026-09-09; **0 of 8 implementation steps complete.**
**Stop point for this planning session:** before §16 step 1. No dependency or code installed.

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

The current derivation in `tools/fpack/pack.zig` emits only `source`; step 2 must extend
the script-kind emission to include `language "lua-5.5"`. Merely adding `.lua` to the
extension table is insufficient. Test both derived and explicitly authored records.

Append optional **`script`**, `since = 2`, to `foundry:mod` and raise that schema to version
2. Its nested fields are `entry: id` and `binding: u32`, both required when present.
M8 accepts binding 1. Keep every existing field unchanged. V1 packages remain readable;
absent script means exactly today's behavior. Update the test that currently assumes all
manifest fields have `since = 1`; do not remove version checking.

Illustrative authoring record (validated against actual syntax in step 2):

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

**Containment before publication:** lexical `..` rejection is insufficient. The new source
read must reject escaping symlinks/reparse points using a root-relative confined open (or
reject symlink components entirely), through `platform.Os`. Validate on the opened object,
not a `realpath` check followed by an unrelated open. No absolute machine path reaches a
script diagnostic. Cross-target compilation and adversarial host filesystem tests belong
to step 2. Do not claim the existing asset path check already establishes this guarantee.

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
2. **Make scripts ordinary package assets.** Add script schema/source loader, confined
   source reads, fpack derivation and manifest v2 metadata through discovery/resolution.
   Source revisions and override/refusal tests; neither fpack nor content-only hosts links
   Lua. Runnable result: compile/discover a script-bearing package and read its bounded
   source asset through an asset test host. Old packages still compile/load.
3. **Publish source through ABI v2.** Add the table and typed copy call, retain v1 exactly,
   update native version-range selection and install header agreement. Test a native C
   consumer reading the asset, both versions side by side, empty host, stale/provenance
   refusals and deliberate agreement breaks. Runnable result: an external C-shaped consumer
   reads a packaged script without engine types. No Lua gameplay yet.
4. **Bind bounded content and gameplay operations.** Implement §7's conversions and exact
   allowlist against fake and real ABI tables; stable iteration/RNG and entity ownership.
   Implement/check template preflight, aggregate/native memory policy and atomic spawn
   refusal. Runnable result: a protected script reads content and spawns/removes an entity
   through a fake-table test and a real null-world integration fixture. No package scheduler.
5. **Wire the package lifecycle.** Stable manager slots, issued identities, one system per
   package, activation/fault/teardown and diagnostics; integrate the minimal scripted
   encounter in the sandbox's own package. Support an opt-in host with no native loader.
   Test mixed packages, version failures, capacity and one script failing beside a healthy
   one. Runnable result: visible fixed-tick behavior driven by an ordinary script package.
6. **Replace code without replacing the world.** Implement snapshots, versioned migration,
   candidate validation, source revision polling and nonallocating commit. Test rollback,
   fault recovery and repeated reload beyond slot capacity. Runnable result: edit gameplay
   conditions live and retain state/entities, then introduce bad source and keep the old
   behavior. Document content-reload independence explicitly.
7. **Prove isolation and reproducibility end to end.** Complete the adversarial matrix in
   §14, guard-breaking evidence, bounded native-work/OOM paths, deterministic scenarios,
   source confinement and windowed recovery. Measure the default budgets with the runnable
   sample and record any justified adjustment before changing them. Runnable result: a
   deliberately broken mod beside healthy gameplay, with a useful error and working controls.
8. **Execute the author exit criterion.** Write `docs/modding/script-mods.md` by creating
   a package outside the engine tree, following it from installed tools to scripted gameplay,
   source edit, migration and intentional failure/recovery. Verify it independently by
   following the exact guide. Update indices/status/actual test count and mark M8 complete
   only with that evidence; commit/tag `m8`. Stop before M9.

## 17. Planning handoff

Architecture and sequence are written; runtime/build compatibility, security tests,
performance and guide execution are **unverified until their implementation steps**.
The next authorized implementation unit, when the user resumes, is §16 step 1 only.
Planning changes no Zig/C source, public header, dependency manifest or existing behavior.
