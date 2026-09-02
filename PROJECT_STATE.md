# Foundry Project State

**Last updated:** 2026-09-02
**Updated by:** initial architecture session (second pass, after platform/renderer correction)

This document changes every session. Durable principles live in `CLAUDE.md`; individual
decisions live in `docs/adr/`; milestone definitions live in `docs/ROADMAP.md`.

---

## Current phase

**Phase 1 — Foundation.** Architecture established. No engine code written yet.

## Current milestone

**M0 — Skeleton: "it runs."** Not started.

Target: a window that opens and responds to input on macOS, a fixed-timestep loop, `core`
primitives, a null RHI backend, and cross-compilation checks for Windows and Linux. Full
definition and exit criteria in `docs/ROADMAP.md`.

---

## What has been implemented

Nothing yet, by design. The first objective was architecture, not code.

Repository contents:

* `CLAUDE.md` — philosophy, 9 invariants, architecture, toolchain, conventions, postponed
  decisions.
* `PROJECT_STATE.md` — this file.
* `docs/ROADMAP.md` — M0 through M9, the unscheduled second backend, and the 3D phase.
* `docs/adr/0001`–`0016` — sixteen decisions.
* `docs/design/README.md` — the design docs owed, and when.
* `THIRD_PARTY_LICENSES/README.md` — dependency licensing policy, established before the first
  dependency.
* `LICENSE`, `NOTICE` — Apache-2.0.
* `README.md`, `.gitignore`, `.editorconfig`.

## What currently works

Nothing runs. There is no build yet.

## What is being worked on

Nothing in progress. The next session starts M0.

---

## Immediate next steps

In order. The first three are setup, not engineering.

1. **Install and pin Zig.** A specific *stable* release — never master or nightly (ADR-0001).
   Download the official tarball to a versioned path, record the version and SHA256 in
   `.zigversion` and `minimum_zig_version` in `build.zig.zon`. Do **not** install via Homebrew;
   a package-manager upgrade must not be able to move the compiler.
2. **Verify the SDL3 Zig package builds against that pinned release**, macOS first. This is the
   single highest-risk item in M0. Fallbacks, in order, are documented in ADR-0002: vendor SDL3
   and write our own `build.zig`, then — last resort — CMake with vendored prebuilt libraries.
   Note the constraint from ADR-0001: a package that only supports Zig master is not usable.
   Add SDL3's zlib license entry to `THIRD_PARTY_LICENSES/` in the same commit.
3. **Confirm cross-compilation** to `x86_64-windows` and `x86_64-linux` actually works from
   this machine before the roadmap depends on it.
4. **Write `docs/design/core-memory-and-handles.md`**, then `docs/design/platform-interface.md`.
   The handle table underpins Invariant I1 and every subsystem uses it; it is worth designing
   on paper first.
5. **Write `build.zig`** with the module graph from ADR-0007, so layering is enforced from the
   first line of code.
6. **Implement `core`**: allocators, generational handle table, string IDs and hashing, logging,
   assertions, math, time, explicit RNG.
7. **Implement `platform`**: window, event pump, input, clock, filesystem, opaque
   `NativeSurfaceHandle`. SDL3 confined here.
8. **Implement `app`**: fixed-timestep loop, subsystem lifecycle, clean shutdown.
9. **Define the `rhi` interface and write the null backend.** Interface shape matters far more
   than the backend at this stage.
10. **Build `samples/sandbox`** to M0's exit criteria.

Before M1, and before any Metal code: **`docs/design/rhi.md`**, including the Metal / Vulkan /
D3D12 concept mapping table from ADR-0003. This is the highest-leverage document in the project.

---

## Known bugs and technical debt

None. There is no code.

Anticipated debt, recorded early so it is not mistaken for oversight:

* **The RHI will be validated by exactly one backend for a long time.** ADR-0003's mitigations
  (design to the strict model, null backend as validator) reduce this but do not remove it.
  Expect backend #2 to find design errors.
* Shaders will need per-backend variants when a second backend lands (ADR-0015). Small while
  the shader set is small; the shader set's growth is the trigger to revisit.
