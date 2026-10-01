//! M24's sample-owned patrol/playback. Retain a model handle, never asset payload pointers.
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

pub const Settings = struct {
    model: core.ContentId,
    waypoints: [max_points]Vec3 = @splat(.zero),
    len: usize = 0,
    speed: f32,
    cross_fade: f32,
    pub const max_points = 16;
    pub fn read(fields: data.fpk.Fields) !Settings {
        var out: Settings = .{
            .model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidWalker,
            .speed = @floatCast((try fields.floatAt(try index(fields, "speed"))) orelse return error.InvalidWalker),
            .cross_fade = @floatCast((try fields.floatAt(try index(fields, "cross_fade"))) orelse return error.InvalidWalker),
        };
        if (out.model.isNone() or !std.math.isFinite(out.speed) or out.speed <= 0 or out.speed > 6 or
            !std.math.isFinite(out.cross_fade) or out.cross_fade < 1.0 / 60.0 or out.cross_fade > 10) return error.InvalidWalker;
        const list = (try fields.listAt(try index(fields, "waypoints"))) orelse return error.InvalidWalker;
        if (list.len < 2 or list.len > max_points) return error.InvalidWalker;
        for (0..list.len) |i| {
            const point = (try list.nestedAt(@intCast(i))) orelse return error.InvalidWalker;
            const p: Vec3 = .init(@floatCast((try point.floatAt(0)) orelse return error.InvalidWalker), @floatCast((try point.floatAt(1)) orelse return error.InvalidWalker), @floatCast((try point.floatAt(2)) orelse return error.InvalidWalker));
            if (!physics.shape.positionValid(p)) return error.InvalidWalker;
            out.waypoints[i] = p;
        }
        out.len = list.len;
        for (0..out.len) |i| if (out.waypoints[i].sub(out.waypoints[(i + 1) % out.len]).lengthSquared() < 0.01) return error.InvalidWalker;
        return out;
    }
};
fn index(fields: data.fpk.Fields, name: []const u8) !u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidWalker;
}

pub const Walker = struct {
    settings: ?Settings = null,
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
    reached: u32 = 0,
    used_idle: bool = false,
    used_walk: bool = false,
    used_fade: bool = false,
    hash: u64 = 0xcbf29ce484222325,
    pub const proof_ticks = 2100;

    pub fn deinit(self: *Walker, gpa: std.mem.Allocator, world: *physics.World, content: *render3d.Content) void {
        if (!self.character.isNone()) _ = world.removeCharacter(gpa, self.character);
        if (!self.model.isNone()) content.releaseModel(self.model);
        self.character = .none;
        self.model = .none;
        self.joint_count = 0;
    }
    /// At the generation seam: borrow new values, validate, and rebuild the pose. Preserve
    /// playback/feet when the record is unchanged. Any refusal disables, never uses old arrays.
    pub fn refresh(self: *Walker, gpa: std.mem.Allocator, store: *const data.Store, world: *physics.World, content: *render3d.Content, dt: f32) !void {
        const entry = store.lookup(core.ContentId.fromString("sandbox3d:walker.main")) orelse {
            self.deinit(gpa, world, content);
            self.settings = null;
            return error.MissingWalker;
        };
        const fresh = Settings.read(entry.fields) catch |err| {
            self.deinit(gpa, world, content);
            self.settings = null;
            return err;
        };
        const changed = !std.meta.eql(self.settings, @as(?Settings, fresh));
        self.deinit(gpa, world, content);
        errdefer self.deinit(gpa, world, content);
        self.settings = fresh;
        self.model = try content.acquireModel(fresh.model);
        if (changed) {
            self.feet = fresh.waypoints[0];
            self.waypoint = 1;
            self.wait_ticks = 60;
            self.tick = 0;
            self.weight = 0;
            self.velocity = 0;
            self.yaw = 0;
            self.reached = 0;
            self.used_idle = false;
            self.used_walk = false;
            self.used_fade = false;
            self.hash = 0xcbf29ce484222325;
        }
        self.character = try world.addCharacter(gpa, .{
            .radius = 0.22,
            .height = 1.7,
            .max_slope = std.math.pi / 4.0,
            .step_height = 0.35,
            .snap_distance = 0.3,
            .max_move = 1,
            .layer = 2,
            .mask = 1,
        }, self.feet, 0);
        try self.evaluate(content, dt);
    }
    pub fn move(self: *Walker, gpa: std.mem.Allocator, world: *physics.World, dt: f32) !void {
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
                self.reached += 1;
                self.waypoint = (self.waypoint + 1) % s.len;
                self.wait_ticks = 60;
            } else horizontal = delta.scale(@min(distance, s.speed * dt) / distance);
        }
        self.velocity = @max(-20, self.velocity - 9.81 * dt);
        const result = (try world.moveCharacter(gpa, self.character, horizontal.add(.init(0, self.velocity * dt, 0)), &.{})) orelse return error.NoCharacter;
        if (result.stuck) return error.WalkerStuck;
        self.feet = result.feet;
        if (result.grounded) self.velocity = 0;
        const moved = self.feet.sub(before);
        const walking = moved.x * moved.x + moved.z * moved.z > 1e-10;
        if (walking) self.yaw = std.math.atan2(-moved.x, -moved.z);
        const by = dt / s.cross_fade;
        self.weight = std.math.clamp(self.weight + (if (walking) by else -by), 0, 1);
        self.tick += 1;
    }
    /// All payload borrows last only through this call, including converted track slices.
    pub fn evaluate(self: *Walker, content: *render3d.Content, dt: f32) !void {
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
        self.used_idle = self.used_idle or self.weight == 0;
        self.used_walk = self.used_walk or self.weight == 1;
        self.used_fade = self.used_fade or (self.weight > 0 and self.weight < 1);
    }
    pub fn record(self: *Walker) void {
        // Hash fields, not struct padding. Every local TRS and matrix at every tick.
        for (self.pose[0..self.joint_count]) |p| {
            self.bytes(std.mem.asBytes(&p.translation));
            self.bytes(std.mem.asBytes(&p.rotation));
            self.bytes(std.mem.asBytes(&p.scale));
        }
        self.bytes(std.mem.sliceAsBytes(self.matrices[0..self.joint_count]));
        self.bytes(std.mem.asBytes(&self.feet));
        self.bytes(std.mem.asBytes(&self.weight));
    }
    fn bytes(self: *Walker, b: []const u8) void {
        for (b) |byte| self.hash = (self.hash ^ byte) *% 0x100000001b3;
    }
    pub fn proofPassed(self: *const Walker) bool {
        return self.tick == proof_ticks and self.reached >= 4 and self.used_idle and self.used_walk and self.used_fade and self.joint_count != 0;
    }
    pub fn draw(self: *const Walker, content: *render3d.Content, offset: Vec3) !void {
        if (self.joint_count == 0 or self.model.isNone()) return;
        try content.drawModel(.{ .model = self.model, .world = Mat4.trs(self.feet.add(offset), Quat.fromAxisAngle(.up, self.yaw), .one), .skin = self.matrices[0..self.joint_count] });
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
