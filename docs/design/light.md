# Design: M22 — Light: the lit model, lights, one shadow, HDR and the light-unit convention

**Status:** Proposed 2026-09-29; awaiting the owner's acceptance of §15. No step has begun.
**Date:** 2026-09-29
**Baseline:** `eaefd70`, tag `m21`. M0–M21 are complete.
**Decisions:**
- ADR-0048 (conventions: linear lighting, reversed-Z, −Z forward), ADR-0049 (engine shading
  models per backend, behind a registry), ADR-0052 (forward first, fixed passes), ADR-0053 (assets
  are not the renderer), ADR-0054 (fixed vertex slots) and ADR-0055 (imports compile to records)
  constrain this design.
- It proposes [ADR-0056](../adr/0056-photometric-light-units-and-pre-exposure.md): lights are in
  photometric units with glTF's punctual-light semantics, exposure is applied before the colour
  target is written, and one hue-preserving tone map writes the sRGB surface.

`render3d.md` is `render3d`'s document and `meshes.md` added M20's sections beside it. M22 spans
`rhi`, `asset`, `author`, `render3d`, `app` and the sample, so it writes its own document, as M20
did, and this is it.

## 1. Purpose and boundary

M22 is `3d.md` §10's fourth milestone:
- **Runnable result:** a lit room whose materials a content mod changes.
- **Exit condition:** a content-only mod changes how the room looks, with no code.
- **Regression coverage it adds:** material record validation; a readback of a lit reference
  scene, within a stated tolerance per backend; a mod override that changes a sampled pixel.

**What M22 builds:**
1. the light-unit convention, exposure and the tone map (§3, ADR-0056);
2. the RHI capabilities the passes need, on all three backends: sampled depth, comparison
   samplers, depth bias, depth-only passes, and a multisampled floating-point target that
   resolves and is sampled (§4);
3. `foundry:material`'s lit fields, and tangent streams in `asset.Mesh` (§5);
4. glTF import of those fields, of `TANGENT`, and of `KHR_materials_unlit` and
   `KHR_materials_emissive_strength` (§6);
5. in `render3d`: lights, the frame's HDR target and tone-map pass, `render3d` recording its own
   passes, and a CPU reference of the lighting maths (§7);
6. the lit shading model, with normal maps, occlusion and emission (§8);
7. one shadow map, for one directional light (§9);
8. `sandbox3d` lit, reading user mods, and a content mod that changes it (§10).

**What it does not build**, and whose it is:
- image-based lighting, a sky and cubemaps. Ambient light is one constant (§7.3). Their trigger
  is in §14;
- point-light and spot-light shadows, and cascades (`3d.md` §11);
- an engine light record or component. Lights are values a game submits each frame, as draws are
  (§7.1). A `foundry:light` record waits for glTF light import or the ABI (§14);
- `physics3d` (M23), skinned variants (M24) and anything in the public ABI (M25). **`render3d`
  still exposes nothing through the ABI**, and `abi` does not import it. `foundry:material`'s new
  fields are content schema, which a Tier 1 mod already writes and overrides, and that is M22's
  whole modding surface;
- tangent generation (MikkTSpace), bloom, auto-exposure, colour grading, and other post-process
  (§14).

## 2. What exists

- **`render3d.Renderer`** (`engine/src/render3d/renderer.zig`) is M19's frame and M20's
  materials:
  - one registered shading model, `foundry:shading.unlit`, whose `ShadingVariants` is a fixed
    `vertex: [4]` (UV0 × colour) and `fragment: [2]` (opaque-or-blend, mask);
  - one pipeline layout: group 0 is the frame (`view_projection`, visible to the vertex stage),
    group 1 is unused, and group 2 is the material (a uniform, one texture, one sampler). Inline
    constants carry the 64-byte world matrix, of the RHI's 128;
  - pipelines keyed by (model, vertex layout, alpha mode, cull), targeting the **surface format**,
    with `depth32_float`, `greater_equal`, clear 0;
  - `ensureTargets` makes a multisampled surface-format colour target and a depth target, and
    `passDesc` resolves the colour target into the surface;
  - `MaterialDesc` holds `shading`, `base_color`, `base_color_texture`, `alpha_mode`,
    `alpha_cutoff` and `double_sided`; `Stats` holds draws, triangles, pipeline binds, culled and
    blended.
- **`render3d.Content`** (`content.zig`) resolves `foundry:model` and `foundry:material` records
  by ID, follows reloads, and draws the magenta placeholder for a material that fails.
- **`app.Engine.renderScene`** (`engine/src/app/engine.zig`) opens one command buffer, calls the
  world's `plan`, `prepare`, `passDesc` and `record`, then an optional `render2d` overlay pass that
  loads the surface (`render3d.md` §7).
- **The RHI** (`engine/src/rhi/`) already has `rgba16_float` (Metal and Vulkan formats mapped),
  `depth32_float`, `CompareFunction`, `TextureUsage.sampled` and `.depth_stencil`, MSAA 1 and 4
  with resolve, and `max_inline_constant_bytes = 128`. It has **no** comparison sampler, **no**
  depth bias, and nothing yet samples a depth texture or draws a pass with no colour attachment,
  so none of those paths is proved on any backend.
