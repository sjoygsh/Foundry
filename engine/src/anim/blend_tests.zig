//! `animation-ik.md` §16's tests for M36 Step 1: blend spaces in one and two axes, played by a
//! channel, through a stack and through a machine. No device, no asset and no allocator under test.

const std = @import("std");
const core = @import("core");

const blend_mod = @import("blend.zig");
const clip_mod = @import("clip.zig");
const machine_mod = @import("machine.zig");
const motion_mod = @import("motion.zig");
const player_mod = @import("player.zig");
const pose_mod = @import("pose.zig");
const rig_mod = @import("rig.zig");
const skeleton_mod = @import("skeleton.zig");
const stack_mod = @import("stack.zig");

const Blend = blend_mod.Blend;
const Clip = clip_mod.Clip;
const ContentId = core.ContentId;
const Event = rig_mod.Event;
const Machine = machine_mod.Machine;
const Mat4 = core.math.Mat4;
const Player = player_mod.Player;
const Point = blend_mod.Point;
const Positions = blend_mod.Positions;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;
const Skeleton = skeleton_mod.Skeleton;
const Stack = stack_mod.Stack;
const Step = player_mod.Step;
const Track = clip_mod.Track;
const Transform = core.math.Transform;

const clipName = rig_mod.clipName;
const no_parent = skeleton_mod.no_parent;
const t = std.testing;
const dt: f32 = 1.0 / 60.0;

// ---------------------------------------------------------------------------------------------
// Fixtures: a pelvis that travels, and a leg that swings under it.

const pelvis = 0;
const leg = 1;
const joints = 2;

const parents = [_]u16{ no_parent, pelvis };
const rest = [_]Transform{ .{ .translation = .init(0, 0.9, 0) }, .{ .translation = .init(0, -0.5, 0) } };
const inverse_bind: [joints]Mat4 = @splat(Mat4.identity);
const skeleton: Skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &inverse_bind };

const ends = [_]f32{ 0, 1 };
const run_ends = [_]f32{ 0, 0.7 };
const halves = [_]f32{ 0, 0.5, 1 };
const run_halves = [_]f32{ 0, 0.35, 0.7 };

/// A leg that swings forward and back once a lap, by `reach` metres along Z.
fn swing(comptime reach: f32) [9]f32 {
    return .{ 0, -0.5, reach, 0, -0.5, -reach, 0, -0.5, reach };
}

/// A pelvis that travels `x`, `z` metres a lap.
fn travel(comptime x: f32, comptime z: f32) [6]f32 {
    return .{ 0, 0.9, 0, x, 0.9, z };
}

const idle_leg = swing(0.02);
const walk_leg = swing(0.2);
const run_leg = swing(0.35);
const side_leg = swing(0.1);

const walk_path = travel(0, -1.0);
const run_path = travel(0, -1.3);
const left_path = travel(-1.0, 0);
const right_path = travel(1.0, 0);

fn walking(comptime path: *const [6]f32, comptime legs: *const [9]f32, comptime times: *const [2]f32, comptime keys: *const [3]f32) [2]Track {
    return .{
        .{ .joint = pelvis, .path = .translation, .times = times, .values = path },
        .{ .joint = leg, .path = .translation, .times = keys, .values = legs },
    };
}

const idle_tracks = [_]Track{.{ .joint = leg, .path = .translation, .times = &halves, .values = &idle_leg }};
const walk_tracks = walking(&walk_path, &walk_leg, &ends, &halves);
const run_tracks = walking(&run_path, &run_leg, &run_ends, &run_halves);
const left_tracks = walking(&left_path, &side_leg, &ends, &halves);
const right_tracks = walking(&right_path, &side_leg, &ends, &halves);
const jump_tracks = [_]Track{.{ .joint = leg, .path = .translation, .times = &halves, .values = &walk_leg }};

