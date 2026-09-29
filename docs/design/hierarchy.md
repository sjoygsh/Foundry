# Design: M21 — Hierarchy: the engine's transform components, propagation, re-parenting and 3D in the overlay

**Status:** Complete 2026-09-29, tag `m21`. Accepted when the owner requested Step 1; §13 is
accepted as written. All six steps are walked.
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

## Resolution — Step 3: re-parenting and the cascade (2026-09-29)

Step 3 implements §5 in `scene/hierarchy.zig` and `World.destroy`, and stops before the
overlay.

**What exists now:**
- **`setParent(world, child, parent)`** keeps the local pose. It writes or removes
  `foundry:parent` and nothing else, so it accepts a sheared chain.
- **`setParentKeepWorld(world, child, parent)`** follows `3d.md` §7.1 step for step:
  1. validate;
  2. compute `W` and `P` fresh with `worldOf`;
  3. check that `|det(P)|` is at least `ε_det · max(1, ‖P₃ₓ₃‖)³`, then invert;
  4. decompose `L = P⁻¹ · W` with `fromMat4Exact`;
  5. write the parent and the local pose together.

  A null parent detaches, against the identity.
- **The cascade:** `World.destroy` destroys the result of `hierarchy.descendants(root)`,
  deepest first and then by ascending slot index, and then the entity itself. It still
  returns whether that entity existed, and the ABI's `world_destroy_entity` cascades with no
  change of its own.

**What implementation sharpened:**
- **`destroy` cannot fail, so the cascade never allocates.**
  - Its scratch (a depth per parent component, and the list of what was found) lives in
    `hierarchy.State`. `World.addComponent` grows it whenever a `foundry:parent` is added,
    and every parent arrives that way: `setParent`, a save's second pass, or the ABI's
    generic component write.
  - The walk is `O(parents)`, not `O(entities)`. A memo means each chain is walked once.
  - A walk longer than the live entity count has gone round a cycle that does not pass
    through the root, and is marked outside it.
- **Descendants follow the stored links, not the effective ones.** A parent without a
  transform contributes the identity to propagation (§6), but it is still a parent:
  destroying it takes its children.
  - A stale link reaches nothing.
  - On a cycle through the root, every other member is a descendant.
  - A cycle elsewhere is left alone.
- **`WouldCycle` and `TooDeep` use the same walk.** The parent is refused if it is among
  the child's descendants. The deepest resulting depth is the parent's effective depth plus
  one plus the subtree's height, or just the height under a parent without a transform. That
  is stricter than the effective structure only when a transform-less entity sits inside the
  subtree, and it never admits a cycle into the stored links.
- **`ReparentError` gains `OutOfMemory`.** When the child has no parent component yet, both
  the store slot and the cascade scratch are reserved before any check could pass to a
  write. The new `ComponentStore.reserve` is `add`'s fallible half. The commit then cannot
  fail, as §5.3 requires.
- **Values that are not finite:** in `W` this is `NotRepresentable`, and in `P` it is
  `SingularParent`. §7.1 required finiteness without naming the error, and these are the
  steps that would refuse such a value anyway.
- **`L`'s last row is set to `(0, 0, 0, 1)`,** not left to the rounding of the cofactor
  inverse's `inv₁₅ / det`. Both factors are affine, as §7.1 says, and `fromMat4Exact`
  requires that row exactly. Without the fix, the sweep test's uniformly scaled, rotated
  parents are refused as `NotRepresentable`.
- **The norm in the singular check** is the largest absolute element of `P`'s 3×3, the same
  norm `fromMat4Exact` uses for `‖L‖∞`.
- **The Step 2 hostile-save test built its orphan by destroying the parent,** which now takes
  the child with it. It writes the stale link raw instead.

**Tests** (§10 items 4 to 7 and 9):
- keep-local is accepted under `3d.md` §7.1's shearing parent, and the world is exactly
  `W_parent · local`. Detaching removes the component, and a parent without a transform
  gives depth 0;
- keep-world holds the world pose within `ε_rep`:
  - under a uniformly scaled grandchild parent;
  - under a non-uniform scale aligned with a child turned a quarter;
  - when detaching after the parent moved without a propagation, which proves the matrices
    are computed fresh;
  - across a sweep of 64 rotated, uniformly scaled parents;
- refusals, with nothing written:
  - `NotRepresentable` under the shearing parent, and for detaching a sheared child;
  - `SingularParent` for a zero scale, and for `1e-7` (below the tolerance);
