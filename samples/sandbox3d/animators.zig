//! M34's 32-animator cost run (`animation-logic.md` §13): `FOUNDRY_SANDBOX3D_ANIMATORS=32`.
//!
//! **What it measures is `scene.animation.advance` alone, over 32 animators, with no pose.** They
//! live in a world of their own, so the pacer's events, report and save stay as they are. Since M35
//! each plays the pacer's machine with both its layers (`animation-states.md` §13, §16), so they
//! cost what a figure's machine costs. Each is primed by its own number of ticks, so their corners
//! and events do not all fall on one tick. Nothing draws, evaluates or saves them: a pose is the
//! `animation` line's budget, and this is the one before it.

const std = @import("std");

const anim = @import("anim");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const scene = @import("scene");

const animation = scene.animation;

pub const count = 32;
/// Ticks between one animator's start and the next's: 32 of them spread over about two sides.
const spread = 9;

pub const Animators = struct {
    schemas: data.Registry = undefined,
    world: scene.World = undefined,
    rig: asset.RigHandle = .none,
    machine: asset.MachineHandle = .none,
    built: bool = false,
    /// Set when they could not be made; said once, and never tried again.
    failed: bool = false,

    /// Make the 32 the first time the pacer's set has a rig and its machine builds against it.
    pub fn start(self: *Animators, gpa: std.mem.Allocator, set: core.ContentId, machine: core.ContentId, rigs: *asset.Rigs, dt: f32) !void {
        self.schemas = .init(gpa, .default);
        errdefer self.schemas.deinit(gpa);
        self.world = .init(gpa, &self.schemas, .default);
        errdefer self.world.deinit();
        const types = try self.world.enableAnimation();
        self.rig = try rigs.acquire(set);
        errdefer {
            rigs.release(self.rig);
            self.rig = .none;
        }
        self.machine = try rigs.acquireMachine(set, machine);
        errdefer {
            rigs.releaseMachine(self.machine);
            self.machine = .none;
        }
        const rig = rigs.get(self.rig) orelse return error.MissingRig;
        const steering = rigs.getMachine(self.machine) orelse return error.MissingMachine;
        if (steering.layers.len < 2) return error.OneLayer;
        for (0..count) |i| {
            const e = try self.world.create();
            const initial: animation.Animator = .{ .set = set, .machine = machine };
            _ = try self.world.addComponent(e, types.animator, std.mem.asBytes(&initial));
            const stack = animation.stack(&self.world, e).?;
            var step: anim.Step = .{};
            for (0..i * spread) |_| anim.machine.advance(stack, rig.*, steering.*, dt, &step);
        }
        self.built = true;
    }

    /// One tick of all 32, which is what the span around it measures.
    pub fn tick(self: *Animators, rigs: *const asset.Rigs, dt: f32) !animation.Summary {
        return animation.advance(&self.world, animation.rigSource(rigs), dt, .{});
    }

    pub fn deinit(self: *Animators, gpa: std.mem.Allocator, rigs: *asset.Rigs) void {
        if (!self.built) return;
        rigs.releaseMachine(self.machine);
        rigs.release(self.rig);
        self.world.deinit();
        self.schemas.deinit(gpa);
        self.* = .{};
    }
};
