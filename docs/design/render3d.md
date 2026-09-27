# Design: M19 — Depth: 3D math, depth, multisampling and the `render3d` skeleton

**Status:** Accepted 2026-09-27, when the owner asked for Step 1. **Steps 1–3 are done**
(`core`, the RHI contract on the null backend, and Metal). Steps 4–8 have not begun. Each step stops with its Resolution, as every milestone's has since M13.
**Date:** 2026-09-27
**Baseline:** `6fc69d7`, after tag `m18`. M0–M18 are complete, and 3D is decided.
**Decisions:**
- ADR-0048 (conventions), ADR-0052 (forward first) and ADR-0053 (assets are not the renderer)
  constrain this design.
- ADR-0049 (shading models) and ADR-0050 (hierarchy) are M20's and M21's.
- It proposes [ADR-0054](../adr/0054-vertex-semantics-are-fixed-slots.md): vertex semantics
  are fixed shader slots.

This is `render3d`'s design document, as `render2d.md` is `render2d`'s. M19 writes its first
sections. Later milestones extend it, or write their own and link them here.

## 1. Purpose and boundary

M19 is `3d.md` §10's first milestone:
- **Runnable result:** intersecting spinning meshes built in code, depth-tested and
  multisampled, in the new 3D sample.
- **Exit condition:** every §2 convention of `3d.md` is expressed once in code and pinned by a
  test. Draw order no longer decides what is visible.

**What M19 builds:**
1. `core`'s rotation, transform and matrix additions, and the world axes (§3);
2. the RHI's multisampling, resolve and texture readback, on all three backends (§4);
3. the in-memory runtime mesh in `asset` (§5);
4. a `render3d` skeleton: camera, targets, mesh residency, submission, sorting, and one unlit
   vertex-colour pipeline (§6);
5. a frame of two passes in `app`, the 3D world then `render2d`'s overlay (§7);
6. `samples/sandbox3d` (§8).

**What it does not build**, and whose it is:
- mesh, model and material files, and glTF import (M20);
- textures on meshes, `foundry:material`, the shading-model registry, and frustum culling (M20);
- entities with transforms, and the hierarchy (M21);
- light, normals in a shader, shadows and HDR (M22);
- anything in the public ABI (M25). **`render3d` exposes nothing through the ABI in M19** — the
  answer CLAUDE.md §5 asks every new subsystem for. `abi` does not import it.

## 2. What exists

The RHI anticipated more of this than `3d.md` §4 assumed. On all three backends, today:
- **Depth works as a type and as a command.** `DepthStencilState` (format, write, compare) is on
  the pipeline, `DepthAttachment` is on the pass, and `depth32_float` maps to
  `MTLPixelFormatDepth32Float` and `VK_FORMAT_D32_SFLOAT`. The null backend already refuses:
  - a pipeline wanting depth in a pass without it;
  - a depth format used as a colour target;
  - a colour format used as a depth target;
  - a depth attachment without `depth_stencil` usage.
  
  **No pixel has ever been depth-tested and checked.** M19 does that.
- **There is no multisampling.** Textures and pipelines have no sample count, and
  `StoreAction` is `{store, discard}`, with a comment reserving `resolve`.
- **There is no way to read a texture back.** `MemoryIntent.readback` exists, and names
  screenshots as its purpose, but no command copies a texture into a buffer. The headless targets
  already allow copying out: Metal's has `copy_src`, and Vulkan's rests in the transfer-source
  layout.
- **`core.math`** has `Vec2`–`Vec4` and `Mat4` with `mul`, `translation`, `scaling` and
  `rotationZ`. Its header says it "does not know which way is up", and that quaternions arrive
  with 3D.
- **`app.renderFrame`** opens exactly one pass, on the surface, cleared, and ends it in `present`.

## 3. `core`: the conventions, once, in code

`core/math.zig` stays free of I/O and allocation. Every item below is used in M19, or it is the
single expression of a convention `3d.md` §2 locks. The exit condition needs both.

**The header is revised** to say what changed: `core` now knows which way is up, because the
world axes are a compatibility decision (ADR-0048) that `physics3d` and `render3d` must share,
and `core` is their only common ancestor. The projection still stays out, for the existing
reason: it depends on `rhi.clip_space`.

**Axes.** `Vec3.right` (+X), `Vec3.up` (+Y) and `Vec3.forward` (−Z). Their negations are
spelled as negations, never as extra constants.

**`Quat`** — `extern struct { x, y, z, w: f32 }`, Hamilton, stored with `w` last:
- `identity`; `fromAxisAngle(axis, radians)`, which normalises the axis, so that a zero axis
  gives the identity;
- `mul(a, b)`, which applies `b` first, then `a`, as `Mat4.mul` does;
- `rotate(q, v)`, which is `q · v · q⁻¹`; `conjugate`, which is the inverse of a unit
  quaternion; `dot`; `normalize`;
- `slerp(a, b, t)`, which takes the shorter arc: it negates `b` when `dot(a, b) < 0`. It falls
  back to a normalised linear blend when the angle is too small for `sin` to be stable;
- `lookRotation(forward, up) ?Quat`: the rotation that turns −Z to `forward` and keeps +Y as
  close to `up` as it can. It is null when either input is zero or non-finite, or when the two
  are parallel;
- **`validated(x, y, z, w) error{InvalidRotation}!Quat`**: the one entry point for a rotation
  from outside, whether content, a save, a mod or the ABI. It refuses a non-finite component,
  and a length outside `1 ± 1e-3`. It returns the normalised value.
  - **The tolerance is deliberately loose.** It exists to reject garbage, not to judge
    precision. `(0, 0.707, 0, 0.707)`, written by hand, is accepted. `(0, 0, 0, 0)`,
    `(1, 1, 1, 1)` and a NaN are refused.
  - Nothing is repaired silently: a stored rotation is always the normalised result of an
    accepted one (I8).
