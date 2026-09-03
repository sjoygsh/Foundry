# Foundry

A modular 2D-first game engine, written in Zig, built to grow into a general-purpose
2D/3D engine with modding as a first-class feature rather than an afterthought.

Foundry is a long-term, incremental engineering project. Every milestone is required to
leave behind something that runs.

## Status

**M0 complete.** It runs: a window opens on macOS and responds to input, the
fixed-timestep loop turns, and the sample exits cleanly. Nothing is drawn yet — M0
deliberately excludes the GPU, and the renderer is M1.

```sh
./scripts/install-zig.sh   # the only tool you need
zig build run              # opens a window; escape quits
zig build test             # 222 tests
```

Implemented so far:

* **`core`** — allocators, generational handles, content IDs, math, fixed-timestep time, RNG.
* **`platform`** — window, input, filesystem, dynamic libraries, clocks. An SDL3 backend
  and a headless one, kept honest by a `comptime` conformance check.
* **`rhi`** — the render hardware interface, with a **validation backend** that enforces
  the strict rules Metal forgives. Not scaffolding: it is what substitutes for a second
  graphics backend until there is one.
* **`app`** — the engine loop, subsystem lifecycle, and the log sink.

[PROJECT_STATE.md](PROJECT_STATE.md) records exactly where things stand, and is updated
every session.

This is currently a solo project in its earliest stage. It is developed in the open because
the boundaries are worth making checkable, not because it is ready to be depended on — the
public API does not exist yet, and nothing is stable. Contribution infrastructure will appear
when there is something to contribute to.

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
