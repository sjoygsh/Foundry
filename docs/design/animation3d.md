# Design: M24 — Animation: skeletons, clips, fixed-step sampling, CPU skinning and a walking character

**Status:** Accepted 2026-10-01, when the owner requested Step 1. Steps 1–6 of eight are complete;
Step 7 has not begun.
**Date:** 2026-10-01
**Baseline:** `9c6bf56`, tag `m23`. M0–M23 are complete.
**Decisions:**
- ADR-0048 (conventions), ADR-0053 (assets are not the renderer), ADR-0054 (fixed vertex
  slots), ADR-0055 (imports compile to records), ADR-0013 (deterministic-friendly, not
  bit-exact) and ADR-0036 (explicit jobs) constrain it.
- [ADR-0058](../adr/0058-skeletal-animation-sampled-poses-cpu-skinning.md): animation
  is sampled poses in a new L1 module, `anim`, that sees no asset and no entity; skeletons and
  clips are compiled assets it is handed as values; skinning is linear-blend, on the CPU, into
  per-frame vertex data, with no skinned shader variant.

`3d.md` §9 is the architecture of animation in two sentences, and §10's M24 row is the contract.
M24 spans a new module, `asset`, `author`, `rhi`, `render3d` and the sample, so it writes its
own document, as M20, M22 and M23 did. `sprite-animation.md` is 2D's flip-book animation and is
unrelated: nothing here changes it.

## 1. Purpose and boundary

`3d.md` §10's row, quoted:
- **Milestone:** skins and clips from glTF, sampled at the fixed step, CPU skinning, and the
  skinned variants.
- **Runnable result:** an animated character from glTF, walking through the room.
- **Exit condition:** sampling is deterministic, and skinning matches a reference.
- **Regression coverage:** sampling replay; skinned pose against a reference; import refusal
  for bad skins.

**In M24:**
- a skeleton and a clip as Foundry's own runtime representations and compiled assets;
- glTF skins and animations imported into them, and refused with diagnostics when malformed;
- sampling a clip into a pose, looping, and blending two poses;
- linear-blend skinning on the CPU, drawn through `render3d` lit, unlit and into the shadow map;
- a generated, in-repo skinned character that patrols the M23 room, colliding, on Metal and on
  Windows/Vulkan.

