# Design: `asset` — bytes become things the engine can use

**Status:** Partly implemented as `engine/src/asset/`. M2 built the PNG decoder and
`loadImage`; everything in §2 onward is design for M3.
**Date:** 2026-09-04
**Implements:** I1, I2, I3, I5, I6, I8 · **Informed by:** ADR-0005, ADR-0006, ADR-0015,
ADR-0018, ADR-0019, ADR-0021

`asset` is layer L2, depending on `core`, `data` and `platform`. It is the module that has
both a filesystem and the content model, which makes it the seam between them: **`data`
cannot open a file and `render2d` should not, so opening files on content's behalf is this
module's job and nobody else's.**

Its existing module doc already draws the other boundary and it does not move: `asset` owns
nothing on the GPU. It produces bytes and decoded data in ordinary memory; `render2d` turns
an `Image` into a texture and owns it from there (`render2d.md` §8).

Everything here parses input from files, which means input from mods, which means untrusted
input: validated and refused, never asserted.

---

## 1. What M2 left, and what M3 replaces

M2 built exactly two things and deliberately no more: an RGBA8 `Image`, and a PNG decoder
that produces one (ADR-0018). `asset/root.zig` says why the rest was left out —

> It has no registry, no content IDs, no reference counting and no hot reload — because the
> asset ID scheme is a decision deliberately postponed to M3, and a half-built registry now
> would resolve it by accident. Callers pass a path, and paths are what M3 replaces.

ADR-0021 has now made that decision, and this document is what M3 builds on it. **The
path-taking API goes away.** `loadImage(path)` was scaffolding with a stated expiry, not an
interface.

---

## 2. An asset is a record

ADR-0021's decision, restated because everything below depends on reading it exactly right:

> An asset is content. Its identity is its `ContentId`. A path may *derive* an ID at compile
> time, as a default for a field an author may write instead. A path is never what identity
> *means*, and no runtime code resolves anything by one.

So a texture is a record like any other:

```
texture foundry:texture.sprites {
    source "textures/sprites.png"
    filter nearest
    wrap   clamp
}
```

The engine registers the schemas for the kinds it can load — `foundry:texture`,
`foundry:shader`, `foundry:sound` — through the same runtime registration a mod's `@schema`
uses (I6). They are mechanisms, not content: an engine that can load a texture has not thereby
hardcoded a game (I5).

`source` is meaningful **only to `fpack`**, at compile time. It does not reach the runtime as
identity, and the runtime cannot ask "what is at this path".

### Why this is worth the trouble

Because path identity fails the way load-order identity fails. An engine that finds
`textures/sprites.png` by looking for `textures/sprites.png` has made its own directory
layout a permanent public interface: it can never reorganise, and a mod replacing a texture
must reproduce the base game's folders exactly to be found — path-shadowing, which breaks
quietly, on the user's machine, for reasons nobody in the chain can see.

With identity in the ID, `content/core/` can be reorganised freely and a mod overriding
`foundry:texture.sprites` says only that. It does not know where the original lives and does
not need to.

---

## 3. Derivation, specified

Authoring five thousand sprites must not mean authoring five thousand records, so `fpack`
derives the ID when the author does not write one.

**The function.** For a file at package-relative path `p`, in a package whose namespace is
`ns`: drop the extension, replace each `/` with `.`, and prefix `ns:`.

```
package foundry,  textures/ui/panel.png   ->   foundry:textures.ui.panel
package foundry,  shaders/water.msl       ->   foundry:shaders.water
```

It is a pure function of the path, and only of the path: it does not consult the file's
contents, its kind, or its loader. A mod author can therefore compute an asset's ID by
looking at it, which is most of the value.

**It transforms nothing.** Every path segment must already be a valid ID segment by the rule
in `content-schemas.md` §2 — `[a-z][a-z0-9_]*`. A file called `Panel-01.png` does not become
`panel_01`; it is an error saying the segment is not a valid ID and offering the two ways
out: rename the file, or write the ID explicitly.

This is deliberate, and it is the same principle `core/id.zig` states for hashing. A
transformation is a second specification — every external mod tool would have to implement
it identically, and any divergence produces IDs that differ invisibly. Refusing to transform
means there is nothing to reimplement.

**Collisions are errors naming both files.** Two files whose paths differ only in extension
derive one ID. `fpack` reports both paths and stops; last-one-wins is how content gets lost
without anyone noticing.

**Which files are candidates.** `fpack` walks the package directory, and a file whose
extension is registered to an asset kind becomes an asset record — unless an authored record
already names that path in its `source`, in which case the authored record wins and nothing
is derived. Explicit always beats implicit, and never silently duplicates it.

**Derivation is a compile-time convenience with no runtime trace.** `fpack` materialises the
derived ID into the `.fpk` exactly as if it had been written by hand. This is the structural
half of ADR-0021: the runtime is never given the chance to learn about paths, so it cannot
come to depend on them.

**Stability, and its honest hole.** A derived ID lasts as long as its path. Moving a file
changes the derived ID, and the signal is a reference that stops resolving — a build-time
error, but one that names the reference rather than the move. Writing the ID explicitly makes
it permanent. ADR-0021 records the intended fix: a per-package ID ledger so `fpack` can tell a
move from a deletion-plus-addition and refuse to mint a new ID silently. Deliberately not
built in M3.

---

## 4. The registry

Content ID in, handle out. The registry is the only way to reach a loaded asset.

