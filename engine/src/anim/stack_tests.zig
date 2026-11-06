//! `animation-states.md` §16's `anim` tests for M35 Step 2: layers, masks and additive poses. No
//! device, no asset and no allocator under test.

const std = @import("std");
const core = @import("core");

const clip_mod = @import("clip.zig");
const player_mod = @import("player.zig");
const pose_mod = @import("pose.zig");
const rig_mod = @import("rig.zig");
const skeleton_mod = @import("skeleton.zig");
const stack_mod = @import("stack.zig");

const Clip = clip_mod.Clip;
const ContentId = core.ContentId;
const Event = rig_mod.Event;
const Mask = rig_mod.Mask;
const MaskEntry = rig_mod.MaskEntry;
const Mat4 = core.math.Mat4;
const Player = player_mod.Player;
const Pose = pose_mod.Pose;
const Quat = core.math.Quat;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;
const Skeleton = skeleton_mod.Skeleton;
const Spec = stack_mod.Spec;
const Stack = stack_mod.Stack;
const Step = player_mod.Step;
const Track = clip_mod.Track;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;

const clipName = rig_mod.clipName;
const no_parent = skeleton_mod.no_parent;
const t = std.testing;
const dt: f32 = 1.0 / 60.0;

// ---------------------------------------------------------------------------------------------
// Fixtures: a pelvis, a spine and a chest above it, and a leg below.

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

/// Forward 0.6 m a lap, swinging the leg.
const walk_values = [_]f32{ 0, 0.9, 0, 0, 0.9, -0.6 };
const leg_values = [_]f32{ 0, -0.5, 0, 0.2, -0.5, 0 };
const walk_tracks = [_]Track{
    .{ .joint = pelvis, .path = .translation, .times = &ends, .values = &walk_values },
    .{ .joint = leg, .path = .translation, .times = &ends, .values = &leg_values },
};
const walk_clip: Clip = .{ .duration = 1, .tracks = &walk_tracks };

/// The leg alone.
const idle_tracks = [_]Track{.{ .joint = leg, .path = .translation, .times = &ends, .values = &leg_values }};
const idle_clip: Clip = .{ .duration = 1, .tracks = &idle_tracks };

const s90: f32 = 0.70710678;
/// A quarter turn about X at the spine and the chest, and the leg moved: an upper body that reaches.
const bow = [_]f32{ s90, 0, 0, s90, s90, 0, 0, s90 };
const kick = [_]f32{ 0, -0.5, 0.3, 0, -0.5, 0.3 };
const reach_tracks = [_]Track{
    .{ .joint = spine, .path = .rotation, .times = &ends, .values = &bow },
    .{ .joint = chest, .path = .rotation, .times = &ends, .values = &bow },
    .{ .joint = leg, .path = .translation, .times = &ends, .values = &kick },
};
const reach_clip: Clip = .{ .duration = 1, .tracks = &reach_tracks };

/// The chest rises 0.1 m at mid-breath and settles: what `pant` does.
const heave = [_]f32{ 0, 0.25, 0, 0, 0.35, 0, 0, 0.25, 0 };
const pant_tracks = [_]Track{.{ .joint = chest, .path = .translation, .times = &thirds, .values = &heave }};
const pant_clip: Clip = .{ .duration = 1, .tracks = &pant_tracks };

/// Its reference: the clip's own first frame, which is the rest pose.
const pant_reference = rest;

const foot = ContentId.fromString("test:event.foot");
const breath = ContentId.fromString("test:event.breath");
const walk_events = [_]Event{ .{ .at = 0.25, .id = foot }, .{ .at = 0.75, .id = foot } };
const pant_events = [_]Event{.{ .at = 0.25, .id = breath }};

const name_walk = clipName("walk");
const name_idle = clipName("idle");
const name_reach = clipName("reach");
const name_pant = clipName("pant");
const name_upper = clipName("upper");
const name_waist = clipName("waist");
const name_lower = clipName("lower");

fn lessName(_: void, a: RigClip, b: RigClip) bool {
    return a.name < b.name;
}

const clips = blk: {
    @setEvalBranchQuota(100_000);
    var out = [_]RigClip{
        .{ .name = name_walk, .clip = walk_clip, .motion = true, .events = &walk_events, .label = "walk" },
        .{ .name = name_idle, .clip = idle_clip, .label = "idle" },
        .{ .name = name_reach, .clip = reach_clip, .label = "reach" },
        .{ .name = name_pant, .clip = pant_clip, .additive = true, .reference = &pant_reference, .events = &pant_events, .label = "pant" },
    };
    std.mem.sort(RigClip, &out, {}, lessName);
    break :blk out;
};

