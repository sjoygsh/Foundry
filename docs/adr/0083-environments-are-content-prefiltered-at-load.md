# ADR-0083: Environments are content, prefiltered on the CPU when they load

**Status:** Proposed 2026-11-15
**Date:** 2026-11-15
**Informed by:** ADR-0053, ADR-0056, ADR-0062, ADR-0013, `docs/design/light.md` §7.3 and §14, `docs/design/environment.md` §4, §7–§9

## Context

Until M41, a 3D frame's indirect light is one constant radiance (`FrameView.ambient`). Outdoors,
that leaves a metal sphere reflecting a flat grey, and nothing stands behind the geometry but a
clear colour. Image-based lighting needs three things:
- a cube of incoming light;
- that cube prefiltered for each roughness;
- a diffuse term that integrates it.

Something must also decide where the cube comes from and when the prefiltering happens. The
RHI has no compute until M75, and HDR image formats are M116's.

## Decision

**An environment is a content record, `foundry:environment`, with a source and a face size.**
The source is either six sRGB colour textures scaled by a luminance in cd/m², or a three-colour
gradient (zenith, horizon, ground) with a luminance per colour. A mod overrides it by ID like any
other record. M116 adds an HDR image source to the same record.

**It is prefiltered on the CPU when it loads**, in `asset`'s pure decode on the background pool:
- the specular cube, one level per halving down to 8², level *k* for roughness
  *k* / (levels − 1), by GGX filtered importance sampling with a fixed Hammersley set;
- nine spherical-harmonic coefficients per channel for diffuse light.

The output is `rgba16_float` bytes and 27 floats, depend only on the record and its inputs, and
are pinned by hash. Karis's analytic DFG fit, already in the lit model, is kept; no lookup table
is added.

**One environment lights a frame.** `render3d` holds it by `EnvironmentHandle` and the frame
names it. It lights every lit draw, diffuse from the harmonics and specular from the cube by
roughness, and the constant ambient is added on top. A sky pass draws level 0 of the same cube
behind the opaque geometry and before the blended geometry, so the sky and its light always
agree.

## Consequences

- Indoor and outdoor scenes each get light that matches what surrounds them. Metals have
  something to reflect.
- A game's sky is content, changeable by a content mod with no code.
- Load time grows by the prefilter: about 8 million GGX samples for a 128 cube. This is
  measured in M41 Step 4.
- **Cost:** one environment per frame. An interior reached from outdoors needs the frame to
  change its environment, until M87's probes.
- **Cost:** without HDR sources, a sun cannot be in the sky's image. The directional light is
  the sun, and the sky's disc is M85's.
- **Cost:** the uniform grows by 160 bytes, to its fourth layout.
- With no environment, every existing frame is unchanged.

## Alternatives considered

- **Prefilter at build time in `author`, shipping the cube.** Rejected for M41: the cube would
  be compiled content derived from other content, so a mod overriding one face texture would
  need the whole environment rebuilt. It would also break the precedent that textures make
  their mips at load (`meshes.md` §4.2). The trigger is the same as for mips: a measured load
  time.
- **Prefilter on the GPU.** Rejected: there is no compute until M75, and render-to-cube
  prefiltering would make the bytes depend on the GPU, which defeats the pins.
- **A lookup table for DFG.** Rejected: the analytic fit is already shared by the oracle and
  both shaders, and its error is within the readback tolerances.
- **A procedural sky model (Preetham, Hosek–Wilkie).** Rejected for M41: it is an atmosphere,
  and it belongs with M85's scattering. A gradient is enough for the samples and is readable
  content.
- **A per-object environment.** Rejected: that is M87's reflection probes, and it needs cube
  arrays and a choice per draw.

## Revisit if

- A 512 cube takes over two seconds to prefilter on the background pool (M75 then moves it to
  the GPU).
- A shipped environment's pinned bytes differ between macOS and Windows.
- The yard's spheres differ from the oracle by more than the readback tolerance at 64 samples.
- A game needs two environments in one frame before M87.
