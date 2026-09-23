<p align="center">
  <img src="brand/foundry-wordmark.png" alt="Foundry" width="440">
</p>

A modular 2D-first game engine, written in Zig, built to grow into a general-purpose
2D/3D engine with modding as a first-class feature rather than an afterthought.

Foundry is a long-term, incremental engineering project. Every milestone is required to
leave behind something that runs.

## Download

The latest preview is on the [Releases page](https://github.com/sjoygsh/Foundry/releases).
It contains two sample applications:
- **Foundry Room**, a small game with a mod manager;
- **Foundry Sandbox**, the engine's capabilities on display.

They are built for **macOS on Apple Silicon** and **Windows x64**.

**These builds are unsigned previews.** Your system will warn before opening them the first
time:
- **macOS:** open the app once, then go to **System Settings → Privacy & Security** and choose
  **Open Anyway**.
- **Windows:** when "Windows protected your PC" appears, choose **More info → Run anyway**.
  Windows needs a GPU driver with Vulkan 1.3.

Each release lists the SHA-256 of every file, so you can check a download matches.

## Quick start from source

```sh
./scripts/install-zig.sh          # the only tool you need: the pinned Zig
zig build run  -Drhi=metal        # the sandbox, in a window (macOS)
zig build room -Drhi=metal        # the room, a small game
zig build test                    # about 1,680 headless tests
```

On Windows, use `-Drhi=vulkan` with the pinned Vulkan SDK on `PATH` (see
[AGENTS.md](AGENTS.md)).

## What it does

* **2D rendering** through Foundry's own render hardware interface, with Metal and Vulkan
  backends. A validation backend enforces the strict rules either GPU API would forgive, so
  every rendering test runs headlessly.
* **Content as data.** Content lives in Foundry's own `.fdt` text format, compiled to `.fpk`
  packages. Every record has a stable namespaced ID such as `foundry:item.torch`, never a
  load-order index. The engine's own content loads through exactly the path a mod's does.
* **Entities, collision, audio and UI**, all Foundry's own:
  - runtime-registered components and systems, with world saves;
  - tile-grid collision;
  - a WAV mixer;
  - an immediate-mode UI with content-driven themes.
* **Three modding tiers, all working:**
  - content packages;
  - sandboxed, hot-reloadable Lua 5.5.1 scripts;
  - native C mods through one versioned C ABI.

  Players order their mods in an MO2-style mod screen.
* **An editor** that authors content through the same public C ABI a mod uses. It has no
  private path into the engine.
* **Online multiplayer:**
  - one authoritative server;
  - TLS 1.3 with certificates on both sides;
  - commands admitted by tick, and complete state sent to clients.

  It has been played over the public internet, with servers on Windows and Linux.
* **Relocatable releases,** with generated third-party attribution, for macOS and Windows.

## Modding

Modding is a design constraint from the first commit, not a later feature. The disciplines
that keep it possible (stable IDs, handles instead of pointers, one public API, content as
data) are Foundry's nine invariants, in [CLAUDE.md §3](CLAUDE.md#3-invariants). The author
guides are in [docs/modding](docs/modding/):
- [content](docs/modding/content-mods.md);
- [scripts](docs/modding/script-mods.md);
- [native](docs/modding/native-mods.md);
- [authoring](docs/modding/authoring.md);
- [networking](docs/modding/networking.md).

## Target platforms

| Platform | Role | Graphics |
| --- | --- | --- |
| macOS on Apple Silicon | Primary development target, first-class supported | Metal (native) |
| Windows x64 | Second target, runtime-tested since M13 | Vulkan |
| Linux x64 | Headless and server runtime proven in M16.5; the desktop comes after the first game, before 3D | None headless; Vulkan compile-checked only |

Windows runs on one tested Intel Arc machine so far. Linux x64 runs the headless test graph
and the network authority, proven on a cloud VM serving macOS and Windows clients. No Linux
window or graphics driver has run yet. See [ADR-0008](docs/adr/0008-target-platforms.md),
[ADR-0039](docs/adr/0039-linux-after-the-first-game.md) and
[ADR-0046](docs/adr/0046-linux-headless-servers-before-release.md).

## Toolchain

**The only tool you need to install is Zig**, pinned to a specific stable release. No CMake,
no Ninja, no Make, no pkg-config: Zig's build system compiles C, C++ and Objective-C,
cross-compiles, fetches dependencies with pinned hashes, runs tests and hosts custom build
steps ([ADR-0014](docs/adr/0014-toolchain.md)). On macOS, Xcode supplies the rest: the Metal
framework, the Objective-C compiler, `xcrun metal` for shaders, and GPU frame capture.

`./scripts/install-zig.sh` fetches the pinned release from ziglang.org, verifies its SHA-256,
installs it to a versioned path, and symlinks `zig` into `~/.local/bin`. It deliberately
avoids a package manager, so an unrelated upgrade cannot move the compiler. The pinned version
is in [.zigversion](.zigversion).

## Engine modules

Each module is a separate Zig module, and the build graph enforces their layering: a lower
layer cannot import a higher one.

* **`core`**: allocators, generational handles, content IDs, math, fixed-timestep time, RNG,
  and explicit deterministic jobs.
* **`platform`**: window, input, filesystem, dynamic libraries, clocks, the audio device and
  authenticated TLS streams. It has an SDL3 backend and a headless one.
* **`data`**: schemas, the `.fdt` authoring format, the `.fpk` runtime format, and the store
  that merges packages by load order.
* **`rhi`**: the render hardware interface, with Metal, Vulkan and validation backends.
* **`asset`**: Foundry's own PNG decoder, and a registry that loads assets by content ID,
  never by path.
* **`net`**: sessions, grants, admission, tick-admitted commands and replaceable state. It
  handles bytes only; the meaning is the application's.
* **`render2d`**, **`physics2d`**, **`scene`**, **`audio`** and **`ui`**: sprites and text,
  collision, entities and systems, the mixer, and immediate-mode UI.
* **`app`**, **`author`** and **`mod`**:
  - `app`: the engine loop, and the player's mod set and settings;
  - `author`: the one content compiler, with bounded source workspaces;
  - `mod`: discovery, dependencies and deterministic load order.
* **`debug`**: the in-process profiler, memory report, log console, entity inspector and
  content browser.
* **`abi`**: the installed C99/C++ header, and five additive versions of the public API table
  (233 calls), for native mods, scripts, tools and the editor alike.
* **`script`**: the optional restricted Lua runtime, built on that same table.

## How it is built

Foundry is developed by its owner with substantial help from AI coding assistants:
- **Claude Opus 5.5**, **Claude Opus 5** and **Claude Fable 5**, from Anthropic;
- **ChatGPT Sol 5.6** and **ChatGPT Astra 6**, from OpenAI, including through Codex;
- **DeepSeek V4.1 Flash**, from DeepSeek.

They wrote much of the code and documentation. The owner directed and reviewed the work, and
every milestone passed the same tests and runtime checks regardless of who wrote it. Git
history attributes commits to the owner; commits written with an assistant say so in their
trailers.

Decisions are recorded before they are built:
- [CLAUDE.md](CLAUDE.md): the durable principles, invariants and architecture;
- [docs/adr/](docs/adr/): each architectural decision and its reasons;
- [docs/design/](docs/design/): each subsystem's design, written before its code.

## Project status

**M0 through M16.5 are complete; M17 publishes the first preview release.** Foundry is a
playable, moddable, networked 2D engine with an editor. It runs on macOS and Windows, and its
servers also run on Linux. Next is the first game, in its own repository. Linux desktops then
follow in M18, before 3D. Signed and notarized releases wait until after a fully playable 3D
game ([ADR-0047](docs/adr/0047-unsigned-github-preview-release.md)).

- [docs/ROADMAP.md](docs/ROADMAP.md): every milestone, what it proved and what comes next.
- [PROJECT_STATE.md](PROJECT_STATE.md): exactly where things stand, updated every session.

This is a solo project, developed in the open because its boundaries are worth making
checkable. The versioned public C ABI is stable. Interfaces outside it remain free to evolve.

### Scope

This repository is the engine, its tools, its samples and its documentation. **Games live in
their own repositories** and consume Foundry as a dependency, with their licensing and content
decided independently ([ADR-0017](docs/adr/0017-repository-scope.md)). `samples/` holds the
smallest thing that exercises a capability, and a sample is not a game.

### Documents

| File | Purpose | Changes |
| --- | --- | --- |
| [CLAUDE.md](CLAUDE.md) | Durable philosophy, invariants, architecture, conventions | Rarely |
| [AGENTS.md](AGENTS.md) | How to build, verify and work here | As practice changes |
| [PROJECT_STATE.md](PROJECT_STATE.md) | Current phase, what works, next steps, open questions | Every session |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Staged milestones from minimal engine to 2D to 3D | Occasionally |
| [docs/adr/](docs/adr/) | Numbered architecture decision records | Append-only |
| [docs/design/](docs/design/) | Per-subsystem design, written before implementation | As needed |
| [docs/modding/](docs/modding/) | Guides for mod authors and server operators | With the features |
| [docs/shipping/](docs/shipping/) | Packaging, recipients and release gates | At release changes |
| [brand/](brand/) | The marks, and what anyone may do with them | Rarely |

If you read only one thing, read `CLAUDE.md` §3, the nine invariants. Everything else follows
from them, and most of them exist to keep modding possible.

## License

Apache-2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party dependencies and their
licenses are recorded in [THIRD_PARTY_LICENSES/](THIRD_PARTY_LICENSES/), where a dependency and
its license entry must land in the same commit.
