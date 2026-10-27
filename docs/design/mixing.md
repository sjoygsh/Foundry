# Design: M31 — Audio III: spatialisation, buses and effects

**Status:** Accepted 2026-10-27, when the owner asked for Step 1, with §16 as written. Step 1 is done; its Resolution follows §17.
**Date:** 2026-10-27
**Baseline:** `d8d6e42`, tag `m30`. M0–M30 are complete.
**Decisions:**
- These ADRs constrain it:
  - ADR-0023: Foundry mixes its own audio; `f32` interleaved end to end; resampling in the
    voice; one lock-free command ring; the callback cannot fail, allocate, lock or log. It
    said spatialisation "arrives with 3D if at all". M19–M26 brought 3D, and the roadmap's
    M31 line brings it.
  - ADR-0065 and ADR-0066: Foundry's own Vorbis decoder; streamed voices on the background
    pool; the sample clock, scheduled starts and `level × envelope` ramps; `audio.Music`.
    ADR-0066's third revisit trigger, "M31's buses arrive", fires here and §8.4 answers it.
  - ADR-0048: right-handed, +Y up, −Z forward, metres. The listener and emitters use it.
  - ADR-0041 and ADR-0064: engine record types live in `asset`, so `fpack` checks them
    without linking their consumer.
  - ADR-0031: host bootstrap, content defaults and bounded user preferences stay separate.
    The court's new volume sliders are preferences.
  - ADR-0013: deterministic-friendly, not bit-exact. ADR-0064's lesson: a pin must not depend
    on which `sinf` a binary linked.
- It proposes two ADRs:
  - [ADR-0067](../adr/0067-buses-and-effects-are-content-mixed-by-engine-nodes.md): the mix is
    a tree of buses described by `foundry:audio_bus` records, each with an ordered chain of
    engine-implemented effects (filter, delay, reverb, compressor, limiter) described by their
    own records. It runs in the callback over buffers allocated when the tree is built. A
    changed tree is swapped by one command. Mods configure effects and never supply DSP code.
    The arithmetic the callback needs (`exp2`, `log2`, sine) is written out in `core`.
  - [ADR-0068](../adr/0068-spatial-voices-are-placed-on-the-game-thread.md): a spatial voice
    has a position, and the mixer has one listener. Distance gain, constant-power pan and
    occlusion are computed on the game thread once per `update`, from
    `foundry:audio_attenuation` records. The callback then interpolates the gains across its
    next buffer. Output stays stereo. HRTF is M144's, Doppler M55's, and surround output is not
    planned.

## 1. Purpose and boundary

The roadmap's row (`docs/ROADMAP.md`, Phase 6) is the contract:

> M31 | Audio III | 3D spatialisation, mixer buses and effects; also a limiter and
> compressor, voice stealing by priority, loop points within a file, and seeking a sound by
> granule (a playlist resumed where it was left)

Other documents allocate work to M31 by name:
- **`audio.md` §11:**
  - question 1 (voice stealing): "goes to M31, whose buses give priorities something to
    attach to";
  - question 2 (buses);
  - question 5 (loop points within a file, with seeking).
- **`audio.md` §12:** spatialisation, effects, and "a real limiter or compressor". §5's clamp
  is "a safety net, not a mix bus".
- **`playable3d.md`:**
  - §6.2: "Position is the sample's arithmetic. The mixer has gain and pan and no listener
    (M31 adds spatialisation)."
  - §13's row: "3D spatialised audio and a listener — M31; the court's distance-and-pan
    arithmetic is the budget it must beat."
- **`music.md` §13** and ADR-0066's revisit: "A music bus replaces `Music` setting `level` on
  each of its voices". §8.4 shows why that is half right.

**The runnable result** is `samples/court` mixed as a 3D game is. After M31:
- **The warden is heard where it is.** Its steps, the gate and the beacons are spatial voices
  placed by the engine from the walker's eye. Behind the low wall or the gate's frame, the
  warden is muffled by occlusion, which the court decides with one ray against its collision
  world.
- **The court has a mix:** music, world (effects and ambience), and UI buses under a master.
  - The world bus carries a courtyard reverb and a gentle compressor.
  - The master carries a limiter, so twenty loud voices no longer clip.
  - Pausing muffles the world bus through a low-pass filter, swept over a quarter of a second.
- **The options menu has three sliders**, master, music and effects, kept in the court's
  preferences.
- **Music:** the title track plays an intro once and then loops its body, by loop points in
  its record. Leaving the calm music for the chase, then returning, resumes the calm track
  where it was left, by seeking.
- **Voices have priorities.** Footsteps give way to a beacon, and the music is never stolen.
- **`nocturne`,** the existing content mod, also lengthens the courtyard reverb and adds an
  echo to the music bus, with no code.

**Exit criteria** (§14 gives each one's measure):
1. **Seeking and loop points.** A seek to any frame of any fixture decodes exactly the samples
   a whole decode has there. A streamed voice with a loop region equals its resident decode,
   sample for sample, across three seams.
2. **Spatialisation.** Distance gain, pan and occlusion match §5's formulas on the stepped
   device. Summed power is constant across a pan sweep. A moving source's gains change across
   each buffer with no step. The court's own arithmetic (`sounds.zig`'s `place`) is deleted.
3. **Effects.**
   - Each filter's magnitude at f₀/2, f₀ and 2f₀ is within 0.1 dB of the RBJ formula.
   - The reverb's measured decay is within 10% of its `decay`, from 0.3 to 5 s.
   - The compressor's settled curve is within 0.25 dB of its static curve.
   - No limited output sample exceeds the ceiling, over a 32-voice full-gain stress and its
     mutations.
4. **Voice stealing.** The policy of §7 holds case by case. A higher priority is never stolen.
   A stolen voice fades to silence over exactly its fade.
5. **Determinism.** On the stepped device with immediate tasks, a sequenced mix through the
   court's full tree is the same every run. It is pinned by hash, and the pin is equal in
   Debug and ReleaseSafe and under x86_64.
6. **Cost.**
   - The callback mixes the court's full load at least 20 times faster than real time on the
     Arc PC's i3, in ReleaseSafe on one thread: 32 voices, 8 of them spatial, the whole tree
     and every effect.
   - Main-thread audio stays at most 0.10 ms at p95 in the court, now including placing
     spatial voices.
7. **Moddability.** `nocturne` changes the reverb and adds the echo with no code.
8. **The court.** Three scripted ten-minute runs each, from a relocated ReleaseSafe install on
   the M5 with Metal and on the Arc PC with Vulkan:
   - zero underruns, late starts and dropped commands;
   - no limited sample past the ceiling;
   - the sliders kept across a restart;
   - the scripted endings unchanged.
