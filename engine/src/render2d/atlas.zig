//! Packing many images into one texture, so that many sprites become one draw call.
//!
//! The batcher breaks a batch whenever the texture changes (`docs/design/render2d.md`
//! §7), so an atlas is the *only* real answer to batch count. Sorting by texture within a
//! layer is the wrong answer: it changes what the game asked to be drawn on top.
//!
//! Packing happens at **runtime**, deliberately. An offline packer in `tools/fpack` would
//! pack better, but a mod that adds a sprite needs packing to work at load time, and I3
//! says the base game uses the same path a mod does. An offline pre-pack can be added at
//! M3 as an optimisation of this mechanism rather than a replacement for it.

const std = @import("std");
const core = @import("core");

const texture_mod = @import("texture.zig");

const Allocator = std.mem.Allocator;
const Extent2D = texture_mod.Extent2D;
const Rect = core.math.Rect;
const TextureHandle = texture_mod.TextureHandle;

/// Phantom tag for `AtlasHandle`. Never instantiated (I1).
pub const Atlas = opaque {};

pub const AtlasHandle = core.Handle(Atlas);

pub const Error = error{
    /// No room left. A **normal** condition: the caller makes another atlas.
    AtlasFull,
    /// Larger than the atlas is, in one axis or both. Deliberately distinct from
    /// `AtlasFull`, because the two call for opposite responses: `AtlasFull` means try a
    /// fresh atlas, and a caller that answered this one the same way would allocate
    /// atlases forever. Content comes from files, so this is reachable by a mod shipping
    /// a 4096-pixel sprite, and it must be a clean refusal rather than a loop.
    RegionTooLarge,
};

pub const AtlasOptions = struct {
    /// Applies to the whole atlas, because a sampler belongs to a texture. Two sprites
    /// that need different filtering therefore belong in different atlases — which is a
    /// real constraint on packing, and the reason this is spelled out rather than left to
    /// be discovered.
    filter: texture_mod.Filter = .nearest,
    wrap: texture_mod.Wrap = .clamp,
    /// See `Packer.padding`. One texel, which is enough.
    padding: u32 = 1,
    label: []const u8 = "atlas",
};

