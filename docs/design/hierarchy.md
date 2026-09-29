# Design: M21 — Hierarchy: the engine's transform components, propagation, re-parenting and 3D in the overlay

**Status:** Accepted 2026-09-29, when the owner requested Step 1; §13 is accepted as written.
Steps 1 and 2 of six are complete; Step 3 has not begun.
**Date:** 2026-09-29
**Baseline:** `00f39d3`, tag `m20`. M0–M20 are complete.
**Decisions:**
- **Constraining it:** ADR-0050 (the engine declares the 3D transform and hierarchy
  components), ADR-0048 (conventions), ADR-0010 (runtime component types), ADR-0013
  (determinism), ADR-0025 (the overlay reaches only for calls the ABI could expose) and
  ADR-0053 (assets are not the renderer).
- **Proposed:** none. ADR-0050 already decides everything here that constrains future work.
  This document fixes what it left to M21: the field layouts, where the code lives, the
  propagation point, the depth limit, and how the rules hold against data nobody validated.

This is the milestone `3d.md` §10 allocates as M21, and it follows `3d.md` §7 and §7.1, which
are locked. It touches `scene`, `debug` and `samples/sandbox3d`, so it writes its own document,
as `meshes.md` did.

## 1. Purpose and boundary

From `3d.md` §10's M21 row:
- **Runnable result:** nested moving objects, inspected live in the overlay.
- **Exit condition:** §7's rules hold, and a saved hierarchy loads back to the same world poses.
- **Regression coverage:**
  - propagation independent of spawn order;
  - a rotated, non-uniformly scaled parent chain propagating a sheared world exactly;
  - keep-local accepted under that chain;
  - keep-world accepted for uniform scale, and for non-uniform scale aligned with the child;
  - keep-world refused as `NotRepresentable` for a shearing parent, and detaching a sheared
    child refused too;
  - `SingularParent` for a zero-scale parent;
  - a reflection that decomposes canonically;
  - after every refusal (cycle, depth, singular, not representable), a snapshot of every
    entity's components, byte-identical to the one before;
  - the despawn cascade;
  - a save round trip.

**In M21:**
- `foundry:transform`, `foundry:parent` and `foundry:world_transform`, registered by `scene`
  when a world enables the hierarchy (§3);
- one propagation, and an on-demand world pose that reads without writing (§4);
- keep-local and keep-world re-parenting, and the despawn cascade (§5);
- the rules held against data no call validated: saves, mods' raw component writes and hand
  edits (§6);
- the overlay showing the hierarchy and world poses, and `render3d`'s frame counts (§7);
- `sandbox3d` building an animated hierarchy in a `scene` world, with save and load (§8).

**Not in M21:**
- **Authoring a hierarchy in content.** A template can author `foundry:transform`, but not a
  parent (§3.3). An additive `children` field on `foundry:entity` waits for its trigger (§12).
- **The public ABI.** The names enter it in `FoundryApi_v6`, M25's (ADR-0050). §3.5 says what
  existing calls see meanwhile.
- **Dirty tracking and parallel propagation.** Propagation recomputes every world transform
  each time it runs. The trigger is a measurement (§12).
- **An engine component that names a model.** Which component a game uses to say "draw this
  model here" is the game's (`3d.md` §3, row 6). `sandbox3d` declares its own.
- **Gizmos, picking and editing in the overlay.** The overlay stays read-only
  (`debug-overlay.md` §7.4). Editing poses is the editor's, with its own milestone.
- **Physics, animation and light** are M22–M24.

## 2. What exists

Read from the code at `00f39d3`:

- **`core.math`** (`engine/src/core/math.zig`) has everything the pose needs. `Transform` is an
  `extern struct` of `translation: Vec3`, `rotation: Quat` and `scale: Vec3`. It has `toMat4`
  (`T · R · S`) and `isValid`. It also has `fromMat4Exact`, `3d.md` §7.1's canonical
  decomposition, which M20 moved into `core` with `representation_epsilon = 1e-5` and
  `determinant_epsilon = 1e-6`. `Mat4` has `mul`, `inverse` (a relative singularity test),
  `determinant` and `mulPoint`. `Quat.validated` accepts a rotation within tolerance of unit
  length.
- **`scene`** (`engine/src/scene/`) is M4/M5's type-erased world:
  - **Entities:** `Entity` is an 8-byte `core.Handle`.
  - **Component types:** registered at runtime from a `ComponentTypeInfo`, whose identity is a
    `data` schema. `componentType(T)` derives one from a Zig struct, nested structs included.
    Registration must happen before any entity exists (`WorldNotEmpty`).
  - **Component data:** `addComponent`, `getComponent` and `removeComponent` hand out raw bytes
    by type.
  - **Systems:** registered and run in registration order by `World.update(tick)`.
  - **Templates:** `spawn` and `spawnScene` build entities from `foundry:entity` and
    `foundry:scene` records, deserializing each component record.
  - **Saves:** `save` and `load` write and read `.fsav`, which preserves entity identity
    exactly. So an `Entity` inside component data is saved as its 64-bit packing and needs no
    remapping (`entity-storage.md` §9).
