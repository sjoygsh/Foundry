//! Host-owned simulation, collision residency and first-person camera. No RHI or ECS coupling.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const physics = @import("physics3d");
const input = @import("input");
pub const Settings = @import("walk_settings.zig").Settings;
const Vec3 = core.math.Vec3;
const log = core.log.scoped(.court);

/// What a menu asks of the game. A phase changes only inside a tick, from that tick's
/// `Intent` (playable3d.md §5.2), so a menu's choice travels here like any other input.
pub const Action = enum { none, play, pause, unpause, restart, title };

pub const Intent = struct {
    direction: Vec3 = .zero,
    turn: f32 = 0,
    pitch: f32 = 0,
    jump: bool = false,
    use: bool = false,
    action: Action = .none,
    look_dx: f32 = 0,
    look_dy: f32 = 0,
    /// A navigation mesh to adopt before this tick, or 0 (`agents.md` §9). Recorded with the rest,
    /// which is how a mesh's arrival, a wall-clock fact, reaches simulation.
    navigation: u32 = 0,
};

/// What a frame chose that is not input: a menu's command and a mesh's arrival. Each reaches the
/// first tick after it, once; a frame with no tick keeps it for the next. Input's own edges and
/// motion are the engine's tick view's (`input.md` §7), which replaced M26's `Pending`.
pub const Owed = struct {
    intent: Intent = .{},
    pub fn feed(self: *Owed, chosen: Intent) void {
        if (chosen.action != .none) self.intent.action = chosen.action;
        if (chosen.navigation != 0) self.intent.navigation = chosen.navigation;
    }
    pub fn take(self: *Owed) Intent {
        const out = self.intent;
        self.intent = .{};
        return out;
    }
};

/// The court's actions (`content/input.fdt`), by content ID.
pub const actions = struct {
    pub const move = core.ContentId.fromString("court:action.walk.move");
    pub const jump = core.ContentId.fromString("court:action.walk.jump");
    pub const use = core.ContentId.fromString("court:action.walk.use");
    pub const look = core.ContentId.fromString("court:action.walk.look");
    pub const look_stick = core.ContentId.fromString("court:action.walk.look_stick");
    pub const pause = core.ContentId.fromString("court:action.walk.pause");
    pub const menu_up = core.ContentId.fromString("court:action.menu.up");
    pub const menu_down = core.ContentId.fromString("court:action.menu.down");
    pub const menu_left = core.ContentId.fromString("court:action.menu.left");
    pub const menu_right = core.ContentId.fromString("court:action.menu.right");
    pub const menu_accept = core.ContentId.fromString("court:action.menu.accept");
    pub const menu_back = core.ContentId.fromString("court:action.menu.back");
    pub const panels = core.ContentId.fromString("court:action.panels");
    pub const walk_context = core.ContentId.fromString("court:context.walk");
    pub const menu_context = core.ContentId.fromString("court:context.menu");
};

/// How a person's look is read: the player's options, and whether the pointer is captured.
pub const Look = struct {
    sensitivity: f32 = 1,
    invert: bool = false,
    /// An uncaptured pointer's motion is a cursor's, not a look.
    captured: bool = true,
};

/// One tick's intent from that tick's actions (`Step.actions`): edges and mouse motion arrive at
/// the first tick after they happened, levels at every tick. The arrows and the right stick turn
/// at the walk's turn rate and take no sensitivity, as M26's arrows did.
pub fn actionIntent(frame: *const input.Frame, look: Look) Intent {
    const move = frame.state(actions.move).value;
    const stick = frame.state(actions.look_stick).value;
    const motion = if (look.captured) frame.state(actions.look).value else core.math.Vec2.zero;
    return .{
        // +y is forward, which is -Z. The action is already clamped to length 1.
        .direction = .init(move.x, 0, -move.y),
        .jump = frame.state(actions.jump).pressed,
        .use = frame.state(actions.use).pressed,
        .look_dx = motion.x * look.sensitivity,
        .look_dy = motion.y * if (look.invert) -look.sensitivity else look.sensitivity,
        .turn = -stick.x,
        .pitch = if (look.invert) -stick.y else stick.y,
    };
}

