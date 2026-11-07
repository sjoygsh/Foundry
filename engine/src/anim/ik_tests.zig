//! `animation-ik.md` §16's tests for M36 Step 2: `ik.twoBone` and `ik.aim` on a hand-built leg and
//! neck. No device, no asset and no allocator under test.

const std = @import("std");
const core = @import("core");

const ik = @import("ik.zig");
const pose_mod = @import("pose.zig");
const skeleton_mod = @import("skeleton.zig");

const Mat4 = core.math.Mat4;
const Pose = pose_mod.Pose;
const Quat = core.math.Quat;
const Skeleton = skeleton_mod.Skeleton;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;

const no_parent = skeleton_mod.no_parent;
const t = std.testing;

// ---------------------------------------------------------------------------------------------
// Fixtures: a pelvis with one leg, a hip, a knee and a foot, and a chest with a neck and a head.

const pelvis = 0;
const hip = 1;
const knee = 2;
const foot = 3;
const chest = 4;
const neck = 5;
const head = 6;
const joints = 7;

const parents = [_]u16{ no_parent, pelvis, hip, knee, pelvis, chest, neck };
/// The knee sits 2 cm forward of the line, as a clip's would, so a leg knows its bend.
const rest = [_]Transform{
    .{ .translation = .init(0, 0.9, 0) },
    .{ .translation = .init(0.12, 0, 0) },
    .{ .translation = .init(0, -0.4, -0.02) },
    .{ .translation = .init(0, -0.37, 0.02) },
    .{ .translation = .init(0, 0.45, 0) },
    .{ .translation = .init(0, 0.13, 0) },
    .{ .translation = .init(0, 0.12, 0) },
};
const inverse_bind: [joints]Mat4 = @splat(Mat4.identity);
const skeleton: Skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &inverse_bind };

const leg: ik.TwoBone = .{ .root = hip, .middle = knee, .end = foot };
const gaze_joints = [_]ik.AimJoint{ .{ .joint = neck, .share = 0.4 }, .{ .joint = head, .share = 0.6 } };
const gaze: ik.AimChain = .{ .joints = &gaze_joints, .limit = 1.2 };

/// The rest pose with a clip's bend in it: rotations that are not the identity, so that a solve which
/// touched them would show in their last bits.
fn posed() [joints]Transform {
    var out = rest;
    out[hip].rotation = Quat.fromAxisAngle(.right, 0.3);
    out[knee].rotation = Quat.fromAxisAngle(.right, -0.5);
    // Unit only to a clip's precision, as keys written by an exporter are: normalising would move them.
    out[neck].rotation = .{ .x = 0, .y = 0.0998, .z = 0, .w = 0.995 };
    out[head].rotation = .{ .x = -0.07, .y = -0.021, .z = 0, .w = 0.9973 };
    return out;
}

fn at(local: *[joints]Transform, joint: u16) Vec3 {
    return at3(skeleton, local, joint);
}

fn at3(s: Skeleton, local: *[joints]Transform, joint: u16) Vec3 {
    const m = ik.modelOf(s, .{ .local = local }, joint);
    return .init(m.cols[3][0], m.cols[3][1], m.cols[3][2]);
}

/// The knee pushed half a metre forward, as a game passes a leg's pole.
fn poleOf(local: *[joints]Transform) Vec3 {
    return at(local, knee).add(.init(0, 0, -0.5));
}

fn facing(local: *[joints]Transform) Vec3 {
    const m = ik.modelOf(skeleton, .{ .local = local }, head);
    return m.mulDirection(Vec3.forward).normalize();
}

// ---------------------------------------------------------------------------------------------

