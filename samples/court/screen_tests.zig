//! M26 Step 4: the phases a menu drives, the screens, the sound set, the text and the
//! preferences, against the compiled package and with no window or device.
const std = @import("std");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const platform = @import("platform");
const ui = @import("ui");
const game_mod = @import("game.zig");
const walk_mod = @import("walk.zig");
const menus_mod = @import("menus.zig");
const hud = @import("hud.zig");
const sounds_mod = @import("sounds.zig");
const Preferences = @import("prefs.zig").Preferences;
const Text = @import("text.zig").Text;
const Settings = @import("settings.zig").Settings;
const game_tests = @import("game_tests.zig");
const options = @import("court_test_options");
const testing = std.testing;

const TestEnv = game_tests.TestEnv;
const dt = game_tests.dt;
const Vec2 = core.math.Vec2;

test "court: a phase changes only by its own action, and a paused game is paused exactly" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    const busy: walk_mod.Intent = .{ .direction = .forward, .jump = true, .use = true, .look_dx = 40 };

    // The title: the world does not run, whatever the hands do, and only Play leaves it.
    const at_title = game.hashTick();
    for (0..30) |_| try game.step(busy, dt);
    try testing.expectEqual(at_title, game.hashTick());
    for ([_]walk_mod.Action{ .pause, .unpause, .restart, .title }) |action| {
        try game.step(.{ .action = action }, dt);
        try testing.expectEqual(game_mod.Phase.title, game.phase);
    }
    try game.step(.{ .action = .play }, dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    try testing.expectEqual(@as(u64, 0), game.tick);

    // Playing: Play, Resume, Restart and Title are not offered and do nothing.
    for (0..20) |_| try game.step(.{ .direction = .forward }, dt);
    try testing.expectEqual(@as(u64, 20), game.tick);
    for ([_]walk_mod.Action{ .play, .unpause, .restart, .title }) |action| {
        const before = game.hashTick();
        try game.step(.{ .action = action, .direction = .forward }, dt);
        try testing.expectEqual(game_mod.Phase.playing, game.phase);
        // The action is the whole tick: the world did not also move.
        try testing.expectEqual(before, game.hashTick());
    }

    // Paused: nothing moves, however long and whatever is pressed. The warden too.
    const warden = game.warden.?.feet;
    try game.step(.{ .action = .pause }, dt);
    try testing.expectEqual(game_mod.Phase.paused, game.phase);
    const paused = game.hashTick();
    for (0..240) |_| try game.step(busy, dt);
    try testing.expectEqual(paused, game.hashTick());
    try testing.expectEqualDeep(warden, game.warden.?.feet);
    try testing.expectEqual(@as(usize, 0), game.tickEvents().len);
    try game.step(.{ .action = .play }, dt);
    try testing.expectEqual(game_mod.Phase.paused, game.phase);
    try game.step(.{ .action = .unpause }, dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    try testing.expectEqual(@as(u64, 20), game.tick);

    // From a pause: Restart begins again, Title goes back with the world reset.
    try game.step(.{ .action = .pause }, dt);
    try game.step(.{ .action = .restart }, dt);
    try testing.expectEqual(game_mod.Phase.playing, game.phase);
    try testing.expectEqual(@as(u64, 0), game.tick);
    for (0..20) |_| try game.step(.{ .direction = .forward }, dt);
    try game.step(.{ .action = .pause }, dt);
    try game.step(.{ .action = .title }, dt);
    try testing.expectEqual(game_mod.Phase.title, game.phase);
    try testing.expectEqual(at_title, game.hashTick());

    // From an end screen: Pause and Resume do nothing; Restart and Title work.
    try game.step(.{ .action = .play }, dt);
    try game.walk.teleport(.init(0, game.rules.?.pit_height - 1, -2.6));
    try game.step(.{}, dt);
    try testing.expectEqual(game_mod.Phase.fell, game.phase);
    for ([_]walk_mod.Action{ .pause, .unpause, .play }) |action| {
        try game.step(.{ .action = action }, dt);
        try testing.expectEqual(game_mod.Phase.fell, game.phase);
    }
    try game.step(.{ .action = .title }, dt);
    try testing.expectEqual(game_mod.Phase.title, game.phase);
    try testing.expectEqual(at_title, game.hashTick());
}

test "court: a menu action latched in one frame reaches exactly one tick" {
    var pending: walk_mod.Pending = .{};
    pending.feed(.{ .action = .pause });
    // A frame with no tick, then another frame's input: the press is still there.
    pending.feed(.{ .direction = .right });
    const first = pending.take();
    try testing.expectEqual(walk_mod.Action.pause, first.action);
    try testing.expectEqual(walk_mod.Action.none, pending.take().action);
    // A later choice replaces an earlier one that no tick has seen.
    pending.feed(.{ .action = .pause });
    pending.feed(.{ .action = .restart });
    try testing.expectEqual(walk_mod.Action.restart, pending.take().action);
}

test "court: footsteps follow the ground walked, and an event the buffer cannot hold is counted" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.initPlaying(gpa);
    defer env.deinit(gpa);
    const game = &env.game;
    try game.walk.teleport(.init(4.5, 0.004, 6.5));
    for (0..5) |_| try game.step(.{}, dt);

    // No stride, no steps: what is heard is presentation's to ask for.
    var steps: u32 = 0;
    for (0..60) |_| {
        try game.step(.{ .direction = .init(-1, 0, 0) }, dt);
        for (game.tickEvents()) |e| steps += @intFromBool(e.kind == .step);
    }
    try testing.expectEqual(@as(u32, 0), steps);

    // Three metres a second for a little over a second, a step every metre: three steps.
    game.stride = 1;
    game.walked = 0;
    for (0..70) |_| {
        try game.step(.{ .direction = .right }, dt);
        for (game.tickEvents()) |e| steps += @intFromBool(e.kind == .step);
    }
    try testing.expectEqual(@as(u32, 3), steps);
    // Standing still is silent, and so is the air.
    steps = 0;
    for (0..60) |_| {
        try game.step(.{}, dt);
        for (game.tickEvents()) |e| steps += @intFromBool(e.kind == .step);
    }
    try testing.expectEqual(@as(u32, 0), steps);

    // A jump and its landing are each said once.
    var jumps: u32 = 0;
    var lands: u32 = 0;
    try game.step(.{ .jump = true }, dt);
    for (game.tickEvents()) |e| jumps += @intFromBool(e.kind == .jump);
    for (0..90) |_| {
        try game.step(.{}, dt);
        for (game.tickEvents()) |e| {
            jumps += @intFromBool(e.kind == .jump);
            lands += @intFromBool(e.kind == .land);
        }
    }
    try testing.expectEqual(@as(u32, 1), jumps);
    try testing.expectEqual(@as(u32, 1), lands);

    // The presentation's strides never reach the outcome's hash.
    var other = try TestEnv.initPlaying(gpa);
    defer other.deinit(gpa);
    other.game.stride = 0.3;
    other.game.warden_stride = 0.2;
    var plain = try TestEnv.initPlaying(gpa);
    defer plain.deinit(gpa);
    for (0..200) |_| {
        try other.game.step(.{ .direction = .forward }, dt);
        try plain.game.step(.{ .direction = .forward }, dt);
        try testing.expectEqual(plain.game.hashTick(), other.game.hashTick());
    }

    // The buffer is bounded and says when it was not enough. A tick emits at most one of
    // each kind, which fits; the bound is for whatever a later step adds.
    try testing.expectEqual(@as(u32, 0), game.events_dropped);
    try game.step(.{}, dt);
    for (0..game_mod.Game.max_events) |_| game.emit(.{ .kind = .step });
    try testing.expectEqual(game_mod.Game.max_events, game.tickEvents().len);
    try testing.expectEqual(@as(u32, 0), game.events_dropped);
    game.emit(.{ .kind = .won });
    game.emit(.{ .kind = .won });
    try testing.expectEqual(game_mod.Game.max_events, game.tickEvents().len);
    try testing.expectEqual(@as(u32, 2), game.events_dropped);
    for (game.tickEvents()) |e| try testing.expectEqual(game_mod.Event.Kind.step, e.kind);
    // The next tick starts empty.
    try game.step(.{}, dt);
    try testing.expectEqual(@as(usize, 0), game.tickEvents().len);
}

