# The public API surface, and what a mod is

**Status:** implemented in full 2026-09-09. M7 complete.

Rests on [ADR-0004](../adr/0004-public-c-abi.md) (one versioned C ABI),
[ADR-0026](../adr/0026-abi-module-and-host.md) (where `abi` sits and who supplies its
subsystems) and [ADR-0027](../adr/0027-mods-are-content-packages.md) (a mod is a content
package). Those three settle *whether*, *where* and *what*; this settles *how*.

---

## 1. What this is, and what it is not

This is the specification for the boundary between Foundry and everything that is not Foundry:
native mods today, the scripting host at M8, external tools and the editor after that. I4 says
there is exactly one such surface, so this document is the only place a capability becomes
public.

**It is not a list of engine features.** Every capability published here already exists and is
already tested; what is designed here is the *crossing* — how a handle, a string, an error, an
iteration and a callback survive a C boundary that a compiled binary from outside this
repository is on the other side of. The engine work M7 actually requires is small and is §15.

**It is not the gameplay API's design.** `debug-overlay.md` §14 refused the overlay a mutation
path and said the mutation surface is the gameplay API, designed when the ABI is. That is now,
and §9 designs it — but only for the capabilities the six "what this exposes to mods" sections
already committed to. Nothing is published here because it happened to be reachable.

## 2. Two halves, and why they are one document

M7 has two shapes of work in it, and they look separable:

* **The table** — what a mod may call. `abi` at L5 (ADR-0026).
* **The lifecycle** — what a mod *is*, how it is found, in what order it loads, and how its
  code gets to run. `mod` at L2 plus a loader in `abi` (ADR-0027).

They are one document because the interesting decisions are exactly the ones that touch both. A
manifest that named a library the table could not receive would be two designs that only look
like one; a table handed to a mod before its content was merged would publish a store that is
about to change underneath it; and the phase in which a mod may register a component type is
decided by the load order, not by the table. §13 is where the two halves meet, and it is the
part to read first if only one part is read.

## 3. The entry point, and the only signature frozen forever

A native mod exports one required symbol:

```c
FOUNDRY_EXPORT int32_t foundry_mod_init(FoundryGetApi get_api, FoundryMod self);
FOUNDRY_EXPORT void    foundry_mod_shutdown(FoundryMod self);   /* optional */
```

with

```c
/* Returns a `const FoundryApi_vN *`, or NULL if this host does not offer version N. */
typedef const void *(*FoundryGetApi)(uint32_t version);
```

**This signature can never change**, because every compiled mod ever shipped is baked against
it, so the whole of the versioning problem has to be solvable without touching it. It is, and
the indirection is why.

**Why a query function rather than the table itself.** ADR-0004 says new versions are *added
alongside* rather than replacing, which means `FoundryApi_v1` is frozen forever and
`FoundryApi_v2` is a different struct. If `foundry_mod_init` took `const FoundryApi_v1 *`, a
host could never hand a v2-aware mod a v2 table without a second entry point, and mods and
hosts would drift into a matrix of entry points. With `get_api`, one host offers every version
it still supports and one mod asks for the newest it understands:

```c
const FoundryApi_v1 *api = get_api(1);
if (api == NULL) return FOUNDRY_ERR_UNSUPPORTED;   /* legible failure, not a crash */
```

A mod that supports two engine generations asks for 2, falls back to 1, and ships one binary.
A host that has dropped v1 returns NULL and the mod refuses itself with a message naming the
version it wanted — which is the failure mode this costs one indirection to buy.

`self` identifies the loaded mod for anything scoped to it: which package it came from, what
name its log lines carry, and what is unregistered if it ever becomes unloadable (§14). It is
an ordinary opaque handle.

`foundry_mod_shutdown` is resolved if present and called in reverse load order at engine
teardown. Optional, because a mod that allocates nothing owes nothing.

## 4. The table

`FoundryApi_v1` is a flat `extern struct` of function pointers, C layout, one entry per
capability, named `<module>_<verb>_<noun>`:

```c
typedef struct FoundryApi_v1 {
    uint32_t version;        /* 1 */
    uint32_t size;           /* sizeof(FoundryApi_v1) as the host built it */

    int32_t (*log_write)(FoundryMod self, int32_t level, FoundryStr message);
    int32_t (*content_find)(FoundryContentId id, FoundryRecord *out);
    int32_t (*world_create_entity)(FoundryEntity *out);
    /* ... */
} FoundryApi_v1;
```

**Flat rather than nested by module.** Nesting reads better at a call site and is what the eye
wants for a table of this size. It is refused because a nested substruct is a second thing that
is frozen forever, and additive growth is then either a new outer version for a change inside
one module, or nested pointers — which reintroduces the null check ADR-0026 spent a decision
removing. The prefix in the name carries the grouping at no cost.

**`version` and `size` lead the struct** even though `get_api` already establishes both. They
are for a case the query cannot reach: a crash dump on a player's machine, where the one thing
worth knowing is whether the mod was built against this header. Eight bytes, and every other
answer to that question involves asking the player to reproduce something.

**No function pointer in the table is ever NULL.** A capability whose subsystem the host did not
supply is present and returns `FOUNDRY_ERR_UNAVAILABLE` (ADR-0026). The table for a version is
one shape, always.

## 5. Types that cross

The rule the whole section serves: **nothing crosses whose layout Foundry does not state**, and
every stated layout is checked against the header on every target by a test (§17).

| C type | Layout | Notes |
| --- | --- | --- |
| `FoundryStr` | `{ const uint8_t *ptr; uint64_t len; }` | Byte-identical to a Zig `[]const u8`, so conversion is a cast. **Not NUL-terminated** — content strings are spans into a mapped package and always have been. UTF-8, validated on the way in. |
| `FoundryEntity`, `FoundryTexture`, `FoundryVoice`, … | `{ uint64_t bits; }` | One struct per handle type, so C's type system keeps the distinction `core.Handle(T)`'s phantom tag keeps in Zig. `Handle.bits()` is the packing and already exists for this. Zero is always the null handle. |
| `FoundryContentId` | `{ uint64_t hash; }` | FNV-1a 64 of the exact UTF-8 bytes, specified in `core-memory-and-handles.md` and re-specified in the header, because external mod tooling must be able to compute one without linking Foundry. |
| `FoundryCursor` | `{ uint64_t bits; }` | §7. |
| booleans | `uint8_t` | 0 is false, **any** nonzero is true on input; 0 or 1 on output. A `bool` whose C size is a platform question is not a type that crosses. |
| enums | `int32_t` with explicitly assigned values | Never a C `enum`, whose size is implementation-defined. Values are written down in a table and never derived from declaration order — the same rule `.fpk`'s tag bytes follow, for the same reason. |
| floats | `float` | `double` never crosses. I9 makes `f32` the simulation type and a `double` on this boundary would be an invitation to compute simulation state at a precision the engine does not use. |
| structs | `extern struct`, explicit padding | No bitfields, no unions, no anonymous members. Every one is `@sizeOf`- and `@offsetOf`-asserted against the header. |

**Pointer lifetime is one rule.** Every pointer the API hands out is **borrowed and valid only
until the mod returns control to the engine** — until the current callback or the current
`foundry_mod_init` returns. A mod that wants to keep a string copies it. Nothing the API returns
is ever freed by the mod, and no call in `_v1` transfers ownership in either direction, which is
the strongest form ADR-0004's "explicit ownership rules" can take: there is nothing to explain
per call because there is nothing to own.

This is affordable because it is already how the engine works — the frame arena exists, the
overlay's panels already read borrowed values with frame lifetime, and `MemoryReport` was
already made a snapshot rather than a pointer for exactly this reason. Where a value must
outlive the call, the API takes a caller-supplied buffer and a capacity and reports the length
it needed; that pattern appears in `_v1` in exactly two places (§9), and each is noted.

## 6. Result codes and validation

```c
typedef int32_t FoundryResult;
```

**Zero is success, positive is a non-error terminal condition, negative is an error.** That
split is what makes `while (next(...) == FOUNDRY_OK)` correct and `FOUNDRY_END` not an error.

