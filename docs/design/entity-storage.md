# Design: `scene` — entities, components, systems and world state

**Status:** M4 in progress. Steps 1 to 5 of §15 are built — `engine/src/scene/` in full, and
`samples/sandbox` holds entities rather than an array of sprites. The Resolution sections at
the end record what each step settled. Step 6 — entities in content, and saves — is not
written.
**Date:** 2026-09-05
**Implements:** I1, I2, I3, I5, I6, I8, I9 · **Informed by:** ADR-0005, ADR-0006, ADR-0010,
ADR-0013, ADR-0020, ADR-0021

`scene` is layer L3. ADR-0007 grants it `core`, `data` and `asset`; M4 wires **`core` and
`data` only**, and takes `asset` when something here actually needs to acquire one (§8). A
dependency the module does not use is a claim about the architecture that the build cannot
check.

Two consequences of that layering are worth stating before anything else, because they shape
the interfaces rather than merely constraining them:

* **`scene` cannot read input and cannot read a clock.** `platform` is not below it and never
  will be. A system is *given* the tick it is running, and anything from a device reaches it
  as ordinary data the game put there.
* **`scene` cannot open a file.** Same rule `data` lives under. A world is saved *into a byte
  slice* and loaded *from one*; whoever has a filesystem does the writing. That keeps every
  test here hermetic, exactly as it did for the content pipeline.

Component data, entity templates and save files all come from outside the engine, which makes
all three **untrusted input**: validated and refused, never asserted.

---

## 1. What is already decided

ADR-0010 fixed two things in September, before there was anything to implement them against,
because both are rewrites if deferred:

1. **Component types are registered at runtime and storage is type-erased.** A component type
   is described by a runtime `ComponentTypeInfo`. Native Zig registers through `comptime`
   helpers that *produce* one; a mod will register the same structure through the C ABI. Same
   registry, no privileged path (I6).
2. **Entities are generational handles** (I1), and anything about an entity that is saved or
   crosses a boundary uses handles and content IDs, never pointers.

It deferred the storage strategy itself, naming sparse-set-with-dense-arrays as the first
implementation, and deferred system scheduling, parallel iteration, hierarchy and change
detection entirely.

This document decides what M4 needs on top of that: **what a component type is in the content
system**, how storage and queries are shaped, what order things happen in, how an entity is
described in content, and what a save file is.

---

## 2. Entities

```zig
pub const Entities = opaque {};
pub const Entity = core.Handle(Entities);
```

**The handle is called `Entity`, not `EntityHandle`.** Everywhere else in Foundry a handle
names a thing that also exists in some other form — `AssetHandle` refers to a loaded payload,
`TextureHandle` to a texture, `RecordHandle` to a record. An entity has no other form. There
is no entity object anywhere in the engine; the identity *is* the entity, and its components
live in storage keyed by it. `EntityHandle` would imply an `Entity` for the handle to point
at, and there is none. This is a name mods will see, so it is chosen deliberately rather than
by analogy.

Entity slots come from `core.HandlePool`, whose semantics M4 inherits without change: slot
indices are stable forever, generation 0 is reserved for `none`, a stale handle resolves to
null rather than to the new occupant, and resolution failure is a normal recoverable
condition rather than an assertion. All four of those matter more here than anywhere they
have mattered so far, because entity handles are the ones that end up in save files and in
other entities' component data.

The pool's payload per entity is deliberately tiny — a live flag is already in the slot, so
the payload starts as `void` and grows only if profiling asks. What an entity "has" is not
recorded on the entity; it is recorded in each component store (§4).

---

## 3. A component type is a schema

This is the decision the rest of the document rests on.

A component type needs a name that is stable across builds, load orders and mod lists (I2), a
size and alignment for storage, and a description of its fields good enough to serialize it,
to read it out of content, and to survive a version change (I8). Foundry already has a thing
that is exactly the last of those, is already versioned, is already registered at runtime, is
already carried inside packages that use it, and is already checkable against untrusted input:
a **schema**.

So:

> **A component type declares a `data.Schema`, and its identity is that schema's ID.**

`ComponentTypeInfo` is the runtime half — the part `data` cannot know, because `data` has no
opinion about memory layout:

```zig
pub const ComponentTypeInfo = struct {
    /// Identity, and the schema its serialized form is laid out against. One ID, so a
    /// component type cannot be two things.
    schema: data.Schema,
    /// The authored spelling, for diagnostics. Copied at registration — a mod's string
    /// does not outlive the call that hands it over.
    name: []const u8,

    size: u32,
    alignment: u32,

    ctx: ?*anyopaque = null,
    /// Bytes -> fields. Writes into a block laid out by `schema`, exactly as `.fpk` lays
    /// out a record. Never fails on valid data; may fail on allocation.
    serialize: *const fn (ctx: ?*anyopaque, component: [*]const u8, out: *FieldWriter) SerializeError!void,
    /// Fields -> bytes. **Untrusted:** the fields came from a save or from content, and a
    /// field the schema says is there may still be absent, out of range or the wrong shape.
    deserialize: *const fn (ctx: ?*anyopaque, fields: data.fpk.Fields, schema: data.Schema, out: [*]u8) DeserializeError!void,
    /// Optional. Absent means zero-initialised is a valid component.
    construct: ?*const fn (ctx: ?*anyopaque, out: [*]u8) void = null,
    /// Optional. Absent means the component owns nothing.
    destruct: ?*const fn (ctx: ?*anyopaque, component: [*]u8) void = null,
};
```

