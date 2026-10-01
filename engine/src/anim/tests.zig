//! `animation3d.md` §12's `anim` tests: every refusal, sampling against hand-computed values,
//! skinning against a hand-computed strip and an independent `f64` reference, and a replay.
//!
//! No device, no asset and no allocator in anything under test: the only allocations here are
//! the tests' own buffers.

const std = @import("std");
const core = @import("core");

const clip_mod = @import("clip.zig");
const pose_mod = @import("pose.zig");
const skeleton_mod = @import("skeleton.zig");
const skinning = @import("skin.zig");

const Clip = clip_mod.Clip;
const Mat4 = core.math.Mat4;
const Pose = pose_mod.Pose;
const Quat = core.math.Quat;
const Skeleton = skeleton_mod.Skeleton;
const Track = clip_mod.Track;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;

const no_parent = skeleton_mod.no_parent;
const t = std.testing;
const tolerance: f32 = 1e-5;

// ---------------------------------------------------------------------------------------------
// Fixtures

/// Three joints stacked a metre apart along +Y, each the child of the one below.
const chain_parents = [_]u16{ no_parent, 0, 1 };
const chain_rest = [_]Transform{
    .{},
    .{ .translation = .init(0, 1, 0) },
    .{ .translation = .init(0, 1, 0) },
};
const chain_inverse_bind = [_]Mat4{
    Mat4.identity,
    Mat4.translation(.init(0, -1, 0)),
    Mat4.translation(.init(0, -2, 0)),
};
const chain: Skeleton = .{ .parents = &chain_parents, .rest = &chain_rest, .inverse_bind = &chain_inverse_bind };

fn quarterZ() Quat {
    return Quat.fromAxisAngle(.init(0, 0, 1), std.math.pi / 2.0);
}

fn expectVec3(expected: Vec3, actual: Vec3) !void {
    try t.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try t.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try t.expectApproxEqAbs(expected.z, actual.z, tolerance);
}

fn expectXyz(expected: [3]f32, actual: [3]f32) !void {
    for (expected, actual) |e, a| try t.expectApproxEqAbs(e, a, tolerance);
}

// ---------------------------------------------------------------------------------------------
// Validation

test "skeleton: a valid chain is accepted, with one root or several" {
    try chain.validate();
    try t.expectEqual(@as(usize, 3), chain.jointCount());
    const two_roots: Skeleton = .{ .parents = &.{ no_parent, no_parent, 0 }, .rest = &chain_rest, .inverse_bind = &chain_inverse_bind };
    try two_roots.validate();
}

test "skeleton: every refusal is named" {
    try t.expectError(error.NoJoints, (Skeleton{ .parents = &.{}, .rest = &.{}, .inverse_bind = &.{} }).validate());

    const many_parents: [skeleton_mod.max_joints + 1]u16 = @splat(no_parent);
    const many_rest: [skeleton_mod.max_joints + 1]Transform = @splat(.{});
    const many_bind: [skeleton_mod.max_joints + 1]Mat4 = @splat(Mat4.identity);
    try t.expectError(error.TooManyJoints, (Skeleton{ .parents = &many_parents, .rest = &many_rest, .inverse_bind = &many_bind }).validate());
    try (Skeleton{ .parents = many_parents[0..skeleton_mod.max_joints], .rest = many_rest[0..skeleton_mod.max_joints], .inverse_bind = many_bind[0..skeleton_mod.max_joints] }).validate();

    try t.expectError(error.LengthMismatch, (Skeleton{ .parents = &chain_parents, .rest = chain_rest[0..2], .inverse_bind = &chain_inverse_bind }).validate());
    try t.expectError(error.LengthMismatch, (Skeleton{ .parents = &chain_parents, .rest = &chain_rest, .inverse_bind = chain_inverse_bind[0..2] }).validate());

    // A parent after its child, a joint that is its own parent, and a parent that does not exist.
    try t.expectError(error.ParentOutOfOrder, (Skeleton{ .parents = &.{ no_parent, 2, 0 }, .rest = &chain_rest, .inverse_bind = &chain_inverse_bind }).validate());
    try t.expectError(error.ParentOutOfOrder, (Skeleton{ .parents = &.{ no_parent, 1, 1 }, .rest = &chain_rest, .inverse_bind = &chain_inverse_bind }).validate());
    try t.expectError(error.ParentOutOfOrder, (Skeleton{ .parents = &.{ 0, 0, 1 }, .rest = &chain_rest, .inverse_bind = &chain_inverse_bind }).validate());
    try t.expectError(error.ParentOutOfOrder, (Skeleton{ .parents = &.{ no_parent, 0, 900 }, .rest = &chain_rest, .inverse_bind = &chain_inverse_bind }).validate());

    var rest = chain_rest;
    rest[1].translation.x = std.math.nan(f32);
    try t.expectError(error.InvalidRest, (Skeleton{ .parents = &chain_parents, .rest = &rest, .inverse_bind = &chain_inverse_bind }).validate());
    rest = chain_rest;
    rest[2].rotation = .{ .x = 0, .y = 0, .z = 0, .w = 0 };
    try t.expectError(error.InvalidRest, (Skeleton{ .parents = &chain_parents, .rest = &rest, .inverse_bind = &chain_inverse_bind }).validate());

    var bind = chain_inverse_bind;
    bind[1].cols[3][0] = std.math.inf(f32);
    try t.expectError(error.InvalidInverseBind, (Skeleton{ .parents = &chain_parents, .rest = &chain_rest, .inverse_bind = &bind }).validate());
    bind = chain_inverse_bind;
    bind[2].cols[1][3] = 0.5; // a projective row: not affine
    try t.expectError(error.InvalidInverseBind, (Skeleton{ .parents = &chain_parents, .rest = &chain_rest, .inverse_bind = &bind }).validate());

    var root = Mat4.identity;
    root.cols[3][3] = 2;
    try t.expectError(error.InvalidRoot, (Skeleton{ .parents = &chain_parents, .rest = &chain_rest, .inverse_bind = &chain_inverse_bind, .root = root }).validate());
}

