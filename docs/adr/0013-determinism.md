# ADR-0013: Deterministic-friendly simulation

**Status:** Accepted
**Date:** 2026-09-02

## Context

Determinism is one of the few properties that is nearly free to design for and extremely
expensive to retrofit. Adding it later means auditing every use of randomness, every
iteration over an unordered container, every read of the wall clock, and every subsystem that
touches simulation state — including subsystems mods have already built against.

Three tiers were considered: none, deterministic-friendly, and bit-exact across platforms.

## Decision

**Deterministic-friendly.** The same binary, given the same inputs and the same seed, produces
the same simulation results. Bit-exact reproducibility across different machines, compilers or
architectures is **explicitly not guaranteed**.

Binding rules — these become Invariant I9:

1. **Fixed timestep simulation**, decoupled from rendering. Rendering interpolates; it never
   feeds back into simulation state.
2. **No global RNG.** Random number generators are explicit objects, seeded deliberately,
   passed to the code that uses them. Seeds come from content or save data, never from the
   clock at an arbitrary point.
3. **Stable, defined iteration order** anywhere iteration order can affect simulation
   results. No iterating a hash map and letting its layout decide outcomes. Where order
   matters, it is defined and documented — not merely stable by accident.
4. **No wall-clock reads inside simulation.** Simulation time comes from the tick counter.
   Wall-clock time is for profiling, frame pacing and display only.
5. **No dependence on pointer or address values** for behaviour or ordering. Already implied
   by Invariant I1, restated because it is a common source of accidental nondeterminism.
6. **Content merge is deterministic.** The same package set in the same load order always
   produces the same resolved content.
7. **No fast-math.** Floating point is permitted, but the compiler is not licensed to
   reassociate it.

## Consequences

* Replays, reproducible bug reports and reproducible mod testing all become possible. For a
  moddable engine, "reproduce this with my load order" is the difference between a fixable
  bug report and an unfixable one.
* The ECS acquires a real requirement: entity iteration order must be stable and documented
  (ADR-0010). This is a constraint on the eventual archetype upgrade too.
* Debugging gets substantially easier — a nondeterministic bug in a game engine is a bad day.
* Cost: slightly more verbose APIs, since RNG must be threaded through rather than reached
  for globally. This is good design regardless, but it is real friction.
* Cost: some convenient patterns are off the table, notably iterating a hash map to drive
  simulation.
* Cost: it must be *maintained*. A single wall-clock read or global RNG in a new subsystem
  silently breaks the property. This deserves a test that runs a fixed scenario twice and
  compares state, added when there is a simulation to run.

**Upgrade path preserved.** If lockstep networking or cross-machine replay verification is
ever wanted, a *subset* can be made bit-exact — most plausibly a fixed-point physics module —
without forcing bit-exactness on the whole engine. Choosing the middle tier now does not
foreclose the strict tier later for the part that actually needs it.

## Alternatives considered

* **No determinism goal.** Simplest, no ongoing discipline. Rejected: it forecloses replays,
  lockstep networking and reproducible bug reports, and retrofitting is invasive precisely
  because the violations are scattered and individually invisible.
* **Bit-exact across platforms.** Enables lockstep multiplayer and cross-machine replay
  verification. Rejected as premature and expensive: it demands strict float discipline or
  fixed-point throughout, a controlled math library, and it permanently constrains every
  future subsystem — including ones mods touch — in exchange for capabilities Foundry has no
  concrete need for yet.

## Revisit if

Lockstep multiplayer or cross-machine replay verification becomes a real requirement, in
which case the question is which *subset* to make bit-exact rather than whether to convert
the whole engine.
