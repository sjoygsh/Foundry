# Design: audio — the device, the mixer, and sounds as content

**Status:** Fully implemented, steps 1-6, 2026-09-06. Written before any audio code existed,
so that implementation was transcription rather than invention; see the four Resolution
sections at the end for what it settled.
**Date:** 2026-09-05
**Implements:** I1, I2, I5, I6, I7, I8, I9 · **Informed by:** ADR-0002, ADR-0007, ADR-0013,
ADR-0018, ADR-0023

M5 asks for sound. ADR-0023 already decided *who writes it* — Foundry mixes its own audio and
decodes its own WAV — and named the three places it lands. This document works out the
interfaces, and it spends most of its length on the one thing that makes audio unlike every
other subsystem in Foundry so far:

> **There is a second thread, Foundry did not create it, and it has a deadline.**

Everything below is downstream of that sentence. The device calls us on a thread it owns, we
must fill a buffer before it drains the last one, and missing that deadline is an audible
click rather than a dropped frame. No allocation, no lock, no logging, no syscall, and no
error return anyone can act on. The design's job is to make the correct thing the *only*
thing a future session can easily write there.

---

## 1. What is already decided

**ADR-0023** fixed the decisions; this document does not reopen them.

* Foundry mixes its own audio. No third-party audio dependency.
* Foundry decodes its own WAV, in `asset`, beside PNG — for ADR-0018's reasons, arriving
  through the same untrusted door.
* `platform` owns the audio device, SDL3 stays confined to it, and **the null backend gets a
  stepped device** so the mixer is testable.
* A new `audio` module at **L3 → `core`, `platform`, `asset`**, owning the mixer, a fixed
  pool of handle-addressed voices, gain, pan and resampling.
* Samples are **`f32`, interleaved**, end to end.
* **Resampling happens in the voice, not at load.**
* The supported WAV subset is stated and everything outside it is refused *by name*.
* A single-producer, single-consumer ring carries commands to the callback. No locks.

**What already exists and is used unchanged:** `core.Handle`/`HandlePool` (I1), `data`'s
schema and record model, `asset.Registry` with its runtime-registered loaders (I6), and the
`render2d`/`asset` split that puts a schema low and the loader that consumes it high.

**One thing ADR-0023 left implicit that this document makes explicit:** the mixer opens the
device. See §7.

---

## 2. The three pieces, and the line between them

```
  platform            audio                      asset
  ────────            ─────                      ─────
  AudioDevice   <──   Mixer                      foundry:sound  (schema)
   open/close          voices, rings, mixing     Sound          (decoded samples)
   callback            playSound(ContentId)  ──> wav.decode
   (thread)                    │
                               └── registers the sound loader upward (I6)
```

The line between them is drawn where it already was for textures. `platform` knows what a
device is and nothing about sounds. `asset` knows what a `.wav` file is and nothing about
mixing — which is what lets `fpack` see the `foundry:sound` schema without linking a mixer,
the same argument `assets.md` made for `foundry:texture`. `audio` knows about both and is the
only module that does.

**`scene` does not appear in this diagram, and that is structural rather than tidy.** Both are
L3 and neither depends on the other, so a system *cannot* call the mixer even by accident.
Audio is driven by the game, from data systems wrote down — the identical shape that
`entity-storage.md` gave input. §8 is why that matters.

---

## 3. The device in `platform`

Four functions on the backend interface, checked by `interface.check` like every other:

```zig
pub const AudioError = error{
    OutOfMemory,
    /// No output device, or the OS declined to open one. Not a programmer error: a
    /// machine with no sound card is a configuration, not a bug.
    AudioUnavailable,
    /// The device exists but cannot produce anything Foundry can use.
    AudioFormatUnsupported,
    /// The handle does not name a live device — closed, or from before a reopen (I1).
    InvalidAudioDevice,
};

openAudio  : (*Platform, AudioConfig) AudioError!AudioDeviceHandle
closeAudio : (*Platform, AudioDeviceHandle) void
audioInfo  : (*Platform, AudioDeviceHandle) ?AudioInfo
setAudioPaused : (*Platform, AudioDeviceHandle, bool) void
```

**A handle, not a singleton**, even though there is exactly one output device in M5. Not
because we expect many: because an output device is *closed and reopened* in normal use — the
player unplugs headphones and the OS moves output elsewhere — and a stale handle surviving
that reopen is precisely the use-after-close a generation exists to refuse (I1). The window
precedent costs nothing to follow and the exception would need defending.

### The format, and what is negotiated

