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

**When an important architectural decision is made**, write an ADR (§8) and update this
file if the decision changes anything durable.

**If an old decision here conflicts with a newer deliberate one**, update this file. Never
let contradictory rules accumulate. Never silently remove or weaken a core principle — if a
change would alter Foundry's fundamental direction, raise it explicitly with the user.

---

## 1. What Foundry is

A modular game engine, 2D first, with a clean path to 3D, intended for building real games
rather than demonstrating programming. The long-term ambition is a general-purpose engine
comparable in scope to Creation Engine, Unity or Godot.

It is developed incrementally over a long period. Optimize for **actually finishing
things**, not for producing impressive-looking code quickly.

---

## 2. Core philosophy

* Modular and extensible; major subsystems can be replaced or upgraded without rewriting
  the engine.
* 2D first, with 3D designed for and not designed *around*.
* Cross-platform where reasonably practical.
* Suitable for real game development.
* Every milestone leaves behind something runnable.
* Fully under our control, with minimal dependence on proprietary technology.
* Structured like a real software project: source control, documentation, testing,
  profiling, sensible architecture — from the beginning.
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
8. Always distinguish: what we need **now**, what we should **design for** now, and what
   should be **postponed**.
9. If the user proposes something architecturally problematic, say so directly and explain
   why.
10. Never make a major architectural decision silently on the user's behalf.
11. Maintain the running record of decisions in `docs/adr/`.
12. **Never sacrifice future moddability merely because implementing mod support early is
    inconvenient.** If a decision could make modding substantially harder, identify that
    risk before proceeding.
13. Prefer choices that let Foundry evolve without forcing major rewrites.
14. Do not add complexity solely because a larger engine does it that way.
15. When uncertain, investigate and present the tradeoffs. Do not guess.
16. Keep documentation proportional and useful to future sessions.

---

## 3. Invariants

**These must not be violated without explicit discussion with the user.** They are cheap to
maintain now and extremely expensive to retrofit later. Each exists to keep modding,
serialization, hot reload and tooling possible.

**I1 — Generational handles, never raw pointers, across subsystem boundaries.**
Anything addressable (entity, asset, texture, buffer, component) is referred to by a
`{ index, generation }` handle. Raw pointers may exist inside a subsystem; they never cross
one, are never stored long-term, and are never serialized.

**I2 — Stable, namespaced string IDs for all content.**
Content is identified as `namespace:name` (e.g. `foundry:item.torch`), hashed to a stable
numeric ID at build time and resolved to a runtime handle at load. Content IDs are **never**
derived from load order, array position or file offset. *Bethesda's load-order-indexed
FormIDs are the specific anti-pattern being avoided here; they are the root cause of a large
fraction of real-world mod fragility.*

**I3 — The base game is content package zero.**
Engine and first-party content loads through exactly the same content-package path that mods
use. There is no privileged loading path. This is the strongest available guarantee that the
mod path works: we are always using it ourselves.

**I4 — There is exactly one public API surface.**
Native mods, the future scripting host, external tools and any future language bindings all
go through one versioned C ABI (§5). Internal engine code does not use it. Nothing gets a
private back door — including the editor.

**I5 — The engine hardcodes no game content.**
No item, entity type, rule table or gameplay constant lives in engine source. Content is
data. Engine code provides mechanisms; content provides specifics.

**I6 — Registries are runtime-populated.**
Component types, asset loaders, systems and content schemas are registered at runtime
through data structures, not fixed at compile time. Native code may use `comptime` helpers
to *produce* the registration data, but the registry itself must accept entries a mod could
also supply.

**I7 — Module layering is enforced by the build graph, not by convention.**
A lower layer cannot import a higher one because the build does not give it access (§4.2).
Modularity that relies on discipline alone decays.

**I8 — Anything crossing a boundary is versioned.**
The public ABI, content schemas, compiled asset formats and save files all carry explicit
version information, and the loading code handles a version it does not recognise
gracefully rather than by undefined behaviour.

---

## 4. Architecture

### 4.1 Technology decisions

| Area | Decision | ADR |
| --- | --- | --- |
| Language | Zig; idiomatic internally, C ABI only at the public boundary | [0001](docs/adr/0001-language-zig.md) |
| Platforms | Windows + Linux ship; macOS dev host and eventual ship target | [0008](docs/adr/0008-target-platforms.md) |
| Platform layer | SDL3 behind Foundry's own platform interface | [0002](docs/adr/0002-platform-layer-sdl3.md) |
| Rendering | Foundry's own RHI with native backends; Vulkan first, null backend for headless | [0003](docs/adr/0003-renderer-own-rhi-vulkan-first.md) |
| Public API | One versioned C ABI table shared by mods, scripts and tools | [0004](docs/adr/0004-public-c-abi.md) |
| Identity | Generational handles internally; stable namespaced string IDs for content | [0005](docs/adr/0005-handles-and-content-ids.md) |
| Content | Engine is a library; content is data; two representations (authoring / runtime) | [0006](docs/adr/0006-content-model.md) |
| Modularity | Layering enforced by the Zig build graph | [0007](docs/adr/0007-module-layering.md) |
| Process | CLAUDE.md + PROJECT_STATE.md + numbered ADRs | [0009](docs/adr/0009-documentation-process.md) |
| Entities | Type-erased component storage with runtime-registered types | [0010](docs/adr/0010-entity-component-constraints.md) |
| Tooling | Tools are Foundry applications built on the public API | [0011](docs/adr/0011-tooling-architecture.md) |

