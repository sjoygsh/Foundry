# Design: M37 — Character and collision extras: moving platforms, pushing, surfaces, one-sided faces, rotational sweeps, runtime scale, proxies and the up axis

**Status:** Accepted 2026-11-09, when the owner asked for Step 1, with §19 as written. **Complete
2026-11-09, tag `m37`.** Each step's Resolution follows §19, and the dated notes below say where the
code sharpened this text.
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

> **2026-11-09, at the close:** the comparison's bound is 5 mm, not 0.1 mm. Floating-point ties
> at thresholds differ in a turned frame (Step 1's Resolution). The sandbox's worst tick was
> 0.1 mm.

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

> **2026-11-09, at the close:** `moveBody` leaves a body's own riders, characters whose ground it
> is, to the carry, so a lift moves its rider once, not twice (Step 4's Resolution).
> `content-mods.md` §9 now gives §13's order.

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

> **2026-11-09, at the close:** only the corner's ground joins the walk world's list. The rock
> cannot, since the list holds no pose or scale. The sample makes its body from the collision its
> model names. The rock stage counts a wall on any tick of the stage, not just its last (Step 7's
> Resolution).

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

> **2026-11-09, at the close:** the court has no steps and two materials, so it has two
> surfaces, paving and stone. Stone is heard on the low wall's top. A `court:surface` names three
> sounds (a stride, a landing and the warden's footfall), not one (Step 8's Resolution).

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

## Resolution — Step 1: the up axis (2026-11-09)

`physics3d` now covers §3:
- **`World.up` and `World.up_rotation`:** the up is +Y and the rotation identity by default.
  `World.setUp` refuses `InvalidUp` (not unit, to `Quat`'s tolerance, or not finite) and
  `CharactersPresent`.
- **The rotation is built with no trigonometry:** `world.rotationTo` uses the half-way quaternion
  from +Y, and straight down is a half turn about +X.
- **The controller measures everything against `up`:** walkable, horizontal, a step's rise, its
  landing and gain, a snap, a ceiling, and a wall's vertical limits.
- **The capsule stands along `up`:** it is posed by `up_rotation`.
- **`earliestPair`'s box-face choice** compares faces with `up`.
- **`walkable` takes the up** as an argument, since nothing outside the module called it.

**A fault the tilt found, fixed in `gjk.zig`.**
- **What it did:** a capsule standing 0.78 m from a vertical triangle, both turned, was read as
  touching it, 0.3 m deep. So the controller depenetrated it by its radius, from nothing.
- **Why:** a segment parallel to a triangle's plane makes a flat Minkowski difference. GJK's
  tetrahedron there is flat but for rounding, and its four faces' signs, which are noise, can all
  agree that the origin is inside. The exactly flat case was already handled.
- **The fix:** a tetrahedron whose six-fold volume is below `flat_volume` (1e-5) of its longest
  edge cubed counts as flat, so it never holds the origin.
- **What it touches:** upright worlds meet the same case wherever a capsule runs parallel to a
  turned face. No existing test, pin or digest moved, and the whole suite is unchanged.

**A correction to §3's proof: within 5 mm, not 0.1 mm.**
- **The scenarios,** each run upright and in a world turned 0.7 rad about (1, 0.3, 0.5) with every
  input turned alike:
  - the 30 and 50 degree slopes;
  - the 15, 30 and 40 cm steps;
  - a step down with a snap and a jump;
  - a wall slide into a corner under a low ceiling, then a teleport into a box;
  - a walk off a mesh drop under gravity;
  - M23's 1,200-tick course.
- **What they agree to:** most within 0.01 mm, and the 1,200-tick course within 0.13 mm.
- **What does not agree exactly:** a decision exactly on a threshold goes by rounding, which a
  tilt changes:
  - a contact on the 45 degree line, which makes the 15 cm step's climb 4 mm apart;
  - a witness on a box's edge between two faces, which flips the ceiling flag with no effect on
    position;
  - one ground probe on the 20 m turned floor box.
- **So the test holds:** every tick's feet within 5 mm, flags differing on under 2% of ticks (32 of
  about 2,600), and every scenario ending in the same state. `stuck` always agrees. That is what a
  tilt can promise; an exact match was not. §11's tilted tour is held to the same.

**Guards verified by mutation,** each failing a test before it was restored:
- walkable read from `.y`;
- `horizontal` dropping `.y`;
- `setUp` without its `CharactersPresent` check;
- the flat-tetrahedron test. It failed only once the riser test replayed the scenario's own moves,
  since the false contact needs the exact pose the walk reaches.

**The bar:** see `PROJECT_STATE.md`. `zig build test` passes 2,876/2,886, with ten skips and
132/132 steps, and three new tests.

## Resolution — Step 2: runtime scale and rotational sweeps (2026-11-09)

`physics3d` now covers §4 and §5; the tests are in `engine/src/physics3d/scale_tests.zig`.

**Scale:**
- **`Body.scale`** is a `Vec3`, one by default. `body.scaleValid` admits each axis in [0.01, 100]
  for a mesh or a hull, and nothing but one for a sphere, a capsule or a box.
- **`World.setScale`** sets it. `addBody` and `setShape` check it too, so a scaled mesh cannot turn
  into a box at that scale.
- **A refused scale is `InvalidShape`:** a shape the body cannot hold at that size. That keeps the
  error sets the ABI translates unchanged, so nothing above `physics3d` moved.
- **Where scale applies:**
  - `Mesh.candidates` takes the scale, and moves its area into the mesh's own, unscaled space after
    the inverse pose;
  - a candidate triangle's vertices are scaled before the pose;
  - `Convex` gains `scale`, which a hull's support and bounds apply;
  - a body's bounds scale its mesh's root box.
- **One hull, two sizes:** a hull shared by bodies at two scales stays one hull. A test holds that.
- **`core`'s `Vec3` gains `mul` and `div`,** component by component.

**Sweeps:** `World.shapeSweep(shape, from, to, filter)`, as §5 has it.
- **The bound:** the turn's angle is bounded as θ ≤ π·√(1 − d²) from the rotations' dot, with no
  inverse trigonometry. `reachOf` is the farthest a shape reaches from its origin.
- **What it stops at:** `contact_skin` short, as `shapeCast` does, after at most
  `max_cast_iterations` advances.
- **A sweep with no turn is `shapeCast`,** which a test holds.

**A sharpening of §5: the path is a chord, not an arc.**
- §5's path lerps the position and slerps the rotation. For a door posed at its centre, that cuts
  across the arc its hinge would trace.
- Over one tick's few degrees the two agree, which is how §11's door swings, a sweep a tick. A
  sweep across a quarter turn checks its stopping pose on its own path.

**What the tests hold:**
- **A scaled, turned mesh** at (2, 1, 0.5) answers 24 rays, 24 sphere casts and a box's contacts
  as the same mesh baked at that scale, within 1e-5, triangle by triangle.
- **A 400-triangle grid at ten times its size** is found wherever it is drawn.
- **A scaled hull** is its baked copy.
- **Every refusal is named.**
- **The door:** a swinging door stops a skin from a wall, never into it. A 2 cm pole at 45 degrees
  is never passed.
- **Determinism:** two worlds sweeping 64 doors hash alike.

**Guards verified by mutation,** each failing a test before it was restored:
- **The candidates' scale:** the wedge test passed without it, its few large triangles found even
  through the wrong box. The fine-grid test was added for it, and fails.
- the triangles' scale;
- the hull's support scale;
- the unit check on other shapes;
- the sweep's turn in its speed bound.

**The bar:** see `PROJECT_STATE.md`. `zig build test` passes 2,883/2,893, with ten skips and
132/132 steps, and seven new tests.

## Resolution — Step 3: surfaces and one-sided triangles (2026-11-09)

`physics3d` now covers §6; the tests are in `engine/src/physics3d/surface_tests.zig`.

**Surfaces:**
- **A surface is a `core.ContentId`,** `none` by default. `physics3d` already depends on `core`, so
  the type a game passes is the content ID itself and no cast is needed.
- **`World.addMeshWith(gpa, positions, indices, mesh.Attributes)`:**
  - `surfaces` is the table, up to `mesh.max_surfaces` (65,535);
  - `triangle_surfaces` gives a u16 per triangle, an index into the table or `mesh.no_surface`
    (0xFFFF);
  - `one_sided` gives a bool per triangle;
  - each per-triangle slice is empty (none) or one entry a triangle.
  Anything else is `InvalidMesh`, before allocating, as `addMesh`'s refusals are. `addMesh` is
  `addMeshWith` with no attributes, so a plain mesh stores three empty slices. `.fcol` v2's packed
  u32 (Step 5) unpacks into these two slices, so the format does not leak into `physics3d`.
- **`Body.surface`,** and `World.setSurface` to change it, as every other field has a setter.
- **What reports it:** `Hit`, `RayHit`, `Contact` and `Ground`, as §6 lists, and also `Overlap`,
  so every query does. A triangle's own surface wins, and its body's applies where it has none.

**One-sided triangles,** as §6 has them, judged per candidate triangle. Its front is the winding's
cross product after scale and pose, so a body turned over faces the other way.
- **Casts, and the controller's casts and probes:** a triangle is skipped when the shape's origin
  starts behind its plane, or when the displacement runs along its front.
- **A ray** is a cast of a point, so the same rule is §6's ray rule.
- **A sweep** judges it against its whole travel, with the origin at each advance.
- **Overlap, contacts and the controller's depenetration:** a triangle is skipped when the origin is
  behind the plane.

**A sharpening of §6: a one-sided face is left by its front.**
- **The problem:** a capsule half through a one-way ledge, its centre just past the plane, is
  nearly as deep one way as the other. GJK/EPA's shortest way out of a face with no thickness then
  pointed down through the back about as often as up. The first jump test hovered at the plane: it
  was pushed down, cast up through the back, and pushed down again.
- **The answer:** a contact with a one-sided triangle has the front as its normal, and as its depth
  how far the shape's deepest point lies behind the plane. So a character that rises through a
  ledge until its centre passes the plane is lifted onto it, which is how a one-way platform is
  expected to behave.
- **A cost:** near an edge, a shape is no longer pushed out sideways, since sideways may be
  shorter. A character beside the edge whose centre has crossed the plane is lifted, not shoved off.

**What the tests hold:**
- **Surfaces:** a ray, a cast, a sweep, contacts and overlap each report a triangle's surface, and
  the body's on the triangle with none. A box's comes from its body, and a character's ground says
  what it stands on. A mesh with no attributes reports none.
- **Refusals:** a table of 65,536 is refused, and one of 65,535 is admitted, its last index
  reaching its last entry. Also refused: an index past the table, a table missing, and either slice
  of the wrong length.
- **One-sided:**
  - a ray, a cast and a sweep through the back pass, and through the front hit;
  - a pole whose centre starts in front, rising into the edge from under it, passes;
  - a turned body faces the other way;
  - contacts and overlap ignore a face the centre is behind, and push out along the front by the
    depth behind it, 1.15 m for a pole whose way out through the back is shorter;
  - a capsule whose head is through a slab from below is left where it is;
  - a character jumps 3.5 m up through a one-sided ledge 2.2 m up, with no ceiling, and comes down
    onto it, its ground the ledge and the ledge's surface, its feet where it jumped. Two-sided, the
    same ledge is a ceiling and it lands on the floor;
  - a one-sided wall lets a character through from behind, and stops it a radius from its front.

**Guards verified by mutation,** each failing a test before it was restored:
- the one-sided back test, both halves:
  - the origin behind the plane;
  - the displacement along the front, which survived until the rising-pole case was added, since
    every cast from behind also started behind;
- the front-only depth, which fails the jump and the contact depths;
- the surface index check;
- the table's cap;
- the body's surface beneath a triangle with none.

**The bar:** see `PROJECT_STATE.md`.

## Resolution — Step 4: moving platforms and pushing (2026-11-09)

`physics3d` now covers §7 and §8; the tests are in `engine/src/physics3d/platform_tests.zig`.

**Platforms:**
- **`World.moveBody(gpa, handle, pose, crushed)`** returns a `BodyMove`:
  - `pushed`, the characters it moved;
  - `crushed`, a `Found` over the caller's buffer of characters it still overlaps;
  - null for a stale handle, and `NotKinematic` or `InvalidPose` refused.
- **What a body keeps:** `Body.motion` (`from`, `to`) and `Body.serial`, which the world keeps and
  `addBody` resets.
- **The carry:** `Character.ground_serial` records the serial a character last took, or found when
  it first stood on the body. A move whose ground body has a newer serial is carried first.
  - It is swept with the carrier ignored, and slid along what it meets.
  - It is reported as `carried` and `carried_yaw`.
  - The turn about `up` is the twist of the motion's rotation, so a tilt carries nothing. The yaw
    comes from `std.math.atan2`, which is Zig's own, so no libm is linked.
- **Only the last motion is carried.** A body moved twice between a rider's moves carries the second
  only; §13's order moves each once a tick.

**Three sharpenings of §7:**
- **`moveBody` leaves its riders alone.** §7 pushes every character the body overlaps. But a lift
  moved up overlaps its rider's feet, and pushing them out there and carrying them at their own
  move would move them twice. So a character whose ground is the body is only carried.
- **A pushed character's move ignores the body moving it.** Otherwise its depenetration and its cast
  would both move it out of the body. It moves by the motion at its centre, so it keeps its gap.
- **`setPose` bumps the serial and records a motion of none.** A teleport after a `moveBody` would
  otherwise leave a stale motion for a rider still owed its carry.

**Pushing:**
- **What marks it:** `Body.push`, in [0, 1] and only on a kinematic body, and `CharacterConfig.push`.
  - An invalid ratio is refused as `InvalidShape` for a body, by `addBody`, `setPush` and
    `setKind`, so no error set the ABI translates changed.
  - For a character it is refused as `InvalidCharacter`.
- **In the slide:** a slide that meets something pushable pushes it once a move. It then casts again
  against it where it now is, and the step's `CharacterMove.pushed` says what was pushed and how
  far.
  - **A body** is cast by `World.pushCast`, symmetric under its own filter, ignoring itself and the
    pusher. It is moved by `moveBodyAlone`, which records the motion and moves no character. That
    is the one-level rule for bodies: its cast stops at a character or a second crate rather than
    moving into it.
  - **A character** is moved by `character.moveWith` with no carry and no push, ignoring the pusher.
    Its own carry stays owed until its own move.
- **`character.moveWith(w, handle, displacement, hits, Options)`** is that move. `move` is it with
  every option on.
- **`controllerCast`, `controllerProbe` and `controllerContact`** take the extra body to ignore.
  `characterCast` and the others keep their signatures.

**What the tests hold:**
- **A lift:**
  - 40 ticks up and 40 down, its rider carried within 1e-5 and its gap to the top held within 1e-5;
  - a second move in the same tick is carried by nothing.
- **A turntable:** a quarter turn over 60 ticks sums `carried_yaw` to π/2 within 1e-3, and takes the
  rider from +x to −z.
- **A tilting deck:** it carries no yaw and no displacement, and leaves the capsule upright.
- **Into a wall:** a deck carrying a rider into a wall leaves it at the wall, slid along it by the
  deck's sideways motion.
- **`setPose`:** it carries nobody, and cancels a carry owed.
- **A ram:** it pushes a standing character by its motion. Pinned against a wall, the character is
  `crushed`, and the ram's move stands. `moveBody`'s refusals and its null for a stale handle are
  also tested.
- **A crate at ratio 0.5:** it moves 0.2 a tick for a pusher asking 0.4, and so does the pusher.
- **Into a second crate:** a crate pushed into a second stops a skin short, and the second never
  moves. At ratio 0 the first is a wall.
- **A pushed character:** it slides along a 45-degree wall. One pushed into a pushable crate
  pushes nothing.
- **A crate's rider:** a character standing on a pushed crate is carried by the crate's motion.
- **Refusals:** each ratio refusal.
- **Determinism:** 1,200 ticks of a lift, a turntable, a door swung by `shapeSweep` then `moveBody`,
  a pushable crate, and four characters hash alike in two worlds, and differ at 1,199.

**Guards verified by mutation,** each failing a test before it was restored:
- **the carry's serial:** carrying every move fails the lift's second move;
- **the push ratio;**
- **the one-level push, both halves:**
  - a pushed character pushing, which survived the wall test until the crate test was added;
  - a pushed body's cast;
- **`moveBody`'s rider skip:** without it the lift's rider is moved twice;
- **the carrier ignored in the carry's sweep;**
- **the twist,** failing the tilting deck;
- **`setPose`'s cancel;**
- **the crushed check.**

**Not measured here:** §16's 0.25 ms move budget, carried and pushing, is read in the sandbox's paced
loop at Step 7, and on the i3 at Step 9.

**The bar:** see `PROJECT_STATE.md`.

## Resolution — Step 5: `.fcol` version 2 and the records (2026-11-09)

`asset` now covers §9. The tests are in `collision_mesh.zig` and `schemas.zig`.

**`.fcol` version 2,** as §9 lays it out, after version 1's header and arrays:
- a u32 count, at most `max_surfaces` (65,535);
- that many content-ID hashes, as little-endian u64s;
- a u32 per triangle: the surface index in bits 0–15, `no_surface` (0xFFFF) for none, and
  `one_sided_bit` (bit 16). `plain_attribute` (0xFFFF) is a version 1 triangle.

**Reading:**
- `format_version` is now 2. `read` accepts 1 and 2, and anything else is `UnsupportedVersion`.
- A version 1 file must end at its indices, so a version 1 header over version 2's tail is
  `Malformed`.
- A version 2 file is `Malformed` when:
  - its count passes the cap;
  - its length is not exactly what the count and triangles say;
  - an index passes its table, or reserved bits (17–31) are set;
  - **a table entry is the absent ID.** §9 did not list this; no compiler emits it, and a table of
    `none` would report nothing.
- `View` gains `surfaces` (`[]align(1) const core.ContentId`) and `triangle_attributes`, empty for
  version 1. `copy` and `CollisionMesh` carry them, with `surfaceOf` and `oneSidedAt`.
- `surfaceIndex` and `oneSided` read an attribute. Converting to `physics3d.mesh.Attributes`'
  u16 and bool slices is the consumer's, above both modules, at Steps 7 and 8.

**Writing:** `writeWith(gpa, positions, indices, Attributes)`.
- It writes version 2 only when there is a surface, or a triangle that is not plain. Otherwise it
  writes version 1, byte for byte `write`'s, whose hash pin holds. So §10's rule, that a derived
  mesh keeps its bytes when it has neither, is the writer's.
- It refuses everything the reader would, as `InvalidMesh`.

**The records:**
- **`foundry:model` is version 3,** gaining an optional `collision` ID at index 4. A model compiled
  against version 2 reads it as absent.
- **`foundry:collision_import` version 1:** `source`, `front` (defaulting to `-z`), `exclude` and
  `surfaces`. A surface entry is `{ material surface one_sided }`, with `one_sided` defaulting to
  false. That type is `schemas.surface_mappings_type`, which `model_import` version 3 will share at
  Step 6.
- **The compiler sees both.** `foundry:collision_import` joins `author`'s `engine_schema_names`,
  so the editor's New Record form can offer it. The compiler's animation test now expects a model
  of the newest version, since every compiled model is version 3. No package pin moved.
- **A new list, `schemas.build_only`.** The proxy is registered by `registerAll` through it, not
  through `kinds`, since no extension derives it. Nor is it in `records`, which are shipped. The
  compiler routes it to the private import package at Step 6. Until then nothing authors one.

**What the tests hold:**
- **The round trip:**
  - version 2 round-trips byte for byte, borrowed from an unaligned start and through `copy`;
  - a plain mesh written by `writeWith` is version 1 with `write`'s pinned hash;
  - a one-sided face alone makes version 2.
- **Refusals:** every read refusal above, every truncation, a trailing byte and every writer
  refusal. The fullest table is admitted, with its last index.
- **The loader** reads version 2 and unwinds every allocation failure.
- **The records:**
  - a model of version 2 reads with no collision, and one of version 3 names it;
  - a proxy record with exclusions and surfaces checks;
  - wrong types in either are refused.

**Guards verified by mutation,** each failing a test before it was restored:
- the reserved bits;
- the index past the table, in reading and in writing;
- the absent ID;
- version 1's exact length;
- the plain mesh written as version 1;
- the table's cap: it survived at first, since a count past it was also a length mismatch, until a
  full table of 65,536 whose file does hold it was added.

**The bar:** see `PROJECT_STATE.md`.

## Resolution — Step 6: surfaces, proxies, and a model that names its collision (2026-11-09)

`author` now covers §10. The code is in `compiler.zig` and `gltf/translate.zig`, with tests in
`compiler.zig` and the one pin in `gltf/root.zig` updated.

**`foundry:model_import` version 3** gains `surfaces` (the shared `surface_mappings_type`) and
`collision_mesh` (an optional ID). A version 2 import reads with neither.

**Deriving surfaces.**
- The surface table lists the surfaces in the order the mappings name them, each once, so two
  materials mapped to one surface share an index.
- Each kept triangle takes the attribute of the glTF material its primitive is drawn with. Submesh i
  is primitive i, as `translateMesh` builds them. A material no mapping names gives the plain
  attribute.
- The `.fcol` is written by `writeWith`. That writes version 1 for a plain mesh, so a model with no
  surfaces keeps its bytes. The test compares it with `write` over the same triangles, and the
  M23 fixture's hash pin `0xc854ac2cc345318d` holds.

**A model names its collision.** A model that derives collision writes `collision <model>.collision`.
One that names a proxy writes `collision <proxy>`. So every derived model's record gains one line,
while its `.fcol` bytes are unchanged. `gltf/root.zig`'s opt-in pin said the old text was a prefix
of the new. It now says that once the one `collision` line is taken out, the text is the old text
followed by the collision record. No package or digest pin moved.

**The proxy.**
- **Routing:** `foundry:collision_import` joins `model_import` in the compiler's private import
  package, so it never reaches an FPK. The test checks the package holds no such record.
- **Compiling:** it compiles through the same translator with `Settings.proxy`. Its meshes are read
  for triangles only. The model walk runs into a buffer that is thrown away, to place the nodes.
  It emits only `foundry:collision_mesh <its ID>`, at `<source stem>/proxy0.fcol`. The file is
  named `proxy` so it never meets a model's `collision0.fcol` from the same glTF.
- **Sharpened:** a proxy's materials need nothing a renderer would, so a lit material without
  NORMAL is accepted. §10 did not say. A proxy exported plain would otherwise have been refused.
- **Claiming:** a proxy claims its glTF, so the file derives no model of its own unless a
  `model_import` names it.

**The refusals.** Each names the record (`model import 'x'` or `collision import 'x'`) and is
tested:
- a mapping whose material is not in the file;
- a material named twice;
- a surface that is no record in the package or its dependencies;
- `surfaces` without `collision true`;
- `collision true` together with `collision_mesh`;
- a `collision_mesh` that names something other than a `foundry:collision_mesh`, or nothing.
- **For a proxy:** a bad `front`, a source that is not a glTF in the package, an `exclude` that
  names no node, and a proxy that derives nothing.
- **Sharpened:** the `collision_exclude` refusal now names its record too. Its old text survives as
  the tail of the new.

**Checking the references.** A surface lives only in `.fcol` bytes, so no checker sees it.
- The surface and `collision_mesh` references are checked after derivation, once every record is in
  the package. So a proxy's compiled record, an authored `.fcol` and a dependency's record all
  count.
- A `collision_mesh` must be a `foundry:collision_mesh`, which a proxy has compiled into by then. A
  surface may be any record.
- The check is skipped when an import has already failed, since its records would be missing for
  that reason alone.

**What the tests hold:**
- one glTF with two primitives, "Grass" and "Stone", makes three products:
  - plain collision, which stays version 1, equal to `write`, and is named by the model;
  - surfaced collision, version 2, with the table in mapping order, a one-sided Grass triangle, and
    the same package bytes on a second compile;
  - a proxy with one surface, loaded through the asset registry, whose triangles report the surface
    and none;
- fourteen refusals, each matched to its text and record.

**Guards verified by mutation,** each failing a test before it was restored:
- the one-sided bit;
- the material-to-attribute mapping;
- the reference check;
- its `foundry:collision_mesh` schema test;
- a proxy's unlit materials;
- surfaces needing collision;
- a material named twice;
- one collision per model;
- the model naming its collision;
- the proxy routed as build-only.

Three of these first broke compilation through unused captures. They were rerun in a form that
compiles.

**The bar:** see `PROJECT_STATE.md`.

## Resolution — Step 7: the corner, and the tilted tour (2026-11-09)

`sandbox3d` now covers §11. The code is `extras.zig` (the pieces), `corner_tour.zig` (the six
stages, the tilt and the comparison), and changes to `walk.zig`, `walk_settings.zig` and
`main.zig`. The content is `content/extras.fdt`, and `walk.main` gains the corner's collision and a
jump. The models are written by `scripts/m37/make_corner.py`, which borrows M20's glTF writer and
writes none of M20's files. The tests are in `extras_tests.zig`.

**The corner** is centred on (−20, 0, 0), west of the room and the crate grid, and far from every
tour path, square, corner and crowd lane:
- **The ground** is `sandbox3d:models.corner`:
  - a stone floor, a metal platform beside the lift, and a metal wall behind the crate;
  - a ledge whose collision is its top quad alone, wood and one-sided, over a slab that
    `collision_exclude` keeps drawn only, since its underside would otherwise be a ceiling.
  Its collision is version 2. It joins `walk.main`'s list, so the walk world holds it, and it is
  neither a navigation source nor a prop.
- **The lift** is a metal box whose top goes from 0.1 m to the platform's 1.0 m. It waits a second
  at each end and takes a second and a half each way.
- **The turntable** is a wooden sixteen-sided hull, turned about `up` a quarter-turn a second,
  counted in whole turns so its angle stays small.
- **The crate** is a wooden box, pushed at 0.5, 1 mm off the floor as Step 4's test had it.
- **The door** is a wooden leaf hinged at its edge, its foot 0.1 m clear of the floor. It swings shut
  for two seconds and open for two, at a quarter-turn a second. Each tick it is swept by
  `shapeSweep` and moved by `moveBody` to where the sweep stopped, so it stops at the player.
- **The rock** is `sandbox3d:models.rock`, 768 triangles drawn. Its import names
  `sandbox3d:models.rock_proxy`, two boxes of 24 triangles. The sample reads the rock's compiled
  `foundry:model` for its `collision` and places that at scale 1.5.

`sandbox3d:extras.main` names the models that draw the pieces, the rock, its place and scale, and
each moving piece's surface. The places and motions are the sample's, as M28's and M29's corners'
are, and repeat the generator's numbers.

**Sharpened, §11's "join the walk world's own list":** the corner's ground joins the list. The rock
cannot, because the list has no pose or scale. So the sample makes the rock's body, in the walk
world, from the collision its model names. Neither is a navigation source or a prop.

**The walk.**
- **Surfaces:** `addCollisionMesh` is the consumer's half of §9, since `asset` cannot see
  `physics3d`. It turns each `.fcol` v2 attribute into a surface index and a one-sided flag for
  `addMeshWith`. Every collision the walk loads, and the rock, goes through it. A v1 mesh gives
  empty attributes, so nothing that was plain changes.
- **The jump:** `walk` gains `jump_speed` (default 0, so older records still read), and `Intent`
  gains `jump`, held on space. A jump leaves only from the ground. `walk.main` sets 4.5 m/s.
- **The turntable turns the view:** the walk adds `carried_yaw` to its yaw.
- **The frame:** `Walk.frame`, identity except in the tilted tour. The world's geometry and `up`
  are turned by it. `teleport`, each move and `result` are in the upright frame, so a tour reads the
  same in either. A world that has a frame sets its `up` before its first character.
- **What is underfoot:** `Walk.surface` is the ground's surface. The overlay draws "on stone" (or
  wood, metal, none) a line above its counts, and the log says "walk: on …" when it changes.

**The order of a tick** is §13's:
- the pieces move first, in their own span, `corner.pieces`;
- then the player.
In the tour, `CornerTour.prepare` moves them and `move` moves the player, so the frame loop times
the player's move alone. The corner's bodies are made last in a refresh, so every body before them
keeps the handle it had.

**The tour.** M23's five stages are unchanged. M37's six follow, once those, the plinth's and the
orbiter's proofs are done. Each begins with the corner set back (`Extras.reset`, by `setPose`,
which carries nobody) and a teleport:
- **lift:** standing on it, carried up for 200 ticks; `carried` was reported, and the feet end
  within 1 cm of 1.0 m;
