"""The walks M36 adds to the walker (`animation-ik.md` §11), for the strafer's blend `walk8`.

`scripts/m24/make_character.py` appends these after M35's four, so every clip before them, the mesh
and the skeleton keep their bytes. The joints, axes and keying are M34's (`scripts/m34/clips.py`):
forward is -Z, and a rotation about +X by a positive angle swings a hanging limb forward.

Eight walks, one a compass point of the figure's own frame (north is -Z, east +X). Each lasts a
second and travels its place on the grid in a lap: a cardinal walk 1 m, a diagonal one 1 m along each
axis. With `idle` in the middle they fill a 3 x 3 grid of metres a second, and since bilinear
weights reproduce a linear quantity exactly, the blend's travel anywhere on the grid is its
position. `stride`, at 0.6 m a lap, is not among them, and keeps its bytes.

A foot lands at 0 and halfway, as in `stride`, but the gait is its own, because a foot placed and
locked on the ground has to be a planted foot in the clip too (M36 Step 7):
- each hip swings along the direction of travel, forward while its knee bends back to clear the
  foot, and back while the leg is straight and the foot is down;
- the swing is just far enough that a planted foot moves back by the walk's own travel across the
  half lap it is down;
- the pelvis rides the planted leg's arc, so a planted foot stays at its rest height all the while,
  and is lowest as each foot lands.

`stride`'s swing is wider than its travel, its pelvis bobs on its own, and its planted foot rises and
moves forward and back, which a lock cannot follow. So these walks do not copy it.
"""
import importlib.util
import math
from pathlib import Path

_spec = importlib.util.spec_from_file_location("m34_clips", Path(__file__).resolve().parents[1]/"m34/clips.py")
m34 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m34)

SPINE = m34.SPINE
KNEE_BEND = .8
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

# The foot joint's rest height, and the hip to the foot at rest, metres.
FOOT = .08
LEG = m34.PELVIS_HEIGHT - FOOT


def walk(name, east, ahead):
    speed = math.hypot(east, ahead)
    # The axis that swings a hanging limb toward (east, -ahead) in model space.
    axis = (ahead/speed, 0, east/speed)
    # A planted foot goes from L sin(a) ahead to L sin(a) behind in half a lap, which is half the
    # lap's travel.
    swing = math.asin(speed/(4*LEG))
    # Arms swing against the legs, with the forward part of the walk alone.
    arms = .3*ahead/speed
    lag = lambda u: math.cos(2*math.pi*u)
    rotations = {
        SPINE: lambda u: axis_angle(X, .025*wave(u)),
        SHOULDER_L: lambda u: axis_angle(X, arms*lag(u)),
        SHOULDER_R: lambda u: axis_angle(X, -arms*lag(u)),
        ELBOW_L: lambda u: axis_angle(X, .12),
        ELBOW_R: lambda u: axis_angle(X, .12),
        # The left foot is behind at 0, swings forward with its knee bent, lands ahead at halfway
        # and is carried back while it is down. The right is half a lap from it.
        HIP_L: lambda u: axis_angle(axis, -swing*lag(u)),
        HIP_R: lambda u: axis_angle(axis, swing*lag(u)),
        # Bent back while each foot swings, from rest: the left in the first half, the right in the
        # second. A negative angle about +X swings a hanging limb back.
        KNEE_L: lambda u: axis_angle(X, -KNEE_BEND*max(0, wave(u))),
        KNEE_R: lambda u: axis_angle(X, -KNEE_BEND*max(0, -wave(u))),
    }
    # On the planted leg's arc: its hip is `swing*|lag|` from straight down, and its knee straight.
    pelvis = lambda u: FOOT + LEG*math.cos(swing*lag(u))
    return name, 1.0, rotations, lambda u: (east*u, pelvis(u), -ahead*u)


def animations(accessor):
    """The glTF animations, after M35's, written through the walker generator's own `accessor`."""
    return m34.build(accessor, tuple(walk(*entry) for entry in WALKS))