/// Where an image ended up: which texture, and which part of it.
///
/// This is the only thing that escapes the packer, which is what makes the packing
/// algorithm replaceable without any caller noticing.
pub const Region = struct {
    texture: TextureHandle,
    /// In UV space, Y-down, matching `Sprite.uv` and every texture format on disk.
    uv: Rect,
    /// The region's size in pixels. Needed to draw it at its natural size, and needed to
    /// slice it further — a font's glyph grid is a `sub` of its region.
    size_px: Extent2D,

    /// A whole texture, addressed as a region. What a game holding a plain texture passes
    /// where a region is wanted, so that "in an atlas" and "on its own" are the same call.
    pub fn whole(handle: TextureHandle, size: Extent2D) Region {
        return .{
            .texture = handle,
            .uv = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .size_px = size,
        };
    }

    /// A sub-rectangle, in **this region's** pixel space rather than the texture's.
    ///
    /// Deliberately relative: a caller slicing a sprite sheet into cells should not have
    /// to know or care whether the sheet is a texture of its own or a corner of a shared
    /// atlas. That is exactly what a font does with its glyph grid, and it is why moving
    /// a font into an atlas changes no code that uses it.
    ///
    /// The rectangle is clamped to the region, so an out-of-range cell yields an empty or
    /// truncated region rather than sampling a neighbour's pixels — which, in an atlas, is
    /// someone else's sprite.
    pub fn sub(self: Region, x: u32, y: u32, w: u32, h: u32) Region {
        if (self.size_px.isEmpty()) return .{ .texture = self.texture, .uv = .{}, .size_px = .{} };

        const cx = @min(x, self.size_px.width);
        const cy = @min(y, self.size_px.height);
        const cw = @min(w, self.size_px.width - cx);
        const ch = @min(h, self.size_px.height - cy);

        const inv_w = self.uv.w / @as(f32, @floatFromInt(self.size_px.width));
        const inv_h = self.uv.h / @as(f32, @floatFromInt(self.size_px.height));
        return .{
            .texture = self.texture,
            .uv = .{
                .x = self.uv.x + @as(f32, @floatFromInt(cx)) * inv_w,
                .y = self.uv.y + @as(f32, @floatFromInt(cy)) * inv_h,
                .w = @as(f32, @floatFromInt(cw)) * inv_w,
                .h = @as(f32, @floatFromInt(ch)) * inv_h,
            },
            .size_px = .{ .width = cw, .height = ch },
        };
    }

    /// Cell `index` of a `columns` x `rows` grid cut from this region, row-major.
    ///
    /// The unit a sprite sheet is authored in: an animation names a run of cells and
    /// `frameAt` says which one is showing. Built on `sub`, so a sheet packed into a
    /// shared atlas slices identically to one that got a texture of its own — which is
    /// what makes moving it into an atlas a change to one creation call and to nothing
    /// else (`docs/design/render2d.md` §8).
    ///
    /// Cell size is integer division, so a sheet whose pixels do not divide evenly leaves
    /// a strip at the right or bottom unused. That is the honest answer: the alternative
    /// is cells of two different sizes, which is worse and harder to notice.
    ///
    /// **Everything out of range yields an empty region rather than a neighbouring cell**
    /// — a zero grid dimension, an `index` past the last cell, or a region too small to
    /// divide. All three come from content (a clip's `first + count` is a number in a
    /// file), and `sub` already refuses to read past a region's edge for the same reason:
    /// in an atlas, the texels next door are somebody else's sprite. An animation that
    /// vanishes sends its author to the clip; one that silently shows the wrong cell does
    /// not.
    pub fn cell(self: Region, columns: u32, rows: u32, index: u32) Region {
        const nothing: Region = .{ .texture = self.texture, .uv = .{}, .size_px = .{} };
        if (columns == 0 or rows == 0) return nothing;
        // Widened, because a 65,536-square grid is a content mistake rather than a crash.
        if (index >= @as(u64, columns) * @as(u64, rows)) return nothing;

        const cw = self.size_px.width / columns;
        const ch = self.size_px.height / rows;
        return self.sub((index % columns) * cw, (index / columns) * ch, cw, ch);
    }
};

/// Where the packer decided an image goes, in texels from the atlas's top-left.
pub const Placement = struct { x: u32, y: u32 };

