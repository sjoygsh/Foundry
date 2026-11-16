# ADR-0091: Milestones return to one at a time

**Status:** Accepted 2026-11-17, by the owner's instruction
**Date:** 2026-11-17
**Supersedes:** ADR-0082
**Informed by:** ADR-0060, ADR-0082, CLAUDE.md §2 (rule 17)

## Context

ADR-0082 had milestones advance in pairs from M41: a lead and an unrelated partner, one of them
built by a second Opus agent, moving by the same stop and closing together. M41 (Environment) and
M45 (Input) were the first pair, and they walked nine steps that way.

The owner judged it not worth its cost: "instead of a days worth of tokens this consumes like 3x
tokens for 2x work". Each pair step ran two orientations, two bars and a merge. The agent
started from a stale base more than once and hit its usage limit once. And the two milestones
contended for the one Windows PC and the owner's time at it.

## Decision

**From M41's close on, one milestone is worked at a time**, as before M41. ADR-0060's "its turn"
means one milestone's turn again. A step is done by the primary session unless the owner asks for
an agent.

**M41 closes alone.** Its Step 10 is no longer a joint close: it closes M41's documents and cleans
its own state. M45's Steps 1 to 9 are done and merged, and they stand.

**M45 is parked, not closed.** It resumes at its Step 10 (Linux) after M44 closes and before M46's
design, and it then closes by its own Step 11. Until then:
- its accepted ADRs (0087–0090) and its code stand as they are;
- the next milestone is M42, then M43 and M44, as the roadmap orders them;
- M45's remaining exit items stay M45's, so nothing leaves it unowned (rule 17).

## Consequences

- A session does one step of one milestone, then stops, as `foundry-milestone-step` describes. Its
  §0 on pairs no longer applies.
- No design stop chooses a partner.
- M42–M44 are designed and built against a tree that already holds M45's `input` module and
  `FoundryApi_v8`. M48's table is therefore v9, as ADR-0090 said.

## Revisit when

The owner asks again for two milestones to move together. If so, the pair should be chosen so
that the two never need the same machine or the owner's time in the same step.
