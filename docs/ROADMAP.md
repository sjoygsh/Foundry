# Foundry Roadmap

Staged milestones from a minimal engine toward 2D, then 3D.

**Milestones are units of work, not units of time.** No dates. Sessions are bounded by
available context, so each milestone is sized to be resumable from `PROJECT_STATE.md` alone,
and each leaves behind something that runs.

**Rules for every milestone:**

* It produces a runnable result — `samples/sandbox` must still start and do something on
  macOS.
* `zig build test` passes.
* Non-rendering modules still **cross-compile** for `x86_64-windows` and `x86_64-linux`
  (ADR-0008). No obligation to *run* them there until a backend for those platforms exists.
* Any new dependency arrived with its `THIRD_PARTY_LICENSES/` entry in the same commit.
* `PROJECT_STATE.md` is updated. A milestone is not done until it is.
* Design docs for anything non-trivial are written **before** implementation, in
  `docs/design/` (see that directory's README for what is owed and when).

---

## Phase 1 — Foundation

### M0 — Skeleton: "it runs" — **complete (2026-09-03)**

The smallest useful version of Foundry. Deliberately excludes the GPU.

*Exit criteria met: `zig build run` opens a window on macOS that responds to input, and
both platform backends cross-compile for Windows and Linux. 222 tests.*

**Setup, before code:**

* Install the pinned stable Zig release from the official tarball at a versioned path; record
  version and SHA256 in `.zigversion` and `build.zig.zon` (ADR-0001, ADR-0014).
* **Verify the SDL3 Zig package builds against that release, for macOS first.** This is the
  main risk in M0; fallbacks are documented in ADR-0002. Record SDL3's zlib license entry in
  `THIRD_PARTY_LICENSES/` in the same commit.
* Confirm cross-compilation to `x86_64-windows` and `x86_64-linux` actually works before
  relying on it.

**Then:**

* `build.zig` with the module graph from ADR-0007, so layering is enforced from the first line
  of code.
* `core`: allocators (general, arena, pool), generational handle table, string IDs and hashing,
  logging with subsystem scopes, assertions, math basics, time, explicit RNG.
* `platform`: window creation, event pump, keyboard/mouse input, high-resolution clock,
  filesystem basics, opaque `NativeSurfaceHandle`. SDL3 confined here.
* `app`: fixed-timestep loop with interpolated render step (I9), subsystem lifecycle
  ordering, clean exit.
* `rhi`: interface definition plus the **null backend** only.
* `samples/sandbox`: opens a window, logs input, runs the loop, exits cleanly.
* Test harness running; a script that builds all three targets.

**Exit criteria:** a window opens and responds to input on macOS; Windows and Linux
cross-compiles succeed for the non-rendering modules.

**Not in this milestone:** anything drawn.

### M1 — First pixels: "it draws" — **complete (2026-09-04)**

*Exit criteria met: `zig build run -Drhi=metal` draws a rotating, nearest-filtered textured
quad that survives being resized, with Metal API and shader validation clean and the null
validation backend raising no complaints about the same command stream. 227 tests under
`-Drhi=null`, 235 under `-Drhi=metal`. Xcode GPU frame capture is confirmed by its
prerequisites — the sandbox runs clean under `MTL_CAPTURE_ENABLED=1` and shaders carry
`-frecord-sources` — but no trace has been opened in Xcode yet.*

Preceded by `docs/design/rhi.md` — **the highest-leverage document in the project.** It must
include the concept mapping table across Metal, Vulkan and D3D12 (ADR-0003). Designing the RHI
against Metal alone is the single most likely way to force a renderer rewrite later.

* Metal backend via the Objective-C shim (ADR-0012): device, command queue, `CAMetalLayer`
  from SDL3, pipeline state objects, buffers, textures, draw submission, resize handling.
* Metal shader build step: `xcrun metal` → `.air` → `xcrun metallib`, wired into `build.zig`
  (ADR-0015).
* Runtime MSL compilation path for development builds, giving shader hot reload.
* Null backend upgraded to a **validation backend** — enforcing the strict, Vulkan-shaped rules
  Metal silently forgives. This is what partially substitutes for not having a second backend.
* Metal API validation enabled in debug builds; Xcode GPU frame capture confirmed working.

**Exit criteria:** a textured quad on screen, surviving window resize, with Metal validation
clean and the null backend raising no complaints about the same command stream.

**Not in this milestone:** batching, materials, anything 3D-specific.

---

## Phase 2 — A real 2D engine

### M2 — Sprites: "it draws a lot" — **complete (2026-09-04)**

* Sprite batching; texture atlas support; texture loading from disk (PNG decode).
* 2D camera with pan/zoom; screen and world coordinate spaces.
* Bitmap text rendering.
* Frame statistics: frame time, draw calls, batch count.

**Exit criteria:** thousands of sprites at a stable frame rate, with a camera and on-screen text.

*Exit criteria met: `zig build run -Drhi=metal` draws 4,185 sprites at vsync under a camera
driven by keyboard and mouse, with the batcher's own statistics on screen in a screen-space
view that does not move when the camera does — 4 batches and 4 draw calls, because the sheet,
the font and the selection outline share one atlas. Metal API and GPU validation clean over
2,400 frames; the null validation backend raises no complaints about the same command
stream. 346 tests under `-Drhi=null`, 354 under `-Drhi=metal`, all eight target/backend
combinations compiling.*

*Read the batch count as M2's. At M3 step 9 the sample's images became assets, which arrive
as standalone textures, so it draws 5 batches now. `render2d`'s atlas is unchanged and still
covered by its own tests; the sample stopped using it, and making it an atlas again is a
decision about what an asset is (`docs/design/assets.md` §9).*

*Two things arrived that the entry does not name. `render2d` gained **views** — a per-frame
table of spaces rather than a screen/world flag — because the statistics readout needed a
second space and a boolean would have answered M2 and nothing after it. `rhi` gained
`dst_origin` on a buffer-to-texture copy, without which packing one sprite into an atlas
means re-uploading the whole thing; rule 10 in `rhi.md` §11 grew to match, before the code.*

### M3 — Content: "it has data" — **complete (2026-09-05)** — *first modding-relevant milestone*

* ~~Schema system: record types with typed fields, versioned.~~
* ~~Content packages, ordered load, override-by-ID (replace semantics first).~~
* ~~Authoring text format~~ — **syntax decided here** (`CLAUDE.md` §9). *Decided 2026-09-04:
  Foundry's own `.fdt` (ADR-0020), specified in `docs/design/content-schemas.md` §4.*
* ~~Runtime binary format and `tools/fpack` to compile one to the other.~~
* ~~`asset`: registry, loading by content ID, reference counting.~~ *Asset identity decided
  2026-09-04: assets are content records, and a path derives an ID but never defines it
  (ADR-0021), specified in `docs/design/assets.md`.*
  * **Shaders did not become assets, deliberately.** Engine-owned shaders stay embedded
    (ADR-0019) and the sprite shader is one; the only remaining case is a *content-owned*
    shader, which needs something to reference it. Building an asset kind with per-backend
    variant selection (ADR-0015) for no consumer would be exactly the hypothetical
    requirement rule 7 warns about. **Due with the material system**, which is Phase 4 or
    whenever a sample needs its own shader — and the asset kind is a schema and a loader
    registered at runtime, so nothing has to be reshaped to add it.
* ~~Hot reload of content and assets in development builds.~~
* ~~Base game content moved into `content/core` as package zero (I3).~~
* ~~`docs/modding/` begins.~~

**Exit criteria — all three met and seen, not inferred:**

1. *The sandbox's content lives entirely in data.* Its sprite sheet, its font, its sheet
   grid, its banner and its sprite count are records in packages; it embeds nothing and
   names no path. What remains in Zig is the sample's own behaviour — camera speeds, zoom
   limits, HUD margins — which is code, not content.
2. *A second package placed after it overrides a value and the change is visible.* A package
   compiled with `fpack` into `zig-out/content/` and named in `FOUNDRY_SANDBOX_PACKAGES`
   changed the sprite count from 4000 to 250 and replaced `foundry:fonts.debug` with an
   image at `whatever/i/like/glyphs.png` — a path mirroring nothing.
3. *Editing a content file live-updates the running program.* Under Metal, windowed: editing
   `sandbox.fdt` and recompiling the package changed the field from 4000 sprites to 300 and
   changed the banner text, mid-run, with a clean exit. Replacing a `.png` alone reloads the
   texture behind its handle with no package recompile at all.

**At this point Tier 1 content modding effectively works**, long before the mod system
exists — and `docs/modding/content-mods.md` is written by doing it, then verified by
following it verbatim.

### M4 — World: "it has entities" — **complete (2026-09-05)**

* Entity storage: generational handles, sparse set with dense per-component arrays.
* Type-erased component storage with runtime-registered `ComponentTypeInfo` (ADR-0010).
* `comptime` wrapper for ergonomic native component registration.
* Queries and iteration that do not leak storage layout, with **stable documented iteration
  order** (I9).
* System registration and ordered update.
* Save/load of world state in its own versioned format, sharing the field-block layout and
  schema encoding with the package format. **Not** through the record system: giving every
  entity a content ID would derive identity from position, which is what I2 forbids
  (`docs/design/entity-storage.md` §9).

**Exit criteria:** a scene of entities defined in content data, updated by systems, saved and
reloaded correctly across a restart. A fixed scenario run twice produces identical state.

### M5 — Playable: "it's a game" — **in progress, started 2026-09-05**

*Both `CLAUDE.md` §9 decisions that came due here were made before any code: physics is
Foundry's own, scoped to collision rather than dynamics (ADR-0022), and audio is Foundry's own
mixer and WAV decoding over the device `platform` was already chartered to provide
(ADR-0023). The sample is **top-down tile movement**, which is what decides that gravity and
slopes are out of M5's collision scope.*

* Tilemaps with efficient rendering and collision — `docs/design/tilemaps-and-collision.md`.
* 2D collision detection and response; spatial partitioning — the new **`physics2d`** module,
  L1 on `core` alone.
* Sprite animation: clips, state, timing — `docs/design/sprite-animation.md`.
* Audio: device output, sound loading, mixing, playback by content ID — the new **`audio`**
  module at L3, plus an audio device in `platform` and WAV decoding in `asset`;
  `docs/design/audio.md`.
* A small but genuinely playable sample in `samples/sandbox`.

*All three design documents are written (2026-09-05). Each carries its own implementation
order — §15, §13 and §10 respectively — and the three are independent sequences that share
only the frame that calls them. **Collision steps 1 through 4 are done**: `physics2d` is
complete as a module, with shapes, tile grids, the broadphase, `moveAndSlide`,
`resolveOverlaps` and the four queries. Remaining there: tilemap content and `fpack`'s
text-grid front end, drawing with view culling, and the sandbox's player meeting the map.
Audio and sprite animation have not started.*

**Exit criteria:** something a person can play for five minutes without knowing it is a tech
demo.

*On that last bullet and ADR-0017.* "Playable sample" and "a sample is not a game"
(`CLAUDE.md` §4.5) pull against each other, and the tension is resolved in favour of the
engine: the exit criterion is evidence that **Foundry can carry a game**, not that
`samples/sandbox` is one. It stays the smallest thing that exercises the capabilities — a
tilemap, a character that collides with it, an animation, a sound, and nothing that exists to
be impressive. The moment it starts wanting features rather than demonstrating them, it has
outgrown this repository, and the answer is a game in its own repository (ADR-0017), not a
bigger sample.

### M6 — Tools: "it's inspectable"

* In-process immediate-mode debug overlay — UI toolkit decision made here.
* Entity inspector, content browser, log console.
* Frame profiler with per-subsystem timing; memory reporting per allocator.
* Introspection APIs designed with the future public ABI in mind (ADR-0004, ADR-0011).

**Exit criteria:** a performance problem can be diagnosed from inside the running game.

---

## Phase 3 — Modding and shipping

### M7 — Moddable: "others can extend it"

* The public C ABI: `FoundryApi_v1` table, opaque handles, versioning (ADR-0004).
* Mod manifests: ID, version, dependencies, compatibility range, **license field** (ADR-0016).
* Mod discovery, dependency resolution, deterministic load order.
* Native mod loading through dynamic libraries (Tier 3).
* Untrusted-input validation across the whole boundary.
* Mod-facing API documentation in `docs/modding/`.

**Exit criteria:** a mod built outside the engine tree adds a new component type, new content,
and new behaviour, without engine source changes.

### M8 — Scriptable: "modders can extend it"

* Scripting language decision (`CLAUDE.md` §9).
* Scripting host over the same public ABI; no separate surface.
* Sandboxing, resource limits, script hot reload.
* Error reporting good enough for a non-programmer mod author.

**Exit criteria:** meaningful gameplay written in script, hot-reloaded, unable to crash the host.

### M9 — Shippable: "it distributes"

* Asset and content bundling; release build configuration.
* Game configuration and user settings.
* Generated `THIRD_PARTY_NOTICES.txt` from `THIRD_PARTY_LICENSES/` (ADR-0016).
* Distributable macOS build. Crash handling and diagnostics.

**Exit criteria:** a zip a stranger can download and run.

---

## Unscheduled: backend #2

**Deliberately not placed on the timeline.** Started when there is a reason — a decision to
ship Windows or Linux, or a decision to validate the RHI against a second API — not when the
roadmap reaches it. Linux implies Vulkan; Windows could be either (ADR-0003).

Expect this milestone to surface RHI design errors. That is its second purpose, and budgeting
for it is more honest than being surprised by it. It also brings: real hardware or VM testing
for that platform, the Vulkan SDK and RenderDoc if applicable, and the shader cross-compiler
decision (ADR-0015).

---

## Phase 4 — 3D

Deliberately unplanned in detail. Reuses `core`, `platform`, `rhi`, `data`, `asset` and `scene`
unchanged; that reuse is the entire point of the earlier architecture.

Expected shape, in rough order:

* `rhi` 3D capability: depth buffers, MSAA, cubemaps, mipmapping, compute.
* Transform hierarchy and scene graph on top of the existing entity model.
* Mesh and material systems; the material system must not assume all shaders are known at build
  time (ADR-0003, ADR-0015).
* 3D camera, frustum culling, sorting.
* Model import (glTF) through the asset pipeline.
* Lighting and shadows.
* 3D physics — likely the largest single item in this phase, and constrained by I9.
* Skeletal animation.

**This phase is not designed yet, and must not be designed until Phase 2 is complete.**
Recording it here is a commitment to compatibility, not a plan.