test "court: the sound set names real sounds, and refuses missing, non-finite and out-of-bounds fields" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);
    const set = sounds_mod.SoundSet.find(&env.store).?;
    // Every sound an event can play is a `foundry:sound` in the package: a name typed
    // wrong in the record would otherwise be found only by ear.
    const ids = [_]core.ContentId{ set.ambience, set.step, set.jump, set.land, set.gate, set.warden_step, set.won, set.caught, set.fell, set.click };
    for (ids) |sound| try testing.expect(env.store.lookup(sound).?.schema.id.eql(asset.schemas.sound.id));
    for (env.game.beacons[0..env.game.beacon_count]) |b| {
        try testing.expect(env.store.lookup(b.settings.sound).?.schema.id.eql(asset.schemas.sound.id));
    }

    const fields = env.store.lookup(core.ContentId.fromString(sounds_mod.SoundSet.record_id)).?.fields;
    const block = @constCast(fields.block);
    const saved = try gpa.dupe(u8, block);
    defer gpa.free(saved);
    for (fields.fields, 0..) |field, i| {
        block[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
        try testing.expectError(error.InvalidSounds, sounds_mod.SoundSet.read(fields));
        @memcpy(block, saved);
        const offset = fieldOffset(fields.fields, i);
        switch (field.type) {
            .f32 => for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -1, 1e9 }) |v| {
                std.mem.writeInt(u32, block[offset..][0..4], @bitCast(v), .little);
                try testing.expectError(error.InvalidSounds, sounds_mod.SoundSet.read(fields));
                @memcpy(block, saved);
            },
            .id => {
                std.mem.writeInt(u64, block[offset..][0..8], core.ContentId.none.hash, .little);
                try testing.expectError(error.InvalidSounds, sounds_mod.SoundSet.read(fields));
                @memcpy(block, saved);
            },
            else => {},
        }
    }
    _ = try sounds_mod.SoundSet.read(fields);
    // A refused set leaves the court silent, not stopped.
    block[0] &= ~@as(u8, 1);
    try testing.expectEqual(@as(?sounds_mod.SoundSet, null), sounds_mod.SoundSet.find(&env.store));
    @memcpy(block, saved);
}

