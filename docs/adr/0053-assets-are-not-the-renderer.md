# ADR-0053: Assets are not the renderer — import, runtime assets, scene, submission and GPU stay separate

**Status:** Accepted 2026-09-27 (constraint only; M19–M20 implement it)
**Date:** 2026-09-27
**Informed by:** ADR-0006, ADR-0021, CLAUDE.md §4.2 and §6, `docs/design/3d.md` §3

## Context

The first 3D importer will be glTF's, and glTF has a strong shape: nodes, accessors, buffer
views, primitives, extensions. An engine that lets the first importer's shape become its
renderer API is stuck with it, and a second format, a procedural mesh or a streaming system
then has to pretend to be glTF. 2D avoided this by accident, because PNG has little shape.
3D will not avoid it by accident.

## Decision

Between a source file and the GPU there are six stages, each owned by one module, with one
translation per seam (`3d.md` §3):
1. **import** (`fpack`, build time, the only glTF reader);
2. **the runtime mesh** (`asset`: streams by semantic, indices, submeshes, bounds, versioned);
3. **textures and materials** (`asset` and content records);
4. **the model** (a content record of parts, each with a submesh, a material slot and a local
   transform; flattened, not a hierarchy);
5. **the scene** (`scene`'s entities);
6. **submission** (`render3d`: mesh, submesh, material, world matrix, camera, lights).

`rhi` resources are owned by `render3d`.

**`render3d`'s API names only Foundry runtime types and handles.** No glTF concept passes `fpack`.
Code can build the same runtime mesh a file loads. Whether spawning a model creates entities is
`scene`'s decision.

## Consequences

- A second importer, a procedural generator, or later LOD and streaming produce the same runtime
  types, and nothing downstream changes.
- Runtime formats are Foundry's, versioned under I8, and never glTF or JSON at runtime.
- The costs are more types and one more translation than drawing glTF directly, and the model
  record's flattening loses glTF's node names unless a later need keeps them.

## Alternatives considered

- **Load glTF at runtime.** It is quick to start, but it makes JSON a runtime format (CLAUDE.md
  §6) and ties the renderer to one format.
- **Make models entity hierarchies at import.** That puts `scene`'s decision in a tool, and makes
  every static mesh pay for entities.
- **One combined "mesh with materials" asset.** It couples geometry to appearance, so a material
  mod would have to replace geometry.

## Revisit if

- A workload shows that a translation step is a measured load-time cost worth fusing.
- Streaming or LOD needs a representation between the model and submission. That would be added
  as a new stage, not by merging two.
