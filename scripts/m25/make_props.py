#!/usr/bin/env python3
"""Reproduce M25's plain stone plinth glTF. No downloads or third-party modules."""
import json
from pathlib import Path
import struct

OUT = Path(__file__).resolve().parents[2] / "samples/sandbox3d/testdata/mods/plinth/models"


def generate(out=OUT, stem="plinth", boxes=None, material="Stone"):
    positions, normals, indices = [], [], []
    frames = [((1, 0, 0), (0, 0, -1), (0, 1, 0)),
              ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
              ((0, 1, 0), (1, 0, 0), (0, 0, -1)),
              ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
              ((0, 0, 1), (1, 0, 0), (0, 1, 0)),
              ((0, 0, -1), (-1, 0, 0), (0, 1, 0))]
    # Feet at y=0, a broad base, narrow shaft and cap. All faces wind CCW outside.
    for centre, half in boxes or [((0, .1, 0), (.6, .1, .6)),
                         ((0, .65, 0), (.4, .45, .4)),
                         ((0, 1.15, 0), (.55, .05, .55))]:
        for normal, u, v in frames:
            base = len(positions)
            for su, sv in [(-1, -1), (1, -1), (1, 1), (-1, 1)]:
                positions.append(tuple(centre[k] + half[k] *
                                       (normal[k] + su*u[k] + sv*v[k]) for k in range(3)))
                normals.append(normal)
            indices.extend([base, base+1, base+2, base, base+2, base+3])
    binary, views, accessors = bytearray(), [], []

    def accessor(values, width, fmt, component, kind, bounds=False):
        while len(binary) % 4:
            binary.append(0)
        start = len(binary)
        for value in values:
            binary.extend(struct.pack("<" + fmt*width, *value))
        views.append({"buffer": 0, "byteOffset": start, "byteLength": len(binary)-start})
        entry = {"bufferView": len(views)-1, "componentType": component,
                 "count": len(values), "type": kind}
        if bounds:
            entry.update(min=[min(p[k] for p in values) for k in range(width)],
                         max=[max(p[k] for p in values) for k in range(width)])
        accessors.append(entry)
        return len(accessors)-1

    attributes = {"POSITION": accessor(positions, 3, "f", 5126, "VEC3", True),
                  "NORMAL": accessor(normals, 3, "f", 5126, "VEC3")}
    index = accessor([(i,) for i in indices], 1, "H", 5123, "SCALAR")
    document = {"asset": {"version": "2.0", "generator": "Foundry M25"},
                "scene": 0, "scenes": [{"nodes": [0]}],
                "nodes": [{"name": stem.title(), "mesh": 0}],
                "meshes": [{"primitives": [{"attributes": attributes, "indices": index, "material": 0}]}],
                "materials": [{"name": material, "pbrMetallicRoughness": {
                    "baseColorFactor": [.42, .38, .32, 1], "metallicFactor": 0, "roughnessFactor": .9}}],
                "buffers": [{"uri": stem + ".bin", "byteLength": len(binary)}],
                "bufferViews": views, "accessors": accessors}
    out.mkdir(parents=True, exist_ok=True)
    (out / (stem + ".bin")).write_bytes(binary)
    (out / (stem + ".gltf")).write_text(json.dumps(document, indent=2) + "\n")
    print(f"{stem}: {len(positions)} vertices, {len(indices)//3} triangles; {len(binary)} bytes")


if __name__ == "__main__":
    generate()
    generate(OUT.parent.parent / "orbiter/models", "orbiter",
             [((0, 0, 0), (.4, .5, .25))], "Bronze")
