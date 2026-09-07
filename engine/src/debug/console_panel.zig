//! The log console (`debug-overlay.md` §6): a filter box over the in-memory log ring.
//!
//! The ring is `app.log_sink`'s and is ambient, because `std.log` reaches it from code that
//! has no engine pointer to ask. This panel is a reader of it and nothing more.
//!
//! It is also §11's windowing convention's first user and the case that convention was
//! written for: the ring holds up to a thousand lines and a handful are on screen, so the
//! caller emits only the visible rows and stands two `spacer`s in for the rest. The work
//! skipped is the *formatting*, which is what a kernel-side cull could never have reached.

const std = @import("std");
const Allocator = std.mem.Allocator;

const app = @import("app");
const core = @import("core");
const ui = @import("ui");

const overlay = @import("overlay.zig");
const View = overlay.View;

/// How wide the filter box's storage is. A debug filter is a word or two; the field is
/// caller-owned and does not allocate, which is the whole reason it has a size at all.
pub const filter_capacity = 48;

/// The most rows formatted in one frame, however tall the panel is. A bound on the work,
/// not on the list: `total` is still the ring's and the scroll bar still says so.
pub const max_rows = 64;

pub const State = struct {
    filter: [filter_capacity]u8 = @splat(0),
    filter_len: usize = 0,

    pub fn describe(ctx: ?*anyopaque, view: *View) anyerror!void {
        const self: *State = @ptrCast(@alignCast(ctx.?));
        const style = view.ui.style;

        if (app.log_sink.captureLevel() == null) {
            try view.line("log capture off (Config.log_capture)", .{});
            return;
        }

        // Typing here must not also walk the player or resize the window, which is what
        // `Context.wantsKeyboard` is for and what the game checks before reading a key.
        _ = try ui.textField(view.ui, view.ui.childId("filter"), &self.filter, &self.filter_len);

        const list_id = view.ui.childId("lines");
        const row = view.row();
        // One row is kept back for the footer, and the area is **reserved** from the
        // enclosing region rather than merely read: `beginScroll` places itself at the
        // rectangle it is handed and does not advance the cursor, so a footer described
        // after `endScroll` would otherwise land on top of the list's first line.
        const list_height = @max(row, view.ui.region().remaining().h - row);
        const area = view.ui.region().take(list_height);
        const capacity = @min(max_rows, overlay.rowsIn(list_height, row));

        const records = try view.arena.alloc(app.LogRecord, capacity);
        // Last frame's offset, which is this frame's, read *before* `beginScroll`.
        const scroll = @max(0, view.ui.stateOf(list_id).scroll);
        const first: usize = @intFromFloat(@floor(scroll / row));

        const page = app.log_sink.readView(
            view.arena,
            records,
            .{ .contains = self.filter[0..self.filter_len] },
            first,
        ) catch app.LogView{ .total = 0, .records = records[0..0] };

        const window = overlay.Window{
            .first = @min(first, page.total),
            .count = page.records.len,
            .total = page.total,
            .row = row,
        };

        try ui.beginScroll(view.ui, list_id, area, window.contentHeight());
        ui.spacer(view.ui, window.before());
        for (page.records) |record| {
            try view.line("{d} {t} {s}: {s}", .{ record.frame, record.level, record.scope, record.text });
        }
        ui.spacer(view.ui, window.after());
        try ui.endScroll(view.ui);

        try ui.beginRow(view.ui, view.ui.childId("footer"), style.line_height);
        try view.line("{d} lines, {d} dropped", .{ page.total, app.log_sink.dropped() });
        // Not introspection, and not a back door: `clear` is public, and the drop count
        // survives it because that is a fact about the run rather than about the view.
        if (try ui.button(view.ui, view.ui.childId("clear"), "clear")) app.log_sink.clear();
        ui.endRow(view.ui);
    }
};

// -- tests -----------------------------------------------------------------------------
//
// The ring is process-wide, so these tests set it up and tear it down around themselves.
// That is the cost of the thing being ambient, and it is the same cost `log_sink`'s own
// tests already pay.

const testing = std.testing;

fn describeInto(state: *State, ctx: *ui.Context) !void {
    var test_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer test_arena.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 400));
    var view: View = .{ .ui = ctx, .arena = test_arena.allocator(), .frame = .{}, .sources = .{} };
    try ui.beginPanel(ctx, ui.Id.root.child("console"), .init(0, 0, 600, 400));
    try State.describe(state, &view);
    try ui.endPanel(ctx);
    ctx.end();
}

test "the console shows only the lines passing the filter" {
    app.log_sink.setCaptureLevel(.trace);
    defer app.log_sink.setCaptureLevel(null);
    // The ring and the terminal are two independent filters (§6.3), which is what lets a
    // test fill one without printing to the other.
    app.log_sink.setLevel(.err);
    defer app.log_sink.setLevel(.info);
    app.log_sink.clear();

    // Written through the sink's own entry point rather than through `std.log`, because
    // `std.log` reaches `logFn` only when the *root* source file installs `std_options` —
    // and this test binary's root is `debug`, not a game's. This is the same call the
    // installed hook makes.
    app.log_sink.logFn(.info, .console_test, "a torch was lit", .{});
    app.log_sink.logFn(.info, .console_test, "a door was opened", .{});
    app.log_sink.logFn(.info, .console_test, "another torch", .{});

    var state: State = .{};
    @memcpy(state.filter[0..5], "torch");
    state.filter_len = 5;

    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    try describeInto(&state, &ctx);

    try testing.expect(overlay.findText(&ctx, "a torch was lit"));
    try testing.expect(overlay.findText(&ctx, "another torch"));
    try testing.expect(!overlay.findText(&ctx, "a door was opened"));
    try testing.expect(overlay.findText(&ctx, "2 lines, 0 dropped"));
}

test "a ten-thousand line log does not emit ten thousand draw commands" {
    app.log_sink.setCaptureLevel(.trace);
    defer app.log_sink.setCaptureLevel(null);
    app.log_sink.setLevel(.err);
    defer app.log_sink.setLevel(.info);
    app.log_sink.clear();

    // More lines than the ring holds, which is the point: the ring keeps its last thousand
    // and the panel formats a screenful of those.
    for (0..10_000) |i| app.log_sink.logFn(.info, .console_test, "line {d}", .{i});

    var state: State = .{};
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    try describeInto(&state, &ctx);

    // §11's claim, as an assertion: the cost is bounded by what is on screen and not by
    // what the list holds. The footer, the filter's contents and the clear button are text
    // commands too, hence a bound rather than an equality.
    try testing.expect(overlay.countText(&ctx) <= max_rows + 8);

    // And the list really did hold a great many more than it drew. The ring keeps what
    // fits — it is bounded in *bytes* as well as in records, which is why this is a range
    // rather than a number.
    const live = app.log_sink.count();
    try testing.expect(live > 100);
    try testing.expect(live <= 1024);
    const footer = try std.fmt.allocPrint(
        testing.allocator,
        "{d} lines, {d} dropped",
        .{ live, app.log_sink.dropped() },
    );
    defer testing.allocator.free(footer);
    try testing.expect(overlay.findText(&ctx, footer));
}

test "the console says so when nothing is being captured" {
    app.log_sink.setCaptureLevel(null);

    var state: State = .{};
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    try describeInto(&state, &ctx);

    try testing.expect(overlay.findText(&ctx, "log capture off"));
}
