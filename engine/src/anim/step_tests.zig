//! `animation-logic.md` §13's `anim` tests for what a tick reports: events, root motion, `seek` and
//! the `Report`. No device, no asset and no allocator under test.

const std = @import("std");
const core = @import("core");

const clip_mod = @import("clip.zig");
const player_mod = @import("player.zig");
const report_mod = @import("report.zig");
const rig_mod = @import("rig.zig");
const skeleton_mod = @import("skeleton.zig");

const Clip = clip_mod.Clip;
const ContentId = core.ContentId;
const Event = rig_mod.Event;
const Mat4 = core.math.Mat4;
const Player = player_mod.Player;
const Quat = core.math.Quat;
const Report = report_mod.Report;
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
// Fixtures: a pelvis at 0.9 m with a leg below it.

const parents = [_]u16{ no_parent, 0 };
const rest = [_]Transform{ .{ .translation = .init(0, 0.9, 0) }, .{ .translation = .init(0, -0.5, 0) } };
const inverse_bind = [_]Mat4{ Mat4.identity, Mat4.identity };
const skeleton: Skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &inverse_bind };

const ends = [_]f32{ 0, 1 };

/// Forward 0.6 m a lap, and up and back down in the middle.
const stride_times = [_]f32{ 0, 0.5, 1 };
const stride_values = [_]f32{ 0, 0.9, 0, 0, 1.0, -0.3, 0, 0.9, -0.6 };
const stride_tracks = [_]Track{.{ .joint = 0, .path = .translation, .times = &stride_times, .values = &stride_values }};
const stride: Clip = .{ .duration = 1, .tracks = &stride_tracks };

/// Stays put, moving the leg.
const idle_values = [_]f32{ 0, -0.5, 0, 0.1, -0.5, 0 };
const idle_tracks = [_]Track{.{ .joint = 1, .path = .translation, .times = &ends, .values = &idle_values }};
const idle: Clip = .{ .duration = 1, .tracks = &idle_tracks };

const s45: f32 = 0.38268343; // sin 22.5 degrees
const c45: f32 = 0.92387953;
const s90: f32 = 0.70710678;

/// A quarter turn left about +Y over a second, with no travel.
const turn_times = [_]f32{ 0, 0.5, 1 };
const turn_values = [_]f32{ 0, 0, 0, 1, 0, s45, 0, c45, 0, s90, 0, s90 };
const turn_tracks = [_]Track{.{ .joint = 0, .path = .rotation, .times = &turn_times, .values = &turn_values }};
const turn: Clip = .{ .duration = 1, .tracks = &turn_tracks };

/// The same quarter turn, walking forward 1 m in the clip's own frame.
const arc_values = [_]f32{ 0, 0.9, 0, 0, 0.9, -1 };
const arc_tracks = [_]Track{
    .{ .joint = 0, .path = .rotation, .times = &turn_times, .values = &turn_values },
    .{ .joint = 0, .path = .translation, .times = &ends, .values = &arc_values },
};
const arc: Clip = .{ .duration = 1, .tracks = &arc_tracks };

const foot = ContentId.fromString("test:event.foot");
const land = ContentId.fromString("test:event.land");
const start_event = ContentId.fromString("test:event.start");

const step_events = [_]Event{ .{ .at = 0, .id = start_event }, .{ .at = 0.25, .id = foot }, .{ .at = 0.75, .id = foot } };
const once_events = [_]Event{ .{ .at = 0.5, .id = foot }, .{ .at = 1, .id = land } };
const tiny_events = [_]Event{.{ .at = 0.5, .id = foot }};

const name_stride = clipName("stride");
const name_idle = clipName("idle");
const name_turn = clipName("turn");
const name_arc = clipName("arc");
const name_once = clipName("once");
const name_walk = clipName("walk");
const name_tiny = clipName("tiny");
const name_ring = clipName("ring");
const name_short = clipName("short");

fn lessName(_: void, a: RigClip, b: RigClip) bool {
    return a.name < b.name;
}

