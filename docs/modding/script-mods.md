# Script mods

**Status:** Tier 2 works as of M8, 2026-09-12. A script mod is a content package with one Lua
file in it. The file runs in its own restricted VM ([ADR-0028](../adr/0028-scripting-lua.md)),
reaches the engine only through the same public ABI table a native mod is handed
([ADR-0029](../adr/0029-script-host-and-reload.md)), spends a bounded amount of memory,
instructions and engine calls, and **can be replaced while the game is running** without the
world, its state or the entities it owns being disturbed. A script that faults is disabled with
an explanation; it does not take the host down with it.

This page is an author guide, not a second specification — the design is
[`design/scripting.md`](../design/scripting.md). The example below was written by doing it: an
ordinary package in a directory outside the Foundry checkout, compiled with the installed
`fpack`, loaded by the shipped sandbox, then edited, migrated, broken and fixed while it ran.
Every line of output quoted here was produced by that run.

For the data-only tier see [`content-mods.md`](content-mods.md); for the unsandboxed C tier see
[`native-mods.md`](native-mods.md).

---

## Before you start

You need:

* a checkout of Foundry and its pinned Zig 0.16.0 toolchain; and
* a host that runs scripts. **The sandbox is one**, so unlike Tier 3 you do not have to write
  your own. It publishes its subsystems through the public ABI, registers the script source
  loader and runs up to four script packages: its own, and three of yours.

You do not need a compiler, an SDK, or a line of engine source. The code you write is one text
file, and the engine reads it at runtime.

## 1. What a script package is

The same directory a content mod is, with two additions: the manifest says the package carries
a script, and one `.lua` file is its entry.

```
wisp/
  mod.fdt          # what the package is called, and that it has a script
  wisp.fdt         # the content the script reads and the templates it spawns
  scripts/
    main.lua       # the entry chunk
```

`mod.fdt`:

```fdt
foundry:mod  wisp:content {
    name     "Wisps"
    version  1
    license  "MIT"
    # `sandbox:content` is here because this package builds entities out of the component
    # types that host registered. `foundry:core` is package zero and always underneath.
    requires [ { id foundry:core }  { id sandbox:content } ]
    # The ABI versions the script was written against, and which Lua surface it expects.
    abi      { min 2  max 2 }
    script   { entry wisp:scripts.main  binding 1 }
}
```

Three things about those last two lines:

* **`abi` is the API-table version, not a Foundry release number.** A script needs v2, because
  v2 is the table that can hand the host your source. A package whose range does not intersect
  what the host offers is reported and its code is not run — its content still loads.
* **`entry` is a content ID, not a path.** `scripts/main.lua` derives `wisp:scripts.main` by the
  ordinary rule ([`content-mods.md` §5](content-mods.md)), so the two agree here without either
  of them being a filename. Write a `foundry:script` record yourself if you want a different ID
  or a different path; the derived one is a convenience, not the definition.
* **`binding 1` is which Lua surface you expect**, and M8 has exactly one. It is separate from
  the ABI range on purpose: the table underneath can grow a version without changing what a
  script is allowed to call.

A manifest that names **both** `script` and `native` is refused for code activation and keeps
its content. Sandboxed and unsandboxed code in one package would make the label meaningless,
so the two tiers stay one per package.

## 2. Decide what is content and what is code

Binding 1 can read content, look at the world, spawn a template it was pointed at, and remove
what it spawned. It cannot write a component, move an entity, draw anything, read a clock or
open a file. That is not a gap to work around — it is the split that makes a script mod safe to
install, and it means **the script decides *when*, and content decides *what* and *where*.**

`wisp.fdt`:

