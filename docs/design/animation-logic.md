# Design: M34 — Animation logic I: playback, a saved component, root motion and events

**Status:** Accepted 2026-10-31, when the owner asked for Step 1, with §16 as written. Each step's
Resolution follows §16.
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

## Resolution — Step 1: `Player` and `Rig` (2026-10-31)

**Acceptance.** The owner's "Begin" accepted §16 as written. ADR-0071 is Accepted and is in
CLAUDE.md §4.1. §4.3's lines change at the close, when the grants have been made.

**What exists.** `anim/rig.zig` has `Rig`, `RigClip`, `clipName`, `find` and `validate`.
`anim/player.zig` has `Channel`, `Player`, `Step`, `play`, `setSpeed`, `advance`, `evaluate`,
`finished` and `playing`. `anim/player_tests.zig` adds 22 tests. Nothing outside `anim` uses them
yet, and no pin elsewhere moved.

**What the design had not settled, and the answers:**
- **A player keeps its step size in `dt`.** §3 has `evaluate` take no `dt`, but a channel's time
  needs one. So `advance` stores it, which also makes a load's first evaluation right with no
  argument. It isn't a clock: it is what `ticks` are counted in. If the step changes, `advance`
  re-anchors first, so ticks already counted keep their worth.
- **`fade` is seconds, not weight a tick.** §3's field comment can't be met, since `play` has no
  `dt`. It also gives M24's `dt / cross_fade` exactly.
- **`Player` is 144 bytes:** 128 of channels, then `fade`, `newest` and `dt`, and padding. A test
  pins the layout, since `foundry:animator` lays over it in Step 4.
- **`.keep` and `.restart` both apply to a clip still playing.** §3 said such a clip always keeps
  its phase, which would leave a one-shot played twice stuck at its end. So `.restart` begins it
  again, in any channel, and `.keep` leaves its own time alone. A walker uses `.keep`, as M24's
  shared clock did. `.keep` on a new clip takes the newest clip's unfolded time.
- **Weights sum to 1, by sharing.** The newest moves toward 1, and the rest share what is left in
  proportion. So an interrupted fade loses no weight, and all the old channels finish together.
  `evaluate` still normalises as it blends, since a replaced channel's weight is gone for a tick.
  A fade with nothing to fade from is at full weight at once.
- **`setSpeed` does nothing for an unchanged speed,** so a game calling it every tick doesn't
  re-anchor every tick. It takes the rig, which §3's table left out, because the rate reads the
  clip's authored speed.
- **`play` gains a `speed` option,** defaulting to 1, so a new clip needn't start at the wrong rate
  for a tick.
- **`evaluate` is `const` and skips what it can't use,** without emptying anything; only `advance`
  repairs. With nothing usable it shows the start clip's first frame, so a new player can be drawn
  before its first tick. That tick begins the clip, and counts as its first.
- **A clip is capped at 1,024 per rig,** which is what a model may list. §4's 256 caps a set's
  listed clips, and that is Step 3's.
- **`Step` holds only `lost` for now.** Events and motion join it in Step 2.
- **A rig refuses a name that hashes to zero,** `UnnamedClip`, since zero marks an empty channel.

**Tests.** Every `Rig.validate` refusal; time, wrapping, one-shots, the rate, re-anchoring on speed
and on step, a day's run resolving a tick, and agreement with M24's formula within 1e-4 across a
walker's 2,100 ticks; cuts, fades, reversals, third and fifth requests, `.keep` and `.restart`;
every `play` refusal changing nothing; a lost clip, a surviving channel, eight bad channels, and a
bad `newest` and `fade`, none of which assert; the layout; the replay.

**The replay** runs 1,200 ticks of cuts, fades, interruptions and a speed change, byte-identical
in one process. Its pin has two values for `tests.zig`'s reason: `f1d3c73ecbaab79c` where Zig's
`sin` is used, and `e9d45191bbdf1bd3` in an optimised arm64 build. `anim-test` passes 41 of 41 in
Debug and ReleaseSafe on arm64, and in both under Rosetta.

**Guards verified by mutation.** Twenty-six were tried and restored. Twenty-four failed at once.
- **The first survivor was a missing test:** `play` with a fade and nothing to fade from. A test
  now covers it, and its mutation fails.
- **The second was a redundant line:** `repair`'s check of `dt`. `time` already refuses a bad step
  and `advance` overwrites it, so the line is gone.