/// Spine and everything above: the upper body.
const upper_weights = [_]f32{ 0, 1, 1, 0 };
/// The waist feathered: half the spine, all the chest.
const waist_weights = [_]f32{ 0, 0.5, 1, 0 };
/// The pelvis and the leg: everything but the upper body.
const lower_weights = [_]f32{ 1, 0, 0, 1 };
const masks = [_]Mask{
    .{ .name = name_lower, .weights = &lower_weights, .label = "lower" },
    .{ .name = name_upper, .weights = &upper_weights, .label = "upper" },
    .{ .name = name_waist, .weights = &waist_weights, .label = "waist" },
};

const rig: Rig = .{ .skeleton = skeleton, .clips = &clips, .start = name_idle, .motion_joint = pelvis, .masks = &masks };

const body_only = [_]Spec{.{}};
const three = [_]Spec{ .{}, .{ .mask = name_upper }, .{ .mode = .additive } };

const Buffers = struct {
    out: [joints]Transform = undefined,
    a: [joints]Transform = undefined,
    b: [joints]Transform = undefined,

    fn evaluate(self: *Buffers, stack: *const Stack, specs: []const Spec) []const Transform {
        stack.evaluate(rig, specs, .{ .{ .local = &self.a }, .{ .local = &self.b } }, .{ .local = &self.out });
        return &self.out;
    }
};

fn baseOnly(stack: *const Stack) [joints]Transform {
    var out: [joints]Transform = undefined;
    var scratch: [joints]Transform = undefined;
    stack.players[0].evaluate(rig, .{ .local = &scratch }, .{ .local = &out });
    return out;
}

fn run(stack: *Stack, specs: []const Spec, ticks: usize) void {
    var step: Step = .{};
    for (0..ticks) |_| stack.advance(rig, specs, dt, &step);
}

fn same(a: Transform, b: Transform) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

// ---------------------------------------------------------------------------------------------
// The rig's refusals, masks and specs

test "rig: every refusal of an additive clip and a mask is named" {
    try rig.validate();
    const Case = struct { clips: []const RigClip, masks: []const Mask = &.{}, start: u64, err: anyerror };
    const short = rest[0..2];
    const nan_rest = [_]Transform{ .{ .translation = .init(std.math.nan(f32), 0, 0) }, rest[1], rest[2], rest[3] };
    const bad_turn = [_]Transform{ .{ .rotation = .{ .x = 0, .y = 0, .z = 0, .w = 2 } }, rest[1], rest[2], rest[3] };
    const two = [_]f32{ 0, 2, 0, 0 };
    const nan_weight = [_]f32{ 0, std.math.nan(f32), 0, 0 };
    const nine: [9]Mask = @splat(.{ .name = name_upper, .weights = &upper_weights });
    const cases = [_]Case{
        .{ .clips = &.{.{ .name = name_pant, .clip = pant_clip, .additive = true, .motion = true, .reference = &pant_reference }}, .start = name_pant, .err = error.AdditiveWithMotion },
        .{ .clips = &.{ .{ .name = name_idle, .clip = idle_clip }, .{ .name = name_pant, .clip = pant_clip, .additive = true, .reference = short } }, .start = name_idle, .err = error.InvalidReference },
        .{ .clips = &.{ .{ .name = name_idle, .clip = idle_clip }, .{ .name = name_pant, .clip = pant_clip, .additive = true } }, .start = name_idle, .err = error.InvalidReference },
        .{ .clips = &.{ .{ .name = name_idle, .clip = idle_clip }, .{ .name = name_pant, .clip = pant_clip, .additive = true, .reference = &nan_rest } }, .start = name_idle, .err = error.InvalidReference },
        .{ .clips = &.{ .{ .name = name_idle, .clip = idle_clip }, .{ .name = name_pant, .clip = pant_clip, .additive = true, .reference = &bad_turn } }, .start = name_idle, .err = error.InvalidReference },
        .{ .clips = &.{.{ .name = name_idle, .clip = idle_clip, .reference = &pant_reference }}, .start = name_idle, .err = error.InvalidReference },
        .{ .clips = &.{.{ .name = name_pant, .clip = pant_clip, .additive = true, .reference = &pant_reference }}, .start = name_pant, .err = error.AdditiveStart },
        .{ .clips = &.{.{ .name = name_idle, .clip = idle_clip }}, .masks = &nine, .start = name_idle, .err = error.TooManyMasks },
        .{ .clips = &.{.{ .name = name_idle, .clip = idle_clip }}, .masks = &.{.{ .name = 0, .weights = &upper_weights }}, .start = name_idle, .err = error.UnnamedMask },
        .{ .clips = &.{.{ .name = name_idle, .clip = idle_clip }}, .masks = &.{ masks[0], masks[0] }, .start = name_idle, .err = error.DuplicateMask },
        .{ .clips = &.{.{ .name = name_idle, .clip = idle_clip }}, .masks = &.{.{ .name = name_upper, .weights = upper_weights[0..3] }}, .start = name_idle, .err = error.InvalidMask },
        .{ .clips = &.{.{ .name = name_idle, .clip = idle_clip }}, .masks = &.{.{ .name = name_upper, .weights = &two }}, .start = name_idle, .err = error.InvalidMask },
        .{ .clips = &.{.{ .name = name_idle, .clip = idle_clip }}, .masks = &.{.{ .name = name_upper, .weights = &nan_weight }}, .start = name_idle, .err = error.InvalidMask },
    };
    for (cases) |case| {
        var sorted: [2]RigClip = undefined;
        @memcpy(sorted[0..case.clips.len], case.clips);
        std.mem.sort(RigClip, sorted[0..case.clips.len], {}, lessName);
        const candidate: Rig = .{ .skeleton = skeleton, .clips = sorted[0..case.clips.len], .start = case.start, .masks = case.masks };
        try t.expectError(case.err, candidate.validate());
    }
}

