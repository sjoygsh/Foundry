#!/usr/bin/env python3
"""Generate samples/sandbox3d/content/models/ — the 3D sandbox's glTF scene (M20, meshes.md §9).

Foundry's own content, under the repository's licence. The output is committed; this script
exists so that the binaries in the tree are reproducible rather than mysterious, the bargain
`gen-room-assets.py` makes for the room's sprites. It is a developer tool and never part of
the build (CLAUDE.md §4.4): the build imports the committed glTF through `author`'s compiler,
exactly as it would import a file an artist exported.

What it writes, all beside each other so a `.gltf`'s relative URIs stay inside the package:

  room.gltf, room.bin    the room: a checkered floor, four brick walls facing inward, a table
                         whose top carries four child legs (a node hierarchy that flattens into
                         parts), a crate and a mirrored copy of it (negative X scale), a plant
                         whose leaves are alpha-masked, and a glass pane that blends
  crate.gltf, crate.bin  one crate, which the sample stands in a grid outside the walls
  checker.png            the floor's texture, repeated by UVs past 1
  brick.png              the walls'
  crate.png              the crates', with an F on each face so a mirrored one reads mirrored
  leaf.png               the plant's, with alpha 0 around the leaves

The unlit shading model draws texture x vertex colour x base colour, so each box face carries
a baked tone in COLOR_0: without it a box would draw as one flat silhouette.

Units are metres, +Y is up and -Z forward, as glTF's and Foundry's are (ADR-0048). The walls are
single-sided and face inward, so from the orbiting camera outside, the near wall's back is
culled away and the room is seen into.

Nothing here reads a clock or `random`: the same script writes the same bytes everywhere.
Run from the repository root.
"""

import binascii
import json
import math
import os
import struct
import zlib

OUT = os.path.join("samples", "sandbox3d", "content", "models")

# glTF's numeric constants, named once.
FLOAT = 5126
UNSIGNED_BYTE = 5121
UNSIGNED_SHORT = 5123
ARRAY_BUFFER = 34962
ELEMENT_ARRAY_BUFFER = 34963
LINEAR = 9729
LINEAR_MIPMAP_LINEAR = 9987
REPEAT = 10497


# -- images --------------------------------------------------------------------------

def chunk(kind: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF))


