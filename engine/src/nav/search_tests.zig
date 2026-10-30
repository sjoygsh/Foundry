//! Search and string pulling (`agents.md` §5, §13, Step 3): the truth of islands and links, the
//! corners against the mesh, the length against a reference over voxels, and the cost.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const config_mod = @import("config.zig");
const features = @import("features.zig");
const funnel = @import("funnel.zig");
const heightfield = @import("heightfield.zig");
const link = @import("link.zig");
const open = @import("open.zig");
const poly = @import("poly.zig");
const scenes = @import("scenes.zig");
const search = @import("search.zig");

const testing = std.testing;
const Features = features.Features;
const Filter = search.Filter;
const Mesh = poly.Mesh;
const Query = search.Query;
const Step = search.Step;
const Vec3 = core.math.Vec3;
const walker = config_mod.walker;
const gpa = testing.allocator;

fn built(scene: *scenes.Scene, f: Features) !Mesh {
    return poly.buildWith(gpa, walker, scene.sources(), f);
}

fn on(m: *const Mesh, x: f32, y: f32, z: f32) !@import("locate.zig").Located {
    return m.locate(.init(x, y, z), .init(0.2, 0.3, 0.2)) orelse error.NotOnMesh;
}

/// A query and room for a path.
const Run = struct {
    query: Query,
    steps: [256]Step = undefined,
    points: [64]funnel.Corner = undefined,

    fn init() !Run {
        return .{ .query = try Query.init(gpa, 4096) };
    }

    fn deinit(self: *Run) void {
        self.query.deinit();
    }

    fn path(self: *Run, m: *const Mesh, filter: *const Filter, a: @import("locate.zig").Located, b: @import("locate.zig").Located) search.Path {
        return self.query.find(m, filter, a, b, &self.steps);
    }

    fn corners(self: *Run, m: *const Mesh, from: Vec3, p: search.Path) []funnel.Corner {
        return funnel.corners(m, self.steps[0..p.count], from, p.end, &self.points);
    }
};

/// Whether `b` is reached from `a` by neighbours and links in their directions.
fn reachable(m: *const Mesh, a: u32, b: u32) !bool {
    const seen = try gpa.alloc(bool, m.polygons.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    seen[a] = true;
    try stack.append(gpa, a);
    while (stack.pop()) |p| {
        if (p == b) return true;
        const polygon = &m.polygons[p];
        for (polygon.neighbours[0..polygon.count]) |q| {
            if (q == poly.none_polygon or seen[q]) continue;
            seen[q] = true;
            try stack.append(gpa, q);
        }
        for (m.linksFrom(p)) |li| {
            const l = m.links[li];
            const q = if (l.from_polygon == p) l.to_polygon else l.from_polygon;
            if (seen[q]) continue;
            seen[q] = true;
            try stack.append(gpa, q);
        }
    }
    return false;
}

/// Every point along `from` and the corners is over the mesh, sampled every 5 cm: the line never
/// leaves it, not even at a corner.
fn expectOnMesh(m: *const Mesh, from: Vec3, corners: []const funnel.Corner) !void {
    var a = from;
    for (corners, 0..) |c, i| {
        const d = c.point.sub(a);
        const length = @sqrt(d.x * d.x + d.z * d.z);
        const samples: u32 = @intFromFloat(@ceil(length / 0.05));
        for (0..samples + 1) |s| {
            const t = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(@max(samples, 1)));
            const p = a.add(d.scale(t));
            if (m.locate(p, .init(0.03, 1.5, 0.03)) == null) return error.LeftTheMesh;
        }
        a = c.point;
        if (c.link != link.none_link) {
            const l = m.links[c.link];
            a = if (c.reversed) l.from else l.to;
        }
        _ = i;
    }
}

fn lengthOf(from: Vec3, corners: []const funnel.Corner) f32 {
    var total: f32 = 0;
    var a = from;
    for (corners) |c| {
        const d = c.point.sub(a);
        total += @sqrt(d.x * d.x + d.z * d.z);
        a = c.point;
    }
    return total;
}

// -- search -----------------------------------------------------------------------------