test "a chain is a chain, and an aim's joints, shares, forward and limit are refused by name" {
    try leg.validate(skeleton);
    try (ik.TwoBone{ .root = pelvis, .middle = knee, .end = foot }).validate(skeleton);
    try t.expectError(error.NotAChain, (ik.TwoBone{ .root = hip, .middle = hip, .end = foot }).validate(skeleton));
    try t.expectError(error.NotAChain, (ik.TwoBone{ .root = chest, .middle = knee, .end = foot }).validate(skeleton));
    try t.expectError(error.NotAChain, (ik.TwoBone{ .root = knee, .middle = knee, .end = foot }).validate(skeleton));
    try t.expectError(error.NotAChain, (ik.TwoBone{ .root = hip, .middle = knee, .end = joints }).validate(skeleton));

    try gaze.validate(skeleton);
    const Case = struct { chain: ik.AimChain, err: anyerror };
    const five = [_]ik.AimJoint{ .{ .joint = pelvis, .share = 1 }, .{ .joint = chest, .share = 1 }, .{ .joint = neck, .share = 1 }, .{ .joint = head, .share = 1 }, .{ .joint = head, .share = 1 } };
    const cases = [_]Case{
        .{ .chain = .{ .joints = &.{} }, .err = error.NotAChain },
        .{ .chain = .{ .joints = &five }, .err = error.NotAChain },
        .{ .chain = .{ .joints = &.{ .{ .joint = head, .share = 1 }, .{ .joint = neck, .share = 1 } } }, .err = error.NotAChain },
        .{ .chain = .{ .joints = &.{ .{ .joint = neck, .share = 1 }, .{ .joint = foot, .share = 1 } } }, .err = error.NotAChain },
        .{ .chain = .{ .joints = &.{.{ .joint = joints, .share = 1 }} }, .err = error.NotAChain },
        .{ .chain = .{ .joints = &.{.{ .joint = head, .share = 0 }} }, .err = error.InvalidAimWeight },
        .{ .chain = .{ .joints = &.{.{ .joint = head, .share = std.math.nan(f32) }} }, .err = error.InvalidAimWeight },
        .{ .chain = .{ .joints = &.{.{ .joint = head, .share = 1 }}, .forward = .zero }, .err = error.InvalidForward },
        .{ .chain = .{ .joints = &.{.{ .joint = head, .share = 1 }}, .limit = 0 }, .err = error.InvalidLimit },
        .{ .chain = .{ .joints = &.{.{ .joint = head, .share = 1 }}, .limit = 3.2 }, .err = error.InvalidLimit },
    };
    for (cases) |case| try t.expectError(case.err, case.chain.validate(skeleton));
}

test "two bones reach a reachable target within 1e-4, with the knee on the pole's side" {
    const targets = [_]Vec3{
        .init(0.12, 0.25, 0),
        .init(0.12, 0.35, -0.2),
        .init(0.3, 0.2, 0.1),
        .init(0.0, 0.5, -0.3),
        .init(0.12, 0.6, 0.25),
    };
    for (targets) |target| {
        for ([_]f32{ -0.5, 0.5 }) |push| {
            var local = posed();
            const pole = at(&local, knee).add(.init(0, 0, push));
            ik.twoBone(skeleton, .{ .local = &local }, leg, target, pole, 1);
            try t.expect(at(&local, foot).sub(target).length() < 1e-4);
            // The bones keep their lengths: only rotations changed.
            try t.expectApproxEqAbs(rest[knee].translation.length(), at(&local, knee).sub(at(&local, hip)).length(), 1e-5);
            // The knee bends toward the pole.
            const a = at(&local, hip);
            const along = target.sub(a).normalize();
            const off = pole.sub(a);
            const across = off.sub(along.scale(off.dot(along))).normalize();
            try t.expect(at(&local, knee).sub(a).dot(across) > 0);
        }
    }
    // A root that is an ancestor, not the middle's parent, reaches as well.
    var local = posed();
    const target = Vec3.init(0.1, 0.3, -0.1);
    ik.twoBone(skeleton, .{ .local = &local }, .{ .root = pelvis, .middle = knee, .end = foot }, target, poleOf(&local), 1);
    try t.expect(at(&local, foot).sub(target).length() < 1e-4);
}

test "a target out of reach straightens the leg toward it, and one too close is held off" {
    var local = posed();
    const far = Vec3.init(0.12, -2, -0.5);
    ik.twoBone(skeleton, .{ .local = &local }, leg, far, poleOf(&local), 1);
    const a = at(&local, hip);
    const reach = at(&local, foot).sub(a);
    const upper = rest[knee].translation.length();
    const lower = rest[foot].translation.length();
    // Straight, toward the target, never past what the bones can do.
    try t.expectApproxEqAbs(upper + lower - ik.straight_margin, reach.length(), 2e-5);
    try t.expect(reach.normalize().cross(far.sub(a).normalize()).length() < 1e-4);
    for (local) |joint| try t.expect(joint.rotation.isUnit());

    // At the hip itself the leg folds only as far as its bones allow.
    var close = posed();
    ik.twoBone(skeleton, .{ .local = &close }, leg, at(&close, hip), poleOf(&close), 1);
    const folded = at(&close, foot).sub(at(&close, hip)).length();
    try t.expectApproxEqAbs(@abs(upper - lower) + ik.straight_margin, folded, 2e-5);
    for (close) |joint| try t.expect(joint.rotation.isUnit());
}

test "two bones at weight 0 leave the pose bit for bit, and at 1 are the solve" {
    const target = Vec3.init(0.12, 0.35, -0.2);
    for ([_]f32{ 0, -1, std.math.nan(f32) }) |weight| {
        var local = posed();
        ik.twoBone(skeleton, .{ .local = &local }, leg, target, poleOf(&local), weight);
        const before = posed();
        try t.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&local));
    }
    var full = posed();
    var over = posed();
    ik.twoBone(skeleton, .{ .local = &full }, leg, target, poleOf(&full), 1);
    ik.twoBone(skeleton, .{ .local = &over }, leg, target, poleOf(&over), 7);
    try t.expectEqualSlices(u8, std.mem.asBytes(&full), std.mem.asBytes(&over));
    // Half way leaves the foot between where it was and the target.
    var half = posed();
    ik.twoBone(skeleton, .{ .local = &half }, leg, target, poleOf(&half), 0.5);
    var untouched = posed();
    const gap = at(&untouched, foot).sub(target).length();
    const left = at(&half, foot).sub(target).length();
    try t.expect(left > 1e-3 and left < gap);
}

