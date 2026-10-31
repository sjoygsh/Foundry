//! M24's sample-owned patrol, played by an `anim.Player` through `asset.Rigs` since M34. Retain
//! handles, never a rig or an asset's payload.
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
    set: core.ContentId,
    waypoints: [max_points]Vec3 = @splat(.zero),
    len: usize = 0,
    speed: f32,
    cross_fade: f32,
    pub const max_points = 16;
    pub fn read(fields: data.fpk.Fields) !Settings {
        var out: Settings = .{
            .model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidWalker,
            .set = (try fields.idAt(try index(fields, "set"))) orelse return error.InvalidWalker,
            .speed = @floatCast((try fields.floatAt(try index(fields, "speed"))) orelse return error.InvalidWalker),
            .cross_fade = @floatCast((try fields.floatAt(try index(fields, "cross_fade"))) orelse return error.InvalidWalker),
        };
        if (out.model.isNone() or out.set.isNone() or !std.math.isFinite(out.speed) or out.speed <= 0 or out.speed > 6 or
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

const idle_clip = anim.clipName("idle");
const walk_clip = anim.clipName("walk");

pub const Walker = struct {
    settings: ?Settings = null,
    model: render3d.ModelHandle = .none,
    rig: asset.RigHandle = .none,
    character: physics.CharacterHandle = .none,
    feet: Vec3 = .zero,
    yaw: f32 = 0,
    velocity: f32 = 0,
    tick: u64 = 0,
    waypoint: usize = 1,
    wait_ticks: u32 = 60,
    player: anim.Player = .{},
    joint_count: usize = 0,
    scratch: [anim.max_joints]Transform = undefined,
    pose: [anim.max_joints]Transform = undefined,
    matrices: [anim.max_joints]Mat4 = undefined,
    reached: u32 = 0,
    used_idle: bool = false,
    used_walk: bool = false,
    used_fade: bool = false,
    hash: u64 = 0xcbf29ce484222325,
    pub const proof_ticks = 2100;

    pub fn deinit(self: *Walker, gpa: std.mem.Allocator, world: *physics.World, content: *render3d.Content, rigs: *asset.Rigs) void {
        if (!self.character.isNone()) _ = world.removeCharacter(gpa, self.character);
        if (!self.model.isNone()) content.releaseModel(self.model);
        if (!self.rig.isNone()) rigs.release(self.rig);
        self.character = .none;
        self.model = .none;
        self.rig = .none;
        self.joint_count = 0;
    }
    /// At the generation seam, after `rigs.contentChanged`: take the rig again and rebuild the
    /// pose. Preserve playback/feet when the record is unchanged. Any refusal disables, and a
    /// rig is never kept past the seam.
    pub fn refresh(self: *Walker, gpa: std.mem.Allocator, store: *const data.Store, world: *physics.World, content: *render3d.Content, rigs: *asset.Rigs) !void {
        const entry = store.lookup(core.ContentId.fromString("sandbox3d:walker.main")) orelse {
            self.deinit(gpa, world, content, rigs);
            self.settings = null;
            return error.MissingWalker;
        };
        const fresh = Settings.read(entry.fields) catch |err| {
            self.deinit(gpa, world, content, rigs);
            self.settings = null;
            return err;
        };
        const changed = !std.meta.eql(self.settings, @as(?Settings, fresh));
        self.deinit(gpa, world, content, rigs);
        errdefer self.deinit(gpa, world, content, rigs);
        self.settings = fresh;
        self.model = try content.acquireModel(fresh.model);
        self.rig = try rigs.acquire(fresh.set);
        const rig = rigs.get(self.rig) orelse return error.MissingRig;
        if (rig.find(idle_clip) == null) return error.MissingIdle;
        if (rig.find(walk_clip) == null) return error.MissingWalk;
        if (changed) {
            self.feet = fresh.waypoints[0];
            self.waypoint = 1;
            self.wait_ticks = 60;
            self.tick = 0;
            try self.player.play(rig.*, idle_clip, .{});
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
        try self.evaluate(rigs);
    }
    pub fn move(self: *Walker, gpa: std.mem.Allocator, world: *physics.World, rigs: *const asset.Rigs, dt: f32) !void {
        const s = self.settings orelse return;
        if (self.character.isNone()) return;
        const rig = rigs.get(self.rig) orelse return error.MissingRig;
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
        const wanted = if (walking) walk_clip else idle_clip;
        if (!self.player.playing(wanted)) try self.player.play(rig.*, wanted, .{ .fade = s.cross_fade, .phase = .keep });
        // Its clips carry no events and no motion, and a refresh made sure of both of them.
        var step: anim.Step = undefined;
        self.player.advance(rig.*, dt, &step);
        self.tick += 1;
    }
    /// The pose, a function of the player and the rig alone.
    pub fn evaluate(self: *Walker, rigs: *const asset.Rigs) !void {
        if (self.rig.isNone()) return;
        errdefer self.joint_count = 0;
        const rig = rigs.get(self.rig) orelse return error.MissingRig;
        const n = rig.skeleton.jointCount();
        const scratch: anim.Pose = .{ .local = self.scratch[0..n] };
        const pose: anim.Pose = .{ .local = self.pose[0..n] };
        self.player.evaluate(rig.*, scratch, pose);
        anim.skinMatrices(rig.skeleton, pose, self.matrices[0..n]);
        self.joint_count = n;
        const weight = self.walkWeight();
        self.used_idle = self.used_idle or weight == 0;
        self.used_walk = self.used_walk or weight == 1;
        self.used_fade = self.used_fade or (weight > 0 and weight < 1);
    }
    /// How far between idle and walk the figure is.
    pub fn walkWeight(self: *const Walker) f32 {
        for (self.player.channels) |channel| {
            if (channel.clip == walk_clip) return channel.weight;
        }
        return 0;
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
        const weight = self.walkWeight();
        self.bytes(std.mem.asBytes(&weight));
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
