"""The walks M36 adds to the walker (`animation-ik.md` §11), for the strafer's blend `walk8`.

`scripts/m24/make_character.py` appends these after M35's four, so every clip before them, the mesh
and the skeleton keep their bytes. The joints, axes and keying are M34's (`scripts/m34/clips.py`):
forward is -Z, and a rotation about +X by a positive angle swings a hanging limb forward.

Eight walks, one a compass point of the figure's own frame (north is -Z, east +X). Each lasts a
second and travels its place on the grid in a lap: a cardinal walk 1 m, a diagonal one 1 m along each
axis. With `idle` in the middle they fill a 3 x 3 grid of metres a second, and since bilinear
weights reproduce a linear quantity exactly, the blend's travel anywhere on the grid is its
position. `stride`, at 0.6 m a lap, is not among them, and keeps its bytes.

Each is `stride`'s gait with its legs swung along the direction of travel, so a foot is down at 0
and halfway, as in `stride`.
"""
import importlib.util
import math
from pathlib import Path

_spec = importlib.util.spec_from_file_location("m34_clips", Path(__file__).resolve().parents[1]/"m34/clips.py")
m34 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m34)

SPINE = m34.SPINE
SHOULDER_L, ELBOW_L = m34.SHOULDER_L, m34.ELBOW_L
SHOULDER_R, ELBOW_R = m34.SHOULDER_R, m34.ELBOW_R
HIP_L, KNEE_L = m34.HIP_L, m34.KNEE_L
HIP_R, KNEE_R = m34.HIP_R, m34.KNEE_R
X = m34.X
axis_angle, wave = m34.axis_angle, m34.wave

# (name, metres east a lap, metres ahead a lap)
WALKS = (
    ("walk.n", 0, 1), ("walk.ne", 1, 1), ("walk.e", 1, 0), ("walk.se", 1, -1),
    ("walk.s", 0, -1), ("walk.sw", -1, -1), ("walk.w", -1, 0), ("walk.nw", -1, 1),
)

# `stride` swings its hips 0.4 rad for 0.6 m a lap. These swing in proportion, held to 0.45 so a
# leg swung sideways does not cross the other far.
MAX_SWING = .45


def walk(name, east, ahead):
    speed = math.hypot(east, ahead)
    # The axis that swings a hanging limb toward (east, -ahead) in model space.
    axis = (ahead/speed, 0, east/speed)
    swing = min(MAX_SWING, .4*speed/m34.STRIDE_METRES)
    # Arms swing with the forward part of the walk alone.
    arms = .4*ahead/speed
    rotations = {
        SPINE: lambda u: axis_angle(X, .025*wave(u)),
        SHOULDER_L: lambda u: axis_angle(X, arms*wave(u)),
        SHOULDER_R: lambda u: axis_angle(X, -arms*wave(u)),
        ELBOW_L: lambda u: axis_angle(X, .12),
        ELBOW_R: lambda u: axis_angle(X, .12),
        HIP_L: lambda u: axis_angle(axis, swing*wave(u)),
        HIP_R: lambda u: axis_angle(axis, -swing*wave(u)),
        KNEE_L: lambda u: axis_angle(X, .45*max(0, wave(u))),
        KNEE_R: lambda u: axis_angle(X, .45*max(0, -wave(u))),
    }
    bob = lambda u: m34.PELVIS_HEIGHT - .012*(1-math.cos(4*math.pi*u))/2
    return name, 1.0, rotations, lambda u: (east*u, bob(u), -ahead*u)


def animations(accessor):
    """The glTF animations, after M35's, written through the walker generator's own `accessor`."""
    return m34.build(accessor, tuple(walk(*entry) for entry in WALKS))
