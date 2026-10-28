//! A `foundry:nav_mesh` record's rules against the builder's own.
//!
//! `asset` refuses a recipe where it is compiled and loaded, and `nav` refuses a `Config` it is
//! asked to build. ADR-0069 keeps the two modules apart, so each states the rules itself; this
//! stands above both and fails if they disagree on a default or on a refusal at any boundary.

const std = @import("std");
const asset = @import("asset");
const nav = @import("nav");

const testing = std.testing;
const Settings = asset.nav_mesh.Settings;
const Field = nav.Config.Field;

/// Field for field, as a game converts a decoded recipe (`navigation.md` §7).
fn convert(s: *const Settings) nav.Config {
    var out: nav.Config = undefined;
    inline for (std.meta.fields(nav.Config)) |f| @field(out, f.name) = @field(s, f.name);
    return out;
}

/// The record's refusal for each of the builder's fields.
fn refusalFor(field: Field) asset.nav_mesh.Refusal {
    return switch (field) {
        .agent_radius => error.InvalidAgentRadius,
        .agent_height => error.InvalidAgentHeight,
        .agent_climb => error.InvalidAgentClimb,
        .agent_slope => error.InvalidAgentSlope,
        .cell_size => error.InvalidCellSize,
        .cell_height => error.InvalidCellHeight,
        .region_min_area => error.InvalidRegionMinArea,
        .region_merge_area => error.InvalidRegionMergeArea,
        .edge_max_length => error.InvalidEdgeMaxLength,
        .edge_max_error => error.InvalidEdgeMaxError,
        .polygon_max_vertices => error.InvalidPolygonMaxVertices,
        .detail_sample_distance => error.InvalidDetailSampleDistance,
        .detail_max_error => error.InvalidDetailMaxError,
    };
}

fn walker() Settings {
    var s: Settings = .{ .agent_radius = 0.3, .agent_height = 1.8, .agent_climb = 0.35, .agent_slope = 0.785398 };
    s.source_buffer[0] = .fromString("t:level");
    s.source_count = 1;
    return s;
}

/// Both answers for one value: the record's refusal and the builder's field, which must name
/// the same thing or both be null.
fn agree(s: Settings) !void {
    const built = convert(&s).invalidField();
    const recorded: ?asset.nav_mesh.Refusal = if (s.validate()) |_| null else |err| err;
    if (built) |field| {
        try testing.expectEqual(@as(?asset.nav_mesh.Refusal, refusalFor(field)), recorded);
    } else {
        try testing.expectEqual(@as(?asset.nav_mesh.Refusal, null), recorded);
    }
}

test "a recipe's defaults are the builder's defaults" {
    const s = walker();
    const c = convert(&s);
    const defaults: nav.Config = .{ .agent_radius = 0.3, .agent_height = 1.8, .agent_climb = 0.35, .agent_slope = 0.785398 };
    try testing.expectEqual(defaults, c);
    try testing.expectEqual(nav.max_polygon_vertices, asset.nav_mesh.max_polygon_vertices);
    // The schema's written defaults are the value's.
    for (asset.nav_mesh.nav_mesh.fields) |field| {
        const default = switch (field.presence) {
            .default => |d| d,
            else => continue,
        };
        inline for (std.meta.fields(nav.Config)) |f| {
            if (std.mem.eql(u8, f.name, field.name)) {
                const want: f64 = switch (default) {
                    .float => |v| v,
                    .int => |v| @floatFromInt(v),
                    else => return error.TestUnexpectedResult,
                };
                const have: f64 = switch (@typeInfo(f.type)) {
                    .float => @field(c, f.name),
                    else => @floatFromInt(@field(c, f.name)),
                };
                try testing.expectApproxEqAbs(want, have, 1e-6);
            }
        }
    }
}

test "the record and the builder refuse the same fields at the same values" {
    const nan = std.math.nan(f32);
    const floats = [_]f32{ -1, -0.01, 0, 0.005, 0.01, 0.05, 0.09, 0.1, 0.5, 0.6, 0.9, 1, 1.5, 1.5708, 1.8, 1.81, 2, 3, 3.01, 4.99, 5, 5.01, 10, 10.01, 99, 100, 100.1, 10_000, 10_001, nan, std.math.inf(f32) };
    inline for (std.meta.fields(nav.Config)) |f| {
        switch (@typeInfo(f.type)) {
            .float => for (floats) |v| {
                var s = walker();
                @field(s, f.name) = v;
                try agree(s);
            },
            else => for ([_]u32{ 0, 2, 3, 4, 6, 7, 100 }) |v| {
                var s = walker();
                @field(s, f.name) = v;
                try agree(s);
            },
        }
    }
}