- `approxEql(a, b, eps)` treats `q` and `−q` as equal, because they are the same rotation.

**`Transform`** — `extern struct { translation: Vec3, rotation: Quat, scale: Vec3 }`, always
local:
- `identity`;
- `toMat4()`, which composes `T · R · S`;
- `isValid()`: every component is finite and the rotation is unit to `1e-3`.

  Any finite scale is valid, including zero and negative. A zero or negative scale collapses or
  reflects a mesh, and that is a legitimate thing to author. What a singular or reflected parent
  means for re-parenting is `3d.md` §7.1's, in M21.

**`Mat4` additions:**
- `rotationX` and `rotationY`, beside the existing `rotationZ`;
- `fromQuat(q)`;
- `trs(t, r, s)`, which is `Transform.toMat4`'s arithmetic;
- `mulPoint(m, p)` (`w = 1`) and `mulDirection(m, d)` (`w = 0`);
- `determinant`;
- `inverse(m) ?Mat4`, a general cofactor inverse. It is null only when the determinant is
  exactly zero or the result is not finite. **A tolerance is the caller's decision.** `3d.md`
  §7.1 states its own (`ε_det`), relative to the matrix's scale. A fixed epsilon here would be
  wrong for a matrix in millimetres and for one in kilometres alike;
- `lookAt(eye, target, up) ?Mat4`: a **view** matrix, the inverse of the rigid pose at `eye`
  with rotation `lookRotation(target − eye, up)`. It is null where `lookRotation` is;
- `approxEql(a, b, eps)`.

**What stays out of `core`:** projection (§6.3); normal matrices, which M22 adds when a shader
reads a normal; `nlerp`, Euler conversion and swing-twist, until a consumer exists. Euler
angles are display-only by ADR-0048, and the editor is their first consumer.

**Tests: the convention tests, one per locked rule.**

| Convention (`3d.md` §2) | What the test asserts |
| --- | --- |
| Right-handed | `cross(right, up) == back`, that is `−forward`, exactly |
| −Z forward | `lookRotation(forward, up)` is the identity. `rotate(q, forward)` equals the direction `lookRotation` was given, for eight directions around a sphere |
| Right-hand rule | `fromAxisAngle(up, π/2)` turns `forward` (−Z) to −X, and `rotationY(π/2)` does the same to the point |
| Column vectors, column-major | `translation(t).cols[3]` holds `t`, and `mulPoint` moves a point by it |
| Same composition order | For random unit `a` and `b`: `fromQuat(mul(a, b)) ≈ mul(fromQuat(a), fromQuat(b))`, and `rotate(mul(a, b), v) ≈ rotate(a, rotate(b, v))` |
| `T · R · S` | A point at `(1,0,0)` under scale 2, a quarter turn about +Y and a translation of `(0,0,5)` lands at `(0,0,3)`, where any other order lands elsewhere |
| Shorter arc | `slerp(a, −b, t) ≈ slerp(a, b, t)`, and the midpoint's angle to `a` is half the smaller angle |
| Rejected, not repaired | `validated` refuses zero, NaN, infinities and a length of `1 ± 0.01`. It accepts `1 ± 0.0009` and returns unit length |
| Inverse | `mul(m, inverse(m)) ≈ identity` for random TRS, including negative scale. A zero-scale matrix gives null |
| Look-at | `lookAt(eye, target, up)` maps `eye` to the origin and `target` to the negative Z axis. It equals `inverse(trs(eye, lookRotation(target − eye, up), one))` |

Reversed-Z's mapping is a projection test, so it lives in `render3d` (§6.3).

## 4. The RHI widens

Every item lands on the null, Metal and Vulkan backends in the same step as its validation, as
`3d.md` §4 requires. The interface grows by one function (40 → 41), and `interface.zig`'s
count test moves with it.

### 4.1 Depth: proved, and one explicit refusal

Nothing is added to depth's types. M19 proves them with pixels (§9). One gap is closed. Vulkan
guarantees depth-attachment support for `D32_SFLOAT` **or** `X8_D24_UNORM_PACK32`, not both.
So `createTexture` already checks format features, and `render3d.init` answers
`error.DepthFormatUnsupported` if `depth32_float` is refused. **There is no fallback to 24-bit
depth.** Reversed-Z's precision depends on a floating-point buffer (ADR-0048). A 24-bit
reversed-Z buffer is not the same convention with less precision; it is a different
precision profile, and silently choosing it would make a scene's z-fighting depend on the
driver. Apple GPUs support `depth32_float`, and desktop Vulkan drivers generally do. A
machine that does not is recorded, not accommodated.

The RHI's default depth clear stays `1.0`, the conventional value. `render3d` clears to `0`,
which is reversed-Z's far plane. The RHI does not hold one renderer's convention.

### 4.2 Multisampling

**The types:**
- `TextureDesc.sample_count: u32 = 1`;
- `RenderPipelineDesc.sample_count: u32 = 1`;
- `ColorAttachment.resolve: ?ResolveTarget = null`, where
  `ResolveTarget = struct { texture, initial_state = .undefined, final_state = .render_target }`.

