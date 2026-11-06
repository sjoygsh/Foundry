"""The clips M35 adds to the walker and the warden (`animation-states.md` §12).

Both generators append these after M34's seven, so every clip before them, the mesh and the
skeleton keep their bytes. The joints, axes and keying are M34's (`scripts/m34/clips.py`): forward
is -Z, and a rotation about +X by a positive angle swings a hanging limb forward.

`run` is a body clip with root motion. `reach` moves the upper body only, for a layer under the set's
`upper` mask. `pant` and `look` are additive: each begins at rest, so its own first frame is the
reference its difference is taken from.
"""
import importlib.util
import math
from pathlib import Path

_spec = importlib.util.spec_from_file_location("m34_clips", Path(__file__).resolve().parents[1]/"m34/clips.py")
m34 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m34)

PELVIS, SPINE, CHEST = m34.PELVIS, m34.SPINE, m34.CHEST
NECK, HEAD = 3, 4
SHOULDER_L, ELBOW_L, WRIST_L = m34.SHOULDER_L, m34.ELBOW_L, 7
SHOULDER_R, ELBOW_R, WRIST_R = m34.SHOULDER_R, m34.ELBOW_R, 11
HIP_L, KNEE_L = m34.HIP_L, m34.KNEE_L
HIP_R, KNEE_R = m34.HIP_R, m34.KNEE_R
X, Y, Z = m34.X, m34.Y, m34.Z
axis_angle, wave = m34.axis_angle, m34.wave

RUN_SECONDS = .7
RUN_METRES = 1.3


def heave(u):
    """From rest, up once and back, across a looped clip."""
    return (1-math.cos(2*math.pi*u))/2


def run():
    # The walk's shape, wider and quicker: arms bent and pumping, knees high, a forward lean.
    rotations = {
        SPINE: lambda u: axis_angle(X, -.12 + .03*wave(u)),
        SHOULDER_L: lambda u: axis_angle(X, .7*wave(u)),
        SHOULDER_R: lambda u: axis_angle(X, -.7*wave(u)),
        ELBOW_L: lambda u: axis_angle(X, 1.1),
        ELBOW_R: lambda u: axis_angle(X, 1.1),
        HIP_L: lambda u: axis_angle(X, .75*wave(u)),
        HIP_R: lambda u: axis_angle(X, -.75*wave(u)),
        KNEE_L: lambda u: axis_angle(X, -1.0*max(0, -wave(u)) - .15),
        KNEE_R: lambda u: axis_angle(X, -1.0*max(0, wave(u)) - .15),
    }
    # A foot down at 0 and halfway, the body lowest there and lifted between.
    bob = lambda u: m34.PELVIS_HEIGHT - .04 + .04*(1-math.cos(4*math.pi*u))/2
    return "run", RUN_SECONDS, rotations, lambda u: (0, bob(u), -RUN_METRES*u)


def reach():
    # Arms out in front, hands closing and opening, the chest leaning in. No leg or pelvis track.
    rotations = {
        SPINE: lambda u: axis_angle(X, -.1),
        CHEST: lambda u: axis_angle(X, -.15 - .05*wave(u)),
        SHOULDER_L: lambda u: axis_angle(X, 1.35 + .15*wave(u)),
        SHOULDER_R: lambda u: axis_angle(X, 1.35 - .15*wave(u)),
        ELBOW_L: lambda u: axis_angle(X, .35 - .2*wave(u)),
        ELBOW_R: lambda u: axis_angle(X, .35 + .2*wave(u)),
        WRIST_L: lambda u: axis_angle(X, .5*heave(u)),
        WRIST_R: lambda u: axis_angle(X, .5*heave((u + .5) % 1)),
    }
    return "reach", 1.0, rotations, None


def pant():
    # The chest rises back and the shoulders lift with each breath, from rest, as `idle` holds them.
    rotations = {
        CHEST: lambda u: axis_angle(X, .08*heave(2*u % 1)),
        SHOULDER_L: lambda u: axis_angle(Z, -.06*heave(2*u % 1)),
        SHOULDER_R: lambda u: axis_angle(Z, .06*heave(2*u % 1)),
    }
    return "pant", 1.2, rotations, None


def look():
    # From rest, the head turns left, back, right and back. Left is +Y, facing -Z.
    rotations = {
        NECK: lambda u: axis_angle(Y, .2*wave(u)),
        HEAD: lambda u: axis_angle(Y, .5*wave(u)),
    }
    return "look", 4.0, rotations, None


def animations(accessor):
    """The glTF animations, after M34's, written through a generator's own `accessor`."""
    return m34.build(accessor, (run(), reach(), pant(), look()))
