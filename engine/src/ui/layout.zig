//! Layout: a stack of regions, and the cursor arithmetic that places one widget after the
//! next.
//!
//! **Layout is a cursor, not a solver.** A region is a rectangle, a cursor, a direction and
//! a spacing; each widget consumes a rectangle and the cursor advances. Nothing is measured
//! twice and nothing iterates to a fixed point. A debug panel is a stack of full-width rows
//! with the occasional side-by-side pair, and anything more expressive belongs to the game
//! widget layer, where a designer's intent actually needs stating.
//!
//! Nothing here draws and nothing here interacts, so it is arithmetic that can be checked
//! on its own — which is most of why it is a file rather than a handful of fields on the
//! `Context`.
//!
//! Design: `docs/design/ui.md` §5.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const Rect = core.math.Rect;
const Vec2 = core.math.Vec2;
const Id = @import("id.zig").Id;

pub const Axis = enum { vertical, horizontal };

/// Replace anything that is not a finite number with zero, and refuse a negative extent.
///
/// `ui.md` §12: rectangles reaching the kernel come from a game and, from M7, from a mod, so
/// a NaN is **rejected at the region boundary** rather than asserted on. One NaN that got as
/// far as a cursor would poison every rectangle placed after it, and the symptom would
/// appear in a widget that did nothing wrong.
pub fn sanitize(r: Rect) Rect {
    return .init(finite(r.x), finite(r.y), @max(0, finite(r.w)), @max(0, finite(r.h)));
}

fn finite(v: f32) f32 {
    return if (std.math.isFinite(v)) v else 0;
}

fn extent(v: f32) f32 {
    return @max(0, finite(v));
}

pub const Region = struct {
    /// The area widgets are placed inside. Already sanitized.
    bounds: Rect = .{},
    /// Top-left of the next rectangle to be handed out.
    cursor: Vec2 = .zero,
    axis: Axis = .vertical,
    spacing: f32 = 0,
    /// Seeds the ids of widgets described inside this region, so a panel drawn twice with
    /// different seeds has distinct children without either call site inventing names.
    seed: Id = .root,
    /// The widest and tallest the placed rectangles reached, measured from `bounds`'
    /// origin, so a container can size itself to its contents. Trailing spacing is not
    /// counted: it falls *between* items, and a panel padded by a gap nobody asked for is
    /// how a layout drifts.
    placed: Vec2 = .zero,

    pub fn init(bounds: Rect, axis: Axis, spacing: f32, seed: Id) Region {
        const clean = sanitize(bounds);
        return .{
            .bounds = clean,
            .cursor = .init(clean.x, clean.y),
            .axis = axis,
            .spacing = extent(spacing),
            .seed = seed,
        };
    }

    /// From the cursor to the region's far corner. Never negative, so a region that has
    /// been overfilled reports nothing left rather than a rectangle inside out.
    pub fn remaining(self: Region) Rect {
        return .init(
            self.cursor.x,
            self.cursor.y,
            @max(0, self.bounds.x + self.bounds.w - self.cursor.x),
            @max(0, self.bounds.y + self.bounds.h - self.cursor.y),
        );
    }

    /// Reserve `main` along the region's axis and everything left across it.
    ///
    /// **A widget that does not fit still gets the rectangle it asked for**, running past
    /// the region's edge rather than being squashed into what is left. Clipping is a draw
    /// concern (`ui.md` §11) and a widget that silently changed height when a panel filled
    /// up would be far harder to explain than one that is simply cut off.
    pub fn take(self: *Region, main: f32) Rect {
        const size = extent(main);
        const left = self.remaining();
        const rect: Rect = switch (self.axis) {
            .vertical => .init(left.x, left.y, left.w, size),
            .horizontal => .init(left.x, left.y, size, left.h),
        };
        switch (self.axis) {
            .vertical => self.cursor.y += size + self.spacing,
            .horizontal => self.cursor.x += size + self.spacing,
        }
        self.placed = .init(
            @max(self.placed.x, rect.x + rect.w - self.bounds.x),
            @max(self.placed.y, rect.y + rect.h - self.bounds.y),
        );
        return rect;
    }

    /// Reserve the component of `desired` that lies along the region's axis. Every widget
    /// works out how big it wants to be on both axes and calls this, so the same widget
    /// stacks in a panel and sits side by side in a row without knowing which it is in.
    pub fn takeSize(self: *Region, desired: Vec2) Rect {
        return self.take(switch (self.axis) {
            .vertical => desired.y,
            .horizontal => desired.x,
        });
    }
};

