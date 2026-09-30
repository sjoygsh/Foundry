//! The collision world: bodies, shared hulls and static meshes, and what may be asked of them.
//!
//! **No time, no velocity, no step** (`collision3d.md` §3). A caller says *put this here*, *move
//! this by that* or *what is there*; gravity, jumping and speed are the game's.
//!
//! **A body is read through a const pointer and changed through named calls**, for
//! `physics2d`'s reason: there is only a linear scan to keep in step today, but a broadphase
//! added later must see every change, and a field write would bypass it. The setters take an
//! allocator for that future structure now, so their signatures do not change when it arrives.
//!
//! **Queries allocate nothing.** They scan bodies in ascending handle-index order — which is
//! also the order ties resolve in (§5.4) — and write into caller buffers that report a `total`,
//! so a caller whose buffer was short learns that it truncated.

const std = @import("std");
const core = @import("core");

const body_mod = @import("body.zig");
const narrow = @import("narrow.zig");
const shape_mod = @import("shape.zig");
const mesh_mod = @import("mesh.zig");

const Aabb = shape_mod.Aabb;
const Allocator = std.mem.Allocator;
const Bodies = body_mod.Bodies;
const Body = body_mod.Body;
const BodyHandle = body_mod.BodyHandle;
const Convex = shape_mod.Convex;
const Filter = body_mod.Filter;
const HullHandle = shape_mod.HullHandle;
const Hulls = shape_mod.Hulls;
const MeshHandle = shape_mod.MeshHandle;
const Meshes = shape_mod.Meshes;
const Pose = shape_mod.Pose;
const Shape = shape_mod.Shape;
const Vec3 = core.math.Vec3;

/// A hit's triangle when what it hit is not a mesh.
pub const none_triangle: u32 = std.math.maxInt(u32);

pub const AddHullError = error{ OutOfMemory, InvalidShape };
pub const AddBodyError = error{ OutOfMemory, InvalidShape, InvalidPose };
pub const SetPoseError = error{ OutOfMemory, InvalidPose };
pub const SetShapeError = error{ OutOfMemory, InvalidShape };
pub const RemoveHullError = error{InUse};
pub const AddMeshError = mesh_mod.AddError;
pub const RemoveMeshError = error{InUse};

/// What a query refuses. `InvalidQuery` covers what is neither a shape nor a pose: a ray
/// direction that is not unit, a negative or non-finite reach, a displacement that is not finite.
pub const QueryError = error{ InvalidShape, InvalidPose, InvalidQuery };

pub const Hit = struct {
    /// Of the requested displacement, in [0, 1].
    fraction: f32,
    /// On the surface hit.
    point: Vec3,
    /// Out of what was hit, toward the moving shape. Unit.
    normal: Vec3,
    /// The two-sided triangle face or closest box face, otherwise `normal` (§5.3).
    surface_normal: Vec3,
    body: BodyHandle,
    user: u64,
    triangle: u32 = none_triangle,
    started_inside: bool,
};

pub const RayHit = struct {
    /// Along the ray, metres.
    distance: f32,
    point: Vec3,
    normal: Vec3,
    surface_normal: Vec3,
    body: BodyHandle,
    user: u64,
    triangle: u32 = none_triangle,
    started_inside: bool,
};

pub const Overlap = struct {
    body: BodyHandle,
    user: u64,
    triangle: u32 = none_triangle,
};

pub const Contact = struct {
    body: BodyHandle,
    user: u64,
    triangle: u32 = none_triangle,
    /// Out of the body, toward the query shape: the way to push the query shape out.
    normal: Vec3,
    /// How far the query shape is inside, metres. Positive.
    depth: f32,
    /// On the body's surface.
    point: Vec3,
};

/// How many results a buffer received, and how many there were.
pub const Found = struct {
    count: u32,
    total: u32,
};

const Hull = struct {
    points: []Vec3,
    /// Bodies naming this hull. It cannot be removed while any do.
    users: u32 = 0,
};

