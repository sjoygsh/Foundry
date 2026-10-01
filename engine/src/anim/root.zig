//! Foundry `anim` — layer L1. Depends on **`core` and nothing else**.
//!
//! Skeletal animation as sampled poses (ADR-0058): skeletons, clips, sampling, a two-pose
//! blend, skin matrices and the linear-blend skinning kernel. There is no playback state and
//! no time here: a caller says *sample this clip at this time* and is handed a pose.
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
pub const pose = @import("pose.zig");
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

pub const SkinInput = skinning.Input;
pub const SkinOutput = skinning.Output;
pub const max_influences = skinning.max_influences;
pub const skin = skinning.skin;
pub const validateInfluences = skinning.validateInfluences;

test {
    _ = clip;
    _ = pose;
    _ = skeleton;
    _ = skinning;
    _ = @import("tests.zig");
}