fn one(track: Track, duration: f32) Clip.ValidateError!void {
    return (Clip{ .duration = duration, .tracks = &.{track} }).validate(3);
}

test "clip: every refusal is named" {
    const good: Track = .{ .joint = 1, .path = .translation, .times = &.{ 0, 1 }, .values = &.{ 0, 0, 0, 1, 0, 0 } };
    try one(good, 1);
    try (Clip{ .duration = 1, .tracks = &.{} }).validate(3);

    try t.expectError(error.InvalidDuration, one(good, 0));
    try t.expectError(error.InvalidDuration, one(good, -1));
    try t.expectError(error.InvalidDuration, one(good, std.math.inf(f32)));
    try t.expectError(error.InvalidDuration, one(good, std.math.nan(f32)));

    const too_many: [clip_mod.max_tracks + 1]Track = @splat(good);
    try t.expectError(error.TooManyTracks, (Clip{ .duration = 1, .tracks = &too_many }).validate(3));

    try t.expectError(error.EmptyTrack, one(.{ .joint = 0, .path = .scale, .times = &.{}, .values = &.{} }, 1));

    const long_times: [clip_mod.max_keys_per_track + 1]f32 = @splat(0);
    try t.expectError(error.TooManyKeys, one(.{ .joint = 0, .path = .scale, .times = &long_times, .values = &.{} }, 1));

    try t.expectError(error.ValueCountMismatch, one(.{ .joint = 0, .path = .translation, .times = &.{ 0, 1 }, .values = &.{ 0, 0, 0, 1, 0 } }, 1));
    // Three floats a key is a translation's width, not a rotation's.
    try t.expectError(error.ValueCountMismatch, one(.{ .joint = 0, .path = .rotation, .times = &.{0}, .values = &.{ 0, 0, 1 } }, 1));

    try t.expectError(error.UnknownJoint, one(.{ .joint = 3, .path = .translation, .times = &.{0}, .values = &.{ 0, 0, 0 } }, 1));
    // The same clip is fine for a skeleton that has the joint.
    try (Clip{ .duration = 1, .tracks = &.{.{ .joint = 3, .path = .translation, .times = &.{0}, .values = &.{ 0, 0, 0 } }} }).validate(4);

    try t.expectError(error.DuplicateTrack, (Clip{ .duration = 1, .tracks = &.{ good, good } }).validate(3));
    // A second path on the same joint is not a duplicate.
    try (Clip{ .duration = 1, .tracks = &.{ good, .{ .joint = 1, .path = .scale, .times = &.{0}, .values = &.{ 1, 1, 1 } } } }).validate(3);

    try t.expectError(error.InvalidTime, one(.{ .joint = 0, .path = .scale, .times = &.{-0.5}, .values = &.{ 1, 1, 1 } }, 1));
    try t.expectError(error.InvalidTime, one(.{ .joint = 0, .path = .scale, .times = &.{1.5}, .values = &.{ 1, 1, 1 } }, 1));
    try t.expectError(error.InvalidTime, one(.{ .joint = 0, .path = .scale, .times = &.{std.math.nan(f32)}, .values = &.{ 1, 1, 1 } }, 1));

    try t.expectError(error.UnsortedTimes, one(.{ .joint = 0, .path = .scale, .times = &.{ 0.5, 0.25 }, .values = &.{ 1, 1, 1, 1, 1, 1 } }, 1));
    try t.expectError(error.UnsortedTimes, one(.{ .joint = 0, .path = .scale, .times = &.{ 0.5, 0.5 }, .values = &.{ 1, 1, 1, 1, 1, 1 } }, 1));

    try t.expectError(error.InvalidValue, one(.{ .joint = 0, .path = .scale, .times = &.{0}, .values = &.{ 1, std.math.inf(f32), 1 } }, 1));
    try t.expectError(error.InvalidRotation, one(.{ .joint = 0, .path = .rotation, .times = &.{0}, .values = &.{ 1, 1, 1, 1 } }, 1));
    try t.expectError(error.InvalidRotation, one(.{ .joint = 0, .path = .rotation, .times = &.{0}, .values = &.{ 0, 0, 0, 0 } }, 1));
}