- **turntable:** standing 0.5 m off its centre; over a second, `carried_yaw` sums to π/2 within
  1e-3;
- **crate:** walking into it toward the wall:
  - it moves at 0.5 of the walk's pace within 1% on at least 15 ticks;
  - it moves at least 0.5 m;
  - it ends still for 20 ticks, its face within 1 cm of the wall's;
- **door:** standing in its swing as it shuts:
  - every tick it never overlaps the player and never moves them by 1 mm;
  - at the end, its last sweep met the player at fraction 0, which is within `cast_tolerance`;
  - it stands more than 0.2 rad open;
- **ledge:** a jump from under it; no ceiling, and landing on it within 1 cm, on wood;
- **rock:** walking at it; blocked, and stopped within 1 cm of the proxy's scaled face plus the
  radius and skin, with its body's mesh 24 triangles.

The feet end each stage at: the platform (1.005 m), the disc (0.105 m), 0.29 m short of the wall
behind the crate, still at the door, the ledge (1.205 m), and 1.99 m along at the rock, each 5 mm up
for the skin.

**Sharpened, the rock's "blocked":** the walls a blocked move reports can be 0 on a tick
where the move is refused outright, so the rock stage counts a wall on any tick of the stage, as M23's
plinth proof counts being held up.

**The tilted tour.** `FOUNDRY_SANDBOX3D_WALK=tilted` is the tour, and then both tours again in a
fresh walk and corner whose frame is Step 1's tilt, 0.7 rad about (1, 0.3, 0.5). Every tick of each
trace is compared with the frame loop's, in the upright frame, within 5 mm, and every stage must
pass in both. The worst ticks were 0.01 mm (M23's) and 0.1 mm (M37's). `extras_tests.zig` holds the
same comparison.

