//! The additions that make the kernel a content-skinned game widget set (ADR-0041).
//!
//! Existing controls remain in `widget.zig`: they use the same interaction function and
//! draw from `Context.skin` when one is installed. This file contains only interactions
//! the debug set did not need — tabs, selectable rows and an in-list reorder gesture —
//! plus placed image and icon widgets. Nothing here sees content or a renderer. Images are
//! still opaque `ImageRef`s and every test runs headlessly.
//!
//! A reorder list deliberately owns no rows. The caller lays out and draws them, then hands
//! their rectangle and count to `reorderList`; it draws grips over those rows and returns a
//! `{ from, to }` value on release. That keeps a rich game row composable from a checkbox,
//! text and icons without teaching the kernel what any of them mean.
//!
//! Design: `docs/design/mod-management.md` §10 and Step 6.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Rect = core.math.Rect;
const Vec2 = core.math.Vec2;
const Context = @import("context.zig").Context;
const Source = @import("draw.zig").Source;
const Id = @import("id.zig").Id;
const layout = @import("layout.zig");
const skin_mod = @import("skin.zig");
const Color = @import("style.zig").Color;
const widget = @import("widget.zig");

/// A completed in-list move. `to` is the final index after `from` is removed, which is the
/// shape `app.ModSet.move` already accepts. Both are always below the count passed to the
/// widget.
pub const ReorderMove = struct {
    from: u32,
    to: u32,
};

pub const ReorderDirection = enum {
    up,
    down,
    top,
    bottom,
};

/// A horizontal row of tabs. `selected` is clamped to the available tabs; zero is returned
/// for an empty list. Identity comes from `id` and the tab index, never from display text.
pub fn tabs(
    ctx: *Context,
    id: Id,
    labels: []const []const u8,
    selected: usize,
) Allocator.Error!usize {
    if (labels.len == 0) return 0;

    const style = ctx.style;
    var total: f32 = 0;
    for (labels, 0..) |text, i| {
        total += extent(style.font.measure(text, style.text_scale).x + style.padding.x * 2);
        if (i + 1 != labels.len) total += extent(style.spacing);
    }
    const strip = ctx.take(.init(total, style.line_height));
    const current = @min(selected, labels.len - 1);
    var chosen = current;
    var x = strip.x;

    for (labels, 0..) |text, i| {
        const width = extent(style.font.measure(text, style.text_scale).x + style.padding.x * 2);
        const bounds: Rect = .init(x, strip.y, width, strip.h);
        const interaction = ctx.interact(id.childIndex(i), bounds);
        if (interaction.clicked) chosen = i;

        // The caller owns the selection, so this frame is drawn from the value it passed.
        // A click returns the next value; the following frame draws it selected. This also
        // avoids painting both the old and new tabs as selected on the release frame.
        const on = current == i;
        const fallback = if (interaction.active)
            style.control_active
        else if (interaction.hot)
            style.control_hot
        else if (on)
            selectedColor(ctx)
        else
            style.control;
        try drawPart(ctx, bounds, if (on) .tab_on else .tab, fallback);
        try drawText(ctx, text, bounds, style.text, .center);
        x += width + extent(style.spacing);
    }
    return chosen;
}

/// A full-width row with a caller-owned selected state. True only on a completed click.
///
/// **Full width in either kind of region.** Down a panel it is a band across it; inside a row
/// it takes what the row has left, so a list row can lead with a checkbox or an icon and still
/// be selected by its whole remaining length.
pub fn selectable(ctx: *Context, id: Id, text: []const u8, selected: bool) Allocator.Error!bool {
    const line = ctx.style.line_height;
    const bounds = ctx.take(.init(ctx.region().remaining().w, line));
    return selectableIn(ctx, id, text, selected, bounds);
}

