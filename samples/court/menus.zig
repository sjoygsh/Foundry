//! The court's menus as plain state: which screen is up, which row has the focus, and what
//! a key or a click on a row asks for (playable3d.md §6.1).
//!
//! Nothing here draws or reads a device. `hud.zig` draws this state and reports clicks; a
//! person's keys and a script's presses arrive as the same `Keys`. The game's phase is
//! simulation state and is never written here: a choice leaves as a `Command`, and the host
//! turns the ones that change the phase into the next tick's `Intent.action`.
const std = @import("std");
const game_mod = @import("game.zig");
const walk_mod = @import("walk.zig");

const Phase = game_mod.Phase;

pub const Screen = enum { hud, title, pause, ended, options };

pub const Item = enum {
    play,
    resume_game,
    restart,
    options,
    to_title,
    quit,
    volume,
    sensitivity,
    invert,
    back,
};

pub const title_items = [_]Item{ .play, .options, .quit };
pub const pause_items = [_]Item{ .resume_game, .restart, .options, .to_title };
pub const ended_items = [_]Item{ .restart, .to_title };
pub const options_items = [_]Item{ .volume, .sensitivity, .invert, .back };

/// One frame's menu input, as edges. Arrows, Enter and Escape for a person.
pub const Keys = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    accept: bool = false,
    back: bool = false,

    pub fn any(self: Keys) bool {
        return self.up or self.down or self.left or self.right or self.accept or self.back;
    }
};

/// What the player can change, with the bounds a preference file is held to as well.
pub const Options = struct {
    volume: f32 = 1,
    sensitivity: f32 = 1,
    invert: bool = false,

    pub const volume_min: f32 = 0;
    pub const volume_max: f32 = 1;
    pub const volume_step: f32 = 0.05;
    pub const sensitivity_min: f32 = 0.2;
    pub const sensitivity_max: f32 = 3;
    pub const sensitivity_step: f32 = 0.1;
};

/// What a frame of menu input asked for.
pub const Command = enum {
    none,
    play,
    pause,
    resume_game,
    restart,
    to_title,
    quit,
    /// The focus moved or a screen opened or closed: worth a click, nothing else.
    moved,
    /// `Options` changed and should be applied and saved.
    options_changed,

    /// The tick action this command is, if it is one.
    pub fn action(self: Command) walk_mod.Action {
        return switch (self) {
            .play => .play,
            .pause => .pause,
            .resume_game => .unpause,
            .restart => .restart,
            .to_title => .title,
            .none, .quit, .moved, .options_changed => .none,
        };
    }
};

