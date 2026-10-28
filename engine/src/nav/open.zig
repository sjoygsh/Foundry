//! The open heightfield: walkable floors, their clearance and their links, then erosion by the
//! agent's radius and the distance field the regions grow over (`navigation.md` §5.3).
//!
//! **An open span is a floor and the space above it**: the top of a walkable solid span and the
//! clearance to the next one. Spans are stored column by column, columns by Z and then X, each
//! column bottom to top, so a span's index is also its place in the one scan order every later
//! stage uses (I9).
//!
//! **A link is a neighbour the agent can step to**: in each of the four directions, the first
//! span of the neighbouring column whose floor is within the climb and whose clearance overlaps
//! the agent's height. Links are span indices, never addresses.

const std = @import("std");

const heightfield = @import("heightfield.zig");

const Allocator = std.mem.Allocator;
const Agent = heightfield.Agent;
const Grid = @import("input.zig").Grid;
const Heightfield = heightfield.Heightfield;

pub const none = heightfield.none;
pub const unwalkable = heightfield.unwalkable;
pub const walkable = heightfield.walkable;
pub const directions = heightfield.directions;

/// The clearance of a span with nothing above it.
pub const open_clearance: u16 = std.math.maxInt(u16);
/// A distance not yet measured. Every walkable span connected to a boundary ends below it.
const far: u16 = std.math.maxInt(u16);

pub const OpenSpan = struct {
    /// The floor, in cells above the grid's origin.
    y: u16,
    /// Open cells above the floor, to the next solid span, or `open_clearance`.
    clearance: u16,
    /// −X, +Z, +X, −Z, as `directions`.
    links: [4]u32 = @splat(none),
    area: u8,
    /// 0 until regions are built, and 0 for a span in no region.
    region: u16 = 0,
};

pub const Column = struct { first: u32, count: u32 };

