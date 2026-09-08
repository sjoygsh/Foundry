//! Plain values that the `physics2d` calls exchange with a mod.
//!
//! The collision module's own `Shape`, `Hit` and `QueryHit` values contain Zig unions and
//! handles for an internal grid. Neither is a C ABI type. These are the deliberately boring
//! wire forms: an explicit tag, explicit padding, and null `Body` for a grid result.
//!
//! Design: `docs/design/public-abi.md` §5, §9 and `docs/design/tilemaps-and-collision.md` §12.

const std = @import("std");

const types = @import("types.zig");

const Body = types.Body;
const Grid = types.Grid;

/// A two-dimensional position, extent or motion. Coordinates are world units and use the
/// physics module's Y-up convention.
pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// The closed shape set exposed by physics2d.
///
/// `kind` is 0 for a box and 1 for a circle. A box uses both extents as positive half-
/// extents. A circle uses `x` as its positive radius and requires `y == 0`; spelling the
/// unused member out makes the bytes deterministic and catches a descriptor assembled with
/// the wrong shape in a mod before it reaches a union conversion.
pub const Shape = extern struct {
    kind: i32 = 0,
    reserved: u32 = 0,
    x: f32 = 0,
    y: f32 = 0,
};

/// The in-memory description needed to create one body.
///
/// Body kind is 0 static, 1 movable and 2 trigger. Layer and mask are plain bit masks, and
/// `user` is returned unchanged in contacts; the engine never interprets it.
pub const BodyDesc = extern struct {
    shape: Shape = .{},
    position: Vec2 = .{},
    kind: i32 = 0,
    reserved: u32 = 0,
    layer: u32 = 1,
    mask: u32 = ~@as(u32, 0),
    user: u64 = 0,
};

/// A swept contact. `body` is zero for a tile-grid hit; in that case `grid`, `cell_x` and
/// `cell_y` identify the solid cell. For a body hit, the grid and cell fields are zero and
/// `user` is that body's opaque user value. The explicit padding before `user` is part of the
/// contract: offsets and total size do not prove the width of a member by themselves.
pub const Hit = extern struct {
    body: Body = .none,
    grid: Grid = .none,
    cell_x: u32 = 0,
    cell_y: u32 = 0,
    normal: Vec2 = .{},
    fraction: f32 = 0,
    reserved: [4]u8 = .{ 0, 0, 0, 0 },
    user: u64 = 0,
};

/// An overlap result. There is no normal or fraction because an overlap has neither. Grid
/// identity is retained for the same reason as in `Hit`: two grids can have the same cell
/// coordinates, and a null body alone cannot tell them apart.
pub const QueryHit = extern struct {
    body: Body = .none,
    grid: Grid = .none,
    cell_x: u32 = 0,
    cell_y: u32 = 0,
    user: u64 = 0,
};

/// The result of a body move. `hit_count` is how many entries were written and `total_hits`
/// is how many contacts there were. A smaller caller buffer therefore produces a successful,
/// explicitly truncated result rather than an invented error.
pub const MoveResult = extern struct {
    position: Vec2 = .{},
    hit_count: u32 = 0,
    total_hits: u32 = 0,
    started_inside: types.Bool = 0,
    reserved: [3]u8 = .{ 0, 0, 0 },
};

