//! The UI portion of `FoundryApi_v1`.
//!
//! `abi` does not own a UI context. A host lends one, along with the input snapshot captured
//! for the current frame, and these calls only validate arguments, invoke one kernel operation
//! and return a result. The draw list remains host-owned and is not exposed to a mod; the host
//! walks it after `ui_end`.
//!
//! Design: `docs/design/public-abi.md` §6 and §9; `docs/design/ui.md` §13.

const std = @import("std");
const core = @import("core");
const ui = @import("ui");

const types = @import("types.zig");
const ui_types = @import("ui_types.zig");

const Allocator = std.mem.Allocator;
const Result = types.Result;
const Bool = types.Bool;
const Str = types.Str;
const Id = ui_types.Id;
const Rect = ui_types.Rect;
const Style = ui_types.Style;
const PlotOptions = ui_types.PlotOptions;

/// A mod cannot make the kernel allocate an unbounded command or temporary text buffer in one
/// call. This is a bound, not a promise that a whole frame fits in it.
pub const max_text_bytes: u64 = 1 << 20;
pub const max_plot_samples: u64 = 1 << 20;

pub fn Of(comptime H: type) type {
    return struct {
        fn context() ?*ui.Context {
            const h = H.current() orelse return null;
            return h.ui_context;
        }

        fn frame() ?struct { host: *H, context: *ui.Context } {
            const h = H.current() orelse return null;
            const ctx = h.ui_context orelse return null;
            if (!ctx.in_frame) return null;
            return .{ .host = h, .context = ctx };
        }

        /// An optional frame cannot distinguish an absent UI context from a call made
        /// outside a frame. Keep those refusal codes distinct: an empty host is
        /// `unavailable`, while a supplied context that is not open is `refused`.
        fn frameFailure() Result {
            const h = H.current() orelse return .unavailable;
            const ctx = h.ui_context orelse return .unavailable;
            return if (ctx.in_frame) .ok else .refused;
        }

        fn resultOf(err: Allocator.Error) Result {
            return switch (err) {
                error.OutOfMemory => .out_of_memory,
            };
        }

        fn finite(value: f32) bool {
            return std.math.isFinite(value);
        }

        fn validRect(value: Rect) bool {
            return finite(value.x) and finite(value.y) and finite(value.w) and finite(value.h);
        }

        fn toRect(value: Rect) core.math.Rect {
            return .init(value.x, value.y, value.w, value.h);
        }

        fn validId(value: Id) bool {
            return !value.isNone();
        }

        fn text(value: Str) ?[]const u8 {
            if (value.len > max_text_bytes) return null;
            return value.utf8();
        }

        fn internalId(ctx: *ui.Context, h: *const H, value: Id) ui.Id {
            // Region seeds and explicit pushed ids are both identity scopes. Keep the
            // explicit stack as raw values so a push made outside a panel still composes
            // with the panel's seed when the widget is described inside it; using only the
            // top pushed seed would erase that region boundary and alias sibling panels.
            var seed = ctx.region().seed;
            var index: u32 = 0;
            while (index < h.ui_state.depth) : (index += 1) {
                seed = seed.childIndex(@intCast(h.ui_state.ids[index].bits));
            }
            return seed.childIndex(@intCast(value.bits));
        }

        fn resultId(ctx: *ui.Context, h: *const H, value: Id) ?ui.Id {
            if (!validId(value)) return null;
            return internalId(ctx, h, value);
        }

        fn validColor(value: ui_types.Color) bool {
            return finite(value.r) and finite(value.g) and finite(value.b) and finite(value.a);
        }

        fn validStyle(value: Style) bool {
            return finite(value.font.cell.x) and
                finite(value.font.cell.y) and
                finite(value.font.letter_spacing) and
                finite(value.font.line_spacing) and
                finite(value.text_scale) and
                finite(value.line_height) and
                finite(value.padding.x) and
                finite(value.padding.y) and
                finite(value.spacing) and
                finite(value.separator_thickness) and
                finite(value.scrollbar) and
                validColor(value.text) and
                validColor(value.text_dim) and
                validColor(value.surface) and
                validColor(value.control) and
                validColor(value.control_hot) and
                validColor(value.control_active) and
                validColor(value.accent) and
                value.font.cell.x >= 0 and
                value.font.cell.y >= 0 and
                value.text_scale >= 0 and
                value.line_height >= 0 and
                value.padding.x >= 0 and
                value.padding.y >= 0 and
                value.spacing >= 0 and
                value.separator_thickness >= 0 and
                value.scrollbar >= 0;
        }

        fn toColor(value: ui_types.Color) ui.Color {
            return .{ .r = value.r, .g = value.g, .b = value.b, .a = value.a };
        }

        fn fromColor(value: ui.Color) ui_types.Color {
            return .{ .r = value.r, .g = value.g, .b = value.b, .a = value.a };
        }

        fn toStyle(value: Style) ui.Style {
            return .{
                .font = .{
                    .cell = .init(value.font.cell.x, value.font.cell.y),
                    .letter_spacing = value.font.letter_spacing,
                    .line_spacing = value.font.line_spacing,
                },
                .text_scale = value.text_scale,
                .line_height = value.line_height,
                .padding = .init(value.padding.x, value.padding.y),
                .spacing = value.spacing,
                .separator_thickness = value.separator_thickness,
                .scrollbar = value.scrollbar,
                .caret_blink_frames = value.caret_blink_frames,
                .text = toColor(value.text),
                .text_dim = toColor(value.text_dim),
                .surface = toColor(value.surface),
                .control = toColor(value.control),
                .control_hot = toColor(value.control_hot),
                .control_active = toColor(value.control_active),
                .accent = toColor(value.accent),
            };
        }

        fn fromStyle(value: ui.Style) Style {
            return .{
                .font = .{
                    .cell = .{ .x = value.font.cell.x, .y = value.font.cell.y },
                    .letter_spacing = value.font.letter_spacing,
                    .line_spacing = value.font.line_spacing,
                },
                .text_scale = value.text_scale,
                .line_height = value.line_height,
                .padding = .{ .x = value.padding.x, .y = value.padding.y },
                .spacing = value.spacing,
                .separator_thickness = value.separator_thickness,
                .scrollbar = value.scrollbar,
                .caret_blink_frames = value.caret_blink_frames,
                .text = fromColor(value.text),
                .text_dim = fromColor(value.text_dim),
                .surface = fromColor(value.surface),
                .control = fromColor(value.control),
                .control_hot = fromColor(value.control_hot),
                .control_active = fromColor(value.control_active),
                .accent = fromColor(value.accent),
            };
        }

        // -- frame and identity -------------------------------------------------------

        /// Begins the mod's UI description for the current host frame.
        ///
        /// Input is captured by the host and copied into the context. The viewport is the
        /// only frame argument a mod supplies because the host owns platform input and keeps
        /// the platform-shaped snapshot out of the public ABI.
        pub fn uiBegin(viewport: ?*const Rect) callconv(.c) Result {
            const view = viewport orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const ctx = h.ui_context orelse return .unavailable;
            if (ctx.in_frame or h.ui_state.depth != 0 or h.ui_state.container_depth != 0) return .refused;
            const input = h.ui_input orelse return .unavailable;
            if (!validRect(view.*)) return .invalid_argument;

            ctx.begin(input, toRect(view.*));
            h.ui_state.reset();
            return .ok;
        }

        /// Ends the mod's UI description. An unbalanced id, region or clip stack refuses the
        /// frame after finalising the context; the host must not walk that draw list.
        pub fn uiEnd() callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const ctx = h.ui_context orelse return .unavailable;
            if (!ctx.in_frame) return .refused;

            const balanced = h.ui_state.depth == 0 and
                h.ui_state.container_depth == 0 and
                ctx.regions.depth() == 0 and
                ctx.list.clipDepth() == 0;
            ctx.end();
            h.ui_state.reset();
            return if (balanced) .ok else .refused;
        }

        /// Pushes a runtime id seed. Widget ids are folded through the current region and
        /// stack seed, so this does not expose the context's own memory.
        pub fn uiPushId(value: Id) callconv(.c) Result {
            const active = frame() orelse return frameFailure();
            if (!validId(value)) return .invalid_argument;
            if (active.host.ui_state.depth == ui_types.State.max_id_depth) return .limit;

            // Store the caller's scope, not a seed that already includes the current
            // region. `internalId` folds this raw stack into whichever region is active for
            // each subsequent widget.
            active.host.ui_state.ids[active.host.ui_state.depth] = value;
            active.host.ui_state.depth += 1;
            return .ok;
        }

        pub fn uiPopId() callconv(.c) Result {
            const active = frame() orelse return frameFailure();
            if (active.host.ui_state.depth == 0) return .refused;
            active.host.ui_state.depth -= 1;
            active.host.ui_state.ids[active.host.ui_state.depth] = .{};
            return .ok;
        }

        // -- containers ----------------------------------------------------------------

        pub fn uiBeginPanel(id: Id, bounds: ?*const Rect) callconv(.c) Result {
            const destination = bounds orelse return .invalid_argument;
            const active = frame() orelse return frameFailure();
            const effective = resultId(active.context, active.host, id) orelse return .invalid_argument;
            if (!validRect(destination.*)) return .invalid_argument;
            if (active.host.ui_state.container_depth == ui_types.State.max_container_depth) return .limit;
            ui.beginPanel(active.context, effective, toRect(destination.*)) catch |err| return resultOf(err);
            _ = active.host.ui_state.pushContainer(
                .panel,
                active.context.regions.depth(),
                active.context.list.clipDepth(),
            );
            return .ok;
        }

        pub fn uiEndPanel() callconv(.c) Result {
            const active = frame() orelse return frameFailure();
            if (!active.host.ui_state.topMatches(
                .panel,
                active.context.regions.depth(),
                active.context.list.clipDepth(),
            )) return .refused;
            ui.endPanel(active.context) catch |err| return resultOf(err);
            _ = active.host.ui_state.popContainer(.panel);
            return .ok;
        }

        pub fn uiBeginRow(id: Id, height: f32) callconv(.c) Result {
            const active = frame() orelse return frameFailure();
            const effective = resultId(active.context, active.host, id) orelse return .invalid_argument;
            if (!finite(height)) return .invalid_argument;
            if (active.host.ui_state.container_depth == ui_types.State.max_container_depth) return .limit;
            ui.beginRow(active.context, effective, height) catch |err| return resultOf(err);
            _ = active.host.ui_state.pushContainer(
                .row,
                active.context.regions.depth(),
                active.context.list.clipDepth(),
            );
            return .ok;
        }

        pub fn uiEndRow() callconv(.c) Result {
            const active = frame() orelse return frameFailure();
            if (!active.host.ui_state.topMatches(
                .row,
                active.context.regions.depth(),
                active.context.list.clipDepth(),
            )) return .refused;
            ui.endRow(active.context);
            _ = active.host.ui_state.popContainer(.row);
            return .ok;
        }

        pub fn uiBeginScroll(id: Id, bounds: ?*const Rect, content: f32) callconv(.c) Result {
            const destination = bounds orelse return .invalid_argument;
            const active = frame() orelse return frameFailure();
            const effective = resultId(active.context, active.host, id) orelse return .invalid_argument;
            if (!validRect(destination.*) or !finite(content)) return .invalid_argument;
            if (active.host.ui_state.container_depth == ui_types.State.max_container_depth) return .limit;
            ui.beginScroll(active.context, effective, toRect(destination.*), content) catch |err| return resultOf(err);
            _ = active.host.ui_state.pushContainer(
                .scroll,
                active.context.regions.depth(),
                active.context.list.clipDepth(),
            );
            return .ok;
        }

        pub fn uiEndScroll() callconv(.c) Result {
            const active = frame() orelse return frameFailure();
            if (!active.host.ui_state.topMatches(
                .scroll,
                active.context.regions.depth(),
                active.context.list.clipDepth(),
            )) return .refused;
            ui.endScroll(active.context) catch |err| return resultOf(err);
            _ = active.host.ui_state.popContainer(.scroll);
            return .ok;
        }

        // -- widgets -------------------------------------------------------------------

        pub fn uiLabel(value: Str) callconv(.c) Result {
            const active = frame() orelse return frameFailure();
            const bytes = text(value) orelse return .invalid_argument;
            ui.label(active.context, bytes) catch |err| return resultOf(err);
            return .ok;
        }

        pub fn uiButton(id: Id, value: Str, out: ?*Bool) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const active = frame() orelse return frameFailure();
            const bytes = text(value) orelse return .invalid_argument;
            const effective = resultId(active.context, active.host, id) orelse return .invalid_argument;
            const clicked = ui.button(active.context, effective, bytes) catch |err| return resultOf(err);
            destination.* = types.boolOut(clicked);
            return .ok;
        }

        pub fn uiCheckbox(id: Id, value: Str, checked: ?*Bool, changed: ?*Bool) callconv(.c) Result {
            const checked_out = checked orelse return .invalid_argument;
            const changed_out = changed orelse return .invalid_argument;
            const active = frame() orelse return frameFailure();
            const bytes = text(value) orelse return .invalid_argument;
            const effective = resultId(active.context, active.host, id) orelse return .invalid_argument;

            var checked_value = types.boolIn(checked_out.*);
            const did_change = ui.checkbox(active.context, effective, bytes, &checked_value) catch |err| return resultOf(err);
            checked_out.* = types.boolOut(checked_value);
            changed_out.* = types.boolOut(did_change);
            return .ok;
        }

        pub fn uiSlider(id: Id, value: Str, number: ?*f32, min: f32, max: f32, changed: ?*Bool) callconv(.c) Result {
            const number_out = number orelse return .invalid_argument;
            const changed_out = changed orelse return .invalid_argument;
            const active = frame() orelse return frameFailure();
            const bytes = text(value) orelse return .invalid_argument;
            const effective = resultId(active.context, active.host, id) orelse return .invalid_argument;
            if (!finite(number_out.*) or !finite(min) or !finite(max) or min > max) return .invalid_argument;

            var number_value = number_out.*;
            const did_change = ui.slider(active.context, effective, bytes, &number_value, min, max) catch |err| return resultOf(err);
            number_out.* = number_value;
            changed_out.* = types.boolOut(did_change);
            return .ok;
        }

        pub fn uiSliderInt(id: Id, value: Str, number: ?*i32, min: i32, max: i32, changed: ?*Bool) callconv(.c) Result {
            const number_out = number orelse return .invalid_argument;
            const changed_out = changed orelse return .invalid_argument;
            const active = frame() orelse return frameFailure();
            const bytes = text(value) orelse return .invalid_argument;
            const effective = resultId(active.context, active.host, id) orelse return .invalid_argument;
            if (min > max) return .invalid_argument;

            var number_value = number_out.*;
            const did_change = ui.sliderInt(active.context, effective, bytes, &number_value, min, max) catch |err| return resultOf(err);
            number_out.* = number_value;
            changed_out.* = types.boolOut(did_change);
            return .ok;
        }

        pub fn uiSeparator() callconv(.c) Result {
            const active = frame() orelse return frameFailure();
            ui.separator(active.context) catch |err| return resultOf(err);
            return .ok;
        }

        pub fn uiSpacer(size: f32) callconv(.c) Result {
            const active = frame() orelse return frameFailure();
            if (!finite(size)) return .invalid_argument;
            ui.spacer(active.context, size);
            return .ok;
        }

        pub fn uiCollapsingHeader(id: Id, value: Str, open: ?*Bool) callconv(.c) Result {
            const destination = open orelse return .invalid_argument;
            const active = frame() orelse return frameFailure();
            const bytes = text(value) orelse return .invalid_argument;
            const effective = resultId(active.context, active.host, id) orelse return .invalid_argument;
            const is_open = ui.collapsingHeader(active.context, effective, bytes) catch |err| return resultOf(err);
            destination.* = types.boolOut(is_open);
            return .ok;
        }

        pub fn uiTextField(id: Id, buffer: ?[*]u8, capacity: u64, length: ?*u64, changed: ?*Bool) callconv(.c) Result {
            const length_out = length orelse return .invalid_argument;
            const changed_out = changed orelse return .invalid_argument;
            const active = frame() orelse return frameFailure();
            if (capacity > max_text_bytes) return .limit;
            if (capacity != 0 and buffer == null) return .invalid_argument;
            if (length_out.* > capacity) return .invalid_argument;

            const effective = resultId(active.context, active.host, id) orelse return .invalid_argument;
            const used = @as(usize, @intCast(length_out.*));
            const cap = @as(usize, @intCast(capacity));
            const source = if (cap == 0) &.{} else buffer.?[0..cap];
            if (!std.unicode.utf8ValidateSlice(source[0..used])) return .invalid_argument;

            // The kernel edits its buffer before appending draw commands. Work on a temporary
            // copy so an allocation failure leaves the mod's in/out memory untouched; the ABI
            // writes both outputs only once the whole widget call succeeds.
            const scratch = if (cap == 0) @as([]u8, &.{}) else active.context.gpa.alloc(u8, cap) catch return .out_of_memory;
            defer if (cap != 0) active.context.gpa.free(scratch);
            if (used != 0) @memcpy(scratch[0..used], source[0..used]);
            var scratch_len = used;
            const did_change = ui.textField(active.context, effective, scratch, &scratch_len) catch |err| return resultOf(err);
            if (scratch_len > cap) return .internal;
            if (scratch_len != 0) @memcpy(buffer.?[0..scratch_len], scratch[0..scratch_len]);
            length_out.* = scratch_len;
            changed_out.* = types.boolOut(did_change);
            return .ok;
        }

        pub fn uiPlot(samples: ?[*]const f32, count: u64, options: ?*const PlotOptions) callconv(.c) Result {
            const source_options = options orelse return .invalid_argument;
            const active = frame() orelse return frameFailure();
            if (count > max_plot_samples) return .limit;
            if (count != 0 and samples == null) return .invalid_argument;
            if (!finite(source_options.height)) return .invalid_argument;
            if (types.boolIn(source_options.has_min) and !finite(source_options.min)) return .invalid_argument;
            if (types.boolIn(source_options.has_max) and !finite(source_options.max)) return .invalid_argument;
            if (types.boolIn(source_options.has_min) and types.boolIn(source_options.has_max) and source_options.min > source_options.max) return .invalid_argument;

            const count_usize = @as(usize, @intCast(count));
            const source = if (count_usize == 0) @as([]const f32, &.{}) else samples.?[0..count_usize];
            for (source) |sample| {
                if (!finite(sample)) return .invalid_argument;
            }

            const translated: ui.PlotOptions = .{
                .height = source_options.height,
                .first = @intCast(source_options.first),
                .min = if (types.boolIn(source_options.has_min)) source_options.min else null,
                .max = if (types.boolIn(source_options.has_max)) source_options.max else null,
            };
            ui.plot(active.context, source, translated) catch |err| return resultOf(err);
            return .ok;
        }

        // -- style and capture ---------------------------------------------------------

        pub fn uiStyleGet(out: ?*Style) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const ctx = context() orelse return if (H.current() == null) .unavailable else .unavailable;
            destination.* = fromStyle(ctx.style);
            return .ok;
        }

        pub fn uiStyleSet(value: ?*const Style) callconv(.c) Result {
            const source = value orelse return .invalid_argument;
            const ctx = context() orelse return if (H.current() == null) .unavailable else .unavailable;
            if (ctx.in_frame) return .refused;
            if (!validStyle(source.*)) return .invalid_argument;
            ctx.style = toStyle(source.*);
            return .ok;
        }

        pub fn uiWantsKeyboard(out: ?*Bool) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const ctx = context() orelse return .unavailable;
            if (ctx.in_frame) return .refused;
            destination.* = types.boolOut(ctx.wantsKeyboard());
            return .ok;
        }

        pub fn uiWantsPointer(out: ?*Bool) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const ctx = context() orelse return .unavailable;
            if (ctx.in_frame) return .refused;
            destination.* = types.boolOut(ctx.wantsPointer());
            return .ok;
        }
    };
}

