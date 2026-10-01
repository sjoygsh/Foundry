//! Linear-blend skinning, on the CPU (`animation3d.md` §5).
//!
//! Each vertex's matrix is the weighted sum of its joints' skin matrices. Positions use the
//! whole matrix. Normals and tangents use its upper 3×3 and are renormalised, which is exact
//! for rigid and uniformly scaled joints; a non-uniformly scaled joint wants the inverse
//! transpose, which is deferred with a trigger (`animation3d.md` §14).

const std = @import("std");
const core = @import("core");

const Mat4 = core.math.Mat4;

/// How many joints may move one vertex.
pub const max_influences: usize = 4;

/// How far from one a vertex's weights may sum. The importer normalises, so this rejects
/// garbage rather than judging precision.
pub const weight_sum_tolerance: f32 = 1e-3;

/// The bind-pose streams, borrowed. Every slice present has one entry per vertex.
pub const Input = struct {
    positions: []const [3]f32,
    normals: ?[]const [3]f32 = null,
    /// `x, y, z` and the handedness `w`, which is copied.
    tangents: ?[]const [4]f32 = null,
    joints: []const [max_influences]u8,
    weights: []const [max_influences]f32,
};

/// Where the skinned streams go, indexed as the input is. A stream is written exactly when the
/// input has it.
pub const Output = struct {
    positions: [][3]f32,
    normals: ?[][3]f32 = null,
    tangents: ?[][4]f32 = null,
};

pub const InfluenceError = error{
    LengthMismatch,
    JointOutOfRange,
    InvalidWeight,
};

/// Refuses vertex influences that `skin` could not use with `joint_count` skin matrices: a
/// weight that is negative or not finite, weights that do not sum to one, or a weighted joint
/// the skeleton lacks. A joint index beside a zero weight is never read, so it is not checked.
pub fn validateInfluences(
    joints: []const [max_influences]u8,
    weights: []const [max_influences]f32,
    joint_count: usize,
) InfluenceError!void {
    if (joints.len != weights.len) return error.LengthMismatch;
    for (joints, weights) |vertex_joints, vertex_weights| {
        var sum: f32 = 0;
        for (vertex_joints, vertex_weights) |joint, weight| {
            if (!std.math.isFinite(weight) or weight < 0) return error.InvalidWeight;
            if (weight == 0) continue;
            if (joint >= joint_count) return error.JointOutOfRange;
            sum += weight;
        }
        if (@abs(sum - 1) > weight_sum_tolerance) return error.InvalidWeight;
    }
}

/// Skins vertices `begin..end` with `matrices`, one per joint, from `anim.skinMatrices`.
///
/// **It takes a range** so a caller can split one mesh across `core.Jobs` chunks. A call writes
/// only its own vertices and reads nothing another call writes, so the result does not depend
/// on how the range was split or in what order the pieces ran (ADR-0036).
///
/// The influences must have passed `validateInfluences` for `matrices.len` joints, and the
/// matrices must be affine, as a validated skeleton's are.
pub fn skin(input: Input, matrices: []const Mat4, begin: u32, end: u32, output: Output) void {
    const count = input.positions.len;
    core.assert.always(begin <= end and end <= count, "skin range {d}..{d} is outside {d} vertices", .{ begin, end, count });
    core.assert.always(input.joints.len == count and input.weights.len == count and output.positions.len == count, "skin streams differ in length", .{});
    core.assert.always((input.normals == null) == (output.normals == null) and (input.tangents == null) == (output.tangents == null), "skin output streams must match the input's", .{});
    if (input.normals) |normals| core.assert.always(normals.len == count and output.normals.?.len == count, "skin normals differ in length", .{});
    if (input.tangents) |tangents| core.assert.always(tangents.len == count and output.tangents.?.len == count, "skin tangents differ in length", .{});

    for (begin..end) |v| {
        // The top three rows of the blended matrix, column by column. The fourth row of an
        // affine matrix is constant, and the weights sum to one.
        var m: [4][3]f32 = @splat(@splat(0));
        for (input.joints[v], input.weights[v]) |joint, weight| {
            if (weight == 0) continue;
            const cols = &matrices[joint].cols;
            for (0..4) |c| {
                for (0..3) |r| m[c][r] += cols[c][r] * weight;
            }
        }

        const p = input.positions[v];
        for (0..3) |r| {
            output.positions[v][r] = m[0][r] * p[0] + m[1][r] * p[1] + m[2][r] * p[2] + m[3][r];
        }
        if (input.normals) |normals| {
            output.normals.?[v] = direction(m, normals[v]);
        }
        if (input.tangents) |tangents| {
            const t = tangents[v];
            const d = direction(m, .{ t[0], t[1], t[2] });
            output.tangents.?[v] = .{ d[0], d[1], d[2], t[3] };
        }
    }
}

/// The upper 3×3 applied to a direction, renormalised. A direction that collapses to zero stays
/// zero rather than becoming NaN.
fn direction(m: [4][3]f32, d: [3]f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (0..3) |r| out[r] = m[0][r] * d[0] + m[1][r] * d[1] + m[2][r] * d[2];
    const len = @sqrt(out[0] * out[0] + out[1] * out[1] + out[2] * out[2]);
    if (len == 0) return .{ 0, 0, 0 };
    const k = 1.0 / len;
    return .{ out[0] * k, out[1] * k, out[2] * k };
}
