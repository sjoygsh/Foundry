//! The court's HUD and menus, described into a `ui.Context` (playable3d.md §6.1).
//!
//! Layout is code and the look is `court:ui.theme`'s (ADR-0041): this file names colours
//! and patches by role and holds no colour of its own. Every string is `court:text.main`'s.
//! It decides nothing: it draws `menus.Menus` and reports which row the pointer is over or
//! pressed, and `Menus.update` turns that into a command.
const std = @import("std");
const core = @import("core");
const ui = @import("ui");
const menus_mod = @import("menus.zig");
const game_mod = @import("game.zig");
const Text = @import("text.zig").Text;

const Rect = core.math.Rect;
const Vec2 = core.math.Vec2;
const Item = menus_mod.Item;
const Options = menus_mod.Options;
const Allocator = std.mem.Allocator;

/// What one frame shows. Plain values, so a test builds one with no engine.
pub const View = struct {
    phase: game_mod.Phase,
    menus: *const menus_mod.Menus,
    text: *const Text,
    lit: usize = 0,
    beacons: usize = 0,
    /// A beacon is in the look and within reach.
    aimed: bool = false,
    gate_open: bool = false,
    has_gate: bool = true,
    /// Whether the goal line is still up: the first seconds of each game.
    show_goal: bool = false,
    /// The pointer moved this frame. A resting pointer does not hold the focus against
    /// the keyboard.
    pointer_moved: bool = false,
    size: Vec2,
};

pub const Result = struct {
    hovered: ?Item = null,
    clicked: ?Item = null,
    /// A slider was dragged; `options` already holds the new value.
    options_changed: bool = false,
};

const row_width: f32 = 340;
const margin: f32 = 64;

/// Describes the frame's HUD or menu. `options` is edited in place by a dragged slider.
pub fn describe(ctx: *ui.Context, view: View, options: *Options) Allocator.Error!Result {
    return switch (view.menus.screen(view.phase)) {
        .hud => blk: {
            try hud(ctx, view);
            break :blk .{};
        },
        .title => title(ctx, view),
        .pause => pause(ctx, view),
        .ended => ended(ctx, view),
        .options => optionsScreen(ctx, view, options),
    };
}

fn hud(ctx: *ui.Context, view: View) Allocator.Error!void {
    const style = ctx.style;
    const t = view.text;
    const line = style.line_height;

    // Top left: the count, a segment per beacon, and what is being counted.
    var buffer: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&buffer, "{d} / {d}", .{ view.lit, view.beacons }) catch buffer[0..0];
    try text(ctx, count, .init(24, 20), style.text, 1.5);
    const segment: Vec2 = .init(30, 6);
    for (0..view.beacons) |n| {
        const at: Rect = .init(24 + @as(f32, @floatFromInt(n)) * (segment.x + 4), 20 + line + 4, segment.x, segment.y);
        try ctx.list.addRect(ctx.gpa, at, if (n < view.lit) style.accent else style.control_hot);
    }
    try text(ctx, t.beacons_lit, .init(24, 20 + line + 18), style.text_dim, 1);

    // Top centre: the objective, and under it the goal for the first seconds of a game.
    const objective = if (view.gate_open) t.objective_gate else t.objective;
    try centred(ctx, objective, view.size.x / 2, 20, if (view.gate_open) style.accent else style.text, 1);
    if (!view.has_gate) {
        try centred(ctx, t.no_gate, view.size.x / 2, 20 + line, negative(ctx), 1);
    } else if (view.show_goal) {
        try centred(ctx, t.goal, view.size.x / 2, 20 + line, style.text_dim, 1);
        try centred(ctx, t.goal_detail, view.size.x / 2, 20 + line * 2 - 8, style.text_dim, 1);
    }

    // Top right: how to get out.
    const hint = measure(ctx, t.pause_hint, 1);
    try text(ctx, t.pause_hint, .init(view.size.x - 24 - hint.x, 20), style.text_dim, 1);

    // The centre mark.
    const centre = view.size.scale(0.5);
    const dot: Rect = .init(centre.x - 3, centre.y - 3, 6, 6);
    const drawn = if (ctx.skin) |skin| skin.icon("reticle") else null;
    if (drawn) |source| {
        try ui.imageIn(ctx, source, dot, style.text);
    } else {
        try ctx.list.addRect(ctx.gpa, dot, style.text);
    }

    // The prompt, when a beacon is in the look and in reach: a key cap and what it does.
    if (view.aimed) {
        const key = measure(ctx, t.use_key, 1);
        const words = measure(ctx, t.use_prompt, 1);
        const cap: Rect = .init(0, 0, key.x + style.padding.x * 2, line);
        const total = cap.w + 12 + words.x;
        const left = centre.x - total / 2;
        const top = view.size.y * 0.62;
        try part(ctx, .init(left, top, cap.w, cap.h), .button, style.control);
        try text(ctx, t.use_key, .init(left + style.padding.x, top + (line - key.y) / 2), style.text, 1);
        try text(ctx, t.use_prompt, .init(left + cap.w + 12, top + (line - words.y) / 2), style.text, 1);
    }
}

