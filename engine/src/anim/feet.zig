//! Feet: legs placed on ground the game found (`animation-ik.md` §4, ADR-0073).
//!
//! **`anim` never sees the world.** `probes` says where to look, as world-space rays from each posed
//! foot; the game casts them against its own geometry and hands back a `Ground` a leg; `place`
//! corrects the pose. The pelvis only drops, each leg is reached by `ik.twoBone`, each planted foot
//! is tilted to its ground, and a planted foot may be held where it landed.
//!
//! **`Feet` is presentation, not state.** It is never saved, and it never moves a body or fires an
//! event. It is stepped once a tick with the tick's `dt`, so a replay reproduces every pose.
//!
//! **On flat ground at the figure's own height the pose is the clip's, bit for bit.** A correction
//! smaller than 0.1 mm is none, and a leg with nothing to correct is not solved.

const std = @import("std");
const core = @import("core");

const blend_mod = @import("blend.zig");
const ik = @import("ik.zig");
const player_mod = @import("player.zig");
const pose_mod = @import("pose.zig");
const rig_mod = @import("rig.zig");
const skeleton_mod = @import("skeleton.zig");

const Mat4 = core.math.Mat4;
const Player = player_mod.Player;
const Pose = pose_mod.Pose;
const Positions = blend_mod.Positions;
const Quat = core.math.Quat;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;
const Skeleton = skeleton_mod.Skeleton;
const Vec3 = core.math.Vec3;

/// Two now; four is a quadruped, which costs nothing to allow.
pub const max_legs = 4;

/// The most stretches of contact one leg has in one clip.
pub const max_contacts = 4;

/// How many fractions of a lap a clip's foot heights are read at.
pub const contact_samples = 64;

/// How fast an offset and the pelvis ease onto a new height, in metres a second.
pub const settle_speed: f32 = 2;
/// A correction smaller than this is none, so flat ground leaves the clip's pose alone.
pub const dead_zone: f32 = 1e-4;
/// The most a planted foot is tilted toward its ground, in radians.
pub const max_tilt: f32 = 0.5;
/// Seconds a lock takes to take hold and to let go.
pub const lock_in: f32 = 0.05;
pub const lock_out: f32 = 0.1;
/// How far a held foot may be from where the clip wants it before it lets go, in metres.
pub const lock_reach: f32 = 0.25;
/// How far ahead of the knee a leg's pole is, along its bend.
pub const pole_reach: f32 = 0.5;

/// A leg as a set says it (§6).
pub const Leg = struct {
    /// `clipName` of what the set calls it.
    name: u64,
    chain: ik.TwoBone,
    /// The foot joint's height above the ground at rest, in model space.
    sole: f32,
    contact_height: f32 = 0.03,
    max_raise: f32 = 0.35,
    max_drop: f32 = 0.35,
    label: []const u8 = "",
};

/// The most legs and aim chains one rig may hold.
pub const max_rig_legs = max_legs;

/// A stretch of a lap with a leg's foot down, from `from` up to `to`. `from > to` wraps through the
/// lap's end.
pub const Contact = struct {
    leg: u8,
    from: f32,
    to: f32,

    fn holds(contact: Contact, fraction: f32) bool {
        if (contact.from <= contact.to) return fraction >= contact.from and fraction < contact.to;
        return fraction >= contact.from or fraction < contact.to;
    }
};

pub const LegError = ik.TwoBone.ValidateError || error{ TooManyLegs, UnnamedLeg, DuplicateLeg, InvalidLegRange, InvalidContacts };

/// Refuses every way a rig's legs, and its clips' contacts, can be wrong.
pub fn validateLegs(rig: Rig) LegError!void {
    if (rig.legs.len > max_legs) return error.TooManyLegs;
    for (rig.legs, 0..) |leg, i| {
        if (leg.name == 0) return error.UnnamedLeg;
        for (rig.legs[0..i]) |earlier| {
            if (earlier.name == leg.name) return error.DuplicateLeg;
        }
        try leg.chain.validate(rig.skeleton);
        if (!std.math.isFinite(leg.sole)) return error.InvalidLegRange;
        if (!within(leg.contact_height, 0, 0.5) or !within(leg.max_raise, 0, 2) or !within(leg.max_drop, 0, 2)) return error.InvalidLegRange;
    }
    for (rig.clips) |entry| {
        var counts: [max_legs]u8 = @splat(0);
        if (entry.contacts.len != 0 and (!entry.loop or entry.blend != null)) return error.InvalidContacts;
        for (entry.contacts) |contact| {
            if (contact.leg >= rig.legs.len) return error.InvalidContacts;
            if (!within(contact.from, 0, 1) or !within(contact.to, 0, 1) or contact.from == contact.to) return error.InvalidContacts;
            counts[contact.leg] += 1;
            if (counts[contact.leg] > max_contacts) return error.InvalidContacts;
        }
    }
}

