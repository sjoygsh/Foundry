#!/usr/bin/env python3
"""Generate sandbox3d's particle textures (M29, docs/design/particles.md §8).

- `samples/sandbox3d/content/effects/flame.png`: a 4x4 flipbook, 256x256, sixteen 64x64 frames
  of a flame tongue that rises, narrows and fades, row-major from the top left.
- `samples/sandbox3d/content/effects/puff.png`: one soft round puff, 64x64, for smoke, sparks,
  the fountain and the trail.

Both are white in RGB with the shape in alpha (straight, not premultiplied): the material and
the emitter's colour curve give the colour, so one texture serves every tint. The output is
deterministic: the same script writes the same bytes, and the build never runs it.

Run from the repository root.
"""

import binascii
import math
import struct
import zlib


def chunk(kind: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF))


def png(width: int, height: int, alpha) -> bytes:
    """An RGBA8 PNG, white with `alpha(x, y)` in 0..1 (no filter, zlib level 9)."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            a = max(0.0, min(1.0, alpha(x, y)))
            raw += bytes((255, 255, 255, round(a * 255)))
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def smooth(edge0: float, edge1: float, x: float) -> float:
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def puff(x: int, y: int) -> float:
    u = (x + 0.5) / 32 - 1
    v = (y + 0.5) / 32 - 1
    r = math.sqrt(u * u + v * v)
    return 1 - smooth(0.0, 1.0, r)


def flame(x: int, y: int) -> float:
    frame = (y // 64) * 4 + (x // 64)
    t = frame / 15
    # Within the frame: u across in -1..1, v up from the bottom in 0..1.
    u = ((x % 64) + 0.5) / 32 - 1
    v = 1 - ((y % 64) + 0.5) / 64
    # A tongue that sways a little, narrows towards the tip and shrinks over the flipbook.
    sway = 0.12 * math.sin(6.0 * v + 2.4 * frame)
    width = (0.65 - 0.25 * t) * (1 - v) ** 0.7 + 0.02
    across = abs(u - sway * v) / width
    height = 1 - smooth(0.55 - 0.25 * t, 0.95 - 0.3 * t, v)
    return (1 - smooth(0.5, 1.0, across)) * height * (1 - 0.5 * t)


def main() -> None:
    base = "samples/sandbox3d/content/effects/"
    with open(base + "flame.png", "wb") as f:
        f.write(png(256, 256, flame))
    with open(base + "puff.png", "wb") as f:
        f.write(png(64, 64, puff))


if __name__ == "__main__":
    main()
