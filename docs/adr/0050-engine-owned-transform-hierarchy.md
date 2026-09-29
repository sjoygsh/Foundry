# ADR-0050: The engine declares the 3D transform and hierarchy components

**Status:** Accepted 2026-09-27; implemented in M21, complete 2026-09-29 ([`hierarchy.md`](../design/hierarchy.md), tag `m21`)
**Date:** 2026-09-27
**Revised:** 2026-09-27, before any code depended on it. The owner asked for keep-world
re-parenting to be defined exactly. It now names its checks, its tolerance and its errors, and it
states that a refusal changes nothing (`3d.md` §7.1). The refusal itself is unchanged.
**Informed by:** ADR-0010, ADR-0013, ADR-0048, `entity-storage.md`, `tilemaps-and-collision.md`,
`docs/design/3d.md` §7

## Context

Since M5, the engine has declared no component types. A name chosen before any game says what
belongs on it is a name every mod is stuck with, so `foundry:collider` was deliberately never
made, and each 2D sample wires its own. A 3D hierarchy is different in kind: propagation,
collision sync, animation output and render extraction all need one shared answer to "where is
this, relative to what". Left to games, every mod would invent its own transform, and mods could
not attach to each other's objects.

## Decision

**`scene` declares `foundry:transform`** (local translation, unit rotation, scale),
**`foundry:parent`** (an entity reference, saved through the existing entity-reference path),
and **`foundry:world_transform`** (a derived affine matrix: never saved, never authored, written
only by propagation). The semantics are `3d.md` §7's:
- **Propagation** is one system at a documented point in the tick. It visits parents before
  children, and entities at equal depth in ascending handle order. Between runs a world
  transform is the last run's.
- **Only entities with a transform take part.** A missing parent makes the child a root, and is
  reported. Cycles and over-deep chains are refused when set.
- **Re-parenting keeps the local transform by default.** An explicit variant keeps the world
  pose. It is defined in `3d.md` §7.1:
  - it computes both world matrices fresh, and `L = P⁻¹ · W`;
  - it decomposes `L` canonically, with a reflection carried as a negative x scale;
  - `L` is **representable exactly** if and only if recomposing the decomposition as `T · R · S`
    reproduces every element of `L` within `ε_rep · max(1, ‖L‖∞)`, where `ε_rep = 1e-5`;
  - otherwise it refuses as `NotRepresentable` (shear, or a zero scale), `SingularParent`,
    `WouldCycle`, `TooDeep` or `NoSuchEntity`;
  - **a refusal writes nothing to any entity.**
  
  Shear is legal in a world matrix and never in a `Transform`. Propagation and keep-local never
  decompose, so they accept sheared chains.
- **Despawning a parent despawns its descendants.**
- The names and semantics are generic, and no game's assumptions are in them. 2D games need not
  use them.

## Consequences

- Games, mods, `render3d` extraction and the future editor share one pose model.
- Mods can parent to each other's entities.
- **These are permanent public names** (CLAUDE.md §7). They enter the ABI in `FoundryApi_v6`,
  and their layout is versioned like any schema (I8).
- This is the first exception to M5's "no engine component types". Future engine components need
  the same bar: a mechanism that cannot work without a shared name.
- A caller that wants a sheared pose approximated must choose the approximation itself, and then
  re-parent with keep-local. The engine never picks one silently. M21's tests cover rotated,
  non-uniformly scaled chains, and assert that every refusal leaves every entity byte-identical.
- A derived component costs a matrix per entity, and a one-tick staleness that callers must
  know about. An on-demand computation covers the few that cannot wait.

## Alternatives considered

- **A mechanism over game-declared components.** It adds no engine names, but every game and mod
  re-declares a transform, and two mods cannot share a parent. That is worse for modding
  (development rule 12) than one well-chosen name.
- **Storing the world transform as the authored pose.** It makes re-parenting and saves ambiguous,
  and loses the local pose's exactness under non-uniform scale.
- **Repairing shear on keep-world** (orthogonalising, or dropping the off-axis part). It moves
  the object visibly, with no one having asked.
- **Allowing shear in `foundry:transform`** (storing a full affine local). Every consumer of the
  authored pose, including physics, animation, saves and the ABI, would then need to handle a
  non-TRS pose, for a case that only one operation creates.
- **Orphaning children on despawn.** Things would move without anyone asking, and the result would
  depend on despawn order.

## Revisit if

- A game needs a transform representation §2 cannot express, such as double-precision
  positions.
- Propagation's single tick point measurably fails a game's system ordering.
- A second engine-declared component is proposed, which should be judged by this ADR's bar.
