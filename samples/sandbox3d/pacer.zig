//! M34's pacer (`animation-logic.md` §10): the sample's first skinned entity, and a figure that
//! saves.
//!
//! **Its speed and every corner come from its clips.** It plays `stride` for a time, plays `turn`,
//! and repeats, and its record says how long a side lasts in strides of the clip as authored. It
//! never says a distance, so a mod that doubles `stride`'s speed widens the square with no code.
//!
//! **Everything that is state is in the world.** `Pace` and `foundry:animator` save with the
//! orrery, and `foundry:transform` holds its feet. So `Figure` only holds what a load can make
//! again: handles, a pose, and the character in the walk world.

const std = @import("std");

const anim = @import("anim");
const asset = @import("asset");
const core = @import("core");
const physics = @import("physics3d");
const render3d = @import("render3d");
const scene = @import("scene");

const animation = scene.animation;
const hierarchy = scene.hierarchy;
const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;

const stride_clip = anim.clipName("stride");
const turn_clip = anim.clipName("turn");
/// Off a corner, across a clip the turn has finished. A fade into a turn would lose some of it.
const fade_seconds: f32 = 0.1;
/// More than this is a mistake, and a square that would leave the room anyway.
const max_strides: f32 = 64;
const max_fall: f32 = 20;
const gravity: f32 = 9.81;

pub const Pace = struct {
    pub const component = "sandbox3d:pacer";
    model: core.ContentId = .none,
    /// How long a side lasts, in `stride`s of the clip as authored.
    strides: f32 = 1,
    /// A figure begins on a corner, so that every side starts the same way.
    turning: bool = true,
    /// Ticks along this side.
    ticks: u32 = 0,
    corners: u32 = 0,
    yaw: f32 = 0,
    velocity: f32 = 0,

    /// A save is untrusted, and only these can reach the arithmetic.
    fn usable(self: *const Pace) bool {
        return std.math.isFinite(self.strides) and self.strides > 0 and self.strides <= max_strides and
            std.math.isFinite(self.yaw) and std.math.isFinite(self.velocity) and @abs(self.velocity) <= max_fall;
    }
};

pub const Error = error{ NoAnimator, NoPace, InvalidPacer, MissingRig, MissingStride, MissingTurn, TurnLoops, NoMotionJoint };

