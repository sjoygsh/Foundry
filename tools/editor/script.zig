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
//! The application's script walks the regions, types into the filter and reaches the first
//! row of each list; the workflow that creates and edits named records is test code, where
//! knowing a fixture's names is allowed.

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
    list_remove,
    list_down,
    boolean,
    record_delete,
    record_duplicate,
    dependency_override,
    first_dependency_record,
    confirm_save,
    confirm_discard,
    confirm_cancel,
    document_refresh,
    document_discard,

    pub fn rect(self: Target, targets: *const Targets) ?editor_client.Rect {
        return switch (self) {
            .new_package => targets.new_package,
            .new_record => targets.new_record,
            .new_document => targets.new_document,
            .save => targets.save,
            .save_all => targets.save_all,
            .validate => targets.validate,
            .build => targets.build,
            .reload => targets.reload,
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
            .field => targets.rows[0].control,
            .field_apply => targets.rows[0].apply,
            .field_reset => targets.rows[0].reset,
            .list_add => targets.rows[0].add,
            .list_remove => targets.rows[0].remove,
            .list_down => targets.rows[0].down,
            .boolean => targets.rows[0].control,
            .record_delete => targets.record_delete,
            .record_duplicate => targets.record_duplicate,
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

pub const Action = union(enum) {
    /// Hover, press, release — three frames, because that is what a real click is and the
    /// kernel's hot/active model is written against the edges rather than a state.
    click: Target,
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
    .{ .click = .first_document },
    .{ .click = .first_record },
    .idle,
    .{ .click = .field },
    .{ .write = "0" },
    .{ .key = .backspace },
    .idle,
    .{ .click = .filter },
    .{ .write = "e" },
    .idle,
    .{ .key = .backspace },
    .idle,
    .{ .click = .tab_dependencies },
    .{ .click = .first_dependency_record },
    .idle,
    .{ .click = .tab_schemas },
    .idle,
    .{ .click = .tab_preview },
    .idle,
    .{ .click = .tab_assets },
    .idle,
    .{ .click = .tab_source },
    .{ .click = .validate },
    .idle,
};

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
            .click => |target| {
                if (self.phase == 0) {
                    const bounds = target.rect(targets) orelse {
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
    try testing.expectEqual(@as(u64, 4), frames(&.{.{ .click = .save }}));
    try testing.expectEqual(@as(u64, 2), frames(&.{.{ .write = "abc" }}));
    var long: [platform.event.max_text_bytes * 2]u8 = @splat('x');
    try testing.expectEqual(@as(u64, 3), frames(&.{.{ .write = &long }}));
}

test "a step whose control was not drawn is skipped, not aimed blindly" {
    const targets: Targets = .{};
    var runner: Runner = .init(&.{ .{ .click = .save }, .idle });
    const input = runner.next(&targets, 1);
    try testing.expect(!input.pointerPressed());
    try testing.expectEqual(@as(usize, 1), runner.step);
}

test "a click presses and releases at the rectangle the client recorded" {
    var targets: Targets = .{};
    targets.save = .{ .x = 100, .y = 40, .w = 60, .h = 20 };
    var runner: Runner = .init(&.{.{ .click = .save }});

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