pub const Menus = struct {
    focus: u8 = 0,
    options_open: bool = false,
    /// The focus to return to when Options closes.
    options_from: u8 = 0,
    /// The phase the focus belongs to. A new phase starts at its first row.
    seen: ?Phase = null,

    pub fn screen(self: *const Menus, phase: Phase) Screen {
        if (phase == .playing) return .hud;
        if (self.options_open) return .options;
        return switch (phase) {
            .title => .title,
            .paused => .pause,
            .won, .caught, .fell => .ended,
            .playing => unreachable,
        };
    }

    pub fn items(self: *const Menus, phase: Phase) []const Item {
        return switch (self.screen(phase)) {
            .hud => &.{},
            .title => &title_items,
            .pause => &pause_items,
            .ended => &ended_items,
            .options => &options_items,
        };
    }

    pub fn focused(self: *const Menus, phase: Phase) ?Item {
        const list = self.items(phase);
        if (list.len == 0) return null;
        return list[@min(self.focus, list.len - 1)];
    }

    /// One frame. `clicked` is a row the pointer pressed and `hovered` one it is over, both
    /// from the drawn screen; a hovered row takes the focus, so keys and pointer agree.
    pub fn update(self: *Menus, phase: Phase, keys: Keys, hovered: ?Item, clicked: ?Item, options: *Options) Command {
        if (self.seen != phase) {
            self.seen = phase;
            self.focus = 0;
            // Options belongs to the menu it was opened from; a phase change closes it.
            self.options_open = false;
        }
        const list = self.items(phase);
        if (list.len == 0) {
            // Playing: Escape pauses, and nothing else is a menu's.
            return if (keys.back) .pause else .none;
        }
        self.focus = @min(self.focus, @as(u8, @intCast(list.len - 1)));

        var result: Command = .none;
        if (hovered) |item| if (indexOf(list, item)) |at| {
            self.focus = at;
        };
        if (keys.up) {
            self.focus = if (self.focus == 0) @intCast(list.len - 1) else self.focus - 1;
            result = .moved;
        }
        if (keys.down) {
            self.focus = if (self.focus + 1 == list.len) 0 else self.focus + 1;
            result = .moved;
        }

        const current = list[self.focus];
        if (keys.left or keys.right) {
            const sign: f32 = if (keys.right) 1 else -1;
            if (adjust(current, sign, options)) result = .options_changed;
        }
        if (clicked) |item| if (indexOf(list, item)) |at| {
            self.focus = at;
            return self.activate(item, options);
        };
        if (keys.accept) return self.activate(current, options);
        if (keys.back) return self.goBack(phase);
        return result;
    }

    fn activate(self: *Menus, item: Item, options: *Options) Command {
        switch (item) {
            .play => return .play,
            .resume_game => return .resume_game,
            .restart => return .restart,
            .to_title => return .to_title,
            .quit => return .quit,
            .options => {
                self.options_open = true;
                self.options_from = self.focus;
                self.focus = 0;
                return .moved;
            },
            .back => {
                self.closeOptions();
                return .moved;
            },
            .invert => {
                options.invert = !options.invert;
                return .options_changed;
            },
            // A slider has nothing to accept; left and right change it.
            .volume, .sensitivity => return .none,
        }
    }

    fn goBack(self: *Menus, phase: Phase) Command {
        if (self.options_open) {
            self.closeOptions();
            return .moved;
        }
        return switch (phase) {
            .paused => .resume_game,
            .won, .caught, .fell => .to_title,
            // Leaving the title is Quit's, said out loud rather than under Escape.
            .title, .playing => .none,
        };
    }

    fn closeOptions(self: *Menus) void {
        self.options_open = false;
        self.focus = self.options_from;
    }
};

fn indexOf(list: []const Item, item: Item) ?u8 {
    for (list, 0..) |candidate, i| if (candidate == item) return @intCast(i);
    return null;
}

/// One step of a slider, clamped. Returns whether the value changed.
fn adjust(item: Item, sign: f32, options: *Options) bool {
    switch (item) {
        .volume => {
            const next = snap(options.volume + sign * Options.volume_step, Options.volume_step, Options.volume_min, Options.volume_max);
            if (next == options.volume) return false;
            options.volume = next;
            return true;
        },
        .sensitivity => {
            const next = snap(options.sensitivity + sign * Options.sensitivity_step, Options.sensitivity_step, Options.sensitivity_min, Options.sensitivity_max);
            if (next == options.sensitivity) return false;
            options.sensitivity = next;
            return true;
        },
        .invert => {
            options.invert = sign > 0;
            return true;
        },
        else => return false,
    }
}