Two representations, in-memory and serialized, related by two function pointers. That is the
same split CLAUDE.md §6 already draws between authoring and runtime content, applied one level
down, and for the same reason: the fast form and the durable form have different requirements
and pretending otherwise costs one of them.

**What this buys, all of it from machinery that already exists and is tested:**

* Saving and loading a component reuses `.fpk`'s block layout — presence bitmap, fields at
  schema-computed offsets, explicit little-endian. A component that gains a field in version 2
  reads a version 1 save with the new field defaulted, because that is what `data` already
  does for records (I8, and `content-schemas.md` §3).
* Content can *define* component data, because component data is a record (§8).
* A mod declaring a component type writes `@schema` in a `.fdt` file — a thing it can already
  do, with a checker that already refuses nonsense and diagnostics that already point at the
  line.
* `fpack` can validate content that uses engine component types without linking the engine,
  for the same reason it can already validate assets: the schema is data.

**What it costs, stated plainly.** A component's *serialized* fields are limited to the closed
type list — bool, the four integer widths, two float widths, string, content ID, homogeneous
list, inline struct (`content-schemas.md` §3). Its in-memory form is any Zig type at all, but
whatever it holds must project onto that list to be saved. In practice the awkward cases are
handles: an `Entity` field and an `AssetHandle` field are each a runtime value with no content
meaning. Both have an answer, and they are different answers:

* An **entity reference** serializes as `u64` — the handle's published packing
  (`core.Handle.bits`). This works because a save preserves entity identity exactly (§9), so
  the handle on the other side of a reload is the same handle. I1 forbids serializing
  *pointers*; a handle is what it offers instead.
* An **asset reference** serializes as `id` — the asset's content ID, which is its identity
  (ADR-0021). The runtime `AssetHandle` is never saved, because it means nothing outside the
  process that issued it.

A component that cannot express itself as fields at all — a scratch buffer, a cache — is a
component that should not be saved. That case is real and gets a real answer: a type may
declare an **empty schema**, which stores and iterates normally and saves nothing. It is not
a loophole; it is the honest description of transient state, and making it explicit is better
than letting a component silently round-trip to garbage.

### Why not a separate component ID space

`data` already has two ID spaces, `SchemaId` and `ContentId`, over the same hash but
deliberately not interchangeable (`content-schemas.md` §2). A third — `ComponentTypeId` —
would have to be kept in lockstep with a schema anyway for any component that is ever saved or
authored, and "kept in lockstep" is a synonym for "eventually diverges". A component type that
is a schema cannot disagree with itself.

The cost is that every component type occupies a name in the schema space, so a component and
a record type cannot share a name. That is a feature: `foundry:transform` should mean one
thing.

---

## 4. Storage

Sparse set with dense per-component arrays, as ADR-0010 named. One `ComponentStore` per
registered type, all type-erased:

```
sparse:  []u32                 indexed by entity index -> dense position, or `absent`
owners:  []Entity              dense; parallel to `data`
data:    []u8                  dense; stride = alignForward(size, alignment)
```

* **`get`** — index `sparse` by the entity's index, bounds-checked; if the slot is `absent`,
  the component is not there. Then check `owners[dense] == entity`, comparing *both halves* of
  the handle. That second check is what makes a stale handle fail cleanly instead of reading a
  reused slot's component, and it is why `owners` exists at all.
* **`add`** — append to the dense arrays, write the sparse entry. Growing is a reallocation of
  three arrays; a pointer into `data` is a borrow valid until the next mutation, the same rule
  `HandlePool.get` already documents. Query iteration hands out pointers, and a system that
  adds components while iterating invalidates them — §5 says what to do instead.
* **`remove`** — swap the last dense element into the hole, patch the moved entity's sparse
  entry, shrink. `destruct` runs first if the type has one.
* **`destroy` an entity** — every registered store is asked to remove it. That is O(registered
  types) per destroy, each iteration a bounds check and an array read. At the tens-of-types
  scale M4 has, it is not worth a per-entity component mask, and it is not worth being clever
  about; when profiling says otherwise the fix is local to `World.destroy` and changes no
  interface.

`sparse` is sized to the entity pool's slot count and grows with it. It is dense in memory and
sparse in meaning: a world with 100,000 slots and 12 sprites spends 400 KiB on the sprite
store's sparse array. That is the trade a sparse set makes, and the alternative — a hash map
per store — is slower for the common case in exchange for memory nobody is short of. If entity
slot counts ever get large enough for this to matter, it is a paging problem with a known
shape, not a redesign.

