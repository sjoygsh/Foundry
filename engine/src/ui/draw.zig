//! What the kernel produces instead of drawing: a flat, ordered list of commands.
//!
//! `ui` never calls a renderer (ADR-0024). It describes what should appear and something
//! above walks the description into `render2d` calls. That is what lets the whole
//! interaction model be tested with no device, no window and no frame, and it is the reason
//! this module exists at all.
//!
//! **Order is paint order**, back to front, and nothing is sorted. Immediate mode makes
//! that free: a caller describes a panel before the button on it, so submission order is
//! already the order the pixels want.
//!
//! **Images are named, never held** (ADR-0041). `image` and `nine_slice` carry an
//! `ImageRef`, an opaque number the caller defines, and never a texture handle: the kernel
//! still sees no renderer, and the walker resolves the number through a table the caller
//! passes. Both commands carry numbers only, so their tests need nothing linked.
//!
//! Design: `docs/design/ui.md` §6; the image commands, `mod-management.md` §10.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Rect = core.math.Rect;
const Vec2 = core.math.Vec2;
const Color = @import("style.zig").Color;
const layout = @import("layout.zig");

/// Where a string lives in the list's own text storage.
///
/// **Strings are copied, not borrowed**, and this is the type that makes that true. The
/// obvious way to draw a number is to format it into a stack buffer, and a slice into one
/// of those is dangling by the time the walker runs. A UI whose most natural call site is
/// a use-after-free is a UI that will eventually contain one, so the list pays a memcpy per
/// label and the hazard does not exist.
///
/// An offset rather than a pointer, so the storage may grow and reallocate mid-frame
/// without invalidating a command recorded before it did.
pub const TextRef = struct {
    offset: u32 = 0,
    len: u32 = 0,
};

pub const RectCommand = struct {
    bounds: Rect,
    color: Color,
};

pub const TextCommand = struct {
    /// Top-left of the first glyph's cell, matching `render2d.TextOptions.position`.
    at: Vec2,
    text: TextRef,
    color: Color,
    scale: f32,
};

/// An image, as the caller numbers them. Opaque to the kernel: what number means which
/// texture is the caller's table, resolved by the walker (ADR-0041).
pub const ImageRef = enum(u32) {
    _,

    pub fn of(n: u32) ImageRef {
        return @enumFromInt(n);
    }

    pub fn index(self: ImageRef) u32 {
        return @intFromEnum(self);
    }
};

/// A rectangle of an image, in the image's own pixels from its top-left. The kernel cannot
/// know the image's size; the walker checks the rectangle against the image it resolves.
pub const Source = struct {
    image: ImageRef,
    x: u32 = 0,
    y: u32 = 0,
    w: u32,
    h: u32,

    pub fn isEmpty(self: Source) bool {
        return self.w == 0 or self.h == 0;
    }
};

/// How far in from each edge of a `Source` its fixed border runs, in the image's pixels.
pub const Insets = struct {
    left: u32 = 0,
    top: u32 = 0,
    right: u32 = 0,
    bottom: u32 = 0,

    pub fn all(n: u32) Insets {
        return .{ .left = n, .top = n, .right = n, .bottom = n };
    }
};

/// `source`, stretched to fill `bounds`.
pub const ImageCommand = struct {
    bounds: Rect,
    source: Source,
    tint: Color,
};

/// `source` cut by `insets` into nine pieces: the corners keep their size, the edges
/// stretch one way and the centre both. What a skinned panel or button is drawn with.
pub const NineSliceCommand = struct {
    bounds: Rect,
    source: Source,
    insets: Insets,
    /// Screen units per image pixel for the corners and edges, as `Style.text_scale` is
    /// for glyphs, so a border drawn at double size stays crisp.
    scale: f32,
    tint: Color,
};