const clips = blk: {
    @setEvalBranchQuota(100_000);
    var out = [_]RigClip{
        .{ .name = name_stride, .clip = stride, .motion = true, .label = "stride" },
        .{ .name = name_idle, .clip = idle, .label = "idle" },
        .{ .name = name_turn, .clip = turn, .motion = true, .loop = false, .label = "turn" },
        .{ .name = name_arc, .clip = arc, .motion = true, .loop = false, .label = "arc" },
        .{ .name = name_once, .clip = idle, .loop = false, .events = &once_events, .label = "once" },
        .{ .name = name_walk, .clip = idle, .events = &step_events, .label = "a walk with a name longer than a row holds" },
        .{ .name = name_ring, .clip = arc, .motion = true, .label = "ring" },
        .{ .name = name_short, .clip = .{ .duration = 0.017, .tracks = &.{} }, .events = &tiny_events, .label = "short" },
        .{ .name = name_tiny, .clip = .{ .duration = 1e-5, .tracks = &.{} }, .events = &tiny_events, .motion = true, .label = "tiny" },
    };
    std.mem.sort(RigClip, &out, {}, lessName);
    break :blk out;
};
const rig: Rig = .{ .skeleton = skeleton, .clips = &clips, .start = name_idle, .motion_joint = 0 };

fn pelvis(player: *const Player, r: Rig) Transform {
    var a: [2]Transform = @splat(.{});
    var b: [2]Transform = @splat(.{});
    player.evaluate(r, .{ .local = &b }, .{ .local = &a });
    return a[0];
}

/// How many of `id` fired over `ticks` ticks.
fn count(player: *Player, r: Rig, ticks: usize, id: ContentId, tick: f32) u32 {
    var step: Step = .{};
    var total: u32 = 0;
    for (0..ticks) |_| {
        player.advance(r, tick, &step);
        for (step.fired()) |event| {
            if (event.eql(id)) total += 1;
        }
    }
    return total;
}

/// The body a game would keep: where it is and which way it faces, by the rule in `motion.zig`.
const Body = struct {
    position: Vec3 = .zero,
    yaw: f32 = 0,

    fn apply(body: *Body, step: *const Step) void {
        body.position = body.position.add(Quat.fromAxisAngle(.up, body.yaw).rotate(step.motion.translation));
        body.yaw += step.motion.yaw;
    }
};

fn walk(player: *Player, r: Rig, body: *Body, ticks: usize, tick: f32) void {
    var step: Step = .{};
    for (0..ticks) |_| {
        player.advance(r, tick, &step);
        body.apply(&step);
    }
}

// ---------------------------------------------------------------------------------------------
// The rig's refusals

/// A rig of one clip, borrowing the caller's.
fn with(entry: *const RigClip) Rig {
    return .{ .skeleton = skeleton, .clips = entry[0..1], .start = entry.name, .motion_joint = 0 };
}

test "rig: every refusal of an event and a motion joint is named" {
    try rig.validate();
    const id = foot;

    var entry: RigClip = .{ .name = 5, .clip = idle };
    const unnamed = [_]Event{.{ .at = 0, .id = .none }};
    entry.events = &unnamed;
    try t.expectError(error.UnnamedEvent, with(&entry).validate());

    for ([_]f32{ -0.1, 1, 1.5, std.math.nan(f32), std.math.inf(f32) }) |at| {
        const out = [_]Event{.{ .at = at, .id = id }};
        entry.events = &out;
        try t.expectError(error.EventOutOfRange, with(&entry).validate());
    }
    // 1 is a one-shot's end, and on a loop would be the next lap's 0 twice.
    const end = [_]Event{.{ .at = 1, .id = id }};
    entry.events = &end;
    entry.loop = false;
    try with(&entry).validate();
    entry.loop = true;

    const backward = [_]Event{ .{ .at = 0.5, .id = id }, .{ .at = 0.25, .id = id } };
    entry.events = &backward;
    try t.expectError(error.UnsortedEvents, with(&entry).validate());

    const many: [rig_mod.max_events + 1]Event = @splat(.{ .at = 0, .id = id });
    entry.events = &many;
    try t.expectError(error.TooManyEvents, with(&entry).validate());

    // Two events at one time are legal: both fire.
    const together = [_]Event{ .{ .at = 0.5, .id = id }, .{ .at = 0.5, .id = id } };
    entry.events = &together;
    try with(&entry).validate();

    const moving: RigClip = .{ .name = 5, .clip = stride, .motion = true };
    var bad = with(&moving);
    bad.motion_joint = no_parent;
    try t.expectError(error.MissingMotionJoint, bad.validate());
    bad.motion_joint = 2;
    try t.expectError(error.UnknownJoint, bad.validate());
    bad.motion_joint = 1;
    try t.expectError(error.MotionJointNotRoot, bad.validate());
    bad = with(&moving);
    bad.skeleton.root = Mat4.scaling(.init(1, 0, 1));
    try t.expectError(error.SingularRoot, bad.validate());
}