| Value | Name | Means |
| --- | --- | --- |
| `0` | `FOUNDRY_OK` | |
| `1` | `FOUNDRY_END` | Iteration is finished. Not an error. |
| `-1` | `FOUNDRY_ERR_INVALID_ARGUMENT` | A pointer, length, range or enum value the API refuses. |
| `-2` | `FOUNDRY_ERR_INVALID_HANDLE` | Well-formed and stale, or never issued. |
| `-3` | `FOUNDRY_ERR_NOT_FOUND` | The thing asked for does not exist. Distinct from a bad handle. |
| `-4` | `FOUNDRY_ERR_UNAVAILABLE` | The host supplied no subsystem for this capability (ADR-0026). |
| `-5` | `FOUNDRY_ERR_UNSUPPORTED` | A version, format or feature this build does not have. |
| `-6` | `FOUNDRY_ERR_ALREADY_EXISTS` | Registering a name or id twice, incompatibly. |
| `-7` | `FOUNDRY_ERR_LIMIT` | A bound was hit: a buffer, a pool, a configured maximum. |
| `-8` | `FOUNDRY_ERR_REFUSED` | Well-formed, permitted in general, not permitted **now** — the reentrancy cases in §8, and writes during a phase that forbids them. |
| `-9` | `FOUNDRY_ERR_OUT_OF_MEMORY` | |
| `-10` | `FOUNDRY_ERR_INTERNAL` | An engine error with no mapping. Always logged with the underlying error name. |

`api->result_name(FoundryResult) -> FoundryStr` exists so a mod can log legibly without shipping
its own copy of this table, which would go stale.

**Everything from the other side is untrusted, and untrusted means validated.** Not asserted,
not assumed, not documented-as-a-precondition. Concretely, on every entry point: pointers are
null-checked, lengths are bounded, strings are UTF-8-validated, handles are resolved rather than
indexed, enums are range-checked, floats are checked for NaN and infinity where a NaN would
propagate into simulation state, and every out-parameter is written **only** on `FOUNDRY_OK`.

**The ABI never panics and never propagates a Zig error.** Every call is a `catch` that maps to
a code; an unmapped error becomes `FOUNDRY_ERR_INTERNAL` and logs. The failure this rule exists
to prevent is a mod's bad argument crashing the host inside a subsystem three layers down, and
§15 is the list of places where that is currently possible.

## 7. Enumeration

Nothing hands out a container — `ui.md` §13, `render2d.md` §12 and `debug-overlay.md` §14 all
say so independently. What crosses is one element at a time:

```c
FoundryCursor c = FOUNDRY_CURSOR_BEGIN;    /* zero */
FoundryEntity e;
while (api->world_next_entity(&c, &e) == FOUNDRY_OK) { /* ... */ }
```

**A cursor, not an index.** An index invites being stored and reused as an identity, which is
I2's whole complaint one level down; a cursor is visibly a position in a walk. It carries
`{ generation, index }` in its 64 bits, the same packing a handle uses, so a cursor whose
container has been structurally mutated is *detected* rather than silently resynchronised — it
returns `FOUNDRY_ERR_INVALID_ARGUMENT`, which is the boundary's version of the mutation guard
`entity-storage.md` §5 already keeps internally.

Iteration order is whatever the subsystem documents, and every subsystem publishing an
enumeration already documents one. A count is available where the subsystem can answer cheaply,
and is a snapshot, not a promise about the next call.

## 8. Callbacks: the engine calling into a mod

Three things in `_v1` call back — a registered system, an asset loader, and a content-reload
notification — and all three are the same shape, which is the shape the engine already uses:

```c
typedef struct {
    void *ctx;
    void (*update)(void *ctx, const FoundryStep *step);
} FoundrySystemDesc;
```

`scene.System`, `asset.Loader` and `debug.Panel` are each already a context pointer beside a
function pointer, arrived at independently and before any of this was designed. That is worth
naming as evidence rather than coincidence: the constraint ADR-0025 imposed on M6 — build it as
if it had to cross a C ABI — produced the shape it has to cross one in.

**The rules, all of which are the mod's obligations except the last:**

* The engine never takes ownership of `ctx`, never copies it, never dereferences it.
* A callback runs on the thread that invoked it, which is always the thread the host drives the
  engine from. **No mod code ever runs on the audio device thread** — `audio.md` §10 refuses the
  mix callback permanently and this does not reopen it.
* A callback may call the API. It may not call anything that structurally mutates a container
  the engine is currently iterating; those calls return `FOUNDRY_ERR_REFUSED` rather than
  corrupting the walk. §15 is what makes that a return rather than an assertion.
* A callback that crashes takes the host down. Tier 3 is the consenting-adults tier
  (`CLAUDE.md` §5) and no amount of validation at the boundary changes what a wild store inside
  a mod does. This is stated plainly in `docs/modding/` rather than implied.

## 9. What `FoundryApi_v1` publishes

The union of the six "what this exposes to mods" sections, which were written one milestone to
five milestones ahead of this one and are honoured rather than revisited. Grouped by module;
names are illustrative in shape and exact in prefix.

