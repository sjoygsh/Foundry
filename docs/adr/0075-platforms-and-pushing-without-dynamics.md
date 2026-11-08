# ADR-0075: Moving platforms carry by recorded motion, and pushing is bounded, without dynamics

**Status:** Accepted 2026-11-09, when the owner requested M37 Step 1
**Date:** 2026-11-09
**Informed by:** ADR-0013, ADR-0051, `docs/design/collision3d.md`, `docs/design/collision-extras.md`

## Context

ADR-0051 gave `physics3d` collision, queries and a character controller, and no dynamics. It named
two revisits that M37 is now the milestone for: moving platforms that carry a character, and
characters that push. A game needs a lift, a turntable, a crate to shove, and a door that does not
pass through the player. None of these needs mass or momentum, and `physics3d` has no time: a game
says where a body goes, and the world answers what is there.

## Decision

**A kinematic body moved by `World.moveBody(handle, pose)` records the motion.** It keeps its last
motion, the difference between its old pose and its new one, and a serial that counts its moves.
`setPose` stays a teleport and records nothing.

**A character standing on a body that has moved since the character last moved is carried first.**
- Its feet go through the body's motion: the rotation's part about the world's up, about the body's
  old origin, then the translation.
- The carry is swept, ignoring the carrier, so a rider carried into a wall slides.
- Then the requested displacement is moved. The move reports `carried` and `carried_yaw`.

**A body moved into a character pushes it.** Each overlapped character, in handle order, is moved
by the body's motion at its centre through the ordinary controller. One that still overlaps is
reported as `crushed`. The body's move stands, and what follows is the game's.

**Pushing is a ratio, one level deep.**
- A body's `push` and a character's `push` are a ratio in [0, 1], 0 by default.
- A character's slide that meets a pushable body or character first pushes it. The push is the
  remaining horizontal displacement along the contact, times the ratio: a body by a shape cast and
  `moveBody`, and a character by its own controller.
- A pushed thing pushes nothing further. Pushes happen in slide order within a move, and in the
  game's order across characters.

**The order a game runs:** kinematic bodies first, then characters.

## Consequences

- A lift, a turntable, a crate and a shove are built from queries that already exist. Determinism
  is ADR-0051's: handle order, fixed iteration counts, no time.
- **No momentum:** a crate stops the tick its pusher stops, and a chain of crates is a wall after
  the first. A game wanting more waits for M51.
- **A tilting platform does not tilt its rider's capsule:** only the turn about up is carried.
- The controller's move does more work on a tick it carries or pushes, against M23's 0.25 ms budget.
- `crushed` is a report, not a rule, so two games may decide differently what a lift does then.

## Alternatives considered

- **Velocity on bodies.** It needs a `dt` `physics3d` does not have (ADR-0051), and a game already
  knows the pose it moved a body to.
- **A solver now** (Jolt, or Foundry's own). Out of proportion to a lift and a crate, and M51's
  decision.
- **Chains of pushes.** Ordering and mass across a chain is a solver's work, and one level is what a
  crate and a shove need.
- **Carrying by parenting the character to the platform in `scene`.** `physics3d` would not know
  the rider moved, a wall would not stop it, and `scene` is above `physics3d`.

## Revisit if

- A game needs pushes that carry momentum, or stacks it pushes as a whole. That is M51 and M52's.
- A game's rider must tilt with its platform, such as a ship's deck at sea.
- The controller's move is measured over its budget on a tick that carries or pushes.