// ---------------------------------------------------------------------------------------------
// Events

test "events: one at 0 fires on the tick a clip starts, and each once a lap" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{});
    var step: Step = .{};
    player.advance(rig, dt, &step);
    try t.expectEqual(@as(u32, 1), step.event_count);
    try t.expect(step.events[0].eql(start_event));
    // Over the next lap the two feet fire, and the start comes round once more.
    var again = player;
    try t.expectEqual(@as(u32, 2), count(&player, rig, 60, foot, dt));
    try t.expectEqual(@as(u32, 1), count(&again, rig, 60, start_event, dt));
}

test "events: a boundary fires once, and a run loses and doubles none at any rate" {
    // 1/8 s a tick lands exactly on every 0.25 and 0.75.
    var exact: Player = .{};
    try exact.play(rig, name_walk, .{});
    try t.expectEqual(@as(u32, 40), count(&exact, rig, 160, foot, 0.125));
    for ([_]f32{ 1.0 / 30.0, 1.0 / 60.0, 1.0 / 144.0 }) |tick| {
        var player: Player = .{};
        try player.play(rig, name_walk, .{});
        const ticks: usize = @intFromFloat(@round(20.1 / tick));
        try t.expectEqual(@as(u32, 40), count(&player, rig, ticks, foot, tick));
    }
}

test "events: a speed change re-anchors between ticks and neither loses nor doubles" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{});
    var total: u32 = 0;
    for (0..40) |i| {
        try player.setSpeed(rig, if (i % 2 == 0) 2 else 1);
        total += count(&player, rig, 15, foot, 0.125 / 3.0);
    }
    // Forty stretches of 0.625 s, half at double speed: 37.5 laps of two feet.
    try t.expectEqual(@as(u32, 75), total);
}

test "events: a short clip at speed fires each lap in a tick, in time order" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{ .speed = 16 });
    var step: Step = .{};
    player.advance(rig, 0.25, &step);
    // Four seconds of clip: 0, .25, .75 four times, of which 12 fit.
    try t.expectEqual(@as(u32, 12), step.event_count);
    try t.expectEqual(@as(u32, 0), step.dropped);
    for (step.fired(), 0..) |event, i| {
        try t.expect(event.eql(if (i % 3 == 0) start_event else foot));
    }
}

test "events: more than a tick holds are counted, and a very short clip ends the search" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{ .speed = 16 });
    var step: Step = .{};
    player.advance(rig, 1, &step);
    try t.expectEqual(@as(u32, player_mod.max_step_events), step.event_count);
    try t.expectEqual(@as(u32, 16 * 3 - player_mod.max_step_events), step.dropped);

    var tiny: Player = .{};
    try tiny.play(rig, name_tiny, .{});
    tiny.advance(rig, dt, &step);
    try t.expectEqual(@as(u32, player_mod.max_step_events), step.event_count);
    try t.expect(step.dropped > 1000);

    // Far on, where one lap more no longer changes an `f64`, the search still ends.
    var far: Player = .{};
    try far.play(rig, name_short, .{ .speed = 16 });
    // Found by search: at this anchor the event's time rounds just below the tick's start.
    far.channels[far.newest].anchor = 9907919180215158.0;
    far.advance(rig, 16, &step);
    try t.expectEqual(@as(u32, 0), step.lost);
}

