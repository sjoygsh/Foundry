//! Rebinding: a player's overrides and capturing the next source (`docs/design/input.md` §8,
//! ADR-0088). `Map.apply` and `Map.conflicts` are `map.zig`'s.
//!
//! **An override replaces an action's bindings whole.** "My bindings for Jump are these" is one
//! rule a player can predict, and it never merges a player's change with a mod's later change
//! to the same defaults. The order of authority is the player's override, then the last
//! package's record, then the game's: the map is built from the merged store, and `apply` lays
//! the overrides over it.
//!
//! Overrides are not content and never a package (ADR-0031). Step 6's `app.input_bindings`
//! reads and writes them in `bindings.fset`; this file holds them as values.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const schemas = @import("schemas.zig");
const source_mod = @import("source.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const InputSnapshot = platform.InputSnapshot;
const Binding = schemas.Binding;
const Source = source_mod.Source;
const Physical = source_mod.Physical;

/// The most actions a player may override (ADR-0088).
pub const max_overrides: usize = 256;

/// One action's replacement bindings, in the record's own shape. Zero bindings is an action the
/// player has unbound.
pub const Override = struct {
    action: ContentId,
    binding_buffer: [schemas.max_bindings]Binding = undefined,
    binding_count: u8 = 0,

    pub fn bindings(self: *const Override) []const Binding {
        return self.binding_buffer[0..self.binding_count];
    }
};

pub const SetError = Allocator.Error || error{
    /// 256 actions are overridden already, and this is not one of them.
    TooManyOverrides,
    /// More than eight bindings.
    TooManyBindings,
    InvalidScale,
    InvalidThreshold,
    InvalidDeadzone,
};

/// A player's overrides, by action, kept in content-ID order.
pub const Overrides = struct {
    items: std.ArrayList(Override) = .empty,

    pub const empty: Overrides = .{};

    pub fn deinit(self: *Overrides, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.* = .empty;
    }

    /// Replaces the action's override, or adds one. Its numbers are checked here; whether its
    /// sources can feed the action's kind needs the map, and is `Map.apply`'s.
    pub fn set(self: *Overrides, gpa: Allocator, action: ContentId, bindings: []const Binding) SetError!void {
        if (bindings.len > schemas.max_bindings) return error.TooManyBindings;
        for (bindings) |*b| b.validate() catch |err| return switch (err) {
            error.InvalidScale => error.InvalidScale,
            error.InvalidThreshold => error.InvalidThreshold,
            else => error.InvalidDeadzone,
        };
        var value: Override = .{ .action = action, .binding_count = @intCast(bindings.len) };
        @memcpy(value.binding_buffer[0..bindings.len], bindings);
        const at = self.lowerBound(action);
        if (at < self.items.items.len and self.items.items[at].action.eql(action)) {
            self.items.items[at] = value;
            return;
        }
        if (self.items.items.len == max_overrides) return error.TooManyOverrides;
        try self.items.insert(gpa, at, value);
    }

    /// Removes the action's override, so its defaults stand. Whether there was one.
    pub fn remove(self: *Overrides, action: ContentId) bool {
        const at = self.lowerBound(action);
        if (at == self.items.items.len or !self.items.items[at].action.eql(action)) return false;
        _ = self.items.orderedRemove(at);
        return true;
    }

    pub fn get(self: *const Overrides, action: ContentId) ?*const Override {
        const at = self.lowerBound(action);
        if (at == self.items.items.len or !self.items.items[at].action.eql(action)) return null;
        return &self.items.items[at];
    }

    pub fn slice(self: *const Overrides) []const Override {
        return self.items.items;
    }

    fn lowerBound(self: *const Overrides, action: ContentId) usize {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.items.items[mid].action.hash < action.hash) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

/// The sources a capture may not take: the game's cancel binding, so Escape cancels rather than
/// binds. Compared by physical input.
pub const max_ignored: usize = 8;

/// Where an axis becomes a capture: leaving rest past this, in either direction.
pub const capture_threshold: f32 = 0.5;

pub const CaptureOptions = struct {
    /// Keys, mouse buttons and the wheel's four directions.
    keyboard_mouse: bool = true,
    /// One bit per pad slot.
    pads: u4 = 0b1111,
    ignore: []const Source = &.{},
};

/// The source a capture took, with the scale a binding should give it: 1 for a button, the
/// axis's sign for an axis.
pub const Captured = struct {
    source: Source,
    scale: f32 = 1,
    /// The slot a pad source came from, for a game seating local players.
    pad: ?u8 = null,
};

/// Listens for the next source a player makes active.
///
/// Fed one snapshot at a time, it answers the first source that became active: a key, a mouse
/// button or a pad button pressed, the wheel turned, or a pad axis leaving rest past 0.5, its
/// sign giving the scale. **Mouse motion never captures**, and neither does a source in
/// `ignore`. Ties in one snapshot go by source order: keys, then mouse buttons, then the wheel's
/// up, down, left and right, then each pad by slot, its buttons and then its axes, each in enum
/// order.
///
/// An axis captures only when it leaves rest: the first snapshot after `start` (and the first
/// after a new pad is seated) sets where each axis is, so a stick still held from navigating
/// the menu does not bind itself. A key held at `start` has no press edge and does not either.
/// Once it answers, it is disarmed.
pub const Capture = struct {
    armed: bool = false,
    keyboard_mouse: bool = true,
    pads: u4 = 0,
    ignored: Physical = source_mod.no_physical,
    /// Per slot, whether each axis was past the threshold at the last snapshot fed, for the pad
    /// in the slot then.
    past: [platform.max_gamepads]u8 = @splat(0),
    seen: [platform.max_gamepads]platform.GamepadHandle = @splat(.none),
    baseline: bool = false,

    pub const StartError = error{TooManyIgnored};

    pub fn start(self: *Capture, options: CaptureOptions) StartError!void {
        if (options.ignore.len > max_ignored) return error.TooManyIgnored;
        self.* = .{ .armed = true, .keyboard_mouse = options.keyboard_mouse, .pads = options.pads };
        for (options.ignore) |s| source_mod.markPhysical(&self.ignored, s);
    }

    pub fn cancel(self: *Capture) void {
        self.armed = false;
    }

    pub fn feed(self: *Capture, s: *const InputSnapshot) ?Captured {
        if (!self.armed) return null;
        const found = self.find(s);
        self.remember(s);
        if (found != null) self.armed = false;
        return found;
    }

    fn take(self: *const Capture, source: Source) bool {
        return source_mod.physicalOf(source).intersectWith(self.ignored).count() == 0;
    }

    fn find(self: *const Capture, s: *const InputSnapshot) ?Captured {
        if (self.keyboard_mouse) {
            for (std.enums.values(platform.Key)) |k| {
                if (k == .unknown or !s.wasPressed(k)) continue;
                if (self.take(.{ .key = k })) return .{ .source = .{ .key = k } };
            }
            for (std.enums.values(platform.MouseButton)) |b| {
                if (!s.mouse.wasPressed(b)) continue;
                if (self.take(.{ .mouse_button = b })) return .{ .source = .{ .mouse_button = b } };
            }
            const w = s.mouse.wheel;
            const turned = [_]struct { d: source_mod.WheelDirection, on: bool }{
                .{ .d = .up, .on = w.y > 0 },   .{ .d = .down, .on = w.y < 0 },
                .{ .d = .left, .on = w.x < 0 }, .{ .d = .right, .on = w.x > 0 },
            };
            for (turned) |t| {
                if (t.on and self.take(.{ .wheel = t.d })) return .{ .source = .{ .wheel = t.d } };
            }
        }
        for (0..platform.max_gamepads) |slot| {
            if (self.pads & (@as(u4, 1) << @intCast(slot)) == 0) continue;
            const pad = s.gamepads[slot];
            if (!pad.connected) continue;
            for (std.enums.values(platform.GamepadButton)) |b| {
                if (!pad.wasPressed(b)) continue;
                if (self.take(.{ .pad_button = b })) return .{ .source = .{ .pad_button = b }, .pad = @intCast(slot) };
            }
            // A pad not seen at the last snapshot has no rest to leave yet.
            if (!self.baseline or !self.seen[slot].eql(pad.handle)) continue;
            for (std.enums.values(platform.GamepadAxis)) |a| {
                const v = pad.axis(a);
                const bit = @as(u8, 1) << @as(u3, @intCast(@intFromEnum(a)));
                if (@abs(v) <= capture_threshold or self.past[slot] & bit != 0) continue;
                if (self.take(.{ .pad_axis = a })) return .{ .source = .{ .pad_axis = a }, .scale = if (v < 0) -1 else 1, .pad = @intCast(slot) };
            }
        }
        return null;
    }

    fn remember(self: *Capture, s: *const InputSnapshot) void {
        for (0..platform.max_gamepads) |slot| {
            const pad = s.gamepads[slot];
            var bits: u8 = 0;
            if (pad.connected) {
                for (std.enums.values(platform.GamepadAxis)) |a| {
                    if (@abs(pad.axis(a)) > capture_threshold) bits |= @as(u8, 1) << @as(u3, @intCast(@intFromEnum(a)));
                }
            }
            self.past[slot] = bits;
            self.seen[slot] = if (pad.connected) pad.handle else .none;
        }
        self.baseline = true;
    }
};
