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
const character_mod = @import("character.zig");
const report_mod = @import("report.zig");

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
const Counters = report_mod.Counters;
const QueryKind = report_mod.QueryKind;
const Report = report_mod.Report;

/// A hit's triangle when what it hit is not a mesh.
pub const none_triangle: u32 = std.math.maxInt(u32);

pub const AddHullError = error{ OutOfMemory, InvalidShape };
pub const AddBodyError = error{ OutOfMemory, InvalidShape, InvalidPose };
pub const SetPoseError = error{ OutOfMemory, InvalidPose };
pub const SetShapeError = error{ OutOfMemory, InvalidShape };
pub const RemoveHullError = error{InUse};
pub const AddMeshError = mesh_mod.AddError;
pub const RemoveMeshError = error{InUse};
/// What `moveBody` refuses: a pose that is not one, or a body that is not kinematic.
pub const MoveBodyError = error{ InvalidPose, NotKinematic };

/// What a `moveBody` did to the characters in its way (`collision-extras.md` §7).
pub const BodyMove = struct {
    /// Characters it overlapped and moved, its riders aside: they are carried at their own move.
    pushed: u32 = 0,
    /// Characters it still overlaps after moving them, written into the caller's buffer.
    crushed: Found = .{ .count = 0, .total = 0 },
};

/// What a query refuses. `InvalidQuery` covers what is neither a shape nor a pose: a ray
/// direction that is not unit, a negative or non-finite reach, a displacement that is not finite.
pub const QueryError = error{ InvalidShape, InvalidPose, InvalidQuery };
/// What `setUp` refuses: an up that is not a unit direction, or a world that already holds a
/// character, whose capsule stands along the up it was made with.
pub const SetUpError = error{ InvalidUp, CharactersPresent };

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
    /// The triangle's surface, or its body's where it has none (`collision-extras.md` §6).
    surface: core.ContentId = .none,
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
    /// The triangle's surface, or its body's where it has none (`collision-extras.md` §6).
    surface: core.ContentId = .none,
    started_inside: bool,
};

pub const Overlap = struct {
    body: BodyHandle,
    user: u64,
    triangle: u32 = none_triangle,
    surface: core.ContentId = .none,
};

