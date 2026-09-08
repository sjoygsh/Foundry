//! Plain values that make up the public UI calls.
//!
//! `ui` itself is deliberately below the ABI and its `Context` never crosses this boundary.
//! These are the values a mod can describe instead: coordinates, colours, style metrics,
//! plot options and a runtime-only widget id. Every type is `extern`, and padding is written
//! down where a C boolean would otherwise leave it to a compiler's layout rules.
//!
//! Design: `docs/design/ui.md` §13 and `docs/design/public-abi.md` §5.

const std = @import("std");

const types = @import("types.zig");

/// A runtime-only widget identity.
///
/// This is deliberately a distinct type from `ContentId`: a UI id is not serialized, does
/// not identify a package record and is free to change when a layout changes. Zero is the
/// no-widget value and is refused by calls that require an interactive id.
pub const Id = extern struct {
    bits: u64 = 0,

    pub const none: Id = .{};

    pub fn isNone(self: Id) bool {
        return self.bits == 0;
    }
};

/// ABI bookkeeping for the id seed stack.
///
/// The stack is host-owned because `ui.Context` has no native push-id operation and a mod
/// must not get a pointer to any of the context's internal state. It is reset at every
/// successful `ui_begin` and must be empty when `ui_end` succeeds. Thirty-two levels is a
/// deliberately finite bound: a malformed mod cannot grow an unbounded stack in the host.
pub const State = struct {
    pub const max_id_depth: u32 = 32;
    pub const max_container_depth: u32 = 32;

    pub const ContainerKind = enum { panel, row, scroll };

    /// The boundary's shadow of one open kernel container. The depths are captured after
    /// the begin operation, so a close can prove that no other caller (or an earlier
    /// failed operation) changed the kernel stacks underneath it before unwinding.
    pub const Container = struct {
        kind: ContainerKind = .panel,
        region_depth: u32 = 0,
        clip_depth: u32 = 0,
    };

    ids: [max_id_depth]Id = @splat(.{}),
    depth: u32 = 0,
    containers: [max_container_depth]Container = @splat(.{}),
    container_depth: u32 = 0,

    pub fn reset(self: *State) void {
        self.ids = @splat(.{});
        self.depth = 0;
        self.containers = @splat(.{});
        self.container_depth = 0;
    }

    pub fn pushContainer(self: *State, kind: ContainerKind, region_depth: u32, clip_depth: u32) bool {
        if (self.container_depth == max_container_depth) return false;
        self.containers[self.container_depth] = .{
            .kind = kind,
            .region_depth = region_depth,
            .clip_depth = clip_depth,
        };
        self.container_depth += 1;
        return true;
    }

    pub fn topMatches(self: *const State, kind: ContainerKind, region_depth: u32, clip_depth: u32) bool {
        if (self.container_depth == 0) return false;
        const top = self.containers[self.container_depth - 1];
        return top.kind == kind and top.region_depth == region_depth and top.clip_depth == clip_depth;
    }

    pub fn popContainer(self: *State, kind: ContainerKind) bool {
        if (self.container_depth == 0) return false;
        if (self.containers[self.container_depth - 1].kind != kind) return false;
        self.container_depth -= 1;
        self.containers[self.container_depth] = .{};
        return true;
    }
};

/// A two-dimensional point or size, in UI points.
pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// A rectangle in screen points. The UI kernel sanitises negative extents as empty; the ABI
/// rejects non-finite coordinates before the rectangle reaches it.
pub const Rect = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// A linear-light colour, matching `ui.Color` field-for-field.
pub const Color = extern struct {
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,
};

/// The renderer-independent arithmetic needed to measure a bitmap font.
pub const FontMetrics = extern struct {
    cell: Vec2 = .{},
    letter_spacing: f32 = 0,
    line_spacing: f32 = 0,
};

/// The complete value read by the UI kernel to choose metrics and colours.
///
/// All fields are explicit, including `caret_blink_frames` as `u32`; no Zig optional or
/// enum reaches the C boundary. The order mirrors `ui.style.Style` so conversion stays a
/// field-for-field operation.
pub const Style = extern struct {
    font: FontMetrics = .{},
    text_scale: f32 = 1,
    line_height: f32 = 0,
    padding: Vec2 = .{},
    spacing: f32 = 0,
    separator_thickness: f32 = 1,
    scrollbar: f32 = 12,
    caret_blink_frames: u32 = 30,
    text: Color = .{},
    text_dim: Color = .{},
    surface: Color = .{},
    control: Color = .{},
    control_hot: Color = .{},
    control_active: Color = .{},
    accent: Color = .{},
};

