# ADR-0052: `render3d` starts as a simple forward renderer

**Status:** Accepted 2026-09-27 (constraint only; M19–M22 implement it)
**Date:** 2026-09-27
**Informed by:** ADR-0003, ADR-0035, ADR-0036, CLAUDE.md §4.2, `docs/design/3d.md` §6

## Context

`render3d` is the second renderer API, beside `render2d`. Its first job is to establish the
architecture and prove:
- meshes, transforms and cameras;
- depth;
- materials and textures;
- lighting;
- Metal and Vulkan.

Deferred, clustered and forward+ designs pay off at light and material counts no Foundry game
has shown.

## Decision

**A forward renderer:**
- **The frame:** begin with a camera, submit, end.
- **Submissions** name handles and content IDs, never pointers.
- **Sorting and culling:** CPU frustum culling; opaque draws front to back and transparent
  ones back to front, with ties broken by submission order.
- **Passes:** a fixed order of shadow, opaque, transparent, then `render2d`'s overlay.
- **Lighting:** a small bounded light set in the forward shader, one directional shadow, one
  HDR target and one tone map.
- **Growing the RHI:** it widens only as each pass needs it, on all three backends at once.
- **`render3d` does not see entities;** the game extracts and submits, as in 2D.

The renderer changes architecture only when a real workload's measurement shows a limit.

## Consequences

- It is the smallest renderer that proves the whole path. MSAA stays cheap, and transparency
  stays simple.
- Many lights, or many shadowed lights, will cost per pixel. That is the known limit, and its
  trigger is a frame time at a stated light count on the target hardware.
- Fixed passes mean a new pass is an engine change until a render graph is justified.

## Alternatives considered

- **Deferred:** it complicates MSAA and transparency for light counts not yet seen.
- **Clustered forward or forward+:** these are the likely upgrade path, and they are sized to a
  workload that does not exist.
- **A render graph now:** it has one consumer and fixed passes, so it is scaffolding with nothing
  to schedule.

## Revisit if

- A measured scene misses its frame budget because of light count, shadowed lights or overdraw.
- A second consumer needs to reorder or insert passes.
- A game's visual target needs a technique forward shading cannot provide.

## Note — 2026-09-30, M22's close

Implemented through M22 without changing the decision. The pass-order shorthand above
omitted the tone map that its lighting bullet already required: the actual fixed sequence
is optional shadow, world (opaque/mask then transparent), Neutral tone map, then overlay.
`render3d.recordFrame` owns the first three; `app.renderScene` retains ownership of the
overlay and supports legacy single-pass recorders. ADR-0056 fixes photometric units and
pre-exposure; `light.md` records the implementation and proofs. No render graph was added.