test "fillMask: a joint's subtree, in order, so a later entry feathers an earlier one" {
    var out: [joints]f32 = undefined;
    try rig_mod.fillMask(skeleton, &.{.{ .joint = spine, .weight = 1 }}, &out);
    try t.expectEqualSlices(f32, &upper_weights, &out);
    try rig_mod.fillMask(skeleton, &.{ .{ .joint = spine, .weight = 0.5 }, .{ .joint = chest, .weight = 1 } }, &out);
    try t.expectEqualSlices(f32, &waist_weights, &out);
    try rig_mod.fillMask(skeleton, &.{ .{ .joint = pelvis, .weight = 1 }, .{ .joint = leg, .weight = 0 } }, &out);
    try t.expectEqualSlices(f32, &.{ 1, 1, 1, 0 }, &out);
    try rig_mod.fillMask(skeleton, &.{}, &out);
    try t.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &out);

    try t.expectError(error.UnknownJoint, rig_mod.fillMask(skeleton, &.{.{ .joint = 4, .weight = 1 }}, &out));
    try t.expectError(error.InvalidMaskWeight, rig_mod.fillMask(skeleton, &.{.{ .joint = 1, .weight = 1.5 }}, &out));
    try t.expectError(error.InvalidMaskWeight, rig_mod.fillMask(skeleton, &.{.{ .joint = 1, .weight = std.math.nan(f32) }}, &out));
    const many: [33]MaskEntry = @splat(.{ .joint = 1, .weight = 1 });
    try t.expectError(error.TooManyMaskEntries, rig_mod.fillMask(skeleton, &many, &out));
}

test "specs: every refusal is named" {
    try stack_mod.validateSpecs(rig, &three);
    try t.expectError(error.NoLayers, stack_mod.validateSpecs(rig, &.{}));
    try t.expectError(error.TooManyLayers, stack_mod.validateSpecs(rig, &.{ .{}, .{}, .{}, .{} }));
    try t.expectError(error.AdditiveBase, stack_mod.validateSpecs(rig, &.{.{ .mode = .additive }}));
    try t.expectError(error.MaskOnBase, stack_mod.validateSpecs(rig, &.{.{ .mask = name_upper }}));
    try t.expectError(error.UnknownMask, stack_mod.validateSpecs(rig, &.{ .{}, .{ .mask = clipName("absent") } }));
    try t.expectError(error.InvalidFade, stack_mod.validateSpecs(rig, &.{ .{}, .{ .fade = -1 } }));
    try t.expectError(error.InvalidFade, stack_mod.validateSpecs(rig, &.{ .{}, .{ .fade = std.math.nan(f32) } }));
}

