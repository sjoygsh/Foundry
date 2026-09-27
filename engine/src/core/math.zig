//! Linear algebra.
//!
//! **This file knows which way is up, and nothing else about rendering.** The 3D world
//! axes are a compatibility decision (ADR-0048) that `physics3d` and `render3d` must share,
//! and `core` is their only common ancestor, so they live here: right-handed, +X right,
//! **+Y up, −Z forward**, metres and radians. A rotation is a unit quaternion `(x, y, z, w)`
//! in Hamilton's convention, and `Quat.mul(a, b)` applies `b` first — the same order as
//! `Mat4.mul` — so a chain reads the same in either form. A `Transform` composes `T · R · S`.
//! `docs/design/3d.md` §2 is the full statement; the tests below pin each rule.
//!
//! **The projection still does not live here.** `core` is L0 and has consumers that are not
//! renderers; a projection matrix baking in one clip space would be a landmine for any of
//! them. Each renderer builds its own projection from these primitives and reads the
//! convention from `rhi.clip_space` (`docs/design/rhi.md` §9). The 2D world and screen
//! spaces are `docs/design/render2d.md` §4's, and nothing here overrides them.
//!
//! Vectors are columns: a point transforms as `M · v`. Matrices are **column-major in
//! storage**, matching MSL, GLSL and HLSL, so a `Mat4` is sixteen contiguous floats that can
//! go into a uniform buffer untransposed.
//!
//! No fast-math, ever (I9, ADR-0013).

const std = @import("std");

pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero: Vec2 = .{ .x = 0, .y = 0 };
    pub const one: Vec2 = .{ .x = 1, .y = 1 };

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }
    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(v: Vec2, s: f32) Vec2 {
        return .{ .x = v.x * s, .y = v.y * s };
    }
    pub fn neg(v: Vec2) Vec2 {
        return .{ .x = -v.x, .y = -v.y };
    }
    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn lengthSquared(v: Vec2) f32 {
        return dot(v, v);
    }
    pub fn length(v: Vec2) f32 {
        return @sqrt(lengthSquared(v));
    }
    /// A zero vector normalises to zero rather than to NaN — a deterministic choice,
    /// so callers do not have to guard every call site.
    pub fn normalize(v: Vec2) Vec2 {
        const len = length(v);
        return if (len == 0) zero else scale(v, 1.0 / len);
    }
    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return add(a, scale(sub(b, a), t));
    }
    pub fn eql(a: Vec2, b: Vec2) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{ .x = 0, .y = 0, .z = 0 };
    pub const one: Vec3 = .{ .x = 1, .y = 1, .z = 1 };

    /// The world axes (ADR-0048). Their opposites are written as negations — `up.neg()` —
    /// never as more constants, so there is exactly one spelling of each direction.
    pub const right: Vec3 = .{ .x = 1, .y = 0, .z = 0 };
    pub const up: Vec3 = .{ .x = 0, .y = 1, .z = 0 };
    /// **−Z.** A camera, a light and a character all look down their local −Z.
    pub const forward: Vec3 = .{ .x = 0, .y = 0, .z = -1 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }
    pub fn neg(v: Vec3) Vec3 {
        return .{ .x = -v.x, .y = -v.y, .z = -v.z };
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    pub fn lengthSquared(v: Vec3) f32 {
        return dot(v, v);
    }
    pub fn length(v: Vec3) f32 {
        return @sqrt(lengthSquared(v));
    }
    pub fn normalize(v: Vec3) Vec3 {
        const len = length(v);
        return if (len == 0) zero else scale(v, 1.0 / len);
    }
    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return add(a, scale(sub(b, a), t));
    }
    pub fn eql(a: Vec3, b: Vec3) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
    pub fn isFinite(v: Vec3) bool {
        return std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z);
    }
};

pub const Vec4 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,

    pub const zero: Vec4 = .{ .x = 0, .y = 0, .z = 0, .w = 0 };

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
    pub fn fromPoint(v: Vec3) Vec4 {
        return .{ .x = v.x, .y = v.y, .z = v.z, .w = 1 };
    }
    pub fn fromDirection(v: Vec3) Vec4 {
        return .{ .x = v.x, .y = v.y, .z = v.z, .w = 0 };
    }
    pub fn xyz(v: Vec4) Vec3 {
        return .{ .x = v.x, .y = v.y, .z = v.z };
    }
    pub fn add(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z, .w = a.w + b.w };
    }
    pub fn sub(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z, .w = a.w - b.w };
    }
    pub fn scale(v: Vec4, s: f32) Vec4 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s, .w = v.w * s };
    }
    pub fn dot(a: Vec4, b: Vec4) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }
    pub fn eql(a: Vec4, b: Vec4) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w;
    }
};