pub const OpenField = struct {
    grid: Grid,
    agent: Agent,
    columns: []Column,
    spans: []OpenSpan,
    /// Chamfer distance to the nearest boundary, two per cell straight and three diagonally.
    /// Filled by `buildDistanceField`; empty before.
    distance: []u16 = &.{},
    max_distance: u16 = 0,

    /// The walkable spans of `hf`, linked.
    pub fn init(gpa: Allocator, hf: *const Heightfield) Allocator.Error!OpenField {
        var count: usize = 0;
        for (hf.heads) |first| {
            var i = first;
            while (i != none) : (i = hf.span(i).next) {
                if (hf.span(i).area != unwalkable) count += 1;
            }
        }
        const columns = try gpa.alloc(Column, hf.heads.len);
        errdefer gpa.free(columns);
        const spans = try gpa.alloc(OpenSpan, count);
        errdefer gpa.free(spans);

        var n: u32 = 0;
        for (hf.heads, columns) |first, *out| {
            out.* = .{ .first = n, .count = 0 };
            var i = first;
            while (i != none) : (i = hf.span(i).next) {
                const s = hf.span(i);
                if (s.area == unwalkable) continue;
                const clearance: u16 = if (s.next != none) hf.span(s.next).min - s.max else open_clearance;
                spans[n] = .{ .y = s.max, .clearance = clearance, .area = s.area };
                n += 1;
                out.count += 1;
            }
        }

        var self: OpenField = .{ .grid = hf.grid, .agent = hf.agent, .columns = columns, .spans = spans };
        self.link();
        return self;
    }

    pub fn deinit(self: *OpenField, gpa: Allocator) void {
        gpa.free(self.columns);
        gpa.free(self.spans);
        gpa.free(self.distance);
        self.* = undefined;
    }

    pub fn column(self: *const OpenField, x: u32, z: u32) Column {
        return self.columns[x + z * self.grid.width];
    }

    fn link(self: *OpenField) void {
        const climb: i32 = @intCast(self.agent.climb);
        const height: i32 = @intCast(self.agent.height);
        const w = self.grid.width;
        const d = self.grid.depth;
        for (0..d) |zi| for (0..w) |xi| {
            const c = self.columns[xi + zi * w];
            for (c.first..c.first + c.count) |i| {
                const s = self.spans[i];
                const bot: i32 = s.y;
                const top: i32 = bot + s.clearance;
                for (directions, 0..) |dir, k| {
                    const nx = @as(i64, @intCast(xi)) + dir[0];
                    const nz = @as(i64, @intCast(zi)) + dir[1];
                    if (nx < 0 or nz < 0 or nx >= w or nz >= d) continue;
                    const nc = self.columns[@as(usize, @intCast(nx)) + @as(usize, @intCast(nz)) * w];
                    for (nc.first..nc.first + nc.count) |j| {
                        const ns = self.spans[j];
                        const nbot: i32 = ns.y;
                        const ntop: i32 = nbot + ns.clearance;
                        if (@min(top, ntop) - @max(bot, nbot) >= height and @abs(nbot - bot) <= climb) {
                            self.spans[i].links[k] = @intCast(j);
                            break;
                        }
                    }
                }
            }
        };
    }

    /// The span one step from `i` in direction `k`, if it is linked and has `i`'s area.
    fn step(self: *const OpenField, i: u32, k: usize) ?u32 {
        const j = self.spans[i].links[k];
        if (j == none or self.spans[j].area != self.spans[i].area) return null;
        return j;
    }

    // -- erosion (§5.3) ---------------------------------------------------------------

    /// Removes every span nearer than the agent's radius to the surface's boundary: a span with
    /// fewer than four walkable neighbours. Distances are chamfered, two a cell straight and
    /// three diagonally, so "nearer than r cells" is "below 2r".
    pub fn erode(self: *OpenField, gpa: Allocator) Allocator.Error!void {
        if (self.agent.radius == 0) return;
        const dist = try gpa.alloc(u16, self.spans.len);
        defer gpa.free(dist);
        for (self.spans, dist, 0..) |s, *out, i| {
            out.* = if (s.area == unwalkable or self.walkableNeighbours(@intCast(i)) != 4) 0 else far;
        }
        self.chamfer(dist);
        const threshold = 2 * self.agent.radius;
        for (self.spans, dist) |*s, value| {
            if (value < threshold) s.area = unwalkable;
        }
    }

    fn walkableNeighbours(self: *const OpenField, i: u32) u32 {
        var n: u32 = 0;
        for (0..4) |k| {
            const j = self.spans[i].links[k];
            if (j != none and self.spans[j].area != unwalkable) n += 1;
        }
        return n;
    }

    /// Two passes of a 3-4 style chamfer over the links: forward over −X, −Z and their
    /// diagonals, then backward over +X, +Z and theirs. Spans are in scan order, so forward is
    /// ascending index.
    fn chamfer(self: *const OpenField, dist: []u16) void {
        for (0..self.spans.len) |i| self.relax(dist, @intCast(i), 0, 3);
        var i = self.spans.len;
        while (i > 0) {
            i -= 1;
            self.relax(dist, @intCast(i), 2, 1);
        }
    }

    /// From span `i`, its neighbours in directions `a` and `b` and the diagonals through them.
    fn relax(self: *const OpenField, dist: []u16, i: u32, a: usize, b: usize) void {
        var best: u32 = dist[i];
        // `a` then its `b`-ward neighbour, and `b` then its `(b + 3) % 4`, as Recast's pass does:
        // −X then −Z, −Z then +X forward; +X then +Z, +Z then −X backward.
        if (self.linkOf(i, a)) |n| {
            best = @min(best, @as(u32, dist[n]) + 2);
            if (self.linkOf(n, b)) |m| best = @min(best, @as(u32, dist[m]) + 3);
        }
        if (self.linkOf(i, b)) |n| {
            best = @min(best, @as(u32, dist[n]) + 2);
            if (self.linkOf(n, (b + 3) % 4)) |m| best = @min(best, @as(u32, dist[m]) + 3);
        }
        dist[i] = @intCast(@min(best, far));
    }

    fn linkOf(self: *const OpenField, i: u32, k: usize) ?u32 {
        const j = self.spans[i].links[k];
        return if (j == none) null else j;
    }

    // -- the distance field (§5.4) ----------------------------------------------------

    /// Distance from every walkable span to the nearest span with a missing or other-area
    /// neighbour, after erosion, then blurred once by a 3 × 3 box so the watershed's seeds are
    /// not split by single-cell noise.
    pub fn buildDistanceField(self: *OpenField, gpa: Allocator) Allocator.Error!void {
        const dist = try gpa.alloc(u16, self.spans.len);
        errdefer gpa.free(dist);
        const scratch = try gpa.alloc(u16, self.spans.len);
        defer gpa.free(scratch);
        for (self.spans, dist, 0..) |s, *out, i| {
            var same: u32 = 0;
            if (s.area != unwalkable) {
                for (0..4) |k| {
                    if (self.step(@intCast(i), k) != null) same += 1;
                }
            }
            out.* = if (same == 4) far else 0;
        }
        self.chamfer(dist);
        self.blur(dist, scratch);
        gpa.free(self.distance);
        self.distance = dist;
        self.max_distance = 0;
        for (dist, self.spans) |value, s| {
            if (s.area != unwalkable) self.max_distance = @max(self.max_distance, value);
        }
    }

    /// Recast's box blur with a threshold of one cell: a span within a cell of the boundary
    /// keeps its distance, and every other one takes the mean of its 3 × 3 neighbourhood, a
    /// missing neighbour counting as itself.
    fn blur(self: *const OpenField, dist: []u16, scratch: []u16) void {
        const threshold: u32 = 2;
        for (0..self.spans.len) |ii| {
            const i: u32 = @intCast(ii);
            const cd: u32 = dist[i];
            if (cd <= threshold) {
                scratch[i] = @intCast(cd);
                continue;
            }
            var sum: u32 = cd;
            for (0..4) |k| {
                if (self.linkOf(i, k)) |n| {
                    sum += dist[n];
                    sum += if (self.linkOf(n, (k + 1) % 4)) |m| dist[m] else cd;
                } else {
                    sum += cd * 2;
                }
            }
            scratch[i] = @intCast((sum + 5) / 9);
        }
        @memcpy(dist, scratch);
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const scenes = @import("scenes.zig");
const config_mod = @import("config.zig");
const walker = config_mod.walker;

pub fn openOf(gpa: Allocator, config: config_mod.Config, scene: *scenes.Scene) !OpenField {
    var hf = try heightfield.solid(gpa, config, scene.sources());
    defer hf.deinit(gpa);
    return OpenField.init(gpa, &hf);
}

/// Walkable spans along the row of columns at world `z`, counted at the floor nearest `y`.
fn walkableAcross(f: *const OpenField, z: f32, y: f32) u32 {
    const zc: u32 = @intFromFloat(@floor((z - f.grid.origin.z) / f.grid.cell_size));
    const yc: i32 = @intFromFloat(@round((y - f.grid.origin.y) / f.grid.cell_height));
    var n: u32 = 0;
    for (0..f.grid.width) |x| {
        const c = f.column(@intCast(x), zc);
        for (f.spans[c.first..][0..c.count]) |s| {
            if (s.area != unwalkable and @abs(@as(i32, s.y) - yc) <= 4) n += 1;
        }
    }
    return n;
}

test "links are symmetric, and each joins floors within the climb" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(4, 0, 4), false);
    scene.box(.init(1.05, 0, 1.05), .init(2.05, 0.15, 2.05));
    scene.box(.init(2.55, 0, 2.55), .init(3.05, 0.6, 3.05));
    var f = try openOf(gpa, walker, &scene);
    defer f.deinit(gpa);
    var links: u32 = 0;
    for (f.spans, 0..) |s, i| for (s.links, 0..) |j, k| {
        if (j == none) continue;
        links += 1;
        try testing.expectEqual(@as(u32, @intCast(i)), f.spans[j].links[(k + 2) % 4]);
        try testing.expect(@abs(@as(i32, f.spans[j].y) - @as(i32, s.y)) <= f.agent.climb);
    };
    try testing.expect(links > 0);
}

