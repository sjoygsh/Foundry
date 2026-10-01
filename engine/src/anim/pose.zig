//! Poses: sampling a clip, blending two poses, and composing a pose into matrices.

const std = @import("std");
const core = @import("core");

const clip_mod = @import("clip.zig");
const skeleton_mod = @import("skeleton.zig");

const Clip = clip_mod.Clip;
const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Skeleton = skeleton_mod.Skeleton;
const Track = clip_mod.Track;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;

/// One local transform per joint, in a buffer the caller owns.
pub const Pose = struct {
    local: []Transform,
};

/// A looping clip's time: `time` folded into `[0, duration)`. A negative time wraps from the
/// end. A time that is not finite is 0.
pub fn wrap(time: f32, duration: f32) f32 {
    core.assert.debugOnly(duration > 0, "wrap needs a positive duration", .{});
    if (!std.math.isFinite(time)) return 0;
    const folded = @mod(time, duration);
    // A tiny negative time rounds up to `duration` itself, which is the start of the loop.
    return if (folded >= duration) 0 else folded;
}

/// A one-shot clip's time: `time` held within `[0, duration]`. A time that is not finite is 0.
pub fn clamp(time: f32, duration: f32) f32 {
    core.assert.debugOnly(duration > 0, "clamp needs a positive duration", .{});
    if (!std.math.isFinite(time)) return 0;
    return std.math.clamp(time, 0, duration);
}

/// Fills every joint of `out` with `clip` at `time`, in seconds.
///
/// A path with no track keeps the skeleton's rest value, so a clip that animates only the legs
/// leaves the arms at rest. Before a track's first key its first value holds, and after its
/// last, its last. `time` is used as given: looping and holding are `wrap` and `clamp`.
///
/// Both values must have passed `validate`, the clip for this skeleton's joint count.
pub fn sample(skeleton: Skeleton, clip: Clip, time: f32, out: Pose) void {
    core.assert.always(out.local.len == skeleton.jointCount(), "pose has {d} joints, skeleton has {d}", .{ out.local.len, skeleton.jointCount() });
    @memcpy(out.local, skeleton.rest);
    for (clip.tracks) |track| {
        const joint = &out.local[track.joint];
        const span = locate(track, time);
        switch (track.path) {
            .translation => joint.translation = Vec3.lerp(vec3At(track, span.a), vec3At(track, span.b), span.t),
            .scale => joint.scale = Vec3.lerp(vec3At(track, span.a), vec3At(track, span.b), span.t),
            // `slerp` takes the shorter arc and normalises, and a held key is normalised too,
            // so a stored rotation is always unit (`core.math.Quat`).
            .rotation => joint.rotation = if (span.a == span.b)
                quatAt(track, span.a).normalize()
            else
                Quat.slerp(quatAt(track, span.a), quatAt(track, span.b), span.t),
        }
    }
}

const Span = struct { a: usize, b: usize, t: f32 };

/// The two keys `time` lies between, and how far along. Both are the same key when the value
/// holds: outside the track's range, exactly on a key, or under `step`.
fn locate(track: Track, time: f32) Span {
    const times = track.times;
    const last = times.len - 1;
    // Written so a NaN time fails the comparison and holds the first key.
    if (!(time > times[0])) return .{ .a = 0, .b = 0, .t = 0 };
    if (time >= times[last]) return .{ .a = last, .b = last, .t = 0 };

    // The last key at or before `time`. The two returns above leave `times[0] < time <
    // times[last]`, so `lo` always has a key after it.
    var lo: usize = 0;
    var hi: usize = last;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (times[mid] <= time) lo = mid else hi = mid;
    }
    if (track.interpolation == .step or times[lo] == time) return .{ .a = lo, .b = lo, .t = 0 };
    return .{ .a = lo, .b = hi, .t = (time - times[lo]) / (times[hi] - times[lo]) };
}

fn vec3At(track: Track, key: usize) Vec3 {
    const v = track.values[key * 3 ..][0..3];
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

fn quatAt(track: Track, key: usize) Quat {
    const v = track.values[key * 4 ..][0..4];
    return .{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] };
}

/// Mixes two poses joint by joint: translation and scale linearly, rotation along the shorter
/// arc. `weight` is clamped to `[0, 1]`; 0 gives `a` exactly and 1 gives `b` exactly. `out` may
/// be `a` or `b`.
pub fn blend(a: Pose, b: Pose, weight: f32, out: Pose) void {
    core.assert.always(a.local.len == b.local.len and a.local.len == out.local.len, "blend needs three poses of one length", .{});
    // Written so a NaN weight is 0.
    const w: f32 = if (!(weight > 0)) 0 else @min(weight, 1);
    for (a.local, b.local, out.local) |from, to, *mixed| {
        if (w == 0) {
            mixed.* = from;
        } else if (w == 1) {
            mixed.* = to;
        } else {
            mixed.* = .{
                .translation = Vec3.lerp(from.translation, to.translation, w),
                .rotation = Quat.slerp(from.rotation, to.rotation, w),
                .scale = Vec3.lerp(from.scale, to.scale, w),
            };
        }
    }
}

/// Each joint's model-space matrix: the skeleton's `root`, then the chain of local transforms
/// down to the joint. What a game attaches something to a joint with.
pub fn modelMatrices(skeleton: Skeleton, pose: Pose, out: []Mat4) void {
    const count = skeleton.jointCount();
    core.assert.always(pose.local.len == count and out.len == count, "pose and output need {d} joints", .{count});
    // Parents first, so every parent's matrix is already written when its child reads it.
    for (skeleton.parents, pose.local, 0..) |parent, local, joint| {
        const above = if (parent == skeleton_mod.no_parent) skeleton.root else out[parent];
        out[joint] = Mat4.mul(above, local.toMat4());
    }
}

/// The matrices skinning consumes: `root · model[j] · inverse_bind[j]`, taking a bind-pose
/// vertex in model space to its posed place in model space. At the bind pose each is the
/// identity.
pub fn skinMatrices(skeleton: Skeleton, pose: Pose, out: []Mat4) void {
    modelMatrices(skeleton, pose, out);
    // A second pass, because a child composes from its parent's model matrix, not its skin
    // matrix.
    for (out, skeleton.inverse_bind) |*matrix, inverse_bind| {
        matrix.* = Mat4.mul(matrix.*, inverse_bind);
    }
}
