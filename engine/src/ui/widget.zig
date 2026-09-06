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
const state_mod = @import("state.zig");
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
    const side = markerSide(style);
    const text_size = style.font.measure(text, style.text_scale);
    const width = style.padding.x * 2 + side + style.spacing + text_size.x;
    const bounds = ctx.take(.init(width, style.line_height));

    const state = ctx.interact(id, bounds);
    const changed = state.clicked;
    if (changed) value.* = !value.*;

    const tick = squareIn(bounds, style, side);
    try ctx.list.addRect(ctx.gpa, tick, fillFor(style, state));
    if (value.*) {
        // The mark is the box inset by the same padding everything else uses, clamped so a
        // generous padding cannot swallow it. **A quarter of the box, not a half**: half
        // insets the rectangle to zero width, which prevents an inside-out mark by drawing
        // an invisible one instead — a checkbox that could never be seen to be ticked. Any
        // style whose padding reaches half the box hits it, and the sandbox's first one
        // did.
        const mark = @min(style.padding.x, side / 4);
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

/// A bar that drags `value` between `min` and `max`. True on the frame the value moved.
///
/// **The value lives with the caller**, like a checkbox's flag and for the same reason: a
/// slider showing a copy of gravity is a slider that can be wrong about gravity. What the
/// kernel contributes is the drag, which is `active` surviving the pointer leaving the
/// widget — the case `ui.md` §2 names as the reason `active` exists at all.
///
/// **`text` is drawn, not formatted.** A debug slider usually wants to show its value, and
/// a caller that wants that formats it into the label it passes. The kernel has no format
/// string of its own, because that would be a string literal in the one place ADR-0024 asks
/// for none.
pub fn slider(
    ctx: *Context,
    id: Id,
    text: []const u8,
    value: *f32,
    min: f32,
    max: f32,
) Allocator.Error!bool {
    const style = ctx.style;
    const size = style.font.measure(text, style.text_scale);
    const bounds = ctx.take(.init(size.x + style.padding.x * 4, style.line_height));

    const state = ctx.interact(id, bounds);
    var changed = false;
    // A range that is not two numbers is a caller's mistake, and from M7 a mod's: the
    // control draws and refuses to move rather than writing a NaN into the caller's value.
    if (state.active and !bounds.isEmpty() and std.math.isFinite(min) and std.math.isFinite(max)) {
        const wanted = valueAt(ctx.input.pointer.x, bounds, min, max);
        if (wanted != value.*) {
            value.* = wanted;
            changed = true;
        }
    }

    try drawTrack(ctx, bounds, state, fractionOf(value.*, min, max));
    try drawText(ctx, text, bounds, style.text, .center);
    return changed;
}

/// `slider`, over whole numbers.
///
/// A separate function rather than a generic one: the rounding is the whole difference, and
/// a caller of the float version passing whole numbers would get a control that stops on
/// values it cannot represent as an integer. Ranges are clamped to what an `i32` holds
/// before any arithmetic, because `min` and `max` come from a caller.
pub fn sliderInt(
    ctx: *Context,
    id: Id,
    text: []const u8,
    value: *i32,
    min: i32,
    max: i32,
) Allocator.Error!bool {
    const style = ctx.style;
    const size = style.font.measure(text, style.text_scale);
    const bounds = ctx.take(.init(size.x + style.padding.x * 4, style.line_height));

    const low: f32 = @floatFromInt(min);
    const high: f32 = @floatFromInt(max);

    const state = ctx.interact(id, bounds);
    var changed = false;
    if (state.active and !bounds.isEmpty()) {
        // Rounded rather than truncated, so the two halves of a step are the same width and
        // the ends of the range are reachable.
        const wanted: i32 = @intFromFloat(@round(std.math.clamp(
            valueAt(ctx.input.pointer.x, bounds, low, high),
            low,
            high,
        )));
        if (wanted != value.*) {
            value.* = wanted;
            changed = true;
        }
    }

    try drawTrack(ctx, bounds, state, fractionOf(@floatFromInt(value.*), low, high));
    try drawText(ctx, text, bounds, style.text, .center);
    return changed;
}

/// A clickable header that remembers whether it is open, so the caller describes its
/// contents inside an `if`.
///
/// **The open flag is the kernel's**, and it is the first thing that is. A caller could own
/// it, and for one panel that would be better — but an inspector with a header per entity
/// would need an array of bools parallel to the world, which is the second copy immediate
/// mode exists to avoid (`state.zig`).
///
/// Contents are **not** indented. Indenting needs a region and a metric, and a debug tree
/// reads perfectly well without one; a caller that wants it opens a region itself.
pub fn collapsingHeader(ctx: *Context, id: Id, text: []const u8) Allocator.Error!bool {
    const style = ctx.style;
    const side = markerSide(style);
    const size = style.font.measure(text, style.text_scale);
    const width = style.padding.x * 2 + side + style.spacing + size.x;
    const bounds = ctx.take(.init(width, style.line_height));

    const interaction = ctx.interact(id, bounds);
    const state = ctx.stateOf(id);
    if (interaction.clicked) state.open = !state.open;
    const open = state.open;

    try ctx.list.addRect(ctx.gpa, bounds, fillFor(style, interaction));

    // A filled square when open and a hollow one when closed. A triangle would read better
    // and the draw list has no triangle in it (`ui.md` §6); adding one to the vocabulary
    // for a disclosure marker would be the tail wagging the dog.
    const marker = squareIn(bounds, style, side);
    try ctx.list.addRect(ctx.gpa, marker, style.text_dim);
    if (open) {
        const inner = @min(style.padding.x, side / 4);
        try ctx.list.addRect(ctx.gpa, inset(marker, .init(inner, inner)), style.accent);
    }

    const after = marker.x + side + style.spacing;
    try drawText(
        ctx,
        text,
        .init(after, bounds.y, @max(0, bounds.x + bounds.w - after), bounds.h),
        style.text,
        .left,
    );
    return open;
}

/// A window onto contents taller than it is, scrolled by the wheel or by its bar.
///
/// `content` is the total height of what will be described inside, in points, and the
/// caller has to know it — a cursor layout places one widget after the next and never sees
/// the whole (`ui.md` §5). For a list that is `count * (line_height + spacing)`, which is
/// the arithmetic the caller was doing anyway to decide the list was worth scrolling.
///
/// **Clipping does not cull** (`ui.md` §11 and §14): everything described inside still emits
/// its commands, and a scrolling list of ten thousand lines still costs ten thousand text
/// commands. That is a known cost with a known fix, and the fix waits for the profiler M6
/// is building rather than being guessed at now.
pub fn beginScroll(ctx: *Context, id: Id, bounds: Rect, content: f32) Allocator.Error!void {
    const style = ctx.style;
    const clean = layout.sanitize(bounds);
    const height = @max(0, finiteOr(content, 0));
    const span = @max(0, height - clean.h);

    const state = ctx.stateOf(id);
    ctx.blockPointer(clean);

    // One notch is one row, which is the unit the contents are made of.
    if (span > 0 and clean.contains(ctx.input.pointer)) {
        state.scroll -= ctx.input.wheel.y * style.line_height;
    }

    // Clamped before the bar reads it, so a content list that shrank under a scrolled view
    // does not draw a thumb past the end of its track for one frame.
    state.scroll = std.math.clamp(finiteOr(state.scroll, 0), 0, span);

    // The bar is described *before* the contents, so it sits under them in paint order.
    // That is safe because the contents' region is narrowed by exactly its width, and it
    // saves carrying the viewport across to `endScroll` in a third stack.
    const bar = if (span > 0) @max(0, style.scrollbar) else 0;
    if (bar > 0) try scrollbar(ctx, id.child("bar"), clean, bar, height, span, state);

    try ctx.pushClip(clean);
    // The region starts *above* the visible top by the scroll offset, so the cursor places
    // the first row off-screen and the rest follow. Scrolling is layout, not a transform on
    // the draw list, which is what keeps `interact` agreeing with what is on screen.
    try ctx.beginRegion(
        .init(clean.x, clean.y - state.scroll, @max(0, clean.w - bar), height),
        .vertical,
        style.spacing,
        id,
    );
}

pub fn endScroll(ctx: *Context) Allocator.Error!void {
    _ = ctx.endRegion();
    try ctx.popClip();
}

/// One line over a caller-owned array of samples.
///
/// Not interactive and not given an id, for `label`'s reason: there is nothing to click.
/// The samples belong to the caller — a frame profiler already keeps a ring buffer, and a
/// plot that kept its own would be a second copy of it.
///
/// **The line is drawn as one rectangle per sample**, spanning from the previous sample's
/// height to this one's. The draw list has rectangles and text in it and nothing else
/// (`ui.md` §6), and a staircase of thin columns is what a line plot is when that is all
/// there is. A flat run is `separator_thickness` tall rather than nothing.
pub fn plot(ctx: *Context, samples: []const f32, options: PlotOptions) Allocator.Error!void {
    const style = ctx.style;
    const height = @max(0, finiteOr(options.height, style.line_height));
    const bounds = ctx.take(.init(height, height));
    try ctx.list.addRect(ctx.gpa, bounds, style.control);
    if (samples.len == 0 or bounds.isEmpty()) return;

    // Auto-scaled from the data unless the caller says otherwise, because a frame-time plot
    // that rescales is readable and one pinned to a guess is not.
    var low = options.min orelse std.math.floatMax(f32);
    var high = options.max orelse -std.math.floatMax(f32);
    if (options.min == null or options.max == null) {
        for (samples) |raw| {
            const v = finiteOr(raw, 0);
            if (options.min == null) low = @min(low, v);
            if (options.max == null) high = @max(high, v);
        }
    }
    const span = high - low;

    const thickness = @max(0, style.separator_thickness);
    const column = bounds.w / @as(f32, @floatFromInt(samples.len));
    var previous = plotY(sampleAt(samples, options.first, 0), low, span, bounds);

    for (1..samples.len) |i| {
        const y = plotY(sampleAt(samples, options.first, i), low, span, bounds);
        const top = @min(previous, y);
        const tall = @max(thickness, @abs(y - previous));
        try ctx.list.addRect(
            ctx.gpa,
            .init(bounds.x + @as(f32, @floatFromInt(i)) * column, top, @max(thickness, column), tall),
            style.accent,
        );
        previous = y;
    }
}

pub const PlotOptions = struct {
    /// How tall the plot is, in points. Zero uses one row.
    height: f32 = 0,
    /// Index of the **oldest** sample, so a ring buffer can be passed as it is stored
    /// rather than rotated into a copy every frame. Zero for a plain slice.
    first: usize = 0,
    /// Fixed bounds for the vertical axis. Null on either auto-scales that end from the
    /// samples.
    min: ?f32 = null,
    max: ?f32 = null,
};

/// A single-line editable field over a **caller-owned** buffer.
///
/// `len` is how many of `buffer`'s bytes are in use, and the widget rewrites both. Nothing
/// is allocated: a debug filter box is thirty-odd bytes and an allocating text field would
/// be the kernel owning a string it would then have to free at a point immediate mode does
/// not have.
///
/// Editing is insert, backspace, delete, and caret movement. Selection, clipboard and
/// multi-line editing are out at M6 (`ui.md` §15) — with a selection this stops being a
/// widget and starts being a subsystem.
///
/// **Typed bytes are untrusted.** They arrive from a device today and from a mod at M7, so
/// they are validated as UTF-8 and stripped of control characters rather than asserted on,
/// and every caret movement lands on a codepoint boundary.
pub fn textField(ctx: *Context, id: Id, buffer: []u8, len: *usize) Allocator.Error!bool {
    const style = ctx.style;
    const bounds = ctx.take(.init(style.line_height * 8, style.line_height));

    const interaction = ctx.interact(id, bounds);
    const state = ctx.stateOf(id);

    // A caller may have rewritten the buffer since last frame, so nothing about the caret
    // is trusted until it has been checked against what is actually there.
    len.* = @min(len.*, buffer.len);
    state.caret = @min(state.caret, @as(u32, @intCast(len.*)));
    state.caret = @intCast(alignBoundary(buffer[0..len.*], state.caret));

    var changed = false;
    if (ctx.isFocused(id)) {
        // **The one widget that eats typing, and the only thing that says so.** A game
        // reads `wantsKeyboard` to decide whether "w" was a step or a letter, and the
        // answer is this call rather than "something has focus" — a slider with focus is
        // not eating anything (`Context.blockKeyboard`).
        ctx.blockKeyboard();
        changed = edit(ctx, buffer, len, state);
    }

    try ctx.list.addRect(ctx.gpa, bounds, fillFor(style, interaction));
    const text = buffer[0..len.*];
    const inner = inset(bounds, .init(style.padding.x, 0));
    try drawText(ctx, text, inner, style.text, .left);

    // Frames, not milliseconds: the caret blinks the same way on every machine and in every
    // test run, because the number driving it is the one the caller passed in (I9).
    const period = @max(1, style.caret_blink_frames);
    const lit = (ctx.input.frame / period) % 2 == 0;
    if (ctx.isFocused(id) and lit) {
        const before = style.font.measure(text[0..@min(state.caret, text.len)], style.text_scale);
        const thickness = @max(0, style.separator_thickness);
        try ctx.list.addRect(ctx.gpa, .init(
            @round(inner.x + before.x),
            @round(bounds.y + (bounds.h - style.font.cell.y * style.text_scale) / 2),
            thickness,
            style.font.cell.y * style.text_scale,
        ), style.accent);
    }
    return changed;
}

// -- shared --------------------------------------------------------------------------

fn fillFor(style: Style, state: Interaction) Color {
    if (state.active) return style.control_active;
    if (state.hot) return style.control_hot;
    return style.control;
}

fn finiteOr(v: f32, fallback: f32) f32 {
    return if (std.math.isFinite(v)) v else fallback;
}

/// The side of the little square a checkbox and a collapsing header both draw: a row's
/// height less its vertical padding, so the two line up in a column of controls.
fn markerSide(style: Style) f32 {
    return @max(0, style.line_height - style.padding.y * 2);
}

/// That square, placed at the left of `bounds` and vertically centred. Rounded, because a
/// half-point rectangle on a pixel grid is a blurry one.
fn squareIn(bounds: Rect, style: Style, side: f32) Rect {
    return .init(
        @round(bounds.x + style.padding.x),
        @round(bounds.y + (bounds.h - side) / 2),
        side,
        side,
    );
}

/// Where `value` sits between `min` and `max`, as 0 to 1. A zero or non-finite span is the
/// left-hand end rather than a divide by zero: both come from a caller.
fn fractionOf(value: f32, min: f32, max: f32) f32 {
    const span = max - min;
    if (!std.math.isFinite(span) or span == 0) return 0;
    return std.math.clamp((finiteOr(value, min) - min) / span, 0, 1);
}

/// The value a pointer at `x` is asking for.
fn valueAt(x: f32, bounds: Rect, min: f32, max: f32) f32 {
    if (bounds.w <= 0) return min;
    const t = std.math.clamp((finiteOr(x, bounds.x) - bounds.x) / bounds.w, 0, 1);
    return min + (max - min) * t;
}

/// A slider's two rectangles: the whole row, and the part of it left of the value.
fn drawTrack(ctx: *Context, bounds: Rect, state: Interaction, t: f32) Allocator.Error!void {
    const style = ctx.style;
    try ctx.list.addRect(ctx.gpa, bounds, fillFor(style, state));
    try ctx.list.addRect(ctx.gpa, .init(bounds.x, bounds.y, bounds.w * t, bounds.h), style.accent);
}

/// A scroll region's bar. Only described when there is something to scroll, so a list that
/// fits loses no width to it.
///
/// `state` is the region's own entry, passed in rather than looked up again: `Context.stateOf`
/// may grow the map and invalidate a pointer taken before it, so there is exactly one lookup
/// per scroll region and it happens in `beginScroll`.
fn scrollbar(
    ctx: *Context,
    id: Id,
    view: Rect,
    width: f32,
    content: f32,
    span: f32,
    state: *state_mod.State,
) Allocator.Error!void {
    const style = ctx.style;
    const track: Rect = .init(view.x + view.w - width, view.y, width, view.h);
    try ctx.list.addRect(ctx.gpa, track, style.control);

    // The thumb is as much of the track as the view is of the content, never smaller than
    // it is wide — a thumb thinner than that is unhittable, and `scrollbar` is the metric
    // already in hand for how big "small enough to be a problem" is.
    const visible = if (content > 0) @min(1, view.h / content) else 1;
    const thumb_h = @max(width, track.h * visible);
    const travel = @max(0, track.h - thumb_h);

    var at = if (span > 0) std.math.clamp(state.scroll / span, 0, 1) else 0;
    const interaction = ctx.interact(id, track);

    if (interaction.pressed) {
        // Where in the thumb the pointer took hold, so the drag does not snap the thumb's
        // middle to the cursor. A press on the track outside the thumb centres it there,
        // which is the "jump to here" every scrollbar does.
        const offset = ctx.input.pointer.y - (track.y + travel * at);
        state.grab = if (offset >= 0 and offset <= thumb_h) offset else thumb_h / 2;
    }
    if (interaction.active and travel > 0) {
        at = std.math.clamp((ctx.input.pointer.y - state.grab - track.y) / travel, 0, 1);
        state.scroll = at * span;
    }

    try ctx.list.addRect(
        ctx.gpa,
        .init(track.x, track.y + travel * at, width, thumb_h),
        fillFor(style, interaction),
    );
}

/// Where one sample sits vertically. A larger value is a higher line, and screen Y grows
/// downward, so the fraction is inverted here and nowhere else.
fn plotY(v: f32, low: f32, span: f32, bounds: Rect) f32 {
    const t = if (span > 0) std.math.clamp((finiteOr(v, low) - low) / span, 0, 1) else 0.5;
    return bounds.y + bounds.h * (1 - t);
}

/// The `i`th sample of a ring that starts at `first`. `samples.len` is never zero here.
fn sampleAt(samples: []const f32, first: usize, i: usize) f32 {
    return samples[(first +% i) % samples.len];
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// `at`, moved back to the start of the codepoint it lands inside. A caret is only ever
/// between characters, so every operation below can assume it already is one.
fn alignBoundary(text: []const u8, at: usize) usize {
    var i = @min(at, text.len);
    while (i > 0 and i < text.len and isContinuation(text[i])) i -= 1;
    return i;
}

fn prevBoundary(text: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var i = @min(at, text.len) - 1;
    while (i > 0 and isContinuation(text[i])) i -= 1;
    return i;
}

fn nextBoundary(text: []const u8, at: usize) usize {
    if (at >= text.len) return text.len;
    var i = at + 1;
    while (i < text.len and isContinuation(text[i])) i += 1;
    return i;
}

fn removeRange(buffer: []u8, len: *usize, from: usize, to: usize) void {
    std.mem.copyForwards(u8, buffer[from..], buffer[to..len.*]);
    len.* -= to - from;
}

/// One frame of typing applied to a focused field. True if the text changed.
///
/// Everything here is untrusted: the bytes come from a device today and from a mod at M7,
/// so they are validated rather than asserted on, and a sequence that is not valid UTF-8 is
/// dropped rather than stored — a buffer that a later `measure` walks as substitution
/// glyphs would be a field the user cannot see the contents of.
fn edit(ctx: *Context, buffer: []u8, len: *usize, state: *state_mod.State) bool {
    var changed = false;

    for (ctx.input.text) |typed| {
        const bytes = typed.text();
        if (!std.unicode.utf8ValidateSlice(bytes)) continue;

        var it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
        while (it.nextCodepointSlice()) |slice| {
            const codepoint = std.unicode.utf8Decode(slice) catch continue;
            // Single-line: a newline or a tab in a filter box is a character the field
            // cannot show and the caller did not ask for.
            if (codepoint < 0x20 or codepoint == 0x7F) continue;
            if (len.* + slice.len > buffer.len) break;

            const at: usize = state.caret;
            std.mem.copyBackwards(u8, buffer[at + slice.len .. len.* + slice.len], buffer[at..len.*]);
            @memcpy(buffer[at..][0..slice.len], slice);
            len.* += slice.len;
            state.caret = @intCast(at + slice.len);
            changed = true;
        }
    }

    const keys = &ctx.input.keys;
    const caret: usize = state.caret;

    if (keys.wasPressed(.backspace) and caret > 0) {
        const from = prevBoundary(buffer[0..len.*], caret);
        removeRange(buffer, len, from, caret);
        state.caret = @intCast(from);
        changed = true;
    } else if (keys.wasPressed(.delete) and caret < len.*) {
        removeRange(buffer, len, caret, nextBoundary(buffer[0..len.*], caret));
        changed = true;
    }

    // Read after the edits, so a caret moved by one of them is what these move from.
    const now: usize = state.caret;
    if (keys.wasPressed(.left)) state.caret = @intCast(prevBoundary(buffer[0..len.*], now));
    if (keys.wasPressed(.right)) state.caret = @intCast(nextBoundary(buffer[0..len.*], now));
    if (keys.wasPressed(.home)) state.caret = 0;
    if (keys.wasPressed(.end)) state.caret = @intCast(len.*);

    return changed;
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
const platform = @import("platform");
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

test "a tick is visible however generous the padding is" {
    // Found by looking at one: a style with padding half the box's height insets the mark
    // to nothing, and the checkbox draws a rectangle nobody can see. The clamp exists to
    // stop the mark turning inside out, and at a half it does that by deleting it.
    var style = testStyle();
    style.padding = .init(20, 4);
    var ctx: Context = .init(testing.allocator, style);
    defer ctx.deinit();
    var value = true;

    ctx.begin(.at(away, .up), viewport);
    _ = try checkbox(&ctx, Id.root.child("vsync"), "vsync", &value);
    ctx.end();

    // Box, mark, label — and the mark has area.
    const items = ctx.list.items();
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expect(!items[1].rect.bounds.isEmpty());
    try testing.expectEqual(style.accent, items[1].rect.color);
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

// -- the widgets step 5 added ---------------------------------------------------------

/// One frame over `at`, with the primary button in `phase`.
fn frameOf(at: Vec2, phase: enum { up, pressed, held, released }) Input {
    return switch (phase) {
        .up => .at(at, .up),
        .pressed => .at(at, .pressed),
        .held => .at(at, .held),
        .released => .at(at, .released),
    };
}

fn withKey(base: Input, k: platform.Key) Input {
    var in = base;
    platform.key.setKey(&in.keys.keys_pressed, k, true);
    return in;
}

fn withText(base: Input, typed: []const platform.event.TextInput) Input {
    var in = base;
    in.text = typed;
    return in;
}

/// Hover, then press: `hot` resolves at the end of a frame, so a widget cannot be pressed
/// on the first frame the pointer is over it (`Context.hot`).
fn reach(ctx: *Context, at: Vec2, describe: anytype) !void {
    ctx.begin(frameOf(at, .up), viewport);
    try describe(ctx);
    ctx.end();
}

test "a slider follows the pointer, and keeps following it off the end" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("gravity");
    var value: f32 = 0;

    const row: Rect = .init(0, 0, 800, 20);
    const quarter: Vec2 = .init(200, 10);

    // Frame one places the slider and makes it hot; nothing moves yet.
    ctx.begin(frameOf(quarter, .up), viewport);
    _ = try slider(&ctx, id, "gravity", &value, 0, 100);
    ctx.end();
    try testing.expectEqual(@as(f32, 0), value);

    // The press lands a quarter of the way along an 800-wide row.
    ctx.begin(frameOf(quarter, .pressed), viewport);
    const moved = try slider(&ctx, id, "gravity", &value, 0, 100);
    ctx.end();
    try testing.expect(moved);
    try testing.expectApproxEqAbs(@as(f32, 25), value, 1e-4);
    try testing.expectEqual(row.w, ctx.list.items()[0].rect.bounds.w);

    // Dragging past the right-hand edge pins it at the maximum rather than losing the
    // drag — `active` outliving the rectangle is the reason `active` exists (`ui.md` §2).
    ctx.begin(frameOf(.init(5000, 900), .held), viewport);
    _ = try slider(&ctx, id, "gravity", &value, 0, 100);
    ctx.end();
    try testing.expectApproxEqAbs(@as(f32, 100), value, 1e-4);
    try testing.expect(ctx.isActive(id));
}

test "a slider's fill is the fraction of its range, and a bad range moves nothing" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("v");
    var value: f32 = 25;

    ctx.begin(frameOf(away, .up), viewport);
    _ = try slider(&ctx, id, "v", &value, 0, 100);
    ctx.end();
    // Track then fill: a quarter of an 800-wide row.
    try testing.expectApproxEqAbs(@as(f32, 200), ctx.list.items()[1].rect.bounds.w, 1e-4);

    // A range one number wide never divides by it: the fill is empty, and an empty
    // rectangle is not a command (`draw.addRect`), so the track and the label are all
    // there is.
    ctx.begin(frameOf(away, .up), viewport);
    _ = try slider(&ctx, id, "v", &value, 5, 5);
    ctx.end();
    try testing.expectEqual(@as(usize, 2), ctx.list.items().len);
    try testing.expect(ctx.list.items()[1] == .text);

    // And a range that is not two numbers refuses to write one.
    const nan = std.math.nan(f32);
    _ = try reachAndPress(&ctx, .init(400, 10), id, &value, 0, nan);
    try testing.expectEqual(@as(f32, 25), value);
}

fn reachAndPress(ctx: *Context, at: Vec2, id: Id, value: *f32, min: f32, max: f32) !bool {
    ctx.begin(frameOf(at, .up), viewport);
    _ = try slider(ctx, id, "v", value, min, max);
    ctx.end();

    ctx.begin(frameOf(at, .pressed), viewport);
    const changed = try slider(ctx, id, "v", value, min, max);
    ctx.end();
    return changed;
}

test "an integer slider stops on whole numbers and reaches both ends" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("count");
    var value: i32 = 0;

    // A tenth of the way along a range of 0..10 rounds to 1, not to 0.
    for ([_]struct { x: f32, want: i32 }{
        .{ .x = 0, .want = 0 },
        .{ .x = 80, .want = 1 },
        .{ .x = 400, .want = 5 },
        // Just inside the right-hand edge: `Rect.contains` is half-open, so a pointer
        // exactly on `x + w` is over the widget beside this one rather than over this one.
        .{ .x = 799, .want = 10 },
    }) |case| {
        ctx.begin(frameOf(.init(case.x, 10), .up), viewport);
        _ = try sliderInt(&ctx, id, "count", &value, 0, 10);
        ctx.end();

        ctx.begin(frameOf(.init(case.x, 10), .pressed), viewport);
        _ = try sliderInt(&ctx, id, "count", &value, 0, 10);
        ctx.end();
        try testing.expectEqual(case.want, value);

        ctx.begin(frameOf(.init(case.x, 10), .released), viewport);
        _ = try sliderInt(&ctx, id, "count", &value, 0, 10);
        ctx.end();
    }
}

test "a collapsing header remembers, and two of them remember separately" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const first = Id.root.child("transform");
    const second = Id.root.child("visual");
    const on_first: Vec2 = .init(30, 10);

    // Closed to begin with, and describing it a hundred times does not open it.
    for (0..100) |_| {
        ctx.begin(frameOf(away, .up), viewport);
        try testing.expect(!try collapsingHeader(&ctx, first, "Transform"));
        ctx.end();
    }

    ctx.begin(frameOf(on_first, .up), viewport);
    _ = try collapsingHeader(&ctx, first, "Transform");
    ctx.end();
    ctx.begin(frameOf(on_first, .pressed), viewport);
    _ = try collapsingHeader(&ctx, first, "Transform");
    ctx.end();
    ctx.begin(frameOf(on_first, .released), viewport);
    // It reports open on the very frame it was clicked, so the caller describes its
    // contents without a frame of delay.
    try testing.expect(try collapsingHeader(&ctx, first, "Transform"));
    ctx.end();

    // The one below it is untouched, and the open one stays open.
    ctx.begin(frameOf(away, .up), viewport);
    try testing.expect(try collapsingHeader(&ctx, first, "Transform"));
    try testing.expect(!try collapsingHeader(&ctx, second, "Visual"));
    ctx.end();
}