**The interface never exposes any of the above.** No caller receives `sparse`, `owners` or
`data`; queries return entities and pointers to components. ADR-0010 requires this because
archetype storage is the anticipated upgrade and it has none of these three arrays. A caller
that has learned the layout is a caller that blocks the upgrade.

---

## 5. Queries and iteration order

A query names one or more component types and yields the entities that have all of them,
with pointers to each.

```zig
var it = world.query(.{ Transform, Sprite });
while (it.next()) |e| {
    e.get(Transform).y += velocity;
    _ = e.get(Sprite);
}
```

**Iteration is driven by the dense array of the *first* named component**, with the rest
resolved by sparse lookup and non-matches skipped.

The obvious alternative is to drive from the *smallest* store, which is faster and is what
most ECS libraries do. It is rejected here, and the reason is I9. Driving from the smallest
store makes iteration order a function of the data — the same query yields a different order
when a mod adds forty sprites, because a different array became the smallest. That is still
deterministic in the strict sense, but it makes the order impossible to reason about from the
code, and "deterministic but unpredictable" is precisely the property that turns an ordering
bug into a three-day bug. Driving from the first named component makes the order a property of
the query as written. The cost is that the caller should name the most selective component
first, and the documentation says so.

**The order itself is dense order**, and dense order is insertion order perturbed by
swap-removal. It is therefore:

* **Reproducible** — the same sequence of operations always produces the same order, which is
  what I9 asks for.
* **Not entity-index order**, and not intuitive. Removing a component moves the last element
  into the hole. This is the same caveat `HandlePool`'s iterator already carries, for the same
  reason, and it is stated in both places on purpose.
* **Preserved across a save and reload**, because the save writes dense order and the load
  reproduces it (§9). Without that, a saved world would resume in a different iteration order
  from the one it was saved in, and the M4 exit criterion about a fixed scenario reproducing
  itself would be quietly false.

A system whose *results* depend on order — not merely its traversal, but its answer — must
sort explicitly, and `Entity` is the key to sort by. This is written down rather than
prevented, because preventing it means promising an order that archetype storage could not
keep.

**Structural change during iteration** — adding or removing components, creating or destroying
entities — invalidates the iterator and the pointers it handed out. M4 does not support it,
and does not silently tolerate it: the world carries a mutation counter, the iterator captures
it, and `next` asserts it is unchanged. This is an assertion rather than a validation because
it is a programmer error in engine or game code, not untrusted input. The escape hatch is the
ordinary one: collect entities into a frame-arena list, then act on them after the loop.

---

## 6. Registering a component type

Native Zig code registers through a `comptime` helper that derives everything from the struct:

```zig
pub const Transform = struct {
    pub const component = "foundry:transform";
    x: f32 = 0,
    y: f32 = 0,
    rotation: f32 = 0,
    scale: f32 = 1,
};

try world.registerComponent(scene.componentType(Transform));
```

`componentType` builds the schema from the struct's fields — Zig type to `FieldType`, a Zig
default value to `Presence.default`, no default to `required` — and generates `serialize` and
`deserialize` over the same field order. Types that do not project onto the closed list are a
compile error naming the field, not a runtime surprise. `Entity` and `AssetHandle` fields are
recognised specially, per §3.

A struct may instead declare `pub const schema: data.Schema` and its own two functions, for
the cases where the in-memory and serialized forms genuinely differ. The derived path is the
convenience; the explicit path is the contract.

**A mod registers the identical structure** — its `@schema` declaration in a `.fdt` file, and
its function pointers through the C ABI at M7. The registry cannot tell the two apart, and
that is the point (I6). What the ABI needs from this design is already true of it: the info
struct is C-shaped, carries `ctx` rather than a closure, and returns result codes rather than
Zig error unions at the boundary.

**Registration is checked**, because it is where a wrong answer is cheapest to catch:

* The schema goes into the world's `data.Registry`, so the existing rules apply unchanged — a
  second registration of the same ID at the same version must be identical, and a version bump
  must be additive.
* `alignment` must be a power of two and at least 1, and a native type's must match its Zig
  type's. **`size` may be zero**, which means a marker: a component that records only that an
  entity has it, stores no bytes, and ordinarily declares an empty schema because there is
  nothing to save.
* `name` must parse as a `namespace:name` and must hash to `schema.id`. The spelling exists so
  a diagnostic can print something a person can grep for, and an unchecked one would eventually
  print a name the schema does not have.
* Registering after the world has *ever* created an entity is refused — slots used, not live
  entities. Storage is allocated per type at registration, and a type appearing mid-run would
  silently have no data for entities that already exist, an emptiness indistinguishable from
  "none of them has this component". Every registration happens during startup, which is also
  when a mod's would.

---

## 7. Systems

```zig
pub const System = struct {
    id: core.ContentId,
    name: []const u8,
    ctx: ?*anyopaque = null,
    update: *const fn (ctx: ?*anyopaque, world: *World, tick: Tick) void,
};

pub const Tick = struct {
    tick: u64,
    delta: core.time.Duration,
};
```