test "events: a fading channel is silent, and the one fading in fires at once" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{});
    var step: Step = .{};
    player.advance(rig, 0.2, &step);
    try player.play(rig, name_idle, .{ .fade = 10 });
    // The walk is at 0.2 and would fire at 0.25 and 0.75, and it is still the heavier by far.
    try t.expectEqual(@as(u32, 0), count(&player, rig, 5, foot, 0.2));

    try player.play(rig, name_walk, .{ .fade = 10, .phase = .restart });
    player.advance(rig, dt, &step);
    try t.expectEqual(@as(u32, 1), step.event_count);
}

test "events: a one-shot fires its middle and its end once, and nothing after" {
    var player: Player = .{};
    try player.play(rig, name_once, .{});
    try t.expectEqual(@as(u32, 1), count(&player, rig, 40, foot, dt));
    try t.expectEqual(@as(u32, 0), count(&player, rig, 19, land, dt));
    try t.expectEqual(@as(u32, 1), count(&player, rig, 1, land, dt));
    try t.expect(player.finished(rig));
    try t.expectEqual(@as(u32, 0), count(&player, rig, 100, land, dt));
    try t.expectEqual(@as(u32, 0), count(&player, rig, 100, foot, dt));
}

test "events: a one-shot's end landing exactly on a tick still fires once" {
    var player: Player = .{};
    try player.play(rig, name_once, .{});
    try t.expectEqual(@as(u32, 1), count(&player, rig, 8, land, 0.125));
    try t.expectEqual(@as(u32, 0), count(&player, rig, 8, land, 0.125));
}

test "events: speed 0 fires nothing" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{ .speed = 0 });
    try t.expectEqual(@as(u32, 0), count(&player, rig, 100, start_event, dt));
}

// ---------------------------------------------------------------------------------------------
// Seek

test "seek: forward fires what it crosses, once, and backward fires nothing" {
    var player: Player = .{};
    try player.play(rig, name_once, .{});
    var step: Step = .{};
    player.seek(rig, 0.4, dt, &step);
    try t.expectEqual(@as(u32, 0), step.event_count);
    player.seek(rig, 0.6, dt, &step);
    try t.expectEqual(@as(u32, 1), step.event_count);
    try t.expect(step.events[0].eql(foot));
    player.seek(rig, 0.6, dt, &step);
    try t.expectEqual(@as(u32, 0), step.event_count);
    player.seek(rig, 1, dt, &step);
    try t.expectEqual(@as(u32, 1), step.event_count);
    try t.expect(step.events[0].eql(land));
    try t.expect(player.finished(rig));
    player.seek(rig, 1, dt, &step);
    try t.expectEqual(@as(u32, 0), step.event_count);
    player.seek(rig, 0, dt, &step);
    try t.expectEqual(@as(u32, 0), step.event_count);
    try t.expect(!player.finished(rig));
    player.seek(rig, 0.6, dt, &step);
    try t.expectEqual(@as(u32, 1), step.event_count);
}

test "seek: on a loop it stays in the lap it is in, and goes at most to the lap's end" {
    var player: Player = .{};
    try player.play(rig, name_walk, .{});
    try t.expectEqual(@as(u32, 5), count(&player, rig, 5, foot, 0.5));
    var step: Step = .{};
    player.seek(rig, 0.8, dt, &step);
    // From 2.5 into this lap's 0.8, over the 0.75 alone.
    try t.expectEqual(@as(u32, 1), step.event_count);
    player.seek(rig, 7, dt, &step);
    // To the lap's end, and no further: nothing lies between 0.8 and it.
    try t.expectEqual(@as(u32, 0), step.event_count);
}

