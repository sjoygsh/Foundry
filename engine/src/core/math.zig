//! Linear algebra.
//!
//! Deliberately convention-free: this file does not know which way is up. Coordinate
//! system, handedness, the 2D origin and clip-space range are renderer-facing decisions
//! that interact with the differences between Metal, Vulkan and D3D12.
//!
//! **Those decisions are now written down** — `docs/design/rhi.md` §9 states the clip space
//! and `docs/design/render2d.md` §4 the world and screen spaces — and they still do not
//! live here. `core` is L0 and has consumers that are not renderers; a projection matrix
//! baking in one clip space would be a landmine for any of them. The renderer builds its
//! own projection from these primitives and reads the convention from `rhi.clip_space`.
//!
//! Matrices are **column-major in storage**, matching MSL, GLSL and HLSL, so a `Mat4`
//! is sixteen contiguous floats that can go into a uniform buffer untransposed.
//!
//! No fast-math, ever (I9, ADR-0013).
//! Quaternions arrive with 3D; adding them now would be unused code.

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
