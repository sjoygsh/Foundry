# CLAUDE.md — Foundry Engine

The persistent source of truth for Foundry's core ideas, architectural principles,
development rules and durable decisions.

**This file changes rarely.** It holds things that stay true across sessions. It is not an
implementation diary. Current status lives in `PROJECT_STATE.md`; individual decisions and
their reasoning live in `docs/adr/`.

---

## 0. How to use this file

**At the start of every session:**

1. Read this file.
2. Read `PROJECT_STATE.md`.
3. Read `docs/ROADMAP.md` if the current milestone is unclear.
4. Inspect the actual code before assuming anything about it.
5. Summarize your understanding of the current state back to the user.
6. Continue from the existing architecture. Do not restart or redesign completed systems.

**Before making a significant change**, check it against the Invariants (§3). If a change
would violate one, stop and discuss it with the user first.

**When an important architectural decision is made**, write an ADR (§8) and update this file
if the decision changes anything durable.

**If an old decision here conflicts with a newer deliberate one**, update this file. Never let
contradictory rules accumulate. Never silently remove or weaken a core principle — if a change
would alter Foundry's fundamental direction, raise it explicitly with the user.

---

## 1. What Foundry is

A modular game engine, 2D first, with a clean path to 3D, intended for building real games
rather than demonstrating programming. The long-term ambition is a general-purpose engine
comparable in scope to Creation Engine, Unity or Godot.

It is developed incrementally over a long period. Optimize for **actually finishing things**,
not for producing impressive-looking code quickly.

---

## 2. Core philosophy

### Foundry owns its abstractions

This is the organizing principle. Everything below follows from it.

* **SDL3 is a current implementation choice for the platform layer, not Foundry's identity.**
* **Metal, Vulkan and Direct3D are renderer backends, not Foundry's public API.**
* **Zig is the implementation language, with C ABI interoperability as a future boundary.**

Foundry defines the interfaces the rest of the engine and the game layer see. Implementation
choices sit behind those interfaces and must be replaceable without rewriting the engine or
the game layer.

### The rest

* Modular and extensible; major subsystems can be replaced or upgraded without rewriting the
  engine.
* 2D first, with 3D designed for and not designed *around*.
* Cross-platform where reasonably practical.
* Suitable for real game development.
* Every milestone leaves behind something runnable.
* Minimal dependence on proprietary technology.
* Structured like a real software project: source control, documentation, testing, profiling,
  sensible architecture — from the beginning.
* **Modding is a fundamental feature, not a later addition.** Systems that may eventually be
  exposed to mods are designed with proper boundaries and stable interfaces rather than
  requiring access to arbitrary engine internals.

### Development rules

1. Design before implementation.
2. Prefer simple, understandable architecture over premature optimization.
3. Do not add a dependency merely because it saves a small amount of code.
4. When a subsystem becomes complex, explain the architectural choices before implementing.
5. Keep the engine modular.
6. Every major milestone produces a runnable result.
7. Avoid overengineering for hypothetical future requirements.
8. Always distinguish: what we need **now**, what we should **design for** now, and what should
   be **postponed**.
9. If the user proposes something architecturally problematic, say so directly and explain why.
10. Never make a major architectural decision silently on the user's behalf.
11. Maintain the running record of decisions in `docs/adr/`.
12. **Never sacrifice future moddability merely because implementing mod support early is
    inconvenient.** If a decision could make modding substantially harder, identify that risk
    before proceeding.
13. Prefer choices that let Foundry evolve without forcing major rewrites.
14. Do not add complexity solely because a larger engine does it that way.
15. When uncertain, investigate and present the tradeoffs. Do not guess.
16. Keep documentation proportional and useful to future sessions.

---

## 3. Invariants

**These must not be violated without explicit discussion with the user.** They are cheap to
maintain now and extremely expensive to retrofit. Each exists to keep modding, serialization,
hot reload, tooling or reproducibility possible.

**I1 — Generational handles, never raw pointers, across subsystem boundaries.**
Anything addressable (entity, asset, texture, buffer, component) is referred to by a
`{ index, generation }` handle. Raw pointers may exist inside a subsystem; they never cross
one, are never stored long-term, and are never serialized.