test "an open header draws a mark and a closed one does not" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("h");

    ctx.begin(frameOf(away, .up), viewport);
    _ = try collapsingHeader(&ctx, id, "H");
    ctx.end();
    // Fill, marker, label.
    try testing.expectEqual(@as(usize, 3), ctx.list.items().len);

    ctx.stateOf(id).open = true;
    ctx.begin(frameOf(away, .up), viewport);
    _ = try collapsingHeader(&ctx, id, "H");
    ctx.end();
    const items = ctx.list.items();
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqual(testStyle().accent, items[2].rect.color);
    try testing.expect(!items[2].rect.bounds.isEmpty());
}

/// A scroll region of `rows` rows in a window `visible` tall.
fn scrollFrame(ctx: *Context, in: Input, rows: usize, visible: f32) !void {
    const style = ctx.style;
    const step = style.line_height + style.spacing;
    ctx.begin(in, viewport);
    try beginScroll(ctx, Id.root.child("log"), .init(0, 0, 200, visible), @as(f32, @floatFromInt(rows)) * step);
    for (0..rows) |i| {
        _ = i;
        try label(ctx, "line");
    }
    try endScroll(ctx);
    ctx.end();
}

test "the wheel scrolls a region, and stops at both ends" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("log");

    var wheel_up: Input = .at(.init(100, 50), .up);
    wheel_up.wheel = .init(0, 1);
    var wheel_down: Input = .at(.init(100, 50), .up);
    wheel_down.wheel = .init(0, -1);

    // Twenty rows of 22 in a 100-tall window: 340 points of travel.
    try scrollFrame(&ctx, wheel_down, 20, 100);
    try testing.expectApproxEqAbs(@as(f32, 20), ctx.states.peek(id).?.scroll, 1e-4);

    try scrollFrame(&ctx, wheel_up, 20, 100);
    try testing.expectEqual(@as(f32, 0), ctx.states.peek(id).?.scroll);

    // Down past the end, and it stops at the end rather than running off it.
    for (0..64) |_| try scrollFrame(&ctx, wheel_down, 20, 100);
    try testing.expectApproxEqAbs(@as(f32, 340), ctx.states.peek(id).?.scroll, 1e-4);
}

