# ADR-0063: Runtime geometry is owned by handle, beside content, and changes in place

**Status:** Accepted 2026-10-23 (the owner asked for M28 Step 1; `docs/design/runtime-geometry.md`)
**Date:** 2026-10-23

## Context

`render3d` can already make a mesh, texture or material from code (ADR-0053: code builds the
same runtime mesh a file loads). But each one is fixed once it is made. Nothing says what
such a resource *is* relative to content, and nothing says what happens when one is destroyed
while another binds it.

M28 makes runtime geometry a first-class path: generated meshes, textures written by the CPU,
and materials made by code. Later milestones build on it:
- M29's particles;
- M62's terrain;
- M65–M67's voxels;
- M48, which publishes it to mods.

Three questions have to be answered once, before those milestones each answer them
differently.

The first is identity. Every piece of content is a namespaced content ID resolved at load
(I2, ADR-0021), and the asset registry is keyed by it. A generated mesh has no record and no
package. Giving it an ID would mean inventing one from creation order, which is exactly what
I2 forbids.

The second is change. A resource that must be destroyed and remade to change gives out a new
handle each time, and breaks every holder of the old one. `drawMesh` validates a draw at
submission, so a resource that changes between submission and recording breaks that check.

The third is lifetime. A material's bind group names its textures' GPU objects. Today a
caller must destroy materials before the textures they bind. `Content` is the only owner that
keeps that order, and it does so by care.

## Decision

1. **Runtime meshes, textures and materials are `render3d` resources named only by
   generational handle (I1) and owned by the code that made them.** They are not content.
   They have no content ID, they are not in the asset registry, no package can override
   them, and nothing saves them. A game that needs one in a save stores what generated it,
   such as a seed and parameters, and generates it again.
2. **References run one way.**
   - A runtime resource may refer to compiled content. A runtime material binds a compiled
     texture by content ID and follows its reloads, and it may override a compiled model's
     slot.
   - A runtime mesh may draw with a compiled material.
   - A record never names a runtime resource. It names content IDs, and a runtime resource
     has none.
3. **Contents change in place, and the handle survives.** A mesh may change completely. A
   texture keeps its size, format and colour space, and changes by region (when it has no
   mips) or as a whole chain. A material's description is replaced. A refused change changes
   nothing.
4. **Writes happen outside a frame's submission window.** Writes and destroys of meshes and
   textures are refused between `begin` and the end of `recordFrame`. A write is seen by the
   next frame recorded and never by one already submitted.
5. **A material keeps alive what it binds.** Destroying a texture that a live material binds
   invalidates the handle at once. Its GPU object is destroyed when the last such material
   is destroyed or rebuilt without it.
6. **CPU work may leave the main thread; the device does not** (ADR-0061, decision 5).
   Generation and staging fills may run on the background pool, and the device is touched at
   a main-thread pump. Arrival is presentation: simulation never reads whether a runtime
   resource is ready, and geometry that simulation needs is generated at a fixed tick, or
   joined there.
7. **Nothing is published before M48.** When M48 publishes this, it publishes these rules,
   with mod-owned handles as ADR-0059's instances are, and per-mod byte quotas.

> **Revision, 2026-10-23 (M28 Step 2, before any code depended on decision 4):** destroys
> inside the window are **deferred, not refused**. `destroyMesh`, `destroyTexture` and
> `destroyMaterial` return nothing, and the registry's loader unload, which calls them, has no
> way to receive a refusal.
> - A mesh or material destroyed inside the window is no longer drawable at once. It is still
>   recorded for the draws already submitted, and freed when the window closes.
> - A texture needs no deferral, because decision 5 already keeps a bound texture alive.
> - Decision 4's refusal (`error.InFrame`) now applies to writes only: Step 3's
>   `updateMesh`, `writeTexture` and `writeTextureChain`.
> - `updateMaterial` stays allowed in the window. `Content.drawModel` rebuilds materials from
>   inside a frame, and a submitted draw already keeps its pipeline key and binds the new
>   group.
>
> The intent is unchanged: no accepted draw is recorded against a check that no longer holds,
> and none vanishes.

## Consequences

- Generation, painting and recolouring work without touching packages, and without giving
  mods a way to depend on something that was never content. I2's guarantee is untouched:
  nothing derived from creation order is ever an ID.
- Holders keep their handles across every change. A water sheet rewritten every frame is one
  mesh for its whole life.
- `Content`'s teardown order stops being a correctness rule. Any caller may destroy a texture
  first.
- Cost: a texture tracks how many materials bind it, and a destroyed texture can outlive its
  handle until its last material goes.
- Cost: a game must make its writes outside the window. In practice that means in its tick or
  its pump, not mid-render. The refusal is a named error, not a silent drop.
- Cost: an in-place write after a frame has drawn the resource waits on the GPU for that
  frame's reads. That serialises a little GPU time, in exchange for no second buffer.
- Saves and the editor never see runtime geometry. A tool that wants to keep generated
  geometry has to export it as content, through the compiler, as a new asset with its own ID.

## Alternatives considered

- **Register runtime resources in the asset registry under synthetic IDs.** This was
  rejected. The IDs would come from creation order or a counter, which is I2's anti-pattern,
  and a mod could then name and override a resource that is not content.
- **Make every runtime resource immutable, and change by remaking.** This was rejected. It
  hands out new handles every frame for anything that moves, and breaks every material and
  draw that held the old one.
- **Allow writes at any time.** This was rejected. A draw validated at submission against a
  mesh that has since changed is recorded against a check that no longer holds.
- **Refuse to destroy a texture a material binds.** This was rejected. It forces an order on
  every caller, including `Content`'s reload, which releases textures before rebuilding the
  materials over them.
- **Double-buffer every mutable resource per frame in flight.** This was rejected for now. It
  doubles the memory of everything mutable to save GPU waits nobody has measured. A per-frame
  ring for meshes is the design's named answer if the water sheet's measurement asks for it.

## Revisit if

- A mod needs to override or depend on generated geometry by name. That is a reason to export
  it as content, or to reconsider decision 1.
- A measured update cost, the water sheet's p95 over 1.0 ms after staging reuse, needs
  double buffering or a persistently mapped ring instead of in-place writes.
- A save needs generated geometry's bytes rather than its generator's inputs.
- A milestone needs the GPU to write a texture (a render target), which this decision does
  not cover.
