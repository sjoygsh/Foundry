# Design: M29 — Particles I: a CPU particle system with content-defined emitters

**Status:** Accepted 2026-10-23, when the owner asked for Step 1, with §14 as written. Steps 1–6 of §15's eight are done; their Resolutions follow §15.
**Date:** 2026-10-23
**Baseline:** `86456c9`, tag `m28`. M0–M28 are complete.
**Decisions:**
- These ADRs constrain it:
  - ADR-0063: runtime geometry is owned by handle, changes in place and stages through kept
    buffers.
  - ADR-0049: engine shading models are written by hand for each backend, behind a registry.
  - ADR-0056: emission and ambient are in cd/m², and lit output is pre-exposed.
  - ADR-0054: fixed vertex slots.
  - ADR-0036: explicit, deterministic jobs.
  - ADR-0041: engine record types live in `asset`, so `fpack` checks them without a renderer.
  - ADR-0058: a simulation below the renderer, with its state kept by the caller.
- It proposes [ADR-0064](../adr/0064-particles-are-a-simulation-drawn-through-runtime-meshes.md):
  - The simulation is an L1 module, `particles`, on `core` alone.
  - An emitter is a `foundry:particle_emitter` record that names an ordinary
    `foundry:material` for its look.
  - A running emitter is owned by handle in `render3d.Particles`, and is never content.
  - Particles reach the GPU as runtime meshes, written straight into kept staging and
    updated through `updateMeshFromStaged`.
  - One engine shading model, `foundry:shading.particle`, takes premultiplied colour from the
    vertex. Additive and covering particles therefore share one pipeline and one sort.

## 1. Purpose and boundary

The roadmap's row (`docs/ROADMAP.md`, Phase 6) is the contract:

> M29 | Particles I | A CPU particle system with content-defined emitters

Two other documents allocate work to M29 by name:
- `runtime-geometry.md` §12: "M29 decides whether it uses `updateMesh` or a ring of its own".
  §7 answers it: `updateMesh`, staged directly, with no ring.
- ADR-0063's context lists "M29's particles" as a consumer of runtime geometry. M29 is its
  first consumer in the engine itself.

Later milestones own the rest of the subject:
- M78, GPU particles;
- M79, ribbons, mesh particles and particle collision;
- M110, the particle editor;
- M48, publishing particles to mods;
- M49, their Lua binding.

**Runnable result.** `sandbox3d` gains an effects corner beside the generated one, each
effect a record in its package:
- **a torch**: an additive flame played from a flipbook sheet, over a smoke column that
  covers what is behind it and is lit by the room's ambient;
- **a spark burst**: velocity-stretched sparks under gravity, fired on a fixed tick cycle,
  and on **B**;
- **a fountain**: 10,000 live, blended, depth-sorted particles. It is the budget's load.
- **a moving emitter**: a world-space trail from an emitter carried on the orrery's moon,
  which leaves its particles where they were born.

A content-only test mod, `embers`, overrides the torch's records, so the flame changes colour
and rate with no code.

**Exit condition**, on Metal and on Windows/Vulkan, from a relocated install:
1. With every corner emitter live, about 11,000 particles, the particle work on the main thread
   has a p95 of at most 2.0 ms per frame. That is the step plus `prepare`, wall time including
   any wait on jobs.
2. The same emitter, seed and ticks give a pinned state hash. A replay from tick zero matches
   it, and so does a run at a different frame rate over the same ticks.
3. In a readback, a nearer blended particle covers a farther one in either submission order,
   and an additive particle adds to what is behind it.
4. An emissive particle's exposed output tracks EV100 exactly as an emissive lit surface's
   does, measured by readback at two exposures.
5. With `embers` enabled, the torch draws its overriding colour and rate. Reloading with **R**
   keeps every instance's handle and its live particles.
6. The tour's hash (`cb99ccfcf2b6d6c3`), the walker's (`62ed8c026c20482c`), the court's three
   endings and M28's corner measurements are unchanged.
7. Vulkan validation is clean throughout.

**What M29 builds:**
1. `particles`, an L1 module on `core` (§3), containing:
   - emitter descriptions as validated values;
   - the fixed-capacity store;
   - the deterministic step;
   - the expansion into sorted quads.
2. The `foundry:particle_emitter` record in `asset`, checked by `fpack` and decoded with named
   refusals (§4).
3. `foundry:shading.particle`, in MSL and in GLSL (§5).
4. `render3d.Particles`: instances by handle, their materials resolved through `Content`, a
   `prepare` that expands and uploads, a `draw`, culling, reload and counters (§6).
5. `sandbox3d`'s effects corner, the `embers` mod, and their measurements (§8).

**What M29 does not build**, each with the milestone that owns it (§13 has the full list):
- GPU simulation and expansion: M78.
- Ribbons and trails as strips, mesh particles, collision and sub-emitters: M79.
- Particles lit by the frame's lights, and particles receiving shadows: M79. Particles casting
  translucent shadows: M40.
- Soft particles that fade into the depth buffer: M81, which adds the depth prepass.
- Live emitter editing with a preview: M110. Until then, the M15 editor edits emitter records
  as it edits any record.
- The public table and Lua: M48 and M49 (§9).
- Particles drawn by `render2d`: M106 (§13).

## 2. What exists

Read from the code at `86456c9`.

