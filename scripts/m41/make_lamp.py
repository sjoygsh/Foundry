#!/usr/bin/env python3
"""Generate the 3D sandbox's M41 lamp (`docs/design/environment.md` §11).

Foundry's own content, under the repository's licence. The output is committed beside M20's
models; this script exists so the binary is reproducible, the bargain `scripts/m20/make_scene.py`
makes, whose glTF writer it borrows. It is a developer tool and never part of the build
(CLAUDE.md §4.4), and it writes no other milestone's files, so their pins cannot move.

What it writes into samples/sandbox3d/content/models/:

  lamp.glb  a standing lamp, its foot at the origin: a square foot, a post, an arm along +X and a
            shade at its end, 2.1 m up. One `KHR_lights_punctual` spot hangs under the shade,
            pointing down, named "Lamp", which `foundry:model_import`'s `lights` makes a shadow
            caster. The metal parts carry a normal map of raised rings and no TANGENT, so the
            import generates MikkTSpace tangents for them (ADR-0086). The PNG is in the GLB's BIN
            chunk, so the lamp is one file.

Nothing here reads a clock or `random`: the same script writes the same bytes everywhere.
Run from the repository root.
"""

import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "m20"))
from make_scene import Gltf, box, png  # noqa: E402

OUT = os.path.join("samples", "sandbox3d", "content", "models")
NORMAL_SIZE = 64


def rings(x, y):
    """A tangent-space normal map of raised rings, encoded as glTF stores it: (n + 1) / 2."""
    u = (x + 0.5) / NORMAL_SIZE * 2 - 1
    v = (y + 0.5) / NORMAL_SIZE * 2 - 1
    r = math.hypot(u, v)
    # The height is a sine of the radius, three rings across, so the slope is its derivative.
    slope = 0.35 * math.cos(r * 3 * math.pi)
    dx = slope * (u / r) if r > 1e-6 else 0.0
    dy = slope * (v / r) if r > 1e-6 else 0.0
    n = (-dx, dy, 1.0)
    length = math.sqrt(sum(c * c for c in n))
    return bytes(max(0, min(255, round((c / length * 0.5 + 0.5) * 255))) for c in n) + b"\xff"


def moved(m, offset):
    m.positions = [tuple(p[i] + offset[i] for i in range(3)) for p in m.positions]
    return m


def lamp():
    g = Gltf("lamp.bin")
    # The PNG goes in the BIN chunk, by a view with no target, as an exporter writes it.
    image = png(NORMAL_SIZE, NORMAL_SIZE, rings)
    while len(g.buffer) % 4:
        g.buffer.append(0)
    g.doc["bufferViews"].append({"buffer": 0, "byteOffset": len(g.buffer), "byteLength": len(image)})
    g.buffer.extend(image)
    g.doc["images"].append({"bufferView": len(g.doc["bufferViews"]) - 1, "mimeType": "image/png"})
    g.doc["textures"].append({"sampler": 0, "source": len(g.doc["images"]) - 1})
    normal_texture = len(g.doc["textures"]) - 1

    g.doc["materials"].append({
        "name": "Metal",
        "pbrMetallicRoughness": {"baseColorFactor": [0.55, 0.5, 0.42, 1.0], "metallicFactor": 1.0, "roughnessFactor": 0.35},
        "normalTexture": {"index": normal_texture},
    })
    metal = len(g.doc["materials"]) - 1
    g.doc["materials"].append({
        "name": "Shade",
        "pbrMetallicRoughness": {"baseColorFactor": [0.9, 0.82, 0.62, 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.8},
        "emissiveFactor": [1.0, 0.78, 0.45],
    })
    shade = len(g.doc["materials"]) - 1

    foot = g.mesh(moved(box("foot", 0.2, 0.025, 0.2), (0, 0.025, 0)), metal, colours=False)
    post = g.mesh(moved(box("post", 0.025, 1.05, 0.025), (0, 1.1, 0)), metal, colours=False)
    arm = g.mesh(moved(box("arm", 0.2, 0.02, 0.02), (0.2, 2.13, 0)), metal, colours=False)
    hood = g.mesh(moved(box("shade", 0.12, 0.08, 0.12), (0.4, 2.05, 0)), shade, colours=False)

    # A spot, pointing down: its -Z turned a quarter about +X onto -Y.
    g.doc["extensionsUsed"] = ["KHR_lights_punctual"]
    g.doc["extensions"] = {"KHR_lights_punctual": {"lights": [{
        "name": "Lamp",
        "type": "spot",
        "color": [1.0, 0.85, 0.62],
        "intensity": 90.0,
        "range": 6.0,
        "spot": {"innerConeAngle": 0.45, "outerConeAngle": 0.75},
    }]}}
    half = math.sqrt(0.5)
    light = g.node("LampLight", t=(0.4, 1.96, 0), r=(-half, 0.0, 0.0, half), root=False)
    g.doc["nodes"][light]["extensions"] = {"KHR_lights_punctual": {"light": 0}}
    parts = [g.node(name, mesh, root=False) for name, mesh in (("Foot", foot), ("Post", post), ("Arm", arm), ("Shade", hood))]
    g.node("Lamp", children=parts + [light])
    return g


def write_glb(g, stem):
    doc = {k: v for k, v in g.doc.items() if v != []}
    while len(g.buffer) % 4:
        g.buffer.append(0)
    doc["buffers"] = [{"byteLength": len(g.buffer)}]
    text = json.dumps(doc, separators=(",", ":")).encode()
    while len(text) % 4:
        text += b" "
    body = (struct.pack("<II", len(text), 0x4E4F534A) + text
            + struct.pack("<II", len(g.buffer), 0x004E4942) + bytes(g.buffer))
    with open(os.path.join(OUT, stem + ".glb"), "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)


if __name__ == "__main__":
    write_glb(lamp(), "lamp")