test "influences: every refusal is named" {
    const joints = [_][4]u8{ .{ 0, 1, 0, 0 }, .{ 2, 0, 0, 0 } };
    const weights = [_][4]f32{ .{ 0.25, 0.75, 0, 0 }, .{ 1, 0, 0, 0 } };
    try skinning.validateInfluences(&joints, &weights, 3);

    try t.expectError(error.LengthMismatch, skinning.validateInfluences(&joints, weights[0..1], 3));
    // Joint 2 carries weight and a two-joint skeleton has no joint 2.
    try t.expectError(error.JointOutOfRange, skinning.validateInfluences(&joints, &weights, 2));
    // An unweighted slot's index is never read, so it may hold anything.
    try skinning.validateInfluences(&.{.{ 0, 200, 200, 200 }}, &.{.{ 1, 0, 0, 0 }}, 1);

    try t.expectError(error.InvalidWeight, skinning.validateInfluences(&.{.{ 0, 1, 0, 0 }}, &.{.{ 1.5, -0.5, 0, 0 }}, 3));
    try t.expectError(error.InvalidWeight, skinning.validateInfluences(&.{.{ 0, 1, 0, 0 }}, &.{.{ std.math.nan(f32), 1, 0, 0 }}, 3));
    try t.expectError(error.InvalidWeight, skinning.validateInfluences(&.{.{ 0, 0, 0, 0 }}, &.{.{ 0, 0, 0, 0 }}, 3));
    try t.expectError(error.InvalidWeight, skinning.validateInfluences(&.{.{ 0, 1, 0, 0 }}, &.{.{ 0.5, 0.25, 0, 0 }}, 3));
}

// ---------------------------------------------------------------------------------------------
// Sampling

/// A rest pose that is nowhere the identity, so a path a clip leaves alone shows whether it
/// kept rest or was reset.
const posed_rest = [_]Transform{
    .{ .translation = .init(0, 0.5, 0), .scale = .init(2, 2, 2) },
    .{ .translation = .init(0, 1, 0), .rotation = .{ .x = 0, .y = 0.6, .z = 0, .w = 0.8 } },
    .{ .translation = .init(0.25, 1, 0) },
};
const posed: Skeleton = .{ .parents = &chain_parents, .rest = &posed_rest, .inverse_bind = &chain_inverse_bind };

test "sample: on a key, between keys, and held outside the track" {
    const clip: Clip = .{ .duration = 3, .tracks = &.{
        .{ .joint = 1, .path = .translation, .times = &.{ 0.5, 1, 2 }, .values = &.{ 0, 0, 0, 2, 0, 0, 2, 4, 0 } },
    } };
    try clip.validate(3);
    var local: [3]Transform = undefined;
    const out: Pose = .{ .local = &local };

    pose_mod.sample(posed, clip, 0.75, out);
    try expectVec3(.init(1, 0, 0), local[1].translation);
    pose_mod.sample(posed, clip, 1, out);
    try t.expectEqual(Vec3.init(2, 0, 0), local[1].translation);
    pose_mod.sample(posed, clip, 1.25, out);
    try expectVec3(.init(2, 1, 0), local[1].translation);

    // Before the first key the first value holds; after the last, the last.
    pose_mod.sample(posed, clip, 0, out);
    try t.expectEqual(Vec3.init(0, 0, 0), local[1].translation);
    pose_mod.sample(posed, clip, -4, out);
    try t.expectEqual(Vec3.init(0, 0, 0), local[1].translation);
    pose_mod.sample(posed, clip, 2.5, out);
    try t.expectEqual(Vec3.init(2, 4, 0), local[1].translation);
    pose_mod.sample(posed, clip, 100, out);
    try t.expectEqual(Vec3.init(2, 4, 0), local[1].translation);
    // A time that is not a number holds the first key rather than reading out of range.
    pose_mod.sample(posed, clip, std.math.nan(f32), out);
    try t.expectEqual(Vec3.init(0, 0, 0), local[1].translation);
}

test "sample: a path with no track keeps the rest pose" {
    const clip: Clip = .{ .duration = 1, .tracks = &.{
        .{ .joint = 1, .path = .translation, .times = &.{0}, .values = &.{ 9, 9, 9 } },
    } };
    try clip.validate(3);
    var local: [3]Transform = undefined;
    pose_mod.sample(posed, clip, 0.5, .{ .local = &local });

    // Joints 0 and 2 have no track at all.
    try t.expectEqual(posed_rest[0], local[0]);
    try t.expectEqual(posed_rest[2], local[2]);
    // Joint 1's translation is animated; its rotation and scale are still the rest's.
    try t.expectEqual(Vec3.init(9, 9, 9), local[1].translation);
    try t.expectEqual(posed_rest[1].rotation, local[1].rotation);
    try t.expectEqual(posed_rest[1].scale, local[1].scale);
}

test "sample: step holds the earlier key, and scale interpolates linearly" {
    const clip: Clip = .{ .duration = 2, .tracks = &.{
        .{ .joint = 0, .path = .translation, .interpolation = .step, .times = &.{ 0, 1 }, .values = &.{ 1, 0, 0, 5, 0, 0 } },
        .{ .joint = 2, .path = .scale, .times = &.{ 0, 2 }, .values = &.{ 1, 1, 1, 3, 5, 1 } },
    } };
    try clip.validate(3);
    var local: [3]Transform = undefined;
    const out: Pose = .{ .local = &local };

    pose_mod.sample(posed, clip, 0.99, out);
    try t.expectEqual(Vec3.init(1, 0, 0), local[0].translation);
    try expectVec3(.init(1.99, 2.98, 1), local[2].scale);
    pose_mod.sample(posed, clip, 1, out);
    try t.expectEqual(Vec3.init(5, 0, 0), local[0].translation);
    try expectVec3(.init(2, 3, 1), local[2].scale);
}

