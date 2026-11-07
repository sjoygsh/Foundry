//! Inverse kinematics: two closed-form solvers on a pose (`animation-ik.md` §3, ADR-0073).
//!
//! **A correction of an evaluated pose, and nothing else.** Each solver takes targets in model space,
//! the space `modelMatrices` composes into, and writes local rotations back, so a corrected pose is
//! still an ordinary `Pose` for `skinMatrices`. Neither holds state, reads a clock, sees a world or
//! allocates.
//!
//! **No inverse trig runs here.** A bend comes from the law of cosines as a cosine, and a quaternion
//! is built from it by half angles; a turn between two directions is the shortest arc, built from
//! their dot and cross products; a limit's sine and cosine come from `core.math.trig`. So a solve
//! depends on the binary's arithmetic and on `Quat.slerp`, which every blend already uses.
//!
//! **Only rotations change,** never a translation or a scale. A chain is assumed to have uniform
//! scale, which every skeleton here has; a non-uniform one still solves, a little off its target.

const std = @import("std");
const core = @import("core");

const pose_mod = @import("pose.zig");
const skeleton_mod = @import("skeleton.zig");

const Mat4 = core.math.Mat4;
const Pose = pose_mod.Pose;
const Quat = core.math.Quat;
const Skeleton = skeleton_mod.Skeleton;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;

const no_parent = skeleton_mod.no_parent;

/// The closest a target may come to a chain's root, and how far short of straight a reach stops,
/// in metres: so a chain is never folded flat nor snapped through.
pub const min_reach: f32 = 1e-3;
pub const straight_margin: f32 = 1e-4;

/// A root, a middle and an end: a hip, a knee and a foot.
pub const TwoBone = struct {
    root: u16,
    middle: u16,
    end: u16,

    pub const ValidateError = error{NotAChain};

    /// The middle is the end's parent, and the root is an ancestor of the middle.
    pub fn validate(chain: TwoBone, skeleton: Skeleton) ValidateError!void {
        const count = skeleton.jointCount();
        if (chain.root >= count or chain.middle >= count or chain.end >= count) return error.NotAChain;
        if (skeleton.parents[chain.end] != chain.middle) return error.NotAChain;
        if (!isAncestor(skeleton, chain.root, chain.middle)) return error.NotAChain;
    }
};

/// The most joints an aim chain turns.
pub const max_aim_joints = 4;

pub const AimJoint = struct {
    joint: u16,
    /// Its share of the turn, above 0. Shares are normalised to sum to 1.
    share: f32,
};

/// Joints from the root down, turned so that `forward`, a direction in the last joint's frame,
/// points at a target.
pub const AimChain = struct {
    joints: []const AimJoint,
    forward: Vec3 = Vec3.forward,
    /// Radians, above 0 and at most π: the most the whole turn may be.
    limit: f32 = 1.2,

    pub const ValidateError = error{ NotAChain, InvalidAimWeight, InvalidForward, InvalidLimit };

    pub fn validate(chain: AimChain, skeleton: Skeleton) ValidateError!void {
        if (chain.joints.len == 0 or chain.joints.len > max_aim_joints) return error.NotAChain;
        for (chain.joints, 0..) |entry, i| {
            if (entry.joint >= skeleton.jointCount()) return error.NotAChain;
            if (i != 0 and !isAncestor(skeleton, chain.joints[i - 1].joint, entry.joint)) return error.NotAChain;
            // Written so a NaN is refused.
            if (!(entry.share > 0) or !std.math.isFinite(entry.share)) return error.InvalidAimWeight;
        }
        if (!chain.forward.isFinite() or !(chain.forward.length() > 1e-6)) return error.InvalidForward;
        if (!(chain.limit > 0 and chain.limit <= std.math.pi)) return error.InvalidLimit;
    }

    fn last(chain: AimChain) u16 {
        return chain.joints[chain.joints.len - 1].joint;
    }
};

/// Whether `above` is a strict ancestor of `joint`.
pub fn isAncestor(skeleton: Skeleton, above: u16, joint: u16) bool {
    var at = skeleton.parents[joint];
    var steps: usize = 0;
    while (at != no_parent and steps < skeleton_mod.max_joints) : (steps += 1) {
        if (at == above) return true;
        at = skeleton.parents[at];
    }
    return false;
}

