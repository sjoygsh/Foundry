//! `animation-states.md` §16's `anim` tests for M35 Step 3: the machine, its parameters,
//! conditions and tick order, and its replay. No device, no asset and no allocator under test.

const std = @import("std");
const core = @import("core");

const clip_mod = @import("clip.zig");
const machine_mod = @import("machine.zig");
const player_mod = @import("player.zig");
const rig_mod = @import("rig.zig");
const skeleton_mod = @import("skeleton.zig");
const stack_mod = @import("stack.zig");

const Clip = clip_mod.Clip;
const Condition = machine_mod.Condition;
const ContentId = core.ContentId;
const Event = rig_mod.Event;
const Machine = machine_mod.Machine;
const MachineLayer = machine_mod.MachineLayer;
const Mask = rig_mod.Mask;
const Mat4 = core.math.Mat4;
const ParamDef = machine_mod.ParamDef;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;
const Skeleton = skeleton_mod.Skeleton;
const Stack = stack_mod.Stack;
const State = machine_mod.State;
const Step = player_mod.Step;
const Track = clip_mod.Track;
const Transform = core.math.Transform;
const Transition = machine_mod.Transition;

const clipName = rig_mod.clipName;
const no_parent = skeleton_mod.no_parent;
const t = std.testing;
const dt: f32 = 1.0 / 60.0;

// ---------------------------------------------------------------------------------------------
// Fixtures: the skeleton of `stack_tests.zig`, and a warden's clips.

const pelvis = 0;
const spine = 1;
const chest = 2;
const leg = 3;
const joints = 4;

const parents = [_]u16{ no_parent, pelvis, spine, pelvis };
const rest = [_]Transform{
    .{ .translation = .init(0, 0.9, 0) },
    .{ .translation = .init(0, 0.25, 0) },
    .{ .translation = .init(0, 0.25, 0) },
    .{ .translation = .init(0, -0.5, 0) },
};
const inverse_bind: [joints]Mat4 = @splat(Mat4.identity);
const skeleton: Skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &inverse_bind };

const ends = [_]f32{ 0, 1 };
const thirds = [_]f32{ 0, 0.5, 1 };
const leg_values = [_]f32{ 0, -0.5, 0, 0.2, -0.5, 0 };

/// 0.6 m a lap: 0.6 m/s.
const walk_values = [_]f32{ 0, 0.9, 0, 0, 0.9, -0.6 };
const walk_tracks = [_]Track{
    .{ .joint = pelvis, .path = .translation, .times = &ends, .values = &walk_values },
    .{ .joint = leg, .path = .translation, .times = &ends, .values = &leg_values },
};
const walk_clip: Clip = .{ .duration = 1, .tracks = &walk_tracks };

/// 1.3 m in 0.7 s.
const run_times = [_]f32{ 0, 0.7 };
const run_values = [_]f32{ 0, 0.9, 0, 0, 0.9, -1.3 };
const run_tracks = [_]Track{.{ .joint = pelvis, .path = .translation, .times = &run_times, .values = &run_values }};
const run_clip: Clip = .{ .duration = 0.7, .tracks = &run_tracks };

const idle_tracks = [_]Track{.{ .joint = leg, .path = .translation, .times = &ends, .values = &leg_values }};
const idle_clip: Clip = .{ .duration = 1, .tracks = &idle_tracks };

const s90: f32 = 0.70710678;
const bow = [_]f32{ s90, 0, 0, s90, s90, 0, 0, s90 };
const reach_tracks = [_]Track{.{ .joint = chest, .path = .rotation, .times = &ends, .values = &bow }};
const reach_clip: Clip = .{ .duration = 1, .tracks = &reach_tracks };

const heave = [_]f32{ 0, 0.25, 0, 0, 0.35, 0, 0, 0.25, 0 };
const pant_tracks = [_]Track{.{ .joint = chest, .path = .translation, .times = &thirds, .values = &heave }};
const pant_clip: Clip = .{ .duration = 1, .tracks = &pant_tracks };