```zig
pub const AssetHandle = core.Handle(Asset);

pub const Registry = struct {
    /// Resolve and load if needed; increments the reference count.
    pub fn acquire(self: *Registry, id: ContentId) AcquireError!AssetHandle;
    /// Decrement. Reaching zero makes it evictable, not immediately freed.
    pub fn release(self: *Registry, handle: AssetHandle) void;
    /// The loaded payload, or null if the handle is stale.
    pub fn get(self: *Registry, handle: AssetHandle) ?Asset;
};
```

**Reference counted, but not eagerly freed.** Reaching zero marks an asset evictable; eviction
happens at a defined point, in bulk. A texture whose count touches zero between two levels
that both use it should not be unloaded and reloaded, and immediate freeing makes that the
default behaviour rather than an unlucky case.

**Handles, not pointers, and this is where I1 earns its keep twice over.** A stale handle
fails a lookup instead of reading freed memory; and hot reload works by swapping what a
handle points at, so every holder follows without knowing anything happened.

**A failed acquire is a value, not a crash.** A missing or malformed asset is normal when
mods are involved. The registry reports it, names the ID, and — in development builds —
substitutes a visible placeholder, because a magenta texture is diagnosable from across the
room and a black one is not.

---

## 5. Loaders are registered at runtime, including ours

A loader turns a record plus its source bytes into a payload the registry holds opaquely.

```zig
pub const Loader = struct {
    schema: SchemaId,
    load: *const fn (ctx: *anyopaque, gpa: Allocator, record: Record, bytes: []const u8) LoadError!*anyopaque,
    unload: *const fn (ctx: *anyopaque, gpa: Allocator, payload: *anyopaque) void,
    ctx: *anyopaque,
};
```

I6 requires the registry to accept entries a mod could also supply, and this shape does. It
also resolves a layering problem cleanly rather than by exception: **`render2d` is L3 and
`asset` is L2, so `asset` cannot know what a GPU texture is** — and it does not need to.
`render2d` registers a loader for `foundry:texture` at startup; the payload it returns is its
own `TextureHandle`, opaque to the registry, freed by the same module that made it.

The dependency points downward and the capability points upward, which is what
runtime-registered loaders are *for*.

### Shaders, and one thing not to tidy

The roadmap says shaders become assets at M3, and ADR-0015 is what it means: a material
references `foundry:shader.water`, carrying per-backend variants selected at load.

ADR-0019 draws the line and it is easy to erase by accident: **engine-owned shaders stay
embedded in the binary.** The sprite shader is not overridable content — it is the other half
of a contract with the batcher's vertex layout. A future session finding an embedded shader
and "moving it into the content system for consistency" would be undoing a decision, not
finding an oversight.

---

## 6. Hot reload

Development builds only; shipped builds never watch anything.

The mechanism follows from §4: recompile the changed package, then swap the payload behind
the existing handle. Nothing that holds the handle is notified and nothing needs to be.

Three rules that matter more than the mechanism:

1. **Never mid-frame.** Changes are detected and queued; the swap happens at a defined point
   at the start of a frame, before simulation. A texture replaced between two draws in one
   frame is a class of bug worth never having.
2. **A failed reload changes nothing.** The new content is compiled and validated *before* the
   old payload is released. A syntax error while typing must leave the running program with
   the last thing that worked, and say so — not with a hole.
3. **Deterministic.** Queued changes apply in a documented order, so a reload of many files
   produces the same state as reloading them one at a time (I9).

---

## 7. Errors

| Error | Meaning |
| --- | --- |
| `AssetNotFound` | No record with that content ID in the merged store. |
| `SourceMissing` | The record exists; its `source` file does not. Different failure, different fix. |
| `WrongSchema` | The record exists but is not an asset kind, or not the kind asked for. |
| `NoLoader` | Nothing is registered for that schema — usually a subsystem not yet initialised. |
| `InvalidAsset` | The bytes are not what they claim to be. Decode failure, from `DecodeError`. |
| `UnsupportedVersion` | The asset's format version is newer than this build understands (I8). |

The M2 test that separates "your texture is corrupt" from "your texture is missing" was
written to pin that distinction, and it survives: the reasons a load can fail stay
distinguishable at the call site, because the useful answer to a mod author is which one it
was.

---

## 8. What this exposes to mods

Acquiring by content ID, and registering a loader. That is the whole surface, and it is
enough for a mod to add an asset *kind* the engine has never heard of — the interesting case,
and the one I6 exists for.

Not exposed: paths, the filesystem, the registry's internals, or the payload's type. A mod
gets an opaque handle and the loader that made it, which is the same deal the engine gives
itself.

---

## 9. Open questions

1. **Eviction policy.** §4 says zero-count assets become evictable, not freed. *When* eviction
   runs — budgeted, on level transition, never — is unanswered, and answering it before there
   is a memory number to look at would be guessing.
2. **Streaming and async loading.** Everything here is synchronous. Nothing in the design
   forecloses async, and the job system is a post-M5 decision (CLAUDE.md §9); this is a
   deliberate non-answer rather than an omission.
3. **Asset dependencies.** A material referencing a shader referencing a texture is a graph,
   and acquiring the root should acquire the rest. Whether that is a loader's business or the
   registry's is open until the material system exists.
4. **The ID ledger.** ADR-0021 names it as the fix for §3's stability hole. Due when a rename
   silently breaks something in practice — or before `docs/modding/` tells anyone that derived
   IDs are safe.

---

## 10. Deliberately not here

* **GPU resources.** `render2d` owns textures, including their retirement queue
  (`render2d.md` §9).
* **The content model.** Schemas, packages, merge and the `.fdt` and `.fpk` formats are
  `content-schemas.md`.
* **Mod discovery and load order.** M7. `asset` consumes a merged store; it does not assemble
  one.
* **Audio decoding.** M5. `foundry:sound` is named here so the shape is uniform, not because
  anything decodes one yet.