* Sparse-set entity storage (M4) is explicitly a first implementation, not a final one.
* The first content authoring format may need replacing once real content exists at scale.
  ADR-0006 contains this by separating schemas from syntax.
* "Supported" currently means "compiles" for Windows and Linux. Stated plainly in ADR-0008
  rather than implying coverage that does not exist.

---

## Important decisions made recently

Sixteen ADRs written this session. Four were revised in place the same session, before any code
existed, after the platform and renderer direction was corrected: 0001 (stable-release pinning
tightened), 0002 (acquisition and Metal seam), 0003 (**Vulkan-first reversed to Metal-first**),
0008 (**macOS promoted from dev host to primary target**).

Widest blast radius:

* **Metal is the first real backend; macOS is the primary target** (ADR-0003, ADR-0008). No
  MoltenVK. This turns "first pixels" from the largest milestone in the project into a small
  one, at the cost of an abstraction validated by a single API for a while.
* **Two rendering boundaries, not one** (ADR-0003). Games see the Renderer API; the RHI is
  engine-internal and never exposed to games or mods.
* **Zig pinned to a stable release, never master** (ADR-0001). Consequence: packages that only
  support master are unusable.
* **Toolchain is Zig only** (ADR-0014). No CMake, Ninja, Make or pkg-config — Zig's build system
  covers every reason they would be adopted. Xcode already supplies the Metal toolchain, the
  Objective-C compiler and GPU frame capture.
* **One public C ABI shared by mods, scripts, tools and the editor** (ADR-0004). Nothing gets a
  private back door, which is what keeps the mod API honest.
* **Stable namespaced content IDs, never load-order-derived** (ADR-0005). Directly rejects the
  Creation Engine FormID model.
* **Runtime-registered, type-erased component types** (ADR-0010). Determines whether mods can
  add real component types or merely fill in fields.
* **Deterministic-friendly simulation** (ADR-0013, Invariant I9). Cheap now, invasive later.
* **Apache-2.0 with a permissive-only dependency policy** (ADR-0016), and the
  `THIRD_PARTY_LICENSES/` system established before the first dependency exists.

---

## Major unresolved questions

1. **Which stable Zig release to pin.** Determined at install time. Once chosen it constrains
   which third-party Zig packages are usable (ADR-0001).
2. **Does the SDL3 Zig package support that release?** The M0 gate. If not, the fallback is real
   work (ADR-0002).
3. **RHI granularity.** To be settled in `docs/design/rhi.md`: how coarse the resource-group /
   binding model should be, and how explicitly resource state transitions are expressed given
   that Metal will ignore them. Too abstract and Vulkan cannot implement it efficiently; too
   thin and the Metal backend carries pointless ceremony.
4. **What "package zero" means for the engine itself.** Does the engine ship content of its own
   — default font, error texture, fallback shader — as a real content package? Probably yes, and
   it is a good early test of Invariant I3. Decide during M3.
5. **Authoring format syntax.** Postponed to M3 by ADR-0006. Requirements recorded; candidates
   are adopting an existing format versus a small purpose-built one.
6. **Zig upgrade cadence.** ADR-0001 says between milestones, never during. Whether that means
   *every* milestone boundary or only when there is a reason is unresolved.
7. **When backend #2 is triggered.** Deliberately unscheduled (ADR-0003). The trigger is a
   reason, not a date — but it is worth noticing if that reason never arrives, since the RHI
   stays unvalidated until it does.

---

## Notes for the next session

* Read `CLAUDE.md` first, then this file, then `docs/ROADMAP.md`.
* The architecture is settled. Do not relitigate ADRs without a concrete reason; each records
  the conditions that would justify revisiting it.
* Sessions are bounded by available context, not calendar time. Prefer finishing a coherent
  piece and updating this file over leaving several things half-built.
* Machine: Apple M5, macOS 26.6.2, Xcode 26 with SDK 26.5, Metal toolchain present, Homebrew
  present, git and Python present. Zig is not installed yet.
