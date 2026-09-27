# ADR-0048: 3D conventions — right-handed, Y up, −Z forward, metres, quaternions

**Status:** Accepted 2026-09-27 (constraint only; M19 implements it)
**Date:** 2026-09-27
**Informed by:** ADR-0013, `rhi.md` §9, `docs/design/3d.md` §2

## Context

Every mesh, animation, save, collision shape and mod sees 3D's conventions. Changing one after
content exists breaks all of it, silently: a model turned the wrong way, or a rotation composed
backwards, looks like a bug in the game rather than an error. `core.Mat4` already fixes
column-major storage and `mul`'s order, and `rhi.md` §9 fixes clip space. Nothing yet fixes
handedness, up, forward, units, the rotation representation or how transforms compose.
`physics3d` (L1) and `render3d` (L3) must agree on all of them, and they share only `core`.

## Decision

The conventions in `docs/design/3d.md` §2 are Foundry's, in every subsystem and across the
public ABI:
- **Right-handed, +Y up, −Z forward, +X right; one unit is one metre;** radians in code and the
  ABI.
- **Column vectors, column-major storage.** `v' = M · v`; a TRS is `T · R · S`;
  `clip = P · V · W · v`; normals transform by the inverse transpose.
- **Unit quaternions** `(x, y, z, w)`, Hamilton, right-hand rule. `a ⊗ b` applies `b` first,
  like `Mat4.mul`. Stored rotations are renormalised. Invalid ones from content, mods or saves
  are refused. Interpolation takes the shorter arc. Euler angles are display only.
- **A `Transform` is local; a world transform is a derived affine matrix,** `parent_W · M_local`,
  never saved, and not assumed to decompose.
- **Counter-clockwise front faces; reversed-Z** with `depth32_float` (near 1, far 0,
  greater-or-equal, clear 0); **linear lighting with sRGB storage**; `rhi.md` §9's clip space and
  top-left texture origin unchanged.
- **Import converts nothing silently.** glTF's axes are Foundry's. An asset whose front faces
  glTF's +Z declares it, and `fpack` bakes the half-turn.
- **The world axes become `core` constants.** Projection stays in the renderer, which reads
  `rhi.clip_space`, as `core/math.zig` requires.

## Consequences

- glTF imports without axis conversion. Most tools export it, so most content needs none.
- A model authored facing +Z needs one import field, and a mismatch is visible and local.
- Reversed-Z gives usable depth precision at game distances with a 32-bit float buffer, for one
  comparison direction and one clear value.
- `core/math.zig`'s rule that it "does not know which way is up" is revised for 3D. The 2D
  spaces in `render2d.md` §4 are unchanged.
- Single-precision metres limit precise coordinates to a few kilometres from the origin. Beyond
  that is deferred, not designed.

## Alternatives considered

- **Left-handed, +Z forward (Unity, D3D tradition).** Every glTF import would convert, and the
  conversion flips winding and handedness, which is the class of bug this ADR exists to remove.
- **Z up (Blender, Unreal, most CAD).** Natural for level design, but it converts on every glTF
  import and disagrees with the camera convention every shading tutorial and tool assumes.
- **+Z forward.** It matches glTF's *model* front, but not its camera, and it makes a camera and
  a character disagree about "forward". −Z makes them one rule, with an explicit import flag for
  +Z-facing assets.
- **Euler angles or matrices as the stored rotation.** Euler angles gimbal-lock and need an
  order convention in every file. Matrices drift and carry nine numbers for three degrees of
  freedom.
- **Row vectors.** They would contradict `core.Mat4`'s existing, tested order.
- **Standard Z.** It wastes float precision exactly where perspective needs it.

## Revisit if

- A target backend cannot present `rhi.md` §9's clip space.
- A shipped world needs coordinates beyond single precision's range (a floating origin, or
  doubles in simulation, would be additive to this ADR, not a replacement for it).
- A dominant interchange format other than glTF becomes the main import path.
