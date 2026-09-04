//! The batcher: what turns thousands of draw calls into a handful.

const std = @import("std");

const color_mod = @import("color.zig");
const sprite_mod = @import("sprite.zig");
const texture_mod = @import("texture.zig");
const view_mod = @import("view.zig");

const Allocator = std.mem.Allocator;
const BlendMode = color_mod.BlendMode;
const Sprite = sprite_mod.Sprite;
const TextureHandle = texture_mod.TextureHandle;
const ViewId = view_mod.ViewId;

/// One sprite as submitted: what to draw, and which space to draw it in.
///
/// The view lives here rather than on `Sprite` on purpose. It changes per screenful, not
/// per sprite — a HUD is one `setView` and then a hundred draws — and putting it in the
/// struct would mean copying the same field onto `TextOptions` and onto every draw struct
/// that ever exists. See `view.zig`.
pub const Item = struct {
    sprite: Sprite,
    view: ViewId,
};

/// One `drawIndexed` call.
pub const Batch = struct {
    /// Which vertex buffer of the frame's set this batch reads from. A batch never spans
    /// two, because a draw reads one bound buffer.
    buffer: u32,
    /// Which space this batch is drawn in. The recorder binds its transform and viewport.
    view: ViewId,
    texture: TextureHandle,
    blend: BlendMode,
    /// Quad offset within `buffer`, not within the frame.
    first_quad: u32,
    quad_count: u32,
};

/// Accumulates a frame's sprites, orders them, and works out the draw calls.
///
/// Deliberately knows nothing about the GPU: it takes sprites and a quads-per-buffer
/// capacity and produces batches. That is what makes the ordering rules — the part most
/// likely to be got subtly wrong — testable without a device.
pub const Batcher = struct {
    items: std.ArrayList(Item) = .empty,
    /// Indices into `items`, sorted. Sorting indices rather than items keeps the
    /// submission index available as the tie-break, and moves 4 bytes instead of 64.
    order: std.ArrayList(u32) = .empty,
    batches: std.ArrayList(Batch) = .empty,
    /// How many quads fit in one vertex buffer. A buffer boundary forces a batch break.
    quads_per_buffer: u32,

    pub fn init(quads_per_buffer: u32) Batcher {
        std.debug.assert(quads_per_buffer > 0);
        return .{ .quads_per_buffer = quads_per_buffer };
    }

    pub fn deinit(self: *Batcher, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.order.deinit(gpa);
        self.batches.deinit(gpa);
        self.* = undefined;
    }

    /// Drops the frame's sprites but keeps the capacity, so a steady-state frame does no
    /// allocation at all after the first few.
    pub fn reset(self: *Batcher) void {
        self.items.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
    }

    pub fn add(self: *Batcher, gpa: Allocator, sprite: Sprite, view: ViewId) Allocator.Error!void {
        try self.items.append(gpa, .{ .sprite = sprite, .view = view });
    }

    pub fn count(self: *const Batcher) u32 {
        return @intCast(self.items.items.len);
    }

    /// How many vertex buffers this frame needs.
    pub fn bufferCount(self: *const Batcher) u32 {
        const n: u32 = @intCast(self.items.items.len);
        return (n + self.quads_per_buffer - 1) / self.quads_per_buffer;
    }

    /// Sort into draw order and compute the batches.
    ///
    /// **The sort key is `(view, layer, submission index)` and deliberately not texture.**
    /// Sorting by texture within a layer would cut the batch count and would reorder
    /// overlapping translucent sprites, which is wrong in a way that surfaces as
    /// flickering in someone else's game months later. The atlas is the answer to batch
    /// count; reordering is not.
    ///
    /// **`view` comes first**, so a view is drawn entirely before the next and `layer`
    /// orders *within* a view rather than across them. That is what makes a HUD a HUD:
    /// nothing in the world can be given a layer high enough to cover it. The cost is
    /// honest — the floor on batch count is the number of views in use.
    ///
    /// Because the key includes the submission index it is a **total** order, so the
    /// result does not depend on the sort algorithm being stable. That discharges I9 by
    /// construction rather than by choosing a stable sort and hoping nobody swaps it.
    pub fn plan(self: *Batcher, gpa: Allocator) Allocator.Error!void {
        self.order.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();

        try self.order.ensureTotalCapacity(gpa, self.items.items.len);
        for (0..self.items.items.len) |i| self.order.appendAssumeCapacity(@intCast(i));

        std.sort.pdq(u32, self.order.items, self.items.items, lessThan);

        for (self.order.items, 0..) |item_index, position| {
            const item = self.items.items[item_index];
            const buffer: u32 = @intCast(position / self.quads_per_buffer);
            const quad: u32 = @intCast(position % self.quads_per_buffer);

            if (self.batches.items.len > 0) {
                const last = &self.batches.items[self.batches.items.len - 1];
                if (last.buffer == buffer and
                    last.view == item.view and
                    last.texture.eql(item.sprite.texture) and
                    last.blend == item.sprite.blend)
                {
                    last.quad_count += 1;
                    continue;
                }
            }

            try self.batches.append(gpa, .{
                .buffer = buffer,
                .view = item.view,
                .texture = item.sprite.texture,
                .blend = item.sprite.blend,
                .first_quad = quad,
                .quad_count = 1,
            });
        }
    }

    fn lessThan(items: []const Item, a: u32, b: u32) bool {
        const x = items[a];
        const y = items[b];
        if (x.view != y.view) return @intFromEnum(x.view) < @intFromEnum(y.view);
        if (x.sprite.layer != y.sprite.layer) return x.sprite.layer < y.sprite.layer;
        return a < b;
    }
};