/// A shelf packer: rows of a fixed height, filled left to right.
///
/// **Not a skyline or MAXRECTS packer.** Shelf is a hundred lines, gets within a few
/// percent of optimal when the images are the same height — which is what a sprite sheet
/// and a glyph grid both are — and only `Placement` escapes it, so a better packer is a
/// drop-in replacement rather than an API change.
///
/// `docs/design/render2d.md` §8 describes this as "sort by height, fill rows". Sorting is
/// what an offline packer does, and it is not available here: `add` is called one image at
/// a time, because a mod adds one sprite at load time long after the others were packed.
/// The incremental equivalent is **best fit by height** — put the image on the shelf that
/// wastes the least vertical space — which is what this does, and which degenerates to the
/// sorted result when the images are all the same height.
///
/// Pure logic, deliberately: no allocator beyond its own list, no GPU, no renderer. It is
/// the part most likely to be replaced and the part cheapest to test exhaustively.
pub const Packer = struct {
    size: Extent2D,
    /// Transparent texels reserved to the right of and below each image.
    ///
    /// One by default, and one is enough. Linear filtering samples four texels and will
    /// reach across a shared edge; nearest filtering will too, at a non-integer scale,
    /// because the sample point is a position rather than an index. A neighbour's colour
    /// bleeding into a sprite's edge is the classic atlas artefact and it is confusing
    /// precisely because the sprite looks correct on its own.
    padding: u32,

    shelves: std.ArrayList(Shelf) = .empty,
    /// The first y no shelf has claimed.
    used_height: u32 = 0,
    /// Texels the images themselves occupy, padding excluded. `fill` divides by this.
    used_area: u64 = 0,

    const Shelf = struct {
        y: u32,
        height: u32,
        /// The first x on this shelf that is free.
        cursor: u32,
    };

    pub fn init(size: Extent2D, padding: u32) Packer {
        return .{ .size = size, .padding = padding };
    }

    pub fn deinit(self: *Packer, gpa: Allocator) void {
        self.shelves.deinit(gpa);
        self.* = undefined;
    }

    /// Finds room for a `w` by `h` image, or says why there is none.
    pub fn add(self: *Packer, gpa: Allocator, w: u32, h: u32) (Error || Allocator.Error)!Placement {
        if (w == 0 or h == 0) return error.RegionTooLarge;
        // Padded, because the reservation is what has to fit — an image flush against the
        // right edge with no padding beyond it is fine, but one that needs its padding to
        // hang off the edge is not.
        const need_w = w +| self.padding;
        const need_h = h +| self.padding;
        // A distinct answer from `AtlasFull`: this will not fit in a *fresh* atlas of this
        // size either, so the caller must do something other than retry.
        if (w > self.size.width or h > self.size.height) return error.RegionTooLarge;

        // Best fit by height: the shelf that wastes the least. Ties go to the first, so
        // the packing is a pure function of insertion order (I9).
        // What must fit is the **image**, not its padding: the reserved texels to the
        // right of and below the last thing on a shelf are never written, so an image
        // flush against the far edge is legal. Checking the padded size here instead
        // would refuse an image exactly as large as the atlas, which is the one size a
        // caller is most likely to have chosen on purpose.
        var best: ?usize = null;
        var best_waste: u32 = std.math.maxInt(u32);
        for (self.shelves.items, 0..) |shelf, i| {
            if (shelf.height < need_h) continue;
            if (shelf.cursor + w > self.size.width) continue;
            const waste = shelf.height - need_h;
            if (waste < best_waste) {
                best = i;
                best_waste = waste;
            }
        }

        const shelf = if (best) |i| &self.shelves.items[i] else blk: {
            if (self.used_height + h > self.size.height) return error.AtlasFull;
            try self.shelves.append(gpa, .{ .y = self.used_height, .height = need_h, .cursor = 0 });
            // Advanced by the padded height, so the next shelf starts clear of this one.
            // It may now sit one texel past the bottom edge, which is exactly the case the
            // check above is written to reject on the next call rather than this one.
            self.used_height +|= need_h;
            break :blk &self.shelves.items[self.shelves.items.len - 1];
        };

        const placement: Placement = .{ .x = shelf.cursor, .y = shelf.y };
        shelf.cursor += need_w;
        self.used_area += @as(u64, w) * h;
        return placement;
    }

    /// The fraction of the atlas the images occupy, padding and offcuts excluded.
    ///
    /// A diagnostic, not a decision input: it is the number that tells you an atlas is the
    /// wrong size, and `Stats` is where it is meant to end up.
    pub fn fill(self: *const Packer) f32 {
        const total = @as(u64, self.size.width) * self.size.height;
        if (total == 0) return 0;
        return @as(f32, @floatFromInt(self.used_area)) / @as(f32, @floatFromInt(total));
    }
};

const testing = std.testing;

test "a whole texture is a region, and slicing it gives the cells of a sheet" {
    const handle: TextureHandle = .none;
    const sheet: Region = .whole(handle, .{ .width = 64, .height = 64 });

    try testing.expectEqual(@as(f32, 1), sheet.uv.w);

    // A 4x4 grid of 16-pixel cells. Cell (1, 2) is a quarter across and half down.
    const cell = sheet.sub(16, 32, 16, 16);
    try testing.expectApproxEqAbs(@as(f32, 0.25), cell.uv.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), cell.uv.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), cell.uv.w, 1e-6);
    try testing.expectEqual(@as(u32, 16), cell.size_px.width);
}