/// Reaches `chain`'s end toward `target`, bending in the plane through the root, the target and
/// `pole`, all in model space. A target out of reach straightens the chain toward it, and one closer
/// than the bones can fold to is held at that distance. `weight`, from 0 to 1, slerps each changed
/// local rotation from the clip's toward the solve; at 0 the pose is untouched. `chain` must have
/// passed `validate` for `skeleton`.
pub fn twoBone(skeleton: Skeleton, pose: Pose, chain: TwoBone, target: Vec3, pole: Vec3, weight: f32) void {
    // Written so a NaN is 0.
    const w: f32 = if (!(weight > 0)) 0 else @min(weight, 1);
    if (w == 0 or !target.isFinite() or !pole.isFinite()) return;

    const a = positionOf(modelOf(skeleton, pose, chain.root));
    const b = positionOf(modelOf(skeleton, pose, chain.middle));
    const c = positionOf(modelOf(skeleton, pose, chain.end));
    const upper = b.sub(a).length();
    const lower = c.sub(b).length();
    if (!(upper > 0) or !(lower > 0)) return;

    const to_target = target.sub(a);
    const span = to_target.length();
    const along = if (span > 1e-9) to_target.scale(1 / span) else direction(c.sub(a), Vec3.up);
    const shortest = @max(min_reach, @abs(upper - lower) + straight_margin);
    const longest = upper + lower - straight_margin;
    const d = std.math.clamp(span, shortest, @max(shortest, longest));

    // The bend: perpendicular to the reach, toward the pole, or toward the clip's own middle when
    // the pole lies on the line.
    const across = perpendicular(pole.sub(a), along) orelse perpendicular(b.sub(a), along) orelse anyPerpendicular(along);
    const cos_root = std.math.clamp((upper * upper + d * d - lower * lower) / (2 * upper * d), -1, 1);
    const sin_root = @sqrt(@max(0, 1 - cos_root * cos_root));
    const middle_at = a.add(along.scale(upper * cos_root)).add(across.scale(upper * sin_root));
    const end_at = a.add(along.scale(d));

    // Turn the root so the middle lands, then the middle so the end does, both in model space.
    const turn_root = fromTo(b.sub(a), middle_at.sub(a));
    const end_after_root = a.add(turn_root.rotate(c.sub(a)));
    const turn_middle = fromTo(end_after_root.sub(middle_at), end_at.sub(middle_at));

    const root_parent = parentRotation(skeleton, pose, chain.root);
    const middle_parent = parentRotation(skeleton, pose, chain.middle);
    const root_local = pose.local[chain.root].rotation;
    const middle_local = pose.local[chain.middle].rotation;

    // A model-space turn `t` of a joint whose parent's model rotation is `p` is `p⁻¹ · t · p` locally.
    const solved_root = local(root_parent, turn_root).mul(root_local).normalize();
    // The middle's parent has turned with the root, so its own turn is read in that turned frame.
    const solved_middle = local(turn_root.mul(middle_parent), turn_middle).mul(middle_local).normalize();

    pose.local[chain.root].rotation = mix(root_local, solved_root, w);
    pose.local[chain.middle].rotation = mix(middle_local, solved_middle, w);
}

/// Turns `chain` so its last joint's `forward` points at `target`, in model space, each joint taking
/// its share of what remains from the root down, and the whole turn held within `chain.limit`. Each
/// joint turns about its own position. `weight` is as `twoBone`'s. `chain` must have passed
/// `validate` for `skeleton`.
pub fn aim(skeleton: Skeleton, pose: Pose, chain: AimChain, target: Vec3, weight: f32) void {
    const w: f32 = if (!(weight > 0)) 0 else @min(weight, 1);
    if (w == 0 or !target.isFinite()) return;

    var before: [max_aim_joints]Quat = undefined;
    for (chain.joints, 0..) |entry, i| before[i] = pose.local[entry.joint].rotation;

    var total: f32 = 0;
    for (chain.joints) |entry| total += entry.share;
    const forward = direction(chain.forward, Vec3.forward);
    const start = facing(skeleton, pose, chain.last(), forward);
    const limit = limits(chain.limit);

    var remaining = total;
    for (chain.joints) |entry| {
        const eye = positionOf(modelOf(skeleton, pose, chain.last()));
        const now = facing(skeleton, pose, chain.last(), forward);
        const wanted = held(start, direction(target.sub(eye), now), limit);
        const turn = fromTo(now, wanted);
        const part = if (remaining > 0) @min(1, entry.share / remaining) else 1;
        const step = if (part >= 1) turn else Quat.slerp(Quat.identity, turn, part);
        const parent = parentRotation(skeleton, pose, entry.joint);
        const joint = &pose.local[entry.joint];
        joint.rotation = local(parent, step).mul(joint.rotation).normalize();
        remaining -= entry.share;
    }

    if (w >= 1) return;
    for (chain.joints, 0..) |entry, i| {
        pose.local[entry.joint].rotation = Quat.slerp(before[i], pose.local[entry.joint].rotation, w);
    }
}

/// The shortest turn from direction `from` toward `to`, held to at most `radians`. What a foot's tilt
/// and a gaze's sweep use.
pub fn limitedTurn(from: Vec3, to: Vec3, radians: f32) Quat {
    const a = direction(from, Vec3.forward);
    const b = held(a, direction(to, a), limits(@max(0, @min(radians, std.math.pi))));
    return fromTo(a, b);
}

/// Turns `joint` by `turn`, a rotation in model space about the joint's own place.
pub fn turnJoint(skeleton: Skeleton, pose: Pose, joint: u16, turn: Quat) void {
    const parent = parentRotation(skeleton, pose, joint);
    pose.local[joint].rotation = local(parent, turn).mul(pose.local[joint].rotation).normalize();
}

