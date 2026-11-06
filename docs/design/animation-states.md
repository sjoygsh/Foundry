# Design: M35 — Animation logic II: state machines, layers, masks and additive poses

**Status:** Accepted 2026-11-06, when the owner asked for Step 1, with §19 as written (row 15 included:
blend spaces go to M36's row at the close). Each step's Resolution follows §19.
**Date:** 2026-11-06
**Baseline:** `1ff0360`, tag `m34`. M0–M34 are complete.
**Decisions:**
- These ADRs constrain it:
  - ADR-0071: playback is `anim.Player`, a fixed value of four channels on `core` alone, and a
    pose is never state. `foundry:animator` is that value under an engine name, saved with a
    world. What a clip means is `foundry:animation_set`, and never part of a clip's bytes. Its
    first "Revisit if" is M35's: per-channel state that four nested channels cannot hold within
    additive versioning. §8 shows it does not fire.
  - ADR-0058: `anim` is L1 on `core` alone, and nothing in it allocates.
  - ADR-0010 and `derive`: a component's schema grows by appending fields, and a record or save
    written against an older version keeps its defaults for the new ones (I8).
  - ADR-0041: engine record types live in `asset`, so `fpack` checks them without linking their
    consumer.
  - ADR-0070: a value the game owns says what it wants, and the game moves the body.
  - ADR-0025: the overlay prints the subsystem's own answers.
  - ADR-0013: deterministic-friendly, not bit-exact.
- It proposes one ADR:
  - [ADR-0072](../adr/0072-a-state-machine-is-content-that-drives-layers.md): a state machine is
    a content record, `foundry:animation_machine`, separate from the set and named by the figure
    that plays it. It drives up to three layers, each an `anim.Player`. Its inputs are a few
    named parameters a game sets, and they are saved with its place in each layer. Masks and
    additive clips are what a set says about a skeleton and its clips. All of it runs in `anim`
    on validated values, so a simulation needs no renderer.

## 1. Purpose and boundary

The roadmap's row (`docs/ROADMAP.md`, Phase 6) is the contract:

> M35 | Animation logic II | State machines, layers, masks and additive poses; also clips of
> different lengths kept in step, a clip played backward, and a ladder's climb fitted to its height
> (M34)

**The runnable result.** In the court, the warden's legs are no longer one clip run at four times
its rate. It walks on patrol and runs in a chase, on clips of different lengths that cross-fade
without a stumble. When it closes on the player, its arms reach forward while its legs keep
running, and after a chase its chest heaves on top of whatever it is doing. None of that is code
in the court: a machine record decides it from parameters the game sets. In `sandbox3d`, the pacer
walks its square on a machine instead of code. Its head looks about on an additive layer. A save
in mid-turn carries on from the same state, and the content mod `pacer_back` makes it walk every
other side backward with no code. The climber's ladder climb is fitted to the ladder's height.

**The exit condition.** A machine chooses a figure's clips from parameters alone, on three layers
with masks and an additive pose, and a saved world continues byte for byte across a transition.
Clips of different lengths stay in step through a fade, a clip plays backward with its events and
travel reversed, and a climb is fitted to its height. Every refusal is proved, and a person has
watched and played it.

**In M35:**
- a clip played backward, clips kept in step by a sync group, and a seek fitted over several laps,
  all in `anim.Player`;
- `anim.Stack`: up to three layers, each a `Player`, with masks and additive poses;
- `anim.Machine`: states, transitions and parameters, stepping a `Stack`;
- `foundry:animation_set` version 2, with masks, additive clips, sync groups and a climb's rise,
  and the new record `foundry:animation_machine`;
- `foundry:animator` version 2, saving a machine's place, its parameters and its layers;
- the animation panel showing layers, states and parameters;
- four new clips, the pacer and the warden moved onto machines, and the climber fitted.

**Not in M35.** Each has its owner in §18:
- foot placement and look-at by inverse kinematics, which are M36's;
- blending many clips continuously by a parameter (a blend space), which §19 proposes for M36;
- editing a machine as a graph, which is M111's;
- anything in the public table, which is M48's, and in Lua, which is M49's.

## 2. What exists

Read from the code at `1ff0360`:
- **`engine/src/anim/player.zig`** holds `Player`: four `extern` channels, each a clip's name
  hash, an `f64` anchor, a tick count, a speed in `[0, 16]` and a weight. `play` takes a fade and a
  `Phase`, `.restart` or `.keep`, where `.keep` copies the newest clip's **seconds**. That is right
  only for clips of one length, and every clip so far is one second long. `advance`, `seek`,
  `evaluate` and `finished` are there. `seek` puts the newest channel at a fraction of one lap and
  fires what it crosses forward. Every value is untrusted and `repair`ed, never asserted.
- **A negative speed is refused** in `play`, `setSpeed` and `saneChannel`, because `fire`'s span
  `[before, after)` and `motion.travel` both run one way. `fold` clamps a one-shot only at its end.
- **`pose.zig`** has `sample`, `sampleJoint` and `blend`, a whole-pose mix. There is no per-joint
  weight and no additive pose.
- **`rig.zig`'s `RigClip`** has a name, a clip, `loop`, `speed`, `motion`, events and a label. A
  `Rig` is borrowed and validated once. `asset.Rigs` builds it from `foundry:animation_set` v1
  (`engine/src/asset/animation_set.zig`, `rigs.zig`), and rebuilds it at `contentChanged`, keeping
  handles.
- **`scene/animation.zig`** declares `foundry:animator`: a set's ID and the player's fields laid
  over `anim.Player` exactly (`c0` to `c3`, `fade`, `newest`, `dt`), with a comptime layout check.
  `derive` takes nested structs and no arrays, and a record or save of an older schema version
  leaves the newer fields at their defaults (`derive.zig`, the test "content written against an
  older schema version leaves the newer field alone"). A save holds no pose.
- **The pacer's logic is code** (`samples/sandbox3d/pacer.zig`): it plays `stride` for
  `strides × duration` seconds as authored, cuts to `turn`, and fades back across a finished turn.
  `sandbox3d:pacer.main` holds `strides 1.5`. Its save is 3,675 bytes, and it pins
  `47f67027ff3a12b0` and `ef5c24337f5f2925`.
- **The warden's logic is code** (`samples/court/warden.zig`, `finishTick`): idle or `stride`,
  chosen by whether it moved, with `stride`'s rate set to its speed over `motion_speed`, clamped to
  16. It reaches 4.0 at 2.4 m/s. A link's clip is played and `seek`ed by `link_t`, then seeked to 1
  on the tick it lands. The warden is a plain value, not an entity, and holds a `Player` directly.
- **The climber** (`samples/sandbox3d/crowd.zig`) crosses the sandbox's 0.6 m ladder with one lap of
  `climb`. The ladder is one-way, and the climber goes up it.
- **`anim.Report`** has rows of channels, with no layer or state.
- **The characters** share one 19-joint skeleton from `scripts/m24/make_character.py`, with
  `pelvis`, `spine`, `chest`, `neck` and `head` up the middle. `scripts/m34/clips.py` appends
  `stride`, `turn`, `jump`, `drop` and `climb` after `idle` and `walk`, all one second long.

## 3. A clip played backward (`anim.Player`)

**A channel's speed may be negative,** from −16 to 16. Time is still `anchor + ticks × dt × rate`
in `f64`, and the anchor may now be negative too, so a looping clip played backward from 0 simply
unfolds below zero and `fold` wraps it.

- **`play` with a negative speed and `.restart` begins a one-shot at its end,** not its start, so
  `turn` played backward begins turned and unturns. A loop begins at 0 either way.
- **`fold` holds a one-shot at both ends,** so a backward one-shot sits on its first frame once it
  arrives. **`finished`** is true for a backward one-shot at or before 0.
- **Events fire on `(after, before]` when time runs backward,** the mirror of `[before, after)`, so
  one tick's end is still exactly the next one's start and nothing fires twice. A backward one-shot
  fires its event at 0 on the tick it arrives, as a forward one fires its event at 1.
- **Root motion reverses.** `travel(from, to)` with `to < from` is the inverse of
  `travel(to, from)`: the yaw negated, and the translation turned back by it and negated, so a
  stride played backward walks back along the path it walked forward. A pin compares the two.
- **`setSpeed` across zero re-anchors as before,** so changing direction never moves the pose.

`seek` keeps its rule: it fires what it crosses forward and nothing backward, because a seek is a
position and not playing.

**The cost:** `saneChannel` accepts what it refused, so a save or raw write with a negative speed
now plays instead of being emptied. That is a widening of what loads, not a narrowing, and no
saved value changes meaning.

## 4. Clips kept in step: sync groups (`anim.Player`)

**A clip may belong to a sync group,** named by `foundry:animation_set` (§9) and carried by
`RigClip.sync`, a name hash, zero for none. Within one player, channels whose clips share a group
are kept at the same **fraction** of their clips:

- **`.keep` copies a fraction, not seconds, when both clips share a group.** `walk` at 0.25 of its
  1.0 s fades into `run` at 0.25 of its 0.7 s, so the same foot is down. With no group, `.keep`
  copies seconds, as M34 does, so nothing that exists changes.
- **During a fade, the newest channel leads.** Each tick, after times move, every other channel in
  its group is re-anchored to the leader's fraction of the lap, with its ticks at zero. A
  follower's own speed is ignored while it follows.
- **A follower's travel is still its own,** measured from its re-anchored time before to after, so
  a walk fading into a run speeds up smoothly instead of jumping.
- **Events stay the newest channel's,** as M34 has it. A group is only sound when its clips mean
  the same thing at the same fraction, a foot down at 0 and 0.5. That is the author's to keep, and
  the panel shows each channel's fraction so a person can see it.

A group is a clip's property and not a channel's, so nothing about it is saved.

## 5. A seek fitted over several laps (`anim.Player`)

**`seekLaps(rig, fraction, laps, dt, step)` puts the newest channel `laps × fraction` laps into its
clip,** and `seek` is `seekLaps` with one lap. It fires what it crosses forward on every lap, so a
climb can carry a rung event, and travel is reported as `seek`'s is.

**How many laps is the clip's meaning and the link's size.** A set gives a climbing clip its
`rise`, in metres a lap (§9), and `Rig.lapsFor(name, height)` is `max(1, round(height ÷ rise))`,
or 1 for a clip with no rise. `anim` sees no link. The climber computes the ladder's height from
the link's two ends, asks for the laps, and seeks. Its 0.6 m ladder and a `rise` of 0.3 m give two
laps, and a test fits 0.3 m to 6 m.

## 6. Layers, masks and additive poses (`anim.Stack`)

**`anim.Stack` is up to three layers, each a `Player`.** Layer 0 is the base, and the others are
mixed over it in order. Each layer beyond the base has a **weight**, moved toward a target at a
rate, and a **mode**:
- **override:** the layer's pose replaces the base's, joint by joint, by `mask[joint] × weight`;
- **additive:** the layer's pose, already a difference from a reference (below), is added onto the
  pose beneath, scaled by `mask[joint] × weight`.

```zig
pub const max_layers = 3;

pub const Layer = extern struct {
    player: Player,
    weight: f32,      // 0 to 1; the base's is always 1
    target: f32,      // where `weight` is going
    state: u64,       // §7: the machine's state, by name hash; zero is none yet
    state_ticks: u64, // §7: ticks in that state
};

pub const Stack = extern struct {
    layers: [max_layers]Layer,
    params: [max_params]Param,   // §7
};
```

**Three, because the court needs three:** a body, an upper-body override and an additive breath.
More is a schema version of `foundry:animator`, as a fifth channel is.

**A mask is a weight for every joint,** from 0 to 1, built when a rig is built from a set's list
of joints and weights (§9). Each entry applies to the joint and its subtree, in list order, so a
later entry overrides an earlier one, and `spine 0.5` then `chest 1` feathers the waist. A layer
with no mask covers every joint at 1. A mask is a `[]const f32` in `anim.Rig`, borrowed like
everything there.

**An additive clip is a difference from a reference pose.** The reference is a pose of the clip's
own first frame, or of another clip's first frame when the set names one. `Rigs` samples it once
when the rig is built and the rig borrows it, so no tick samples a reference. A layer samples the
clip and takes, per joint, the rotation `q_ref⁻¹ · q`, the translation `t − t_ref` and the scale
`s ÷ s_ref`. It blends its channels' differences as poses, and applies them to the pose beneath
as `q_below · slerp(identity, q_diff, w)`, `t_below + w · t_diff` and
`s_below · lerp(1, s_diff, w)`. A joint no track touches is at rest in both, so its difference is
the identity. That is why an additive clip that moves only the chest moves only the chest.

**What a layer may play is checked when a rig is built:**
- an additive layer plays only additive clips, and an override layer only clips that are not;
- **root motion comes from the base layer alone,** so a clip with `motion` is refused on any other
  layer. A body has one path;
- **events come from every layer whose weight is above zero,** from its newest channel, in layer
  order and by time within a layer. That order is a contract, and `Step` still holds 16.

`Stack.evaluate(rig, machine, scratch, out)` takes two scratch poses a caller lends, for a layer's
pose and its channels' blend. A stack with one layer and no machine evaluates exactly as its
`Player` does, which a test holds bit for bit.

## 7. `anim.Machine`: states, transitions and parameters

**A machine is a validated description, and a stack is its place.** `anim.Machine` is borrowed,
like a rig, and `Rigs` builds it from a record (§10). `Stack` holds what changes: each layer's state
and ticks in it, and the parameters. A machine reads no clock and allocates nothing.

**Parameters are a game's inputs:** up to eight named `f32`s per machine, named by hash as clips
are. A game sets them before a tick with `stack.set(machine, name, value)`, which refuses an
unknown name or a value that is not finite. A boolean is 0 or 1, and a kind is a small integer.
There are no triggers: a game that wants one sets a parameter for one tick. **Parameters are saved
with the stack,** each as its name hash and value, so a game that sets one only when it changes
still loads exactly. A saved parameter the machine no longer has is dropped and counted.

**A layer of a machine has states and transitions:**
- **a state** names a clip, a speed, and how its rate is found. `speed_param` makes the rate the
  parameter's value divided by the clip's `motion_speed`, clamped to ±16, so the feet match a body
  moved by other means. That is the warden's rule today, moved into content. A negative value plays
  backward (§3). `seek_param` makes the state seek its clip to the parameter's fraction instead of
  running it, as a link's crossing does;
- **a transition** goes from a state, or from any state, to another. It has a fade, a phase
  (`restart` or `keep`, §4) and up to four conditions, all of which must hold;
- **a condition** compares one quantity with a constant by `at_least`, `below` or `is`. The
  quantity is a parameter, `laps` (whole laps of the state's clip as authored since it was entered,
  as the pacer times a side), or `finished` (the state's one-shot is at its end, as 0 or 1);
- **a layer beyond the base** has `weight_param`, the parameter its target weight follows, clamped
  to `[0, 1]`, and `weight_fade`, the seconds it takes to get there.

**One tick of a machine,** for each layer in order:
1. If the layer has a `weight_param`, set its target, and move its weight toward it.
2. Take the first `from "*"` transition, in listed order, whose conditions all hold and which
   does not lead to the state it is in. Then, only if none did, the first whose `from` is the
   current state and whose conditions all hold. Take at most one a tick. `"*"` goes first because
   it is how an interruption, a jump or a hit, is written. Taking one plays its state's clip
   with its fade and phase, and zeroes `state_ticks`.
3. Set the rate from `speed_param`, if the state has one.
4. `seekLaps` by `seek_param` if the state has one, otherwise `advance`.

The order is the contract, and one transition a tick keeps it from ringing. A transition can fire
during a fade, which is what four channels are for.

**A state of zero means not yet entered.** On its first tick a layer adopts the state whose clip
is its newest channel's, if one does, and otherwise enters the layer's `entry` state with a cut.
So a version 1 save, which has channels and no state, carries on without a pop (§8).

**Everything a stack holds is untrusted,** as a player's is: a state the machine does not have is
re-entered from `entry` and counted, and a state's tick count past any condition is harmless.
Nothing asserts.

**What a machine may say is checked once, when it is built against a rig,** and refused by name:
`UnknownClip`, `UnknownState`, `UnknownParam`, `UnknownMask`, `DuplicateState`, `DuplicateParam`,
`NoEntry`, `TooManyLayers`, `TooManyStates`, `TooManyTransitions`, `TooManyConditions`,
`TooManyParams`, `MotionOffBase`, `AdditiveMismatch`, `NoMotionSpeed` (a `speed_param` on a clip
with none), `InvalidFade` and `InvalidSpeed`. Limits: 3 layers, 32 states and 64 transitions a
layer, 4 conditions a transition, 8 parameters.

**Why a machine is content and not code.** I5 puts specifics in data, and a machine is the most
game-specific thing animation has: which clip, when, how fast. As code, a mod could retime a
footstep but never change what a figure does when it is close. As a record, `pacer_back` changes
the pacer with no code, and M111's editor will have a record to edit.

## 8. `foundry:animator` version 2 (`scene`)

**The component grows by appending fields,** so a version 1 record or save loads with the new ones
at their defaults, which is a stack with only a base layer and no machine:

| Field | Type | Saved | Note |
| --- | --- | --- | --- |
| `set` … `dt` | as v1 | yes | The base layer's player, unchanged in place |
| `s0`, `t0` | u64, u64 | yes | The base layer's state and ticks in it |
| `l1`, `l2` | nested `Layer` | yes | A layer's channels, fade, newest, dt, weight, target, state, ticks |
| `p0` … `p7` | nested `{ name u64, value f32 }` | yes | The parameters |
| `machine` | id | yes | The `foundry:animation_machine` this plays; none for a plain player |

`machine` comes last so the fields from `c0` onward lie over `anim.Stack` as one span, and the
layout check grows to hold it. Authoring names the set and, optionally, the machine.

**This does not fire ADR-0071's revisit.** Per-layer state is three more nested structs, within
additive versioning, and the base layer keeps v1's offsets. A save grows by about 450 bytes an
animator, and a test records the number.

**`RigSource` gains a machine lookup,** `(set, machine) → ?*const anim.Machine`, so `scene` still
names no `asset`. `animation.advance` steps an animator's stack through its machine if it has one,
and its player alone if not, in entity order as before. `animation.stack(world, entity)` returns
the `*anim.Stack`, for `set`. `animation.player` returns the base layer's player, so a game that
plays by hand keeps doing so.

**The deserializer refuses** a stack that is not sane: a weight or target outside `[0, 1]`, a
value that is not finite, or a parameter whose name is zero but whose value is not. `advance`
repairs what a raw write left, as M34's does.

## 9. `foundry:animation_set` version 2

Version 2 appends fields, so every v1 set means what it meant:

```fdt
foundry:animation_set court:warden.set {
    model court:models.warden
    start "idle"
    motion_joint "pelvis"
    masks [
        { name "upper" joints [ { joint "spine" weight 0.5 } { joint "chest" weight 1 } ] }
    ]
    clips [
        { name "stride" motion true sync "feet" events [ … ] }
        { name "run" motion true sync "feet" events [ … ] }
        { name "pant" additive true }
        { name "reach" }
    ]
}
```

| Field | Type | Rule |
| --- | --- | --- |
| `masks` | list, optional, at most 8 | Per-joint weights, by name |
| `masks[].name` | string | Once per set |
| `masks[].joints` | list, 1 to 32 | Applied in order, each to a joint and its subtree |
| `masks[].joints[].joint` | string | A joint of the skeleton |
| `masks[].joints[].weight` | f32, default 1 | 0 to 1 |
| `clips[].sync` | string, optional | A group name; clips sharing it are kept in step (§4) |
| `clips[].additive` | bool, default false | Played as a difference from its reference (§6). Not with `motion` |
| `clips[].reference` | string, optional | The clip whose first frame is the reference. Default: its own |
| `clips[].rise` | f32, optional | Metres one lap climbs, above 0, for `lapsFor` (§5) |

`fpack` checks what one record shows: duplicate masks, weights in range, `additive` with `motion`,
a `rise` not above 0. Whether a joint exists, or a reference clip is a clip of the model, is the
rig's, when it is built, since a mod may override the model. New refusals: `UnknownJoint` and
`DuplicateMask` join v1's, plus `AdditiveWithMotion`, `UnknownReference` and `InvalidRise`.

## 10. `foundry:animation_machine` (`asset`)

**A new engine record, separate from the set.** A set says what a model's clips are, and a machine
says what a figure does with them. Two figures of one model may behave differently, as the pacer
and the climber do, and a machine names clips by name, so one machine serves any set whose clips
share those names. So the figure names its machine (§8, and the warden's record), and the set does
not.

```fdt
foundry:animation_machine court:warden.machine {
    params [ { name "speed" } { name "link" } { name "link_t" } { name "near" } { name "winded" } ]
    layers [
        { name "body" entry "idle"
          states [
            { name "idle" clip "idle" }
            { name "walk" clip "stride" speed_param "speed" }
            { name "run" clip "run" speed_param "speed" }
            { name "jump" clip "jump" seek_param "link_t" }
          ]
          transitions [
            { from "*" to "jump" fade 0.1 when [ { param "link" is 1 } ] }
            { from "jump" to "idle" fade 0.2 when [ { param "link" is 0 } ] }
            { from "idle" to "walk" fade 0.25 phase "keep" when [ { param "speed" at_least 0.05 } ] }
            { from "walk" to "run" fade 0.3 phase "keep" when [ { param "speed" at_least 1.8 } ] }
            { from "run" to "walk" fade 0.3 phase "keep" when [ { param "speed" below 1.6 } ] }
            { from "walk" to "idle" fade 0.25 when [ { param "speed" below 0.05 } ] }
          ]
        }
        { name "arms" mask "upper" weight_param "near" weight_fade 0.3 entry "reach"
          states [ { name "reach" clip "reach" } ] }
        { name "breath" mode "additive" weight_param "winded" weight_fade 1.5 entry "pant"
          states [ { name "pant" clip "pant" } ] }
    ]
}
```

| Field | Type | Rule |
| --- | --- | --- |
| `params` | list, at most 8 | `name`, a string, once each, and `default`, an f32, 0 unless given |
| `layers` | list, 1 to 3 | The first is the base |
| `layers[].name` | string | For a person and the panel |
| `layers[].mode` | `"override"` or `"additive"`, default override | The base is override |
| `layers[].mask` | string, optional | A mask of the set. Not on the base |
| `layers[].weight_param`, `weight_fade` | string, f32 | Not on the base. Without a param, the weight is 1 |
| `layers[].entry` | string | A state of the layer |
| `layers[].states` | list, 1 to 32 | `name`, `clip`, `speed` (default 1, ±16), `speed_param` or `seek_param`, not both |
| `layers[].transitions` | list, at most 64 | `from` (a state or `"*"`), `to`, `fade` (default 0), `phase` (default restart), `when` |
| `when` | list, at most 4 | `param` or `laps` or `finished`, then `at_least`, `below` or `is`, with an f32 |

**`fpack` checks one record:** names unique, every `from`, `to`, `entry` and `param` resolved within
it, the limits, the modes, a base with no mask or weight. **A rig checks the rest** when
`Rigs.machine(set, machine_id)` builds it: clips, masks, additive and motion rules, `motion_speed`.
`Rigs` rebuilds machines at `contentChanged` with their rigs and keeps their handles. A machine that
no longer builds answers null, and its figures fall back to their base player and are counted, as
a rig's do.

**The name.** `foundry:animation_machine`, beside `foundry:animation_set`, because both are about
animation and a mod author looks for them together. A machine of something else would be its own
record.

## 11. The panel (`anim`, `debug`)

**`anim.Report` gains layers.** A row becomes a figure, and under it up to three layers, each with
its name, mode, weight, state's name and channels. A row also lists the parameters and their
values, and a report counts transitions taken, states re-entered and parameters dropped. The rig
and machine keep their labels so the panel prints names, never hashes. `Report.addStack` fills it,
and `Report.add` stays for a bare player.

The panel has no write path, as before. Watching a parameter cross a threshold and the state change
on that tick is what it is for.

## 12. The characters

**A new generator, `scripts/m35/clips.py`, appends four clips** to the walker and the warden after
M34's seven, so every existing clip, mesh and skeleton keeps its bytes, which Step 7 compares:

| Clip | Length | What it is |
| --- | --- | --- |
| `run` | 0.7 s, loop | A run with the pelvis travelling 1.3 m a lap (1.86 m/s), a foot down at 0 and 0.5 |
| `reach` | 1.0 s, loop | Arms forward and grasping, chest leaning; only the upper body has tracks |
| `pant` | 1.2 s, loop | Additive: the chest and shoulders heave from `idle`'s chest |
| `look` | 4.0 s, loop | Additive: the head turns left, back, right and back |

`stride` gains `sync "feet"` and `run` joins it, so walk and run cross-fade on the same foot.
`climb` gains `rise 0.3`. `pant`'s reference is its own first frame, which is `idle`'s chest, and
`look`'s is the head at rest.

## 13. `sandbox3d`

- **The pacer plays a machine,** `sandbox3d:pacer.machine`, which says what `pacer.zig` says today:
  `stride` until `laps at_least 1.5`, a cut to `turn`, and a fade of 0.1 back across a `finished`
  turn. `sandbox3d:pacer.main` loses `strides`, since the machine holds it, and `pacer.zig` keeps
  only the body: root motion through the controller. **Its two pins hold**, which proves the
  machine does what the code did, tick for tick. If one moves, the Step's Resolution says why
  before it is accepted.
- **Its head looks about** on an additive layer of `look`, weight 1, so a save holds two layers.
- **A save in mid-turn** joins the tour beside the save in mid-stride, and a fresh world must
  continue byte for byte across the turn's end and the fade that follows. A third save loads a
  version 1 file of M34's pacer, kept in testdata, and must carry on with no pop.
- **`pacer_back`, a content mod in testdata,** overrides `sandbox3d:pacer.machine` so that every
  other side is walked with `stride` at speed −1, the figure walking backward with its travel
  reversed. It changes the path with no code, and a pin holds it.
- **The climber fits its climb** by `lapsFor`: two laps of `climb` on the 0.6 m ladder. It stays on
  code, not a machine, because a machine with a fitted seek has no second user, and the court has
  no ladder.
- **`FOUNDRY_SANDBOX3D_ANIMATORS=32`** now builds 32 of the pacer's animators with its machine and
  both layers, so §16's cost is of a machine.

## 14. The court

- **The warden plays `court:warden.machine`** (§10) through an `anim.Stack` it holds directly. It
  is still not an entity, and the court still saves nothing.
- **The game sets five parameters a tick:** `speed`, its ground speed in metres a second; `link`,
  the kind of link it is crossing plus one, or 0; `link_t`, how far across, 1 on the tick it lands;
  `near`, 1 when chasing within the record's `reach_distance` of the player; and `winded`, 1 while
  chasing. `finishTick`'s choice of clip, rate and seek goes.
- **Walk and run,** in one sync group, cross-fade at 1.8 and 1.6 m/s, so it walks on patrol at
  1.0 m/s on `stride` at 1.7 and runs in a chase at 2.4 m/s on `run` at 1.3, instead of `stride` at
  4.0. Its footfalls come from whichever clip leads, so the chase still sounds like a chase.
- **The body stays on the crowd's wish,** so no route moves, and `win`, `caught` and `fell` keep
  every tick. That is a digest compared against the code before the step, as in M34.
- **The arms reach** on the `upper` mask when `near`, while the legs keep running, and **the chest
  heaves** additively while `winded`, fading over 1.5 s after a chase ends.

## 15. Platform assessment, and the public ABI

**Nothing enters the public table.** M48 publishes animation, and its line gains machines,
parameters and layers at the close. The API is drawn for a table regardless: values, a machine by
content ID, parameters by name, named refusals, no callbacks but `RigSource`.

- **Metal:** the first run of everything.
- **Windows/Vulkan on the PC is needed,** once, at Step 10: the pins on x86_64, the costs on the i3,
  and both samples relocated under validation. No backend, shader or RHI path changes. The PC holds
  no Foundry clone, so it clones again under the usual rules: idle checked, `-j2`, below normal, a
  scheduled task for windowed runs, and only Foundry's own paths deleted after.
- **Linux: compile only.** Nothing here is Linux-specific (`3d.md` §10.2).

## 16. Verification, pins and budgets

**`anim`:**
- backward: a one-shot from its end, `fold` held at 0, `finished` at 0, the mirrored event span at
  a boundary and across a loop, reversed travel equal to the forward path's inverse within 1e-5,
  and a re-anchor across zero;
- sync: `.keep` by fraction within a group and by seconds without, followers locked during a fade,
  a follower's travel its own, and M34's tests unchanged;
- `seekLaps`: events on every lap, `lapsFor` from 0.3 m to 6 m, a clip with no rise;
- layers: an override at a mask's weights, a feathered mask, an additive difference that is the
  identity on untouched joints, an additive layer at weight 0 and 1, events from two layers in
  order, motion from the base alone, and **a one-layer stack equal to its player bit for bit**;
- the machine: every refusal by name, listed order, `"*"` before the state's own, one transition a
  tick, a transition mid-fade, `laps` and `finished`, `speed_param` matching `motion_speed`,
  `seek_param`, a layer's weight fading, an unknown parameter refused by `set`, a lost state
  re-entered and counted, and a state of zero adopting the newest clip;
- the stack replay: 1,200 ticks of a three-layer machine twice in one process, bytes equal, and a
  pin per binary family;
- nothing allocates, which is structural.

**`asset`:** both records round-trip; every refusal in §9 and §10; a v1 set compiles to the rig it
did; an override of a machine by a later package; a reload that keeps machine handles; a reload
that breaks a machine.

**`scene`:** every v2 field survives a save and a load; a v1 save loads and continues; the layout
check over the whole span; the deserializer's refusals; a save mid-transition that continues
byte-identical; parameters saved and a dropped one counted.

**`debug`:** layers, states and parameters printed, and a bare player still printed as before.

**The samples:** existing clip, mesh and skeleton bytes unchanged; the pacer's pins held by its
machine; `pacer_back` pinned; the walker's `655e865f98779129` and the player's `cb99ccfcf2b6d6c3`
unmoved; the court's `win`, `caught`, `fell` and soundtrack runs on every tick; the nav pins
unmoved.

**Guards verified by mutation,** each named in its step's Resolution: the mirrored span, the
reversed travel, fraction phase in a group, the leader's lock, the mask's subtree, the additive
identity, motion off the base, listed transition order, one transition a tick, the state-zero
adoption and the layout check.

**Budgets, measured inside the paced 60 Hz frame loop at ReleaseSafe, on the Mac and the PC:**

| What | Budget (p95) |
| --- | --- |
| `animation`: one figure's advance, evaluate and skin matrices, now three layers (M24's zone) | 0.10 ms |
| `render.skin`, one figure (M24's zone) | 0.25 ms |
| `animation.animators`: 32 animators, each a two-layer machine, no pose | 0.10 ms |
| The court's whole game tick (its `character` line) | 0.25 ms |

M34 read 0.027 ms for 32 bare players on the i3, so a machine has room. If the 32 pass 0.10 ms,
that is ADR-0071's second revisit, and M100's.

**By hand:** a person watches the pacer cross both saves and `pacer_back`, and plays the court,
watching the warden walk, run, reach and pant. That is the exit condition's last clause, and Step 9
hands the owner a build.

## 17. Implementation order — eleven bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

### Step 1 — `anim`: backward, in step, and fitted

§3, §4 and §5 in `Player` and `Rig`: negative speed, the mirrored span, reversed travel, sync groups,
`seekLaps` and `lapsFor`, with §16's tests for them. **Exit:** a stride played backward retraces its
forward path within 1e-5, a walk fades into a clip of another length on the same fraction, and
every M34 test and pin is unchanged.

### Step 2 — `anim`: layers, masks and additive poses

§6: `Stack` without a machine, masks, the additive difference and its application, events by
layer, motion from the base, and two scratch poses. **Exit:** a one-layer stack equals its player
bit for bit, and an additive chest moves only the chest.

### Step 3 — `anim`: the machine

§7: `Machine`, its validation, parameters, conditions, transitions, the tick order, state zero, and
the stack replay. **Exit:** a hand-built machine runs a three-layer figure from parameters alone,
every refusal is named, and its replay is byte-identical.

### Step 4 — `asset`: the set's version 2 and `foundry:animation_machine`

§9 and §10: both schemas, `fpack`'s checks, references sampled when a rig is built, masks, and
`Rigs.machine` with its reload. **Exit:** a machine compiled from text builds against a rig with no
renderer, every refusal is named, and a v1 set builds the rig it did.

### Step 5 — `scene`: `foundry:animator` version 2

§8: the fields, the layout check, `RigSource`'s machine lookup, `advance` through a machine, `stack`,
and the deserializer. **Exit:** a world saved mid-transition continues byte-identical, and a v1 save
loads and carries on, in `scene`'s hermetic tests.

### Step 6 — `debug`: layers in the panel

§11: `Report.addStack` and the panel. **Exit:** layers, states and parameters print by name, a bare
player prints as it did, and `debug` has no write path.

### Step 7 — The clips

§12: `scripts/m35/clips.py`, both generators, `sync`, `rise`, `additive`, the `upper` mask in both
sets. **Exit:** every existing clip, mesh and skeleton byte is unchanged, and the four new clips build
rigs in both samples.

### Step 8 — `sandbox3d`: the pacer on a machine

§13: the machine, the look layer, the mid-turn and v1 saves, `pacer_back`, the climber's fitted climb
and the 32 animators. **Exit:** from a relocated ReleaseSafe install on Metal, the pacer's pins hold,
the tour passes across all three saves, and `pacer_back` changes the path with no code.

### Step 9 — The court: the warden on a machine

§14: the machine, the five parameters, walk and run, the reach and the breath. The owner gets a
build, and the exit condition's last clause is theirs. **Exit:** `win`, `caught`, `fell` and the soundtrack keep every
tick, and the owner has played it.

### Step 10 — Windows/Vulkan

The native suites, the pins on x86_64, both samples relocated under validation, and the i3's costs.
**Exit:** every suite and run passes on the PC, and §16's budgets are read there.

### Step 11 — Close M35

This step resolves:
- `animation-logic.md` §15's rows for state machines, sync groups, a clip played backward and the
  ladder, and `animation3d.md` §14's row, by dated notes pointing here;
- ADR-0071's first "Revisit if", with a dated note that §8 kept within additive versioning;
- CLAUDE.md §4.1's new row, and §4.3's `anim` and `asset` lines for `Stack`, `Machine` and
  `foundry:animation_machine`;
- `docs/modding/content-mods.md` §10, which gains masks, additive clips, sync groups, `rise` and the
  machine;
- the roadmap's M35 line, M48's (machines, parameters and layers), and M36's if §19's row 15 is
  accepted;
- AGENTS.md's bar if it changed, the design index, the README and `PROJECT_STATE.md`.

Tag `m35`, push when asked, and stop before M36's design. **Exit:** every document names M35
complete, and none names a contract the code does not have.

## 18. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| Foot placement and look-at | M36 | `look` is a clip here; M36 aims a head at a point |
| A blend space: many clips mixed continuously by one or two parameters | M36, if §19's row 15 is accepted | Sync groups are its foundation; nothing in the samples blends more than a cross-fade |
| Editing a machine as a graph, and previewing a state | M111 | `.fdt` is the authoring path until then |
| Machines, parameters and layers in the public table, and in Lua | M48, M49 | §15 |
| A mirrored clip (a left turn played as a right one) | M111 | Mirroring needs a joint pairing a person maps, which is an authoring view's job |
| More than three layers, or eight parameters | A schema version of `foundry:animator` | Raised by the milestone whose sample needs it, as a fifth channel would be |
| Advancing machines on `core.Jobs` | M100 | Measured against §16's 32-animator budget |
| A ragdoll taking over from a layer | M54 | |

## 19. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | A channel's speed may be negative, from −16 to 16. A backward one-shot starts at its end, events fire on `(after, before]`, and travel reverses exactly | §3 |
| 2 | A sync group is a clip's property in the set. `.keep` copies a fraction within a group and seconds without, and the newest channel leads during a fade | §4 |
| 3 | `seekLaps` fits a clip over laps, and `Rig.lapsFor` divides a height by the clip's `rise`. `anim` sees no link | §5 |
| 4 | `anim.Stack` is three layers, each a `Player`: override or additive, with a per-joint mask from the set, and a weight that follows a parameter | §6 |
| 5 | An additive clip is a difference from a reference pose sampled once when the rig is built | §6 |
| 6 | Root motion comes from the base layer alone. Events come from every weighted layer, in layer order | §6 |
| 7 | A machine is a validated description in `anim`. Its inputs are up to eight named `f32` parameters, and there are no triggers | §7 |
| 8 | One tick takes at most one transition a layer: `"*"` in listed order first, then the state's own | §7 |
| 9 | A state of zero adopts the newest clip's state, so a v1 save carries on | §7, §8 |
| 10 | `foundry:animator` v2 appends layers, states, parameters and `machine`, and parameters are saved. ADR-0071's revisit does not fire | §8 |
| 11 | `foundry:animation_set` v2 appends masks, `sync`, `additive`, `reference` and `rise` | §9 |
| 12 | `foundry:animation_machine` is its own record, named by the figure and not the set (ADR-0072) | §10 |
| 13 | The pacer and the warden move onto machines. The pacer's pins must hold, and the court's digests must | §13, §14 |
| 14 | Four new clips, appended so every existing byte holds: `run`, `reach`, `pant`, `look` | §12 |
| 15 | **A blend space is not in M35's row and is not built. This design proposes adding it to M36's row**, beside foot placement, which also weighs poses by a parameter. If you'd rather it go elsewhere, name the milestone | §18 |
| 16 | A mirrored clip goes to M111, with the joint pairing a person maps | §18 |
| 17 | Nothing enters the public table. M48's line gains machines, parameters and layers at the close | §15 |
| 18 | The PC is needed once, at Step 10. Linux is compile only | §15 |
| 19 | Budgets: M24's two, 32 two-layer machines at 0.10 ms, and the court's tick at 0.25 ms | §16 |
| 20 | The owner's watch and play is the exit condition's last clause, at Step 9 | §16 |

Once these are accepted, nothing blocks Step 1.

## Resolution — Step 1: backward, in step, and fitted (2026-11-06)

`anim.Player` and `anim.Rig` now cover §3, §4 and §5. New tests are in
`engine/src/anim/direction_tests.zig`.

**Backward (§3).**
- `validSpeed` takes −16 to 16, and `saneChannel` accepts any finite anchor.
- `.restart` with a negative speed puts a one-shot at its end. `fold` clamps a one-shot at both
  ends, and `finished` reads the channel's sign.
- `fire` hands a span running backward to `fireBackward`, which fires `(to, from]`, latest first.
  A loop starts from the lap `from` is in, so an event exactly on `from` fires. A one-shot's 0
  fires on arrival, as its 1 does going forward.
- `motion.travel` with `to < from` is `undo(forward(to, from))`: the translation turned back by the
  yaw and reversed, and the yaw reversed. The walk and the curving `ring` both retrace 150 forward
  ticks within 1e-5 on every tick back.
- Two M34 tests changed with the contract. `setSpeed(-1)` is now valid, so the refusal is tested at
  −17. The untrusted list's `speed -1` and `anchor -1` became `-17` and `-inf`.
- `scene`'s refusal of a bad save tested `anchor = -1`, which is now a loop played backward, so it
  is now refused at infinity. The deserializer itself did not change.

**In step (§4).**
- `RigClip.sync` is a group's name hash. `.keep` copies the newest clip's fraction within a group
  (`keptFor`), and its seconds outside one, so nothing M34 made changes.
- `follow` runs at the top of `finish`, after times move and before events and travel. Each
  follower moves as many laps as the leader did, plus the difference to the leader's fraction,
  taken the short way round. So its travel is its own, and a follower that ran ahead steps back
  rather than lapping.
- **This sharpens the design: a rig refuses a group on a one-shot** (`SyncOnOneShot`). A fraction
  needs a lap, and there was no consumer for a synced one-shot.

**Fitted (§5).**
- **This also sharpens the design: `seekLaps(n)` treats n laps as one lap n times as long.** It
  stays in the long lap it is in, so at n = 1 it is M34's `seek` exactly, and a test compares their
  bytes. `seek` is now `seekLaps(…, 1, …)`. A one-shot has one lap, and a count of 0 is 1.
- A seek's backward rule now covers the newest channel's followers too: a backward seek neither
  fires nor travels.
- `RigClip.rise` is metres a lap, with 0 for none and a NaN, infinity or negative refused
  (`InvalidRise`).
- `Rig.lapsFor` rounds |height| ÷ rise, from 1 to `max_fitted_laps` (256). A loop with no rise, a
  one-shot, an unknown clip or a height that is not finite all answer 1.

**Guards verified by mutation.** Each of these was broken once, and each broken version failed a
test:
- the mirrored span's `<=` (the loop's count at 0.25 s ticks);
- the undo's turn sign (the retrace);
- the fraction phase (two sync tests);
- the leader's lock (two);
- the short way round, `@round` against `@floor` (two);
- the seek's backward-travel skip (M34's backward-seek test).

**Not yet:** layers, masks, additive poses and the machine, which are Steps 2 and 3. Nothing in
`asset`, `scene` or the samples changed, and no record names `sync` or `rise` until Step 4.

**Bar:** 2,747/2,757 (ten skips), 131/131 steps. `anim-test` is 87/87, 16 of them new.

## Resolution — Step 2: layers, masks and additive poses (2026-11-06)

`anim.Stack` now covers §6, without a machine. It is in `engine/src/anim/stack.zig`, with tests in
`stack_tests.zig`.

**The values.**
- `Layer` is `extern`: a `Player`, a `weight`, a `target`, and the `state` and `state_ticks` that
  Step 3 fills. `Stack` is three of them.
- **Parameters are not in `Stack` yet.** They are Step 3's, and they are appended there, so the
  layout §8 lays over grows once.

**This sharpens the design: a layer's mode, mask and fade are a `Spec`, never held in the stack.**
- What a layer is belongs to its machine. What a stack holds is only what changes and is saved.
- `validateSpecs` refuses `NoLayers`, `TooManyLayers`, `AdditiveBase`, `MaskOnBase`, `UnknownMask`
  and `InvalidFade`. Step 3's machine produces specs that have passed it.

**The rig.**
- `RigClip` gains `additive` and `reference`. `Rig` gains `masks` (`Mask`: a name hash, one weight
  a joint and a label) and `mask(name)`.
- `validate` adds `AdditiveWithMotion`, `InvalidReference`, `AdditiveStart`, `TooManyMasks`,
  `UnnamedMask`, `DuplicateMask` and `InvalidMask`.
  - `InvalidReference` covers a reference of the wrong length, a non-finite or non-unit joint, a
    missing reference, and a reference on a clip that is not additive.
  - `AdditiveStart` exists because a new player begins its start clip on the base.
- `fillMask(skeleton, entries, out)` is how Step 4's `Rigs` will build a mask from a set's entries.
  It refuses `UnknownJoint`, `InvalidMaskWeight` and `TooManyMaskEntries`.

**The pose.**
- `pose.difference` turns a sampled pose into `q_ref⁻¹·q`, `t − t_ref` and `s ÷ s_ref`. A reference
  scale of 0 on an axis gives 1.
- `blendMasked` and `addMasked` mix by `mask[joint] × weight`.
- `Player.evaluate` takes the difference of an additive clip after sampling it, so its channels
  blend as differences. A rig with no additive clip evaluates exactly as before.

**A tick.**
- `Stack.advance` repairs each layer in its spec. A layer above the base moves its weight toward
  its target by `dt ÷ fade`, or at once with no fade. The base is held at weight 1, whatever a raw
  write left. Then it empties and counts any clip its layer cannot play: an additive clip on an
  override layer or the reverse, motion above the base, or above the base a clip that is gone or
  insane.
- **That last point sharpens the design.** A layer above the base is emptied by the stack, not by
  its player. The player's own repair would begin the rig's start clip, which is the base's, so an
  emptied upper layer would refill every tick. An empty layer is skipped.
- Events go into one `Step`: the base's, then each layer with weight above zero, by layer. Motion
  is the base's alone. `Step.emit` is now public for this.
- `Stack.evaluate(rig, specs, scratch[2], out)` evaluates the base with `scratch[1]`. Each layer
  with weight and a channel to show (`Player.hasWeight`) is evaluated into `scratch[0]` and mixed.
- `Stack.play` refuses `UnknownLayer`, `ModeMismatch` and `MotionOffBase`, changing nothing.
  `setTarget` clamps to [0, 1], a NaN is 0, and the base's target is ignored.

**The exit.**
- Over 600 ticks of a fade, an interrupted fade and a backward cut, a stack of its base alone
  matches a `Player` in its bytes, events and motion each tick. Its pose under three specs, with
  the upper layers empty, is the player's bit for bit.
- An additive `pant` on the walk leaves every joint but the chest byte-identical, and lifts the
  chest by its 0.1 m difference within 1e-5.

**Guards verified by mutation:**
- the mask's subtree (`fillMask`'s test);
- the additive difference (three tests);
- the motion-above-base refusal (the raw-write test);
- silence at weight 0 (the events test);
- the base held at 1, and an additive mask. Both survived their first mutation, so the tests "the
  base always fires" and "a mask keeps a difference off the joints it leaves out" were added, and
  each then failed under its mutation.

**Not yet:** the machine, parameters and conditions, which are Step 3. Nothing in `asset`, `scene`
or the samples changed.

**Bar:** 2,762/2,772 (ten skips), 131/131 steps. `anim-test` is 102/102, 15 of them new.