/// A quarter turn about +Y, as the pacer's corner.
const turn_values = [_]f32{ 0, 0, 0, 1, 0, s90, 0, s90 };
const turn_tracks = [_]Track{.{ .joint = pelvis, .path = .rotation, .times = &ends, .values = &turn_values }};
const turn_clip: Clip = .{ .duration = 1, .tracks = &turn_tracks };

/// A crouch and reach, played across a link.
const jump_times = [_]f32{ 0, 0.8 };
const jump_tracks = [_]Track{.{ .joint = leg, .path = .translation, .times = &jump_times, .values = &leg_values }};
const jump_clip: Clip = .{ .duration = 0.8, .tracks = &jump_tracks };

const foot = ContentId.fromString("test:event.foot");
const land = ContentId.fromString("test:event.land");
const walk_events = [_]Event{ .{ .at = 0, .id = foot }, .{ .at = 0.5, .id = foot } };
const jump_events = [_]Event{.{ .at = 1, .id = land }};

const feet = clipName("feet");
const c_walk = clipName("walk");
const c_run = clipName("run");
const c_idle = clipName("idle");
const c_reach = clipName("reach");
const c_pant = clipName("pant");
const c_turn = clipName("turn");
const c_jump = clipName("jump");
const upper = clipName("upper");

fn lessName(_: void, a: RigClip, b: RigClip) bool {
    return a.name < b.name;
}

const clips = blk: {
    @setEvalBranchQuota(100_000);
    var out = [_]RigClip{
        .{ .name = c_walk, .clip = walk_clip, .motion = true, .sync = feet, .events = &walk_events, .label = "walk" },
        .{ .name = c_run, .clip = run_clip, .motion = true, .sync = feet, .label = "run" },
        .{ .name = c_idle, .clip = idle_clip, .label = "idle" },
        .{ .name = c_reach, .clip = reach_clip, .label = "reach" },
        .{ .name = c_pant, .clip = pant_clip, .additive = true, .reference = &rest, .label = "pant" },
        .{ .name = c_turn, .clip = turn_clip, .motion = true, .loop = false, .label = "turn" },
        .{ .name = c_jump, .clip = jump_clip, .loop = false, .events = &jump_events, .label = "jump" },
    };
    std.mem.sort(RigClip, &out, {}, lessName);
    break :blk out;
};
const upper_weights = [_]f32{ 0, 1, 1, 0 };
const masks = [_]Mask{.{ .name = upper, .weights = &upper_weights }};
const rig: Rig = .{ .skeleton = skeleton, .clips = &clips, .start = c_idle, .motion_joint = pelvis, .masks = &masks };

// The warden's machine, as §10 writes it.

const p_speed = clipName("speed");
const p_link = clipName("link");
const p_link_t = clipName("link_t");
const p_near = clipName("near");
const p_winded = clipName("winded");

const s_idle = clipName("idle");
const s_walk = clipName("walk");
const s_run = clipName("run");
const s_jump = clipName("jump");
const s_reach = clipName("reach");
const s_pant = clipName("pant");

const params = [_]ParamDef{
    .{ .name = p_speed, .label = "speed" },
    .{ .name = p_link, .label = "link" },
    .{ .name = p_link_t, .label = "link_t" },
    .{ .name = p_near, .label = "near" },
    .{ .name = p_winded, .label = "winded" },
};

fn when(param: u64, compare: machine_mod.Compare, value: f32) Condition {
    return .{ .quantity = .param, .param = param, .compare = compare, .value = value };
}

