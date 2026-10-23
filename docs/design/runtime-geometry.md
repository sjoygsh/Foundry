# Design: M28 — Runtime geometry: meshes, textures and materials made and changed at run time, beside compiled content

**Status:** Accepted 2026-10-23, when the owner asked for Step 1, with §13 as written. Steps run in §14's order; their Resolutions follow it.
**Date:** 2026-10-23
**Baseline:** `7224505`, tag `m27`. M0–M27 are complete.
**Decisions:**
- ADR-0053 (assets are not the renderer) already says code can build the same runtime mesh a
  file loads. ADR-0035 (completion-backed retirement), ADR-0054 (fixed vertex slots), ADR-0021
  (asset identity is a content ID), ADR-0057 (physics copies geometry as values), ADR-0059 (v6
  publishes no runtime geometry) and ADR-0061/0062 (background tasks, staged loads) constrain
  it.
- It proposes [ADR-0063](../adr/0063-runtime-geometry-is-owned-by-handle.md): runtime meshes,
  textures and materials are `render3d` resources named only by handle and owned by the code
  that made them. They are never content, so they have no content ID, no package can override
  them, and nothing saves them. They may refer to compiled content, and content never refers to
  them. Their contents change in place, outside a frame's submission window, and their handles
  survive the change.

## 1. Purpose and boundary

The roadmap's row (`docs/ROADMAP.md`, Phase 6) is the contract:

> M28 | Runtime geometry | Meshes, materials and textures created at run time in `render3d`,
> beside compiled content

Nothing else allocates work to M28 by name. `background.md` §1 says M27 "gives them the finish
path they will use". `public3d.md` §14's row, "runtime meshes, materials and textures from a
mod", is M48's, because M48 publishes what M27–M47 built.

**What "created at run time" has to mean now.** `render3d` could already make a mesh, texture
or material from code: M19 drew code-built meshes before any mesh file existed, and
`sandbox3d` still builds its cubes that way (§2). What it cannot do is everything a game that
generates geometry needs next:

- **Change one.** Every runtime resource is fixed when it is made. A surface that moves, a
  wall that is painted on or a mesh that is regenerated means destroying and remaking it. That
  gives out a new handle, and so breaks every material or draw that held the old one.
- **Make a large one without stalling a frame.** `createMesh` copies every byte into a new
  staging buffer on the main thread. That is the cost M27 Step 10 measured at 2–9 ms per
  21 MiB on the Arc's upload memory, and M27 moved it off the main thread for content only.