test "sample: rotation takes the shorter arc across a sign flip" {
    // The second key is a quarter turn about Z, stored negated: the same rotation, in the
    // other hemisphere. Halfway is an eighth of a turn, not three eighths the long way round.
    const q = quarterZ().neg();
    const clip: Clip = .{ .duration = 1, .tracks = &.{
        .{ .joint = 1, .path = .rotation, .times = &.{ 0, 1 }, .values = &.{ 0, 0, 0, 1, q.x, q.y, q.z, q.w } },
    } };
    try clip.validate(3);
    var local: [3]Transform = undefined;
    pose_mod.sample(posed, clip, 0.5, .{ .local = &local });

    const eighth = Quat.fromAxisAngle(.init(0, 0, 1), std.math.pi / 4.0);
    try t.expect(Quat.approxEql(eighth, local[1].rotation, tolerance));
    try t.expectApproxEqAbs(@as(f32, 1), local[1].rotation.length(), tolerance);

    // A held key that was accepted slightly off unit is stored unit.
    const loose: Clip = .{ .duration = 1, .tracks = &.{
        .{ .joint = 1, .path = .rotation, .times = &.{0}, .values = &.{ 0, 0.707, 0, 0.707 } },
    } };
    try loose.validate(3);
    pose_mod.sample(posed, loose, 0.5, .{ .local = &local });
    try t.expectApproxEqAbs(@as(f32, 1), local[1].rotation.length(), 1e-6);
}

test "wrap and clamp" {
    try t.expectEqual(@as(f32, 0), pose_mod.wrap(0, 2));
    try t.expectEqual(@as(f32, 0.5), pose_mod.wrap(0.5, 2));
    try t.expectEqual(@as(f32, 0), pose_mod.wrap(2, 2));
    try t.expectEqual(@as(f32, 0.5), pose_mod.wrap(6.5, 2));
    try t.expectEqual(@as(f32, 1.5), pose_mod.wrap(-0.5, 2));
    // A negative time too small to subtract from the duration starts the loop, never ends it.
    try t.expect(pose_mod.wrap(-1e-12, 2) < 2);
    try t.expectEqual(@as(f32, 0), pose_mod.wrap(std.math.inf(f32), 2));
    try t.expectEqual(@as(f32, 0), pose_mod.wrap(std.math.nan(f32), 2));

    try t.expectEqual(@as(f32, 0), pose_mod.clamp(-3, 2));
    try t.expectEqual(@as(f32, 1.25), pose_mod.clamp(1.25, 2));
    try t.expectEqual(@as(f32, 2), pose_mod.clamp(2, 2));
    try t.expectEqual(@as(f32, 2), pose_mod.clamp(7, 2));
    try t.expectEqual(@as(f32, 0), pose_mod.clamp(std.math.nan(f32), 2));
}

test "blend: 0 is the first pose, 1 the second, and between mixes each path" {
    var a_local = [_]Transform{.{ .translation = .init(0, 0, 0), .scale = .init(1, 1, 1) }};
    var b_local = [_]Transform{.{ .translation = .init(4, 2, 0), .rotation = quarterZ(), .scale = .init(3, 1, 1) }};
    var out_local: [1]Transform = undefined;
    const a: Pose = .{ .local = &a_local };
    const b: Pose = .{ .local = &b_local };
    const out: Pose = .{ .local = &out_local };

    pose_mod.blend(a, b, 0, out);
    try t.expectEqual(a_local[0], out_local[0]);
    pose_mod.blend(a, b, 1, out);
    try t.expectEqual(b_local[0], out_local[0]);
    // Outside the range is clamped, and a weight that is not a number is 0.
    pose_mod.blend(a, b, -2, out);
    try t.expectEqual(a_local[0], out_local[0]);
    pose_mod.blend(a, b, 7, out);
    try t.expectEqual(b_local[0], out_local[0]);
    pose_mod.blend(a, b, std.math.nan(f32), out);
    try t.expectEqual(a_local[0], out_local[0]);

    pose_mod.blend(a, b, 0.25, out);
    try expectVec3(.init(1, 0.5, 0), out_local[0].translation);
    try expectVec3(.init(1.5, 1, 1), out_local[0].scale);
    try t.expect(Quat.approxEql(Quat.fromAxisAngle(.init(0, 0, 1), std.math.pi / 8.0), out_local[0].rotation, tolerance));

    // The output may be one of the inputs.
    pose_mod.blend(a, b, 0.25, a);
    try t.expectEqual(out_local[0], a_local[0]);
}

// ---------------------------------------------------------------------------------------------
// Matrices

/// A quarter turn about +Z: +X goes to +Y and +Y to −X.
fn quarterZAt(x: f32, y: f32, z: f32) Mat4 {
    return .{ .cols = .{
        .{ 0, 1, 0, 0 },
        .{ -1, 0, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ x, y, z, 1 },
    } };
}

test "skin matrices: the rest pose is the identity" {
    var local = chain_rest;
    var matrices: [3]Mat4 = undefined;
    pose_mod.skinMatrices(chain, .{ .local = &local }, &matrices);
    for (matrices) |m| try t.expect(Mat4.approxEql(Mat4.identity, m, tolerance));
}