test "court: every string comes from the text record, and a missing one shows its field's name" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);
    const text = Text.read(&env.store);
    inline for (@typeInfo(Text).@"struct".fields) |field| {
        const value = @field(text, field.name);
        try testing.expect(value.len != 0);
        // The record's string, not the placeholder.
        try testing.expect(!std.mem.eql(u8, value, field.name));
    }
    try testing.expectEqualStrings("The Court", text.title);

    const fields = env.store.lookup(core.ContentId.fromString(Text.record_id)).?.fields;
    const block = @constCast(fields.block);
    const play_index: usize = for (fields.fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, "play")) break i;
    } else unreachable;
    block[play_index / 8] &= ~(@as(u8, 1) << @intCast(play_index % 8));
    const partial = Text.read(&env.store);
    try testing.expectEqualStrings("play", partial.play);
    try testing.expectEqualStrings("The Court", partial.title);
    block[play_index / 8] |= @as(u8, 1) << @intCast(play_index % 8);
    // A string that is there but empty is no better than one that is missing. A string
    // field is an offset and a length; the length is the second half.
    const length = block[fieldOffset(fields.fields, play_index) + 4 ..][0..4];
    const old_length: [4]u8 = length.*;
    std.mem.writeInt(u32, length, 0, .little);
    try testing.expectEqualStrings("play", Text.read(&env.store).play);
    length.* = old_length;
    try testing.expectEqualStrings("Play", Text.read(&env.store).play);

    // No record at all: every screen still has words.
    var empty: data.Store = .init(gpa, .default);
    defer empty.deinit(gpa);
    const bare = Text.read(&empty);
    try testing.expectEqualStrings("title", bare.title);
    try testing.expectEqualStrings("resume", bare.@"resume");
}

