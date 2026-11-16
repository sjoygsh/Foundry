//! The court's half of M45 (`input.md` §11): which context is enabled, the menus' keys and the
//! walk's intent read from actions, what a script's hands are as actions, what a binding is
//! called on screen, which device the player last used, and the pad's rumble.
//!
//! Nothing here reads a key by name. Every press comes from an action the court's content
//! declares (`content/input.fdt`), so a mod or a player's rebinding changes it with no code.
const std = @import("std");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const input = @import("input");
const platform = @import("platform");
const walk_mod = @import("walk.zig");
const menus_mod = @import("menus.zig");
const SourceNames = @import("text.zig").SourceNames;

const ContentId = core.ContentId;
const Vec2 = core.math.Vec2;
const ids = walk_mod.actions;
const log = core.log.scoped(.court);

/// The walk's context in play, the menus' otherwise. Answers whether it changed, which is when
/// `Guard.arm` runs.
pub fn syncContexts(actions: *input.Actions, playing: bool) bool {
    const want = if (playing) ids.walk_context else ids.menu_context;
    const drop = if (playing) ids.menu_context else ids.walk_context;
    if (actions.isEnabled(want) and !actions.isEnabled(drop)) return false;
    actions.disable(drop);
    // Two contexts, never more than one enabled: eight is not reached.
    actions.enable(want) catch unreachable;
    return true;
}

/// The button actions whose press a context change could fake.
const guarded = [_]ContentId{
    ids.jump,      ids.use,        ids.menu_up,     ids.menu_down,
    ids.menu_left, ids.menu_right, ids.menu_accept, ids.menu_back,
};

/// **A button held across a change of context is not pressed by it.** An action in no enabled
/// context reads as rest, so one enabled while its key is still down reads as pressed: the pad's
/// south button that chose Play would jump, and a jump held when the warden catches would choose
/// Restart (`input.md` §7's rule, read from the court's side). `arm` notes which of those
/// actions' sources are down when the context changes, and each stays silent until it is let go.
pub const Guard = struct {
    armed: [guarded.len]bool = @splat(false),

    pub fn arm(self: *Guard, map: *const input.Map, snapshot: *const platform.InputSnapshot) void {
        for (guarded, &self.armed) |id, *armed| {
            const action = map.action(id) orelse {
                armed.* = false;
                continue;
            };
            armed.* = for (action.bindings()) |b| {
                if (sourceHeld(snapshot, b)) break true;
            } else false;
        }
    }

    /// Once a frame, from the frame's actions: a guarded action that is no longer held is free.
    pub fn update(self: *Guard, frame: *const input.Frame) void {
        for (guarded, &self.armed) |id, *armed| {
            if (armed.* and !frame.state(id).held) armed.* = false;
        }
    }

    pub fn pressed(self: *const Guard, frame: *const input.Frame, id: ContentId) bool {
        for (guarded, self.armed) |g, armed| if (g.eql(id) and armed) return false;
        return frame.state(id).pressed;
    }

    /// The tick's intent, with a held-over jump or use taken out.
    pub fn apply(self: *const Guard, frame: *const input.Frame, intent: *walk_mod.Intent) void {
        intent.jump = intent.jump and self.pressed(frame, ids.jump);
        intent.use = intent.use and self.pressed(frame, ids.use);
    }
};

/// Whether a binding's source is down in `s`: a button held, or a pad axis past its threshold.
fn sourceHeld(s: *const platform.InputSnapshot, b: input.Binding) bool {
    return switch (b.source) {
        .key => |k| s.isHeld(k),
        .mouse_button => |m| s.mouse.isHeld(m),
        .pad_button => |p| for (s.gamepads) |pad| {
            if (pad.connected and pad.isHeld(p)) break true;
        } else false,
        .pad_axis => |a| for (s.gamepads) |pad| {
            if (pad.connected and pad.axis(a) * std.math.sign(b.scale) >= b.threshold) break true;
        } else false,
        .pad_stick, .mouse_motion, .mouse_wheel, .wheel => false,
    };
}