```zig
pub const AudioConfig = struct {
    sample_rate: u32 = 48_000,
    channels: u8 = 2,
    /// Frames per callback — the latency knob. 512 at 48 kHz is about 10.7 ms. A
    /// *request*; the device answers with what it will actually use.
    buffer_frames: u32 = 512,
    /// Called on a thread the device owns. See the rule below.
    callback: *const fn (ctx: ?*anyopaque, out: []f32) void,
    ctx: ?*anyopaque = null,
};

pub const AudioInfo = struct {
    sample_rate: u32,
    channels: u8,
    buffer_frames: u32,
};
```

**The device speaks `f32` interleaved, always, and that is not negotiated.** The backend is
responsible for making it true, converting if the hardware wants `s16`. A sample-format enum
in this interface would push a `switch` into the mixer's inner loop for a case that exists
only because a driver is old; both SDL3 and CoreAudio convert for free, and on a future
backend where it is not free it is one pass over a 512-frame buffer, internal to that backend.
One representation end to end is ADR-0023's decision and this is where it is enforced.

**Sample rate and channel count are negotiated**, request in and actual out, because those two
genuinely change what the mixer computes: the rate sets every voice's resampling ratio and the
channel count sets the pan model.

### The rule about the callback

Stated in the doc comment on `AudioConfig.callback`, where someone editing an implementation
will read it, and repeated in `audio`'s module comment:

> The callback runs on a thread Foundry did not create, under a deadline measured in
> milliseconds. Inside it: **no allocation, no lock, no logging, no filesystem, no
> `core.log`, no error return**. It fills `out` completely — silence is zeroes, never a
> short write.

There is no mechanism that enforces this, and pretending otherwise would be worse than saying
so. ADR-0023 named it as the cost we accept permanently. What the *design* can do is remove
every reason to reach for a forbidden thing: the ring means no lock, the fixed voice pool
means no allocation, and §5's error handling means nothing in there has anything to report.

### The null device is stepped, not threaded

```zig
// null backend only. Deliberately *not* on the interface.
pub fn stepAudio(self: *Platform, device: AudioDeviceHandle, frames: u32) void
```

It invokes the callback synchronously, on the caller's thread, with a buffer of exactly
`frames * channels` samples, and returns. A test pulls a known number of frames and gets the
same samples every run.

**Not on the interface**, because there is nothing sensible for the SDL3 backend to do with
it — the device thread is calling the callback and cannot be asked to do it again on demand.
A test that wants deterministic audio names `platform.null_backend` directly, exactly as
`app`'s loop tests already name it for the synthetic clock.

**What this does and does not prove** is worth being exact about, because a stepped device
looks like more of a guarantee than it is. It proves the mixer's arithmetic, the command
protocol's semantics, and the voice lifecycle. It does **not** exercise the ring under real
concurrency, because producer and consumer are the same thread. Concurrency correctness rests
on the ring being genuinely single-producer/single-consumer with the memory ordering §4 states,
which is established by review and by keeping it small — not by these tests.

---

## 4. The `audio` module: voices, and two rings

The mixer's state is split by *which thread owns it*, and every rule below follows from that
split rather than from taste.

```
Mixer
  ── owned by the game thread ─────────────────────────────────────────
  slots:      fixed table of { generation, state, sound, asset }   voice bookkeeping
  free_list:  slot indices available to claim
  sounds:     HandlePool(Sound)      decoded samples + a retirement flag
  to_audio:   Ring(Command)          producer end
  from_audio: Ring(Retired)          consumer end

  ── owned by the callback thread ─────────────────────────────────────
  voices:     fixed array of Voice   cursor, step, gains, source slice
  to_audio:   consumer end
  from_audio: producer end
```

No field is written by both. That is the whole concurrency design, and it is why no lock
appears anywhere in the module.

### A voice, and why the handle has a generation

```zig
pub const Voices = opaque {};
pub const VoiceHandle = core.Handle(Voices);
```

A `VoiceHandle` is `{ index, generation }` (I1), the index selects a slot in a fixed array
sized at initialisation, and the generation is the answer to the oldest bug in game audio:

> A game starts a footstep, keeps the handle, and 400 ms later calls `stop` on it. The
> footstep finished 300 ms ago and its slot was reused by the door that just opened. With a
> bare index, the door goes silent for no reason anyone can reproduce.

The generation makes that a no-op instead. The command carries the handle it was issued for;
a slot whose generation has moved on refuses it. This is the same reason `Entity` and
`AssetHandle` are generational, applied to the one subsystem where the recycling is fast
enough that a person will actually hit it.

### Commands go one way