/// Written so a NaN is outside.
fn within(value: f32, lo: f32, hi: f32) bool {
    return value >= lo and value <= hi;
}

/// A foot joint's height above the model's floor at rest: what a leg's `sole` is.
pub fn soleOf(skeleton: Skeleton, foot: u16) f32 {
    return ik.positionOf(ik.modelOf(skeleton, .{ .local = @constCast(skeleton.rest) }, foot)).y;
}

/// Reads where each leg's foot is down in a looping clip, from its heights at `contact_samples`
/// fractions: within `contact_height` of the clip's lowest sample for that foot. Writes at most
/// `max_contacts` stretches a leg into `out`, in lap order, and returns how many. A one-shot has
/// none. `scratch` is one pose. Every value must have passed validation.
pub fn deriveContacts(skeleton: Skeleton, entry: *const RigClip, legs: []const Leg, scratch: Pose, out: []Contact) usize {
    if (!entry.loop or entry.blend != null) return 0;
    var written: usize = 0;
    for (legs, 0..) |leg, l| {
        var heights: [contact_samples]f32 = undefined;
        var lowest: f32 = std.math.inf(f32);
        for (&heights, 0..) |*height, i| {
            const at = entry.clip.duration * @as(f32, @floatFromInt(i)) / contact_samples;
            pose_mod.sample(skeleton, entry.clip, at, scratch);
            height.* = ik.positionOf(ik.modelOf(skeleton, scratch, leg.chain.end)).y;
            lowest = @min(lowest, height.*);
        }
        var down: [contact_samples]bool = undefined;
        var any_up = false;
        for (heights, 0..) |height, i| {
            down[i] = height <= lowest + leg.contact_height;
            any_up = any_up or !down[i];
        }
        if (!any_up) {
            // Down the whole lap: one stretch covering it.
            if (written < out.len) {
                out[written] = .{ .leg = @intCast(l), .from = 0, .to = 1 };
                written += 1;
            }
            continue;
        }
        // Start just after a sample that is up, so a stretch across the lap's end stays whole.
        var start: usize = 0;
        while (down[start]) start += 1;
        var count: usize = 0;
        var i: usize = 0;
        while (i < contact_samples) {
            const at = (start + i) % contact_samples;
            if (!down[at]) {
                i += 1;
                continue;
            }
            var length: usize = 0;
            while (i + length < contact_samples and down[(start + i + length) % contact_samples]) length += 1;
            if (count < max_contacts and written < out.len) {
                const from = @as(f32, @floatFromInt(at)) / contact_samples;
                const end = (at + length) % contact_samples;
                out[written] = .{ .leg = @intCast(l), .from = from, .to = if (end == 0) 1 else @as(f32, @floatFromInt(end)) / contact_samples };
                written += 1;
                count += 1;
            }
            i += length;
        }
    }
    return written;
}

/// How much each leg is down in what `player` shows: each weighted channel's contact at its
/// fraction, times its weight. A blend's is its heaviest clip's at `positions`.
pub fn contactWeights(rig: Rig, player: *const Player, positions: Positions) [max_legs]f32 {
    var out: [max_legs]f32 = @splat(0);
    for (player.channels, 0..) |channel, i| {
        if (!(channel.weight > 0)) continue;
        var entry = Player.usableIn(rig, channel) orelse continue;
        var fraction = player.seconds(rig, i);
        if (entry.blend) |blend| {
            // A blend's seconds are laps, and its clips share the fraction.
            entry = blend_mod.member(rig, blend.weights(positions.of(entry)).heaviest());
        } else {
            fraction /= entry.clip.duration;
        }
        for (entry.contacts) |contact| {
            if (contact.holds(fraction)) out[contact.leg] += channel.weight;
        }
    }
    for (&out) |*weight| weight.* = @min(1, weight.*);
    return out;
}