const body_states = [_]State{
    .{ .name = s_idle, .clip = c_idle, .label = "idle" },
    .{ .name = s_walk, .clip = c_walk, .speed_param = p_speed, .label = "walk" },
    .{ .name = s_run, .clip = c_run, .speed_param = p_speed, .label = "run" },
    .{ .name = s_jump, .clip = c_jump, .seek_param = p_link_t, .label = "jump" },
};
const body_transitions = [_]Transition{
    .{ .from = machine_mod.any_state, .to = s_jump, .fade = 0.1, .conditions = &.{when(p_link, .is, 1)} },
    .{ .from = s_jump, .to = s_idle, .fade = 0.2, .conditions = &.{when(p_link, .is, 0)} },
    .{ .from = s_idle, .to = s_walk, .fade = 0.25, .phase = .keep, .conditions = &.{when(p_speed, .at_least, 0.05)} },
    .{ .from = s_walk, .to = s_run, .fade = 0.3, .phase = .keep, .conditions = &.{when(p_speed, .at_least, 1.8)} },
    .{ .from = s_run, .to = s_walk, .fade = 0.3, .phase = .keep, .conditions = &.{when(p_speed, .below, 1.6)} },
    .{ .from = s_walk, .to = s_idle, .fade = 0.25, .conditions = &.{when(p_speed, .below, 0.05)} },
};
const layers = [_]MachineLayer{
    .{ .entry = s_idle, .states = &body_states, .transitions = &body_transitions, .label = "body" },
    .{ .spec = .{ .mask = upper, .fade = 0.3 }, .weight_param = p_near, .entry = s_reach, .states = &.{.{ .name = s_reach, .clip = c_reach }}, .label = "arms" },
    .{ .spec = .{ .mode = .additive, .fade = 1.5 }, .weight_param = p_winded, .entry = s_pant, .states = &.{.{ .name = s_pant, .clip = c_pant }}, .label = "breath" },
};
const warden: Machine = .{ .params = &params, .layers = &layers };

fn tick(stack: *Stack, machine: Machine, ticks: usize) Step {
    var step: Step = .{};
    for (0..ticks) |_| machine_mod.advance(stack, rig, machine, dt, &step);
    return step;
}

// ---------------------------------------------------------------------------------------------
// Validation

