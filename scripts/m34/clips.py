"""The clips M34 adds to the walker and the warden (`animation-logic.md` §9).

Both generators append these after `idle` and `walk`, so what those two and the mesh compile to
keeps its bytes. Both skeletons are the same 19 joints, and forward is -Z. A rotation about +X by a
positive angle swings a hanging limb forward.
"""
import math

PELVIS, SPINE, CHEST = 0, 1, 2
SHOULDER_L, ELBOW_L = 5, 6
SHOULDER_R, ELBOW_R = 9, 10
HIP_L, KNEE_L = 13, 14
HIP_R, KNEE_R = 16, 17

PELVIS_HEIGHT = .85
STRIDE_METRES = .6
KEYS = 8


def axis_angle(axis, angle):
    s, c = math.sin(angle/2), math.cos(angle/2)
    return (axis[0]*s, axis[1]*s, axis[2]*s, c)


X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)


def wave(u):
    """One whole swing through a looped clip."""
    return math.sin(2*math.pi*u)


def hump(u):
    """Up and back down across a one-shot."""
    return math.sin(math.pi*u)


def ease(u):
    return u*u*(3-2*u)


def walk_angle(joint, u):
    """The joint angles of the M24 walk, so that `stride` is that walk."""
    if joint == SPINE:
        return .025*wave(u)
    sign = -1 if joint in (SHOULDER_R, ELBOW_R, HIP_R, KNEE_R) else 1
    if joint in (SHOULDER_L, SHOULDER_R, HIP_L, HIP_R):
        return sign*.4*wave(u)
    if joint in (KNEE_L, KNEE_R):
        return .45*max(0, sign*wave(u))
    return .12


def stride():
    joints = (SPINE, SHOULDER_L, ELBOW_L, SHOULDER_R, ELBOW_R, HIP_L, KNEE_L, HIP_R, KNEE_R)
    rotations = {j: (lambda u, j=j: axis_angle(X, walk_angle(j, u))) for j in joints}
    # Twice a lap, once for each foot. The height comes back to where it began.
    bob = lambda u: PELVIS_HEIGHT - .012*(1-math.cos(4*math.pi*u))/2
    translation = lambda u: (0, bob(u), -STRIDE_METRES*u)
    return "stride", 1.0, rotations, translation


def turn():
    rotations = {
        PELVIS: lambda u: axis_angle(Y, ease(u)*math.pi/2),
        HIP_L: lambda u: axis_angle(X, .3*hump(u)),
        KNEE_L: lambda u: axis_angle(X, -.45*hump(u)),
        HIP_R: lambda u: axis_angle(X, -.12*hump(u)),
    }
    return "turn", .8, rotations, None


def jump():
    crouch = lambda u: math.sin(math.pi*u/.4)**2 if u < .4 else 0
    tuck = lambda u: math.sin(math.pi*(u-.4)/.6)**2 if u >= .4 else 0
    # Down, up through the arc, and down to land: the body follows the link, so this is the shape.
    height = lambda u: PELVIS_HEIGHT - .16*crouch(u) + .1*tuck(u)
    bend = lambda u: crouch(u) + tuck(u)
    rotations = {
        SPINE: lambda u: axis_angle(X, -.25*crouch(u)),
        SHOULDER_L: lambda u: axis_angle(X, 2.4*hump(u)),
        SHOULDER_R: lambda u: axis_angle(X, 2.4*hump(u)),
        ELBOW_L: lambda u: axis_angle(X, .3*hump(u)),
        ELBOW_R: lambda u: axis_angle(X, .3*hump(u)),
        HIP_L: lambda u: axis_angle(X, .8*bend(u)),
        HIP_R: lambda u: axis_angle(X, .8*bend(u)),
        KNEE_L: lambda u: axis_angle(X, -1.2*bend(u)),
        KNEE_R: lambda u: axis_angle(X, -1.2*bend(u)),
    }
    return "jump", .9, rotations, lambda u: (0, height(u), 0)


def drop():
    rotations = {
        SHOULDER_L: lambda u: axis_angle(Z, -1.3*hump(u)),
        SHOULDER_R: lambda u: axis_angle(Z, 1.3*hump(u)),
        HIP_L: lambda u: axis_angle(X, .55*hump(u)),
        KNEE_L: lambda u: axis_angle(X, -.35*hump(u)),
        HIP_R: lambda u: axis_angle(X, -.2*hump(u)),
        KNEE_R: lambda u: axis_angle(X, -.6*hump(u)),
    }
    return "drop", .7, rotations, None


def climb():
    # Opposite hand and foot, reaching forward onto rungs.
    shoulder = lambda sign: (lambda u: axis_angle(X, 2.2 + sign*.5*wave(u)))
    elbow = lambda sign: (lambda u: axis_angle(X, .5 - sign*.4*wave(u)))
    hip = lambda sign: (lambda u: axis_angle(X, .7 + sign*.45*wave(u)))
    knee = lambda sign: (lambda u: axis_angle(X, -.9 + sign*.45*wave(u)))
    rotations = {
        SHOULDER_L: shoulder(1), ELBOW_L: elbow(1),
        SHOULDER_R: shoulder(-1), ELBOW_R: elbow(-1),
        HIP_L: hip(-1), KNEE_L: knee(1),
        HIP_R: hip(1), KNEE_R: knee(-1),
    }
    return "climb", 1.0, rotations, None


def animations(accessor):
    """The glTF animations, written through a generator's own `accessor`."""
    return build(accessor, (stride(), turn(), jump(), drop(), climb()))


def build(accessor, clips):
    """Each `(name, duration, rotations, translation)` as a glTF animation, keyed at KEYS + 1 even
    times. M35's generator (`scripts/m35/clips.py`) writes its clips through this too."""
    out = []
    for name, duration, rotations, translation in clips:
        times = accessor([(i/KEYS*duration,) for i in range(KEYS+1)], 1, "f", 5126, "SCALAR", True)
        samplers, channels = [], []

        def track(joint, path, width, kind, curve):
            values = [curve(i/KEYS) for i in range(KEYS+1)]
            output = accessor(values, width, "f", 5126, kind)
            samplers.append({"input": times, "output": output, "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers)-1, "target": {"node": joint, "path": path}})

        for joint in sorted(rotations):
            track(joint, "rotation", 4, "VEC4", rotations[joint])
        if translation:
            track(PELVIS, "translation", 3, "VEC3", translation)
        out.append({"name": name, "samplers": samplers, "channels": channels})
    return out
