#!/usr/bin/env python3
"""Build the MikkTSpace reference tool (ADR-0086, docs/design/environment.md §5.1).

`build(scratch)` fetches `mikktspace.c` and `mikktspace.h` at the pinned commit, checks them
against the SHA-256 values below (also in AGENTS.md), and compiles `reference/mikktspace_ref.c`
against them with `zig cc`, all inside `scratch`. It returns the tool's path. The files are
fetched from GitHub unless they are already in `scratch`.

`-ffp-contract=off` matters: clang would otherwise fuse multiplies and adds into FMAs on
arm64, and the reference is MikkTSpace in plain IEEE `float` arithmetic, as Foundry's Zig
port evaluates it. Nothing here is part of the build, and nothing it builds ships or links
into Foundry: the corpus is its output (ADR-0086). `zig` must be on PATH.
"""

import hashlib
import os
import subprocess
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

COMMIT = "3e895b49d05ea07e4c2133156cfa94369e19e409"
SOURCES = {
    "mikktspace.c": "de87e74107df766ce68108801262bd8d53899414236b59810509a8fc2a51e288",
    "mikktspace.h": "17fc433894f24c73753d548086cc4d8c5c0379f4a6edfb98b5da243e4f0bc3d0",
}


def fetch(scratch: str, name: str) -> str:
    path = os.path.join(scratch, name)
    if not os.path.exists(path):
        url = f"https://raw.githubusercontent.com/mmikk/MikkTSpace/{COMMIT}/{name}"
        urllib.request.urlretrieve(url, path)
    with open(path, "rb") as f:
        actual = hashlib.sha256(f.read()).hexdigest()
    if actual != SOURCES[name]:
        raise SystemExit(f"{name}: sha256 {actual} is not the pinned {SOURCES[name]}")
    return path


def build(scratch: str) -> str:
    os.makedirs(scratch, exist_ok=True)
    for name in SOURCES:
        fetch(scratch, name)
    tool = os.path.join(scratch, "mikktspace_ref")
    subprocess.run(
        ["zig", "cc", "-O2", "-ffp-contract=off", "-w", "-o", tool, "-I", scratch,
         os.path.join(HERE, "reference", "mikktspace_ref.c"),
         os.path.join(scratch, "mikktspace.c"), "-lm"],
        check=True,
    )
    return tool


def run(tool: str, mesh: str, tangents: str) -> None:
    subprocess.run([tool, mesh, tangents], check=True)
