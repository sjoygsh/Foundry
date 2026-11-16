//! Options → Controls (`input.md` §11, §8): every rebindable action with its keyboard and pad
//! binding. Accept captures a new one, Back cancels, a conflict asks and swaps, and "Reset"
//! returns every default.
//!
//! As `menus.zig` is, plain state: nothing here draws or writes a file. A finished choice leaves
//! as a `Change`, which `overridesWith` turns into the player's whole set for
//! `Engine.saveBindings`. The engine decides nothing about a conflict; the court swaps.
const std = @import("std");
const core = @import("core");
const input = @import("input");
const platform = @import("platform");
const walk_mod = @import("walk.zig");
const menus_mod = @import("menus.zig");
const controls = @import("controls.zig");
const ControlsText = @import("text.zig").ControlsText;
const SourceNames = @import("text.zig").SourceNames;
const Labels = @import("app").InputSources.Labels;

const ContentId = core.ContentId;
const Binding = input.Binding;
const Column = controls.Column;
const ids = walk_mod.actions;
const max_bindings = input.schemas.max_bindings;

/// A row: an action and the field of `court:text.controls` that names it.
pub const Row = struct { id: ContentId, name: []const u8 };

/// Every rebindable action the court declares, in the order the screen lists them. Look and
/// Pause are not rebindable and not listed.
pub const rows = [_]Row{
    .{ .id = ids.move, .name = "action_move" },
    .{ .id = ids.look_stick, .name = "action_look_stick" },
    .{ .id = ids.jump, .name = "action_jump" },
    .{ .id = ids.use, .name = "action_use" },
    .{ .id = ids.menu_up, .name = "action_menu_up" },
    .{ .id = ids.menu_down, .name = "action_menu_down" },
    .{ .id = ids.menu_left, .name = "action_menu_left" },
    .{ .id = ids.menu_right, .name = "action_menu_right" },
    .{ .id = ids.menu_accept, .name = "action_menu_accept" },
    .{ .id = ids.menu_back, .name = "action_menu_back" },
    .{ .id = ids.panels, .name = "action_panels" },
};

/// The rows after the actions.
pub const reset_row: u8 = rows.len;
pub const back_row: u8 = rows.len + 1;
pub const row_count: u8 = rows.len + 2;

pub fn nameOf(t: *const ControlsText, id: ContentId) []const u8 {
    inline for (rows) |r| if (r.id.eql(id)) return @field(t, r.name);
    return t.another_action;
}

/// A vector bound to buttons takes four, in this order: what `sequence_*` asks for.
const sequence = [_]struct { axis: input.Component, scale: f32 }{
    .{ .axis = .y, .scale = 1 },
    .{ .axis = .y, .scale = -1 },
    .{ .axis = .x, .scale = -1 },
    .{ .axis = .x, .scale = 1 },
};

/// One action's new bindings.
pub const Entry = struct {
    action: ContentId,
    buffer: [max_bindings]Binding = undefined,
    len: u8 = 0,

    pub fn bindings(self: *const Entry) []const Binding {
        return self.buffer[0..self.len];
    }
};

/// What the screen settled on: new bindings for an action and for any it swapped with, or every
/// default back.
pub const Change = struct {
    reset: bool = false,
    entries: [1 + max_conflicts]Entry = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Change) []const Entry {
        return self.entries[0..self.len];
    }
};

const max_conflicts = 4;

/// What a frame did on the screen.
pub const Result = struct {
    /// The focus moved, a capture began or ended: worth a click.
    moved: bool = false,
    closed: bool = false,
    change: ?Change = null,
};

pub const Mode = enum { browse, capturing, conflict };

