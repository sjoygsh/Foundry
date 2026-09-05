//! Drawing a grid of tile ids as ordinary sprites.
//!
//! A tilemap is a great many sprites that happen to be arranged regularly, and this file is
//! the whole of that idea. There is no tilemap renderer, no chunk cache, no persistent
//! vertex buffer and no dirty-rectangle tracking: `Tiles` turns a visible rectangle into a
//! run of `Sprite`s and the existing batcher does the rest, so a layer is one texture at one
//! sort layer and therefore **one batch**.
//!
//! That restraint is a decision rather than an omission (`tilemaps-and-collision.md` §10). A
//! screen of 16-unit tiles is on the order of 40x25 cells; four layers of that is four
//! thousand quads, and M2 measured 4,185 quads at vsync in four batches. The trigger for
//! caching is stated so it is not a matter of taste: a tilemap draw showing up in the frame
//! profiler M6 builds, at the layer counts a real map uses. None of it would change the
//! interface here.
//!
//! **Culling is the part that is not optional**, because it is the difference between
//! drawing what is visible and drawing the map. `Tiles.init` intersects the layer with the
//! view's own rectangle first and never looks at a cell outside it.
//!
//! **Nothing here knows what content is.** A `TilemapLayer` is a region, a slice of ids and
//! two vectors; `asset` reads the records and the game fills this in (§11). A map generated
//! at runtime with no content package at all draws through exactly this path.

const std = @import("std");
const core = @import("core");

const atlas_mod = @import("atlas.zig");
const color_mod = @import("color.zig");
const sprite_mod = @import("sprite.zig");
const texture_mod = @import("texture.zig");

const BlendMode = color_mod.BlendMode;
const Color = color_mod.Color;
const Extent2D = texture_mod.Extent2D;
const Rect = core.math.Rect;
const Region = atlas_mod.Region;
const Sprite = sprite_mod.Sprite;
const Vec2 = core.math.Vec2;

pub const Error = error{
    /// A layer whose dimensions, cell size, origin or tile sheet cannot be drawn.
    ///
    /// Every field of a `TilemapLayer` can come from a content file and, from M7, from a
    /// mod, so this is refused and reported rather than asserted (CLAUDE.md §7). What it
    /// does *not* cover is a tile id the sheet does not have: that is per cell, in a loop,
    /// and one bad id in ten thousand draws nothing rather than failing the frame.
    InvalidTilemap,
};

/// One drawable plane of a map.
///
/// This crosses the game-facing boundary (CLAUDE.md §4.2), so its shape is a compatibility
/// decision rather than a style one. Everything with a sensible default has one, which is
/// why the simplest layer names six fields.
pub const TilemapLayer = struct {
    /// The tile sheet. A `Region` rather than a `TextureHandle`, so a tileset packed into a
    /// shared atlas and a tileset on its own are the same call — the same reason a font's
    /// glyphs are a region.
    tiles: Region,
    /// One tile's size in `tiles`' **own** pixel space, which `Region.sub` cuts in.
    tile_size: Extent2D,
    /// Tiles per row in the sheet. Rows are derived from the region's height, because a
    /// sheet that disagrees with itself about its height is a sheet, and one that disagrees
    /// about its width is a typo worth reporting.
    columns: u32,

    /// The grid, row-major, **bottom row first** — the order `asset.tilegrid` stores and
    /// the order world Y grows in. Borrowed: this never owns it and never outlives it.
    map: []const u16,
    width: u32,
    height: u32,

    /// Where cell `(0, 0)`'s minimum corner sits, in the view's space.
    origin: Vec2 = .zero,
    /// One cell's size in that space. Not tied to `tile_size`: how big a tile is drawn and
    /// how many pixels its art has are different questions, and a map is not obliged to
    /// answer them the same way.
    cell: Vec2,

    /// The tile id that means "nothing here", or null when every id draws.
    ///
    /// Null by default because the bottom layer of a map covers the ground, and a default
    /// that punched holes in it would be surprising. A layer drawn *over* another one sets
    /// this, and says so in content rather than in code — `foundry:tilemap.layer` carries
    /// the field.
    empty: ?u16 = null,

    tint: Color = .white,
    /// Draw order, the same key `Sprite.layer` uses. `foundry:tilemap.layer.order` is this.
    layer: i16 = 0,
    blend: BlendMode = .alpha,
};

