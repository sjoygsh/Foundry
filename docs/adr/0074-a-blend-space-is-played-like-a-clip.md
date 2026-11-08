# ADR-0074: A blend space is played like a clip, placed by a machine's parameters

**Status:** Accepted 2026-11-07, when the owner requested M36 Step 1; implemented in M36 (2026-11-09, tag `m36`)
**Date:** 2026-11-07
**Informed by:** ADR-0071, ADR-0072, `docs/design/animation-ik.md`

## Context

M35 cross-fades between states, and the warden walks and runs on two clips with thresholds at 1.6
and 1.8 m/s. Between them a fade is a fixed time, not a function of speed, so a warden that
lingers at 1.7 m/s plays one clip or the other, never a stride halfway to a run. M36 must add blend
spaces: many clips mixed continuously by one or two parameters, on M35's sync groups.

Several things pull on the shape:
- `foundry:animator` saves four channels a layer, and a fifth is a schema version.
- A blend mixing four clips must not take a layer's four channels, or it could never fade into
  anything.
- The parameters a blend follows are already saved with the stack.
- A mod should be able to change a blend without code.

## Decision

**A blend space is named like a clip, and a channel plays it as it plays a clip.**
- A channel's `clip` holds the blend's name hash. A rig refuses a blend that shares a name with a
  clip.
- The channel's time is in laps, and every clip in the blend is sampled at that one fraction. That
  is M35's sync rule inside one channel.
- The lap's length is the clips' lengths weighted, so the channel is re-anchored every tick.
- Its travel and motion speed are weighted, and its events are its heaviest clip's.

**Its shape is the set's.** `foundry:animation_set` version 3's `blends` lists each blend's clips
at points: one axis sorted, or two axes as a full grid, with at most four clips mixed at once.

**Its position is the machine's.** `foundry:animation_machine` version 2's `axes` binds each axis to
a parameter. So nothing new is saved: the channel holds a hash it already held, and the parameters
are already in the stack.

## Consequences

- The warden's walk and run become one state, and every speed between them is its own gait.
- A blend fades into a clip, or another blend, with M35's four channels, and a fade between two
  blends is up to eight clips sampled.
- `foundry:animator` stays at version 2, and every M35 save loads unchanged.
- **The cost:** a channel may now name a clip or a blend, so every lookup of a channel's clip asks
  both. A stale save naming a blend that a later rig lacks is a lost channel, as a stale clip is.
- **The cost:** evaluating takes a third scratch pose. Every caller of `Stack.evaluate`, and
  `scene.animation.evaluate`'s buffer, grows by one pose.
- **The cost:** a blend's position exists only through a machine. A bare `Player` plays a blend at
  its first point.

## Alternatives considered

- **A blend as a state kind, taking a layer's channels for its clips.** No new channel meaning.
  Rejected: a blend of four clips would fill a layer, and fading out of it would have no channel
  left.
- **The position saved in the channel.** A bare player could steer a blend. Rejected: a field
  inside the nested channel is not additive, so it would cost a schema version for a value the
  machine's saved parameters already determine.
- **Blends in the machine record.** One record for a figure's behaviour. Rejected: a blend is what
  a model's clips are together, like a mask or a sync group, and two figures of one model may steer
  it by different inputs. So the set holds the blend and the machine its axes.
- **Scattered points with a triangulation.** More freedom of placement. Rejected for now: a grid
  has one continuous answer with no triangulation to get wrong. Scattered points need a view a
  person can correct, which is M111's.

## Revisit if

- A blend needs more than four clips mixed at once, which a grid cannot produce but scattered
  points might.
- A game steers a blend without a machine often enough that a channel's position is worth a
  schema version.
- Re-anchoring every tick shows in the 32-animator reading.