test "two bones under a turned skeleton root still reach within 1e-4" {
    const turned: Skeleton = .{
        .parents = &parents,
        .rest = &rest,
        .inverse_bind = &inverse_bind,
        .root = Mat4.trs(.init(1, 0, 2), Quat.fromAxisAngle(.up, 1.1), .one),
    };
    var local = posed();
    const pole = at3(turned, &local, knee).add(.init(0.3, 0, -0.3));
    const target = at3(turned, &local, foot).add(.init(0.1, 0.25, -0.05));
    ik.twoBone(turned, .{ .local = &local }, leg, target, pole, 1);
    try t.expect(at3(turned, &local, foot).sub(target).length() < 1e-4);
}

test "an aim points the head at a target within its limit, each joint taking its share" {
    const targets = [_]Vec3{ .init(1, 1.6, -2), .init(-1.5, 2, -1), .init(0.5, 1.0, -3), .init(-0.8, 1.5, -0.6) };
    for (targets) |target| {
        var local = posed();
        ik.aim(skeleton, .{ .local = &local }, gaze, target, 1);
        const eye = at(&local, head);
        const look = facing(&local);
        const wanted = target.sub(eye).normalize();
        try t.expect(look.dot(wanted) > 0);
        try t.expect(look.cross(wanted).length() < 1e-4);
    }

    // The neck turns about two fifths of the way, and the head the rest, from a still neck.
    var local = rest;
    ik.aim(skeleton, .{ .local = &local }, gaze, .init(-3, 1.6, -3), 1);
    const neck_turn = angleOf(local[neck].rotation);
    const head_turn = angleOf(local[head].rotation);
    try t.expectApproxEqAbs(@as(f32, 0.4), neck_turn / (neck_turn + head_turn), 0.03);
    // Each turns about its own place: the head stays on its neck.
    try t.expectApproxEqAbs(rest[head].translation.length(), at(&local, head).sub(at(&local, neck)).length(), 1e-5);
}

test "an aim past its limit turns exactly the limit, toward the target" {
    const targets = [_]Vec3{ .init(0, 1.6, 3), .init(2, 1.6, 0.5), .init(-2, 0.2, 1) };
    for (targets) |target| {
        var local = posed();
        const start = facing(&local);
        ik.aim(skeleton, .{ .local = &local }, gaze, target, 1);
        const look = facing(&local);
        try t.expectApproxEqAbs(@cos(gaze.limit), look.dot(start), 1e-4);
        // Toward the target: it is closer than before.
        try t.expect(look.dot(target.sub(at(&local, head)).normalize()) > start.dot(target.sub(at(&local, head)).normalize()));
    }
}

test "an aim at weight 0 leaves the pose bit for bit, and between turns part way" {
    const target = Vec3.init(-1.5, 2, -1);
    for ([_]f32{ 0, -2, std.math.nan(f32) }) |weight| {
        var local = posed();
        ik.aim(skeleton, .{ .local = &local }, gaze, target, weight);
        const before = posed();
        try t.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&local));
    }
    var untouched = posed();
    const start = facing(&untouched);
    var full = posed();
    ik.aim(skeleton, .{ .local = &full }, gaze, target, 1);
    var half = posed();
    ik.aim(skeleton, .{ .local = &half }, gaze, target, 0.5);
    const whole = start.dot(facing(&full));
    const part = start.dot(facing(&half));
    try t.expect(part < 1 and part > whole);
}

test "fromTo is the shortest arc, and opposite directions turn half way round" {
    const pairs = [_][2]Vec3{
        .{ .init(1, 0, 0), .init(0, 1, 0) },
        .{ .init(0, 0, -1), .init(0.6, 0, -0.8) },
        .{ .init(0, 1, 0), .init(0, -1, 0) },
        .{ .init(0.3, 0.4, 0.5), .init(-0.3, -0.4, -0.5) },
    };
    for (pairs) |pair| {
        const q = ik.fromTo(pair[0], pair[1]);
        try t.expect(q.isUnit());
        try t.expect(q.rotate(pair[0].normalize()).sub(pair[1].normalize()).length() < 1e-5);
    }
}

fn angleOf(q: Quat) f32 {
    const w = @min(1, @abs(q.w));
    return 2 * std.math.acos(w);
}
