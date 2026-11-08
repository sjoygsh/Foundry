# Design: M37 — Character and collision extras: moving platforms, pushing, surfaces, one-sided faces, rotational sweeps, runtime scale, proxies and the up axis

**Status:** Proposed 2026-11-09; awaiting the owner's acceptance of §17. No step has begun.
**Date:** 2026-11-09
**Baseline:** `6058f66`, tag `m36`. M0–M36 are complete.
**Decisions:**
- ADR-0051 (3D collision, queries and a character controller, no dynamics) and ADR-0057 (collision
  geometry is compiled content, copied into `physics3d`, rigid poses) are the contracts this
  milestone extends. Each names its own items as revisit triggers, and M37 is those triggers'
  milestone. ADR-0013 (deterministic-friendly), ADR-0048 (+Y up, metres, radians), ADR-0055
  (imports compile to records) and ADR-0059 (the public 3D table, frozen at v6) constrain it.
- Proposed [ADR-0075](../adr/0075-platforms-and-pushing-without-dynamics.md): a kinematic body
  moved by the game records its motion, a character standing on it is carried by that motion,
  and pushing is a bounded, ordered displacement, not a solver.
- Proposed [ADR-0076](../adr/0076-collision-geometry-gains-surfaces-scale-and-proxies.md): `.fcol`
  version 2 carries a surface and a one-sided flag per triangle, a body carries a scale for its
  mesh or hull, a `foundry:collision_import` produces a proxy, and `foundry:model` names its
  collision.

`collision3d.md` is `physics3d`'s document, and its §15 lists every item here with the trigger it
was given in M23. ADR-0060 scheduled them all in M37. Its rule 17 means each is built here, or
named by the milestone that owns it.

## 1. Purpose and boundary

The roadmap's row is the contract:

> **M37 — Character and collision extras.** Moving platforms, pushing, surface types, one-sided
> triangles, rotational sweeps, runtime scale, collision proxies; also a configurable up axis, and
> a model record that names its collision.

**The runnable result.** `sandbox3d`'s course gains a corner of its own, reached from the floor:
- a lift the player rides from the floor to the platform;
- a turntable that turns the player with it;
- a crate the player pushes;
- a door that swings shut until it meets the player and stops;
- a one-way ledge to jump up through and stand on;
- a rock drawn dense and collided as a simple proxy, its model naming that collision, and placed
  at 1.5 times its size, solid at that size.

The overlay's walk line names the surface under the player's feet. The tour gains stages for each,
and a tilted tour runs the whole course with its up axis turned away from +Y. In the court, every
footstep, the player's and the warden's, sounds by the surface it lands on.

**The exit condition:**
- every item above is shown in `sandbox3d` and passes its tour stage on Metal and on Windows/Vulkan;
- the tilted tour reproduces the upright one in the tilted frame;
- the court's four body digests keep every tick while its footsteps change by surface;
- the player's, the walker's, the pacer's and the navigation pins hold, since nothing old moved;
- the character controller's move stays inside M23's budget (§16).

**In M37:**
- `physics3d`: the up axis, body scale, rotational sweeps, surfaces and one-sided triangles,
  moving bodies that carry, and pushing;
- `asset`: `.fcol` version 2, `foundry:model` version 3 and the `foundry:collision_import` schema;
- `author`: surfaces and one-sided faces derived at import, the proxy import, and a model that
  names its collision;
- the two samples;
- the Windows run and the close.

**Not in M37, and whose it is:**
- Rigid-body dynamics, stacking, joints, ragdolls and vehicles are M51–M55's (ADR-0051's first
  revisit). Pushing here is the bounded kind with no mass or momentum, and §8 says where it stops.
- Heightfield collision is M63's (Terrain II).
- The BVH baked into `.fcol`, a broadphase over bodies, hull assets, specialised pair routines and
  a physics panel in the overlay are M38's (Collision at scale), the next milestone.
- Publishing any of this through the C ABI is M48's (§15).

## 2. What exists