The rest are the `f64` time, the clip's rate, both re-anchors, the one-shot hold, `finished`,
`.keep`, `.restart` on a live clip, the lightest replaced, the cut, the weight share, normalised
blending, all three `play` refusals, the sanity check, starting from nothing, the survivor taking
over, and five rig refusals plus the rig's clip validation.

**Exit met:** a player cross-fades through interrupted requests with no device and no asset, and
its replay is byte-identical. Bar 2,643/2,653 (ten skips), 128/128 steps. Every command exits 0.

## Resolution — Step 2: events and root motion (2026-10-31)

**What exists.** `anim/motion.zig` has `Motion`, `hold`, `travel` and `groundSpeed`. `anim/report.zig`
has `Report`. `Player` gains `seek`, and `Step` gains `events`, `dropped` and `motion`. `RigClip`
gains `motion`, `events` and `label`, and `Rig` gains `motion_joint` and `motionSpeed`. `pose.zig`
gains `sampleJoint`, sharing its track code with `sample`, whose bytes don't change.
`anim/step_tests.zig` adds 30 tests. Nothing outside `anim` uses any of this yet.

**What the design had not settled, and the answers:**
- **A delta is in the body's frame at the tick's start.** §6 said model space, which is wrong for a
  clip that turns as it walks: the body has already turned by what the clip has reached. So the
  delta is unturned by that much, and a game adds `yaw` to its facing and moves along
  `translation` turned by the old facing. A track straight in the clip's first frame then comes out
  straight, whichever way the body faced. Across a lap's end inside a tick, the next lap's travel
  is carried round by the turn so far.
- **`motion_speed` is not a field.** It is `Rig.motionSpeed(name)`, read off the clip when asked,
  since a stored copy could disagree with the clip. It is the net ground distance of a lap over
  its duration, at the authored rate, and 0 for a clip with no motion.
- **`seek` takes `dt`,** which §3 left out, because a fade carries on during a seek and the other
  channels run on. It replaces `advance` for that tick. On a loop it stays in the lap it is in, and
  a fraction is held to 0 to 1, with a NaN being 0. Going backward fires nothing and travels
  nowhere.
- **`RigClip` gains `label`,** the clip's name for a person, which §3 left out. The panel needs it,
  and a hash is no use to read. Step 3 fills it.
- **The yaw angle comes from `std.math.atan2`,** not `core`, which has none. It is Zig's own
  arithmetic on every target, so the pin still depends on no libm. Quaternions do the rest.
- **The frame is worked out on each call:** `Mat4.inverse` of the skeleton's root, in `hold` and
  `travel`. A rig is borrowed and can't cache it, and Step 3 can add a field if Step 6's
  measurement asks.
- **Both searches have bounds, for what a hostile package could ask.** A tick looks through 64 laps
  for events, then counts the rest. It works through 4,096 whole laps of travel. The event bound is
  more than tidiness: at a huge time, a lap more stops changing an `f64`, and the search would never
  end.
- **`Report.add` takes a game's label, the player, the rig and the tick's `Step`.** Rows stop at
  eight, and the rest are still counted.

**Tests.** Every new `Rig.validate` refusal. Events: at 0, a boundary landing exactly on a tick, no
loss or doubling at 30, 60 and 144 ticks a second or across speed changes, several laps in a tick,
overflow counted exactly, a clip of 10 µs, a time so far on that laps stop adding, a fading channel
silent, a one-shot's middle and end, and speed 0. `seek`: forward, backward, in a loop's lap, out
of range, a NaN, during a fade, and on a broken player. Motion: hand-computed straight travel,
loop boundaries at three tick rates, several laps in a tick, blended slowing, the joint held with its
height kept, yaw as a twist, a swing left in the pose, a clip that turns as it walks from two
starting facings, a rotated root for travel and for twist, and `motionSpeed`. The `Report`, and a
replay of pose, motion and events together.

**The replay** is byte-identical, and pinned at `ad558f6b1a182eac`, one value on all four builds so
far. Its rotations don't reach the inputs on which the two `sin`s differ. `anim-test` passes 71 of
71 in Debug and ReleaseSafe, on arm64 and under Rosetta.

**Guards verified by mutation.** Forty were tried and restored, and 31 failed at once.
- **Eight survivors were missing tests,** each now added, and each mutation now fails: a one-shot
  landing exactly on its end, the event lap bound, overflow inside a lap, `seek` keeping its lap,
  `seek`'s upper limit, the twist axis in `hold`, the root in `travel`, and a turn carried across a
  lap's end. The last two were real gaps in the proof of §6. The lap bound's test needed a time
  found by search, and with the bound gone that test hangs, which is its failure.