test "a straight floor is one polygon's walk, and a start in the goal's polygon is one step" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    const a = try on(&m, 2, 0, 2);
    const p = run.path(&m, &f, a, a);
    try testing.expectEqual(@as(u32, 1), p.count);
    try testing.expect(p.complete);
    const b = try on(&m, 8, 0, 8);
    const q = run.path(&m, &f, a, b);
    try testing.expect(q.complete and q.count >= 1);
    try testing.expectEqual(a.polygon, run.steps[0].polygon);
    try testing.expectEqual(b.polygon, run.steps[q.count - 1].polygon);
    const c = run.corners(&m, a.point, q);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqual(b.point, c[0].point);
}

test "a path is complete exactly when islands and links say so" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(5, 0, 5), false);
    scene.floor(.init(7, 0, 0), .init(12, 0, 5), false);
    scene.floor(.init(14, 0, 0), .init(19, 0, 5), false);
    var one_way = try built(&scene, .{ .links = &.{.{ .kind = .jump, .from = .init(4.5, 0, 2.5), .to = .init(7.5, 0, 2.5), .snap = 1 }} });
    defer one_way.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    const west = try on(&one_way, 2, 0, 2);
    const middle = try on(&one_way, 9, 0, 2);
    const east = try on(&one_way, 16, 0, 2);
    try testing.expect(run.path(&one_way, &f, west, middle).complete);
    // Against a one-way link: the nearest it gets is its own island's edge.
    const back = run.path(&one_way, &f, middle, west);
    try testing.expect(!back.complete and back.count >= 1);
    try testing.expect(back.end.x > 7 - 0.1 and back.end.x < 8);
    // No link at all.
    const far = run.path(&one_way, &f, west, east);
    try testing.expect(!far.complete);
    try testing.expect(far.end.x > 7 and far.end.x < 12.1);

    var two_way = try built(&scene, .{ .links = &.{.{ .kind = .jump, .from = .init(4.5, 0, 2.5), .to = .init(7.5, 0, 2.5), .snap = 1, .two_way = true }} });
    defer two_way.deinit(gpa);
    const w2 = try on(&two_way, 2, 0, 2);
    const m2 = try on(&two_way, 9, 0, 2);
    const p = run.path(&two_way, &f, m2, w2);
    try testing.expect(p.complete);
    var crossed = false;
    for (run.steps[0..p.count]) |s| {
        if (s.link != link.none_link) {
            crossed = true;
            try testing.expect(s.reversed);
        }
    }
    try testing.expect(crossed);
}

test "the truth table of every pair of polygons on the course and the yard" {
    const links = [_]features.LinkInput{
        .{ .kind = .ladder, .from = .init(1, 0, 1), .to = .init(2.7, 0.6, 2.5), .two_way = true },
        .{ .kind = .drop, .from = .init(2.7, 0.6, 2.5), .to = .init(4.5, 0, 2.5) },
    };
    for (0..2) |which| {
        var scene: scenes.Scene = .{};
        if (which == 0) scene.course() else scene.yard();
        var m = try built(&scene, if (which == 0) .{ .links = &links } else .{});
        defer m.deinit(gpa);
        var run = try Run.init();
        defer run.deinit();
        const f: Filter = .{};
        for (0..m.polygons.len) |a| for (0..m.polygons.len) |b| {
            const from: u32 = @intCast(a);
            const to: u32 = @intCast(b);
            const pa = m.position(m.polygons[a].vertices[0]);
            const pb = m.position(m.polygons[b].vertices[0]);
            const p = run.path(&m, &f, .{ .polygon = from, .point = pa }, .{ .polygon = to, .point = pb });
            try testing.expectEqual(try reachable(&m, from, to), p.complete);
        };
    }
}

test "an area's cost moves a path off it only when the detour is cheaper" {
    // A band of area across the floor, with a way round it at the far end.
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 8), false);
    const band: features.Volume = .{ .area = 1, .min = .init(5, -1, 0), .max = .init(7, 1, 6) };
    const a: Vec3 = .init(2, 0, 2);
    const b: Vec3 = .init(10, 0, 2);
    var cheap = try built(&scene, .{ .costs = &.{ 1, 1.1 }, .volumes = &.{band} });
    defer cheap.deinit(gpa);
    var dear = try built(&scene, .{ .costs = &.{ 1, 50 }, .volumes = &.{band} });
    defer dear.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    const crosses = struct {
        fn check(m: *const Mesh, steps: []const Step) bool {
            for (steps) |s| {
                if (m.polygons[s.polygon].area == 1) return true;
            }
            return false;
        }
    }.check;
    const near = run.path(&cheap, &f, try on(&cheap, a.x, a.y, a.z), try on(&cheap, b.x, b.y, b.z));
    try testing.expect(near.complete and crosses(&cheap, run.steps[0..near.count]));
    const round = run.path(&dear, &f, try on(&dear, a.x, a.y, a.z), try on(&dear, b.x, b.y, b.z));
    try testing.expect(round.complete and !crosses(&dear, run.steps[0..round.count]));
    // The filter scales it, for this search only.
    var scaled: Filter = .{};
    scaled.area_scale[1] = 100;
    const by_filter = run.path(&cheap, &scaled, try on(&cheap, a.x, a.y, a.z), try on(&cheap, b.x, b.y, b.z));
    try testing.expect(by_filter.complete and !crosses(&cheap, run.steps[0..by_filter.count]));
}

