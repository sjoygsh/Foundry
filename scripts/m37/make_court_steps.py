#!/usr/bin/env python3
"""Generate the court's M37 footsteps on stone (`docs/design/collision-extras.md` §12).

Foundry's own content, under the repository's licence. The court's paving keeps M26's
step.wav, land.wav and warden_step.wav, written by `scripts/m26/make_court.py`; this script
writes only the stone's three, so none of M26's bytes can move. Stone is the harder surface:
the same filtered-noise burst as M26's, brighter and shorter, with a faint knock under it.

What it writes into samples/court/content/sounds/:

  step_stone.wav         the player's stride on stone
  land_stone.wav         a landing on stone, the player's or the warden's
  warden_step_stone.wav  the warden's footfall on stone

Nothing here reads a clock or `random`: the same script writes the same bytes everywhere.
Run from the repository root, or with --check to compare without writing.
"""

import argparse
import math
import struct
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "samples/court/content/sounds"
RATE = 22050


def wav(samples):
    """16-bit mono PCM, as M26's."""
    data = b"".join(struct.pack("<h", max(-32767, min(32767, int(round(v * 32767))))) for v in samples)
    return (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " +
            struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16) + b"data" + struct.pack("<I", len(data)) + data)


def noise(seed):
    """M26's fixed LCG."""
    state = seed & 0xFFFFFFFF
    while True:
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        yield (state >> 8) / float(1 << 23) - 1.0


def burst(seed, ms, alpha, gain, decay, knock):
    """A low-passed noise burst with a knock at `knock` Hz under it, both decaying."""
    source, last = noise(seed), 0.0
    n = RATE * ms // 1000
    out = []
    for i in range(n):
        t, u = i / RATE, i / n
        last += alpha * (next(source) - last)
        out.append((last * gain + 0.25 * math.sin(2 * math.pi * knock * t)) * math.exp(-decay * u))
    return out


def generate():
    return {
        "step_stone.wav": wav(burst(53, 70, 0.55, 1.6, 9, 610)),
        "land_stone.wav": wav(burst(59, 130, 0.35, 2.2, 7, 330)),
        "warden_step_stone.wav": wav(burst(61, 100, 0.3, 2.4, 7, 260)),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for name, expected in generate().items():
        path = OUT / name
        if args.check:
            if not path.exists() or path.read_bytes() != expected:
                stale.append(name)
        else:
            path.write_bytes(expected)
    if stale:
        print("stale: " + ", ".join(stale))
        sys.exit(1)


if __name__ == "__main__":
    main()
