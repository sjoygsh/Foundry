# ADR-0017: Foundry is a standalone public repository; games are separate consumers

**Status:** Accepted
**Date:** 2026-09-02

## Context

Foundry is being built as an engine other people can use, not as private infrastructure for
one game. That intent has been implicit in every prior decision — the public C ABI (ADR-0004),
"the base game is content package zero" (I3), the permissive licensing policy (ADR-0016) —
but the repository itself had no home and no stated scope.

The obvious convenient thing is to develop the engine and the first game together in one
repository. It is convenient precisely because it removes friction: shared build, shared
refactors, no versioning, no release step. That convenience is the problem. Every one of
those removed frictions is a boundary the engine needs in order to be usable by anyone else.

An engine developed inside its first game acquires that game's assumptions silently. Not
through any deliberate decision, but through a hundred small ones: a constant that only makes
sense for that game, a subsystem shaped around one content type, an API that is fine because
the only caller is next door in the same tree. By the time the coupling is visible it is
structural. This is the same failure mode Invariant I5 (the engine hardcodes no game content)
and Invariant I4 (exactly one public API surface) exist to prevent — and a shared repository
is the environment in which both are easiest to violate without noticing.

## Decision

**Foundry lives in its own public repository, and is the canonical home of the engine.**

* Canonical repository: `github.com/sjoygsh/Foundry`, public, Apache-2.0 (ADR-0016).
* The repository contains the engine, its tools, its samples and its documentation.
  Nothing else.
* **Games live in their own repositories** and consume Foundry as a dependency. Their
  licensing, content, release cadence and platform choices are decided independently and are
  none of this repository's business.
* `samples/` is for the smallest thing that exercises an engine capability. A sample is not a
  game and must not grow into one. When a sample starts wanting features rather than
  demonstrating them, that is the signal it should become its own repository.

**Consuming Foundry is not a privileged act.** A game depends on Foundry the way any other
consumer does — the same modules, the same eventual public API (I4). We do not get to add a
back door for our own game any more than for the editor.

**Public from the start, not published later.** Developing in the open means the boundaries
are checkable by someone other than us, and it removes the temptation to defer cleanliness to
a hypothetical publication date that keeps moving.

What this does *not* commit us to yet: contribution infrastructure, CI, release automation,
issue templates or a governance model. Those are introduced when the project is mature enough
to need them, not as decoration. An empty `CONTRIBUTING.md` is worse than none.

## Consequences

* The engine cannot silently absorb game-specific assumptions, because there is no game in
  the tree to absorb them from.
* Foundry must be *consumable* — a real dependency with a real interface — before there is a
  game to consume it. This is a cost, paid early and deliberately.
* Versioning becomes real work at some point: a game pinned to a Foundry version, and a
  decision about how breaking changes reach it. Deferred until there is a second repository,
  but it will arrive.
* Some cross-cutting changes become two commits in two repositories instead of one. This is
  the friction being deliberately bought.
* Documentation is now load-bearing for people who are not us. `CLAUDE.md`,
  `PROJECT_STATE.md` and the ADRs are read by strangers, and should be written accordingly.
* Nothing in the repository may assume one particular machine, one developer's paths, or one
  developer's installed tools. Setup must be scripted and reproducible.

## Alternatives considered

* **Monorepo containing engine and game.** Rejected above. The convenience is real and so is
  the coupling it produces.
* **Private now, public later.** Rejected: "later" is a moving target, and the discipline of
  being visible is most valuable while the architecture is still cheap to change.
* **Engine as a subdirectory of the game, extracted once it stabilises.** Rejected — this is
  the monorepo option with an extraction task appended, and the extraction is exactly the work
  that never happens.

## Revisit if

The two-repository split proves to obstruct real development — for instance if early engine
work turns out to need a game-shaped consumer to make progress at all. The answer then is a
richer sample or a dedicated test-bed repository, **not** moving a game into this one.