test "erosion keeps the agent's radius from every wall: corridors close and open" {
    const gpa = testing.allocator;
    // Free columns between the walls: 2r − 2 and 2r + 2, for r = 3 cells.
    for ([_]struct { free: u32, left: u32 }{ .{ .free = 4, .left = 0 }, .{ .free = 8, .left = 2 } }) |case| {
        var scene: scenes.Scene = .{};
        const w = @as(f32, @floatFromInt(case.free + 1)) * 0.1;
        // Walls half a cell off the grid, so the column holding each face is a wall column and
        // `free` whole columns lie between them.
        scene.floor(.init(-1, 0, 0), .init(w + 1, 0, 6), false);
        scene.box(.init(-1, 0, 0), .init(0.05, 1, 6));
        scene.box(.init(0.05 + w, 0, 0), .init(w + 1, 1, 6));
        var f = try openOf(gpa, walker, &scene);
        defer f.deinit(gpa);
        try testing.expectEqual(case.free, walkableAcross(&f, 3, 0));
        try f.erode(gpa);
        try testing.expectEqual(case.left, walkableAcross(&f, 3, 0));
    }
}

test "erosion grows an obstacle's hole by the radius on every side" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    scene.box(.init(4.55, 0, 4.55), .init(5.55, 3, 5.55));
    var f = try openOf(gpa, walker, &scene);
    defer f.deinit(gpa);
    try f.erode(gpa);
    // Across the floor through the pillar's middle: the floor's 100 columns, less a ring for
    // the ledge and the radius at each far edge, less the 11 columns the pillar is in and the
    // radius on each side of them. Inside the hollow pillar its 9 columns of floor, 3 m under
    // its top, are open too, and erode to 3; the regions' minimum area drops that island.
    const across = walkableAcross(&f, 5.05, 0);
    const expected: i32 = 100 - 2 * (1 + 3) - (11 + 2 * 3) + 3;
    try testing.expect(@abs(@as(i32, @intCast(across)) - expected) <= 1);
}