- **One survivor was redundant code:** clamping a one-shot's span, when `sample` already holds. It
  is gone.

**Exit met:** a hand-computed clip's events and travel are exact at two tick rates and more, and
every §13 mutation for them fails a test. Bar 2,673/2,683 (ten skips), 128/128 steps. Every command exits 0.

## Resolution — Step 3: `foundry:animation_set` and `Rigs` (2026-10-31)

**What exists.** `asset/animation_set.zig` has the schema, `check`, and readers for its fields.
`asset/rigs.zig` has `Rigs`, `RigHandle` and `BuildError`. `asset` is granted `anim`. `fpack` checks a
set where it compiles it, and `app` registers the schema as it does `foundry:nav_mesh`.
`zig build rigs-test` is a new target inside `test` and `check`, and its import list holds no
renderer, which is what it proves. No sample uses any of this yet.

**What the design had not settled, and the answers:**
- **A `*const anim.Rig` lasts until the next `acquire` as well as the next `contentChanged`,** since
  the pool can move. So a game keeps the handle and asks, as §4 already says of `RigHandle`.
- **A rig that stops building answers null, and can't keep what it had.** §4 mentioned "the
  established reload policy", but a rig borrows its keys from the registry, and a reload may have
  freed them. It is said once, and tried again at the next `contentChanged`. The handle lives on,
  and an `acquire` of a broken set returns why it is broken, holding nothing new.
- **Events in the wrong order are refused,** `UnsortedEvents`, rather than sorted. It is one code
  path fewer, and a person reading the record sees what a player does.
- **`Rigs.lookup(set)` answers by content ID,** for `foundry:animator` in Step 4. It reads only
  sets someone has acquired, through a map, and acquires nothing.
- **`acquire` is synchronous** (ADR-0062 keeps it so). There is no `request`, because a skeleton and
  a few clips are small. `render3d.Content` already holds the same assets where a model is drawn.
- **`check` runs again when a rig is built,** not only at `fpack`. A mod's package is untrusted
  whatever made it, and a package no compiler checked has its own test.
- **A rig's clip labels are copied.** The store is replaced at a reload, and a label would dangle.
- **`MissingMotionJoint` is `check`'s,** since one record shows it, and `motion_joint` being a root
  is `anim.Rig.validate`'s, reached by name. `DuplicateClip` joins §4's list, and `InvalidSpeed`,
  `TooManyEvents` and `EventOutOfRange` are refused by both, so a rig stays safe however it was made.

**No `dist` staging was needed.** No sample's content and no file kind changed: a set is a record,
with no bytes of its own.

**Tests.** `animation_set.zig` has 4: reading with defaults, a set that is only a model, every
refusal at its boundary, and both limits one past. `animation_rigs.zig` has 11, over the real
compiler, store and registry: a set compiled from text builds a rig that plays and reports the
right events and travel; a model's unlisted clips; one rig counted; every refusal needing another
record, each leaving no rig and no asset held; a clip for another skeleton, and a file that won't
load; a compile's diagnostic naming the record; a package no compiler checked; a reload that follows
the set and the clips; a later package's override winning with no asset restated; a broken reload
mended under the same handle; and out of memory at every allocation.

**Guards verified by mutation.** Thirty-one were tried and restored, and 27 failed at once. All four
survivors were missing tests, now added, and each mutation now fails: `check` at build, a model with
an empty clip list, a set's `loop` reaching the rig, and acquiring a set again after its last
release.

**Exit met:** a set compiled from text builds a rig with no renderer, every refusal is named, and a
reload keeps handles. Bar 2,688/2,698 (ten skips), 130/130 steps. Every command exits 0.

## Resolution — Step 4: `foundry:animator`, saved with a world (2026-10-31)

**What exists.** `scene/animation.zig` has `Animator`, `RootMotion`, `Types`, `RigSource`, `rigSource`,
`Events`, `Options`, `Summary`, `advance`, `evaluate`, `player`, `animatorOf` and `motionOf`.
`World.enableAnimation` opts a world in. `scene` is granted `anim`, `foundry:animator` joins the
schemas content may author, and `anim.Player.sane` says whether a player's values are in range.
`.fsav` did not change. `zig build scene-test` is a new focused target. No sample uses any of this
yet.

