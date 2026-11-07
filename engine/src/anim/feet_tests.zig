//! `animation-ik.md` §16's tests for M36 Step 3: legs and aims in a rig, contacts read from clips,
//! feet placed on hand-built ground, locks, and a gaze. No device, no asset and no allocator.

const std = @import("std");
const core = @import("core");

const blend_mod = @import("blend.zig");
const clip_mod = @import("clip.zig");
const feet_mod = @import("feet.zig");
const gaze_mod = @import("gaze.zig");
const ik = @import("ik.zig");
const player_mod = @import("player.zig");
const pose_mod = @import("pose.zig");
const report_mod = @import("report.zig");
const rig_mod = @import("rig.zig");
const skeleton_mod = @import("skeleton.zig");

const Contact = feet_mod.Contact;
const Feet = feet_mod.Feet;
const Ground = feet_mod.Ground;
const Leg = feet_mod.Leg;
const Mat4 = core.math.Mat4;
const Player = player_mod.Player;
const Pose = pose_mod.Pose;
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
// Fixtures: a pelvis, two legs, and a chest with a neck and a head.

const pelvis = 0;
const hip_l = 1;
const knee_l = 2;
const foot_l = 3;
const hip_r = 4;
const knee_r = 5;
const foot_r = 6;
const chest = 7;
const neck = 8;
const head = 9;
const joints = 10;

const parents = [_]u16{ no_parent, pelvis, hip_l, knee_l, pelvis, hip_r, knee_r, pelvis, chest, neck };
const rest = [_]Transform{
    .{ .translation = .init(0, 0.9, 0) },
    .{ .translation = .init(-0.12, 0, 0) },
    .{ .translation = .init(0, -0.4, -0.06) },
    .{ .translation = .init(0, -0.37, 0.06) },
    .{ .translation = .init(0.12, 0, 0) },
    .{ .translation = .init(0, -0.4, -0.06) },
    .{ .translation = .init(0, -0.37, 0.06) },
    .{ .translation = .init(0, 0.45, 0) },
    .{ .translation = .init(0, 0.13, 0) },
    .{ .translation = .init(0, 0.12, 0) },
};
const inverse_bind: [joints]Mat4 = @splat(Mat4.identity);
const skeleton: Skeleton = .{ .parents = &parents, .rest = &rest, .inverse_bind = &inverse_bind };

/// The foot joint is 13 cm above the floor at rest, and each knee is bent 6 cm forward so a leg has
/// room to reach.
const sole: f32 = 0.13;

const quarters = [_]f32{ 0, 0.25, 0.5, 0.75, 1 };
/// The left foot lifts 6 cm at half a lap, and the right at the lap's turn.
const left_lift = [_]f32{ 0, -0.37, 0.06, 0, -0.37, 0.06, 0, -0.31, 0.06, 0, -0.37, 0.06, 0, -0.37, 0.06 };
const right_lift = [_]f32{ 0, -0.31, 0.06, 0, -0.37, 0.06, 0, -0.37, 0.06, 0, -0.37, 0.06, 0, -0.31, 0.06 };
const walk_tracks = [_]Track{
    .{ .joint = foot_l, .path = .translation, .times = &quarters, .values = &left_lift },
    .{ .joint = foot_r, .path = .translation, .times = &quarters, .values = &right_lift },
};
const halves = [_]f32{ 0, 1 };
const still_values = [_]f32{ 0, -0.37, 0.06, 0, -0.37, 0.06 };
const still_tracks = [_]Track{.{ .joint = foot_l, .path = .translation, .times = &halves, .values = &still_values }};
const hop_tracks = walk_tracks;

const name_walk = clipName("walk");
const name_still = clipName("still");
const name_hop = clipName("hop");
const name_left = clipName("left");
const name_right = clipName("right");
const name_head = clipName("head");

const legs = [_]Leg{
    .{ .name = name_left, .chain = .{ .root = hip_l, .middle = knee_l, .end = foot_l }, .sole = sole, .label = "left" },
    .{ .name = name_right, .chain = .{ .root = hip_r, .middle = knee_r, .end = foot_r }, .sole = sole, .label = "right" },
};
const gaze_joints = [_]ik.AimJoint{ .{ .joint = neck, .share = 0.4 }, .{ .joint = head, .share = 0.6 } };
const aims = [_]gaze_mod.RigAim{.{ .name = name_head, .chain = .{ .joints = &gaze_joints, .limit = 1.2 }, .label = "head" }};

