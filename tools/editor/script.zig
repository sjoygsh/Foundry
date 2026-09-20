//! Deterministic input for the editor, replayed frame by frame.
//!
//! `editor.md` §12 asks for headless action sequences and for a real window that shows text
//! entry, clipping and capture actually working.  Both need input that does not come from a
//! human, and both need it to be the *same* input every time, so this is one runner over a
//! list of actions rather than two scripts that could drift apart.
//!
//! **It aims at rectangles the client recorded, never at coordinates written down here.**
//! A control that moves takes its script with it, and a control that vanished makes its step
//! a no-op instead of a click on whatever is now underneath it.
//!
//! **Nothing in this file knows a schema, a record or a field by name** (`editor.md` §11).
//! The application's built-in script walks the regions, types into the filter and reaches the
//! first row of each list; the workflow that creates and edits named records is test code,
//! where knowing a fixture's names is allowed.
//!
//! A plan that *does* name a schema, a record or a field is read from a file the host was
//! given on its command line (`--plan`), so the names stay in the author's directory beside
//! the package they describe and never in the editor.  `parse` turns that text into the same
//! actions the built-in walkthrough is written in, and the runner cannot tell them apart.

const std = @import("std");
const core = @import("core");
const editor_client = @import("editor_client");
const platform = @import("platform");
const ui = @import("ui");

const Vec2 = core.math.Vec2;
const Targets = editor_client.Targets;

pub const Target = enum {
    new_package,
    new_record,
    new_document,
    save,
    save_all,
    validate,
    build,
    reload,
    export_package,
    undo,
    redo,
    form_create,
    form_cancel,
    form_field_0,
    form_field_1,
    form_field_2,
    form_field_3,
    first_schema,
    filter,
    tab_source,
    tab_dependencies,
    tab_preview,
    tab_schemas,
    tab_assets,
    first_document,
    first_record,
    field,
    field_apply,
    field_reset,
    list_add,
    list_element,
    list_remove,
    list_up,
    list_down,
    boolean,
    record_delete,
    record_duplicate,
    dependency_package,
    dependency_override,
    first_dependency_record,
    confirm_save,
    confirm_discard,
    confirm_cancel,
    document_refresh,
    document_discard,

    /// Where this target was drawn, if it was.  `index` chooses among the details pane's
    /// rows and is ignored by everything else, because every other control is unique in a
    /// frame while a field row is one of many.
    pub fn rect(self: Target, targets: *const Targets, index: u32) ?editor_client.Rect {
        const at: Targets.Row = if (index < targets.row_count) targets.rows[index] else .{};
        return switch (self) {
            .new_package => targets.new_package,
            .new_record => targets.new_record,
            .new_document => targets.new_document,
            .save => targets.save,
            .save_all => targets.save_all,
            .validate => targets.validate,
            .build => targets.build,
            .reload => targets.reload,
            .export_package => targets.export_package,
            .undo => targets.undo,
            .redo => targets.redo,
            .form_create => targets.form_create,
            .form_cancel => targets.form_cancel,
            .form_field_0 => targets.form_fields[0],
            .form_field_1 => targets.form_fields[1],
            .form_field_2 => targets.form_fields[2],
            .form_field_3 => targets.form_fields[3],
            .first_schema => targets.first_schema,
            .filter => targets.filter,
            .tab_source => targets.tabs[0],
            .tab_dependencies => targets.tabs[1],
            .tab_preview => targets.tabs[2],
            .tab_schemas => targets.tabs[3],
            .tab_assets => targets.tabs[4],
            .first_document => targets.first_document,
            .first_record => targets.first_record,
            .field, .boolean => at.control,
            .field_apply => at.apply,
            .field_reset => at.reset,
            .list_add => at.add,
            .list_element => at.element,
            .list_remove => at.remove,
            .list_up => at.up,
            .list_down => at.down,
            .record_delete => targets.record_delete,
            .record_duplicate => targets.record_duplicate,
            // The one row-indexed target outside the details pane: only the chosen
            // package's records are listed, so a plan has to choose one.
            .dependency_package => if (index < targets.dependency_packages.len) targets.dependency_packages[index] else null,
            .dependency_override => targets.dependency_override,
            .first_dependency_record => targets.first_dependency_record,
            .confirm_save => targets.confirm_save,
            .confirm_discard => targets.confirm_discard,
            .confirm_cancel => targets.confirm_cancel,
            .document_refresh => targets.document_refresh,
            .document_discard => targets.document_discard,
        };
    }
};

