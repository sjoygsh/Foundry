# Design: `asset` — bytes become things the engine can use

**Status:** Implemented in full as `engine/src/asset/`, plus `tools/fpack/` for §3's
derivation, `render2d/loader.zig` for §5's texture loader and `app` for §6's watcher.
`loadImage` is gone. The three Resolution sections at the end record what building it
settled.
**Date:** 2026-09-04, revised 2026-09-05
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
interface. *Removed 2026-09-05; the test that made it worth having — a missing file and a
corrupt one staying distinguishable — moved into the registry's, which is where the
distinction is now made.*

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

`source` is **location, never identity**, and the difference is the whole decision. Nothing
can be looked up by path: `acquire` takes a `ContentId` and there is no other way in. A record
found that way may then say where its own bytes live, and the registry reads them — which is
what §7's `SourceMissing` has always described. So `source` is an ordinary field a mod
changes in one line without any reference, save or other package noticing, and no caller can
turn a path back into an asset.

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
pub const AssetHandle = core.Handle(Assets);

pub const Registry = struct {
    /// Resolve and load if needed; increments the reference count.
    pub fn acquire(self: *Registry, gpa: Allocator, id: ContentId) AcquireError!AssetHandle;
    /// The same, refusing anything that is not the record type asked for.
    pub fn acquireOf(self: *Registry, gpa: Allocator, id: ContentId, schema: SchemaId) AcquireError!AssetHandle;
    /// Decrement. Reaching zero makes it evictable, not immediately freed.
    pub fn release(self: *Registry, handle: AssetHandle) void;
    /// The loaded payload, or null if the handle is stale.
    pub fn get(self: *Registry, handle: AssetHandle) ?Asset;
    /// Unloads every asset at zero references, and says how many. Nothing calls it on
    /// its own — see §9's first open question.
    pub fn evictUnused(self: *Registry, gpa: Allocator) u32;
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
    ctx: ?*anyopaque = null,
    load: *const fn (ctx: ?*anyopaque, gpa: Allocator, record: Record, bytes: []const u8) LoadError!Payload,
    unload: *const fn (ctx: ?*anyopaque, gpa: Allocator, payload: Payload) void,
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
| `SourceRejected` | The `source` field is not a path a package may name. *Added in implementation.* |
| `LoadFailed` | The loader failed for a reason that is neither the bytes' fault nor a version. *Added in implementation.* |

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

---

## Resolution: derivation and `fpack` (implementation, 2026-09-04)

§3 specified a function and a rule, and building the tool around them settled five things
the specification did not have to.

**The asset schemas live in `asset`, and the loaders stay above.** §5 puts the texture
loader in `render2d`, which is L3 and cannot be seen from a content compiler. But the
*record* — a source path, and later its sampling parameters — is not a GPU concept, and
`fpack` has to know it at compile time without linking a renderer. So `asset/schemas.zig`
holds the schema and the extension table, `render2d` will register the loader that reads
it, and the dependency still points down while the capability points up.

**`foundry:texture` has one field for now.** §2 sketches `filter` and `wrap` beside
`source`, and they arrive with the loader that reads them, at version 2, with defaults —
which is exactly the case additive versioning exists for. Adding them now would mean
deciding how an enumeration is spelled in `.fdt` with nothing to check the decision
against, and the type list is closed (`content-schemas.md` §3). This is the cheap half of
I8: the schema can grow, and content written against version 1 keeps working.

**A derived record is `.fdt` text, parsed and checked like any other.** §3 says a derived
id is materialised "exactly as if it had been written by hand", and the cheapest way to be
sure of that is for it to *be* written — into a buffer named `<derived>`, then through the
same parser and the same checker the authored records went through. A derived id that
collides with an authored one is then reported by the checker's existing "defined twice in
this package" message, with its note pointing at the authored record, rather than by a
second implementation of the same complaint.

**The package's name and version are arguments, not a file.** `fpack --name foundry:core`
rather than a manifest in the directory. `content-schemas.md` §11 defers mod manifests to
M7 and says `data` consumes a load order rather than computing one; inventing a manifest
format here would answer that question early, in the wrong place, and in a format nothing
else reads yet.

**Dot-prefixed names are skipped, and every listing is sorted.** `.git`, `.DS_Store` and an
editor's swap files are not content, and a package that had to enumerate its exclusions
would be a package with a manifest. Sorting is the I9 half: a filesystem's enumeration
order is not a specification, so the walk imposes one, and compiling the same directory
twice produces the same bytes — which is a test.

---

## Resolution: the registry (implementation, 2026-09-05)

§4 through §7 became `asset/registry.zig` and `render2d/loader.zig`. Six things the
specification left to the implementation, and one it asked for that it did not get.

**`source` had to become a runtime read, and saying so cost nothing.** §2 said `source` was
meaningful "only to `fpack`", and §7 simultaneously specified a `SourceMissing` error that
only a runtime file read can produce. The second is right and the first was imprecise:
ADR-0021's promise is that *nothing can be looked up by path*, and that is kept exactly —
`acquire` takes a `ContentId` and there is no other entry point. What a record says about
where its own bytes are is location, and location was never the thing the ADR was protecting.
§2 now says this in the words the code uses.

**A package's root is mounted here, not carried by `data`.** Resolving `source` needs to know
where a package's files are, and `data.store.LoadedPackage` documents its own label as
diagnostics-only — reusing it would have quietly made a diagnostic string load-bearing. So
`Registry.mount(package, root)` is a separate call, in the module whose job is having a
filesystem. §10 stays true: `asset` still consumes a merged store and assembles nothing.

**A payload is one 64-bit word, not a `*anyopaque`.** §5's sketch made it a pointer, and
`render2d`'s payload is a `TextureHandle` — a value, not an allocation. A pointer-shaped
payload would force every handle-producing loader to box two `u32`s for no reason. A word
holds either, and it is already the shape the public ABI publishes a handle in (ADR-0004),
so `core.Handle` gained `bits`/`fromBits` and the packing is written down once.

**§7's table gained two rows.** `SourceRejected` for a `source` that is not a path a package
may name — the security-relevant half of `SourceMissing`, and merging the two would file a
package trying to read outside itself under "not found", where nobody would look. And
`LoadFailed` for a loader failing when neither the bytes nor a version are at fault: the
device refused the texture, the file could not be read. Calling that `InvalidAsset` sends a
mod author to inspect a file that is perfectly fine.

**`foundry:texture` is version 2, and version 1 content still loads.** `filter` and `wrap`
arrived with the loader that reads them, appended with defaults — the case additive
versioning exists for, and the cheap half of I8 made real rather than asserted: a package
compiled when the schema had one field is read against the version it carries, and the rest
is filled from the newest schema's defaults. That is a test.

They are **strings**, because the type list is closed (`content-schemas.md` §3) and there is
no enum type. The domain is therefore only knowable in the loader, whose enum tag names *are*
the content spelling, so the two cannot drift. An unrecognised spelling warns and falls back
rather than refusing the texture: answering a typo with a missing sprite is the least
diagnosable outcome available.

**Eviction is a call nobody makes.** §4 said zero references means evictable, not freed, and
§9's first open question is *when* eviction runs. Both are honoured literally:
`evictUnused` is the mechanism, and nothing invokes it on a schedule. A texture released
between two levels that both use it stays resident and comes back without a decode, which is
a test.

**What §4 asked for and did not get: the development-build placeholder.** "A magenta texture
is diagnosable from across the room" is right, and it is not built. It cannot live in the
registry, which does not know how to make a texture of any colour, so it would be an optional
third function on `Loader` — cheap, and worth adding when there is a game to see it in. What
exists now is the half that cannot be deferred: a failed acquire is a value naming the ID and
the reason, and every one of §7's failures is separately reachable in a test.

---

## Resolution: hot reload (implementation, 2026-09-05)

§6 asked for three rules and got them literally. What it did not say, and building it
settled:

**Nothing recompiles anything at runtime.** §6 says "recompile the changed package", and
the engine does not: `fpack` compiles, the engine *reloads*. The watcher stamps every
package file and every loaded asset's source, and a change to either is picked up — so the
loop is edit, `zig build` (or `fpack` alone, which is faster), and the running program
follows without restarting. Putting a content compiler inside the engine would mean shipping
one in every build to serve a development path, and the value of hot reload is the process
not dying, not who ran the compiler.

**A reload builds a whole new content set and swaps it.** Rule 2 — "a failed reload changes
nothing" — is not a check, it is a shape: a fresh schema registry, store and byte set are
built to one side, and only a complete one is ever swapped in. A package caught mid-save
leaves the running program with the last thing that worked and a line saying why, and the
generation counter does not move, so nothing downstream re-derives from a state that never
happened.

**The schema registry is rebuilt too, which is what makes editing a schema work.** Reusing
it would refuse any schema changed without a version bump — the registry's rule, correct and
extremely annoying in a development loop. Rebuilding costs nothing and the engine's own
asset schemas go back in the same way they did at startup.

**Reloading a package reloads every asset in it.** A record can now name a different file,
different sampler settings or a different record type, and none of that shows up as a
changed source file. Reloading all of them is the simple correct answer; comparing records
to reload only what moved is an optimisation with a correctness risk and no measurement
behind it.

**A handle follows a swap; anything derived from one does not.** §4 promises that "hot
reload works by swapping what a handle points at, so every holder follows without knowing
anything happened", and that is exactly true of the handle and exactly false of a `Region`
cut from a texture or a string borrowed from a package's bytes. So `app` publishes a
**generation counter**, and a caller that derived something compares it and derives again.
The sandbox is the worked example, and it copies its banner string rather than borrowing
it — the freed-bytes case is real.

**A file that changed into rubbish is complained about once.** The watcher stamps a source
even when reloading it failed, so a half-written PNG does not produce the same complaint
twice a second. The next real edit changes the stamp again and it is retried.

**Stamps are modification time *and* size.** A wall clock is not monotonic — a corrected
clock, a restored backup — and a coarse one can miss two edits in the same second. Two
fields agreeing is a much better answer than either alone, and hashing contents would mean
reading every watched file on every check.