test "validate: the warden's machine passes, and every refusal is named" {
    try rig.validate();
    try warden.validate(rig);

    const idle_only = [_]State{.{ .name = s_idle, .clip = c_idle }};
    const one = [_]MachineLayer{.{ .entry = s_idle, .states = &idle_only }};
    const Case = struct { machine: Machine, err: anyerror };
    const eight_more: [9]ParamDef = blk: {
        var out: [9]ParamDef = undefined;
        for (&out, 0..) |*p, i| p.* = .{ .name = 100 + i };
        break :blk out;
    };
    const many_states: [33]State = blk: {
        var out: [33]State = undefined;
        for (&out, 0..) |*s, i| s.* = .{ .name = 100 + i, .clip = c_idle };
        break :blk out;
    };
    const many_transitions: [65]Transition = @splat(.{ .from = s_idle, .to = s_idle });
    const five: [5]Condition = @splat(when(p_speed, .is, 0));
    const cases = [_]Case{
        .{ .machine = .{ .params = &eight_more, .layers = &one }, .err = error.TooManyParams },
        .{ .machine = .{ .params = &.{.{ .name = 0 }}, .layers = &one }, .err = error.UnnamedParam },
        .{ .machine = .{ .params = &.{ .{ .name = p_speed }, .{ .name = p_speed } }, .layers = &one }, .err = error.DuplicateParam },
        .{ .machine = .{ .params = &.{.{ .name = p_speed, .default = std.math.nan(f32) }}, .layers = &one }, .err = error.InvalidParam },
        .{ .machine = .{ .layers = &.{} }, .err = error.NoLayers },
        .{ .machine = .{ .layers = &.{ one[0], one[0], one[0], one[0] } }, .err = error.TooManyLayers },
        .{ .machine = .{ .layers = &.{.{ .spec = .{ .mode = .additive }, .entry = s_pant, .states = &.{.{ .name = s_pant, .clip = c_pant }} }} }, .err = error.AdditiveBase },
        .{ .machine = .{ .layers = &.{.{ .spec = .{ .mask = upper }, .entry = s_idle, .states = &idle_only }} }, .err = error.MaskOnBase },
        .{ .machine = .{ .layers = &.{ one[0], .{ .spec = .{ .mask = 77 }, .entry = s_idle, .states = &idle_only } } }, .err = error.UnknownMask },
        .{ .machine = .{ .layers = &.{ one[0], .{ .spec = .{ .fade = -1 }, .entry = s_idle, .states = &idle_only } } }, .err = error.InvalidFade },
        .{ .machine = .{ .params = &params, .layers = &.{.{ .weight_param = p_near, .entry = s_idle, .states = &idle_only }} }, .err = error.WeightOnBase },
        .{ .machine = .{ .layers = &.{ one[0], .{ .weight_param = p_near, .entry = s_idle, .states = &idle_only } } }, .err = error.UnknownParam },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &.{} }} }, .err = error.NoStates },
        .{ .machine = .{ .layers = &.{.{ .entry = 100, .states = &many_states }} }, .err = error.TooManyStates },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &.{.{ .name = 0, .clip = c_idle }} }} }, .err = error.UnnamedState },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &.{ idle_only[0], idle_only[0] } }} }, .err = error.DuplicateState },
        .{ .machine = .{ .layers = &.{.{ .entry = s_walk, .states = &idle_only }} }, .err = error.NoEntry },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &.{.{ .name = s_idle, .clip = 77 }} }} }, .err = error.UnknownClip },
        .{ .machine = .{ .layers = &.{.{ .entry = s_pant, .states = &.{.{ .name = s_pant, .clip = c_pant }} }} }, .err = error.AdditiveMismatch },
        .{ .machine = .{ .layers = &.{ one[0], .{ .spec = .{ .mode = .additive }, .entry = s_reach, .states = &.{.{ .name = s_reach, .clip = c_reach }} } } }, .err = error.AdditiveMismatch },
        .{ .machine = .{ .layers = &.{ one[0], .{ .entry = s_walk, .states = &.{.{ .name = s_walk, .clip = c_walk }} } } }, .err = error.MotionOffBase },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &.{.{ .name = s_idle, .clip = c_idle, .speed = 17 }} }} }, .err = error.InvalidSpeed },
        .{ .machine = .{ .params = &params, .layers = &.{.{ .entry = s_walk, .states = &.{.{ .name = s_walk, .clip = c_walk, .speed_param = p_speed, .seek_param = p_link_t }} }} }, .err = error.SpeedAndSeek },
        .{ .machine = .{ .params = &params, .layers = &.{.{ .entry = s_idle, .states = &.{.{ .name = s_idle, .clip = c_idle, .speed_param = p_speed }} }} }, .err = error.NoMotionSpeed },
        .{ .machine = .{ .layers = &.{.{ .entry = s_walk, .states = &.{.{ .name = s_walk, .clip = c_walk, .speed_param = p_speed }} }} }, .err = error.UnknownParam },
        .{ .machine = .{ .layers = &.{.{ .entry = s_jump, .states = &.{.{ .name = s_jump, .clip = c_jump, .seek_param = p_link_t }} }} }, .err = error.UnknownParam },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &idle_only, .transitions = &many_transitions }} }, .err = error.TooManyTransitions },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &idle_only, .transitions = &.{.{ .from = s_walk, .to = s_idle }} }} }, .err = error.UnknownState },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &idle_only, .transitions = &.{.{ .from = s_idle, .to = s_walk }} }} }, .err = error.UnknownState },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &idle_only, .transitions = &.{.{ .from = s_idle, .to = s_idle, .fade = -1 }} }} }, .err = error.InvalidFade },
        .{ .machine = .{ .params = &params, .layers = &.{.{ .entry = s_idle, .states = &idle_only, .transitions = &.{.{ .from = s_idle, .to = s_idle, .conditions = &five }} }} }, .err = error.TooManyConditions },
        .{ .machine = .{ .params = &params, .layers = &.{.{ .entry = s_idle, .states = &idle_only, .transitions = &.{.{ .from = s_idle, .to = s_idle, .conditions = &.{when(p_speed, .is, std.math.inf(f32))} }} }} }, .err = error.InvalidCondition },
        .{ .machine = .{ .layers = &.{.{ .entry = s_idle, .states = &idle_only, .transitions = &.{.{ .from = s_idle, .to = s_idle, .conditions = &.{when(p_speed, .is, 0)} }} }} }, .err = error.UnknownParam },
    };
    for (cases, 0..) |case, i| {
        case.machine.validate(rig) catch |err| {
            if (err != case.err) {
                std.debug.print("case {d}: expected {s}, found {s}\n", .{ i, @errorName(case.err), @errorName(err) });
                return error.TestExpectedError;
            }
            continue;
        };
        std.debug.print("case {d}: expected {s}, and it passed\n", .{ i, @errorName(case.err) });
        return error.TestExpectedError;
    }
}

