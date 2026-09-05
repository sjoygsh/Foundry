//! The tile grid: static geometry that knows it is a grid.
//!
//! **A grid is a shape source, not a body**, and it does not enter the broadphase. Sweeping
//! against it is a bounded walk over the cells the sweep's bounds cover, which costs the same
//! for a 20x20 map as for a 2000x2000 one. That is the whole reason ADR-0022 made it
//! first-class instead of generating a static body per solid tile: the latter is correct, and
//! it is also ten thousand broadphase entries and a rebuild every time one tile changes.
//!
//! It is also what makes the **internal-edge** fix exact. A box sliding along a wall built
//! from adjacent solid tiles snags on the seam between two tiles that are each individually
//! right: the sweep finds a face on the next tile that the box is already past, and reports a
//! normal pointing back the way it came. The answer here is neighbour-aware face culling — a
//! face is ignored when the neighbouring cell in that direction is also solid, because that
//! face is interior to the wall and cannot legitimately be hit. Four bit tests per cell, no
//! preprocessing, and exact rather than a tolerance. **A pile of boxes cannot do this**, because
//! a box does not know its neighbours.
//!
//! Design: `docs/design/tilemaps-and-collision.md` §4.

const std = @import("std");
const core = @import("core");

const shape_mod = @import("shape.zig");

const Bounds = shape_mod.Bounds;
const Contact = shape_mod.Contact;
const Face = shape_mod.Face;
const FaceMask = shape_mod.FaceMask;
const Rounded = shape_mod.Rounded;
const Vec2 = core.math.Vec2;

/// Phantom tag for `GridHandle`. Never instantiated (I1).
pub const Grids = opaque {};

pub const GridHandle = core.Handle(Grids);

pub const GridError = error{
    /// The grid's dimensions and its tile array disagree, or a size is not usable. Content
    /// arrives from files, so this is reported rather than asserted (CLAUDE.md §7).
    InvalidGrid,
};