```zig
const Command = union(enum) {
    play: Play,
    stop: struct { voice: VoiceHandle },
    stop_all,
    set_gain:  struct { voice: VoiceHandle, gain: f32 },
    set_pan:   struct { voice: VoiceHandle, pan: f32 },
    set_pitch: struct { voice: VoiceHandle, pitch: f32 },
    set_master_gain: struct { gain: f32 },
};

const Play = struct {
    voice: VoiceHandle,
    /// Borrowed. Alive for the voice's whole life — see the two rules below.
    samples: []const f32,
    channels: u8,
    sample_rate: u32,
    gain: f32,
    pan: f32,
    pitch: f32,
    looping: bool,
};
```

The ring is a fixed-capacity array with atomic head and tail indices, allocated at
initialisation. A full ring **drops the command and counts it** — it cannot block, it cannot
grow, and it cannot report to a caller who is on the other thread. The counter is readable
from the game thread and a non-zero value means the ring is too small or the game is issuing
commands faster than a callback period, both of which are the game's to fix.

### Retirements come back

A voice that reaches the end of a non-looping sound, or that is stopped, pushes
`Retired{ slot, generation }` into the second ring before it stops reading. The game thread
drains that ring in `update()` (§7), returns the slot to the free list, and only then may the
sound's samples be freed.

**The one memory-ordering requirement in Foundry**, stated here because it is invisible and a
future session will otherwise "simplify" it: the retirement push is a **release** store and
the drain is an **acquire** load, so that the callback thread's last read of the samples
happens-before the game thread's free of them. Nothing else in this module needs anything
beyond that, and if a second ordering argument ever appears, it is a sign the split above has
been broken.

### Why the ordering is what makes it correct

The generation check on the callback side is belt-and-braces. What actually makes stale
commands safe is that the ring is **FIFO with a single producer**, so commands arrive in the
order the game thread issued them, and the game thread cannot issue a `play` for generation
*n+1* until it has drained the retirement for generation *n*. A `stop` for a dead voice can
therefore only ever arrive *before* the `play` that recycles its slot, never after. Saying
this out loud is the difference between a design and a coincidence.

---

## 5. Mixing, concretely

Each callback, in this order:

1. **Drain the command ring**, applying each command to the voice array. Bounded work: one
   pass over whatever is queued.
2. **Zero the output buffer.**
3. **Mix every active voice, in slot index order** — stable, documented, and the reason two
   runs of the stepped device produce identical samples.
4. **Apply master gain**, then **clamp to `[-1, 1]`**.
5. **Push retirements** for voices that ended during this buffer.

**The clamp is not a limiter and does not pretend to be.** It is there because an `f32` sample
outside `[-1, 1]` converted to `s16` by a driver that does not clamp wraps, and wrapping is
the single worst sound a program can make. Twenty voices at full gain will clip; a real
limiter is named in §12 as not-here.

**Nothing in the callback can fail.** There is no allocation to fail, no file to be missing,
and no handle to be invalid that is not simply ignored. That is a design property, not an
optimism: every operation that *can* fail was moved to the game thread, which is what §7's
`play` is for.

### Gain and pan

Pan is `[-1, 1]`, and the mapping is **constant-power**: with `θ = (pan + 1) · π/4`, the left
gain is `cos θ` and the right is `sin θ`. Linear panning is one line shorter and dips about
3 dB in the centre, which is audible as a sound getting quieter as it crosses in front of the
player — the exact opposite of what panning is for.

The trigonometry runs **once per `set_pan` command**, not per sample; the voice stores the two
gains. Arithmetic is not what the callback rule forbids, and moving the conversion to the game
thread would put a policy decision on the wrong side of the interface.

Device channel count is 1 or 2. A mono source feeds both channels through the pan gains; a
stereo source has them applied as a balance. **More than two device channels is refused at
mixer initialisation**, by name, rather than silently mixed into the first two — surround is
§12, and a game shipping to a 5.1 setup deserves the sentence.

### Resampling in the voice

A voice holds a cursor in source frames and advances it by

```
step = (source_rate / device_rate) · pitch
```

per output frame, reading with linear interpolation between the two neighbouring source
frames. `pitch` is why this machinery is in the voice rather than at load: a sound played at
0.9× is the same operation as a 44.1 kHz sound on a 48 kHz device, and building it once serves
both (ADR-0023).

**The cursor is `f64`.** A three-minute sound is 8.6 million frames, far inside `f64`'s exact
integer range, with ample fractional precision left. A fixed-point cursor is the upgrade if
streaming ever makes lengths unbounded, and it changes nothing else.

**Linear interpolation is honestly adequate for effects and audible on a sustained tone.**
ADR-0023 said so; the note here is only that the interpolation is a single function and a
better kernel replaces it without touching anything above.

