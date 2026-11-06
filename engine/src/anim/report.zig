//! What animation is doing, as a plain value (`animation-logic.md` §8): what the overlay's panel
//! prints.
//!
//! **The introspection lives here, and the overlay only prints it** (ADR-0025). A `Report` is
//! values and no pointers, so M48 can publish it with no redesign. A game fills it from each player
//! it wants shown, with `add`, or from each figure a machine steers, with `addStack`
//! (`animation-states.md` §11). A row of a stack holds its layers, their states and the machine's
//! parameters by the labels content gave them, so the panel prints names, never hashes.

const std = @import("std");

const machine_mod = @import("machine.zig");
const motion_mod = @import("motion.zig");
const player_mod = @import("player.zig");
const rig_mod = @import("rig.zig");
const stack_mod = @import("stack.zig");

const Machine = machine_mod.Machine;
const Mode = stack_mod.Mode;
const Motion = motion_mod.Motion;
const Player = player_mod.Player;
const Rig = rig_mod.Rig;
const Stack = stack_mod.Stack;
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

/// One layer of a figure: what the machine calls it and its state, and its player's channels. A
/// bare player's row has one, with no names.
pub const LayerRow = struct {
    name: [max_label]u8 = undefined,
    name_len: u8 = 0,
    mode: Mode = .override,
    /// The mask's label, or empty for every joint.
    mask: [max_label]u8 = undefined,
    mask_len: u8 = 0,
    weight: f32 = 1,
    state: [max_label]u8 = undefined,
    state_len: u8 = 0,
    /// Ticks in that state.
    state_ticks: u64 = 0,
    channels: [player_mod.max_channels]ChannelRow = @splat(.{}),
    channel_count: u8 = 0,

    pub fn label(row: *const LayerRow) []const u8 {
        return row.name[0..@min(row.name_len, max_label)];
    }

    pub fn maskLabel(row: *const LayerRow) []const u8 {
        return row.mask[0..@min(row.mask_len, max_label)];
    }

    pub fn stateLabel(row: *const LayerRow) []const u8 {
        return row.state[0..@min(row.state_len, max_label)];
    }
};

pub const ParamRow = struct {
    name: [max_label]u8 = undefined,
    name_len: u8 = 0,
    /// What the next tick will see.
    value: f32 = 0,

    pub fn label(row: *const ParamRow) []const u8 {
        return row.name[0..@min(row.name_len, max_label)];
    }
};

pub const Row = struct {
    name: [max_label]u8 = undefined,
    name_len: u8 = 0,
    /// Whether a machine steers it; a bare player's row prints as M34's did.
    machine: bool = false,
    layers: [stack_mod.max_layers]LayerRow = @splat(.{}),
    layer_count: u8 = 0,
    params: [stack_mod.max_params]ParamRow = @splat(.{}),
    param_count: u8 = 0,
    /// This tick's.
    events: u32 = 0,
    motion: Motion = .{},
    /// This tick's, as `Step`'s.
    transitions: u32 = 0,

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
    /// Across every figure a machine steers, this tick (`Step`'s).
    transitions: u32 = 0,
    reentered: u32 = 0,
    params_dropped: u32 = 0,

    /// Adds one player's tick. `label` is a game's name for it, cut short if it is long.
    pub fn add(self: *Report, player: *const Player, rig: Rig, name: []const u8, step: *const Step) void {
        const row = self.begin(name, step) orelse return;
        row.layer_count = 1;
        channels(&row.layers[0], player, rig);
    }

    /// Adds one figure's tick, as `machine.advance` left `stack`: each of the machine's layers with
    /// its mode, mask, weight and state, and every parameter with the value the next tick will see.
    /// A state the machine lacks prints with no name, as a hash would tell no one anything.
    pub fn addStack(self: *Report, stack: *const Stack, rig: Rig, machine: Machine, name: []const u8, step: *const Step) void {
        self.transitions +|= step.transitions;
        self.reentered +|= step.reentered;
        self.params_dropped +|= step.params_dropped;
        const row = self.begin(name, step) orelse return;
        row.machine = true;
        row.transitions = step.transitions;
        const count = @min(machine.layers.len, stack_mod.max_layers);
        row.layer_count = @intCast(count);
        for (machine.layers[0..count], 0..) |layer, i| {
            const out = &row.layers[i];
            out.name_len = copy(&out.name, layer.label);
            out.mode = layer.spec.mode;
            if (layer.spec.mask != 0) {
                if (rig.mask(layer.spec.mask)) |m| out.mask_len = copy(&out.mask, m.label);
            }
            out.weight = if (i == 0) 1 else stack.layers[i].weight;
            if (layer.state(stack.layers[i].state)) |state| out.state_len = copy(&out.state, state.label);
            out.state_ticks = stack.layers[i].state_ticks;
            channels(out, &stack.players[i], rig);
        }
        const params = @min(machine.params.len, stack_mod.max_params);
        row.param_count = @intCast(params);
        for (machine.params[0..params], 0..) |param, i| {
            const out = &row.params[i];
            out.name_len = copy(&out.name, param.label);
            out.value = machine_mod.get(stack, machine, param.name) orelse param.default;
        }
    }

    fn begin(self: *Report, name: []const u8, step: *const Step) ?*Row {
        self.players += 1;
        self.events +|= step.event_count;
        self.dropped +|= step.dropped;
        self.lost +|= step.lost;
        if (self.row_count == max_rows) return null;
        const row = &self.rows[self.row_count];
        self.row_count += 1;
        row.* = .{ .events = step.event_count, .motion = step.motion };
        row.name_len = copy(&row.name, name);
        return row;
    }
};

fn channels(row: *LayerRow, player: *const Player, rig: Rig) void {
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

fn copy(to: *[max_label]u8, from: []const u8) u8 {
    const count = @min(from.len, max_label);
    @memcpy(to[0..count], from[0..count]);
    return @intCast(count);
}
