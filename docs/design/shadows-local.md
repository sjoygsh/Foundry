# Design: M40 — Shadows III: spot, point and translucent shadows in tiles of one allocated atlas

**Status:** Accepted 2026-11-14, when the owner asked for Step 1, with §16 as written. Each step's
Resolution follows §16.
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
