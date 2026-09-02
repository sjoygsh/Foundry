# Foundry Project State

**Last updated:** 2026-09-02
**Updated by:** M0 setup session — toolchain pinned, SDL3 gate cleared, repository published

This document changes every session. Durable principles live in `CLAUDE.md`; individual
decisions live in `docs/adr/`; milestone definitions live in `docs/ROADMAP.md`.

---

## Repository

**Canonical home: `github.com/sjoygsh/Foundry`** — public, Apache-2.0, established
2026-09-02. This repository is the engine, its tools, its samples and its documentation.
Games live in their own repositories and consume Foundry as a dependency (ADR-0017).

No CI, release automation or contribution infrastructure yet; those arrive when the project
is mature enough to need them rather than as decoration.

## Current phase

**Phase 1 — Foundation.**

## Current milestone

**M0 — Skeleton: "it runs."** In progress. The three setup items are done; no engine code
written yet.

Target: a window that opens and responds to input on macOS, a fixed-timestep loop, `core`
primitives, a null RHI backend, and cross-compilation checks for Windows and Linux. Full
definition and exit criteria in `docs/ROADMAP.md`.

---

## What has been implemented

**Toolchain and dependency verification. No engine code yet.**

New this session:

* `scripts/install-zig.sh` — fetches the pinned Zig release from the official tarball,
  verifies SHA256, installs to a versioned path, symlinks `~/.local/bin/zig`, and writes
  `.zigversion`. Idempotent.
* `.zigversion` — `0.16.0`.
* `THIRD_PARTY_LICENSES/sdl3.md` — SDL3's entry, including the HIDAPI license election.
* Resolution notes appended to ADR-0001 (which Zig release, and how it is installed) and
  ADR-0002 (which SDL3 package, and the evidence it works).
* `docs/adr/0017-repository-scope.md` — the engine is a standalone public repository; games
  are separate consumers. Reflected in `CLAUDE.md` §4.1, §4.5 and §10.
* `README.md` rewritten for an audience that is not us: scope, toolchain setup, and an honest
  statement of how early this is.
* Commit history normalised to a single author identity before publication.

Pre-existing: `CLAUDE.md`, `docs/ROADMAP.md`, ADRs 0001–0016, `docs/design/README.md`,
`THIRD_PARTY_LICENSES/README.md`, `LICENSE`, `NOTICE`, `README.md`, `.gitignore`,
`.editorconfig`.

## What currently works

**Zig 0.16.0 is installed and pinned.** `~/.local/zig/0.16.0`, symlinked at
`~/.local/bin/zig`. Verified: native build, `zig build test`, and cross-compilation to
`x86_64-windows-gnu`, `x86_64-linux-gnu` and `aarch64-linux-gnu` producing correct PE32+ and
ELF binaries — with no toolchain beyond Zig.

**The M0 gate is cleared: SDL3 builds and the Metal seam works.** `castholm/SDL`
v0.5.3+3.4.14 (SDL 3.4.14) builds from source against Zig 0.16.0. A probe opened a window
under the `cocoa` driver with `SDL_WINDOW_METAL`, obtained a live `CAMetalLayer` via
`SDL_Metal_CreateView` / `SDL_Metal_GetLayer`, pumped events and exited cleanly. Full SDL3
also cross-compiles from macOS to Windows x64 and Linux x64.

**Caveat, stated plainly:** that probe was built in a scratch directory and is **not** in this
repository. There is still no `build.zig`, no `build.zig.zon` and no engine source here. The
verification is evidence that the plan works, not code that implements it. Nothing in the repo
builds yet, because there is nothing in the repo to build.

## What is being worked on

Nothing in progress. The next session continues M0 at step 1 below.

---

## Immediate next steps

Setup is finished. Everything remaining in M0 is engineering.

1. **Write `docs/design/core-memory-and-handles.md`**, then `docs/design/platform-interface.md`.
   The handle table underpins Invariant I1 and every subsystem uses it; it is worth designing
   on paper first. The platform interface doc matters for a second reason recorded in ADR-0002:
   it is where SDL concepts are most likely to leak into the *design* rather than just the
   implementation.
2. **Write `build.zig` and `build.zig.zon`** with the module graph from ADR-0007, so layering
   is enforced from the first line of code (I7). The SDL3 dependency lands here, pinned by the
   hash already verified this session:
   `git+https://github.com/castholm/SDL.git?ref=v0.5.3+3.4.14#fb2d799c4778832a34ccb3739e40dded700684bd`
   `hash = "sdl-0.5.3+3.4.14-SDL--v4eqAGuIKFsspMVxBxZf1OIEmmH-yHDdEl9ZRdX"`
   Its `THIRD_PARTY_LICENSES/` entry already exists, so the same-commit rule is satisfied.
3. **Implement `core`**: allocators, generational handle table, string IDs and hashing, logging,
   assertions, math, time, explicit RNG.
4. **Implement `platform`**: window, event pump, input, clock, filesystem, opaque
   `NativeSurfaceHandle`. SDL3 confined here.
5. **Implement `app`**: fixed-timestep loop, subsystem lifecycle, clean shutdown.
6. **Define the `rhi` interface and write the null backend.** Interface shape matters far more
   than the backend at this stage.
7. **Build `samples/sandbox`** to M0's exit criteria.
8. **Add a script that builds all three targets**, so the cross-compile obligation is checked
   rather than remembered.

Before M1, and before any Metal code: **`docs/design/rhi.md`**, including the Metal / Vulkan /
D3D12 concept mapping table from ADR-0003. This is the highest-leverage document in the project.

---

## Known bugs and technical debt