/// A rotation: a unit quaternion `(x, y, z, w)`, `w` last as glTF stores it, in Hamilton's
/// convention (`i·j = k`). Positive angles turn counter-clockwise looking down the axis toward
/// the origin — the right-hand rule, as `Mat4.rotationZ` has always had it.
///
/// **A stored rotation is always unit.** Anything that produces one for storage normalises it,
/// and a rotation arriving from outside — content, a save, a mod, the ABI — enters through
/// `validated`, which refuses rather than repairs (I8). Euler angles are display-only and have
/// no conversion here (ADR-0048).
pub const Quat = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Quat = .{ .x = 0, .y = 0, .z = 0, .w = 1 };

    /// How far from unit length a rotation from outside may be and still be accepted.
    ///
    /// **Deliberately loose.** It exists to reject garbage — zero, NaN, `(1, 1, 1, 1)` — not
    /// to judge precision: `(0, 0.707, 0, 0.707)`, typed by hand, is 1.5e-4 short and is
    /// accepted, then normalised. A value that far off is still unambiguously one rotation.
    pub const unit_tolerance: f32 = 1e-3;

    pub const ValidationError = error{InvalidRotation};

    /// The one entry point for a rotation from outside the engine. Refuses a non-finite
    /// component or a length outside `1 ± unit_tolerance`; returns the normalised value.
    pub fn validated(x: f32, y: f32, z: f32, w: f32) ValidationError!Quat {
        const q: Quat = .{ .x = x, .y = y, .z = z, .w = w };
        if (!q.isUnit()) return error.InvalidRotation;
        return q.normalize();
    }

    /// Finite, and unit to within `unit_tolerance`.
    pub fn isUnit(q: Quat) bool {
        if (!(std.math.isFinite(q.x) and std.math.isFinite(q.y) and
            std.math.isFinite(q.z) and std.math.isFinite(q.w))) return false;
        return @abs(q.length() - 1) <= unit_tolerance;
    }

    /// A turn of `radians` about `axis`. The axis is normalised here, so any non-zero
    /// direction will do; a zero axis names no rotation and gives the identity.
    pub fn fromAxisAngle(axis: Vec3, radians: f32) Quat {
        const n = axis.normalize();
        if (n.eql(Vec3.zero)) return identity;
        const half = radians * 0.5;
        const s = @sin(half);
        return .{ .x = n.x * s, .y = n.y * s, .z = n.z * s, .w = @cos(half) };
    }

    /// `mul(a, b)` applies `b` first, then `a` — the same reading as `Mat4.mul`, so
    /// `Mat4.fromQuat(mul(a, b)) == Mat4.mul(fromQuat(a), fromQuat(b))`.
    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        };
    }

    /// `q · v · q⁻¹`, for a unit `q`, without building the matrix.
    pub fn rotate(q: Quat, v: Vec3) Vec3 {
        const u: Vec3 = .{ .x = q.x, .y = q.y, .z = q.z };
        const t = Vec3.cross(u, v).scale(2);
        return v.add(t.scale(q.w)).add(Vec3.cross(u, t));
    }

    /// The inverse of a unit quaternion.
    pub fn conjugate(q: Quat) Quat {
        return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = q.w };
    }

    pub fn neg(q: Quat) Quat {
        return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = -q.w };
    }

    pub fn dot(a: Quat, b: Quat) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }

    pub fn length(q: Quat) f32 {
        return @sqrt(dot(q, q));
    }

    /// A zero quaternion normalises to zero rather than to NaN, as the vectors do. It is not
    /// a rotation, and `isUnit` says so.
    pub fn normalize(q: Quat) Quat {
        const len = q.length();
        if (len == 0) return .{ .x = 0, .y = 0, .z = 0, .w = 0 };
        const k = 1.0 / len;
        return .{ .x = q.x * k, .y = q.y * k, .z = q.z * k, .w = q.w * k };
    }

    /// Spherical interpolation along the **shorter arc**: `q` and `−q` are the same rotation,
    /// so `b` is negated when it lies in the other hemisphere. Close to parallel, where
    /// `sin` of the angle is too small to divide by, it falls back to a normalised linear
    /// blend, which is indistinguishable there.
    pub fn slerp(a: Quat, b_in: Quat, t: f32) Quat {
        var b = b_in;
        var d = dot(a, b);
        if (d < 0) {
            b = b.neg();
            d = -d;
        }
        if (d > 0.9995) {
            return (Quat{
                .x = a.x + (b.x - a.x) * t,
                .y = a.y + (b.y - a.y) * t,
                .z = a.z + (b.z - a.z) * t,
                .w = a.w + (b.w - a.w) * t,
            }).normalize();
        }
        const theta0 = std.math.acos(d);
        const theta = theta0 * t;
        const sin0 = @sin(theta0);
        const sa = @sin(theta0 - theta) / sin0;
        const sb = @sin(theta) / sin0;
        return (Quat{
            .x = a.x * sa + b.x * sb,
            .y = a.y * sa + b.y * sb,
            .z = a.z * sa + b.z * sb,
            .w = a.w * sa + b.w * sb,
        }).normalize();
    }

    /// The rotation that turns −Z (`Vec3.forward`) to `forward_dir` and keeps +Y as close to
    /// `up_hint` as it can: how a camera, light or character is aimed. Null when either input
    /// is zero or not finite, or when they are parallel, since then no roll is defined.
    pub fn lookRotation(forward_dir: Vec3, up_hint: Vec3) ?Quat {
        if (!forward_dir.isFinite() or !up_hint.isFinite()) return null;
        const f = forward_dir.normalize();
        const u = up_hint.normalize();
        if (f.eql(Vec3.zero) or u.eql(Vec3.zero)) return null;
        // Local +Z points back, away from where the thing looks.
        const z = f.neg();
        const x_raw = Vec3.cross(u, z);
        if (x_raw.length() < 1e-6) return null;
        const x = x_raw.normalize();
        const y = Vec3.cross(z, x);
        return fromBasis(x, y, z);
    }

    /// The rotation whose matrix has these orthonormal, right-handed columns.
    fn fromBasis(x: Vec3, y: Vec3, z: Vec3) Quat {
        // `m{row}{col}`: column 0 is `x`, column 1 `y`, column 2 `z`. Shepperd's method,
        // choosing the largest diagonal term so nothing divides by a small number.
        const m00 = x.x;
        const m10 = x.y;
        const m20 = x.z;
        const m01 = y.x;
        const m11 = y.y;
        const m21 = y.z;
        const m02 = z.x;
        const m12 = z.y;
        const m22 = z.z;
        const trace = m00 + m11 + m22;
        var q: Quat = undefined;
        if (trace > 0) {
            const s = @sqrt(trace + 1) * 2;
            q = .{ .w = 0.25 * s, .x = (m21 - m12) / s, .y = (m02 - m20) / s, .z = (m10 - m01) / s };
        } else if (m00 > m11 and m00 > m22) {
            const s = @sqrt(1 + m00 - m11 - m22) * 2;
            q = .{ .w = (m21 - m12) / s, .x = 0.25 * s, .y = (m01 + m10) / s, .z = (m02 + m20) / s };
        } else if (m11 > m22) {
            const s = @sqrt(1 + m11 - m00 - m22) * 2;
            q = .{ .w = (m02 - m20) / s, .x = (m01 + m10) / s, .y = 0.25 * s, .z = (m12 + m21) / s };
        } else {
            const s = @sqrt(1 + m22 - m00 - m11) * 2;
            q = .{ .w = (m10 - m01) / s, .x = (m02 + m20) / s, .y = (m12 + m21) / s, .z = 0.25 * s };
        }
        return q.normalize();
    }

    /// Equal to within `eps` per component, treating `q` and `−q` as the same rotation.
    pub fn approxEql(a: Quat, b: Quat, eps: f32) bool {
        const same = @abs(a.x - b.x) <= eps and @abs(a.y - b.y) <= eps and
            @abs(a.z - b.z) <= eps and @abs(a.w - b.w) <= eps;
        const opposite = @abs(a.x + b.x) <= eps and @abs(a.y + b.y) <= eps and
            @abs(a.z + b.z) <= eps and @abs(a.w + b.w) <= eps;
        return same or opposite;
    }
};