```fdt
# The component types belong to the host, so their schemas are copied from it, spelled in
# full and field for field. A script can only spawn a template made of types the host
# registered; these two are what the sandbox registers.

@schema sandbox:transform {
    x f32
    y f32
    rotation f32
}

@schema sandbox:visual {
    size f32
    cell u32
    tint { r f32  g f32  b f32  a f32 }
    additive bool
    layer i32
}

# What the script may decide is when. Where the wisps are and what they look like is here.

@schema wisp:tuning {
    interval i64
    lights   [id]
}

wisp:tuning wisp:tuning.main {
    interval 8
    lights   [ wisp:light.left  wisp:light.right  wisp:light.high ]
}

sandbox:transform wisp:at.left  { x -70  y  30  rotation 0 }
sandbox:transform wisp:at.right { x  70  y  30  rotation 0 }
sandbox:transform wisp:at.high  { x   0  y  80  rotation 0 }

sandbox:visual wisp:look.left  { size 12  cell 3  tint { r 0.55 g 1.0  b 0.8  a 1 }  additive true  layer 6 }
sandbox:visual wisp:look.right { size 12  cell 3  tint { r 0.8  g 0.85 b 1.0  a 1 }  additive true  layer 6 }
sandbox:visual wisp:look.high  { size 16  cell 3  tint { r 1.0  g 0.95 b 0.6  a 1 }  additive true  layer 6 }

foundry:entity wisp:light.left  { components [ wisp:at.left   wisp:look.left  ] }
foundry:entity wisp:light.right { components [ wisp:at.right  wisp:look.right ] }
foundry:entity wisp:light.high  { components [ wisp:at.high   wisp:look.high  ] }
```

**You can only spawn templates made of component types the host registered**, and the host has
to be able to build them from content — a type a *native* mod registered through the ABI has no
deserializer in M8 and is refused by the spawn preflight rather than half-built. `interval` is
in **ticks**, not seconds, because this is simulation and simulation counts steps.

## 3. Write the script

The entry chunk returns a table, and exactly four field names are recognized:

```lua
return {
    state_version = 1,
    init  = function() return { next_tick = 1 } end,
    update = function(state, step) end,
    -- optional: migrate = function(old_state, old_version) return new_state end
}
```

A misspelled lifecycle field is diagnosed rather than ignored. Here is the whole of
`scripts/main.lua`:

```lua
-- wisp:scripts.main -- the package's entry chunk.
--
-- Top-level evaluation is preparation: it may read content and may not change the world.

local tuning = foundry.content_find("wisp:tuning.main")
local interval = foundry.record_get_i64(tuning, foundry.record_field_index(tuning, "interval"))

local lights = foundry.record_field_index(tuning, "lights")
local templates = {}
for i = 0, foundry.record_list_len(tuning, lights) - 1 do
    -- List indices are the ABI's and count from zero; Lua arrays count from one.
    templates[i + 1] = foundry.record_list_get_id(tuning, lights, i)
end

return {
    state_version = 1,

    init = function()
        return { next_tick = interval, lit = 0, total = 0, owned = {} }
    end,

    update = function(state, step)
        if step.tick < state.next_tick then return end
        state.next_tick = step.tick + interval

        if state.lit < #templates then
            local made = foundry.world_spawn(templates[state.lit + 1])
            -- Absence is a value: a template a later package removed is `nil`, not a crash.
            if made == nil then return end
            state.lit = state.lit + 1
            state.total = state.total + 1
            state.owned[state.lit] = made
            foundry.log_write("info", "wisp " .. tostring(state.lit) ..
                " lit (" .. tostring(state.total) .. " so far)")
        else
            -- Only what this package spawned, because that is all it is allowed to remove.
            for i = 1, state.lit do
                foundry.world_destroy_entity(state.owned[i])
                state.owned[i] = nil
            end
            state.lit = 0
            foundry.log_write("info", "wisps out")
        end
    end,
}
```

Four rules this example is built on, and every one of them will bite you if you ignore it:

1. **Top-level code, `init` and `migrate` are *preparation*.** They may use the pure helpers and
   read content. They may not change the world, and they may not log — a log line is a live
   effect, and preparation happens outside the tick. Only `update` may do either.
2. **Everything that must survive a reload lives in `state`.** Upvalues like `interval` and
   `templates` above are rebuilt from content when the code is replaced, which is exactly what
   you want for them. A counter kept in an upvalue would silently reset.
3. **Field and list indices are the ABI's, and the ABI counts from zero.** Lua arrays count from
   one. Neither is converted behind your back, because a convenience conversion here is a
   different specification every tool would have to reimplement identically.
4. **`step` carries `tick` and `delta_ns`, and nothing else.** There is no clock to read. Two
   runs of the same ticks produce the same result no matter what the frame rate did (I9).