fn lessName(_: void, a: RigClip, b: RigClip) bool {
    return a.name < b.name;
}

const bare_clips = blk: {
    @setEvalBranchQuota(100_000);
    var out = [_]RigClip{
        .{ .name = name_walk, .clip = .{ .duration = 1, .tracks = &walk_tracks }, .label = "walk" },
        .{ .name = name_still, .clip = .{ .duration = 1, .tracks = &still_tracks }, .label = "still" },
        .{ .name = name_hop, .clip = .{ .duration = 1, .tracks = &hop_tracks }, .loop = false, .label = "hop" },
    };
    std.mem.sort(RigClip, &out, {}, lessName);
    break :blk out;
};

/// The clips with their contacts read, as `Rigs` will read them when it builds a rig.
const Built = struct {
    clips: [bare_clips.len]RigClip,
    contacts: [bare_clips.len][feet_mod.max_legs * feet_mod.max_contacts]Contact,

    fn init(self: *Built) void {
        self.clips = bare_clips;
        var scratch: [joints]Transform = undefined;
        for (&self.clips, 0..) |*entry, i| {
            const n = feet_mod.deriveContacts(skeleton, entry, &legs, .{ .local = &scratch }, &self.contacts[i]);
            entry.contacts = self.contacts[i][0..n];
        }
    }

    fn rig(self: *const Built) Rig {
        return .{ .skeleton = skeleton, .clips = &self.clips, .start = name_still, .legs = &legs, .aims = &aims };
    }
};

fn contactsOf(rig: Rig, name: u64) []const Contact {
    return rig.find(name).?.contacts;
}

fn downAt(contacts: []const Contact, leg: u8, fraction: f32) bool {
    for (contacts) |contact| {
        if (contact.leg != leg) continue;
        const inside = if (contact.from <= contact.to) fraction >= contact.from and fraction < contact.to else fraction >= contact.from or fraction < contact.to;
        if (inside) return true;
    }
    return false;
}

/// A figure standing at `place`, facing `yaw` about +Y.
fn world(place: Vec3, yaw: f32) Mat4 {
    return Mat4.trs(place, Quat.fromAxisAngle(.up, yaw), .one);
}

/// Ground under each probe at the height `height(x, z)` gives, facing up unless `normal` says.
fn groundUnder(probes: []const feet_mod.Probe, comptime height: fn (f32, f32) f32, normal: Vec3) [feet_mod.max_legs]Ground {
    var out: [feet_mod.max_legs]Ground = @splat(.{});
    for (probes, 0..) |probe, i| {
        const p = probe.origin;
        out[i] = .{ .hit = true, .point = .init(p.x, height(p.x, p.z), p.z), .normal = normal };
    }
    return out;
}

fn flat(_: f32, _: f32) f32 {
    return 0;
}

fn evaluate(rig: Rig, player: *const Player, out: *[joints]Transform) void {
    var scratch: [joints]Transform = undefined;
    player.evaluate(rig, .{ .local = &scratch }, .{ .local = out });
}

fn soleHeight(local: *[joints]Transform, to_world: Mat4, foot: u16) f32 {
    const model = ik.positionOf(ik.modelOf(skeleton, .{ .local = local }, foot));
    return to_world.mulPoint(model.sub(.init(0, sole, 0))).y;
}

fn playing(rig: Rig, name: u64, ticks: usize) Player {
    var player: Player = .{};
    player.play(rig, name, .{}) catch unreachable;
    var step: Step = .{};
    for (0..ticks) |_| player.advance(rig, dt, &step);
    return player;
}

/// Places a figure's feet for `ticks` ticks on `height`, standing still at one fraction.
fn settle(rig: Rig, feet: *Feet, player: *const Player, to_world: Mat4, comptime height: fn (f32, f32) f32, normal: Vec3, ticks: usize, options: feet_mod.Options) [joints]Transform {
    var local: [joints]Transform = undefined;
    for (0..ticks) |_| {
        evaluate(rig, player, &local);
        var rays: [feet_mod.max_legs]feet_mod.Probe = undefined;
        const probes = Feet.probes(rig, .{ .local = &local }, to_world, &rays);
        const grounds = groundUnder(probes, height, normal);
        feet.place(rig, .{ .local = &local }, to_world, grounds[0..probes.len], feet_mod.contactWeights(rig, player, .none), dt, options);
    }
    return local;
}