/// A pose relative to a parent, or to the world for an entity with none: **always local**
/// (ADR-0048). The world pose is derived, as an affine `Mat4`, and is never stored as one of
/// these, because a non-uniform scale under a rotated parent shears and a TRS cannot hold
/// shear.
pub const Transform = extern struct {
    translation: Vec3 = Vec3.zero,
    rotation: Quat = Quat.identity,
    scale: Vec3 = Vec3.one,

    pub const identity: Transform = .{};

    /// The relative element tolerance for deciding whether a matrix is exactly representable
    /// as TRS. Shared by model import (M20) and keep-world re-parenting (M21).
    pub const representation_epsilon: f32 = 1e-5;

    /// The relative determinant tolerance reserved for M21's parent-inversion check. It lives
    /// beside the decomposition tolerance so the two implementations cannot invent different
    /// constants for `docs/design/3d.md` §7.1.
    pub const determinant_epsilon: f32 = 1e-6;

    /// `T · R · S`: scale first, then rotate, then translate.
    pub fn toMat4(t: Transform) Mat4 {
        return Mat4.trs(t.translation, t.rotation, t.scale);
    }

    pub const DecomposeError = error{NotRepresentable};

    /// Decomposes an affine matrix into the canonical `T · R · S` representation, or refuses
    /// it. Refusal is the important half of this function: shear and a collapsed axis are not
    /// silently approximated. A reflection is represented by a negative X scale.
    pub fn fromMat4Exact(matrix: Mat4) DecomposeError!Transform {
        var norm: f32 = 0;
        for (matrix.cols) |column| {
            for (column) |value| {
                if (!std.math.isFinite(value)) return error.NotRepresentable;
                norm = @max(norm, @abs(value));
            }
        }
        if (matrix.cols[0][3] != 0 or matrix.cols[1][3] != 0 or
            matrix.cols[2][3] != 0 or matrix.cols[3][3] != 1)
        {
            return error.NotRepresentable;
        }

        const a0 = Vec3.init(matrix.cols[0][0], matrix.cols[0][1], matrix.cols[0][2]);
        const a1 = Vec3.init(matrix.cols[1][0], matrix.cols[1][1], matrix.cols[1][2]);
        const a2 = Vec3.init(matrix.cols[2][0], matrix.cols[2][1], matrix.cols[2][2]);
        const sx_abs = a0.length();
        const sy = a1.length();
        const sz = a2.length();
        if (sx_abs == 0 or sy == 0 or sz == 0 or
            !std.math.isFinite(sx_abs) or !std.math.isFinite(sy) or !std.math.isFinite(sz))
        {
            return error.NotRepresentable;
        }

        const reflected = Vec3.dot(a0, Vec3.cross(a1, a2)) < 0;
        const sx = if (reflected) -sx_abs else sx_abs;
        const x = a0.scale(1.0 / sx);
        const y = a1.scale(1.0 / sy);
        const z = a2.scale(1.0 / sz);
        const rotation = Quat.fromBasis(x, y, z);
        if (!rotation.isUnit()) return error.NotRepresentable;

        const result: Transform = .{
            .translation = .{
                .x = matrix.cols[3][0],
                .y = matrix.cols[3][1],
                .z = matrix.cols[3][2],
            },
            .rotation = rotation,
            .scale = .{ .x = sx, .y = sy, .z = sz },
        };
        const recomposed = result.toMat4();
        const tolerance_scaled = representation_epsilon * @max(@as(f32, 1), norm);
        for (0..4) |column| {
            for (0..4) |row| {
                if (@abs(recomposed.cols[column][row] - matrix.cols[column][row]) > tolerance_scaled) {
                    return error.NotRepresentable;
                }
            }
        }
        return result;
    }

    /// Every component finite and the rotation unit. **Any finite scale is valid**, zero and
    /// negative included: collapsing or mirroring a mesh is a legitimate thing to author.
    /// What a singular parent means for re-parenting is `docs/design/3d.md` §7.1's.
    pub fn isValid(t: Transform) bool {
        return t.translation.isFinite() and t.scale.isFinite() and t.rotation.isUnit();
    }
};