fn fieldOffset(fields: []const data.schema.Field, index: usize) usize {
    var cursor: usize = data.fpk.presenceBytes(fields.len);
    for (fields, 0..) |field, i| {
        cursor = std.mem.alignForward(usize, cursor, data.fpk.alignOf(field.type));
        if (i == index) return cursor;
        cursor += data.fpk.sizeOf(field.type);
    }
    unreachable;
}

// -- the screens -----------------------------------------------------------------------

/// A kernel with the fallback look: enough to lay a screen out and hit-test it.
fn testContext(gpa: std.mem.Allocator) ui.Context {
    return .init(gpa, .{
        .font = .{ .cell = .init(8, 8) },
        .text_scale = 2,
        .line_height = 34,
        .padding = .init(14, 8),
        .spacing = 6,
        .text = .white,
        .text_dim = .linear(0.6, 0.6, 0.6, 1),
        .surface = .linear(0, 0, 0, 0.85),
        .control = .linear(0.1, 0.1, 0.1, 1),
        .control_hot = .linear(0.2, 0.2, 0.2, 1),
        .control_active = .linear(0.8, 0.8, 0.8, 1),
        .accent = .linear(0.5, 0.9, 0.7, 1),
    });
}

const size: Vec2 = .init(1280, 720);

fn describeAt(ctx: *ui.Context, view: hud.View, chosen: *menus_mod.Options, input: ui.Input) !hud.Result {
    ctx.begin(input, .init(0, 0, size.x, size.y));
    defer ctx.end();
    return hud.describe(ctx, view, chosen);
}

fn shows(ctx: *const ui.Context, wanted: []const u8) bool {
    for (ctx.list.items()) |command| switch (command) {
        .text => |t| if (std.mem.eql(u8, ctx.list.textOf(t.text), wanted)) return true,
        else => {},
    };
    return false;
}

/// The rectangle of the first nine-slice or rect drawn right before `label`'s text: the row.
fn rowCentre(ctx: *const ui.Context, label: []const u8) ?Vec2 {
    var last: ?core.math.Rect = null;
    for (ctx.list.items()) |command| switch (command) {
        .rect => |r| last = r.bounds,
        .nine_slice => |n| last = n.bounds,
        .text => |t| if (std.mem.eql(u8, ctx.list.textOf(t.text), label)) {
            const r = last orelse return null;
            return .init(r.x + r.w / 2, r.y + r.h / 2);
        },
        else => {},
    };
    return null;
}