/// A target and which of the details pane's rows it belongs to.
pub const Click = struct {
    target: Target,
    row: u32 = 0,

    pub fn rect(self: Click, targets: *const Targets) ?editor_client.Rect {
        return self.target.rect(targets, self.row);
    }
};

pub const Action = union(enum) {
    /// Hover, press, release — three frames, because that is what a real click is and the
    /// kernel's hot/active model is written against the edges rather than a state.
    click: Click,
    /// Typed characters, delivered to whatever the last click focused. Split across frames
    /// when longer than one text event carries.
    write: []const u8,
    key: platform.Key,
    idle,
};

/// A generic walk of every region, for the windowed proof.  It changes nothing: each step
/// is a selection, a tab or a filter keystroke, so it is safe to point at a real package.
pub const walkthrough = [_]Action{
    .idle,
    .{ .click = .{ .target = .first_document } },
    .{ .click = .{ .target = .first_record } },
    .idle,
    .{ .click = .{ .target = .field } },
    .{ .write = "0" },
    .{ .key = .backspace },
    .idle,
    .{ .click = .{ .target = .filter } },
    .{ .write = "e" },
    .idle,
    .{ .key = .backspace },
    .idle,
    .{ .click = .{ .target = .tab_dependencies } },
    .{ .click = .{ .target = .first_dependency_record } },
    .idle,
    .{ .click = .{ .target = .tab_schemas } },
    .idle,
    .{ .click = .{ .target = .tab_preview } },
    .idle,
    .{ .click = .{ .target = .tab_assets } },
    .idle,
    .{ .click = .{ .target = .tab_source } },
    .{ .click = .{ .target = .validate } },
    .idle,
};

/// The most actions a plan file may hold.  A plan is a developer's own input rather than
/// content, but it is still a file, so it is still bounded.
pub const max_actions = 1024;

/// How many characters `enter` deletes before it types.  A control keeps what was last in
/// it, so a plan that only typed would be appending to it.
const clear_strokes = 40;

/// Where a plan file stopped making sense, for a message that names the line.
pub const ParseError = struct {
    line: u32 = 0,
    word: []const u8 = "",
};

/// One action per line: `click <target>[:<row>]`, `write <text>`, `key <name>`, `idle`, or
/// `enter <target>[:<row>] <text>` — which is the click, the caret, the clearing and the
/// typing an author performs to replace a control's contents.  A `#` at the start of a line
/// is a comment, and a blank line is nothing.
///
/// **The returned actions borrow `source`**: `write` payloads point into it, so it must
/// outlive them.  The slice itself is the caller's to free.
pub fn parse(
    gpa: std.mem.Allocator,
    source: []const u8,
    err: *ParseError,
) error{ BadPlan, OutOfMemory }![]Action {
    var actions: std.ArrayList(Action) = .empty;
    errdefer actions.deinit(gpa);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (actions.items.len >= max_actions) {
            err.* = .{ .line = number, .word = "too many actions" };
            return error.BadPlan;
        }

        const verb_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const verb = line[0..verb_end];
        const rest = std.mem.trim(u8, line[verb_end..], " \t");

        if (std.mem.eql(u8, verb, "idle")) {
            if (rest.len != 0) return badPlan(err, number, rest);
            try actions.append(gpa, .idle);
        } else if (std.mem.eql(u8, verb, "write")) {
            if (rest.len == 0) return badPlan(err, number, verb);
            try actions.append(gpa, .{ .write = rest });
        } else if (std.mem.eql(u8, verb, "key")) {
            const which = std.meta.stringToEnum(platform.Key, rest) orelse return badPlan(err, number, rest);
            try actions.append(gpa, .{ .key = which });
        } else if (std.mem.eql(u8, verb, "click") or std.mem.eql(u8, verb, "enter")) {
            const token_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            const click = clickOf(rest[0..token_end]) orelse return badPlan(err, number, rest[0..token_end]);
            const text = std.mem.trim(u8, rest[token_end..], " \t");
            try actions.append(gpa, .{ .click = click });
            if (std.mem.eql(u8, verb, "click")) {
                if (text.len != 0) return badPlan(err, number, text);
            } else {
                if (text.len == 0) return badPlan(err, number, verb);
                try actions.append(gpa, .{ .key = .end });
                try actions.appendNTimes(gpa, .{ .key = .backspace }, clear_strokes);
                try actions.append(gpa, .{ .write = text });
                try actions.append(gpa, .idle);
            }
        } else return badPlan(err, number, verb);
    }
    return actions.toOwnedSlice(gpa);
}

