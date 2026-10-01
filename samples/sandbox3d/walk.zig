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

pub const Intent = struct { direction: Vec3 = .zero, turn: f32 = 0, pitch: f32 = 0 };

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
    };
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
        const mesh = try self.world.addMesh(self.gpa, geometry.positions, geometry.indices);
        errdefer _ = self.world.removeMesh(self.gpa, mesh) catch unreachable;
        const body = try self.world.addBody(self.gpa, .{ .shape = .{ .mesh = mesh }, .user = id.hash });
        return .{ .handle = handle, .mesh = mesh, .body = body };
    }
    pub fn teleport(self: *Walk, feet: Vec3) !void {
        if (!try self.world.setCharacterFeet(self.gpa, self.character, feet)) return error.NoCharacter;
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
        self.velocity -= c.gravity * dt;
        // Preserve horizontal speed while clamping the fall so the full displacement stays
        // within the configured length (not an independent per-axis clamp).
        const vertical_limit = @sqrt(@max(0, c.character.max_move * c.character.max_move - horizontal.lengthSquared()));
        const by = horizontal.add(.init(0, @max(-vertical_limit, self.velocity * dt), 0));
        self.result = (try self.world.moveCharacter(self.gpa, self.character, by, &.{})) orelse return error.NoCharacter;
        if (self.result.grounded or (self.result.ceiling and self.velocity > 0)) self.velocity = 0;
        if (self.result.feet.y < -10) {
            log.warn("walk fell below -10 m; respawning", .{});
            try self.teleport(c.spawn);
        }
    }
};

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
