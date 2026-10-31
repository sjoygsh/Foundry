# Design: M34 — Animation logic I: playback, a saved component, root motion and events

**Status:** Proposed 2026-10-31; awaiting the owner's acceptance of §16. No step has begun.
**Date:** 2026-10-31
**Baseline:** `3a7a68d`, tag `m33`. M0–M33 are complete.
**Decisions:**
- These ADRs constrain it:
  - ADR-0058: `anim` is L1 on `core` alone, clips are compiled assets handed over as values, and
    playback is the caller's until a second consumer shows what an engine component should hold.
    Its "Revisit if" names that consumer: a save, a replicated pose or the public ABI.
  - ADR-0050: an engine-declared component is opted into per world, and propagation holds its
    rules against data no call validated.
  - ADR-0010: component types are registered at runtime, and a save is the type's own decision.
  - ADR-0055: generated records are named by position in the source file. They are not an
    identity to save against.
  - ADR-0070: a value the game owns says what it wants, the game moves the body, and the value
    is told where the body went.
  - ADR-0041: engine record types live in `asset`, so `fpack` checks them without linking their
    consumer.
  - ADR-0025: the overlay reads the subsystem's own answers and has no private path.
  - ADR-0013: deterministic-friendly, not bit-exact.
- It proposes one ADR:
  - [ADR-0071](../adr/0071-playback-is-a-value-a-component-saves.md): playback is `anim.Player`,
    a plain value of a few fixed channels. `foundry:animator` is that value under an engine name,
    so a world saves it. What a clip means (its loop, its events, its root motion) is a
    hand-written record, `foundry:animation_set`, and never part of the clip's bytes. Root motion
    is a wish, as an agent's is: the player reports a delta and the game moves the body.

## 1. Purpose and boundary

The roadmap's row (`docs/ROADMAP.md`, Phase 6) is the contract:

> M34 | Animation logic I | An engine animation component saved with a world, root motion and
> events; also an animation panel in the overlay; also the clip an agent plays on a link (M33)

**The runnable result.** In `sandbox3d`, a new figure, the pacer, walks a square at the speed its
clips carry, turning its corners by a clip. Save the world in mid-stride, load it, and the figure
carries on from the same foot. In the court, the warden's feet are heard when they land, its
stride matches its speed in a chase, and it jumps the gap with a jump clip instead of gliding
across in a walk. The overlay's new panel shows all of this running.

**The exit condition.** A saved and loaded world continues byte for byte, events and root motion
replay exactly, every refusal is proved, and a person has watched and heard it.

**In M34:**
- `anim.Player`, a fixed-size playback value, and `anim.Rig`, a skeleton and its clips made ready;
- `foundry:animation_set`, the record that says what each clip means;
- events and root motion, both reported on a tick;
- `foundry:animator` and `foundry:root_motion` in `scene`, saved with a world;
- an animation panel, fed by `anim.Report`;
- the warden and the sandbox's walker moved onto `anim.Player`, ending two copies of one routine;
- a clip for a link crossing, in the court and in the sandbox.

**Not in M34.** Each has its owner in §15:
- state machines, layers, masks and additive poses, which are M35's;
- foot placement and look-at, which are M36's;
- anything in the public table, which is M48's;
- a third-person player, which is M50's;
- placing events on a timeline, which is M111's.

## 2. What exists

Read from the code at `3a7a68d`:
- **`engine/src/anim/`** has `Skeleton`, `Clip`, `Pose`, `sample`, `blend`, `wrap`, `clamp`,
  `modelMatrices`, `skinMatrices` and `skin`. It holds no time and allocates nothing.
- **`samples/sandbox3d/walker.zig` and `samples/court/warden.zig` hold the same playback**, line
  for line: a tick, a weight, three 256-joint pose buffers, and a `clip()` that converts an
  asset's tracks into `anim.Track`s. That conversion runs on the stack and calls `Clip.validate`,
  which walks every key, on every evaluation. This is the second consumer ADR-0058 waited for.
- **`render3d.Content`** owns the only path from a model to its skeleton and clips (`skeletonOf`,
  `clipOf`). A simulation tick cannot use it without a renderer, and root motion and events are
  simulation.