test "slicing is relative, so a region in an atlas cuts up the same way" {
    // The property that lets a font move into a shared atlas without its code changing:
    // the same `sub` call on a region that is a quarter of a texture yields a cell in the
    // same place *within the region*, at a quarter of the UV size.
    const standalone: Region = .whole(.none, .{ .width = 64, .height = 64 });
    const packed_in: Region = .{
        .texture = .none,
        .uv = .{ .x = 0.5, .y = 0.25, .w = 0.25, .h = 0.25 },
        .size_px = .{ .width = 64, .height = 64 },
    };

    const a = standalone.sub(16, 32, 16, 16);
    const b = packed_in.sub(16, 32, 16, 16);

    try testing.expectEqual(a.size_px.width, b.size_px.width);
    try testing.expectApproxEqAbs(a.uv.w * 0.25, b.uv.w, 1e-6);
    try testing.expectApproxEqAbs(0.5 + 0.25 * 0.25, b.uv.x, 1e-6);
    try testing.expectApproxEqAbs(0.25 + 0.25 * 0.5, b.uv.y, 1e-6);
}

test "a sub-rectangle past the edge is clamped, not wrapped onto a neighbour" {
    // In an atlas the texels past a region's edge belong to somebody else's sprite, so
    // reading them is not a harmless overrun — it draws the wrong picture.
    const region: Region = .whole(.none, .{ .width = 32, .height = 32 });

    const overhang = region.sub(24, 24, 16, 16);
    try testing.expectEqual(@as(u32, 8), overhang.size_px.width);
    try testing.expectEqual(@as(u32, 8), overhang.size_px.height);

    const outside = region.sub(64, 64, 8, 8);
    try testing.expect(outside.size_px.isEmpty());
}

test "a grid cut names cells row-major, and cell zero is the top-left" {
    const sheet: Region = .whole(.none, .{ .width = 64, .height = 64 });

    const first = sheet.cell(4, 4, 0);
    try testing.expectApproxEqAbs(@as(f32, 0), first.uv.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), first.uv.y, 1e-6);
    try testing.expectEqual(@as(u32, 16), first.size_px.width);
    try testing.expectEqual(@as(u32, 16), first.size_px.height);

    // Row-major: index 5 is column 1 of row 1, not column 1 of row 0 read down.
    const fifth = sheet.cell(4, 4, 5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), fifth.uv.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), fifth.uv.y, 1e-6);

    // The same cell reached the long way, to pin the arithmetic to `sub` rather than to
    // itself.
    try testing.expectApproxEqAbs(sheet.sub(16, 16, 16, 16).uv.x, fifth.uv.x, 1e-6);
    try testing.expectApproxEqAbs(sheet.sub(16, 16, 16, 16).uv.y, fifth.uv.y, 1e-6);

    const last = sheet.cell(4, 4, 15);
    try testing.expectApproxEqAbs(@as(f32, 0.75), last.uv.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), last.uv.y, 1e-6);
}

test "a grid cut of a region in an atlas gives the same cells as one on its own texture" {
    // The `sub` property, restated for `cell`, because this is the call a sprite sheet
    // actually makes and it is the one that has to survive being packed.
    const standalone: Region = .whole(.none, .{ .width = 64, .height = 64 });
    const packed_in: Region = .{
        .texture = .none,
        .uv = .{ .x = 0.5, .y = 0.25, .w = 0.25, .h = 0.25 },
        .size_px = .{ .width = 64, .height = 64 },
    };

    for (0..16) |i| {
        const index: u32 = @intCast(i);
        const a = standalone.cell(4, 4, index);
        const b = packed_in.cell(4, 4, index);
        try testing.expectEqual(a.size_px.width, b.size_px.width);
        try testing.expectEqual(a.size_px.height, b.size_px.height);
        // The atlas region occupies a quarter of the texture in each axis, so every cell
        // is a quarter the size and offset to where the region begins.
        try testing.expectApproxEqAbs(a.uv.w * 0.25, b.uv.w, 1e-6);
        try testing.expectApproxEqAbs(0.5 + a.uv.x * 0.25, b.uv.x, 1e-6);
        try testing.expectApproxEqAbs(0.25 + a.uv.y * 0.25, b.uv.y, 1e-6);
    }
}