**`physics3d`** (`engine/src/physics3d/`, L1 on `core`, ADR-0051):
- `world.zig`: `World`, with bodies, hulls, meshes and characters in generational pools.
  - **Queries:** `raycast`, `shapeCast`, `overlap` and `contacts`, which scan bodies in handle
    order. The internal `earliestPair` drives the character's casts.
  - **What a hit reports:** fraction, point, normal, `surface_normal`, body, user and triangle.
- `body.zig`: `Body` has a shape, a rigid `Pose`, a kind (`static` or `kinematic`, both solid), a
  layer and mask, and a `user`.
  - **How a body moves:** `World.setPose` teleports it. It records nothing about the motion.
- `shape.zig`: sphere, capsule, box, hull and mesh shapes. Poses are rigid, as ADR-0057 says.
  `Convex` is the one form the narrowphase sees.
- `mesh.zig`: a static triangle mesh, its positions and indices copied, with a deterministic BVH.
  `Mesh.candidates` answers the triangles near an area.
- `character.zig`: a capsule controller with collide-and-slide (four iterations),
  depenetration, ground, maximum slope, step-up, snap-down and ceilings. Its body is kinematic, and
  `move` is allocation-free. **+Y is hard-coded** in every walkable test, in `horizontal()`, in the
  step's rise, the snap and the ceiling, and in `earliestPair`'s box-face choice.
- `gjk.zig` and `narrow.zig`: one rounded-core GJK/EPA for every pair, with `cast` (a translation)
  and `separation`. There is no rotation in any cast.

**`asset`:**
- `collision_mesh.zig`: `.fcol` version 1, `FCOL`. It holds positions and 32-bit indices and
  nothing per triangle. `View.copy` hands them to `World.addMesh`.
- `schemas.zig`: `foundry:collision_mesh` (one field, `source`) and `foundry:model` version 2
  (slots, parts, skeleton and clips). The model knows nothing of its collision.

**`author`** (`gltf/translate.zig`, `compiler.zig`): `foundry:model_import` version 2's
`collision true` derives `<model>.collision` from every node not in `collision_exclude`, with its
whole matrix baked, scale included. An exclusion that names no node is refused.

**The samples:**
- `sandbox3d/walk.zig` loads the course's collision into the walk world. `props.zig` refuses a
  scaled prop that has collision, with `ScaledCollision`. `nav.zig` gathers the course and props
  as navigation sources.
- `court/walk.zig` and `court/gate.zig`: the gate is a kinematic box moved by `setPose`. A
  character it moves into depenetrates on that character's next move. Nothing carries a character.
- `court/sounds.zig` plays one footstep sound for the player, from the walk's step events, and one
  for the warden, from its clip's footfalls.

**The public table** (`foundry.h`, v6, frozen at 261 calls): `physics3d_raycast`, shape cast,
overlap and bodies. Hits carry `triangle`. Nothing here changes it (§15).

## 3. The up axis (`physics3d`)

**A world has an up, and its controller uses it.** `World.up` is a unit vector, `+Y` by default,
set by `World.setUp(up)` while the world holds no character. It is refused (`CharactersPresent`,
`InvalidUp`) otherwise.

**What changes:**
- **Walkability:** a hit is walkable when `surface_normal · up ≥ cos(max_slope)`.
- **Horizontal** is `v − up·(v·up)`.
- **Step-up and snap** go along `up`, and a ceiling is a normal with `normal · up < 0`.
- **`earliestPair`'s box-face choice** compares faces with `up`, not `.y`.
- **The capsule stands along `up`:** the character's body pose is rotated from +Y to `up`.

**Gravity is still the game's** (ADR-0051). A game with gravity along −`up` passes a displacement
that says so. The court and the sandbox keep +Y.

**Why one up per world, not per character.** A world whose up is not +Y is a level built on a
tilted frame, or a ship, or a planet's patch. A character walking on walls needs an up that changes
with every step it takes, and that is a different controller, not a field. Rendering's +Y
(ADR-0048) is untouched: this is the controller's notion of up, not the engine's convention.

