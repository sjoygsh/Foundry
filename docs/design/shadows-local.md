# Design: M40 — Shadows III: spot, point and translucent shadows in tiles of one allocated atlas

**Status:** Accepted 2026-11-14, when the owner asked for Step 1, with §16 as written. Complete
2026-11-15, tag `m40`: all ten steps done. Each step's Resolution follows §16.
**Date:** 2026-11-14
**Baseline:** `7490d18`, tag `m39`. M0–M39 are complete.
**Decisions:**
- ADR-0048 (reversed-Z, right-handed, −Z forward), ADR-0052 (forward rendering, changed only on
  measurement), ADR-0056 (photometric light units), ADR-0059 (the public 3D table, frozen at v6)
  and ADR-0013 (deterministic-friendly) constrain it.
- ADR-0079 (accepted, M39): the directional light's cascades are tiles of one depth atlas, and
  "M40's spot and point shadows take tiles of the same atlas. M39 builds a fixed table of tiles;
  M40 replaces it with an allocator." This design does that.
- [ADR-0080](../adr/0080-local-shadows-are-allocated-tiles-of-the-atlas.md) (accepted 2026-11-14): spot and
  point lights cast into tiles a per-frame buddy allocator hands out from the same atlas, in a
  deterministic priority order. A point light is six tiles, one per cube face, not a cubemap. Depth
  bias becomes a per-tile command in the RHI.
- [ADR-0081](../adr/0081-translucent-shadows-are-a-transmittance-atlas.md) (accepted 2026-11-14): blended
  casters filter light through a colour atlas beside the depth atlas, which also holds the nearest
  translucent depth, so a receiver in front of the glass is not tinted.