const step_walk = ContentId.fromString("test:event.walk");
const step_run = ContentId.fromString("test:event.run");
const walk_events = [_]Event{ .{ .at = 0.25, .id = step_walk }, .{ .at = 0.75, .id = step_walk } };
const run_events = [_]Event{ .{ .at = 0.25, .id = step_run }, .{ .at = 0.75, .id = step_run } };

const name_idle = clipName("idle");
const name_walk = clipName("walk");
const name_run = clipName("run");
const name_left = clipName("left");
const name_right = clipName("right");
const name_jump = clipName("jump");
const name_move = clipName("move");
const name_grid = clipName("grid");
const name_feet = clipName("feet");

/// Idle at 0, the walk at 1 m/s and the run at 1.86 m/s: the warden's `move`.
const move_points = [_]Point{
    .{ .clip = name_idle, .x = 0 },
    .{ .clip = name_walk, .x = 1.0 },
    .{ .clip = name_run, .x = 1.86 },
};
const move_blend = Blend.build(&move_points) catch unreachable;

/// Sideways and ahead: three across, two deep, with the walk at all three places ahead.
const grid_points = [_]Point{
    .{ .clip = name_idle, .x = 0, .y = 0 },
    .{ .clip = name_left, .x = -1, .y = 0 },
    .{ .clip = name_right, .x = 1, .y = 0 },
    .{ .clip = name_walk, .x = -1, .y = 1 },
    .{ .clip = name_walk, .x = 0, .y = 1 },
    .{ .clip = name_walk, .x = 1, .y = 1 },
};
const grid_blend = Blend.build(&grid_points) catch unreachable;

fn lessName(_: void, a: RigClip, b: RigClip) bool {
    return a.name < b.name;
}

fn sorted(comptime entries: []const RigClip) [entries.len]RigClip {
    @setEvalBranchQuota(100_000);
    var out: [entries.len]RigClip = entries[0..entries.len].*;
    std.mem.sort(RigClip, &out, {}, lessName);
    return out;
}

const base_clips = [_]RigClip{
    .{ .name = name_idle, .clip = .{ .duration = 1, .tracks = &idle_tracks }, .label = "idle" },
    .{ .name = name_walk, .clip = .{ .duration = 1, .tracks = &walk_tracks }, .motion = true, .events = &walk_events, .sync = name_feet, .label = "walk" },
    .{ .name = name_run, .clip = .{ .duration = 0.7, .tracks = &run_tracks }, .motion = true, .events = &run_events, .sync = name_feet, .label = "run" },
    .{ .name = name_left, .clip = .{ .duration = 1, .tracks = &left_tracks }, .motion = true, .sync = name_feet, .label = "left" },
    .{ .name = name_right, .clip = .{ .duration = 1, .tracks = &right_tracks }, .motion = true, .label = "right" },
    .{ .name = name_jump, .clip = .{ .duration = 1, .tracks = &jump_tracks }, .loop = false, .label = "jump" },
};

const clips = sorted(&(base_clips ++ [_]RigClip{
    blend_mod.entryFor(name_move, &move_blend, true, name_feet, "move"),
    blend_mod.entryFor(name_grid, &grid_blend, true, 0, "grid"),
}));

const rig: Rig = .{ .skeleton = skeleton, .clips = &clips, .start = name_idle, .motion_joint = pelvis };

fn at(x: f32, y: f32) Positions {
    var out: Positions = .{};
    out.put(name_move, .{ x, y });
    out.put(name_grid, .{ x, y });
    return out;
}

fn entryOf(name: u64) *const RigClip {
    return rig.find(name).?;
}

fn weightOf(mix: blend_mod.Mix, name: u64) f32 {
    for (mix.slice()) |part| {
        if (part.clip == name) return part.weight;
    }
    return 0;
}

fn playing(name: u64) Player {
    var player: Player = .{};
    player.play(rig, name, .{}) catch unreachable;
    return player;
}

