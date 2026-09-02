# ADR-0007: Module layering enforced by the Zig build graph

**Status:** Accepted
**Date:** 2026-09-02

## Context

Foundry requires that major subsystems be replaceable without rewriting the engine. That
requires real boundaries. Modularity maintained by convention alone decays: under deadline
pressure someone adds one sideways import, and a year later the "modular" engine is a ball
of mud.

Zig's build system declares modules explicitly and grants each module access only to the
modules named as its dependencies.

## Decision

Each engine subsystem is a **separate Zig module** declared in `build.zig`, with its
dependencies stated explicitly. A module can only import what the build graph grants it, so a
layering violation is a **build error**, not a code review finding.

```
L0  core       std only
L1  platform   -> core            (SDL3 lives ONLY here)
L1  data       -> core
L2  rhi        -> core, platform  (Vulkan/Metal/D3D live ONLY here)
L2  asset      -> core, data, platform
L3  render2d   -> core, rhi, asset
L3  scene      -> core, data, asset
L4  app        -> all of the above
L5  abi        -> app             (added at M7)
```

Dependencies point downward only. If a new subsystem does not fit, that is a signal to
re-examine the subsystem or the layering explicitly with the user, not to add a sideways
dependency.

## Consequences

* The two most important containment rules — SDL3 confined to `platform`, graphics APIs
  confined to `rhi` — are mechanically enforced. Replacing either is a bounded job.
* Compile times improve; changing `render2d` cannot force a rebuild of `core`.
* Modules are independently testable, and the dependency graph is legible in one file.
* Cost: shared types must live low in the stack, which occasionally means putting something
  in `core` that only two upper modules use.
* Cost: genuine cross-cutting concerns (logging, profiling, allocation) must be designed as
  `core` primitives that upper layers use, rather than as ambient services.
* Cost: the layering will sometimes be inconvenient. That is the point; the inconvenience is
  the signal.

## Alternatives considered

* **One module, directory convention** — simplest, zero build complexity. Rejected: no
  enforcement, and the boundaries erode.
* **Separate repositories per subsystem** — hardest possible boundary. Rejected as far too
  much ceremony for a solo project; version skew between repos would dominate.
* **A linting or import-checking script** — enforcement without build complexity. Rejected:
  a second mechanism to maintain when the build system already does this natively.

## Revisit if

The layering forces genuinely awkward designs repeatedly, or Zig's module system changes in
a way that makes this impractical.
