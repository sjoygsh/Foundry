# ADR-0081: Translucent shadows are a transmittance atlas

**Status:** Accepted 2026-11-14, when the owner requested M40 Step 1
**Date:** 2026-11-14
**Informed by:** ADR-0079, ADR-0080, `docs/design/light.md` §14, `docs/design/shadows-local.md` §9

## Context

From M22 to M39 a blended material casts nothing, so a glass pane lets all light through
untouched. `light.md` §14 set translucent shadows aside until a game needed glass to cast
coloured light, and the roadmap gives them to M40. A coloured shadow must tint receivers behind
the glass and leave alone those between the light and the glass, and the pane itself.

## Decision

**Beside the depth atlas sits an `rgba16_float` colour atlas with the same tiles.** Its rgb is the
light's transmittance, cleared to white and multiplied by each translucent caster's filter colour,
`mix(1, base.rgb, base.a)`. Its alpha is the depth of the translucent caster nearest the light,
kept by the `max` blend in reversed-Z.

**Translucent casters are drawn in a second pass after the depth pass,** with the depth atlas
attached read-only and tested, so a pane behind an opaque caster adds nothing.

**A receiver multiplies its light by the transmittance only where its depth lies beyond the
stored translucent depth,** tap by tap within its filter.

**The colour atlas is made on the first frame that draws a translucent caster,** and a host may
turn translucent shadows off in its `Config`, so a host that does not want the memory never
allocates it. No blend factor or operation is added to the RHI.

## Consequences

- Glass casts its colour, stacked panes multiply, and receivers in front of glass stay untinted.
- At the default atlas the colour twin is 256 MiB, paid only by a host that draws translucent
  casters with the switch on.
- Only the nearest translucent depth is kept. A receiver between two panes is tinted by both, as
  though behind both. A scene that shows this is the trigger below.
- Half-precision depth answers "behind the glass or not" to about 1/2,048 of a tile's range, which
  a per-tile bias covers at room scale.
- The lit shaders gain two bindings and a colour read per tap when the switch is on.

## Alternatives considered

- **A third, depth-only atlas for translucent casters.** Exact depth, but another pass, another
  binding and another 128 MiB, for a question half precision answers.
- **Transmittance without depth.** Cheaper, but a player standing in front of a window would be
  tinted by it.
- **Treating blended casters as masked (dithered or cut out).** Casts holes, not colour, which is
  not what the roadmap asks for.
- **Stochastic or deep (Fourier, moment) shadow maps.** They handle many layers, at much greater
  cost and complexity than a sample with one pane needs.

## Revisit if

- A scene a game needs shows receivers between two translucent layers visibly wrong.
- The colour atlas's memory is too much for a device Foundry supports at the size a game needs.
- Particles, which are blended, come to cast in M79 and need a different filter.
