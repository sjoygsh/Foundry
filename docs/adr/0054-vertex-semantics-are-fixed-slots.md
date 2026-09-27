# ADR-0054: Vertex semantics are fixed shader slots

**Status:** Accepted — implemented in M19 (2026-09-27, tag `m19`)
**Date:** 2026-09-27
**Informed by:** ADR-0049, ADR-0053, `docs/design/render3d.md` §5 and §6.4, `rhi.md` §9

## Context

A runtime mesh (ADR-0053's row 3) carries vertex streams by semantic: position, normal,
tangent, two UV sets, colour, joints and weights. Every shading model reads a subset of them.
How a semantic reaches a shader input is shader-visible:
- every hand-written MSL and GLSL variant (ADR-0049) depends on it;
- M20's mesh format and importer depend on it;
- the day mods author shaders, they will depend on it too.

The RHI allows eight vertex buffers (`pipeline.max_vertex_buffers`), a limit taken from
Metal's shared argument table.

## Decision

**Each semantic has one fixed slot, used as both the vertex buffer index and the shader
attribute location:**

| Slot | Semantic |
| --- | --- |
| 0 | position |
| 1 | normal |
| 2 | tangent |
| 3 | UV0 |
| 4 | UV1 |
| 5 | colour |
| 6 | joints |
| 7 | weights |

- **One stream per buffer; streams are never interleaved** in the runtime representation.
- **A shading model declares only the slots it reads,** and never renumbers them.
- **A mesh may carry streams a model ignores.** A model that needs a stream the mesh lacks
  refuses the draw.
- **The formats a slot allows** are a table in `asset`. It widens only in the milestone that
  first reads that slot.

## Consequences

- **A pipeline needs no per-mesh layout.** Any mesh with the right streams draws with any model
  that reads them. A mod's mesh and a mod's material meet without code.
- **No slot remains for a ninth semantic.** A second colour set, a third UV set, or per-vertex
  data a future model invents does not fit. Adding one means packing, or a storage buffer read
  by vertex index. Each is a new decision.
- **Separate streams cost some vertex-fetch locality** compared with an interleaved layout, on
  hardware that prefers interleaving. In exchange, a depth-only shadow pass (M22) binds position
  alone, and a model reading three streams fetches three.
- The table is a public name in effect. Changing it later breaks every shader and every
  compiled mesh, so it is treated like a content ID (CLAUDE.md §7).

## Alternatives considered

- **Interleaved vertices with a per-mesh layout.** This is the common engine choice. Every
  pipeline would then have to match every mesh's layout, which means either a pipeline per
  layout or an importer that forces one layout. The first multiplies variants that ADR-0049
  keeps few. The second hides a conversion in the importer.
- **Locations assigned per shading model.** This is flexible, but the mapping becomes data
  every model carries and every mesh is matched against. That buys nothing while the model
  set is small and engine-written.
- **Two buffers: position alone, and everything else interleaved.** This is a good
  optimisation for depth-only passes. It becomes worth reconsidering when a measurement shows
  vertex fetch mattering. It changes the buffer mapping, not the semantic table.

## Revisit if

- A game needs a ninth per-vertex semantic.
- A frame measured on a target machine is limited by vertex fetch, and interleaving is shown
  to fix it.
- A mod-shader design (ADR-0015's warning) needs locations the table cannot express.

## Revision note — 2026-09-27, at M19's close

Implemented as written. Expressing it needed one RHI fact the interface lacked: a
`VertexBufferLayout` named no slot, so its array index was the binding, and position at slot 0
with colour at slot 5 could not be declared without inventing slots 1–4. Layouts now name their
slot explicitly and may be sparse (`rhi.md` §9 and rules 6 and 10, `render3d.md` Step 6). The
table itself did not change.