// ---------------------------------------------------------------------------------------------
// Validation and contacts.

test "a rig's legs, aims and contacts are refused by name" {
    var built: Built = undefined;
    built.init();
    try built.rig().validate();

    const LegCase = struct { legs: []const Leg, err: anyerror };
    const chain = legs[0].chain;
    const five = [_]Leg{
        .{ .name = 1, .chain = chain, .sole = sole }, .{ .name = 2, .chain = chain, .sole = sole },
        .{ .name = 3, .chain = chain, .sole = sole }, .{ .name = 4, .chain = chain, .sole = sole },
        .{ .name = 5, .chain = chain, .sole = sole },
    };
    const leg_cases = [_]LegCase{
        .{ .legs = &five, .err = error.TooManyLegs },
        .{ .legs = &.{.{ .name = 0, .chain = chain, .sole = sole }}, .err = error.UnnamedLeg },
        .{ .legs = &.{ legs[0], legs[0] }, .err = error.DuplicateLeg },
        .{ .legs = &.{.{ .name = 1, .chain = .{ .root = hip_l, .middle = knee_r, .end = foot_l }, .sole = sole }}, .err = error.NotAChain },
        .{ .legs = &.{.{ .name = 1, .chain = chain, .sole = std.math.nan(f32) }}, .err = error.InvalidLegRange },
        .{ .legs = &.{.{ .name = 1, .chain = chain, .sole = sole, .contact_height = 0.6 }}, .err = error.InvalidLegRange },
        .{ .legs = &.{.{ .name = 1, .chain = chain, .sole = sole, .max_raise = -0.1 }}, .err = error.InvalidLegRange },
        .{ .legs = &.{.{ .name = 1, .chain = chain, .sole = sole, .max_drop = 3 }}, .err = error.InvalidLegRange },
    };
    for (leg_cases) |case| {
        const bad: Rig = .{ .skeleton = skeleton, .clips = &bare_clips, .start = name_still, .legs = case.legs };
        try t.expectError(case.err, bad.validate());
    }

    const ContactCase = struct { name: u64, contacts: []const Contact };
    const too_many = [_]Contact{
        .{ .leg = 0, .from = 0, .to = 0.1 },   .{ .leg = 0, .from = 0.2, .to = 0.3 }, .{ .leg = 0, .from = 0.4, .to = 0.5 },
        .{ .leg = 0, .from = 0.6, .to = 0.7 }, .{ .leg = 0, .from = 0.8, .to = 0.9 },
    };
    const contact_cases = [_]ContactCase{
        .{ .name = name_walk, .contacts = &.{.{ .leg = 2, .from = 0, .to = 0.5 }} },
        .{ .name = name_walk, .contacts = &.{.{ .leg = 0, .from = -0.1, .to = 0.5 }} },
        .{ .name = name_walk, .contacts = &.{.{ .leg = 0, .from = 0.5, .to = 0.5 }} },
        .{ .name = name_walk, .contacts = &too_many },
        .{ .name = name_hop, .contacts = &.{.{ .leg = 0, .from = 0, .to = 0.5 }} },
    };
    for (contact_cases) |case| {
        var clips = bare_clips;
        for (&clips) |*entry| {
            if (entry.name == case.name) entry.contacts = case.contacts;
        }
        const bad: Rig = .{ .skeleton = skeleton, .clips = &clips, .start = name_still, .legs = &legs };
        try t.expectError(error.InvalidContacts, bad.validate());
    }

    const AimCase = struct { aims: []const gaze_mod.RigAim, err: anyerror };
    const one = aims[0];
    const aim_cases = [_]AimCase{
        .{ .aims = &.{ one, .{ .name = 2, .chain = one.chain }, .{ .name = 3, .chain = one.chain }, .{ .name = 4, .chain = one.chain }, .{ .name = 5, .chain = one.chain } }, .err = error.TooManyAims },
        .{ .aims = &.{.{ .name = 0, .chain = one.chain }}, .err = error.UnnamedAim },
        .{ .aims = &.{ one, one }, .err = error.DuplicateAim },
        .{ .aims = &.{.{ .name = 1, .chain = .{ .joints = &.{}, .limit = 1 } }}, .err = error.NotAChain },
        .{ .aims = &.{.{ .name = 1, .chain = .{ .joints = &gaze_joints, .limit = 4 } }}, .err = error.InvalidLimit },
    };
    for (aim_cases) |case| {
        const bad: Rig = .{ .skeleton = skeleton, .clips = &bare_clips, .start = name_still, .aims = case.aims };
        try t.expectError(case.err, bad.validate());
    }
}

