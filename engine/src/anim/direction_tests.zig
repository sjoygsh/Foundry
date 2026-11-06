//! `animation-states.md` §16's `anim` tests for M35 Step 1: a clip played backward, clips kept in step
//! by a sync group, and a seek fitted over laps. No device, no asset and no allocator under test.

const std = @import("std");
const core = @import("core");

const clip_mod = @import("clip.zig");
const player_mod = @import("player.zig");
const rig_mod = @import("rig.zig");
const skeleton_mod = @import("skeleton.zig");

const Clip = clip_mod.Clip;
const ContentId = core.ContentId;
const Event = rig_mod.Event;
const Mat4 = core.math.Mat4;
const Player = player_mod.Player;
const Quat = core.math.Quat;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;
const Skeleton = skeleton_mod.Skeleton;
const Step = player_mod.Step;
const Track = clip_mod.Track;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;

const clipName = rig_mod.clipName;
const no_parent = skeleton_mod.no_parent;
const t = std.testing;
const dt: f32 = 1.0 / 60.0;

// ---------------------------------------------------------------------------------------------
// Fixtures: a pelvis at 0.9 m with a leg below it, as `step_tests.zig` has.

const parents = [_]u16{ no_parent, 0 };
const rest = [_]Transform{ .{ .translation = .init(0, 0.9, 0) }, .{ .translation = .init(0, -0.5, 0) } };
const inverse_bind = [_]Mat4{ Mat4.identity, Mat4.identity };
const skeleton: Skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &inverse_bind };

const ends = [_]f32{ 0, 1 };

/// Forward 0.6 m a lap, bobbing in the middle.
const walk_times = [_]f32{ 0, 0.5, 1 };
const walk_values = [_]f32{ 0, 0.9, 0, 0, 1.0, -0.3, 0, 0.9, -0.6 };
const walk_tracks = [_]Track{.{ .joint = 0, .path = .translation, .times = &walk_times, .values = &walk_values }};
const walk_clip: Clip = .{ .duration = 1, .tracks = &walk_tracks };

/// Forward 1.3 m in 0.7 s: a clip of another length.
const run_times = [_]f32{ 0, 0.35, 0.7 };
const run_values = [_]f32{ 0, 0.9, 0, 0, 1.0, -0.65, 0, 0.9, -1.3 };
const run_tracks = [_]Track{.{ .joint = 0, .path = .translation, .times = &run_times, .values = &run_values }};
const run_clip: Clip = .{ .duration = 0.7, .tracks = &run_tracks };

const s45: f32 = 0.38268343; // sin 22.5 degrees
const c45: f32 = 0.92387953;
const s90: f32 = 0.70710678;

/// A quarter turn left about +Y as it walks forward a metre: a path that curves.
const turn_times = [_]f32{ 0, 0.5, 1 };
const turn_values = [_]f32{ 0, 0, 0, 1, 0, s45, 0, c45, 0, s90, 0, s90 };
const arc_values = [_]f32{ 0, 0.9, 0, 0, 0.9, -1 };
const arc_tracks = [_]Track{
    .{ .joint = 0, .path = .rotation, .times = &turn_times, .values = &turn_values },
    .{ .joint = 0, .path = .translation, .times = &ends, .values = &arc_values },
};
const arc_clip: Clip = .{ .duration = 1, .tracks = &arc_tracks };

/// The leg moves, and nothing travels.
const still_values = [_]f32{ 0, -0.5, 0, 0.1, -0.5, 0 };
const still_tracks = [_]Track{.{ .joint = 1, .path = .translation, .times = &ends, .values = &still_values }};
const still_clip: Clip = .{ .duration = 1, .tracks = &still_tracks };

const foot = ContentId.fromString("test:event.foot");
const land = ContentId.fromString("test:event.land");
const start_event = ContentId.fromString("test:event.start");
const rung = ContentId.fromString("test:event.rung");

const loop_events = [_]Event{ .{ .at = 0, .id = start_event }, .{ .at = 0.25, .id = foot }, .{ .at = 0.75, .id = foot } };
const once_events = [_]Event{ .{ .at = 0, .id = start_event }, .{ .at = 0.5, .id = foot }, .{ .at = 1, .id = land } };
const rung_events = [_]Event{.{ .at = 0, .id = rung }};