- **`asset`** has `foundry:skeleton`, `foundry:animation` and `foundry:model` v2, whose `clips`
  list maps a name to a generated ID. `.fskel` keeps joint names. `asset`'s build grants are
  `core`, `data` and `platform`.
- **`scene`** has `foundry:transform`, `foundry:parent` and the unsaved `foundry:world_transform`,
  opted into by `World.enableHierarchy`. Its build grants are `core` and `data`, narrower than
  CLAUDE.md §4.3's line. `derive.componentType` takes `u32`, `u64`, `f32`, `f64`, `ContentId`,
  `Entity` and nested structs. It refuses arrays and pointers. `.fsav` needs no change for a new
  type.
- **`samples/sandbox3d/orrery.zig`** is a world that saves and loads to `world.fsav`, from a key
  and from the tests.
- **The court's warden is not an entity,** and the court has no `scene.World` or save. Its
  `Game` runs in a live run and in a replay, and draws in neither. Its footsteps are counted by
  distance in `Game.step` (`warden_stride`), outside the hash.
- **The court's clip is walked at one speed.** The warden patrols at 1.0 m/s and chases at
  2.4 m/s on a clip whose stride is about 0.6 m/s, and it crosses a link in the walk pose.
- **`nav.AgentView`** reports `link` and `link_t` during a crossing, and the court's two links
  are both `jump`. The sandbox's climber uses a `drop` and a `ladder`, drawn as a box.
- **`debug`** has six built-in panels. The navigation panel prints a `nav.Report`, a value the
  game fills in through `Sources`.

## 3. `anim.Player`: playback as a value

**A new file in `anim`, on `core` alone.** ADR-0058's reasoning stands: a pure function of its
inputs, tested with no device. What changes is that `anim` now has a value that remembers, and
it still reads no clock.

```zig
pub const max_channels = 4;

pub const Channel = extern struct {
    clip: u64,      // the clip's name hash; zero is an empty channel
    anchor: f64,    // seconds into the clip at `ticks == 0`
    ticks: u64,     // ticks since the anchor
    speed: f32,     // zero or more, at most 16
    weight: f32,    // 0 to 1
};

pub const Player = extern struct {
    channels: [max_channels]Channel,
    fade: f32,      // weight a tick, for the channel being faded to
    newest: u32,    // which channel the rest are fading away from
};
```

**Four channels, because a cross-fade can be interrupted.** The two M24 needs cannot hold a third
request made during a fade without a pop. Each channel's weight moves toward 1 for the newest and
0 for the rest. A channel at 0 is emptied. A request for a clip that is still playing makes it
the newest again, so a walker that stops and starts mid-fade reverses smoothly and keeps its
phase. With all four in use, the lightest is replaced. M35 builds on channels and may ask for
more, and that is a schema version.

**A clip is named by the hash of its name, never by an index or a generated ID.** ADR-0055 numbers
generated clips in file order, so a re-export would make a saved index play the wrong clip. The
name is what `foundry:model` already asks a game to use. A collision between two names of one rig
is refused when the rig is built.

**Time is `anchor + ticks × dt × speed`, in `f64`.** It is folded in `f64` and cast to `f32` only
for `sample`. M24's `@as(f32, tick) * dt` keeps ADR-0058's rule against accumulation but loses
half a tick of resolution after a day. A value that is saved now has to run that long. A speed
change re-anchors, so changing speed never jumps the pose. **This moves the walker's replay pins
once** (§13). `dt` comes from the caller on each call, so a player holds no clock.

The calls, each deterministic and allocation-free:

| Call | Does |
| --- | --- |
| `play(rig, name, .{ .fade, .phase })` | Makes a clip the newest. `phase` is `.restart` or `.keep`, which starts it at the current clip's time, as the M24 cross-fade did. An unknown name is `error.UnknownClip`, and nothing changes |
| `setSpeed(speed)` | The newest channel's speed, re-anchored |
| `advance(rig, dt, &step)` | One tick: moves weights and times and fills `step` |
| `seek(rig, fraction, &step)` | Puts the newest channel at a fraction of its clip and fills `step` as if it had played there. A link's crossing uses it |
| `evaluate(rig, scratch, out)` | The blended pose. `scratch` is a caller's `Pose`, and `out` may be followed by `skinMatrices` |
| `finished(rig)` | Whether the newest channel's clip is one-shot and at its end |