test "contacts are read from a clip's foot heights, and a one-shot has none" {
    var built: Built = undefined;
    built.init();
    const rig = built.rig();
    try t.expectApproxEqAbs(sole, feet_mod.soleOf(skeleton, foot_l), 1e-6);

    const walk = contactsOf(rig, name_walk);
    // The left foot is up at half a lap and down either side; the right the other way round.
    for ([_]f32{ 0, 0.1, 0.3, 0.7, 0.9, 0.99 }) |f| try t.expect(downAt(walk, 0, f));
    for ([_]f32{ 0.45, 0.5, 0.55 }) |f| try t.expect(!downAt(walk, 0, f));
    for ([_]f32{ 0.2, 0.4, 0.5, 0.6, 0.8 }) |f| try t.expect(downAt(walk, 1, f));
    for ([_]f32{ 0, 0.03, 0.97 }) |f| try t.expect(!downAt(walk, 1, f));
    // One stretch each: the left's wraps through the lap's end and stays whole.
    try t.expectEqual(@as(usize, 2), walk.len);
    for (walk) |contact| {
        if (contact.leg == 0) try t.expect(contact.from > contact.to);
    }
    // A foot that never lifts is down all lap.
    const still = contactsOf(rig, name_still);
    try t.expect(downAt(still, 0, 0.5) and downAt(still, 1, 0.5));
    try t.expectEqual(@as(usize, 0), contactsOf(rig, name_hop).len);

    // A player's contact is each channel's, weighted.
    const half = playing(rig, name_walk, 30);
    const weights = feet_mod.contactWeights(rig, &half, .none);
    try t.expectEqual(@as(f32, 0), weights[0]);
    try t.expectEqual(@as(f32, 1), weights[1]);
}

// ---------------------------------------------------------------------------------------------
// Placing.

test "on flat ground at the figure's height the pose is the clip's, bit for bit" {
    var built: Built = undefined;
    built.init();
    const rig = built.rig();
    const to_world = world(.init(3, 0, -2), 0.7);
    var player = playing(rig, name_walk, 0);
    var feet: Feet = .{};
    var step: Step = .{};
    for (0..90) |_| {
        player.advance(rig, dt, &step);
        var clip: [joints]Transform = undefined;
        evaluate(rig, &player, &clip);
        const placed = settle(rig, &feet, &player, to_world, flat, Vec3.up, 1, .{ .lock = false });
        try t.expectEqualSlices(u8, std.mem.asBytes(&clip), std.mem.asBytes(&placed));
    }
    try t.expectEqual(@as(f32, 0), feet.pelvis);
    for (feet.legs[0..2]) |leg| try t.expectEqual(@as(f32, 0), leg.offset);

    // A bump of 0.03 mm, inside the dead zone, is flat.
    var bumped: Feet = .{};
    for (0..10) |_| {
        player.advance(rig, dt, &step);
        var clip: [joints]Transform = undefined;
        evaluate(rig, &player, &clip);
        const placed = settle(rig, &bumped, &player, to_world, hair, Vec3.up, 1, .{ .lock = false });
        try t.expectEqualSlices(u8, std.mem.asBytes(&clip), std.mem.asBytes(&placed));
    }

    // Standing still with locks on, a held foot is where the clip has it, so nothing changes either.
    const standing = playing(rig, name_still, 5);
    var held: Feet = .{};
    var clip: [joints]Transform = undefined;
    evaluate(rig, &standing, &clip);
    const placed = settle(rig, &held, &standing, to_world, flat, Vec3.up, 20, .{});
    try t.expect(held.legs[0].locked == 1 and held.legs[1].locked == 1);
    try t.expectEqualSlices(u8, std.mem.asBytes(&clip), std.mem.asBytes(&placed));
}

fn hair(_: f32, _: f32) f32 {
    return 3e-5;
}

