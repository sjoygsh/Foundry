# Architecture Decision Records

A record of decisions that constrain future work, are expensive to reverse, or would look
arbitrary to a future session.

## Rules

* One decision per file, named `NNNN-short-title.md`, numbered sequentially and never reused.
* **Append-only once code depends on it.** Before any implementation exists against a
  decision, it may be revised in place with a dated revision note at the top. After code
  depends on it, changing it means writing a new ADR that supersedes the old one, and marking
  the old one `Superseded by NNNN`.

  The line is drawn at "code depends on it" rather than at "accepted" because a trail of
  superseded ADRs from a single planning session is archaeology, not history. Once something
  is built, the old reasoning becomes genuinely valuable and must be preserved.
* Every ADR states what would cause us to revisit it.
* The index of accepted ADRs is the table in `CLAUDE.md` §4.1. Keep it in sync.

Do not write an ADR for routine implementation choices. Do write one when a future developer
would reasonably ask "why on earth is it like this?"

## Statuses

`Proposed` · `Accepted` · `Superseded by NNNN` · `Deprecated`

An ADR may also be `Accepted (constraint only)` — the decision is binding on how something
will be built, but the implementation is deferred.

## Template

```markdown
# ADR-NNNN: Title

**Status:** Proposed
**Date:** YYYY-MM-DD

## Context
What situation forces a decision. Constraints, requirements, what we know and don't.

## Decision
What we are doing, stated plainly.

## Consequences
What this makes easy, what it makes hard, and what it costs. Be honest about the costs.

## Alternatives considered
Each with why it was not chosen. A rejected alternative with no stated reason is not
considered.

## Revisit if
The specific conditions that would make us reopen this.
```