`Step` is a fixed value: up to `max_step_events` (16) events in order, a `dropped` count, and the
tick's `Motion`.

**Evaluating needs nothing but the player and the rig,** and nothing in the pose is state. That
is why a saved world holds no pose, and why a load's first evaluation equals the run's (§7).

**`anim.Rig` is a skeleton and its clips made ready,** as borrowed values:

```zig
pub const Rig = struct {
    skeleton: Skeleton,
    clips: []const RigClip,   // sorted by name hash
    start: u64,               // the clip a new player begins
    motion_joint: u16,        // or no_parent
};

pub const RigClip = struct {
    name: u64,
    clip: Clip,
    loop: bool,
    speed: f32,               // authored rate, multiplied into the channel's
    motion: bool,
    motion_speed: f32,        // metres a second at speed 1, measured when the rig is built
    events: []const Event,    // sorted by `at`
};
```

`Rig.validate` refuses by name, and it is the last validation. A clip is walked key by key once,
when the rig is built, and never on a tick. A player holding a name the rig does not have, which a
reload or a removed mod can cause, is not a programmer error. `advance` empties that channel and
counts it, and a player left with none starts `start`. Saved data is untrusted (§7), so `advance`
also empties a channel that is not finite or is out of range.

## 4. `foundry:animation_set`: what a clip means (`asset`)

glTF carries no loop flag, no events and no root joint, and a clip's records are generated by the
import. So a clip's meaning can't live in the clip. It is one hand-written record per model, and
a mod overrides that record to retime a footstep without touching an asset or restating a model:

```fdt
foundry:animation_set sandbox3d:walker.set {
    model sandbox3d:models.walker
    start "idle"
    motion_joint "pelvis"
    clips [
        { name "stride" motion true events [
            { at 0.0 event sandbox3d:event.footfall }
            { at 0.5 event sandbox3d:event.footfall }
        ] }
        { name "turn" loop false motion true speed 1.2 }
    ]
}
```

| Field | Type | Rule |
| --- | --- | --- |
| `model` | id | A skinned `foundry:model` |
| `start` | string | A clip of the model. Default: the first clip the model lists |
| `motion_joint` | string | A root joint of the skeleton. Required if any clip has `motion` |
| `clips` | list, optional, at most 256 | Clips the set says something about. A model's clip not listed plays looped at speed 1, with no motion and no events |
| `clips[].name` | string | A clip of the model, once only |
| `clips[].loop` | bool, default true | |
| `clips[].speed` | f32, default 1 | Above 0, at most 16 |
| `clips[].motion` | bool, default false | §6 |
| `clips[].events` | list, optional, at most 64 | §5 |
| `events[].at` | f32 | A fraction of the clip, from 0 up to but not including 1, or exactly 1 on a one-shot clip |
| `events[].event` | id | A name the game listens for. It need not be a record |

**`at` is a fraction, not seconds,** so a retimed or overridden clip keeps its footsteps on its
feet. **An event is an ID and carries nothing else.** What it does is the game's (I5), and a
payload would need a shape M34 has no consumer for.

**The set is version 1, and no existing record changes:** `foundry:model`, `foundry:animation`,
`.fanim` and the importer are all untouched. `fpack` checks what one record can show: duplicates,
ranges and limits. What depends on other records is checked when a rig is built, since a mod may
override any of them.

**`asset.Rigs` builds them, and `asset` is granted `anim`.** It sits in `asset` because a
simulation needs a rig with no renderer, and because both `scene` and `render3d` could reach it
there. It is L2 taking L1, downward. It converts and does not evaluate, so ADR-0058's objection to
evaluation in `asset` stands.

- `Rigs.acquire(set_id)` reads the merged store, follows the set to the model, acquires its
  skeleton and clips through the ordinary loaders, and returns a `RigHandle` (I1).