test "skin and model matrices: a three-joint chain bent at the middle joint, by hand" {
    var local = chain_rest;
    local[1].rotation = quarterZ();
    const pose: Pose = .{ .local = &local };

    // Joint 1 turns a quarter about its own origin at (0, 1, 0), so joint 2, a metre above
    // it at rest, swings to (−1, 1, 0).
    var model: [3]Mat4 = undefined;
    pose_mod.modelMatrices(chain, pose, &model);
    try t.expect(Mat4.approxEql(Mat4.identity, model[0], tolerance));
    try t.expect(Mat4.approxEql(quarterZAt(0, 1, 0), model[1], tolerance));
    try t.expect(Mat4.approxEql(quarterZAt(-1, 1, 0), model[2], tolerance));

    // Joint 2 does not turn against joint 1, so both carry the same rigid motion: the quarter
    // turn about (0, 1, 0), which sends the origin to (1, 1, 0).
    var skin: [3]Mat4 = undefined;
    pose_mod.skinMatrices(chain, pose, &skin);
    try t.expect(Mat4.approxEql(Mat4.identity, skin[0], tolerance));
    try t.expect(Mat4.approxEql(quarterZAt(1, 1, 0), skin[1], tolerance));
    try t.expect(Mat4.approxEql(quarterZAt(1, 1, 0), skin[2], tolerance));
    try expectVec3(.init(-1, 1, 0), skin[2].mulPoint(.init(0, 2, 0)));
    try expectVec3(.init(-1.5, 1, 0), skin[2].mulPoint(.init(0, 2.5, 0)));
}

test "skin and model matrices: the skeleton's root is applied once, outermost" {
    var with_root = chain;
    with_root.root = Mat4.translation(.init(5, 0, 0));
    var local = chain_rest;
    local[1].rotation = quarterZ();
    const pose: Pose = .{ .local = &local };

    var model: [3]Mat4 = undefined;
    pose_mod.modelMatrices(with_root, pose, &model);
    try t.expect(Mat4.approxEql(quarterZAt(4, 1, 0), model[2], tolerance));

    var skin: [3]Mat4 = undefined;
    pose_mod.skinMatrices(with_root, pose, &skin);
    try t.expect(Mat4.approxEql(Mat4.translation(.init(5, 0, 0)), skin[0], tolerance));
    try t.expect(Mat4.approxEql(quarterZAt(6, 1, 0), skin[2], tolerance));
}

// ---------------------------------------------------------------------------------------------
// Skinning

test "skin: a bent two-joint strip matches hand-computed positions, normals and tangents" {
    // Joint 0 at the origin and joint 1 a metre up; joint 1 turns a quarter about +Z.
    const skin_matrices = [_]Mat4{ Mat4.identity, quarterZAt(1, 1, 0) };

    const positions = [_][3]f32{ .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 2, 0 }, .{ 0.2, 1.5, 0 }, .{ 0.2, 1, 0 } };
    const normals = [_][3]f32{ .{ 1, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 } };
    const tangents = [_][4]f32{ .{ 0, 1, 0, 1 }, .{ 0, 1, 0, 1 }, .{ 0, 1, 0, -1 }, .{ 0, 1, 0, 1 }, .{ 0, 1, 0, 1 } };
    const joints = [_][4]u8{ .{ 0, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 1, 0, 0, 0 } };
    const weights = [_][4]f32{ .{ 1, 0, 0, 0 }, .{ 0.5, 0.5, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 1, 0, 0, 0 }, .{ 0.5, 0.5, 0, 0 } };
    try skinning.validateInfluences(&joints, &weights, 2);

    var out_positions: [5][3]f32 = undefined;
    var out_normals: [5][3]f32 = undefined;
    var out_tangents: [5][4]f32 = undefined;
    skinning.skin(
        .{ .positions = &positions, .normals = &normals, .tangents = &tangents, .joints = &joints, .weights = &weights },
        &skin_matrices,
        0,
        5,
        .{ .positions = &out_positions, .normals = &out_normals, .tangents = &out_tangents },
    );

    const h = @sqrt(0.5);
    // Bound to joint 0 alone: unmoved.
    try expectXyz(.{ 0, 0, 0 }, out_positions[0]);
    try expectXyz(.{ 1, 0, 0 }, out_normals[0]);
    // On the hinge, half to each joint: the point stays, and its normal is the bisector.
    try expectXyz(.{ 0, 1, 0 }, out_positions[1]);
    try expectXyz(.{ h, h, 0 }, out_normals[1]);
    try expectXyz(.{ -h, h, 0 }, out_tangents[1][0..3].*);
    // The tip, bound to joint 1 alone: swung from a metre above the hinge to a metre beside it.
    try expectXyz(.{ -1, 1, 0 }, out_positions[2]);
    try expectXyz(.{ 0, 1, 0 }, out_normals[2]);
    try expectXyz(.{ -1, 0, 0 }, out_tangents[2][0..3].*);
    try t.expectEqual(@as(f32, -1), out_tangents[2][3]);
    try expectXyz(.{ -0.5, 1.2, 0 }, out_positions[3]);
    // Half each of where joint 0 leaves it, (0.2, 1, 0), and where joint 1 takes it, (0, 1.2, 0).
    try expectXyz(.{ 0.1, 1.1, 0 }, out_positions[4]);
    // A normal along the hinge's axis does not turn.
    try expectXyz(.{ 0, 0, 1 }, out_normals[4]);
    try t.expectEqual(@as(f32, 1), out_tangents[4][3]);
}