- a mirror decomposes to a scale of `(−1, 1, 1)` over a unit rotation, with the world kept;
- each of `WouldCycle` (self, descendant), `TooDeep` (the child alone, and the subtree
  below it) and `NoSuchEntity` (a stale parent, a stale or transform-less child, and for
  keep-world a transform-less parent) leaves a snapshot byte-identical, through both calls.
  The snapshot is the save's bytes, then every world transform with its owner, then the
  mutation generation;
- the cascade destroys `R ─ A ─ C ─ E, R ─ B ─ D` as E, D, C, B, A, R, recorded by a
  component destructor, and a child detached first survives;
- through hostile data, a cycle through the root is destroyed, while a cycle elsewhere, a
  self-parent and an orphan are untouched and nothing hangs. A transform-less parent takes
  its child;
- `world_destroy_entity` through the table cascades, and the descendants' handles go stale;
- a hierarchy saved and loaded into a fresh world propagates to world matrices bit-identical
  to the original's, and destroying one loaded parent cascades.

**Guards verified by mutation,** each restored byte for byte:
- keep-world writing the parent before its checks failed the shear-refusal test;
- the cascade skipping grandchildren failed the hostile-cascade and round-trip tests;
- ordering the cascade by index alone failed the order test;
- dropping the descendant check for `WouldCycle` failed the refusal test;
- ignoring the subtree's height failed the `TooDeep` case;
- dropping the determinant tolerance made the `1e-7` parent `NotRepresentable` rather than
  `SingularParent`;
- reading the stored world transform instead of `worldOf` failed the detach-after-move test;
- leaving `L`'s last row to rounding failed the sweep.

**The bar:** **1,847 of 1,848 headless tests** (the existing skip; **1,928 declared**) and
**1,855 of 1,866 on `-Drhi=metal`**, with fmt, all four `check` variants and the three
thirty-frame samples, which logged no warnings. The ABI gained a test and no call, so the
header is unchanged. No Vulkan, shader or platform source changed.

Every item on `3d.md` §10's M21 regression list now has a passing test. Step 4, 3D in the
overlay, is next.

## Resolution — Step 4: 3D in the overlay (2026-09-29)

Step 4 implements §7 in `debug` and stops before the sample.

**What exists now:**
- **`debug` imports `render3d`,** in `build.zig` and in CLAUDE.md §4.3's layer list, as
  §13's item 8 accepted. ADR-0025's layer diagram is append-only and still shows the old
  list; the close records the addition beside it.
- **`debug.Sources.world3d: ?*const render3d.Renderer`.** The profiler panel shows
  `render3d.Stats` in two lines below `render2d`'s: draws, culled and blended, then
  triangles and pipeline binds. Without a 3D renderer it says
  "no 3D renderer (Sources.world3d)", because a missing line would read as a 3D game that
  drew nothing.
- **The entity inspector is a tree** when the world has the hierarchy. `entity_panel.treeOrder`
  lists the roots in ascending slot index, each followed by its children the same way, then
  the entities without a transform in slot order. Rows are indented two spaces per level, up
  to twelve levels.
- **The panel is headed by the last propagation's counts:** transforms, roots and depth on
  one line, and the four repairs on the next. Before any propagation it says
  "hierarchy: not propagated yet".
- **The selection** shows:
  - its parent (or "no parent"), its depth and its child count;
  - its world translation from `worldTransform`;
  - its rotation and scale when `fromMat4Exact` accepts the matrix, and otherwise
    "sheared: not a transform";
  - "world: not propagated yet" before the first propagation.

  Its components follow through their serializers as before, so `foundry:transform` shows
  its local fields, and `foundry:world_transform` reads "not saved, so not shown". It is
  still read-only.

**What implementation sharpened:**
- **Two read calls in `scene.hierarchy`:** `enabled(world)` and `lastPropagation(world)`.
  The overlay holds a `*const World` and cannot run a propagation to count one, so
  `propagate` now keeps its last `PropagationStats` in the world's hierarchy state. Both
  calls are ABI-shaped (ADR-0025), and v6 can publish them as they are.
- **"Root" and "child" are the propagation's.** An entity is drawn under its stored parent
  exactly when `depthOf` is not zero. So an orphan, a cycle member or an entity cut for depth
  is drawn as a root, which is how it is being propagated. The child count is the number of
  children drawn under it.