- `Rigs.get(handle)` returns a `*const anim.Rig`, borrowed until the next `contentChanged`.
- `contentChanged()` rebuilds every rig at the game's generation seam, keeping handles. A bad
  candidate keeps the established reload policy. A rig that no longer builds answers null, and its
  users are told once.

Refusals, each named: `MissingSet`, `MissingModel`, `NotSkinned`, `UnknownClip`, `DuplicateClip`,
`NameCollision`, `UnknownJoint`, `MotionJointNotRoot`, `MissingMotionJoint`, `JointCountMismatch`,
`TooManyClips`, `TooManyEvents`, `EventOutOfRange` and `InvalidSpeed`. A diagnostic names the set,
the clip and the field.

**A rig reaches a tick at the seam a game already has.** Rigs change only in `contentChanged`,
which a game calls where it already rebuilds a walker (`Walker.refresh`). A reload is a change of
content, and a replay across one is not promised today by any sample.

## 5. Events

**An event fires when a channel's time crosses its `at`, on the half-open span `[before, after)`.**
That fires an event at 0 on the tick a clip starts, once a lap thereafter, and never twice on a
boundary. A one-shot's end closes the span, so an event at 1 fires on its last tick. A short clip
at a high speed may lap more than once in a tick, and each lap fires.

**Only the newest channel fires.** A clip fading out is on its way to being gone, and in a walk to
idle its next footfall is the one a person does not want to hear. A clip fading in fires from the
tick it begins.

**Order is a contract:** by time within a tick. `Step` holds 16, and more are counted in `dropped`
rather than lost silently, as `Game.events_dropped` is. A `seek` fires what it crosses, forward
only. A seek backward fires nothing, and it is what a restart needs.

Events are simulation. They come out of `advance` on the tick, in a replay as in a run, and a game
that plays a sound from one does so from the same tick it would have asked for it anyway.

## 6. Root motion

**A clip with `motion` carries the character's travel in its motion joint.** The joint must be a
root of the skeleton, since a child's translation is in a moving frame. `advance` takes the
joint's travel out of the pose and reports it:

```zig
pub const Motion = struct {
    translation: Vec3,  // metres this tick, in model space, X and Z
    yaw: f32,           // radians about +Y this tick
};
```

- **The pose keeps the joint's height,** so a stride's bob stays in the animation. Its X and Z
  are held at the clip's first key, and its yaw is removed by a twist about model up.
- **Across a loop,** the delta is the rest of this lap, whole laps, and the start of the next, so
  a stride covers the same ground at any frame rate of keys.
- **Blended,** a channel's delta is weighted by its share. A clip with no motion contributes
  nothing but its weight, so a walk fading to idle slows down instead of stopping.
- **`skeleton.root` is applied,** so `front` from an import and any baked ancestors turn the
  delta into model space. The twist axis is model up in the joint's own frame.
- **It uses no trig on a tick.** A delta is a difference of keys, and the twist is a projection.
  The yaw angle comes from `core`'s own arithmetic, so a pin does not depend on a linked libm.

**Root motion is a wish.** `anim` moves nothing, exactly as `nav.Crowd` moves nothing: the game
rotates the delta by its body's facing and calls its controller, which may refuse it. A blocked
figure keeps walking on the spot. That is the game's to notice, and there is no correction back
into the clip.

**`motion_speed` is the same data read another way.** A rig measures each motion clip's average
ground speed when it is built. A game that moves its body by other means, like the warden on its
crowd, can then set `speed = actual ÷ motion_speed`, and the feet keep up. The clip's travel is
still removed from the pose, and only the rate is used. So one clip serves both kinds of body.

## 7. `foundry:animator` and `foundry:root_motion` (`scene`)

**`scene` is granted `anim`, and a world opts in** with `World.enableAnimation`, as it does with
the hierarchy. Two types:

- **`foundry:animator`, saved and authorable:** `set`, a `ContentId`, and the player's state.
  Authoring names only the set, and the rest default to a player that starts `start` on its first
  tick. It is an `extern struct` with `anim.Player`'s layout, like `scene.Transform` over
  `core.Transform`, with four nested channels `c0` to `c3` because `derive` takes no arrays. A
  layout check and two bit casts keep the two the same.
