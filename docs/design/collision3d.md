# Design: M23 — Collision: `physics3d`, collision meshes, the character controller and a first-person walk

**Status:** Accepted 2026-09-30, when the owner requested Step 1, with every §16 choice as
written. **Complete 2026-10-01, all seven steps, tag `m23`.**
**Date:** 2026-09-30
**Baseline:** `a0f8d73`, tag `m22`. M0–M22 are complete.
**Decisions:**
- ADR-0051 (collision, queries and a character controller, no dynamics) is accepted and is the
  contract this design implements. ADR-0013 (deterministic-friendly, not bit-exact), ADR-0022
  (2D collision, our own), ADR-0048 (conventions: +Y up, metres, radians), ADR-0053 (assets are
  not the renderer) and ADR-0055 (imports compile to records) constrain it.
- Accepted [ADR-0057](../adr/0057-collision-geometry-is-compiled-content.md): collision
  geometry is a compiled `foundry:collision_mesh` asset, derived at import from the nodes a
  `foundry:model_import` does not exclude, and `physics3d` copies it and builds its own tree
  rather than reading an asset.

`3d.md` §8 is the architecture of 3D physics and ADR-0051 its decision. M23 spans a new module,
`asset`, `author` and the sample, so it writes its own document, as M20 and M22 did, and this is
it. `tilemaps-and-collision.md` is `physics2d`'s document; `physics3d` follows its shape
deliberately, and says where it departs.

## 1. Purpose and boundary

From `3d.md` §10, M23's row:

- **Runnable result:** a first-person walk through that room, colliding.
- **Exit condition:** the character walks, climbs steps, is stopped by a steep slope and slides
  along walls, on every backend.
- **Regression coverage:** query tests; character scenarios for slope limit, step, snap-down,
  wall slide, ceiling, depenetration and speed without tunnelling; byte-exact replay on the
  same machine.

"On every backend" is read precisely (§11): collision is CPU work that no backend touches, so
the backends differ only in drawing the walk. The same scripted tour passes headless on the null
backend in `zig build test`, windowed on macOS/Metal, and windowed and natively on Windows/Vulkan
on x86_64. Linux/Vulkan compiles.

**In M23:**
- a new L1 module, `physics3d`, on `core` alone: shapes, rigid poses, static and kinematic
  bodies, layers and masks, raycasts, shape casts, overlaps, static triangle meshes, and a
  character controller (§3–§7);
- a runtime collision-mesh asset, `foundry:collision_mesh` with a `.fcol` format, in `asset`
  (§8);
- `foundry:model_import` version 2 gains `collision` and `collision_exclude`, and the importer
  derives `<model>.collision` (§9);
- `sandbox3d` walks: a first-person character in the lit room, a small course of steps and ramps,
  its dimensions and speeds in content, a camera toggle, and a scripted tour that proves the exit
  condition headless (§10).

**Not in M23:**
- rigid-body dynamics, stacking, joints, ragdolls, vehicles, moving platforms that carry a
  character, and characters pushing each other (ADR-0051);
- a pointer-capture ("relative mouse") mode in `platform` (§10.3);
- anything in the public ABI (§12);
- a physics panel in the debug overlay (§15).

## 2. What exists