`Tick` is `scene`'s own, not `app.Step`. `app` is L4 and `scene` cannot see it, and the part of
a step a system is entitled to is the fixed timestep and the tick number — not the frame's
input, which came from a device, and not `alpha`, which exists for interpolating a render and
has no business inside a simulation step (`app-and-frame-loop.md` §2).

**Input reaches systems as data the game put in the world.** The game reads
`platform.InputSnapshot` at L4 and writes what its simulation needs into components, or holds
it in the `ctx` its own systems were registered with. That is not a workaround for the
layering; it is what makes replay possible later, because the simulation's inputs become
values that were written down.

**There are no "resources".** The ECS-standard singleton store is deliberately absent: a
singleton is an entity with one component, which already works, has one storage path to
serialize and one to save, and needs no second concept. Inventing a parallel storage kind
before something needs it is rule 7.

**Order is registration order**, and `update` runs the list front to back once per fixed step.
That is the simplest thing that works, and it is honest about what M4 needs: every system in
existence at M4 is registered by one program that knows what it wants.

It is also not sufficient forever, and the successor is known: **`before` and `after`
constraints naming other systems by content ID, with a deterministic topological sort**. That
is what a mod needs to insert a system between two engine ones without editing the engine, and
it is purely additive — a system registered with no constraints keeps its registration-order
position. It is not built now because there is no second registrant to have a constraint with,
and a scheduler with one client is a scheduler designed against a guess. §13 records the
trigger.

---

## 8. Entities in content

M4's exit criteria require a scene of entities defined in content data. That must be expressible
in `.fdt` **without adding syntax**, because ADR-0020 is settled and content written today has
to keep parsing.

The closed type list has no heterogeneous list, so an entity cannot carry an inline block of
arbitrary components. It does have `[id]`, and that turns out to be the better shape anyway:

```fdt
# Each component instance is a record, with its own content ID.
foundry:transform  sandbox:player.transform  { x 0  y 0 }
foundry:sprite     sandbox:player.sprite     { texture sandbox:textures.hero  layer 1 }

# A template is a list of them.
foundry:entity sandbox:entity.player {
    components [ sandbox:player.transform  sandbox:player.sprite ]
}

# A scene is a list of templates. Naming one twice spawns it twice.
foundry:scene sandbox:scene.main {
    entities [ sandbox:entity.player  sandbox:entity.goblin  sandbox:entity.goblin ]
}
```

Spawning a template: for each named ID, look the record up in the store, take its schema ID,
find the component type registered for that schema, and `deserialize` its fields into fresh
storage on a new entity. Two records of the same schema in one template is an error naming
both, because an entity has at most one component of a type.

**Why component instances are separate records rather than an inline block.** Because
`content-schemas.md` §7's rule — anything a mod might want to override on its own is a record
with a content ID, and anything it would not is an inline struct — answers this question
directly. A mod that wants the player's sprite changed and nothing else overrides
`sandbox:player.sprite`, one record, and never mentions the template. With an inline block it
would have to restate the whole entity, and every future field of every other component on it,
to change one texture. The verbosity of a content ID per component instance is the price of
that, it is paid in authored content rather than in the engine, and a tilemap — where the
verbosity would actually hurt — is M5 and is a different representation entirely.

**What this does not do at M4 is per-instance variation.** Two goblins from one template spawn
identical. Systems move them apart; a save records where they ended up. The general answer —
an instance that names a template plus a handful of overridden fields — is `@patch`, whose
syntax M3 froze and whose semantics M3 deliberately did not implement. That is the right place
for it and inventing a second override mechanism here would be a mistake worth avoiding twice.

**Content changing under a running world.** A spawned entity is a copy, independent of the
records it came from. Hot reload does not respawn it, and nothing here watches content. That is
deliberate: re-applying a template to a live entity means deciding what happens to state a
system has since changed, which is an editor question and not a loading question.

**Where `asset` would come in.** A `sprite` component holds a texture's content ID and stays a
content ID. Turning it into an `AssetHandle` is `render2d`'s loader through `asset.Registry`,
called by the game's rendering system, which lives above both. If `scene` acquired assets it
would need to know which fields are assets and what to do when one is missing mid-spawn, and
it would own a lifetime it cannot see the end of. It does not, and so M4 does not wire the
dependency ADR-0007 allows.

---

## 9. Saving a world

A save is a distinct format, `.fsav`, with its own magic and a version in a field rather than
in the magic — the same discipline `.fpk` uses, for the same I8 reason.

It is **not** a `.fpk`. Reusing the package format would require giving every entity a content
ID, and a generated `save:entity.00417` is an identity derived from position, which is the
precise anti-pattern I2 exists to forbid. Content IDs name authored things. Entities are not
authored.

What a save contains:

* **A component type table** — content ID, version and the full schema of every type present,
  carried in the file. A save can therefore be read against the schema it was written with,
  and a build whose `foundry:transform` has gained a field fills that field from its default
  rather than misreading bytes. This is the same guarantee a package gives, achieved the same
  way: carry the schema, do not assume the reader's.
