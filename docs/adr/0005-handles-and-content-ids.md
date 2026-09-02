# ADR-0005: Generational handles internally, stable namespaced string IDs for content

**Status:** Accepted
**Date:** 2026-09-02

## Context

How objects are identified determines what is possible later. Raw pointers make hot reload,
serialization, defragmentation and cross-boundary references either unsafe or impossible.
Identity that depends on load order makes mod overrides and save compatibility fragile.

Bethesda's Creation Engine encodes the load-order index into the top byte of every FormID.
The result is well documented: mods break when load order changes, merging plugins is a
specialist activity, and an entire ecosystem of tooling exists purely to work around it.
This is the specific failure Foundry is designing against.

## Decision

Two identity systems, used at different levels.

**Runtime identity: generational handles.** Everything addressable — entity, component,
asset, texture, buffer — is referred to by a `{ index: u32, generation: u32 }` handle.
Lookup validates the generation; a stale handle fails cleanly rather than reading freed
memory. Raw pointers may exist inside a subsystem, but they never cross a subsystem boundary,
are never stored long-term, and are never serialized. (Invariant I1.)

**Content identity: stable namespaced strings.** Content is identified as `namespace:name`,
e.g. `foundry:item.torch`. The namespace is the owning package. The string is hashed to a
stable numeric ID and resolved to a runtime handle at load. Content IDs are **never** derived
from load order, array position, or file offset. (Invariant I2.)

Saves and content files store **content IDs**, never handles. Handles are runtime-only.

## Consequences

* Mod overrides work by ID, so load order changes what wins without changing what anything
  is called.
* Saves survive content being added, removed or reordered. An unresolvable ID is a
  recoverable, reportable condition rather than corruption.
* Hot reload becomes tractable: swap what a handle points at and every holder follows.
* Object storage can move or defragment freely.
* Cost: a lookup indirection on every dereference. Mitigated by resolving IDs to handles once
  at load and by iterating storage directly in hot loops rather than chasing handles.
* Cost: string IDs cost memory and hashing time at load, and hash collisions must be detected
  at content build time rather than discovered at runtime.

## Alternatives considered

* **Raw pointers** — fastest and simplest. Rejected: incompatible with hot reload,
  serialization and the mod boundary.
* **Plain integer indices** — cheap, but a freed-and-reused slot silently becomes a different
  object. The generation counter is the cheap fix.
* **Load-order-indexed IDs (Creation Engine)** — compact and fast. Rejected explicitly; see
  Context.
* **GUIDs for content** — globally unique with no coordination, but unreadable in files, in
  diffs, and in error messages, which is hostile to mod authors.

## Revisit if

Handle indirection shows up as a genuine cost in profiling, or the content ID scheme proves
insufficient for a case like procedurally generated or runtime-created content.