- **The counts line is tested through its formatter.** A `render3d.Renderer` needs an
  `rhi.Device`, and `debug` has no `rhi` by design (CLAUDE.md §4.3). The test gives
  `describeStats3d` a `Stats` value and checks "no 3D renderer" from empty `Sources`.
  `sandbox3d`, in Step 5, is the first host to hand over a real renderer.

**Tests** (§10's overlay list):
- the tree order of a six-entity world, with slots deliberately out of tree order and one
  entity without a transform, and its child counts;
- on null, `3d.md` §7.1's shearing parent and turned child:
  - before propagation, both "not propagated yet" lines;
  - after, the counts;
  - the child indented under its parent, its parent and depth, its world translation, and
    "sheared: not a transform";
  - the parent's own pose decomposed to rotation and scale `2 1 1`, with no "sheared";
- "no 3D renderer", and the two `render3d` counts lines.

**Guards verified by mutation,** each restored byte for byte:
- slot order in place of the tree failed both tree tests;
- decomposing a fixed matrix in place of the world pose failed the sheared-child test;
- dropping the indentation failed it too;
- pushing children in the wrong order failed the tree-order test.

**The bar:** **1,850 of 1,851 headless tests** (the existing skip; **1,931 declared**) and
**1,858 of 1,869 on `-Drhi=metal`**, with fmt, all four `check` variants and the three
thirty-frame samples, which logged no warnings. No Vulkan, shader, platform or ABI source
changed. Step 5, `sandbox3d`'s nested moving objects, is next.

## Resolution — Step 5: `sandbox3d`'s nested moving objects (2026-09-29)

Step 5 implements §8 and records §10's runnable result. It stops before the close. It was
written by Claude, with Codex's confined save path and a first set of Windows runs folded in;
the evidence below is from runs repeated after that, on the finished tree.

**The world** (`samples/sandbox3d/orrery.zig`) has its own registry and `scene.World`, with
the hierarchy enabled and two sample components:
- **`sandbox3d:model`** is `{ model: id }`;
- **`sandbox3d:spin`** is `{ axis: Vec3, rate: f32 }`, in radians per second about the
  entity's own axis.

The package declares both with `@schema`, field for field, and authors seven templates:
- **the turntable,** a spinning pivot with no model;
- **the platter,** a crate scaled flat, a child of the turntable;
- **the rider,** a spinning crate, also a child of the turntable. It is not the platter's
  child, which would flatten it;
- **the moon,** a child of the rider, with no spin of its own, so it orbits;
- **the frame,** scaled `(0.4, 0.2, 0.2)`, which is 2 : 1 : 1;
- **the sheared crate,** turned 45° about Y on top of the frame;
- **M19's cube,** a pose and a spin with no model, because its mesh is built in code.

`populate` spawns them and sets the parents in code with `setParent`. A missing template is
logged, and its role is left empty.

**Systems and extraction.** `sandbox3d:systems.spin` is registered before
`foundry:systems.propagate_transforms`, so it runs first. After the steps, the sample queries
`sandbox3d:model` and draws each entity at its `worldTransform`, through a small cache of
model handles that is released on every content change. The cube is drawn at its entity's
world pose. `cube_radians_per_second` has left `sandbox3d:config`, because the cube's spin is
now its template's. The camera's orbit came in to 4 m radius and 2.4 m height, focused on the
table top, so objects 0.1–0.5 m across can be read.

**The overlay** is hosted as `samples/room` hosts it:
- **Imports:** `sandbox3d` gains `ui` beside `scene` and `debug`, because the kernel's
  `Context` is the game's (§8 named only the other two). It still imports no `rhi`.
- **F1** toggles it. `FOUNDRY_SANDBOX3D_PANELS` starts it open.
- **Panels:** the entity tree and the log are open, with the sheared crate selected. The
  profiler is one click away in the bar, because three panels in one column left the
  selection no room.
- **Text:** scale 1 in a 480-point column. At scale 2, a tree row did not fit.
- **Capture level:** `log_capture = .info`, so the log shows what each key did.
- **The stats line** adds the propagation's transform count and moves to the bottom, right of
  the column.

**Keys:**
- **F5** writes `world.fsav` with `replaceFileConfined` beneath the user data directory
  (`FOUNDRY_SANDBOX3D_SAVE_DIR` redirects it for evidence runs). It first propagates, and logs
  a hash of every world matrix in slot order.
- **F9** reads the file with `readFileConfined`, rebuilds the world with the same
  registrations, loads, propagates, and logs the hash, saying whether it is this run's save.
  The roles survive, because a save keeps handles (`entity-storage.md` §9). A refused save
  gives a freshly populated orrery, never an empty table.
- **F6** moves the moon between the rider and the cube with `setParentKeepWorld`, and logs the
  largest change in any world-matrix element.
- **F7** tries to move the sheared crate onto the turntable the same way. The turntable is
  rigid, and the crate's world is sheared, so it is refused as `NotRepresentable`, and the
  pose hash before and after is logged as unchanged.
- **Scripted presses:** `FOUNDRY_SANDBOX3D_KEYS=f5@300,...` presses keys on given frames,
  which is host bootstrap for runs nobody watches (ADR-0031).

**What implementation sharpened:**
- **A button centres its label,** so the Step 4 tree's leading spaces did not indent it on
  screen. `entity_panel` now indents each row with a spacer in a horizontal row, and its test
  checks the child's text x against the parent's.
- **`WorldTransform` has no component name,** so extraction queries `sandbox3d:model` and
  reads each pose with `hierarchy.worldTransform`, which is the same data §8 described.

**Tests:**
- the spin turns local poses, and the moon orbits because its parent turns;
- after every step, each drawn pose equals `worldOf` of the poses just written, so nothing is
  drawn a tick behind;
- a saved orrery loads back to the same pose hash, F6 moves the moon to the cube and back
  with a change below `1e-5`, and F7 is `NotRepresentable` with the hash and the parent
  unchanged;
- an unreadable save leaves a world with the hierarchy;
- a spin with no axis, or a NaN rate, leaves the entity still;
- scripted keys parse, and a malformed list is refused whole.

**Guards verified by mutation,** each restored byte for byte:
- dropping the zero-axis and NaN guard failed the still-entity test;
- skipping the propagation after a load failed the round-trip test;
- F7 keeping the local pose failed it too;
- registering the propagation before the spin failed the tick-behind test. That test was
  added because this mutation first survived;
- a zero indent failed the overlay's indentation test.

**The runnable result, macOS/Metal** (ReleaseSafe, relocated install, Apple M5, HOME in
scratch so nothing real is written):
- **Captures:** at 4× and 1×, with the overlay open on the sheared crate: the tree, and
  "sheared: not a transform" beside it. At 4× after F9, the overlay's own log shows F5 at
  frame 600, F6 at 840, F7 at 960 and F9 at 1200.
- **Keys:** F5 and F9 both logged poses `e6a48bdef78e78cd`, "the same as this run's save".
  F6's largest change was `5.96e-8`. F7 was refused with its poses unchanged.
- **Window handling:** resized to 900 × 560 and to 1400 × 800 (fitted to 1375 × 800), each
  captured. Minimised, the window left the on-screen list, and it was restored and captured.
  Every run exited 0.
- **Pacing, last 240 frames, 4×:** median 16.658 ms, p95 16.943 ms. The display ran at 120 Hz
  in earlier runs (median 8.6 ms); the sample paces to the display.
- **A harness note:** System Events and `screencapture` reach the window only while it is on
  the active Space. Two attempts made while the Mac was in use elsewhere lost their captures
  and are not counted.

**The runnable result, Windows/Vulkan** (Arc A750, ReleaseSafe, relocated install, Zig and
the SDK off `PATH`, `APPDATA` in a scratch root, a desktop session through a scheduled task):
- **The whole `-Drhi=vulkan` graph** passed on the PC: **1,888 of 1,907, with 19 skips**.
- **Validation:** core, synchronization, stateless, object lifetime, thread safety and handle
  wrapping enabled, and **no errors or warnings** at 4× or at 1×.
- **Keys at 4×:** F5 and F9 both logged poses `52c30dcd3e4b7d2c`, the same save. F6's largest
  change was `8.94e-8`. F7 was refused with its poses unchanged.
- **Captures:** at 4× and 1×, 1280 × 720, with the overlay open on the sheared crate, matching
  macOS.
- **Window handling:** `SetWindowPos` gave a 944 × 561 client. `ShowWindow` minimised it:
  iconic, 99 frames skipped. It restored and was captured. `WM_CLOSE` ended it with exit 0,
  and every run exited 0.
- **Pacing, last 240 frames:** with validation, 4× median 16.662 ms (p95 16.724 ms) and 1×
  median 16.663 ms (p95 16.665 ms). With every layer disabled, 4× median 16.663 ms (p95
  16.664 ms).
- **What did not count:** in the final run, two mid-run captures came back black because
  something covered the window while the PC was in use. The first run's versions of those
  captures were good. Its exit codes were blank, because .NET keeps `ExitCode` only for a
  process whose handle was opened. The harness now reads the handle at launch, and the rerun
  gave 0.
- **The PC's wall clock** reads true UTC as local time under an India Standard Time zone, and
  has never synced, so it runs 5.5 hours slow. Pacing uses the monotonic clock and is
  unaffected. M20's anomaly was in the monotonic clock, and nothing like it appeared here.

**Cross-host determinism** (§9, evidence and not a claim): the pose hashes differ between
the hosts, and between runs on one host. That is expected, because F5 lands on whichever tick
the frame reached, and a frame's tick count depends on real time. What each run proves is
that its load gives back its own save's poses to the bit.

**The bar:** **1,857 of 1,858 headless tests** (the existing skip; **1,938 declared**) and
**1,865 of 1,876 on `-Drhi=metal`**, with fmt, all four `check` variants and the three
thirty-frame samples, which logged no warnings. Also:
- **`dist` staging** for `sandbox` and `room` on Metal, because sample content changed;
- **the five Vulkan compile checks;**
- **the Windows whole graph** above.

No shader, RHI, platform or ABI source changed. Step 6, the close, is next.

## Resolution — Step 6: Close M21 (2026-09-29)

Step 6 changes documents only. No source, build or content file changed after Step 5
(`4fa290b`), so Step 5's bar is the bar M21 closes on: **1,857 of 1,858 headless tests (1,938
declared)**, **1,865 of 1,876 on `-Drhi=metal`**, and the PC's `-Drhi=vulkan` graph at **1,888 of
1,907** (19 skips).