**The proof:** the whole course, rotated by a fixed tilt, with `up` turned the same way and the
tour's inputs rotated with it. Every stage passes, and every feet position, rotated back, is within
0.1 mm of the upright tour's.

## 4. Runtime scale (`physics3d`)

**A body carries a scale, for the shapes that need one.**
- **`Body.scale`** is a `Vec3`, (1, 1, 1) by default, and it applies to `mesh` and `hull` shapes.
  It is non-uniform, positive and finite, and each axis lies within [0.01, 100].
- **Other shapes** refuse any scale but one, since a box, a sphere and a capsule already say their
  size, and a second way to say it would be one too many.
- **The pose stays rigid,** as ADR-0057 said, and scale is applied first, then the pose. Mirroring,
  a negative scale, is refused: it turns a triangle's winding over, and §6's one-sided faces would
  face the wrong way.
- **`World.setScale(handle, scale)`** changes it, refused for a shape it does not apply to.

**How a query sees a scaled body:**
- **Mesh triangles** are scaled, then posed, when they become candidates. `Mesh.candidates`
  receives the area in mesh space, mapped through the inverse of the scaled pose; for a scaled and
  rotated mesh that is the bounds of the area's corners.
- **Hull points** are scaled into the `Convex` the narrowphase sees. A hull shared by two bodies
  at two scales is one hull.
- **Normals** come from the scaled triangle, so a flattened ramp is a shallower slope, which is
  what a person sees.

**Why on the body.** A shared mesh, a plinth placed at twice its size by one prop and at its own
size by another, stays one copy in memory. Baking scale at import, which ADR-0057 does, stays the
way a model's own scale is handled; this is for a game's runtime placement.

**In the sandbox:**
- the corner places its rock at scale 1.5;
- `props.zig` drops `ScaledCollision`, passes a prop's scale to its body, and pre-scales the
  triangles it copies for navigation, since `nav.Source` stays rigid. No prop in today's content is
  both scaled and solid, so no navigation pin moves.

## 5. Rotational sweeps (`physics3d`)

**`World.shapeSweep(shape, from, to, filter) ?Hit`** moves a convex shape from one pose to another,
turning as it goes, and answers the earliest hit.
- **The path:** its position goes linearly, and its rotation by `slerp`, from `from` to `to`. The
  fraction is of that path. A sweep whose two rotations are equal is `shapeCast`.
- **The method: conservative advancement.** At each step the GJK distance `d` to the nearest
  candidate bounds how far the path may advance. No point of the shape moves faster than
  `|Δp| + |θ|·R`, where θ is the rotation's angle and R the farthest the shape reaches from its
  origin. So the path advances `d ÷ (|Δp| + |θ|·R)`.
  - It stops within `cast_tolerance` of contact, after at most 32 advances.
  - It answers the hit at that fraction, with the normal and point of the last separation.
- **Determinism:** candidates are scanned in handle order, and the advance count is fixed, so a
  replay is byte-exact on one machine.
- **What it refuses:** a mesh as the moving shape, as `shapeCast` does. A pose that is not finite.

**Why conservative advancement.** A swept rotating volume has no closed form for GJK. Sampling at
fixed angles misses thin geometry between samples. The bound is cheap, exact in what it promises
(never past a contact), and needs nothing the narrowphase does not already have.

**In the sandbox,** the door is a kinematic box hinged at one edge. Each tick the game asks
`shapeSweep` from the door's pose to the one it wants. It moves it to the hit's fraction, so it
closes until it meets the player and stops there.

## 6. Surfaces and one-sided triangles (`physics3d`)

**A surface is a content ID the game gives meaning to.** `physics3d` stores and reports it, and
interprets nothing: a footstep sound, a friction, a decal are a game's (I5).
- **A mesh's triangles** may each carry a surface and a one-sided flag.
  `World.addMeshWith(positions, indices, .{ .surfaces, .triangle_surfaces, .one_sided })` copies a
  table of up to 65,535 surface IDs and, per triangle, an index into it (or none) and a flag.
  `addMesh` stays, and means no surfaces and two-sided triangles.
