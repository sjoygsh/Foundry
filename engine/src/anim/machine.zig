//! State machines: states, transitions and parameters stepping a `Stack` (`animation-states.md` §7,
//! ADR-0072).
//!
//! **A machine is a validated description, and a stack is its place in it.** `Machine` is borrowed,
//! like a rig: `asset.Rigs` builds it from `foundry:animation_machine` (§10), and a test builds one
//! by hand. A stack holds what changes: each layer's state and ticks in it, and the parameters. A
//! machine reads no clock and allocates nothing.
//!
//! **Parameters are a game's inputs:** up to eight named `f32`s, set before a tick. There are no
//! triggers: a game that wants one sets a parameter for one tick.
//!
//! **One tick, for each layer in order:** its weight's target follows its parameter; the first
//! `"*"` transition that holds and leads elsewhere is taken, or else the first of the state's own,
//! at most one a tick; the state's rate is set from its parameter; then the layer runs, or seeks.
//! That order is the contract.
//!
//! **Everything a stack holds is untrusted:** a state the machine lacks begins its layer's entry
//! again and is counted, and a layer with no state yet adopts the one its newest clip plays, so a
//! save from before machines carries on without a pop.

const std = @import("std");

const player_mod = @import("player.zig");
const rig_mod = @import("rig.zig");
const stack_mod = @import("stack.zig");

const Layer = stack_mod.Layer;
const Param = stack_mod.Param;
const Phase = player_mod.Phase;
const Pose = @import("pose.zig").Pose;
const Rig = rig_mod.Rig;
const RigClip = rig_mod.RigClip;
const Spec = stack_mod.Spec;
const Stack = stack_mod.Stack;
const Step = player_mod.Step;

pub const max_params = stack_mod.max_params;
pub const max_states = 32;
pub const max_transitions = 64;
pub const max_conditions = 4;

/// A transition's `from` that matches any state.
pub const any_state: u64 = 0;

pub const ParamDef = struct {
    /// `clipName` of what the record calls it.
    name: u64,
    default: f32 = 0,
    label: []const u8 = "",
};

pub const Quantity = enum {
    /// The value of `Condition.param`.
    param,
    /// Laps of the state's clip, as authored, since the state was entered: `ticks × dt` against
    /// `value × duration`, which is how a pacer times its side.
    laps,
    /// 1 once the state's one-shot is at its end, and 0 before.
    finished,
};

pub const Compare = enum { at_least, below, is };

pub const Condition = struct {
    quantity: Quantity,
    /// For `.param`.
    param: u64 = 0,
    compare: Compare,
    value: f32,
};

pub const State = struct {
    /// `clipName` of what the record calls it.
    name: u64,
    clip: u64,
    /// The channel's speed, or the factor a `speed_param` is multiplied by.
    speed: f32 = 1,
    /// When set, the rate is the parameter over the clip's `motion_speed`, so the feet match a body
    /// moved by other means. Negative plays backward.
    speed_param: u64 = 0,
    /// When set, the state seeks its clip to the parameter's fraction instead of running it.
    seek_param: u64 = 0,
    label: []const u8 = "",
};

pub const Transition = struct {
    /// A state's name, or `any_state`.
    from: u64,
    to: u64,
    fade: f32 = 0,
    phase: Phase = .restart,
    conditions: []const Condition = &.{},
};

pub const MachineLayer = struct {
    spec: Spec = .{},
    /// The parameter the layer's target weight follows, clamped to [0, 1]; zero is a weight of 1.
    /// Never on the base.
    weight_param: u64 = 0,
    entry: u64,
    states: []const State,
    transitions: []const Transition = &.{},
    label: []const u8 = "",

    pub fn state(layer: MachineLayer, name: u64) ?*const State {
        for (layer.states) |*candidate| {
            if (candidate.name == name) return candidate;
        }
        return null;
    }
};