test "court: each screen shows its own words, and the HUD shows the count, the goal and the prompt" {
    const gpa = testing.allocator;
    var ctx = testContext(gpa);
    defer ctx.deinit();
    const text: Text = .{};
    var menus: menus_mod.Menus = .{};
    var chosen: menus_mod.Options = .{};

    // The HUD while playing.
    _ = try describeAt(&ctx, .{ .phase = .playing, .menus = &menus, .text = &text, .lit = 1, .beacons = 3, .size = size }, &chosen, .{});
    try testing.expect(shows(&ctx, "1 / 3"));
    try testing.expect(shows(&ctx, text.beacons_lit) and shows(&ctx, text.objective) and shows(&ctx, text.pause_hint));
    try testing.expect(!shows(&ctx, text.use_prompt) and !shows(&ctx, text.goal) and !shows(&ctx, text.objective_gate));
    try testing.expect(!ctx.wantsPointer());
    // The goal line in a game's first seconds; the prompt when a beacon is in reach; the
    // gate's line once it opens; and a court with no gate says so.
    _ = try describeAt(&ctx, .{ .phase = .playing, .menus = &menus, .text = &text, .lit = 3, .beacons = 3, .aimed = true, .show_goal = true, .gate_open = true, .size = size }, &chosen, .{});
    try testing.expect(shows(&ctx, "3 / 3") and shows(&ctx, text.use_prompt) and shows(&ctx, text.use_key));
    try testing.expect(shows(&ctx, text.goal) and shows(&ctx, text.goal_detail) and shows(&ctx, text.objective_gate));
    _ = try describeAt(&ctx, .{ .phase = .playing, .menus = &menus, .text = &text, .beacons = 3, .has_gate = false, .show_goal = true, .size = size }, &chosen, .{});
    try testing.expect(shows(&ctx, text.no_gate) and !shows(&ctx, text.goal));

    // The title: the name, the goal in two sentences, the controls, and three rows.
    _ = menus.update(.title, .{}, null, null, &chosen);
    _ = try describeAt(&ctx, .{ .phase = .title, .menus = &menus, .text = &text, .size = size }, &chosen, .{});
    for ([_][]const u8{ text.title, text.goal, text.goal_detail, text.controls, text.play, text.options, text.quit, text.menu_hints }) |words| try testing.expect(shows(&ctx, words));
    try testing.expect(!shows(&ctx, text.@"resume"));

    // Pause.
    _ = menus.update(.paused, .{}, null, null, &chosen);
    _ = try describeAt(&ctx, .{ .phase = .paused, .menus = &menus, .text = &text, .lit = 2, .beacons = 3, .size = size }, &chosen, .{});
    for ([_][]const u8{ text.paused, text.@"resume", text.restart, text.options, text.to_title, text.pointer_released }) |words| try testing.expect(shows(&ctx, words));
    try testing.expect(!shows(&ctx, text.play));

    // The three end screens, each with its own line.
    const endings = [_]struct { phase: game_mod.Phase, heading: []const u8, detail: []const u8 }{
        .{ .phase = .won, .heading = text.won, .detail = text.won_detail },
        .{ .phase = .caught, .heading = text.caught, .detail = text.caught_detail },
        .{ .phase = .fell, .heading = text.fell, .detail = text.fell_detail },
    };
    for (endings) |ending| {
        _ = menus.update(ending.phase, .{}, null, null, &chosen);
        _ = try describeAt(&ctx, .{ .phase = ending.phase, .menus = &menus, .text = &text, .size = size }, &chosen, .{});
        try testing.expect(shows(&ctx, ending.heading) and shows(&ctx, ending.detail));
        try testing.expect(shows(&ctx, text.restart) and shows(&ctx, text.to_title));
        for (endings) |other| if (other.phase != ending.phase) try testing.expect(!shows(&ctx, other.heading));
    }

    // Options, opened from the title.
    _ = menus.update(.title, .{}, null, null, &chosen);
    _ = menus.update(.title, .{ .down = true }, null, null, &chosen);
    _ = menus.update(.title, .{ .accept = true }, null, null, &chosen);
    chosen = .{ .volume = 0.8, .sensitivity = 1.5, .invert = true };
    _ = try describeAt(&ctx, .{ .phase = .title, .menus = &menus, .text = &text, .size = size }, &chosen, .{});
    for ([_][]const u8{ text.audio, text.master_volume, text.controls_section, text.look_sensitivity, text.invert_look, text.applies_at_once, text.back, text.options_hints, "80%", "1.5x", text.on }) |words| try testing.expect(shows(&ctx, words));
    try testing.expect(!shows(&ctx, text.off) and !shows(&ctx, text.play));
}

