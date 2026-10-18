#!/usr/bin/env python3
"""M27's gallery: eight large textures on framed panels, the workload background loading moves.

Python is a developer tool, never a build input. Run to regenerate the committed files, or
--check to compare them byte for byte without writing (`docs/design/background.md` §11).

Each texture is 2048x2048 sRGB RGBA with mipmaps (the import's default). The patterns are
periodic in every row, so zlib keeps the committed bytes small while the decoded pixels,
16 MiB each before mips, are what a load has to make. The panels stand in a ring of radius
7 m above the crate grid, facing the room, so the orbiting camera always has some in view.
Metres, +Y up, -Z forward, CCW triangles (ADR-0048). No collision: the gallery is only drawn.
"""
import argparse
import json
import math
from pathlib import Path
import struct
import zlib

CONTENT = Path(__file__).resolve().parents[2] / "samples/sandbox3d/content"
SIZE = 2048
BORDER = 48
PANELS = 8
RADIUS = 7.0
CENTRE_Y = 2.4
HALF = 0.9           # the picture's half width and height
FRAME = 0.1          # how far the frame stands out around it
DEPTH = 0.05         # the frame's half depth

# Two colours, a stripe period in pixels and a slope per panel: distinct at a glance.
DESIGNS = [
    ((196, 72, 52), (238, 196, 120), 64, 1),
    ((40, 92, 150), (200, 220, 236), 96, -1),
    ((54, 120, 70), (220, 214, 150), 48, 2),
    ((120, 52, 120), (236, 170, 210), 128, -2),
    ((28, 28, 32), (230, 230, 220), 32, 1),
    ((200, 140, 30), (60, 40, 20), 80, -1),
    ((30, 130, 140), (250, 240, 200), 112, 3),
    ((150, 30, 40), (30, 30, 60), 56, -3),
]
FRAME_COLOUR = (52, 36, 26)


