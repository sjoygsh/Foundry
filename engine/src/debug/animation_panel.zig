//! Animation, as a game reports it (`animation-logic.md` §8).
//!
//! **Only what a game hands over.** `app` owns no player and no rig, so the overlay has none to ask:
//! `Sources.animation` is an `anim.Report`, a value the game fills. A panel with no report says so,
//! because a panel that vanishes is indistinguishable from a panel nobody wrote. It has no write
//! path: it holds a const pointer to a value with no pointers in it, so nothing it could reach leads
//! back to a player.
//!
//! A figure a machine steers prints its layers, each with its mode, mask, weight and state, and the
//! machine's parameters, all by the names content gave them (`animation-states.md` §11). Watching a
//! parameter cross a threshold and the state change on that tick is what it is for. A bare player
//! prints as it did in M34.
//!
//! A channel playing a blend prints where the blend sits and each clip it mixes there, and a figure
//! whose game added its feet and gaze prints each leg's offset, contact and lock, the pelvis's drop,
//! and each aim chain's weight (`animation-ik.md` §10). Watching a contact flicker, or an offset
//! settle on a step, is what those are for.
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
        if (r.transitions != 0) try view.line("{d} transition(s) this tick", .{r.transitions});
        if (r.reentered != 0) try view.line("WARNING: {d} layer(s) in a state their machine lacks, begun again", .{r.reentered});
        if (r.params_dropped != 0) try view.line("WARNING: {d} saved parameter(s) their machine lacks, dropped", .{r.params_dropped});

        const rows = r.rows[0..@min(r.row_count, r.rows.len)];
        for (rows) |*row| {
            try view.line("{s}  {d} event(s)", .{ row.label(), row.events });
            const moved = row.motion.translation.length();
            if (moved != 0 or row.motion.yaw != 0) {
                try view.line("  moved {d:.4} m  turned {d:.4} rad", .{ moved, row.motion.yaw });
            }
            const layers = row.layers[0..@min(row.layer_count, row.layers.len)];
            if (!row.machine) {
                if (layers.len != 0) try channels(view, &layers[0], "  ");
                try ik(view, row);
                continue;
            }
            for (layers, 0..) |*layer, i| {
                const called = layer.label();
                const state = layer.stateLabel();
                const mask = layer.maskLabel();
                try view.line("  {s}{s}  {t}{s}{s}  weight {d:.2}  state {s} ({d} tick(s))", .{
                    if (called.len == 0) "layer " else called,
                    if (called.len == 0) &[_]u8{'0' + @as(u8, @intCast(i))} else "",
                    layer.mode,
                    if (mask.len == 0) "" else "  mask ",
                    mask,
                    layer.weight,
                    if (state.len == 0) "?" else state,
                    layer.state_ticks,
                });
                try channels(view, layer, "    ");
            }
            for (row.params[0..@min(row.param_count, row.params.len)]) |*param| {
                try view.line("  {s} = {d:.2}", .{ param.label(), param.value });
            }
            try ik(view, row);
        }
        if (r.players > rows.len) try view.line("and {d} more", .{r.players - rows.len});
    }
};

fn channels(view: *View, layer: *const anim.report.LayerRow, indent: []const u8) !void {
    for (layer.channels[0..@min(layer.channel_count, layer.channels.len)]) |*channel| {
        try view.line("{s}{s}  {d:.2} / {d:.2} s  weight {d:.2}  speed {d:.2}", .{
            indent,
            channel.label(),
            channel.time,
            channel.duration,
            channel.weight,
            channel.speed,
        });
        if (!channel.blend()) continue;
        if (channel.axes == 2) {
            try view.line("{s}  at {d:.2}, {d:.2}", .{ indent, channel.at[0], channel.at[1] });
        } else {
            try view.line("{s}  at {d:.2}", .{ indent, channel.at[0] });
        }
        for (channel.members[0..@min(channel.member_count, channel.members.len)]) |*member| {
            try view.line("{s}  + {s}  weight {d:.2}", .{ indent, member.label(), member.weight });
        }
    }
}

/// A figure's feet and gaze, if its game added them.
fn ik(view: *View, row: *const anim.report.Row) !void {
    if (row.feet) {
        try view.line("  pelvis {d:.3} m", .{row.pelvis});
        for (row.legs[0..@min(row.leg_count, row.legs.len)]) |*leg| {
            try view.line("  leg {s}  offset {d:.3} m  contact {d:.2}  lock {d:.2}", .{ leg.label(), leg.offset, leg.contact, leg.lock });
        }
    }
    for (row.aims[0..@min(row.aim_count, row.aims.len)]) |*aim| {
        try view.line("  aim {s}  weight {d:.2}{s}", .{ aim.label(), aim.weight, if (aim.beyond) "  past its limit" else "" });
    }
}

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
    report.rows[0].layer_count = 1;
    const base = &report.rows[0].layers[0];
    base.channel_count = 2;
    base.channels[0] = name(anim.report.ChannelRow, "walk");
    base.channels[0].time = 0.5;
    base.channels[0].duration = 1.25;
    base.channels[0].weight = 0.75;
    base.channels[0].speed = 1.5;
    base.channels[1] = name(anim.report.ChannelRow, "idle");
    base.channels[1].weight = 0.25;
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
    // A bare player's row has no layer, state or parameter lines.
    try testing.expect(!overlay.findText(&h.ctx, "state"));
    try testing.expect(!overlay.findText(&h.ctx, "override"));
    try testing.expect(!overlay.findText(&h.ctx, "transition"));
}

