//! What animation is doing, as a plain value (`animation-logic.md` §8): what the overlay's panel
//! prints.
//!
//! **The introspection lives here, and the overlay only prints it** (ADR-0025). A `Report` is
//! values and no pointers, so M48 can publish it with no redesign. A game fills it from each player
//! it wants shown.

const std = @import("std");

const motion_mod = @import("motion.zig");
const player_mod = @import("player.zig");
const rig_mod = @import("rig.zig");

const Motion = motion_mod.Motion;
const Player = player_mod.Player;
const Rig = rig_mod.Rig;
const Step = player_mod.Step;

/// How many players a report lists. The rest are still counted.
pub const max_rows = 8;

pub const max_label = 24;

pub const ChannelRow = struct {
    name: [max_label]u8 = undefined,
    name_len: u8 = 0,
    /// Seconds into the clip, folded.
    time: f32 = 0,
    duration: f32 = 0,
    weight: f32 = 0,
    speed: f32 = 0,

    pub fn label(row: *const ChannelRow) []const u8 {
        return row.name[0..@min(row.name_len, max_label)];
    }
};

pub const Row = struct {
    name: [max_label]u8 = undefined,
    name_len: u8 = 0,
    channels: [player_mod.max_channels]ChannelRow = @splat(.{}),
    channel_count: u8 = 0,
    /// This tick's.
    events: u32 = 0,
    motion: Motion = .{},

    pub fn label(row: *const Row) []const u8 {
        return row.name[0..@min(row.name_len, max_label)];
    }
};

pub const Report = struct {
    players: u32 = 0,
    rows: [max_rows]Row = undefined,
    row_count: u32 = 0,
    /// Across every player added, this tick.
    events: u32 = 0,
    dropped: u32 = 0,
    lost: u32 = 0,

    /// Adds one player's tick. `label` is a game's name for it, cut short if it is long.
    pub fn add(self: *Report, player: *const Player, rig: Rig, name: []const u8, step: *const Step) void {
        self.players += 1;
        self.events +|= step.event_count;
        self.dropped +|= step.dropped;
        self.lost +|= step.lost;
        if (self.row_count == max_rows) return;
        const row = &self.rows[self.row_count];
        self.row_count += 1;
        row.* = .{ .events = step.event_count, .motion = step.motion };
        row.name_len = copy(&row.name, name);
        for (player.channels, 0..) |channel, i| {
            const entry = rig.find(channel.clip) orelse continue;
            const out = &row.channels[row.channel_count];
            row.channel_count += 1;
            out.* = .{
                .time = player.seconds(rig, i),
                .duration = entry.clip.duration,
                .weight = channel.weight,
                .speed = channel.speed,
            };
            out.name_len = copy(&out.name, entry.label);
        }
    }
};

fn copy(to: *[max_label]u8, from: []const u8) u8 {
    const count = @min(from.len, max_label);
    @memcpy(to[0..count], from[0..count]);
    return @intCast(count);
}
