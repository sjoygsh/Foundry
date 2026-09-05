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
//!
//! **A body is read through a const pointer and changed through named calls.** Handing out a
//! `*Body` would let a caller move one by assignment, leaving the broadphase describing where
//! it used to be — and the symptom of that is "things sometimes do not collide", which is the
//! worst class of bug this module could ship. The setters exist so that every change which
//! affects the acceleration structure passes through something that can update it.

const std = @import("std");
const core = @import("core");

const body_mod = @import("body.zig");
const broadphase_mod = @import("broadphase.zig");
const grid_mod = @import("grid.zig");
const shape_mod = @import("shape.zig");

const Allocator = std.mem.Allocator;
const Bodies = body_mod.Bodies;
const Body = body_mod.Body;
const BodyHandle = body_mod.BodyHandle;
const BodyKind = body_mod.BodyKind;
const Bounds = shape_mod.Bounds;
const Broadphase = broadphase_mod.Broadphase;
const Candidates = broadphase_mod.Candidates;
const Grid = grid_mod.Grid;
const GridHandle = grid_mod.GridHandle;
const Grids = grid_mod.Grids;
const Shape = shape_mod.Shape;
const Vec2 = core.math.Vec2;

pub const AddBodyError = error{
    OutOfMemory,
    /// A degenerate shape: a zero or negative extent, or one that is not finite. Reported
    /// rather than asserted, because a shape reaches here from a game and from M7 from a mod.
    InvalidShape,
};

pub const AddGridError = error{ OutOfMemory, InvalidGrid };

pub const Options = struct {
    /// Broadphase cell size, or null to take it from the first body inserted.
    ///
    /// The default heuristic is right when bodies are of similar size, which is what a tile
    /// game has. This exists for when the first body is not representative — a world whose
    /// first insert is the one enormous boss — because a uniform hash degrades when sizes vary
    /// by orders of magnitude (ADR-0022).
    cell_size: ?f32 = null,
};