**§9's Linux assessment holds.** Across `m20..4fa290b`, nothing in `platform`, `rhi`, the
shaders, presentation or the C header changed: the diff is `scene`, `debug`, `abi`'s cascade
test, one line of `author`'s schema list, `sandbox3d` and `build.zig`'s import lists. None of
`3d.md` §10.2's triggers fired, and the Linux null cross-compile in the bar stood for it.

**`3d.md` §10's M21 row holds as written.** Each required test is in the graph:
- propagation independent of spawn order, and the sheared chain propagated exactly;
- keep-local under that chain; keep-world under uniform and aligned scale, and over a sweep;
- keep-world refused as `NotRepresentable` for a shearing parent, and for detaching a sheared
  child; `SingularParent` for a zero and a `1e-7` scale; the reflection decomposed
  canonically;
- a byte-identical snapshot after every refusal;
- the despawn cascade, including through hostile links;
- the save round trip, to bit-identical world poses.

Its runnable result is Step 5's orrery, on macOS/Metal and Windows/Vulkan.

**Contract discrepancies resolved in their originating documents:**
- **`entity-storage.md`:** its examples used `foundry:transform` for a 2D `{ x y }` position.
  They are now `sandbox:position` (and `sandbox:sprite`, which was never an engine type
  either). §14's "hierarchy deliberately not here" now records what M21 built: the engine's
  first component types, registered only by a world that opts in, and a storage change of
  one call (`Store.reserve`), as §14 predicted.