**Language note.** Zig is pre-1.0 and both the language and `std` break between releases.
This is an accepted, managed risk: the compiler version is pinned in-repo, upgrades are an
explicit chore performed *between* milestones and never during one, and `std` usage is
concentrated behind `core` so churn touches few files.

### 4.2 Module layering

Dependencies point downward only. Each module is a separate Zig module declared in
`build.zig`; a module can only import what the build graph grants it, so a layering
violation is a build error rather than a code review finding (I7).

```
L0  core        std only. Math, memory/allocators, containers, handles, IDs,
                hashing, logging, assertions, time primitives.

L1  platform    -> core.        Window, input, events, filesystem, dynamic library
                                loading, high-resolution clock, audio device.
                                *** SDL3 is referenced ONLY here. ***
L1  data        -> core.        Schemas, records, content packages, load order,
                                merge/override semantics, serialization.

L2  rhi         -> core, platform.  Render hardware interface + backends.
                                *** Vulkan/Metal/D3D are referenced ONLY here. ***
L2  asset       -> core, data, platform.  Asset registry, loading, hot reload.

L3  render2d    -> core, rhi, asset.      Sprite/tilemap/text batching, cameras.
L3  scene       -> core, data, asset.     Entities, components, world, systems.

L4  app         -> all of the above.      Engine loop, subsystem lifecycle, config.

L5  abi         -> app.                   The public C ABI. (Added at M7.)
```

Games, samples and tools depend on `app` (and on `abi` when they are acting as mods).

**Rule:** if a new subsystem does not fit this layering, that is a signal to re-examine
either the subsystem or the layering — explicitly, with the user — not to add a sideways
dependency.

### 4.3 Repository structure

```
Foundry/
  CLAUDE.md              This file. Durable principles and architecture.
  PROJECT_STATE.md       Current state. Changes every session.
  README.md
  build.zig              Module graph, targets, test and tool steps.
  build.zig.zon          Dependencies and pinned minimum Zig version.
  .zigversion            Exact pinned toolchain version.

  docs/
    ROADMAP.md           Staged milestones.
    adr/                 Numbered architecture decision records.
    design/              Longer-form per-subsystem design docs, written before
                         implementing anything non-trivial.
    modding/             Mod-author-facing documentation. Grows from M3 onward.

  engine/
    src/
      core/  platform/  data/  rhi/  asset/  render2d/  scene/  app/  abi/
    tests/               Integration tests. Unit tests are colocated with source.

  tools/
    fpack/               Content compiler: authoring text -> runtime binary.
    (editor/)            Later. A Foundry application, not a special case.

  samples/
    sandbox/             The runnable app every milestone must keep working.

  content/
    core/                Base content package. Package zero (I3).

  third_party/           Vendored dependencies, each with provenance and license noted.
  scripts/
```

---

## 5. Modding architecture

Foundry targets three tiers of modding. They are listed in order of how many people will use
them, which is the inverse of how much power they grant.

**Tier 1 — Content mods (most users).** Data only: items, entities, maps, rules, text,
assets. No code, no compiler, no sandbox concerns. This tier must work *early* because it is
where most mod value actually lives, and because its requirements (I2, I3, I5, I8) constrain
serialization and the content model in ways that are impossible to retrofit.

**Tier 2 — Script mods (most modders).** Sandboxed, hot-reloadable code against the public
API. Cannot crash the host. The scripting language is a **postponed** decision (§9).

**Tier 3 — Native mods (power users).** Dynamic libraries loaded through the C ABI. Full
speed, full power, no sandbox, and version-fragile by nature. Explicitly a
consenting-adults tier.

### The public ABI

One narrow, versioned C ABI (I4):

* A struct of function pointers — an **API table** — handed to the mod at load
  (`FoundryApi_v1`, then `_v2`, added alongside rather than replacing).
* **Opaque handles only.** No engine struct layouts are exposed; changing an internal struct
  must never break a compiled mod.
* Explicit ownership and allocation rules on every call that transfers memory.
* Result codes, not Zig error unions, across the boundary.

**Consequence to remember:** if a capability is not reachable through the public API, mods
cannot use it. Therefore **adding a subsystem includes deciding what, if anything, it
exposes** — even if the answer is "nothing yet."

### Keeping mod compatibility without building the mod system

The mod system is postponed to M7. The *disciplines* that make it possible are in force from
day one, and they are exactly Invariants I1–I8. Nothing more is required now. Specifically,
we do **not** yet build: mod manifests, dependency resolution, sandboxing, a mod manager UI,
or the ABI itself.

