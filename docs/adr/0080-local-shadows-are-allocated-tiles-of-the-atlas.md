# ADR-0080: Local shadows are allocated tiles of the atlas

**Status:** Accepted 2026-11-14, when the owner requested M40 Step 1; implemented in M40
(complete 2026-11-15, tag `m40`)
**Date:** 2026-11-14
**Informed by:** ADR-0048, ADR-0052, ADR-0079, `docs/design/light.md` §7.1 and §14, `docs/design/shadows-cascaded.md` §4 and §13, `docs/design/shadows-local.md`

## Context

Until M40 only the directional light casts. M39 drew its cascades into tiles of one depth atlas
at fixed places, and ADR-0079 said spot and point shadows would take tiles of the same atlas,
with an allocator in place of the fixed table. Local lights come and go every frame, ask for
maps of different sizes, and a point light needs to see in every direction. The RHI has no
cubemaps or texture arrays (M41's), and its depth bias is fixed pipeline state, though a spot's
perspective depth and a cascade's orthographic depth need different biases.

## Decision

**The atlas is a row of square pages, each holding M39's four cascades, and one buddy allocator
hands out its tiles, rebuilt from nothing every frame.** The cascades are its first requests and
land exactly on M39's tiles. Local lights follow in a deterministic order: unseen lights skipped,
then nearest range sphere first, ties by submission order. Each asks for a power-of-two side from
its screen coverage, halved when the atlas is full, and dropped (counted, not refused) when even
the minimum does not fit. A frame holds at most 32 tiles.

**A spot to 60° casts into one perspective tile. A point light, and a wider spot, casts into six
90° tiles, one per cube face,** widened so the filter's clamp stays inside the face. The lit shader
chooses the face by the largest component of the light-to-receiver vector.

**Depth bias is a per-pass RHI command,** `RenderPass.setDepthBias`, dynamic state on Vulkan and an
encoder call on Metal. Binding a pipeline restores its own bias. `render3d` sets one bias for the
cascades and one for local tiles.

**The frame uniform's third layout carries every tile's rectangle, parameters and folded matrix,**
and each light finds its own tiles, so any number of lights may cast within the tile limit. One
casting directional light per frame remains the rule.

## Consequences

- Every shadow, whatever its kind, is the same thing to the lit shader: a tile, a matrix, a
  clamp and a filter. One pass, one binding and one sampler serve them all.
- The default atlas doubles M39's, to 128 MiB, so local lights have one page of their own.
- A point light draws its casters up to six times. The shadow pass's draw count grows with the
  number of casting lamps, and the room's and the court's budgets measure it.
- A frame's shadows are a pure function of its submissions: the same lights and camera give the
  same tiles. Nothing is cached, so nothing can go stale; caching is M99's.
- A light may be unshadowed in a crowded frame. That is visible, and counted in `Stats`.
- The uniform grows to 4,256 bytes and every shader that declares it changes again.

## Alternatives considered

- **Cubemaps for point lights.** The usual answer, but they are an RHI feature the roadmap gives
  M41, need a second comparison binding in every lit shader, and still need a pass per face.
- **A texture array of equal layers.** It holds maps of mixed sizes badly, which ADR-0079 already
  weighed.
- **Tiles that persist across frames.** They make a tile's place depend on history, and are only
  worth keeping when their contents are, which is caster caching (M99).
- **One pipeline per bias value.** It multiplies the shadow pipelines by the tile kinds for a
  value that is one command.
- **Refusing a light that does not fit.** The lights in a frame change as a player walks; a
  quality limit should degrade, not fail the frame.
- **Dual-paraboloid maps for points.** Two tiles instead of six, but they bend straight edges,
  need tessellated casters to look right, and filter unevenly.

## Revisit if

- A scene needs more than 32 shadow tiles a frame, or the allocator's drops are seen by a person
  in a scene a game needs.
- M41's cubemaps are measured to make point shadows cheaper or cleaner than six tiles.
- A readback shows that one bias per kind cannot serve all of that kind's tiles.
- The shadow passes are measured over their share of a frame (M99's question).
