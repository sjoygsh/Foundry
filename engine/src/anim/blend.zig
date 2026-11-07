//! Blend spaces: looping clips at points along one or two axes, mixed by a position between them
//! (`animation-ik.md` §7, ADR-0074).
//!
//! **A blend is played like a clip.** It is an entry of `Rig.clips` whose `blend` is set, so a
//! channel names it by the same hash and `Rig.find` answers it, and a name shared with a clip is
//! the rig's ordinary `NameCollision`. Its clip is a lap of one second with no tracks: a channel
//! playing it counts time in laps, and every clip in it is sampled at that one fraction of its own
//! length, which is M35's sync rule inside one channel.
//!
//! **One axis** sorts its points by `x` and weighs two neighbours linearly. **Two axes** need a full
//! grid, one point at every pair of its distinct `x`s and `y`s, and weigh a cell's four corners
//! bilinearly. Either way a position outside is held at the edge, and at most four clips mix.
//!
//! **Its position is not a channel's.** A machine binds a blend's axes to its parameters and passes
//! `Positions` to a tick and to a pose; with none, a blend sits at its first point's place, where
//! one clip has all the weight.

const std = @import("std");

const motion_mod = @import("motion.zig");
const rig_mod = @import("rig.zig");

const Motion = motion_mod.Motion;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;

/// The most points one blend may hold: a 5 × 5 grid.
pub const max_points = 25;

/// The most blends one rig may hold.
pub const max_blends = 8;

/// The most clips one position mixes: a grid cell's corners.
pub const max_mixed = 4;

/// The most blends one machine binds, and so the most positions a tick carries.
pub const max_positions = 8;

/// One clip at one place, as a set lists it.
pub const Point = struct {
    /// `clipName` of a looping clip of the rig.
    clip: u64,
    x: f32,
    y: f32 = 0,
};

pub const BuildError = error{ TooFewPoints, TooManyPoints, InvalidPoint, DuplicatePoint, NotAGrid };

/// A validated arrangement, held inline so a rig borrows nothing more for it.
pub const Blend = struct {
    columns: [max_points]f32 = undefined,
    rows: [max_points]f32 = undefined,
    column_count: u8 = 0,
    row_count: u8 = 0,
    /// Row-major, `row_count × column_count` of them: the clip at each place.
    cells: [max_points]u64 = undefined,
    /// Each cell's place in the list it was built from, so ties go to the earlier point.
    ranks: [max_points]u8 = undefined,
    /// The first listed point's place, where a blend sits with no position.
    origin: [2]f32 = .{ 0, 0 },

    /// Arranges `points` as a line, when every `y` is one value, or else as a full grid, refusing by
    /// name what is neither.
    pub fn build(points: []const Point) BuildError!Blend {
        if (points.len < 2) return error.TooFewPoints;
        if (points.len > max_points) return error.TooManyPoints;
        var blend: Blend = .{};
        for (points, 0..) |point, i| {
            if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidPoint;
            for (points[0..i]) |earlier| {
                if (earlier.x == point.x and earlier.y == point.y) return error.DuplicatePoint;
            }
            insert(&blend.columns, &blend.column_count, point.x);
            insert(&blend.rows, &blend.row_count, point.y);
        }
        // No two points share a place, so as many points as places means every place is filled.
        if (@as(usize, blend.column_count) * blend.row_count != points.len) return error.NotAGrid;
        for (points, 0..) |point, i| {
            const at = blend.cell(slot(blend.rowSlice(), point.y), slot(blend.columnSlice(), point.x));
            blend.cells[at] = point.clip;
            blend.ranks[at] = @intCast(i);
        }
        blend.origin = .{ points[0].x, points[0].y };
        return blend;
    }

    /// Whether a blend that did not come from `build` is one: sorted, finite, and its counts in
    /// range. `Rig.validate` asks.
    pub fn sound(blend: *const Blend) bool {
        const count = @as(usize, blend.column_count) * blend.row_count;
        if (blend.column_count == 0 or blend.row_count == 0 or count < 2 or count > max_points) return false;
        if (!ascending(blend.columnSlice()) or !ascending(blend.rowSlice())) return false;
        if (!std.math.isFinite(blend.origin[0]) or !std.math.isFinite(blend.origin[1])) return false;
        for (blend.ranks[0..count]) |rank| if (rank >= count) return false;
        return true;
    }

    /// One axis or two: a single row is a line.
    pub fn axes(blend: *const Blend) u8 {
        return if (blend.row_count == 1) 1 else 2;
    }

    pub fn places(blend: *const Blend) []const u64 {
        return blend.cells[0 .. @as(usize, blend.column_count) * blend.row_count];
    }

    pub fn columnSlice(blend: *const Blend) []const f32 {
        return blend.columns[0..blend.column_count];
    }

    pub fn rowSlice(blend: *const Blend) []const f32 {
        return blend.rows[0..blend.row_count];
    }

    fn cell(blend: *const Blend, row: usize, column: usize) usize {
        return row * blend.column_count + column;
    }

    /// The clips `at` mixes, each once, with weights summing to 1, in corner order. A clip standing
    /// at two corners has their weights together, and the earlier point's rank.
    pub fn weights(blend: *const Blend, at: [2]f32) Mix {
        const across = bracket(blend.columnSlice(), at[0]);
        const down = bracket(blend.rowSlice(), at[1]);
        var mix: Mix = .{};
        const corners = [4]struct { r: usize, c: usize, w: f32 }{
            .{ .r = down.lo, .c = across.lo, .w = (1 - across.t) * (1 - down.t) },
            .{ .r = down.lo, .c = across.hi, .w = across.t * (1 - down.t) },
            .{ .r = down.hi, .c = across.lo, .w = (1 - across.t) * down.t },
            .{ .r = down.hi, .c = across.hi, .w = across.t * down.t },
        };
        for (corners) |corner| {
            if (!(corner.w > 0)) continue;
            const at_cell = blend.cell(corner.r, corner.c);
            mix.add(blend.cells[at_cell], corner.w, blend.ranks[at_cell]);
        }
        return mix;
    }
};

