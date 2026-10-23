# Design: M29 — Particles I: a CPU particle system with content-defined emitters

**Status:** Accepted 2026-10-23, when the owner asked for Step 1, with §14 as written. Step 1 of §15's eight is done; its Resolution follows §15.
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
