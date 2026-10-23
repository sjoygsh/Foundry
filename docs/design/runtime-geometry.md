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
| 4 | Writes and destroys of meshes and textures are refused between `begin` and the end of `recordFrame` (`error.InFrame`); a write is seen by the next frame recorded and never by one already submitted | §4.2 |
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