/// Up to four clips and their weights.
pub const Mix = struct {
    entries: [max_mixed]Weighted = undefined,
    len: u8 = 0,

    pub const Weighted = struct { clip: u64, weight: f32, rank: u8 };

    pub fn slice(mix: *const Mix) []const Weighted {
        return mix.entries[0..mix.len];
    }

    fn add(mix: *Mix, clip: u64, weight: f32, rank: u8) void {
        for (mix.entries[0..mix.len]) |*entry| {
            if (entry.clip == clip) {
                entry.weight += weight;
                entry.rank = @min(entry.rank, rank);
                return;
            }
        }
        mix.entries[mix.len] = .{ .clip = clip, .weight = weight, .rank = rank };
        mix.len += 1;
    }

    /// The clip with the most weight, ties to the earlier point: the one whose events a blend
    /// fires (§7).
    pub fn heaviest(mix: *const Mix) u64 {
        var best: usize = 0;
        for (mix.entries[1..mix.len], 1..) |entry, i| {
            const lead = mix.entries[best];
            if (entry.weight > lead.weight or (entry.weight == lead.weight and entry.rank < lead.rank)) best = i;
        }
        return mix.entries[best].clip;
    }
};

/// Where each blend a machine plays is, this tick.
pub const Positions = struct {
    entries: [max_positions]Position = undefined,
    len: u8 = 0,

    pub const Position = struct { blend: u64, at: [2]f32 };

    /// None: every blend sits at its first point.
    pub const none: Positions = .{};

    pub fn put(self: *Positions, blend: u64, at: [2]f32) void {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.blend == blend) {
                entry.at = at;
                return;
            }
        }
        if (self.len == max_positions) return;
        self.entries[self.len] = .{ .blend = blend, .at = at };
        self.len += 1;
    }

    /// Where `entry`'s blend is: its position, or its origin. A value that is not a number is the
    /// origin's on that axis.
    pub fn of(self: *const Positions, entry: *const RigClip) [2]f32 {
        const blend = entry.blend.?;
        var at = blend.origin;
        for (self.entries[0..self.len]) |position| {
            if (position.blend != entry.name) continue;
            if (std.math.isFinite(position.at[0])) at[0] = position.at[0];
            if (std.math.isFinite(position.at[1])) at[1] = position.at[1];
        }
        return at;
    }
};

/// How long a lap of `entry`'s blend lasts at `at`, in seconds: its clips' lengths, weighted.
pub fn lapLength(rig: Rig, entry: *const RigClip, at: [2]f32) f64 {
    const mix = entry.blend.?.weights(at);
    var length: f64 = 0;
    for (mix.slice()) |part| length += @as(f64, part.weight) * member(rig, part.clip).clip.duration / member(rig, part.clip).speed;
    return length;
}

/// The blend's ground speed at `at`, in metres a second at channel speed 1: the travel of a lap,
/// weighted, over the lap's length, so it is the speed the blend's reported travel has.
pub fn groundSpeed(rig: Rig, entry: *const RigClip, at: [2]f32) f32 {
    const mix = entry.blend.?.weights(at);
    var metres: f64 = 0;
    var seconds: f64 = 0;
    for (mix.slice()) |part| {
        const clip = member(rig, part.clip);
        const length = @as(f64, clip.clip.duration) / clip.speed;
        metres += @as(f64, part.weight) * motion_mod.groundSpeed(rig, clip) * length;
        seconds += @as(f64, part.weight) * length;
    }
    if (!(seconds > 0)) return 0;
    return @floatCast(metres / seconds);
}