def png(design):
    """One RGBA PNG of diagonal stripes inside a plain border, written without a filter."""
    a, b, period, slope = design
    border_px = bytes(FRAME_COLOUR) + b"\xff"
    stripe = b"".join(bytes(a if (x % period) < period // 2 else b) + b"\xff" for x in range(period))
    span = stripe * (SIZE // period + 2)
    inner = SIZE - 2 * BORDER
    edge_row = b"\0" + border_px * SIZE
    rows = []
    for y in range(SIZE):
        if y < BORDER or y >= SIZE - BORDER:
            rows.append(edge_row)
            continue
        shift = ((y * slope) % period) * 4
        rows.append(b"\0" + border_px * BORDER + span[shift:shift + inner * 4] + border_px * BORDER)
    raw = b"".join(rows)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def add(p, q, s=1.0):
    return tuple(p[k] + s * q[k] for k in range(3))


def generate_model():
    binary, views, accessors, meshes, nodes = bytearray(), [], [], [], []

    def accessor(values, width, fmt, component, kind, bounds=False):
        while len(binary) % 4:
            binary.append(0)
        start = len(binary)
        for value in values:
            binary.extend(struct.pack("<" + fmt * width, *value))
        views.append({"buffer": 0, "byteOffset": start, "byteLength": len(binary) - start})
        entry = {"bufferView": len(views) - 1, "componentType": component, "count": len(values), "type": kind}
        if bounds:
            entry.update(min=[min(v[k] for v in values) for k in range(width)],
                         max=[max(v[k] for v in values) for k in range(width)])
        accessors.append(entry)
        return len(accessors) - 1

    def primitive(positions, normals, uv, indices, material):
        attributes = {"POSITION": accessor(positions, 3, "f", 5126, "VEC3", True),
                      "NORMAL": accessor(normals, 3, "f", 5126, "VEC3"),
                      "TEXCOORD_0": accessor(uv, 2, "f", 5126, "VEC2")}
        return {"attributes": attributes, "indices": accessor([(i,) for i in indices], 1, "H", 5123, "SCALAR"),
                "material": material}

    for k in range(PANELS):
        angle = (k + 0.5) * 2 * math.pi / PANELS
        out = (math.sin(angle), 0.0, math.cos(angle))
        inward = (-out[0], 0.0, -out[2])
        right = (-out[2], 0.0, out[0])   # the viewer's right, looking out from the room
        up = (0.0, 1.0, 0.0)
        centre = (RADIUS * out[0], CENTRE_Y, RADIUS * out[2])

        # The picture: one quad just in front of the frame, facing the room.
        face = add(centre, inward, DEPTH + 0.001)
        positions, normals, uv = [], [], []
        for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            positions.append(add(add(face, right, su * HALF), up, sv * HALF))
            normals.append(inward)
            uv.append(((su + 1) / 2, (1 - sv) / 2))
        picture = primitive(positions, normals, uv, [0, 1, 2, 0, 2, 3], k)

        # The frame: a box in the basis (right, up, inward), which is right-handed.
        half = (HALF + FRAME, HALF + FRAME, DEPTH)
        local = [((1, 0, 0), (0, 0, -1), (0, 1, 0)), ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
                 ((0, 1, 0), (1, 0, 0), (0, 0, -1)), ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
                 ((0, 0, 1), (1, 0, 0), (0, 1, 0)), ((0, 0, -1), (-1, 0, 0), (0, 1, 0))]

        def world(v):
            return tuple(v[0] * right[i] + v[1] * up[i] + v[2] * inward[i] for i in range(3))
        positions, normals, uv, indices = [], [], [], []
        for normal, u, v in local:
            base = len(positions)
            for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                corner = tuple(half[i] * (normal[i] + su * u[i] + sv * v[i]) for i in range(3))
                positions.append(add(centre, world(corner)))
                normals.append(world(normal))
                uv.append(((su + 1) / 2, (sv + 1) / 2))
            indices.extend((base, base + 1, base + 2, base, base + 2, base + 3))
        frame = primitive(positions, normals, uv, indices, PANELS)

        nodes.append({"name": f"Panel{k}", "mesh": len(meshes)})
        meshes.append({"primitives": [frame, picture]})

    materials = [{"name": f"Picture{k}", "pbrMetallicRoughness": {
        "baseColorTexture": {"index": k}, "metallicFactor": 0, "roughnessFactor": 0.9}} for k in range(PANELS)]
    materials.append({"name": "Frame", "pbrMetallicRoughness": {
        "baseColorFactor": [((c / 255) ** 2.2) for c in FRAME_COLOUR] + [1], "metallicFactor": 0, "roughnessFactor": 0.7}})
    document = {
        "asset": {"version": "2.0", "generator": "Foundry M27"}, "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}], "nodes": nodes, "meshes": meshes,
        "materials": materials,
        "textures": [{"source": k} for k in range(PANELS)],
        "images": [{"uri": f"gallery{k}.png"} for k in range(PANELS)],
        "buffers": [{"uri": "gallery.bin", "byteLength": len(binary)}],
        "bufferViews": views, "accessors": accessors,
    }
    return (json.dumps(document, indent=2) + "\n").encode(), bytes(binary)


RECORD = """# M27's gallery (`docs/design/background.md` §11): eight 2048x2048 textures on framed
# panels, generated by scripts/m27/make_gallery.py. Nothing draws it until the sample asks for
# it, on a fixed tick or on G, so it is the load the background path exists to move off the
# frame. It has no collision and no rule; it is only drawn.
foundry:model_import sandbox3d:models.gallery { source "models/gallery.gltf" }
""".encode()


def generate():
    gltf, binary = generate_model()
    products = {"models/gallery.gltf": gltf, "models/gallery.bin": binary, "gallery.fdt": RECORD}
    for k, design in enumerate(DESIGNS):
        products[f"models/gallery{k}.png"] = png(design)
    return products


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    products = generate()
    total = sum(len(contents) for contents in products.values())
    if total > 2 * 1024 * 1024:
        raise SystemExit(f"gallery: {total} bytes is over its 2 MiB bound")
    if args.check:
        for name, expected in products.items():
            path = CONTENT / name
            if not path.exists() or path.read_bytes() != expected:
                raise SystemExit(f"generated asset differs or missing: {name}")
        print(f"gallery: {len(products)} generated files match byte for byte ({total} bytes)")
    else:
        for name, contents in products.items():
            (CONTENT / name).parent.mkdir(parents=True, exist_ok=True)
            (CONTENT / name).write_bytes(contents)
        print(f"gallery: wrote {len(products)} files ({total} bytes)")


if __name__ == "__main__":
    main()
