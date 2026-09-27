# Design: M20 — Meshes: runtime formats, glTF import, textures with mips, materials and culling

**Status:** Accepted 2026-09-27 when the owner requested Step 1. Step 1 of nine is complete;
Step 2 has not begun. §14 records the accepted choices.
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
  roughness, normal, occlusion and emissive, as its design names them) with defaults. **A model
  ignores a field it does not read, and says so once**: an unlit material with a roughness is not
  an error, and its record still loads on an engine that draws it lit. A generic parameter list
  waits for content-owned shading models (ADR-0015's trigger), and it is additive then.
- **`base_color` is linear**, as glTF's `baseColorFactor` is, and as every colour the renderer
  takes is. The unlit model draws `base_color × texture × vertex colour`, where an absent texture
  or colour stream contributes 1.
- **The texture must be sRGB.** A linear texture named here is refused, not reinterpreted.

### 5.2 `foundry:model`

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
bytes and `.fdt` text.

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

### 6.3 What an import generates

For a model with ID `M`, every generated ID is `M` plus one segment, numbered by the glTF
array it came from (ADR-0055):

| glTF | Generated | ID | File under `--assets-out` |
| --- | --- | --- | --- |
| mesh *i* | `foundry:mesh` | `M.mesh<i>` | `<source dir>/<stem>/mesh<i>.fmesh` |
| material *i*, unless mapped | `foundry:material` | `M.material<i>` | — |
| image *i*, if embedded | `foundry:texture` | `M.texture<i>` | `<source dir>/<stem>/texture<i>.png` |
| image *i*, if an external file in the package | `foundry:texture` | `M.texture<i>` | — (its `source` is that file) |
| the default scene | `foundry:model` | `M` | — |

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
- **A required extension is refused unless it is supported.** M20 supports one,
  `KHR_materials_unlit`, which confirms the material is unlit. An extension that is used but not
  required is ignored with a warning.

**Geometry:**
- Primitive mode 4, a triangle list. Points, lines, strips and fans are refused.
- `POSITION` is required. `NORMAL`, `TEXCOORD_0`, `TEXCOORD_1` and `COLOR_0` are imported.
  `TANGENT` is omitted with a warning until M22. `JOINTS_n` and `WEIGHTS_n` are refused until
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
- `pbrMetallicRoughness.baseColorFactor` and `baseColorTexture`, `alphaMode`, `alphaCutoff` and
  `doubleSided` map to §5.1's fields. Metallic, roughness, normal, occlusion and emissive are
  ignored with one warning per material until M22.
- A texture reference with `texCoord` other than 0 is refused, because the unlit model samples
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
