# ADR-0010: Entity/component model constraints

**Status:** Accepted (constraint only; implementation deferred to M4)
**Date:** 2026-09-02

## Context

The entity model is one of the few things that is genuinely brutal to change once gameplay
code is written against it. Two properties must be decided now even though nothing is being
implemented yet, because retrofitting either is a rewrite.

The critical one is modding-driven. In Zig, the natural and fastest entity storage registers
component types at `comptime`: the set of components is fixed when the engine compiles. That
is a clean design and it makes mods that add new component types **impossible** — which
would violate development rule 12 outright.

## Decision

Two binding constraints; the implementation itself is deferred to M4.

**1. Component types are registered at runtime, storage is type-erased.**
A component type is described by a runtime `ComponentTypeInfo`: stable ID, name, size,
alignment, and function pointers for serialization, deserialization, and optional
construction and destruction. Storage is type-erased byte arrays keyed by that info.

Native Zig code registers via `comptime` helpers that *produce* a `ComponentTypeInfo` from a
Zig type, so engine and game code keeps full type safety and ergonomics. Mods register the
same structure through the C ABI. Both use the same registry (Invariant I6).

**2. Entities are generational handles** (Invariant I1), and everything about an entity that
is saved or referenced across a boundary uses handles and content IDs, never pointers.

**Deferred:** the storage strategy itself. The first implementation should be the simplest
thing that works — a sparse set with dense per-component arrays — behind an interface that
allows a later upgrade to archetype-based storage without touching gameplay code. Query and
iteration APIs must not leak the storage layout.

Also deferred: system scheduling, parallel iteration, hierarchy/parenting, and change
detection. None of these are owed anything now beyond not being designed out.

## Consequences

* Mods can add genuinely new component types, not merely fill in fields on engine-defined
  ones. This is the difference between a moddable engine and a configurable one.
* Serialization function pointers in `ComponentTypeInfo` mean saving and loading works
  uniformly for engine, game and mod components — no special cases.
* Cost: type-erased storage is slower than a `comptime`-specialized layout, and loses some
  compile-time checking at the storage layer. The `comptime` wrapper recovers the ergonomics
  and most of the type safety for native code.
* Cost: component IDs become part of the compatibility surface. Renaming one breaks saves and
  mods, so component names are a compatibility decision, not a style decision.

## Alternatives considered

* **`comptime`-only component registration** — faster, fully type-checked, idiomatic Zig.
  Rejected: it makes mod-defined components impossible, violating rule 12.
* **Fixed component set with a generic "custom data" bag for mods** — a common compromise.
  Rejected: mod content becomes second-class, with worse performance and worse ergonomics
  than first-party content, which contradicts Invariant I3.
* **Archetype storage from the start** — better iteration performance. Rejected as premature
  (rule 7); the interface keeps the door open.

## Revisit if

Profiling shows type erasure is a real bottleneck, or the sparse-set implementation proves
inadequate at the entity counts an actual game needs.