9. **Nothing else changes.** With no tree configured, the mixer's output is identical to
   M30's. M30's sequenced-mix pin and the 2D samples' sound are unchanged.

**In M31:**
- arithmetic `exp2` and `log2` in `core` (§3);
- the records (§4):
  - `foundry:sound` version 3, with `bus`, `priority`, `attenuation` and a loop region;
  - `foundry:audio_bus`;
  - five effect records;
  - `foundry:audio_attenuation`;
  - `foundry:music_playlist` version 2, with `resume`;
- seeking by granule in the decoder, and loop regions and start offsets in voices (§6);
- spatial voices and the listener (§5);
- voice stealing (§7);
- the bus tree (§8);
- the effects (§9);
- `Music` on loop regions and resume (§10);
- the court's mix and the `nocturne` additions (§11).

**Not in M31**, each with its owner (§15 has them all):
- HRTF and binaural rendering go to M144 (VR and XR).
- Doppler goes to M55 (Vehicles).
- Surround output is not planned. ADR-0068 says when it would be.
- Sends between buses are not planned. ADR-0067 says when they would be.
- The table's audio calls for all of this go to M48, and Lua to M49.
- A bus and effect editor goes to M110.

## 2. What exists

- **The mixer** (`engine/src/audio/mixer.zig`, `voice.zig`, `ring.zig` and `stream.zig`):
  - `MixerOf(P)` has a fixed voice table (32), a 256-entry command ring, an events ring
    (`started | retired`, twice the voice count), a published sample clock, and a stream table
    (4).
  - `PlayParams` has gain, pan, pitch, looping, `start_at` and `envelope`. Each voice's output
    is `level × envelope` (`voice.Ramp`: frame-pure, with one queued `next`).
  - `mix` drains commands, zeroes `out`, and adds each active voice into `out` in slot order.
    It then multiplies by `master_gain` and clamps to ±1. It advances the clock last.
  - `play` returns `NoFreeVoice` past the table: "there is no voice stealing in M5,
    deliberately".
  - Pan is `voice.panGains`, constant-power, and it uses `@cos` and `@sin`. It applies at the
    next callback, with no ramp.