* **The entity pool's exact state** — slot count, and per slot its generation and whether it is
  live, plus the free list head and order. A reloaded world hands out the same handles the
  original would have.
* **Per component type, its dense arrays** — the owner entity for each element in dense order,
  then the serialized blocks in the same order.

Preserving entity identity exactly is what makes the rest simple. An `Entity` inside a
component's data is a `u64` that stays correct with no remapping pass, which in turn means
`scene` never has to know which fields are entity references — a fact that would otherwise have
to be maintained in two places and would be wrong in mod-registered components first.
Preserving dense order is what makes iteration order survive the round trip (§5).

**The reader trusts nothing.** Counts are bounded before allocation, every offset is checked
against the file's length, every owner entity is checked to be live in the pool the same file
just described, every dense index is checked to be in range, and a component type the build
does not know is *reported and skipped*, not fatal — a save from a session with a mod loaded
should open without it, minus that mod's components. The `.fpk` reader's mutate-one-byte test
is the model, and the save reader gets the same treatment.

**Load is into a fresh world**, whose registered component types may differ from the writer's.
Merging a save into a populated world is a different operation with different rules — handle
collision above all — and it is not owed anything by M4 beyond not being designed out. It
isn't: a merge would be a remap pass over a load, and the type table gives it what it needs.

---

## 10. Determinism

I9 in this module, concretely:

* Systems receive a fixed `delta` and an integer `tick`. Nothing here reads a clock, and
  nothing can — `platform` is not below `scene`.
* No global RNG. A system that needs randomness holds a `core.Pcg32` in the state it was
  registered with, or in a component, and either way it is seeded explicitly and saved with the
  world if the world's reproduction depends on it.
* Iteration order is documented and reproducible (§5), and survives a save (§9).
* Nothing depends on pointer values. Entities are compared and sorted by handle.
* The spawn order of a scene is the order of its `entities` list, and the component order
  within a template is the order of its `components` list. Both are what the author wrote, in a
  file, in order — not a hash map's iteration.

The bit-exactness that ADR-0013 declines to promise is not needed by any of the above.

---

## 11. What this exposes to mods

Adding a subsystem includes deciding what it exposes (CLAUDE.md §5), even when the answer is
"nothing yet". M4 has no ABI, so nothing here is reachable from a mod *yet*; what follows is
what the design commits to making reachable at M7, and what it is careful not to promise.

**Reachable, by construction:**

* Declaring a component type — a schema in `.fdt`, plus the info struct through the ABI for a
  native mod. A script mod at M8 gets the same registry.
* Defining component instances, entity templates and scenes as content, and overriding any of
  them by content ID with no engine involvement.
* Registering a system.
* Creating and destroying entities, adding and removing components, and querying.

**Deliberately not promised:**

* Iteration order beyond §5's rule. A mod that depends on more is a mod that archetype storage
  breaks.
* Anything about storage layout. Queries are the interface.
* The save format's byte layout. It is versioned and it is the engine's; a mod reads a world
  through the API, not through the file.

**Compatibility surface, named so it is treated as one:** component type IDs, their schemas'
field names, entity template and scene schema IDs. Renaming any of them breaks saves and mods.
ADR-0010 already says component names are a compatibility decision rather than a style one;
this is the list that sentence refers to.

---

## 12. Errors

Zig error unions internally, meaningful and narrow, with the split the rest of the engine uses:
a programmer error asserts, untrusted input is validated and returns.

| Error | Means | Untrusted? |
| --- | --- | --- |
| `UnknownComponentType` | No type registered for that schema ID | yes — content or a save |
| `ComponentTypeExists` | Registered twice, incompatibly | no — registration is engine or mod startup code |
| `ComponentExists` | The entity already has one of that type | no |
| `NoSuchEntity` | The entity is stale or was never created | yes |
| `ComponentSizeMismatch` | The supplied bytes are not the type's size | no |
| `DuplicateComponent` | A template names two records of the same type | yes — content |
| `EntityLimit` / `ComponentLimit` | A bound was exceeded | yes |
| `NotAnEntityTemplate` / `NotAScene` | The record is not the schema asked for | yes |
| `SaveCorrupt` / `SaveUnsupportedVersion` | The file is not readable | yes |

Resolving a stale `Entity` is **not** an error. It returns null, everywhere, and callers are
expected to handle it — handles arrive from saves, tools and mods, and a stale one is a normal
condition (`core-memory-and-handles.md` §2).

A failure logs at `warn` and returns; `log.err` stays reserved for a failure with no other way
to report itself, which is also what keeps the test runner's error-counting meaningful.

---

## 13. Open questions

Recorded rather than resolved, each with what would force it.

1. **System ordering constraints.** `before`/`after` by content ID with a deterministic
   topological sort (§7). *Forced by:* the first registrant that cannot arrange its own
   position — in practice the first mod, or the first engine subsystem that must run between
   two of the game's systems. Additive, so nothing has to be built now to keep it possible.