/// Options for the one-line plot widget.
///
/// `min` and `max` are used only when their corresponding flag is nonzero. They stay present
/// in the struct even when automatic scaling is selected so the layout is fixed and a C mod
/// can initialise the value without an optional representation. The two one-byte booleans
/// are followed by explicit padding because the struct's alignment is four on all supported
/// targets while the following ABI values must not acquire an implementation-defined gap.
pub const PlotOptions = extern struct {
    height: f32 = 0,
    _padding0: [4]u8 = .{ 0, 0, 0, 0 },
    first: u64 = 0,
    min: f32 = 0,
    max: f32 = 0,
    has_min: types.Bool = 0,
    has_max: types.Bool = 0,
    _padding1: [2]u8 = .{ 0, 0 },
};

comptime {
    if (@sizeOf(Id) != 8 or @offsetOf(Id, "bits") != 0) {
        @compileError("FoundryUiId layout changed");
    }
    if (@sizeOf(Vec2) != 8 or @offsetOf(Vec2, "x") != 0 or @offsetOf(Vec2, "y") != 4) {
        @compileError("FoundryUiVec2 layout changed");
    }
    if (@sizeOf(Rect) != 16 or @offsetOf(Rect, "x") != 0 or @offsetOf(Rect, "y") != 4 or
        @offsetOf(Rect, "w") != 8 or @offsetOf(Rect, "h") != 12)
    {
        @compileError("FoundryUiRect layout changed");
    }
    if (@sizeOf(Color) != 16 or @offsetOf(Color, "r") != 0 or @offsetOf(Color, "g") != 4 or
        @offsetOf(Color, "b") != 8 or @offsetOf(Color, "a") != 12)
    {
        @compileError("FoundryUiColor layout changed");
    }
    if (@sizeOf(FontMetrics) != 16 or @offsetOf(FontMetrics, "cell") != 0 or
        @offsetOf(FontMetrics, "letter_spacing") != 8 or @offsetOf(FontMetrics, "line_spacing") != 12)
    {
        @compileError("FoundryUiFontMetrics layout changed");
    }
    if (@sizeOf(Style) != 160 or @offsetOf(Style, "font") != 0 or
        @offsetOf(Style, "text_scale") != 16 or @offsetOf(Style, "line_height") != 20 or
        @offsetOf(Style, "padding") != 24 or @offsetOf(Style, "spacing") != 32 or
        @offsetOf(Style, "separator_thickness") != 36 or @offsetOf(Style, "scrollbar") != 40 or
        @offsetOf(Style, "caret_blink_frames") != 44 or @offsetOf(Style, "text") != 48 or
        @offsetOf(Style, "accent") != 144)
    {
        @compileError("FoundryUiStyle layout changed");
    }
    if (@sizeOf(PlotOptions) != 32 or @offsetOf(PlotOptions, "height") != 0 or
        @offsetOf(PlotOptions, "first") != 8 or @offsetOf(PlotOptions, "min") != 16 or
        @offsetOf(PlotOptions, "max") != 20 or @offsetOf(PlotOptions, "has_min") != 24 or
        @offsetOf(PlotOptions, "has_max") != 25 or @offsetOf(PlotOptions, "_padding1") != 26)
    {
        @compileError("FoundryUiPlotOptions layout changed");
    }
}

const testing = std.testing;

test "UI ABI values have explicit, stable layouts" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Id));
    try testing.expectEqual(@as(usize, 8), @alignOf(Id));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Vec2));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Rect));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Color));
    try testing.expectEqual(@as(usize, 16), @sizeOf(FontMetrics));

    try testing.expectEqual(@as(usize, 160), @sizeOf(Style));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Style, "font"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Style, "text_scale"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Style, "padding"));
    try testing.expectEqual(@as(usize, 44), @offsetOf(Style, "caret_blink_frames"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(Style, "text"));
    try testing.expectEqual(@as(usize, 144), @offsetOf(Style, "accent"));

    try testing.expectEqual(@as(usize, 32), @sizeOf(PlotOptions));
    try testing.expectEqual(@as(usize, 0), @offsetOf(PlotOptions, "height"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(PlotOptions, "first"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(PlotOptions, "has_min"));
    try testing.expectEqual(@as(usize, 25), @offsetOf(PlotOptions, "has_max"));
    try testing.expectEqual(@as(usize, 26), @offsetOf(PlotOptions, "_padding1"));
}
