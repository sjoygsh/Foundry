//! Foundry `anim` — layer L1. Depends on **`core` and nothing else**.
//!
//! Skeletal animation as sampled poses (ADR-0058): skeletons, clips, sampling, a two-pose
//! blend, skin matrices and the linear-blend skinning kernel. A caller says *sample this clip at
//! this time* and is handed a pose. Playback, where a game wants it, is `Player`: a plain value
//! of a few channels, ticked by its owner and holding no clock (ADR-0071).
//!
//! **No assets, no entities, no renderer, no I/O.** `asset`, `scene` and `render3d` are above
//! this module and cannot be named from it. A skeleton and a clip arrive as values whose slices
//! the caller owns (as `physics3d` takes geometry, ADR-0057), so animation works with no file,
//! no ECS and no device.
//!
//! **Nothing allocates.** No function here takes an allocator; every result is written into a
//! buffer the caller passes.
//!
//! **Time is the caller's, in seconds.** A simulation derives it from its tick count
//! (`tick × dt`, then `wrap` or `clamp`) and never by accumulating `dt`, so a long run does not
//! drift and a replay from tick zero reproduces every pose (I9).
//!
//! **Determinism is interface contract** (I9): joints and tracks are visited in stored order,
//! nothing reads a clock or an address, and there is no fast-math. The same binary and inputs
//! give the same bytes; across machines the last bit is not promised (ADR-0013).
//!
//! Skeletons, clips and vertex influences come from content, and from M25 perhaps from a mod, so
//! each has a `validate` that **refuses by name**. Sampling or skinning a value that was never
//! validated is a programmer error.
//!
//! Design: `docs/design/animation3d.md`

pub const clip = @import("clip.zig");
pub const motion = @import("motion.zig");
pub const player = @import("player.zig");
pub const pose = @import("pose.zig");
pub const report = @import("report.zig");
pub const rig = @import("rig.zig");
pub const skeleton = @import("skeleton.zig");
pub const skinning = @import("skin.zig");

// The names reached for most often. A game sees them today and a mod may later, so renaming one
// is a compatibility decision rather than a tidy-up (CLAUDE.md §7).
pub const Clip = clip.Clip;
pub const Interpolation = clip.Interpolation;
pub const Path = clip.Path;
pub const Track = clip.Track;
pub const max_keys_per_track = clip.max_keys_per_track;
pub const max_tracks = clip.max_tracks;

pub const Skeleton = skeleton.Skeleton;
pub const max_joints = skeleton.max_joints;
pub const no_parent = skeleton.no_parent;

pub const Pose = pose.Pose;
pub const blend = pose.blend;
pub const clamp = pose.clamp;
pub const modelMatrices = pose.modelMatrices;
pub const sample = pose.sample;
pub const skinMatrices = pose.skinMatrices;
pub const wrap = pose.wrap;

pub const Channel = player.Channel;
pub const Motion = motion.Motion;
pub const Phase = player.Phase;
pub const PlayError = player.PlayError;
pub const PlayOptions = player.PlayOptions;
pub const Player = player.Player;
pub const Step = player.Step;
pub const max_channels = player.max_channels;
pub const max_speed = player.max_speed;
pub const max_step_events = player.max_step_events;

pub const Report = report.Report;

pub const Event = rig.Event;
pub const Rig = rig.Rig;
pub const RigClip = rig.RigClip;
pub const clipName = rig.clipName;
pub const max_clip_events = rig.max_events;
pub const max_rig_clips = rig.max_clips;

pub const SkinInput = skinning.Input;
pub const SkinOutput = skinning.Output;
pub const max_influences = skinning.max_influences;
pub const skin = skinning.skin;
pub const validateInfluences = skinning.validateInfluences;

test {
    _ = clip;
    _ = motion;
    _ = player;
    _ = pose;
    _ = report;
    _ = rig;
    _ = skeleton;
    _ = skinning;
    _ = @import("player_tests.zig");
    _ = @import("step_tests.zig");
    _ = @import("tests.zig");
}