test "skin: only the requested range is written, and absent streams stay absent" {
    const skin_matrices = [_]Mat4{Mat4.translation(.init(1, 0, 0))};
    const positions = [_][3]f32{ .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 2, 0 } };
    const joints: [3][4]u8 = @splat(.{ 0, 0, 0, 0 });
    const weights: [3][4]f32 = @splat(.{ 1, 0, 0, 0 });
    var out: [3][3]f32 = @splat(.{ 7, 7, 7 });
    skinning.skin(.{ .positions = &positions, .joints = &joints, .weights = &weights }, &skin_matrices, 1, 2, .{ .positions = &out });
    try t.expectEqual([3]f32{ 7, 7, 7 }, out[0]);
    try t.expectEqual([3]f32{ 1, 1, 0 }, out[1]);
    try t.expectEqual([3]f32{ 7, 7, 7 }, out[2]);
}

const Fixture = struct {
    const joint_count = 12;
    const vertex_count = 1000;

    parents: [joint_count]u16,
    rest: [joint_count]Transform,
    inverse_bind: [joint_count]Mat4,
    posed: [joint_count]Transform,
    matrices: [joint_count]Mat4,
    positions: [vertex_count][3]f32,
    normals: [vertex_count][3]f32,
    tangents: [vertex_count][4]f32,
    joints: [vertex_count][4]u8,
    weights: [vertex_count][4]f32,

    fn skeleton(f: *const Fixture) Skeleton {
        return .{ .parents = &f.parents, .rest = &f.rest, .inverse_bind = &f.inverse_bind };
    }

    fn input(f: *const Fixture) skinning.Input {
        return .{ .positions = &f.positions, .normals = &f.normals, .tangents = &f.tangents, .joints = &f.joints, .weights = &f.weights };
    }
};

fn signed(rng: *core.Pcg32) f32 {
    return rng.float01() * 2 - 1;
}

fn randomUnit(rng: *core.Pcg32) Vec3 {
    while (true) {
        const v = Vec3.init(signed(rng), signed(rng), signed(rng));
        if (v.length() > 0.1) return v.normalize();
    }
}

fn randomTransform(rng: *core.Pcg32) Transform {
    return .{
        .translation = Vec3.init(signed(rng), signed(rng), signed(rng)).scale(0.5),
        .rotation = Quat.fromAxisAngle(randomUnit(rng), signed(rng) * std.math.pi),
        .scale = Vec3.one.scale(0.75 + rng.float01() * 0.5),
    };
}

/// A random tree of joints, a random pose of it, and random vertices bound to it by one to
/// four joints each.
fn randomFixture(f: *Fixture, seed: u64) !void {
    var rng = core.Pcg32.init(seed, 24);
    for (0..Fixture.joint_count) |j| {
        f.parents[j] = if (j == 0) no_parent else @intCast(rng.below(@intCast(j)));
        f.rest[j] = randomTransform(&rng);
        f.posed[j] = randomTransform(&rng);
    }
    // Bind matrices are the inverse of the rest pose's model matrices, as an importer makes them.
    f.inverse_bind = @splat(Mat4.identity);
    var model: [Fixture.joint_count]Mat4 = undefined;
    pose_mod.modelMatrices(f.skeleton(), .{ .local = &f.rest }, &model);
    for (&f.inverse_bind, model) |*inverse_bind, m| {
        inverse_bind.* = m.inverse().?;
        // An inverse computed in floats does not keep the last row exact; an importer writes it.
        inverse_bind.cols[0][3] = 0;
        inverse_bind.cols[1][3] = 0;
        inverse_bind.cols[2][3] = 0;
        inverse_bind.cols[3][3] = 1;
    }
    try f.skeleton().validate();
    pose_mod.skinMatrices(f.skeleton(), .{ .local = &f.posed }, &f.matrices);

    for (0..Fixture.vertex_count) |v| {
        f.positions[v] = .{ signed(&rng), signed(&rng), signed(&rng) };
        const n = randomUnit(&rng);
        const tangent = randomUnit(&rng);
        f.normals[v] = .{ n.x, n.y, n.z };
        f.tangents[v] = .{ tangent.x, tangent.y, tangent.z, if (rng.boolean()) 1 else -1 };

        const used = 1 + rng.below(4);
        var sum: f32 = 0;
        for (0..4) |i| {
            f.joints[v][i] = @intCast(rng.below(Fixture.joint_count));
            f.weights[v][i] = if (i < used) 0.05 + rng.float01() else 0;
            sum += f.weights[v][i];
        }
        for (&f.weights[v]) |*w| w.* /= sum;
    }
    try skinning.validateInfluences(&f.joints, &f.weights, Fixture.joint_count);
}

/// Linear-blend skinning written the other way round, in `f64`: transform the vertex by each
/// joint's matrix, then weight the results. The kernel blends the matrices first.
fn referencePoint(f: *const Fixture, v: usize, source: [3]f32, w_component: f64) [3]f64 {
    var out = [3]f64{ 0, 0, 0 };
    for (f.joints[v], f.weights[v]) |joint, weight| {
        const m = f.matrices[joint];
        for (0..3) |r| {
            const moved = @as(f64, m.cols[0][r]) * source[0] + @as(f64, m.cols[1][r]) * source[1] +
                @as(f64, m.cols[2][r]) * source[2] + @as(f64, m.cols[3][r]) * w_component;
            out[r] += moved * weight;
        }
    }
    return out;
}

