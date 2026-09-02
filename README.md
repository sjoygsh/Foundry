# Foundry

A modular 2D-first game engine, written in Zig, built to grow into a general-purpose
2D/3D engine with modding as a first-class feature rather than an afterthought.

Foundry is a long-term, incremental engineering project. Every milestone is required to
leave behind something that runs.

## Status

Pre-implementation. Architecture established; no engine code written yet.
See [PROJECT_STATE.md](PROJECT_STATE.md) for exactly where things stand.

## Documents

| File | Purpose | Changes |
| --- | --- | --- |
| [CLAUDE.md](CLAUDE.md) | Durable philosophy, invariants, architecture, conventions | Rarely |
| [PROJECT_STATE.md](PROJECT_STATE.md) | Current phase, what works, next steps, open questions | Every session |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Staged milestones from minimal engine to 2D to 3D | Occasionally |
| [docs/adr/](docs/adr/) | Numbered architecture decision records | Append-only |
| [docs/design/](docs/design/) | Per-subsystem design, written before implementation | As needed |

## Target platforms

| Platform | Role | Graphics |
| --- | --- | --- |
| macOS on Apple Silicon | Primary development target, first-class supported | Metal (native) |
| Windows x64 | Intended supported target | Backend deferred until there is a reason |
| Linux x64 | Intended supported target | Backend deferred until there is a reason |

Windows and Linux are cross-compiled as a portability check each milestone; they are not yet
tested at runtime. See [ADR-0008](docs/adr/0008-target-platforms.md).

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party dependencies and their
licenses are recorded in [THIRD_PARTY_LICENSES/](THIRD_PARTY_LICENSES/).

## Building

Nothing to build yet. The only tool that needs installing is Zig (a pinned stable release);
everything else Foundry needs is already provided by Xcode. See
[ADR-0014](docs/adr/0014-toolchain.md) and the setup steps in `PROJECT_STATE.md`.
