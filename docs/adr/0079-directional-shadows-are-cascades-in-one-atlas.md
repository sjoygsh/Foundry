# ADR-0079: Directional shadows are cascades in one atlas

**Status:** Proposed 2026-11-13
**Date:** 2026-11-13
**Informed by:** ADR-0048, ADR-0052, ADR-0056, `docs/design/light.md` §9 and §14, `docs/design/3d.md` §4, `docs/design/shadows-cascaded.md`

## Context

M22 gave the frame one directional shadow map: a sphere fitted round the view frustum out to
`shadow_distance`, snapped to its texels so edges do not crawl, filtered by nine bilinear
comparison taps. One map spreads its texels evenly over the whole distance. At the 80 m a large
outdoor scene needs, such as M38's yard, a 2048 map's texel is about 8.5 cm, even at the player's
feet. `light.md` §14 named that measurement as the trigger for cascades, and ADR-0060 scheduled
them in M39.

Cascades need several shadow maps a frame. The RHI has 2D textures, comparison samplers and
viewports with origins, but no texture arrays, which the roadmap gives to M41 with cubemaps. M40's
spot and point shadows will need many maps of different sizes in the same frame.

## Decision

**The one directional caster's shadow is up to four cascades.** The shadowed range is split by
the practical scheme, a mix of logarithmic and uniform splits weighted by λ. Each cascade is
M22's sphere fit over its slice, snapped to its own texels and extended toward the light by
overlapping casters. With one cascade, the result is M22's map bit for bit.

**The cascades are tiles of one depth atlas, not layers of a texture array.** One `depth32_float`
texture holds them in a fixed grid. The caster pass draws every tile in one render pass, setting
each tile's viewport and scissor. Each draw's light matrix is folded into its inline constants,
so the pass reads no uniform. An atlas larger than the device allows is refused at `init`.

**A receiver picks its cascade by view depth** and blends linearly with the next across a band
at the end of each cascade. The last cascade fades out. Filter taps are clamped inside their
tile, and the normal offset is scaled by each cascade's own texel.

**M40's spot and point shadows take tiles of the same atlas.** M39 builds a fixed table of tiles;
M40 replaces it with an allocator.

**The count, the split weight and the blend band are the host's `Config`, not content,** and
nothing about them enters the public table.

## Consequences

- Near shadows are sharp at a long shadow distance: about 0.6 cm a texel nearest the camera
  where one map gave 8.5 cm, in the yard at the defaults.
- A caster in several cascades is drawn several times. The shadow pass's draw count can rise by
  up to the cascade count, and Steps 4 and 6 of the design measure it.
- The default atlas is 64 MiB where M22's map was 16 MiB. Four 4096 tiles need an 8,192-texel
  atlas and 256 MiB.
- Every shader that declares the frame uniform changes with its second layout.
- The pipeline's depth bias is the same for every cascade, though each covers a different depth
  range. The normal offset, which does scale, carries most of the correction.
- The RHI gains nothing, and texture arrays stay M41's.

## Alternatives considered

- **A texture array, one layer per cascade.** It is the usual answer, but it would pull an RHI
  feature forward from M41 on three backends. It also suits M40's maps of mixed sizes badly.
- **Four separate textures.** Four bindings in the lit shader's frame group, and four times the
  binding work in M40, for nothing an atlas lacks.
- **Tight box fits per slice.** They use more of each tile, but change size as the camera turns,
  so every edge shimmers. That is what M22 chose the sphere to avoid.
- **Choosing the cascade from map coordinates rather than view depth.** It can use a nearer
  cascade at a slice's edge, but it costs a transform per cascade tried. A sphere fit already
  holds its whole slice, so view depth is always correct.
- **No blending at seams.** It is cheaper, but the change of resolution shows as a line across
  the ground, which a person sees as soon as they walk.
- **Cascades as content.** Their right values depend on the host's view and budget, as M22's bias
  did. A mod changes lights, not how a host draws them.

## Revisit if

- A device Foundry supports cannot hold the atlas at the size a game needs.
- M40's tiles of mixed sizes cannot share the atlas without wasting more than a texture array
  would.
- A readback or a person shows acne or peter-panning confined to one cascade, which needs
  per-cascade bias.
- The shadow pass is measured over its share of a frame because casters are drawn into several
  tiles. That is M99's question.