**I2 — Stable, namespaced string IDs for all content.**
Content is identified as `namespace:name` (e.g. `foundry:item.torch`), hashed to a stable
numeric ID at build time and resolved to a runtime handle at load. Content IDs are **never**
derived from load order, array position or file offset. *Bethesda's load-order-indexed FormIDs
are the specific anti-pattern being avoided; they are the root cause of a large fraction of
real-world mod fragility.*

**I3 — The base game is content package zero.**
Engine and first-party content loads through exactly the same content-package path mods use.
There is no privileged loading path. This is the strongest available guarantee that the mod
path works: we are always using it ourselves.

**I4 — There is exactly one public API surface.**
Native mods, the future scripting host, external tools and any future language bindings all go
through one versioned C ABI (§5). Internal engine code does not use it. Nothing gets a private
back door — including the editor.

**I5 — The engine hardcodes no game content.**
No item, entity type, rule table or gameplay constant lives in engine source. Content is data.
Engine code provides mechanisms; content provides specifics.

**I6 — Registries are runtime-populated.**
Component types, asset loaders, systems and content schemas are registered at runtime through
data structures, not fixed at compile time. Native code may use `comptime` helpers to *produce*
the registration data, but the registry itself must accept entries a mod could also supply.

**I7 — Module layering is enforced by the build graph, not by convention.**
A lower layer cannot import a higher one because the build does not give it access (§4.2).
Modularity that relies on discipline alone decays.

**I8 — Anything crossing a boundary is versioned.**
The public ABI, content schemas, compiled asset formats and save files all carry explicit
version information, and loading code handles an unrecognised version gracefully rather than
by undefined behaviour.

**I9 — Simulation is deterministic-friendly.**
The same binary, same inputs and same seed produce the same result. Fixed timestep; no global
RNG; stable and documented iteration order wherever order affects outcomes; no wall-clock reads
inside simulation; no behaviour dependent on pointer values; deterministic content merge; no
fast-math. Bit-exactness across machines is explicitly *not* guaranteed (ADR-0013).

---

## 4. Architecture

### 4.1 Decisions

