//! M37's corner (`docs/design/collision-extras.md` §11): a lift, a turntable, a crate, a door and
//! a rock beside the ground `models/corner.gltf` gives the walk world, west of the room at `origin`
//! and away from every tour path, so none of them moves an older pin.
//!
//! The moving pieces are bodies this module makes in the walk world and moves each tick before
//! the player, in §13's order: the lift and the turntable by `moveBody`, the door by `shapeSweep`
//! and then `moveBody`, stopping where the sweep is stopped. The crate is moved by nothing but
//! the player's push. The rock is a static body of its model's collision, its proxy, at a scale.
//! The ledge is the corner model's, in the walk's own list. None is a navigation source or a prop.
//!
//! Every pose is turned by `frame`, the walk's, so the tilted tour moves the same corner turned.
//! The places here repeat `scripts/m37/make_corner.py`'s.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const physics = @import("physics3d");
const render3d = @import("render3d");
const walk_mod = @import("walk.zig");
const Vec3 = core.math.Vec3;
const Quat = core.math.Quat;
const Mat4 = core.math.Mat4;
const Pose = physics.Pose;
const log = core.log.scoped(.sandbox3d);

pub const record_id = core.ContentId.fromString("sandbox3d:extras.main");

/// The corner's centre, past the room's west wall and the crate grid.
pub const origin: Vec3 = .init(-20, 0, 0);

/// The lift: a slab whose top rises from `lift_low` to the platform's height, `lift_high`.
pub const lift_centre: Vec3 = origin.add(.init(-2.5, 0, -2.5));
pub const lift_half: Vec3 = .init(0.5, 0.05, 0.5);
pub const lift_low: f32 = 0.1;
pub const lift_high: f32 = 1.0;
const lift_wait: u32 = 60;
const lift_travel: u32 = 90;

/// The turntable: a sixteen-sided disc a metre across its radius, a quarter-turn a second.
pub const table_centre: Vec3 = origin.add(.init(2.5, 0.05, -2.5));
pub const table_radius: f32 = 1.0;
pub const table_half: f32 = 0.05;
const table_sides = 16;
pub const table_rate: f32 = std.math.pi / 2.0;

/// The crate: pushed at half the pusher's pace, toward the metal wall whose face is at `wall_x`.
pub const crate_start: Vec3 = origin.add(.init(-2.2, 0.301, 2.0));
pub const crate_half: Vec3 = .init(0.3, 0.3, 0.3);
pub const crate_push: f32 = 0.5;
pub const wall_x: f32 = origin.x - 3.2;

/// The door: a leaf hinged at its edge, swung between open (a quarter-turn, along −Z from the
/// hinge) and shut (along +X), a quarter-turn a second. Its foot clears the floor.
pub const hinge: Vec3 = origin.add(.init(1.5, 1.05, 2.0));
pub const door_half: Vec3 = .init(0.6, 0.95, 0.05);
pub const door_open: f32 = std.math.pi / 2.0;
const door_rate: f32 = std.math.pi / 2.0;
const door_phase: u32 = 120;

/// The one-sided ledge's top, a model triangle pair the walk world already holds.
pub const ledge_centre: Vec3 = origin.add(.init(0, 1.2, -2.5));

const dt: f32 = 1.0 / 60.0;

pub const Settings = struct {
    box_model: core.ContentId,
    disc_model: core.ContentId,
    rock: core.ContentId,
    rock_position: Vec3,
    rock_scale: f32,
    lift_surface: core.ContentId,
    table_surface: core.ContentId,
    crate_surface: core.ContentId,
    door_surface: core.ContentId,

    pub fn read(fields: data.fpk.Fields) !Settings {
        const at = (try fields.nestedAt(try index(fields, "rock_position"))) orelse return error.InvalidExtras;
        const out: Settings = .{
            .box_model = try id(fields, "box_model"),
            .disc_model = try id(fields, "disc_model"),
            .rock = try id(fields, "rock"),
            .rock_position = .init(try number(at, "x"), try number(at, "y"), try number(at, "z")),
            .rock_scale = try number(fields, "rock_scale"),
            .lift_surface = try id(fields, "lift_surface"),
            .table_surface = try id(fields, "turntable_surface"),
            .crate_surface = try id(fields, "crate_surface"),
            .door_surface = try id(fields, "door_surface"),
        };
        if (!physics.shape.positionValid(out.rock_position) or !(out.rock_scale >= physics.body.min_scale and out.rock_scale <= physics.body.max_scale))
            return error.InvalidExtras;
        return out;
    }
};

