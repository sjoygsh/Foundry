//! Sample-owned warden with CPU skinning. It is an agent on the navigation mesh (`agents.md`
//! §11.2): the crowd says where to go, and the controller, with its gravity, goes, except across
//! a link, whose curve a controller would refuse.
//!
//! **It plays through an `anim.Player`, on the same ticks in a run and its replay,** with no renderer.
//! Its body stays on the crowd's wish, so a clip never moves it: `stride`'s travel is read for the
//! rate that keeps its feet on the floor, and its footfalls are events.
//!
//! **Its senses and its states are the court's,** not the engine's: it patrols, chases what it
//! sees, and searches where it last saw the player before going back. Every number is content.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const anim = @import("anim");
const nav = @import("nav");
const physics = @import("physics3d");
const render3d = @import("render3d");
const asset = @import("asset");
const log = core.log.scoped(.court);
const Vec3 = core.math.Vec3;
const Mat4 = core.math.Mat4;
const Transform = core.math.Transform;
const Quat = core.math.Quat;
const Fields = data.fpk.Fields;

pub const idle = anim.clipName("idle");
const stride_clip = anim.clipName("stride");
/// What a foot landing is called in `foundry:animation_set`, and what `warden_step` is made from.
pub const footfall = core.ContentId.fromString("court:event.footfall");

/// The longest single move the warden's controller is asked for, metres.
pub const max_move: f32 = 1;

pub const WardenSettings = struct {
    model: core.ContentId,
    set: core.ContentId,
    waypoints: [max_points]Vec3 = @splat(.zero),
    len: usize = 0,
    speed: f32,
    cross_fade: f32,
    radius: f32,
    height: f32,
    /// Seconds stood at each waypoint, and before the first walk.
    pause: f32,
    /// Metres a second in a chase. Under the player's walk, so that a player can outrun it.
    chase_speed: f32,
    /// How far it sees, metres.
    sight_range: f32,
    /// The half-angle of its view, radians.
    sight_angle: f32,
    /// Seconds after losing sight of the player before it gives up the chase.
    lose_seconds: f32,
    pub const max_points = 16;

    pub fn read(fields: Fields) !WardenSettings {
        const model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidWarden;
        if (model.isNone()) return error.InvalidWarden;
        const set = (try fields.idAt(try index(fields, "set"))) orelse return error.InvalidWarden;
        if (set.isNone()) return error.InvalidWarden;
        const speed = try bounded(fields, "speed", 0.01, 10);
        const cross_fade = try bounded(fields, "cross_fade", 0.01, 5);
        const radius = try bounded(fields, "radius", 0.05, 2);
        const height = try bounded(fields, "height", 0.1, 4);
        if (height < 2 * radius) return error.InvalidWarden;
        const pause = try bounded(fields, "pause", 0, 60);
        const chase_speed = try bounded(fields, "chase_speed", 0.01, 10);
        const sight_range = try bounded(fields, "sight_range", 0, 100);
        const sight_angle = try bounded(fields, "sight_angle", 0, 1.57);
        const lose_seconds = try bounded(fields, "lose_seconds", 0, 60);
        const list = (try fields.listAt(try index(fields, "waypoints"))) orelse return error.InvalidWarden;
        if (list.len < 2 or list.len > max_points) return error.InvalidWarden;
        var out: WardenSettings = .{
            .model = model,
            .set = set,
            .speed = speed,
            .cross_fade = cross_fade,
            .radius = radius,
            .height = height,
            .pause = pause,
            .chase_speed = chase_speed,
            .sight_range = sight_range,
            .sight_angle = sight_angle,
            .lose_seconds = lose_seconds,
        };
        for (0..list.len) |i| {
            const point = (try list.nestedAt(@intCast(i))) orelse return error.InvalidWarden;
            const p: Vec3 = .init(try number(point, "x"), try number(point, "y"), try number(point, "z"));
            if (!physics.shape.positionValid(p)) return error.InvalidWarden;
            out.waypoints[i] = p;
        }
        out.len = list.len;
        for (0..out.len) |i| {
            if (out.waypoints[i].sub(out.waypoints[(i + 1) % out.len]).lengthSquared() < 0.01) return error.InvalidWarden;
        }
        return out;
    }
};

