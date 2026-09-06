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
//! Design: `docs/design/ui.md` §6.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Rect = core.math.Rect;
const Vec2 = core.math.Vec2;
const Color = @import("style.zig").Color;

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

pub const Command = union(enum) {
    rect: RectCommand,
    text: TextCommand,
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
    /// Depth of the clip stack, so an unbalanced frame is caught rather than handed to a
    /// walker that would then clip everything after it.
    clip_depth: u32 = 0,

    pub fn deinit(self: *DrawList, gpa: Allocator) void {
        self.commands.deinit(gpa);
        self.text_bytes.deinit(gpa);
        self.* = .{};
    }

    pub fn reset(self: *DrawList) void {
        self.commands.clearRetainingCapacity();
        self.text_bytes.clearRetainingCapacity();
        self.clip_depth = 0;
    }

    pub fn addRect(self: *DrawList, gpa: Allocator, bounds: Rect, color: Color) Allocator.Error!void {
        // An empty rectangle is not an error and not worth a command; a layout that
        // produces one is usually a container with nothing in it yet.
        if (bounds.isEmpty()) return;
        try self.commands.append(gpa, .{ .rect = .{ .bounds = bounds, .color = color } });
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
            .text = .{ .at = at, .text = ref, .color = color, .scale = scale },
        });
    }

    pub fn pushClip(self: *DrawList, gpa: Allocator, bounds: Rect) Allocator.Error!void {
        try self.commands.append(gpa, .{ .clip_push = bounds });
        self.clip_depth += 1;
    }

    /// Popping an empty stack is a caller bug — from M7 possibly a mod's — so it is
    /// reported by returning false rather than asserted (CLAUDE.md §7). The command is not
    /// recorded, which keeps the list walkable whatever the caller did.
    pub fn popClip(self: *DrawList, gpa: Allocator) Allocator.Error!bool {
        if (self.clip_depth == 0) return false;
        try self.commands.append(gpa, .clip_pop);
        self.clip_depth -= 1;
        return true;
    }

    /// The bytes a `TextRef` names. Valid until the next `reset`.
    pub fn textOf(self: *const DrawList, ref: TextRef) []const u8 {
        return self.text_bytes.items[ref.offset..][0..ref.len];
    }

    pub fn items(self: *const DrawList) []const Command {
        return self.commands.items;
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
    try testing.expectEqual(@as(u32, 1), list.clip_depth);
    try testing.expect(try list.popClip(testing.allocator));
    try testing.expectEqual(@as(u32, 0), list.clip_depth);

    try testing.expect(!try list.popClip(testing.allocator));
    // The stray pop recorded nothing, so the list is still walkable.
    try testing.expectEqual(@as(usize, 2), list.items().len);
}

test "reset keeps capacity and drops content" {
    var list: DrawList = .{};
    defer list.deinit(testing.allocator);

    try list.addText(testing.allocator, .zero, "gone", .white, 1);
    try list.pushClip(testing.allocator, .init(0, 0, 1, 1));
    list.reset();

    try testing.expectEqual(@as(usize, 0), list.items().len);
    try testing.expectEqual(@as(u32, 0), list.clip_depth);
    try testing.expectEqual(@as(usize, 0), list.text_bytes.items.len);
}
