# ADR-0064: Particles are a simulation below the renderer, defined by content and drawn through runtime meshes

**Status:** Proposed
**Date:** 2026-10-23

## Context

M29 gives Foundry its first particle system: a CPU one, whose emitters are content
(`docs/ROADMAP.md`, Phase 6). Three later milestones build on it: M78 moves particles to the
GPU, M79 adds ribbons, mesh particles and collision, and M110 edits emitters live. A fourth,
M48, publishes it to mods. What M29 settles is where each part lives, and those milestones
inherit it.

Four questions have to be answered once.

The first is placement. A particle system is a simulation (spawn, integrate, age, kill) and a
drawing (camera-facing quads, sorted, blended). The simulation reads no device and no file. If
it lives inside `render3d` it can only be tested through a renderer, and `render2d`, a peer at
L3, can never draw it. `anim` faced the same question in M24 and answered it with an L1 module
on `core` alone (ADR-0058).

The second is identity. An emitter's behaviour is authored, overridden by mods and reloaded, so
it is content (I2, I5). A running emitter is not: it has no record and is not saved, like
ADR-0063's runtime geometry and like `anim`'s playback state.

The third is how particles reach the GPU. M28 left this to M29 (`runtime-geometry.md` §12: "M29
decides whether it uses `updateMesh` or a ring of its own"). `updateMesh` keeps a handle, reuses
buffer capacity and stages through M27's kept buffers, and M28 proved it each frame on both
backends. M28 also measured its cost: the 129² water rewritten inline took 2.0 ms at p95 in the
paced sample, mostly building and copying an `asset.Mesh` that was then copied again.

The fourth is blending. Fire and sparks add light; smoke covers what is behind it. `render3d`
has one blended pipeline state, premultiplied alpha, and its shading models premultiply in the
fragment shader. So an additive particle cannot be written today: its colour would be multiplied
by an alpha of zero.

## Decision

1. **The simulation is an L1 module, `particles`, on `core` alone.** It holds validated emitter
   descriptions as values, a fixed-capacity particle store per running emitter, the step, and the
   expansion of live particles into camera-facing quads, written into buffers the caller passes.
   It has no assets, no entities, no renderer, no clock and no I/O. Its step is deterministic
   (I9): time is the caller's tick times its fixed delta, never an accumulated sum; randomness is
   a `core.rng.Pcg32` seeded per emitter; particles are kept and visited in spawn order.
2. **An emitter is content: a `foundry:particle_emitter` record**, whose schema lives in `asset`
   beside `foundry:ui_theme`, so `fpack` checks it without a renderer. It names its look as an
   ordinary `foundry:material`, so a texture, a reload and a mod's override of the look all
   arrive through the path materials already have. `asset` decodes the record into a value of its
   own, and `render3d` converts it into `particles`' description. Neither module names the other's
   types, as with skeletons and clips.
3. **A running emitter is owned by handle, never content.** `render3d.Particles` holds each one by
   a generational handle (I1), made and destroyed by its creator. It has no content ID and is not
   saved, and its destroy inside a frame's window is deferred (ADR-0063). Each instance follows its
   record across a reload and keeps its handle and its live particles.
4. **Particles are drawn as runtime meshes through `updateMesh`, with no ring of their own.**
   Each visible instance's quads are written directly into a kept staging reservation and given to
   `updateMeshFromStaged`. No intermediate `asset.Mesh` is built, so the copy that cost M28's
   inline water is not paid. The expansion and the fill may run over `core.Jobs` inside the
   frame, so the camera they face is the frame's own. An instance holds at most 16,384 particles,
   so its quads index with `u16`.
5. **One engine shading model, `foundry:shading.particle`, written by hand for each backend**
   (ADR-0049). It takes premultiplied colour from the vertex and does not premultiply again. The
   expansion writes each particle's colour as `rgb × opacity` with alpha `opacity × (1 −
   additive)`. Additive and covering particles therefore share one pipeline and one sort, and need
   no new blend state and no new alpha mode. The light it emits is
   `texture × vertex colour × (base colour × frame ambient + emissive × emissive strength)`,
   pre-exposed as lit output is (ADR-0056).
6. **Nothing is published in M29.** M48 publishes particles in `FoundryApi_v8`, and M49 binds
   them to Lua.

## Consequences

- The simulation tests with no device and no window. A replay from tick zero reproduces every
  particle, so emitters can be pinned by hash.
- `render2d` can draw the same simulation without a sideways dependency, because `particles` is
  below both renderers. M29 does not build that; `docs/design/particles.md` §13 names its
  milestone.
- Emitter look and behaviour are both overridable, separately: a mod replaces a material to
  recolour fire, or an emitter record to change how much fire there is.
- Two description shapes exist, one decoded by `asset` and one validated by `particles`, with a
  field-for-field conversion in `render3d`. That is the same price `asset.Skeleton` and
  `anim.Skeleton` pay, for the same reason.
- Sorting is exact within an instance and approximate between instances, which `render3d`
  orders by their bounds' centres. Two interpenetrating blended emitters can show the wrong one in
  front. Additive particles do not care about order.
- 16,384 particles per instance is a hard limit. A larger effect uses several instances, or waits
  for M78's GPU particles.
- Particles light only by emission and the frame's ambient term. They are not lit by the frame's
  lights, do not receive shadows and do not fade into geometry; each of those names its milestone
  in `particles.md` §13.

## Alternatives considered

- **The simulation inside `render3d`.** It is simpler by one module. It was rejected because it
  makes the simulation untestable without a renderer and unreachable from `render2d`, and
  because a particle's motion is no more a rendering concept than a pose is (ADR-0058).
- **Emitters named by code, not content.** A game would describe effects in Zig, which is I5's
  anti-pattern. A mod could change no effect it did not write.
- **An emitter naming a texture and colours directly, not a material.** It needs a second path to
  bind, reload and override a texture, beside the one materials already have (ADR-0063).
- **A ring buffer of its own, persistently mapped.** It would save the staging copy, but it would
  be a second upload path with its own lifetime rules next to M28's. Writing straight into the
  kept staging buffer removes the copy that actually cost time. `runtime-geometry.md` §12 already
  found no trigger for persistent mapping.
- **An additive alpha mode or blend state.** It would add a material field and a pipeline variant
  that every shading model must honour. Additive and covering emitters would also sort in
  different groups, where today they interleave correctly in one.
- **Billboards expanded in the vertex shader.** That would make the mesh independent of the
  camera, but it would need per-particle data in slots ADR-0054 fixes to other meanings. That is
  GPU expansion, and it is M78's.
- **A scene component carrying an emitter.** Particle state is presentation, which no save
  holds. An engine component that draws an entity's model or effect belongs with M103's "draws
  this model" component.

## Revisit if

- With every sample emitter live, M29's measured particle work misses its budget on the Arc PC
  even over `core.Jobs` (`particles.md` §1, criterion 1). The answer is then M78's GPU path, not a
  faster CPU one.
- A game needs more than 16,384 particles from one emitter before M78.
- The between-instance sort is visibly wrong in a sample or game that M29–M77 ships. The answer
  then is order-independent transparency or merged sorting, and needs its own decision.
- `render2d` gains particles. If it needs a second description shape inside `particles`, the
  module's boundary was drawn wrong.