/// Column-major 4x4. `cols[c][r]` is the element in row `r`, column `c`, so the memory
/// order is exactly what a shader uniform expects.
pub const Mat4 = extern struct {
    cols: [4][4]f32,

    pub const identity: Mat4 = .{ .cols = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    pub const zero: Mat4 = .{ .cols = .{
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
    } };

    pub fn at(m: Mat4, row: usize, col: usize) f32 {
        return m.cols[col][row];
    }

    /// `mul(a, b)` applies `b` first, then `a` — the usual reading of `A * B * v`.
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        for (0..4) |c| {
            for (0..4) |r| {
                var sum: f32 = 0;
                for (0..4) |k| sum += a.cols[k][r] * b.cols[c][k];
                out.cols[c][r] = sum;
            }
        }
        return out;
    }

    pub fn mulVec4(m: Mat4, v: Vec4) Vec4 {
        const in = [4]f32{ v.x, v.y, v.z, v.w };
        var out = [4]f32{ 0, 0, 0, 0 };
        for (0..4) |c| {
            for (0..4) |r| out[r] += m.cols[c][r] * in[c];
        }
        return .{ .x = out[0], .y = out[1], .z = out[2], .w = out[3] };
    }

    pub fn transpose(m: Mat4) Mat4 {
        var out: Mat4 = undefined;
        for (0..4) |c| {
            for (0..4) |r| out.cols[r][c] = m.cols[c][r];
        }
        return out;
    }

    pub fn translation(t: Vec3) Mat4 {
        var out = identity;
        out.cols[3][0] = t.x;
        out.cols[3][1] = t.y;
        out.cols[3][2] = t.z;
        return out;
    }

    pub fn scaling(s: Vec3) Mat4 {
        var out = identity;
        out.cols[0][0] = s.x;
        out.cols[1][1] = s.y;
        out.cols[2][2] = s.z;
        return out;
    }

    /// Right-handed rotation about +Z, the standard mathematical convention. This says
    /// nothing about which way is up on screen; that is the renderer's decision.
    pub fn rotationZ(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        var out = identity;
        out.cols[0][0] = c;
        out.cols[0][1] = s;
        out.cols[1][0] = -s;
        out.cols[1][1] = c;
        return out;
    }

    /// Right-handed rotation about +X: +Y turns toward +Z.
    pub fn rotationX(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        var out = identity;
        out.cols[1][1] = c;
        out.cols[1][2] = s;
        out.cols[2][1] = -s;
        out.cols[2][2] = c;
        return out;
    }

    /// Right-handed rotation about +Y: +Z turns toward +X, so forward (−Z) turns toward −X.
    pub fn rotationY(radians: f32) Mat4 {
        const c = @cos(radians);
        const s = @sin(radians);
        var out = identity;
        out.cols[0][0] = c;
        out.cols[0][2] = -s;
        out.cols[2][0] = s;
        out.cols[2][2] = c;
        return out;
    }

    /// The rotation matrix of a unit quaternion.
    pub fn fromQuat(q: Quat) Mat4 {
        const xx = q.x * q.x;
        const yy = q.y * q.y;
        const zz = q.z * q.z;
        const xy = q.x * q.y;
        const xz = q.x * q.z;
        const yz = q.y * q.z;
        const wx = q.w * q.x;
        const wy = q.w * q.y;
        const wz = q.w * q.z;
        return .{ .cols = .{
            .{ 1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0 },
            .{ 2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0 },
            .{ 2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0 },
            .{ 0, 0, 0, 1 },
        } };
    }

    /// `T · R · S` in one step: the rotation's columns scaled, and the translation last.
    pub fn trs(t: Vec3, r: Quat, s: Vec3) Mat4 {
        var out = fromQuat(r);
        const k = [3]f32{ s.x, s.y, s.z };
        for (0..3) |c| {
            for (0..3) |row| out.cols[c][row] *= k[c];
        }
        out.cols[3] = .{ t.x, t.y, t.z, 1 };
        return out;
    }

    /// `M · (p, 1)`, without a perspective divide: for affine matrices.
    pub fn mulPoint(m: Mat4, p: Vec3) Vec3 {
        return m.mulVec4(Vec4.fromPoint(p)).xyz();
    }

    /// `M · (d, 0)`: a direction, which translation does not move.
    pub fn mulDirection(m: Mat4, d: Vec3) Vec3 {
        return m.mulVec4(Vec4.fromDirection(d)).xyz();
    }

    pub fn determinant(m: Mat4) f32 {
        const a: *const [16]f32 = @ptrCast(&m);
        const inv = cofactors(a);
        return a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12];
    }

    /// The general inverse, by cofactors. **Null only when the determinant is exactly zero,
    /// or the result is not finite.** How close to singular is too close is the caller's
    /// decision, relative to its own scale: a fixed epsilon here would be wrong in
    /// millimetres and in kilometres alike (`docs/design/3d.md` §7.1 states one).
    pub fn inverse(m: Mat4) ?Mat4 {
        const a: *const [16]f32 = @ptrCast(&m);
        const inv = cofactors(a);
        const det = a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12];
        if (det == 0 or !std.math.isFinite(det)) return null;
        const k = 1.0 / det;
        var out: Mat4 = undefined;
        const o: *[16]f32 = @ptrCast(&out);
        for (0..16) |i| {
            o[i] = inv[i] * k;
            if (!std.math.isFinite(o[i])) return null;
        }
        return out;
    }

    /// The adjugate's entries, in the same flat order as `m`. The expansion is symmetric
    /// under transposition, so it is correct for column-major storage as written.
    fn cofactors(m: *const [16]f32) [16]f32 {
        var inv: [16]f32 = undefined;
        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
        return inv;
    }

    /// A **view** matrix: the inverse of the rigid pose standing at `eye` and looking at
    /// `target`, with +Y as close to `up` as it can be. Computed exactly, as the transposed
    /// rotation and the rotated, negated position, rather than by a general inverse. Null
    /// where `Quat.lookRotation` is: `eye == target`, or looking along `up`.
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) ?Mat4 {
        if (!eye.isFinite() or !target.isFinite()) return null;
        const q = Quat.lookRotation(target.sub(eye), up) orelse return null;
        var out = fromQuat(q.conjugate());
        const t = out.mulDirection(eye.neg());
        out.cols[3] = .{ t.x, t.y, t.z, 1 };
        return out;
    }

    pub fn approxEql(a: Mat4, b: Mat4, eps: f32) bool {
        for (0..4) |c| {
            for (0..4) |r| if (!(@abs(a.cols[c][r] - b.cols[c][r]) <= eps)) return false;
        }
        return true;
    }
};

