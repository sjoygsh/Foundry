# Design: M36 — Animation logic III: foot placement, look-at and blend spaces

**Status:** Accepted 2026-11-07, when the owner asked for Step 1, with §19 as written. Each step's
Resolution follows §19.
**Date:** 2026-11-07
**Baseline:** `f223898`, tag `m35`. M0–M35 are complete.
**Decisions:**
- These ADRs constrain it:
  - ADR-0058: `anim` is L1 on `core` alone, and nothing in it allocates.
  - ADR-0071: playback is `anim.Player`, a fixed value, and **a pose is never state**. Its
    consequence line, "a body that a controller blocks keeps walking on the spot, until M36 has a
    game do better", is answered here (§9).
  - ADR-0072: a state machine is content that drives up to three layers from eight saved
    parameters. A field cannot be added inside an existing list item of a record, so every new
    field here is a new top-level list (M35 Step 4's Resolution).
  - ADR-0051 and ADR-0057: `physics3d` answers queries on copied geometry, and `anim` cannot see it.
  - ADR-0048: right-handed, +Y up, −Z forward, metres, radians.
  - ADR-0013: deterministic-friendly, not bit-exact.
- It proposes two ADRs:
  - [ADR-0073](../adr/0073-inverse-kinematics-corrects-a-pose.md): inverse kinematics corrects
    an evaluated pose in `anim`, from targets the game finds with its own queries. It is
    presentation: it never moves a body, fires an event or enters a save. Its small smoothing
    state is a value the game holds, stepped once a tick, so a replay reproduces every pose.
    What a skeleton's legs and aim chains are is `foundry:animation_set` version 3's.
  - [ADR-0074](../adr/0074-a-blend-space-is-played-like-a-clip.md): a blend space is named like
    a clip and played by a channel like one. It mixes up to four of its loops at one lap fraction,
    by a position from the machine's parameters. It is defined in the set, and its axes are bound
    in the machine. No saved shape changes.

## 1. Purpose and boundary

The roadmap's row (`docs/ROADMAP.md`, Phase 6) is the contract:

> M36 | Animation logic III | Inverse kinematics: foot placement and look-at; also blend spaces,
> many clips mixed continuously by one or two parameters, on M35's sync groups (M35)

Two rows of `animation-logic.md` §15 also name M36, and rule 17 makes them part of it:
- "A body correcting a clip it was blocked from following";
- "Foot locking during a matched speed".

**The runnable result.**
- **In `sandbox3d`:**
  - **The climber's feet:** they land on each of the course's steps and on its ramp as it goes up
    to the platform, instead of floating over them and sinking into them. Its hips drop to let the
    lower foot reach.
  - **A new figure, the strafer,** circles a point. It faces the point for one lap and faces
    along its path for the next, on a two-parameter blend space of eight walks. So its legs step
    sideways, forward and every way between, with no pop.
  - **The pacer's head** turns toward the camera when the camera comes within three metres, and
    turns back when it leaves.
  - **The pacer is blocked:** a crate dropped on its square makes it turn at the crate, instead of
    walking on the spot into it.
- **In the court:**
  - **The warden walks and runs on one blend space,** over its speed, instead of two clips and
    two cross-fades. Its planted feet stay planted.
  - **It watches you:** its head follows the player while it can see them.

**The exit condition.**
- **Foot placement:** feet meet uneven ground within 1 cm, and they leave a pose on flat ground as
  the clip had it.
- **Look-at:** a head turns to a point within its limit, and gives up smoothly past it.
- **Blend spaces:** one and two parameters mix clips continuously, and a sweep across a blend
  space never jumps the pose.
- **A blocked body:** it does better than walking on the spot.
- **Saves and replays:** saved worlds and replays are byte for byte as before, wherever this
  milestone does not change them on purpose.
- **Refusals and a person:** every refusal is proved, and a person has watched and played it.

**In M36:**
- `anim.ik`: a two-bone solver and an aim solver, on poses, with no world;
- `anim.Feet`: legs placed on ground the game found, with contacts read from the clip, a dropped
  pelvis, aligned feet and foot locking;
- `anim.Aim`: a chain of joints turned toward a point, within a limit;
- blend spaces in one and two dimensions, played by a channel, with root motion, events and sync;
- `foundry:animation_set` version 3, with legs, aim chains and blend spaces;
- `foundry:animation_machine` version 2, which binds a blend's axes to parameters;
- the panel showing blend weights, legs and aims;
- seven new walks, the climber's feet, the strafer, the pacer's gaze and its block, and the
  warden's blend, feet and gaze.

**Not in M36.** Each has its owner in §18:
- a hand placed on a point, such as a ladder's rung or a ledge, which is M50's, with the
  third-person body;
- chains longer than two bones solved together, and full-body solving, which are M54's, with
  ragdolls;
- a blend space of scattered points, placed by a person, which is M111's;
- anything in the public table, which is M48's, and in Lua, which is M49's.

## 2. What exists

Read from the code at `f223898`:
- **`engine/src/anim/pose.zig`:**
  - `sample`, `sampleJoint`, `blend`, `blendMasked`, `addMasked`, `difference`, `modelMatrices`
    and `skinMatrices`;
  - a pose is local transforms, parents first, and model matrices are composed in one pass;
  - nothing turns a joint toward a model-space point, and nothing works back from a model-space
    target to local transforms.
- **`engine/src/anim/player.zig`:**
  - `Player`: four `extern` channels, each a clip's name hash, an `f64` anchor, ticks, a speed
    from −16 to 16 and a weight;
  - a channel names a clip of the rig and nothing else;
  - `evaluate` samples each weighted channel and blends them, and takes one scratch pose.
- **`engine/src/anim/stack.zig`:**
  - `Stack`: three players, three layers and eight `Param`s;
  - `evaluate` takes two scratch poses.
- **`engine/src/anim/machine.zig`:**
  - `State` has a `clip`, a `speed`, a `speed_param` (the rate is the parameter over the clip's
    `motion_speed`) and a `seek_param`;
  - `machine.evaluate` passes the stack and the machine's specs to `Stack.evaluate`.
- **`engine/src/anim/rig.zig`:**
  - `RigClip` has `sync`, `rise`, `additive` and `reference`, from set version 2;
  - `Rig` has clips sorted by name, `masks`, `motion_joint`, `motionSpeed` and `lapsFor`;
  - there is no list of legs or aim chains, and no blend.
- **`engine/src/asset/animation_set.zig` and `rigs.zig`:**
  - set version 2 appended `masks`, `sync`, `additive` and `rises` as top-level lists, because
    `data.Registry` compares a nested item's fields whole;
  - `fpk.List` reads nested items and has no reader for a list of strings, so a list of names is
    written `[ { clip "x" } ]`.
- **`engine/src/scene/animation.zig`:** `evaluate(world, entity, rigs, scratch, out)` asks for
  twice the joint count of scratch for an animator with a machine. `foundry:animator` is version 2,
  at 872 bytes.
- **`engine/src/physics3d/world.zig`:** `raycast(origin, direction, max_distance, filter)` answers
  a point, a smoothed `normal` and the triangle's `surface_normal`. A game's walk world holds the
  room and the course, so a game can ask what is under a foot.
- **The skeleton** (`scripts/m24/make_character.py`):
  - 19 joints, among them `pelvis`, and `hip`, `knee` and `foot` on each side;
  - at rest, the foot joint is 8 cm above the floor;
  - a leg is two bones of 0.40 m and 0.37 m, which leaves the knee room to bend.
- **The climber** (`samples/sandbox3d/crowd.zig`):
  - a `Player` on the walker's rig, moved by the crowd's wish, with no controller;
  - it climbs the course's steps and ramp to the 0.6 m platform, drops off it and climbs the
    ladder;
  - its pose is the clip's, so its feet sink into each step and float over the ramp.
- **The pacer** (`samples/sandbox3d/pacer.zig`):
  - an entity on `sandbox3d:pacer.machine`, moved by root motion through a controller;
  - when the controller stops it, it keeps striding on the spot;
  - its pins are `47f67027ff3a12b0`, and `ef5c24337f5f2925` with `pacer_quick`;
  - `pacer_back` pins `59632bcff2461113`.
- **The warden** (`samples/court/warden.zig`):
  - a plain value holding an `anim.Stack`, on `court:warden.machine`;
  - its body walks, runs and jumps by `speed`, `link` and `link_t`, and its walk and run
    cross-fade at 1.8 and 1.6 m/s in the `feet` sync group;
  - its body follows the crowd's wish, and its rate is matched to that speed by `speed_param`;
  - the court's floor is flat, and its two jump links start and end at height 0.

## 3. The two solvers (`anim.ik`)

**`anim.ik` is two functions on a pose,** with no state, no world and no allocation. Each takes
targets in **model space**, the space `modelMatrices` composes into. Each writes local transforms
back, so a corrected pose is still an ordinary `Pose` for `skinMatrices`.

**`twoBone(skeleton, pose, chain, target, pole, weight)`** reaches a three-joint chain toward a
point:
- **The chain** is a root, a middle and an end, such as a hip, a knee and a foot. The middle must
  be the end's parent, and the root the middle's parent's ancestor. The rig checks this when it is
  built (§6).
- **The angle at the middle joint comes from the law of cosines,** on the two bone lengths in
  the pose and the distance to the target.
- **The distance is held** between 1 mm and the two lengths' sum less 0.1 mm, so a target out of
  reach straightens the leg toward it. It never snaps the chain through.
- **The bend plane** is the one through the root, the target and `pole`, a model-space point. For
  a leg, the game passes the pose's own knee, pushed 0.5 m forward along the knee's bend. So the
  knee bends the way the clip bent it, and a straight leg in the clip still bends forward.
- **Then the root is turned** so the end reaches the target. Both turns are the shortest arc, as
  `Quat.fromTo` gives.
- **`weight`,** from 0 to 1, slerps each changed local rotation from the clip's toward the solved
  one. At 0 the pose is untouched bit for bit, which a test holds.

**`aim(skeleton, pose, chain, target, forward, limit, weight)`** turns a chain of up to four joints
so that `forward`, a direction in the last joint's frame, points at a model-space target:
- **Each joint takes its share** of the turn that remains, from the root down. A chain of
  `neck 0.4` and `head 0.6` turns the neck 40% of the way, then the head the rest. The shares are
  normalised to sum to 1.
- **`limit`,** in radians, bounds the whole turn. Past it, the turn is the limit, and §5's gaze
  fades out.
- **The turn is about the joint's own position,** so a head turns on its neck and does not slide.

**Why these two, and only these.**
- Every M36 use is one of them: a leg is two bones, and a gaze is a short chain aimed by a share.
- Both are closed forms, so they cost a few dozen operations a figure, take no iterations, and give
  the same bits for the same pose.
- An iterative solver, such as FABRIK or CCD, is what chains longer than two bones need. It has no
  user before M54's ragdolls.

## 4. Feet (`anim.Feet`)

**A leg** is what a set says (§6):
- its hip, knee and foot joints;
- `sole`, the foot joint's height above the ground at rest. The rig takes it from the rest pose:
  8 cm on these skeletons.
- `contact_height`, default 3 cm.
- `max_raise`, default 0.35 m, the highest a step may lift a foot. The 0.35 m is the sandbox
  controller's `step_height`, and the court's player has 0.25 m.
- `max_drop`, default 0.35 m, the lowest a foot may reach down.

A rig holds up to four legs. Two are used now, and four is a quadruped, which costs nothing to
allow.

**A contact is when the clip has the foot down,** read from the clip, not authored:
- **When it is read:** when a rig is built, for every looping clip and every leg.
- **How:** the foot joint's model-space height is sampled at 64 fractions of the clip. The foot is
  down wherever that height is within `contact_height` of the clip's lowest sample for that foot.
- **What a clip keeps:** up to four intervals a leg, as lap fractions, in `RigClip.contacts`.
- **A one-shot,** such as a jump, a drop or a turn, has no contacts, so its feet are placed, never
  locked.
- **Why derive:** these clips are generated, and a person authoring contacts by hand would mark
  what the heights already say. Marking contacts in a view is M111's.
- **At run time,** a pose's contact weight for a leg is each weighted channel's in-contact, 0 or 1,
  at that channel's fraction, times the channel's weight. A blend space's contact is its heaviest
  clip's (§7).

**`anim.Feet` is the state, held by the game and never saved:**

```zig
pub const max_legs = 4;

pub const Feet = struct {
    legs: [max_legs]LegState = @splat(.{}),
    /// How far the pelvis is lowered now, in metres, smoothed.
    pelvis: f32 = 0,
};

pub const LegState = struct {
    /// The foot's correction, in metres along model +Y, smoothed.
    offset: f32 = 0,
    /// Where a planted foot is held, in world space, and how firmly, 0 to 1.
    lock: Vec3 = .zero,
    locked: f32 = 0,
    /// Whether it was in contact on the last tick, so a new contact is seen.
    down: bool = false,
};
```

**One tick of feet,** after the stack is evaluated:
1. **`Feet.probes(rig, pose, to_world, out)`** gives, for each leg, a world-space ray: down from
   `max_raise` above the posed foot's sole to `max_drop` below it.
2. **The game casts the rays** against its own world (`physics3d`'s `raycast` in both samples).
   It fills a `Ground` a leg: a hit or none, the world point, and the triangle's `surface_normal`.
3. **`Feet.place(rig, pose, to_world, grounds, dt, &feet)`** corrects the pose, as below.

`anim` never sees the world. It sees a transform and the answers the game found.

**What `place` does:**
- **Each foot's wanted offset** is the ground's height under it, in model space, less the clip's
  floor at 0. No hit leaves the offset at 0. A hit higher than `max_raise` or lower than `max_drop`
  is ignored.
- **Each offset moves toward its wanted value** at 2 m/s, so a foot stepping onto a step does not
  pop.
- **The pelvis drops** by the most negative of the legs' offsets, smoothed the same way. It never
  rises above the clip, since a body standing on its feet is the controller's job. So the lower
  foot can still reach the ground.
- **Each leg is solved** by `twoBone`, to the posed foot plus its offset, less the pelvis's drop it
  already moved.
- **Each foot is tilted** from model +Y to the ground's normal, by at most 0.5 radians, and only by
  its contact weight. So a swinging foot keeps the clip's swing.
- **On flat ground at the figure's own height,** every offset and the pelvis are 0, and the pose is
  the clip's bit for bit. A test holds it, and the court proves it in a game.

**Foot locking, for a matched speed.**
- **What it fixes:** a body moved by other means, as the warden is by its crowd, has its rate
  matched to its speed by `speed_param`, but not its every step. A rate that lags one tick slides
  a planted foot by a few millimetres, and a turn slides it more.
- **When a lock begins:** when a leg's contact weight first rises past 0.5, `place` records the
  foot's world position as `lock`, and fades `locked` toward 1 over 0.05 s.
- **While locked,** the solver's target is `lock`, brought into model space by `to_world`'s
  inverse, mixed with the placed target by `locked`.
- **When it releases:** when the contact ends, or when the lock is more than 0.25 m from the foot
  the clip wants, `locked` fades to 0 over 0.1 s. So a foot never stretches the leg to keep its
  place. A blocked or teleported body lets go.
- **Without locking:** a figure whose root motion is its own path, such as the pacer, places its
  feet with `Options.lock = false`, because its feet already match its travel exactly.

**Why `Feet` is not saved.** A pose is not state (ADR-0071), and `Feet` is how a pose is
corrected, not where a figure has got. A world loaded from a save has its feet settle within their
smoothing, about 0.2 s, and never moves a body. But `Feet` is stepped once a tick, with the tick's
`dt`, beside the stack. So a replay from tick zero reproduces every pose, and a pin can hold one.

## 5. Look-at (`anim.Aim`)

**An aim chain** is what a set says (§6):
- its joints and their shares, from the root down;
- `forward`, the direction the last joint looks along at rest, default −Z;
- `limit`, default 1.2 radians (about 69°).

A rig holds up to four chains. Each skeleton here has one, `head`, from `neck 0.4` and
`head 0.6`.

**`anim.Aim` is the state, held by the game and never saved:**

```zig
pub const Aim = struct {
    /// The point looked at now, in world space, smoothed, and how firmly, 0 to 1.
    at: Vec3 = .zero,
    weight: f32 = 0,
};
```

**One tick of an aim:** `Aim.apply(rig, chain, pose, to_world, target, wanted, dt, &aim)`.
- **`target`** is a world point or none, and `wanted` is the weight the game asks for, from 0 to 1.
- **The point moves toward `target`** at 6 rad/s about the head, so a target that jumps sweeps the
  gaze across rather than snapping it.
- **The weight moves toward `wanted`** over 0.3 s, and toward 0 while the point is past `limit`,
  so a figure gives up on what is behind it instead of breaking its neck.
- **Then `ik.aim` turns the chain** at that weight.
- **Order:** it runs after `Feet.place`, so a gaze is from where the figure actually stands. It
  runs after every layer, so an additive `look` clip still moves the head beneath a weak gaze.

**Why a gaze is not a layer.** A layer plays a clip, and a gaze has no clip: it is a correction
toward a point the clip never knew. It cannot be content alone either, since what a figure looks
at is the game's knowledge, as `near` is.

## 6. `foundry:animation_set` version 3

**Version 3 appends three top-level lists,** each `since = 3`, because an item of an existing list
cannot gain a field (M35 Step 4). A version 2 set means what it meant.

```fdt
foundry:animation_set sandbox3d:walker.set {
    # … version 2's fields …
    legs [
        { name "left"  hip "hip.L" knee "knee.L" foot "foot.L" }
        { name "right" hip "hip.R" knee "knee.R" foot "foot.R" }
    ]
    aims [
        { name "head" joints [ { joint "neck" weight 0.4 } { joint "head" weight 0.6 } ] limit 1.2 }
    ]
    blends [
        { name "move" points [ { clip "idle" x 0 } { clip "stride" x 1.0 } { clip "run" x 1.86 } ] }
    ]
}
```

| Field | Type | Rule |
| --- | --- | --- |
| `legs` | list, at most 4 | Each a chain the rig checks: `knee`'s parent is above it toward `hip`, and `foot`'s parent is `knee` |
| `legs[].name` | string | Once per set |
| `legs[].hip`, `knee`, `foot` | string | Joints of the skeleton |
| `legs[].contact_height` | f32, default 0.03 | 0 to 0.5 |
| `legs[].max_raise`, `max_drop` | f32, default 0.35 | 0 to 2 |
| `aims` | list, at most 4 | |
| `aims[].name` | string | Once per set |
| `aims[].joints` | list, 1 to 4 | Each the previous one's descendant; `weight` above 0, the shares normalised |
| `aims[].forward` | `{ x y z }`, default `{ x 0 y 0 z -1 }` | Not zero |
| `aims[].limit` | f32, default 1.2 | Above 0, at most π |
| `blends` | list, at most 8 | §7 |
| `blends[].name` | string | Once per set, and **no clip's name**: a channel names either |
| `blends[].points` | list, 2 to 25 | `clip`, `x`, and `y` (default 0) |
| `blends[].sync` | string, optional | The blend's own sync group (§7) |

**What `fpack` checks on one record:**
- duplicate names, the limits, weights and ranges;
- a blend's points form a line or a full grid (§7);
- no two points of a blend share a place.

**What the rig checks when it is built**, since a mod may override the model:
- every joint is a joint of the skeleton, and each chain is a chain;
- every point's clip is a loop of the model that is not additive;
- a blend's name collides with no clip's.

**New refusals:** `DuplicateLeg`, `DuplicateAim`, `DuplicateBlend`, `NotAChain`, `TooManyLegs`,
`TooManyAims`, `TooManyBlends`, `InvalidLegRange`, `InvalidAimWeight`, `InvalidForward`,
`InvalidLimit`, `TooManyPoints`, `TooFewPoints`, `NotAGrid`, `DuplicatePoint`, `BlendOfOneShot`,
`BlendOfAdditive` and `BlendNameCollision`.

## 7. Blend spaces

**A blend space is a set of looping clips at points along one or two axes,** with a position
between them that picks their weights.
- **One axis:** the points are sorted by `x`, and a position between two neighbours weighs them
  linearly. A position outside the range is held at its end.
- **Two axes:** the points must form a full grid: some distinct `x`s, some distinct `y`s, and
  exactly one point at each pair. A position weighs the four corners of its cell bilinearly, held
  at the edges. A clip may stand at more than one point.
- **At most four clips are mixed at once,** whatever the blend's size, so sampling is bounded.
- **Why a grid and not triangles:** bilinear weights over a grid are continuous, need no
  triangulation, and have one answer for one position. A blend of scattered points needs a
  triangulation a person can see and correct, which is M111's view.

**A blend is played like a clip.**
- **How a channel names it:** a channel's `clip` holds the blend's name hash, which is why a blend
  may not share a name with a clip. `Rig.find` answers clips, and `Rig.blend` blends. A player asks
  for either.
- **A blend's time is in laps,** not seconds. All its clips are sampled at one fraction of their
  own lengths. That is the sync group's rule (M35 §4) applied inside one channel, so the same foot
  is down in every clip it mixes.
- **The length of its lap** is the weighted mean of its clips' lengths at the current position.
  Because that changes with the position, a channel playing a blend is re-anchored every tick at
  its current lap, with its ticks at zero, as a sync follower is. So time never jumps when the
  position moves.
- **Root motion** is each clip's travel over the tick's span of the lap, at its own length,
  weighted.
- **Events** are the heaviest clip's alone, ties to the earlier point, so a mix of a walk and a
  run steps once, not twice.
- **`motionSpeed` of a blend** is its clips' motion speeds, weighted. A state with `speed_param`
  divides by it, as it divides by a clip's. So the warden's blend over speed, with its rate from
  speed, plays at about 1 inside its range, and faster past the run's point.
- **A blend may belong to a sync group,** from `blends[].sync`. Fading from a blend into a clip,
  or into another blend, in that group keeps its fraction (M35 §4).

**Where the position comes from.** A blend's position is not a channel's: it is the machine's
parameters.
- **Version 2 of `foundry:animation_machine`** appends one top-level list:
  `axes [ { blend "move" x "speed" y "" } ]`. It says which parameter is each axis of a blend when
  this machine plays it.
- **Why the machine binds the axes:** the set says what the blend is, and the machine what it
  means to this figure. Two figures of one model may steer one blend by different inputs.
- **Before evaluating,** the machine gathers its blends' positions from its parameters into a
  `Positions` of up to eight. `Player` and `Stack` take it, and they take it in `advance` too,
  for the lap's length.
- **Played without a machine,** a blend sits at its first point's place.

**Nothing saved changes.**
- A channel holding a blend's hash is an ordinary channel, and the parameters that place it are
  already saved (M35 §8).
- `foundry:animator` stays at version 2 and 872 bytes.
- A save naming a blend that a later rig no longer has is a lost channel, emptied and counted, as
  a lost clip is.

**What it costs.**
- `Player.evaluate` needs a third scratch pose, for a blend's clips before they join the channel
  mix.
- `Stack.evaluate` and `machine.evaluate` take three scratch poses.
- `scene.animation.evaluate` asks for three times the joint count for an animator with a machine.
- A figure with no blend pays nothing on a tick: the third pose is only lent.

## 8. `foundry:animation_machine` version 2

| Field | Type | Rule |
| --- | --- | --- |
| `axes` | list, at most 8, `since 2` | One per blend this machine plays |
| `axes[].blend` | string | A blend of the set, checked when the machine is built against the rig |
| `axes[].x`, `axes[].y` | string, `y` default `""` | Parameters of this machine. `y` is required for a two-axis blend, and refused for a one-axis one |

**`fpack`** checks that each `x` and `y` names a parameter, and that no blend is bound twice.

**The rig checks the rest**, when it builds the machine:
- the blend exists;
- its axes match the blend's dimensions;
- every state whose `clip` is a blend has a binding. A blend played with no binding would sit at
  one place forever, which is a mistake, not a choice.

**New refusals:** `UnknownBlend`, `DuplicateAxes`, `AxisMismatch` and `UnboundBlend`.

**A version 1 machine** has no `axes`, so it plays no blend and means what it meant.

## 9. A blocked body

ADR-0071 left a body that a controller blocks walking on the spot. M36 does better in two places.
Each belongs where it does:
- **The game knows it was blocked,** and says so as a parameter. A figure moved by root motion
  compares the travel its controller delivered with the travel its clip asked for. The pacer sets
  `blocked` to 1 when it delivered less than half for six ticks running, and to 0 otherwise.
  What a figure does when blocked is its machine's:
  `sandbox3d:pacer.machine` gains `{ from "stride" to "turn" when [ { param "blocked" is 1 } ] }`,
  so the pacer turns at an obstacle and walks the next side.
- **The feet stop sliding:** a figure that keeps a clip while blocked, which a machine may still
  choose, keeps its planted feet planted by §4's lock. The lock lets go at 0.25 m, so the leg is
  never stretched past its reach.

**The cost: the pacer's pins move once.** A new parameter is a new saved slot, so the save's bytes
change, though no tick does:
- `47f67027ff3a12b0`, `ef5c24337f5f2925` and `pacer_back`'s `59632bcff2461113` each move;
- Step 7 proves first that nothing else moved, by comparing the old and new runs with the
  parameter's slot masked, every tick, before the new pins are taken;
- the tour's three saves still load, and the parameter takes its default.

## 10. The panel (`anim`, `debug`)

**`anim.Report` gains what the panel needs to show IK:**
- a channel playing a blend shows the blend's name, its position, and its up to four clips with
  their weights;
- **`Report.addFeet(rig, feet)`** adds, for each leg, its name, offset, contact weight and lock
  weight, and the pelvis's drop;
- **`Report.addAim(rig, chain, aim)`** adds the chain's name, its weight, and whether it is past
  its limit.

The game passes its `Feet` and `Aim`, since it holds them. The panel prints names, never hashes,
and still has no write path. Watching a contact flicker, or an offset settle on a step, is what it
is for.

## 11. The characters

**A new generator, `scripts/m36/clips.py`, appends seven walks to the walker** after M35's
eleven clips. So every existing clip, mesh and skeleton keeps its bytes, which Step 6 compares.

| Clip | Length | What it is |
| --- | --- | --- |
| `walk.ne`, `walk.e`, `walk.se`, `walk.s`, `walk.sw`, `walk.w`, `walk.nw` | 1.0 s, loop | `stride`'s gait, its pelvis travelling 1.0 m a lap toward that compass point of the figure's own frame (north is −Z). A foot is down at 0 and 0.5, as in `stride` |

With `stride` as north and `idle` in the middle, they fill a 3 × 3 grid, `x` from −1 to 1 m/s
sideways and `y` from −1 to 1 m/s ahead. That grid is the strafer's blend `walk8`.

**What both sets gain:**
- the warden's set gains `legs`, the `head` aim, and `move`, a one-axis blend of `idle`,
  `stride` and `run`;
- the walker's gains the same, and `walk8`.

**What stays as it was:**
- the warden's model gains no clip;
- `stride`, `run` and the new walks keep the `feet` group;
- `move` itself joins `feet`, so a fade from it to a jump and back keeps the step.

## 12. `sandbox3d`

**The climber's feet.**
- **What it uses:** `anim.Feet`, with locking, since it is moved by the crowd.
- **Where its rays go:** they are cast in the walk world, which holds the course.
- **What it shows:** on the steps and the ramp its feet land within 1 cm of each surface, and on
  the floor its pose is the clip's.
- **It still plays a bare `Player`,** not a machine, which proves IK needs neither a stack nor a
  machine.

**The strafer**, a new figure of the walker's rig.
- **Where it is:** a plain value, as the climber is, not an entity, and not saved.
- **What it does:** it circles a point on the floor at 0.9 m/s, by code. On one lap it faces the
  centre, so it moves sideways, and on the next it faces along its path, so it moves forward. It
  turns between them over a second, so its velocity in its own frame sweeps through every
  direction.
- **What it plays:** `sandbox3d:strafer.machine`, one layer, one state playing `walk8`, with axes
  `side` and `ahead`. The game sets them from that velocity.
- **What else:** it places its feet with locking, and looks at the camera with the `head` aim.
- **Its proof:** a tour run sweeps the blend's position over the whole grid. Between any two
  ticks, no joint's model position moves more than its speed allows.

**The pacer.**
- **Its gaze:** it turns its head to the camera, `wanted` 1 within 3 m and 0 beyond, over its
  additive `look` layer.
- **Its block:** a new key drops a crate on its square, and it turns at it (§9).
- **What it does not get:** feet. It walks flat floor, on root motion that already matches its
  feet, so foot placement would leave its pose unchanged. A test proves that once, and the sample
  leaves it out.

**`FOUNDRY_SANDBOX3D_ANIMATORS=32`** is unchanged: 32 of the pacer's animators, no pose, since IK
is a pose's.

## 13. The court

**The warden walks and runs on `move`.**
- **The body layer's states:** `court:warden.machine` replaces `walk` and `run`, and their four
  transitions, with one state, `move`. It plays the blend with `speed_param "speed"`, and its axis
  is `speed`.
- **What that does:** at 1.0 m/s on patrol it plays `stride` alone, at rate 1.67, `stride`'s own
  0.6 m/s being slower (corrected 2026-11-08, Step 6; it said rate 1). At 2.4 m/s in a chase it
  plays `run` alone, at 1.29. Between, it mixes them on one foot.
- **What stays:** idle and the jump. `idle` stays in the blend at 0, so slowing to a stop eases
  in. The jump stays a state, faded to and from `move` in the `feet` group.

**Its feet** are placed and locked on every tick.
- **On the flat court,** placement changes nothing. A test of the court's ground holds every
  offset at 0, which is the exit condition's flat-ground clause in a game.
- **Locking** holds each planted foot where it landed, against the one-tick lag between the
  crowd's speed and the rate. That is `animation-logic.md` §15's matched-speed row.

**It watches you.** The `head` aim targets the player's eyes, `wanted` 1 while the warden can see
the player (M33's sight test) and 0 otherwise. It is held in limit, so a player behind it is
ignored.

**What must not move:**
- `Game.bodyHash`'s digests for `win`, `caught`, `fell` and the soundtrack, taken before the step
  and compared after, as in M35;
- every route;
- only footfalls, which now come from the heaviest clip, may change.

## 14. The order a game runs a figure in

Every figure that uses these follows one order a tick. The samples follow it, and
`content-mods.md` will say it:
1. Set parameters, and tick the stack, or the player.
2. Move the body.
3. Evaluate the pose, with the machine's blend positions.
4. Ask `Feet.probes`, cast them, then `Feet.place`.
5. `Aim.apply`.
6. `skinMatrices`.

Steps 4 and 5 use the body's transform after step 2. So feet are placed where the body now is,
which is why they come after the move.

## 15. Platform assessment, and the public ABI

**Nothing enters the public table.**
- M48 publishes animation, and its line gains blend spaces, feet and aims at the close.
- The API is still drawn for a table: values, targets as points, chains and blends by name, and
  named refusals. A mod's feet would be placed on what the host's world answers, through the
  queries M25 already publishes.

**Per platform:**
- **Metal:** the first run of everything.
- **Windows/Vulkan on the PC is needed,** once, at Step 9:
  - the pins on x86_64, the costs on the i3, and both samples relocated under validation;
  - no backend, shader or RHI path changes;
  - the PC holds no Foundry clone, so it clones again under the usual rules: idle checked, `-j2`,
    below normal, a scheduled task for windowed runs, and only Foundry's own paths deleted after.
- **Linux: compile only.** Nothing here is Linux-specific (`3d.md` §10.2).

## 16. Verification, pins and budgets

**`anim.ik`:**
- `twoBone` reaches a reachable target within 1e-4 m;
- an unreachable one leaves the chain straight toward it, never through;
- the bend stays on the pole's side;
- weight 0 is the pose bit for bit, and weight 1 is the solve;
- `aim` points `forward` at the target within 1e-4 rad inside its limit;
- shares sum to the whole turn, and the turn is held at the limit.

**`anim.Feet`:**
- contacts read from a generated stride at 0 and 0.5, and none on a one-shot;
- a step up and a step down land the foot within 1 cm, and the pelvis drops only;
- flat ground is the clip bit for bit;
- the tilt is bounded and weighted by contact;
- a lock holds a foot through a contact, lets go at its end and past 0.25 m, and fades both ways;
- a missing hit, and a hit past `max_raise` or `max_drop`, are ignored;
- a replay of 1,200 ticks of feet and aim on a moving figure twice in one process is equal byte
  for byte.

**`anim.Aim`:** the point's sweep rate, the weight's fade in and out, and the fall to zero past the
limit.

**Blend spaces:**
- one-axis and two-axis weights at points, between them and outside them;
- weights summing to 1;
- at most four clips;
- a position swept smoothly moves the pose smoothly;
- one fraction across the clips;
- the lap's length, re-anchored without a jump;
- weighted travel;
- the heaviest clip's events, with ties;
- `motionSpeed` and `speed_param`;
- a blend in a sync group fading into a clip;
- a lost blend counted;
- a blend at its first point when played without a machine.

**`asset`:**
- both records round-trip;
- every refusal in §6 and §8;
- a version 2 set and a version 1 machine build what they did;
- an override, and a reload that keeps handles and one that breaks a blend.

**`scene`:**
- a v2 save naming a blend loads and continues;
- `evaluate` refuses scratch shorter than three poses for a machine;
- every M35 save test is unchanged.

**`debug`:** blends, legs and aims print by name. A figure with none prints as before.

**The samples:**
- existing clip, mesh and skeleton bytes are unchanged;
- the walker's `655e865f98779129` and the player's `cb99ccfcf2b6d6c3` are unmoved, and so are the
  nav pins;
- the pacer's three pins move once, by §9's masked comparison, and are then pinned again;
- the climber's feet are within 1 cm on every step and the ramp;
- the strafer's sweep has no jump, and is pinned;
- the court's body digests are kept, and its flat-ground offsets are all 0.

**Guards verified by mutation,** each named in its step's Resolution:
- the reach clamp, the pole side, weight 0 as identity;
- the aim's limit, the pelvis that only drops, the contact weighting of the tilt;
- the lock's release distance, the grid check, the blend name collision;
- the heaviest-clip events, the re-anchor of a blend's lap, `UnboundBlend`.

**Budgets, measured inside the paced 60 Hz frame loop at ReleaseSafe, on the Mac and the PC:**

| What | Budget (p95) |
| --- | --- |
| `animation`: one figure's advance, evaluate, feet, aim and skin matrices (M24's zone) | 0.10 ms |
| `render.skin`, one figure (M24's zone) | 0.25 ms |
| `animation.animators`: 32 animators, each a two-layer machine, no pose | 0.10 ms, M35's, now M100's |
| The court's whole game tick, with the warden's two rays | 0.25 ms |

Two rays and two closed-form solves are a few microseconds. If a budget fails, the reading goes
in the step's Resolution, and a pose's correction does not go to the jobs. That is M100's, as
M35's readings already are.

**By hand, which is the exit condition's last clause:**
- a person watches the climber's feet on the steps, the strafer, and the pacer's gaze and block;
- a person plays the court, watching the warden walk, run and watch them;
- Step 8 hands the owner a build.

## 17. Implementation order — ten bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

### Step 1 — `anim`: blend spaces

§7 in `Rig`, `Player`, `Stack` and `Machine`: `Blend` and its weights in one and two axes; a
channel playing a blend in laps, re-anchored each tick; weighted travel and `motionSpeed`; the
heaviest clip's events; `Positions`; the third scratch pose; and the tests in §16 for blends.
**Exit:** a hand-built two-axis blend swept across its grid moves the pose without a jump, and
every M35 test and pin is unchanged.

### Step 2 — `anim`: the two solvers

§3: `ik.twoBone` and `ik.aim`, with their tests. **Exit:** both reach their targets within 1e-4,
and both at weight 0 leave a pose bit for bit.

### Step 3 — `anim`: feet and aims

§4 and §5: `Rig.legs` and `Rig.aims` with their validation, contacts read when a rig is built,
`Feet.probes`, `Feet.place`, locking, and `Aim.apply`, with their tests and the replay. **Exit:** a
hand-built figure on a hand-built step lands both feet within 1 cm, flat ground is the clip bit for
bit, and the replay is byte-identical.

### Step 4 — `asset`: the set's version 3 and the machine's version 2

§6 and §8: the schemas, `fpack`'s checks, `Rigs` building legs, aims, contacts and blends, and
binding axes. **Exit:** a set and machine compiled from text build a rig with a blend, legs and an
aim with no renderer, every refusal is named, and older versions build what they did.

### Step 5 — `scene` and `debug`: three scratch poses, and the panel

§7's `evaluate` change in `scene.animation`, and §10's `Report.addFeet`, `addAim` and blend rows.
**Exit:** a v2 save naming a blend loads and continues in `scene`'s hermetic tests, and blends,
legs and aims print by name.

### Step 6 — The clips

§11: `scripts/m36/clips.py`, the seven walks, and both sets' legs, aims and blends. **Exit:** every
existing clip, mesh and skeleton byte is unchanged, and both samples' rigs build with their new
lists.

### Step 7 — `sandbox3d`: feet, the strafer, the pacer's gaze and its block

§9 and §12. **Exit:** from a relocated ReleaseSafe install on Metal:
- the climber's feet are within 1 cm on the course;
- the strafer sweeps its grid without a jump;
- the pacer turns at the crate;
- the pacer's pins move only by the masked parameter, and the tour passes across all three saves.

### Step 8 — The court: the warden's blend, feet and gaze

§13. The owner gets a build, and the exit condition's last clause is theirs. **Exit:** `win`,
`caught`, `fell` and the soundtrack keep every tick, the flat court's offsets are 0, and the owner
has played it.

### Step 9 — Windows/Vulkan

The native suites, the pins on x86_64, both samples relocated under validation, and the i3's costs.
**Exit:** every suite and run passes on the PC, and §16's budgets are read there.

### Step 10 — Close M36

This step resolves:
- `animation-logic.md` §15's two M36 rows, `animation3d.md` §14's IK row and
  `animation-states.md` §18's two M36 rows, by dated notes pointing here;
- ADR-0071's consequence line on a blocked body, by a dated note pointing to §9;
- CLAUDE.md §4.1's two new rows, and §4.3's `anim` and `asset` lines for `ik`, `Feet`, `Aim`,
  blends and the records' versions;
- `docs/modding/content-mods.md` §10, which gains legs, aims, blends, axes and §14's order;
- the roadmap's M36 line, and M48's (blend spaces, feet and aims);
- AGENTS.md's bar if it changed, the design index, the README and `PROJECT_STATE.md`.

Tag `m36`, push when asked, and stop before M37's design. **Exit:** every document names M36
complete, and none names a contract the code does not have.

## 18. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| A hand placed on a point: a rung, a ledge, a door | M50 | `twoBone` serves an arm unchanged; what needs it is a third-person body that climbs and holds, which M50 brings |
| Chains longer than two bones solved together, and full-body solving | M54 | An iterative solver, with ragdolls, where `anim` and physics join |
| A blend space of scattered points, triangulated | M111 | A triangulation a person can see and correct is an authoring view's |
| Contacts marked by hand, and a mirrored clip | M111 | Contacts are read from the clip until then; mirroring stays M111's, as M35 had it |
| Blend spaces, feet and aims in the public table, and in Lua | M48, M49 | §15 |
| Placing feet and aims on `core.Jobs` | M100 | Measured against §16's per-figure budget, beside M35's 32-animator reading |

## 19. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | IK lives in `anim`, on `core` alone. It takes model-space targets, and the game finds them with its own queries, so `anim` sees no physics (ADR-0073) | §3, §4 |
| 2 | **IK is presentation:** it never moves a body, fires an event or enters a save. `Feet` and `Aim` are values the game holds, stepped once a tick, so a replay reproduces every pose (ADR-0073) | §4, §5 |
| 3 | Two closed-form solvers only, two-bone and aim. The knee bends the way the clip bent it, and weight 0 leaves the pose bit for bit | §3 |
| 4 | Contacts are read from each looping clip's foot heights when a rig is built, not authored | §4 |
| 5 | The pelvis only drops. Feet are tilted to the ground by at most 0.5 rad, by contact weight. Flat ground leaves the clip's pose | §4 |
| 6 | Foot locking holds a planted foot in world space and lets go at contact's end or past 0.25 m. It answers `animation-logic.md` §15's matched-speed row | §4, §13 |
| 7 | A gaze is a chain turned by shares within a limit, after every layer and after the feet. It is not a layer | §5 |
| 8 | `foundry:animation_set` v3 appends `legs`, `aims` and `blends` as top-level lists | §6 |
| 9 | A blend space is one axis sorted, or two axes as a full grid, with at most four clips mixed. Scattered points are M111's | §7 |
| 10 | A blend is named like a clip and played by a channel in laps, re-anchored each tick. Its events are its heaviest clip's, and its travel and `motionSpeed` are weighted (ADR-0074) | §7 |
| 11 | A blend's position is the machine's parameters, bound by `foundry:animation_machine` v2's `axes`. **No saved shape changes**, and `foundry:animator` stays at v2 | §7, §8 |
| 12 | Evaluating takes a third scratch pose, and `scene.animation.evaluate` asks for three times the joint count for a machine | §7 |
| 13 | A blocked body: the game sets a parameter, and the pacer's machine turns on it. **The pacer's three pins move once**, proved by a comparison with the new parameter masked. This answers ADR-0071's consequence line and `animation-logic.md` §15's blocked row | §9 |
| 14 | Seven directional walks are appended to the walker, so every existing byte holds. The warden's model gains none | §11 |
| 15 | Sandbox: the climber's feet on the course, a new strafer on a 3 × 3 blend, the pacer's gaze and block. The pacer gets no feet | §12 |
| 16 | Court: the warden's walk and run become one blend over speed, with feet, locking and a gaze at the player. Its body digests must hold | §13 |
| 17 | Nothing enters the public table. M48's line gains blend spaces, feet and aims at the close | §15 |
| 18 | The PC is needed once, at Step 9. Linux is compile only | §15 |
| 19 | Budgets: M24's two zones with feet and aim inside, and the court's tick at 0.25 ms. The 32 animators stay M100's | §16 |
| 20 | The owner's watch and play is the exit condition's last clause, at Step 8 | §16 |

Once these are accepted, nothing blocks Step 1.

## Resolution — Step 1: blend spaces (2026-11-07)

`anim` now covers §7:
- `engine/src/anim/blend.zig` is new: `Blend`, `Point`, `Mix`, `Positions`, and the lap, travel and
  speed of a blend at a place;
- `Rig`, `Player`, `Stack` and `Machine` play blends;
- the tests are in `engine/src/anim/blend_tests.zig`.

**How a blend sits in a rig: as an entry of `Rig.clips`.**
- **The entry:** `blend.entryFor` makes it, with `RigClip.blend` set and a clip that is a lap of
  one second with no tracks. So `Rig.find` answers clips and blends alike.
- **The name:** a blend sharing a clip's name is the rig's own `NameCollision`, so §6's
  `BlendNameCollision` is that error. `Rig.blend(name)` answers the arrangement.
- **The rig's refusals:** `InvalidBlend`, for a blend that is not sorted, or an entry carrying an
  authored rate, events, a rise or a reference. Also `UnknownBlendClip`, `BlendOfBlend`,
  `BlendOfOneShot`, `BlendOfAdditive`, `TooManyBlends` (eight), and `BlendMotionMismatch`, an entry
  whose `motion` is not whether any of its clips moves.
- **The arrangement's refusals:** `Blend.build` refuses `TooFewPoints`, `TooManyPoints` (25),
  `InvalidPoint`, `DuplicatePoint` and `NotAGrid`. The set's own refusals in `fpack` are Step 4's.
- **Ties:** the heaviest clip's tie goes to the earlier listed point. A clip standing at several
  places has its weights summed, and keeps its earliest place.

**Three sharpenings of §7:**
- **A blend's `motionSpeed` is weighted by lap,** not as a mean of its clips' speeds. It is the
  metres of a lap, weighted, over the seconds of a lap, weighted, so it equals the travel the blend
  reports. §7's "weighted" is that.
- **A clip's authored rate shortens its lap,** so a lap's length counts `duration ÷ speed`.
- **Where a blend has no travel at all,** such as standing on `idle`, a `speed_param` state plays
  at its own `speed` rather than at 0 ÷ 0. `NoMotionSpeed` for a blend asks whether its fastest clip
  moves, since its first point may be still.

**Two more that §7 had not said:**
- **The `laps` condition on a blend state** counts laps of the blend's lap at its place now.
- **The machine reads positions with `get`,** by name with defaults, so a pose evaluated before
  any tick still finds them. A position that is not a number is the origin on that axis, and one
  outside the grid is held at its edge.

**The calls:**
- `Player.advanceAt`, `seekLapsAt` and `evaluateAt` take `Positions`, and `evaluateAt` takes two
  scratch poses.
- The calls without `At` put every blend at its first point. There one clip has all the weight,
  so the old one-pose `evaluate` stays exact.
- `Stack.advanceLayer` takes positions, and `Stack.advance` passes none.
- `Stack.evaluate` takes positions and three scratch poses, and `machine.evaluate` three, with
  positions from the parameters. `machine.positions` is public.

**Step 5's scratch change landed here,** because the signature forced it:
- `scene.animation.evaluate` asks for three times the joint count for a machine;
- the warden's and the pacer's buffers grew to match;
- Step 5 keeps the scene's blend-save test and the panel.

**Guards verified by mutation,** each failing a test before it was restored:
- the grid check;
- the tie to the earlier point;
- the blend's per-tick re-anchor (three tests failed);
- `UnboundBlend`;
- events from the heaviest clip.

The name collision is M34's existing guard.

**The bar.**
- `zig build test`: 2,826/2,836, ten skips, 132/132 steps. That is thirteen new tests, and every M35
  test and pin is unchanged.
- The first run crashed one `scene` test: its helper still lent two scratch poses, so `evaluate`
  answered null. The helper now lends three.
- Every other line of the bar passed: `fmt`, the four `check`s, the four thirty-frame samples and
  `fdt-check`.

## Resolution — Step 2: the two solvers (2026-11-07)

`engine/src/anim/ik.zig` is new, with `TwoBone`, `AimChain`, `twoBone`, `aim`, `fromTo` and
`modelOf`. Its tests are in `engine/src/anim/ik_tests.zig`, on a hand-built leg and neck.

**As §3 has it:**
- **The reach** is held between `min_reach` (1 mm) and the bones' sum less `straight_margin`
  (0.1 mm). It is held below too, at their difference plus the margin, so a target at the hip folds
  the leg as far as it can go and no further.
- **The bend plane** is through the root, the target and the pole. A pole on the line falls back to
  the clip's own middle joint.
- **The two turns** are shortest arcs in model space. Each is turned into the joint's local frame
  as `p⁻¹ · t · p`, with the middle read in its parent's frame after the root has turned. So the
  root may be any ancestor of the middle, which a test proves with the pelvis as the root.
- **Weight** slerps each changed local rotation. At 0, or for a weight that is not a number, the
  pose is not touched. Above 1 it is the solve.

**What §3 had not said:**
- **No inverse trig runs.** The bend comes from the law of cosines and a square root. A turn between
  two directions comes from their dot and cross products. The limit's cosine and half-angle come
  from `core.math.trig.sinCosTurns`. `Quat.slerp` is the only library-dependent arithmetic, as in
  every blend already.
- **An aim limits the turn from where the head started.** Each joint is aimed from the head's
  current place at the target. The direction is held within `limit` of the starting forward, and a
  joint takes `share ÷ remaining` of what is left, so the last joint finishes the turn exactly.
- **Only rotations change,** and a chain is assumed to have uniform scale. A skeleton root that
  turns is read once, by `Transform.fromMat4Exact`, and a test reaches under a root turned 1.1 rad.

**Guards verified by mutation,** each failing a test before it was restored:
- **the pole's side:** a negated bend failed;
- **the aim's limit:** an unheld direction failed;
- **the reach clamp, after the test was tightened:** the clamped cosine alone already folds and
  straightens the leg, so removing the clamp moved the reach only by the 0.1 mm margin, inside the
  first test's 1e-4 tolerance. Both reach tests now hold the margin to 2e-5, and the mutation fails
  them;
- **weight 0 as identity, after the test pose was changed:** the first test pose's rotations
  survived `slerp` at 0 bit for bit, so dropping the early return passed. The pose now holds a
  clip's bend and keys that are unit only to an exporter's precision. Dropping the return then
  fails for both solvers.

**The bar.** `zig build test`: 2,835/2,845, ten skips, 132/132 steps, with nine new tests. Every other
line of the bar passed.

## Resolution — Step 3: feet and aims (2026-11-07)

`anim` now covers §4 and §5:
- `engine/src/anim/feet.zig` holds `Leg`, `Contact`, `deriveContacts`, `contactWeights`, `Probe`,
  `Ground`, `Feet` and `LegState`;
- `engine/src/anim/gaze.zig` holds `RigAim` and `Aim`;
- `ik` gains `limitedTurn` and `turnJoint`;
- the tests are in `engine/src/anim/feet_tests.zig`, on a hand-built two-legged figure.

**In the rig.**
- `Rig.legs` and `Rig.aims` are validated when a rig is, refusing `TooManyLegs`, `UnnamedLeg`,
  `DuplicateLeg`, `NotAChain` and `InvalidLegRange`, and `TooManyAims`, `UnnamedAim`,
  `DuplicateAim` and the chain's own refusals.
- `RigClip.contacts` holds each leg's stretches of contact. A clip whose stretches name a leg the
  rig lacks, fall outside `[0, 1]`, are empty, number more than four for one leg, or sit on a
  one-shot or a blend is refused as `InvalidContacts`.
- `soleOf` reads a foot's rest height, and `Rigs` fills `Leg.sole` with it in Step 4.

**Sharpenings of §4:**
- **Contacts are read by `deriveContacts`,** which `Rigs` calls when it builds a rig (Step 4). It
  samples the clip without its travel held out, since only height counts. Sampling starts after a
  sample with the foot up, so a stretch across the lap's end is one stretch, written `from > to`.
- **A foot down all lap** is one stretch from 0 to 1. A leg with more than four stretches keeps its
  first four.
- **A pose's contact** is `contactWeights(rig, player, positions)`, from the base player, and the
  game passes it to `place`. So `place` takes a `contacts` argument §4's signature did not show.
  The court and the strafer pass their stack's base player.
- **The pelvis** is the root above the first leg's hip. It drops along model −Y, read through the
  skeleton's root.
- **A leg's target** is the clip's foot plus its offset, taken before the pelvis drops. So a raised
  foot reaches up past the drop, and a foot the clip lifts keeps its lift above the ground.
- **Flat ground stays exact:** a ground height inside 0.1 mm is 0, and a leg whose target is within
  0.01 mm of where it stands is not solved. So flat ground, and a lock on a still foot, leave the
  pose bit for bit. A test holds both, and a bump of 0.03 mm.

**Sharpenings of §5:**
- **`Aim.apply`** takes the chain's index in `Rig.aims`.
- **The first target, or one seen after a gaze faded out, is taken as it is.** Later ones are swept
  at 6 rad/s.
- **The limit is measured from where the clip faces the chain's last joint.** `beyond` says
  whether the point is past it, for the panel.

**Guards verified by mutation,** each failing a test before it was restored. Four first passed,
because the tests were weaker than the guards, and each test was strengthened before its
mutation counted:
- **the pelvis that only drops:** it is held twice, by the lowest offset starting at 0 and by
  `@min(0, …)`. A test with ground raised under both feet now fails when both are removed;
- **the contact weighting of the tilt:** the gate at contact 0 hid it, so a half contact now
  tilts half as far, within 1e-3;
- **the lock's release distance:** an unreachable 1,000 m failed;
- **the dead zone:** the flat test never produced an error to absorb, so the 0.03 mm bump now
  fails without it.

The test fixture's knees were bent 6 cm, because a straight leg cannot hold a foot that the body
slides away from. The lock test holds only within the 8 cm the leg can reach.

**The bar.** `zig build test`: 2,844/2,854, ten skips, 132/132 steps, with nine new tests including
the 1,200-tick replay of feet and a gaze on moving, bumpy ground. Every other line of the bar passed.

## Resolution — Step 4: the set's version 3 and the machine's version 2 (2026-11-08)

`asset` now covers §6 and §8:
- `foundry:animation_set` is version 3, appending `legs`, `aims` and `blends`, each `since = 3`;
  `schema_v2` is version 2's fields, as `schema_v1` is version 1's;
- `foundry:animation_machine` is version 2, appending `axes`, with `schema_v1`;
- `Rigs` builds legs, aim chains, blends and every clip's contacts, and machines bind axes;
- the tests are colocated in `animation_set.zig` and `animation_machine.zig`, and in
  `engine/tests/animation_rigs.zig` on a new standing figure with a pelvis, a knee, a foot and a head.

**What `fpack` checks, as §6 and §8 list it,** with three sharpenings:
- **An aim chain of no joints or more than four** is `NotAChain`, since a single record can't
  see the skeleton. The rig refuses a chain whose joints do not descend, with the same name.
- **A point whose place is not a finite number** is `InvalidPoint`. §6 had no name for it, and
  `anim.Blend.build` already refuses it by that name.
- **A blend is checked with the arrangement `anim` will build,** by `set_mod.arrangement`, so
  `TooFewPoints`, `TooManyPoints`, `DuplicatePoint` and `NotAGrid` are the same checks at compile
  and at build. `BlendOfOneShot` and `BlendOfAdditive` are refused where the set itself lists the
  clip as a one-shot or additive. Otherwise the rig refuses them.

**Defaults §6 had not written:**
- an aim joint's `weight` defaults to 1;
- `forward` is an optional `{ x y z }`, all three required when it is given.

**In `Rigs`:**
- **A blend becomes an entry of the rig's clips,** after the model's, by `blend_space.entryFor`, and
  the whole list is then sorted. Its `motion` is whether any of its clips moves, and its `sync` is
  `blends[].sync`.
- **A blend named as one of the model's clips** is `BlendNameCollision`, named by `Rigs` before
  `Rig.validate` would say `NameCollision`. So a clip the set never lists is caught too.
- **`start` may name a blend.** A figure may stand in one, at its first point, before a machine
  places it.
- **A leg's joints are found by name,** and its `sole` is read from the rest pose by `soleOf`. Its
  chain, and an aim's descent, are `Rig.validate`'s.
- **Aim weights become `share`s as written,** since `ik.aim` normalises them.
- **Contacts are read after `Rig.validate`,** so no unvalidated key is sampled. Every clip that is
  looping, not additive and not a blend gets its contacts, at most four stretches a leg, and
  `validateLegs` runs again on the result. A rig with no legs reads none. An additive clip has
  none, because contact is the base layer's (§4).

**In the machine:**
- **`fpack` checks** `TooManyAxes` (8), `DuplicateAxes`, that `x` and `y` are declared
  parameters, and empty names. `y ""`, its default, is a one-axis binding.
- **The rig checks** `UnknownBlend`, `AxisMismatch` and `UnboundBlend`, as Step 1's
  `Machine.validate` does.

**Older versions build what they did:**
- a version 2 set compiled against `schema_v2` reads under version 3 with no new lists;
- a version 1 machine reads under version 2 with no axes, and builds against a version 3 rig;
- the version 1 and 2 rig tests now also hold that no clip has a blend or contacts, and that the rig
  has no legs or aims.

**The proof from text:**
- the standing figure's `walk` lifts the foot 15 cm at mid-lap. Its contact is read across the
  lap's end, from sample 58 of 64 to sample 7, exactly as `deriveContacts` writes it;
- `idle` is down all lap;
- the sole is 0.05 m;
- the machine, at speed 0.6, places the blend halfway between standing and walking, and the rate
  from speed keeps the ground at 0.6 m/s over half a second.

**Guards verified by mutation,** each failing a test before it was restored:
- the compile-time arrangement check (`TooFewPoints` passed);
- `BlendOfAdditive` at compile;
- `DuplicateAxes`;
- `Rigs`' `BlendNameCollision`, which `Rig.validate` would otherwise report only as
  `NameCollision`;
- a blend's `motion`: with it wrong, every version 3 rig test failed with `BlendMotionMismatch`.

**The bar:** see PROJECT_STATE. `zig build test`: 2,855/2,865, ten skips, 132/132 steps, with
eleven new tests.

## Resolution — Step 5: the scene's blend save, and the panel (2026-11-08)

Step 1 had already moved `scene.animation.evaluate` to three scratch poses. This step adds the
scene's blend tests and §10's report and panel.

**In `scene`:**
- **A version 2 save naming a blend loads and continues byte for byte.** A figure walks by a
  blend, placed by `speed` at 0.3, halfway between standing and the walk. It is saved 37 ticks
  in, mid-lap, loaded into a second world, and both are steered alike for 240 ticks: on to the
  walk's place, then past it. Every tick's pose, motion, events and stack hash the same. Past the
  walk's place the blend is held at its edge and the rate carries the rest (1.5 at 0.9 m/s).
- **A save naming a blend that a later rig lacks** empties that channel and counts it as lost, as
  a lost clip is, and the animator stays resolved (§7).
- **Nothing saved changed,** so M35's test that holds the animator at 872 bytes holds it still.

**In `anim.Report`:**
- **A channel's row names a blend by its label.** Its `at` and `axes` say where it sits, and its
  up to four `members` are the clips mixed there, with their weights. Its `time` and `duration`
  are seconds of the lap it has at that place, not the entry's nominal one second.
- **Where the place comes from:** `addStack` reads it with `machine.positions`. A bare player's
  `add` has no machine, so a blend sits at its first point, as it plays.
- **`addFeet(rig, feet)` and `addAim(rig, chain, aim)` write into the row added last.** `Report.open`
  says whether that figure was given a row. Without it, a ninth figure's feet would land in the
  eighth's row. A chain the rig lacks adds nothing.
- **The contact weight is kept for the panel.** `LegState.contact` holds the contact `place` was
  given on the last tick, since the panel needs it and only the game held it. Like the rest of
  `Feet` it is presentation, never saved.

**In the panel:**
- **A blend channel** prints `at x` (or `at x, y`) and a `+ clip  weight` line for each clip.
- **A figure with feet** prints `pelvis` and a `leg` line each, with its offset, contact and lock.
- **Each aim chain** prints its weight, and `past its limit` when it is letting go.
- All by the names content gave them. Counts out of range read no further than the arrays, and
  the panel's no-write-path test still holds: a `Report` holds no pointer.

**Guards verified by mutation,** each failing a test before it was restored:
- `Report.open`;
- the lap's seconds for a blend's time (`expected 0.85, found 1`);
- `addStack`'s positions from the machine;
- `place` keeping the contact. Its test now requires a foot to be down, so a contact left at 0
  fails it.

**The bar.** `zig build test`: 2,861/2,871, ten skips, 132/132 steps, with six new tests.

## Resolution — Step 6: the clips (2026-11-08)

§11 is built:
- `scripts/m36/clips.py` generates the walks;
- `scripts/m24/make_character.py` appends them to the walker after M35's four. The warden's model
  gains none, and its generator was not run;
- `sandbox3d:walker.set` and `court:warden.set` gain `legs`, the `head` aim and `move`, and the
  walker's gains `walk8`.

**A correction to §11: eight walks, not seven, each travelling its place on the grid.**
- **What §11 said:** `stride` as north, and seven walks of 1.0 m a lap toward their compass
  points.
- **Why that does not fit:** `walk8`'s places are metres a second, `x` from −1 to 1 and `y` from
  −1 to 1. But `stride` travels 0.6 m a lap, and a diagonal walk of 1.0 m travels 0.71 m on each
  axis. So the travel inside the grid would not be the velocity the strafer sets. A body that
  code moves at that velocity would slide against its locked feet.
- **What was built:** a new `walk.n` of 1 m a lap takes north. The diagonals travel 1 m on each
  axis, √2 m a lap. Bilinear weights reproduce anything linear in the position exactly, so
  `walk8`'s travel is its position everywhere on the grid. A test holds that at five places,
  within 0.1 mm, and every lap is one second.
- **What stays as it was:** `stride` is untouched, and stays `move`'s walk and the pacer's.

**The gait.** Each walk is `stride`'s:
- **The hips** swing about the axis that carries a hanging limb toward the direction of travel.
  They swing in proportion to `stride`'s 0.4 rad for 0.6 m, held at 0.45 rad so that a leg swung
  sideways crosses the other little.
- **The arms** swing with the forward part of the walk alone.
- **The knees, the spine and the bob** are `stride`'s. So a foot is down near 0 and halfway,
  where the footfalls are.
- **What the set says of each:** a looping clip with motion, two footfalls and the `feet` group.

**`move`** is §6's: `idle` at 0, `stride` at 1.0 and `run` at 1.86, in `feet`.
- **A place on the axis is a speed asked for, not a clip's own speed.** So at 1 m/s the warden
  plays `stride` alone at rate 1.67, its 0.6 m/s motion speed's, as M35's machine already did.
- **§13 says "at rate 1",** which is wrong. Step 8, which builds the warden's machine, corrects it.
- **At 2.4 m/s** it plays `run` alone at 1.29, as §13 says.

**Bytes.**
- `walker.bin`'s first 29,800 bytes are unchanged, and so are the glTF's nodes, skin, mesh, and its
  first 96 accessors and buffer views. Only the eight animations and their data follow.
- `clip0`–`clip10`, `mesh0` and `skeleton0` compile to their pins in both models.
- The walker's pin test now also pins `clip11`–`clip18`. The warden's files are untouched.
- The walker's, the player's and the pacer's pins and the court's digests all hold. No sample plays
  anything new yet.

**Tests on each sample's compiled content.** The walker's rig is M35's eleven clips plus eight
walks and two blends, 21 entries, and it checks:
- both legs, their chains and their 8 cm soles;
- the `head` chain over the neck and the head;
- `idle` with both feet down all lap, and `stride` and every walk with each foot down for part of
  one;
- each walk's travel and group;
- `move` as one axis in `feet`;
- `walk8` as a 3 × 3 grid whose travel is its place.

The warden's is twelve entries: its legs, gaze and `move`. A test places `move` at 1 and 2.4 m/s,
and finds no `walk8`. The M35 tests that counted eleven clips now count 21 and 12. The `stride` test
copies the rig's clips into a buffer of any size.

**Guards verified by mutation,** each failing a test before it was restored:
- a walk taken out of `feet`;
- the warden's legs removed;
- two of `walk8`'s points swapped (its travel then misses its place);
- a wrong pin on `clip11`.

**The bar:** see PROJECT_STATE. `zig build test`: 2,863/2,873, ten skips, 132/132 steps, two new
tests. The samples' content changed, so `court` and `room` were staged with `dist`, ReleaseSafe on
Metal.

## Resolution — Step 7: `sandbox3d`: feet, the strafer, the pacer's gaze and its block (2026-11-08)

§9 and §12 are built:
- the climber's feet in `crowd.zig`;
- the strafer, new in `strafer.zig` with `sandbox3d:strafer.machine` and `sandbox3d:strafer.main`;
- the pacer's `blocked`, its gaze and its crate in `pacer.zig`, the crate a new record,
  `sandbox3d:pacer.block`;
- key **K** in `main.zig`;
- the tests are in `nav_tests.zig`, `pacer_tests.zig` and a new `strafer_tests.zig`.

Four things §12 said turned out otherwise, and one clip fix went back into Step 6's walks.

**The climber.**
- **How its feet are placed:** rays go down from each foot into the walk world's static layer
  (mask 1). `anim.Feet` places the feet with locking on every tick it walks. On a link it plays its
  one-shot as the clip has it, since a ladder's rungs are no floor.
- **A sharpening of `anim`:** `Feet.probes` now gives its distance in world metres. The climber is
  drawn at 0.71 of the walker's size, so a ray in model metres would have looked 30% too far. A test
  holds a half-size figure's rays at half the length.
- **A correction to §12: on the floor its pose is not the clip's.** The crowd stands its pawn
  1.37 cm above the floor, which is the navigation mesh's height there. So on the floor the feet take
  the figure down to it: every settled leg's offset there is the pawn's height over the figure's
  size, within 0.1 mm. On a floor the body stands on, the pose is the clip's bit for bit, which
  `anim`'s tests hold and the strafer below shows.
- **What "within 1 cm" measures:** the foot's height above the ground, less the clip's own height
  for that foot above its floor. M24's `stride` never puts a foot flat on its floor: a foot that
  counts as down sits 1–4 cm above it, and placement keeps that lift on purpose (§4).
  - Over two minutes of the crowd, every landing on a settled offset is exact: 2,105 of them, 25 on
    the steps, the ramp and the platform.
  - A foot that lands within a few ticks of crossing an edge lands while its offset still eases at
    §4's 2 m/s, so that nothing pops. That happened to 21 landings, missing by up to 12.6 cm. The
    test bounds those under 4%.

**The strafer.**
- **A correction to §12: the sweep.** Facing the centre one lap and the path the next turns its own
  velocity only from ahead to one side, a quarter of the directions. Instead its heading turns
  steadily against its path, `spin` 0.5 turns a lap, so over two laps it walks forward, sideways,
  backward and sideways again. A test sees all eight eighths of a turn.
- **Where it is:** it circles at 0.9 m/s round (−0.25, 0, 1.25), 0.6 m out. That is clear floor: a
  map of the walk world's heights found a 0.3 m block where §12's first guess had put it.
- **A correction to Step 6: the walks' gait.** Step 6 copied `stride`'s gait, whose planted foot
  rises and swings forward and back again. So the contacts read from it fell in the swing, with the
  foot moving 2.5 m/s while "down". The eight walks are now regenerated:
  - the pelvis rides the planted leg's arc, so a planted foot stays at its rest height;
  - the swinging knee bends back 0.8 rad;
  - the hips swing `asin(v ÷ 4L)`, so a planted foot moves back by the walk's travel.
  - Footfalls are still at 0 and 0.5. `clip11`–`clip18` are re-pinned. Every earlier file and the
    buffer's first 29,800 bytes are unchanged.
- **A correction to §12: its feet are not locked.**
  - Inside `walk8` the mixed walks' planted foot slides up to 0.8 m/s, because a blend mixes the
    hips' rotations, not the feet.
  - So a locked foot reaches its 0.25 m reach in mid-contact and is let go. Its catch-up then moved
    a joint 11.3 cm in a tick (6.8 m/s).
  - Unlocked, or with no feet at all, the fastest joint moves 3.4 cm a tick (2.1 m/s), and the test
    bounds it at 3 m/s.
  - The climber locks, and so will the warden, since each plays one clip at a speed its rate
    matches.
  - `Strafer.lock` keeps the choice in one place.
- **On the flat floor its pose is the blend's, bit for bit, on every tick,** against a second
  strafer with no ground.
- **It looks at the camera** with the `head` aim, and lets go once the camera is behind it.
- **It replays to the bit.** Its 1,200-tick hash is pinned at `27f549beaaf0e20b`.
- **The tour gives it no camera,** as it gives the pacer none.

**The pacer.**
- **`blocked` is a count, kept in the parameter.** It rises a sixth for each tick running that the
  controller delivered less than half the travel `stride` asked for, so six ticks is 1. A tick that
  asks for none, such as a turn on the spot, resets it.
  - The machine's new first transition, `stride` → `turn` when `blocked` is 1, does the rest.
  - Keeping the count in the saved parameter means a load carries on counting. §9 said 0 or 1, and
    the rule it gives for reaching 1 is the same.
  - `pacer_back` gains the same transition from both its walking states.
- **The crate:**
  - it is the record `sandbox3d:pacer.block`, a static box in the walk world on the first side,
    which **K** drops and lifts;
  - the pacer turns where it stops, at the crate's east face plus the controller's 0.22 m radius,
    within 3 cm;
  - it then walks the next side;
  - the run logs each block.
- **The gaze** turns its head to the camera inside 3 m, after the pose and over the `look` layer, and
  lets go beyond. The tour gives it no camera, since its proof compares the run's pose hash with a
  replay's.
- **A correction to §9: the pacer's pins did not move.** `47f67027ff3a12b0`, `ef5c24337f5f2925` and
  `pacer_back`'s `59632bcff2461113` all hold.
  - **Why:** they hash the pose, the feet, the motion, the heading and the footfalls, never the
    save's bytes, and without a crate `blocked` stays 0 and changes no tick.
  - **So** the masked comparison §9 asked for is the pins themselves, unmasked.
  - **The tour's three saves** still load, and `blocked` takes its default.
- **It still places no feet,** as §12 says.

**Guards verified by mutation,** each failing a test before it was restored:
- the probes' world scale;
- the pacer's half-travel test for being held up;
- the climber placing its feet at all;
- the strafer's spin (its sweep test and its pin failed);
- the pacer's gaze reach.

**From the relocated ReleaseSafe install on Metal,** windowed:
- **The tour passes all three saves:**
  - mid-stride `e46c09dc62b1eeac`;
  - mid-turn `222e0a9b12fd152c`;
  - the M34 save `47f67027ff3a12b0`.
  - The save is still 9,280 bytes, since a stack's parameters are fixed slots.
  - The walker's `655e865f98779129` and the player's `cb99ccfcf2b6d6c3` hold.
- **With K pressed on frame 60,** the pacer is blocked at (2.375, 0.800) and turns there. On its new
  path it is blocked again at (2.775, 1.685), by the room, and turns there too. A second loop
  repeats both.
- **The strafer's tick, p95 in the paced loop:** 0.062 ms (tour) and 0.066 ms (crate run) for
  advance, evaluate, two rays, feet, gaze and skin matrices, against §16's 0.10 ms.

**The bar.** `zig build test`: 2,871/2,881, ten skips, 132/132 steps, with eight new tests. Every
other line passed.

## Resolution — Step 8: the court: the warden's blend, feet and gaze (2026-11-08)

§13 is built:
- `court:warden.machine` plays `move`;
- `warden.zig` places the warden's feet and turns its head each tick;
- the tests are in the court's `nav_tests.zig`.

**The machine.** The body layer is now two states:
- `move`, the entry: it plays the set's `move` with `speed_param "speed"`, and its axis is `speed`;
- `jump`, as before, faded to from `*` when `link` is 1, and back to `move` when it is 0.

M35's `walk` and `run`, `idle` as a state, and their four transitions are gone. Standing, `move` is
idle. The arms and the breath are unchanged.

**What the blend does:**
- at 1 m/s on patrol it is `stride` alone, at rate 1.67 (§13's "rate 1" is corrected in place,
  dated);
- by 1.43 m/s it is half and half, where M35's machine walked on to 1.8;
- from 1.86 m/s it is `run`;
- a chase at 2.4 m/s is `run` at 1.29.

The court's tests that read "which clip plays" now read the clip that leads inside `move`, at the
machine's place.

**The pose, the feet and the gaze are made on the tick, not the frame.**
- **The order:** after the body's move, `Warden.present` evaluates the pose. It casts two rays into
  the level's layer and places the feet, locked, as §13 says. It turns the `head` aim toward the
  player's eyes, with `wanted` 1 while the warden sees them, and then skins.
- **Why on the tick:** feet and a gaze are stepped once a tick, with the tick's `dt` (ADR-0073). So
  the frame only draws what the last tick made, and a replay makes the same pose.
- **On a crossing** its jump is left as its clip.
- **`evaluate` stays,** pose and skin only, for a test or a host with no level.
- **None of it reaches either hash.** A test throws one warden's gaze and feet off every tick and
  finds `hashTick` and the pose equal to a second warden's.

**`hashTick`'s walk weight** is now read at the end of each tick, as the share of the base layer
that is not idle, a blend's clips counted by their weights at its place. M35 read the `stride`
channel, which no longer plays.

**A correction to §13: on the flat court the offsets are not 0.**
- **Why:** the controller holds the warden 4–5 mm over the floor (its waypoints stand at 0.004,
  and the controller has its skin). So each settled offset is exactly minus that height, within
  0.1 mm, and the pelvis drops by it.
- **What the test holds:** that, over a patrol and a chase, for every planted foot.
- **The rays that miss:** a foot the run lifts high has its ray end above the floor, and a miss
  leaves that foot as it is. Every planted foot finds the floor.

**The bodies keep every tick.** `win`, `caught`, `fell` and the soundtrack keep their M35 digests,
`2495783980aedff1`, `757a204cc05d1b02`, `6b4fdba4db5b669e` and `806953eeb8f10db8`, every tick. A
mutation putting the gaze's weight into `bodyHash` fails that test.

**From the staged ReleaseSafe court on Metal, moved out of the repository,** each script was played
windowed:

| Script | Whole game tick p95 | `render.skin` p95 |
| --- | --- | --- |
| `win` | 0.233 ms | |
| `caught` | 0.193 ms | 0.067 ms |
| `fell` | 0.207 ms | 0.071 ms |

The budgets are 0.25 ms for the tick and 0.25 ms for the skin. No sound, mixer command or event
was dropped.

**Guards verified by mutation,** each failing a test before it was restored:
- the feet placed at all;
- the gaze given the player's eyes;
- the walk weight read from the blend;
- the gaze kept out of the body's hash (the digest test failed).

**The bar.** `zig build test`: 2,873/2,883, ten skips, 132/132 steps, with two new tests. Every other
line passed. `room` and `court` were staged with `dist`, since the content changed.

**The exit's last clause is the owner's:** the staged build is `zig-out/dist/court/Foundry
Court.app`, or its zip, and the owner has not yet played it.