/// `selectable` in a caller-provided rectangle, for a list with its own layout.
pub fn selectableIn(
    ctx: *Context,
    id: Id,
    text: []const u8,
    selected: bool,
    bounds: Rect,
) Allocator.Error!bool {
    const clean = layout.sanitize(bounds);
    const interaction = ctx.interact(id, clean);
    const fallback = if (interaction.active)
        ctx.style.control_active
    else if (interaction.hot)
        ctx.style.control_hot
    else if (selected)
        selectedColor(ctx)
    else
        ctx.style.control;
    try drawPart(ctx, clean, if (selected) .row_selected else .row, fallback);
    try drawText(ctx, text, inset(clean, .init(ctx.style.padding.x, 0)), ctx.style.text, .left);
    return interaction.clicked;
}

/// Place an arbitrary image in the current region. `size` is the drawn size; the slot may
/// stretch across the region, but the image itself does not. Use `imageIn` for absolute
/// placement.
pub fn image(
    ctx: *Context,
    source: Source,
    size: Vec2,
    tint: Color,
) Allocator.Error!void {
    const clean_size = Vec2.init(extent(size.x), extent(size.y));
    const slot = ctx.take(clean_size);
    try imageIn(ctx, source, placedIn(slot, clean_size), tint);
}

pub fn imageIn(ctx: *Context, source: Source, bounds: Rect, tint: Color) Allocator.Error!void {
    try ctx.list.addImage(ctx.gpa, bounds, source, tint);
}

/// Place the icon named by the active skin. The slot is kept even when the name is absent,
/// so a missing optional icon does not move every column after it. Returns whether it was
/// found and described.
pub fn icon(
    ctx: *Context,
    name: []const u8,
    size: Vec2,
    tint: Color,
) Allocator.Error!bool {
    const clean_size = Vec2.init(extent(size.x), extent(size.y));
    const slot = ctx.take(clean_size);
    return iconIn(ctx, name, placedIn(slot, clean_size), tint);
}

pub fn iconIn(
    ctx: *Context,
    name: []const u8,
    bounds: Rect,
    tint: Color,
) Allocator.Error!bool {
    const skin = ctx.skin orelse return false;
    const source = skin.icon(name) orelse return false;
    try ctx.list.addImage(ctx.gpa, bounds, source, tint);
    return true;
}

/// Put a reorder grip over each of `count` standard-height rows in `bounds`. The rows are
/// separated by `Style.spacing`, matching a vertical region. A drag may leave the list;
/// its insertion slot clamps to the first or last edge and pointer capture stays active.
/// Nothing is allocated besides the draw-list commands and the context's ordinary state.
pub fn reorderList(
    ctx: *Context,
    id: Id,
    bounds: Rect,
    count: u32,
) Allocator.Error!?ReorderMove {
    const clean = layout.sanitize(bounds);
    const state = ctx.stateOf(id);
    if (count == 0 or clean.isEmpty()) {
        state.reorder_from = null;
        return null;
    }
    if (state.reorder_from) |from| {
        if (from >= count) state.reorder_from = null;
    }

    const style = ctx.style;
    const row_height = extent(style.line_height);
    const step = row_height + extent(style.spacing);
    const grip_side = extent(row_height - style.padding.y * 2);
    const grip_seed = id.child("grip");
    // If the list was not described when a release arrived, `Context.end` correctly
    // cleared the active widget. Forget the matching gesture when the list returns rather
    // than drawing an insertion marker for a drag that no longer exists.
    if (state.reorder_from) |from| {
        if (!ctx.isActive(grip_seed.childIndex(from))) state.reorder_from = null;
    }
    const was_dragging = state.reorder_from != null;
    const releasing = was_dragging and ctx.input.pointerReleased();

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const row_y = clean.y + @as(f32, @floatFromInt(i)) * step;
        const grip = layout.sanitize(Rect.init(
            @round(clean.x + style.padding.x),
            @round(row_y + (row_height - grip_side) / 2),
            grip_side,
            grip_side,
        ));
        const interaction = ctx.interact(grip_seed.childIndex(i), grip);
        if (interaction.pressed) {
            state.reorder_from = i;
            state.reorder_slot = i;
        }
        try drawGrip(ctx, grip, interaction.active or state.reorder_from == i);
    }

    if (ctx.isDisabled()) {
        state.reorder_from = null;
        return null;
    }

    const from = state.reorder_from orelse return null;
    const slot = insertionSlot(ctx.input.pointer.y, clean.y, row_height, step, count);
    state.reorder_slot = slot;

    if (!releasing) {
        const y = insertionY(clean.y, row_height, step, slot, count);
        const thickness = @max(0, style.separator_thickness);
        try ctx.list.addRect(ctx.gpa, .init(clean.x, y - thickness / 2, clean.w, thickness), selectedColor(ctx));
        return null;
    }

    state.reorder_from = null;
    const to = destination(from, slot, count);
    if (to == from) return null;
    return .{ .from = from, .to = to };
}