pub const Grid = struct {
    /// World position of cell (0,0)'s lower-left corner.
    origin: Vec2,
    /// Cell size. Non-square is legal.
    cell: Vec2,
    width: u32,
    height: u32,
    /// Row-major, `width * height` long. **Borrowed; the world does not own this.**
    tiles: []const u16,
    /// A bitset over tile **ids**, not over cells — so it is the size of the tileset (tens of
    /// bytes) rather than the size of the map, and hot-reloading a tileset's collision data
    /// changes one small array instead of rebuilding the world. **Borrowed.**
    solid: []const u32,

    /// Whether this grid is one the module can walk.
    ///
    /// Called by `World.addGrid`, so nothing below has to defend against a malformed one. The
    /// borrowed slices are the caller's to keep alive; that part cannot be checked here and is
    /// stated in `World.addGrid` instead.
    pub fn validate(self: Grid) GridError!void {
        if (self.width == 0 or self.height == 0) return error.InvalidGrid;
        const expected = @as(u64, self.width) * @as(u64, self.height);
        if (self.tiles.len != expected) return error.InvalidGrid;
        if (!(self.cell.x > 0) or !(self.cell.y > 0)) return error.InvalidGrid;
        if (!std.math.isFinite(self.cell.x) or !std.math.isFinite(self.cell.y)) return error.InvalidGrid;
        if (!std.math.isFinite(self.origin.x) or !std.math.isFinite(self.origin.y)) return error.InvalidGrid;
    }

    /// The tile id at a cell, or null when the cell is outside the grid.
    ///
    /// Signed coordinates because neighbour lookups walk off the edge by construction, and an
    /// unsigned subtraction at the boundary is how that becomes a wrapped index into the
    /// middle of the map.
    pub fn tileAt(self: Grid, x: i64, y: i64) ?u16 {
        if (x < 0 or y < 0) return null;
        if (x >= self.width or y >= self.height) return null;
        const index = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        return self.tiles[index];
    }

    /// Whether a tile id is solid.
    ///
    /// A bitset shorter than the tileset means the tiles past its end are **not** solid, rather
    /// than an out-of-bounds read. Tolerant on purpose: `solid` comes from content that may
    /// predate a tile being added.
    pub fn isSolidTile(self: Grid, tile: u16) bool {
        const word = tile >> 5;
        if (word >= self.solid.len) return false;
        return self.solid[word] & (@as(u32, 1) << @intCast(tile & 31)) != 0;
    }

    /// Whether a cell is solid.
    ///
    /// **Outside the grid is not solid.** A grid is a shape source rather than a world
    /// boundary: a game that wants a closed map draws a border of solid tiles, which is
    /// content and not engine policy (I5). The alternative would make a grid unusable as a
    /// local patch of geometry — one room, one platform — because everything around it would
    /// be a wall.
    pub fn isSolidAt(self: Grid, x: i64, y: i64) bool {
        return self.isSolidTile(self.tileAt(x, y) orelse return false);
    }

    /// A cell's centre, and the half-extents every cell shares.
    ///
    /// Computed straight from the origin rather than by halving `cellBounds`, because every
    /// test in the module is centre-and-half-extents and a round trip through corners is a
    /// rounding step for nothing.
    pub fn cellCenter(self: Grid, x: u32, y: u32) Vec2 {
        return .{
            .x = self.origin.x + (@as(f32, @floatFromInt(x)) + 0.5) * self.cell.x,
            .y = self.origin.y + (@as(f32, @floatFromInt(y)) + 0.5) * self.cell.y,
        };
    }

    pub fn cellHalf(self: Grid) Vec2 {
        return self.cell.scale(0.5);
    }

    /// A cell as an obstacle: a box with no rounding.
    pub fn cellShape(self: Grid) Rounded {
        return .{ .half = self.cellHalf(), .radius = 0 };
    }

    pub fn cellBounds(self: Grid, x: u32, y: u32) Bounds {
        const min: Vec2 = .{
            .x = self.origin.x + @as(f32, @floatFromInt(x)) * self.cell.x,
            .y = self.origin.y + @as(f32, @floatFromInt(y)) * self.cell.y,
        };
        return .{ .min = min, .max = min.add(self.cell) };
    }

    pub fn bounds(self: Grid) Bounds {
        return .{
            .min = self.origin,
            .max = .{
                .x = self.origin.x + @as(f32, @floatFromInt(self.width)) * self.cell.x,
                .y = self.origin.y + @as(f32, @floatFromInt(self.height)) * self.cell.y,
            },
        };
    }

    /// Which faces of a cell can legitimately be hit.
    ///
    /// The internal-edge fix, and the whole of it. A face whose neighbour is also solid is
    /// interior to the wall.
    pub fn facesAt(self: Grid, x: u32, y: u32) FaceMask {
        const cx: i64 = x;
        const cy: i64 = y;
        return .{
            .neg_x = !self.isSolidAt(cx - 1, cy),
            .pos_x = !self.isSolidAt(cx + 1, cy),
            .neg_y = !self.isSolidAt(cx, cy - 1),
            .pos_y = !self.isSolidAt(cx, cy + 1),
        };
    }

    /// The inclusive range of cells a rectangle covers, clamped to the grid.
    pub fn cellRange(self: Grid, area: Bounds) CellRange {
        const x = self.axisRange(area.min.x, area.max.x, self.origin.x, self.cell.x, self.width);
        const y = self.axisRange(area.min.y, area.max.y, self.origin.y, self.cell.y, self.height);
        if (x == null or y == null) return .empty;
        return .{ .min_x = x.?[0], .max_x = x.?[1], .min_y = y.?[0], .max_y = y.?[1], .is_empty = false };
    }

    fn axisRange(self: Grid, lo: f32, hi: f32, origin: f32, size: f32, count: u32) ?[2]u32 {
        _ = self;
        if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return null;
        const first = @floor((lo - origin) / size);
        const last = @floor((hi - origin) / size);
        const limit: f32 = @floatFromInt(count - 1);
        // Compared in float space before any cast: `@intFromFloat` of a value outside the
        // integer's range is undefined behaviour, and these values came from a game.
        if (last < 0 or first > limit) return null;
        return .{
            @intFromFloat(@max(first, 0)),
            @intFromFloat(@min(last, limit)),
        };
    }

    /// Whether a shape overlaps any solid cell.
    ///
    /// Face culling deliberately does **not** apply: an interior face is irrelevant to the
    /// question of whether something is inside the wall.
    pub fn overlapsShape(self: Grid, mover: Rounded, at: Vec2) bool {
        const range = self.cellRange(Bounds.fromCenter(at, mover.halfExtents()));
        if (range.is_empty) return false;

        const cell_shape = self.cellShape();
        var y = range.min_y;
        while (y <= range.max_y) : (y += 1) {
            var x = range.min_x;
            while (x <= range.max_x) : (x += 1) {
                if (!self.isSolidAt(x, y)) continue;
                const obstacle = mover.sum(cell_shape);
                if (shape_mod.overlapRounded(obstacle, at, self.cellCenter(x, y), .all) != null) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn overlapsBox(self: Grid, half: Vec2, at: Vec2) bool {
        return self.overlapsShape(.{ .half = half }, at);
    }

    /// The deepest way out of the wall, or null when the shape is not in one.
    ///
    /// **Face culling applies here and it is the whole reason this is not a loop the caller
    /// writes.** Pushing out of the middle of a wall along an interior face moves the body
    /// further in; restricting the escape directions to the faces `facesAt` admits is what
    /// makes depenetration against a tile grid converge instead of oscillate.
    ///
    /// Cells are visited in row-major order and a later cell replaces the incumbent only on a
    /// strictly greater depth, so ties resolve to the first cell in that order (§8 rule 2).
    pub fn deepestOverlap(self: Grid, mover: Rounded, at: Vec2) ?GridContact {
        const range = self.cellRange(Bounds.fromCenter(at, mover.halfExtents()));
        if (range.is_empty) return null;

        const cell_shape = self.cellShape();
        var best: ?GridContact = null;
        var y = range.min_y;
        while (y <= range.max_y) : (y += 1) {
            var x = range.min_x;
            while (x <= range.max_x) : (x += 1) {
                if (!self.isSolidAt(x, y)) continue;
                const obstacle = mover.sum(cell_shape);
                const contact = shape_mod.overlapRounded(
                    obstacle,
                    at,
                    self.cellCenter(x, y),
                    self.facesAt(x, y),
                ) orelse continue;
                if (best == null or contact.depth > best.?.depth) {
                    best = .{
                        .cell = .{ x, y },
                        .normal = contact.normal,
                        .depth = contact.depth,
                    };
                }
            }
        }
        return best;
    }

    /// Sweeps a shape against the grid and returns the earliest legitimate contact.
    ///
    /// Cells are visited in **row-major order** and a later cell replaces the incumbent only
    /// on a strictly smaller fraction, so ties resolve to the first cell in that order — which
    /// is I9's "stable and documented iteration order" for this walk (§8 rule 2).
    ///
    /// A cell the shape *began* inside contributes no contact — a sweep cannot resolve a
    /// penetration behind it — but it does set `started_inside`, and the walk carries on. It
    /// carries on because stopping there would let a body overlapping one tile pass through
    /// every tile beyond it; the flag is what `moveAndSlide` reports so that a game can call
    /// `resolveOverlaps`, and the walk is what still stops the body at the next wall.
    pub fn sweepShape(self: Grid, mover: Rounded, from: Vec2, motion: Vec2) GridSweep {
        const start = Bounds.fromCenter(from, mover.halfExtents());
        const range = self.cellRange(start.sweptBy(motion));
        if (range.is_empty) return .{};

        const cell_shape = self.cellShape();
        var result: GridSweep = .{};
        var y = range.min_y;
        while (y <= range.max_y) : (y += 1) {
            var x = range.min_x;
            while (x <= range.max_x) : (x += 1) {
                if (!self.isSolidAt(x, y)) continue;

                // The internal-edge fix travels with the mask: a face whose neighbour is also
                // solid is interior to the wall, so a contact on it is the artefact rather
                // than the geometry, and a rounded corner needs both of its faces.
                const obstacle = mover.sum(cell_shape);
                const hit = shape_mod.sweepRounded(
                    obstacle,
                    from,
                    motion,
                    self.cellCenter(x, y),
                    self.facesAt(x, y),
                ) orelse continue;

                if (hit.startedInside()) {
                    result.started_inside = true;
                    continue;
                }
                if (result.hit == null or hit.fraction < result.hit.?.fraction) {
                    result.hit = .{
                        .cell = .{ x, y },
                        .normal = hit.normal,
                        .fraction = hit.fraction,
                        .face = hit.face,
                    };
                }
            }
        }
        return result;
    }

    pub fn sweepBox(self: Grid, half: Vec2, from: Vec2, motion: Vec2) GridSweep {
        return self.sweepShape(.{ .half = half }, from, motion);
    }
};

pub const CellRange = struct {
    min_x: u32 = 0,
    max_x: u32 = 0,
    min_y: u32 = 0,
    max_y: u32 = 0,
    is_empty: bool = true,

    pub const empty: CellRange = .{};

    pub fn count(self: CellRange) u64 {
        if (self.is_empty) return 0;
        return (@as(u64, self.max_x - self.min_x) + 1) * (@as(u64, self.max_y - self.min_y) + 1);
    }
};

pub const GridHit = struct {
    cell: [2]u32,
    normal: Vec2,
    fraction: f32,
    /// The axis-aligned face entered, or null for a **rounded corner** — which happens only
    /// when the moving shape is a circle. See `Sweep`.
    face: ?Face,
};

/// What a walk of the grid found: the earliest contact, and whether the shape started out
/// already in a wall. The two are independent answers and a caller needs both — the first to
/// stop at, the second to know that stopping will not be enough.
pub const GridSweep = struct {
    hit: ?GridHit = null,
    started_inside: bool = false,
};

/// A resolved penetration into one cell, in the same convention as `Contact`: the normal
/// points out of the cell, and moving the shape by `normal.scale(depth)` separates them.
pub const GridContact = struct {
    cell: [2]u32,
    normal: Vec2,
    depth: f32,
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

fn v(x: f32, y: f32) Vec2 {
    return .{ .x = x, .y = y };
}

/// A grid built from a picture, so a test reads as the map it describes.
///
/// Rows are given **top first**, as they look on screen, and reversed here — world Y is up
/// (`render2d.md` §4) while a picture's first row is its highest.
fn gridOf(comptime rows: []const []const u8, tiles: []u16) Grid {
    const height = rows.len;
    const width = rows[0].len;
    for (rows, 0..) |row, i| {
        std.debug.assert(row.len == width);
        const y = height - 1 - i;
        for (row, 0..) |c, x| {
            tiles[y * width + x] = if (c == '#') 1 else 0;
        }
    }
    return .{
        .origin = .zero,
        .cell = .{ .x = 1, .y = 1 },
        .width = @intCast(width),
        .height = @intCast(height),
        .tiles = tiles[0 .. width * height],
        .solid = &solid_tile_one,
    };
}

/// Tile id 1 is solid, tile id 0 is not.
const solid_tile_one = [_]u32{0b10};

test "a malformed grid is refused rather than trusted" {
    var tiles = [_]u16{ 0, 0, 0, 0 };
    const ok: Grid = .{
        .origin = .zero,
        .cell = .one,
        .width = 2,
        .height = 2,
        .tiles = &tiles,
        .solid = &solid_tile_one,
    };
    try ok.validate();

    var wrong = ok;
    wrong.width = 3;
    try testing.expectError(error.InvalidGrid, wrong.validate());

    var zero_cell = ok;
    zero_cell.cell = .{ .x = 0, .y = 1 };
    try testing.expectError(error.InvalidGrid, zero_cell.validate());

    var nan_origin = ok;
    nan_origin.origin = .{ .x = std.math.nan(f32), .y = 0 };
    try testing.expectError(error.InvalidGrid, nan_origin.validate());

    var empty = ok;
    empty.width = 0;
    empty.tiles = &.{};
    try testing.expectError(error.InvalidGrid, empty.validate());
}

test "outside the grid is not solid" {
    var tiles: [4]u16 = undefined;
    const grid = gridOf(&.{
        "##",
        "##",
    }, &tiles);

    try testing.expect(grid.isSolidAt(0, 0));
    try testing.expect(!grid.isSolidAt(-1, 0));
    try testing.expect(!grid.isSolidAt(0, -1));
    try testing.expect(!grid.isSolidAt(2, 0));
    try testing.expect(!grid.isSolidAt(0, 2));
    // The negative coordinate must not wrap into the middle of the map.
    try testing.expectEqual(@as(?u16, null), grid.tileAt(-1, -1));
}

test "a solid bitset shorter than the tileset leaves the rest passable" {
    var tiles = [_]u16{ 0, 40, 0, 0 };
    const grid: Grid = .{
        .origin = .zero,
        .cell = .one,
        .width = 2,
        .height = 2,
        .tiles = &tiles,
        // One word: tile ids 0..31 only. Tile 40 is past its end.
        .solid = &solid_tile_one,
    };
    try testing.expect(!grid.isSolidTile(40));
    try testing.expect(!grid.isSolidAt(1, 0));
}

test "a cell range clamps to the grid and reports emptiness" {
    var tiles: [16]u16 = undefined;
    const grid = gridOf(&.{
        "....",
        "....",
        "....",
        "....",
    }, &tiles);

    const inside = grid.cellRange(.{ .min = v(1.2, 1.2), .max = v(2.8, 2.8) });
    try testing.expectEqual(@as(u32, 1), inside.min_x);
    try testing.expectEqual(@as(u32, 2), inside.max_x);

    const clamped = grid.cellRange(.{ .min = v(-50, -50), .max = v(50, 50) });
    try testing.expectEqual(@as(u32, 0), clamped.min_x);
    try testing.expectEqual(@as(u32, 3), clamped.max_x);
    try testing.expectEqual(@as(u64, 16), clamped.count());

    try testing.expect(grid.cellRange(.{ .min = v(100, 100), .max = v(200, 200) }).is_empty);
    try testing.expect(grid.cellRange(.{ .min = v(-9, -9), .max = v(-5, -5) }).is_empty);
    // Not merely large: a coordinate that would be undefined behaviour to cast.
    try testing.expect(grid.cellRange(.{
        .min = v(std.math.nan(f32), 0),
        .max = v(1, 1),
    }).is_empty);
}

test "interior faces are culled and boundary faces are not" {
    var tiles: [9]u16 = undefined;
    const grid = gridOf(&.{
        "...",
        "###",
        "...",
    }, &tiles);

    // The middle of a horizontal wall: its left and right faces are interior, its top and
    // bottom faces are the wall's surface.
    const middle = grid.facesAt(1, 1);
    try testing.expect(!middle.neg_x);
    try testing.expect(!middle.pos_x);
    try testing.expect(middle.neg_y);
    try testing.expect(middle.pos_y);

    // The end of the wall keeps the face that points off the end.
    const end = grid.facesAt(0, 1);
    try testing.expect(end.neg_x);
    try testing.expect(!end.pos_x);
}

test "a swept box stops at the first solid cell" {
    var tiles: [16]u16 = undefined;
    const grid = gridOf(&.{
        "...#",
        "...#",
        "...#",
        "...#",
    }, &tiles);

    // A 0.5-radius box at y = 2 travelling right. The wall's left face is at x = 3, so the
    // box's centre stops at 2.5 -- half of a 5-unit journey from x = 0.
    const sweep = grid.sweepBox(v(0.5, 0.5), v(0, 2), v(5, 0));
    const hit = sweep.hit.?;
    try testing.expectEqual(v(-1, 0), hit.normal);
    try testing.expectApproxEqAbs(@as(f32, 0.5), hit.fraction, 1e-6);
    try testing.expectEqual(@as(u32, 3), hit.cell[0]);
    try testing.expect(!sweep.started_inside);
}

test "a sweep through open ground finds nothing" {
    var tiles: [16]u16 = undefined;
    const grid = gridOf(&.{
        "....",
        "....",
        "....",
        "####",
    }, &tiles);

    try testing.expectEqual(
        @as(?GridHit, null),
        grid.sweepBox(v(0.4, 0.4), v(0.5, 2.5), v(3, 0)).hit,
    );
}

test "sliding along a tiled wall never catches on an internal edge" {
    // The bug this module is built to not have. A box slides right along the top of a solid
    // floor; every cell boundary it crosses is a chance to report a spurious vertical face
    // pointing back the way it came.
    var tiles: [32]u16 = undefined;
    const grid = gridOf(&.{
        "........",
        "........",
        "........",
        "########",
    }, &tiles);

    const half = v(0.5, 0.5);
    var at = v(0.5, 1.5);
    var step: u32 = 0;
    while (step < 12) : (step += 1) {
        const motion = v(0.5, 0);
        const sweep = grid.sweepBox(half, at, motion);
        if (sweep.hit) |h| {
            // A hit here is the artefact: nothing is in the way, and any contact reported
            // would have a horizontal normal produced by an interior face.
            std.debug.print(
                "spurious contact at x={d} cell=({d},{d}) normal=({d},{d})\n",
                .{ at.x, h.cell[0], h.cell[1], h.normal.x, h.normal.y },
            );
            return error.CaughtOnInternalEdge;
        }
        at = at.add(motion);
    }
}

test "culling does not hide the wall's real surface" {
    // The other half of the fix: culling must remove interior faces and nothing else, so a
    // box falling onto the same floor still lands on it.
    var tiles: [32]u16 = undefined;
    const grid = gridOf(&.{
        "........",
        "........",
        "........",
        "########",
    }, &tiles);

    const hit = grid.sweepBox(v(0.5, 0.5), v(3.5, 3.5), v(0, -3)).hit.?;
    try testing.expectEqual(v(0, 1), hit.normal);
    // The floor's top is y = 1, so the centre stops at 1.5: two of the three units.
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), hit.fraction, 1e-6);
}

test "the earliest contact wins regardless of walk order" {
    var tiles: [16]u16 = undefined;
    const grid = gridOf(&.{
        "...#",
        "....",
        "#...",
        "....",
    }, &tiles);

    // Travelling up and to the right from the bottom-left. The cell at (0,1) is nearer than
    // the one at (3,3), and it is also visited first -- so this asserts the fraction rather
    // than the visit order, which is the property that has to hold.
    const hit = grid.sweepBox(v(0.25, 0.25), v(0.5, 0.4), v(0, 4)).hit.?;
    try testing.expectEqual(@as(u32, 1), hit.cell[1]);
    try testing.expectEqual(v(0, -1), hit.normal);
}

test "a box already inside a wall says so instead of reporting a contact" {
    var tiles: [4]u16 = undefined;
    const grid = gridOf(&.{
        "##",
        "##",
    }, &tiles);

    const sweep = grid.sweepBox(v(0.25, 0.25), v(0.5, 0.5), v(1, 0));
    try testing.expect(sweep.started_inside);
    // No contact, because every contact this walk could report is behind the shape. The way
    // out is `resolveOverlaps`, which is a separate call for exactly this reason.
    try testing.expectEqual(@as(?GridHit, null), sweep.hit);
}

test "starting inside one tile does not let a shape through the next wall" {
    // The reason the walk carries on past a cell it began inside rather than stopping there.
    var tiles: [16]u16 = undefined;
    const grid = gridOf(&.{
        "....",
        "....",
        "#..#",
        "....",
    }, &tiles);

    // The box straddles cell (0,1) and travels right into cell (3,1).
    const sweep = grid.sweepBox(v(0.4, 0.4), v(0.9, 1.5), v(3, 0));
    try testing.expect(sweep.started_inside);
    const hit = sweep.hit.?;
    try testing.expectEqual(@as(u32, 3), hit.cell[0]);
    try testing.expectEqual(v(-1, 0), hit.normal);
}

test "overlap ignores face culling, because being inside a wall is not about faces" {
    var tiles: [9]u16 = undefined;
    const grid = gridOf(&.{
        "...",
        "###",
        "...",
    }, &tiles);

    try testing.expect(grid.overlapsBox(v(0.25, 0.25), v(1.5, 1.5)));
    try testing.expect(!grid.overlapsBox(v(0.25, 0.25), v(1.5, 2.5)));
    // Exactly touching the top of the wall is not an overlap, the same rule the pair tests use.
    try testing.expect(!grid.overlapsBox(v(0.5, 0.5), v(1.5, 2.5)));
}

test "a grid with a non-square cell and a shifted origin walks correctly" {
    var tiles: [4]u16 = undefined;
    var grid = gridOf(&.{
        ".#",
        "..",
    }, &tiles);
    grid.origin = v(-10, 5);
    grid.cell = v(2, 4);

    // Cell (1,1) spans x in [-8,-6], y in [9,13].
    try testing.expect(grid.isSolidAt(1, 1));
    const b = grid.cellBounds(1, 1);
    try testing.expectEqual(v(-8, 9), b.min);
    try testing.expectEqual(v(-6, 13), b.max);
    try testing.expect(grid.overlapsBox(v(0.5, 0.5), v(-7, 11)));
    try testing.expect(!grid.overlapsBox(v(0.5, 0.5), v(-9, 11)));
}

test "a circle slides along a tiled floor without catching on a seam" {
    // The internal-edge test again, for the shape that has corners to snag on as well as
    // faces. Every cell boundary the circle crosses offers a vertical face and a quarter disc,
    // and both are interior to the wall.
    var tiles: [32]u16 = undefined;
    const grid = gridOf(&.{
        "........",
        "........",
        "........",
        "########",
    }, &tiles);

    const mover: Rounded = .{ .radius = 0.5 };
    var at = v(0.5, 1.5);
    var step: u32 = 0;
    while (step < 12) : (step += 1) {
        const motion = v(0.5, 0);
        const sweep = grid.sweepShape(mover, at, motion);
        if (sweep.hit) |h| {
            std.debug.print(
                "spurious contact at x={d} cell=({d},{d}) normal=({d},{d})\n",
                .{ at.x, h.cell[0], h.cell[1], h.normal.x, h.normal.y },
            );
            return error.CaughtOnInternalEdge;
        }
        try testing.expect(!sweep.started_inside);
        at = at.add(motion);
    }
}

test "a circle rounds the exposed corner at the end of a wall" {
    // The other half: culling must remove the seams and leave the wall's real corner, or a
    // circle would cut it.
    var tiles: [16]u16 = undefined;
    const grid = gridOf(&.{
        "....",
        "....",
        "##..",
        "....",
    }, &tiles);

    // Cell (1,1) is the end of the wall, so its corner at (2,2) is real geometry.
    const mover: Rounded = .{ .radius = 0.5 };
    const sweep = grid.sweepShape(mover, v(3.5, 3.5), v(-2, -2));
    const hit = sweep.hit.?;
    try testing.expectEqual(@as(u32, 1), hit.cell[0]);
    try testing.expectEqual(@as(u32, 1), hit.cell[1]);
    try testing.expectEqual(@as(?Face, null), hit.face);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), hit.normal.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), hit.normal.y, 1e-5);
}