fn title(ctx: *ui.Context, view: View) Allocator.Error!Result {
    const style = ctx.style;
    const t = view.text;
    try veil(ctx, view);
    var y = view.size.y * 0.18;
    try text(ctx, t.title, .init(margin, y), style.text, 2.5);
    y += style.line_height * 2.2;
    try text(ctx, t.goal, .init(margin, y), style.text_dim, 1);
    y += style.line_height * 0.8;
    try text(ctx, t.goal_detail, .init(margin, y), style.text_dim, 1);
    y += style.line_height * 1.6;
    const result = try rows(ctx, view, margin, y);
    try text(ctx, t.controls, .init(margin, view.size.y - 40 - style.line_height), style.text_dim, 1);
    try text(ctx, t.menu_hints, .init(margin, view.size.y - 40), style.text_dim, 1);
    return result;
}

fn pause(ctx: *ui.Context, view: View) Allocator.Error!Result {
    const style = ctx.style;
    const t = view.text;
    try veil(ctx, view);
    const left = (view.size.x - row_width) / 2;
    var y = view.size.y * 0.24;
    try centred(ctx, t.paused, view.size.x / 2, y, style.text, 2);
    y += style.line_height * 1.6;
    var buffer: [48]u8 = undefined;
    const progress = std.fmt.bufPrint(&buffer, "{d} / {d}  {s}", .{ view.lit, view.beacons, t.beacons_lit }) catch buffer[0..0];
    try centred(ctx, progress, view.size.x / 2, y, style.text_dim, 1);
    y += style.line_height * 1.2;
    const result = try rows(ctx, view, left, y);
    y += rowsHeight(ctx, view) + style.line_height * 0.5;
    try centred(ctx, t.pointer_released, view.size.x / 2, y, style.text_dim, 1);
    try centred(ctx, t.menu_hints, view.size.x / 2, view.size.y - 40, style.text_dim, 1);
    return result;
}

fn ended(ctx: *ui.Context, view: View) Allocator.Error!Result {
    const style = ctx.style;
    const t = view.text;
    try veil(ctx, view);
    const won = view.phase == .won;
    const heading = switch (view.phase) {
        .won => t.won,
        .caught => t.caught,
        else => t.fell,
    };
    const detail = switch (view.phase) {
        .won => t.won_detail,
        .caught => t.caught_detail,
        else => t.fell_detail,
    };
    const left = (view.size.x - row_width) / 2;
    var y = view.size.y * 0.26;
    try centred(ctx, heading, view.size.x / 2, y, if (won) style.accent else negative(ctx), 2);
    y += style.line_height * 1.6;
    try centred(ctx, detail, view.size.x / 2, y, style.text_dim, 1);
    y += style.line_height * 1.4;
    const result = try rows(ctx, view, left, y);
    try centred(ctx, t.menu_hints, view.size.x / 2, view.size.y - 40, style.text_dim, 1);
    return result;
}

