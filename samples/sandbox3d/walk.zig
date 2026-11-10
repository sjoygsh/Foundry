//! Host-owned simulation, collision residency and first-person camera. No RHI or ECS coupling.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const physics = @import("physics3d");
const platform = @import("platform");
pub const Settings = @import("walk_settings.zig").Settings;
const Vec3 = core.math.Vec3;
const log = core.log.scoped(.sandbox3d);

pub const Intent = struct { direction: Vec3 = .zero, turn: f32 = 0, pitch: f32 = 0, jump: bool = false };

/// Read immutable frame input once. Mouse delta is consumed once per frame, never once per tick.
pub fn inputIntent(input: platform.InputSnapshot, typing: bool) Intent {
    if (typing) return .{};
    const x: f32 = @as(f32, if (input.isHeld(.d)) 1 else 0) - @as(f32, if (input.isHeld(.a)) 1 else 0);
    const z: f32 = @as(f32, if (input.isHeld(.s)) 1 else 0) - @as(f32, if (input.isHeld(.w)) 1 else 0);
    var direction: Vec3 = .init(x, 0, z);
    if (direction.lengthSquared() > 1) direction = direction.normalize();
    return .{
        .direction = direction,
        .turn = @as(f32, if (input.isHeld(.left)) 1 else 0) - @as(f32, if (input.isHeld(.right)) 1 else 0),
        .pitch = @as(f32, if (input.isHeld(.up)) 1 else 0) - @as(f32, if (input.isHeld(.down)) 1 else 0),
        .jump = input.isHeld(.space),
    };
}

/// A collision mesh copied into `world` with its surfaces and one-sided faces (`.fcol` v2),
/// each position turned by `frame`: the consumer's half of `collision-extras.md` §9, since
/// `asset` cannot see `physics3d`. Its scratch is freed before it returns.
pub fn addCollisionMesh(gpa: std.mem.Allocator, world: *physics.World, geometry: *const asset.CollisionMesh, frame: core.math.Quat) !physics.MeshHandle {
    const triangles = geometry.indices.len / 3;
    const surfaces = try gpa.alloc(u16, if (geometry.triangle_attributes.len == 0) 0 else triangles);
    defer gpa.free(surfaces);
    const one_sided = try gpa.alloc(bool, surfaces.len);
    defer gpa.free(one_sided);
    for (geometry.triangle_attributes, surfaces, one_sided) |attribute, *surface, *side| {
        surface.* = asset.collision_mesh.surfaceIndex(attribute) orelse physics.mesh.no_surface;
        side.* = asset.collision_mesh.oneSided(attribute);
    }
    var attributes: physics.mesh.Attributes = .{ .surfaces = geometry.surfaces, .triangle_surfaces = surfaces, .one_sided = one_sided };
    if (upright(frame)) {
        // A baked tree (`.fcol` v3, `collision-scale.md` §7), in `physics3d`'s layout: the file
        // keeps one link a node, and an inner node's left child is the node after it. Only
        // upright, since turning the positions would leave its boxes behind.
        const baked = geometry.tree() orelse return world.addMeshWith(gpa, geometry.positions, geometry.indices, attributes);
        const nodes = try gpa.alloc(physics.mesh.Node, baked.nodes.len);
        defer gpa.free(nodes);
        for (baked.nodes, nodes, 0..) |node, *out, i| {
            out.* = .{ .bounds = .{ .min = node.min, .max = node.max } };
            if (node.leaf()) {
                out.first = node.link;
                out.count = node.count;
            } else {
                out.left = @intCast(i + 1);
                out.right = node.link;
            }
        }
        attributes.tree = .{ .nodes = nodes, .order = baked.order };
        return world.addMeshWith(gpa, geometry.positions, geometry.indices, attributes);
    }
    const turned = try gpa.alloc(Vec3, geometry.positions.len);
    defer gpa.free(turned);
    for (geometry.positions, turned) |p, *t| t.* = frame.rotate(p);
    return world.addMeshWith(gpa, turned, geometry.indices, attributes);
}