| Area | Decision | ADR |
| --- | --- | --- |
| Language | Zig, pinned stable release, never master; C ABI only at the public boundary | [0001](docs/adr/0001-language-zig.md) |
| Platforms | macOS/Apple Silicon primary; Windows x64 and Linux x64 build-checked | [0008](docs/adr/0008-target-platforms.md) |
| Platform layer | SDL3 behind Foundry's own platform interface, via a Zig package | [0002](docs/adr/0002-platform-layer-sdl3.md) |
| Rendering | Foundry's own RHI with native backends; Metal first, null backend validates | [0003](docs/adr/0003-renderer-own-rhi-metal-first.md) |
| Metal bridge | Thin Objective-C shim exposing a C API | [0012](docs/adr/0012-metal-objc-shim.md) |
| Shaders | MSL now; shaders are assets with per-backend variants | [0015](docs/adr/0015-shader-strategy.md) |
| Shader ownership | Engine-owned shaders embedded; content-owned shaders are assets | [0019](docs/adr/0019-builtin-versus-content-shaders.md) |
| Public API | One versioned C ABI table shared by mods, scripts and tools | [0004](docs/adr/0004-public-c-abi.md) |
| ABI placement | `abi` is a peer of `debug` at L5; the host supplies its subsystems | [0026](docs/adr/0026-abi-module-and-host.md) |
| Scripting runtime | Restricted Lua 5.5.1, one VM per package, quotas inside a protected C boundary | [0028](docs/adr/0028-scripting-lua.md) |
| Script host | Header-only public ABI consumer; its Lua surface is validation over the shared table | [0029](docs/adr/0029-script-host-and-reload.md) |
| Distribution | Relocatable applications around ordinary packages; explicit staging and macOS release gates | [0030](docs/adr/0030-distribution-artifacts.md) |
| Configuration | Host bootstrap, ordinary content defaults and bounded user preferences remain separate | [0031](docs/adr/0031-application-configuration-and-user-data.md) |
| Identity | Generational handles internally; stable namespaced string IDs for content | [0005](docs/adr/0005-handles-and-content-ids.md) |
| Content | Engine is a library; content is data; two representations (authoring / runtime) | [0006](docs/adr/0006-content-model.md) |
| Authoring format | Foundry's own `.fdt` text format; IDs are bare tokens, directives are `@`-prefixed | [0020](docs/adr/0020-authoring-text-format.md) |
| Asset identity | Assets are content records; a path derives an ID but never defines identity | [0021](docs/adr/0021-asset-identity.md) |
| Mods | A mod is a content package; its manifest is a record inside it; discovery and load order are `mod` at L2 | [0027](docs/adr/0027-mods-are-content-packages.md) |
| Images | Foundry decodes its own PNG; no third-party image library | [0018](docs/adr/0018-image-decoding.md) |
| Modularity | Layering enforced by the Zig build graph | [0007](docs/adr/0007-module-layering.md) |
| Entities | Type-erased component storage with runtime-registered types | [0010](docs/adr/0010-entity-component-constraints.md) |
| Collision | Foundry's own 2D collision, scoped to collision rather than dynamics | [0022](docs/adr/0022-2d-collision-own.md) |
| Audio | Foundry's own mixer and WAV decoding; `platform` owns the device | [0023](docs/adr/0023-audio-own-mixer.md) |
| UI | Foundry's own immediate-mode UI; one kernel, a debug widget set now, a content-driven game one later | [0024](docs/adr/0024-ui-own-immediate-mode.md) |
| Debug overlay | A module `debug` above `app`, reaching only for calls the public ABI could expose | [0025](docs/adr/0025-debug-overlay-module.md) |
| Determinism | Deterministic-friendly, not bit-exact | [0013](docs/adr/0013-determinism.md) |
| Tooling | Tools are Foundry applications built on the public API | [0011](docs/adr/0011-tooling-architecture.md) |
| Toolchain | Zig only; no CMake, Ninja, Make or pkg-config | [0014](docs/adr/0014-toolchain.md) |
| Licensing | Apache-2.0; permissive-only third-party policy | [0016](docs/adr/0016-licensing.md) |
| Repository | Engine is a standalone public repo; games are separate consumers | [0017](docs/adr/0017-repository-scope.md) |
| Process | CLAUDE.md + PROJECT_STATE.md + numbered ADRs | [0009](docs/adr/0009-documentation-process.md) |

**Language note.** Zig is pre-1.0 and both the language and `std` break between releases. This
is an accepted, managed risk: pinned to a stable release, **never master or nightly**, upgraded
deliberately between milestones and never during one, with `std` usage concentrated behind
`core` so churn touches few files.

### 4.2 The two rendering boundaries

The intended architecture is `Game → Foundry APIs → Foundry Renderer → Graphics Backend`. That
is **two** abstraction boundaries, not one, and conflating them is the most likely way to get
this wrong:

| Boundary | Audience | Exposed to games and mods |
| --- | --- | --- |
| **Renderer API** (`render2d`, later `render3d`) — sprites, cameras, materials, text | Games, tools, eventually mods | **Yes** |
| **RHI** (`rhi`) — devices, command buffers, pipeline state, GPU resources | Engine internals only | **No** |

Games never touch the RHI. Backends never appear above it.

### 4.3 Module layering

Dependencies point downward only. Each module is a separate Zig module declared in `build.zig`;
a module can only import what the build graph grants it, so a layering violation is a build
error rather than a code review finding (I7).

