//! Layers: players mixed over one another (`animation-states.md` §6, ADR-0072).
//!
//! **A stack is up to three layers, each an `anim.Player`.** Layer 0 is the base. Each layer above it
//! is mixed over what is beneath, in order, by its weight and a mask: an override layer replaces
//! joints, and an additive layer adds a difference onto them. A layer's mode and mask are not state.
//! They are a `Spec` the caller passes, from a machine (§7) or by hand, so a save holds only what
//! changes.
//!
//! **Root motion comes from the base alone,** so a body has one path. **Events come from every layer
//! whose weight is above zero,** from its newest channel, in layer order. A stack with one layer
//! evaluates exactly as its player does, bit for bit.
//!
//! **Everything a stack holds is untrusted,** as a player's is: a clip on the wrong kind of layer is
//! emptied and counted, and a weight out of range is held in it. Nothing asserts on it.

const std = @import("std");
const core = @import("core");

const player_mod = @import("player.zig");
const pose_mod = @import("pose.zig");
const rig_mod = @import("rig.zig");

const Player = player_mod.Player;
const PlayError = player_mod.PlayError;
const PlayOptions = player_mod.PlayOptions;
const Pose = pose_mod.Pose;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;
const Step = player_mod.Step;

/// A body, an upper-body override and an additive breath. More is a schema version of
/// `foundry:animator`.
pub const max_layers = 3;

pub const Mode = enum(u8) {
    /// The layer's pose replaces the one beneath, by `mask × weight`.
    override,
    /// The layer's difference is added onto the one beneath, by `mask × weight`.
    additive,
};

/// What a layer is, as opposed to where it has got. Never saved.
pub const Spec = struct {
    mode: Mode = .override,
    /// `clipName` of a mask of the rig, or zero for every joint at 1.
    mask: u64 = 0,
    /// Seconds a layer's weight takes to reach its target; zero is at once.
    fade: f32 = 0,
};

/// `extern`, since `foundry:animator` lays its fields over this exactly (§8).
pub const Layer = extern struct {
    player: Player = .{},
    /// 0 to 1. The base's is always 1.
    weight: f32 = 0,
    /// Where `weight` is going.
    target: f32 = 0,
    /// The machine's state, by name hash; zero is none yet (§7, Step 3).
    state: u64 = 0,
    /// Ticks in that state.
    state_ticks: u64 = 0,
};

pub const SpecError = error{
    NoLayers,
    TooManyLayers,
    /// The base is an override of every joint.
    AdditiveBase,
    MaskOnBase,
    UnknownMask,
    InvalidFade,
};

pub const StackError = PlayError || error{
    UnknownLayer,
    /// An additive clip on an override layer, or the other way round.
    ModeMismatch,
    /// A clip with motion above the base: a body has one path.
    MotionOffBase,
};

/// Refuses every way a caller's specs can be wrong for `rig`. A machine's are checked when it is
/// built; a game passing its own checks them once.
pub fn validateSpecs(rig: Rig, specs: []const Spec) SpecError!void {
    if (specs.len == 0) return error.NoLayers;
    if (specs.len > max_layers) return error.TooManyLayers;
    if (specs[0].mode != .override) return error.AdditiveBase;
    if (specs[0].mask != 0) return error.MaskOnBase;
    for (specs) |spec| {
        if (spec.mask != 0 and rig.mask(spec.mask) == null) return error.UnknownMask;
        if (!std.math.isFinite(spec.fade) or spec.fade < 0) return error.InvalidFade;
    }
}

/// A machine's inputs (§7, Step 3). More is a schema version of `foundry:animator`.
pub const max_params = 8;

/// One saved parameter, by name, so a machine that gains, loses or reorders one keeps the rest.
pub const Param = extern struct {
    /// `clipName` of the machine's name for it; zero is an empty slot.
    name: u64 = 0,
    value: f32 = 0,
};