**The set of counts is exactly `{1, 4}`.** Vulkan's required limits make
`framebufferColorSampleCounts` and `framebufferDepthSampleCounts` include 4 on every
conformant device, and every Apple GPU supports 4. Two is useless next to four, and eight is
optional everywhere. A count outside the set is `InvalidDescriptor`. Vulkan still checks the
format's own sample counts with `vkGetPhysicalDeviceImageFormatProperties`, and a format
without 4× answers `UnsupportedFormat`.

**Resolve is a field of the attachment, not a store action.** The existing comment reserved
`StoreAction.resolve`. The design takes the other shape, for one reason: storing and resolving
are independent in both APIs:
- Metal has `MultisampleResolve` and `StoreAndMultisampleResolve`;
- Vulkan sets `storeOp` and `resolveMode` separately.

With a field, `store = .discard, resolve = X` is the common case, and `store = .store,
resolve = X` is the rare one. Neither needs a combined enum value. `StoreAction` stays
`{store, discard}`, and its comment and `rhi.md` §8 and §12 are corrected.

**The rules**, which the null backend enforces and whose misuse the Metal and Vulkan tests
refuse:
1. A multisampled texture has `render_target` or `depth_stencil` usage, and neither `sampled`,
   `copy_src` nor `copy_dst`. It has one mip level.
2. Every attachment of a pass has the same sample count. So does every pipeline bound in it.
3. A resolve target:
   - is single-sampled;
   - has `render_target` usage;
   - matches its source's format and size;
   - is not itself an attachment of the pass.
   
   Its source is multisampled. Resolving a single-sampled attachment is refused.
4. A resolve target's states are tracked and checked like an attachment's. It may be the
   surface, ending in `present` or `render_target`.
5. Depth is never resolved in M19: `DepthAttachment` has no resolve target. *(Step 2 dropped
   "a multisampled depth attachment ends in `discard`": storing samples is legal, because a later
   pass may load them.)*

**Backend mapping:**

| | Metal | Vulkan |
| --- | --- | --- |
| Texture | `MTLTextureType2DMultisample`, `sampleCount` | `VkImageCreateInfo.samples` |
| Pipeline | `rasterSampleCount` | `VkPipelineMultisampleStateCreateInfo.rasterizationSamples` |
| Resolve | `resolveTexture`, and the store action `MultisampleResolve`, or `StoreAndMultisampleResolve` when `store` | `VkRenderingAttachmentInfo`: `resolveMode = AVERAGE`, `resolveImageView` and `resolveImageLayout` |

### 4.3 Reading a texture back

`CommandBuffer.copyTextureToBuffer(TextureToBufferCopy)`, the mirror of `copyBufferToTexture`:
- **The descriptor:** `src` and `src_mip_level`, `src_origin`, `size`, `dst` and `dst_offset`,
  and `dst_bytes_per_row`, where 0 means tightly packed.
