# ADR-0018: Foundry decodes its own images; no third-party image library

**Status:** Accepted (implementation begins in M2)
**Date:** 2026-09-04

## Context

M2 requires loading textures from disk, which means decoding PNG. Three routes exist, and
all three are permissible under ADR-0016's permissive-only licence policy, so the choice is
made on other grounds.

The decisive ground is **who sends us the bytes**. Images are content. Content comes from
mods (§5, I3), and CLAUDE.md is unambiguous that "all input from the other side is
untrusted: validated, never asserted." An image decoder is therefore not a convenience in a
trusted tool — it is one of the first pieces of Foundry that a stranger's file reaches
directly. Image decoders are historically the single richest source of memory-safety
vulnerabilities in game and application software, precisely because they parse
attacker-controlled, length-prefixed, compressed binary.

Two facts about the Zig standard library change the size of this decision, and both were
verified against the pinned 0.16.0 toolchain rather than assumed:

* `std.compress.flate.Decompress` handles the `zlib` container, including its checksum. PNG
  data is zlib-wrapped DEFLATE, so **no inflate implementation is needed.**
* `std.hash.Crc32` is CRC-32/ISO-HDLC, which is exactly PNG's chunk checksum.

What remains is the PNG layer itself: signature, chunk walk, `IHDR` validation, palette and
transparency, bit-depth expansion, and the five row filters. That is a few hundred lines of
straightforward, table-free code with a well-specified format behind it.

## Decision

**Foundry decodes PNG itself, in Zig, in `asset`.** No third-party image dependency.

The supported subset is stated, and everything outside it is **refused with an error**, not
approximated:

* Bit depth 8. Colour types 0 (greyscale), 2 (RGB), 3 (palette), 4 (greyscale+alpha) and 6
  (RGBA), plus `tRNS` transparency for types 0, 2 and 3.
* Non-interlaced only. Adam7 is refused.
* 16-bit channels are refused.

All output is expanded to 8-bit RGBA. Refusal is a normal, logged, recoverable outcome:
`error.UnsupportedImage` names what was unsupported, so a mod author gets a sentence rather
than a black texture.

Decoding validates before it allocates: dimensions are checked against a configured maximum
and against `rhi` device capabilities before any buffer is sized from file-supplied numbers,
because "allocate what the header claims" is how decoders are made to exhaust memory.

## Consequences

* **The untrusted path is memory-safe by construction.** Zig's bounds checking covers every
  index in the decoder, and a malformed file produces an error rather than undefined
  behaviour. This is the entire point.
* No dependency, no `THIRD_PARTY_LICENSES/` entry, nothing to track across a toolchain
  upgrade, and nothing that can be abandoned upstream.
* We get an `Image` type shaped the way the engine wants it, rather than adapting one shaped
  the way a general-purpose library wants it.
* **Cost: we own the correctness.** This is paid with a test corpus rather than with
  confidence — hand-built minimal PNGs for each colour type and filter, plus deliberately
  malformed files asserting that each is *refused* rather than tolerated. Those tests are
  part of M2, not a follow-up.
* **Cost: PNG only.** No JPEG, no WebP. For 2D sprite art this is not a real limitation —
  lossy compression on sprite sheets is a mistake anyway — but it becomes one the day large
  photographic textures matter.
* The subset means some real-world PNGs are refused, notably 16-bit and interlaced files.
  The content pipeline (M3) is the right place to transcode them at build time, and refusing
  them clearly is better than silently mangling them.

## Alternatives considered

* **`stb_image.h`, compiled by `build.zig`.** Public domain, battle-tested, one header, and
  the build already compiles C and Objective-C so it would cost nothing to add. Rejected
  because it places C with a documented CVE history directly in the path that mod-supplied
  files travel, and because it decodes a dozen formats we do not want in order to give us the
  one we do. The Metal shim is C in the trusted path by necessity (ADR-0012); this would be C
  in the untrusted path by choice.
* **`zigimg`.** Pure Zig, MIT, many formats, no C. Rejected as the weakest form of the
  dependency trade here: it is a pre-1.0 package tracking a pre-1.0 language, so it adds a
  second thing that can break when the pinned toolchain moves between milestones. ADR-0001
  accepts that churn once, deliberately, and concentrates it behind `core`; taking it on
  again for a few hundred lines of code is a bad trade.
* **Ship raw or uncompressed textures and skip PNG entirely.** Simplest possible, and
  tempting because M3's compiled content format will want its own texture representation
  anyway. Rejected because mod authors have PNGs, not our format, and Tier 1 content modding
  must work with the files people actually have (§5).

## Revisit if

A format we cannot reasonably write ourselves becomes genuinely required — JPEG or WebP for
large photographic content — or if the decoder's defect rate ever suggests that a widely
audited implementation would be safer than ours despite the language advantage.
