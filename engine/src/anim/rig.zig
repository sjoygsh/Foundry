//! A rig: a skeleton and its clips made ready to play (`animation-logic.md` §3).
//!
//! Borrowed, like every value here. `validate` is the last validation a rig's clips see: it walks
//! every key once, when the rig is built, and a player never walks one on a tick (ADR-0071).

const std = @import("std");
const core = @import("core");

const clip_mod = @import("clip.zig");
const motion = @import("motion.zig");
const player = @import("player.zig");
const skeleton_mod = @import("skeleton.zig");

const Clip = clip_mod.Clip;
const ContentId = core.ContentId;
const Skeleton = skeleton_mod.Skeleton;

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
};

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

    pub const ValidateError = Skeleton.ValidateError || Clip.ValidateError || error{
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
            if (entry.motion and rig.motion_joint == skeleton_mod.no_parent) return error.MissingMotionJoint;
        }
        if (rig.find(rig.start) == null) return error.UnknownStart;
        if (rig.motion_joint != skeleton_mod.no_parent) {
            // A child's translation is in a moving frame, which a plain difference cannot read.
            if (rig.motion_joint >= rig.skeleton.jointCount()) return error.UnknownJoint;
            if (rig.skeleton.parents[rig.motion_joint] != skeleton_mod.no_parent) return error.MotionJointNotRoot;
            if (motion.frameOf(rig) == null) return error.SingularRoot;
        }
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
        const entry = rig.find(name) orelse return 0;
        return motion.groundSpeed(rig, entry);
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