/// One frame's menu keys from the frame's actions. Pause is in both contexts: in play it
/// pauses, in a menu it goes back, as Escape always did.
pub fn menuKeys(frame: *const input.Frame, guard: *const Guard) menus_mod.Keys {
    return .{
        .up = guard.pressed(frame, ids.menu_up),
        .down = guard.pressed(frame, ids.menu_down),
        .left = guard.pressed(frame, ids.menu_left),
        .right = guard.pressed(frame, ids.menu_right),
        .accept = guard.pressed(frame, ids.menu_accept),
        .back = guard.pressed(frame, ids.menu_back) or frame.state(ids.pause).pressed,
    };
}

/// **A script presses actions, not keys.** Its hands for one frame, as the court's actions
/// would read them, over `map`'s actions in its order: the walk as a vector, a flick of the
/// look as a delta, and Jump and Use pressed in every frame the script holds them. Fed through a
/// `TickView` and read by `walk.actionIntent`, the tick sees what M26's `Pending` gave it: edges
/// and motion once, at the first tick after them, and levels at every tick.
pub fn handsFrame(map: *const input.Map, hands: walk_mod.Intent) input.Frame {
    var frame: input.Frame = .{ .count = @intCast(map.actions.len) };
    for (map.actions, 0..) |a, i| {
        frame.ids[i] = a.id;
        frame.kinds[i] = a.kind;
        frame.states[i] = .rest;
    }
    set(&frame, ids.move, .vector, level(.init(hands.direction.x, -hands.direction.z)));
    set(&frame, ids.look, .delta, level(.init(hands.look_dx, hands.look_dy)));
    set(&frame, ids.jump, .button, .{ .held = hands.jump, .pressed = hands.jump });
    set(&frame, ids.use, .button, .{ .held = hands.use, .pressed = hands.use });
    return frame;
}

fn level(value: Vec2) input.ActionState {
    return .{ .held = value.x != 0 or value.y != 0, .value = value };
}

fn set(frame: *input.Frame, id: ContentId, kind: input.Kind, state: input.ActionState) void {
    const i = frame.find(id) orelse return;
    // A mod that changed the action's kind gets no hands for it: they would mean something else.
    if (frame.kinds[i] != kind) return;
    frame.states[i] = state;
}

/// Which half of a binding list a source belongs to: the Controls screen's two columns.
pub const Column = enum { keyboard, pad };

pub fn columnOf(source: input.Source) Column {
    return switch (source) {
        .pad_button, .pad_axis, .pad_stick => .pad,
        else => .keyboard,
    };
}

/// The pad the player touched last, or the keyboard and mouse: what a prompt names.
pub const LastDevice = struct {
    pad: ?u8 = null,

    pub fn note(self: *LastDevice, s: *const platform.InputSnapshot) void {
        if (s.keys_pressed.count() != 0 or s.mouse.buttons_pressed.count() != 0 or
            (s.mouse.captured and (s.mouse.motion.x != 0 or s.mouse.motion.y != 0))) self.pad = null;
        for (s.gamepads, 0..) |pad, slot| {
            if (!pad.connected) continue;
            var moved = pad.buttons_pressed.count() != 0;
            for (pad.axes) |v| moved = moved or @abs(v) >= 0.5;
            if (moved) self.pad = @intCast(slot);
        }
        if (self.pad) |slot| if (!s.gamepads[slot].connected) {
            self.pad = null;
        };
    }

    pub fn column(self: LastDevice) Column {
        return if (self.pad == null) .keyboard else .pad;
    }
};

/// Room for one cell's label: a vector's four keys at sixteen bytes each, and spaces.
pub const label_capacity = 72;

/// What one source is called: a key by the keyboard's layout, a face button by what `pad`
/// prints on it, anything else by `court:text.sources`, and its own name as the last resort.
pub fn sourceLabel(
    buf: *[label_capacity]u8,
    source: input.Source,
    labels: ?app.InputSources.Labels,
    names: SourceNames,
    pad: ?platform.GamepadState,
) []const u8 {
    switch (source) {
        .key => |k| {
            var key_buf: [platform.key.label_capacity]u8 = undefined;
            const shown = if (labels) |l| l.label(l.ctx, k, &key_buf) else platform.key.boundedLabel(k.name(), &key_buf);
            return copy(buf, if (shown.len != 0) shown else k.name());
        },
        .pad_button => |b| if (pad) |p| {
            const printed = p.labelOf(b);
            if (printed != .none) if (names.face(@tagName(printed))) |word| return copy(buf, word);
        },
        else => {},
    }
    var name_buf: [input.source.max_name]u8 = undefined;
    const name = source.name(&name_buf);
    return copy(buf, names.source(name) orelse name);
}