fn index(fields: data.fpk.Fields, name: []const u8) !u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidExtras;
}
fn number(fields: data.fpk.Fields, name: []const u8) !f32 {
    const value: f32 = @floatCast((try fields.floatAt(try index(fields, name))) orelse return error.InvalidExtras);
    if (!std.math.isFinite(value)) return error.InvalidExtras;
    return value;
}
fn id(fields: data.fpk.Fields, name: []const u8) !core.ContentId {
    const value = (try fields.idAt(try index(fields, name))) orelse return error.InvalidExtras;
    if (value.isNone()) return error.InvalidExtras;
    return value;
}

/// A surface record's `name`, for the overlay and the log, or "none".
pub fn surfaceName(store: *const data.Store, surface: core.ContentId) []const u8 {
    if (surface.isNone()) return "none";
    const record = store.lookup(surface) orelse return "unknown";
    const at = record.schema.fieldIndex("name") orelse return "unknown";
    return (record.fields.stringAt(at) catch null) orelse "unknown";
}

pub const Extras = struct {
    settings: ?Settings = null,
    /// The walk's frame: identity, or the tilted tour's turn.
    frame: Quat = .identity,
    /// The corner's own clock, in ticks, which the tour sets back to begin a stage.
    tick: u32 = 0,
    lift: physics.BodyHandle = .none,
    table: physics.BodyHandle = .none,
    table_hull: physics.HullHandle = .none,
    crate: physics.BodyHandle = .none,
    door: physics.BodyHandle = .none,
    /// The door's turn from shut, radians, and the last sweep that stopped it.
    door_angle: f32 = door_open,
    door_stop: ?physics.Hit = null,
    /// What the door's last sweep cost, when `step` was given a clock. Measurement only.
    sweep_ns: ?i64 = null,
    rock: physics.BodyHandle = .none,
    rock_mesh: physics.MeshHandle = .none,
    rock_asset: asset.AssetHandle = .none,
    rock_triangles: usize = 0,
    /// What draws them, when there is a renderer.
    box_model: render3d.ModelHandle = .none,
    disc_model: render3d.ModelHandle = .none,
    rock_model: render3d.ModelHandle = .none,
    reported: bool = false,

    pub fn deinit(self: *Extras, gpa: std.mem.Allocator, world: *physics.World, assets: *asset.Registry, content: ?*render3d.Content) void {
        for ([_]physics.BodyHandle{ self.lift, self.table, self.crate, self.door, self.rock }) |b| {
            if (!b.isNone()) _ = world.removeBody(gpa, b);
        }
        if (!self.table_hull.isNone()) _ = world.removeHull(gpa, self.table_hull) catch unreachable; // Its body went above.
        if (!self.rock_mesh.isNone()) _ = world.removeMesh(gpa, self.rock_mesh) catch unreachable; // So did the rock's.
        if (!self.rock_asset.isNone()) assets.release(self.rock_asset);
        if (content) |c| for ([_]render3d.ModelHandle{ self.box_model, self.disc_model, self.rock_model }) |m| {
            if (!m.isNone()) c.releaseModel(m);
        };
        const frame = self.frame;
        self.* = .{ .frame = frame };
    }

    /// Made again at every content refresh, from `sandbox3d:extras.main`; without the record, or
    /// with one that will not do, there is no corner, and nothing else changes.
    pub fn refresh(self: *Extras, gpa: std.mem.Allocator, store: *const data.Store, world: *physics.World, assets: *asset.Registry, content: ?*render3d.Content) void {
        self.deinit(gpa, world, assets, content);
        const record = store.lookup(record_id) orelse return;
        const settings = Settings.read(record.fields) catch |err| {
            log.warn("the M37 corner is left out ({t})", .{err});
            return;
        };
        self.build(gpa, store, world, assets, settings) catch |err| {
            log.warn("the M37 corner is left out ({t})", .{err});
            self.deinit(gpa, world, assets, content);
            return;
        };
        self.settings = settings;
        if (content) |c| {
            self.box_model = acquire(c, settings.box_model);
            self.disc_model = acquire(c, settings.disc_model);
            self.rock_model = acquire(c, settings.rock);
        }
    }

    fn acquire(content: *render3d.Content, model: core.ContentId) render3d.ModelHandle {
        return content.acquireModel(model) catch |err| blk: {
            log.warn("model {f} is not drawn ({t})", .{ model, err });
            break :blk .none;
        };
    }

    fn build(self: *Extras, gpa: std.mem.Allocator, store: *const data.Store, world: *physics.World, assets: *asset.Registry, s: Settings) !void {
        self.lift = try world.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = lift_half } }, .pose = self.place(liftPose(0)), .kind = .kinematic, .surface = s.lift_surface });
        var rim: [2 * table_sides]Vec3 = undefined;
        for (0..table_sides) |k| {
            const a = 2 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, table_sides);
            rim[2 * k] = .init(table_radius * @cos(a), table_half, -table_radius * @sin(a));
            rim[2 * k + 1] = .init(table_radius * @cos(a), -table_half, -table_radius * @sin(a));
        }
        self.table_hull = try world.addHull(gpa, &rim);
        self.table = try world.addBody(gpa, .{ .shape = .{ .hull = self.table_hull }, .pose = self.place(tablePose(0)), .kind = .kinematic, .surface = s.table_surface });
        self.crate = try world.addBody(gpa, .{ .shape = .{ .box = .{ .half_extents = crate_half } }, .pose = self.place(.at(crate_start)), .kind = .kinematic, .push = crate_push, .surface = s.crate_surface });
        self.door = try world.addBody(gpa, .{ .shape = doorShape(), .pose = self.place(doorPose(door_open)), .kind = .kinematic, .surface = s.door_surface });
        // The rock collides as whatever its model names (`foundry:model` v3's `collision`).
        const model = store.lookup(s.rock) orelse return error.MissingRock;
        const at = model.schema.fieldIndex("collision") orelse return error.RockNamesNoCollision;
        const collision = (try model.fields.idAt(at)) orelse return error.RockNamesNoCollision;
        const kind = store.lookup(collision) orelse return error.MissingRockCollision;
        if (!kind.schema.id.eql(asset.schemas.collision_mesh.id)) return error.WrongKind;
        self.rock_asset = try assets.acquire(gpa, collision);
        const product = assets.getIfLoader(self.rock_asset, asset.collisionMeshLoader()) orelse return error.WrongLoader;
        const geometry = asset.collision_mesh.fromPayload(product.payload);
        self.rock_triangles = geometry.indices.len / 3;
        self.rock_mesh = try walk_mod.addCollisionMesh(gpa, world, geometry, .identity);
        const scale = s.rock_scale;
        self.rock = try world.addBody(gpa, .{ .shape = .{ .mesh = self.rock_mesh }, .pose = self.place(.at(s.rock_position)), .scale = .init(scale, scale, scale), .user = s.rock.hash });
        self.tick = 0;
        self.door_angle = door_open;
    }

    /// The corner's start, as the tour begins each stage: the lift down, the table unturned, the
    /// crate where it was put, the door open, and the clock at `tick`. `setPose` carries nobody.
    pub fn reset(self: *Extras, gpa: std.mem.Allocator, world: *physics.World, tick: u32) !void {
        if (self.settings == null) return error.NoCorner;
        self.tick = tick;
        self.door_angle = door_open;
        self.door_stop = null;
        _ = try world.setPose(gpa, self.lift, self.place(liftPose(tick)));
        _ = try world.setPose(gpa, self.table, self.place(tablePose(tick)));
        _ = try world.setPose(gpa, self.crate, self.place(.at(crate_start)));
        _ = try world.setPose(gpa, self.door, self.place(doorPose(door_open)));
    }

    /// §13's first step: the kinematic bodies, before any character moves. `clock`, null or
    /// anything with `monotonicNanos`, times the door's sweep and nothing else.
    pub fn step(self: *Extras, gpa: std.mem.Allocator, world: *physics.World, clock: anytype) !void {
        self.sweep_ns = null;
        if (self.settings == null) return;
        self.tick +%= 1;
        var crushed: [4]physics.CharacterHandle = undefined;
        _ = try world.moveBody(gpa, self.lift, self.place(liftPose(self.tick)), &crushed);
        _ = try world.moveBody(gpa, self.table, self.place(tablePose(self.tick)), &crushed);
        // The door goes shut for half its phase and open for the other half, at its rate, and
        // stops where its sweep is stopped: by the player, most often.
        const goal: f32 = if (self.tick % (2 * door_phase) < door_phase) 0 else door_open;
        const limit = door_rate * dt;
        const target = self.door_angle + std.math.clamp(goal - self.door_angle, -limit, limit);
        if (target == self.door_angle) return;
        const from = world.body(self.door).?.pose;
        const to = self.place(doorPose(target));
        const started = if (@TypeOf(clock) == @TypeOf(null)) 0 else clock.monotonicNanos(); // Measurement only.
        self.door_stop = try world.shapeSweep(doorShape(), from, to, .{ .ignore = self.door });
        if (@TypeOf(clock) != @TypeOf(null)) self.sweep_ns = @intCast(clock.monotonicNanos() - started);
        if (self.door_stop) |hit| {
            const f = hit.fraction;
            self.door_angle += (target - self.door_angle) * f;
            _ = try world.moveBody(gpa, self.door, .{ .position = from.position.lerp(to.position, f), .rotation = from.rotation.slerp(to.rotation, f) }, &crushed);
        } else {
            self.door_angle = target;
            _ = try world.moveBody(gpa, self.door, to, &crushed);
        }
    }

    /// A pose in the upright frame, turned into the walk world's.
    pub fn place(self: *const Extras, pose: Pose) Pose {
        return .{ .position = self.frame.rotate(pose.position), .rotation = self.frame.mul(pose.rotation) };
    }
    /// Where a body is, in the upright frame.
    pub fn local(self: *const Extras, world: *physics.World, body: physics.BodyHandle) Pose {
        const pose = world.body(body).?.pose;
        const back = self.frame.conjugate();
        return .{ .position = back.rotate(pose.position), .rotation = back.mul(pose.rotation) };
    }

    pub fn draw(self: *Extras, world: *physics.World, content: *render3d.Content) void {
        if (self.settings == null) return;
        // The box model is the crate's: 0.8 m a side, standing on its origin.
        for ([_]physics.BodyHandle{ self.lift, self.crate, self.door }, [_]Vec3{ lift_half, crate_half, door_half }) |b, half| {
            const pose = world.body(b).?.pose;
            const foot = pose.position.add(pose.rotation.rotate(.init(0, -half.y, 0)));
            self.drawOne(content, self.box_model, Mat4.trs(foot, pose.rotation, half.scale(1.0 / 0.4)));
        }
        const table = world.body(self.table).?.pose;
        self.drawOne(content, self.disc_model, Mat4.trs(table.position, table.rotation, .one));
        const rock = world.body(self.rock).?;
        self.drawOne(content, self.rock_model, Mat4.trs(rock.pose.position, rock.pose.rotation, rock.scale));
    }
    fn drawOne(self: *Extras, content: *render3d.Content, model: render3d.ModelHandle, matrix: Mat4) void {
        if (model.isNone()) return;
        content.drawModel(.{ .model = model, .world = matrix }) catch |err| {
            if (!self.reported) log.warn("an M37 corner piece is not drawn ({t})", .{err});
            self.reported = true;
        };
    }
};

