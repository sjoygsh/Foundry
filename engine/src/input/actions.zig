//! `Actions`: what each action reads this frame (`docs/design/input.md` §7).
//!
//! `evaluate(snapshot, options)` is a pure function of the map, the enabled contexts, the
//! previous frame's held states and the snapshot. It answers a `Frame`, one `ActionState` per
//! action in the map's content-ID order (I9's documented order).
//!
//! **Contexts.** A game enables at most eight. They are read from the highest priority down,
//! ties by content ID ascending. An action is evaluated in the first enabled context it belongs
//! to; an action in no enabled context reads as rest, with a release edge if it was held. A
//! context that `blocks` hides every source its actions bind from every lower context, whether
//! pressed or not, compared by physical input (`source.Physical`).
//!
//! **A button's edges are the action's own.** It is held while any binding holds it. It is
//! pressed when it goes from not held to held, or when a source was pressed and released
//! within the frame, so a tap is never lost (the snapshot's own rule, kept). While one
//! binding holds it steadily across the frame, another binding's press or release is not an
//! edge of the action: two keys on Jump do not jump twice. A release is never reported
//! without a press or an earlier held frame to end. A pad axis holds a button from its
//! `threshold` in the direction of its `scale`'s sign, compared with `>=` on the axis's raw
//! value; the deadzone is not applied first.
//!
//! **Axes, vectors and deltas** are levels. Each binding contributes its value times `scale`:
//! a button 1 while held, a pad axis its value past the deadzone rescaled to start from 0, a
//! stick its value past a radial deadzone rescaled the same way. An axis is clamped to
//! [-1, 1] and a vector to length 1, so a keyboard diagonal is no faster than a stick. A delta
//! is the frame's motion or wheel times `scale`, unclamped. Each is held while nonzero, and its
//! edges follow `held`. A wheel direction is a tap, held in no frame, so it feeds a button and
//! never moves an axis.
//!
//! **Devices.** `Options.devices` selects the keyboard, the mouse and pad slots; a pad source
//! reads every selected, connected slot, a button held on any, an axis from the slot whose
//! value is largest in magnitude (ties to the lowest slot). `Options.blocked` hides the
//! keyboard or the pointer from every action, the `ui_wants_keyboard` case.
//!
//! The only float operations are adds, multiplies, divisions, comparisons and square roots,
//! with no fast-math, so the same inputs give the same frame (I9, ADR-0013).

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const map_mod = @import("map.zig");
const schemas = @import("schemas.zig");
const source_mod = @import("source.zig");

const ContentId = core.ContentId;
const Vec2 = core.math.Vec2;
const InputSnapshot = platform.InputSnapshot;
const Map = map_mod.Map;
const Action = map_mod.Action;
const Binding = schemas.Binding;
const Kind = schemas.Kind;
const Source = source_mod.Source;
const Physical = source_mod.Physical;

pub const max_actions = map_mod.max_actions;
/// The most contexts a game may enable at once (§7).
pub const max_enabled: usize = 8;

/// One action's value this frame.
pub const ActionState = struct {
    held: bool = false,
    pressed: bool = false,
    released: bool = false,
    /// A button's is (1, 0) while held; an axis's is in `x`; a vector's and a delta's are both.
    value: Vec2 = .zero,

    pub const rest: ActionState = .{};
};