// ---------------------------------------------------------------------------------------------
// Parameters

test "params: set and get by name, refusing a name or value it cannot use" {
    var stack: Stack = .{};
    try t.expectEqual(@as(f32, 0), machine_mod.get(&stack, warden, p_speed).?);
    try machine_mod.set(&stack, warden, p_speed, 1.2);
    try t.expectEqual(@as(f32, 1.2), machine_mod.get(&stack, warden, p_speed).?);
    try t.expectError(error.UnknownParam, machine_mod.set(&stack, warden, clipName("absent"), 1));
    try t.expectError(error.UnknownParam, machine_mod.set(&stack, warden, 0, 1));
    try t.expectError(error.InvalidParam, machine_mod.set(&stack, warden, p_speed, std.math.nan(f32)));
    try t.expectEqual(@as(f32, 1.2), machine_mod.get(&stack, warden, p_speed).?);
    try t.expect(machine_mod.get(&stack, warden, clipName("absent")) == null);

    const defaulted = [_]ParamDef{.{ .name = p_speed, .default = 0.4 }};
    const one = [_]MachineLayer{.{ .entry = s_idle, .states = &.{.{ .name = s_idle, .clip = c_idle }} }};
    var fresh: Stack = .{};
    try t.expectEqual(@as(f32, 0.4), machine_mod.get(&fresh, .{ .params = &defaulted, .layers = &one }, p_speed).?);
}

test "params: a tick puts them in the machine's order by name, and drops and counts the rest" {
    var stack: Stack = .{};
    stack.params[0] = .{ .name = clipName("gone"), .value = 3 };
    stack.params[1] = .{ .name = p_winded, .value = 1 };
    stack.params[2] = .{ .name = p_speed, .value = 0.5 };
    const step = tick(&stack, warden, 1);
    try t.expectEqual(@as(u32, 1), step.params_dropped);
    try t.expectEqual(p_speed, stack.params[0].name);
    try t.expectEqual(@as(f32, 0.5), stack.params[0].value);
    try t.expectEqual(p_winded, stack.params[4].name);
    try t.expectEqual(@as(f32, 1), stack.params[4].value);
    try t.expectEqual(@as(u64, 0), stack.params[5].name);
    try t.expectEqual(@as(u32, 0), tick(&stack, warden, 1).params_dropped);

    // A set with every slot full of names the machine lacks still lands.
    var full: Stack = .{};
    for (&full.params, 0..) |*p, i| p.* = .{ .name = 900 + i, .value = 1 };
    try machine_mod.set(&full, warden, p_near, 1);
    try t.expectEqual(@as(f32, 1), machine_mod.get(&full, warden, p_near).?);
}

// ---------------------------------------------------------------------------------------------
// The tick

test "entry: a fresh stack enters each layer's entry, and the upper layers wait at weight 0" {
    var stack: Stack = .{};
    _ = tick(&stack, warden, 1);
    try t.expectEqual(s_idle, stack.layers[0].state);
    try t.expectEqual(s_reach, stack.layers[1].state);
    try t.expectEqual(s_pant, stack.layers[2].state);
    try t.expect(stack.layers[0].player.playing(c_idle));
    try t.expect(stack.layers[1].player.playing(c_reach));
    try t.expectEqual(@as(f32, 0), stack.layers[1].weight);
    try t.expectEqual(@as(u64, 1), stack.layers[0].state_ticks);
}