/// An axis-aligned rectangle. Carries no opinion about which way `y` grows.
pub const Rect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn init(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }
    pub fn contains(r: Rect, p: Vec2) bool {
        return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h;
    }
    pub fn overlaps(a: Rect, b: Rect) bool {
        if (a.isEmpty() or b.isEmpty()) return false;
        return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
    }
    /// The rectangle covered by both. Disjoint inputs give an empty rectangle placed at the
    /// overlap's corner rather than at the origin, so a caller that goes on to nest another
    /// intersection inside it stays where it was rather than jumping to (0, 0).
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const right = @min(a.x + a.w, b.x + b.w);
        const bottom = @min(a.y + a.h, b.y + b.h);
        return .init(x, y, @max(0, right - x), @max(0, bottom - y));
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const tolerance = 1e-5;

fn expectVec3(expected: Vec3, actual: Vec3) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try testing.expectApproxEqAbs(expected.z, actual.z, tolerance);
}

test "vector arithmetic" {
    const a = Vec2.init(3, 4);
    try testing.expectApproxEqAbs(@as(f32, 5), a.length(), tolerance);
    try testing.expectApproxEqAbs(@as(f32, 1), a.normalize().length(), tolerance);
    try testing.expect(Vec2.lerp(Vec2.zero, Vec2.init(10, 20), 0.5).eql(Vec2.init(5, 10)));
}

test "normalizing zero yields zero, not NaN" {
    try testing.expect(Vec2.zero.normalize().eql(Vec2.zero));
    try testing.expect(Vec3.zero.normalize().eql(Vec3.zero));
}

test "cross product is right-handed" {
    const x = Vec3.init(1, 0, 0);
    const y = Vec3.init(0, 1, 0);
    try expectVec3(Vec3.init(0, 0, 1), Vec3.cross(x, y));
}

test "identity is a multiplicative identity" {
    const m = Mat4.mul(Mat4.translation(Vec3.init(1, 2, 3)), Mat4.scaling(Vec3.init(2, 2, 2)));
    const left = Mat4.mul(Mat4.identity, m);
    const right = Mat4.mul(m, Mat4.identity);
    for (0..4) |c| {
        for (0..4) |r| {
            try testing.expectApproxEqAbs(m.cols[c][r], left.cols[c][r], tolerance);
            try testing.expectApproxEqAbs(m.cols[c][r], right.cols[c][r], tolerance);
        }
    }
}

test "mul applies the right-hand matrix first" {
    // Scale then translate: the translation must not be scaled.
    const m = Mat4.mul(Mat4.translation(Vec3.init(10, 0, 0)), Mat4.scaling(Vec3.init(2, 2, 2)));
    const p = m.mulVec4(Vec4.fromPoint(Vec3.init(1, 0, 0)));
    try expectVec3(Vec3.init(12, 0, 0), p.xyz());
}

test "translation moves points but not directions" {
    const m = Mat4.translation(Vec3.init(5, 6, 7));
    try expectVec3(Vec3.init(5, 6, 7), m.mulVec4(Vec4.fromPoint(Vec3.zero)).xyz());
    try expectVec3(Vec3.init(1, 0, 0), m.mulVec4(Vec4.fromDirection(Vec3.init(1, 0, 0))).xyz());
}

test "rotationZ by 90 degrees maps +x to +y" {
    const m = Mat4.rotationZ(std.math.pi / 2.0);
    try expectVec3(Vec3.init(0, 1, 0), m.mulVec4(Vec4.fromPoint(Vec3.init(1, 0, 0))).xyz());
}

test "matrix storage is column-major and contiguous" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(Mat4));
    const m = Mat4.translation(Vec3.init(1, 2, 3));
    // Column-major: the translation occupies the last four floats.
    const flat: *const [16]f32 = @ptrCast(&m);
    try testing.expectEqual(@as(f32, 1), flat[12]);
    try testing.expectEqual(@as(f32, 2), flat[13]);
    try testing.expectEqual(@as(f32, 3), flat[14]);
    try testing.expectEqual(@as(f32, 1), flat[15]);
    try testing.expectEqual(m.at(0, 3), flat[12]);
}

test "transpose is an involution" {
    const m = Mat4.mul(Mat4.rotationZ(0.7), Mat4.translation(Vec3.init(1, 2, 3)));
    const back = m.transpose().transpose();
    for (0..4) |c| {
        for (0..4) |r| try testing.expectApproxEqAbs(m.cols[c][r], back.cols[c][r], tolerance);
    }
}