pub const Controls = struct {
    focus: u8 = 0,
    column: Column = .keyboard,
    mode: Mode = .browse,
    capture: input.Capture = .{},
    /// The action being bound, its new column so far, and how many of a sequence are in.
    target: u8 = 0,
    taken: [4]Binding = undefined,
    taken_len: u8 = 0,
    /// Whether the capture is a vector's four buttons.
    sequenced: bool = false,
    /// The bindings a conflict asks about, and which actions hold their sources.
    proposed: Entry = .{ .action = .none },
    with: [max_conflicts]ContentId = undefined,
    with_len: u8 = 0,

    /// Opened from Options: the first row, browsing.
    pub fn open(self: *Controls) void {
        self.* = .{};
    }

    pub fn cancel(self: *Controls) void {
        self.capture.cancel();
        self.mode = .browse;
    }

    /// One frame. `keys` are the menus' (an accept starts a capture, a back cancels one);
    /// `snapshot` is what a capture listens to; `map` is the effective map. `clicked` is a cell
    /// the pointer pressed and `hovered` a row it is over.
    pub fn update(
        self: *Controls,
        keys: menus_mod.Keys,
        snapshot: *const platform.InputSnapshot,
        map: *const input.Map,
        hovered: ?u8,
        clicked: ?Cell,
    ) Result {
        switch (self.mode) {
            .capturing => return self.listen(keys, snapshot, map),
            .conflict => {
                if (keys.back) {
                    self.mode = .browse;
                    return .{ .moved = true };
                }
                if (keys.accept) {
                    self.mode = .browse;
                    return .{ .moved = true, .change = self.swap(map) };
                }
                return .{};
            },
            .browse => {},
        }
        var result: Result = .{};
        if (hovered) |row| self.focus = @min(row, row_count - 1);
        if (keys.up) {
            self.focus = if (self.focus == 0) row_count - 1 else self.focus - 1;
            result.moved = true;
        }
        if (keys.down) {
            self.focus = if (self.focus + 1 == row_count) 0 else self.focus + 1;
            result.moved = true;
        }
        if (keys.left or keys.right) {
            const next: Column = if (keys.right) .pad else .keyboard;
            if (next != self.column) result.moved = true;
            self.column = next;
        }
        if (clicked) |cell| {
            self.focus = @min(cell.row, row_count - 1);
            self.column = cell.column;
            return self.activate(map);
        }
        if (keys.accept) return self.activate(map);
        if (keys.back) return .{ .moved = true, .closed = true };
        return result;
    }

    fn activate(self: *Controls, map: *const input.Map) Result {
        if (self.focus == back_row) return .{ .moved = true, .closed = true };
        if (self.focus == reset_row) return .{ .moved = true, .change = .{ .reset = true } };
        const action = map.action(rows[self.focus].id) orelse return .{};
        if (!action.rebindable) return .{};
        var ignore: [input.rebind.max_ignored]input.Source = undefined;
        self.capture.start(.{
            .keyboard_mouse = self.column == .keyboard,
            .pads = if (self.column == .pad) 0b1111 else 0,
            .ignore = cancelSources(map, &ignore),
        }) catch return .{};
        self.mode = .capturing;
        self.target = self.focus;
        self.taken_len = 0;
        self.sequenced = action.kind == .vector;
        return .{ .moved = true };
    }

    fn listen(self: *Controls, keys: menus_mod.Keys, snapshot: *const platform.InputSnapshot, map: *const input.Map) Result {
        if (keys.back) {
            self.cancel();
            return .{ .moved = true };
        }
        const got = self.capture.feed(snapshot) orelse return .{};
        const action = map.action(rows[self.target].id) orelse {
            self.cancel();
            return .{ .moved = true };
        };
        if (self.taken_len == 0 and self.column == .pad and action.kind == .vector) {
            if (stickOf(got.source)) |stick| {
                self.taken[0] = .{ .source = .{ .pad_stick = stick }, .deadzone = stickDeadzone(action) };
                self.taken_len = 1;
                return self.finish(map, action);
            }
        }
        if (self.sequenced) {
            const s = sequence[self.taken_len];
            self.taken[self.taken_len] = .{ .source = got.source, .axis = s.axis, .scale = s.scale * got.scale };
            self.taken_len += 1;
            if (self.taken_len < sequence.len) {
                self.restart(map);
                return .{ .moved = true };
            }
        } else {
            self.taken[0] = .{ .source = got.source, .scale = got.scale };
            self.taken_len = 1;
        }
        return self.finish(map, action);
    }

    /// The next of a sequence: `Capture` disarms once it answers.
    fn restart(self: *Controls, map: *const input.Map) void {
        var ignore: [input.rebind.max_ignored]input.Source = undefined;
        self.capture.start(.{
            .keyboard_mouse = self.column == .keyboard,
            .pads = if (self.column == .pad) 0b1111 else 0,
            .ignore = cancelSources(map, &ignore),
        }) catch self.cancel();
    }

    /// The action's other column as it was, then the new one; a conflict asks first.
    fn finish(self: *Controls, map: *const input.Map, action: *const input.Action) Result {
        self.mode = .browse;
        var entry: Entry = .{ .action = action.id };
        for (action.bindings()) |b| {
            if (controls.columnOf(b.source) == self.column) continue;
            if (entry.len == max_bindings) break;
            entry.buffer[entry.len] = b;
            entry.len += 1;
        }
        for (self.taken[0..self.taken_len]) |b| {
            if (entry.len == max_bindings) break;
            entry.buffer[entry.len] = b;
            entry.len += 1;
        }
        self.proposed = entry;
        self.with_len = 0;
        for (self.taken[0..self.taken_len]) |b| {
            var found: [8]ContentId = undefined;
            for (map.conflicts(b.source, action.id, &found)) |other| {
                const known = for (self.with[0..self.with_len]) |w| {
                    if (w.eql(other)) break true;
                } else false;
                if (known or self.with_len == max_conflicts) continue;
                self.with[self.with_len] = other;
                self.with_len += 1;
            }
        }
        if (self.with_len != 0) {
            self.mode = .conflict;
            return .{ .moved = true };
        }
        var change: Change = .{};
        change.entries[0] = entry;
        change.len = 1;
        return .{ .moved = true, .change = change };
    }

    /// The new bindings, and each conflicting action given this one's old source in the place of
    /// the one it lost: the same position in a sequence, else the column's first. One with no old
    /// source to take, or that is not rebindable, keeps its own and the two share it.
    fn swap(self: *const Controls, map: *const input.Map) Change {
        var change: Change = .{};
        change.entries[0] = self.proposed;
        change.len = 1;
        const mine = map.action(self.proposed.action) orelse return change;
        var old: [max_bindings]input.Source = undefined;
        var old_len: usize = 0;
        for (mine.bindings()) |b| if (controls.columnOf(b.source) == self.column) {
            old[old_len] = b.source;
            old_len += 1;
        };
        for (self.with[0..self.with_len]) |id| {
            const other = map.action(id) orelse continue;
            if (!other.rebindable) continue;
            var entry: Entry = .{ .action = id };
            for (other.bindings()) |b| {
                var kept = b;
                for (self.taken[0..self.taken_len], 0..) |t, n| {
                    if (!input.source.overlaps(b.source, t.source)) continue;
                    if (old_len == 0) break;
                    kept.source = old[if (n < old_len) n else 0];
                    break;
                }
                // A source the other action cannot read (a stick on a button) is dropped.
                if (!other.kind.accepts(kept.source.class())) continue;
                entry.buffer[entry.len] = kept;
                entry.len += 1;
            }
            change.entries[change.len] = entry;
            change.len += 1;
        }
        return change;
    }

    /// The sequence word the capture asks for now, or null for a single capture.
    pub fn asking(self: *const Controls) ?usize {
        if (self.mode != .capturing or !self.sequenced) return null;
        return self.taken_len;
    }

    pub fn conflicts(self: *const Controls) []const ContentId {
        return self.with[0..self.with_len];
    }

    /// The first source of the proposal that conflicts, for the question.
    pub fn conflicting(self: *const Controls) ?input.Source {
        if (self.taken_len == 0) return null;
        return self.taken[0].source;
    }
};