- **Mix with content safely.** A runtime material cannot bind a compiled texture and survive
  that texture's reload. Destroying a texture that a live material binds leaves the material
  pointing at a destroyed GPU object. Until now the only owner that had to get this right was
  `Content`, by ordering its own teardown (`meshes.md`, Step 5's Resolution). A game generating
  geometry is a second owner, and it should not have to.

**Runnable result.** `sandbox3d` gains a generated corner beside the room:
- a walkable terrain patch generated from a seed, whose one set of triangles is both the drawn
  mesh and the character's collision;
- a water sheet rewritten on the CPU every frame;
- a canvas texture that the player paints by looking at it, written one region at a time;
- a large generated landmark, built on the background pool, that appears when it is ready;
- a compiled model with one slot overridden by a runtime material. That material binds a
  compiled texture, and follows it when the texture is reloaded.

**Exit condition**, on Metal and on Windows/Vulkan, from a relocated install:
1. The water sheet (129×129 vertices) is rewritten every frame, at a p95 of at most 1.0 ms of
   main-thread work per update.
2. The landmark appears with no frame's work over 16.67 ms between its request and the 60
   frames after it is ready. The same landmark built inline, generated and uploaded in one
   frame, exceeds 16.67 ms. Its size is chosen in Step 6 so that it does, and pinned there.
3. A canvas region is written each tick at a p95 of at most 0.5 ms.
4. The character walks the patch to a pinned end position.
5. The overriding material follows a reload of its compiled texture with its handle unchanged.
6. The tour's hash (`cb99ccfcf2b6d6c3`) and the court's three endings are unchanged.
7. Vulkan validation is clean throughout.

**What M28 builds:**
1. `asset.mesh.Builder`: typed streams in, a validated `asset.Mesh` out. It is pure, so a
   background task may run it (§3).
2. The lifetime rules: a material keeps the textures it binds alive, and writes are refused
   inside a frame's submission window (§4).
3. In-place changes that keep the handle: `updateMesh`, `writeTexture` and `writeTextureChain`,
   all staged through M27's kept upload buffers (§5).
4. `render3d.Uploads`: creates and updates whose staging fill runs on the background pool, and
   whose finish runs at the caller's pump (§6).
5. Runtime materials in `Content`, binding compiled textures by content ID or runtime textures
   by handle, followed across reloads (§7).
6. `sandbox3d`'s generated corner and its measurements (§8).

**What M28 does not build**, each with the milestone that owns it:
- Runtime geometry for mods through the public table: M48, `FoundryApi_v8` (§9).
- The same for Lua scripts: M49.
- Particles, which may use these calls or a path of their own (M29's design decides): M29.
- Heightfield terrain as an engine feature: M62. The patch here is the sample's own generator,
  and `render3d` is not told it is terrain.
- Voxel meshing and chunk remeshing: M65 and M67.
- Tangent generation: M41. Morph targets: M77.
- GPU-side generation (compute) and persistently mapped rings: neither has a milestone, and
  §12 says why none is needed.
- Render-to-texture: M28's "textures created at run time" are textures whose texels the CPU
  writes. A texture the GPU draws into is a render target, and is the upper tier's (§12).
- `render2d` is unchanged. It already makes textures at run time and packs atlases into them
  (`rhi.md` §8).

## 2. What exists

Read from the code at `7224505`.

- **`render3d.Renderer`** (`engine/src/render3d/renderer.zig`):
  - `createMesh(asset.Mesh, label)` validates the mesh, computes per-submesh bounds, builds a
    skin bind for a skinned mesh, and uploads each stream and the indices. Every stream gets a
    staging buffer of its own, made and destroyed in the call, and one command buffer is
    submitted.
  - `createTexture`, `createTextureFromChain` and `createTextureFromStaged` (M27 Step 10)
    upload a texture whole. The last takes a `StagingReservation` from `reserveStaging`,
    whose kept buffers are reused once the frame ring has passed them (`latest + 1 + fif`).
    Those buffers are kept to 64 MiB, and all are freed after 300 idle frames.
  - `createMaterial`/`updateMaterial` build a uniform and a bind group. `updateMaterial`
    keeps the handle, and a refusal changes nothing.
  - `destroyMesh`, `destroyTexture` and `destroyMaterial` release now. The RHI defers the GPU
    object past its in-flight uses (ADR-0035). **Nothing records that a material binds a
    texture.** A draw whose material or mesh is gone is skipped at record time
    (`materials.getConst(...) orelse continue`).
  - `recording` is true from `begin` to the end of `recordFrame`. `drawMesh` validates the
    submesh index and streams against the mesh *at submission*.
- **`render3d.Content`** (`content.zig`): models and materials by content ID, each with a
  reference count. A material entry holds `[5]asset.AssetHandle` textures and is rebuilt when
  a texture payload changes (`built_from`). `drawModel` accepts `SlotOverride`s holding any
  live `MaterialHandle`, so a code-made material can already override a compiled slot.
  `deinit` destroys materials before textures, which is the one place the order is kept.
- **`render3d.Instances`** (`instances.zig`): retained, mod-owned instances of models by
  content ID (ADR-0059). M28 does not touch them.
- **`asset.Mesh`** (`engine/src/asset/mesh.zig`): byte streams by semantic, indices, submeshes,
  bounds and optional joint bounds. It has `validate` and `computeBounds`, and no builder: code
  writes little-endian bytes by hand (`sandbox3d/main.zig`'s `createMesh` helper).
- **The RHI** (`engine/src/rhi`):
  - `copyBufferToBuffer`, `copyBufferToTexture` with a `dst_origin` and `dst_mip_level`
    (added for `render2d`'s atlas), buffer and texture barriers, and upload and device-local
    memory.
  - `FrameVertexBuffer` (`frame_vertices.zig`), which stages bounded per-frame vertex data
    into a slot per frame in flight. Skinning uses it.
  - The RHI's states are `undefined`, `render_target`, `depth_stencil`, `shader_read`,
    `copy_src`, `copy_dst` and `present`, and vertex and index reads are `shader_read`.
- **`core.tasks`** and **`platform.Background`** (M27): `Tasks.start(task, done)`, `Graph`
  with background and main-thread nodes, and `Budget`. `app.Engine.tasks()` and
  `taskAllocator()` hand them to a game.
- **`physics3d.World.addMesh(gpa, positions, indices)`** copies a triangle mesh into its own
  tree (ADR-0057), so a generator's arrays can become collision unchanged.
- **`app.Engine`** pumps `asset.Registry` once a frame, before the game's step (ADR-0061,
  decision 4). It owns no `render3d.Renderer`: the game does, and hands it to `renderScene`.

## 3. Building a mesh from code (`asset`, L2)

`asset.Mesh` is the representation every importer produces (ADR-0053), so a generator produces
it too. What it lacks is a way to make one that does not mean writing bytes by hand.

```zig
pub const Builder = struct {
    pub fn init(gpa: Allocator, limits: BuilderLimits) Builder;
    pub fn positions(self: *Builder, values: []const Vec3) Error!void;
    pub fn normals(self: *Builder, values: []const Vec3) Error!void;
    pub fn uv0(self: *Builder, values: []const [2]f32) Error!void;
    pub fn colors(self: *Builder, values: []const [4]f32) Error!void;      // float32x4
    pub fn indices16(self: *Builder, values: []const u16) Error!void;
    pub fn indices32(self: *Builder, values: []const u32) Error!void;
    pub fn submesh(self: *Builder, first_index: u32, index_count: u32) Error!void;
    /// Bounds computed from the positions; `validate`d; the bytes are the caller's to free.
    pub fn finish(self: *Builder) Error!OwnedMesh;
};
```

- **Now:** position, normal, UV0 and float colour streams, 16- or 32-bit indices, submeshes,
  and bounds computed with `computeBounds`. `finish` validates the result exactly as a loaded
  `.fmesh` is validated, so a generator's mistake is the same named error a hostile file
  gets. A stream whose count differs from the positions' count is refused, as is a NaN,
  an index out of range and a mesh over `BuilderLimits`.
- **Pure and thread-free.** It allocates through the allocator it is given and touches no
  device and no global. A background task may run it with `Engine.taskAllocator()`, and two
  runs over the same inputs give the same bytes (I9).
- **Designed for:** tangents (`M41`), UV1, joints and weights. Each is one more setter over
  the same layout rules. None has a consumer in M28's sample, so none is added (rule 7).
- **Not here:** normal or tangent *generation*. A generator knows its surface and writes its
  normals analytically, as the sample's do. Tangent generation is M41's.

## 4. Lifetime and the write window (`render3d`, L3)

Two rules hold for every runtime resource, and they hold for `Content`'s too.

### 4.1 A material keeps alive what it binds

Each texture records how many live materials bind it. `destroyTexture` on a bound texture
invalidates its handle at once: a new material cannot bind it, and `writeTexture` refuses it.
Its GPU object is kept until the last material that binds it is destroyed or rebuilt without
it. Then it is destroyed, behind the RHI's ordinary deferred retirement.

The alternative, refusing the destroy, is rejected. `Content`'s reload deliberately releases
a texture before rebuilding the materials over it (`meshes.md`, Step 5's Resolution), and
refusing would force that order on every caller. Deferring keeps `Content` exactly as it is,
and turns its ordering from a correctness rule into an efficiency one.

### 4.2 Writes happen outside a frame's submission window

`updateMesh`, `writeTexture`, `writeTextureChain`, `updateMaterial`, `destroyMesh` and
`destroyTexture` are refused with `error.InFrame` between `begin` and the end of
`recordFrame`.

The reason is that `drawMesh` validates the submesh index and streams at submission. A mesh
changed between submission and recording would be drawn by a check that no longer holds.
Destroying mid-frame is refused for the same reason, although recording already skips a gone
handle: a draw that was accepted and then silently vanishes is a bug that should surface.
`destroyMaterial` keeps its current behaviour, because `Content` releases materials from
inside a draw path. Step 2 confirms whether it has to.

A write made outside the window is submitted at once, on its own command buffer, ahead of
the next frame's. Two promises follow:
- **The next frame recorded sees it.** Its submission comes after the copy's.
- **A frame already submitted never sees it.** The copy's barrier names the resource's
  `shader_read` state as its source, and on one queue that waits for every earlier
  submission's reads. On Vulkan a barrier's first scope covers all commands submitted
  earlier on the queue. Metal tracks hazards on resources it allocates with tracking. Step 3
  proves both by readback rather than taking them on trust.

> **2026-10-23, Step 2:** destroys inside the window are deferred to its close, not refused,
> and `updateMaterial` stays allowed there. See Step 2's Resolution and ADR-0063's revision
> note. §13 item 4 reads accordingly.

### 4.3 Counted

`Stats` gains `mesh_updates`, `texture_writes` and `uploaded_bytes` per frame, and the overlay
prints them beside M27's pump line. They are what §8's measurements read.

## 5. Changing a resource in place (`render3d`, L3)

### 5.1 `updateMesh(handle, mesh, label)`

The new mesh is validated exactly as `createMesh` validates, and **a refusal changes
nothing**. It may differ in every respect, including vertex count, submeshes, the stream set
and whether it is skinned. Each stream is then handled in one of two ways:
- **It fits** its existing buffer (same slot and format, no more bytes than the buffer
  holds): it is copied into that buffer.
- **It does not fit:** a new buffer is made, and the old one is destroyed behind ADR-0035's
  retirement.

The index buffer follows the same rule. Submesh bounds and the skin bind are rebuilt on the
CPU. The handle never changes.

There is no reserve or capacity option. A mesh that grows reallocates once per growth, and
that is cheap beside the generation that made it grow. §12 names the measurement that would
add one.

### 5.2 `writeTexture(handle, region, pixels)` and `writeTextureChain(handle, chain)`

- **`writeTexture`** writes an RGBA8 rectangle into level 0 of a texture **made without mips**,
  at `region.origin`. The region must lie inside the texture, and `pixels` must be exactly
  `width × height × 4` bytes. A mipmapped texture is refused (`error.HasMips`), because one
  region of a chain cannot be made consistent without regenerating every level.
- **`writeTextureChain`** replaces every level of a mipmapped texture with a chain of the same
  base size and colour space, made by `asset.mips.generate`. A canvas that needs both painting
  and mips regenerates its chain off the main thread (§6) and writes it whole.

Neither may change the size, format or colour space. The GPU texture is the same object, so
every material's bind group stays valid with nothing rebuilt. A texture that must change size
is made new, and its materials are moved to it with `updateMaterial`.

> **2026-10-23, Step 3:** `writeTextureChain` also takes the chain's `color_space`, because
> `asset.MipChain` does not record one and §11's colour-space refusal needs it. Its errors and
> the others' are listed in Step 3's Resolution.

### 5.3 Staging is M27's kept buffers

Every write and every `createMesh` reserves from `reserveStaging`, which today only texture
loads use, rather than making and destroying a staging buffer per stream. A water sheet
rewritten every frame therefore reuses the same few upload buffers on the frame ring's
schedule, and never allocates in the steady state. `createMesh`'s behaviour is otherwise
unchanged, and its bytes are pinned before and after.

## 6. Off the main thread: `render3d.Uploads` (`render3d`, L3)

M27 left two costs on the main thread for anything that is not a content load:
- generating the geometry;
- filling the upload buffer.

The first is the game's own code. The game runs it on `Engine.tasks()` and keeps the result
(an `asset.Mesh` from §3, or an `asset.Image` or `MipChain`). The second is the same cost M27
Step 10 moved for textures, and `Uploads` moves it here in the same way:

```zig
pub const Uploads = struct {
    pub fn init(gpa: Allocator, renderer: *Renderer, tasks: core.Tasks, limits: UploadLimits) Uploads;
    /// Reserves staging now, on the main thread; the fill runs on `tasks`.
    pub fn createMesh(self: *Uploads, mesh: OwnedMesh, label: []const u8) Error!UploadHandle;
    pub fn updateMesh(self: *Uploads, target: MeshHandle, mesh: OwnedMesh) Error!UploadHandle;
    pub fn createTexture(self: *Uploads, chain: OwnedChain, options: TextureOptions) Error!UploadHandle;
    pub fn writeTextureChain(self: *Uploads, target: TextureHandle, chain: OwnedChain) Error!UploadHandle;
    /// Once a frame, before simulation (ADR-0061, decision 4): finishes filled uploads in
    /// request order, within the budget, and frees each one's CPU bytes on the pool.
    pub fn pump(self: *Uploads, budget: *core.tasks.Budget) PumpStats;
    pub fn state(self: *const Uploads, handle: UploadHandle) ?UploadState; // pending, done, failed
    pub fn result(self: *Uploads, handle: UploadHandle) ?ResultHandle;      // the mesh or texture
    pub fn quiesce(self: *Uploads) void;
};
```

- **Main thread, at the request:** validation (a refusal changes nothing) and `reserveStaging`.
- **Pool:** the fill, a `memcpy` of streams and indices into the reservation at offsets
  `Uploads` computed when it reserved.
- **Main thread, at the pump:** the copy's command buffer, and for a create, the handle.
  Finishes run in request order, so the same requests finish in the same order whatever the
  pool's timing.
- **Ownership:** the CPU bytes move into `Uploads` at the request. They are freed on the pool
  after the finish, which is `Split.after_finish = .free_on_pool`'s reason (M27 Step 9).

It is a `render3d` type rather than an `asset.Registry` path because the registry is keyed by
content ID, and these resources have none (ADR-0021, ADR-0063). `app` does not pump it,
because `app` owns no renderer. The game calls `pump` where it renders, at the start of the
frame and under the same rule M27 set: what finishes on the main thread is presentation.

**Arrival is presentation** (ADR-0061). A game may draw a mesh once `state` says `done`.
Simulation never reads `state`. §8's patch shows what a game does when simulation needs the
geometry.

> **2026-10-23, Step 6:** a mesh's validation and submesh boxes, both linear in its indices,
> move from the request and the finish to the fill on the pool. A mesh that does not validate
> now fails at its finish (`failure` names why), rather than being refused at the request. The
> finish trusts the boxes the fill measured (`Renderer.PreparedMesh`). Measured on the landmark,
> the finish had cost 12.2 ms on the main thread. See Step 6's Resolution.

**Inline, for the baseline and the tests.** `Uploads` over `core.tasks.immediate` fills during
the request and finishes at the next pump. That is the path §1's exit criterion 2 compares
against, and it needs no thread.

## 7. Runtime materials beside records (`render3d.Content`)

`Content.createMaterial(desc: RuntimeMaterial) Error!MaterialHandle` makes a material that
`Content` owns and rebuilds, but that no record describes. Each of its five textures is a
`TextureRef`, one of:
- `none`;
- `runtime`, a `TextureHandle`;
- `content`, a `ContentId`.

A `content` texture is acquired through `render3d`'s texture loader, as a record's is. It is
followed across reloads by the same `built_from` check, so the material's handle survives a
reload and binds the new texture. `releaseMaterial` gives it back like any other.

- **It overrides a compiled model's slot**, through `SlotOverride` as today. That is the
  "beside compiled content" the row asks for: a game recolours or retextures a model it did
  not author without editing the package.
- **A runtime mesh draws with a compiled material**, through `acquireMaterial`, as today.
- **The reverse is impossible by construction.** A record names content IDs, and a runtime
  resource has none (ADR-0063, decision 2).
- A `runtime` texture is bound by handle, and §4.1 keeps it alive while the material binds it.

## 8. `sandbox3d`'s generated corner

All of it is in `samples/sandbox3d/generated.zig`. `FOUNDRY_SANDBOX3D_GENERATE` takes
`background` (the default), `inline` or `off`, and behaves like M27's `FOUNDRY_SANDBOX3D_LOAD`:
an unknown value is said aloud and treated as `off`. The corner is placed off the tour's
path, so the tour's hash is a check that nothing else moved.

- **The patch.** A 65×65 heightfield from a seeded value-noise function in the sample, with
  analytic normals and a lit material from the package.
  - It is generated **synchronously at startup, before the first tick**, and its positions
    and indices go to both `asset.mesh.Builder` and `physics3d.World.addMesh`. One set of
    triangles is drawn and walked on.
  - It is not built on the background pool, because collision is simulation. A patch that
    arrived when a thread finished would change what the character stands on with timing
    (ADR-0061).
  - A game that needs large generated collision joins it at a fixed tick and waits if it must.
    That is deterministic, because the result does not depend on when it arrived. The sample
    has no need of it, so it does not.
- **The water.** A 129×129 sheet, with its heights and normals from a sum of sines of the
  tick (not the wall clock, I9). It is rewritten with `updateMesh` every frame, outside the
  window, and drawn with a blended lit material.
> **2026-10-23, Step 6:** the water's default is to generate each frame's sheet on
> `Engine.tasks()` and update it through `Uploads.updateMesh`, so its validation, boxes and
> copy run on the pool. Rewriting it with `Renderer.updateMesh` on the main thread is kept as
> `FOUNDRY_SANDBOX3D_WATER=inline`, the baseline. That path measured 2.0 ms at p95 in the paced
> sample. See Step 6's Resolution.

- **The canvas.** A 1024² linear-filtered texture without mips, on a wall. While the player
  looks at it within reach, a 64² brush stamp is written with `writeTexture` at the ray's hit,
  at most once per tick. `C` clears it, which writes the whole texture once.
- **The landmark.** A generated spire of revolved, displaced rings, requested at a fixed tick
  (as the gallery is, `background.md` §11) through `Uploads.createMesh`. Its generation runs
  on `Engine.tasks()`. It draws once its state is `done`, and only the frames record when.
- **The recoloured model.** A compiled model from the package with slot 0 overridden by a
  `Content.createMaterial` whose base colour texture is a compiled one, by content ID. `R`
  reloads packages, and an evidence run changes that texture's source between two runs.

**Measured** in the gallery's style: a window of frames from the landmark's request until 60
frames after it is ready, with frame work excluding pacing, acquire and present, each write's
main-thread time, and `Stats`' new counters. It prints the same summary lines the gallery
prints, and an evidence run reads them. Nothing measured feeds simulation.

## 9. The public ABI: nothing in M28

v7 is frozen at 264 calls, and M28 adds none. Runtime geometry for mods is M48's
(`FoundryApi_v8`), which publishes what M27–M47 built. ADR-0063 is written so that M48 can
publish it as it is:
- handles that a mod owns, as ADR-0059's instances are;
- writes refused in the window;
- no content ID.

What M48 has to add is per-mod quotas on bytes, which this milestone's `UploadLimits` already
bound per `Uploads`.

## 10. Platform assessment

- **Metal.** `MTLBuffer`s are allocated with tracked hazards, so a blit into a vertex buffer
  after a frame that read it is ordered by Metal. Step 3 confirms it by reading back a frame
  recorded before the write and one recorded after.
- **Vulkan/Windows. Required.** Two things are new here:
  - **Vertex and index buffers written after they were drawn.** The barrier from
    `shader_read` must cover the vertex-input stage, and Step 3 checks the backend's mapping
    under validation.
  - **Uncached upload memory**, where M27 found its stall. The water sheet's per-frame write
    is the case it penalises, and §1's 1.0 ms is measured there.

  The PC was emptied at M27's close, so Step 7 re-clones into a fresh worktree (memory:
  exact paths only, `-j2`, below-normal priority, idle first).
- **Linux. Compile only.** Nothing Linux-specific changes: no windowing, input, presentation or
  driver path is touched. 3d.md §10.2's trigger does not fire.

## 11. Verification

- **`asset`:** the builder's bytes for a fixed quad equal `sandbox3d`'s hand-written quad,
  byte for byte. Each refusal is tested: count mismatch, NaN, index out of range, a submesh
  past the end and limits exceeded. Two runs give identical bytes.
- **`render3d`, null backend:**
  - Every `error.InFrame` refusal.
  - A destroyed but bound texture: its handle is invalid at once, its GPU object outlives the
    material, and it goes when the material is destroyed or rebuilt, counted through the null
    device's live-object count.
  - `updateMesh` refusals that leave the mesh unchanged.
  - Fit versus reallocation: buffer handles are kept or replaced.
  - `writeTexture` region bounds, byte length and `HasMips`; `writeTextureChain` size and
    colour-space refusals.
  - `Uploads`: order, budget, quiesce and teardown while pending, and freeing on the pool,
    all with `core.tasks.Manual`.
  - Content's runtime materials across a reload.
- **Readbacks on Metal and Vulkan:**
  - A mesh drawn, updated, then drawn again: the first frame's pixels are unchanged and the
    second's show the update.
  - A texture region write and a chain write, compared texel for texel.
  - A mesh made by `Uploads` and by `createMesh`, drawn identically.
- **Guards proved by mutation**, each named in its Resolution: the window check, the bound
  count, the fit check and the pump's order.
- **Determinism:** the patch's and landmark's bytes are hashed and pinned, identical between
  `inline` and `background` on one machine. Across macOS and Windows they are compared and
  reported, and not required (ADR-0013). The patch walk's end position is pinned by a headless
  test.
- **The bar** in full at every step, with the header check unchanged because the ABI does not
  change.

## 12. What stays open, deliberately

Each item is named with the milestone that owns it, or the measurement that would give it one.

| Item | Owner or trigger |
| --- | --- |
| Runtime geometry for mods through the table | M48 (`FoundryApi_v8`) |
| Runtime geometry from Lua | M49 |
| Particle geometry | M29 decides whether it uses `updateMesh` or a ring of its own |
| Heightfield terrain as an engine feature | M62–M63 |
| Voxel meshing and remeshing | M65, M67 |
| Tangent generation, and a `tangents` builder setter | M41 |
| Morph targets | M77 |
| Render targets a game draws into | The upper tier's design (Phase 8); no M0–M28 sample draws into a texture |
| A mesh capacity/reserve option | Added if Step 6 or Step 7 measures reallocation as more than 10% of an update's p95 |
| A persistently mapped per-frame ring for meshes | Added if the water sheet's update p95 exceeds 1.0 ms on either platform after §5.3's staging reuse |
| GPU-side (compute) generation | No compute in the RHI; it is the upper tier's when a sample's generation is GPU-bound |

The last two triggers are tested in Steps 6 and 7. If one fires, it is designed in this
milestone rather than handed on (rule 17).

## 13. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | Runtime meshes, textures and materials are named only by handle, owned by their creator, never content (no content ID, no override, no save); runtime may refer to compiled, never the reverse (ADR-0063) | §1, §7 |
| 2 | `asset.mesh.Builder` is pure, in `asset`, with position, normal, UV0 and colour now; no normal or tangent generation | §3 |
| 3 | A material keeps alive the textures it binds; destroying a bound texture is deferred, not refused | §4.1 |
| 4 | Writes of meshes and textures are refused between `begin` and the end of `recordFrame` (`error.InFrame`); destroys there are deferred to the window's close (revised at Step 2); a write is seen by the next frame recorded and never by one already submitted | §4.2 |
| 5 | `updateMesh` keeps the handle and copies in place where a stream fits, else reallocates; no capacity option | §5.1 |
| 6 | `writeTexture` writes regions only into textures without mips; `writeTextureChain` replaces a mipmapped texture whole; neither changes size, format or colour space | §5.2 |
| 7 | All runtime uploads reuse M27's kept staging buffers | §5.3 |
| 8 | `render3d.Uploads` fills staging on the pool and finishes at a pump the game calls, in request order; it is not an `asset.Registry` path and `app` does not pump it | §6 |
| 9 | `Content.createMaterial` makes runtime materials whose textures are `none`, a runtime handle or a content ID, followed across reloads | §7 |
| 10 | The sample's collision patch is generated synchronously at startup; only render-only geometry is generated in the background | §8 |
| 11 | No ABI change; M48 publishes it | §9 |
| 12 | Windows/Vulkan runtime proof is required; Linux is compile only | §10 |
| 13 | The exit budgets: water update p95 ≤ 1.0 ms, canvas write p95 ≤ 0.5 ms, no frame over 16.67 ms around the landmark while its inline baseline exceeds it | §1 |

No parent document is corrected. `public3d.md` §14's runtime-geometry row and `background.md`
§1's M28 line gain pointers at the close. Once these are accepted, nothing blocks Step 1.

## 14. Implementation order — eight bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `asset`: the mesh builder

§3: `Builder`, `BuilderLimits` and `OwnedMesh`, colocated tests for every refusal, the
byte-for-byte quad equivalence and repeatability. `sandbox3d`'s hand-written mesh helper moves
onto it, and its meshes' bytes are pinned before and after.
**Exit:** a builder-made quad is byte-identical to the hand-written one, and every refusal in
§11 is a named error.

### Step 2 — `render3d`: lifetime and the write window

§4: bound-texture counts and deferred destruction, `error.InFrame` and the `Stats` counters
with their overlay line, all tested on the null backend. It confirms whether `destroyMaterial`
can join the window rule (§4.2), and records the answer.
**Exit:** a bound texture outlives its handle until its last material goes, proved by the null
device's live count, and every write inside the window is refused.

### Step 3 — `render3d`: changes that keep the handle

§5: `updateMesh`, `writeTexture` and `writeTextureChain`, and `createMesh` moved onto kept
staging. There are null refusal tests, and before-and-after readbacks on Metal.
**Exit:** on Metal, a frame recorded before an update reads back unchanged and the next one
shows it, for a mesh, a region and a chain, with handles unchanged.

### Step 4 — `render3d`: `Uploads`

§6: requests, pool fills, the ordered pump, quiesce and teardown, tested with
`core.tasks.Manual`, and an `Uploads`-made mesh read back against `createMesh`'s on Metal.
**Exit:** the same requests finish in the same order under any interleaving of the manual
executor, and teardown while pending leaks nothing.

### Step 5 — `render3d.Content`: runtime materials

§7: `RuntimeMaterial`, `TextureRef` and `createMaterial`, followed across `contentChanged`,
and used as a slot override.
**Exit:** a runtime material binding a compiled texture keeps its handle across a reload and
binds the new texture, and one binding a destroyed runtime texture still draws until it is
released.

### Step 6 — `sandbox3d`: the generated corner, proved on Metal

§8 in full, the landmark's size chosen so that its inline frame exceeds 16.67 ms and pinned,
and the measurement windows. §1's exit is run on Metal from a relocated ReleaseSafe install,
together with the tour and the court, and §12's two measured triggers are read.
**Exit:** §1's exit criteria 1–6 hold on Metal.

### Step 7 — Windows/Vulkan

A fresh worktree on the PC. The native Vulkan suites run under validation, and Steps 3–6's
readbacks and the corner's measurements run from a relocated install. §12's triggers are read
again.
**Exit:** §1's exit holds on Windows/Vulkan, validation-clean.

### Step 8 — Close M28

- Resolve the contract discrepancies in their originating documents:
  - `background.md` §1's M28 line;
  - `public3d.md` §14's runtime-geometry row, pointing at M48;
  - `3d.md`'s "code can make a runtime mesh too", which now names changing one;
  - `render3d.md` and `meshes.md` §7.3's "a material does not track its texture", which §4.1
    reverses;
  - and anything Steps 1–7 found.
- Mark ADR-0063 accepted and implemented, and add its row to `CLAUDE.md` §4.1. Update §4.3's
  `render3d` and `asset` lines, and §9's deferred row.
- Update `AGENTS.md`'s bar only if a step changed it, then the ROADMAP, the design index, the
  README and `PROJECT_STATE.md`.
- Tag `m28`, push when asked, and stop before M29's design.

**Exit:** §1's exit holds as written on both platforms, and no item of §12 is left without its
owner.

## Resolution — Step 1: the mesh builder (2026-10-23)

**What exists now.** `asset.mesh.Builder`, `asset.mesh.BuilderLimits`, `BuilderError` and
`OwnedMesh`, in `engine/src/asset/mesh_builder.zig`, re-exported from `asset` as `MeshBuilder`,
`MeshBuilderLimits` and `OwnedMesh`.
- Each setter copies its values into memory the builder owns.
- `finish` validates with `Mesh.validate`. On success it moves every byte into the returned
  `OwnedMesh`, which can be moved freely and is freed with the same allocator.
- A refusal leaves the builder owning the bytes, and `deinit` is safe either way.
- Streams come out in slot order, whatever order they were given in.

**Where the implementation sharpened §3:**
- **`colors8` (unorm8x4) joins `colors` (float32x4).** §3 named only float colour, but
  `sandbox3d`'s vertex-coloured cube is unorm8x4, and moving it onto the builder unchanged is
  this step's exit. Both are formats `Mesh.validate` already accepted.
- **Bounds are computed in `positions`,** from the typed values, so a non-finite position is
  refused at that call (`NonFinitePosition`) rather than at `finish`. Computing them at
  `finish` would have meant reading `Vec3`s back out of byte storage that is only
  byte-aligned.
- **Only the positions set the vertex count.** Every other stream is checked against it by
  `validate` (`InvalidStreamLength`), whichever was given first.
- **No submesh means one spanning every index.** An explicit `submesh` replaces that default.
  With no indices at all, `finish` refuses with `MissingSubmesh`, exactly as a mesh with none
  would be refused.
- **New refusals:**
  - `TooManyVertices`, `TooManyIndices` and `TooManySubmeshes`, checked against
    `BuilderLimits` before anything is copied. The defaults are `.fmesh`'s 16,777,216 vertices
    and 65,536 submeshes, plus 67,108,864 indices.
  - `IndicesAlreadySet` for indices given twice.
  - `DuplicateSemantic`, which already existed, for a stream given twice.
- **`OwnedMesh.deinit` frees the submeshes at their allocated alignment.** `Mesh` views
  submeshes as `align(1)` so that `.fmesh` file bytes can back them, so the slice is cast back
  before freeing. The debug allocator caught the mismatch on the first run.

**`sandbox3d`** now builds its cube and its shadow-proof ground through the builder (`boxMesh`
and `shadowGroundMesh`). The M19 arrays are kept as `boxArrays`. A test compares the builder's
streams, indices and bounds byte for byte against those arrays and against the ground's
literal arrays, and pins each mesh's digest:
- the cube: `16753803297239917816`;
- the ground: `6219219726740329206`.

**Guards verified by mutation**, each failing a named test:
- the stream vertex limit, the index limit and the submesh limit;
- indices given twice, and a stream given twice;
- the default submesh;
- moving ownership out of the builder at `finish` (removing it double-frees in six tests).

Two mutations caught nothing at first, and both led to changes:
- The positions' own limit check is shadowed by the stream check after it. It stays only as a
  precheck before the bounds pass. A test now sends a normal and a colour stream over the
  limit.
- The first version let whichever stream came first set the vertex count. Removing that rule
  changed nothing, which is why only the positions set the count now.

`checkAllAllocationFailures` runs over a full build and leaks nothing.

**Not done, as designed:** UV1, tangents, joints and weights setters, and any normal or tangent
generation (§3; tangents are M41's). `render3d` is untouched: `sandbox3d` still uploads
through `createMesh`, whose behaviour Step 3 changes.

**Bar:** `zig build test` **2,218/2,219** (one skip, unchanged), up from 2,204/2,205 by the 13
builder tests and the `sandbox3d` pin. fmt, the four `check` variants, the four thirty-frame
headless runs and `fdt-check` are clean. No ABI, shader, Vulkan or content change, so no
conditional extra applied.

## Resolution — Step 2: lifetime and the write window (2026-10-23)

**What exists now**, all in `engine/src/render3d/renderer.zig`:
- **Bound-texture counts (§4.1).** A material records the five textures its group names,
  defaults included, and each holds one of that texture's `binds`.
  - `destroyTexture` on a bound texture marks it `released`. The handle answers nothing from
    then on: `liveTexture` refuses it, so no new material can bind it.
  - Its GPU object is freed by `unbindTexture` when the last material that binds it is
    destroyed or rebuilt without it.
  - An unbound texture goes at once, as before.
  - A rebuild binds the new textures before it lets go of the old ones. That way a rebuild
    onto the same texture never frees it in between.
- **Deferred destroys in the window (§4.2, revised).** Between `begin` and the end of
  `recordFrame`, `destroyMesh` and `destroyMaterial` only mark their resource `doomed`.
  - A doomed handle is refused by `drawMesh` at once (`InvalidMesh`, `InvalidMaterial`) and by
    `updateMaterial`.
  - A draw submitted before the destroy is still recorded.
  - `freeDoomed` frees everything doomed at three points: when the window closes in
    `recordFrame`, at the next `begin` (a frame that was begun and never recorded), and in
    `deinit`.
  - If the doomed list cannot grow, the resource is freed at once, with a warning. That is
    today's behaviour, and recording already skips a gone handle.
- **Counters (§4.3).** `Stats` gains `mesh_updates`, `texture_writes` and `uploaded_bytes`.
  - Uploads happen between frames, so they collect in `uploads` and `begin` folds them into
    the frame that follows them.
  - `uploaded_bytes` already counts `createMesh`'s and `createTexture`'s bytes, staged or not.
  - The two update counts stay zero until Step 3 adds the calls they count.
  - The profiler panel prints them as one line, "3D: … mesh updates … texture writes … KiB
    uploaded", beside M27's pump line.

**Where the implementation corrected §4.2** (also recorded in ADR-0063's revision note, and in
§13 item 4):
- **Destroys inside the window are deferred, not refused.** The three destroys return `void`.
  The asset registry's loader unload calls them and has nowhere to put a refusal. Changing
  that would have widened `asset`'s loader contract for a case that deferring handles fully.
- **A texture needs no deferral.** §4.1 already keeps a bound texture's GPU object alive. An
  unbound one is named by no submitted draw, because draws name materials.
- **`updateMaterial` stays allowed inside the window.** This settles the question §4.2 left
  to this step. `Content.drawModel` rebuilds a model's materials from inside a frame. A
  submitted draw keeps its pipeline key and records the group current at recording, and the
  RHI retires the old group behind the frame ring. `destroyMaterial` defers like a mesh does.
- **`error.InFrame` therefore arrives with Step 3,** on `updateMesh`, `writeTexture` and
  `writeTextureChain`, the only calls the window still refuses. This step's exit ("every write
  inside the window is refused") applies to those writes when they exist. M28 adds no write
  call before Step 3.

**`Content`** is unchanged in behaviour. Its teardown still releases materials first, and the
`deinit` comment now says why that is an efficiency choice, not a correctness rule. The
renderer's own tests cover the other order: a texture destroyed before its material, with the
null device's live count dropping only when the material goes.

**What the full suite caught.** The first bar failed two tests outside `render3d`, both from
reloads made inside a frame that was begun but never recorded. Such a reload now dooms the old
mesh instead of freeing it.
- `sandbox3d`'s walker test expected `meshJointCount` on the retired handle to answer `null`.
  That was a real gap: a doomed mesh still answered queries. `meshJointCount` and
  `validateSkin` now go through a `liveMesh`, as `drawMesh` does. A doomed mesh answers
  nothing, as a destroyed one does, and only recording still reads it. The doomed-records
  test now checks both queries.
- `engine/tests/model_content.zig` retired "the first mesh in the pool". That was now the
  doomed old mesh, so destroying it again was a no-op. The test now retires the first live
  one, and still proves that `drawModel` refuses a retired handle with `InvalidMesh`.

**Tests.** `render3d` runs 79 tests, up from 71. The new ones:
- a bound texture outlives its handle until its last material goes, by the null device's live
  texture count;
- an unbound texture goes at once, and a refused material counts no binding;
- a rebuild binds the new texture before releasing the old;
- destroying a material leaves a texture that is still live untouched;
- a mesh and a material destroyed in the window still record their submitted draw, and are
  refused for new ones;
- a destroy outside the window is immediate, and a frame that is begun but never recorded
  frees what it doomed;
- `deinit` frees what a frame left doomed;
- uploads are counted into the frame that follows them.

Two older tests that compared whole `Stats` or a fixture's upload now check the specific GPU
objects through the null device, because uploads appear in `Stats` from this step on.

**Guards verified by mutation.** Each mutation below was caught:

| Mutation | Caught by |
| --- | --- |
| A bound texture freed at once | panicked on a null GPU object |
| An unbind frees a texture that is still live | the live-texture test |
| A released texture still bindable | the outlives-its-handle and rebuild tests |
| A material destroyed in the window not deferred | the doomed-records and abandoned-frame tests |
| A doomed mesh still drawable | the stale-handle and doomed-records tests |
| A doomed material still drawable | the doomed-records test |
| An abandoned frame does not free its doomed resources | the abandoned-frame test |
| The window's close does not free its doomed resources | the doomed-records test |
| Uploads not folded into `Stats` | the resident-mesh and uploads-counted tests |
| `deinit` not freeing doomed resources | the `deinit` test |

The last one was caught by a hang. That test binary spun until it was killed, rather than
failing on the testing allocator's leak report. It never passes, so the guard holds, but a
hang is a poor way to learn of it. Step 3 looks into why the leaked mesh hangs the null
device's teardown, and makes it fail.

**Not done, as designed:** `updateMesh`, `writeTexture`, `writeTextureChain` and `InFrame`
(Step 3), `Uploads` (Step 4), and runtime materials in `Content` (Step 5).

**Bar:** `zig build test` **2,226/2,227** (one skip, unchanged), up from 2,218/2,219 by the eight
lifetime tests. fmt, the four `check` variants, the four thirty-frame headless runs and
`fdt-check` are clean. No ABI, shader, Vulkan or content change, so no conditional extra
applied.

## Resolution — Step 3: changes that keep the handle (2026-10-23)

**What exists now**, in `engine/src/render3d/renderer.zig`:

- **`updateMesh(handle, mesh, label)` (§5.1).**
  - `createMesh` and `updateMesh` now share one path, `uploadMesh`. It validates, builds the
    CPU parts (submeshes, submesh boxes, skin bind), and places each stream.
  - A stream **fits** when the old mesh has a buffer in that slot, with the same format and at
    least as many bytes. Fitting streams are copied into their buffer. Any other stream gets a
    new buffer. The index buffer follows the same rule.
  - `MeshState` records each buffer's capacity. A mesh that shrinks keeps its larger buffers,
    and growing back into them makes nothing.
  - The old mesh's buffers that the new state no longer names are retired behind ADR-0035's
    deferral, along with its CPU parts. The handle never changes.
  - A refusal frees only what the call made and leaves the old mesh untouched. If `submit`
    itself fails, a lost device, the kept buffers may already hold the new bytes while the
    mesh still describes the old ones. That is the same answer `createMesh` has always given
    a lost device.
- **`writeTexture(handle, region, pixels)` (§5.2)** writes an RGBA8 `TextureRegion` into level 0
  of a texture made without mips.
- **`writeTextureChain(handle, chain, color_space)`** replaces every level of a mipmapped
  texture.
  - The chain is untrusted input. It must have the texture's base size and exactly its level
    count. Each level must be the size `mipLevel` gives, and its bytes must lie inside the
    chain.
  - Both writes copy into the same GPU texture, so every bind group that names it stays
    valid. `TextureState` now records its size and level count.
- **Staging (§5.3).** Each upload reserves one kept buffer from `reserveStaging`:
  - for a mesh, one buffer holding every stream and the indices at 16-byte-aligned offsets;
  - for a write, one buffer holding the texels.

  The buffer goes back with `returnStaging(used)` on the frame ring's schedule. A mesh
  rewritten every frame reaches a steady state after the ring turns, and makes no buffer from
  then on (tested). The one-reservation layout is also what Step 4's `Uploads` fills on the
  pool: "at offsets `Uploads` computed when it reserved".
- **Counting.** `mesh_updates`, `texture_writes` and `uploaded_bytes` are counted into the frame
  after the write, as Step 2 set up.

**New errors** in `render3d.Error`:
- `InFrame`;
- `HasMips` (a region write into a chain) and `NoMips` (a chain write into a texture without
  mips);
- `InvalidRegion` (empty or outside level 0, overflow-safe);
- `InvalidPixelLength`;
- `TextureSizeMismatch`;
- `InvalidMipChain`.

`WrongColorSpace` is reused. `InvalidTexture` also covers the renderer's three default
textures: they are every material's fallback, so writing one would recolour materials that
never named it.

**The window.** `updateMesh`, `writeTexture` and `writeTextureChain` refuse `InFrame` while
`recording`, from `begin` to the end of `recordFrame`. A frame that is begun and never recorded
stays in its window until the next `begin`, as Step 2's deferred destroys do. `updateMesh`
needs no doomed check of its own: a mesh is doomed only inside the window, which the refusal
already covers. The mutation that removed such a check survived, which is how this was found.

**The ordering promise, proved on Metal.** The test "a frame submitted before a write reads back
unchanged, and the next one shows it" covers three cases:
- a mesh moved from the left half of the frame to the right, in the same buffers;
- a texel of a 2×1 canvas turned green;
- a mipmapped texture's chain replaced whole.

Each case submits a frame, writes without waiting, submits the next frame, and only then
waits. Every first frame reads back the old contents, and every second the new.
`zig build render3d-test -Drhi=metal` passes **85/85**. That includes every existing pixel test,
which pins `createMesh`'s output across its move onto kept staging, and Step 2's lifetime tests,
which had run only on null until now.

**Step 2's loose end is closed.** The "`deinit` not freeing doomed resources" mutation hung
because of how `deinit` emptied its pools. It looped `destroyMesh` (and `destroyMaterial`)
until each pool was empty, and a destroy passes over a doomed entry. So a doomed entry nobody
had freed kept the count above zero forever. Nothing was leaking; teardown could never make
progress.

`deinit` now frees every entry directly, doomed or not. The equivalent mutation ("`deinit`
skips doomed meshes") is now reported at once by the testing allocator, as "leaked 2
allocations".

Mutation runs now go through a wrapper that kills the whole process group after a limit. Its
first version kept its own timer alive after the run, which held the output open for the full
limit. Fixed, one round of mutations takes seconds.

**A blind spot found and closed in the null backend.** A kept buffer's barrier names
`shader_read` as its source. That is what makes the copy wait for earlier frames' reads.
Declaring `undefined` instead skips that wait, and it survived the first mutation round,
because null does not check a barrier whose source is `undefined`. Textures already counted
such a transition (`contentsDiscarded`); buffers did not. The null device now counts it for
buffers too (`bufferContentsDiscarded`, with its own rule-1 test). The fit test and the
region-write test assert zero discards. Both barrier mutations, for buffers and for textures,
are now caught.

**Tests.** `render3d` runs 85 tests, up from 79:
- a mesh update fits, grows, shrinks back into its buffers, and drops a stream;
- a refused update, and one inside the window, change nothing;
- kept staging reaches a steady state;
- region-write refusals;
- chain-write refusals, including a chain that lies about its levels;
- the Metal ordering readback.

**Guards verified by mutation**, each failing a named test within seconds:

| Guard | Caught by |
| --- | --- |
| The window check on each of the three writes | its own write's test |
| A fit that is never taken | the fit test |
| A fit that ignores capacity | the fit and refused-update tests, by a null copy-range violation |
| An index buffer that always fits | the same two tests |
| The old buffers not retired | the fit test |
| `HasMips`; the region bounds; the pixel length; the defaults' refusal | the region test |
| The chain's colour space, level sizes, level bytes and level count | the chain test |
| The update and write counts | the fit, region and chain tests |
| A barrier from `undefined` on a kept buffer or a written texture | the fit and region tests |
| `deinit` skipping doomed meshes | the testing allocator's leak report |

**Not done, as designed:** `Uploads` (Step 4) and runtime materials in `Content` (Step 5).
Vulkan's readback of the same three cases is Step 7's.

**Bar:** `zig build test` **2,233/2,234** (one skip, unchanged), up from 2,226/2,227 by the six
`render3d` tests and the null backend's buffer-discard test. `render3d-test -Drhi=metal` passes
85/85. fmt, the four `check` variants, the four thirty-frame headless runs and `fdt-check` are
clean. The RHI change is to the null backend's test observability only, so no Vulkan check
applied. There is no ABI, shader or content change.

## Resolution — Step 4: `Uploads` (2026-10-23)

**What exists now.** `render3d.Uploads`, in `engine/src/render3d/uploads.zig`. It is exported as
`Uploads`, `UploadHandle`, `UploadLimits`, `UploadState` and `UploadResult`.

- **At the request (main thread):** validation, the staging reservation, and the fill started
  on `tasks`. A refusal reserves nothing it keeps and leaves the bytes the caller's. On
  success the bytes are the `Uploads`' own.
- **On the pool:** the fill copies into the reservation. A mesh goes through
  `Renderer.fillMeshStaging`, at the offsets `uploadMesh` reads.
- **At the pump (main thread):** the oldest unfinished request finishes through the
  renderer's new staged entry points:
  - `createMeshFromStaged` and `updateMeshFromStaged`;
  - `writeTextureChainFromStaged`;
  - M27's `createTextureFromStaged`.

  Each entry point consumes the reservation whatever it returns.
- **Afterwards, on the pool:** the CPU bytes are freed. If the pool is full, they are freed on
  the main thread instead.

**The order guarantee.** Only the head of the queue may finish, so a filled request waits
behind an unfilled older one. Under `core.tasks.Manual`, every one of the 24 orders four fills
can run in, with a pump after each fill, finishes the requests 0, 1, 2, 3. This is the step's
exit, together with teardown (below).

**Where the implementation settled or corrected §6's sketch:**
- **One staging layout, shared.** `uploadMesh` now plans its pieces with a pure `meshPieces`.
  That function also backs `meshStagingSize`, which the request reserves by, and
  `fillMeshStaging`, which the pool runs. The background fill and the main-thread copy cannot
  disagree. `createMesh` itself goes through the same function, and it is pinned on Metal
  below.
- **Owned bytes.**
  - A mesh is an `asset.OwnedMesh` made with the `Uploads`' own allocator, because it is freed
    with it on the pool. That allocator must therefore be thread-safe whenever `tasks` has
    threads, as the registry's is.
  - §6's `OwnedChain` is `asset.MipChain`, which already owns its bytes.
  - `createTexture` takes one level, or every level `asset.mips.generate` makes. A one-level
    chain is a texture without mips. The new `Renderer.checkNewTextureChain` checks it as
    untrusted input. `checkTextureChain` shares its shape check (`chainShaped`).
- **`writeTextureChain` takes `color_space`,** as `Renderer.writeTextureChain` does since
  Step 3. `updateMesh` takes a label.
- **`release(handle)`, `failure(handle)` and a fourth state, `cancelled`, were added.** §6 had
  no way to forget a request. A water sheet updated every frame would have grown the table
  without bound.
  - `release` cancels a pending request. Its turn in `pump` drops it without charging the
    budget, once its fill has run, because the fill writes into its staging.
  - A finished request's mesh or texture stays the caller's after `release`.
  - `failure` says why a request is `failed`. Its target went, as in the test, or the device
    refused.
- **`Limits`:** `max_requests` (256), counting pending and finished-but-unreleased requests,
  and `max_pending_bytes` (64 MiB). They are refused with `TooManyUploads` and
  `TooManyUploadBytes`. A full executor answers `Full`, giving its reservation back. This is
  the bound M48 sets per mod.
- **`pump` finishes nothing inside a frame's submission window.** The writes would be refused
  there (§4.2). Waiting keeps every request's place, where failing it would not.
- **The budget is M27's `core.tasks.Budget`.** A finish charges its staging bytes. A budget
  already spent still finishes the first ready request, so a large finish cannot wait forever.
- **`quiesce`** waits for every pool task, then drops whatever is pending as `cancelled`. Its
  staging goes back unused, and its bytes are freed. `deinit` runs it, and must come before the
  renderer's.

**Tests**, eight in `uploads.zig`:
- the 24 interleavings;
- budget, always-one and the window;
- teardown with fills unrun, with fills run but not finished, and with a finish whose free has
  not run. The testing allocator and the renderer's reservation assertion are the checks;
- bytes freed on the pool after the finish and not before;
- a released request dropped while the next finishes;
- request refusals, including `Full`, both limits, a lying chain, a default texture and a target
  destroyed before its turn;
- an update and a chain write through `Uploads` that keep their targets' handles, counted in
  `Stats`;
- on Metal, a fan made by `Uploads` reads back byte for byte as the same fan made by
  `createMesh`.

**Guards verified by mutation**, each caught by a named test failing or crashing, in under a
minute for the whole round:

| Guard | Caught by |
| --- | --- |
| Finishing the first filled request rather than the oldest | the interleaving test |
| Finishing inside the window | the budget test |
| The first finish under a spent budget | the budget test, once it began spent |
| Ignoring the budget | the budget test |
| Finishing a released request | the release test |
| Freeing on the main thread | the pool-free test |
| `quiesce` not waiting, or not dropping | the teardown test |
| `drop` keeping the staging | the teardown test |
| The request and byte limits | the refusal test |
| The new-chain, update-target and written-chain checks | the refusal test |
| Recording the failure | the refusal test |
| A full executor keeping its staging | the refusal test |

The always-one mutation survived at first. The test's budget of one byte is not spent until
something charges it, so the test now starts from a budget of zero.

**Not done, as designed:** no sample uses `Uploads` yet (Step 6). `Content`'s runtime
materials are Step 5's, and Vulkan's readback is Step 7's.

**Bar:** `zig build test` **2,241/2,242** (one skip, unchanged), up from 2,233/2,234 by the eight
`Uploads` tests. `render3d-test -Drhi=metal` passes 93/93. fmt, the four `check` variants, the
four thirty-frame headless runs and `fdt-check` are clean. There is no ABI, shader, Vulkan or
content change.

## Resolution — Step 5: runtime materials (2026-10-23)

**What exists now.** `Content.createMaterial(RuntimeMaterial) Error!MaterialHandle`, in
`engine/src/render3d/content.zig`, with `RuntimeMaterial` and `TextureRef` exported from
`render3d`.

- **`RuntimeMaterial`** has `MaterialDesc`'s values. Each of its five textures is a
  `TextureRef`: `none`, `runtime` (a `TextureHandle`) or `content` (a `ContentId`).
- **A runtime material is an ordinary `MaterialEntry`** with `id = ContentId.none` and its own
  description kept in a new `runtime` field.
  - `refresh` follows its content textures across texture reloads by the same `built_from`
    check a record's uses.
  - `contentChanged` rebuilds it with `resolveRuntime`, acquiring its content textures afresh.
  - `releaseMaterial` and `deinit` handle it like any other entry.
  - Its handle survives every rebuild, and it overrides a compiled model's slot through
    `SlotOverride`, unchanged.

**Where the implementation settled §7:**
- **A refusal at `createMaterial` is an error, not the placeholder.** A record is content and
  untrusted, so its mistakes draw magenta. A runtime material's values are the caller's code,
  so they are refused, and nothing is held:
  - `TextureNotFound` (new) for a content ID with no texture record, or one naming another
    schema. The registry already refuses both;
  - `WrongColorSpace`, `InvalidMaterialValue`, `UnknownShadingModel`, and `InvalidTexture`
    for a destroyed runtime texture, all from the renderer.

  A rebuild that fails later is content's doing: a texture record gone, or a runtime texture
  destroyed since. It then draws the placeholder behind the same handle, said once.
- **A rebuild happens only when something content-owned is named.** A runtime material with no
  `content` texture is skipped by `contentChanged`, because no reload can change it. Rebuilding
  it anyway would drop a `runtime` texture destroyed since, which §4.1 promises it keeps
  drawing until it is released.
- **No ID finds a runtime material.** Hash 0 is reserved, and the content compiler refuses any
  name that hashes to it, so the record lookup needs no extra check. A first draft had one. Its
  mutation survived, which showed it could never matter, so it was removed.

**Tests**, three in `engine/tests/model_content.zig`, over the real compiler, store, registry
and renderer:
- **A runtime material binds the compiled crate texture by ID, and overrides the pair model's
  slot.** A draw with nothing changed keeps its bind group. It follows the PNG edited on disk,
  rebinding before the draw, with no null violation. It keeps its handle, values and single
  reference across a package reload. It becomes the placeholder behind the same handle once
  the texture's record is gone.
- **A runtime material binding a destroyed runtime texture** still draws, across a package
  reload, with no violation. Its GPU texture goes only when the material is released, by the
  null device's live count.
- **Refusals hold nothing:** `TextureNotFound` twice, `WrongColorSpace` for an sRGB texture in
  a lit material's metallic-roughness slot, `InvalidMaterialValue`, `InvalidTexture` and
  `UnknownShadingModel`. Neither `Content`'s entries, the renderer's materials, nor the
  registry's reference counts move. A record's acquire never returns a runtime material.

**Guards verified by mutation** against `zig build integration-test`, about a minute per
mutation:

| Mutation | Caught by |
| --- | --- |
| Rebuilt as a record | the reload test, and the destroyed-texture test |
| Rebuilt with nothing content-owned named | the destroyed-texture test |
| Never rebuilt | the reload test, at the gone record |
| A refused create keeping its textures | the refusal test |
| A rebuild keeping the old textures | the reload test, by the reference count |
| `built_from` not recorded at create | the reload test, by the bind group |
| A failed rebuild not made the placeholder | the reload test |

The `built_from` mutation survived at first. It costs only a needless rebuild at the first
draw, and the test now asserts the bind group is unchanged. A schema check written before the
registry's acquire also survived. The registry already refuses a record of another schema, so
the duplicate was removed.

**Not done, as designed:** no sample uses runtime materials yet (Step 6, the recoloured model),
and Vulkan's readbacks are Step 7's.

**Bar:** `zig build test` **2,244/2,245** (one skip, unchanged), up from 2,241/2,242 by the three
tests. `integration-test -Drhi=metal` passes 106/111, with five skips. M27 Step 9 also recorded five,
but the two sets were not compared one by one. fmt, the four `check` variants, the four thirty-frame headless runs and `fdt-check`
are clean. There is no ABI, shader, Vulkan or content change.

## Resolution — Step 6: the generated corner, proved on Metal (2026-10-23)

**What exists now:** `samples/sandbox3d/generated.zig`, wired into `main.zig`. The corner is
centred at x = 20, past the crate grid's last row (±9.6 m) and away from every tour position.
`FOUNDRY_SANDBOX3D_GENERATE=background|inline|off` chooses how the landmark is made.

- **The patch.** A 65×65 heightfield from two octaves of seeded value noise, 0.2 m apart.
  - Its normals are analytic, from the noise's own derivatives. Every normal is within 45° of
    up, and a test checks that.
  - It is generated before the first tick. One set of world-space triangles goes both to the
    renderer, through the builder, and to the walk's `physics3d.World` as a static mesh body.
  - A pinned headless test walks it: it settles for 30 ticks, then moves for 150 ticks along
    (1, 0, 0.3), ending grounded at (22.390009, 0.074692, 1.227917). The patch's digest is
    pinned (`11729102987930533220`).
- **The water.** 129×129 vertices, 12 × 6 m, a sum of three sines of simulation time (I9).
  - Each wave's phase is split into a column term and a row term, so a fill takes one sine and
    one cosine per row and per column (about 800 calls) rather than per vertex (about
    100,000). Generation alone fell from about 3.5 ms to 0.47 ms on the Mac.
  - Its bytes at t = 1.5 s are pinned (`8743190568358611974`).
- **The canvas.** 1024², linear-filtered, without mips, bound by a `Content.createMaterial`
  with a `runtime` texture.
  - A soft 64² stamp is blended into a CPU copy of the canvas and written with `writeTexture`,
    at most once a tick, where the player's look meets it within 5 m. **C** clears it.
  - `FOUNDRY_SANDBOX3D_PAINT=auto` paints a fixed figure-of-eight every tick instead, so a run
    nobody watches still measures §1's criterion 3. This switch is new here: §8 assumed a
    person would be looking.
  - Tests cover stamp clipping, and a look that misses or is out of reach. They also cover a
    look from behind and an eye on the canvas's plane; the mutation round below found both
    untested.
- **The landmark.** A 1024 × 1024-segment spire of revolved, fluted rings: 1,050,625 vertices
  and 6,291,456 indices, with its digest pinned (`17175394173672716032`). A test checks the
  bytes are the same from a `Manual` pool task as from a direct call. It is requested on tick
  240, two seconds after the gallery's tick, and the frames around it are measured with M27's
  `gallery.Window`, which now takes a label and a pump span.
- **The recoloured crate.** The compiled crate model, with slot 0 overridden by a
  `Content.createMaterial` that tints and binds `sandbox3d:models.crate.texture0` by content ID.
- **New keys:** **T** puts the player on the patch, facing the canvas. **R** calls
  `Engine.reloadContent`. Both join `FOUNDRY_SANDBOX3D_KEYS`, with C.
- **Package additions:** three materials for the patch, the water (blended, `casts_shadow
  false`) and the landmark.

**What measurement changed in M28's code**, both recorded as dated notes in §6 and §8:
1. **`Uploads` validates on the pool.**
   - The landmark's first background run kept every frame under 16.67 ms. But its
     `uploads.pump` reached 12.15 ms, because the finish re-ran `Mesh.validate` and computed
     `submeshBounds`, both linear in 6.3M indices, on the main thread.
   - The fill now does both. The finish takes the measured boxes through
     `Renderer.PreparedMesh`, whose count is checked, and does not validate again.
   - The cost is that a mesh that does not validate fails at its finish (`failure`), rather
     than being refused at the request. Uploads exist for geometry too big to validate on the
     frame, so this is the trade §6's own argument makes for the copy.
   - The pump's maximum fell to 0.15–0.39 ms.
2. **The water is pooled by default.**
   - The direct `Renderer.updateMesh` path measured 2.0 ms at p95 in the paced sample, against
     the 1.0 ms budget. A probe split it: validation 576 µs, the boxes 379 µs, the copy 93 µs,
     the staging reservation 1 µs and the submission 60 µs.
   - **The same call takes 0.21 ms back to back, and 1.37 ms with a 14 ms sleep between calls**
     (a `render3d` probe on the Metal device, not committed). Removing the sample's pacing
     sleep did not help, because it then waits on the drawable. The cost is what the frame's
     idle time does to the core and its caches, not the renderer's code.
   - The pooled default generates each sheet on `Engine.tasks()` and requests
     `Uploads.updateMesh`. That leaves the main thread the request, the next generation's
     start and the finish: p95 0.14–0.26 ms.
   - The sheet arrives a frame or two after its tick, which is presentation (ADR-0061). 597
     updates land in 600 frames.
   - `FOUNDRY_SANDBOX3D_WATER=inline` keeps the direct path as the baseline.

**§12's two measured triggers:**
- **A mesh capacity or reserve option: not fired.** Every water update fits its buffers, so no
  update reallocated at all, against a trigger of 10% of an update's p95. The landmark is a
  create.
- **A persistently mapped per-frame ring: not fired.** The pooled water's p95 is under 1.0 ms.
  The inline path's 2.0 ms is validation and boxes on an idle-cooled core. Staging reservation
  measured 1 µs and the copy 93 µs, and a ring removes neither validation nor boxes. A ring
  answers GPU-wait or allocation stalls, and neither was measured.

**§1's exit on Metal** from a relocated ReleaseSafe install: `zig build install -Drhi=metal
-Doptimize=ReleaseSafe` to a staging prefix, moved, then run from the new place. Windowed, on
an Apple M5, 4x MSAA, 600 frames with the gallery off. Three runs each way, alternated:

| Run | Landmark path | Frame work median / p95 / max (ms) | `uploads.pump` p95 / max (ms) | Request to ready | Water p95 (ms) | Canvas p95 (ms) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | background | 1.345 / 1.578 / **2.582** | 0.151 / 0.198 | 133.3 ms | 0.150 | 0.208 |
| 1 | inline | 1.290 / 1.753 / **132.801** | 0.150 / 0.164 | 120.9 ms | 0.143 | 0.205 |
| 2 | background | 1.282 / 1.671 / **2.553** | 0.139 / 0.145 | 133.4 ms | 0.151 | 0.261 |
| 2 | inline | 1.389 / 1.665 / **132.639** | 0.221 / 0.387 | 120.4 ms | 0.256 | 0.290 |
| 3 | background | 1.375 / 1.578 / **2.498** | 0.162 / 0.209 | 133.2 ms | 0.151 | 0.200 |
| 3 | inline | 1.400 / 1.545 / **131.005** | 0.144 / 0.151 | 119.1 ms | 0.141 | 0.206 |

1. **The water: holds.** p95 0.141–0.256 ms against 1.0 ms, pooled. The inline baseline
   measured p95 2.026 ms, of which `updateMesh` was 1.492 ms.
2. **The landmark: holds.** Every background maximum is at most 2.582 ms. Every inline maximum
   is at least 131.0 ms, so the inline frame exceeds 16.67 ms as §1 requires, and the
   1024 × 1024 size is pinned.
3. **The canvas: holds.** p95 0.200–0.290 ms against 0.5 ms.
4. **The patch walk: holds**, by the pinned headless test.
5. **The recolour: holds.** During a run, the installed `crate.png` was replaced, and a
   scripted **R** reloaded every package. The log reads "recolour: material 18.1 kept, binding
   texture 13.1 (was 7.1)". The file was restored afterwards and checked byte for byte.
6. **Tour, walker and court: hold.**
   - **The tour:** headless and windowed from the install, the player's hash stays
     `cb99ccfcf2b6d6c3` and the walker's `62ed8c026c20482c`, with the landmark arriving during
     the run.
   - **The court:** the `win`, `caught` and `fell` endings replay tick for tick headless, over
     1213, 112 and 185 ticks. The windowed `win` replays 1216 ticks.

Criterion 7, Vulkan validation, is Step 7's.

**One pre-existing warning is not M28's:** `content(0xdf3a2f1da5dcb6c5)`, "fields unread by its
shading model are ignored". It appears with the corner off too. The water's own warning, for
blending while casting shadows, was fixed by `casts_shadow false`.

**Guards verified by mutation**, with the round time-limited:

| Mutation | Caught by |
| --- | --- |
| The prepared boxes' count unchecked | the new renderer test |
| The fill not validating | `Uploads`' fails-at-its-finish test |
| A fill error ignored at the finish | the same test |
| A stamp not clipped at the left | the canvas test, which crashed on the out-of-range write |
| A look beyond reach painting | the canvas test |
| An unknown generate mode taken as `background` | the switch test |
| The patch's normals not analytic | the patch test, by its digest |
| A look from behind painting | the canvas test, once its from-behind case was added |
| The water's phase reversed | the water test, once its bytes were pinned |

The last two survived the first round and led to the tests that catch them.

**Tests:**
- `sandbox3d-test`: 33 of 33, with five new.
- `render3d`: 95, adding the prepared-mesh refusal and the fill-validation failure.

**Not done, as designed:** Windows/Vulkan and criterion 7 (Step 7), and the close (Step 8).

**Bar:** `zig build test` **2,251/2,252** (one skip, unchanged), up from 2,244/2,245 by the five
corner tests and the two `render3d` tests. On Metal, `render3d-test` passes 95/95 and
`sandbox3d-test` 33/33. fmt, the four `check` variants, the four thirty-frame headless runs and
`fdt-check` are clean. The package's change is three material records. `dist` stages no
`sandbox3d`, so the relocated install above is that change's staging proof. There is no ABI,
shader or Vulkan change.

## Resolution — Step 7: Windows/Vulkan (2026-10-23)

§1's seven criteria hold on Windows/Vulkan, validation-clean, with nothing in the engine
changed by the step.

**The machine and the setup:**
- The PC's Intel Arc A750 under Windows 11, Vulkan 1.4, with the pinned SDK 1.4.357.0 and Zig
  0.16.0.
- The PC had held no Foundry clone since M27's close. A bundle of local `main` at `1f624e8`
  was cloned into a fresh `src\Foundry-m28`, its hash checked and its checkout confirmed clean.
- The harness is `scripts/m28/windows.ps1`, after M27's.
  - **`build` mode ran over SSH:** the suites, then a ReleaseSafe install moved to `relocated`.
    That install was denied write, append, attribute and delete rights, and its 148 files were
    hashed. They were unchanged afterwards.
  - A writable copy, `reloadable`, holds the one run that edits a texture beneath it.
  - **`desktop` mode ran in the desktop session** from a scheduled task, at normal integrity,
    so the loader honours the layer filter. `PATH` was reduced to the system directories, and
    `APPDATA` and the save directories were disposable.
- `build` mode started at `-j2` and below-normal priority. With the PC idle, its processes were
  raised to normal priority in place, at the owner's word, without restarting anything.

**The suites:**
- null, Debug: **2,230/2,240** (ten skips);
- Vulkan, Debug, whose test binaries require synchronization validation: **2,511/2,532**
  (21 skips);
- Vulkan, ReleaseSafe: `render3d-test`, `sandbox3d-test`, `model-content-test` and
  `court-test`, **172/172**;
- in the desktop session: `native-window-test` 8/9 (one skip) and `vulkan-window-test` 10/10.

The skip counts are M27 Step 10's, ten and 21. The Vulkan suite includes Step 3's
before-and-after readback of a mesh, a region and a chain, and Step 4's comparison of an
`Uploads` mesh with `createMesh`'s, now on Vulkan as well as Metal. The patch walk's pinned end
position held on x86_64, to the tolerance pinned on the Mac.

**§1's corner, windowed from the read-only install:** 600 frames, the gallery off, painting
auto, API validation off. Three runs each way, alternated:

| Run | Landmark path | Frame work median / p95 / max (ms) | `uploads.pump` p95 / max (ms) | Request to ready | Water p95 (ms) | Canvas p95 (ms) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | background | 0.530 / 0.870 / **4.189** | 0.108 / 3.602 | 167.2 ms | 0.092 | 0.129 |
| 1 | inline | 0.582 / 0.755 / **172.256** | 0.092 / 0.132 | 154.8 ms | 0.105 | 0.146 |
| 2 | background | 0.512 / 0.776 / **5.330** | 0.111 / 3.303 | 167.2 ms | 0.088 | 0.125 |
| 2 | inline | 0.548 / 0.723 / **176.422** | 0.094 / 0.138 | 155.3 ms | 0.104 | 0.147 |
| 3 | background | 0.628 / 0.876 / **5.310** | 0.164 / 3.445 | 166.8 ms | 0.126 | 0.144 |
| 3 | inline | 0.659 / 0.866 / **175.934** | 0.117 / 0.200 | 155.0 ms | 0.109 | 0.162 |

1. **The water: holds.** p95 0.088–0.126 ms, pooled. The inline baseline measured p95
   1.253 ms (`updateMesh` 1.039 ms, generation 0.181 ms). The first attempt's inline run
   measured 0.951 ms: on the Arc's machine the direct path sits at the budget, where on the
   Mac it is twice over.
2. **The landmark: holds.** Every background maximum is at most 5.330 ms. Every inline maximum
   is at least 172.3 ms, so exceeding 16.67 ms holds here too at the size pinned in Step 6.
   - The background frame's maximum is the landmark's finish: `uploads.pump` reaches 3.3–3.6 ms
     in that frame. It creates three device-local buffers totalling about 37 MiB and records
     their copies. `vkAllocateMemory` is M27 Step 10's known cost on this machine.
   - A pooled water finish shares that pump, which is why the water's maximum is the same
     3.3–3.6 ms. Its p95 is unaffected.
3. **The canvas: holds.** p95 0.125–0.162 ms. One maximum of 3.0 ms is a single frame, and the
   criterion is the p95.
4. **The patch walk: holds**, by the pinned test, natively.
5. **The recolour: holds.** Under synchronization validation, `crate.png` was replaced beneath
   `reloadable` three seconds into the run, and a scripted **R** reloaded every package. The log
   reads "recolour: material 18.1 kept, binding texture 13.1 (was 7.1)".
   - The reload frame's work was 34.3 ms. That is `Engine.reloadContent`'s synchronous
     re-read, under validation. Nothing in §1 bounds it.
6. **Tour, walker and court: hold**, each with and without validation:
   - the tour's player hash stays `cb99ccfcf2b6d6c3` and the walker's `62ed8c026c20482c`;
   - the court's `win`, `caught` and `fell` replay tick for tick: 1217–1220, 112–113 and
     189–190 ticks, and 46/46, 7/7 and 6/6 steps.
7. **Vulkan validation: clean.** It ran with synchronization validation on, over the
   background and inline corner, the recolour, the tour and the six plays. Every log has zero
   errors, warnings, VUIDs and hazards, and each carries the layer's own info line, so the log
   was live.

**One false start, in the harness, not the engine.** The first desktop attempt stopped at its
own evidence check, after the inline water run, because the pattern expected `129.` for
"129²". Windows PowerShell reads the UTF-8 log in the system code page, so "²" arrives as two
characters. The pattern is now `129.+`. A new `-Evidence` folder let the second attempt rerun
the whole desktop mode against the same install, and the first attempt's logs were kept. Its
nine completed runs agree with the second's: water p95 0.100–0.150 ms, landmark background
maximum 5.2–6.4 ms, inline about 175 ms, canvas p95 0.149–0.185 ms.

**Linux:** compile only, as §10 assessed. The Linux null cross-check passes in the Mac bar, and
nothing Linux-specific changed.

**Left on the PC for Step 8:** `src\Foundry-m28` (clean at `1f624e8`) and the evidence under
`%USERPROFILE%\m28`. Step 8 removes both, by exact path, when M28 closes.

**Bar:** the Mac bar last ran at `1f624e8` (Step 6), and this step changes no Zig, content or
build file. Its only files are the harness and these documents, so no Mac bar was re-run. The
PC ran the full suite natively on that same commit, above.