No code, so no bugs.

Anticipated debt, recorded early so it is not mistaken for oversight:

* **The RHI will be validated by exactly one backend for a long time.** ADR-0003's mitigations
  (design to the strict model, null backend as validator) reduce this but do not remove it.
  Expect backend #2 to find design errors.
* **SDL3 arrives through a third-party build script** that can bitrot against a future pinned
  Zig release. Checking it is part of the cost of every Zig upgrade. Fallbacks in ADR-0002.
* Shaders will need per-backend variants when a second backend lands (ADR-0015). Small while
  the shader set is small; the shader set's growth is the trigger to revisit.
* Sparse-set entity storage (M4) is explicitly a first implementation, not a final one.
* The first content authoring format may need replacing once real content exists at scale.
  ADR-0006 contains this by separating schemas from syntax.
* "Supported" still means "compiles" for Windows and Linux — but as of this session that claim
  is at least tested, including SDL itself, rather than assumed.

---

## Important decisions made recently

**This session:**

* **Pinned Zig 0.16.0**, installed from the official tarball with hash verification to a
  versioned path, never Homebrew (ADR-0001 resolution). Constrains which Zig packages are
  usable, which is exactly why it was the first thing settled.
* **SDL3 via `castholm/SDL` v0.5.3+3.4.14**, chosen over `allyourcodebase/SDL` because it keeps
  the Linux system dependencies behind one lazily-fetched package instead of resolving X11,
  Wayland, dbus, EGL and xkbcommon separately — a smaller surface to pin and audit
  (ADR-0002 resolution).
* **HIDAPI license election: BSD-3-Clause.** SDL bundles HIDAPI under
  `GPL-3.0-only OR BSD-3-Clause OR HIDAPI`. The `OR` makes it the recipient's choice, so no GPL
  obligation attaches. Verified against the package's `REUSE.toml` that no GPL identifier
  stands alone. Written down because "SDL has GPL in it" would otherwise cause a false alarm
  years from now (`THIRD_PARTY_LICENSES/sdl3.md`).
* **Neither ADR-0002 fallback was needed**, so ADR-0014's "Zig is the only build tool" claim
  survived contact with the project's first real dependency.
* **The engine gets its own public repository; games get theirs** (ADR-0017). The convenience
  of a shared repository is exactly the friction that keeps I4 and I5 honest, so it is
  deliberately declined. Consequence: Foundry has to be genuinely consumable before there is
  anything consuming it.

**Earlier (architecture session):** sixteen ADRs. Widest blast radius: Metal-first with macOS
primary (0003, 0008); two rendering boundaries with the RHI never exposed (0003); Zig pinned to
stable, never master (0001); toolchain is Zig only (0014); one public C ABI shared by mods,
scripts, tools and the editor (0004); stable namespaced content IDs, never load-order-derived
(0005); runtime-registered type-erased component types (0010); deterministic-friendly
simulation (0013, I9); Apache-2.0 with a permissive-only dependency policy (0016).

---

## Major unresolved questions

1. **RHI granularity.** To be settled in `docs/design/rhi.md`: how coarse the resource-group /
   binding model should be, and how explicitly resource state transitions are expressed given
   that Metal will ignore them. Too abstract and Vulkan cannot implement it efficiently; too
   thin and the Metal backend carries pointless ceremony.
2. **What "package zero" means for the engine itself.** Does the engine ship content of its own
   — default font, error texture, fallback shader — as a real content package? Probably yes, and
   it is a good early test of Invariant I3. Decide during M3.
3. **Authoring format syntax.** Postponed to M3 by ADR-0006. Requirements recorded; candidates
   are adopting an existing format versus a small purpose-built one.
4. **Zig upgrade cadence.** ADR-0001 says between milestones, never during. Whether that means
   *every* milestone boundary or only when there is a reason is still unresolved. Now has a
   concrete input: each upgrade must re-verify the SDL3 port.
5. **When backend #2 is triggered.** Deliberately unscheduled (ADR-0003). The trigger is a
   reason, not a date — but it is worth noticing if that reason never arrives, since the RHI
   stays unvalidated until it does.

*Resolved this session: which stable Zig release to pin, and whether the SDL3 Zig package
supports it. Both were the top two questions on this list.*

---

## Notes for the next session

* Read `CLAUDE.md` first, then this file, then `docs/ROADMAP.md`.
* The architecture is settled. Do not relitigate ADRs without a concrete reason; each records
  the conditions that would justify revisiting it.
* Sessions are bounded by available context, not calendar time. Prefer finishing a coherent
  piece and updating this file over leaving several things half-built.
* **Zig 0.16.0 build-system idioms differ from older releases.** Confirmed against this exact
  compiler: modules are created with `b.addModule` / `b.createModule` and wired through
  `.imports`; `addExecutable` and `addTest` take a `.root_module` rather than a
  `root_source_file` directly; `build.zig.zon` requires a `.fingerprint` field and its `.name`
  is an enum literal (`.foundry`, not `"foundry"`). Run `zig init` in a scratch directory and
  read the generated files before trusting any remembered API.
* **Reference development environment**, which is what the verification above was performed
  against: Apple Silicon, macOS 26, Xcode 26 with SDK 26.5, Zig 0.16.0. The Metal toolchain is
  always invoked via `xcrun`, never a hardcoded path — it lives on a versioned mount that moves
  between updates. Homebrew may exist on a developer's machine but nothing in Foundry may
  assume it.
* `scripts/install-zig.sh` places Zig at `~/.local/zig/<version>` and symlinks
  `~/.local/bin/zig`. If `~/.local/bin` is not on `PATH`, add it:
  `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`