// ---------------------------------------------------------------------------------------------
// One layer is a player

test "one layer: a stack of its base alone is its player, bit for bit" {
    var stack: Stack = .{};
    var player: Player = .{};
    var buffers: Buffers = .{};
    var a: Step = .{};
    var b: Step = .{};
    for (0..600) |tick| {
        switch (tick) {
            10 => {
                try stack.play(rig, &body_only, 0, name_walk, .{ .fade = 0.3 });
                try player.play(rig, name_walk, .{ .fade = 0.3 });
            },
            200 => {
                try stack.play(rig, &body_only, 0, name_idle, .{ .fade = 0.2, .phase = .keep });
                try player.play(rig, name_idle, .{ .fade = 0.2, .phase = .keep });
            },
            400 => {
                try stack.play(rig, &body_only, 0, name_walk, .{ .speed = -1 });
                try player.play(rig, name_walk, .{ .speed = -1 });
            },
            else => {},
        }
        stack.advance(rig, &body_only, dt, &a);
        player.advance(rig, dt, &b);
        try t.expectEqualSlices(u8, std.mem.asBytes(&player), std.mem.asBytes(&stack.players[0]));
        try t.expectEqual(b.event_count, a.event_count);
        try t.expectEqualSlices(ContentId, b.fired(), a.fired());
        try t.expectEqualSlices(u8, std.mem.asBytes(&b.motion), std.mem.asBytes(&a.motion));
        const from_stack = buffers.evaluate(&stack, &three);
        const from_player = baseOnly(&stack);
        // The layers above are empty, so even three specs show the base alone.
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(&from_player), std.mem.sliceAsBytes(from_stack));
    }
}

// ---------------------------------------------------------------------------------------------
// Additive

test "additive: a breathing chest moves only the chest, by its difference" {
    var stack: Stack = .{};
    try stack.play(rig, &three, 0, name_walk, .{});
    try stack.play(rig, &three, 2, name_pant, .{});
    stack.setTarget(2, 1);
    run(&stack, &three, 30);
    var buffers: Buffers = .{};
    const mixed = buffers.evaluate(&stack, &three);
    const plain = baseOnly(&stack);
    for (0..joints) |j| {
        if (j == chest) continue;
        try t.expect(same(plain[j], mixed[j]));
    }
    // Half a breath in: the chest 0.1 m above where the walk put it.
    try t.expectApproxEqAbs(plain[chest].translation.y + 0.1, mixed[chest].translation.y, 1e-5);
    try t.expectApproxEqAbs(plain[chest].translation.x, mixed[chest].translation.x, 1e-6);
}

test "additive: at weight 0 it is the base exactly, and halfway it adds half" {
    var stack: Stack = .{};
    try stack.play(rig, &three, 0, name_walk, .{});
    try stack.play(rig, &three, 2, name_pant, .{});
    run(&stack, &three, 30);
    var buffers: Buffers = .{};
    const plain = baseOnly(&stack);
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(&plain), std.mem.sliceAsBytes(buffers.evaluate(&stack, &three)));
    stack.layers[2].weight = 0.5;
    stack.layers[2].target = 0.5;
    try t.expectApproxEqAbs(plain[chest].translation.y + 0.05, buffers.evaluate(&stack, &three)[chest].translation.y, 1e-5);
}

test "additive: a mask keeps a difference off the joints it leaves out" {
    const lower = [_]Spec{ .{}, .{ .mode = .additive, .mask = name_lower } };
    var stack: Stack = .{};
    try stack.play(rig, &lower, 0, name_walk, .{});
    try stack.play(rig, &lower, 1, name_pant, .{});
    stack.setTarget(1, 1);
    run(&stack, &lower, 30);
    var buffers: Buffers = .{};
    const plain = baseOnly(&stack);
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(&plain), std.mem.sliceAsBytes(buffers.evaluate(&stack, &lower)));
}

test "additive: a difference of a joint at its reference is the identity" {
    var pose = rest;
    pose_mod.difference(.{ .local = &pose }, &rest);
    for (pose) |joint| try t.expect(same(Transform.identity, joint));
    var below = rest;
    pose_mod.addMasked(.{ .local = &below }, .{ .local = &pose }, null, 1, .{ .local = &below });
    for (below, rest) |got, want| try t.expect(same(want, got));
}

// ---------------------------------------------------------------------------------------------
// Override and masks

