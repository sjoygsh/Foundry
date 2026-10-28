//! What a build is made from, and the grid it will need (`navigation.md` §5, "Inputs").
//!
//! **Everything here comes from content, and from M48 from a mod**, so it is validated and
//! refused, never asserted (CLAUDE.md §7). `measure` reads the sources once, allocates
//! nothing, and answers either a grid every later stage can rely on or the reason there is
//! none. A build calls it before it allocates.

const std = @import("std");
const core = @import("core");

const config_mod = @import("config.zig");

const Config = config_mod.Config;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;

/// The farthest a posed position may be from the origin on any axis: `physics3d`'s and
/// `.fcol`'s envelope, so whatever collides can be navigated.
pub const max_coordinate: f32 = 8192;
/// `.fcol`'s limits, over all sources together.
pub const max_triangles: usize = 1_048_576;
pub const max_positions: usize = 3_145_728;
/// A level's collision plus the props a game places on it.
pub const max_sources: usize = 4096;
/// Columns on X and on Z. Bounds the heightfield's column table at 4M entries.
pub const max_columns: u32 = 2048;
/// Cells on Y: a span's floor and top are `u16`s.
pub const max_cells_high: u32 = 65_535;
/// Below this area a triangle is skipped, as `physics3d` skips it, not refused.
pub const min_triangle_area: f32 = 1e-12;

/// Rigid, as `physics3d.Pose` is: a position and a unit rotation, no scale (ADR-0057).
pub const Pose = struct {
    position: Vec3 = .zero,
    rotation: Quat = .identity,

    pub const identity: Pose = .{};

    pub fn apply(self: Pose, local: Vec3) Vec3 {
        return self.position.add(self.rotation.rotate(local));
    }
};

/// One piece of geometry, borrowed for as long as the call that reads it.
pub const Source = struct {
    positions: []const Vec3,
    indices: []const u32,
    pose: Pose = .identity,
};

pub const InputError = error{
    /// A field of the `Config`; `Config.invalidField` says which.
    InvalidConfig,
    /// No sources, an index past its positions, a count not a multiple of three, a position or
    /// pose that is not finite or is outside `max_coordinate`, or a rotation that is not a
    /// rotation.
    InvalidGeometry,
    /// More sources, triangles or positions than the limits, or a grid wider, deeper or taller
    /// than `max_columns` and `max_cells_high`.
    TooLarge,
};

/// The voxel grid a build will use: its corner and its size in cells.
pub const Grid = struct {
    /// The sources' minimum, lowered by one cell on every axis, so no span touches the edge.
    origin: Vec3,
    cell_size: f32,
    cell_height: f32,
    width: u32,
    depth: u32,
    height: u32,
    triangles: u32,

    pub fn columns(self: Grid) u32 {
        return self.width * self.depth;
    }
};

/// Validates `config` and every source, and measures the grid they need. Allocates nothing.
pub fn measure(config: Config, sources: []const Source) InputError!Grid {
    if (!config.valid()) return error.InvalidConfig;
    if (sources.len == 0) return error.InvalidGeometry;
    if (sources.len > max_sources) return error.TooLarge;

    var triangles: usize = 0;
    var positions: usize = 0;
    for (sources) |s| {
        if (s.indices.len % 3 != 0) return error.InvalidGeometry;
        triangles += s.indices.len / 3;
        positions += s.positions.len;
    }
    if (triangles > max_triangles or positions > max_positions) return error.TooLarge;
    if (triangles == 0) return error.InvalidGeometry;

    var min: Vec3 = .init(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32));
    var max: Vec3 = .init(-std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32));
    for (sources) |s| {
        const pose = try validPose(s.pose);
        for (s.indices) |i| if (i >= s.positions.len) return error.InvalidGeometry;
        // Every position, referenced or not, as `physics3d` checks them: a value that is not a
        // coordinate is a damaged source whichever triangle it would have joined.
        for (s.positions) |local| {
            if (!inEnvelope(local)) return error.InvalidGeometry;
            const p = pose.apply(local);
            if (!inEnvelope(p)) return error.InvalidGeometry;
            min = .init(@min(min.x, p.x), @min(min.y, p.y), @min(min.z, p.z));
            max = .init(@max(max.x, p.x), @max(max.y, p.y), @max(max.z, p.z));
        }
    }

    const origin: Vec3 = .init(min.x - config.cell_size, min.y - config.cell_height, min.z - config.cell_size);
    // The cell holding the maximum, plus that cell, plus one of margin on the far side.
    const width = cellOf(max.x - origin.x, config.cell_size) + 2;
    const depth = cellOf(max.z - origin.z, config.cell_size) + 2;
    const height = cellOf(max.y - origin.y, config.cell_height) + 2;
    if (width > max_columns or depth > max_columns or height > max_cells_high) return error.TooLarge;
    return .{
        .origin = origin,
        .cell_size = config.cell_size,
        .cell_height = config.cell_height,
        .width = @intCast(width),
        .depth = @intCast(depth),
        .height = @intCast(height),
        .triangles = @intCast(triangles),
    };
}

