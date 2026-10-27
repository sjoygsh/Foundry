# Design: M31 — Audio III: spatialisation, buses and effects

**Status:** Accepted 2026-10-27, when the owner asked for Step 1, with §16 as written. Steps 1–11 are done; their Resolutions follow §17.
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

## Resolution — Step 2: seeking by granule (2026-10-27)

`vorbis.Decoder.seek(index, frame)` positions the decoder so the next `read` gives frame
`frame` onward. The samples are bit for bit those a whole decode has there. §6.1's argument
held: a packet depends only on its own bits and the second half of the packet before it.

**What a checkpoint is.** The design sketched the index as each page's offset, granule and a
flag, then "back up one packet". The built form is simpler to keep exact:
- `vorbis.Checkpoint` is a page that begins with a fresh packet, plus what the decoder had
  counted once that packet was decoded:
  - the page's byte `offset` and `sequence`;
  - `emitted`, the frames emitted;
  - `made` and `position`, libvorbis's granule bookkeeping.

  That is 40 bytes a page. On the court's own tracks it comes to 3.4–6.3 KB per minute, the
  design's order of magnitude.
- **A seek** chooses the last checkpoint with `emitted ≤ frame` by binary search.
  1. It resumes the Ogg reader at that page (`ogg.Packets.resumeAt`, a new call).
  2. It decodes that page's first packet with its output thrown away, which leaves exactly
     the overlap the next packet needs.
  3. It restores the three counters.
  4. It reads and drops frames up to `frame`.

  The work is one packet plus at most a page of frames. Before the first checkpoint, the seek
  decodes from the start.
- **No "backing up" is needed.** The checkpoint's own packet is the one decoded and thrown
  away, so the index never has to describe a packet that starts on an earlier page.
  `ogg.Packets.atPageStart` says when the next packet begins a page.
- **Only `prove` makes checkpoints.** It records one while decoding whole, once the granule
  bookkeeping has a position, and never for an empty packet, since an empty packet leaves no
  overlap to rebuild. `Proven` gains `index`.
  - The mixer's `Compressed` keeps it with the bytes and frees it in `destroy`. Step 3 is the
    first to seek a stream.
  - A resident sound needs no index.
- **`rewind` is unchanged.** It is what `seek(index, 0)` does first, and a seek to 0 is
  exactly it.
- `seek` allocates nothing once `reserve` has been called. The exactness test runs on a
  failing allocator to prove it.

**Refusals, and one fix the refusals found:**
- **Refused as `InvalidSound`:** a frame past the length, and a checkpoint past the bytes. A
  checkpoint inside a page, or with the wrong page number, is refused by the Ogg walk as any
  damaged page is.
- **A checkpoint whose counts lie but stay in range** makes a decode that goes wrong. It
  reports that or ends, but never panics. Writing that test found a real overflow:
  - `trim`'s `made + step` was unchecked, and a `made` near the top of `u64` trapped.
  - It now saturates, as `position` beside it already did.
  - A whole decode never comes near the limit, so no output changes.
- **A checkpoint whose `emitted` is past the length** can never be chosen, because no frame a
  seek accepts reaches it. The check written for it was unreachable and was removed.

**Tests:**
- every fixture, as encoded and repaged so its long packets span pages;
- frames 0, 1, the last and the end, both sides of every checkpoint, and 64 seeded frames,
  each compared bit for bit over up to 1,500 frames;
- the index's order and size;
- damaged and lying checkpoints;
- the mutation sweep extended: every mutated file that decodes is proved, then sought into
  with its own index and with the original's, which is stale. In ReleaseSafe that runs over
  all 2,000 flips.

**Guards verified by breaking them:**
- skipping the throwaway packet failed the exactness and damage tests;
- treating every packet as a page start failed the exactness, index and damage tests;
- the unsaturated `made` panicked the lying-checkpoint test, which is how it was found.

**Bar:** the full bar, all exit 0. `zig build test` is **2,389/2,392** (three skips).
`zig build asset-test -Doptimize=ReleaseSafe`, the full 2,000-flip sweep with seeks, is
215/215. Decoder speed is unchanged at 961× real time on the M5. The index is built only
in `prove`, so a whole decode pays nothing for it.

Next is Step 3: start offsets and loop regions in voices, which is the first step to seek a
stream.

## Resolution — Step 3: start offsets and loop regions (2026-10-27)

A voice can now begin part-way through a sound, and a looping voice plays its intro once and
then its region. Resident and streamed voices give identical samples, buffer for buffer.

**The settings travel with the sound.**
- The loader's `Loaded` box now carries the record's `asset.mix.SoundSettings` beside the
  samples or the compressed bytes. `Stored` keeps them, so later steps' bus, priority and
  attenuation are already where `play` can read them.
- `insertSoundWith` and `insertStreamedWith` take settings directly, as a record would give
  them, and refuse a region that does not fit, by Step 1's names. `insertSound` and
  `insertStreamed` are those with the defaults.

**`play` folds everything once**, so neither the callback nor the decode task asks again:
- `start_frame` at or past the end is refused, `error.InvalidStart`, before anything is
  claimed. The public table always starts at 0, so the new error cannot reach it.
- A one-shot's region is the whole file, which it uses only to know where it ends. Loop
  points apply only to a looping voice.
- **A looping voice started past its region's end folds into the region**:
  `loop_start + (start − loop_start) mod length`. The design said only "past the end is
  refused". This is the answer for a looping start between `loop_end` and the file's end,
  and it is what Step 9's resume needs.
- The play command carries `loop_start`, `loop_end` and `start`, and the voice's cursor
  begins at `start`.

**The voice** (`voice.zig`):
- It wraps at `loop_end` by subtracting the region's length, never by resetting, so no
  fractional error builds up.
- It interpolates across the seam from `loop_end − 1` to `loop_start`.
- A streamed voice's ring frame is `Voice.streamFrame(pass, index)`. The first pass runs
  from `start` to `loop_end`, and each later pass is the region again. With the whole file
  and no start it reduces to M30's `pass × frames + index`, so every M30 pin is unchanged.