test "override: an upper mask takes the spine and chest and leaves the leg to the base" {
    var stack: Stack = .{};
    try stack.play(rig, &three, 0, name_walk, .{});
    try stack.play(rig, &three, 1, name_reach, .{});
    stack.setTarget(1, 1);
    run(&stack, &three, 20);
    var buffers: Buffers = .{};
    const mixed = buffers.evaluate(&stack, &three);
    const plain = baseOnly(&stack);
    try t.expect(same(plain[pelvis], mixed[pelvis]));
    try t.expect(same(plain[leg], mixed[leg]));
    try t.expect(Quat.approxEql(.{ .x = s90, .y = 0, .z = 0, .w = s90 }, mixed[spine].rotation, 1e-5));
    try t.expect(Quat.approxEql(.{ .x = s90, .y = 0, .z = 0, .w = s90 }, mixed[chest].rotation, 1e-5));
}

test "override: a feathered waist turns the spine halfway and the chest the whole way" {
    const feathered = [_]Spec{ .{}, .{ .mask = name_waist } };
    var stack: Stack = .{};
    try stack.play(rig, &feathered, 0, name_idle, .{});
    try stack.play(rig, &feathered, 1, name_reach, .{});
    stack.setTarget(1, 1);
    run(&stack, &feathered, 2);
    var buffers: Buffers = .{};
    const mixed = buffers.evaluate(&stack, &feathered);
    const half = Quat.slerp(.identity, .{ .x = s90, .y = 0, .z = 0, .w = s90 }, 0.5);
    try t.expect(Quat.approxEql(half, mixed[spine].rotation, 1e-5));
    try t.expect(Quat.approxEql(.{ .x = s90, .y = 0, .z = 0, .w = s90 }, mixed[chest].rotation, 1e-5));
}

// ---------------------------------------------------------------------------------------------
// Events, motion and refusals

test "events: every weighted layer fires, base first, and a silent layer does not" {
    var stack: Stack = .{};
    try stack.play(rig, &three, 0, name_walk, .{});
    try stack.play(rig, &three, 2, name_pant, .{});
    var step: Step = .{};
    stack.advance(rig, &three, 0.25, &step);
    // Weight 0: the walk's 0.25 lies on the next tick, and the breath is not heard.
    stack.advance(rig, &three, 0.25, &step);
    try t.expectEqual(@as(u32, 1), step.event_count);
    try t.expect(step.events[0].eql(foot));
    // The same with the breath weighted: both fire, the base's first.
    var fresh: Stack = .{};
    try fresh.play(rig, &three, 0, name_walk, .{});
    try fresh.play(rig, &three, 2, name_pant, .{});
    fresh.setTarget(2, 1);
    fresh.advance(rig, &three, 0.25, &step);
    fresh.advance(rig, &three, 0.25, &step);
    try t.expectEqual(@as(u32, 2), step.event_count);
    try t.expect(step.events[0].eql(foot));
    try t.expect(step.events[1].eql(breath));
}

test "events: the base always fires, whatever a raw write left its weight at" {
    var stack: Stack = .{};
    try stack.play(rig, &three, 0, name_walk, .{});
    stack.layers[0].weight = 0;
    stack.layers[0].target = 0;
    var step: Step = .{};
    stack.advance(rig, &three, 0.25, &step);
    stack.advance(rig, &three, 0.25, &step);
    try t.expectEqual(@as(u32, 1), step.event_count);
    try t.expectEqual(@as(f32, 1), stack.layers[0].weight);
}

test "motion: only the base moves a body, and a clip with motion is refused above it" {
    var stack: Stack = .{};
    try t.expectError(error.MotionOffBase, stack.play(rig, &three, 1, name_walk, .{}));
    try t.expectError(error.ModeMismatch, stack.play(rig, &three, 0, name_pant, .{}));
    try t.expectError(error.ModeMismatch, stack.play(rig, &three, 2, name_reach, .{}));
    try t.expectError(error.UnknownLayer, stack.play(rig, &three, 3, name_reach, .{}));
    try t.expectError(error.UnknownLayer, stack.play(rig, &body_only, 1, name_reach, .{}));
    try t.expectError(error.UnknownClip, stack.play(rig, &three, 1, clipName("absent"), .{}));
    try t.expectEqualSlices(u8, std.mem.asBytes(&Stack{}), std.mem.asBytes(&stack));

    try stack.play(rig, &three, 0, name_idle, .{});
    // A raw write a save could carry: a walk on the upper layer.
    stack.players[1].channels[0] = .{ .clip = name_walk, .speed = 1, .weight = 1 };
    stack.layers[1].weight = 1;
    var step: Step = .{};
    stack.advance(rig, &three, dt, &step);
    try t.expectEqual(@as(u32, 1), step.lost);
    try t.expectEqual(@as(f32, 0), step.motion.translation.length());
    try t.expect(!stack.players[1].hasClip());
    // Emptied, it stays empty, and the base's start clip is not begun on it.
    stack.advance(rig, &three, dt, &step);
    try t.expectEqual(@as(u32, 0), step.lost);
    try t.expect(!stack.players[1].hasClip());
}

