# ADR-0065: Foundry decodes its own Ogg Vorbis

**Status:** Accepted 2026-10-26 (the owner asked for M30 Step 1; `docs/design/music.md`); being implemented in M30
**Date:** 2026-10-26

## Context

ADR-0023 chose WAV only and named the cost: a three-minute track is about 30 MB. Its first
revisit trigger was "music size becomes a real problem", and it framed the question as
"writing an Opus or Vorbis decoder versus taking a narrowly scoped permissive one, with the
mixer and the voice model unchanged either way". The roadmap's M30 line ("compressed audio and
streamed music; the decoder is an ADR") fires the trigger. This ADR is the answer.

Three facts constrain it:
- **The file is untrusted.** Mods ship sounds, and a sound travels the same door a PNG does.
  ADR-0018 kept image decoding in Zig for that reason. In the ReleaseSafe builds Foundry
  ships, a bad index there is a checked panic, not memory corruption.
- **The format must be one authors can export.** A sound comes from Audacity, a DAW or a
  sound library, not from Foundry's tools, so the format must be one those tools write.
- **Tests need a reference.** A lossy decoder is correct when it agrees with the reference
  implementation within float tolerance, and the machine has no encoder.

## Decision

**Foundry decodes Ogg Vorbis itself, in Zig, in `asset`, beside WAV.** It has no codec
dependency.

1. **The container** is `asset/ogg.zig`. It reads one logical stream, checks every page's CRC,
   and takes the length from the final granule before allocating.
2. **The codec** is `asset/vorbis.zig`, a Vorbis I decoder: floor type 1, residue types 0–2,
   and coupling. It produces the same `f32` interleaved `Sound` WAV does, or frames into a
   caller's buffer for a stream (ADR-0066).
3. **The subset is stated, and everything else is refused by name:**
   - a second logical stream (chained or multiplexed);
   - a bad CRC;
   - more than two channels;
   - a rate above 192 kHz;
   - floor type 0, which libvorbis has not written since before 1.0;
   - another codec in Ogg, named where recognisable (Opus, FLAC, Speex, Theora);
   - any index past its count;
   - a non-finite decoded sample.
4. **Its trig is written out** (`core.math.trig`, moved from `particles`), so a decoded file is
   the same bytes in every optimization mode of one binary.
5. **The reference is a developer tool, never a dependency.** A small C program against
   libvorbis 1.3.7 and libogg 1.3.5 (BSD-3-Clause) is built by `zig cc` in a scratch directory
   from release tarballs whose SHA-256 values `AGENTS.md` records. It encodes the test
   fixtures and the samples' music, and decodes the reference outputs the tests compare
   against. The build never runs it, and nothing of it links or ships. The committed files are
   its output, not its code. So, as with RenderDoc, no `THIRD_PARTY_LICENSES/` entry is owed,
   and adding the tool is recorded here rather than as a build tool.

## Consequences

- **Music is about eleven times smaller** than 16-bit WAV at quality 4. The court's 150 s
  soundtrack is about 3 MB instead of about 27 MB.
- **No C sits in the path a mod's file travels.** A malformed Vorbis file is a named refusal
  or a checked panic in tests, and the mutation sweep is how that claim is tested
  (`music.md` §12).
- **Cost: about 3,000 lines of decoder that Foundry owns.** Its correctness is measured
  against libvorbis on fixtures that span the encoder's configurations, so a regression shows
  as a tolerance failure or a changed hash.
- **Cost: decoding speed is ours.** A bounds-checked decoder is slower than `stb_vorbis` built
  with optimizations. M30's bound, at least 50× real time on the slowest machine, keeps one
  stream to about 2% of one pool thread.
- **Cost: floor 0 and chained files are refused.** A rare old file gets a sentence telling
  its author to re-export it.
- **Fixtures depend on a C tool that is not in the build.** Regenerating them needs
  `zig cc` and the two pinned tarballs, and nothing else. The tarballs come from Xiph's
  download server, and if that ever moves, the hashes still identify them.

## Alternatives considered

- **`stb_vorbis` (public domain or MIT).** One file, fast and widely used. Rejected because
  fuzzing has found memory-safety bugs in it repeatedly (a batch of CVEs in 2019, more since).
  That is untrusted input through C, which is the trade ADR-0018 declined for images.
- **libvorbis and libogg as linked dependencies (BSD-3).** The reference itself. Rejected for
  the same reason, with more code: two libraries and an allocator model of their own, in the
  path of every mod's music. It remains the tests' oracle.
- **Opus, our own or libopus (BSD-3).** A better codec at low bitrates, and macOS's
  `afconvert` writes it. Rejected for M30:
  - its decoder is SILK, CELT and a hybrid of both, several times the size of Vorbis's;
  - libopus would be C on the untrusted path;
  - Vorbis at quality 4 already meets the size problem ADR-0023 named.
- **MP3 (patents expired; `minimp3` is CC0).** Rejected: lower quality at the same size, a
  decoder of similar complexity to Vorbis's, and nothing it does better.
- **FLAC (our own, about 1,000 lines).** Lossless and simple. Rejected as the answer because it
  only halves the size, and ADR-0023's problem is a factor of ten.
- **QOA ("Quite OK Audio", MIT, about 400 lines), with `fpack` compressing WAV at build time.**
  Tiny and easy to own. Rejected for two reasons: no authoring tool exports it, so a mod
  author's `.ogg` would still be refused; and at about 280 kbps it is roughly twice Vorbis's
  size.

## Revisit if

- **A game needs quality at bitrates Vorbis does poorly at**, such as voice-heavy content under
  64 kbps. Opus is then the question, decided as this was: our own decoder against a
  library, with the untrusted-input argument weighed again.
- **The mutation sweep or a real file finds a crash** that the bounds checks do not turn into
  a refusal. The decoder's structure is then wrong, not just a line.
- **Decoding stops meeting 50× real time** on a supported machine, or a game needs more
  simultaneous streams than one pool thread covers. SIMD in the MDCT and the residue loop is
  the first answer, and it is internal to `asset`.
- **Authors report Vorbis files the subset refuses** (floor 0, chained exports) often enough to
  matter.
