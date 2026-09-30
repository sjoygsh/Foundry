//! Shapes, poses and bounds — and the one form the narrowphase sees: a convex core plus a radius.
//!
//! **Every shape is a core and a radius** (`collision3d.md` §4). A sphere is a point and its
//! radius, a capsule a segment and its radius, a box and a hull their own solids with radius
//! zero. The narrowphase measures the cores and subtracts the radii afterwards, which is why
//! one algorithm serves every pair and why the character's capsule, which is almost always
//! *separated* at its core from what it touches, stays in the well-conditioned regime.
//!
//! **Poses are rigid.** A position and a unit rotation, no scale: a scaled box is a box with
//! other half-extents, and a triangle mesh has its scale baked by the importer (ADR-0057).

const std = @import("std");
const core = @import("core");

const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;

/// Phantom tag for `HullHandle`. Never instantiated (I1).
pub const Hulls = opaque {};

/// A convex hull the world owns. A body names one by handle, never by slice, because a slice
/// kept in a body would be a raw pointer held long-term (I1).
pub const HullHandle = core.Handle(Hulls);

/// The farthest a position may be from the origin on any axis. **Numerical, not gameplay**: at
/// 8,192 m an `f32` still resolves about a millimetre, so the 5 mm contact skin means something.
pub const max_coordinate: f32 = 8192;

pub const min_hull_points: usize = 4;
pub const max_hull_points: usize = 256;
/// A hull's points must span at least this volume, m³, by the deterministic scan `hullVolume`
/// performs. Coplanar or collinear sets have no inside to collide with.
pub const min_hull_volume: f32 = 1e-9;

pub const Shape = union(enum) {
    sphere: struct { radius: f32 },
    /// A segment of length `2·half_height` along local ±Y, swept by `radius`. `half_height` 0 is
    /// a sphere, and permitted.
    capsule: struct { radius: f32, half_height: f32 },
    box: struct { half_extents: Vec3 },
    hull: HullHandle,

    /// Whether the dimensions describe a solid. A hull's handle is the world's to check.
    pub fn dimensionsValid(self: Shape) bool {
        return switch (self) {
            .sphere => |s| positive(s.radius),
            .capsule => |c| positive(c.radius) and std.math.isFinite(c.half_height) and c.half_height >= 0,
            .box => |b| positive(b.half_extents.x) and positive(b.half_extents.y) and positive(b.half_extents.z),
            .hull => |h| !h.isNone(),
        };
    }

    fn positive(v: f32) bool {
        return std.math.isFinite(v) and v > 0;
    }
};

/// Where a shape stands: its centre (a hull's local origin) and a unit rotation.
pub const Pose = struct {
    position: Vec3 = .zero,
    rotation: Quat = .identity,

    pub const identity: Pose = .{};

    pub fn at(position: Vec3) Pose {
        return .{ .position = position };
    }

    pub fn apply(self: Pose, local: Vec3) Vec3 {
        return self.position.add(self.rotation.rotate(local));
    }

    pub fn applyDirection(self: Pose, local: Vec3) Vec3 {
        return self.rotation.rotate(local);
    }

    pub fn inverseDirection(self: Pose, world: Vec3) Vec3 {
        return self.rotation.conjugate().rotate(world);
    }

    pub fn translated(self: Pose, by: Vec3) Pose {
        return .{ .position = self.position.add(by), .rotation = self.rotation };
    }
};

/// A pose from outside, refused rather than repaired: a position that is not finite or lies
/// beyond `max_coordinate`, or a rotation `core.math.Quat.validated` refuses. The rotation is
/// returned normalised, through the one entry point every rotation from outside takes.
pub fn validatePose(pose: Pose) error{InvalidPose}!Pose {
    if (!positionValid(pose.position)) return error.InvalidPose;
    const r = pose.rotation;
    const rotation = Quat.validated(r.x, r.y, r.z, r.w) catch return error.InvalidPose;
    return .{ .position = pose.position, .rotation = rotation };
}

pub fn positionValid(p: Vec3) bool {
    return p.isFinite() and @abs(p.x) <= max_coordinate and @abs(p.y) <= max_coordinate and
        @abs(p.z) <= max_coordinate;
}

pub const Aabb = struct {
    min: Vec3,
    max: Vec3,

    pub fn around(p: Vec3) Aabb {
        return .{ .min = p, .max = p };
    }

    pub fn include(self: Aabb, p: Vec3) Aabb {
        return .{
            .min = .init(@min(self.min.x, p.x), @min(self.min.y, p.y), @min(self.min.z, p.z)),
            .max = .init(@max(self.max.x, p.x), @max(self.max.y, p.y), @max(self.max.z, p.z)),
        };
    }

    pub fn merge(a: Aabb, b: Aabb) Aabb {
        return a.include(b.min).include(b.max);
    }

    pub fn expand(self: Aabb, by: f32) Aabb {
        const e: Vec3 = .init(by, by, by);
        return .{ .min = self.min.sub(e), .max = self.max.add(e) };
    }

    /// The box covering this one at every point of a translation by `motion`.
    pub fn sweptBy(self: Aabb, motion: Vec3) Aabb {
        return self.merge(.{ .min = self.min.add(motion), .max = self.max.add(motion) });
    }

    /// Closed on both sides: touching boxes overlap, so a query never misses a shape it
    /// merely touches because the bounds disagreed by a rounding.
    pub fn overlaps(a: Aabb, b: Aabb) bool {
        return a.min.x <= b.max.x and b.min.x <= a.max.x and
            a.min.y <= b.max.y and b.min.y <= a.max.y and
            a.min.z <= b.max.z and b.min.z <= a.max.z;
    }
};