**Pins.** The corner's tour is pinned at `832fe43a3a82db13`. Every older pin holds:
- the player's `cb99ccfcf2b6d6c3`;
- the walker's `655e865f98779129`;
- the pacer's three (`e46c09dc62b1eeac`, `222e0a9b12fd152c`, `47f67027ff3a12b0`);
- the strafer's, the navigation and the crowd pins, in the bar's tests.
`walk_tests.zig`'s count of the walk's collisions is three, not two.

**Guards verified by mutation,** each failing a test before it was restored:
- the one-sided flag, and the surface index, in `addCollisionMesh`;
- the frame turned back in `Walk.step`, and the tilted world's `up` (the tilted test);
- the door moved only as far as its sweep allows;
- the rock's scale;
- the jump;
- the turntable's rate (its quarter-turn check);
- the crate's push ratio.

**From the relocated ReleaseSafe install on Metal,** windowed:
- **The tour:** M23's five, M37's six and the corner's replay pass. The corner tour's hash is
  `832fe43a3a82db13`. The player's, the walker's and the pacer's three pins hold.
- **The tilted tour (`FOUNDRY_SANDBOX3D_WALK=tilted`):** it passes, worst 0.01 mm and 0.1 mm from
  upright.

**Budgets, p95 in the paced 60 Hz loop:**
- **The player's move:** 0.231 ms and 0.233 ms over 1,300 moves, both tours, carried and pushing,
  against 0.25 ms. The frame pacing was a median of 16.67 ms.