const testing = std.testing;

fn at(layer: i16, texture_index: u32, blend: BlendMode) Sprite {
    return .{
        .texture = .{ .index = texture_index, .generation = 1 },
        .position = .init(0, 0),
        .size = .init(1, 1),
        .layer = layer,
        .blend = blend,
    };
}

fn planned(gpa: Allocator, quads_per_buffer: u32, sprites: []const Sprite) !Batcher {
    var b: Batcher = .init(quads_per_buffer);
    errdefer b.deinit(gpa);
    for (sprites) |s| try b.add(gpa, s, .world);
    try b.plan(gpa);
    return b;
}

fn plannedInViews(gpa: Allocator, items: []const Item) !Batcher {
    var b: Batcher = .init(1024);
    errdefer b.deinit(gpa);
    for (items) |it| try b.add(gpa, it.sprite, it.view);
    try b.plan(gpa);
    return b;
}

test "layers order, and submission order breaks every tie" {
    const gpa = testing.allocator;
    var b = try planned(gpa, 1024, &.{
        at(5, 0, .alpha),
        at(-3, 1, .alpha),
        at(5, 2, .alpha),
        at(0, 3, .alpha),
    });
    defer b.deinit(gpa);

    // Sorted by layer; the two layer-5 sprites keep the order they were submitted in.
    try testing.expectEqualSlices(u32, &.{ 1, 3, 0, 2 }, b.order.items);
}

test "the order is total, so it does not depend on the sort being stable" {
    const gpa = testing.allocator;
    // Two hundred sprites all on the same layer: with only `layer` as the key an
    // unstable sort would be free to shuffle these, and the result would differ between
    // runs or between compiler versions. It must not.
    var sprites: [200]Sprite = undefined;
    for (&sprites, 0..) |*s, i| s.* = at(0, @intCast(i % 7), .alpha);

    var first = try planned(gpa, 1024, &sprites);
    defer first.deinit(gpa);
    var second = try planned(gpa, 1024, &sprites);
    defer second.deinit(gpa);

    try testing.expectEqualSlices(u32, first.order.items, second.order.items);
    // And that order is exactly submission order, since every layer is equal.
    for (first.order.items, 0..) |index, position| {
        try testing.expectEqual(@as(u32, @intCast(position)), index);
    }
}

test "sprites sharing a texture and blend mode become one draw call" {
    const gpa = testing.allocator;
    var b = try planned(gpa, 1024, &.{
        at(0, 7, .alpha),
        at(0, 7, .alpha),
        at(0, 7, .alpha),
    });
    defer b.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), b.batches.items.len);
    try testing.expectEqual(@as(u32, 3), b.batches.items[0].quad_count);
    try testing.expectEqual(@as(u32, 0), b.batches.items[0].first_quad);
}

test "a batch breaks on texture and on blend mode, and not on anything else" {
    const gpa = testing.allocator;
    var b = try planned(gpa, 1024, &.{
        at(0, 1, .alpha),
        at(0, 2, .alpha), // different texture
        at(0, 2, .alpha),
        at(0, 2, .additive), // same texture, different blend
    });
    defer b.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), b.batches.items.len);
    try testing.expectEqual(@as(u32, 1), b.batches.items[0].quad_count);
    try testing.expectEqual(@as(u32, 2), b.batches.items[1].quad_count);
    try testing.expectEqual(@as(u32, 1), b.batches.items[2].quad_count);
}

test "interleaving textures is expensive, which is what the atlas is for" {
    const gpa = testing.allocator;
    var sprites: [8]Sprite = undefined;
    for (&sprites, 0..) |*s, i| s.* = at(0, @intCast(i % 2), .alpha);

    var b = try planned(gpa, 1024, &sprites);
    defer b.deinit(gpa);

    // Eight sprites alternating between two textures is eight draw calls. Sorting by
    // texture would make it two and would reorder them, which is the trade this design
    // explicitly refuses.
    try testing.expectEqual(@as(usize, 8), b.batches.items.len);
}