test "seek: a fraction out of range is held, and a NaN is the start" {
    var player: Player = .{};
    try player.play(rig, name_once, .{});
    var step: Step = .{};
    player.seek(rig, 7, dt, &step);
    try t.expect(player.finished(rig));
    player.seek(rig, std.math.nan(f32), dt, &step);
    try t.expect(!player.finished(rig));
}

test "seek: a fade carries on, and a seek repairs as a tick does" {
    var player: Player = .{};
    try player.play(rig, name_idle, .{});
    var step: Step = .{};
    player.advance(rig, dt, &step);
    try player.play(rig, name_once, .{ .fade = 0.5 });
    player.seek(rig, 0.1, dt, &step);
    try t.expectApproxEqAbs(dt / 0.5, player.channels[player.newest].weight, 1e-5);
    for (0..40) |_| player.seek(rig, 0.1, dt, &step);
    try t.expectEqual(@as(f32, 1), player.channels[player.newest].weight);

    var bad: Player = .{};
    bad.newest = 99;
    bad.seek(rig, 0.5, dt, &step);
    try t.expect(bad.playing(name_idle));
}

test "seek: travel follows a forward seek, and a backward one reports none" {
    var player: Player = .{};
    try player.play(rig, name_arc, .{});
    var step: Step = .{};
    player.seek(rig, 0.5, dt, &step);
    try t.expect(step.motion.translation.length() > 0.1);
    player.seek(rig, 0.25, dt, &step);
    try t.expectEqual(@as(f32, 0), step.motion.translation.length());
    try t.expectEqual(@as(f32, 0), step.motion.yaw);
}

// ---------------------------------------------------------------------------------------------
// Root motion

test "motion: a straight clip travels its distance, and the body's Y never moves" {
    var player: Player = .{};
    try player.play(rig, name_stride, .{});
    var body: Body = .{};
    walk(&player, rig, &body, 60, dt);
    try t.expectApproxEqAbs(@as(f32, -0.6), body.position.z, 1e-4);
    try t.expectEqual(@as(f32, 0), body.position.y);
    try t.expectEqual(@as(f32, 0), body.position.x);
}

test "motion: a loop's boundary loses nothing, at 30 and at 60 ticks a second" {
    for ([_]f32{ 1.0 / 30.0, 1.0 / 60.0, 1.0 / 7.0 }) |tick| {
        var player: Player = .{};
        try player.play(rig, name_stride, .{});
        var body: Body = .{};
        const ticks: usize = @intFromFloat(@round(3.5 / tick));
        walk(&player, rig, &body, ticks, tick);
        const seconds = @as(f32, @floatFromInt(ticks)) * tick;
        // The track is piecewise, so read the expected place off it: 0.6 a lap, in two halves.
        const lap: f32 = seconds - @floor(seconds);
        try t.expectApproxEqAbs(-(0.6 * @floor(seconds) + 0.6 * lap), body.position.z, 2e-3);
    }
}

test "motion: a lap's end inside a tick carries the turn into the next lap's travel" {
    var player: Player = .{};
    try player.play(rig, name_ring, .{});
    var body: Body = .{};
    walk(&player, rig, &body, 1, 1.5);
    // A lap: a metre along -Z, turning left a quarter. Half a lap more, in the frame that left:
    // half a metre along what is now -X, and an eighth of a turn.
    try t.expectApproxEqAbs(@as(f32, -0.5), body.position.x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, -1), body.position.z, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 3.0 * std.math.pi / 4.0), body.yaw, 1e-3);
}

test "motion: several laps in one tick still add up" {
    var player: Player = .{};
    try player.play(rig, name_stride, .{ .speed = 8 });
    var body: Body = .{};
    walk(&player, rig, &body, 1, 0.5);
    try t.expectApproxEqAbs(@as(f32, -2.4), body.position.z, 1e-3);
}

