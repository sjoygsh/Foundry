//! A rig: a skeleton and its clips made ready to play (`animation-logic.md` §3).
//!
//! Borrowed, like every value here. `validate` is the last validation a rig's clips see: it walks
//! every key once, when the rig is built, and a player never walks one on a tick (ADR-0071).

const std = @import("std");
const core = @import("core");

const clip_mod = @import("clip.zig");
const player = @import("player.zig");
const skeleton_mod = @import("skeleton.zig");

const Clip = clip_mod.Clip;
const Skeleton = skeleton_mod.Skeleton;

/// The most clips one rig may hold, which is what a model may list.
pub const max_clips: usize = 1024;

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
};

/// Borrowed: `clips` and everything it points to belong to the caller.
pub const Rig = struct {
    skeleton: Skeleton,
    /// Strictly ascending by `name`, so a lookup is a binary search.
    clips: []const RigClip,
    /// The clip a new player begins.
    start: u64,

    pub const ValidateError = Skeleton.ValidateError || Clip.ValidateError || error{
        NoClips,
        TooManyClips,
        UnnamedClip,
        UnsortedClips,
        /// Two clips share a hash: two names collided, or one name came twice.
        NameCollision,
        InvalidSpeed,
        UnknownStart,
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
        }
        if (rig.find(rig.start) == null) return error.UnknownStart;
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
