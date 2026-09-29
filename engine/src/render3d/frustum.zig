//! View-frustum culling: six planes from `P · V`, and conservative world bounds.
//!
//! Culling is an optimisation, never correctness (`docs/design/meshes.md` §7.6): a draw is
//! culled only when its bounds lie wholly outside one plane, so a culled draw is one that
//! would have produced no pixel. Anything the test cannot decide — a non-finite bound, a
//! degenerate plane — is kept.

const std = @import("std");
const core = @import("core");
const rhi = @import("rhi");
const asset = @import("asset");

const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;

comptime {
    // The near and far rows below are written for this clip space, and reversed-Z on top.
    if (rhi.clip_space.depth_range != .zero_to_one) {
        @compileError("render3d's frustum planes assume a zero-to-one depth range");
    }
}

/// A world-space box as centre and half-extent, which is what a plane test wants.
pub const Bounds = struct {
    center: Vec3,
    extent: Vec3,

    /// A mesh's local box through `world`, by Arvo's method: the centre is transformed, and
    /// the half-extent is `|M₃ₓ₃| · e`. Conservative under rotation, shear and reflection.
    pub fn transformed(local: asset.MeshAabb, world: Mat4) Bounds {
        const center = local.min.add(local.max).scale(0.5);
        const half = local.max.sub(local.min).scale(0.5);
        const e = [3]f32{ half.x, half.y, half.z };
        var out: [3]f32 = undefined;
        for (0..3) |row| {
            var sum: f32 = 0;
            for (0..3) |col| sum += @abs(world.at(row, col)) * e[col];
            out[row] = sum;
        }
        return .{ .center = world.mulPoint(center), .extent = .init(out[0], out[1], out[2]) };
    }
};

pub const Frustum = struct {
    /// `(a, b, c, d)`, inside where `a·x + b·y + c·z + d ≥ 0`, normalised so `(a, b, c)` is a
    /// unit vector. Order: left, right, bottom, top, near, far.
    planes: [6][4]f32,

    /// Gribb and Hartmann's row sums over `rhi.clip_space`'s `[0, 1]` depth. Foundry's
    /// projection is reversed-Z, so the near plane is `z = w` and the far plane is `z = 0`;
    /// the two inequalities are the same either way round, which is why no flag is needed.
    pub fn fromViewProjection(m: Mat4) Frustum {
        var rows: [4][4]f32 = undefined;
        for (0..4) |r| for (0..4) |c| {
            rows[r][c] = m.at(r, c);
        };
        const raw = [6][4]f32{
            add(rows[3], rows[0]),
            sub(rows[3], rows[0]),
            add(rows[3], rows[1]),
            sub(rows[3], rows[1]),
            sub(rows[3], rows[2]),
            rows[2],
        };
        var frustum: Frustum = undefined;
        for (raw, &frustum.planes) |plane, *out| {
            const length = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
            // A plane that cannot be normalised culls nothing: (0, 0, 0, 1) is always inside.
            out.* = if (length > 0 and std.math.isFinite(length) and std.math.isFinite(plane[3]))
                .{ plane[0] / length, plane[1] / length, plane[2] / length, plane[3] / length }
            else
                .{ 0, 0, 0, 1 };
        }
        return frustum;
    }

    /// True only when `bounds` lies wholly outside at least one plane.
    pub fn excludes(self: Frustum, bounds: Bounds) bool {
        if (!bounds.center.isFinite() or !bounds.extent.isFinite()) return false;
        for (self.planes) |p| {
            const distance = p[0] * bounds.center.x + p[1] * bounds.center.y + p[2] * bounds.center.z + p[3];
            const radius = @abs(p[0]) * bounds.extent.x + @abs(p[1]) * bounds.extent.y + @abs(p[2]) * bounds.extent.z;
            if (distance + radius < 0) return true;
        }
        return false;
    }
};

fn add(a: [4]f32, b: [4]f32) [4]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
}

fn sub(a: [4]f32, b: [4]f32) [4]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3] };
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const Camera = @import("camera.zig").Camera;

const unit_box: asset.MeshAabb = .{ .min = .init(-0.5, -0.5, -0.5), .max = .init(0.5, 0.5, 0.5) };

/// Looking down −Z from the origin, 90° vertical field of view, square, near 1, far 10.
fn testFrustum() Frustum {
    const camera: Camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 1, .far = 10 };
    return .fromViewProjection(camera.viewProjection(1, 1));
}