test "rect containment and overlap" {
    const r = Rect.init(0, 0, 10, 10);
    try testing.expect(r.contains(Vec2.init(0, 0)));
    try testing.expect(r.contains(Vec2.init(9.9, 9.9)));
    try testing.expect(!r.contains(Vec2.init(10, 5))); // half-open
    try testing.expect(r.overlaps(Rect.init(5, 5, 10, 10)));
    try testing.expect(!r.overlaps(Rect.init(10, 0, 5, 5))); // touching is not overlapping
    try testing.expect(!r.overlaps(Rect.init(0, 0, 0, 10))); // empty overlaps nothing
}

test "rect intersection" {
    const r = Rect.init(0, 0, 10, 10);
    try testing.expectEqual(Rect.init(5, 5, 5, 5), r.intersect(Rect.init(5, 5, 10, 10)));
    // Fully contained gives the inner rectangle back unchanged.
    try testing.expectEqual(Rect.init(2, 2, 3, 3), r.intersect(Rect.init(2, 2, 3, 3)));
    // Disjoint is empty, and sits at the corner it was asked about rather than the origin.
    const away = r.intersect(Rect.init(20, 20, 5, 5));
    try testing.expect(away.isEmpty());
    try testing.expectEqual(@as(f32, 20), away.x);
    // Intersection is commutative.
    try testing.expectEqual(
        r.intersect(Rect.init(-5, 3, 8, 2)),
        Rect.init(-5, 3, 8, 2).intersect(r),
    );
}

// -- 3D conventions (ADR-0048; `docs/design/render3d.md` §3) -----------------------------
//
// One test per rule `docs/design/3d.md` §2 locks. A failure here is a convention change,
// which every mesh, animation, save and mod would see: fix the code, not the test.

/// Rotations reached by different axes and angles, some beyond a half-turn, used wherever a
/// rule must hold for rotations in general rather than for one.
const sample_rotations = [_]Quat{
    Quat.identity,
    Quat.fromAxisAngle(Vec3.up, 0.3),
    Quat.fromAxisAngle(Vec3.right, -1.2),
    Quat.fromAxisAngle(Vec3.init(1, 2, 3), 2.5),
    Quat.fromAxisAngle(Vec3.init(-0.4, 0.1, 0.9), 4.0),
    Quat.fromAxisAngle(Vec3.forward, std.math.pi),
};

fn expectVec3Near(expected: Vec3, actual: Vec3, eps: f32) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, eps);
    try testing.expectApproxEqAbs(expected.y, actual.y, eps);
    try testing.expectApproxEqAbs(expected.z, actual.z, eps);
}

/// The angle a unit quaternion turns through, in `[0, π]`.
fn angleOf(q: Quat) f32 {
    return 2 * std.math.acos(@min(1.0, @abs(q.w)));
}

test "convention: right-handed, with +Y up and -Z forward" {
    // Exactly, not approximately: these are the definitions.
    try testing.expect(Vec3.cross(Vec3.right, Vec3.up).eql(Vec3.forward.neg()));
    try testing.expect(Vec3.cross(Vec3.up, Vec3.forward.neg()).eql(Vec3.right));
    try testing.expectEqual(@as(f32, -1), Vec3.forward.z);
    try testing.expectEqual(@as(f32, 1), Vec3.up.y);
}

test "convention: forward is -Z, and lookRotation aims it" {
    // Looking forward with +Y up is no rotation at all.
    try testing.expect(Quat.approxEql(Quat.identity, Quat.lookRotation(Vec3.forward, Vec3.up).?, 1e-6));

    const directions = [_]Vec3{
        Vec3.right,              Vec3.right.neg(),
        Vec3.forward.neg(),      Vec3.init(1, 1, 1),
        Vec3.init(-1, 0.5, 2),   Vec3.init(0.3, -1, -0.2),
        Vec3.init(2, -0.1, 0.7), Vec3.init(-0.2, 0.9, -0.4),
    };
    for (directions) |d| {
        const q = Quat.lookRotation(d, Vec3.up).?;
        try testing.expect(q.isUnit());
        try expectVec3Near(d.normalize(), q.rotate(Vec3.forward), 1e-5);
        // Up stays in the plane of up and the view direction: no roll.
        const local_up = q.rotate(Vec3.up);
        try testing.expect(Vec3.dot(local_up, Vec3.cross(Vec3.up, d.normalize())) < 1e-5);
        try testing.expect(local_up.y >= 0);
    }
}

test "convention: lookRotation refuses what defines no rotation" {
    try testing.expect(Quat.lookRotation(Vec3.zero, Vec3.up) == null);
    try testing.expect(Quat.lookRotation(Vec3.forward, Vec3.zero) == null);
    try testing.expect(Quat.lookRotation(Vec3.up, Vec3.up) == null);
    try testing.expect(Quat.lookRotation(Vec3.up.neg(), Vec3.up) == null);
    try testing.expect(Quat.lookRotation(Vec3.init(std.math.nan(f32), 0, -1), Vec3.up) == null);
}

test "convention: positive angles follow the right-hand rule" {
    // A quarter turn about +Y takes forward (-Z) to -X, in both forms.
    const q = Quat.fromAxisAngle(Vec3.up, std.math.pi / 2.0);
    try expectVec3Near(Vec3.right.neg(), q.rotate(Vec3.forward), 1e-6);
    try expectVec3Near(Vec3.right.neg(), Mat4.rotationY(std.math.pi / 2.0).mulPoint(Vec3.forward), 1e-6);
    // About +X, +Y turns toward +Z; about +Z, +X turns toward +Y.
    try expectVec3Near(Vec3.forward.neg(), Mat4.rotationX(std.math.pi / 2.0).mulPoint(Vec3.up), 1e-6);
    try expectVec3Near(Vec3.up, Mat4.rotationZ(std.math.pi / 2.0).mulPoint(Vec3.right), 1e-6);
    // The quaternion and the axis matrices agree.
    const angle: f32 = 0.8;
    try testing.expect(Mat4.approxEql(Mat4.rotationX(angle), Mat4.fromQuat(Quat.fromAxisAngle(Vec3.right, angle)), 1e-6));
    try testing.expect(Mat4.approxEql(Mat4.rotationY(angle), Mat4.fromQuat(Quat.fromAxisAngle(Vec3.up, angle)), 1e-6));
    try testing.expect(Mat4.approxEql(Mat4.rotationZ(angle), Mat4.fromQuat(Quat.fromAxisAngle(Vec3.forward.neg(), angle)), 1e-6));
}