/// The solid under a shape's radius.
pub const Core = union(enum) {
    point,
    segment: f32, // half-height along local Y
    box: Vec3, // half-extents
    /// A hull's local points. Borrowed from the world for the length of one query, never held.
    points: []const Vec3,
};

/// A shape in the form the narrowphase measures: a posed core and a radius.
pub const Convex = struct {
    core: Core,
    radius: f32,
    pose: Pose,

    /// The core's farthest point along `dir` (world space). Ties go to the positive side, and
    /// among a hull's points to the first, so the answer is a function of the input alone (I9).
    pub fn support(self: Convex, dir: Vec3) Vec3 {
        return switch (self.core) {
            .point => self.pose.position,
            .segment => |h| blk: {
                const local = self.pose.inverseDirection(dir);
                break :blk self.pose.apply(.init(0, if (local.y >= 0) h else -h, 0));
            },
            .box => |he| blk: {
                const d = self.pose.inverseDirection(dir);
                break :blk self.pose.apply(.init(
                    if (d.x >= 0) he.x else -he.x,
                    if (d.y >= 0) he.y else -he.y,
                    if (d.z >= 0) he.z else -he.z,
                ));
            },
            .points => |pts| blk: {
                const d = self.pose.inverseDirection(dir);
                var best = pts[0];
                var best_dot = best.dot(d);
                for (pts[1..]) |p| {
                    const v = p.dot(d);
                    if (v > best_dot) {
                        best = p;
                        best_dot = v;
                    }
                }
                break :blk self.pose.apply(best);
            },
        };
    }

    pub fn translated(self: Convex, by: Vec3) Convex {
        var out = self;
        out.pose = self.pose.translated(by);
        return out;
    }

    /// World bounds of the rounded shape.
    pub fn bounds(self: Convex) Aabb {
        const b: Aabb = switch (self.core) {
            .point => .around(self.pose.position),
            .segment => |h| Aabb.around(self.pose.apply(.init(0, h, 0))).include(self.pose.apply(.init(0, -h, 0))),
            .box => |he| blk: {
                // |R|·he: each world axis's reach is the sum of the box axes' projections.
                const ax = self.pose.applyDirection(.init(he.x, 0, 0));
                const ay = self.pose.applyDirection(.init(0, he.y, 0));
                const az = self.pose.applyDirection(.init(0, 0, he.z));
                const reach: Vec3 = .init(
                    @abs(ax.x) + @abs(ay.x) + @abs(az.x),
                    @abs(ax.y) + @abs(ay.y) + @abs(az.y),
                    @abs(ax.z) + @abs(ay.z) + @abs(az.z),
                );
                break :blk .{ .min = self.pose.position.sub(reach), .max = self.pose.position.add(reach) };
            },
            .points => |pts| blk: {
                var acc: Aabb = .around(self.pose.apply(pts[0]));
                for (pts[1..]) |p| acc = acc.include(self.pose.apply(p));
                break :blk acc;
            },
        };
        return b.expand(self.radius);
    }

    /// The normal of the face a contact lies on, for `collision3d.md` §5.3: a box's face most
    /// aligned with the contact normal (ties to the lowest axis), and the contact normal itself
    /// for the shapes that have no faces in M23.
    pub fn surfaceNormal(self: Convex, contact_normal: Vec3) Vec3 {
        switch (self.core) {
            .box => {
                const n = self.pose.inverseDirection(contact_normal);
                const ax = @abs(n.x);
                const ay = @abs(n.y);
                const az = @abs(n.z);
                const local: Vec3 = if (ax >= ay and ax >= az)
                    .init(if (n.x >= 0) 1 else -1, 0, 0)
                else if (ay >= az)
                    .init(0, if (n.y >= 0) 1 else -1, 0)
                else
                    .init(0, 0, if (n.z >= 0) 1 else -1);
                return self.pose.applyDirection(local);
            },
            else => return contact_normal,
        }
    }
};

