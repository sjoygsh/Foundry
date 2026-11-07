//! M36's strafer (`animation-ik.md` §12): a walker figure that circles a point on the floor, and
//! sweeps `walk8`, the set's 3 × 3 blend of directional walks, through every direction it has.
//!
//! **Code moves the body, and the blend follows.** It goes round at a steady speed while its heading
//! turns steadily against its path, `spin` turns a lap. At half a turn a lap it walks forward,
//! sideways with the centre ahead of it, backward and sideways again over two laps. So its velocity
//! in its own frame sweeps every direction,
//! and the game says that velocity to `sandbox3d:strafer.machine` as `side` and `ahead`, the blend's
//! two axes. Each of `walk8`'s walks travels its own place on the grid, so the blend's travel is the
//! velocity the body moves at, and the feet keep up with it.
//!
//! **A tick runs `animation-ik.md` §14's order:** parameters and the stack, the body's move, the pose
//! at the machine's place in the blend, the feet on what rays find in the walk world, then the head
//! turned to the camera. Its feet are not locked; see `lock`.
//!
//! **It is a plain value, as the climber is,** not an entity, and nothing of it is saved. A set
//! without `walk8`, or a machine that does not build, leaves it out and says why.

const std = @import("std");

const anim = @import("anim");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const physics = @import("physics3d");
const render3d = @import("render3d");

const Fields = data.fpk.Fields;
const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;
const log = core.log.scoped(.sandbox3d);

pub const record_id = core.ContentId.fromString("sandbox3d:strafer.main");
const walk8 = anim.clipName("walk8");
const side_param = anim.clipName("side");
const ahead_param = anim.clipName("ahead");
const head_aim = anim.clipName("head");

pub const Settings = struct {
    model: core.ContentId,
    set: core.ContentId,
    machine: core.ContentId,
    centre: Vec3,
    radius: f32,
    speed: f32,
    /// Turns of its heading against its path, each lap round.
    spin: f32,

    pub fn read(fields: Fields) !Settings {
        const out: Settings = .{
            .model = try id(fields, "model"),
            .set = try id(fields, "set"),
            .machine = try id(fields, "machine"),
            .centre = try point(fields, "centre"),
            .radius = try bounded(fields, "radius", 0.1, 10),
            .speed = try bounded(fields, "speed", 0.05, 4),
            .spin = try bounded(fields, "spin", -4, 4),
        };
        return out;
    }
};