test "order: one transition a tick, the state's own in listed order" {
    var stack: Stack = .{};
    _ = tick(&stack, warden, 1);
    try machine_mod.set(&stack, warden, p_speed, 2.4);
    var step = tick(&stack, warden, 1);
    try t.expectEqual(@as(u32, 1), step.transitions);
    try t.expectEqual(s_walk, stack.layers[0].state);
    step = tick(&stack, warden, 1);
    try t.expectEqual(@as(u32, 1), step.transitions);
    try t.expectEqual(s_run, stack.layers[0].state);
    step = tick(&stack, warden, 1);
    try t.expectEqual(@as(u32, 0), step.transitions);
    try t.expectEqual(@as(u64, 2), stack.layers[0].state_ticks);
}

test "order: \"*\" goes before the state's own, and never into the state it is in" {
    var stack: Stack = .{};
    _ = tick(&stack, warden, 1);
    // Both `idle → walk` and `* → jump` hold; the interruption wins.
    try machine_mod.set(&stack, warden, p_speed, 1);
    try machine_mod.set(&stack, warden, p_link, 1);
    var step = tick(&stack, warden, 1);
    try t.expectEqual(s_jump, stack.layers[0].state);
    step = tick(&stack, warden, 5);
    try t.expectEqual(@as(u32, 0), step.transitions);
    try t.expectEqual(s_jump, stack.layers[0].state);
}

test "transitions: one taken mid-fade holds every channel and keeps the sum" {
    var stack: Stack = .{};
    _ = tick(&stack, warden, 1);
    try machine_mod.set(&stack, warden, p_speed, 1);
    _ = tick(&stack, warden, 5);
    try machine_mod.set(&stack, warden, p_speed, 2.4);
    _ = tick(&stack, warden, 2);
    try machine_mod.set(&stack, warden, p_speed, 1);
    _ = tick(&stack, warden, 2);
    try t.expectEqual(s_walk, stack.layers[0].state);
    var total: f32 = 0;
    var live: usize = 0;
    for (stack.layers[0].player.channels) |channel| {
        if (channel.clip == 0) continue;
        live += 1;
        total += channel.weight;
    }
    try t.expect(live >= 2);
    try t.expectApproxEqAbs(@as(f32, 1), total, 1e-5);
}

test "speed_param: the rate keeps the feet on the floor, and a negative one walks backward" {
    var stack: Stack = .{};
    _ = tick(&stack, warden, 1);
    try machine_mod.set(&stack, warden, p_speed, 1.2);
    _ = tick(&stack, warden, 60);
    const base = &stack.layers[0].player;
    try t.expectApproxEqAbs(@as(f32, 2), base.channels[base.newest].speed, 1e-5);
    const step = tick(&stack, warden, 1);
    try t.expectApproxEqAbs(@as(f32, -1.2 * dt), step.motion.translation.z, 1e-4);

    const back_states = [_]State{.{ .name = s_walk, .clip = c_walk, .speed_param = p_speed }};
    const back: Machine = .{ .params = &params, .layers = &.{.{ .entry = s_walk, .states = &back_states }} };
    var backward: Stack = .{};
    try machine_mod.set(&backward, back, p_speed, -0.6);
    _ = tick(&backward, back, 2);
    try t.expectApproxEqAbs(@as(f32, 0.6 * dt), tick(&backward, back, 1).motion.translation.z, 1e-4);
}

