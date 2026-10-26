# ADR-0066: Streamed voices decode on the background pool, and music is sequenced on a sample clock

**Status:** Accepted 2026-10-26 (the owner asked for M30 Step 1; `docs/design/music.md`); being implemented in M30
**Date:** 2026-10-26

## Context

ADR-0023 built voices that read resident `f32` samples, and designed the model "so a voice
pulling from a decoder rather than a buffer is not a redesign". `audio.md` §12 called music
sequencing "game policy built on `play` and `setGain`, not engine mechanism". M30 builds both,
streamed music and sequencing, and implementing them shows that the second claim falls short:
- `setGain` applies at the next callback, so a crossfade built from it steps once per frame
  and clicks.
- A track started with `play` begins at whatever callback the command reaches. Two tracks
  meant to overlap by exactly two seconds, or a stinger meant to land on a beat, cannot be
  placed to the sample from the game thread.
- Only the callback knows which frame is being mixed.

The decisions below fix where decoding runs, what the mixer gains, and where sequencing lives.
Later milestones inherit them: M31's buses and spatialisation, M48's table and M60's
streaming.

## Decision

1. **A streamed sound stays compressed in memory**, whenever its `foundry:sound` record says
   `stream true`.
   - It is decoded once in full at load, on the pool, to prove it, and the samples are
     discarded. A stream decode can then treat failure as impossible, and a bad track is
     refused by name at load.
   - It is decoded while it plays into a fixed ring of one second per stream. Streams come from
     a fixed table, four by default, allocated at the mixer's `init`.
2. **Decoding runs on the background pool** (`core.Tasks`, ADR-0061), never on the device
   thread and never on the game thread.
   - `Mixer.update` starts a decode task for each stream whose ring is below half full and has
     no task in flight. A stream never has two tasks in flight.
   - The callback still only reads, which keeps the ring single-producer and single-consumer.
3. **An underrun keeps the timeline.** The voice writes silence, counts it, advances its
   position, and discards the missed frames when they arrive.
4. **The mixer gains four mechanisms**, all on the game thread's side of the command ring:
   - **a sample clock:** frames mixed, published by release and read by acquire;
   - **starts scheduled to a mixer frame**, landing on that sample, with a count of starts that
     arrived late;
   - **start reports**, on the existing return ring, which becomes an events ring of twice the
     voice count;
   - **two gains per voice**, `level × envelope`, each ramped per frame with a linear or an
     equal-power (`√t`) curve.

   `setGain` keeps its current meaning.
5. **Sequencing is `audio.Music`**, a game-thread type beside the mixer.
   - It turns `foundry:music_playlist` and `foundry:music_stinger` records into frame-exact
     scheduled starts and fades: tracks crossfaded, playlists switched on a bar line, and
     stingers placed on a beat or a bar with the music ducked.
   - It uses only the mixer's public game-thread API, so a game or a mod could do what it
     does.
   - The game decides which playlist plays when; `Music` decides exactly when that lands.
6. **The clock is presentation.** No tick reads it, and `scene` still cannot see `audio`
   (I7, I9). `Music`'s shuffle takes an explicit seed.

## Consequences

- **Music costs about an eleventh of its WAV size** in memory, plus a fixed 384 KB ring per
  stream at 48 kHz stereo.
- **Crossfades and stingers are sample-exact** and testable on the stepped null device. A
  sequenced mix is pinned by hash with immediate tasks.
- **The callback still cannot fail.** Everything that can fail (stream claims, allocation,
  record lookup) happens on the game thread at `play`, as before.
- **Cost: a second producer of mixer work, on the pool.** The pool is shared with asset loads,
  and the half-second margin is all that stands between a pool backlog and an underrun. M30
  measures it against M27's gallery load as the worst neighbour.
- **Cost: `Mixer.update` must keep being called.** If it stops, streams run dry within half a
  second. The existing rule, once per frame, already said so for retirements.
- **Cost: the one-second lookahead** delays a stinger by up to a beat plus a second. M30
  measures command delivery and lowers it if that is safe.
- **`audio.md` §12's "game policy, not engine mechanism" is corrected.** Policy stays with the
  game, and the frame arithmetic moves beside the clock that makes it exact.

## Alternatives considered

- **Decode on the device thread**, inside the callback. It needs no ring and no task. Rejected:
  a Vorbis packet's decode time varies with its block size and codebooks, which is exactly the
  unbounded work the callback rule forbids. A slow packet becomes a click for every voice, not
  only the stream's.
- **Decode on the game thread**, in `Mixer.update`. It is simpler, and deterministic without a
  pool. Rejected because the music then stops whenever the frame stalls. A synchronous load or
  a long frame would starve every stream, and M27 built the pool so that frames do not carry
  background work.
- **Decode to PCM at load and keep it resident** (the "streamed" track fully decoded). It needs
  no streaming at all. Rejected: a three-minute track is about 60 MB as `f32`, twice ADR-0023's
  WAV problem.
- **Read compressed bytes from disk as the track plays.** This is the least memory. Rejected
  for M30 because packages are read whole through the registry today, and incremental reads
  are M60's streaming work. Compressed music is small enough to stay resident until then.
- **Pause an underrunning voice until data arrives.** It keeps every frame of the track.
  Rejected because the track then stays behind its own schedule, and every later crossfade
  and stinger lands off the music.
- **Leave sequencing to games** (`audio.md` §12's original position). Rejected: without a
  clock, scheduled starts and ramps, a game cannot do it exactly. With them, every game would
  write the same arithmetic. The mechanisms are engine work, and the playlist choice stays the
  game's.
- **Put sequencing in `scene`, as components and systems.** Rejected: `scene` cannot see
  `audio` (I7), and music is presentation that a tick must never read (I9).

## Revisit if

- **Underruns appear under a real game's load** with the pool's default size. A dedicated
  audio-decode lane, or task priorities (M99), is then the answer.
- **A game needs more than one tempo within a playlist**, or tempo changes inside a track. The
  grid then belongs to the track, which `foundry:sound` should not carry, so a music-track
  record would be the decision.
- **M31's buses arrive.** `Music` setting `level` on each of its voices should become one music
  bus's gain.
- **A game needs streams beyond resident compressed bytes**, such as hours of dialogue. That is
  M60's disk streaming.
