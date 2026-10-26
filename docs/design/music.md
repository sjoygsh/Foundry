# Design: M30 — Audio II: compressed audio, streamed music and music sequencing

**Status:** Proposed 2026-10-26; awaiting the owner's acceptance of §14. No step has begun.
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
