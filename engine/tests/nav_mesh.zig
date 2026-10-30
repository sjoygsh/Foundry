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
const Vec3 = @import("core").math.Vec3;

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

/// A recipe's volumes and links as the builder takes them, the costs given.
fn convertFeatures(s: *const Settings, costs: []const f32, volumes: []nav.Volume, links: []nav.LinkInput) nav.Features {
    var ids: [asset.nav_mesh.max_areas]@import("core").ContentId = undefined;
    const areas = s.areas(&ids);
    for (s.volumes(), volumes[0..s.volumes().len]) |v, *out| {
        var at: u8 = 0;
        for (areas, 1..) |id, i| {
            if (id.eql(v.area)) at = @intCast(i);
        }
        out.* = .{ .area = at, .min = v.min, .max = v.max };
    }
    for (s.links(), links[0..s.links().len]) |l, *out| {
        out.* = .{ .kind = @enumFromInt(@intFromEnum(l.kind)), .from = l.from, .to = l.to, .two_way = l.two_way, .cost = l.cost, .snap = l.snap, .arc = l.arc };
    }
    return .{ .costs = costs, .volumes = volumes[0..s.volumes().len], .links = links[0..s.links().len] };
}

fn featureRefusal(problem: nav.features.Problem) asset.nav_mesh.Refusal {
    return switch (problem) {
        .volume_box => error.InvalidVolumeBox,
        .link_ends => error.InvalidLinkEnds,
        .link_cost => error.InvalidLinkCost,
        .link_snap => error.InvalidLinkSnap,
        .link_arc => error.InvalidLinkArc,
        // A record's own numbering cannot produce these; `asset` has no such refusal.
        .area_cost, .too_many_areas, .volume_area, .too_many_volumes, .too_many_links => unreachable,
    };
}

fn agreeFeatures(s: Settings) !void {
    var volumes: [nav.max_volumes]nav.Volume = undefined;
    var links: [nav.max_links]nav.LinkInput = undefined;
    const features = convertFeatures(&s, &.{ 1, 2 }, &volumes, &links);
    const recorded: ?asset.nav_mesh.Refusal = if (s.validate()) |_| null else |err| err;
    if (features.problem()) |problem| {
        try testing.expectEqual(@as(?asset.nav_mesh.Refusal, featureRefusal(problem)), recorded);
    } else {
        try testing.expectEqual(@as(?asset.nav_mesh.Refusal, null), recorded);
    }
}

test "the record and the builder hold the same limits" {
    try testing.expectEqual(nav.max_volumes, asset.nav_mesh.max_volumes);
    try testing.expectEqual(nav.max_links, asset.nav_mesh.max_links);
    try testing.expectEqual(nav.max_areas, asset.nav_mesh.max_areas + 1);
    try testing.expectEqual(nav.max_coordinate, asset.nav_mesh.max_coordinate);
    try testing.expectEqual(nav.features.min_link_length, asset.nav_mesh.min_link_length);
    try testing.expectEqual(nav.features.max_area_cost, asset.nav_mesh.max_area_cost);
    try testing.expectEqual(nav.features.max_link_cost, asset.nav_mesh.max_link_cost);
    // A link's written defaults are the builder's.
    const defaults: nav.LinkInput = .{ .kind = .jump, .from = .zero, .to = .zero };
    const written: asset.nav_mesh.Link = .{};
    try testing.expectEqual(defaults.two_way, written.two_way);
    try testing.expectEqual(defaults.cost, written.cost);
    try testing.expectEqual(defaults.snap, written.snap);
    try testing.expectEqual(defaults.arc, written.arc);
    // The kinds are one enumeration, in one order, in both modules.
    for (std.meta.fieldNames(asset.nav_mesh.LinkKind), std.meta.fieldNames(nav.LinkKind)) |a, b| try testing.expectEqualStrings(a, b);
}

test "the record and the builder refuse the same volumes and links at the same values" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const coordinates = [_]f32{ -8192.5, -8192, -1, 0, 0.05, 0.1, 0.2, 1, 8192, 8192.5, nan, inf };
    const amounts = [_]f32{ -1, -0.01, 0, 0.04, 0.05, 0.5, 1, 4.99, 5, 5.01, 9.99, 10, 10.01, 999, 1000, 1001, nan, inf };
    for (coordinates) |lo| for (coordinates) |hi| {
        var s = walker();
        s.volume_buffer[0] = .{ .area = .fromString("t:a"), .min = .init(lo, 0, 0), .max = .init(hi, 1, 1) };
        s.volume_count = 1;
        try agreeFeatures(s);
        s.volume_count = 0;
        s.link_buffer[0] = .{ .from = .init(lo, 0, 0), .to = .init(hi, 0, 0) };
        s.link_count = 1;
        try agreeFeatures(s);
    };
    for (amounts) |v| {
        for (0..3) |which| {
            var s = walker();
            s.link_buffer[0] = .{ .from = .zero, .to = Vec3.init(1, 0, 0) };
            s.link_count = 1;
            switch (which) {
                0 => s.link_buffer[0].cost = v,
                1 => s.link_buffer[0].snap = v,
                else => s.link_buffer[0].arc = v,
            }
            try agreeFeatures(s);
        }
    }
}