test "convention: column vectors in column-major storage" {
    const m = Mat4.translation(Vec3.init(4, 5, 6));
    // The translation is the fourth column, which is the last four floats.
    try testing.expectEqual([4]f32{ 4, 5, 6, 1 }, m.cols[3]);
    try expectVec3Near(Vec3.init(5, 5, 6), m.mulPoint(Vec3.right), 0);
    try expectVec3Near(Vec3.right, m.mulDirection(Vec3.right), 0);
}

test "convention: quaternions compose in the same order as matrices" {
    const v = Vec3.init(0.3, -1.7, 2.2);
    for (sample_rotations) |a| {
        for (sample_rotations) |b| {
            const ab = Quat.mul(a, b);
            // `mul(a, b)` applies `b` first, in both forms.
            try testing.expect(Mat4.approxEql(Mat4.fromQuat(ab), Mat4.mul(Mat4.fromQuat(a), Mat4.fromQuat(b)), 1e-5));
            try expectVec3Near(a.rotate(b.rotate(v)), ab.rotate(v), 1e-5);
            // And rotating is the matrix's product.
            try expectVec3Near(Mat4.fromQuat(ab).mulPoint(v), ab.rotate(v), 1e-5);
        }
    }
}

test "convention: a transform composes T * R * S" {
    // Scale 2, then a quarter turn about +Y, then (0, 0, 5): (1,0,0) -> (2,0,0) -> (0,0,-2)
    // -> (0,0,3). Any other order lands elsewhere.
    const t: Transform = .{
        .translation = Vec3.init(0, 0, 5),
        .rotation = Quat.fromAxisAngle(Vec3.up, std.math.pi / 2.0),
        .scale = Vec3.init(2, 2, 2),
    };
    try expectVec3Near(Vec3.init(0, 0, 3), t.toMat4().mulPoint(Vec3.right), 1e-5);

    const T = Mat4.translation(t.translation);
    const R = Mat4.fromQuat(t.rotation);
    const S = Mat4.scaling(t.scale);
    try testing.expect(Mat4.approxEql(Mat4.mul(T, Mat4.mul(R, S)), t.toMat4(), 1e-6));
    const other_orders = [_]Mat4{
        Mat4.mul(R, Mat4.mul(T, S)),
        Mat4.mul(S, Mat4.mul(R, T)),
        Mat4.mul(T, Mat4.mul(S, R)),
    };
    for (other_orders) |m| {
        try testing.expect(!Vec3.eql(m.mulPoint(Vec3.right), Vec3.init(0, 0, 3)));
    }
}

test "convention: interpolation takes the shorter arc" {
    const a = Quat.identity;
    // A turn of 5 radians is the same rotation as -(2π - 5) ≈ -1.28: halfway is 0.64, not 2.5.
    const b = Quat.fromAxisAngle(Vec3.up, 5.0);
    const mid = Quat.slerp(a, b, 0.5);
    try testing.expectApproxEqAbs((2 * std.math.pi - 5.0) / 2.0, angleOf(mid), 1e-5);
    // q and -q interpolate identically.
    for (sample_rotations) |q| {
        for ([_]f32{ 0, 0.25, 0.5, 0.9, 1 }) |t| {
            try testing.expect(Quat.approxEql(Quat.slerp(a, q, t), Quat.slerp(a, q.neg(), t), 1e-5));
        }
        try testing.expect(Quat.approxEql(q, Quat.slerp(a, q, 1), 1e-5));
        try testing.expect(Quat.approxEql(a, Quat.slerp(a, q, 0), 1e-6));
    }
    // Near-parallel inputs take the linear path and stay unit.
    const close = Quat.fromAxisAngle(Vec3.up, 1e-4);
    try testing.expect(Quat.slerp(a, close, 0.5).isUnit());
}

test "convention: rotations from outside are refused, never repaired" {
    const Err = Quat.ValidationError;
    try testing.expectError(Err.InvalidRotation, Quat.validated(0, 0, 0, 0));
    try testing.expectError(Err.InvalidRotation, Quat.validated(1, 1, 1, 1));
    try testing.expectError(Err.InvalidRotation, Quat.validated(std.math.nan(f32), 0, 0, 1));
    try testing.expectError(Err.InvalidRotation, Quat.validated(0, std.math.inf(f32), 0, 0));
    try testing.expectError(Err.InvalidRotation, Quat.validated(0, 0, 0, 1.01));
    try testing.expectError(Err.InvalidRotation, Quat.validated(0, 0, 0, 0.99));

    // Within the tolerance: accepted, and stored unit.
    for ([_]Quat{
        .{ .x = 0, .y = 0, .z = 0, .w = 1.0009 },
        .{ .x = 0, .y = 0, .z = 0, .w = 0.9991 },
        .{ .x = 0, .y = 0.707, .z = 0, .w = 0.707 },
    }) |q| {
        const v = try Quat.validated(q.x, q.y, q.z, q.w);
        try testing.expectApproxEqAbs(@as(f32, 1), v.length(), 1e-6);
    }
}