const name_walk = clipName("walk");
const name_run = clipName("run");
const name_jog = clipName("jog");
const name_ring = clipName("ring");
const name_once = clipName("once");
const name_steps = clipName("steps");
const name_climb = clipName("climb");
const name_idle = clipName("idle");
const feet = clipName("feet");

fn lessName(_: void, a: RigClip, b: RigClip) bool {
    return a.name < b.name;
}

const clips = blk: {
    @setEvalBranchQuota(100_000);
    var out = [_]RigClip{
        .{ .name = name_walk, .clip = walk_clip, .motion = true, .sync = feet, .label = "walk" },
        .{ .name = name_run, .clip = run_clip, .motion = true, .sync = feet, .label = "run" },
        .{ .name = name_jog, .clip = run_clip, .motion = true, .label = "jog" },
        .{ .name = name_ring, .clip = arc_clip, .motion = true, .label = "ring" },
        .{ .name = name_once, .clip = still_clip, .loop = false, .events = &once_events, .label = "once" },
        .{ .name = name_steps, .clip = still_clip, .events = &loop_events, .label = "steps" },
        .{ .name = name_climb, .clip = still_clip, .events = &rung_events, .rise = 0.3, .label = "climb" },
        .{ .name = name_idle, .clip = still_clip, .label = "idle" },
    };
    std.mem.sort(RigClip, &out, {}, lessName);
    break :blk out;
};
const rig: Rig = .{ .skeleton = skeleton, .clips = &clips, .start = name_idle, .motion_joint = 0 };

/// The body a game would keep, by the rule in `motion.zig`.
const Body = struct {
    position: Vec3 = .zero,
    yaw: f32 = 0,

    fn apply(body: *Body, step: *const Step) void {
        body.position = body.position.add(Quat.fromAxisAngle(.up, body.yaw).rotate(step.motion.translation));
        body.yaw += step.motion.yaw;
    }
};

fn fraction(player: *const Player, index: usize) f32 {
    const entry = rig.find(player.channels[index].clip).?;
    return player.seconds(rig, index) / entry.clip.duration;
}

fn slotOf(player: *const Player, name: u64) usize {
    for (player.channels, 0..) |channel, i| {
        if (channel.clip == name) return i;
    }
    unreachable;
}

/// Every event over `ticks`, in the order they fired.
fn collect(player: *Player, ticks: usize, tick: f32, out: []ContentId) []ContentId {
    var step: Step = .{};
    var n: usize = 0;
    for (0..ticks) |_| {
        player.advance(rig, tick, &step);
        for (step.fired()) |event| {
            out[n] = event;
            n += 1;
        }
    }
    return out[0..n];
}