fn raised(_: f32, _: f32) f32 {
    return 0.1;
}

fn rightStep(x: f32, _: f32) f32 {
    return if (x > 3) 0.15 else 0;
}

fn leftHollow(x: f32, _: f32) f32 {
    return if (x < 3) -0.15 else 0;
}

test "a step up lands its foot within 1 cm, and a step down drops the pelvis so the lower foot reaches" {
    var built: Built = undefined;
    built.init();
    const rig = built.rig();
    // Facing −Z at x = 3, so the right foot is over x > 3.
    const to_world = world(.init(3, 0, 0), 0);
    // A fraction with both feet down.
    const player = playing(rig, name_walk, 12);

    // The clip's own lift at this fraction is kept on top of the ground.
    var clip: [joints]Transform = undefined;
    evaluate(rig, &player, &clip);
    const lift_l = soleHeight(&clip, to_world, foot_l);
    const lift_r = soleHeight(&clip, to_world, foot_r);

    var up: Feet = .{};
    var local = settle(rig, &up, &player, to_world, rightStep, Vec3.up, 20, .{ .lock = false });
    try t.expectApproxEqAbs(0.15 + lift_r, soleHeight(&local, to_world, foot_r), 0.01);
    try t.expectApproxEqAbs(lift_l, soleHeight(&local, to_world, foot_l), 0.01);
    try t.expectEqual(@as(f32, 0), up.pelvis);
    // It eased there: one tick moves an offset 2 m/s × dt at most.
    var fresh: Feet = .{};
    _ = settle(rig, &fresh, &player, to_world, rightStep, Vec3.up, 1, .{ .lock = false });
    try t.expectApproxEqAbs(feet_mod.settle_speed * dt, fresh.legs[1].offset, 1e-6);

    // Ground raised under both feet lifts the feet, never the pelvis: the body's height is its own.
    var both: Feet = .{};
    local = settle(rig, &both, &player, to_world, raised, Vec3.up, 20, .{ .lock = false });
    try t.expectEqual(@as(f32, 0), both.pelvis);
    try t.expectApproxEqAbs(0.1 + lift_l, soleHeight(&local, to_world, foot_l), 0.01);
    try t.expectApproxEqAbs(0.1 + lift_r, soleHeight(&local, to_world, foot_r), 0.01);

    var down: Feet = .{};
    local = settle(rig, &down, &player, to_world, leftHollow, Vec3.up, 20, .{ .lock = false });
    try t.expectApproxEqAbs(@as(f32, -0.15), down.pelvis, 1e-6);
    try t.expectApproxEqAbs(-0.15 + lift_l, soleHeight(&local, to_world, foot_l), 0.01);
    try t.expectApproxEqAbs(lift_r, soleHeight(&local, to_world, foot_r), 0.01);
    // The pelvis went down by the drop, and only down.
    const model_pelvis = ik.positionOf(ik.modelOf(skeleton, .{ .local = &local }, pelvis));
    try t.expectApproxEqAbs(@as(f32, 0.75), model_pelvis.y, 1e-5);
}

fn tooHigh(_: f32, _: f32) f32 {
    return 0.5;
}

test "no hit, a hit out of range and a point that is not a number all leave the foot alone" {
    var built: Built = undefined;
    built.init();
    const rig = built.rig();
    const to_world = world(.init(0, 0, 0), 0);
    const player = playing(rig, name_walk, 12);
    var clip: [joints]Transform = undefined;
    evaluate(rig, &player, &clip);

    var high: Feet = .{};
    const placed = settle(rig, &high, &player, to_world, tooHigh, Vec3.up, 10, .{ .lock = false });
    try t.expectEqualSlices(u8, std.mem.asBytes(&clip), std.mem.asBytes(&placed));

    for ([_]Ground{ .{}, .{ .hit = true, .point = .init(std.math.nan(f32), 0, 0) } }) |ground| {
        var feet: Feet = .{};
        var local = clip;
        const grounds = [_]Ground{ ground, ground };
        feet.place(rig, .{ .local = &local }, to_world, &grounds, feet_mod.contactWeights(rig, &player, .none), dt, .{ .lock = false });
        try t.expectEqualSlices(u8, std.mem.asBytes(&clip), std.mem.asBytes(&local));
    }
}

