//! Sample-owned patrol warden with CPU skinning.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const anim = @import("anim");
const physics = @import("physics3d");
const render3d = @import("render3d");
const asset = @import("asset");
const Vec3 = core.math.Vec3;
const Mat4 = core.math.Mat4;
const Transform = core.math.Transform;
const Quat = core.math.Quat;
const Fields = data.fpk.Fields;

pub const WardenSettings = struct {
    model: core.ContentId,
    waypoints: [max_points]Vec3 = @splat(.zero),
    len: usize = 0,
    speed: f32,
    cross_fade: f32,
    pub const max_points = 16;

    pub fn read(fields: Fields) !WardenSettings {
        const model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidWarden;
        if (model.isNone()) return error.InvalidWarden;
        const speed = try bounded(fields, "speed", 0.01, 10);
        const cross_fade = try bounded(fields, "cross_fade", 0.01, 5);
        const list = (try fields.listAt(try index(fields, "waypoints"))) orelse return error.InvalidWarden;
        if (list.len < 2 or list.len > max_points) return error.InvalidWarden;
        var out: WardenSettings = .{
            .model = model,
            .speed = speed,
            .cross_fade = cross_fade,
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

pub const Warden = struct {
    settings: ?WardenSettings = null,
    model: render3d.ModelHandle = .none,
    character: physics.CharacterHandle = .none,
    feet: Vec3 = .zero,
    yaw: f32 = 0,
    velocity: f32 = 0,
    tick: u64 = 0,
    waypoint: usize = 1,
    wait_ticks: u32 = 60,
    weight: f32 = 0,
    joint_count: usize = 0,
    idle_pose: [256]Transform = undefined,
    walk_pose: [256]Transform = undefined,
    pose: [256]Transform = undefined,
    matrices: [256]Mat4 = undefined,

    pub fn deinit(self: *Warden, gpa: std.mem.Allocator, world: *physics.World, content: ?*render3d.Content) void {
        if (!self.character.isNone()) _ = world.removeCharacter(gpa, self.character);
        self.character = .none;
        if (content) |c| {
            if (!self.model.isNone()) c.releaseModel(self.model);
        }
        self.model = .none;
        self.joint_count = 0;
    }

    pub fn reset(self: *Warden, gpa: std.mem.Allocator, world: *physics.World) !void {
        const s = self.settings orelse return;
        self.feet = s.waypoints[0];
        self.waypoint = 1;
        self.wait_ticks = 60;
        self.velocity = 0;
        self.yaw = 0;
        self.weight = 0;
        self.tick = 0;
        if (!self.character.isNone()) {
            _ = try world.setCharacterFeet(gpa, self.character, self.feet);
        }
    }

    pub fn step(self: *Warden, gpa: std.mem.Allocator, world: *physics.World, dt: f32) !void {
        const s = self.settings orelse return;
        if (self.character.isNone()) return;
        const before = self.feet;
        var horizontal: Vec3 = .zero;
        if (self.wait_ticks != 0) {
            self.wait_ticks -= 1;
        } else {
            var delta = s.waypoints[self.waypoint].sub(self.feet);
            delta.y = 0;
            const distance = delta.length();
            if (distance <= s.speed * dt + 0.01) {
                self.waypoint = (self.waypoint + 1) % s.len;
                self.wait_ticks = 60;
            } else {
                horizontal = delta.scale(@min(distance, s.speed * dt) / distance);
            }
        }
        self.velocity = @max(-20, self.velocity - 9.81 * dt);
        const result = (try world.moveCharacter(gpa, self.character, horizontal.add(.init(0, self.velocity * dt, 0)), &.{})) orelse return error.NoCharacter;
        self.feet = result.feet;
        if (result.grounded) self.velocity = 0;
        const moved = self.feet.sub(before);
        const walking = moved.x * moved.x + moved.z * moved.z > 1e-10;
        if (walking) self.yaw = std.math.atan2(-moved.x, -moved.z);
        const by = dt / s.cross_fade;
        self.weight = std.math.clamp(self.weight + (if (walking) by else -by), 0, 1);
        self.tick += 1;
    }

    pub fn evaluate(self: *Warden, content: *render3d.Content, dt: f32) !void {
        if (self.model.isNone()) return;
        errdefer self.joint_count = 0;
        const source = content.skeletonOf(self.model) orelse return error.MissingSkeleton;
        const skeleton: anim.Skeleton = .{ .parents = source.parents, .rest = source.rest, .inverse_bind = source.inverse_bind, .root = source.root };
        try skeleton.validate();
        const n = skeleton.jointCount();
        const idle = content.clipOf(self.model, "idle") orelse return error.MissingIdle;
        const walk = content.clipOf(self.model, "walk") orelse return error.MissingWalk;
        var idle_tracks: [anim.clip.max_tracks]anim.Track = undefined;
        var walk_tracks: [anim.clip.max_tracks]anim.Track = undefined;
        const a = try clip(idle, n, &idle_tracks);
        const b = try clip(walk, n, &walk_tracks);
        const time = @as(f32, @floatFromInt(self.tick)) * dt;
        const pose_a: anim.Pose = .{ .local = self.idle_pose[0..n] };
        const pose_b: anim.Pose = .{ .local = self.walk_pose[0..n] };
        const pose: anim.Pose = .{ .local = self.pose[0..n] };
        anim.sample(skeleton, a, anim.wrap(time, a.duration), pose_a);
        anim.sample(skeleton, b, anim.wrap(time, b.duration), pose_b);
        anim.blend(pose_a, pose_b, self.weight, pose);
        anim.skinMatrices(skeleton, pose, self.matrices[0..n]);
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

fn clip(source: *const asset.animation.Animation, count: usize, tracks: []anim.Track) !anim.Clip {
    try source.checkJointCount(count);
    if (source.tracks.len > tracks.len) return error.TooManyTracks;
    for (source.tracks, tracks[0..source.tracks.len]) |from, *to| to.* = .{
        .joint = from.joint,
        .path = @enumFromInt(@intFromEnum(from.path)),
        .interpolation = @enumFromInt(@intFromEnum(from.interpolation)),
        .times = from.times,
        .values = from.values,
    };
    const result: anim.Clip = .{ .duration = source.duration, .tracks = tracks[0..source.tracks.len] };
    try result.validate(count);
    return result;
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
