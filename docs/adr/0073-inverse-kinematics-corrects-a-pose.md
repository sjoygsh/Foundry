# ADR-0073: Inverse kinematics corrects a pose from targets the game finds

**Status:** Proposed 2026-11-07
**Date:** 2026-11-07
**Informed by:** ADR-0013, ADR-0048, ADR-0051, ADR-0057, ADR-0058, ADR-0071, ADR-0072,
`docs/design/animation-ik.md`

## Context

Until now a figure's pose was its clips' pose. On the sandbox's steps and ramp, the climber's feet
sink into each step and float over the slope. A figure cannot look at anything a clip did not
author. M36 must add foot placement and look-at, and finish two rows M34 left it: a body blocked
from following its clip, and feet that slide when a rate is matched to a speed.

Several things pull on the shape:
- Foot placement needs to know the ground, and the ground is `physics3d`'s. `anim` is L1 on
  `core` alone, and the layering (I7) gives it no way to ask.
- ADR-0071 says a pose is never state: a save holds a figure's playback, not its joints.
- Correcting a foot smoothly needs memory between ticks: an offset that eases onto a step, and a
  planted foot's world position.
- A replay must still reproduce every pose (I9).

## Decision

**IK is a correction of an evaluated pose, in `anim`.**
- `anim.ik` has two closed-form solvers on a pose, `twoBone` and `aim`, with targets in model
  space.
- `anim.Feet` and `anim.Aim` use them to place legs on ground and turn a chain toward a point.
- Nothing here allocates, reads a clock or sees a world.

**The game finds the targets.**
- `Feet.probes` says where to look, as rays in world space.
- The game casts them with its own queries, and hands back what it found.
- So `anim` stays on `core`, and a mod's figure will be placed on what its host's world answers,
  through queries already public.

**IK is presentation.** It never moves a body, never fires an event and never enters a save.

**Its memory is a value the game holds:**
- `Feet` and `Aim`, a few dozen bytes a figure;
- stepped once a tick with the tick's `dt`, beside the stack;
- so a replay from tick zero reproduces every pose, and a loaded world's feet settle within their
  smoothing.

**What a skeleton's legs and aim chains are is content.** `foundry:animation_set` version 3 lists
them by joint name. A leg's contacts are read from each looping clip's foot heights when a rig is
built, not authored.

## Consequences

- Feet meet steps and ramps, and planted feet stay planted, with no change to a body or a save.
- On flat ground at the figure's height, a pose is the clip's bit for bit. So a figure gains feet
  without moving a pin.
- A blocked body is a game's parameter and a machine's choice, with locked feet beneath it.
- **The cost:** a game runs a fixed order a tick (evaluate, probe, cast, place, aim, skin), and
  each sample writes it. `scene` cannot do it for an entity, since it has no physics.
- **The cost:** a world loaded mid-step shows its feet settling for about 0.2 s. A save that held
  `Feet` would avoid it, at the price of saving a correction of a pose.
- **The cost:** derived contacts are only as good as a clip's heights. A clip that shuffles a foot
  low has a contact a person would not mark, until M111 lets one mark them.

## Alternatives considered

- **IK in `scene`, with `physics3d` granted to it.** It would let `animation.advance` place feet
  itself. Rejected: `scene` would gain a sideways dependency on collision, and a figure with no
  physics world, such as a pawn in a test, would be wrong.
- **IK in a new L3 module over `anim` and `physics3d`.** A clean home for the casts. Rejected: the
  casts are three lines in each game, and the module would exist to hide them while fixing one
  query's shape for every game.
- **`Feet` and `Aim` saved in `foundry:animator`.** A load would be seamless. Rejected:
  ADR-0071's rule that a pose is not state would bend for a correction that settles in 0.2 s, and
  a schema version would be spent on it.
- **An iterative solver (FABRIK or CCD) for everything.** One solver for any chain. Rejected:
  every chain in M36 is two bones or a short aim, which closed forms solve exactly and cheaply, and
  iteration's tolerance would make a pose's last bits depend on a count. Chains longer than two
  bones are M54's.
- **Contacts authored in the set.** Exact where a person cares. Rejected for now: these clips are
  generated and their heights say it. Marking them by hand is M111's.

## Revisit if

- A game needs a figure's corrected pose to be the same immediately after a load, for example a
  replicated pose (M128). That would put `Feet` in a save.
- A shipped clip's derived contacts are wrong often enough that a person corrects them, before
  M111.
- §16 of the design finds feet and aim over the per-figure budget on the i3.
