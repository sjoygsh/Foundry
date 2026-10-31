//! Animation, as a game reports it (`animation-logic.md` §8).
//!
//! **Only what a game hands over.** `app` owns no player and no rig, so the overlay has none to ask:
//! `Sources.animation` is an `anim.Report`, a value the game fills. A panel with no report says so,
//! because a panel that vanishes is indistinguishable from a panel nobody wrote. It has no write
//! path: it holds a const pointer to a value with no pointers in it, so nothing it could reach leads
//! back to a player.
//!
//! Joints drawn in the world are a view, and M111's preview owns those.

const std = @import("std");

const anim = @import("anim");
const ui = @import("ui");

const overlay = @import("overlay.zig");
const View = overlay.View;

pub const State = struct {
    pub fn describe(_: ?*anyopaque, view: *View) anyerror!void {
        const r = view.sources.animation orelse {
            try view.line("no animation reported (debug.Sources.animation)", .{});
            return;
        };
        if (r.players == 0) {
            try view.line("no players", .{});
            return;
        }
        try view.line("{d} player(s)  {d} event(s) this tick", .{ r.players, r.events });
        if (r.dropped != 0) try view.line("WARNING: {d} event(s) dropped this tick", .{r.dropped});
        if (r.lost != 0) try view.line("WARNING: {d} channel(s) emptied this tick", .{r.lost});

        const rows = r.rows[0..@min(r.row_count, r.rows.len)];
        for (rows) |*row| {
            try view.line("{s}  {d} event(s)", .{ row.label(), row.events });
            const moved = row.motion.translation.length();
            if (moved != 0 or row.motion.yaw != 0) {
                try view.line("  moved {d:.4} m  turned {d:.4} rad", .{ moved, row.motion.yaw });
            }
            for (row.channels[0..@min(row.channel_count, row.channels.len)]) |*channel| {
                try view.line("  {s}  {d:.2} / {d:.2} s  weight {d:.2}  speed {d:.2}", .{
                    channel.label(),
                    channel.time,
                    channel.duration,
                    channel.weight,
                    channel.speed,
                });
            }
        }
        if (r.players > rows.len) try view.line("and {d} more", .{r.players - rows.len});
    }
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    ctx: ui.Context,

    fn init(self: *Harness) void {
        self.arena = .init(testing.allocator);
        self.ctx = ui.Context.init(testing.allocator, overlay.testStyle());
        self.ctx.begin(.{}, .init(0, 0, 500, 400));
    }

    fn deinit(self: *Harness) void {
        self.ctx.deinit();
        self.arena.deinit();
    }

    fn describe(self: *Harness, report: ?*const anim.Report) !void {
        var view: View = .{ .ui = &self.ctx, .arena = self.arena.allocator(), .frame = .{}, .sources = .{ .animation = report } };
        try State.describe(null, &view);
        self.ctx.end();
    }
};

fn holdsPointer(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => return true,
        .array => |array| return holdsPointer(array.child),
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (holdsPointer(field.type)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn name(comptime Row: type, text: []const u8) Row {
    var row: Row = .{};
    @memcpy(row.name[0..text.len], text);
    row.name_len = @intCast(text.len);
    return row;
}

test "a game with no animation is told so" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try h.describe(null);
    try testing.expect(overlay.findText(&h.ctx, "no animation reported"));
}

test "an empty report says there are no players" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const report: anim.Report = .{};
    try h.describe(&report);
    try testing.expect(overlay.findText(&h.ctx, "no players"));
    try testing.expect(!overlay.findText(&h.ctx, "player(s)"));
}

test "a report's players, channels, events and motion are printed" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var report: anim.Report = .{ .players = 2, .row_count = 2, .events = 3, .dropped = 4, .lost = 5 };
    report.rows[0] = name(anim.report.Row, "warden");
    report.rows[0].events = 2;
    report.rows[0].motion = .{ .translation = .init(0, 0, -0.03), .yaw = 0.0125 };
    report.rows[0].channel_count = 2;
    report.rows[0].channels[0] = name(anim.report.ChannelRow, "walk");
    report.rows[0].channels[0].time = 0.5;
    report.rows[0].channels[0].duration = 1.25;
    report.rows[0].channels[0].weight = 0.75;
    report.rows[0].channels[0].speed = 1.5;
    report.rows[0].channels[1] = name(anim.report.ChannelRow, "idle");
    report.rows[0].channels[1].weight = 0.25;
    report.rows[1] = name(anim.report.Row, "pacer");
    try h.describe(&report);
    for ([_][]const u8{
        "2 player(s)  3 event(s) this tick",
        "WARNING: 4 event(s) dropped this tick",
        "WARNING: 5 channel(s) emptied this tick",
        "warden  2 event(s)",
        "  moved 0.0300 m  turned 0.0125 rad",
        "  walk  0.50 / 1.25 s  weight 0.75  speed 1.50",
        "  idle  0.00 / 0.00 s  weight 0.25  speed 0.00",
        "pacer  0 event(s)",
    }) |text| try testing.expect(overlay.findText(&h.ctx, text));
    try testing.expect(!overlay.findText(&h.ctx, "more"));
}

test "a still player prints no move, and a tick that lost nothing warns of nothing" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var report: anim.Report = .{ .players = 1, .row_count = 1 };
    report.rows[0] = name(anim.report.Row, "pacer");
    try h.describe(&report);
    try testing.expect(!overlay.findText(&h.ctx, "moved"));
    try testing.expect(!overlay.findText(&h.ctx, "WARNING"));
}

test "a turn on the spot is a move" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var report: anim.Report = .{ .players = 1, .row_count = 1 };
    report.rows[0] = name(anim.report.Row, "pacer");
    report.rows[0].motion.yaw = -0.5;
    try h.describe(&report);
    try testing.expect(overlay.findText(&h.ctx, "moved 0.0000 m  turned -0.5000 rad"));
}

test "a straight walk is a move" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var report: anim.Report = .{ .players = 1, .row_count = 1 };
    report.rows[0] = name(anim.report.Row, "pacer");
    report.rows[0].motion.translation = .init(0.02, 0, 0);
    try h.describe(&report);
    try testing.expect(overlay.findText(&h.ctx, "moved 0.0200 m  turned 0.0000 rad"));
}

test "players past the rows are counted, and counts out of range read no further than the rows" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var report: anim.Report = .{ .players = 11, .row_count = 200 };
    for (&report.rows) |*row| {
        row.* = name(anim.report.Row, "pacer");
        row.name_len = 200;
        row.channel_count = 200;
        for (&row.channels) |*channel| channel.name_len = 200;
    }
    try h.describe(&report);
    try testing.expect(overlay.findText(&h.ctx, "and 3 more"));
}

test "the panel has no write path" {
    // `Sources` is the only way in, and what comes through it is const and holds no pointer that
    // could lead back to a player.
    try testing.expect(@FieldType(overlay.Sources, "animation") == ?*const anim.Report);
    try testing.expect(!holdsPointer(anim.Report));
}

test "the overlay's own panel reads the report it is handed" {
    const o = try overlay.Overlay.init(testing.allocator, .{});
    defer o.deinit();
    o.toggle("animation");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 800, 600));
    var report: anim.Report = .{ .players = 1, .row_count = 1 };
    report.rows[0] = name(anim.report.Row, "pacer");
    try o.describeIn(&ctx, .{}, arena.allocator(), .{ .animation = &report });
    ctx.end();
    try testing.expect(overlay.findText(&ctx, "pacer  0 event(s)"));
}