**Engine and `core` — always available.** `log_write`, `log_next` (read the ring),
`result_name`, `id_from_string`, `id_to_string`, `frame_index`, `frame_delta_ns`, `elapsed_ns`,
`tick_rate`, `scope_begin`/`scope_end` (the profiler a mod's own systems appear in),
`memory_counter_open`/`memory_counter_set` (so a mod that allocates is diagnosable in the memory
panel — the ABI cannot wrap a mod's allocator, so the mod reports its own numbers).

**`data` — content.** `content_generation`, `content_find`, `content_next`,
`content_next_of_schema`, `record_schema`, `record_name`, `record_package`, `record_field_index`
(by name), `record_field_count`, `record_field_name`, `record_field_type`, the typed readers
`record_get_bool` / `_i64` / `_u64` / `_f32` / `_string` / `_id`, the list forms
`record_list_len` and `record_list_get_*`, `package_next` and the package accessors, and
`schema_next` with its field accessors. **Inline structs are read through a sub-record handle** —
`record_nested(record, field, FoundryRecord *out)` returns something that answers the same field
calls — which composes to any depth and needs no path language invented for the boundary.

**`asset`.** `asset_acquire`, `asset_release`, `asset_find`, `asset_next`, `asset_content_id`,
`asset_refcount`. Acquire and release are the one refcount a mod owns and must own.

**`scene` — the largest group, and two thirds of the exit criterion.**
`world_register_component`, `world_find_component_type`, `world_component_type_next` with its
accessors, `world_create_entity`, `world_destroy_entity`, `world_contains`, `world_entity_count`,
`world_next_entity`, `world_add_component`, `world_remove_component`, `world_has_component`,
`world_register_system`, `world_query_begin`/`world_query_next`, `world_spawn`,
`world_spawn_scene`.

Reading a component is **two calls, and the split is the M6 finding paid forward**:

* `world_read_component(entity, type, FoundryRecord *out)` — the schema-described read, works
  for any type including ones the engine has never heard of, and is exactly what
  `debug-overlay.md` §7 made the inspector do rather than casting bytes.
* `world_component_bytes(entity, type, void **out, uint32_t *size)` — a borrow of the raw
  storage, valid until the next structural mutation, and **permitted only for a component type
  the calling mod itself registered**; any other type returns `FOUNDRY_ERR_REFUSED`. A mod owns
  the layout of a type it declared — it supplied the size and alignment — so casting is correct
  there and nowhere else. This is the fast path a native mod needs, granted exactly where it is
  sound.

**`render2d`.** `render_texture_of_asset`, `render_destroy_texture`, `render_draw_sprite`,
`render_draw_text`, `render_add_view`, `render_select_view`, `render_camera_get`,
`render_camera_set`, `render_world_to_screen`, `render_screen_to_world`, `render_stats`.
`render_add_view` is in the list because `render2d.md` §12 argued for it: a mod drawing a minimap
without a view of its own has to reimplement the projection and get it wrong.

**`ui`.** `ui_begin`/`ui_end`, `ui_push_id`/`ui_pop_id`, `ui_begin_panel`/`ui_end_panel`,
`ui_begin_row`/`ui_end_row`, `ui_begin_scroll`/`ui_end_scroll`, every widget in `ui.md` §10 —
`label`, `button`, `checkbox`, `slider`, `slider_int`, `separator`, `spacer`,
`collapsing_header`, `text_field`, `plot` — plus `ui_style_get`/`ui_style_set` and
`ui_wants_keyboard`/`ui_wants_pointer`. Every one is a function over plain values with no object
lifetime crossing, which is what ADR-0024 meant by immediate mode surviving the ABI.

**`audio`.** `audio_play` (by content id, returning a voice handle), `audio_stop`,
`audio_set_gain`, `audio_set_pan`, `audio_set_pitch`, `audio_set_master_gain`. `VoiceHandle` is
already `extern`-shaped and already 64 bits and crosses as-is, which `audio.md` §10 predicted.

**`physics2d`.** `physics_create_body`, `physics_destroy_body`, `physics_move_body`,
`physics_query_point`, `physics_query_aabb`, `physics_query_ray`, `physics_body_contacts`. A
body's `user` field is already an opaque `u64` rather than an `Entity`, which
`tilemaps-and-collision.md` §12 called "the first piece of that already being true".

**The two caller-supplied-buffer calls in `_v1`**, and the only exceptions to §5's borrow rule:
`id_to_string` and `record_get_string` may be asked to copy into a caller buffer when the mod
needs the bytes past the call. Both also have a borrowing form; the copy form takes a pointer
and a capacity and reports the length it needed, returning `FOUNDRY_ERR_LIMIT` rather than
truncating, because silent truncation of a name is how a mod ships with a bug nobody can see.

## 10. What it does not publish, and why

* **The RHI**, permanently. §4.2 and `rhi.md` §1: the renderer API is the game-facing boundary
  and the RHI is not, so `abi` does not depend on `rhi` at all (ADR-0026) rather than merely
  declining to publish it.
* **Shaders and materials.** A mod cannot supply a shader through `render2d`, which
  `render2d.md` §12 already recorded as a constraint on this milestone. It belongs to the
  material system, and ADR-0015 says why that is not ready.
* **The mix callback**, permanently (`audio.md` §10). Untrusted code inside the one context in
  Foundry where a mistake is unrecoverable and undebuggable.
* **Panels.** ADR-0026: `abi` does not depend on `debug`, because that would make the overlay
  mandatory for every mod host and being depended on by nothing is the whole reason `debug` is
  opt-in. Owed, additively, when `debug` can install its own section into a table the host
  assembles.
* **Save file bytes, the draw list's memory, the batcher, the widget state map, the recorder's
  arrays, the log ring's memory, and any pointer into a subsystem's container.** The pattern
  `ui.md` §13 set and every document since has repeated: a consumer describes and reads; it does
  not get the container.
* **Windows, files and devices.** `abi` depends on `platform` for `Library` alone. A mod reads
  its data as content, through the package it shipped, which is the whole of ADR-0021's
  argument. A mod that needs a scratch file is an open question (§18), not an oversight.

## 11. The manifest

A `foundry:mod` record in the package it describes (ADR-0027). The schema is **engine-declared
and registered at runtime**, beside `foundry:texture` and `foundry:entity` and for the same
reason `assets.md` gives for those: `fpack` must know the record type to check a package, and
whoever consumes the record is somewhere else entirely. `content/core` carries a record of it,
like every other package.

> **Corrected 2026-09-07 by step 1.** This section first said the schema was "declared in
> `content/core`". It cannot be: a mod's package does not declare it either, and a schema no
> compiler knows is a record no compiler can check. `content/core` declaring it would have made
> the engine's package a prerequisite for *compiling* rather than for loading.

```
// engine/src/mod/schemas.zig, in Zig; spelled here as the .fdt it is equivalent to
@schema mod {
    name        string                          # display name, shown to a player
    version     u32                             # the mod's own version, monotonic
    license     string                          # ADR-0016; an SPDX identifier or "see LICENSE"
    summary     string   (optional)
    authors     [string] (optional)
    url         string   (optional)

    # What must load before this, and at what versions. An id, not a path or a name.
    requires    [{ id id  min u32 (default 1)  max u32 (optional) }] (optional)

    # Required only by a mod with code. The ABI version it was compiled against.
    abi         { min u32  max u32 (optional) } (optional)

    # The base name of its native library: no `lib`, no extension, no separator.
    native      string   (optional)
}
```

and, in a mod:

```
# brighter/mod.fdt
foundry:mod  brighter:mod {
    name     "Brighter Lamps"
    version  3
    license  "MIT"
    requires [ { id foundry:core  min 1 }  { id room:content  min 2 } ]
    abi      { min 1 }
    native   "brighter"
}
```

### 11.1 Three fields worth arguing about

**`native` is a base name, never a filename.** The loader forms `libbrighter.dylib`,
`brighter.dll` or `libbrighter.so` per platform, so one package works on all three and a mod
author never writes a platform conditional into content. It must contain no path separator, no
`.` and no `..`; `platform.os.isSafeRelativePath` is not enough here and a bare-name check is
what the loader applies. A manifest naming a library outside its own package directory is
refused with a diagnostic, not sandboxed by hope.

**`abi` rather than an engine version.** What a compiled mod is fragile against is the table,
not the release number, and versioning against the thing that actually breaks is the difference
between a compatibility range that means something and one a mod author guesses at. A
content-only mod omits it entirely and is compatible with every engine that can read its
package format — which is I8's job, not this field's.

**`version` is the mod's, and `requires` ranges are against it.** Foundry does not interpret
it beyond ordering comparisons: no semver parsing, no pre-release grammar, no build metadata. A
monotonic `u32` is what a dependency range needs and everything past it is a specification
somebody has to implement identically in every external mod tool — the same argument `core/id.zig`
makes for refusing to normalise identifiers.

### 11.2 Package zero has one

`content/core` carries a `foundry:mod` record using the schema it declares. Self-referential and
correct: the schema and its first user are in the same package, which is the ordinary case, and
it means the engine's own content is discovered, ordered and loaded by exactly the code a mod
goes through. I3 has never had a stronger statement available to it.

### 11.3 What a mod may do to content it does not own

`content-schemas.md` §10.3 left this open **and named this milestone as when it comes due**:
whether a mod may add a field to another package's schema. It is a policy question, not a
mechanism one — the mechanism has been safe since the store was built, because each package
carries the schemas its records use at the version they were compiled against, a record is read
against its own package's copy, and a field a record predates reads as absent and is filled from
the newer version's default.

**Decided: yes, additively, and only additively.** A mod may declare a higher version of another
package's schema that is a strict superset of it — new fields, all optional or defaulted, none
removed, none retyped, none reordered. The registry already implements exactly this rule and
already refuses the rest.

The case for permitting it is that "add a field to items" is the single most-requested content
mod capability there is, and refusing it does not prevent it — it forces a mod to fork the
schema, which produces two incompatible `foundry:item`s and breaks every other mod at once.
Permitting it additively produces the outcome a schema author actually wants: their records keep
working, unchanged, whatever anyone adds.

The cost, stated so it is not discovered later: **a schema's shape becomes a function of the
enabled set.** Two mods may each add a field and a third sees both. That is already true of
records and is why the override chain is reconstructible; it is why the content browser shows
which package defined what. Nothing about reading is affected, because reading was never against
the registry's newest copy.

## 12. Discovery, resolution and load order — the `mod` module

L2, on `core`, `data` and `platform` (ADR-0027). It finds packages, reads their manifests,
computes an order, and hands back the list `app.Config.content` already takes. It opens no
library and loads no code, so a game that hosts only content mods needs nothing above it.

```zig
pub const Requirement = struct { id: core.ContentId, min: u32, max: ?u32 };

pub const Manifest = struct {
    id: core.ContentId,          // the package's own id, from the record's namespace
    name: []const u8,
    version: u32,
    license: []const u8,
    requires: []const Requirement,
    abi: ?Range,
    native: ?[]const u8,
};

pub const Candidate = struct { manifest: Manifest, file: []const u8, root: []const u8 };

pub fn discover(gpa: Allocator, os: *platform.os.Os, dir: []const u8) ![]Candidate;
pub fn resolve(gpa: Allocator, candidates: []const Candidate, request: Request) !Resolution;

pub const Request = struct {
    /// The player's order, and the reason it exists: load order *is* the override mechanism.
    enabled: []const core.ContentId,
    /// Not skippable. `foundry:core` is always in here.
    required: []const core.ContentId,
};

pub const Resolution = struct {
    order: []const app_content_entry,   // file + root, in load order
    skipped: []const Skip,              // id, reason, and what it names
};
```

A candidate's manifest is read by opening its `.fpk` **alone** — the store's own resolution
established that a package can be read with nothing but itself, and this is the consumer that
property was predicted for. Nothing is merged to find out what is installed.

### 12.1 The algorithm, and why each step is the way it is

1. **Index by id.** Two candidates with the same id is an **error naming both files**, not a
   silent pick. Two copies of one mod installed is a common, real user mistake and choosing one
   quietly produces a bug report nobody can reproduce.
2. **Seed** with `required` plus `enabled`.
3. **Close over `requires`.** A dependency that is absent, or present at a version outside the
   range, **skips the dependent and everything transitively depending on it**, each with its own
   diagnostic naming the mod, the dependency and the range. Skipping rather than refusing to
   start is the rule `content-schemas.md` §7 already set for a patch targeting a missing id, and
   for the same reason: a player with one broken mod should get a game and a message, not a
   failure to launch.
4. **Cycles** skip every mod in the cycle and name the cycle in order. A cycle is an authoring
   error and there is no correct order to invent.
5. **Sort.** Kahn's algorithm with a priority queue: among the mods whose dependencies are all
   placed, take the smallest by `(position in the player's enabled list, content id ascending)`.
6. **`required` is never skipped.** A missing or broken `foundry:core` is fatal, because there
   is no game without it.

**Why a stable topological sort rather than a plain one.** Load order is how overrides resolve
(`content-schemas.md` §7), so the player's order is a real input carrying real intent — two mods
that both replace the same texture are settled by which the player put last. The graph
constrains the order only where a dependency actually exists; everywhere else the player's order
must survive, and content id is the final tie-break so that two mods the player never ordered
still land somewhere reproducible.

**Determinism is the property, not the algorithm** (I9). The same candidates and the same enabled
set produce the same order on every machine, and the test that says so shuffles the discovery
order — which is the only thing a filesystem can vary — and asserts the resolution is
byte-identical.

## 13. The mod lifecycle

Where the two halves meet. Phases, in order, each ending somewhere a host may legitimately stop:

1. **Discover.** `mod.discover` over the game's content directory and the user's mod directory
   (`platform.os.userDataDirAlloc`). No engine exists yet; a launcher can do exactly this much.
2. **Resolve.** `mod.resolve` produces the order and the skip diagnostics. A mod manager UI is
   this plus a list box, and it is *not* built at M7.
3. **Content.** `app.Engine.init` with that order. Packages merge, assets mount, schemas
   register. **Tier 1 is finished here** — a content-only host stops, and nothing above this
   line has been linked.
4. **Bind.** The host fills an `abi.Host` with the subsystems it has — world, renderer, mixer,
   collision world, any subset — and asks `abi` for the table. Absent subsystems become
   `UNAVAILABLE` answers, not missing entries (ADR-0026).
5. **Load.** For each ordered mod with a `native` name: open the library, resolve
   `foundry_mod_init`, call it with `get_api` and its own handle. This is where component types,
   systems and asset loaders get registered — after the store exists, which is why a mod may
   register a type whose schema came from content.
6. **Run.** Frames. Systems registered in phase 5 run in the world's ordinary system order.
7. **Shutdown.** `foundry_mod_shutdown` in **reverse** load order, then the engine's ordinary
   teardown, which is already strictly reverse of initialisation.

**No phase forbids registration**, and that falls out of a decision M4 already made: a component
type is identified by a handle and a schema id rather than by an index, so registering one late
renumbers nothing and invalidates nothing. The only ordering that matters is that phase 5 comes
after phase 3, and it does.

## 14. Native mods: where the library is, and what is not done to it

A mod's library lives **in the mod's own package directory**, named by `native` with the
platform's decoration applied by the loader (§11.1). One directory is one mod.

Every failure is a diagnostic and a skipped mod, never a crash: no such file, wrong
architecture, unresolvable transitive dependency, missing `foundry_mod_init`, an `abi` range this
host cannot satisfy, or `foundry_mod_init` returning anything but `FOUNDRY_OK`. A skipped native
mod's **content still loads** — it was merged in phase 3 — which is the right outcome: a texture
replacement should not stop working because a plugin failed to open.

**M7 does not unload a native mod, and does not hot-reload one.** `platform/library.zig` says
why in its own doc comment: closing a library invalidates every pointer obtained from it,
including any the loaded code handed back, and a mod that registered a system has left a function
pointer inside the world. Unloading correctly means unregistering everything a mod registered, in
reverse, and establishing that nothing else still holds a pointer — a lifecycle problem, and a
milestone of its own. So libraries are opened once and stay open for the life of the process,
and `foundry_mod_shutdown` is where a mod releases *its* resources, not where its code goes away.

The cost is stated rather than hidden: a native mod author rebuilds and restarts. Content hot
reload is untouched and keeps working, which is most of what iterating on a mod actually is.

## 15. What the boundary forces on the modules below it

The engine work M7 requires, in full. It is short, and that is the milestone's real result:
six milestones of designing for a boundary that did not exist produced an engine whose ABI is a
translation layer rather than a retrofit.

**1. `scene`'s mutation guard must gain a validating form.** `entity-storage.md` §5:

> the world carries a mutation counter, the iterator captures it, and `next` **asserts** it is
> unchanged. This is an assertion rather than a validation because it is a programmer error in
> engine or game code, not untrusted input.

Correct when written, and **the boundary falsifies the premise**: at M7 the caller can be a mod,
and untrusted input reaching an assertion is a crash a mod can trigger from outside the
repository. The iterator gains a form that reports the change; `abi` uses it and returns
`FOUNDRY_ERR_INVALID_ARGUMENT`. The internal one may keep asserting, because for engine and game
code the premise still holds.

This is the concrete instance of what ADR-0025 said would happen and named as its own
falsification test — a rule that was right, written down with its reasoning, and overturned by
the boundary arriving. It is worth noticing that the *reasoning* is what made it cheap: the
document said exactly which assumption it rested on, so checking whether the assumption still
held took one paragraph rather than an audit.

**2. An audit for the same shape everywhere else.** Every `core.assert` reachable from a
published entry point is either shown unreachable from the boundary or converted to a validated
return. This is mechanical, it is the largest single piece of engine work in the milestone, and
it is exactly the discipline `CLAUDE.md` §7 has asked for since day one — applied now to a
caller that finally exists.

**3. `fpack` and `build.zig`**, per ADR-0027: the manifest becomes the source of a package's
name and version, `--name` and `--version` go, and the build's content table loses its `id`.

**4. Nothing else.** No subsystem gains a dependency, no interface changes shape, and no module
below L5 learns that the ABI exists.

## 16. The header, and who writes it

**One hand-written `foundry.h`**, installed by `zig build`, C99, no dependencies, no generator.

A generator would be a build tool, and ADR-0014 requires an ADR for one. More importantly the
header is the **specification** — the artifact a mod author reads and the one this document is
about — and a generated header is a description of the implementation rather than a contract the
implementation owes.

It is kept honest by compilation rather than by care: a C translation unit includes `foundry.h`
and statically asserts every struct's size, every field's offset **and every member's width**,
and a Zig test asserts the same numbers from the `extern struct` side. Both are built by `zig
build test` *and* `zig build check` for every target, because Zig compiles C and this therefore
needs no tool that is not already installed. A header that disagrees with the engine fails the
build on the machine that changed it.

> **Revised 2026-09-07, implementing it.** Two details this had wrong. The translation unit is
> attached to the `abi` *module* rather than to the test binary, which is what puts it on `zig
> build check` and therefore on the cross-compiled targets where a padding assumption would
> actually differ. And sizes and offsets alone do not pin a member's *width* — a `uint32_t` where
> a `uint64_t` belongs can satisfy both and still be a different ABI — so member widths are
> asserted too. See the resolution at the end of this document.

## 17. Testing

* **The garbage sweep.** Every entry point in the table, called with zeroed arguments, stale
  handles, out-of-range enums, NaNs, null pointers and lengths that overflow — each must return
  an error and none may crash. Table-driven, so a capability added without a refusal path fails
  the sweep rather than shipping. Same discipline as `.fpk`'s mutate-one-byte test, which is the
  precedent for trusting a reader at all.
* **The empty host.** Every entry point against an `abi.Host` with no subsystems must answer
  `UNAVAILABLE`, which is one assertion per entry and catches a capability wired to a subsystem
  the host never supplied.
* **`mod`, four ways:** manifests mutated one byte at a time; discovery order shuffled with the
  resolution asserted identical; and one test each for a cycle, a missing dependency, an
  unsatisfiable range and a duplicate id — every one asserting a *skip with a diagnostic*, not a
  refusal to start.
* **The header agreement test**, §16.
* **An integration test**, `engine/tests/mod_pipeline.zig`, shaped like `sound_pipeline.zig`: the
  parts are unit-tested and what this proves is that they are wired to each other — a package on
  disk with a manifest, discovered, ordered, merged, its library opened, its `foundry_mod_init`
  called, its component type registered and its system running, all against the null platform and
  the null device.

## 18. Open questions

The remaining questions are named rather than resolved, per the standing rule that implementation
must not settle them opportunistically. Question 1 was resolved by the M7 exit proof below.

2. **Unloading, and native hot reload.** §14 defers both with a reason. *Trigger: a mod author
   with a real iteration loop complaining, or the editor needing to reload a tool plugin.*
3. **A mod's own storage.** Reading is content and needs nothing. Writing — a config file, a
   cache — has no answer here and deliberately no capability. *Trigger: the first mod that
   genuinely cannot express its state as content.*
4. **Per-mod tables rather than one shared table.** A per-mod table would allow per-mod policy —
   a mod granted read-only capability, a tool granted more — at the cost of a table per consumer.
   Nothing needs it yet, and `_v1` being shared does not foreclose it.
5. **What a mod may learn about its host.** A mod adapting to "which game am I in" needs a name
   and a version; nothing needs it yet, and the question is whether that is the ABI's business or
   the game's own content.
6. **Threading.** Everything here is single-threaded because Foundry is, apart from the audio
   device thread no mod code will ever run on. A job system reopens this, and this document is
   part of what its design has to read.
7. **Sandboxing.** Tier 2's problem and M8's. Nothing in `_v1` assumes the caller is trusted; the
   difference at M8 is what happens when it misbehaves, not what it may call.

> **M8 design follow-up, 2026-09-09:** question 7 is now specified by
> [scripting.md](scripting.md) and ADR-0028/0029, with implementation pending. The restricted
> binding exposes a bounded subset of this table, and source access is designed as an additive
> v2 call. V1 is unchanged. Questions 2–6 remain open; script VM replacement does not unload
> native libraries or introduce per-mod C tables.

## 19. Implementation order

Each step ends with something that runs and something that is tested.

1. **`mod`** — the engine-declared manifest schema, with `content/core` carrying its record,
   `discover`, `resolve`, and the diagnostics.
   Headless: no table, no library, no window. Ends with the three packages in this repository
   carrying manifests, `fpack` reading name and version from them, `build.zig` losing its `id`
   column, and both samples' load order **computed rather than written by hand**. This is Tier 1
   finished, and it is the step that pays off M3.
2. **The type layer and the header** — `foundry.h`, results, strings, handles, cursors, the
   agreement test. No capabilities. Small, and everything after it is downstream of getting it
   right.
3. **`abi`'s skeleton** — `Host`, `get_api`, `FoundryApi_v1` carrying only what `app` and `data`
   already answer: log, ids, frame, profiler, memory, content, assets. The validation discipline
   and the garbage sweep land here, with the smallest possible surface to be wrong about.
4. **`scene` through the ABI**, including §15's mutation-guard change and the assertion audit.
   Component types, entities, components, queries, systems. Two thirds of the exit criterion.
5. **The rest of the capabilities** — `render2d`, `ui`, `audio`, `physics2d`. Mechanical by this
   point, which is the test of whether steps 2 and 3 were right.
6. **Native loading** — the library, `foundry_mod_init`, phases 4 to 7, every refusal path, and
   `engine/tests/mod_pipeline.zig`.
7. **The exit criterion** — a mod built outside the tree that adds a component type, content and
   behaviour, and `docs/modding/` written by doing it and then verified by following it verbatim,
   which is how `content-mods.md` was written and the only way that document stayed true.

---

## Resolution: `mod` (implementation, 2026-09-07)

§19 step 1, built. What writing it settled that the design had not.

**The manifest schema is engine-declared, not content-declared**, and §11 is corrected in place
above. The design said "a schema declared in `content/core`", which cannot work: `fpack` has to
know the record type to *check* a manifest, a mod's own package does not declare it either, and
a package zero that had to be compiled before anything else could be checked would be a
privileged path in the compiler — the exact shape I3 exists to refuse. It lives in
`engine/src/mod/schemas.zig` beside `foundry:texture`, and `content/core` carries a record of it
like every other package does.

**The manifest source has a fixed filename: `mod.fdt` at the package root.** Not stated in §11,
and forced by an ordering the design did not look at: the parser expands a bare schema name using
the *package's namespace*, and the package's namespace now comes from inside the package. The
pre-pass therefore has to read one file before it knows anything, so it has to know which file.
Two consequences worth having anyway — a tool with only the source tree can find a package's
identity without compiling it, and the manifest is the first file a mod author sees in their own
directory listing. The cost is one rule: **a manifest's schema reference must be written out as
`foundry:mod`**, because a bare `mod` would expand against a namespace nobody knows yet.

**The pre-pass parses with a placeholder namespace, and that is safe for a reason the format
already guaranteed.** Content ids are always fully qualified, so nothing in a manifest is
expanded except a bare schema name — which the rule above forbids. The file is parsed again in
the ordinary pass, where the record is checked against the schema like any other; the pre-pass
reads two values and checks nothing, which is what keeps it from being a second, weaker checker.

**A dependency's id has no spelling, and one diagnostic is worse for it.** An `id`-typed field is
eight bytes in a compiled package — the format working as designed — so `requires` carries hashes.
`resolve` recovers the name from whichever candidate has it, which covers every case except a
dependency *nobody* has installed; that one prints a number. Keeping the field an `id` was
chosen over a string: the compile-time-checking argument that makes bare ids right elsewhere does
not apply to a package reference (nothing can check it at compile time either way), but a format
with two spellings for an identifier is a worse thing to explain than one bad diagnostic. Recorded
as a known limitation rather than worked around.

**The manifest record's content id is the package's content id**, and the two are checked against
each other at read time. The header already carries the package id, so a package whose manifest
disagrees with its own header has been edited by hand and nothing else it says can be believed —
`ManifestIdMismatch`, with `ManifestVersionMismatch` beside it for the same reason.

**`compile` returns the identity, and the caller owns the string.** It cannot borrow: it is read
out of a parse tree that is gone before the compile finishes, and pointing into the compiled bytes
would tie a two-word answer to a buffer the caller may already have written out. Found by a
segfault in the first test that asserted it, which is the null-backend argument in miniature — the
test that reads a value is the one that discovers who owns it.

**`app.contentDirOf` is public now.** Discovery happens before an engine exists (§13 phase 1), so
the directory to search has to be answerable without one, and the two samples were about to
compute `<prefix>/content` themselves — which is how a default becomes two defaults that drift.
The engine calls it with `Config.content_dir`; a host that discovers calls it once and passes the
answer back, so both look in the same place by construction.

**What the samples show now.** Neither names a file. Each names two content ids — the package it
cannot run without and the package it *is* — and everything else comes from the manifests. The
environment variable that used to take filename stems takes **content ids**, which is the visible
half of ADR-0027: a mod is identified by what it calls itself, and where its file sits stopped
mattering. `docs/modding/content-mods.md` was updated and then followed verbatim: a package
compiled with no `--name`, discovered by manifest, enabled by id, loading third behind
`foundry:core` and the sandbox's own.

---

## Resolution: the type layer (implementation, 2026-09-07)

§19 step 2, built: `engine/src/abi/` with `foundry.h`, the types that cross, and the agreement
that keeps the two of them the same. No capabilities, and the module depends on `core` alone.

**Where the header lives, which §16 did not say.** `engine/src/abi/foundry.h`, beside the module
whose contract it is — the same arrangement `metal_shim.h` already has beside its implementation
— and installed by `zig build` to `<prefix>/include/foundry.h`. So a mod compiles against exactly
the header the engine it will be loaded by was built from, which is the only version of that
sentence worth having.

**A size and an offset do not pin a member's width, and the agreement test had to be tested to
find that out.** The first deliberate break — `uint64_t len` changed to `uint32_t` in
`FoundryStr` — passed every assertion, because the struct pads back out to sixteen bytes and
`len` still sits at offset eight. It is a real ABI break and nothing caught it. `agreement.c` now
asserts `sizeof(((FoundryStr *)0)->len)` as well as the offsets, and the general lesson is the one
`.fpk`'s mutate-a-byte test already taught: a test that checks agreement is worth exactly what
breaking the thing it agrees about proves, so break it.

**The check belongs on the module, not on the test binary.** §16 said "a C translation unit in the
test suite", and attaching `agreement.c` to the `abi` *module* instead makes it part of `zig build
check` too — so a header edited here is compiled for `x86_64-windows` and `x86_64-linux` as well
as the host, which is where a padding assumption would actually differ. Nothing in the file is
referenced outside a test, so a linked game drops all of it. `-std=c99 -pedantic -Werror`, with
nothing else in the translation unit, is also what turns the header's "C99, no dependencies" from
an intention into a checked claim; it is included twice, which checks the include guard.

**§6's "lengths are bounded" needed a number.** `Str.max_bytes` is one gibibyte. No string that
legitimately crosses this boundary is that long, and refusing the ones that claim to be turns a
large class of garbage — an uninitialised field, a length where a pointer belonged — into a
refusal rather than a fault. It is explicitly *not* a security boundary: nothing here can check
that memory a mod described is memory a mod owns. A null pointer with a zero length is the empty
string and is legal, because a mod that builds a `FoundryStr` by zeroing a struct means `""`.

**`Result.fromError` had to be split in two to be testable.** §6 requires an unmapped error to
become `internal` *and log*, and Zig's test runner fails any test that logs at `err` level —
correctly, and not something to opt out of. So the mapping is a private function the test calls
and the logging wraps it. The same shape will be wanted wherever validation logs.

**The 64-bit assumption is now stated twice rather than assumed once.** `FoundryStr` is only
byte-identical to a Zig slice while a pointer is eight bytes; the header `#error`s on any other
target and `types.zig` `@compileError`s. Two halves of one claim, each failing on its own side,
which is the same arrangement as the agreement test itself.

**Nothing had to be converted.** `ContentId` crosses as `core.ContentId`, unchanged, because M0
made it an `extern struct` *for this* — and a handle's 64 bits are `core.Handle.bits()`, written
down in M0 for the same reason. The one place two implementations do exist is FNV-1a: the header
carries its own copy so that external tooling can compute an id without linking Foundry, so
`agreement.zig` calls the header's through the C boundary and compares it against the content
compiler's, over the pinned vectors plus a non-ASCII one.

**Four values cross in the tests, and that is the part the assertions cannot do.** Matching
numbers prove two layouts are the same *shape*; a `FoundryStr` built in Zig and read byte by byte
in C proves they are the same *layout*. Reordering `Str`'s two fields fails the offset assertion
and the crossing test independently — which is what a second, differently-shaped check is for.

**Verified beyond the suite:** a stub mod including only `<foundry.h>` from the install tree
compiles `-std=c99 -pedantic -Werror` for macOS and for `x86_64-linux-gnu`, exports
`foundry_mod_init` and `foundry_mod_shutdown`, and the header also compiles clean as C++17.

---

## Resolution: the skeleton (implementation, 2026-09-07)

§19 step 3, built. `FoundryApi_v1` is **sixty-three calls** — everything `app` and `data`
already answer — plus `version` and `size`, and `abi` gains `data`, `asset`, `platform` and
`app`.

**The table has no context parameter, so the host is ambient.** §4's signatures settle this
without saying so: `content_find(id, out)` has nowhere to carry a host. So there is one bound
host per process, found by every entry point through a container-level variable — the shape
`app.log_sink` already has, and for the same reason. §18's fourth question, a table per
consumer, stays open and is not foreclosed by it.

**`Host` is generic over the engine's type**, which was not in the design and is the decision
the rest of the step rests on. `app.Engine` is `EngineOf(platform.Platform, rhi.Device)`; a
`Host` that named it would have dragged a window and a device into every test of a call that
reads a record. Instead a test binds a fake engine with a real content store and a real asset
registry, and every one of the boundary's tests runs headless. It is the null-backend argument
one layer up, and it is also why `platform` joined `abi` at this step rather than at step 6:
an `asset.Registry` takes an `Os`, and the alternative was an asset surface with no unit tests.

**The order of checks needed a rule, and it has two halves.** A *pointer* argument is
validated before the host is looked up — a null out-parameter is `invalid_argument` even on a
bare host, because a null pointer is a mistake in the mod whatever the host has, and
`unavailable` would send its author looking in the wrong place. A *value* argument is
validated after, because whether an id or a handle is meaningful is the subsystem's question
and on a bare host there is no subsystem to ask. Both sweeps in §17 depend on the distinction:
the garbage sweep passes zeroed arguments and expects an error; the empty-host sweep passes
well-formed ones and expects `unavailable`. Both walk `Api_v1`'s fields with `inline for`, so
a capability added without a refusal path fails rather than ships.

**Enumerations cross as `i32` and are looked up, never cast.** A Zig enum holding a value the
enum does not have is illegal behaviour *before* any validation could run, so an enum-typed
parameter would be a hole the boundary opened for itself. Values leaving are enums, because
those the engine produces. The numbers are written down rather than taken from declaration
order, and a test asserts every `data.FieldType` has one — so adding a field type without
publishing it fails here rather than at a mod author's desk.

**`record_nested` is the one place §9 asked for something it had not costed.** A sub-record
"answers the same field calls one level down", which is right — but a view into a compiled
block is three slices and a handle is sixty-four bits. The answer is a **ring of views in the
host**, generational: `record_nested` and `record_list_nested` open one, a view stays valid
until enough further ones are opened to recycle its slot, and a recycled view — or one that
survived a content reload — answers `invalid_handle` rather than reading freed memory. That
is I1's promise applied to a view rather than to an object, and the reload case is the one
that would otherwise be a use-after-free rather than a wrong answer.

**A cursor's generation is the container's size folded with the content generation.** §7 asked
for mutation to be detected and did not say against what; there is no walk counter in `data`
or `asset` to compare against, and adding one would be an interface change §15 rules out. The
fold detects a reload, a package added, and an asset loaded or evicted, which is every
mutation a walk realistically survives into. Two changes that cancel exactly are not
distinguishable in thirty-two bits, and the code says so rather than implying otherwise.

**`FoundrySchemaId` had to exist.** §9 wrote `record_schema` and `content_next_of_schema`
without saying which identifier space they use, and `data` made schema ids a distinct type
precisely so the two most confusable values in the content system could not be swapped —
saying, in the same paragraph, that it is `extern struct` "which is why", meaning here.
Collapsing them at the boundary would have thrown that away at the one place it is hardest to
catch by eye. It has one consequence worth stating: **a schema keeps no spelling at runtime**,
so there is no `schema_name`, exactly as a dependency id in a manifest has no spelling.

**`tick_rate` became `tick_delta_ns`.** The engine's timestep is an exact rational, so a rate
rounded to an integer would not reproduce it, and a mod that recomputed the step from a
rounded rate would drift away from the simulation it is part of. §9's names are "illustrative
in shape and exact in prefix", and this is the shape being wrong.

**`app` gained one function**, which §15 had not foreseen: `endScope`. `Scope` is the right
form in Zig because a value cannot be forgotten on an early return, and a C ABI has no such
value to hand across — `scope_begin` and `scope_end` are two calls with nothing between them.
So the pairing is counted by the caller, and `abi` counts its own depth and refuses to close a
span the game opened, because the recorder cannot tell them apart.

**Two small things the design's rules forced into the open.** `log_write` refuses an empty
message, because the garbage sweep's zeroed call would otherwise write an empty `err` line —
and a line with nothing in it is a mistake rather than a message. And an `f64` content field
is **narrowed** by `record_get_f32`: §5 says `double` never crosses, `f32` is the precision
the simulation computes at (I9), and a schema needing more holds a value the engine itself
could not use. Both are in the header rather than only here.

**Verified beyond the suite:** a stub mod including only `<foundry.h>` from the install tree —
querying the table, writing a log line, walking the packages, and reading a record field by
field through its schema — compiles `-std=c99 -pedantic -Werror` for macOS and for
`x86_64-linux-gnu`, and as C++17.

---

## Resolution: `scene` through the ABI (implementation, 2026-09-07)

§19 step 4, built. `abi` gains `scene`, and a host lends a `scene.World` exactly as it already
lends an engine: twenty-four `world_*` entries, each answering `unavailable` when the game has
no world to lend. `FoundryApi_v1` is eighty-seven calls. What writing it settled that the design
had not.

**A raw native component type cannot be saved, read as content, or spawned from a template —
and that is the milestone's real limit, not an oversight.** §9 says `world_read_component`
"works for any type including ones the engine has never heard of". That is true for a type the
*engine* registered and false for a type a *mod* registered, and the difference is a serializer.
`FoundryComponentDesc` carries size, alignment and construct/destruct, because those are the
things a C struct can honestly describe about itself; it carries no serializer, because writing
one means a mod calling back into a field-block writer, which is a whole sub-surface this step
would have had to invent. So a mod's own type is transient state and behaviour today:
`world_component_bytes` gives its owner the storage, `world_read_component` answers
`unsupported`, and `world_component_type_savable` says so ahead of time rather than after.

Not worked around, because the versioned-struct path already exists and is the honest one: a
later `FoundryComponentDesc` with serializer slots, alongside a `world_register_component`
that takes it, is exactly the additive shape I8 asks for. **Reserved fields were considered and
refused** — speculative padding is what §7's rule against hypothetical requirements is about,
and it would freeze a guess about a surface nobody has designed. What this owes step 7 is
concrete: the exit criterion's mod adds a component type whose *content* comes from records it
also ships, and whose native type carries the runtime half.

**A C mod could not construct a `FoundrySchemaId` at all.** Every call that takes one —
`schema_find`, `content_next_of_schema`, `world_find_component_type`, and now
`FoundryComponentDesc.schema` — could only be fed by a call that *returns* one, and every one of
those needs something that already has a schema. A mod naming its own component type has nothing
to start from, and there is deliberately no `schema_name` to search by. So `foundry_schema_id`
joins `foundry_content_id` as an inline function in the header: same algorithm, same bytes, the
other type. The agreement now cross-checks both against the engine over the same pinned vectors.
Found by writing the stub mod, which is the argument for writing one at every step rather than
at the end — the Zig tests could not find it, because Zig has `SchemaId.fromStringUnchecked` and
C had nothing.

**The agreement did not re-run when only the header changed.** `agreement.c`'s object is cached
against the C file, so editing `foundry.h` alone left the cache warm and the build green — the
one edit the whole mechanism exists to catch was the one edit that did not trigger it. Step 2's
verification passed because it changed both sides. The fix is that `agreement.zig` now
`@embedFile`s the header, making it an input of a module whose recompilation does re-run the C
half, and two checks read the embedded text so the embed is a check rather than a trick: the
version and entry-point symbols are the ones this build publishes, and every table member is
named in the header **in the table's own order**. Both header-only breaks — a narrowed member
and a reordered entry — now fail.

**`template` is a C++ keyword, and the header did not compile as C++.** Mods get written in
C++, `world_spawn`'s parameter was called `template`, and nothing had ever compiled the header
that way. A parameter name is documentation rather than ABI, so the rename is free; the guard
beside it is not free and is the point — a test walks the embedded header for the keywords C++
has and C does not, so the next one fails at the commit rather than at a mod author's build.

**A described component is a frame-lifetime borrow, and that is a second lifetime a nested view
did not have.** `world_read_component` serializes through the type's own function into the frame
arena, so what it returns is alive until the next `beginFrame` — where a view into a loaded
package is alive until a content reload. The host's view slots guarded only the second, so a
record held across a frame would have resolved and read reclaimed memory. A view now records
which lifetime it has, and the two are tested against each other: the same frame boundary that
kills a described component leaves a package view untouched.

**Systems use the shape §8 already named, and the world is the thing that does not cross.**
`FoundrySystemDesc` is an id, a name, a context and a callback; the host bridges it to
`scene.System` and drops the world pointer `scene` passes, handing over only a `FoundryStep` of
tick and fixed delta. A system reaches the world through the table it kept from init. No clock,
no input snapshot, no interpolation alpha — all three would make a mod's simulation depend on
its host's frame rate, which is I9's whole argument.

The id and the name must agree, and the boundary is stricter than the engine here on purpose: a
`ContentId` has no spelling at runtime, so the name is the only thing that can ever say what the
id was, and two that disagree produce a mod nobody can diagnose later. `registerComponent`
already enforces the same rule for schemas; making systems match it costs a mod one identical
string.

**The mutation guard has a validating form, and only one of the three walks needed it.**
`Query.nextChecked`, `EntityIterator.nextChecked` and `TypeIterator.nextChecked` return
`error.Mutated` where `next` asserts. The query's is load-bearing: a query cursor names a
host-held `scene.Query` that survives between calls, so a structural change really is caught
there. The entity and type walks rebuild their iterator on every call, so their own guard cannot
fire — what catches a mutation is the cursor's generation stamp, folded from the world's
mutation counter. They still take the checked form, because **no entry point may call an API
that can assert**, and that rule has to survive somebody later hoisting an iterator.

Two deliberate widenings beyond §15, recorded rather than left to be noticed. `EntityIterator`
and `TypeIterator` gained a mutation guard they never had — the same discipline the query has,
for the same reason, and a walk that silently skips entities is a worse bug than one that stops.
And `World.typeInfo` is now a public accessor: the type walk was already building that snapshot,
and a caller holding a handle had no way to ask for it. Both are additive; nothing below L5
learns that the ABI exists.

**The assertion audit was small because the premises were written down.** Five assertions are
reachable in `scene`, and each is now either guarded or unreachable from a published entry
point: `Query.next`'s and the two iterators' are the checked forms above; `World.query`'s
maximum type count is validated at the boundary before the call; `ComponentStore.add`'s pair sit
behind `addComponent`'s own size, existence and duplicate checks; and `World.destroy`'s follows
its `contains`. The one premise a mod can actually falsify was mutation during iteration, which
is what §15 predicted, and finding nothing else is the six milestones of discipline paying out
rather than a light audit.

**Three refusals the mapping got wrong until a test asked.** `WorldNotEmpty` is `refused`, not
`invalid_argument` — component types are startup-only, so the call is well formed and permitted
in general, just not now, which is exactly what that code means. A query naming a type the world
does not know is `invalid_handle` at the boundary although `World.query` deliberately tolerates
it: the engine's reasoning is about a system that should be inert when the mod owning its
component is absent, and a mod cannot hold a handle to a type nobody registered, so the same
input means something different on this side. And `memory_counter_set`'s step-3 rule generalised:
a call whose subject only exists because a subsystem accepted it must answer `unavailable`
before `invalid_handle`.

## Resolution: remaining capabilities (contract, 2026-09-08)

Step 5 exposes the existing subsystems through §9's table. The following host contracts
are recorded before their implementation; verification and any further findings follow below.

**The host still owns every subsystem and the inputs it needs.** In addition to the engine
and scene world, it lends the renderer, UI context, mixer and collision world. Collision's
allocator is supplied alongside its world, because `physics2d.World` deliberately takes an
allocator per allocating call and a collision-only host must not need an `app.Engine`.
The audio host type may be specialised for a null-device mixer in tests, retaining the
ordinary `HostOf(Engine)` spelling for applications.

**UI input is supplied by the host, not reconstructed by a mod.** `ui_begin` takes a plain
viewport rectangle and uses the captured `ui.Input` the host lends for that frame. The host
walks the completed draw list through the existing walker. The boundary refuses a second
begin while the context is open, and refuses an unbalanced end. Identity-stack bookkeeping
belongs to the boundary; widget state and layout continue to belong to `ui`.

**A camera is host-owned state, not a mutable view inside the renderer.** Camera get/set and
coordinate conversion use a camera explicitly lent by the host. The host supplies that camera
to its next renderer begin; changing it does not rewrite views or draws already recorded.
Per-frame view handles must expire when the renderer begins its next frame, even if the new
frame reuses the same view index.

**Integer slider endpoints must remain representable.** The existing widget converts an
`i32` limit to `f32` and back when dragging. `INT32_MAX` rounds up to 2147483648 in that path,
so a valid boundary argument can trigger a checked float-to-integer conversion failure. The
widget must clamp before conversion using representable integer limits; the ABI must not
hide that bug by refusing a valid part of its declared integer range.

**A queued audio command needs an acceptance result.** The mixer's existing control calls
return `void` and can drop a command when its ring is full. A public call cannot report
success for a command it did not queue. Checked control forms expose queue acceptance to
the ABI, which returns `limit` when full; existing callers keep their current signatures.
No callback-thread code or ownership changes are needed.

**Collision results retain both kinds of identity.** A hit names a body or a grid by an
opaque generational handle, with cell coordinates for a grid. Dropping the grid handle would
make the same cell coordinates in two grids indistinguishable. A grid handle grants identity,
not access to its arrays. Queries use caller buffers with written and total counts, preserving
the collision subsystem's explicit truncation semantics; zero capacity is a counting query.
This extends §9's list of caller-buffer calls, which predated the concrete collision surface.

**A texture obtained from an asset owns its own asset reference.** `render_texture_of_asset`
accepts an acquired asset, verifies that its payload is a texture belonging to the supplied
renderer, and issues a boundary-owned generational texture handle while acquiring one further
reference. `render_destroy_texture` invalidates that boundary handle and releases precisely
that reference; it never destroys the renderer payload directly. A caller may therefore release
the asset it used to create the texture handle without invalidating the texture prematurely.
This is the concrete replacement for `render2d.md` §12's earlier intent to expose raw texture
and atlas construction: `public-abi.md` §9 deliberately publishes content-backed textures in
version one, so image bytes and renderer allocation policy do not cross the boundary.

**A view handle carries the renderer frame that issued it.** `Renderer.begin` advances a
nonzero generation and the ABI combines that generation with the returned view index. Selecting
a handle from an earlier renderer frame is therefore `invalid_handle`, even when that frame has
created a view at the same index. This is the validating support the public boundary forces on
`render2d`; it exposes no RHI state and changes no game-facing draw semantics.

## Resolution: remaining capabilities (implementation, 2026-09-09)

§19 step 5, built. `FoundryApi_v1` is **one hundred and thirty-five calls**: eleven render,
twenty-four UI, six audio and seven collision calls appended after the eighty-seven-call scene
table. `abi` gains the four corresponding modules and still cannot see `rhi`; the one integration
test that needs a real validating device lives above the modules in `engine/tests`.

**Texture ownership is loader provenance, not handle coincidence.** Renderer texture handles
are local to a renderer, so two pools can issue identical bits. The asset registry now has one
narrow query that compares the schema, owner context and both loader callbacks before returning a
payload. The ABI uses it both when issuing a texture wrapper and on every draw. A wrapper stores
the acquired asset handle rather than a copied renderer handle, so a successful hot reload swaps
the payload behind the same wrapper; changing its loader or schema makes the next draw a refusal.
An integration test uses two renderers to prove both halves.

**UI nesting needs identity and topology.** The boundary shadows each open panel, row and scroll
with its kind and the kernel stack depths it produced, so a mismatched close cannot unwind state
opened by somebody else. Explicit pushed ids are raw scopes folded through the current region
seed at widget time; otherwise one pushed id erases the distinction between sibling panels. The
regression uses the same child id in two panels, rows and scroll regions and observes no duplicate.

**Collision counting had two edge cases.** A body's own overlap is subtracted only when its layer
passes the query mask, and the conversion scratch has one slot beyond the caller's bounded
capacity. The maximum-capacity regression creates the self hit plus 4,096 external contacts: all
4,096 caller slots must be filled and the total must still be honest. Mask zero remains a valid
counting/filter query, not malformed input.

**The C agreement now checks signatures as well as bytes.** Every new struct member has a width,
offset and size assertion, every new table member has a name and offset, and all forty-eight new
function pointers are assigned to independently written expected types. Deliberately narrowing
`FoundryPhysicsHit.user` failed its width assertion while the surrounding layout still fitted;
deliberately changing `render_stats`' expected parameter failed as an incompatible function
pointer. Both guards were restored and compiled as C99 on all three targets and as C++17.

**The implementation audit found and fixed the existing integer-slider overflow.** Interpolation
now uses wider arithmetic before the result is clamped back into the complete `i32` range. Audio's
control commands gained checked queue forms so the ABI can return `limit` rather than claiming a
dropped command succeeded. View generations advance at renderer begin, malformed strings stop at
the ABI as invalid UTF-8, and every new out-parameter remains untouched on refusal.

## Resolution: native loading (implementation, 2026-09-09)

§19 step 6, built. `mod.Entry` carries the manifest's ABI range beside its native base name, and
`abi.NativeLoaderOf` implements phases 5 and 7 without moving library loading below L5. It applies
the target's decoration, opens only beneath the resolved package's one-directory root, resolves
the required init and optional shutdown symbols, and gives the library the same 135-call v1 table
the rest of the milestone has tested directly.

**An init result crosses as an integer before it becomes an enum.** The header returns
`FoundryResult`, which is an `int32_t`; native code can return any value in that range. Typing the
function pointer as Zig's `Result` made an unknown value illegal at the instant the call returned,
before the boundary could diagnose it. `ModInit` therefore returns raw `i32` internally and the
loader uses `Result.fromCode`, diagnosing an unknown result exactly like `result_name` does.

**A failed init leaves an image mapped but does not earn shutdown.** Once init has run, the mod may
already have put a function pointer into a subsystem before returning an error, so closing the
image would manufacture a later use-after-unload. The loader reserves its bookkeeping before any
foreign call and retains every invoked image. But `foundry.h` also promises that nothing else is
called after init refuses, so only a successful init keeps its optional shutdown callback. Those
callbacks run once, in reverse resolved order; the image itself is never unloaded in M7.

**Refusal neutralizes registrations made before the refusal.** A hostile init can register a
component callback, system or memory counter and then return an error. The world has no removal
operation in M7, so its append-only registration metadata remains, but the host clears every
foreign callback and unregisters the counters before invalidating `self`; no later frame or
teardown calls into that library. The C integration fixture registers a system and then refuses,
and proves an ordinary world update leaves its callback untouched.

**`FoundryMod` became a resolved identity rather than merely nonzero bits.** The loader issues it
from a bounded generational table carrying the package's content id and validated spelling, which
now prefixes that mod's log lines as §3 promised. Every call that records or
uses per-mod ownership — component registration and raw access, system registration, and memory
counters — resolves the handle first. Unbind invalidates slots without resetting their
generations, so a library retaining an old `self` cannot regain authority when the same host is
bound again. Generation allocation is shared across host instances too, so replacing the ambient
host cannot make an old identity valid against a fresh host's first slot.

**Location is checked at both seams.** Manifest reading still refuses a `native` value that is not
a bare name. The loader checks it again because `mod.Entry` is a public host-facing value, and also
requires `root` to be exactly one safe relative directory before joining any path. This closes the
case a hand-constructed entry or a pathological package filename could otherwise turn into a
library outside its own package directory.

`engine/tests/mod_pipeline.zig` is the complete composition test §17 required. The build produces
separate C99 dynamic libraries against only `foundry.h` for the host, Linux and Windows targets.
Real packages are written to disk, discovered, resolved and merged; two native images register
component types, one registers a system whose callback mutates a world, and their shutdown-created
entities prove reverse order. Further images and entries cover a missing or corrupt file, missing
init symbol, an absent optional shutdown, missing or unsupported ABI range, known refusal, unknown
result integer, unsafe name/root and the 64-mod identity limit. **1117 headless tests.**

## Resolution: the exit criterion (implementation, 2026-09-09)

§19 step 7, done, and with it M7. The mod itself lived in a temporary directory outside the
Foundry checkout, which resolves open question 1 narrowly: **the proof belongs outside the engine
tree; the durable artifact is the author guide, not another in-tree sample.** A mod is not a game,
but putting this one under `samples/` would have weakened the only property the criterion exists
to test — that neither its source nor its build participates in Foundry's build graph. Nothing
about this answer requires every future example mod to live elsewhere; it answers where this
compatibility proof lives.

`docs/modding/native-mods.md` was written from the outside in and then followed. Its exact C99
source compiled against `zig-out/include/foundry.h`, not an engine module or private header; its
manifest and content compiled with the installed `fpack`; and the resulting `.fpk` plus
package-local `liblanterns.dylib` were handed to a separate host. Discovery found `lanterns:mod`,
resolution put `foundry:core` before it, the loader called its init, and the mod read 41 from its
own content, registered `lanterns:counter` and `lanterns:advance`, then changed the component to
42 on the first world update. The host observed the value through `scene`, not through a test-only
export from the library. No engine source changed to make the proof pass.

The exercise found one test-host defect rather than an ABI defect. `mod_pipeline.zig` called the
selected `app.Engine`, so the default SDL build tried to initialise a display even though the test
declared itself headless. It now explicitly instantiates `EngineOf` with the null platform and
null RHI, matching the test's documented contract and making the ordinary `zig build test` bar
headless independently of the configured application backend.

Open questions 2 through 7 remain open. In particular M7 still does not unload or hot-reload a
native image, provide mod-owned writable storage, vary the table per mod, expose host identity,
run mod callbacks concurrently, or sandbox native code. None was required to meet the criterion,
and step 7 does not manufacture evidence to close them.