fn optionsScreen(ctx: *ui.Context, view: View, options: *Options) Allocator.Error!Result {
    const style = ctx.style;
    const t = view.text;
    try veil(ctx, view);
    const width: f32 = 520;
    const left = (view.size.x - width) / 2;
    var y = view.size.y * 0.16;
    try text(ctx, t.options, .init(left, y), style.text, 2);
    y += style.line_height * 1.8;
    var result: Result = .{};
    const focused = view.menus.focused(view.phase);

    try section(ctx, t.audio, left, &y, width);
    var buffer: [16]u8 = undefined;
    const volume = std.fmt.bufPrint(&buffer, "{d:.0}%", .{options.volume * 100}) catch buffer[0..0];
    if (try sliderRow(ctx, view, .volume, t.master_volume, volume, &options.volume, Options.volume_min, Options.volume_max, Options.volume_step, .init(left, y, width, style.line_height), focused == .volume, &result)) result.options_changed = true;
    y += style.line_height + style.spacing * 3;

    try section(ctx, t.controls_section, left, &y, width);
    const sensitivity = std.fmt.bufPrint(&buffer, "{d:.1}x", .{options.sensitivity}) catch buffer[0..0];
    if (try sliderRow(ctx, view, .sensitivity, t.look_sensitivity, sensitivity, &options.sensitivity, Options.sensitivity_min, Options.sensitivity_max, Options.sensitivity_step, .init(left, y, width, style.line_height), focused == .sensitivity, &result)) result.options_changed = true;
    y += style.line_height + style.spacing;
    {
        const bounds: Rect = .init(left, y, width, style.line_height);
        try row(ctx, view, .invert, t.invert_look, bounds, focused == .invert, &result);
        const state = if (options.invert) t.on else t.off;
        const size = measure(ctx, state, 1);
        const box: Rect = .init(bounds.x + bounds.w - style.padding.x - 18, bounds.y + (bounds.h - 18) / 2, 18, 18);
        try part(ctx, box, if (options.invert) .check_on else .check_off, if (options.invert) style.accent else style.control);
        try text(ctx, state, .init(box.x - 10 - size.x, bounds.y + (bounds.h - size.y) / 2), rowColor(ctx, focused == .invert), 1);
    }
    y += style.line_height + style.spacing * 3;

    try text(ctx, t.applies_at_once, .init(left, y), style.text_dim, 1);
    y += style.line_height;
    try row(ctx, view, .back, t.back, .init(left, y, 160, style.line_height), focused == .back, &result);
    try centred(ctx, t.options_hints, view.size.x / 2, view.size.y - 40, style.text_dim, 1);
    return result;
}

/// A section's name over a hairline.
fn section(ctx: *ui.Context, name: []const u8, left: f32, y: *f32, width: f32) Allocator.Error!void {
    const style = ctx.style;
    try text(ctx, name, .init(left, y.*), style.text_dim, 1);
    y.* += style.line_height * 0.7;
    try ctx.list.addRect(ctx.gpa, .init(left, y.*, width, style.separator_thickness), style.control_hot);
    y.* += style.spacing * 2;
}

/// A row with a track and its value at the right. Returns whether a drag changed `value`.
fn sliderRow(
    ctx: *ui.Context,
    view: View,
    item: Item,
    label: []const u8,
    shown: []const u8,
    value: *f32,
    min: f32,
    max: f32,
    step: f32,
    bounds: Rect,
    focused: bool,
    result: *Result,
) Allocator.Error!bool {
    const style = ctx.style;
    try row(ctx, view, item, label, bounds, focused, result);
    const value_width: f32 = 64;
    const track: Rect = .init(bounds.x + bounds.w - style.padding.x - value_width - 180, bounds.y + (bounds.h - 6) / 2, 180, 6);
    // A taller target than the line that is drawn, so the pointer can find it.
    const grab: Rect = .init(track.x, bounds.y, track.w, bounds.h);
    const state = ctx.interact(rowId(item).child("track"), grab);
    var changed = false;
    if (state.active and track.w > 0) {
        const fraction = std.math.clamp((ctx.input.pointer.x - track.x) / track.w, 0, 1);
        const wanted = std.math.clamp(@round((min + fraction * (max - min)) / step) * step, min, max);
        if (wanted != value.*) {
            value.* = wanted;
            changed = true;
        }
        result.hovered = item;
    }
    const fill = std.math.clamp((value.* - min) / (max - min), 0, 1);
    const on_row = if (focused) ink(ctx) else style.accent;
    try ctx.list.addRect(ctx.gpa, track, if (focused) dimmed(ink(ctx)) else style.control_hot);
    try ctx.list.addRect(ctx.gpa, .init(track.x, track.y, track.w * fill, track.h), on_row);
    try ctx.list.addRect(ctx.gpa, .init(track.x + track.w * fill - 2, track.y - 4, 4, track.h + 8), on_row);
    const size = measure(ctx, shown, 1);
    try text(ctx, shown, .init(bounds.x + bounds.w - style.padding.x - size.x, bounds.y + (bounds.h - size.y) / 2), rowColor(ctx, focused), 1);
    return changed;
}