/// One of the four content-labelled buttons beside a reorder list. Impossible moves draw
/// through the ordinary disabled scope, take the pointer from the game, and return null.
pub fn reorderButton(
    ctx: *Context,
    id: Id,
    text: []const u8,
    index: u32,
    count: u32,
    direction: ReorderDirection,
) Allocator.Error!?ReorderMove {
    const to = buttonDestination(index, count, direction);
    if (to == null) ctx.beginDisabled();
    defer if (to == null) ctx.endDisabled();

    if (!try widget.button(ctx, id, text)) return null;
    return .{ .from = index, .to = to.? };
}

fn drawPart(ctx: *Context, bounds: Rect, part: skin_mod.Part, fallback: Color) Allocator.Error!void {
    if (ctx.skin) |skin| {
        if (skin.patch(part)) |patch| {
            try ctx.list.addNineSlice(ctx.gpa, bounds, patch.source, patch.insets, skin.patch_scale, .white);
            return;
        }
    }
    try ctx.list.addRect(ctx.gpa, bounds, fallback);
}

fn selectedColor(ctx: *const Context) Color {
    return if (ctx.skin) |skin| skin.selection else ctx.style.accent;
}

fn drawGrip(ctx: *Context, bounds: Rect, active: bool) Allocator.Error!void {
    const style = ctx.style;
    const thickness = @max(0, style.separator_thickness);
    if (thickness == 0 or bounds.isEmpty()) return;
    // Inset by the padding, but never by more than a quarter of the grip either side: a grip
    // is a square a line tall, and a padding wider than half of it would leave lines of no
    // width at all, which is a grip nobody can see (`checkbox`'s mark has the same rule).
    const margin = @min(style.padding.x, bounds.w / 4);
    const width = @max(0, bounds.w - margin * 2);
    const x = bounds.x + margin;
    const gap = @max(thickness, style.spacing);
    const middle = bounds.y + bounds.h / 2 - thickness / 2;
    const color = if (active) selectedColor(ctx) else style.text_dim;
    inline for ([_]f32{ -1, 0, 1 }) |offset| {
        try ctx.list.addRect(ctx.gpa, .init(x, middle + offset * gap, width, thickness), color);
    }
}

fn insertionSlot(pointer_y: f32, top: f32, height: f32, step: f32, count: u32) u32 {
    if (!std.math.isFinite(pointer_y) or step <= 0 or height <= 0) return 0;
    if (pointer_y <= top) return 0;
    const delta = pointer_y - top;
    const row_float = @floor(delta / step);
    if (row_float >= @as(f32, @floatFromInt(count))) return count;
    const row: u32 = @intFromFloat(row_float);
    const within = delta - @as(f32, @floatFromInt(row)) * step;
    return row + @as(u32, if (within >= height / 2) 1 else 0);
}

fn insertionY(top: f32, height: f32, step: f32, slot: u32, count: u32) f32 {
    if (slot >= count) {
        return top + @as(f32, @floatFromInt(count - 1)) * step + height;
    }
    return top + @as(f32, @floatFromInt(slot)) * step;
}

fn destination(from: u32, slot: u32, count: u32) u32 {
    const shifted = if (slot > from) slot - 1 else slot;
    return @min(shifted, count - 1);
}