comptime {
    if (@sizeOf(Vec2) != 8 or @offsetOf(Vec2, "x") != 0 or @offsetOf(Vec2, "y") != 4 or
        @sizeOf(@FieldType(Vec2, "x")) != 4 or @sizeOf(@FieldType(Vec2, "y")) != 4)
    {
        @compileError("FoundryPhysicsVec2 layout changed");
    }
    if (@sizeOf(Shape) != 16 or @offsetOf(Shape, "kind") != 0 or
        @offsetOf(Shape, "reserved") != 4 or @offsetOf(Shape, "x") != 8 or
        @offsetOf(Shape, "y") != 12 or @sizeOf(@FieldType(Shape, "kind")) != 4 or
        @sizeOf(@FieldType(Shape, "reserved")) != 4 or @sizeOf(@FieldType(Shape, "x")) != 4 or
        @sizeOf(@FieldType(Shape, "y")) != 4)
    {
        @compileError("FoundryPhysicsShape layout changed");
    }
    if (@sizeOf(BodyDesc) != 48 or @offsetOf(BodyDesc, "shape") != 0 or
        @offsetOf(BodyDesc, "position") != 16 or @offsetOf(BodyDesc, "kind") != 24 or
        @offsetOf(BodyDesc, "reserved") != 28 or @offsetOf(BodyDesc, "layer") != 32 or
        @offsetOf(BodyDesc, "mask") != 36 or @offsetOf(BodyDesc, "user") != 40 or
        @sizeOf(@FieldType(BodyDesc, "shape")) != 16 or
        @sizeOf(@FieldType(BodyDesc, "position")) != 8 or
        @sizeOf(@FieldType(BodyDesc, "kind")) != 4 or
        @sizeOf(@FieldType(BodyDesc, "reserved")) != 4 or
        @sizeOf(@FieldType(BodyDesc, "layer")) != 4 or
        @sizeOf(@FieldType(BodyDesc, "mask")) != 4 or
        @sizeOf(@FieldType(BodyDesc, "user")) != 8)
    {
        @compileError("FoundryPhysicsBodyDesc layout changed");
    }
    if (@sizeOf(Hit) != 48 or @offsetOf(Hit, "body") != 0 or @offsetOf(Hit, "grid") != 8 or
        @offsetOf(Hit, "cell_x") != 16 or @offsetOf(Hit, "cell_y") != 20 or
        @offsetOf(Hit, "normal") != 24 or @offsetOf(Hit, "fraction") != 32 or
        @offsetOf(Hit, "reserved") != 36 or @offsetOf(Hit, "user") != 40 or
        @sizeOf(@FieldType(Hit, "body")) != 8 or @sizeOf(@FieldType(Hit, "grid")) != 8 or
        @sizeOf(@FieldType(Hit, "cell_x")) != 4 or @sizeOf(@FieldType(Hit, "cell_y")) != 4 or
        @sizeOf(@FieldType(Hit, "normal")) != 8 or @sizeOf(@FieldType(Hit, "fraction")) != 4 or
        @sizeOf(@FieldType(Hit, "reserved")) != 4 or @sizeOf(@FieldType(Hit, "user")) != 8)
    {
        @compileError("FoundryPhysicsHit layout changed");
    }
    if (@sizeOf(QueryHit) != 32 or @offsetOf(QueryHit, "body") != 0 or
        @offsetOf(QueryHit, "grid") != 8 or @offsetOf(QueryHit, "cell_x") != 16 or
        @offsetOf(QueryHit, "cell_y") != 20 or @offsetOf(QueryHit, "user") != 24 or
        @sizeOf(@FieldType(QueryHit, "body")) != 8 or
        @sizeOf(@FieldType(QueryHit, "grid")) != 8 or
        @sizeOf(@FieldType(QueryHit, "cell_x")) != 4 or
        @sizeOf(@FieldType(QueryHit, "cell_y")) != 4 or
        @sizeOf(@FieldType(QueryHit, "user")) != 8)
    {
        @compileError("FoundryPhysicsQueryHit layout changed");
    }
    if (@sizeOf(MoveResult) != 20 or @offsetOf(MoveResult, "position") != 0 or
        @offsetOf(MoveResult, "hit_count") != 8 or @offsetOf(MoveResult, "total_hits") != 12 or
        @offsetOf(MoveResult, "started_inside") != 16 or @offsetOf(MoveResult, "reserved") != 17 or
        @sizeOf(@FieldType(MoveResult, "position")) != 8 or
        @sizeOf(@FieldType(MoveResult, "hit_count")) != 4 or
        @sizeOf(@FieldType(MoveResult, "total_hits")) != 4 or
        @sizeOf(@FieldType(MoveResult, "started_inside")) != 1 or
        @sizeOf(@FieldType(MoveResult, "reserved")) != 3)
    {
        @compileError("FoundryPhysicsMoveResult layout changed");
    }
}

test "physics ABI values have explicit stable layouts and widths" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 8), @sizeOf(Vec2));
    try testing.expectEqual(@as(usize, 16), @sizeOf(Shape));
    try testing.expectEqual(@as(usize, 48), @sizeOf(BodyDesc));
    try testing.expectEqual(@as(usize, 48), @sizeOf(Hit));
    try testing.expectEqual(@as(usize, 32), @sizeOf(QueryHit));
    try testing.expectEqual(@as(usize, 20), @sizeOf(MoveResult));
    try testing.expectEqual(@as(usize, 1), @sizeOf(types.Bool));
    try testing.expectEqual(@as(usize, 3), @sizeOf(@FieldType(MoveResult, "reserved")));
}