pub const Command = union(enum) {
    rect: RectCommand,
    text: TextCommand,
    image: ImageCommand,
    nine_slice: NineSliceCommand,
    /// **Intersected with whatever is already on the clip stack**, so a scrolling list
    /// inside a panel clips to both and no caller computes the intersection itself.
    clip_push: Rect,
    clip_pop,
};

/// The kernel's output for one frame. Public and read-only once the frame has ended: the
/// walker reads it, a test asserting a rectangle is where it should be reads it, and a tool
/// dumping a layout reads the same array.
pub const DrawList = struct {
    commands: std.ArrayList(Command) = .empty,
    /// The per-frame text storage `TextRef` indexes into. Cleared, not freed, each frame,
    /// so a steady-state UI stops allocating after its first few frames.
    text_bytes: std.ArrayList(u8) = .empty,
    /// The clip rectangles currently open, innermost last and **already intersected**. Kept
    /// so an unbalanced frame is caught rather than handed to a walker that would then clip
    /// everything after it, and so each pushed command carries a rectangle the walker can
    /// hand straight to a scissor without doing the arithmetic again.
    clip_stack: std.ArrayList(Rect) = .empty,
    /// Multiplies the alpha of every colour recorded while it is below 1. How a disabled
    /// scope looks (`Context.beginDisabled`): the kernel fades what it is told to draw, and
    /// the style says how far.
    fade: f32 = 1,

    pub fn deinit(self: *DrawList, gpa: Allocator) void {
        self.commands.deinit(gpa);
        self.text_bytes.deinit(gpa);
        self.clip_stack.deinit(gpa);
        self.* = .{};
    }

    pub fn reset(self: *DrawList) void {
        self.commands.clearRetainingCapacity();
        self.text_bytes.clearRetainingCapacity();
        self.clip_stack.clearRetainingCapacity();
        self.fade = 1;
    }

    pub fn addRect(self: *DrawList, gpa: Allocator, bounds: Rect, color: Color) Allocator.Error!void {
        // An empty rectangle is not an error and not worth a command; a layout that
        // produces one is usually a container with nothing in it yet.
        if (bounds.isEmpty()) return;
        try self.commands.append(gpa, .{ .rect = .{ .bounds = bounds, .color = self.faded(color) } });
    }

    /// `source`, stretched over `bounds`. Nothing is recorded for an empty rectangle or an
    /// empty source, as for an empty `addRect`.
    pub fn addImage(self: *DrawList, gpa: Allocator, bounds: Rect, source: Source, tint: Color) Allocator.Error!void {
        const clean = layout.sanitize(bounds);
        if (clean.isEmpty() or source.isEmpty()) return;
        try self.commands.append(gpa, .{ .image = .{ .bounds = clean, .source = source, .tint = self.faded(tint) } });
    }

    /// `source` as a nine-slice over `bounds`. Nothing is recorded for an empty rectangle,
    /// an empty source, or a scale that is not a positive finite number: a list is data a
    /// mod may have described, so a bad value is refused rather than asserted (CLAUDE.md §7).
    /// Insets are kept as given; `nineSlice` clamps them when it cuts.
    pub fn addNineSlice(
        self: *DrawList,
        gpa: Allocator,
        bounds: Rect,
        source: Source,
        insets: Insets,
        scale: f32,
        tint: Color,
    ) Allocator.Error!void {
        const clean = layout.sanitize(bounds);
        if (clean.isEmpty() or source.isEmpty()) return;
        if (!std.math.isFinite(scale) or scale <= 0) return;
        try self.commands.append(gpa, .{ .nine_slice = .{
            .bounds = clean,
            .source = source,
            .insets = insets,
            .scale = scale,
            .tint = self.faded(tint),
        } });
    }

    pub fn addText(
        self: *DrawList,
        gpa: Allocator,
        at: Vec2,
        text: []const u8,
        color: Color,
        scale: f32,
    ) Allocator.Error!void {
        if (text.len == 0) return;
        const ref = try self.intern(gpa, text);
        try self.commands.append(gpa, .{
            .text = .{ .at = at, .text = ref, .color = self.faded(color), .scale = scale },
        });
    }

    /// Clip to `bounds` **intersected with whatever is already open**, so a scrolling list
    /// inside a panel clips to both and no caller computes the intersection itself. The
    /// command carries the resolved rectangle, not the requested one.
    pub fn pushClip(self: *DrawList, gpa: Allocator, bounds: Rect) Allocator.Error!void {
        const requested = layout.sanitize(bounds);
        const resolved = if (self.currentClip()) |open| open.intersect(requested) else requested;
        // Both or neither: a command recorded without its stack entry would unbalance every
        // pop after it, and a stack entry without its command would clip nothing.
        try self.clip_stack.ensureUnusedCapacity(gpa, 1);
        try self.commands.append(gpa, .{ .clip_push = resolved });
        self.clip_stack.appendAssumeCapacity(resolved);
    }

    /// Popping an empty stack is a caller bug — from M7 possibly a mod's — so it is
    /// reported by returning false rather than asserted (CLAUDE.md §7). The command is not
    /// recorded, which keeps the list walkable whatever the caller did.
    pub fn popClip(self: *DrawList, gpa: Allocator) Allocator.Error!bool {
        if (self.clip_stack.items.len == 0) return false;
        try self.commands.append(gpa, .clip_pop);
        _ = self.clip_stack.pop();
        return true;
    }

    /// The rectangle currently in force, or null when nothing is clipped.
    pub fn currentClip(self: *const DrawList) ?Rect {
        if (self.clip_stack.items.len == 0) return null;
        return self.clip_stack.items[self.clip_stack.items.len - 1];
    }

    pub fn clipDepth(self: *const DrawList) u32 {
        return @intCast(self.clip_stack.items.len);
    }

    /// The bytes a `TextRef` names. Valid until the next `reset`.
    pub fn textOf(self: *const DrawList, ref: TextRef) []const u8 {
        return self.text_bytes.items[ref.offset..][0..ref.len];
    }

    pub fn items(self: *const DrawList) []const Command {
        return self.commands.items;
    }

    fn faded(self: *const DrawList, color: Color) Color {
        if (self.fade >= 1) return color;
        return color.withAlpha(color.a * self.fade);
    }

    fn intern(self: *DrawList, gpa: Allocator, text: []const u8) Allocator.Error!TextRef {
        const offset = self.text_bytes.items.len;
        try self.text_bytes.appendSlice(gpa, text);
        return .{
            .offset = @intCast(offset),
            .len = @intCast(text.len),
        };
    }
};