fn normalized64(v: [3]f64) [3]f64 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

test "skin: a randomised fixture matches an independent f64 reference within 1e-5" {
    const f = try t.allocator.create(Fixture);
    defer t.allocator.destroy(f);
    const out_positions = try t.allocator.alloc([3]f32, Fixture.vertex_count);
    defer t.allocator.free(out_positions);
    const out_normals = try t.allocator.alloc([3]f32, Fixture.vertex_count);
    defer t.allocator.free(out_normals);
    const out_tangents = try t.allocator.alloc([4]f32, Fixture.vertex_count);
    defer t.allocator.free(out_tangents);

    for ([_]u64{ 1, 2, 3 }) |seed| {
        try randomFixture(f, seed);
        skinning.skin(f.input(), &f.matrices, 0, Fixture.vertex_count, .{ .positions = out_positions, .normals = out_normals, .tangents = out_tangents });

        var moved: usize = 0;
        for (0..Fixture.vertex_count) |v| {
            const position = referencePoint(f, v, f.positions[v], 1);
            const normal = normalized64(referencePoint(f, v, f.normals[v], 0));
            const tangent = normalized64(referencePoint(f, v, f.tangents[v][0..3].*, 0));
            for (0..3) |r| {
                try t.expectApproxEqAbs(position[r], @as(f64, out_positions[v][r]), 1e-5);
                try t.expectApproxEqAbs(normal[r], @as(f64, out_normals[v][r]), 1e-5);
                try t.expectApproxEqAbs(tangent[r], @as(f64, out_tangents[v][r]), 1e-5);
            }
            try t.expectEqual(f.tangents[v][3], out_tangents[v][3]);
            if (@abs(out_positions[v][0] - f.positions[v][0]) > 0.1) moved += 1;
        }
        // The pose really does move the mesh: a fixture that skinned to itself proves nothing.
        try t.expect(moved > Fixture.vertex_count / 2);
    }
}

const ChunkedSkin = struct {
    fixture: *const Fixture,
    output: skinning.Output,

    fn run(self: *const ChunkedSkin, chunk: core.jobs.Chunk) void {
        skinning.skin(self.fixture.input(), &self.fixture.matrices, chunk.begin, chunk.end, self.output);
    }
};