/// Every binding of `action` in `column`, each labelled, separated by spaces, or an empty slice.
pub fn columnLabel(
    buf: *[label_capacity]u8,
    action: *const input.Action,
    column: Column,
    labels: ?app.InputSources.Labels,
    names: SourceNames,
    pad: ?platform.GamepadState,
) []const u8 {
    var len: usize = 0;
    for (action.bindings()) |b| {
        if (columnOf(b.source) != column) continue;
        var one: [label_capacity]u8 = undefined;
        const word = sourceLabel(&one, b.source, labels, names, pad);
        const gap: usize = @intFromBool(len != 0);
        // Whole words only: a cell too narrow for the next one ends before it.
        if (len + gap + word.len > buf.len) break;
        if (gap != 0) buf[len] = ' ';
        @memcpy(buf[len + gap ..][0..word.len], word);
        len += gap + word.len;
    }
    return buf[0..len];
}

fn copy(buf: *[label_capacity]u8, text: []const u8) []const u8 {
    var n = @min(text.len, buf.len);
    // Cut on a codepoint, as every bounded label is.
    while (n < text.len and n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

/// The prompt's key cap: Use's binding on the device the player last used, or on the other one
/// when that device has none.
pub fn useLabel(
    buf: *[label_capacity]u8,
    map: *const input.Map,
    device: LastDevice,
    snapshot: *const platform.InputSnapshot,
    labels: ?app.InputSources.Labels,
    names: SourceNames,
) []const u8 {
    const action = map.action(ids.use) orelse return buf[0..0];
    const pad: ?platform.GamepadState = if (device.pad) |slot| snapshot.gamepads[slot] else null;
    const first: Column = device.column();
    for ([_]Column{ first, if (first == .pad) .keyboard else .pad }) |column| {
        for (action.bindings()) |b| {
            if (columnOf(b.source) == column) return sourceLabel(buf, b.source, labels, names, pad);
        }
    }
    return buf[0..0];
}

/// The pad's answer to being caught, from `court:controls.main`. Presentation only.
pub const Rumble = struct {
    low: f32 = 0,
    high: f32 = 0,
    ms: u32 = 0,

    pub const record_id = "court:controls.main";

    pub fn read(store: *const data.Store) Rumble {
        const record = store.lookup(ContentId.fromString(record_id)) orelse return .{};
        if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked("court:controls"))) return .{};
        const f = record.fields;
        const out: Rumble = .{
            .low = float(f, "caught_rumble_low") orelse return refused(),
            .high = float(f, "caught_rumble_high") orelse return refused(),
            .ms = @intCast(@min(int(f, "caught_rumble_ms") orelse return refused(), platform.gamepad.max_rumble_ms)),
        };
        if (!platform.gamepad.rumbleValid(out.low, out.high, out.ms)) return refused();
        return out;
    }

    fn refused() Rumble {
        log.warn("'{s}' is refused; the pad does not rumble", .{record_id});
        return .{};
    }

    /// Every connected pad, since any of them may be the player's.
    pub fn play(self: Rumble, engine: *app.Engine) void {
        if (self.ms == 0) return;
        for (engine.input.gamepads) |pad| {
            if (!pad.connected) continue;
            engine.platform.setGamepadRumble(pad.handle, self.low, self.high, self.ms) catch |err| {
                log.info("rumble unavailable ({t})", .{err});
            };
        }
    }
};

fn float(f: data.fpk.Fields, name: []const u8) ?f32 {
    for (f.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) {
        const v: f32 = @floatCast((f.floatAt(@intCast(i)) catch return null) orelse return null);
        return if (std.math.isFinite(v)) v else null;
    };
    return null;
}

fn int(f: data.fpk.Fields, name: []const u8) ?u64 {
    for (f.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) {
        const v = (f.intAt(@intCast(i)) catch return null) orelse return null;
        return std.math.cast(u64, v);
    };
    return null;
}