- **The door's sweep:** 0.014 ms against 0.05 ms.
- **`addMesh` with surfaces, and the court's tick,** are Step 8's, since the court's level is what
  gains surfaces. The corner's ground is a few dozen triangles.

**The bar.** `zig build test`: 2,917/2,927, ten skips, 132/132 steps, with three new tests. Every
check, the four samples and `fdt-check` passed. No release stages `sandbox3d`, and the room's and
the court's content did not change, so no release was staged.

## Resolution — Step 8: the court's footsteps by surface (2026-11-09)

**The level.** `court:models.court`'s import gains `surfaces`: its glTF's two materials,
`Paving` to `court:surface.paving` and `Stone` to `court:surface.stone`. The paving is the floor,
the ledge and the exit; the stone is the walls, the low wall and the pit's floor. Its collision is
`.fcol` version 2, 132 triangles and two surfaces. The glTF is unchanged, and so are the triangles.

**Sharpened, §12's "floor, walls and steps":** the court has no steps and only two materials. So it
has two surfaces, and the place a player hears stone is the low wall's top, a jump up from the
floor. Giving the ledge or the exit a material of its own would change the drawn model, which §12
keeps.

**The records.** `@schema surface { step id  land id  warden_step id }` and two records:
- the paving names M26's `step`, `land` and `warden_step`;
- the stone names three new sounds, `court:sounds.step_stone`, `land_stone` and
  `warden_step_stone`, on the same buses and priorities as the paving's.