There is one file. `require`, `load` and `dofile` do not exist — factor with local functions
inside it. Multiple modules and cross-package imports are a recorded open question, not an
oversight ([`scripting.md` §15](../design/scripting.md)).

## 4. Compile it and install it

From the Foundry checkout, build once so the tools and the content directory exist:

```sh
FOUNDRY_ROOT="/absolute/path/to/Foundry"
MOD_ROOT="/absolute/path/to/wisp"
cd "$FOUNDRY_ROOT"
zig build
```

Compile the package, then copy its files in beside the result:

```sh
zig build fpack -- --out zig-out/content/wisp.fpk "$MOD_ROOT"
cp -R "$MOD_ROOT" zig-out/content/wisp
```

```
fpack: wisp:content version 1 -> zig-out/content/wisp.fpk (2070 bytes)
```

The `.fpk` and the same-stem directory beside it are a pair, exactly as they are for a mod with
textures: the compiled records are in the file, and the files the records name are read from the
directory. **Your `.lua` is one of those files.** It is not compiled into the package, it is not
parsed by `fpack`, and `fpack` links no Lua — which is why a content-only host can load your
package and simply not run its code.

## 5. Run it

The host is handed content IDs, not filenames:

```sh
FOUNDRY_SANDBOX_PACKAGES=wisp:content zig build run -Drhi=metal
```

Headless, for a run you can read afterwards:

```sh
FOUNDRY_SANDBOX_PACKAGES=wisp:content FOUNDRY_SANDBOX_FRAMES=400 \
  zig build run -Dplatform=null -Drhi=null
```

```
debug(mod): found wisp:content version 1 in wisp.fpk
info(sandbox): enabling 'wisp:content'
info(sandbox): load order: foundry:core version 1
info(sandbox): load order: sandbox:content version 1
info(sandbox): load order: wisp:content version 1
debug(scene): system 'wisp:content' registered at position 3
info(sandbox): scripts: 2 of 2 package(s) running
info(mod): [wisp:content] wisp 1 lit (1 so far)
info(mod): [wisp:content] wisp 2 lit (2 so far)
info(mod): [wisp:content] wisp 3 lit (3 so far)
```

Two packages, two VMs. The sandbox's own script and yours share no globals, no state, no heap
quota and no entity ownership; one of them failing does not spend the other's budget or stop its
next update. Your package became **one system**, registered in resolved load order, driven by
the world's own fixed tick. `[wisp:content]` is the log scope — your package's own name — so
your lines are yours.

## 6. Edit it while it runs

Leave that running and edit the **installed** copy, `zig-out/content/wisp/scripts/main.lua`. A
development build watches what it loaded, and the next tick runs the new code:

```
info(mod): [wisp:content] wisp 3 lit (12 so far)
info(mod): [wisp:content] wisps out
info(asset): reloaded 'wisp:scripts.main'
info(sandbox): 'wisp:content' is running new code (1 reload(s) in)
info(mod): [wisp:content] wisp 1 lit (13 so far, edited live)
```

**Thirteen, not one.** `init` did not run again, your `total` kept counting, and the entities the
old code had spawned are still yours. That is the whole point of the transaction underneath:

* your new source is compiled into a **candidate VM built beside the running one**;
* your old state is written out as a bounded tree of values and read back into the candidate;
* everything up to that point may fail, and failing changes nothing at all; and
* the commit that swaps them allocates nothing and runs none of your code.

What you get back after a reload is your state and your entities. What you *do not* get back is
anything you left in a global or an upvalue — those are rebuilt by running the new chunk, which
is how `interval` picks up a content change without you writing a line for it.

## 7. When the shape of your state changes

Rename a field or add one and the old state no longer fits the new code. Say so with
`state_version`, and provide the function that converts:

```lua
return {
    state_version = 2,

    init = function()
        return { next_tick = interval, lit = 0, lit_total = 0, cycles = 0, owned = {} }
    end,

    -- Preparation, like the chunk itself: it may read, and it may not change the world or
    -- log. It is called instead of `init` when the state that crossed was written by an
    -- older version, and what it returns is checked exactly as `init`'s result is.
    migrate = function(old, version)
        local carried = {
            next_tick = old.next_tick or 0,
            lit = old.lit or 0,
            lit_total = old.total or 0,
            cycles = 0,
            owned = {},
        }
        -- The entities the old code spawned are still this package's. Carry the handles or
        -- the new code will not know which ones to put out.
        for i = 1, carried.lit do carried.owned[i] = old.owned[i] end
        return carried
    end,

    update = function(state, step) --[[ §3's update, changed as described below ]] end,
}
```

