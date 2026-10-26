# Design: M30 — Audio II: compressed audio, streamed music and music sequencing

**Status:** Accepted 2026-10-26, when the owner asked for Step 1, with §14 as written. Step 1 of nine is done; its Resolution follows §15.
**Date:** 2026-10-26
**Baseline:** `e4ea4b5`, tag `m29`. M0–M29 are complete.
**Decisions:**
- These ADRs constrain it:
  - ADR-0023: Foundry mixes its own audio and decodes its own WAV; `f32` interleaved end to
    end; resampling in the voice; one lock-free command ring; and its first revisit trigger,
    "music size becomes a real problem", which the roadmap's M30 line now fires.
  - ADR-0018: Foundry decodes its own image format, because mod-supplied files travel that
    path. An audio file arrives through the same door.
  - ADR-0061 and ADR-0062: the background pool beside the frame, and loaders split into a pure
    `decode` and a main-thread `finish`.
  - ADR-0041 and ADR-0064: engine record types live in `asset`, so `fpack` checks them without
    linking their consumer.
  - ADR-0013: deterministic-friendly, not bit-exact.
- It proposes two ADRs:
  - [ADR-0065](../adr/0065-foundry-decodes-its-own-ogg-vorbis.md): Foundry decodes its own Ogg
    Vorbis, in Zig, in `asset`, beside WAV. Its subset is stated and everything else is refused
    by name. Its tests compare against the reference decoder's output on fixtures that the
    reference encoder wrote once.
  - [ADR-0066](../adr/0066-streamed-voices-and-music-on-a-sample-clock.md): a streamed sound
    stays compressed in memory and is decoded while it plays, on the background pool, into a
    ring per stream. The mixer gains a sample clock, starts scheduled to a frame, and gain
    ramps. Music sequencing (playlists, crossfades and stingers) is `audio.Music`, a
    game-thread sequencer over those mechanisms, driven by `foundry:music_playlist` and
    `foundry:music_stinger` records.

## 1. Purpose and boundary

The roadmap's row (`docs/ROADMAP.md`, Phase 6) is the contract:

> M30 | Audio II | Compressed audio and streamed music; the decoder is an ADR; also music
> sequencing: playlists, crossfades and stingers

Two other documents allocate work to M30 by name:
- `background.md` §1: "Streamed music and compressed audio decoded while playing: M30." §6
  answers it with the background pool M27 built.
- `audio.md` §11 and §12 name compressed formats (question 3: "due with music") and music
  sequencing. That document called sequencing "game policy built on `play` and `setGain`, not
  engine mechanism". §8 corrects it: a crossfade that lands on a frame, and a stinger that
  lands on a beat, need a sample clock and a scheduled start, and only the mixer can supply
  them. What remains policy (which playlist, when) stays with the game.

**The runnable result** is `samples/court` with a soundtrack. The court is the engine's
playable 3D consumer, and it already plays an ambience loop and event sounds (`playable3d.md`
§6.2). After M30:
- a title track plays on the title screen and crossfades into the game's calm playlist when
  play begins;
- the calm playlist's tracks follow one another with crossfades;
- when the warden comes within hearing distance, the music crossfades into a chase track at
  the next bar, and back again once the warden is out of range;
- lighting a beacon plays a stinger on the next beat, and opening the gate plays one on the
  next bar, each with the music ducked beneath it;
- the music ducks while the game is paused; winning, being caught or falling fades it out
  under an ending stinger;
- every track is Ogg Vorbis, streamed, and the stingers are Ogg Vorbis decoded whole at load;
- a content-only mod, `nocturne`, replaces the calm playlist and one stinger without code.

**Exit criteria** (§12 gives each one's measure):
1. **Decoding.** Every reference fixture decodes within §12's tolerance of the reference
   decoder. Every refusal in §3.4 is reported by name. A mutation sweep over the fixtures
   neither crashes nor hangs. The decoder runs at least 50 times faster than real time on the
   Arc PC's i3, ReleaseSafe, single-threaded.
2. **Streaming.** Ten scripted minutes of the court, from a relocated ReleaseSafe install,
   report zero underruns, zero late starts and zero dropped commands. This holds on the M5
   with Metal and on the Arc PC with Vulkan.
3. **Schedule.** Over the same run, every crossfade and stinger starts on the exact frame
   `audio.Music` computed for it. The mixer reports each start's actual frame, and the log
   compares the two.
4. **Cost.** Main-thread audio work, meaning `Mixer.update` plus `Music.update`, is at most
   0.10 ms at p95. The court's streamed music is resident in at most an eighth of the bytes
   its 16-bit WAV equivalent would take.
5. **Determinism.** On the stepped null device with immediate tasks, a sequenced mix of a
   crossfade, a playlist switch and a stinger gives the same samples every run, pinned by
   hash.
6. **Moddability.** `nocturne` changes the calm music and the beacon's stinger with no code.
7. **Nothing else changes.** The court's scripted endings (won, caught, fell) give the same
   outcomes. The 2D `sandbox` and `room` sound as they did, and the headless runs pass.

**In M30:**
- an Ogg container reader and a Vorbis I decoder in `asset` (§3);
- `foundry:sound` version 2, with `.ogg` derived and a `stream` field (§4);
- the mixer's sample clock, scheduled starts, gain ramps and start reports (§5);
- streamed voices decoded on the background pool (§6);
- music records in `asset` and `audio.Music` (§7, §8);
- the court's soundtrack and the `nocturne` mod (§9).

**Not in M30**, each with its owner (§13 has them all): 3D spatialisation, mixer buses,
effects, a limiter and a compressor are M31's. Opus and other codecs are not planned (ADR-0065
says when they would be). Streaming from disk rather than from resident compressed bytes is
M60's. The public table's music calls are M48's.

## 2. What exists

- **The device** (`engine/src/platform/audio.zig`): `openAudio`, `closeAudio`, `audioInfo` and
  `setAudioPaused` on the backend interface. The null backend's device is stepped
  (`stepAudio`), so a test pulls a known number of frames. SDL3's backend adopts the
  hardware's sample rate and always hands the callback the block size it promised (`audio.md`,
  Step 2's Resolution).
- **The mixer** (`engine/src/audio/mixer.zig`, `voice.zig` and `ring.zig`):
  - `MixerOf(P)` owns a fixed voice table (32 by default) and a command ring to the callback
    (256 by default).
  - A retirement ring comes back, sized to the voice count so that a retirement can never be
    dropped.
  - Sounds live in a `HandlePool` with reference counts and a retirement flag. A hot reload
    therefore retires a sound while a voice still reads it.
  - `play(ContentId, PlayParams)` takes gain, pan, pitch and looping. `setGain`, `setPan`,
    `setPitch` and `setMasterGain` all apply at the next callback, with no ramp.
  - `update()` drains retirements once per frame.
  - Voices mix in slot order. The output is clamped, not limited.
- **Sounds as content** (`engine/src/asset/sound.zig`, `wav.zig` and `schemas.zig`):
  - `foundry:sound` is version 1, with `source` only, and `.wav` derives it.
  - `Sound` is `f32` interleaved, one or two channels, every sample finite.
  - The WAV decoder refuses everything outside its table by name, and checks the frame limit
    before allocating.
  - `soundLoader` is split (M27): `soundDecode` runs on the pool and `soundFinish` inserts the
    sound into the mixer's pool.
- **The background pool** (`engine/src/core/tasks.zig`, ADR-0061): `core.Tasks`, with
  `start(task, *Done)`. `immediate` runs each task inside `start` and is the reference every
  background result is compared against. `Manual` holds tasks until a test runs them, in any
  order.
- **Trig written out** (`engine/src/particles/trig.zig`, M29): `sinCosTurns` uses only `+`, `−`,
  `×` and `floor` in `f64`, so a pin does not depend on which `sinf` a binary linked.
- **The public table** (`engine/src/abi/calls_audio.zig`): `audio_play`, `audio_stop`,
  `audio_set_gain`, `audio_set_pan`, `audio_set_pitch` and `audio_set_master_gain`, by content
  ID and voice handle. 264 calls in all.
- **The court** (`samples/court/sounds.zig` and `court.fdt`): a `sound_set` record names an
  ambience loop, footsteps, the warden's steps, the gate, the beacons and the three endings,
  each a `.wav` that `scripts/m26/make_court.py` generated. Sound is driven by the events a
  tick emitted, and no tick reads anything back (I9). `FOUNDRY_COURT_PACKAGES` selects mods,
  and `testdata/mods/noon` is the court's existing content mod.
- **No encoder** is on the Mac. `afconvert` writes Opus and FLAC in CAF, but not Vorbis.
  Neither `ffmpeg` nor `oggenc` is installed, and nothing may assume Homebrew. §3.5 answers
  where fixtures come from.

## 3. The decoder (`asset`, ADR-0065)

### 3.1 Why Vorbis, and why our own

ADR-0065 sets out the alternatives. Briefly:
- **Vorbis** is what authoring tools export (Audacity, Reaper, every DAW's "Ogg" option), and
  it is free of patents and royalties. It is about eleven times smaller than 16-bit WAV at
  quality 4.
- **A Vorbis I decoder is a bounded piece of work**, roughly 2,500–3,500 lines of Zig: Ogg
  pages, three headers, codebooks, floor type 1, three residue types, channel coupling, an
  inverse MDCT and overlap-add.
- **Opus** is the better codec, but its decoder is SILK, CELT and a hybrid of both, several
  times the size. A C library would put untrusted mod files through C.
- **`stb_vorbis`** has a long record of memory-safety bugs found by fuzzing (2019 and 2021).
  That is exactly ADR-0018's argument for keeping untrusted decoding in Zig, where a bad index
  is a checked panic in the ReleaseSafe builds Foundry ships, not an exploit.

### 3.2 The container: `asset/ogg.zig`

Ogg is pages, and each page carries packet segments.
- **What it does:** it walks pages, checks each page's CRC-32 (polynomial `0x04c11db7`, as
  RFC 3533 gives it), reassembles packets across pages, and reports each page's granule
  position.
- **One logical stream only.** A second serial number refuses the file, whether multiplexed
  or chained: `UnsupportedSound` "chained or multiplexed Ogg". A game's track is one stream,
  and a chained file is a broken export far more often than it is a playlist.
- **A page with a bad CRC refuses the file.** It is not skipped. A file in a package is not a
  radio broadcast, so a damaged page means the file is wrong.
- **The total length** comes from the last page's granule position. It is read before
  anything is allocated, so a header that claims hours costs nothing (`audio.md` §6's rule
  for WAV).

### 3.3 The codec: `asset/vorbis.zig`

It follows the Vorbis I specification (Xiph.Org, 2020 revision), section by section:
- **The identification header:** version 0, one or two channels, a rate from 1 to 192,000 Hz,
  and the two block sizes, each a power of two from 64 to 8192 with short ≤ long.
- **The comment header:** checked for framing, then skipped. Tags are not read; nothing asks
  for them.
- **The setup header:**
  - codebooks, whose Huffman trees are built and validated as complete or single-entry, with
    lookup types 0, 1 and 2;
  - floor type 1, and residue types 0, 1 and 2;
  - mappings, with coupling steps and submaps;
  - modes.

  Every index is checked against the count it indexes. The time-domain placeholders must be
  zero.
- **An audio packet:** mode, window shape, floor curve, residue, inverse coupling, the inverse
  MDCT, windowing and overlap-add with the previous block. The first packet produces no
  output, and the last page's granule trims the final block. A file therefore decodes to
  exactly the frame count its granule claims, which a loop seam needs (§6.4).
- **The output** is `f32` interleaved: `Sound` for a whole decode, or frames into a caller's
  buffer for a stream (§6).