- **`foundry:root_motion`, derived and unsaved:** this tick's `Motion`, like
  `foundry:world_transform`. Only an entity with a motion clip gains one.

**`scene` still sees no asset.** Its calls take a `RigSource`, a context and a function from a
`ContentId` to `?*const anim.Rig`. A game passes `asset.Rigs`, and a test passes a hand-built
rig, so `scene`'s tests stay hermetic and CLAUDE.md §4.3's `asset` grant stays unused.

| Call | Does |
| --- | --- |
| `animation.advance(world, rigs, dt, events)` | Every animator, in entity order. Writes each `foundry:root_motion`, and appends `{ entity, event }` to a game's bounded list, counting what does not fit |
| `animation.evaluate(world, entity, rigs, scratch, out)` | One entity's pose into a game's buffers |
| `animation.player(world, entity)` | The entity's `*anim.Player`, for `play`, `setSpeed` and `seek` |

**It is a function, not a registered system.** A game's order matters here: it decides what to
play, then advances, then moves bodies with the deltas, then propagates. A `System` can wrap it
in one line for a game that wants one.

**Saving.** A save holds the set's ID and each channel: name hash, anchor, ticks, speed, weight.
It holds no pose, because a pose is a function of those and the rig. A load therefore reproduces
the pose exactly, and a save stays small: 128 bytes of channels for a character with 256 joints.
`.fsav` needs no change. A save whose set is gone leaves the animator in the world, unadvanced and
counted, and it resumes if the set returns. Its clip being gone is §3's rule.

**A saved or mod-written animator is untrusted,** so its deserializer refuses non-finite values,
and `advance` holds §3's rule for a raw component write no deserializer saw. Neither asserts.

## 8. The panel (`anim`, `debug`)

**`anim.Report`** is a plain value with no pointers, as `nav.Report` is: players counted, the rows
of up to eight, each with a label, up to four channels (clip name, time, duration, weight, speed),
this tick's events and motion, and totals for events fired, events dropped and channels emptied. A
game fills it through `Player.report`, passing the rig and a label. `debug` is granted `anim`
and `Sources` gains `animation: ?*const anim.Report`.

The panel prints it, says so when a game reports none, and has no write path (ADR-0025). The seven
built-in panels register through the same call a game's does. Joints drawn in the world are a
view, and M111's preview owns those.

## 9. The characters

**The generators gain clips, and the existing ones keep their bytes.** A shared `scripts/m34/clips.py`
gives `make_character.py` and `make_court.py` four more, appended after `idle` and `walk`:

| Clip | What it is |
| --- | --- |
| `stride` | `walk` with the pelvis travelling forward: 0.6 m in a one-second loop |
| `turn` | A one-shot quarter turn of the pelvis to the left, with a step |
| `jump` | A one-shot crouch, tuck and reach |
| `drop` | A one-shot step off and a fall, arms out |
| `climb` | A looped ladder climb |

Appending keeps `clip0` and `clip1`, and the `.fmesh`, identical. Step 6 compares their bytes.

**The walker and the warden each move onto `anim.Player`,** and their copied poses, tick, weight
and `clip()` go. `render3d.Content.skeletonOf` and `clipOf` stay, since they are published
behaviour of a `Content`. A walker that has only `idle` and `walk` in its set behaves as it did.

## 10. `sandbox3d`: the pacer, a figure that saves

**An entity in the orrery's world,** with `foundry:transform`, `foundry:animator`, and a
controller in the walk world on the walker's layers. It is the sample's first skinned entity.
Its record, `sandbox3d:pacer.main`, says how many strides make a side. Each tick it plays `stride`
for that many laps, plays `turn`, and repeats. Its speed and every corner come from its clips, so
it walks a square that the record does not describe in metres. A motion delta rotated by its yaw
goes through `moveCharacter`, and the result goes back to `foundry:transform`.

**The existing save key saves it.** On a load its feet come from `foundry:transform` by
`setCharacterFeet`. A tour stage saves at a fixed tick in mid-stride, runs on, loads into a fresh
world, runs the same ticks, and requires the same hash of pose, feet, motion and events.

