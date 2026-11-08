# ADR-0076: Collision geometry gains surfaces, one-sided faces, runtime scale and proxies

**Status:** Proposed
**Date:** 2026-11-09
**Informed by:** ADR-0055, ADR-0057, `docs/design/collision3d.md`, `docs/design/collision-extras.md`

## Context

ADR-0057 made static collision a compiled `foundry:collision_mesh`: `.fcol` version 1, positions
and indices only, derived from a model's own nodes, with poses rigid and scale baked at import. It
named its own revisits:
- per-triangle surface data;
- proxy collision simpler than the visual model, "a new producer of the same record";
- runtime-scaled models.

M37 also needs one-sided triangles, and a model record that names its collision.

## Decision

**`.fcol` version 2** appends a surface table, at most 65,535 content-ID hashes, and a u32 per
triangle: a surface index in its low 16 bits (0xFFFF for none) and a one-sided flag in bit 16, the
other bits zero. Version 1 reads as before. A derived mesh is written at version 2 only when it has
a surface or a one-sided face, so every existing mesh keeps its bytes.

**A surface is a content ID that `physics3d` stores and reports, and never interprets** (I5). Every
hit and the controller's ground report it. A body has a surface of its own, and a mesh triangle's
surface wins over it.

**A one-sided triangle collides from its front, by its winding,** and every query and depenetration
skip it from behind.

**A body carries a scale for its mesh or hull shape:** non-uniform, positive, 0.01 to 100 on each
axis. Scale is applied before the pose, and poses stay rigid. Mirroring is refused. Other shapes
refuse any scale but one.

**`foundry:collision_import`** is a build-only record, compiling into the `foundry:collision_mesh` of
its own ID from a glTF file of its own. That is the proxy producer ADR-0057 anticipated.

**`foundry:model` version 3 names its collision,** derived or proxy, so a game finds a model's
collision from the model alone. `foundry:model_import` version 3 maps glTF materials to surfaces and
one-sided faces, and names a proxy by `collision_mesh`.

## Consequences

- A level is one mesh with grass, stone and a one-way ledge in it, and a footstep is chosen by
  what the hit says.
- A prop placed at twice its size collides at that size, from one shared copy of its triangles.
- A model's collision can be a few boxes while it draws thousands of triangles.
- **The cost:** four bytes a triangle, and a scaled mesh's candidates are found through an inverse
  transform, which is a little more work per query than a rigid one.
- `physics3d` still sees no asset: a game copies the view's arrays into `addMeshWith`.

## Alternatives considered

- **A mesh per surface.** It multiplies bodies and the scan over them, and splits what an author
  made as one.
- **Scale in the pose.** Every shape would have two ways to say its size, and every narrowphase
  path would carry a scale that only meshes and hulls need.
- **Surfaces as small integers the engine defines.** That is game content in the engine (I5), and
  a mod could not add a surface.
- **Proxy nodes in the model's own file, named by convention.** ADR-0057 refused inferring
  collision from names, and a separate file is what an author draws a proxy in.

## Revisit if

- A game needs data per triangle beyond a surface and a side, such as a friction coefficient read
  by a solver. That is a new format version, M51's at the earliest.
- A table of 65,535 surfaces is too few for one mesh.
- A scaled mesh's queries are measured over budget against a baked one's.