pub const Mode = enum { patrolling, chasing, searching };

pub const Warden = struct {
    settings: ?WardenSettings = null,
    model: render3d.ModelHandle = .none,
    /// None when its set doesn't give it what it needs: it still patrols, undrawn and silent.
    rig: asset.RigHandle = .none,
    /// `stride`'s metres a second at speed 1, read when the rig was bound, and zero with no rig
    /// to play.
    stride_speed: f32 = 0,
    player: anim.Player = .{},
    /// This tick's, for the game to turn into `warden_step`.
    footfalls: u32 = 0,
    character: physics.CharacterHandle = .none,
    agent: nav.AgentHandle = .none,
    /// Whether the agent has been told the waypoint it is walking to.
    targeted: bool = false,
    mode: Mode = .patrolling,
    /// Where it last saw the player.
    last_seen: Vec3 = .zero,
    /// Ticks since it last saw the player, in a chase.
    unseen_ticks: u32 = 0,
    lose_ticks: u32 = 0,
    /// The way it faces, unit, on the floor. What sight reads, so that a tick reads no trig.
    facing: Vec3 = .init(0, 0, -1),
    /// The cosine of the record's `sight_angle`, worked out once.
    sight_cosine: f32 = 1,
    feet: Vec3 = .zero,
    yaw: f32 = 0,
    velocity: f32 = 0,
    tick: u64 = 0,
    waypoint: usize = 1,
    wait_ticks: u32 = 0,
    /// `settings.pause` in ticks, fixed when the record is read.
    pause_ticks: u32 = 0,
    joint_count: usize = 0,
    scratch: [anim.max_joints]Transform = undefined,
    pose: [anim.max_joints]Transform = undefined,
    matrices: [anim.max_joints]Mat4 = undefined,

    pub fn deinit(self: *Warden, gpa: std.mem.Allocator, world: *physics.World, content: ?*render3d.Content, rigs: ?*asset.Rigs) void {
        if (!self.character.isNone()) _ = world.removeCharacter(gpa, self.character);
        self.character = .none;
        if (content) |c| {
            if (!self.model.isNone()) c.releaseModel(self.model);
        }
        self.model = .none;
        self.joint_count = 0;
        if (rigs) |r| if (!self.rig.isNone()) r.release(self.rig);
        self.rig = .none;
        self.stride_speed = 0;
    }

    /// Whether a rig holds what the warden plays. A set is a mod's to override, and one that
    /// doesn't leave it silent says so.
    pub fn bind(self: *Warden, rigs: *const asset.Rigs) void {
        self.stride_speed = 0;
        const rig = rigs.get(self.rig) orelse return;
        if (rig.find(idle) == null or rig.motionSpeed(stride_clip) <= 0) {
            log.warn("the warden's set has no 'idle' or no moving 'stride'; it goes unanimated", .{});
            return;
        }
        self.stride_speed = rig.motionSpeed(stride_clip);
    }

    /// How the warden's agent walks: its capsule, and a patrol's speed.
    pub fn params(s: *const WardenSettings) nav.AgentParams {
        return .{ .radius = s.radius, .height = s.height, .speed = s.speed, .acceleration = 8, .arrival_radius = 0.04 };
    }

    pub fn reset(self: *Warden, gpa: std.mem.Allocator, world: *physics.World, crowd: *nav.Crowd, rigs: ?*const asset.Rigs) !void {
        const s = self.settings orelse return;
        self.feet = s.waypoints[0];
        self.waypoint = 1;
        self.targeted = false;
        self.mode = .patrolling;
        self.unseen_ticks = 0;
        self.last_seen = .zero;
        self.facing = .init(0, 0, -1);
        _ = crowd.remove(self.agent);
        self.agent = crowd.add(params(&s), s.waypoints[0]) catch .none;
        self.wait_ticks = self.pause_ticks;
        self.velocity = 0;
        self.yaw = 0;
        self.tick = 0;
        // A cut to the start of `idle`, which is all a new game's player holds.
        if (self.rigOf(rigs)) |rig| try self.player.play(rig.*, idle, .{});
        if (!self.character.isNone()) {
            _ = try world.setCharacterFeet(gpa, self.character, self.feet);
        }
    }

    /// Whether the player's eye is in its view: near enough, inside the angle, and in line of
    /// sight along `clear`, which the game answers from its collision world.
    pub fn sees(self: *const Warden, from: Vec3, target: Vec3, clear: anytype) bool {
        const s = self.settings orelse return false;
        const to = target.sub(from);
        const flat = @sqrt(to.x * to.x + to.z * to.z);
        if (flat > s.sight_range) return false;
        if (flat > 1e-3 and (to.x * self.facing.x + to.z * self.facing.z) / flat < self.sight_cosine) return false;
        return clear.lineOfSight(from, target);
    }

    /// Its eyes, a little under the top of its head.
    pub fn eye(self: *const Warden) Vec3 {
        const s = self.settings orelse return self.feet;
        return self.feet.add(.init(0, s.height * 0.92, 0));
    }

    /// Chooses what the agent is walking to, from what it saw this tick.
    fn think(self: *Warden, crowd: *nav.Crowd, s: *const WardenSettings, seen: bool, player: Vec3) void {
        if (seen) {
            if (self.mode != .chasing) _ = crowd.setSpeed(self.agent, s.chase_speed);
            self.mode = .chasing;
            self.last_seen = player;
            self.unseen_ticks = 0;
            self.wait_ticks = 0;
            self.targeted = false;
            _ = crowd.setTarget(self.agent, player);
            return;
        }
        switch (self.mode) {
            .patrolling => {},
            .chasing => {
                self.unseen_ticks += 1;
                if (self.unseen_ticks >= self.lose_ticks) self.mode = .searching;
            },
            .searching => if (crowd.agent(self.agent)) |view| if (view.state == .arrived or view.state == .blocked) {
                self.mode = .patrolling;
                self.targeted = false;
                _ = crowd.setSpeed(self.agent, s.speed);
                _ = crowd.clearTarget(self.agent);
            },
        }
    }

    /// One fixed tick. `gravity` is the court's, from its rules, and `seen` is whether it sees the
    /// player at `player`, the feet. With no mesh it stands.
    pub fn step(self: *Warden, gpa: std.mem.Allocator, world: *physics.World, crowd: *nav.Crowd, rigs: ?*const asset.Rigs, gravity: f32, dt: f32, seen: bool, player: Vec3) !void {
        const s = self.settings orelse return;
        if (self.character.isNone()) return;
        const before = self.feet;
        var horizontal: Vec3 = .zero;
        self.think(crowd, &s, seen, player);
        if (self.mode == .patrolling) {
            if (self.wait_ticks != 0) {
                self.wait_ticks -= 1;
            } else if (!self.targeted) {
                self.targeted = crowd.setTarget(self.agent, s.waypoints[self.waypoint]);
            }
        }
        crowd.step(dt);
        if (self.mode == .patrolling) if (crowd.agent(self.agent)) |view| if (view.state == .arrived) {
            _ = crowd.clearTarget(self.agent);
            self.targeted = false;
            self.waypoint = (self.waypoint + 1) % s.len;
            self.wait_ticks = self.pause_ticks;
        };
        const wish = crowd.wish(self.agent);
        if (wish) |w| if (w.on_link) {
            // On a curve a controller would refuse: the body goes where the crossing says.
            self.feet = self.feet.add(w.displacement);
            _ = try world.setCharacterFeet(gpa, self.character, self.feet);
            self.velocity = 0;
            try self.finishTick(before, s, rigs, dt);
            return;
        };
        if (wish) |w| horizontal = .init(w.displacement.x, 0, w.displacement.z);
        self.velocity -= gravity * dt;
        // The fall is clamped so one move stays inside the controller's bound.
        const fall_limit = @sqrt(@max(0, max_move * max_move - horizontal.lengthSquared()));
        const result = (try world.moveCharacter(gpa, self.character, horizontal.add(.init(0, @max(self.velocity * dt, -fall_limit), 0)), &.{})) orelse return error.NoCharacter;
        self.feet = result.feet;
        crowd.place(self.agent, self.feet);
        if (result.grounded) self.velocity = 0;
        try self.finishTick(before, s, rigs, dt);
    }

    fn rigOf(self: *const Warden, rigs: ?*const asset.Rigs) ?*const anim.Rig {
        if (self.stride_speed <= 0) return null;
        return (rigs orelse return null).get(self.rig);
    }

    /// How far between idle and `stride` the figure is.
    pub fn walkWeight(self: *const Warden) f32 {
        for (self.player.channels) |channel| {
            if (channel.clip == stride_clip) return channel.weight;
        }
        return 0;
    }

    fn finishTick(self: *Warden, before: Vec3, s: WardenSettings, rigs: ?*const asset.Rigs, dt: f32) !void {
        const moved = self.feet.sub(before);
        const walking = moved.x * moved.x + moved.z * moved.z > 1e-10;
        const length = @sqrt(moved.x * moved.x + moved.z * moved.z);
        if (walking) {
            self.yaw = std.math.atan2(-moved.x, -moved.z);
            self.facing = .init(moved.x / length, 0, moved.z / length);
        }
        self.tick += 1;
        self.footfalls = 0;
        const rig = self.rigOf(rigs) orelse return;
        // The rate that keeps its feet on the floor, whichever speed it is going at.
        const speed = if (walking) @min(length / dt / self.stride_speed, anim.max_speed) else 1;
        const wanted = if (walking) stride_clip else idle;
        if (!self.player.playing(wanted)) {
            try self.player.play(rig.*, wanted, .{ .fade = s.cross_fade, .phase = .keep, .speed = speed });
        }
        if (walking) try self.player.setSpeed(rig.*, speed);
        var step_out: anim.Step = undefined;
        self.player.advance(rig.*, dt, &step_out);
        for (step_out.fired()) |event| {
            if (event.eql(footfall)) self.footfalls += 1;
        }
    }

    /// The pose, a function of the player and the rig alone.
    pub fn evaluate(self: *Warden, rigs: ?*const asset.Rigs) void {
        const rig = self.rigOf(rigs) orelse {
            self.joint_count = 0;
            return;
        };
        const n = rig.skeleton.jointCount();
        const pose: anim.Pose = .{ .local = self.pose[0..n] };
        self.player.evaluate(rig.*, .{ .local = self.scratch[0..n] }, pose);
        anim.skinMatrices(rig.skeleton, pose, self.matrices[0..n]);
        self.joint_count = n;
    }

    pub fn draw(self: *const Warden, content: *render3d.Content) !void {
        if (self.joint_count == 0 or self.model.isNone()) return;
        try content.drawModel(.{
            .model = self.model,
            .world = Mat4.trs(self.feet, Quat.fromAxisAngle(.up, self.yaw), .one),
            .skin = self.matrices[0..self.joint_count],
        });
    }
};

fn index(fields: Fields, name: []const u8) !u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidWarden;
}

fn number(fields: Fields, name: []const u8) !f32 {
    const value = (fields.floatAt(try index(fields, name)) catch return error.InvalidWarden) orelse return error.InvalidWarden;
    const v: f32 = @floatCast(value);
    if (!std.math.isFinite(v)) return error.InvalidWarden;
    return v;
}

fn bounded(fields: Fields, name: []const u8, min: f32, max: f32) !f32 {
    const value = try number(fields, name);
    if (value < min or value > max) return error.InvalidWarden;
    return value;
}
