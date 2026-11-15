# ADR-0082: Milestones advance in pairs, the next one and an unrelated partner

**Status:** Accepted 2026-11-15, by the owner's instruction
**Date:** 2026-11-15
**Amends:** ADR-0060's "No milestone is designed before its turn"
**Informed by:** ADR-0060, CLAUDE.md §2 (rules 1 and 17), `AGENTS.md` §6

## Context

Through M40, one milestone was worked at a time: its design was accepted, then each step was
built and stopped on, one per request. That holds the owner's review between steps, but it
leaves most of the work serial, even when two milestones have nothing in common. For example,
an environment renderer and an input system share no module.

The owner asked for two such milestones to move together, one by the primary session and one
by a second Opus agent, with the same stops as before.

## Decision

**From M41 on, milestones advance in pairs.** Each pair is the next milestone in roadmap order,
the *lead*, and one *partner*: a later milestone from an unrelated field. The two are worked
at the same time. ADR-0060's "its turn" now means the pair's turn, so a partner is designed
with its lead and not ahead of it.

**Choosing the partner is part of the work before Step 1.** It is the first act of the lead's
design stop, and the lead's design records it. The partner is the earliest later milestone
that meets all of these conditions:
- it lies in a different field;
- by its roadmap line, it neither needs the lead's work nor is needed by it;
- it changes no engine module the lead changes, apart from shared documents;
- it does not need the Windows PC at the same step as the lead, or it can wait for the PC.

A partner may not skip past a milestone it depends on.

**Every stop moves both milestones.** One request ("Begin") advances both milestones by the
same stop:
- both designs and their ADRs;
- then both Step 1s, then both Step 2s, and so on.

Each step is complete on its own terms: its own bar, Resolution and commit. The report comes
once, after both are done. One of the two is always done by a spawned Opus agent in its own
git worktree and branch. The primary session merges that branch into `main` before reporting
and does not re-verify the agent's step, whose own bar is its evidence.

**The pair shares one last step.** Instead of two separate closes, a joint close:
- closes both milestones' documents;
- cleans up both milestones' scratch, worktrees and PC state;
- runs one compile check of the merged tree.

If one milestone has fewer steps, it waits at its last step for the joint close.

**A dependency found mid-pair drops the partner.** If a step shows that the two milestones
need each other's work, the partner stops for the rest of the lead. Its committed steps
stand. It resumes, or is redesigned, after the lead closes. The design records the drop in a
dated note.

**What does not change:** design before implementation, the owner's acceptance before Step 1,
the stops, rule 17 for each milestone separately, the full bar on every step, the fixed
total and the roadmap's order of leads.

## Consequences

- Roughly twice the work per request, where the two fields are truly separate.
- **Cost:** `PROJECT_STATE.md` carries two lines of work, and its head says where each one
  stands.
- **Cost:** `main` takes a merge each stop. A conflict in shared documents is resolved by the
  primary session.
- **Cost:** a partner is designed against code the lead is about to change. Its "What exists"
  section must say so. Choosing an unrelated partner is the safeguard, and the drop rule is
  the fallback.
- **Cost:** the Windows PC and the Mac's cores are shared. Only one milestone uses the PC at a
  time.
- **Cost:** the agent's step is not re-verified. The joint close's compile check is the one
  check over the merged tree.

## Alternatives considered

- **One milestone at a time (ADR-0060 as written).** The owner rejected it for speed.
- **Two consecutive milestones.** Rejected: consecutive milestones are usually in one field
  (M41 Environment, then M42 Tone and exposure) and depend on each other.
- **A partner chosen ahead for the whole roadmap.** Rejected: whether two milestones are
  related is only clear from the code when the pair's turn comes.

## Revisit if

- Two pairs in a row drop their partner. That would mean the selection rule does not find
  unrelated work.
- Merges of the agent's branch break `main` despite its own bar.
- The owner's review between steps suffers from reading two steps at once.
