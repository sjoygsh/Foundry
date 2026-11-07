//! A rig: a skeleton and its clips made ready to play (`animation-logic.md` §3).
//!
//! Borrowed, like every value here. `validate` is the last validation a rig's clips see: it walks
//! every key once, when the rig is built, and a player never walks one on a tick (ADR-0071).

const std = @import("std");
const core = @import("core");

const blend_mod = @import("blend.zig");
const clip_mod = @import("clip.zig");
const feet_mod = @import("feet.zig");
const gaze_mod = @import("gaze.zig");
const motion = @import("motion.zig");
const player = @import("player.zig");
const skeleton_mod = @import("skeleton.zig");

const Clip = clip_mod.Clip;
const ContentId = core.ContentId;
const Skeleton = skeleton_mod.Skeleton;
const Transform = core.math.Transform;

/// The most clips one rig may hold, which is what a model may list.
pub const max_clips: usize = 1024;

/// The most events one clip may carry.
pub const max_events: usize = 64;

/// A name a game listens for, at a fraction of a clip, so that a retimed clip keeps its footsteps
/// on its feet. It carries nothing else: what it does is the game's (I5).
pub const Event = struct {
    /// From 0 up to but not including 1, or exactly 1 on a one-shot clip.
    at: f32,
    id: ContentId,
};

/// What a clip is called in a player: the hash of its name. A generated clip's ID is numbered by
/// file order (ADR-0055), so a re-export would make a saved ID or index play the wrong clip.
pub fn clipName(name: []const u8) u64 {
    return core.id.fnv1a64(name);
}

pub const RigClip = struct {
    /// `clipName` of what the model calls it. Zero marks an empty channel, so it is refused.
    name: u64,
    clip: Clip,
    loop: bool = true,
    /// The authored rate, multiplied into a channel's.
    speed: f32 = 1,
    /// Whether its motion joint's travel leaves the pose and is reported (`motion.zig`).
    motion: bool = false,
    /// Ascending by `at`.
    events: []const Event = &.{},
    /// What the model calls it, for a person: the panel prints it, and a hash is no use to anyone.
    label: []const u8 = "",
    /// `clipName` of its sync group, or zero for none. Clips of one group are kept at one fraction
    /// (`animation-states.md` §4). Only a looping clip has a lap to share.
    sync: u64 = 0,
    /// Metres one lap climbs, for `lapsFor`, or zero for none (§5).
    rise: f32 = 0,
    /// Played as a difference from `reference`, on an additive layer (`animation-states.md` §6).
    additive: bool = false,
    /// An additive clip's reference pose, one transform a joint, sampled when the rig was built so
    /// that no tick samples it. Empty for any other clip.
    reference: []const Transform = &.{},
    /// Set for a blend space rather than a clip (`animation-ik.md` §7): `clip` is then a lap of one
    /// second with no tracks, and the blend says what plays. `blend.entryFor` makes one.
    blend: ?*const blend_mod.Blend = null,
    /// Where each leg's foot is down in a lap, read from the clip when the rig was built
    /// (`animation-ik.md` §4). Empty for a one-shot and a blend.
    contacts: []const feet_mod.Contact = &.{},
};

/// Per-joint weights a layer is mixed by, named as a clip is (§6).
pub const Mask = struct {
    /// `clipName` of what the set calls it.
    name: u64,
    /// One a joint, each from 0 to 1.
    weights: []const f32,
    label: []const u8 = "",
};

/// The most masks one rig may hold.
pub const max_masks: usize = 8;

/// The most joints one mask may name, each with its subtree.
pub const max_mask_entries: usize = 32;

/// One entry of a mask as a set writes it: a joint and everything below it, at a weight.
pub const MaskEntry = struct {
    joint: u16,
    weight: f32,
};

pub const FillError = error{ UnknownJoint, InvalidMaskWeight, TooManyMaskEntries };