Looping wraps the cursor by the source length rather than resetting it to zero, so a loop
does not accumulate a fractional-frame error on every pass.

---

## 6. Sounds as content

### The schema

```
@schema foundry:sound {
    source: string
}
```

Version 1, `source` only — the same shape `foundry:texture` started with, and for the same
reason: fields are added when the thing that reads them exists, appended with defaults, and
old packages keep loading (I8). Loop points are the most likely second field and are named in
§11 rather than guessed at now.

It lives in `asset/schemas.zig` beside the texture schema, with `wav` in its extension table,
so a `.wav` file in a package derives a `foundry:sound` record with no authoring at all
(`assets.md` §3) and an author who wants to say more writes the record by hand.

**No sound content ships in `content/core`.** The engine hardcodes no content (I5), and the
same reasoning that keeps M5 from inventing a `foundry:collider` keeps it from inventing a
`foundry:sound.click`. The sandbox ships its own, as a game would.

### The decoded form

`asset/sound.zig`, beside `image.zig`, and the symmetry is the argument:

```zig
pub const Sound = struct {
    /// Interleaved `f32`, `frames * channels` long. The mixer reads this directly.
    samples: []f32,
    channels: u8,
    sample_rate: u32,

    pub fn frameCount(self: Sound) usize { return self.samples.len / self.channels; }
};
```

Every decoder expands to this one layout, exactly as every image decoder expands to 8-bit
RGBA — because the alternative is a format enum that the one consumer that matters must switch
on, in its hot loop, forever.

### WAV decoding, and the subset

`asset/wav.zig`, beside `png.zig`. RIFF container, `fmt ` chunk, `data` chunk, unknown chunks
skipped by their declared size after that size is checked against what remains.

| Accepted | Converted to `f32` by |
| --- | --- |
| PCM 8-bit unsigned | `(s - 128) / 128` |
| PCM 16-bit signed | `s / 32768` |
| PCM 24-bit signed | `s / 8388608` |
| PCM 32-bit signed | `s / 2147483648` |
| IEEE float 32-bit | unchanged |

`WAVE_FORMAT_EXTENSIBLE` is read by taking the tag from the first two bytes of its sub-format
GUID. **Everything else is refused with the format tag in the message** — ADPCM, µ-law and
A-law included — because a mod author deserves a sentence rather than a noise (ADR-0023).

Refused, each as untrusted input rather than an assertion: a truncated file, a chunk size that
runs past the end, zero channels or more than two, a zero or implausible sample rate, a bit
depth outside the table, a `data` length that is not a whole number of frames, and a declared
frame count above `Limits.max_frames` — checked **before** allocating, so a header claiming
four gigabytes costs nothing.

**A non-finite sample in a float WAV refuses the file.** This is the one place the decoder is
stricter than the texture path, which prefers a wrong-looking sprite to a missing one, and the
asymmetry is deliberate: a NaN entering the mixer propagates through the accumulator and makes
*everything* silent for the rest of the session, which is the least diagnosable failure
available. A refused file names its own path.

### The loader, registered upward

`audio` registers the `foundry:sound` loader into `asset.Registry` at startup, exactly as
`render2d` registers the texture loader (I6): the dependency points down, the capability
points up, and a mod adding an asset kind the engine has never heard of does the same thing.

The payload is a `SoundHandle` into a pool the mixer owns — **not** a pointer to the samples.
That indirection is what §7's hot-reload rule needs.

---

## 7. Lifetime: who guarantees the samples outlive the voice

A `Play` command hands the callback thread a borrowed slice. Two independent hazards can free
it underneath, and each gets its own answer.

**Hazard one: the game releases the asset while it is playing.** Answer: **the mixer holds the
asset reference for the voice's lifetime.** `play` acquires, the retirement drain releases.
The game cannot drop the last reference to something it can still hear.

**Hazard two: hot reload replaces the sound while it is playing.** `asset.Registry.reload`
calls the loader's `unload` at the top of a frame (`assets.md` §6), and the callback thread is
in the middle of the old samples. Answer: **the mixer keeps its own retirement**, exactly as
`render2d` keeps its own retirement queue rather than trusting the RHI's deferred destroy
(`render2d.md` §9). `unload` marks the `Sound` retired and returns; the samples are freed in a
later `update()`, once no voice references them — which the game thread knows, because a voice
only stops referencing a sound by pushing a retirement, and the acquire/release pair in §4 is
what makes that knowledge sound.

Two hazards, two mechanisms, and both are already the shape this codebase uses elsewhere.

### The game-thread API