/// Every action's state, in the map's content-ID order, found by ID with a sorted search.
pub const Frame = struct {
    count: u16 = 0,
    ids: [max_actions]ContentId = undefined,
    kinds: [max_actions]Kind = undefined,
    states: [max_actions]ActionState = undefined,

    pub const empty: Frame = .{};

    /// The action's index, or null for an ID the map does not hold.
    pub fn find(self: *const Frame, id: ContentId) ?u16 {
        var lo: usize = 0;
        var hi: usize = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = self.ids[mid].hash;
            if (at == id.hash) return @intCast(mid);
            if (at < id.hash) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// The action's state, or rest for one the map does not hold.
    pub fn state(self: *const Frame, id: ContentId) ActionState {
        return self.states[self.find(id) orelse return .rest];
    }

    pub fn slice(self: *const Frame) []const ActionState {
        return self.states[0..self.count];
    }
};

/// Which devices an `Actions` reads. Two over one snapshot with different devices are two
/// local players.
pub const Devices = struct {
    keyboard: bool = true,
    mouse: bool = true,
    /// One bit per pad slot, slot 0 lowest.
    pads: u4 = 0b1111,

    pub const all: Devices = .{};
};

/// Devices hidden from every action this frame, whatever their selection.
pub const Blocked = struct {
    keyboard: bool = false,
    /// The mouse: its buttons, its motion and its wheel.
    pointer: bool = false,
};

pub const Options = struct {
    devices: Devices = .{},
    blocked: Blocked = .{},
};

pub const EnableError = error{
    /// Eight contexts are enabled already.
    TooManyEnabled,
};

/// What evaluation keeps from one frame for the next, per action.
const Memory = struct {
    held: bool = false,
    /// One bit per binding: a pad axis feeding a button was past its threshold.
    past: u8 = 0,
    /// Whether `past` describes the action's current bindings. A new map may have moved them,
    /// so the first evaluation after one takes each axis's side of its threshold as it finds it:
    /// a trigger held through a rebinding is held, not pressed again.
    known: bool = true,
};

pub const Actions = struct {
    /// Borrowed; the caller keeps it alive and calls `setMap` when it changes.
    map: *const Map,
    enabled_buffer: [max_enabled]ContentId = undefined,
    enabled_count: u8 = 0,
    memory: [max_actions]Memory = @splat(.{}),
    /// Per context in the map: the physical inputs its actions bind, which it hides when it blocks.
    bound: [map_mod.max_contexts]Physical = @splat(source_mod.no_physical),
    frame: Frame = .empty,

    pub fn init(map: *const Map) Actions {
        var self: Actions = .{ .map = map };
        self.computeBound();
        self.frame.count = @intCast(map.actions.len);
        for (map.actions, 0..) |a, i| {
            self.frame.ids[i] = a.id;
            self.frame.kinds[i] = a.kind;
            self.frame.states[i] = .rest;
        }
        return self;
    }

    /// Replaces the map, after a reload or a rebinding. An action that survives, by content ID,
    /// keeps its held state, so a change of map never invents a press or loses a release.
    pub fn setMap(self: *Actions, map: *const Map) void {
        var memory: [max_actions]Memory = @splat(.{});
        var states: [max_actions]ActionState = undefined;
        for (map.actions, 0..) |a, i| {
            states[i] = .rest;
            if (self.frame.find(a.id)) |old| {
                memory[i] = .{ .held = self.memory[old].held, .known = false };
                states[i] = self.frame.states[old];
            }
        }
        self.map = map;
        self.memory = memory;
        self.computeBound();
        self.frame.count = @intCast(map.actions.len);
        for (map.actions, 0..) |a, i| {
            self.frame.ids[i] = a.id;
            self.frame.kinds[i] = a.kind;
            self.frame.states[i] = states[i];
        }
    }

    fn computeBound(self: *Actions) void {
        self.bound = @splat(source_mod.no_physical);
        for (self.map.actions) |*a| {
            var set = source_mod.no_physical;
            for (a.bindings()) |b| source_mod.markPhysical(&set, b.source);
            for (a.contexts()) |c| self.bound[c].setUnion(set);
        }
    }

    /// Enables a context by content ID. Idempotent. An ID the map does not hold is kept and
    /// matches nothing, so a game's state survives a reload whose content briefly lacks it.
    pub fn enable(self: *Actions, id: ContentId) EnableError!void {
        if (self.isEnabled(id)) return;
        if (self.enabled_count == max_enabled) return error.TooManyEnabled;
        self.enabled_buffer[self.enabled_count] = id;
        self.enabled_count += 1;
    }

    pub fn disable(self: *Actions, id: ContentId) void {
        for (self.enabled(), 0..) |e, i| {
            if (!e.eql(id)) continue;
            // Order among the enabled is not meaning: evaluation sorts them by priority.
            self.enabled_buffer[i] = self.enabled_buffer[self.enabled_count - 1];
            self.enabled_count -= 1;
            return;
        }
    }

    pub fn disableAll(self: *Actions) void {
        self.enabled_count = 0;
    }

    pub fn isEnabled(self: *const Actions, id: ContentId) bool {
        for (self.enabled()) |e| if (e.eql(id)) return true;
        return false;
    }

    /// The enabled contexts, in no meaningful order.
    pub fn enabled(self: *const Actions) []const ContentId {
        return self.enabled_buffer[0..self.enabled_count];
    }

    /// The last frame `evaluate` answered.
    pub fn current(self: *const Actions) *const Frame {
        return &self.frame;
    }

    /// Every action's state from `snapshot`. The answer is borrowed until the next call.
    pub fn evaluate(self: *Actions, snapshot: *const InputSnapshot, options: Options) *const Frame {
        const map = self.map;

        // The enabled contexts the map holds, in reading order.
        var order: [max_enabled]u8 = undefined;
        var n: usize = 0;
        for (self.enabled()) |id| {
            const index = map.findContext(id) orelse continue;
            order[n] = index;
            n += 1;
        }
        std.mem.sort(u8, order[0..n], map, readsBefore);

        // What each reading position may not see: the bound inputs of every blocking context
        // read before it.
        var hidden: [max_enabled]Physical = undefined;
        var acc = source_mod.no_physical;
        for (order[0..n], 0..) |c, k| {
            hidden[k] = acc;
            if (map.contexts[c].blocks) acc.setUnion(self.bound[c]);
        }

        const reader: Reader = .{ .snapshot = snapshot, .options = options };
        for (map.actions, 0..) |*a, i| {
            const memory = &self.memory[i];
            const rank = rankOf(a, order[0..n]) orelse {
                self.frame.states[i] = .{ .released = memory.held };
                memory.* = .{};
                continue;
            };
            self.frame.states[i] = evaluateAction(a, &reader, hidden[rank], memory);
        }
        return &self.frame;
    }
};

/// Reading order: higher priority first, ties by content ID ascending.
fn readsBefore(map: *const Map, a: u8, b: u8) bool {
    return map.readsFirst(a, b);
}

/// The position in `order` of the first enabled context the action belongs to.
fn rankOf(a: *const Action, order: []const u8) ?usize {
    for (order, 0..) |c, k| {
        for (a.contexts()) |mine| if (mine == c) return k;
    }
    return null;
}

const ButtonRead = struct { held: bool = false, pressed: bool = false, released: bool = false };

/// One snapshot, as the options let an action see it.
const Reader = struct {
    snapshot: *const InputSnapshot,
    options: Options,

    fn visible(self: *const Reader, source: Source, hidden: *const Physical) bool {
        if (source_mod.physicalOf(source).intersectWith(hidden.*).count() != 0) return false;
        const o = self.options;
        return switch (source) {
            .key => o.devices.keyboard and !o.blocked.keyboard,
            .mouse_button, .mouse_motion, .mouse_wheel, .wheel => o.devices.mouse and !o.blocked.pointer,
            .pad_button, .pad_axis, .pad_stick => o.devices.pads != 0,
        };
    }

    fn padSelected(self: *const Reader, slot: usize) bool {
        return self.options.devices.pads & (@as(u4, 1) << @intCast(slot)) != 0 and self.snapshot.gamepads[slot].connected;
    }

    fn button(self: *const Reader, source: Source) ButtonRead {
        const s = self.snapshot;
        return switch (source) {
            .key => |k| .{ .held = s.isHeld(k), .pressed = s.wasPressed(k), .released = s.wasReleased(k) },
            .mouse_button => |b| .{ .held = s.mouse.isHeld(b), .pressed = s.mouse.wasPressed(b), .released = s.mouse.wasReleased(b) },
            .wheel => |d| blk: {
                const turned = switch (d) {
                    .up => s.mouse.wheel.y > 0,
                    .down => s.mouse.wheel.y < 0,
                    .right => s.mouse.wheel.x > 0,
                    .left => s.mouse.wheel.x < 0,
                };
                // A tap: pressed and released in the frame it turned, held in none.
                break :blk .{ .pressed = turned, .released = turned };
            },
            .pad_button => |b| blk: {
                var out: ButtonRead = .{};
                for (0..platform.max_gamepads) |slot| {
                    if (!self.padSelected(slot)) continue;
                    const pad = s.gamepads[slot];
                    out.held = out.held or pad.isHeld(b);
                    out.pressed = out.pressed or pad.wasPressed(b);
                    out.released = out.released or pad.wasReleased(b);
                }
                break :blk out;
            },
            else => .{},
        };
    }

    /// A pad axis, from the selected slot where it is largest in magnitude, ties to the lowest.
    fn axis(self: *const Reader, a: platform.GamepadAxis) f32 {
        var best: f32 = 0;
        for (0..platform.max_gamepads) |slot| {
            if (!self.padSelected(slot)) continue;
            const v = self.snapshot.gamepads[slot].axis(a);
            if (@abs(v) > @abs(best)) best = v;
        }
        return best;
    }

    /// A stick, from the selected slot where it is pushed furthest, ties to the lowest.
    fn stick(self: *const Reader, s: source_mod.Stick) Vec2 {
        const axes = s.axes();
        var best: Vec2 = .zero;
        for (0..platform.max_gamepads) |slot| {
            if (!self.padSelected(slot)) continue;
            const pad = self.snapshot.gamepads[slot];
            const v: Vec2 = .init(pad.axis(axes[0]), pad.axis(axes[1]));
            if (v.lengthSquared() > best.lengthSquared()) best = v;
        }
        return best;
    }

    fn delta(self: *const Reader, source: Source) Vec2 {
        return switch (source) {
            .mouse_motion => self.snapshot.mouse.motion,
            .mouse_wheel => self.snapshot.mouse.wheel,
            else => .zero,
        };
    }
};

/// A one-dimensional deadzone, rescaled so the value starts from 0 at its edge.
pub fn deadzone1(v: f32, d: f32) f32 {
    const a = @abs(v);
    if (a <= d) return 0;
    const out = (a - d) / (1 - d);
    return if (v < 0) -out else out;
}

/// A radial deadzone, rescaled the same way along the stick's direction.
pub fn deadzoneRadial(v: Vec2, d: f32) Vec2 {
    const l2 = v.lengthSquared();
    if (l2 <= d * d) return .zero;
    const l = @sqrt(l2);
    return v.scale(((l - d) / (1 - d)) / l);
}

fn clampLength(v: Vec2) Vec2 {
    const l2 = v.lengthSquared();
    if (l2 <= 1) return v;
    return v.scale(1 / @sqrt(l2));
}

fn addComponent(v: *Vec2, component: schemas.Component, amount: f32) void {
    switch (component) {
        .x => v.x += amount,
        .y => v.y += amount,
    }
}

fn evaluateAction(a: *const Action, reader: *const Reader, hidden: Physical, memory: *Memory) ActionState {
    const was = memory.held;
    var out: ActionState = .{};
    switch (a.kind) {
        .button => {
            var press = false;
            var release = false;
            var steady = false;
            var past_bits: u8 = 0;
            for (a.bindings(), 0..) |b, bi| {
                if (!reader.visible(b.source, &hidden)) continue;
                switch (b.source.class()) {
                    .button => {
                        const r = reader.button(b.source);
                        out.held = out.held or r.held;
                        press = press or r.pressed;
                        release = release or r.released;
                        steady = steady or (r.held and !r.pressed and !r.released);
                    },
                    .axis => {
                        const v = reader.axis(b.source.pad_axis);
                        const signed = if (b.scale < 0) -v else v;
                        const past = signed >= b.threshold;
                        const bit = @as(u8, 1) << @intCast(bi);
                        const before = if (memory.known) memory.past & bit != 0 else past;
                        if (past) past_bits |= bit;
                        out.held = out.held or past;
                        press = press or (past and !before);
                        release = release or (!past and before);
                        steady = steady or (past and before);
                    },
                    // Refused by `Kind.accepts` when the map was built.
                    .stick, .delta => {},
                }
            }
            memory.past = past_bits;
            if (steady and was) {
                // One binding held it through the frame: nothing the others did is an edge.
            } else {
                out.pressed = press or (!was and out.held);
                out.released = (release or (was and !out.held)) and (was or out.pressed);
            }
            if (out.held) out.value = .init(1, 0);
        },
        .axis, .vector, .delta => {
            var sum: Vec2 = .zero;
            for (a.bindings()) |b| {
                if (!reader.visible(b.source, &hidden)) continue;
                switch (b.source.class()) {
                    .button => if (reader.button(b.source).held) addComponent(&sum, if (a.kind == .axis) .x else b.axis, b.scale),
                    .axis => addComponent(&sum, if (a.kind == .axis) .x else b.axis, b.scale * deadzone1(reader.axis(b.source.pad_axis), b.deadzone)),
                    .stick => sum = sum.add(deadzoneRadial(reader.stick(b.source.pad_stick), b.deadzone).scale(b.scale)),
                    .delta => sum = sum.add(reader.delta(b.source).scale(b.scale)),
                }
            }
            out.value = switch (a.kind) {
                .axis => .init(std.math.clamp(sum.x, -1, 1), 0),
                .vector => clampLength(sum),
                else => sum,
            };
            out.held = out.value.x != 0 or out.value.y != 0;
            out.pressed = !was and out.held;
            out.released = was and !out.held;
            memory.past = 0;
        },
    }
    memory.held = out.held;
    memory.known = true;
    return out;
}