/// The current screen's rows, one under another from `top`.
fn rows(ctx: *ui.Context, view: View, left: f32, top: f32) Allocator.Error!Result {
    var result: Result = .{};
    const focused = view.menus.focused(view.phase);
    var y = top;
    for (view.menus.items(view.phase)) |item| {
        try row(ctx, view, item, labelOf(view.text, item), .init(left, y, row_width, ctx.style.line_height), focused == item, &result);
        y += ctx.style.line_height + ctx.style.spacing;
    }
    return result;
}

fn rowsHeight(ctx: *ui.Context, view: View) f32 {
    const n: f32 = @floatFromInt(view.menus.items(view.phase).len);
    return n * (ctx.style.line_height + ctx.style.spacing);
}

/// One menu row: the focused one is filled with the accent and written in the surface's
/// ink; the others are plain text.
fn row(ctx: *ui.Context, view: View, item: Item, label: []const u8, bounds: Rect, focused: bool, result: *Result) Allocator.Error!void {
    const id = rowId(item);
    if (try ui.selectableIn(ctx, id, "", focused, bounds)) result.clicked = item;
    if (view.pointer_moved and ctx.isHot(id)) result.hovered = item;
    const size = measure(ctx, label, 1);
    try text(ctx, label, .init(bounds.x + ctx.style.padding.x, bounds.y + (bounds.h - size.y) / 2), rowColor(ctx, focused), 1);
}

fn rowId(item: Item) ui.Id {
    return ui.Id.root.child("court").child(@tagName(item));
}

fn labelOf(t: *const Text, item: Item) []const u8 {
    return switch (item) {
        .play => t.play,
        .resume_game => t.@"resume",
        .restart => t.restart,
        .options => t.options,
        .to_title => t.to_title,
        .quit => t.quit,
        .volume => t.master_volume,
        .sensitivity => t.look_sensitivity,
        .invert => t.invert_look,
        .back => t.back,
    };
}

/// The scene behind a menu, dimmed by the theme's surface.
fn veil(ctx: *ui.Context, view: View) Allocator.Error!void {
    try ctx.list.addRect(ctx.gpa, .init(0, 0, view.size.x, view.size.y), ctx.style.surface);
    // A menu owns the pointer wherever it is, so a click beside a row is not the game's.
    ctx.blockPointer(.init(0, 0, view.size.x, view.size.y));
}

fn part(ctx: *ui.Context, bounds: Rect, which: ui.SkinPart, fallback: ui.Color) Allocator.Error!void {
    if (ctx.skin) |skin| if (skin.patch(which)) |patch| {
        try ctx.list.addNineSlice(ctx.gpa, bounds, patch.source, patch.insets, skin.patch_scale, .white);
        return;
    };
    try ctx.list.addRect(ctx.gpa, bounds, fallback);
}

/// The surface's colour at full strength: what is written on an accent-filled row.
fn ink(ctx: *const ui.Context) ui.Color {
    var c = ctx.style.surface;
    c.a = 1;
    return c;
}

fn dimmed(c: ui.Color) ui.Color {
    var out = c;
    out.a *= 0.35;
    return out;
}

fn rowColor(ctx: *const ui.Context, focused: bool) ui.Color {
    return if (focused) ink(ctx) else ctx.style.text;
}

fn negative(ctx: *const ui.Context) ui.Color {
    return if (ctx.skin) |skin| skin.negative else ctx.style.text;
}

fn measure(ctx: *const ui.Context, string: []const u8, scale: f32) Vec2 {
    return ctx.style.font.measure(string, ctx.style.text_scale * scale);
}

/// Text at a point, on whole units so the glyph grid stays on the pixel grid.
fn text(ctx: *ui.Context, string: []const u8, at: Vec2, color: ui.Color, scale: f32) Allocator.Error!void {
    try ctx.list.addText(ctx.gpa, .init(@round(at.x), @round(at.y)), string, color, ctx.style.text_scale * scale);
}

fn centred(ctx: *ui.Context, string: []const u8, centre_x: f32, y: f32, color: ui.Color, scale: f32) Allocator.Error!void {
    const size = measure(ctx, string, scale);
    try text(ctx, string, .init(centre_x - size.x / 2, y), color, scale);
}