The `.wav` files come from `scripts/m37/make_court_steps.py`, which writes only those three and
none of M26's.

**Sharpened, §12's "a step sound each":** a surface names three sounds, not one. The player's
stride, a landing and the warden's footfall were already three sounds, and the warden's carries
an attenuation the player's must not. A landing plays its surface's `land`, the player's or the
warden's.

**What plays.**
- `walk.addCollisionMesh` is the court's copy of the sandbox's: it turns `.fcol` v2 attributes
  into `physics3d`'s, since `asset` cannot see `physics3d` and one sample cannot import another.
- `Walk.surface` is the ground's surface, and `Warden.surface` is the surface under its
  controller after its move, or none while it is carried over a link.
- `game.Event` gains `surface`, set on `step`, `land`, `warden_step` and `warden_land`.
- `sounds.surfaceSound` reads the surface's `court:surface` record from the store at each
  footstep, so a reload is followed.
- Ground with no surface, an ID that is no `court:surface`, or a missing sound plays the sound
  set's own, as before. The run counts both cases: "footsteps: N by their surface, M by the sound
  set's own".

**What did not move.** `win`, `caught`, `fell` and the soundtrack keep their body digests,
`2495783980aedff1`, `757a204cc05d1b02`, `6b4fdba4db5b669e` and `806953eeb8f10db8`, every tick. The
digest folds each event's kind, place and beacon and not its surface, and nothing reads a surface
but the sounds. Every navigation and court pin holds, since the mesh is built from the same
positions.