/// `limit`'s cosine, and the half-angle sine and cosine of a turn by it.
const Limit = struct { cos: f32, half_sin: f32, half_cos: f32 };

fn limits(radians: f32) Limit {
    const turns: f64 = @as(f64, radians) / (2 * std.math.pi);
    const whole = core.math.trig.sinCosTurns(turns);
    const half = core.math.trig.sinCosTurns(turns / 2);
    return .{ .cos = @floatCast(whole[1]), .half_sin = @floatCast(half[0]), .half_cos = @floatCast(half[1]) };
}

/// `wanted`, unless it lies more than the limit from `start`, in which case `start` turned toward it
/// by exactly the limit.
fn held(start: Vec3, wanted: Vec3, limit: Limit) Vec3 {
    if (start.dot(wanted) >= limit.cos) return wanted;
    const axis = direction(start.cross(wanted), anyPerpendicular(start));
    const turn: Quat = .{ .x = axis.x * limit.half_sin, .y = axis.y * limit.half_sin, .z = axis.z * limit.half_sin, .w = limit.half_cos };
    return turn.rotate(start);
}

/// Where a joint's `forward` points in model space.
fn facing(skeleton: Skeleton, pose: Pose, joint: u16, forward: Vec3) Vec3 {
    return direction(modelRotation(skeleton, pose, joint).rotate(forward), forward);
}

/// A joint's model matrix: the skeleton's root, then every local transform down to it.
pub fn modelOf(skeleton: Skeleton, pose: Pose, joint: u16) Mat4 {
    var path: [skeleton_mod.max_joints]u16 = undefined;
    var len: usize = 0;
    var at = joint;
    while (at != no_parent and len < path.len) : (len += 1) {
        path[len] = at;
        at = skeleton.parents[at];
    }
    var matrix = skeleton.root;
    while (len > 0) {
        len -= 1;
        matrix = Mat4.mul(matrix, pose.local[path[len]].toMat4());
    }
    return matrix;
}

/// A joint's model rotation: the root's, then every local rotation down to it.
fn modelRotation(skeleton: Skeleton, pose: Pose, joint: u16) Quat {
    return parentRotation(skeleton, pose, joint).mul(pose.local[joint].rotation).normalize();
}

/// The model rotation of a joint's parent, or of the skeleton's root for a root joint.
fn parentRotation(skeleton: Skeleton, pose: Pose, joint: u16) Quat {
    var path: [skeleton_mod.max_joints]u16 = undefined;
    var len: usize = 0;
    var at = skeleton.parents[joint];
    while (at != no_parent and len < path.len) : (len += 1) {
        path[len] = at;
        at = skeleton.parents[at];
    }
    var rotation = rootRotation(skeleton);
    while (len > 0) {
        len -= 1;
        rotation = rotation.mul(pose.local[path[len]].rotation);
    }
    return rotation.normalize();
}

fn rootRotation(skeleton: Skeleton) Quat {
    const decomposed = Transform.fromMat4Exact(skeleton.root) catch return Quat.identity;
    return decomposed.rotation;
}

/// The local form of a model-space turn `turn` for a joint whose parent's model rotation is `parent`.
fn local(parent: Quat, turn: Quat) Quat {
    return parent.conjugate().mul(turn).mul(parent);
}

fn mix(from: Quat, to: Quat, w: f32) Quat {
    return if (w >= 1) to else Quat.slerp(from, to, w);
}

/// The shortest turn taking direction `from` to direction `to`. Opposite directions turn half way
/// round any perpendicular.
pub fn fromTo(from: Vec3, to: Vec3) Quat {
    const a = direction(from, Vec3.forward);
    const b = direction(to, a);
    const d = a.dot(b);
    if (d < -1 + 1e-6) {
        const axis = anyPerpendicular(a);
        return .{ .x = axis.x, .y = axis.y, .z = axis.z, .w = 0 };
    }
    const axis = a.cross(b);
    return (Quat{ .x = axis.x, .y = axis.y, .z = axis.z, .w = 1 + d }).normalize();
}

/// `v` made unit, or `fallback` when it has no direction.
fn direction(v: Vec3, fallback: Vec3) Vec3 {
    const length = v.length();
    if (!(length > 1e-9) or !std.math.isFinite(length)) return fallback;
    return v.scale(1 / length);
}

/// The part of `v` across the unit `along`, made unit, or null when there is none.
fn perpendicular(v: Vec3, along: Vec3) ?Vec3 {
    const across = v.sub(along.scale(v.dot(along)));
    const length = across.length();
    if (!(length > 1e-6)) return null;
    return across.scale(1 / length);
}

fn anyPerpendicular(v: Vec3) Vec3 {
    const other = if (@abs(v.y) < 0.9) Vec3.up else Vec3.right;
    return direction(v.cross(other), Vec3.right);
}

/// A model matrix's translation.
pub fn positionOf(m: Mat4) Vec3 {
    return .init(m.cols[3][0], m.cols[3][1], m.cols[3][2]);
}