fn pose(player: *const Player, positions: Positions) [joints]Transform {
    var out: [joints]Transform = undefined;
    var a: [joints]Transform = undefined;
    var b: [joints]Transform = undefined;
    player.evaluateAt(rig, positions, .{ .{ .local = &a }, .{ .local = &b } }, .{ .local = &out });
    return out;
}

fn sampled(name: u64, seconds: f32) [joints]Transform {
    var out: [joints]Transform = undefined;
    const entry = entryOf(name);
    pose_mod.sample(skeleton, entry.clip, seconds, .{ .local = &out });
    if (entry.motion) motion_mod.hold(rig, entry, .{ .local = &out });
    return out;
}

// ---------------------------------------------------------------------------------------------
// Arrangement.

test "a line sorts its points, a grid needs every place, and what is neither is refused by name" {
    try rig.validate();

    try t.expectEqual(@as(u8, 1), move_blend.axes());
    try t.expectEqualSlices(f32, &.{ 0, 1.0, 1.86 }, move_blend.columnSlice());
    try t.expectEqual(@as(u8, 2), grid_blend.axes());
    try t.expectEqualSlices(f32, &.{ -1, 0, 1 }, grid_blend.columnSlice());
    try t.expectEqualSlices(f32, &.{ 0, 1 }, grid_blend.rowSlice());
    try t.expectEqual([2]f32{ 0, 0 }, grid_blend.origin);

    // Out of order is still a line.
    const shuffled = try Blend.build(&.{ .{ .clip = name_run, .x = 2 }, .{ .clip = name_idle, .x = 0 }, .{ .clip = name_walk, .x = 1 } });
    try t.expectEqualSlices(u64, &.{ name_idle, name_walk, name_run }, shuffled.places());
    try t.expectEqual([2]f32{ 2, 0 }, shuffled.origin);

    try t.expectError(error.TooFewPoints, Blend.build(&.{.{ .clip = name_idle, .x = 0 }}));
    var many: [blend_mod.max_points + 1]Point = undefined;
    for (&many, 0..) |*point, i| point.* = .{ .clip = name_idle, .x = @floatFromInt(i) };
    try t.expectError(error.TooManyPoints, Blend.build(&many));
    _ = try Blend.build(many[0..blend_mod.max_points]);
    try t.expectError(error.InvalidPoint, Blend.build(&.{ .{ .clip = name_idle, .x = 0 }, .{ .clip = name_walk, .x = std.math.nan(f32) } }));
    try t.expectError(error.InvalidPoint, Blend.build(&.{ .{ .clip = name_idle, .x = 0 }, .{ .clip = name_walk, .x = 1, .y = std.math.inf(f32) } }));
    try t.expectError(error.DuplicatePoint, Blend.build(&.{ .{ .clip = name_idle, .x = 0 }, .{ .clip = name_walk, .x = 0 } }));
    // Three places of a two-by-two grid.
    try t.expectError(error.NotAGrid, Blend.build(&.{
        .{ .clip = name_idle, .x = 0, .y = 0 },
        .{ .clip = name_walk, .x = 1, .y = 0 },
        .{ .clip = name_run, .x = 0, .y = 1 },
    }));
}