test "escaping a wall goes out through a face the wall actually has" {
    // Depenetration's version of the internal-edge problem: the shortest way out of the middle
    // cell of a horizontal wall is sideways, and sideways is further into the wall.
    var tiles: [9]u16 = undefined;
    const grid = gridOf(&.{
        "...",
        "###",
        "...",
    }, &tiles);

    const mover: Rounded = .{ .half = v(0.25, 0.25) };
    const contact = grid.deepestOverlap(mover, v(1.5, 1.5)).?;
    try testing.expectEqual(@as(u32, 1), contact.cell[0]);
    // Up or down, never left or right. Ties go to +Y, as `overlapRounded` documents.
    try testing.expectEqual(v(0, 1), contact.normal);
    try testing.expectApproxEqAbs(@as(f32, 0.75), contact.depth, 1e-6);

    // And applying it leaves the shape outside.
    const escaped = v(1.5, 1.5).add(contact.normal.scale(contact.depth));
    try testing.expect(!grid.overlapsShape(mover, escaped));
}

test "a shape outside every wall has nothing to escape" {
    var tiles: [9]u16 = undefined;
    const grid = gridOf(&.{
        "...",
        "###",
        "...",
    }, &tiles);

    const mover: Rounded = .{ .half = v(0.25, 0.25) };
    try testing.expectEqual(@as(?GridContact, null), grid.deepestOverlap(mover, v(1.5, 2.5)));
}