**The test.** `game_tests.zig` checks four things:
- the level reports paving on its floor and stone on the low wall and the walls;
- the records resolve, and no surface, another schema or no store gives none;
- a drop onto the low wall lands on stone and strides on stone, and the floor strides on
  paving;
- the sounds took every footstep from its surface's record. The warden's surface is paving.

**Guards verified by mutation,** each failing that test before it was restored:
- the surface index in `addCollisionMesh`;
- the stride's surface;
- the landing's surface;
- the warden's surface;
- the stride's sound chosen by its surface.

**Budgets, from the staged ReleaseSafe court on Metal, moved out of the repository and read-only,
windowed:**

| Script | Whole game tick p95 | `render.skin` p95 | Level `addMesh` p95 |
| --- | --- | --- | --- |
| `win` | 0.157 ms | 0.065 ms | 0.061 ms |
| `caught` | 0.153 ms | 0.054 ms | 0.048 ms |
| `fell` | 0.176 ms | 0.056 ms | 0.053 ms |

- **The budgets:** 0.25 ms for the tick and 5 ms for `addMesh`. The `addMesh` line is the level's
  collision with its surfaces, added to a scratch world 32 times at load.
- **Footsteps:** `win`'s 144 footsteps and landings played 142 by surface and 2 by the set's own.
  The two found no surface underfoot, as the warden has none while a link carries it.