fn boxAt(point: Vec3) Bounds {
    return .transformed(unit_box, Mat4.translation(point));
}

test "each of the six planes culls a box wholly beyond it and keeps one inside" {
    const f = testFrustum();
    try testing.expect(!f.excludes(boxAt(.init(0, 0, -5))));
    // At z = -5 the side planes are at |x| = 5 and |y| = 5, and they lean outward with depth:
    // a unit box at 6 has its far corner on the plane, which is touching, not outside.
    try testing.expect(f.excludes(boxAt(.init(-7, 0, -5))));
    try testing.expect(f.excludes(boxAt(.init(7, 0, -5))));
    try testing.expect(f.excludes(boxAt(.init(0, -7, -5))));
    try testing.expect(f.excludes(boxAt(.init(0, 7, -5))));
    try testing.expect(!f.excludes(boxAt(.init(6, 0, -5))));
    try testing.expect(f.excludes(boxAt(.init(0, 0, -0.25))));
    try testing.expect(f.excludes(boxAt(.init(0, 0, -11))));
}

test "a box straddling any plane is kept" {
    const f = testFrustum();
    try testing.expect(!f.excludes(boxAt(.init(-5, 0, -5))));
    try testing.expect(!f.excludes(boxAt(.init(0, 5.2, -5))));
    try testing.expect(!f.excludes(boxAt(.init(0, 0, -1))));
    try testing.expect(!f.excludes(boxAt(.init(0, 0, -10))));
}

test "reversed-Z's near and far are where the camera says, not swapped" {
    const f = testFrustum();
    // Just inside near and far is kept, just outside is culled: a swapped pair would cull
    // everything between them instead.
    try testing.expect(!f.excludes(boxAt(.init(0, 0, -1.6))));
    try testing.expect(f.excludes(boxAt(.init(0, 0, -0.4))));
    try testing.expect(!f.excludes(boxAt(.init(0, 0, -9.6))));
    try testing.expect(f.excludes(boxAt(.init(0, 0, -10.6))));
    // Normalised, so each is a distance in metres: near is -z - 1 ≥ 0, far is z + 10 ≥ 0.
    const near = f.planes[4];
    const far = f.planes[5];
    try testing.expectApproxEqAbs(@as(f32, -1), near[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), near[3], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), far[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 10), far[3], 1e-3);
}

test "behind the camera is culled even where the side planes would cross" {
    const f = testFrustum();
    try testing.expect(f.excludes(boxAt(.init(0, 0, 5))));
    try testing.expect(f.excludes(boxAt(.init(20, 20, 20))));
}

test "mirrored and sheared world matrices get conservative bounds" {
    const f = testFrustum();
    // A reflection keeps the box's extent positive, so it is culled or kept like its twin.
    var mirrored = Mat4.mul(Mat4.translation(.init(0, 0, -5)), Mat4.scaling(.init(-1, 1, 1)));
    const bounds = Bounds.transformed(unit_box, mirrored);
    try testing.expectEqual(@as(f32, 0.5), bounds.extent.x);
    try testing.expect(!f.excludes(bounds));
    mirrored.cols[3][0] = 7;
    try testing.expect(f.excludes(.transformed(unit_box, mirrored)));

    // A shear x += 2y stretches the box to |x| ≤ 1.5. Centred at x = 6.8 its nearest corner
    // is at 5.3, inside the right plane, which leans out to 5.5 at the box's far face: kept,
    // where the same box unsheared is culled.
    var sheared = Mat4.translation(.init(6.8, 0, -5));
    try testing.expect(f.excludes(.transformed(unit_box, sheared)));
    sheared.cols[1][0] = 2;
    const sheared_bounds = Bounds.transformed(unit_box, sheared);
    try testing.expectEqual(@as(f32, 1.5), sheared_bounds.extent.x);
    try testing.expect(!f.excludes(sheared_bounds));
}

test "bounds or planes the test cannot decide are never culled" {
    const f = testFrustum();
    try testing.expect(!f.excludes(.{ .center = .init(std.math.nan(f32), 0, -5), .extent = .init(1, 1, 1) }));
    try testing.expect(!f.excludes(.{ .center = .init(100, 0, -5), .extent = .init(std.math.inf(f32), 1, 1) }));
    const degenerate = Frustum.fromViewProjection(Mat4.zero);
    try testing.expect(!degenerate.excludes(boxAt(.init(1000, 1000, 1000))));
}
