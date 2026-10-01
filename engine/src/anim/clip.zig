//! A clip: keyframe tracks over a duration, each animating one path of one joint.

const std = @import("std");
const core = @import("core");

const Quat = core.math.Quat;
const skeleton = @import("skeleton.zig");

/// What a track animates. The numeric values are stored in `.fanim`, so they do not change.
pub const Path = enum(u8) {
    translation = 0,
    rotation = 1,
    scale = 2,

    /// How many floats one key holds.
    pub fn width(path: Path) usize {
        return switch (path) {
            .translation, .scale => 3,
            .rotation => 4,
        };
    }
};

/// How a track moves between two keys. Cubic splines are refused at import
/// (`animation3d.md` §7).
pub const Interpolation = enum(u8) {
    /// Holds the earlier key's value.
    step = 0,
    /// Translation and scale linearly, rotation along the shorter arc.
    linear = 1,
};

/// No joint has more than one track per path, so this is every track a clip can hold.
pub const max_tracks: usize = skeleton.max_joints * 3;

/// Over eighteen minutes of keys at sixty a second. A bound, so a hostile file cannot make
/// validation unbounded work.
pub const max_keys_per_track: usize = 1 << 16;

/// Borrowed: both slices belong to the caller.
pub const Track = struct {
    joint: u16,
    path: Path,
    interpolation: Interpolation = .linear,
    /// Strictly increasing, in `[0, duration]`.
    times: []const f32,
    /// `path.width()` floats per key: `x, y, z` for translation and scale, `x, y, z, w` for
    /// rotation.
    values: []const f32,

    pub fn keyCount(track: Track) usize {
        return track.times.len;
    }
};

/// Borrowed: `tracks` and everything it points to belong to the caller.
pub const Clip = struct {
    /// Seconds; positive and finite.
    duration: f32,
    tracks: []const Track,

    pub const ValidateError = error{
        InvalidDuration,
        TooManyTracks,
        EmptyTrack,
        TooManyKeys,
        ValueCountMismatch,
        UnknownJoint,
        DuplicateTrack,
        InvalidTime,
        UnsortedTimes,
        InvalidValue,
        InvalidRotation,
    };

    /// Refuses every way an untrusted clip can be wrong for a skeleton of `joint_count` joints.
    /// A clip is checked against a skeleton when the two are paired, since a mod may override
    /// either.
    pub fn validate(clip: Clip, joint_count: usize) ValidateError!void {
        if (!std.math.isFinite(clip.duration) or clip.duration <= 0) return error.InvalidDuration;
        if (clip.tracks.len > max_tracks) return error.TooManyTracks;

        // Two tracks for one joint and path would let the later one win silently.
        var seen = std.StaticBitSet(max_tracks).initEmpty();
        for (clip.tracks) |track| {
            if (track.joint >= joint_count or track.joint >= skeleton.max_joints) return error.UnknownJoint;
            const slot = @as(usize, track.joint) * 3 + @intFromEnum(track.path);
            if (seen.isSet(slot)) return error.DuplicateTrack;
            seen.set(slot);

            const keys = track.times.len;
            if (keys == 0) return error.EmptyTrack;
            if (keys > max_keys_per_track) return error.TooManyKeys;
            const width = track.path.width();
            if (track.values.len != keys * width) return error.ValueCountMismatch;

            var previous: f32 = -1;
            for (track.times) |time| {
                if (!std.math.isFinite(time) or time < 0 or time > clip.duration) return error.InvalidTime;
                if (time <= previous) return error.UnsortedTimes;
                previous = time;
            }
            for (track.values) |value| {
                if (!std.math.isFinite(value)) return error.InvalidValue;
            }
            if (track.path == .rotation) {
                for (0..keys) |key| {
                    const v = track.values[key * 4 ..][0..4];
                    const q: Quat = .{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] };
                    if (!q.isUnit()) return error.InvalidRotation;
                }
            }
        }
    }
};