- **Nothing was dropped:** no sound, mixer command or event, and each replay matched.
- **The first frames after load** read 54–78 ms of frame work, the cost `navigation.md` records
  whether or not a mesh is built.

**The bar.** `zig build test`: 2,918/2,928, ten skips, 132/132 steps, with one new test. Every
check, the four samples and `fdt-check` passed, and `make_court_steps.py --check` holds. The court
was staged with `dist`, since its content changed.

**The owner played it (2026-11-09), which is the exit's last clause.** They played the staged
ReleaseSafe build, `zig-out/dist/court/Foundry Court.app`, on the Mac, and reported "Fanatstic".

## Resolution — Step 9: Windows/Vulkan (2026-11-09)

`scripts/m37/windows.ps1` comes from M36's, with `m37-setup.ps1` and `m37-launch.ps1` beside it,
as M36's were. The setup clones the repository into its own directory on the PC and checks out
M37's commits from a git bundle, since they are not pushed. The launcher runs the desktop half from
a scheduled task in the owner's session.

The script drops M36's path, crate and animator runs, which M37 did not touch. It adds the corner's
six stages, their replay pin, the tilted tour, the move and door lines, and the court's `addMesh`
and footstep lines. It ran on the owner's Arc A750 PC, an i3-10105F, from a fresh clone at
`a7ec9c8`, at `-j2` and below normal priority, with the 50% CPU cutoff on. The PC read 21–24%
before each half.

