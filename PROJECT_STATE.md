# Foundry Project State

**Last updated:** 2026-09-02
**Updated by:** initial architecture session

This document changes every session. Durable principles live in `CLAUDE.md`; individual
decisions live in `docs/adr/`; milestone definitions live in `docs/ROADMAP.md`.

---

## Current phase

**Phase 1 — Foundation.** Architecture established. No engine code written yet.

## Current milestone

**M0 — Skeleton: "it runs."** Not started.

Target: a window that opens and responds to input, a fixed-timestep loop, `core` primitives,
a null RHI backend, and builds for all three platforms. See `docs/ROADMAP.md` for the full
definition and exit criteria.

---

## What has been implemented

Nothing yet, by design. The first objective was architecture, not code.

Repository contents so far:

* `CLAUDE.md` — philosophy, invariants, architecture, conventions, postponed decisions.
* `PROJECT_STATE.md` — this file.
* `docs/ROADMAP.md` — M0 through M9 plus the 3D phase.
* `docs/adr/0001`–`0011` — the eleven decisions made this session.
* `README.md`, `.gitignore`, `.editorconfig`.
* Git repository initialized.

## What currently works

Nothing runs. There is no build yet.

## What is being worked on

Nothing in progress. The next session starts M0 from a clean slate.

---

## Immediate next steps

In order. The first three are setup, not engineering.

1. **Install and pin the Zig toolchain.** Record the exact version in `.zigversion` and as
   `minimum_zig_version` in `build.zig.zon`. Confirm cross-compilation to
   `x86_64-windows-gnu` and `x86_64-linux-gnu` works from this macOS host before relying on it.
2. **Decide how SDL3 is obtained** — built from source through `build.zig` (preferred, best
   for cross-compilation) or linked as a prebuilt library (fallback). Verify this early; it is
   the most likely source of unpleasant surprises in M0.
3. **Choose a license.** It interacts with the mod ABI and with third-party licenses. Listed
   as an open question below.
4. **Write `build.zig`** with the module graph from ADR-0007, so the layering is enforced from
   the first line of code.
5. **Implement `core`**, in this order: allocators, generational handle table, string IDs and
   hashing, logging, assertions, math, time.
6. **Implement `platform`**: window, event pump, input, clock, filesystem. SDL3 confined here.
7. **Implement `app`**: fixed-timestep loop, subsystem lifecycle, clean shutdown.
8. **Define the `rhi` interface and write the null backend.** Interface shape matters more
   than the backend at this stage.
9. **Build `samples/sandbox`** to M0's exit criteria, and actually run a Windows or Linux
   build rather than only compiling one.

A design doc in `docs/design/` should precede items 5–8. `core`'s handle table and allocator
model in particular are worth designing on paper first — Invariant I1 depends on getting the
handle table right, and every subsystem will use it.

---

## Known bugs and technical debt

None. There is no code.

Anticipated debt, recorded early so it is not mistaken for oversight:

* The null RHI backend will need to grow validation as the real backend reveals what needs
  checking.
* The first content authoring format may need replacing once real content exists at scale.
  ADR-0006 keeps this contained by separating schemas from syntax.
* Sparse-set entity storage (M4) is explicitly a first implementation, not a final one.

---

## Important decisions made recently

All eleven ADRs were written this session. The ones with the widest blast radius:

* **Zig, idiomatic internally, C ABI only at the outer boundary** (ADR-0001). Pre-1.0 churn
  is an accepted, actively managed risk.
* **Foundry's own RHI with a Vulkan backend, not SDL3's GPU layer** (ADR-0003). Correct
  long-term, and it makes M1 the largest milestone in the project. The null backend is the
  mitigation that keeps everything else moving.
* **One public C ABI shared by mods, scripts, tools and the editor** (ADR-0004). Nothing gets
  a private back door, including the editor — which is what keeps the mod API honest.
* **Stable namespaced content IDs, never load-order-derived** (ADR-0005). Directly rejects the
  Creation Engine FormID model.
* **Runtime-registered, type-erased component types** (ADR-0010). The single decision that
  determines whether mods can add real component types or only fill in fields.
* **The base game is content package zero** (Invariant I3). First-party content uses the
  identical path mods use, so the mod path cannot rot.

---

## Major unresolved questions

1. **License.** Needs deciding before there is much code. Interacts with the mod ABI (what
   are mod authors permitted to do?) and with vendored third-party licenses.
2. **SDL3 acquisition and cross-compilation.** Building SDL3 from source through `build.zig`
   for three targets is the preferred path but unproven here. This is the main M0 risk.
3. **Windows/Linux test environment.** ADR-0008 requires running, not just building, on the
   ship targets each milestone. VM or hardware — unresolved logistics.
4. **Authoring format syntax.** Postponed to M3 by ADR-0006. Requirements are recorded;
   candidates are adopting an existing format versus a small purpose-built one.
5. **What "package zero" means for the engine itself.** Does the engine ship content of its
   own (default fonts, error textures, fallback shaders) as a real content package? Probably
   yes, and it is a good early test of Invariant I3. Decide during M3.
6. **Zig version upgrade cadence.** ADR-0001 says between milestones, never during. Whether
   that means *every* milestone boundary or only when there is a reason is unresolved.

---

## Notes for the next session

* Read `CLAUDE.md` first, then this file, then `docs/ROADMAP.md`.
* The architecture is settled. Do not relitigate ADRs 0001–0011 without a concrete reason;
  each records the conditions that would justify revisiting it.
* Sessions are bounded by available context, not by calendar time. Prefer finishing a
  coherent piece and updating this file over leaving several things half-built.
