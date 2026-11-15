#!/usr/bin/env python3
"""The six painted faces of `sandbox3d:environments.room` (`docs/design/environment.md` §11).

A developer script, run once from the repository root; its output is committed and nothing in
the build runs it. The room is painted, not photographed: plaster walls over a dark skirting,
a pale ceiling, a plank floor, and one window in the -Z wall, the brightest thing in the room,
so a metal edge has something to catch. Faces are +X -X +Y -Y +Z -Z, 128 texels square, rows
top to bottom in the cube convention the RHI shares with every GPU API (for a side face, the
last row is nearest the floor). The grain is a fixed hash, so every run writes the same bytes.

    python3 scripts/m41/make_room_faces.py
"""

import binascii
import os
import struct
import zlib

SIZE = 128
OUT = os.path.join("samples", "sandbox3d", "content", "textures", "room")
NAMES = ["px", "nx", "py", "ny", "pz", "nz"]


def chunk(kind: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF))


def png(width: int, height: int, pixel) -> bytes:
    """RGBA8, filter 0 on every row. `pixel(x, y)` returns three sRGB-encoded bytes."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixel(x, y))
            raw.append(255)
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    out += chunk(b"IEND", b"")
    return out


def grain(x: int, y: int, salt: int) -> int:
    """A stable value in [-6, 6]."""
    h = (x * 73856093) ^ (y * 19349663) ^ (salt * 83492791)
    h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
    return (h >> 8) % 13 - 6


def clamp(v: int) -> int:
    return max(0, min(255, v))


def tint(rgb, d):
    return bytes(clamp(c + d) for c in rgb)


PLASTER = (196, 186, 166)
SKIRTING = (70, 52, 38)
CEILING = (226, 224, 216)
PLANK = (122, 84, 54)
SEAM = (82, 56, 36)
SKY = (236, 244, 255)
FRAME = (64, 60, 56)


def wall(salt: int, window: bool):
    def pixel(x: int, y: int):
        if y >= SIZE * 7 // 8:
            return tint(SKIRTING, grain(x, y, salt) // 2)
        if window:
            left, right, top, bottom = SIZE * 5 // 16, SIZE * 11 // 16, SIZE // 5, SIZE * 5 // 8
            if left <= x < right and top <= y < bottom:
                inner = (left + 3 <= x < right - 3 and top + 3 <= y < bottom - 3
                         and abs(x - (left + right) // 2) > 1 and abs(y - (top + bottom) // 2) > 1)
                return bytes(SKY) if inner else bytes(FRAME)
        return tint(PLASTER, grain(x, y, salt))
    return pixel


def ceiling(x: int, y: int):
    return tint(CEILING, grain(x, y, 3) // 2)


def floor(x: int, y: int):
    if x % 16 == 0:
        return bytes(SEAM)
    # Each plank's end joint at its own place along it.
    if (y + (x // 16) * 37) % 96 == 0:
        return bytes(SEAM)
    return tint(PLANK, grain(x // 2, y // 6, 4) + ((x // 16) % 3 - 1) * 6)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    faces = [wall(0, False), wall(1, False), ceiling, floor, wall(5, False), wall(6, True)]
    for name, pixel in zip(NAMES, faces):
        path = os.path.join(OUT, name + ".png")
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(png(SIZE, SIZE, pixel))
        os.replace(tmp, path)
        print(path)


if __name__ == "__main__":
    main()