**A content mod retimes it:** `pacer_quick`, in the sample's testdata, overrides
`sandbox3d:walker.set` to move a footfall and double `stride`'s speed, with no code. A wider
square is the visible result, and it is what a mod's reach here means.

## 11. The court

- **The warden's walk is `stride`,** with `speed` set each tick from its actual speed over
  `motion_speed`, so its feet match at 1.0 and at 2.4 m/s. Its body stays on the crowd's wish, so
  **no script's route moves** and every tick assertion holds.
- **Footsteps become events.** `court:warden.set` puts `court:event.footfall` at each foot plant,
  and `Game.step` turns it into its existing `warden_step`. `warden_stride`, `warden_walked` and
  the sound set's `warden_step_distance` go. The events stay outside the hash, as they were.
- **A crossing plays a clip.** When `AgentView.link` begins, the warden plays the clip for the
  link's kind, named in `court:warden`'s new `link_clips`, and `seek`s to `link_t` each tick, so a
  jump of any length fits the arc. A `court:event.land` at its end plays the land sound.
- **The agent's record names the clip, not the link.** A link is a place, and two bodies crossing
  it may not move alike. So `nav` and `foundry:nav_mesh` don't change.
- **The rig is resolved once in `Game.init`,** and held by handle, so a replay runs the same player
  on the same ticks with no renderer involved.

**The sandbox's climber** becomes a walker figure, playing `drop` and `climb` by the same rule, so
all three link kinds run in a sample.

## 12. The public ABI, and platform assessment

**Nothing enters the public table.** M48 publishes it: `play`, `seek`, events and motion for a
mod's entity, and a skinned instance, which `render3d.Instances` refuses today as `Unsupported`.
Its line in the roadmap gains this at the close. The API is drawn for a table regardless: values,
caller-owned buffers, named refusals and no callbacks except `RigSource`, which a table would
replace with a handle.

- **Metal:** the first run of everything.
- **Windows/Vulkan on the PC is needed,** once, at Step 10: the pins on x86_64, the costs on the
  i3, and both samples relocated with validation. No backend, shader or RHI path changes. The
  PC has no Foundry clone, so it clones again, under the usual rules.
- **Linux: compile only.** Nothing here is Linux-specific (`3d.md` §10.2).

## 13. Verification, pins and budgets

**`anim`:**
- `Rig.validate`'s every refusal;
- time: `f64` folding, a re-anchor keeps the pose, a day's run keeps tick resolution, and speed 0
  holds;
- channels: a reversal mid-fade, a third and a fifth request, weights summing to 1, the lightest
  replaced;
- events: at 0, at a boundary, a double lap, a one-shot's 1, a fading channel silent, a forward
  and a backward seek, order, overflow counted;
- motion: a hand-computed straight clip, a loop boundary in the same total at 30 and 60 Hz, a
  blended deceleration, the joint held in the pose with its height kept, yaw through a twist, a
  rotated `skeleton.root`, and `motion_speed`;
- untrusted state: a NaN, a huge speed and an unknown name each empty a channel, never assert;
- the player replay: 1,200 ticks twice in one process, with bytes equal and a pin per binary
  family, as `anim/tests.zig` does;
- nothing allocates, which is structural.

**`asset`:** the record round-trips; every §4 refusal; a model's unlisted clips get the defaults;
a set's override by a later package; a reload that keeps handles; a reload that breaks a rig.

**`scene`:** every field survives a save and a load; the layout check; a save whose set or clip is
gone; the deserializer's refusals; advance in entity order; the event list's overflow; a save at
tick N that continues byte-identical to the unsaved world. `root_motion` is absent from a save.

**`debug`:** no report said so, rows printed, and seven panels.

**The samples:** the walker and the warden hold byte-identical clip and mesh assets. A tolerance
test compares the walker's new poses with M24's formula, within 1e-4, across its 2,100 ticks,
**and then its two pins move once, with this reason recorded.** The player's `cb99ccfcf2b6d6c3`
does not move. The court's `win`, `caught`, `fell` and soundtrack runs keep every tick. The nav
pins do not move. `pacer_quick` changes the square with no code.