- **A body** has a `surface` of its own, none by default: what a crate or a platform is made of.
  A mesh triangle's surface, where it has one, wins over its body's.
- **What reports it:** `Hit`, `RayHit`, `Contact` and the character's `Ground` all gain `surface`,
  so a controller's ground says what the feet stand on.

**A one-sided triangle collides from its front alone.** Its front is the side its winding faces,
counter-clockwise, as glTF's front faces are.
- **A cast or sweep** skips it when the shape moves out through its back (the displacement along
  its normal is positive), or when the shape's centre starts behind its plane.
- **A ray** skips it when the ray's direction runs along its normal.
- **An overlap, a contact and depenetration** skip it when the shape's centre is behind its plane.
- **So a character jumps up through a one-way ledge from below and lands on it from above,** and a
  one-way wall lets it through one way only.

**Why per triangle and not per body.** One imported level holds grass, stone and a one-way ledge
in one mesh. Splitting it into a mesh per surface multiplies bodies and the scan over them.

## 7. Moving platforms (`physics3d`)

**A kinematic body moved by `World.moveBody(handle, pose)` records the motion,** and a character
standing on it is carried by that motion when it next moves (ADR-0075).
- **What `moveBody` keeps:** the body's last motion, from its old pose to its new one, and a serial
  that counts its moves. `setPose` stays a teleport and records no motion, so a body put somewhere
  carries nobody with it.
- **The carry:** at the start of `move`, a character whose ground is a body that has moved since
  the character last moved is carried first.
  - Its feet are taken through the body's motion: rotated about the body's old origin by the
    rotation's part about `up`, then translated.
  - The carry is swept, ignoring the body that carries it, so a character carried into a wall
    slides along it rather than through.
  - Then the requested displacement is moved as before.
- **What the move reports:** `CharacterMove.carried` (the displacement) and `carried_yaw` (the turn
  about `up`), so a game can turn its camera with a turntable.
- **What is not carried:** a body's tilt. Only the rotation about `up` turns a character, since a
  character stands along `up` (§3). A tilting platform tips its rider's feet with the surface,
  through the ground and the slide, not its capsule.

**A body moved into a character pushes it out of the way.**
- After `moveBody`, each character, in handle order, that the body now overlaps is moved by the
  body's motion at that character's centre, through the ordinary controller, so it slides along
  walls.
- If it still overlaps the body, it is reported in `moveBody`'s result as `crushed`.
- The body's move is kept either way: whether a lift reverses on a crushed rider is the game's.

**The order a game runs.** It moves its platforms and doors first, then its characters, each tick.
The sandbox and the court follow it, and `content-mods.md` will say it.

**Why recorded motion and not velocity.** `physics3d` has no time (ADR-0051), so a velocity would
need a `dt` it does not have. The pose a game moved a body to is what the game already says, and
the difference of two poses is the motion.

## 8. Pushing (`physics3d`)

**A body or a character may be pushable,** and a character's move pushes what it walks into
(ADR-0075).
- **What marks it:** `Body.push` and `CharacterConfig.push` are a ratio in [0, 1], 0 by default. 0
  is not pushable, 1 moves as fast as the pusher, and between them it is heavier, so the pusher
  moves at that fraction too.
- **When it pushes:** in `move`, a slide that hits a pushable body or character first pushes it.
  The push is the remaining displacement's horizontal part along the hit's normal, times the
  ratio.
  - **A body** is shape-cast along that push, against everything but the pusher and itself, under
    its own mask, and moved to the cast's fraction. That is a `moveBody`, so a character standing on
    a crate is carried with it.
  - **A character** is moved by its own controller, so it slides along walls and climbs steps.
  - Then the pusher's slide continues against the pushed thing where it now is.
