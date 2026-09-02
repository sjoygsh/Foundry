# ADR-0006: Engine as a library, content as data, two representations

**Status:** Accepted (model decided; authoring syntax deferred to M3)
**Date:** 2026-09-02

## Context

How a game is defined determines how deeply it can be modded. Three models were considered:
a code-first library, a fully data-first generic runtime, and a hybrid.

The developer chose the hybrid, with an explicit caveat: data-first must not degenerate into
"everything is JSON," and content must be separable from engine implementation.

That caveat is correct. JSON has no comments, ambiguous numeric semantics (notably integers
above 2^53), no schema, no good binary story, and non-trivial parse cost at load. It is a
poor authoring format for humans and a poor runtime format for machines.

## Decision

**Foundry is a library.** A game is a program that links it. Game-specific systems may be
written in Zig.

**Content and configuration are data**, loaded at runtime: entities, items, maps, rule
tables, text, and tuning values. The engine hardcodes no game content (Invariant I5).

**Schemas are canonical, not syntax.** A schema is a named record type with typed fields,
owned by whoever defines it — engine, game or mod. Content is instances of schemas. Schemas
are versioned (Invariant I8).

**Two representations:**

| | Authoring | Runtime |
| --- | --- | --- |
| Form | Text | Compiled binary |
| Audience | Humans and mod authors | The engine |
| Requirements | Comments, unambiguous typed scalars, stable diffs, imports/includes, hand-writable, machine-generatable, good error messages | Fast load, ideally mappable, versioned, validated at build time |

Shipped builds read only the runtime format. Development builds may read the authoring
format directly, for hot reload. `tools/fpack` compiles one to the other.

**Binary payloads are never embedded in content text.** Textures, meshes and audio are
assets, referenced by ID and stored in their own formats.

**Load order and overrides.** Content arrives as an ordered list of packages. The base game
is package zero (Invariant I3). Later packages override earlier ones by content ID. Merge
semantics — replace, patch-fields, append-to-list — are designed now and implemented
incrementally, starting with replace.

**Deferred to M3:** the specific authoring syntax. Candidates include adopting an existing
format or writing a small purpose-built one. JSON is disqualified for both representations
and permitted only for tool interchange.

## Consequences

* Tier 1 content modding works early, which is where most mod value actually lives.
* Content iterates without recompiling the engine.
* Because first-party content uses the same path as mods, the mod path cannot silently rot.
* Cost: a content compiler and a schema system are real work that a code-first engine avoids
  entirely.
* Cost: two representations means two code paths that must agree, and a build step between
  editing content and seeing it.
* Cost: errors in content must produce good diagnostics — a mod author cannot debug a crash.

## Alternatives considered

* **Code-first library** — simplest and fastest to build. Rejected: deep content modding
  becomes near-impossible to retrofit, and mods would be limited to native plugins.
* **Fully data-first generic runtime** (Creation Engine / Godot model) — maximum
  moddability. Rejected as premature: it forces scripting, tooling and serialization to be
  solved before the engine can render anything.
* **JSON for everything** — ubiquitous, zero parser work. Rejected on the merits above and by
  explicit developer decision.

## Revisit if

The compile step proves too slow for comfortable iteration, or the schema system turns out
to be insufficiently expressive for real game content.