test "a figure a machine steers prints its layers, states and parameters by name" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var report: anim.Report = .{ .players = 1, .row_count = 1, .transitions = 1, .reentered = 2, .params_dropped = 3 };
    const row = &report.rows[0];
    row.* = name(anim.report.Row, "warden");
    row.machine = true;
    row.layer_count = 3;
    row.layers[0] = name(anim.report.LayerRow, "body");
    @memcpy(row.layers[0].state[0..3], "run");
    row.layers[0].state_len = 3;
    row.layers[0].state_ticks = 12;
    row.layers[0].channel_count = 1;
    row.layers[0].channels[0] = name(anim.report.ChannelRow, "run");
    row.layers[0].channels[0].duration = 0.7;
    row.layers[0].channels[0].weight = 1;
    row.layers[0].channels[0].speed = 1.25;
    row.layers[1] = name(anim.report.LayerRow, "arms");
    @memcpy(row.layers[1].mask[0..5], "upper");
    row.layers[1].mask_len = 5;
    row.layers[1].weight = 0.5;
    // No names: the panel says which layer, and that its state has none.
    row.layers[2] = .{ .mode = .additive, .weight = 0 };
    row.param_count = 2;
    row.params[0] = name(anim.report.ParamRow, "speed");
    row.params[0].value = 2.4;
    row.params[1] = name(anim.report.ParamRow, "near");
    row.params[1].value = 1;
    try h.describe(&report);
    for ([_][]const u8{
        "1 transition(s) this tick",
        "WARNING: 2 layer(s) in a state their machine lacks, begun again",
        "WARNING: 3 saved parameter(s) their machine lacks, dropped",
        "warden  0 event(s)",
        "  body  override  weight 1.00  state run (12 tick(s))",
        "    run  0.00 / 0.70 s  weight 1.00  speed 1.25",
        "  arms  override  mask upper  weight 0.50  state ? (0 tick(s))",
        "  layer 2  additive  weight 0.00  state ? (0 tick(s))",
        "  speed = 2.40",
        "  near = 1.00",
    }) |text| try testing.expect(overlay.findText(&h.ctx, text));
}

test "a blend prints its place and its clips, and a figure's feet and gaze print by name" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var report: anim.Report = .{ .players = 2, .row_count = 2 };
    const row = &report.rows[0];
    row.* = name(anim.report.Row, "warden");
    row.layer_count = 1;
    const base = &row.layers[0];
    base.channel_count = 1;
    base.channels[0] = name(anim.report.ChannelRow, "move");
    base.channels[0].duration = 0.85;
    base.channels[0].weight = 1;
    base.channels[0].speed = 1;
    base.channels[0].at = .{ 1.43, 0 };
    base.channels[0].axes = 1;
    base.channels[0].member_count = 2;
    base.channels[0].members[0] = name(anim.report.MemberRow, "walk");
    base.channels[0].members[0].weight = 0.5;
    base.channels[0].members[1] = name(anim.report.MemberRow, "run");
    base.channels[0].members[1].weight = 0.5;
    row.feet = true;
    row.pelvis = -0.12;
    row.leg_count = 2;
    row.legs[0] = name(anim.report.LegRow, "left");
    row.legs[0].offset = -0.12;
    row.legs[0].contact = 1;
    row.legs[0].lock = 0.5;
    row.legs[1] = name(anim.report.LegRow, "right");
    row.aim_count = 1;
    row.aims[0] = name(anim.report.AimRow, "head");
    row.aims[0].weight = 0.25;
    row.aims[0].beyond = true;

    const strafer = &report.rows[1];
    strafer.* = name(anim.report.Row, "strafer");
    strafer.layer_count = 1;
    strafer.layers[0].channel_count = 1;
    strafer.layers[0].channels[0] = name(anim.report.ChannelRow, "strafe");
    strafer.layers[0].channels[0].axes = 2;
    strafer.layers[0].channels[0].at = .{ -0.5, 1 };
    try h.describe(&report);
    for ([_][]const u8{
        "  move  0.00 / 0.85 s  weight 1.00  speed 1.00",
        "    at 1.43",
        "    + walk  weight 0.50",
        "    + run  weight 0.50",
        "  pelvis -0.120 m",
        "  leg left  offset -0.120 m  contact 1.00  lock 0.50",
        "  leg right  offset 0.000 m  contact 0.00  lock 0.00",
        "  aim head  weight 0.25  past its limit",
        "    at -0.50, 1.00",
    }) |text| try testing.expect(overlay.findText(&h.ctx, text));
}

test "a figure with no feet or gaze added prints none" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    var report: anim.Report = .{ .players = 1, .row_count = 1 };
    report.rows[0] = name(anim.report.Row, "pacer");
    try h.describe(&report);
    try testing.expect(!overlay.findText(&h.ctx, "pelvis"));
    try testing.expect(!overlay.findText(&h.ctx, "aim "));
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
        row.machine = true;
        row.layer_count = 200;
        row.param_count = 200;
        for (&row.params) |*param| param.name_len = 200;
        for (&row.layers) |*layer| {
            layer.name_len = 200;
            layer.mask_len = 200;
            layer.state_len = 200;
            layer.channel_count = 200;
            for (&layer.channels) |*channel| {
                channel.name_len = 200;
                channel.axes = 1;
                channel.member_count = 200;
                for (&channel.members) |*member| member.name_len = 200;
            }
        }
        row.feet = true;
        row.leg_count = 200;
        for (&row.legs) |*leg| leg.name_len = 200;
        row.aim_count = 200;
        for (&row.aims) |*aim| aim.name_len = 200;
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