fn badPlan(err: *ParseError, line: u32, word: []const u8) error{BadPlan} {
    err.* = .{ .line = line, .word = word };
    return error.BadPlan;
}

/// `field:3` is the fourth row's control; a bare name is the first row, or a control that
/// has no row at all.
fn clickOf(token: []const u8) ?Click {
    const colon = std.mem.indexOfScalar(u8, token, ':') orelse token.len;
    const target = std.meta.stringToEnum(Target, token[0..colon]) orelse return null;
    if (colon == token.len) return .{ .target = target };
    const row = std.fmt.parseInt(u32, token[colon + 1 ..], 10) catch return null;
    return .{ .target = target, .row = row };
}

/// How many frames a plan needs, so a bounded run can be given exactly enough.
pub fn frames(plan: []const Action) u64 {
    var total: u64 = 0;
    for (plan) |action| total += switch (action) {
        .click => 3,
        .write => |bytes| @max(1, (bytes.len + platform.event.max_text_bytes - 1) / platform.event.max_text_bytes),
        .key, .idle => 1,
    };
    return total + 1;
}

pub const Runner = struct {
    plan: []const Action,
    step: usize = 0,
    /// Which frame of the current action this is: a click's hover/press/release, or a
    /// write's chunk.
    phase: usize = 0,
    /// Where the pointer was left, so a press and its release agree about the target even
    /// if the control moved between them.
    pointer: Vec2 = .init(-1, -1),
    typed: [1]platform.event.TextInput = .{.{}},

    pub fn init(plan: []const Action) Runner {
        return .{ .plan = plan };
    }

    pub fn done(self: *const Runner) bool {
        return self.step >= self.plan.len;
    }

    /// One frame of input.  Reading it advances the script by exactly one frame.
    pub fn next(self: *Runner, targets: *const Targets, frame: u64) ui.Input {
        if (self.done()) return idle(frame);
        const action = self.plan[self.step];
        switch (action) {
            .idle => {
                self.advance();
                return idle(frame);
            },
            .key => |k| {
                self.advance();
                var input = idle(frame);
                input.pointer = self.pointer;
                input.keys.keys_pressed = keySet(k);
                return input;
            },
            .click => |at| {
                if (self.phase == 0) {
                    const bounds = at.rect(targets) orelse {
                        // A control the frame did not draw is not clicked on: the step is
                        // skipped rather than aimed at whatever occupies its space now.
                        self.advance();
                        return idle(frame);
                    };
                    self.pointer = .init(bounds.x + 8, bounds.y + 10);
                }
                const phase = self.phase;
                self.phase += 1;
                if (self.phase == 3) self.advance();
                var input: ui.Input = .at(self.pointer, switch (phase) {
                    0 => .up,
                    1 => .pressed,
                    else => .released,
                });
                input.frame = frame;
                return input;
            },
            .write => |bytes| {
                const chunk = platform.event.max_text_bytes;
                const from = self.phase * chunk;
                const to = @min(bytes.len, from + chunk);
                self.phase += 1;
                if (to >= bytes.len) self.advance();
                var input = idle(frame);
                input.pointer = self.pointer;
                self.typed[0] = platform.event.TextInput.fromSlice(bytes[from..to]) orelse .{};
                input.text = self.typed[0..1];
                return input;
            },
        }
    }

    fn advance(self: *Runner) void {
        self.step += 1;
        self.phase = 0;
    }

    fn idle(frame: u64) ui.Input {
        return .{ .pointer = .init(-1, -1), .frame = frame };
    }
};

