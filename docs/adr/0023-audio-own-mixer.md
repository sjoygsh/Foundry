# ADR-0023: Foundry's own mixer, and its own WAV decoding

**Status:** Accepted
**Date:** 2026-09-05

## Context

`CLAUDE.md` §9 scheduled "audio: own mixer vs. library" for M5 with one note — *SDL3 gives the
device either way* — and §4.3 already charters `platform` with the audio device alongside the
window, the clock and the filesystem. So the device is not the question. The question is who
owns the ~200 lines per frame that turn a set of playing sounds into a buffer of samples, and
who owns turning a file on disk into samples in the first place.

Three things constrain the answer.

**The mix callback is a real-time context.** It runs on a device-owned thread, it must produce
a buffer before the device drains the last one, and missing that deadline is audible as a click
rather than as a dropped frame. Inside it there is no allocation, no lock, no logging, no
error return that anyone can act on. This discipline is the same whether we write the mixer or
call one, but it determines the *shape* of everything around it.

**Audio must not become an I9 hazard.** The device thread's timing is genuinely
nondeterministic, and nothing about ADR-0013 can change that. So audio has to sit outside the
simulation's determinism promise without leaking into it: simulation may emit "play this", and
must never read back "where is that sound now" and let the answer change what it does.

**ADR-0018 is directly on point.** Foundry already decodes its own PNG rather than taking a
battle-tested C decoder, on the grounds that mod-supplied files travel that path, that Zig's
bounds checking makes the untrusted path memory-safe by construction, and that we get a type
shaped the way the engine wants. An audio file is the same kind of input arriving through the
same kind of door.

## Decision

**Foundry mixes its own audio and decodes its own WAV.** No third-party audio dependency.

Three pieces, in three places that already exist for the reasons that put them there:

**1. `platform` gains an audio device.** Open with a desired format, receive the format the
device actually gave, fill buffers from a callback, close. SDL3 is confined here as it always
has been (ADR-0002), and no SDL type appears in the interface. **The null backend gets a device
too** — a silent one that is *stepped explicitly* rather than driven by a thread, so the mixer
can be pulled a known number of frames in a test and produce the same samples every time. That
is the same role the null RHI backend plays, for the same reason: the untestable part of a
subsystem is the part that rots.

**2. A new `audio` module at L3, depending on `core`, `platform` and `asset`.** It owns the
mixer, a fixed pool of voices allocated at initialisation and addressed by handle (I1), gain
and pan, resampling, and playback by content ID. The game thread never touches mixer state
directly: it publishes commands — play, stop, set gain — through a single-producer,
single-consumer ring that the callback drains. That is the entire concurrency design, it is
stated here because it is load-bearing, and it is why no lock appears anywhere in the module.

**3. WAV decoding lives in `asset`, beside PNG**, and the `foundry:sound` schema lives there
too — the same placement `assets.md` argued for textures, so that a content compiler can see
the schema without linking an audio mixer. The **loader is registered upward from `audio`**,
exactly as `render2d` registers the texture loader (I6): the dependency points down while the
capability points up.

The supported subset is stated and everything outside it is refused by name, not approximated:

* Uncompressed PCM: 8-bit unsigned, 16/24/32-bit signed integer, and 32-bit IEEE float.
* One or two channels.
* Compressed WAV — ADPCM, µ-law, A-law — is **refused**, with the format tag named in the
  error, because a mod author deserves a sentence rather than a noise.

Two format decisions inside the mixer:

* **Samples are `f32`, interleaved**, from decode through mixing to the device. One
  representation end to end; the conversion happens once, at load.
* **Resampling happens in the voice, not at load.** A sound is kept at its authored rate. The
  alternative — resample everything to the device rate when it loads — is simpler and was
  rejected for two concrete reasons: a device format change (the user moves to a different
  output) would otherwise invalidate every loaded sound, and pitch variation needs exactly the
  same machinery anyway, so building it once in the voice costs nothing extra. Linear
  interpolation first, which is honestly stated as adequate for effects and audible on a
  sustained tone; a better kernel is a self-contained upgrade.

## Consequences