`light.md` §7.1 refused any shadow caster but the directional one ("Point and spot shadows are
`3d.md` §11's"), and its §14 set aside translucent shadows "when a game needs glass to cast
coloured light". ADR-0060 scheduled both here. M39's §13 added three items: the tile allocator,
per-tile depth bias and contact-hardening penumbrae.

## 1. Purpose and boundary

The roadmap's row is the contract:

> **M40 — Shadows III.** Point and spot shadows; translucent shadows; also a tile allocator for
> M39's shadow atlas, per-tile depth bias and contact-hardening penumbrae
> (`shadows-cascaded.md` §13).

**The runnable result.** `sandbox3d`'s lit room (M22) is seen with every light casting:
- its two point lights throw shadows of the crates and the ledge in every direction, onto the
  floor, the walls and the ceiling;
- a new spot light over the room's glass pane throws the pane's blue-green tint on the floor,
  and the crates' shadows through it;
- the sun's cascades fall through the window as before, now softening with distance from the
  caster when the sun has a size;
- `--local-shadows=off` shows the room as M39 drew it, for comparison, and the overlay's line
  counts tiles and casters per kind.

The court's beacons cast point shadows when lit, through the court's own content, and the owner
plays it.

**The exit condition:**
- The allocator, the spot and face matrices, the priority order and the penumbra maths agree
  with a CPU oracle.
- With no local caster, no translucent caster and every source radius zero, every M22, M24 and
  M39 readback holds unchanged.
- New Metal readbacks show a spot's shadow, a point's shadow on each of its six faces and across
  a face seam, a coloured shadow under glass and none in front of it, and a penumbra that widens
  with the distance from its caster.
- The room holds 60 Hz with every light casting on macOS/Metal and on Windows/Vulkan, and Vulkan
  validation is clean.

**In M40:**
- the RHI's per-pass depth-bias command (§3);
- the atlas as pages, and the buddy allocator over them, the cascades its first requests (§4);
- local casters: which lights cast, in what order, at what size (§5);
- the spot's projection (§6) and the point's six faces (§7);
- the frame uniform's third layout (§8);
- translucent shadows (§9);
- contact-hardening penumbrae (§10);
- configuration, statistics and the overlay (§11);
- the room and the court (§12).

**Not in M40, each owned elsewhere:**
- Cubemaps and texture arrays in the RHI: M41, unchanged. A point light is six atlas tiles (§7).
- Particles casting and receiving shadows: M79.
- Screen-space contact shadows and the depth prepass: M81.
- Rotating the penumbra's sample pattern per pixel, which needs a temporal resolve to hide its
  noise: M82, with TAA (§10).
- Ray-traced shadows: M98.
- Caching shadow tiles across frames, skipping faces a wide spot cannot see, and drawing one
  caster into several tiles at once: M99 (§15).
- GPU timing of the shadow passes: M73.
- Mod lights that cast: a v6 light still refuses `casts_shadow` (`instances.zig`), and letting a
  mod's light cast is a publication decision for M48 (§13).

## 2. What exists

**`engine/src/render3d/lighting.zig`:**
- `Light` has `kind` (directional, point, spot), colour, intensity, `range` (0 unbounded),
  `inner_cone`, `outer_cone` (up to π/2), `casts_shadow` and `world`.
- `PackedLight` is four `vec4`s; `cone_shadow` holds the two cone cosines, a casting flag in `z`,
  and nothing in `w`.
- `FrameUniform` is M39's second layout, 1,520 bytes: four tile rectangles, four folded
  matrices, four splits and four normal offsets.
- `fitCascades`, `cascadeSplits`, `tileMatrix`, `chooseCascade` and `cascadeTint` are the
  cascade oracle. `attenuation`, `spotCone`, `brdf` and `shade` are the lit oracle.

**`engine/src/render3d/renderer.zig`:**
- `addLight` refuses a second caster, or a caster that is not directional, as
  `InvalidShadowCaster` (line 1793).
- `shadowAtlasExtent`, `shadowTileOrigin` and `shadowTileRect` are M39's fixed table: `s×s`,
  `2s×s` or `2s×2s`, cascade `i` at column `i mod 2`, row `i / 2`.
- Preparation fits the cascades, culls each draw against each cascade's light box, and stores a
  `u4` mask on the draw (`DrawItem.shadow_cascades`). Blend materials never cast (line 1896).
- `recordShadow` makes one pass over the atlas: per cascade, a viewport and scissor, then each
  masked caster with the light matrix folded into its constants. The pipeline's depth bias is
  fixed state, set from `Config.shadow_bias_*` when each shadow pipeline is built.
- `Stats` has `shadow_draws`, `shadow_culled`, `shadow_cascades` and `shadow_cascade_draws`.

**The shaders.** `lit.metal` and `lit.frag.glsl` pick a cascade by view depth, blend across its
band, and call `cascadeVisibility`: a normal offset, one multiply by the folded matrix, a tile
test, and nine bilinear comparison taps clamped inside the tile. Every light whose `cone_shadow.z`
is set multiplies its falloff by that visibility, which is why only one light may cast today.

**The RHI:**
- `DepthBias` (constant, slope, clamp) is part of `DepthStencilState` in a pipeline.
  - Metal applies it on the encoder when a pipeline is set (`fd_mtl_render_encoder_set_depth_bias`),
    so it is already dynamic underneath.
  - Vulkan bakes it into `VkPipelineRasterizationStateCreateInfo`. Viewport and scissor are the
    only dynamic states.
- Blending has `zero`, `one`, `src_color` and the alpha factors, and the `min` and `max`
  operations, separately for colour and alpha. `rgba16_float` is a render target that can be
  sampled (M22's HDR frame).
- `Frustum.fromViewProjection` (M20) culls against any projection, perspective included.

**The samples:**
- `sandbox3d`'s room has the sun (casting) and two point lights of range 8 m, from
  `sandbox3d:config.main`'s `lights`, whose schema already carries `casts_shadow` for every kind.
  `sandbox3d:materials.glass` is a blended, double-sided pane in the room model.
- The court adds one point light per lit beacon in code (`samples/court/main.zig:731`), from the
  beacon's content (colour, intensity, range).
- Mod lights (`render3d.Instances`, M25) refuse `casts_shadow`.

## 3. Depth bias per tile (`rhi`)

**What M39 left:** one bias for every tile, because bias was pipeline state. A spot's perspective
depth and a cascade's orthographic depth are different quantities, so one constant cannot suit
both: a constant bias in a 32-bit float depth buffer is scaled by the depth value's exponent,
and a perspective tile's depths crowd near 1 in reversed-Z while a cascade's spread evenly.

**The change:** `RenderPass.setDepthBias(DepthBias)`, recorded like `setViewport`.
- **Metal:** the encoder call it already makes, now also made on demand. Setting a pipeline still
  applies that pipeline's own bias, so code that never calls the command is unchanged.
- **Vulkan:** every pipeline whose depth bias is enabled also declares `VK_DYNAMIC_STATE_DEPTH_BIAS`,
  which is core 1.0, and `vkCmdSetDepthBias` records it. Because dynamic state must be set before
  a draw, binding such a pipeline records its own bias too, so Vulkan behaves as Metal does.
- **Null:** records it, and refuses a non-finite value or a call outside a pass, as it refuses a
  bad viewport (`InvalidCommand`).
- A clamp needs `depthBiasClamp`, which the Vulkan backend already requires.

**Why a command, not a pipeline per bias:** one pipeline per tile kind and bias value would
multiply the shadow pipelines by the kinds (cascade, spot, face), and every one is built the first
time a caster meets it. A dynamic value costs one command per tile.

**The values:** `render3d` sets a tile's bias from its kind.
- Cascades use `Config.shadow_bias_constant`, `_slope` and `_clamp` as now, the same in every
  cascade. M39 measured no acne confined to one cascade, which was the trigger for scaling them,
  so they are not scaled. The mechanism now exists to do it per cascade if a readback asks.
- Spot tiles and point faces use `Config.shadow_local_bias_constant`, `_slope` and `_clamp`.
  Step 3 chooses the defaults from the readbacks of §13 and records them in its Resolution;
  the starting values are M22's (−1, −1, 0).

**Now / designed for / postponed:**
- **Now:** a bias per tile, set from its kind.
- **Designed for:** a bias per tile computed from the tile's own depth range, if a readback shows
  one kind's value cannot serve all its tiles.
- **Postponed:** nothing.

## 4. The atlas as pages, and the allocator (`render3d`)

**The atlas becomes a row of square pages.** Each page is `2s` texels a side, where `s` is
`Config.shadow_size` (the cascade tile, 2048 by default), so one page holds M39's four cascades
exactly. `Config.shadow_atlas_pages` (1 to 4, default 2) sets how many.

| Pages | Atlas, at `s = 2048` | `depth32_float` |
| --- | --- | --- |
| 1 | 4,096 × 4,096 | 64 MiB, M39's four-cascade size |
| 2 (default) | 8,192 × 4,096 | 128 MiB |
| 4 | 16,384 × 4,096 | 256 MiB |

An atlas wider than the device's `max_texture_dimension` is `InvalidConfig` at `init`, as M39's
was. At `s = 4096` two pages are 16,384 wide, which the M5 and the Arc allow, and four are
refused.

**The allocator** (`render3d/shadow_atlas.zig`, pure, no device) is a buddy allocator, one
quadtree per page:
- A request is a power-of-two side from 128 to `2s`.
- It takes the first free square of that size in a fixed walk: pages in order, then quadrants in
  row-major order (top-left, top-right, bottom-left, bottom-right), recursively. A square is split
  only when nothing of its size is free.
- It is rebuilt every frame from nothing. Nothing persists between frames, so the same requests in
  the same order give the same tiles, and there is no fragmentation to manage (I9's spirit, as
  light order is).
- It never moves a granted tile, and refuses a request it cannot place, which §5 answers.

**The cascades are its first requests.** Cascade `i` asks for `s` before any local light asks
for anything. With an empty page 0, the walk grants quadrant `i`, which is M39's tile `i`: column
`i mod 2`, row `i / 2`. A test proves the grant equals M39's table for one to four cascades.
- With fewer than four cascades, page 0's other quadrants are free for local tiles.
- Only the atlas width changes, so each cascade's UV rectangle narrows. Its texels, its fit and
  its depth do not, so every M39 readback holds within its tolerance. A test pins the texel
  rectangle, not the UV.

**Why pages and not one large square:** a square big enough for the cascades and several local
lights is 8,192 a side at the default, 256 MiB. Pages let the default add exactly one cascade
area's worth (64 MiB) for local lights, and let a host trade memory for local resolution.

**Why rebuild every frame:** tiles that persisted would make a tile's place depend on the history
of which lights came and went, and a cached tile is only worth keeping once its contents are kept
too, which is M99's caster caching. Rebuilding costs a few hundred operations a frame.

**Now / designed for / postponed:**
- **Now:** pages, one buddy allocator rebuilt per frame, and requests in priority order.
- **Designed for:** tiles kept across frames for lights and casters that did not move, which needs
  only a way to pin a request's place before the walk.
- **Postponed:** that caching (M99).

## 5. Which local lights cast, in what order, at what size

**A local light casts when `casts_shadow` is set,** whatever its kind. `addLight` now refuses
only a second casting directional light (`InvalidShadowCaster`). Any number of point and spot
lights may ask, up to the sixteen lights a frame already allows.

**A light is seen or not.** One whose range sphere lies wholly outside the camera's frustum casts
nothing this frame, and `Stats.shadow_lights_unseen` counts it. Its light reaches nothing the
camera sees. A light with range 0 (unbounded) is always seen.

**Priority:** the seen casting lights are ordered by the distance from the camera to the nearest
point of their range sphere, nearest first, ties broken by submission order. A light whose sphere
holds the camera has distance 0. Range 0 counts as distance 0. This order is a pure function of
the frame's submissions (I9's spirit).

**Size:** each light asks for a tile side from its screen coverage.
- The coverage is the range sphere's projected diameter in pixels, as M20's bounds projection
  computes it, capped at the target's larger side. Range 0 covers the whole target.
- The request is the power of two at or above half the coverage, clamped to
  `[shadow_local_min, shadow_local_max]` (defaults 256 and 1024). A point asks for six tiles of
  that side, a spot for one (§6, §7).
- Half the coverage, because a local shadow is filtered over a 4-texel footprint and a tile at a
  pixel per texel is more than the eye resolves. Step 3 checks it against the spot readback.

**When the atlas is full:** a light whose tiles do not fit asks again at half the side, down to
`shadow_local_min`. A point light asks for all six faces at one side, never mixed sizes, so its
faces filter alike and its seams match. A light that cannot fit at the minimum casts nothing this
frame, and `Stats.shadow_lights_dropped` counts it. It is still lit, just unshadowed.

**The tile limit.** A frame holds at most `max_shadow_tiles = 32` tiles: four cascades and 28
local tiles (four point lights and four spots, or 28 spots). The limit is compiled into the
uniform (§8), as `max_lights` is. A light that would pass it is dropped as above.

**Why drop rather than refuse:** casting is a request about quality, not correctness, and the
lights a scene submits can change every frame. A refusal would make the frame fail when the
player walks into a room with one lamp too many. M22's limits on lights are refusals because they
are about the uniform's shape; this one is about the atlas's space, which varies.

## 6. The spot's projection

**A spot whose outer cone is at most π/3 (60°) casts into one tile** through a perspective
projection down its −Z:
- the field of view is twice the outer cone, widened so the clamp's inset and the filter's
  footprint (§10) fall outside the cone, as §7 widens a face;
- reversed-Z, as every depth here (ADR-0048);
- near is `Config.shadow_local_near` (default 0.05 m); far is the light's range, or
  `Config.shadow_local_far` (default 50 m) when its range is 0;
- the up axis is the light's local +Y, so a spot's tile does not spin as the light turns about
  its axis, and is the same for the same world matrix.

**A wider spot casts as a point light does,** through six faces (§7). One perspective projection
cannot reach π/2 a side, and at 60° its edge texels are already stretched to twice the centre's
area. A wide spot is rare enough that six tiles are an acceptable price. Skipping the faces its
cone cannot see is M99's (§15).

**Its casters** are the frame's opaque and mask draws whose material casts, culled against the
tile's frustum by `Frustum.fromViewProjection`, the test M39 runs per cascade. The draw's tile
mask grows from M39's `u4` to a `u32` over all 32 tiles, `DrawItem.shadow_tiles`.

**Its lookup:** the receiver, offset along its normal, is multiplied by the tile's folded matrix,
divided by `w`, and tested against the tile's rectangle and depth range. Outside the tile, it is
outside the cone too, so the spot's own falloff is already zero there and visibility is 1.

**The normal offset scales with distance.** A perspective texel grows with distance from the
light. The tile carries the texel size at one metre, `2·tan(fov/2) / size`, and the shader
multiplies it by the receiver's depth along the light's axis and by `shadow_normal_offset`.

## 7. The point light's six faces

**A point light casts into six tiles, one per cube face,** in the fixed order +X, −X, +Y, −Y,
+Z, −Z. Each is a 90° perspective projection (§6's rules for near, far and reversed-Z), with the
up axes of the usual cube-map convention so the six tiles meet without rotation.

**Why six tiles and not a cubemap:**
- the RHI has no cubemaps, and the roadmap gives them to M41 with texture arrays;
- an atlas tile is what every other shadow is, so one pass, one binding, one filter and one bias
  command serve every kind;
- a cubemap would need its own comparison sampler binding in every lit shader, and its own pass
  per face anyway.

The price is that the shader picks the face itself, and the seams between faces need care.

**Face choice:** the vector from the light to the receiver's offset position is compared by its
largest absolute component, ties broken in the face order. That face's tile is read. The same rule
on the CPU (`lighting.chooseFace`) is the oracle.

**Seams.** A receiver near a face's edge filters across the edge of its tile, where the clamp
holds its taps. Each face is therefore widened, so that its tile, inset by the clamp's two texels
and the filter's widest footprint, still covers its full 90°:

```
tan(half fov) = 1 / (1 − 2·(inset + footprint) / size)
```

A point near a seam then reads its face's own valid texels, and the two faces it lies between
agree within a texel's error. A readback (§13) runs a shadow edge across a seam and finds no step.

**Its casters** are culled per face, against the face's frustum, as a spot's are. A caster
straddling faces is drawn into each, and counted in each.

**Its lookup:** as a spot's, with the face's tile and matrix, and the normal offset scaled by the
receiver's distance along the face's axis.

## 8. The frame uniform, third layout

`FrameUniform` is replaced again, as M39 replaced M22's: the shadow block becomes per tile. Its
members, all `vec4`-aligned:

| Member | Size | Holds |
| --- | --- | --- |
| `view_projection` | 64 | unchanged |
| `camera_exposure` | 16 | unchanged |
| `ambient` | 16 | unchanged |
| `counts` | 16 | x: lights; y: cascades; z: the tint; w: the translucent switch (§9) |
| `camera_forward` | 16 | unchanged: forward axis and the band |
| `shadow_splits` | 16 | unchanged |
| `shadow_parameters` | 16 | x, y: the reciprocal atlas size; z, w: the clamp's inset |
| `shadow_tiles` | 32 × 16 | each tile's UV rectangle |
| `shadow_tile_parameters` | 32 × 16 | x: normal offset (metres, or metres per metre of distance); y: 0 orthographic, 1 perspective; z: the penumbra scale (§10); w: the translucent depth bias (§9) |
| `shadow_matrices` | 32 × 64 | each tile's matrix, folded into its UV |
| `lights` | 16 × 64 | `cone_shadow.z` becomes the light's first tile plus one (0: casts nothing this frame); `w`, its tile count (cascades, 1 or 6) |

- The total is 4,256 bytes. Vulkan guarantees 16 KiB of uniform range, and Metal's constant
  buffers bound by offset have no such limit. Each lit, unlit and particle shader asserts 4,256.
- `shadow_offsets` leaves, since the offset is per tile now.
- The directional light's tiles are always 0 to `counts.y − 1`, so its lookup is M39's code with
  the offset read from the tile.
- A light's shadow is found from its own `cone_shadow`, so any number of lights may cast, and the
  "one caster" rule in the shader goes.

**Why 32 tiles in the uniform and not a storage buffer:** the RHI's lit pipelines bind one
uniform in group 0, and 4 KiB is small. A storage buffer would be a second binding in every lit
shader on every backend for no measured need. M73's bindless binding is where the frame's data
moves when it outgrows this.

## 9. Translucent shadows (ADR-0081)

**What casts:** a blend material whose model reads `casts_shadow` and whose material sets it.
M22 to M39 skipped every blend material in the shadow pass. Mask materials are already in the
depth pass and stay there, holes and all.

**A second atlas, `rgba16_float`, the same size as the depth atlas,** with the same tiles:
- rgb is the light's transmittance through every translucent caster in front of it, cleared to
  white and multiplied by each caster's filter colour;
- a is the depth of the translucent caster nearest the light, cleared to 0 (far, in reversed-Z),
  kept by the `max` blend.

**A filter colour** is `mix(1, base.rgb, base.a)`: a pane with alpha 0 passes all light, one with
alpha 1 passes only its own colour, and a black opaque-looking blend surface shadows fully. The
base colour is the material's factor times its texture and the vertex colour, as the lit shader
computes it. It is a filter, not a physical transmission model; M41's environment and any later
refraction do not change it.

**The pass:** after the depth pass, a second pass over the colour atlas with the depth atlas
attached read-only, depth test `greater_equal`, no depth write:
- each translucent caster is drawn into each tile whose frustum it meets, with blend state colour
  `src·0 + dst·src` (zero, `src_color`) and alpha `max`;
- the depth test discards translucent fragments behind an opaque caster, which could never reach
  a receiver;
- its shader is the shadow vertex shader with a new fragment stage that computes the filter
  colour, and writes its depth into alpha.

No blend factor or operation is added to the RHI: multiply and `max` are already there.

**The lookup:** in each of the nine filter taps (or the penumbra's, §10), the receiver reads the
colour atlas with a point sampler at the tap's coordinate. If its own depth lies beyond the
translucent depth by more than the tile's translucent bias, the tap contributes the transmittance,
otherwise white. The light's colour is multiplied by the average, after the opaque visibility.
- A receiver in front of the glass (nearer the light) is not tinted.
- The pane itself is not tinted by its own shadow, because its depth equals the stored one within
  the bias.
- With no translucent caster in a frame, `counts.w` is 0 and the shader skips the colour atlas.

**It is made when first needed.** The colour atlas is created the first frame a translucent
caster is drawn, as M22's map was made on first use, and kept. At the default it is 256 MiB, so
`Config.shadow_translucent` (default true) lets a host refuse it; with it false, blend materials
cast nothing, as before.

**Why one colour atlas with depth in alpha, not a third depth atlas:** a separate depth target
for translucent casters doubles the passes and adds a binding. Half-precision depth is coarse
(about 1/2,048 of a tile's range), but the question it answers is only "is the receiver behind
the glass", which needs a centimetre at a room's scale, and the bias is per tile.

**Bindings:** group 0 gains binding 3, the colour atlas (or a 1×1 white fallback), and binding 4,
a point sampler. The fallback keeps one layout, as M22's 1×1 depth fallback does.

## 10. Contact-hardening penumbrae

**A light gains a size:** `Light.source_radius: f32 = 0`.
- For a point or spot it is the emitter's radius in metres; for the directional light it is its
  angular radius in radians (the sun's is about 0.0047).
- Finite and at least zero; a directional one at most π/8, and a local one less than its range
  when the range is bounded (`InvalidLight`).
- **Zero is M39's filter exactly:** the nine bilinear taps, so every existing readback holds.
- It is `render3d`'s, not content: the samples' config records gain a field for it (§12), and a
  v6 light's is 0 (§13).

**With a size, the shadow is found in three stages:**
1. **The blocker search.** Sixteen depth reads, with a point sampler on the same depth atlas, on a
   fixed disc whose radius is the light's size projected through the receiver into the tile. Those
   nearer the light than the receiver are averaged; with none, the receiver is lit and stops here.
2. **The penumbra.** Its width in the tile is the gap between receiver and blocker times the
   light's size over the blocker's distance: for a perspective tile
   `(d_receiver − d_blocker) · radius / d_blocker`, and for a cascade
   `(d_receiver − d_blocker) · tan(angular radius)`, both in linear depth, converted to texels by
   the tile's penumbra scale (`shadow_tile_parameters.z`).
3. **The filter.** Sixteen bilinear comparison taps on a fixed disc of that width, at least M39's
   1.5 texels and at most `Config.shadow_penumbra_max` texels (default 12), each clamped inside its
   tile.

So a post's shadow is sharp where the post meets the ground and soft at its far end, which is what
the readback of §13 measures.

**The fixed disc.** The same sixteen offsets everywhere, a Vogel spiral written into both shaders
and `lighting.zig`. A per-pixel rotation would trade the banding of wide penumbrae for noise,
which needs a temporal resolve to hide; that is M82's TAA. Without it the oracle and the readbacks
stay exact.

**The clamp and the widening.** Every tap stays inside its tile, inset by two texels. A face's and
a spot's widening (§6, §7) includes `shadow_penumbra_max`, so a penumbra at a seam still reads its
own face.

**The cost** falls only on lights with a size, and only on receivers inside their tiles: 32 reads
where M39 made nine. Steps 7 and 9 measure it in the room.

## 11. Configuration, statistics, the overlay

**`Config` gains**, all the host's and not content, as M22 kept bias:
- `shadow_atlas_pages: u32 = 2`, 1 to 4 (§4);
- `shadow_local_min: u32 = 256` and `shadow_local_max: u32 = 1024`, powers of two from 128 to
  `2·shadow_size`, min ≤ max (§5);
- `shadow_local_near: f32 = 0.05` and `shadow_local_far: f32 = 50`, finite, 0 < near < far (§6);
- `shadow_local_bias_constant`, `_slope` and `_clamp`, finite (§3);
- `shadow_translucent: bool = true` (§9);
- `shadow_penumbra_max: f32 = 12`, finite, 1.5 to 32 texels (§10).

Anything else is `InvalidConfig`.

**`FrameView` gains `local_shadows: bool = true`,** so a sample can switch them off per frame for
comparison. With it false, local lights cast nothing and the frame is M39's.

**`Stats` gains:**
- `shadow_tiles`, granted this frame, cascades included;
- `shadow_local_lights`, `shadow_lights_unseen` and `shadow_lights_dropped` (§5);
- `shadow_local_draws` and `shadow_translucent_draws`, beside M39's per-cascade draws;
  `shadow_draws` stays the sum of every caster draw.

**`Renderer.shadowTiles()`** returns the last frame's grants (light index, kind, face, rectangle
in texels), as `shadowCascades()` returns the fit, so a host can report them.

**The overlay's profiler line** gains a second line:
`3D: 2 local lights  13 tiles  210 local draws  4 translucent  0 dropped`. It is an ordinary
`Stats` read, and widens no grant.

## 12. The samples

**`sandbox3d`'s room:**
- Its two point lights set `casts_shadow true` in `sandbox3d:config.main`, and a third light, a
  spot of 60° outer cone over the glass pane, is added there. All three are content, so the dusk
  mod can change them.
- The light schema gains `source_radius f32 (default 0)`. The sun gets 0.0047 and the lamps 0.05,
  so penumbrae show at the defaults.
- New flags: `--local-shadows=off`, which sets `FrameView.local_shadows` false, and
  `--penumbra=off`, which submits every light with radius 0. **J** toggles local shadows while
  walking. The overlay shows the tile line.
- The exit report logs each granted tile (light, kind, face, size) and the local draw counts.
- The tour's pins do not move, since rendering does not reach the simulation, and the tour is run
  to prove it, with local shadows on and off.

**The court:**
- Its beacon record gains `light_casts_shadow bool (default true)`, read where the sample adds
  each lit beacon's light. No rule or simulation changes; the four digests hold.
- The owner plays it.

**`--shadow-proof`** gains nothing. §13's readbacks are the proof.

## 13. The public table, platforms and verification

### The public table

**Nothing.** FoundryApi_v6 is frozen (ADR-0059). Its lights still refuse `casts_shadow`
(`instances.zig:267`, `calls_public3d.zig:66`), and its lights have no source radius, so a mod's
light is lit and unshadowed exactly as now. Whether a mod's light may cast, and how many, is a
budget a host must grant; M48's row gains "mod lights that cast, by host grant, and a light's
source radius", which Step 10 writes.

### Platform assessment

**Metal (macOS, Apple M5):**
- The depth-bias command already exists underneath. `depth2d::sample` with a plain sampler for the
  blocker search, beside `sample_compare`.
- A 8,192 × 4,096 atlas and its colour twin are within the device's limits.

**Vulkan (Windows, Arc A750):**
- `VK_DYNAMIC_STATE_DEPTH_BIAS` and `vkCmdSetDepthBias`, both core 1.0.
- The depth atlas read through both a comparison sampler and a plain one, as separate sampler
  objects on one sampled image, which core Vulkan allows.
- The colour atlas pass loads the depth atlas as a read-only attachment, `DEPTH_STENCIL_READ_ONLY`
  layout, then both are read by the lit pass.
- The GLSL variants change with the uniform and the new fragment stage, recompiled by the pinned
  SDK tools (ADR-0038).
- **The PC is needed:** the RHI, the shaders, the uniform and the readbacks change, and Step 9
  runs the Vulkan suites, the readbacks, both samples windowed and the budgets.

**Linux:** compile only, confirmed at the close. None of `3d.md` §10.2's triggers fires.

### Verification

**Headless, in `zig build test` (null backend and Metal):**
- **The RHI:** `setDepthBias` is recorded, refused outside a pass and for a non-finite value, and
  a pipeline bound after it restores its own.
- **The allocator:**
  - one to four cascades are granted M39's tiles, by texel rectangle;
  - requests in a fixed order give the same tiles every time, and a test pins a mixed set;
  - a request too large for any free square is refused, and a smaller one after it still fits;
  - no two grants overlap, checked over a seeded sweep of a thousand request lists.
- **Priority and size:** nearest sphere first, ties by submission; a sphere holding the camera is
  distance 0; an unseen light gets nothing and is counted; coverage gives the documented power of
  two; a full atlas halves a request and then drops it.
- **Matrices:** a spot's tile holds its cone and its depth runs near to far; each face's widened
  frustum, inset, still covers its 90°; the six faces cover the sphere; face choice by the largest
  component, ties in face order.
- **The uniform:** every member's offset and the size of 4,256 bytes, which every shader asserts.
- **Configuration and lights:** every new field's refusal; a second casting directional light is
  still `InvalidShadowCaster`; a point or spot that casts is accepted; a source radius that is
  negative, NaN, too wide, or past the range is `InvalidLight`.
- **Casters per tile:** a crate beside a point light is drawn into the faces it meets and culled
  from the others; tile masks sum to the draw counts; blend materials join only the translucent
  pass, and only when `shadow_translucent` is on.

**Metal readbacks, against the CPU oracle as before (±2/255, penumbra pixels excluded unless the
test is about them):**
- **Nothing local, no size:** every M22, M24 and M39 readback holds.
- **A spot:** a crate under a spot shadows the floor where the oracle says; a receiver outside the
  cone reads unlit, and one inside but unoccluded reads lit.
- **A point, on every face:** a cube with a crate on each side of a point light, so each face's
  tile has one caster, shadows each wall.
- **A seam:** a long bar's shadow crossing from one face to the next has no step above the
  tolerance at the seam.
- **Glass:** under a blue pane, a lit receiver reads the light times the filter colour; one
  between the light and the pane reads untinted; the pane itself is not darkened by its own
  shadow.
- **A penumbra:** a vertical post under a sized light gives a shadow whose measured edge width
  grows with the distance from the post's foot, as the oracle's widths do, and is M39's 1.5 texels
  at the foot. With radius 0 the same scene is M39's picture.
- **Two kinds at once:** the sun's cascades and a point light shadow the same receiver, and the
  result is the oracle's sum of the two visibilities.

**Each guard is broken once** and must fail its test:
- the allocator's overlap check removed;
- face order swapped;
- a face's widening removed;
- the spot's perspective divide dropped;
- the translucent depth comparison inverted;
- the penumbra width's distance ratio inverted;
- the depth-bias command not issued for a local tile.

**The samples:**
- `sandbox3d` thirty frames headless with local shadows on and off, and the tour with every pin
  held.
- `court-test` with its four digests.
- Windowed and relocated: the room with every light casting, with local shadows off, with
  penumbrae off, and the court.

**Budgets, p95, from relocated ReleaseSafe installs, judged by frame work as M39's were:**
- **The room**, with the sun's four cascades, two point lights, the spot and the glass: a whole
  frame within 16.67 ms with no skipped frames, on the M5 and on the i3/Arc. `render.world` is
  recorded with local shadows on and off, so their cost is a number.
- **The court:** with every beacon lit and casting, frame pacing unchanged against M39's.

## 14. Implementation order — ten steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

### Step 1 — `rhi`: depth bias per pass command

§3 in the RHI: `RenderPass.setDepthBias` on null, Metal and Vulkan, Vulkan pipelines with bias
declaring it dynamic, and a pipeline's bind restoring its own. `render3d` still sets nothing new.
Tests: §13's RHI tests, and a Metal readback that two tiles drawn with different biases differ
in depth as the bias says.
**Exit:** the command records on all three backends, every existing shadow readback holds, and
the Vulkan checks compile.

### Step 2 — `render3d`: the allocator, priority, sizes and matrices, as maths

§4's allocator in `shadow_atlas.zig`, §5's priority and size, §6's and §7's matrices and face
choice in `lighting.zig`, §11's `Config` fields and `Light.source_radius` validation. The renderer
places its cascades through the allocator on pages, still casting nothing local.
**Exit:** the allocator grants M39's tiles for one to four cascades, every refusal and sweep test
passes, and every M39 readback holds through the paged atlas.

### Step 3 — `render3d`: the third uniform and spot shadows

§8 in Zig, MSL and GLSL. `addLight` accepts casting spots. Spot tiles allocated, culled, drawn
with their own bias and looked up. Statistics and the overlay's line. The local bias defaults
chosen from the readbacks.
**Exit:** the spot readbacks pass, every earlier readback holds, the uniform is 4,256 bytes in all
three languages, and the spot guards fail when broken.

### Step 4 — `render3d`: point shadows

§7: six widened faces, face choice in the shaders, wide spots through faces.
**Exit:** the every-face and seam readbacks pass, and the face guards fail when broken.

### Step 5 — `render3d`: translucent shadows

§9: the colour atlas made on first need, the second pass, the filter fragment stage, bindings 3
and 4 with their fallback, the lookup.
**Exit:** the glass readbacks pass, with `shadow_translucent` off blend materials cast nothing,
and the comparison guard fails when inverted.

### Step 6 — `render3d`: contact-hardening penumbrae

§10: the blocker search, the penumbra, the filter, the disc in both shaders and the oracle.
**Exit:** the penumbra readback's widths match the oracle's, radius 0 is M39's picture, and the
ratio guard fails when inverted.

### Step 7 — `sandbox3d`: the room, every light casting, on Metal

§12's room: the content lights and the spot, `source_radius` in the schema, the flags, the J key,
the exit report, the tour with local shadows on and off, and the room's budgets from a relocated
ReleaseSafe install.
**Exit:** the room's whole frame holds 16.67 ms at p95 on the M5 with every light casting, and
every tour pin holds.

### Step 8 — the court

§12's court: `light_casts_shadow` in the beacon record, `court-test`'s digests, a relocated run of
each ending, and the owner plays it.
**Exit:** the four digests hold, the court's pacing is unchanged with every beacon casting, and
the owner has played it.

### Step 9 — Windows/Vulkan

`scripts/m40/`, from M39's. On the owner's PC, idle first, from a clone, `-j2` at below-normal
priority:
- the null and Vulkan suites, with the Vulkan readbacks at ±3/255;
- every pin;
- the installed content bytes against the Mac's;
- the room and the court, windowed and relocated, validation clean;
- the budgets on the i3.

**Exit:** every readback, pin and byte equals the Mac's, validation is clean, and the room holds
16.67 ms at p95 on the Arc with every light casting.

### Step 10 — Close M40

Resolve the contract discrepancies in their documents:
- `light.md` §7.1 (any light may cast; one directional caster), §9 (the atlas is allocated), and
  §14's point/spot and translucent rows struck through;
- `shadows-cascaded.md` §4's fixed table (now the allocator's first grants) and §13's M40 items;
- `3d.md` §11's point and spot shadows;
- `render3d.md`'s shadow passes, and `debug-overlay.md` §7.5's second line;
- `public3d.md`'s note that mod lights do not cast, pointing to M48.

Then:
- move ADR-0080 and ADR-0081 to Accepted and into `CLAUDE.md` §4.1, and update §4.3's `rhi` and
  `render3d` lines and §9's row;
- add M40's costs and `scripts/m40` to `AGENTS.md`;
- update the roadmap (M40 done; §15's items in the rows of M48, M82 and M99), the design index,
  the README and `PROJECT_STATE.md`;
- tag `m40`, push when asked, and stop before M41's design.

## 15. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).
- **Cubemaps and texture arrays:** M41. Point shadows do not need them (§7).
- **Particles casting and receiving shadows:** M79.
- **Screen-space contact shadows:** M81.
- **A per-pixel rotation of the penumbra's disc:** M82, whose temporal resolve hides its noise.
- **Tiles kept across frames, skipping a wide spot's unseen faces, and one caster drawn into
  several tiles at once:** M99, with caster caching. The trigger is a shadow pass measured over its
  share of a frame.
- **GPU timing of the shadow passes:** M73.
- **Mod lights that cast, and a light's source radius in the public table:** M48.
- **Per-cascade bias computed from each cascade's range:** not built, because M39 measured no
  acne confined to one cascade. The command exists, so it is a value change in `render3d` if a
  readback shows it, inside whichever milestone sees it.

## 16. Decisions acceptance fixes

Each is recommended as written.

| # | Choice | Where |
| --- | --- | --- |
| 1 | Depth bias becomes a per-pass RHI command, `setDepthBias`, dynamic on Vulkan, already dynamic on Metal; a bound pipeline restores its own (ADR-0080) | §3 |
| 2 | Cascades keep one bias for all; spots and faces share a second, `shadow_local_bias_*`, chosen in Step 3 | §3 |
| 3 | The atlas is a row of `2s` square pages, two by default (128 MiB); one buddy allocator, rebuilt each frame, grants the cascades first, which land on M39's tiles (ADR-0080) | §4 |
| 4 | Any point or spot light may cast; a second casting directional light is still refused | §5 |
| 5 | Unseen lights cast nothing; seen ones go nearest sphere first, ties by submission; size from half the screen coverage, 256 to 1024; a full atlas halves a request, then drops it, counted, never refused | §5 |
| 6 | At most 32 tiles a frame, compiled into the uniform | §5, §8 |
| 7 | A spot to 60° is one perspective tile; a wider one casts as a point | §6 |
| 8 | A point light is six widened 90° tiles of the atlas, not a cubemap; the shader picks the face (ADR-0080) | §7 |
| 9 | `FrameUniform`'s third layout, 4,256 bytes, per-tile rectangles, parameters and matrices; a light finds its own tiles | §8 |
| 10 | Translucent shadows: a lazily made `rgba16_float` atlas of transmittance and nearest translucent depth, multiplied and `max`-blended, a filter colour of `mix(1, base, alpha)`, host-switchable (ADR-0081) | §9 |
| 11 | `Light.source_radius` (metres, or radians for the sun); zero is M39's filter; with a size, 16 blocker reads and 16 taps on a fixed Vogel disc, the penumbra capped at 12 texels | §10 |
| 12 | The new `Config` fields, `FrameView.local_shadows`, the statistics and a second overlay line | §11 |
| 13 | The room's lamps cast and a spot lights the glass, all content; the court's beacons cast through a content field; the owner plays it | §12 |
| 14 | Nothing in the public table; mod lights still do not cast, and M48's row gains that | §13 |
| 15 | The PC runs Step 9; Linux is compile only | §13 |
| 16 | Ten steps: bias, maths, spots, points, glass, penumbrae, the room, the court, Windows, the close | §14 |
| 17 | §15's items go to M41, M48, M73, M79, M81, M82 and M99; Step 10 writes each into its roadmap row | §15 |

Once these are accepted nothing blocks Step 1: it is one RHI command on three backends, on the
code as it is.

## Resolution — Step 1: depth bias per pass command (2026-11-14)

The design was accepted when the owner asked for Step 1. Its status line, ADR-0080, ADR-0081 and
`CLAUDE.md` §4.1's two new rows record that.

**What the step pinned:**
- `RenderPass.setDepthBias(DepthBias)` is in the interface every backend must satisfy. It replaces
  the bound pipeline's bias for the draws after it, until the next `setPipeline`, which restores
  that pipeline's own, even when the same pipeline is bound again.
- **Only a pipeline built with bias enabled may have it changed.** `DepthBias.enabled()` (any
  non-zero member) and `DepthBias.isFinite()` are new. §3 did not say this, and it is the
  contract's sharpest edge: Vulkan ignores a dynamic bias on a pipeline whose
  `depthBiasEnable` is false, while Metal would apply it. The contract follows Vulkan, and the
  null backend enforces it, so no caller can write code that works on Metal and not on the Arc.
- **Null** records the bias on the pass. It refuses a call after the pass ended
  (`encoder_discipline`), a non-finite value (`limits`), a call with no pipeline bound
  (`incomplete_bindings`) and a call on a pipeline built without bias (`usage`). A refused call
  changes nothing. A null pipeline now keeps its bias, and `setPipeline` copies it to the pass.
- **Metal** calls the encoder's `setDepthBias` that `setPipeline` already used.
- **Vulkan:** a biased pipeline also declares `VK_DYNAMIC_STATE_DEPTH_BIAS` and keeps its bias.
  Binding it records `vkCmdSetDepthBias` with that bias, since dynamic state must be set before
  a draw. A pipeline without bias declares only viewport and scissor, as before.
  `vkCmdSetDepthBias` joins the dispatch table.
- `render3d` calls nothing new yet: its shadow pipelines are biased (−1, −1), so Step 3 can use
  the command without changing them.

**A Metal test proves the command.** Three 8-texel tiles of one depth texture are drawn at
depth 0.5 by a pipeline whose own bias is one unit. The middle tile sets −2^17 units, which is
2^−7 at that depth. The third binds the same pipeline again. A comparison at 0.496 passes in the
middle tile only.

**A weak M22 test found and repaired.** `DepthAttachment.store` defaults to `.discard`.
- The first version of the new test omitted `.store = .store`, as M22's "a depth-only pass is
  sampled through a comparison sampler" does. Every comparison passed, at references of 0.25,
  0.75 and 0.496 alike, because the sampled attachment had been discarded.
- So M22's test had never proved its comparison. It now stores its depth and expects what
  reversed-Z gives: a reference of 0.4 lies behind the stored 0.5, so it fails everywhere.
- The comparison's sense is confirmed: `greater_equal` passes where the reference is at or
  nearer than the stored depth, as `render3d`'s shadows assume.
- The null backend does not flag sampling an attachment whose contents a pass discarded. Making
  it do so is a validation rule outside this step; it is recorded here and left alone.

**Vulkan** compiles for Windows and Linux, and the five Vulkan checks pass. No Vulkan readback
was added: the backend's sprite pipeline writes depth 0, where a constant bias's size is not
portable. Step 9 runs the Vulkan suites under required validation, whose shadow readbacks bind
biased pipelines. Without the bind's `vkCmdSetDepthBias`, validation would refuse those draws,
and from Step 3 they use the command per tile.

**Each guard was broken once, and each failed its test:**
- `setPipeline` not restoring the pipeline's bias failed the null test;
- the null refusal of an unbiased pipeline removed failed the null test;
- Metal's `setDepthBias` made a no-op failed the Metal readback.

**Step 10's list gains `rhi.md`,** whose command list gains `setDepthBias` and its contract.

**Bar:** every line of `AGENTS.md` §3 passes:
- null 2,999/3,009 (ten skips) and Metal 3,010/3,031 (21 skips), one and two more than M39 for
  the new tests;
- every check, the four thirty-frame samples, `fdt-check`, the tour with every pin held
  (`1052a9ae891b0d27`), `court-test` 87/89, and the five Vulkan checks.
`zig fmt` failed once, on the Metal file as restored after the mutations, and passed once it was
formatted. Only whitespace changed, and the Metal build was checked again.

## Resolution — Step 2: the allocator, priority, sizes and matrices, as maths (2026-11-14)

**What the step pinned:**
- **`render3d/shadow_atlas.zig`,** pure and its own oracle:
  - `Atlas` is a row of 1 to 4 pages, each one quadtree of up to seven levels, from 8,192 down
    to 128. Its node states are fixed arrays, about 21 KB, with no allocation.
  - `allocate` walks as §4 says. It first looks for a free square of the size asked under
    squares already split. Only then does it split the smallest free larger square, down
    through first quadrants.
  - `allocateGroup` takes all of a group's tiles at one side, or restores the nodes and takes
    none.
  - `requestFor`, `order` and `place` are §5: unseen lights skipped, nearest sphere first with
    ties by submission, sides from coverage, halving down to the minimum, dropping counted.
    `max_tiles = 32` is enforced by `place`.
- **`lighting.zig`:**
  - `Light.source_radius`, validated (§10);
  - `widenedTangent`, `localProjection` (reversed-Z, `Camera.projectionMatrix`'s form) and
    `lookAlong`;
  - `spotMatrix`, `faceMatrix` over `face_axes`, `chooseFace` and `localFar`;
  - `shadow_clamp_inset = 2` as a named constant.
- **`Config`** gains §11's fields, refused out of range as `InvalidConfig` (`validShadows`
  replaces `validCascades`).
- **The renderer** makes its atlas `pages × 2s` by `2s` and places the cascades through the
  allocator each frame, keeping the grants in `shadow_tiles`. Nothing local is granted or
  drawn, and `addLight` still refuses a casting point or spot.

**Where implementation sharpened the design:**
- **Coverage.** §5 said "as M20's bounds projection computes it", but M20 has no projection of
  bounds, only frustum exclusion. Coverage is the sphere's angular radius, `r / √(d² − r²)`,
  over the camera's half-field tangent, times the target's height, capped at its larger side.
  A sphere holding the camera, or an unbounded light, covers the whole target.
- **Seen.** A light is unseen when the cube around its range sphere is excluded by the camera's
  frustum: conservative, so a seen light may still light nothing on screen.
- **A light whose range is no farther than `shadow_local_near` casts nothing,** and is counted
  as unseen, because its tile would have no depth range. §5 did not say.
- **A spot's up axis** is the light's +Y made orthogonal to its axis. When the two are
  parallel, it falls back to world +Y, or +X when the axis is vertical, as `fitShadowSlice`
  does.
- **A host with one cascade now pays for a page,** `2s × 2s`: four times M22's single map, where
  M39 sized its atlas `s × s` at one cascade. The picture is unchanged, since every tile's
  texels are where they were. §4's table already showed one page as the minimum, and §16 row 3
  accepted it; this records the cost for a one-cascade host. A device whose limit is 4,096 now
  refuses the default (8,192 wide) and must set one page.
- **The widening's footprint** is `shadow_penumbra_max` (12 texels by default), which also
  covers M39's 1.5-texel filter, so `max(1.5, penumbra_max)` is just `penumbra_max`.

**Every M39 readback holds through the paged atlas,** on Metal: the cascades land on M39's texel
rectangles, and only their UV rectangles narrow with the atlas's width. The uniform test now
expects a 4,096 × 2,048 atlas at `s = 1024`.

**Tests:**
- the allocator: M39's tiles for one to four cascades; a pinned mixed walk run twice; a refusal
  that changes nothing; a group all or none; a thousand seeded lists with no overlap, every tile
  inside the atlas and aligned to its side;
- priority and size: six lights, one unseen, one holding the camera, one unbounded and a tie,
  ordered and sized; a near-plane range refused; the spot's face count at π/3; `sideFor`'s
  powers;
- placement: halving twice to fit six faces, a 256 granted where it fits, a drop when two
  128s remain, and the 32-tile limit dropping a fifth point after four cascades and four points;
- matrices: a spot's cone edge meets the inset in four directions at three distances, its depth
  runs 1 to 0, and its up is the light's +Y; each face's corners meet the inset's corner, its up
  is clip +y, and a thousand seeded directions each land inside their chosen face's inset;
  `chooseFace`'s ties;
- `source_radius`'s refusals, and every new `Config` field's.

**Each guard was broken once, and each failed its tests:**
- the allocator granting a node without checking it is free failed eight tests, the overlap
  sweep among them;
- swapping +X and −X in `chooseFace` failed the face-choice and coverage tests;
- removing the widening failed the spot and face tests.

**Bar:** every line of `AGENTS.md` §3 passes:
- null 3,012/3,022 (ten skips) and Metal 3,023/3,044 (21 skips);
- every check, the four thirty-frame samples, `fdt-check`, the tour with every pin held
  (`1052a9ae891b0d27`), `court-test` 87/89, and the five Vulkan checks.

## Resolution — Step 3: the third uniform and spot shadows (2026-11-14)

**What the step pinned:**
- **`FrameUniform`'s third layout,** 4,256 bytes, in Zig and in all ten shader files that
  declare `Frame`: three Metal (`lit`, `unlit`, `particle`) and seven GLSL. The SPIR-V agreement check
  in `rhi/backends/vulkan/spirv.zig` pins the new offsets, which §13 had not listed. The offsets
  are 144 for the parameters, 160 for the tiles, 672 for their parameters, 1,184 for the
  matrices and 3,232 for the lights.
- **`packLight` leaves `cone_shadow.z` and `w` zero.** The renderer writes them once it has
  placed the frame's tiles, so a light that asked to cast and got no tile casts nothing.
- **One lookup, `tileVisibility`, serves cascades and spots.** A tile's parameter y says
  whether to divide by w, and its normal offset is scaled by `axial`: 1 for a cascade, or the
  receiver's depth along the spot's axis. The directional branch reads the cascade from the
  light's first tile, as M39 did from 0. The spot branch tests the light's kind as well as its
  one tile, so a one-cascade sun past its last split is never read as a spot.
- **`addLight`** accepts casting spots to π/3. It still refuses point lights and wider spots,
  which are Step 4's, and a second casting directional light. Only a directional caster sets
  `has_shadow_caster`.
- **Preparation** is now `placeShadowTiles`: the cascades first (M39's fit, on M39's tiles),
  then each seen casting spot through §5's order and placement. Every caster is culled against
  every tile into `DrawItem.shadow_tiles: u32`, which replaces M39's `u4`.
- **`recordShadow`** draws every tile. A local tile issues `setDepthBias` after each
  `setPipeline`, since binding a pipeline restores the cascades' bias.
- **`Stats`** gains `shadow_tiles`, `shadow_local_lights`, `shadow_lights_unseen`,
  `shadow_lights_dropped`, `shadow_local_draws` and `shadow_translucent_draws` (0 until Step 5).
  The overlay's second line reads
  `3D: 2 local lights  13 tiles  210 local draws  4 translucent  0 dropped`.
- **`FrameView.local_shadows`** and **`Renderer.shadowTiles()`** (light, kind, index, tile).

**Where implementation sharpened the design:**
- **`DepthBias.dynamic`.** Step 1's contract let only a pipeline built with non-zero bias take
  a per-pass bias. A host may set the cascades' bias to zero while the local bias is not, so
  shadow pipelines are now built with `dynamic = true`. That enables bias even at zero, and
  `enabled()` includes it. Vulkan enables bias for such a pipeline, and Metal and null need
  nothing else.
- **A short request list.** `order` overflowed on an empty list (`1..0`), which every frame
  without a casting local light hit. It now returns for fewer than two requests, and a test
  calls it on zero and one.
- **The local bias defaults stay M22's (−1, −1, 0).** The spot readback holds at ±2/255 with
  them, lit and shadowed, so the readbacks gave no reason to move them.

**A weakened M39 test found and repaired.** "A filter at its tile's edge never reads the
neighbouring cascade's depth" aims its lookup at a fixed atlas UV, `0.5 − 1/2048`. Step 2's
paged atlas is twice as wide, so that point lay outside tile 0, and the test would have passed
whatever the clamp did. It now asserts the atlas's size and aims at `0.25 − 1/4096`, one texel
inside tile 0's new right edge. Removing the clamp fails it again.

**Tests:**
- **Null:** a sun and two casting spots, one unseen. The seen spot takes tile 4, the smallest
  side on page 1. The uniform points it at tile 4 with its folded perspective matrix and its
  per-metre offset, the unseen spot points nowhere, and the casters are culled per tile. A
  second test covers four cascades filling a one-page atlas so the spot is dropped and counted,
  and a spot alone with local shadows on and off.
- **Metal:** a spot's cube shadows a wall to the oracle's ambient, lights the wall beside the
  shadow to the oracle's lit value, and leaves a point outside its cone unlit. The same scene
  with a local bias of −10⁹ casts nothing, because only the per-tile command can push those
  casters to the far plane while the cascades keep theirs.

**Each guard was broken once, and each failed its test:**
- dropping the spot's perspective divide in `lit.metal` failed the spot readback;
- not issuing `setDepthBias` for a local tile failed the spot readback's large-bias case;
- removing the tile clamp failed the re-aimed no-bleed test.

**Bar:** every line of `AGENTS.md` §3 passes:
- null 3,015/3,025 (ten skips) and Metal 3,026/3,047 (21 skips);
- every check, the four thirty-frame samples, `fdt-check`, the tour with every pin held
  (`1052a9ae891b0d27`), `court-test` 87/89, and the five Vulkan checks, whose SPIR-V agreement
  check now pins the third layout.

## Resolution — Step 4: point shadows (2026-11-14)

**What the step pinned:**
- **`addLight`** accepts any casting spot or point light. Only a second casting directional
  light is still `InvalidShadowCaster`.
- **`placeShadowTiles`** gives a request with six faces six consecutive tiles in face order
  (+X, −X, +Y, −Y, +Z, −Z), each `lighting.faceMatrix` from the light's position. A point light
  and a spot wider than π/3 take the same path, so a wide spot's cone only limits its light,
  not its tiles. Each tile is `ShadowTile.kind = .face` with its face as `index`. The light's
  `cone_shadow.w` is 6.
- **All six faces share one side and one normal offset,** the texel at one metre of the face's
  axis, `shadow_normal_offset · 2·widenedTangent(1, side, penumbra_max) / side`.
- **The lit shaders** (`lit.metal`, `lit.frag.glsl`) read a light with one tile as a spot and
  any other local light as six faces. For faces:
  - `axial` is the largest absolute component of the light-to-receiver vector, which is the
    distance along whichever face is read;
  - the receiver is offset along its normal by the first tile's offset times `axial`;
  - the face is chosen from the offset vector by `lighting.chooseFace`'s rule, ties in face
    order and zero counting as positive;
  - that face's tile is read by Step 3's `tileVisibility`.

**Where implementation sharpened the design:**
- **Which vector chooses the face.** §7 chooses from "the receiver's offset position", but the
  offset is scaled by distance along the face, which depends on the face. The scale is taken
  from the largest component of the unoffset vector, which is the same for every face a
  receiver near a seam could read. The face is then chosen from the offset position, as §7
  says, so the shader needs no second pass.
- **A face test that turns the scene, not the light.** §13 asked for a cube with a crate on
  each side of a point light. The camera of a 32-pixel readback sees one wall, so the readback
  turns the whole scene, camera included, about the camera six times, once per face axis. The
  light-to-wall axis is each face's in turn, only that face's tile holds the caster, and the
  oracle is unchanged by the turn.

**Tests:**
- **Null:** a point light whose sphere holds the camera, and a spot at 1.2 rad farther off.
  - They take tiles 0–5 and 6–11, nearest first, all 256, none overlapping.
  - The uniform points them at `(1, 6)` and `(7, 6)`, with each face's folded matrix and offset.
  - A crate on the point light's +X axis is drawn into +X alone, and one on the +X/+Y diagonal
    into those two faces.
  - The local draws are the sum of the face bits, and there are no violations.
- **Metal, every face:** turned to each face axis in turn, a point light's cube shadows the
  wall to the oracle's ambient and lights the wall beside it to the oracle. The caster is in
  that face's tile alone, and `chooseFace` agrees.
- **Metal, a seam:** a thin bar's shadow runs across the −Z/+X seam at pixel column 23.
  `chooseFace` puts column 22 on −Z and column 23 on +X. Every pixel of the band, columns 17 to
  29, reads the oracle's ambient, and every pixel above and below it reads lit.
- **The refusal test** now accepts casting points and wide spots and still refuses a second
  casting sun.

**Each guard was broken once:**
- swapping +X and −X in `lit.metal`'s face choice failed the every-face and seam readbacks;
- placing the faces' matrices in reverse order failed the null placement test and both
  readbacks;
- removing a face's widening failed Step 2's coverage test, but no readback. At a 256 side the
  widening moves a seam by about fourteen texels, and the clamp keeps the taps on the caster's
  own depth, so the seam reads the same either way. Step 2's maths test is what guards it;
- leaving a face's normal offset unscaled (`axial = 1`) failed nothing. The readbacks' walls
  do not cast, so they have no acne for the offset to remove. Step 7's room, where every
  surface casts, is where the offset's scale shows, and Step 4 records that it is unproved
  until then.

**Bar:** every line of `AGENTS.md` §3 passes:
- null 3,018/3,028 (ten skips) and Metal 3,029/3,050 (21 skips);
- every check, the four thirty-frame samples, `fdt-check`, the tour with every pin held
  (`1052a9ae891b0d27`), `court-test` 87/89, and the five Vulkan checks, which compile the
  GLSL face choice.

## Resolution — Step 5: translucent shadows (2026-11-14)

**What the step pinned:**
- **The colour atlas** is `rgba16_float`, the depth atlas's size. It is made by
  `ensureTranslucentResources` the first frame that draws a translucent caster, and then kept.
  Each slot's world group is rebuilt to read it, and the replaced groups are retired by the
  device. A 1×1 fallback, cleared to white with alpha 0 at `init` beside M22's empty depth
  map, fills binding 3 everywhere else. Binding 4 is a nearest sampler.
- **The frame layout** gains binding 3 (sampled texture) and binding 4 (sampler). Every frame
  group carries them, so the layout stays one.
- **Culling:** a blend material that casts gets a tile mask like any caster, and joins
  `translucent_order`, never `shadow_order`. With `shadow_translucent` off it gets neither,
  as before M40. Translucent casters also widen the cascades' depth range, as opaque casters
  do, so off-camera glass reaches its receivers. They are kept for skinning and budget
  drops as shadow casters are.
- **The passes:**
  - when a frame has translucent casters, the depth pass ends in `depth_stencil`;
  - the translucent pass then clears the colour atlas to `(1, 1, 1, 0)` and loads the depth
    atlas, testing `greater_equal` with no write and no bias, and leaves both in `shader_read`;
  - `recordTranslucent` draws each caster into each tile its mask names, binding the
    fallback caster group, so nothing samples what it draws;
  - each draw adds one to `Stats.shadow_translucent_draws`, and none counts in `shadow_draws`.
- **The pipeline:** a shadow key with `alpha = blend` uses the new fragment stage
  `fragmentTranslucent`, or `shadow_fragment_2` with `-DTRANSLUCENT`. It writes
  `mix(1, base.rgb, base.a)` and the fragment's depth to one `rgba16_float` target, with
  `translucent_blend`: colour zero/`src_color`/add, alpha one/one/`max`. A masked or blended
  caster's shadow key now reads the uv and colour streams, since the filter needs both.
- **The lookup:** `tileVisibility` became `tileShadow`, returning the transmittance in rgb
  and the visibility in w (−1 outside the tile, with white). With `counts.w` set, each of the
  nine taps reads the colour atlas at its own clamped coordinate. It takes the colour when
  `q.z < a·(1 − bias)`, and white otherwise. The light is multiplied by the average after the
  opaque visibility; cascades blend both across a band.
- **`counts.w`** is 1 only in a frame that drew the translucent pass. **`tile_params.w`** is
  `lighting.translucent_bias = 1/512` for every tile.

**Where implementation sharpened the design:**
- **The translucent bias is relative, the same for every tile.** §9 left it per tile, without
  a value. Half precision keeps depth to about 2⁻¹¹ of itself wherever it lies, and
  reversed-Z perspective depth falls with distance. A bias relative to the stored depth
  therefore means the same fraction of distance for every kind of tile: `1/512` is four
  half-precision steps. It stays in the uniform's per-tile slot, so a later step may vary it.
- **Metal's texture and sampler indices move.** The Metal backend numbers each kind in layout
  order, group by group, so group 0's two new entries become texture 1 and sampler 1. Every
  material texture and sampler in `lit.metal`, `unlit.metal`, `particle.metal` and
  `shadow.metal` moves up by one. Vulkan names set and binding, so nothing moved there.
- **`shadow_culled` counts translucent casters' culls too,** since they are culled per tile
  the same way. M39's per-cascade test now expects that.
- **The pane's own shadow.** Its lit fragment's normal offset already lifts it off the
  stored depth, so the bias is a margin, not what keeps the pane from tinting itself. Removing
  the bias fails no test (below).

**Tests:**
- **Null and Metal, the switch and first need:**
  - an opaque frame makes no colour atlas, and sets `counts.w` to 0;
  - a frame with glass makes one, the atlas's size, sets `counts.w` to 1, and draws the
    glass once per cascade its mask names, never as a depth caster;
  - a later opaque frame keeps the atlas and clears `counts.w`;
  - with `shadow_translucent` off, nothing is made or drawn;
  - there are no violations.
- **Metal, glass:** a spot shines through a blue pane (`(0.2, 0.4, 1)`, alpha 0.6). Behind
  it, the wall reads the oracle's light times the filter `(0.52, 0.64, 1)`, plainly not the
  untinted light. A receiver between the light and the pane reads untinted. The pane's own
  pixel is the same with its shadow on and off. With the switch off, the wall behind the pane
  reads untinted.
- M39's two caster-selection tests now find the blend material in `translucent_order` and
  still never in `shadow_order`.

**Each guard was broken once:**
- inverting the translucent depth comparison failed the glass readback;
- writing `base.rgb` in place of the filter colour failed it;
- keeping alpha by `min` in place of `max` failed it, since the clear's 0 then wins;
- ignoring `shadow_translucent` in culling failed the switch test and the glass readback;
- removing the bias failed nothing, for the reason above. In this readback the normal offset
  is what keeps the pane untinted by itself, and no test isolates the bias. A receiver whose
  offset is small, such as one seen edge-on to the light, is where it would show; Step 7's
  room is the first scene with one.

**A GLSL reserved word.** The first bar's Vulkan cross-checks refused `lit.frag.glsl`, because
`filter` is reserved in GLSL. The variable is now `tint` in both shaders. The five Vulkan
checks had passed regardless: they validate the RHI's own stages, not render3d's, which only
`zig build check -Drhi=vulkan` compiles.

**Bar:** every line of `AGENTS.md` §3 passes:
- null 3,020/3,030 (ten skips) and Metal 3,031/3,052 (21 skips);
- every check, the four thirty-frame samples, `fdt-check`, the tour with every pin held
  (`1052a9ae891b0d27`), `court-test` 87/89, and the five Vulkan checks, whose SPIR-V agreement
  check now pins the lit fragment's bindings 3 and 4 and the translucent caster's output.

## Resolution — Step 6: contact-hardening penumbrae (2026-11-14)

**What the step pinned:**
- **`lighting.zig`:**
  - `penumbra_min = 1.5`, M39's filter's half width;
  - `penumbra_disc`, the sixteen Vogel points written out to six places;
  - `perspectivePenumbraScale` and `orthographicPenumbraScale`, a tile's penumbra scale;
  - `penumbraWidth` and `blockerSearchWidth`, which the lit shaders mirror.
- **The renderer** writes each tile's scale into `shadow_tile_parameters.z`:
  - a cascade's from the sun's angular radius, its fitted depth range and its texel;
  - a spot's or a face's from the lamp's radius, its widened tangent, its side and its near
    and far planes.
  It writes `Config.shadow_penumbra_max` into `ambient.w`, the uniform's one free lane, in every
  frame with shadow tiles. A light of radius 0 has scale 0.
- **The lit shaders' `tileShadow`** (`lit.metal`, `lit.frag.glsl`) take §10's path when the
  tile's scale is not zero. Otherwise they run M39's nine taps, unchanged.
  - Sixteen point reads of the depth atlas on the disc, at the search radius, use binding 4's
    nearest sampler. That sampler is Step 5's, so no binding was added. A read is a blocker when
    its depth is nearer the light than the receiver's.
  - With no blocker the point is lit and stops there. In a frame that drew translucent casters
    it still filters the tint, at 1.5 texels.
  - The blockers' mean depth gives the half width. Sixteen comparison taps on the same disc at
    that width give the visibility, and each tap reads the tint as Step 5's taps do.
  - Every read is clamped inside its tile by Step 3's inset.

**Where implementation sharpened the design:**
- **One formula for both kinds of tile.** §10 gives the width in linear depth: for a
  perspective tile `(d_r − d_b)·radius/d_b` metres, and for a cascade the gap times the sun's
  tangent, both converted to texels. Reversed-Z perspective depth is `A/d − near/(far − near)`,
  with `A = near·far/(far − near)`, so `1/d_b − 1/d_r` is `(z_b − z_r)/A`. The perspective width
  in the receiver's texels is therefore `(z_b − z_r)` times the scale
  `radius·side/(2·tangent·A)`. A cascade's depth is linear, so its width is `(z_b − z_r)` times
  `depth_range·tan(angle)/texel`. Each shader then needs one multiply, with no reconstruction
  of linear depth, and the result is §10's formula exactly, not an approximation of it.
- **The search radius** is "the light's size projected through the receiver into the tile".
  That is the penumbra a blocker at the tile's near end (depth 1) would cast,
  `(1 − z_r)·scale`, clamped from 1.5 texels to the limit. A cascade has no near plane, so
  its near end is its depth range's end toward the sun.
- **The widest penumbra lives in `ambient.w`.** §8's table left no lane for it. `ambient.w`
  was zero and read by no shader. It is a frame value, not a tile's, so it does not take one
  of the tile's four parameters.
- **The readback is a plate, not a post.** §13 asked for a vertical post whose shadow widens
  from its foot. The test asks the same question of one straight edge at several gaps, which
  the CPU can filter exactly:
  - a spot of radius 0.9 m, 6 m from a wall, throws a plate's edge onto it;
  - the plate stands 0.2, 1.5 and 3 m before the wall;
  - a fourth frame repeats the widest gap at radius 0.
  The atlas then holds one depth on one side of a known column, so `edgeVisibility` rebuilds
  each frame's blocker search, width and bilinear taps from the light's own matrix and checks
  every pixel of a row against it.
  The camera stands to one side, so it sees the wall past the plate's edge. Pixels where it
  sees the plate are skipped.
- **The disc test is in f64.** The last Vogel point is turned about 36 radians, where f32's
  trig loses the sixth place.

**Tests:**
- **No GPU:**
  - the disc is the Vogel formula, and both lit shaders' source text holds the same sixteen
    points;
  - a perspective width equals `(d_r − d_b)·radius/d_b` over the receiver's texel at three
    depths, and is clamped to 1.5 at contact and to the limit;
  - a cascade's width is the gap times the sun's tangent over its texel;
  - the search radius is the near plane's penumbra;
  - a sun, a spot and a point light, each with a size, carry their scales in all nine tiles,
    with zero for every tile at radius 0, and `ambient.w` holds the configured limit.
- **Metal, the penumbra:**
  - every pixel of the row matches the oracle at ±2/255 in all four frames;
  - the oracle's half width at contact is exactly 1.5 texels;
  - the measured transition widens with the gap. Counting pixels that read neither their own
    unlit nor their own lit value, it is 0, 4 and 11 pixels at 0.2, 1.5 and 3 m, and 1 pixel at
    radius 0, M39's filter. At contact the penumbra, about 0.09 m, is narrower than one camera
    pixel, 0.125 m on the wall.
- Every earlier readback holds unchanged, since all of them light at radius 0.

**Each guard was broken once:**
- inverting the width's distance ratio (16 over the gap times the scale) failed the penumbra
  readback;
- dropping the radius-0 branch, so a zero scale runs the disc at 1.5 texels, failed the
  penumbra readback's radius-0 frame. No earlier readback failed: the 1.5-texel disc and
  M39's nine taps agree within ±2/255 on their scenes, so the radius-0 frame is what holds
  the branch;
- taking the search radius as the width, ignoring the blockers' depth, failed the penumbra
  readback;
- not writing a tile's scale into the uniform failed the scale test and the penumbra readback.

**Bar:** every line of `AGENTS.md` §3 passes:
- null 3,024/3,034 (ten skips) and Metal 3,035/3,056 (21 skips);
- every check, the four thirty-frame samples, `fdt-check`, the tour with every pin held
  (`1052a9ae891b0d27`), `court-test` 87/89, and the five Vulkan checks, which compile the GLSL
  penumbra.

## Resolution — Step 7: the room, every light casting, on Metal (2026-11-15)

**What the step pinned:**
- **`sandbox3d:config.main`:**
  - its two point lights set `casts_shadow true` and `source_radius 0.05`;
  - the sun gets `source_radius 0.0047`;
  - a spot joins them over the glass pane: at (0, 1.8, 2.4), aimed through the pane's upper
    half at the floor beyond it, outer cone 0.5236 rad (60° across), inner 0.35, 150 cd,
    range 8, radius 0.05.
  The schema's light entry gains `source_radius f32 (default 0)`.
- **The dusk mod** restates the whole config, so its lamps now cast too, at radius 0.08, and
  it adds an orange spot of its own in the same place. That change is content only. It
  compiles with `fpack` against the base package. `docs/modding/content-mods.md` says so.
- **`light_settings.zig`** reads `source_radius` and lets every spot and point light cast. It
  still refuses a second casting directional light, and `lighting.valid` refuses a radius out
  of range.
- **The flags.** `--local-shadows=off` sets `FrameView.local_shadows` false.
  `--penumbra=off` submits every light with radius 0. Anything else near them is the usage
  error, and the options test pins both. **J** toggles local shadows, logging `j: local
  shadows on|off`, and `j@frame` joins the scripted keys.
- **The exit report** logs each granted local tile (light, kind, face, side, origin) and a line
  of local counts: lights, tiles, local draws, translucent draws, unseen, dropped. The
  overlay's second profiler line is Step 3's, read from the same `Stats`.

**Where implementation sharpened the design:**
- **`--shadow-tint` had never reached the sample.** M39 parsed it into `Options`, but
  `Sample.init` did not copy it, so the run started untinted and only H tinted it. With the
  flag, the run now starts tinted, and the two new flags take the same path.
- **The test light without a colour.** The schema's nested `color` record must be present even
  though its fields have defaults. The test's lamps say so, as the content's do.
- **M39's refusal of a casting point light** in the lighting test now has to pass, so that case
  is gone. A list of the sun, two casting lamps and a casting spot reads as four lights, each
  lamp with its radius.

**The room, headless, at the default:** the three local lights take 17 tiles of 1,024:
- each lamp takes six faces on page 1;
- the spot takes one;
- none is unseen and none dropped.
Thirty frames draw 260 local and 8 translucent shadow draws. With `--local-shadows=off` the
frame draws M39's 459 shadow draws exactly, with 4 translucent draws into the cascades.
`--penumbra=off` draws the same counts as the default.

**The tour,** 2,400 frames, held every pin with local shadows on (the bar's run) and off:
- the player `b85b52c97d259db4`;
- the walker `655e865f98779129`;
- the pacer's three replays and M34's save;
- the corner `e2992f93e5323345`;
- the yard `1052a9ae891b0d27`.

**The budget, from a relocated, read-only ReleaseSafe install, windowed on the M5:**
- the install was made with `zig build install -Drhi=metal -Doptimize=ReleaseSafe` to a staging
  prefix, then moved and made read-only;
- each run was 900 frames of the orbiting room, with saves redirected to scratch;
- nothing under Application Support changed.

| Run | Shadow draws (local, translucent) | Frame work, median / p95 (max) | `render.world`, median / p95 | Skipped |
| --- | --- | --- | --- | --- |
| Every light casting | 840 (318, 8) | 3.727 / **4.103 ms** (40.013) | 2.095 / 2.276 ms | 0 |
| `--local-shadows=off` | 522 (0, 4) | 3.073 / 3.445 ms (4.073) | 1.449 / 1.523 ms | 0 |
| `--penumbra=off` | 840 (318, 8) | 2.952 / 4.233 ms (4.730) | 1.557 / 2.237 ms | 0 |

- **What local shadows cost:** about 0.65 ms of CPU a frame at the median, nearly all of it
  `render.world` recording 318 more caster draws.
- **What the penumbra costs:** the CPU difference between the first and third runs is within
  run-to-run noise. The penumbra is GPU work, and GPU timing of the shadow passes is M73's.
- **The exit holds:** the frame works for 4.1 ms of its 16.67 at p95.
- **One frame took 40 ms** in the casting run's last 240. Only that run had one, and no frame
  was skipped. This step does not explain it, and Step 9's Windows run measures the same scene
  again.

**What this step leaves to the owner's eye.** Step 4's loose end, a point light's face offset
scaled by distance, is the kind of fault that shows as acne in this room, where every surface
casts. This step's runs measure counts and time and capture no image, so the room's look is
first seen when the owner plays at Step 8 or watches Step 9's Windows run.

**Each guard was broken once:**
- a parser taking anything starting with `--local-shadows` failed the options test;
- removing the second-sun refusal failed the lighting test;
- leaving `source_radius` unread failed the lighting test.

**Bar:** every line of `AGENTS.md` §3 passes:
- null 3,024/3,034 (ten skips) and Metal 3,035/3,056 (21 skips), the sample's own tests among
  them (`sandbox3d-test` 75/76, one skip);
- every check, the four thirty-frame samples, `fdt-check`, the tour with every pin held
  (`1052a9ae891b0d27`), `court-test` 87/89, and the five Vulkan checks.

## Resolution — Step 8: the court (2026-11-15)

**What the step pinned:**
- **The beacon record's light gains `casts_shadow bool (default true)`.** It sits beside the
  light's colour, intensity, range and height, as `light.casts_shadow`. §12 named it
  `light_casts_shadow`, which is the Zig field's name in `BeaconSettings`, where the light's
  other values are flattened as `light_color` and the rest. The three beacons rely on the
  default.
- **`BeaconSettings.read`** refuses a record without the flag, as it refuses any other missing
  field. The schema defaults it, so only a record the compiler did not write lacks it. The
  presence test therefore covers it with the others.
- **`main.zig`** submits each lit beacon's point light with the flag. No rule, tick or
  simulation changed.
- **The exit report** logs, over the run, the most beacon lights casting in one frame, their
  tiles, their local draws and drops. A frame's stats show only that frame, and the court's
  last frame is usually a menu.

**The digests hold.** `court-test` passed 87 of 89 in Debug (two skips) and 89 of 89 at
ReleaseSafe, where the ten-minute soundtrack runs. The four digests are M39's: `win`
`4cea12a2d26686ba`, `caught` `448a83a95a46f1af`, `fell` `489ec244f5946487` and `soundtrack`
`38ee55e6ad5b65da`.

**Frame pacing is unchanged.** Two relocated, read-only ReleaseSafe installs were built on the
Mac:
- **M40:** this tree;
- **Baseline:** the same tree with the schema's default set to `false`, so no beacon casts.

Each scripted play ran windowed from both, with preferences redirected to scratch:

| Play | Ending, both installs | Ticks matched | Beacons casting (tiles) | Frame work p95, baseline → M40 | Whole tick p95, baseline → M40 |
| --- | --- | --- | --- | --- | --- |
| `win` | won at 1219 and 2436 | 2,443 | 3 (18 faces beside 4 cascades) | 1.330 → 1.350 ms | 0.254 → 0.246 ms |
| `caught` | caught at 90 | 92 | 0 | 2.388 → 3.494 ms | 0.195 → 0.220 ms |
| `fell` | fell at 186 | 188 | 0 | 1.280 → 1.322 ms | 0.190 → 0.248 ms |

- **Only `win` lights beacons,** so it is the comparison that measures their shadows: 20 µs at
  p95.
- **`caught` and `fell` draw the same frames in both installs.** Their differences are the
  noise of 90 and 186 frames, the warden's first frames among them.
- **No frame was skipped.** The court's files under Application Support were fingerprinted
  before and after, and were unchanged.

**The first baseline `win` failed its music check,** with 41 underruns. It was the first launch
of the first install, and it casts nothing. Rerun, it had no underrun, with 15 of 17 starts on
their frame and two pending at the quit, as M40's run had. The table uses the rerun.

**The owner's play.** The owner played the M40 install by hand:
- won at tick 1701, all three beacons lit and casting into 22 tiles, with nothing dropped;
- frame work p95 2.515 ms over 1,906 frames;
- whole tick p95 0.220 ms;
- the warden's skinning p95 0.108 ms;
- audio p95 0.032 ms;
- all 11 music starts on their frame, no underrun, and no frame skipped.

**Their verdict: "All good."** This is the first time anyone has looked at local shadows in a
real scene. The face offset that Step 4 left unproved showed no acne the owner remarked on.

**Guard broken on purpose:** a reader that ignores the content's flag and always casts failed
the court's refusal test, which turns the flag off.

**Bar:** every line of `AGENTS.md` §3 passes:
- null 3,024/3,034 (ten skips) and Metal 3,035/3,056 (21 skips);
- every check, the four thirty-frame samples, `fdt-check`, the tour with every pin held
  (`1052a9ae891b0d27`), `court-test` 87/89, and the five Vulkan checks;
- the court's content changed, so `zig build dist -Dapp=court` staged it on macOS, ReleaseSafe
  on Metal, exit 0.

## Resolution — Step 9: Windows/Vulkan (2026-11-15)

**Where it ran:**
- the owner's PC (Arc A750, i3-10105F), from a fresh clone of `origin/main` plus a bundle of
  the unpushed commits, checked out at `d5cae5f`;
- `-j2`, below-normal priority, windowed runs from a scheduled task in the desktop session.

**The PC was not idle.** The owner was running EU5 in its automatic observe mode, at about 80%
CPU, and lifted the 50% cutoff for this run ("ignore usage"). So every timing below was taken
beside a running game. They are upper bounds for this machine, not readings of an idle i3.
`scripts/m40/` gained two things for this:
- the launcher passes `-IgnoreCpuLimit` through to the desktop half, as the build half already
  took it;
- the ReleaseSafe pins and the install get 120 minutes instead of 40. At `-j2` beside the game,
  the pins took 22 minutes once a first attempt had hit the old deadline. That attempt ran no
  test to completion, so it left nothing to compare.

**The suites:**
- null: 3,003 of 3,022 passed (19 skips);
- Vulkan, the readbacks at ±3/255 with validation and synchronization on: 3,285 of 3,315 passed
  (30 skips), every local, point, translucent and penumbra readback among them;
- the pins at ReleaseSafe on x86_64 (physics3d, nav, anim, rigs, scene, sandbox3d, the yard and
  the court): 767 of 767;
- the install: 177 of 177 steps.

**The bytes.** The relocated, read-only install's 210 content files equal the Mac's
ReleaseSafe install byte for byte. The one expected difference is the orbiter's native library,
`orbiter.dll` against `liborbiter.dylib`. The install's hash was the same after every run.

**The runs, all 18 passing, the validated ones clean:**
- **The tour.** Five runs (plain, validated, local shadows off, tilted, repeated) held every
  pin: walker `655e865f98779129`, player `b85b52c97d259db4`, yard replay `1052a9ae891b0d27`.
- **The room.** 900 frames, with the cascades exactly as on the Mac. Casting, it had Step 7's
  17 tiles (light 1 face 0, light 2 face 5, light 3's spot, each 1,024 texels), 320–327 local
  draws, 8 translucent and nothing dropped. Off, it had 4 tiles and 0 local draws.
- **The court.** Its three endings each ran validated and plain, and `win` ran twice. Every
  replay matched a fresh simulation. `win` peaked at three beacons casting into 22 tiles, 78
  local draws, nothing dropped, as on the Mac.

| Room, last 240 frames | Frame work median / p95 | `render.world` median / p95 |
| --- | --- | --- |
| every light casting | 2.85 / 7.62 ms | 0.92 / 3.37 ms |
| every light casting, again | 3.34 / 7.87 ms | 1.00 / 3.38 ms |
| penumbrae off | 2.76 / 6.47 ms | 0.89 / 2.45 ms |
| local shadows off | 1.86 / 3.64 ms | 0.54 / 1.00 ms |
| local shadows off, again | 2.63 / 6.97 ms | 0.70 / 2.02 ms |

**The exit holds.** With every light casting, the room's frame work p95 is 7.62 and 7.87 ms
against 16.67, beside a running game. The validated run, 35 ms, measures the layers and is not
a budget.

**What the numbers do not settle:**
- **The local shadows' cost.** At the median it is about 0.4 ms of `render.world`. The p95s
  move by a millisecond or more between identical runs, because the game took the CPU.
- **The court's whole-tick p95** was 0.35 and 0.30 ms in its two `win` runs, against M23's
  0.25 ms line. That line is a game-tick figure, the beacons' shadows are render work, and the
  validated run read 0.30 ms. It is the contention, not this milestone. An idle reading belongs
  with the paced spread M39 left to M73.

**No engine code changed** since Step 8, whose bar passed. This step adds only the PowerShell
under `scripts/m40/`, which no line of the bar builds or runs.

## Resolution — Step 10: Close M40 (2026-11-15)

Every document now names M40 complete:
- the status line here, ADR-0080 and ADR-0081, and their `CLAUDE.md` §4.1 rows;
- §4.3's `rhi` line (the per-pass depth bias) and `render3d` line (local tiles, the
  transmittance twin, penumbrae), and §9's row;
- the roadmap, the design index and the README, which now points to M41. The roadmap row and the
  index had still said "proposed" after Step 1 accepted the design; both now say complete.

**The contracts M40 changed, resolved by dated notes:**
- `light.md`:
  - §7.1: any light may cast, with one directional caster;
  - §9: the atlas is allocated in pages, bias is per pass, and the filter is a disc;
  - §14: its point/spot and translucent rows are struck through as done.
- `shadows-cascaded.md`:
  - §4's fixed table is now the allocator's first grants;
  - §13's M40 items are struck through. Per-cascade bias was not set, because no readback
    showed acne confined to one cascade.
- `3d.md` §4: the RHI needed no texture array or cubemap, only the bias command. §11's point
  and spot shadows are noted done.
- `render3d.md` gains the allocated atlas, the translucent pass, the 4,256-byte uniform and
  `shadowTiles()`.
- `debug-overlay.md` §7.5 gains the second profiler line.
- `public3d.md` notes that a retained light still never casts, and that mod lights that cast
  are M48's.

**ADR-0052 needs nothing.** Local shadows cost about 0.7 ms of `render.world` on the M5 with
three casting lights and 17 tiles. The room stays far inside its frame on both machines.

**§15's items go to their roadmap rows:**
- M48: mod lights that cast, and a light's source radius in the public table;
- M73: GPU timing of the shadow passes, now M40's as well as M39's;
- M79: particles casting as well as receiving;
- M82: the penumbra disc's per-pixel rotation;
- M99: tiles kept across frames, and a wide spot's unseen faces skipped.

M41 (cubemaps and texture arrays) and M81 (contact shadows) already said so.

**`AGENTS.md`** gains M40's runs and costs, and `scripts/m40`. **The PC's** clone
`src\Foundry-m40`, its scratch `m40` and the helper scripts were removed by exact name, and no
scheduled task is left.

**No bar was rerun.** Only documents changed after Step 8, so Step 8's bar stands:
- null 3,024/3,034 and Metal 3,035/3,056;
- the PC's Step 9 suites: null 3,003/3,022, Vulkan 3,285/3,315, pins 767/767.