- **No engine component type exists.** ADR-0050 is the first exception to M5's rule. The name
  `foundry:transform` appears today only in `scene`'s own tests (`world.zig`) and in doc
  examples (`schemas.zig`, `derive.zig`, `entity-storage.md`). Each uses it for a 2D `{ x y }`
  type, so each must be renamed before the engine registers the real one (§3.1).
- **`debug`** (L5) has an entity inspector (`debug/entity_panel.zig`). It lists live entities
  and shows a selected one's components by serializing them, as a save does. It says "not
  saved, so not shown" for a type without a serializer, which is what a derived world
  transform will be. `debug.Sources` carries a `scene.World`, a `render2d.Renderer` and an
  `audio.Mixer`. `debug` may not import `render3d` today.
- **`samples/sandbox3d`** draws M20's glTF room and a crate grid through `render3d.Content`,
  and a code-built cube. It has no `scene` world and no overlay, and it imports neither `scene`
  nor `debug`. `samples/sandbox` shows the pattern it will follow: a game-owned world, a
  `debug.Overlay` whose panels are toggled by key, and F5/F9 to save and load.
- **The public ABI** (`abi/calls_scene.zig`, v1–v5) exposes the world generically. Mods create
  and destroy entities and add, read and write components by schema ID, through each type's
  serializer.

## 3. The components (`scene`)

### 3.1 Where they live, and how a world gets them

**`engine/src/scene/hierarchy.zig`** holds the three types, the propagation, the re-parenting
calls and the checks that make them safe. It lives in `scene` because the components are
entities' data and the rules are about entities (ADR-0050). Nothing here needs `asset`,
`render3d` or `platform`, so `scene`'s imports do not change.

**A world opts in with `World.enableHierarchy()`.** That call registers the three types under
their engine names and records their handles in the world. Like any registration, it happens
before entities exist, and it is refused with `WorldNotEmpty` otherwise.
- **Why opt-in, not always:** ADR-0050 says a 2D game need not use any of this. `samples/sandbox`
  and `samples/room` should not grow three unused types in their saves.
- **Why the world must know:** the despawn cascade (§5.4) has to hold for every caller of
  `World.destroy`, the ABI's `entity_destroy` included. A helper beside the world could not
  make it hold for callers that do not know the helper exists.
- A second call is a no-op, so a host and a library that both enable it do not conflict.

**The rename comes first.** `scene`'s tests register a 2D `foundry:transform { x y }`, and
`schemas.zig`, `derive.zig` and `entity-storage.md` use it as their example. The tests move to
`test:position`, and the examples to a game's own namespace. That is the only change to existing
behaviour in Step 1.

### 3.2 The layouts: permanent public names

Each is a `data` schema at version 1. Every field name below is a public name (CLAUDE.md §7).
They are the names `foundry:model`'s parts already use, so an author sees one vocabulary for a
pose.

```fdt
foundry:transform sandbox3d:table.transform {
    translation { x 0  y 0.75  z 0 }        # metres, in the parent's frame
    rotation    { x 0  y 0  z 0  w 1 }      # a unit quaternion (x, y, z, w), ADR-0048
    scale       { x 1  y 1  z 1 }           # along the rotated axes; negative is a reflection
}
```

- **`foundry:transform`** is `core.Transform`'s own layout: 40 bytes, derived by
  `componentType`. The defaults are the identity pose, so a template writes only what differs.
  It is saved and authorable.
- **`foundry:parent`** is `{ entity }`, one `Entity`, saved as its 64-bit packing through the
  existing entity-reference path. It is saved and never authored (§3.3).
- **`foundry:world_transform`** is a 64-byte column-major `Mat4`. It is never saved, never
  authored, and written only by propagation. It has no serializer, so its schema has no fields.
  It is read through `hierarchy.worldTransform` (§4.3), the same call the overlay and, in M25,
  the ABI use.

**A transform is validated where it enters.** `foundry:transform`'s deserializer, used by
templates and saves, refuses a value `Transform.isValid` refuses. That is a non-finite
component, a rotation not within tolerance of unit length, or a non-finite scale; each is
refused as `ValueOutOfRange`. A zero scale is legal in a local pose, because a collapsed
object is a real thing to author. Only keep-world refuses it, when it would have to divide
by it (§5.2).

### 3.3 What content can author

`scene.schemas.registerAll`, which the package compiler calls before compiling, gains
`foundry:transform`. A template can then write a pose:

```fdt
foundry:transform sandbox3d:moon.transform { translation { x 0.4 y 0 z 0 }  scale { x 0.3 y 0.3 z 0.3 } }
foundry:entity    sandbox3d:entity.moon    { components [ sandbox3d:moon.transform  sandbox3d:moon.model ] }
```

**`foundry:parent` and `foundry:world_transform` are not registered for content.** A package
that names them fails to compile with the ordinary unknown-schema diagnostic.
- **Why a parent cannot be authored:** an `Entity` means something only inside the world that
  made it. A number in a template would name whatever entity happened to occupy that slot.