```
L0  core        std only. Math, memory/allocators, containers, handles, IDs,
                hashing, logging, assertions, time primitives, RNG.

L1  platform    -> core.        Window, input, events, filesystem, dynamic library
                                loading, high-resolution clock, audio device.
                                *** SDL3 is referenced ONLY here. ***
L1  data        -> core.        Schemas, records, content packages, load order,
                                merge/override semantics, serialization.
L1  physics2d   -> core.        Shapes, tile grids, broadphase, queries, collision
                                response. No entities, no content, no I/O.
L1  ui          -> core, platform.  Immediate-mode UI kernel: widget identity, input
                                routing, layout, clipping. Emits a draw list; draws
                                nothing itself and never sees a renderer.

L2  rhi         -> core, platform.  Render hardware interface + backends.
                                *** Metal/Vulkan/D3D are referenced ONLY here. ***
                                backends/null, backends/metal (+ its ObjC shim).
L2  asset       -> core, data, platform.  Asset registry, loading, hot reload.
L2  mod         -> core, data, platform.  Mod discovery, manifests, dependency
                                resolution, deterministic load order. Produces the
                                order `data` consumes; opens no library and loads no
                                code, so a content-only host needs nothing above it.

L3  render2d    -> core, rhi, asset.      Sprite/tilemap/text batching, cameras.
L3  scene       -> core, data, asset.     Entities, components, world, systems.
L3  audio       -> core, platform, asset. Mixer, voices, playback by content ID.

L4  app         -> all of the above.      Engine loop, subsystem lifecycle, config.

L5  debug       -> core, data, ui, asset, render2d, scene, audio, app.
                The in-process debug overlay: profiler, memory, log console, entity
                inspector, content browser. Nothing in the engine depends on it; a game
                opts in by importing it. No `platform`, no `rhi`, no `physics2d` — it
                reads the engine's answers, not the devices under them.
L5  abi         -> core, data, physics2d, platform, ui, asset, render2d, scene,
                audio, app, mod.  The public C ABI, and the native mod loader.
                A peer of `debug`, not a layer over `app` (ADR-0026). No `rhi`,
                ever; `platform` for `Library` alone. Holds no engine state.
```

Games, samples and tools depend on `app`. A host that loads mods also imports `abi`; a
native mod itself depends on the C header and never on a Zig module.

**`script` sits at L6, as a consumer of the public API rather than a layer of the engine.**
It depends on `core`, the pinned Lua library, and declarations from `foundry.h` — never an
engine implementation module. It reaches the engine only through the `FoundryApi_v2` table
its application hands it, exactly as a native mod does, so the Lua surface can never be
wider than what the public ABI already publishes. Nothing below it depends on it, and a
content-only host links no Lua at all. See ADR-0029 and `docs/design/scripting.md` for
ownership and the step order; `PROJECT_STATE.md` for how far that order has been walked.

**The overlay is not privileged.** `debug` is engine code and gets no private path (I4,
ADR-0025): every call it makes must be one the public ABI could expose, which means handle or
content-ID identity, a documented iteration order, read-only answers, frame-lifetime borrows,
and validation rather than assertion on anything a mod could have supplied. The introspection
itself lives in the subsystem being introspected, never in the overlay. This is I3's argument
applied to tooling — the overlay is package zero for the introspection API, and the editor
(§9, M6+) is a re-host of it rather than a rewrite.

**The ABI is not a layer over the engine; it is a peer of the overlay** (ADR-0026). Two
facts force it. `app` cannot see `scene`, `audio` or `physics2d` — each absence deliberate —
and it *owns* no world, renderer, mixer or collision world, because the game does. So the
module that publishes those capabilities has to sit beside `debug` and be **handed** its
subsystems by the host, exactly as `debug.Sources` is. A capability whose subsystem is absent
answers `Unavailable`; the table's shape never varies within a version. And `abi` may only
translate — validate, call one subsystem, return a code — because a module that can see the
whole engine will otherwise accumulate the whole engine.

**The UI draw seam.** `ui` sits at L1 and below the renderer on purpose (ADR-0024). It reads
input, decides what is hot, lays out, clips — and then *describes* what should appear as a list
of rectangles, text runs and clip rectangles. It never calls a renderer, so it unit-tests with
no device, no window and no frame. Something above walks that list into `render2d` calls; the
walker is the only piece that knows both vocabularies, and it is the price of the seam.

**The native surface seam.** `platform` exposes an opaque `NativeSurfaceHandle` — a tagged
pointer whose tag names the surface kind — and `rhi` interprets it per backend. On macOS that
carries the `CAMetalLayer` obtained from SDL3. `rhi` already depends on `platform`, so this
needs no sideways dependency, and no SDL or Metal type appears in any interface.

**Rule:** if a new subsystem does not fit this layering, that is a signal to re-examine either
the subsystem or the layering — explicitly, with the user — not to add a sideways dependency.

### 4.4 Toolchain

**Installed deliberately:** Zig, a specific stable release from the official tarball at a
versioned path, with version and SHA256 recorded in-repo. Never via a package manager, so an
unrelated upgrade cannot silently move the compiler.

