//! `foundry:animation_machine`: what a figure does with its clips (`docs/design/animation-states.md`
//! §10, ADR-0072).
//!
//! ```fdt
//! foundry:animation_machine court:warden.machine {
//!     params [ { name "speed" } { name "near" } ]
//!     layers [
//!         { name "body" entry "idle"
//!           states [ { name "idle" clip "idle" } { name "walk" clip "stride" speed_param "speed" } ]
//!           transitions [
//!             { from "idle" to "walk" fade 0.25 phase "keep" when [ { param "speed" at_least 0.05 } ] }
//!             { from "walk" to "idle" fade 0.25 when [ { param "speed" below 0.05 } ] }
//!           ] }
//!         { name "arms" mask "upper" weight_param "near" weight_fade 0.3 entry "reach"
//!           states [ { name "reach" clip "reach" } ] }
//!     ]
//! }
//! ```
//!
//! **Separate from the set, and named by the figure.** A set says what a model's clips are; a
//! machine says what a figure does with them. Two figures of one model may behave differently, and a
//! machine names clips by name, so one serves any set whose clips share them.
//!
//! **A condition is a quantity and one comparison:** `{ param "speed" at_least 0.05 }`,
//! `{ quantity "laps" at_least 1.5 }` or `{ quantity "finished" is 1 }`. `quantity` defaults to
//! `"param"`, so the common case reads plainly, and a parameter named `laps` cannot be mistaken for
//! the quantity.
//!
//! **`check` is what one record can show,** and `fpack` runs it. What depends on a model (does the
//! set have this clip, this mask, a motion speed) is `rigs.zig`'s, when a machine is built against a
//! rig, since a mod may override any of them.
//!
//! **Every name here is on authors' disks** (CLAUDE.md §7).

const std = @import("std");
const anim = @import("anim");
const data = @import("data");

const Allocator = std.mem.Allocator;
const Fields = data.fpk.Fields;
const FieldType = data.FieldType;
const List = data.fpk.List;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;

pub const name = "foundry:animation_machine";

pub const max_params = anim.max_params;
pub const max_layers = anim.max_layers;
pub const max_states = anim.machine.max_states;
pub const max_transitions = anim.machine.max_transitions;
pub const max_conditions = anim.machine.max_conditions;

