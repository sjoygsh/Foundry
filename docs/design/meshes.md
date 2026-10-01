# Design: M20 — Meshes: runtime formats, glTF import, textures with mips, materials and culling

**Status:** Accepted 2026-09-27 when the owner requested Step 1. **Complete 2026-09-29, tag
`m20`**: all nine steps are walked, and Step 9's Resolution closes it. §14 records the accepted choices.
**Date:** 2026-09-27
**Baseline:** `a8cbd64`, tag `m19`. M0–M19 are complete.
**Decisions:**
- ADR-0048 (conventions), ADR-0049 (shading models), ADR-0052 (forward first), ADR-0053
  (assets are not the renderer) and ADR-0054 (fixed vertex slots) constrain this design.
- It proposes [ADR-0055](../adr/0055-imported-models-compile-to-foundry-records.md): an import
  is an authoring form of a model, compiled away, and what it generates has derived content IDs.
- ADR-0050 (the hierarchy) is M21's. Nothing here creates an entity.

`render3d.md` is `render3d`'s document, and M19 wrote its first sections. M20 spans `asset`,
`author` and `render3d`, so it writes its own document, as `render3d.md`'s preamble allows, and
this is it. `render3d.md` links here.

## 1. Purpose and boundary

M20 is `3d.md` §10's second milestone:
- **Runnable result:** a glTF-authored scene from a content package, drawn textured, relocated
  and hot-reloaded.
- **Exit condition:** a glTF file is imported into Foundry's representations, and nothing
  downstream of the compiler knows it was glTF. A malformed file is refused with a diagnostic.

**What M20 builds:**
1. the runtime mesh file, `.fmesh`, and the widened stream table (§3);
2. the texture record's colour space and mip chains, generated on the CPU at load (§4);
3. `foundry:material` and `foundry:model`, the records for rows 4 and 5 (§5);
4. glTF 2.0 import in `author`'s compiler, and the build-only import record (§6);
5. in `render3d`: the shading-model registry and its unlit entry, materials, the three alpha
   modes, mirrored draws, frustum culling, and models drawn by content ID (§7 and §8);
6. `sandbox3d`'s glTF scene (§9).

**What it does not build**, and whose it is:
- entities, `foundry:transform` and the hierarchy (M21). A model is drawn at a matrix the game
  gives it;
- light, normals in a shader, tangents, and every PBR parameter (M22). Normals are imported now,
  so that M22 does not require a re-import;
- skins, joints, weights and clips (M24);
- anything in the public ABI (M25). **`render3d` still exposes nothing through the ABI**, and
  `abi` does not import it. `foundry:mesh`, `foundry:material` and `foundry:model` are content
  schemas, which a Tier 1 mod can already write and override, and that is M20's whole modding
  surface;
- compressed texture formats, LOD, streaming, occlusion culling and instancing (`3d.md` §11).

## 2. What exists

- **`asset.Mesh`** (`render3d.md` §5) is a validated, borrowed view: streams by semantic,
  indices, submeshes and bounds. Its format table allows only position (`float32x3`) and colour
  (`unorm8x4`). Nothing reads or writes it from a file.
- **`foundry:texture`** is schema version 2: `source`, `filter` (`nearest`, `linear`) and `wrap`
  (`clamp`, `repeat`). `render2d` registers its only loader, which decodes the PNG into
  `rgba8_unorm_srgb` with one mip level. `asset.Image` documents itself as always sRGB.
- **The registry** takes one loader per schema (`LoaderExists` otherwise). A loader is handed a
  record and its `source` bytes. **The game registers the loaders**; `app` registers none but
  the tile grid's. Every asset kind has `source` at field zero. A record without one, such as a
  `foundry:ui_theme`, is read from the store and is not a registry asset.
- **The compiler is `author`'s** (`author/compiler.zig`, ADR-0042), and `fpack` is one host of
  it. It already compiles one authoring format into a runtime asset: a `.grid` becomes an
  `.fgrid` under `--assets-out`, and derivation then mints its record. Records it derives are
  written as `.fdt` text and go through the same parser and checker as authored ones.
- **The RHI has most of what mips need.** `TextureDesc.mip_levels`, a per-level
  `copyBufferToTexture`, `SamplerDesc.mip_filter`, and rule 10's bound on a copy's level exist
  on all three backends. Vulkan creates views over every level and samples with an unclamped
  LOD. **No test has ever sampled a mip chain and checked which level was read.**
- **`render3d`** draws one pipeline, unlit vertex colour, with `MeshDraw { mesh, submesh, world }`
  and no material. It sorts opaque draws front to back, and culls nothing. M19 recorded that M20
  adds `material` to `MeshDraw` as a required field.
- **`core.Transform`** composes `T · R · S`, and nothing decomposes a matrix back into one.
  `3d.md` §7.1 specifies that decomposition, with its tolerance, for M21's keep-world re-parent.

## 3. The runtime mesh file (`asset`)