pub fn doorShape() physics.Shape {
    return .{ .box = .{ .half_extents = door_half } };
}

/// Where the lift is at `tick`: down for a second, up over a second and a half, up for a
/// second, and down again, every five seconds.
pub fn liftPose(tick: u32) Pose {
    const t = tick % (2 * (lift_wait + lift_travel));
    const rise: f32 = if (t < lift_wait)
        0
    else if (t < lift_wait + lift_travel)
        @as(f32, @floatFromInt(t - lift_wait)) / lift_travel
    else if (t < 2 * lift_wait + lift_travel)
        1
    else
        1 - @as(f32, @floatFromInt(t - 2 * lift_wait - lift_travel)) / lift_travel;
    const top = lift_low + (lift_high - lift_low) * rise;
    return .at(.init(lift_centre.x, top - lift_half.y, lift_centre.z));
}

/// The turntable's turn at `tick`, about the world's up, a quarter-turn a second, counted in
/// whole turns so the angle stays small.
pub fn tablePose(tick: u32) Pose {
    const ticks_a_turn: u32 = 240;
    const angle = table_rate * @as(f32, @floatFromInt(tick % ticks_a_turn)) * dt;
    return .{ .position = table_centre, .rotation = Quat.fromAxisAngle(.up, angle) };
}

/// The door turned `angle` from shut, about its hinge.
pub fn doorPose(angle: f32) Pose {
    const turn = Quat.fromAxisAngle(.up, angle);
    return .{ .position = hinge.add(turn.rotate(.init(door_half.x, 0, 0))), .rotation = turn };
}