The rest of the file is §3's, with `total` renamed to `lit_total`, a
`state.cycles = state.cycles + 1` in the branch that puts the wisps out, and both log lines
naming the cycle:

```lua
foundry.log_write("info", "wisp " .. tostring(state.lit) ..
    " lit (" .. tostring(state.lit_total) .. " so far, cycle " ..
    tostring(state.cycles) .. ")")
-- and, in the other branch:
foundry.log_write("info", "wisps out (cycle " .. tostring(state.cycles) .. ")")
```

Saving that produced:

```
info(mod): [wisp:content] wisp 1 lit (25 so far, edited live)
info(asset): reloaded 'wisp:scripts.main'
info(sandbox): 'wisp:content' is running new code (2 reload(s) in)
info(mod): [wisp:content] wisp 2 lit (26 so far, cycle 0)
info(mod): [wisp:content] wisp 3 lit (27 so far, cycle 0)
info(mod): [wisp:content] wisps out (cycle 1)
```

The counter continued at 26, the sequence continued at wisp 2, and the "wisps out" that followed
destroyed an entity **the previous VM had spawned**. Three rules worth knowing:

* **A changed `state_version` without a `migrate` refuses the replacement.** There is no implicit
  reset, because silently starting over is indistinguishable from working until you look at what
  the world already contains.
* **`migrate` is preparation.** Build and return the table; do not log from it and do not touch
  the world. The result is validated exactly as `init`'s is, and a version it does not recognise
  is yours to handle — `old_version` is the second argument for that reason.
* **Only values that can persist cross.** Nil, booleans, integers, finite numbers, strings,
  tables keyed by integers or strings, content IDs, schema IDs, unsigned values, an RNG's state,
  and entity handles **this package still owns**. A function, a record, a cursor, a cycle or a
  repeated table reference is refused — and refusing means the old code keeps running, not that
  your state is lost. Records and cursors are scoped to the invocation that made them anyway;
  reacquire them by content ID.

Ownership does not come from your state: the ledger belongs to the package, so a handle you
forget to carry does not free the entity, and a handle you fabricate does not acquire one.

## 8. Break it on purpose

Delete an `end` and save. The engine re-read the file, tried to build a candidate, and refused
it:

```
info(asset): reloaded 'wisp:scripts.main'
warning(mod): [wisp:content] wisp:content / wisp:scripts.main:38 — load, tick 0: syntax —
load: 'end' expected (to close 'function' at line 25) near 'update'. The last working
version is still running; fix the source and reload it.
info(mod): [wisp:content] wisp 2 lit (38 so far, cycle 4)
```

The next line is the beat that was already due. Nothing skipped, nothing reset, nothing lost —
and it is a **warning**, not an error, because a package that is still running is not a failure.
Saving the fixed file recovered it:

```
info(asset): reloaded 'wisp:scripts.main'
info(sandbox): 'wisp:content' is running new code (3 reload(s) in)
```

Read a diagnostic left to right: your package, the entry ID, the file and line, the phase
(`load`, `init`, `update` or `migrate`), the tick it happened on for an update, then a **stable
category** and what to do about it. Branch on the category, not on the sentence:

| Category | What it means |
| --- | --- |
| `syntax` | The source did not compile. |
| `contract` | The module is not the shape §3 requires — a missing `update`, a misspelled field, a bad `state_version`. |
| `invalid_argument` | A binding was called with something it cannot accept. |
| `stale_handle` | A handle outlived what it named, or an invocation it was scoped to. |
| `unavailable` | The host has no such capability, or the call is not in binding 1. |
| `instruction_limit` | One invocation executed too many instructions. |
| `memory_limit` | The VM or the shared aggregate ran out of its budget. |
| `native_work_limit` | A single bounded helper was asked to do too much at once. |
| `migration` | `migrate` failed, or a version changed without one. |
| `source_rejected` | The source was too large, not valid UTF-8, or not a confined file. |