test "a link's cost is charged: too dear, and the walk round is taken" {
    // Two floors joined by a bridge at the far end, and a link across the gap at this end.
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(5, 0, 12), false);
    scene.floor(.init(7, 0, 0), .init(12, 0, 12), false);
    scene.floor(.init(5, 0, 10), .init(7, 0, 12), false);
    const across: features.LinkInput = .{ .kind = .jump, .from = .init(4.5, 0, 1), .to = .init(7.5, 0, 1), .snap = 1 };
    var free = try built(&scene, .{ .links = &.{across} });
    defer free.deinit(gpa);
    var dear_link = across;
    dear_link.cost = 100;
    var dear = try built(&scene, .{ .links = &.{dear_link} });
    defer dear.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    const crossings = struct {
        fn count(steps: []const Step) u32 {
            var n: u32 = 0;
            for (steps) |s| n += @intFromBool(s.link != link.none_link);
            return n;
        }
    }.count;
    const short = run.path(&free, &f, try on(&free, 2, 0, 1), try on(&free, 10, 0, 1));
    try testing.expect(short.complete);
    try testing.expectEqual(@as(u32, 1), crossings(run.steps[0..short.count]));
    const long = run.path(&dear, &f, try on(&dear, 2, 0, 1), try on(&dear, 10, 0, 1));
    try testing.expect(long.complete);
    try testing.expectEqual(@as(u32, 0), crossings(run.steps[0..long.count]));
}

test "a filter excludes an area and a kind of link, and an invalid one is refused" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(5, 0, 5), false);
    scene.floor(.init(7, 0, 0), .init(12, 0, 5), false);
    var m = try built(&scene, .{
        .costs = &.{ 1, 2 },
        .volumes = &.{.{ .area = 1, .min = .init(8, -1, 0), .max = .init(9, 1, 5) }},
        .links = &.{.{ .kind = .ladder, .from = .init(4.5, 0, 2.5), .to = .init(7.5, 0, 2.5), .snap = 1 }},
    });
    defer m.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const a = try on(&m, 2, 0, 2);
    const b = try on(&m, 7.5, 0, 2);
    const c = try on(&m, 11, 0, 2);
    var f: Filter = .{};
    try testing.expect(run.path(&m, &f, a, c).complete);
    f.excluded_links = 1 << @intFromEnum(features.LinkKind.ladder);
    try testing.expect(!run.path(&m, &f, a, b).complete);
    f = .{ .area_scale = @splat(1) };
    f.area_scale[1] = 0;
    // Round the band there is no way, because it crosses the whole floor.
    try testing.expect(!run.path(&m, &f, a, c).complete);
    try testing.expect(run.path(&m, &f, a, b).complete);
    // A start inside an excluded area may still walk out of it.
    try testing.expect(run.path(&m, &f, try on(&m, 8.5, 0, 2), b).complete);
    for ([_]f32{ 0.5, -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        f.area_scale[1] = bad;
        try testing.expectEqual(@as(u32, 0), run.path(&m, &f, a, c).count);
    }
}