test "motion: blending shares a delta by weight, so a walk fading to idle slows" {
    var player: Player = .{};
    try player.play(rig, name_stride, .{});
    var step: Step = .{};
    player.advance(rig, dt, &step);
    const full = step.motion.translation.z;
    try player.play(rig, name_idle, .{ .fade = 1 });
    var last = full;
    for (0..30) |_| {
        player.advance(rig, dt, &step);
        try t.expect(step.motion.translation.z > last - 1e-6 or last == full);
        last = step.motion.translation.z;
    }
    try t.expectApproxEqAbs(full * 0.5, last, 1e-3);
    for (0..31) |_| player.advance(rig, dt, &step);
    try t.expectEqual(@as(f32, 0), step.motion.translation.z);
}

test "motion: the pose holds the joint on the floor and keeps its height" {
    var player: Player = .{};
    try player.play(rig, name_stride, .{});
    var step: Step = .{};
    for (0..30) |_| player.advance(rig, dt, &step);
    const held = pelvis(&player, rig);
    try t.expectApproxEqAbs(@as(f32, 0), held.translation.x, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0), held.translation.z, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 1.0), held.translation.y, 1e-4);
}

test "motion: a clip with no motion joint set keeps its travel in the pose" {
    var player: Player = .{};
    const plain: RigClip = .{ .name = 5, .clip = stride };
    var r = with(&plain);
    r.motion_joint = no_parent;
    try r.validate();
    try player.play(r, 5, .{});
    var step: Step = .{};
    for (0..30) |_| player.advance(r, dt, &step);
    try t.expectEqual(@as(f32, 0), step.motion.translation.length());
    try t.expectApproxEqAbs(@as(f32, -0.3), pelvis(&player, r).translation.z, 1e-3);
}

test "motion: yaw comes through as a twist, and leaves the pose" {
    var player: Player = .{};
    try player.play(rig, name_turn, .{});
    var body: Body = .{};
    walk(&player, rig, &body, 30, dt);
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), body.yaw, 1e-3);
    const held = pelvis(&player, rig);
    try t.expect(held.rotation.approxEql(.identity, 1e-3));
    walk(&player, rig, &body, 60, dt);
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), body.yaw, 1e-3);
    try t.expectEqual(@as(f32, 0), body.position.length());
}

test "motion: a swing about another axis stays in the pose" {
    const swing_values = [_]f32{ 0, 0, 0, 1, s90, 0, 0, s90 };
    const swing_tracks = [_]Track{.{ .joint = 0, .path = .rotation, .times = &ends, .values = &swing_values }};
    const entry: RigClip = .{ .name = 5, .clip = .{ .duration = 1, .tracks = &swing_tracks }, .motion = true };
    const r = with(&entry);
    var player: Player = .{};
    try player.play(r, 5, .{});
    var step: Step = .{};
    for (0..30) |_| {
        player.advance(r, dt, &step);
        try t.expectApproxEqAbs(@as(f32, 0), step.motion.yaw, 1e-5);
    }
    const q = pelvis(&player, r).rotation;
    try t.expect(q.approxEql(.{ .x = s45, .y = 0, .z = 0, .w = c45 }, 1e-3));
}

test "motion: a clip that turns as it walks keeps to its track, whichever way the body faced" {
    // The track is a straight metre in the frame the clip began in, so that is where the body
    // goes, for all that it turns on the way.
    var player: Player = .{};
    try player.play(rig, name_arc, .{});
    var body: Body = .{};
    walk(&player, rig, &body, 60, dt);
    try t.expectApproxEqAbs(@as(f32, -1), body.position.z, 2e-3);
    try t.expectApproxEqAbs(@as(f32, 0), body.position.x, 2e-3);
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), body.yaw, 1e-3);

    // Facing -X to begin with, the same clip goes a metre that way.
    var turned_player: Player = .{};
    try turned_player.play(rig, name_arc, .{});
    var turned_body: Body = .{ .yaw = std.math.pi / 2.0 };
    walk(&turned_player, rig, &turned_body, 60, dt);
    try t.expectApproxEqAbs(@as(f32, -1), turned_body.position.x, 2e-3);
    try t.expectApproxEqAbs(@as(f32, 0), turned_body.position.z, 2e-3);
}

