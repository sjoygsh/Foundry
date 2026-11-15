#!/usr/bin/env python3
"""Write the tangent port's corpus (ADR-0086, docs/design/environment.md §5.1).

    python3 -I scripts/m41/make_tangent_corpus.py <scratch-dir>

Builds each mesh deterministically, writes it as `<name>.mesh`, and runs the reference
MikkTSpace (`reference.py` builds the tool in <scratch-dir>) over it to write
`<name>.tangents`, both into `engine/src/asset/testdata/tangents/`. A mesh file is a u32
vertex count, a u32 index count, then f32x3 positions, f32x3 normals, f32x2 UVs and u32
indices, little-endian; a tangents file is one f32x4 per index.

Each mesh exists for a path through the reference that `asset/tangents.zig`'s corpus test
must match. The build never runs this; run it from the repository root with `zig` on PATH.
"""

import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference  # noqa: E402

OUT = "engine/src/asset/testdata/tangents"
TAU = 2 * math.pi


def lcg(seed: int):
    """A fixed generator in [0, 1), the same on every run and every Python."""
    state = seed
    while True:
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        yield (state >> 11) / (1 << 53)


def unit(v):
    n = math.sqrt(sum(c * c for c in v))
    return tuple(c / n for c in v) if n > 0 else (0.0, 0.0, 0.0)


class Mesh:
    def __init__(self):
        self.p, self.n, self.t, self.i = [], [], [], []

    def vert(self, p, n, t) -> int:
        self.p.append(p)
        self.n.append(n)
        self.t.append(t)
        return len(self.p) - 1

    def tri(self, a, b, c):
        self.i += [a, b, c]

    def bytes(self) -> bytes:
        out = bytearray(struct.pack("<II", len(self.p), len(self.i)))
        for p in self.p:
            out += struct.pack("<3f", *p)
        for n in self.n:
            out += struct.pack("<3f", *n)
        for t in self.t:
            out += struct.pack("<2f", *t)
        out += struct.pack(f"<{len(self.i)}I", *self.i)
        return bytes(out)


def grid(cols, rows, height=lambda x, z: 0.0, uv=lambda u, v: (u, v)) -> Mesh:
    """A surface y = height(x, z) over [-1, 1]², its normal from central differences."""
    m = Mesh()
    e = 1e-3
    for j in range(rows + 1):
        for i in range(cols + 1):
            u, v = i / cols, j / rows
            x, z = u * 2 - 1, v * 2 - 1
            dx = (height(x + e, z) - height(x - e, z)) / (2 * e)
            dz = (height(x, z + e) - height(x, z - e)) / (2 * e)
            m.vert((x, height(x, z), z), unit((-dx, 1.0, -dz)), uv(u, v))
    for j in range(rows):
        for i in range(cols):
            a = j * (cols + 1) + i
            b, c, d = a + 1, a + cols + 2, a + cols + 1
            m.tri(a, d, c)
            m.tri(a, c, b)
    return m


def quad() -> Mesh:
    return grid(1, 1)


def wavy() -> Mesh:
    return grid(8, 8, height=lambda x, z: 0.15 * math.sin(3 * x) * math.cos(2 * z))


def cube() -> Mesh:
    m = Mesh()
    for axis in range(3):
        for sign in (1.0, -1.0):
            n = [0.0, 0.0, 0.0]
            n[axis] = sign
            a, b = (axis + 1) % 3, (axis + 2) % 3
            corners = []
            for (su, sv) in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                p = [0.0, 0.0, 0.0]
                p[axis] = sign
                p[a] = su * sign
                p[b] = sv
                corners.append(m.vert(tuple(p), tuple(n), ((su + 1) / 2, (sv + 1) / 2)))
            m.tri(corners[0], corners[1], corners[2])
            m.tri(corners[0], corners[2], corners[3])
    return m


def sphere(segments=24, rings=12) -> Mesh:
    """A UV sphere with a duplicated seam and one pole vertex per segment, so the polar
    triangles have two corners at one position: degenerate."""
    m = Mesh()
    for r in range(rings + 1):
        theta = math.pi * r / rings
        for s in range(segments + 1):
            phi = TAU * s / segments
            n = (math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi))
            m.vert(n, n, (s / segments, r / rings))
    for r in range(rings):
        for s in range(segments):
            a = r * (segments + 1) + s
            b, c, d = a + 1, a + segments + 2, a + segments + 1
            m.tri(a, b, c)
            m.tri(a, c, d)
    return m


def mirror() -> Mesh:
    """u mirrored about x = 0: the halves have opposite handedness and share a column."""
    return grid(8, 4, height=lambda x, z: 0.1 * z * z, uv=lambda u, v: (abs(u * 2 - 1), v))


def collapsed_uv() -> Mesh:
    """Some UVs collapse to one point, so their triangles have no UV area: group-with-any."""
    def uv(u, v):
        if 0.25 <= u <= 0.5 and 0.25 <= v <= 0.5:
            return (0.375, 0.375)
        return (u, v)
    return grid(8, 8, height=lambda x, z: 0.2 * x * z, uv=uv)


def soup() -> Mesh:
    """Random vertices joined at random: repeated indices, non-manifold edges, any winding."""
    rand = lcg(41)
    m = Mesh()
    for _ in range(120):
        p = tuple(next(rand) * 2 - 1 for _ in range(3))
        n = unit(tuple(next(rand) * 2 - 1 for _ in range(3)))
        m.vert(p, n, (next(rand), next(rand)))
    for _ in range(300):
        m.tri(*(int(next(rand) * 120) for _ in range(3)))
    return m