- **The rules:**
  - the source has `copy_src` usage, is in the `copy_src` state, is single-sampled, and has a
    colour format;
  - the destination has `copy_dst` usage;
  - the region fits both resources;
  - the row pitch covers a row and is a multiple of the texel size;
  - the offset is a multiple of 4 and of the texel size, which both APIs require *(Step 3
    corrected "of 4", which was Vulkan's rule alone)*.

**When the bytes are valid:** after `waitIdle`, and not before. M19 adds no finer completion
query, because its only consumers are tests and a screenshot. A game that reads back every
frame would need one, and would be the reason to add it.

**Why it goes in the RHI, not in a test helper:** from M19 on, every renderer claim is proved
by pixels. A white-box read of one backend's internals would prove that backend, not the
contract.

### 4.4 Not in M19

Each of these waits for the stated trigger:

| Left out | Its trigger |
| --- | --- |
| Memoryless or lazily allocated attachments (`MTLStorageModeMemoryless`, `LAZILY_ALLOCATED`) | Memory for a 4× target measured as a problem on a real machine |
| Depth resolve | A pass that samples depth |
| Stencil | A pass that uses it |
| Alpha-to-coverage | M20's `mask` alpha mode, if measurement prefers it to discard |
| Sample counts above 4 | A measured quality need |
| Multisampling in `render2d` | Its overlay never needs it (§7) |

## 5. The in-memory runtime mesh (`asset`)

`3d.md` §3's row 3, in memory, with no file format yet. `asset/mesh.zig` holds it. M20 gives it a
versioned binary form (I8), and that loader produces this same value. Code that builds a mesh
produces it too.

```zig
pub const Semantic = enum(u8) { position, normal, tangent, uv0, uv1, color, joints, weights };

pub const Stream = struct { semantic: Semantic, format: VertexFormat, bytes: []const u8 }; // asset's enums, not rhi's
pub const Submesh = struct { first_index: u32, index_count: u32 };
pub const Aabb = extern struct { min: Vec3, max: Vec3 };

pub const Mesh = struct {
    vertex_count: u32,
    streams: []const Stream,        // at most one per semantic
    index_format: IndexFormat,      // uint16 or uint32
    indices: []const u8,
    submeshes: []const Submesh,     // at least one
    bounds: Aabb,                   // local space; contains every position
};
```

- **Streams are separate, one buffer per semantic, not interleaved.** A shading model reads the
  streams it needs, and ignores the rest without a stride to skip. Eight semantics fit exactly
  in the RHI's eight vertex buffers, which is ADR-0054.
- **`asset` does not import `rhi`.** `asset` is L2 beside `rhi`, and the runtime mesh is
  row 3, which knows nothing of the GPU (ADR-0053). The vertex and index formats are `asset`'s
  own enums, and `render3d` maps them to the RHI's. That mapping is one of the seams ADR-0053
  permits.
- **A `Mesh` is a view.** Its slices borrow from whoever built it: the sample's arrays in M19,
  the loader's allocation in M20. `render3d` copies at upload and keeps nothing.
- **Triangle lists only,** with counter-clockwise front faces (ADR-0048).

**`Mesh.validate()` refuses, and never repairs.** The value is untrusted from M20 on, because a
mod supplies it. Each refusal has a named error:
- no position stream, or a semantic given twice;
- a format the semantic does not allow. In M19 the table allows `float32x3` for position and
  `unorm8x4` for colour, which is linear, as glTF defines vertex colour. Every other semantic is
  refused until the milestone that reads it widens the table: M20 for UVs and normals, M22 for
  tangents, M24 for joints and weights;
- a stream whose length is not `vertex_count × size`, or a vertex count of zero;
- `uint16` indices with more than 65,536 vertices, an index count that is not a multiple of 3,
  or an index at or beyond `vertex_count`;
- a submesh outside the index range, an empty submesh, or no submesh at all;
- a non-finite position, or bounds that fail to contain a position.

`Mesh.computeBounds` exists for builders. A loaded mesh's stored bounds are checked, never
recomputed in place of the check.

## 6. `render3d`: the skeleton

### 6.1 The module

`L3 render3d -> core, rhi, asset`, beside `render2d` and `scene`, and declared in `build.zig`
so layering stays a build error (I7). `app` (L4) imports it. `debug` does not yet, and `abi`
does not until M25. CLAUDE.md §4.3's graph gains the line in the step that adds the module.

### 6.2 The API, in `render2d`'s shape

```zig
pub const Config = struct { frames_in_flight: u32 = 2, sample_count: u32 = 4 };
pub const Renderer = struct {
    pub fn init(gpa, device: *rhi.Device, surface_format, config) Error!Renderer;
    pub fn deinit(self) void;

    pub fn createMesh(self, mesh: asset.Mesh, label: []const u8) Error!MeshHandle; // validates, uploads
    pub fn destroyMesh(self, MeshHandle) void;          // handle dies now, GPU objects retire (ADR-0035)

    pub fn begin(self, view: FrameView) Error!void;     // camera, target size in pixels, clear colour
    pub fn drawMesh(self, draw: MeshDraw) Error!void;   // { mesh, submesh = 0, world: Mat4 }
    pub fn plan(self) Error!void;                       // sort
    pub fn prepare(self, cmd, frame) Error!void;        // frame uniforms; targets for this size
    pub fn passDesc(self, frame, overlay: bool) rhi.RenderPassDesc; // §7
    pub fn record(self, pass) Error!void;
    pub fn frameStats(self) Stats;                      // draws, triangles, pipeline binds
};
```

A draw names a handle, a submesh index and a matrix, never a pointer (I1). **M19's draw names
no material.** Every draw uses the unlit vertex-colour pipeline, and a mesh without a colour
stream is refused at `drawMesh` with `error.MissingStream`. M20 adds `material` to `MeshDraw`
as a required field, and the unlit model then reads vertex colour, base colour and a texture.
Until then this is a Zig API with one consumer, the sample, not the ABI. Adding the field is a
compile error in exactly one place, which is the intended cost.

### 6.3 Camera and projection

`Camera = struct { position: Vec3, rotation: Quat, vertical_fov: f32, near: f32, far: f32 }`:
- **A rigid pose.** A camera has no scale, and ADR-0048 has it look down its local −Z. The view
  matrix is `R⁻¹ · T⁻¹`, computed exactly from the conjugate and the negated position rather
  than by a general inverse.
- **Validated at `begin`** (`error.InvalidCamera`):
  - the rotation is unit;
  - `0 < vertical_fov < π`;
  - `0 < near < far`;
  - every field is finite;
  - the target size is non-zero.
- **Reversed-Z perspective,** right-handed, into `[0, 1]` depth. With `f = 1 / tan(fov / 2)`
  and aspect `a = width / height`:

  ```
  | f/a  0      0             0          |
  | 0    f      0             0          |
  | 0    0   n/(F−n)     n·F/(F−n)       |
  | 0    0     −1             0          |
  ```

  A point at `z = −n` maps to depth 1, and one at `z = −F` maps to 0. Depth clears to 0 and
  compares `greater_equal`. `render3d` reads `rhi.clip_space` and refuses at compile time any
  convention but `y up, [0, 1]`, which is every backend's. `render2d` switches on the same
  value, but a second 3D variant would be dead code.
- **The far plane is finite.** An infinite reversed-Z far plane is simpler and slightly more
  precise. It is not chosen, because M20's frustum culling and M22's shadow fitting both want a
  bounded frustum. A scene that needs the horizon can ask for it later.
- **Tests:**
  - near maps to 1 and far to 0;
  - depth decreases strictly with distance at twenty points;
  - the midpoint of `[n, F]` lands near 0, because precision goes to the near range;
  - +X view maps to +X clip, and +Y view maps to +Y clip;
  - a point behind the camera has `w < 0`.

### 6.4 Bindings: what every 3D pipeline shares

- **Vertex buffers: slot = location = semantic** (ADR-0054). Position is buffer 0 and
  `location(0)`, normal is 1, tangent 2, UV0 3, UV1 4, colour 5, joints 6 and weights 7. A
  shading model declares only the locations it reads.
- **Group 0, per frame:** one uniform block holding `view_projection` (`P · V`, 64 bytes), in a
  per-slot ring, written in `prepare`. Groups 1–3 are unused in M19. Group 2 (per material)
  becomes M20's, following `rhi.md` §9's ordering.
- **Inline constants, per draw:** the world matrix, 64 bytes of the 128. The vertex shader
  computes `clip = view_projection · world · position`. M22 adds the normal transform, and the
  remaining 64 bytes or a per-draw group hold it.

### 6.5 The unlit vertex-colour pipeline

- **Written by hand twice** (ADR-0049): `render3d/shaders/unlit_color.metal`, and
  `unlit_color.vert.glsl` with `.frag.glsl`. They are compiled by the existing `metalLibrary`
  and `vulkanShaderStage` build steps, and embedded (ADR-0019).
- **The fragment writes the interpolated linear vertex colour.** The `_srgb` target encodes it,
  so linear-in and sRGB-out holds from the first pixel (ADR-0048).
- **Its state:** back-face culling with counter-clockwise front faces; depth `greater_equal` with
  writes on; no blending; the renderer's sample count.
- **It is not a registered shading model yet.** The registry is M20's (`3d.md` §10.1). M20
  absorbs this pipeline into that registry's unlit entry, and M19 names no content ID for it.

### 6.6 Targets

- **`render3d` owns its multisampled colour target and its depth target.** The colour target
  has the surface format. Both have the configured sample count and the size `FrameView` gives
  in pixels. `prepare` rebuilds them when the size changes, and the old ones retire under
  ADR-0035 while frames are in flight.
- **At a sample count of 1** there is no colour target of its own. The pass draws straight into
  the surface, with depth.
- **The depth target is never stored,** and the multisampled colour target is discarded after
  its resolve. Discarding them is the store actions' purpose on a tiler (`rhi.md` §8).

### 6.7 Submission, sorting and statistics

- **`drawMesh` validates at the call:**
  - the handle is live;
  - the submesh is in range;
  - the world matrix is finite;
  - the mesh has the streams the pipeline reads.
  
  A refused draw records nothing.
- **`plan` sorts the opaque draws front to back** by the view-space depth of each draw's world
  bounds centre. Ties break by submission index, so the order is a function of the inputs alone
  (I9). M19 has no transparent draws.
- **The sort is an optimisation, never correctness.** The readback test (§9) uses meshes that
  pass through each other, which no ordering of whole draws can resolve. Only the depth test
  can.
- **`Stats`** counts draws, triangles and pipeline binds, as outputs only.

### 6.8 Mesh residency

`createMesh`:
1. validates the mesh;
2. makes one `device_local` vertex buffer per stream, and an index buffer;
3. uploads them through `upload` staging, in a command buffer of its own outside any frame.
   That is how `render2d` uploads a texture.

`destroyMesh` kills the handle at once. The buffers retire when the work that could use them
has finished, so destroying a mesh with frames in flight is legal. `render3d` owns this
residency, as `render2d` owns its textures (ADR-0052).

## 7. The frame: the world, then the overlay

**The engine owns the frame** (`render2d.md` §3), so `app` gains a second entry point.
`renderFrame` is kept unchanged for 2D-only hosts:

```zig
pub fn renderScene(self, options: FrameOptions, world: anytype, overlay: anytype) !void
```

- **The world recorder** provides `plan` (optional), `prepare`, `passDesc` and `record`, like
  `render2d`'s, and supplies its own attachments. `render3d.Renderer` is one; `app` still names
  no renderer type.
- **The overlay** is a `render2d`-shaped recorder, or `null`.

**One command buffer, two passes, in ADR-0052's fixed order:**
1. **World.**
   - Colour: the multisampled target, cleared, and discarded after it resolves into the
     surface. The surface arrives `undefined` and leaves as `render_target`, or as `present` if
     there is no overlay.
   - Depth: cleared to 0 and discarded.
2. **Overlay.** It loads the surface, draws `render2d`'s single-sampled, depth-less pipelines,
   and leaves the surface in `present`.

**Why two passes rather than drawing the overlay inside the world pass:** a pipeline's
attachment formats and sample count must match its pass, as Metal checks and rule 2 restates.
One pass would need a multisampled, depth-aware variant of every `render2d` pipeline, and a UI
gains nothing from either. The price is one load of the surface into tile memory. That is
measured in Step 7, and it is the trigger for revisiting this.

**Profiling:** `render.record` splits into `render.world` and `render.overlay`. The other spans
are unchanged.

## 8. `samples/sandbox3d`

**The name.** The sample that gains each 3D capability from M19 to M25, as `samples/sandbox`
gained 2D's. M26's playable sample gets its own name in M26.

**What it shows:**
- Three meshes, built in the sample, never in the engine: a cube, a thin slab that passes
  through the cube, and a tilted floor plane that cuts through both. Each has flat vertex
  colours per face.
- The cube and the slab spin about different axes, from `Quat.fromAxisAngle` at the fixed step.
  Their intersections sweep, which draw order cannot fake.
- The camera is placed with `Mat4.lookAt`'s pose, and does not move in M19.
- An overlay line from `foundry:core`'s font: the backend, the sample count and the frame time.
  It is the first proof that 2D draws over a 3D frame.

**Its package, `sandbox3d`**, holds a `sandbox3d:config` record of the sample's own schema:
- window title and size;
- clear colour;
- spin rates in radians per second, as field names say (ADR-0048).

It loads through the same path as every package (I3).

**Bootstrap:** `--msaa=1|4`, defaulting to 4. It exists so the evidence can show the same
frame both ways, and it is host bootstrap (ADR-0031), not content.

**The RHI boundary is a build error.** The sample's module is given `app`, `render3d`,
`render2d`, `asset`, `core`, `data` and `platform`, and **not `rhi`**. CLAUDE.md §4.2's rule
that games never touch the RHI is enforced by the graph for this sample, where `samples/sandbox`
predates the rule and imports it.

Engine primitive builders (cube, sphere) wait for a second consumer. The tests build their own
two quads.

## 9. Verification

Each step's tests are listed with it (§11). Three things carry the exit condition:

1. **The convention tests** (§3), and the projection tests (§6.3), on every host.
2. **Null-backend refusal** of every §4.2 and §4.3 rule, each tested by a violating descriptor
   or command.
3. **The draw-order readback.**
   - **Setup:** a headless device at 64×64. Two quads, one solid red and one solid blue, cross
     each other like an X seen from above, about the view's vertical axis. The camera looks
     down −Z at the crossing: red is in front on the left half and blue on the right.
   - **Runs:** both submission orders, each with MSAA 1 and 4, on **Metal** (in
     `zig build test -Drhi=metal`) and on **Vulkan** (the native Windows graph, with validation
     required).
   - **Assertions:**
     - pixels well away from the crossing line are exactly red on the left and blue on the
       right;
     - for each sample count, the two orders' images are byte-identical;
     - at 4×, pixels on the crossing line are blends, which proves the resolve ran;
     - at 1×, those same pixels are pure.
   - **Why this, not the sort:** no whole-draw order produces both halves, so a pass means the
     depth test decided visibility (§6.7).

**The runnable result** is `sandbox3d` from a relocated install, on macOS/Metal and on
Windows/Vulkan with validation. It is recorded:
- a screenshot at 1× and at 4×;
- a resize;
- a minimise and restore;
- a clean exit;
- the frame pacing of the last 240 frames, with the overlay pass's cost measured (§7).

`samples/sandbox` and `samples/room` still pass their runs. The whole test graph stays green on
null, Metal and Vulkan, and Linux/Vulkan compile-checks (`zig build check`).

## 10. Linux assessment: compile only

As `3d.md` §10.2 requires, **M19 changes nothing Linux-specific:**
- **Windows, surfaces and presentation are untouched.** The swapchain gains no usage, no format
  and no mode. Resolving into a swapchain image uses the colour-attachment usage it already
  has.
- **What M19 adds to Vulkan is core 1.3 behaviour:** multisampled images and pipelines,
  resolve in dynamic rendering, and a buffer-image copy. Every format and sample count it relies
  on is queried and refused explicitly rather than assumed (§4.1, §4.2). Mesa's ANV and Intel's
  Windows driver drive the same Arc for the Windows run.

**Runtime becomes required** if any of these happens during M19:
- the implementation changes swapchain creation, format choice or presentation;
- the Windows run shows behaviour that depends on the driver, such as a refused format, a
  resolve that differs from Metal's, or a validation message that names the driver;
- a pixel test needs a tolerance per backend.

Step 8 confirms that none did, or provisions a fresh machine with `scripts/m18/` and runs the
affected tests there.

## 11. Implementation order — eight bounded steps

Each step ends with a Resolution in this document, an updated `PROJECT_STATE.md`, the bar, and a
commit. There is no automatic chaining.

### Step 1 — `core`: rotations, transforms and the axes

§3 in full: the axes, `Quat`, `Transform`, the `Mat4` additions, and the revised header. Every
convention test. No other module changes. **Exit:** §3's table passes on every host, and nothing
outside `core` changed.

### Step 2 — The RHI contract, on the null backend

The types of §4.2 and §4.3, `copyTextureToBuffer` in the interface (41), and every rule in the
null backend with a violating test each. Metal and Vulkan gain compiling stubs that return
`UnsupportedFormat` for `sample_count = 4` and refuse the copy, so the graph stays green. The
stubs never outlive Steps 3 and 4. **Exit:** the null contract is complete, and nothing is
drawn yet.

### Step 3 — Metal: multisampling, resolve and readback

Replace Metal's stubs. Headless Metal tests, at the RHI level:
- a depth-tested draw read back;
- a 4× draw resolved and read back;
- a copy at an offset and a pitch.

**Exit:** the RHI-level readback passes on Metal, and misuse is refused as on null.

### Step 4 — Vulkan: the same, proved on Windows

Replace Vulkan's stubs with format and sample-count queries and resolve in dynamic rendering.
Run the same RHI-level tests natively on the Windows PC, with validation and synchronization
validation required. **Exit:** Metal's tests pass on Vulkan, validation-clean, and §10's
triggers are checked.

### Step 5 — The runtime mesh in `asset`

§5: the types, `validate`, `computeBounds`, and one refusal test per named error. Nothing uploads
yet. **Exit:** a valid mesh passes, and every malformed one is refused with its error.

### Step 6 — `render3d`

§6:
- the module and its build-graph entry;
- the camera and the projection tests;
- the shaders;
- targets, residency, submission, sorting and statistics.

Tests:
- on null, the recorded commands (passes, states, the sort, refusals);
- the draw-order readback of §9 on Metal here, and on Vulkan at Windows.

**Exit:** §9's readback passes on both backends at 1× and 4×.

### Step 7 — The frame and `sandbox3d`

§7's `renderScene`, its spans, and §8's sample and package. Run it on macOS and Windows from
relocated installs, and record §9's evidence and the overlay pass's measured cost. Rerun
`sandbox` and `room`. **Exit:** the runnable result, on both platforms.

### Step 8 — Close M19

- Confirm §10's assessment.
- Resolve every contract discrepancy in its originating document: `rhi.md` §8, §9 and §12,
  `3d.md` §4 and §10, and `render2d.md` §3 on who owns the frame.
- Update CLAUDE.md §4.3's graph, `AGENTS.md`'s bar if a step changed, `PROJECT_STATE.md`, the
  roadmap, the design index and ADR-0054's status.

Tag `m19`, push, and stop before M20's design. **Exit:** `3d.md` §10's M19 row holds as written.

## 12. What stays open

Nothing blocks Step 1. These are M19's own choices, fixed above unless the owner changes them
at acceptance:

| # | Choice | Where |
| --- | --- | --- |
| 1 | The sample is `samples/sandbox3d`, with package `sandbox3d` | §8 |
| 2 | Sample counts are exactly `{1, 4}`, with 4 by default | §4.2 |
| 3 | Resolve is a field of the attachment. `StoreAction` stays `{store, discard}` | §4.2 |
| 4 | Texture readback is an RHI command, valid after `waitIdle` | §4.3 |
| 5 | No 24-bit depth fallback. A driver without `depth32_float` is refused | §4.1 |
| 6 | Vertex semantics are fixed slots 0–7, one stream per buffer (ADR-0054) | §5, §6.4 |
| 7 | A finite far plane | §6.3 |
| 8 | `app.renderScene`: world pass, then overlay pass | §7 |
| 9 | Quaternions from outside are accepted within `1 ± 1e-3` of unit length, and normalised | §3 |
| 10 | Linux: compile only, with the stated triggers | §10 |

## Resolution — 2026-09-27, Step 1: `core`'s rotations, transforms and axes

**Done, on macOS; the Windows run is owed** (below). `engine/src/core/math.zig` is the only
source file changed. It gains:
- the axes: `Vec3.right`, `Vec3.up` and `Vec3.forward` (−Z), plus `Vec3.isFinite`;
- `Quat`, with the API §3 lists;
- `Transform`;
- the `Mat4` additions: `rotationX` and `rotationY`, `fromQuat`, `trs`, `mulPoint` and
  `mulDirection`, `determinant`, `inverse`, `lookAt` and `approxEql`.

Its header now says it knows which way is up, and still holds no projection.

**What implementation settled:**
- **`fromAxisAngle` normalises its axis,** where §3 said the axis "must be unit". A zero axis
  gives the identity. The cost is one square root, and it removes a precondition that a
  caller could get wrong silently. §3 is corrected.
- **The `inverse` is the cofactor expansion,** written over the flat sixteen floats. It is
  symmetric under transposition, so it needs no row/column translation. Its determinant uses
  the same cofactors.
- **The layouts are pinned by a test:**
  - `Quat` is 16 bytes, with `w` at offset 12;
  - `Transform` is 40 bytes, with its rotation at offset 12 and its scale at 28.
  
  Both will cross into GPU buffers and the ABI.

**Tests:** 14 new tests in `math.zig`, covering every row of §3's table, plus `lookRotation`'s
refusals, `rotate` against the matrix, `Transform.isValid`, and the layouts. **The tests were
mutated to show they fail when the conventions break:**
- reversing a term of the quaternion product fails the composition test;
- making forward +Z fails three convention tests;
- scaling the translation (`S·T` order) fails the `T·R·S` test.

**The bar on macOS:**
- `zig fmt --check`;
- `zig build test`: **91/91 steps, 1,698 of 1,699 headless tests** (the one skip predates M16);
- `check` native, `-Drhi=metal`, and the Linux and Windows null cross targets;
- both samples, for 30 frames each.

**Windows is not yet run.** The PC's DHCP address has moved again. Its host key matches the
recorded one at the new address. Changing the Mac's SSH configuration to follow it was refused
by the session's permission checks, and is left to the owner. The run owed is only
`zig test math.zig` natively on x86_64 Windows, at low priority. The file imports nothing but
`std`. Step 4 runs the whole Vulkan graph there in any case.

**Linux:** compile only, as §10 states. The Linux cross-check passed, and nothing here touches
Linux.

## Resolution — 2026-09-27, Step 2: the RHI contract, on the null backend

**Done.** The contract was written into `rhi.md` first, as its §11 requires of any tightening:
- §8 describes resolve targets and readback;
- rules 1, 7, 10 and 11 gain M19 clauses;
- §12's MSAA entry now points at §4.4 here.

The rule count stays at eleven. The new checks are clauses of existing rules, and are reported
under those rules' names.

**The types:**
- `TextureDesc.sample_count` and `RenderPipelineDesc.sample_count`, both defaulting to 1;
- `rhi.isValidSampleCount`, which accepts exactly 1 and 4;
- `ColorAttachment.resolve: ?ResolveTarget`. `ResolveTarget` holds a texture and its own initial
  and final states;
- `TextureToBufferCopy`, and `CommandBuffer.copyTextureToBuffer`. The interface now has 41
  functions, and its count test moved with it. `StoreAction` stays `{store, discard}`, and its
  comment now says why.

**The null backend enforces:**

| Rule | What is enforced |
| --- | --- |
| 10 | A sample count other than 1 or 4, on a texture or a pipeline, is refused. So is a multisampled texture with more than one mip level |
| 11 | A multisampled texture that is sampled, copied, or not an attachment is refused. A resolve target needs `render_target` usage. Readback needs `copy_src` on the texture, a colour format, and `copy_dst` on the buffer |
| 7 | Attachments of a pass have one sample count, and a drawing pipeline matches it. A resolve's source is multisampled. The resolve target is single-sampled, has its source's format and size, and is not an attachment of the same pass |
| 1 | A resolve target's arrival state is checked, and its departure tracked. A texture is read back only from `copy_src` |
| 10 | A readback region fits its level, and its rows fit the buffer. The pitch holds a row in whole texels, and the offset is a multiple of 4 |
| 8, 9 | Readback inside a pass is refused, as are a destroyed source, destination or resolve target |

**What implementation settled:**
- **§4.2's rule 5 was too strict.** It said a multisampled depth attachment "ends in
  `discard`", and the same logic would have forbidden storing a multisampled colour
  attachment. Both are legal in every API. A later pass may load the samples, and one test now
  proves that. What remains is that depth has no resolve target.
- **Readback of a depth format is refused under rule 11,** as a usage the RHI does not yet
  offer, rather than under a rule of its own.

**Metal and Vulkan stubs:**
- a sample count outside the set is `InvalidDescriptor`, as on null;
- 4× is `UnsupportedFormat`, the answer a device without 4× would give;
- `copyTextureToBuffer` records nothing and returns `ValidationFailed`.

Steps 3 and 4 replace them. Nothing in the tree reaches them.

**Tests:**
- 19 new null-backend tests: sixteen for the refused cases, and three accepting ones:
  - a 4× colour and depth pass resolved into the surface, which is what `render3d` will record;
  - a multisampled attachment stored and loaded across two passes;
  - a readback at an offset and pitch, mapped after `waitIdle`.
- **Mutations:** disabling the draw-time sample-count check fails exactly its rule 7 test, and
  disabling the readback state check fails exactly its rule 1 test.

**The bar on macOS:**
- `zig fmt --check`;
- `zig build test`: **91/91 steps, 1,717 of 1,718 headless tests**;
- `check` native, `-Drhi=metal`, and the Linux and Windows null cross targets;
- both samples, for 30 frames each;
- the Vulkan checks: `vulkan-check` for Windows and Linux, and `check -Drhi=vulkan` for Windows
  (Debug and ReleaseSafe) and Linux.

No Vulkan code runs until Step 4, which is on the Windows PC. Linux stays compile only (§10).

## Resolution — 2026-09-27, Step 3: Metal

**Done.** Metal's Step 2 stubs are gone. The backend now draws multisampled, resolves and reads
back:
- **Textures** carry `MTLTextureType2DMultisample` and `sampleCount`. The texture type is chosen
  in Zig, and the shim only passes it through, as it does every other Metal value.
- **Pipelines** carry `rasterSampleCount`.
- **Resolve:** a colour attachment with a resolve target gets `resolveTexture`. Its store action
  is `MultisampleResolve`, or `StoreAndMultisampleResolve` when the RHI says `store`. A resolve
  into the surface presents it, as drawing into it does.
- **Readback** is one blit, `copyFromTexture:…toBuffer:`. A zero-sized copy records nothing,
  because the RHI allows one and Metal's blit asserts on it.
- **Sample counts:** a count outside {1, 4} is `InvalidDescriptor`. One the device refuses
  (`supportsTextureSampleCount:`) is `UnsupportedFormat`. Every Apple GPU draws 4×, and the
  device is asked rather than assumed.
- **Shim constants:** the four new ones are `_Static_assert`ed against Metal's, as all the
  others are.

**What "refused as on null" means here.** This backend still does not validate commands
(ADR-0003); commands remain the null backend's job. It does refuse, at creation and with
null's error, a multisampled texture with mips, or one that is sampled, copied, or not an
attachment. Metal itself would accept a sampled multisampled texture, so without this check a
program could work on this backend alone.

**The contract was corrected first.** A readback offset must be a multiple of 4 **and of the
texel size**:
- Vulkan requires both, and Metal on macOS requires the texel size;
- "a multiple of 4" was enough for every 8-bit format, but not for `rgba16_float` or
  `rgba32_float`.

`rhi.md` rule 10, §4.3 here, the field's comment and the null check were changed together. The
null readback-limits test now refuses an 8-byte-texel copy at offset 4 and accepts it at 8.
Step 2's table above keeps its original wording, as the record of that step.

**Tests.** There are four new Metal tests. They run under `zig build test -Drhi=metal` on a
headless device:
- **Depth decides, at 1×.** This is §9's crossing at the RHI level: two full-viewport quads
  under reversed-Z, with depths that cross inside column 32 at x = 32.3 px. That point is off
  the pixel's centre and off every standard 4× sample position, so no sample ties. Both draw
  orders produce byte-identical images: exact red left of column 32, exact blue right of it,
  and a pure column 32.
- **A 4× draw resolves.** Both orders are byte-identical, with the same exact halves. Column
  32 is a red–blue blend, one sample in four, which only a resolve can produce.
- **A readback at an offset and a pitch.** A 4×2 region at (2, 1) of an uploaded 8×4 pattern,
  read to offset 12 with 24-byte rows. Every byte outside the region keeps its fill.
- **Creation-time misuse.** Two samples, a mipped, sampled, copied or unattached 4× texture,
  and a 3-sample pipeline are each refused with `InvalidDescriptor`.

**Mutations,** each run once and then restored. Each fails exactly the test aimed at it:
- dropping the resolve texture fails the 4× test;
- a depth compare of `always` fails both crossing tests;
- ignoring the pitch fails the readback test.

**The bar on macOS:**
- `zig fmt --check`;
- `zig build test`: 91/91 steps, 1,717 of 1,718 tests (one null test was extended, not added);
- `zig build test -Drhi=metal`: **95/95 steps, 1,726 of 1,732**, where the pre-step baseline
  was 1,722 of 1,728, with the same six skipped;
- `check` native, `-Drhi=metal`, and the Linux and Windows null cross targets;
- both samples, for 30 frames each;
- `vulkan-check -Drhi=vulkan` for Windows and Linux;
- `check -Drhi=vulkan` for Windows (Debug and ReleaseSafe) and Linux.

Vulkan keeps its stubs until Step 4, which runs these same tests natively on the Windows PC.