- **One level deep:** a pushed thing pushes nothing in turn. A crate pushed into a second crate
  stops, and so does its pusher.
- **Order:** within one move, pushes happen in the order the slide meets them. Across characters,
  in the order the game moves them.
- **What the move reports:** `CharacterMove.pushed`, the handle of the last thing pushed and how
  far.

**Why bounded.** A chain of pushes, or masses that share momentum, is a solver: ADR-0051's first
revisit, M53's. One ordered push a contact, through queries that already exist, is what a crate, a
shove and a lift need.

## 9. `.fcol` version 2 and the records (`asset`)

**`.fcol` version 2** appends to version 1's header and arrays:
- a surface table: a count, at most 65,535, then that many content-ID hashes (u64);
- per triangle, a u32: a surface index in its low 16 bits (0xFFFF for none), and a one-sided flag
  in bit 16. The other bits must be zero.

**What reading checks:** a version 1 file reads as before, with no surfaces and two-sided
triangles. A version 2 file whose index passes its table, or whose reserved bits are set, is
`Malformed`. `View` gains `surfaces` and `triangle_attributes`, and `copy` copies them.

**`foundry:model` version 3** gains `collision`, an optional ID of a `foundry:collision_mesh`. A
model whose import derives collision names `<model>.collision`. A model whose import names a proxy
names that. A game finds a model's collision from the model alone.

**`foundry:collision_import`** is a build-only authoring record, as `foundry:model_import` is
(ADR-0055). It compiles into the `foundry:collision_mesh` of its own ID:
- `source`: a glTF file;
- `front`: as `model_import`'s;
- `exclude`: node names, as `collision_exclude`;
- `surfaces`: as `model_import`'s below.

It is a proxy: collision authored apart from what is drawn, which ADR-0057's first revisit named "a
new producer of the same record, not a new record".

## 10. Deriving surfaces, one-sided faces and proxies (`author`)

**`foundry:model_import` version 3** gains two fields:
- **`surfaces`**, a list of `{ material "Grass" surface court:surface.grass one_sided false }`.
  Each entry maps a glTF material, by name, to a surface ID and a flag, and every triangle drawn
  with that material takes them. A triangle whose material no entry names has no surface and is
  two-sided.
- **`collision_mesh`**, an optional ID naming a proxy collision. It is refused with
  `collision true`, since a model has one collision.

**What the compiler refuses:**
- a material that names no material in the file;
- a material named twice;
- a surface ID that names no record in the package's view;
- `surfaces` without collision;
- `collision_mesh` that names no `foundry:collision_mesh` or `foundry:collision_import`.

Each is named, as the exclusions are.

**The derived `.fcol` is version 2 only when it has a surface or a one-sided face.** So every
existing model's collision keeps its bytes, and the navigation pins and the court's collision stay
as they are.

## 11. `sandbox3d`

**The corner.** A new area of the course's floor, away from every tour path, the walker's square,
the pacer's square and the crowd's corners, holds §1's pieces:
- **The lift:** a kinematic box moved by `moveBody` between the floor and the platform's height,
  pausing at each end.
- **The turntable:** a kinematic disc, a hull, turned about `up` at a quarter-turn a second.
- **The crate:** a pushable box, ratio 0.5, so it slides at half the player's pace.
- **The door:** a kinematic box hinged at an edge, swung by `shapeSweep` between open and shut, and
  stopped by the player.
- **The ledge:** a one-sided slab, imported with `surfaces`, its front facing up.
- **The rock:** a dense model whose import names a `foundry:collision_import` proxy of a few
  boxes, placed at scale 1.5.

Their surfaces are stone, wood and metal, named by `sandbox3d:surface.*` records, and the overlay
and the walk's log line name the surface under the player.

**What does not move:** the ledge's and the rock's collision join the walk world's own list, not the
navigation recipe's sources or the props, and the moving pieces are bodies the corner makes. None
is a navigation source, and none touches a tour path, so the
player's `cb99ccfcf2b6d6c3`, the walker's `655e865f98779129`, the pacer's pins, the strafer's, and
the navigation and crowd pins hold. The test of that is the pins themselves.