/// A pose from outside, with its rotation normalised through the one entry point every
/// rotation from outside takes.
fn validPose(pose: Pose) InputError!Pose {
    if (!inEnvelope(pose.position)) return error.InvalidGeometry;
    const r = pose.rotation;
    const rotation = Quat.validated(r.x, r.y, r.z, r.w) catch return error.InvalidGeometry;
    return .{ .position = pose.position, .rotation = rotation };
}

fn inEnvelope(p: Vec3) bool {
    return p.isFinite() and @abs(p.x) <= max_coordinate and @abs(p.y) <= max_coordinate and
        @abs(p.z) <= max_coordinate;
}

/// The cell a distance from the origin falls in, as rasterisation will place it. In `f64`, so
/// a 16 km extent at 1 cm cannot overflow before it is compared with the limits.
fn cellOf(extent: f32, size: f32) u64 {
    return @intFromFloat(@floor(@as(f64, extent) / @as(f64, size)));
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const walker = config_mod.walker;

/// A 10 m floor of two triangles at y = 0, from (0, 0, 0) to (10, 0, 10).
const floor_positions = [_]Vec3{ .init(0, 0, 0), .init(10, 0, 0), .init(10, 0, 10), .init(0, 0, 10) };
const floor_indices = [_]u32{ 0, 2, 1, 0, 3, 2 };
const floor: Source = .{ .positions = &floor_positions, .indices = &floor_indices };

test "a floor measures its grid with a cell of margin on every side" {
    const grid = try measure(walker, &.{floor});
    try testing.expectApproxEqAbs(@as(f32, -0.1), grid.origin.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.05), grid.origin.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.1), grid.origin.z, 1e-6);
    // The far edge, 10.1 m from the origin, falls in cell 101; with it and a margin, 103.
    try testing.expectEqual(@as(u32, 103), grid.width);
    try testing.expectEqual(@as(u32, 103), grid.depth);
    try testing.expectEqual(@as(u32, 3), grid.height);
    try testing.expectEqual(@as(u32, 2), grid.triangles);
}

test "a pose moves and turns a source before it is measured" {
    const quarter = Quat.fromAxisAngle(.init(0, 1, 0), std.math.pi / 2.0);
    const moved: Source = .{ .positions = &floor_positions, .indices = &floor_indices, .pose = .{
        .position = .init(100, 2, 0),
        .rotation = quarter,
    } };
    const grid = try measure(walker, &.{moved});
    // A quarter turn about +Y takes +X to −Z, so the floor spans z from −10 to 0.
    try testing.expectApproxEqAbs(@as(f32, 99.9), grid.origin.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.95), grid.origin.y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -10.1), grid.origin.z, 1e-4);
}

