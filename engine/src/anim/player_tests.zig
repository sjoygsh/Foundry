//! `animation-logic.md` §13's `anim` tests for playback: refusals, time, channels, what a player
//! does with untrusted state, and a replay. No device, no asset and no allocator under test.

const std = @import("std");
const core = @import("core");

const clip_mod = @import("clip.zig");
const player_mod = @import("player.zig");
const pose_mod = @import("pose.zig");
const rig_mod = @import("rig.zig");
const skeleton_mod = @import("skeleton.zig");

const Channel = player_mod.Channel;
const Clip = clip_mod.Clip;
const Mat4 = core.math.Mat4;
const Player = player_mod.Player;
const Pose = pose_mod.Pose;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;
const Skeleton = skeleton_mod.Skeleton;
const Step = player_mod.Step;
const Track = clip_mod.Track;
const Transform = core.math.Transform;

const clipName = rig_mod.clipName;
const t = std.testing;
const dt: f32 = 1.0 / 60.0;

// ---------------------------------------------------------------------------------------------
// Fixtures: one joint, whose X is a clip's own ramp, so a pose reads back as the time that made it.

const parents = [_]u16{skeleton_mod.no_parent};
const rest = [_]Transform{.{}};
const inverse_bind = [_]Mat4{Mat4.identity};
const skeleton: Skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &inverse_bind };

const up_times = [_]f32{ 0, 1 };
const up_values = [_]f32{ 0, 0, 0, 1, 0, 0 };
const up_tracks = [_]Track{.{ .joint = 0, .path = .translation, .times = &up_times, .values = &up_values }};
/// X runs 0 to 1 over a second.
const up: Clip = .{ .duration = 1, .tracks = &up_tracks };

const high_times = [_]f32{ 0, 2 };
const high_values = [_]f32{ 10, 0, 0, 12, 0, 0 };
const high_tracks = [_]Track{.{ .joint = 0, .path = .translation, .times = &high_times, .values = &high_values }};
/// X runs 10 to 12 over two seconds.
const high: Clip = .{ .duration = 2, .tracks = &high_tracks };

const low_values = [_]f32{ -5, 0, 0, -5, 0, 0 };
const low_tracks = [_]Track{.{ .joint = 0, .path = .translation, .times = &up_times, .values = &low_values }};
/// X holds at -5.
const low: Clip = .{ .duration = 1, .tracks = &low_tracks };

const name_up = clipName("up");
const name_high = clipName("high");
const name_low = clipName("low");
const name_once = clipName("once");
const name_slow = clipName("slow");

fn sorted(comptime entries: []const RigClip) [entries.len]RigClip {
    var out: [entries.len]RigClip = entries[0..entries.len].*;
    std.mem.sort(RigClip, &out, {}, struct {
        fn less(_: void, a: RigClip, b: RigClip) bool {
            return a.name < b.name;
        }
    }.less);
    return out;
}

const clips = blk: {
    @setEvalBranchQuota(100_000);
    break :blk sorted(&.{
        .{ .name = name_up, .clip = up },
        .{ .name = name_high, .clip = high },
        .{ .name = name_low, .clip = low },
        .{ .name = name_once, .clip = up, .loop = false },
        .{ .name = name_slow, .clip = up, .speed = 0.5 },
    });
};
const rig: Rig = .{ .skeleton = skeleton, .clips = &clips, .start = name_up };

fn poseX(player: *const Player) f32 {
    var a = [_]Transform{.{}};
    var b = [_]Transform{.{}};
    player.evaluate(rig, .{ .local = &b }, .{ .local = &a });
    return a[0].translation.x;
}

fn run(player: *Player, ticks: usize) void {
    var step: Step = .{};
    for (0..ticks) |_| player.advance(rig, dt, &step);
}

fn weightSum(player: *const Player) f32 {
    var sum: f32 = 0;
    for (player.channels) |channel| sum += channel.weight;
    return sum;
}

