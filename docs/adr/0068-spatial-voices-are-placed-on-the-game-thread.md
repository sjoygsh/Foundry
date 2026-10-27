# ADR-0068: Spatial voices are placed on the game thread, and output stays stereo

**Status:** Accepted 2026-10-27 (the owner asked for M31 Step 1; `docs/design/mixing.md`); implemented in M31 (2026-10-27, tag `m31`)
**Date:** 2026-10-27

## Context

ADR-0023 said spatialisation "arrives with 3D if at all". 3D arrived in M19–M26, and the court
places its warden and gate with a dozen lines of its own arithmetic: gain falling linearly to a
hearing distance, ignoring height, and pan from the direction against the yaw, set once per
frame with `setGain` and `setPan`. `playable3d.md` §13 made that "the budget M31 must beat".

The choices are where the computation runs, what it models, and what output it targets:
- **The callback** could compute gains per sample from positions, but positions change once
  per game frame, and the callback has no use for trigonometry it would repeat 48,000 times a
  second.
- **The court's per-frame `setGain`** steps once per frame and is audible as zipper noise on a
  moving source.
- **Occlusion** needs geometry, which only the game has.

## Decision

1. **One listener and a position per spatial voice, both on the game thread.**
   - `setListener` takes a position, forward and up, in ADR-0048's conventions.
   - `PlayParams.position` makes a voice spatial, and `setPosition` moves it.
   - Both are presentation (I9): set after the tick from the state it left, never read by one.
2. **`Mixer.update` computes, once per frame**, each spatial voice's left gain, right gain and
   low-pass cutoff:
   - distance from a `foundry:audio_attenuation` record, `inverse` (1/d reaching zero at
     `max_distance`) or `linear`, in three dimensions;
   - constant-power pan from the source's direction against the listener's right, narrowing to
     the centre inside `min_distance`, computed with `core.math.trig`;
   - occlusion as an amount the game supplies, which scales the gain and closes a per-voice
     one-pole low-pass.

   **The callback interpolates the three values across its next buffer**, so a moving source
   changes with no step.
3. **Output stays stereo.** A stereo source played spatially is summed to mono.
4. **Not in this decision:**
   - HRTF and front–back cues (M144);
   - Doppler (M55);
   - occlusion computed by the engine from world geometry (M60);
   - surround output. It stays refused by name (`UnsupportedChannelCount`) and is not
     planned.

## Consequences

- Placing every spatial voice is a few dozen multiplies and one square root each on the game
  thread. The court's main-thread budget of 0.10 ms p95 must hold with it included.
- The callback gains three linear ramps per spatial voice and a one-pole filter while a voice
  is occluded, which is arithmetic only.
- Positions are at most one game frame plus one buffer behind the game, about 27 ms at 60 Hz
  with a 512-frame device. That is below what a listener can place.
- Front and back sound alike, which is stereo's limit and is accepted until M144.
- A game decides what occludes what. The court uses one ray per voice. A game with portals uses
  its portals, and the mixer does not care which.

## Alternatives considered

- **Compute per sample in the callback.** Rejected: positions change at the frame rate, so
  per-sample trigonometry buys nothing over a per-buffer ramp and moves work onto the thread
  with a deadline.
- **Leave spatialisation to games**, as the court does today. Rejected: every 3D game would
  rewrite the same distance and pan arithmetic, and none could ramp it, because `setGain` and
  `setPan` step.
- **Clamped 1/d with no end.** Rejected: it never reaches zero, so a game hears everything at
  any range or adds a step to cut it off.
- **A biquad per voice for occlusion.** Rejected: a biquad swept every frame can go unstable,
  and a one-pole cannot.
- **HRTF now.** Rejected: it needs measured impulse-response data, a dataset licensing decision
  and convolution per voice. Its first real need is a tracked head on headphones, which is M144.

## Revisit if

- **A game targets home-theatre output**, or a platform's device offers only more than two
  channels. Surround panning (VBAP over the device's layout) would then be decided.
- **Spatial placement exceeds its share of the 0.10 ms main-thread budget** at a real game's
  voice count. The computation would then move to `core.Jobs`, or into the callback per buffer.
- **A game needs more than one listener**, such as split-screen. The model is then a listener
  per output mix.