fn countOf(events: []const ContentId, id: ContentId) usize {
    var n: usize = 0;
    for (events) |event| {
        if (event.eql(id)) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------------------------
// The rig's refusals

test "rig: a sync group on a one-shot and a bad rise are refused by name" {
    try rig.validate();
    const one_shot = [_]RigClip{.{ .name = name_once, .clip = still_clip, .loop = false, .sync = feet }};
    try t.expectError(error.SyncOnOneShot, (Rig{ .skeleton = skeleton, .clips = &one_shot, .start = name_once }).validate());
    for ([_]f32{ -0.3, std.math.nan(f32), std.math.inf(f32) }) |rise| {
        const bad = [_]RigClip{.{ .name = name_climb, .clip = still_clip, .rise = rise }};
        try t.expectError(error.InvalidRise, (Rig{ .skeleton = skeleton, .clips = &bad, .start = name_climb }).validate());
    }
}

// ---------------------------------------------------------------------------------------------
// Backward

test "backward: a one-shot starts at its end, holds at its first frame, and finishes there" {
    var player: Player = .{};
    try player.play(rig, name_once, .{ .speed = -1 });
    try t.expectEqual(@as(f32, 1), player.seconds(rig, player.newest));
    try t.expect(!player.finished(rig));
    var step: Step = .{};
    for (0..59) |_| player.advance(rig, dt, &step);
    try t.expect(!player.finished(rig));
    for (0..30) |_| player.advance(rig, dt, &step);
    try t.expect(player.finished(rig));
    try t.expectEqual(@as(f32, 0), player.seconds(rig, player.newest));

    // A restart on the newest begins backward from the end again.
    try player.play(rig, name_once, .{ .speed = -1 });
    try t.expectEqual(@as(f32, 1), player.seconds(rig, player.newest));
    // Forward from the start, as before.
    try player.play(rig, name_once, .{ .speed = 1 });
    try t.expectEqual(@as(f32, 0), player.seconds(rig, player.newest));
}

test "backward: a one-shot fires its end first and its start last, each once" {
    var player: Player = .{};
    try player.play(rig, name_once, .{ .speed = -1 });
    var buffer: [16]ContentId = undefined;
    const fired = collect(&player, 120, dt, &buffer);
    try t.expectEqual(@as(usize, 3), fired.len);
    try t.expect(fired[0].eql(land));
    try t.expect(fired[1].eql(foot));
    try t.expect(fired[2].eql(start_event));
}

test "backward: a start landing exactly on a tick still fires once" {
    var player: Player = .{};
    try player.play(rig, name_once, .{ .speed = -1 });
    var buffer: [16]ContentId = undefined;
    const fired = collect(&player, 8, 0.25, &buffer);
    try t.expectEqual(@as(usize, 1), countOf(fired, start_event));
    try t.expectEqual(@as(usize, 1), countOf(fired, land));
}

test "backward: a loop fires as often as forward, at any rate, latest first within a tick" {
    for ([_]f32{ 1.0 / 60.0, 1.0 / 30.0, 0.25, 1.0 / 7.0 }) |tick| {
        const ticks: usize = @intFromFloat(@round(3.0 / tick));
        var ahead: Player = .{};
        try ahead.play(rig, name_steps, .{});
        var back: Player = .{};
        try back.play(rig, name_steps, .{ .speed = -1 });
        var a: [64]ContentId = undefined;
        var b: [64]ContentId = undefined;
        const forward = collect(&ahead, ticks, tick, &a);
        const backward = collect(&back, ticks, tick, &b);
        try t.expectEqual(countOf(forward, foot), countOf(backward, foot));
        try t.expectEqual(countOf(forward, start_event), countOf(backward, start_event));
    }
    // A tick spanning a whole lap backward reads it from the top down: 0.75, 0.25, then 0.
    var player: Player = .{};
    try player.play(rig, name_steps, .{ .speed = -1 });
    var step: Step = .{};
    player.advance(rig, 0.5, &step);
    // From 0 to -0.5, `(-0.5, 0]`: the start at 0, which is `from`, then the 0.75 of the lap below.
    try t.expectEqual(@as(u32, 2), step.event_count);
    try t.expect(step.events[0].eql(start_event));
    try t.expect(step.events[1].eql(foot));
    player.advance(rig, 0.5, &step);
    // From -0.5 to -1: the 0.25 of the lap below, and nothing at -1, which is the next tick's.
    try t.expectEqual(@as(u32, 1), step.event_count);
    try t.expect(step.events[0].eql(foot));
}

test "backward: a stride played backward retraces its forward path within 1e-5" {
    inline for (.{ name_walk, name_ring }) |name| {
        var player: Player = .{};
        try player.play(rig, name, .{});
        var body: Body = .{};
        var path: [151]Body = undefined;
        path[0] = body;
        var step: Step = .{};
        for (1..path.len) |i| {
            player.advance(rig, dt, &step);
            body.apply(&step);
            path[i] = body;
        }
        try t.expect(body.position.length() > 1);
        try player.setSpeed(rig, -1);
        var i: usize = path.len - 1;
        while (i > 0) {
            i -= 1;
            player.advance(rig, dt, &step);
            body.apply(&step);
            try t.expectApproxEqAbs(path[i].position.x, body.position.x, 1e-5);
            try t.expectApproxEqAbs(path[i].position.z, body.position.z, 1e-5);
            try t.expectApproxEqAbs(path[i].yaw, body.yaw, 1e-5);
        }
    }
}

test "backward: a change of direction re-anchors and moves no pose" {
    var player: Player = .{};
    try player.play(rig, name_steps, .{});
    var step: Step = .{};
    for (0..20) |_| player.advance(rig, dt, &step);
    const at = player.seconds(rig, player.newest);
    try player.setSpeed(rig, -2);
    try t.expectEqual(at, player.seconds(rig, player.newest));
    for (0..30) |_| player.advance(rig, dt, &step);
    // A loop run backward past its start wraps to its end.
    try t.expectApproxEqAbs(@mod(at - 1.0, 1.0), player.seconds(rig, player.newest), 1e-5);
    try t.expect(player.sane());
}

// ---------------------------------------------------------------------------------------------
// Sync groups

test "sync: keep copies a fraction within a group, and seconds without one" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{});
    var step: Step = .{};
    for (0..15) |_| player.advance(rig, dt, &step);
    try t.expectApproxEqAbs(@as(f32, 0.25), fraction(&player, player.newest), 1e-5);
    try player.play(rig, name_run, .{ .fade = 0.3, .phase = .keep });
    try t.expectApproxEqAbs(@as(f32, 0.25), fraction(&player, player.newest), 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0.175), player.seconds(rig, player.newest), 1e-5);

    var plain: Player = .{};
    try plain.play(rig, name_walk, .{});
    for (0..15) |_| plain.advance(rig, dt, &step);
    try plain.play(rig, name_jog, .{ .fade = 0.3, .phase = .keep });
    try t.expectApproxEqAbs(@as(f32, 0.25), plain.seconds(rig, plain.newest), 1e-5);
}

