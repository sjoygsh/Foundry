# ADR-0060: Foundry is planned as 150 milestones, climbed gradually

**Status:** Accepted 2026-10-02, by the owner's instruction
**Date:** 2026-10-02
**Revised 2026-10-02 (before any milestone was built against it), by the owner's instruction:**
certified releases become the final milestone, M150. The 150 engine milestones M0–M149 are
unchanged; the plan now runs M0 to M150.
**Informed by:** ADR-0008, ADR-0013, ADR-0017, ADR-0033, ADR-0044, ADR-0047, ADR-0051, ADR-0052,
`docs/ROADMAP.md`, `docs/design/3d.md` §11

## Context

At M25's close Foundry is a moddable, networked 2D and 3D engine with an editor, and its
roadmap ended at M26, a playable 3D sample. Everything beyond that was recorded as deferred,
each item waiting for a game or a measurement to ask for it. That rule kept the engine small
while its foundations were laid, but it gave no picture of the whole: nothing said how far a
general-purpose engine comparable to Godot, Unity or Unreal actually is, or in what order the
distance would be covered.

The owner asked for that picture and decided its size.

## Decision

**Foundry is planned as 150 numbered engine milestones, M0 to M149, and one more, M150, the
certified release.** M0–M25 are complete, M26 is next, and M27–M149 are listed in
`docs/ROADMAP.md` in five phases: a complete game toolkit, dynamics and worlds, the renderer's
upper tier, tools, and reach. M150 follows Foundry 1.0.

**It is a gradual ascent, not a sprint.** The count measures distance, never speed. Every rule
that governed M0–M25 governs the rest: design before implementation, the owner's acceptance
before Step 1, one bounded step at a time with a stop between steps, a runnable result, the
full bar, and no private path around the public API.

**The list fixes intent and order, not designs.** A roadmap line is a title and one sentence.
No milestone is designed before its turn, and no ADR is written for it until then. Where a
line names a choice (a physics solver, a shading language, a second scripting language, a
decoder, Android's build tooling), that choice is made by that milestone's own ADR.

**The total is held: 150 engine milestones and M150.** A milestone that proves too large is split and the split is paid
for by a merge elsewhere. The owner may reorder or re-scope by a dated note in the roadmap.

**Scope changes this makes:**
- **Android, the web and VR/XR are planned.** CLAUDE.md listed mobile, web and VR as out of
  scope indefinitely. Consoles, iOS and x86-64 macOS remain out.
- **Direct3D 12 is planned** (M135–M136). This supersedes ADR-0033's "D3D12 not planned";
  Vulkan remains the Windows and Linux backend.
- **An opt-in replication layer is planned** (M128). ADR-0044's single authority and
  application-defined channels are unchanged; automatic replication stops being excluded and
  becomes a layer above them, decided by its own ADR.
- **A voxel module is planned** (M65–M67) as an optional module nothing else depends on.
- **One milestone changes only how Foundry looks** (M122): the editor, overlay, mod manager and
  samples get one visual language, and no function changes.
- **Certified releases are M150, the last milestone.** Developer ID signing, notarization, a
  quarantined launch on a clean recipient Mac and Windows code signing stay deferred until
  then, after Foundry 1.0 at M149. This re-dates ADR-0047's "after a fully playable 3D game";
  its rule that nothing uncertified is published as verified stands, and no membership is
  bought before M150's turn.

**What it does not change:** the nine invariants, the layering, the two rendering boundaries,
the dependency and license policy, and the rule that games live in their own repositories.

## Consequences

- A future session can see the whole plan and where the project stands in it: 26 of the 151 numbered
  milestones (M0–M150) at M25's close (M16.5 was inserted between two and is not counted).
- Deferred items now have a place in an order. Their recorded triggers stop deciding *whether*
  and keep deciding *how*: each milestone still names the sample that needs the feature and
  the budget it is measured against.
- **Cost:** some capabilities will be built before a game outside this repository asks for
  them. That weakens the protection development rule 7 gave ("avoid overengineering for
  hypothetical future requirements"). The rule stays, and applies inside each milestone: build
  what its sample needs, and defer the rest with a trigger.
- **Cost:** a long list invites treating it as a schedule. It is not one, which is why the
  roadmap carries no dates and the count is fixed instead of the pace.
- **Cost:** several milestones (real-time global illumination, virtual geometry, a second
  scripting runtime, the web) are larger than anything built so far and are the likeliest to
  need the split-and-merge rule.

## Alternatives considered

- **Keep the trigger rule and plan nothing past M26.** Rejected by the owner: it hides the
  size of the ambition CLAUDE.md §1 states, and leaves every session to rediscover it.
- **An open-ended list with no fixed total.** Rejected: a plan that can only grow is not a
  plan. A fixed count forces each addition to displace something.
- **Fewer, larger milestones (about 90).** Rejected: the large ones would not fit the
  one-step-per-session discipline that has kept every milestone resumable.

## Revisit if

- A phase ends and its sample shows the next phase is ordered wrongly for real games.
- The split-and-merge rule fails, that is, the plan cannot hold its total without dropping
  something a game needs.
- A milestone's design shows its line contradicts an invariant; the invariant wins and the
  line changes.
