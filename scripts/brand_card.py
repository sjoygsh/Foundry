#!/usr/bin/env python3
"""Compose Foundry's GitHub social-preview card from the brand marks.

A developer script, never part of the build (CLAUDE.md 4.4). It exists so the card can be
regenerated from the masters rather than being an image nobody can reproduce.

There is no ImageMagick or Pillow on this machine, and the one thing needed here -- compositing
a transparent mark onto an opaque ground -- is exactly what `sips` cannot do. So the PNG read
and write are done directly over stdlib zlib: 8-bit RGBA, non-interlaced, which is what both
masters are and what `sips` emits when it rescales them.

    python3 scripts/brand_card.py

Writes brand/social-preview.png at GitHub's 1280x640.
"""

import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

CARD_W, CARD_H = 1280, 640
LOGO_H = 260            # the glyph's height in the lockup
WORDMARK_W = 620        # the wordmark's width beside it
GAP = 56                # space between them
GROUND_CENTRE = (0x16, 0x19, 0x1E)
GROUND_EDGE = (0x0A, 0x0B, 0x0D)


def read_png(path):
    """Decode an 8-bit RGBA, non-interlaced PNG into (width, height, bytearray)."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos, idat, header = 8, bytearray(), None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        kind = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if header is None:
        raise SystemExit(f"{path}: no IHDR")
    width, height, depth, colour, compression, filt, interlace = header
    if (depth, colour, compression, filt, interlace) != (8, 6, 0, 0, 0):
        raise SystemExit(f"{path}: want 8-bit RGBA non-interlaced, got {header[2:]}")

    raw = zlib.decompress(bytes(idat))
    stride = width * 4
    out = bytearray(stride * height)
    previous = bytearray(stride)
    at = 0
    for y in range(height):
        method = raw[at]
        line = bytearray(raw[at + 1 : at + 1 + stride])
        at += 1 + stride
        if method == 1:
            for i in range(4, stride):
                line[i] = (line[i] + line[i - 4]) & 0xFF
        elif method == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif method == 3:
            for i in range(stride):
                left = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif method == 4:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b = previous[i]
                c = previous[i - 4] if i >= 4 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                nearest = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + nearest) & 0xFF
        elif method != 0:
            raise SystemExit(f"{path}: unknown filter {method}")
        out[y * stride : (y + 1) * stride] = line
        previous = line
    return width, height, out


def write_png(path, width, height, pixels):
    """Encode 8-bit RGBA with no filtering -- the image is flat colour and a mark."""

    def chunk(kind, body):
        return (
            struct.pack(">I", len(body))
            + kind
            + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )

    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += pixels[y * stride : (y + 1) * stride]
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def scaled(source, out, *, width=None, height=None):
    """Rescale through sips, which keeps the alpha channel the compositing needs."""
    flag = ["--resampleWidth", str(width)] if width else ["--resampleHeight", str(height)]
    subprocess.run(
        ["sips", *flag, str(source), "--out", str(out)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return read_png(out)


def ground():
    """A soft radial lift under the lockup, so the card is not a flat rectangle."""
    pixels = bytearray(CARD_W * CARD_H * 4)
    cx, cy = CARD_W / 2, CARD_H / 2
    longest = (cx * cx + cy * cy) ** 0.5
    for y in range(CARD_H):
        for x in range(CARD_W):
            d = (((x - cx) ** 2 + (y - cy) ** 2) ** 0.5) / longest
            t = min(1.0, d * 1.15) ** 1.4
            at = (y * CARD_W + x) * 4
            for c in range(3):
                pixels[at + c] = round(GROUND_CENTRE[c] + (GROUND_EDGE[c] - GROUND_CENTRE[c]) * t)
            pixels[at + 3] = 0xFF
    return pixels


def over(canvas, mark, mark_w, mark_h, left, top):
    """Ordinary source-over compositing; the ground is opaque, so alpha stays at 255."""
    for y in range(mark_h):
        dy = top + y
        if not 0 <= dy < CARD_H:
            continue
        for x in range(mark_w):
            dx = left + x
            if not 0 <= dx < CARD_W:
                continue
            s = (y * mark_w + x) * 4
            alpha = mark[s + 3]
            if alpha == 0:
                continue
            d = (dy * CARD_W + dx) * 4
            if alpha == 0xFF:
                canvas[d : d + 3] = mark[s : s + 3]
                continue
            for c in range(3):
                canvas[d + c] = (mark[s + c] * alpha + canvas[d + c] * (255 - alpha) + 127) // 255


def main():
    brand = ROOT / "brand"
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        lw, lh, logo = scaled(brand / "foundry-logo.png", tmp / "logo.png", height=LOGO_H)
        ww, wh, wordmark = scaled(brand / "foundry-wordmark.png", tmp / "word.png", width=WORDMARK_W)

    canvas = ground()
    lockup = lw + GAP + ww
    left = (CARD_W - lockup) // 2
    over(canvas, logo, lw, lh, left, (CARD_H - lh) // 2)
    over(canvas, wordmark, ww, wh, left + lw + GAP, (CARD_H - wh) // 2)

    out = brand / "social-preview.png"
    write_png(out, CARD_W, CARD_H, canvas)
    print(f"{out.relative_to(ROOT)}  {CARD_W}x{CARD_H}  {out.stat().st_size} bytes")


if __name__ == "__main__":
    sys.exit(main())
