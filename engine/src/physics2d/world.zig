//! The collision world: bodies, grids, and what may be asked of them.
//!
//! **The world holds no time and no velocity, and integrates nothing.** There is no `dt` in
//! any signature here, no stored velocity, and no step. A caller says *move this body by this
//! vector* and is told where it ended up and what it touched. Three things follow, all of them
//! wanted (`tilemaps-and-collision.md` §2):
//!
//! * Movement feel stays in the game, which is where acceleration curves and speed caps belong.
//! * I9 gets simpler: a module with no clock cannot read one, and a module that integrates
//!   nothing has no accumulated float state to diverge.
//! * Every test is "put these shapes here, move this one, assert where it stopped" — no
//!   stepping, no settling, no tolerance for a solver converging.

const std = @import("std");
const core = @import("core");

const body_mod = @import("body.zig");
const grid_mod = @import("grid.zig");
const shape_mod = @import("shape.zig");

const Allocator = std.mem.Allocator;
const Bodies = body_mod.Bodies;
const Body = body_mod.Body;
const BodyHandle = body_mod.BodyHandle;
const Bounds = shape_mod.Bounds;
const Grid = grid_mod.Grid;
const GridHandle = grid_mod.GridHandle;
const Grids = grid_mod.Grids;
const Vec2 = core.math.Vec2;

pub const AddBodyError = error{
    OutOfMemory,
    /// A degenerate shape: a zero or negative extent, or one that is not finite. Reported
    /// rather than asserted, because a shape reaches here from a game and from M7 from a mod.
    InvalidShape,
};

pub const AddGridError = error{ OutOfMemory, InvalidGrid };

pub const World = struct {
    bodies: core.HandlePool(Bodies, Body) = .empty,
    grids: core.HandlePool(Grids, Grid) = .empty,

    pub const empty: World = .{};

    pub fn deinit(self: *World, gpa: Allocator) void {
        self.bodies.deinit(gpa);
        self.grids.deinit(gpa);
        self.* = .empty;
    }

    pub fn addBody(self: *World, gpa: Allocator, new: Body) AddBodyError!BodyHandle {
        if (!new.shape.isValid()) return error.InvalidShape;
        if (!std.math.isFinite(new.position.x) or !std.math.isFinite(new.position.y)) {
            return error.InvalidShape;
        }
        return self.bodies.add(gpa, new);
    }

    pub fn removeBody(self: *World, handle: BodyHandle) bool {
        return self.bodies.remove(handle);
    }

    pub fn body(self: *World, handle: BodyHandle) ?*Body {
        return self.bodies.get(handle);
    }

    /// Moves a body without testing anything — a teleport.
    ///
    /// Named for what it is. It is how a spawn, a warp or a cutscene places something, and it
    /// can leave a body overlapping geometry, which is exactly the state `resolveOverlaps`
    /// exists to detect rather than to hide.
    pub fn setPosition(self: *World, handle: BodyHandle, position: Vec2) bool {
        const b = self.bodies.get(handle) orelse return false;
        if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y)) return false;
        b.position = position;
        return true;
    }

    /// Adds a tile grid.
    ///
    /// **`grid.tiles` and `grid.solid` are borrowed and must outlive the grid's presence in
    /// the world.** The world copies the descriptor and not the arrays; their lifetime and
    /// their reloading belong to whoever loaded them. This is what keeps `physics2d` at L1 —
    /// it never learns what an asset is.
    pub fn addGrid(self: *World, gpa: Allocator, new: Grid) AddGridError!GridHandle {
        try new.validate();
        return self.grids.add(gpa, new);
    }

    pub fn removeGrid(self: *World, handle: GridHandle) bool {
        return self.grids.remove(handle);
    }

    pub fn grid(self: *World, handle: GridHandle) ?*Grid {
        return self.grids.get(handle);
    }

    pub fn bodyCount(self: *const World) u32 {
        return self.bodies.count();
    }

    pub fn gridCount(self: *const World) u32 {
        return self.grids.count();
    }

    /// Live bodies in **ascending handle-index order** (I9; §8 rule 1).
    ///
    /// Every operation in this module that considers more than one body uses this order or
    /// sorts into it, which is what makes the acceleration structure replaceable without
    /// changing a single result.
    pub fn bodyIterator(self: *World) core.HandlePool(Bodies, Body).Iterator {
        return self.bodies.iterator();
    }

    /// Live grids in ascending handle-index order. **Grids are considered before bodies** in
    /// any operation that looks at both (§8 rule 3).
    pub fn gridIterator(self: *World) core.HandlePool(Grids, Grid).Iterator {
        return self.grids.iterator();
    }

    /// The bounds of a body, or null if the handle is stale.
    pub fn boundsOf(self: *World, handle: BodyHandle) ?Bounds {
        const b = self.bodies.get(handle) orelse return null;
        return b.bounds();
    }
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