- **`debug-overlay.md`** gains §7.5: the tree order, the selection's world pose or "sheared:
  not a transform", the propagation's counts, and `render3d`'s counts through
  `Sources.world3d`.
- **`3d.md` §7** now says where the point is fixed: where the host registers
  `foundry:systems.propagate_transforms`, unchecked until `before`/`after` constraints exist.
  It also gains the depth limit's value (64 edges) and the per-world opt-in.
- **ADR-0025** gains a dated note beside its layer line recording `render3d`. The ADR is
  append-only, so the note sits beside the line rather than replacing it. ADR-0050's status
  records its implementation.
- **CLAUDE.md:**
  - §4.3 lists `sandbox3d`'s grants;
  - §4.1's hierarchy row names the opt-in and the cascade;
  - §9's 3D row adds M21.

  `debug`'s `render3d` was already in §4.3 from Step 4.

**Unchanged:** `AGENTS.md`'s bar, since no step changed it. §12's open items stay open with
their triggers. Nothing entered the public ABI, as §13's item 10 said.

**Packed up:**
- **The PC:**
  - the `Foundry-m20` worktree is clean again, detached at `00f39d3`;
  - the M21 working folders, the helper scripts and Codex's proof folders are deleted.
    Codex's folders went unread, including the token file one held;
  - a scheduled task Codex left is unregistered.
- **The Mac:** the scratch runs are cleared.

M21 is tagged `m21`. M22, Light, is next, and its design comes first.