/// One of a nine-slice's pieces: where it goes, and the image pixels it is drawn from.
pub const Piece = struct {
    dest: Rect,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// A nine-slice's pieces, back to front in reading order, with empty ones left out.
pub const Pieces = struct {
    items: [9]Piece = undefined,
    len: usize = 0,

    pub fn slice(self: *const Pieces) []const Piece {
        return self.items[0..self.len];
    }
};

/// Cuts a nine-slice into the pieces a walker draws. Pure arithmetic, so the geometry is
/// tested here, with nothing linked, and the walker only converts pixels to texture
/// coordinates.
///
/// Insets wider or taller than the source are clamped to it, left and top first. When the
/// bounds are smaller than the two borders together, both borders shrink in proportion
/// rather than overlapping, so a skinned button squeezed narrow keeps its shape. A source
/// whose far edge is past what a `u32` holds names no image anyone has, and cuts to nothing.
pub fn nineSlice(c: NineSliceCommand) Pieces {
    const src = c.source;
    if (@as(u64, src.x) + src.w > std.math.maxInt(u32) or @as(u64, src.y) + src.h > std.math.maxInt(u32)) return .{};
    const left = @min(c.insets.left, src.w);
    const right = @min(c.insets.right, src.w - left);
    const top = @min(c.insets.top, src.h);
    const bottom = @min(c.insets.bottom, src.h - top);

    const xs = borders(c.bounds.x, c.bounds.w, left, right, c.scale);
    const ys = borders(c.bounds.y, c.bounds.h, top, bottom, c.scale);
    const us = [4]u32{ src.x, src.x + left, src.x + src.w - right, src.x + src.w };
    const vs = [4]u32{ src.y, src.y + top, src.y + src.h - bottom, src.y + src.h };

    var out: Pieces = .{};
    for (0..3) |row| {
        for (0..3) |col| {
            const dest = Rect.init(xs[col], ys[row], xs[col + 1] - xs[col], ys[row + 1] - ys[row]);
            const w = us[col + 1] - us[col];
            const h = vs[row + 1] - vs[row];
            if (dest.w <= 0 or dest.h <= 0 or w == 0 or h == 0) continue;
            out.items[out.len] = .{ .dest = dest, .x = us[col], .y = vs[row], .w = w, .h = h };
            out.len += 1;
        }
    }
    return out;
}

/// The four edges along one axis: start, after the first border, before the second, end.
fn borders(start: f32, length: f32, first: u32, second: u32, scale: f32) [4]f32 {
    var a = @as(f32, @floatFromInt(first)) * scale;
    var b = @as(f32, @floatFromInt(second)) * scale;
    if (a + b > length and a + b > 0) {
        const k = length / (a + b);
        a *= k;
        b *= k;
    }
    return .{ start, start + a, start + length - b, start + length };
}

const testing = std.testing;

test "a list records what it was told, in order" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);

    try list.addRect(testing.allocator, .init(0, 0, 10, 10), .white);
    try list.addText(testing.allocator, .init(1, 1), "hi", .black, 1);

    try testing.expectEqual(@as(usize, 2), list.items().len);
    try testing.expect(list.items()[0] == .rect);
    try testing.expectEqualStrings("hi", list.textOf(list.items()[1].text.text));
}

