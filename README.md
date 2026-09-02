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

## Target platforms

Windows and Linux are shipping targets. macOS is a development host and an eventual
shipping target. Builds cross-compile from any of the three via the Zig toolchain.

## Building

Nothing to build yet. Toolchain setup is the first task in `PROJECT_STATE.md`.