test "scrolling moves the contents and not the clip" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("log");

    try scrollFrame(&ctx, .at(away, .up), 20, 100);
    const unscrolled = firstLabel(&ctx);
    // Clipped to the window it was given, wherever the contents have gone.
    try testing.expectEqual(Rect.init(0, 0, 200, 100), ctx.list.items()[2].clip_push);

    ctx.stateOf(id).scroll = 44;
    try scrollFrame(&ctx, .at(away, .up), 20, 100);
    try testing.expectApproxEqAbs(unscrolled - 44, firstLabel(&ctx), 1e-4);
    try testing.expectEqual(Rect.init(0, 0, 200, 100), ctx.list.items()[2].clip_push);
}

fn firstLabel(ctx: *const Context) f32 {
    for (ctx.list.items()) |c| if (c == .text) return c.text.at.y;
    return std.math.nan(f32);
}

test "a region whose contents fit has no bar and gives up no width" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    ctx.begin(frameOf(away, .up), viewport);
    try beginScroll(&ctx, ctx.childId("fits"), .init(0, 0, 200, 500), 100);
    try testing.expectEqual(Rect.init(0, 0, 200, 20), ctx.region().take(20));
    try endScroll(&ctx);
    ctx.end();

    // Clip, label-less contents, pop: no track and no thumb.
    try testing.expectEqual(@as(usize, 2), ctx.list.items().len);
    try testing.expect(ctx.list.items()[0] == .clip_push);

    // And one that does not fit loses exactly the bar's width.
    ctx.begin(frameOf(away, .up), viewport);
    try beginScroll(&ctx, ctx.childId("overflows"), .init(0, 0, 200, 100), 500);
    try testing.expectEqual(Rect.init(0, 0, 188, 20), ctx.region().take(20));
    try endScroll(&ctx);
    ctx.end();
}