**Already present and sufficient:** Xcode 26 (SDK 26.5) for the Metal framework, Objective-C
compilation and GPU frame capture; the on-demand Metal toolchain for shader compilation —
always invoked as `xcrun metal` / `xcrun metallib`, **never a hardcoded path**, since it lives
on a versioned mount; git; Python for developer scripts only, never load-bearing in the build.

**Deliberately absent:** CMake, Ninja, Make, pkg-config. Zig's build system compiles C, C++ and
Objective-C, cross-compiles, fetches dependencies with pinned hashes, runs tests and hosts
custom build steps. Homebrew exists on the machine as an escape hatch; nothing in the build may
assume it.

**Adding a build tool requires an ADR.** Tools accumulate silently otherwise.

### 4.5 Repository structure

```
Foundry/
  CLAUDE.md              This file. Durable principles and architecture.
  AGENTS.md              How to build, verify and work here. Binds to this file,
                         never restates it. For any agent, not only Claude Code.
  PROJECT_STATE.md       Current state. Changes every session.
  README.md
  LICENSE  NOTICE        Apache-2.0.
  build.zig              Module graph, targets, test and tool steps.
  build.zig.zon          Dependencies (pinned hashes) and minimum Zig version.
  .zigversion            Exact pinned toolchain version.

  docs/
    ROADMAP.md           Staged milestones.
    adr/                 Numbered architecture decision records.
    design/              Per-subsystem design docs, written BEFORE implementation.
    modding/             Mod-author-facing documentation. Grows from M3 onward.

  engine/
    src/
      core/  platform/  data/  physics2d/  ui/  rhi/  asset/  mod/  render2d/
      scene/  audio/  app/  debug/  abi/  script/
      rhi/backends/      null/  metal/ (Zig backend + Objective-C shim)
    tests/               Integration tests. Unit tests are colocated with source.

  tools/
    fpack/               Content compiler: authoring text -> runtime binary.
    distribution/        Release staging: the build-time description a consuming game
                         imports, and the packager it drives. Not installed.
    (editor/)            Later. A Foundry application, not a special case.

  samples/
    sandbox/             Capabilities, demonstrated. The runnable app every milestone must
      content/           keep working. Its own content package, as a game has one.
    room/                A small game, built out of them. Playability is a capability too,
      content/           and it needs a sample whose HUD is not full of frame times.

  content/
    core/                Base content package. Package zero (I3). Engine content
                         only; a sample's or a game's belongs to it, not here.

  THIRD_PARTY_LICENSES/  One file per dependency. Entry lands in the same commit
                         as the dependency. See its README for the policy.
  scripts/
```

**What does not live here.** Foundry is the engine, and its repository contains the engine,
its tools, its samples and its documentation — nothing else. **Games live in their own
repositories** and consume Foundry as a dependency (ADR-0017). A game developed inside the
engine tree would leak its assumptions into the engine silently, which is precisely what I4
and I5 exist to prevent.

`samples/` holds the smallest thing that exercises a capability, and there may be more than
one of them: a sample that demonstrates and a sample that plays are different smallest
things, and asking one artifact to be both produces neither. A sample is still not a game.
When a sample starts wanting features rather than demonstrating them, it has outgrown this
repository. A sample does, however, ship its **own** content package, because that is the
shape a real consumer has and the sample is the reference for one.

---

## 5. Modding architecture

Three tiers, listed in order of how many people will use them — the inverse of how much power
they grant.

**Tier 1 — Content mods (most users).** Data only: items, entities, maps, rules, text, assets.
No code, no compiler, no sandbox concerns. This tier must work *early*, because it is where
most mod value actually lives and because its requirements (I2, I3, I5, I8) constrain
serialization and the content model in ways that are impossible to retrofit.

**Tier 2 — Script mods (most modders).** Sandboxed, hot-reloadable code against the public API.
Script faults must not crash the host. **Restricted Lua 5.5.1** is selected by ADR-0028 and
its boundary by ADR-0029. Its operational fault-containment contract, limits and explicit
exclusions are in `docs/design/scripting.md`; how far M8's eight steps have been walked is in
`PROJECT_STATE.md`.