pub const Strafer = struct {
    settings: ?Settings = null,
    rig: asset.RigHandle = .none,
    machine: asset.MachineHandle = .none,
    model: render3d.ModelHandle = .none,
    stack: anim.Stack = .{},
    feet: anim.Feet = .{},
    aim: anim.Aim = .{},
    /// Radians round the centre, and the heading's turn away from its path.
    angle: f32 = 0,
    offset: f32 = 0,
    position: Vec3 = .zero,
    yaw: f32 = 0,
    /// The velocity in its own frame, as the machine was told: x to its right, y ahead.
    at: [2]f32 = .{ 0, 0 },
    joint_count: usize = 0,
    grounds: [anim.max_legs]anim.Ground = @splat(.{}),
    scratch: [3 * anim.max_joints]Transform = undefined,
    pose: [anim.max_joints]Transform = undefined,
    matrices: [anim.max_joints]Mat4 = undefined,
    /// Whether planted feet are held where they landed (`anim.feet.Options.lock`). Not by default:
    /// inside `walk8` its walks' planted feet, mixed, slide up to 0.8 m/s, so a held foot reaches its
    /// 0.25 m and is let go in mid-step, and catching up moves it faster than any step does (M36
    /// Step 7's Resolution). The climber, on one clip at a matched rate, locks.
    lock: bool = false,
    ticks: u64 = 0,
    hash: u64 = hash_seed,

    pub const hash_seed: u64 = 0xcbf29ce484222325;

    pub fn deinit(self: *Strafer, rigs: *asset.Rigs, content: ?*render3d.Content) void {
        if (!self.model.isNone()) if (content) |c| c.releaseModel(self.model);
        if (!self.machine.isNone()) rigs.releaseMachine(self.machine);
        if (!self.rig.isNone()) rigs.release(self.rig);
        self.* = .{};
    }

    /// At each content refresh: the record, the rig and machine, and the figure back at its start.
    pub fn refresh(self: *Strafer, store: *const data.Store, rigs: *asset.Rigs, content: ?*render3d.Content) void {
        self.deinit(rigs, content);
        const record = store.lookup(record_id) orelse return;
        const settings = Settings.read(record.fields) catch |err| {
            log.warn("{f} is refused ({t}); no strafer", .{ record_id, err });
            return;
        };
        self.rig = rigs.acquire(settings.set) catch |err| {
            log.warn("no strafer: {f} did not build ({t})", .{ settings.set, err });
            return;
        };
        const rig = rigs.get(self.rig).?;
        if (rig.blend(walk8) == null or rig.blend(walk8).?.axes() != 2) {
            log.warn("no strafer: {f} has no two-axis 'walk8'", .{settings.set});
            self.deinit(rigs, content);
            return;
        }
        self.machine = rigs.acquireMachine(settings.set, settings.machine) catch |err| {
            log.warn("no strafer: {f} does not build against its set ({t})", .{ settings.machine, err });
            self.deinit(rigs, content);
            return;
        };
        if (content) |c| self.model = c.acquireModel(settings.model) catch |err| blk: {
            log.warn("the strafer is not drawn: {f} ({t})", .{ settings.model, err });
            break :blk .none;
        };
        self.settings = settings;
        self.place();
    }

    pub fn active(self: *const Strafer) bool {
        return self.settings != null;
    }

    /// Where the angle puts it, and the heading its path and the offset give it.
    fn place(self: *Strafer) void {
        const s = self.settings.?;
        const c = @cos(self.angle);
        const n = @sin(self.angle);
        self.position = s.centre.add(.init(s.radius * c, 0, s.radius * n));
        // Going round with the angle: along (-sin, 0, cos). A heading `yaw` faces (-sin yaw, 0, -cos yaw).
        self.yaw = std.math.atan2(n, -c) + self.offset;
    }

    /// One tick. `ground` is the walk world, `eye` the camera's, and either may be absent.
    pub fn step(self: *Strafer, rigs: *const asset.Rigs, ground: ?*physics.World, eye: ?Vec3, dt: f32) !void {
        const s = self.settings orelse return;
        const rig = rigs.get(self.rig) orelse return;
        const machine = rigs.getMachine(self.machine) orelse return;

        // Its velocity, in its own frame.
        const along = self.angle + std.math.pi / 2.0;
        const velocity: Vec3 = .init(s.speed * @cos(along), 0, s.speed * @sin(along));
        const local = Quat.fromAxisAngle(.up, -(self.yaw)).rotate(velocity);
        self.at = .{ local.x, -local.z };
        try anim.machine.set(&self.stack, machine.*, side_param, self.at[0]);
        try anim.machine.set(&self.stack, machine.*, ahead_param, self.at[1]);
        var out: anim.Step = .{};
        anim.machine.advance(&self.stack, rig.*, machine.*, dt, &out);

        // The body's move, by code, and its heading's turn against its path. Each is kept within a
        // whole turn, so neither grows without bound over a long run.
        const step_angle = s.speed / s.radius * dt;
        self.angle = @mod(self.angle + step_angle, 2 * std.math.pi);
        self.offset = @mod(self.offset - s.spin * step_angle, 2 * std.math.pi);
        self.place();

        const n = rig.skeleton.jointCount();
        const pose: anim.Pose = .{ .local = self.pose[0..n] };
        const lent = [3]anim.Pose{
            .{ .local = self.scratch[0..n] },
            .{ .local = self.scratch[n .. 2 * n] },
            .{ .local = self.scratch[2 * n .. 3 * n] },
        };
        anim.machine.evaluate(&self.stack, rig.*, machine.*, lent, pose);
        const to_world = Mat4.trs(self.position, Quat.fromAxisAngle(.up, self.yaw), .one);
        if (ground) |world| if (rig.legs.len != 0) {
            var rays: [anim.max_legs]anim.Probe = undefined;
            const probes = anim.Feet.probes(rig.*, pose, to_world, &rays);
            for (probes, 0..) |probe, l| {
                const hit = world.raycast(probe.origin, probe.direction, probe.distance, .{ .mask = 1 }) catch null;
                self.grounds[l] = if (hit) |h| .{ .hit = true, .point = h.point, .normal = h.normal } else .{};
            }
            const contacts = anim.feet.contactWeights(rig.*, &self.stack.players[0], anim.machine.positions(&self.stack, machine.*));
            self.feet.place(rig.*, pose, to_world, self.grounds[0..probes.len], contacts, dt, .{ .lock = self.lock });
        };
        if (aimOf(rig.*)) |chain| self.aim.apply(rig.*, chain, pose, to_world, eye, if (eye != null) 1 else 0, dt);
        anim.skinMatrices(rig.skeleton, pose, self.matrices[0..n]);
        self.joint_count = n;
        self.ticks += 1;
        self.note();
    }

    fn note(self: *Strafer) void {
        for (self.pose[0..self.joint_count]) |p| {
            self.bytes(std.mem.asBytes(&p.translation));
            self.bytes(std.mem.asBytes(&p.rotation));
            self.bytes(std.mem.asBytes(&p.scale));
        }
        self.bytes(std.mem.asBytes(&self.position));
        self.bytes(std.mem.asBytes(&self.yaw));
    }

    fn bytes(self: *Strafer, b: []const u8) void {
        for (b) |byte| self.hash = (self.hash ^ byte) *% 0x100000001b3;
    }

    pub fn draw(self: *const Strafer, content: *render3d.Content) !void {
        if (self.joint_count == 0 or self.model.isNone()) return;
        try content.drawModel(.{ .model = self.model, .world = Mat4.trs(self.position, Quat.fromAxisAngle(.up, self.yaw), .one), .skin = self.matrices[0..self.joint_count] });
    }
};

/// The set's `head` aim, if it has one.
fn aimOf(rig: anim.Rig) ?usize {
    for (rig.aims, 0..) |entry, i| if (entry.name == head_aim) return i;
    return null;
}

fn index(fields: Fields, name: []const u8) !u32 {
    for (fields.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    return error.InvalidStrafer;
}

fn id(fields: Fields, name: []const u8) !core.ContentId {
    const value = (try fields.idAt(try index(fields, name))) orelse return error.InvalidStrafer;
    if (value.isNone()) return error.InvalidStrafer;
    return value;
}

fn number(fields: Fields, name: []const u8) !f32 {
    const v: f32 = @floatCast((try fields.floatAt(try index(fields, name))) orelse return error.InvalidStrafer);
    if (!std.math.isFinite(v)) return error.InvalidStrafer;
    return v;
}

fn bounded(fields: Fields, name: []const u8, lo: f32, hi: f32) !f32 {
    const v = try number(fields, name);
    if (v < lo or v > hi) return error.InvalidStrafer;
    return v;
}

fn point(fields: Fields, name: []const u8) !Vec3 {
    const p = (try fields.nestedAt(try index(fields, name))) orelse return error.InvalidStrafer;
    return .init(try number(p, "x"), try number(p, "y"), try number(p, "z"));
}