test "a planted foot tilts to its ground, by at most half a radian and only as far as it is down" {
    var built: Built = undefined;
    built.init();
    const rig = built.rig();
    const to_world = world(.init(0, 0, 0), 0);
    const standing = playing(rig, name_still, 3);
    for ([_]f32{ 0.3, 1.0 }) |slope| {
        const normal = Quat.fromAxisAngle(.right, slope).rotate(Vec3.up);
        var feet: Feet = .{};
        var local = settle(rig, &feet, &standing, to_world, flat, normal, 1, .{ .lock = false });
        const foot_up = ik.modelOf(skeleton, .{ .local = &local }, foot_l).mulDirection(Vec3.up).normalize();
        const turned = std.math.acos(@min(1, foot_up.dot(Vec3.up)));
        try t.expectApproxEqAbs(@min(slope, feet_mod.max_tilt), turned, 1e-4);
    }
    // Half down is tilted about half as far.
    {
        var clip: [joints]Transform = undefined;
        evaluate(rig, &standing, &clip);
        var local = clip;
        var rays: [feet_mod.max_legs]feet_mod.Probe = undefined;
        const probes = Feet.probes(rig, .{ .local = &local }, to_world, &rays);
        const tilted = Quat.fromAxisAngle(.right, 0.3).rotate(Vec3.up);
        const grounds = groundUnder(probes, flat, tilted);
        var feet: Feet = .{};
        feet.place(rig, .{ .local = &local }, to_world, grounds[0..2], .{ 0.5, 0.5, 0, 0 }, dt, .{ .lock = false });
        const foot_up = ik.modelOf(skeleton, .{ .local = &local }, foot_l).mulDirection(Vec3.up).normalize();
        try t.expectApproxEqAbs(@as(f32, 0.15), std.math.acos(@min(1, foot_up.dot(Vec3.up))), 1e-3);
    }
    // A foot in the air keeps the clip's swing.
    const swinging = playing(rig, name_walk, 30);
    var feet: Feet = .{};
    const normal = Quat.fromAxisAngle(.right, 0.3).rotate(Vec3.up);
    var local = settle(rig, &feet, &swinging, to_world, flat, normal, 1, .{ .lock = false });
    const left_up = ik.modelOf(skeleton, .{ .local = &local }, foot_l).mulDirection(Vec3.up).normalize();
    try t.expectApproxEqAbs(@as(f32, 1), left_up.dot(Vec3.up), 1e-6);
}

test "a lock holds a planted foot in the world, and lets go past its reach and at the contact's end" {
    var built: Built = undefined;
    built.init();
    const rig = built.rig();
    const standing = playing(rig, name_still, 3);
    var feet: Feet = .{};
    var place = Vec3.init(0, 0, 0);
    var local: [joints]Transform = undefined;
    var planted: ?Vec3 = null;
    // The body slides 1 cm a tick under a foot that stays down.
    for (0..40) |tick| {
        local = settle(rig, &feet, &standing, world(place, 0), flat, Vec3.up, 1, .{});
        const foot = world(place, 0).mulPoint(ik.positionOf(ik.modelOf(skeleton, .{ .local = &local }, foot_l)));
        if (tick == 0) planted = foot;
        // Within what the leg can reach: 8 cm of slide.
        if (tick >= 4 and tick <= 8) {
            // Held where it landed, within what the leg can reach.
            try t.expectEqual(@as(f32, 1), feet.legs[0].locked);
            try t.expect(foot.sub(planted.?).length() < 1e-3);
        }
        place = place.add(.init(0.01, 0, 0));
    }
    // 25 cm away it let go, and 0.1 s later it is the clip's again.
    try t.expect(!feet.legs[0].holding);
    try t.expectEqual(@as(f32, 0), feet.legs[0].locked);

    // A lock fades in over 0.05 s, and out over 0.1 s once the contact ends.
    const walking = playing(rig, name_walk, 0);
    var player = walking;
    var step: Step = .{};
    var fading: Feet = .{};
    _ = settle(rig, &fading, &player, world(.zero, 0), flat, Vec3.up, 1, .{});
    try t.expectApproxEqAbs(dt / feet_mod.lock_in, fading.legs[0].locked, 1e-6);
    while (feet_mod.contactWeights(rig, &player, .none)[0] > 0.5) {
        player.advance(rig, dt, &step);
        _ = settle(rig, &fading, &player, world(.zero, 0), flat, Vec3.up, 1, .{});
    }
    try t.expect(!fading.legs[0].holding);
    try t.expectApproxEqAbs(1 - dt / feet_mod.lock_out, fading.legs[0].locked, 1e-6);
}

