# Design: M25 — Public 3D: `FoundryApi_v6`, a 3D content mod and a native one

**Status:** Proposed 2026-10-01; awaiting the owner's acceptance of §15. No step has begun.
**Date:** 2026-10-01
**Baseline:** `211901d`, tag `m24`. M0–M24 are complete.
**Decisions:**
- ADR-0004 (one versioned C ABI), ADR-0026 (`abi` is a peer of `debug`; the host supplies its
  subsystems), ADR-0027 (a mod is a content package), ADR-0031 and ADR-0040 (native consent is
  the host's), ADR-0048 (3D conventions), ADR-0050 (the engine-declared hierarchy), ADR-0051
  (collision without dynamics), ADR-0053 (assets are not the renderer) and ADR-0058 (animation
  is the caller's) constrain it.
- [ADR-0059](../adr/0059-public-3d-retained-instances-owned-bodies.md), proposed: v6 publishes
  3D by content ID through **retained, mod-owned instances and lights** that the host submits
  in its own frame, the engine-declared transforms, and **mod-owned** `physics3d` bodies and
  characters beside world queries. It publishes no camera write, no animation, no runtime mesh
  or material creation and no shader.

`3d.md` §9 names what `FoundryApi_v6` covers, and §10's M25 row is the contract. M25 spans
`render3d`, `abi`, the C header, `sandbox3d` and the modding guide, so it writes its own
document, as M16 did for v5.

## 1. Purpose and boundary

`3d.md` §10's row, quoted:
- **Milestone:** `FoundryApi_v6`, and a 3D content mod and a native one.
- **Runnable result:** a mod that adds a 3D object and a material.
- **Exit condition:** an external C99 consumer uses v6 alone, and the table survives hostile
  input.
- **Regression coverage:** ABI conformance; hostile-input tests; the external consumer.

`3d.md` §9 lists v6's reach: "meshes, models and materials by content ID; instances; the
transform components; cameras; lights; and `physics3d` queries and the character". It is
published only after the Zig APIs have held for a milestone, which M24 satisfied for everything
here except animation.

**In M25:**
- `FoundryApi_v6`: v5's 233 calls unchanged, then 28 additive calls (§5–§8), with their types in
  `foundry.h` and Zig, proven to agree on every target;
- a retained instance set in `render3d` that the table fills and the host submits (§4);
- `sandbox3d` hosting two mods: a **content mod** that adds a model, its material and its
  collision with no code, and a **native C mod** that adds a model and a material through v6,
  moves it, lights it and makes it solid (§10);
- a hostile native mod, a seeded argument sweep over every v6 call, and an external C99 client
  that calls every v6 entry point (§12);
- `docs/modding/3d.md`, written from an out-of-repository consumer built against the installed
  header (§11).

**Not in M25** (each has its trigger in §14):
- animation through the ABI: poses, clips, skinned instances;
- a camera a mod writes;
- meshes, materials or textures a mod creates at runtime, and any shader or shading model;
- hull and mesh collision shapes from a mod, contacts, and a mod moving another mod's or the
  host's bodies;
- 3D in the Lua script host;
- an engine-declared "this entity draws this model" component;
- any change to v1–v5. They are frozen and stay byte-identical.

## 2. What exists

Read from the code at `211901d`:
- **`abi`** (`engine/src/abi/`) publishes `FoundryApi_v1` to `_v5`, 233 calls, each version the
  previous one's fields followed by a tail (`api.zig`'s `extendV4`). `foundry.h` is the
  specification; `agreement.zig`/`agreement.c` check every field's offset; `sweep.zig` walks
  the newest table's fields with `inline for`, so a call without a refusal path fails a test.
  `native_loader.zig` offers the versions in `offered_api_versions`. `abi`'s build grant has
  `scene` and `physics2d` but **not `render3d`, `physics3d` or `anim`**.
- **The host** (`host.zig`) holds optional subsystem pointers and the few fixed rings the
  boundary needs (texture slots, theme slots, nested views, authoring nodes). A callback a mod
  supplies is a system (per tick), an asset loader or a content-reload note (`public-abi.md`
  §8). **There is no per-frame callback.** v1's `render_draw_sprite` is legal only while the
  host's renderer is recording, which no mod callback is guaranteed to be inside.
- **`render3d`** draws immediately: `Renderer.begin`, `addLight`, `drawMesh`, then
  `Content.drawModel(ModelDraw{ model, world, overrides, skin })` with models and materials by
  handle, acquired by content ID (`content.zig`). A skinned model drawn without a palette is
  refused (`MissingSkin`). `Light` is a kind, colour, intensity, range, cones, a shadow flag and
  a world matrix; at most 16 a frame.
- **`scene.hierarchy`** has `worldTransform`, `parentOf`, `setParent`, `setParentKeepWorld` and
  their named refusals; `foundry:world_transform` has no serializer, so v1's generic read cannot
  see it (`hierarchy.md` §3.5).
- **`physics3d`** has spheres, capsules, boxes, hulls and meshes, static and kinematic bodies with
  a `u64` user value, `raycast`, `shapeCast`, `overlap`, `contacts`, and characters
  (`character.add`, `move`, `setFeet`, `remove`). `collision3d.md` §12 drew it for this table:
  generational handles, caller buffers with totals, named refusals, no callbacks.
- **`sandbox3d`** discovers packages from the install and the player's mods
  (`FOUNDRY_SANDBOX3D_PACKAGES`), owns a hierarchy world (the orrery), a collision world
  (`walk.zig`) and a `render3d.Content`, and loads **no native code**. No sample does: the
  room's mod screen manages profiles but "the room loads none". The native loader runs only in
  `engine/tests/`, against fixtures in `engine/tests/fixtures/*.c`.
- **External consumers** exist for v4 (`author_client.c`) and v5 (`net_client.c`), compiled by
  AGENTS.md's header matrix as C99 and C++17 for three targets.

## 3. The shape of v6, and why it is retained

The deciding problem is **when a mod's code runs**. A mod runs in `foundry_mod_init`, in its
systems at the fixed tick, and in loader and reload callbacks. None of those is inside the
host's frame, and the host's frame is the only place `render3d` accepts a draw. v1's 2D drawing
works only for a host that happens to update its world while recording, and no sample does.

There are two ways to give a mod a 3D object:
- **Immediate:** a per-frame draw callback, during which the mod calls `draw_model`. That is a
  new callback kind on the host's render path, running untrusted code between `begin` and
  `prepare`, with reentrancy rules for every other call made inside it.
- **Retained:** the mod creates an instance (a model by content ID, a world matrix, optional
  material overrides) from wherever its code runs, changes it from its systems, and destroys
  it. The host submits every live instance in its own frame, at a point it chooses.

**v6 is retained** (ADR-0059). It needs no new callback, so no untrusted code runs on the render
path and §8's reentrancy rules are unchanged. It is deterministic by construction: a system
writes an instance's pose at a tick, and every frame draws the last written pose, in a
documented order. It is cheap to validate, because every value is checked once at the call
that sets it rather than at every frame. And it is what `3d.md` §9 means by "instances". Lights
are retained the same way, for the same reason.

What stays immediate is the Zig API. `render3d` keeps submission per frame; the retained set
(§4) is a small mechanism above it, which a game may use or ignore.

**Ownership is per mod.** Every create call takes the caller's `FoundryMod self`, and a handle
remembers it. A mod may change or destroy only what it created; any other live handle answers
`FOUNDRY_ERR_REFUSED`. In 2D, `physics_destroy_body` accepts any body. 3D does not repeat that:
a query returns other bodies' handles, and a hostile mod must not be able to delete the player's
character with one (§8).

**Identity crosses as content IDs**, never as asset or `render3d` handles: a model, a material
and a collision mesh are named by `FoundryContentId`, and the boundary acquires them. A mod
cannot hold a payload pointer, and an override by another package reaches every mod's instance
at the next reload, exactly as it reaches the host's own draws.

## 4. `render3d`: the retained instance set

**A new file, `render3d/instances.zig`, `render3d.Instances`.** A fixed-capacity set of
instances and lights with generational handles, each carrying an opaque `owner: u64` that
`render3d` stores and never interprets, as `physics3d` stores `user`.

- **An instance** holds a `ModelHandle` acquired through `Content`, a world `Mat4`, up to
  `max_overrides` (8) slot overrides with their acquired `MaterialHandle`s, and a visibility
  flag. Creating one acquires the model; destroying it releases the model and its materials.
- **A light** holds a `Light` value.
- **`submit(content, renderer)`** draws every visible instance through `Content.drawModel` and
  adds every light through `addLight`, in **ascending slot index**. The host calls it once in its
  frame, after its own lights and draws, so that the host's lights are never the ones a full
  frame drops. A light that does not fit (`max_lights` is 16 in all) is counted in
  `Stats.instance_lights_dropped` rather than failing the frame; an instance whose draw is refused
  (a model reloaded into something undrawable) is counted in `instances_refused` and the frame
  goes on.
- **Capacity** comes from `Instances.Limits`: 1,024 instances and 8 lights by default. Bounds are
  refusals with names (`TooManyInstances`, `TooManyLights`), never growth.
- **Refusals at the call that sets a value:** a world matrix that is not finite or not affine
  (`InvalidTransform`), a model that is not a `foundry:model` (`NotAModel`), a model with a
  skeleton (`Unsupported`: drawing it needs a palette the ABI does not carry, §14), a slot the
  model lacks, more than one override per slot, and a light `lighting.valid` refuses.
- **Content reload:** `Content.contentChanged` already keeps model handles valid across reload.
  The set therefore needs no hook of its own. A model reloaded into a skinned one is refused at
  `submit` and counted, never drawn with a missing palette.

**Why `render3d` and not `abi`.** The set is engine state with a renderer's semantics — budgets,
order, reload — and `abi` holds no engine state (ADR-0026). The boundary only translates a call
into one `Instances` method and checks `owner` against the caller.

**What it is not.** It is not an entity, a component or a scene graph. A mod that wants an
instance to follow an entity reads the entity's world transform (§6) in its system and writes it
to the instance. An engine "draw this model" component is deferred (§14).

## 5. v6's `render3d` calls (9)

All take and return plain values. `FoundryMat4` is sixteen `float`s, column-major, column
vectors (ADR-0048), and `FoundryLight3D` places a light by a position and a unit rotation whose
−Z is its direction, which is the light's own frame and avoids a scale a light cannot have.

| Call | Does |
| --- | --- |
| `render3d_instance_create(self, model, const FoundryMat4 *world, FoundryInstance *out)` | Acquire `model` by content ID and draw it at `world` until destroyed |
| `render3d_instance_destroy(instance)` | Release it |
| `render3d_instance_set_world(instance, const FoundryMat4 *world)` | Move it |
| `render3d_instance_set_material(instance, slot, material)` | Override one slot by content ID; `FOUNDRY_ID_NONE` clears it |
| `render3d_instance_set_visible(instance, visible)` | Hide it without releasing it |
| `render3d_light_create(self, const FoundryLight3D *light, FoundryLight *out)` | Add a light to every frame until destroyed |
| `render3d_light_set(light, const FoundryLight3D *value)` | Change it |
| `render3d_light_destroy(light)` | Remove it |
| `render3d_camera_get(FoundryCamera3D *out)` | The camera the host drew its last frame with: position, rotation, vertical field of view, near, far, and the target's pixel size |

`render3d_stats(FoundryRender3dStats *out)` is not added: the overlay reads `render3d`'s
`Stats` through `debug`, and a mod's use of it has no consumer yet.

**Why no camera write.** 2D publishes `render_camera_set`. In 3D the camera belongs to the
host's player or tool, and two writers would fight every frame. Reading is enough to place a
label over an object or to face the viewer. A mod-owned camera (a spectator, a cutscene) is a
grant the host would have to hand out explicitly, and waits for a mod that needs one (§14).

**Why not runtime meshes and materials.** A native mod ships a content package (ADR-0027), so its
geometry and materials are records and assets in that package, compiled by the same compiler and
overridable by the next mod. A mod generating geometry at runtime would need mesh upload through
the table and lifetime rules for GPU resources; that waits for a mod that needs procedural
geometry (§14).

## 6. v6's transform calls (5)

`hierarchy.md` §3.5 promised the names in v6. The world is the one the host lends (`world`, as
v1's scene calls use), and a world whose host did not enable the hierarchy answers
`FOUNDRY_ERR_UNAVAILABLE`.

| Call | Does |
| --- | --- |
| `world_transform_get(entity, FoundryTransform *out)` | The local `foundry:transform` |
| `world_transform_set(entity, const FoundryTransform *value)` | Add or replace it, validated as `scene` validates a transform |
| `world_parent_get(entity, FoundryEntity *out)` | The parent, or the null entity for a root |
| `world_parent_set(entity, parent, mode)` | Re-parent, `mode` 0 keeping the local pose and 1 keeping the world pose (`hierarchy.md` §5); the null entity detaches |
| `world_world_transform(entity, FoundryMat4 *out)` | The world matrix the last propagation left |

`FoundryTransform` is a translation, a unit rotation `(x, y, z, w)` and a scale, 40 bytes, the
same layout as `scene.hierarchy.Transform`. **The refusals map to the boundary's codes:** a
cycle and an unrepresentable keep-world pose are `FOUNDRY_ERR_REFUSED`, a chain past the depth
limit is `FOUNDRY_ERR_LIMIT`, a dead entity is `FOUNDRY_ERR_INVALID_HANDLE`, and an invalid
transform is `FOUNDRY_ERR_INVALID_ARGUMENT`. Nothing is written on any refusal, which is
`hierarchy.md`'s rule, now said at the boundary. Ownership does not apply: entities are the
world's, as in v1, and a mod writing a transform is what v1's `world_add_component` already
permits by schema.

## 7. v6's world queries (3)

The world is the collision world the host lends with its allocator, as `physics2d` is lent.

| Call | Does |
| --- | --- |
| `physics3d_raycast(origin, direction, max_distance, const FoundryFilter3D *filter, FoundryRayHit3D *out, FoundryBool *hit)` | The nearest hit along a unit direction |
| `physics3d_shape_cast(const FoundryShape3D *shape, const FoundryPose3D *pose, displacement, filter, FoundryHit3D *out, FoundryBool *hit)` | The earliest hit of a moving sphere, capsule or box |
| `physics3d_overlap(shape, pose, filter, FoundryOverlap3D *out, capacity, count, total)` | Everything overlapping, in handle order, with the total so a short buffer knows it truncated |

"No hit" is `FOUNDRY_OK` with `*hit` false, not `FOUNDRY_END`, which means a walk has finished.
Capacity is bounded by `physics3d_max_hits` (4,096), as in 2D. A filter's `ignore` may name any
body: ignoring is not mutation. `contacts` is not published; depenetration is the character's
business and nothing outside it has asked (§14).

## 8. v6's bodies and characters (11)

| Call | Does |
| --- | --- |
| `physics3d_body_create(self, const FoundryBody3DDesc *desc, FoundryBody3D *out)` | A static or kinematic sphere, capsule or box, with a layer, a mask and a `u64` user value |
| `physics3d_body_destroy(body)` | |
| `physics3d_body_set_pose(body, const FoundryPose3D *pose)` | Move it; a kinematic body is what a moving platform is |
| `physics3d_body_set_filter(body, layer, mask)` | |
| `physics3d_body_get(body, FoundryBody3DDesc *out)` | Read any body, owned or not: shape, pose, kind, filter, user |
| `physics3d_character_create(self, const FoundryCharacterConfig *config, feet, user, FoundryCharacter *out)` | A capsule character with `collision3d.md` §7's settings |
| `physics3d_character_destroy(character)` | |
| `physics3d_character_move(character, displacement, FoundryCharacterMove *out)` | One move: feet, grounded, ground normal, walls, stepped, snapped, depenetrated, stuck |
| `physics3d_character_set_feet(character, feet)` | Teleport |
| `physics3d_character_feet(character, FoundryVec3 *out)` | |
| `physics3d_character_body(character, FoundryBody3D *out)` | The body a query hit names, so a mod can tell its character apart |

**Ownership is enforced here most of all.** The host records each body and character a mod
created, in a bounded table on the host (256 bodies and 16 characters by default), because
`physics3d` keeps one `user` value per body and that value is the mod's to choose. Destroying,
moving or refiltering a body the caller did not create is `FOUNDRY_ERR_REFUSED`, so the host's
room, the player and another mod's objects cannot be changed through the table, only read and
queried. A mod's body may block the player: that is what making an object solid means, and the
host chose to load the mod.

**Shapes are spheres, capsules and boxes.** Hulls need a point list crossing the boundary and a
geometry lifetime; meshes need a collision asset resolved by content ID. Both wait for a mod
whose object is not a primitive (§14). A content mod's object has mesh collision without any of
this, through its compiled `.fcol` (§10).

**Simulation discipline.** Bodies and characters change only when a mod calls; nothing ticks on
its own. A mod that moves a character from its system, at the fixed step, gets I9's replay.

## 9. `abi` and the header

- **`abi` is granted `render3d` and `physics3d`**, downward from L5, and still never `rhi` or
  `anim`. CLAUDE.md §4.3's `abi` line gains both at the close.
- **The host lends** `render3d_content: ?*render3d.Content`, `render3d_instances:
  ?*render3d.Instances`, a `render3d_camera: ?Camera3D` snapshot it refreshes each frame,
  `collision3d: ?*physics3d.World` with `collision3d_allocator`, and keeps its ownership tables.
  Each absence is `FOUNDRY_ERR_UNAVAILABLE` for its group, never a missing entry.
- **`FoundryApi_v6`** is v5's fields, then the 28 calls in the order §5, §6, §7, §8 list them.
  `api_version_6` joins `offered_api_versions` **in the same commit as the table** — M15 shipped
  v4 without it, and the external client was what found it.
- **Types**, each `extern`, explicitly padded, and offset-checked by `agreement` on every target:
  `FoundryVec3`, `FoundryQuat`, `FoundryMat4`, `FoundryTransform`, `FoundryPose3D`,
  `FoundryCamera3D`, `FoundryLight3D`, `FoundryShape3D`, `FoundryFilter3D`, `FoundryBody3DDesc`,
  `FoundryRayHit3D`, `FoundryHit3D`, `FoundryOverlap3D`, `FoundryCharacterConfig`,
  `FoundryCharacterMove`, and the handles `FoundryInstance`, `FoundryLight`, `FoundryBody3D`,
  `FoundryCharacter`. Enumerations (light kind, shape kind, body kind, parent mode) are `int32_t`
  with written values.
- **Validation is §6 of `public-abi.md`, all of it:** pointers before the host is looked up,
  values after; every float checked for NaN and infinity before it reaches simulation; unit
  quaternions within `Quat`'s tolerance; affine matrices; out-parameters written only on
  `FOUNDRY_OK`.
- **Names are permanent** (CLAUDE.md §7). The prefixes `render3d_`, `world_` and `physics3d_`
  match the modules a mod author reads about, beside v1's `render_` and `physics_`.

Nothing in v1–v5 changes, so every existing mod, the editor's client and the network client keep
their bytes. v6 is **frozen at M25's close**: M26 plays through Zig APIs, and a call it finds
missing goes into a later additive version (`3d.md` §10.1).

## 10. `sandbox3d`: two mods

**The content mod, `plinth`** (`samples/sandbox3d/testdata/mods/plinth/`): a stone plinth and its
material, with no code. Its glTF is generated in-repo by `scripts/m25/make_props.py`,
byte-reproducibly, as M20's and M24's are. Its `foundry:model_import` sets `collision true`, so
the compiler emits its `.fcol`. It adds one record of a new sample schema:

```fdt
@schema prop {
    model id
    position { x f32 y f32 z f32 }
    yaw f32 (default 0)
    scale f32 (default 1)
    collision id (default none)
}
```

`sandbox3d` draws **every** `sandbox3d:prop` record, in content-ID order, and adds each one's
collision mesh to the walk's world as a static body. That is the Tier 1 pattern any game uses:
the host enumerates records of a schema it owns, and a mod adds records. The sample's own package
has none, so a run without the mod is unchanged and M23's and M24's pinned hashes hold.

**The native mod, `orbiter`** (`samples/sandbox3d/testdata/mods/orbiter/`): a C99 library built
by `build.zig` against the installed header, with a package that carries its own model and
material. Its `foundry_mod_init` asks for v6 and refuses itself legibly without it. It then:
- creates an entity with a `foundry:transform` and parents a second to it, then reads the child's
  world matrix (§6);
- raycasts down to find the floor, and creates an instance of its model there (§5, §7);
- overrides that instance's material with a second one from its package;
- adds a point light above it;
- creates a kinematic box body around it, so the player is stopped by it (§8);
- registers a system that turns the parent, propagation moves the child, and the system writes
  the child's world matrix to the instance and the body's pose each tick.

**Hosting native code is opt-in, by the host, per package.** `FOUNDRY_SANDBOX3D_NATIVE` lists
the package IDs the person running the sample consents to for this run. It is host bootstrap
(ADR-0031), not content: no package can grant it, and a mod named in it that is not also
selected loads nothing (ADR-0040's rule, applied without a profile). Without it the sample stays
content-only, as today. The sample binds `abi.Host` with its world, content, instances, camera
and collision world, then runs the native loader after content is live, as `public-abi.md` §13
orders.

**The tour gains a mod stage.** With both mods selected and `orbiter` consented,
`FOUNDRY_SANDBOX3D_WALK=tour` checks that the plinth is drawn and blocks a cast, that the
orbiter's instance, light and body exist and moved for a fixed number of ticks, and that the
player is stopped by the orbiter's body. It replays in a fresh process and requires the same
hash of the orbiter's poses. Without mods, the existing tour and its hashes are unchanged.

## 11. The modding guide and the external consumer

`docs/modding/3d.md` is written the way `docs/modding/networking.md` was in M16: from a consumer
**outside the repository**, built only against the installed `foundry.h`, with every command run.
It covers a content mod's model, material and prop record, a native mod's instances, lights,
transforms and bodies, ownership and its refusals, and what v6 does not do. `native-mods.md`'s
statement that "the sandbox does not bind a native loader" gains its 3D exception.

`engine/tests/fixtures/render3d_client.c` is the in-repository conformance client: it calls
every v6 entry point and nothing else, the way `net_client.c` does for v5, and AGENTS.md's header
matrix compiles it as C99 and C++17 for macOS, Linux and Windows.

## 12. Verification

**Platforms first.** Nothing in `rhi`, the shaders or a backend changes: an instance is drawn by
the path every model already takes. **Windows/Vulkan, on the PC, is needed** (Step 6) for the
one new runtime path there, a native `.dll` loaded by a sample from a relocated install, and for
the native x86_64 `abi` suites, where struct layout and calling convention are what a cross
`check` compiles but does not run. **Linux is compile-only**: the loader's `.so` path predates
M25, and no window, surface, presentation or driver behaviour changes (`3d.md` §10.2).

**`render3d.Instances` (null backend):** every refusal of §4; submission order by slot; a
destroyed instance's model and materials released (refcounts back to their prior values); a
stale handle refused after slot reuse; lights beyond the frame's capacity counted, never fatal;
an instance whose model reloads into a skinned one refused at `submit` and counted; a
content-reload with a material override from another package seen at the next frame.

**`abi` (unit, with the test engine):**
- `sweep.zig` covers v6 by construction: every call with zeroed arguments returns an error and
  every call on an empty host answers `unavailable`;
- each call's refusals: null pointers, NaN and infinity in every float, non-unit quaternions,
  non-affine and non-finite matrices, zero and negative dimensions, an out-of-range enumeration, a
  content ID of the wrong schema, a skinned model, a stale handle, a foreign handle (`refused`),
  a capacity above the bound, a full table (`limit`); out-parameters untouched on every refusal;
- hierarchy refusals at the boundary (cycle, depth, unrepresentable, dead entity) with a
  snapshot of every component byte-identical before and after, as `hierarchy.md` requires;
- `agreement` offsets for every new type and the v6 table on every target; `offered_api_versions`
  includes 6.

**Hostile input (integration):**
- `engine/tests/fixtures/hostile3d_mod.c`, loaded through the real native loader, sends every
  refusal above and tries to destroy, move and refilter host bodies and another mod's instance.
  The host then draws a frame and runs the tour; both pass and the player's replay hash is
  unchanged;
- a **seeded argument sweep**: 10,000 calls a seed, across every v6 entry point, with random bit
  patterns for handles, IDs, floats (including NaN, infinities and denormals), enumerations and
  capacities, and pointers that are null or valid. No call faults, no assertion fires, every
  result is a documented code, and the host's state checks pass afterwards. Three fixed seeds run
  in `zig build test`.

**The external consumer:** `render3d_client.c` compiles in the header matrix and runs as a native
mod in an integration test, every call answering as documented. Out of the repository, the guide's
consumer (§11) builds against the installed header and runs in a relocated sample.

**The sample:** the tour with both mods passes headless on null, windowed on Metal and on
Windows/Vulkan from relocated ReleaseSafe installs (the native library beside its package), with
the replay hash stable on each machine; without mods, M23's `cb99ccfcf2b6d6c3` and M24's walker
hashes are unchanged. Both ad-hoc releases stage, since the sample gains a schema and test mods.

**Cost, measured inside the paced 60 Hz loop** at ReleaseSafe on the Mac and the PC: the median
and p95 of a new `abi.instances` zone around `Instances.submit` with the orbiter's instance and
light, **budget p95 under 0.05 ms**, and with 1,024 instances of the plinth recorded without a
budget, to show the cost of a mod that fills the table.

**By hand:** a person walks into the plinth and the orbiter, sees the orbiter turn under its
light, and says so.

## 13. Implementation order — eight bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

### Step 1 — `render3d`: the retained instance set

§4: `render3d.Instances`, its limits, refusals, ownership tag, submission order, reload behaviour
and the new `Stats` counters, with §12's `Instances` tests. No ABI. **Exit:** instances and lights
created, changed and destroyed through the set draw on the null backend in slot order, every
refusal is named, and every acquisition is released.

### Step 2 — `abi`: `FoundryApi_v6`

§5–§9: the build grants, the host's lent subsystems and ownership tables, the 28 calls, their
types in `foundry.h` and Zig, `agreement`, `offered_api_versions`, the sweep and the per-call
refusal tests. AGENTS.md's header matrix gains `render3d_client.c`. **Exit:** v6 is published
with every call tested against its refusals, the sweep covers it, the header compiles as C99 and
C++17 for three targets, and v1–v5's offsets are unchanged.

### Step 3 — hostile input and conformance

§12's hostile native mod through the real loader, the seeded sweep at three seeds, and
`render3d_client.c` loaded and run as a native mod. **Exit:** no hostile call faults or changes
anything it does not own, and the conformance client's every call answers as documented.

### Step 4 — `sandbox3d`: the content mod, on Metal

§10's `prop` schema, `scripts/m25/make_props.py`, the `plinth` package, drawing and colliding
every prop, and the tour's check of it. **Exit:** with `plinth` selected, the plinth draws lit and
blocks the player on Metal from a relocated install; without it, every pinned hash is unchanged.

### Step 5 — `sandbox3d`: the native mod, on Metal

§10's `FOUNDRY_SANDBOX3D_NATIVE` consent, the host binding and loader, the `orbiter` C mod built by
`build.zig` and installed beside its package, the tour's mod stage and replay, and the paced cost.
**Exit:** from a relocated ReleaseSafe Metal install with both mods, the orbiter turns, lights,
blocks and replays byte-exactly, and an unconsented `orbiter` loads its content but no code.

### Step 6 — Windows/Vulkan on the PC

The native `abi` and sample suites; `orbiter.dll` loaded from a relocated install; the tour with
both mods under synchronization validation and with layers off; the replay on that machine; the
recorded cost; pack-up. The PC rules stand: CPU at or under 50%, `-j2`, below-normal priority,
background jobs, a worktree. **Exit:** every suite and the tour pass natively with validation
clean, and the orbiter's replay is byte-identical on that machine.

### Step 7 — the external consumer and the guide

§11: an out-of-repository C99 mod built against the installed header, run in a relocated sample on
the Mac and compiled for Windows, and `docs/modding/3d.md` written from it. **Exit:** a mod built
outside the repository from the guide alone adds an object and a material through v6.

### Step 8 — Close M25

This step:
- reconciles `3d.md` §9 (what v6 covers: retained instances, no camera write, no animation) and
  §10's M25 row; `public-abi.md` gains a pointer to v6; `hierarchy.md` §3.5 and `collision3d.md`
  §12 record that their names are published; `native-mods.md`'s host note;
- adds `render3d` and `physics3d` to `abi`'s line in CLAUDE.md §4.3, moves ADR-0059 to Accepted
  and into §4.1, and updates §9's 3D row;
- updates AGENTS.md's header matrix if Step 2 changed it, the roadmap, the design index and
  `PROJECT_STATE.md`;
- runs the bar and tags `m25`. v6 is frozen from this commit.

It pushes only when asked, and stops before M26's design. **Exit:** every document names M25
complete and v6 frozen, and nothing names a contract the code does not have.

## 14. What stays open, deliberately

| Deferred | Returns when |
| --- | --- |
| Animation through the ABI (poses, clips, skinned instances) | A mod needs an animated character; it would publish sampling over a model's named clips and a palette on an instance |
| A camera a mod writes | A mod needs a spectator or cutscene camera; it needs a host grant like `mods_write` |
| Runtime meshes, materials and textures from a mod | A mod needs procedural geometry or materials it cannot ship as content |
| Mod-authored shaders and shading models | ADR-0015's trigger: a mod needs a look the engine's models cannot give |
| Hull and mesh shapes, and `contacts`, for mod bodies | A mod's object is not a primitive and is not content |
| An engine-declared "draws this model" component | A second host needs entity-driven drawing that a mod can join, or M26's sample does |
| 3D in the Lua script host | A script mod needs 3D; the script host's surface is validation over the table and would grow with it |
| Immediate-mode drawing through a frame callback | Retained instances measured as a burden for a real mod (thousands of short-lived objects a frame) |
| Per-mod instance and body quotas | One mod starving another of a shared table in practice |
| `render3d_stats` for mods | A mod with a use for frame counts |

## 15. Decisions acceptance fixes

Every choice is recommended as written. Nothing blocks Step 1 once these are accepted.

| # | Choice | Where |
| --- | --- | --- |
| 1 | v6 is v5 unchanged plus 28 additive calls, frozen at the close (ADR-0004, `3d.md` §10.1) | §1, §9 |
| 2 | **3D drawing is retained, not immediate:** mod-owned instances and lights the host submits in its frame; no per-frame callback (ADR-0059) | §3 |
| 3 | The retained set is `render3d.Instances`, with an opaque owner tag; `abi` only translates | §4 |
| 4 | Models, materials and collision meshes cross as content IDs, never as handles or payloads | §3, §5 |
| 5 | **A mod may change or destroy only what it created**; foreign handles are `refused`, unlike 2D's bodies | §3, §8 |
| 6 | The transform calls publish `hierarchy.md` §3.5's names, with refusals mapped to boundary codes and nothing written on refusal | §6 |
| 7 | Queries are raycast, shape cast and overlap; bodies are sphere, capsule and box, static or kinematic; characters are published | §7, §8 |
| 8 | **No camera write, no animation, no runtime meshes or materials, no shaders, no Lua** in v6, each with its trigger | §5, §14 |
| 9 | `abi` is granted `render3d` and `physics3d`, never `rhi` or `anim` | §9 |
| 10 | `sandbox3d` gains a `prop` schema that a content mod adds records of, drawn and collided | §10 |
| 11 | **`sandbox3d` becomes the first sample to load native code**, only for packages named in `FOUNDRY_SANDBOX3D_NATIVE` | §10 |
| 12 | The two mods are `plinth` (content) and `orbiter` (native C99), generated and built in-repo | §10 |
| 13 | Hostile input is proven by a hostile native mod and a seeded sweep across every v6 call | §12 |
| 14 | Budget, read inside the paced loop: `abi.instances` p95 under 0.05 ms for the orbiter on both machines; 1,024 instances recorded without a budget | §12 |
| 15 | The PC is needed (Step 6) with the ordinary 50% CPU rule; Linux is compile-only, since nothing Linux-specific changes | §13 |