pub const World = struct {
    bodies: core.HandlePool(Bodies, Body) = .empty,
    grids: core.HandlePool(Grids, Grid) = .empty,
    broadphase: Broadphase = .empty,

    pub const empty: World = .{};

    pub fn init(options: Options) World {
        var world: World = .empty;
        if (options.cell_size) |size| {
            if (size > 0 and std.math.isFinite(size)) world.broadphase.setCellSize(size);
        }
        return world;
    }

    pub fn deinit(self: *World, gpa: Allocator) void {
        self.bodies.deinit(gpa);
        self.grids.deinit(gpa);
        self.broadphase.deinit(gpa);
        self.* = .empty;
    }

    pub fn addBody(self: *World, gpa: Allocator, new: Body) AddBodyError!BodyHandle {
        if (!new.shape.isValid()) return error.InvalidShape;
        if (!std.math.isFinite(new.position.x) or !std.math.isFinite(new.position.y)) {
            return error.InvalidShape;
        }
        const handle = try self.bodies.add(gpa, new);
        errdefer _ = self.bodies.remove(handle);
        try self.broadphase.insert(gpa, handle, new.kind, new.bounds());
        return handle;
    }

    pub fn removeBody(self: *World, gpa: Allocator, handle: BodyHandle) bool {
        const existing = self.bodies.get(handle) orelse return false;
        self.broadphase.remove(gpa, handle, existing.kind);
        return self.bodies.remove(handle);
    }

    /// A body, for reading. See the note at the top of this file about why it is const.
    pub fn body(self: *World, handle: BodyHandle) ?*const Body {
        return self.bodies.get(handle);
    }

    /// Moves a body without testing anything — a teleport.
    ///
    /// Named for what it is. It is how a spawn, a warp or a cutscene places something, and it
    /// can leave a body overlapping geometry, which is exactly the state `resolveOverlaps`
    /// exists to detect rather than to hide.
    pub fn setPosition(self: *World, gpa: Allocator, handle: BodyHandle, position: Vec2) Allocator.Error!bool {
        const existing = self.bodies.get(handle) orelse return false;
        if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y)) return false;
        existing.position = position;
        try self.broadphase.update(gpa, handle, existing.kind, existing.bounds());
        return true;
    }

    /// Replaces a body's shape. Refused if the new shape is degenerate.
    pub fn setShape(self: *World, gpa: Allocator, handle: BodyHandle, shape: Shape) Allocator.Error!bool {
        if (!shape.isValid()) return false;
        const existing = self.bodies.get(handle) orelse return false;
        existing.shape = shape;
        try self.broadphase.update(gpa, handle, existing.kind, existing.bounds());
        return true;
    }

    /// Moves a body between broadphase tiers.
    ///
    /// Its own call rather than a field write, because the tiers are the one piece of state
    /// that a plain assignment would silently desynchronise.
    pub fn setKind(self: *World, gpa: Allocator, handle: BodyHandle, kind: BodyKind) Allocator.Error!bool {
        const existing = self.bodies.get(handle) orelse return false;
        if (existing.kind == kind) return true;
        self.broadphase.remove(gpa, handle, existing.kind);
        existing.kind = kind;
        try self.broadphase.insert(gpa, handle, kind, existing.bounds());
        return true;
    }

    /// Neither of these reaches the broadphase, so they need no allocator and cannot fail.
    pub fn setFilter(self: *World, handle: BodyHandle, layer: u32, mask: u32) bool {
        const existing = self.bodies.get(handle) orelse return false;
        existing.layer = layer;
        existing.mask = mask;
        return true;
    }

    pub fn setUser(self: *World, handle: BodyHandle, user: u64) bool {
        const existing = self.bodies.get(handle) orelse return false;
        existing.user = user;
        return true;
    }

    /// Adds a tile grid.
    ///
    /// **`grid.tiles` and `grid.solid` are borrowed and must outlive the grid's presence in
    /// the world.** The world copies the descriptor and not the arrays; their lifetime and
    /// their reloading belong to whoever loaded them. This is what keeps `physics2d` at L1 —
    /// it never learns what an asset is.
    ///
    /// A grid does **not** enter the broadphase. It is a shape source and is walked directly,
    /// which is why it costs the same for a 2000x2000 map as for a 20x20 one (§4).
    pub fn addGrid(self: *World, gpa: Allocator, new: Grid) AddGridError!GridHandle {
        try new.validate();
        return self.grids.add(gpa, new);
    }

    pub fn removeGrid(self: *World, handle: GridHandle) bool {
        return self.grids.remove(handle);
    }

    pub fn grid(self: *World, handle: GridHandle) ?*const Grid {
        return self.grids.get(handle);
    }

    pub fn bodyCount(self: *const World) u32 {
        return self.bodies.count();
    }

    pub fn gridCount(self: *const World) u32 {
        return self.grids.count();
    }

    /// Live bodies in **ascending handle-index order** (I9; §8 rule 1).
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
        const existing = self.bodies.get(handle) orelse return null;
        return existing.bounds();
    }

    /// Bodies whose bounds actually meet `area` and whose layer the mask admits, in ascending
    /// handle-index order.
    ///
    /// The broadphase's answer narrowed twice: to bodies the mask wants, and to bodies the
    /// rectangle really touches rather than merely shares a cell with. `out` is cleared first
    /// and is the caller's to reuse, so a per-frame query loop allocates once.
    pub fn queryBounds(
        self: *World,
        gpa: Allocator,
        area: Bounds,
        mask: u32,
        out: *Candidates,
    ) Allocator.Error!void {
        try self.broadphase.query(gpa, area, out);

        var write: usize = 0;
        for (out.items.items) |handle| {
            const existing = self.bodies.get(handle) orelse continue;
            if (!body_mod.maskAdmits(mask, existing.*)) continue;
            if (!existing.bounds().overlaps(area)) continue;
            out.items.items[write] = handle;
            write += 1;
        }
        out.items.shrinkRetainingCapacity(write);
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
    try testing.expectEqual(@as(u32, 1), world.broadphase.count());
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

    // Nothing was added, so nothing below has to defend against one -- and the broadphase did
    // not gain an entry for a body the pool does not have.
    try testing.expectEqual(@as(u32, 0), world.bodyCount());
    try testing.expectEqual(@as(u32, 0), world.broadphase.count());
}