// ---------------------------------------------------------------------------------------------
// Gazing.

fn facingOf(local: *[joints]Transform) Vec3 {
    return ik.modelOf(skeleton, .{ .local = local }, head).mulDirection(Vec3.forward).normalize();
}

test "a gaze sweeps toward a new target, fades in, and gives up past its limit" {
    var built: Built = undefined;
    built.init();
    const rig = built.rig();
    const to_world = world(.zero, 0);
    var clip: [joints]Transform = undefined;
    evaluate(rig, &playing(rig, name_still, 0), &clip);
    const eye = ik.positionOf(ik.modelOf(skeleton, .{ .local = &clip }, head));

    var aim: gaze_mod.Aim = .{};
    const ahead = eye.add(.init(0, 0, -3));
    var local = clip;
    aim.apply(rig, 0, .{ .local = &local }, to_world, ahead, 1, dt);
    try t.expectApproxEqAbs(dt / gaze_mod.fade, aim.weight, 1e-6);
    for (0..30) |_| {
        local = clip;
        aim.apply(rig, 0, .{ .local = &local }, to_world, ahead, 1, dt);
    }
    try t.expectEqual(@as(f32, 1), aim.weight);

    // A target to the side: the point looked at turns 6 rad/s at most.
    const side = eye.add(.init(-1.5, 0, -2));
    const before = aim.at.sub(eye).normalize();
    local = clip;
    aim.apply(rig, 0, .{ .local = &local }, to_world, side, 1, dt);
    const swept = std.math.acos(@min(1, before.dot(aim.at.sub(eye).normalize())));
    try t.expectApproxEqAbs(gaze_mod.sweep_speed * dt, swept, 1e-4);
    for (0..60) |_| {
        local = clip;
        aim.apply(rig, 0, .{ .local = &local }, to_world, side, 1, dt);
    }
    const look = facingOf(&local);
    const wanted = side.sub(ik.positionOf(ik.modelOf(skeleton, .{ .local = &local }, head))).normalize();
    try t.expect(look.cross(wanted).length() < 1e-3);

    // Behind, past 1.2 rad, it lets go.
    const behind = eye.add(.init(0, 0, 3));
    for (0..60) |_| {
        local = clip;
        aim.apply(rig, 0, .{ .local = &local }, to_world, behind, 1, dt);
    }
    try t.expect(aim.beyond);
    try t.expectEqual(@as(f32, 0), aim.weight);
    try t.expectEqualSlices(u8, std.mem.asBytes(&clip), std.mem.asBytes(&local));

    // With no target it fades out, and a chain the rig lacks changes nothing.
    var fading: gaze_mod.Aim = .{ .at = ahead, .weight = 1, .aimed = true };
    local = clip;
    fading.apply(rig, 0, .{ .local = &local }, to_world, null, 1, dt);
    try t.expectApproxEqAbs(1 - dt / gaze_mod.fade, fading.weight, 1e-6);
    local = clip;
    fading.apply(rig, 3, .{ .local = &local }, to_world, ahead, 1, dt);
    try t.expectEqualSlices(u8, std.mem.asBytes(&clip), std.mem.asBytes(&local));
}

// ---------------------------------------------------------------------------------------------
// Replay.

fn bumps(x: f32, z: f32) f32 {
    const cell = @floor(x * 4) + @floor(z * 3);
    return @mod(cell, 4) * 0.04;
}