**What the design had not settled, and the answers:**
- **`advance` takes `Options` and returns a `Summary`.** §7 gave it an events list. A game may want
  none, and Step 5's panel needs a `Report` filled per animator, so both are optional. `Summary`
  counts animators, unresolved animators, lost channels, events, and events dropped.
- **Root motion is added in a pass of its own,** before the tick, since adding a component during a
  query is a structural change. So `advance` can allocate, on the tick an entity first needs one,
  and a load comes back through the same pass. An allocation failure leaves the whole tick undone.
- **"Carries motion" is `rig.motion_joint` being set,** not a walk of its clips, so the question is
  one comparison on every tick. An entity whose set names a motion joint gets the component even
  while it plays a clip with no motion.
- **Entity order is imposed on the list.** The dense store's order is its history, which a query says
  not to rely on. So `advance` walks it and then sorts this tick's part of the list by slot,
  stably, which keeps each entity's events in time order and leaves anything already in the list
  alone. What overflows is still decided in store order, which a save preserves.
- **A save with a bad value is refused whole, as `SaveCorrupt`.** That is what `save.zig` does with
  any deserializer's refusal, and `foundry:transform` is the same. The repair in §3 is for what no
  deserializer saw, a raw write. A template with a bad value fails to spawn, `ValueOutOfRange`.
- **`rigSource` is generic,** over anything with `lookup(set)`, because `scene` can't name
  `asset.Rigs`. A rig has to have been acquired for `lookup` to find it, so a game acquires what its
  world uses. Until then an animator is unresolved, which is the same state as a removed mod.
- **One buffer serves every rig:** `evaluate` takes two slices of at least the joint count and answers
  the count, so a game keeps one pair of 256.
- **`scene-test`** joins `asset-test` and the others in `build.zig`, for a focused run.

**Tests.** Fourteen in `animation.zig`, all hermetic, on hand-built rigs: both types registered once;
a world without animation; a body's move each tick and a game reaching the player; no root motion
without a motion joint; `evaluate`'s refusals; entity order, time order and overflow; a list that
already holds events; **a world saved mid-stride, whose first pose and next 240 ticks of pose, motion
and events are byte-identical to the unsaved world's, in a save no bigger after play**; seven bad
values each refused in a save; a set gone and returning; a raw write repaired; a report; out of
memory leaving the tick undone; and authoring by naming a set.

**Guards verified by mutation.** Twenty-three were tried and restored, and 22 failed at once. The
survivor was redundant code: `enableAnimation`'s own check for a late call, which `registerComponent`
already makes. It is gone. The layout check is `comptime`, so its proof is that swapping two fields
of `Animator` stops the build on that assertion.

**Exit met:** a world saved mid-stride and loaded continues byte-identical to the one that was not,
in `scene`'s hermetic tests. Bar 2,702/2,712 (ten skips), 130/130 steps. Every command exits 0.

## Resolution — Step 5: the animation panel (2026-10-31)

**What exists.** `debug/animation_panel.zig` is the overlay's seventh built-in panel, registered
through `addPanel` as the other six are. `Sources.animation` is `?*const anim.Report`, and `debug` is
granted `anim`. No sample fills it yet, so each says "no animation reported" until Step 7's pacer
and Step 8's warden do. `zig build debug-test` is a new focused target.

**What the design had not settled, and the answers:**
- **A game fills a report through `Report.add`,** as Step 2 built it, not `Player.report` as §8 says.
  `Options.report` in `scene.animation.advance` does the same for a world's animators. A report
  accumulates, so a game resets it each tick.
- **An empty report says "no players",** which is different from no report at all, as the navigation
  panel's "no mesh yet" is.
- **A row prints its move only when there is one:** metres this tick, and radians. Either a walk or a
  turn on the spot counts. Dropped events and emptied channels are warnings, and print only when
  non-zero. Players past the eight rows are "and N more".
- **Counts out of range read no further than the arrays.** A report is a value a game can write, and
  ADR-0025 says to validate what a mod could supply, so `row_count` and `channel_count` are clamped
  in the panel, and `name_len` in `anim`'s `label()`. A label cut mid-codepoint is safe, because the
  text layer already substitutes invalid UTF-8.
- **"No write path" is a test:** `Sources.animation` is exactly a const pointer, and a comptime walk
  finds no pointer anywhere in `anim.Report`, so nothing the panel holds leads back to a player.

