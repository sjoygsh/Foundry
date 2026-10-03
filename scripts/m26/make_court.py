#!/usr/bin/env python3
"""Deterministic court geometry. Python is a developer tool, never a build input.

Run to regenerate committed assets, or --check to compare without writing.
Metres, +Y up, -Z forward, CCW triangles (ADR-0048).
"""
import argparse
import json
from pathlib import Path
import struct
import zlib

OUT = Path(__file__).resolve().parents[2] / "samples/court/content/models"


def png(colors):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + b"".join(bytes(colors[(x + y) % 2]) for x in range(8)) for y in range(8))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def generate():
    boxes = [
        ("CourtFloor", (0, -.2, 3), (6, .2, 5), 0),
        ("Ledge", (0, -.2, -5.35), (6, .2, 2.15), 0),
        ("PitFloor", (0, -4.7, -2.6), (6, .2, .6), 1),
        ("West", (-6.2, 1.3, 0), (.2, 1.3, 8), 1),
        ("East", (6.2, 1.3, 0), (.2, 1.3, 8), 1),
        ("South", (0, 1.3, 8.2), (6.4, 1.3, .2), 1),
        ("NorthLeft", (-3.75, 1.3, -7.7), (2.75, 1.3, .2), 1),
        ("NorthRight", (3.75, 1.3, -7.7), (2.75, 1.3, .2), 1),
        ("GateLintel", (0, 2.65, -7.7), (1, .15, .2), 1),
        ("ExitFloor", (0, -.2, -8.4), (1, .2, .9), 0),
        ("LowWall", (-3, .325, 1), (2, .325, .15), 1),
    ]
    frames = [((1,0,0),(0,0,-1),(0,1,0)), ((-1,0,0),(0,0,1),(0,1,0)),
              ((0,1,0),(1,0,0),(0,0,-1)), ((0,-1,0),(1,0,0),(0,0,1)),
              ((0,0,1),(1,0,0),(0,1,0)), ((0,0,-1),(-1,0,0),(0,1,0))]
    binary, views, accessors, meshes, nodes = bytearray(), [], [], [], []

    def accessor(values, width, fmt, component, kind, bounds=False):
        while len(binary) % 4:
            binary.append(0)
        start = len(binary)
        for value in values:
            binary.extend(struct.pack("<" + fmt * width, *value))
        views.append({"buffer": 0, "byteOffset": start, "byteLength": len(binary)-start})
        a = {"bufferView": len(views)-1, "componentType": component, "count": len(values), "type": kind}
        if bounds:
            a.update(min=[min(v[k] for v in values) for k in range(width)],
                     max=[max(v[k] for v in values) for k in range(width)])
        accessors.append(a)
        return len(accessors)-1

    for name, center, half, material in boxes:
        positions, normals, uv, indices = [], [], [], []
        for normal, u, v in frames:
            base = len(positions)
            for su, sv in ((-1,-1),(1,-1),(1,1),(-1,1)):
                positions.append(tuple(center[k] + half[k]*(normal[k] + su*u[k] + sv*v[k]) for k in range(3)))
                normals.append(normal)
                uv.append(((su+1)/2, (sv+1)/2))
            indices.extend((base, base+1, base+2, base, base+2, base+3))
        attributes = {"POSITION": accessor(positions,3,"f",5126,"VEC3",True),
                      "NORMAL": accessor(normals,3,"f",5126,"VEC3"),
                      "TEXCOORD_0": accessor(uv,2,"f",5126,"VEC2")}
        index = accessor([(i,) for i in indices],1,"H",5123,"SCALAR")
        nodes.append({"name": name, "mesh": len(meshes)})
        meshes.append({"primitives": [{"attributes": attributes, "indices": index, "material": material}]})
    document = {
        "asset": {"version": "2.0", "generator": "Foundry M26"}, "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}], "nodes": nodes, "meshes": meshes,
        "materials": [{"name": name, "pbrMetallicRoughness": {
            "baseColorTexture": {"index": i}, "metallicFactor": 0, "roughnessFactor": .85}}
            for i, name in enumerate(("Paving", "Stone"))],
        "textures": [{"source": 0}, {"source": 1}],
        "images": [{"uri": "paving.png"}, {"uri": "stone.png"}],
        "buffers": [{"uri": "court.bin", "byteLength": len(binary)}],
        "bufferViews": views, "accessors": accessors,
    }
    return {"court.gltf": (json.dumps(document, indent=2)+"\n").encode(),
            "court.bin": bytes(binary),
            "paving.png": png(((115,122,134,255), (90,97,110,255))),
            "stone.png": png(((145,130,105,255), (120,108,90,255)))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    products = generate()
    if args.check:
        for name, expected in products.items():
            if (OUT / name).read_bytes() != expected:
                raise SystemExit(f"generated asset differs: {name}")
        print(f"court: {len(products)} generated assets match byte for byte")
    else:
        OUT.mkdir(parents=True, exist_ok=True)
        for name, contents in products.items():
            (OUT / name).write_bytes(contents)
        print(f"court: wrote {len(products)} assets")


if __name__ == "__main__":
    main()