test "a position weighs its neighbours, sums to one, and is held at the edges" {
    // On a point, that point alone.
    for (move_points) |point| {
        const mix = move_blend.weights(.{ point.x, 0 });
        try t.expectEqual(@as(u8, 1), mix.len);
        try t.expectEqual(point.clip, mix.entries[0].clip);
        try t.expectEqual(@as(f32, 1), mix.entries[0].weight);
    }
    // Between, linearly.
    const between = move_blend.weights(.{ 1.43, 0 });
    try t.expectApproxEqAbs(@as(f32, 0.5), weightOf(between, name_walk), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5), weightOf(between, name_run), 1e-6);
    // Held outside, either side, and a NaN is the first.
    try t.expectEqual(@as(f32, 1), weightOf(move_blend.weights(.{ -3, 0 }), name_idle));
    try t.expectEqual(@as(f32, 1), weightOf(move_blend.weights(.{ 9, 0 }), name_run));
    try t.expectEqual(@as(f32, 1), weightOf(move_blend.weights(.{ std.math.nan(f32), 0 }), name_idle));

    // Bilinear in a cell, and a clip at two corners has their weight together.
    const cell = grid_blend.weights(.{ 0.25, 0.5 });
    try t.expectEqual(@as(u8, 3), cell.len);
    try t.expectApproxEqAbs(@as(f32, 0.375), weightOf(cell, name_idle), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.125), weightOf(cell, name_right), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5), weightOf(cell, name_walk), 1e-6);
    var sum: f32 = 0;
    for (cell.slice()) |part| sum += part.weight;
    try t.expectApproxEqAbs(@as(f32, 1), sum, 1e-6);

    // Every position mixes at most four, summing to one.
    var y: f32 = -0.5;
    while (y <= 1.5) : (y += 0.0625) {
        var x: f32 = -1.5;
        while (x <= 1.5) : (x += 0.0625) {
            const mix = grid_blend.weights(.{ x, y });
            try t.expect(mix.len >= 1 and mix.len <= blend_mod.max_mixed);
            var total: f32 = 0;
            for (mix.slice()) |part| total += part.weight;
            try t.expectApproxEqAbs(@as(f32, 1), total, 1e-5);
        }
    }
}

test "the heaviest clip leads, and a tie goes to the earlier point" {
    try t.expectEqual(name_walk, move_blend.weights(.{ 1.2, 0 }).heaviest());
    try t.expectEqual(name_run, move_blend.weights(.{ 1.6, 0 }).heaviest());
    // Exactly halfway, the walk was listed first.
    try t.expectEqual(name_walk, move_blend.weights(.{ 1.43, 0 }).heaviest());
    const backward = try Blend.build(&.{ .{ .clip = name_run, .x = 1 }, .{ .clip = name_walk, .x = 0 } });
    try t.expectEqual(name_run, backward.weights(.{ 0.5, 0 }).heaviest());
}