**Tests.** Nine in `animation_panel.zig`: no report; an empty report; a report's players, channels,
events, motion and warnings; a still player; a turn on the spot; a straight walk; counts out of
range; no write path; and the panel reached through a real overlay. `overlay.zig`'s count is seven.

**Guards verified by mutation.** Twenty-one were tried and restored against `debug-test`. The first
run was void, because that step did not exist and every build failed; the step was added and the
baseline checked first. Then 18 failed at once. The three survivors were real gaps, a straight walk
with no yaw and two unbounded names, and tests were added that catch them.

**Exit met:** seven panels, the panel prints a report and says so when there is none, and `debug` has
no write path. Bar 2,711/2,721 (ten skips), 130/130 steps. Every command exits 0.

## Resolution — Step 6: the clips, and the walker on `Player` (2026-10-31)

**What exists.** `scripts/m34/clips.py` gives both generators `stride`, `turn`, `jump`, `drop` and
`climb`, appended after `idle` and `walk`. The walker plays through `anim.Player` and `asset.Rigs`,
its record names `sandbox3d:walker.set`, and the sample owns one `Rigs`. Its copied poses, weight
and clip conversion are gone. The warden has the clips and doesn't use them until Step 8.

**What the design had not settled, and the answers:**
- **§9 says four clips and lists five.** The list is right: Steps 8 and 9 need all five.
- **The walker's record gains `set`,** after `model`. The model is still its own field, since a
  `Content` draws it, and `Rigs` is what follows the set.
- **`evaluate` and `refresh` lose `dt`.** A player keeps it, so a pose needs only a player and a
  rig.
- **A rig borrows keys, so a tick must never run between a reload and `Rigs.contentChanged`.** M24's
  walker re-read its clips on every evaluate and couldn't see this. The sandbox had the gap: **R**
  reloads in `keys()`, after that frame's seam and before its ticks. So the sample checks the
  generation again after `keys()`. Step 8 must do the same for the court if a reload can land
  between its seam and its ticks.
- **One walker hides this, and 16 don't.** A lone walker's release frees the rig and its `acquire`
  rebuilds it, so a missing `contentChanged` does no harm. Walkers sharing a rig keep a stale one.
- **The per-evaluate refusals are gone.** The old test corrupted live clips to reach them, and
  `rigs-test` now covers that when a rig is built, which is §3's rule. `refresh` still refuses a rig
  with no `idle` or `walk`, and a rig gone at a reload is `error.MissingRig` from `move` and
  `evaluate`.
- **A package keeps one copy of a string,** so the test's rename of `idle` renames the set's `start`
  too, and the rig still builds. `MissingIdle` is what reaches it.

**Two pins moved, and they became one.** The walker's replay is now **`655e865f98779129`**, for this
reason alone: time went from `f32` to `f64` (§3). `M24` in `walker_tests.zig` keeps the old formula
and checks every joint's translation, rotation and scale and the weight on all 2,100 ticks, against
a tolerance of 1e-4. The worst difference is 2.4e-6. The player's `cb99ccfcf2b6d6c3` didn't move.

The second pin, `fa431d9440d4cb2e`, was already stale. The code before this step gives
`62ed8c026c20482c` in the headless tour and in the test binary, Debug and ReleaseSafe alike, and the
new code gives one value in the same four. So the test now takes only the new pin. A windowed
ReleaseSafe run on Metal hasn't been measured, and Step 9's build is the first.

**Bytes.** `clip0`, `clip1`, `mesh0` and `skeleton0` compile to exactly what they did, compared
against a snapshot of the previous build for both models. The two models' four files are also
identical to each other. Pins in `walker_tests.zig` and the court's `walk_tests.zig` keep that
checked. Both generators reproduced the committed files before they changed. `stride`'s rotations
equal `walk`'s in both models.

**Tests.** The tolerance run; both byte pins; and on the real assets, `stride` at 0.6 m/s, `turn` a
yaw of pi/2 to the left, and `jump` and `drop` with no travel. The reload, refusal and settings
tests carry over to rigs, and a missing `set` is refused.

**Guards verified by mutation.** Sixteen were tried against a checked baseline, and 13 failed at once.
Three survived:
- **The cleared rig handle** was a test gap. It now has a test, which fails.
- **`self.player = .{}` was redundant,** since a zero-fade restart already resets, and it is gone.
- **The rig seam in `Sample.refresh` has no automated test.** It was proved by hand, in Debug, headless with 16
  walkers: 32 scripted reloads pass, and removing either the second check or `contentChanged`
  panics reading poisoned memory, at joint index 43690. One reload missed the window in the first
  case, because a headless frame doesn't always tick.