test "a full buffer forces a break, and quads count from zero in the next one" {
    const gpa = testing.allocator;
    var sprites: [5]Sprite = undefined;
    for (&sprites) |*s| s.* = at(0, 3, .alpha);

    var b = try planned(gpa, 2, &sprites);
    defer b.deinit(gpa);

    try testing.expectEqual(@as(u32, 3), b.bufferCount());
    try testing.expectEqual(@as(usize, 3), b.batches.items.len);

    // Every batch addresses its own buffer, starting at quad zero.
    for (b.batches.items, 0..) |batch, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), batch.buffer);
        try testing.expectEqual(@as(u32, 0), batch.first_quad);
    }
    try testing.expectEqual(@as(u32, 2), b.batches.items[0].quad_count);
    try testing.expectEqual(@as(u32, 1), b.batches.items[2].quad_count);
}

test "reset keeps capacity so a steady frame does not allocate" {
    const gpa = testing.allocator;
    var b: Batcher = .init(64);
    defer b.deinit(gpa);

    for (0..100) |_| try b.add(gpa, at(0, 0, .alpha), .world);
    try b.plan(gpa);
    const capacity = b.items.capacity;

    b.reset();
    try testing.expectEqual(@as(u32, 0), b.count());
    try testing.expectEqual(capacity, b.items.capacity);
    try testing.expectEqual(@as(usize, 0), b.batches.items.len);
}

test "an empty frame plans no batches rather than one empty one" {
    const gpa = testing.allocator;
    var b = try planned(gpa, 64, &.{});
    defer b.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), b.batches.items.len);
    try testing.expectEqual(@as(u32, 0), b.bufferCount());
}

test "a view is drawn entirely before the next, whatever the layers say" {
    const gpa = testing.allocator;
    // A screen-space sprite on the *lowest* layer against a world sprite on the highest.
    // If layer led the sort the HUD would be buried, which is the bug this ordering
    // exists to make impossible.
    var b = try plannedInViews(gpa, &.{
        .{ .sprite = at(std.math.maxInt(i16), 0, .alpha), .view = .world },
        .{ .sprite = at(std.math.minInt(i16), 0, .alpha), .view = .screen },
        .{ .sprite = at(0, 0, .alpha), .view = .world },
    });
    defer b.deinit(gpa);

    // Both world sprites first, ordered by layer among themselves; the screen one last.
    try testing.expectEqualSlices(u32, &.{ 2, 0, 1 }, b.order.items);
}

test "a view change breaks a batch even when nothing else changes" {
    const gpa = testing.allocator;
    // Same texture, same blend, same layer: the only difference is the space, and that is
    // a different transform bound on the GPU, so it cannot share a draw call.
    var b = try plannedInViews(gpa, &.{
        .{ .sprite = at(0, 1, .alpha), .view = .world },
        .{ .sprite = at(0, 1, .alpha), .view = .screen },
    });
    defer b.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), b.batches.items.len);
    try testing.expectEqual(ViewId.world, b.batches.items[0].view);
    try testing.expectEqual(ViewId.screen, b.batches.items[1].view);
}

test "sprites in one view still batch together across submission order" {
    const gpa = testing.allocator;
    // Interleaved on submission, but the sort groups them: two draw calls, not four. This
    // is why the view is the sort key and not merely a batch-break condition.
    var b = try plannedInViews(gpa, &.{
        .{ .sprite = at(0, 1, .alpha), .view = .screen },
        .{ .sprite = at(0, 1, .alpha), .view = .world },
        .{ .sprite = at(0, 1, .alpha), .view = .screen },
        .{ .sprite = at(0, 1, .alpha), .view = .world },
    });
    defer b.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), b.batches.items.len);
    try testing.expectEqual(@as(u32, 2), b.batches.items[0].quad_count);
    try testing.expectEqual(@as(u32, 2), b.batches.items[1].quad_count);
}

test "views past the named two order by their id" {
    const gpa = testing.allocator;
    // The order a caller gets is the order `addView` handed the ids out in, which is what
    // makes "add the minimap after the HUD and it draws on top" mean something.
    var b = try plannedInViews(gpa, &.{
        .{ .sprite = at(0, 1, .alpha), .view = ViewId.fromIndex(4) },
        .{ .sprite = at(0, 1, .alpha), .view = ViewId.fromIndex(2) },
        .{ .sprite = at(0, 1, .alpha), .view = .world },
    });
    defer b.deinit(gpa);

    try testing.expectEqualSlices(u32, &.{ 2, 1, 0 }, b.order.items);
}