/// The open regions, innermost last.
///
/// The outermost region is a **field rather than the first element**, so there is always a
/// region to place a widget in and `begin` cannot fail for want of memory. A caller that
/// describes a widget without opening anything gets the viewport, which is the only answer
/// that is ever useful.
pub const Stack = struct {
    root: Region = .{},
    nested: std.ArrayList(Region) = .empty,

    pub fn deinit(self: *Stack, gpa: Allocator) void {
        self.nested.deinit(gpa);
        self.* = .{};
    }

    /// Start a frame: one region covering `viewport`, and nothing nested. Keeps the
    /// capacity a previous frame earned.
    pub fn reset(self: *Stack, root: Region) void {
        self.root = root;
        self.nested.clearRetainingCapacity();
    }

    pub fn push(self: *Stack, gpa: Allocator, region: Region) Allocator.Error!void {
        try self.nested.append(gpa, region);
    }

    /// False when there was nothing nested to pop — a caller bug, reported rather than
    /// asserted, and the outermost region survives it.
    pub fn pop(self: *Stack) bool {
        if (self.nested.items.len == 0) return false;
        _ = self.nested.pop();
        return true;
    }

    pub fn current(self: *Stack) *Region {
        if (self.nested.items.len == 0) return &self.root;
        return &self.nested.items[self.nested.items.len - 1];
    }

    pub fn seed(self: *const Stack) Id {
        if (self.nested.items.len == 0) return self.root.seed;
        return self.nested.items[self.nested.items.len - 1].seed;
    }

    pub fn depth(self: *const Stack) u32 {
        return @intCast(self.nested.items.len);
    }
};

const testing = std.testing;

const panel: Rect = .init(10, 20, 100, 200);

test "a vertical region stacks full-width rows" {
    var region: Region = .init(panel, .vertical, 4, .root);

    try testing.expectEqual(Rect.init(10, 20, 100, 30), region.take(30));
    // The next row starts one spacing below the last.
    try testing.expectEqual(Rect.init(10, 54, 100, 30), region.take(30));
}

test "a horizontal region places rows side by side, full height" {
    var region: Region = .init(panel, .horizontal, 4, .root);

    try testing.expectEqual(Rect.init(10, 20, 30, 200), region.take(30));
    try testing.expectEqual(Rect.init(44, 20, 30, 200), region.take(30));
}

test "takeSize picks the component the region's axis cares about" {
    var down: Region = .init(panel, .vertical, 0, .root);
    var across: Region = .init(panel, .horizontal, 0, .root);

    const desired: Vec2 = .init(40, 12);
    try testing.expectEqual(@as(f32, 12), down.takeSize(desired).h);
    try testing.expectEqual(@as(f32, 100), down.takeSize(desired).w);
    try testing.expectEqual(@as(f32, 40), across.takeSize(desired).w);
    try testing.expectEqual(@as(f32, 200), across.takeSize(desired).h);
}

test "what was placed is measured without the trailing gap" {
    var region: Region = .init(panel, .vertical, 4, .root);
    _ = region.take(30);
    _ = region.take(30);
    // Two rows and one gap: 30 + 4 + 30. The gap after the second is not content.
    try testing.expectEqual(Vec2.init(100, 64), region.placed);
}

test "a widget that does not fit keeps the size it asked for" {
    var region: Region = .init(.init(0, 0, 100, 20), .vertical, 0, .root);
    _ = region.take(20);

    // Past the bottom edge: the rectangle is still 30 tall, sitting outside the region.
    const overflow = region.take(30);
    try testing.expectEqual(Rect.init(0, 20, 100, 30), overflow);
    try testing.expect(region.remaining().isEmpty());
}

test "a region rejects rubbish rather than propagating it" {
    var region: Region = .init(.init(std.math.nan(f32), 0, 100, -5), .vertical, std.math.inf(f32), .root);
    try testing.expectEqual(Rect.init(0, 0, 100, 0), region.bounds);
    try testing.expectEqual(@as(f32, 0), region.spacing);

    // And a NaN height reserves nothing rather than poisoning the cursor.
    _ = region.take(std.math.nan(f32));
    try testing.expectEqual(Vec2.init(0, 0), region.cursor);
}

test "the outermost region needs no allocation and survives an unbalanced pop" {
    var stack: Stack = .{};
    defer stack.deinit(testing.allocator);
    stack.reset(.init(panel, .vertical, 0, .root));

    try testing.expect(!stack.pop());
    try testing.expectEqual(@as(u32, 0), stack.depth());
    try testing.expectEqual(panel, stack.current().bounds);
}

test "nesting swaps which region a widget lands in, and unwinds" {
    var stack: Stack = .{};
    defer stack.deinit(testing.allocator);
    stack.reset(.init(panel, .vertical, 0, .root));

    const inner: Rect = .init(0, 0, 10, 10);
    try stack.push(testing.allocator, .init(inner, .horizontal, 0, Id.root.child("inner")));
    try testing.expectEqual(inner, stack.current().bounds);
    try testing.expectEqual(Id.root.child("inner"), stack.seed());

    try testing.expect(stack.pop());
    try testing.expectEqual(panel, stack.current().bounds);
    try testing.expectEqual(Id.root, stack.seed());
}