fn keySet(k: platform.Key) platform.key.KeySet {
    var set = platform.key.empty_keys;
    set.set(@intFromEnum(k));
    return set;
}

const testing = std.testing;

test "a click is three frames and a write is one per event's worth of text" {
    try testing.expectEqual(@as(u64, 4), frames(&.{.{ .click = .{ .target = .save } }}));
    try testing.expectEqual(@as(u64, 2), frames(&.{.{ .write = "abc" }}));
    var long: [platform.event.max_text_bytes * 2]u8 = @splat('x');
    try testing.expectEqual(@as(u64, 3), frames(&.{.{ .write = &long }}));
}

test "a step whose control was not drawn is skipped, not aimed blindly" {
    const targets: Targets = .{};
    var runner: Runner = .init(&.{ .{ .click = .{ .target = .save } }, .idle });
    const input = runner.next(&targets, 1);
    try testing.expect(!input.pointerPressed());
    try testing.expectEqual(@as(usize, 1), runner.step);
}

test "a click presses and releases at the rectangle the client recorded" {
    var targets: Targets = .{};
    targets.save = .{ .x = 100, .y = 40, .w = 60, .h = 20 };
    var runner: Runner = .init(&.{.{ .click = .{ .target = .save } }});

    const hover = runner.next(&targets, 1);
    try testing.expectEqual(@as(f32, 108), hover.pointer.x);
    try testing.expect(!hover.pointerHeld());
    try testing.expect(runner.next(&targets, 2).pointerPressed());
    try testing.expect(runner.next(&targets, 3).pointerReleased());
    try testing.expect(runner.done());
}

test "typed text is delivered as a real text event at the focused control" {
    const targets: Targets = .{};
    var runner: Runner = .init(&.{.{ .write = "hi" }});
    const input = runner.next(&targets, 1);
    try testing.expectEqual(@as(usize, 1), input.text.len);
    try testing.expectEqualStrings("hi", input.text[0].text());
}

test "a plan file is the same actions, written down beside the package" {
    var err: ParseError = .{};
    const plan = try parse(testing.allocator,
        \\# the manifest
        \\click new_package
        \\enter form_field_0 demo:pack
        \\click field:3
        \\key backspace
        \\idle
    , &err);
    defer testing.allocator.free(plan);

    try testing.expectEqual(Click{ .target = .new_package }, plan[0].click);
    try testing.expectEqual(Click{ .target = .form_field_0 }, plan[1].click);
    try testing.expectEqual(platform.Key.end, plan[2].key);
    try testing.expectEqual(platform.Key.backspace, plan[3].key);
    try testing.expectEqualStrings("demo:pack", plan[3 + clear_strokes].write);
    try testing.expectEqual(Action.idle, plan[4 + clear_strokes]);
    try testing.expectEqual(Click{ .target = .field, .row = 3 }, plan[5 + clear_strokes].click);
    try testing.expectEqual(platform.Key.backspace, plan[6 + clear_strokes].key);
    try testing.expectEqual(Action.idle, plan[7 + clear_strokes]);
    try testing.expectEqual(@as(usize, 8 + clear_strokes), plan.len);
}

test "a plan that does not make sense names the line that did not" {
    const cases = [_][]const u8{
        "hover save",
        "click no_such_control",
        "click field:x",
        "key no_such_key",
        "idle please",
        "write",
        "enter save",
    };
    for (cases) |text| {
        var err: ParseError = .{};
        try testing.expectError(error.BadPlan, parse(testing.allocator, text, &err));
        try testing.expectEqual(@as(u32, 1), err.line);
    }
}

test "a row-relative target reads the row a plan asked for" {
    var targets: Targets = .{};
    targets.row_count = 2;
    targets.rows[1].apply = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try testing.expectEqual(@as(f32, 10), Target.field_apply.rect(&targets, 1).?.x);
    try testing.expect(Target.field_apply.rect(&targets, 0) == null);
    // Past the rows the frame actually drew is "not drawn", not the last row again.
    try testing.expect(Target.field_apply.rect(&targets, 7) == null);
}