test "court: the pointer reaches every menu row, and a dragged slider changes its option within bounds" {
    const gpa = testing.allocator;
    var ctx = testContext(gpa);
    defer ctx.deinit();
    const text: Text = .{};
    var menus: menus_mod.Menus = .{};
    var chosen: menus_mod.Options = .{ .volume = 0.5 };
    _ = menus.update(.title, .{}, null, null, &chosen);
    const view: hud.View = .{ .phase = .title, .menus = &menus, .text = &text, .pointer_moved = true, .size = size };

    // Lay the screen out once to find Quit's row, as a person finds it by looking.
    _ = try describeAt(&ctx, view, &chosen, .{});
    const quit = rowCentre(&ctx, text.quit).?;
    // The pointer arrives, and a frame later the row is hot: hovered, and so focused.
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(quit, .up));
    const hover = try describeAt(&ctx, view, &chosen, ui.Input.at(quit, .up));
    try testing.expectEqual(@as(?menus_mod.Item, .quit), hover.hovered);
    try testing.expectEqual(@as(?menus_mod.Item, null), hover.clicked);
    try testing.expectEqual(menus_mod.Command.none, menus.update(.title, .{}, hover.hovered, hover.clicked, &chosen));
    try testing.expectEqual(menus_mod.Item.quit, menus.focused(.title).?);
    // A menu owns the pointer, on a row or beside one, so a click on its empty part is
    // never the game's.
    try testing.expect(ctx.wantsPointer());
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(.init(size.x - 5, 5), .up));
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(.init(size.x - 5, 5), .up));
    try testing.expect(ctx.wantsPointer());
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(quit, .up));
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(quit, .up));
    // Down and up on it is a click, and the click is Quit.
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(quit, .pressed));
    const click = try describeAt(&ctx, view, &chosen, ui.Input.at(quit, .released));
    try testing.expectEqual(@as(?menus_mod.Item, .quit), click.clicked);
    try testing.expectEqual(menus_mod.Command.quit, menus.update(.title, .{}, click.hovered, click.clicked, &chosen));
    // A pointer that did not move does not take the focus back from the keyboard.
    var still = view;
    still.pointer_moved = false;
    _ = try describeAt(&ctx, still, &chosen, ui.Input.at(quit, .up));
    const resting = try describeAt(&ctx, still, &chosen, ui.Input.at(quit, .up));
    try testing.expectEqual(@as(?menus_mod.Item, null), resting.hovered);
    // A press that slides off the row before letting go is not a click.
    const play = rowCentre(&ctx, text.play).?;
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(play, .up));
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(play, .pressed));
    const slid = try describeAt(&ctx, view, &chosen, ui.Input.at(.init(size.x - 5, 5), .released));
    try testing.expectEqual(@as(?menus_mod.Item, null), slid.clicked);

    // Options: drag the volume's track to its right end, then far past its left.
    _ = menus.update(.title, .{}, .options, .options, &chosen);
    try testing.expectEqual(menus_mod.Screen.options, menus.screen(.title));
    _ = try describeAt(&ctx, view, &chosen, .{});
    const row = rowCentre(&ctx, text.master_volume).?;
    // The track sits in the row's right half; its exact ends are the layout's business.
    const on_track: Vec2 = .init(row.x + 110, row.y);
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(on_track, .up));
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(on_track, .pressed));
    const dragged = try describeAt(&ctx, view, &chosen, ui.Input.at(.init(size.x, row.y), .held));
    try testing.expect(dragged.options_changed);
    try testing.expectEqual(menus_mod.Options.volume_max, chosen.volume);
    const back = try describeAt(&ctx, view, &chosen, ui.Input.at(.init(0, row.y), .held));
    try testing.expect(back.options_changed);
    try testing.expectEqual(menus_mod.Options.volume_min, chosen.volume);
    // Holding still changes nothing more, and the value stayed on a whole step.
    const held = try describeAt(&ctx, view, &chosen, ui.Input.at(.init(0, row.y), .held));
    try testing.expect(!held.options_changed);
    _ = try describeAt(&ctx, view, &chosen, ui.Input.at(.init(0, row.y), .released));
}

// -- preferences -----------------------------------------------------------------------