- **Streams** (`stream.zig`'s `Feed`, `Stream.fill` in `mixer.zig`): a ring of one second per
  stream, filled by a decode task on `core.Tasks`. Loops come from the decoder's `rewind`,
  which starts again at the first audio packet. A voice's absolute frame is
  `pass × frames + cursor`.
- **The decoder** (`engine/src/asset/vorbis.zig` and `ogg.zig`): a whole decode, `prove`,
  `reserve` and `rewind`. It cannot yet start anywhere but the first audio packet.
- **Records** (`engine/src/asset/sound.zig`, `music.zig` and `schemas.zig`):
  - `foundry:sound` version 2 is `source` plus `stream`;
  - `foundry:music_playlist` and `foundry:music_stinger` are version 1.
- **`audio.Music`** (`engine/src/audio/music.zig`):
  - It schedules every track as a one-shot voice. The next starts at
    `start + frames − crossfade`, and a single-track looping playlist crossfades into itself.
  - The stinger duck and `setGain` are per-voice `fadeGainAt` ramps.
- **`core.math`** (`engine/src/core/math.zig`, `trig.zig`): `Vec3` and `trig.sinCosTurns`,
  which is arithmetic only. There is no arithmetic `exp` or `log`.
- **`data.Store.iterate(schema)`** lists every record of one schema in merge order. §8.2 needs
  it.
- **The court** (`samples/court/sounds.zig`, `music.zig` and `menus.zig`):
  - `place` gives gain falling linearly to the `sound_set`'s `hearing_distance`, ignoring
    height, and pan from the direction against the yaw.
  - The gate's loop is re-placed every frame with `setGain` and `setPan`.
  - The options menu has one `volume`, which is the master gain.
- **The public table** (`engine/src/abi/calls_audio.zig`): `audio_play`, `audio_stop`, and the
  four setters. 264 calls in all.

## 3. Arithmetic in `core`

The compressor and limiter work in decibels, and so do the records. Turning decibels into gain
needs `exp2`, and turning a level back needs `log2`. Zig's `@exp2` and `@log2` resolve to
whatever the linked math library provides, which is ADR-0064's problem again: a pin would
depend on the binary.

`engine/src/core/exp.zig` becomes `core.math.exp`, beside `trig`:
- `exp2(x: f32) f32` and `log2(x: f32) f32` use `+`, `−`, `×`, `floor` and bit manipulation
  only: range reduction to [1, 2), then a minimax polynomial.
- **Accuracy:** at most 2 × 10⁻⁷ relative error across the range the mixer uses, `exp2` on
  −40 to 10 and `log2` on 2⁻³⁰ to 2⁸. That is about 0.000002 dB, far below anything audible
  or measured.
- `dbToGain(db)` is `exp2(db · log2(10) / 20)`, and `gainToDb(g)` is the inverse. Gains below
  2⁻³⁰ read as −180 dB, never as −∞.
- They are tested against `std.math` to the bound, at every power of two in range, and as an
  exact round trip at the records' default values.

## 4. The records

All are decoded and validated in `asset`, so `fpack`, the editor and `fdt-check` refuse what
the engine would. Every ID field resolves at decode to a record of the schema it names. Every
number is finite, and a non-finite number is refused by name.

### 4.1 `foundry:sound` version 3

```
@schema foundry:sound {
    source string
    stream bool (default false)
    bus id (optional)                  # a foundry:audio_bus; none plays on the root
    priority u32 (default 128)         # 0–255; higher is kept
    attenuation id (optional)          # a foundry:audio_attenuation, for spatial plays
    loop_start u64 (default 0)         # source frames
    loop_end u64 (default 0)           # source frames; 0 is the sound's end
}
```

- **Every field is added with a default** (I8). Packages compiled at version 1 or 2 keep
  loading, and each of their sounds plays exactly as before.
- **Loop points are frames at the sound's own rate**, not seconds. A DAW exports loop points
  in samples, and a frame is exact where a second is not.
- **Refused:**
  - a `loop_end` past the sound's length;
  - a `loop_start` at or after the effective end;
  - a region shorter than 64 frames;
  - a `priority` above 255.

  The length is known only at decode, so these are checked there, as `stream` on a WAV is
  today.
- **A loop region matters only when the voice loops.** A sound with loop points played
  one-shot plays from start to end.

### 4.2 `foundry:audio_attenuation`

```
@schema foundry:audio_attenuation {
    model string (default "inverse")   # inverse | linear
    min_distance f32 (default 1.0)     # metres; full gain inside it
    max_distance f32 (default 30.0)    # metres; silent at and past it
    occluded_gain f32 (default 0.5)    # gain factor when fully occluded
    occluded_cutoff f32 (default 1200) # Hz: the low-pass when fully occluded
}
```

Refused: an unknown model; `min_distance` not positive; `max_distance` not above
`min_distance`, or above 10 km; `occluded_gain` outside 0–1; `occluded_cutoff` outside
20–20,000 Hz.

### 4.3 `foundry:audio_bus`

```
@schema foundry:audio_bus {
    parent id (optional)               # a foundry:audio_bus; none makes it a root
    gain f32 (default 1.0)             # 0–4
    effects [id] (default [])          # in order: filters, delays, reverbs, compressors, limiters
}
```

Refused: a `gain` outside 0–4; more than 8 effects; an effect that is not one of §4.4's
records. Cycles and depth are properties of the tree, not of one record, so §8.2 refuses them
when the tree is built.

### 4.4 The effects

```
@schema foundry:audio_filter {
    shape string                       # lowpass | highpass | bandpass | lowshelf | highshelf | peak
    frequency f32                      # Hz, 20–20,000
    q f32 (default 0.7071)             # 0.1–20
    gain_db f32 (default 0)            # shelves and peak; −24 to 24
}

@schema foundry:audio_delay {
    time f32                           # seconds, 0.001–2.0
    feedback f32 (default 0.3)         # 0 to 0.95
    wet f32 (default 0.3)              # 0–1
    dry f32 (default 1.0)              # 0–1
}

@schema foundry:audio_reverb {
    decay f32 (default 1.5)            # seconds to fall 60 dB, 0.1–20
    damping f32 (default 0.5)          # 0–1: how much faster high frequencies decay
    size f32 (default 1.0)             # 0.25–2: scales the delay lines; fixed per tree
    predelay f32 (default 0.01)        # seconds, 0–0.2
    wet f32 (default 0.25)
    dry f32 (default 1.0)
}

@schema foundry:audio_compressor {
    threshold_db f32 (default -18)     # −60 to 0
    ratio f32 (default 3)              # 1–20
    knee_db f32 (default 6)            # 0–24
    attack f32 (default 0.01)          # seconds, 0.0001–0.5
    release f32 (default 0.15)         # seconds, 0.001–5
    makeup_db f32 (default 0)          # 0–24
}

@schema foundry:audio_limiter {
    ceiling_db f32 (default -1)        # −24 to 0
    release f32 (default 0.1)          # seconds, 0.001–2
    lookahead f32 (default 0.002)      # seconds, 0.0005–0.01
}
```

**One schema per effect, not one schema with a `kind`.** A typed record lets each field carry
its own range, lets `fpack` refuse a reverb with a `ratio`, and lets the editor show the fields
that apply. A bus names its effects by ID, so a mod overrides one effect record without
touching the bus, or overrides the bus to change its chain.

**The set is fixed, deliberately** (ADR-0067). Effects run on the device thread, where a fault
cannot be contained. `audio.md` §10 already ruled that mod DSP is "a graph of engine-implemented
nodes a mod configures, not a function pointer". I6 asks that registries take entries a mod
could also supply. Here a mod supplies records, which the tree takes at run time. It never
supplies the code that runs them.

### 4.5 `foundry:music_playlist` version 2

`resume bool (default false)` is added. When the playlist is left and later played again, it
resumes the track it was playing at the frame where it was left (§10.2).

## 5. Spatial voices (`audio`, ADR-0068)

### 5.1 The listener and a position

```zig
pub const Listener = struct {
    position: Vec3 = .zero,
    forward: Vec3 = .forward,          // −Z, ADR-0048
    up: Vec3 = .up,
};

PlayParams.position: ?Vec3 = null      // non-null makes the voice spatial
PlayParams.attenuation: ?ContentId = null  // overrides the sound record's

setListener(self, Listener) void
setPosition(self, voice, Vec3) void
setOcclusion(self, voice, amount: f32) void   // 0 open, 1 fully occluded
```

- **The listener and positions live on the game thread.** They are presentation (I9). A game
  sets them after its tick, from the state the tick left, exactly as the court sets its camera.
  `scene` still cannot see `audio`.
- **A spatial voice's `pan` is ignored**, because its position decides it. Its `gain` remains
  its `level`.
- **A non-finite position or listener is refused** by the checked variants, as the other
  setters refuse, and ignored by the unchecked ones. A degenerate listener, with `forward`
  parallel to `up`, keeps the previous listener.

### 5.2 Distance

`d` is the distance from listener to source, in metres, in all three dimensions. The court
ignored height. Its ledge is two metres up, so the engine's answer is the truer one, and the
court's numbers move into an attenuation record (§11).

- **`inverse`**, the default, is the physical 1/d law, adjusted to reach zero at
  `max_distance`:

  `g = (min/d − min/max) / (1 − min/max)` for `min ≤ d ≤ max`, and 1 inside `min`.

  The usual clamped 1/d never reaches zero, so a game would either hear everything at any
  distance or cut it off with a step. This curve stays within 3% of 1/d over the first third
  of the range and falls smoothly to silence.
- **`linear`:** `g = 1 − (d − min) / (max − min)`. It is the court's curve, kept for
  hand-tuned cases.

### 5.3 Direction

- The listener's right is `normalize(forward × up)`.
- Pan is `dot(normalize(source − listener), right)`, in −1 to 1, and goes through the
  constant-power law of `voice.panGains`.
- The law is computed with `core.math.trig.sinCosTurns` rather than `@cos` and `@sin`, so a
  spatial pin is the same in every binary.
- `panGains` itself is unchanged, so M30's pins and every existing caller are untouched.
- **Inside `min_distance` the pan narrows toward the centre**, as `d / min`. A source the
  listener walks through then moves across the middle, never flipping from hard left to hard
  right in one frame.
- **Front and back sound the same**, which is stereo's limit. HRTF is what distinguishes them,
  and that is M144's.

### 5.4 Occlusion

The game decides whether something is in the way, because only the game has the geometry. The
court casts a ray. A game with portals would ask its portals. The mixer turns `amount` into
sound:
- the voice's gain is multiplied by `lerp(1, occluded_gain, amount)`;
- **a one-pole low-pass per voice** is set to `lerp(20,000, occluded_cutoff, amount)` Hz, on a
  logarithmic scale.

A one-pole filter is used rather than a biquad because it stays stable under any change of
its coefficient. A per-voice filter swept every frame is exactly the case that unsettles a
biquad. It costs two multiplies per channel per frame, and it is bypassed entirely while
`amount` is 0.

### 5.5 When it is computed

- **`Mixer.update`, once per game frame**, recomputes every spatial voice's left gain, right
  gain and cutoff from the listener, its position, its occlusion and its attenuation. It sends
  them in one `spatial` command per changed voice.
- **The callback interpolates** each of the three linearly from the values it holds to the new
  ones across the next buffer, then holds them.

A sound moving at a frame rate below the buffer rate therefore changes smoothly, with no zipper
and no step at a buffer edge. The trig and divisions stay off the device thread, and the
callback adds three linear ramps per spatial voice.

### 5.6 A stereo source

A stereo sound played spatially is summed to mono before it is panned, at half the sum of the
two channels. A source at a point has one position, and panning a stereo file's two channels as
if they came from that point would give a width the point does not have. A game that wants a
wide ambient bed plays it non-spatially.

## 6. Seeking and loop regions (`asset` and `audio`)

### 6.1 Seeking by granule

A Vorbis packet's output depends on its own data and the right half of the packet before it,
and on nothing earlier. Decoding can therefore start at any packet, provided the packet before
it is decoded first and its output discarded. The samples that follow are bit for bit those a
whole decode gives.

- **A seek index**, built during the proving pass at load (`music.md` §4): each page's byte
  offset, its granule, and whether a packet begins on it. That is 16 bytes a page, about 4 KB
  per minute of quality-4 stereo. It is kept with the compressed bytes.
- **`vorbis.seek(state, frame)`:**
  1. binary-search the index for the last page whose granule is below `frame`;
  2. back up one packet;
  3. decode that packet and discard its output;
  4. decode on and drop frames until `frame`.

  The work is at most two packets plus one page's worth of frames.
- **`rewind`** becomes `seek(0)`.
- **A resident sound** needs no index. Its samples are already there.

### 6.2 Start offsets

`PlayParams.start_frame: u64 = 0` starts the voice that many source frames in.
- A resident voice starts its cursor there.
- A streamed voice seeks its decoder before its first fill.
- A `start_frame` past the sound's end is refused by `play` with `error.InvalidStart`. It is
  caller arithmetic, not content, so it fails on the game thread with a name.

### 6.3 Loop regions

A looping voice plays from its start to `loop_end`, then wraps to `loop_start`, for as long as
it loops.
- **Resident:** the cursor wraps by subtraction, by the region's length rather than the
  sound's, as today, so no fractional error accumulates. Interpolation reads across the seam
  from `loop_end − 1` to `loop_start`.
- **Streamed:** when the decoder reaches `loop_end` it trims the block there and seeks to
  `loop_start`. The absolute frame becomes
  `intro + pass × region + offset`, with `intro = loop_start`, replacing `pass × frames`. The
  ring and the timeline work unchanged.
- **A sound with no loop points** has a region of the whole file. Its seams are then exactly
  M30's, which a test confirms frame for frame against M30's behaviour.

## 7. Voice stealing (`audio`)

When `play` finds no free voice, it may take one rather than return `NoFreeVoice`.
- **Priority:** `PlayParams.priority: ?u8` overrides the sound record's `priority`.
- **Candidates:** voices whose priority is at most the new voice's. A higher-priority voice is
  never stolen. With no candidate, `play` returns `NoFreeVoice`, as today.
- **Choice,** in order:
  1. the lowest priority;
  2. then the quietest by the game thread's estimate: `level` × the envelope's target × the
     spatial gain. A voice placed past its `max_distance` is 0 and goes first;
  3. then the oldest, by a play sequence number.

  Every input is game-thread state, so the choice is deterministic and testable without a
  device.
- **No click.** A stolen voice moves to one of `Options.fade_slots` (4) extra slots that `play`
  never claims. There it fades to silence linearly over `Options.steal_fade_frames` (256,
  5.3 ms at 48 kHz), then retires. Its own slot is free for the new voice at once.
  - The move is one `steal` command, ahead of the new voice's `play` in the same ring, so the
    callback sees them in that order.
  - With every fade slot busy, the victim is cut and counted in `cutSteals()`.
- **Lifetime.** The victim's handle dies at once, and its generation moves on. Its sound
  reference and any stream move with it to the fade slot, and are released when the fade
  slot's retirement arrives. `music.md` §6.5's rule holds: both sides done.
- **Counters:** `stolen()` and `cutSteals()`.
- **`Options.voices`'s comment changes**, and so does `NoFreeVoice`'s, which today says the
  mixer "does not steal one".

## 8. Buses (`audio`, ADR-0067)

### 8.1 The shape

```
 voices ──► their bus's buffer ──► effects in order ──► gain ramp ──► parent's buffer
                                                                        │
            ...children before parents, siblings by content ID...       ▼
                                             root: effects ──► gain (master) ──► clamp ──► out
```

- **A tree, one parent each, one root.** A voice mixes into its bus's buffer. Each bus, after
  all its children, runs its effects in place, applies its gain ramp, and adds itself into its
  parent.
- **The root's gain is the master gain.** `setMasterGain` sets it, so the public table's
  `audio_set_master_gain` means what it meant. The clamp stays after the root as the last
  safety net. With a limiter on the root it never engages.
- **Order is documented and stable** (I9): post-order, children before parents, siblings by
  ascending content ID. It never follows load order, so a mod adding a bus does not reorder
  anyone else's sums.
- **Buffers and effect state are allocated when the tree is built**, on the game thread. There
  is one buffer per bus, a device buffer long. The callback only zeroes and adds.

### 8.2 Building the tree from content

```zig
useMix(self, root: ContentId) MixError!void
contentChanged(self) MixError!void     // after a reload: rebuild if any bus or effect record changed
setBusGain(self, bus: ContentId, gain: f32, frames: u32) void
```

- **`useMix`** takes every `foundry:audio_bus` record whose chain of parents reaches `root`,
  through `data.Store.iterate`, and builds the tree.
  - The root names no parent.
  - Records that do not reach `root` are ignored and logged once. They may belong to another
    game's root in the same store.
  - **A mod adds a bus by adding a record with a parent**, with no override of anyone's list.
    That is why the link runs from child to parent.
- **Refused by name, on the game thread:**
  - a cycle;
  - a depth above 8;
  - more than 32 buses;
  - a `root` that is not a bus, or that has a parent.
- **Routing.** A voice's bus is its sound record's `bus`. A bus not in the tree routes the
  voice to the root, and counts it in `misrouted()`, which the court's evidence requires to be
  0.
- **No tree** is the M30 mixer: one implicit root with no effects, whose buffer is `out`
  itself. Voices add into it in slot order as before, so criterion 9's identical output follows
  from the structure, not from tuning.

### 8.3 Changing the tree while it plays

- **A parameter change**, meaning a bus's gain or an effect's fields, keeps the tree's shape.
  `contentChanged` sends each changed value as a command, and the effect's state (a reverb's
  tail, a compressor's envelope) carries on.
- **A shape change** (a new bus, a changed parent, a changed chain, a reverb's `size`) builds a
  whole new tree on the game thread, where allocation may fail. One `swap_mix` command hands it
  to the callback, which installs it between two buffers. The old tree comes back through the
  events ring, which gains a `tree` event and grows by two entries, and `update` frees it.
  Every voice's bus index is re-resolved in the new tree before the swap, and the command
  carries the mapping.
- **Effect tails restart** on a shape change, because their state belongs to the old tree.
  Only an edit to the mix's structure is heard as a seam.

### 8.4 Music and its bus

ADR-0066 expected a music bus to replace `Music` setting `level` on each of its voices. Half of
that holds:
- **The player's slider owns the music bus's gain.** The court's options set
  `setBusGain(court:bus.music, …)`.
- **`Music` keeps its own gain per voice.** The stinger duck and the pause duck are the
  sequencer's, not the player's. If they also drove the bus, a duck's release would overwrite
  the slider, and the slider would cut a duck short.

So tracks route to the music bus by their sound records, and `Music.setGain` stays as it is.
The revisit is answered: two owners of a gain need two gains.

## 9. Effects (`audio`, ADR-0067)

Each effect is a struct with `process(buffer, frames, channels)`. Its state is allocated when
the tree is built, and its coefficients are recomputed only when a parameter changes. All of it
is arithmetic: `core.math.trig` and `core.math.exp`, never a linked math library.

- **Filter:** a biquad, transposed direct form II, with the RBJ Audio EQ Cookbook's
  coefficients for the six shapes.
  - A change to `frequency`, `q` or `gain_db` ramps over one buffer: the coefficients are
    recomputed at each of the buffer's 8 sub-blocks, which is enough to avoid zipper noise on a
    sweep.
  - `setEffect` with a ramp length sweeps across several buffers. The court's pause muffle uses
    it.
- **Delay:** one line per channel, sized to the record's `time` (at most two seconds), with
  feedback and wet and dry gains. `time` is fixed per tree. A change to it is a shape change.
- **Reverb:** a feedback delay network (Jot):
  - eight delay lines, at mutually prime lengths from 29.7 to 79.3 ms, scaled by `size`;
  - an 8×8 Hadamard matrix, which needs only additions and one scale;
  - each line's gain `10^(−3·L/(decay·rate))`, so the network falls 60 dB in `decay` seconds;
  - a one-pole low-pass in each line, set from `damping`, so high frequencies decay faster;
  - a predelay;
  - stereo out from alternate lines.

  `decay`, `damping`, `wet` and `dry` change with no new memory. `size` and `predelay` are
  fixed per tree. This is a known, documented structure whose decay time is a parameter rather
  than an emergent property, which is what lets criterion 3 measure it.
- **Compressor:** feed-forward.
  - The level is the peak of the channels in decibels, `log2`-based.
  - The gain computer is the soft-knee static curve.
  - Attack and release are one-pole smoothing coefficients on the gain reduction, computed
    from the time constants.
  - Makeup gain follows.
  - It costs one `log2` and one `exp2` per frame, not per sample per channel: the channels
    share the gain.
- **Limiter:** a lookahead peak limiter.
  - The signal is delayed by `lookahead`.
  - The gain needed to keep the peak under the ceiling over that window comes from a sliding
    maximum (a monotonic deque, constant time per frame) and is applied when the delayed sample
    leaves.
  - Release is a one-pole ramp back up.
  - Because the gain already reaches its target by the time the sample it was computed for
    leaves, no output exceeds the ceiling. Criterion 3 tests that against random and mutated
    loud input.
  - **Its lookahead delays everything beneath it**, which is 96 frames at 48 kHz by default.
    The sample clock still counts mixed frames, and scheduled starts are exact against it. The
    output is the same constant later, which `mixerLatency()` reports.
- **`setEffect(bus, slot, Effect)`** takes a tagged union of the five parameter sets,
  validated on the game thread with the records' ranges, plus `frames` to ramp over where the
  effect supports it.

## 10. `Music` in M31

### 10.1 Loop regions

A track whose sound has a loop region, in a playlist with `loop true` and one track, plays as
**one looping voice** until the playlist is left: its intro once, then its body for as long as
it lasts. `music.md` §8.2's crossfade into itself is kept for tracks with no loop region, and
for playlists of several tracks, which advance as before. The head's length is then unbounded,
so `advance` schedules nothing after it. A switch fades it on the bar line, as for any track.

### 10.2 Resume

When a playlist with `resume true` is left, `Music` records its track and its position, in the
track's source frames, at the frame its fade-out begins:
`start_frame + (fade_begin − started_at) × step`, folded into the loop region if it loops.
Pitch is always 1 for music, so `step` is the rate ratio and the position is exact.

When that playlist is played again, its track starts at that position with `start_frame` (§6.2),
fading in over the crossfade. Its next track follows from there as usual. A playlist played for
the first time, or with `resume false`, starts at its first track.

### 10.3 The pin

Criterion 5's sequenced mix is M30's sequence, adding the following, all on the stepped device
with immediate tasks:
- a track with a loop region;
- a resumed playlist;
- two spatial voices, one moving and one occluded;
- a steal;
- the court's whole tree: reverb, compressor, filter sweep, delay and limiter.

## 11. The court's mix

- **Records** in `court.fdt`:
  - buses: `court:bus.master` (the root, with a limiter at −1 dB); `court:bus.music`;
    `court:bus.world`, with `court:fx.courtyard` (a reverb, decay 1.4 s, wet 0.18),
    `court:fx.world_glue` (a compressor at −20 dB, 2:1) and `court:fx.muffle` (a low-pass,
    at 20 kHz until paused); `court:bus.effects` and `court:bus.ambience` under world; and
    `court:bus.ui`.
  - every sound gets its `bus` and a `priority`: footsteps 32, the warden's steps 64, the gate
    and beacons 128, the endings and menu clicks 200, music tracks 255;
  - `court:attenuation.warden` and `court:attenuation.prop` take the place of the
    `sound_set`'s `hearing_distance`, which stays only as the music's chase trigger;
  - `court:music.calm` gets `resume true`;
  - the title track gets a loop region.
- **Music:** `make_court_music.py` regenerates `title.ogg` with an eight-bar intro before its
  loop body, and writes its loop points. Its other outputs are unchanged, and its test still
  regenerates and compares byte for byte.
- **`sounds.zig`:**
  - `place` is deleted;
  - the warden's steps, the gate's loop and the beacons play with `position`;
  - each frame it calls `setListener` from the walker's eye and look, then `setPosition` and
    `setOcclusion` for each spatial voice. Occlusion comes from one ray, ears to source,
    against the court's static collision layer.
- **`menus.zig` and preferences:**
  - the options gain `music` and `effects` sliders beside `volume`;
  - they are bounded preferences, added with defaults (ADR-0031, I8), so an M30 preferences
    file loads unchanged;
  - `volume` drives the root's gain, `music` the music bus, and `effects` the world bus.
- **Pause:** `setEffect(court:bus.world, muffle, lowpass 800 Hz over 0.25 s)`, and back on
  resume, beside `Music.setGain`'s duck.
- **`nocturne`** also overrides `court:fx.courtyard` with a 3.2 s decay. It adds
  `nocturne:fx.echo`, a delay of three eighths of a beat at its own tempo, and overrides
  `court:bus.music` to name it. No code.
- **The evidence:** `FOUNDRY_COURT_MUSIC_LOG=on` grows to the audio log. Every ten seconds and
  at exit, it adds the stolen, cut, misrouted and over-ceiling counters and the limiter's
  deepest reduction. A test hook counts output samples past the ceiling on the stepped device,
  never in the callback.

## 12. The public ABI: nothing in M31

The call count stays 264.
- **`audio_play`** plays a sound on the bus, at the priority and with the loop region its
  record names, because those are properties of the record. Without a position it plays
  non-spatially.
- **`audio_set_master_gain`** sets the root bus's gain, as it set the master gain.
- **The listener, positions, occlusion, buses, effects, priorities, start offsets and stealing
  counters** reach the table in M48's `FoundryApi_v8`, and Lua in M49. M48's line covers "what
  M27–M47 built", and the close adds an "also" clause naming them.
- **A content mod reaches all of the mix today**, as `nocturne` shows: bus records, effect
  records, attenuation, priorities and loop points are content.

## 13. Platform assessment

- **macOS (Metal):** CoreAudio through SDL3, unchanged. Everything new is pure Zig. Steps 1–10
  run here.
- **Windows (Vulkan):** WASAPI through SDL3, on the slower i3. Criterion 6's mixing speed is
  decided there, so Step 11 runs on the Arc PC.
  - The PC has no Foundry clone since M30's close, so Step 11 clones again.
  - The usual rules apply: check it is idle, `-j2`, below-normal priority, a scheduled task
    for windowed runs, and removal of exact Foundry paths only.
- **Linux:** nothing M31 changes is Linux-specific, so 3d.md §10.2 calls for no Linux run. The
  Linux null cross-check stays in the bar.
- **Graphics:** untouched.

## 14. Verification, pins and budgets

- **`core.math.exp`:** the bound against `std.math`, round trips, and the records' defaults.
- **Records:** defaults, every refusal through `fpack`'s path and on hand-made records, an
  override replacing an effect or a bus, and version 1 and 2 sounds and version 1 playlists
  loading unchanged.
- **Seeking:**
  - for every fixture, 64 seeded frames plus the first, the last and every page boundary: the
    seek's samples equal the whole decode's from there, compared bit for bit;
  - a seek on a damaged index is refused, never a panic;
  - the mutation sweep is extended to seeks.
- **Loop regions:** resident and streamed voices, three seams each, equal frame for frame.
  M30's whole-file loop is unchanged. `InvalidStart` is refused.
- **Spatial,** on the stepped device:
  - gain at `min`, a third of the way, half way and `max` for both models;
  - pan at the four compass points and overhead;
  - the near-field narrowing;
  - summed power across a sweep;
  - a moving source whose largest change between consecutive frames is bounded by its buffer's
    ramp;
  - occlusion's gain and cutoff;
  - non-finite refusals;
  - a degenerate listener.
- **Stealing:** a table of cases covering the priority, loudness and age orders, a refused
  higher priority, a stolen streamed voice whose stream outlives the fade, cut steals with
  every fade slot full, and a fade that reaches zero on its last frame. All of it runs under
  `testing.allocator`.
- **Buses:**
  - the summation order, pinned;
  - cycle, depth, count and root refusals;
  - misrouting;
  - a parameter change that keeps a reverb tail, and a shape change that swaps the tree, with
    the old tree freed only after its event;
  - no tree giving output identical to M30's on M30's pinned sequence.
- **Effects:**
  - filter magnitude from a steady sine at three frequencies, against the formula;
  - the delay's echo at exactly its frame, at its feedback;
  - the reverb's decay from the Schroeder integral of its impulse response at five `decay`
    values;
  - the compressor's settled curve at 13 input levels, and its attack and release times
    within 10%;
  - the limiter's ceiling over seeded random loud buffers, a 32-voice stress, and their
    mutations (impulses, square waves, full-scale steps).
- **Mixing speed:** a timing test mixes the court-shaped load and prints frames per second,
  in ReleaseSafe on one thread. It must be at least 20× real time on the i3, and the Mac's
  figure is recorded.
- **The court:** criteria 6–8 from a relocated ReleaseSafe install, three ten-minute runs each,
  on the M5 and then the Arc PC; `dist` staging, because the sample's content changes; the
  scripted endings unchanged.
- **The bar** (`AGENTS.md` §3) at every step. `fdt-check` covers the new records and versions.

**Pins across machines.** The sequenced mix's hash is pinned on the Mac and checked on the PC
and under x86_64. A difference across machines is recorded, not forced (ADR-0013). It fails an
exit only if one machine disagrees with itself.

**Listening.** None of the criteria needs a human ear. Step 10 offers the owner a listening
check of the court on the Mac, as M30 did. It is not an exit criterion.

## 15. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| HRTF, binaural rendering and front–back cues | M144 | VR and XR is where a head is tracked and headphones are assumed. Added to its intent at the close |
| Doppler shift from relative velocity | M55 | Vehicles are the first sources fast enough to hear it. Added to its intent at the close |
| The listener, positions, occlusion, buses, effects, priorities and start offsets in the public table, and in Lua | M48, M49 | §12. M48's line gains an "also" clause at the close, and M49's "audio" already covers its binding |
| Editing buses, effects and attenuation with preview | M110 | Beside the music and sound editor already on its line |
| Occlusion from geometry the engine computes (portals, ray budgets) | M60 | A world large enough to stream is the first that needs more than a game's own ray. Added to its intent at the close |
| Surround output (5.1, 7.1) | Not planned | Refused by name today (`UnsupportedChannelCount`); ADR-0068 says when it would be decided |
| Sends from one bus to another (an auxiliary reverb fed by several buses) | Not planned | An insert reverb with wet and dry covers the court and the common case; ADR-0067 says when it would be decided |
| Effects written by mods | Never | Device-thread code a mod supplies is the one fault Foundry cannot contain (`audio.md` §10) |

## 16. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | `core.math.exp` gives arithmetic `exp2`, `log2`, `dbToGain` and `gainToDb`, so no pin depends on a linked math library | §3, ADR-0067 |
| 2 | `foundry:sound` version 3 adds `bus`, `priority`, `attenuation`, `loop_start` and `loop_end`, all with defaults; loop points are source frames | §4.1 |
| 3 | `foundry:audio_attenuation` with `inverse` (1/d reaching zero at `max_distance`) and `linear` models, plus occlusion's gain and cutoff | §4.2, §5.2 |
| 4 | `foundry:audio_bus`: a tree linked child to parent, gain and up to eight effects; at most 32 buses and depth 8 | §4.3, §8.2 |
| 5 | Five effects, each its own record and a fixed engine set: a biquad filter (six shapes), a delay, an eight-line FDN reverb, a feed-forward compressor and a lookahead limiter; mods configure them and never supply DSP | §4.4, §9, ADR-0067 |
| 6 | `foundry:music_playlist` version 2 adds `resume` | §4.5, §10.2 |
| 7 | Spatial voices are placed on the game thread in `Mixer.update`, and their gains and cutoff interpolated across the next buffer; one listener; three-dimensional distance; constant-power pan narrowing inside `min_distance`; a stereo source summed to mono | §5, ADR-0068 |
| 8 | Occlusion is an amount the game supplies, which the mixer turns into gain and a per-voice one-pole low-pass | §5.4 |
| 9 | Seeking by a page index built in the proving pass, exact to the bit; `start_frame` on `play`; loop regions on resident and streamed voices | §6 |
| 10 | Voice stealing by priority, then loudness, then age; never a higher priority; the stolen voice fades over 256 frames in one of four fade slots | §7, correcting `audio.md` §11's question 1 and the mixer's "no voice stealing" |
| 11 | Buses mix children before parents, siblings by content ID; the root's gain is the master gain; no tree is M30's mixer exactly; a parameter change keeps state and a shape change swaps the tree by one command | §8 |
| 12 | The player's slider owns the music bus and `Music` keeps its per-voice gain, answering ADR-0066's music-bus revisit | §8.4 |
| 13 | `Music` plays a single looping track with a loop region as one looping voice, and resumes a `resume` playlist where it was left | §10 |
| 14 | The runnable result is the court's mix: spatial warden and props with occlusion, buses with reverb, compressor, filter and limiter, three sliders, an intro-and-loop title, resumed calm music; `nocturne` adds a longer reverb and an echo | §1, §11 |
| 15 | No ABI change; 264 calls; `audio_play` honours a sound's bus, priority and loop region | §12 |
| 16 | The budgets: mixing ≥ 20× real time on the i3 with the court's full load; main-thread audio ≤ 0.10 ms p95; zero underruns, late starts, dropped commands, misroutes and samples past the ceiling | §1, §14 |
| 17 | HRTF to M144, Doppler to M55, engine-computed occlusion to M60, the table to M48/M49, editing to M110; surround and sends not planned; the roadmap's intent lines gain these at the close | §15 |
| 18 | Twelve steps, in §17's order | §17 |

Once these are accepted, nothing blocks Step 1.

## 17. Implementation order — twelve bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `core` and `asset`: arithmetic, and the records

- Add `core.math.exp` (§3).
- Add `foundry:sound` version 3, `foundry:audio_attenuation`, `foundry:audio_bus`, the five
  effect records, and `foundry:music_playlist` version 2, decoded and validated in `asset`
  (§4).
- Tests: §14's `core.math.exp` and record items.

**Exit:** every record decodes with its defaults and refuses every out-of-range field by name
through `fpack`'s path, and every M30 package loads unchanged.

### Step 2 — `asset`: seeking by granule

The seek index in the proving pass, `vorbis.seek`, and `rewind` as `seek(0)` (§6.1). Tests:
§14's seeking items.

**Exit:** a seek to every tested frame of every fixture gives the whole decode's samples bit
for bit, and the extended mutation sweep neither panics nor hangs.

### Step 3 — `audio`: start offsets and loop regions

`start_frame`, loop regions on resident and streamed voices, and the streamed absolute frame
(§6.2, §6.3). Tests: §14's loop items.

**Exit:** with immediate tasks, a streamed voice with a loop region equals its resident decode
across three seams, and M30's whole-file loop is unchanged.

### Step 4 — `audio`: spatial voices

The listener, positions, occlusion, both distance models, the pan and its narrowing, the
per-voice one-pole, the `spatial` command and its interpolation across a buffer (§5). Tests:
§14's spatial items.

**Exit:** every spatial formula holds on the stepped device, and a moving source changes with
no step at a buffer edge.

### Step 5 — `audio`: voice stealing

Priorities, the choice, fade slots, the `steal` command, lifetime through the fade, and the
counters (§7). Tests: §14's stealing items.

**Exit:** every case in the stealing table chooses its expected voice, and a stolen voice fades
to zero over exactly its fade.

### Step 6 — `audio`: the bus tree

The tree from records, routing, buffers, order, gain ramps, `setBusGain`, `setMasterGain` on
the root, misrouting, and parameter changes and swaps on reload (§8). There are no effects yet:
each chain is accepted and bypassed. Tests: §14's bus items.

**Exit:** no tree reproduces M30's pinned sequence exactly, and a tree's summation order and
swap behave as §8 states.

### Step 7 — `audio`: filters, delay and reverb

The biquad's six shapes and their ramps, the delay, the FDN reverb, and `setEffect` for them
(§9). Tests: §14's filter, delay and reverb items.

**Exit:** criterion 3's filter and reverb measures hold.

### Step 8 — `audio`: compressor and limiter

The compressor, the lookahead limiter, `mixerLatency()`, and the mixing-speed timing test
(§9, §14).

**Exit:** criterion 3's compressor and limiter measures hold, and the Mac's mixing speed is
recorded.

### Step 9 — `audio`: `Music` on loop regions and resume

The looping single track, resume, and the M31 sequenced mix pinned in Debug, ReleaseSafe and
x86_64 (§10). Tests: §14's items for both, and criterion 5.

**Exit:** the sequenced mix is pinned and equal in the three builds, and a resumed playlist
starts on the frame §10.2 computes.

### Step 10 — `court`: the mix, proved on the Mac

- The records, the regenerated title, `sounds.zig` on the listener with occlusion, the sliders
  and preferences, the pause muffle, and the `nocturne` additions.
- The evidence log.
- Measurements from a relocated ReleaseSafe install, and a check of `dist` staging (§11).

**Exit:** criteria 6 (main thread), 7, 8 and 9 hold on the M5 with Metal, three ten-minute runs
each. The owner is offered a listening check.

### Step 11 — Windows/Vulkan

Clone on the PC. Run the null and Vulkan suites, the mixing-speed test, and the pins. Run the
relocated court for ten minutes three times, with and without validation, plus its scripted
endings.

**Exit:** criteria 5–9 hold on the Arc A750, with the pins checked against the Mac's and any
difference recorded.

### Step 12 — Close M31

Resolve the contract discrepancies where they were written:
- `audio.md`:
  - §11's questions 1, 2 and 5;
  - §12's spatialisation, effects and limiter bullets;
  - §5's note that the clamp is "not a limiter";
- `playable3d.md` §6.2 ("Position is the sample's arithmetic") and §13's spatial row;
- ADR-0023's "spatialisation arrives with 3D if at all";
- ADR-0066's music-bus revisit (§8.4);
- the intent lines of M48, M55, M60, M110 and M144 in `docs/ROADMAP.md` (§15).

Then:
- move ADR-0067 and ADR-0068 to Accepted and into `CLAUDE.md` §4.1;
- update §4.3's `audio` and `core` descriptions, and §9's deferred row;
- update `AGENTS.md`'s bar if a step changed it, and add the mixing-speed measurement beside
  the M30 optimized-only ones;
- update the ROADMAP's M31 row, the design index, the README and `PROJECT_STATE.md`;
- pack up the PC by exact path.

Tag `m31`, push when asked, and stop before M32's design.

## Resolution — Step 1: arithmetic, and the records (2026-10-27)

The owner's "Begin" accepted the design with §16 as written. The design's status line,
ADR-0067, ADR-0068 and `CLAUDE.md` §4.1 record it.

**`core.math.exp`** (`engine/src/core/exp.zig`) gives `exp2`, `log2`, `dbToGain` and
`gainToDb`. Two points sharpen §3:
- **Series, not minimax polynomials.** Each function works in `f64`, using only `+`, `−`,
  `×`, `/`, `floor` and the bits of the number, and returns `f32`:
  - `exp2` splits `x` into `n + f` with |f| ≤ ½, then takes e^(f·ln 2) as a twelve-term
    Taylor series. It builds 2ⁿ from its bits.
  - `log2` takes the mantissa into [√½, √2), then 2·atanh(s) as an eight-term odd series.

  A series' error is its first omitted term (below 2 × 10⁻¹⁶ for both), which is easier to
  argue than fitted coefficients. Both meet the 2 × 10⁻⁷ bound with room to spare.
- **Every power of two is exact**, bit for bit, in both directions, from 2⁻¹⁴⁹ to 2¹²⁷.
  - The same three tests pass in Debug, ReleaseSafe and as x86_64 under Rosetta.
  - "Exact round trip at the records' defaults" was too strong for `f32`. The test holds
    `gainToDb(dbToGain(x))` within 10⁻⁵ dB of `x` at each default and limit.
  - Silence, a negative gain and NaN all read as −180 dB.

**The records:**
- **`asset/mix.zig` is new**, as `asset.mix`. It holds:
  - the seven schemas (bus, attenuation, and the five effects), each version 1;
  - the values: `SoundSettings`, `Attenuation`, `Bus`, `Effect` as a union of the five
    effect parameter sets, and each value's `validate`;
  - the decoders;
  - `describe` and `noun` for diagnostics;
  - `checkSoundReferences` and `checkBusReferences`, for the IDs that resolve across
    packages.

  `Effect` is the form Steps 6–8 build a tree from.
- **`foundry:sound` is version 3**, with §4.1's five fields, each `since = 3` with a default
  or optional. `schemas.zig`'s tests already require that of every field after version 1.
  Version 1 and 2 packages decode as defaults, so every existing sound and pin is unchanged.
- **`foundry:music_playlist` is version 2**, with `resume`.
  - `resume` is a Zig keyword, so `Playlist`'s field is `resumes`. The record's field, which
    is on authors' disks, stays `resume`.
- **The loop region is checked in two places**, by what each can know:
  - **The record alone:** with a `loop_end`, `loop_start` must be before it (`InvalidLoop`)
    and the region at least 64 frames (`LoopTooShort`). `fpack` and the editor check this.
  - **The decoded length:** `SoundSettings.checkLoop` refuses `LoopPastEnd`, a start at or
    after the end, and a region under 64 frames. The mixer's `soundDecode` runs it once the
    resident samples or the proving pass know the length, whether resident or streamed. A
    refusal is `InvalidAsset` with the sentence logged, the outcome a broken file has.
  - A sound with no loop points is not checked. Its region is the whole file, so a
    20-frame click may still loop whole, as in M30.
- **Where they are checked:**
  - `author/compiler.zig`'s `checkMeanings` decodes every `foundry:sound` and every mixing
    record in a written package. A refusal names the record and its field, at its line:
    "audio reverb 'demo:r' has a decay that is not between 0.1 and 20 seconds".
  - IDs resolve across packages, so whether a bus is a bus, an attenuation is an attenuation
    or an effect is an effect is checked at load. The checks are written and tested here.
    Steps 4 and 6, which first resolve those IDs, call them.
- **Registration:** `asset.mix.registerAll` joins the compiler's `registerAvailableSchemas`
  and `app`'s engine registration. `engine_schema_names` gains the seven spellings, 29 in
  all, so the editor's New Record form offers them. The court's and `music_sequencing`'s test
  stacks register no mixing schemas yet, because no content of theirs uses one until
  Step 10.

**Guards verified by breaking them**, all at once, each failing its own test before
restoring:
- dropping the priority bound failed the refusal table and the compiler's line test (a `u8`
  cast trap, which still fails the test);
- skipping the load-time loop check failed `sound_pipeline`'s new resident-and-streamed test;
- dropping one term of `log2`'s series failed the bound and the decibel tests.

**Bar:** the full bar, all exit 0. `zig build test` is **2,386/2,389** (three skips, as
before): 124/124 steps, ten more tests than M30's close.

Next is Step 2: seeking by granule in `asset`. No mixer behaviour has changed yet. Buses,
spatial voices, stealing and loop regions in voices do not exist; only their records do.