test "every invalid input is refused before anything is allocated" {
    const nan = std.math.nan(f32);
    var bad_config = walker;
    bad_config.cell_size = 0;
    try testing.expectError(error.InvalidConfig, measure(bad_config, &.{floor}));

    try testing.expectError(error.InvalidGeometry, measure(walker, &.{}));
    try testing.expectError(error.InvalidGeometry, measure(walker, &.{.{ .positions = &floor_positions, .indices = &.{} }}));
    try testing.expectError(error.InvalidGeometry, measure(walker, &.{.{ .positions = &floor_positions, .indices = &.{ 0, 1 } }}));
    try testing.expectError(error.InvalidGeometry, measure(walker, &.{.{ .positions = &floor_positions, .indices = &.{ 0, 1, 4 } }}));

    const cases = [_]Vec3{ .init(nan, 0, 0), .init(0, std.math.inf(f32), 0), .init(0, 0, 8192.5), .init(-9000, 0, 0) };
    for (cases) |p| {
        const positions = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), p };
        try testing.expectError(error.InvalidGeometry, measure(walker, &.{.{ .positions = &positions, .indices = &.{ 0, 1, 2 } }}));
        // An unreferenced bad position is refused too.
        const spare = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 0, 1), p };
        try testing.expectError(error.InvalidGeometry, measure(walker, &.{.{ .positions = &spare, .indices = &.{ 0, 1, 2 } }}));
    }

    // A pose that carries a valid position out of the envelope, and poses that are not poses.
    const out: Source = .{ .positions = &floor_positions, .indices = &floor_indices, .pose = .{ .position = .init(8190, 0, 0) } };
    try testing.expectError(error.InvalidGeometry, measure(walker, &.{out}));
    const nan_pose: Source = .{ .positions = &floor_positions, .indices = &floor_indices, .pose = .{ .position = .init(nan, 0, 0) } };
    try testing.expectError(error.InvalidGeometry, measure(walker, &.{nan_pose}));
    const zero_turn: Source = .{ .positions = &floor_positions, .indices = &floor_indices, .pose = .{ .rotation = .{ .x = 0, .y = 0, .z = 0, .w = 0 } } };
    try testing.expectError(error.InvalidGeometry, measure(walker, &.{zero_turn}));
}

test "limits are refused as too large, not as invalid" {
    // 2,048 columns at 0.1 m is 204.8 m less the two margin cells.
    const wide = [_]Vec3{ .init(0, 0, 0), .init(204.5, 0, 0), .init(0, 0, 1) };
    _ = try measure(walker, &.{.{ .positions = &wide, .indices = &.{ 0, 1, 2 } }});
    const wider = [_]Vec3{ .init(0, 0, 0), .init(204.8, 0, 0), .init(0, 0, 1) };
    try testing.expectError(error.TooLarge, measure(walker, &.{.{ .positions = &wider, .indices = &.{ 0, 1, 2 } }}));
    const deep = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 0, 300) };
    try testing.expectError(error.TooLarge, measure(walker, &.{.{ .positions = &deep, .indices = &.{ 0, 1, 2 } }}));
    // 65,535 cells of 1 cm is 655 m of height.
    var fine = walker;
    fine.cell_height = 0.01;
    const tall = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 700, 1) };
    try testing.expectError(error.TooLarge, measure(fine, &.{.{ .positions = &tall, .indices = &.{ 0, 1, 2 } }}));

    const many = [_]Source{floor} ** (max_sources + 1);
    try testing.expectError(error.TooLarge, measure(walker, &many));

    // The counts are compared before any position is read, so zeroed buffers suffice.
    const gpa = testing.allocator;
    const indices = try gpa.alloc(u32, (max_triangles + 1) * 3);
    defer gpa.free(indices);
    @memset(indices, 0);
    try testing.expectError(error.TooLarge, measure(walker, &.{.{ .positions = &floor_positions, .indices = indices }}));
    const positions = try gpa.alloc(Vec3, max_positions / 2 + 1);
    defer gpa.free(positions);
    @memset(positions, .zero);
    const half: Source = .{ .positions = positions, .indices = &floor_indices };
    try testing.expectError(error.TooLarge, measure(walker, &.{ half, half }));
}