test "motion: a rotated root turns the delta into model space, and the twist axis with it" {
    // +X up in the joint's frame, as a Z-up export baked by `front` might leave it.
    const root = Mat4.fromQuat(.fromAxisAngle(.init(0, 0, 1), std.math.pi / 2.0));
    const values = [_]f32{ 0, 0, 0, 0, 0, -1 };
    const tracks = [_]Track{.{ .joint = 0, .path = .translation, .times = &ends, .values = &values }};
    // Joint +Y is model -X, and joint +X is model up.
    const across = [_]f32{ 0, 0, 0, 0, 1, 0 };
    const across_tracks = [_]Track{.{ .joint = 0, .path = .translation, .times = &ends, .values = &across }};
    const about_x = [_]f32{ 0, 0, 0, 1, s90, 0, 0, s90 };
    const rotation = [_]Track{.{ .joint = 0, .path = .rotation, .times = &ends, .values = &about_x }};
    const about_y = [_]f32{ 0, 0, 0, 1, 0, s90, 0, s90 };
    const not_up = [_]Track{.{ .joint = 0, .path = .rotation, .times = &ends, .values = &about_y }};

    const entries = [_]RigClip{
        .{ .name = 1, .clip = .{ .duration = 1, .tracks = &tracks }, .motion = true },
        .{ .name = 2, .clip = .{ .duration = 1, .tracks = &rotation }, .motion = true },
        .{ .name = 3, .clip = .{ .duration = 1, .tracks = &not_up }, .motion = true },
        .{ .name = 4, .clip = .{ .duration = 1, .tracks = &across_tracks }, .motion = true },
    };
    var r: Rig = .{ .skeleton = skeleton, .clips = &entries, .start = 1, .motion_joint = 0 };
    r.skeleton.root = root;
    try r.validate();
    try t.expectApproxEqAbs(@as(f32, 1), r.motionSpeed(1), 1e-5);

    var player: Player = .{};
    try player.play(r, 1, .{});
    var body: Body = .{};
    walk(&player, r, &body, 59, dt);
    try t.expectApproxEqAbs(@as(f32, -59.0 / 60.0), body.position.z, 1e-3);

    var turning: Player = .{};
    try turning.play(r, 2, .{});
    var turned_body: Body = .{};
    walk(&turning, r, &turned_body, 59, dt);
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0 * 59.0 / 60.0), turned_body.yaw, 1e-3);
    try t.expect(pelvis(&turning, r).rotation.approxEql(.identity, 1e-3));

    var other: Player = .{};
    try other.play(r, 3, .{});
    var still: Body = .{};
    walk(&other, r, &still, 59, dt);
    try t.expectApproxEqAbs(@as(f32, 0), still.yaw, 1e-4);

    var sideways: Player = .{};
    try sideways.play(r, 4, .{});
    var side_body: Body = .{};
    walk(&sideways, r, &side_body, 59, dt);
    try t.expectApproxEqAbs(@as(f32, -59.0 / 60.0), side_body.position.x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 0), pelvis(&sideways, r).translation.y, 1e-4);
}

test "motion: speed is measured off the clip, at its authored rate" {
    try t.expectApproxEqAbs(@as(f32, 0.6), rig.motionSpeed(name_stride), 1e-5);
    try t.expectEqual(@as(f32, 0), rig.motionSpeed(name_idle));
    try t.expectEqual(@as(f32, 0), rig.motionSpeed(7));
    const fast: RigClip = .{ .name = 5, .clip = stride, .motion = true, .speed = 2 };
    try t.expectApproxEqAbs(@as(f32, 1.2), with(&fast).motionSpeed(5), 1e-5);
}

// ---------------------------------------------------------------------------------------------
// Report

