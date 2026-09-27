//! The rigid 3D camera and Foundry's reversed-Z projection.
//!
//! Design: `docs/design/render3d.md` §6.3 and ADR-0048.

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");

const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;

comptime {
    if (rhi.clip_space.y_axis != .up or rhi.clip_space.depth_range != .zero_to_one) {
        @compileError("render3d requires the RHI's +Y-up, zero-to-one clip space");
    }
}

pub const Camera = struct {
    position: Vec3 = .zero,
    rotation: Quat = .identity,
    vertical_fov: f32 = std.math.pi / 3.0,
    near: f32 = 0.1,
    far: f32 = 1000.0,

    pub fn isValid(self: Camera) bool {
        return self.position.isFinite() and self.rotation.isUnit() and
            std.math.isFinite(self.vertical_fov) and self.vertical_fov > 0 and
            self.vertical_fov < std.math.pi and std.math.isFinite(self.near) and
            std.math.isFinite(self.far) and self.near > 0 and self.near < self.far;
    }

    /// A rigid inverse, deliberately not the general matrix inverse: R^-1 * T^-1.
    pub fn viewMatrix(self: Camera) Mat4 {
        return Mat4.mul(
            Mat4.fromQuat(self.rotation.conjugate()),
            Mat4.translation(self.position.neg()),
        );
    }

    pub fn projectionMatrix(self: Camera, aspect: f32) Mat4 {
        const f = 1.0 / @tan(self.vertical_fov * 0.5);
        const range = self.far - self.near;
        return .{ .cols = .{
            .{ f / aspect, 0, 0, 0 },
            .{ 0, f, 0, 0 },
            .{ 0, 0, self.near / range, -1 },
            .{ 0, 0, self.near * self.far / range, 0 },
        } };
    }

    pub fn viewProjection(self: Camera, width: u32, height: u32) Mat4 {
        const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        return Mat4.mul(self.projectionMatrix(aspect), self.viewMatrix());
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

fn projected(camera: Camera, point: Vec3) core.math.Vec4 {
    return camera.projectionMatrix(1).mulVec4(.fromPoint(point));
}

fn depth(camera: Camera, z: f32) f32 {
    const clip = projected(camera, .init(0, 0, z));
    return clip.z / clip.w;
}

test "reversed-Z maps near to one and far to zero" {
    const camera: Camera = .{ .near = 0.1, .far = 1000 };
    try testing.expectApproxEqAbs(@as(f32, 1), depth(camera, -camera.near), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), depth(camera, -camera.far), 1e-7);
}

test "reversed-Z depth decreases strictly with distance" {
    const camera: Camera = .{ .near = 0.1, .far = 1000 };
    var previous = depth(camera, -camera.near);
    for (1..21) |i| {
        const t = @as(f32, @floatFromInt(i)) / 20.0;
        const distance = camera.near + (camera.far - camera.near) * t;
        const current = depth(camera, -distance);
        try testing.expect(current < previous);
        previous = current;
    }
}

test "reversed-Z spends precision near the camera" {
    const camera: Camera = .{ .near = 0.1, .far = 1000 };
    const midpoint = (camera.near + camera.far) * 0.5;
    try testing.expect(depth(camera, -midpoint) < 0.001);
}

test "projection preserves positive X and Y" {
    const camera: Camera = .{ .vertical_fov = std.math.pi / 2.0 };
    const x = projected(camera, .init(1, 0, -2));
    const y = projected(camera, .init(0, 1, -2));
    try testing.expect(x.x / x.w > 0);
    try testing.expect(y.y / y.w > 0);
}

test "a point behind the camera has negative clip W" {
    const clip = projected(.{}, .init(0, 0, 1));
    try testing.expect(clip.w < 0);
}

test "the rigid view is rotation inverse times translation inverse" {
    const camera: Camera = .{
        .position = .init(4, -2, 7),
        .rotation = .fromAxisAngle(Vec3.up, 0.7),
    };
    try testing.expect(Mat4.approxEql(
        camera.viewMatrix(),
        Mat4.mul(Mat4.fromQuat(camera.rotation.conjugate()), Mat4.translation(camera.position.neg())),
        0,
    ));
    try testing.expect(camera.viewMatrix().mulPoint(camera.position).length() < 1e-5);
}

test "camera validation refuses every malformed field" {
    try testing.expect((Camera{}).isValid());
    try testing.expect(!(Camera{ .position = .init(std.math.nan(f32), 0, 0) }).isValid());
    try testing.expect(!(Camera{ .rotation = .{ .x = 1, .w = 1 } }).isValid());
    try testing.expect(!(Camera{ .vertical_fov = 0 }).isValid());
    try testing.expect(!(Camera{ .vertical_fov = std.math.pi }).isValid());
    try testing.expect(!(Camera{ .near = 0 }).isValid());
    try testing.expect(!(Camera{ .near = 2, .far = 1 }).isValid());
    try testing.expect(!(Camera{ .far = std.math.inf(f32) }).isValid());
}
