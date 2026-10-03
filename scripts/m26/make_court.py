#!/usr/bin/env python3
"""Deterministic court geometry and models. Python is a developer tool, never a build input.

Run to regenerate committed assets, or --check to compare without writing.
Metres, +Y up, -Z forward, CCW triangles (ADR-0048).
"""
import argparse
import json
import math
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


def generate_court():
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


def generate_prop(stem, boxes, material_name, color, roughness=0.8):
    frames = [((1, 0, 0), (0, 0, -1), (0, 1, 0)),
              ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
              ((0, 1, 0), (1, 0, 0), (0, 0, -1)),
              ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
              ((0, 0, 1), (1, 0, 0), (0, 1, 0)),
              ((0, 0, -1), (-1, 0, 0), (0, 1, 0))]
    positions, normals, indices = [], [], []
    for centre, half in boxes:
        for normal, u, v in frames:
            base = len(positions)
            for su, sv in [(-1, -1), (1, -1), (1, 1), (-1, 1)]:
                positions.append(tuple(centre[k] + half[k] * (normal[k] + su*u[k] + sv*v[k]) for k in range(3)))
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
        entry = {"bufferView": len(views)-1, "componentType": component, "count": len(values), "type": kind}
        if bounds:
            entry.update(min=[min(p[k] for p in values) for k in range(width)],
                         max=[max(p[k] for p in values) for k in range(width)])
        accessors.append(entry)
        return len(accessors)-1

    attrs = {"POSITION": accessor(positions, 3, "f", 5126, "VEC3", True),
             "NORMAL": accessor(normals, 3, "f", 5126, "VEC3")}
    index = accessor([(i,) for i in indices], 1, "H", 5123, "SCALAR")
    document = {
        "asset": {"version": "2.0", "generator": "Foundry M26"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": stem.title(), "mesh": 0}],
        "meshes": [{"primitives": [{"attributes": attrs, "indices": index, "material": 0}]}],
        "materials": [{"name": material_name, "pbrMetallicRoughness": {
            "baseColorFactor": color, "metallicFactor": 0, "roughnessFactor": roughness}}],
        "buffers": [{"uri": stem + ".bin", "byteLength": len(binary)}],
        "bufferViews": views, "accessors": accessors,
    }
    return {
        stem + ".gltf": (json.dumps(document, indent=2) + "\n").encode(),
        stem + ".bin": bytes(binary),
    }


def generate_warden():
    joints = [
        ("pelvis", -1, (0, .85, 0)), ("spine", 0, (0, 1.1, 0)),
        ("chest", 1, (0, 1.35, 0)), ("neck", 2, (0, 1.48, 0)),
        ("head", 3, (0, 1.6, 0)),
        ("shoulder.L", 2, (-.25, 1.35, 0)), ("elbow.L", 5, (-.3, 1.05, 0)),
        ("wrist.L", 6, (-.3, .8, 0)), ("hand.L", 7, (-.3, .74, 0)),
        ("shoulder.R", 2, (.25, 1.35, 0)), ("elbow.R", 9, (.3, 1.05, 0)),
        ("wrist.R", 10, (.3, .8, 0)), ("hand.R", 11, (.3, .74, 0)),
        ("hip.L", 0, (-.12, .85, 0)), ("knee.L", 13, (-.12, .45, 0)),
        ("foot.L", 14, (-.12, .08, 0)),
        ("hip.R", 0, (.12, .85, 0)), ("knee.R", 16, (.12, .45, 0)),
        ("foot.R", 17, (.12, .08, 0)),
    ]
    nodes = []
    for name, parent, p in joints:
        origin = joints[parent][2] if parent >= 0 else (0, 0, 0)
        nodes.append({"name": name, "translation": [p[i]-origin[i] for i in range(3)]})
    for i, (_, parent, _) in enumerate(joints):
        if parent >= 0:
            nodes[parent].setdefault("children", []).append(i)
    nodes.append({"name": "Warden", "mesh": 0, "skin": 0})
    positions, normals, influences, weights, indices = [], [], [], [], []
    blocks = [(0, (0, .9, 0), (.22, .12, .13)),
              (1, (0, 1.18, 0), (.21, .2, .12)),
              (4, (0, 1.6, -.01), (.12, .1, .12))]
    for j in (6, 7, 10, 11, 14, 15, 17, 18):
        parent = joints[j][1]
        a, b = joints[parent][2], joints[j][2]
        blocks.append((j, tuple((a[k]+b[k])/2 for k in range(3)),
                       (.065 if j < 13 else .08, abs(a[1]-b[1])/2, .07)))
    for j in (8, 12, 15, 18):
        p = joints[j][2]
        blocks.append((j, (p[0], p[1], p[2]-.055), (.07, .06, .13)))
    frames = [((1,0,0),(0,0,-1),(0,1,0)), ((-1,0,0),(0,0,1),(0,1,0)),
              ((0,1,0),(1,0,0),(0,0,-1)), ((0,-1,0),(1,0,0),(0,0,1)),
              ((0,0,1),(1,0,0),(0,1,0)), ((0,0,-1),(-1,0,0),(0,1,0))]
    for j, centre, half in blocks:
        parent = max(0, joints[j][1])
        for n, u, v in frames:
            base = len(positions)
            for su, sv in ((-1,-1),(1,-1),(1,1),(-1,1)):
                p = tuple(centre[k]+half[k]*(n[k]+su*u[k]+sv*v[k]) for k in range(3))
                positions.append(p)
                normals.append(n)
                distal = .15 if p[1] > centre[1] else .85
                if parent == j:
                    distal = 1
                influences.append((j, parent, 0, 0))
                weights.append((distal, 1-distal, 0, 0))
            indices.extend((base,base+1,base+2,base,base+2,base+3))
    binary, views, accessors = bytearray(), [], []

    def accessor(values, width, fmt, component, kind, bounds=False):
        while len(binary) % 4:
            binary.append(0)
        start = len(binary)
        for value in values:
            binary.extend(struct.pack("<"+fmt*width, *value))
        views.append({"buffer": 0, "byteOffset": start, "byteLength": len(binary)-start})
        a = {"bufferView": len(views)-1, "componentType": component,
             "count": len(values), "type": kind}
        if bounds:
            a.update(min=[min(v[k] for v in values) for k in range(width)],
                     max=[max(v[k] for v in values) for k in range(width)])
        accessors.append(a)
        return len(accessors)-1

    attrs = {"POSITION": accessor(positions,3,"f",5126,"VEC3",True),
             "NORMAL": accessor(normals,3,"f",5126,"VEC3"),
             "JOINTS_0": accessor(influences,4,"B",5121,"VEC4"),
             "WEIGHTS_0": accessor(weights,4,"f",5126,"VEC4")}
    index = accessor([(i,) for i in indices],1,"H",5123,"SCALAR")
    binds = []
    for _, _, p in joints:
        binds.append((1,0,0,0, 0,1,0,0, 0,0,1,0, -p[0],-p[1],-p[2],1))
    bind = accessor(binds,16,"f",5126,"MAT4")
    animations = []
    for name in ("idle", "walk"):
        times = accessor([(i/8,) for i in range(9)],1,"f",5126,"SCALAR",True)
        samplers, channels = [], []
        for j in (1,5,6,9,10,13,14,16,17):
            values = []
            for i in range(9):
                phase = 2*math.pi*i/8
                if name == "idle":
                    angle = .025*math.sin(phase) if j in (1,5,9) else 0
                else:
                    sign = -1 if j in (9,16,17) else 1
                    angle = sign*.4*math.sin(phase) if j in (5,9,13,16) else (
                        .45*max(0,sign*math.sin(phase)) if j in (14,17) else .12)
                    if j == 1:
                        angle = .025*math.sin(phase)
                values.append((math.sin(angle/2),0,0,math.cos(angle/2)))
            output = accessor(values,4,"f",5126,"VEC4")
            samplers.append({"input": times,"output": output,"interpolation":"LINEAR"})
            channels.append({"sampler":len(samplers)-1,"target":{"node":j,"path":"rotation"}})
        animations.append({"name":name,"samplers":samplers,"channels":channels})
    document = {"asset":{"version":"2.0","generator":"Foundry M26"},
                "scene":0,"scenes":[{"nodes":[0,19]}],"nodes":nodes,
                "skins":[{"joints":list(range(19)),"skeleton":0,"inverseBindMatrices":bind}],
                "animations":animations,"meshes":[{"primitives":[{"attributes":attrs,"indices":index,"material":0}]}],
                "materials":[{"name":"Warden","pbrMetallicRoughness":{"baseColorFactor":[.6,.2,.2,1],"metallicFactor":0,"roughnessFactor":.7}}],
                "buffers":[{"uri":"warden.bin","byteLength":len(binary)}],
                "bufferViews":views,"accessors":accessors}
    return {
        "warden.gltf": (json.dumps(document, indent=2) + "\n").encode(),
        "warden.bin": bytes(binary),
    }


def generate():
    products = {}
    products.update(generate_court())
    products.update(generate_prop("beacon", [
        ((0, .1, 0), (.35, .1, .35)),
        ((0, .5, 0), (.18, .3, .18)),
        ((0, .9, 0), (.28, .1, .28)),
    ], "Beacon", [.5, .45, .4, 1], roughness=.8))
    products.update(generate_prop("gate", [
        ((0, 1.25, 0), (1.0, 1.25, 0.08)),
    ], "Gate", [.35, .3, .25, 1], roughness=.7))
    products.update(generate_warden())
    return products


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    products = generate()
    if args.check:
        for name, expected in products.items():
            path = OUT / name
            if not path.exists() or path.read_bytes() != expected:
                raise SystemExit(f"generated asset differs or missing: {name}")
        print(f"court: {len(products)} generated assets match byte for byte")
    else:
        OUT.mkdir(parents=True, exist_ok=True)
        for name, contents in products.items():
            (OUT / name).write_bytes(contents)
        print(f"court: wrote {len(products)} assets")


if __name__ == "__main__":
    main()