/// Where the game should look for a leg's ground, in world space.
pub const Probe = struct {
    origin: Vec3,
    /// Unit, along the model's down.
    direction: Vec3,
    distance: f32,
};

/// What the game found under a leg.
pub const Ground = struct {
    hit: bool = false,
    point: Vec3 = .zero,
    /// The surface's normal, in world space.
    normal: Vec3 = Vec3.up,
};

pub const Options = struct {
    /// Hold planted feet where they landed. Off for a body whose root motion already matches.
    lock: bool = true,
};

pub const LegState = struct {
    /// The foot's correction, in metres along model +Y, smoothed.
    offset: f32 = 0,
    /// Where a planted foot is held, in world space, and how firmly, 0 to 1.
    lock: Vec3 = .zero,
    locked: f32 = 0,
    /// Whether it was in contact on the last tick, so a new contact is seen.
    down: bool = false,
    /// How much the pose had it down on the last tick, 0 to 1: for the panel.
    contact: f32 = 0,
    /// Whether the lock still holds this contact, until it ends or reaches too far.
    holding: bool = false,
};

pub const Feet = struct {
    legs: [max_legs]LegState = @splat(.{}),
    /// How far the pelvis is lowered now, in metres, smoothed. Never above 0.
    pelvis: f32 = 0,

    /// One world-space ray a leg: from `max_raise` above the posed foot's sole to `max_drop` below
    /// it, in world metres, so a figure drawn at another size looks as far as its legs reach.
    /// Returns the first `rig.legs.len` of `out`.
    pub fn probes(rig: Rig, pose: Pose, to_world: Mat4, out: *[max_legs]Probe) []Probe {
        const scaled = to_world.mulDirection(Vec3.up);
        const up = direction(scaled);
        const size = scaled.length();
        const scale: f32 = if (std.math.isFinite(size) and size > 1e-9) size else 1;
        for (rig.legs, 0..) |leg, l| {
            const foot = ik.positionOf(ik.modelOf(rig.skeleton, pose, leg.chain.end));
            const top = foot.add(.init(0, leg.max_raise - leg.sole, 0));
            out[l] = .{ .origin = to_world.mulPoint(top), .direction = up.neg(), .distance = (leg.max_raise + leg.max_drop) * scale };
        }
        return out[0..rig.legs.len];
    }

    /// Corrects `pose` for one tick: offsets eased toward each leg's ground, the pelvis dropped by
    /// the lowest, each leg reached and each planted foot tilted and, with `options.lock`, held.
    /// `grounds` and `contacts` have one entry a leg. A `to_world` that cannot be undone changes
    /// nothing.
    pub fn place(feet: *Feet, rig: Rig, pose: Pose, to_world: Mat4, grounds: []const Ground, contacts: [max_legs]f32, dt: f32, options: Options) void {
        const to_model = to_world.inverse() orelse return;
        const step: f32 = if (std.math.isFinite(dt) and dt > 0) dt else 0;
        const legs = rig.legs[0..@min(rig.legs.len, grounds.len)];

        // Where the clip has each foot, before anything moves.
        var clip_feet: [max_legs]Vec3 = undefined;
        var normals: [max_legs]Vec3 = undefined;
        var lowest: f32 = 0;
        for (legs, 0..) |leg, l| {
            const state = &feet.legs[l];
            clip_feet[l] = ik.positionOf(ik.modelOf(rig.skeleton, pose, leg.chain.end));
            normals[l] = Vec3.up;
            var wanted: f32 = 0;
            const ground = grounds[l];
            if (ground.hit and ground.point.isFinite()) {
                const height = to_model.mulPoint(ground.point).y;
                if (height <= leg.max_raise and height >= -leg.max_drop) {
                    wanted = if (@abs(height) < dead_zone) 0 else height;
                    if (ground.normal.isFinite()) normals[l] = direction(to_model.mulDirection(ground.normal));
                }
            }
            state.offset = toward(sane(state.offset), wanted, settle_speed * step);
            lowest = @min(lowest, state.offset);
        }
        feet.pelvis = @min(0, toward(sane(feet.pelvis), lowest, settle_speed * step));
        dropPelvis(rig, pose, legs, feet.pelvis);

        for (legs, 0..) |leg, l| {
            const state = &feet.legs[l];
            const placed = clip_feet[l].add(.init(0, state.offset, 0));
            const contact = std.math.clamp(contacts[l], 0, 1);
            state.contact = contact;
            updateLock(state, to_world, to_model, placed, contact, step, options.lock);
            const target = if (state.locked > 0) placed.lerp(to_model.mulPoint(state.lock), state.locked) else placed;

            const now = ik.positionOf(ik.modelOf(rig.skeleton, pose, leg.chain.end));
            if (target.sub(now).length() >= 1e-5) {
                ik.twoBone(rig.skeleton, pose, leg.chain, target, poleOf(rig.skeleton, pose, leg.chain), 1);
            }
            tilt(rig.skeleton, pose, leg.chain.end, normals[l], contact);
        }
    }
};