- **The runtime check:** the compile-time refusal is not the only guard, because a store can
  be built by other means than the compiler. So `World.spawn` refuses a template naming a
  `foundry:parent` record with a new `SpawnError.ParentNotAuthorable`, before creating
  anything. A world transform in a template is already refused as `NotConstructibleFromData`,
  because the type has no deserializer.
- **Authoring a hierarchy** as data (a template's children, say) needs a reference that means
  something across a spawn. It is additive later (§12).

### 3.4 Limits

`scene.Limits` gains **`max_hierarchy_depth = 64`**, the same bound M20's glTF import puts on a
node chain. Depth counts edges: a root is depth 0. A chain that would exceed it is refused when
set (`TooDeep`), and cut when found in data (§6).

### 3.5 What the public ABI sees in M21

Nothing is added; the names enter `FoundryApi_v6` in M25 (ADR-0050). What v1–v5 consumers see
in a world whose host enabled the hierarchy follows from their generic calls:
- `foundry:transform` and `foundry:parent` can be read and written by schema ID, as any
  component can. A raw write bypasses the cycle and depth checks, which is why §6 exists.
- `foundry:world_transform` cannot be read, because it has no serializer. That is the honest
  answer until v6 publishes `worldTransform`.
- `entity_destroy` on a parent destroys its descendants (§5.4). No existing consumer creates
  parents, so no existing behaviour changes.

## 4. Propagation (`scene`)

### 4.1 The call and its point in the tick

```zig
pub fn propagate(world: *World) PropagationStats;
pub fn system() scene.System;   // id foundry:systems.propagate_transforms
```

**The point in the tick is where the host registers the system.** Systems run in registration
order (`scene/system.zig`), and `3d.md` §7 fixes the point relative to other systems: after
every system that writes transforms, and before anything that reads world transforms. The host
therefore registers `hierarchy.system()` after its writers. Render extraction runs after
`World.update`, so it always sees this tick's poses. A host that does not register the system
can call `propagate` itself at the same point. The successor to registration order,
`before`/`after` constraints (`entity-storage.md` §13), makes this point checkable when a mod
first needs to insert a system into it. M21 does not build it.

### 4.2 What one run does

1. **Collect** every live entity with `foundry:transform`, and compute its depth by walking
   its parent chain. Depths are memoised, so each entity is walked once.
2. **Order** them by depth, then by ascending slot index. A live entity's index is unique, so
   the order is total and follows from the world's contents alone (I9).
3. **Compute** each world matrix as `W = W_parent · local.toMat4()`, where `W_parent` is the
   parent's matrix from this run, or the identity for a root. Parents come first, so it is
   always ready.
4. **Write** `foundry:world_transform`, adding it to any entity that has a transform and lacks
   one. Propagation also removes it from any entity that has lost its transform. So the
   component exists exactly where it means something, and is never garbage: it is added
   already written.

**It never decomposes** (`3d.md` §7.1). A sheared world is a product of matrices, carried down
the chain exactly and drawn correctly.

**It is a function of the world's contents.** Each world matrix depends only on its chain's
local poses, multiplied in the same order, so it is bit-identical however and whenever the
entities were spawned. A test pins that by spawning one hierarchy in several orders.

`PropagationStats` counts entities, roots, the deepest depth, and each kind of entry §6 had to
repair. It is what the overlay and a test read.

### 4.3 Reading a world pose

```zig
pub fn worldTransform(world: *const World, entity: Entity) ?Mat4;  // the last propagation's
pub fn worldOf(world: *const World, entity: Entity) ?Mat4;         // computed now, writes nothing
pub fn parentOf(world: *const World, entity: Entity) ?Entity;
pub fn depthOf(world: *const World, entity: Entity) ?u32;
```

- **`worldTransform`** returns the last propagation's value. Between propagations it is last
  tick's, as ADR-0050 says. It is null for an entity that has never been propagated or has no
  transform.
- **`worldOf`** walks the chain now, under the same rules as propagation (§6). It is the
  on-demand path for a system that cannot wait a tick, and keep-world's input (§5.2).
- All four are read-only, take handles, return values, and resolve a stale entity to null.
  That is the shape ADR-0025 requires of anything the overlay calls, and the shape v6 will
  publish.

### 4.4 Cost, now and later

**Now:** every run recomputes every world transform: an `O(n log n)` sort and one 4×4 multiply
per entity, into a frame-arena buffer.

**Designed for:** the depth-then-index order is exactly the one a level-by-level parallel pass
over `core.Jobs` would use. A dirty flag on `foundry:transform` could be added without changing
any rule here.

**Budget:** 10,000 entities at depth up to 8 propagate in **under 1 ms** in ReleaseSafe on the
Apple M5. Step 2 measures it and records the number. Missing the budget is the trigger for
either optimisation (§12), not a reason to build both now.

## 5. Re-parenting and despawning (`scene`)

### 5.1 Keep-local, the default

```zig
pub fn setParent(world: *World, child: Entity, parent: ?Entity) ReparentError!void;
```

This writes `foundry:parent`, or removes it when `parent` is null, and leaves the local
transform alone, so the child moves with its new parent. It never decomposes, so it accepts
any valid parent, sheared chains included (`3d.md` §7.1).

It refuses:
- **`NoSuchEntity`:** the child is not live or has no `foundry:transform`, or the parent is
  not live;
- **`WouldCycle`:** the parent is the child or one of its descendants;
- **`TooDeep`:** the resulting subtree would be deeper than the limit.

A parent without a transform is accepted and contributes identity, as ADR-0050 says. Its own
parent is then not consulted, so the chain stops there, and §6 documents that.

### 5.2 Keep-world

```zig
pub fn setParentKeepWorld(world: *World, child: Entity, parent: ?Entity) ReparentError!void;
```

This is `3d.md` §7.1, step for step, and it covers detaching (a null parent means the
identity):
1. **Validate** as §5.1 does, and require the new parent to have a transform too.
2. **Compute** `W` and `P` fresh with `worldOf`, never from a possibly stale
   `foundry:world_transform`. Every element must be finite.
3. **Invert** `P`. It is refused as `SingularParent` below `determinant_epsilon`, scaled to
   the matrix.
4. **Decompose** `L = P⁻¹ · W` with `Transform.fromMat4Exact`. A reflection comes back as a
   negative x scale, and a zero scale or a shear is refused as `NotRepresentable`.
5. **Commit or change nothing.** Only when every check has passed are the child's parent and
   transform written, together. The world transform is left for the next propagation.

`ReparentError` is `{ NoSuchEntity, WouldCycle, TooDeep, SingularParent, NotRepresentable }`.
Each is one of ADR-0050's names, and each says which step refused.

### 5.3 A refusal writes nothing

Every check in §5.1 and §5.2 runs before the first write, and the writes cannot fail: the
component slots exist, or are added with capacity reserved first. The tests do not take this on
trust. They snapshot every entity's components before each refusal and compare after:
`World.save`'s bytes, plus each `foundry:world_transform`'s raw bytes, since a save leaves
those out. The two must be byte-identical, as `3d.md` §10 requires.

### 5.4 The despawn cascade

**`World.destroy(entity)`, in a world with the hierarchy enabled, destroys the entity's
descendants too.** It goes deepest first and, at equal depth, in ascending slot index (I9). A
descendant is found by scanning `foundry:parent` once, `O(n)` per destroy. A child index is
the obvious optimisation, and its trigger is a measured despawn cost (§12). A child meant to
survive is detached first, with either `setParent`. `World.destroy` still returns whether the
root entity existed.

`World.clear` destroys everything anyway, and is unchanged.

## 6. The rules against unvalidated data

§5's calls keep the hierarchy valid, but they are not the only writers. A save, a mod's
generic component write through the ABI, or a hand-edited file can hold a parent that is gone,
a cycle, a chain past the limit, or a local pose `isValid` refuses. Propagation and `worldOf`
therefore check what `setParent` checks, and repair by one documented rule each. None of these
is ever a crash or an assertion:

| Found | Treated as | Counted as |
| --- | --- | --- |
| A parent that is not live | The child is a root | `orphans` |
| A parent without `foundry:transform` | It contributes identity, and its own parent is not consulted | — (documented, not an error) |
| A cycle | Every entity on it is a root | `cycles` |
| A chain deeper than `max_hierarchy_depth` | Cut at the limit: the entity past it is a root | `too_deep` |
| A local pose `isValid` refuses | That entity's world transform is left unchanged, and its subtree propagates from it | `invalid` |

- **Why keep the last world pose for an invalid local,** rather than use the identity: a
  NaN written by a buggy mod should freeze its object, not teleport it to the origin.
- **Reported once:** each repaired entity is logged the first time it is found. It is logged
  again only after its `foundry:parent` or `foundry:transform` changes, so a broken save does
  not flood the log.
- **The overlay** shows the counts (§7).

## 7. 3D in the overlay (`debug`)

`3d.md` §10 asks for "3D in the debug overlay". For M21 that means the hierarchy and its poses.
Each call is one the ABI could expose (ADR-0025).

**The entity inspector gains the hierarchy.**
- **Tree order:** when the world has the hierarchy, the list shows roots in ascending slot
  index, each followed by its children the same way, indented by depth. Entities without a
  transform follow in slot order.
- **The selection** shows its parent, its depth, its child count, and its world pose from
  `worldTransform`:
  - the translation;
  - the decomposed rotation and scale when `fromMat4Exact` accepts the matrix;
  - otherwise **"sheared: not a transform"**, which is `3d.md` §7.1's distinction made visible.
- **Other components** are still shown through their serializers, as before.
- **The last propagation's counts** head the panel.
- **Read-only:** it stays read-only (`debug-overlay.md` §7.4).

**The profiler panel gains `render3d`'s frame counts:** draws, culled, blended, triangles and
pipeline binds, beside `render2d`'s. That needs **`render3d` in `debug`'s imports**, and
`debug.Sources` gains an optional `world3d: ?*const render3d.Renderer`. The dependency points
downward (L5 to L3), and it is the same kind as `debug`'s existing one on `render2d`. It still
changes CLAUDE.md §4.3's list, so it is §13's item 8 for the owner. The alternative, routing the
counts through `app`, would put a renderer's statistics into the engine loop for one panel.

## 8. `samples/sandbox3d`: nested moving objects

`sandbox3d` gains `scene` and `debug` in its imports, and still not `rhi`.
- **The world:** it creates a `scene.World`, enables the hierarchy, and declares two components
  of its own:
  - **`sandbox3d:model`** names a model by content ID. It is the "whatever component a game
    uses" of `3d.md` §3.
  - **`sandbox3d:spin`** holds an axis and a rate in radians per second.
- **Content:** templates in its package author each object's `foundry:transform`, model and
  spin. The sample parents them in code (§3.3).
- **The objects:** an orrery on the table.
  - A turntable turns; a crate rides on it and turns about its own axis; a smaller crate orbits
    that one.
  - Beside it, a frame scaled `(2, 1, 1)` carries a child turned 45°, so a sheared world is on
    screen, drawn correctly.
  - M19's code-built cube becomes one entity among them.
- **The systems:** `sandbox3d:systems.spin` writes the transforms, then
  `foundry:systems.propagate_transforms` runs.
- **Extraction:** after `World.update`, the sample queries `foundry:world_transform` with
  `sandbox3d:model` and draws each through `render3d.Content`. The room and the crate grid stay
  as M20 drew them.
- **The overlay:** hosted as `samples/sandbox` hosts it, with the entity inspector, the
  profiler and the log. F1 toggles it; the other keys follow `samples/sandbox`.
- **Keys:**
  - **F5 and F9** save the world to the user data directory and load it back. The poses after
    a load are the poses before, which is the exit condition shown live.
  - **F6** moves the orbiting crate between two parents with keep-world, and it does not jump.
  - **F7** tries the same for the sheared child. It is refused as `NotRepresentable`, the log
    says so, and nothing moves.
- **The overlay line** adds the propagation's entity count.

## 9. Platform assessment

M21 changes CPU code in `scene`, an overlay panel, and a sample. It touches no shader, RHI,
Vulkan, windowing or presentation code.
- **macOS/Metal:** the whole graph, and the runnable result from a relocated install.
- **Windows/Vulkan:** the runnable result from a relocated install with validation required,
  and the whole `-Drhi=vulkan` graph, as every milestone ends runnable there (`3d.md` §10). The
  PC's clock showed anomalies in M20 Step 7, so Step 5 checks it before recording any pacing.
- **Linux: compile only.** None of `3d.md` §10.2's triggers applies: nothing Linux- or
  Vulkan-specific changes. It would become required if a step touched `platform`, `rhi` or
  presentation, which none is planned to.
- **Determinism across hosts** is not claimed bit-exact (ADR-0013). Propagation is
  bit-identical on one machine across spawn orders (§4.2), and a test pins that. A hash of
  world matrices is compared between macOS and Windows as evidence, and a difference would be
  recorded, not treated as a failure.

## 10. Verification

**Null tests in `scene`**, each covering `3d.md` §10's list:
1. **Registration:**
   - the three types register under their names, and a second `enableHierarchy` is a no-op;
   - enabling after an entity exists is `WorldNotEmpty`;
   - `foundry:transform`'s deserializer refuses each invalid value.
2. **Content:**
   - a template authors a transform with defaults filled;
   - a package naming `foundry:parent` fails to compile;
   - a template naming a `foundry:parent` record placed directly in a store is refused as
     `ParentNotAuthorable`, with nothing created.
3. **Propagation:**
   - parents before children, whatever the spawn order: one hierarchy spawned in three orders
     gives bit-identical world matrices;
   - a rotated, non-uniformly scaled chain gives the expected sheared world, element for
     element;
   - world transforms are added and removed with the transform;
   - `worldOf` equals the next propagation's result and writes nothing.
4. **Keep-local:** accepted under the sheared chain, with the world moving with the new parent.
5. **Keep-world:**
   - accepted for a uniformly scaled parent, and for a non-uniform scale aligned with the
     child, with the world pose unchanged within `representation_epsilon`;
   - refused as `NotRepresentable` under a shearing parent, and for detaching a sheared child;
   - refused as `SingularParent` for a zero-scale parent;
   - a reflected result decomposes canonically, with a negative x scale.
6. **Refusals change nothing:** each of `WouldCycle`, `TooDeep`, `SingularParent`,
   `NotRepresentable` and `NoSuchEntity` is followed by a save-bytes-and-world-transforms
   snapshot, byte-identical to the one before.
7. **The cascade:**
   - destroying a parent destroys its subtree, deepest first then by index;
   - a detached child survives;
   - `entity_destroy` through the ABI cascades too.
8. **Unvalidated data:** a save built by hand with a stale parent, a two-entity cycle, a
   65-deep chain and a NaN rotation loads. Propagation treats each by §6's table, counts it,
   and logs it once across ten runs.
9. **The save round trip:** a hierarchy saved and loaded into a fresh world propagates to
   world matrices bit-identical to the original's.

**Measurement:** the §4.4 budget, 10,000 entities at depth up to 8, recorded in Step 2.

**Overlay tests on null:**
- the tree order and indentation;
- the world-pose lines, including "sheared: not a transform";
- the propagation counts;
- `render3d`'s counts line, or "no 3D renderer" when `Sources` has none.

**Mutations:** every guard is broken once, and its test watched to fail. At least:
- ordering by index only;
- keep-world writing before its last check;
- the cascade skipping grandchildren;
- propagation trusting a stale parent.

**The runnable result,** from relocated installs on macOS/Metal and on Windows/Vulkan with
validation:
- captures at 1× and 4× with the overlay open on the sheared child;
- F5, a change, then F9, with the poses before and after compared from the log;
- F6 and F7's outcomes;
- a resize, a minimise and restore, and a clean exit;
- 240-frame pacing.

`sandbox` and `room` still pass their runs.

## 11. Implementation order — six bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `scene`: the components, and what content may author

§3: the fixture and example renames, `World.enableHierarchy`, the three types and their
layouts, the validating deserializer, `max_hierarchy_depth`, `registerAll`'s
`foundry:transform`, and `ParentNotAuthorable`. Tests 1 and 2 of §10. **Exit:** a world enables
the hierarchy, a template authors a transform, and a parent cannot be authored.

### Step 2 — `scene`: propagation

§4 and §6: `propagate`, the system, the four read calls, the rules against unvalidated data
with their counts and once-only reports, and the budget measurement. Tests 3 and 8. **Exit:** a
sheared chain propagates exactly, independent of spawn order, and a hostile save propagates by
§6's table.

### Step 3 — `scene`: re-parenting and the cascade

§5: `setParent`, `setParentKeepWorld`, the snapshot tests and the despawn cascade in
`World.destroy`, then the save round trip. Tests 4 to 7 and 9. **Exit:** every item of `3d.md`
§10's M21 regression list has a passing test.

### Step 4 — `debug`: 3D in the overlay

§7: the tree, the selection's world pose, the counts, `render3d` in `debug`'s imports, and the
`world3d` source. The overlay tests. **Exit:** on null, the inspector shows a sheared child as
sheared and its parent's children under it.

### Step 5 — `sandbox3d`: nested moving objects

§8: the world, the two sample components, the templates, the orrery, the systems, extraction,
the overlay, and F5/F9/F6/F7. The runnable result on macOS and Windows, with the PC's clock
checked first. **Exit:** nested moving objects are inspected live in the overlay on both
platforms, and a save loads back to the same poses.

### Step 6 — Close M21

- Confirm §9's Linux assessment.
- Resolve every contract discrepancy in its originating document:
  - `entity-storage.md`'s `foundry:transform { x y }` examples and its "no engine component
    types";
  - `debug-overlay.md` §7, for the tree and the world pose;
  - `3d.md` §7, for where propagation's point is fixed;
  - CLAUDE.md §4.3, for `debug` and `sandbox3d`'s imports.
- Update CLAUDE.md §9's 3D row, `AGENTS.md`'s bar if a step changed it, `PROJECT_STATE.md`, the
  roadmap and the design index.

Tag `m21`, push when asked, and stop before M22's design. **Exit:** `3d.md` §10's M21 row
holds as written.

## 12. What stays open, deliberately

- **Authoring a hierarchy in content.** The trigger is the first content that needs one: M26's
  sample, or a content mod that builds a parented object. The likely answer is an additive
  `children` list on `foundry:entity` (version 2), spawning each child template under its
  parent. The design problem is naming the parent across a spawn, never with an `Entity`.
- **Dirty tracking, and propagation over `core.Jobs`.** The trigger is §4.4's budget missed by a
  measurement.
- **A child index for the cascade and the tree.** The trigger is a measured despawn or overlay
  cost in a world large enough to show it.
- **`before`/`after` system constraints.** The trigger is the first mod that must insert a
  system between a writer and propagation (`entity-storage.md` §13).
- **Double precision and a floating origin.** The trigger is a world past about 8 km
  (`3d.md` §2), as ADR-0050's revisit condition says.
- **Editing poses in a tool.** The editor's, in its own milestone, with undo and the
  content/state question `debug-overlay.md` §7.4 names.

## 13. Decisions acceptance fixes

Nothing blocks Step 1 once these are accepted. Each is recommended as written:

| # | Choice | Where |
| --- | --- | --- |
| 1 | A world opts in with `World.enableHierarchy()`, which registers the three types and makes `World.destroy` cascade; 2D worlds do not change | §3.1, §5.4 |
| 2 | `scene`'s test fixtures and doc examples stop using `foundry:transform` for a 2D type | §3.1 |
| 3 | The layouts: `foundry:transform` is `core.Transform` as `{ translation, rotation, scale }`, `foundry:parent` is `{ entity }`, and `foundry:world_transform` is a field-less derived `Mat4` | §3.2 |
| 4 | Content may author `foundry:transform`, never `foundry:parent`: the compiler does not know the parent schema, and `spawn` refuses one as `ParentNotAuthorable` | §3.3 |
| 5 | `max_hierarchy_depth = 64` edges, in `scene.Limits` | §3.4 |
| 6 | Propagation's point is where the host registers `foundry:systems.propagate_transforms`: after writers, before extraction; it recomputes everything each run, within a measured 1 ms budget for 10,000 entities | §4 |
| 7 | Unvalidated data is repaired by §6's table, never asserted: stale or cyclic parents make roots, over-deep chains are cut, an invalid local keeps the last world pose; each is reported once | §6 |
| 8 | `debug` gains `render3d` in its imports for a frame-counts line, and the inspector shows the hierarchy and world poses, read-only | §7 |
| 9 | `sandbox3d` gains `scene` and `debug`, its own `sandbox3d:model` and `sandbox3d:spin` components, and an orrery with a sheared child, F5/F9 save and load, and F6/F7 keep-world demonstrations | §8 |
| 10 | Nothing enters the public ABI in M21; v6 (M25) publishes the names and the read calls | §3.5 |
| 11 | Linux: compile only, with §9's trigger | §9 |

## Resolution — Step 1: the components, and what content may author (2026-09-29)

Step 1 implements §3 and stops before propagation.

**What exists now:**
- **`engine/src/scene/hierarchy.zig`** holds the three types:
  - **`Transform`** (`foundry:transform`) is an `extern struct` with `core.Transform`'s
    layout. A comptime check pins its size, alignment and field offsets, so `fromCore` and
    `toCore` are bit casts. It needs its own type only because a component's name is a
    declaration on the type, and `core` cannot carry `scene`'s names.
  - **`Parent`** (`foundry:parent`) is `{ entity }`.
  - **`WorldTransform`** (`foundry:world_transform`) is a column-major `Mat4`, registered by
    hand with a field-less schema, no serializer and no deserializer, constructed as the
    identity.
  - **`Types`** holds the three handles one world registered.
- **The transform's registration** is `componentType`'s with its deserializer wrapped, so a
  pose `isValid` refuses is `ValueOutOfRange` wherever it enters, from a template or a save.
  `transform_schema` is the same derived value, so content and the world cannot disagree
  about a field or a default.
- **`World.enableHierarchy()`** registers the three and records them in `World.hierarchy`. It
  checks the entity count, the type limit and all three names before registering any, so a
  refusal (`WorldNotEmpty`, `ComponentTypeLimit`, `ComponentTypeExists`) leaves nothing
  registered. Once it is enabled, a second call returns the same types, even after entities
  exist.
- **`World.spawn`** scans the template's component records before creating anything, and
  refuses one naming `foundry:parent` as the new `SpawnError.ParentNotAuthorable`. The check
  is by schema ID, so it holds whether or not the world enabled the hierarchy.
  `foundry:world_transform` in a template is `NotConstructibleFromData`, as §3.3 expected.
- **`scene.schemas.all`** gains `foundry:transform`, and not the other two. A package naming
  `foundry:parent` fails to compile with the ordinary unknown-schema diagnostic.
- **`scene.Limits.max_hierarchy_depth = 64`**, unused until Steps 2 and 3.
- **The renames:** `world.zig`'s test fixture is `test:position`. `derive.zig`'s and
  `schemas.zig`'s examples use a game's namespace. `entity-storage.md`'s examples wait for the
  close, as §11 says.

**What implementation found:**
- **A `derive` defect from M5.** For a nested field, the schema default was built from each
  sub-field's *type* default rather than from the outer field's value. `scale: Vec3 =
  Vec3.one` therefore compiled to a schema default of `(0, 0, 0)`, while a component
  constructed in code got `(1, 1, 1)`. A template that left out `scale` produced a collapsed
  object. `valueOf` now reads `@field(v, sub.name)`, and a test pins it. No earlier component
  had a nested default that differed from its type's, so no content or save changes meaning.
- **`author`'s `engine_schema_names`** is the one place the engine schemas' spellings are
  written down, for the editor's New Record form. Its test caught the missing
  `foundry:transform`, which it now lists.

**Tests** (§10 items 1 and 2):
- the three types register under their names, saved or not as §3.2 says, and a second call
  is a no-op;
- enabling late, over a name a game already took, and past the type limit each refuse with
  nothing registered;
- a template authors a transform, with the rotation and scale defaults filled;
- a non-unit rotation is refused with no entity left, and a zero or negative scale is accepted;
- `foundry:parent` fails to compile, and a store built by hand is refused at spawn with the
  world's mutation generation unchanged;
- a world transform cannot be built from data;
- `derive`'s nested default follows the outer value.

**Guards verified by mutation,** each restored byte for byte:
- the nested default read from the type failed the `derive` test and the authored-transform
  test;
- skipping the parent pre-scan failed the content test;
- dropping the transform validation failed the refusal test;
- dropping the all-or-nothing name check failed the half-way test.

**The bar:** **1,831 of 1,832 headless tests** (the existing skip; **1,912 declared**) and
**1,839 of 1,850 on `-Drhi=metal`**, with fmt, all four `check` variants, and the three
thirty-frame samples, which logged no warnings. No Vulkan, shader, platform or ABI source
changed. Step 2, propagation, is next.

## Resolution — Step 2: propagation (2026-09-29)

Step 2 implements §4 and §6 in `scene/hierarchy.zig`, and stops before re-parenting.

**The propagation**, `propagate(world)`, does §4.2's four things:
1. **Effective parents and depths.** Each entity's chain is walked once, with a memo, and the
   walk applies §6's rules as it goes.
2. **The order:** depth, then slot index, by `std.sort.pdq` over that total order.
3. **World transforms added:** every entity with a transform gets `foundry:world_transform`,
   constructed as the identity, before any is written.
4. **Computed and written top down:** each matrix is `W_parent · local`. A root's is its local
   matrix, unmultiplied, so `worldOf`, which composes the same way, agrees with it to the bit.

It then removes the world transform from any entity that lost its transform. Its working
arrays are sized by the entity pool's capacity and freed at the end.

**`system()`** is `foundry:systems.propagate_transforms`. The host registers it where it should
run.

**What implementation sharpened:**
- **`propagate` returns `Allocator.Error!PropagationStats`,** not the bare stats §4.1 showed,
  because its working arrays allocate. The system logs a failure at `err` and leaves last
  tick's world transforms, which §4.3 already promises between runs.
- **`scene.World` gains `readComponent`,** a `*const World` read of a component's bytes. The
  read calls take a `*const World`, as ADR-0025 requires of anything the overlay calls, and the
  existing `getComponent` needs a mutable one.
- **`World.hierarchy` holds a `State`:** the three types, plus which repairs have been
  reported. Each report keeps the raw parent and a hash of the raw local pose, and the entry is
  forgotten when the repair no longer applies. `reports` counts the log lines, which is how a
  test proves "once".
- **`worldOf` allocates nothing.** It finds the chain's length and any cycle with Brent's
  algorithm, derives the effective root arithmetically (a chain past the limit is cut every
  `limit + 1` entities), and composes at most `limit + 1` matrices from a fixed buffer. So the
  depth limit is capped at **`hierarchy.max_depth_limit = 256`** for both the propagation and
  `worldOf`, whatever `Limits` says, and they always cut at the same depth.
- **A save with an invalid pose does not load.** Step 1 made `foundry:transform` validate where
  it enters, and `save.read` turns any refused deserialization into `SaveCorrupt`. §10's
  item 8 therefore splits. A hostile save with a stale parent, a cycle and an over-deep chain
  loads and is repaired. A NaN rotation is the one §6 row a save cannot carry, and it is reached
  only by a raw byte write from native code, which the tests use. Refusing the whole save is
  `save.read`'s existing rule for a component it cannot read.

**§6 as built:**
- **A parent that is not live:** the child is a root (`orphans`).
- **A parent without a transform:** it contributes the identity, and the chain stops there
  (`Link.root`, not counted).
- **A cycle:** every member is a root (`cycles`), and entities hanging off it take their depth
  from the member they reach.
- **A chain past the limit:** the entity past it is a root (`too_deep`), and its descendants
  continue from it.
- **An invalid local pose:** that entity's world transform is left as it was (the identity if
  it was just added), and its subtree propagates from that (`invalid`). `worldOf` reads the
  stored value for it, so the two still agree.