fn buttonDestination(index: u32, count: u32, direction: ReorderDirection) ?u32 {
    if (count == 0 or index >= count) return null;
    return switch (direction) {
        .up => if (index > 0) index - 1 else null,
        .down => if (index + 1 < count) index + 1 else null,
        .top => if (index > 0) 0 else null,
        .bottom => if (index + 1 < count) count - 1 else null,
    };
}

fn placedIn(slot: Rect, size: Vec2) Rect {
    return .init(slot.x, @round(slot.y + (slot.h - size.y) / 2), @min(slot.w, size.x), @min(slot.h, size.y));
}

fn inset(r: Rect, by: Vec2) Rect {
    return .init(r.x + by.x, r.y + by.y, @max(0, r.w - by.x * 2), @max(0, r.h - by.y * 2));
}

fn extent(value: f32) f32 {
    return if (std.math.isFinite(value)) @max(0, value) else 0;
}

fn drawText(
    ctx: *Context,
    text: []const u8,
    bounds: Rect,
    color: Color,
    alignment: enum { left, center },
) Allocator.Error!void {
    if (text.len == 0) return;
    const scale = ctx.style.text_scale;
    const size = ctx.style.font.measure(text, scale);
    const x = switch (alignment) {
        .left => bounds.x,
        .center => bounds.x + (bounds.w - size.x) / 2,
    };
    try ctx.list.addText(ctx.gpa, .init(@round(x), @round(bounds.y + (bounds.h - size.y) / 2)), text, color, scale);
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;
const platform = @import("platform");
const draw = @import("draw.zig");
const Input = @import("input.zig").Input;
const Skin = skin_mod.Skin;
const Style = @import("style.zig").Style;

const viewport: Rect = .init(0, 0, 400, 300);
const away: Vec2 = .init(350, 250);

fn testStyle() Style {
    return .{
        .font = .{ .cell = .init(8, 8) },
        .line_height = 20,
        .padding = .init(4, 4),
        .spacing = 2,
        .text = .white,
        .text_dim = .{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 1 },
        .surface = .black,
        .control = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1 },
        .control_hot = .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1 },
        .control_active = .{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 1 },
        .accent = .{ .r = 0.2, .g = 0.5, .b = 0.9, .a = 1 },
    };
}

const test_icons = [_]skin_mod.Icon{.{
    .name = "warning",
    .source = .{ .image = .of(0), .x = 200, .y = 0, .w = 8, .h = 8 },
}};

fn testSkin() Skin {
    var skin: Skin = .{
        .patch_scale = 2,
        .selection = .{ .r = 0.7, .g = 0.4, .b = 0.2, .a = 1 },
        .icons = &test_icons,
    };
    inline for (std.meta.tags(skin_mod.Part), 0..) |part, i| {
        skin.patches.set(part, .{
            .source = .{ .image = .of(0), .x = @intCast(i + 1), .y = 0, .w = 12, .h = 12 },
            .insets = .all(4),
        });
    }
    return skin;
}

fn frameOf(at: Vec2, phase: enum { up, pressed, held, released }) Input {
    return switch (phase) {
        .up => .at(at, .up),
        .pressed => .at(at, .pressed),
        .held => .at(at, .held),
        .released => .at(at, .released),
    };
}

fn firstPatch(ctx: *const Context) draw.NineSliceCommand {
    for (ctx.list.items()) |command| if (command == .nine_slice) return command.nine_slice;
    unreachable;
}