const param_type: FieldType = .{ .nested = &.{
    .{ .name = "name", .type = .string },
    .{ .name = "default", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
} };

const state_type: FieldType = .{ .nested = &.{
    .{ .name = "name", .type = .string },
    .{ .name = "clip", .type = .string },
    .{ .name = "speed", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
    .{ .name = "speed_param", .type = .string, .presence = .optional },
    .{ .name = "seek_param", .type = .string, .presence = .optional },
} };

const condition_type: FieldType = .{ .nested = &.{
    .{ .name = "quantity", .type = .string, .presence = .{ .default = .{ .string = "param" } } },
    .{ .name = "param", .type = .string, .presence = .optional },
    .{ .name = "at_least", .type = .f32, .presence = .optional },
    .{ .name = "below", .type = .f32, .presence = .optional },
    .{ .name = "is", .type = .f32, .presence = .optional },
} };

const transition_type: FieldType = .{ .nested = &.{
    .{ .name = "from", .type = .string },
    .{ .name = "to", .type = .string },
    .{ .name = "fade", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    .{ .name = "phase", .type = .string, .presence = .{ .default = .{ .string = "restart" } } },
    .{ .name = "when", .type = .{ .list = &condition_type }, .presence = .optional },
} };

const layer_type: FieldType = .{ .nested = &.{
    .{ .name = "name", .type = .string },
    .{ .name = "mode", .type = .string, .presence = .{ .default = .{ .string = "override" } } },
    .{ .name = "mask", .type = .string, .presence = .optional },
    .{ .name = "weight_param", .type = .string, .presence = .optional },
    .{ .name = "weight_fade", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    .{ .name = "entry", .type = .string },
    .{ .name = "states", .type = .{ .list = &state_type } },
    .{ .name = "transitions", .type = .{ .list = &transition_type }, .presence = .optional },
} };

pub const schema: Schema = .{
    .id = SchemaId.fromStringUnchecked(name),
    .version = 1,
    .fields = &.{
        .{ .name = "params", .type = .{ .list = &param_type }, .presence = .optional },
        .{ .name = "layers", .type = .{ .list = &layer_type } },
    },
};

pub fn registerAll(allocator: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    _ = try registry.register(allocator, schema);
}

pub const Refusal = error{
    EmptyName,
    TooManyParams,
    DuplicateParam,
    InvalidValue,
    NoLayers,
    TooManyLayers,
    UnknownMode,
    MaskOnBase,
    WeightOnBase,
    AdditiveBase,
    UnknownParam,
    InvalidFade,
    NoStates,
    TooManyStates,
    DuplicateState,
    NoEntry,
    InvalidSpeed,
    SpeedAndSeek,
    TooManyTransitions,
    UnknownState,
    UnknownPhase,
    TooManyConditions,
    UnknownQuantity,
    /// A `"param"` condition with no `param`, or another with one.
    MisplacedParam,
    /// Not exactly one of `at_least`, `below` and `is`.
    NoComparison,
};

pub const DecodeError = Refusal || data.fpk.ReadError;

/// What a diagnostic says, after the record's name.
pub fn describe(err: DecodeError) []const u8 {
    return switch (err) {
        error.EmptyName => "has an empty name, clip, state, mask or parameter",
        error.TooManyParams => "has more parameters than a machine may hold, 8",
        error.DuplicateParam => "names one parameter twice",
        error.InvalidValue => "has a default, speed or comparison that is not a finite number",
        error.NoLayers => "has no layers",
        error.TooManyLayers => "has more layers than a machine may hold, 3",
        error.UnknownMode => "has a layer whose mode is not \"override\" or \"additive\"",
        error.MaskOnBase => "puts a mask on its first layer, which is the whole body",
        error.WeightOnBase => "gives its first layer a weight_param; the base is always at full weight",
        error.AdditiveBase => "makes its first layer additive; the base is an override",
        error.UnknownParam => "names a parameter it does not declare",
        error.InvalidFade => "has a fade that is not 0 or more",
        error.NoStates => "has a layer with no states",
        error.TooManyStates => "has a layer with more than 32 states",
        error.DuplicateState => "names one state twice in a layer",
        error.NoEntry => "has a layer whose entry is not one of its states",
        error.InvalidSpeed => "has a state whose speed is not from -16 to 16",
        error.SpeedAndSeek => "has a state with both a speed_param and a seek_param",
        error.TooManyTransitions => "has a layer with more than 64 transitions",
        error.UnknownState => "has a transition from or to a state its layer does not have",
        error.UnknownPhase => "has a transition whose phase is not \"restart\" or \"keep\"",
        error.TooManyConditions => "has a transition with more than 4 conditions",
        error.UnknownQuantity => "has a condition whose quantity is not \"param\", \"laps\" or \"finished\"",
        error.MisplacedParam => "has a condition on a parameter with no param named, or a param on laps or finished",
        error.NoComparison => "has a condition without exactly one of at_least, below and is",
        else => "is malformed",
    };
}

// ---------------------------------------------------------------------------------------------
// Reading

fn indexOf(fields: Fields, field: []const u8) ?u32 {
    for (fields.fields, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate.name, field)) return @intCast(i);
    }
    return null;
}

fn optionalString(fields: Fields, field: []const u8) DecodeError!?[]const u8 {
    const value = (try fields.stringAt(indexOf(fields, field) orelse return null)) orelse return null;
    if (value.len == 0) return error.EmptyName;
    return value;
}

fn string(fields: Fields, field: []const u8) DecodeError![]const u8 {
    return (try optionalString(fields, field)) orelse error.EmptyName;
}

fn float(fields: Fields, field: []const u8, default: f32) DecodeError!f32 {
    const at = indexOf(fields, field) orelse return default;
    const value: f32 = @floatCast((try fields.floatAt(at)) orelse return default);
    if (!std.math.isFinite(value)) return error.InvalidValue;
    return value;
}

fn optionalFloat(fields: Fields, field: []const u8) DecodeError!?f32 {
    const at = indexOf(fields, field) orelse return null;
    const value: f32 = @floatCast((try fields.floatAt(at)) orelse return null);
    if (!std.math.isFinite(value)) return error.InvalidValue;
    return value;
}

fn list(fields: Fields, field: []const u8) DecodeError!?List {
    return fields.listAt(indexOf(fields, field) orelse return null);
}

fn item(l: List, index: usize) DecodeError!Fields {
    return (try l.nestedAt(@intCast(index))) orelse error.EmptyName;
}

pub const Param = struct { name: []const u8, default: f32 };

pub const State = struct {
    name: []const u8,
    clip: []const u8,
    speed: f32,
    speed_param: ?[]const u8,
    seek_param: ?[]const u8,
};

pub const Condition = struct {
    quantity: anim.machine.Quantity,
    param: ?[]const u8,
    compare: anim.machine.Compare,
    value: f32,
};

pub const Transition = struct {
    /// Null for `"*"`.
    from: ?[]const u8,
    to: []const u8,
    fade: f32,
    phase: anim.Phase,
    when: ?List,
};

pub const Layer = struct {
    name: []const u8,
    mode: anim.LayerMode,
    mask: ?[]const u8,
    weight_param: ?[]const u8,
    weight_fade: f32,
    entry: []const u8,
    states: List,
    transitions: ?List,
};

pub fn params(fields: Fields) DecodeError!?List {
    return list(fields, "params");
}

pub fn paramAt(l: List, index: usize) DecodeError!Param {
    const fields = try item(l, index);
    return .{ .name = try string(fields, "name"), .default = try float(fields, "default", 0) };
}

pub fn layers(fields: Fields) DecodeError!List {
    return (try list(fields, "layers")) orelse error.NoLayers;
}

pub fn layerAt(l: List, index: usize) DecodeError!Layer {
    const fields = try item(l, index);
    const mode_name = (try optionalString(fields, "mode")) orelse "override";
    const mode: anim.LayerMode = if (std.mem.eql(u8, mode_name, "override"))
        .override
    else if (std.mem.eql(u8, mode_name, "additive"))
        .additive
    else
        return error.UnknownMode;
    return .{
        .name = try string(fields, "name"),
        .mode = mode,
        .mask = try optionalString(fields, "mask"),
        .weight_param = try optionalString(fields, "weight_param"),
        .weight_fade = try float(fields, "weight_fade", 0),
        .entry = try string(fields, "entry"),
        .states = (try list(fields, "states")) orelse return error.NoStates,
        .transitions = try list(fields, "transitions"),
    };
}

pub fn stateAt(l: List, index: usize) DecodeError!State {
    const fields = try item(l, index);
    return .{
        .name = try string(fields, "name"),
        .clip = try string(fields, "clip"),
        .speed = try float(fields, "speed", 1),
        .speed_param = try optionalString(fields, "speed_param"),
        .seek_param = try optionalString(fields, "seek_param"),
    };
}

pub fn transitionAt(l: List, index: usize) DecodeError!Transition {
    const fields = try item(l, index);
    const from = try string(fields, "from");
    const phase_name = (try optionalString(fields, "phase")) orelse "restart";
    const phase: anim.Phase = if (std.mem.eql(u8, phase_name, "restart"))
        .restart
    else if (std.mem.eql(u8, phase_name, "keep"))
        .keep
    else
        return error.UnknownPhase;
    return .{
        .from = if (std.mem.eql(u8, from, "*")) null else from,
        .to = try string(fields, "to"),
        .fade = try float(fields, "fade", 0),
        .phase = phase,
        .when = try list(fields, "when"),
    };
}

pub fn conditionAt(l: List, index: usize) DecodeError!Condition {
    const fields = try item(l, index);
    const quantity_name = (try optionalString(fields, "quantity")) orelse "param";
    const quantity: anim.machine.Quantity = if (std.mem.eql(u8, quantity_name, "param"))
        .param
    else if (std.mem.eql(u8, quantity_name, "laps"))
        .laps
    else if (std.mem.eql(u8, quantity_name, "finished"))
        .finished
    else
        return error.UnknownQuantity;
    const param = try optionalString(fields, "param");
    if ((quantity == .param) != (param != null)) return error.MisplacedParam;
    const at_least = try optionalFloat(fields, "at_least");
    const below = try optionalFloat(fields, "below");
    const is = try optionalFloat(fields, "is");
    const given = @as(u8, @intFromBool(at_least != null)) + @intFromBool(below != null) + @intFromBool(is != null);
    if (given != 1) return error.NoComparison;
    return .{
        .quantity = quantity,
        .param = param,
        .compare = if (at_least != null) .at_least else if (below != null) .below else .is,
        .value = at_least orelse below orelse is.?,
    };
}

// ---------------------------------------------------------------------------------------------
// Checking

/// Everything one record can show. It allocates nothing, so a package's compile can run it.
pub fn check(fields: Fields) DecodeError!void {
    const param_list = try params(fields);
    if (param_list) |l| {
        if (l.len > max_params) return error.TooManyParams;
        for (0..l.len) |i| {
            const param = try paramAt(l, i);
            for (0..i) |earlier| {
                if (std.mem.eql(u8, (try paramAt(l, earlier)).name, param.name)) return error.DuplicateParam;
            }
        }
    }
    const layer_list = try layers(fields);
    if (layer_list.len == 0) return error.NoLayers;
    if (layer_list.len > max_layers) return error.TooManyLayers;
    for (0..layer_list.len) |i| try checkLayer(param_list, try layerAt(layer_list, i), i);
}

fn checkLayer(param_list: ?List, layer: Layer, index: usize) DecodeError!void {
    if (index == 0) {
        if (layer.mask != null) return error.MaskOnBase;
        if (layer.weight_param != null) return error.WeightOnBase;
        if (layer.mode != .override) return error.AdditiveBase;
    }
    if (layer.weight_param) |param| try known(param_list, param);
    if (layer.weight_fade < 0) return error.InvalidFade;
    if (layer.states.len == 0) return error.NoStates;
    if (layer.states.len > max_states) return error.TooManyStates;
    for (0..layer.states.len) |i| {
        const state = try stateAt(layer.states, i);
        for (0..i) |earlier| {
            if (std.mem.eql(u8, (try stateAt(layer.states, earlier)).name, state.name)) return error.DuplicateState;
        }
        if (@abs(state.speed) > anim.max_speed) return error.InvalidSpeed;
        if (state.speed_param != null and state.seek_param != null) return error.SpeedAndSeek;
        if (state.speed_param) |param| try known(param_list, param);
        if (state.seek_param) |param| try known(param_list, param);
    }
    if (!try hasState(layer.states, layer.entry)) return error.NoEntry;
    const transitions = layer.transitions orelse return;
    if (transitions.len > max_transitions) return error.TooManyTransitions;
    for (0..transitions.len) |i| {
        const transition = try transitionAt(transitions, i);
        if (transition.from) |from| {
            if (!try hasState(layer.states, from)) return error.UnknownState;
        }
        if (!try hasState(layer.states, transition.to)) return error.UnknownState;
        if (transition.fade < 0) return error.InvalidFade;
        const when = transition.when orelse continue;
        if (when.len > max_conditions) return error.TooManyConditions;
        for (0..when.len) |c| {
            const condition = try conditionAt(when, c);
            if (condition.param) |param| try known(param_list, param);
        }
    }
}

fn known(param_list: ?List, param: []const u8) DecodeError!void {
    const l = param_list orelse return error.UnknownParam;
    for (0..l.len) |i| {
        if (std.mem.eql(u8, (try paramAt(l, i)).name, param)) return;
    }
    return error.UnknownParam;
}

fn hasState(states: List, state: []const u8) DecodeError!bool {
    for (0..states.len) |i| {
        if (std.mem.eql(u8, (try stateAt(states, i)).name, state)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Building

/// What `decode` allocates, all of it in one arena the caller owns: the machine borrows from it.
pub fn decode(arena: Allocator, fields: Fields) (DecodeError || Allocator.Error)!anim.Machine {
    try check(fields);
    const param_list = try params(fields);
    const out_params = try arena.alloc(anim.ParamDef, if (param_list) |l| l.len else 0);
    for (out_params, 0..) |*out, i| {
        const param = try paramAt(param_list.?, i);
        out.* = .{ .name = anim.clipName(param.name), .default = param.default, .label = try arena.dupe(u8, param.name) };
    }
    const layer_list = try layers(fields);
    const out_layers = try arena.alloc(anim.MachineLayer, layer_list.len);
    for (out_layers, 0..) |*out, i| {
        const layer = try layerAt(layer_list, i);
        const states = try arena.alloc(anim.MachineState, layer.states.len);
        for (states, 0..) |*state_out, s| {
            const state = try stateAt(layer.states, s);
            state_out.* = .{
                .name = anim.clipName(state.name),
                .clip = anim.clipName(state.clip),
                .speed = state.speed,
                .speed_param = hashOf(state.speed_param),
                .seek_param = hashOf(state.seek_param),
                .label = try arena.dupe(u8, state.name),
            };
        }
        const transition_count = if (layer.transitions) |l| l.len else 0;
        const transitions = try arena.alloc(anim.Transition, transition_count);
        for (transitions, 0..) |*transition_out, t| {
            const transition = try transitionAt(layer.transitions.?, t);
            const when_count = if (transition.when) |l| l.len else 0;
            const conditions = try arena.alloc(anim.Condition, when_count);
            for (conditions, 0..) |*condition_out, c| {
                const condition = try conditionAt(transition.when.?, c);
                condition_out.* = .{ .quantity = condition.quantity, .param = hashOf(condition.param), .compare = condition.compare, .value = condition.value };
            }
            transition_out.* = .{
                .from = if (transition.from) |from| anim.clipName(from) else anim.machine.any_state,
                .to = anim.clipName(transition.to),
                .fade = transition.fade,
                .phase = transition.phase,
                .conditions = conditions,
            };
        }
        out.* = .{
            .spec = .{ .mode = layer.mode, .mask = hashOf(layer.mask), .fade = layer.weight_fade },
            .weight_param = hashOf(layer.weight_param),
            .entry = anim.clipName(layer.entry),
            .states = states,
            .transitions = transitions,
            .label = try arena.dupe(u8, layer.name),
        };
    }
    return .{ .params = out_params, .layers = out_layers };
}

fn hashOf(text: ?[]const u8) u64 {
    return if (text) |t| anim.clipName(t) else 0;
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;
const gpa = testing.allocator;
const ContentId = @import("core").ContentId;

const Compiled = struct {
    registry: Registry,
    package: data.Package,
    diags: data.Diagnostics,
    bytes: std.ArrayList(u8) = .empty,
    store: data.Store,

    fn init(self: *Compiled, source: []const u8) !void {
        self.* = .{
            .registry = .init(gpa, .default),
            .package = try data.Package.init(gpa, "t:content", 1, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
        };
        try registerAll(gpa, &self.registry);
        var doc = try data.parser.parse(gpa, "t.fdt", source, .{ .namespace = "t" }, &self.diags);
        defer doc.deinit(gpa);
        try self.package.addDocument(gpa, &doc, &self.registry, &self.diags);
        try data.fpk.write(gpa, &self.package, &self.registry, &self.bytes);
        _ = try self.store.add(gpa, "t.fpk", self.bytes.items, &self.registry, &self.diags);
    }

    fn deinit(self: *Compiled) void {
        self.store.deinit(gpa);
        self.bytes.deinit(gpa);
        self.diags.deinit(gpa);
        self.package.deinit(gpa);
        self.registry.deinit(gpa);
    }

    fn fields(self: *Compiled) Fields {
        return self.store.lookup(ContentId.fromString("t:machine")).?.fields;
    }
};

const warden_text =
    \\foundry:animation_machine t:machine {
    \\    params [ { name "speed" } { name "link" } { name "link_t" } { name "near" default 0.5 } ]
    \\    layers [
    \\        { name "body" entry "idle"
    \\          states [
    \\            { name "idle" clip "idle" }
    \\            { name "walk" clip "stride" speed_param "speed" }
    \\            { name "jump" clip "jump" seek_param "link_t" speed 0.5 }
    \\          ]
    \\          transitions [
    \\            { from "*" to "jump" fade 0.1 when [ { param "link" is 1 } ] }
    \\            { from "idle" to "walk" fade 0.25 phase "keep" when [ { param "speed" at_least 0.05 } { quantity "laps" below 3 } ] }
    \\            { from "walk" to "idle" when [ { quantity "finished" is 1 } ] }
    \\          ] }
    \\        { name "arms" mask "upper" weight_param "near" weight_fade 0.3 entry "reach"
    \\          states [ { name "reach" clip "reach" } ] }
    \\        { name "breath" mode "additive" entry "pant" states [ { name "pant" clip "pant" } ] }
    \\    ]
    \\}
;

test "a machine reads into an anim.Machine, every name hashed and every default in place" {
    var c: Compiled = undefined;
    try c.init(warden_text);
    defer c.deinit();
    try check(c.fields());
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const machine = try decode(arena.allocator(), c.fields());
    try testing.expectEqual(@as(usize, 4), machine.params.len);
    try testing.expectEqual(anim.clipName("near"), machine.params[3].name);
    try testing.expectEqual(@as(f32, 0.5), machine.params[3].default);
    try testing.expectEqualStrings("near", machine.params[3].label);
    try testing.expectEqual(@as(usize, 3), machine.layers.len);

    const body = machine.layers[0];
    try testing.expectEqualStrings("body", body.label);
    try testing.expectEqual(anim.clipName("idle"), body.entry);
    try testing.expectEqual(anim.LayerMode.override, body.spec.mode);
    try testing.expectEqual(anim.clipName("stride"), body.states[1].clip);
    try testing.expectEqual(anim.clipName("speed"), body.states[1].speed_param);
    try testing.expectEqual(@as(f32, 1), body.states[1].speed);
    try testing.expectEqual(@as(f32, 0.5), body.states[2].speed);
    try testing.expectEqual(anim.clipName("link_t"), body.states[2].seek_param);
    try testing.expectEqual(anim.machine.any_state, body.transitions[0].from);
    try testing.expectEqual(anim.Phase.restart, body.transitions[0].phase);
    const walk = body.transitions[1];
    try testing.expectEqual(anim.Phase.keep, walk.phase);
    try testing.expectEqual(@as(f32, 0.25), walk.fade);
    try testing.expectEqual(anim.machine.Compare.at_least, walk.conditions[0].compare);
    try testing.expectEqual(anim.machine.Quantity.laps, walk.conditions[1].quantity);
    try testing.expectEqual(anim.machine.Compare.below, walk.conditions[1].compare);
    try testing.expectEqual(@as(u64, 0), walk.conditions[1].param);
    try testing.expectEqual(anim.machine.Quantity.finished, body.transitions[2].conditions[0].quantity);
    try testing.expectEqual(@as(f32, 0), body.transitions[2].fade);

    const arms = machine.layers[1];
    try testing.expectEqual(anim.clipName("upper"), arms.spec.mask);
    try testing.expectEqual(@as(f32, 0.3), arms.spec.fade);
    try testing.expectEqual(anim.clipName("near"), arms.weight_param);
    try testing.expectEqual(anim.LayerMode.additive, machine.layers[2].spec.mode);
    try testing.expectEqual(@as(u64, 0), machine.layers[2].weight_param);
}

fn expectRefused(expected: DecodeError, source: []const u8) !void {
    var c: Compiled = undefined;
    try c.init(source);
    defer c.deinit();
    try testing.expectError(expected, check(c.fields()));
    try testing.expect(!std.mem.eql(u8, describe(expected), "is malformed"));
}

test "every refusal one record can show is named" {
    const head = "foundry:animation_machine t:machine { ";
    const one = "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] } ] }";
    const p = "params [ { name \"p\" } ] ";
    const cases = [_]struct { DecodeError, []const u8 }{
        .{ error.EmptyName, "params [ { name \"\" } ] " ++ one },
        .{ error.DuplicateParam, "params [ { name \"p\" } { name \"p\" } ] " ++ one },
        .{ error.NoLayers, "layers [ ] }" },
        .{ error.UnknownMode, "layers [ { name \"b\" mode \"blend\" entry \"s\" states [ { name \"s\" clip \"c\" } ] } ] }" },
        .{ error.AdditiveBase, "layers [ { name \"b\" mode \"additive\" entry \"s\" states [ { name \"s\" clip \"c\" } ] } ] }" },
        .{ error.MaskOnBase, "layers [ { name \"b\" mask \"m\" entry \"s\" states [ { name \"s\" clip \"c\" } ] } ] }" },
        .{ error.WeightOnBase, p ++ "layers [ { name \"b\" weight_param \"p\" entry \"s\" states [ { name \"s\" clip \"c\" } ] } ] }" },
        .{ error.UnknownParam, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] } { name \"u\" weight_param \"q\" entry \"s\" states [ { name \"s\" clip \"c\" } ] } ] }" },
        .{ error.InvalidFade, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] } { name \"u\" weight_fade -1 entry \"s\" states [ { name \"s\" clip \"c\" } ] } ] }" },
        .{ error.NoStates, "layers [ { name \"b\" entry \"s\" states [ ] } ] }" },
        .{ error.DuplicateState, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } { name \"s\" clip \"d\" } ] } ] }" },
        .{ error.NoEntry, "layers [ { name \"b\" entry \"t\" states [ { name \"s\" clip \"c\" } ] } ] }" },
        .{ error.EmptyName, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"\" } ] } ] }" },
        .{ error.InvalidSpeed, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" speed 17 } ] } ] }" },
        .{ error.SpeedAndSeek, p ++ "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" speed_param \"p\" seek_param \"p\" } ] } ] }" },
        .{ error.UnknownParam, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" speed_param \"p\" } ] } ] }" },
        .{ error.UnknownParam, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" seek_param \"p\" } ] } ] }" },
        .{ error.UnknownState, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"t\" to \"s\" } ] } ] }" },
        .{ error.UnknownState, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"*\" to \"t\" } ] } ] }" },
        .{ error.InvalidFade, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"s\" to \"s\" fade -0.1 } ] } ] }" },
        .{ error.UnknownPhase, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"s\" to \"s\" phase \"sync\" } ] } ] }" },
        .{ error.UnknownQuantity, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"s\" to \"s\" when [ { quantity \"time\" is 1 } ] } ] } ] }" },
        .{ error.MisplacedParam, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"s\" to \"s\" when [ { is 1 } ] } ] } ] }" },
        .{ error.MisplacedParam, p ++ "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"s\" to \"s\" when [ { quantity \"laps\" param \"p\" is 1 } ] } ] } ] }" },
        .{ error.NoComparison, p ++ "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"s\" to \"s\" when [ { param \"p\" } ] } ] } ] }" },
        .{ error.NoComparison, p ++ "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"s\" to \"s\" when [ { param \"p\" is 1 below 2 } ] } ] } ] }" },
        .{ error.UnknownParam, "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"s\" to \"s\" when [ { param \"p\" is 1 } ] } ] } ] }" },
    };
    inline for (cases) |case| try expectRefused(case[0], head ++ case[1]);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, head ++ "params [");
    for (0..max_params + 1) |i| try text.print(gpa, " {{ name \"p{d}\" }}", .{i});
    try text.appendSlice(gpa, " ] " ++ one);
    try expectRefused(error.TooManyParams, text.items);

    text.clearRetainingCapacity();
    try text.appendSlice(gpa, head ++ "layers [");
    for (0..max_layers + 1) |_| try text.appendSlice(gpa, " { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] }");
    try text.appendSlice(gpa, " ] }");
    try expectRefused(error.TooManyLayers, text.items);

    text.clearRetainingCapacity();
    try text.appendSlice(gpa, head ++ "layers [ { name \"b\" entry \"s0\" states [");
    for (0..max_states + 1) |i| try text.print(gpa, " {{ name \"s{d}\" clip \"c\" }}", .{i});
    try text.appendSlice(gpa, " ] } ] }");
    try expectRefused(error.TooManyStates, text.items);

    text.clearRetainingCapacity();
    try text.appendSlice(gpa, head ++ "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [");
    for (0..max_transitions + 1) |_| try text.appendSlice(gpa, " { from \"s\" to \"s\" }");
    try text.appendSlice(gpa, " ] } ] }");
    try expectRefused(error.TooManyTransitions, text.items);

    text.clearRetainingCapacity();
    try text.appendSlice(gpa, head ++ p ++ "layers [ { name \"b\" entry \"s\" states [ { name \"s\" clip \"c\" } ] transitions [ { from \"s\" to \"s\" when [");
    for (0..max_conditions + 1) |_| try text.appendSlice(gpa, " { param \"p\" is 1 }");
    try text.appendSlice(gpa, " ] } ] } ] }");
    try expectRefused(error.TooManyConditions, text.items);
}
