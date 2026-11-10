# ADR-0077: Collision structures find candidates and never decide an answer

**Status:** Accepted 2026-11-10, when the owner requested M38 Step 1
**Date:** 2026-11-10
**Informed by:** ADR-0013, ADR-0051, ADR-0055, ADR-0057, ADR-0076, `docs/design/collision3d.md`, `docs/design/collision-scale.md`

> **Revised 2026-11-10, at M38 Step 1, before any code depended on it:** the bake threshold is
> 1,024 triangles, not 4,096. A tree of 4,096 triangles measured 4.7 ms to build, ADR-0057's whole
> budget.

## Context

`physics3d` answers every query by scanning its bodies in handle order, and builds each mesh's
tree when the mesh is added. Both were deliberate at M23, and both named their revisit: a
broadphase when a query is over budget at a body count a game has, and a tree baked into `.fcol`
when `addMesh` is over 5 ms on a shipped level. ADR-0060 scheduled both in M38.

Two things must survive the change. Ties between hits resolve by handle and then by triangle
(`collision3d.md` §5.4), and every pin in the repository rests on that. And content is untrusted:
a `.fcol` may come from a mod, so a tree read from one may be wrong, or hostile.

`author` compiles `.fcol` and cannot see `physics3d`, which holds the only tree builder.

## Decision

**A structure finds candidates. It never orders them and never answers.**

**The broadphase is one balanced bounding-volume tree over every body.** A query walks it, sorts
the bodies it found by handle index, and tests each as the scan did, exact bounds included. A
kinematic body's box is padded, so a small move costs nothing. Every write of a body's pose goes
through one place, which refits. The scan is kept for tests, and a test runs every query both
ways and compares the answers byte for byte.

**A mesh may arrive with its tree.** `physics3d` validates it in linear time: its shape, its
depth against the query's fixed stack, that its leaves hold each triangle exactly once, and that
every box contains what is under it. A tree that fails is refused, not rebuilt. Any valid tree
gives the same answers, because a mesh's candidates are sorted by triangle index.

**`.fcol` version 3 carries the tree.** `author` writes one for a mesh of 1,024 triangles or
more, and writes smaller meshes as before, so every existing file keeps its bytes.

**`author` is granted `physics3d`,** and bakes a tree with the builder that would have built it
at load.

## Consequences

- A world of thousands of bodies costs a query a walk of the tree, not a pass over all of them,
  and no answer or pin changes.
- A large level's collision loads in the time it takes to copy and check it.
- Queries still allocate nothing: the scratch grows when a body is added.
- Every setter must refit, and one that forgets is a wrong answer only for a moved body. The
  equivalence test is what catches it, so it must move, reshape, rescale, remove and add.
- `author` now depends on `physics3d`. It is a downward grant, but it is one more module a
  content compiler links.
- A file with a tree is larger: 32 bytes a node and 4 a triangle, about 20 bytes a triangle.
- Validation makes a baked tree linear, not free. Past about a quarter-million triangles the
  check alone nears 5 ms, and such a level must be loaded in pieces.

## Alternatives considered

- **A spatial hash, as `physics2d` has.** It needs a cell size, and a 3D world holds a level mesh
  beside a crate. A tree takes both, and M51's pair finding wants one.
- **Trusting a baked tree.** A wrong tree loses collision silently, and a deep one overruns the
  query's stack. Content is untrusted (CLAUDE.md §7).
- **Rebuilding when a baked tree is wrong.** It hides a damaged file, and a mod author never
  learns their tool is broken.
- **A second tree builder in `asset` or `author`.** Two builders drift, and nothing would test
  that they agree.
- **Granting `asset` `physics3d`.** ADR-0057 kept them apart on purpose: the asset is geometry,
  and physics copies it.
- **Baking a tree into every mesh.** Every existing collision file would change bytes for a
  tree that builds in under two milliseconds.

## Revisit if

- A game's bodies move so much each tick that refits cost more than the scan they replaced.
- A level's collision is measured over 5 ms with a valid baked tree. That is streaming's
  question, M60's.
- M51's solver needs pairs in an order the tree cannot give without a sort it cannot afford.