fn replay() u64 {
    var built: Built = undefined;
    built.init();
    const rig = built.rig();
    var player = playing(rig, name_walk, 0);
    var feet: Feet = .{};
    var aim: gaze_mod.Aim = .{};
    var step: Step = .{};
    var hash: u64 = 0xcbf29ce484222325;
    for (0..1200) |tick| {
        const f: f32 = @floatFromInt(tick);
        const to_world = world(.init(f * 0.012, 0, @sin(f * 0.01)), f * 0.004);
        player.advance(rig, dt, &step);
        var local: [joints]Transform = undefined;
        evaluate(rig, &player, &local);
        var rays: [feet_mod.max_legs]feet_mod.Probe = undefined;
        const probes = Feet.probes(rig, .{ .local = &local }, to_world, &rays);
        const grounds = groundUnder(probes, bumps, Vec3.up);
        feet.place(rig, .{ .local = &local }, to_world, grounds[0..probes.len], feet_mod.contactWeights(rig, &player, .none), dt, .{});
        const target = Vec3.init(f * 0.012 + 2 * @cos(f * 0.02), 1.5, -2 + @sin(f * 0.02));
        aim.apply(rig, 0, .{ .local = &local }, to_world, if (tick % 300 < 250) target else null, 1, dt);
        for (std.mem.asBytes(&local)) |byte| hash = (hash ^ byte) *% 0x100000001b3;
        for (feet.legs[0..2]) |leg| {
            for (std.mem.asBytes(&leg.offset) ++ std.mem.asBytes(&leg.locked) ++ std.mem.asBytes(&leg.lock)) |byte| hash = (hash ^ byte) *% 0x100000001b3;
        }
        for (std.mem.asBytes(&feet.pelvis) ++ std.mem.asBytes(&aim.weight) ++ std.mem.asBytes(&aim.at)) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    }
    return hash;
}

test "1200 ticks of feet and a gaze on moving bumpy ground replay byte for byte" {
    try t.expectEqual(replay(), replay());
}

comptime {
    _ = blend_mod;
}

// ---------------------------------------------------------------------------------------------
// The panel's rows.

test "report: legs and aims are added to the figure's own row, by name" {
    var built: Built = undefined;
    built.init();
    const rig = built.rig();
    var player = playing(rig, name_walk, 10);
    var feet: Feet = .{};
    // Over a hollow, so the offsets and the pelvis have moved.
    var local = settle(rig, &feet, &player, world(.zero, 0), leftHollow, Vec3.up, 20, .{});
    var aim: gaze_mod.Aim = .{};
    const eye = ik.positionOf(ik.modelOf(skeleton, .{ .local = &local }, head));
    aim.apply(rig, 0, .{ .local = &local }, world(.zero, 0), eye.add(.init(0, 0, -3)), 1, dt);

    var step: Step = .{};
    var report: report_mod.Report = .{};
    report.add(&player, rig, "walker", &step);
    report.addFeet(rig, &feet);
    report.addAim(rig, 0, &aim);
    // A chain the rig lacks adds nothing.
    report.addAim(rig, 3, &aim);
    const row = &report.rows[0];
    try t.expect(row.feet);
    try t.expectEqual(@as(u8, 2), row.leg_count);
    try t.expectEqualStrings("left", row.legs[0].label());
    try t.expectEqualStrings("right", row.legs[1].label());
    for (row.legs[0..2], feet.legs[0..2]) |out, state| {
        try t.expectEqual(state.offset, out.offset);
        try t.expectEqual(state.contact, out.contact);
        try t.expectEqual(state.locked, out.lock);
    }
    try t.expect(row.legs[0].offset < 0);
    try t.expectEqual(feet.pelvis, row.pelvis);
    try t.expect(row.pelvis < 0);
    // The contact is what `place` was given: this tick's pose, with a foot down.
    try t.expect(row.legs[0].contact + row.legs[1].contact > 0);
    try t.expectEqual(std.math.clamp(feet_mod.contactWeights(rig, &player, .none)[0], 0, 1), row.legs[0].contact);
    try t.expectEqual(@as(u8, 1), row.aim_count);
    try t.expectEqualStrings("head", row.aims[0].label());
    try t.expectEqual(aim.weight, row.aims[0].weight);
    try t.expect(!row.aims[0].beyond);

    // A figure that got no row is counted, and its legs go nowhere, not into another's row.
    var full: report_mod.Report = .{};
    for (0..report_mod.max_rows) |_| full.add(&player, rig, "walker", &step);
    full.add(&player, rig, "ninth", &step);
    full.addFeet(rig, &feet);
    full.addAim(rig, 0, &aim);
    try t.expectEqual(@as(u32, report_mod.max_rows + 1), full.players);
    try t.expect(!full.rows[report_mod.max_rows - 1].feet);
    try t.expectEqual(@as(u8, 0), full.rows[report_mod.max_rows - 1].aim_count);
}
