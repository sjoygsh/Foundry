//! The widgets: containers that place things, and controls that read the interaction model.
//!
//! Every widget here has the same shape. It works out how big it wants to be, asks the
//! current region for a rectangle, hands that rectangle to `Context.interact` if it is a
//! control, and describes itself into the draw list from what it was told. Nothing here
//! draws to a renderer and nothing here reads a device, so all of it is testable by
//! inspecting the resulting command list.
//!
//! Widgets take **identity and display text as separate parameters**, always (`id.zig`).
//! The debug widget set may offer a shorthand that derives one from the other; the kernel
//! does not, so the game layer cannot acquire the habit.
//!
//! **No colour, metric or string below is a literal.** Every number a widget uses to decide
//! its size or its appearance comes from `ctx.style`, which is what makes a content-driven
//! theme a new producer rather than a rewrite (ADR-0024).
//!
//! Design: `docs/design/ui.md` §5 and §10.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Rect = core.math.Rect;
const Vec2 = core.math.Vec2;
const Context = @import("context.zig").Context;
const Interaction = @import("context.zig").Interaction;
const Id = @import("id.zig").Id;
const layout = @import("layout.zig");
const Color = @import("style.zig").Color;
const Style = @import("style.zig").Style;

// -- containers ----------------------------------------------------------------------

/// A filled, clipped rectangle that widgets stack down the inside of, until `endPanel`.
///
/// Three things at once, and they are separable on purpose: a surface is drawn, the pointer
/// is taken from the game while it is inside (`Context.blockPointer`), and a region is
/// opened inset by the style's padding. A caller that wants only the third can call
/// `Context.beginRegion` directly.
pub fn beginPanel(ctx: *Context, id: Id, bounds: Rect) Allocator.Error!void {
    const clean = layout.sanitize(bounds);
    const style = ctx.style;

    try ctx.list.addRect(ctx.gpa, clean, style.surface);
    try ctx.pushClip(clean);
    ctx.blockPointer(clean);

    try ctx.beginRegion(inset(clean, style.padding), .vertical, style.spacing, id);
}

pub fn endPanel(ctx: *Context) Allocator.Error!void {
    _ = ctx.endRegion();
    try ctx.popClip();
}

/// A horizontal strip `height` tall, taken from the enclosing region, that widgets are
/// placed across until `endRow`.
///
/// The strip is reserved along the enclosing region's axis, so a row inside a panel is a
/// full-width band — which is what a row is for. A row inside another row reserves `height`
/// of *width* instead; that is unusual rather than wrong, and it is stated here so the
/// arithmetic is not a surprise.
pub fn beginRow(ctx: *Context, id: Id, height: f32) Allocator.Error!void {
    const bounds = ctx.region().take(height);
    try ctx.beginRegion(bounds, .horizontal, ctx.style.spacing, id);
}

pub fn endRow(ctx: *Context) void {
    _ = ctx.endRegion();
}

// -- widgets -------------------------------------------------------------------------

/// A line of text occupying a row of its own. Not interactive and not given an id: there is
/// nothing to click, and an id that names nothing would still cost a collision check.
pub fn label(ctx: *Context, text: []const u8) Allocator.Error!void {
    const style = ctx.style;
    const size = style.font.measure(text, style.text_scale);
    const bounds = ctx.take(.init(size.x + style.padding.x * 2, style.line_height));
    try drawText(ctx, text, inset(bounds, .init(style.padding.x, 0)), style.text, .left);
}

/// A dividing line across the region, with a gap either side of it.
pub fn separator(ctx: *Context) Allocator.Error!void {
    const style = ctx.style;
    const thickness = @max(0, style.separator_thickness);
    const main = thickness + style.spacing * 2;
    const bounds = ctx.take(.init(main, main));

    // Centred in the space it reserved, and spanning the region across its axis, so the
    // same call divides a column of controls and a row of them.
    const line: Rect = switch (ctx.region().axis) {
        .vertical => .init(bounds.x, bounds.y + (bounds.h - thickness) / 2, bounds.w, thickness),
        .horizontal => .init(bounds.x + (bounds.w - thickness) / 2, bounds.y, thickness, bounds.h),
    };
    try ctx.list.addRect(ctx.gpa, line, style.text_dim);
}

/// Blank space `size` along the region's axis. Draws nothing and cannot fail.
pub fn spacer(ctx: *Context, size: f32) void {
    _ = ctx.take(.init(size, size));
}