test "UI ABI accepts one balanced frame and refuses mismatched container closes" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const audio = @import("audio");

    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);
    var ctx = ui.Context.init(testing.allocator, .{
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
    });
    defer ctx.deinit();
    const input: ui.Input = .{};
    var host: Host = .{ .ui_context = &ctx, .ui_input = input };
    host.bind();
    defer host.unbind();

    const viewport: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try testing.expectEqual(Result.ok, Calls.uiBegin(&viewport));
    try testing.expectEqual(Result.ok, Calls.uiLabel(Str.from("hello")));
    try testing.expectEqual(Result.ok, Calls.uiEnd());

    try testing.expectEqual(Result.ok, Calls.uiBegin(&viewport));
    try testing.expectEqual(Result.ok, Calls.uiBeginPanel(
        .{ .bits = 1 },
        &Rect{ .x = 1, .y = 1, .w = 40, .h = 40 },
    ));
    // A panel and a row both open regions, but only a matching close may unwind the clip
    // and region pair. The boundary owns this type stack because the kernel does not.
    try testing.expectEqual(Result.refused, Calls.uiEndRow());
    try testing.expectEqual(Result.ok, Calls.uiEndPanel());
    try testing.expectEqual(Result.ok, Calls.uiEnd());
}

test "UI ABI composes pushed ids with every region seed" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const audio = @import("audio");

    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);
    var ctx = ui.Context.init(testing.allocator, .{
        .font = .{ .cell = .init(8, 8) },
        .line_height = 20,
        .padding = .init(4, 4),
        .spacing = 2,
        .text = .white,
        .text_dim = .white,
        .surface = .black,
        .control = .white,
        .control_hot = .white,
        .control_active = .white,
        .accent = .white,
    });
    defer ctx.deinit();
    var host: Host = .{ .ui_context = &ctx, .ui_input = .{} };
    host.bind();
    defer host.unbind();

    const viewport: Rect = .{ .w = 400, .h = 400 };
    var panel_a: Rect = .{ .w = 100, .h = 30 };
    var panel_b: Rect = .{ .x = 120, .w = 100, .h = 30 };
    var scroll_a: Rect = .{ .y = 80, .w = 100, .h = 40 };
    var scroll_b: Rect = .{ .x = 120, .y = 80, .w = 100, .h = 40 };
    var clicked: Bool = 0;

    try testing.expectEqual(Result.ok, Calls.uiBegin(&viewport));
    try testing.expectEqual(Result.ok, Calls.uiPushId(.{ .bits = 0xCAFE }));

    // The child id is intentionally identical in every pair. Region seeds must remain in
    // the composed identity even though the pushed scope is shared by all six widgets.
    try testing.expectEqual(Result.ok, Calls.uiBeginPanel(.{ .bits = 1 }, &panel_a));
    try testing.expectEqual(Result.ok, Calls.uiButton(.{ .bits = 7 }, Str.from("same"), &clicked));
    try testing.expectEqual(Result.ok, Calls.uiEndPanel());
    try testing.expectEqual(Result.ok, Calls.uiBeginPanel(.{ .bits = 2 }, &panel_b));
    try testing.expectEqual(Result.ok, Calls.uiButton(.{ .bits = 7 }, Str.from("same"), &clicked));
    try testing.expectEqual(Result.ok, Calls.uiEndPanel());

    try testing.expectEqual(Result.ok, Calls.uiBeginRow(.{ .bits = 3 }, 20));
    try testing.expectEqual(Result.ok, Calls.uiButton(.{ .bits = 7 }, Str.from("same"), &clicked));
    try testing.expectEqual(Result.ok, Calls.uiEndRow());
    try testing.expectEqual(Result.ok, Calls.uiBeginRow(.{ .bits = 4 }, 20));
    try testing.expectEqual(Result.ok, Calls.uiButton(.{ .bits = 7 }, Str.from("same"), &clicked));
    try testing.expectEqual(Result.ok, Calls.uiEndRow());

    try testing.expectEqual(Result.ok, Calls.uiBeginScroll(.{ .bits = 5 }, &scroll_a, 100));
    try testing.expectEqual(Result.ok, Calls.uiButton(.{ .bits = 7 }, Str.from("same"), &clicked));
    try testing.expectEqual(Result.ok, Calls.uiEndScroll());
    try testing.expectEqual(Result.ok, Calls.uiBeginScroll(.{ .bits = 6 }, &scroll_b, 100));
    try testing.expectEqual(Result.ok, Calls.uiButton(.{ .bits = 7 }, Str.from("same"), &clicked));
    try testing.expectEqual(Result.ok, Calls.uiEndScroll());

    try testing.expectEqual(Result.ok, Calls.uiPopId());
    try testing.expectEqual(Result.ok, Calls.uiEnd());
    try testing.expectEqual(@as(u32, 0), ctx.duplicates);
}