**The native suites:**
- null 2,897/2,916 (19 skips), 128/128 steps;
- Vulkan 3,178/3,208 (30 skips), 232/232 steps;
- the ReleaseSafe pin suites (`physics3d`, `nav`, `anim`, `rigs`, `scene`, `sandbox3d` and
  `court`) 714/714.

So on x86_64 at ReleaseSafe, these pins hold:
- the corner's `832fe43a3a82db13` and the tilted comparison;
- the player's, the walker's and the pacer's three;
- the navigation and crowd pins;
- the court's four digests and its footsteps test.

**Both samples ran from a relocated, read-only ReleaseSafe install,** windowed in the desktop
session. One run of each kind was also under Khronos validation with synchronization, and every
validation log holds its one info line and nothing else.
- **The tour, six times:**
  - M23's five stages, the walker, the pacer's three saves and the corner's six stages pass with
    the Mac's values;
  - the corner's replay is `832fe43a3a82db13`;
  - the surfaces underfoot are the Mac's.
- **The tilted tour, twice:** it passes, worst 0.00001 m and 0.00010 m from upright, as on the Mac.
- **The court's three endings, eight runs:** each replay matched a fresh simulation, and nothing
  was dropped. Footsteps by surface are the Mac's: `win` 142 by surface and 2 by the set's own,
  `caught` 2, `fell` 11.
- **The install's hash tree was unchanged,** and no scripted run wrote preferences.

**§16's budgets on the i3, p95 in the paced loop:**

| What | Readings | Budget |
| --- | --- | --- |
| The player's move, carried and pushing, 1,300 moves a run | 0.090–0.114 ms | 0.25 ms |
| The door's `shapeSweep`, 600 a run | 0.0074–0.0080 ms | 0.05 ms |
| The level's `addMesh` with surfaces | 0.146–0.165 ms | 5 ms |
| The court's whole game tick, `win` ×4 and `fell` ×2 | 0.125–0.215 ms | 0.25 ms |
| The court's whole game tick, `caught` (76–80 frames) | **0.250 ms and 0.273 ms** | 0.25 ms |
| The warden's `render.skin` | 0.039–0.127 ms | 0.25 ms |

**The short `caught` ending sits on its line and over it under validation,** as in M35
(0.154–0.321 ms) and M36 (0.287 ms) on this i3. Its 76–80 frames make its p95 the worst four
frames. Every long ending sits under its line, and so does every reading of the move, which
was M23's tight one. The reading goes to M100 with M35's and M36's, as §16 says.

**Linux** compiles in the bar's cross-check. Nothing here is Linux-specific (§14).

**The PC** keeps `%USERPROFILE%\src\Foundry-m37` and `%USERPROFILE%\m37` until Step 10, which
deletes those two exact paths and nothing else.

## Resolution — Step 10: Close M37 (2026-11-09)

Every document now names M37 complete:
- `CLAUDE.md`:
  - §4.1's two rows say implemented;
  - §4.3's `physics3d`, `asset` and `author` lines name the up axis, scale, sweeps, surfaces,
    one-sided faces, platforms and pushing, `.fcol` v2, `foundry:model` v3's `collision` and
    `foundry:collision_import`;
  - §9's row adds M37.
- The roadmap's M37 line says complete, and M48's gains M37's bodies, hits, sweeps, scale and up.
- The design index says complete. The README says what a figure now does and points to M38.
- ADR-0075 and ADR-0076 say implemented.

**The contract discrepancies, each resolved by a dated note:**
- `collision3d.md` §15's eight rows are struck through: moving platforms and pushing, proxies, a
  model naming its collision, runtime scale, one-sided triangles, surfaces, rotational sweeps and
  the up axis. Each points here, and a surface's friction is named M50's.
- ADR-0051's "pushing and carrying platforms wait" and its revisit point to ADR-0075.
- ADR-0057's "rigid poses" notes body scale and proxies (ADR-0076), and that the baked tree, M38's,
  takes a later `.fcol` version, since v2 went to surfaces.
- `agents.md` §14's moving-mesh row notes that M37's platforms carry characters, and that a
  navigation mesh moving with one remains a game's.
- In this document:
  - §3 notes the tilted bound of 5 mm;
  - §7 notes that `moveBody` leaves riders to the carry, and that the guide now gives §13's order;
  - §11 notes the rock's body and its wall count;
  - §12 notes the two surfaces and three sounds.
- `docs/modding/3d.md`'s prop note says a body may now scale its mesh, while `sandbox3d:prop` still keeps a
  solid prop at scale 1.

**The guide:** `docs/modding/content-mods.md` §9 gains "Collision: surfaces, one-sided faces and
proxies". It covers `surfaces` by material name, `one_sided`, a proxy through
`foundry:collision_import` and `collision_mesh`, and what `fpack` refuses. It ends with §13's
order of a tick, which a game runs a world in.

**`AGENTS.md`:** its costs gain M37's readings on both machines, the corner's pin, the tilted tour,
and `scripts/m37/windows.ps1`. The bar itself is unchanged.

**What M37 leaves, each to a named milestone:** §18 stands as written. Readings over their line,
the i3's short `caught` ending among them, are M100's, as M35's and M36's were.

**The PC is cleaned:** `src\Foundry-m37` and `m37` are removed by exact name, and nothing else is
touched. No Foundry scratch is left on the Mac.

Nothing but documents changed after Step 9, which changed only scripts and documents. So the code's
bar stands at Step 8's: 2,918/2,928, ten skips, 132/132 steps. Tagged `m37`, not pushed.
