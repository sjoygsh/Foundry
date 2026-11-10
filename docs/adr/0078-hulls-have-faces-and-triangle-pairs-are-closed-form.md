# ADR-0078: Hulls have faces and are content, and triangle pairs are closed-form

**Status:** Proposed
**Date:** 2026-11-10
**Informed by:** ADR-0013, ADR-0051, ADR-0057, ADR-0076, `docs/design/collision3d.md`, `docs/design/collision-scale.md`

## Context

A hull in `physics3d` is 4 to 256 points. It has no faces, so a hit on one reports only the
contact normal, and a character at a hull's rim is judged by its edge. A game can make a hull
only in code: no content record holds one. `collision3d.md` §15 set both aside until "a game
stands characters on hulls, or content needs hulls". M37's turntable is a hull a character
stands on.

Every pair of shapes goes through one GJK and conservative advancement, a ray included.
`collision3d.md` §5.1 chose that for one routine to test and audit, and named what would change
it: a profile showing capsule-against-triangle as the cost of a move above budget. The Mac's move
sits at 0.231 ms against 0.25, and the i3's court tick has crossed its line in three milestones.
ADR-0060 scheduled the work in M38.

GJK stops when it improves by less than 1e-7 m. A closed form is exact to rounding. So replacing
one with the other changes a character's position in its last bits, and every digest of a walk.

## Decision

**A hull has faces.** `physics3d` finds them from the points when a hull is added, and keeps each
face's plane. The points are kept as given, so no distance, cast or depth on a hull changes. A
hull's surface normal is the face the contact lies on, and the controller prefers a walkable face
at a hull's edge as it does at a box's.

**A hull is compiled content.** `foundry:collision_hull` has a `.fhul` payload of points alone.
`foundry:collision_import` version 2's `shape hull` compiles one from a glTF file, keeping the
hull's vertices and refusing more than 256.

**A ray, a sphere and a capsule meet a triangle by closed-form routines.** Point against
triangle and segment against triangle give the distance that a cast's advancement asks for, and
a ray against a triangle is answered in one step. The cast's meaning, its skin and its tolerance
do not change, and depth is still EPA's. Boxes, hulls and every pair without a triangle stay on
GJK.

**The walking pins move once.** Before any pin is changed, each routine is compared with GJK
over 100,000 configurations, and each tour is compared with its own GJK run at every tick, within
1 mm. Each pin's old value is recorded beside its new one.

## Consequences

- A character on a hull is told the face it stands on.
- Content, and so a content mod, can supply a hull.
- The pairs a walking character spends its time in cost a few dozen operations, not an
  iteration to convergence.
- There are now four narrowphase routines to keep right where there was one. GJK stays compiled
  beside the three, and is their reference in tests.
- Every digest of a walk on triangles changes, on every architecture, and the history of those
  pins restarts at M38.
- A hull's faces are derived twice, once by `author` to reduce the points and once at load.
  They cannot disagree with the points, because no file holds them.

## Alternatives considered

- **Faces stored in `.fhul`.** A file could then hold faces that are not its points' hull, and
  checking that costs what finding them does.
- **Closed forms used only to skip triangles a cast cannot reach.** No pin would move. But the
  cost is in the triangles that are reached, and the mesh tree already skips the rest.
- **A fully analytic swept capsule against a triangle.** It would replace the advancement too,
  and so the meaning of a cast's stopping place. That is a wider change than the measurement
  asks for.
- **Closed forms for every pair.** Fifteen routines, each with its own edge cases. Only the
  triangle pairs are in a character's every tick.
- **A switch a game sets, GJK or closed form.** Two answers to one query, forever, and twice the
  pins.

## Revisit if

- A profile shows a box or hull pair as the cost of a move above budget.
- A tour diverges from its GJK run by more than the band and no single branch explains it.
- Content needs a hull of more than 256 points, or several hulls as one body. The second is
  M51's.