test "existing controls use their skin parts and keep the flat path when there is no skin" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const skin = testSkin();
    ctx.skin = skin;

    const id = Id.root.child("button");
    const bounds: Rect = .init(0, 0, 100, 20);

    ctx.begin(frameOf(away, .up), viewport);
    _ = try widget.buttonIn(&ctx, id, "button", bounds);
    ctx.end();
    try testing.expectEqual(@intFromEnum(skin_mod.Part.button) + 1, firstPatch(&ctx).source.x);

    const over: Vec2 = .init(50, 10);
    ctx.begin(frameOf(over, .up), viewport);
    _ = try widget.buttonIn(&ctx, id, "button", bounds);
    ctx.end();
    ctx.begin(frameOf(over, .up), viewport);
    _ = try widget.buttonIn(&ctx, id, "button", bounds);
    ctx.end();
    try testing.expectEqual(@intFromEnum(skin_mod.Part.button_hot) + 1, firstPatch(&ctx).source.x);

    ctx.begin(frameOf(over, .pressed), viewport);
    _ = try widget.buttonIn(&ctx, id, "button", bounds);
    ctx.end();
    try testing.expectEqual(@intFromEnum(skin_mod.Part.button_active) + 1, firstPatch(&ctx).source.x);

    ctx.begin(frameOf(over, .held), viewport);
    ctx.beginDisabled();
    _ = try widget.buttonIn(&ctx, id, "button", bounds);
    ctx.endDisabled();
    ctx.end();
    try testing.expectEqual(@intFromEnum(skin_mod.Part.button_disabled) + 1, firstPatch(&ctx).source.x);

    // With no skin the original debug path is byte-for-byte the same command kind.
    ctx.skin = null;
    ctx.begin(frameOf(away, .up), viewport);
    _ = try widget.buttonIn(&ctx, id, "button", bounds);
    ctx.end();
    try testing.expect(ctx.list.items()[0] == .rect);
}

test "the existing widget set maps every applicable surface to the skin" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const skin = testSkin();
    ctx.skin = skin;
    var checked = true;
    var slider_value: f32 = 0.5;
    var field: [8]u8 = undefined;
    var field_len: usize = 0;

    ctx.begin(frameOf(away, .up), viewport);
    try widget.beginPanel(&ctx, Id.root.child("panel"), .init(0, 0, 300, 280));
    _ = try widget.checkbox(&ctx, ctx.childId("check"), "check", &checked);
    _ = try widget.collapsingHeader(&ctx, ctx.childId("header"), "header");
    _ = try widget.slider(&ctx, ctx.childId("slider"), "slider", &slider_value, 0, 1);
    try widget.plot(&ctx, &.{ 0, 1 }, .{});
    _ = try widget.textField(&ctx, ctx.childId("field"), &field, &field_len);
    try widget.beginScroll(&ctx, ctx.childId("scroll"), .init(0, 150, 200, 100), 500);
    try widget.endScroll(&ctx);
    try widget.endPanel(&ctx);
    ctx.end();

    var seen = std.EnumArray(skin_mod.Part, bool).initFill(false);
    for (ctx.list.items()) |command| if (command == .nine_slice) {
        const ordinal = command.nine_slice.source.x - 1;
        if (ordinal < std.meta.fields(skin_mod.Part).len) seen.set(@enumFromInt(ordinal), true);
    };
    inline for ([_]skin_mod.Part{ .panel, .check_on, .row, .field, .scroll_track, .scroll_thumb }) |part| {
        try testing.expect(seen.get(part));
    }
    // A themed check mark is the patch itself, not the old flat inset painted over it.
    try testing.expectEqual(@as(usize, 1), countPart(&ctx, .check_on));
}

fn countPart(ctx: *const Context, part: skin_mod.Part) usize {
    const x: u32 = @intCast(@intFromEnum(part) + 1);
    var count: usize = 0;
    for (ctx.list.items()) |command| {
        if (command == .nine_slice and command.nine_slice.source.x == x) count += 1;
    }
    return count;
}

test "tabs select by index, draw both states from the skin, and capture" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    ctx.skin = testSkin();
    const id = Id.root.child("tabs");
    const second: Vec2 = .init(48, 10);
    const labels = [_][]const u8{ "One", "Two" };

    ctx.begin(frameOf(second, .up), viewport);
    try testing.expectEqual(@as(usize, 0), try tabs(&ctx, id, &labels, 0));
    ctx.end();
    try testing.expect(ctx.wantsPointer());
    try testing.expectEqual(@as(usize, 1), countPart(&ctx, .tab));
    try testing.expectEqual(@as(usize, 1), countPart(&ctx, .tab_on));

    ctx.begin(frameOf(second, .pressed), viewport);
    _ = try tabs(&ctx, id, &labels, 0);
    ctx.end();
    ctx.begin(frameOf(second, .released), viewport);
    try testing.expectEqual(@as(usize, 1), try tabs(&ctx, id, &labels, 0));
    ctx.end();
}