test "a rig refuses a blend that is not one, by name" {
    const Case = struct { blend: *const Blend, motion: bool, err: anyerror };
    const of_jump = comptime Blend.build(&.{ .{ .clip = name_idle, .x = 0 }, .{ .clip = name_jump, .x = 1 } }) catch unreachable;
    const of_gone = comptime Blend.build(&.{ .{ .clip = name_idle, .x = 0 }, .{ .clip = clipName("gone"), .x = 1 } }) catch unreachable;
    const of_move = comptime Blend.build(&.{ .{ .clip = name_idle, .x = 0 }, .{ .clip = name_move, .x = 1 } }) catch unreachable;
    const still = comptime Blend.build(&.{ .{ .clip = name_idle, .x = 0 }, .{ .clip = name_idle, .x = 1 } }) catch unreachable;
    var unsorted = move_blend;
    unsorted.columns[0] = 5;
    const cases = [_]Case{
        .{ .blend = &of_jump, .motion = false, .err = error.BlendOfOneShot },
        .{ .blend = &of_gone, .motion = false, .err = error.UnknownBlendClip },
        .{ .blend = &of_move, .motion = true, .err = error.BlendOfBlend },
        .{ .blend = &still, .motion = true, .err = error.BlendMotionMismatch },
        .{ .blend = &unsorted, .motion = true, .err = error.InvalidBlend },
    };
    for (cases) |case| {
        var entries: [clips.len + 1]RigClip = undefined;
        @memcpy(entries[0..clips.len], &clips);
        entries[clips.len] = blend_mod.entryFor(clipName("zz.extra"), case.blend, case.motion, 0, "extra");
        std.mem.sort(RigClip, &entries, {}, lessName);
        const bad: Rig = .{ .skeleton = skeleton, .clips = &entries, .start = name_idle, .motion_joint = pelvis };
        try t.expectError(case.err, bad.validate());
    }

    // An entry for a blend that carries what only a clip may.
    const shapes = [_]RigClip{
        .{ .name = name_move, .clip = .{ .duration = 2, .tracks = &.{} }, .motion = true, .blend = &move_blend },
        .{ .name = name_move, .clip = .{ .duration = 1, .tracks = &.{} }, .motion = true, .speed = 2, .blend = &move_blend },
        .{ .name = name_move, .clip = .{ .duration = 1, .tracks = &.{} }, .motion = true, .events = &walk_events, .blend = &move_blend },
        .{ .name = name_move, .clip = .{ .duration = 1, .tracks = &.{} }, .motion = true, .rise = 0.3, .blend = &move_blend },
    };
    for (shapes) |shape| {
        var entries = clips;
        for (&entries) |*entry| {
            if (entry.name == name_move) entry.* = shape;
        }
        const bad: Rig = .{ .skeleton = skeleton, .clips = &entries, .start = name_idle, .motion_joint = pelvis };
        try t.expectError(error.InvalidBlend, bad.validate());
    }

    // A name a clip has is the rig's ordinary collision.
    var twice = clips;
    for (&twice) |*entry| {
        if (entry.name == name_move) entry.name = name_walk;
    }
    std.mem.sort(RigClip, &twice, {}, lessName);
    const colliding: Rig = .{ .skeleton = skeleton, .clips = &twice, .start = name_idle, .motion_joint = pelvis };
    try t.expectError(error.NameCollision, colliding.validate());

    // Nine blends are one too many.
    var crowded: [base_clips.len + blend_mod.max_blends + 1]RigClip = undefined;
    @memcpy(crowded[0..base_clips.len], &base_clips);
    for (0..blend_mod.max_blends + 1) |i| {
        crowded[base_clips.len + i] = blend_mod.entryFor(@as(u64, 1000) + i, &move_blend, true, 0, "");
    }
    std.mem.sort(RigClip, &crowded, {}, lessName);
    const too_many: Rig = .{ .skeleton = skeleton, .clips = &crowded, .start = name_idle, .motion_joint = pelvis };
    try t.expectError(error.TooManyBlends, too_many.validate());
    // Eight are not.
    try (Rig{ .skeleton = skeleton, .clips = crowded[1..], .start = name_idle, .motion_joint = pelvis }).validate();
}

// ---------------------------------------------------------------------------------------------
// Playing.

test "a blend's clips are sampled at one fraction, and its lap is their lengths weighted" {
    var player = playing(name_move);
    const halfway = at(1.43, 0);
    const lap = blend_mod.lapLength(rig, entryOf(name_move), halfway.of(entryOf(name_move)));
    try t.expectApproxEqAbs(@as(f64, 0.5 * 1.0 + 0.5 * 0.7), lap, 1e-6);

    var step: Step = .{};
    for (0..17) |_| player.advanceAt(rig, halfway, dt, &step);
    const laps = player.channels[0].anchor;
    try t.expectApproxEqAbs(17 * @as(f64, dt) / lap, laps, 1e-9);
    try t.expectEqual(@as(u64, 0), player.channels[0].ticks);

    // Each clip at that fraction of its own length, mixed by the weights.
    const fraction: f32 = @floatCast(laps);
    const walk = sampled(name_walk, fraction * 1.0);
    const run = sampled(name_run, fraction * 0.7);
    var expected: [joints]Transform = undefined;
    pose_mod.blend(.{ .local = @constCast(&walk) }, .{ .local = @constCast(&run) }, 0.5, .{ .local = &expected });
    const got = pose(&player, halfway);
    for (got, expected) |g, e| {
        try t.expectApproxEqAbs(e.translation.z, g.translation.z, 1e-5);
        try t.expectApproxEqAbs(e.translation.y, g.translation.y, 1e-5);
    }
}

