#!/usr/bin/env python3
"""Write the Vorbis decoder's fixtures (docs/design/music.md §3.5).

    python3 scripts/m30/make_fixtures.py <scratch-dir>

Synthesises each source signal deterministically, encodes it with the reference libvorbis
(`reference.py` builds the tool in <scratch-dir>), and decodes the result with the reference
libvorbisfile. Writes `<name>.ogg` and `<name>.ref.wav` into
`engine/src/asset/testdata/vorbis/`. The source WAVs stay in scratch.

Each fixture exists for a reason the decoder's tests name. The build never runs this; run it
from the repository root with `zig` on PATH.
"""

import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference  # noqa: E402

OUT = "engine/src/asset/testdata/vorbis"
TAU = 2 * math.pi


def lcg(seed: int):
    """A fixed generator, so the noise in a fixture is the same on every run."""
    state = seed
    while True:
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        yield ((state >> 33) / (1 << 31)) * 2 - 1


def write_wav(path: str, rate: int, channels: list) -> None:
    frames = len(channels[0])
    data = bytearray()
    for i in range(frames):
        for ch in channels:
            data += struct.pack("<h", max(-32768, min(32767, round(ch[i] * 32767))))
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, len(channels), rate,
                                      rate * 2 * len(channels), 2 * len(channels), 16))
        f.write(b"data" + struct.pack("<I", len(data)) + bytes(data))


def tone(rate: int, seconds: float, f):
    n = round(rate * seconds)
    return [f(i / rate, i / n) for i in range(n)]


def chord(t: float, u: float) -> float:
    env = math.exp(-2.5 * u)
    return env * 0.3 * sum(math.sin(TAU * hz * t) for hz in (220.0, 277.18, 329.63))


def sweep(t: float, u: float) -> float:
    return 0.6 * math.sin(TAU * (100 * t + 4000 * t * t))


def fixtures():
    """(name, rate, channels, quality, why)."""
    noise = lcg(7)
    yield "mono44_q0", 44100, [tone(44100, 1.5, chord)], 0.0, "lowest common quality"
    yield "mono44_q10", 44100, [tone(44100, 1.0, sweep)], 1.0, "highest quality"
    left = tone(48000, 2.0, lambda t, u: 0.5 * math.sin(TAU * 440 * t) * (1 - u))
    right = tone(48000, 2.0, lambda t, u: 0.5 * math.sin(TAU * 440 * t + 0.6) * u)
    yield "stereo48_q4", 48000, [left, right], 0.4, "the court's settings"
    yield "stereo22_qm1", 22050, [
        tone(22050, 1.5, lambda t, u: 0.4 * math.sin(TAU * 330 * t) + 0.1 * next(noise)),
        tone(22050, 1.5, lambda t, u: 0.4 * math.sin(TAU * 495 * t) + 0.1 * next(noise)),
    ], -0.1, "the lowest quality, the smallest blocks"
    short = 300 / 48000
    yield "short", 48000, [
        tone(48000, short, lambda t, u: 0.5 * math.sin(TAU * 1000 * t)),
        tone(48000, short, lambda t, u: 0.5 * math.sin(TAU * 1500 * t)),
    ], 0.4, "fewer frames than one long block"
    yield "long3s", 22050, [tone(22050, 3.0, lambda t, u: chord(t, (u * 3) % 1) + 0.2 * next(noise))], 0.6, "many pages"
    yield "coupled", 44100, [
        tone(44100, 1.0, lambda t, u: 0.5 * math.sin(TAU * 523.25 * t)),
        tone(44100, 1.0, lambda t, u: 0.3 * next(noise)),
    ], 0.4, "channels that differ, so coupling carries a real residue"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    scratch = os.path.abspath(sys.argv[1])
    tool = reference.build(scratch)
    os.makedirs(OUT, exist_ok=True)
    for index, (name, rate, channels, quality, _why) in enumerate(fixtures()):
        source = os.path.join(scratch, name + ".src.wav")
        write_wav(source, rate, channels)
        ogg = os.path.join(OUT, name + ".ogg")
        reference.encode(tool, source, ogg, quality, 0x46440000 + index)
        reference.decode(tool, ogg, os.path.join(OUT, name + ".ref.wav"))
        print(f"{name}: {os.path.getsize(ogg)} bytes")


if __name__ == "__main__":
    main()