**Its trig is written out.** The window `sin(π/2 · sin²(…))` and the MDCT's twiddles are
computed once per block size, at setup, with the arithmetic-only `sinCosTurns`. Step 1 moves it
from `particles` to `core` as `core.math.trig`, and `particles` imports it from there with every
pin unchanged. A decoded file is then the same bytes in every optimization mode of one binary,
for the reason particles needed it (`public3d.md` §10's two math providers).

**Speed.** The inverse MDCT is the usual N/4-point complex FFT form, never the direct O(N²)
sum. Codebooks decode through a lookup table for short codes, falling back to the tree.
Floor 1's curve uses the specification's inverse-dB table, written out as its 256 constants.

### 3.4 The subset, and the refusals

Each refusal is untrusted input reported by name, never an assertion:
- not Ogg, a bad page CRC, or a truncated page;
- a second logical stream;
- a codec other than Vorbis. It is named where it is recognisable: Opus (`OpusHead`), FLAC
  (`\x7fFLAC`), Speex and Theora;
- Vorbis version not 0; zero channels or more than two (the mixer's rule); a rate of zero or
  above 192 kHz; a block size outside 64–8192;
- **floor type 0**: `UnsupportedSound` "Vorbis floor 0". libvorbis has not written it since
  before 1.0, and the specification calls it rare. A file using it is refused with a
  sentence, as compressed WAV is;
- a codebook, floor, residue, mapping or mode index past its count; an incomplete Huffman
  tree; a lookup type above 2; a codebook whose values are not finite;
- a frame count above `Limits.max_frames`, checked before allocating;
- **a non-finite decoded sample**, which refuses the file, as WAV does (`audio.md` §6). A
  crafted codebook can produce one, and the whole-file decode at load is where it is found
  (§4).

The decoder's errors are `SoundDecodeError`'s existing members. A valid file outside the
subset is `UnsupportedSound`, which the loader maps to `UnsupportedVersion`, as WAV's is.

### 3.5 Fixtures from the reference

A Vorbis decoder is correct when it agrees with libvorbis, the reference implementation. Its
tests therefore need files libvorbis wrote, and the samples libvorbis decodes from them.
1. **The tool.** `scripts/m30/reference/` holds one small C program, about 150 lines. It
   encodes a WAV at a given quality with `libvorbisenc`, and decodes an Ogg to a 16-bit WAV
   with `libvorbisfile`.
2. **Building it.** `scripts/m30/make_fixtures.py` builds the program with `zig cc`, in the
   scratch directory, from the release tarballs of libogg 1.3.5 and libvorbis 1.3.7 (both
   BSD-3-Clause). Both tarballs are checked against SHA-256 values recorded in `AGENTS.md`,
   beside the Vulkan SDK's.
3. **What it makes.** The script synthesises the source WAVs deterministically, encodes them
   and decodes the results. It writes the fixtures and their reference decodes into
   `engine/src/asset/testdata/vorbis/`.
4. **Nothing of libvorbis ships or links.** The build never runs the script. The committed
   fixtures are the encoder's output, not its code, so no `THIRD_PARTY_LICENSES/` entry is
   owed. ADR-0065 records this as it records the tool, and RenderDoc is the precedent.

The fixtures, each at most a few seconds long:
- mono 44.1 kHz at quality 0 and quality 10, the two extremes of block and codebook
  configuration;
- stereo 48 kHz at quality 4;
- stereo 22.05 kHz at quality −1;
- a file shorter than one long block;
- a three-second mono file spanning many pages;
- a stereo file whose channels differ, which proves coupling.

The refusal corpus is made in the test itself, as WAV's and PNG's are: a chained file built by
concatenating two fixtures, a hand-built `OpusHead` page, a flipped CRC byte, and every header
field set out of range.

The court's music (§9) is encoded by the same tool, so the samples Foundry ships come from the
reference encoder too.

## 4. `foundry:sound` version 2

```
@schema foundry:sound {
    source string
    stream bool (default false)
}
```

- **`.ogg` joins `.wav`** in the extension table, so an `.ogg` in a package derives a
  `foundry:sound` with no authoring, as a `.wav` does. The loader chooses the decoder by the
  file's magic bytes, `RIFF` or `OggS`, never by extension, because a path never defines
  identity (ADR-0021).
- **`stream` is added with a default** (I8). Packages compiled at version 1 keep loading, and
  each of their sounds is resident as before.
- **`stream false`** decodes the whole file in the loader's `decode` phase, on the pool, into
  the same `Sound` that WAV produces. A stinger and a footstep take this path. They are small,
  and a voice that reads resident samples cannot underrun.
- **`stream true`** keeps the compressed bytes. The `decode` phase still decodes the whole file
  once and discards the samples. This proving pass is what lets §6's stream decode treat a
  failure as impossible: the same bytes through the same decoder give the same result, so a
  file that decoded at load decodes again while it plays. It costs one decode per load, on
  the pool, which is under 0.1 s for a minute of music at criterion 1's speed. In exchange, a
  corrupt or non-finite track is refused by name at load, never heard as silence halfway
  through.
- **`stream true` on a WAV is refused**, `UnsupportedVersion` "stream is for compressed
  sounds". Streaming PCM that is already resident would buy nothing and cost a ring.

**Why a field and not a length threshold.** Whether a sound streams is a choice about memory
against latency, and the author is the one who knows which this sound needs. A threshold
would make one extra second of a stinger change how it plays.

## 5. The mixer's new mechanisms (`audio`, ADR-0066)

All are on the game thread's side of the ring. The callback still cannot fail, allocate, lock
or log (`audio.md` §3).

### 5.1 The sample clock

The callback counts the frames it has mixed since the mixer started, as a `u64`. After each
buffer it publishes the count with a release store, and `Mixer.clock()` reads it with an
acquire load.
- **The clock is presentation, never simulation.** It advances with a thread Foundry does not
  control, so I9 keeps it out of every tick. That is the same rule as `isPlaying`
  (`audio.md` §8), and the structure enforces it as before: `scene` cannot see `audio`.
- **It is the music's only clock.** `Music` never reads wall time. It schedules in mixer frames
  and asks the clock where now is.

### 5.2 Scheduled starts, and start reports

- **`PlayParams.start_at: ?u64`** names a mixer frame. The callback holds a voice whose frame
  has not come, and starts it at that exact frame within the buffer that contains it. Its
  first sample lands on that frame, not at the buffer's start. `null` keeps today's meaning:
  start at the next callback.
- **A start frame that has already passed** when the command arrives starts the voice at once,
  and the mixer counts it in `lateStarts()`. Criterion 2 requires the counter to stay at zero.
  `Music`'s lookahead (§8.4) is what keeps it there.
- **The callback reports each voice's actual start frame** back to the game thread. It uses
  the ring that carries retirements today, which becomes an events ring of
  `{ started | retired }` sized to twice the voice count. Each voice starts at most once and
  retires at most once before its slot is reused, so a dropped event remains structurally
  impossible, as the retirement ring's sizing argued (`audio.md`, Steps 3–4's Resolution).
  `Mixer.startedAt(voice)` answers from what `update` drained. Criterion 3 compares it with the
  frame `Music` asked for.

### 5.3 Two gains per voice, each ramped

A crossfade and a duck can overlap on one voice, so one gain cannot carry both. A voice's
output gain becomes `level × envelope`:
- **`envelope`** is the voice's shape over time: fade in, fade out and crossfade.
  `fade(voice, .{ at, frames, to, curve, stop })` ramps it from wherever it is to `to` over
  `frames`, starting at mixer frame `at` (or the next callback when `at` is null). When `stop`
  is set, the voice retires at the ramp's end. `PlayParams.envelope` (default 1) is its value
  when the voice starts.
- **`level`** is how loud the voice is meant to be: the playlist's gain, the music's gain and
  the duck. `fadeGain(voice, gain, frames)` ramps it. `setGain` keeps its present meaning,
  applied at the next callback with no ramp, so every existing caller and the public table
  behave as before.
- **Curves.** `linear` ramps amplitude linearly. `equal_power` ramps along `√t` going up and
  `√(1 − t)` going down. Across a crossfade of two uncorrelated tracks, the summed power then
  stays constant and the middle does not dip by 3 dB. `√` is exactly rounded by IEEE 754, so
  the curve costs one square root per frame per fading voice, and nothing in it depends on a
  linked math library.
- **The ramp advances per frame**, inside the callback's existing loop, as an increment kept in
  the voice. It is arithmetic only, which the callback rule allows.

### 5.4 What the game-thread API gains

```zig
PlayParams.start_at: ?u64 = null
PlayParams.envelope: f32 = 1.0
fade(voice, Fade) void                 // and fadeChecked, as the setters have
fadeGain(voice, gain: f32, frames: u32) void
clock() u64
startedAt(voice) ?u64
lateStarts() u32
underruns() u32                        // §6
```

All of them are presentation-side and none is visible to a tick.

## 6. Streamed voices (`audio`, ADR-0066)

### 6.1 The shape

```
 game thread                    background pool             device thread
 ───────────                    ───────────────             ─────────────
 play(streamed sound)
   claims a Stream ──────────►  decode task: fill  ───────►  voice reads frames
   from a fixed table           the stream's ring            from the ring
 update(): below half full?     (one producer at a           (one consumer)
   start another decode task    time; the Stream's
                                Done says when)
```

- **The `Stream` table is fixed-size**, `Options.streams`, 4 by default. Each stream owns a
  ring of `f32` frames holding one second at the sound's own rate, plus a Vorbis decoder
  state. The table is allocated at `init`, with each ring at the largest size its limits
  allow. `play` allocates only the decoder's per-stream state, on the game thread, where
  `play` is already allowed to fail. Past the table, `play` returns `error.NoFreeStream`.
- **The decoder state is per stream, and its setup is per sound.** The codebooks and modes
  were parsed once at load and are shared read-only by every stream of that sound. The
  overlap buffers and the page cursor belong to the stream.
- **The voice is an ordinary voice whose source is a ring.** Gain, pan, pitch, resampling, the
  ramps and scheduled starts all work unchanged. The voice reads source frames from the ring
  exactly as it reads them from a resident slice, interpolating between neighbours. The ring
  therefore keeps one frame of history behind its read cursor.

### 6.2 Who decodes, and when

- `play` claims a stream and starts its first decode task at once, so the ring fills before a
  scheduled start arrives (§8.4's lookahead is one second).
- **`update()`** starts another decode task for every stream whose ring is below half full
  and has no task in flight. Each task decodes until the ring is full, or the sound ends and
  does not loop, then sets its `Done`.
- **One producer at a time.** A stream never has two tasks in flight. The `Done` flag is the
  rule, and it keeps the ring single-producer and single-consumer, as `ring.zig`'s contract
  needs, even though successive producers may run on different pool threads. The handoff
  between them goes through the `Done` flag's release and acquire.
- **The margin is half a second.** A game frame or a pool backlog shorter than that is absorbed
  without a gap. A longer stall underruns, and §6.3 says what is heard. M27's pool is shared
  with asset loads. Step 5 measures the margin against the gallery's load as the worst
  neighbour, and Step 7 against the court's own load.

### 6.3 An underrun keeps the timeline

When the ring is empty, the voice writes silence, counts `underruns()` and **still advances its
position**. The frames it missed are discarded when they arrive. A late track is therefore cut,
not delayed, and every later crossfade and stinger, scheduled in mixer frames from the track's
start, still lines up with the music. The other answer, pausing the voice until frames arrive,
would leave the track permanently behind its own schedule after any hitch. Criterion 2
requires the counter to stay at zero, so either answer is a failure. This one keeps a failure
local.

### 6.4 Loops and ends

- A looping stream's decoder starts again at the first audio packet when it reaches the last
  granule. The last block is trimmed to the granule, and the first block of the new pass
  overlaps from silence, as the file's own start does. The seam is therefore exactly the file's
  length, with no gap and no extra frame, and a test checks it frame by frame against a
  resident decode of the same file played as a loop.
- A one-shot stream ends when its last frame has been read, and retires through the events
  ring like any voice.

### 6.5 Lifetime

`audio.md` §7's two hazards hold unchanged, with one addition.
- **The compressed bytes** are the `Stored` sound's, reference-counted by the voices reading
  them, and retired rather than freed by a hot reload. That is the same mechanism as resident
  samples.
- **New: a stream's state is freed only when both sides are done**: the voice has retired, and
  the stream's `Done` shows no decode task in flight. `update` frees it once both are true. A
  task still decoding into a ring whose voice was stopped finishes into a ring nobody reads,
  and that is harmless. Freeing the ring under it would not be.
- **`shutdown`** closes the device, waits for every stream's task, then hands references back,
  in that order (`audio.md`, Steps 5–6's Resolution).

### 6.6 Determinism

With the stepped device and `core.Tasks.immediate`, a decode task runs inside `start`. A
streamed voice's output then depends only on the commands and the buffer sizes, and is pinned by
hash (criterion 5). `core.Tasks.Manual` gives the adversarial case: tasks held back
deliberately, to prove that an underrun writes silence, counts, keeps the timeline, and that
the voice is whole again once frames arrive.

## 7. Music as content (`asset/music.zig`)

Two engine record types, decoded and validated in `asset` like `foundry:particle_emitter`, so
`fpack` and `fdt-check` check them without linking a mixer (ADR-0041, ADR-0064):

```
@schema foundry:music_playlist {
    tracks [id]                          # foundry:sound records; one or more
    order string (default "sequential")  # sequential | shuffle
    loop bool (default true)             # after the last track, start again
    crossfade f32 (default 2.0)          # seconds: between tracks, and entering this playlist
    gain f32 (default 1.0)
    tempo f32 (default 0)                # beats per minute; 0 means no grid
    beats_per_bar u32 (default 4)
    first_beat f32 (default 0)           # seconds into each track where beat one falls
}

@schema foundry:music_stinger {
    sound id                             # a foundry:sound, usually not streamed
    quantize string (default "beat")     # now | beat | bar
    gain f32 (default 1.0)
    duck f32 (default 0.5)               # the music's level beneath it; 1 is no duck
    duck_fade f32 (default 0.1)          # seconds, into the duck and back out
}
```

- **One tempo per playlist.** A playlist's tracks share its grid. This covers a soundtrack
  written as a set, which is the common case and the court's. A per-track tempo would make the
  track record carry music theory, and a `foundry:sound` is not a musical object. A soundtrack
  whose tracks differ in tempo uses one playlist per tempo.
- **Validation, refused by name:**
  - an empty `tracks`, or more than 64;
  - a track that is not a `foundry:sound`, checked at decode where the ID resolves;
  - an unknown `order` or `quantize`;
  - a `crossfade` below 0 or above 30 s;
  - a gain outside 0–4, or a `duck` outside 0–1;
  - a `tempo` below 0 or above 400;
  - a `beats_per_bar` of 0 or above 32;
  - a `first_beat` below 0;
  - a non-finite number anywhere.
- **A mod overrides either record whole**, by I3's ordinary merge. `nocturne` does exactly that
  (§9).

## 8. `audio.Music`

### 8.1 Where it lives, and why

`Music` is a game-thread type in `audio`, beside the mixer it drives.
- **It is not engine policy.** Which playlist plays when is the game's choice: the court picks
  "chase" when the warden is near, and `Music` never knows why.
- **It is mechanism with musical meaning.** It turns "this playlist next" into frame-exact
  scheduled starts and fades, and "this stinger" into a start on the next beat with a duck
  around it. A game written without it would rebuild the same arithmetic on the same clock.
  That is why it belongs beside the clock, and it is §1's correction to `audio.md` §12.
- **It sees only the mixer's public game-thread API**: `play` with `start_at`, `fade`,
  `fadeGain`, `clock` and `startedAt`. Anything it does, a game could have done. Through
  M48's table, so could a mod, and that is the test that it is not privileged.

```zig
pub fn MusicOf(comptime M: type) type   // M: a MixerOf(P); tests use the null platform's
pub const Music = MusicOf(Mixer);

init(gpa, mixer: *Mixer, registry: *asset.Registry, options: Options) !Music
deinit(self) void
play(self, playlist: ContentId) PlayError!void      // switch, with the playlist's crossfade
stop(self, fade_seconds: f32) void
stinger(self, stinger: ContentId) PlayError!void
setGain(self, gain: f32, fade_seconds: f32) void    // the court's pause duck
update(self) void                                   // once per frame, after Mixer.update
contentChanged(self) void                           // a reload: re-read records at the next boundary
```

`Options.seed: u64` seeds shuffle. It is an explicit generator from `core.rng`, never the clock
(§7 of CLAUDE.md).

### 8.2 Tracks and crossfades

`Music` knows each track's frame count from its `Sound`, and the frame it asked the track to
start at. Everything else is arithmetic on those two numbers:
- the next track starts at `start + frames − crossfade` (in the device's frames, through the
  track's resampling ratio), with `envelope` 0 and an `equal_power` fade up over the crossfade;
- the current track gets an `equal_power` fade down over the same frames, with `stop` set;
- a track shorter than twice the crossfade is played without one, and Step 6 records the
  answer it chose for the edge;
- after the last track, `loop` starts again at the first, and `false` lets the music end.

**Shuffle** draws a permutation per cycle, by Fisher–Yates from the seeded generator, and swaps
the first entry if it would repeat the last track of the previous cycle. The same seed gives
the same order.

### 8.3 Switching playlists

`play(other)` crossfades from the current track into `other`'s first track (by its order),
using `other`'s crossfade. When the current playlist has a tempo, the switch lands on its next
bar line (`first_beat + n · beats_per_bar · 60 / tempo` seconds into the track), so the change
falls on the music's own phrase. Without a tempo it lands one lookahead after the call. A switch
to the playlist already playing does nothing.

### 8.4 Stingers

`stinger(id)` plays the stinger's sound at the next `quantize` point of the current track's
grid: the next beat, the next bar, or `now`. `now` means one lookahead from the clock. The
music's `level` ramps down to `duck` over `duck_fade`, ending at the stinger's start, and back
up over `duck_fade` once it ends. A stinger with no music playing, or with a playlist of tempo
0, plays one lookahead from now.

**The lookahead is one second**, `Options.lookahead_frames`. A start scheduled closer to the
clock than one device buffer plus the ring's delivery time could arrive late. One second also
covers a streamed track's first fill. A beat less than a second away is therefore skipped in
favour of the one after. That is a known cost: at 96 bpm a stinger may wait up to about 1.6 s.
Step 6 measures the actual command-delivery latency, and lowers the lookahead to the measured
bound with a margin if the measurement allows.

### 8.5 Reload

A reload that changes a playlist or a stinger record takes effect at the next track boundary,
or the next `stinger` call. A playing track is never cut by a record edit. A reload that
replaces a track's sound behaves as `audio.md` §7 already says: the playing voice keeps the old
bytes until it ends.

## 9. The court's soundtrack

- **Music.** `scripts/m30/make_court_music.py` synthesises the court's music deterministically
  in Python: chords, a bass line and soft percussion at 96 bpm in 4/4. It then encodes it with
  §3.5's reference tool at quality 4 into `samples/court/content/music/`:
  - `title.ogg`, about 24 s, looping;
  - `calm_a.ogg` and `calm_b.ogg`, about 48 s each;
  - `chase.ogg`, about 32 s, looping;
  - three stingers: `beacon` (beat), `gate` (bar), and `ending` (bar).

  The repository grows by about 3 MB, against about 27 MB as 16-bit WAV.
- **Records** in `court.fdt`:
  - `court:music.title`, `court:music.calm` and `court:music.chase` playlists, the calm one
    shuffled;
  - three stingers;
  - `stream true` on the four tracks.
- **`samples/court/music.zig`**, beside `sounds.zig`, maps the game's state to calls, from what
  the tick already exposes:
  - `title` plays the title playlist;
  - `playing` plays calm, or chase while the warden is within the `sound_set`'s
    `hearing_distance`, with a two-second hold before returning, so a warden pacing at the edge
    does not flip the music on every step;
  - `paused` calls `setGain(0.3, 0.25)`;
  - the endings call `stop(1.0)` and the `ending` stinger;
  - the beacon and gate events play their stingers.

  Like `sounds.zig`, it reads the game and the game never reads it (I9).
- **The ambience loop stays**, beneath the music, at its own gain. It is sound design, not
  music.
- **`nocturne`** (`samples/court/testdata/mods/nocturne`) is a content-only package. It
  overrides `court:music.calm` with its own two tracks at a different tempo, and replaces the
  beacon stinger's sound. No code.
- **The headless court** starts the title playlist, which decodes its first stream through the
  real path, as the sandbox's headless ambience does (`audio.md`, Steps 5–6's Resolution), and
  issues nothing else, because its device never runs.
- **The evidence.** `FOUNDRY_COURT_MUSIC_LOG=on` writes each scheduled start with its asked and
  actual frame, plus the counters every ten seconds and at exit. Criteria 2 and 3 read that
  log.

## 10. The public ABI: nothing in M30

The call count stays 264. A mod reaches M30 three ways before M48:
- **content:** its own `.ogg` sounds, streamed or not, and playlist and stinger records that
  override the game's, as `nocturne` does;
- **`audio_play` unchanged:** a native or Lua mod plays a streamed sound through v1's call,
  because streaming is a property of the record;
- **nothing else.** Scheduled starts, fades, the clock and `Music` reach the table in M48's
  `FoundryApi_v8`. Its line already covers "what M27–M47 built", and the close adds an "also"
  clause naming music so the item cannot be lost.

## 11. Platform assessment

- **macOS (Metal):** CoreAudio through SDL3, unchanged. The decoder and streaming are pure Zig
  plus `core.Tasks`. Steps 1–7 run here.
- **Windows (Vulkan):** WASAPI through SDL3. The pool's threads are Windows threads, and the
  i3-10105F is the slower CPU. Both affect criteria 1, 2 and 4, so Step 8 runs on the Arc PC.
  - The PC has had no Foundry clone since M29's close, so Step 8 clones into a worktree.
  - Its rules are the usual ones: check it is idle, `-j2`, below-normal priority, and remove
    only exact Foundry paths afterwards.
  - Its audio device plays through the scheduled-task desktop, as the court's sounds did in
    M26.
- **Linux:** nothing M30 changes is Linux-specific. SDL3's audio path and the pool are already
  proven there (M18, M26), so 3d.md §10.2 calls for no Linux run. The Linux null cross-check
  stays in the bar.
- **Graphics:** untouched. The Vulkan validation runs in Step 8 are the court's usual ones.

## 12. Verification, pins and budgets

- **`asset`, Ogg:** CRC against known vectors; packets spanning pages; a packet in exactly 255
  lacing segments; granules; every container refusal.
- **`asset`, Vorbis:**
  - every fixture against its reference decode: **maximum absolute difference ≤ 2⁻¹⁴**
    (about 6 × 10⁻⁵), which allows for the reference's 16-bit quantization (2⁻¹⁶) and float
    differences between two MDCTs;
  - an RMS difference recorded per fixture;
  - exact frame counts;
  - every §3.4 refusal;
  - each fixture's output pinned by hash.
- **The mutation sweep:**
  - every truncation of the short fixture;
  - 2,000 seeded single-bit flips across the stereo fixture, each with the page CRC recomputed
    so the flip reaches the decoder.

  Each case must decode or be refused, never panic. Debug and ReleaseSafe both catch an
  out-of-bounds index as a panic, so the test fails on one.
- **Decoder speed:** frames per second for the stereo quality-4 fixture, ReleaseSafe and
  single-threaded, printed by a timing test. It must be at least 50× real time on the Arc PC
  (criterion 1). The Mac's figure is recorded.
- **`audio`, stepped device:**
  - the clock advances by exactly each buffer;
  - a scheduled start lands on its frame mid-buffer, sample-exact;
  - a late start counts;
  - `startedAt` reports;
  - each ramp's curve at its start, middle and end;
  - `level × envelope` composes;
  - a `stop` fade retires;
  - `setGain` is unchanged.
- **Streams:**
  - with `immediate`, a streamed voice equals the same file's resident decode, sample for
    sample, looping included across three seams;
  - with `Manual`, an underrun is silent, counted and keeps the timeline;
  - a stop with a task in flight frees only after `Done`;
  - a hot reload while streaming;
  - `NoFreeStream`;
  - `testing.allocator` on every path, so an early free and a leak both fail.
- **`asset`, music records:** defaults, every refusal through `fpack`'s path and on hand-made
  records, and an override replacing a record whole.
- **`Music`, stepped device:**
  - crossfade frames from the arithmetic of §8.2;
  - shuffle's order for a seed, with no repeat across cycles;
  - a switch on the bar line;
  - stingers on the beat and the bar, with the duck's ramps;
  - `stop`;
  - reload at the boundary;
  - **the sequenced mix pinned by hash** (criterion 5).
- **The court:**
  - criteria 2, 3, 4 and 6 from a relocated ReleaseSafe install, three ten-minute scripted runs
    each, on the M5 and then the Arc PC;
  - the scripted endings unchanged;
  - `dist` staging, because the sample's content and asset kinds change.
- **The bar** (`AGENTS.md` §3) at every step. `fdt-check` covers the two new record kinds and
  `foundry:sound` version 2.

**Pins across machines.** The decoder's and the sequenced mix's hashes are pinned on the Mac
and checked on the PC. A difference across machines is recorded, not forced (ADR-0013). It
fails an exit only if one machine disagrees with itself.

**Listening.** None of the criteria needs a human ear. The schedule, counters and pins prove
the mechanism. Step 7 still offers the owner a listening check of the court on the Mac, as M24
offered the walker. It is not an exit criterion.

## 13. What stays open, deliberately

Each item names the milestone that owns it (CLAUDE.md §2, rule 17).

| Item | Owner | Note |
| --- | --- | --- |
| 3D spatialisation, mixer buses, effects, a limiter and a compressor | M31 | Already its line. A music bus replaces `Music` setting `level` on each of its voices |
| Loop points within a file (an intro before the loop), and starting a sound part-way (seek, and resuming a playlist where it was left) | M31 | Added to M31's intent at the close. Both need the decoder to seek by granule, and M31's buses and effects are the next change to the voice |
| Streaming from disk rather than from resident compressed bytes | M60 | Added to M60's intent ("assets loaded and unloaded around a point") at the close. Compressed music is small enough to stay resident until a world streams |
| Scheduled starts, fades, the clock and `Music` in the public table, and in Lua | M48, M49 | §10. M48's and M49's lines gain an "also" clause for music at the close |
| Voice stealing (`audio.md` §11, question 1) | M31 | Its buses give priorities something to attach to; added to its intent at the close |
| Device change and enumeration (`audio.md` §11, question 4) | M45 | Beside input's device handling; added to M45's intent at the close |
| A music or sound editor with preview | M110 | Beside live emitter editing; the M15 editor already edits the records |
| Opus, MP3, FLAC and other codecs | Not planned | ADR-0065's revisit says when a second codec would be decided |

## 14. Decisions acceptance fixes

| # | Choice | Where |
| --- | --- | --- |
| 1 | Foundry decodes its own Ogg Vorbis in Zig, in `asset`, beside WAV; no codec dependency; Opus is not planned | §3, ADR-0065 |
| 2 | The subset: one logical stream, one or two channels, up to 192 kHz, floor type 1 only; a bad CRC, a chained file, floor 0 and other codecs are refused by name | §3.4 |
| 3 | Fixtures and the court's music come from the reference libvorbis 1.3.7 and libogg 1.3.5, built by `zig cc` in scratch from hash-pinned tarballs by a developer script, never by the build. The tarballs' hashes go in `AGENTS.md`; no `THIRD_PARTY_LICENSES/` entry, because nothing ships or links | §3.5, ADR-0065 |
| 4 | `sinCosTurns` moves from `particles` to `core.math.trig` and the decoder uses it; particles' pins are unchanged | §3.3 |
| 5 | `foundry:sound` version 2 adds `stream` (default false); `.ogg` derives a sound; the decoder is chosen by magic bytes; `stream` on a WAV is refused | §4 |
| 6 | A streamed sound stays compressed in memory, is proved by one whole decode at load, and is decoded while playing into a one-second ring per stream on the background pool; four streams by default | §4, §6, ADR-0066 |
| 7 | An underrun writes silence, counts and keeps the timeline | §6.3 |
| 8 | The mixer gains a published sample clock, frame-exact scheduled starts with a late-start counter, start reports on an events ring, and two ramped gains per voice (`level × envelope`) with linear and equal-power curves; `setGain` keeps its meaning | §5 |
| 9 | Music sequencing is `audio.Music`, a game-thread sequencer over the mixer's public game-thread API, correcting `audio.md` §12's "game policy, not engine mechanism" | §1, §8 |
| 10 | `foundry:music_playlist` and `foundry:music_stinger` in `asset`, with §7's fields; one tempo per playlist | §7 |
| 11 | Playlist switches land on the current track's next bar; stingers on the next beat, bar or now, ducked; a one-second lookahead, lowered in Step 6 if measured safe | §8.3, §8.4 |
| 12 | The runnable result is the court's soundtrack, with the `nocturne` content mod; the 2D samples are unchanged | §1, §9 |
| 13 | No ABI change; the call count stays 264; `audio_play` plays a streamed sound unchanged | §10 |
| 14 | The budgets: decode ≥ 50× real time on the i3; zero underruns, late starts and dropped commands over ten minutes; main-thread audio ≤ 0.10 ms p95; streamed music ≤ ⅛ of its 16-bit WAV size | §1, §12 |
| 15 | Loop points, seeking and voice stealing go to M31, disk streaming to M60, device change to M45 and the table's music calls to M48/M49; the roadmap's intent lines gain these "also" clauses at the close | §13 |
| 16 | Nine steps, in §15's order | §15 |

Once these are accepted, nothing blocks Step 1.

## 15. Implementation order — nine bounded steps

Each step ends with a Resolution here, an updated `PROJECT_STATE.md`, the bar and a commit.
There is no automatic chaining.

### Step 1 — `asset`: the Ogg container, and the reference fixtures

- Move `sinCosTurns` to `core.math.trig`, with `particles` importing it and its pins unchanged.
- Add `asset/ogg.zig` (§3.2).
- Write `scripts/m30/reference/` and `make_fixtures.py` (§3.5), record the tarballs' hashes in
  `AGENTS.md`, and commit the fixtures and their reference decodes.
- Tests: §12's Ogg items, run over the real fixtures.

**Exit:** every fixture's pages and packets read with their CRCs checked and their final
granule matching the reference's frame count, and every container refusal is reported by name.

### Step 2 — `asset`: Vorbis headers and setup

Add the identification, comment and setup headers (§3.3): codebooks with their Huffman trees,
floor 1, residues, mappings and modes, with every setup-time refusal in §3.4.

**Exit:** every fixture's setup parses, and every out-of-range field, incomplete tree and
floor-0 setup is refused by name.

### Step 3 — `asset`: decoding Vorbis, and `foundry:sound` version 2

- Add audio packet decode, the inverse MDCT, overlap-add and granule trimming. Add the whole
  decode to `Sound`.
- Add `.ogg` to the extension table, `stream` to the schema, and decoding by magic bytes in the
  loader (§4).
- Tests: the fixtures against their references, the hashes, the mutation sweep, and the speed
  printed.

**Exit:** criterion 1 holds on the Mac (the 50× bound is held at Step 8 on the PC), and an
`.ogg` dropped into a package plays through the existing `play`.

### Step 4 — `audio`: the clock, scheduled starts and ramps

§5: the clock, `start_at`, late starts, the events ring with start reports, and
`level × envelope` with both curves. Tests: §12's stepped-device items.

**Exit:** a voice scheduled to a frame mid-buffer starts on that sample, and a crossfade built
from two voices by hand has constant summed power at its middle.

### Step 5 — `audio`: streamed voices

§6: the stream table, the rings, decode tasks on `core.Tasks`, underruns that keep the timeline,
loops, lifetime with tasks in flight, and the loader keeping compressed bytes for `stream true`.
Measure the half-second margin against the gallery's load.

**Exit:** with `immediate`, a streamed voice equals its resident decode across three loop seams,
and with `Manual`, an underrun is silent, counted and recovers on time.

### Step 6 — `asset` and `audio`: music records and `audio.Music`

§7 and §8: both records, `Music` with crossfades, shuffle, switching on the bar line, stingers
with ducking, and reload. Measure the command-delivery latency, and settle the lookahead.

**Exit:** criterion 5's sequenced mix is pinned, and every scheduled start in it is on the frame
§8's arithmetic gives.

### Step 7 — `court`: the soundtrack, proved on the Mac

- Add `make_court_music.py`, the music and stingers, the records and `music.zig` (§9).
- Add the `nocturne` mod and the evidence log.
- Measure from a relocated ReleaseSafe install, and check `dist` staging.

**Exit:** criteria 2–4, 6 and 7 hold on the M5 with Metal, three ten-minute runs each. The
owner is offered a listening check.

### Step 8 — Windows/Vulkan

Clone on the PC. Run the null and Vulkan suites, the decoder's speed test and pins, and the
relocated court for ten minutes three times (with and without validation), plus its scripted
endings.

**Exit:** criteria 1–4, 6 and 7 hold on the Arc A750, with the pins checked against the Mac's
and any difference recorded.

### Step 9 — Close M30

Resolve the contract discrepancies where they were written:
- `audio.md` §11 (questions 1, 3, 4 and 5) and §12 (compressed formats, music sequencing),
  each pointing to where it was answered or who owns it;
- `background.md` §1's M30 line;
- ADR-0023's revisit triggers for music size and streaming;
- the intent lines of M31, M45, M48, M49 and M60 in `docs/ROADMAP.md` (§13).

Then:
- move ADR-0065 and ADR-0066 to Accepted and into `CLAUDE.md` §4.1;
- update §4.3's `audio` and `asset` descriptions, and §9's deferred row;
- update `AGENTS.md`: the reference tool's pin is already there from Step 1, and the bar
  changes only if a step changed it;
- update the ROADMAP's M30 row, the design index, the README and `PROJECT_STATE.md`;
- pack up the PC by exact path.

Tag `m30`, push when asked, and stop before M31's design.

## Resolution — Step 1: the Ogg container, and the reference fixtures (2026-10-26)

**Acceptance.** The owner's "Begin" on 2026-10-26 accepted §14 as written. ADR-0065 and
ADR-0066 are Accepted and listed in `CLAUDE.md` §4.1.

**Trig, moved.** `sinCosTurns` is now `core.math.trig` (`engine/src/core/trig.zig`), moved
from `particles` unchanged. `particles` imports it from `core`, and every particles pin passes
untouched. `CLAUDE.md` §4.1's particles row still says the module "owns its trig". Step 9
corrects that row along with the other close items.

**The reference tool** is in place, as §3.5 describes:
- `scripts/m30/reference/vorbis_ref.c`;
- `scripts/m30/reference.py`, which fetches, hash-checks, unpacks and builds;
- `scripts/m30/make_fixtures.py`.

`AGENTS.md` records the tarballs' hashes under "The Vorbis reference (M30)". Three details §3.5
had not fixed:
- **Quality is libvorbisenc's VBR scale**, −0.1 to 1.0, which is `oggenc`'s −1 to 10 divided
  by ten. The fixtures use −0.1, 0, 0.2, 0.4, 0.6 and 1.0.
- **The reference decode** is libvorbisfile's float output, each sample rounded to the
  nearest `x · 32768` and clamped to 16 bits. Foundry's WAV decoder divides by 32768, so the
  reference is exact to 2⁻¹⁶, and §12's 2⁻¹⁴ tolerance has room on top of that.
- **Each fixture has a fixed stream serial**, `0x46440000 + index`, so the same input gives the
  same file. Two full runs of the script wrote byte-identical fixtures.

**The seven fixtures** are in `engine/src/asset/testdata/vorbis/`, about 1.4 MB in all, almost
all of it the reference WAVs. The `.ogg` files total about 80 KB. The fixture meant to span
many pages (`long3s`) first came out at three pages, so it now has noise added and is encoded
at quality 0.6, which gives eight pages. The others have three to six pages. The headers alone
take two pages in every libvorbis file.

**`asset/ogg.zig`** implements §3.2. Implementing it settled several things the design had not:
- **Two readers share one set of rules.** `scan` walks every page once and allocates nothing,
  returning the serial, the page count, the codec and the final granule. `Packets` walks the
  packets, borrowing each from the file unless it spans pages, and gathering it into its own
  buffer when it does. Both use one `Walk` for the rules between pages, so they cannot
  disagree about what a valid stream is.
- **The codec is identified in the container.** The stream's first packet must end on its
  first page, as every Ogg mapping requires, and is matched against the Vorbis, Opus, FLAC,
  Speex and Theora signatures. Refusing a codec that is not Vorbis is the decoder's job, from
  `Info.codec`, in Step 2.
- **More is refused than §3.2 listed:**
  - a page that sets reserved flag bits;
  - a first page that does not begin the stream, or a later one that begins it again;
  - a continuation flag that disagrees with the packet left open, in either direction;
  - a granule that goes backwards;
  - a last page that leaves a packet open, or has no granule (the stream would have no
    length);
  - bytes after the last page.

  Bytes after the end are told apart: a page beginning a new stream is `UnsupportedSound`
  ("a chained file"), and anything else is `InvalidSound`.
- **No packet-size limit is needed.** A packet that spans pages is gathered from the file, so
  it can never be larger than the file already in memory.

**Every fixture's final granule equals the reference decode's frame count exactly**, for all
seven. That confirms what §3.3 relies on: libvorbisfile trims the last block to the granule,
so Step 3 has an exact length to match.

**A real bug was caught by its own test.** In `parsePage`, `header_size + segments` was summed
in `u8` because `segments` was the page's byte. A page with 255 segments, which is legal, then
overflowed: a checked panic in Debug and ReleaseSafe, and a wrong length in an unchecked build.
The 255-segment test found it, and `segments` is now a `usize`. It is the kind of bug the
mutation sweep in Step 3 exists to find.

**Guards checked by breaking them.** Disabling each of three checks failed the suite: the CRC
comparison, the page-sequence check and the serial check (the multiplexed and chained tests).

**What Step 1 does not do:** no Vorbis header is parsed, and `.ogg` is not yet a sound. Those
are Steps 2 and 3.

**Bar:** all exit 0, with `zig build test` at **2,304/2,305** (one skip, M27's). The suite grew by the nine Ogg tests.

## Resolution — Step 2: Vorbis headers and setup (2026-10-26)

**`asset/vorbis.zig`** reads the three headers (§3.3), with every setup-time refusal in §3.4.
- **`readHeaders`** runs in a fixed order, so nothing is allocated from a field that has not
  been checked:
  1. `ogg.scan` checks the container, and refuses a codec that is not Vorbis by name ("the
     stream is Opus, not Vorbis; re-export as Ogg Vorbis").
  2. The length is checked against `Limits.max_frames`, and a stream with zero frames is
     refused.
  3. The identification header is parsed.
  4. The comment header is checked.
  5. The setup header is parsed, the only step that allocates.
- **`Setup`** owns an arena holding every codebook, floor, residue, mapping and mode. Step 3's
  decoder and Step 5's streams share it read-only, as §6.1 planned.

What implementing it settled:
- **A memory budget for the setup**, `Limits.max_setup_bytes`, 32 MiB by default. Every arena
  allocation is checked against it before it is made, and exceeding it is `SoundTooLarge`.
  §3.4 had bounded the frame count but not the setup. An ordered codebook can declare 2²⁴
  entries in a few bits, so without this a hostile file could make the setup allocate
  gigabytes. The fixtures' setups need 124–566 KB. A test confirms the budget refuses before
  allocating, with a failing allocator.
- **Lookup values must fit in the packet.** A type-2 book's multiplicands are read from the
  packet, so a count beyond its remaining bits is refused before anything is allocated.
- **Codewords are stored bit-reversed.** Codewords are defined most significant bit first,
  but Vorbis reads bits least significant first. Reversing them once at setup lets Step 3
  compare directly. The specification's worked example (§3.2.1, lengths 2 4 4 4 4 2 3 3) is
  a test.
- **Trees:**
  - complete trees and single-entry books are accepted, as libvorbis accepts them;
  - an overspecified tree is refused by name;
  - an underspecified tree with more than one entry is refused.

  Disabling the overspecified check showed that the underspecified check also catches every
  overspecified tree: an assignment with no room left always leaves a free branch behind. The
  first check therefore only gives the refusal its right name. That is recorded here so a
  later session does not mistake it for the only guard.
- **More is refused than §3.4 listed:**
  - a codebook with no dimensions or no entries;
  - an ordered codebook whose runs pass its entries, or whose lengths pass 32 bits;
  - a floor with more than 65 points (Vorbis I §7.2.2), or two points at one x;
  - a residue book that has no value table (a residue decodes vectors);
  - a mapping type other than 0, or a non-zero reserved field;
  - a channel coupled with itself, which covers any coupling in mono;
  - a submap index past the count.

  An unsupported Vorbis version is `UnsupportedSound`. A zero channel count or a zero rate is
  `InvalidSound`.
- **Values are computed in `f32`, as libvorbis computes them**:
  `multiplicand × delta + minimum + last`, left to right. `float32_unpack` is exact in `f64`
  before the cast, so an exponent near the top overflows to infinity, and the finiteness
  check refuses it.
- **Floor 1 precomputes its sort order and neighbours** at setup, so Step 3's curve does no
  searching per packet.

**What the fixtures hold.** libvorbis 1.3.7 writes:
- 32 to 44 codebooks, with at most 6,561 entries, 8 dimensions and 22-bit codewords;
- two floors, all type 1;
- two modes. The exception is `stereo22_qm1`, at 22.05 kHz and quality −0.1, which has one
  mapping and one mode, with block sizes 1024/1024.

`long3s` (22.05 kHz, quality 0.6) uses 512/1024 blocks, and the rest use 256/2048. Mono uses
residue type 1, and coupled stereo uses residue type 2, except `stereo22_qm1`, which uses
type 1.

**Two paths no fixture reaches**, both for Step 3:
- **Residue type 0**, which no current libvorbis writes. Step 3 tests its decode on a
  hand-made packet against the specification's algorithm.
- **A single-entry codebook.** libvorbis decodes one by reading one bit and returning the
  entry whatever its value. Step 3 does the same, and tests it the same way.

**Tests:** twelve:
- the bit reader;
- `ilog`, `float32_unpack` and `lookup1_values` against the specification;
- codeword assignment and both tree refusals;
- every fixture's headers against its reference WAV's channels, rate and length;
- a minimal hand-written setup, then 24 copies of it, each with one field out of range, every
  one refused with the right error;
- every truncation of the minimal setup, and of a real one;
- the memory budget;
- the identification header's ten cases;
- the comment header;
- another codec, zero frames and too many frames.

**Guards checked by breaking them:** disabling the underspecified-tree check, the finiteness
check and the mapping's floor index each failed the suite. The overspecified check is the case
described above.

**What Step 2 does not do:** no audio packet is decoded, and `.ogg` is not yet a sound. That is
Step 3.

**Bar:** all exit 0, with `zig build test` at **2,316/2,317** (one skip, M27's), twelve tests more than Step 1.

## Resolution — Step 3: decoding Vorbis, and `foundry:sound` version 2 (2026-10-26)

**`asset/vorbis.zig` decodes audio** (§3.3). `Decoder` reads a checked stream packet by
packet into a caller's buffer: the floor, the residue, inverse coupling, the inverse MDCT, and
overlap-add. `decode` fills a whole `Sound`. The decoder is about 1,500 lines with the
headers, and about 750 more of tests.

**Every fixture matches the reference within 1.55 × 10⁻⁵** (criterion 1's bound is 2⁻¹⁴, about
6.1 × 10⁻⁵). That is half of one 16-bit step, so the only difference left is the reference's own
rounding. The root-mean-square difference is 8.8 × 10⁻⁶ on every fixture. Each fixture also
decodes to exactly its reference's frame count, and each output is pinned by hash. The same
hashes hold in Debug and in ReleaseSafe.

**Where the specification leaves room, the decoder follows libvorbis 1.3.7.** It is the oracle
the tests compare against, and it is what authors' players run. Reading its source settled
these:
- **Running out of packet.** In a floor, the channel is unused. In a residue, decoding stops and
  what was decoded stays. A type 0 partition reads all its entries before adding any of them.
- **A single-entry codebook** is accepted only when its one codeword is one bit long, and
  decoding it reads one bit and returns the entry whatever the bit is. Step 2 had accepted a
  single entry of any length, and that is now refused as underspecified, as libvorbis refuses
  it.
- **A book with no used entries** reads nothing and adds nothing when it decodes vectors. As a
  scalar book, it ends the floor or residue.
- **Floor values** are masked to 15 bits, with bit 15 marking a point the curve skips, and
  clamped to 0–255 before the inverse-dB table is read. The table is libvorbis's 256 constants,
  the same values as the specification's `floor1_inverse_dB_table`.
- **A residue's classbook** must be big enough to name every classification of a word
  (`classifications ^ dimensions ≤ entries`). libvorbis refuses a setup that is not, and so does
  this, as a new refusal at setup. A classbook entry beyond `classifications ^ dimensions` ends
  the residue.
- **Type 2 residue** de-interleaves from frame `offset / channels`, starting at channel 0.
  That only differs from the specification's interleaving when an offset is not a multiple of
  the channel count, which no encoder writes.
- **The window follows the blocks' actual sizes**, and the packet's two window flags are read
  and ignored, as libvorbis's synthesis ignores them. The overlap is `vorbis_synthesis_blockin`'s.
- **Granules.** The first granule that reaches a packet trims the stream's start, or its end if
  that packet is the last. The last granule trims the end. Neither trims more frames than the
  packet made. A granule mid-stream that disagrees is believed, without a trim.
- **An empty packet is dropped.** A header packet among the audio packets, or a mode index past
  the count, refuses the file. libvorbis skips those, but skipping would leave the file a
  different length from the one it claims.

**The decoder's stream contract** is the length its last granule claims, exactly. It never
hands out a frame past that length. If the packets hold more frames or fewer, the file is
`InvalidSound`. So is a non-finite sample, which the decoder checks as it copies each sample
out.

**The inverse MDCT** is unscaled, as libvorbis's `mdct_backward` is. It treats the
transform as a DCT-IV of `n/2` points: one `n/4`-point complex FFT between two twiddles, then
unfolded. The twiddles, the FFT roots, the bit-reversal and the window slopes are built per
block size into the setup's arena, from `core.math.trig`. They count against the setup's memory
budget. A test checks the transform against its direct O(n²) sum at 64, 256 and 2048 points.

**Codebooks decode through a first-stage table** of up to ten bits. A longer codeword continues
down an explicit tree from the table's node. Both are built at setup and budgeted. A test
decodes 13-bit codewords through the tree.

**Speed (criterion 1):** stereo 48 kHz at quality 4 decodes at **1,119× real time** on the
M5, in ReleaseSafe on one thread (about 54 million frames per second). The bound is 50× on the
Arc PC's i3, checked at Step 8. Run the timing test with
`zig build asset-test -Doptimize=ReleaseSafe`. A Debug build prints a figure too, but it means
little.

**The mutation sweep (§12):**
- every truncation of `short`;
- 2,000 seeded single-bit flips across `stereo48_q4`, each with its page's CRC recomputed so
  the flip reaches the decoder.

Each case decodes or is refused, and none panics. A Debug run, which the bar uses, does 200 of
the flips so that it stays quick. ReleaseSafe runs all 2,000, and they passed.

**Hand-made packets** cover the two paths no fixture reaches (Step 2's Resolution): residue
type 0's step interleaving, and a single-entry classbook. They also show that running out of
packet keeps the partitions already decoded.

**`foundry:sound` version 2** (§4) adds `stream bool (default false)`, and version 1 packages
still load. `.ogg` is in the extension table beside `.wav`. The mixer's loader picks the decoder
by the file's first four bytes, `OggS` or anything else, never by its extension. A WAV that says
`stream true` is refused with `UnsupportedVersion`.

One gap until Step 5: **an Ogg that says `stream true` is decoded whole and kept resident.**
Step 5 keeps it compressed and decodes it as it plays (§6). That step owns the change, and
nothing else depends on it. `docs/modding/content-mods.md` now lists Ogg Vorbis and `stream`.

**Integration tests (`engine/tests/sound_pipeline.zig`):**
- an `.ogg` plays through the existing `play`, sample for sample what `vorbis.decode` gives;
- a streamed `.wav` is refused, and a streamed `.ogg` loads;
- an Opus file is `UnsupportedVersion`, and a broken Ogg is `InvalidAsset`.

`fpack`'s derivation test now derives an `.ogg` beside the `.wav`.

**Guards checked by breaking them.** Disabling each of these failed the suite:
- the finiteness check;
- the end trim;
- the one-bit single-entry rule;
- the classbook-size refusal;
- the header-among-audio refusal;
- a type 0 partition reading all its entries before adding any.

The decoder's overrun and short-length checks were backed up by `decode`'s own length checks,
so disabling either one at first failed nothing. A test now drives `Decoder.read` directly, as
Step 5's streams will, and both of those mutations now fail it.

The tree builder's codeword-collision refusal cannot be reached, because Step 2 has already
proved the tree complete. It remains as a guard in case that proof ever changes.

**Not in this step:** no stream, mixer clock or schedule exists yet, and none of the court's
content has changed, so `dist` staging is not due until Step 7.

**The integration tests' first run corrected two of them.** The null device opens at 48 kHz
unless asked otherwise, so the `.ogg` test now opens it at the fixture's 44.1 kHz. A sound
whose first load failed cannot be acquired to reload, so the Opus and broken-Ogg cases are now
two records rather than one file rewritten.

**Bar:** **2,330/2,331** (one skip, M27's), with 14 new tests: 11 in `vorbis.zig` and 3 in
`sound_pipeline.zig`. Every line exited 0: fmt, test, the four checks, the four
thirty-frame headless runs and `fdt-check`.

## Resolution — Step 4: the clock, scheduled starts and ramps (2026-10-26)

§5 is implemented in `audio/voice.zig` and `audio/mixer.zig`. Nothing in the public table
changed, and `setGain`'s meaning did not change either.

**The clock.** The callback keeps `mixed`, the frame number of the next buffer's first sample.
After clamping each buffer, it adds the buffer's length and publishes the count with a release
store, so a game that reads `clock()` (acquire) also sees every event that buffer pushed.
Buffers before `ready` are not mixer frames, and do not count.

**Scheduled starts.**
- `apply` turns every `play` into a pending voice whose `start_at` is either the frame asked
  for or `mixed`.
- An immediate start (`start_at` null) goes through the same path, which keeps one code path
  and makes `startedAt` answer for every voice.
- A frame already past counts in `lateStarts()`. A frame exactly at `mixed` is on time.
- A pending voice is skipped until the buffer that contains its frame. It then mixes into the
  slice of the buffer from that offset, with that frame number, so its first sample lands on
  that frame.

**The events ring.**
- `from_audio` carries `{ started | retired, slot, generation, frame }` and is sized
  `2 × voices`.
- A voice starts at most once and retires at most once. Its slot cannot be claimed again until
  `update` drains the retirement, and so (the ring being FIFO) the start before it too.
- A voice stopped while still pending pushes only its retirement.
- `startedAt(voice)` is null until `update` has heard, and again once the slot is no longer
  live.

**Ramps: the design said "an increment kept in the voice". The step made them a function of
the mixer frame instead.**
- `Ramp.at(frame)` computes `from + (to − from)·shape(t)` from `frame − begin`, and keeps no
  running count. A voice that waits several buffers to start therefore cannot fall out of step
  with a ramp scheduled to the same frame.
- The cost is one `f64` division per frame per voice that is fading.
- The ramp's end frame returns `to` exactly.

**A fade replacing one under way was the case the design had not settled.** The first version
started a new ramp from the last value produced. That value lags the frame the new ramp begins
on, so a fade issued right after another one ended started from the old one's second-to-last
value. The test of a fade issued in the following buffer caught it.

The answer now is that `start` queues the new ramp as `next`. The running ramp carries on
until the new one's begin frame. The new ramp then starts from the value the old one has *at
that frame*, even when the voice is first visited after it. A scheduled fade therefore never
jumps. A third fade issued before the queued one begins replaces it. One queued ramp is all
`Music` needs: a crossfade or a duck issues one fade per voice at a time.

**Fades with no frame, or a frame already past,** begin at `mixed` and run their whole length.
They are not counted: a late fade ends late, and §12 requires only that late *starts* stay at
zero.

**A stopping fade** retires its voice on its end frame, without writing that frame (its target,
which is silence). `frames 0` with `stop` therefore retires the voice at the next callback,
with no special case needed.

**Two gains.** `PlayParams.gain` is the initial `level`, and `PlayParams.envelope` the initial
envelope.
- `setGain` holds `level` at once, and cancels both a `fadeGain` under way and one queued.
- `fadeGain` ramps `level` linearly from the next callback.
- `fade` ramps the envelope with either curve, optionally from a scheduled frame.

A voice's output gain is `level × envelope`. The envelope is exactly 1 unless a fade moved it,
and `x × 1` is exact, so every earlier mix, pin and test is bit-identical.

**Equal power.** `shape` is `√t` rising and `1 − √(1 − t)` falling. A voice falling from 1 to 0
therefore follows `√(1 − t)`, and two crossing voices satisfy `a² + b² = 1` at every frame. The
exit test pans one voice hard left and the other hard right, so each channel is one voice's
gain:
- with `equal_power`, the summed power is 1 within 10⁻⁶ at the middle and at every frame;
- with `linear`, the middle reads 0.5, the 3 dB dip the curve exists to avoid.

**A start reported for an earlier voice.** `update` stamps `started_at` only when the event's
generation is the slot's. The FIFO never delivers a stale start (a slot is freed only after its
retirement, which follows its start), so removing the check first survived every test. A test
now pushes a forged start for a slot's earlier generation, and it holds the check in place: the
slot is told apart by generation, never by trusting the order alone.

**Guards verified by mutation.** Each was broken, the suite run, and the file restored:
- mixing a scheduled voice from offset 0 instead of its frame failed the mid-buffer start;
- not counting a past start failed the lateness test;
- linear in place of equal power failed the crossfade and the curve test;
- a queued ramp starting from its own `from` rather than the running ramp's value at its begin
  failed the chain test;
- `stopped` never true failed three tests, the stopping fades among them;
- the clock not advancing failed two tests, the clock's among them;
- a past fade frame kept as given failed the next-callback fade test;
- an events ring sized `voices` panicked on the full-buffer test, as its assertion says;
- the start's generation check removed failed the forged-start test.

**Bar.** `zig build test` passes 2,341 of 2,342 (one skip, M27's), with 11 new tests. fmt, the
four checks, the four thirty-frame headless runs and `fdt-check` all exit 0.

## Resolution — Step 5: streamed voices (2026-10-26)

§6 is implemented: `audio/stream.zig` (the ring), streamed reading in `audio/voice.zig`, and the
stream table, decode tasks and lifetime in `audio/mixer.zig`. In `asset/vorbis.zig`, the
decoder gained `prove`, `Decoder.reserve` and `Decoder.rewind`. Nothing in the public table
changed shape.

**The loader keeps a streamed sound compressed** (§4). With `stream true`, its decode phase
runs `vorbis.prove`, which decodes the whole file in 1,024-frame pieces and keeps none of it.
It then hands the finish a copy of the bytes and the parsed headers. A one-hour track
therefore costs its file size plus one piece at load, never its length in samples.
`Mixer.insertStreamed` does the same for a caller that holds bytes rather than content. The
`.ogg` gap that Step 3 left is closed: `stream true` now streams.

**The ring is a feed of absolute frames.** `Feed` holds a stream's frames in `storage`, one
second at the sound's own rate.
- `written` is the producer's count and `consumed` the consumer's. Both are positions in
  the stream counted across every pass of a loop, and frame `f` lives at index
  `f % capacity`.
- Two release/acquire pairs are the whole ordering argument, and `stream.zig` states it as
  `ring.zig` does:
  - the producer writes frames, then publishes `written`;
  - the voice publishes `consumed` once it is past a frame, and the producer reads it
    before overwriting that frame's index.
- Because positions are absolute, an underrun needs no special path. The voice moves on, and
  the frames it skipped are written later at indices nobody reads (§6.3).

**The voice reads the feed with the resident path's own arithmetic.**
- It keeps the same wrapped `f64` cursor and adds `pass`, the count of completed loop
  passes, so a frame's stream position is `pass × frames + index`.
- At a loop's seam, the interpolation's neighbour is the next pass's first frame.
- The cursor's rounding is therefore bit for bit the resident voice's. The exit test compares
  every sample across three seams, at the device's rate and resampled from 44.1 kHz, and
  they are equal.

**An underrun is counted once per buffer**, per voice that missed at least one frame in that
buffer. `underruns()` counts glitches heard, not frames lost. One stall is one count, however
long.

**An unscheduled streamed start waits for its first frames.** The design did not say what
`play` with no `start_at` should do before the first decode lands. Starting at the next
callback would underrun at once on a real pool and cut the track's opening. There is no
timeline to keep yet, so such a voice stays pending until two frames are written, then
starts. `startedAt` reports the frame it actually began on. A scheduled start keeps its frame
and underruns instead, as §6.3 requires.

**A decode task never allocates.**
- `Decoder.init` runs on the game thread in `play`, which may fail. Its buffers are fixed by
  the block sizes.
- The one other allocation is the Ogg reader's buffer for a packet spanning pages. `prove`
  measures that buffer's size over the whole file, and `play` reserves it.
- `rewind` restarts at the first audio packet and keeps that capacity.
- A test proves it with a failing allocator armed after `reserve`: three passes per fixture
  allocate nothing and equal the reference.
- No encoder's fixture has a packet that spans pages, so the test also repaginates every
  fixture into one-segment pages. Every packet over 255 bytes then spans, the reserve is real
  (over 255 bytes for each), and the frames are identical.
- If a task's decode fails anyway, it logs, ends the stream, and the voice hears an underrun.

**Repaginating the fixtures found a Step 3 bug, fixed here.**
- A page's granule of −1 means no packet ends on it. `Packets` returned that value as the
  granule of a packet that did end there, and the decoder's position arithmetic then
  overflowed: a crafted file could panic it.
- `Packets` now gives such a packet no granule, as libvorbis reads it. The position addition
  saturates, so a granule near the top of the range cannot overflow either.
- A container test pins the first. The second is a guard behind `scan`, which refuses a final
  granule above `max_frames` and granules that go backwards, so it cannot be reached.

**The stream table** is fixed at `init`.
- `Options.streams` sets its size, 4 by default. Each stream's ring is allocated at 192 kHz
  stereo, one second, as §6.1 says: the most any stream can need. That is 1.5 MiB a stream,
  6 MiB at the default, whether or not anything streams.
- A game that streams nothing can set `streams = 0`.
- If the fixed cost ever matters, a smaller rate ceiling with a named refusal is the change;
  it does not matter for M30.
- Past the table, `play` returns `NoFreeStream`, and the public `audio_play` maps that to
  `FOUNDRY_ERR_LIMIT`, as it maps `NoFreeVoice`.
- `VoiceError` also gained `OutOfMemory`, for the decoder's state.

**Where streams decode:** `Options.tasks`, `immediate` by default.
- Under `immediate`, the first fill runs inside `play` and each refill inside `update`.
- A game passes its background pool's tasks. No sample streams yet, so none is changed here.
  The court passes its pool in Step 7.
- `update` settles finished tasks, starts a refill for any stream below half full with no task
  in flight, and frees streams that both sides are done with.

**Lifetime** (§6.5).
- A stream holds its own reference on the sound beside its voice's, so a hot reload, or a
  `releaseSound`, frees the compressed bytes only once the decode task is done too.
- A retired voice marks its stream, and the stream is freed when its `Done` is seen.
- `shutdown` and `deinit` wait for the executor only if a task is actually in flight. A pool
  torn down first has already run what it held, and a mixer outliving its pool must not call
  into it.

**`streamBuffered(voice)`** reports the frames decoded ahead of a streamed voice. It is a
diagnostic, and it is how the margin was measured.

**The half-second margin, measured against the gallery** (§6.2).
- The setup is the worst position a refill can be in:
  - the gallery's eight 2048×2048 PNG decodes, each with its sRGB mip chain as the texture
    loader's decode builds it, are queued on a real `platform.Background` with the default
    two threads;
  - then a stream is started half a second ahead, so its first decode waits behind all
    eight;
  - then it plays in real time, in 10 ms buffers, for two seconds.
- On the M5, ReleaseSafe, five runs: the first frames arrived **265–272 ms** after the stream
  was queued (the gallery itself finished at 266–276 ms), against the 500 ms margin. There
  were **no underruns**.
- The pool is FIFO, so the stream's decode waits for every gallery decode started before it.
  The margin is the gallery's whole decode time plus a moment. Step 8 measures the same on
  the Arc PC, where M27's synchronous gallery took 834–841 ms against the Mac's 548–575 ms,
  so the margin there is the open question.
- The test skips in Debug, where its timings mean nothing, which is why the bar now reports
  two skips. Run it with `zig build integration-test -Doptimize=ReleaseSafe`.

**Found and not changed:** that ReleaseSafe run also fails
`ui_theme.test.a valid theme resolves…` on a last-bit float comparison (0.7605246 against
0.76052463). It is an existing integration test whose code this step does not touch, and
the Debug bar passes. It is reported to the owner rather than fixed here.

**Guards verified by mutation.** Each was broken, the suite run, and the file restored. Each
of these failed it:
- reading a frame the producer has not written, instead of underrunning;
- an underrun that holds the cursor instead of moving it on (the timeline);
- `pass` not counted at a seam;
- a seam's neighbour read from the current pass rather than the next;
- a second decode task started while one is in flight;
- a stream freed before its task's `Done`;
- the stream's own reference on the sound dropped;
- an unscheduled streamed start not waiting for its first frames;
- `shutdown` freeing streams without waiting for their tasks;
- the proving pass replaced by reading the headers alone;
- `rewind` dropping the reserved capacity;
- `reserve` doing nothing;
- `Packets` passing a granule of −1 through.

The `reserve` mutation first survived, because each repaged fixture's setup header spanned
pages and grew the buffer at `init`, before the failing allocator was armed. The repaging
keeps the three headers on whole pages now, so only audio packets span. In `mono44_q10` and
`coupled` they do, and the test requires both to.

**Bar.** `zig build test` passes 2,353 of 2,355. The two skips are M27's and the margin test,
which runs only in ReleaseSafe. There are 13 new tests:
- one in `stream.zig`;
- eight in `mixer.zig`;
- one each in `vorbis.zig` and `ogg.zig`;
- two in `sound_pipeline.zig`.

fmt, the four checks, the four thirty-frame headless runs and `fdt-check` all exit 0.

## Resolution — Step 6: music records and `audio.Music` (2026-10-26)

§7 and §8 are implemented: `asset/music.zig` (both records) and `audio/music.zig` (`Music`).
Nothing in the public table changed.

**The records** are in `asset` beside `particle_emitter`, with §7's fields and defaults.
- Both are registered where the emitter is, in the engine's content registry and in the
  compiler's.
- The compiler's `checkMeanings` decodes them, so `fpack` and the editor refuse a bad one at
  its line, by the same decoder the engine runs: "music playlist 't:calm' has a tempo that
  is …".
- A track, or a stinger's sound, that is not a `foundry:sound` is refused where the IDs
  resolve, when `Music` reads the record (`NotASound`). A playlist may name another
  package's sounds.
- `.fdt` text cannot spell a non-finite number, so that refusal is tested on decoded values.

**Two public mixer calls were added**, both game-thread and both callable by any game, so
`Music` is still unprivileged:
- **`fadeGainAt(voice, at, gain, frames)`:** a level ramp that begins on a scheduled frame.
  §8.4's duck must end on the stinger's first frame, and `fadeGain` begins at the next
  callback. `fade` already took a frame; the level ramp now can too.
- **`soundInfo(id)`:** a sound's length in device frames, and whether it streams. `Music`
  needs the next track's length before it starts the track, to decide where it starts. The
  length is `ceil(frames / step)`. A resampled voice accumulates its step, so its real end
  can differ by a frame. No scheduled start depends on that frame: an end only ends a voice.

**A gain ramp holds one queued ramp** (Step 4), and a duck needs two: down, then back up. If
both were sent at once, the release would replace the descent before the descent began.
- `Music` therefore defers the release, and sends it from `update` once the clock has passed
  the descent's begin frame, when the descent is running and the queue is free.
- A `setGain` during a duck takes the voice's queue too, so it re-queues the release behind
  itself.
- The release multiplies the playlist's gain by the music's gain as it is sent, not as it was
  when the stinger was played. The setGain-under-duck test caught both of these: the music
  either stayed ducked for good or came back from the pause.

**Scheduling is just in time.** A track's successor is scheduled once `clock + lookahead`
reaches the earliest frame it could start on. `Music` holds only the head track, the one every
later decision is relative to. Its arithmetic, all in `u64` frames from `f64` seconds rounded
once:
- **Tracks:**
  - the successor starts at `start + frames − crossfade`, with its envelope at 0, and both
    fades are `equal_power` over the crossfade, the old one stopping;
  - entering a playlist fades in over its crossfade.
- **The 2× edge** (§8.2 left it open): a crossfade happens only when both tracks are at
  least twice the crossfade. Otherwise the successor starts at the head's end, with no fade
  either way. Entering a playlist fades in only if its first track is long enough.
- **Grid points:** `start + round((first_beat + n · beats · 60 / tempo) · rate)`, for the
  smallest `n` at or after the earliest frame.
  - A switch takes the head's grid of `beats_per_bar`, with the earliest frame
    `max(clock + lookahead, head.start)`.
  - It is clamped to the head's end, so a switch asked late in a track lands where the track
    ends.
  - The old head fades over the new playlist's crossfade on the same frame, or stops on it
    with no crossfade.
- **Stingers** take the head's grid of one beat (`beat`) or one bar (`bar`), or none (`now`).
  - The duck ramps down over `duck_fade`, ending on the stinger's first frame, and back up
    over `duck_fade` from its last.
  - A second stinger in a duck extends it.
  - A track starting inside a duck starts at the ducked level, with its own release.
- **Shuffle:** Fisher–Yates per cycle, from a `core.rng.Pcg32` seeded by `Options.seed`. A
  cycle whose first track would repeat the last one played swaps it with the cycle's last.
- **`loop false`:** after the last track nothing is scheduled, and the head plays out;
  `current()` is then null.
- **`stop`:** ramps every music voice to 0 over its time with `stop`, scheduled starts
  included, and forgets the playlist. Stingers already playing finish.

**Reload** (§8.5). `contentChanged` marks the playlist, and the record is read again at the
next boundary, never before, so the track playing is never cut. A changed track list starts a
new cycle of the new list there. An unchanged one keeps its place. Stingers are read at every
`stinger` call.

**The lookahead, settled.** §8.4 asked for the command-delivery latency to be measured, and
the lookahead lowered if the measurement allowed.
- On the M5's real CoreAudio device, at 48 kHz with 512-frame buffers, a test played 400
  silent voices, each scheduled for the clock it had just read, three times over. **0, 1
  and 1** of the 400 slipped, each by **exactly one buffer** (10.7 ms).
- One buffer is also the structural bound: a command pushed while a callback is already
  mixing waits for the next callback.
- So the lookahead splits in two:
  - **Tracks keep one second.** What binds them is a streamed track's first decode, which
    Step 5 measured at 265–272 ms behind the gallery on the Mac. The PC's figure is Step 8's,
    so lowering it now would be a guess.
  - **A resident stinger takes `stinger_lookahead_seconds`, 0.1 s**, about nine buffers. A
    streamed stinger takes the track lookahead.
- §8.4's "known cost", a stinger waiting up to 1.6 s at 96 bpm, becomes at most a beat
  plus 0.1 s for a resident stinger: about 0.7 s at 96 bpm.
- The test runs only in ReleaseSafe with a real backend, and skips otherwise; it is the
  bar's third skip.

**Criterion 3's evidence.** `Music` keeps a ring of its last 64 asked starts (`starts()`,
`startCount()`). Step 7's log compares each with `Mixer.startedAt`, and the tests here do it
after every buffer.

**Criterion 5, pinned.** The sequenced mix runs on the stepped null device with immediate
tasks: playlist A at 360 bpm in two-beat bars, its crossfade, a stinger on the beat with its
duck, a switch on the bar to playlist B, and B looping into itself.
- Each of its five starts equals arithmetic written out in the test (1,024; 10,624; 18,624;
  42,624; 61,664), and the frame the mixer reports.
- Two runs give the same samples, and their Wyhash is pinned at `2692657964278199496`.
- The switch is placed where the next beat (34,624) and the next bar (42,624) differ, so
  quantizing to a beat instead of a bar fails the pin. In the first scenario they coincided,
  and that mutation passed.

**Guards verified by mutation.** Each was broken, the suite run, and the file restored. Each
of these failed it:
- the crossfade boundary taken as the head's end;
- a linear fade in place of equal power;
- a switch quantized to the beat, not the bar;
- the 2× edge removed;
- the shuffle's no-repeat swap removed;
- scheduling with no lookahead (the starts were late);
- a duck's release sent at once;
- `contentChanged` ignored;
- the tracks-are-sounds check removed;
- a streamed stinger given the short lookahead;
- the same playlist restarted by a second `play`;
- the compiler's playlist check removed;
- the tempo limit removed;
- `setGain` dropping the duck factor;
- `setGain` not re-queueing a release;
- a release using the gain from before the pause.

Three of these first survived, and each now has a test that holds it:
- the bar mutation, until the switch was moved off a frame where beat and bar coincide;
- `contentChanged`, until the playlist was re-read only on it, as the design's API says. It
  had been re-read at every boundary, which made the call do nothing;
- the no-repeat swap, until a two-track shuffle over twenty cycles was added. With four
  tracks and seed 7, no cycle repeated its predecessor's last track.

**Bar.** `zig build test` passes 2,369 of 2,372. The three skips are M27's and the two
measurements, the stream margin and command delivery, which run only in ReleaseSafe. There are
17 new tests:
- two in `asset/music.zig`;
- one each in `mixer.zig` and `compiler.zig`;
- thirteen in `engine/tests/music_sequencing.zig`.

fmt, the four checks, the four thirty-frame headless runs and `fdt-check` all exit 0. The
ReleaseSafe integration run passes everything except the ui_theme float comparison Step 5
reported.

## Resolution — Step 7: the court's soundtrack, proved on the Mac (2026-10-26)

§9 is implemented: `scripts/m30/make_court_music.py`, the court's music and records,
`samples/court/music.zig`, the `nocturne` mod and the evidence log. Nothing in the public
table changed. One engine change was found necessary and made (the setup's memory, below).

**The music.** The script synthesises every piece in Python (chords, bass, soft percussion and
a melody, 48 kHz stereo) and encodes it with Step 1's reference tool at quality 4 (`0.4`), each
with a fixed serial.
- The court's pieces are at 96 bpm in 4/4:
  - tracks in `content/music/tracks/`: `title` (10 bars, 25 s), `calm_a` and `calm_b` (20
    bars, 50 s each) and `chase` (13 bars, 32.5 s);
  - stingers in `content/music/stingers/`: `beacon` (1.6 s), `gate` (2.5 s) and `ending`
    (3 s).
- `nocturne`'s pieces are at 72 bpm in 3/4, so its bars are also 2.5 s: `nocturne_a` and
  `nocturne_b` (16 bars, 40 s each) and its own `beacon`.
- All ten files come to **1.8 MB**, against 47 MB as 16-bit WAV. §9 estimated 3 MB against
  27 MB; the synthetic music compresses better than that estimate assumed.
- The files sit under `tracks/` and `stingers/`, because a sound's ID derives from its path
  and the playlists and stingers want the short names (`court:music.calm` is the playlist,
  `court:music.tracks.calm_a` its sound).

**The records** (`court.fdt`):
- the four tracks are `foundry:sound` records with `stream true`; the stingers derive
  resident sounds from their paths;
- the three playlists are at tempo 96 in 4/4, the calm one shuffled at gain 0.8;
- every crossfade is **one bar (2.5 s), not the 2 s default**: a track then begins on its
  predecessor's bar line, so their beats coincide through the crossfade. With 2 s, two
  tracks at 96 bpm would overlap 0.125 s off the beat;
- the three stingers, with ducks of 0.5, 0.4 and none.

`court:music.main`, of the court's own schema `court:music_set`, says which record plays when,
so `music.zig` names no music itself (I5).

**Two places the design was sharpened:**
- **The chase is not at the hearing distance.** §9 said chase while the warden is within the
  sound set's `hearing_distance`. That is 14 m, and the court is smaller than that: the warden
  is always within it, so the chase would never end. The music set has its own
  `chase_distance`, 3 m, which the warden comes within only when it passes near the player.
  The design's two-second hold is `chase_hold`. Both are counted in playing ticks, so a pause holds the chase where it
  was.
- **The ending lands on a beat, not a bar.** The ending fades the music over a second
  (`ending_fade`), and a bar at 96 bpm is 2.5 s, so a bar-quantized ending could arrive after
  more than a second of silence. The stinger is asked first, so it takes its beat from the
  music before `stop` fades it.

**`music.zig`** maps the game's state to calls, as `sounds.zig` maps events:
- the title plays `title`;
- `playing` plays `calm`, or `chase` while the warden has been within `chase_distance` in the
  last `chase_hold` seconds;
- entering `paused` calls `setGain(0.3, 0.25)`, and leaving it `setGain(1, 0.25)`;
- the beacon and gate events play their stingers;
- won, caught and fell play `ending` and then `stop(1.0)`.

It asks for a playlist only when the answer changes. It reads the game and the game never
reads it (I9): the scripted runs' replays still match a fresh simulation at every tick. The
court now hands the mixer `engine.tasks()`, so its streams decode on the background pool.
`Sounds.frame` no longer calls `Mixer.update`; the host calls it, then `Music.update`, inside
one profiler scope, `audio`, which is criterion 4's measure.

**The evidence** (`FOUNDRY_COURT_MUSIC_LOG=on|off`, any other value refusing to start).
`Evidence.check` takes each start from `Music.starts`, waits for `Mixer.startedAt`, and counts
it:
- exact, or missed if it began on another frame;
- cancelled if it retired before it began, as a stop retires the track scheduled behind the
  one fading out. Nothing was heard late, so it is not a miss;
- lost if the sequencer's ring overwrote it before it was read.

The log has a line per start, and the counters every 600 frames (ten seconds at 60 Hz) and at
exit. A scripted run now also fails unless the music is clean: no start missed or lost, and
no underrun, late start or refused call.

**The ten-minute run is a fourth script, `soundtrack`.** `play.zig` gains a `wait` step (frames
of doing nothing, in any phase), and the win route is split at the ledge beacon. One pass:
- 30 s on the title, past its loop;
- play, and 15 s standing where the warden passes, so the music turns to the chase and back;
- the first beacon, and a 5 s pause;
- the other two beacons, then a minute far from the warden, long enough for the calm
  playlist to cross from one track to the next;
- the gate and a win;
- caught, then fell, each restarted;
- back to the title.

Five passes and Quit come to **40,553 frames, 11.3 minutes**. The cost collector's bound grew
from 4,096 frames to 65,536, so a run keeps every frame, and it moved to the heap.

**Found and fixed: a streamed sound's setup held a third more than it used.**
- Criterion 4's second half was measured in a court test, by counting what the mixer
  allocates for each track. The four tracks held **3.91 MB**, against 30.24 MB as 16-bit
  WAV: 7.7 times smaller, short of the 8.
- The files are 1.26 MB. The rest was each track's setup header: **662 KiB of arena for
  about 470 KiB of tables**. The arena's growth was the slack, plus the VQ multiplicands,
  which are needed only while the values are expanded.
- `vorbis.parseSetup` now parses the packet twice. The first pass, into scratch, measures
  what it asks for. The second fills one allocation of exactly that size, plus each
  allocation's worst-case alignment padding. The multiplicands go to scratch, freed when the
  parse ends.
- The second parse reads the same bits, so it asks for the same allocations in the same
  order, and decoding is unchanged: every decoder pin and fixture still passes.
- The tracks now hold **3.18 MB: 9.5 times smaller** than their WAV. The test holds it to the
  eighth.

**Tests.** Seven new court tests:
- in `music.zig`, each phase's playlist, an inert soundtrack, the chase hold, and what a clean
  run is;
- in `music_tests.zig`, against the real files on the stepped null device with immediate
  tasks:
  - the tracks stream within the eighth and the stingers stay resident;
  - the title's switch to calm lands on its bar and a beacon on its beat, with the evidence
    agreeing;
  - `nocturne` replaces the calm playlist (72 bpm, 3/4, its two tracks) and the beacon's
    sound, and plays them on its own 40,000-frame beat.

The build compiles `nocturne` against core and court, as it compiles `noon`, and installs it as
an optional package, never selected by default.

**Guards verified by mutation.** Each was broken, `court-test` run, and the file restored. Each
of these failed it:
- the chase hold ignored;
- an exact start counted as missed;
- underruns left out of a clean run;
- `playing` ignoring the chase;
- the setup buffer without its alignment padding;
- `stream true` removed from a track;
- `nocturne`'s stinger written as a new record instead of an override.

**Runtime evidence:** M5, SDL3 `cocoa`, Metal, ReleaseSafe, 4× MSAA and shadows.
- `zig build dist -Dapp=court` staged the bundle with all seven `.ogg` files (revision
  `a6ca12f+m30-step7`).
- Its zip was extracted into scratch and made read-only, then run with `PATH=/usr/bin:/bin`
  and a disposable preferences root. The 50 bundle files hash the same after the runs.

| Run | Frames | Starts asked / on their frame / cancelled / pending | Underruns, late starts, commands dropped, refused | `audio` median / p95 |
| --- | --- | --- | --- | --- |
| soundtrack 1 | 40,553 | 86 / 80 / 5 / 1 | 0, 0, 0, 0 | 0.0015 / 0.0033 ms |
| soundtrack 2 | 40,553 | 86 / 80 / 5 / 1 | 0, 0, 0, 0 | 0.0015 / 0.0041 ms |
| soundtrack 3 | 39,534 (interrupted) | 78 / 74 / 4 / 0 | 0, 0, 0, 0 | 0.0006 / 0.0025 ms |
| nocturne soundtrack | 40,553 | 86 / 80 / 5 / 1 | 0, 0, 0, 0 | 0.0006 / 0.0016 ms |

- **No start missed**, against criterion 3. The one pending at exit was asked within the
  second before Quit.
- `audio`'s p95 is about a twenty-fifth of the 0.10 ms budget.
- Every run played all 573 sounds it asked for and dropped no event or skinned draw.
  Its replay matched a fresh simulation at every tick.
- **The third run did not finish its script.** Losing the window's focus pauses the game
  (M26 Step 12), and a script stops at a pause it did not ask for, as interrupted.
  - The first attempt lost focus at tick 22,650, in its third pass. Its music was clean to
    that point: 44 asked, 42 exact, 2 cancelled.
  - The second lost it at tick 38,616, in the minute's wait of its fifth pass, after 11.0
    minutes.
  - Both happened while the window sat idle beside the ledge. What took the focus is not
    known from inside the run. Runs 1, 2 and `nocturne` never lost it.
  - Criteria 2–4 are measured over the run's time, and the second attempt's 39,534 frames
    are more than ten minutes, with nothing missed, underrun, late, dropped or refused.
  - What it did not reach is its last pass's endings, which runs 1, 2, `nocturne` and the
    scripted endings below cover.
- **Criterion 6:** `nocturne.fpk` and its music were copied into the user mod root and
  selected with `FOUNDRY_COURT_PACKAGES=nocturne:content`, then removed by exact path.
  - The calm tracks and the beacon's stinger that started were `nocturne`'s.
  - The title, chase, gate and ending were the court's.
- **Criterion 7:** the scripted endings are unchanged.
  - Base win: 1,219 frames, 73 of 73 sounds.
  - Caught: 110 frames, 5 of 5.
  - Fell: 186 frames, 10 of 10.
  - `nocturne` win: 1,215 frames, 73 of 73.
  - Each matched its replay and finished its menu-driven script, with music clean.
  - Frame work's p95 stayed under 1.1 ms in every run.
- The 2D samples' headless runs pass in the bar, unchanged.

**Listening.** The owner is offered a listening check, `FOUNDRY_COURT_PLAY` unset, from the
same bundle. It is not an exit criterion (§12).

**Bar.** `zig build test` passes 2,376 of 2,379, with the same three skips (M27's, the stream margin and command delivery). fmt, the four checks, the four thirty-frame
headless runs and `fdt-check` all exit 0. `dist -Dapp=court` stages.