fn live(player: *const Player) usize {
    var count: usize = 0;
    for (player.channels) |channel| {
        if (channel.clip != 0) count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------------------------
// The rig

test "rig: a valid rig is accepted, and every refusal is named" {
    try rig.validate();

    var bad = rig;
    bad.clips = &.{};
    try t.expectError(error.NoClips, bad.validate());
    bad = rig;
    bad.start = 7;
    try t.expectError(error.UnknownStart, bad.validate());
    bad = rig;
    bad.skeleton.parents = &.{};
    try t.expectError(error.NoJoints, bad.validate());

    const zero = [_]RigClip{.{ .name = 0, .clip = up }};
    bad = rig;
    bad.clips = &zero;
    try t.expectError(error.UnnamedClip, bad.validate());

    const twice = [_]RigClip{ .{ .name = 5, .clip = up }, .{ .name = 5, .clip = up } };
    bad.clips = &twice;
    bad.start = 5;
    try t.expectError(error.NameCollision, bad.validate());

    const backward = [_]RigClip{ .{ .name = 9, .clip = up }, .{ .name = 5, .clip = up } };
    bad.clips = &backward;
    try t.expectError(error.UnsortedClips, bad.validate());

    for ([_]f32{ 0, -1, 16.5, std.math.nan(f32), std.math.inf(f32) }) |speed| {
        const fast = [_]RigClip{.{ .name = 5, .clip = up, .speed = speed }};
        bad.clips = &fast;
        try t.expectError(error.InvalidSpeed, bad.validate());
    }

    // A clip's own refusals come through: its one track names a joint this skeleton lacks.
    const wide_tracks = [_]Track{.{ .joint = 1, .path = .translation, .times = &up_times, .values = &up_values }};
    const wide = [_]RigClip{.{ .name = 5, .clip = .{ .duration = 1, .tracks = &wide_tracks } }};
    bad.clips = &wide;
    try t.expectError(error.UnknownJoint, bad.validate());

    bad.clips = (&[_]RigClip{.{ .name = 5, .clip = up }} ** 1)[0..1];
    try bad.validate();
    var many: [rig_mod.max_clips + 1]RigClip = undefined;
    for (&many, 0..) |*entry, i| entry.* = .{ .name = i + 1, .clip = up };
    bad.clips = &many;
    bad.start = 1;
    try t.expectError(error.TooManyClips, bad.validate());
}

test "rig: find answers every clip, and null for one it lacks" {
    for (rig.clips) |*entry| try t.expectEqual(entry, rig.find(entry.name).?);
    try t.expect(rig.find(1) == null);
    try t.expect(rig.find(std.math.maxInt(u64)) == null);
}

// ---------------------------------------------------------------------------------------------
// Time

test "time: a new player shows its start clip, and begins it on its first tick" {
    var player: Player = .{};
    try t.expectEqual(@as(f32, 0), poseX(&player));
    run(&player, 1);
    try t.expectEqual(@as(usize, 1), live(&player));
    try t.expect(player.playing(name_up));
    try t.expectApproxEqAbs(dt, poseX(&player), 1e-6);
}

test "time: a looping clip wraps, a one-shot holds its end and says so" {
    var player: Player = .{};
    run(&player, 90);
    try t.expectApproxEqAbs(@as(f32, 0.5), poseX(&player), 1e-4);
    try t.expect(!player.finished(rig));

    try player.play(rig, name_once, .{});
    run(&player, 59);
    try t.expect(!player.finished(rig));
    run(&player, 1);
    try t.expect(player.finished(rig));
    run(&player, 200);
    try t.expectApproxEqAbs(@as(f32, 1), poseX(&player), 1e-5);
}

test "time: the rate is the channel's speed by the clip's authored speed" {
    var player: Player = .{};
    try player.play(rig, name_slow, .{ .speed = 0.5 });
    run(&player, 30);
    try t.expectApproxEqAbs(@as(f32, 0.125), poseX(&player), 1e-5);
}

test "time: a change of speed moves no pose, and speed 0 holds" {
    var player: Player = .{};
    run(&player, 20);
    const before = poseX(&player);
    try player.setSpeed(rig, 2);
    try t.expectEqual(before, poseX(&player));
    run(&player, 10);
    try t.expectApproxEqAbs(before + 2.0 * 10.0 * dt, poseX(&player), 1e-5);
    const held = poseX(&player);
    try player.setSpeed(rig, 0);
    run(&player, 100);
    try t.expectEqual(held, poseX(&player));

    // Backward is a speed (`animation-states.md` §3); past 16 either way is not.
    try t.expectError(error.InvalidSpeed, player.setSpeed(rig, -17));
    try t.expectError(error.InvalidSpeed, player.setSpeed(rig, std.math.nan(f32)));
}

test "time: a change of step keeps the ticks already counted at what they were worth" {
    var player: Player = .{};
    var step: Step = .{};
    run(&player, 30);
    player.advance(rig, dt * 2, &step);
    try t.expectApproxEqAbs(@as(f32, 0.5) + dt * 2, poseX(&player), 1e-5);
}

test "time: a day's run still resolves a tick" {
    var player: Player = .{ .dt = dt };
    player.channels[0] = .{ .clip = name_high, .speed = 1, .weight = 1, .ticks = 60 * 60 * 60 * 24 };
    player.newest = 0;
    const a = poseX(&player);
    run(&player, 1);
    const b = poseX(&player);
    // X runs at half a metre a second here, so this is half a tick of it. `f32` seconds a day
    // in are 8 ms apart, half a tick, which would not come out even.
    try t.expectApproxEqAbs(dt, b - a, 2e-5);
}

test "time: M24's tick-times-step formula agrees across a walker's run" {
    var player: Player = .{};
    var a = [_]Transform{.{}};
    for (1..2101) |tick| {
        run(&player, 1);
        const m24 = @as(f32, @floatFromInt(tick)) * dt;
        pose_mod.sample(skeleton, up, pose_mod.wrap(m24, up.duration), .{ .local = &a });
        const now = poseX(&player);
        // Either side of a wrap, the two are a lap apart for one tick.
        if (@abs(a[0].translation.x - now) > 0.5) continue;
        try t.expectApproxEqAbs(a[0].translation.x, now, 1e-4);
    }
}

// ---------------------------------------------------------------------------------------------
// Channels

test "channels: a fade with nothing to fade from is at full weight at once" {
    var player: Player = .{};
    try player.play(rig, name_low, .{ .fade = 1 });
    try t.expectEqual(@as(f32, -5), poseX(&player));
    try t.expectEqual(@as(f32, 1), player.channels[player.newest].weight);
}

test "channels: a cut replaces everything at once" {
    var player: Player = .{};
    run(&player, 10);
    try player.play(rig, name_low, .{});
    try t.expectEqual(@as(usize, 1), live(&player));
    try t.expectEqual(@as(f32, -5), poseX(&player));
}

test "channels: a fade mixes in proportion, ends on the new clip and keeps the sum" {
    var player: Player = .{};
    try player.play(rig, name_low, .{});
    run(&player, 1);
    try player.play(rig, name_high, .{ .fade = 0.5 });
    try t.expectEqual(@as(f32, -5), poseX(&player));
    run(&player, 15);
    try t.expectApproxEqAbs(@as(f32, 1), weightSum(&player), 1e-5);
    // Halfway, between -5 and a little over 10.
    try t.expectApproxEqAbs(@as(f32, (-5.0 + 10.0 + 0.25) / 2.0), poseX(&player), 1e-2);
    run(&player, 15);
    try t.expectEqual(@as(usize, 1), live(&player));
    try t.expectEqual(@as(f32, 1), weightSum(&player));
    try t.expect(player.playing(name_high));
}

test "channels: reversing mid-fade keeps the clip's time and moves no pose" {
    var player: Player = .{};
    try player.play(rig, name_up, .{});
    run(&player, 20);
    try player.play(rig, name_high, .{ .fade = 1 });
    run(&player, 20);
    const before = poseX(&player);
    const time_up = player.channels[0].ticks;
    try player.play(rig, name_up, .{ .fade = 1, .phase = .keep });
    try t.expectEqual(before, poseX(&player));
    try t.expectEqual(time_up, player.channels[0].ticks);
    try t.expectEqual(@as(usize, 2), live(&player));
    run(&player, 1);
    try t.expect(player.channels[0].weight > 1.0 - 21.0 / 60.0);
}

test "channels: a third and a fifth request are held, and the lightest gives way" {
    var player: Player = .{};
    try player.play(rig, name_low, .{});
    run(&player, 1);
    try player.play(rig, name_high, .{ .fade = 1 });
    run(&player, 10);
    try player.play(rig, name_up, .{ .fade = 1 });
    run(&player, 10);
    try t.expectEqual(@as(usize, 3), live(&player));
    try t.expectApproxEqAbs(@as(f32, 1), weightSum(&player), 1e-5);

    try player.play(rig, name_once, .{ .fade = 1 });
    run(&player, 10);
    try t.expectEqual(@as(usize, 4), live(&player));

    const lightest = blk: {
        var at: usize = 0;
        for (player.channels, 0..) |channel, i| {
            if (channel.weight < player.channels[at].weight) at = i;
        }
        break :blk at;
    };
    const gone = player.channels[lightest].clip;
    const others = [_]u64{ name_low, name_high, name_up, name_once };
    try player.play(rig, name_slow, .{ .fade = 1 });
    try t.expectEqual(@as(usize, 4), live(&player));
    try t.expect(player.playing(name_slow));
    for (others) |name| {
        var found = false;
        for (player.channels) |channel| found = found or channel.clip == name;
        try t.expectEqual(name != gone, found);
    }
    run(&player, 1);
    try t.expectApproxEqAbs(@as(f32, 1), weightSum(&player), 1e-5);
    run(&player, 60);
    try t.expectEqual(@as(usize, 1), live(&player));
}

test "channels: keep takes the newest's time, restart begins, and a restart on the newest begins again" {
    var player: Player = .{};
    run(&player, 30);
    try player.play(rig, name_low, .{ .phase = .keep });
    run(&player, 30);
    try player.play(rig, name_high, .{ .phase = .keep });
    try t.expectApproxEqAbs(@as(f32, 11), poseX(&player), 1e-4);

    try player.play(rig, name_once, .{});
    try t.expectEqual(@as(f32, 0), poseX(&player));
    run(&player, 120);
    try t.expect(player.finished(rig));
    try player.play(rig, name_once, .{});
    try t.expect(!player.finished(rig));
    try t.expectEqual(@as(f32, 0), poseX(&player));
}

test "channels: every refusal is named and changes nothing" {
    var player: Player = .{};
    run(&player, 10);
    const before = player;
    try t.expectError(error.UnknownClip, player.play(rig, 7, .{}));
    try t.expectError(error.InvalidFade, player.play(rig, name_low, .{ .fade = -1 }));
    try t.expectError(error.InvalidFade, player.play(rig, name_low, .{ .fade = std.math.nan(f32) }));
    try t.expectError(error.InvalidSpeed, player.play(rig, name_low, .{ .speed = 17 }));
    try t.expectEqual(before, player);
}

// ---------------------------------------------------------------------------------------------
// Untrusted state

test "untrusted: a clip gone from the rig is emptied and counted, and the player begins again" {
    var player: Player = .{};
    try player.play(rig, name_low, .{});
    run(&player, 5);
    player.channels[0].clip = 7;
    try t.expectEqual(@as(f32, 0), poseX(&player));
    var step: Step = .{};
    player.advance(rig, dt, &step);
    try t.expectEqual(@as(u32, 1), step.lost);
    try t.expect(player.playing(name_up));
    player.advance(rig, dt, &step);
    try t.expectEqual(@as(u32, 0), step.lost);
}

test "untrusted: the survivor of a lost channel carries on" {
    var player: Player = .{};
    try player.play(rig, name_low, .{});
    run(&player, 1);
    try player.play(rig, name_high, .{ .fade = 1 });
    run(&player, 6);
    player.channels[player.newest].clip = 7;
    var step: Step = .{};
    player.advance(rig, dt, &step);
    try t.expectEqual(@as(u32, 1), step.lost);
    try t.expect(player.playing(name_low));
    try t.expectEqual(@as(f32, -5), poseX(&player));
}

test "untrusted: bad values empty a channel and never assert" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f64);
    const bad = [_]Channel{
        .{ .clip = name_up, .speed = nan, .weight = 1 },
        .{ .clip = name_up, .speed = 1000, .weight = 1 },
        .{ .clip = name_up, .speed = -17, .weight = 1 },
        .{ .clip = name_up, .speed = 1, .weight = nan },
        .{ .clip = name_up, .speed = 1, .weight = 2 },
        .{ .clip = name_up, .speed = 1, .weight = -1 },
        .{ .clip = name_up, .speed = 1, .weight = 1, .anchor = inf },
        .{ .clip = name_up, .speed = 1, .weight = 1, .anchor = -inf },
    };
    for (bad) |channel| {
        var player: Player = .{};
        player.channels[0] = channel;
        try t.expect(std.math.isFinite(poseX(&player)));
        var step: Step = .{};
        player.advance(rig, dt, &step);
        try t.expectEqual(@as(u32, 1), step.lost);
        try t.expect(std.math.isFinite(poseX(&player)));
    }
}

