# ADR-0001: Zig as the implementation language, C ABI only at the boundary

**Status:** Accepted
**Date:** 2026-09-02
**Revised:** 2026-09-02 — pinning tightened to stable releases only, no master/nightly.

## Context

Foundry is a multi-year, solo, from-scratch engine project. The developer has strong systems
programming experience (C/C++/Rust), develops on macOS, and ships to Windows and Linux.
Requirements that bear on language choice: minimal proprietary dependency, deep modding
support with a stable interface between engine and mods, replaceable subsystems, and a real
chance of the project being finished.

The developer proposed Zig with a C ABI, noting the C ABI part was open to change.

## Decision

**Zig**, with a two-level structure:

* **Internally**, idiomatic Zig — generics, slices, error unions, `comptime`, explicit
  allocators. Internal module boundaries are Zig interfaces, not C ones.
* **At the outer boundary**, a narrow versioned C ABI (see ADR-0004).

The compiler version is **pinned in-repo** to a **specific stable Zig release**
(`.zigversion` plus `minimum_zig_version` in `build.zig.zon`, with the release's SHA256
recorded).

**Foundry never tracks Zig master or nightly builds.** Not for a feature, not temporarily,
not for a dependency that only builds against master. A pre-1.0 language is survivable when
you control *when* you absorb its breakage; tracking master means absorbing it continuously
and unpredictably, which is the failure mode that kills long-running Zig projects.

Toolchain upgrades are an explicit, deliberate project decision, performed **between**
milestones and never during one. An upgrade is its own commit, carrying the version bump, any
resulting code changes, and a note in `PROJECT_STATE.md`. The compiler is installed from the
official release tarball at a versioned path rather than through a package manager, so that
an unrelated `brew upgrade` cannot silently change the toolchain.

## Consequences

Good:

* `comptime` gives serialization, schema handling and component reflection without a code
  generation step or macro machinery.
* Explicit allocators match what an engine wants anyway: per-frame arenas, per-subsystem
  pools, no hidden allocation.
* C interop is free. Every library Foundry might want — SDL3, Vulkan, a scripting runtime —
  is C.
* Cross-compilation is built in, which matters concretely: a macOS host shipping Windows and
  Linux is exactly Zig's strongest case.
* One language for source, build system and tests.
* Zig has no stable ABI of its own, which pushes the public boundary toward C — where it
  belongs anyway.

Costs, accepted knowingly:

* **Zig is pre-1.0. The language and `std` break between releases.** Over a multi-year
  project this cost is paid repeatedly. Mitigated by pinning to stable releases, by never
  tracking master, by scheduling upgrades between milestones, and by concentrating `std`
  usage behind `core`.
* A consequence of refusing master: a third-party Zig package that only supports master is
  not usable by Foundry. This is a real constraint on dependency choice, accepted
  deliberately — it is the price of a stable floor.
* Small ecosystem; few engine-specific resources or people to ask.
* Debugger and profiler tooling is less mature than C++'s.
* No guarantee of a 1.0 date.

Escape hatch: because module boundaries are explicit and the public surface is C-shaped, a
worst-case port to C or C++ is painful but not fatal. This is a fallback, not a plan.

## Alternatives considered

* **C++** — largest ecosystem, most engine literature, best tooling. Rejected because Zig's
  `comptime`, allocator model and cross-compilation are direct wins for this specific
  project, and the developer explicitly wants Zig. C++ remains the strongest fallback.
* **Rust** — excellent tooling and safety; `wgpu` is a strong GPU story. Rejected for real
  friction with engine-shaped data structures (cyclic references, arena/handle patterns) and
  a weak dynamic-plugin story, which matters for Tier 3 mods.
* **C** — maximum portability and ABI stability. Rejected: no `comptime`, no generics, no
  slices; too much of the engine becomes hand-written boilerplate.

## Revisit if

Zig's churn consumes a materially disruptive share of development time across several
milestones, or the language's direction changes in a way that breaks the allocator or
`comptime` models Foundry depends on.