/// Moves `value` toward `goal` by at most `by`.
fn toward(value: f32, goal: f32, by: f32) f32 {
    if (value < goal) return @min(goal, value + by);
    return @max(goal, value - by);
}

fn sane(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

fn direction(v: Vec3) Vec3 {
    const length = v.length();
    if (!(length > 1e-9) or !std.math.isFinite(length)) return Vec3.up;
    return v.scale(1 / length);
}

/// The joint every leg hangs from: the root above the first leg's hip.
fn pelvisOf(rig: Rig, legs: []const Leg) ?u16 {
    if (legs.len == 0) return null;
    var at = legs[0].chain.root;
    var steps: usize = 0;
    while (rig.skeleton.parents[at] != skeleton_mod.no_parent and steps < skeleton_mod.max_joints) : (steps += 1) at = rig.skeleton.parents[at];
    return at;
}

fn dropPelvis(rig: Rig, pose: Pose, legs: []const Leg, by: f32) void {
    if (by == 0) return;
    const pelvis = pelvisOf(rig, legs) orelse return;
    const into = rig.skeleton.root.inverse() orelse return;
    pose.local[pelvis].translation = pose.local[pelvis].translation.add(into.mulDirection(.init(0, by, 0)));
}

/// The knee pushed `pole_reach` along its bend: across the line from the hip to the foot, toward
/// the knee, or forward when the leg is straight.
fn poleOf(skeleton: Skeleton, pose: Pose, chain: ik.TwoBone) Vec3 {
    const hip = ik.positionOf(ik.modelOf(skeleton, pose, chain.root));
    const knee = ik.positionOf(ik.modelOf(skeleton, pose, chain.middle));
    const foot = ik.positionOf(ik.modelOf(skeleton, pose, chain.end));
    const line = foot.sub(hip);
    const length = line.length();
    var bend = Vec3.forward;
    if (length > 1e-6) {
        const along = line.scale(1 / length);
        const off = knee.sub(hip);
        const across = off.sub(along.scale(off.dot(along)));
        if (across.length() > 1e-5) bend = across.normalize();
    }
    return knee.add(bend.scale(pole_reach));
}

fn updateLock(state: *LegState, to_world: Mat4, to_model: Mat4, placed: Vec3, contact: f32, dt: f32, enabled: bool) void {
    const down = contact > 0.5;
    if (enabled and down and !state.down) {
        state.lock = to_world.mulPoint(placed);
        state.holding = true;
    }
    if (!down or !enabled) state.holding = false;
    if (state.holding and to_model.mulPoint(state.lock).sub(placed).length() > lock_reach) state.holding = false;
    state.down = down;
    const locked = sane(state.locked);
    state.locked = if (state.holding)
        toward(locked, 1, dt / lock_in)
    else
        toward(locked, 0, dt / lock_out);
}

/// Turns a planted foot from model up toward its ground's normal, at most `max_tilt`, by its contact.
fn tilt(skeleton: Skeleton, pose: Pose, foot: u16, normal: Vec3, contact: f32) void {
    if (!(contact > 0) or normal.dot(Vec3.up) > 1 - 1e-6) return;
    const full = ik.limitedTurn(Vec3.up, normal, max_tilt);
    const turn = if (contact >= 1) full else Quat.slerp(Quat.identity, full, contact);
    ik.turnJoint(skeleton, pose, foot, turn);
}