test "a selectable row clicks, captures, and uses the selected part" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    ctx.skin = testSkin();
    const id = Id.root.child("row");
    const over: Vec2 = .init(50, 10);

    ctx.begin(frameOf(over, .up), viewport);
    try testing.expect(!try selectable(&ctx, id, "row", true));
    ctx.end();
    try testing.expect(ctx.wantsPointer());
    try testing.expectEqual(@as(usize, 1), countPart(&ctx, .row_selected));

    ctx.begin(frameOf(over, .pressed), viewport);
    _ = try selectable(&ctx, id, "row", true);
    ctx.end();
    ctx.begin(frameOf(over, .released), viewport);
    try testing.expect(try selectable(&ctx, id, "row", true));
    ctx.end();
}

test "inside a row, a selectable takes what the row has left" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const row = Id.root.child("row");

    ctx.begin(frameOf(away, .up), viewport);
    try widget.beginRow(&ctx, row, ctx.style.line_height);
    widget.spacer(&ctx, 30);
    const before = ctx.region().remaining();
    _ = try selectable(&ctx, row.child("item"), "item", false);
    const after = ctx.region().remaining();
    widget.endRow(&ctx);
    ctx.end();

    // The whole rest of the row, and nothing left over but the spacing after it.
    try testing.expectEqual(@as(f32, 0), after.w);
    try testing.expectEqual(before.x + before.w + ctx.style.spacing, after.x);
    const drawn = ctx.list.items()[0].rect.bounds;
    try testing.expectEqual(before.x, drawn.x);
    try testing.expectEqual(before.w, drawn.w);
}

test "image and icon place opaque image references and a missing icon keeps its slot" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    ctx.skin = testSkin();
    const source: Source = .{ .image = .of(7), .x = 3, .y = 4, .w = 10, .h = 12 };

    ctx.begin(frameOf(away, .up), viewport);
    try image(&ctx, source, .init(20, 24), .white);
    try testing.expect(try icon(&ctx, "warning", .init(8, 8), .white));
    try testing.expect(!try icon(&ctx, "absent", .init(8, 8), .white));
    const next = ctx.region().remaining().y;
    ctx.end();

    try testing.expectEqual(@as(usize, 2), ctx.list.items().len);
    try testing.expectEqual(@as(u32, 7), ctx.list.items()[0].image.source.image.index());
    try testing.expectEqual(@as(u32, 200), ctx.list.items()[1].image.source.x);
    // Three vertical slots, including the absent icon: 24 + 2 + 8 + 2 + 8 + 2.
    try testing.expectEqual(@as(f32, 46), next);
}

test "a grip stays visible when the padding is wider than the grip" {
    var style = testStyle();
    style.padding = .init(10, style.line_height / 2 - 6);
    var ctx: Context = .init(testing.allocator, style);
    defer ctx.deinit();

    ctx.begin(frameOf(away, .up), viewport);
    _ = try reorderList(&ctx, Id.root.child("list"), .init(0, 0, 200, style.line_height), 1);
    ctx.end();

    // Three lines, each half the twelve-point grip wide.
    var lines: usize = 0;
    for (ctx.list.items()) |command| switch (command) {
        .rect => |r| {
            try testing.expectEqual(@as(f32, 6), r.bounds.w);
            lines += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), lines);
}

fn reorderFrame(ctx: *Context, input: Input) !?ReorderMove {
    ctx.begin(input, viewport);
    const list_id = Id.root.child("list");
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const y = @as(f32, @floatFromInt(i)) * 22;
        _ = try selectableIn(ctx, list_id.child("row").childIndex(i), "row", false, .init(0, y, 200, 20));
    }
    const moved = try reorderList(ctx, list_id, .init(0, 0, 200, 86), 4);
    ctx.end();
    return moved;
}