test "UI ABI rejects malformed text and preserves outputs on allocation failure" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const audio = @import("audio");
    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);

    var ctx = ui.Context.init(testing.allocator, .{
        .font = .{ .cell = .init(8, 8) },
        .line_height = 20,
        .padding = .init(4, 4),
        .spacing = 2,
        .text = .white,
        .text_dim = .white,
        .surface = .black,
        .control = .white,
        .control_hot = .white,
        .control_active = .white,
        .accent = .white,
    });
    defer ctx.deinit();
    var host: Host = .{ .ui_context = &ctx, .ui_input = .{} };
    host.bind();
    defer host.unbind();
    const viewport: Rect = .{ .w = 100, .h = 100 };
    try testing.expectEqual(Result.ok, Calls.uiBegin(&viewport));
    const invalid = [_]u8{0xff};
    try testing.expectEqual(Result.invalid_argument, Calls.uiLabel(Str.from(&invalid)));
    try testing.expectEqual(Result.ok, Calls.uiEnd());

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var failing_ctx = ui.Context.init(failing.allocator(), ctx.style);
    defer failing_ctx.deinit();
    var failing_host: Host = .{ .ui_context = &failing_ctx, .ui_input = .{} };
    failing_host.bind();
    defer failing_host.unbind();
    try testing.expectEqual(Result.ok, Calls.uiBegin(&viewport));
    try testing.expectEqual(Result.out_of_memory, Calls.uiLabel(Str.from("allocation")));
    try testing.expectEqual(Result.ok, Calls.uiEnd());
}

test "UI ABI accepts the full i32 slider range without float conversion traps" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const audio = @import("audio");
    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);
    var ctx = ui.Context.init(testing.allocator, .{
        .font = .{ .cell = .init(8, 8) },
        .line_height = 20,
        .padding = .init(4, 4),
        .spacing = 2,
        .text = .white,
        .text_dim = .white,
        .surface = .black,
        .control = .white,
        .control_hot = .white,
        .control_active = .white,
        .accent = .white,
    });
    defer ctx.deinit();
    var host: Host = .{ .ui_context = &ctx, .ui_input = .{} };
    host.bind();
    defer host.unbind();
    const viewport: Rect = .{ .w = 100, .h = 100 };
    try testing.expectEqual(Result.ok, Calls.uiBegin(&viewport));
    var value: i32 = 0;
    var changed: Bool = 9;
    try testing.expectEqual(Result.ok, Calls.uiSliderInt(
        .{ .bits = 1 },
        Str.from("range"),
        &value,
        std.math.minInt(i32),
        std.math.maxInt(i32),
        &changed,
    ));
    try testing.expectEqual(@as(Bool, 0), changed);
    try testing.expectEqual(Result.ok, Calls.uiEnd());
}