2. **Per-instance overrides in a scene** (§8). The answer is `@patch` semantics, which are
   frozen in syntax and unimplemented. *Forced by:* the first scene that wants two of something
   in different places without two templates — likely the first real sample in M5.
3. **The per-entity component mask.** Destroy is O(registered types) (§4). *Forced by:*
   profiling, at an entity churn rate no current sample approaches.
4. **Archetype storage.** ADR-0010's anticipated upgrade, kept possible by §4's interface rule.
   *Forced by:* profiling showing sparse-set iteration is the bottleneck at the entity counts a
   real game needs.
5. **Merging a save into a live world** (§9). *Forced by:* streaming, or an editor that loads a
   fragment.
6. **Whether a world holds its own `data.Registry` or borrows the engine's.** Borrowing is
   simpler and matches how `asset` takes a store; owning makes a world self-contained, which a
   tool loading two worlds at once would want. M4 borrows. *Forced by:* the first tool that
   wants two.

---

## 14. Deliberately not here

* **Hierarchy and parenting.** A transform hierarchy is a component and a system, and it can be
  added without touching storage. Building it now would fix a policy — dirty flags, traversal
  order, what happens to a child when a parent dies — with no consumer to judge it.
* **Change detection**, **parallel iteration**, and **any threading**. ADR-0010 defers all
  three; the job system is a post-M5 decision (CLAUDE.md §9). Nothing here assumes single-
  threaded forever: storage is per type, systems are a list, and the interface hands out
  borrows with stated lifetimes rather than long-lived pointers.
* **Prefab nesting** — a template that includes another template. Wanted eventually, an
  override-semantics question, and not needed to spawn a scene.
* **Spatial queries.** M5, with the tilemap and collision, where there is something to
  accelerate.
* **A world's own frame loop.** `app` drives; `scene` is stepped. Same relationship
  `app-and-frame-loop.md` §1 draws with the game.

---

## 15. Implementation order

Six steps, ordered so each leaves the tree green and the sandbox runnable, and so none is a
rewrite of the one before.

1. **The module, entities, and the type registry.** `scene` in the build graph with `core` and
   `data`; `Entity`; `World` with entity create/destroy; `ComponentTypeInfo` and registration,
   including the schema going into `data.Registry` and every check in §6. Layering confirmed by
   breaking it, as `data`'s was.
2. **Type-erased storage.** `ComponentStore` per §4 — add, get, remove, swap-removal, the
   owner check, destroy across all stores. Tested against a component type built by hand, so
   the storage is proven before the `comptime` sugar exists to hide it.
3. **The `comptime` wrapper.** `scene.componentType(T)`: schema derivation, `serialize` and
   `deserialize` generation, the `Entity` and `AssetHandle` field rules, compile errors for
   what does not project. Tested by round-tripping a struct through its own generated pair.
4. **Queries.** One and many components, first-named iteration, the mutation guard. This is
   where the interface either leaks the layout or does not, so it is worth writing the test
   that would catch it: a query's results depend on nothing but entities and components.
5. **Systems, and the sandbox gets a world.** `System`, registration, ordered update from
   `app`'s fixed step. The sample stops holding an array of sprites and holds entities, which
   is the first honest test of whether the interface is usable.
6. **Content and saves.** `foundry:entity` and `foundry:scene` schemas; spawning a template and
   a scene from the store; the `.fsav` writer and reader with the trust rules of §9. Ends with
   the exit criterion: a scene from content, updated by systems, saved, reloaded across a
   restart, and a fixed scenario run twice producing identical state.

The factoring this needs from `data`: **the record-block writer inside `fpk.write` becomes
callable on its own**, so a save can lay out a component block exactly as a package lays out a
record. It is the same code with the same schema, and having two of it is the way the two
formats would drift apart.

---

## Resolution: entities and the type registry (implementation, 2026-09-05)

Step 1 of §15, built as `engine/src/scene/` — `entity.zig`, `component.zig`, `limits.zig`,
`world.zig`. 18 tests. What building it settled or changed:

**A registered component type is a `core.Handle`, not an index.** The document did not say,
and an index was the obvious choice: nothing unregisters a type, so nothing can go stale, and
the generation would always be 1. A handle was taken anyway, for a reason worth recording
because it will not be obvious later — **unloading a mod unregisters its component types**,
and on that day every index held anywhere becomes a dangling reference with no way to detect
it. The generation is four bytes now and a rewrite of every holder afterwards. Because nothing
is removed today, `handle.index` is dense and is exactly the position of the type's storage,
which is what step 2's flat array of stores indexes by.

**The world keeps the schema *handle*, never a copy of the schema.** `data.Registry` updates a
schema in place behind its handle when a later package extends it, so a component type
registered before a mod loads follows that mod's added field without being re-registered. A
copy taken at registration would have been the one thing in the engine that quietly did not,
and it is the sort of divergence that shows up as a field reading zero rather than as an
error. There is a test for exactly that.

**Size zero is legal and means a marker.** §6 originally required a non-zero size. Marker
components — "is player", "is dead" — are ordinary ECS practice, `@sizeOf(struct {})` is 0 in
Zig, and a sparse set stores presence in `sparse` and `owners` whether or not there are bytes
to go with it. Refusing them would have been a limitation discovered by the first person who
wanted one, in exchange for nothing.