/// A compiled collision mesh in `world`, with its surfaces and one-sided faces: the consumer's
/// half of `collision-extras.md` §9, since `asset` cannot see `physics3d`. A version 1 mesh has
/// no attributes, and adds as it always did.
pub fn addCollisionMesh(gpa: std.mem.Allocator, world: *physics.World, geometry: *const asset.CollisionMesh) !physics.MeshHandle {
    const triangles = geometry.indices.len / 3;
    const surfaces = try gpa.alloc(u16, if (geometry.triangle_attributes.len == 0) 0 else triangles);
    defer gpa.free(surfaces);
    const one_sided = try gpa.alloc(bool, surfaces.len);
    defer gpa.free(one_sided);
    for (geometry.triangle_attributes, surfaces, one_sided) |attribute, *surface, *side| {
        surface.* = asset.collision_mesh.surfaceIndex(attribute) orelse physics.mesh.no_surface;
        side.* = asset.collision_mesh.oneSided(attribute);
    }
    return world.addMeshWith(gpa, geometry.positions, geometry.indices, .{ .surfaces = geometry.surfaces, .triangle_surfaces = surfaces, .one_sided = one_sided });
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
        const record = store.lookup(core.ContentId.fromString("court:rules.main"));
        const fresh: ?Settings = if (record) |r| blk: {
            if (!r.schema.id.eql(data.SchemaId.fromStringUnchecked("court:rules"))) break :blk null;
            break :blk Settings.read(r.fields, dt) catch |err| {
                log.warn("'court:rules.main' refused ({t})", .{err});
                break :blk null;
            };
        } else null;
        const changed = !std.meta.eql(self.settings, fresh);
        self.clearCollision(assets);
        self.settings = fresh;
        if (changed) {
            if (!self.character.isNone()) _ = self.world.removeCharacter(self.gpa, self.character);
            self.character = .none;
        }
        const config = fresh orelse {
            log.warn("invalid/missing 'court:rules.main'; walking disabled", .{});
            return;
        };
        for (config.collision[0..config.len], 0..) |id, n| {
            self.collisions[n] = self.loadCollision(store, assets, id) catch |err| blk: {
                log.warn("collision {f} omitted ({t})", .{ id, err });
                break :blk .{};
            };
        }
        if (self.character.isNone()) {
            const player = config.character;
            // The court's player collides with level geometry; outcome logic is Step 3.
            self.character = self.world.addCharacter(self.gpa, player, config.spawn, 0) catch |err| {
                log.warn("walk disabled ({t})", .{err});
                return;
            };
            self.result = .{ .feet = config.spawn };
            self.yaw = config.spawn_yaw;
            self.pitch = 0;
            self.velocity = 0;
        }
    }
    fn loadCollision(self: *Walk, store: *const data.Store, assets: *asset.Registry, id: core.ContentId) !Resident {
        const record = store.lookup(id) orelse return error.MissingRecord;
        if (!record.schema.id.eql(asset.schemas.collision_mesh.id)) return error.WrongKind;
        const handle = try assets.acquire(self.gpa, id);
        errdefer assets.release(handle);
        const product = assets.getIfLoader(handle, asset.collisionMeshLoader()) orelse return error.WrongLoader;
        const geometry = asset.collision_mesh.fromPayload(product.payload);
        const mesh = try addCollisionMesh(self.gpa, &self.world, geometry);
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
    /// The surface of the ground underfoot, or none in the air or on ground that names none.
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
        self.look(intent.look_dx, intent.look_dy);
        self.yaw = @mod(self.yaw + intent.turn * c.turn_rate * dt, 2 * std.math.pi);
        self.pitch = clampPitch(self.pitch + intent.pitch * c.turn_rate * dt);
        const horizontal = core.math.Quat.fromAxisAngle(.up, self.yaw).rotate(intent.direction).scale(c.walk_speed * dt);
        if (intent.jump and self.result.grounded and self.velocity <= 0) self.velocity = c.jump_speed;
        self.velocity -= c.gravity * dt;
        // Preserve horizontal speed while clamping the fall so the full displacement stays
        // within the configured length (not an independent per-axis clamp).
        const vertical_limit = @sqrt(@max(0, c.character.max_move * c.character.max_move - horizontal.lengthSquared()));
        const by = horizontal.add(.init(0, std.math.clamp(self.velocity * dt, -vertical_limit, vertical_limit), 0));
        self.result = (try self.world.moveCharacter(self.gpa, self.character, by, &.{})) orelse return error.NoCharacter;
        // A rising capsule can briefly probe ground at the wall's lip. It is not a landing.
        if ((self.result.grounded and self.velocity <= 0) or (self.result.ceiling and self.velocity > 0)) self.velocity = 0;
    }
};

fn clampPitch(pitch: f32) f32 {
    return std.math.clamp(pitch, -85 * std.math.pi / 180.0, 85 * std.math.pi / 180.0);
}

test "walk: a frame with no court actions is a player at rest, and pitch is bounded" {
    // The court's actions over its real package are `controls_tests.zig`'s.
    const rest = actionIntent(&input.Frame.empty, .{ .sensitivity = 3, .invert = true });
    try std.testing.expect(!rest.jump and !rest.use and rest.look_dx == 0 and rest.look_dy == 0);
    try std.testing.expectEqual(@as(f32, 0), rest.direction.length());
    try std.testing.expectApproxEqAbs(@as(f32, 85 * std.math.pi / 180.0), clampPitch(10), 1e-6);
}