test "report: a row per player, the rest counted, names cut short" {
    var report: Report = .{};
    var player: Player = .{};
    try player.play(rig, name_stride, .{});
    var step: Step = .{};
    player.advance(rig, dt, &step);
    try player.play(rig, name_walk, .{ .fade = 1, .speed = 2 });
    player.advance(rig, dt, &step);
    try t.expectEqual(@as(u32, 1), step.event_count);
    for (0..report_mod.max_rows + 2) |_| report.add(&player, rig, "a figure", &step);

    try t.expectEqual(@as(u32, report_mod.max_rows + 2), report.players);
    try t.expectEqual(@as(u32, report_mod.max_rows), report.row_count);
    try t.expectEqual(@as(u32, report_mod.max_rows + 2), report.events);

    const row = &report.rows[0];
    try t.expectEqualStrings("a figure", row.label());
    try t.expect(!row.machine);
    try t.expectEqual(@as(u8, 1), row.layer_count);
    const base = &row.layers[0];
    try t.expectEqual(@as(u8, 2), base.channel_count);
    try t.expectEqual(@as(u32, 1), row.events);
    try t.expectEqualStrings("stride", base.channels[0].label());
    try t.expectEqualStrings("a walk with a name longe", base.channels[1].label());
    try t.expectApproxEqAbs(dt * 2, base.channels[0].time, 1e-5);
    try t.expectEqual(@as(f32, 2), base.channels[1].speed);
}

test "report: a clip the rig lacks is left out rather than guessed at" {
    var report: Report = .{};
    var player: Player = .{};
    player.channels[0] = .{ .clip = 7, .speed = 1, .weight = 1 };
    const step: Step = .{ .lost = 1, .dropped = 2 };
    report.add(&player, rig, "lost", &step);
    try t.expectEqual(@as(u8, 0), report.rows[0].layers[0].channel_count);
    try t.expectEqual(@as(u32, 1), report.lost);
    try t.expectEqual(@as(u32, 2), report.dropped);
}

// ---------------------------------------------------------------------------------------------
// Replay

test "replay: events, motion and pose together are byte-identical, and pinned" {
    const run = struct {
        fn go() u64 {
            var player: Player = .{};
            var step: Step = .{};
            var a: [2]Transform = @splat(.{});
            var b: [2]Transform = @splat(.{});
            var hash: u64 = 0xcbf29ce484222325;
            const feed = struct {
                fn in(h: *u64, bytes: []const u8) void {
                    for (bytes) |byte| h.* = (h.* ^ byte) *% 0x100000001b3;
                }
            }.in;
            for (0..1200) |tick| {
                switch (tick % 300) {
                    10 => player.play(rig, name_stride, .{ .fade = 0.25 }) catch unreachable,
                    90 => player.play(rig, name_arc, .{ .fade = 0.25 }) catch unreachable,
                    100 => player.play(rig, name_walk, .{ .fade = 0.5, .phase = .keep }) catch unreachable,
                    180 => player.setSpeed(rig, 1.5) catch unreachable,
                    220 => player.play(rig, name_turn, .{ .fade = 0.1 }) catch unreachable,
                    else => {},
                }
                player.advance(rig, dt, &step);
                player.evaluate(rig, .{ .local = &b }, .{ .local = &a });
                for (a) |joint| {
                    feed(&hash, std.mem.asBytes(&joint.translation));
                    feed(&hash, std.mem.asBytes(&joint.rotation));
                }
                feed(&hash, std.mem.asBytes(&step.motion.translation));
                feed(&hash, std.mem.asBytes(&step.motion.yaw));
                for (step.fired()) |event| feed(&hash, std.mem.asBytes(&event.hash));
            }
            return hash;
        }
    }.go;
    const a = run();
    try t.expectEqual(a, run());

    // One value on all four builds so far: this run's rotations meet none of the inputs on which
    // the two `sin`s differ. A second value would be recorded here, as `tests.zig` does.
    try t.expectEqual(@as(u64, 0xad558f6b1a182eac), a);
}