test "an out-of-range grid cut is empty rather than a neighbour" {
    const sheet: Region = .whole(.none, .{ .width = 64, .height = 64 });

    // One past the last cell of a 4x4 grid. A clip whose `first + count` runs off the end
    // of its sheet reaches exactly this.
    try testing.expect(sheet.cell(4, 4, 16).size_px.isEmpty());
    try testing.expect(sheet.cell(4, 4, 999).size_px.isEmpty());

    // Both grid dimensions come from a file, so both can be zero, and neither may divide.
    try testing.expect(sheet.cell(0, 4, 0).size_px.isEmpty());
    try testing.expect(sheet.cell(4, 0, 0).size_px.isEmpty());

    // The widened bound: `columns * rows` overflows a u32 here, and the last cell of a
    // grid that large is still out of range for any u32 index.
    try testing.expect(sheet.cell(65_536, 65_536, 4_294_967_295).size_px.isEmpty());

    // A region too small to divide yields empty cells rather than zero-width slivers of
    // the wrong place.
    const tiny: Region = .whole(.none, .{ .width = 2, .height = 2 });
    try testing.expect(tiny.cell(4, 4, 0).size_px.isEmpty());
}

test "a sheet whose pixels do not divide evenly leaves the remainder unused" {
    // 30 / 4 is 7, so the grid covers 28 pixels and the last two are not in any cell.
    // Stated as a test because the alternative — cells of two different sizes — is the
    // kind of thing a future session might add as a "fix".
    const sheet: Region = .whole(.none, .{ .width = 30, .height = 30 });

    const last = sheet.cell(4, 4, 15);
    try testing.expectEqual(@as(u32, 7), last.size_px.width);
    try testing.expectEqual(@as(u32, 7), last.size_px.height);
    try testing.expectApproxEqAbs(@as(f32, 21.0 / 30.0), last.uv.x, 1e-6);
}

test "same-height images pack into full rows" {
    var packer: Packer = .init(.{ .width = 64, .height = 64 }, 0);
    defer packer.deinit(testing.allocator);

    // Four 16-wide images fill one row of a 64-wide atlas exactly.
    for (0..4) |i| {
        const p = try packer.add(testing.allocator, 16, 16);
        try testing.expectEqual(@as(u32, @intCast(i * 16)), p.x);
        try testing.expectEqual(@as(u32, 0), p.y);
    }
    // The fifth starts a second shelf rather than overflowing the first.
    const fifth = try packer.add(testing.allocator, 16, 16);
    try testing.expectEqual(@as(u32, 0), fifth.x);
    try testing.expectEqual(@as(u32, 16), fifth.y);

    try testing.expectApproxEqAbs(@as(f32, 5 * 256) / (64 * 64), packer.fill(), 1e-6);
}

test "padding is reserved between neighbours, and never off the edge" {
    var packer: Packer = .init(.{ .width = 64, .height = 64 }, 1);
    defer packer.deinit(testing.allocator);

    const first = try packer.add(testing.allocator, 16, 16);
    const second = try packer.add(testing.allocator, 16, 16);
    // One texel of daylight between them, which is what stops one bleeding into the other.
    try testing.expectEqual(@as(u32, 0), first.x);
    try testing.expectEqual(@as(u32, 17), second.x);

    // An image exactly as wide as the atlas still fits: the padding beyond the last image
    // on a shelf is never written, so it does not have to be inside the texture.
    var tight: Packer = .init(.{ .width = 64, .height = 64 }, 1);
    defer tight.deinit(testing.allocator);
    _ = try tight.add(testing.allocator, 64, 64);
}