* **No dependency**: nothing in `THIRD_PARTY_LICENSES/`, nothing to re-verify when the pinned
  toolchain moves, no C in the path a mod's `.wav` travels.
* **`platform` keeps its charter intact.** SDL3 does not escape it, which `CLAUDE.md` §10 lists
  as non-negotiable, and the audio API games and mods eventually see is one Foundry designed.
* **The mixer is testable headlessly and deterministically** through the stepped null device —
  a property none of the library options offer, and the reason audio can have real tests rather
  than a listening check.
* **Cost: WAV only, so music is large.** A three-minute track at 44.1 kHz stereo 16-bit is
  about 30 MB. This is genuinely painful the first time a game ships with a soundtrack, and it
  is the accepted cost, deferred exactly the way ADR-0018 deferred JPEG. The revisit trigger
  below is specific rather than aspirational.
* **Cost: we own resampling quality and real-time discipline, permanently.** The second is the
  one that bites later: an allocation or a log call added to the callback by a future session
  is a bug that only manifests as an occasional click, and no test catches it. The rule is
  written in the module's doc comment where someone editing it will read it.
* **Cost: no spatialisation, no effects, no streaming, no submixes on day one.** Streaming
  matters as soon as music does and is the first likely addition; the voice model is designed
  so a voice pulling from a decoder rather than a buffer is not a redesign.
* We own the correctness of a `.wav` parser against hostile input. Paid the way PNG was: a
  corpus of hand-built minimal files per sample format, plus deliberately malformed ones
  asserting refusal rather than tolerance.

## Alternatives considered

* **SDL3_mixer (zlib).** Least code by a wide margin, permissively licensed, same family as
  the platform backend. Rejected on the architecture rather than the library: it would leak SDL
  past `platform`, which `CLAUDE.md` §10 forbids; it brings its own device management,
  duplicating the charter §4.3 already gave `platform`; and its chunk/music/channel model would
  quietly become the shape of Foundry's audio API — an abstraction we would not own, at one of
  the boundaries games and mods actually see. It also pulls in codec libraries for formats we
  did not ask for, each with its own license entry.
* **miniaudio (MIT / public domain).** Genuinely excellent, single-file, no build tooling
  needed, and the technically strongest option on its merits. Rejected because it is device +
  decode + mix + spatialisation as one stack: adopting it displaces `platform`'s audio charter
  entirely and leaves SDL3 and miniaudio arguing over who owns the output device. Taking only
  its mixer and giving it SDL3's device is possible but is the worst version of the trade —
  a dependency carried in full, used in part, integrated against its grain.
* **Own mixer, third-party decoders (`dr_wav`, `stb_vorbis`).** Splits the difference: we keep
  the architecture and buy the file parsing. Rejected for WAV because a PCM WAV parser is a few
  hundred lines and this is precisely development rule 3 — a dependency is not worth a small
  amount of code. It remains the *most likely* shape of a future decision about Vorbis or Opus,
  where the code is genuinely hard, and nothing here forecloses it.
* **Defer audio past M5.** The milestone's exit criterion — five minutes without noticing it is
  a tech demo — is not reachable in silence. Rejected on that alone.

## Revisit if

* **Music size becomes a real problem** — the first game ships a soundtrack, or a download
  crosses a size a player would notice. Then the question is a compressed format, and it is
  specifically the question of writing an Opus or Vorbis decoder versus taking a narrowly
  scoped permissive one, with the mixer and the voice model unchanged either way.
* **Streaming is needed before that**, for long ambient tracks that should not be resident.
  This is an addition to the voice model, not a reopening of this decision.
* **Profiling shows mixing is a measurable cost** at the voice counts a real game uses.
  Deinterleaved buffers and SIMD are the answer, and both are internal to the module.
* **The device abstraction proves wrong on a second platform.** The interface here is designed
  against SDL3 and the null backend only; a future backend may reveal an assumption, exactly as
  ADR-0003 expects a second graphics backend to.
* **Spatial audio becomes a requirement.** Panning is in scope; a real 3D audio model is not,
  and arrives with Phase 4 if it arrives at all.
