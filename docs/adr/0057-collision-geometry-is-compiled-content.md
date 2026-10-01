# ADR-0057: Collision geometry is compiled content, derived at import and copied into `physics3d`

**Status:** Accepted 2026-09-30, when the owner requested M23 Step 1 — implemented in M23 (2026-10-01, tag `m23`)
**Date:** 2026-09-30
**Informed by:** ADR-0006, ADR-0021, ADR-0048, ADR-0051, ADR-0053, ADR-0055,
`docs/design/3d.md` §8, `docs/design/collision3d.md` §6, §8 and §9

## Context

ADR-0051 gives `physics3d` a static triangle-mesh shape, and `3d.md` §8 says its geometry is "a
collision asset that the package compiler derives from a mesh or authors separately, like the tile
grid". M23 has to make that concrete. Four things about it will be hard to change once content
depends on them:
- **The record's name and schema.** They are compatibility decisions (CLAUDE.md §7), and M25
  publishes them to mods.
- **The runtime format.** It is versioned under I8.
- **How an author says what collides.** Every model a mod ships will carry that answer.
- **Whether `physics3d` holds geometry or borrows it.** That fixes who owns a mesh's lifetime
  across a reload.

The render mesh is not a candidate. It is `render3d`'s GPU residency, and ADR-0053 keeps import,
runtime asset, renderer and simulation apart, so no CPU copy of it exists at runtime for physics
to read.

## Decision

**A static collision mesh is its own asset.**
- **The record** is `foundry:collision_mesh`, version 1: one field, `source`, naming a `.fcol`
  file.
- **The file** is `.fcol`, format version 1, magic `FCOL`. Its version is in a field, as in every
  Foundry format. It holds model-space positions and 32-bit triangle indices, with no tree.
- **Where it lives:** the format, its `View` and its loader live in `asset`. The loader is
  registered at runtime by whoever wants it (I6).

**It is derived at import, and only when asked.**
- `foundry:model_import` version 2 gains `collision` (bool, default `false`) and
  `collision_exclude`, a list of glTF node names whose subtrees are left out.
- `collision true` derives `<model>.collision`. That is one record per model, adding a
  `collision` segment beside ADR-0055's `mesh<i>`, `material<i>` and `texture<i>`.
- Its triangles are every triangle of every node not excluded, flattened by the node's whole
  matrix. That includes scale, after `front`.
- **An exclusion naming no node is refused.** An empty result is refused. Degenerate triangles are
  dropped, with a counted warning. Nothing is excluded by inference: not by alpha mode, material
  or naming convention.

**`physics3d` copies.** A game reads the asset's `View` and passes its positions and indices to
`physics3d.World.addMesh`. That call validates them, copies them and builds a deterministic
bounding-volume tree. `physics3d` never sees an asset, a record or a path. A body refers to the
mesh by a generational handle (I1).

**Collision poses are rigid.** Scale is baked at import; `physics3d` poses carry none.

## Consequences

- **Nothing at runtime knows collision came from glTF.** A hand-placed `.fcol`, derived through
  the `kinds` table, is indistinguishable from an imported one, as ADR-0055 requires of every
  import.
- **Adding collision to a model is a line in its import record**, and a mod can override that
  record. A model does not become solid by accident: every existing import, and every `.gltf`
  without a record, still derives none.
- **A typo in an exclusion is a build error**, not a solid plant.
- **Reloading is safe.** The world owns its copy, so a package reload replaces a mesh by removing
  and re-adding it, and no body points into freed bytes.
- **The cost:** a second copy of each collision mesh's triangles in memory, and a tree built at
  load. For the sample that is a few thousand triangles. §15 of the design names the measurement
  that would bake the tree into the format: `addMesh` above 5 ms on a shipped level.
- **Proxy collision is not yet possible.** A simpler collision shape authored separately from the
  visual model, which `3d.md` §8 anticipated, has to wait. `3d.md` §8 is corrected at M23's close
  to say so.
- **A runtime-scaled model does not collide at its scale.** A game needing that is a trigger.

## Alternatives considered

- **Collide against the render mesh at runtime.** Rejected: the renderer holds GPU buffers, not
  CPU triangles (ADR-0053). It would also make `physics3d` depend on a module above it, or make
  the renderer keep a CPU copy it does not need.
- **Derive collision for every imported model by default.** This is simpler to use. It was rejected
  because it converts silently (ADR-0048): a decorative model would start blocking, and turning it
  off would mean discovering it had been on.
- **Mark collision in the glTF**, with `extras`, a node-name prefix such as `UCX_`, or a
  material. That keeps an artist's tool as the one place to decide. It was rejected because it is a
  rule hidden from the import record, which is where Foundry's authors read and mods override.
  A convention an importer honours is also one it must honour forever.
- **Bake the tree into `.fcol`.** That makes loads faster. It was rejected for now because it
  fixes a tree layout in a versioned format before any measurement asks for it. Adding it later is
  a format version 2.
- **Borrow the asset's arrays, as `physics2d` borrows a tile grid.** Rejected because the tree must
  be stored somewhere anyway, and a borrowed slice outlives a package reload only by luck.
- **One collision record per glTF mesh, not per model.** This would allow reusing a mesh's
  collision across models. It was rejected because the model's node transforms, which include
  scale, are what place triangles in the space a game poses. Per-mesh records would need a
  runtime scale, which this ADR keeps out of `physics3d`.

## Revisit if

- An author needs proxy collision that is simpler than the visual model, or collision derived from
  a hand-written `foundry:mesh`. That would be a new producer of the same record, not a new
  record.
- `addMesh` is measured above 5 ms for a shipped level. Bake the tree into `.fcol` version 2.
- A game scales collidable models at runtime.
- A game needs per-triangle surface data, such as footstep sounds or friction. That would be an
  additive field in a new format version.
- A game finds the model-to-collision link it has to write itself too error-prone. Then
  `foundry:model` would gain an optional `collision` field.
