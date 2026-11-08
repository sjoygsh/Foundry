//! Sample-owned warden with CPU skinning. It is an agent on the navigation mesh (`agents.md`
//! §11.2): the crowd says where to go, and the controller, with its gravity, goes, except across
//! a link, whose curve a controller would refuse.
//!
//! **It plays a machine, `court:warden.machine`, through an `anim.Stack` it holds,** on the same ticks
//! in a run and its replay, with no renderer (`animation-states.md` §14). Its body stays on the crowd's
//! wish, so a clip never moves it. Each tick the court tells the machine five things and the machine
//! decides the rest:
//! - `speed`: its ground speed, m/s, which picks idle, walk or run and the rate that keeps its feet
//!   on the floor;
//! - `link`: the kind of link it is crossing, plus one, or 0;
//! - `link_t`: how far across, which is where the crossing's clip is put, so a jump of any length
//!   fits its arc;
//! - `near`: 1 in a chase within `reach_distance` of the player, when its arms reach;
//! - `winded`: 1 in a chase, when its chest heaves.
//!
//! Its footfalls and its landing are events. The crowd's last tick of a crossing no longer says it is
//! on a link, so that tick keeps `link` and puts `link_t` at 1, and an event at the clip's end still
//! fires.
//!
//! **Since M36 it walks and runs on a blend, and places its feet and looks** (`animation-ik.md` §13):
//! the machine's `move` mixes idle, the stride and the run by `speed`. After each tick's move the
//! pose is evaluated, its feet are put on what two rays find in the level, locked, and its head
//! turns to the player's eyes while it sees them. All of that is presentation, stepped once a tick
//! so a replay draws the same, and none of it moves the body.
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
const speed_param = anim.clipName("speed");
const link_param = anim.clipName("link");
const link_t_param = anim.clipName("link_t");
const near_param = anim.clipName("near");
const winded_param = anim.clipName("winded");
const head_aim = anim.clipName("head");
/// What the feet's rays may hit: the level's layer.
const ground_mask: u32 = 1;
/// What a foot landing is called in `foundry:animation_set`, and what `warden_step` is made from.
pub const footfall = core.ContentId.fromString("court:event.footfall");
/// What landing from a crossing is called there.
pub const land = core.ContentId.fromString("court:event.land");

/// The longest single move the warden's controller is asked for, metres.
pub const max_move: f32 = 1;