def unwelded() -> Mesh:
    """The sphere with every corner its own vertex, which the reference welds back."""
    s = sphere(16, 8)
    m = Mesh()
    for k in s.i:
        m.vert(s.p[k], s.n[k], s.t[k])
        m.i.append(len(m.p) - 1)
    return m


def torus(segments=48, sides=24, big=1.0, small=0.35) -> Mesh:
    m = Mesh()
    for i in range(segments + 1):
        u = TAU * i / segments
        for j in range(sides + 1):
            v = TAU * j / sides
            n = (math.cos(u) * math.cos(v), math.sin(v), math.sin(u) * math.cos(v))
            p = ((big + small * math.cos(v)) * math.cos(u), small * math.sin(v),
                 (big + small * math.cos(v)) * math.sin(u))
            m.vert(p, n, (3 * i / segments, j / sides))
    for i in range(segments):
        for j in range(sides):
            a = i * (sides + 1) + j
            b, c, d = a + 1, a + sides + 2, a + sides + 1
            m.tri(a, b, c)
            m.tri(a, c, d)
    return m


def degenerate() -> Mesh:
    """Degenerate triangles among good ones: each corner copies a good corner's space, or
    keeps the default when none shares its vertex."""
    m = wavy()
    good = len(m.i) // 3
    for k in range(0, good, 5):
        a, b, c = m.i[3 * k: 3 * k + 3]
        m.tri(a, a, b)
        m.tri(c, b, c)
    lone = m.vert((5.0, 5.0, 5.0), (0.0, 1.0, 0.0), (0.5, 0.5))
    other = m.vert((5.0, 5.0, 5.0), (0.0, 0.0, 1.0), (0.25, 0.5))
    m.tri(lone, other, lone)
    # Collinear but distinct positions: not degenerate to the reference, and no area.
    a = m.vert((6.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0))
    b = m.vert((7.0, 0.0, 0.0), (0.0, 1.0, 0.0), (1.0, 0.0))
    c = m.vert((8.0, 0.0, 0.0), (0.0, 1.0, 0.0), (1.0, 1.0))
    m.tri(a, b, c)
    return m


def all_degenerate() -> Mesh:
    m = Mesh()
    a = m.vert((0.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0))
    b = m.vert((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (1.0, 0.0))
    m.tri(a, a, b)
    m.tri(b, a, b)
    return m


def butterfly() -> Mesh:
    """Four triangles on one edge, two each way round, and a fifth sharing a vertex."""
    m = Mesh()
    up = (0.0, 1.0, 0.0)
    a = m.vert((0.0, 0.0, -1.0), up, (0.5, 0.0))
    b = m.vert((0.0, 0.0, 1.0), up, (0.5, 1.0))
    wings = []
    for k, (x, y) in enumerate(((1.0, 0.0), (-1.0, 0.0), (0.7, 0.7), (-0.7, -0.7))):
        wings.append(m.vert((x, y, 0.0), unit((0.0, 1.0, 0.2 * k)), ((x + 1) / 2, 0.5)))
    m.tri(a, b, wings[0])
    m.tri(b, a, wings[1])
    m.tri(a, b, wings[2])
    m.tri(b, a, wings[3])
    tip = m.vert((2.0, 0.0, -1.0), up, (1.0, 0.0))
    m.tri(a, wings[0], tip)
    return m


def parallel() -> Mesh:
    """Normals along the UV's u direction, and one zero normal: the projected tangent is
    zero and is not normalized."""
    m = Mesh()
    along = (1.0, 0.0, 0.0)
    a = m.vert((0.0, 0.0, 0.0), along, (0.0, 0.0))
    b = m.vert((1.0, 0.0, 0.0), along, (1.0, 0.0))
    c = m.vert((1.0, 0.0, -1.0), (0.0, 0.0, 0.0), (1.0, 1.0))
    d = m.vert((0.0, 0.0, -1.0), along, (0.0, 1.0))
    m.tri(a, b, c)
    m.tri(a, c, d)
    return m


CASES = {
    "quad": quad,
    "grid": wavy,
    "cube": cube,
    "sphere": sphere,
    "mirror": mirror,
    "collapsed_uv": collapsed_uv,
    "soup": soup,
    "unwelded": unwelded,
    "torus": torus,
    "degenerate": degenerate,
    "all_degenerate": all_degenerate,
    "butterfly": butterfly,
    "parallel": parallel,
}


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: make_tangent_corpus.py <scratch-dir>")
    tool = reference.build(os.path.abspath(sys.argv[1]))
    os.makedirs(OUT, exist_ok=True)
    for name, make in CASES.items():
        mesh = os.path.join(OUT, name + ".mesh")
        tmp = mesh + ".tmp"
        with open(tmp, "wb") as f:
            f.write(make().bytes())
        os.replace(tmp, mesh)
        tangents = os.path.join(OUT, name + ".tangents")
        reference.run(tool, mesh, tangents + ".tmp")
        os.replace(tangents + ".tmp", tangents)
        print(f"{name}: {os.path.getsize(mesh)} + {os.path.getsize(tangents)} bytes")


if __name__ == "__main__":
    main()