test "untrusted: a clip on the wrong kind of layer, or gone, is emptied and counted" {
    var stack: Stack = .{};
    try stack.play(rig, &three, 0, name_idle, .{});
    stack.players[0].channels[1] = .{ .clip = name_pant, .speed = 1, .weight = 0 };
    stack.players[2].channels[0] = .{ .clip = name_reach, .speed = 1, .weight = 1 };
    stack.players[1].channels[0] = .{ .clip = clipName("gone"), .speed = 1, .weight = 1 };
    stack.layers[1].weight = std.math.nan(f32);
    stack.layers[2].target = 7;
    var step: Step = .{};
    stack.advance(rig, &three, dt, &step);
    try t.expectEqual(@as(u32, 3), step.lost);
    try t.expectEqual(@as(f32, 0), stack.layers[1].weight);
    try t.expectEqual(@as(f32, 1), stack.layers[2].target);
    try t.expectEqual(@as(f32, 1), stack.layers[0].weight);
}

test "weight: a layer fades toward its target at its spec's rate, and a cut is at once" {
    const faded = [_]Spec{ .{}, .{ .mask = name_upper, .fade = 0.5 } };
    var stack: Stack = .{};
    try stack.play(rig, &faded, 1, name_reach, .{});
    stack.setTarget(1, 1);
    run(&stack, &faded, 15);
    try t.expectApproxEqAbs(@as(f32, 0.5), stack.layers[1].weight, 1e-5);
    run(&stack, &faded, 30);
    try t.expectEqual(@as(f32, 1), stack.layers[1].weight);
    stack.setTarget(1, std.math.nan(f32));
    try t.expectEqual(@as(f32, 0), stack.layers[1].target);
    run(&stack, &faded, 15);
    try t.expectApproxEqAbs(@as(f32, 0.5), stack.layers[1].weight, 1e-5);
    stack.setTarget(0, 0);
    try t.expectEqual(@as(f32, 1), stack.layers[0].target);

    var cut: Stack = .{};
    try cut.play(rig, &three, 1, name_reach, .{});
    cut.setTarget(1, 0.75);
    run(&cut, &three, 1);
    try t.expectEqual(@as(f32, 0.75), cut.layers[1].weight);
}

test "sane: a default stack is, and each bad value a load could carry is not" {
    const fresh: Stack = .{};
    try t.expect(fresh.sane());
    const edits = [_]*const fn (*Stack) void{
        struct {
            fn edit(s: *Stack) void {
                s.players[2].channels[0] = .{ .clip = 7, .speed = std.math.nan(f32), .weight = 1 };
            }
        }.edit,
        struct {
            fn edit(s: *Stack) void {
                s.layers[1].weight = 1.5;
            }
        }.edit,
        struct {
            fn edit(s: *Stack) void {
                s.layers[2].target = -0.25;
            }
        }.edit,
        struct {
            fn edit(s: *Stack) void {
                s.layers[0].weight = std.math.nan(f32);
            }
        }.edit,
        struct {
            fn edit(s: *Stack) void {
                s.params[3] = .{ .name = 5, .value = std.math.inf(f32) };
            }
        }.edit,
        struct {
            fn edit(s: *Stack) void {
                s.params[7] = .{ .name = 0, .value = 2 };
            }
        }.edit,
    };
    for (edits) |edit| {
        var stack: Stack = .{};
        edit(&stack);
        try t.expect(!stack.sane());
    }
    // The edges of the range are in it, and a named parameter may hold any finite value.
    var edge: Stack = .{};
    edge.layers[1] = .{ .weight = 0, .target = 1 };
    edge.params[0] = .{ .name = 5, .value = -1e30 };
    try t.expect(edge.sane());
}