/// The visible cells of one layer, as sprites.
///
/// Public for the same reason `text.Layout` is: the culled span is worth having without
/// drawing — a debug overlay counting visible tiles, or a game that wants to draw them some
/// other way — and a renderer that hid it would be hiding the only interesting part.
///
/// **Row-major, bottom row first.** Order is interface, not incidental: the batcher breaks
/// ties on submission order, so two tiles in one cell of two layers stack the way the
/// layers say and never the way an iteration happened to run (I9).
pub const Tiles = struct {
    layer: TilemapLayer,
    /// Tile rows in the sheet, derived from the region.
    sheet_tiles: u32,
    /// The visible span, in cells, inclusive at both ends.
    x0: u32,
    y0: u32,
    columns: u32,
    /// How many cells the span holds. Zero when nothing of the layer is on screen.
    count: u64,
    cursor: u64 = 0,

    /// Culls `layer` to `visible` — a rectangle in the same space `layer.origin` is in.
    ///
    /// A layer entirely off screen is not an error; it yields nothing. What is refused is a
    /// layer that could not be drawn wherever it was put.
    pub fn init(layer: TilemapLayer, visible: Rect) Error!Tiles {
        if (layer.width == 0 or layer.height == 0) return error.InvalidTilemap;
        if (@as(u64, layer.width) * layer.height != layer.map.len) return error.InvalidTilemap;
        if (layer.columns == 0 or layer.tile_size.isEmpty()) return error.InvalidTilemap;
        if (layer.tiles.size_px.isEmpty()) return error.InvalidTilemap;
        // A sheet narrower than the columns claimed would have `Region.sub` quietly clamp
        // every tile in the last column onto its neighbour's pixels. Said out loud instead.
        if (@as(u64, layer.columns) * layer.tile_size.width > layer.tiles.size_px.width) {
            return error.InvalidTilemap;
        }
        const rows = layer.tiles.size_px.height / layer.tile_size.height;
        if (rows == 0) return error.InvalidTilemap;

        if (!finite(layer.origin) or !finite(layer.cell)) return error.InvalidTilemap;
        if (!(layer.cell.x > 0) or !(layer.cell.y > 0)) return error.InvalidTilemap;
        // The view's rectangle comes from a camera that was validated when it was resolved,
        // so this is belt and braces — but the alternative to checking is `@intFromFloat`
        // on a NaN, which is illegal behaviour rather than a wrong picture.
        if (!std.math.isFinite(visible.x) or !std.math.isFinite(visible.y)) {
            return error.InvalidTilemap;
        }
        if (!std.math.isFinite(visible.w) or !std.math.isFinite(visible.h)) {
            return error.InvalidTilemap;
        }

        const empty: Tiles = .{
            .layer = layer,
            .sheet_tiles = layer.columns * rows,
            .x0 = 0,
            .y0 = 0,
            .columns = 0,
            .count = 0,
        };
        if (visible.isEmpty()) return empty;

        const xs = span(visible.x, visible.x + visible.w, layer.origin.x, layer.cell.x, layer.width) orelse
            return empty;
        const ys = span(visible.y, visible.y + visible.h, layer.origin.y, layer.cell.y, layer.height) orelse
            return empty;

        const wide = xs[1] - xs[0] + 1;
        const tall = ys[1] - ys[0] + 1;
        return .{
            .layer = layer,
            .sheet_tiles = layer.columns * rows,
            .x0 = xs[0],
            .y0 = ys[0],
            .columns = wide,
            .count = @as(u64, wide) * tall,
        };
    }

    /// The next visible, non-empty, drawable cell. Null when the span is exhausted.
    pub fn next(self: *Tiles) ?Sprite {
        while (self.cursor < self.count) {
            const at = self.cursor;
            self.cursor += 1;

            const cx = self.x0 + @as(u32, @intCast(at % self.columns));
            const cy = self.y0 + @as(u32, @intCast(at / self.columns));
            const id = self.layer.map[@as(usize, cy) * self.layer.width + cx];

            if (self.layer.empty) |hole| {
                if (id == hole) continue;
            }
            // A map naming a tile its sheet does not have. Content, so it draws nothing
            // rather than sampling whatever is at the clamped edge of the region.
            if (id >= self.sheet_tiles) continue;

            const tw = self.layer.tile_size.width;
            const th = self.layer.tile_size.height;
            const region = self.layer.tiles.sub((id % self.layer.columns) * tw, (id / self.layer.columns) * th, tw, th);

            return .{
                .texture = region.texture,
                .position = .{
                    .x = self.layer.origin.x + @as(f32, @floatFromInt(cx)) * self.layer.cell.x,
                    .y = self.layer.origin.y + @as(f32, @floatFromInt(cy)) * self.layer.cell.y,
                },
                .size = self.layer.cell,
                .uv = region.uv,
                // The corner nearest the space's own origin, which is what `origin` means
                // (`sprite.writeQuad`). In a Y-up space that is the cell's bottom-left and
                // rows climb; in a Y-down one it is the top-left and rows descend. Cells
                // advance along the space's `+y` either way, exactly as a sprite's position
                // does, rather than the tilemap inventing a second rule for itself.
                .origin = .{ .x = 0, .y = 0 },
                .tint = self.layer.tint,
                .layer = self.layer.layer,
                .blend = self.layer.blend,
            };
        }
        return null;
    }
};