**The stream** (`mixer.zig`'s `Stream.fill`):
- A looping stream reads only up to `loop_end`, then seeks to `loop_start` with Step 2's
  `seek` on the sound's index.
- A whole-file loop therefore seeks to 0 at exactly the file's length, where M30 read to the
  end and rewound. The result is the same samples: the three-seam test is unchanged.
- A stream begun part-way seeks before its first fill, on the game thread in `play`.

**One trap found on the way.** A `Voice` built by hand with no `loop_end` has a region of
zero, and its wrap would never end. Only the voice unit tests' `monoVoice` built one, and it
hung the suite. It now sets the whole file, as the mixer always does.

**Tests:**
- exact frames from a ramp: the intro, then the region, over eight buffers; a one-shot of
  the same sound playing to its own end; a start part-way; a start folded into the region;
  `InvalidStart` claiming nothing;
- regions that do not fit, refused resident and streamed;
- **streamed equal to resident**, buffer for buffer, over at least three seams:
  - a region inside the short file;
  - an intro begun part-way with a region to the end, resampled and panned;
  - a mid-file region begun inside it;
  - a start folded into the region;
  - a one-shot begun part-way, to its retirement.

**Guards verified by breaking them**, each in its own run:
- seeking a loop to 0 rather than `loop_start` failed the streamed equality;
- wrapping by the end rather than the region's length failed the resident region and the
  streamed equality;
- dropping the fold failed the fold test and the streamed equality.

The first attempts at the second and third mutations did not compile. That is noted so a
later session checks a mutation compiled before it trusts the silence.

**Bar:** the full bar, all exit 0. `zig build test` is **2,393/2,396** (three skips).
M30's sequenced-mix pin and the court's tests are unchanged.

Next is Step 4: spatial voices.

## Resolution — Step 4: spatial voices (2026-10-27)

A voice played with a `position` is now heard where it is, against one listener. Distance,
pan and occlusion are computed on the game thread once per `update`, and the callback glides
to them across its next buffer.

**Where the pieces are:**
- **`audio/spatial.zig` is new, and pure:**
  - `Listener` and its `Basis` (position and unit right);
  - `distanceGain` for both models;
  - `cutoffFor`, logarithmic, and `onePole`, the coefficient `1 − e^(−2π·fc/fs)` through
    `core.math.exp`;
  - `place`, which returns a `Placed` of four values: the pan's two gains, `space`
    (distance gain times occlusion's gain), and the low-pass coefficient.

  The pan law is `panGains`'s, computed with `core.math.trig`. `panGains` itself is
  untouched, so every existing pin holds.
- **The mixer:**
  - `PlayParams` gains `position` and `attenuation`.
  - `play` resolves the attenuation where the ID resolves, from the store, refusing a missing
    or wrong-schema record as `UnknownAttenuation`. Its default is `Attenuation{}`. This is
    where Step 1's reference check first runs for sounds.
  - A non-finite position is `InvalidPosition`. Both are checked before anything is claimed.
  - `play` places the voice once, so its first buffer is already where the source is, with no
    glide in from unity.
  - `setListener`, `setPosition` and `setOcclusion`, each with a checked form, store state on
    the game thread.
  - `update` calls `placeSpatial`, which sends one `spatial` command per voice whose placement
    changed. If the ring refuses one, `sent` is not updated, so it goes again next frame.
- **`setPan` on a spatial voice is refused** (the checked form returns false). The position
  decides the pan.

**The callback** (`voice.zig`):
- A spatial voice sums a stereo source to mono, runs the one-pole, and multiplies by `left`,
  `right` and `space`. A mono device hears `space` alone.
- A `spatial` command arms a `Glide`. Each of the four values moves linearly from where it is
  to its target and lands exactly on the buffer's last frame, then holds.
- A coefficient of exactly 1 passes the sample through untouched, so an unoccluded spatial
  voice is not filtered at all, bit for bit.
- Non-spatial voices take the code path they always did.

**Two corrections to §5:**
- **§5.2's "within 3% of 1/d over the first third" was wrong.** The adjusted inverse curve
  differs from 1/d by `(d − near)·near/((far − near)·d)`, which never exceeds
  `near/(far − near)` of full scale: 3.4% at the default 1 m and 30 m. It is an absolute
  bound at every distance, not a relative one over a third of the range. The test holds it
  at every quarter metre.
- **§5.5's "no step at a buffer edge" bounds each glided value.** An output is a pan gain
  times `space`, so its per-frame change is bounded by both changes' shares together. The
  moving-source test checks that bound at every frame across 60 buffers, edges included, and
  that each buffer ends exactly on its target.

**Tests:**
- `spatial.zig`:
  - both distance models at the near distance, a third, half and the far distance;
  - the inverse bound and its monotonic fall;
  - pan at the four compass points, behind and overhead, and for a turned listener;
  - constant power across a full circle;
  - the near-field narrowing;
  - occlusion's gain, the one-pole's coefficient and the geometric-mean cutoff at half, with
    out-of-range amounts clamped;
  - listeners that cannot be heard from.
- The mixer:
  - a placed voice from its first buffer, its `pan` ignored;
  - the moving source;
  - stereo summed to mono, and a mono device;
  - occlusion: open is exact, fully occluded holds the device's Nyquist frequency under a
    tenth, and a steady level settles to the occluded gain;
  - every refusal.
- `sound_pipeline`: a spatial play uses its sound's attenuation record, a play may name
  another, and a sound named as an attenuation is refused. Its stack now registers
  `asset.mix`.

**Guards verified by breaking them**, each in its own run and each compiling:
- applying a placement at once instead of gliding failed the moving-source test;
- never closing the low-pass failed both occlusion tests;
- dropping the near-field narrowing failed the sweep test.

**Bar:** the full bar, all exit 0. `zig build test` is **2,404/2,407** (three skips).

Next is Step 5: voice stealing by priority.

## Resolution — Step 5: voice stealing (2026-10-27)

When every voice is busy, `play` now takes one rather than refusing. It takes the lowest
priority first, then the quietest by the game thread's estimate, then the oldest, and never
a voice of higher priority. The stolen voice fades out over 256 frames in a fade voice
`play` never claims. When every fade voice is busy, it is cut and counted.

**What §7 left to settle, and the answers:**
- **Equal priority may be stolen.** "At most the new voice's" includes equal, so two
  voices of the default 128 now replace one another rather than the second being refused.
  - An M5 test that expected `NoFreeVoice` for an equal-priority play now plays one priority
    lower to show the refusal.
  - The same is true through the public table. `audio_play` at a full mixer now takes the
    oldest of the quietest default-priority voices where it used to answer `limit`. A mod
    asking for a sound gets one, which is §7's intent. It answers `limit` only when every
    voice outranks the sound.
- **The lifetime is a zombie on the victim's slot**, not a second bookkeeping table:
  1. `play` moves the victim's sound reference, asset hold, stream and fade voice into
     `Slot.zombie`, tagged with the victim's generation.
  2. The slot then plays its new voice at the next generation.
  3. The callback reports a retirement for the victim's generation once it has stopped
     reading. The fade voice reports it through `Voice.owner`, so the event names the slot.
  4. `update` matches the retirement to the zombie and releases everything once.

  Every path reports exactly once:
  - **A fade:** the fade voice retires on its last frame.
  - **A cut, or a victim still waiting for a scheduled start:** there is nothing to fade, so
    the steal deactivates the victim and reports at once.
  - **A victim that had already ended** reported its own retirement when it ended, because
    every voice that stops in the callback reports. The steal finds it dead and adds nothing.
    The first draft reported it again, and the mutation run caught that: removing the
    redundant report changed no test, because the victim's own report had always been the
    one doing the work. The second report is gone, and with it any reliance on "the second
    finds no zombie".

  A slot whose zombie is outstanding is not stolen from again, so each slot adds at most one
  event. The events ring goes from two per slot to four, with room to spare.
- **A steal and its play go together.** `play` checks the command ring has room for both
  before claiming anything. The ring's length read by the producer is an upper bound, so the
  check is conservative.
- **The quietness estimate** is the game thread's own record: `level` (from `play`,
  `setGain` and `fadeGain`), the envelope's target (from `fade`), and a spatial voice's
  `space`. A voice placed past its far distance is 0 and goes first among equals.
- **The fade copies the voice whole**: samples or feed, cursor, ramps and placement. It
  starts a stopping linear ramp from wherever the envelope is. A stolen stream therefore
  keeps decoding until the fade ends, and its stream is retired with the zombie.

**Tests:**
- a policy table: lowest priority over a quieter higher one, quietest among equals, oldest
  among identical voices, a far spatial voice first, and a higher priority never taken (with
  nothing changed);
- the fade, sample-exact on a steady level over 256 frames, with its sound held until
  `update` hears the retirement;
- a cut with no fade voices;
- a victim that had already ended, released exactly once under `testing.allocator`;
- a victim still waiting to start, which never sounds;
- a stolen stream heard through its fade and given back after it, with no underrun.

**Guards verified by breaking them**, each in its own run:
- leaving the zombie's sound reference held failed the fade and the once-only tests;
- allowing a higher priority to be stolen failed the policy table and M5's slot test;
- halving the fade failed the sample-exact fade.

**Bar:** the full bar, all exit 0. `zig build test` is **2,408/2,411** (three skips).

Next is Step 6: the bus tree.

## Resolution — Step 6: the bus tree (2026-10-27)

A game now mixes through buses: `Mixer.useMix(root)` builds the tree of every
`foundry:audio_bus` whose chain of parents reaches `root`. Each voice mixes into its sound's
bus, and each bus applies its gain and adds itself into its parent. Effect chains are
accepted and checked, and Step 7 runs them.

**Where it is:**
- **`audio/bus.zig` is new.** `bus.build` reads the records on the game thread and allocates
  everything the callback touches:
  - one buffer per bus below the root, a device buffer long;
  - each bus's gain ramp;
  - `voice_bus`, every voice's bus in the new tree.

  Indices are the root at 0, then the rest by ascending content ID. `order` is post-order,
  children before parents, siblings by index, so the summation order never follows load
  order.
- **The mixer:**
  - `useMix` and `contentChanged` build a tree and hand it over with one `swap_mix` command.
    The callback installs it between two buffers, re-routes every voice from `voice_bus`, and
    sends back a `tree` event.
  - `update` frees the tree the event releases. Trees awaiting release are kept oldest first,
    at most four (`SwapPending`), which is what the events ring's four extra entries allow.
  - `setBusGain` ramps a bus's game gain.
  - `misrouted()` counts plays whose sound names a bus outside the tree. They are mixed at the
    root.

**What §8 left open, and the answers:**
- **A bus's output gain is the record's gain times the game's** (`setBusGain`), not one or
  the other. §8.4 already gave the music bus's gain to the player's slider. A reload then
  sets the record's factor and leaves the slider's alone, and neither overwrites the other.
  This is §8.4's argument, applied to every bus.
- **The master gain applies after the root's own gain.** `setMasterGain` keeps its meaning,
  and the public table's `audio_set_master_gain` with it. §8.1's "the root's gain is the
  master gain" becomes "the master gain multiplies the root's".
- **A device buffer longer than the tree's block is mixed in blocks.** The tree's block is
  the device's buffer size. A real device always hands the size it promised, but the stepped
  null device takes any size, so the tree path loops in blocks with the clock moving per
  block. A spatial glide then spans a block, not the whole call; on a real device the two are
  the same.
- **On a swap, a voice follows its sound's bus into the new tree**, computed from the game
  thread's record of each slot and each zombie's fade voice. A voice routed to the root
  because its bus was missing is re-routed when a reload adds that bus.
  - Commands queued before the swap use the old indices, and those after it the new ones. The
    ring is first in, first out, so both meet the tree they were computed against.
- **A parameter change is a gain change.** Two trees have the same shape when their buses,
  parents and effect lists match. Then `contentChanged` sends a `bus_base` for each changed
  gain and the tree plays on. Effect parameters join this in Step 7.
- **No tree is M30's mixer exactly**, by structure. The M30 path is the same code, with the
  voice loop moved into `mixVoices` unchanged, and M30's pinned sequence passes untouched.
  Criterion 9's half is held here.
- **Refusals**, on the game thread, with the mix carrying on unchanged:
  - `NotABus`: the root is not a bus, or a bus's parent is not one;
  - `RootHasParent`;
  - `Cycle`: a chain longer than the number of buses;
  - `TooDeep`, past 8;
  - `TooManyBuses`, past 32;
  - `InvalidBus`: a record that does not decode, or an effect that is not an effect record,
    the reference check Step 1 wrote.

**Tests**, in `sound_pipeline`, with packages built into owned bytes (`addPackage`), since
the store borrows a package's bytes:
- the tree's members, indices and order;
- each voice's level through its chain of gains;
- a misrouted voice at the root, counted;
- the master gain after the root;
- `setBusGain`'s ramp across six blocks of a long buffer, and its refusals;
- every refusal;
- a gain reload keeping the tree;
- a shape reload swapping it, re-routing a playing voice, and freeing the old tree under
  `testing.allocator`.

**Guards verified by breaking them**, each in its own run:
- adding a parent before its children (pre-order) failed the order and gain test;
- not counting a misroute failed it too;
- treating every reload as a shape change failed the reload test;
- leaving every voice at the root on a swap failed the re-routing check.

**Bar:** the full bar, all exit 0. `zig build test` is **2,412/2,415** (three skips).

Next is Step 7: filters, the delay and the reverb.

## Resolution — Step 7: filters, delay and reverb (2026-10-27)

Buses now run their effects. Each bus applies its chain in order to its buffer before its
gain, and the root before its gain, the master gain and the clamp. The filter, delay and
reverb are built. The compressor and limiter are accepted into a chain and pass audio through
until Step 8.

**`audio/effects.zig` is new:** `Unit` holds one effect's state, with `init` on the game
thread when the tree is built, `process` in the callback, and `set` for new parameters.
`bus.build` decodes each bus's effects where their IDs resolve and allocates their units,
flattened per tree with each bus's slice. `Tree.effect_values` keeps the parameters as last
sent, on the game thread.

**What §9 left open, and the answers:**
- **The filter's ramp runs in fixed sub-blocks of 32 frames**, not "8 sub-blocks per
  buffer". A sub-block of fixed length sweeps at the same rate whatever the device's buffer
  is.
  - The frequency moves on a logarithmic scale, and Q and gain linearly.
  - The coefficients are recomputed at each sub-block while a ramp runs, and once at its end,
    exactly to the target.
  - A reload's change ramps over one buffer, and `setEffect`'s over the frames it is given.
  - A change of shape within a filter is a parameter change: the shape switches at once and
    the frequency ramps.
  - A frequency at or above 0.49 of the device rate is held there, below Nyquist, where every
    shape is defined.
- **The reverb's lines:**
  - Each line's length is the next prime at or above its nominal length times `size`, and
    above the line before it. Primes are mutually prime, which is what "mutually prime
    lengths" needed.
  - Damping is a one-pole per line with coefficient `1 − 0.8·damping`. At 0 it is exactly no
    filter.
  - The input is the channels' mean after the predelay. The left output is the even lines
    and the right the odd, each times ½. A mono device hears their mean.
- **What is fixed per tree** is what sizes memory: a delay's `time`, a reverb's `size` and
  `predelay`, and the limiter's `lookahead` (Step 8). `effects.fixedEql` decides it.
  - A reload that changes one of these is a change of shape, and swaps the tree.
  - A reload that changes anything else sends `effect` commands and keeps every tail.
  - `setEffect` refuses a change to a fixed field, since that is a reload's job.
- **`setEffect(bus, slot, effect, frames)`** validates by the records' ranges and refuses a
  bus or slot that is not there or an effect of another kind.

**Measured** (`effects.zig`'s tests):
- each of the six shapes at f₀/2, f₀ and 2f₀, from a settled sine, is within 0.1 dB of the
  RBJ formula computed independently in `f64` with `std.math`;
- the reverb's T30, extrapolated from its impulse response's Schroeder integral, is within
  10% of `decay` at 0.3, 0.6, 1.5, 3 and 5 s, and damping shortens it;
- the delay's echoes land on exactly frame `round(time · rate)` and its multiples, at `wet`
  and then `wet · feedback`, with silence everywhere else;
- a 12,000-frame sweep from 20 kHz to 800 Hz on a full-scale Nyquist signal stays finite and
  bounded, and ends exactly on the target's coefficients.

**Integration** (`sound_pipeline`):
- a root's low-pass all but removes a Nyquist buzz, and `setEffect` retunes it to a
  high-pass that passes it;
- every `setEffect` refusal;
- a reload that changes a reverb's decay and wet keeps the tree and its values;
- a reload that changes its size swaps the tree and frees the old one.

**Guards verified by breaking them**, each in its own run:
- a wrong Hadamard normalisation failed the reverb's decay;
- one low-pass coefficient off by 1% failed the magnitude test;
- skipping the root's chain failed the bus filter test;
- ignoring a delay's time in `fixedEql` failed its unit test and `setEffect`'s refusals.

**Bar:** the full bar, all exit 0. `zig build test` is **2,420/2,423** (three skips).

Next is Step 8: the compressor, the limiter, `mixerLatency()` and the mixing-speed test.

## Resolution — Step 8: compressor and limiter (2026-10-27)

The last two effects are built. A bus may now compress, and the master may limit so that
nothing passes its ceiling. `mixerLatency()` reports what the limiters add, and a timing test
measures the whole court-shaped mix.

**The compressor** (`effects.Compressor`) is §9's as written:
- the channels' peak in decibels through `core.math.exp.gainToDb`;
- the soft-knee static curve;
- attack and release as one-pole smoothing of the reduction, with coefficient
  `e^(−1/(t·fs))` through `exp2`;
- makeup.

It costs one `log2` and one `exp2` a frame.

**The limiter** (`effects.Limiter`):
1. It delays the signal by `lookahead`.
2. It keeps each frame's required gain in a ring.
3. A monotonic deque gives the sliding minimum over the window, at constant time per frame.
4. It averages that minimum over the window. Every window that contains the frame now
   leaving has a minimum at most that frame's requirement, so the average is too, and the
   gain arrives as a ramp across the lookahead rather than a step.
5. Release is a one-pole back up.

Two refinements the design did not foresee:
- **The gain is also held to the leaving frame's own requirement**, `min(gain, leaving)`.
  The running sum behind the average is `f64`, but it is still rounded. This makes the
  guarantee exact rather than nearly so. It never engages beyond that rounding, and the
  attack-ramp test shows the averaging is what does the work.
- **The product is held to ±ceiling.** A sample times `ceiling / peak` rounded one unit in
  the last place above the ceiling on the first run (`−0.891251` against `0.89125097`). The
  gain was right; the multiplication rounded. The hold corrects only that.
  - So the hold cannot hide a broken gain, the limiter records `unheld`, its largest product
    before the hold.
  - The ceiling test requires `unheld` to be within a millionth of the ceiling, so the gain
    alone keeps it there, up to rounding.

**`mixerLatency()`** is the longest path's sum of limiter lookaheads, bus by bus up to the
root. A unit's lookahead is fixed when the tree is built, so the game thread reads it safely.
The sample clock still counts mixed frames, and scheduled starts are exact against it.

**Measured:**
- The compressor settles within 0.25 dB of the static curve, computed independently in `f64`,
  at 13 levels from −60 to 0 dB on a steady level.
- Its attack reaches 1 − 1/e of a step's reduction in 10 ms, and its release falls to 1/e in
  150 ms, each within 10%.
- No limited sample exceeds the ceiling, and `unheld` stays within rounding of it, over:
  - seeded random input up to four times full scale;
  - 32 summed full-scale sines;
  - 200 sparse impulses of 8;
  - square waves of ±3 at periods 2, 7, 96, 97 and 1000;
  - steps from 0.1 to 5.

  Each is processed in blocks of seeded sizes from 1 to 512 frames.
- Quiet audio passes exactly, sample for sample, 96 frames late at the 2 ms default.
- A jump to five times full scale is met by an even ramp over the lookahead, its steepest
  step within one 97th of the drop, ending exactly on the requirement.
- `mixerLatency()` sums a path: 96 on the master plus 240 on a world bus is 336.
- **Mixing speed** (`sound_pipeline`, optimized builds only): the court-shaped load is
  - 32 looping voices, all resampling;
  - 16 of them spatial, half the effects occluded;
  - six buses, with the master's limiter and the world's reverb, compressor and filter.

  **98× real time on the M5 in ReleaseSafe**, single-threaded, against criterion 6's 20×,
  which the i3 decides at Step 11. The test skips in Debug, as the stream margin does, so the
  bar now shows four skips.

The ReleaseSafe integration run's only failure is the Mac's `ui_theme` test, open for the
owner since M30, which M31 does not touch.

**Guards verified by breaking them**, each in its own run:
- using the window minimum without its average failed the attack-ramp test, which is why
  that test was written: the hold to the leaving frame's requirement keeps the ceiling on its
  own, so only a test of the ramp can see the averaging;
- swapping attack and release failed the time-constant test;
- summing only a bus's own chain failed `mixerLatency`'s test.

**Bar:** the full bar, all exit 0. `zig build test` is **2,426/2,430** (four skips; the new
one is the mixing-speed test in Debug). `zig build integration-test -Doptimize=ReleaseSafe`
passes everything except `ui_theme`, as above.

Next is Step 9: `Music` on loop regions and resume, and the M31 sequenced mix pinned.

## Resolution — Step 9: `Music` on loop regions and resume, and the M31 pin (2026-10-27)

`audio.Music` now plays a title's intro once and loops its body, and resumes a playlist where
it was left. The M31 sequenced mix is pinned.

**What §10 left to settle, and the answers:**
- **`Mixer.SoundInfo` gains three fields**: `source_frames`, `step` (source frames per device
  frame at pitch 1) and `loops` (the record gives a loop region). `Music` still reaches the
  mixer only through public game-thread calls.
- **One looping voice** is a playlist with `loop`, one track, and that track's sound giving a
  loop region. Its head lasts forever (`maxInt`), and every sum on a head's end saturates, so
  nothing is scheduled after it until a switch. A track with no loop region, or a playlist of
  several, behaves exactly as in M30, so M30's pin is unchanged.
- **The beat grid of a looping track runs from the track's start**, through its intro and on.
  A body of whole bars keeps every later bar line on the music, which is how the court's title
  is written (Step 10).
- **Leaving a playlist** records its order, position and source frame:
  - The source frame is `start_frame + (at − start) × step`, at the frame `at` its replacement
    starts, or at the clock for `stop`, which §10.2 did not mention but plainly leaves a
    playlist too.
  - A track already played out resumes at the next one.
  - Up to eight playlists are remembered, the oldest dropped first.
  - A saved point is used once, and only if the playlist still has the same number of tracks.
- **Resuming** starts the saved track at its frame with `start_frame` (Step 3), fading in over
  the crossfade. Its head lasts the remaining `(source_frames − frame) / step` device frames,
  rounded up, so the next track follows on time.
- **A resumed track keeps its own beat grid.** Its beat one fell `start_frame / step` device
  frames before it resumed, and `gridPoint` counts from there. Without that, a switch away
  from a resumed track would land on bars measured from the resume, which is not where the
  music's bars are. A test pins it: a track stopped mid-bar and resumed is switched away from
  at 33,408, its real bar line, rather than at 42,624.

**The pin.** `m31Mix` runs a six-voice stereo mixer through the court's kind of tree:
- a limiter at −3 dB on the master;
- a delay on the music bus;
- reverb, compressor and a filter swept from 20 kHz to 800 Hz on the world bus.

Over 400 buffers it plays:
- a title looping its region;
- a resumed playlist through a switch to a tempo'd chase and back;
- a moving spatial hum and an occluded one;
- a run of low-priority ticks that steal past the six voices.

Every start lands on the frame it asked for, with no late starts, dropped commands or misroutes.
**The hash `11458463935403524307` is the same twice in a run, in Debug, in ReleaseSafe, and in
an x86_64-macos build under Rosetta** (`zig build integration-test -Dtarget=x86_64-macos
-Dplatform=null -Drhi=null -frosetta`, 148/151 with its usual skips). Every coefficient, pan
and decibel in the mix is `core.math`'s arithmetic. Criterion 5 holds on the Mac; Step 11
checks it on the PC.

**Tests** (`music_sequencing`, whose stack now registers `asset.mix` and takes options):
- a loop-region title as one start, with every sample after its fade the region's, exactly;
- a resume, with exact start frames, the resumed samples equal to the source from frame
  10,240, and the next track at 56,384 from the remaining length;
- a playlist without `resume` starting from 0;
- the grid test;
- the pin.

**Guards verified by breaking them**, each in its own run:
- never playing as one voice failed the loop test;
- never recording a leave failed the resume, grid and pin tests;
- ignoring the resumed start in the grid failed the grid test, which was written for it;
- using the whole length for a resumed head failed the resume and pin tests.

**Bar:** the full bar, all exit 0. `zig build test` is **2,430/2,434** (four skips).

Next is Step 10: the court's mix, proved on the Mac.

## Resolution — Step 10: the court's mix, proved on the Mac (2026-10-27)

`samples/court` is now mixed as a 3D game is:
- the warden's steps, the gate and the beacons are spatial voices, placed by the engine from
  the walker's eye and muffled by what one ray finds in the way;
- music, the world (effects and ambience) and the menus run on buses under a master limiter;
- the world carries the courtyard reverb, a gentle compressor and a low-pass that a pause
  sweeps down;
- the options have master, music and effects sliders;
- the title plays its intro once and then loops its body, and calm resumes after a chase;
- `nocturne` lengthens the reverb and echoes the music, with no code.

**Where it is:**
- **`court.fdt`:**
  - every `.wav` now has an authored `foundry:sound` record, which speaks for its file so
    nothing is derived for it, naming its bus and priority: footsteps 32, the warden 64,
    gate and beacons 128, ambience 160, the endings and clicks 200, and every track and
    stinger 255;
  - `court:attenuation.warden` (1.5–16 m) and `court:attenuation.prop` (2–24 m);
  - the buses and effects of §11, exactly as written, with the limiter at −1 dB;
  - `court:mix.main`, a `court:mix_set` naming the master, the music and world buses, the
    muffle, its pause frequency (800 Hz) and its sweep (0.25 s), so `sounds.zig` names no bus;
  - the title's loop region, at 960,000 and 1,920,000 frames, and `resume true` on calm;
  - `music_volume` and `effects_volume` in `court:config` and labels in `court:text`, each with
    a default, so `noon`, which overrides both records whole, compiles unchanged.
- **`make_court_music.py`:** the title is eight bars of chords and bass, then an eight-bar
  body with the melody and soft hats, 40 s in all. The body's tail wraps into its own first
  bar and nothing is faded at the end, so the loop seam is the music carrying on. The script
  prints the loop points. Regenerated, **only `title.ogg` changed; the other nine files are
  byte for byte the same**, which is §11's comparison: the generator is deterministic and
  there is no separate test.
- **`sounds.zig`:**
  - `place` is deleted;
  - `onEvents` plays the gate, beacons and warden steps with a `position` and a starting
    occlusion;
  - `frame` sets the listener from the eye and look, then, for each spatial voice still
    playing (up to 16 tracked), moves it to its source (the warden's body, the sinking gate, or
    the beacon where it stands) and steps its occlusion an eighth a frame toward the ray's
    answer;
  - `useMix`, `applyVolumes` and `setPaused` carry the mix.
- **Preferences:** `court:preferences` is version 2, adding the two volumes after the first
  five, with a migration from version 1. An M30 file loads and keeps its values; the new two
  are the content's until moved. `volume` is the master gain, `music` the music bus's game
  gain and `effects` the world bus's, each ramped over 20 ms.
- **`main.zig`:** the mix is built after the loader is registered. The listener, rays and
  placement now run inside the `audio` scope, before `Mixer.update`, so criterion 6's measure
  includes them and the placement is the same frame's. The volumes are logged at start.
- **`nocturne`:** overrides `court:fx.courtyard` (decay 3.2 s), adds `nocturne:fx.echo` (0.3125 s,
  three eighths of a beat at 72 bpm) and overrides `court:bus.music` to carry it. Its own
  tracks and beacon stinger gained authored records routing them to the music bus; derived,
  they would have mixed at the root, past the music slider.
- **The evidence log:** every ten seconds and at exit, a `mix` line beside the `music` one:
  voices stolen, steals cut, plays misrouted, samples past the ceiling, and the deepest
  limiting in dB. Each pause and resume logs its sweep. A scripted run is now clean only with
  nothing misrouted and nothing past the ceiling as well.

**What §11 left open, and the answers:**
- **The over-ceiling counter is counted in the callback, not by a test hook.** §11 asked for
  a counter in the court's log and also said the hook counts "on the stepped device, never in
  the callback". A ten-minute run on a real device cannot be read any other way, so each
  limiter counts the samples its gain left more than a rounding past the ceiling, before the
  final hold, and its lowest gain. The mixer collects both once a buffer into two atomics,
  `overCeiling()` and `deepestLimit()`. It costs one comparison a sample. The stepped device's
  stress test reads the same counters.
- **A spatial play takes a starting `occlusion`** (`PlayParams.occlusion`, clamped, non-finite
  refused as `InvalidPosition`). Without it a warden step behind the wall began unmuffled and
  glided to muffled over its first buffer, which is a fifth of a 0.11 s step.
- **Occlusion is one ray, ears to source, against the level layer**, stopping 0.3 m short so
  the ground under a source is not in its way. The gate's own sound leaves the gate's body
  out; the warden's is heard from the middle of its body, not its feet. The answer is 0 or 1,
  and the court eases toward it, so a source passing behind a wall is muffled over about
  0.13 s.
- **`hearing_distance` is deleted from `court:sound_set`**, not kept "as the music's chase
  trigger": the chase has always been `court:music.main`'s `chase_distance`, and nothing read
  the field once `place` went.
- **Which buses the sliders move** is content (`court:mix.main`), not names in code.

**Tests:**
- `sound_pipeline`: a loud 16-voice mix through the court-shaped tree is limited by the gain,
  with nothing past the ceiling, and no tree counts nothing.
- `mixer`: a play occluded from the start is muffled in its first buffer (past the one-pole's
  first 32 frames, its own start-up), and a non-finite occlusion is refused.
- Court, against the real content:
  - every sound's bus and priority, every track and stinger on the music bus at 255, the tree
    built with nothing misrouted and a 96-frame latency, the muffle found at slot 2;
  - the title's loop points and 1,920,000 frames, and 46 s of play as one start, one voice and
    no underrun;
  - `nocturne`'s reverb, echo and routing, with the tree building either way;
  - the gate occluding a sound behind it, its opening clear without it, and nothing between
    the ears and a nearer source;
  - an M30 preferences file loading unchanged, then written at version 2 and read back;
  - the music and effects sliders stepping in the options menu.

**Guards verified by breaking them**, each in its own run:
- a limiter whose gain stays at 1 failed the over-ceiling test;
- an occlusion ray that never reports a hit failed the gate test;
- a muffle slot never found failed the mix test;
- preferences without their migration failed the M30-file test.

**Runtime evidence:** M5, SDL3 `cocoa`, Metal, ReleaseSafe, 4× MSAA and shadows.
- `zig build dist -Dapp=court` staged the bundle with its 50 files (revision
  `e6ca301+m31-step10`). Its zip was extracted into scratch, made read-only and run with
  `env -i`, `PATH=/usr/bin:/bin` and a disposable preferences root per run. The files hash
  the same after the runs.

| Run | Frames | Starts asked / on their frame / cancelled / pending | Underruns, late, dropped, refused | Stolen, cut, misrouted, past ceiling | Deepest limiting | `audio` median / p95 |
| --- | --- | --- | --- | --- | --- | --- |
| win | 1,217 | 17 / 15 / 0 / 2 | 0, 0, 0, 0 | 0, 0, 0, 0 | 0.0 dB | 0.0003 / 0.0091 ms |
| caught | 110 | 4 / 1 / 0 / 3 | 0, 0, 0, 0 | 0, 0, 0, 0 | 0.0 dB | 0.0003 / 0.0008 ms |
| fell | 186 | 4 / 1 / 0 / 3 | 0, 0, 0, 0 | 0, 0, 0, 0 | 0.0 dB | 0.0003 / 0.0023 ms |
| soundtrack 1 | 7,094 (interrupted) | 9 / 9 / 0 / 0 | 0, 0, 0, 0 | 0, 0, 0, 0 | 0.0 dB | 0.0002 / 0.0018 ms |
| soundtrack 2 | 40,553 | 82 / 81 / 0 / 1 | 0, 0, 0, 0 | 0, 0, 0, 0 | 0.0 dB | 0.0001 / 0.0015 ms |
| soundtrack 3 | 40,553 | 82 / 81 / 0 / 1 | 0, 0, 0, 0 | 0, 0, 0, 0 | 0.0 dB | 0.0002 / 0.0019 ms |
| soundtrack 4 | 40,553 | 82 / 81 / 0 / 1 | 0, 0, 0, 0 | 0, 0, 0, 0 | 0.0 dB | 0.0002 / 0.0017 ms |
| nocturne soundtrack | 40,553 | 81 / 75 / 5 / 1 | 0, 0, 0, 0 | 0, 0, 0, 0 | 0.0 dB | 0.0002 / 0.0017 ms |

The pending starts at exit were asked for within the last frames before the process
stopped. The five cancelled under `nocturne` are tracks retired behind a fading one, as at M30.

- **Every run is clean on every count**: no start missed, no underrun, late start, dropped
  command, refusal, steal, misroute or sample past the ceiling. Every replay matched a fresh
  simulation at every tick, and the endings are unchanged.
- **Criterion 6, main thread:** the `audio` scope, now with the listener, up to 16 rays and
  placement, stays at a p95 of 0.0015–0.0091 ms against 0.10.
- **Criterion 7:** the `nocturne` run selected the mod from the user root and played 208 of
  208 steps clean. The test proves what it changes.
- **Each pause swept the world's low-pass**, 800 Hz on pause and back to 20 kHz on resume,
  ten sweeps a soundtrack run.
- **The limiter never had to act.** The deepest limiting in every run is 0.0 dB: at the
  court's own levels nothing reaches −1 dB. The ceiling is held by the limiter's stress tests
  and the court-shaped one above, not by this sample.
- **The first soundtrack run was interrupted** when the window lost focus at tick 3,504, a
  minute in, while the Mac was in use. Losing focus pauses the game, and the script fails a
  pause it did not ask for, as M30 Step 7's third run did. Its 7,094 frames were clean. It was
  replaced by a fourth run from a bundle restaged after one change: the cost line's label,
  which now names placing, a log string only.
- **The sliders across a restart** are not something a script can show: scripted runs write
  no preferences, by design (§8). They are proven by the court's preference tests, a write
  at version 2 read back by a fresh `Preferences` and an M30 file migrated. The owner's
  listening check covers the window.

**Criterion 9:** M30's sequenced-mix pin and the 2D samples are unchanged; the full bar holds
them.
In ReleaseSafe, `integration-test` passes except the known Mac `ui_theme` test. The M30 and M31
sequenced-mix pins hold with the limiter's new counters in the callback, and the mixing-speed
test reads **100× real time** on the M5.

**Bar:** the full bar, all exit 0. `zig build test` is **2,437/2,441** (four skips).

**Listening.** The owner is offered a check of the court on the Mac: the title's intro into
its loop, the warden behind the low wall and the gate, the pause muffle, the three sliders
across a restart, and `nocturne`'s longer room and echo. It is not an exit criterion.

Next is Step 11: Windows/Vulkan on the Arc PC.

## Resolution — Step 11: Windows/Vulkan on the Arc PC (2026-10-27)

Criteria 5–9 hold on the Arc A750 (i3-10105F, Windows 11, WASAPI through SDL3), at `e5e4d78`.
No engine or sample code changed in this step.

**How it ran:**
- **The clone:** `main` at `m30` from GitHub, then M31's eleven unpushed commits from a git
  bundle, so the PC built exactly the Mac's commit and nothing went to GitHub.
- **The harness:** `scripts/m31/windows.ps1`, M30's with M31's expectations.
  - `build` mode, over SSH: the suites, the optimized tests and a relocated, read-only
    ReleaseSafe install.
  - `desktop` mode, from a scheduled task in the player's session: the court, where nothing
    took focus.
  - Every run is at `-j2` and below-normal priority, gated on the PC's CPU.

**The suites:**
- `zig build test -Dplatform=null -Drhi=null`: 2,416/2,429 (13 skipped).
- `zig build test vulkan-test -Drhi=vulkan`: 2,697/2,721 (24 skipped), validation and
  synchronization required by the test binaries themselves.
- ReleaseSafe `asset-test court-test`: 268/269 (one skip), which covers the seek sweep, the
  court's mix, occlusion and preferences tests.
- ReleaseSafe `integration-test`: 148/153 (five skipped), with none failing.
  - **Criterion 5:** both pins pass unchanged, so the M31 sequenced mix
    (`11458463935403524307`) and M30's are equal on the PC, in ReleaseSafe on x86_64, to the
    Mac's. No difference to record.
  - **`ui_theme`** passes here, as in M30. Its failure is the Mac's alone.

**Criterion 6:**
- **Mixing speed:** the court-shaped load (32 voices, 16 spatial, six buses, four effects)
  mixes at **39× real time on the i3**, single-threaded in ReleaseSafe, against 20×. The M5
  does about 100×.
- **Command delivery** on the player's device: 400 plays at 48 kHz in 512-frame buffers,
  none slipped.

**The court**, from the relocated install, `env`-scrubbed, with disposable preferences and
user roots. The install hashed the same after the runs, and no preferences were written.

| Run | Layers | Steps | Frames | `audio` p95 | Starts on frame | Deepest limiting |
| --- | --- | --- | --- | --- | --- | --- |
| soundtrack 1 | off | 208/208 | 40,554 | 0.0177 ms | 81 of 82, 1 pending | 0.0 dB |
| soundtrack 2 | off | 208/208 | 40,552 | 0.0204 ms | 81 of 82, 1 pending | 0.0 dB |
| soundtrack 3 | off | 208/208 | 40,555 | 0.0173 ms | 81 of 82, 1 pending | 0.0 dB |
| soundtrack | validation | 208/208 | 40,551 | 0.0162 ms | 81 of 82, 1 pending | 0.0 dB |
| `nocturne` | off | 208/208 | 40,553 | 0.0180 ms | 75 of 81, 5 retired, 1 pending | 0.0 dB |
| `nocturne` win | validation | 46/46 | 1,209 | 0.0364 ms | 16 of 17 | −0.3 dB |
| win | validation | 46/46 | 1,209 | 0.0349 ms | 15 of 17 | 0.0 dB |
| caught | validation | 7/7 | 100 | 0.0033 ms | 1 of 4 | 0.0 dB |
| fell | validation | 6/6 | 177 | 0.0097 ms | 1 of 4 | 0.0 dB |
| win | off | 46/46 | 1,211 | 0.0258 ms | 15 of 17 | −0.9 dB |
| caught | off | 7/7 | 100 | 0.0039 ms | 1 of 4 | 0.0 dB |
| fell | off | 6/6 | 177 | 0.0112 ms | 1 of 4 | 0.0 dB |

- **Every run is clean on every count:**
  - no start missed, no underrun, late start, dropped command or refusal;
  - no steal, misroute or sample past the ceiling;
  - every sound asked for was played;
  - every replay matched a fresh simulation at every tick;
  - the endings are unchanged.
- **Validation** logged its live info line and nothing else in each of the six runs under it.
- **Criterion 6, main thread:** the `audio` scope's p95 is 0.016–0.036 ms against 0.10, about
  four times the Mac's figure on the slower CPU. The highest are the short win runs, whose
  1,200 frames are mostly the ending's busiest seconds.
- **Criterion 7:** `nocturne` was selected and played clean. It retired five starts before
  they began, the same count as the Mac's `nocturne` run in Step 10.
- **Each pause swept the world's low-pass:** ten sweeps a soundtrack run, two a win.
- **The limiter acted in the court on the PC,** which it never did on the Mac. In two win
  endings the victory stinger met the music at device timing that differs from the Mac's,
  and the limiter took the peak down by 0.3 and 0.9 dB, with no sample past the ceiling. The
  simulation is identical, so the overlap that reached the ceiling is a matter of buffer
  timing, not of the game.

**Criterion 8, the sliders kept across a restart:** proven by the court's preference tests,
which pass on the PC in ReleaseSafe. Scripted runs write no preferences, by design (§8).

**Listening:** the owner listened to the court on the Mac (Step 10's runs) and on the PC
(these runs) and reported that the sound was right on both.

**Bar:** the tree is Step 10's, whose full bar passed, plus this step's PowerShell harness
and documents. No Zig, content or build file changed, so the bar was not rerun.

**PC paths to remove at the close, by exact name:**
- `%USERPROFILE%\src\Foundry-m31`
- `%USERPROFILE%\m31`
- `%USERPROFILE%\state-m31.ps1`
- Zig's cache under `%LOCALAPPDATA%\zig`

Next is Step 12: close M31.
