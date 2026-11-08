#!/usr/bin/env python3
"""Generate the 3D sandbox's M37 corner models (`docs/design/collision-extras.md` §11).

Foundry's own content, under the repository's licence. The output is committed beside M20's
models; this script exists so those binaries are reproducible, the bargain `scripts/m20/
make_scene.py` makes, whose glTF writer it borrows. It is a developer tool and never part of
the build (CLAUDE.md §4.4), and it writes none of M20's files, so their byte pins cannot move.

What it writes into samples/sandbox3d/content/models/:

  corner.gltf, corner.bin  the corner's static ground, centred on (-20, 0, 0) in the walk
                           world's own coordinates: a stone floor, a metal platform beside
                           the lift, a metal wall the crate is pushed against, and a wooden
                           ledge whose top is one quad, imported one-sided so it is met from
                           above alone, over a slab that is drawn and left out of collision
  rock.gltf, rock.bin      a dense rock, its base at the origin: the model that is drawn
  rock_proxy.gltf, .bin    two boxes around the rock: the collision it names instead
  disc.gltf, disc.bin      the turntable: a sixteen-sided prism, the hull the sample builds

The numbers that place these are repeated in `samples/sandbox3d/extras.zig`, which moves the
pieces and checks the tour against them; a change here is a change there.

Nothing here reads a clock or `random`: the same script writes the same bytes everywhere.
Run from the repository root.
"""

import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "m20"))
from make_scene import Gltf, Mesh, box  # noqa: E402

WHITE = [(255, 255, 255, 255)] * 4
UV = [(0, 1), (1, 1), (1, 0), (0, 0)]

# The corner's centre, past the room's west wall and the crate grid's last column.
ORIGIN = (-20.0, 0.0, 0.0)
FLOOR_HALF = 4.0
PLATFORM = ((-4.0, -3.0), (-3.02, -2.0), 1.0)  # (x0, z0), (x1, z1), top, relative to ORIGIN
WALL = ((-3.4, 1.0), (-3.2, 3.0), 1.0)
LEDGE = ((-0.75, -3.25), (0.75, -1.75), 1.2)
DISC_RADIUS = 1.0
DISC_HALF = 0.05
DISC_SIDES = 16


def at(rel):
    return tuple(ORIGIN[i] + rel[i] for i in range(3))


def block(name, corner0, corner1, top, bottom=0.0):
    """A box from `bottom` to `top`, between two corners in x and z, relative to ORIGIN."""
    (x0, z0), (x1, z1) = corner0, corner1
    m = box(name, (x1 - x0) / 2, (top - bottom) / 2, (z1 - z0) / 2)
    return m, at(((x0 + x1) / 2, (top + bottom) / 2, (z0 + z1) / 2))


def corner():
    g = Gltf("corner.bin")
    stone = g.material("Stone", colour=(0.55, 0.55, 0.52, 1))
    metal = g.material("Metal", colour=(0.45, 0.5, 0.58, 1))
    ledge = g.material("Ledge", colour=(0.55, 0.38, 0.22, 1))
    slab = g.material("Slab", colour=(0.45, 0.3, 0.18, 1))
    h = FLOOR_HALF
    floor = Mesh("floor")
    floor.quad([at((-h, 0, h)), at((h, 0, h)), at((h, 0, -h)), at((-h, 0, -h))], (0, 1, 0),
               [(0, 8), (8, 8), (8, 0), (0, 0)], WHITE)
    g.node("Floor", g.mesh(floor, stone))
    platform, centre = block("platform", PLATFORM[0], PLATFORM[1], PLATFORM[2])
    g.node("Platform", g.mesh(platform, metal), t=centre)
    wall, centre = block("wall", WALL[0], WALL[1], WALL[2])
    g.node("Wall", g.mesh(wall, metal), t=centre)
    # The ledge's collision is its top alone, facing up: one-sided, a jump from below passes
    # up through it. The slab under it is drawn and excluded, or its underside would be a
    # ceiling and its sides walls.
    (x0, z0), (x1, z1), y = LEDGE
    top = Mesh("ledge")
    top.quad([at((x0, y, z1)), at((x1, y, z1)), at((x1, y, z0)), at((x0, y, z0))], (0, 1, 0), UV, WHITE)
    g.node("Ledge", g.mesh(top, ledge))
    under, centre = block("slab", LEDGE[0], LEDGE[1], y - 0.01, y - 0.1)
    g.node("LedgeSlab", g.mesh(under, slab), t=centre)
    g.write("corner")