**Guards verified by mutation,** each named in its step's Resolution: the half-open event span,
newest-channel-only firing, the joint-held pose, the loop delta, the twist axis, the hash
collision refusal, the root-joint refusal, the raw-write check and the layout check.

**Budgets, measured inside the paced 60 Hz frame loop at ReleaseSafe, on the Mac and the PC:**

| What | Budget (p95) |
| --- | --- |
| `animation`: one figure's advance, evaluate and skin matrices (M24's zone) | 0.10 ms |
| `render.skin`, one figure (M24's zone) | 0.25 ms |
| `animation.advance` over 32 animators, no pose | 0.10 ms |
| The court's whole game tick (its `character` line) | 0.25 ms |

**By hand:** a person watches the pacer cross a save and a load, and plays the court, listening to
the warden's feet and watching it jump. That is criterion 8, and Step 9 hands the owner a build.

## 14. Implementation order — eleven bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit. There
is no automatic chaining.

### Step 1 — `anim`: `Player` and `Rig`

§3 without events or motion: the values, `validate`, channels, time, `play`, `setSpeed`, `advance`,
`evaluate` and `finished`, with §13's time, channel, untrusted-state and replay tests. **Exit:** a
player cross-fades through interrupted requests with no device and no asset, and its replay is
byte-identical.

### Step 2 — `anim`: events and root motion

§5 and §6: `Step`, `seek`, `Motion`, the held joint, `motion_speed`, and `Report`, with §13's event
and motion tests. **Exit:** a hand-computed clip's events and travel are exact at two tick rates,
and every mutation in §13 for them fails a test.

### Step 3 — `asset`: `foundry:animation_set` and `Rigs`

§4: the schema, `fpack`'s checks, the `anim` grant, `Rigs` and its reload. **Exit:** a set compiled
from text builds a rig with no renderer, every refusal is named, and a reload keeps handles.

### Step 4 — `scene`: `foundry:animator`, saved with a world

§7: the grant, the two types, `enableAnimation`, `advance`, `evaluate` and `RigSource`. **Exit:** a
world saved mid-stride and loaded continues byte-identical to the one that was not, in `scene`'s
hermetic tests.

### Step 5 — `debug`: the animation panel

§8: the panel and `Sources.animation`. **Exit:** seven panels, the panel prints a report and says
so when there is none, and `debug` has no write path.

### Step 6 — The clips, and the walker on `Player`

§9: `scripts/m34/clips.py`, both generators, and `walker.zig` on `anim.Player` through `Rigs`.
**Exit:** existing clip and mesh bytes are unchanged, the tolerance test passes, the walker's pins
move once with the reason recorded, and the player's pin does not move.

### Step 7 — `sandbox3d`: the pacer

§10: the record, the entity, root motion through a controller, the save-and-load tour stage,
`pacer_quick` and the panel. **Exit:** from a relocated ReleaseSafe install on Metal, the tour
passes across a save and a load, and `pacer_quick` changes the square with no code.

### Step 8 — The court: the warden's stride and footfalls

§11's first two points: the warden on `Player`, its speed matched, events for feet, and the
distance count removed. **Exit:** `win`, `caught`, `fell` and the soundtrack replay on the ticks
they did, with `warden_step` now from events.

### Step 9 — A clip on a link

§11's rest: `link_clips`, `seek` by `link_t`, the land event, and the sandbox's climber. The owner
gets a build, and criterion 8 is theirs. **Exit:** all three link kinds play a clip in a sample,
replays hold, and the owner has played it.

### Step 10 — Windows/Vulkan

The native suites, the pins on x86_64, both samples relocated with validation, and the i3's costs.
**Exit:** every suite and run passes on the PC, and the budgets in §13 are read there.

### Step 11 — Close M34

This step resolves:
- `animation3d.md` §14's rows for the component, root motion, events and the panel, and ADR-0058's
  playback sentence, by a dated note pointing to ADR-0071;
- `agents.md` §6.3 and §15's link row, and `playable3d.md` §13's row;
- `public3d.md` §14's animation row, and the roadmap's M34 and M48 lines;
- CLAUDE.md §4.1's new row, §4.3's `asset`, `scene` and `debug` grants, with `scene`'s line corrected to the
  build, which gives it no `asset`, and §9's row;
- `docs/modding/content-mods.md`, which gains `foundry:animation_set`;
- AGENTS.md's bar if it changed, the design index and `PROJECT_STATE.md`.

Tag `m34`, push when asked, and stop before M35's design. **Exit:** every document names M34
complete, and none names a contract the code does not have.

## 15. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| State machines, layers, masks and additive poses | M35 | Built on channels. A fifth channel, or a layer, is a schema version of `foundry:animator` |
| Keeping two clips of different lengths in step (sync groups) | M35 | `.keep` copies the time, which is right only for clips of one length, as all here are |
| A clip played backward | M35 | A negative speed is refused today, since §5's span runs one way |
| A body correcting a clip it was blocked from following | M36 | Foot placement is where a clip gives way to the world |
| Foot locking during a matched speed | M36 | |
| Animation in the public table and in Lua, including skinned instances and event subscription | M48, M49 | §12 |
| A third-person player on this | M50 | |
| A ragdoll taking over from a pose | M54 | |
| Events and clips moved by an authoring view | M111 | With joints drawn in the world. `.fdt` is the authoring path until then |
| Clip compression, and a rig's memory with it | M76 | |
| Pose replication | M128 | A pose is a function of `Player` and the rig, so what replicates is the player |
| Advancing animators on `core.Jobs` | M100 | Measured against §13's 32-animator budget |

## 16. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | Playback is `anim.Player`, a fixed value in `anim`, on `core` alone, with four channels and no clock (ADR-0071, answering ADR-0058's revisit) | §3 |
| 2 | A clip is named by its name's hash, never by index or generated ID, and a collision is refused | §3 |
| 3 | Time is `anchor + ticks × dt × speed` in `f64`. **This moves the walker's two replay pins once**, proved first by a 1e-4 tolerance against M24's formula | §3, §13 |
| 4 | `anim.Rig` validates once, when it is built. `Clip.validate` no longer runs on a tick | §3 |
| 5 | `foundry:animation_set` says what a clip means, one record a model. Loop, speed, motion and events never enter a clip's bytes, so `.fanim`, `foundry:model` and the importer don't change | §4 |
| 6 | `asset` is granted `anim`, and `asset.Rigs` builds rigs below the renderer, so a simulation needs no `render3d` | §4 |
| 7 | An event is an ID at a fraction of a clip, carrying nothing else. It fires on `[before, after)`, from the newest channel only, in time order | §4, §5 |
| 8 | Root motion is a wish: a root joint's X, Z and yaw leave the pose and are reported, its height stays, and the game moves the body (ADR-0071) | §6 |
| 9 | `motion_speed` lets a body moved by other means match its feet, so one clip serves both | §6, §11 |
| 10 | `scene` is granted `anim` and not `asset`. `foundry:animator` is saved and `foundry:root_motion` is derived; a world opts in; a save holds no pose | §7 |
| 11 | `animation.advance` is a function a game calls in its own order, not a registered system | §7 |
| 12 | `debug` is granted `anim`, and the seventh panel prints an `anim.Report` | §8 |
| 13 | The court's warden stays a plain value, not an entity. The component's consumer is `sandbox3d`'s pacer, and the court still saves nothing | §10, §11 |
| 14 | The warden's body stays on the crowd, so no route moves. Only its clip rate and sounds change, and footsteps become events | §11 |
| 15 | A link's clip is named by the agent's record, by link kind, not on the link. `nav` and `foundry:nav_mesh` don't change, and `seek` fits a clip to `link_t` | §11 |
| 16 | Nothing enters the public table; M48 publishes it and its line gains this at the close | §12 |
| 17 | The PC is needed once, at Step 10; Linux is compile-only | §12 |
| 18 | Budgets: M24's two, 32 animators at 0.10 ms, and the court's tick unchanged at 0.25 ms | §13 |
| 19 | The owner's watch and play is criterion 8, at Step 9 | §13 |