pub const Machine = struct {
    params: []const ParamDef = &.{},
    layers: []const MachineLayer,

    pub const ValidateError = stack_mod.SpecError || error{
        TooManyParams,
        UnnamedParam,
        DuplicateParam,
        InvalidParam,
        UnknownParam,
        /// A `weight_param` on the base, which is always at 1.
        WeightOnBase,
        NoStates,
        TooManyStates,
        UnnamedState,
        DuplicateState,
        NoEntry,
        UnknownClip,
        UnknownState,
        /// An additive clip on an override layer, or the other way round.
        AdditiveMismatch,
        MotionOffBase,
        InvalidSpeed,
        /// A state may run at a parameter's rate or seek to it, not both.
        SpeedAndSeek,
        /// A `speed_param` on a clip with no ground speed to divide by.
        NoMotionSpeed,
        TooManyTransitions,
        TooManyConditions,
        InvalidCondition,
    };

    /// Refuses every way an untrusted machine can be wrong for `rig`, which must have passed
    /// `Rig.validate`. A machine that passes is safe for a stack to run, whatever that stack holds.
    pub fn validate(machine: Machine, rig: Rig) ValidateError!void {
        if (machine.params.len > max_params) return error.TooManyParams;
        for (machine.params, 0..) |param, i| {
            if (param.name == 0) return error.UnnamedParam;
            if (!std.math.isFinite(param.default)) return error.InvalidParam;
            for (machine.params[0..i]) |earlier| {
                if (earlier.name == param.name) return error.DuplicateParam;
            }
        }
        var buffer: [stack_mod.max_layers]Spec = undefined;
        if (machine.layers.len > stack_mod.max_layers) return error.TooManyLayers;
        try stack_mod.validateSpecs(rig, machine.specs(&buffer));
        for (machine.layers, 0..) |layer, i| try machine.validateLayer(rig, layer, i);
    }

    fn validateLayer(machine: Machine, rig: Rig, layer: MachineLayer, at: usize) ValidateError!void {
        if (layer.weight_param != 0) {
            if (at == 0) return error.WeightOnBase;
            try machine.known(layer.weight_param);
        }
        if (layer.states.len == 0) return error.NoStates;
        if (layer.states.len > max_states) return error.TooManyStates;
        for (layer.states, 0..) |state, i| {
            if (state.name == 0) return error.UnnamedState;
            for (layer.states[0..i]) |earlier| {
                if (earlier.name == state.name) return error.DuplicateState;
            }
            const entry = rig.find(state.clip) orelse return error.UnknownClip;
            if (entry.motion and at != 0) return error.MotionOffBase;
            if (entry.additive != (layer.spec.mode == .additive)) return error.AdditiveMismatch;
            if (!std.math.isFinite(state.speed) or @abs(state.speed) > player_mod.max_speed) return error.InvalidSpeed;
            if (state.speed_param != 0 and state.seek_param != 0) return error.SpeedAndSeek;
            if (state.speed_param != 0) {
                try machine.known(state.speed_param);
                if (!(rig.motionSpeed(state.clip) > 0)) return error.NoMotionSpeed;
            }
            if (state.seek_param != 0) try machine.known(state.seek_param);
        }
        if (layer.state(layer.entry) == null) return error.NoEntry;
        if (layer.transitions.len > max_transitions) return error.TooManyTransitions;
        for (layer.transitions) |transition| {
            if (transition.from != any_state and layer.state(transition.from) == null) return error.UnknownState;
            if (layer.state(transition.to) == null) return error.UnknownState;
            if (!std.math.isFinite(transition.fade) or transition.fade < 0) return error.InvalidFade;
            if (transition.conditions.len > max_conditions) return error.TooManyConditions;
            for (transition.conditions) |condition| {
                if (!std.math.isFinite(condition.value)) return error.InvalidCondition;
                if (condition.quantity == .param) try machine.known(condition.param);
            }
        }
    }

    fn known(machine: Machine, name: u64) ValidateError!void {
        if (machine.index(name) == null) return error.UnknownParam;
    }

    /// Where `name` is in `params`, which is where a stack keeps it once the machine has run.
    pub fn index(machine: Machine, name: u64) ?usize {
        if (name == 0) return null;
        for (machine.params, 0..) |param, i| {
            if (param.name == name) return i;
        }
        return null;
    }

    /// Each layer's spec, as `Stack.advance` and `Stack.evaluate` take them.
    pub fn specs(machine: Machine, out: *[stack_mod.max_layers]Spec) []const Spec {
        const count = @min(machine.layers.len, stack_mod.max_layers);
        for (machine.layers[0..count], 0..) |layer, i| out[i] = layer.spec;
        return out[0..count];
    }
};