test "a stale handle names nothing, and does not name whatever took its slot" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    const first = try world.addBody(testing.allocator, boxAt(1, 1));
    try testing.expect(world.removeBody(testing.allocator, first));
    try testing.expect(!world.removeBody(testing.allocator, first));

    const second = try world.addBody(testing.allocator, boxAt(2, 2));
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);

    try testing.expectEqual(@as(?*const Body, null), world.body(first));
    try testing.expectEqual(@as(f32, 2), world.body(second).?.position.x);
    try testing.expect(!try world.setPosition(testing.allocator, first, .{ .x = 9, .y = 9 }));
    try testing.expectEqual(@as(f32, 2), world.body(second).?.position.x);
}

test "a teleport does not pretend to be a move" {
    var world: World = .empty;
    defer world.deinit(testing.allocator);

    const handle = try world.addBody(testing.allocator, boxAt(0, 0));
    try testing.expect(try world.setPosition(testing.allocator, handle, .{ .x = 5, .y = -5 }));
    try testing.expectEqual(@as(f32, 5), world.body(handle).?.position.x);

    // A position that is not a number is refused rather than stored, because it would poison
    // every bound computed from it thereafter.
    try testing.expect(!try world.setPosition(testing.allocator, handle, .{ .x = std.math.inf(f32), .y = 0 }));
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
    try testing.expect(world.removeBody(testing.allocator, b));
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
    // rebuild. It is also why a grid never enters the broadphase.
    tiles[1] = 0;
    try testing.expect(!world.grid(handle).?.isSolidAt(1, 0));
    try testing.expectEqual(@as(u32, 0), world.broadphase.count());

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

test "a query returns only bodies the rectangle really touches" {
    var world: World = .init(.{ .cell_size = 4 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    const near = try world.addBody(testing.allocator, boxAt(0, 0));
    // Same broadphase cell, but the rectangle misses it: the narrow phase of the query is what
    // turns a candidate into a result.
    _ = try world.addBody(testing.allocator, boxAt(3.5, 3.5));
    _ = try world.addBody(testing.allocator, boxAt(80, 80));

    try world.queryBounds(testing.allocator, .fromCenter(.zero, .{ .x = 1, .y = 1 }), ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);
    try testing.expect(out.handles()[0].eql(near));
}

test "a query respects the mask, one-sidedly" {
    var world: World = .init(.{ .cell_size = 4 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    var wall = boxAt(0, 0);
    wall.layer = 0b010;
    // Its own mask is empty, and a query still finds it: a query asks where things are, it
    // does not collide with them.
    wall.mask = 0;
    const handle = try world.addBody(testing.allocator, wall);

    try world.queryBounds(testing.allocator, .fromCenter(.zero, .one), 0b010, &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);
    try testing.expect(out.handles()[0].eql(handle));

    try world.queryBounds(testing.allocator, .fromCenter(.zero, .one), 0b100, &out);
    try testing.expectEqual(@as(usize, 0), out.handles().len);
}

test "a removed body stops being found, and a moved one is found where it went" {
    var world: World = .init(.{ .cell_size = 1 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    const handle = try world.addBody(testing.allocator, boxAt(0, 0));
    const here: Bounds = .fromCenter(.zero, .one);
    const there: Bounds = .fromCenter(.{ .x = 30, .y = 30 }, .one);

    try world.queryBounds(testing.allocator, here, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);

    _ = try world.setPosition(testing.allocator, handle, .{ .x = 30, .y = 30 });
    try world.queryBounds(testing.allocator, here, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 0), out.handles().len);
    try world.queryBounds(testing.allocator, there, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);

    try testing.expect(world.removeBody(testing.allocator, handle));
    try world.queryBounds(testing.allocator, there, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 0), out.handles().len);
    try testing.expectEqual(@as(u32, 0), world.broadphase.count());
}

test "changing kind moves a body between tiers without losing it" {
    var world: World = .init(.{ .cell_size = 2 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    const handle = try world.addBody(testing.allocator, boxAt(0, 0));
    try testing.expectEqual(@as(u32, 1), world.broadphase.movers.count());
    try testing.expectEqual(@as(u32, 0), world.broadphase.statics.count());

    try testing.expect(try world.setKind(testing.allocator, handle, .static));
    try testing.expectEqual(@as(u32, 0), world.broadphase.movers.count());
    try testing.expectEqual(@as(u32, 1), world.broadphase.statics.count());

    try world.queryBounds(testing.allocator, .fromCenter(.zero, .one), ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);
    try testing.expectEqual(BodyKind.static, world.body(handle).?.kind);
}

test "growing a body's shape widens what finds it" {
    var world: World = .init(.{ .cell_size = 1 });
    defer world.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    const handle = try world.addBody(testing.allocator, boxAt(0, 0));
    const far: Bounds = .fromCenter(.{ .x = 3, .y = 0 }, .{ .x = 0.25, .y = 0.25 });

    try world.queryBounds(testing.allocator, far, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 0), out.handles().len);

    try testing.expect(try world.setShape(testing.allocator, handle, .{ .box = .{ .x = 4, .y = 4 } }));
    try world.queryBounds(testing.allocator, far, ~@as(u32, 0), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);

    // A degenerate replacement is refused and changes nothing.
    try testing.expect(!try world.setShape(testing.allocator, handle, .{ .circle = -1 }));
    try testing.expectEqual(@as(f32, 4), world.body(handle).?.shape.box.x);
}

test "the same world described two ways answers the same question the same way" {
    // I9, in the strongest form M5 can state at this step: two insertion orders describing the
    // same world must agree, because that is the property that catches an accidental
    // dependence on the hash. The bodies carry `user` values so the comparison is about the
    // world rather than about which slot each body happened to get.
    const places = [_][2]f32{ .{ 0, 0 }, .{ 1.5, 0.5 }, .{ -2, 1 }, .{ 40, 40 }, .{ 0.5, -1.2 } };
    const orders = [_][5]usize{
        .{ 0, 1, 2, 3, 4 },
        .{ 4, 3, 2, 1, 0 },
        .{ 2, 4, 0, 3, 1 },
    };
    const area: Bounds = .{ .min = .{ .x = -1, .y = -1 }, .max = .{ .x = 2, .y = 2 } };

    var expected: [8]u64 = undefined;
    var expected_len: usize = 0;

    for (orders, 0..) |order, run| {
        // A different cell size each run as well, so the test rejects both an order dependence
        // and a bucketing dependence at once.
        const sizes = [_]f32{ 0.5, 3, 17 };
        var world: World = .init(.{ .cell_size = sizes[run] });
        defer world.deinit(testing.allocator);

        var out: Candidates = .empty;
        defer out.deinit(testing.allocator);

        for (order) |index| {
            var b = boxAt(places[index][0], places[index][1]);
            b.user = index + 1;
            _ = try world.addBody(testing.allocator, b);
        }

        try world.queryBounds(testing.allocator, area, ~@as(u32, 0), &out);

        var users: [8]u64 = undefined;
        for (out.handles(), 0..) |handle, i| users[i] = world.body(handle).?.user;
        std.sort.pdq(u64, users[0..out.handles().len], {}, std.sort.asc(u64));

        if (run == 0) {
            expected_len = out.handles().len;
            @memcpy(expected[0..expected_len], users[0..expected_len]);
            // Two of the five are outside the rectangle, and one of those only just.
            try testing.expectEqual(@as(usize, 3), expected_len);
        } else {
            try testing.expectEqualSlices(u64, expected[0..expected_len], users[0..out.handles().len]);
        }
    }
}
