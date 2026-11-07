//! M34's pacer (`animation-logic.md` §10): the sample's first skinned entity, and a figure that
//! saves. Since M35 it plays a machine (`animation-states.md` §13).
//!
//! **Its speed and every corner come from its clips, and what it plays from its machine.**
//! `sandbox3d:pacer.machine` plays `stride` for a lap and a half of the clip as authored, cuts to
//! `turn`, and fades back across a finished turn, while an additive layer turns the head. That is
//! what this file decided in M34, and the replay pins prove it. This file keeps only the body: root
//! motion carried out through the controller. Nothing here says a distance, so a mod that doubles
//! `stride`'s speed widens the square, and one that restates the machine changes the walk, with no
//! code.
//!
//! **A save from before the machine still loads.** Its animator names none, so `refresh` gives it
//! the pacer's and puts the base layer where M34's `turning` and `ticks` had it. The figure carries
//! on to the bit, and the head's layer fades in from nothing.
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

const stride_state = anim.clipName("stride");
const turn_state = anim.clipName("turn");
const turn_clip = anim.clipName("turn");
/// The machine a save from before machines plays. The content that defines it can be overridden.
pub const machine_id = core.ContentId.fromString("sandbox3d:pacer.machine");
/// More than this is a mistake, and a square that would leave the room anyway.
const max_strides: f32 = 64;
const max_fall: f32 = 20;
const gravity: f32 = 9.81;

pub const Pace = struct {
    pub const component = "sandbox3d:pacer";
    model: core.ContentId = .none,
    /// M34's: how long a side lasted, in `stride`s. The machine holds it now, and this stays for the
    /// shape of an older save.
    strides: f32 = 1,
    /// M34's: whether it was on a corner, read once from a save made before the machine.
    turning: bool = true,
    /// M34's: ticks along that side, read with `turning`.
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

pub const Error = error{ NoAnimator, NoPace, InvalidPacer, MissingRig, MissingMachine, NoMotionJoint };

pub const Figure = struct {
    entity: ?scene.Entity = null,
    rig: asset.RigHandle = .none,
    machine: asset.MachineHandle = .none,
    model: render3d.ModelHandle = .none,
    character: physics.CharacterHandle = .none,
    feet: Vec3 = .zero,
    joint_count: usize = 0,
    /// Three poses, since a stack mixes a layer over the base and a blend its clips.
    scratch: [3 * anim.max_joints]Transform = undefined,
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
        if (!self.machine.isNone()) rigs.releaseMachine(self.machine);
        if (!self.rig.isNone()) rigs.release(self.rig);
        self.character = .none;
        self.model = .none;
        self.machine = .none;
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
        if (rig.motion_joint == anim.no_parent) return error.NoMotionJoint;
        // Before the save is touched, so a refusal leaves it as it was.
        const id = if (animator.machine.isNone()) machine_id else animator.machine;
        self.machine = rigs.acquireMachine(animator.set, id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MissingMachine,
        };
        if (animator.machine.isNone()) adopt(animator, pace);
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

    /// One tick: advance through the machine, and carry out the move. The caller propagates.
    pub fn step(self: *Figure, gpa: std.mem.Allocator, world: *scene.World, walk: *physics.World, rigs: *const asset.Rigs, dt: f32) !void {
        const e = self.entity orelse return;
        if (self.character.isNone()) return;
        _ = rigs.get(self.rig) orelse return error.MissingRig;
        const machine = rigs.getMachine(self.machine) orelse return error.MissingMachine;
        const before = (animation.stack(world, e) orelse return error.NoAnimator).layers[0].state;

        var events: animation.Events = .{ .buffer = &self.fired };
        self.report = .{};
        const summary = try animation.advance(world, animation.rigSource(rigs), dt, .{ .events = &events, .report = &self.report });
        if (summary.unresolved != 0) return error.MissingMachine;
        for (events.fired()) |fired| {
            if (fired.event.eql(footfall)) self.footfalls += 1;
            self.bytes(std.mem.asBytes(&fired.event.hash));
        }

        // A structural change of the world can come out of `advance`, so read it again.
        const pace = paceOf(world, e) orelse return error.NoPace;
        // A corner is counted on the tick it ends, as M34 counted it: when the base leaves a state
        // that plays `turn`, whatever the machine calls it.
        const after = (animation.stack(world, e) orelse return error.NoAnimator).layers[0].state;
        if (after != before and playsTurn(machine.*, before)) pace.corners +%= 1;
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

    /// The machine it plays, for a game or a test to steer it by name.
    pub fn machineOf(self: *const Figure, rigs: *const asset.Rigs) ?*const anim.Machine {
        return rigs.getMachine(self.machine);
    }

    pub fn draw(self: *const Figure, world: *const scene.World, content: *render3d.Content) !void {
        const e = self.entity orelse return;
        if (self.joint_count == 0 or self.model.isNone()) return;
        const pose = hierarchy.worldTransform(world, e) orelse return;
        try content.drawModel(.{ .model = self.model, .world = pose, .skin = self.matrices[0..self.joint_count] });
    }
};

pub const footfall = core.ContentId.fromString("sandbox3d:event.footfall");

/// A save from before machines: the animator gets the pacer's, and the base layer goes where M34's
/// timing had it. M34 counted a side's ticks from the one after it began, and a machine counts the one
/// it began on, so a side in progress is one tick further on (`animation-states.md`, Step 8's
/// Resolution). Its player is left alone, so the pose carries on; the base's newest clip is what
/// the state names.
fn adopt(animator: *animation.Animator, pace: *const Pace) void {
    animator.machine = machine_id;
    animator.s0 = .{
        .weight = 1,
        .target = 1,
        .state = if (pace.turning) turn_state else stride_state,
        .ticks = if (pace.turning) 0 else @as(u64, pace.ticks) + 1,
    };
}

fn playsTurn(machine: anim.Machine, state: u64) bool {
    if (machine.layers.len == 0) return false;
    const found = machine.layers[0].state(state) orelse return false;
    return found.clip == turn_clip;
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