- **`physics2d`** (`engine/src/physics2d/`) is the precedent in every structural respect:
  - an L1 module on `core` alone, with no time, no velocity and no step;
  - `World` owns a `core.HandlePool` of bodies; a `Body` carries a shape, a centre, a kind, a
    `layer`/`mask` pair and an opaque `user: u64`;
  - bodies are read through `*const` and changed through named setters, so the broadphase can
    never describe a stale position (`world.zig`'s header);
  - `moveAndSlide` returns a `MoveResult` whose `hit_count`/`total_hits` pair tells a caller its
    buffer truncated, and `resolveOverlaps` is separate from movement on purpose;
  - shapes are rounded internally (`shape.Rounded`: a core plus a radius);
  - candidates are sorted by handle before use (I9).

  `physics3d` does not import it and shares no code with it. The two modules solve different
  geometry, and a shared "physics base" would be a third module that both depend on for no gain.
- **`core.math`** (`engine/src/core/math.zig`) has `Vec3`, `Quat`, `Transform` and `Mat4`, with
  ADR-0048's conventions pinned by M19's tests. `core.id.fnv1a64` hashes bytes, which the replay
  test uses.
- **`asset`**:
  - `mesh_file.zig` is the model for a bounded, canonical binary format: its version is in a
    field, not in the magic, and it has a `View` that copies no payload;
  - `tilegrid.zig` is the model for an asset whose product is not a GPU object. It is loaded by
    whoever wants it, and `render2d` and `physics2d` both use it without owning it;
  - `schemas.zig` holds the `kinds` table, which derives a record from a file extension.
- **`author`'s glTF importer** (`engine/src/author/gltf/`):
  - `translate.zig` flattens the node tree into model parts, refusing a chain whose product
    shears;
  - it refuses a `materials` mapping that names no material in the file ("maps no material in the
    file"), which is the precedent for refusing an exclusion that names no node;
  - `document.Node` carries an optional `name`.
- **`sandbox3d`**:
  - `samples/sandbox3d/main.zig` draws `models/room.gltf`, a 6 m by 6 m room with a floor, four
    single-sided brick walls 1.2 m high, a table, two crates, a pot, a plant and a glass pane
    (`scripts/m20/make_scene.py`);
  - the camera orbits (`Sample.eye`); `step` advances at the fixed step;
  - keys are F-keys only, so the overlay's filter box keeps typing;
  - the config is one `sandbox3d:config` record, and the dusk mod overrides it **whole**
    (`testdata/mods/dusk/dusk.fdt`), which §10.1 takes into account.
- **`platform`** reports held keys and per-frame mouse motion deltas
  (`engine/src/platform/input.zig`). It has no pointer capture.

## 3. `physics3d`: the module and its world

**Layer L1, on `core` alone**, beside `physics2d`, for ADR-0022's and ADR-0051's reasons: collision
has to be testable with no device, no asset, no entity and no clock, and a module that cannot
name any of them cannot depend on them by accident. `build.zig` declares it
`.{ .name = "physics3d", .deps = &.{"core"} }`. `sandbox3d` is granted it, and nothing else in
the engine is.

**No time, no velocity, no step.** Every call is "put this here", "move this by that" or "what is
there". Gravity, jumping, acceleration and speed caps are the game's, which owns velocity. A test
is "place, move, assert where it stopped", with no settling and no solver.

**`World`** holds:
- bodies in a `core.HandlePool`;
- the triangle meshes and hulls those bodies reference, each in its own pool (§4);
- the characters (§7);
- the scratch its queries reuse, so a steady-state tick allocates nothing.

Allocators are explicit on every call that may grow storage (CLAUDE.md §7).

**A body** is:

```zig
pub const Body = struct {
    shape: Shape,
    pose: Pose,                // position and unit rotation; rigid, no scale
    kind: BodyKind,            // .static or .kinematic
    layer: u32 = 1,
    mask: u32 = ~@as(u32, 0),
    user: u64 = 0,             // the game's, never interpreted (entity.bits() in practice)
};
```

- **Static** bodies may still be repositioned with `setPose`, which is a teleport; "static"
  describes frequency, as in 2D.
- **Kinematic** bodies are moved by the caller's casts or by the character controller.
- **A triangle mesh may only be static**, and adding a kinematic one is refused as
  `InvalidShape`. A moving mesh needs swept-mesh tests nothing has asked for.

**There is no trigger kind.** `3d.md` §8 says a trigger is an overlap query the game asks each
tick, and layers already express one: a volume on a layer the character's mask omits blocks
nothing, and an overlap query whose mask includes that layer finds it. That is one mechanism, not
two. The filter is symmetric for body pairs (`a.mask & b.layer != 0 and b.mask & a.layer != 0`)
and one-sided for queries, exactly as `physics2d.body.filtersAdmit` and `maskAdmits` document.

**Poses are rigid.** A `Pose` is a `Vec3` and a unit `Quat`, with no scale. A scaled box is a box
with different half-extents. Scale in a triangle mesh is baked by the importer (§9), which already
has the node's whole matrix. A body whose rotation is not unit length within `1e-4`, or whose
position is not finite, or lies beyond ±8,192 m on any axis, is refused as `InvalidPose`.

The bound on position is numerical, not gameplay. At 8,192 m an `f32` resolves about 1 mm, so the
contact skin (§5) still means something there. Beyond it, "held 5 mm off the wall" would be a
rounding error.

**Setters, not field writes:** `setPose`, `setShape`, `setFilter` and `setUser`, as in `physics2d`,
for the same reason. There is only one acceleration structure to keep in step now (§6), but the
API should not change when there are more.

## 4. Shapes

```zig
pub const Shape = union(enum) {
    sphere: struct { radius: f32 },
    capsule: struct { radius: f32, half_height: f32 }, // segment along local ±Y, half_height ≥ 0
    box: struct { half_extents: Vec3 },
    hull: HullHandle,
    mesh: MeshHandle,
};
```

**Hulls and meshes are handles, not slices.** They are variable-sized geometry. A slice stored in a
body is a raw pointer held long-term (I1), and a caller who freed or reloaded the bytes would leave
a dangling body. So:
- `World.addHull(gpa, points)` and `World.addMesh(gpa, positions, indices)` validate and **copy**,
  and return generational handles;
- a body refers to that handle;
- `removeHull` and `removeMesh` are refused as `InUse` while any body refers to the geometry.

**Every shape is a convex core plus a radius** (the 3D form of `physics2d.shape.Rounded`):

| Shape | Core | Radius |
| --- | --- | --- |
| sphere | a point | `radius` |
| capsule | a segment of length `2·half_height` along local Y | `radius` |
| box | the box | 0 |
| hull | the point set's convex hull | 0 |
| triangle (inside a mesh) | the triangle | 0 |

**This is why one narrowphase serves every pair (§5).** Distance and casts run on the cores, and the
radii are subtracted afterwards. The character's capsule, which is the case that matters most,
therefore spends nearly all its time with its core *separated* from what it touches. That is the
numerically well-conditioned regime, and penetration depth is simply `radius − distance`.

**A hull is its points.** A game supplies 4 to 256 points. They must be finite, and they must span
a volume: the largest tetrahedron found by a deterministic scan must exceed `1e-9` m³. Otherwise
the hull is refused as `InvalidShape`. The support function is the maximum dot product over the
points, which is all GJK needs, so **M23 computes no hull faces**. The consequence is recorded in
§5.3: a hull's `surface_normal` is its contact normal. Hull assets are postponed (§15).

**Validation, never assertion.** Every shape reaches here from a game, and from M25 from a mod.
A radius, half-height or half-extent that is not finite, a negative half-height, or a radius or
half-extent of 0 or less, is refused as `InvalidShape`. A capsule whose `half_height` is 0 is
permitted, and it is a sphere.

## 5. Narrowphase: distance, casts and depth

### 5.1 One algorithm, on cores

- **Distance** between two convex cores is GJK on their support functions, with a fixed budget
  of `max_gjk_iterations = 32` and termination when the simplex stops improving by more than
  `1e-7` m.
- **A shape cast** (translation only) is conservative advancement on that distance:
  1. measure the core distance `d`;
  2. subtract both radii and the contact skin;
  3. advance by what the closing speed along the separating axis allows;
  4. repeat, up to `max_cast_iterations = 32`, until the gap is under `1e-5` m.

  The hit's fraction, point and normal are those of the last iteration. A cast that uses its whole
  budget without closing reports its last *safe* fraction, which is short and never through.
- **Penetration depth** when the cores themselves intersect is EPA on GJK's final simplex, with
  `max_epa_iterations = 32`. It is needed only for depenetration (§7.4) and for overlaps of boxes
  and hulls. When only the rounded parts overlap, the depth is `radius_sum − distance` along the
  core-to-core axis, and EPA does not run.
- **A raycast** is a cast of a point core with radius 0.

Every constant is part of the interface, as `physics2d.max_slide_iterations` is, because a caller
can observe its effect.

**Why not one analytic routine per pair?** Five shapes make fifteen pairs. Each is a separate
routine with its own edge cases, and each would need its own determinism audit. GJK on support
functions is one routine whose correctness a test suite can pin pairwise. Its known weakness,
accuracy at exact contact, is exactly what rounded cores and the contact skin avoid. The trigger
to specialise a pair (§15) is a measurement: a profile showing capsule-against-triangle as the
cost of a character move above its budget (§11.4).

### 5.2 The contact skin

`contact_skin = 0.005` m, which is 5 mm. A cast stops `contact_skin` short of contact along the
hit normal, so the next query does not begin touching what the last one stopped against. It is an
interface constant, because a caller sees a character stand 5 mm off a wall. It is metric
because Foundry is metric (ADR-0048). At the §3 position bound it is still five `f32` steps.

### 5.3 What a hit reports

```zig
pub const Hit = struct {
    fraction: f32,        // of the requested displacement, in [0, 1]
    point: Vec3,          // on the surface hit
    normal: Vec3,         // contact normal, unit, pointing out of what was hit
    surface_normal: Vec3, // the face's normal (triangle, box face); = normal for sphere/capsule/hull
    body: BodyHandle,
    user: u64,
    triangle: u32,        // index within the mesh, or none_triangle
    started_inside: bool,
};
```

**`surface_normal` exists for the character.** A capsule resting on the edge of a stair touches
the edge, and the contact normal there tilts toward the character. Judged by that normal, a
perfectly flat stair would read as steep at every edge, and the character would lose its ground at
every step. The face normal of the triangle touched, or of the box face most aligned with the
contact normal, is what the surface *is*. The controller judges walkability by it (§7.2). Hulls
have no faces in M23 (§4), so theirs is the contact normal. A game that stands characters on hulls
is the trigger to compute hull faces (§15).

### 5.4 Order, ties and determinism

These are interface contract, as in `physics2d`:
- candidates are sorted by body handle index before any narrowphase, and triangles within a mesh
  by triangle index;
- the earliest hit wins by fraction, then lower body handle index, then lower triangle index;
- overlap results list bodies in handle order;
- no clock, no RNG, no global state, no address-dependent order, no fast-math, and fixed iteration
  counts everywhere.

The same binary, the same calls and the same order produce the same bytes (I9). Across machines,
agreement to the last bit is not promised (ADR-0013). The tests assert scenario outcomes with
tolerances on every host, and byte equality only for a replay on the same machine (§11.3).

## 6. Triangle meshes and the bodies' broadphase

**`addMesh` copies and builds.** It takes positions as `[]const Vec3` and indices as
`[]const u32`, three per triangle. It validates them:
- 1 to 1,048,576 triangles;
- at most 3,145,728 positions;
- every index in range;
- every position finite and within the §3 bound.

Otherwise it is refused as `InvalidMesh`, with the first offending triangle available to the
caller. It then copies both arrays into the world and builds a bounding-volume hierarchy:
- axis-aligned boxes;
- a median split on the longest axis of the triangles' centroid bounds, where the centroids are
  sorted by `(coordinate, triangle index)`, so the tree is a function of the input alone;
- at most four triangles per leaf.

**Degenerate triangles** are those whose area is under `1e-12` m². `addMesh` keeps them, and they
are never hit, because a triangle with no area has no normal. The importer drops them, with a
warning (§9). The runtime check stays because a game can call `addMesh` itself.

**Triangles are two-sided.** The room's walls are single-sided quads that face inward (`make_scene.py`).
- **Collision must not depend on which side a character approaches from.** A one-sided wall lets a
  character that reaches its back walk through it. That is the tunnelling this module exists to
  prevent.
- **A triangle's normal for a hit** is its face normal, flipped to face the side the query came
  from.
- **Depenetration from a triangle** pushes toward the side the core's centre is on.
- One-sided collision is postponed (§15).

**Why copy, not borrow.** `physics2d` borrows a tile grid's arrays, because a grid's cells are the
tile ids themselves and the loader keeps them alive. A collision mesh here also needs its tree,
which the asset does not hold. And the sample reloads packages (M20), so a borrowed slice would
dangle after a reload. Copying makes the world self-contained. A reload is then
`removeBody`/`removeMesh`, then `addMesh`/`addBody` (§10.4). The cost is one copy of a few
thousand triangles at load. The alternative, baking the tree into `.fcol`, is postponed until a
measurement shows `addMesh` too slow (§15).

**Bodies have no broadphase yet.** A query tests every live body's world bounds in handle order,
then descends the BVH of any mesh body whose bounds pass. The sandbox's world has a few bodies:
the room, the course and a character. A hash or a tree over bodies is added when a measured query
over a body count a game actually has exceeds budget (§15). It will not change an answer, because
order already comes from handles and not from the structure (§5.4).

**The queries** (all take a `Filter { mask: u32 = ~0, ignore: ?BodyHandle = null }`):

| Call | Returns |
| --- | --- |
| `raycast(gpa, origin, direction (unit), max_distance, filter)` | `?RayHit`: the nearest hit, with `distance` in place of `fraction` |
| `shapeCast(gpa, shape, pose, displacement, filter)` | `?Hit`: the earliest hit of `shape`, which may be sphere, capsule, box or hull |
| `overlap(gpa, shape, pose, filter, out: []Overlap)` | `OverlapResult { count, total }`: everything overlapping, in handle order. For a mesh it lists the body once, with the first triangle found |
| `contacts(gpa, shape, pose, filter, out: []Contact)` | `ContactResult { count, total }`: overlaps with depth and push-out normal, in handle order, then triangle order. This is what depenetration uses, exposed because a game may want to ask it too |

A mesh cannot be the *moving* shape of a cast or an overlap. It is refused as `InvalidShape`.
Every buffer pattern reports a `total`, so a caller whose buffer was too small learns that it
truncated, as in 2D. It is the shape the C ABI needs (M25).

## 7. The character controller

### 7.1 What a character is

```zig
pub const CharacterConfig = struct {
    radius: f32,         // metres
    height: f32,         // total, feet to crown; ≥ 2·radius
    max_slope: f32,      // radians; a surface steeper than this is a wall; in (0, π/2)
    step_height: f32,    // metres; in [0, height − 2·radius]
    snap_distance: f32,  // metres; in [0, height]
    max_move: f32,       // longest displacement one move accepts; > 0
    layer: u32 = 1,
    mask: u32 = ~@as(u32, 0),
};
```

**The gameplay numbers have no defaults** (I5). How tall a character is, how steep a hill it
climbs and how high a step it takes are a game's, and in the sample they are content (§10.1). Only
numerical constants are the module's: the skin, the iteration budgets and the tolerances.

`addCharacter(gpa, config, feet, user)` validates the config, refusing it as `InvalidCharacter`.
It then adds a **kinematic capsule body** that carries the character's layer, mask and user, and
returns a `CharacterHandle`. The body is ordinary, so other characters' moves and every query
see it (§7.6).

**A character's position is its feet**, the lowest point of its capsule, not the capsule's centre
as a body's is. The feet are what a game places on the ground, measures a step from and puts a
camera above.

### 7.2 One move

`moveCharacter(gpa, handle, displacement, hits: []Hit) !?CharacterMove` moves the character by up
to `displacement` and commits the result:

```zig
pub const CharacterMove = struct {
    feet: Vec3,
    grounded: bool,
    ground: ?Ground,       // surface normal, body, user, triangle, when grounded
    ceiling: bool,         // an upward part of the move was stopped by a downward-facing surface
    walls: u32,            // non-walkable contacts that redirected the move
    stepped: f32,          // height gained by step-up in this move, metres (0 if none)
    snapped: bool,         // snap-down kept the character on the ground
    depenetrated: bool,    // it began overlapping and was pushed out
    stuck: bool,           // it is still overlapping after the budget, and did not move
    hit_count: u32,
    total_hits: u32,
};
```

- It returns null for a stale handle.
- A displacement that is not finite, or longer than `max_move`, is refused as `InvalidMove`, and
  nothing moves.
- The requested endpoint's feet and capsule centre must also remain inside §3's coordinate
  envelope, even if a wall could stop the move sooner. Depenetration and the final result obey
  that envelope too; an invalid result is refused before committing any body/ground change.

**Walkable** means `surface_normal.y ≥ cos(max_slope)`, using the surface normal (§5.3) and the
world's up, which is +Y (ADR-0048). The up axis is fixed in M23, and a configurable up is
postponed (§15).

In order:

1. **Depenetrate** (§7.4). If the character is still overlapping, report `stuck` and stop.
2. **Collide and slide**, for at most `max_slide_iterations = 4`. Each iteration:
   1. casts the capsule along what remains;
   2. moves it to the hit, less the skin;
   3. projects the remainder onto the hit's plane.

   **A non-walkable contact never lifts the character.** Its horizontal remainder is projected on
   the plane of its normal flattened to horizontal, as if it were a vertical wall. Its downward
   remainder is projected on its true plane, so a falling character slides down a steep slope
   rather than hanging on it. No remainder after a non-walkable contact rises above what the
   displacement itself asked for.

   A walkable contact's remainder is projected on its true plane, so walking up a gentle ramp
   climbs it. A contact whose surface normal faces down while the remainder has an upward part
   sets `ceiling`, and the upward part is removed.
3. **Step up.** This happens only if the character was grounded when the move began, the move has
   a horizontal part, and step 2 met a non-walkable contact. The controller:
   1. casts up by `step_height`, stopping at a ceiling;
   2. casts the remaining horizontal motion from there;
   3. casts down by the height it rose plus `snap_distance`.

   The step is kept only if it lands on a walkable surface, no higher than `step_height` above
   the start, and the character got further horizontally than the step-2 result did. Otherwise
   step 2's result stands. **The walkable-landing rule is what stops a character from stepping up
   a steep slope a step at a time:** its landing is on the slope, which is not walkable.
4. **Snap down.** This happens only if the character was grounded when the move began, the
   displacement did not ask to rise (`displacement.y ≤ 0`), and it is not grounded now. The
   controller casts down by `snap_distance`. If that finds a walkable surface, the character moves
   onto it. This keeps it on a ramp or a flight of stairs going down, instead of stepping off
   each tread into a fall.
5. **Ground.** The controller probes down by `2·contact_skin`. The character is grounded if and
   only if that probe finds a walkable surface. The result is kept for the next move's steps 3
   and 4.

**Jump and gravity are the caller's.** A game jumps by asking for an upward displacement; the
controller neither snaps nor steps up on that move. It falls by adding its own gravity to the
displacement, and zeroes its vertical speed when `grounded` or `ceiling` says to.

### 7.3 No tunnelling

Every part of a move is a continuous cast, so no speed passes through geometry, including a
zero-thickness two-sided wall. The only limit is `max_move`. It bounds how long a single move may
be, so that a runaway displacement, such as a NaN-adjacent value or a bug, is refused rather than
swept across a whole level. It is configured by the game: the sample's is 1 m per tick (§10.1).
§11.2's tunnelling scenario runs at `max_move` against a zero-thickness wall and a 1 cm box.

### 7.4 Depenetration

A character that begins a move overlapping something may have been:
- teleported (`setCharacterFeet`);
- moved into by a static body's `setPose`;
- given a reloaded mesh (§10.4).

The controller then pushes it out along the deepest contact (§6's `contacts`), by the depth plus
the skin, up to `max_depenetration_iterations = 4` times, and reports `depenetrated`. If it is
still inside after that, the move reports `stuck` and changes nothing further, so the game can
decide, for example by respawning. As in `physics2d.resolveOverlaps`, being stuck is a state a
game can see, never a silent teleport.

### 7.5 What is held between moves

Each character keeps:
- its body;
- its config;
- whether it was grounded, and on what.

Nothing else. There is no velocity, so a character that is not moved stays exactly where it is.
`setCharacterFeet` teleports it and clears its ground. `removeCharacter` removes its body.

### 7.6 Characters and each other

A character's capsule is an ordinary kinematic body, so another character's move treats it as
solid and stops against it. **Nothing pushes anything.** A move changes only the character moved,
and every other body's bytes are unchanged (§11.2). Pushing is ADR-0051's deferred item.

## 8. The collision-mesh asset (`asset`)

**`foundry:collision_mesh`, version 1:** a record with one field, `source`, naming a `.fcol`
file. That is the shape of `foundry:mesh` and `foundry:tilegrid`, for the same reason: the bulk is
a binary payload (CLAUDE.md §6). It is registered in `schemas.zig`'s `kinds` table with the
extension `fcol`, so a hand-placed `.fcol` derives a record the way a `.fmesh` does. That is how
tests and a future non-glTF producer write one.

**`.fcol`, format version 1** (`asset/collision_mesh.zig`), little-endian:

```
0   magic            [4]u8   "FCOL"
4   format_version   u32     1
8   vertex_count     u32
12  triangle_count   u32
16  bounds_min       f32[3]
28  bounds_max       f32[3]
40  positions        f32[3 · vertex_count]
..  indices          u32[3 · triangle_count]
```

- **The coordinates are model space**, the same space as the model's parts, after the import's
  `front` rotation (ADR-0055).
- **Reading is a `View` that copies nothing**, as `mesh_file.View` is.
- **Refusals:** a wrong magic is `NotACollisionMesh`; an unknown version is `UnsupportedVersion`
  (I8). `Malformed` covers truncation, a non-finite position, an index out of range, bounds that
  do not contain the positions, and trailing bytes. `OverLimit` covers more than §6's counts or a
  file over 256 MiB.
- **The writer is canonical:** the same triangles produce the same bytes.

**The loader lives here** and is registered at runtime by whoever wants it (I6), as
`tilegridLoader` is. `physics3d` never sees an asset. The loader copies the borrowed `View`
into aligned, owned `CollisionMesh` arrays, since the registry releases the source bytes after
loading. The game hands those arrays to `addMesh`, which copies them (§6); a direct format
consumer can use `View.copy` for the same alignment and ownership. That is ADR-0053's separation applied
to collision: import, runtime asset and simulation stay three things.

## 9. Import: deriving collision (`author`)

**`foundry:model_import` version 2** gains two additive fields:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `collision` | bool | `false` | derive `<model>.collision` from this model's geometry |
| `collision_exclude` | `[string]` | empty | glTF node names whose meshes, and whose subtrees', are left out of it |

**A model collides only when its import says so.** A `.gltf` with no import record, and a version-1
import record, derive no collision. Imports convert nothing silently (ADR-0048), and a decorative
model that suddenly blocked a corridor would be exactly the surprise that rule forbids.

**Exclusion is by node name, and an exclusion that matches nothing is refused.** It uses the
precedent of `materials`' "maps no material in the file":

    model_import.collision_exclude: "Plnt" names no node in the file

An exclusion that names no node is almost always a typo, and a typo here would silently make a
plant solid. Every node carrying the name is excluded, with its subtree. An unnamed node cannot be
excluded; an author who wants to exclude it names it. Exclusion is not inferred from alpha mode,
material or naming conventions (such as a `UCX_` prefix). Those would be rules hidden from the
record, and the record is the place an author reads (ADR-0057 weighs the alternatives).

**The derived record** is `<model>.collision`, which adds one segment to ADR-0055's scheme beside
`mesh<i>`, `material<i>` and `texture<i>`. It is written as `.fdt` and checked by the one checker,
and its `.fcol` goes to the compiler's asset output. The collision mesh is **one** mesh per model:
- every triangle primitive of every node not excluded;
- transformed by the node's flattened matrix, including its scale and after `front`, so the
  runtime needs no scale (§3);
- in node order, then primitive order, then index order.

Degenerate triangles (§6) are dropped, with one warning that counts them. A model whose collision
would be empty after exclusion is refused ("derives an empty collision mesh"). An author who wants
no collision says `collision false`. Non-triangle primitive modes are already refused by M20's
importer.

**The output is a function of the source bytes and the record** (ADR-0055, I9). M20's hash pins
on the room's and crate's import output stay valid, because `collision` defaults to `false` and
M23 adds collision only through new records and a new model (§10.2).

**The model record does not name its collision.** A game names both in its own content, as the
sample does (§10.1). Linking them is postponed until a game wants to find a model's collision from
the model alone (§15).

## 10. `sandbox3d`: a first-person walk

### 10.1 The walk is its own record

The dusk mod overrides `sandbox3d:config.main` **whole** (M22; `content-mods.md` §4). If the
walk's settings lived in that record, every lighting mod would have to restate the character's
height and the room's collision, and a lighting mod written before M23 would silently turn
collision off. So the walk is a **second record** of a new sample schema:

```
@schema walk {
    start_camera string (default "walk")      # "walk" or "orbit"
    spawn { x f32 y f32 z f32 }               # feet, metres
    spawn_yaw f32 (default 0)                 # radians about +Y; 0 looks along −Z
    radius f32  height f32  eye_height f32    # metres
    max_slope f32                             # radians
    step_height f32  snap_distance f32        # metres
    walk_speed f32                            # metres per second
    gravity f32                               # metres per second², downward
    turn_rate f32                             # radians per second, arrow keys
    look_rate f32                             # radians per point of mouse motion
    course id                                 # the model drawn for the course
    collision [id]                            # foundry:collision_mesh records the character meets
}
```

- **`sandbox3d:walk.main`** is in the sample's package, with a 0.3 m radius, 1.8 m height,
  1.65 m eye, 45° (0.785398) maximum slope, 0.35 m step, 0.3 m snap, 3 m/s walk and 9.81 m/s²
  gravity.
- **Every field is validated** as the M22 light settings are. An invalid record falls back, as a
  whole, to walking disabled and the orbit camera, with a warning. The character never sees a
  half-valid config.
- **`max_move`** is `walk_speed` times the fixed step times 4, but at least 1 m. The sample
  derives it, and it bounds a tick's displacement even while falling.
- **The dusk mod is unchanged.** It does not override `walk`, so dusk walks as the base does. A
  mod could override `walk` alone.

### 10.2 The course

`scripts/m20/make_scene.py` gains a third output, `models/course.gltf` and its `.bin`, so that
`room.gltf`'s and `crate.gltf`'s bytes, and every pin on them, stay unchanged. The course is a lit,
shadow-casting set of boxes in the free north-west quarter of the room, clear of the table, the
orrery, the crates and the glass:
- **a flight of four steps**, each 0.15 m high and 0.30 m deep, to a 1 m by 1 m platform 0.60 m
  up;
- **a walkable ramp** of 25° down from the platform;
- **a steep ramp** of 55°, against the west wall, which the character must not climb.

Its import record sets `collision true`. The room's import record gains `collision true` and
`collision_exclude ["Plant"]`, since the leaves are alpha-masked quads that should not stop anyone.
The pot, the crates, the table and the glass collide. The walk record lists
`sandbox3d:models.room.collision` and `sandbox3d:models.course.collision`. Step 5 pins the exact
coordinates in its Resolution and checks every scenario against them.

### 10.3 Walking, looking and the camera

- **The camera:**
  - **F3** toggles between the walk and M22's orbit. The walk is the default, because it is M23's
    runnable result;
  - the walk's camera stands at the feet plus `eye_height`, looking along the yaw and pitch;
  - pitch is clamped to ±85°.
- **Keys:**
  - W, A, S and D move relative to the yaw;
  - the arrow keys turn and pitch;
  - holding the right mouse button looks with the mouse's motion.

  These are the sample's first letter keys. **They are ignored while a text field in the overlay
  has keyboard focus**, so the filter box keeps typing, which is the reason the F-key comment in
  `main.zig` gives.
- **Pointer capture is deferred to M26**, which needs it for a person to play. Holding a button to
  look needs nothing from `platform`. SDL3's relative-mouse mode behaves differently under X11 and
  Wayland, so adding it would be a Linux-specific change, and 3d.md §10.2 would then owe it a
  Linux run in M23. The playable sample, M26, runs on a freshly provisioned Linux machine anyway.
- **Movement is simulation.** `step`, at the fixed step, turns the held keys and the yaw into a
  horizontal displacement of `walk_speed · dt`. It adds the sample's vertical velocity, which
  gravity drives and `grounded`/`ceiling` reset, then calls `moveCharacter` once per tick. The
  frame only reads the result for the camera. The walk is the same at any frame rate, because it
  is driven by ticks (I9).
- **Falling out:** a character whose feet fall below −10 m, which only a mod's broken collision
  could cause, respawns with a warning.
- **The profiler** gains a `character` zone around the move (`core.profile`), so the overlay shows
  its cost.

### 10.4 Reload

The sample already follows its records across a package reload (M20's `follow`). When a collision
record it lists changes, it:
1. removes that record's body and mesh;
2. loads the new `View`;
3. adds it again.

The character's next move depenetrates it if the new geometry now overlaps it (§7.4). A reload
that removes a collision record the walk names leaves that geometry out, with a warning, rather
than failing.

### 10.5 The tour

`FOUNDRY_SANDBOX3D_WALK=tour` replaces the keys with a scripted intent per tick: a yaw and a
move direction, in `samples/sandbox3d/tour.zig`. It walks the course and logs a checkpoint line
for each stage and a final `tour: pass` or `tour: FAIL <stage>`. The stages are:
1. **Floor:** it crosses the floor, grounded on every tick, including across the seam between the
   floor's triangles, with no wall contact.
2. **Steps:** it climbs the four steps, and its feet reach 0.60 m ± `2·contact_skin` on the
   platform, with `stepped` > 0 on four moves.
3. **Ramp:** it walks down the 25° ramp, grounded on every tick, with `snapped` on at least one.
4. **Steep slope:** it pushes into the 55° ramp for two seconds, and its feet rise no more than
   `contact_skin` above the floor.
5. **Wall slide:** it walks at 30° into the north wall for two seconds, and its progress along the
   wall is at least 80% of the tangential part of what it asked for.
6. **Replay:** the fnv1a64 hash of every tick's feet bytes equals a second run of the same tour
   from a fresh world, in the same process.

The same tour is a `sandbox3d-test` test against the sample's compiled package. It runs on null
in `zig build test`, and windowed on each GPU (§11.4).

## 11. Verification

### 11.1 Queries and shapes (`physics3d` unit tests)

- **Distance and casts:**
  - GJK distance for every pair of sphere, capsule, box, hull and triangle, against analytic
    answers in rotated poses, to `1e-5` m;
  - casts for the same pairs, with the hit's fraction, point, normal and `surface_normal` checked;
  - a raycast against each shape.
- **Overlaps and contacts:**
  - `overlap` and `contacts` with depths against analytic answers, including core-intersecting
    boxes and hulls, where EPA runs;
  - a capsule whose rounded part only overlaps, where it does not.
- **Order:** ties broken by fraction, then handle, then triangle.
- **Filters:** a symmetric filter pair, a one-sided query mask, and `ignore`.
- **Buffers:** `total` beyond a full buffer.
- **Refusals**, each with its named error:
  - `InvalidShape`: non-finite, zero or negative dimensions; a hull with fewer than 4 points,
    more than 256, coplanar points or a non-finite point; a mesh as a kinematic body or as a
    cast's moving shape;
  - `InvalidPose`: a non-unit rotation, or a position that is not finite or is beyond ±8,192 m;
  - `InvalidMesh`: an index out of range, a non-finite position, zero triangles, or too many;
  - `InUse`: removing a hull or mesh a body references.
- **Guards verified by mutation**, each named in its step's Resolution:
  - a hull's volume check;
  - the tie-break;
  - the two-sided flip;
  - the walkable test's use of `surface_normal`.

### 11.2 Character scenarios (`physics3d` unit tests)

These are the regression list from `3d.md`'s row, each a named test on geometry built in the test:

| Scenario | Asserts |
| --- | --- |
| slope limit | walks up 30° grounded; 50° pushed into for 600 ticks rises ≤ skin; falls onto 50° and slides down, never `stuck`, never hangs |
| step | climbs 0.15 m and 0.30 m steps with step 0.35; refuses 0.40 m; `stepped` equals the rise ± skin |
| stair edge | stands on a tread's edge with the capsule overhanging, still `grounded`, by `surface_normal` |
| snap-down | walks down stairs and a 25° ramp grounded on every tick; does not snap when the displacement rises (a jump) |
| wall slide | 30° into a wall, progress along it ≥ 80% of the tangential request; into a corner, stops without jitter |
| ceiling | an upward move under a low ceiling sets `ceiling` and ends one skin below it |
| depenetration | teleported half into a box and into a mesh, is pushed out and reports `depenetrated`; sealed inside a closed box, reports `stuck` and does not move |
| tunnelling | at `max_move` per tick, never ends beyond a zero-thickness two-sided wall or a 1 cm box, from either side |
| characters | A walking into B stops against it; B's body bytes are unchanged |
| refusals | `InvalidCharacter` for each out-of-range config field; `InvalidMove` for a non-finite or over-long displacement, with nothing moved |

### 11.3 Determinism

- **Replay:** a 1,200-tick scripted walk over a mesh course, hashed per tick (fnv1a64 of the feet
  bytes), equals a second run from a fresh world in the same process. The same property, run
  on the real package, is §10.5's stage 6.
- **No hash constant is pinned** for physics output. ADR-0013 does not promise it across
  machines, and a pin that fails on the PC for a legitimate reason teaches people to ignore pins.
- **The `.fcol` writer is pinned by hash** (§11.4), since its output is integers and exact `f32`
  copies of the importer's values.

### 11.4 Assets, import and the sample

- **`.fcol` (`asset`):**
  - a round trip, and the writer's bytes pinned by hash for a fixture;
  - every `ReadError`, including a newer version reporting `UnsupportedVersion` rather than
    `NotACollisionMesh` (I8).
- **Import (`author`):**
  - `collision true` derives `<model>.collision`, whose triangles are the fixture's in model space
    after `front` and a scaled, rotated node chain;
  - `collision_exclude` removes a named subtree;
  - an exclusion naming no node is refused, with its diagnostic;
  - an empty result is refused;
  - degenerate triangles are dropped with a counted warning;
  - `collision false`, and a version-1 record, derive nothing, and the M20 room import's hash is
    unchanged.
- **The sample:**
  - the tour passes in `zig build test` (null);
  - it passes windowed on Metal from a relocated ReleaseSafe install;
  - it passes windowed on Vulkan on the PC from a relocated ReleaseSafe install;
  - F3, walking, looking and a live reload of the course's collision are exercised by hand, and
    what was seen is recorded;
  - the dusk mod still loads, and still walks.
- **The character's cost:** the median and p95 of a move in the tour, at ReleaseSafe, are recorded
  on the Mac and the PC. **Budget: p95 under 0.25 ms per move.** Exceeding it is the trigger in
  §5.1 and §6.
- **Distribution:** both ad-hoc releases stage, since the sample gains an asset kind, `fcol`
  (AGENTS.md's staging trigger).

## 12. The public ABI and the overlay

**Published in M25 (2026-10-02):** raycast, shape cast, overlap, sphere/capsule/box bodies and
the character are in `FoundryApi_v6`, with ownership enforced at the boundary (`public3d.md`
§7–§8). Hull and mesh shapes and `contacts` are not published.

**Nothing enters the public ABI in M23.** `3d.md` §9 publishes `physics3d` queries and the
character in `FoundryApi_v6` in M25, after the Zig API has held for a milestone. The API is
drawn for that table already:
- generational handles;
- a `u64` user value;
- caller-owned buffers with totals;
- named refusals of every input;
- no callbacks into game code.

**The debug overlay gains nothing.** `debug` is not granted `physics3d`. Granting it is a layering
change to put to the owner when debugging a game's collision needs a panel (§15). Until then the
profiler's `character` zone and the sample's log are what is shown.

## 13. Platform assessment

- **Metal and Vulkan:** they draw one more lit model, and nothing in `rhi`, `render3d` or the
  shaders changes. The course uses M22's lit model as it is.
- **Windows/Vulkan, on the PC, is needed** for:
  - the native x86_64 run of the `physics3d` suite and the tour, where floating-point results
    may differ in their last bits, which is why §11.2 asserts outcomes with tolerances;
  - the windowed walk from a relocated install.

  The same PC rules as M22 apply: check it is idle first, use `-j2` at below-normal priority, run
  jobs in the background, and build from a worktree.
- **Linux: compile only.** M23 changes nothing Linux-specific. There is no platform change,
  because pointer capture is deferred (§10.3). So `3d.md` §10.2 owes no run.

## 14. Implementation order — seven bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

### Step 1 — `physics3d`: shapes, poses, bodies and the convex narrowphase — Done 2026-09-30

This step implements §3, §4 and §5, and §6's queries against convex bodies:
- the module in `build.zig`, granted to `sandbox3d`;
- `Shape`, `Pose`, `Body`, `World` and its setters, hulls, and filters;
- GJK distance, conservative-advancement casts, and EPA;
- `raycast`, `shapeCast`, `overlap` and `contacts` against spheres, capsules, boxes and hulls.

It adds §11.1's tests except the mesh ones, with the hull-volume and tie-break mutations.
**Exit:** every convex pair's distance, cast and contact matches its analytic answer in rotated
poses, and every §11.1 refusal is a named error.

**Resolution (2026-09-30): complete.** `engine/src/physics3d/` holds `shape.zig`, `gjk.zig`,
`narrow.zig`, `body.zig`, `world.zig` and `tests.zig`. `build.zig` declares the module on `core`
alone and grants it only to `sandbox3d`, and CLAUDE.md §4.3 lists it. The world has:
- bodies and ref-counted hulls in `core.HandlePool`s;
- the setters `setPose`, `setShape`, `setFilter`, `setUser` and `setKind`;
- `raycast`, `shapeCast`, `overlap` and `contacts` over spheres, capsules, boxes and hulls.

`Shape` has no `.mesh` variant yet, because Step 2 adds it with `MeshHandle`.

Where implementation sharpened the design:
- **Pose rotations enter through `core.math.Quat.validated`.** That means `Quat.unit_tolerance`,
  which is 1e-3, and normalisation, rather than §3's 1e-4. It is the one entry point every
  rotation from outside already takes, and two tolerances for the same question would disagree.
- **`gjk_tolerance` is 1e-6 m, not §5.1's 1e-7.** An `f32` resolves 1.2e-7 m at 1 m, so 1e-7 was
  reachable only through the no-progress rule. GJK also stops when a new support point repeats a
  simplex vertex, or when the closest point stops getting closer.
- **Normals near contact.** The distance normal is the plane normal of GJK's final triangle when
  the simplex is one, which is exact however small the gap. A raycast's zero-radius contact
  otherwise produced a normal that was mostly rounding: 0.01 off at 100 m. Edge and vertex
  contacts still use the witness direction. That is also where the true normal is ambiguous.
- **Raycasts target separation 0**, and report the exact surface. Shape casts stop `contact_skin`
  short, along the normal.
- **A conservative-advancement step that lands inside the surface.** One that lands within
  `cast_tolerance` (1e-5 m) inside is accepted as the contact. The original "keep the last safe
  answer" rule turned a ray's exact landing, 1e-7 inside, into a hit at fraction 0. A step deeper
  than that still keeps the last safe fraction.
- **EPA grows a degenerate start simplex** along ten fixed directions, in a fixed order, so the
  result depends on the input alone:
  - capacity is 64 vertices and 128 faces;
  - depth is clamped at 0;
  - it returns null for a Minkowski difference with no volume, which only sphere and capsule cores
    produce. `narrow.separation` then pushes along the line between the centres, or along +Y when
    they coincide, by the radii.
- **Queries allocate nothing, so they take no allocator.** A mesh BVH walk in Step 2 uses a fixed
  stack.
- **The setters take one even though nothing uses it yet**, as §3 asked, so a broadphase does not
  change their signatures.
- **`InvalidQuery` is a fourth refusal**, for a non-unit ray direction, a negative or non-finite
  reach, and a non-finite displacement. `InvalidPose` also covers a ray origin beyond the bound.
- **Overlap means penetration:** touching is not overlapping.
- **Test tolerances follow the coordinates.** The analytic tests run every case under four rigid
  frames, out to (900, −300, 1200), where an `f32` step is 1.2e-4 m. Their tolerance scales with
  the frame, from 1e-5 m to 5e-4 m, because no narrowphase answers more finely than its inputs.

**Coverage:** 31 tests:
- separation against analytic answers for fifteen pair cases, covering every pair of sphere,
  capsule, box and hull, including edge, corner and crossed-segment cases, in four frames;
- EPA depth for boxes, hulls and a sphere deep in a box, and rounded overlaps that do not need EPA;
- raycasts, shape casts and surface normals, including an edge contact and the diagonal tie;
- a capsule that does not tunnel through a 1 cm plate from either side;
- handle-order overlaps, with a truncated buffer's total;
- ties, including a reused slot;
- mask, ignore and trigger-by-layer filtering;
- every named refusal;
- byte-identical results for the same calls.

**Guards verified by mutation:**
- skipping the hull-volume check failed the coplanar-hull refusal;
- letting an equal fraction replace the best failed the tie test;
- the face-normal and landing fixes were each found by a failing test before they existed.

The two-sided and walkable-by-`surface_normal` mutations belong to Steps 2 and 4.

**Bar:** all nine commands pass, and `zig build test` passes 1,927 of 1,928 tests with one expected
skip: 31 more than M22's close. `zig fmt` reflowed `gjk.zig`'s direction table after the run, a
whitespace-only change that was re-checked.

Nothing is in the ABI. Step 2 (triangle meshes) has not begun.

### Step 2 — `physics3d`: static triangle meshes — Done 2026-09-30

This step implements §6: `addMesh` and `removeMesh`, with copying, validation and the
deterministic BVH; triangle cores in the narrowphase; two-sided hits with `surface_normal`; mesh
bodies in every query. It adds the mesh parts of §11.1, with the two-sided and tie-break
mutations. **Exit:** every query against a mesh returns the same hit as against the same triangles
added as separate hulls, in handle-then-triangle order.

**Resolution (2026-09-30): complete.** `mesh.zig` validates and copies positions and indices,
retains degenerate triangles without ever querying them, and builds an axis-aligned BVH with
at most four triangles per leaf. Median splits use the longest centroid axis (ties X, Y, Z)
and `(coordinate, original triangle index)` ordering. A mesh lives in its own generational
pool; bodies retain it, removal while referenced returns `InUse`, and stale handles are refused.
`addBody`, `setShape` and `setKind` all enforce static-only meshes. `setKind` now returns
`error{InvalidShape}!bool` so changing an existing mesh to kinematic is a named refusal too.

All four queries use the same triangle support core and existing rounded-core narrowphase.
Ray/shape hits carry the triangle index and two-sided face normal, distinct from the contact
normal at edges. Overlap reports each mesh body once at its first overlapping triangle;
contacts reports every penetrating triangle, in body-then-triangle order, with buffer totals.
Static-body teleporting works through `setPose` and queries derive bounds from the current pose.

Implementation details that sharpen the specification:
- `mesh.validate(positions, indices)` exposes `Validation { valid, triangle }`, identifying
  the first offending indexed triangle before allocation. Count failures and invalid unused
  positions have no offending triangle. `addMesh` itself returns `InvalidMesh`.
- Queries still take no allocator. `addMesh` reserves World-owned candidate scratch for the
  largest mesh added; a 32-entry fixed-stack walk gathers candidates and an allocation-free
  heap sort restores original triangle order before narrowphase. Scratch remains until world
  deinitialisation. This prevents spatial tree order from becoming query or tie order.
- Transformed broadphase bounds have 2 mm conservative padding for `f32` rounding. This
  admits extra candidates only; it does not change narrowphase skin or hit distances.
- A zero-radius ray landing exactly on a triangle preserves the last separated approach side:
  rounding at the plane otherwise reversed a rotated ray's normal. A core intersection with
  no volume uses the triangle face toward the core centre rather than the convex-pair fallback.
- The exit's “separate hulls” oracle is a separate flat **point-set convex core** per triangle,
  not `addHull`: Step 1 correctly refuses coplanar public hulls. No hull validation is weakened.
  The oracle compares BVH answers against brute-force independent cores, including misses.

**Evidence:** twelve added tests (43 focused physics tests total) cover every convex kind
against triangles and triangle–triangle separation/casts in rigid frames, both sides, edge
normals, core-intersecting depth, fast capsule casts through zero-thickness walls, validation
and diagnostics, static-only/setter refusals, copied/shared lifetime and teleporting, stale
generations, degenerates, filters, truncated/empty buffers, exact body/triangle ties, reproducible
tree construction, a spatially shuffled 1,024-triangle brute-force oracle and same-process
replay. Every allocation failure in mesh/world creation unwinds without leaks.

Four deliberate mutations failed the intended tests: removing the two-sided normal flip,
omitting candidate index sorting, admitting kinematic meshes, and querying degenerate triangles.
All were restored. The 43-test suite passes in Debug and ReleaseSafe. The complete nine-command
bar passes **1,939 of 1,940 tests**, one expected skip, with Metal and both cross-target checks
and all three headless sample runs clean. The module remains on `core` alone; no ABI, asset,
import, platform, renderer or sample change. Native Windows proof remains Step 6 and Linux
remains compile-only. Step 3 has not begun.

### Step 3 — `asset` and `author`: `foundry:collision_mesh`, `.fcol`, and derived collision

This step implements §8 and §9:
- the schema, the `kinds` entry, the format, `View`, the writer and the loader;
- `foundry:model_import` version 2 with `collision` and `collision_exclude`;
- derivation of `<model>.collision`, with its refusals and warning.

It adds §11.4's asset and import tests, including the unchanged M20 hash. **Exit:** a fixture
glTF with `collision true` compiles to a `.fcol` whose bytes match their pin, and every refusal is
reported by the compiler with its diagnostic.

**Resolution — Step 3 (2026-09-30).** §8 and §9 are implemented, with no change to ADR-0057:

- `asset/collision_mesh.zig` supplies `versionOf`, the borrowed `View`, canonical `write`,
  aligned `View.copy`, `CollisionMesh` and the explicitly registered `collisionMeshLoader`.
  Counts, length, indices, finite containing bounds and the ±8192 m geometry envelope are
  validated before any consumer sees arrays. The 256 MiB format/loader ceiling does not raise
  the registry's separately configured source-read ceiling.
- The runtime schema joins `kinds` without changing existing kind indices. Hand-placed `.fcol`
  assets and generated assets follow the same package/store/registry path. The host owns loader
  registration; neither `physics3d` nor the ABI gains an asset dependency.
- Import v2 appends its two fields. Missing exclusions are an optional value interpreted as
  the empty list, including when extending a v1 record. The importer reuses validated `.fmesh`
  streams and the visual default-scene traversal's exact flattened matrices, then emits
  collision in node-array order. Exclusion propagates to descendants, applies to every repeated
  name and infers nothing. The ID is `<model>.collision`; its private generated source path is
  `<source dir>/<stem>/collision0.fcol`. Degenerates are dropped with one `u64` count; a fully
  degenerate result is refused with both its warning and the empty-result diagnostic.
- Four format tests, one schema compatibility test and six author/import tests were added;
  the existing end-to-end import test also proves collision opt-in, unchanged visual bytes,
  generated package loading and compiler diagnostics. Focused results: **124/124 asset** and
  **91/91 author**. Both the writer and triangle import pin **`c854ac2cc345318d`** (FNV-1a64).
- Ten guard mutations fail: format version, file cap, counts, exact length, indices, coordinate
  envelope, finite bounds, unknown exclusion, subtree inheritance and degenerate filtering.
  The bounds mutation first passed because the old cases also failed containment; a NaN-bounds
  case now isolates it and fails when the finite guard is removed. All guards are restored.
- The nine-command bar passes **1,950 of 1,951 tests**, one expected skip. Native, Metal,
  Linux/Windows cross checks and three headless sample runs pass. Both room and sandbox
  ReleaseSafe ad-hoc macOS releases stage from this working tree (revision input `cb7510a`).
  SHA-256 comparison against the pre-step outputs passes for all eight room meshes, the crate
  mesh and the complete sandbox3d package (`9b26a63ac04e44204bbce15cd12f8706f7721ee732166248599b0ac785841702`).

No character, walk input, sample collision content or ABI work was added. Step 4 is next;
the Windows runtime proof remains Step 6 and Linux remains compile-only.

### Step 4 — `physics3d`: the character controller — Done 2026-09-30

This step implements §7: the config, `addCharacter`, `moveCharacter`, `setCharacterFeet` and
`removeCharacter`; depenetration, slide, step-up, snap-down, ground and ceiling. It adds every
§11.2 scenario and §11.3's replay, with the walkable-by-`surface_normal` mutation. **Exit:** every
§11.2 scenario passes, and the 1,200-tick replay is byte-identical in-process.

**Implementation refinement (2026-09-30):** downward ground/landing probes must classify a
shared riser–tread edge as the tread when both faces hit at the same position (within cast
tolerance) on the same body. A box probe likewise recognises an adjacent walkable face only
when its contact witness lies on that face. Otherwise triangle order can select the riser's
non-walkable face and prevent even a short step from being climbed. Only these controller probes prefer a
walkable face at that coincident hit; ordinary movement casts and public query tie rules remain
unchanged. An earlier non-walkable obstruction still stops the probe. This is not permission
to step onto a steep ramp or to select a later, hidden floor.

**Resolution — Step 4 (2026-09-30): complete.** `character.zig` supplies `CharacterConfig`,
`CharacterHandle`, `Character`, `Ground` and `CharacterMove`; `World` owns the character pool
and exposes `addCharacter`, `character` (const inspection), `moveCharacter`, `setCharacterFeet`
and `removeCharacter`. Each character owns one ordinary kinematic capsule body; characters
block through symmetric pair filters, and only the moved character changes. Allocation failure
in the character pool unwinds its newly created body. Removal retires both handles; stale
characters (including ones whose body was separately removed) cannot move or teleport.

Implementation details that sharpen §7 without changing the architecture:
- Every config field is finite and range-checked; a zero-segment capsule with zero step/snap
  is valid. Feet and centre obey the position envelope. Move-length arithmetic uses `f64` to
  avoid overflow in validation of finite `f32` inputs. Refused moves commit neither pose nor
  ground. Setters/moves retain explicit allocators but steady-state work allocates nothing.
- Depenetration scans every admitted body/triangle for the deepest contact without truncating
  through a fixed output buffer. Equal depths keep body-then-triangle order. Four pushes are
  allowed; `stuck` commits those pushes but performs no requested movement, step or snap and
  reports no ground, so the caller can respawn. No other body is moved.
- Controller casts ignore resting skin contacts only when motion is tangential or separating;
  closing motion still blocks. Public queries retain their existing semantics. Casts already
  stop a skin short, so the controller never subtracts a second skin.
- Slide, step, snap and ground run in the specified order with four slide iterations. Downward
  ground/landing probes apply the edge refinement above, including the same contact-position
  check and box-face witness check. Earlier blockers are never skipped to find a hidden floor.
- Step acceptance bounds both actual feet rise **and the landing witness's surface height**.
  The feet alone can be below a tread at a rounded edge: bounding only them allowed a 0.40 m
  step to be climbed in pieces with a 0.35 m limit. `stepped` reports actual rise in that move;
  a box corner can finish climbing by ordinary walkable slide rather than another step.
- An upward requested displacement neither steps nor snaps. The ground probe does not move
  the character. Hit totals cover slide casts and accepted step/snap casts; discarded step
  candidates and the read-only ground probe do not enter the output buffer.

**Evidence:** seventeen added character tests cover every §11.2 scenario: 30° ascent, 600
ticks against 50°, falling/sliding on 50°, 0.15/0.30/0.40 m steps on boxes and meshes, tread
overhang, descending stairs and a 25° ramp, jump, wall tangent progress and stable corners,
ceiling, box/mesh teleport and sealed-space stuck, maximum-speed casts against a 1 cm box and
two-sided wall from both sides, no pushing, symmetric masks, truncated hits, all config/move
refusals, stale handles, ownership and allocation failures. Additional focused guards cover
coordinate escape, allocation-free movement, hidden floors and a box's unrelated top face.
The 1,200-tick mesh course reproduces every feet byte and its FNV-1a64 hash in a fresh world;
no cross-machine physics hash is pinned.

**Ten mutations fail:** config validation, move cap, walkable-by-`surface_normal`, landing
surface-height cap, jump snap exclusion, symmetric cast filtering, resting tangential-contact
skip, coincident mesh-face selection, box-face witness and feet/centre validation. The
box-witness mutation initially passed because a signed-zero-side fixture selected the bottom
face anyway; moving its witness into the upper half now isolates and fails that guard. All
mutations are restored. **60/60 physics tests** pass in Debug and ReleaseSafe.

The final nine-command bar passes **1,967 of 1,968 tests**, one expected skip: native and Metal
graphs, Linux/Windows cross checks and all three headless samples. `physics3d-test` exposes the
existing module test run as a focused build step, also still included in `test`/`check`. The
module remains on `core` alone. No ABI, asset-kind, sample, platform, renderer or release change;
their conditional proofs are not triggered. Native Windows remains Step 6; Linux compile-only.
Step 5 has not begun.

### Step 5 — `sandbox3d` walks, on Metal — Done 2026-09-30

**Implementation refinement (2026-09-30, before the fix):** the real multi-step course
exposed a resting riser/tread edge that blocked further horizontal movement. The earlier
Step 4 rule restricted coincident-face preference to ground/landing probes; that is too narrow.
Controller movement casts may also prefer a coincident walkable face, **only when the contact
normal itself meets the slope threshold**. This lets a capsule already resting on a tread
continue, without reclassifying the low, tilted first contact with its riser. Same-body,
same-time and same-witness tests still apply, and earlier blockers are never skipped. Public
queries retain their triangle tie order. A multi-riser regression and the package tour prove
the correction; the architecture, skin, slope limit and step-height limit do not change.

This step implements §10:
- the `walk` schema and record, and the course from `make_scene.py`;
- the room's and the course's collision;
- walking and looking, F3, gravity, respawn, reload and the profiler zone;
- `tour.zig`, and the tour as a `sandbox3d-test` test.

It pins the course's coordinates in the Resolution, runs the tour windowed on Metal from a
relocated ReleaseSafe install, exercises the hand checks, and records the cost and both staged
releases. **Exit:** the tour logs `tour: pass` headless in `zig build test` and windowed on Metal,
with the dusk mod both off and on.

**Resolution — Step 5 (2026-09-30): complete.** Codex wrote most of this step and ran out
before finishing it. Claude found a failing test, fixed it, measured the cost and ran the Metal
runs, and records all of it here. The sample now walks. `walk.zig` owns a `physics3d.World`,
one character, and the copied collision of every record the walk names. `walk_settings.zig`
reads and validates `sandbox3d:walk.main`, and `tour.zig` is the scripted tour. `main.zig`
does the following:
- adds F3, WASD, the arrow keys, right-mouse look, gravity and the respawn below −10 m;
- adds the `character` profiler zone;
- draws the course model;
- runs a fixed step when the tour is asked for headless.

`walk_tests.zig` runs the tour against the sample's **compiled package**, with the loader
reading the `.fcol` files the build generated. No course is recreated by hand, so the test
proves the whole path from package to controller.

**The course, pinned** (`make_scene.py`'s `course()`; `room.gltf` and `crate.gltf` bytes
unchanged):
- **Steps:** x ∈ [−1.8, −0.8]. Step i (0–3) has its tread top at 0.15·(i+1) m, from
  z = −0.4 − 0.3·i to −0.7 − 0.3·i. Each riser is authored before its tread.
- **Platform:** top at y 0.6 over x [−1.8, −0.8], z [−1.6, −2.6], with side and north faces.
- **Gentle ramp:** 25°, 1 m wide about z = −2.1. It leaves the platform's east edge
  (x −0.8, y 0.6) and meets the floor at x ≈ 0.487.
- **Steep ramp:** 55°, 1 m wide about z = −0.7. It rises west from x ≈ −2.48 to x −2.9, y 0.6,
  against the west wall at x −3.
- **Both ramps** are 4 cm-thick rotated boxes whose undersides pass below the floor.
- **Collision:** the room's import sets `collision true` and `collision_exclude ["Plant"]`; the
  course sets `collision true`. The walk lists both collision records.
- **The walk record:** as in §10.1, with a spawn at (1.1, 0.004, 2.5), yaw 0, turn rate
  1.5 rad/s and look rate 0.004 rad per point.

**The tour, pinned.** Each stage starts with a teleport and one settling tick; after that,
movement comes only from `Walk.step`. Starts, directions and ticks at 60 Hz:

| Stage | Start | Direction | Ticks |
| --- | --- | --- | --- |
| Floor | (1.1, skin, 2.5) | (0, 0, −1) | 80 |
| Steps | (−1.3, skin, 0.1) | (0, 0, −0.4) | 130 |
| Ramp | (−1.1, 0.6 + skin, −2.1) | (1, 0, 0) | 40 |
| Steep slope | (−2.0, skin, −0.7) | (−1, 0, 0) | 120 |
| Wall slide | (−0.3, 0.65, −2.65) | (0.2, 0, −0.3464) | 120 |

The steps and wall-slide stages walk at 0.4 of full speed. The wall slide's direction is 30° off
the north wall's normal. Every §10.5 check is as written:
- **Floor:** it ends at feet (1.1, 0.005, −1.5) after crossing the floor's diagonal seam.
- **Steps:** at least four stepped moves, ending at y 0.605.
- **Ramp:** it snaps down to the floor.
- **Steep slope:** the feet never rise, and it ends at x −2.3211.
- **Wall slide:** 100% of the tangential progress asked for, ending at z −2.695.
- **Replay:** 495 ticks with hash `cb99ccfcf2b6d6c3`. Every tick's feet bytes equal a fresh
  world's, on null and on Metal, with and without dusk.

**Where the implementation sharpened §10:**
- **Movement casts also prefer a coincident walkable face** (the refinement above). Codex found
  this on the course's successive risers. **Mutation:** reverting it fails the package tour
  (`tour: FAIL steps` at y 0.455). The multi-riser `physics3d` unit test added with it still
  passes under that mutation, so it does not isolate the guard. The tour, which is in
  `zig build test`, is the evidence. Making the unit test isolate the guard is a Step 6 or
  Step 7 loose end.
- **Reload re-adds every listed collision on any content change**, not only a changed record.
  The result is the same, the code is simpler, and an unchanged character is not teleported.
  The package test proves the following:
  - residency is replaced;
  - a real source edit raising the course by 0.1 m depenetrates the next tick onto it;
  - a missing named record is left out with a warning;
  - a missing walk record retires the character and returns to orbit.
- **A valid walk record requires every field present.** The missing-field and non-finite
  refusals cover all fields, including formerly defaulted ones. Also refused: empty,
  over-long and duplicate collision lists, and an eye above the height. **Mutations:**
  accepting duplicates, and dropping the eye bound, each failed the settings test and were
  restored.
- **Headless tours advance the null clock by the fixed step**, so each frame is one tick. A
  consequence: on null the profiler's `character` span reads 0. The sample therefore times
  moves itself with the monotonic clock, for measurement only; the time never enters the
  simulation.
- **A test fix:** the reload test addressed the walk's `collision` field by a hard-coded
  index, 16. The field is 14, and the null field crashed the test after the tour had already
  passed. It now looks the field up by name. `build.zig` also finds the sandbox3d package by
  its stem, not by its position.

**Runs on macOS/Metal (Apple M5):** relocated ReleaseSafe install, launched from outside the
repository.
- `tour: pass` with the base content, and with `dusk:content` enabled from user storage. Both
  exit 0 with the same replay hash.
- A scripted F3 at frame 150 switched walk to orbit, and the run exited 0.
- **What was not done by a person:** walking with WASD, mouse look, a visual look at the
  course, and a hand-made live reload. The owner can check these; the automated F3, tour and
  package reload stand in for them here.

**Cost (§11.4), measured, ReleaseSafe:**
- **Unpaced moves**, the tour's replay run back to back inside the same windowed process:
  median **0.082 ms**, p95 **0.139 ms** in both runs. On null, headless: 0.052 ms and
  0.093 ms.
- **Paced moves**, inside the windowed 60 Hz frame loop: median **0.15 ms**, p95
  **0.30–0.32 ms**. That is over the 0.25 ms budget.
- **The difference is the CPU's clock state, not the algorithm.** It is the same 495 moves,
  with the same work and the same answers, in the same process: between paced frames the CPU
  has clocked down.
- **So the §15 trigger was not acted on.** It asks for a profile showing GJK as a move's cost
  above budget, and the unpaced p95 is about half the budget. Whether the budget means paced
  or unpaced time is put to the owner, not decided here.
- One counting run found about 160 separations and 110 casts per move across both runs. Part
  of this is repeated, identical queries: the overlap scan runs twice when nothing overlaps,
  and the ground probe runs twice when no snap happens. Removing them would not change an
  answer. It was not done in this step.
- The PC's figures are Step 6's.

**Bar and proofs:** both ad-hoc macOS releases (room, sandbox) stage. `sandbox3d-test`
passes 14 of 14 and `physics3d-test` 61 of 61. The nine-command bar passes **1,971 of 1,972
tests**, one expected skip: four more than Step 4, which are the riser test, the input test and
the two package tests. The native, Metal and both cross checks pass, as do all three headless
samples. There is no ABI change, and the overlay is not granted `physics3d`. The
Windows runtime is Step 6; Linux is compile-only.

### Step 6 — Windows/Vulkan on the PC — Done 2026-10-01

This step runs, on x86_64 Windows:
- the `physics3d` suite, the asset and import tests, and `sandbox3d-test`, natively;
- the tour windowed on Vulkan from a relocated ReleaseSafe install, with validation;
- the recorded cost.

It fixes anything x86_64 shows, and records the evidence and pack-up. **Exit:** every scenario
and the tour pass natively on the PC, with Vulkan validation clean. Replay is byte-identical on
that machine.

**Resolution — Step 6 (2026-10-01): complete.** The pushed Step 5 tree (`8d5a735`) ran natively
on Windows x64, from a clean detached checkout with nothing overlaid: Intel Arc A750, Vulkan
1.4, Zig 0.16.0, LunarG SDK 1.4.357.0. The PC was idle (CPU 15%), and every build used `-j2` at
below-normal priority. **x86_64 showed nothing to fix; no file changed in this step.**

**Native suites, all exit 0:**
- `physics3d-test`: **61 of 61** in Debug and again in ReleaseSafe. That is every §11.1 query
  test, every §11.2 scenario and the 1,200-tick replay.
- `asset-test` 123 of 124 (one skip), `author-test` 88 of 91 (three skips), `sandbox3d-test`
  **14 of 14**, which includes the package tour, its replay and the reload.
- The whole `zig build test` graph, on the default backend (101 steps) and with `-Drhi=vulkan`
  under required validation (192 steps). Their printed totals, 1,677 of 1,682 and 1,437 of
  1,456, leave out the test binaries the focused runs had just cached, so they are not
  comparable with earlier whole-graph counts. The skips are the usual Windows-conditional ones.

**The tour, windowed on Vulkan,** from a ReleaseSafe install moved out of its prefix, started
in the desktop session at normal integrity with Zig and the SDK off `PATH` and `APPDATA` in a
scratch root. Five runs, all exit 0 with `tour: pass` on every stage:
- base and dusk under Khronos validation with synchronization checks: **no error and no
  warning**; the log holds only the layer's own enabled-checks notice, and the loader shows
  only `VK_LAYER_KHRONOS_validation` inserted;
- base twice with no validation;
- dusk with every layer disabled.

**Replay:** byte-identical on that machine in every run, 495 ticks. Its hash,
`cb99ccfcf2b6d6c3`, is also the Mac's. ADR-0013 does not promise that across machines, and
nothing here relies on it. The dusk package built there has the SHA-256 M22 recorded.

**Cost on the PC (§11.4), ReleaseSafe, over ten runs:**
- **Paced moves**, in the 60 Hz frame loop: median **0.071–0.088 ms**, p95 **0.12–0.13 ms**,
  with one run at 0.20 ms. Every run is under the 0.25 ms budget.
- **Unpaced moves**, the replay: median 0.058–0.068 ms, p95 0.106–0.115 ms.
- So the PC meets the budget either way it is read. The Mac's paced p95 (0.30–0.32 ms)
  remains over it and its unpaced p95 (0.139 ms) under; the reading stays the owner's call,
  and the §15 trigger stays unacted on.

**Still not done by a person:** walking, looking and a live reload by hand (§11.4), on either
machine. **Pack-up:** the install, logs, scripts and the scheduled task are removed from the
PC; its checkout is left clean at `8d5a735`. Linux stays compile-only.

### Step 7 — Close M23 — Done 2026-10-01

This step:
- reconciles the parent documents:
  - `3d.md` §8, whose collision asset "derives from a mesh or authors separately": M23 derives
    it from a model import only;
  - `3d.md` §8's trigger sentence, which layers now express;
  - `3d.md` §10's M23 row, with "on every backend" read as §1 reads it;
  - CLAUDE.md §4.3's layer table, gaining `physics3d` at L1;
  - ADR-0055, by an append-only note on the `collision` segment, since it is accepted and
    implemented;
- moves ADR-0057 to Accepted and into CLAUDE.md §4.1, and updates §9's 3D row;
- updates the roadmap, the design index and `PROJECT_STATE.md`;
- runs the bar, and tags `m23`.

It pushes only when asked, and stops before M24's design. **Exit:** every document names M23
complete, and nothing names a contract the code does not have.

**Resolution — Step 7 (2026-10-01): complete.** M23 is closed at tag `m23`.

**Two loose ends from Step 5 were finished first,** because the owner asked for all pending
work:
- **The riser unit test now isolates its guard.** Step 5 recorded that Codex's multi-riser
  test passed with the movement-cast refinement reverted. It is rewritten on the course's own
  stairs (risers listed before treads, side walls, climbed toward −Z under gravity at the
  tour's speed). Reverting the refinement now fails it, 60 of 61, and the guard is restored.
- **A move no longer repeats two identical queries.** The overlap scan is not run a second
  time when the first found nothing, and the final ground probe reuses the snap check's when
  the feet did not move after it. No answer changes: every physics test passes, and the tour's
  replay hash is still `cb99ccfcf2b6d6c3` on both machines.

**Cost after that change (§11.4), ReleaseSafe, relocated installs:**

| | Paced, in the 60 Hz frame loop | Unpaced, the replay |
| --- | --- | --- |
| Mac, Metal, three runs | median 0.095–0.112 ms, p95 **0.243–0.254 ms** | median 0.048–0.053 ms, p95 0.068–0.087 ms |
| PC, Vulkan, five runs | median 0.059–0.061 ms, p95 **0.100–0.128 ms** | median 0.046–0.050 ms, p95 0.086–0.089 ms |

The PC is under the 0.25 ms budget on every reading. The Mac's paced p95 came down from
0.30–0.32 ms to the budget line: one run under it and two a few microseconds over. Its unpaced
p95 is about a third of the budget. **Whether the budget is read paced or unpaced is still the
owner's call**; the §15 trigger for specialised pair routines stays unacted on, since GJK is
not what the paced figure measures.

**The PC ran the changed controller too:** `physics3d-test` 61 of 61 in Debug and ReleaseSafe,
`sandbox3d-test` 14 of 14, and the five-run windowed Vulkan tour from a fresh relocated
install, all exit 0, validation with no error or warning. The two files were overlaid on the
clean checkout with matching SHA-256 and restored afterwards; the PC is packed up again.

**Documents reconciled:**
- `3d.md` §8 says collision derives from a model import (ADR-0057), not "from a mesh or
  authored separately", and that triggers are overlap queries filtered by layers.
- `3d.md` §10's M23 row is done, with "on every backend" read as §1 reads it.
- ADR-0055 has a dated note on the `collision` segment; ADR-0051 and ADR-0057 name M23 as
  their implementation.
- CLAUDE.md §4.1 and §9, the roadmap, the design index and `PROJECT_STATE.md` name M23
  complete. CLAUDE.md §4.3 already held `physics3d` at L1.

**What the exit does not include:** nobody has yet walked the room with the keys, looked
with the mouse or reloaded the course live by hand (§11.4's hand check). The scripted tour,
the scripted F3 and the package reload test are what stand in for it. It is recorded as open
in `PROJECT_STATE.md`, not as passed.

**Bar:** the nine commands pass on the Mac after the change: fmt, test, native, Metal and both
cross checks, and the three headless samples. The declared count is unchanged at 1,972 (one
test was rewritten, none added), 1,971 passing with the one expected skip. No ABI change, no
overlay grant, no new dependency. Linux is compile-only.

**Owner's answers after the close (2026-10-01), appended; nothing above is changed.**
- **The budget is read inside the paced frame loop.** On that reading the PC is well under
  0.25 ms (p95 0.10–0.13 ms) and the Mac sits on the line (p95 0.243–0.254 ms: one run under,
  two a few microseconds over). So §15's trigger for specialised pair routines is at its
  threshold on the Mac, not clearly past it. Nothing was started; whether to schedule that work
  is still the owner's decision.
- **The hand check:** the owner walked with the keys and saw it work. Mouse look and a live
  reload by hand were not mentioned, and stay unrecorded.

## 15. What stays open, deliberately

| Deferred | Returns when |
| --- | --- |
| Rigid-body dynamics, stacking, joints, ragdolls, vehicles | A game needs a simulated object (ADR-0051; Jolt weighed then) |
| Moving platforms carrying a character; characters pushing | A game needs either (ADR-0051) |
| Pointer capture (relative mouse) in `platform` | M26's playable sample, or any sample a person plays with the mouse, with its Linux run |
| Collision authored separately from the visual model (a proxy import, or deriving from a `foundry:mesh`) | A model whose render mesh is measured too dense to collide against within §11.4's budget, or an author asks for a simpler proxy |
| A model record that names its collision | A game needs to find a model's collision from the model alone |
| Runtime scale of collision geometry | A game scales a collidable model at runtime |
| The BVH baked into `.fcol` | `addMesh` measured above 5 ms on a shipped level |
| A broadphase over bodies | A query measured over budget at a body count a game has |
| Specialised pair routines (analytic capsule–triangle) | A profile shows GJK as the cost of a move above §11.4's budget |
| Hull faces, hull assets | A game stands characters on hulls, or content needs hulls |
| One-sided triangles | A measured need, such as a one-way wall |
| Per-triangle surface ids (footsteps, friction) | A game needs a surface type from a hit |
| Rotational sweeps | A game rotates a box through geometry and needs the hit |
| Configurable up axis | A game with gravity other than −Y |
| Heightfield terrain | A game with terrain a mesh is measured too large for |
| A physics panel in the overlay | Debugging a game's collision needs one, and `debug` is granted `physics3d` by the owner's decision |
| Jump in the sample | M26, which is the sample a person plays |

## 16. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | "On every backend" means the same tour passes headless on null, windowed on Metal, and natively and windowed on Windows/Vulkan; Linux compiles. This reads `3d.md` §10's row, which Step 7 reconciles | §1, §11.4 |
| 2 | `physics3d` at L1 on `core` alone, granted only to `sandbox3d`; it shares no code with `physics2d` | §3 |
| 3 | Bodies are static or kinematic, and there is no trigger kind: a trigger is a body on a layer the character's mask omits | §3 |
| 4 | Poses are rigid, with no scale; positions are bounded to ±8,192 m for `f32` precision | §3 |
| 5 | Hulls and meshes are world-owned handles, copied at add; a body cannot hold a slice (I1) | §4, §6 |
| 6 | Every shape is a convex core plus a radius, and one narrowphase serves every pair: GJK, conservative advancement and EPA, with fixed budgets | §4, §5.1 |
| 7 | Hulls are point sets with no faces in M23, so a hull's `surface_normal` is its contact normal | §4, §5.3 |
| 8 | `contact_skin` is 5 mm, and it and every iteration budget are interface constants | §5.1, §5.2 |
| 9 | Hits report `surface_normal`, and walkability is judged by it, so stair edges stay walkable | §5.3, §7.2 |
| 10 | Triangles are two-sided | §6 |
| 11 | There is no body broadphase yet: a linear scan in handle order, with a BVH per mesh | §6 |
| 12 | The character has no default gameplay dimensions (I5); its position is its feet; up is +Y | §7.1, §7.2 |
| 13 | The controller's order: depenetrate, then slide, then step up only onto walkable ground, then snap down, then ground; a non-walkable contact never lifts; `stuck` stops the move | §7.2, §7.4 |
| 14 | Characters block and never push; a move changes only the character moved | §7.6 |
| 15 | ADR-0057: `foundry:collision_mesh` and `.fcol` version 1 in `asset`; derived as `<model>.collision` by `foundry:model_import` version 2's `collision` (default false) and `collision_exclude` by node name, where a name matching nothing is refused; nothing is excluded by inference. This corrects `3d.md` §8's "or authors separately", which is postponed | §8, §9 |
| 16 | The walk is its own `sandbox3d:walk` record, so the whole-record dusk override is unchanged and still walks | §10.1 |
| 17 | The course is a new `course.gltf`, leaving the room's and the crate's bytes and pins untouched; the plant is excluded by name | §10.2 |
| 18 | Look by the arrow keys and a held right mouse button; pointer capture is deferred to M26, keeping Linux compile-only | §10.3, §13 |
| 19 | WASD is ignored while an overlay text field has focus | §10.3 |
| 20 | No physics output hash is pinned; replay is byte-exact in-process; the `.fcol` writer is pinned | §11.3 |
| 21 | Budget: a character move at p95 under 0.25 ms at ReleaseSafe, recorded on both machines | §11.4 |
| 22 | Nothing enters the ABI; the overlay gains nothing, since `debug` is not granted `physics3d` | §12 |

Once these are accepted, nothing blocks Step 1.