**Tier 3 — Native mods (power users).** Dynamic libraries loaded through the C ABI. Full speed,
full power, no sandbox, version-fragile by nature. Explicitly a consenting-adults tier.

### The public ABI

One narrow, versioned C ABI (I4):

* A struct of function pointers — an **API table** — handed to the consumer at load
  (`FoundryApi_v1`, then `_v2`, added alongside rather than replacing).
* **Opaque handles only.** No engine struct layouts are exposed; changing an internal struct
  must never break a compiled mod.
* Explicit ownership and allocation rules on every call that transfers memory.
* Result codes, not Zig error unions.
* All input from the other side is **untrusted**: validated, never asserted.
* **The host supplies the subsystems** (ADR-0026). `abi` creates no world, renderer, mixer or
  collision world; a game hands it the ones it has, and a capability whose subsystem is absent
  answers `Unavailable` rather than being a null pointer.

**Consequence to remember:** if a capability is not reachable through the public API, mods
cannot use it. Therefore **adding a subsystem includes deciding what, if anything, it exposes**
— even if the answer is "nothing yet."

### What a mod is made of

**A mod is a content package** (ADR-0027), and its manifest — id, version, dependencies,
engine range, license (ADR-0016) — is a record inside it, of an engine-declared schema.
Every tier is that package with something optional attached: Tier 1 is the package alone, Tier 3
adds a native library the manifest names, Tier 2 adds scripts. So there is one identity (the
package's content ID, I2), one version, one file, and no second format that can disagree with
the package it describes.

Discovery, dependency resolution and load order are `mod` at L2, **below** the engine loop,
because a Tier 1 mod list has to be computable by a game that loads no code at all. `data` still
consumes an order and does not compute one. Order is a topological sort with a documented
tie-break — by content ID, ascending — so the same packages and the same enabled set produce the
same order on every machine (I9).

### Keeping mod compatibility ahead of the mod system

The *disciplines* that make modding possible were in force from day one, before any of the above
was built, and they are exactly Invariants I1–I9. That is why neither M7 nor M8 required a
retrofit below it. A mod manager UI is still unbuilt.

The Metal shim (ADR-0012) is a small, low-risk C ABI boundary inside the engine that exercised
the same discipline early.

Known future problem, recorded so it is not a surprise: **mod-authored shaders** will require
runtime shader compilation or a shipped compiler. Do not design the material system assuming
all shaders are known at build time. Metal's runtime MSL compilation makes this tractable on
the first backend (ADR-0015).

---

## 6. Content and data model

**Content is data, separable from engine implementation.** The engine defines mechanisms;
content defines specifics (I5).

**Schemas are canonical, not syntax.** A schema is a named record type with typed fields, owned
by whoever defines it — engine, game or mod. Content is instances of schemas.

**Two representations:**

* **Authoring format** — text. Human-editable, diffable, commentable, hand-writable and
  machine-generatable. What mod authors touch.
* **Runtime format** — compiled binary. Fast to load, ideally mappable, versioned. What shipped
  builds read. Shipped builds never parse the authoring format; development builds may, for hot
  reload.

**JSON is disqualified** as either format: no comments, ambiguous numeric handling, needless
parse cost at load. Tool interchange only. The authoring format is Foundry's own `.fdt`
([ADR-0020](docs/adr/0020-authoring-text-format.md)), drawn around the record shape and
specified in [`docs/design/content-schemas.md`](docs/design/content-schemas.md).

**Binary payloads are never embedded in content text.** Textures, meshes, audio and similar are
assets, referenced by ID and stored in their own formats. Shaders are assets too (ADR-0015).

**An asset is content, and its identity is its content ID** — never its path
([ADR-0021](docs/adr/0021-asset-identity.md)). A path may *derive* an ID at compile time, as a
default for a field an author may write instead; it is never what an ID *means*. No runtime
code resolves an asset by path, so directory layout stays private to each package and a mod
overriding an asset never has to mirror someone else's folders.

---

## 7. Conventions

**Zig style.** Follow `std` conventions: `TitleCase` types, `camelCase` functions, `snake_case`
variables and fields, `SCREAMING_SNAKE_CASE` constants. Files are `snake_case.zig`, except a
file that *is* a single struct, which is `TitleCase.zig`.

**Allocators are explicit.** Every allocating API takes an `Allocator`. There is no global
allocator. Per-frame garbage uses a frame arena that is reset, not freed piecewise. Subsystems
own pools for their own object types.

**RNG is explicit.** Same rule as allocators, for the same reason and also for I9: generators
are passed in, never global, never seeded from the clock at an arbitrary point.

**Errors.** Zig error unions internally, with error sets kept meaningful and narrow. Result
codes at the C ABI. Never swallow an error silently; a deliberately ignored error is commented.

**Logging and assertions** go through `core`, scoped by subsystem, never `std.debug.print` in
committed code. Assertions distinguish "programmer error" from "invalid external input" — mod
and content input is untrusted and is validated, not asserted.

**Testing.** Unit tests colocated in source; integration tests in `engine/tests/`. `zig build
test` must pass before a milestone is done. The null RHI backend exists partly so rendering-
adjacent code is testable headlessly, and it enforces the strict rules Metal would forgive.

**Naming things mods will see** — schemas, component types, API functions, content IDs — is a
compatibility decision, not a style decision. Renaming them later breaks mods and saves. Treat
these names with more care than internal ones.

**Dependencies.** A dependency and its `THIRD_PARTY_LICENSES/` entry land in the **same commit**.
Check the license before evaluating a library technically. Permissive licenses only; no GPL,
AGPL or LGPL (ADR-0016). **That entry's shape is load-bearing**: the release packager parses it
to generate the attribution a player receives, and an entry that drifts from the template in
`THIRD_PARTY_LICENSES/README.md` fails the build rather than being skipped.

**Commits.** Small, focused, present tense. A milestone ends with a tagged commit and an updated
`PROJECT_STATE.md`.

---

## 8. Architecture decision records

Decisions live in `docs/adr/NNNN-short-title.md`, using the template in `docs/adr/README.md`.

* An ADR is **append-only once code depends on it.** Before implementation exists against it, it
  may be revised in place with a dated revision note. After that, changing it means a new ADR
  that supersedes the old one.
* Every ADR records what would cause us to **revisit** it. A decision no one can falsify is not
  a decision, it is a habit.
* The index of accepted ADRs is the table in §4.1.

Write an ADR when a choice constrains future work, is expensive to reverse, or will look
arbitrary to a future session. Do not write one for routine implementation choices.

---

## 9. Deliberately postponed decisions

Recorded so they are not made accidentally. Each notes when it comes due.

| Decision | Due | Notes |
| --- | --- | --- |
| Separate editor application | M6+ | In-process debug overlay first. |
| Second graphics backend (Vulkan / D3D12) | Unscheduled | Triggered by a reason — shipping Windows or Linux, or validating the RHI. Linux implies Vulkan; Windows could be either. |
| Shader cross-compiler vs. hand-written variants | Backend #2, or when the shader set grows large | ADR-0015. Whichever comes first. |
| Job system / threading model | Post-M5 | Do not design subsystems that assume single-threaded forever. |
| Bit-exact determinism for a subset | If lockstep networking is ever wanted | ADR-0013 keeps this open without paying for it now. |
| Networking | Indefinite | I1, I2, I8 and I9 keep it possible. Nothing else is owed to it now. |

**Out of scope indefinitely, not constraining the initial architecture:** consoles, mobile, web,
VR, x86-64 macOS.

---

## 10. Non-negotiables for future implementations

A future session must not, without explicit discussion:

* Violate any Invariant in §3.
* Give the editor, tools or first-party content a private path the mod API does not have.
* Hardcode game content into engine source.
* Move a game into this repository, or let `samples/` grow into one (ADR-0017).
* Let SDL3 references escape `platform`, or graphics API references escape `rhi`.
* Expose the RHI to games or mods. The Renderer API is the game-facing boundary, not the RHI.
* Track Zig master or nightly, or upgrade the pinned toolchain during a milestone.
* Add a build tool without an ADR.
* Add a dependency without its `THIRD_PARTY_LICENSES/` entry in the same commit, or add one
  under GPL, AGPL or LGPL.
* Introduce a dependency that cannot be replaced, or a proprietary one.
* Skip a milestone's runnable result in order to move faster.
* Expand `CLAUDE.md` into an implementation diary.