- **No particle code exists** anywhere in `engine/`, `samples/` or `content/`.
- **Runtime meshes** (`engine/src/render3d/renderer.zig`, M28):
  - `updateMesh` keeps the handle. It reuses a stream's buffer when the new bytes fit its
    capacity, and reallocates only when they grow. It is refused with `error.InFrame` between
    `begin` and the end of `recordFrame`.
  - `reserveStaging(label, size)` lends a kept staging buffer, and `fillMeshStaging` writes a
    mesh's streams and indices into it in a fixed layout. `updateMeshFromStaged(handle, mesh,
    label, staged, prepared)` then submits a mesh that is already staged, with its submesh
    bounds in `PreparedMesh`, and does not validate it again.
  - M28 Step 6 measured the 129² water rewritten inline at 2.0 ms p95. Most of that was
    generating an `asset.Mesh` and copying it into staging, so the water moved to the pool.
- **Blending** (`renderer.zig`):
  - `AlphaMode` is `opaque`, `mask` or `blend`.
  - Blend draws use `BlendState.premultiplied_alpha` with depth writes off. They are ordered
    last, back to front by their bounds' centres, with ties broken by submission order
    (`drawLessThan`). Within one draw, triangles are drawn in index order.
  - The unlit and lit fragment shaders both premultiply (`value.rgb *= value.a`). So nothing
    can be additive today.
- **Shading models**: `Renderer.init` registers `foundry:shading.unlit` and
  `foundry:shading.lit` through `registerShadingModel`. A model declares the streams it
  requires, the material fields it reads, and its stages per backend. A material record names
  its model by content ID.
- **Light units** (`light.md` §3): emission and ambient are in cd/m², and lit output is
  pre-exposed by `FrameView.exposure_ev100`. Unlit output is display-referred and never
  exposed. The frame uniform carries `camera_exposure` and `ambient`.
- **Materials as content** (`render3d/content.zig`): `Content.acquireMaterial(id)` resolves a
  `foundry:material` with a reference count and rebuilds it when its texture's payload changes.
  It answers with the same handle across a reload. `contentChanged` re-resolves after **R**.
- **Engine records in `asset`**: `asset/ui_theme.zig` is the model for a record type that
  `fpack` checks and something above decodes. The schema's closed field types
  (`data/schema.zig`) include nested structs and lists of them. A vector is spelled
  `{ x … y … z … }` and a colour `{ r … g … b … a … }`.
- **Determinism tools**: `core.rng.Pcg32` (`init(seed, stream)`, `float01`, `split`), and
  `core.Jobs.run(count, task)` for fork-join over data-determined chunks (ADR-0036).
- **`sandbox3d`**:
  - `main.zig` steps on `app`'s fixed tick (`Step.tick`, `Step.delta`).
  - M28's corner sits at x = 20 (`generated.zig`).
  - The orrery's moon is an entity with a derived world transform.
  - Its test mods are in `testdata/mods/`: `dusk`, `orbiter` and `plinth`.
- **The overlay**: `debug/profiler_panel.zig` prints `Renderer.frameStats()` for 3D.

## 3. The simulation (`particles`, L1)

A new module, `engine/src/particles/`, granted `core` and nothing else. It sits beside
`anim`, for ADR-0058's reasons:
- no `asset`, because a description arrives as a value;
- no `scene`, because instances are the caller's;
- no `rhi` or renderer, because a particle's motion is not a rendering concept;
- no `platform`, so there is no clock to read (I9).

It allocates only in `System.init`, from the caller's allocator, at the description's
capacity.

### 3.1 The description

`particles.Emitter` is a plain value, validated by `Emitter.validate`, which refuses by name.
Its fields are §4's, one for one:
- **spawning**: rate, bursts, duration and loop;
- **each particle**: a lifetime range, a shape, a speed range, acceleration and drag;
- **looks over life**: a size range, size over life, a rotation range, a spin range, colour
  over life and an additive weight;
- **drawing**: facing and stretch, the space, the sheet, the capacity and the seed.

**Curves** are piecewise linear over a particle's normalized age `t ∈ [0, 1]`, with at most 8
keys. Keys strictly increase in `t`, the first is at 0 and the last at 1. A curve that is
absent is constant 1, or white and opaque for colour.

**Shapes**:
- `point`;
- `sphere`, with a radius, filled or on its `surface`;
- `box`, with a half-extent;
- `cone`, with a base radius and a half-angle about the emitter's local +Y.

A particle's initial direction is:
- for `point` and `sphere`, outward and uniformly distributed;
- for `box`, local +Y;
- for `cone`, within the cone.

Fountains and flames rise by default because the axis is +Y. −Z is forward for cameras and
lights (ADR-0048), but an emitter is neither.

### 3.2 The store and the step

`particles.System` holds the particles as parallel arrays, at most `capacity`:
- position and velocity;
- the tick of birth and the fraction of a tick it was born at;
- lifetime, size scale, rotation and spin;
- a 32-bit per-particle random value;
- a spawn serial.

`step(emitter, tick, dt, transform)` does four things, in this order:
1. **Ages and kills.** Age is `(tick − birth_tick + birth_fraction) × dt`, computed from ticks
   and never accumulated. A particle whose age reaches its lifetime is removed by compaction
   that keeps spawn order. Order is the iteration order, and the sort's tie-break uses it, so
   swap-removal is not used.
2. **Integrates the survivors.** It is semi-implicit Euler: `v += a·dt`, then
   `v *= 1 / (1 + drag·dt)`, then `p += v·dt`. In `world` space the acceleration is in world
   axes. In `local` space positions are kept in the emitter's frame and transformed only at
   expansion.
3. **Spawns.** The count due at tick `n` is
   `floor(rate × n·dt) − floor(rate × (n−1)·dt)`, plus any burst whose time falls in the
   tick, repeated per loop of `duration`. It is computed from the tick, so rounding never
   drifts.
   - Spawns within a tick get evenly spread birth fractions. They are also integrated back by
     that fraction, so a moving emitter leaves a continuous stream rather than clumps.
   - A spawn into a full store is dropped and counted. The oldest particle is never stolen,
     which would change the iteration order.
4. **Updates bounds.** It refits an AABB over live positions, padded by the largest size.

Randomness comes from one `Pcg32` per system, seeded from `(emitter.seed, instance stream)`
and drawn in a fixed order per spawn. `play`, `stop` (spawning ends and the live particles
finish) and `clear` change state only at a step.

**Determinism is interface contract** (I9). The same binary, description, seed, transforms and
ticks give the same bytes. Frame rate does not enter, because the caller steps once per tick.
`System.hash` is FNV-1a over the live arrays in order, and the tests and the sample pin it.
Across machines the last bit is not promised (ADR-0013), so the pin is checked on both
platforms and any difference is recorded, not assumed away.

### 3.3 Expansion

`expand(system, emitter, view, out)` writes one quad per live particle into caller buffers:
- position (slot 0, `float32x3`);
- UV0 (slot 3, `float32x2`), from the sheet frame;
- colour (slot 5, `float32x4`);
- `u16` indices, which are a fixed pattern.

It writes these into a caller buffer and nothing else.

- **Facing:**
  - `camera`: the quad spans the view's right and up, rotated by the particle's rotation.
  - `velocity`: the long axis is the velocity projected onto the view plane, lengthened by
    `stretch × speed`. Sparks use it.
  - `up`: the quad lies flat in the emitter's local XZ plane, for ripples and ground marks.
- **Sorting.** It is back to front by view depth, with ties broken by spawn serial, so the
  order is total and deterministic. It is used whenever the material blends. An opaque or
  masked emitter keeps spawn order, because depth testing orders it.
- **Colour.** The colour stored is premultiplied: `rgb × a` with alpha `a × (1 − additive)`.
  `additive` is 0 for a covering particle and 1 for a purely additive one, and anything between
  is a blend of the two (§5).
- **Sheet.** The frame is `floor(t × frames)` when `fps` is 0, or `floor(age × fps) mod frames`
  otherwise. It is laid out row-major from the top left, as `foundry:ui_theme` atlases are.

The expansion can be split into chunks over `core.Jobs`. Each chunk writes its own slice after
the sort, so the output does not depend on the worker count.

**Limits**: at most 16,384 particles per system, so 65,536 vertices index with `u16`. Curves
have at most 8 keys, bursts at most 8, and a sheet at most 64×64 frames.

## 4. Emitters as content (`foundry:particle_emitter`, `asset`)

The record type is the engine's, registered through the same call a mod's `@schema` uses (I6),
and its schema is in `engine/src/asset/particle_emitter.zig`. `fpack` checks a record with no
renderer linked, and `asset` decodes it into `asset.ParticleEmitter`. `render3d` converts that
into `particles.Emitter` field for field. Every name below is on authors' disks (CLAUDE.md §7).
Adding a field later is additive; renaming one is a break.

```fdt
foundry:particle_emitter sandbox3d:effects.torch_flame {
    material        sandbox3d:materials.flame      # a foundry:material whose shading is foundry:shading.particle
    capacity        256
    rate            90                              # particles per second
    bursts          [ { time 0  count 12 } ]        # seconds into each loop
    duration        1.0
    loop            true
    lifetime        { min 0.5  max 0.8 }
    shape           { kind "cone"  radius 0.05  angle 0.3 }
    speed           { min 0.4  max 0.7 }
    acceleration    { x 0  y 1.2  z 0 }             # m/s², in `space`'s axes
    drag            1.5
    size            { min 0.16  max 0.24 }          # metres
    size_over_life  [ { t 0  value 0.6 } { t 0.3  value 1 } { t 1  value 0.2 } ]
    rotation        { min 0  max 6.2832 }
    spin            { min -1  max 1 }               # radians per second
    color_over_life [ { t 0  color { r 1  g 0.7  b 0.3  a 0 } }
                      { t 0.15  color { r 1  g 0.6  b 0.2  a 1 } }
                      { t 1  color { r 0.6  g 0.1  b 0.0  a 0 } } ]
    additive        1
    facing          "camera"                        # "camera", "velocity" or "up"
    stretch         0                               # metres per m/s, for "velocity"
    space           "world"                         # "world" or "local"
    sheet           { columns 4  rows 4  frames 16  fps 0 }   # fps 0: once over each life
    seed            7
}
```

Each field has a default except `material`. A `shape` with no `kind` is `point`. Colours are
linear, like a material's `base_color`.

**Refusals** happen at compile and again at decode, because a mod is untrusted, and each has a
name:
- a capacity of 0 or above 16,384;
- a rate, time, size, speed, drag or seed that is not finite or is out of range;
- a `min` above its `max`;
- a lifetime that is not positive;
- an unknown `kind`, `facing` or `space` string;
- curve keys out of order, outside [0, 1], or more than 8;
- more than 8 bursts;
- a sheet whose `frames` exceeds `columns × rows`, or is above 4,096.

`material` is checked to name a `foundry:material` when the instance resolves it. A material
whose shading model does not take vertex colour and UV0 is refused there by name, because the
particle mesh supplies those two streams and no others.

## 5. The particle shading model (`render3d`)

`foundry:shading.particle` is registered by `Renderer.init` beside unlit and lit. It is written
by hand in `shaders/particle.metal` and in `particle.vert.glsl` / `particle.frag.glsl`
(ADR-0049, ADR-0038).

- **It requires** position, UV0 and colour.
- **It reads** `base_color`, `base_color_texture`, `emissive`, `emissive_strength` and
  `alpha_cutoff`. It reads no metallic, roughness, normal or occlusion field, and a material
  that sets them is accepted and ignores them, as unlit's is.
- **Output**:
  - The texel is premultiplied in the shader: `tex.rgb × tex.a`.
  - `L = tex.rgb × vcol.rgb × (base_color.rgb × ambient + emissive × emissive_strength)`.
    `ambient` is the frame's ambient luminance in cd/m², the term lit applies to a surface's
    base colour.
  - `rgb = L × pre-exposure`.
  - `a = tex.a × vcol.a × base_color.a`.
  - Because the vertex colour is already premultiplied (§3.3), a vertex alpha of 0 keeps its
    colour and adds it.
- **Exposure.** A flame authored at 2,000 cd/m² is bright at EV100 8 and modest in sunlight at
  EV100 15, as an emissive surface is (ADR-0056). Smoke authored with no emission is the room's
  ambient times its base colour, so it darkens with the room. That is why particles are exposed,
  and why the model is not unlit.
- **Alpha modes.** `blend` is the normal case. `mask` discards below `alpha_cutoff` and writes
  depth, for cut-out debris. `opaque` is accepted. Particles do not cast shadows: the model
  declares no shadow read, so a particle material never joins the shadow pass, whatever its
  `casts_shadow` says.
- **Backface culling is off** for every particle draw, because `velocity` and `up` quads can
  face away.

## 6. Running emitters (`render3d.Particles`)

A new file, `engine/src/render3d/particles.zig`. `render3d` is granted `particles` in
`build.zig`. That is one new edge, downward: L3 to L1.

```zig
var effects = render3d.Particles.init(gpa, &renderer, &content, limits);
const torch = try effects.create(.{ .emitter = id, .transform = world, .stream = 3 });
effects.setTransform(torch, moved);                   // any time
effects.stop(torch);  effects.play(torch);  effects.clear(torch);
effects.step(tick, dt, jobs);                         // on the simulation tick
try effects.prepare(view, jobs);                      // after the camera, before `begin`
try renderer.begin(view);
try effects.draw();                                   // inside the window: drawMesh per visible instance
```

- **Instances** are `EmitterHandle`s, `{ index, generation }`, owned by their creator
  (ADR-0063, ADR-0064).
  - `create` resolves the record and its material through `Content.acquireMaterial`, makes one
    runtime mesh, and validates.
  - A missing record, the wrong schema or a refused field is a named error, and nothing is
    made.
  - `destroy` inside the window is deferred to the window's end, as a runtime mesh's is.
- **`step`** steps every playing instance in handle order. Instances are independent, so with
  `jobs` they run in data-determined chunks of instances, and the result is the same bytes
  either way.
- **`prepare(view, jobs)`** handles each instance in three stages:
  - **Culling.** An instance whose bounds miss the view frustum is not expanded or uploaded,
    and its mesh keeps last frame's bytes. Culled instances are still stepped.
  - **Expansion.** Each instance with live particles reserves staging sized for its quads
    (`reserveStaging`), expands into it in the layout `fillMeshStaging` uses, and calls
    `updateMeshFromStaged` with its bounds.
  - **Jobs.** The expansions run as one fork-join over `jobs`; the uploads are submitted on
    the main thread afterwards.

  An instance with no live particles draws nothing.
- **`draw`** submits one `drawMesh` per prepared instance with its material. The renderer's
  existing order puts these last, sorted by bounds, with ties broken by submission.
- **Reload.** `contentChanged` re-reads each instance's record. The new description replaces
  the old at the next step, and the handle, the live particles and the seed's stream are kept.
  - When capacity shrinks, particles beyond it are removed oldest first by the same
    order-keeping compaction, and counted.
  - A record that a reload removed or broke leaves its instance stopped and drawing nothing,
    counted, until a reload restores it. That is `Instances.submit`'s rule for retained
    instances.
- **Counters** are folded into `Stats`:
  - `particle_emitters` prepared;
  - `particles` drawn;
  - `particle_emitters_culled`;
  - `particles_dropped` (a full store's refused spawns);
  - `particle_emitters_refused`.

  The overlay's 3D panel prints them.

## 7. Why `updateMesh`, staged directly, and no ring of its own

`runtime-geometry.md` §12 left this to M29. A ring persistently mapped for particles would
avoid one copy, from kept staging into a device-local buffer. But it would also be a second
upload path, with its own lifetime and frames-in-flight rules beside ADR-0063's, and §12 already
found no measured trigger for persistent mapping. What M28's inline water actually paid for was
building an `asset.Mesh` and copying it into staging. Particles skip that: the expansion writes
directly into the reservation. What is left is one GPU copy per visible instance, which the
renderer already submits for every updated mesh.

The index pattern is fixed, but `updateMesh` rewrites indices with the vertices. It is 12 bytes
a quad, about a quarter of the vertex bytes. If Step 5's measurement shows it matters, Step 5
adds a counted "indices unchanged" option to `updateMeshFromStaged`, inside this milestone.
Otherwise it stays as it is.

## 8. `sandbox3d`'s effects corner

All of it is in `samples/sandbox3d/effects.zig`. `FOUNDRY_SANDBOX3D_EFFECTS` takes `on` (the
default) or `off`. An unknown value is said aloud and treated as `off`, as M28's switch does.
The corner is off the tour's path and is not walked on, so the tour's hash is a check that
nothing else moved.

- **The records** are in `content/sandbox3d.fdt`:
  - four emitters, `sandbox3d:effects.torch_flame`, `torch_smoke`, `sparks` and `fountain`,
    plus `trail` for the moon;
  - their materials, each with `shading foundry:shading.particle`;
  - two textures: a 4×4 flame flipbook and a soft round puff. Both are generated by a
    developer script in `scripts/` and committed as PNGs, so the build never runs Python.
- **The sparks** fire a burst every 180 ticks and on **B**. They are `velocity`-faced, under
  gravity, and additive.
- **The fountain** is capacity 12,000, at a rate that holds about 10,000 live particles,
  blended and sorted. Its colour varies by each particle's random value through
  `color_over_life`.
- **The trail** is a `world`-space emitter whose transform the sample copies from the moon's
  world transform each tick.
- **`embers`**, in `testdata/mods/embers/`, is a content-only mod. It overrides
  `torch_flame`'s rate and `materials.flame`'s emissive colour.

**Measured** as M28 measured, from a relocated ReleaseSafe install:
- the main-thread wall time of `step` and of `prepare` each frame;
- `Stats`' particle counters;
- the state hash of the fountain at a pinned tick.

The sample prints these as summary lines that an evidence run reads. Nothing measured feeds
simulation.

## 9. The public ABI: nothing in M29

M48's line publishes what M27–M47 built in `FoundryApi_v8`, and its intent already covers
particles. A mod reaches M29's particles before that only as content: a package can add
`foundry:particle_emitter` records and override the sample's. A mod cannot create an
instance, because no table call exists. The C header is unchanged, and so is the ABI's call
count of 264.

## 10. Platform assessment

- **Metal**: the new shading model in MSL, and the readbacks of §11.
- **Vulkan on Windows**: the same model in GLSL, compiled to SPIR-V by the pinned SDK tools
  (ADR-0038). It needs the Arc PC: the budget is measured on its i3-10105F, and validation runs
  there, as in M28 Step 7.
  - The PC has had no Foundry clone since M27's close, so Step 7 re-clones into a worktree.
  - The rules are the usual ones: check it is idle, `-j2`, below-normal priority, and delete
    only exact Foundry paths afterwards.
- **Linux**: nothing in M29 is Linux-specific, so 3d.md §10.2 calls for no Linux run. The
  Linux null cross-check stays in the bar.
- **CPU difference**: the M-series Mac and the i3 differ most in the expansion and the sort.
  Criterion 1 is held on the slower machine.

## 11. Verification

- **`particles` unit tests:**
  - every `validate` refusal;
  - spawn counts per tick against the closed form, across loops and bursts;
  - age from ticks;
  - order-keeping compaction;
  - a full store drops new spawns and counts them;
  - each shape's distribution bounds;
  - curve evaluation at keys and between them;
  - each facing's quad corners for a known view;
  - sort order with tie-break;
  - premultiplied colour for additive 0, 1 and 0.5;
  - sheet frames in both modes;
  - bounds;
  - the state hash pinned;
  - replay from tick zero equal;
  - `local` against `world` space under a moving transform;
  - expansion over `core.Jobs` with 1, 2 and 4 workers equal byte for byte.
- **`asset`:** every compile refusal through `fpack`'s path and every decode refusal on a
  hand-made record; defaults; and a mod's override replacing a record whole.
- **`render3d`, null backend:**
  - create, step, prepare and draw;
  - `InFrame` refusals and the deferred destroy;
  - culled instances are not uploaded but still stepped;
  - reload keeps handles and particles;
  - capacity shrink;
  - a removed record stops its instance;
  - a material without the particle model's streams is refused;
  - counters.
- **Readbacks** on Metal, and with `-Drhi=vulkan` on the PC:
  - two overlapping blended particles in both submission orders: the nearer wins;
  - an additive particle over a known background adds;
  - one emissive particle at EV100 8 and 12 against an emissive lit quad: the ratio matches;
  - a `mask` particle writes depth.
- **The sample** (§8): criteria 1, 2, 5 and 6 from a relocated install, three runs each. The
  tour, the walker and the court are unchanged. Vulkan validation is clean, with synchronization
  validation on.
- The full bar (`AGENTS.md` §3) at every step. `fdt-check` covers the new record kind.

## 12. Hash pins and budgets

- **The fountain's state hash** is pinned at tick 600 in Step 1's test, with its own small
  description. The sample's own fountain is pinned at Step 6 on Metal and checked on Windows in
  Step 7. A difference across machines is recorded rather than forced (ADR-0013). It does not
  fail the exit unless the same machine disagrees with itself.
- **The budget** is criterion 1's 2.0 ms p95 for about 11,000 particles. Step 6 prints the
  share each part of the work takes:
  - the step;
  - the sort;
  - the expansion;
  - the uploads' submission.

  If the Mac or the PC misses it single-threaded, `core.Jobs` is the lever, and it is already
  in `step` and `prepare`. If it misses with jobs, ADR-0064's revisit condition has fired, and
  that is reported to the owner before M29 closes.

## 13. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| GPU simulation, GPU expansion, counts beyond 16,384 per emitter | M78 | Needs M75's compute |
| Ribbons and trails as strips, mesh particles, collision, sub-emitters and events on death | M79 | Sub-emitters are added to M79's intent at the close |
| Particles lit by the frame's lights, and receiving shadows | M79 | Added to M79's intent at the close |
| Particles casting translucent shadows | M40 | Its line already names translucent shadows |
| Soft particles (depth fade) | M81 | Needs the depth prepass M81 adds; added to its intent at the close |
| Live emitter editing with a preview | M110 | The M15 editor already edits records |
| `particles` in the public table, and in Lua | M48, M49 | §9 |
| Particles drawn by `render2d` | M106 | Added to M106's intent ("2D scenes") at the close; `particles` already sits below `render2d` |
| An engine component that carries an emitter on an entity | M103 | Beside its "draws this model" component |
| Exact ordering between two interpenetrating blended emitters | Not planned | A limit of sorted transparency, recorded in ADR-0064; its revisit names when it would need a decision |

## 14. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | A new L1 module, `particles`, on `core` alone, holding the simulation and the expansion; `render3d` is granted it | §3, ADR-0064 |
| 2 | Emitters are `foundry:particle_emitter` records in `asset`, with §4's field names; their look is an ordinary `foundry:material` | §4 |
| 3 | Instances are owned by handle in `render3d.Particles`, never content and never saved; their destroy inside the window is deferred | §6, ADR-0063 |
| 4 | Time comes from ticks, spawn counts from a closed form, and compaction keeps spawn order; a full store drops new spawns and never steals the oldest | §3.2 |
| 5 | Particles reach the GPU through `updateMeshFromStaged`, written straight into kept staging, with no ring of their own. This answers `runtime-geometry.md` §12 | §7 |
| 6 | `foundry:shading.particle`: premultiplied vertex colour with an `additive` weight, so additive and covering particles share one pipeline; exposed emission plus ambient; no shadows; no culling | §5 |
| 7 | At most 16,384 particles per instance (`u16` indices); curves of up to 8 keys | §3.3 |
| 8 | A cone's axis and a box's direction are the emitter's local +Y | §3.1 |
| 9 | 3D only: `render2d` drawing particles goes to M106 | §13 |
| 10 | Lit and shadow-receiving particles and sub-emitters go to M79, soft particles to M81, and an emitter component to M103. The roadmap's intent columns gain these "also" clauses at the close | §13 |
| 11 | The exit budget is 2.0 ms p95 of main-thread particle work at about 11,000 particles, held on the Arc PC | §1, §12 |
| 12 | No ABI change; the call count stays 264 | §9 |
| 13 | Eight steps, in §15's order | §15 |

Once these are accepted, nothing blocks Step 1.

## 15. Implementation order — eight bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `particles`: the description and the step

Add the module and its `build.zig` entry, `particles.Emitter` with `validate`, `System` and
`step`. That is §3.1 and §3.2. Tests: §11's `particles` items up to replay, including the
pinned hash. Verify the compaction's order guard and the spawn closed form by breaking each.
**Exit:** an emitter stepped 600 ticks from a seed matches its pinned hash twice and after a
replay, and every refusal has a test.

### Step 2 — `particles`: expansion

`expand`, covering the three facings, the sort, premultiplied colour, sheet frames and bounds
(§3.3), with the `core.Jobs` split. Tests: §11's expansion items, including 1/2/4 workers
byte-equal.
**Exit:** a known system expands to pinned vertex bytes for each facing, identically at
every worker count.

### Step 3 — `asset`: `foundry:particle_emitter`

The schema, `fpack`'s check, `asset.ParticleEmitter` and its decode with named refusals (§4),
and `fdt-check` coverage. Tests: every refusal at compile and at decode, defaults, and an
override.
**Exit:** §4's example compiles and decodes to the expected value, and each refusal names its
field.

### Step 4 — `render3d`: the particle shading model

`foundry:shading.particle` in MSL and GLSL (§5), registered by `Renderer.init`. Tests: model
registration and the stream refusal on null; the Metal readbacks of §11. The Vulkan check
compiles and validates the SPIR-V on the Mac.
**Exit:** on Metal, the nearer blended particle wins in both orders, additive adds, and the
emissive ratio at two exposures matches the lit quad's.

### Step 5 — `render3d.Particles`

`create`, `step`, `prepare`, `draw`, `destroy`, culling, reload and counters (§6), and the
`render3d → particles` grant. Measure whether rewriting the indices matters (§7) and decide it
here. The overlay prints the counters. Tests: §11's `render3d` items on null.
**Exit:** an instance is created from a record, stepped, culled, prepared and drawn, and a
reload keeps its handle and particles, all on null with every refusal tested.

### Step 6 — `sandbox3d`: the effects corner, proved on Metal

`effects.zig`, the records, materials and textures, the generating script, the `embers` mod and
the measurements (§8). Pin the fountain's hash at its tick.
**Exit:** criteria 1–6 hold on Metal from a relocated ReleaseSafe install, three runs each.

### Step 7 — Windows/Vulkan

Re-clone on the PC, then run the suites, the `-Drhi=vulkan` readbacks, the relocated sample with
and without validation, the tour, the walker and the court.
**Exit:** criteria 1–7 hold on the Arc A750, validation-clean, with the fountain's hash checked
against Metal's and any difference recorded.

### Step 8 — Close M29

Resolve the contract discrepancies where they were written:
- `runtime-geometry.md` §12's "M29 decides" row;
- ADR-0063's context;
- the intent lines of M79, M81, M103 and M106 in `docs/ROADMAP.md`.

Then:
- move ADR-0064 to Accepted and into `CLAUDE.md` §4.1;
- add `particles` to §4.3's layer graph, and `render3d`'s new edge;
- update §9's deferred row;
- update `AGENTS.md`'s bar if a step changed it;
- update the ROADMAP's M29 row, the design index, the README and `PROJECT_STATE.md`;
- pack up the PC by exact path.

Tag `m29`, push when asked, and stop before M30's design.

## Resolution — Step 1: the description and the step (2026-10-23)

**What exists.** `engine/src/particles/`, an L1 module on `core` alone, in `build.zig`'s
layering, with a `particles-test` step:
- `emitter.zig`: `Emitter`, with §4's field names, and `validate`, which refuses by name. It
  also has the curve evaluation (`sizeAt`, `colorAt` and `maxSizeFactor`) that Step 2's
  expansion reads.
- `system.zig`: `System`, a `std.MultiArrayList(Particle)` set to its capacity at `init` and
  never grown. It has `step`, `play`, `stop`, `clear`, `hash` and the `Counts` that Step 5 folds
  into `Stats`.
- `trig.zig`: the module's own sine and cosine (below).
- `tests.zig`.

The module has no expansion, no record, no shader and no `render3d` edge yet; Steps 2–5 add
them.

**Where the step sharpened §3.2:**
- **Birth is an exact instant, not a tick and a fraction.** A particle stores `birth`, in `f64`
  seconds since tick zero:
  - a continuous spawn `m` is born at exactly `m / rate` on its timeline;
  - a burst is born at exactly `k·duration + time`.

  Age is `tick·dt − birth`. "Evenly spread fractions" became these exact instants, which are
  what the closed form already counts.
- **The interval is `[from, to)`**, so a burst at time 0 and the rate's `m = 0` fire at a
  timeline's first step. The count due is `ceil(rate·to) − ceil(rate·from)`.
- **A timeline begins one tick before its first step.** That first step covers `[0, dt)` and
  ends at its own tick's time. The origin is therefore signed, because a system first stepped
  at tick 0 starts at −1. A test pins it: the burst and the rate's first spawn are born at
  −dt.
- **A gap between steps is one interval.** It spawns exactly what each tick would have spawned,
  and integrates survivors in one stride. Ticks must increase and `dt` must not change; either
  mistake is the caller's, and an assertion catches it.
- **A moving emitter.** A world-space spawn is placed between the previous and the current
  transform, at its fraction of the interval. It is then integrated from its birth to the end
  of the tick. A spawn whose life ends inside that remainder is not stored, but it still
  consumed its draws, so it never shifts the next particle's.
- **The draw order is fixed per spawn:** lifetime, speed, size, rotation, spin, a 32-bit
  random, then four shape draws for every shape.
- **A lower capacity removes the oldest first.** It is counted as `shrunk`. §6 needs this for
  reload, and it is a property of the step, so it is here rather than in Step 5.
- **The minimum loop is 1 ms** (`min_duration`). Without it, a hostile record could make one
  tick walk unbounded loops of bursts.
- **The tie order cannot be observed.** Which goes first when a burst and a continuous spawn
  coincide makes no difference: particles born at one instant draw and are stored alike. The
  mutation that reversed it passed every test, as an equivalent mutant must. The comment no
  longer claims an order.

**Trig is the module's own.** The first pin differed between Debug and ReleaseSafe on the Mac.
Bisecting showed that the module's arithmetic agreed with itself in both. The difference was
the test's own `@sin` input: `@sin` lowers to whichever `sinf` a binary resolves, which is
`public3d.md`'s Step 5 math-pin finding. Rather than carry two recorded variants, as the walker
does, `trig.sinCosTurns` computes sine and cosine from `f64` add, multiply and floor alone, and
the shapes and the pinned test use it. It agrees with `std` to 1e-14 across ±2 turns.

The pin `0xc9fa8e13b9c40c85` holds:
- in Debug, ReleaseSafe and ReleaseFast on the Mac;
- in an x86_64-macos build run under Rosetta.

Step 7 checks it natively on the PC.

**The pinned run** is 600 ticks at `dt = 1/64`, which is a power of two, so tick times and the
closed forms are exact. It uses:
- a cone;
- rate and three bursts over 1.5 s loops, one of them at each loop's start;
- gravity and drag;
- varied lifetimes, sizes, rotations and spins;
- a moving transform.

It matches twice and differs for another instance stream.

**Mutations.** Each was made, watched to fail, and restored byte for byte:
- removal that reorders the survivors failed "removal keeps spawn order" and the pin;
- `floor` in place of the `ceil` closed form failed the tick-by-tick count and the pin;
- a full store stealing its oldest particle failed the drop test.

**Bar:** **2,264/2,265** (one skip, M27's), the full bar: `zig fmt --check`, `zig build test`, the four `check` variants, the four 30-frame headless runs and `fdt-check`, all exit 0. Thirteen of the new tests are `particles`'.

## Resolution — Step 2: expansion (2026-10-24)

**What exists.** `engine/src/particles/expand.zig` provides `Expander`, `View`, `Output` and
`Expanded`, with tests in `expand_tests.zig`:
- `Expander.init(gpa, capacity)` allocates the sort keys once.
- `expand(system, emitter, view, .{ .sorted, .transform }, out, jobs)` writes four vertices
  (position, UV0, colour) and six `u16` indices per live particle. It returns the quad count
  and the exact bounds of every vertex written.
- `View.fromCamera(world)` takes a camera's world transform. Forward is its −Z.

**Where the step sharpened §3.3:**
- **Output is world space.** A `local` emitter's particles are carried by the transform during
  expansion, so Step 5 draws each mesh with an identity world. Its bounds are the vertices' own
  rather than the step's padded box.
- **The expansion reads the time of the system's last step**, `last_tick · dt`, with no
  interpolation. Expanding a system that holds particles but was never stepped is a
  programmer error.
- **The caller chooses `sorted`.** Step 5 sets it from the material's alpha mode: blend sorts,
  opaque and mask keep spawn order.
- **Size is the quad's side**, so each half-axis is `size/2`. The step's bounds padding,
  `size·√½`, is that quad's half-diagonal.
- **`velocity` facing:**
  - The long half-axis is `size/2 + stretch·|v|/2`, so the full length is
    `size + stretch × speed`, with speed the full 3D speed.
  - The wide axis is `forward × long`.
  - A particle moving straight along the view, or not at all, has nothing to stretch along. It
    falls back to an unrotated camera-facing quad.
- **`up` facing** uses the emitter transform's X and Z axes, normalized, so a tilted emitter
  tilts its quads. Rotation and spin turn the quad within that plane, as they do for `camera`.
- **The sheet's top row is v = 0.** Corner 0 (−right, −up) takes the frame's lower-left UV.
  Frames are row-major from the top left. `fps` 0 is `min(frames−1, floor(t·frames))`;
  otherwise `floor(age·fps) mod frames`.
- **Corners** are (−a−b, +a−b, +a+b, −a+b), indexed 0-1-2 and 0-2-3. Winding does not matter,
  because §5 disables culling.
- **The split:**
  - The sort runs first, on the calling thread: `pdq` over `(depth descending, serial
    ascending)`, a total order, so an unstable sort is deterministic.
  - `core.Jobs.forChunks` then writes chunks of `grain = 256` quads of that order.
  - Each chunk writes only its own vertex and index ranges and its own bounds slot, and the
    slots are merged in chunk order.

**Determinism.**
- Rotation goes through `trig`, as Step 1's shapes do.
- The tests compare four executors: `serial`, `reversed`, and a test-only executor with real
  threads pulling chunks from a shared counter (2 and 4 workers). They agree byte for byte on
  2,013 quads (8 chunks) for every facing.
- The pins are FNV-1a over the four streams in order:
  - `camera` `0x1fd9087640e501cb`;
  - `velocity` `0xe06311a79d0f8f5e`;
  - `up` `0x762af06190750a2f`.

  They hold in Debug, ReleaseSafe and ReleaseFast, and on x86_64 under Rosetta.

**Mutations.** Each was made, watched to fail, and restored byte for byte:
- removing the serial tie-break failed the sort test;
- merging only the first chunk's bounds failed the bounds check in the worker-count test;
- dropping the premultiplication failed the colour test and the pins.

**Bar:** **2,272/2,273** (one skip, M27's), the full bar, all exit 0; eight of the new tests are the expansion's.

## Resolution — Step 3: `foundry:particle_emitter` (2026-10-24)

**What exists.** `engine/src/asset/particle_emitter.zig` holds:
- the version 1 schema;
- `registerAll`;
- `ParticleEmitter`, a decoded value with fixed arrays, so it owns what it says and needs no
  allocator;
- `decode(fields)`, `validate` and `describe`.

The schema is registered where `foundry:ui_theme` is: `app.Engine`'s content load,
`author.compiler.registerAvailableSchemas`, and `engine_schema_names`. That makes it available
to every package, the editor and `fpack`. §4's example compiles and decodes to exactly the
values it says.

**Where the step sharpened §4:**
- **Defaults.**
  - Scalars and strings carry their defaults in the schema, so the editor shows them.
  - The nested fields (`lifetime`, `speed`, `size`, `rotation`, `spin`, `shape`,
    `acceleration`, `sheet`) are optional, and an absent one takes `ParticleEmitter`'s
    default, which is the simulation's.
  - A nested field that is present fills what it omits from its own inner defaults: `shape {
    kind "sphere" }` is a sphere of radius 0, and `extent` defaults to zero per axis.
  - `material` is required, so a record without one fails the schema check, before any of
    this.
- **"Refused at compile" is a new compiler stage.** The compiler checked types only: a
  material's `alpha_mode` string is refused only when `render3d` decodes it.
  - `compile` now has a step 5. After writing the package, it reopens the written bytes and
    runs the engine's own `decode` on every `foundry:particle_emitter`.
  - Each refusal is reported at the defining record's line, as "particle emitter '<id>'
    <describe>", and every bad record is reported, not only the first.
  - On failure the written bytes are dropped and the compile is `ContentInvalid`.
  - `fpack`, the editor's workspace builds and the dependency compiler all go through
    `compile`, so they refuse alike.
  - `@patch` does not load yet (`check.zig`), so there is nothing to patch-check. Decoding
    the written package rather than the declarations is what will make a patched result the
    thing checked when it does.
- **Two rule sets, and a guard between them.** ADR-0064 keeps `asset` and `particles` apart,
  so `asset` restates the simulation's limits and rules in `validate`.
  `engine/tests/particle_emitter.zig` stands above both, with `particles` newly granted to the
  integration module. It checks four things:
  - every limit is equal;
  - every refusal name exists in `particles.Error`;
  - a record naming only its material converts to `particles.Emitter{}` field for field;
  - both validators give the same verdict across the boundaries of every numeric field, every
    sheet shape, bursts, curve shapes and colour alpha.

  The record adds three refusals of its own: `UnknownShape`, `UnknownFacing` and
  `UnknownSpace`, plus `Unreadable` for a block that disagrees with its schema.
- **Strings are matched exactly**, as `alpha_mode` is: `"Cone"` is unknown.

**Mutations.** Each was made, watched to fail, and restored byte for byte:
- loosening the record's duration rule failed the agreement test ("record says '',
  simulation says 'InvalidDuration'");
- changing the simulation's rate limit failed the limits test and the agreement test;
- skipping the compiler stage failed both compiler tests;
- defaulting an unknown facing failed the refusal test.

**Bar:** **2,282/2,283** (one skip, M27's), the full bar and `editor-workflow` (the editor builds through the changed compiler), all exit 0; ten new tests: five in `asset`, two in the compiler, three in the integration suite.

## Resolution — Step 4: the particle shading model (2026-10-24)

**What exists.** `Renderer.init` now registers `foundry:shading.particle`
(`render3d.particle_id`) after unlit and lit:
- `shaders/particle.metal` and `shaders/particle.frag.glsl` hold `fragmentParticle` and
  `fragmentParticleMask`. The GLSL is built twice, with `-DMASK=1` and with `-DNO_MASK=1`.
- `fshadercheck` has two new profiles, `particle_fragment` and `particle_mask_fragment`. They
  check unlit's fragment interface and material slots, the light frame's offsets, and
  `emissive_strength` at offset 48.

**Where the step sharpened §5:**
- **The vertex stage is unlit's `vertexUvColor`, unchanged.** It takes position, UV0 and colour
  and outputs UV and colour, which is everything the particle fragment reads. So there is no
  particle vertex shader on either backend.
  - On Metal, that stage comes from unlit's library and the fragment from
    `particle_metallib`. The Metal backend already looks up each stage in its own library.
  - The model requires position, UV0 and colour, with nothing optional, so it has one vertex
    variant and two fragment variants (blend or opaque, and mask).
- **The ambient term is `base_color.rgb × frame.ambient`.** Lit's ambient includes a split for
  reflections off a smooth surface (Fresnel, via the DFG lookup); a camera-facing quad with no
  normal has nothing to evaluate that against, so the particle model takes only the plain
  diffuse part. Emission is lit's exactly: `emissive.rgb × emissive_strength`, packed as
  `emissive_strength.xyz` with the strength in `.w`. The result is multiplied by
  `camera_exposure.w`, as lit's is.
- **`base_color.a` scales both the colour and the opacity**, because output is premultiplied.
  The texel is premultiplied in the shader; the vertex colour is not touched again.
- **A mask on an additive particle discards it entirely.** Its alpha is 0, so masking only
  makes sense for covering particles.
- **"No culling" is a model feature, `ShadingFeatures.two_sided`.** A material's
  `double_sided` stays as it was, and a two-sided model ignores both it and a reflected world.
- **"No shadows" is a rule in the renderer, not only a declaration.** The shadow fit and the
  shadow order now ask `castsShadow`: the material's `casts_shadow` and its model's
  `reads.casts_shadow`. Unlit and lit both read it, so nothing they do changes. A particle
  material that says `casts_shadow true`, even masked, is never a caster.
- **Validation is `buildMaterial`'s.** Because the model reads `emissive`, emissive channels
  must be in 0–1 and the strength finite and non-negative, as for lit. The base colour is in
  0–1. A mesh without UV0 or colour is refused with `MissingStream`.

**Tests.**
- **Null:** the model is registered. A mesh without UV0 is refused. A particle draw is never
  culled, even with a reflected world. A masked particle claiming `casts_shadow` stays out of
  the shadow order, while a lit quad beside it is in.
- **Readbacks** run on Metal now and with `-Drhi=vulkan` on the PC in Step 7:
  - **Submission order:** two blended particles over an unlit grey backdrop give the same image
    in either order, and the centre pixel is the CPU's premultiplied composite.
  - **Additive:** an alpha-0 particle adds its colour to the grey.
  - **Mask:** a masked particle with a half-empty texture writes depth where it is drawn, so
    the farther opaque quad shows only through the hole.
  - **Exposure:** an emissive particle at EV100 8 and 12 equals both the CPU's exposed emission
    and an emissive lit quad.
  - **Ambient:** a particle with no emission is ambient times its base colour.
- Three existing tests counted the built-in models and now expect three.

**Mutations.** Each was made, watched to fail, and restored byte for byte:
- premultiplying the vertex colour again failed the readback test (the additive pixel);
- removing exposure failed the light test;
- ignoring `two_sided` failed the null test;
- letting `casts_shadow` alone decide failed the null test.

**Bar:** **2,285/2,286** (one skip, M27's) on the null bar, all exit 0. The whole graph under `-Drhi=metal` is 2,295/2,307, with 12 backend-conditional skips; the new readbacks ran there. All five Vulkan checks passed on the Mac with the SDK tools on PATH: `vulkan-check` and `check` for Windows and Linux, and `check` for Windows ReleaseSafe. Native Vulkan readbacks are Step 7's, on the PC.

## Resolution — Step 5: `render3d.Particles` (2026-10-24)

**What exists.** `engine/src/render3d/particles.zig` provides `render3d.Particles`, with
`ParticleEmitterHandle` and `ParticlesLimits`. `build.zig` grants `render3d` the `particles`
module, one new edge downward. The API is:
- `init(gpa, renderer, content, limits)` and `deinit`;
- `create(.{ .emitter, .transform, .stream })` and `destroy`;
- `setTransform`, `play`, `stop` and `clear`;
- `step(tick, dt, jobs)`, `prepare(view, jobs)` and `draw`;
- `contentChanged`;
- `liveCount` and `stateHash`.

Its tests are in `engine/tests/particles3d.zig`, over compiled packages, because `render3d`
has no `data` to compile a record with.

**Where the step sharpened §6–§7:**
- **The instance holds its description, not a pointer to one.** `Description` keeps the
  decoded `asset.ParticleEmitter` beside the arrays `particles.Emitter` borrows. The view is
  rebuilt from the entry's own storage at each use, because a `HandlePool` may move entries.
- **Material compatibility is checked through a new `Renderer.materialShape`.** It reports the
  alpha mode, which decides `sorted`, and the model's required streams, which must be covered
  by position, UV0 and colour. A lit material is therefore `InvalidMaterial`. A material record
  that fails to build is drawn as `Content`'s placeholder, as everywhere else.
- **Counters are held on the renderer until `begin`.** `prepare` runs before `begin`, which
  resets `Stats`, so `Renderer.noteParticles` holds them and `begin` folds them in, exactly as
  M28's upload counters are. `particles_dropped` is the drops gathered by every `step` since
  the previous `prepare`. The overlay's 3D panel prints a fifth line, "3D: N particles in E
  emitters  C culled  D dropped  R refused".
- **Culling uses the step's padded bounds**, in world or local space, against
  `Camera.viewProjection`'s frustum, and only when `Config.cull` is set. A culled instance is
  stepped but neither uploaded nor drawn.
- **`step` splits one instance per chunk.** `prepare` handles instances in order, and each
  expansion splits its own quads over `jobs`; the two splits are never nested.
- **Writing straight into staging needs aligned mapped memory.**
  - Metal maps page-aligned contents, and Vulkan maps each buffer's own memory from offset 0,
    so at least 64-byte aligned.
  - The null backend allocated with no alignment, so it now allocates at `map_alignment` (16),
    modelling the real backends' promise.
  - Each piece of the layout starts at a multiple of 16, so the typed views of the
    reservation are aligned on every backend.
  - The `asset.Mesh` handed to `updateMeshFromStaged` names those same views. The prefilled
    path reads only their lengths.
- **The index question (§7) is decided by bytes.** Indices are 12 bytes a quad against 144 for
  the vertices, about 8% of the upload. That is too small to need an "indices unchanged"
  option, so none is added. Step 6 times the uploads' share of the frame. If it shows
  otherwise, the option is added there, inside M29.
- **Reload.**
  - A record that is gone, does not decode, names an absent material, or whose material no
    longer suits a particle mesh, leaves its instance refused: not stepped, not drawn, and
    counted each frame.
  - A later reload restores it, with its particles as they were.
  - A different material is acquired before the old one is released.
  - A capacity change resizes the store with the new `System.setCapacity`, which removes the
    oldest first, and resizes the expander's keys.
  - The caller calls `Content.contentChanged` first.
- **`InvalidEmitter`** is what an undecodable record gives at `create`. The compiler cannot
  emit one (Step 3), so it is reached only by a package from elsewhere. The decode tests cover
  each refusal; this path logs `describe`'s sentence.

**Tests.** There are six in `particles3d.zig`, and the overlay test gains the new line:
- **Refusals:** every refusal holds nothing.
- **Frame:** step, `prepare` refused inside the window, two meshes drawn with an identity
  world, and the counts.
- **Destroy:** destroying inside the window is clean.
- **Culling:** an instance behind the camera is stepped but neither uploaded nor drawn.
- **Drops:** a full store's drops are counted in the next frame.
- **Jobs:** `serial` and `reversed` steps give identical hashes, and streams differ.
- **Reload:** a lower capacity and a new material keep the handle and the newest 100
  particles. A removed record stops, and stays byte-identical across 80 ticks, past every
  particle's life. Restoring the record draws it again.

**Mutations.** Each was made, watched to fail, and restored byte for byte:
- removing culling failed the out-of-view test;
- not refusing a removed record failed the reload test;
- stepping refused instances first survived. The test stepped one tick into a full store whose
  particles neither moved nor aged out. Stepping past their lifetime made it fail, as it
  should.
- not folding the emitter count failed the counting test.

**Bar:** **2,291/2,292** (one skip, M27's), the full bar, all exit 0. The whole graph under `-Drhi=metal` is 2,301/2,313, with 12 backend-conditional skips; `particles3d` runs there through real Metal staging. No shader or Vulkan code changed, so the Vulkan checks were not due.

## Resolution — Step 6: the effects corner, proved on Metal (2026-10-24)

**What exists:**
- **`samples/sandbox3d/effects.zig`.** `FOUNDRY_SANDBOX3D_EFFECTS=on|off`, with `on` when
  unset; an unknown value is said aloud and is `off`. **P** stands the player on M28's patch
  facing the corner. **B** restarts the sparks' timeline, so their burst at time 0 fires at the
  next step. Both keys join `FOUNDRY_SANDBOX3D_KEYS`.
- **Content in `sandbox3d.fdt`:** five emitters, `sandbox3d:effects.torch_flame`,
  `torch_smoke`, `sparks`, `fountain` and `trail`, and five particle materials.
- **Textures:** `content/effects/flame.png` (a 4×4 flipbook) and `puff.png`. They are white,
  with the shape in alpha, and written by `scripts/gen-particle-textures.py`, which produces the
  same bytes on every run.
- **`testdata/mods/embers`:** a content-only mod that overrides the flame emitter at rate 180 and
  the flame material in green. `build.zig` compiles it beside `plinth` and `orbiter`, installs
  it as an optional package, and hands it to the sample's tests.
- **`effects_tests.zig`:** four tests.

The sample calls `step` on the tick, with the moon's world transform for the trail.
`prepare(view)` runs once the frame's `FrameView` is built and before `begin`, and `draw` runs
after the generated corner's draws.

**Where the step sharpened §8:**
- **Placement.** The corner is at x = 20, z = 9.5, past the +Z edge of M28's patch. Its ground
  is the patch, so **P** says so and does nothing when the generated corner is off.
- **The fountain** has capacity 12,000, rate 6,500 and lifetime 1.5–1.7 s, which holds about
  10,400 live. With the rest of the corner the peak is 10,756.
  - Its colour comes from `color_over_life` alone. §8's "varies by each particle's random
    value" is dropped: §4's record has no field that reads the per-particle random. It is kept
    in the store (Step 1), and nothing is deferred by not using it.
- **`casts_shadow false` is not written on particle materials.** The particle model reads no
  `casts_shadow`, so setting it raised `Content`'s "fields unread" warning. Particles never
  cast, whatever it says (Step 4).
- **`app`'s first tick is 1.** The pin is taken at `tick == 600`, after 600 steps, and the test
  steps ticks 1–600, as the sample does.
- **A clock for the parts of `prepare`.** `render3d` reads no clock, so
  `Particles.prepareTimed(view, jobs, clock)` takes a caller's clock, as `core.profile` takes
  timestamps. It returns the expansions' time, which includes each sort, and the uploads'.
  Measurement only. The sort cannot be timed apart from the expansion, because it runs inside
  `particles.Expander` and `particles` has no clock either.

**The first measurement missed the budget, and the fix changed no byte.** Three windowed runs
from the relocated install measured a step-plus-prepare p95 of 4.67–4.69 ms, with expansion
and sort 3.7 ms of it. A ReleaseSafe benchmark of the same fountain on a busy core took 0.35 ms
to expand, 0.35 ms more to sort, and 0.09 ms to step.
- **The ×6–8 gap is the paced main thread.** It idles between frames and runs on a cooler,
  slower core, as M28's inline water did. Thread priority and QoS are M99's.
- **So the work was cut instead:**
  - The sort is now a stable LSD radix sort on the depth's bits: −0 folded into +0, IEEE order
    made unsigned, then reversed for far first. A store is in spawn order, so stability gives
    the same "then earlier spawned" tie-break as before. Step 2's tie test now builds its store
    in spawn order, as every real store is.
  - The step's removal moves runs of survivors one field array at a time.
  - The expansion reads the field arrays directly, skips trig when the angle is exactly 0
    (`sinCosTurns(0)` is exactly (0, 1)), and keeps plain per-chunk bounds.
- **Every pin is unchanged:** Step 1's state, Step 2's three facings and the fountain's. The
  benchmark now expands in 0.14 ms, sorts and expands in 0.25 ms, and steps in 0.09 ms.

**§1's exit on Metal.** These runs used a relocated ReleaseSafe install (`zig build install
-Drhi=metal -Doptimize=ReleaseSafe` to a staging prefix, moved, then run from the new place).
They were windowed, on an Apple M5, with 4× MSAA, 600 frames, the gallery off, and **P** at
frame 30, so the corner is in view throughout:

| Run | Step + prepare median / p95 / max (ms) | Step p95 | Prepare p95 (expand and sort / upload) | Peak live |
| --- | --- | --- | --- | --- |
| 1 | 1.655 / **1.799** / 2.025 | 0.391 | 1.415 (1.167 / 0.369) | 10,756 |
| 2 | 1.618 / **1.758** / 2.078 | 0.400 | 1.368 (1.120 / 0.357) | 10,756 |
| 3 | 1.606 / **1.751** / 1.933 | 0.394 | 1.371 (1.110 / 0.360) | 10,756 |

1. **The budget holds:** a p95 of 1.75–1.80 ms against 2.0 ms. With `FOUNDRY_SANDBOX3D_WORKERS=0`
   the p95 is 2.50 ms, so `core.Jobs` is the lever, as §12 planned. The Arc PC decides the
   criterion in Step 7.
2. **The pin holds:** `0xc5f2d56ba1124b5d` at tick 600, in all of these:
   - the test;
   - the headless tour;
   - all three windowed runs;
   - the `embers` run;
   - the run with no workers;
   - the windowed tour.

   They differ in frame pacing, worker count and packages, and all give the same ticks and the
   same bytes.
3. **and 4. Order, additive, mask and exposure hold**, by Step 4's Metal readbacks.
5. **`embers` holds.** `FOUNDRY_SANDBOX3D_PACKAGES=embers:content` enables it, and the peak rises
   to 10,868 from the flame's doubled rate. The test shows the overriding rate and the green
   emission. A scripted **R** logs "torch flame particles.Emitter(0#1) kept, 116 live", and
   the pin is unchanged.
6. **The other samples hold.**
   - The windowed tour from the install keeps the player's `cb99ccfcf2b6d6c3` and the walker's
     `62ed8c026c20482c`, as does the headless tour.
   - The court's endings run in `zig build test`.
   - M28's water stays near a p95 of 0.11 ms.
   - The landmark's worst frame is 3.6 ms against its 16.67 ms budget. That is up from M28's
     2.6 ms by about the particle work, which now shares those frames.

**The index question (§7) is closed:** uploads are about 0.36 ms of a frame, and the indices
about 8% of those bytes, so about 0.03 ms. No "indices unchanged" option is added.

**Found, not M29's:** M28's "the landmark is the same bytes inline and from a pool task" test
fails under `-Doptimize=ReleaseSafe`. It fails identically on a clean checkout of `b41ce67`. Its
digest is pinned for Debug alone; it is the `sinf` variance of `public3d.md` §10 and of this
milestone's Step 1. The bar runs Debug, where it passes. It is reported to the owner rather
than changed here.

**Tests.** `sandbox3d-test` passes 37 of 37, four of them new:
- every record decodes, and the corner makes all five effects;
- the pin, with 10,000–11,500 live;
- the mode switch;
- `embers`: rate and colour overridden, the handle kept, and twice the spawning.

**Mutations.** Each was made, watched to fail, and restored byte for byte:
- an unknown mode taken as `on` failed the mode test;
- the effects not following a reload failed the `embers` test;
- a radix key not reversed failed the sort test and the facing pins;
- the compaction skipping `spin` failed the state pin and the facing pins.

**Bar:** **2,295/2,296** (one skip, M27's), the full bar, all exit 0. The whole graph under `-Drhi=metal` is 2,305/2,317, with 12 backend-conditional skips. The content change is staged by the relocated install above, as M28's was, because `dist` stages no `sandbox3d`. No shader or Vulkan code changed.