test "a search refuses what is not on the mesh, and its bounds answer a partial path" {
    var scene: scenes.Scene = .{};
    scene.yard();
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    const a = try on(&m, 3, 0, 2);
    const b = try on(&m, 27, 0, 18);
    try testing.expectEqual(@as(u32, 0), run.path(&m, &f, .{ .polygon = 99_999, .point = a.point }, b).count);
    try testing.expectEqual(@as(u32, 0), run.path(&m, &f, a, .{ .polygon = 99_999, .point = b.point }).count);
    try testing.expectEqual(@as(u32, 0), run.path(&m, &f, .{ .polygon = 0, .point = .init(std.math.nan(f32), 0, 0) }, b).count);
    try testing.expectEqual(@as(u32, 0), run.query.find(&m, &f, a, b, run.steps[0..0]).count);

    // Too few nodes: partial, starting where it should, and well-formed.
    var small = try Query.init(gpa, 4);
    defer small.deinit();
    const partial = small.find(&m, &f, a, b, &run.steps);
    try testing.expect(!partial.complete and partial.count >= 1 and partial.count <= 4);
    try testing.expectEqual(a.polygon, run.steps[0].polygon);
    // Too little room: the path's own start, and not complete.
    const whole = run.path(&m, &f, a, b);
    try testing.expect(whole.complete and whole.count > 2);
    var first: [2]Step = undefined;
    const cut = run.query.find(&m, &f, a, b, &first);
    try testing.expect(!cut.complete);
    try testing.expectEqual(@as(u32, 2), cut.count);
    try testing.expectEqual(run.steps[0], first[0]);
    try testing.expectEqual(run.steps[1], first[1]);

    try testing.expectError(error.InvalidNodes, Query.init(gpa, 0));
    try testing.expectError(error.InvalidNodes, Query.init(gpa, search.max_query_nodes + 1));
}

test "the same search gives the same path, whatever came before it" {
    var scene: scenes.Scene = .{};
    scene.yard();
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    const a = try on(&m, 3, 0, 2);
    const b = try on(&m, 27, 0, 18);
    const p = run.path(&m, &f, a, b);
    var first: [256]Step = undefined;
    @memcpy(first[0..p.count], run.steps[0..p.count]);
    _ = run.path(&m, &f, b, try on(&m, 10, 0, 6));
    const again = run.path(&m, &f, a, b);
    try testing.expectEqual(p.count, again.count);
    try testing.expectEqualSlices(Step, first[0..p.count], run.steps[0..p.count]);
}

// -- string pulling ---------------------------------------------------------------------

test "a corner is pulled tight round a wall, and never leaves the mesh" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 12), false);
    scene.box(.init(5, 0, 0), .init(6, 2, 9));
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    const a = try on(&m, 2, 0, 3);
    const b = try on(&m, 10, 0, 3);
    const p = run.path(&m, &f, a, b);
    try testing.expect(p.complete);
    const c = run.corners(&m, a.point, p);
    try testing.expect(c.len >= 2);
    try expectOnMesh(&m, a.point, c);
    // Round the wall's end, 0.3 m clear of it, and no further: the exact answer is two straight
    // lines round its two corners.
    const exact = @sqrt(2.7 * 2.7 + 6.3 * 6.3) + 1.6 + @sqrt(3.7 * 3.7 + 6.3 * 6.3);
    try testing.expectApproxEqAbs(exact, lengthOf(a.point, c), 0.3);
    // A corner is drawn in from the wall's own vertex by a hair, never onto it.
    for (c[0 .. c.len - 1]) |corner| {
        var nearest = std.math.inf(f32);
        for (0..m.vertices.len) |v| {
            const d = m.position(@intCast(v)).sub(corner.point);
            nearest = @min(nearest, @sqrt(d.x * d.x + d.z * d.z));
        }
        try testing.expect(nearest > 0.001 and nearest <= 0.021);
    }
}

test "a path through a link has a corner at each end of it" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(5, 0, 5), false);
    scene.floor(.init(7, 0, 0), .init(12, 0, 5), false);
    var m = try built(&scene, .{ .links = &.{.{ .kind = .jump, .from = .init(4.5, 0, 2.5), .to = .init(7.5, 0, 2.5), .snap = 1, .two_way = true }} });
    defer m.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    const a = try on(&m, 1, 0, 1);
    const b = try on(&m, 11, 0, 4);
    const forward = run.path(&m, &f, a, b);
    const c = run.corners(&m, a.point, forward);
    try testing.expectEqual(@as(usize, 2), c.len);
    try testing.expectEqual(@as(u32, 0), c[0].link);
    try testing.expect(!c[0].reversed);
    try testing.expectEqual(m.links[0].from, c[0].point);
    try testing.expectEqual(b.point, c[1].point);
    try testing.expectEqual(link.none_link, c[1].link);
    try expectOnMesh(&m, a.point, c);
    const back = run.path(&m, &f, b, a);
    const d = run.corners(&m, b.point, back);
    try testing.expect(d[0].reversed);
    try testing.expectEqual(m.links[0].to, d[0].point);
}

