# ADR-0084: RHI textures have layers and a kind

**Status:** Proposed 2026-11-15
**Date:** 2026-11-15
**Informed by:** ADR-0003, ADR-0035, `docs/design/rhi.md` §12, `docs/design/3d.md` §4, `docs/design/environment.md` §3

## Context

Every RHI texture is a single 2D image. M41's environment needs a cube that is sampled by
direction, filtered across face seams, uploaded face by face and read back in tests. The
roadmap also names texture arrays here, and M43's glyph pages will be their first renderer
consumer. Metal and Vulkan both treat cubes and arrays as layered images with a fixed view
type.

## Decision

- `TextureDesc` gains `kind` (`d2`, `d2_array`, `cube`) and `layers`. A `d2` texture has 1
  layer, a `d2_array` 1 to 256, and a `cube` exactly 6, in the order +X, −X, +Y, −Y, +Z, −Z,
  with square faces. A multisampled texture is `d2`.
- The kind is fixed when the texture is created, and the texture is always bound as that kind.
  There is no separate view object.
- Buffer–texture copies and colour attachments name a `layer`.
- A bind group layout's sampled-texture entry declares a `dimension`. A texture of another kind
  in that slot is refused when the bind group is created.
- All of it lands on null, Metal and Vulkan in one step (`3d.md` §4's rule). Cube arrays are not
  supported.

## Consequences

- A cube and an array cost the backends one native type each, and one more field in copies and
  attachments.
- Validation catches a mismatched binding at bind-group creation, not as a wrong image at draw.
- **Cost:** reading one texture as two kinds, a cube's single face as 2D for instance, is not
  possible. No consumer needs it.
- **Cost:** `render3d` has no array consumer in M41. The arrays are proven by RHI readbacks
  alone until M43.

## Alternatives considered

- **Texture views as objects**, as in Vulkan and WebGPU. Rejected: they are a second handle
  type and a lifetime rule (ADR-0035) for a need nobody has. The trigger is a pass that reads
  one texture as two kinds.
- **A cube as six 2D textures.** Rejected: no seamless filtering, six bindings, and lookups by
  direction rebuilt in the shader.
- **Cube arrays now.** Rejected: their only consumer is M87's probes. Vulkan makes them an
  optional feature, and they would be untested.
- **Leaving arrays to M43.** Rejected by the roadmap's line, and arrays are nearly free beside
  cubes, which are the same layered images.

## Revisit if

- A pass needs one texture under two views (M87's probes are the likely first).
- A device the engine targets lacks seamless cube filtering.
- M43's glyph pages find the array's limits (256 layers, no per-layer format) wrong.