def png(width: int, height: int, pixel) -> bytes:
    """RGBA8, filter 0 on every row. `pixel(x, y)` returns four sRGB-encoded bytes."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixel(x, y))
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    out += chunk(b"IEND", b"")
    return out


def hashed(x: int, y: int, salt: int) -> int:
    """A stable per-pixel value in [0, 65535], for grain that is the same on every machine."""
    v = (x * 374761393 + y * 668265263 + salt * 2246822519) & 0xFFFFFFFF
    v ^= v >> 13
    v = (v * 1274126177) & 0xFFFFFFFF
    return v >> 16


def grain(rgb, x, y, salt, amount):
    d = (hashed(x, y, salt) % (2 * amount + 1)) - amount
    return bytes(max(0, min(255, c + d)) for c in rgb) + b"\xff"


def checker(x, y):
    light = ((x // 32) + (y // 32)) % 2 == 0
    return grain((196, 188, 170) if light else (92, 84, 74), x, y, 1, 4)


def brick(x, y):
    # 64x32: two courses of 16 px, each brick 32 px long, alternate courses offset by half.
    course = y // 16
    bx = (x + (16 if course % 2 else 0)) % 32
    if y % 16 in (0, 15) or bx in (0, 31):
        return grain((168, 160, 150), x, y, 2, 3)
    tone = hashed(x // 32 + course * 7, course, 3) % 24
    return grain((150 + tone, 64 + tone // 2, 44), x, y, 4, 6)


# A 5x7 F, in cells of 4 px, placed off-centre so that a reflection moves it.
F_GLYPH = ["#####", "#....", "#....", "####.", "#....", "#....", "#...."]


def crate(x, y):
    if x < 4 or x >= 60 or y < 4 or y >= 60:
        return grain((96, 64, 34), x, y, 5, 4)
    gx, gy = (x - 10) // 4, (y - 12) // 4
    if 0 <= gx < 5 and 0 <= gy < 7 and F_GLYPH[gy][gx] == "#":
        return grain((238, 222, 180), x, y, 6, 3)
    plank = (y - 4) // 14
    if (y - 4) % 14 == 0:
        return grain((110, 74, 40), x, y, 7, 3)
    tone = plank * 9
    return grain((176 - tone, 124 - tone, 70 - tone // 2), x, y, 8, 7)


LEAVES = [  # centre x, centre y, half length, half width, angle: in pixels and radians
    (32, 30, 26, 9, 0.0),
    (20, 38, 22, 8, -0.7),
    (44, 38, 22, 8, 0.7),
]


def leaf(x, y):
    for cx, cy, a, b, t in LEAVES:
        dx, dy = x + 0.5 - cx, y + 0.5 - cy
        u = dx * math.cos(t) + dy * math.sin(t)
        v = -dx * math.sin(t) + dy * math.cos(t)
        if (v / a) ** 2 + (u / b) ** 2 <= 1.0:
            vein = abs(u) < 1.0
            rgb = (120, 190, 90) if vein else (48 + int(40 * (1 + v / a)), 128, 44)
            return grain(rgb, x, y, 9, 5)
    return b"\x00\x00\x00\x00"


# -- geometry ------------------------------------------------------------------------

class Mesh:
    def __init__(self, name):
        self.name = name
        self.positions = []
        self.normals = []
        self.uvs = []
        self.colours = []
        self.indices = []

    def quad(self, corners, normal, uvs, colours):
        """Four corners, counter-clockwise seen from the side `normal` points to."""
        base = len(self.positions)
        self.positions.extend(corners)
        self.normals.extend([normal] * 4)
        self.uvs.extend(uvs)
        self.colours.extend(colours)
        self.indices.extend([base, base + 1, base + 2, base, base + 2, base + 3])


# Each face's normal and two edges whose cross product is that normal (the sandbox's own
# box frames), with a tone baked for the face.
FACES = [
    ((1, 0, 0), (0, 0, -1), (0, 1, 0), 216),
    ((-1, 0, 0), (0, 0, 1), (0, 1, 0), 178),
    ((0, 1, 0), (1, 0, 0), (0, 0, -1), 255),
    ((0, -1, 0), (1, 0, 0), (0, 0, 1), 128),
    ((0, 0, 1), (1, 0, 0), (0, 1, 0), 204),
    ((0, 0, -1), (-1, 0, 0), (0, 1, 0), 166),
]


def box(name, hx, hy, hz):
    m = Mesh(name)
    for n, u, v, tone in FACES:
        def at(su, sv):
            return tuple(n[i] * (hx, hy, hz)[i] + su * u[i] * (hx, hy, hz)[i]
                         + sv * v[i] * (hx, hy, hz)[i] for i in range(3))
        m.quad([at(-1, -1), at(1, -1), at(1, 1), at(-1, 1)], n,
               [(0, 1), (1, 1), (1, 0), (0, 0)], [(tone, tone, tone, 255)] * 4)
    return m


def floor(half, repeats):
    m = Mesh("floor")
    m.quad([(-half, 0, half), (half, 0, half), (half, 0, -half), (-half, 0, -half)], (0, 1, 0),
           [(0, repeats), (repeats, repeats), (repeats, 0), (0, 0)], [(255, 255, 255, 255)] * 4)
    return m


def wall(half_width, height):
    """Facing +Z, standing on y = 0. Two metres of brick per texture repeat."""
    m = Mesh("wall")
    top, bottom = (255, 255, 255, 255), (150, 150, 150, 255)
    m.quad([(-half_width, 0, 0), (half_width, 0, 0), (half_width, height, 0), (-half_width, height, 0)],
           (0, 0, 1),
           [(0, height), (half_width, height), (half_width, 0), (0, 0)],
           [bottom, bottom, top, top])
    return m


def leaves(size, count):
    """`count` vertical quads crossed about +Y, sharing the one leaf texture."""
    m = Mesh("leaves")
    h = size / 2
    for i in range(count):
        t = math.pi * i / count
        c, s = math.cos(t), math.sin(t)
        normal = (s, 0.0, c)
        m.quad([(-h * c, 0, h * s), (h * c, 0, -h * s), (h * c, size, -h * s), (-h * c, size, h * s)],
               normal, [(0, 1), (1, 1), (1, 0), (0, 0)], [(255, 255, 255, 255)] * 4)
    return m


def pane(half_width, height):
    m = Mesh("pane")
    white = (255, 255, 255, 255)
    m.quad([(-half_width, 0, 0), (half_width, 0, 0), (half_width, height, 0), (-half_width, height, 0)],
           (0, 0, 1), [(0, 1), (1, 1), (1, 0), (0, 0)], [white] * 4)
    return m


# -- the glTF writer -----------------------------------------------------------------

class Gltf:
    def __init__(self, bin_name):
        self.bin_name = bin_name
        self.buffer = bytearray()
        self.doc = {
            "asset": {"version": "2.0", "generator": "Foundry scripts/m20/make_scene.py"},
            "scene": 0,
            "scenes": [{"nodes": []}],
            "nodes": [],
            "meshes": [],
            "materials": [],
            "textures": [],
            "images": [],
            "samplers": [{"magFilter": LINEAR, "minFilter": LINEAR_MIPMAP_LINEAR, "wrapS": REPEAT, "wrapT": REPEAT}],
            "accessors": [],
            "bufferViews": [],
            # M22 Step 2 imports ordinary glTF materials as lit; this sample stays
            # explicitly unlit until its lit content is authored in Step 7.
            "extensionsUsed": ["KHR_materials_unlit"],
            "buffers": [],
        }
        self.images = {}

    def view(self, data: bytes, target):
        while len(self.buffer) % 4:
            self.buffer.append(0)
        self.doc["bufferViews"].append({"buffer": 0, "byteOffset": len(self.buffer), "byteLength": len(data), "target": target})
        self.buffer.extend(data)
        return len(self.doc["bufferViews"]) - 1

    def accessor(self, data, component, count, kind, normalized=False, bounds=None):
        target = ELEMENT_ARRAY_BUFFER if kind == "SCALAR" else ARRAY_BUFFER
        entry = {"bufferView": self.view(data, target), "componentType": component, "count": count, "type": kind}
        if normalized:
            entry["normalized"] = True
        if bounds:
            entry["min"], entry["max"] = bounds
        self.doc["accessors"].append(entry)
        return len(self.doc["accessors"]) - 1

    def texture(self, uri):
        if uri not in self.images:
            self.doc["images"].append({"uri": uri})
            self.doc["textures"].append({"sampler": 0, "source": len(self.doc["images"]) - 1})
            self.images[uri] = len(self.doc["textures"]) - 1
        return self.images[uri]

    def material(self, name, colour=(1, 1, 1, 1), texture=None, alpha="OPAQUE", cutoff=None, double_sided=False):
        pbr = {"baseColorFactor": list(colour)}
        if texture:
            pbr["baseColorTexture"] = {"index": self.texture(texture)}
        entry = {"name": name, "pbrMetallicRoughness": pbr, "extensions": {"KHR_materials_unlit": {}}}
        if alpha != "OPAQUE":
            entry["alphaMode"] = alpha
        if cutoff is not None:
            entry["alphaCutoff"] = cutoff
        if double_sided:
            entry["doubleSided"] = True
        self.doc["materials"].append(entry)
        return len(self.doc["materials"]) - 1

    def mesh(self, m: Mesh, material, uvs=True, colours=True):
        n = len(m.positions)
        lo = [min(p[i] for p in m.positions) for i in range(3)]
        hi = [max(p[i] for p in m.positions) for i in range(3)]
        attributes = {
            "POSITION": self.accessor(b"".join(struct.pack("<3f", *p) for p in m.positions), FLOAT, n, "VEC3", bounds=(lo, hi)),
            "NORMAL": self.accessor(b"".join(struct.pack("<3f", *v) for v in m.normals), FLOAT, n, "VEC3"),
        }
        if uvs:
            attributes["TEXCOORD_0"] = self.accessor(b"".join(struct.pack("<2f", *t) for t in m.uvs), FLOAT, n, "VEC2")
        if colours:
            attributes["COLOR_0"] = self.accessor(b"".join(struct.pack("<4B", *c) for c in m.colours), UNSIGNED_BYTE, n, "VEC4", normalized=True)
        indices = self.accessor(b"".join(struct.pack("<H", i) for i in m.indices), UNSIGNED_SHORT, len(m.indices), "SCALAR")
        self.doc["meshes"].append({"name": m.name, "primitives": [{"attributes": attributes, "indices": indices, "material": material}]})
        return len(self.doc["meshes"]) - 1

    def node(self, name, mesh=None, t=None, r=None, s=None, children=None, root=True):
        entry = {"name": name}
        if mesh is not None:
            entry["mesh"] = mesh
        if t:
            entry["translation"] = list(t)
        if r:
            entry["rotation"] = list(r)
        if s:
            entry["scale"] = list(s)
        if children:
            entry["children"] = children
        self.doc["nodes"].append(entry)
        index = len(self.doc["nodes"]) - 1
        if root:
            self.doc["scenes"][0]["nodes"].append(index)
        return index

    def write(self, stem):
        # Empty arrays are left out, as an exporter would.
        doc = {k: v for k, v in self.doc.items() if v != []}
        doc["buffers"] = [{"uri": self.bin_name, "byteLength": len(self.buffer)}]
        with open(os.path.join(OUT, stem + ".gltf"), "w", newline="\n") as f:
            json.dump(doc, f, indent=2)
            f.write("\n")
        with open(os.path.join(OUT, self.bin_name), "wb") as f:
            f.write(bytes(self.buffer))


def about_y(angle):
    return (0.0, math.sin(angle / 2), 0.0, math.cos(angle / 2))


def room():
    g = Gltf("room.bin")
    floor_mat = g.material("Floor", texture="checker.png")
    brick_mat = g.material("Brick", texture="brick.png")
    wood_mat = g.material("Wood", colour=(0.42, 0.25, 0.12, 1.0))
    crate_mat = g.material("Crate", texture="crate.png")
    pot_mat = g.material("Pot", colour=(0.55, 0.22, 0.10, 1.0))
    leaf_mat = g.material("Leaf", texture="leaf.png", alpha="MASK", cutoff=0.5, double_sided=True)
    glass_mat = g.material("Glass", colour=(0.55, 0.75, 0.85, 0.35), alpha="BLEND", double_sided=True)

    g.node("Floor", g.mesh(floor(3.0, 6.0), floor_mat))

    wall_mesh = g.mesh(wall(3.0, 1.2), brick_mat)
    g.node("WallNorth", wall_mesh, t=(0, 0, -3))
    g.node("WallSouth", wall_mesh, t=(0, 0, 3), r=about_y(math.pi))
    g.node("WallWest", wall_mesh, t=(-3, 0, 0), r=about_y(math.pi / 2))
    g.node("WallEast", wall_mesh, t=(3, 0, 0), r=about_y(-math.pi / 2))

    # The table: its legs are the top's children, placed in the top's frame.
    leg_mesh = g.mesh(box("leg", 0.03, 0.36, 0.03), wood_mat)
    legs = [g.node("Leg%d" % i, leg_mesh, t=(x, -0.39, z), root=False)
            for i, (x, z) in enumerate([(-0.62, -0.38), (0.62, -0.38), (-0.62, 0.38), (0.62, 0.38)])]
    g.node("TableTop", g.mesh(box("tabletop", 0.7, 0.03, 0.45), wood_mat), t=(0, 0.75, 0), children=legs)

    crate_mesh = g.mesh(box("crate", 0.35, 0.35, 0.35), crate_mat)
    g.node("Crate", crate_mesh, t=(1.9, 0.35, -1.0), r=about_y(0.5))
    g.node("CrateMirrored", crate_mesh, t=(1.9, 0.35, -2.0), r=about_y(0.5), s=(-1, 1, 1))

    g.node("Pot", g.mesh(box("pot", 0.18, 0.16, 0.18), pot_mat), t=(-1.9, 0.16, 1.7))
    g.node("Plant", g.mesh(leaves(0.9, 3), leaf_mat), t=(-1.9, 0.32, 1.7))

    g.node("Glass", g.mesh(pane(0.6, 1.0), glass_mat, uvs=False, colours=False), t=(0, 0, 1.3))
    g.write("room")


def crate_model():
    g = Gltf("crate.bin")
    g.node("Crate", g.mesh(box("crate", 0.4, 0.4, 0.4), g.material("Crate", texture="crate.png")), t=(0, 0.4, 0))
    g.write("crate")


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, width, height, pixel in [
        ("checker.png", 64, 64, checker),
        ("brick.png", 64, 32, brick),
        ("crate.png", 64, 64, crate),
        ("leaf.png", 64, 64, leaf),
    ]:
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(png(width, height, pixel))
    room()
    crate_model()


if __name__ == "__main__":
    main()