pub const Contact = struct {
    body: BodyHandle,
    user: u64,
    triangle: u32 = none_triangle,
    surface: core.ContentId = .none,
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
    characters: core.HandlePool(character_mod.Characters, character_mod.Character) = .empty,
    bodies: core.HandlePool(Bodies, Body) = .empty,
    hulls: core.HandlePool(Hulls, Hull) = .empty,
    meshes: core.HandlePool(Meshes, mesh_mod.Mesh) = .empty,
    triangle_scratch: []u32 = &.{},
    /// The controller's up (`collision-extras.md` §3): what walkable, horizontal, a step and a
    /// ceiling are measured against, and what a character's capsule stands along. +Y unless set.
    /// Gravity stays the game's, and rendering's +Y (ADR-0048) is untouched.
    up: Vec3 = Vec3.up,
    /// The rotation from +Y to `up`, which stands a capsule along it.
    up_rotation: core.math.Quat = core.math.Quat.identity,
    /// Work done since they were last taken (`collision-scale.md` §3). Never simulation state.
    counters: Counters = .{},

    pub const empty: World = .{};

    // -- the report ------------------------------------------------------------------

    /// What the world holds, and its counters as they stand. It takes nothing.
    pub fn report(self: *World) Report {
        var out: Report = .{
            .characters = self.characters.count(),
            .meshes = self.meshes.count(),
            .hulls = self.hulls.count(),
        };
        var bodies = self.bodies.iterator();
        while (bodies.next()) |entry| switch (entry.value.kind) {
            .static => out.bodies_static += 1,
            .kinematic => out.bodies_kinematic += 1,
        };
        var meshes = self.meshes.iterator();
        while (meshes.next()) |entry| out.triangles += entry.value.order.len;
        return out.withCounters(self.counters);
    }

    /// The counters, which are then zero: a game takes them once a tick or once a frame.
    pub fn takeCounters(self: *World) Counters {
        const taken = self.counters;
        self.counters = .{};
        return taken;
    }

    pub fn counted(self: *World, kind: QueryKind) void {
        self.counters.queries[@intFromEnum(kind)] +%= 1;
    }

    /// One narrowphase test against `part`. Every pair is GJK's until §8.
    fn tested(self: *World, part: Part) void {
        self.counters.pairs_gjk +%= 1;
        if (part.triangle != none_triangle) self.counters.triangles_tested +%= 1;
    }

    /// Sets the controller's up. Only while the world holds no character, since a capsule is
    /// stood along the up it was made with. `up` must be unit, to `Quat`'s tolerance.
    pub fn setUp(self: *World, up: Vec3) SetUpError!void {
        if (!up.isFinite() or @abs(up.length() - 1) > core.math.Quat.unit_tolerance) return error.InvalidUp;
        if (self.characters.count() != 0) return error.CharactersPresent;
        self.up = up.normalize();
        self.up_rotation = rotationTo(self.up);
    }

    pub fn deinit(self: *World, gpa: Allocator) void {
        self.characters.deinit(gpa);
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
        return self.addMeshWith(gpa, positions, indices, .{});
    }

    /// `addMesh`, with a surface and a side per triangle (`collision-extras.md` §6). Refused as
    /// `InvalidMesh` for a table past `mesh.max_surfaces`, an index past its table, or a
    /// per-triangle slice that is neither empty nor one entry a triangle.
    pub fn addMeshWith(self: *World, gpa: Allocator, positions: []const Vec3, indices: []const u32, attributes: mesh_mod.Attributes) AddMeshError!MeshHandle {
        var owned = try mesh_mod.Mesh.initWith(gpa, positions, indices, attributes);
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
        // A scale a shape cannot take is a shape the body cannot hold (§4).
        if (!body_mod.scaleValid(new.shape, new.scale)) return error.InvalidShape;
        if (new.shape == .mesh and new.kind != .static) return error.InvalidShape;
        // A push the body cannot take, like a scale, is a body it cannot be.
        if (!body_mod.pushValid(new.kind, new.push)) return error.InvalidShape;
        var stored = new;
        stored.pose = try shape_mod.validatePose(new.pose);
        stored.motion = .{ .from = stored.pose, .to = stored.pose };
        stored.serial = 0;
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

    /// A teleport: nothing is tested, and nobody is carried or pushed. A carry still owed to a
    /// rider is cancelled: the body has moved, and its motion is none. False for a stale handle.
    pub fn setPose(self: *World, gpa: Allocator, handle: BodyHandle, pose: Pose) SetPoseError!bool {
        _ = gpa;
        const valid = try shape_mod.validatePose(pose);
        const existing = self.bodies.get(handle) orelse return false;
        existing.pose = valid;
        existing.motion = .{ .from = valid, .to = valid };
        existing.serial +%= 1;
        return true;
    }

    /// Moves a kinematic body and records the motion (`collision-extras.md` §7): a character
    /// standing on it is carried by it at that character's next move. Each other character it now
    /// overlaps, in handle order, is moved by the body's motion at its centre through its own
    /// controller, ignoring the body, so it slides along walls. One that still overlaps it is
    /// written to `crushed`. The body's move stands either way. Null for a stale handle.
    pub fn moveBody(self: *World, gpa: Allocator, handle: BodyHandle, pose: Pose, crushed: []character_mod.CharacterHandle) MoveBodyError!?BodyMove {
        const valid = try shape_mod.validatePose(pose);
        const existing = self.bodies.get(handle) orelse return null;
        if (existing.kind != .kinematic) return error.NotKinematic;
        self.moveBodyAlone(handle, valid);
        var result: BodyMove = .{};
        const moved = self.bodies.get(handle).?.*;
        var it = self.characters.iterator();
        while (it.next()) |entry| {
            const c = entry.value.*;
            if (c.body.eql(handle)) continue;
            if (c.ground) |g| if (g.body.eql(handle)) continue;
            const rider = self.bodies.get(c.body) orelse continue;
            if (!body_mod.filtersAdmit(moved, rider.*)) continue;
            if (!self.overlapsBody(handle, rider.*)) continue;
            const centre = rider.pose.position;
            const local = moved.motion.from.rotation.conjugate().rotate(centre.sub(moved.motion.from.position));
            const by = moved.motion.to.apply(local).sub(centre);
            result.pushed += 1;
            _ = character_mod.moveWith(self, entry.id, by, &.{}, .{ .carry = false, .push = false, .ignore = handle }) catch {};
            if (self.overlapsBody(handle, self.bodies.get(c.body).?.*)) {
                if (result.crushed.count < crushed.len) {
                    crushed[result.crushed.count] = entry.id;
                    result.crushed.count += 1;
                }
                result.crushed.total += 1;
            }
        }
        _ = gpa; // for the broadphase that does not exist yet (see the file's header)
        return result;
    }

    /// The pose and the motion, with no character moved: a pushed body's move (§8), one level deep.
    pub fn moveBodyAlone(self: *World, handle: BodyHandle, pose: Pose) void {
        const existing = self.bodies.get(handle).?;
        existing.motion = .{ .from = existing.pose, .to = pose };
        existing.pose = pose;
        existing.serial +%= 1;
    }

    /// Whether the body `handle` overlaps `other`'s shape: penetrates, not merely touches.
    fn overlapsBody(self: *World, handle: BodyHandle, other: Body) bool {
        const b = self.bodies.get(handle) orelse return false;
        var query = self.convexOf(other.shape, other.pose);
        query.scale = other.scale;
        var candidates = self.candidate(handle, b.*, query.bounds(), .{}) orelse return false;
        while (candidates.next()) |part| {
            if (!part.admits(query.pose.position, .zero)) continue;
            self.tested(part);
            if (part.separation(query).distance < 0) return true;
        }
        return false;
    }

    /// How a character's move pushes this body (§8): a ratio in [0, 1]. Refused for a static
    /// body unless 0. False for a stale handle.
    pub fn setPush(self: *World, handle: BodyHandle, push: f32) error{InvalidShape}!bool {
        const existing = self.bodies.get(handle) orelse return false;
        if (!body_mod.pushValid(existing.kind, push)) return error.InvalidShape;
        existing.push = push;
        return true;
    }

    pub fn setShape(self: *World, gpa: Allocator, handle: BodyHandle, new: Shape) SetShapeError!bool {
        _ = gpa;
        if (!self.shapeValid(new)) return error.InvalidShape;
        const existing = self.bodies.get(handle) orelse return false;
        if (new == .mesh and existing.kind != .static) return error.InvalidShape;
        if (!body_mod.scaleValid(new, existing.scale)) return error.InvalidShape;
        self.retain(new);
        self.release(existing.shape);
        existing.shape = new;
        return true;
    }

    /// A mesh's or hull's size at runtime (`collision-extras.md` §4). Refused for a scale the body's
    /// shape cannot take. False for a stale handle.
    pub fn setScale(self: *World, gpa: Allocator, handle: BodyHandle, scale: Vec3) SetShapeError!bool {
        _ = gpa;
        const existing = self.bodies.get(handle) orelse return false;
        if (!body_mod.scaleValid(existing.shape, scale)) return error.InvalidShape;
        existing.scale = scale;
        return true;
    }

    pub fn setFilter(self: *World, handle: BodyHandle, layer: u32, mask: u32) bool {
        const existing = self.bodies.get(handle) orelse return false;
        existing.layer = layer;
        existing.mask = mask;
        return true;
    }

    /// What the body is made of (§6). False for a stale handle.
    pub fn setSurface(self: *World, handle: BodyHandle, surface: core.ContentId) bool {
        const existing = self.bodies.get(handle) orelse return false;
        existing.surface = surface;
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
        if (!body_mod.pushValid(kind, existing.push)) return error.InvalidShape;
        existing.kind = kind;
        return true;
    }

    /// World bounds of a body's rounded shape, or null for a stale handle.
    pub fn boundsOf(self: *World, handle: BodyHandle) ?Aabb {
        const existing = self.bodies.get(handle) orelse return null;
        return self.bodyBounds(existing.*);
    }

    // -- queries ---------------------------------------------------------------------

    pub const addCharacter = character_mod.add;
    pub const removeCharacter = character_mod.remove;
    pub const setCharacterFeet = character_mod.setFeet;
    pub const moveCharacter = character_mod.move;

    pub fn character(self: *World, handle: character_mod.CharacterHandle) ?*const character_mod.Character {
        return self.characters.get(handle);
    }

    /// Controller-only query: pairs are symmetric, unlike public one-sided queries. A resting
    /// skin contact does not block tangential/away motion. No public query semantics change.
    pub fn characterCast(self: *World, moving: Convex, displacement: Vec3, source: BodyHandle, walkable_y: f32) ?Hit {
        return self.controllerCast(moving, displacement, source, .none, walkable_y);
    }

    /// Downward ground/landing probes prefer a walkable face even on an overhanging edge.
    pub fn characterProbe(self: *World, moving: Convex, displacement: Vec3, source: BodyHandle, ground_y: ?f32) ?Hit {
        return self.controllerProbe(moving, displacement, source, .none, ground_y);
    }

    pub fn characterContact(self: *World, query: Convex, source: BodyHandle) ?Contact {
        return self.controllerContact(query, source, .none);
    }

    /// `characterCast`, also ignoring `also`: the body carrying the character, or the one moving
    /// it (`collision-extras.md` §7). `.none` ignores nothing more.
    pub fn controllerCast(self: *World, moving: Convex, displacement: Vec3, source: BodyHandle, also: BodyHandle, walkable_y: f32) ?Hit {
        const actor = self.bodies.get(source) orelse return null;
        return self.earliestPair(moving, displacement, narrow.contact_skin, .{ .mask = actor.mask, .ignore = source }, actor.layer, walkable_y, true, also);
    }

    pub fn controllerProbe(self: *World, moving: Convex, displacement: Vec3, source: BodyHandle, also: BodyHandle, ground_y: ?f32) ?Hit {
        const actor = self.bodies.get(source) orelse return null;
        return self.earliestPair(moving, displacement, narrow.contact_skin, .{ .mask = actor.mask, .ignore = source }, actor.layer, ground_y, false, also);
    }

    /// Deepest contact without a bounded output buffer losing a later, deeper triangle.
    /// Equal depths keep handle-then-triangle order, just like all other queries.
    pub fn controllerContact(self: *World, query: Convex, source: BodyHandle, also: BodyHandle) ?Contact {
        const actor = self.bodies.get(source) orelse return null;
        var best: ?Contact = null;
        var it = self.bodies.iterator();
        while (it.next()) |entry| {
            self.counters.bodies_visited +%= 1;
            if (entry.value.mask & actor.layer == 0) continue;
            if (entry.id.eql(also)) continue;
            var candidates = self.candidate(entry.id, entry.value.*, query.bounds(), .{ .mask = actor.mask, .ignore = source }) orelse continue;
            while (candidates.next()) |other| {
                if (!other.admits(query.pose.position, .zero)) continue;
                self.tested(other);
                const s = other.separation(query);
                if (s.distance >= 0) continue;
                if (best) |b| if (-s.distance <= b.depth) continue;
                best = .{ .body = entry.id, .user = entry.value.user, .triangle = other.triangle, .surface = other.surface, .normal = s.normal, .depth = -s.distance, .point = s.point_b };
            }
        }
        return best;
    }

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
        self.counted(.ray);
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
            .surface = hit.surface,
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
        self.counted(.cast);
        return self.earliest(moving, displacement, narrow.contact_skin, filter);
    }

    /// The earliest hit of `shape` moved from `from` to `to`, turning as it goes
    /// (`collision-extras.md` §5): its position goes linearly and its rotation by `slerp`, and the
    /// hit's `fraction` is of that path. Like `shapeCast` it stops `contact_skin` short.
    ///
    /// **Conservative advancement:** no point of the shape moves faster, per unit of the path,
    /// than `|Δp| + θ·R`, θ the turn's angle and R the farthest the shape reaches from its origin.
    /// So the nearest candidate's distance bounds how far the path may advance without passing
    /// it. At most `max_cast_iterations` advances. A sweep that does not turn is `shapeCast`.
    pub fn shapeSweep(self: *World, shape: Shape, from: Pose, to: Pose, filter: Filter) QueryError!?Hit {
        const start = try self.queryConvex(shape, from);
        const end_pose = try shape_mod.validatePose(to);
        self.counted(.sweep);
        const begin = start.pose;
        const d = @abs(begin.rotation.dot(end_pose.rotation));
        if (d >= 1) return self.earliest(start, end_pose.position.sub(begin.position), narrow.contact_skin, filter);
        // θ = 2·asin(√(1 − d²)) ≤ π·√(1 − d²), with no inverse trig.
        const turn = std.math.pi * @sqrt(@max(0, 1 - d * d));
        const reach = reachOf(start);
        const travel = end_pose.position.sub(begin.position);
        const speed = travel.length() + turn * reach;
        var end = start;
        end.pose = end_pose;
        const area = start.bounds().merge(end.bounds()).expand(turn * reach + narrow.contact_skin);
        var fraction: f32 = 0;
        var iteration: u32 = 0;
        var found: ?Hit = null;
        while (iteration < narrow.max_cast_iterations) : (iteration += 1) {
            var moving = start;
            moving.pose = .{ .position = begin.position.lerp(end_pose.position, fraction), .rotation = begin.rotation.slerp(end_pose.rotation, fraction) };
            const nearest = self.nearestTo(moving, travel, area, filter) orelse return null;
            const gap = nearest.separation.distance - narrow.contact_skin;
            found = .{
                .fraction = fraction,
                .point = nearest.separation.point_b,
                .normal = nearest.separation.normal,
                .surface_normal = nearest.part.convex.surfaceNormal(nearest.separation.normal),
                .body = nearest.body,
                .user = nearest.user,
                .triangle = nearest.part.triangle,
                .surface = nearest.part.surface,
                .started_inside = fraction == 0 and nearest.separation.distance < 0,
            };
            if (gap <= narrow.cast_tolerance) return found;
            fraction += gap / speed;
            if (fraction >= 1) return null;
        }
        return found;
    }

    const Nearest = struct { separation: narrow.Separation, part: Part, body: BodyHandle, user: u64 };

    /// The candidate nearest `moving` among bodies in `area`. Ties go to the lower handle, then
    /// triangle, since the scan is in that order and only a strictly nearer one replaces it.
    /// One-sided triangles are judged against `motion`, the sweep's travel.
    fn nearestTo(self: *World, moving: Convex, motion: Vec3, area: Aabb, filter: Filter) ?Nearest {
        var best: ?Nearest = null;
        var it = self.bodies.iterator();
        while (it.next()) |entry| {
            self.counters.bodies_visited +%= 1;
            var candidates = self.candidate(entry.id, entry.value.*, area, filter) orelse continue;
            while (candidates.next()) |other| {
                if (!other.admits(moving.pose.position, motion)) continue;
                self.tested(other);
                const s = narrow.separation(moving, other.convex);
                if (best) |b| if (!(s.distance < b.separation.distance)) continue;
                best = .{ .separation = s, .part = other, .body = entry.id, .user = entry.value.user };
            }
        }
        return best;
    }

    /// Every body `shape` at `pose` overlaps — penetrates, not merely touches — in handle order.
    pub fn overlap(self: *World, shape: Shape, pose: Pose, filter: Filter, out: []Overlap) QueryError!Found {
        const query = try self.queryConvex(shape, pose);
        self.counted(.overlap);
        const area = query.bounds();
        var found: Found = .{ .count = 0, .total = 0 };
        var it = self.bodies.iterator();
        while (it.next()) |entry| {
            self.counters.bodies_visited +%= 1;
            var candidates = self.candidate(entry.id, entry.value.*, area, filter) orelse continue;
            while (candidates.next()) |other| {
                if (!other.admits(query.pose.position, .zero)) continue;
                self.tested(other);
                if (narrow.separation(query, other.convex).distance >= 0) continue;
                if (found.count < out.len) {
                    out[found.count] = .{ .body = entry.id, .user = entry.value.user, .triangle = other.triangle, .surface = other.surface };
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
        self.counted(.contacts);
        const area = query.bounds();
        var found: Found = .{ .count = 0, .total = 0 };
        var it = self.bodies.iterator();
        while (it.next()) |entry| {
            self.counters.bodies_visited +%= 1;
            var candidates = self.candidate(entry.id, entry.value.*, area, filter) orelse continue;
            while (candidates.next()) |other| {
                if (!other.admits(query.pose.position, .zero)) continue;
                self.tested(other);
                const s = other.separation(query);
                if (s.distance >= 0) continue;
                if (found.count < out.len) {
                    out[found.count] = .{
                        .body = entry.id,
                        .user = entry.value.user,
                        .triangle = other.triangle,
                        .surface = other.surface,
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
        return self.earliestPair(moving, displacement, target, filter, null, null, false, .none);
    }

    /// A pushed body's cast (§8): symmetric, as a character's is, under its own filter, ignoring
    /// itself and `pusher`.
    pub fn pushCast(self: *World, handle: BodyHandle, displacement: Vec3, pusher: BodyHandle) ?Hit {
        const b = self.bodies.get(handle) orelse return null;
        var moving = self.convexOf(b.shape, b.pose);
        moving.scale = b.scale;
        return self.earliestPair(moving, displacement, narrow.contact_skin, .{ .mask = b.mask, .ignore = handle }, b.layer, null, false, pusher);
    }

    fn earliestPair(self: *World, moving: Convex, displacement: Vec3, target: f32, filter: Filter, layer: ?u32, ground_y: ?f32, sliding: bool, also: BodyHandle) ?Hit {
        const area = moving.bounds().sweptBy(displacement).expand(target);
        var best: ?Hit = null;
        var it = self.bodies.iterator();
        while (it.next()) |entry| {
            self.counters.bodies_visited +%= 1;
            if (layer) |l| if (entry.value.mask & l == 0) continue;
            if (entry.id.eql(also)) continue;
            var candidates = self.candidate(entry.id, entry.value.*, area, filter) orelse continue;
            while (candidates.next()) |other| {
                if (!other.admits(moving.pose.position, displacement)) continue;
                self.tested(other);
                const c = narrow.cast(moving, displacement, other.convex, target) orelse continue;
                if (layer != null and !c.started_inside and c.fraction == 0 and displacement.dot(c.normal) >= -1e-7) continue;
                var face = other.convex.surfaceNormal(c.normal);
                if (ground_y) |up| {
                    // A box corner belongs to several faces too, but unlike mesh faces
                    // they are represented by one convex candidate. Select a walkable face
                    // only when the witness actually lies on it, not a later hidden floor.
                    if (other.convex.core == .box and (!sliding or c.normal.dot(self.up) >= up)) {
                        const local = other.convex.pose.inverseDirection(c.point.sub(other.convex.pose.position));
                        const he = other.convex.core.box;
                        const coordinates = [_]f32{ local.x, local.y, local.z };
                        const extents = [_]f32{ he.x, he.y, he.z };
                        for (coordinates, extents, 0..) |v, extent, axis| {
                            if (@abs(@abs(v) - extent) > narrow.cast_tolerance) continue;
                            const sign: f32 = if (v >= 0) 1 else -1;
                            const local_face: Vec3 = switch (axis) {
                                0 => .init(sign, 0, 0),
                                1 => .init(0, sign, 0),
                                else => .init(0, 0, sign),
                            };
                            const possible = other.convex.pose.applyDirection(local_face);
                            if (possible.dot(self.up) >= up and possible.dot(c.normal) >= -1e-6) {
                                face = possible;
                                break;
                            }
                        }
                    }
                }
                if (best) |b| {
                    if (ground_y) |up| {
                        const coincident = (!sliding or (c.normal.dot(self.up) >= up and b.normal.dot(self.up) >= up)) and b.body.eql(entry.id) and @abs(c.fraction - b.fraction) * displacement.length() <= narrow.cast_tolerance and
                            c.point.sub(b.point).lengthSquared() <= narrow.cast_tolerance * narrow.cast_tolerance;
                        if (coincident and b.surface_normal.dot(self.up) >= up and face.dot(self.up) < up) continue;
                        if (!(coincident and b.surface_normal.dot(self.up) < up and face.dot(self.up) >= up) and !(c.fraction < b.fraction)) continue;
                    } else if (!(c.fraction < b.fraction)) continue;
                }
                best = .{
                    .fraction = c.fraction,
                    .point = c.point,
                    .normal = c.normal,
                    .surface_normal = face,
                    .body = entry.id,
                    .user = entry.value.user,
                    .triangle = other.triangle,
                    .surface = other.surface,
                    .started_inside = c.started_inside,
                };
            }
        }
        return best;
    }

    const Part = struct {
        convex: Convex,
        triangle: u32 = none_triangle,
        /// The triangle's surface, or its body's.
        surface: core.ContentId = .none,
        one_sided: bool = false,

        /// Whether a shape whose origin is at `centre`, moving by `motion`, may meet this part
        /// (`collision-extras.md` §6). A one-sided triangle is met from its front alone: not by a
        /// shape whose centre is behind its plane, nor by one moving out through its back. A
        /// query that does not move passes zero.
        fn admits(self: Part, centre: Vec3, motion: Vec3) bool {
            if (!self.one_sided) return true;
            const facing = self.front();
            if (centre.sub(self.convex.pose.apply(self.convex.core.triangle[0])).dot(facing) < 0) return false;
            return motion.dot(facing) <= 0;
        }

        /// A triangle's front, the way its counter-clockwise winding faces, after scale and pose.
        /// Not unit.
        fn front(self: Part) Vec3 {
            const pts = self.convex.core.triangle;
            return self.convex.pose.applyDirection(Vec3.cross(pts[1].sub(pts[0]), pts[2].sub(pts[0])));
        }

        /// How `query` and this part overlap. **A one-sided triangle is left by its front:** the
        /// normal is its front, and the depth how far the query's deepest point is behind its
        /// plane. The shortest way out of a thin face may be through its back, and a capsule
        /// half through a one-way ledge would then be pushed back down as often as up.
        fn separation(self: Part, query: Convex) narrow.Separation {
            const s = narrow.separation(query, self.convex);
            if (!self.one_sided or s.distance >= 0) return s;
            const n = self.front().normalize();
            const deepest = query.support(n.scale(-1)).sub(n.scale(query.radius));
            const depth = self.convex.pose.apply(self.convex.core.triangle[0]).sub(deepest).dot(n);
            var out = s;
            out.distance = -@max(depth, 0);
            out.normal = n;
            out.point_a = deepest;
            out.point_b = deepest.add(n.scale(@max(depth, 0)));
            return out;
        }
    };
    const Candidates = struct {
        convex: ?Convex = null,
        mesh: ?*const mesh_mod.Mesh = null,
        pose: Pose = .identity,
        scale: Vec3 = .one,
        surface: core.ContentId = .none,
        triangles: []const u32 = &.{},
        cursor: usize = 0,

        fn next(self: *Candidates) ?Part {
            if (self.convex) |c| {
                self.convex = null;
                return .{ .convex = c, .surface = self.surface };
            }
            if (self.cursor == self.triangles.len) return null;
            const t = self.triangles[self.cursor];
            self.cursor += 1;
            // Scaled before the pose, so a scaled triangle's normal is the one a person sees.
            var pts = self.mesh.?.triangle(t);
            for (&pts) |*p| p.* = p.mul(self.scale);
            const own = self.mesh.?.surfaceOf(t);
            return .{
                .convex = .{ .core = .{ .triangle = pts }, .radius = 0, .pose = self.pose },
                .triangle = t,
                .surface = if (own.isNone()) self.surface else own,
                .one_sided = self.mesh.?.oneSided(t),
            };
        }
    };

    fn candidate(self: *World, id: BodyHandle, b: Body, area: Aabb, filter: Filter) ?Candidates {
        if (filter.ignore) |ignored| if (ignored.eql(id)) return null;
        if (!body_mod.maskAdmits(filter.mask, b)) return null;
        self.counters.bodies_tested +%= 1;
        if (!self.bodyBounds(b).expand(0.002).overlaps(area)) return null;
        if (b.shape == .mesh) {
            const m = self.meshes.get(b.shape.mesh).?;
            return .{ .mesh = m, .pose = b.pose, .scale = b.scale, .surface = b.surface, .triangles = m.candidates(b.pose, b.scale, area, self.triangle_scratch) };
        }
        var c = self.convexOf(b.shape, b.pose);
        c.scale = b.scale;
        return .{ .convex = c, .surface = b.surface };
    }

    fn bodyBounds(self: *World, b: Body) Aabb {
        if (b.shape == .mesh) {
            const c: Convex = .{ .core = .point, .radius = 0, .pose = b.pose };
            const local = self.meshes.get(b.shape.mesh).?.nodes[0].bounds;
            return c.poseBounds(.{ .min = local.min.mul(b.scale), .max = local.max.mul(b.scale) });
        }
        var c = self.convexOf(b.shape, b.pose);
        c.scale = b.scale;
        return c.bounds();
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

/// The farthest a convex shape reaches from its pose's origin, its radius included.
fn reachOf(c: Convex) f32 {
    const core_reach: f32 = switch (c.core) {
        .point => 0,
        .segment => |h| h,
        .box => |he| he.length(),
        .points => |pts| blk: {
            var r: f32 = 0;
            for (pts) |p| r = @max(r, p.mul(c.scale).length());
            break :blk r;
        },
        .triangle => |pts| @max(pts[0].length(), @max(pts[1].length(), pts[2].length())),
    };
    return core_reach + c.radius;
}

/// The shortest rotation taking +Y to unit `to`, by the half-way quaternion: no trigonometry, so
/// no pin depends on a linked libm. Straight down is a half turn about +X.
pub fn rotationTo(to: Vec3) core.math.Quat {
    const from = Vec3.up;
    const d = from.dot(to);
    if (d < -1 + 1e-6) return .{ .x = 1, .y = 0, .z = 0, .w = 0 };
    const c = from.cross(to);
    const q: core.math.Quat = .{ .x = c.x, .y = c.y, .z = c.z, .w = 1 + d };
    return q.normalize();
}