**Tests** (§10 items 3 and 8):
- one five-node tree, with a sheared branch, built in three creation orders with the slot
  indices shifted, gives bit-identical world matrices;
- `3d.md` §7.1's parent scaled `(2, 1, 1)` over a child turned 45° gives exactly
  `P · C`. Its axes are not orthogonal, and `fromMat4Exact` refuses it;
- world transforms exist exactly where transforms do;
- `worldOf` writes nothing (the mutation generation is unchanged, and the stored value stays
  stale) and equals what the next propagation writes. `depthOf` and `parentOf` agree;
- the registered system propagates on `World.update`;
- a hand-built save with an orphan, a two-entity cycle with a tail, and a 66-entity chain loads.
  Ten propagations count one orphan, two cycle members and one cut, each logged once (four
  reports), and each repair is the documented one. A changed parent is reported again, once;
- a NaN rotation written raw freezes its entity, its child follows the frozen pose, and a save
  of it is refused as `SaveCorrupt`.

**The budget (§4.4):** 10,000 entities in 1,250 chains of depth 8, created interleaved, in
ReleaseSafe on the Apple M5, 200 propagations per run. Four runs gave medians of 0.381,
0.281, 0.266 and 0.266 ms. The p95s were 1.008, 0.385, 0.281 and 0.283 ms, the first run cold.
**Within the 1 ms budget,** so neither dirty tracking nor a parallel pass is due. The benchmark
was a scratch program over the `scene` module, not committed, because `scene` may not read a
clock.

**Guards verified by mutation,** each restored byte for byte:
- ordering by index alone failed the spawn-order test;
- trusting a stale parent, cutting one level early, and logging every run each failed the
  hostile-save test;
- not freezing an invalid pose, and `worldOf` ignoring the frozen pose, each failed the
  invalid-pose test.

**The bar:** **1,838 of 1,839 headless tests** (the existing skip; **1,919 declared**) and
**1,846 of 1,857 on `-Drhi=metal`**, with fmt, all four `check` variants and the three
thirty-frame samples. Step 3, re-parenting and the cascade, is next.