fn finite(v: Vec2) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y);
}

/// The inclusive cell range the half-open interval `[lo, hi)` covers, clamped to
/// `[0, count)`, or null for none.
///
/// **Half-open, matching `Rect.overlaps`.** A view whose right edge lands exactly on a cell
/// boundary does not see the cell beyond it, and the `@ceil` is what says so — with `@floor`
/// on both ends a screen-sized view would draw one extra column and one extra row forever,
/// which is a bug that never looks like one.
///
/// Every value reaching this is finite and `cell` is positive, both checked by the caller,
/// so the clamp happens **before** any conversion to an integer and an absurd rectangle
/// yields an empty span rather than illegal behaviour.
fn span(lo: f32, hi: f32, origin: f32, cell: f32, count: u32) ?[2]u32 {
    const limit: f32 = @floatFromInt(count);
    const first = @floor((lo - origin) / cell);
    const last = @ceil((hi - origin) / cell) - 1;
    if (!(last >= 0) or !(first < limit)) return null;

    const a = @max(first, 0);
    const b = @min(last, limit - 1);
    if (b < a) return null;
    return .{ @intFromFloat(a), @intFromFloat(b) };
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

/// A 4x4 sheet of 16-pixel tiles, and a map of `w * h` cells filled with `fill`.
fn layerOf(map: []const u16, w: u32, h: u32) TilemapLayer {
    return .{
        .tiles = .whole(.none, .{ .width = 64, .height = 64 }),
        .tile_size = .{ .width = 16, .height = 16 },
        .columns = 4,
        .map = map,
        .width = w,
        .height = h,
        .cell = .init(16, 16),
    };
}

fn drain(tiles: *Tiles, out: []Sprite) usize {
    var n: usize = 0;
    while (tiles.next()) |s| : (n += 1) {
        if (n < out.len) out[n] = s;
    }
    return n;
}

test "only the cells the view can see are drawn" {
    // The whole point of the file. A hundred by a hundred is ten thousand cells; a view
    // showing three by two must cost six sprites, not ten thousand.
    const map = [_]u16{1} ** (100 * 100);
    var tiles: Tiles = try .init(layerOf(&map, 100, 100), .init(0, 0, 48, 32));

    var seen: [16]Sprite = undefined;
    try testing.expectEqual(@as(usize, 6), drain(&tiles, &seen));
}

test "a cell lands where the grid puts it, with rows climbing +y" {
    const map = [_]u16{0} ** (4 * 4);
    var tiles: Tiles = try .init(.{
        .tiles = .whole(.none, .{ .width = 64, .height = 64 }),
        .tile_size = .{ .width = 16, .height = 16 },
        .columns = 4,
        .map = &map,
        .width = 4,
        .height = 4,
        .origin = .init(-32, -32),
        .cell = .init(16, 16),
    }, .init(-100, -100, 200, 200));

    var seen: [32]Sprite = undefined;
    try testing.expectEqual(@as(usize, 16), drain(&tiles, &seen));

    // Row-major from the bottom row: cell (0,0) is the map's minimum corner, and the fifth
    // sprite is the start of the row above it.
    try testing.expectEqual(@as(f32, -32), seen[0].position.x);
    try testing.expectEqual(@as(f32, -32), seen[0].position.y);
    try testing.expectEqual(@as(f32, -16), seen[1].position.x);
    try testing.expectEqual(@as(f32, -32), seen[1].position.y);
    try testing.expectEqual(@as(f32, -32), seen[4].position.x);
    try testing.expectEqual(@as(f32, -16), seen[4].position.y);
    // Placed by its minimum corner, so the quad occupies exactly one cell.
    try testing.expectEqual(@as(f32, 0), seen[0].origin.x);
    try testing.expectEqual(@as(f32, 0), seen[0].origin.y);
    try testing.expectEqual(@as(f32, 16), seen[0].size.x);
}

test "a view that has moved off the map draws nothing rather than clamping onto it" {
    const map = [_]u16{1} ** (4 * 4);
    const layer = layerOf(&map, 4, 4);

    var away: Tiles = try .init(layer, .init(1000, 1000, 100, 100));
    try testing.expectEqual(@as(?Sprite, null), away.next());

    var before: Tiles = try .init(layer, .init(-1000, -1000, 100, 100));
    try testing.expectEqual(@as(?Sprite, null), before.next());

    // Straddling the edge is the case that would read out of bounds if the clamp were
    // missing: the visible rectangle starts well below the map and ends inside it.
    var over: Tiles = try .init(layer, .init(-1000, -1000, 1032, 1032));
    var seen: [32]Sprite = undefined;
    try testing.expectEqual(@as(usize, 4), drain(&over, &seen));
    try testing.expectEqual(@as(f32, 0), seen[0].position.x);
}

test "an empty id punches a hole and every other id draws" {
    const map = [_]u16{ 0, 1, 0, 2 };
    var layer = layerOf(&map, 2, 2);
    const view: core.math.Rect = .init(0, 0, 32, 32);

    var all: Tiles = try .init(layer, view);
    var seen: [8]Sprite = undefined;
    try testing.expectEqual(@as(usize, 4), drain(&all, &seen));

    // The default draws every id, because the bottom layer of a map covers the ground.
    layer.empty = 0;
    var holed: Tiles = try .init(layer, view);
    try testing.expectEqual(@as(usize, 2), drain(&holed, &seen));
    try testing.expectEqual(@as(f32, 16), seen[0].position.x);
    try testing.expectEqual(@as(f32, 16), seen[1].position.y);
}

test "a tile the sheet does not have draws nothing" {
    // Content, and therefore untrusted: one bad id in a map is a missing tile, not a
    // failed frame — and specifically not a region clamped onto a neighbour's pixels.
    const map = [_]u16{ 0, 15, 16, 60000 };
    var tiles: Tiles = try .init(layerOf(&map, 2, 2), .init(0, 0, 32, 32));

    var seen: [8]Sprite = undefined;
    try testing.expectEqual(@as(usize, 2), drain(&tiles, &seen));
}

test "a tile id cuts the sheet cell it names" {
    const map = [_]u16{5};
    var tiles: Tiles = try .init(layerOf(&map, 1, 1), .init(0, 0, 16, 16));

    // Id 5 in a four-column sheet is column 1, row 1, and the sheet is 64 pixels square.
    const sprite = tiles.next().?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), sprite.uv.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), sprite.uv.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), sprite.uv.w, 1e-6);
}