/// The fastest any of `entry`'s clips moves, which says whether a rate can follow a speed at all.
pub fn fastest(rig: Rig, entry: *const RigClip) f32 {
    var best: f32 = 0;
    for (entry.blend.?.places()) |name| best = @max(best, motion_mod.groundSpeed(rig, member(rig, name)));
    return best;
}

/// The move from lap `from` to lap `to`: each clip's travel over the same laps of its own, weighted.
pub fn travel(rig: Rig, entry: *const RigClip, at: [2]f32, from: f64, to: f64) Motion {
    const mix = entry.blend.?.weights(at);
    var out: Motion = .{};
    for (mix.slice()) |part| {
        const clip = member(rig, part.clip);
        if (!clip.motion) continue;
        const length: f64 = clip.clip.duration;
        const moved = motion_mod.travel(rig, clip, from * length, to * length);
        out.translation = out.translation.add(moved.translation.scale(part.weight));
        out.yaw += moved.yaw * part.weight;
    }
    return out;
}

/// A clip of a validated blend. `Rig.validate` refused a blend naming anything else.
pub fn member(rig: Rig, name: u64) *const RigClip {
    return rig.find(name).?;
}

/// The entry a rig lists for a blend: a lap of one second with no tracks, looping, at rate 1.
/// `motion` says whether any of its clips carries travel, which `Rig.validate` checks.
pub fn entryFor(name: u64, blend: *const Blend, motion: bool, sync: u64, label: []const u8) RigClip {
    return .{
        .name = name,
        .clip = .{ .duration = 1, .tracks = &.{} },
        .motion = motion,
        .sync = sync,
        .label = label,
        .blend = blend,
    };
}

pub const ValidateError = error{
    /// A blend that is not a line or a grid, or an entry for one that is not a lap of one second
    /// with no tracks, events, rise, reference or authored rate.
    InvalidBlend,
    UnknownBlendClip,
    BlendOfBlend,
    BlendOfOneShot,
    BlendOfAdditive,
    /// The entry's `motion` is not whether any of its clips has motion.
    BlendMotionMismatch,
    TooManyBlends,
};

/// Refuses every way a blend entry can be wrong for `rig`.
pub fn validate(rig: Rig, entry: *const RigClip) ValidateError!void {
    const blend = entry.blend.?;
    if (!blend.sound()) return error.InvalidBlend;
    if (entry.clip.duration != 1 or entry.clip.tracks.len != 0 or !entry.loop or entry.speed != 1) return error.InvalidBlend;
    if (entry.events.len != 0 or entry.rise != 0 or entry.additive or entry.reference.len != 0) return error.InvalidBlend;
    var moves = false;
    for (blend.places()) |name| {
        const clip = rig.find(name) orelse return error.UnknownBlendClip;
        if (clip.blend != null) return error.BlendOfBlend;
        if (!clip.loop) return error.BlendOfOneShot;
        if (clip.additive) return error.BlendOfAdditive;
        moves = moves or clip.motion;
    }
    if (moves != entry.motion) return error.BlendMotionMismatch;
}

fn insert(values: *[max_points]f32, count: *u8, value: f32) void {
    var i: usize = 0;
    while (i < count.* and values[i] < value) i += 1;
    if (i < count.* and values[i] == value) return;
    var j: usize = count.*;
    while (j > i) : (j -= 1) values[j] = values[j - 1];
    values[i] = value;
    count.* += 1;
}

fn slot(values: []const f32, value: f32) usize {
    for (values, 0..) |v, i| if (v == value) return i;
    unreachable;
}

fn ascending(values: []const f32) bool {
    for (values, 0..) |v, i| {
        if (!std.math.isFinite(v)) return false;
        if (i != 0 and !(values[i - 1] < v)) return false;
    }
    return true;
}

const Bracket = struct { lo: usize, hi: usize, t: f32 };

/// The two neighbours `value` lies between, and how far along, held at either end. A single value is
/// its own neighbour.
fn bracket(values: []const f32, value: f32) Bracket {
    const last = values.len - 1;
    // Written so a NaN holds the first.
    if (last == 0 or !(value > values[0])) return .{ .lo = 0, .hi = 0, .t = 0 };
    if (value >= values[last]) return .{ .lo = last, .hi = last, .t = 0 };
    var lo: usize = 0;
    while (values[lo + 1] <= value) lo += 1;
    if (values[lo] == value) return .{ .lo = lo, .hi = lo, .t = 0 };
    return .{ .lo = lo, .hi = lo + 1, .t = (value - values[lo]) / (values[lo + 1] - values[lo]) };
}
