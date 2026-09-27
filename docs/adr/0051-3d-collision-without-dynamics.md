# ADR-0051: 3D collision, queries and a character controller; no dynamics

**Status:** Accepted 2026-09-27 (constraint only; M23 implements it)
**Date:** 2026-09-27
**Informed by:** ADR-0013, ADR-0022, `docs/design/3d.md` §8

## Context

A playable 3D game needs to walk, collide, look and pick. It does not necessarily need mass,
stacking or constraints. ADR-0022 built Foundry's own 2D collision, scoped to collision rather
than dynamics, because I9 decided it and not licensing, and it held: two samples and the first
game used it without a solver.

## Decision

**`physics3d` is an L1 module on `core` alone,** shaped like `physics2d`: no time, no velocity, a
caller-supplied displacement, an opaque `u64` per body, and the game wiring it to `scene`. It
provides:
- **shapes:** sphere, capsule, box, convex hull, and static triangle mesh from a collision asset;
- **static and kinematic bodies,** with layers and masks;
- **queries:** raycast, shape cast, overlap and closest hit;
- **a character controller:** collide-and-slide with a bounded iteration count, ground detection,
  a maximum slope, step-up, snap-down, ceilings, depenetration, and no tunnelling at its
  configured speeds.

Candidates are sorted by handle, iteration counts are fixed, and there is no fast-math. A replay
is byte-exact on the same machine.

**No rigid-body dynamics.** Mass, integration, stacking, joints, ragdolls, vehicles, pushing and
carrying platforms wait for a game that needs them.

## Consequences

- The capability a walkable 3D game needs is covered without a solver or a dependency.
- Determinism is within Foundry's control.
- **Games that want physical objects cannot have them yet.** That gap is honest, and it is named.
- The query and shape API is designed to stay when a solver arrives beneath it.

## Alternatives considered

- **Jolt Physics now (MIT, with a deterministic mode).** It is the leading candidate *when*
  dynamics are due, and it would be a large C++ dependency and an integration milestone for a
  capability nothing has asked for.
- **Write a general solver now.** That is the premature generality ADR-0022 declined in 2D.
- **Physics in the game only.** Every game would rewrite the controller and its edge cases,
  which are the hard part.

## Revisit if

- A game needs simulated objects, stacking, joints, ragdolls or vehicles. That is a new ADR,
  weighing Jolt against a solver.
- A game needs moving platforms, or characters that push each other.
- Triangle-mesh queries are measured too slow for a shipped level.