pub const Stack = extern struct {
    layers: [max_layers]Layer = .{ .{ .weight = 1, .target = 1 }, .{}, .{} },
    /// A machine's parameters, in its order once it has run (`machine.zig`).
    params: [max_params]Param = @splat(.{}),

    /// The base layer's player, which is all a one-layer stack is.
    pub fn base(self: *Stack) *Player {
        return &self.layers[0].player;
    }

    /// `Player.play` on `layer`, refusing a clip that layer cannot play. A refusal changes nothing.
    pub fn play(self: *Stack, rig: Rig, specs: []const Spec, layer: usize, name: u64, options: PlayOptions) StackError!void {
        if (layer >= specs.len or layer >= max_layers) return error.UnknownLayer;
        const entry = rig.find(name) orelse return error.UnknownClip;
        if (!fits(entry, specs[layer].mode, layer)) {
            return if (entry.motion and layer != 0) error.MotionOffBase else error.ModeMismatch;
        }
        try self.layers[layer].player.play(rig, name, options);
    }

    /// Where `layer`'s weight goes, from 0 to 1, at its spec's fade. The base's stays at 1. A value
    /// that is not a number is 0.
    pub fn setTarget(self: *Stack, layer: usize, target: f32) void {
        if (layer == 0 or layer >= max_layers) return;
        self.layers[layer].target = unit(target);
    }

    /// One tick of every layer in `specs`, base first. `step` gets the base's motion and every
    /// weighted layer's events, in layer order, with what was lost and dropped added up.
    pub fn advance(self: *Stack, rig: Rig, specs: []const Spec, dt: f32, step: *Step) void {
        step.* = .{};
        const count = @min(specs.len, max_layers);
        for (0..count) |i| self.advanceLayer(rig, specs, i, dt, null, step);
    }

    /// One layer's tick, adding to `step`: run, or seek to `seek` of its newest clip's lap. A
    /// machine calls this a layer at a time (`machine.zig`).
    pub fn advanceLayer(self: *Stack, rig: Rig, specs: []const Spec, i: usize, dt: f32, seek: ?f32, step: *Step) void {
        const layer = &self.layers[i];
        self.repair(rig, specs, i, dt, step);
        if (i != 0 and !layer.player.hasClip()) return;
        var own: Step = undefined;
        if (seek) |fraction| layer.player.seek(rig, fraction, dt, &own) else layer.player.advance(rig, dt, &own);
        step.lost +|= own.lost;
        step.dropped +|= own.dropped;
        if (i == 0) step.motion = own.motion;
        if (layer.weight > 0) {
            for (own.fired()) |event| step.emit(event);
        }
    }

    /// The pose: the base, then each layer above it with weight, mixed in order. `scratch` is two
    /// poses the caller lends, and `out` may be followed by `skinMatrices`.
    pub fn evaluate(self: *const Stack, rig: Rig, specs: []const Spec, scratch: [2]Pose, out: Pose) void {
        self.layers[0].player.evaluate(rig, scratch[1], out);
        const count = @min(specs.len, max_layers);
        for (1..count) |i| {
            const layer = &self.layers[i];
            const weight = unit(layer.weight);
            if (weight == 0 or !layer.player.hasWeight(rig)) continue;
            layer.player.evaluate(rig, scratch[1], scratch[0]);
            const mask = if (specs[i].mask == 0) null else if (rig.mask(specs[i].mask)) |m| m.weights else continue;
            switch (specs[i].mode) {
                .override => pose_mod.blendMasked(out, scratch[0], mask, weight, out),
                .additive => pose_mod.addMasked(out, scratch[0], mask, weight, out),
            }
        }
    }

    /// Makes one layer safe to tick: its weight moved toward its target and both held in range, and
    /// any clip it cannot play emptied and counted.
    fn repair(self: *Stack, rig: Rig, specs: []const Spec, i: usize, dt: f32, step: *Step) void {
        const layer = &self.layers[i];
        if (i == 0) {
            layer.weight = 1;
            layer.target = 1;
        } else {
            layer.target = unit(layer.target);
            layer.weight = unit(layer.weight);
            const fade = specs[i].fade;
            if (!(fade > 0) or !std.math.isFinite(fade)) {
                layer.weight = layer.target;
            } else {
                const by = (if (std.math.isFinite(dt) and dt > 0) dt else 0) / fade;
                layer.weight = if (layer.weight < layer.target) @min(layer.target, layer.weight + by) else @max(layer.target, layer.weight - by);
            }
        }
        for (&layer.player.channels) |*channel| {
            if (channel.clip == 0) continue;
            if (Player.usableIn(rig, channel.*)) |entry| {
                if (fits(entry, specs[i].mode, i)) continue;
            } else if (i == 0) {
                // The base's own player empties and counts it, and begins the start clip.
                continue;
            }
            // Above the base, a layer emptied here stays empty: the player's own repair would begin
            // the rig's start clip, which is the base's.
            channel.* = .{};
            step.lost +|= 1;
        }
    }
};

/// Whether `entry` may play on layer `i` of `mode`.
fn fits(entry: *const RigClip, mode: Mode, i: usize) bool {
    if (entry.motion and i != 0) return false;
    return entry.additive == (mode == .additive);
}

/// Written so a NaN is 0.
fn unit(value: f32) f32 {
    return if (!(value > 0)) 0 else @min(value, 1);
}