test "sync: through a fade the newest leads, and the other keeps its fraction" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{});
    var step: Step = .{};
    for (0..10) |_| player.advance(rig, dt, &step);
    try player.play(rig, name_run, .{ .fade = 0.5, .phase = .keep });
    const walk_slot = slotOf(&player, name_walk);
    var saw_both = false;
    for (0..40) |_| {
        player.advance(rig, dt, &step);
        if (player.channels[walk_slot].clip != name_walk) break;
        saw_both = true;
        try t.expectApproxEqAbs(fraction(&player, player.newest), fraction(&player, walk_slot), 1e-5);
    }
    try t.expect(saw_both);
}

test "sync: a follower's travel is its own, so a walk fading into a run speeds up smoothly" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{});
    var step: Step = .{};
    for (0..10) |_| player.advance(rig, dt, &step);
    const walking = -step.motion.translation.z;
    try player.play(rig, name_run, .{ .fade = 0.5, .phase = .keep });
    var last = walking;
    for (0..29) |_| {
        player.advance(rig, dt, &step);
        const now = -step.motion.translation.z;
        // At the run's rate the walk covers a lap in 0.7 s, so the blend is never slower.
        try t.expect(now >= walking - 1e-5);
        // Smooth: no tick jumps by a lap's worth of a stride.
        try t.expect(@abs(now - last) < 0.01);
        last = now;
    }
}

test "sync: a follower that ran ahead steps back, rather than lapping" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{});
    var step: Step = .{};
    for (0..10) |_| player.advance(rig, dt, &step);
    try player.play(rig, name_run, .{ .fade = 0.5, .phase = .keep });
    const walk_slot = slotOf(&player, name_walk);
    player.channels[walk_slot].anchor += 0.1;
    player.advance(rig, dt, &step);
    try t.expectApproxEqAbs(fraction(&player, player.newest), fraction(&player, walk_slot), 1e-5);
    // A lap would be 0.6 m forward; a step back is a few centimetres at most.
    try t.expect(@abs(step.motion.translation.z) < 0.1);
}

test "sync: clips of no group are left alone through a fade" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{});
    var step: Step = .{};
    for (0..10) |_| player.advance(rig, dt, &step);
    try player.play(rig, name_jog, .{ .fade = 0.5, .phase = .keep });
    const walk_slot = slotOf(&player, name_walk);
    const walk_before = player.seconds(rig, walk_slot);
    player.advance(rig, dt, &step);
    try t.expectApproxEqAbs(walk_before + dt, player.seconds(rig, walk_slot), 1e-6);
}

// ---------------------------------------------------------------------------------------------
// Fitted seeks