test "untrusted: a bad newest, fade or step are repaired" {
    var player: Player = .{};
    run(&player, 3);
    player.newest = 99;
    player.fade = -1;
    player.dt = std.math.nan(f32);
    try t.expect(!player.finished(rig));
    try t.expect(!player.playing(name_up));
    try player.setSpeed(rig, 1);
    run(&player, 1);
    try t.expect(player.playing(name_up));
    try t.expectEqual(@as(f32, 0), player.fade);
    try t.expectEqual(dt, player.dt);

    // Weights that all read zero still show a pose.
    var silent: Player = .{};
    silent.channels[2] = .{ .clip = name_low, .speed = 1 };
    silent.newest = 2;
    try t.expectEqual(@as(f32, 0), poseX(&silent));
    run(&silent, 1);
    try t.expectEqual(@as(f32, -5), poseX(&silent));
}

test "a player's layout is what foundry:animator lays over" {
    try t.expectEqual(@as(usize, 32), @sizeOf(Channel));
    try t.expectEqual(@as(usize, 144), @sizeOf(Player));
    try t.expectEqual(@as(usize, 128), @offsetOf(Player, "fade"));
}

// ---------------------------------------------------------------------------------------------
// Replay

fn replay(out: []u8) u64 {
    // Rotation keys, so the bytes depend on `slerp` as a walker's do.
    const sway_times = [_]f32{ 0, 0.5, 1 };
    const sway_values = [_]f32{ 0, 0, 0, 1, 0, 0.247404, 0, 0.968912, 0, 0, 0, 1 };
    const tracks = [_]Track{
        .{ .joint = 0, .path = .translation, .times = &up_times, .values = &up_values },
        .{ .joint = 0, .path = .rotation, .times = &sway_times, .values = &sway_values },
    };
    const sway: RigClip = .{ .name = clipName("sway"), .clip = .{ .duration = 1, .tracks = &tracks } };
    var list = clips ++ [_]RigClip{sway};
    std.mem.sort(RigClip, &list, {}, struct {
        fn less(_: void, a: RigClip, b: RigClip) bool {
            return a.name < b.name;
        }
    }.less);
    const r: Rig = .{ .skeleton = skeleton, .clips = &list, .start = name_up };

    var player: Player = .{};
    var step: Step = .{};
    var a = [_]Transform{.{}};
    var b = [_]Transform{.{}};
    var hash: u64 = 0xcbf29ce484222325;
    var at: usize = 0;
    for (0..1200) |tick| {
        // A fixed score of cuts, fades, interruptions and a speed change.
        switch (tick % 240) {
            30 => player.play(r, sway.name, .{ .fade = 0.25, .phase = .keep }) catch unreachable,
            37 => player.play(r, name_high, .{ .fade = 0.5 }) catch unreachable,
            44 => player.play(r, sway.name, .{ .fade = 0.5, .phase = .keep }) catch unreachable,
            120 => player.setSpeed(r, 1.5) catch unreachable,
            180 => player.play(r, name_once, .{ .fade = 0.25 }) catch unreachable,
            230 => player.play(r, name_up, .{ .fade = 0.1 }) catch unreachable,
            else => {},
        }
        player.advance(r, dt, &step);
        player.evaluate(r, .{ .local = &b }, .{ .local = &a });
        const bytes = std.mem.asBytes(&a[0].translation) ++ std.mem.asBytes(&a[0].rotation) ++ std.mem.asBytes(&a[0].scale);
        @memcpy(out[at..][0..bytes.len], bytes);
        at += bytes.len;
        for (bytes) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    }
    return hash;
}

test "replay: 1200 ticks of cuts, fades and interruptions are byte-identical" {
    const size = 1200 * (@sizeOf(core.math.Vec3) * 2 + @sizeOf(core.math.Quat));
    const first = try t.allocator.alloc(u8, size);
    defer t.allocator.free(first);
    const second = try t.allocator.alloc(u8, size);
    defer t.allocator.free(second);
    const a = replay(first);
    const b = replay(second);
    try t.expectEqualSlices(u8, first, second);
    try t.expectEqual(a, b);

    // Pinned, with two values for the reason `tests.zig`'s replay gives: which `sin` the binary
    // calls. A third would be recorded here, not chased (ADR-0013).
    const zig_sin: u64 = 0xf1d3c73ecbaab79c;
    const apple_sin: u64 = 0xe9d45191bbdf1bd3;
    try t.expect(a == zig_sin or a == apple_sin);
}