const PrefsFixture = struct {
    os: *platform.os.Os,
    tmp: std.testing.TmpDir,
    dir: []u8,

    fn init() !PrefsFixture {
        const gpa = testing.allocator;
        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-court-test", .env = &.{} });
        errdefer os.deinit();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const dir = try platform.os.joinPath(gpa, &.{ buf[0..n], "foundry-court" });
        return .{ .os = os, .tmp = tmp, .dir = dir };
    }

    fn deinit(self: *PrefsFixture) void {
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
        self.os.deinit();
    }

    fn open(self: *PrefsFixture, persist: bool) !Preferences {
        return .{ .file = try Preferences.openIn(testing.allocator, self.os, self.dir, persist) };
    }

    fn writeRaw(self: *PrefsFixture, bytes: []const u8) !void {
        try self.os.createDirPath(self.dir);
        _ = try self.os.replaceFileConfined(self.dir, app.settings.default_leaf, bytes, 1 << 20);
    }

    fn readRaw(self: *PrefsFixture) ![]u8 {
        const read = try self.os.readFileConfined(testing.allocator, self.dir, app.settings.default_leaf, 1 << 20);
        return read.bytes;
    }
};

test "court: preferences default from content, keep only what the player chose, and come back" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);
    var fixture = try PrefsFixture.init();
    defer fixture.deinit();

    // No file: the package's defaults, and nothing is the player's.
    var first = try fixture.open(true);
    first.resolve(&env.store);
    try testing.expectEqual(@as(u32, 1280), first.width.value);
    try testing.expectEqual(@as(u32, 720), first.height.value);
    try testing.expectApproxEqAbs(@as(f32, 0.8), first.volume.value, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), first.sensitivity.value, 1e-6);
    try testing.expect(!first.invert.value);
    try testing.expectEqual(app.settings.Origin.content, first.volume.origin);
    for (first.values()) |value| try testing.expectEqual(@as(?data.Value, null), value);
    // Nothing changed, nothing written.
    first.flush(gpa);
    try testing.expectError(error.FileNotFound, fixture.readRaw());

    // The options screen changes two things; the third stays the content's.
    var chosen = first.options();
    chosen.volume = 0.35;
    chosen.invert = true;
    first.noteOptions(chosen);
    try testing.expect(first.volume.isUser() and first.invert.isUser() and !first.sensitivity.isUser());
    // Out-of-range and non-finite values from a caller are bounded or ignored.
    chosen.sensitivity = 50;
    first.noteOptions(chosen);
    try testing.expectEqual(menus_mod.Options.sensitivity_max, first.sensitivity.value);
    chosen.sensitivity = std.math.nan(f32);
    first.noteOptions(chosen);
    try testing.expectEqual(menus_mod.Options.sensitivity_max, first.sensitivity.value);
    chosen.sensitivity = 1.5;
    first.noteOptions(chosen);
    // A resize the user made is kept; an absurd one is not.
    first.noteResize(.{ .width = 1600, .height = 900 });
    first.noteResize(.{ .width = 10, .height = 10 });
    try testing.expectEqual(@as(u32, 1600), first.width.value);
    // Written only once the changes have settled, not on every frame of a drag.
    first.tick(gpa);
    try testing.expectError(error.FileNotFound, fixture.readRaw());
    first.flush(gpa);
    first.deinit(gpa);

    // The next start reads it back, over the content.
    var second = try fixture.open(true);
    defer second.deinit(gpa);
    try testing.expectEqual(app.settings.State.loaded, second.file.state());
    second.resolve(&env.store);
    try testing.expectApproxEqAbs(@as(f32, 0.35), second.volume.value, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.5), second.sensitivity.value, 1e-6);
    try testing.expect(second.invert.value);
    try testing.expectEqual(@as(u32, 1600), second.width.value);
    try testing.expectEqual(@as(u32, 900), second.height.value);
    try testing.expectEqual(app.settings.Origin.user, second.volume.origin);
}

