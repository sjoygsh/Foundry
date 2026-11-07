//! Look-at: a chain of joints turned toward a point (`animation-ik.md` §5, ADR-0073).
//!
//! **The game says what a figure looks at,** a world point or none, and how much it wants to. `Aim`
//! eases toward both: the point it looks at sweeps toward a new target rather than snapping, and the
//! weight fades in and out, and away to nothing while the point is past the chain's limit, so a
//! figure gives up on what is behind it.
//!
//! **`Aim` is presentation, not state,** like `Feet`: never saved, stepped once a tick with the tick's
//! `dt`. It runs after the feet and after every layer, so a gaze is from where the figure stands and
//! an additive `look` clip still moves the head beneath a weak gaze.

const std = @import("std");
const core = @import("core");

const ik = @import("ik.zig");
const pose_mod = @import("pose.zig");
const rig_mod = @import("rig.zig");

const Mat4 = core.math.Mat4;
const Pose = pose_mod.Pose;
const Rig = rig_mod.Rig;
const Vec3 = core.math.Vec3;

/// The most aim chains one rig may hold.
pub const max_aims = 4;

/// How fast the point looked at sweeps toward a new target, in radians a second about the eye.
pub const sweep_speed: f32 = 6;
/// Seconds a gaze's weight takes to fade fully in or out.
pub const fade: f32 = 0.3;

/// An aim chain as a set says it (§6).
pub const RigAim = struct {
    /// `clipName` of what the set calls it.
    name: u64,
    chain: ik.AimChain,
    label: []const u8 = "",
};

pub const AimError = ik.AimChain.ValidateError || error{ TooManyAims, UnnamedAim, DuplicateAim };

pub fn validateAims(rig: Rig) AimError!void {
    if (rig.aims.len > max_aims) return error.TooManyAims;
    for (rig.aims, 0..) |entry, i| {
        if (entry.name == 0) return error.UnnamedAim;
        for (rig.aims[0..i]) |earlier| {
            if (earlier.name == entry.name) return error.DuplicateAim;
        }
        try entry.chain.validate(rig.skeleton);
    }
}

pub const Aim = struct {
    /// The point looked at now, in world space, smoothed, and how firmly, 0 to 1.
    at: Vec3 = .zero,
    weight: f32 = 0,
    /// Whether `at` holds a point yet, so the first target is taken as it is.
    aimed: bool = false,
    /// Whether the point was past the chain's limit on the last tick: for the panel.
    beyond: bool = false,

    /// One tick of `chain`, the rig's `aims[chain]`: `at` swept toward `target`, the weight toward
    /// `wanted` or toward 0 when there is no target or it is past the limit, then the chain turned.
    /// A chain the rig lacks, or a `to_world` that cannot be undone, changes nothing.
    pub fn apply(aim: *Aim, rig: Rig, chain: usize, pose: Pose, to_world: Mat4, target: ?Vec3, wanted: f32, dt: f32) void {
        if (chain >= rig.aims.len) return;
        const to_model = to_world.inverse() orelse return;
        const definition = rig.aims[chain].chain;
        const step: f32 = if (std.math.isFinite(dt) and dt > 0) dt else 0;
        const last = definition.joints[definition.joints.len - 1].joint;
        const eye = to_world.mulPoint(ik.positionOf(ik.modelOf(rig.skeleton, pose, last)));

        var goal: f32 = if (std.math.isFinite(wanted)) std.math.clamp(wanted, 0, 1) else 0;
        if (target) |point| {
            if (point.isFinite()) {
                aim.sweep(eye, point, step);
            } else {
                goal = 0;
            }
        } else {
            goal = 0;
        }
        if (!aim.at.isFinite()) {
            aim.at = eye;
            aim.aimed = false;
        }

        // Past the limit from where the clip has the head facing, the gaze lets go.
        const model_forward = ik.modelOf(rig.skeleton, pose, last).mulDirection(definition.forward);
        const facing = to_world.mulDirection(model_forward);
        const toward = aim.at.sub(eye);
        aim.beyond = false;
        if (aim.aimed and toward.length() > 1e-6 and facing.length() > 1e-6) {
            const cos = facing.normalize().dot(toward.normalize());
            if (cos < cosOf(definition.limit)) {
                aim.beyond = true;
                goal = 0;
            }
        }
        const current = if (std.math.isFinite(aim.weight)) std.math.clamp(aim.weight, 0, 1) else 0;
        aim.weight = if (current < goal) @min(goal, current + step / fade) else @max(goal, current - step / fade);
        if (aim.weight > 0 and aim.aimed) ik.aim(rig.skeleton, pose, definition, to_model.mulPoint(aim.at), aim.weight);
    }

    /// Turns `at` about the eye toward `target` by at most `sweep_speed × dt`, and takes the target's
    /// distance. The first target, or one seen after the gaze had faded out, is taken as it is.
    fn sweep(aim: *Aim, eye: Vec3, target: Vec3, dt: f32) void {
        if (!aim.aimed or aim.weight == 0 or !aim.at.isFinite()) {
            aim.at = target;
            aim.aimed = true;
            return;
        }
        const from = aim.at.sub(eye);
        const to = target.sub(eye);
        const distance = to.length();
        if (!(from.length() > 1e-6) or !(distance > 1e-6)) {
            aim.at = target;
            return;
        }
        const turn = ik.limitedTurn(from, to, sweep_speed * dt);
        aim.at = eye.add(turn.rotate(from.normalize()).scale(distance));
    }
};

fn cosOf(radians: f32) f32 {
    return @floatCast(core.math.trig.sinCosTurns(@as(f64, radians) / (2 * std.math.pi))[1]);
}
