//! A skeleton: joints in parents-first order, their rest pose and their inverse bind matrices.
//!
//! A joint is its index within its skeleton. Names belong to the asset (`animation3d.md` §6)
//! and never reach this module.

const std = @import("std");
const core = @import("core");

const Mat4 = core.math.Mat4;
const Transform = core.math.Transform;

/// The most joints one skeleton may have. A joint index fits a byte, which is what a vertex
/// stores (`animation3d.md` §6).
pub const max_joints: usize = 256;

/// The parent of a root joint.
pub const no_parent: u16 = 0xFFFF;

/// Borrowed, never owned: the three slices belong to the caller and must outlive every use.
/// They have one entry per joint, and that shared length is the joint count.
pub const Skeleton = struct {
    /// Each joint's parent, or `no_parent`. **Every parent precedes its children**, so one
    /// pass in index order composes the hierarchy. More than one root is allowed here; the
    /// importer is what insists on a single tree.
    parents: []const u16,
    /// The local rest pose: what a joint holds on any path a clip does not animate.
    rest: []const Transform,
    /// Model space to each joint's bind space.
    inverse_bind: []const Mat4,
    /// The constant transform from the skeleton's root space to model space.
    root: Mat4 = Mat4.identity,

    pub const ValidateError = error{
        NoJoints,
        TooManyJoints,
        LengthMismatch,
        ParentOutOfOrder,
        InvalidRest,
        InvalidInverseBind,
        InvalidRoot,
    };

    pub fn jointCount(s: Skeleton) usize {
        return s.parents.len;
    }

    /// Refuses every way an untrusted skeleton can be wrong. A skeleton that passes is safe to
    /// sample, compose and skin with.
    pub fn validate(s: Skeleton) ValidateError!void {
        const count = s.parents.len;
        if (count == 0) return error.NoJoints;
        if (count > max_joints) return error.TooManyJoints;
        if (s.rest.len != count or s.inverse_bind.len != count) return error.LengthMismatch;
        if (!isAffine(s.root)) return error.InvalidRoot;
        for (s.parents, s.rest, s.inverse_bind, 0..) |parent, rest, inverse_bind, joint| {
            // A parent at or after its child would be read before it was composed, and a
            // cycle is the same mistake twice.
            if (parent != no_parent and parent >= joint) return error.ParentOutOfOrder;
            if (!rest.isValid()) return error.InvalidRest;
            if (!isAffine(inverse_bind)) return error.InvalidInverseBind;
        }
    }
};

/// Finite, with a last row of exactly `(0, 0, 0, 1)`. Skinning relies on it: a skin matrix is
/// applied to a point without a perspective divide.
pub fn isAffine(m: Mat4) bool {
    for (m.cols) |column| {
        for (column) |value| if (!std.math.isFinite(value)) return false;
    }
    return m.cols[0][3] == 0 and m.cols[1][3] == 0 and m.cols[2][3] == 0 and m.cols[3][3] == 1;
}