/// A clickable rectangle with a centred label, sized to its text and placed by the current
/// region. True on the frame the pointer is released over it having gone down on it.
pub fn button(ctx: *Context, id: Id, text: []const u8) Allocator.Error!bool {
    const style = ctx.style;
    const size = style.font.measure(text, style.text_scale);
    const bounds = ctx.take(.init(size.x + style.padding.x * 2, style.line_height));
    return buttonIn(ctx, id, text, bounds);
}

/// `button`, at a rectangle the caller worked out itself.
///
/// Kept alongside the laid-out form because a debug overlay is not always inside a panel —
/// a single button pinned to a screen corner has no region worth opening — and because it
/// is the form every layout test can check without also testing the cursor.
///
/// Errors only on allocation, and only from the draw list: interaction itself cannot fail,
/// so a caller that runs out of memory mid-frame has already been told what the user did.
pub fn buttonIn(ctx: *Context, id: Id, text: []const u8, bounds: Rect) Allocator.Error!bool {
    const state = ctx.interact(id, bounds);

    // A duplicate id still draws. An inert control is easier to find than a missing one,
    // and the log line from `interact` says which id was reused.
    try ctx.list.addRect(ctx.gpa, bounds, fillFor(ctx.style, state));
    try drawText(ctx, text, bounds, ctx.style.text, .center);
    return state.clicked;
}

/// A box that toggles `value`, with its label to the right. True on the frame it changed,
/// so a caller can act on the change rather than polling the value it already owns.
///
/// The value lives with the caller, not in the kernel. That is the immediate-mode bargain:
/// there is no second copy of the flag inside the UI that can drift from the real one.
pub fn checkbox(ctx: *Context, id: Id, text: []const u8, value: *bool) Allocator.Error!bool {
    const style = ctx.style;
    const side = @max(0, style.line_height - style.padding.y * 2);
    const text_size = style.font.measure(text, style.text_scale);
    const width = style.padding.x * 2 + side + style.spacing + text_size.x;
    const bounds = ctx.take(.init(width, style.line_height));

    const state = ctx.interact(id, bounds);
    const changed = state.clicked;
    if (changed) value.* = !value.*;

    const tick: Rect = .init(
        @round(bounds.x + style.padding.x),
        @round(bounds.y + (bounds.h - side) / 2),
        side,
        side,
    );
    try ctx.list.addRect(ctx.gpa, tick, fillFor(style, state));
    if (value.*) {
        // The mark is the box inset by the same padding everything else uses, clamped so a
        // generous padding cannot turn it inside out.
        const mark = @min(style.padding.x, side / 2);
        try ctx.list.addRect(ctx.gpa, inset(tick, .init(mark, mark)), style.accent);
    }

    const after_box = tick.x + side + style.spacing;
    const text_bounds: Rect = .init(
        after_box,
        bounds.y,
        @max(0, bounds.x + bounds.w - after_box),
        bounds.h,
    );
    try drawText(ctx, text, text_bounds, style.text, .left);
    return changed;
}

// -- shared --------------------------------------------------------------------------

fn fillFor(style: Style, state: Interaction) Color {
    if (state.active) return style.control_active;
    if (state.hot) return style.control_hot;
    return style.control;
}

fn inset(r: Rect, by: Vec2) Rect {
    return .init(
        r.x + by.x,
        r.y + by.y,
        @max(0, r.w - by.x * 2),
        @max(0, r.h - by.y * 2),
    );
}

/// Text placed in `bounds` and measured with the same arithmetic the renderer will draw it
/// with (`style.FontMetrics.measure`), so a label that fits here fits there.
///
/// Rounded to whole units so a glyph grid stays on the pixel grid. A half-pixel label is
/// the difference between a crisp bitmap font and a blurry one, and centring is exactly
/// where the halves come from.
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
    const at: Vec2 = .init(@round(x), @round(bounds.y + (bounds.h - size.y) / 2));
    try ctx.list.addText(ctx.gpa, at, text, color, scale);
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;
const Input = @import("input.zig").Input;
const draw = @import("draw.zig");

fn testStyle() Style {
    return .{
        .font = .{ .cell = .init(8, 8) },
        .line_height = 20,
        .padding = .init(4, 4),
        .spacing = 2,
        .text = .white,
        .text_dim = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 },
        .surface = .black,
        .control = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1 },
        .control_hot = .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1 },
        .control_active = .{ .r = 0.4, .g = 0.4, .b = 0.4, .a = 1 },
        .accent = .{ .r = 0.2, .g = 0.5, .b = 0.9, .a = 1 },
    };
}

const viewport: Rect = .init(0, 0, 800, 600);
const box: Rect = .init(0, 0, 100, 20);
const over: Vec2 = .init(50, 10);
const away: Vec2 = .init(500, 500);