test "seek_param: a crossing state is put where the parameter says, and lands with its event" {
    var stack: Stack = .{};
    _ = tick(&stack, warden, 1);
    try machine_mod.set(&stack, warden, p_link, 1);
    try machine_mod.set(&stack, warden, p_link_t, 0.5);
    _ = tick(&stack, warden, 1);
    const base = &stack.layers[0].player;
    try t.expectApproxEqAbs(@as(f32, 0.4), base.seconds(rig, base.newest), 1e-5);
    try machine_mod.set(&stack, warden, p_link_t, 1);
    const step = tick(&stack, warden, 1);
    try t.expectEqual(@as(u32, 1), step.event_count);
    try t.expect(step.events[0].eql(land));
    try machine_mod.set(&stack, warden, p_link, 0);
    _ = tick(&stack, warden, 1);
    try t.expectEqual(s_idle, stack.layers[0].state);
}

test "weight_param: a layer's weight follows its parameter at its fade" {
    var stack: Stack = .{};
    try machine_mod.set(&stack, warden, p_near, 1);
    _ = tick(&stack, warden, 9);
    try t.expectApproxEqAbs(@as(f32, 0.5), stack.layers[1].weight, 1e-5);
    try machine_mod.set(&stack, warden, p_near, 7);
    _ = tick(&stack, warden, 30);
    try t.expectEqual(@as(f32, 1), stack.layers[1].weight);
    try machine_mod.set(&stack, warden, p_near, -3);
    _ = tick(&stack, warden, 1);
    try t.expectEqual(@as(f32, 0), stack.layers[1].target);
}

// A pacer: `turn` after a lap and a half of `walk`, as authored, and back across a finished turn.
const pace_states = [_]State{ .{ .name = s_walk, .clip = c_walk }, .{ .name = clipName("turn"), .clip = c_turn } };
const pace_transitions = [_]Transition{
    .{ .from = s_walk, .to = clipName("turn"), .conditions = &.{.{ .quantity = .laps, .compare = .at_least, .value = 1.5 }} },
    .{ .from = clipName("turn"), .to = s_walk, .fade = 0.1, .conditions = &.{.{ .quantity = .finished, .compare = .is, .value = 1 }} },
};
const pacer: Machine = .{ .layers = &.{.{ .entry = s_walk, .states = &pace_states, .transitions = &pace_transitions }} };

test "laps and finished: a pacer's side and corner come from its clips" {
    try pacer.validate(rig);
    var stack: Stack = .{};
    var turned_at: ?usize = null;
    var back_at: ?usize = null;
    var step: Step = .{};
    for (0..300) |i| {
        machine_mod.advance(&stack, rig, pacer, dt, &step);
        if (step.transitions == 1 and turned_at == null) turned_at = i;
        if (step.transitions == 1 and turned_at != null and i != turned_at.?) {
            back_at = i;
            break;
        }
    }
    // Entered on tick 0, so 90 ticks of a 60 Hz walk have passed on tick 90: 1.5 seconds.
    try t.expectEqual(@as(usize, 90), turned_at.?);
    // The one-second turn begins on tick 90 and is at its end after its 60th, so it leaves on tick
    // 150, as a corner done by hand by `finished` would.
    try t.expectEqual(@as(usize, 150), back_at.?);
    try t.expectEqual(s_walk, stack.layers[0].state);
}

test "laps: a side that ends exactly on a tick turns on that tick" {
    var stack: Stack = .{};
    var step: Step = .{};
    var turned_at: ?usize = null;
    for (0..12) |i| {
        machine_mod.advance(&stack, rig, pacer, 0.25, &step);
        if (step.transitions == 1) {
            turned_at = i;
            break;
        }
    }
    // Six quarter-seconds are exactly a lap and a half of a one-second walk.
    try t.expectEqual(@as(usize, 6), turned_at.?);
}

// ---------------------------------------------------------------------------------------------
// Untrusted

test "untrusted: a state the machine lacks begins its entry again, and is counted" {
    var stack: Stack = .{};
    _ = tick(&stack, warden, 3);
    stack.layers[0].state = clipName("gone");
    stack.layers[2].state = clipName("gone");
    const step = tick(&stack, warden, 1);
    try t.expectEqual(@as(u32, 2), step.reentered);
    try t.expectEqual(s_idle, stack.layers[0].state);
    try t.expectEqual(s_pant, stack.layers[2].state);
}

