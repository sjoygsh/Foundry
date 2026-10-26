#!/usr/bin/env python3
"""Build the Vorbis reference tool (docs/design/music.md §3.5, ADR-0065).

`build(scratch)` unpacks libogg 1.3.5 and libvorbis 1.3.7 from their release tarballs, checked
against the SHA-256 values below (also in AGENTS.md), and compiles `reference/vorbis_ref.c`
against them with `zig cc`, all inside `scratch`. It returns the tool's path. The tarballs are
fetched from Xiph's download server unless they are already in `scratch`.

Nothing here is part of the build, and nothing it builds ships or links into Foundry: the
fixtures and the samples' music are its output (ADR-0065, decision 5). `zig` must be on PATH.
"""

import hashlib
import os
import subprocess
import tarfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

TARBALLS = {
    "libogg-1.3.5.tar.gz": (
        "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz",
        "0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664",
    ),
    "libvorbis-1.3.7.tar.gz": (
        "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz",
        "0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab",
    ),
}

# What `configure` would generate for libogg on every platform Foundry builds on.
CONFIG_TYPES = """#ifndef __CONFIG_TYPES_H__
#define __CONFIG_TYPES_H__
#include <stdint.h>
typedef int16_t ogg_int16_t;
typedef uint16_t ogg_uint16_t;
typedef int32_t ogg_int32_t;
typedef uint32_t ogg_uint32_t;
typedef int64_t ogg_int64_t;
typedef uint64_t ogg_uint64_t;
#endif
"""

# libvorbis's lib/ also holds three programs with their own `main`, and the encoder's
# psychoacoustic tuning tool; none belongs in the library.
VORBIS_SKIP = {"barkmel.c", "psytune.c", "tone.c"}


def fetch(scratch: str, name: str) -> str:
    url, digest = TARBALLS[name]
    path = os.path.join(scratch, name)
    if not os.path.exists(path):
        urllib.request.urlretrieve(url, path)
    with open(path, "rb") as f:
        actual = hashlib.sha256(f.read()).hexdigest()
    if actual != digest:
        raise SystemExit(f"{name}: sha256 {actual} is not the pinned {digest}")
    return path


def unpack(scratch: str, name: str) -> str:
    root = os.path.join(scratch, name[: -len(".tar.gz")])
    if not os.path.isdir(root):
        with tarfile.open(fetch(scratch, name)) as tar:
            tar.extractall(scratch, filter="data")
    return root


def build(scratch: str) -> str:
    os.makedirs(scratch, exist_ok=True)
    ogg = unpack(scratch, "libogg-1.3.5.tar.gz")
    vorbis = unpack(scratch, "libvorbis-1.3.7.tar.gz")
    with open(os.path.join(ogg, "include", "ogg", "config_types.h"), "w") as f:
        f.write(CONFIG_TYPES)
    tool = os.path.join(scratch, "vorbis_ref")
    sources = [os.path.join(ogg, "src", c) for c in ("bitwise.c", "framing.c")]
    lib = os.path.join(vorbis, "lib")
    sources += sorted(
        os.path.join(lib, c) for c in os.listdir(lib) if c.endswith(".c") and c not in VORBIS_SKIP
    )
    subprocess.run(
        ["zig", "cc", "-O2", "-w", "-o", tool,
         "-I", os.path.join(ogg, "include"),
         "-I", os.path.join(vorbis, "include"),
         "-I", lib,
         os.path.join(HERE, "reference", "vorbis_ref.c"), *sources, "-lm"],
        check=True,
    )
    return tool


def encode(tool: str, wav: str, ogg: str, quality: float, serial: int) -> None:
    subprocess.run([tool, "encode", wav, ogg, repr(quality), str(serial)], check=True)


def decode(tool: str, ogg: str, wav: str) -> None:
    subprocess.run([tool, "decode", ogg, wav], check=True)