**`serialize` and `deserialize` are not in `ComponentTypeInfo` yet.** They arrive with the
`comptime` wrapper at step 3, because until there is a field writer for them to speak to, a
signature would be a guess written into a struct that mods will implement. Nothing else in the
file moves when they land.

**What was confirmed rather than decided.** The layering was checked by breaking it: `scene`
importing `platform` fails with *"no module named 'platform' available within module 'root'"*,
the same message `data`'s check produced — and, as with `data`, only once something
*references* the import, because Zig analyses top-level declarations lazily. `scene` therefore
cannot read a clock, cannot read input, and cannot open a file, by construction rather than by
convention (I7).

---

## Resolution: storage (implementation, 2026-09-05)

Step 2 of §15, built as `engine/src/scene/store.zig` and wired into `World`. The sparse set is
§4's, unchanged in shape. What building it settled:

**The dense byte array over-allocates and aligns its own base.** A component's alignment is a
runtime value and `Allocator.alloc` cannot express one — `alignedAlloc` takes it at `comptime`,
and `rawAlloc`, which does take it at runtime, says in its own doc comment that it is not for
callers. So the block allocates `bytes + alignment - 1` through the ordinary interface and
keeps an aligned pointer into it. The waste is at most fifteen bytes per store for any
component anyone has yet wanted, and it stays inside the public API. There is a test that walks
64 additions of a 16-byte-aligned type through several reallocations and checks the alignment
of every one.

**`addComponent` checks its arguments before it checks the world's state.** Bytes of the wrong
size mean the caller is holding the wrong type entirely, which is a more fundamental mistake
than adding a component twice — and being told "already has one" while holding the wrong struct
sends somebody to look in the wrong place. The order is `UnknownComponentType`,
`ComponentSizeMismatch`, `NoSuchEntity`, `ComponentExists`.

**Supplied bytes are copied *instead of* constructing, never over a construction.** The
constructor runs only when no initial value is given. Running it first and then overwriting
would be a double initialisation, which is exactly what a component type that owns memory
cannot survive — and the whole point of `construct` and `destruct` existing is that such types
are allowed.

**§12's table gained two errors.** `NoSuchEntity`, because resolving a stale entity returns
null (which the table already said) but *adding a component to one* has no sensible alternative
to an error; and `ComponentSizeMismatch`, which is the check that stops a caller writing past a
component slot.

**A marker's `at()` returns a valid empty slice**, not a null pointer. The block keeps a
non-null, correctly-aligned address it never dereferences, so `ptr[0..0]` is a legal empty
slice at every stride including zero. Swap-removal still moves the owner for a marker — there
is simply nothing to copy beside it.

**Confirmed rather than decided:** the owner check is what makes a stale entity safe, and the
test that proves it reuses a slot deliberately — entity `3#1` has a component, is removed, and
`3#2` is given its own. The sparse array answers for index 3 either way, and only comparing the
generation separates them.

---

## Resolution: the `comptime` wrapper (implementation, 2026-09-05)

Step 3 of §15, built as `engine/src/scene/derive.zig`. `scene.componentType(T)` derives a
schema from a Zig struct and generates `deserialize` and, where the struct allows it,
`construct`. What building it settled:

**An asset reference in a component is a `core.ContentId`, not an `AssetHandle`.** §3 said
both `Entity` and `AssetHandle` fields would be recognised specially, with an asset
serializing as its content ID. Implementation showed that cannot be what the sentence means:
an `AssetHandle` does not carry a content ID, so serializing one as an `id` would need the
asset registry — which `scene` does not have and, per §8, deliberately does not take. The
resolution is simpler and was already implicit: **a component that references an asset holds
the content ID**, which is what an asset's identity actually is (ADR-0021), and the runtime
handle is the rendering system's business. So the wrapper needs no `AssetHandle` case at all,
which is the same fact as `scene` needing no `asset` dependency.

**`deserialize` does not take the schema; the fields already carry it.** §3's signature passed
both `data.fpk.Fields` and a `data.Schema`. `Fields` holds the field list it was read against,
so the second argument could only ever agree with the first or be a bug. It is gone.

**Fields match by position, not by name.** A schema may only append (`content-schemas.md` §3),
so field *i* is field *i* in every version that has it. A record written against an older
version simply has fewer fields, and the ones beyond it keep whatever `construct` left there.
That is the whole of I8's forward compatibility for components, and it costs one comparison
per field rather than a name lookup per field per entity.

**`construct` is generated when every field has a Zig default**, and that is what makes the
paragraph above work: a field the record predates has to fall back to the *type's* default,
not to zero. A component whose `solid: bool = true` came back false after loading old content
would be a silent, plausible-looking bug. There is a test for exactly that.

**Components hold no strings and no slices.** The deserialize signature has no allocator —
deliberately, since it writes into storage the world already owns — so a component cannot
acquire memory while being read. Variable-length data is referenced by content ID instead.
The compile error for a pointer field says so.