```zig
pub fn MixerOf(comptime P: type) type { ... }
pub const Mixer = MixerOf(platform.Platform);

init(gpa, platform: *P, assets: *asset.Registry, options: Options) InitError!*Mixer
deinit(self) void

play(self, id: core.ContentId, params: PlayParams) PlayError!VoiceHandle
stop(self, voice: VoiceHandle) void
stopAll(self) void
setGain / setPan / setPitch (self, voice, f32) void
setMasterGain(self, f32) void
isPlaying(self, voice: VoiceHandle) bool
update(self) void
soundLoader(self) asset.Loader
```

**`update()` is called once per frame and the module says what happens if it is not:** voices
never return to the free list, retired sounds are never freed, and `play` starts failing with
`error.NoFreeVoice` after `voice_count` sounds. That is a loud, immediate failure rather than
a slow leak, which is the right way round.

**`play` is where everything that can fail, fails** — `NoFreeVoice`, `UnknownSound`,
`WrongAssetKind`, `OutOfMemory` from the acquire — precisely so that §5's callback has nothing
left to report.

**No voice stealing in M5.** `play` returns `error.NoFreeVoice` and the game decides. A game
firing 200 footsteps a second wants an oldest-or-quietest policy, and where that policy lives
is a real question (§11), not something to guess at while nothing has asked.

**`isPlaying` exists and its doc comment says it is for presentation.** §8 is why.

### The mixer opens the device

ADR-0023 left this implicit and it decides where `audio` sits in the lifecycle. The device
cannot be opened before a callback exists, and the callback is the mixer's, so **`Mixer.init`
opens the device and `deinit` closes it**. `audio` already depends on `platform`, so this
needs nothing new.

The consequence is the useful part: **`app` gains no dependency on `audio` at all.** The game
constructs the mixer, registers the sound loader, and calls `update()` — the same shape it
already has with `render2d`, where `app` owns the `rhi.Device` and the game owns the
`Renderer`. `app` stays short by design.

The rule this puts on the game is the one it already lives under for the renderer: **the mixer
is deinitialised before the engine**, because it holds a device the platform owns and a loader
the asset registry calls into.

---

## 8. Audio and I9

ADR-0013's promise is that the same binary, inputs and seed produce the same simulation. The
device thread's timing is genuinely nondeterministic and no design changes that. So audio sits
**outside** the promise, and the whole of this section is about keeping it from leaking in.

1. **Simulation may emit, never observe.** A system may cause a sound; nothing it does may
   depend on where a sound has got to. `isPlaying` is a presentation query and is documented
   as one.
2. **The structure enforces this, not the documentation.** `scene` and `audio` are both L3 and
   neither depends on the other, so a system physically cannot reach the mixer (I7). A game
   plays sounds from data its systems wrote down — the identical shape input already has.
3. **The mixer never reads a clock.** Voices advance by frames mixed, not by elapsed time.
   `platform` has a clock and the mixer never calls it.
4. **Voices mix in slot index order**, which is I9's "stable and documented iteration order"
   applied to the one loop here that has one.
5. **Given the same commands and the same buffer sizes, the mixer produces the same samples.**
   That is not a determinism promise about a running game — real buffer sizes are the device's
   business — but it is exactly what makes the stepped null device a real test rather than a
   smoke check.

---

## 9. Errors

Three sets, each at the boundary that owns it, and none of them crossing.

* **`platform`** — `AudioError` (§3). A machine with no output device is a configuration, so
  it is reported and a game may carry on in silence.
* **`asset`** — `SoundDecodeError{ InvalidSound, UnsupportedSound, SoundTooLarge, OutOfMemory }`,
  mapped by the loader to `asset.LoadError` exactly as the texture loader maps PNG's:
  `UnsupportedSound → error.UnsupportedVersion`, because a valid file we do not handle is a
  different sentence to an author than a corrupt one.
* **`audio`** — `InitError` and `PlayError` (§7). Both on the game thread. The callback has
  none, by construction.

---

## 10. What this exposes to mods

**Tier 1 works at M5, as a consequence of the content model rather than as a feature.** A mod
drops a `.wav` into its package and gets a `foundry:sound` record by derivation, or writes the
record by hand to point at its own file, or overrides an existing sound's `source` to replace
one the base game ships. No code, no new mechanism, and it works because the base game is
package zero (I3) and its sounds went through this same path.

**Tiers 2 and 3, at M7**, need a narrow surface, named now because adding a subsystem includes
deciding what it exposes (CLAUDE.md §5): play a sound by content ID and receive an opaque
voice handle; stop one; set gain, pan and pitch; set master gain. Nothing about devices,
buffers, threads or sample data crosses. The `VoiceHandle` is already `extern`-shaped and
already 64 bits, so it crosses the ABI as-is.