test "corners stop when the room for them does, and a broken path stops where it breaks" {
    var scene: scenes.Scene = .{};
    scene.yard();
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    const a = try on(&m, 3, 0, 2);
    const b = try on(&m, 27, 0, 18);
    const p = run.path(&m, &f, a, b);
    const all = run.corners(&m, a.point, p);
    try testing.expect(all.len >= 2);
    var one: [1]funnel.Corner = undefined;
    const first = funnel.corners(&m, run.steps[0..p.count], a.point, p.end, &one);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqual(all[0].point, first[0].point);
    // Two polygons that do not touch.
    var far = a.polygon;
    for (m.polygons, 0..) |poly_p, i| {
        if (std.mem.indexOfScalar(u32, poly_p.neighbours[0..poly_p.count], a.polygon) == null and i != a.polygon) far = @intCast(i);
    }
    const broken = [_]Step{ .{ .polygon = a.polygon }, .{ .polygon = far } };
    try testing.expectEqual(@as(usize, 0), funnel.corners(&m, &broken, a.point, b.point, &run.points).len);
    try testing.expectEqual(@as(usize, 0), funnel.corners(&m, &.{}, a.point, b.point, &run.points).len);
}

// -- the property, against a reference over voxels ----------------------------------------

/// Distances from one span over the eroded spans, 8-way: `step` straight, 1.414 `step` diagonally,
/// a diagonal only where both of its sides are walkable.
const Reference = struct {
    distance: []f32,

    fn init(f: *const open.OpenField, start: u32) !Reference {
        const distance = try gpa.alloc(f32, f.spans.len);
        @memset(distance, std.math.inf(f32));
        const Item = struct {
            at: u32,
            d: f32,
            fn order(_: void, a: @This(), b: @This()) std.math.Order {
                return std.math.order(a.d, b.d);
            }
        };
        var queue: std.PriorityQueue(Item, void, Item.order) = .empty;
        defer queue.deinit(gpa);
        distance[start] = 0;
        try queue.push(gpa, .{ .at = start, .d = 0 });
        const cell = f.grid.cell_size;
        while (queue.pop()) |item| {
            if (item.d > distance[item.at]) continue;
            const s = f.spans[item.at];
            for (0..4) |k| {
                const n = s.links[k];
                if (n == open.none or f.spans[n].area == open.unwalkable) continue;
                try relax(&queue, distance, n, item.d + cell);
                const n2 = f.spans[n].links[(k + 1) % 4];
                const side = s.links[(k + 1) % 4];
                if (n2 == open.none or side == open.none) continue;
                if (f.spans[n2].area == open.unwalkable or f.spans[side].area == open.unwalkable) continue;
                try relax(&queue, distance, n2, item.d + cell * 1.41421356);
            }
        }
        return .{ .distance = distance };
    }

    fn relax(queue: anytype, distance: []f32, n: u32, d: f32) !void {
        if (d < distance[n]) {
            distance[n] = d;
            try queue.push(gpa, .{ .at = n, .d = d });
        }
    }

    fn deinit(self: *Reference) void {
        gpa.free(self.distance);
    }
};

fn spanAt(f: *const open.OpenField, p: Vec3) ?u32 {
    const g = f.grid;
    const x: i64 = @intFromFloat(@floor((p.x - g.origin.x) / g.cell_size));
    const z: i64 = @intFromFloat(@floor((p.z - g.origin.z) / g.cell_size));
    if (x < 0 or z < 0 or x >= g.width or z >= g.depth) return null;
    const c = f.column(@intCast(x), @intCast(z));
    var best: ?u32 = null;
    var best_d: f32 = 0.6;
    for (c.first..c.first + c.count) |i| {
        const s = f.spans[i];
        if (s.area == open.unwalkable) continue;
        const y = g.origin.y + @as(f32, @floatFromInt(s.y)) * g.cell_height;
        if (@abs(y - p.y) < best_d) {
            best_d = @abs(y - p.y);
            best = @intCast(i);
        }
    }
    return best;
}