test "the chamfer equals a brute-force search, on an open floor and around a pillar" {
    for ([_]bool{ false, true }) |pillar| try chamferMatches(pillar);
}

fn chamferMatches(pillar: bool) !void {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(3, 0, 2), false);
    // A pillar's corners are where the nearest boundary is diagonal.
    if (pillar) scene.box(.init(1.25, 0, 0.85), .init(1.55, 1, 1.15));
    var f = try openOf(gpa, walker, &scene);
    defer f.deinit(gpa);
    try f.buildDistanceField(gpa);
    // Brute force before the blur, which the field has had: rebuild the raw chamfer.
    const raw = try gpa.alloc(u16, f.spans.len);
    defer gpa.free(raw);
    for (f.spans, raw, 0..) |s, *out, i| {
        var same: u32 = 0;
        if (s.area != unwalkable) {
            for (0..4) |k| {
                if (f.step(@intCast(i), k) != null) same += 1;
            }
        }
        out.* = if (same == 4) far else 0;
    }
    // On a convex floor two passes are exact: each span's distance is the least, over every
    // boundary span, of three per diagonal step and two per straight one.
    const expected = try gpa.alloc(u16, f.spans.len);
    defer gpa.free(expected);
    for (0..f.grid.depth) |zi| for (0..f.grid.width) |xi| {
        const c = f.column(@intCast(xi), @intCast(zi));
        if (c.count == 0) continue;
        // The floor's spans only: a pillar's top is a floor of its own, far from this one.
        if (f.spans[c.first].y > 4) {
            for (c.first..c.first + c.count) |i| expected[i] = far;
            continue;
        }
        var best: u32 = far;
        for (0..f.grid.depth) |zj| for (0..f.grid.width) |xj| {
            const b = f.column(@intCast(xj), @intCast(zj));
            if (b.count == 0 or raw[b.first] != 0 or f.spans[b.first].y > 4) continue;
            const dx: u32 = @intCast(@abs(@as(i64, @intCast(xi)) - @as(i64, @intCast(xj))));
            const dz: u32 = @intCast(@abs(@as(i64, @intCast(zi)) - @as(i64, @intCast(zj))));
            const diag = @min(dx, dz);
            best = @min(best, 3 * diag + 2 * (@max(dx, dz) - diag));
        };
        expected[c.first] = @intCast(best);
    };
    f.chamfer(raw);
    for (f.spans, expected, raw) |s, want, have| {
        if (s.y <= 4) try testing.expectEqual(want, have);
    }
}

test "a link needs a floor within the climb and room for the agent across both" {
    const gpa = testing.allocator;
    const grid: Grid = .{ .origin = .zero, .cell_size = 0.1, .cell_height = 0.05, .width = 2, .depth = 1, .height = 100, .triangles = 0 };
    const cases = [_]struct { b_floor: u16, b_ceiling: ?u16, linked: bool }{
        .{ .b_floor = 8, .b_ceiling = null, .linked = true }, // 6 up, within a climb of 7
        .{ .b_floor = 10, .b_ceiling = null, .linked = false }, // 8 up
        .{ .b_floor = 2, .b_ceiling = 37, .linked = false }, // level, but 35 open where 36 are needed
        .{ .b_floor = 2, .b_ceiling = 38, .linked = true },
    };
    for (cases) |case| {
        // Unfiltered spans by hand, so the ledge filter cannot decide first.
        var hf = try Heightfield.init(gpa, grid, .{ .height = 36, .climb = 7, .radius = 0 });
        defer hf.deinit(gpa);
        try hf.addSpan(gpa, 0, 0, 0, 2, walkable);
        try hf.addSpan(gpa, 1, 0, 0, case.b_floor, walkable);
        if (case.b_ceiling) |top| try hf.addSpan(gpa, 1, 0, top, top + 2, unwalkable);
        var f = try OpenField.init(gpa, &hf);
        defer f.deinit(gpa);
        try testing.expectEqual(case.linked, f.spans[0].links[2] != none);
        try testing.expectEqual(case.linked, f.spans[1].links[0] != none);
    }
}