**Not in M24** (each has its trigger in §14):
- GPU skinning of any kind, and so any skinned shader variant (§8 says why the row's "skinned
  variants" are not built);
- morph targets, cubic-spline keyframes, and animation of nodes that are not joints;
- root motion, inverse kinematics, additive layers, state machines and animation events;
- an engine-declared animation component in `scene`, and anything in the public ABI;
- a third-person player body. The player stays first-person; the animated character is another
  walker in the room.

## 2. What exists

Read from the code at `9c6bf56`:
- **`core/math.zig`** has `Vec3`, `Quat` (with `slerp`), `Transform` and `Mat4`. Nothing knows
  what a joint is.
- **`asset/mesh.zig`** names `joints` (slot 6) and `weights` (slot 7) in `Semantic`, and
  `validate` refuses both as `UnsupportedVertexFormat`. `VertexFormat` has three float formats
  and `unorm8x4`; there is no integer format. `mesh_file.zig` is `.fmesh` version 1.
- **`asset/schemas.zig`** declares `foundry:model` as slots and flat parts (mesh, submesh, slot,
  TRS). A model has no nodes: the importer flattens them (`3d.md` §3).
- **`author/gltf/`** parses `skins` and `animations` only as opaque JSON. It warns that both
  "are not imported until M24", warns on a node's `skin`, and **refuses** a primitive with
  `JOINTS_n` or `WEIGHTS_n`. So no existing import contains skinned geometry, and importing
  skins cannot change an existing package's bytes.
- **`render3d/renderer.zig`** uploads a mesh once in `createMesh`, into device-local buffers
  through a staging copy. Per frame it maps only each frame slot's uniform buffer. `MeshDraw` is
  a mesh, a submesh, a material and a world matrix. `content.zig` draws a `foundry:model` by
  handle. Nothing writes vertex data per frame.
- **`rhi`** has `MemoryIntent` (`device_local`, `upload`, `readback`) and `mapBuffer`. Whether a
  mapped buffer may be bound as a vertex buffer, and reused across frames in flight, is not a
  path any code exercises today (§7).
- **`physics3d`** has characters, and **`samples/sandbox3d`** has M23's walk, course and tour,
  whose replay hash `cb99ccfcf2b6d6c3` is pinned in a test.
- **`scripts/m20/make_scene.py`** generates the sample's glTF in-repo, byte-reproducibly.

## 3. `anim`: the module and its values

**A new module, `anim`, at L1, on `core` alone.** It is to animation what `physics3d` is to
collision, and for the same reasons (ADR-0022, ADR-0051): the deciding issue is I9, and a module
that can see neither files, entities nor a renderer is a pure function of its inputs, unit-tested
with no device. It has no time and no playback state. A caller says *sample this clip at this
time*, and gets a pose.

**Why not inside `asset`, `scene` or `render3d`.** `asset` loads; it should not evaluate.
`scene` would tie animation to entities before a second consumer shows what a component should
hold (§10). `render3d` would make a pose a rendering concept, and gameplay will want poses a
renderer never sees (a hand's position for an attachment, a hit volume). Below all three, each
can use it.

**Its values are borrowed, never owned assets** (as ADR-0057 has `physics3d` take geometry):
- **`Skeleton`**: `joint_count` (1 to 256); `parents: []const u16`, where a root holds
  `no_parent` and **every parent precedes its children**; `rest: []const Transform`, the local
  rest pose; `inverse_bind: []const Mat4`; and `root: Mat4`, the constant transform from the
  skeleton's root space to model space.
- **`Clip`**: `duration` in seconds, positive and finite; and `tracks`, each naming a joint, a
  path (`translation`, `rotation` or `scale`), an interpolation (`step` or `linear`), strictly
  increasing key times in `[0, duration]` and their values.
- **`Pose`**: `local: []Transform`, one per joint, in a caller-owned buffer.

`Skeleton.validate` and `Clip.validate` return named errors for every way untrusted data can be
wrong (a parent after its child, a non-finite value, a non-unit quaternion, an unsorted time, a
track naming a joint the skeleton lacks). Sampling a value that has not been validated is a
programmer error, and asserts.

**Nothing allocates after setup.** Every function writes into buffers the caller passes.

## 4. Sampling, looping and blending

**`sample(skeleton, clip, time, out: *Pose)`** fills every joint:
- A joint with no track for a path keeps the skeleton's rest value for that path. So a clip
  that animates only the legs leaves the arms at rest, never at identity.
- Between two keys, translation and scale interpolate linearly, and rotation by `core`'s
  `Quat.slerp` along the shorter arc. That is glTF's rule, so an imported clip plays as its
  authoring tool showed it.
- Before the first key the first value holds; after the last, the last.
- `step` holds the earlier key's value.

**Time is the caller's, in seconds, as `f32`.** `anim` reads no clock. `wrap(time, duration)`
and `clamp(time, duration)` are the two helpers for a looping and a one-shot clip. A simulation
derives time from its **tick count** (`tick × dt`, wrapped), not by accumulating `dt`, so a long
run does not drift and a replay from tick zero reproduces every pose (I9). The sample does this
(§10); the rule is stated in the module's header for every later caller.

**`blend(a, b, weight, out)`** mixes two poses joint by joint: translation and scale linearly,
rotation by `slerp`. It is what a cross-fade from idle to walk needs, and it is all M24 builds.
Layers, masks and additive poses are deferred (§14).

**`skinMatrices(skeleton, pose, out: []Mat4)`** walks joints in order (parents first, so one
pass), composes each joint's model-space matrix, and writes `root · model[j] · inverse_bind[j]`.
Those are the matrices skinning consumes. `modelMatrices` returns the un-skinned joint matrices,
for a game that attaches something to a joint.

**Determinism.** Sampling uses no global state, no clock and no pointer value, and visits joints
and tracks in stored order. The same binary, clip, skeleton and time give the same bytes. Across
machines the last bits may differ (ADR-0013), which is why §12 asserts against references with
tolerances and asserts replay byte-exactly only on one machine.

## 5. Skinning: linear blend, on the CPU

**`anim.skin` is one kernel:** given bind-pose positions, normals and tangents, each vertex's
four joint indices and four weights, and the skin matrices, it writes skinned positions, normals
and tangents. Each vertex's matrix is the weighted sum of its joints' matrices. Positions use the
full matrix; normals and tangents use its upper 3×3 and are renormalised; a tangent's `w`
(handedness) is copied.

**The normal rule is exact for rigid and uniformly scaled joints,** which is what a character
has. A non-uniformly scaled joint wants the inverse transpose; that is deferred with a trigger
(§14) and stated here so nobody discovers it.

**It takes a vertex range,** so `render3d` can split one mesh across `core.Jobs` chunks
(ADR-0036). Each chunk writes only its own vertices, so the result does not depend on the worker
count, and the inline `Jobs` is the reference a parallel run is compared with.

**Why the CPU.** `3d.md` §9 fixes it: "Skinning runs on the CPU first; GPU skinning is compute's
trigger." It also buys three things now: the skinned vertices are ordinary vertices, so every
existing shader, the shadow pass and both backends draw them unchanged; "skinning matches a
reference" is a CPU test with no readback tolerance; and gameplay can later read a skinned
position without a GPU round trip.

## 6. Assets: `.fskel`, `.fanim`, `.fmesh` version 2 and the model record

All in `asset`, beside the mesh and the collision mesh, each a versioned little-endian binary
whose reader borrows the caller's bytes and refuses rather than asserts (I8). A newer version
reports `UnsupportedVersion`, never "not a skeleton".

- **`foundry:skeleton`**, source `.fskel`, magic `FSKL`, version 1: the joint count, then per
  joint its parent, rest TRS and inverse bind matrix, then the root matrix, then a name table.
  **Joint names are kept**: they are how a game finds "hand.R" for an attachment, and how a
  diagnostic names a joint. They are not identity; a joint is its index within its skeleton.
- **`foundry:animation`**, source `.fanim`, magic `FANM`, version 1: the duration, the joint
  count the clip was made for, then the tracks. A clip is checked against a skeleton when the
  two are paired, since a mod may override either.
- **`.fmesh` version 2** adds:
  - `VertexFormat.uint8x4`, legal only for `joints`; `weights` is `float32x4`;
  - a joint-bounds section: per joint, the box, in model bind space, of every vertex it
    influences with a non-zero weight. It is what culling uses (§8);
  - the rule that `joints`, `weights` and joint bounds come together or not at all.

  Version 1 files still read, byte for byte as before. The writer emits version 1 for a mesh
  with no skin, so **no existing mesh's bytes change**, and a test pins the room's mesh hashes.
  Recompiled packages may change because they carry the additive model schema version;
  existing compiled version-1 records continue to load without recompilation.
- **`foundry:model` version 2** adds two optional fields: `skeleton`, an ID, and `clips`, a
  list of `{ name, clip }`. A model with a skinned mesh must name a skeleton. The clip list is
  how a game asks for "walk" by name without knowing a generated ID, as slots already map
  material names.

**Limits, all refused by name when exceeded:** 256 joints per skeleton, four influences per
vertex, and bounded track and key counts in a clip (`Limits`, as `.fmesh` has).

## 7. Import: glTF skins and animations (`author`)

Import stays the only code that knows glTF (ADR-0053). `foundry:model_import` gains no field
and no version: a file that has a skin imports it, and one that has none imports exactly as
before.

**Generated records** take ADR-0055's naming: `<model>.skeleton`, and `<model>.clip<i>` in the
file's animation order. The model's `clips` list carries each glTF animation's name. An
unnamed or duplicate-named animation is refused, since the name is how it is found.

**The skeleton** is the skin's joints, plus every node on the path between two joints, so the
hierarchy is closed. Those added joints influence no vertex. Joints are ordered parents first,
keeping the file's order among siblings, and vertex joint indices are remapped to match. The
transforms of nodes above the skeleton's root are baked into `root`; `front` is applied there
too, once, as M20 applies it to parts. Inverse bind matrices are read from the file, or are
identity when omitted, as glTF specifies (corrected before Step 3 below).

**Clips** keep the file's key times and values. Nothing is resampled. A channel is translated
into a track when its target is a joint of the model's skeleton.

**Refused, each with a diagnostic naming the object and the fix:**
- a skinned primitive whose joint or weight accessor is missing, the wrong type, or of unequal
  count; `JOINTS_1` or `WEIGHTS_1` (more than four influences);
- a joint index outside the skin; a vertex whose weights are all zero, negative or non-finite;
- more than one skin used by one model; more than 256 joints after closure;
- a skin whose joints do not form one tree; a non-invertible bind matrix;
- `CUBICSPLINE` interpolation ("bake to linear keys on export");
- key times that are unsorted, negative or non-finite; a rotation key that is not unit length
  beyond `Quat`'s tolerance.

**Warned and counted, never silent (ADR-0048):**
- weights that do not sum to one are normalised;
- a channel that targets a node outside the skeleton, or morph weights, is dropped;
- a non-joint node above the root that a clip animates is treated as static.

**Output depends on the source bytes alone** (ADR-0055). Two hosts importing the same file
produce identical `.fskel`, `.fanim` and `.fmesh` bytes, which §12 checks between the Mac and
the PC.

## 8. `rhi` and `render3d`: drawing a skinned mesh

**No shader changes, and no skinned variant.** `3d.md` §5 lists "the skinned variants of each"
shading model for M24, and §9 says skinning runs on the CPU. Both cannot be built: a mesh
skinned on the CPU reaches the vertex shader as plain positions, normals and tangents, which
the existing unlit, lit and shadow shaders already draw. This design follows §9 and corrects
§5. ADR-0054's slots 6 and 7 stay reserved for the day GPU skinning has its measured trigger;
until then `joints` and `weights` are CPU-side streams that are never bound.

**`rhi` gains one capability: vertex data written every frame.** A vertex buffer the CPU fills
each frame and the GPU reads in that frame, safe with two frames in flight. Step 4 pins the
exact form after reading both backends (a mappable vertex buffer per frame slot, or the existing
staging copy into a device-local one), states the null backend's rules for misuse, and proves
it on Metal and, compiling, on Vulkan. Nothing else in the RHI moves.

**`render3d`:**
- `createMesh` accepts a mesh with `joints` and `weights`. It keeps a CPU copy of the bind
  positions, normals, tangents, joints, weights and joint bounds, and uploads the other streams
  and the indices as today.
- `MeshDraw` and `ModelDraw` gain `skin: ?[]const Mat4`, the skin matrices for this draw,
  copied at submission. A skinned mesh drawn without them, or with the wrong count, is refused
  with a named error; an unskinned mesh given them is refused too.
- **Culling** uses the union of each joint's bound transformed by its skin matrix and the
  world matrix. It is conservative and costs eight corners per joint, with no vertex touched.
- **Skinning runs in `prepare`,** once per submitted instance that the camera or the shadow
  frustum kept, through `anim.skin` over `core.Jobs`, into the frame slot's vertex data. The
  colour pass and the shadow pass draw the same skinned vertices.
- **A per-frame budget,** `Config.max_skinned_vertices` (default 262,144). A draw that would
  exceed it is not drawn and is counted; it never truncates a mesh.
- `Stats` gains skinned draws, skinned vertices and draws dropped for budget. The profiler
  gains a `render.skin` zone.

`render3d` is granted `anim` in the build graph: an L3 module taking an L1 one, downward.

**Blended skinned draws** sort by the instance's bound centre, as unskinned ones do.

## 9. What the public ABI and the overlay gain

**Nothing enters the public ABI in M24.** `3d.md` §9's list for `FoundryApi_v6` (M25) does not
name animation. Whether v6 publishes poses, and in what shape, is M25's design to decide after
this Zig API has held for a milestone. The API is drawn for a table regardless: values and
caller-owned buffers, named refusals, no callbacks.

**The overlay gains two profiler zones and the new `Stats` fields,** through `render3d`, which
`debug` already sees. `debug` is not granted `anim`.

## 10. `sandbox3d`: a walker in the room

**The character is generated in-repo,** by `scripts/m24/make_character.py`, as M20's scene is:
a blocky figure of about 1.7 m (torso, head, two-segment arms and legs), around 19 joints and
under 2,000 vertices, with blended weights at the elbows, knees, hips and shoulders, and two
clips, `idle` and `walk`. It is authored by the repository, under its licence, and regenerates
byte-identically. It is deliberately plain: it has to show bending joints, not art.

**The walker is the sample's own record,** `sandbox3d:walker.main`, validated like M23's walk
record: the model, a list of waypoints in the room, a speed, and a cross-fade time. The dusk
mod does not override it.

**Each fixed tick,** the sample moves the walker toward its next waypoint with a second
`physics3d` character (so it collides with the room and the course), turns it to face its
motion, and chooses `walk` when it moved and `idle` when it is waiting at a waypoint. It
samples both clips at `tick × dt`, wrapped, blends them by a cross-fade weight that moves at a
fixed rate per tick, and keeps the pose. Each frame it submits the model with that pose's skin
matrices. Playback state is two integers and a weight in the sample; **no engine component is
declared** until a second consumer shows what one should hold (§14).

**The walker and the player do not collide.** They are on layers that ignore each other, so
M23's tour is untouched and its pinned hash, `cb99ccfcf2b6d6c3`, must not change. A test
asserts it.

**The tour grows a walker stage.** `FOUNDRY_SANDBOX3D_WALK=tour` also runs the walker for a
fixed number of ticks, checks that it reached its waypoints and that both clips and a
cross-fade were used, and hashes every tick's pose bytes and skin matrices. It then replays in
a fresh world and requires the same hash.

**Speed and stride are authored to agree,** by the generator, so the feet do not visibly slide.
Root motion is deferred.

**Reload:** a changed skeleton, clip or mesh rebuilds the walker's values, as `Walk.refresh`
rebuilds collision.

## 11. Platform assessment

- **Metal:** the first backend for per-frame vertex data and the skinned readbacks.
- **Windows/Vulkan, on the PC, is needed** for: per-frame vertex data under synchronization
  validation, which is the one new Vulkan path; the native x86_64 run of `anim`; the importer's
  bytes compared with the Mac's; and the walker windowed from a relocated install. The PC
  rules stand: check CPU use, `-j2` at below-normal priority, background jobs, a worktree.
  The owner's M24-only exception below permits testing while playing at CPU use below 90%,
  instead of the previous 50% cutoff; no foreground interruption is authorized.
- **Linux: compile only.** Nothing here is Linux-specific: no platform, window or loader
  change. `3d.md` §10.2 owes no run.

## 12. Verification

**`anim` (unit tests):**
- every `validate` refusal, for skeletons and clips;
- sampling: on a key, between keys, before the first and after the last, `step`, a joint with
  no track keeping rest, the shorter arc across a quaternion sign flip;
- `wrap` and `clamp`; `blend` at 0, 1 and between;
- `skinMatrices` on a three-joint chain against hand-computed matrices; a rest pose yielding
  the identity skin;
- **the skinning reference:** a bent two-joint strip whose skinned positions and normals are
  hand-computed, and a randomised fixture compared with an independent `f64` implementation,
  within 1e-5;
- skinning the same mesh inline and across chunked `Jobs` gives identical bytes;
- **the sampling replay:** a 1,200-tick run sampled and blended twice in one process, with
  every tick's bytes equal and one hash pinned per platform family if they differ;
- no function allocates.

**Guards verified by mutation,** each named in its step's Resolution: the parent-order check,
the rest-pose fallback, the shorter-arc choice, weight normalisation, the joint-index bound,
the skin-count check in `render3d`, and the budget refusal.

**`asset`:** a round trip and a pinned writer hash for `.fskel`, `.fanim` and a version-2
`.fmesh`; every `ReadError`; a newer version reporting `UnsupportedVersion`; version-1 `.fmesh`
files reading unchanged; model version 1 records loading unchanged.

**`author`:** fixtures built in-repo for a valid skin and each refusal and warning in §7; the
hierarchy closure and remapping; `front` applied once; the M20 room's and M23 course's output
hashes unchanged.

**`rhi` and `render3d`:** the null backend refusing misuse of per-frame vertex data; a skinned
readback on Metal and on Vulkan where a bent strip's pixel matches the CPU reference at 1× and
4×, lit and in shadow; a posed mesh culled and kept correctly at the frustum's edge; the budget
refusal counted.

**The sample:** the tour with its walker stage passes in `zig build test` (null), windowed on
Metal and windowed on Vulkan from relocated ReleaseSafe installs, dusk off and on; M23's hash
unchanged; both ad-hoc releases stage, since the sample gains asset kinds.

**Cost, measured and never estimated,** at ReleaseSafe, **inside the paced 60 Hz frame loop**,
which is how the owner reads a budget (2026-10-01), on the Mac and the PC: the median and p95
of the sample's `animation` zone (sampling, blending and skin matrices for one walker) and of
`render.skin`. **Budgets: p95 under 0.10 ms for `animation` and under 0.25 ms for
`render.skin`.** A run with sixteen walkers is measured and recorded without a budget, to show
how the cost scales. Exceeding a budget is the trigger in §14, not a reason to redesign.

**By hand:** a person watches the walker walk, turn, stop and cross-fade, and says so.

## 13. Implementation order — eight bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

### Step 1 — `anim`: skeletons, clips, poses, sampling, blending and the skinning kernel

§3, §4 and §5: the module in `build.zig` at L1, its values and validation, `sample`, `wrap`,
`clamp`, `blend`, `skinMatrices`, `modelMatrices` and `skin`, with §12's `anim` tests.
**Exit:** the sampling replay is byte-identical in one process, and the skinning reference
passes, with no device and no asset.

### Step 2 — `asset`: `.fskel`, `.fanim`, `.fmesh` version 2 and the model record

§6: the three formats, `foundry:skeleton` and `foundry:animation`, `uint8x4`, joint bounds,
`foundry:model` version 2, and their loaders. **Exit:** each format round-trips with a pinned
hash, every malformed file is refused by name, and every version-1 file reads unchanged.

**Implementation refinement (2026-10-01, before Step 2 code):** §6 originally put each
joint's box in joint-local bind space, while §8 transforms it by the skin matrix, which
accepts model bind-space points. Those spaces disagree. Joint boxes instead bound influenced
vertices in **model bind space**. Their transformed union conservatively encloses linear-blend
skinning with non-negative, normalized weights. An uninfluencing joint has a zero box.
This corrects the space, not the culling algorithm or the CPU-skinning architecture.

### Step 3 — `author`: glTF skins and animations

§7: the import, its refusals and warnings, and the generated IDs. **Exit:** a skinned glTF
fixture compiles to a skeleton, clips and a version-2 mesh that Step 1 samples and skins to the
fixture's known pose, every §7 refusal has a diagnostic, and the room's and course's hashes are
unchanged.

**Implementation refinement (2026-10-01, before Step 3 code):** §7's claim that glTF
defaults omitted inverse-bind matrices to inverse rest pose is incorrect. The
[Khronos glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)
defaults them to identity. Import follows that default. Skinned mesh-node transforms are
ignored as glTF requires; their model parts are identity, and the skeleton's root contains
the static ancestor chain with `front` premultiplied once. Original mesh positions and inverse
binds are kept in their matching space. Added closure joints influence no vertex and use
identity inverse binds. A mesh used both rigidly and skinned cannot share one generated
`.fmesh`; refuse it with a request to duplicate that mesh on export. Collision, when requested,
uses the imported rest-pose skin matrices, not the ignored mesh-node placement.

### Step 4 — `rhi`: vertex data written every frame

§8's one capability, on null, Metal and Vulkan (compiled and validated by `vulkan-check`).
**Exit:** a vertex buffer rewritten each frame draws correctly on Metal across frames in
flight, and the null backend refuses each misuse.

**Implementation refinement (2026-10-01, before Step 4 code):** use the existing staging
copy, not directly bound upload memory. `rhi.FrameVertexBuffer` owns one bounded upload/
device-local pair per configured frame slot. `update(frame, bytes)` validates the currently
open frame's index and slot, a nonempty prefix within capacity, and at most one update per
buffer per frame; it writes/unmaps staging, records the explicit copy and vertex-read
barriers, submits before returning the slot's ordinary vertex handle. Call it on the RHI
thread before opening passes. Collect all instance data before updating; draw offsets select
the instances. The returned handle is for that frame only, and only the written prefix may
be drawn. No mapping escapes, no completion timeline is added, and retirement stays with the
backend. A failed update consumes this frame's update opportunity; cleanup discards an
unsubmitted recording. Destroying the helper invalidates all its handles immediately.
The helper is engine-internal and changes neither the backend interface nor the public ABI.
Metal gains the same internal open-frame bit null/Vulkan already keep, so a stale token is
refused after `endFrame`, including an end failure; failed acquisition never sets that bit.

**M24-only PC permission:** the owner permits background tests while playing on Windows,
with the previous CPU-use refusal cutoff raised from 50% to 90%. Keep `-j2`, below-normal
priority and isolated worktrees; do not take focus or close games. This exception expires
at M24's close. Step 4's Vulkan evidence is compilation; native qualification remains Step 7.

### Step 5 — `render3d`: skinned meshes

§8: residency, `skin` on the draw structs, culling, skinning in `prepare`, the shadow pass, the
budget and `Stats`. **Exit:** the bent-strip readback matches the CPU reference on Metal, lit
and in shadow, at 1× and 4×.

**Implementation refinement (2026-10-01, before Step 5 code):** retain aligned CPU bind
streams and collect palettes in frame-owned storage. Budget admission is in submission order
over the union of camera/shadow survivors, once per draw; a draw skins its full mesh and both
passes share its offsets. One lazily allocated, fixed-capacity frame-vertex buffer holds
separate position/normal/tangent regions, preserving ADR-0054. Bounds include the accepted
weight-sum tolerance around one (scale the posed model-space union before world placement).
Models retain skeleton/clip asset handles and validate their current joint counts, including
after reload. `prepareSkin(frame)` is an idempotent preparation seam called by `prepare`;
`app.renderScene` may time that seam as `render.skin`, keeping the clock above the renderer
and workers. No new callback or platform dependency is needed.

### Step 6 — `sandbox3d`: the walker, on Metal

§10: the character generator, the walker record, patrol, cross-fade, the tour's walker stage,
reload and the measured cost on the Mac. **Exit:** the tour passes headless and windowed on
Metal from a relocated ReleaseSafe install, the pose replay hash is stable, and M23's hash is
unchanged.

### Step 7 — Windows/Vulkan on the PC

The native `anim`, asset, import and sample suites; the Vulkan skinned readback under
validation; the importer's bytes compared with the Mac's; the windowed tour from a relocated
install; the recorded cost; pack-up. **Exit:** every test and the tour pass natively on the PC
with validation clean, and replay is byte-identical on that machine.

### Step 8 — Close M24

This step:
- reconciles `3d.md` §5 (no skinned shader variants while skinning is on the CPU), §3's table
  (skeleton and clip rows) and §10's M24 row;
- adds `anim` to CLAUDE.md §4.3's layer table and `render3d`'s grant of it; moves ADR-0058 to
  Accepted and into §4.1; updates §9's 3D row;
- appends a dated note to ADR-0055 for the `skeleton` and `clip<i>` segments;
- updates AGENTS.md's bar if a step changed it, the roadmap, the design index and
  `PROJECT_STATE.md`;
- runs the bar and tags `m24`.

It pushes only when asked, and stops before M25's design. **Exit:** every document names M24
complete, and nothing names a contract the code does not have.

## 14. What stays open, deliberately

| Deferred | Returns when |
| --- | --- |
| GPU skinning (vertex-shader palette or compute), and skinned shader variants | `render.skin` measured above its budget at a character count a game has (`3d.md` §4's trigger) |
| An engine-declared animation component in `scene`, saved with a world | A second consumer of playback state exists, or M26's sample must save a pose |
| Animation in the public ABI | M25's design decides what `FoundryApi_v6` publishes |
| Root motion | A game whose character speed must come from its clip |
| State machines, layers, masks, additive poses, events | A game needs any of them; each is game logic over `sample` and `blend` first |
| Inverse kinematics (foot placement, look-at) | A game needs feet on M23's steps to look right |
| Cubic-spline keys | Real assets are refused for it often enough that baking on export is a burden |
| Morph targets | A game needs faces or blend shapes |
| Animated nodes that are not joints (rigid part animation) | A game needs an animated prop without a skin; it wants a model that keeps nodes |
| More than one skin per model; more than four influences; more than 256 joints | A real asset is refused for it |
| Inverse-transpose normals for non-uniformly scaled joints | A visible shading error on a real asset |
| Clip compression and key reduction | A shipped package's clip size, or sampling cost, measured as a problem |
| A third-person player body | M26's sample, if it is third-person |
| An animation panel in the overlay | Debugging a game's animation needs one |

## 15. Decisions acceptance fixes

Every choice is recommended as written. Nothing blocks Step 1 once these are accepted.

| # | Choice | Where |
| --- | --- | --- |
| 1 | A new L1 module, `anim`, on `core` alone: no asset, no entity, no renderer, no clock (ADR-0058) | §3 |
| 2 | Skeletons and clips are compiled assets, `foundry:skeleton`/`.fskel` and `foundry:animation`/`.fanim`, handed to `anim` as borrowed values | §3, §6 |
| 3 | Skinning is linear-blend, on the CPU, in `anim.skin`, run by `render3d` over `core.Jobs` | §5, §8 |
| 4 | **No skinned shader variants are built, correcting `3d.md` §5,** which lists them for M24 while §9 says skinning is on the CPU. Slots 6 and 7 stay reserved | §8 |
| 5 | `rhi` gains vertex data written every frame, and nothing else | §8 |
| 6 | `render3d` is granted `anim`; `debug` is not | §8, §9 |
| 7 | `.fmesh` version 2 adds `uint8x4` joints, `float32x4` weights and per-joint bounds; unskinned meshes are still written as version 1, so no existing mesh bytes change | §6 |
| 8 | `foundry:model` version 2 adds `skeleton` and a named `clips` list; one skin per model | §6 |
| 9 | Generated IDs are `<model>.skeleton` and `<model>.clip<i>`; `foundry:model_import` gains no field | §7 |
| 10 | Limits: 256 joints, four influences; cubic-spline keys, morph targets and non-joint node animation are refused or dropped with a warning, never converted silently | §7 |
| 11 | Sampling follows glTF: linear translation and scale, shorter-arc slerp, rest pose for untracked paths; time is seconds derived from the tick count | §4 |
| 12 | Blending is a two-pose cross-fade only | §4 |
| 13 | Playback state lives in the sample; no engine animation component and nothing in the ABI in M24 | §9, §10 |
| 14 | The character is generated in-repo; it is a second walker, on layers the player ignores, and the player stays first-person | §10 |
| 15 | Budgets are read inside the paced frame loop: p95 under 0.10 ms for `animation` and 0.25 ms for `render.skin`, one walker, both machines | §12 |
| 16 | The PC is needed (Step 7); Linux is compile-only | §11 |

## Resolution — Step 1: the `anim` module (2026-10-01)

**Acceptance.** The owner's request to begin Step 1 accepted §15 as written. ADR-0058 is
Accepted and is in CLAUDE.md §4.1. CLAUDE.md §4.3's layer table gains `anim` at the close
(Step 8), as planned.

**What exists.** `engine/src/anim/` at L1 on `core` alone, in `build.zig`'s layering table, with
`zig build anim-test`:
- `skeleton.zig`: `Skeleton` and `validate`;
- `clip.zig`: `Clip`, `Track`, `Path`, `Interpolation` and `validate`;
- `pose.zig`: `Pose`, `sample`, `wrap`, `clamp`, `blend`, `modelMatrices` and `skinMatrices`;
- `skin.zig`: the kernel `skin` and `validateInfluences`.

No module is granted `anim` yet. `render3d`'s grant is Step 5's.

**What the design had not settled, and the answers:**
- **The joint count is the slices' shared length,** `Skeleton.jointCount()`, not a stored
  field. §3 listed a `joint_count`; a field that can disagree with three slice lengths is one
  more thing to refuse.
- **A skeleton may have several roots here.** `anim` composes any parents-first forest. "One
  tree" is the importer's refusal (§7), where it has a diagnostic to give.
- **Inverse bind matrices and `root` must be affine,** with a last row of exactly `(0, 0, 0, 1)`,
  or `validate` refuses them. glTF requires it of bind matrices, and it lets the kernel skip the
  perspective divide.
- **`modelMatrices` includes `root`,** so it returns model space, which is what attaching to a
  joint needs. `skinMatrices` is then `model[j] · inverse_bind[j]`, in a second pass over the
  same buffer, with no scratch memory.
- **A clip's track values are flat `f32`s,** three per key or four for a rotation, so `.fanim`
  can hand its bytes over without a copy (Step 2).
- **Two tracks for one joint and path are refused** (`DuplicateTrack`), since the later would
  win silently. That bounds a clip at 768 tracks. A track holds at most 65,536 keys.
- **A sampled rotation is always unit:** a held key is normalised, as `slerp`'s result is.
- **Time outside a track holds; a time that is not a number holds the first key.** `wrap` and
  `clamp` return 0 for a time that is not finite.
- **`blend` clamps its weight,** returns the first pose exactly at 0 and the second exactly at
  1, and may write over either input.
- **Vertex influences have their own check, `validateInfluences`:** a weight negative or not
  finite, weights not summing to one within 1e-3, or a weighted joint the skeleton lacks. It
  lives here because `asset` cannot see `anim`; `render3d` calls it when a mesh is created
  (Step 5). A joint index beside a zero weight is never read, so it is not checked.
- **The kernel indexes its output as its input,** over full-length slices, and writes only the
  requested range.
- **"No function allocates" is structural:** nothing in `anim` takes an allocator.

**One finding about the toolchain, not about `anim`.** The replay is byte-identical within a
binary, which is I9's promise and this step's exit. Its hash, though, has **two** values on one
machine: Debug and ReleaseSafe builds for Apple silicon differ in the last bit of some
rotations. The cause was isolated: `@sin` is Zig's own routine in a Debug build and in both
build modes for x86_64, but binds to the system's `sin` in an optimised arm64 macOS build, and
the two differ by one unit in the last place on some inputs. `acos` and plain multiply-add
agree everywhere. It affects every caller of `@sin` in the engine equally (`Quat.slerp`,
`fromAxisAngle`, the rotation matrices), and ADR-0013 already declines to promise the last bit
across binaries. The test pins both values and names the reason. Nothing was changed in `core`.
Step 7 records which value the PC produces.

**Tests:** 19 in `anim`, with no device and no asset. Every `validate` refusal; sampling on a
key, between keys, outside the track, under `step`, with rest kept, and across a quaternion
sign flip; `wrap`, `clamp` and `blend`; a three-joint chain's model and skin matrices by hand,
with and without `root`; the bent strip's positions, normals and tangents by hand; three
randomised 1,000-vertex fixtures against an independent `f64` implementation within 1e-5; one
call against chunked `Jobs` in both orders at three grains, byte for byte; and the 1,200-tick
replay.

**Guards verified by mutation,** each restored afterwards: the parent-order check (fails the
skeleton refusals), the rest-pose fallback (fails the rest test and the replay), the
shorter-arc interpolation (fails the sign-flip test and the replay), the joint-index bound
(fails the influence refusals), the order of the skin-matrix product (fails both hand-computed
matrix tests and the replay), and the duplicate-track refusal (fails the clip refusals).

**The exit is met:** the sampling replay is byte-identical in one process, and the skinning
reference passes, with no device and no asset. The nine-command bar passes, every command
exiting 0. `anim-test` reports 19 of 19 in Debug and ReleaseSafe on arm64, and in both modes for
x86_64 under Rosetta. The whole graph's total was not re-counted: the 19 are added to the
1,972 declared at M23's close.

## Resolution — Step 2: compiled animation assets (2026-10-01)

**What exists.** `asset/skeleton.zig` and `asset/animation.zig` read and write canonical
little-endian assets. Readers allocate nothing and borrow arbitrary-alignment source bytes;
their `copy` methods and registered loaders own aligned arrays independent of the registry's
temporary source. `skeletonLoader`/`animationLoader` are opt-in like `collisionMeshLoader`.
No module gains `anim`; asset and animation representations meet as values in later steps.

**The wire shapes this step settles:**
- **FSKL v1:** a 16-byte header (magic, version, u32 joint count, u32 name-byte count), then
  108 bytes per joint (u16 parent, zero u16 reserved, ten f32 local TRS values, sixteen f32
  inverse-bind values), the sixteen-f32 root matrix, eight-byte name descriptors (u32 offset
  and length), then consecutive UTF-8 name bytes. Empty names are legal; NUL/invalid UTF-8
  are refused. Parents precede children; multiple roots are allowed as in `anim`. Matrices
  must be finite and affine and rest transforms valid. Limits cap at 256 joints, 65,536 name
  bytes and 1 MiB; a caller may lower, not raise, those caps.
- **FANM v1:** a 20-byte header (magic, version, f32 duration, u32 joint count, u32 track
  count); sixteen-byte track descriptors (u16 joint, u8 path, u8 interpolation, u32 key
  count, u32 time offset, u32 value offset); then each track's consecutive f32 times and
  values. Path/interpolation values match Step 1's enums. Limits cap at 256 joints, 768
  tracks, 65,536 keys per track, 8,388,608 total keys and 256 MiB. Zero tracks are legal;
  zero keys in a track are not. Times increase within the positive finite duration;
  duplicate joint/path tracks, non-finite values and non-unit rotations are refused.
  `checkJointCount` explicitly refuses pairing with a different-sized skeleton.
- **FMSH v2:** keeps the first 48 bytes of v1's header, adds u16 joint count, zero u16
  reserved and u32 joint-bounds offset, then the existing stream/submesh/index/stream layout.
  The tail is one six-f32 box per joint. Skin streams and boxes must appear together; only
  joints allow the new format value 4 (`uint8x4`). Weighted indices must exist, weights must
  be non-negative/finite and sum to one within 1e-3 (Step 1's rule), and each box must contain
  every position it influences. Zero-weight indices are ignored. Bounds are in **model bind
  space**, correcting the contradiction recorded before implementation above; consumers must
  account for the influence-normalization tolerance when constructing posed culling bounds.

All layouts reject gaps, overlap, reserved bytes, truncation and trailing payload. A newer
version yields `UnsupportedVersion`, not an identity refusal. Writers refuse invalid values
and retain no allocation on refusal. `.fmesh` still writes v1 when unskinned; the independently
calculated v1 fixture pin is `269a786092e3688b`. Recompiled FPKs may change because they carry
the model-v2 schema: §6's original "no package bytes change" could only apply to mesh bytes,
not package schema metadata. Existing compiled model-v1 records still load as v1.

**The records and integration.** `foundry:skeleton` and `foundry:animation` are source-only
v1 kinds deriving from `.fskel`/`.fanim`; the compiler's schema-name list includes both.
`foundry:model` v2 appends optional `skeleton` and `clips [{ name, clip }]`, leaving slots/parts
at their existing indices. Its v1 compiled-package compatibility test and a real compiler/
store/registry/load-by-ID test pass. Model/mesh/skeleton consistency and clip residency are
Step 5's consumer work, not a new privileged asset path. Until then `render3d.createMesh`
explicitly refuses skin data with `UnsupportedVertexFormat` before creating any resource.
There is no glTF skin import, playback, sample change, RHI change or ABI addition here.

**Evidence.** Eleven new asset tests prove every new read refusal, pinned writer hashes,
byte-identical write/read/write, unaligned borrowing, independent aligned ownership,
loader refusal/unload and allocation-failure cleanup, the 256-joint boundary and compiled
model-v1 compatibility. Pins: FSKL `5440b1836fce2465`, FANM `853e37fc92f939e7`, skinned FMSH
`c5990a7fc5a89641`. Focused suites pass in Debug and ReleaseSafe: **135/135 asset, 92/92 author,
57/57 render3d**. Thirteen guard mutations fail and are restored: parent ordering, rest
validity, affine inverse binds, UTF-8/NUL names, name offsets, joint cap, duplicate tracks,
time ordering, payload offsets, weight normalization, joint indices, influenced-position
containment and the pre-Step-5 residency refusal.

**Exit met.** The nine-command bar passes **2,003 of 2,004 tests**, one expected skip; native,
Metal and Linux/Windows cross checks and all three headless samples exit 0. Both ad-hoc
macOS releases stage (this is not certified public signing). Claude's Step 1 proof was accepted
without a separate baseline re-audit. Step 3 has not begun; Windows runtime is Step 7 and
Linux remains compile-only.

## Resolution — Step 3: glTF skin and animation import (2026-10-01)

**What exists.** `author/gltf/document.zig` reads typed skins, samplers and channels;
`skin.zig` validates the default scene's hierarchy, selects its one used skin, finds the
closest common ancestor, closes every path between joints and orders parents before children
in the file's sibling order. It retains names and remaps all four vertex joint indices.
`translate.zig` emits skinned `.fmesh` v2, `.fskel` and `.fanim` through the existing asset
writers, and generated text through the compiler's ordinary parser/checker. Model metadata
names `<model>.skeleton` and `<model>.clip<i>` in animation-array order. Private output paths
are `<source dir>/<stem>/skeleton0.fskel` and `clip<i>.fanim`; they are not identity.

**Resolved before implementation:** the glTF specification defaults missing inverse binds
to identity, not inverse rest pose. Original bind positions and inverse binds are retained;
added closure joints have identity inverse binds and no influences. Ancestors above the root
are baked into `root`, with `front` premultiplied once. Skinned mesh-node transforms are
ignored as glTF requires, and their parts are identity: reapplying placement would move the
pose twice. Meshes shared by rigid and skinned instances are refused with a request to
duplicate the mesh on export. Optional collision derives the rest-pose skinned positions;
it does not pretend to follow later playback.

**Validation and limits.** Diagnostics name the skin, node, primitive or channel and an
export fix. Missing/wrong/count-mismatched influences, additional influence sets, out-of-skin
indices (including zero-weight lanes), invalid/all-zero weights and duplicate nonzero
influences are refused. So are multiple used skins, disconnected joints, duplicate joints,
closure above 256 joints, invalid bind accessors and non-finite/non-affine/non-invertible
inverse binds. Clips refuse unnamed/duplicate names, unsupported/CUBICSPLINE interpolation,
invalid samplers/targets, non-increasing/negative/non-finite times, malformed TRS output,
duplicate tracks, non-finite values and non-unit rotations. STEP/LINEAR times and values are
kept without resampling. Non-skeleton channels and morph weights are dropped with counted
warnings; an animated ancestor above the root is explicitly reported static. Weight sums
are accumulated in f64 and normalized; deviations over 1e-6 report the affected vertex count.
Empty-duration clips are refused; a positive-duration clip with only dropped channels may
have zero tracks, matching Step 2. Unused skins are reported when no skin is used.

Typed JSON adds limits of 4,096 skins, 1,024 animations and 65,536 channels in total, with
samplers per animation also bounded at 65,536. Import-wide retained keys are capped at
8,388,608 (a caller may lower the cap), in addition to the format's per-track/clip bounds.
This prevents many clips sharing an accessor from multiplying retained keys without a bound.

**Evidence.** Seven importer tests cover hierarchy closure/remapping, sibling order, generated
records, repeat-import identical bytes, every §7 refusal, warning counts, omitted binds,
quantized weights, u16 joints, count limits and all allocation failures. The compiler adds a
real package test, proving generated records, asset files and deterministic recompilation.
`zig build animation-import-test` is a separate cross-layer binary (in `test` and `check`),
not an `author` import grant: it joins the imported skeleton/clip/mesh to `anim.sample`,
`skinMatrices` and `skin`, and compares a known pose with `front` off and on. Its four tests
include the document/accessor checks compiled in that binary. Focused Debug and ReleaseSafe
results: **100/100 author, 4/4 import-to-animation proof**.

**Fourteen mutations fail and are restored:** joint remapping, closure, bind invertibility,
duplicate clip names, key times, rotation validity, weight normalization, the import key cap,
joint indices, invalid weights, duplicate weighted influences, CUBICSPLINE refusal, ignored
mesh placement and `front` in the skeleton root. Deliberately removing closure or index
protection hits Debug bounds traps in the hostile-input proof; the restored importer refuses
those inputs normally. All restored-code checks pass.

**Exit met.** The nine-command bar passes **2,015 of 2,016 tests**, one expected skip;
native/Metal/Linux/Windows checks and all three headless samples exit 0. SHA-256 comparisons
match all eight room meshes, the crate mesh, all three course meshes and both collision
assets against their pre-step outputs. Both ReleaseSafe ad-hoc macOS releases stage; this
does not claim public signing/notarization. No RHI, renderer, ABI, sample or playback work
was added. Step 4 is next; Windows runtime/import-byte comparison remains Step 7.

## Resolution — Step 4: staged per-frame vertex data (2026-10-01)

**What exists.** `rhi/frame_vertices.zig` implements `rhi.FrameVertexBuffer` over the selected
backend. Initialization allocates a fixed upload/device-local vertex pair for each of the
device's configured 1–4 slots, refusing invalid capacity and cleaning up partial construction.
`update(frame, bytes)` checks the open frame's index, slot and surface handle before any
mapping; it refuses an empty/oversized prefix, a second update in that frame, or a dead owner.
It copies bytes into staging, unmaps (including Vulkan's non-coherent flush), submits the
existing explicit copy and copy-destination/vertex-read barriers, and returns the slot's
ordinary vertex handle. The caller draws only this frame's written prefix and collects all
instance data before updating. No mapping escapes, buffer capacity never grows, and the
backend remains the sole completion/retirement owner. Command recording may allocate through
the device's existing machinery; the helper reserves no second timeline.

**Resolution recorded before code.** Staged copies keep `rhi.md` §5's memory-intent discipline
and the same path on discrete and unified memory, rather than directly binding upload memory.
Metal lacked null/Vulkan's internal open-frame bit; it now sets it only after successful
acquisition and clears it before every end path, including failure. This supplies the live
token check without a new backend method. No backend interface, public ABI, shader, renderer,
sample or animation grant changes. A failed update consumes that frame's update opportunity,
discards an unsubmitted recording and relies on ordinary retirement. The null injected-failure
test demonstrates cleanup, not real device-loss recovery; that ADR-0035/0037 boundary remains.

**Evidence.** Six new null tests cover every helper refusal, the legal draw protocol,
premature staging reuse caught by rule 3, 1/2/4-slot reuse, all allocation failures, and
injected submit failure with no recording left open. Focused `zig build rhi-test` results are
**174/174 null, 195/195 Metal**, in Debug and ReleaseSafe. This focused target is also part
of the ordinary module test/check graph. Metal draws twelve frames without a per-frame idle
wait, alternating half-screen vertex positions and changing colour each frame. Distinct
images retain every frame's result; both lit and clear pixels match exact expected bytes
after the final wait. Vertex buffers are retired before that wait, proving their unfinished
uses retain the backing. Vulkan's new test instantiates the helper for all three tested ring
sizes; Step 4 compiles it, while native execution remains Step 7.

**Ten mutations fail and are restored:** the live-frame bit check, frame index, slot,
surface handle, byte-count bound, single-update guard, frame-slot selection, vertex-read
barrier, full-prefix copy and dead-owner check. The prefix-copy mutation fails Metal's pixel
proof, not merely a structural assertion. Restored-code focused and integration checks pass.

**Exit met.** All nine bar commands exit 0: **2,021 of 2,022 tests**, one expected skip;
native/Metal/Linux/Windows checks and the three headless samples pass. All five prescribed
Vulkan compile checks pass, including Windows/Linux backend tests and whole graphs, and
optimized Windows. No native Windows job was needed or started. No content, asset kind or
release description changed, so release restaging was not triggered. Windows synchronization
validation remains Step 7, Linux compile-only, renderer skinning Step 5. The M24-only 90%
background CPU permission is recorded above and expires at the milestone close. Step 5 has
not begun.

## Resolution — Step 5: renderer skin residency, preparation and drawing (2026-10-01)

**What exists.** `render3d` is granted `anim`. `skinning.zig` owns aligned copies of bind
positions, optional normals/tangents, joints, weights and model bind-space boxes; `createMesh`
uploads only the unchanged streams and indices. Slots 6/7 never enter a pipeline. Residency
and partial upload recordings clean up on failure, through ordinary backend retirement.

`MeshDraw.skin`/`ModelDraw.skin` are optional borrowed palettes copied at submission. A mesh
requires exactly its joint count, finite affine matrices, and skin data if and only if it is
skinned: `MissingSkin`, `InvalidSkinCount`, `InvalidSkinMatrix` and `UnexpectedSkin` are named
refusals before submission changes. Posed culling transforms joint-box corners and accounts
for the permitted 1±1e-3 weight sum before world placement, with roundoff padding. Its centre
also orders transparent draws. No skinned vertex is scanned for culling.

**The frame.** `plan` admits the union of camera/shadow survivors in submission order, charging
the full mesh once per draw against `Config.max_skinned_vertices` (262,144 by default; zero
disables skin draws). A refused budget draw is removed from both orders, never truncated.
`prepareSkin(frame)`, also called by `prepare`, joins `anim.skin` chunks of 1,024 vertices
through explicit `Config.jobs`. Chunks allocate nothing, read no clock and call no RHI. The
renderer lazily reserves `40 × max_skinned_vertices` CPU bytes and one Step 4 frame-vertex
helper; each frame packs separate contiguous position/normal/tangent regions into one bounded
prefix. Both passes bind each admitted instance's offsets into that same vertex buffer.
Unused direction regions are zeroed, and capacity never grows. A failed update is consumed,
not mistaken for successful preparation on retry. New draws/lights cannot change prepared data.

The host times the optional preparation seam as `render.skin`, nested under `render.write`;
the normal `prepare` call does not repeat it. This preserves the clock's layer rather than
adding a callback or a platform grant. `Stats.skinned_draws`, `skinned_vertices` and
`skin_budget_dropped` count preparation work (including shadow-only survivors), and the
overlay reads them without being granted `anim`.

**Models and reload.** `Content` retains skeleton and named-clip asset handles through the
ordinary private-loader path. Names are owned, nonempty and unique, with caps of 1,024 clips
and 65,536 total name bytes (callers may lower them). `skeletonOf`/`clipOf` borrow current
payloads only until the next reload; no payload pointer is stored. Mesh/rig/clip joint counts
are checked at acquisition and before drawing, so independent overrides cannot reach a kernel
assertion. A bad candidate preserves the established reload policy. Stale resident mesh
handles now return `InvalidMesh` before any parts, rather than unwrapping a missing count.

**Evidence.** Eight new renderer tests plus the replaced pre-Step-5 refusal test cover copied
residency/palettes, every palette refusal, submission-order budgets across camera/shadow
survivors, posed culling and transparent ordering, tolerance bounds under translated/reflected
placement, all allocation failures, consumed upload failure and multi-instance stream offsets.
Renderer suites pass **65/65 null and 65/65 Metal**, in Debug and ReleaseSafe. Metal draws the
bent two-joint strip against an independently calculated rigid CPU reference, lit and in shadow
at 1×/4×, with positive pixel witnesses, multiple ring reuses and a two-instance proof. The
first comparison caught in-place aliasing in the test's reference formula; preserving its
original x/y values fixed the reference, not the renderer or the tolerance.

`render3d-jobs-test` compares the actual call site's complete vertex prefixes under serial,
reversed and a four-worker pool, around the 1,024-vertex boundary, for two different palettes;
**1/1** passes in both modes. Two new model integration tests prove package-to-residency,
missing/incompatible rigs/clips, bounded/unique names, no-part palette refusal, healthy and bad
asset overrides, package reload with renamed clips, and stale handles. `model-content-test`
runs those **2/2** in both modes; the same tests remain in the normal integration graph.
This focused target filters M24 because its shared PNG helper also imports UI-theme tests;
an unrelated exact-colour assertion in the standalone ReleaseSafe binary differs by one ULP.
No existing test or tolerance was weakened, and the required repository graph is unchanged.

**Eighteen mutations fail and are restored:** palette count, finite and affine matrices,
budget admission, weight-tolerance bounds, mesh/rig and clip/rig pairing, clip count, duplicate
and empty/over-limit names, posed culling, position and normal stream offsets (Metal pixels),
failed-update retry, missing and unexpected skin, palette copying, and stale resident handles.
Removing count/budget/stale-handle guards reaches Debug traps in their hostile proofs; restored
code returns the named refusals. These are guard proofs, not device-loss recovery claims.

**Exit met.** All nine bar commands exit 0: **2,033 of 2,034 tests**, one expected skip.
Vulkan whole-graph Windows/Linux and optimized Windows checks pass (160/160 steps each),
compiling the new readbacks; Step 4's unchanged backend/shader proofs remain accepted. Final
review found the localized stale-handle unwrap; its fix passed the affected model tests and
cached test graph, without restarting unrelated audits. No native Windows job ran. No content,
asset kind or release description changed, so no release restaging was required. No shader,
backend interface or public ABI changed, no sample gained animation, and no new ADR was needed.
Step 6's walker/replay/reload/measurement has not begun; native Vulkan remains Step 7, Linux
compile-only, and the M24-only background/90% CPU permission remains in force.

## Resolution — Step 6: the generated walker on Metal (2026-10-01)

**What exists.** `scripts/m24/make_character.py` generates `models/walker.gltf`/`.bin`:
19 parent-first joints, a 1.7 m block figure, 360 vertices with blended influences at joints,
and named one-second idle/walk clips. It uses no downloaded asset and runs only as a developer
script. Two regenerations match SHA-256 (`d2fe090b…8c8d81` glTF, `48c337d9…e91652` binary).
The ordinary import/compiler/model path produces the skeleton, clips and mesh; the sample
reads none of the interchange representation.

The independent `sandbox3d:walker.main` record names the model, 2–16 bounded waypoints,
positive bounded speed and cross-fade time. The dusk mod leaves it alone. `walker.zig` owns
the model handle, collision character, fixed-capacity poses and palettes, and sample playback
state. Each tick moves through the same room/course collision world, faces actual motion,
samples at `tick × dt`, and cross-fades at a fixed rate. `animation` measures evaluation only;
`render.skin` remains the host's Step 5 seam. Asset payloads and converted tracks are borrowed
only within evaluation, never retained. Current rig/clip values are checked before anim's
programmer-only assertions. Failed evaluation clears the drawable pose.

**Routine details settled.** The walker uses collision layer 2/mask 1; the player ignores
layer 2, so neither affects the other. Waypoints pause for sixty ticks. The authored speed is
0.6 m/s, matching the generated approximate 0.6 m stride; no root motion was added. The first
trial route ran into the room's existing crate; its content waypoints were moved to the clear
side of the room, not through a collision exception. An unchanged record retains feet and
playback across refreshed assets, while a changed record restarts the patrol and proof counters.
Final review caught the initially retained counters on that restart; affected tests passed
after the localized fix, without restarting the integration bar. Missing records, named clips
or incompatible candidates disable the walker; a malformed source reload retains the registry's
healthy candidate under the established reload policy. No ADR or engine component was needed.

**Executable proof.** The tour now includes 2,100 walker ticks and a fresh-world replay,
hashing every joint's local TRS, every palette matrix, feet and blend weight without struct
padding. It reaches nine waypoints and exercises idle, walk and intermediate blends. The Mac
pins are `62ed8c026c20482c` in Debug and `fa431d9440d4cb2e` in ReleaseSafe, reflecting Step 1's
recorded math-library distinction, not a cross-binary determinism promise. Every tick's pose
and matrices match byte-for-byte in a same-binary replay. The player tour remains 495 ticks
and `cb99ccfcf2b6d6c3`, even with the walker in its world.

`sandbox3d-test` passes **16/16** on null (Debug/ReleaseSafe) and Metal (ReleaseSafe). Two new
tests consume the compiled sample package, exercise all setting/borrow-validation refusals,
healthy rig/clip/mesh source replacement, changed-record restart, malformed-source retention,
missing idle/walk names, incompatible clip pairing and disabled cleanup. **Sixteen mutations
fail and are restored:** model ID, speed, fade time, waypoint cardinality, finite/bounded points,
duplicate neighbours, rig validation, clip/rig pairing, failed-pose cleanup, tick-derived time,
player mask, patrol restart, track capacity, clip validation and missing idle/walk refusals.
Removing the track bound deliberately reaches a Debug bounds trap; restored input is refused
normally. A first clip-validation mutation was only a compile failure and was corrected to
demonstrate the runtime proof. Restored-code focused tests pass.

**Runs and costs.** The null tour passes. A ReleaseSafe Metal install was relocated and run
from outside the repository with Zig and the SDK off `PATH`; both base and the ordinary dusk
content package selected from its installed discovery root pass the complete tour/replay.
There were no skipped frames. This is not a new user-mod discovery proof (M22/M23 already
proved that). One surviving skinned draw contains 360 vertices, with no budget drops.
Costs below are median/p95 milliseconds from the last 240 frames inside the paced 60 Hz loop,
not from the unpaced replay or null's synthetic clock:

| Run | `animation` median / p95 | `render.skin` median / p95 |
| --- | --- | --- |
| One walker, base tour | 0.0043 / 0.0050 | 0.0171 / 0.0223 |
| One walker, dusk tour | 0.0236 / 0.0285 | 0.0853 / 0.1073 |
| Sixteen walkers, 600 frames, culling off | 0.1872 / 0.2037 | 0.2841 / 0.3155 |

Both one-walker p95 budgets pass. `FOUNDRY_SANDBOX3D_WALKERS=16` is explicit cost-run bootstrap:
sixteen independent characters/poses, visually fanned out so the instances can be seen. It
skins all 5,760 vertices with no budget drops. Sixteen has no budget; it does not itself
authorize GPU skinning or a crowd system. `WORKERS=0` was used for these cost runs.

**Exit met.** The nine-command bar passes **2,035 of 2,036 tests**, one expected skip; both
ad-hoc macOS releases stage. Neither artifact claims public certification. No Windows work
ran; native qualification, asset-byte comparison and PC costs remain Step 7, Linux compile-only.
The person's watch/walk/turn/stop/cross-fade check is not claimed and remains to be recorded
before milestone close. No engine animation component, ABI, shader or later-step work was
added. Step 7 has not begun.