pub const Walk = struct {
    gpa: std.mem.Allocator,
    world: physics.World = .{},
    settings: ?Settings = null,
    character: physics.CharacterHandle = .none,
    result: physics.CharacterMove = .{ .feet = .zero },
    yaw: f32 = 0,
    pitch: f32 = 0,
    velocity: f32 = 0,
    orbit: bool = true,
    /// The tilted tour's turn (`collision-extras.md` §11): the walk world's geometry and `up`
    /// are this frame's, and `result`, `teleport` and every intent are in the upright frame, so a
    /// tour reads the same in both. Identity for every ordinary walk.
    frame: core.math.Quat = .identity,
    collisions: [Settings.max_collision]Resident = @splat(.{}),
    const Resident = struct { handle: asset.AssetHandle = .none, mesh: physics.MeshHandle = .none, body: physics.BodyHandle = .none };

    pub fn init(gpa: std.mem.Allocator) Walk {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Walk, assets: *asset.Registry) void {
        self.clearCollision(assets);
        self.world.deinit(self.gpa);
    }
    fn clearCollision(self: *Walk, assets: *asset.Registry) void {
        for (&self.collisions) |*r| {
            if (!r.body.isNone()) _ = self.world.removeBody(self.gpa, r.body);
            if (!r.mesh.isNone()) _ = self.world.removeMesh(self.gpa, r.mesh) catch unreachable; // Body retired above.
            if (!r.handle.isNone()) assets.release(r.handle);
            r.* = .{};
        }
    }

    /// Called at the same content-generation seam as the visual model follower. No borrowed
    /// asset arrays survive this call; a failed/missing source leaves its geometry out.
    pub fn refresh(self: *Walk, store: *const data.Store, assets: *asset.Registry, dt: f32) void {
        const record = store.lookup(core.ContentId.fromString("sandbox3d:walk.main"));
        const fresh: ?Settings = if (record) |r| Settings.read(r.fields, dt) catch null else null;
        const changed = !std.meta.eql(self.settings, fresh);
        self.clearCollision(assets);
        self.settings = fresh;
        if (changed) {
            if (!self.character.isNone()) _ = self.world.removeCharacter(self.gpa, self.character);
            self.character = .none;
        }
        const config = fresh orelse {
            self.orbit = true;
            log.warn("invalid/missing 'sandbox3d:walk.main'; walking disabled, orbit camera", .{});
            return;
        };
        for (config.collision[0..config.len], 0..) |id, n| {
            self.collisions[n] = self.loadCollision(store, assets, id) catch |err| blk: {
                log.warn("collision {f} omitted ({t})", .{ id, err });
                break :blk .{};
            };
        }
        if (self.character.isNone()) {
            var player = config.character;
            player.mask &= ~@as(u32, 2); // M24 walkers use layer 2; never affect the player's tour.
            if (!upright(self.frame)) self.world.setUp(self.frame.rotate(.up)) catch |err| log.warn("the tilted walk keeps its up ({t})", .{err});
            self.character = self.world.addCharacter(self.gpa, player, config.spawn, 0) catch |err| {
                log.warn("walk disabled ({t}); orbit camera", .{err});
                self.orbit = true;
                return;
            };
            self.result = .{ .feet = config.spawn };
            self.yaw = config.spawn_yaw;
            self.pitch = 0;
            self.velocity = 0;
            self.orbit = config.orbit;
        }
    }
    fn loadCollision(self: *Walk, store: *const data.Store, assets: *asset.Registry, id: core.ContentId) !Resident {
        const record = store.lookup(id) orelse return error.MissingRecord;
        if (!record.schema.id.eql(asset.schemas.collision_mesh.id)) return error.WrongKind;
        const handle = try assets.acquire(self.gpa, id);
        errdefer assets.release(handle);
        const product = assets.getIfLoader(handle, asset.collisionMeshLoader()) orelse return error.WrongLoader;
        const geometry = asset.collision_mesh.fromPayload(product.payload);
        const mesh = try addCollisionMesh(self.gpa, &self.world, geometry, self.frame);
        errdefer _ = self.world.removeMesh(self.gpa, mesh) catch unreachable;
        const body = try self.world.addBody(self.gpa, .{ .shape = .{ .mesh = mesh }, .user = id.hash });
        return .{ .handle = handle, .mesh = mesh, .body = body };
    }
    pub fn teleport(self: *Walk, feet: Vec3) !void {
        if (!try self.world.setCharacterFeet(self.gpa, self.character, self.frame.rotate(feet))) return error.NoCharacter;
        self.result = .{ .feet = feet };
        self.velocity = 0;
    }
    pub fn look(self: *Walk, dx: f32, dy: f32) void {
        const c = self.settings orelse return;
        self.yaw = @mod(self.yaw - dx * c.look_rate, 2 * std.math.pi);
        self.pitch = clampPitch(self.pitch - dy * c.look_rate);
    }
    pub fn rotation(self: *const Walk) core.math.Quat {
        return core.math.Quat.fromAxisAngle(.up, self.yaw).mul(core.math.Quat.fromAxisAngle(.right, self.pitch));
    }
    /// What the feet stand on, by its content ID, or `.none` in the air or on unnamed ground.
    pub fn surface(self: *const Walk) core.ContentId {
        return if (self.result.ground) |g| g.surface else .none;
    }
    pub fn eye(self: *const Walk) Vec3 {
        return self.result.feet.add(.init(0, if (self.settings) |s| s.eye_height else 0, 0));
    }
    /// One fixed tick; clocks and input devices never enter it. Gravity is sample policy.
    pub fn step(self: *Walk, intent: Intent, dt: f32) !void {
        const c = self.settings orelse return;
        if (self.character.isNone()) return;
        self.yaw = @mod(self.yaw + intent.turn * c.turn_rate * dt, 2 * std.math.pi);
        self.pitch = clampPitch(self.pitch + intent.pitch * c.turn_rate * dt);
        const horizontal = core.math.Quat.fromAxisAngle(.up, self.yaw).rotate(intent.direction).scale(c.walk_speed * dt);
        if (intent.jump and self.result.grounded and c.jump_speed > 0) self.velocity = c.jump_speed;
        self.velocity -= c.gravity * dt;
        // Preserve horizontal speed while clamping the fall so the full displacement stays
        // within the configured length (not an independent per-axis clamp).
        const vertical_limit = @sqrt(@max(0, c.character.max_move * c.character.max_move - horizontal.lengthSquared()));
        const by = horizontal.add(.init(0, @max(-vertical_limit, self.velocity * dt), 0));
        var moved = (try self.world.moveCharacter(self.gpa, self.character, self.frame.rotate(by), &.{})) orelse return error.NoCharacter;
        const back = self.frame.conjugate();
        moved.feet = back.rotate(moved.feet);
        moved.carried = back.rotate(moved.carried);
        self.result = moved;
        // A turntable turns the view with the feet.
        self.yaw = @mod(self.yaw + moved.carried_yaw, 2 * std.math.pi);
        if (self.result.grounded or (self.result.ceiling and self.velocity > 0)) self.velocity = 0;
        if (self.result.feet.y < -10) {
            log.warn("walk fell below -10 m; respawning", .{});
            try self.teleport(c.spawn);
        }
    }
};

fn upright(frame: core.math.Quat) bool {
    return frame.x == 0 and frame.y == 0 and frame.z == 0;
}

fn clampPitch(pitch: f32) f32 {
    return std.math.clamp(pitch, -85 * std.math.pi / 180.0, 85 * std.math.pi / 180.0);
}

test "walk input ignores typing, normalizes diagonals and consumes bounded look" {
    var input: platform.InputSnapshot = .{};
    platform.key.setKey(&input.keys_held, .w, true);
    platform.key.setKey(&input.keys_held, .d, true);
    platform.key.setKey(&input.keys_held, .up, true);
    try std.testing.expectEqualDeep(Intent{}, inputIntent(input, true));
    try std.testing.expectApproxEqAbs(@as(f32, 1), inputIntent(input, false).direction.length(), 1e-6);
    try std.testing.expectEqual(@as(f32, 1), inputIntent(input, false).pitch);
    try std.testing.expectApproxEqAbs(@as(f32, 85 * std.math.pi / 180.0), clampPitch(10), 1e-6);
}
