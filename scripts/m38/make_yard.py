#!/usr/bin/env python3
"""Generate the 3D sandbox's M38 yard models (`docs/design/collision-scale.md` §11).

Foundry's own content, under the repository's licence. The output is committed beside M20's
models; this script exists so those binaries are reproducible, the bargain `scripts/m20/
make_scene.py` makes, whose glTF writer it borrows. It is a developer tool and never part of
the build (CLAUDE.md §4.4), and it writes no other milestone's files, so their pins cannot move.

What it writes into samples/sandbox3d/content/models/:

  yard.gltf, yard.bin        the hillside, centred on its own origin, which the sample places at
                             `sandbox3d:yard.main`'s: a 127 by 127 grid of quads over 64 m, 32,258
                             triangles, rolling by `height` below. Its import derives its
                             collision, which is past `author`'s threshold and so carries its tree
  boulder.gltf, boulder.bin  the boulder, its ramp's low edge at the origin and rising along +X at
                             20 degrees: the model that is drawn, and, through a
                             `foundry:collision_import` with `shape "hull"`, the hull it and one
                             stone in four collide as

`height` is repeated in `samples/sandbox3d/yard.zig`, which sets the stones, the movers and the
boulder on the hillside and walks the tour across it; a change here is a change there. The two
need not agree to the last bit, since everything set on the hillside is sunk a little into it.

Nothing here reads a clock or `random`: the same script writes the same bytes everywhere.
Run from the repository root.
"""

import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "m20"))
from make_scene import Gltf, Mesh  # noqa: E402

HALF = 32.0
QUADS = 127
RAMP_TAN = math.tan(math.radians(20))


def height(x, z):
    """The hillside's height at (x, z) about its own origin: three sines, gentle enough to walk."""
    return (0.45 * math.sin(0.37 * x + 0.4) * math.cos(0.29 * z)
            + 0.25 * math.sin(0.61 * (x + z) + 1.1)
            + 0.15 * math.cos(0.83 * x - 0.47 * z))


def slope(x, z):
    """`height`'s gradient, for the normals."""
    dx = (0.45 * 0.37 * math.cos(0.37 * x + 0.4) * math.cos(0.29 * z)
          + 0.25 * 0.61 * math.cos(0.61 * (x + z) + 1.1)
          - 0.15 * 0.83 * math.sin(0.83 * x - 0.47 * z))
    dz = (-0.45 * 0.29 * math.sin(0.37 * x + 0.4) * math.sin(0.29 * z)
          + 0.25 * 0.61 * math.cos(0.61 * (x + z) + 1.1)
          + 0.15 * 0.47 * math.sin(0.83 * x - 0.47 * z))
    return dx, dz


def yard():
    g = Gltf("yard.bin")
    m = Mesh("hillside")
    side = QUADS + 1
    step = 2 * HALF / QUADS
    for row in range(side):
        z = -HALF + row * step
        for col in range(side):
            x = -HALF + col * step
            dx, dz = slope(x, z)
            n = (-dx, 1.0, -dz)
            length = math.sqrt(sum(c * c for c in n))
            m.positions.append((x, height(x, z), z))
            m.normals.append(tuple(c / length for c in n))
    # Two counter-clockwise triangles a square, seen from above, rows along +Z.
    for row in range(QUADS):
        for col in range(QUADS):
            a = row * side + col
            b, c = a + 1, a + side
            m.indices.extend([a, c, b, b, c, c + 1])
    g.node("Hillside", g.mesh(m, g.material("Grass", colour=(0.34, 0.45, 0.24, 1)), uvs=False, colours=False))
    g.write("yard")