test "moving the position never moves time: each tick runs at the lap its place has then" {
    var player = playing(name_move);
    var step: Step = .{};
    var expected: f64 = 0;
    const places = [_]f32{ 1.0, 1.86, 0.4, 1.43, 1.86, 1.0 };
    for (places) |x| {
        // Evaluating at another place moves nothing.
        _ = pose(&player, at(0.2, 0));
        try t.expectEqual(expected, player.channels[0].anchor);
        player.advanceAt(rig, at(x, 0), dt, &step);
        expected += @as(f64, dt) / blend_mod.lapLength(rig, entryOf(name_move), .{ x, 0 });
        try t.expectApproxEqAbs(expected, player.channels[0].anchor, 1e-12);
    }
}

test "a position swept across the whole grid moves the pose without a jump" {
    var player = playing(name_grid);
    var step: Step = .{};
    var previous: ?[joints]Transform = null;
    // Round the grid's edge and through its middle, a small step a tick.
    const route = [_][2]f32{ .{ -1, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ -1, 1 }, .{ 0, 0 }, .{ 1, 1 } };
    var worst: f32 = 0;
    for (route[0 .. route.len - 1], route[1..]) |from, to| {
        for (0..120) |i| {
            const k = @as(f32, @floatFromInt(i)) / 120;
            const place = at(from[0] + (to[0] - from[0]) * k, from[1] + (to[1] - from[1]) * k);
            player.advanceAt(rig, place, dt, &step);
            const now = pose(&player, place);
            if (previous) |before| {
                for (now, before) |a, b| worst = @max(worst, a.translation.sub(b.translation).length());
            }
            previous = now;
        }
    }
    // The leg swings 0.7 m a lap at most, so a tick moves it a few centimetres at most.
    try t.expect(worst < 0.05);
    try t.expect(worst > 0);
}

test "a blend travels as its clips do over the same laps, weighted, and its speed is that travel's" {
    var player = playing(name_move);
    var step: Step = .{};
    const halfway = at(1.43, 0);
    for (0..10) |_| player.advanceAt(rig, halfway, dt, &step);
    const before = player.channels[0].anchor;
    player.advanceAt(rig, halfway, dt, &step);
    const after = player.channels[0].anchor;

    const walk = motion_mod.travel(rig, entryOf(name_walk), before * 1.0, after * 1.0);
    const run = motion_mod.travel(rig, entryOf(name_run), before * 0.7, after * 0.7);
    try t.expectApproxEqAbs(0.5 * walk.translation.z + 0.5 * run.translation.z, step.motion.translation.z, 1e-6);

    // Metres a lap over seconds a lap: the walk's 1.0 and the run's 1.3, over 1.0 and 0.7.
    const speed = rig.motionSpeedAt(name_move, halfway);
    try t.expectApproxEqAbs(@as(f32, (0.5 * 1.0 + 0.5 * 1.3) / 0.85), speed, 1e-5);
    try t.expectApproxEqAbs(@as(f64, speed) * dt, -step.motion.translation.z, 1e-5);
    // At its first point, idle, a blend has no travel.
    try t.expectEqual(@as(f32, 0), rig.motionSpeed(name_move));
}

test "a blend fires its heaviest clip's events, at that clip's own times" {
    var walking_mix = playing(name_move);
    var running_mix = playing(name_move);
    var step: Step = .{};
    var walks: u32 = 0;
    var runs: u32 = 0;
    for (0..120) |_| {
        walking_mix.advanceAt(rig, at(1.2, 0), dt, &step);
        for (step.fired()) |id| {
            if (id.eql(step_walk)) walks += 1;
            try t.expect(!id.eql(step_run));
        }
        running_mix.advanceAt(rig, at(1.6, 0), dt, &step);
        for (step.fired()) |id| {
            if (id.eql(step_run)) runs += 1;
            try t.expect(!id.eql(step_walk));
        }
    }
    // Two seconds at a lap of about 0.92 s and 0.79 s: two steps a lap, never twice a step.
    try t.expect(walks >= 4 and walks <= 5);
    try t.expect(runs >= 5 and runs <= 6);
}