/// A cell of the table: an action's row and one of its two columns.
pub const Cell = struct { row: u8, column: Column };

/// What cancels a capture and so never becomes a binding: Pause's and Back's sources.
fn cancelSources(map: *const input.Map, out: *[input.rebind.max_ignored]input.Source) []const input.Source {
    var n: usize = 0;
    for ([_]ContentId{ ids.pause, ids.menu_back }) |id| {
        const action = map.action(id) orelse continue;
        for (action.bindings()) |b| {
            if (n == out.len) break;
            out[n] = b.source;
            n += 1;
        }
    }
    return out[0..n];
}

fn stickOf(source: input.Source) ?input.source.Stick {
    return switch (source) {
        .pad_axis => |a| switch (a) {
            .left_x, .left_y => .left,
            .right_x, .right_y => .right,
            else => null,
        },
        .pad_stick => |s| s,
        else => null,
    };
}

/// A captured stick keeps the deadzone its action's stick had.
fn stickDeadzone(action: *const input.Action) f32 {
    for (action.bindings()) |b| if (b.source == .pad_stick) return b.deadzone;
    return (Binding{ .source = .mouse_motion }).deadzone;
}

/// The player's whole set after `change`: `current`, with each entry's action replaced, or none
/// at all for a reset. The caller owns the answer and hands it to `Engine.saveBindings`.
pub fn overridesWith(gpa: std.mem.Allocator, current: *const input.Overrides, change: *const Change) input.rebind.SetError!input.Overrides {
    var out: input.Overrides = .empty;
    errdefer out.deinit(gpa);
    if (change.reset) return out;
    for (current.slice()) |o| try out.set(gpa, o.action, o.bindings());
    for (change.slice()) |*e| try out.set(gpa, e.action, e.bindings());
    return out;
}

