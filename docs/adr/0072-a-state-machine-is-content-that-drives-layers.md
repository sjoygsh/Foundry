# ADR-0072: A state machine is content that drives layers of players

**Status:** Accepted 2026-11-06, when the owner requested M35 Step 1
**Date:** 2026-11-06
**Informed by:** ADR-0010, ADR-0013, ADR-0041, ADR-0058, ADR-0070, ADR-0071,
`docs/design/animation-states.md`

## Context

ADR-0071 made playback a value, `anim.Player`, and left the choice of what to play to code. Two
figures now carry that choice in code: the sandbox's pacer times its sides and turns its corners,
and the court's warden picks idle or stride and sets the rate its feet need. M35 must add state
machines, layers, masks and additive poses, and the warden needs all of them: legs that walk and
run, arms that reach while the legs run, and a breath added on top.

Three things pull on the shape. I5 puts game specifics in data, and what a figure does when it is
close to a player is about as specific as animation gets. A machine's place must save with a
world, as ADR-0071's player does, within additive schema versioning. And a model's clips are
shared by figures that behave differently: the pacer and the climber are one model.

## Decision

**A state machine is a content record, `foundry:animation_machine`,** of layers, states,
transitions and up to eight named `f32` parameters. It names clips and masks by name. **The figure
names its machine,** in `foundry:animator` or a game's own record, and the set does not, so two
figures of one model may behave differently and one machine may serve any set with those names.

**`anim` runs it on validated values.** `asset.Rigs` builds an `anim.Machine` against a rig and
refuses by name, and the machine reads no clock and allocates nothing, so a simulation needs no
renderer. A game sets parameters before a tick. Each layer takes at most one transition a tick,
the any-state ones first, in listed order.

**Layers are players.** `anim.Stack` is up to three layers, each an `anim.Player` with a weight
and a mode, override or additive. A mask is per-joint weights, and an additive clip's reference
pose is sampled when the rig is built. Both are what a set says about a skeleton and its clips, so
`foundry:animation_set` version 2 holds them. Root motion comes from the base layer alone.

**A stack is saved whole:** each layer's channels, state and ticks in it, and the parameters, as
`foundry:animator` version 2's appended fields. A save holds no pose, as before.

## Consequences

- The pacer's and the warden's choices leave code, and a content mod changes what a figure does.
- M111's editor has a record to edit, and M48 a machine to publish by content ID.
- A version 1 save loads: its channels are the base layer, and a layer with no state adopts its
  newest clip's.
- **The cost:** a save grows by about 450 bytes an animator, for layers a figure may not use.
- **The cost:** three layers and eight parameters are a saved shape. More is a schema version.
- **The cost:** a machine is checked in two places, as a set is: `fpack` for what one record shows,
  and the rig build for what depends on a model a mod may override.
- A behaviour that needs more than a threshold on a parameter is still the game's: it computes a
  parameter. There are no triggers or expressions.

## Alternatives considered

- **The machine inside `foundry:animation_set`.** One record. Rejected because the pacer and the
  climber share a set and behave differently, and because a mod retiming a footstep would restate
  the figure's behaviour, or the other way round.
- **Machines as code over `Player`, with `anim` providing only layers.** Least new schema. Rejected
  by I5: a mod could change a clip but never what a figure does with it, and M111 would have nothing
  to edit.
- **Parameters as game state, not saved.** Smaller saves. Rejected because a game that sets a
  parameter only when it changes would load wrong, and a save would no longer continue byte for
  byte on its own.
- **Triggers that consume themselves.** Common in other engines. Rejected because a consumed value
  is hidden state a replay has to reproduce, while a parameter set for one tick is plain input.
- **Layers as more channels in one player.** No new value. Rejected because a mask and a mode
  belong to a group of channels, and a cross-fade within a layer must not fight a layer's weight.
- **A bit mask per layer instead of per-joint weights.** Fixed size. Rejected because a waist must
  feather, and a weight slice in a borrowed rig costs nothing saved.
- **Computing an additive clip's difference from its reference on every tick.** No memory in the rig.
  Rejected because it samples a second pose per layer per tick for a value that never changes.

## Revisit if

- A sample needs a fourth layer or a ninth parameter, which is a schema version of
  `foundry:animator`.
- 32 two-layer machines pass 0.10 ms p95 on the i3, which M100's parallel systems would then answer.
- Games keep writing the same parameter logic, a debounce or a timer, often enough that a
  condition should carry it.
- M111's editor needs something a machine record cannot express, such as a nested machine.