- **`asset.Mesh`** (`engine/src/asset/mesh.zig`) validates position, normal (unit length), UV0,
  UV1 and colour. It refuses tangent, joints and weights by semantic.
- **`foundry:material`** (`engine/src/asset/schemas.zig`) is M20's six fields, version 1.
- **The glTF importer** (`engine/src/author/gltf/translate.zig`) imports `NORMAL`, warns that
  `TANGENT` "is omitted until M22", and warns once per material that "lit material fields are
  ignored until M22". Every generated material is written without `shading`, so it takes the
  schema default, unlit. `KHR_materials_unlit` is the one supported required extension.
- **`samples/sandbox3d`** draws the imported room, a grid of crates, M21's orrery of entities and
  a code-built cube, all unlit, with its `sandbox3d:config.main` record holding the clear colour
  and camera orbit. It discovers only its installed packages: unlike `samples/sandbox` and
  `samples/room`, it reads no user `mods/`.
- **`debug`'s `Sources.world3d`** shows `render3d.Stats` in the profiler (M21 Step 4).

## 3. Light units, exposure and the tone map (ADR-0056)

`3d.md` §6 left "physical or artistic" to this design, before any content depends on it. A light's
intensity is seen by every scene, every mod and every future import, so it is a compatibility
decision (CLAUDE.md §7).

**Lights are photometric, with glTF's `KHR_lights_punctual` semantics exactly:**

| Quantity | Unit | Typical values |
| --- | --- | --- |
| Directional light intensity | lux (lm/m²), illuminance at a surface facing the light | 100,000 noon sun; 400 office; 0.25 full moon |
| Point and spot light intensity | candela (lm/sr) | 60 W incandescent ≈ 70 cd; 1,700 lm spot ≈ 135 cd |
| Emission and ambient | cd/m² (nits), luminance | a lit phone screen ≈ 500 |
| Exposure | EV100 | 15 sunlit exterior; 8 bright interior; 0 moonlit |

- **Why photometric.** An artistic unitless intensity is a scale every author invents, and two
  mods lighting the same game would not agree on it. glTF defines lights in these units, so a
  later light import (§14) maps field for field, as the M20 importer maps materials.
- **Point and spot attenuation is glTF's:** inverse square, windowed by an optional `range` so a
  light reaches exactly zero at it, `clamp(1 − (d/range)⁴, 0, 1) / d²`. A range of 0 means
  unbounded. A spot's cone falls off smoothly between an inner and an outer angle, both in radians
  from the light's −Z (ADR-0048), as glTF's `innerConeAngle` and `outerConeAngle`.
- **Colour is a separate linear factor in [0, 1],** as glTF's is. Intensity carries magnitude.

**Exposure is applied before the target is written ("pre-exposure").** The lit shader multiplies
its result by `1 / (1.2 · 2^EV100)` (the standard photometric exposure for a saturation-based
sensor) before writing it. Two reasons:
- **fp16 range.** A sunlit specular highlight in raw cd/m² passes 65,504, `rgba16_float`'s largest
  finite value, and becomes infinity. Exposed first, the same highlight is a few units.
- **One tone map sees display-scaled values,** whatever the scene's absolute brightness.

**Unlit output and the clear colour are display-referred:** written as they are, not exposed. An
unlit material is what `KHR_materials_unlit` says it is — its colour goes to the screen — and an
unlit sign stays as readable at EV100 15 as at 0. `FrameView.exposure_ev100` defaults to `null`,
which means a scale of exactly 1, so a host that submits no light and names no exposure draws what
M20 drew, up to the tone map below.

**One tone map, Khronos PBR Neutral,** then the surface's hardware sRGB encode (ADR-0048's
"linear lighting, sRGB storage"). It is chosen because it is built to keep a material's authored
base colour: below its compression start (0.76) it only lowers every channel by a small toe, at most
0.04, and it compresses highlights toward white without the hue shift ACES gives saturated
colours. A mod that sets a material's colour sees that colour. There is one tone map, not an enum;
a second is additive when a game asks (§14).

- **Consequence, stated rather than hidden:** M19's and M20's readback expectations pass through
  the tone map from Step 3. Their tests are re-expressed through the CPU reference (§7.5), not
  loosened, and the Step 3 Resolution records every value that moved.

## 4. The RHI widens (`rhi`)

