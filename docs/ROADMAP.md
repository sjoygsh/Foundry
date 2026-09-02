# Foundry Roadmap

Staged milestones from a minimal engine toward 2D, then 3D.

**Milestones are units of work, not units of time.** No dates. Sessions are bounded by
available context, so each milestone is sized to be resumable from `PROJECT_STATE.md` alone,
and each one leaves behind something that runs.

**Rules for every milestone:**

* It produces a runnable result — `samples/sandbox` must still start and do something.
* `zig build test` passes.
* All three platforms still build (Windows, Linux, macOS).
* `PROJECT_STATE.md` is updated. A milestone is not done until it is.
* Design docs for anything non-trivial go in `docs/design/` **before** implementation.

---

## Phase 1 — Foundation

### M0 — Skeleton: "it runs"

The smallest useful version of Foundry. Deliberately excludes the GPU.

* Zig toolchain installed and pinned; `build.zig` with the module graph from ADR-0007.
* `core`: allocators (general, arena, pool), generational handle table, string IDs and
  hashing, logging with subsystem scopes, assertions, math basics, time.
* `platform`: SDL3 vendored and building; window creation, event pump, keyboard/mouse input,
  high-resolution clock, filesystem basics.
* `app`: fixed-timestep loop with interpolated render step, subsystem lifecycle
  (init/update/shutdown ordering), clean exit.
* `rhi`: interface definition plus the **null backend** only.
* `samples/sandbox`: opens a window, logs input, runs the loop, exits cleanly.
* Test harness running; CI-shaped script that builds all three targets.

**Exit criteria:** a window opens and responds to input on macOS; Windows and Linux builds
are produced and at least one has been *run*, not merely compiled.

**Not in this milestone:** anything drawn.

### M1 — First pixels: "it draws"

The largest single milestone in the project. Expect it to span several sessions.

* Vulkan loader loaded dynamically at runtime; instance, physical device selection, logical
  device, queues.
* Swapchain with correct resize and minimize handling; frames in flight; synchronization.
* Render pass, graphics pipeline, shader modules from committed SPIR-V.
* Vertex/index/uniform buffers; staging uploads; memory allocation strategy.
* Shader build step: GLSL to SPIR-V, output committed.
* Validation layers wired up in debug builds.

**Exit criteria:** a textured quad on screen, surviving window resize, with validation layers
clean.

**Not in this milestone:** batching, materials, anything 3D-specific.

---

## Phase 2 — A real 2D engine

### M2 — Sprites: "it draws a lot"

* Sprite batching; texture atlas support; texture loading from disk (PNG decode).
* 2D camera with pan/zoom; screen and world coordinate spaces.
* Bitmap text rendering.
* Basic frame statistics: frame time, draw calls, batch count.

**Exit criteria:** thousands of sprites at a stable frame rate, with a camera and on-screen
text.

### M3 — Content: "it has data" — *first modding-relevant milestone*

* Schema system: record types with typed fields, versioned.
* Content packages, ordered load, override-by-ID (replace semantics first).
* Authoring text format — **syntax decided here** (see `CLAUDE.md` §9).
* Runtime binary format and `tools/fpack` to compile one to the other.
* `asset`: registry, loading by content ID, reference counting.
* Hot reload of content and assets in development builds.
* Base game content moved into `content/core` as package zero (Invariant I3).
* `docs/modding/` begins.

**Exit criteria:** the sandbox's content lives entirely in data; a second package placed after
it overrides a value and the change is visible; editing a content file live updates the
running program.

**At this point Tier 1 content modding effectively works**, long before the mod system exists.

### M4 — World: "it has entities"

* Entity storage: generational handles, sparse set with dense per-component arrays.
* Type-erased component storage with runtime-registered `ComponentTypeInfo` (ADR-0010).
* `comptime` wrapper for ergonomic native component registration.
* Queries and iteration that do not leak storage layout.
* System registration and ordered update.
* Save/load of world state through the record system, by content ID.

**Exit criteria:** a scene of entities defined in content data, updated by systems, saved and
reloaded correctly across a restart.

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
* Mod manifests: ID, version, dependencies, compatibility range.
* Mod discovery, dependency resolution, deterministic load order.
* Native mod loading through dynamic libraries (Tier 3).
* Untrusted-input validation across the whole boundary.
* Mod-facing API documentation in `docs/modding/`.

**Exit criteria:** a mod built outside the engine tree adds a new component type, new content,
and new behaviour, without engine source changes.

### M8 — Scriptable: "modders can extend it"

* Scripting language decision (Lua vs. WASM vs. other — see `CLAUDE.md` §9).
* Scripting host over the same public ABI; no separate surface.
* Sandboxing, resource limits, script hot reload.
* Error reporting good enough for a non-programmer mod author.

**Exit criteria:** meaningful gameplay written in script, hot-reloaded, unable to crash the
host.

### M9 — Shippable: "it distributes"

* Asset and content bundling; release build configuration.
* Game configuration and user settings.
* Distributable builds for Windows, Linux and macOS.
* Crash handling and diagnostics.

**Exit criteria:** a zip a stranger can download and run.

---

## Phase 4 — 3D

Deliberately unplanned in detail. Reuses `core`, `platform`, `rhi`, `data`, `asset` and
`scene` unchanged; that reuse is the entire point of the earlier architecture.

Expected shape, in rough order:

* `rhi` 3D capability: depth buffers, MSAA, cubemaps, mipmapping, compute.
* Transform hierarchy and scene graph on top of the existing entity model.
* Mesh and material systems; the material system must not assume all shaders are known at
  build time (ADR-0003).
* 3D camera, frustum culling, sorting.
* Model import (glTF) through the asset pipeline.
* Lighting and shadows.
* 3D physics — likely the largest single item in this phase.
* Skeletal animation.

**This phase is not designed yet, and must not be designed until Phase 2 is complete.**
Recording it here is a commitment to compatibility, not a plan.
