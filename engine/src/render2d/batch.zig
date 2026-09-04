//! The batcher: what turns thousands of draw calls into a handful.

const std = @import("std");

const color_mod = @import("color.zig");
const sprite_mod = @import("sprite.zig");
const texture_mod = @import("texture.zig");

const Allocator = std.mem.Allocator;
const BlendMode = color_mod.BlendMode;
const Sprite = sprite_mod.Sprite;
const TextureHandle = texture_mod.TextureHandle;

/// One `drawIndexed` call.
pub const Batch = struct {
    /// Which vertex buffer of the frame's set this batch reads from. A batch never spans
    /// two, because a draw reads one bound buffer.
    buffer: u32,
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
    sprites: std.ArrayList(Sprite) = .empty,
    /// Indices into `sprites`, sorted. Sorting indices rather than sprites keeps the
    /// submission index available as the tie-break, and moves 4 bytes instead of 60.
    order: std.ArrayList(u32) = .empty,
    batches: std.ArrayList(Batch) = .empty,
    /// How many quads fit in one vertex buffer. A buffer boundary forces a batch break.
    quads_per_buffer: u32,

    pub fn init(quads_per_buffer: u32) Batcher {
        std.debug.assert(quads_per_buffer > 0);
        return .{ .quads_per_buffer = quads_per_buffer };
    }

    pub fn deinit(self: *Batcher, gpa: Allocator) void {
        self.sprites.deinit(gpa);
        self.order.deinit(gpa);
        self.batches.deinit(gpa);
        self.* = undefined;
    }

    /// Drops the frame's sprites but keeps the capacity, so a steady-state frame does no
    /// allocation at all after the first few.
    pub fn reset(self: *Batcher) void {
        self.sprites.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
    }

    pub fn add(self: *Batcher, gpa: Allocator, sprite: Sprite) Allocator.Error!void {
        try self.sprites.append(gpa, sprite);
    }

    pub fn count(self: *const Batcher) u32 {
        return @intCast(self.sprites.items.len);
    }

    /// How many vertex buffers this frame needs.
    pub fn bufferCount(self: *const Batcher) u32 {
        const n: u32 = @intCast(self.sprites.items.len);
        return (n + self.quads_per_buffer - 1) / self.quads_per_buffer;
    }

    /// Sort into draw order and compute the batches.
    ///
    /// **The sort key is `(layer, submission index)` and deliberately not texture.**
    /// Sorting by texture within a layer would cut the batch count and would reorder
    /// overlapping translucent sprites, which is wrong in a way that surfaces as
    /// flickering in someone else's game months later. The atlas is the answer to batch
    /// count; reordering is not.
    ///
    /// Because the key includes the submission index it is a **total** order, so the
    /// result does not depend on the sort algorithm being stable. That discharges I9 by
    /// construction rather than by choosing a stable sort and hoping nobody swaps it.
    pub fn plan(self: *Batcher, gpa: Allocator) Allocator.Error!void {
        self.order.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();

        try self.order.ensureTotalCapacity(gpa, self.sprites.items.len);
        for (0..self.sprites.items.len) |i| self.order.appendAssumeCapacity(@intCast(i));

        std.sort.pdq(u32, self.order.items, self.sprites.items, lessThan);

        for (self.order.items, 0..) |sprite_index, position| {
            const item = self.sprites.items[sprite_index];
            const buffer: u32 = @intCast(position / self.quads_per_buffer);
            const quad: u32 = @intCast(position % self.quads_per_buffer);

            if (self.batches.items.len > 0) {
                const last = &self.batches.items[self.batches.items.len - 1];
                if (last.buffer == buffer and
                    last.texture.eql(item.texture) and
                    last.blend == item.blend)
                {
                    last.quad_count += 1;
                    continue;
                }
            }

            try self.batches.append(gpa, .{
                .buffer = buffer,
                .texture = item.texture,
                .blend = item.blend,
                .first_quad = quad,
                .quad_count = 1,
            });
        }
    }

    fn lessThan(sprites: []const Sprite, a: u32, b: u32) bool {
        if (sprites[a].layer != sprites[b].layer) return sprites[a].layer < sprites[b].layer;
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
    for (sprites) |s| try b.add(gpa, s);
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

    for (0..100) |_| try b.add(gpa, at(0, 0, .alpha));
    try b.plan(gpa);
    const capacity = b.sprites.capacity;

    b.reset();
    try testing.expectEqual(@as(u32, 0), b.count());
    try testing.expectEqual(capacity, b.sprites.capacity);
    try testing.expectEqual(@as(usize, 0), b.batches.items.len);
}

test "an empty frame plans no batches rather than one empty one" {
    const gpa = testing.allocator;
    var b = try planned(gpa, 64, &.{});
    defer b.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), b.batches.items.len);
    try testing.expectEqual(@as(u32, 0), b.bufferCount());
}