`3d.md` §4 named these for M22: "a depth-only shadow pass and a comparison sampler, and a
floating-point colour target for HDR." Each lands on the null, Metal and Vulkan backends in the
same step (§4's rule), with the null backend refusing its misuse.

### 4.1 Sampled depth

- **A `depth32_float` texture may be `.{ .depth_stencil = true, .sampled = true }`**, single-sampled
  only (rule 11 already refuses a sampled multisampled texture). It moves `depth_stencil →
  shader_read` through the existing state tracking.
- **Vulkan:** the view's aspect is depth (`aspectMask` already says so), and `shader_read` for a
  depth format is `VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL`, with the barrier's stages and
  access masks for depth. Metal needs no change beyond the usage flag.
- `depth32_float_stencil8` stays unsampleable: nothing needs it, and sampling it means choosing an
  aspect.

### 4.2 Comparison samplers

```zig
pub const SamplerDesc = struct { ..., compare: ?CompareFunction = null };
```

- **A comparison sampler is a sampler.** The binding type stays `.sampler`: Vulkan puts compare
  state in the `VkSampler` and Metal in the `MTLSamplerState`, and neither has a separate binding
  type for it. The shader declares a shadow sampler (`sampler2DShadow`, `depth2d` with
  `sample_compare`).
- **The null backend refuses a mismatch it can see:** a comparison sampler bound where the
  layout's entry was declared for a colour texture, or an ordinary sampler with a depth texture in
  the same group. `BindGroupLayoutEntry` gains `sampler: enum { filtering, comparison } = .filtering`
  and `texture: enum { color, depth } = .color` so the layout states which is which, as Vulkan's
  descriptor rules and Metal's argument types both require the shader to know.

### 4.3 Depth bias

```zig
pub const DepthStencilState = struct { ..., bias: DepthBias = .{} };
pub const DepthBias = struct { constant: f32 = 0, slope: f32 = 0, clamp: f32 = 0 };
```

- **Part of the pipeline,** because Vulkan's is (`depthBiasEnable`), and Metal's
  `setDepthBias:slopeScale:clamp:` is issued by the backend when that pipeline is bound. Non-finite
  values are `InvalidDescriptor`.
- **Reversed-Z flips its sign:** "further" is a smaller depth, so a shadow pass pushes depth away
  with a **negative** constant and slope. `render3d` owns the sign; the RHI passes the numbers.

### 4.4 Depth-only passes

- **A pass may have no colour attachment**, and a pipeline no colour target, if it has a depth
  attachment. Both APIs allow it (Vulkan 1.3's dynamic rendering, ADR-0037; Metal natively). The
  pipeline still names a fragment shader, because a masked caster must discard; an opaque caster's
  fragment program is empty. Making the fragment shader optional waits for a measurement that the
  empty program costs anything.

### 4.5 A floating-point target that resolves and is sampled

- **`rgba16_float`** as a 4× multisampled `render_target`, resolved into a single-sampled
  `render_target | sampled` texture, then sampled. Blending into it is required: blend materials
  draw there (§7.2). Every capability here is required of every Vulkan 1.3 device for this format,
  and of every Apple GPU, so no capability query is added; Step 1 confirms it on both.

### 4.6 What the RHI does not gain

Cubemaps (nothing samples one: §14), texture arrays and cascades (one shadow map), stencil, compute,
and MSAA depth resolve (the shadow map is single-sampled and the world's depth is discarded).

## 5. Materials and meshes (`asset`)

### 5.1 `foundry:material`, version 2

M20 fixed the rule: the lit model's fields are **appended, with defaults**, so every version 1
record still loads and draws as it did, and **a model ignores a field it does not read, and says so
once** (`meshes.md` §5.1). The field set is glTF 2.0's core metallic-roughness material, and one
Foundry field.

```fdt
foundry:material sandbox3d:materials.oak {
    shading                   foundry:shading.lit
    base_color                { r 1.0  g 0.94  b 0.86  a 1.0 }   # linear, multiplied in
    base_color_texture        sandbox3d:textures.oak              # sRGB
    metallic                  0.0                                  # [0, 1]
    roughness                 0.7                                  # [0, 1], perceptual
    metallic_roughness_texture sandbox3d:textures.oak_mr          # linear; G roughness, B metallic
    normal_texture            sandbox3d:textures.oak_normal       # linear; tangent space
    normal_scale              1.0                                  # finite
    occlusion_texture         sandbox3d:textures.oak_ao           # linear; R
    occlusion_strength        1.0                                  # [0, 1]
    emissive                  { r 0  g 0  b 0 }                    # linear, [0, 1]
    emissive_texture          sandbox3d:textures.oak_glow         # sRGB
    emissive_strength         1.0                                  # cd/m², ≥ 0
    casts_shadow              true
    alpha_mode                "opaque"
    alpha_cutoff              0.5
    double_sided              false
}
```

- **Every new field is a public name** (CLAUDE.md §7), and each is glTF's name in snake case,
  except `emissive` (glTF's `emissiveFactor`; the factor is implied, as `base_color`'s is) and
  `casts_shadow`.
- **Defaults: `metallic 0`, `roughness 1`**, a matte dielectric. glTF's defaults are 1 and 1, a
  rough metal, which is the wrong surprise for a hand-written record naming only a colour. The
  importer writes both explicitly with glTF's defaults applied (§6), so nothing imported depends
  on this choice.
- **Colour spaces are checked per slot:** `base_color_texture` and `emissive_texture` must be sRGB;
  `metallic_roughness_texture`, `normal_texture` and `occlusion_texture` must be linear. The wrong
  one is `WrongColorSpace`, as M20's base colour is, never reinterpreted.
- **`casts_shadow`** defaults to true. It applies to opaque and mask materials. A blend material
  never casts in M22 (a translucent shadow needs coloured or stochastic shadows), and one that says
  `true` is not an error: the field is unread, reported once.
- **The version** goes from 1 to 2, and version 1 extends to 2 with the new defaults, as the texture
  record's did (`schemas.zig`'s "versions 1 and 2 extend to version 3" test), so I8 holds for every
  compiled package that already exists.
- **`shading` still defaults to unlit.** Changing a default a published record relies on would
  relight every M20 package silently.

### 5.2 Tangent streams

- **`asset.Mesh` accepts `tangent` as `float32x4`:** `xyz` finite and unit length within the
  normal's 1e-3, `w` exactly +1 or −1 (glTF's bitangent sign). Anything else is refused by name.
- **No `.fmesh` version change.** The file already names semantics in slots (ADR-0054); M22 widens
  what `validate` accepts. An M21 engine reading a mesh with tangents refuses it as an unsupported
  stream, which is I8's graceful refusal, not undefined behaviour.

## 6. glTF import (`author`)

Every M20 rule stays; these change:
- **A material imports lit** (`shading foundry:shading.lit`) with every field of §5.1 that glTF
  has, and glTF's defaults (metallic 1, roughness 1) written explicitly when the file omits them. The
  "ignored until M22" warning goes.
- **`KHR_materials_unlit`** now selects `foundry:shading.unlit` and drops the lit fields, as its
  specification says. It stays supported when required.
- **`KHR_materials_emissive_strength`** becomes the second supported extension, mapping to
  `emissive_strength`.
- **`TANGENT`** is imported (`FLOAT VEC4`, validated as §5.2). The M20 warning goes.
- **Refused, each with its fix in the diagnostic:**
  - a lit material on a primitive with no `NORMAL` ("export normals, or mark the material
    `KHR_materials_unlit`");
  - a material with a `normalTexture` on a primitive with no `TANGENT` ("export tangents").
    glTF lets a client generate MikkTSpace tangents instead; that is deferred (§14);
  - any texture reference with `texCoord` other than 0, as M20 refuses for the base colour;
  - one image used as both an sRGB slot (base colour, emissive) and a linear one (normal,
    metallic-roughness, occlusion). A texture record has one colour space, and guessing which use
    is wrong would be silent.
- **Generated textures take their slot's colour space:** `color_space "linear"` for normal,
  metallic-roughness and occlusion images. An image shared by occlusion and metallic-roughness (the
  common packed "ORM" texture) is one linear record.
- **Determinism is unchanged:** the same bytes produce the same records on every host, and M20's
  cross-host comparison is repeated on Windows in Step 6.

## 7. `render3d`: lights, the HDR frame and the reference

### 7.1 Lights are submitted, not owned

```zig
pub const Light = struct {
    kind: enum { directional, point, spot },
    color: [3]f32 = .{ 1, 1, 1 },     // linear, [0, 1]
    intensity: f32,                    // lux (directional) or candela (point, spot)
    range: f32 = 0,                    // metres; 0 is unbounded (point, spot)
    inner_cone: f32 = 0,               // radians from −Z (spot)
    outer_cone: f32 = std.math.pi / 4, // radians from −Z (spot)
    casts_shadow: bool = false,        // directional only, one per frame
    world: Mat4,                       // position from translation, direction from −Z
};
pub fn addLight(self: *Renderer, light: Light) Error!void;   // between begin and plan
```

- **A light has a world matrix, as a draw does.** It points down its local −Z (ADR-0048), so a game
  places a light on an entity with `foundry:world_transform` exactly as it places a model, and
  `render3d` still sees no entity (`3d.md` §3).
- **Validated at the call,** and a refused light records nothing:
  - finite values; `color` in [0, 1]; `intensity ≥ 0`; `range ≥ 0`;
    `0 ≤ inner_cone < outer_cone ≤ π/2`; a world matrix whose −Z column is non-zero
    (`InvalidLight`);
  - at most `max_lights = 16` in a frame (`TooManyLights`). The count is a constant, not
    configuration, because it is compiled into every lit shader's uniform array;
  - at most one shadow-casting light, which must be directional (`InvalidShadowCaster`). Point and
    spot shadows are `3d.md` §11's.
- **Order is submission order,** and lights are summed in it, so the same submissions give the same
  image (I9's spirit, applied to rendering).
- **No light record in M22.** The values come from wherever the game keeps them; `sandbox3d` keeps
  them in its own config record, so a mod overrides them (§10). §14 says when an engine record is due.

### 7.2 `FrameView` and the frame uniform

```zig
pub const FrameView = struct {
    camera: Camera,
    target_size: Extent2D,
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },   // display-referred, linear
    exposure_ev100: ?f32 = null,             // null: a scale of exactly 1
    ambient: [3]f32 = .{ 0, 0, 0 },          // cd/m², uniform from every direction
    shadow_distance: f32 = 25,               // metres from the camera that the shadow covers
};
```

- **Group 0 grows** and becomes visible to the fragment stage too: binding 0 is the frame uniform
  (view-projection, camera position, exposure, ambient, light count, the shadow's matrix and
  parameters, and the 16 packed lights, about 1.2 KiB); binding 1 is the shadow map (a depth
  texture); binding 2 its comparison sampler. With no shadow caster, the shader skips the lookup
  by a flag in the uniform, and binding 1 holds a 1×1 depth texture so there is still one layout.
- **Group 1 stays unused.** It remains what `rhi.md` §9's order reserves for a pass.
- **Inline constants carry the world matrix and its cofactor matrix** (64 + 48 bytes, of 128).
  Normals transform by the inverse transpose (ADR-0048); the cofactor matrix is that times the
  determinant, which the shader's normalisation removes. It needs no inverse, so it is defined for a
  singular world and exact for shear and reflection, which M21 made real.

### 7.3 Ambient

One constant luminance from every direction, `FrameView.ambient`, scaled by the material's occlusion.
Without it every shadow is black, and a sky or image-based lighting is more than M22 needs (§14).
The lit model applies it to the diffuse colour and, through a split-sum approximation of glTF's
Fresnel term, to the specular colour, so a metal is not black in the shade.

### 7.4 The frame: `render3d` records its own passes

M19's `renderScene` asks the world for one pass (`passDesc`, `record`). M22's world is three:

1. **Shadow** (§9): depth-only, into the shadow map, if a light casts;
2. **World:** opaque and mask front to back, then blend back to front (ADR-0052's order, unchanged),
   into the `rgba16_float` target, 4× and resolved, or 1× directly. Depth as M19's;
3. **Tone map:** one full-screen triangle, drawn from `vertex_index` with no vertex buffer, reading
   the resolved HDR image and writing the surface. The surface leaves as `render_target` for the
   overlay, or `present`.

- **So the world recorder records its passes itself:**
  `recordFrame(cmd, frame, overlay: bool) Error!void`. `app.renderScene` calls it when the world
  type declares it and keeps M19's `passDesc`/`record` path otherwise, so a `render2d` world is
  untouched. The overlay pass stays `app`'s, loading the tone-mapped surface. `app` still names no
  renderer type.
- **Why not have `app` open three passes from three descriptors:** the shadow pass's existence, its
  size and the resolve are `render3d`'s decisions, and `app` would learn them to no end. A render
  graph remains unwanted until passes need reordering (`3d.md` §6).
- `passDesc` and `record` leave `render3d`'s public surface; its tests move to `recordFrame`.
- **Every pipeline targets `rgba16_float`**, the unlit model's included. Only the tone-map pipeline
  targets the surface format.
- **`Stats`** gains `lights`, `shadow_draws` and `shadow_culled`. The profiler's `Sources.world3d`
  shows them (Step 7).

### 7.5 The CPU reference (`render3d/lighting.zig`)

**The lighting maths is written once in Zig, as pure functions,** and the shaders are written to
match it:
- light packing into the uniform, and the uniform's layout (the tests pin its size and offsets);
- attenuation, the spot cone, the BRDF of §8, ambient, exposure and the tone map;
- the shadow's fit and texel snap (§9).

The packing is what `render3d` uploads, so it cannot drift from the uniform. The rest is the oracle
for every readback: a test computes the expected pixel from the same inputs and compares it with
the GPU's within §11's tolerance. A hand-picked expected colour, as M19's readbacks used, would say
nothing about a curve.

## 8. The lit shading model

`foundry:shading.lit`, registered by `Renderer.init` beside unlit, hand-written in MSL and in GLSL
compiled to SPIR-V (ADR-0049). Adding it adds no branch to the renderer (`meshes.md` §7.1).

**The BRDF is glTF 2.0's Appendix B,** so an imported material looks as its author's tools showed it:
- Lambertian diffuse, `base_color · (1 − metallic)`;
- GGX specular with the height-correlated Smith visibility term, and Schlick's Fresnel with
  `F0 = mix(0.04, base_color, metallic)`;
- `α = roughness²`, with roughness clamped to 0.045 in the shader (the record accepts [0, 1]) so a
  mirror's highlight does not collapse to a singularity;
- then occlusion on ambient only, emission added (`emissive · emissive_texture · emissive_strength`),
  and exposure.

**Inputs:**
- **Requires** position and normal. **Optional** UV0, colour and tangent. A material with a
  `normal_texture` on a mesh with no tangent is `MissingStream` at the draw, as a missing required
  stream is.
- **Group 2 widens for both models to one layout:** the uniform, five textures (base colour,
  metallic-roughness, normal, occlusion, emissive) and five samplers, each texture's own. An absent
  texture binds `render3d`'s white, or for the normal slot a flat `(0.5, 0.5, 1)` linear texture, so
  there is still one layout. Unlit reads slot 0 alone.

**Variants** (ADR-0049: few, and written):
- vertex: one per subset of {UV0, colour, tangent}, eight;
- fragment: {opaque-or-blend, mask} × {normal-mapped, not}, four.

`ShadingVariants` becomes two slices whose lengths the registration checks against the model's
optional set and feature set (`InvalidShadingModel`), replacing M20's fixed `[4]` and `[2]`. Whether a
variant is a separate function or one source compiled with a define is whichever the existing
`metalLibrary` and `vulkanShaderStage` steps support; no tool is added.

**Unlit is unchanged** apart from its target format and the one layout: it reads no light and is not
exposed (§3).

## 9. One shadow map

- **One directional light casts,** into one `depth32_float` map of `Config.shadow_size` texels a side:
  0 (no shadows), 1024, **2048 by default**, or 4096. Anything else is `InvalidConfig`.
- **The fit:** the smallest sphere around the camera frustum between `near` and
  `min(far, shadow_distance)`, which is the same size whatever way the camera turns, seen through an
  orthographic projection down the light's −Z. Its centre is **snapped to whole shadow texels** in
  light space, so a moving camera does not make shadow edges crawl. The depth range spans the sphere
  and extends toward the light to the furthest caster whose bounds reach it, so something above the
  view still casts into it.
- **Reversed-Z here too:** the map clears to 0 and tests `greater_equal`, one convention in both
  passes (ADR-0048).
- **Casters** are the frame's opaque and mask draws whose material casts, culled against the light's
  box by M20's frustum code. Mask casters discard below their cutoff, so a leaf's shadow has holes.
  A caster keeps its material's cull mode and mirroring.
- **Bias, three ways, each needed:** a constant and a slope-scaled depth bias in the shadow pipeline
  (§4.3), and a normal offset of about one and a half texels in the lit shader's lookup. Their values
  are `Config` fields with documented defaults, validated finite, because the right numbers depend on
  scene scale; they are not content.
- **Filtering:** a 3×3 grid of hardware-bilinear comparison taps, a smooth 4×4-texel footprint.
- **Receivers** are lit materials. Unlit ones ignore light, and so shadow.

## 10. `sandbox3d`: a lit room a content mod changes

- **The room, crates and orrery are lit.** Their glTF materials re-import as lit (§6); the code-built
  cube gains normals and a lit material made in code, so the code path and the content path again
  draw the same way. The glass stays blend.
- **Its lights are content:** `sandbox3d:config.main` gains `exposure_ev100`, `ambient`, and a list
  of lights (kind, colour, intensity, range, cones, pose), in the sample's own schema. One
  directional light casts through the window, with point lights inside. Their exact values are Step
  7's, chosen for a readable picture.
- **It reads user `mods/`,** as `samples/sandbox` does: the installed root and the player's are two
  host-granted roots, and `FOUNDRY_SANDBOX3D_PACKAGES` names the packages to add (`content-mods.md`
  §2). That is the whole code change the exit condition allows, and it is a host's, not the mod's.
- **The mod** is a content package in `samples/sandbox3d/testdata/mods/dusk/`, compiled by `fpack`
  like any other: it overrides the room's floor and wall materials (roughness, a colour, an emissive
  panel) and the config's lights and exposure, to make the same room at dusk. It contains no code. A
  player copies `dusk.fpk` into `mods/` and names it; nothing is rebuilt.
- **Switches, as `--cull=off` is:** `--shadows=off` sets `shadow_size = 0`, to measure what the shadow
  pass costs. Neither is a game setting.
- **The overlay's profiler** shows lights, shadow draws and shadow culls.

## 11. Verification

**Headless (null backend), in `zig build test`:**
- **Material records:** version 1 extends to version 2 with every default; every new field refused
  out of range or non-finite, by name; each texture slot refused in the wrong colour space; a
  material naming an unregistered model refused at resolution; an unlit material with lit fields
  loads, and reports once.
- **Meshes:** tangent streams accepted exactly as §5.2 says, and refused otherwise.
- **Import:** fixtures for every mapped field and both extensions; each refusal in §6 with its fix;
  generated colour spaces; the ORM texture as one record; `KHR_materials_unlit` still unlit.
- **Lights:** every refusal in §7.1, each leaving the frame unchanged; seventeen lights refused; two
  casters refused; packing pinned by size and offset.
- **The reference:** attenuation reaches exactly 0 at `range`; the cone at its two angles; energy of
  the BRDF against published values at known angles; exposure's scale at EV100 0 and 15; the tone map
  against Khronos's reference values; the shadow fit's sphere invariant under camera rotation, and
  its snap moving only by whole texels under translation.
- **The RHI:** each §4 capability's misuse refused by the null backend (sampled multisampled depth, a
  comparison sampler for a colour texture, a colour-less pass with no depth, non-finite bias); the
  frame's three passes in order, with the states each texture leaves in.
- **The registry:** variant-table lengths checked at registration; the lit model registered; a
  normal-mapped material on a tangent-less mesh refused at the draw.

**Readbacks (Metal on the Mac, Vulkan on the PC), against `lighting.zig`:**
- **A lit reference scene:** a plane and a box under one directional and one point light, three
  materials (a dielectric, a metal, an emissive), read at chosen pixels away from edges. **Tolerance:
  ±2/255 per channel on Metal, ±3/255 on Vulkan**, after the tone map and sRGB encode. Anything wider
  is a finding, not a new tolerance.
- **A shadow:** a pixel deep in an occluder's shadow reads ambient only, one well outside reads fully
  lit, and moving the occluder moves which is which. Penumbra pixels are not compared.
- **Unlit through HDR:** M19's and M20's readbacks, re-expressed through the tone map (§3).
- **The mod:** an integration test builds a base package with a lit material and a content mod that
  overrides it, with the package compiler; resolves the order through `mod`; draws a quad through
  `render3d.Content`; and reads one pixel. The base alone matches the reference, and the mod changes
  that pixel by the reference's amount. This is `3d.md` §10's "a mod override that changes a sampled
  pixel".

**Runs:** `sandbox3d` from relocated ReleaseSafe installs on macOS/Metal and Windows/Vulkan, with and
without `dusk`, with and without shadows, at 1× and 4×, captured, resized, minimised and restored,
exit 0; Vulkan validation logs no errors or warnings; frame pacing held at 60 Hz, with the shadow
pass's cost recorded from `--shadows=off`.

## 12. Platform assessment

- **Metal (macOS):** every §4 capability is native. Metal's depth bias is encoder state, which the
  backend sets when a pipeline binds.
- **Vulkan (Windows):** the risks are the depth layout transitions, comparison-sampler descriptors
  and fp16 MSAA resolve. Validation layers and the readbacks are the proof, in Step 6 on the PC.
- **Linux: compile only.** Every capability used is core, required Vulkan 1.3 behaviour on the same
  backend that Windows proves, and M22 changes no window, surface, swapchain or presentation code
  (`3d.md` §10.2's triggers). The one driver-dependent quantity is filtered shadow comparison, whose
  precision may differ on Mesa; the readbacks compare no penumbra pixel, so a difference there
  cannot change a result. The close confirms the assessment held.

## 13. Implementation order — eight bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There is
no automatic chaining.

### Step 1 — `rhi`: sampled depth, comparison samplers, depth bias, depth-only passes, fp16 targets
§4 on null, Metal and Vulkan: the descriptor fields, the layout entry kinds, the null backend's
refusals, the backends' implementations, and a Metal readback test of each (a depth-only pass read
back through a comparison sampler; an fp16 4× target resolved and sampled). Vulkan compiles and
passes the null-equivalent checks here; it runs in Step 6.
**Exit:** every §4 capability is refused when misused on the null backend and read back correctly on
Metal.

### Step 2 — `asset` and `author`: material version 2, tangents, lit import
§5 and §6: the schema, its version extension, tangent validation, and the importer's lit fields,
extensions, colour spaces and refusals, with fixtures.
**Exit:** a glTF file with every metallic-roughness field and tangents imports into version 2
records and a tangent stream, and each §6 refusal names its fix.

### Step 3 — `render3d`: lights, the HDR frame and `recordFrame`
§7: `Light`, `addLight` and its refusals, `FrameView`'s fields, the uniform and its packing,
`lighting.zig`, the `rgba16_float` target and tone-map pass, `recordFrame` and `app.renderScene`'s
use of it. Unlit only still: the lit model is Step 4's. M19's and M20's readbacks pass through the
tone map.
**Exit:** `sandbox3d` draws as before through the HDR target and tone map, and every unlit readback
matches `lighting.zig`'s tone map within tolerance on Metal.

### Step 4 — `render3d`: the lit model
§8: the registry's variant tables, the five-texture material layout, the lit model's MSL and GLSL,
`MaterialDesc`'s fields and their validation, `Content`'s resolution of version 2 records.
**Exit:** the lit reference scene reads back within ±2/255 of `lighting.zig` on Metal.

### Step 5 — `render3d`: the shadow
§9: `Config.shadow_size` and bias fields, the fit and snap, caster selection and culling, the
shadow pipelines, the lookup and filter.
**Exit:** the shadow readbacks hold on Metal, and `sandbox3d` shows a stable shadow while the camera
orbits.

### Step 6 — Vulkan, proved on Windows
Every readback of Steps 1, 3, 4 and 5 on the PC, within ±3/255, the whole `-Drhi=vulkan` test graph,
validation clean, and the importer's output compared byte for byte with the Mac's.
**Exit:** the lit reference scene, the shadow and the unlit readbacks pass on Windows/Vulkan with no
validation message.

### Step 7 — `sandbox3d` lit, and the dusk mod
§10: lit content, lights and exposure from the config, the user mods root and
`FOUNDRY_SANDBOX3D_PACKAGES`, `--shadows=off`, the `dusk` mod, the overlay's new stats, and §11's
mod-pixel integration test. Runs and captures on both platforms.
**Exit:** from a relocated install on macOS/Metal and Windows/Vulkan, adding `dusk.fpk` to `mods/`
makes the same room visibly dusk, with no rebuild and no code in the mod.

### Step 8 — Close M22
Resolve the discrepancies this design makes in its parents:
- `3d.md` §6's pass list gains the tone map between transparent and overlay, and its lighting
  paragraph names ADR-0056's units; §4's "whatever M22's passes use" becomes what they used;
- `meshes.md` §5.1's appended fields and §6.5's "omitted until M22" and "ignored until M22";
- `render3d.md` §7's world recorder (`recordFrame` beside `passDesc`/`record`);
- `rhi.md` §12 and §11's rules for sampled depth, comparison samplers and depth-only passes;
- `debug-overlay.md` §7.5's `Sources.world3d` counts.

Move ADR-0056 to Accepted and into CLAUDE.md §4.1, update §9's 3D row, `AGENTS.md`'s bar if a step
changed it, the roadmap, the design index and `PROJECT_STATE.md`; confirm the Linux assessment; pack
up the PC; tag `m22`, push when asked, and stop before M23's design.

## 14. What stays open, deliberately

- **Image-based lighting, a sky and cubemaps:** when a scene's constant ambient is measurably wrong
  for a game — metals reflecting nothing in an outdoor scene is the likely first — or M26's sample
  needs a sky. Cubemaps enter the RHI then.
- **Point and spot shadows, cascades:** `3d.md` §11; the trigger is a scene whose single map shows
  measured aliasing at `shadow_distance` a game needs.
- **An engine `foundry:light` record, and glTF light import (`KHR_lights_punctual`):** when an
  imported scene carries lights someone wants, or M25 publishes lights through the ABI, whichever is
  first. ADR-0056's units make the import a field-for-field copy.
- **MikkTSpace tangent generation:** when a real asset with a normal map cannot be exported with
  tangents. It is a dependency decision (zlib-licensed reference) or a port.
- **A second tone map, auto-exposure, bloom, colour grading:** when a game asks. A tone-map choice
  is additive (an enum with Neutral as its default).
- **More than 16 lights, or per-draw light lists:** when a scene needs more; that is also the first
  measurement ADR-0052 says would reconsider forward shading.
- **Making the fragment shader optional in a depth-only pipeline:** when the empty program is
  measured to cost anything.
- **Translucent shadows:** when a game needs glass to cast coloured light.

## 15. Decisions acceptance fixes

Each is recommended as written.

| # | Choice | Where |
| --- | --- | --- |
| 1 | Photometric light units with glTF's punctual semantics: lux, candela, cd/m², EV100 exposure (ADR-0056) | §3 |
| 2 | Pre-exposure in the lit shader; unlit output and the clear colour are display-referred and not exposed; `exposure_ev100 = null` is a scale of 1 (ADR-0056) | §3 |
| 3 | One tone map, Khronos PBR Neutral, before the surface's sRGB encode; M19's and M20's readbacks are re-expressed through it (ADR-0056) | §3 |
| 4 | The RHI gains sampled depth, comparison samplers (`SamplerDesc.compare`, layout entry kinds), pipeline depth bias, colour-less depth passes, and fp16 4× targets resolved and sampled; no cubemaps | §4 |
| 5 | `foundry:material` version 2: glTF's metallic-roughness fields in snake case, plus `casts_shadow`; defaults metallic 0, roughness 1; per-slot colour spaces; `shading` still defaults to unlit | §5.1 |
| 6 | Tangents accepted as `float32x4` unit `xyz` with `w = ±1`, with no `.fmesh` version change | §5.2 |
| 7 | glTF materials import lit; `KHR_materials_unlit` selects unlit; `KHR_materials_emissive_strength` supported; `TANGENT` imported; lit-without-`NORMAL`, normal-map-without-`TANGENT`, and one image in both colour spaces refused; no tangent generation | §6 |
| 8 | Lights are values submitted each frame with a world matrix pointing down −Z; at most 16, one shadow caster and only directional; no engine light record in M22 | §7.1 |
| 9 | A constant ambient luminance; no IBL or sky | §7.3 |
| 10 | `render3d` records its own three passes through `recordFrame`, which `app.renderScene` prefers; the overlay stays `app`'s; `passDesc`/`record` leave `render3d`'s surface | §7.4 |
| 11 | The lighting maths is a Zig reference (`lighting.zig`) that packs the uniform and is the oracle for every readback | §7.5 |
| 12 | glTF Appendix B's BRDF; roughness clamped to 0.045 in the shader; normals by the cofactor matrix in inline constants | §7.2, §8 |
| 13 | One five-texture material layout for both models; 8 vertex and 4 fragment lit variants; the variant table becomes checked slices | §8 |
| 14 | One 2048² directional shadow: a sphere fit snapped to texels, reversed-Z, constant, slope and normal-offset bias as `Config`, 3×3 bilinear PCF; blend never casts | §9 |
| 15 | `sandbox3d` reads user `mods/` and `FOUNDRY_SANDBOX3D_PACKAGES`; its lights live in its own config; the `dusk` mod is test data compiled by `fpack` | §10 |
| 16 | Readback tolerances of ±2/255 on Metal and ±3/255 on Vulkan against the reference, no penumbra pixel compared | §11 |
| 17 | Linux is compile only, confirmed at the close | §12 |
| 18 | Eight steps, Metal before Vulkan-on-Windows, the sample last | §13 |

Once these are accepted nothing blocks Step 1: the RHI's widening depends only on the code as it is.