Separately, a `TooManyJoints` check was dead code, since `Rig.validate` already refuses that. It is
gone.

**Exit met:** existing clip and mesh bytes are unchanged, the tolerance test passes, the walker's
pins moved once with the reason recorded, and the player's pin did not move. Bar 2,714/2,724 (ten skips),
130/130 steps. Every command exits 0. `court` and `room` stage on macOS. Windows staging is
Step 10's.

## Resolution — Step 7: `sandbox3d`: the pacer (2026-10-31)

**What exists.** `samples/sandbox3d/pacer.zig` has `Pace`, the component `sandbox3d:pacer`, and
`Figure`, which holds what a load can make again: handles, a pose and the character. The orrery's
world has animation, and `sandbox3d:entity.pacer` is its eighth entity. It walks a 0.9 m square on
the southeast floor, drawn skinned, and the overlay's panel reports it. `sandbox3d:walker.set` now
says what `stride`, `turn`, `jump` and `drop` mean. `pacer_quick` is in the sample's testdata and its
installation.

**What the design had not settled, and the answers:**
- **§10's wider square can't come from counting laps.** A lap covers 0.6 m at any speed, so doubling
  `stride`'s speed would do nothing to a square counted in laps. A side is timed instead, against the
  clip as authored: `strides × duration`. So twice the speed is twice the ground, and §10's result
  holds. The record still says no distance.
- **`strides` is 1.5, a real number.** The clear floor there is about 2.08 m deep, so 1.8 m is the
  widest side that `pacer_quick` can have. A half lap is as good a place to stop as a whole one,
  because both feet are passing.
- **A corner is a cut.** A fade into `turn` shares its yaw with `stride`, and the turn comes up short.
  The pose barely pops, since `stride` is at a passing position and `turn` starts from rest. A side
  starts with a 0.1 s fade across a turn that has finished, which costs each side the same.
- **A figure starts on a corner,** so that every side starts the same way and the square closes. The
  first corner turns it to face west, and it goes round west, south, east and north.