test "text is copied, so a caller's buffer may go away" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);

    {
        var scratch: [8]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&scratch, "{d}", .{42});
        try list.addText(testing.allocator, .zero, formatted, .white, 1);
        @memset(&scratch, 0xAA);
    }

    try testing.expectEqualStrings("42", list.textOf(list.items()[0].text.text));
}

test "a reference survives the storage growing under it" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);

    try list.addText(testing.allocator, .zero, "first", .white, 1);
    const first = list.items()[0].text.text;

    // Enough to force at least one reallocation of the byte storage.
    for (0..256) |_| try list.addText(testing.allocator, .zero, "padding", .white, 1);

    try testing.expectEqualStrings("first", list.textOf(first));
}

test "empty things record nothing" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);

    try list.addRect(testing.allocator, .init(0, 0, 0, 10), .white);
    try list.addText(testing.allocator, .zero, "", .white, 1);
    try testing.expectEqual(@as(usize, 0), list.items().len);
}

test "clips balance, and an unbalanced pop is reported rather than fatal" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);

    try list.pushClip(testing.allocator, .init(0, 0, 10, 10));
    try testing.expectEqual(@as(u32, 1), list.clipDepth());
    try testing.expect(try list.popClip(testing.allocator));
    try testing.expectEqual(@as(u32, 0), list.clipDepth());

    try testing.expect(!try list.popClip(testing.allocator));
    // The stray pop recorded nothing, so the list is still walkable.
    try testing.expectEqual(@as(usize, 2), list.items().len);
}

test "a nested clip is intersected with the one already open" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);

    try list.pushClip(testing.allocator, .init(0, 0, 100, 100));
    // A list inside a panel, hanging off its right edge and its bottom.
    try list.pushClip(testing.allocator, .init(50, 50, 100, 100));

    try testing.expectEqual(Rect.init(50, 50, 50, 50), list.currentClip().?);
    try testing.expectEqual(Rect.init(50, 50, 50, 50), list.items()[1].clip_push);

    // And popping restores the outer one rather than clearing the clip entirely.
    _ = try list.popClip(testing.allocator);
    try testing.expectEqual(Rect.init(0, 0, 100, 100), list.currentClip().?);
}