fn boxAt(x: f32, y: f32) Body {
    return .{
        .shape = .{ .box = .{ .x = 0.5, .y = 0.5 } },
        .position = .{ .x = x, .y = y },
        .kind = .movable,
    };
}

test "a world starts empty and cleans up after itself" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), world.bodyCount());
    try testing.expectEqual(@as(u32, 0), world.gridCount());

    _ = try world.addBody(testing.allocator, boxAt(0, 0));
    try testing.expectEqual(@as(u32, 1), world.bodyCount());
}

test "a degenerate body is refused at the boundary" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    var bad = boxAt(0, 0);
    bad.shape = .{ .box = .{ .x = 0, .y = 1 } };
    try testing.expectError(error.InvalidShape, world.addBody(testing.allocator, bad));

    var not_finite = boxAt(0, 0);
    not_finite.position = .{ .x = std.math.nan(f32), .y = 0 };
    try testing.expectError(error.InvalidShape, world.addBody(testing.allocator, not_finite));

    // Nothing was added, so nothing below has to defend against one.
    try testing.expectEqual(@as(u32, 0), world.bodyCount());
}

test "a stale handle names nothing, and does not name whatever took its slot" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    const first = try world.addBody(testing.allocator, boxAt(1, 1));
    try testing.expect(world.removeBody(first));
    try testing.expect(!world.removeBody(first));

    const second = try world.addBody(testing.allocator, boxAt(2, 2));
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);

    try testing.expectEqual(@as(?*Body, null), world.body(first));
    try testing.expectEqual(@as(f32, 2), world.body(second).?.position.x);
    try testing.expect(!world.setPosition(first, .{ .x = 9, .y = 9 }));
    try testing.expectEqual(@as(f32, 2), world.body(second).?.position.x);
}

test "a teleport does not pretend to be a move" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    const handle = try world.addBody(testing.allocator, boxAt(0, 0));
    try testing.expect(world.setPosition(handle, .{ .x = 5, .y = -5 }));
    try testing.expectEqual(@as(f32, 5), world.body(handle).?.position.x);

    // A position that is not a number is refused rather than stored, because it would poison
    // every bound computed from it thereafter.
    try testing.expect(!world.setPosition(handle, .{ .x = std.math.inf(f32), .y = 0 }));
    try testing.expectEqual(@as(f32, 5), world.body(handle).?.position.x);
}

test "bodies iterate in handle-index order regardless of how they were added" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    _ = try world.addBody(testing.allocator, boxAt(0, 0));
    const b = try world.addBody(testing.allocator, boxAt(1, 0));
    _ = try world.addBody(testing.allocator, boxAt(2, 0));

    // Free the middle slot and refill it. The pool's free list is LIFO, so the newcomer lands
    // back at index 1 -- later in insertion order, earlier in iteration order. Which of those
    // two an operation depends on is exactly what I9 requires be written down.
    try testing.expect(world.removeBody(b));
    const d = try world.addBody(testing.allocator, boxAt(9, 9));
    try testing.expectEqual(b.index, d.index);

    var seen: [3]u32 = undefined;
    var count: usize = 0;
    var it = world.bodyIterator();
    while (it.next()) |entry| : (count += 1) seen[count] = entry.id.index;

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, &seen);
}

test "a grid is validated on the way in and its slices are borrowed" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    var tiles = [_]u16{ 0, 1, 1, 0 };
    const solid = [_]u32{0b10};
    const handle = try world.addGrid(testing.allocator, .{
        .origin = .zero,
        .cell = .one,
        .width = 2,
        .height = 2,
        .tiles = &tiles,
        .solid = &solid,
    });
    try testing.expectEqual(@as(u32, 1), world.gridCount());
    try testing.expect(world.grid(handle).?.isSolidAt(1, 0));

    // The world holds the descriptor, not a copy of the map: editing the caller's array is
    // visible immediately, which is what makes hot-reloading a tilemap a swap rather than a
    // rebuild.
    tiles[1] = 0;
    try testing.expect(!world.grid(handle).?.isSolidAt(1, 0));

    var bad_tiles = [_]u16{0};
    try testing.expectError(error.InvalidGrid, world.addGrid(testing.allocator, .{
        .origin = .zero,
        .cell = .one,
        .width = 4,
        .height = 4,
        .tiles = &bad_tiles,
        .solid = &solid,
    }));
}