/// Fills a mask's weights from its entries, in order, each over a joint's subtree, so a later entry
/// overrides an earlier one and `spine 0.5` then `chest 1` feathers a waist. A joint no entry reaches
/// is 0. `skeleton` must have passed `validate`, so a parent comes before its child.
pub fn fillMask(skeleton: Skeleton, entries: []const MaskEntry, out: []f32) FillError!void {
    core.assert.always(out.len == skeleton.jointCount(), "a mask needs a weight for each of {d} joints", .{skeleton.jointCount()});
    if (entries.len > max_mask_entries) return error.TooManyMaskEntries;
    for (entries) |entry| {
        if (entry.joint >= skeleton.jointCount()) return error.UnknownJoint;
        // Written so a NaN is refused.
        if (!(entry.weight >= 0 and entry.weight <= 1)) return error.InvalidMaskWeight;
    }
    @memset(out, 0);
    var inside: std.StaticBitSet(skeleton_mod.max_joints) = .initEmpty();
    for (entries) |entry| {
        inside = .initEmpty();
        for (skeleton.parents, 0..) |parent, joint| {
            const under = joint == entry.joint or (parent != skeleton_mod.no_parent and inside.isSet(parent));
            if (!under) continue;
            inside.set(joint);
            out[joint] = entry.weight;
        }
    }
}

/// The most laps `lapsFor` answers. A crossing that long is a hostile package or a mistake.
pub const max_fitted_laps: u32 = 256;

