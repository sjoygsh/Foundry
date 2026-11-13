# Design: M39 — Shadows II: cascaded shadow maps for the directional light, in one atlas

**Status:** Accepted 2026-11-13, when the owner asked for Step 1, with §14 as written. Each
step's Resolution follows §14.
**Date:** 2026-11-13
**Baseline:** `d283098`, tag `m38`. M0–M38 are complete.
**Decisions:**
- ADR-0048 (reversed-Z, right-handed, −Z forward), ADR-0052 (a forward renderer, changed only
  on measurement), ADR-0056 (photometric light units) and `light.md` §9 (M22's single shadow
  map) are the contracts this milestone extends. ADR-0013 (deterministic-friendly) and ADR-0059
  (the public 3D table, frozen at v6) constrain it.
- [ADR-0079](../adr/0079-directional-shadows-are-cascades-in-one-atlas.md) (accepted 2026-11-13): the one
  directional caster's shadow is up to four cascades. Each is fitted and snapped as M22's single
  map was, and each is drawn into a tile of one depth atlas, not a layer of a texture array. A
  receiver picks its cascade by view depth and blends across a band at each seam. M40's spot and
  point shadows will take tiles of the same atlas.

`light.md` is M22's document. Its §14 set cascades aside with a trigger ("a scene whose single
map shows measured aliasing at `shadow_distance` a game needs"), and ADR-0060 scheduled them in
M39. `3d.md` §4 tied texture arrays to "shadow cascades that a scene proves it needs"; this design
does not need them (§4), so texture arrays stay M41's.

## 1. Purpose and boundary

The roadmap's row is the contract:

> **M39 — Shadows II.** Cascaded shadow maps.

**The runnable result.** `sandbox3d`'s yard (M38) is seen with shadows out to 80 m, the
camera's far plane:
- the 2,048 stones and 64 posts cast shadows across the whole 64 m hillside;
- a stone at the player's feet casts a shadow with edges as sharp as M22's room;
- `--shadow-cascades=1` shows the same yard through M22's single map, for comparison;
- `--shadow-tint` colours each receiver by the cascade it read, so a person can see the splits.

The court gets cascades through the renderer's default, with no change of its own except a
farther shadow distance, and the owner plays it.

**The exit condition:**
- The cascade maths agrees with a CPU oracle.
- One cascade reproduces M22's matrix bit for bit, and every M22 and M24 shadow readback holds.
- New Metal readbacks show a resolved near shadow that one map cannot resolve, and a far shadow
  in the last cascade. They also show no bleeding between tiles and the blend across a seam.
- The yard holds 60 Hz with four cascades on macOS/Metal and on Windows/Vulkan, and Vulkan
  validation is clean.

**In M39:**
- splits over the shadow distance and one sphere fit per cascade, each snapped to its own texels
  (§3);
- the atlas, its tiles and the caster pass that fills them (§4);
- the lookup: the cascade chosen by view depth, a blended band and filter taps kept inside their
  tile (§5);
- the frame uniform's second layout (§6);
- configuration, statistics, the overlay's line and the tint (§7);
- the yard and the court (§8).

**Not in M39, each owned elsewhere:**
- Point and spot shadows, and translucent (coloured) shadows: M40, which takes tiles of this
  atlas (ADR-0079).
- Texture arrays and cubemaps in the RHI: M41.
- Contact-hardening penumbrae (PCSS): M40. Screen-space contact shadows: M81, which brings the
  depth prepass they read.
- Shadows cast by particles, and particles receiving shadows: M79.
- Ray-traced shadows: M98.
- Timing the shadow pass on the GPU, caching casters, alternate-frame cascades and drawing a
  caster once into several tiles: M73 and M99 (§13).
- Anything in the public table: v6 is frozen, and cascades are the host's renderer
  configuration, as `shadow_size` was (§9).

## 2. What exists

**`engine/src/render3d/lighting.zig`** holds the pure maths, and is the oracle every readback
compares against:
- `FrameUniform` is 1,216 bytes: the view-projection, camera and exposure, ambient, `counts`,
  one `shadow_matrix`, one `shadow_parameters` and sixteen packed lights. An offset test pins
  every member.
- `fitShadow(camera, aspect, distance, light_world, size)` returns a `ShadowFit`: the smallest
  sphere around the camera frustum between `near` and `min(far, distance)`, padded half a texel a
  side and snapped to whole texels in light space. `ShadowFit.includeCaster` extends the depth
  range toward the light for a caster whose bounds overlap the receiver box, and
  `ShadowFit.matrix` is the orthographic light matrix with reversed-Z.
- Two tests pin it: the sphere is invariant under camera rotation and holds every frustum corner,
  and the snap moves only by whole texels.

**`engine/src/render3d/renderer.zig`** draws and owns the GPU side:
- `Config` has `shadow_size` (0, 1024, 2048 or 4096), three depth-bias fields and
  `shadow_normal_offset`, in texels. `FrameView` has `shadow_distance` (default 25 m).
- At most one light may cast, and it must be directional (`InvalidShadowCaster`).
- During preparation (around line 1815) the renderer fits the one map and extends it by casters.
  It culls the frame's opaque and mask draws against the light box into `shadow_order`, then
  `ensureShadowResources` makes the `depth32_float` target and its bind group on first use.
- `recordShadow` sets one viewport and scissor and draws each caster with its world matrix.
  `shadow.vert.glsl` and `shadow.metal` multiply by the frame uniform's `shadow_matrix`. Opaque
  casters draw with no fragment stage (M26 Step 9).
- `Stats` counts `shadow_draws` and `shadow_culled`. The overlay's profiler prints them on one
  line (`engine/src/debug/profiler_panel.zig:149`).

**The shaders.** `lit.frag.glsl` and `lit.metal` transform the receiver by `shadow_matrix` after
a normal offset of `shadow_parameters.y` metres. They take a 3×3 grid of bilinear comparison taps
spaced `shadow_parameters.x`, the reciprocal map size. `counts.y` switches the lookup on.
`unlit` and `particle` declare the same `Frame` struct and assert its size, 1,216 bytes.

