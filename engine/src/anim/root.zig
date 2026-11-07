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

pub const blend_space = @import("blend.zig");
pub const clip = @import("clip.zig");
pub const machine = @import("machine.zig");
pub const motion = @import("motion.zig");
pub const player = @import("player.zig");
pub const pose = @import("pose.zig");
pub const report = @import("report.zig");
pub const rig = @import("rig.zig");
pub const skeleton = @import("skeleton.zig");
pub const stack = @import("stack.zig");
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
pub const addMasked = pose.addMasked;
pub const blend = pose.blend;
pub const blendMasked = pose.blendMasked;
pub const difference = pose.difference;
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

pub const Blend = blend_space.Blend;
pub const BlendMix = blend_space.Mix;
pub const BlendPoint = blend_space.Point;
pub const Positions = blend_space.Positions;
pub const max_blend_points = blend_space.max_points;
pub const max_blends = blend_space.max_blends;
pub const max_positions = blend_space.max_positions;

pub const Axes = machine.Axes;
pub const Condition = machine.Condition;
pub const Machine = machine.Machine;
pub const MachineLayer = machine.MachineLayer;
pub const MachineState = machine.State;
pub const ParamDef = machine.ParamDef;
pub const Transition = machine.Transition;
pub const max_params = machine.max_params;

pub const Layer = stack.Layer;
pub const Param = stack.Param;
pub const LayerMode = stack.Mode;
pub const LayerSpec = stack.Spec;
pub const Stack = stack.Stack;
pub const max_layers = stack.max_layers;
pub const validateSpecs = stack.validateSpecs;

pub const Event = rig.Event;
pub const Mask = rig.Mask;
pub const MaskEntry = rig.MaskEntry;
pub const fillMask = rig.fillMask;
pub const max_masks = rig.max_masks;
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
    _ = blend_space;
    _ = clip;
    _ = machine;
    _ = motion;
    _ = player;
    _ = pose;
    _ = report;
    _ = rig;
    _ = skeleton;
    _ = stack;
    _ = skinning;
    _ = @import("blend_tests.zig");
    _ = @import("direction_tests.zig");
    _ = @import("machine_tests.zig");
    _ = @import("stack_tests.zig");
    _ = @import("player_tests.zig");
    _ = @import("step_tests.zig");
    _ = @import("tests.zig");
}