/// Borrowed: `clips` and everything it points to belong to the caller.
pub const Rig = struct {
    skeleton: Skeleton,
    /// Strictly ascending by `name`, so a lookup is a binary search.
    clips: []const RigClip,
    /// The clip a new player begins.
    start: u64,
    /// The root joint that carries a motion clip's travel, or `no_parent`.
    motion_joint: u16 = skeleton_mod.no_parent,
    /// Unsorted, and few, so a lookup is a walk.
    masks: []const Mask = &.{},
    /// A figure's legs and aim chains (`animation-ik.md` §4, §5).
    legs: []const feet_mod.Leg = &.{},
    aims: []const gaze_mod.RigAim = &.{},

    pub const ValidateError = Skeleton.ValidateError || Clip.ValidateError || blend_mod.ValidateError || feet_mod.LegError || gaze_mod.AimError || error{
        NoClips,
        TooManyClips,
        UnnamedClip,
        UnsortedClips,
        /// Two clips share a hash: two names collided, or one name came twice.
        NameCollision,
        InvalidSpeed,
        UnknownStart,
        TooManyEvents,
        UnnamedEvent,
        EventOutOfRange,
        UnsortedEvents,
        MissingMotionJoint,
        MotionJointNotRoot,
        /// The skeleton's root matrix cannot be undone, so a pose cannot lose a model-space move.
        SingularRoot,
        /// A one-shot has no lap to keep in step.
        SyncOnOneShot,
        InvalidRise,
        /// An additive clip's travel would have nowhere to go: motion is the base layer's.
        AdditiveWithMotion,
        /// An additive clip with no reference of the skeleton's length, or another with one.
        InvalidReference,
        /// A new player begins its start clip on the base layer, which plays no difference.
        AdditiveStart,
        TooManyMasks,
        UnnamedMask,
        DuplicateMask,
        InvalidMask,
    };

    /// Refuses every way an untrusted rig can be wrong. A rig that passes is safe for a player to
    /// use, whatever that player holds.
    pub fn validate(rig: Rig) ValidateError!void {
        try rig.skeleton.validate();
        if (rig.clips.len == 0) return error.NoClips;
        if (rig.clips.len > max_clips) return error.TooManyClips;
        var previous: u64 = 0;
        for (rig.clips, 0..) |entry, i| {
            if (entry.name == 0) return error.UnnamedClip;
            if (i != 0 and entry.name == previous) return error.NameCollision;
            if (entry.name < previous) return error.UnsortedClips;
            previous = entry.name;
            if (!std.math.isFinite(entry.speed) or entry.speed <= 0 or entry.speed > player.max_speed) return error.InvalidSpeed;
            try entry.clip.validate(rig.skeleton.jointCount());
            try validateEvents(entry);
            if (entry.sync != 0 and !entry.loop) return error.SyncOnOneShot;
            // Written so a NaN is refused.
            if (!(entry.rise >= 0) or !std.math.isFinite(entry.rise)) return error.InvalidRise;
            try validateAdditive(rig, entry);
            if (entry.motion and rig.motion_joint == skeleton_mod.no_parent) return error.MissingMotionJoint;
        }
        // A blend names clips, so it is checked once they all are.
        var blends: usize = 0;
        for (rig.clips) |*entry| {
            if (entry.blend == null) continue;
            blends += 1;
            if (blends > blend_mod.max_blends) return error.TooManyBlends;
            try blend_mod.validate(rig, entry);
        }
        try feet_mod.validateLegs(rig);
        try gaze_mod.validateAims(rig);
        if (rig.find(rig.start) == null) return error.UnknownStart;
        if (rig.find(rig.start).?.additive) return error.AdditiveStart;
        try rig.validateMasks();
        if (rig.motion_joint != skeleton_mod.no_parent) {
            // A child's translation is in a moving frame, which a plain difference cannot read.
            if (rig.motion_joint >= rig.skeleton.jointCount()) return error.UnknownJoint;
            if (rig.skeleton.parents[rig.motion_joint] != skeleton_mod.no_parent) return error.MotionJointNotRoot;
            if (motion.frameOf(rig) == null) return error.SingularRoot;
        }
    }

    fn validateAdditive(rig: Rig, entry: RigClip) ValidateError!void {
        if (!entry.additive) {
            if (entry.reference.len != 0) return error.InvalidReference;
            return;
        }
        if (entry.motion) return error.AdditiveWithMotion;
        if (entry.reference.len != rig.skeleton.jointCount()) return error.InvalidReference;
        for (entry.reference) |joint| {
            if (!joint.translation.isFinite() or !joint.scale.isFinite()) return error.InvalidReference;
            if (!joint.rotation.isUnit()) return error.InvalidReference;
        }
    }

    fn validateMasks(rig: Rig) ValidateError!void {
        if (rig.masks.len > max_masks) return error.TooManyMasks;
        for (rig.masks, 0..) |entry, i| {
            if (entry.name == 0) return error.UnnamedMask;
            for (rig.masks[0..i]) |earlier| {
                if (earlier.name == entry.name) return error.DuplicateMask;
            }
            if (entry.weights.len != rig.skeleton.jointCount()) return error.InvalidMask;
            for (entry.weights) |w| {
                // Written so a NaN is refused.
                if (!(w >= 0 and w <= 1)) return error.InvalidMask;
            }
        }
    }

    /// The mask called `name`, or null.
    pub fn mask(rig: Rig, name: u64) ?*const Mask {
        for (rig.masks) |*candidate| {
            if (candidate.name == name) return candidate;
        }
        return null;
    }

    fn validateEvents(entry: RigClip) ValidateError!void {
        if (entry.events.len > max_events) return error.TooManyEvents;
        var previous: f32 = 0;
        for (entry.events) |event| {
            if (event.id.isNone()) return error.UnnamedEvent;
            // Written so a NaN is out of range. 1 on a loop is the next lap's 0, twice.
            const inside = event.at >= 0 and (event.at < 1 or (event.at == 1 and !entry.loop));
            if (!inside) return error.EventOutOfRange;
            if (event.at < previous) return error.UnsortedEvents;
            previous = event.at;
        }
    }

    /// A motion clip's ground speed in metres a second, at channel speed 1, or 0 for a clip with
    /// no motion. It is what a body moved by other means divides its own speed by, so that its
    /// feet keep up (`animation-logic.md` §6).
    pub fn motionSpeed(rig: Rig, name: u64) f32 {
        return rig.motionSpeedAt(name, .none);
    }

    /// `motionSpeed`, with a blend at its position in `positions` rather than at its first point.
    pub fn motionSpeedAt(rig: Rig, name: u64, positions: blend_mod.Positions) f32 {
        const entry = rig.find(name) orelse return 0;
        if (entry.blend != null) return blend_mod.groundSpeed(rig, entry, positions.of(entry));
        return motion.groundSpeed(rig, entry);
    }

    /// The blend called `name`, or null for a clip or nothing.
    pub fn blend(rig: Rig, name: u64) ?*const blend_mod.Blend {
        const entry = rig.find(name) orelse return null;
        return entry.blend;
    }

    /// How many laps of `name` fit a climb of `height` metres: its `rise` into the height, rounded,
    /// from 1 to `max_fitted_laps`. A clip with no rise, or a height that is not a number, is 1.
    pub fn lapsFor(rig: Rig, name: u64, height: f32) u32 {
        const entry = rig.find(name) orelse return 1;
        if (!entry.loop or !(entry.rise > 0) or !std.math.isFinite(height)) return 1;
        const laps = @round(@abs(height) / entry.rise);
        if (!(laps >= 1)) return 1;
        return if (laps >= @as(f32, @floatFromInt(max_fitted_laps))) max_fitted_laps else @intFromFloat(laps);
    }

    /// The clip called `name`, or null: a reload or a removed mod can leave a player holding a
    /// name its rig no longer has, and that is not a programmer error.
    pub fn find(rig: Rig, name: u64) ?*const RigClip {
        var lo: usize = 0;
        var hi: usize = rig.clips.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = rig.clips[mid].name;
            if (at == name) return &rig.clips[mid];
            if (at < name) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};