test "dragging the bar scrolls, without snapping the thumb to the pointer" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("log");
    const bar = id.child("bar");

    // The track is the right-hand 12 points of a 200x100 window, and the thumb is at the
    // top. Take hold of it a third of the way down its own height.
    const grab: Vec2 = .init(194, 6);
    try scrollFrame(&ctx, frameOf(grab, .up), 20, 100);
    try testing.expectEqual(@as(f32, 0), ctx.states.peek(id).?.scroll);

    try scrollFrame(&ctx, frameOf(grab, .pressed), 20, 100);
    // The press alone does not move it: the pointer is already inside the thumb, so the
    // grab offset is where it landed rather than the thumb's middle.
    try testing.expectApproxEqAbs(@as(f32, 0), ctx.states.peek(id).?.scroll, 1e-4);
    // On the region's own entry, not the bar's: a scroll region has exactly one bar, so
    // one lookup does for both (`scrollbar`).
    try testing.expectApproxEqAbs(@as(f32, 6), ctx.states.peek(id).?.grab, 1e-4);

    // Twenty points down the track is twenty points of travel, scaled to the content.
    try scrollFrame(&ctx, frameOf(.init(194, 26), .held), 20, 100);
    try testing.expect(ctx.states.peek(id).?.scroll > 0);
    try testing.expect(ctx.isActive(bar));

    // Dragging far past the bottom pins it at the end.
    try scrollFrame(&ctx, frameOf(.init(194, 9000), .held), 20, 100);
    try testing.expectApproxEqAbs(@as(f32, 340), ctx.states.peek(id).?.scroll, 1e-4);
}