**Deliberately not exposed, ever:** the mix callback. A mod-supplied function running on the
device thread would put untrusted code inside the one context in Foundry where a mistake is
unrecoverable and undebuggable. If mod-authored DSP is ever wanted, it is a graph of
engine-implemented nodes a mod configures, not a function pointer.

---

## 11. Open questions

Named rather than resolved, per the standing rule that implementation must not settle these
opportunistically.

1. **Voice stealing policy, and where it lives.** Oldest, quietest, or by a priority the game
   supplies — and whether the mixer owns it or hands `NoFreeVoice` back forever. Due when
   something actually exhausts the pool.
2. **Buses or categories.** A music slider and an effects slider is the second thing every
   game wants. A gain per named category is a few lines; a real bus graph is a subsystem. Due
   the first time the sandbox wants two sliders.
3. **Streaming.** ADR-0023 designed the voice model so that a voice pulling from a decoder
   rather than a buffer is not a redesign, and M5 does not build it. Due with music, which is
   also when WAV's size becomes the problem ADR-0023 said it would.
4. **Device change and enumeration.** Today an unplugged headphone is whatever SDL3 does about
   it. Owed when someone unplugs something and the answer is unsatisfying; `platform`'s
   interface has room for a device-changed event beside the window events.
5. **Whether `foundry:sound` grows fields.** Loop points are the interesting candidate and
   would be additive (I8). Not invented before something asks.

---

## 12. Deliberately not here

* **Spatialisation.** Panning is in scope; a 3D audio model is not, and arrives with 3D if at
  all (ADR-0023).
* **Effects** — reverb, filters, delay — and a real **limiter or compressor**. §5's clamp is a
  safety net, not a mix bus.
* **Compressed formats.** ADR-0023's first revisit trigger, with its own decision to make
  about writing a decoder versus taking a narrow permissive one.
* **Music sequencing** — playlists, crossfades, stingers. Game policy built on `play` and
  `setGain`, not engine mechanism.
* **Audio capture.** No microphone, no input device. Nothing here precludes one.
* **A mod-supplied callback.** §10.

---

## 13. Implementation order

Each step leaves the suite green, and the first three add no threads at all.

1. **`foundry:sound`, `Sound` and the WAV decoder in `asset`** — schema, extension table,
   `asset/sound.zig`, `asset/wav.zig`. Pure, hermetic and testable with no device and no
   module: a hand-built minimal file per accepted sample format, plus malformed ones asserting
   refusal by name, exactly as the PNG corpus is built.
2. **The audio device in `platform`** — the interface entries, the `comptime` check, the
   stepped null device, then SDL3. Tested through the null device by asserting the callback is
   invoked with the buffer it was promised.
3. **`audio` in the build graph**, at L3 on `core`, `platform` and `asset`, with the layering
   confirmed by *breaking* it — an import of `render2d` must fail the build, and Zig's lazy
   analysis means proving it requires referencing the illegal import.
4. **The rings, the voice table and the mixer**, driven by the stepped null device: silence
   with no voices; one voice at device rate reproducing its samples exactly; gain scaling;
   constant-power pan; a 2:1 resample; a loop wrapping without drift; a voice retiring and its
   slot being reclaimed; and a stale handle's `stop` leaving the voice that took its slot
   alone.
5. **The loader registered upward, and `play(ContentId)`** — including the two lifetime rules
   of §7, with a test that reloads a sound while a voice is playing it.
6. **The sandbox makes a sound**, from its own content package, which is M5's rule for every
   piece of this milestone.

Collision is a separate document and a separate sequence. Neither blocks the other, and the
only thing they share is the frame that calls both.

---

## Resolution: sounds as content (step 1, 2026-09-06)

*What implementing §6 settled. `foundry:sound` in `asset/schemas.zig`, `Sound` in
`asset/sound.zig`, the decoder in `asset/wav.zig`, with 16 tests, plus one in `fpack`.*

**No changes to §6, and one addition to `fpack`: none.** A `.wav` becomes a
`foundry:sound` by path with no code at all, because `fpack` already walks the extension
table rather than knowing about PNG. That is what the table was for, and this is the first
time anything proved it.

**Two refusals the document's list did not have.**

* **The format is asked before the bit depth.** §6's table is keyed by depth, which reads
  as though depth is checked first. It cannot be: four bits per sample is nonsense for PCM
  and correct for IMA ADPCM, so a decoder that checks depth first tells an author their
  file is corrupt when it is merely compressed. Format, then channels, then rate, then
  depth — each refusal naming the thing that is actually wrong.