**A refusal and a fault are different.** A replacement refused before the commit leaves the old
code running and warns. An error *inside* a live `update` faults that package: it is disabled
and logged at error level, whatever that update already did to the world stays done, and the
state as of the fault is kept so a later revision of your source can pick it up. Broken text is
compiled once per revision, not once a frame, so a file you left mid-edit costs one message.

## 9. The `foundry` module

Binding 1, forty calls. The names are the ABI's, so what you learn here reads the same in
`foundry.h`.

| Group | Calls |
| --- | --- |
| Identity | `id_from_string`, `id_to_string`, `schema_id` |
| Randomness | `rng(seed, stream)` → an object with `next_u32()` |
| Logging | `log_write(level, text)` — `"error"`, `"warn"`, `"info"`, `"debug"`, `"trace"` |
| Content walks | `content_generation`, `content_find`, `content_next`, `content_next_of_schema` |
| Record identity | `record_id`, `record_name`, `record_schema`, `record_package` |
| Fields | `record_field_count`, `record_field_index`, `record_field_name`, `record_field_type`, `record_field_present` |
| Reads | `record_get_bool`, `record_get_i64`, `record_get_u64`, `record_get_f32`, `record_get_string`, `record_get_id`, `record_nested` |
| Lists | `record_list_len`, `record_list_get_i64`, `record_list_get_f32`, `record_list_get_string`, `record_list_get_id`, `record_list_nested` |
| World reads | `world_contains`, `world_entity_count`, `world_next_entity`, `world_find_component_type`, `world_has_component`, `world_read_component` |
| World changes | `world_spawn(template_id)`, `world_destroy_entity(entity)` |

`record_field_type` answers `"bool"`, `"i32"`, `"i64"`, `"u32"`, `"u64"`, `"f32"`, `"f64"`,
`"string"`, `"id"`, `"list"` or `"nested"`.

Three conventions run through all of it:

* **Absence is a value, a mistake is an error.** A record that is not there, an iteration that
  has ended, a capability the host does not have: `nil, "not_found"` — check it and carry on.
  A malformed argument, a stale handle, an entity you do not own or an exhausted budget raises
  instead, and the host catches it.
* **A call with nothing to return gives you `true`**, so `if not foundry.world_destroy_entity(e)`
  is never ambiguous.
* **Handles are opaque.** IDs, entities, schema IDs, records, cursors and RNGs are userdata you
  can compare, store where the rules allow and pass back. You cannot build one from a number, and
  a record or cursor belongs to the invocation that produced it.

## 10. The rest of the environment

Built by allowlist, not by opening the standard library and deleting from it.