/// What the Controls screen shows this frame, its labels in buffers of its own so the screen can
/// borrow them while it is described. Filled by `fill` from the effective map.
pub const Table = struct {
    names: [rows.len][]const u8 = @splat(""),
    cells: [rows.len][2][]const u8 = @splat(.{ "", "" }),
    buffers: [rows.len][2][controls.label_capacity]u8 = undefined,
    focus: u8 = 0,
    column: Column = .keyboard,
    mode: Mode = .browse,
    /// While capturing, what to press; in a conflict, the question. Borrowed from text or from
    /// `line_buffer`.
    line: []const u8 = "",
    detail: []const u8 = "",
    line_buffer: [256]u8 = undefined,

    pub fn fill(
        self: *Table,
        state: *const Controls,
        map: *const input.Map,
        t: *const ControlsText,
        labels: ?Labels,
        names: SourceNames,
        pad: ?platform.GamepadState,
    ) void {
        self.focus = state.focus;
        self.column = state.column;
        self.mode = state.mode;
        inline for (rows, 0..) |r, i| self.names[i] = @field(t, r.name);
        for (rows, 0..) |r, i| {
            const action = map.action(r.id);
            for ([_]Column{ .keyboard, .pad }, 0..) |c, n| {
                const shown = if (action) |a| controls.columnLabel(&self.buffers[i][n], a, c, labels, names, pad) else "";
                self.cells[i][n] = if (shown.len == 0) t.unbound else shown;
            }
        }
        self.line = "";
        self.detail = "";
        switch (state.mode) {
            .browse => {},
            .capturing => {
                self.line = if (state.column == .pad) t.press_pad else t.press_key;
                if (state.asking()) |n| self.line = std.fmt.bufPrint(&self.line_buffer, "{s}: {s}", .{
                    self.line,
                    switch (n) {
                        0 => t.sequence_up,
                        1 => t.sequence_down,
                        2 => t.sequence_left,
                        else => t.sequence_right,
                    },
                }) catch self.line;
                self.detail = t.press_cancel;
            },
            .conflict => {
                var one: [controls.label_capacity]u8 = undefined;
                const source = if (state.conflicting()) |s| controls.sourceLabel(&one, s, labels, names, pad) else "";
                const other = if (state.conflicts().len != 0) nameOf(t, state.conflicts()[0]) else t.another_action;
                self.line = std.fmt.bufPrint(&self.line_buffer, "{s} {s} {s}", .{ source, t.conflict, other }) catch t.conflict;
                self.detail = t.conflict_hint;
            },
        }
    }
};