test "untrusted: a stack with no state adopts its newest clip's, so an old save carries on" {
    // What a save from before machines holds: a player in mid-walk, and nothing else.
    var stack: Stack = .{};
    try stack.layers[0].player.play(rig, c_walk, .{});
    var step: Step = .{};
    for (0..20) |_| stack.layers[0].player.advance(rig, dt, &step);
    const before = stack.layers[0].player;
    try machine_mod.set(&stack, warden, p_speed, 0.6);
    step = tick(&stack, warden, 1);
    try t.expectEqual(s_walk, stack.layers[0].state);
    try t.expectEqual(@as(u32, 0), step.transitions);
    // Carried on, not begun again: one tick further into the same clip.
    try t.expectEqual(before.channels[0].clip, stack.layers[0].player.channels[0].clip);
    try t.expect(stack.layers[0].player.seconds(rig, 0) > before.seconds(rig, 0));
}

// ---------------------------------------------------------------------------------------------
// Replay

test "replay: a three-layer machine run from parameters alone is byte-identical, and pinned" {
    const run = struct {
        fn go() !u64 {
            var stack: Stack = .{};
            var step: Step = .{};
            var out: [joints]Transform = undefined;
            var a: [joints]Transform = undefined;
            var b: [joints]Transform = undefined;
            var hash = std.hash.Fnv1a_64.init();
            for (0..1200) |i| {
                const phase = i % 400;
                try machine_mod.set(&stack, warden, p_speed, if (phase < 50) 0 else if (phase < 150) 1.0 else if (phase < 300) 2.4 else 0.8);
                try machine_mod.set(&stack, warden, p_near, if (phase >= 200 and phase < 280) 1 else 0);
                try machine_mod.set(&stack, warden, p_winded, if (phase >= 150 and phase < 320) 1 else 0);
                const crossing = phase >= 320 and phase < 360;
                try machine_mod.set(&stack, warden, p_link, if (crossing) 1 else 0);
                try machine_mod.set(&stack, warden, p_link_t, if (crossing) @as(f32, @floatFromInt(phase - 320)) / 39 else 0);
                machine_mod.advance(&stack, rig, warden, dt, &step);
                machine_mod.evaluate(&stack, rig, warden, .{ .{ .local = &a }, .{ .local = &b } }, .{ .local = &out });
                // Field by field: an `extern` struct's padding is not a value.
                for (stack.layers) |layer| {
                    for (layer.player.channels) |channel| {
                        hash.update(std.mem.asBytes(&channel.clip));
                        hash.update(std.mem.asBytes(&channel.anchor));
                        hash.update(std.mem.asBytes(&channel.ticks));
                        hash.update(std.mem.asBytes(&channel.speed));
                        hash.update(std.mem.asBytes(&channel.weight));
                    }
                    hash.update(std.mem.asBytes(&layer.player.newest));
                    hash.update(std.mem.asBytes(&layer.weight));
                    hash.update(std.mem.asBytes(&layer.state));
                    hash.update(std.mem.asBytes(&layer.state_ticks));
                }
                for (stack.params) |param| {
                    hash.update(std.mem.asBytes(&param.name));
                    hash.update(std.mem.asBytes(&param.value));
                }
                hash.update(std.mem.sliceAsBytes(&out));
                hash.update(std.mem.asBytes(&step.motion));
                hash.update(std.mem.sliceAsBytes(step.fired()));
            }
            return hash.final();
        }
    }.go;
    const first = try run();
    try t.expectEqual(first, try run());
    // Pinned. **Two values, by which `sin` the binary calls**, as `tests.zig` has it: a layer's
    // fading weight sends the chest through `slerp`, whose `@sin` is the system's in an optimised
    // build for Apple silicon and Zig's own everywhere else, and they differ in the last bit.
    const zig_sin: u64 = 0xe375a980ccac95f3;
    const apple_sin: u64 = 0x1b215b3c40e011e8;
    try t.expect(first == zig_sin or first == apple_sin);
}
