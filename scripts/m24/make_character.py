#!/usr/bin/env python3
"""Foundry's plain 1.7 m, 19-joint walker. No downloads; deterministic glTF 2.0.

Run from any directory. The 1-second walk cycle's ~0.6 m stride agrees with
walker.main's 0.6 m/s; feet stay in model space (no root motion).
"""
import json
import math
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "samples/sandbox3d/content/models"


def generate():
    # Parent-first, model-space joint centres. Forward is -Z, metres, +Y up.
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
    nodes.append({"name": "Walker", "mesh": 0, "skin": 0})
    positions, normals, influences, weights, indices = [], [], [], [], []
    # A block per segment. The two rings at a joint blend parent/child weights,
    # rather than giving rigid boxes disjoint one-joint skins.
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
                # Upper ring follows the proximal joint; lower follows distal,
                # with a small overlap that makes bending visible at each seam.
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
    document = {"asset":{"version":"2.0","generator":"Foundry M24"},
                "scene":0,"scenes":[{"nodes":[0,19]}],"nodes":nodes,
                "skins":[{"joints":list(range(19)),"skeleton":0,"inverseBindMatrices":bind}],
                "animations":animations,"meshes":[{"primitives":[{"attributes":attrs,"indices":index,"material":0}]}],
                "materials":[{"name":"Walker","pbrMetallicRoughness":{"baseColorFactor":[.16,.58,.68,1],"metallicFactor":0,"roughnessFactor":.7}}],
                "buffers":[{"uri":"walker.bin","byteLength":len(binary)}],
                "bufferViews":views,"accessors":accessors}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/"walker.bin").write_bytes(binary)
    (OUT/"walker.gltf").write_text(json.dumps(document, indent=2)+"\n")
    print(f"walker: {len(joints)} joints, {len(positions)} vertices, idle/walk; {len(binary)} bytes")


if __name__ == "__main__":
    generate()
