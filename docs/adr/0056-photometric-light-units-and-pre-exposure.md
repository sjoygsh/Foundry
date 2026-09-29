# ADR-0056: Photometric light units, pre-exposure, and one hue-preserving tone map

**Status:** Accepted 2026-09-29 when the owner requested M22 Step 1
**Date:** 2026-09-29
**Informed by:** ADR-0048, ADR-0049, ADR-0052, ADR-0053, `docs/design/3d.md` §6,
`docs/design/light.md` §3

## Context

`3d.md` §6 says M22 fixes the light-unit convention "before any content depends on it". Every
light a game or mod writes, every material's emission, and every future imported light will carry
an intensity. Whatever unit that intensity has will be permanent. Changing it later means every
scene is relit and every mod is wrong.

The choice is tied to two others:
- **How a scene's brightness reaches a 16-bit float target.** Physical values span about eleven
  orders of magnitude, from moonlight to a sunlit specular highlight. `rgba16_float` holds at
  most 65,504.
- **How the HDR image reaches an 8-bit sRGB surface.** A mod that sets a material's colour
  expects to see that colour.

## Decision

**Lights are photometric, with `KHR_lights_punctual`'s semantics exactly:**
- **Units:**
  - a directional light's intensity is illuminance, in lux;
  - a point or spot light's intensity is luminous intensity, in candela;
  - emission and ambient light are luminance, in cd/m².
- **Colour** is a separate linear factor in [0, 1].
- **Distance falloff** is inverse square, windowed to reach zero at an optional `range`.
- **A spot's cone** is two angles in radians from the light's −Z, the inner and the outer, with
  a smooth falloff between them.

**Exposure is EV100, and it is applied in the lit shader before the colour target is written**
(pre-exposure):
- the scale is `1 / (1.2 · 2^EV100)`;
- a view that names no exposure has a scale of exactly 1;
- **unlit output and the clear colour are display-referred**: they are written as authored, and
  not exposed.

**One tone map, Khronos PBR Neutral**, runs in a fixed pass after the world. It is followed by
the surface's hardware sRGB encode. There is no tone-map setting.

## Consequences

- **A glTF light maps to Foundry field for field** when light import arrives, and so will any
  tool that exports glTF lights. Two mods lighting the same game use the same scale.
- **Authors think in real quantities.** "The sun is 100,000 lux at EV100 15" is
  something a reference photograph can check. A light that is too dim is too dim in a known unit,
  not by an arbitrary factor.
- **fp16 is enough.** Exposed values stay within a few units, so a highlight never overflows to
  infinity.
- **Unlit content is unaffected by exposure.** An unlit sign reads the same at any exposure,
  which is what `KHR_materials_unlit` promises.
- **A physically exposed scene makes emission and ambient look dim unless they are realistic.**
  A screen at 1 cd/m² is invisible in daylight, as a real one would be. The design documents it,
  and does not correct for it.
- **Every pixel passes through the tone map, unlit included.** M19's and M20's readback
  expectations change by Neutral's small toe, at most 0.04 in linear value below its compression
  start. Their tests are re-expressed through the tone map, not loosened.
- **The lit shader and the Zig reference both carry the exposure scale**, so they must agree.
  Keeping them in agreement is `lighting.zig`'s job (`light.md` §7.5).

## Alternatives considered

- **Artistic, unitless intensities.** These are simpler to type. They were rejected because
  they are a private scale each author invents: glTF lights would need a guessed conversion, and
  mods from different authors would not agree.
- **Radiometric units (watts).** Photometric units are what glTF and lighting references use.
  Converting watts to lumens depends on a light's efficacy, which is a second number for every
  light.
- **Exposure applied in the tone-map pass.** This is simpler, since only one shader knows about
  exposure. It was rejected because raw sunlit highlights overflow `rgba16_float`, and a 32-bit
  target doubles the bandwidth of every pixel.
- **Exposing unlit output too.** Rejected because an unlit material would then change brightness
  with the camera's exposure, and `KHR_materials_unlit` says it does not.
- **The ACES filmic curve.** Rejected because it shifts hue and desaturates saturated colours,
  so a material's authored colour does not survive, which undermines M22's exit condition.
- **AgX.** It preserves hue better than ACES but still reshapes mid-tones. Neutral was designed
  for exactly this purpose: showing product colours as authored.
- **A choice of tone maps from the start.** Rejected because nothing asks for one yet. Adding an
  enum later, with Neutral as its default, is additive.

## Revisit if

- A game's scenes need a different tone curve, or colour grading. That is additive: an enum
  whose default is Neutral.
- A measurement shows fp16 banding or overflow that pre-exposure does not prevent. The response
  would be a wider target, not a change of units.
- Importing `KHR_lights_punctual` finds any field that does not map directly.
- Auto-exposure is added and needs exposure somewhere other than the lit shader.