pub const Figure = struct {
    entity: ?scene.Entity = null,
    rig: asset.RigHandle = .none,
    model: render3d.ModelHandle = .none,
    character: physics.CharacterHandle = .none,
    feet: Vec3 = .zero,
    joint_count: usize = 0,
    scratch: [anim.max_joints]Transform = undefined,
    pose: [anim.max_joints]Transform = undefined,
    matrices: [anim.max_joints]Mat4 = undefined,
    fired: [anim.max_step_events]animation.Fired = undefined,
    /// This tick's, for the overlay.
    report: anim.Report = .{},
    /// This tick's move, as the controller was asked.
    motion: anim.Motion = .{},
    ticks: u64 = 0,
    footfalls: u32 = 0,
    hash: u64 = hash_seed,

    pub const hash_seed: u64 = 0xcbf29ce484222325;

    pub fn deinit(self: *Figure, gpa: std.mem.Allocator, walk: *physics.World, content: ?*render3d.Content, rigs: *asset.Rigs) void {
        if (!self.character.isNone()) _ = walk.removeCharacter(gpa, self.character);
        if (!self.model.isNone()) if (content) |c| c.releaseModel(self.model);
        if (!self.rig.isNone()) rigs.release(self.rig);
        self.character = .none;
        self.model = .none;
        self.rig = .none;
        self.joint_count = 0;
    }

    /// At the generation seam and after a load: takes the rig and the model again, and stands a
    /// character at the entity's feet. What it does not touch is the world, which is why playback
    /// carries on across a reload.
    pub fn refresh(self: *Figure, gpa: std.mem.Allocator, world: *scene.World, entity: ?scene.Entity, walk: *physics.World, content: ?*render3d.Content, rigs: *asset.Rigs) !void {
        self.deinit(gpa, walk, content, rigs);
        errdefer self.deinit(gpa, walk, content, rigs);
        self.entity = entity;
        const e = entity orelse return;
        const pace = paceOf(world, e) orelse return error.NoPace;
        if (!pace.usable()) return error.InvalidPacer;
        const animator = animation.animatorOf(world, e) orelse return error.NoAnimator;
        self.rig = try rigs.acquire(animator.set);
        const rig = rigs.get(self.rig) orelse return error.MissingRig;
        if (rig.find(stride_clip) == null) return error.MissingStride;
        const turn = rig.find(turn_clip) orelse return error.MissingTurn;
        // `finished` is what ends a corner, and a loop never finishes.
        if (turn.loop) return error.TurnLoops;
        if (rig.motion_joint == anim.no_parent) return error.NoMotionJoint;
        if (content) |c| self.model = try c.acquireModel(pace.model);

        const transform = transformOf(world, e) orelse return error.NoPace;
        self.character = try walk.addCharacter(gpa, .{
            .radius = 0.22,
            .height = 1.7,
            .max_slope = std.math.pi / 4.0,
            .step_height = 0.35,
            .snap_distance = 0.3,
            .max_move = 1,
            .layer = 2,
            .mask = 1,
        }, transform.translation, 0);
        self.feet = transform.translation;
        try self.evaluate(world, rigs);
    }

    /// One tick: decide what to play, advance, and carry out the move. The caller propagates.
    pub fn step(self: *Figure, gpa: std.mem.Allocator, world: *scene.World, walk: *physics.World, rigs: *const asset.Rigs, dt: f32) !void {
        const e = self.entity orelse return;
        if (self.character.isNone()) return;
        const rig = rigs.get(self.rig) orelse return error.MissingRig;
        try decide(paceOf(world, e) orelse return error.NoPace, animation.player(world, e) orelse return error.NoAnimator, rig, dt);

        var events: animation.Events = .{ .buffer = &self.fired };
        self.report = .{};
        _ = try animation.advance(world, animation.rigSource(rigs), dt, .{ .events = &events, .report = &self.report });
        for (events.fired()) |fired| {
            if (fired.event.eql(footfall)) self.footfalls += 1;
            self.bytes(std.mem.asBytes(&fired.event.hash));
        }

        // A structural change of the world can come out of `advance`, so read it again.
        const pace = paceOf(world, e) orelse return error.NoPace;
        const wish = animation.motionOf(world, e) orelse animation.RootMotion{};
        self.motion = .{ .translation = wish.translation, .yaw = wish.yaw };
        pace.velocity = @max(-max_fall, pace.velocity - gravity * dt);
        const along = Quat.fromAxisAngle(.up, pace.yaw).rotate(wish.translation);
        const result = (try walk.moveCharacter(gpa, self.character, along.add(.init(0, pace.velocity * dt, 0)), &.{})) orelse return error.NoPace;
        self.feet = result.feet;
        if (result.grounded) pace.velocity = 0;
        pace.yaw = @mod(pace.yaw + wish.yaw, 2 * std.math.pi);

        const transform = transformOf(world, e) orelse return error.NoPace;
        transform.translation = result.feet;
        transform.rotation = Quat.fromAxisAngle(.up, pace.yaw);
        self.ticks += 1;
    }

    /// The pose, a function of the world and the rig alone.
    pub fn evaluate(self: *Figure, world: *scene.World, rigs: *const asset.Rigs) !void {
        const e = self.entity orelse return;
        errdefer self.joint_count = 0;
        const rig = rigs.get(self.rig) orelse return error.MissingRig;
        const n = animation.evaluate(world, e, animation.rigSource(rigs), &self.scratch, &self.pose) orelse return error.NoAnimator;
        anim.skinMatrices(rig.skeleton, .{ .local = self.pose[0..n] }, self.matrices[0..n]);
        self.joint_count = n;
    }

    /// Pose, feet, motion and heading. Events go in as `step` sees them.
    pub fn record(self: *Figure, world: *const scene.World) void {
        for (self.pose[0..self.joint_count]) |p| {
            self.bytes(std.mem.asBytes(&p.translation));
            self.bytes(std.mem.asBytes(&p.rotation));
            self.bytes(std.mem.asBytes(&p.scale));
        }
        self.bytes(std.mem.sliceAsBytes(self.matrices[0..self.joint_count]));
        self.bytes(std.mem.asBytes(&self.feet));
        self.bytes(std.mem.asBytes(&self.motion.translation));
        self.bytes(std.mem.asBytes(&self.motion.yaw));
        const e = self.entity orelse return;
        const pace = paceOf(@constCast(world), e) orelse return;
        self.bytes(std.mem.asBytes(&pace.yaw));
    }

    fn bytes(self: *Figure, b: []const u8) void {
        for (b) |byte| self.hash = (self.hash ^ byte) *% 0x100000001b3;
    }

    pub fn draw(self: *const Figure, world: *const scene.World, content: *render3d.Content) !void {
        const e = self.entity orelse return;
        if (self.joint_count == 0 or self.model.isNone()) return;
        const pose = hierarchy.worldTransform(world, e) orelse return;
        try content.drawModel(.{ .model = self.model, .world = pose, .skin = self.matrices[0..self.joint_count] });
    }
};

pub const footfall = core.ContentId.fromString("sandbox3d:event.footfall");

/// What to play this tick, before it advances. A side is timed against the clip as authored, so a
/// faster `stride` covers more ground. A corner is a cut, since both clips begin on one foot's
/// passing and a fade would lose part of the turn, and it leaves by a fade across a finished clip.
fn decide(pace: *Pace, player: *anim.Player, rig: *const anim.Rig, dt: f32) !void {
    if (pace.turning) {
        if (!player.playing(turn_clip)) {
            try player.play(rig.*, turn_clip, .{});
        } else if (player.finished(rig.*)) {
            pace.turning = false;
            pace.ticks = 0;
            pace.corners +%= 1;
            try player.play(rig.*, stride_clip, .{ .fade = fade_seconds });
        }
        return;
    }
    if (!player.playing(stride_clip)) try player.play(rig.*, stride_clip, .{ .fade = fade_seconds });
    pace.ticks +|= 1;
    const duration = rig.find(stride_clip).?.clip.duration;
    if (@as(f32, @floatFromInt(pace.ticks)) * dt >= pace.strides * duration) {
        pace.turning = true;
        try player.play(rig.*, turn_clip, .{});
    }
}

fn transformOf(world: *scene.World, entity: scene.Entity) ?*hierarchy.Transform {
    const id = world.findComponent(scene.query.schemaIdOf(hierarchy.Transform)) orelse return null;
    const value = world.getComponent(entity, id) orelse return null;
    return @ptrCast(@alignCast(value.ptr));
}

fn paceOf(world: *scene.World, entity: scene.Entity) ?*Pace {
    const id = world.findComponent(scene.query.schemaIdOf(Pace)) orelse return null;
    const value = world.getComponent(entity, id) orelse return null;
    return @ptrCast(@alignCast(value.ptr));
}

pub fn paceIn(world: *scene.World, entity: scene.Entity) ?*Pace {
    return paceOf(world, entity);
}