| Available | |
| --- | --- |
| Base | `assert`, `error`, `type`, `select`, `tonumber`, `tostring` (scalars and Foundry's own values only), `ipairs`, `pairs` |
| `math` | `abs`, `ceil`, `floor`, `min`, `max`, `sqrt` |
| `string` | `len`, `sub`, `byte`, `char`, `lower`, `upper` |

**Absent, deliberately:** `io`, `os`, `package`, `debug`, `coroutine`, `load`, `loadfile`,
`dofile`, `require`, `pcall`, `xpcall`, `collectgarbage`, `next`, `rawset`, `getmetatable`,
`setmetatable`, `_G`, string patterns, `string.format`, `string.rep`, `table`, and every native
plugin mechanism. There is no `math.random`: use `foundry.rng(seed, stream)`, whose state is a
value your script owns and can carry through a migration, so a replay is a replay.

`pairs` is Foundry's, not Lua's: it collects integer and string keys, walks integers ascending
and then strings by byte order, and refuses a table with more than 1,024 keys or a key that is
neither. That is I9 — a documented iteration order wherever order affects outcomes — and it is
why two runs of your mod agree.

## 11. What it costs, and what it may cost

Per package, per VM, per tick:

| Bound | Limit |
| --- | --- |
| Source | 256 KiB, one file |
| Lua heap | 8 MiB, including compilation and strings |
| All script memory in the host | 160 MiB, source and candidate VMs included |
| Instructions per `update` | 100,000 |
| Instructions per preparation or migration | 1,000,000 |
| Engine calls per tick | 2,048 |
| A string a binding returns or is given | 16 KiB |
| Persistent state | 64 KiB, depth 16, 1,024 entries |
| Entities owned at once | 256, and at most 8 spawns per tick |
| Log lines per tick | 8 |
| Enabled script packages | 16 (the sandbox runs 4) |

For scale: the package on this page is 2,654 bytes of source, peaked at **34,917 bytes** of VM
heap, and its busiest update spent 100 metered instructions, 22 engine calls, one spawn and one
log. Two packages running together, through three reloads with a candidate VM in flight, peaked
at **89,844 bytes** of the 160 MiB aggregate. You are unlikely to meet any of these limits by
accident; a runaway loop meets the first one immediately, which is the point.

A host may lower any of them. Nothing a mod writes can raise one.

## 12. What is not built yet

* **Script state does not survive the process.** It crosses a reload; it is not a save format,
  and it has no on-disk representation. Keep anything that must outlive a session in content.
* **One file per package.** No `require`, no importing another package's code.
* **Packages cannot be enabled or disabled while the game runs.** Changing the manifest, the
  binding, the enabled set or the dependency graph means restarting the host. Editing source and
  migrating state is the supported loop, and that one works.
* **Binding 1 is deliberately small.** No component writes, no input, no rendering, no UI, no
  audio, no collision queries. Each of those is a decision about what the public ABI should
  publish first, not a Lua problem: a capability becomes public before it becomes script-callable.
* **Sandboxing is a fault boundary, not a security boundary.** It contains a script's mistakes —
  runaway loops, memory, bad handles, errors — and it does not make an unknown defect in the
  native runtime underneath into someone else's problem. Install code you trust.

## 13. M8 verification record

This guide was executed on 2026-09-12 from a directory outside the Foundry checkout, using only
the installed toolchain and the shipped sandbox. The durable commands were:

```sh
cd "$FOUNDRY_ROOT"
zig build
zig build fpack -- --out zig-out/content/wisp.fpk "$MOD_ROOT"
cp -R "$MOD_ROOT" zig-out/content/wisp
FOUNDRY_SANDBOX_PACKAGES=wisp:content FOUNDRY_SANDBOX_FRAMES=12000 \
  zig build run -Dplatform=null -Drhi=null
```

During that run the installed `scripts/main.lua` was replaced four times: with new code at the
same state version, with a `state_version 2` module and its `migrate`, with text that does not
compile, and with the working version again. The run logged the reload, the carried counter, the
migration, one warning naming the file and line, and the recovery — then exited cleanly after
12,000 frames and 720 ticks with no error-level line. The package was also loaded beside the
sandbox's own script package throughout, and neither could see the other's globals, state, quota
or entities.

The guide was then verified the way it is meant to be used: the package was rebuilt in a fresh
directory **from the listings on this page alone** — `mod.fdt`, `wisp.fdt` and `main.lua` taken
from §§1–3, and the migrated module assembled from §7 exactly as it describes — and the commands
above were run again from a clean install. It reproduced the run line for line: the same 2,070-byte
`.fpk`, the same §5 output, the counter continuing at 13 across the edit and at 26 across the
migration, the same warning naming line 38, and the same recovery. Every output block on this
page is from that second run.

The automated equivalents live in `engine/tests/script_bindings.zig` (a package's code replaced
while its world, state and entities stay; source that does not compile leaving the running
package exactly as it was; two packages isolated; two runs agreeing across different frame
pacing) and `engine/src/script/manager_tests.zig` (the reload transaction, migration, fault
recovery and repeated reload beyond slot capacity).

## Rules worth keeping visible

* **The script decides when. Content decides what.** Anything a player might want to change
  without editing code belongs in a record.
* **State is what survives; upvalues are rebuilt.** Write the line in `init`, not at the top of
  the file, if it must still be true after a reload.
* **Ticks, never seconds.** `step.tick` is the clock you have, and it is the same on every
  machine.
* **Absence is a value.** A content ID that resolves to nothing gives you `nil`, because a mod
  further down the load order is allowed to remove things.
* **You own what you spawned, and only that.** `world_destroy_entity` refuses anything else.
* **A failed reload changes nothing.** You never get a half-replaced package, and you never get
  a hole.