test "court: a damaged or newer preferences file gives the content defaults and is not overwritten" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);

    // Damaged: not a settings file at all.
    {
        var fixture = try PrefsFixture.init();
        defer fixture.deinit();
        try fixture.writeRaw("this is not a settings file");
        var prefs = try fixture.open(true);
        defer prefs.deinit(gpa);
        try testing.expect(prefs.file.state() != .loaded);
        prefs.resolve(&env.store);
        try testing.expectApproxEqAbs(@as(f32, 0.8), prefs.volume.value, 1e-6);
        try testing.expectEqual(@as(u32, 1280), prefs.width.value);
    }

    // Newer: a valid file of a later version of the same schema.
    {
        var fixture = try PrefsFixture.init();
        defer fixture.deinit();
        var newer = Preferences.schema;
        newer.version = Preferences.schema.version + 1;
        const values = [_]?data.Value{ .{ .int = 640 }, .{ .int = 480 }, .{ .float = 0.1 }, .{ .float = 2.5 }, .{ .bool = true } };
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(gpa);
        try app.settings.encode(gpa, newer, &values, .default, &encoded);
        const bytes = encoded.items;
        try fixture.writeRaw(bytes);
        var prefs = try fixture.open(true);
        defer prefs.deinit(gpa);
        try testing.expect(prefs.file.state() != .loaded);
        prefs.resolve(&env.store);
        try testing.expectApproxEqAbs(@as(f32, 0.8), prefs.volume.value, 1e-6);
        try testing.expect(!prefs.invert.value);
        // This build must not replace what a later one wrote.
        var chosen = prefs.options();
        chosen.volume = 0.2;
        prefs.noteOptions(chosen);
        prefs.flush(gpa);
        const after = try fixture.readRaw();
        defer gpa.free(after);
        try testing.expectEqualSlices(u8, bytes, after);
    }

    // In range on disk but out of the court's bounds: each such value falls to the content's.
    {
        var fixture = try PrefsFixture.init();
        defer fixture.deinit();
        const values = [_]?data.Value{ .{ .int = 100 }, .{ .int = 100000 }, .{ .float = 7 }, .{ .float = -3 }, .{ .bool = true } };
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(gpa);
        try app.settings.encode(gpa, Preferences.schema, &values, .default, &encoded);
        const bytes = encoded.items;
        try fixture.writeRaw(bytes);
        var prefs = try fixture.open(true);
        defer prefs.deinit(gpa);
        try testing.expectEqual(app.settings.State.loaded, prefs.file.state());
        prefs.resolve(&env.store);
        try testing.expectEqual(@as(u32, 1280), prefs.width.value);
        try testing.expectEqual(@as(u32, 720), prefs.height.value);
        try testing.expectApproxEqAbs(@as(f32, 0.8), prefs.volume.value, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 1), prefs.sensitivity.value, 1e-6);
        // The one value that was usable is used.
        try testing.expect(prefs.invert.value);
    }

    // A run that does not persist reads and never writes; headless opens nothing.
    {
        var fixture = try PrefsFixture.init();
        defer fixture.deinit();
        var prefs = try fixture.open(false);
        defer prefs.deinit(gpa);
        prefs.resolve(&env.store);
        var chosen = prefs.options();
        chosen.volume = 0.2;
        prefs.noteOptions(chosen);
        prefs.flush(gpa);
        try testing.expectError(error.FileNotFound, fixture.readRaw());
        var headless = try Preferences.open(gpa, fixture.os, true, false, fixture.dir);
        defer headless.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), headless.file.dir.len);
    }
}

test "court: the config record refuses a goal time that is missing, non-finite or out of bounds" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = testing.allocator;
    var env = try TestEnv.init(gpa);
    defer env.deinit(gpa);
    const record = env.store.lookup(core.ContentId.fromString("court:config.main")).?;
    const config = try Settings.read(record);
    try testing.expectApproxEqAbs(@as(f32, 6), config.goal_seconds, 1e-6);
    const index = record.schema.fieldIndex("goal_seconds").?;
    const bytes = @constCast(record.fields.block)[fieldOffset(record.fields.fields, index)..][0..4];
    const old: [4]u8 = bytes.*;
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -1, 121 }) |v| {
        std.mem.writeInt(u32, bytes, @bitCast(v), .little);
        try testing.expectError(error.InvalidConfig, Settings.read(record));
    }
    bytes.* = old;
    _ = try Settings.read(record);
}