test "2,000 seeded paths on the yard stay on the mesh, and within 1.25 of the reference" {
    var scene: scenes.Scene = .{};
    scene.yard();
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var hf = try heightfield.solid(gpa, walker, scene.sources());
    defer hf.deinit(gpa);
    var field = try open.OpenField.init(gpa, &hf);
    defer field.deinit(gpa);
    try field.erode(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    var prng = std.Random.DefaultPrng.init(0x3333);
    const random = prng.random();

    const sample = struct {
        fn point(rng: std.Random, mesh: *const Mesh) ?@import("locate.zig").Located {
            const p: Vec3 = .init(rng.float(f32) * 30, 0, rng.float(f32) * 20);
            return mesh.locate(p, .init(0.05, 1.5, 0.05));
        }
    }.point;

    var checked: u32 = 0;
    var worst: f32 = 0;
    var starts: u32 = 0;
    while (starts < 20) {
        const a = sample(random, &m) orelse continue;
        const from = spanAt(&field, a.point) orelse continue;
        starts += 1;
        var reference = try Reference.init(&field, from);
        defer reference.deinit();
        var goals: u32 = 0;
        var tries: u32 = 0;
        while (goals < 100 and tries < 1000) : (tries += 1) {
            const b = sample(random, &m) orelse continue;
            const to = spanAt(&field, b.point) orelse continue;
            const p = run.path(&m, &f, a, b);
            const truth = reference.distance[to];
            try testing.expectEqual(try reachable(&m, a.polygon, b.polygon), p.complete);
            if (!p.complete or !std.math.isFinite(truth)) continue;
            goals += 1;
            checked += 1;
            const c = run.corners(&m, a.point, p);
            try expectOnMesh(&m, a.point, c);
            const length = lengthOf(a.point, c);
            if (truth > 1) {
                const ratio = length / truth;
                worst = @max(worst, ratio);
                try testing.expect(ratio <= 1.25);
            }
        }
    }
    try testing.expect(checked >= 1900);
    if (builtin.mode != .Debug) std.debug.print("nav paths: {d} checked, worst {d:.3} of the reference\n", .{ checked, worst });
}

// -- the cost ---------------------------------------------------------------------------

test "search time: a path and a locate on the yard, single-threaded, printed" {
    if (builtin.mode == .Debug) return error.SkipZigTest;
    var scene: scenes.Scene = .{};
    scene.yard();
    var m = try built(&scene, .{});
    defer m.deinit(gpa);
    var run = try Run.init();
    defer run.deinit();
    const f: Filter = .{};
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var pairs: [512][2]@import("locate.zig").Located = undefined;
    var n: usize = 0;
    while (n < pairs.len) {
        const a = m.locate(.init(random.float(f32) * 30, 0, random.float(f32) * 20), .init(0.05, 1.5, 0.05)) orelse continue;
        const b = m.locate(.init(random.float(f32) * 30, 0, random.float(f32) * 20), .init(0.05, 1.5, 0.05)) orelse continue;
        pairs[n] = .{ a, b };
        n += 1;
    }
    var path_ns: [512]u64 = undefined;
    var locate_ns: [512]u64 = undefined;
    var keep: u64 = 0;
    for (pairs, &path_ns, &locate_ns) |pair, *p, *l| {
        const t0 = std.Io.Clock.awake.now(testing.io);
        const found = run.path(&m, &f, pair[0], pair[1]);
        const corners = run.corners(&m, pair[0].point, found);
        const t1 = std.Io.Clock.awake.now(testing.io);
        keep +%= corners.len;
        const located = m.locate(pair[1].point, .init(0.05, 1.5, 0.05));
        const t2 = std.Io.Clock.awake.now(testing.io);
        p.* = @intCast(t1.nanoseconds - t0.nanoseconds);
        l.* = @intCast(t2.nanoseconds - t1.nanoseconds);
        keep +%= located.?.polygon;
    }
    std.mem.sort(u64, &path_ns, {}, std.sort.asc(u64));
    std.mem.sort(u64, &locate_ns, {}, std.sort.asc(u64));
    std.debug.print("nav search time ({t}): path p95 {d:.1} us, worst {d:.1} us; locate p95 {d:.1} us, over {d} polygons ({d})\n", .{
        builtin.mode,                                  @as(f64, @floatFromInt(path_ns[486])) / 1e3, @as(f64, @floatFromInt(path_ns[511])) / 1e3,
        @as(f64, @floatFromInt(locate_ns[486])) / 1e3, m.polygons.len,                              keep,
    });
}