test "a blend in a sync group keeps its fraction into a clip, and back" {
    var player = playing(name_move);
    var step: Step = .{};
    for (0..20) |_| player.advanceAt(rig, at(1.43, 0), dt, &step);
    const fraction = @mod(player.channels[0].anchor, 1);
    try player.play(rig, name_left, .{ .fade = 0.2, .phase = .keep });
    const left = player.channels[player.newest];
    try t.expectApproxEqAbs(fraction * 1.0, left.anchor, 1e-9);
    // And a clip into the blend.
    for (0..20) |_| player.advanceAt(rig, at(1.43, 0), dt, &step);
    var back = playing(name_run);
    for (0..9) |_| back.advanceAt(rig, .none, dt, &step);
    const run_fraction = @mod(back.channels[0].anchor + @as(f64, @floatFromInt(back.channels[0].ticks)) * dt, 0.7) / 0.7;
    try back.play(rig, name_move, .{ .fade = 0.2, .phase = .keep });
    try t.expectApproxEqAbs(run_fraction, back.channels[back.newest].anchor, 1e-6);
}

test "with no position a blend sits at its first point, and a blend a rig lacks is a lost channel" {
    var player = playing(name_move);
    var step: Step = .{};
    for (0..13) |_| player.advance(rig, dt, &step);
    var out: [joints]Transform = undefined;
    var scratch: [joints]Transform = undefined;
    player.evaluate(rig, .{ .local = &scratch }, .{ .local = &out });
    const laps: f32 = @floatCast(player.channels[0].anchor);
    // Idle's lap is one second, so it runs as idle would.
    try t.expectApproxEqAbs(@as(f32, 13) * dt, laps, 1e-6);
    const idle = sampled(name_idle, laps);
    for (out, idle) |a, b| try t.expectEqual(b.translation, a.translation);

    // A rig without the blend empties the channel and counts it.
    const plain: Rig = .{ .skeleton = skeleton, .clips = &sorted(&base_clips), .start = name_idle, .motion_joint = pelvis };
    player.advance(plain, dt, &step);
    try t.expectEqual(@as(u32, 1), step.lost);
    try t.expectEqual(name_idle, player.channels[player.newest].clip);
}

// ---------------------------------------------------------------------------------------------
// Through a machine.

const p_speed = clipName("speed");
const p_side = clipName("side");
const p_ahead = clipName("ahead");
const params = [_]machine_mod.ParamDef{ .{ .name = p_speed }, .{ .name = p_side }, .{ .name = p_ahead } };
const s_move = clipName("s.move");
const s_jump = clipName("s.jump");
const move_states = [_]machine_mod.State{
    .{ .name = s_move, .clip = name_move, .speed_param = p_speed },
    .{ .name = s_jump, .clip = name_jump },
};
const lap_out = [_]machine_mod.Condition{.{ .quantity = .laps, .compare = .at_least, .value = 2 }};
const move_transitions = [_]machine_mod.Transition{.{ .from = s_move, .to = s_jump, .conditions = &lap_out }};
const move_layers = [_]machine_mod.MachineLayer{.{ .entry = s_move, .states = &move_states, .transitions = &move_transitions }};
const move_axes = [_]machine_mod.Axes{.{ .blend = name_move, .x = p_speed }};
const mover: Machine = .{ .params = &params, .layers = &move_layers, .axes = &move_axes };