**The tour's new stages,** each with its check:
- **lift:** carried up within 1 cm of the platform's height, `carried` reported;
- **turntable:** a quarter-turn's `carried_yaw` within 1e-3 rad over a second;
- **crate:** pushed 0.5 m at half pace, and stopped against the wall;
- **door:** stopped by the player within `cast_tolerance`, never through;
- **ledge:** a jump from below passes up through it and lands on it;
- **rock:** blocked by the proxy, not by the drawn mesh's every face.

**The tilted tour:** `FOUNDRY_SANDBOX3D_WALK=tilted` runs the tour in a walk world whose geometry
and `up` are turned by a fixed tilt, and compares every tick with the upright tour turned the same
way (§3).

## 12. The court

**Its footsteps sound by surface.**
- **The level:** the court's import gains `surfaces` for its floor, its walls and its steps, so its
  collision becomes version 2. The triangles are unchanged.
- **The records:** `court:surface` records name a step sound each.
- **What plays:** the player's step, which the walk emits on landing and every stride, plays its
  ground's surface's sound. The warden's footfall plays the surface under its controller.
- **What must not move:** `win`, `caught`, `fell` and the soundtrack keep their body digests every
  tick, and the soundtrack's events keep theirs. A surface chooses which sound plays, and nothing
  that moves. The navigation mesh is built from the same triangles, so its pin holds.

**Nothing else in the court changes.** It has no lift, crate or door: the sandbox demonstrates
capability, and the court is a game whose level is its own.

## 13. The order a game runs a world in

Every game that uses these follows one order a tick, and `content-mods.md` will say it:
1. Move kinematic bodies: platforms by `moveBody`, doors by `shapeSweep` then `moveBody`.
2. Move characters, in a fixed order, each carried, pushing, sliding.
3. Read what they stand on: `ground.surface`.

## 14. Platform assessment

- **Metal (the Mac):** the first run of everything.
- **Windows/Vulkan on the PC,** once, at Step 9:
  - the pins on x86_64;
  - the controller's cost on the i3;
  - both samples relocated under validation;
  - no backend, shader or RHI path changes;
  - the PC holds no Foundry clone, so it clones again under the usual rules: idle checked, `-j2`,
    below normal, a scheduled task for windowed runs, and only Foundry's own paths deleted after.
- **Linux: compile only.** Nothing here is Linux-specific (`3d.md` §10.2).

## 15. The public ABI

**Nothing enters the table.** v6 is frozen, and M48 publishes what M27–M47 built: its line gains,
at the close, surfaces in hits, `moveBody` and pushing, `shapeSweep`, and body scale. The API is
still drawn for a table: handles and values, a surface as a content ID, named refusals.

## 16. Verification, pins and budgets

**`physics3d`:**
- **Up:** a world turned by a tilt, with `up` turned alike, reproduces every controller test in
  the turned frame. `setUp` with characters present, and one not unit, is refused.
- **Scale:** a mesh at scale (2, 1, 0.5), queried by ray, cast and contact, matches the same mesh
  baked at that scale, within 1e-5. A negative, zero, non-finite or out-of-range scale is refused,
  and so is any scale but one on a sphere, capsule or box.
- **Sweeps:**
  - a rotating box stops within `cast_tolerance` of a wall it would pass through;
  - a sweep with no turn equals `shapeCast`;
  - a thin pole between two angles is never passed;
  - 32 advances bound the work.
- **Surfaces:**
  - every query reports a triangle's surface, and a body's where its triangle has none;
  - a table past 65,535, or an index past its table, is refused.
- **One-sided faces:**
  - a ray and a cast through the back pass, and through the front hit;
  - a character jumps up through a one-sided slab and lands on it;
  - depenetration ignores a face whose plane the centre is behind.
