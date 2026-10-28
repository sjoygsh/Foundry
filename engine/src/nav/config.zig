//! What a build is asked for: the agent, the voxel resolution and the simplification
//! (`navigation.md` §4). The same quantities, with the same bounds, as `foundry:nav_mesh`,
//! which `asset` decodes; the integration test `nav_mesh.zig` holds the two in step, since
//! neither module can name the other.

const std = @import("std");

/// The most vertices a polygon may have. A record may ask for fewer, never more.
pub const max_polygon_vertices: u32 = 6;

pub const Config = struct {
    /// How far a wall must be from the agent's centre, metres.
    agent_radius: f32,
    /// The clearance it needs above the floor, metres.
    agent_height: f32,
    /// The tallest step it walks up or down, metres. The controller's `step_height`.
    agent_climb: f32,
    /// The steepest walkable floor, radians. The controller's `max_slope`.
    agent_slope: f32,
    /// The horizontal voxel, metres.
    cell_size: f32 = 0.1,
    /// The vertical voxel, metres.
    cell_height: f32 = 0.05,
    /// A region smaller than this, with no neighbour, is dropped. Square metres.
    region_min_area: f32 = 0.5,
    /// A region smaller than this merges into a neighbour. Square metres.
    region_merge_area: f32 = 4,
    /// Longer boundary edges are split; 0 is no limit. Metres.
    edge_max_length: f32 = 6,
    /// How far a simplified boundary may stray from the voxels', metres.
    edge_max_error: f32 = 0.13,
    polygon_max_vertices: u32 = max_polygon_vertices,
    /// Spacing of the detail mesh's height samples; 0 is none. Metres.
    detail_sample_distance: f32 = 0.6,
    /// How far the detail surface may stray from the voxels', metres.
    detail_max_error: f32 = 0.05,

    /// Each field, so a refusal can say which.
    pub const Field = enum {
        agent_radius,
        agent_height,
        agent_climb,
        agent_slope,
        cell_size,
        cell_height,
        region_min_area,
        region_merge_area,
        edge_max_length,
        edge_max_error,
        polygon_max_vertices,
        detail_sample_distance,
        detail_max_error,
    };

    /// The first field out of its bounds, in declaration order, or null if all are within
    /// them. A field whose bound depends on another (height on radius, climb on height) is
    /// reported as the dependent one.
    pub fn invalidField(c: Config) ?Field {
        if (!within(c.agent_radius, 0, 5)) return .agent_radius;
        if (!within(c.agent_height, 0.1, 10) or c.agent_height < 2 * c.agent_radius) return .agent_height;
        if (!within(c.agent_climb, 0, c.agent_height)) return .agent_climb;
        if (!std.math.isFinite(c.agent_slope) or c.agent_slope <= 0 or c.agent_slope >= std.math.pi / 2.0) return .agent_slope;
        if (!within(c.cell_size, 0.01, 1)) return .cell_size;
        if (!within(c.cell_height, 0.01, 1)) return .cell_height;
        if (!within(c.region_min_area, 0, 10_000)) return .region_min_area;
        if (!within(c.region_merge_area, 0, 10_000)) return .region_merge_area;
        if (!within(c.edge_max_length, 0, 100)) return .edge_max_length;
        if (!within(c.edge_max_error, 0.01, 3)) return .edge_max_error;
        if (c.polygon_max_vertices < 3 or c.polygon_max_vertices > max_polygon_vertices) return .polygon_max_vertices;
        if (!within(c.detail_sample_distance, 0, 10) or
            (c.detail_sample_distance != 0 and c.detail_sample_distance < 0.1)) return .detail_sample_distance;
        if (!within(c.detail_max_error, 0, 1)) return .detail_max_error;
        return null;
    }

    pub fn valid(c: Config) bool {
        return c.invalidField() == null;
    }
};

fn within(value: f32, lo: f32, hi: f32) bool {
    return std.math.isFinite(value) and value >= lo and value <= hi;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

/// The sandbox walker's agent, with every other field at its default.
pub const walker: Config = .{ .agent_radius = 0.3, .agent_height = 1.8, .agent_climb = 0.35, .agent_slope = 0.785398 };

test "the defaults and a walker's agent are valid" {
    try testing.expectEqual(@as(?Config.Field, null), walker.invalidField());
    // Each bound is inclusive where §4 says so.
    var edge = walker;
    edge.agent_radius = 0;
    edge.cell_size = 0.01;
    edge.cell_height = 1;
    edge.edge_max_length = 0;
    edge.polygon_max_vertices = 3;
    edge.detail_sample_distance = 0;
    edge.detail_max_error = 0;
    try testing.expect(edge.valid());
    edge.agent_climb = edge.agent_height;
    edge.detail_sample_distance = 0.1;
    try testing.expect(edge.valid());
}

test "every field out of bounds is refused by name" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const cases = [_]struct { field: Config.Field, values: []const f32 }{
        .{ .field = .agent_radius, .values = &.{ -0.01, 5.01, nan, inf } },
        .{ .field = .agent_height, .values = &.{ 0.09, 10.01, 0.5, nan } },
        .{ .field = .agent_climb, .values = &.{ -0.01, 1.81, nan } },
        .{ .field = .agent_slope, .values = &.{ 0, -0.1, std.math.pi / 2.0, 2, nan } },
        .{ .field = .cell_size, .values = &.{ 0.009, 1.01, nan } },
        .{ .field = .cell_height, .values = &.{ 0.009, 1.01, inf } },
        .{ .field = .region_min_area, .values = &.{ -1, 10_001, nan } },
        .{ .field = .region_merge_area, .values = &.{ -1, 10_001, nan } },
        .{ .field = .edge_max_length, .values = &.{ -0.1, 100.1, nan } },
        .{ .field = .edge_max_error, .values = &.{ 0.009, 3.01, nan } },
        .{ .field = .detail_sample_distance, .values = &.{ -0.1, 0.05, 10.1, nan } },
        .{ .field = .detail_max_error, .values = &.{ -0.01, 1.01, nan } },
    };
    inline for (cases) |case| for (case.values) |value| {
        var c = walker;
        @field(c, @tagName(case.field)) = value;
        try testing.expectEqual(@as(?Config.Field, case.field), c.invalidField());
    };
    for ([_]u32{ 0, 2, 7, 100 }) |n| {
        var c = walker;
        c.polygon_max_vertices = n;
        try testing.expectEqual(@as(?Config.Field, .polygon_max_vertices), c.invalidField());
    }
}