fn frame(ctx: *Context, input: Input, text: []const u8) Allocator.Error!bool {
    ctx.begin(input, viewport);
    const clicked = try buttonIn(ctx, Id.root.child("ok"), text, box);
    ctx.end();
    return clicked;
}

test "a button describes a rectangle and a label, in that order" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    _ = try frame(&ctx, .at(away, .up), "Save");

    const items = ctx.list.items();
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expect(items[0] == .rect);
    try testing.expectEqual(box, items[0].rect.bounds);
    try testing.expectEqualStrings("Save", ctx.list.textOf(items[1].text.text));
}

test "the label is centred by the same measurement the renderer will use" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    _ = try frame(&ctx, .at(away, .up), "Save");

    // Four 8-pixel cells in a 100-wide box: (100 - 32) / 2 = 34. One 8-pixel line in a
    // 20-tall box: (20 - 8) / 2 = 6.
    const at = ctx.list.items()[1].text.at;
    try testing.expectEqual(Vec2.init(34, 6), at);
}

test "the fill follows hot and active, one frame behind the pointer" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const style = testStyle();

    _ = try frame(&ctx, .at(away, .up), "Save");
    try testing.expectEqual(style.control, ctx.list.items()[0].rect.color);

    // The pointer arrives. `hot` is resolved at the *end* of a frame so that the topmost
    // widget wins whatever order the frame described things in, so this frame still draws
    // cold — the one frame of latency `Context.hot` documents, pinned here so a future
    // session changing the resolution point finds out from a test rather than from a user.
    _ = try frame(&ctx, .at(over, .up), "Save");
    try testing.expectEqual(style.control, ctx.list.items()[0].rect.color);

    _ = try frame(&ctx, .at(over, .up), "Save");
    try testing.expectEqual(style.control_hot, ctx.list.items()[0].rect.color);

    _ = try frame(&ctx, .at(over, .pressed), "Save");
    try testing.expectEqual(style.control_active, ctx.list.items()[0].rect.color);
}

test "clicking it returns true exactly once" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    try testing.expect(!try frame(&ctx, .at(over, .up), "Save"));
    try testing.expect(!try frame(&ctx, .at(over, .pressed), "Save"));
    try testing.expect(try frame(&ctx, .at(over, .released), "Save"));
    try testing.expect(!try frame(&ctx, .at(over, .up), "Save"));
}

test "an empty label draws the control and nothing else" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    _ = try frame(&ctx, .at(away, .up), "");
    try testing.expectEqual(@as(usize, 1), ctx.list.items().len);
}

test "a label that is not valid UTF-8 is measured, not refused" {
    // Text reaching a widget is untrusted from M7 (CLAUDE.md §7): a mod's translation file
    // is text from a stranger. It measures as substitution glyphs and draws as them.
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    _ = try frame(&ctx, .at(away, .up), "\xff\xfe");
    const items = ctx.list.items();
    try testing.expectEqual(@as(usize, 2), items.len);
    // Two substitutes, sixteen units wide: (100 - 16) / 2 = 42.
    try testing.expectEqual(@as(f32, 42), items[1].text.at.x);
}

test "a panel fills, clips, and insets what is placed inside it" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const panel: Rect = .init(10, 10, 200, 100);

    ctx.begin(.at(away, .up), viewport);
    try beginPanel(&ctx, ctx.childId("stats"), panel);
    // Padded by 4 on every side, so the first row starts at (14, 14) and is 192 wide.
    try testing.expectEqual(Rect.init(14, 14, 192, 20), ctx.region().take(20));
    try endPanel(&ctx);
    ctx.end();

    const items = ctx.list.items();
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(panel, items[0].rect.bounds);
    try testing.expectEqual(panel, items[1].clip_push);
    try testing.expect(items[2] == .clip_pop);
    try testing.expectEqual(@as(u32, 0), ctx.list.clipDepth());
}

test "a panel takes the pointer even where there is no control" {
    // The reason `pointer_blocked` exists: a click on a panel's empty half must not also
    // walk the player. Nothing here is hot, so hot/active alone would say the UI is idle.
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const panel: Rect = .init(0, 0, 200, 100);

    ctx.begin(.at(.init(150, 80), .up), viewport);
    try beginPanel(&ctx, ctx.childId("stats"), panel);
    try endPanel(&ctx);
    ctx.end();

    try testing.expect(ctx.hot.isNone());
    try testing.expect(ctx.wantsPointer());

    // And it lets go the moment the pointer leaves.
    ctx.begin(.at(away, .up), viewport);
    try beginPanel(&ctx, ctx.childId("stats"), panel);
    try endPanel(&ctx);
    ctx.end();
    try testing.expect(!ctx.wantsPointer());
}