**The RHI** already has what this needs:
- viewports and scissors with an origin (`rhi/command.zig`'s `Viewport` and `ScissorRect`);
- comparison samplers and sampled depth (M22);
- a device's `max_texture_dimension`.

It has no texture arrays, and M39 adds none (§4).

**The samples:**
- `sandbox3d` passes `shadow_size = 2048`, or 0 with `--shadows=off`. Its views use the default
  shadow distance of 25 m with a far plane of 80 m, so the yard at (70, 0, 0) is mostly
  unshadowed beyond 25 m.
- The court uses `shadow_distance = 20`.
- `--shadow-proof` draws M22's code-built cube over a ground.

## 3. Splits and fits

**Where it lives:** `render3d/lighting.zig`, beside `fitShadow`. It is pure maths with no device,
so it unit-tests on the null backend and is the readbacks' oracle.

**Splits.** The shadowed range runs from `near` to `d = min(far, shadow_distance)`. It is cut
into `n` cascades, one to four, at the practical split scheme's distances:

```
split(i) = λ · near · (d / near)^(i/n)  +  (1 − λ) · (near + (d − near) · i/n),   i = 1 … n
```

λ mixes the logarithmic split, which keeps texel density constant with depth, with the uniform
one, which keeps the last cascade from covering almost everything. **The default is λ = 0.75.**
At the yard's 0.1 m to 80 m, with the samples' field of view and a 16:9 window, that puts the
seams at about 5.4 m, 12.1 m and 26.3 m.
`split(n) = d` exactly, which the code writes rather than computes.

**One fit per cascade.** Cascade `i` is `fitShadow` applied to the slice of the frustum between
`split(i−1)` and `split(i)`, with `split(0) = near`. The existing function takes a whole frustum
from `near`, so it gains a near distance for the slice. Each fit keeps M22's three properties:
- **The fit is a sphere,** so its size does not change as the camera turns, and the cascade's
  texel size is fixed for a given view.
- **It is snapped to its own texels,** so shadow edges do not crawl as the camera moves.
- **Its depth extends toward the light** for any caster whose bounds overlap its box.

**One cascade is M22.** With `n = 1`, the one slice is `near` to `d` and the fit is
`fitShadow`'s, bit for bit. A test compares every field and the matrix. This is what lets the
change be made with every existing readback still holding.

**Why a sphere, and not a tighter box.** A box fitted tightly to each slice in light space uses
more of the map, but it changes size as the camera turns. Its texel size then changes every
frame, and every edge shimmers. M22 chose the sphere for that reason, and a cascade has the same
problem at four times the rate.

**Now / designed for / postponed:**
- **Now:** four cascades at most, and λ and the blend band as configuration.
- **Designed for:** a cascade count and splits that a game could set per view. They are plain
  numbers in `Config`, and nothing caches them across frames.
- **Postponed:** cascades that update every other frame, and cached casters (§13).

## 4. The atlas

**One `depth32_float` texture holds every cascade, as tiles.** Each tile is `shadow_size` texels
a side:

| Cascades | Tiles | Atlas size |
| --- | --- | --- |
| 1 | one | `s × s` |
| 2 | two, side by side | `2s × s` |
| 3 or 4 | a 2 × 2 grid, one tile unused at 3 | `2s × 2s` |

Cascade `i` sits at column `i mod 2` and row `i / 2`.

**Why an atlas and not a texture array.** A texture array is the usual answer, but:
- the RHI has none, and the roadmap gives texture arrays to M41, with cubemaps;
- an atlas needs nothing new below `render3d`, since viewports and scissors with origins already
  exist;
- M40's spot and point shadows want an atlas anyway. They are many small maps of different sizes,
  which an array of equal layers holds badly. ADR-0079 records that they take tiles of this one.

The price is that filter taps can cross into a neighbouring tile, which §5's clamp prevents.

**Its size is checked at `init`.** An atlas side greater than the device's
`max_texture_dimension` is `InvalidConfig`.
- At the default, four 2048 tiles make a 4,096-texel atlas. That is 64 MiB, where M22's map was
  16 MiB, and every Vulkan device must allow it.
- Four 4096 tiles need 8,192 texels and 256 MiB. Metal on Apple silicon and the Arc A750 allow
  it. A device that does not gets a named refusal, not a failed allocation.

**The caster pass is one render pass over the whole atlas:**
1. Clear the whole atlas to 0 (reversed-Z: far is 0).
2. For each cascade in order, set its tile's viewport and scissor and draw its casters.

Each cascade's casters are the frame's opaque and mask draws whose material casts, culled against
that cascade's light box by M20's frustum code. That is the test M22 ran for the one map. A
caster in two cascades is drawn twice, and is counted twice in `shadow_draws`.

**The matrix reaches the vertex shader in the draw's inline constants.**
- The shadow vertex shader now reads `constants.world`. For a shadow draw, `render3d` multiplies
  the cascade's light matrix by the draw's world matrix on the CPU and passes the product there.
- The shader no longer reads the frame uniform at all, so one bind group serves all four
  cascades, and no per-cascade uniform is needed.
- The product is computed once per draw per cascade, in `f32`, as the GPU would have done.
- The cofactor half of the constants is unused by the shadow pass, as it is now.

**The depth bias stays one pipeline state for every cascade.**
- A constant and a slope-scaled bias are measured in depth-buffer units. Each cascade's depth
  range differs, so the same bias is a different distance in each.
- M22's defaults (−1, −1, unclamped) are small enough that this has not mattered. The normal
  offset (§5), which scales with each cascade's texel, does most of the work.
- Per-cascade bias would need dynamic bias state, which the RHI does not have. It is named in §13
  in case a readback shows acne in one cascade and not another.

## 5. The lookup

**The cascade is chosen by view depth.**
- The receiver's depth along the camera's forward axis is compared with the split distances.
  The first cascade whose far split lies beyond it is the one read.
- A sphere fit holds its whole slice, so the chosen cascade always covers the point. There is no
  need to test map coordinates.
- Past the last split the receiver is unshadowed, as M22's was past `shadow_distance`.

**Seams are blended.**
- In the last `shadow_cascade_blend` fraction of each cascade's depth range (default 0.1), the
  receiver also reads the next cascade, and mixes the two visibilities linearly by its position
  in the band.
- The last cascade blends to "unshadowed" over its band, so the shadow fades out at the distance
  rather than stopping on a line.
- Outside a band, one cascade is read, so most pixels pay for one lookup, as now.

**The normal offset scales per cascade.** `shadow_normal_offset` stays in texels, and each
cascade multiplies it by its own texel size in metres. A far cascade's coarse texels get a
correspondingly larger offset, which is what M22's offset was for.

**Filter taps stay inside their tile.**
- The filter is M22's 3×3 grid of bilinear comparison taps. Its footprint reaches 1.5 texels past
  the centre tap.
- Each tap's coordinate is clamped to the tile's rectangle, inset by two texels, so no tap reads a
  neighbour's depth.
- A sphere fit's tile already has half a texel of padding on each side, and the clamp only
  matters at the sphere's rim, which the slice's frustum never reaches. The clamp is kept anyway,
  because a test can show what happens without it (§11).

**The tint.** When the frame asks for it (§7), a receiver's lit colour is multiplied by a fixed
colour for the cascade it read: red, green, blue, yellow, mixed in the blend band. It is the
same shader with a uniform switch, not a variant. It exists so a person can see the splits, and a
readback checks it.

## 6. The frame uniform, second layout

`FrameUniform` is replaced, not extended: the shadow block changes shape, and every shader that
declares `Frame` changes with it. Its members, in order, all `vec4`-aligned so std140 and Metal
agree:

| Member | Size | Holds |
| --- | --- | --- |
| `view_projection` | 64 | unchanged |
| `camera_exposure` | 16 | unchanged |
| `ambient` | 16 | unchanged |
| `counts` | 16 | x: lights; y: cascades (0 means no lookup); z: the tint switch |
| `camera_forward` | 16 | xyz: the camera's forward axis; w: the blend fraction |
| `shadow_splits` | 16 | each cascade's far split in view depth, metres |
| `shadow_offsets` | 16 | each cascade's normal offset, metres |
| `shadow_parameters` | 16 | x: the reciprocal atlas size; y: the inset for the clamp, in UV |
| `shadow_tiles` | 4 × 16 | each tile's UV rectangle: origin xy, far corner zw |
| `shadow_matrices` | 4 × 64 | each cascade's light matrix, folded into its tile's UV |
| `lights` | 16 × 64 | unchanged |

- The total is 1,520 bytes, well inside every backend's uniform limit.
- Each cascade's matrix maps a world point straight to atlas UV and depth, with its tile's scale
  and offset folded in, so the shader does one multiply per lookup.
- `lighting.zig`'s offset test pins every member. Each shader's size assertion moves to 1,520:
  `unlit` and `particle` read none of the new members, but they declare the struct.

## 7. Configuration, statistics, the overlay

**`Config` gains:**
- `shadow_cascades: u32 = 4`. 1 to 4; anything else is `InvalidConfig`. `shadow_size = 0` still
  means no shadows at all.
- `shadow_split_lambda: f32 = 0.75`. Finite and between 0 and 1.
- `shadow_cascade_blend: f32 = 0.1`. Finite, from 0 to 0.5.

`shadow_size` is now each tile's size. All three fields are the host's, like `shadow_size`, and
none is content (`light.md` §9 kept bias out of content for the same reason).

**Cascades are on by default.** Every host that casts a shadow gets four cascades unless it says
otherwise.
- **For:** a renderer default should be the better picture, and only the samples and the court
  use this renderer.
- **Against:** the court's and the room's pictures change.
- Their simulation digests do not change, since nothing simulated reads a shadow, and a host keeps
  M22's picture exactly with `shadow_cascades = 1`.

**`FrameView` gains `shadow_tint: bool = false`,** the debug colouring of §5. It is per frame
because a sample toggles it with a key.

**`Stats` gains:**
- `shadow_cascades`, the number fitted this frame;
- `shadow_cascade_draws: [4]u32`, whose sum is `shadow_draws`.

`shadow_culled` counts a caster once per cascade that culled it.

**The overlay's profiler line** becomes `3D: 3 lights  4 cascades  41 shadow draws (12 9 11 9)
17 shadow culled`. It is an ordinary `Stats` read and widens no grant.

## 8. The samples

**`sandbox3d`:**
- Its own config record (`sandbox3d:config.main`, the sample's schema) gains `shadow_distance`,
  default 80, so the yard is shadowed to the far plane. The dusk mod can change it.
- New flags: `--shadow-cascades=1|2|3|4` (default 4) and `--shadow-tint`. **T** toggles the tint
  while walking, and the overlay shows the cascade line.
- The exit report logs each cascade's draws, splits and texel size in centimetres.
- The tour's simulation pin, `1052a9ae891b0d27`, and every older pin do not move, because
  rendering does not reach the simulation. The tour is run to prove it.

**The measurement the trigger asked for.** `light.md` §14 brings cascades back for "measured
aliasing at `shadow_distance` a game needs". The yard is that scene, and Step 4 records it:
- one 2048 map over 0.1–80 m has a texel of about 8.5 cm, so a shadow's edge steps every
  8.5 cm even at the player's feet;
- with four cascades at λ = 0.75, the texels are about 0.6, 1.3, 2.8 and 8.5 cm, nearest first.

Step 1 computes both from the oracle, and Step 4 shows them in the picture.

**The court:**
- `shadow_distance` goes from 20 m to 40 m, so shadows reach twice as far across the court.
- No content, rule or simulation changes. Its four digests hold, and the owner plays it.

**`--shadow-proof`** keeps M22's cube and gains nothing. The readbacks of §11 are the proof now.

## 9. The public table

**Nothing.** FoundryApi_v6 is frozen (ADR-0059). A mod's light may already say it casts, and M22's
rule stands: one directional caster per frame. How that shadow is drawn is the host's `Config`,
which no mod can reach, as `shadow_size` already was. M48's list does not change: a host-granted
renderer configuration is not something M48 publishes.

## 10. Platform assessment

**Metal (macOS, Apple M5):**
- `depth2d::sample_compare` with a clamped coordinate. Nothing else is new.
- An 8,192-texel atlas is within the device's limit.

**Vulkan (Windows, Arc A750):**
- The GLSL variants change with the uniform.
- The atlas is an ordinary 2D depth image, and the tile viewports are core Vulkan.
- The GLSL is recompiled by the pinned SDK tools (ADR-0038).
- **The PC is needed:** the shaders, the uniform and the readbacks change, and Step 6 runs the
  Vulkan suites, the readbacks, both samples windowed and the budgets.

**Linux:**
- Compile only, confirmed at the close.
- None of `3d.md` §10.2's triggers fires: nothing in the platform layer, presentation or a
  Linux-only path changes, and the Vulkan code is the code the PC proves.

## 11. Verification

**Headless, in `zig build test` (null backend and Metal):**
- **Splits:**
  - strictly increasing, from `near` to exactly `d`;
  - λ = 0 gives the uniform splits, and λ = 1 the logarithmic ones;
  - a far plane nearer than `shadow_distance` cuts the range there.
- **Fits:**
  - each cascade's sphere is invariant under camera rotation;
  - it holds every corner of its slice;
  - it moves only by whole texels of its own size;
  - it extends toward the light only for an overlapping caster.
- **One cascade:** fit, matrix and `FrameUniform` equal M22's bit for bit.
- **The uniform:** every member's offset, and the size of 1,520 bytes, which each shader also
  asserts.
- **Configuration:** cascades of 0 and 5, λ below 0, above 1 or NaN, and a blend below 0, above
  0.5 or NaN are each `InvalidConfig`. An atlas side over the device's limit is `InvalidConfig`,
  tested with a null device whose limit is set low.
- **Casters per cascade:**
  - a caster near the camera is drawn into cascade 0 and culled from cascade 3;
  - one spanning two cascades is drawn into both;
  - blend materials and disabled casters are never drawn;
  - the per-cascade counts sum to `shadow_draws`.

**Metal readbacks, compared with the CPU oracle as `light.md` §11's are (±2/255, no penumbra
pixel compared):**
- **Every M22 and M24 shadow readback holds unchanged** with `shadow_cascades = 1`, and again with
  four cascades wherever the scene's receivers fall in cascade 0.
- **A thin pole, 2 cm across, 3 m in front of the camera,** casts a shadow line that four
  cascades resolve: pixels under the line read ambient only. With one map at 80 m, its texel is
  wider than the pole, and the same pixels read lit. That one comparison is the milestone's
  purpose.
- **A wall 60 m away** casts into the last cascade: a receiver behind it reads ambient, one beside
  it reads lit.
- **No bleeding:** a caster placed so cascade 0's filter would reach across its tile's edge into
  cascade 1's leaves a lit receiver lit.
- **The blend:** a receiver in a band reads between its two cascades' values, and one just outside
  reads its own.
- **The tint:** one receiver in each cascade reads its tint colour, modulated as the oracle says.
- **Past the last split,** a receiver under a caster reads lit.

**Each guard is broken once** and must fail its test:
- the clamp removed;
- the tile origin swapped;
- the split order reversed;
- the band's weight inverted;
- the normal offset left per-map instead of per-cascade.

**The samples:**
- `sandbox3d` thirty frames headless at each cascade count, and the tour, with every pin held.
- The court's `court-test` with its four digests.
- Windowed and relocated: the yard at four cascades and at one, and the court.

**Budgets, p95, paced, from relocated ReleaseSafe installs:**
- **The yard:** a whole frame within 16.67 ms with four cascades and no skipped frames, on the M5
  and on the i3/Arc. `render.world`'s CPU time is recorded at one and at four cascades, so the
  cascades' cost is a number, not a guess.
- **The court:** unchanged frame pacing.

## 12. Implementation order — seven steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

### Step 1 — `render3d`: splits and fits, as maths

§3 and §7's `Config` fields and their validation. `lighting.zig` gains the split scheme, the
sliced fit and a `CascadeFit` of up to four `ShadowFit`s. The renderer still draws one map: it
fits with `n = 1`, through the new code. Tests: §11's splits, fits, one-cascade identity and
configuration refusals. The Resolution records the yard's texel sizes at one and at four
cascades, the trigger's measurement.
**Exit:** the sliced fit with one cascade equals `fitShadow` bit for bit, and every existing test
and readback passes through it.

### Step 2 — `render3d`: the uniform's second layout and the atlas, one tile at a time

§6 in Zig, MSL and GLSL, for every shader that declares `Frame`. The shadow vertex shader takes
its matrix from the draw's constants (§4). The atlas texture, sized by §4's table and checked
against the device's limit. The caster pass loops over tiles, but the lookup still reads cascade 0
only.
**Exit:** with `shadow_cascades = 1`, every M22 and M24 shadow readback holds on Metal through
the new uniform, atlas and caster pass. The offset and size tests pin 1,520 bytes in all three
languages.

### Step 3 — `render3d`: four cascades, the lookup and the overlay

§4's per-cascade casters, §5's selection, blend, clamp, per-cascade offset and tint, §7's stats,
the overlay's line.
**Exit:** §11's Metal readbacks pass: the thin pole, the far wall, no bleeding, the blend, the
tint and past the last split. Each guard is broken and fails.

### Step 4 — `sandbox3d`: the yard in cascades, on Metal

§8: `shadow_distance` in the sample's config, the flags, the tint key, the exit report, the tour
run at each cascade count with every pin held, and the yard's budgets from a relocated
ReleaseSafe install.
**Exit:** the yard's whole frame holds 16.67 ms at p95 with four cascades on the M5, and the
recorded texel sizes match Step 1's.

### Step 5 — the court

§8's court: `shadow_distance` 40, cascades by default, `court-test`'s digests held, a relocated
run of each ending, and the owner plays it.
**Exit:** the four court digests hold, the court's frame pacing is unchanged, and the owner has
played it with cascades.

### Step 6 — Windows/Vulkan

`scripts/m39/`, from M38's. On the owner's PC, idle first, from a clone, `-j2` at below-normal
priority:
- the null and Vulkan suites, with the Vulkan readbacks at ±3/255;
- every pin;
- the installed content bytes against the Mac's;
- the yard at one and four cascades and the court, windowed and relocated, validation clean;
- the budgets on the i3.

**Exit:** every readback, pin and byte equals the Mac's, validation is clean, and the yard holds
16.67 ms at p95 with four cascades on the Arc.

### Step 7 — Close M39

Resolve the contract discrepancies in their documents:
- `light.md` §9 (one map becomes cascades in an atlas), and §14's cascade row struck through;
- `3d.md` §4's texture-array trigger (cascades did not need one; M41 keeps them) and §11's
  "cascaded shadows";
- `render3d.md`'s shadow pass, and `debug-overlay.md` §7.5's statistics line;
- ADR-0052, if Step 4's measurement says anything about forward shading's cost.

Then:
- move ADR-0079 to Accepted and into `CLAUDE.md` §4.1, and update §4.3's `render3d` line and §9's
  row;
- add M39's costs and `scripts/m39` to `AGENTS.md`;
- update the roadmap (M39 done, and §13's items in the rows of M40, M73, M81 and M99), the
  design index, the README and `PROJECT_STATE.md`;
- tag `m39`, push when asked, and stop before M40's design.

## 13. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).
- **Point and spot shadows, and translucent shadows:** M40. It allocates tiles of this atlas,
  which needs a tile allocator in place of §4's fixed table. M39 builds only the table.
- **Texture arrays and cubemaps in the RHI:** M41, unchanged.
- **Per-cascade depth bias:** M40, which must add bias per tile anyway for spot maps of different
  depth ranges. The trigger is a readback with acne in one cascade and not another.
- **The shadow pass timed on the GPU:** M73, which brings GPU timestamps to the profiler. Until
  then Steps 4 and 6 record its CPU cost and the frame's pacing.
- **Caster caching, cascades updated on alternate frames, and drawing a caster once into several
  tiles:** M99, with its chunked submission. The trigger is a shadow pass measured over its share
  of a frame.
- **Contact-hardening penumbrae (PCSS):** M40, with the other shadow kinds.
- **Screen-space contact shadows:** M81, which adds the depth prepass they read.
- **Particles casting and receiving shadows:** M79, as the roadmap already says.

## 14. Decisions acceptance fixes

Each is recommended as written.

| # | Choice | Where |
| --- | --- | --- |
| 1 | The one directional caster's shadow is up to four cascades, at the practical split scheme with λ = 0.75 (ADR-0079) | §3 |
| 2 | Each cascade is M22's sphere fit over its slice, snapped to its own texels; one cascade is M22's fit bit for bit | §3 |
| 3 | The cascades are tiles of one `depth32_float` atlas, not a texture array; texture arrays stay M41's, correcting `3d.md` §4's trigger; M40's shadows take tiles of the same atlas (ADR-0079) | §4 |
| 4 | An atlas larger than the device's `max_texture_dimension` is `InvalidConfig` at `init` | §4 |
| 5 | The cascade's matrix reaches the shadow vertex shader folded into the draw's inline constants; the shadow pass reads no uniform | §4 |
| 6 | Depth bias stays one pipeline state; the normal offset scales per cascade; per-cascade bias is M40's | §4, §5 |
| 7 | Selection by view depth; a linear blend over the last 10% of each cascade, and a fade at the last; taps clamped two texels inside the tile | §5 |
| 8 | `FrameUniform` is replaced by a 1,520-byte second layout, asserted in every shader | §6 |
| 9 | `Config` gains `shadow_cascades = 4`, `shadow_split_lambda = 0.75` and `shadow_cascade_blend = 0.1`, the host's and not content; cascades are on by default | §7 |
| 10 | `FrameView.shadow_tint`, per-cascade statistics and one widened overlay line | §7 |
| 11 | `sandbox3d`'s config gains `shadow_distance` (80); the yard is the trigger's measured scene; the court goes to 40 m | §8 |
| 12 | Nothing in the public table; M48's list is unchanged | §9 |
| 13 | The PC runs Step 6; Linux is compile only | §10 |
| 14 | Seven steps: maths, the atlas at one cascade, four cascades, the yard, the court, Windows, the close | §12 |
| 15 | §13's items go to M40, M41, M73, M79, M81 and M99; Step 7 writes each into its roadmap row | §13 |

Once these are accepted nothing blocks Step 1: it is pure maths in `lighting.zig` and `Config`'s
validation, on the code as it is.

## Resolution — Step 1: splits and fits, as maths (2026-11-13)

**Acceptance.** The owner accepted §14 as written by asking for Step 1. The status line here,
ADR-0079 and `CLAUDE.md` §4.1's new "Cascaded shadows" row record it.

**What `lighting.zig` now holds:**
- `fitShadowSlice(camera, aspect, near, far, light, size)` is M22's fit over one slice. The
  slice's frustum keeps its apex at the camera, so the sphere formula is unchanged with the
  slice's near in place of the camera's. `fitShadow` now calls it with `camera.near` and the
  shadowed range's end, so the old function and the slice share one body.
- `cascadeSplits(near, far, count, lambda)` is §3's practical scheme. The logarithm is
  `core.math.exp`'s, not a linked library's. `splits[0] = near` and `splits[count] = far` are
  written, never computed, and entries past `count` repeat `far`.
- `CascadeFit` holds `count`, the splits and four fits. `fitCascades` fills them, and
  `CascadeFit.includeCaster` extends each cascade only by a caster overlapping its own box. Fits
  past `count` repeat the last slice's, so the array is never undefined.

**The renderer** (`Config`, preparation):
- **The fields.** `shadow_cascades = 4`, `shadow_split_lambda = 0.75` and
  `shadow_cascade_blend = 0.1` are new.
- **The check.** `validCascades` refuses, as `InvalidConfig`:
  - a count outside 1–4;
  - a weight outside [0, 1], or a band outside [0, 0.5];
  - NaN or infinity in either;
  - an atlas side, `shadow_size` × (1 or 2), over the device's `max_texture_dimension`.

  It is a pure function of the config and the limit, because the null device reports a fixed
  16,384. The test drives it with Vulkan's guaranteed 4,096 and with 8,191 and 8,192.
- **Preparation** fits through `fitCascades` with **one** cascade, whatever `shadow_cascades`
  says, until Steps 2 and 3 give the atlas more tiles.

**The one-cascade identity holds bit for bit.** For a turned, moved camera, distances of 6, 25,
80 and 500 m, and maps of 1,024, 2,048 and 4,096, `fitCascades(…, 1, …)` equals `fitShadow` in
every field and in its matrix. *(Corrected at Step 2: this Resolution said that every M22 and M24
shadow readback passed through the new path on Metal. They did not run. The bar's
`zig build test` uses the null backend, where they return early, and Step 1 did not run
`-Drhi=metal`. Step 2's Metal run is the first to pass them through the cascade code.)*

**The trigger's measurement.** This is the yard's view: 0.1–80 m, the samples' field of view of
π/3.2, 16:9, and 2048 texels. A test pins:

| Fit | Range | Texel |
| --- | --- | --- |
| One map | 0.1–80 m | 8.52 cm |
| Cascade 0 | 0.1–5.42 m | 0.58 cm |
| Cascade 1 | 5.42–12.13 m | 1.29 cm |
| Cascade 2 | 12.13–26.29 m | 2.80 cm |
| Cascade 3 | 26.29–80 m | 8.52 cm |

Near the player, cascades are about fifteen times finer. The last cascade is no finer than one
map: a slice ending at the far plane has nearly the same sphere as the whole frustum, which is
why the near cascades are where the gain is.

**A sharpened test.** M22's snap test moved the camera by 1.2 texels and expected the centre to
move by exactly one, which holds only where the centre's fraction is zero. For cascades at
arbitrary offsets, the test instead asserts the snap property itself: after any move, each
cascade's centre lies on a whole multiple of its own texel, and the texel does not change.

**Guards broken on purpose, all four at once, each failing its own test:**

| Mistake | Test that failed |
| --- | --- |
| The split weight swapped (λ on the uniform term) | the splits test |
| Each slice fitted from the camera's near plane | the yard's texels |
| Casters extending cascade 0 only | the caster test |
| The atlas limit ignored | the configuration test |

**Bar:** passed, exit 0 throughout.
- `zig build test`: 2,990/3,000 (ten skips, six new tests), 132/132 steps.
- `fmt`, the four checks, the four thirty-frame samples and `fdt-check` passed.
- The tour passed with every pin, and `court-test` 87/89 (two skips).

No shader, uniform or texture changed. Step 2, the uniform's second layout and the atlas at one
cascade, is next.

## Resolution — Step 2: the uniform's second layout and the atlas, one tile at a time (2026-11-14)

**The uniform.** `lighting.FrameUniform` is §6's 1,520 bytes, and the offset test pins all eleven
members. Every shader that declares `Frame` declares all of them, and every Metal one asserts the
size:
- in GLSL: `lit` vertex and fragment, `particle`, and the four `unlit` vertex variants;
- in MSL: `lit`, `particle` and `unlit`.

Vulkan's shader-ABI agreement (`rhi/backends/vulkan/spirv.zig`, run by `fshadercheck` at build
time) checks the new member offsets.

**One correction to §6:** `shadow_parameters.xy` is the reciprocal atlas width *and height*,
because two cascades make an atlas twice as wide as it is tall. A single "reciprocal atlas size"
would space the taps wrongly in v. `zw` is reserved for Step 3's clamp inset.

**The shadow vertex shaders no longer declare `Frame`.** `shadow.metal` and `shadow.vert.glsl`
take the cascade's light matrix multiplied into `constants.world` (§4). The renderer computes
`fit.matrix().mul(item.world)` once per draw per cascade, with the cofactor zeroed. Two places
now encode that the shadow pass reads no uniform:
- the agreement check has a shadow profile that requires the absence of set 0's binding 0;
- the Metal entry points lost their `buffer(9)` parameter.

The caster pass still binds group 0, because the pipeline layout is shared with the lit pass.

**The atlas:**
- `shadowAtlasExtent`, `shadowTileOrigin` and `shadowTileRect` implement §4's table: cascade `i`
  at column `i mod 2`, row `i / 2`.
- The texture is created at that extent, labelled "render3d shadow atlas", and cleared once per
  frame by the one pass.
- `recordShadow` loops over the fitted cascades. It sets each tile's viewport and scissor with
  its origin, and draws that cascade's casters. Preparation still fits one cascade, so the loop
  runs once. With the default four cascades, cascade 0 now sits in the top-left quarter of a
  2 × 2 atlas.

**The lookup reads cascade 0 through its tile.**
- `lighting.tileMatrix` folds a tile's rectangle into the light matrix. Clip x and y map to the
  tile's U and V, with V downward as M22's `.5 - y*.5` had it, and depth is unchanged.
- The lit shaders test `q.xy` against the tile's rectangle instead of `|q.xy| ≤ 1`, and space the
  taps by `shadow_parameters.xy`.
- `shadow_splits`, `shadow_offsets` and `camera_forward` are written now, for one cascade. Only
  the offset is read before Step 3.

**Readbacks on Metal:**
- M22's directional shadow readback now runs at one cascade *and* at four. At four, cascade 0 is
  a quarter of a 2,048-texel atlas, so the tile matrix and the atlas spacing are what the pixels
  prove.
- M24's bent strip runs at the default of four.
- Both pass within M22's tolerances.
- `zig build test -Drhi=metal`: **3,003/3,024, 21 skips**, 146/146 steps.

**New tests:**
- the tile matrix maps clip corners to the rectangle's, v downward;
- the atlas extent and every tile rectangle, for one to four cascades;
- the uploaded uniform at four cascades: count, forward, the reciprocal atlas, tile 0's rectangle,
  the split, the offset and the folded matrix, with the unused matrices left at identity. The
  atlas texture is 2,048 a side on the null device.

**Guards broken on purpose:**

| Mistake | Backend | What failed |
| --- | --- | --- |
| V not flipped | null and Metal | the tile-matrix test only |
| Tile column and row swapped | null | the atlas test |
| Taps spaced by tile, not atlas | null | the uniform test |
| The unfolded clip matrix uploaded | null | the uniform test only |
| The unfolded clip matrix uploaded | Metal | both shadow readbacks and the uniform test |

The flipped v escapes the readbacks: their shadows straddle the middle row, which a vertical flip
leaves in place. **Step 3's readbacks must put a shadow away from the tile's horizontal
centre**, so that a wrong v shows in pixels as well.

**A fix outside the step.** `zig build check -Drhi=vulkan -Dtarget=x86_64-windows-gnu
-Doptimize=ReleaseSafe` failed to link `core`'s tests: `ldexp` was undefined. `exp.zig`'s tests
used `std.math.exp2` for exact powers of two, which lowers to `ldexp` in an optimized Windows
test build, and that build links no C library. This predates M39: those tests are M31's, and no
step since has run that check with shaders changed. The tests now build the powers from their
bits (`powerOfTwo`). The functions under test did not change.

**Bar:** passed, exit 0 throughout.
- `zig build test` (null): 2,993/3,003 (ten skips, three new tests), 132/132 steps.
- `fmt`, the four checks, the four thirty-frame samples, `fdt-check`, the tour with every pin,
  and `court-test` 87/89 (two skips).
- The five Vulkan checks, with the SDK's tools on `PATH`: `vulkan-check` for Windows and Linux,
  and `check` for Windows, Linux and Windows ReleaseSafe.
- `-Drhi=metal`, as above. From here on, every step that changes the renderer also runs
  `zig build test -Drhi=metal`, since that is where the readbacks run.

Step 3 is next: four cascades, per-cascade casters, selection, the blend, the clamp, the tint,
the statistics and the overlay's line.

## Resolution — Step 3: four cascades, the lookup and the overlay (2026-11-14)

**Casters per cascade.** Preparation now fits `shadow_cascades` cascades. Each caster carries a
four-bit mask of the cascades whose light box holds it, from M20's frustum test against each
cascade in turn. `shadow_order` lists every caster drawn into any tile, so budgets and pipelines
see each caster once, and `recordShadow` skips a draw whose bit is clear for the tile it is
drawing. `Stats` gains `shadow_cascades` and `shadow_cascade_draws`, whose sum is
`shadow_draws`; `shadow_culled` counts once per cascade that culled a caster.

**The lookup** (`lit.metal`, `lit.frag.glsl`):
- **Selection.** The receiver's view depth is `dot(world - camera, forward)`. The first cascade
  whose far split lies beyond it is read; past the last, nothing is.
- **The band**, a sharpening of §5: it is the last `shadow_cascade_blend` of the range from the
  *previous split*, and cascade 0's range is measured from the camera, not the near plane. The
  uniform carries far splits only, and 0.1 m makes no visible difference. `lighting.chooseCascade`
  is the same rule on the CPU, and the readbacks' oracle uses it.
- **Outside a tile.** A cascade's lookup returns −1 when the point falls outside its tile or depth
  range. The chosen cascade then reads as lit, as M22's map did. A band's *next* cascade is
  skipped, because its sphere holds its own slice, not the band before it.
- **The clamp.** Each tap is clamped to its tile inset by two texels.
  `shadow_parameters.zw` holds that inset in U and V.
- **The normal offset** is `shadow_offsets[c]` for whichever cascade is read.
- **The tint** (`FrameView.shadow_tint`, `counts.z`) multiplies the final colour by
  `lighting.cascade_tints`: red, green, blue and yellow, softened to 0.25 in the other channels
  so shading still shows. It mixes toward the next cascade's colour across a band, and toward
  white across the last band, as the shadow fades there.

**The overlay** reads, as §7 has it, `3D: 3 lights  4 cascades  41 shadow draws (12 9 11 9)  17
shadow culled`. With nothing casting, it reads `0 cascades` and has no parentheses.

**Readbacks on Metal**, compared with the CPU oracle at ±2/255:

| Readback | What it shows |
| --- | --- |
| M22's and M24's | Pass unchanged at four cascades with the real lookup. M22's receiver, 4 m out with a 6 m shadow distance, now reads cascade 3. |
| A 2 cm pole, 3 m out, shadowing a wall 4 m out | At the default 2,048 tiles and the samples' field of view, cascade 0's texel is 4.1 mm and the pixel reads ambient only. One map over 80 m has 6.1 cm texels, and more than half the light gets through. |
| A canopy 3 m above the eye, shadowing a wall facing the camera | The wall is in shadow at 9, 20, 64 and 72 m (cascades 1, 2, 3, 3), and above the shadow it reads lit. At 76 m it is in the last band, and the light let through is that band's weight, 0.255. At 83.2 m, past the last split, it reads lit. |
| The tint, on lit ground | Rows in cascades 0 to 3 read their colours. A row in cascade 0's band reads the mix. |
| No bleeding | Two cascades, no band. Cascade 0's lookup is aimed one texel inside its tile's right edge, beside a caster in tile 1's left column, and reads lit. |

Several readbacks differ from §11's wording:
- **The shadow is off the middle row.** The pole's shadow falls 0.62 m above the eye, off the
  tile's middle row, as Step 2 asked. A flipped v now fails in pixels as well as in the unit test.
- **The canopy replaces the far wall.** A wall at 60 m would hide what it shadows from the camera,
  so a canopy overhead casts §11's far shadow instead.
- **The band is checked on a wall.** On the grazing ground, one row of pixels at 76 m spans about
  150 m of depth, and the rasterizer's subpixel precision moved the band weight by 3/255. A wall
  facing the camera has one depth per pixel.
- **The blend between two cascades** is shown by the tint, which shares the band weight with
  visibility. The visibility blend is shown by the last band's fade.
- **No bleeding could not happen naturally.** In a 32-pixel readback, a receiver inside a slice
  sits at least about twenty texels inside its tile, as §5 expected, so no placed caster could
  test the clamp. The test writes the aimed matrix into the uploaded uniform between `prepare` and
  recording. The point is to test the shader's clamp itself.

**Null tests:**
- `chooseCascade` and `cascadeTint` at band edges, past the last split, at fewer cascades and
  with no band.
- The uniform at four cascades: every tile, split, offset, folded matrix, the inset and the tint
  switch.
- Casters per cascade, with the light overhead:
  - a caster near the camera is drawn into cascade 0 and culled from cascade 3;
  - one at the first split is drawn into cascades 0 and 1;
  - one 70 m out is drawn into cascade 3 and not cascade 0;
  - blend and disabled materials are drawn into none;
  - the per-cascade draws add up to `shadow_draws`, and the culled count to the rest.
- Two M22/M24 tests that count one map's draws now set `shadow_cascades = 1`.

**Guards broken on purpose:**

| Mistake | What failed |
| --- | --- |
| The clamp removed | the bleeding readback alone |
| The band weight inverted | the canopy, the pole, and M22's and M24's readbacks |
| The normal offset taken from cascade 0 for every cascade | the canopy and M22's readback |
| The splits uploaded in reverse | the canopy, M22's and M24's readbacks, and the uniform test |
| Tile column and row swapped in the caster pass only | the canopy, through cascades 1 and 2 |
| V not flipped | the tile-matrix test and the pole readback |
| Every cascade culled against cascade 0's box | the per-cascade caster test and the particle test |

The GLSL lookup is the Metal one line for line. It is compiled and checked against the uniform by
the Vulkan checks, and it runs on the PC at Step 6.

**Bar:** passed, exit 0 throughout.
- `zig build test` (null): 2,998/3,008 (ten skips, five new tests), 132/132 steps.
- `zig build test -Drhi=metal`: 3,008/3,029 (21 skips), 146/146 steps.
- `fmt`, the four checks, the four thirty-frame samples, `fdt-check`, the tour with every pin,
  `court-test` 87/89 (two skips), and the five Vulkan checks.

Step 4 is next: the yard in cascades, with `sandbox3d`'s flags, its tint key, the exit report
and its budgets. The samples still use their own `shadow_distance` values, and they now draw
four cascades by default.

## Resolution — Step 4: the yard in cascades, on Metal (2026-11-14)

**What `sandbox3d` gained:**
- **The config.** `sandbox3d:config.main` gains `shadow_distance`, default 80 in the schema and
  80 in the record. The frame view takes it, clamped to 1–1,000 m, with a fallback of 80. M22's
  `--shadow-proof` keeps its own 20 m. A mod overriding the record, such as `dusk`, inherits the
  schema's 80 unless it says otherwise.
- **The flags.** `--shadow-cascades=1|2|3|4` (default 4) and `--shadow-tint`. Anything else,
  including `=0`, `=5` and `=12`, is the usage error, and a test pins both.
- **The tint key is H, not T** as §8 had it. T has put the player on M28's generated corner
  since M28.
- **Scripted keys.** H and Y join the scripted keys, so an evidence run can enter the yard and
  toggle the tint.
- **The exit report** prints each cascade's range, texel in centimetres and draws. It also
  prints `render.world`'s median and p95, and the frame's work without the pacing sleep,
  acquire or present over the last 240 frames, the measure the gallery's lines already use.
- **The accessor.** `Renderer.shadowCascades()` returns the last frame's fit, so a host can report
  splits and texels without reaching into the renderer.

**The measurement.** The headless run at the default prints the trigger's numbers, matching Step
1's oracle to the digit, since the window is 16:9 as that test assumed:

| Cascades | Ranges and texels | Shadow draws |
| --- | --- | --- |
| 1 | 0.1–80 m, 8.52 cm | 167 |
| 2 | to 12.13 m, 1.29 cm; to 80 m, 8.52 cm | 268 |
| 3 | to 7.38 m, 0.79 cm; to 19.80 m, 2.11 cm; to 80 m, 8.52 cm | 368 |
| 4 | to 5.42 m, 0.58 cm; to 12.13 m, 1.29 cm; to 26.29 m, 2.80 cm; to 80 m, 8.52 cm | 459 |

**The pins.** The 2,400-frame tour passed at each of the four counts, with every pin unchanged:
- the player `b85b52c97d259db4`;
- the walker `655e865f98779129`;
- the pacer's three replays and M34's save;
- the corner `e2992f93e5323345`;
- the yard `1052a9ae891b0d27`.

No shadow reaches the simulation. The thirty-frame run passed at each count and with
`--shadow-tint`.

**The budget, from a relocated, read-only ReleaseSafe install, windowed on the M5.** Each run was
900 frames with Y pressed at frame 120, standing in the yard's middle lane facing the boulder,
with saves redirected to scratch. Nothing under Application Support changed.

| | Four cascades | One map |
| --- | --- | --- |
| Shadow draws (culled) | 123 (705) | 67 (140) |
| Frame work, p95 (max) | **2.169 ms** (2.271) | 2.069 ms (2.217) |
| `render.world`, median / p95 | 0.411 / 0.482 ms | 0.334 / 0.388 ms |
| Paced interval, median / p95 | 16.662 / 17.422 ms | 16.662 / 17.208 ms |
| Skipped frames | 0 | 0 |

The cascades cost the yard about 0.1 ms of CPU a frame, and the frame works for 2.2 ms of its
16.67. The paced interval's p95 above 16.67 ms is the display's jitter around its 60 Hz sleep. It
is the same at one map, with no frame skipped, so §11's "whole frame within 16.67 ms" is read as
the frame's work, which is the budget the sample has always reported.

**Guard broken on purpose:** a parser accepting `--shadow-cascades=5` failed the options test.

**Bar:** passed, exit 0 throughout.
- `zig build test` (null): 2,998/3,008 (ten skips), 132/132 steps.
- `-Drhi=metal`: 3,008/3,029 (21 skips), 146/146 steps.
- `fmt`, the four checks, the four thirty-frame samples, `fdt-check`, the tour, `court-test`
  87/89 (two skips), and the five Vulkan checks.

Step 5 is next: the court at 40 m with cascades, `court-test`'s digests, a relocated run of each
ending, and the owner's play.