Known future problem, recorded now so it is not a surprise: **mod-authored shaders** will
require either runtime shader compilation or shipping a compiler. Do not design the material
system in a way that assumes all shaders are known at build time.

---

## 6. Content and data model

**Content is data, separable from engine implementation.** The engine defines mechanisms;
content defines specifics (I5).

**Schemas are the canonical thing, not syntax.** A schema is a named record type with typed
fields, owned by whoever defines it — engine, game or mod. Content is instances of schemas.

**Two representations:**

* **Authoring format** — text. Human-editable, diffable, commentable, hand-writable and
  machine-generatable. What mod authors touch.
* **Runtime format** — compiled binary. Fast to load, ideally mappable, versioned. What
  shipped builds read. Shipped builds never parse the authoring format; development builds
  may, for hot reload.

**JSON is disqualified** as either format: no comments, ambiguous numeric handling, and
needless parse cost at load. It may be used for tool interchange only. The specific
authoring syntax is a postponed decision (§9); the requirements it must meet are recorded in
[ADR-0006](docs/adr/0006-content-model.md).

**Binary payloads are never embedded in content text.** Textures, meshes, audio and similar
are assets, referenced by ID and stored in their own formats.

---

## 7. Conventions

**Zig style.** Follow `std` conventions: `TitleCase` types, `camelCase` functions,
`snake_case` variables and fields, `SCREAMING_SNAKE_CASE` constants. Files are
`snake_case.zig`, except a file that *is* a single struct, which is `TitleCase.zig`.

**Allocators are explicit.** Every allocating API takes an `Allocator`. There is no global
allocator. Per-frame garbage uses a frame arena that is reset, not freed piecewise.
Subsystems own pools for their own object types.

**Errors.** Zig error unions internally, with error sets kept meaningful and narrow. Result
codes at the C ABI. Never swallow an error silently; a deliberately ignored error is
commented.

**Logging and assertions** go through `core`, scoped by subsystem, never through `std.debug.print`
in committed code. Assertions distinguish "programmer error" from "invalid external input" —
mod and content input is untrusted and is validated, not asserted.

**Testing.** Unit tests colocated in source files; integration tests in `engine/tests/`.
`zig build test` must pass before a milestone is considered done. The null RHI backend exists
partly so that rendering-adjacent code is testable headlessly and in CI.

**Naming things that mods will see** (schemas, component types, API functions, content IDs)
is a compatibility decision, not a style decision. Renaming them later breaks mods. Treat
these names with more care than internal ones.

**Commits.** Small, focused, present tense. A milestone ends with a tagged commit and an
updated `PROJECT_STATE.md`.

---

## 8. Architecture decision records

Decisions live in `docs/adr/NNNN-short-title.md`, numbered sequentially, using the template
in `docs/adr/README.md`.

* An ADR is **append-only once accepted.** To change a decision, write a new ADR that
  supersedes it and mark the old one `Superseded by NNNN`. Do not edit accepted decisions.
* Every ADR records what would cause us to **revisit** it. A decision no one can falsify is
  not a decision, it is a habit.
* The index of accepted ADRs is the table in §4.1.

Write an ADR when a choice constrains future work, is expensive to reverse, or will look
arbitrary to a future session. Do not write one for routine implementation choices.

---

## 9. Deliberately postponed decisions

Recorded so they are not made accidentally. Each notes when it comes due.

| Decision | Due | Notes |
| --- | --- | --- |
| Authoring text syntax | M3 | Requirements in ADR-0006. Custom vs. adopting an existing format. |
| Asset ID scheme (path-derived vs. GUID) | M3 | Interacts with I2 and with mod-authored asset overrides. |
| Scripting language (Lua vs. WASM vs. other) | M8 | WASM: sandboxed, multi-language. Lua: small, easy, hot-reload. |
| Physics: own vs. ported | M5 | 2D collision first; 3D physics far later. |
| Audio: own mixer vs. library | M5 | SDL3 gives the device either way. |
| Debug/game UI: own IMGUI vs. cimgui | M6 | We need a UI system regardless; that argues for our own. |
| Separate editor application | M6+ | In-process debug overlay first. |
| Native Metal backend | macOS ship | MoltenVK covers macOS development until then. |
| D3D12 backend | Indefinite | Vulkan covers Windows. Only if a concrete reason appears. |
| Job system / threading model | Post-M5 | Do not design subsystems that assume single-threaded forever. |
| Networking | Indefinite | I1/I2/I8 keep it possible. Nothing else is owed to it now. |
| Project license | Soon | Interacts with the mod ABI and with third-party licenses. |

**Out of scope indefinitely:** consoles, mobile, VR, web.

---

## 10. Non-negotiables for future implementations

A future session must not, without explicit discussion:

* Violate any Invariant in §3.
* Give the editor, tools or first-party content a private path the mod API does not have.
* Hardcode game content into engine source.
* Introduce a dependency that cannot be replaced, or a proprietary one.
* Let SDL3 references escape `platform`, or graphics API references escape `rhi`.
* Skip a milestone's runnable result in order to move faster.
* Expand `CLAUDE.md` into an implementation diary.