/// The volume of the largest tetrahedron a deterministic scan finds among `points`: the first
/// point; the point farthest from it; the point farthest from their line; the point farthest from
/// their plane. It under-estimates the true maximum, which only makes the refusal stricter.
pub fn hullVolume(points: []const Vec3) f32 {
    if (points.len < 4) return 0;
    const p0 = points[0];
    const p1 = farthest(points, p0, struct {
        fn dist(p: Vec3, a: Vec3) f32 {
            return p.sub(a).lengthSquared();
        }
    }.dist);
    const axis = p1.sub(p0);
    if (axis.lengthSquared() == 0) return 0;
    var p2 = p0;
    var best: f32 = -1;
    for (points) |p| {
        const d = Vec3.cross(axis, p.sub(p0)).lengthSquared();
        if (d > best) {
            best = d;
            p2 = p;
        }
    }
    const normal = Vec3.cross(axis, p2.sub(p0));
    if (normal.lengthSquared() == 0) return 0;
    var volume: f32 = 0;
    for (points) |p| {
        const v = @abs(normal.dot(p.sub(p0))) / 6;
        if (v > volume) volume = v;
    }
    return volume;
}

fn farthest(points: []const Vec3, from: Vec3, comptime metric: fn (Vec3, Vec3) f32) Vec3 {
    var best = points[0];
    var best_d: f32 = -1;
    for (points) |p| {
        const d = metric(p, from);
        if (d > best_d) {
            best_d = d;
            best = p;
        }
    }
    return best;
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

test "dimensions: zero, negative and non-finite are refused, a zero-length capsule is not" {
    try testing.expect((Shape{ .sphere = .{ .radius = 0.5 } }).dimensionsValid());
    try testing.expect(!(Shape{ .sphere = .{ .radius = 0 } }).dimensionsValid());
    try testing.expect(!(Shape{ .sphere = .{ .radius = std.math.nan(f32) } }).dimensionsValid());
    try testing.expect((Shape{ .capsule = .{ .radius = 0.3, .half_height = 0 } }).dimensionsValid());
    try testing.expect(!(Shape{ .capsule = .{ .radius = 0.3, .half_height = -0.1 } }).dimensionsValid());
    try testing.expect(!(Shape{ .capsule = .{ .radius = 0.3, .half_height = std.math.inf(f32) } }).dimensionsValid());
    try testing.expect(!(Shape{ .box = .{ .half_extents = .init(1, 0, 1) } }).dimensionsValid());
    try testing.expect(!(Shape{ .hull = .none }).dimensionsValid());
}

test "a pose from outside: bounded, finite, unit rotation, returned normalised" {
    const ok = try validatePose(.{ .position = .init(1, 2, 3), .rotation = .{ .x = 0, .y = 0.7071, .z = 0, .w = 0.7071 } });
    try testing.expectApproxEqAbs(@as(f32, 1), ok.rotation.length(), 1e-6);
    try testing.expectError(error.InvalidPose, validatePose(.{ .position = .init(8193, 0, 0) }));
    try testing.expectError(error.InvalidPose, validatePose(.{ .position = .init(0, std.math.nan(f32), 0) }));
    try testing.expectError(error.InvalidPose, validatePose(.{ .rotation = .{ .x = 1, .y = 1, .z = 1, .w = 1 } }));
    try testing.expectError(error.InvalidPose, validatePose(.{ .rotation = .{ .x = 0, .y = 0, .z = 0, .w = 0 } }));
    _ = try validatePose(.{ .position = .init(-8192, 8192, 0) });
}

test "a rotated box's bounds and support follow its pose" {
    const c: Convex = .{
        .core = .{ .box = .init(1, 0.5, 0.25) },
        .radius = 0,
        .pose = .{ .position = .init(2, 0, 0), .rotation = Quat.fromAxisAngle(Vec3.up, std.math.pi / 2.0) },
    };
    const b = c.bounds();
    // A quarter turn about Y swaps the X and Z reaches.
    try testing.expectApproxEqAbs(@as(f32, 1.75), b.min.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.25), b.max.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), b.min.z, 1e-6);
    const s = c.support(.init(0, 0, 1));
    try testing.expectApproxEqAbs(@as(f32, 1), s.z, 1e-6);
}

test "a box's surface normal is its face most aligned with the contact, ties to the lowest axis" {
    const c: Convex = .{ .core = .{ .box = .init(1, 1, 1) }, .radius = 0, .pose = .identity };
    const edge = Vec3.init(1, 1, 0).normalize();
    const n = c.surfaceNormal(edge);
    try testing.expect(n.eql(.init(1, 0, 0)));
    const up = c.surfaceNormal(Vec3.init(0.3, 0.9, 0.1).normalize());
    try testing.expect(up.eql(.init(0, 1, 0)));
}

test "hull volume: a unit cube's corners pass, a flat set is zero" {
    const cube = [_]Vec3{
        .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1),
        .init(1, 1, 0), .init(1, 0, 1), .init(0, 1, 1), .init(1, 1, 1),
    };
    try testing.expect(hullVolume(&cube) > min_hull_volume);
    const flat = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 0, 1), .init(1, 0, 1), .init(0.5, 0, 0.5) };
    try testing.expectEqual(@as(f32, 0), hullVolume(&flat));
    const line = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(2, 0, 0), .init(3, 0, 0) };
    try testing.expectEqual(@as(f32, 0), hullVolume(&line));
}