test "one layer is one sort key, which is what makes it one batch" {
    const map = [_]u16{ 0, 1, 2, 3 };
    var layer = layerOf(&map, 2, 2);
    layer.layer = -10;
    layer.tint = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
    var tiles: Tiles = try .init(layer, .init(0, 0, 32, 32));

    while (tiles.next()) |s| {
        try testing.expectEqual(@as(i16, -10), s.layer);
        try testing.expectEqual(@as(f32, 0), s.tint.g);
    }
}

test "a layer that could not be drawn is refused rather than asserted" {
    // Every one of these arrives from a content file, and from M7 from a mod.
    const map = [_]u16{ 0, 1, 2, 3 };
    const view: core.math.Rect = .init(0, 0, 32, 32);

    var bad = layerOf(&map, 2, 2);
    bad.width = 3; // says twelve cells, carries four
    try testing.expectError(error.InvalidTilemap, Tiles.init(bad, view));

    bad = layerOf(&map, 2, 2);
    bad.height = 0;
    try testing.expectError(error.InvalidTilemap, Tiles.init(bad, view));

    bad = layerOf(&map, 2, 2);
    bad.cell = .init(0, 16);
    try testing.expectError(error.InvalidTilemap, Tiles.init(bad, view));

    bad = layerOf(&map, 2, 2);
    bad.origin = .init(std.math.nan(f32), 0);
    try testing.expectError(error.InvalidTilemap, Tiles.init(bad, view));

    bad = layerOf(&map, 2, 2);
    bad.columns = 0;
    try testing.expectError(error.InvalidTilemap, Tiles.init(bad, view));

    // Five columns of 16 pixels do not fit in a 64-pixel sheet, and the last one would
    // silently become the first one again.
    bad = layerOf(&map, 2, 2);
    bad.columns = 5;
    try testing.expectError(error.InvalidTilemap, Tiles.init(bad, view));

    bad = layerOf(&map, 2, 2);
    bad.tile_size = .{ .width = 16, .height = 0 };
    try testing.expectError(error.InvalidTilemap, Tiles.init(bad, view));

    bad = layerOf(&map, 2, 2);
    bad.tiles = .whole(.none, .{});
    try testing.expectError(error.InvalidTilemap, Tiles.init(bad, view));

    // And a view rectangle that is not a rectangle, which would otherwise reach
    // `@intFromFloat` with a NaN.
    try testing.expectError(
        error.InvalidTilemap,
        Tiles.init(layerOf(&map, 2, 2), .init(0, 0, std.math.nan(f32), 32)),
    );
    // An empty one is not an error; there is simply nothing on screen.
    var none: Tiles = try .init(layerOf(&map, 2, 2), .init(0, 0, 0, 32));
    try testing.expectEqual(@as(?Sprite, null), none.next());
}

test "a cell larger than the view still draws the cell the view is inside" {
    // The zoomed-in case, which an off-by-one in the span turns into an empty screen.
    const map = [_]u16{ 0, 1, 2, 3 };
    var layer = layerOf(&map, 2, 2);
    layer.cell = .init(1000, 1000);

    var tiles: Tiles = try .init(layer, .init(1200, 1300, 10, 10));
    const sprite = tiles.next().?;
    try testing.expectEqual(@as(f32, 1000), sprite.position.x);
    try testing.expectEqual(@as(f32, 1000), sprite.position.y);
    try testing.expectEqual(@as(?Sprite, null), tiles.next());
}
