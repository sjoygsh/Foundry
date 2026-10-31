//! Root motion: a character's travel, carried by a clip (`animation-logic.md` §6, ADR-0071).
//!
//! **It is a wish.** `anim` moves nothing, as `nav.Crowd` moves nothing: a clip's motion joint, a
//! root of the skeleton, loses its X, Z and yaw from the pose, and those come back as a delta. The
//! game turns the delta by its body's facing and carries it out, and its controller may refuse.
//!
//! **The pose keeps the joint's height,** so a stride's bob stays in the animation.
//!
//! **A delta is expressed in the body's frame at the tick's start:** its travel is unturned by the
//! yaw the clip has reached by then, because the game has already turned the body that far. So a
//! game adds `yaw` to its facing and moves along `translation` turned by the old facing, and a clip
//! that walks in an arc comes out as one.
//!
//! **No trig runs on a pose.** The yaw is a twist, found by projecting a quaternion on the axis, and
//! only `Motion.yaw` needs an angle.
//! `std.math.atan2` is Zig's own arithmetic on every target, so a pin does not depend on a libm.

const std = @import("std");
const core = @import("core");

const pose_mod = @import("pose.zig");
const rig_mod = @import("rig.zig");

const Mat4 = core.math.Mat4;
const Pose = pose_mod.Pose;
const Quat = core.math.Quat;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;

/// What a tick asks a body to do.
pub const Motion = struct {
    /// Metres this tick, in the body's frame at the tick's start, on the floor: Y is zero.
    translation: Vec3 = .zero,
    /// Radians about +Y this tick, counter-clockwise from above.
    yaw: f32 = 0,
};

/// The most whole laps of a clip one tick works through. Past this, a clip a hostile package made
/// very short has no meaningful travel to report.
const max_whole_laps: f64 = 4096;

/// How the motion joint's parent space, the skeleton's root space, meets the model.
pub const Frame = struct {
    to_model: Mat4,
    to_joint: Mat4,
    /// Model up, in the joint's parent space, unit.
    axis: Vec3,
};

/// Null for a root that cannot be undone. `Rig.validate` refuses that, so a validated rig has one.
pub fn frameOf(rig: Rig) ?Frame {
    const to_joint = rig.skeleton.root.inverse() orelse return null;
    const axis = to_joint.mulDirection(.init(0, 1, 0));
    const length = axis.length();
    if (!(length > 0) or !std.math.isFinite(length)) return null;
    return .{ .to_model = rig.skeleton.root, .to_joint = to_joint, .axis = axis.scale(1 / length) };
}

/// The part of `q` that is a turn about `axis`, unit. A half turn about a perpendicular axis has
/// none to find, and that is the identity.
fn twist(q: Quat, axis: Vec3) Quat {
    const along = q.x * axis.x + q.y * axis.y + q.z * axis.z;
    const v = axis.scale(along);
    const length = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z + q.w * q.w);
    if (length < 1e-6) return .identity;
    return .{ .x = v.x / length, .y = v.y / length, .z = v.z / length, .w = q.w / length };
}

/// The turn from a joint's rotation at the clip's start to `q`, about `axis`.
fn turned(q: Quat, start: Quat, axis: Vec3) Quat {
    return twist(q, axis).mul(twist(start, axis).conjugate());
}

/// The same turn about model up.
fn inModel(turn: Quat, axis: Vec3) Quat {
    const s = turn.x * axis.x + turn.y * axis.y + turn.z * axis.z;
    return .{ .x = 0, .y = s, .z = 0, .w = turn.w };
}

/// Takes the motion joint's travel out of a pose sampled from `entry`.
pub fn hold(rig: Rig, entry: *const RigClip, pose: Pose) void {
    const frame = frameOf(rig).?;
    const joint = &pose.local[rig.motion_joint];
    const start = pose_mod.sampleJoint(rig.skeleton, entry.clip, rig.motion_joint, 0);
    var moved = frame.to_model.mulDirection(joint.translation.sub(start.translation));
    moved.y = 0;
    joint.translation = joint.translation.sub(frame.to_joint.mulDirection(moved));
    joint.rotation = turned(joint.rotation, start.rotation, frame.axis).conjugate().mul(joint.rotation).normalize();
}

/// The move from `from` to `to`, unfolded seconds of `entry` at its own rate. Nothing for a span
/// that does not run forward.
pub fn travel(rig: Rig, entry: *const RigClip, from: f64, to: f64) Motion {
    if (!(to > from)) return .{};
    const frame = frameOf(rig).?;
    const duration: f64 = entry.clip.duration;
    var path: Path = .{};
    if (!entry.loop) {
        // Past the end of a one-shot the sample holds, so there is nothing to clamp.
        path.add(rig, entry, frame, narrow(from), narrow(to));
        return path.done();
    }
    const first = @floor(from / duration);
    const last = @floor(to / duration);
    if (first == last) {
        path.add(rig, entry, frame, narrow(from - first * duration), narrow(to - last * duration));
        return path.done();
    }
    path.add(rig, entry, frame, narrow(from - first * duration), entry.clip.duration);
    var whole = @min(last - first - 1, max_whole_laps);
    while (whole >= 1) : (whole -= 1) path.add(rig, entry, frame, 0, entry.clip.duration);
    path.add(rig, entry, frame, 0, narrow(to - last * duration));
    return path.done();
}

fn narrow(seconds: f64) f32 {
    return @floatCast(seconds);
}

/// Stretches of a clip, joined end to end.
const Path = struct {
    translation: Vec3 = .zero,
    yaw: f32 = 0,
    /// The turn so far, about model up.
    turn: Quat = .identity,

    fn add(path: *Path, rig: Rig, entry: *const RigClip, frame: Frame, from: f32, to: f32) void {
        const joint = rig.motion_joint;
        const clip = entry.clip;
        const start = pose_mod.sampleJoint(rig.skeleton, clip, joint, 0);
        const a = pose_mod.sampleJoint(rig.skeleton, clip, joint, from);
        const b = pose_mod.sampleJoint(rig.skeleton, clip, joint, to);

        var moved = frame.to_model.mulDirection(b.translation.sub(a.translation));
        moved.y = 0;
        // In the frame the clip had reached at `a`, so that it joins up with the turn so far.
        const reached = inModel(turned(a.rotation, start.rotation, frame.axis), frame.axis);
        path.translation = path.translation.add(path.turn.rotate(reached.conjugate().rotate(moved)));

        var step = inModel(turned(b.rotation, a.rotation, frame.axis), frame.axis);
        if (step.w < 0) step = step.neg();
        path.yaw += 2 * std.math.atan2(step.y, step.w);
        path.turn = path.turn.mul(step).normalize();
    }

    fn done(path: Path) Motion {
        return .{ .translation = path.translation, .yaw = path.yaw };
    }
};

/// A motion clip's net ground speed in metres a second at channel speed 1, or 0 for any other.
pub fn groundSpeed(rig: Rig, entry: *const RigClip) f32 {
    if (!entry.motion) return 0;
    const frame = frameOf(rig) orelse return 0;
    const clip = entry.clip;
    const a = pose_mod.sampleJoint(rig.skeleton, clip, rig.motion_joint, 0);
    const b = pose_mod.sampleJoint(rig.skeleton, clip, rig.motion_joint, clip.duration);
    var moved = frame.to_model.mulDirection(b.translation.sub(a.translation));
    moved.y = 0;
    return moved.length() / clip.duration * entry.speed;
}