pub const SetError = error{ UnknownParam, InvalidParam };

/// Sets a parameter for the next tick. A name the machine lacks, or a value that is not finite, is
/// refused and changes nothing.
pub fn set(stack: *Stack, machine: Machine, name: u64, to: f32) SetError!void {
    if (machine.index(name) == null) return error.UnknownParam;
    if (!std.math.isFinite(to)) return error.InvalidParam;
    for (&stack.params) |*param| {
        if (param.name == name) {
            param.value = to;
            return;
        }
    }
    for (&stack.params) |*param| {
        if (param.name == 0) {
            param.* = .{ .name = name, .value = to };
            return;
        }
    }
    // Every slot holds a name the machine lacks: put the machine's in order, dropping them, then
    // set. `step` sees nothing dropped, since nothing was left to drop.
    var ignored: Step = .{};
    adopt(stack, machine, &ignored);
    stack.params[machine.index(name).?].value = to;
}

/// A parameter's value as the next tick will see it: what was set or saved, or its default.
pub fn get(stack: *const Stack, machine: Machine, name: u64) ?f32 {
    const i = machine.index(name) orelse return null;
    for (stack.params) |param| {
        if (param.name == name and std.math.isFinite(param.value)) return param.value;
    }
    return machine.params[i].default;
}

/// One tick of a stack through its machine: §7's order, a layer at a time. `step` gets what
/// `Stack.advance` would give it, and the machine's own counts.
pub fn advance(stack: *Stack, rig: Rig, machine: Machine, dt: f32, step: *Step) void {
    step.* = .{};
    adopt(stack, machine, step);
    var buffer: [stack_mod.max_layers]Spec = undefined;
    const specs = machine.specs(&buffer);
    for (machine.layers[0..specs.len], 0..) |layer, i| {
        const seek = choose(stack, rig, machine, layer, i, dt, step);
        stack.advanceLayer(rig, specs, i, dt, seek, step);
        const own = &stack.layers[i];
        own.state_ticks +|= 1;
    }
}

/// The pose, through the machine's specs.
pub fn evaluate(stack: *const Stack, rig: Rig, machine: Machine, scratch: [2]Pose, out: Pose) void {
    var buffer: [stack_mod.max_layers]Spec = undefined;
    stack.evaluate(rig, machine.specs(&buffer), scratch, out);
}

/// Puts the stack's parameters in the machine's order, keeping each saved value by name, and
/// counts the saved names the machine no longer has.
fn adopt(stack: *Stack, machine: Machine, step: *Step) void {
    var fresh: [max_params]Param = @splat(.{});
    for (machine.params, 0..) |def, i| {
        fresh[i] = .{ .name = def.name, .value = def.default };
        for (stack.params) |saved| {
            if (saved.name == def.name and std.math.isFinite(saved.value)) fresh[i].value = saved.value;
        }
    }
    for (stack.params) |saved| {
        if (saved.name != 0 and machine.index(saved.name) == null) step.params_dropped +|= 1;
    }
    stack.params = fresh;
}

fn value(stack: *const Stack, machine: Machine, name: u64) f32 {
    // `adopt` put every parameter where `index` says.
    return stack.params[machine.index(name).?].value;
}