- **Platforms:**
  - a character on a lift moves with it to within 1e-5;
  - a turntable turns it, and reports `carried_yaw`;
  - a carry into a wall slides;
  - `setPose` carries nobody;
  - a body moved into a character pushes it out, and one that cannot is reported `crushed`.
- **Pushing:**
  - a crate pushed at ratio 0.5 moves half the pusher's displacement;
  - a pushed crate meeting a second crate stops both;
  - a pushed character slides;
  - ratio 0 is a wall;
  - a character standing on a pushed crate is carried.
- **Determinism:** two worlds stepping the same 1,200 ticks of platforms, pushes, sweeps and
  characters are equal byte for byte.

**`asset` and `author`:**
- `.fcol` v1 reads unchanged, and v2 round-trips;
- every refusal of §9 and §10 is named;
- every existing model's collision keeps its bytes;
- `foundry:model` v2 reads under v3 with no collision;
- a proxy import compiles into the named record.

**The samples:**
- every tour stage of §11 passes, and the tilted tour matches the upright one;
- the player's, the walker's, the pacer's, the strafer's, the navigation and the crowd pins hold;
- the court's four body digests hold every tick, and its footsteps change by surface.

**Budgets, p95 in the paced 60 Hz loop at ReleaseSafe, on the Mac and the i3:**

| What | Budget |
| --- | --- |
| `character`: the player's move, carried and pushing (M23's zone) | 0.25 ms |
| The door's `shapeSweep`, one a tick | 0.05 ms |
| `addMesh` of the course with surfaces | 5 ms, ADR-0057's |
| The court's whole game tick | 0.25 ms |

M23's move sat on its line on the Mac, so a reading over it goes in the step's Resolution and to
M100, as M35's and M36's readings did.

**Guards verified by mutation,** each named in its step's Resolution: the up axis in the walkable
test, the scale's inverse in mesh candidates, the sweep's motion bound, the one-sided back test, the
carry's serial, the push ratio, the one-level push, and the surface index check.

## 17. Implementation order — ten bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

### Step 1 — `physics3d`: the up axis

§3: `World.up` and `setUp`, and the controller, `earliestPair` and the capsule's pose along it.
**Exit:** every controller test passes upright and in a tilted world, and `setUp` refuses what it
should.

### Step 2 — `physics3d`: runtime scale and rotational sweeps

§4 and §5: `Body.scale`, `setScale`, scaled mesh candidates and hull points, and `shapeSweep`.
**Exit:** a scaled mesh queries as the baked one does, and a rotating box never passes a wall.

### Step 3 — `physics3d`: surfaces and one-sided triangles

§6: `addMeshWith`, `Body.surface`, surfaces in every hit and the ground, and one-sided faces in every
query and in depenetration. **Exit:** every query reports surfaces, and a character jumps up
through a one-sided slab and stands on it.

### Step 4 — `physics3d`: moving platforms and pushing

§7 and §8: `moveBody`, the carry, `crushed`, pushable bodies and characters, and the 1,200-tick
replay. **Exit:** a character rides a lift and a turntable, pushes a crate, and every replay is
byte-identical.

### Step 5 — `asset`: `.fcol` version 2 and the records

§9: `.fcol` v2, `foundry:model` v3, and the `foundry:collision_import` schema. **Exit:** v1 reads as
before, v2 round-trips, and every refusal is named.

### Step 6 — `author`: surfaces, proxies, and a model that names its collision

§10. **Exit:** a model import with `surfaces` derives v2 collision, a proxy import compiles into its
record, every existing model's collision keeps its bytes, and every refusal names the record.

### Step 7 — `sandbox3d`: the corner, and the tilted tour

§11: the content, the generator for the corner's models, the pieces, the tour's stages, the tilted
tour and the surface in the overlay. **Exit:** from a relocated ReleaseSafe install on Metal, every
stage and the tilted tour pass, and every older pin holds.

### Step 8 — The court: footsteps by surface

§12. **Exit:** the court's footsteps sound by surface, its four body digests keep every tick, and
the owner has played it.

### Step 9 — Windows/Vulkan