test "seekLaps: a crossing of three laps fires each lap's rung, once" {
    var player: Player = .{};
    try player.play(rig, name_climb, .{});
    var step: Step = .{};
    var rungs: usize = 0;
    var f: f32 = 0;
    while (f <= 1.0001) : (f += 0.05) {
        player.seekLaps(rig, @min(f, 1), 3, dt, &step);
        rungs += countOf(step.fired(), rung);
    }
    try t.expectEqual(@as(usize, 3), rungs);
    try t.expectApproxEqAbs(@as(f32, 0), player.seconds(rig, player.newest), 1e-5);
}

test "seekLaps: one lap is seek, a one-shot has one lap, and zero laps is one" {
    var a: Player = .{};
    var b: Player = .{};
    try a.play(rig, name_steps, .{});
    try b.play(rig, name_steps, .{});
    var sa: Step = .{};
    var sb: Step = .{};
    for ([_]f32{ 0.1, 0.4, 0.8, 1, 0.3 }) |f| {
        a.seek(rig, f, dt, &sa);
        b.seekLaps(rig, f, 1, dt, &sb);
        try t.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
        try t.expectEqual(sa.event_count, sb.event_count);
    }
    var once: Player = .{};
    try once.play(rig, name_once, .{});
    once.seekLaps(rig, 0.5, 4, dt, &sa);
    try t.expectApproxEqAbs(@as(f32, 0.5), once.seconds(rig, once.newest), 1e-6);
    var zero: Player = .{};
    try zero.play(rig, name_climb, .{});
    zero.seekLaps(rig, 0.5, 0, dt, &sa);
    try t.expectApproxEqAbs(@as(f32, 0.5), zero.seconds(rig, zero.newest), 1e-6);
}

test "lapsFor: a rise into a height, rounded and bounded, and 1 for anything else" {
    try t.expectEqual(@as(u32, 1), rig.lapsFor(name_climb, 0.3));
    try t.expectEqual(@as(u32, 2), rig.lapsFor(name_climb, 0.6));
    try t.expectEqual(@as(u32, 20), rig.lapsFor(name_climb, 6));
    try t.expectEqual(@as(u32, 1), rig.lapsFor(name_climb, 0.05));
    try t.expectEqual(@as(u32, 2), rig.lapsFor(name_climb, -0.6));
    try t.expectEqual(@as(u32, 1), rig.lapsFor(name_climb, std.math.nan(f32)));
    try t.expectEqual(@as(u32, 1), rig.lapsFor(name_climb, std.math.inf(f32)));
    try t.expectEqual(rig_mod.max_fitted_laps, rig.lapsFor(name_climb, 1e9));
    try t.expectEqual(@as(u32, 1), rig.lapsFor(name_steps, 6));
    try t.expectEqual(@as(u32, 1), rig.lapsFor(name_once, 6));
    try t.expectEqual(@as(u32, 1), rig.lapsFor(clipName("absent"), 6));
}

// ---------------------------------------------------------------------------------------------
// Replay

fn script(player: *Player, out: *std.hash.Fnv1a_64) !void {
    var step: Step = .{};
    try player.play(rig, name_walk, .{});
    for (0..1200) |tick| {
        switch (tick) {
            100 => try player.play(rig, name_run, .{ .fade = 0.4, .phase = .keep }),
            300 => try player.setSpeed(rig, -1),
            450 => try player.play(rig, name_walk, .{ .fade = 0.3, .phase = .keep, .speed = -0.5 }),
            600 => try player.play(rig, name_once, .{ .fade = 0.2, .speed = -1 }),
            800 => try player.play(rig, name_climb, .{}),
            else => {},
        }
        if (tick >= 800 and tick < 1000) {
            player.seekLaps(rig, @as(f32, @floatFromInt(tick - 800)) / 200, 3, dt, &step);
        } else {
            player.advance(rig, dt, &step);
        }
        out.update(std.mem.asBytes(player));
        out.update(std.mem.asBytes(&step.motion));
        out.update(std.mem.sliceAsBytes(step.fired()));
    }
}

test "replay: backward, synced and fitted playback is byte-identical twice in one process" {
    var a = std.hash.Fnv1a_64.init();
    var b = std.hash.Fnv1a_64.init();
    var first: Player = .{};
    var second: Player = .{};
    try script(&first, &a);
    try script(&second, &b);
    try t.expectEqual(a.final(), b.final());
}