test "a machine binds a blend's axes, and refuses what would leave one unbound or mismatched" {
    try mover.validate(rig);
    const Case = struct { axes: []const machine_mod.Axes, err: anyerror };
    const cases = [_]Case{
        .{ .axes = &.{}, .err = error.UnboundBlend },
        .{ .axes = &.{.{ .blend = name_walk, .x = p_speed }}, .err = error.UnknownBlend },
        .{ .axes = &.{ .{ .blend = name_move, .x = p_speed }, .{ .blend = name_move, .x = p_side } }, .err = error.DuplicateAxes },
        .{ .axes = &.{.{ .blend = name_move, .x = p_speed, .y = p_side }}, .err = error.AxisMismatch },
        .{ .axes = &.{ .{ .blend = name_move, .x = p_speed }, .{ .blend = name_grid, .x = p_side } }, .err = error.AxisMismatch },
        .{ .axes = &.{.{ .blend = name_move, .x = clipName("nope") }}, .err = error.UnknownParam },
    };
    for (cases) |case| {
        const bad: Machine = .{ .params = &params, .layers = &move_layers, .axes = case.axes };
        try t.expectError(case.err, bad.validate(rig));
    }
    const nine: [blend_mod.max_positions + 1]machine_mod.Axes = @splat(.{ .blend = name_move, .x = p_speed });
    try t.expectError(error.TooManyAxes, (Machine{ .params = &params, .layers = &move_layers, .axes = &nine }).validate(rig));

    // A blend of clips with no travel cannot follow a speed.
    const still = comptime Blend.build(&.{ .{ .clip = name_idle, .x = 0 }, .{ .clip = name_idle, .x = 1 } }) catch unreachable;
    const still_clips = sorted(&(base_clips ++ [_]RigClip{blend_mod.entryFor(name_move, &still, false, 0, "move")}));
    const still_rig: Rig = .{ .skeleton = skeleton, .clips = &still_clips, .start = name_idle, .motion_joint = pelvis };
    try still_rig.validate();
    try t.expectError(error.NoMotionSpeed, mover.validate(still_rig));
}

test "a machine places its blend from its parameters, follows speed with the rate, and times laps by the lap" {
    var stack: Stack = .{};
    var step: Step = .{};
    try machine_mod.set(&stack, mover, p_speed, 1.43);
    machine_mod.advance(&stack, rig, mover, dt, &step);
    const player = &stack.players[0];
    try t.expectEqual(name_move, player.channels[player.newest].clip);
    // The rate is the speed over the blend's own speed there: about 1 inside its range.
    const per = rig.motionSpeedAt(name_move, at(1.43, 0));
    try t.expectApproxEqAbs(1.43 / per, player.channels[player.newest].speed, 1e-5);
    // Its travel then is the speed asked for.
    machine_mod.advance(&stack, rig, mover, dt, &step);
    try t.expectApproxEqAbs(@as(f32, 1.43) * dt, -step.motion.translation.z, 1e-4);

    // Standing, there is no speed to follow, and it plays at the state's own rate, not frozen.
    try machine_mod.set(&stack, mover, p_speed, 0);
    machine_mod.advance(&stack, rig, mover, dt, &step);
    try t.expectEqual(@as(f32, 1), player.channels[player.newest].speed);

    // The pose a machine shows is the player's at the machine's place.
    var out: [joints]Transform = undefined;
    var a: [joints]Transform = undefined;
    var b: [joints]Transform = undefined;
    var c: [joints]Transform = undefined;
    machine_mod.evaluate(&stack, rig, mover, .{ .{ .local = &a }, .{ .local = &b }, .{ .local = &c } }, .{ .local = &out });
    const direct = pose(player, at(0, 0));
    for (out, direct) |x, y| try t.expectEqual(y.translation, x.translation);

    // Two laps at the run's end are 1.4 s, not two seconds of a one-second lap.
    var fresh: Stack = .{};
    try machine_mod.set(&fresh, mover, p_speed, 1.86);
    var ticks: u32 = 0;
    while (fresh.layers[0].state != s_jump and ticks < 600) : (ticks += 1) machine_mod.advance(&fresh, rig, mover, dt, &step);
    try t.expectEqual(@as(u32, 85), ticks);
}