test "skin: one call and chunked jobs in either order write identical bytes" {
    const f = try t.allocator.create(Fixture);
    defer t.allocator.destroy(f);
    try randomFixture(f, 7);

    const Buffers = struct { positions: [Fixture.vertex_count][3]f32, normals: [Fixture.vertex_count][3]f32, tangents: [Fixture.vertex_count][4]f32 };
    const whole = try t.allocator.create(Buffers);
    defer t.allocator.destroy(whole);
    const chunked = try t.allocator.create(Buffers);
    defer t.allocator.destroy(chunked);

    skinning.skin(f.input(), &f.matrices, 0, Fixture.vertex_count, .{ .positions = &whole.positions, .normals = &whole.normals, .tangents = &whole.tangents });

    for ([_]core.Jobs{ core.jobs.serial, core.jobs.reversed }) |jobs| {
        // A grain that does not divide the count, so the last chunk is short.
        for ([_]u32{ 1, 64, 333 }) |grain| {
            chunked.* = undefined;
            const context: ChunkedSkin = .{ .fixture = f, .output = .{ .positions = &chunked.positions, .normals = &chunked.normals, .tangents = &chunked.tangents } };
            jobs.forChunks(Fixture.vertex_count, grain, &context, ChunkedSkin.run);
            try t.expectEqualSlices(u8, std.mem.asBytes(&whole.positions), std.mem.asBytes(&chunked.positions));
            try t.expectEqualSlices(u8, std.mem.asBytes(&whole.normals), std.mem.asBytes(&chunked.normals));
            try t.expectEqualSlices(u8, std.mem.asBytes(&whole.tangents), std.mem.asBytes(&chunked.tangents));
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Replay

const replay_ticks = 1200;
const replay_joints = 5;

const Replay = struct {
    poses: [replay_ticks][replay_joints]Transform,
    matrices: [replay_ticks][replay_joints]Mat4,
};

/// A hip, two legs of two joints each, a walk that swings them and an idle that sways the hip:
/// the sample's shape (`animation3d.md` §10), sampled at `tick × dt`, cross-faded at a fixed
/// rate per tick, and composed into skin matrices.
fn replay(out: *Replay) !u64 {
    const parents = [replay_joints]u16{ no_parent, 0, 1, 0, 3 };
    const rest = [replay_joints]Transform{
        .{ .translation = .init(0, 0.9, 0) },
        .{ .translation = .init(-0.1, 0, 0) },
        .{ .translation = .init(0, -0.45, 0) },
        .{ .translation = .init(0.1, 0, 0) },
        .{ .translation = .init(0, -0.45, 0) },
    };
    const inverse_bind = [replay_joints]Mat4{
        Mat4.translation(.init(0, -0.9, 0)),
        Mat4.translation(.init(0.1, -0.9, 0)),
        Mat4.translation(.init(0.1, -0.45, 0)),
        Mat4.translation(.init(-0.1, -0.9, 0)),
        Mat4.translation(.init(-0.1, -0.45, 0)),
    };
    const skeleton: Skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &inverse_bind };
    try skeleton.validate();

    // Literals, not `fromAxisAngle`, so every build is handed the same input bits and the
    // pinned hash is of what `anim` computes rather than of how the test made its keys.
    const fore: Quat = .{ .x = 0.29552022, .y = 0, .z = 0, .w = 0.9553365 };
    const back: Quat = .{ .x = -0.29552022, .y = 0, .z = 0, .w = 0.9553365 };
    const bent: Quat = .{ .x = 0.4349655, .y = 0, .z = 0, .w = 0.9004471 };
    const swing = [_]f32{ fore.x, fore.y, fore.z, fore.w, back.x, back.y, back.z, back.w, fore.x, fore.y, fore.z, fore.w };
    const counter = [_]f32{ back.x, back.y, back.z, back.w, fore.x, fore.y, fore.z, fore.w, back.x, back.y, back.z, back.w };
    const knee = [_]f32{ 0, 0, 0, 1, bent.x, bent.y, bent.z, bent.w, 0, 0, 0, 1 };
    const times = [_]f32{ 0, 0.4, 0.8 };
    const walk: Clip = .{ .duration = 0.8, .tracks = &.{
        .{ .joint = 0, .path = .translation, .times = &.{ 0, 0.2, 0.4, 0.6, 0.8 }, .values = &.{ 0, 0.9, 0, 0, 0.93, 0, 0, 0.9, 0, 0, 0.93, 0, 0, 0.9, 0 } },
        .{ .joint = 1, .path = .rotation, .times = &times, .values = &swing },
        .{ .joint = 2, .path = .rotation, .times = &times, .values = &knee },
        .{ .joint = 3, .path = .rotation, .times = &times, .values = &counter },
        .{ .joint = 4, .path = .rotation, .interpolation = .step, .times = &times, .values = &knee },
    } };
    const lean: Quat = .{ .x = 0, .y = 0, .z = 0.024997396, .w = 0.99968752 };
    const idle: Clip = .{ .duration = 2.5, .tracks = &.{
        .{ .joint = 0, .path = .rotation, .times = &.{ 0, 1.25, 2.5 }, .values = &.{ 0, 0, 0, 1, lean.x, lean.y, lean.z, lean.w, 0, 0, 0, 1 } },
    } };
    try walk.validate(replay_joints);
    try idle.validate(replay_joints);

    const dt: f32 = 1.0 / 60.0;
    const fade_per_tick: f32 = 1.0 / 12.0;
    var weight: f32 = 0;
    var walk_local: [replay_joints]Transform = undefined;
    var idle_local: [replay_joints]Transform = undefined;
    for (0..replay_ticks) |tick| {
        // Time comes from the tick count, never from an accumulated `dt`.
        const time = @as(f32, @floatFromInt(tick)) * dt;
        pose_mod.sample(skeleton, idle, pose_mod.wrap(time, idle.duration), .{ .local = &idle_local });
        pose_mod.sample(skeleton, walk, pose_mod.wrap(time, walk.duration), .{ .local = &walk_local });
        const walking = (tick / 150) % 2 == 1;
        weight = if (walking) @min(weight + fade_per_tick, 1) else @max(weight - fade_per_tick, 0);

        const pose: Pose = .{ .local = &out.poses[tick] };
        pose_mod.blend(.{ .local = &idle_local }, .{ .local = &walk_local }, weight, pose);
        pose_mod.skinMatrices(skeleton, pose, &out.matrices[tick]);
    }
    return core.id.fnv1a64(std.mem.asBytes(out));
}

test "replay: 1200 ticks of sampling, blending and skin matrices are byte-identical" {
    const first = try t.allocator.create(Replay);
    defer t.allocator.destroy(first);
    const second = try t.allocator.create(Replay);
    defer t.allocator.destroy(second);
    // Different garbage in each, so equal bytes afterwards are bytes the replay wrote.
    @memset(std.mem.asBytes(first), 0x00);
    @memset(std.mem.asBytes(second), 0xAA);

    const hash = try replay(first);
    try t.expectEqual(hash, try replay(second));
    try t.expectEqualSlices(u8, std.mem.asBytes(first), std.mem.asBytes(second));

    // The run did something: idle, a cross-fade, and full walk all appear.
    try t.expect(!std.mem.eql(u8, std.mem.asBytes(&first.poses[0]), std.mem.asBytes(&first.poses[155])));
    try t.expect(!std.mem.eql(u8, std.mem.asBytes(&first.poses[155]), std.mem.asBytes(&first.poses[200])));

    // Pinned. **Two values, by which `sin` the binary calls**, and for no other reason: `slerp`
    // uses `@sin`, which is Zig's own routine everywhere except an optimised build for Apple
    // silicon, where it binds to the system's and differs in the last bit on some inputs.
    // Either is a correct answer (ADR-0013); a third would be recorded here, not chased.
    const zig_sin: u64 = 0x41a6ac0f9e3a4e42;
    const apple_sin: u64 = 0x37d154bd9aa080f5;
    try t.expect(hash == zig_sin or hash == apple_sin);
}