* **A sound with no frames is refused.** Not in §6's list, and added because a looping
  voice wraps its cursor by the source length: admitting a zero-frame sound would put a
  division by zero in the one place that must never branch on a special case. A `data`
  chunk of length zero is a broken export in every case anyone has met.

**`nAvgBytesPerSec` and `nBlockAlign` are read by nothing.** Both are derivable from the
rest, both are wrong in a great many real files, and refusing over a redundant field would
refuse sounds that decode perfectly. The same reasoning applies one level up to the `RIFF`
chunk's own size, which is not trusted for bounds: every sub-chunk is separately checked
against the buffer, which is the bound that is actually true.

**A final odd-sized chunk may omit its pad byte.** The format says chunks are padded to an
even length; enough writers skip the last one that refusing them would be refusing real
files. A pad that would run past the end ends the walk instead of failing it.

**The frame limit is proved to precede the allocation, not asserted to.** The test decodes
with an allocator that fails on its first request and expects `SoundTooLarge` rather than
`OutOfMemory`. That is the difference between the bound working and the bound being
written down.

---

## Resolution: the device (step 2, 2026-09-06)

*What implementing §3 settled. `platform/audio.zig`, four entries on the backend
interface, the stepped null device, and the SDL3 backend, with 8 tests.*

**§3's four functions are exactly the four**, and the `comptime` check earned its keep
immediately: adding them broke the SDL3 backend with a compile error naming the missing
function, which is what that check exists to do.

**A device opens running.** §3 did not say, and the alternative is worse in a way that is
hard to notice: SDL's streams start paused, and a backend that left it that way would be an
engine that ships with no sound until somebody investigates. `setAudioPaused` is for a game
that wants silence, not a step every backend has to remember.

**The SDL3 backend adopts the device's own sample rate rather than the requested one.**
§3 said the rate is negotiated without saying which way it resolves. Foundry's voices
already resample — that machinery exists for pitch and cannot be turned off (ADR-0023) — so
taking the hardware rate costs nothing and removes SDL's resampler from the path entirely.
The channel count goes the other way: the request wins, and SDL maps two channels onto
whatever the hardware has, because a mixer that had to know about 5.1 in order to be heard
on a 5.1 machine would be a worse trade than one that never learns.

**Foundry's callback always receives the block size it was promised.** SDL asks for a
number of bytes that need not match, and the backend fills whole blocks into the stream's
queue until the request is covered. Overshoot is not waste — it is what the next callback
does not have to ask for — and it buys the mixer a block size that never changes, which
§8's determinism claim leans on.

**`stepAudio` returns the buffer it filled**, where §3 wrote `void`. It is a test
affordance rather than interface, so this is not an architectural change; returning the
samples is what lets a mixer test assert on what was produced without a recording shim in
between, and every step-4 test uses it that way. A paused stepped device writes silence and
does not call the callback, which is what a paused device does and what lets a test tell
"the mixer produced nothing" apart from "the device was not running".

**The real device was verified once, by hand, and not by a unit test.** A test that opened
an output device would fail on a machine that has none, which is precisely the
configuration §9 says must keep working. A temporary probe reported 48000 Hz, 2 channels,
a 512-frame buffer, 36 callbacks in 400 ms at exactly 1024 samples each, pausing stopping
them, resuming restarting them, and closing stopping them for good.

---

## Resolution: the rings, voices and the mixer (steps 3-4, 2026-09-06)

*What implementing §4 and §5 settled. `audio/ring.zig`, `audio/voice.zig` and
`audio/mixer.zig`, with 32 tests through the stepped null device.*

**The layering claim was checked by breaking it.** Adding `@import("render2d")` to the
module and *referencing* it fails the build with "no module named 'render2d' available
within module 'root'". The reference is the load-bearing part: Zig analyses lazily, and an
illegal import nothing uses compiles clean.

**Three things §4 did not decide, all forced by the first implementation.**

* **A dropped `play` returns an error; every other dropped command is only counted.** §4
  said a full ring drops and counts, which is right for a `set_gain` and catastrophic for a
  `play`: the game thread has already claimed a slot, and a `play` that vanished would
  strand it forever, because the retirement that frees it can only come from a voice that
  actually started. So `play` undoes its claim and returns `CommandQueueFull`, which is a
  fourth member of `PlayError` the document did not have.
* **The retirement ring is sized to the voice count**, which makes dropping a retirement
  structurally impossible rather than merely unlikely. A voice retires at most once and
  cannot play again until `update` returns its slot, so at most `voices` retirements can
  ever be outstanding. The push therefore asserts rather than ignoring its result: the
  impossible case says so instead of vanishing into a stranded slot.