/// Steps 1 to 3 of §7's tick for one layer: its target, a transition, its rate. Returns the
/// fraction to seek to, for a state that seeks.
fn choose(stack: *Stack, rig: Rig, machine: Machine, layer: MachineLayer, i: usize, dt: f32, step: *Step) ?f32 {
    const own = &stack.layers[i];
    if (i != 0) stack.setTarget(i, if (layer.weight_param == 0) 1 else value(stack, machine, layer.weight_param));

    if (own.state == 0) {
        adoptState(stack, rig, layer, i);
    } else if (layer.state(own.state) == null) {
        step.reentered +|= 1;
        enter(stack, rig, i, layer.state(layer.entry).?, .{});
    } else if (pick(stack, rig, machine, layer, i, dt)) |transition| {
        step.transitions +|= 1;
        enter(stack, rig, i, layer.state(transition.to).?, .{ .fade = transition.fade, .phase = transition.phase });
    }

    const state = layer.state(own.state).?;
    if (state.speed_param != 0) {
        const per = rig.motionSpeed(state.clip);
        const wanted = state.speed * value(stack, machine, state.speed_param) / per;
        const rate = std.math.clamp(wanted, -player_mod.max_speed, player_mod.max_speed);
        // `validate` made the state's clip the layer's to play, and the rate is in range.
        own.player.setSpeed(rig, if (std.math.isFinite(rate)) rate else 0) catch unreachable;
    }
    if (state.seek_param != 0) return value(stack, machine, state.seek_param);
    return null;
}

/// A layer with no state yet: the state whose clip its newest channel plays, if one does, so a save
/// from before machines carries on, and otherwise its entry, cut.
fn adoptState(stack: *Stack, rig: Rig, layer: MachineLayer, i: usize) void {
    const own = &stack.layers[i];
    const player = &own.player;
    if (player.newest < player.channels.len and Player.usableIn(rig, player.channels[player.newest]) != null) {
        const clip = player.channels[player.newest].clip;
        for (layer.states) |*state| {
            if (state.clip == clip) {
                own.state = state.name;
                own.state_ticks = 0;
                return;
            }
        }
    }
    enter(stack, rig, i, layer.state(layer.entry).?, .{});
}

const Player = player_mod.Player;

const Entry = struct { fade: f32 = 0, phase: Phase = .restart };

fn enter(stack: *Stack, rig: Rig, i: usize, state: *const State, how: Entry) void {
    const own = &stack.layers[i];
    // `validate` made every state's clip one the layer may play, its speed in range and its fade
    // valid, so nothing here is refused.
    own.player.play(rig, state.clip, .{ .fade = how.fade, .phase = how.phase, .speed = state.speed }) catch unreachable;
    own.state = state.name;
    own.state_ticks = 0;
}

/// The first `"*"` transition that holds and leads elsewhere, or else the first of the state's own.
fn pick(stack: *const Stack, rig: Rig, machine: Machine, layer: MachineLayer, i: usize, dt: f32) ?*const Transition {
    const current = stack.layers[i].state;
    for (layer.transitions) |*transition| {
        if (transition.from == any_state and transition.to != current and holds(stack, rig, machine, layer, i, dt, transition.*)) return transition;
    }
    for (layer.transitions) |*transition| {
        if (transition.from == current and holds(stack, rig, machine, layer, i, dt, transition.*)) return transition;
    }
    return null;
}

fn holds(stack: *const Stack, rig: Rig, machine: Machine, layer: MachineLayer, i: usize, dt: f32, transition: Transition) bool {
    for (transition.conditions) |condition| {
        if (!meets(stack, rig, machine, layer, i, dt, condition)) return false;
    }
    return true;
}

fn meets(stack: *const Stack, rig: Rig, machine: Machine, layer: MachineLayer, i: usize, dt: f32, condition: Condition) bool {
    const own = &stack.layers[i];
    switch (condition.quantity) {
        .param => return compare(value(stack, machine, condition.param), condition.compare, condition.value),
        .finished => {
            const state = layer.state(own.state).?;
            const done: f32 = if (own.player.playing(state.clip) and own.player.finished(rig)) 1 else 0;
            return compare(done, condition.compare, condition.value);
        },
        .laps => {
            const state = layer.state(own.state).?;
            const entry: *const RigClip = rig.find(state.clip).?;
            // In `f32`, as a game timing a side by hand would write it.
            const elapsed = @as(f32, @floatFromInt(own.state_ticks)) * dt;
            const length = condition.value * entry.clip.duration;
            return switch (condition.compare) {
                .at_least => elapsed >= length,
                .below => elapsed < length,
                .is => elapsed == length,
            };
        },
    }
}

fn compare(quantity: f32, how: Compare, against: f32) bool {
    return switch (how) {
        .at_least => quantity >= against,
        .below => quantity < against,
        .is => quantity == against,
    };
}
