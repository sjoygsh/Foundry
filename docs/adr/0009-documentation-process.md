# ADR-0009: Documentation and decision process

**Status:** Accepted
**Date:** 2026-09-02

## Context

Foundry is developed across many sessions, in bounded chunks, with long gaps between them.
Context is lost between sessions. Without a deliberate mechanism, each session either
re-derives decisions already made or, worse, silently contradicts them.

The specific failure modes to prevent: a future session redesigning a finished system; a
future session violating a principle because the reason for it was never recorded; and
documentation growing into an unreadable diary that nobody reads, which is the same as having
none.

## Decision

Four documents with strictly separated jobs and different change rates:

| Document | Contains | Changes |
| --- | --- | --- |
| `CLAUDE.md` | Durable philosophy, invariants, architecture, conventions, postponed decisions | Rarely |
| `PROJECT_STATE.md` | Current phase, what works, in progress, next steps, debt, open questions | Every session |
| `docs/ROADMAP.md` | Staged milestones and their exit criteria | Occasionally |
| `docs/adr/NNNN-*.md` | Individual decisions with reasoning, alternatives and revisit conditions | Append-only |

Plus `docs/design/` for per-subsystem design documents written **before** implementing
anything non-trivial (development rule 1), and `docs/modding/` for mod-author-facing
documentation from M3 onward.

**Session protocol:** read `CLAUDE.md`, read `PROJECT_STATE.md`, inspect the actual code,
summarize understanding back to the user, then continue from the existing architecture.

**ADRs are append-only once accepted.** To change a decision, write a new ADR superseding the
old one. The reasoning behind a rejected path is as valuable as the decision itself, and
editing it away destroys that.

**Every ADR states what would cause it to be revisited.** A decision nobody can falsify is
not a decision, it is a habit.

**A milestone is not complete until `PROJECT_STATE.md` is updated.**

## Consequences

* A cold session can reconstruct the project's state and reasoning from documents alone —
  which matters, since sessions are bounded by available context rather than by calendar time.
* Separating change rates keeps `CLAUDE.md` stable enough to be trusted and read fully.
* Cost: real overhead per session, and discipline to keep `CLAUDE.md` from absorbing content
  that belongs in `PROJECT_STATE.md` or an ADR.
* Cost: ADRs accumulate, including superseded ones. Accepted; the index in `CLAUDE.md` §4.1
  lists only what is currently in force.

## Alternatives considered

* **A single running document** — one place to look. Rejected: durable principles and
  volatile status have different change rates, and mixing them means the principles are never
  reread.
* **Git history and commit messages as the record** — no extra files. Rejected: commit
  messages record *what* changed, rarely *why not the alternative*, and are impractical to
  read cold.
* **No formal process** — least overhead. Rejected: this project specifically cannot afford
  it.

## Revisit if

The documentation burden starts consuming a disproportionate share of session time, or the
four-document split proves to have unclear boundaries in practice.