pub const WardenSettings = struct {
    model: core.ContentId,
    set: core.ContentId,
    /// What it plays, against `set`'s rig. Which clip a link's kind crosses with is the machine's to
    /// say, since a link is a place and two bodies crossing it may not move alike.
    machine: core.ContentId,
    waypoints: [max_points]Vec3 = @splat(.zero),
    len: usize = 0,
    speed: f32,
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
    /// How near the player, in a chase, before its arms reach, metres.
    reach_distance: f32,
    pub const max_points = 16;

    pub fn read(fields: Fields) !WardenSettings {
        const model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidWarden;
        if (model.isNone()) return error.InvalidWarden;
        const set = (try fields.idAt(try index(fields, "set"))) orelse return error.InvalidWarden;
        if (set.isNone()) return error.InvalidWarden;
        const machine = (try fields.idAt(try index(fields, "machine"))) orelse return error.InvalidWarden;
        if (machine.isNone()) return error.InvalidWarden;
        const speed = try bounded(fields, "speed", 0.01, 10);
        const radius = try bounded(fields, "radius", 0.05, 2);
        const height = try bounded(fields, "height", 0.1, 4);
        if (height < 2 * radius) return error.InvalidWarden;
        const pause = try bounded(fields, "pause", 0, 60);
        const chase_speed = try bounded(fields, "chase_speed", 0.01, 10);
        const sight_range = try bounded(fields, "sight_range", 0, 100);
        const sight_angle = try bounded(fields, "sight_angle", 0, 1.57);
        const lose_seconds = try bounded(fields, "lose_seconds", 0, 60);
        const reach_distance = try bounded(fields, "reach_distance", 0, 20);
        const list = (try fields.listAt(try index(fields, "waypoints"))) orelse return error.InvalidWarden;
        if (list.len < 2 or list.len > max_points) return error.InvalidWarden;
        var out: WardenSettings = .{
            .model = model,
            .set = set,
            .machine = machine,
            .speed = speed,
            .radius = radius,
            .height = height,
            .pause = pause,
            .chase_speed = chase_speed,
            .sight_range = sight_range,
            .sight_angle = sight_angle,
            .lose_seconds = lose_seconds,
            .reach_distance = reach_distance,
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

pub const Crossing = struct { kind: nav.LinkKind, t: f32 };

pub const Warden = struct {
    settings: ?WardenSettings = null,
    model: render3d.ModelHandle = .none,
    /// None when its set doesn't give it what it needs: it still patrols, undrawn and silent.
    rig: asset.RigHandle = .none,
    /// None when its machine doesn't build against that rig, which leaves it the same.
    machine: asset.MachineHandle = .none,
    /// `stride`'s metres a second at speed 1, read when the rig was bound, and zero with no rig or
    /// machine to play.
    stride_speed: f32 = 0,
    /// Its layers and the machine's place: the body, the arms and the breath.
    stack: anim.Stack = .{},
    /// This tick's, for the game to turn into `warden_step`.
    footfalls: u32 = 0,
    /// This tick's, for the game to turn into `warden_land`.
    landings: u32 = 0,
    /// This tick's, for the overlay.
    report: anim.Report = .{},
    /// How much of the base layer walks rather than stands, this tick, for `hashTick`.
    walk_weight: f32 = 0,
    /// Its feet and its gaze: presentation, stepped once a tick, never saved or hashed.
    feet_state: anim.Feet = .{},
    aim: anim.Aim = .{},
    /// What each foot's ray found this tick, and whether its feet were placed: for the tests.
    grounds: [anim.max_legs]anim.Ground = @splat(.{}),
    placed: bool = false,
    /// Whether planted feet are held where they landed.
    lock: bool = true,
    /// The `link` it told the machine last tick: the kind plus one while crossing, and 0 otherwise.
    link: f32 = 0,
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
    /// The surface under its controller after this tick's move, for its footfalls' sound.
    surface: core.ContentId = .none,
    yaw: f32 = 0,
    velocity: f32 = 0,
    tick: u64 = 0,
    waypoint: usize = 1,
    wait_ticks: u32 = 0,
    /// `settings.pause` in ticks, fixed when the record is read.
    pause_ticks: u32 = 0,
    joint_count: usize = 0,
    /// Two poses, since a stack mixes its layers over the body.
    scratch: [3 * anim.max_joints]Transform = undefined,
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
        if (rigs) |r| if (!self.machine.isNone()) r.releaseMachine(self.machine);
        self.machine = .none;
        if (rigs) |r| if (!self.rig.isNone()) r.release(self.rig);
        self.rig = .none;
        self.stride_speed = 0;
    }

    /// Whether a rig and a machine hold what the warden plays. Both are a mod's to override, and one
    /// that doesn't leave it silent says so. The machine's validation has named the clips.
    pub fn bind(self: *Warden, rigs: *const asset.Rigs) void {
        self.stride_speed = 0;
        const rig = rigs.get(self.rig) orelse return;
        if (rigs.getMachine(self.machine) == null) {
            log.warn("the warden's machine does not build against its set; it goes unanimated", .{});
            return;
        }
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
        self.surface = .none;
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
        self.link = 0;
        self.walk_weight = 0;
        self.feet_state = .{};
        self.aim = .{};
        self.joint_count = 0;
        // A cut to the start of `idle`, which is all a new game's body holds. The machine's first
        // tick takes the state that plays it.
        self.stack = .{};
        if (self.rigOf(rigs)) |rig| try self.stack.base().play(rig.*, idle, .{});
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
    /// player at `player`, the feet, with its eyes at `player_eye`. With no mesh it stands.
    pub fn step(self: *Warden, gpa: std.mem.Allocator, world: *physics.World, crowd: *nav.Crowd, rigs: ?*const asset.Rigs, gravity: f32, dt: f32, seen: bool, player: Vec3, player_eye: Vec3) !void {
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
            // In the air over the link, so no ground: its landing plays the sound set's own.
            self.surface = .none;
            _ = try world.setCharacterFeet(gpa, self.character, self.feet);
            self.velocity = 0;
            try self.finishTick(before, s, rigs, dt, self.crossing(crowd), player);
            self.present(world, rigs, true, if (seen) player_eye else null, dt);
            return;
        };
        if (wish) |w| horizontal = .init(w.displacement.x, 0, w.displacement.z);
        self.velocity -= gravity * dt;
        // The fall is clamped so one move stays inside the controller's bound.
        const fall_limit = @sqrt(@max(0, max_move * max_move - horizontal.lengthSquared()));
        const result = (try world.moveCharacter(gpa, self.character, horizontal.add(.init(0, @max(self.velocity * dt, -fall_limit), 0)), &.{})) orelse return error.NoCharacter;
        self.feet = result.feet;
        self.surface = if (result.ground) |g| g.surface else .none;
        crowd.place(self.agent, self.feet);
        if (result.grounded) self.velocity = 0;
        try self.finishTick(before, s, rigs, dt, null, player);
        self.present(world, rigs, false, if (seen) player_eye else null, dt);
    }

    /// The kind of link being crossed, and how far across it is.
    pub fn crossing(self: *const Warden, crowd: *const nav.Crowd) ?Crossing {
        const view = crowd.agent(self.agent) orelse return null;
        const mesh = crowd.mesh orelse return null;
        if (view.link >= mesh.links.len) return null;
        return .{ .kind = mesh.links[view.link].kind, .t = view.link_t };
    }

    fn rigOf(self: *const Warden, rigs: ?*const asset.Rigs) ?*const anim.Rig {
        if (self.stride_speed <= 0) return null;
        return (rigs orelse return null).get(self.rig);
    }

    /// The body's player.
    pub fn body(self: *Warden) *anim.Player {
        return self.stack.base();
    }

    /// How much of the body walks rather than stands: `hashTick`'s, read at the end of each tick.
    pub fn walkWeight(self: *const Warden) f32 {
        return self.walk_weight;
    }

    /// Each channel's weight, less the share of it that is `idle`: all of a clip that is not idle,
    /// and a blend's clips other than idle at the machine's place in it.
    fn readWalkWeight(self: *const Warden, rig: anim.Rig, machine: anim.Machine) f32 {
        const positions = anim.machine.positions(&self.stack, machine);
        var total: f32 = 0;
        for (self.stack.players[0].channels) |channel| {
            if (channel.weight == 0 or channel.clip == idle) continue;
            const entry = rig.find(channel.clip) orelse continue;
            const blend = entry.blend orelse {
                total += channel.weight;
                continue;
            };
            const mix = blend.weights(positions.of(entry));
            for (mix.slice()) |part| {
                if (part.clip != idle) total += channel.weight * part.weight;
            }
        }
        return total;
    }

    /// The pose and its skin, with no feet or gaze: what the warden plays, for a test or a host
    /// with no level to stand it on.
    pub fn evaluate(self: *Warden, rigs: ?*const asset.Rigs) void {
        const rig = self.rigOf(rigs) orelse {
            self.joint_count = 0;
            return;
        };
        const machine = (rigs orelse return).getMachine(self.machine) orelse {
            self.joint_count = 0;
            return;
        };
        const n = rig.skeleton.jointCount();
        const pose: anim.Pose = .{ .local = self.pose[0..n] };
        anim.machine.evaluate(&self.stack, rig.*, machine.*, .{ .{ .local = self.scratch[0..n] }, .{ .local = self.scratch[n .. 2 * n] }, .{ .local = self.scratch[2 * n .. 3 * n] } }, pose);
        anim.skinMatrices(rig.skeleton, pose, self.matrices[0..n]);
        self.joint_count = n;
    }

    /// `animation-ik.md` §14's steps 3 to 6, once a tick after the move: the pose, the feet on what
    /// two rays find in the level, the head toward `look`, and the skin. A crossing's one-shot is
    /// left as its clip, off the ground. Nothing here moves the body or reaches the hash.
    fn present(self: *Warden, world: *physics.World, rigs: ?*const asset.Rigs, crossing_now: bool, look: ?Vec3, dt: f32) void {
        self.placed = false;
        const rig = self.rigOf(rigs) orelse {
            self.joint_count = 0;
            return;
        };
        const machine = rigs.?.getMachine(self.machine) orelse {
            self.joint_count = 0;
            return;
        };
        const n = rig.skeleton.jointCount();
        const pose: anim.Pose = .{ .local = self.pose[0..n] };
        anim.machine.evaluate(&self.stack, rig.*, machine.*, .{ .{ .local = self.scratch[0..n] }, .{ .local = self.scratch[n .. 2 * n] }, .{ .local = self.scratch[2 * n .. 3 * n] } }, pose);
        const to_world = Mat4.trs(self.feet, Quat.fromAxisAngle(.up, self.yaw), .one);
        if (!crossing_now and self.link == 0 and rig.legs.len != 0) {
            var rays: [anim.max_legs]anim.Probe = undefined;
            const probes = anim.Feet.probes(rig.*, pose, to_world, &rays);
            for (probes, 0..) |probe, l| {
                const hit = world.raycast(probe.origin, probe.direction, probe.distance, .{ .mask = ground_mask }) catch null;
                self.grounds[l] = if (hit) |h| .{ .hit = true, .point = h.point, .normal = h.normal } else .{};
            }
            const contacts = anim.feet.contactWeights(rig.*, self.stack.base(), anim.machine.positions(&self.stack, machine.*));
            self.feet_state.place(rig.*, pose, to_world, self.grounds[0..probes.len], contacts, dt, .{ .lock = self.lock });
            self.placed = true;
        }
        if (aimOf(rig.*)) |chain| self.aim.apply(rig.*, chain, pose, to_world, look, if (look != null) 1 else 0, dt);
        anim.skinMatrices(rig.skeleton, pose, self.matrices[0..n]);
        self.joint_count = n;
    }

    fn finishTick(self: *Warden, before: Vec3, s: WardenSettings, rigs: ?*const asset.Rigs, dt: f32, across: ?Crossing, player: Vec3) !void {
        const moved = self.feet.sub(before);
        const walking = moved.x * moved.x + moved.z * moved.z > 1e-10;
        const length = @sqrt(moved.x * moved.x + moved.z * moved.z);
        if (walking) {
            self.yaw = std.math.atan2(-moved.x, -moved.z);
            self.facing = .init(moved.x / length, 0, moved.z / length);
        }
        self.tick += 1;
        self.footfalls = 0;
        self.landings = 0;
        const rig = self.rigOf(rigs) orelse return;
        const machine = rigs.?.getMachine(self.machine) orelse return;

        // The five inputs. The tick it lands, the crowd has let go of the crossing: `link` stays as
        // it was and `link_t` is 1, so what the clip says at its end happens here.
        var link: f32 = 0;
        var link_t: f32 = 0;
        if (across) |crossing_now| {
            link = @floatFromInt(@intFromEnum(crossing_now.kind) + 1);
            link_t = crossing_now.t;
        } else if (self.link != 0) {
            link = self.link;
            link_t = 1;
        }
        self.link = if (across != null) link else 0;
        const chasing = self.mode == .chasing;
        const near = chasing and player.sub(self.feet).length() <= s.reach_distance;
        const inputs = [_]struct { name: u64, value: f32 }{
            .{ .name = speed_param, .value = if (walking) length / dt else 0 },
            .{ .name = link_param, .value = link },
            .{ .name = link_t_param, .value = link_t },
            .{ .name = near_param, .value = if (near) 1 else 0 },
            .{ .name = winded_param, .value = if (chasing) 1 else 0 },
        };
        for (inputs) |input| {
            // A mod's machine need not read every input, and every value here is finite.
            anim.machine.set(&self.stack, machine.*, input.name, input.value) catch {};
        }

        var step_out: anim.Step = undefined;
        anim.machine.advance(&self.stack, rig.*, machine.*, dt, &step_out);
        self.walk_weight = self.readWalkWeight(rig.*, machine.*);
        self.report = .{};
        self.report.addStack(&self.stack, rig.*, machine.*, "warden", &step_out);
        for (step_out.fired()) |event| {
            if (event.eql(footfall)) self.footfalls += 1;
            if (event.eql(land)) self.landings += 1;
        }
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

/// The set's `head` aim, if it has one.
fn aimOf(rig: anim.Rig) ?usize {
    for (rig.aims, 0..) |entry, i| if (entry.name == head_aim) return i;
    return null;
}

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
