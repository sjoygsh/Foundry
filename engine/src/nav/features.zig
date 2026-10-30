//! What a build may mark and attach besides the agent: area volumes and off-mesh links
//! (`docs/design/agents.md` §3, §4). The same quantities, with the same bounds, as
//! `foundry:nav_mesh` version 2, which `asset` decodes; the integration test `nav_mesh.zig`
//! holds the two in step, since neither module can name the other.

const std = @import("std");
const core = @import("core");

const input = @import("input.zig");

const Vec3 = core.math.Vec3;

/// Indices a mesh's areas may take: 0, unmarked floor, and eight a recipe may name.
pub const max_areas: usize = 9;
pub const max_volumes: usize = 32;
pub const max_links: usize = 64;
pub const min_link_length: f32 = 0.1;
pub const max_area_cost: f32 = 1000;
pub const max_link_cost: f32 = 1000;

pub const LinkKind = enum(u8) { jump, drop, ladder };

pub const Volume = struct {
    /// An index into `Features.costs`, above 0.
    area: u8,
    min: Vec3,
    max: Vec3,
};

pub const LinkInput = struct {
    kind: LinkKind,
    from: Vec3,
    to: Vec3,
    two_way: bool = false,
    /// Extra metres charged for crossing it.
    cost: f32 = 0,
    /// How far each end may be from a polygon, metres.
    snap: f32 = 0.5,
    /// A jump's height above the higher end, metres.
    arc: f32 = 0.5,
};

pub const Features = struct {
    /// Each area's cost, by index; index 0 is unmarked floor. Empty with no volumes.
    costs: []const f32 = &.{},
    volumes: []const Volume = &.{},
    links: []const LinkInput = &.{},

    /// The first thing out of its bounds, or null if all are within them.
    pub fn problem(f: Features) ?Problem {
        if (f.costs.len > max_areas) return .too_many_areas;
        if (f.volumes.len > max_volumes) return .too_many_volumes;
        if (f.links.len > max_links) return .too_many_links;
        for (f.costs) |c| if (!within(c, 1, max_area_cost)) return .area_cost;
        for (f.volumes) |v| {
            if (v.area == 0 or v.area >= f.costs.len) return .volume_area;
            if (!pointValid(v.min) or !pointValid(v.max) or v.min.x >= v.max.x or v.min.y >= v.max.y or v.min.z >= v.max.z) return .volume_box;
        }
        for (f.links) |l| {
            if (!pointValid(l.from) or !pointValid(l.to) or l.to.sub(l.from).length() < min_link_length) return .link_ends;
            if (!within(l.cost, 0, max_link_cost)) return .link_cost;
            if (!within(l.snap, 0.05, 5)) return .link_snap;
            if (!within(l.arc, 0, 10)) return .link_arc;
        }
        return null;
    }
};

pub const Problem = enum {
    too_many_areas,
    too_many_volumes,
    too_many_links,
    area_cost,
    volume_area,
    volume_box,
    link_ends,
    link_cost,
    link_snap,
    link_arc,
};

fn within(value: f32, lo: f32, hi: f32) bool {
    return std.math.isFinite(value) and value >= lo and value <= hi;
}

fn pointValid(p: Vec3) bool {
    const m = input.max_coordinate;
    return within(p.x, -m, m) and within(p.y, -m, m) and within(p.z, -m, m);
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "no features are valid, and each problem is named" {
    try testing.expectEqual(@as(?Problem, null), (Features{}).problem());
    const box: Volume = .{ .area = 1, .min = .zero, .max = .init(1, 1, 1) };
    const link: LinkInput = .{ .kind = .jump, .from = .zero, .to = .init(1, 0, 0) };
    try testing.expectEqual(@as(?Problem, null), (Features{ .costs = &.{ 1, 4 }, .volumes = &.{box}, .links = &.{link} }).problem());

    const ten: [10]f32 = @splat(1);
    try testing.expectEqual(@as(?Problem, .too_many_areas), (Features{ .costs = &ten }).problem());
    const volumes: [33]Volume = @splat(box);
    try testing.expectEqual(@as(?Problem, .too_many_volumes), (Features{ .costs = &.{ 1, 1 }, .volumes = &volumes }).problem());
    const links: [65]LinkInput = @splat(link);
    try testing.expectEqual(@as(?Problem, .too_many_links), (Features{ .links = &links }).problem());
    try testing.expectEqual(@as(?Problem, .area_cost), (Features{ .costs = &.{ 1, 0.5 } }).problem());
    try testing.expectEqual(@as(?Problem, .area_cost), (Features{ .costs = &.{std.math.nan(f32)} }).problem());
    for ([_]u8{ 0, 2 }) |area| {
        var v = box;
        v.area = area;
        try testing.expectEqual(@as(?Problem, .volume_area), (Features{ .costs = &.{ 1, 1 }, .volumes = &.{v} }).problem());
    }
    var flat = box;
    flat.max.y = 0;
    try testing.expectEqual(@as(?Problem, .volume_box), (Features{ .costs = &.{ 1, 1 }, .volumes = &.{flat} }).problem());
    var short = link;
    short.to = .init(0.05, 0, 0);
    try testing.expectEqual(@as(?Problem, .link_ends), (Features{ .links = &.{short} }).problem());
    var cost = link;
    cost.cost = -1;
    try testing.expectEqual(@as(?Problem, .link_cost), (Features{ .links = &.{cost} }).problem());
    var snap = link;
    snap.snap = 0;
    try testing.expectEqual(@as(?Problem, .link_snap), (Features{ .links = &.{snap} }).problem());
    var arc = link;
    arc.arc = 11;
    try testing.expectEqual(@as(?Problem, .link_arc), (Features{ .links = &.{arc} }).problem());
}