**M24 Step 2, 2026-10-01:** the reader also accepts skinned `.fmesh` v2, adding byte-valued
joint streams, float weights and validated model bind-space joint bounds. Unskinned writers
still emit identical v1 bytes; the layout below remains v1's. The v2 layout and named refusals
are recorded in [`animation3d.md` §6 and Step 2's Resolution](animation3d.md#6-assets-fskel-fanim-fmesh-version-2-and-the-model-record).

`asset/mesh_file.zig` holds `.fmesh`, row 3 on disk. Its reader produces the same `asset.Mesh`
that code builds, so `render3d` uploads both by one path (`3d.md` §3).

```
offset  field              type
0       magic              [4]u8   "FMSH"
4       format_version     u32     1
8       vertex_count       u32
12      index_format       u8      0 = uint16, 1 = uint32
13      stream_count       u8      1–8
14      reserved           u16     0
16      index_count        u32
20      submesh_count      u32
24      bounds             6 × f32 min xyz, max xyz
48      streams            stream_count × { semantic u8, format u8, reserved u16, offset u32, length u32 }
..      submeshes          submesh_count × { first_index u32, index_count u32 }
..      payload            the index bytes, then each stream's bytes, at their offsets
```

- **Little-endian throughout.** Every Foundry target is little-endian, and the reader refuses to
  compile for one that is not, rather than byte-swapping a payload the GPU reads directly.
- **The version is a field, not part of the magic**, as `.fpk`, `.fsav` and `.fgrid` keep it. A
  mesh from a newer Foundry reports "format version 2, this build reads 1"
  (`UnsupportedVersion`), and a file that was never a mesh reports `NotAMesh` (I8).
- **One canonical layout.** Streams are listed in semantic order. Every offset is a multiple of
  4, and the payloads neither overlap nor leave gaps. Reserved bytes are zero, and the file ends
  where the last payload does. The reader refuses anything else as `Malformed`. So a writer has
  one output for one mesh, and `write(read(b))` is `b` byte for byte.
- **The reader returns a view of the bytes it was given**, and then runs `Mesh.validate`. A
  header that lies about a count is refused before any payload is touched. `Limits` bound the
  file (256 MiB by default), the vertex count (16,777,216) and the submesh count (65,536), and
  every product is computed with overflow checks.
- **Stored bounds are checked, never recomputed in place of the check** (`render3d.md` §5).

**The stream table widens** (ADR-0054: it widens only in the milestone that first reads a
slot). M20 reads UVs, and it imports normals so that M22 does not need a re-import:

| Semantic | Formats | Checked by `validate` |
| --- | --- | --- |
| position | `float32x3` | finite; inside the bounds |
| normal | `float32x3` | finite; unit length within `1 ± 1e-3`, as glTF requires |
| uv0, uv1 | `float32x2` | finite |
| colour | `unorm8x4`, `float32x4` | linear; a float component is finite and in [0, 1] |
| tangent | — | refused until M22 |
| joints, weights | — | refused until M24 |

`asset.MeshVertexFormat` gains `float32x2` and `float32x4`, which `render3d` maps to the RHI's
existing formats. Each new refusal has a named error: `InvalidNormal` and `InvalidColor`.

**`foundry:mesh`** is the record: `source` alone, version 1, with the extension `fmesh`. It is
the shape `foundry:tilegrid` has. A `.fmesh` can be written by any tool, which is how a second
importer would reach the same row (`3d.md` §3).

## 4. Textures: colour space and mip chains

### 4.1 The record

`foundry:texture` becomes version 3. Both fields are appended with defaults, so version 1 and 2
content loads unchanged (I8):
- **`color_space`**: `"srgb"` (the default, and what every existing texture is) or `"linear"`.
  A colour texture is sRGB. A normal map, a mask or a roughness texture is linear (ADR-0048). It
  selects `rgba8_unorm_srgb` or `rgba8_unorm`.
- **`mipmaps`**: `bool`, default `false`. It is off by default, because a 2D sprite drawn at
  its own size gains nothing from a chain but a third more memory.
- **`wrap`** gains `"mirror"`, for glTF's `MIRRORED_REPEAT`. `filter` is unchanged. With
  `mipmaps true`, the mip filter follows `filter`.

`asset.Image` keeps its bytes. What changes is its documentation: it says what the bytes are,
and the record says what they mean. An unknown spelling stays a warning that names the legal
set, as `filter` and `wrap` already are.

### 4.2 The chain is generated on the CPU, at load

`asset/mips.zig` builds a chain from a decoded image. This is a pure function of the pixels and
the colour space:
- **Each level is a 2×2 box filter of the one above.** An odd dimension takes the last row or
  column once more. Levels halve down to 1×1, as `Extent2D.mipLevel` already defines.
- **sRGB is filtered in linear light.** Each sample is decoded through an exact 256-entry table,
  averaged in `f32`, and encoded with round-to-nearest. Averaging the encoded bytes darkens every
  level, visibly.
- **Colour is weighted by alpha.** A transparent texel's colour does not bleed into its opaque
  neighbours, which is the halo alpha-tested foliage otherwise gets. Alpha itself is a plain
  average.
- **It is deterministic** (I9). There is no fast-math, and the order is fixed. The same image
  gives the same bytes on every host, and a test pins a hash.

**Why at load and not in `fpack`, which `3d.md` §4 said.** Generating at build time needs a
runtime texture format beside PNG, with its own version, reader, writer and refusal tests. It
would also be a second representation of every texture, or a split in which some textures are
PNG and some are not. At load, the chain costs one pass over a third more pixels than the image
has. For a 2048² texture that is about 5.6 million texels, a few milliseconds. PNG stays the one
texture format, and its decoder is already hardened. **The trigger to move it to build time is
a measured load time,** and that is the same trigger as compressed GPU formats (`3d.md` §3),
which need a build-time format anyway. When that trigger fires, both move together. §14 asks
the owner to accept this correction.

### 4.3 Both renderers honour the record

- **`render2d`'s loader** reads `color_space` and `mipmaps`. It uploads every level and gives
  its sampler the mip filter. A 2D texture is unchanged unless its record asks.
- **`render3d`'s loader** (§7.4) reads the same fields and makes its own texture.
- **The RHI does not widen for mips.** M20 proves what it already has, on Metal and on
  Windows/Vulkan (§11). A texture whose levels are each a different solid colour is drawn
  minified to known sizes, and the readback shows which level the sampler read. A view of a
  level range, which `3d.md` §4 listed, has no consumer, and waits for one.

## 5. Materials and models: rows 4 and 5, as content

Both are records in `asset/schemas.zig`, where `fpack` checks them without linking a renderer,
for `foundry:ui_theme`'s reason. **Neither is a registry asset:** neither has bytes of its own,
so neither has a `source`. `render3d` reads them from the store (§8). **Every field name below
is a public name** (CLAUDE.md §7), and a Tier 1 mod writes and overrides them in M20.

### 5.1 `foundry:material`

```fdt
foundry:material sandbox3d:materials.oak {
    shading            foundry:shading.unlit
    base_color         { r 1.0  g 0.94  b 0.86  a 1.0 }    # linear, multiplied in
    base_color_texture sandbox3d:textures.oak               # optional; must be sRGB
    alpha_mode         "opaque"                             # "opaque" | "mask" | "blend"
    alpha_cutoff       0.5                                  # read by "mask" only
    double_sided       false
}
```

- **`shading` names a shading model's content ID** (ADR-0049), never shader code. The engine
  registers `foundry:shading.unlit` in M20, and `foundry:shading.lit` in M22. A material naming
  a model that is not registered is refused when it is resolved (§8), not at compile time,
  because shading models are runtime registrations (I6) and not records.
- **A fixed field set, not a list of named parameters.** The closed type list has no variant
  type (`content-schemas.md` §3), and a generic `{ name, value }` list can only be checked once a
  renderer has loaded. A fixed set is checked by `fpack`, and it is glTF's own material model,
  so the importer maps it field for field. M22 appends the lit model's fields (metallic,
  roughness, normal, occlusion and emissive) with defaults, as implemented in version 2 below. **A model
  ignores a field it does not read, and says so once**: an unlit material with a roughness is not
  an error, and its record still loads on an engine that draws it lit. A generic parameter list
  waits for content-owned shading models (ADR-0015's trigger), and it is additive then.
- **`base_color` is linear**, as glTF's `baseColorFactor` is, and as every colour the renderer
  takes is. The unlit model draws `base_color × texture × vertex colour`, where an absent texture
  or colour stream contributes 1.
- **The texture must be sRGB.** A linear texture named here is refused, not reinterpreted.

**M22, 2026-09-30:** version 2 appends `metallic` (default 0), `roughness` (1),
`metallic_roughness_texture`, `normal_texture`, `normal_scale` (1), `occlusion_texture`,
`occlusion_strength` (1), `emissive` (black), `emissive_texture`, `emissive_strength` (1 cd/m²),
and `casts_shadow` (true). Optional texture IDs default absent; version 1 extends with these
defaults and still names unlit by default. The full field set, ranges and per-slot colour
spaces are authoritative in `light.md` §5.1. Base colour and emission textures are sRGB;
metallic/roughness, normal and occlusion are linear. Unread non-default fields report once,
not on every reload. Opaque/mask materials may cast; blend never does.

### 5.2 `foundry:model`

**M24 Step 2, 2026-10-01:** model v2 appends optional `skeleton` and `clips [{ name, clip }]`.
Compiled model-v1 records retain their own schema/layout and still load unchanged. Skin
residency and model/clip pairing are M24 Step 5, not part of the asset-format step.

```fdt
foundry:model sandbox3d:models.table {
    slots [ { name "oak"    material sandbox3d:materials.oak }
            { name "metal"  material sandbox3d:models.table.material1 } ]
    parts [ { mesh sandbox3d:models.table.mesh0  submesh 0  slot 0
              translation { x 0 y 0.74 z 0 }
              rotation    { x 0 y 0 z 0 w 1 }
              scale       { x 1 y 1 z 1 } }
            ... ]
}
```

- **A model is a flat list of parts, not a hierarchy** (`3d.md` §3). A part is one submesh of
  one mesh, drawn with one slot's material, at a transform relative to the model's origin.
- **Slots are indirection for materials.** An instance may override a slot (§8), and a mod
  overrides the model record to change a default. A slot's `name` is for people and tools; the
  index is what a part and an override use.
- **A part's transform is a TRS,** validated as `Transform.isValid` validates one, with the
  rotation accepted through `Quat.validated` (`render3d.md` §3). This keeps a model record
  hand-writable, and consistent with the pose M21 authors. A sheared placement therefore cannot
  be written, and the importer refuses one (§6.4) rather than approximating it.
- **Bounds are not stored.** A model's bounds are the union of its parts', derived from each
  mesh's bounds when the model is resolved. A stored copy would be a second fact that could
  disagree.

## 6. glTF import (`author`)

### 6.1 Where it lives

**M24 Step 3, 2026-10-01:** [`animation3d.md` §7](animation3d.md#7-import-gltf-skins-and-animations-author)
extends this importer with `skin.zig`, typed skins/animations, hierarchy closure, remapping
and diagnostics. It emits `.fskel`/`.fanim` and skinned `.fmesh` v2; the historical static
import rules below remain unchanged. Skinned parts are identity and `front` goes into the
skeleton root once, rather than onto those parts. Omitted inverse binds are identity.

**In `author`'s compiler, which `fpack` hosts** (ADR-0042). `3d.md` says "`fpack`'s glTF
import", and that was true of the tool's name, not of the module. There is one package
compiler, and the editor builds through it too, so an import is the same in both hosts, by
construction. `author` has `core`, `data`, `platform`, `asset`, `mod` and `scene`, and neither
`rhi` nor any renderer. That is exactly row 2's boundary: import knows nothing of the runtime
or the GPU.

`author/gltf/` is the only code in Foundry that reads glTF (ADR-0053):
- `container.zig`: `.glb`'s chunks, or `.gltf` with its external buffers and images;
- `document.zig`: the JSON, read into typed, bounded structures. This is the one place
  `std.json` is used, so a `std` change touches one file;
- `accessor.zig`: typed, range-checked access to buffer data;
- `translate.zig`: glTF to rows 3–5.

Nothing in `author/gltf/` is exported past `author`. What leaves it is `.fmesh` bytes, PNG
bytes and `.fdt` text; M23 Step 3 also adds opt-in `.fcol` collision bytes (ADR-0057).

### 6.2 What an author writes

**Nothing, for the default.** A `.gltf` or `.glb` file in a package is an authoring format, like
`.grid`. `models/table.glb` derives the model `sandbox3d:models.table` by `assets.md` §3's rule,
and imports with every default.

**An import record, when a default is wrong** (ADR-0055):

```fdt
foundry:model_import sandbox3d:models.table {
    source    "models/table.glb"
    front     "+z"                                   # default "-z"
    materials [ { name "Oak"  material sandbox3d:materials.oak } ]
}
```

- **It is the model's authoring form, and it is compiled away.** The compiler replaces it with
  the `foundry:model` of the same ID, and the import record never reaches the `.fpk`. This is
  ADR-0006's two representations applied to a model. Its schema is registered like any other,
  so the checker, the editor's forms and a mod author's diagnostics all see it.
- **`front`** is `3d.md` §2's rule. `"-z"` keeps the authored coordinates, which is what level
  geometry needs. `"+z"` says that the model's front faces +Z, as glTF's authoring convention
  has it, and the importer composes a half-turn about +Y onto every part's transform. The meshes
  are unchanged, and a mesh shared with another model is not turned twice.
- **`materials`** maps a glTF material, by its name, to an existing `foundry:material`. A mapped
  material generates no record, and a slot using it names the mapped ID. This is how two models
  share one oak, and how a material gets an ID a person chose. A mapping that names no material
  in the file is an error: a stale mapping is a silent default otherwise.
- **An authored record wins over derivation**, as it does for every asset (`assets.md` §3).
- **Import schema v2's `collision` and `collision_exclude`** (M23 Step 3, ADR-0057) are
  additive: `collision` defaults to `false`, and exclusions default to an empty list. v1
  records and bare glTF derive no collision. Enabling it derives one `<model>.collision`
  in model space; exclusions name every matching glTF node and its subtree, and a name
  matching nothing is refused. Degenerates produce a counted warning; an empty result is
  refused. See [`collision3d.md` §8–§9](collision3d.md#8-the-collision-mesh-asset-asset)
  for the format and derivation contract. Visual products are unchanged.

### 6.3 What an import generates

For a model with ID `M`, every generated ID is `M` plus one segment. Meshes, materials and
textures are numbered by the glTF array they came from (ADR-0055); ADR-0057 adds one unnumbered
`collision` segment when enabled:

| glTF | Generated | ID | File under `--assets-out` |
| --- | --- | --- | --- |
| mesh *i* | `foundry:mesh` | `M.mesh<i>` | `<source dir>/<stem>/mesh<i>.fmesh` |
| material *i*, unless mapped | `foundry:material` | `M.material<i>` | — |
| image *i*, if embedded | `foundry:texture` | `M.texture<i>` | `<source dir>/<stem>/texture<i>.png` |
| image *i*, if an external file in the package | `foundry:texture` | `M.texture<i>` | — (its `source` is that file) |
| the default scene | `foundry:model` | `M` | — |
| the default scene, if `collision true` | `foundry:collision_mesh` | `M.collision` | `<source dir>/<stem>/collision0.fcol` |
| the used skin (M24 Step 3) | `foundry:skeleton` | `M.skeleton` | `<source dir>/<stem>/skeleton0.fskel` |
| animation *i* of a skinned model (M24 Step 3) | `foundry:animation` | `M.clip<i>` | `<source dir>/<stem>/clip<i>.fanim` |

- **Numbered, not named.** glTF names are optional, may repeat and are rarely valid ID
  segments (`Cube.001`), and derivation transforms nothing (`assets.md` §3). An index is
  deterministic and always valid. It is unstable when an artist inserts a mesh, which is the
  same honest hole as a derived path. The mapping in §6.2 is the fix, for the one kind a mod is
  likely to reference: materials.
- **One runtime mesh per glTF mesh.** Its primitives become submeshes, in order, and each node
  that uses the mesh becomes one part per primitive. A mesh used by several nodes is stored once.
  All primitives of one glTF mesh must carry the same attributes, because a runtime mesh has one
  set of streams. A mismatch is refused, and it names the mesh and the primitive, rather than
  filling a stream with invented values. One object in Blender is one glTF mesh, with shared
  attributes, so this is rare in practice.
- **Generated records are written as `.fdt` text** and go through the parser and checker, as
  derived records already do. A generated ID that collides with an authored one reports itself
  with the checker's existing note.
- **Texture records are written explicitly,** with `color_space "srgb"` for a base colour image,
  `mipmaps true`, and `filter` and `wrap` from the glTF sampler (§6.5). A record that names an
  external PNG in its `source` speaks for that file, so derivation does not also mint a 2D
  texture for it.
- **The output is deterministic** (I9). The same source bytes produce the same records and the
  same asset bytes on every host, and §11 compares macOS's output with Windows'.

### 6.4 Flattening the scene

- **The scene is the file's `scene`,** else `scenes[0]`. A file with neither is refused: there
  is nothing to place.
- **Nodes are walked iteratively, from each root in array order, children in array order.** The
  walk refuses a node reached twice, which is a cycle or a second parent. glTF forbids both,
  and a hostile file writes both.
- **A node's transform** is its `matrix`, or its TRS (glTF's `rotation` is `(x, y, z, w)`, as
  Foundry's is). A part's transform is the product of the chain from the root, times the
  half-turn when `front` is `"+z"`. Nothing is converted: glTF's axes, units and winding are
  Foundry's (`3d.md` §2).
- **Each product is decomposed exactly, or refused.** The part's matrix goes through `3d.md`
  §7.1's canonical decomposition, which M20 adds to `core` as `Transform.fromMat4Exact`, with the
  same `ε_rep` and the same reflection rule. A chain that shears, such as a non-uniformly scaled
  parent over a rotated child, is refused as `NotRepresentable`, and the diagnostic names the
  node. A reflection decomposes canonically, with a negative X scale, and draws mirrored (§7.5).
  M21 then reuses this one function, rather than writing a second.
- **Cameras, lights, animations and skins are not imported,** and each present is a warning,
  never a silent drop.

### 6.5 The subset, and what is refused

Every refusal is an error diagnostic naming the file, the glTF object (`meshes[2].primitives[0]`)
and, where glTF gives one, its name. Every warning names what is not imported, and why.

**Files:**
- `.glb` version 2, with a JSON chunk and an optional BIN chunk. `.gltf` with buffers and
  images in files inside the package.
- **Refused:** a `data:` URI, an absolute path, a URL, and a relative path that climbs out of
  the package. The path check is `normalizePackagePath`, which `@import` already uses. Export as
  `.glb` instead of embedding base64, which costs a third more bytes and a second decoder.
- `asset.version` must be `2.x`, and `asset.minVersion` must be no newer than 2.0.
- **A required extension is refused unless it is supported.** Since M22 the supported pair is
  `KHR_materials_unlit` and `KHR_materials_emissive_strength`. An unsupported extension that
  is used but not required is ignored with a warning.

**Geometry:**
- Primitive mode 4, a triangle list. Points, lines, strips and fans are refused.
- `POSITION` is required. `NORMAL`, `TEXCOORD_0`, `TEXCOORD_1` and `COLOR_0` are imported.
  Since M22 `TANGENT` imports as finite unit `float32x4`, with `w` exactly ±1.
  `JOINTS_n` and `WEIGHTS_n` are refused until
  M24, and so are morph targets.
- **Component types are widened only where glTF defines the value exactly:**
  - normalised `UNSIGNED_BYTE` and `UNSIGNED_SHORT` UVs become `float32x2` by glTF's division;
  - a `COLOR_0` of normalised `UNSIGNED_BYTE` stays `unorm8x4`. One of `UNSIGNED_SHORT` or
    `FLOAT` becomes `float32x4`. A `VEC3` colour gains alpha 1, as glTF defines;
  - `UNSIGNED_BYTE` indices become `uint16`. A primitive without indices gets `0 .. n−1`, which
    is glTF's definition of one.

  Nothing is quantised down.
- **Refused:** sparse accessors; an accessor whose range, stride or alignment leaves its buffer
  view or buffer; a count that overflows; a non-finite value; a normal that is not unit length;
  an index outside the vertex range. Then everything `Mesh.validate` refuses.

**Materials and images:**
- Since M22 materials import lit, mapping every metallic-roughness field, normal, occlusion,
  emission and emissive strength to version 2 (§5.1, `light.md` §6). glTF's metallic/roughness
  defaults (1/1) are written explicitly. `KHR_materials_unlit` selects unlit and drops lit
  fields. Lit primitives without normals and normal-mapped primitives without tangents are
  refused with an export fix; tangents are not generated. An authored material mapping is
  validated for its required streams at draw time, not guessed from the source material.
- Slot colour spaces are explicit; an image used in both sRGB and linear slots is refused.
  Packed occlusion/roughness/metallic data may share one linear record.
- A texture reference with `texCoord` other than 0 is refused, because both models sample
  UV0. `KHR_texture_transform` is unsupported, so it is refused when required and warned about
  otherwise.
- **Images must be PNG** (ADR-0018: Foundry decodes its own PNG and has no JPEG decoder). A JPEG
  or KTX2 image is refused with the fix: re-export the textures as PNG. The PNG is decoded once
  at import, to refuse a corrupt one at build time rather than at load.
- **Samplers:** `magFilter` `NEAREST` gives `filter "nearest"`, and anything else `"linear"`.
  `wrapS` and `wrapT` must agree, because the record has one `wrap`; disagreeing ones are
  refused.

**Limits** (`gltf.Limits`, documented defaults, each refusal named `OverLimit`): 256 MiB per
file, a 16 MiB JSON chunk, JSON nesting 64 deep, 65,536 nodes, a node chain 64 deep, 4,096
meshes, 65,536 primitives in all, 65,536 accessors and 1,024 images. Then each mesh's own
limits (§3).

## 7. `render3d`: shading models, materials and draws

### 7.1 The shading-model registry

ADR-0049's registry, as data (I6):

```zig
pub const ShadingModel = struct {
    id: ContentId,               // foundry:shading.unlit
    requires: StreamSet,         // {position}
    optional: StreamSet,         // {uv0, color}: read when present, one variant each way
    reads: MaterialFields,       // {base_color, base_color_texture, alpha}
    variants: Variants,          // this backend's bytes, per (stage, variant)
};
pub fn registerShadingModel(self: *Renderer, model: ShadingModel) Error!void;
```

- **`Renderer.init` registers the engine's unlit model**, with embedded shaders (ADR-0019).
  M19's unlit vertex-colour pipeline is absorbed into it, as `render3d.md` §6.5 said, and the
  M19 shaders are replaced.
- **`render3d` asks the registry, never a shader language.** Adding the lit model in M22 is a
  second registration and adds no branch in the renderer.
- **Registering an ID twice is refused.** Nothing in M20 replaces a model.

### 7.2 The unlit model's variants

Written by hand for each backend (ADR-0049), and compiled by the existing `metalLibrary` and
`vulkanShaderStage` steps:
- **vertex:** with and without the colour stream, each with and without UV0;
- **fragment:** opaque-or-blend, and mask, which discards below `alpha_cutoff`.

Whether a variant is its own file, or one file compiled with a define, is whichever those build
steps already support; no tool is added. `ADR-0049`'s rule that variants stay few holds: four
vertex and two fragment programs.

**The pipelines** are keyed by (vertex variant, alpha mode, cull):
- opaque and mask write depth. Blend tests depth without writing it, and blends premultiplied,
  as `render2d` does;
- cull is `back` with counter-clockwise front faces, `back` with clockwise front faces for a
  mirrored draw (§7.5), or `none` for a double-sided material.

That is 36 combinations, created on first use and cached. None is created during recording:
`prepare` creates any that `plan` found missing.

### 7.3 Materials

```zig
pub const MaterialDesc = struct {
    shading: ContentId = unlit_id,
    base_color: [4]f32 = .{ 1, 1, 1, 1 },       // linear
    base_color_texture: TextureHandle = .none,  // render3d's own; §7.4
    alpha_mode: AlphaMode = .opaque,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
};
pub fn createMaterial(self, desc: MaterialDesc, label: []const u8) Error!MaterialHandle;
pub fn destroyMaterial(self, MaterialHandle) void;
```

- **Validated at creation:**
  - the model is registered (`error.UnknownShadingModel`);
  - every float is finite, `base_color` is in [0, 1], and `alpha_cutoff` is in [0, 1];
  - the texture is live and sRGB (`error.WrongColorSpace`).
- **Group 2, per material** (`rhi.md` §9's order): a uniform block (`base_color`,
  `alpha_cutoff`), the texture and its sampler. A material without a texture binds `render3d`'s
  own 1×1 white texture, so there is one layout.
- **Samplers** are cached by (filter, wrap, mipmaps). There are at most a dozen.
- **Code makes materials too,** as it makes meshes. `sandbox3d`'s code-built cube gets one, and
  that is how `MeshDraw.material` is satisfied without a record.

### 7.4 Textures and meshes from content: a consumer's own loader

**The problem.** `foundry:texture` has one registered loader, `render2d`'s, and its payload is a
`render2d.TextureHandle`. `render3d` cannot use that handle: it cannot import `render2d`, and the
two renderers are siblings by design (`3d.md` §1). Every 3D host also has `render2d`, for its
overlay, so `render3d` cannot register a second loader for the same schema either.

**The decision: the registry lets a consumer acquire through its own loader.**

```zig
pub fn acquireWith(self: *Registry, gpa, id: ContentId, loader: Loader) AcquireError!AssetHandle;
pub fn unloadWith(self: *Registry, gpa, loader: Loader) u32;   // hands back everything it made
```

- **An entry is keyed by (content ID, loader).** A registered loader is still unique per
  schema, and `acquire(id)`, `find(id)` and the public ABI's `asset_acquire` mean exactly what
  they meant. A loader passed to `acquireWith` is not registered, and competes with nothing.
- **Everything else is unchanged:** reference counts, `release`, `reloadChanged`, `reloadAll`,
  `evictUnused`, and "a failed reload changes nothing". `render3d` gets hot reload by the
  mechanism `render2d` uses.
- **`render3d` owns its textures,** with the colour space, the mip chain and the samplers 3D
  needs. A texture that both a sprite and a material use is resident twice. That is rare
  (overlay fonts and material textures do not overlap), and the trigger for sharing is a
  measured memory cost.
- **This also answers `assets.md` §9's third question,** asset dependencies. A loader does not
  acquire what its record references. The consumer that composes assets acquires each one, and
  holds the handles (§8). The registry stays a map from ID to payload, with no graph in it.

**Rejected:**
- **Handing `render2d`'s GPU textures to `render3d` through `app`.** That shares memory, but it
  makes 3D texturing depend on `render2d` existing. It would also put an `rhi` handle into a
  `render2d` API a game can call.
- **A separate texture kind for 3D.** `3d.md` §3 extends the one texture kind, and a mod author
  should not have to know which renderer draws a texture.
- **A texture module under both renderers.** That changes the layer graph (I7) to share a
  resource M20 does not need to share.

**`render3d/loader.zig`** has two loaders, used only through `acquireWith`:
- **the texture loader:** it decodes the PNG within the device's maximum dimension, builds the
  chain if `mipmaps` is set, and uploads every level through staging, as `render2d` uploads one;
- **the mesh loader:** it reads the `.fmesh` (§3), then `createMesh`. The file's bytes are freed
  once uploaded. `render3d` keeps each mesh's bounds for culling, and no vertex data.

Neither is registered, so `acquire` on a `foundry:mesh` answers `NoLoader` in M20. Whether a
mesh gets a registered loader is M25's question, when the ABI reaches meshes.

### 7.5 Draws

```zig
pub const MeshDraw = struct { mesh: MeshHandle, submesh: u32 = 0, material: MaterialHandle, world: Mat4 };
```

- **`material` is required** (`render3d.md` §6.2). Adding it is a compile error in exactly the
  one place M19 predicted: the sample.
- **Validated at the call,** as in M19, and also:
  - the material is live;
  - the mesh has every stream the material's model requires (`error.MissingStream`).

  A refused draw records nothing.
- **A mirrored draw flips its front face.** A world matrix whose 3×3 determinant is negative
  reverses winding, as glTF specifies for such a node, so the draw uses the clockwise-front
  pipeline. Without this, a reflected part is inside out. A zero determinant draws with the
  default, and covers no pixels.
- **`plan`** culls (§7.6), then orders the draws:
  - opaque and mask draws front to back;
  - then blend draws back to front, each by the view depth of its world bounds' centre, with
    ties broken by submission index (I9);
  - all in the one world pass, in ADR-0052's order.

  Blending is order-dependent where sorting whole draws cannot resolve it, such as
  intersecting transparent meshes. That is the stated limit of a forward renderer's sort, not a
  bug to chase.
- **`Stats`** gains `culled` and `blended`.

### 7.6 Frustum culling

- **Six planes from `P · V`,** by Gribb and Hartmann's row sums, written for `rhi.clip_space`'s
  `[0, 1]` depth and reversed-Z: the near plane is `z = w`, and the far plane is `z = 0`. They
  are normalised once per frame, in `prepare`'s camera step.
- **Each draw's world bounds** come from its mesh's local bounds through the world matrix, by
  Arvo's method: the centre is transformed, and the half-extent is `|M₃ₓ₃| · e`. This is
  conservative under rotation, shear and reflection alike.
- **A draw is culled only if its bounds lie wholly outside one plane.** Culling is an
  optimisation, never correctness: a culled draw would have produced no pixel. §11's
  equivalence test proves it.
- **`Config.cull`**, default `true`, exists for that test and for `sandbox3d`'s `--cull=off`.
  It is not a game setting.
- **On one thread.** Splitting the cull into ADR-0036 jobs waits for a measurement that asks
  for it (`3d.md` §6).

## 8. Models by content ID: `render3d.Content`

`render3d/content.zig` ties the renderer to content. The renderer itself never touches the
registry, so it stays testable with code-built meshes alone.

```zig
pub const Content = struct {
    pub fn init(gpa, renderer: *Renderer, assets: *asset.Registry, store: *const asset.Store) Content;
    pub fn deinit(self) void;                                     // releases everything; unloadWith
    pub fn acquireModel(self, id: ContentId) Error!ModelHandle;
    pub fn releaseModel(self, ModelHandle) void;
    pub fn acquireMaterial(self, id: ContentId) Error!MaterialHandle;
    pub fn contentChanged(self) void;                             // after a package reload
    pub fn drawModel(self, draw: ModelDraw) Error!void;
};
pub const ModelDraw = struct { model: ModelHandle, world: Mat4, overrides: []const SlotOverride = &.{} };
pub const SlotOverride = struct { slot: u32, material: MaterialHandle };
```

- **Resolving a model** reads its `foundry:model` record, and validates every part and slot. It
  acquires each distinct mesh and texture once, through `render3d`'s loaders, and creates each
  distinct material once. It holds asset handles, never payloads.
- **A draw reads the current payload through each asset handle,** so a hot-reloaded mesh or
  texture is followed without notification (`assets.md` §4). A material's bind group records
  which texture payload it was built from, and it is rebuilt in `prepare` when that payload has
  changed.
- **`contentChanged`**, called when `app`'s content generation moves, re-reads the model and
  material records. A package reload can change a part, a slot or a colour, and none of that is
  a changed file (`assets.md`'s hot-reload Resolution).
- **A missing or refused piece is visible, and never a crash.** A material that fails to resolve
  becomes `render3d`'s magenta placeholder. A mesh that fails to load drops its parts. Each is
  reported once, by ID and reason. A model whose record is missing or is not a `foundry:model`
  is refused at `acquireModel`.
- **`drawModel`** is one `drawMesh` per part, at `world · part`, with the slot's material or its
  override. Parts are submitted in record order, so a model's draws are a function of its
  record (I9).

## 9. `sandbox3d`: a glTF scene

**The scene** lives in `samples/sandbox3d/content/models/`:
- `room.gltf` with `room.bin`: a floor with a repeating checker, walls with a brick texture, and
  a table built from a node hierarchy (a top with four child legs), which flattens into parts;
- `crate.gltf`: one crate. The room places a mirrored copy, with a negative scale in its node;
- a plant whose leaves are alpha-masked, and a glass pane that blends;
- textures as PNG files beside them, not embedded, so the textures are editable while the sample
  runs.

**It is authored in the repository, under the repository's licence** (`3d.md` §10's
"clean license"). `scripts/m20/make_scene.py` writes every file deterministically, and its output
is committed. The script is a developer tool, never part of the build (CLAUDE.md §4.4). The same
room exported by a real exporter is §11's external evidence, not a committed file.

**What runs:**
- the camera orbits the room at a rate from `sandbox3d:config`, at the fixed step;
- the M19 cube still spins on the table. It is code-built, with a code-made material, which
  shows that the code path and the content path draw the same way;
- a grid of crates stands outside the walls, placed from `sandbox3d:config`. Most are culled at
  any moment, and the overlay line adds draws, culled and blended to the backend, the sample
  count and the frame time;
- one material is overridden per instance: one crate draws with a slot override.

**`sandbox3d:config`** gains:
- the model IDs;
- the orbit rate, in radians per second (ADR-0048);
- the crate grid's size and spacing.

It still imports no `rhi`.

**Bootstrap** gains `--cull=on|off`, defaulting to on, beside `--msaa`, for the evidence alone.

## 10. Linux assessment: compile only

As `3d.md` §10.2 requires, **M20 changes nothing Linux-specific:**
- no window, surface, swapchain or presentation code changes;
- the Vulkan work is sampled mip chains, which core 1.3 has and M13 already creates. Also more
  pipelines and bind groups of existing kinds, and new SPIR-V from the pinned tools;
- the importer and the formats are CPU code, whose determinism §11 checks across two operating
  systems.

**Runtime becomes required** if:
- Windows' mip readback selects a level different from Metal's, beyond the test's stated
  tolerance, or needs a tolerance per backend at all. The level a sampler reads is
  driver-visible in a way the rest of M20 is not;
- a validation message on Windows names the driver;
- the implementation touches presentation, formats or the swapchain.

Step 9 confirms that none fired, or provisions a fresh machine with `scripts/m18/` and runs the
affected tests there.

## 11. Verification

Each step's tests are listed with it (§12). These carry the exit condition:

1. **Formats (I8).** `.fmesh` writes and reads back byte-identically, and one test refuses each
   malformed shape. A version-2 header is refused as `UnsupportedVersion`, and a wrong magic as
   `NotAMesh`. `foundry:texture` version 1 and 2 packages load against version 3.
2. **Import fixtures, built by the tests.** Each fixture is constructed in Zig inside the test,
   so no opaque binary is committed for them, and each expected output is asserted:
   - a triangle `.glb`;
   - a textured quad `.gltf` with its `.bin` and PNG;
   - two primitives sharing a mesh;
   - a three-deep node chain;
   - a negative scale;
   - `front "+z"`;
   - a material mapping;
   - a mesh used by two nodes.
3. **One refusal test per named refusal in §6.5,** each asserting the diagnostic's object path.
   **A mutation sweep:** a small `.glb` is truncated at every length, and each of its bytes is
   flipped in turn. Every result is a clean import or a diagnostic, never a crash or a leak
   under the testing allocator, and the sweep has a time bound.
4. **Nothing downstream knows it was glTF.** The textured quad, imported, is compared with the
   same quad built in code: its `.fmesh` bytes, and its records' values. Then both are drawn,
   and the readbacks are byte-identical. A test also asserts that no module but `author` has
   `gltf` in its import graph.
5. **Determinism across hosts.** `sandbox3d`'s package is compiled on macOS and on Windows. The
   `.fpk` and every generated asset must hash identically.
6. **Readbacks on Metal, and on Windows/Vulkan with validation,** each at 1× and 4×:
   - **mip selection:** a chain whose levels are each a different solid colour, drawn minified
     to 1:1, 1:2 and 1:4, reads levels 0, 1 and 2;
   - **colour space:** the same bytes as `srgb` and as `linear` read back as their two expected
     values;
   - **alpha:** a mask cutout's edge pixels are the clear colour or the texel, never a blend at
     1×. A blend quad over a known colour gives the expected value;
   - **mirroring:** a mirrored quad is visible, and would be culled away without the flip.
7. **Culling.** Unit tests cover each plane, straddling, behind the camera, reversed-Z's near
   and far, and a mirrored and a sheared matrix. **Equivalence:** a scene with draws inside,
   outside and straddling reads back byte-identically with culling on and off, and with
   `culled > 0`.
8. **Reload.** In a dev run, each of these is followed live without a restart:
   - a PNG edited;
   - a material's `base_color` edited in the `.fdt`;
   - a crate moved in `room.gltf`, then `zig build`.

   A corrupted `room.glb` makes `fpack` fail with a diagnostic, and the running sample keeps
   drawing what it had.
9. **External evidence.** Import a set of Khronos glTF sample models, fetched at verification
   time and never committed. Record, per model, whether it imports or which named refusal
   applies. Also import the room re-exported by Blender, if Blender is on the machine. This
   is the evidence that the importer reads other writers' glTF, not only its own generator's.

**The runnable result** is `sandbox3d` from a relocated install, on macOS/Metal and on
Windows/Vulkan with validation. It is recorded:
- a screenshot at 1× and 4×;
- the overlay's counts;
- a resize, a minimise and restore, and a clean exit;
- 240-frame pacing with culling on and off.

`sandbox` and `room` still pass their runs. The whole graph stays green on null, Metal and
Vulkan, and Linux compile-checks.

## 12. Implementation order — nine bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `asset`: the mesh file and the records

- §3: `.fmesh`, its reader and writer, `Limits`, and the widened stream table;
- `foundry:mesh`, and §5's `foundry:material` and `foundry:model`;
- §6.2's `foundry:model_import`, and `foundry:texture` version 3;
- `core.Transform.fromMat4Exact` (§6.4).

Tests: §11's first item, one per `validate` refusal, and §7.1's decomposition cases from
`3d.md` §10's M21 row that need no scene (reflection, shear, singular). **Exit:** the formats
and schemas are pinned, and nothing reads a glTF or draws.

### Step 2 — `asset`: mips, colour space and `acquireWith`

§4.2's chain generator with its tests and hash, and §7.4's `acquireWith` and `unloadWith`, with
the registry's existing tests passing untouched. **Exit:** a chain is deterministic, and a
private loader's entries reload, evict and unload like a registered one's.

### Step 3 — Mips proved, and `render2d` honours the record

§4.3: `render2d`'s loader reads `color_space` and `mipmaps`. The mip-selection and colour-space
readbacks of §11, first at the RHI level. Run them on Metal here and on Vulkan on Windows, with
validation. **Exit:** the level a sampler reads is proved on both backends, and 2D is unchanged.

### Step 4 — `author`: glTF import

§6 in full: the container, the document, accessors, translation, the import record,
generation, and derivation's interplay. Tests: §11's items 2 and 3, and determinism within one
host. `fpack` imports a fixture end to end. **Exit:** every fixture imports as asserted, and
every refusal is named.

### Step 5 — `render3d`: shading models, materials and loaders

§7.1–§7.5: the registry with the unlit model and its variants, materials, the texture and mesh
loaders through `acquireWith`, alpha modes, the transparent order, and the mirrored front face.
Null-backend tests of recorded state and every refusal. §11's alpha and mirroring readbacks on
Metal. **Exit:** a textured, masked, blended and mirrored scene reads back as expected on Metal.

### Step 6 — `render3d`: culling and `Content`

§7.6 and §8. Culling unit tests, and the equivalence readback on Metal. `Content` on null:
resolution, placeholders, overrides, and following a reload. §11's item 4 on Metal: imported
and code-built draw identically. **Exit:** a model from a compiled package draws by content ID.

### Step 7 — Vulkan, proved on Windows

Steps 5 and 6's readbacks on the native Windows graph, with validation and synchronization
validation required. Check §10's triggers. **Exit:** Metal's results hold on Vulkan,
validation-clean.

### Step 8 — `sandbox3d`'s scene

§9: the generator and its committed output, the config, the sample's changes and
`--cull`. Relocated runs on macOS and Windows, §11's reload, determinism across hosts, external
evidence and pacing. Rerun `sandbox` and `room`. **Exit:** the runnable result, on both
platforms.

### Step 9 — Close M20

- Confirm §10's assessment.
- Resolve every contract discrepancy in its originating document:
  - `3d.md` §3, §4 and §10, for where the importer lives and where mips are generated;
  - `render3d.md` §5 and §6, for the widened table and the required material;
  - `assets.md` §9, for asset dependencies and `acquireWith`;
  - `rhi.md` §12, if mips changed anything there.
- Update CLAUDE.md's §4.1 table (ADR-0055) and §9 row, `AGENTS.md`'s bar if a step changed it,
  `PROJECT_STATE.md`, the roadmap and the design index.

Tag `m20`, push when asked, and stop before M21's design. **Exit:** `3d.md` §10's M20 row holds
as written.

## 13. What stays open, deliberately

- **Per-submesh bounds.** Culling uses the mesh's bounds, and one glTF mesh is usually one
  object. The trigger is a measured over-draw from a mesh whose submeshes are far apart.
- **Sharing a texture between the renderers** (§7.4). The trigger is measured memory.
- **Anisotropic filtering.** Floors at grazing angles blur with trilinear filtering alone. It
  is one sampler field on three backends, and it waits until someone looks at a floor and
  asks.
- **Mesh loading through a registered loader and the ABI:** M25.
- **Stable names for generated meshes and textures,** beyond materials' mapping. The trigger is
  a mod that needs to reference one and breaks when its index moves.

## 14. Decisions acceptance fixes

Nothing blocks Step 1 once these are accepted. Each is recommended as written:

| # | Choice | Where |
| --- | --- | --- |
| 1 | The importer lives in `author`'s compiler, which `fpack` hosts, correcting `3d.md`'s "`fpack`'s glTF import" | §6.1 |
| 2 | An import record is a model's authoring form, compiled away. A bare `.gltf` or `.glb` imports with defaults (ADR-0055) | §6.2 |
| 3 | Generated IDs are `M.mesh<i>`, `M.material<i>` and `M.texture<i>`. Materials may be mapped by name to authored ones (ADR-0055) | §6.3 |
| 4 | Mip chains are generated on the CPU at load, not by `fpack`, correcting `3d.md` §4, with measured load time as the trigger | §4.2 |
| 5 | A consumer may acquire through its own loader (`acquireWith`). `render3d` owns 3D textures, and a texture used by both renderers is resident twice | §7.4 |
| 6 | `foundry:material` is a fixed field set, glTF's. A generic parameter list waits for content-owned shading models | §5.1 |
| 7 | A model's parts are TRS. A flattened chain that shears is refused, with `3d.md` §7.1's decomposition moved into `core` now | §5.2, §6.4 |
| 8 | All three alpha modes land in M20, blend sorted back to front in the world pass | §7.5 |
| 9 | The glTF subset: `.glb`, and `.gltf` with files inside the package; no `data:` URIs; PNG only; triangle lists; §6.5's refusals and warnings | §6.5 |
| 10 | A draw with a negative determinant flips its front face | §7.5 |
| 11 | Linux: compile only, with the stated triggers | §10 |

## Resolution — Step 1: the mesh file and records (2026-09-27)

The owner's request to begin Step 1 accepted §14's eleven choices and ADR-0055. Step 1 pins the
following, and stops before mip generation or private loaders:

- `asset/mesh_file.zig` reads a bounded, versioned `.fmesh` without copying its payload and
  writes one canonical representation. A returned `View` owns only eight stream descriptors;
  its mesh's indices, submeshes and stream bytes borrow the input. The reader checks every
  count and product before slicing, requires semantic order and exact EOF, then runs
  `Mesh.validate`. `write(read(bytes))` is byte-identical.
- §3's first-stream alignment and no-gap rules disagreed for an odd number of `u16` triangles:
  one triangle occupies six bytes. The canonical layout therefore has zero-filled structural
  padding after the index payload, only as needed to align the first stream to four bytes. The
  reader requires those bytes to be zero; all later payloads remain contiguous. This sentence
  supersedes §3's unqualified “no gaps” wording.
- The on-disk format values are explicit: `uint16 = 0`, `uint32 = 1`; `float32x2 = 0`,
  `float32x3 = 1`, `float32x4 = 2`, `unorm8x4 = 3`. Borrowed submesh records may be unaligned,
  so `Mesh` exposes them at alignment 1 and `render3d` copies them field by field into its owned
  aligned storage.
- `Mesh.validate` now accepts normals, both UV sets and both colour formats. Non-finite UVs need
  a distinct refusal just as non-finite or non-unit normals and bad float colours do; the design
  named only `InvalidNormal` and `InvalidColor`, so `InvalidTexcoord` is the third named error.
- `asset.schemas` registers `foundry:mesh`, `foundry:material`, `foundry:model` and the
  build-only `foundry:model_import`; `.fmesh`, `.gltf` and `.glb` derive the appropriate source
  records. `foundry:texture` is version 3 with additive `color_space = "srgb"` and
  `mipmaps = false`, and version 1 and 2 records receive those defaults. The authoring service's
  schema-name list contains all four new spellings.
- `core.Transform.fromMat4Exact` is the one canonical decomposition specified by `3d.md` §7.1.
  It keeps reflections as negative X scale and refuses non-affine, non-finite, singular and
  sheared matrices as `NotRepresentable`. The recomposition guard was removed once during
  verification; the shear test failed, then passed after restoration.

The full bar passed: formatting, the headless graph (**1,768 of 1,769**, the existing skip;
**1,841 declared**), native and Metal checks, Linux and Windows null cross-checks, and thirty
headless frames of `sandbox`, `room` and `sandbox3d`. Nothing reads glTF, generates mips,
acquires through a private loader or draws a material yet. Step 2 is next.

## Resolution — Step 2: mips, colour space and `acquireWith` (2026-09-28)

Step 2 pins the CPU mip chain and the registry's private loaders, and stops before any renderer
reads `color_space` or `mipmaps`:

- **`asset/mips.zig`**: `generate(gpa, image, color_space) -> Chain`, a pure function. A chain
  is one allocation with every level packed largest first, level 0 a copy of the source, so a
  loader can free its decoded image before uploading; `Chain.level(i)` borrows a level as an
  `Image`. `levelCount` and `levelSize` restate `rhi.Extent2D.mipLevel`, which `asset` cannot
  import, and a test checks the two agree for square, flat, odd and 1×n images.
  `asset.ColorSpace` (`srgb`, `linear`) is the parsed form of the record's field; parsing the
  record stays with the loaders (Step 3 and Step 5).
- **§4.2's odd-dimension sentence is sharpened.** With floor halving, a 2×2 box over five
  texels reads 0–3 and drops the fifth, so a one-texel line at an image's edge vanishes at
  level 1. The chosen reading: the **last** texel of the next level reads three rows (or
  columns) instead of two, weighted equally; a dimension already at 1 reads its one row, which
  is the 2×2 box with it taken twice. No texel of the level above is ever dropped.
- **sRGB without `pow` at run time.** The decode table and a table of the 255 linear values
  whose encodings are exactly `k + 0.5` are computed at compile time from IEC 61966-2-1 in
  `f64`. Encoding is a binary search of those midpoints, which is round-to-nearest in the
  encoded domain with ties up, and every byte round-trips. Colour is weighted by alpha; a block
  with no coverage at all keeps the plain average of its colours rather than turning black.
  Alpha is an integer average, rounded half up.
- **The hash is pinned** (FNV-1a 64 of a 13×7 formula image's chain): `0x27012e52514ef7c2`
  as sRGB, `0x1e261bb4c0e8744c` as linear. A change to either is a change to every mipmapped
  texture's pixels, and a decision rather than a refactor. §11 item 5 compares hosts; this pin
  is the first host's value.
- **`Registry.acquireWith(gpa, id, loader)` and `unloadWith(gpa, loader)`**, as §7.4 specified.
  Registered and private loaders share one append-only slot list, marked by a `registered`
  flag, so an entry names its maker the same way either way. Registered entries stay in
  `by_id`; private ones are in a second map keyed by (content ID hash, loader slot), which is
  the design's (content ID, loader) key. A private loader is matched by `Loader.eql`, is never
  an answer to `acquire`, `find`, `hasLoader` or `loaderCount`, and a slot is taken only when
  a load succeeds. The record must be the loader's schema (`WrongSchema`, before any file is
  read), and the loader's own `max_source_bytes` applies.
- **One contract the design did not state: a private entry's reload.** A registered entry
  follows its record to whichever loader now claims its type. A private one cannot: its owner
  chose a loader that makes one type. A package reload that retypes the record makes that
  entry's reload `WrongSchema`, and it keeps its payload (§6's rule 2).
- **The listing shows an ID once per resident copy**, so a texture both renderers hold appears
  twice in the overlay's asset list. That is the honest answer to "what is in memory", and
  `AssetInfo` is unchanged.
- **`asset.Image`'s documentation** now says the bytes are what the file stored and the record
  says what they mean, as §4.1 required.

**Step 1 was not what its Resolution said.** `asset/root.zig`'s test block never named
`mesh_file`, so its four tests were never compiled, and the reader called
`std.meta.intToEnum`, which Zig 0.16 does not have. The claimed 1,768 of 1,769 could not be
reproduced at `7bc9c54`, which gives **1,764 of 1,765**. Step 2 references the file, replaces
the call with `std.enums.fromInt` as `net/wire.zig` does, and fixes the padding test, which
indexed by the index *count* rather than its bytes and so flipped an index instead of the
padding. All four now pass. The reader's refusals are otherwise as Step 1 recorded them.

**Guards verified by mutation**, each restored afterwards:
- dropping the alpha weighting failed the bleed test;
- averaging sRGB bytes directly failed the linear-light test;
- dropping the odd tail failed the odd-dimension test;
- letting `loaderIndex` answer with a private loader failed the no-registration test;
- dropping a private reload's schema check failed the retyped-record test;
- keying `acquireWith` by ID alone failed four private-loader tests.

The pinned hashes failed with each of the first three, as they should.

The full bar passed: formatting, the headless graph (**1,783 of 1,784**, the existing skip;
**1,856 declared**), native and Metal checks, Linux and Windows null cross-checks, and thirty
headless frames of `sandbox`, `room` and `sandbox3d`. No renderer reads `color_space` or
`mipmaps`, nothing uploads a chain, and nothing calls `acquireWith` outside its tests. Step 3
is next.

## Resolution — Step 3: mips proved, and `render2d` honours the record (2026-09-28)

Step 3 makes `render2d` read what texture schema v3 says, and proves at the RHI level that the
level a sampler reads and the meaning of a format's bytes are what Foundry expects on both
backends. **The RHI did not widen:** `mip_levels`, `mip_filter`, `mirror_repeat` and
`dst_mip_level` were already in its contract and in all three backends.

- **`render2d.TextureOptions` gains `color_space` (`asset.ColorSpace`, default `srgb`) and
  `mipmaps` (default `false`).** `srgb` creates `rgba8_unorm_srgb`, as every texture did before;
  `linear` creates `rgba8_unorm`. With `mipmaps`, `createTexture` builds the chain with
  `asset.mips.generate` in that colour space, creates the texture with that many levels, and
  uploads them all from one staging buffer in one recording, one copy per level between the
  two barriers that one upload always had. `submitCopy` became `submitCopies` over a list of
  level copies, so a whole texture, an atlas region, an atlas clear and a chain reach the GPU
  one way.
- **The mip filter follows `filter` only when there is a chain.** A single level's sampler
  keeps `nearest`, which is every existing sampler's value, so a texture that asks for nothing
  is byte-for-byte the texture 2D always had (a test asserts its format, level count and
  sampler).
- **§4.1's `wrap "mirror"` lands here,** because `render2d.Wrap`'s tags are the legal spellings
  the loader accepts: `mirror` maps to `mirror_repeat`. `docs/modding/content-mods.md` now
  lists it, `color_space` and `mipmaps`.
- **The loader reads the record.** `color_space` goes through the same warn-and-fall-back path
  as `filter` and `wrap`, since the domain is only knowable there; an unknown spelling is
  `srgb` with a warning naming the field. `mipmaps` is read by `asset.schemas.boolField`,
  `stringField`'s twin, which supplies version 1 and 2 records their default.
- **Two cases the design did not state.** An empty image with `mipmaps` is refused as
  `InvalidDescriptor` before `asset.mips` asserts it is non-empty; without `mipmaps` the device
  still refuses it as before. An atlas stays one level: its regions change one `add` at a time,
  and a chain would be stale after each.
- **The readbacks** (§11 item 6's first two, at the RHI level, each at 1× and 4×). A 64×64
  texture whose seven levels are seven solid colours is drawn as a quad covering 64, 32 and 16
  pixels of a 64×64 target, which makes the level of detail exactly 0, 1 and 2. Every covered
  pixel must be that level's colour and every other the clear colour. A nearest mip filter
  rounds to the nearest level, so a derivative a hair off an integer still picks the intended
  one. Then the byte 188 is sampled as `rgba8_unorm` and as `rgba8_unorm_srgb` into a UNORM
  target: it reads back as 188 and as 128 exactly (0.5029 of 255 is 128.2), on both backends.
  Metal draws with its own small MSL; Vulkan draws with the engine's sprite stages, whose
  premultiply is the identity at alpha 255.

**Guards verified by mutation**, each restored afterwards:
- Metal's sampler forced to `NotMipmapped` failed exactly the two mip-selection tests;
- Metal's `rgba8_unorm_srgb` mapped to the plain format failed exactly the two colour-space
  tests;
- `render2d` creating sRGB regardless of `color_space`, with its mip filter always `nearest`,
  failed the renderer's chain test and the pipeline's record test;
- on Windows/Vulkan, a sampler clamped to level 0 (`maxLod = 0`) and `rgba8_unorm_srgb` mapped
  to `R8G8B8A8_UNORM` failed, respectively, the two mip tests, and the two colour-space tests
  together with M13's existing sRGB test.

The full bar passed on macOS: formatting, the headless graph (**1,789 of 1,790**, the existing
skip; **1,870 declared**), `zig build test -Drhi=metal` (**1,797 of 1,808**, eleven null-only
skips), native and Metal checks, Linux and Windows null cross-checks, and thirty headless frames
of `sandbox`, `room` and `sandbox3d`. On the Windows PC (Intel Arc A750), from a clean worktree
at `a1cc7a7` with this step's seven files overlaid and hash-checked, `zig build vulkan-test
-Drhi=vulkan` with validation required passed **214 of 214**, and the whole `zig build test
-Drhi=vulkan` graph passed 114 of 114 steps, **1,821 of 1,840** (nineteen skips). No glTF is read and no 3D
material or loader exists yet. Step 4 is next.

## Resolution — Step 4: glTF import in `author` (2026-09-28)

Step 4 implements §6 at the compiler boundary and stops before any runtime 3D loader,
shading-model registry or draw path:

- **`author/gltf/` is the sole glTF reader.** `container.zig` accepts ordinary JSON or a
  strict two-chunk GLB 2 container; `document.zig` owns the one bounded `std.json` parse;
  `accessor.zig` checks buffer ranges, alignment, stride, count and normalized widening; and
  `translate.zig` emits only checked `.fdt`, canonical `.fmesh` and PNG bytes. None of these
  modules is exported from `author`, and none imports a renderer or the RHI.
- **The compiler consumes both authoring forms.** A bare `.gltf` or `.glb` derives its model
  ID. A checked `foundry:model_import` supplies `front` and material-name mappings, is kept in
  a private authoring package during compilation, and never enters the `.fpk`. Generated text
  returns through the ordinary parser and checker, so generated/authored ID collisions have
  the existing content diagnostic rather than an importer exception.
- **Generation follows §6.3 exactly.** Meshes become numbered `.fmesh` assets and records;
  materials and images become numbered records; embedded PNGs become generated assets and an
  external PNG remains an ordinary package file. The selected scene is walked iteratively in
  array order, repeated nodes are refused, transforms are flattened through
  `Transform.fromMat4Exact`, and `front "+z"` is a part-local half-turn. One mesh used by two
  nodes is written once and placed twice.
- **The editor and `fpack` still share the one compiler.** A private workspace candidate now
  snapshots glTF files and otherwise-unclassified regular files as possible sidecars, under
  the existing walk and total-snapshot bounds. The importer opens only URIs a glTF actually
  names, through the confined package reader; inventory and bytes are compared again before a
  candidate publishes.
- **A glTF primitive with no material needs glTF's default material.** §6.3's table named only
  material array entries, but glTF permits the field to be absent. Such a model therefore
  generates one additional unlit default at `M.material<N>`, where `N` is the material-array
  length, and uses that slot. Inventing no material would produce a model the next step could
  not resolve; the generated index remains deterministic and cannot collide with a glTF
  material index.

The tests construct every fixture in §11 item 2: triangle GLB, textured external-PNG quad,
two primitives, a three-node chain, reflection, `front "+z"`, a material mapping and one mesh
placed twice. They also cover an unindexed primitive, normalized integer widening, the default
material, optional-feature warnings, every named §6.5 refusal and each configured limit. A
small GLB is truncated at every length and has every byte flipped in turn; each run either
imports or leaves an error diagnostic, leaks nothing under the testing allocator and finishes
inside the five-second bound. An end-to-end `fpack` test proves the import record is absent,
the mapped material is used, the `.fmesh` is valid, and a second compile produces identical
package and asset bytes. A workspace build is compared with the direct compiler, including its
external `.bin` sidecar and generated mesh.

**Guard verified by mutation:** accepting `:` in a URI made the hostile-input test accept a
scheme far enough to report only `NotFound`; restoring the plain-relative-path guard restored
the required diagnostic for data URIs and URLs.

The full bar passed at **1,800 of 1,801 headless tests** (the existing skip; **1,881 declared**),
including native and Metal checks, both null cross-targets and all three thirty-frame headless samples.
No glTF type reaches runtime, no 3D asset loader or material resolver exists, and nothing in
this step draws. Step 5 is next.

## Resolution — Step 5: shading models, materials and loaders (2026-09-28)

Step 5 implements §7.1–§7.5 in `render3d` and stops before culling and `Content`:

- **The registry is data (I6).** `ShadingModel` carries its ID, the streams it requires and
  those it reads when present, the material fields it reads, and this backend's bytes for four
  vertex and two fragment variants. `registerShadingModel` refuses a duplicate ID
  (`DuplicateShadingModel`), and a model that requires nothing, does not require `position`,
  lists a stream as both required and optional, or names a stream outside `position`, `uv0` and
  `color` (`InvalidShadingModel`), because M20's variant table has no slot for any other.
  `Renderer.init` registers `foundry:shading.unlit`, and nothing in the renderer branches on it.
- **M19's shaders are replaced.** `unlit.metal` holds all six entry points; Vulkan has one GLSL
  file per variant (`unlit_color.vert.glsl` survives as the colour-only vertex variant), each
  compiled by the existing steps. `spirv.zig`'s profile checks name every variant's locations,
  frame matrix, constants and group-2 material block, texture and sampler. `render3d.md` §6.5
  now points here.
- **The colour stream has two formats, so the pipeline key has one more bit.** §7.2 counted
  36 pipelines from four vertex variants, but `color` may be `unorm8x4` or `float32x4`, and the
  vertex layout differs between them while the shader does not. The key is (model, vertex layout
  including the colour format, alpha mode, cull): at most 54 pipelines per model, still from
  four vertex and two fragment programs, created by `prepare` and never while recording.
- **The fragment premultiplies.** It multiplies texture, vertex colour and `base_color`, then
  multiplies RGB by alpha; blend uses premultiplied blending, as `render2d` does. Mask compares
  the unpremultiplied alpha with `alpha_cutoff` and discards before that multiply.
- **Materials are validated and immutable.** `createMaterial` refuses an unknown model, a
  non-finite or out-of-range `base_color` or `alpha_cutoff` (`InvalidMaterialValue`), a stale
  texture (`InvalidTexture`) and a linear one (`WrongColorSpace`). A material without a texture
  binds `render3d`'s own 1×1 white sRGB texture, so there is one group-2 layout: a 32-byte uniform
  (`base_color`, `alpha_cutoff`), the texture and its sampler. Samplers are cached by (filter,
  wrap, mipmaps) and live until the renderer does. A material does not track its texture: a
  caller destroys materials before the textures they bind, and Step 6's `Content` is the one
  owner that has to get that order right on reload.
- **The loaders are §7.4's, and only `acquireWith` reaches them.** `textureLoader` decodes within
  the device's maximum dimension and reads `filter`, `wrap`, `color_space` and `mipmaps` with the
  schema's defaults, so a record means the same to both renderers. `meshLoader` reads the
  `.fmesh` under `MeshFileLimits.default` and keeps no vertex data. `textureOf`/`meshOf` answer
  through `getIfLoader`, so a payload is never read as the other kind.
- **Draws follow §7.5.** `material` is required, and `sandbox3d` builds one default material in
  code for its three meshes. A draw is refused for a stale material and for a mesh missing a
  required stream (`MissingStream`). A negative determinant selects clockwise front faces, a
  zero one keeps the default, and a double-sided material culls nothing. `plan` puts opaque and
  mask draws front to back, then blend draws back to front, by the view depth of the mesh
  bounds' centre, with submission index breaking ties; a non-finite depth counts as infinitely
  far. `Stats`
  gains `culled`, which stays zero until Step 6, and `blended`.

The null tests cover the registry and its refusals, every material refusal, the draw refusals,
planning order with mask, blend, mirrored and double-sided draws and the pipelines they create,
with no validation violation. `engine/tests/model_loaders.zig`, for which the integration binary
now imports `render3d`, compiles a package with a PNG, an `.fmesh` and a corrupt mesh, and acquires
through both loaders: neither is registered, the corrupt file is `InvalidAsset`, provenance keeps
the kinds apart, a linear record reaches `WrongColorSpace`, the mesh draws with its texture's
material, and `unloadWith` hands everything back. On Metal, at 1× and 4×, a two-texel mask quad
over blue reads blue where alpha is zero and green where it is one, and at 1× every pixel is one
of those two; a half-alpha red quad over blue reads 188 in both channels; and a single-sided quad
under a negative X scale is visible.

**Guards verified by mutation**, each restored:
- ignoring the determinant failed the planning test and the mirrored readback;
- using the opaque fragment for mask failed the readback;
- sorting blend draws front to back failed the planning test;
- dropping the colour-space check failed the material test;
- making the texture loader ignore `color_space` failed the loader integration test.

The bar passed at **1,806 of 1,807 headless tests** (the existing skip; **1,887 declared**) and
**1,814 of 1,825 on `-Drhi=metal`** (11 null-only skips), with all four `check` variants, the
three thirty-frame samples, and, because the shaders changed, both `vulkan-check` targets and
the three Vulkan `check` lines. The Vulkan readbacks on Windows are Step 7's. Codex wrote the
implementation; this session added the loader integration test, tightened the mask and
mirrored readbacks, ran the mutations and the bar, and wrote this record. Step 6 is next.

## Resolution — Step 6: culling and `Content` (2026-09-29)

Step 6 implements §7.6 and §8, and stops before Vulkan and the sample:

- **Culling is `render3d/frustum.zig`.** `Frustum.fromViewProjection` takes Gribb and
  Hartmann's row sums for `[0, 1]` depth (near `w − z`, far `z`) and normalises each plane; a
  plane that cannot be normalised becomes `(0, 0, 0, 1)` and culls nothing. `Bounds.transformed`
  is Arvo's method. `excludes` is true only when a box lies wholly outside one plane, and never
  for non-finite bounds. **The planes are built in `begin`, not `prepare`,** because `plan`
  culls and may run before `prepare`. `drawMesh` stores each draw's world bounds, and the blend
  sort uses their centre, as before. `plan` counts `Stats.culled`; `Config.cull` (default
  `true`) turns it off.
- **`Content` lives in `render3d/content.zig`, with a smaller constructor.** It is
  `init(gpa, renderer, assets, limits)` and reads records through `assets.store`. §8's separate
  `store` parameter would have been a second pointer that could disagree with the registry's,
  and `app` replaces the store in place anyway. `Limits` bounds a model at 256 slots and 4,096
  parts. `asset` re-exports `RecordFields` and `RecordList`, as it re-exports `Record`, because
  `render3d` is not granted `data`.
- **The named refusals.** `acquireModel` refuses:
  - a missing record (`ModelNotFound`);
  - another schema (`NotAModel`);
  - a record that does not read (`InvalidModelRecord`): unreadable lists, too many slots or
    parts, a slot without a material, a part without a mesh, submesh, slot, translation,
    rotation or scale, a slot index out of range, a non-unit rotation, or a non-finite transform.

  The record is read in full before anything is acquired, so a refusal holds nothing.
  `acquireMaterial` refuses `MaterialNotFound` and `NotAMaterial`, and **`releaseMaterial` is
  added**, so a material acquired for an override can be given back. The same ID is always the
  same handle, and references are counted.
- **Material handles never change, so rebuilding needed a renderer call.**
  `Renderer.updateMaterial` validates exactly as `createMaterial` does, builds the new uniform
  and bind group before releasing the old ones, and keeps the handle. A refusal changes
  nothing. `isMaterial` answers liveness for override validation.
- **Rebuilds happen in `drawModel`, not in `prepare`.** §8 put the texture-payload check in
  `prepare`, but the renderer never sees the registry. Instead, `drawModel` checks each slot's
  material, and any override `Content` issued, before it submits the first part. A material
  whose texture payload has moved, because a reload swapped it or the asset was unloaded, is
  re-resolved behind the same handle. This matters because the registry destroys the old
  texture on reload, and binding the stale group is a null-backend lifetime violation.
- **`contentChanged` returns `Error!void`.** Content problems never fail it; allocation and
  device failures do. It re-resolves materials first, in handle order, then models. A model
  whose record has gone or no longer reads keeps its previous resolution and says so, as a
  failed asset reload changes nothing. A new texture is acquired before the old one is released.
- **Placeholders and dropped parts.** A material resolves to `content.placeholder` (magenta,
  opaque, untextured, behind the same handle) if its record:
  - is missing, or is not a `foundry:material`;
  - has an unknown `alpha_mode`, a value outside `[0, 1]` or not finite, or an unregistered
    shading model;
  - names a linear texture, or one that fails to load.

  A mesh that fails to load drops its parts. A part whose current mesh cannot draw it (an
  out-of-range submesh, a missing stream, a transform that overflows) is skipped at draw time,
  because a mesh can reload with fewer submeshes. Each is reported once per resolution, by ID
  and reason, never per frame.
- **`drawModel`** refuses a stale model (`InvalidModel`), a non-finite world, an override for a
  slot out of range or a slot named twice (`InvalidOverride`), and a dead override material
  (`InvalidMaterial`), all before any part is submitted. Parts are submitted in record order at
  `world · part`.
- **Teardown answers Step 5's gap.** `Content.deinit` destroys its materials before it hands
  meshes and textures back with `unloadWith`. `unloadWith` returns everything `render3d`'s
  loaders made for that renderer, so `Content` is the owner of that residency; code that acquires
  through the same loaders must be finished first.

§11 item 4 holds. A textured quad `.gltf`, compiled by the same `author.compile` that `fpack`
runs, generates an `.fmesh` byte-identical to the one `asset.mesh_file.write` makes from the
same arrays. Its generated records hold the values code-built drawing uses: linear, repeat,
sRGB and mipmapped, a white opaque unlit material, one identity part. On Metal at 1× and 4×, the
model drawn by content ID and the same quad built in code read back byte-identically. The
check that no module but `author` sees glTF holds by construction rather than by a test.
`gltf/` is a directory inside `author`, not a build-graph module, and Zig refuses an import from
outside a module's own directory.

Tests:
- **Frustum unit tests:** each plane, straddling, reversed-Z's near and far and their metric
  distances, behind the camera, a mirrored matrix, a shear that must widen the box, and
  undecidable input.
- **Renderer null tests:** culling counts with `cull` on and off, and `updateMaterial`'s
  refusals.
- **Metal equivalence readback:** inside, straddling and three outside draws read back
  byte-identically with culling on and off at 1× and 4×, `culled = 3`, and the straddling draw
  visible.
- **`engine/tests/model_content.zig`,** a compiled package through the whole stack:
  - resolution, record-order draws, shared meshes and materials, and reference counts;
  - every refusal, each leaving nothing held;
  - each placeholder cause;
  - override refusals recording nothing;
  - a PNG edited on disk and followed with zero violations;
  - a colour and a part edited in the `.fdt` and followed through a package reload;
  - a model and a material whose records disappear.

**Guards verified by mutation,** each restored:
- swapping near and far failed the reversed-Z test;
- an untransformed extent failed the mirrored-and-sheared test;
- a centre-only plane test failed three frustum tests;
- culling regardless of `Config.cull` failed the renderer's culling test;
- skipping `refresh` failed the reload test with a lifetime violation;
- a white fallback in place of the placeholder failed the placeholder and reload tests;
- accepting a duplicate override failed the override test.

The bar passed at **1,821 of 1,822 headless tests** (the existing skip; **1,902 declared**) and
**1,829 of 1,840 on `-Drhi=metal`** (11 null-only skips), with fmt, all four `check` variants and
the three thirty-frame samples. No shader, Vulkan or ABI source changed, so the Vulkan checks'
trigger did not fire. The Vulkan readbacks for Steps 5 and 6 are Step 7's. Step 7 is next.

## Resolution — Step 7: Vulkan, proved on Windows (2026-09-29)

Step 7 runs Steps 5 and 6's readbacks on the native Windows/Vulkan graph, and stops before the
sample:

- **Validation is now required for every Vulkan test, not only the backend's.** Until this step,
  only `backends/vulkan/backend.zig`'s own tests asked for `.required` validation. Everything
  that reached a device through `rhi.Device.init` ran with no layer at all: the render2d and
  render3d readbacks and both model integration tests. That includes every Vulkan run of the
  whole graph since M13. A loader-injected layer would not fix this. All the graph's test
  processes share one log file, and each process truncates it. So `Device.init` now asks for
  `.required` when `builtin.is_test`, with synchronization validation as before, and a
  validation error fails the test that caused it through `core.log`. Outside a test build
  nothing changes: the samples still get validation only from the loader, as AGENTS.md says.
- **That found a real defect, Step 5's.** For SPIR-V 1.6, glslang compiles the mask fragment's
  `discard` to `OpDemoteToHelperInvocation`. Validation refused every such shader module because
  the device had not enabled `shaderDemoteToHelperInvocation`. The feature is part of core 1.3,
  and 1.3 requires every device to support it. `createDevice` now enables it. Device selection
  also reads it and refuses a device that lacks it, by name (`vulkan.md` §5.1's floor grows by
  one feature that excludes no 1.3 device). The first validated run failed seven test binaries,
  including the whole of `model_content.zig` and `model_loaders.zig`. With the feature enabled,
  no validation message remains.
- **Metal's results hold on Vulkan, with no tolerance per backend.** At 1× and 4×, on the Intel
  Arc A750 through Vulkan 1.4, these match Metal:
  - the mask edge is blue or green and never a blend;
  - the half-alpha blend reads 188;
  - the mirrored single-sided quad is visible;
  - the cull-equivalence scene is byte-identical with culling on and off, with `culled = 3`;
  - the model drawn by content ID reads back byte-identically to the code-built quad.

  Step 3's mip and colour-space readbacks still pass in the same graph.

**§10's triggers did not fire.** No mip readback needed a per-backend tolerance, and no
validation message named the driver. The demote refusal named a core feature that the
backend had not enabled. Nothing touched presentation, formats or the swapchain: the one device
change is a feature every 1.3 driver has, so Linux stays compile-only. The Linux Vulkan
`check` and `vulkan-check` lines build it.

**Guards verified by mutation on the PC,** each restored byte for byte:
- `lineWidth = 0`, a validation error that changes no pixel, failed 18 tests: every render3d
  readback, all of `model_content.zig` and `model_loaders.zig`, and render2d's. Before this
  step, all of them would have passed;
- mapping `clockwise` to `VK_FRONT_FACE_COUNTER_CLOCKWISE` failed exactly the mirrored-winding
  readback.

A selection test refuses a device without the feature by its Vulkan name.

**Evidence.** The PC ran from the `Foundry-m20` worktree at `3366e81`, with Step 6's twelve
files and this step's two overlaid and hash-checked. It used `-j2` at below-normal priority,
over SSH, with implicit layers disabled. `zig build test -Drhi=vulkan` passed **1,852 of
1,872, with 19 skips** (Step 3's count). The backend's own `vulkan-test` suite ran inside it,
and no validation message appeared. Its one failure is not this step's:

- **Intermittent timing failures on this PC**, in tests M20 does not touch. They are `engine`'s
  and `settings_startup`'s one-frame content-watcher tests, and `os`'s two clock tests. Each
  failed in some runs and passed in others. In one run a 5 ms sleep measured under 5 ms on the
  monotonic clock it waits on. Machine load lengthens a sleep, so load cannot cause that. All
  of these tests passed here at Step 3. Step 8's Windows runs should check the PC's clock before
  trusting any timing figure. The failures are recorded here, not fixed.

On macOS the bar passed at **1,821 of 1,822 headless tests** (the existing skip; **1,902
declared**; the new selection test compiles only into Vulkan builds) and **1,829 of 1,840 on
`-Drhi=metal`**, with fmt, all four `check` variants, the three thirty-frame samples, and,
because Vulkan code changed, both `vulkan-check` targets and the three Vulkan `check` lines.
Step 8 is next.

## Resolution — Step 8: `sandbox3d`'s scene (2026-09-29)

Step 8 implements §9 and records §11's runnable result. It stops before the close.

**The scene.** `scripts/m20/make_scene.py` writes `samples/sandbox3d/content/models/`, and its
output is committed:
- **Files:** `room.gltf` with `room.bin`, `crate.gltf` with `crate.bin`, and four PNGs beside
  them;
- **The room:**
  - a floor whose checker repeats six times;
  - four single-sided brick walls, one mesh placed four times, facing inward;
  - a table whose top carries its four legs as child nodes;
  - a crate and a mirrored copy of it (scale `(-1, 1, 1)`);
  - a potted plant whose crossed leaf quads are alpha-masked and double-sided;
  - a glass pane that blends.

Each box face bakes a tone into `COLOR_0`, because the unlit model would otherwise draw a box as
one flat silhouette. The crate's texture carries an F on each face, so a mirrored crate reads
mirrored. The script uses no clock and no `random`; rerunning it rewrites the same bytes.

**The package:**
- **An import record for the room.** It maps the glTF material `Glass` to an authored
  `sandbox3d:materials.glass`. That is §6.2's mapping in use, and it gives the reload test a
  material with a name.
- **`sandbox3d:materials.crate_painted`** tints the crate's generated texture
  (`sandbox3d:models.crate.texture0`). One crate of the grid wears it as a slot override.
- **`sandbox3d:config`:** §9's model IDs, orbit rate and grid, plus four fields §9 did not
  name. `orbit_radius` and `orbit_height` place the camera. `crate_override` names the
  override material. `crate_clearance` says how close to the centre a crate may not stand,
  which keeps the room's size out of the sample's code. `slab_radians_per_second` is gone with
  the slab. Every field is validated with a fallback, as M19's were.
- **The manifest's summary** now describes the scene.

**The sample:**
- **Drawing:** the room and a 9 × 9 grid of crates (72 placed, with the three by three inside
  the walls left empty) are drawn by content ID through `render3d.Content`. M19's cube still
  spins on the table from code with a code-made material; the slab and floor meshes are gone.
- **Camera:** it orbits at the fixed step. From outside, the near walls' backs are culled, so
  the room is seen into.
- **Overlay:** the line shows the backend, sample count, draws, culled, blended and frame time.
- **Reload:** `refresh` calls `Content.contentChanged` whenever the engine's content generation
  moves, then follows any change to the configured IDs.
- **Command line:** `--cull=on|off` sits beside `--msaa`.
- **Imports:** the sample still imports no `rhi`.
- **Tests:** they pin the options and the grid's placement.

**A Step 6 defect, fixed.** `Content.deinit` destroyed its materials and freed its models
without releasing the texture and mesh references they held, so `unloadWith` warned at every
exit that fourteen assets were "still held". Teardown now releases each reference first. No
test observes it, because `unloadWith` removes the entries and their counts together. The
evidence is the sample's clean exit, headless and windowed.

**§11.8, reload, in a macOS/Metal dev run.** Each edit was made to the source, followed by
`zig build install` while the sample ran, and each was captured:
- **The checker PNG** changed to green squares. The texture reloaded, and the material that
  binds it was rebuilt in place.
- **The glass's `base_color`** in the `.fdt` changed to a denser red. The package reloaded,
  and the pane changed.
- **The crate in `room.gltf`** moved across the room, and the part followed.
- **A truncated `room.gltf`** failed `fpack` with `models/room.gltf: error: JSON document is
  invalid or over its limits: InvalidJson`. The running sample kept drawing what it had, and
  exited 0.

§11 names `room.glb`; the scene is a `.gltf`, and the equivalent file was corrupted. The design
said "a material's `base_color`" and the pane was used because it is always in view; the
crate override material is off-screen for much of the orbit.

**§11.5, determinism.** From the same sources, `sandbox3d.fpk` and all 19 installed files under
`content/sandbox3d/` hash identically on macOS (ReleaseSafe, Metal) and on Windows (ReleaseSafe,
Vulkan). The 19 files are the sources and every generated `.fmesh`.

**§11.9, external evidence.**
- **Khronos sample models:** 21 of `glTF-Sample-Assets`' `.glb` files were fetched at
  verification time and never committed. Each was imported as its own package after a
  lowercase rename, because derivation transforms nothing and `BoxTextured.glb` is refused as an
  ID segment.
  - **15 import:** Avocado, Box, BoxInterleaved, BoxTextured, BoxVertexColors, Duck, Lantern,
    MetalRoughSpheres, MultiUVTest, NegativeScaleTest, OrientationTest, TextureCoordinateTest,
    ToyCar, VertexColorTest and WaterBottle.
  - **Refused by name:**
    - AlphaBlendModeTest, CesiumMilkTruck and DamagedHelmet: a JPEG image ("re-export it as
      PNG");
    - BrainStem and Fox: `JOINTS_0`, until M24;
    - TextureSettingsTest: disagreeing `wrapS` and `wrapT`.
  - **Warnings,** every one a kind §6.5 names: lit material fields, `TANGENT`, cameras, skins,
    animations, extensions used but not imported, and an ignored `KHR_texture_transform`.
  - AnimatedCube and Suzanne have no `.glb`.
- **Blender:** Blender 5.1.2 re-exported `room.gltf` as a `.glb` with embedded images. It
  imported with no diagnostic, to 8 meshes and 4 generated PNGs.

**The runnable result, macOS/Metal** (ReleaseSafe, relocated install, Apple M5, 60 Hz display):
- **Captures:**
  - at 4× and at 1×, and the 1× edges stair-step where the 4× ones do not;
  - the mirrored crate's F is reversed;
  - the plant's leaves are cut out, and the glass pane blends over the floor;
  - the overlay read 59 draws, 29 culled, 1 blended.
- **Window handling:** System Events resized the window to 900 × 560 and to 1400 × 800 (fitted
  to 1375 × 800), each captured. Minimised, it left the on-screen list, and it was restored and
  captured. All 1,500 frames exited 0.
- **Pacing, last 240 frames, 4×:**

  | Culling | Draws | Culled | Median | p95 | `render.world` median |
  | --- | --- | --- | --- | --- | --- |
  | On | 62 | 26 | 16.662 ms | 17.274 ms | 0.180 ms |
  | Off | 88 | 0 | 16.693 ms | 17.546 ms | 0.184 ms |

**The runnable result, Windows/Vulkan** (ReleaseSafe, relocated install, Arc A750):
- **Setup:** Zig and the SDK off `PATH`, `APPDATA` in a scratch root, and a desktop session
  through an interactive scheduled task.
- **Validation:** the layer reported core, synchronization, stateless, object lifetime, thread
  safety and handle wrapping enabled. It logged **no errors and no warnings**.
- **Captures:** at 4× and at 1×, 1280 × 720. The scene matches macOS's, mirrored crate
  included.
- **Window handling:** `SetWindowPos` gave a 944 × 561 client, which was captured. `ShowWindow`
  minimised it: iconic, 103 frames skipped. It restored and was captured again. `WM_CLOSE` ended
  it with exit 0.
- **Pacing, last 240 frames, 4×:** with validation, median 16.666 ms and p95 16.668 ms.
- **Culling on and off, with every loader layer disabled** (which also shows the install needs
  nothing from the SDK):

  | Culling | Draws | Culled | Median | p95 | `render.world` median |
  | --- | --- | --- | --- | --- | --- |
  | On | 58 | 30 | 16.666 ms | 16.667 ms | 0.083 ms |
  | Off | 88 | 0 | 16.666 ms | 16.667 ms | 0.090 ms |

**Culling's measured value is small here, and that is recorded, not argued away.** With about
90 draws, turning culling off costs a few microseconds of CPU, and the display rate hides the
rest. The equivalence readbacks (Steps 6 and 7) prove it changes no pixel. The scene is too
small to show what it saves.

**Guards verified by mutation,** each restored byte for byte:
- clearing a cell when either axis is inside the clearance failed the grid test;
- ignoring `--cull=off` failed the options test.

`dist` was not staged. It stages only `room`, `sandbox` and the editor, and none of their
content or asset kinds changed.

**The bar:**
- **macOS:** **1,822 of 1,823 headless tests** (the existing skip; **1,903 declared**) and
  **1,830 of 1,841 on `-Drhi=metal`**, with fmt, all four `check` variants and the three
  thirty-frame samples. `sandbox` and `room` still pass theirs. The Linux and Windows Vulkan
  `check` lines passed too.
- **Windows:** from the `Foundry-m20` worktree with every file differing from `origin/main`
  overlaid and hash-checked, `zig build test -Drhi=vulkan` passed **126 of 126 steps, 1,854 of
  1,873 (19 skips)**, with validation required and no validation message. Step 7's intermittent
  timing tests passed in this run.

Step 9, the close, is next.

## Resolution — Step 9: M20 closed (2026-09-29)

**The exit condition holds as `3d.md` §10's M20 row writes it:**
- **Imported:** a glTF file becomes Foundry's own representations. Its runtime mesh, textures,
  materials and model are records and `.fmesh` files.
- **Nothing downstream knows it was glTF:** an imported quad and a code-built one match in
  `.fmesh` bytes, in record values and in pixels, on Metal and on Vulkan.
- **Refused, not crashed:** a malformed file is refused with a diagnostic naming the object.
  This is proved by every named refusal, the truncation and byte-flip sweep, and a corrupt
  glTF that failed a live build while the sample kept drawing.
- **The runnable result:** a glTF-authored scene from a content package, drawn textured,
  relocated on both platforms and hot-reloaded (Step 8).

**§10, Linux: compile only, confirmed.** None of its three triggers fired:
- **No per-backend tolerance:** Windows' mip readbacks selected Metal's levels exactly (Step 3).
- **No driver named:** no validation message named the driver. Step 7's one refusal named a
  core 1.3 feature the backend had not enabled.
- **No presentation code touched:** nothing changed presentation, formats or the swapchain.
  Step 7's device change enables a feature Vulkan 1.3 requires of every device, Mesa's included.

The Linux Vulkan `check` and `vulkan-check` lines built at every step that changed Vulkan code.
No machine was provisioned.

**Contract discrepancies, resolved in their originating documents:**
- **`3d.md` §1, §2, §3, §4 and §10:** the importer is `author`'s package compiler, hosted by
  `fpack` and the editor. Mip chains are built on the CPU at load, with measured load time (and
  compressed formats) as the trigger to move them. `asset` holds the representations and
  `render3d` their loaders. The status line and the M20 row say M20 is done.
- **ADR-0053:** a dated note says its "`fpack`" names that compiler; the decision is unchanged.
  ADR-0053 and ADR-0055 record their implementation.
- **`render3d.md` §5 and §6:** the widened stream table and `.fmesh` point to §3 here. Group 2
  is the material's. A draw requires a material, blended draws sort last, and a negative
  determinant flips the front face.
- **`assets.md` §9:** its third open question, asset dependencies, is answered. The composing
  consumer acquires what a record references, and `acquireWith`/`unloadWith` exist.
- **`rhi.md` §12:** GPU mipmap generation stays out. M20's chains upload through the existing
  path.

**Also updated:**
- `CLAUDE.md` §9's 3D row and §4.3's `render3d` line. ADR-0055 was already in §4.1.
- The roadmap, the design index and `PROJECT_STATE.md`.
- `AGENTS.md`'s bar is unchanged. Step 7 added one sentence: every Vulkan test binary requires
  validation.

**What M20 leaves open is §13's list,** unchanged:
- per-submesh bounds;
- a texture shared between the renderers;
- anisotropic filtering;
- a registered mesh loader and the ABI (M25);
- stable names for generated meshes and textures.

The intermittent Windows timing failures Step 7 recorded passed in Step 8's run and were never
M20's. A later Windows timing measurement should still check the PC's clock first.

This step changed documents only, and the bar passed on them unchanged: Step 8's numbers stand
for the code (**1,822 of 1,823 headless**, **1,830 of 1,841 on Metal**, **1,854 of 1,873 on
Windows/Vulkan**). M20 is tagged `m20`. M21's design is next, and it has not been started.