test "convention: a transform is valid with any finite scale" {
    try testing.expect(Transform.identity.isValid());
    try testing.expect((Transform{ .scale = Vec3.zero }).isValid());
    try testing.expect((Transform{ .scale = Vec3.init(-1, 2, 1) }).isValid());
    try testing.expect(!(Transform{ .translation = Vec3.init(std.math.nan(f32), 0, 0) }).isValid());
    try testing.expect(!(Transform{ .scale = Vec3.init(1, std.math.inf(f32), 1) }).isValid());
    try testing.expect(!(Transform{ .rotation = .{ .x = 0, .y = 0, .z = 0, .w = 2 } }).isValid());
}

test "exact matrix decomposition round trips TRS and canonicalizes reflections" {
    const source: Transform = .{
        .translation = Vec3.init(3, -2, 7),
        .rotation = Quat.fromAxisAngle(Vec3.init(1, 2, 3), 1.1),
        .scale = Vec3.init(2, -3, 0.5),
    };
    const decomposed = try Transform.fromMat4Exact(source.toMat4());
    try testing.expect(decomposed.scale.x < 0);
    try testing.expect(decomposed.rotation.isUnit());
    try testing.expect(Mat4.approxEql(source.toMat4(), decomposed.toMat4(), Transform.representation_epsilon));
}

test "exact matrix decomposition refuses shear, a singular axis, perspective, and non-finite values" {
    var shear = Mat4.identity;
    shear.cols[1][0] = 0.25;
    try testing.expectError(error.NotRepresentable, Transform.fromMat4Exact(shear));

    const singular = Mat4.trs(Vec3.zero, Quat.identity, Vec3.init(1, 0, 1));
    try testing.expectError(error.NotRepresentable, Transform.fromMat4Exact(singular));

    var perspective = Mat4.identity;
    perspective.cols[0][3] = 0.01;
    try testing.expectError(error.NotRepresentable, Transform.fromMat4Exact(perspective));

    var non_finite = Mat4.identity;
    non_finite.cols[2][2] = std.math.nan(f32);
    try testing.expectError(error.NotRepresentable, Transform.fromMat4Exact(non_finite));
}

test "inverse undoes any TRS, reflections included, and a singular matrix has none" {
    const translations = [_]Vec3{ Vec3.zero, Vec3.init(3, -2, 7), Vec3.init(-100, 0.5, 40) };
    const scales = [_]Vec3{ Vec3.one, Vec3.init(2, 0.5, 3), Vec3.init(-1, 1, 1), Vec3.init(0.1, -4, 2) };
    for (sample_rotations) |r| {
        for (translations) |t| {
            for (scales) |s| {
                const m = Mat4.trs(t, r, s);
                const inv = Mat4.inverse(m).?;
                try testing.expect(Mat4.approxEql(Mat4.identity, Mat4.mul(m, inv), 1e-4));
                try testing.expect(Mat4.approxEql(Mat4.identity, Mat4.mul(inv, m), 1e-4));
                // The determinant is the product of the scales, whatever the rotation.
                try testing.expectApproxEqRel(s.x * s.y * s.z, m.determinant(), 1e-4);
            }
        }
    }
    try testing.expect(Mat4.inverse(Mat4.trs(Vec3.init(1, 2, 3), sample_rotations[3], Vec3.init(1, 0, 1))) == null);
    try testing.expect(Mat4.inverse(Mat4.zero) == null);
}

test "lookAt is the inverse of the pose it looks from" {
    const cases = [_][2]Vec3{
        .{ Vec3.init(0, 2, 5), Vec3.zero },
        .{ Vec3.init(-3, 1, -4), Vec3.init(2, 0, 1) },
        .{ Vec3.init(10, -2, 0.5), Vec3.init(10, 3, -8) },
    };
    for (cases) |c| {
        const eye = c[0];
        const target = c[1];
        const view = Mat4.lookAt(eye, target, Vec3.up).?;
        // The eye is the view's origin, and the target lies straight ahead, on -Z.
        try expectVec3Near(Vec3.zero, view.mulPoint(eye), 1e-5);
        try expectVec3Near(Vec3.init(0, 0, -target.sub(eye).length()), view.mulPoint(target), 1e-4);
        const pose = Mat4.trs(eye, Quat.lookRotation(target.sub(eye), Vec3.up).?, Vec3.one);
        try testing.expect(Mat4.approxEql(Mat4.inverse(pose).?, view, 1e-4));
    }
    try testing.expect(Mat4.lookAt(Vec3.one, Vec3.one, Vec3.up) == null);
    try testing.expect(Mat4.lookAt(Vec3.zero, Vec3.up, Vec3.up) == null);
}

test "rotate matches the rotation matrix and keeps length" {
    const v = Vec3.init(-2, 0.5, 3);
    for (sample_rotations) |q| {
        try testing.expect(q.isUnit());
        try expectVec3Near(Mat4.fromQuat(q).mulPoint(v), q.rotate(v), 1e-5);
        try testing.expectApproxEqAbs(v.length(), q.rotate(v).length(), 1e-5);
        // The conjugate undoes it.
        try expectVec3Near(v, q.conjugate().rotate(q.rotate(v)), 1e-5);
    }
    // A zero axis names no rotation.
    try testing.expect(Quat.approxEql(Quat.identity, Quat.fromAxisAngle(Vec3.zero, 1), 0));
}

test "the 3D types keep their storage layouts" {
    // Quat and Transform will cross into GPU buffers and the ABI; their layout is a contract.
    try testing.expectEqual(@as(usize, 16), @sizeOf(Quat));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Quat, "w"));
    try testing.expectEqual(@as(usize, 40), @sizeOf(Transform));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Transform, "rotation"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(Transform, "scale"));
}