test "a text field types, deletes and moves by whole characters" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("filter");

    var buffer: [32]u8 = undefined;
    var len: usize = 0;

    const hi = [_]platform.event.TextInput{platform.event.TextInput.fromSlice("hi").?};
    // é is two bytes and one character, which is the case a byte-wise caret gets wrong.
    const accent = [_]platform.event.TextInput{platform.event.TextInput.fromSlice("\u{e9}").?};

    // Focus first: an unfocused field ignores everything typed at it.
    ctx.begin(withText(frameOf(away, .up), &hi), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    try testing.expectEqual(@as(usize, 0), len);

    ctx.begin(frameOf(over, .up), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    ctx.begin(frameOf(over, .pressed), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    try testing.expect(ctx.isFocused(id));

    ctx.begin(withText(frameOf(over, .up), &hi), viewport);
    try testing.expect(try textField(&ctx, id, &buffer, &len));
    ctx.end();
    try testing.expectEqualStrings("hi", buffer[0..len]);

    ctx.begin(withText(frameOf(over, .up), &accent), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    try testing.expectEqualStrings("hi\u{e9}", buffer[0..len]);
    try testing.expectEqual(@as(u32, 4), ctx.stateOf(id).caret);

    // One backspace takes the whole two-byte character, not half of it.
    ctx.begin(withKey(frameOf(over, .up), .backspace), viewport);
    try testing.expect(try textField(&ctx, id, &buffer, &len));
    ctx.end();
    try testing.expectEqualStrings("hi", buffer[0..len]);

    // Home, then delete, takes the first character and leaves the caret alone.
    ctx.begin(withKey(frameOf(over, .up), .home), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    ctx.begin(withKey(frameOf(over, .up), .delete), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    try testing.expectEqualStrings("i", buffer[0..len]);
    try testing.expectEqual(@as(u32, 0), ctx.stateOf(id).caret);
}

test "a text field refuses what it cannot hold and what it cannot show" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("filter");

    var buffer: [4]u8 = undefined;
    var len: usize = 0;

    ctx.focus = id;
    const long = [_]platform.event.TextInput{platform.event.TextInput.fromSlice("abcdefgh").?};
    ctx.begin(withText(frameOf(over, .up), &long), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    // Filled and no further: a caller's buffer is a bound, not a suggestion.
    try testing.expectEqualStrings("abcd", buffer[0..len]);

    // Control characters and invalid UTF-8 are dropped rather than stored. A tab in a
    // single-line field is a character it cannot show, and bad bytes would draw as
    // substitution glyphs the user cannot delete meaningfully.
    len = 0;
    var nasty: platform.event.TextInput = .{ .len = 3 };
    nasty.bytes[0] = '\t';
    nasty.bytes[1] = 0xFF;
    nasty.bytes[2] = 'a';
    ctx.begin(withText(frameOf(over, .up), &.{nasty}), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    try testing.expectEqual(@as(usize, 0), len);
}

test "the caret blinks on the frame counter, not on a clock" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("filter");
    var buffer: [8]u8 = undefined;
    var len: usize = 0;
    ctx.focus = id;

    var lit: usize = 0;
    for (0..testStyle().caret_blink_frames * 4) |i| {
        var in = frameOf(away, .up);
        in.frame = i;
        ctx.begin(in, viewport);
        _ = try textField(&ctx, id, &buffer, &len);
        ctx.end();
        // Background, and a caret on the frames it is showing.
        if (ctx.list.items().len == 2) lit += 1;
    }
    // Exactly half the frames, every run, on every machine (I9).
    try testing.expectEqual(@as(usize, testStyle().caret_blink_frames * 2), lit);
}

test "a press that reaches nothing takes the keyboard away" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const id = Id.root.child("filter");
    var buffer: [8]u8 = undefined;
    var len: usize = 0;

    ctx.begin(frameOf(over, .up), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    ctx.begin(frameOf(over, .pressed), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    try testing.expect(ctx.wantsKeyboard());

    // The frame of the press is still the field's: `edit` ran with the old focus and has
    // already taken this frame's characters, so a game reading them too would read them
    // twice. Focus goes now; the keyboard goes on the next frame the field is described
    // without it.
    ctx.begin(frameOf(away, .pressed), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    try testing.expect(!ctx.isFocused(id));
    try testing.expect(ctx.wantsKeyboard());

    ctx.begin(frameOf(away, .up), viewport);
    _ = try textField(&ctx, id, &buffer, &len);
    ctx.end();
    try testing.expect(!ctx.wantsKeyboard());
}

test "a plot is one rectangle per sample, over a background" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();
    const samples = [_]f32{ 0, 1, 2, 3, 4, 5 };

    ctx.begin(frameOf(away, .up), viewport);
    try plot(&ctx, &samples, .{ .height = 40 });
    ctx.end();
    // The field, then a column joining each sample to the one before it.
    try testing.expectEqual(samples.len, ctx.list.items().len);

    // The line rises to the right, so each column starts above the last.
    const items = ctx.list.items();
    var previous = items[1].rect.bounds.y;
    for (items[2..]) |c| {
        try testing.expect(c.rect.bounds.y <= previous);
        previous = c.rect.bounds.y;
    }
}

test "a plot reads a ring buffer where it starts, and survives nothing to draw" {
    var ctx: Context = .init(testing.allocator, testStyle());
    defer ctx.deinit();

    // The same six values, stored with the oldest in the middle.
    const rotated = [_]f32{ 3, 4, 5, 0, 1, 2 };
    ctx.begin(frameOf(away, .up), viewport);
    try plot(&ctx, &rotated, .{ .height = 40, .first = 3 });
    ctx.end();

    const items = ctx.list.items();
    var previous = items[1].rect.bounds.y;
    for (items[2..]) |c| {
        try testing.expect(c.rect.bounds.y <= previous);
        previous = c.rect.bounds.y;
    }

    // No samples, and a flat line, both draw something rather than dividing by a span.
    ctx.begin(frameOf(away, .up), viewport);
    try plot(&ctx, &.{}, .{ .height = 40 });
    try plot(&ctx, &.{ 7, 7, 7 }, .{ .height = 40 });
    ctx.end();
    try testing.expectEqual(@as(usize, 4), ctx.list.items().len);
}