- **`Pace` is saved beside the animator:** its side's ticks, corners, heading and fall. `foundry:
  transform` holds its feet. A save's values are refused by name before they reach the arithmetic.
- **`Figure.refresh` serves a reload and a load alike,** since what it remakes is the same. It keeps
  no state, so a reload keeps the figure's place.
- **The tour's load runs on a separate walk world,** with no player or walker in it. So the pacer's
  square has to stay clear of the player, which it does. Its mask is 1, as the walker's is, so a
  person standing in its way does block it.
- **`setCharacterFeet` forgets the ground, and here that changes nothing.** I expected a loaded figure
  to need a settling move, and added one. The mutation showed it made no difference on a flat floor,
  so it is gone. A figure saved on a step or a ramp has no such proof, and none is in this sample.

**Proof.** The tour saves at tick 100, in mid-stride, runs 600 ticks, loads into a fresh world and
walk world, runs the same 600, and requires the same hash of pose, matrices, feet, motion, heading
and events.
- The relocated ReleaseSafe install on Metal passes: 5 corners, 18 footfalls, a 3,675-byte save,
  replay `47f67027ff3a12b0`.
- With `pacer_quick` selected and no other change it passes too, at 31 footfalls, replay
  `ef5c24337f5f2925`.
- Those two runs keep the player's `cb99ccfcf2b6d6c3` and the walker's `655e865f98779129`. **That
  closes Step 6's open item:** windowed ReleaseSafe on Metal gives the same pin as the rest.

**Tests.** `pacer_tests.zig`: the square, each side between 0.85 and 0.9 m on its line, closing within
1 mm, with its heading wrapped and drawn; `pacer_quick` at twice the ground, within 1e-3; saves at
ticks 100, 150 and 30, each byte-identical for 600 ticks, in a save no bigger after walking; an event
counting in the hash by what it is; a fall at the limit and a stop; and a reload keeping its place,
with every refusal by name.

**Guards verified by mutation.** Twenty-nine were tried against a checked baseline, and 20 failed at
once. Of the nine survivors, six were test gaps, each now caught: the heading's wrap, the drawn
rotation, gravity, landing, the fall limit and events in the hash. The settling move was redundant
and is gone. Two can't fail here: no clip both turns and travels, so the order of yaw and move
changes nothing, and the Zig default for `turning` is overridden by the record. A first attempt at
the rerun failed its baseline on a wrong sign in a new test, which was fixed.

**`main.zig`'s F5 and F9 have no automated test.** A headless run proved them: F5 in mid-side at
x 2.265, F9 back to the same feet and the same pose hash, and a reload after it. They now log the
pacer's feet, which is what that read.

**Exit met:** from a relocated ReleaseSafe install on Metal, the tour passes across a save and a load,
and `pacer_quick` changes the square with no code. Bar 2,720/2,730 (ten skips), 131/131 steps. Every
command exits 0. `court` and `room` stage on macOS.

## Resolution — Step 8: the warden's stride and footfalls (2026-10-31)

**What exists.** The warden plays through `anim.Player`. Its copied poses, `weight` and `clip()` are
gone, and its record names `court:warden.set`. `Game` owns a `Rigs`, so a replay plays the same
player on the same ticks with no renderer. A `court:event.footfall` makes each `warden_step`.
`warden_stride`, `warden_walked` and the sound set's `warden_step_distance` are gone. `Warden.tick`
stays, since the hash reads it. The warden's clips for a link are Step 9's.

**The body did not move.** A digest of each tick's phase, player, gate, warden feet, heading, facing,
fall, mode and what it saw, and every event but `warden_step`, was taken from the code before this
step and compared afterwards:

| Script | Ticks | Digest, before and after | `warden_step`s now |
| --- | --- | --- | --- |
| `win` | 2,441 | `9ec8566cf9c09877` | 106 |
| `caught` | 92 | `81f804f7ab2c6538` | 3 |
| `fell` | 185 | `f1e54339e42864be` | 16 |

The headless scripted runs replay every tick against a fresh game, drop no sound, and the music is
clean. The hash still reads the weight, which is why the digest was needed: the weight's bits may
differ, and nothing has to agree with the old hash.

**What the design had not settled, and the answers:**
- **`Game` owns the `Rigs`,** not `main.zig`, so `TestEnv` and the replay need no new wiring. But a
  `TestEnv` moves its `Registry` by value, so `Rigs.assets` is set again by `refreshWarden`,
  `contentChanged` and `deinit`, each of which is handed the registry.
- **`stride_speed` is read once by `Warden.bind`,** at the same seam, rather than on every tick. It
  doubles as whether there is a rig to play: zero leaves the warden patrolling, undrawn and silent.
  Its set is a mod's to override, so a missing `idle` or `stride` is said, not refused.
- **A rate is capped at `anim.max_speed`.** A mod's `chase_speed` of 10 asks for 16.7, which `setSpeed`
  would refuse, and that would fail the tick.
- **A warden's walking starts with `.keep`,** so a pause never restarts a foot. A live clip keeps its
  phase, and a fresh one takes `idle`'s time.
- **`noon` restates `set`.** A required field is simpler than a default ID, and that is its only change.

**The warden now steps three times as often.** The old count was 0.9 m a step, and `stride` covers
0.6 m a lap, or 0.3 m a step. So at 1 m/s it steps 3.3 times a second, and in a chase at 2.4 m/s it
steps 8 times, with its legs at four times the clip's rate. That is what §11 asked for, with its feet
matching at both speeds, and whether it sounds right is for Step 9's criterion 8.

**The court now has a content seam.** It had none, and M24's warden re-read its clips on every
evaluate so it didn't need one. `main.zig` checks the generation after `beginFrame`, before any tick,
and rebuilds the game's rig and the replay's. A test does a real `reloadAll` and then evaluates, and
without the rebuild it fails on freed keys. That covers `Game.contentChanged`. **The lines in
`main.zig` have no such proof.** The seam fired on real reloads, in Debug, headless and on Metal, but
removing the rebuild there did not crash either run. So those lines are read, not mutated.

**A bug that was already here, and is not fixed:** a package changed under a Debug court crashes it.
`Text` borrows strings from the store, a reload frees them, and `hud.zig:122` reads them. The same
crash happens at Step 7's commit, and only Debug hot-reloads. It has nothing to do with animation,
so it is left for the owner to place.

**Tests.** Feet matching at both speeds, to 1e-4 m/s, and the cap. A replay's player byte-identical
on every tick, each `warden_step` from a footfall at the warden's feet, `idle` when it stands, and a
pause keeping its phase. A warden with no rig playing the same game undrawn, and one that loses its
rig ceasing to draw. A real reload, sets that stop giving it what it needs, and only a footfall
making a step. The weight in the hash, `idle` before the first tick, and a record with no set.

**Guards verified by mutation.** Twenty-five were tried against a checked baseline, and 15 failed at
once. Of the ten survivors, seven were test gaps, each now caught: the rate's cap, `idle` when
stopped, a pause's phase, the event filter, a stale pose, the weight in the hash and the first `idle`.
Two reset lines were redundant and are gone. One can't fail: a `stride` with no motion already reads
0. Two runs were void and were repeated: one had no `zig` on its path, and one's live reload never
fired.

**Exit met:** `win`, `caught`, `fell` and the soundtrack replay on the ticks they did, with
`warden_step` now from events. Bar 2,726/2,736 (ten skips), 131/131 steps. Every command exits 0.
`court` and `room` stage on macOS.

## Resolution — Step 9: a clip on a link (2026-10-31)

**What exists.** `court:warden` gains `link_clips`, and the warden plays that clip on a crossing, put
at `link_t` on each tick, so a jump of any length fits its arc. A `court:event.land` at the clip's end
makes `warden_land`, which plays the land sound where the warden is. In `sandbox3d`, the first climber
is a walker figure, with `CrowdDemo.bindFigure`, and it plays `drop` and `climb` by the same rule.
The court's two links are jumps, and the sandbox's are a drop and a ladder, so all three kinds run in
a sample. `nav` and `foundry:nav_mesh` did not change.

**What the design had not settled, and the answers:**
- **The crowd's last tick of a crossing is already off the link.** `Crowd.cross` clears the crossing
  when `t` reaches 1, so `seek` never sees 1, and an event there would not fire. So the figure
  remembers its link clip, and on the next tick seeks to 1 itself. That is the tick it lands.
- **That only matters on a crossing faster than the clip.** A slower one is so near the end that a
  plain tick runs past it anyway. Tests at a slow speed could not see the difference, and the test
  that does runs quicker than the clip.
- **`link_clips` is a nested record of three strings,** one for each `nav.LinkKind`, and required.
  `noon` restates it. A name the rig lacks reads as no clip, so the warden crosses in its walk, and
  that is said once. `bind` decides it, so a tick asks nothing of it.
- **A ladder is one lap of `climb`, however long the ladder.** `seek` stays in its lap, by Step 2's
  rule, and the sandbox's is short. So `link_t` covers one lap, and a long ladder would look slow.
- **A crossing fades in over 0.1 s,** and so does the climber's over 0.15 s, so a clip never snaps on
  at the edge. It takes the clip from its start, not `.keep`, so a jump always begins as a jump.
- **The climber has no controller.** The crowd still places it, so a figure adds a pose and nothing
  else, and a test holds its path identical to a pawn's with no rig. It falls with no horizontal
  motion, so with no clip for a drop it stands through the fall.
- **Warden and climber repeat about thirty lines.** They are in two samples, which share no module.
  M35's state machines are where a shared rule belongs, if one does.

**Replays held.** `win`, `caught` and `fell` keep the digests of Step 8's table, tick for tick.
A crossing's player is byte-identical in a run and its replay, and the climber's pose in two runs.
Scripted runs replay and drop no sound. The sample takes 32 reloads with 16 walkers and the climber.
A relocated ReleaseSafe install on Metal passes the tour with and without `pacer_quick`, and every
pin holds: the player's `cb99ccfcf2b6d6c3`, the walker's `655e865f98779129`, and the pacer's two.

**Tests.** The clip at `link_t` to 1e-3 on all three speeds; a fade on the first tick; one landing on
the tick the crowd lets go; no footfall on a crossing. A link gone from under a crossing, a set with
no clip for it, and a restart forgetting one. The climber's clips, its feet keeping up, `idle` when
it stops, a quick drop, a missing clip, a handle given back, and a replay to the bit.

**Guards verified by mutation.** Twenty-five were tried against a checked baseline, and 13 failed at
once. Of the 12 survivors, 11 were test gaps, each now caught, and the landing tick needed three
tries to find a speed that shows it. One was redundant: clearing the link clips when a rig goes, since
the rig's own guard stops first. It is gone.

**The court's panel.** The warden fills an `anim.Report` each tick, and the court hands it to the
overlay. It had not, so F1 there would have said no animation was reported.

**Exit, in part.** All three link kinds play a clip in a sample, and replays hold. **The owner has
not played it yet,** which is the rest of this exit and criterion 8. Bar 2,731/2,741 (ten skips),
131/131 steps. Every command exits 0. `court` and `room` stage on macOS.