§14. **Exit:** every suite and run passes on the PC, and §16's budgets are read there.

### Step 10 — Close M37

This step resolves:
- `collision3d.md` §15's rows for moving platforms and pushing, proxies, a model naming its
  collision, runtime scale, one-sided triangles, surfaces, rotational sweeps and the up axis, by
  dated notes pointing here;
- ADR-0051's "no pushing and carrying platforms" line and ADR-0057's "rigid poses" and "no proxy"
  lines, by dated notes pointing to ADR-0075 and ADR-0076;
- `agents.md` §14's moving-mesh row, by a note that M37's platforms move characters and a moving
  navigation mesh remains a game's;
- CLAUDE.md §4.1's two new rows, and §4.3's `physics3d`, `asset` and `author` lines;
- `docs/modding/content-mods.md`, which gains surfaces, proxies and §13's order;
- the roadmap's M37 line, and M48's;
- AGENTS.md's bar if it changed, the design index, the README and `PROJECT_STATE.md`.

Tag `m37`, push when asked, and stop before M38's design. **Exit:** every document names M37
complete, and none names a contract the code does not have.

## 18. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| Mass, momentum, and chains of pushes | M51, M52 | Rigid bodies and contacts, then stacking: ADR-0051's first revisit. §8's push is the bounded kind |
| Walking on walls: an up that changes with each step | M50 | Its third-person body's; §3's up is one a world |
| A friction or speed a surface sets in the controller | M50 | The controller moves what it is asked, and until then a game scales its own displacement by a surface |
| Heightfield collision | M63 | Terrain II |
| The BVH baked into `.fcol`, a broadphase over bodies, hull assets, specialised pairs, a physics panel | M38 | Collision at scale, the next milestone |
| All of this in the public table, and in Lua | M48, M49 | §15 |

## 19. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | One up per world, set before characters exist; rendering's +Y untouched | §3 |
| 2 | Scale is a body's, for mesh and hull shapes only, non-uniform, positive, 0.01–100; poses stay rigid; mirroring refused, correcting ADR-0057's "collision poses are rigid; scale baked" to "poses rigid, a body may scale its mesh" | §4, ADR-0076 |
| 3 | Rotational sweeps by conservative advancement, linear position and `slerp` rotation, 32 advances | §5 |
| 4 | A surface is a content ID per triangle (or per body), interpreted by the game alone | §6 |
| 5 | One-sided per triangle, front by winding; skipped from behind in every query and in depenetration | §6 |
| 6 | Platforms carry by a body's recorded motion from `moveBody`; `setPose` stays a teleport; the carry is swept; only the turn about up turns a rider | §7, ADR-0075 |
| 7 | A body moved into a character pushes it through its controller, and reports `crushed`; the game decides what a lift does then | §7, ADR-0075 |
| 8 | Pushing is a ratio on a body or a character, one level deep, in slide order; no mass, no chains, correcting ADR-0051's "no pushing" | §8, ADR-0075 |
| 9 | `.fcol` v2: a surface table and a u32 per triangle; derived only when a surface or one-sided face exists, so existing bytes hold | §9, §10 |
| 10 | `foundry:model` v3 names its collision; `foundry:collision_import` is the proxy producer, compiling into the `foundry:collision_mesh` of its own ID | §9, ADR-0076 |
| 11 | `model_import` v3's `surfaces` map glTF materials by name; `collision_mesh` names a proxy and excludes `collision true` | §10 |
| 12 | The sandbox's corner is new, off every tour path and not a navigation source, so every older pin holds | §11 |
| 13 | A tilted tour proves the up axis in a sample, without a level built for it | §11 |
| 14 | The court changes only its footsteps, by surface; its level, its body digests and its navigation pin hold | §12 |
| 15 | Nothing enters the public table; M48's line gains it at the close | §15 |
| 16 | Ten steps, the Windows PC once at Step 9, and the owner's play of the court at Step 8 | §17 |

Nothing blocks Step 1 once these are accepted.