* **A one-shot ends in the buffer it runs out in**, not the one after. Checking the cursor
  before writing a frame is the obvious loop and holds a finished slot for an extra
  callback; checking after advancing costs nothing and makes the lifetime rule sayable —
  "the voice ended during this buffer" — which is the sentence §5 step 5 already used.

**Pan is ignored on a mono device**, where §5 says a mono source feeds both channels
through the pan gains. Applying constant-power gains and then summing to one channel makes
a centred sound 3 dB quieter than a hard-panned one, which is a strange thing for panning
to do to a listener who has one speaker. The device's channel count is fixed for the
mixer's life, so this is one branch outside the per-frame loop, not inside it.

**Pitch is clamped to [1/64, 64].** §5 did not bound it, and zero would make a voice
immortal while a negative one would read backwards — neither being a thing to discover from
a sound that will not stop.

**`init` opens the device last and gates the callback on a flag.** The device may call back
the instant it is opened, and `AudioInfo` is not known until after that call returns, so
there is a window in which the callback would read a half-built mixer. An acquire/release
`ready` flag closes it, and the callback writes silence until it is set — which also means
a mixer that fails the channel-count check leaves a device writing zeroes rather than
reading a partly-torn-down object.

**The threads were run against each other once**, in `ring.zig`: a producer and a consumer
on two real threads passing 100,000 values, checked in order with none missing and none
duplicated. §3 is right that this is not proof of the memory ordering. It is the difference
between reasoning that was reviewed and reasoning nobody ran.

---

## Resolution: content, and the sandbox (steps 5-6, 2026-09-06)

*What implementing §6, §7 and §10 settled. `soundLoader` and `play(ContentId)` in
`audio/mixer.zig`, `engine/tests/sound_pipeline.zig` with 6 tests, and the wiring plus
three generated `.wav`s in `samples/sandbox/`.*

**`play` keeps the registry's own error set rather than flattening it.** §7 named four
failures and one of them was `WrongAssetKind`; what the registry already distinguishes is
richer — a record that is missing, a record that is the wrong type, a `source` that is not
there, and a `source` a package is not allowed to name — and each sends an author somewhere
different. `PlayError` is therefore `VoiceError || asset.AcquireError`, and the acquire is
`acquireOf`, so a sound that turned out to be a texture is refused where the id was written
rather than where the payload is cast.

**`Mixer.shutdown` is new, and teardown is why.** §7 says the mixer is deinitialised before
the engine; what implementation found is that two requirements want opposite orders. The
registry unloads through a loader that borrows the mixer, so the loader has to go before
`deinit` — the same rule `render2d.textureLoader` already documents. But the mixer holds an
asset reference per playing voice, so those have to come back *before* the loader goes, or
the registry rightly reports that something is still holding an asset it is unloading. The
answer is a third call between them: `shutdown` closes the device — which is what makes the
release safe, since no callback can be reading afterwards — and hands the references back.
`deinit` deliberately does **not** call it: `deinit` has to stay safe after the registry has
already gone, and handing a reference back to a freed registry would be the worst available
way to end a program.

**The two hazards are tested by doing them, in an integration test, because nothing else
can.** Hazard one releases the asset around the mixer's back and evicts, and the sound is
still audible. Hazard two saves a quieter take over a playing loop and watches two sounds
live at once — the old one still playing, the new one waiting for the next voice — until
the voice holding the old one stops. `testing.allocator` is half of each assertion: an
early free is a use-after-free on the device thread, a late one is a leak, and it fails on
both.

**The sample's three sounds each exercise something different**, which is what a sample is
for: the footstep is 22050 Hz so the voice resamples on the real path, the thud is at the
device's own rate so the same path runs with no resampling at all, and the ambience
completes a whole number of cycles inside its half second so the loop wraps silently.
None of them has a record: a `.wav` becomes a `foundry:sound` from its path, so the
settings record naming three ids is the only place the sample mentions them.

**A headless build does not emit one-shots.** Its device never runs, so a command queued
there sits in the ring until it fills and every one after it is refused — the mixer
behaving exactly correctly and the sample asking for something pointless. The ambience
still starts, so a headless run still decodes a `.wav` through the real path.

**§10's Tier 1 claim was checked rather than asserted.** A package declaring
`foundry:sound sandbox:sounds.hum { source "drone.wav" }` replaced a sound the sandbox
never wrote a record for, from a file under a directory layout of the mod's own choosing,
at a sample rate neither the device nor the original uses — with nothing rebuilt but the
mod.

**Open questions 1 through 5 are all still open**, and step 6 was written to keep them
that way: the sample names three sound ids and no gains, because a per-sound gain field
would have answered question 2 by accident.
