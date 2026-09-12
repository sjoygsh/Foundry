# Foundry

A modular 2D-first game engine, written in Zig, built to grow into a general-purpose
2D/3D engine with modding as a first-class feature rather than an afterthought.

Foundry is a long-term, incremental engineering project. Every milestone is required to
leave behind something that runs.

## Status

**M0 through M8 complete.** Foundry is a playable, inspectable and fully moddable 2D engine.
Content packages are discovered and dependency-ordered; native C mods load through the
versioned public ABI and can add component types, systems and behaviour without engine source
changes; and **script mods run on the world's tick and can be edited while the game is
running**.

**M9 is under way: one of its eight steps is done.** Its
[eight-step plan](docs/design/distribution.md#14-implementation-order) covers preferences,
user package roots, release staging, attribution, diagnostics and macOS distribution. Step 1
adds bounded, versioned user preferences — the same field-block layout a record and a save
already use, written by creating a temporary file, syncing it and renaming it over the old
one, so a settings file is never half-written and one this build does not understand is kept
rather than replaced. No sample reads a preference yet and nothing is packaged.

All three modding tiers work — see [docs/modding](docs/modding/). Tier 2 is restricted
Lua 5.5.1, one VM per package, bounded in memory, instructions and engine calls, reaching the
engine only through the same public ABI table a native mod is handed. Replacing a package's
code builds a candidate VM beside the running one: the old state crosses, the entities it owns
stay, and source that does not compile leaves the last working version running with one warning
saying so. The author guide was written by building a script package outside this repository
and then rebuilt from its own listings to check that it says what the engine does.

```sh
./scripts/install-zig.sh   # the only tool you need
zig build run -Drhi=metal  # opens a window and draws; escape quits
zig build test             # 1223 headless tests
```

Implemented so far:

* **`core`** — allocators, generational handles, content IDs, math, fixed-timestep time, RNG.
* **`platform`** — window, input, filesystem, dynamic libraries, clocks. An SDL3 backend
  and a headless one, kept honest by a `comptime` conformance check.
* **`data`** — schemas and their runtime registry, the `.fdt` authoring format and its
  diagnostics, the `.fpk` runtime format, and the store that merges packages by load order.
* **`rhi`** — the render hardware interface, with a Metal backend and a **validation
  backend** that enforces the strict rules Metal forgives. Not scaffolding: it is what
  substitutes for a second graphics backend until there is one.
* **`asset`** — Foundry's own PNG decoder, and the registry that turns a content ID into a
  loaded asset through loaders registered at runtime, including bounded/revisioned script
  source. Nothing is addressable by path.
* **`render2d`** — sprite and text batching, atlases, cameras.
* **`physics2d`** — shapes, tile grids, broadphase, collision queries and response.
* **`ui`** — an immediate-mode kernel that emits a renderer-independent draw list.
* **`scene`** — runtime-registered components and systems, entities, queries and world saves.
* **`audio`** — Foundry's WAV decoder and lock-free mixer over the platform audio device.
* **`app`** — the engine loop, subsystem lifecycle, the log sink, and loading content
  packages in the order it is given them.
* **`debug`** — the in-process profiler, memory report, log console, entity inspector and
  content browser.
* **`mod`** — manifests, package discovery, dependency resolution and deterministic order.
* **`script`** — an optional restricted Lua runtime with protected execution, heap and
  instruction quotas, the bounded `foundry` binding a script calls the engine through, the
  package lifecycle that registers one system per script package and drives it on a fixed tick,
  and the candidate-VM transaction that replaces a package's code while its state, its entities
  and the world stay.
* **`abi`** — the installed C99/C++ header, frozen 135-call `FoundryApi_v1`, additive
  `FoundryApi_v2`, host boundary and native-library lifecycle.
* **`tools/fpack`** — the content compiler: a package directory in, one `.fpk` out.
* **`content/core`** — package zero. The engine's own content, loaded through exactly the
  path a mod's package uses, because that is the only durable way to know that path works.

[PROJECT_STATE.md](PROJECT_STATE.md) records exactly where things stand, and is updated
every session.

This is currently a solo project in an early stage. It is developed in the open because the
boundaries are worth making checkable. The versioned public C ABI now exists, but Foundry is
not yet a shipped release and interfaces outside that ABI remain free to evolve.

## Scope

This repository is the engine, its tools, its samples and its documentation. **Games live in
their own repositories** and consume Foundry as a dependency, with their licensing and content
decided independently ([ADR-0017](docs/adr/0017-repository-scope.md)).

`samples/` holds the smallest thing that exercises a capability. A sample is not a game.

## Documents

| File | Purpose | Changes |
| --- | --- | --- |
| [CLAUDE.md](CLAUDE.md) | Durable philosophy, invariants, architecture, conventions | Rarely |
| [PROJECT_STATE.md](PROJECT_STATE.md) | Current phase, what works, next steps, open questions | Every session |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Staged milestones from minimal engine to 2D to 3D | Occasionally |
| [docs/adr/](docs/adr/) | Numbered architecture decision records | Append-only |
| [docs/design/](docs/design/) | Per-subsystem design, written before implementation | As needed |

If you read only one thing, read `CLAUDE.md` §3 — the nine invariants. They are the
constraints everything else follows from, and most of them exist to keep modding possible.

## Target platforms

| Platform | Role | Graphics |
| --- | --- | --- |
| macOS on Apple Silicon | Primary development target, first-class supported | Metal (native) |
| Windows x64 | Intended supported target | Backend deferred until there is a reason |
| Linux x64 | Intended supported target | Backend deferred until there is a reason |

Windows and Linux are cross-compiled as a portability check each milestone; they are not yet
tested at runtime. See [ADR-0008](docs/adr/0008-target-platforms.md).

## Toolchain

**The only tool you need to install is Zig**, pinned to a specific stable release. No CMake,
no Ninja, no Make, no pkg-config — Zig's build system compiles C, C++ and Objective-C,
cross-compiles, fetches dependencies with pinned hashes, runs tests and hosts custom build
steps ([ADR-0014](docs/adr/0014-toolchain.md)). On macOS, Xcode supplies the rest: the Metal
framework, the Objective-C compiler, `xcrun metal` for shaders, and GPU frame capture.

```sh
./scripts/install-zig.sh
```

That fetches the pinned release from ziglang.org, verifies its SHA256, installs it to a
versioned path, and symlinks `zig` into `~/.local/bin` — deliberately not a package-manager
install, so an unrelated upgrade cannot move the compiler. The pinned version is in
[.zigversion](.zigversion). Upgrading is an explicit act, made between milestones.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party dependencies and their
licenses are recorded in [THIRD_PARTY_LICENSES/](THIRD_PARTY_LICENSES/), where a dependency and
its license entry are required to land in the same commit.