test "best fit puts an image on the shelf that wastes the least" {
    var packer: Packer = .init(.{ .width = 64, .height = 64 }, 0);
    defer packer.deinit(testing.allocator);

    // Two shelves, 20 tall and 8 tall. The second image is too wide to join the first
    // shelf, which is what makes a second one exist at all — an 8-tall image that fits
    // beside a 20-tall one belongs beside it, and best fit says so.
    _ = try packer.add(testing.allocator, 40, 20);
    _ = try packer.add(testing.allocator, 40, 8);

    // A 7-tall image fits both shelves. It belongs on the 8-tall one, which wastes one
    // row rather than thirteen: sorting was not available here, and this is the
    // incremental equivalent of it.
    const placed = try packer.add(testing.allocator, 10, 7);
    try testing.expectEqual(@as(u32, 20), placed.y);
}

test "a full atlas and an oversized image are different answers" {
    var packer: Packer = .init(.{ .width = 32, .height = 32 }, 0);
    defer packer.deinit(testing.allocator);

    _ = try packer.add(testing.allocator, 32, 32);
    // Full: another atlas of the same size would take this.
    try testing.expectError(error.AtlasFull, packer.add(testing.allocator, 8, 8));

    var fresh: Packer = .init(.{ .width = 32, .height = 32 }, 0);
    defer fresh.deinit(testing.allocator);
    // Too large: another atlas of the same size would *not*, so a caller that retried the
    // same way for both would allocate atlases until it ran out of memory.
    try testing.expectError(error.RegionTooLarge, fresh.add(testing.allocator, 64, 8));
    try testing.expectError(error.RegionTooLarge, fresh.add(testing.allocator, 0, 8));
}

test "packing is a pure function of insertion order" {
    // I9. Two packers given the same images in the same order agree exactly, which is
    // what makes an atlas's UVs reproducible across runs — and therefore what makes a
    // screenshot comparison mean something.
    const sizes = [_][2]u32{ .{ 13, 7 }, .{ 5, 21 }, .{ 30, 7 }, .{ 8, 8 }, .{ 2, 21 } };

    var a: Packer = .init(.{ .width = 64, .height = 64 }, 1);
    defer a.deinit(testing.allocator);
    var b: Packer = .init(.{ .width = 64, .height = 64 }, 1);
    defer b.deinit(testing.allocator);

    for (sizes) |s| {
        const pa = try a.add(testing.allocator, s[0], s[1]);
        const pb = try b.add(testing.allocator, s[0], s[1]);
        try testing.expectEqual(pa.x, pb.x);
        try testing.expectEqual(pa.y, pb.y);
    }
    try testing.expectEqual(a.used_area, b.used_area);
}

test "no two packed images overlap" {
    // The property the whole type exists for, checked against the placements themselves
    // rather than against the algorithm's reasoning about them.
    var rng: core.rng.Pcg32 = .init(0xA71A5, 1);
    var packer: Packer = .init(.{ .width = 128, .height = 128 }, 1);
    defer packer.deinit(testing.allocator);

    const Placed = struct { x: u32, y: u32, w: u32, h: u32 };
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(testing.allocator);

    for (0..200) |_| {
        const w = 1 + rng.below(24);
        const h = 1 + rng.below(24);
        const p = packer.add(testing.allocator, w, h) catch |err| switch (err) {
            error.AtlasFull => break,
            else => return err,
        };
        for (placed.items) |other| {
            const disjoint = p.x + w <= other.x or other.x + other.w <= p.x or
                p.y + h <= other.y or other.y + other.h <= p.y;
            try testing.expect(disjoint);
        }
        // And inside the atlas, which is what makes the copy legal under rule 10.
        try testing.expect(p.x + w <= packer.size.width and p.y + h <= packer.size.height);
        try placed.append(testing.allocator, .{ .x = p.x, .y = p.y, .w = w, .h = h });
    }
    try testing.expect(placed.items.len > 20);
}
