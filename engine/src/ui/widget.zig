//! One widget, to prove the loop.
//!
//! Step 1 of `ui.md` §16 builds the kernel and exactly one widget. `button` is the right
//! one because it exercises every part of the model — identity, hot, active, the click
//! rule, the style, text measurement and the draw list — and needs none of the layout that
//! step 2 adds. That is also why it takes explicit bounds: there is no cursor yet, and
//! inventing one here would put layout in the wrong file.
//!
//! Widgets take **identity and display text as separate parameters**, always (`id.zig`).
//! The debug widget set may offer a shorthand that derives one from the other; the kernel
//! does not, so the game layer cannot acquire the habit.
//!
//! Design: `docs/design/ui.md` §10.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Rect = core.math.Rect;
const Vec2 = core.math.Vec2;
const Context = @import("context.zig").Context;
const Id = @import("id.zig").Id;

/// A clickable rectangle with a centred label. True on the frame the pointer is released
/// over it having gone down on it.
///
/// Errors only on allocation, and only from the draw list: interaction itself cannot fail,
/// so a caller that runs out of memory mid-frame has already been told what the user did.
pub fn button(ctx: *Context, id: Id, label: []const u8, bounds: Rect) Allocator.Error!bool {
    const state = ctx.interact(id, bounds);

    // A duplicate id still draws. An inert control is easier to find than a missing one,
    // and the log line from `interact` says which id was reused.
    const fill = if (state.active)
        ctx.style.control_active
    else if (state.hot)
        ctx.style.control_hot
    else
        ctx.style.control;

    try ctx.list.addRect(ctx.gpa, bounds, fill);
    try labelCentred(ctx, label, bounds);
    return state.clicked;
}

/// The label, centred in `bounds` and measured with the same arithmetic the renderer will
/// draw it with (`style.FontMetrics.measure`).
fn labelCentred(ctx: *Context, label: []const u8, bounds: Rect) Allocator.Error!void {
    if (label.len == 0) return;
    const scale = ctx.style.text_scale;
    const size = ctx.style.font.measure(label, scale);

    // Rounded to whole units so a glyph grid stays on the pixel grid. A half-pixel label
    // is the difference between a crisp bitmap font and a blurry one, and centring is
    // exactly where the halves come from.
    const at: Vec2 = .init(
        @round(bounds.x + (bounds.w - size.x) / 2),
        @round(bounds.y + (bounds.h - size.y) / 2),
    );
    try ctx.list.addText(ctx.gpa, at, label, ctx.style.text, scale);
}

const testing = std.testing;
const Input = @import("input.zig").Input;
const Style = @import("style.zig").Style;
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

const box: Rect = .init(0, 0, 100, 20);
const over: Vec2 = .init(50, 10);
const away: Vec2 = .init(500, 500);

fn frame(ctx: *Context, input: Input, label: []const u8) Allocator.Error!bool {
    ctx.begin(input);
    const clicked = try button(ctx, Id.root.child("ok"), label, box);
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