**Arrays are refused for now**, with an error explaining why: a list's elements live outside
the block holding the rest of the component, and where they live is part of the save format
(step 6). A fixed set of named values is an inline struct today, which is what
`content-schemas.md` §3 prefers anyway — it is why there is no colour type and no vector type.

**The integer and float types are exactly the closed list.** A `u8` field is a compile error
rather than a silent widening to `u32`. Widening would mean the schema saying one thing and
the struct another, with a range check on the way back in; it is additive if it is ever
wanted, and refusing it now keeps the round trip trivially lossless.

**Tested through the real pipeline, not a stub.** Every deserialization test compiles `.fdt`
text with the derived schema registered, writes a `.fpk` with `fpk.write`, loads it into a
`data.Store`, and deserializes the record that comes back — so what these tests read is what
`fpack` actually produces.

---

## Resolution: queries (implementation, 2026-09-05)

Step 4 of §15, built as `engine/src/scene/query.zig` plus `World.query` and `World.queryOf`.
§5's rules are unchanged; what building it settled is how the iterator is shaped.

**A `Query` holds its component types by value, not as a borrowed slice.** The first attempt
borrowed, which is the obvious thing — and it makes the typed wrapper self-referential, since
the wrapper owns the handle array the inner query points at, and a struct returned by value
has its own address. Holding sixteen handles inline costs 128 bytes on the stack of something
built once per system per frame, and it buys a query with **no lifetime rule of its own**: it
can be returned, copied and stored, and the only thing that has to outlive it is the world.
`max_components` is that array's length, and it is a real limit rather than an arbitrary one.

**The stores slice a query borrows is stable, and §6 is why.** A query holds `[]ComponentStore`
into the world's array. That array can only grow when a component type is registered, and
registration is refused once a world has ever created an entity — so the slice cannot be
invalidated while anything is iterating. That rule was written to stop a type appearing with no
data for existing entities; it turns out to be what makes the query cheap as well.

**A query naming an unregistered type matches nothing, and is not an error.** A system written
against a component a mod defines should do nothing when the mod is absent, and say so by
matching nothing rather than by failing. It logs at `debug` and yields no entities.

**The order decision is tested by being reversed.** Three entities have `pos`; two have `vis`,
added in the opposite order so the two dense arrays genuinely disagree. `query(.{pos, vis})`
yields `b, c` and `query(.{vis, pos})` yields `c, b` — the same set, and an order that is a
property of the query as written. Driving from the smallest store would have made both of those
the same, and made them change when a mod added a sprite.

**The structural-change guard is an assertion and is therefore not unit-tested.** It panics, and
a passing test cannot observe a panic. It is stated here and in the module doc instead, along
with the escape hatch: collect entities into a frame arena, act on them after the loop.

---

## Resolution: systems, and the sandbox's world (implementation, 2026-09-05)

Step 5 of §15: `engine/src/scene/system.zig`, `World.registerSystem`, `World.update`, and the
sandbox converted from an array of seeds to a world of entities. The sample is the first
consumer that is not a test, and it settled two things.

**A world cannot borrow the engine's schema registry.** §13's sixth open question asked
whether a world should own a `data.Registry` or borrow one, said M4 borrows, and expected a
tool wanting two worlds to force the answer. Hot reload forced it first: the engine builds a
**whole new content set with a whole new registry** and swaps it (`app-and-frame-loop.md` §8),
so a world holding a pointer into the engine's would hold a freed one the moment somebody
saved a file. The sandbox therefore owns the registry its world borrows. Component schemas are
declared by code and outlive any reload; content schemas are rebuilt from packages on every
one, and that difference is the answer.

This leaves a real question for step 6, recorded here rather than resolved: content that
*defines* component instances is checked against the content registry, which must therefore
know the component schemas. The mechanism already exists — `asset.schemas.registerAll` puts
the engine's own asset schemas into each new content registry as it is built — and component
schemas want the same treatment.

**A system that is a function of the tick needs no context at all.** The sandbox's orbit
system computes each entity's angle from `tick.tick` and the fixed delta, so its motion is
reproducible by construction rather than by care: the same run produces the same positions on
a fast machine and a slow one. The version this replaced computed the same angle from
`engine.elapsed()`, which was already right for the same reason — the conversion just moved
where the number comes from.

**§5's order rule paid off in the sample rather than in a test.** Picking and drawing both
query `.{ Transform, Visual }`, in that order, so "topmost" means the same thing to the pick
as it does to the batcher's `(layer, submission index)` sort. Had the query driven from the
smallest store, the two would still have agreed today and could have stopped agreeing the
first time a mod added a component to some of the sprites.

**Verified by running it**, not by inference: 4,176 sprites headless under the null backend
and 4,185 with a selection on screen under Metal, both a clean exit; picking returns an entity
and its outline and label draw; and a mod recompiled *while the program was running* changed
the field from 250 entities to 600 at the top of a frame, with every entity destroyed and
respawned through the same path that built them at startup.
