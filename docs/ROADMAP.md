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

### M0 — Skeleton: "it runs"

The smallest useful version of Foundry. Deliberately excludes the GPU.

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

### M1 — First pixels: "it draws"

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

### M2 — Sprites: "it draws a lot"

* Sprite batching; texture atlas support; texture loading from disk (PNG decode).
* 2D camera with pan/zoom; screen and world coordinate spaces.
* Bitmap text rendering.
* Frame statistics: frame time, draw calls, batch count.

**Exit criteria:** thousands of sprites at a stable frame rate, with a camera and on-screen text.

### M3 — Content: "it has data" — *first modding-relevant milestone*

* Schema system: record types with typed fields, versioned.
* Content packages, ordered load, override-by-ID (replace semantics first).
* Authoring text format — **syntax decided here** (`CLAUDE.md` §9).
* Runtime binary format and `tools/fpack` to compile one to the other.
* `asset`: registry, loading by content ID, reference counting. Shaders become assets.
* Hot reload of content and assets in development builds.
* Base game content moved into `content/core` as package zero (I3).
* `docs/modding/` begins.

**Exit criteria:** the sandbox's content lives entirely in data; a second package placed after
it overrides a value and the change is visible; editing a content file live-updates the running
program.

**At this point Tier 1 content modding effectively works**, long before the mod system exists.

### M4 — World: "it has entities"

* Entity storage: generational handles, sparse set with dense per-component arrays.
* Type-erased component storage with runtime-registered `ComponentTypeInfo` (ADR-0010).
* `comptime` wrapper for ergonomic native component registration.
* Queries and iteration that do not leak storage layout, with **stable documented iteration
  order** (I9).
* System registration and ordered update.
* Save/load of world state through the record system, by content ID.

**Exit criteria:** a scene of entities defined in content data, updated by systems, saved and
reloaded correctly across a restart. A fixed scenario run twice produces identical state.

### M5 — Playable: "it's a game"

* Tilemaps with efficient rendering and collision.
* 2D collision detection and response; spatial partitioning.
* Sprite animation: clips, state, timing.
* Audio: device output, sound loading, mixing, playback by content ID.
* A small but genuinely playable sample game in `samples/`.

**Exit criteria:** something a person can play for five minutes without knowing it is a tech
demo.

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