test "a clip that misses its parent entirely shows nothing, and says so" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);

    try list.pushClip(testing.allocator, .init(0, 0, 100, 100));
    try list.pushClip(testing.allocator, .init(500, 500, 10, 10));
    try testing.expect(list.currentClip().?.isEmpty());
}

test "reset keeps capacity and drops content" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);

    try list.addText(testing.allocator, .zero, "gone", .white, 1);
    try list.pushClip(testing.allocator, .init(0, 0, 1, 1));
    list.reset();

    try testing.expectEqual(@as(usize, 0), list.items().len);
    try testing.expectEqual(@as(u32, 0), list.clipDepth());
    try testing.expectEqual(@as(?Rect, null), list.currentClip());
    try testing.expectEqual(@as(usize, 0), list.text_bytes.items.len);
}

test "an image and a nine-slice are recorded as given, and empty or broken ones are not" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);
    const gpa = testing.allocator;
    const atlas = ImageRef.of(3);
    const tint: Color = .{ .r = 1, .g = 0.5, .b = 0.25, .a = 1 };

    try list.addImage(gpa, .init(10, 20, 16, 16), .{ .image = atlas, .x = 32, .y = 0, .w = 8, .h = 8 }, tint);
    try list.addNineSlice(gpa, .init(0, 0, 100, 40), .{ .image = atlas, .w = 16, .h = 16 }, .all(4), 2, .white);

    // Nothing for an empty rectangle, an empty source, or a scale that is not a size.
    try list.addImage(gpa, .init(0, 0, 0, 10), .{ .image = atlas, .w = 8, .h = 8 }, tint);
    try list.addImage(gpa, .init(0, 0, 10, 10), .{ .image = atlas, .w = 0, .h = 8 }, tint);
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        try list.addNineSlice(gpa, .init(0, 0, 10, 10), .{ .image = atlas, .w = 8, .h = 8 }, .all(2), bad, .white);
    }

    // The golden list: exactly two commands, carrying numbers and nothing else.
    const want = [_]Command{
        .{ .image = .{ .bounds = .init(10, 20, 16, 16), .source = .{ .image = atlas, .x = 32, .y = 0, .w = 8, .h = 8 }, .tint = tint } },
        .{ .nine_slice = .{ .bounds = .init(0, 0, 100, 40), .source = .{ .image = atlas, .w = 16, .h = 16 }, .insets = .all(4), .scale = 2, .tint = .white } },
    };
    try testing.expectEqualDeep(@as([]const Command, &want), list.items());
}

test "a nine-slice's corners keep their size, its edges stretch one way and its centre both" {
    const cut = nineSlice(.{
        .bounds = .init(10, 20, 100, 40),
        .source = .{ .image = .of(0), .x = 64, .y = 16, .w = 16, .h = 16 },
        .insets = .all(4),
        .scale = 2,
        .tint = .white,
    });
    const pieces = cut.slice();
    try testing.expectEqual(@as(usize, 9), pieces.len);

    // Corners: 4 image pixels at scale 2 is 8 screen units, whatever the bounds are.
    try testing.expectEqual(Piece{ .dest = .init(10, 20, 8, 8), .x = 64, .y = 16, .w = 4, .h = 4 }, pieces[0]);
    try testing.expectEqual(Piece{ .dest = .init(102, 52, 8, 8), .x = 76, .y = 28, .w = 4, .h = 4 }, pieces[8]);
    // The top edge stretches across, and keeps its height.
    try testing.expectEqual(Piece{ .dest = .init(18, 20, 84, 8), .x = 68, .y = 16, .w = 8, .h = 4 }, pieces[1]);
    // The left edge stretches down, and keeps its width.
    try testing.expectEqual(Piece{ .dest = .init(10, 28, 8, 24), .x = 64, .y = 20, .w = 4, .h = 8 }, pieces[3]);
    // The centre stretches both ways.
    try testing.expectEqual(Piece{ .dest = .init(18, 28, 84, 24), .x = 68, .y = 20, .w = 8, .h = 8 }, pieces[4]);

    // The pieces tile the bounds exactly: no gap and no overlap.
    var area: f32 = 0;
    for (pieces) |p| area += p.dest.w * p.dest.h;
    try testing.expectEqual(@as(f32, 100 * 40), area);
}