test "a reorder drag returns final indices, draws its insertion, and keeps capture outside" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    ctx.skin = testSkin();
    const second_grip: Vec2 = .init(10, 32);

    try testing.expect(try reorderFrame(&ctx, frameOf(second_grip, .up)) == null);
    try testing.expect(ctx.wantsPointer());
    try testing.expect(try reorderFrame(&ctx, frameOf(second_grip, .pressed)) == null);
    try testing.expectEqual(@as(?u32, 1), ctx.states.peek(Id.root.child("list")).?.reorder_from);

    // Below the last row, and outside the list horizontally: active capture survives and
    // the insertion marker is clamped after the last row.
    try testing.expect(try reorderFrame(&ctx, frameOf(.init(350, 100), .held)) == null);
    try testing.expect(ctx.wantsPointer());
    try testing.expectEqual(@as(u32, 4), ctx.states.peek(Id.root.child("list")).?.reorder_slot);

    const moved = (try reorderFrame(&ctx, frameOf(.init(350, 100), .released))).?;
    try testing.expectEqual(ReorderMove{ .from = 1, .to = 3 }, moved);
    try testing.expectEqual(@as(?u32, null), ctx.states.peek(Id.root.child("list")).?.reorder_from);

    // An insertion after row 2 becomes final index 2 after row 1 is removed. Returning
    // the raw insertion slot would be off by one for every downward move except the last.
    _ = try reorderFrame(&ctx, frameOf(second_grip, .up));
    _ = try reorderFrame(&ctx, frameOf(second_grip, .pressed));
    const down_one = (try reorderFrame(&ctx, frameOf(.init(10, 58), .released))).?;
    try testing.expectEqual(ReorderMove{ .from = 1, .to = 2 }, down_one);
}

test "a reorder gesture forgotten while absent does not return as a phantom drag" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const second_grip: Vec2 = .init(10, 32);

    _ = try reorderFrame(&ctx, frameOf(second_grip, .up));
    _ = try reorderFrame(&ctx, frameOf(second_grip, .pressed));
    try testing.expect(ctx.isActive(Id.root.child("list").child("grip").childIndex(1)));

    // The list is not described on the release frame. Context closes the drag; the list
    // closes its own remembered source when it returns.
    ctx.begin(frameOf(away, .released), viewport);
    ctx.end();
    try testing.expect(try reorderFrame(&ctx, frameOf(away, .up)) == null);
    try testing.expectEqual(@as(?u32, null), ctx.states.peek(Id.root.child("list")).?.reorder_from);
}

fn buttonFrame(ctx: *Context, input: Input, direction: ReorderDirection) !?ReorderMove {
    ctx.begin(input, viewport);
    const moved = try reorderButton(ctx, Id.root.child("move"), "Move", 1, 4, direction);
    ctx.end();
    return moved;
}

test "reorder buttons return the same move and impossible buttons are disabled" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const over: Vec2 = .init(20, 10);

    try testing.expect(try buttonFrame(&ctx, frameOf(over, .up), .bottom) == null);
    try testing.expect(try buttonFrame(&ctx, frameOf(over, .pressed), .bottom) == null);
    const moved = (try buttonFrame(&ctx, frameOf(over, .released), .bottom)).?;
    try testing.expectEqual(ReorderMove{ .from = 1, .to = 3 }, moved);

    try testing.expectEqual(@as(?u32, 1), buttonDestination(2, 4, .up));
    try testing.expectEqual(@as(?u32, 3), buttonDestination(2, 4, .down));
    try testing.expectEqual(@as(?u32, 0), buttonDestination(2, 4, .top));
    try testing.expectEqual(@as(?u32, 3), buttonDestination(2, 4, .bottom));

    ctx.begin(frameOf(over, .up), viewport);
    try testing.expect(try reorderButton(&ctx, Id.root.child("top"), "Top", 0, 4, .top) == null);
    ctx.end();
    try testing.expect(ctx.wantsPointer());
    try testing.expectEqual(testStyle().control.withAlpha(testStyle().disabled_alpha), ctx.list.items()[0].rect.color);
}