/// To the nearest whole step, so repeated presses do not drift.
fn snap(value: f32, step: f32, min: f32, max: f32) f32 {
    return std.math.clamp(@round(value / step) * step, min, max);
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "menus: each phase shows its screen, starting at its first row" {
    var m: Menus = .{};
    var o: Options = .{};
    try testing.expectEqual(Screen.title, m.screen(.title));
    try testing.expectEqual(Command.none, m.update(.title, .{}, null, null, &o));
    try testing.expectEqual(Item.play, m.focused(.title).?);
    try testing.expectEqual(Command.moved, m.update(.title, .{ .down = true }, null, null, &o));
    try testing.expectEqual(Item.options, m.focused(.title).?);
    // A new phase starts at the top, wherever the last one's focus was.
    _ = m.update(.paused, .{}, null, null, &o);
    try testing.expectEqual(Item.resume_game, m.focused(.paused).?);
    try testing.expectEqual(Screen.hud, m.screen(.playing));
    try testing.expectEqual(@as(?Item, null), m.focused(.playing));
    for ([_]Phase{ .won, .caught, .fell }) |phase| {
        try testing.expectEqual(Screen.ended, m.screen(phase));
        _ = m.update(phase, .{}, null, null, &o);
        try testing.expectEqual(Item.restart, m.focused(phase).?);
    }
}

test "menus: the focus wraps, and accept gives each row's command" {
    var m: Menus = .{};
    var o: Options = .{};
    try testing.expectEqual(Command.moved, m.update(.title, .{ .up = true }, null, null, &o));
    try testing.expectEqual(Item.quit, m.focused(.title).?);
    try testing.expectEqual(Command.quit, m.update(.title, .{ .accept = true }, null, null, &o));
    try testing.expectEqual(Command.moved, m.update(.title, .{ .down = true }, null, null, &o));
    try testing.expectEqual(Command.play, m.update(.title, .{ .accept = true }, null, null, &o));

    const expected = [_]Command{ .resume_game, .restart, .moved, .to_title };
    for (pause_items, expected, 0..) |_, command, row| {
        var p: Menus = .{};
        _ = p.update(.paused, .{}, null, null, &o);
        for (0..row) |_| _ = p.update(.paused, .{ .down = true }, null, null, &o);
        try testing.expectEqual(command, p.update(.paused, .{ .accept = true }, null, null, &o));
    }
    var e: Menus = .{};
    try testing.expectEqual(Command.restart, e.update(.caught, .{ .accept = true }, null, null, &o));
    try testing.expectEqual(Command.moved, e.update(.caught, .{ .down = true }, null, null, &o));
    try testing.expectEqual(Command.to_title, e.update(.caught, .{ .accept = true }, null, null, &o));
}

test "menus: Escape pauses play, resumes a pause, leaves an end screen and does nothing on the title" {
    var m: Menus = .{};
    var o: Options = .{};
    try testing.expectEqual(Command.pause, m.update(.playing, .{ .back = true }, null, null, &o));
    try testing.expectEqual(Command.none, m.update(.playing, .{ .accept = true, .up = true }, null, null, &o));
    try testing.expectEqual(Command.resume_game, m.update(.paused, .{ .back = true }, null, null, &o));
    try testing.expectEqual(Command.to_title, m.update(.fell, .{ .back = true }, null, null, &o));
    try testing.expectEqual(Command.none, m.update(.title, .{ .back = true }, null, null, &o));
}

test "menus: only the commands that change the phase become tick actions" {
    try testing.expectEqual(walk_mod.Action.play, Command.play.action());
    try testing.expectEqual(walk_mod.Action.pause, Command.pause.action());
    try testing.expectEqual(walk_mod.Action.unpause, Command.resume_game.action());
    try testing.expectEqual(walk_mod.Action.restart, Command.restart.action());
    try testing.expectEqual(walk_mod.Action.title, Command.to_title.action());
    for ([_]Command{ .none, .quit, .moved, .options_changed }) |c| try testing.expectEqual(walk_mod.Action.none, c.action());
}

test "menus: options opens over its menu, changes values within bounds and returns to its row" {
    var m: Menus = .{};
    var o: Options = .{ .volume = 0.5, .sensitivity = 1 };
    _ = m.update(.paused, .{}, null, null, &o);
    _ = m.update(.paused, .{ .down = true }, null, null, &o);
    _ = m.update(.paused, .{ .down = true }, null, null, &o);
    try testing.expectEqual(Command.moved, m.update(.paused, .{ .accept = true }, null, null, &o));
    try testing.expectEqual(Screen.options, m.screen(.paused));
    try testing.expectEqual(Item.volume, m.focused(.paused).?);

    try testing.expectEqual(Command.options_changed, m.update(.paused, .{ .right = true }, null, null, &o));
    try testing.expectApproxEqAbs(@as(f32, 0.55), o.volume, 1e-6);
    try testing.expectEqual(Command.options_changed, m.update(.paused, .{ .left = true }, null, null, &o));
    try testing.expectApproxEqAbs(@as(f32, 0.5), o.volume, 1e-6);
    // Accept on a slider is not a change.
    try testing.expectEqual(Command.none, m.update(.paused, .{ .accept = true }, null, null, &o));
    // The bounds hold however long a key is pressed, and a press at a bound is no change.
    for (0..40) |_| _ = m.update(.paused, .{ .right = true }, null, null, &o);
    try testing.expectEqual(Options.volume_max, o.volume);
    try testing.expectEqual(Command.none, m.update(.paused, .{ .right = true }, null, null, &o));
    for (0..40) |_| _ = m.update(.paused, .{ .left = true }, null, null, &o);
    try testing.expectEqual(Options.volume_min, o.volume);

    _ = m.update(.paused, .{ .down = true }, null, null, &o);
    for (0..60) |_| _ = m.update(.paused, .{ .right = true }, null, null, &o);
    try testing.expectEqual(Options.sensitivity_max, o.sensitivity);
    for (0..60) |_| _ = m.update(.paused, .{ .left = true }, null, null, &o);
    try testing.expectEqual(Options.sensitivity_min, o.sensitivity);

    _ = m.update(.paused, .{ .down = true }, null, null, &o);
    try testing.expectEqual(Item.invert, m.focused(.paused).?);
    try testing.expectEqual(Command.options_changed, m.update(.paused, .{ .accept = true }, null, null, &o));
    try testing.expect(o.invert);
    try testing.expectEqual(Command.options_changed, m.update(.paused, .{ .left = true }, null, null, &o));
    try testing.expect(!o.invert);

    // Escape closes Options and does not resume the game; the focus is back on its row.
    try testing.expectEqual(Command.moved, m.update(.paused, .{ .back = true }, null, null, &o));
    try testing.expectEqual(Screen.pause, m.screen(.paused));
    try testing.expectEqual(Item.options, m.focused(.paused).?);
    // Back's own row closes it too.
    _ = m.update(.paused, .{ .accept = true }, null, null, &o);
    _ = m.update(.paused, .{ .up = true }, null, null, &o);
    try testing.expectEqual(Item.back, m.focused(.paused).?);
    try testing.expectEqual(Command.moved, m.update(.paused, .{ .accept = true }, null, null, &o));
    try testing.expectEqual(Screen.pause, m.screen(.paused));
    // A phase change closes Options.
    _ = m.update(.paused, .{ .accept = true }, null, null, &o);
    try testing.expectEqual(Screen.options, m.screen(.paused));
    _ = m.update(.title, .{}, null, null, &o);
    try testing.expectEqual(Screen.title, m.screen(.title));
}

test "menus: a hovered row takes the focus and a clicked row is activated; rows of another screen are ignored" {
    var m: Menus = .{};
    var o: Options = .{};
    try testing.expectEqual(Command.none, m.update(.title, .{}, .quit, null, &o));
    try testing.expectEqual(Item.quit, m.focused(.title).?);
    try testing.expectEqual(Command.play, m.update(.title, .{}, null, .play, &o));
    try testing.expectEqual(Item.play, m.focused(.title).?);
    // A stale click from a screen that is no longer up does nothing.
    try testing.expectEqual(Command.none, m.update(.title, .{}, null, .resume_game, &o));
    try testing.expectEqual(Command.none, m.update(.playing, .{}, .play, .play, &o));
}