# The boulder's points, about its ramp's low edge. The ramp is the four points on the plane
# y = 0.1 + x tan 20°, two metres wide; every other point lies below that plane, so the ramp is
# one face of the hull. One point is inside, which the hull leaves out.
RAMP_LENGTH = 2.5
BOULDER = [
    (0.0, 0.1, -1.0), (0.0, 0.1, 1.0),
    (RAMP_LENGTH, 0.1 + RAMP_LENGTH * RAMP_TAN, -1.0), (RAMP_LENGTH, 0.1 + RAMP_LENGTH * RAMP_TAN, 1.0),
    (-0.25, -0.5, -1.05), (-0.25, -0.5, 1.05),
    (1.2, 0.35, -1.25), (1.2, 0.35, 1.25),
    (1.2, -0.5, -1.3), (1.2, -0.5, 1.3),
    (3.4, -0.5, -1.1), (3.4, -0.5, 1.1),
    (3.2, 0.75, -0.8), (3.2, 0.75, 0.8),
    (3.5, 0.2, -0.6), (3.5, 0.2, 0.6),
    (1.5, 0.0, 0.0),
]


def hull_faces(points):
    """The hull's faces, each its corners counter-clockwise seen from outside, by brute force:
    a plane through three points with every point on or behind it is a face. Fine for 17 points."""
    faces = []
    seen = []
    n = len(points)
    for i in range(n):
        for j in range(i + 1, n):
            for k in range(j + 1, n):
                a, b, c = points[i], points[j], points[k]
                u = [b[t] - a[t] for t in range(3)]
                v = [c[t] - a[t] for t in range(3)]
                normal = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
                length = math.sqrt(sum(x * x for x in normal))
                if length < 1e-9:
                    continue
                normal = [x / length for x in normal]
                offset = sum(normal[t] * a[t] for t in range(3))
                sides = [sum(normal[t] * p[t] for t in range(3)) - offset for p in points]
                if all(s <= 1e-6 for s in sides):
                    pass
                elif all(s >= -1e-6 for s in sides):
                    normal = [-x for x in normal]
                    offset = -offset
                else:
                    continue
                key = tuple(round(x, 6) for x in normal) + (round(offset, 6),)
                if key in seen:
                    continue
                seen.append(key)
                on = [p for p in points if abs(sum(normal[t] * p[t] for t in range(3)) - offset) <= 1e-6]
                centre = [sum(p[t] for p in on) / len(on) for t in range(3)]
                # Two axes in the face's plane, to order its corners by angle.
                ref = [on[0][t] - centre[t] for t in range(3)]
                ref_len = math.sqrt(sum(x * x for x in ref))
                e1 = [x / ref_len for x in ref]
                e2 = [normal[1] * e1[2] - normal[2] * e1[1], normal[2] * e1[0] - normal[0] * e1[2], normal[0] * e1[1] - normal[1] * e1[0]]
                on.sort(key=lambda p: math.atan2(sum((p[t] - centre[t]) * e2[t] for t in range(3)),
                                                 sum((p[t] - centre[t]) * e1[t] for t in range(3))))
                faces.append((tuple(normal), on))
    return faces


def boulder():
    g = Gltf("boulder.bin")
    m = Mesh("boulder")
    for normal, corners in hull_faces(BOULDER):
        base = len(m.positions)
        for p in corners:
            m.positions.append(p)
            m.normals.append(normal)
        for k in range(1, len(corners) - 1):
            m.indices.extend([base, base + k, base + k + 1])
    # The inside point is a vertex no triangle uses in the drawn mesh; the hull is built from what
    # the triangles use, so it is given a sliver of its own, inside, which the hull leaves out.
    inside = len(m.positions)
    m.positions.extend([BOULDER[-1], (1.5, 0.0, 0.1), (1.6, 0.0, 0.0)])
    m.normals.extend([(0.0, 1.0, 0.0)] * 3)
    m.indices.extend([inside, inside + 1, inside + 2])
    g.node("Boulder", g.mesh(m, g.material("Rock", colour=(0.45, 0.43, 0.4, 1)), uvs=False, colours=False))
    g.write("boulder")


if __name__ == "__main__":
    yard()
    boulder()