test "a nine-slice smaller than its borders shrinks them in proportion, and bad insets are clamped" {
    // 12 units wide for two 8-unit borders: each becomes 6, and the middle column vanishes.
    const narrow = nineSlice(.{
        .bounds = .init(0, 0, 12, 40),
        .source = .{ .image = .of(0), .w = 16, .h = 16 },
        .insets = .all(4),
        .scale = 2,
        .tint = .white,
    });
    try testing.expectEqual(@as(usize, 6), narrow.len);
    try testing.expectEqual(Rect.init(0, 0, 6, 8), narrow.slice()[0].dest);
    try testing.expectEqual(Rect.init(6, 0, 6, 8), narrow.slice()[1].dest);

    // Insets past the source are clamped to it, left and top first, so nothing reads
    // outside the rectangle the caller named; with no room left for a centre, there is none.
    const clamped = nineSlice(.{
        .bounds = .init(0, 0, 100, 100),
        .source = .{ .image = .of(0), .x = 8, .y = 8, .w = 10, .h = 10 },
        .insets = .{ .left = 7, .right = 9, .top = 40, .bottom = 2 },
        .scale = 1,
        .tint = .white,
    });
    for (clamped.slice()) |p| {
        try testing.expect(p.x >= 8 and p.x + p.w <= 18);
        try testing.expect(p.y >= 8 and p.y + p.h <= 18);
    }
    // Left 7 and right 3; top 10 and bottom 0: two columns, one row.
    try testing.expectEqual(@as(usize, 2), clamped.len);

    // A source past the end of the number line cuts to nothing rather than overflowing.
    const beyond = nineSlice(.{
        .bounds = .init(0, 0, 50, 50),
        .source = .{ .image = .of(0), .x = std.math.maxInt(u32) - 2, .w = 16, .h = 16 },
        .insets = .all(4),
        .scale = 1,
        .tint = .white,
    });
    try testing.expectEqual(@as(usize, 0), beyond.len);

    // No insets at all is an image stretched whole.
    const plain = nineSlice(.{
        .bounds = .init(0, 0, 50, 50),
        .source = .{ .image = .of(0), .w = 16, .h = 16 },
        .insets = .{},
        .scale = 1,
        .tint = .white,
    });
    try testing.expectEqual(@as(usize, 1), plain.len);
    try testing.expectEqual(Piece{ .dest = .init(0, 0, 50, 50), .x = 0, .y = 0, .w = 16, .h = 16 }, plain.slice()[0]);
}

test "a fade dims everything recorded while it is set, and a reset clears it" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);
    const gpa = testing.allocator;

    list.fade = 0.5;
    try list.addRect(gpa, .init(0, 0, 1, 1), .white);
    try list.addText(gpa, .zero, "a", .{ .r = 1, .g = 1, .b = 1, .a = 0.5 }, 1);
    try list.addImage(gpa, .init(0, 0, 1, 1), .{ .image = .of(1), .w = 1, .h = 1 }, .white);
    try testing.expectEqual(@as(f32, 0.5), list.items()[0].rect.color.a);
    try testing.expectEqual(@as(f32, 0.25), list.items()[1].text.color.a);
    try testing.expectEqual(@as(f32, 0.5), list.items()[2].image.tint.a);
    // Only alpha: the colour is still the colour.
    try testing.expectEqual(@as(f32, 1), list.items()[0].rect.color.r);

    list.reset();
    try testing.expectEqual(@as(f32, 1), list.fade);
}