test "a row places widgets across and then the panel carries on down" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(.at(away, .up), viewport);
    try beginPanel(&ctx, ctx.childId("panel"), .init(0, 0, 200, 100));
    try beginRow(&ctx, ctx.childId("row"), 20);
    // Two buttons side by side, each sized to its text plus padding: 4 + 8*2 + 4 = 24.
    _ = try button(&ctx, ctx.childId("a"), "ab");
    _ = try button(&ctx, ctx.childId("b"), "cd");
    endRow(&ctx);
    // Back in the panel, below the row and one spacing down: 4 + 20 + 2 = 26.
    try testing.expectEqual(Rect.init(4, 26, 192, 20), ctx.region().take(20));
    try endPanel(&ctx);
    ctx.end();

    const items = ctx.list.items();
    // surface, clip_push, button a (rect + text), button b (rect + text), clip_pop.
    try testing.expectEqual(Rect.init(4, 4, 24, 20), items[2].rect.bounds);
    try testing.expectEqual(Rect.init(30, 4, 24, 20), items[4].rect.bounds);
}

test "a label sits inside the padding of the row it reserved" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(.at(away, .up), viewport);
    try label(&ctx, "hi");
    ctx.end();

    // Left-aligned at the padding, vertically centred in a 20-tall row: (20 - 8) / 2 = 6.
    try testing.expectEqual(Vec2.init(4, 6), ctx.list.items()[0].text.at);
}

test "a separator is a thin line with a gap either side" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(.at(away, .up), viewport);
    try separator(&ctx);
    const next = ctx.region().take(20);
    ctx.end();

    // Thickness 1 with 2 of spacing either side: a 5-tall reservation, line centred in it.
    try testing.expectEqual(Rect.init(0, 2, 800, 1), ctx.list.items()[0].rect.bounds);
    // The reservation, then the region's own spacing: 5 + 2.
    try testing.expectEqual(@as(f32, 7), next.y);
}

test "a spacer moves the cursor and draws nothing" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(.at(away, .up), viewport);
    spacer(&ctx, 30);
    const next = ctx.region().take(20);
    ctx.end();

    try testing.expectEqual(@as(usize, 0), ctx.list.items().len);
    try testing.expectEqual(@as(f32, 32), next.y);
}

test "a checkbox toggles the caller's flag and reports the frame it changed" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    var value = false;

    const id = Id.root.child("vsync");
    // Sized: padding 4, box 12, spacing 2, five 8-wide glyphs, padding 4 — 62 wide.
    const on_it: Vec2 = .init(20, 10);

    ctx.begin(.at(on_it, .up), viewport);
    _ = try checkbox(&ctx, id, "vsync", &value);
    ctx.end();
    try testing.expect(!value);

    ctx.begin(.at(on_it, .pressed), viewport);
    _ = try checkbox(&ctx, id, "vsync", &value);
    ctx.end();
    try testing.expect(!value);

    ctx.begin(.at(on_it, .released), viewport);
    const changed = try checkbox(&ctx, id, "vsync", &value);
    ctx.end();
    try testing.expect(changed);
    try testing.expect(value);

    // The mark appears only once it is set: box, mark, then the label.
    ctx.begin(.at(on_it, .up), viewport);
    _ = try checkbox(&ctx, id, "vsync", &value);
    ctx.end();
    const items = ctx.list.items();
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(testStyle().accent, items[1].rect.color);
    try testing.expectEqualStrings("vsync", ctx.list.textOf(items[2].text.text));
}

test "a widget past the bottom of its panel still occupies space and still draws" {
    // `ui.md` §11: clipping is a draw concern, not a layout one. The kernel emits the
    // commands and the clip rectangle it emitted them under; what is visible is the
    // walker's business, and culling is an open question rather than a silent behaviour.
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(.at(away, .up), viewport);
    try beginPanel(&ctx, ctx.childId("panel"), .init(0, 0, 100, 30));
    try label(&ctx, "one");
    try label(&ctx, "two");
    try endPanel(&ctx);
    ctx.end();

    const items = ctx.list.items();
    // surface, clip_push, two labels, clip_pop — nothing dropped.
    try testing.expectEqual(@as(usize, 5), items.len);
    // The second label is below the panel's bottom edge, and says so.
    try testing.expect(items[3].text.at.y > 30);
}