pub const World = struct {
    bodies: core.HandlePool(Bodies, Body) = .empty,
    hulls: core.HandlePool(Hulls, Hull) = .empty,
    meshes: core.HandlePool(Meshes, mesh_mod.Mesh) = .empty,
    triangle_scratch: []u32 = &.{},

    pub const empty: World = .{};

    pub fn deinit(self: *World, gpa: Allocator) void {
        var it = self.hulls.iterator();
        while (it.next()) |entry| gpa.free(entry.value.points);
        self.hulls.deinit(gpa);
        var meshes = self.meshes.iterator();
        while (meshes.next()) |entry| entry.value.deinit(gpa);
        self.meshes.deinit(gpa);
        gpa.free(self.triangle_scratch);
        self.bodies.deinit(gpa);
        self.* = .empty;
    }

    // -- hulls -----------------------------------------------------------------------

    /// A convex hull of `points`, in its own local space, copied into the world.
    ///
    /// Refused as `InvalidShape` unless there are 4 to 256 points, every one finite and within
    /// `shape.max_coordinate`, spanning at least `shape.min_hull_volume`.
    pub fn addHull(self: *World, gpa: Allocator, points: []const Vec3) AddHullError!HullHandle {
        if (points.len < shape_mod.min_hull_points or points.len > shape_mod.max_hull_points) return error.InvalidShape;
        for (points) |p| if (!shape_mod.positionValid(p)) return error.InvalidShape;
        if (!(shape_mod.hullVolume(points) >= shape_mod.min_hull_volume)) return error.InvalidShape;
        const owned = try gpa.dupe(Vec3, points);
        errdefer gpa.free(owned);
        return self.hulls.add(gpa, .{ .points = owned });
    }

    /// False for a stale handle. Refused as `InUse` while any body names the hull.
    pub fn removeHull(self: *World, gpa: Allocator, handle: HullHandle) RemoveHullError!bool {
        const hull = self.hulls.get(handle) orelse return false;
        if (hull.users > 0) return error.InUse;
        gpa.free(hull.points);
        return self.hulls.remove(handle);
    }

    pub fn hullCount(self: *const World) u32 {
        return self.hulls.count();
    }

    // -- copied static triangle meshes -----------------------------------------------

    /// Validate before allocating; `mesh.validate` exposes the first offending triangle.
    /// The world owns the arrays, tree and query scratch after this returns.
    pub fn addMesh(self: *World, gpa: Allocator, positions: []const Vec3, indices: []const u32) AddMeshError!MeshHandle {
        var owned = try mesh_mod.Mesh.init(gpa, positions, indices);
        errdefer owned.deinit(gpa);
        if (self.triangle_scratch.len < owned.order.len) {
            const scratch = try gpa.alloc(u32, owned.order.len);
            gpa.free(self.triangle_scratch);
            self.triangle_scratch = scratch;
        }
        return self.meshes.add(gpa, owned);
    }

    pub fn removeMesh(self: *World, gpa: Allocator, handle: MeshHandle) RemoveMeshError!bool {
        const existing = self.meshes.get(handle) orelse return false;
        if (existing.users > 0) return error.InUse;
        existing.deinit(gpa);
        return self.meshes.remove(handle);
    }

    pub fn meshCount(self: *const World) u32 {
        return self.meshes.count();
    }

    // -- bodies ----------------------------------------------------------------------

    pub fn addBody(self: *World, gpa: Allocator, new: Body) AddBodyError!BodyHandle {
        if (!self.shapeValid(new.shape)) return error.InvalidShape;
        if (new.shape == .mesh and new.kind != .static) return error.InvalidShape;
        var stored = new;
        stored.pose = try shape_mod.validatePose(new.pose);
        const handle = try self.bodies.add(gpa, stored);
        self.retain(stored.shape);
        return handle;
    }

    pub fn removeBody(self: *World, gpa: Allocator, handle: BodyHandle) bool {
        _ = gpa; // for the broadphase that does not exist yet (see the file's header)
        const existing = self.bodies.get(handle) orelse return false;
        self.release(existing.shape);
        return self.bodies.remove(handle);
    }

    /// A body, for reading. Const on purpose (see the file's header).
    pub fn body(self: *World, handle: BodyHandle) ?*const Body {
        return self.bodies.get(handle);
    }

    pub fn bodyCount(self: *const World) u32 {
        return self.bodies.count();
    }

    /// Live bodies in ascending handle-index order (I9).
    pub fn bodyIterator(self: *World) core.HandlePool(Bodies, Body).Iterator {
        return self.bodies.iterator();
    }

    /// A teleport: nothing is tested. False for a stale handle.
    pub fn setPose(self: *World, gpa: Allocator, handle: BodyHandle, pose: Pose) SetPoseError!bool {
        _ = gpa;
        const valid = try shape_mod.validatePose(pose);
        const existing = self.bodies.get(handle) orelse return false;
        existing.pose = valid;
        return true;
    }

    pub fn setShape(self: *World, gpa: Allocator, handle: BodyHandle, new: Shape) SetShapeError!bool {
        _ = gpa;
        if (!self.shapeValid(new)) return error.InvalidShape;
        const existing = self.bodies.get(handle) orelse return false;
        if (new == .mesh and existing.kind != .static) return error.InvalidShape;
        self.retain(new);
        self.release(existing.shape);
        existing.shape = new;
        return true;
    }

    pub fn setFilter(self: *World, handle: BodyHandle, layer: u32, mask: u32) bool {
        const existing = self.bodies.get(handle) orelse return false;
        existing.layer = layer;
        existing.mask = mask;
        return true;
    }

    pub fn setUser(self: *World, handle: BodyHandle, user: u64) bool {
        const existing = self.bodies.get(handle) orelse return false;
        existing.user = user;
        return true;
    }

    /// A mesh remains static through every setter, not just when added. False for a stale body.
    pub fn setKind(self: *World, handle: BodyHandle, kind: body_mod.BodyKind) error{InvalidShape}!bool {
        const existing = self.bodies.get(handle) orelse return false;
        if (existing.shape == .mesh and kind != .static) return error.InvalidShape;
        existing.kind = kind;
        return true;
    }

    /// World bounds of a body's rounded shape, or null for a stale handle.
    pub fn boundsOf(self: *World, handle: BodyHandle) ?Aabb {
        const existing = self.bodies.get(handle) orelse return null;
        return self.bodyBounds(existing.*);
    }

    // -- queries ---------------------------------------------------------------------

    /// The nearest surface along a ray. `direction` must be unit (to `core.math.Quat`'s loose
    /// tolerance, then normalised); `max_distance` finite and not negative. A ray that starts
    /// inside a shape hits it at distance 0, `started_inside`.
    pub fn raycast(
        self: *World,
        origin: Vec3,
        direction: Vec3,
        max_distance: f32,
        filter: Filter,
    ) QueryError!?RayHit {
        if (!shape_mod.positionValid(origin)) return error.InvalidPose;
        if (!direction.isFinite() or @abs(direction.length() - 1) > core.math.Quat.unit_tolerance) return error.InvalidQuery;
        if (!std.math.isFinite(max_distance) or max_distance < 0) return error.InvalidQuery;
        const dir = direction.normalize();
        const ray: Convex = .{ .core = .point, .radius = 0, .pose = .at(origin) };
        const reach = dir.scale(max_distance);
        const hit = self.earliest(ray, reach, 0, filter) orelse return null;
        return .{
            .distance = hit.fraction * max_distance,
            .point = hit.point,
            .normal = hit.normal,
            .surface_normal = hit.surface_normal,
            .body = hit.body,
            .user = hit.user,
            .triangle = hit.triangle,
            .started_inside = hit.started_inside,
        };
    }

    /// The earliest hit of `shape`, standing at `pose`, translated by `displacement`. It stops
    /// `contact_skin` short along the contact normal, so the next query does not begin touching.
    pub fn shapeCast(
        self: *World,
        shape: Shape,
        pose: Pose,
        displacement: Vec3,
        filter: Filter,
    ) QueryError!?Hit {
        const moving = try self.queryConvex(shape, pose);
        if (!displacement.isFinite()) return error.InvalidQuery;
        return self.earliest(moving, displacement, narrow.contact_skin, filter);
    }

    /// Every body `shape` at `pose` overlaps — penetrates, not merely touches — in handle order.
    pub fn overlap(self: *World, shape: Shape, pose: Pose, filter: Filter, out: []Overlap) QueryError!Found {
        const query = try self.queryConvex(shape, pose);
        const area = query.bounds();
        var found: Found = .{ .count = 0, .total = 0 };
        var it = self.bodies.iterator();
        while (it.next()) |entry| {
            var candidates = self.candidate(entry.id, entry.value.*, area, filter) orelse continue;
            while (candidates.next()) |other| {
                if (narrow.separation(query, other.convex).distance >= 0) continue;
                if (found.count < out.len) {
                    out[found.count] = .{ .body = entry.id, .user = entry.value.user, .triangle = other.triangle };
                    found.count += 1;
                }
                found.total += 1;
                break; // A mesh body appears once, at its first overlapping triangle.
            }
        }
        return found;
    }

    /// `overlap`, with each overlap's depth and the way out. What depenetration uses.
    pub fn contacts(self: *World, shape: Shape, pose: Pose, filter: Filter, out: []Contact) QueryError!Found {
        const query = try self.queryConvex(shape, pose);
        const area = query.bounds();
        var found: Found = .{ .count = 0, .total = 0 };
        var it = self.bodies.iterator();
        while (it.next()) |entry| {
            var candidates = self.candidate(entry.id, entry.value.*, area, filter) orelse continue;
            while (candidates.next()) |other| {
                const s = narrow.separation(query, other.convex);
                if (s.distance >= 0) continue;
                if (found.count < out.len) {
                    out[found.count] = .{
                        .body = entry.id,
                        .user = entry.value.user,
                        .triangle = other.triangle,
                        .normal = s.normal,
                        .depth = -s.distance,
                        .point = s.point_b,
                    };
                    found.count += 1;
                }
                found.total += 1;
            }
        }
        return found;
    }

    // -- internals -------------------------------------------------------------------

    /// The earliest hit over every admitted body. **Ties go to the lower handle** because the
    /// scan is in handle order and only a strictly earlier fraction replaces the best (§5.4).
    fn earliest(self: *World, moving: Convex, displacement: Vec3, target: f32, filter: Filter) ?Hit {
        const area = moving.bounds().sweptBy(displacement).expand(target);
        var best: ?Hit = null;
        var it = self.bodies.iterator();
        while (it.next()) |entry| {
            var candidates = self.candidate(entry.id, entry.value.*, area, filter) orelse continue;
            while (candidates.next()) |other| {
                const c = narrow.cast(moving, displacement, other.convex, target) orelse continue;
                if (best) |b| if (!(c.fraction < b.fraction)) continue;
                best = .{
                    .fraction = c.fraction,
                    .point = c.point,
                    .normal = c.normal,
                    .surface_normal = other.convex.surfaceNormal(c.normal),
                    .body = entry.id,
                    .user = entry.value.user,
                    .triangle = other.triangle,
                    .started_inside = c.started_inside,
                };
            }
        }
        return best;
    }

    const Part = struct { convex: Convex, triangle: u32 = none_triangle };
    const Candidates = struct {
        convex: ?Convex = null,
        mesh: ?*const mesh_mod.Mesh = null,
        pose: Pose = .identity,
        triangles: []const u32 = &.{},
        cursor: usize = 0,

        fn next(self: *Candidates) ?Part {
            if (self.convex) |c| {
                self.convex = null;
                return .{ .convex = c };
            }
            if (self.cursor == self.triangles.len) return null;
            const t = self.triangles[self.cursor];
            self.cursor += 1;
            return .{ .convex = .{ .core = .{ .triangle = self.mesh.?.triangle(t) }, .radius = 0, .pose = self.pose }, .triangle = t };
        }
    };

    fn candidate(self: *World, id: BodyHandle, b: Body, area: Aabb, filter: Filter) ?Candidates {
        if (filter.ignore) |ignored| if (ignored.eql(id)) return null;
        if (!body_mod.maskAdmits(filter.mask, b)) return null;
        if (!self.bodyBounds(b).expand(0.002).overlaps(area)) return null;
        if (b.shape == .mesh) {
            const m = self.meshes.get(b.shape.mesh).?;
            return .{ .mesh = m, .pose = b.pose, .triangles = m.candidates(b.pose, area, self.triangle_scratch) };
        }
        return .{ .convex = self.convexOf(b.shape, b.pose) };
    }

    fn bodyBounds(self: *World, b: Body) Aabb {
        if (b.shape == .mesh) {
            const c: Convex = .{ .core = .point, .radius = 0, .pose = b.pose };
            return c.poseBounds(self.meshes.get(b.shape.mesh).?.nodes[0].bounds);
        }
        return self.convexOf(b.shape, b.pose).bounds();
    }

    fn queryConvex(self: *World, shape: Shape, pose: Pose) QueryError!Convex {
        if (!self.shapeValid(shape) or shape == .mesh) return error.InvalidShape;
        const valid = try shape_mod.validatePose(pose);
        return self.convexOf(shape, valid);
    }

    fn shapeValid(self: *World, shape: Shape) bool {
        if (!shape.dimensionsValid()) return false;
        return switch (shape) {
            .hull => |h| self.hulls.contains(h),
            .mesh => |m| self.meshes.contains(m),
            else => true,
        };
    }

    fn convexOf(self: *World, shape: Shape, pose: Pose) Convex {
        return switch (shape) {
            .sphere => |s| .{ .core = .point, .radius = s.radius, .pose = pose },
            .capsule => |c| .{ .core = .{ .segment = c.half_height }, .radius = c.radius, .pose = pose },
            .box => |b| .{ .core = .{ .box = b.half_extents }, .radius = 0, .pose = pose },
            .hull => |h| .{ .core = .{ .points = self.hulls.get(h).?.points }, .radius = 0, .pose = pose },
            .mesh => unreachable, // Only queryConvex or the convex branch of candidate calls this.
        };
    }

    fn retain(self: *World, shape: Shape) void {
        if (shape == .hull) self.hulls.get(shape.hull).?.users += 1;
        if (shape == .mesh) self.meshes.get(shape.mesh).?.users += 1;
    }

    fn release(self: *World, shape: Shape) void {
        if (shape == .hull) self.hulls.get(shape.hull).?.users -= 1;
        if (shape == .mesh) self.meshes.get(shape.mesh).?.users -= 1;
    }
};