def rock():
    """A lumpy, flattened sphere on the ground: 16 stacks of 24 slices, 768 triangles."""
    g = Gltf("rock.bin")
    m = Mesh("rock")
    stacks, slices = 16, 24
    centre_y, rx, ry = 0.36, 0.42, 0.36

    def point(i, j):
        theta = math.pi * i / stacks
        phi = 2 * math.pi * (j % slices) / slices
        lump = 1 + 0.08 * math.sin(3 * theta) * math.cos(2 * phi) + 0.04 * math.cos(5 * phi + theta)
        d = (math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi))
        return (rx * lump * d[0], centre_y + ry * lump * d[1], rx * lump * d[2]), d

    for i in range(stacks):
        for j in range(slices):
            # Counter-clockwise seen from outside. A pole's quad is one triangle.
            corners = [point(i, j), point(i, j + 1), point(i + 1, j + 1), point(i + 1, j)]
            base = len(m.positions)
            for p, n in corners:
                m.positions.append(p)
                m.normals.append(n)
                m.uvs.append((j / slices, i / stacks))
                m.colours.append((255, 255, 255, 255))
            if i != 0:
                m.indices.extend([base, base + 1, base + 2])
            if i != stacks - 1:
                m.indices.extend([base, base + 2, base + 3])
    g.node("Rock", g.mesh(m, g.material("Rock", colour=(0.42, 0.4, 0.37, 1))))
    g.write("rock")


def rock_proxy():
    """What the rock collides as: a body and a cap, each just outside the drawn rock."""
    g = Gltf("rock_proxy.bin")
    material = g.material("Proxy")
    g.node("Body", g.mesh(box("body", 0.47, 0.3, 0.47), material), t=(0, 0.3, 0))
    g.node("Cap", g.mesh(box("cap", 0.32, 0.08, 0.32), material), t=(0, 0.68, 0))
    g.write("rock_proxy")


def disc():
    g = Gltf("disc.bin")
    m = Mesh("disc")
    r, h, n = DISC_RADIUS, DISC_HALF, DISC_SIDES

    def rim(k, y):
        a = 2 * math.pi * k / n
        return (r * math.cos(a), y, -r * math.sin(a))

    def fan(points, normal):
        base = len(m.positions)
        m.positions.extend(points)
        m.normals.extend([normal] * 3)
        m.uvs.extend([(0.5, 0.5), (1, 0), (1, 1)])
        m.colours.extend(WHITE[:3])
        m.indices.extend([base, base + 1, base + 2])

    for k in range(n):
        # The top and bottom as fans to the centre, and each side as a quad.
        fan([(0, h, 0), rim(k, h), rim(k + 1, h)], (0, 1, 0))
        fan([(0, -h, 0), rim(k + 1, -h), rim(k, -h)], (0, -1, 0))
        a = 2 * math.pi * (k + 0.5) / n
        m.quad([rim(k, -h), rim(k + 1, -h), rim(k + 1, h), rim(k, h)], (math.cos(a), 0, -math.sin(a)), UV, WHITE)
    g.node("Disc", g.mesh(m, g.material("Turntable", colour=(0.5, 0.36, 0.2, 1))))
    g.write("disc")


def main():
    corner()
    rock()
    rock_proxy()
    disc()


if __name__ == "__main__":
    main()
