//! The solid heightfield: rasterisation, span merging and the three filters
//! (`navigation.md` §5.1, §5.2).
//!
//! **A column is a list of spans**, each a run of solid cells from `min` to `max`, sorted bottom
//! to top and never touching: two spans that touch are one. A span's `max` is the floor an agent
//! would stand on. Spans live in one array and link by index, and a removed span goes on a free
//! list, so a column's list never holds an address (I1's reason, inside the module).
//!
//! **Only the agent's quantities in cells are seen here** (`Agent`): heights rounded up, the
//! climb rounded down, so every rounding is in the agent's favour of caution.

const std = @import("std");
const core = @import("core");

const config_mod = @import("config.zig");
const input = @import("input.zig");

const Allocator = std.mem.Allocator;
const Config = config_mod.Config;
const Grid = input.Grid;
const Source = input.Source;
const Vec3 = core.math.Vec3;

/// The most spans a heightfield holds: 96 MiB of them. A level that needs more needs tiles,
/// which are M60's.
pub const max_spans: u32 = 8_388_608;
/// A column with no span, and the end of a column's list.
pub const none: u32 = std.math.maxInt(u32);

/// What a span's top is. A byte, so M33's area types have room beside these two.
pub const unwalkable: u8 = 0;
pub const walkable: u8 = 1;

/// Above every span: the open sky over a column's top span. Far below `i32`'s range, so a
/// difference of two heights never overflows.
const open: i32 = 1 << 24;

pub const Span = struct {
    min: u16,
    max: u16,
    area: u8,
    next: u32 = none,
};

/// The agent in cells (`navigation.md` §5).
pub const Agent = struct {
    /// Clearance it needs, in cell heights, rounded up.
    height: u32,
    /// The step it takes, in cell heights, rounded down.
    climb: u32,
    /// Its radius, in cells, rounded up.
    radius: u32,

    pub fn of(c: Config) Agent {
        return .{
            .height = @intFromFloat(@ceil(c.agent_height / c.cell_height)),
            .climb = @intFromFloat(@floor(c.agent_climb / c.cell_height)),
            .radius = @intFromFloat(@ceil(c.agent_radius / c.cell_size)),
        };
    }
};

pub const Error = error{ OutOfMemory, TooLarge };

pub const Heightfield = struct {
    grid: Grid,
    agent: Agent,
    /// The first span of each column, `x + z * width`, or `none`.
    heads: []u32,
    spans: std.ArrayList(Span) = .empty,
    free: u32 = none,
    /// Spans in some column's list.
    live: u32 = 0,
    /// `max_spans`, unless a test asks for less.
    span_limit: u32 = max_spans,

    pub fn init(gpa: Allocator, grid: Grid, agent: Agent) Allocator.Error!Heightfield {
        const heads = try gpa.alloc(u32, grid.columns());
        @memset(heads, none);
        return .{ .grid = grid, .agent = agent, .heads = heads };
    }

    pub fn deinit(self: *Heightfield, gpa: Allocator) void {
        gpa.free(self.heads);
        self.spans.deinit(gpa);
        self.* = undefined;
    }

    pub fn head(self: *const Heightfield, x: u32, z: u32) u32 {
        return self.heads[x + z * self.grid.width];
    }

    pub fn span(self: *const Heightfield, index: u32) Span {
        return self.spans.items[index];
    }

    /// Adds `[min, max]` to column `(x, z)`, merging every span it overlaps or touches
    /// (§5.1). Where two tops are within the climb, the walkable flag wins; otherwise the
    /// higher top's flag survives.
    pub fn addSpan(self: *Heightfield, gpa: Allocator, x: u32, z: u32, min: u16, max: u16, area: u8) Error!void {
        std.debug.assert(x < self.grid.width and z < self.grid.depth and min < max);
        const column = x + z * self.grid.width;
        var lo = min;
        var hi = max;
        var flag = area;
        var previous: u32 = none;
        var current = self.heads[column];
        while (current != none) {
            const s = self.spans.items[current];
            if (s.min > hi) break;
            if (s.max < lo) {
                previous = current;
                current = s.next;
                continue;
            }
            if (@abs(@as(i32, s.max) - @as(i32, hi)) <= self.agent.climb) {
                flag = @max(flag, s.area);
            } else if (s.max > hi) {
                flag = s.area;
            }
            lo = @min(lo, s.min);
            hi = @max(hi, s.max);
            const next = s.next;
            self.release(current);
            if (previous == none) self.heads[column] = next else self.spans.items[previous].next = next;
            current = next;
        }
        const added = try self.acquire(gpa);
        self.spans.items[added] = .{ .min = lo, .max = hi, .area = flag, .next = current };
        if (previous == none) self.heads[column] = added else self.spans.items[previous].next = added;
    }

    fn acquire(self: *Heightfield, gpa: Allocator) Error!u32 {
        if (self.free != none) {
            const index = self.free;
            self.free = self.spans.items[index].next;
            self.live += 1;
            return index;
        }
        if (self.spans.items.len >= self.span_limit) return error.TooLarge;
        try self.spans.append(gpa, undefined);
        self.live += 1;
        return @intCast(self.spans.items.len - 1);
    }

    fn release(self: *Heightfield, index: u32) void {
        self.spans.items[index].next = self.free;
        self.free = index;
        self.live -= 1;
    }

    // -- rasterisation (§5.1) ---------------------------------------------------------

    /// Every triangle of every source, in source order and then index order. `sources` must be
    /// the ones the grid was measured from.
    pub fn rasterize(self: *Heightfield, gpa: Allocator, config: Config, sources: []const Source) Error!void {
        // The slope's cosine in arithmetic, so the walkable flag cannot depend on a linked libm.
        const cos_slope: f32 = @floatCast(core.math.trig.sinCosTurns(@as(f64, config.agent_slope) / (2 * std.math.pi))[1]);
        const cos2 = cos_slope * cos_slope;
        const min_cross2 = 4 * input.min_triangle_area * input.min_triangle_area;
        for (sources) |source| {
            // `measure` accepted this pose; the same normalisation is applied here.
            const pose = input.validPose(source.pose) catch unreachable;
            var t: usize = 0;
            while (t < source.indices.len) : (t += 3) {
                const a = pose.apply(source.positions[source.indices[t]]).sub(self.grid.origin);
                const b = pose.apply(source.positions[source.indices[t + 1]]).sub(self.grid.origin);
                const c = pose.apply(source.positions[source.indices[t + 2]]).sub(self.grid.origin);
                const n = Vec3.cross(b.sub(a), c.sub(a));
                const n2 = n.lengthSquared();
                if (n2 < min_cross2) continue;
                // Two-sided: an upward face is walkable whichever way it is wound.
                const area: u8 = if (n.y * n.y >= cos2 * n2) walkable else unwalkable;
                try self.rasterizeTriangle(gpa, .{ a, b, c }, area);
            }
        }
    }

    fn rasterizeTriangle(self: *Heightfield, gpa: Allocator, tri: [3]Vec3, area: u8) Error!void {
        const cs = self.grid.cell_size;
        const ch = self.grid.cell_height;
        const z_range = cellRange(@min(tri[0].z, tri[1].z, tri[2].z), @max(tri[0].z, tri[1].z, tri[2].z), cs, self.grid.depth);
        var z = z_range[0];
        while (z <= z_range[1]) : (z += 1) {
            var row_buf: [max_clip]Vec3 = undefined;
            const row = clip(&tri, &row_buf, 2, @as(f32, @floatFromInt(z)) * cs, @as(f32, @floatFromInt(z + 1)) * cs);
            if (row.len < 3) continue;
            var lo_x = row[0].x;
            var hi_x = row[0].x;
            for (row[1..]) |p| {
                lo_x = @min(lo_x, p.x);
                hi_x = @max(hi_x, p.x);
            }
            const x_range = cellRange(lo_x, hi_x, cs, self.grid.width);
            var x = x_range[0];
            while (x <= x_range[1]) : (x += 1) {
                var cell_buf: [max_clip]Vec3 = undefined;
                const cell = clip(row, &cell_buf, 0, @as(f32, @floatFromInt(x)) * cs, @as(f32, @floatFromInt(x + 1)) * cs);
                if (cell.len < 3) continue;
                var lo_y = cell[0].y;
                var hi_y = cell[0].y;
                for (cell[1..]) |p| {
                    lo_y = @min(lo_y, p.y);
                    hi_y = @max(hi_y, p.y);
                }
                // Rounded outward: the span covers every cell the polygon touches.
                const top: i64 = @intCast(self.grid.height);
                const floor_cell = std.math.clamp(@as(i64, @intFromFloat(@floor(lo_y / ch))), 0, top - 1);
                const top_cell = std.math.clamp(@as(i64, @intFromFloat(@ceil(hi_y / ch))), floor_cell + 1, top);
                try self.addSpan(gpa, x, z, @intCast(floor_cell), @intCast(top_cell), area);
            }
        }
    }

    // -- the filters (§5.2) -----------------------------------------------------------

    /// A non-walkable span whose top is within the climb of the walkable span directly below
    /// it takes that span's flag. "Directly below" reads the flags as they were before the
    /// pass, so a stack of short obstacles does not climb itself.
    pub fn filterLowObstacles(self: *Heightfield) void {
        for (self.heads) |first| {
            var below_walkable = false;
            var below_area: u8 = unwalkable;
            var below_max: i32 = 0;
            var i = first;
            while (i != none) {
                const s = &self.spans.items[i];
                const was_walkable = s.area != unwalkable;
                if (!was_walkable and below_walkable and @abs(@as(i32, s.max) - below_max) <= self.agent.climb) s.area = below_area;
                below_walkable = was_walkable;
                below_area = s.area;
                below_max = s.max;
                i = s.next;
            }
        }
    }

    /// A walkable span is unwalkable if a neighbour the agent fits beside drops by more than the
    /// climb, the grid's edge counting as a drop, or if the neighbours it could step to differ
    /// among themselves by more than the climb, which is a slope too steep to stand on.
    pub fn filterLedges(self: *Heightfield) void {
        const climb: i32 = @intCast(self.agent.climb);
        const height: i32 = @intCast(self.agent.height);
        const w = self.grid.width;
        const d = self.grid.depth;
        for (0..d) |zi| for (0..w) |xi| {
            const x: u32 = @intCast(xi);
            const z: u32 = @intCast(zi);
            var i = self.head(x, z);
            while (i != none) : (i = self.spans.items[i].next) {
                const s = self.spans.items[i];
                if (s.area == unwalkable) continue;
                const bot: i32 = s.max;
                const top = self.ceilingOf(s);
                var lowest: i32 = open;
                var reach_min = bot;
                var reach_max = bot;
                for (directions) |dir| {
                    const nx = @as(i64, x) + dir[0];
                    const nz = @as(i64, z) + dir[1];
                    if (nx < 0 or nz < 0 or nx >= w or nz >= d) {
                        lowest = @min(lowest, -climb - bot);
                        continue;
                    }
                    var n = self.head(@intCast(nx), @intCast(nz));
                    // The gap below the neighbour's first span is a drop to nothing.
                    const first_min: i32 = if (n != none) self.spans.items[n].min else open;
                    if (@min(top, first_min) - @max(bot, -climb) > height) lowest = @min(lowest, -climb - bot);
                    while (n != none) : (n = self.spans.items[n].next) {
                        const ns = self.spans.items[n];
                        const nbot: i32 = ns.max;
                        const ntop = self.ceilingOf(ns);
                        if (@min(top, ntop) - @max(bot, nbot) > height) {
                            lowest = @min(lowest, nbot - bot);
                            if (@abs(nbot - bot) <= climb) {
                                reach_min = @min(reach_min, nbot);
                                reach_max = @max(reach_max, nbot);
                            }
                        }
                    }
                }
                if (lowest < -climb or reach_max - reach_min > climb) self.spans.items[i].area = unwalkable;
            }
        };
    }

    /// A walkable span with less than the agent's height of open space above it is unwalkable.
    pub fn filterLowCeilings(self: *Heightfield) void {
        const height: i32 = @intCast(self.agent.height);
        // Through the columns, not the array: a freed span is still in the array, and its
        // `next` is the free list.
        for (self.heads) |first| {
            var i = first;
            while (i != none) : (i = self.spans.items[i].next) {
                const s = &self.spans.items[i];
                if (s.area == unwalkable) continue;
                if (self.ceilingOf(s.*) - @as(i32, s.max) < height) s.area = unwalkable;
            }
        }
    }

    fn ceilingOf(self: *const Heightfield, s: Span) i32 {
        return if (s.next != none) self.spans.items[s.next].min else open;
    }
};

/// The order neighbours are visited in, everywhere: −X, +Z, +X, −Z.
pub const directions = [4][2]i64{ .{ -1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 0, -1 } };

/// Validates, measures, rasterises and filters: §5.1 and §5.2 in their order.
pub fn solid(gpa: Allocator, config: Config, sources: []const Source) (input.InputError || Error)!Heightfield {
    const grid = try input.measure(config, sources);
    var hf = try Heightfield.init(gpa, grid, .of(config));
    errdefer hf.deinit(gpa);
    try hf.rasterize(gpa, config, sources);
    hf.filterLowObstacles();
    hf.filterLedges();
    hf.filterLowCeilings();
    return hf;
}

/// A triangle clipped by two pairs of planes has at most seven vertices.
const max_clip = 8;

/// The cells `[lo, hi]` touches, as half-open cells: a polygon ending exactly on a boundary
/// does not reach into the next cell, and one with no extent on the axis (a wall in that
/// plane) is in the cell its coordinate falls in. Clamped to the grid.
fn cellRange(lo: f32, hi: f32, size: f32, count: u32) [2]u32 {
    const last: i64 = @as(i64, count) - 1;
    const first = std.math.clamp(@as(i64, @intFromFloat(@floor(lo / size))), 0, last);
    const end = std.math.clamp(@as(i64, @intFromFloat(@ceil(hi / size))) - 1, first, last);
    return .{ @intCast(first), @intCast(end) };
}

/// `poly` clipped to `lo ≤ p[axis] ≤ hi`, Sutherland–Hodgman, into `out`.
fn clip(poly: []const Vec3, out: *[max_clip]Vec3, axis: u2, lo: f32, hi: f32) []const Vec3 {
    var mid: [max_clip]Vec3 = undefined;
    const kept = clipPlane(poly, &mid, axis, lo, 1);
    return clipPlane(kept, out, axis, hi, -1);
}

/// Keeps the side where `sign · (p[axis] − at) ≥ 0`.
fn clipPlane(poly: []const Vec3, out: *[max_clip]Vec3, axis: u2, at: f32, sign: f32) []const Vec3 {
    var n: usize = 0;
    if (poly.len == 0) return out[0..0];
    var a = poly[poly.len - 1];
    var da = sign * (coord(a, axis) - at);
    for (poly) |b| {
        const db = sign * (coord(b, axis) - at);
        if ((da >= 0) != (db >= 0)) {
            const t = da / (da - db);
            out[n] = a.add(b.sub(a).scale(t));
            n += 1;
        }
        if (db >= 0) {
            out[n] = b;
            n += 1;
        }
        a = b;
        da = db;
    }
    return out[0..n];
}

fn coord(p: Vec3, axis: u2) f32 {
    return switch (axis) {
        0 => p.x,
        1 => p.y,
        else => p.z,
    };
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const scenes = @import("scenes.zig");

/// Columns whose top span is walkable, and the walkable spans in all.
fn countWalkable(hf: *const Heightfield) [2]u32 {
    var columns: u32 = 0;
    var spans: u32 = 0;
    for (hf.heads) |first| {
        var any = false;
        var i = first;
        while (i != none) : (i = hf.spans.items[i].next) {
            if (hf.spans.items[i].area == walkable) {
                spans += 1;
                any = true;
            }
        }
        if (any) columns += 1;
    }
    return .{ columns, spans };
}

/// The column holding world point (x, z).
fn columnAt(hf: *const Heightfield, x: f32, z: f32) [2]u32 {
    return .{
        @intFromFloat(@floor((x - hf.grid.origin.x) / hf.grid.cell_size)),
        @intFromFloat(@floor((z - hf.grid.origin.z) / hf.grid.cell_size)),
    };
}

/// The spans of the column holding world point (x, z), bottom to top.
fn spansAt(hf: *const Heightfield, x: f32, z: f32, out: []Span) []Span {
    const c = columnAt(hf, x, z);
    var n: usize = 0;
    var i = hf.head(c[0], c[1]);
    while (i != none) : (i = hf.spans.items[i].next) {
        out[n] = hf.spans.items[i];
        n += 1;
    }
    return out[0..n];
}

/// A span's top in metres, in the world.
fn topOf(hf: *const Heightfield, s: Span) f32 {
    return hf.grid.origin.y + @as(f32, @floatFromInt(s.max)) * hf.grid.cell_height;
}

const walker = config_mod.walker;

test "the agent in cells rounds in caution's favour" {
    const a = Agent.of(walker);
    try testing.expectEqual(@as(u32, 36), a.height);
    try testing.expectEqual(@as(u32, 7), a.climb);
    try testing.expectEqual(@as(u32, 3), a.radius);
    var c = walker;
    c.agent_radius = 0.31;
    c.agent_climb = 0.34;
    try testing.expectEqual(@as(u32, 4), Agent.of(c).radius);
    try testing.expectEqual(@as(u32, 6), Agent.of(c).climb);
}

test "spans merge where they touch, and keep the right flag" {
    const gpa = testing.allocator;
    const grid: Grid = .{ .origin = .zero, .cell_size = 0.1, .cell_height = 0.05, .width = 1, .depth = 1, .height = 100, .triangles = 0 };
    var hf = try Heightfield.init(gpa, grid, .{ .height = 36, .climb = 4, .radius = 3 });
    defer hf.deinit(gpa);
    var buf: [8]Span = undefined;

    try hf.addSpan(gpa, 0, 0, 10, 12, walkable);
    try hf.addSpan(gpa, 0, 0, 2, 4, unwalkable);
    try hf.addSpan(gpa, 0, 0, 20, 22, walkable);
    var got = spansAt(&hf, 0.05, 0.05, &buf);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(@as(u16, 2), got[0].min);
    try testing.expectEqual(@as(u16, 20), got[2].min);

    // Touching is merging: [4, 10] joins the two spans below it into one, [2, 12]. The new
    // top is 2 below the old one, within the climb of 4, so walkable wins.
    try hf.addSpan(gpa, 0, 0, 4, 10, unwalkable);
    got = spansAt(&hf, 0.05, 0.05, &buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(Span{ .min = 2, .max = 12, .area = walkable, .next = got[0].next }, got[0]);

    // A wall rising more than the climb above a floor makes the top the wall's.
    try hf.addSpan(gpa, 0, 0, 11, 18, unwalkable);
    got = spansAt(&hf, 0.05, 0.05, &buf);
    try testing.expectEqual(@as(u16, 18), got[0].max);
    try testing.expectEqual(unwalkable, got[0].area);
    // A floor on it within the climb of its top takes the flag back.
    try hf.addSpan(gpa, 0, 0, 17, 19, walkable);
    got = spansAt(&hf, 0.05, 0.05, &buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(u16, 19), got[0].max);
    try testing.expectEqual(walkable, got[0].area);
    // A span's `max` is its first empty cell: [.., 19] and [20, ..] leave cell 19 open and do
    // not touch, while [.., 20] would.
    try hf.addSpan(gpa, 0, 0, 19, 20, walkable);
    got = spansAt(&hf, 0.05, 0.05, &buf);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(u16, 22), got[0].max);
    // Freed spans are reused, and the live count is the list's length.
    try testing.expectEqual(@as(u32, 1), hf.live);
    try testing.expect(hf.spans.items.len <= 4);
}

test "a span past the limit is refused as too large" {
    const gpa = testing.allocator;
    const grid: Grid = .{ .origin = .zero, .cell_size = 0.1, .cell_height = 0.05, .width = 1, .depth = 1, .height = 100, .triangles = 0 };
    var hf = try Heightfield.init(gpa, grid, .{ .height = 36, .climb = 4, .radius = 3 });
    defer hf.deinit(gpa);
    hf.span_limit = 2;
    try hf.addSpan(gpa, 0, 0, 1, 2, walkable);
    try hf.addSpan(gpa, 0, 0, 5, 6, walkable);
    try testing.expectError(error.TooLarge, hf.addSpan(gpa, 0, 0, 9, 10, walkable));
    // A merge frees what it adds back, so it still fits.
    try hf.addSpan(gpa, 0, 0, 2, 5, walkable);
}

test "a floor is one walkable span in each column it covers, wound either way" {
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |reversed| {
        var scene: scenes.Scene = .{};
        scene.floor(.init(0, 0, 0), .init(10, 0, 10), reversed);
        var hf = try solid(gpa, walker, scene.sources());
        defer hf.deinit(gpa);
        // The floor covers 100 × 100 columns, within a cell for the rounding at its far edges;
        // the ledge filter takes its outer ring, since the grid's edge is a drop.
        const counts = countWalkable(&hf);
        try testing.expect(counts[0] >= 98 * 98 and counts[0] <= 99 * 99);
        try testing.expectEqual(counts[0], counts[1]);
        var buf: [4]Span = undefined;
        const got = spansAt(&hf, 5, 5, &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectApproxEqAbs(@as(f32, 0), topOf(&hf, got[0]), hf.grid.cell_height + 1e-5);
        // Outside the floor, nothing.
        try testing.expectEqual(@as(usize, 0), spansAt(&hf, -0.05, 5, &buf).len);
        try testing.expectEqual(@as(usize, 0), spansAt(&hf, 10.05, 5, &buf).len);
    }
}

test "ramps within the slope are walkable, and ramps beyond it are not" {
    const gpa = testing.allocator;
    for ([_]struct { degrees: f32, walkable: bool }{ .{ .degrees = 25, .walkable = true }, .{ .degrees = 44, .walkable = true }, .{ .degrees = 46, .walkable = false }, .{ .degrees = 55, .walkable = false } }) |case| {
        var scene: scenes.Scene = .{};
        scene.ramp(.init(0, 0, 0), 2, 3, case.degrees);
        var hf = try Heightfield.init(gpa, try input.measure(walker, scene.sources()), .of(walker));
        defer hf.deinit(gpa);
        try hf.rasterize(gpa, walker, scene.sources());
        var buf: [4]Span = undefined;
        // The ramp's middle, before any filter.
        const got = spansAt(&hf, 1, 1.5, &buf);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(case.walkable, got[0].area == walkable);
        const run = 3 * @cos(case.degrees * std.math.pi / 180.0);
        const rise = 3 * @sin(case.degrees * std.math.pi / 180.0);
        const expected = rise * (1.5 / run);
        // Rounded outward, so the top is at most one cell above the surface across a cell.
        const top = topOf(&hf, got[0]);
        try testing.expect(top >= expected - 1e-4);
        try testing.expect(top <= expected + hf.grid.cell_height + hf.grid.cell_size * @tan(case.degrees * std.math.pi / 180.0) + 1e-4);
    }
}

test "a step within the climb keeps its edge, and one beyond it loses it" {
    const gpa = testing.allocator;
    for ([_]struct { climb: f32, edge: bool }{ .{ .climb = 0.35, .edge = true }, .{ .climb = 0.1, .edge = false } }) |case| {
        var scene: scenes.Scene = .{};
        scene.floor(.init(-2, 0, -2), .init(4, 0, 4), false);
        // Half a cell off the grid, so its walls fall inside a column rather than on a boundary
        // rounding would decide.
        scene.box(.init(0.05, 0, 0.05), .init(2.05, 0.15, 2.05));
        var c = walker;
        c.agent_climb = case.climb;
        var hf = try solid(gpa, c, scene.sources());
        defer hf.deinit(gpa);
        var buf: [4]Span = undefined;
        // A closed box is its bottom and its top, hollow between: the floor under it is a
        // span with a ceiling too low to stand under, and the top is walkable.
        const middle = spansAt(&hf, 1, 1, &buf);
        try testing.expectEqual(@as(usize, 2), middle.len);
        try testing.expectEqual(unwalkable, middle[0].area);
        try testing.expectEqual(walkable, middle[1].area);
        try testing.expectApproxEqAbs(@as(f32, 0.15), topOf(&hf, middle[1]), hf.grid.cell_height + 1e-5);
        // On top, on its edge, where the walls make it one solid span: a ledge only when the
        // drop to the floor exceeds the climb.
        const edge = spansAt(&hf, 0.07, 1, &buf);
        try testing.expectEqual(case.edge, edge[edge.len - 1].area == walkable);
        // The floor beside it stays walkable: the box is a wall to it, not a drop.
        const beside = spansAt(&hf, -0.05, 1, &buf);
        try testing.expectEqual(walkable, beside[0].area);
    }
}

test "a floor under a ceiling lower than the agent is cut, and under a higher one is not" {
    const gpa = testing.allocator;
    for ([_]struct { at: f32, open: bool }{ .{ .at = 1.5, .open = false }, .{ .at = 2.0, .open = true } }) |case| {
        var scene: scenes.Scene = .{};
        scene.floor(.init(0, 0, 0), .init(6, 0, 6), false);
        scene.box(.init(2.05, case.at, 2.05), .init(4.05, case.at + 0.2, 4.05));
        var hf = try solid(gpa, walker, scene.sources());
        defer hf.deinit(gpa);
        var buf: [4]Span = undefined;
        // The floor, the slab's bottom and the slab's top.
        const under = spansAt(&hf, 3, 3, &buf);
        try testing.expectEqual(@as(usize, 3), under.len);
        try testing.expectEqual(case.open, under[0].area == walkable);
        // The slab's own top is walkable inside its edges, and a ledge at them.
        try testing.expectEqual(walkable, under[2].area);
        const edge = spansAt(&hf, 2.07, 3, &buf);
        try testing.expectEqual(unwalkable, edge[edge.len - 1].area);
        // Out from under it, the floor is open.
        try testing.expectEqual(walkable, spansAt(&hf, 1, 3, &buf)[0].area);
    }
}

test "a platform over nothing loses exactly its outer ring to the ledge filter" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.box(.init(0, 1, 0), .init(2, 1.2, 2));
    var hf = try solid(gpa, walker, scene.sources());
    defer hf.deinit(gpa);
    // 20 × 20 columns, within a cell at the far walls, less a ring of one.
    const counts = countWalkable(&hf);
    try testing.expect(counts[0] >= 18 * 18 and counts[0] <= 19 * 19);
}

test "a low obstacle above a walkable span takes its flag, once" {
    const gpa = testing.allocator;
    const grid: Grid = .{ .origin = .zero, .cell_size = 0.1, .cell_height = 0.05, .width = 1, .depth = 1, .height = 100, .triangles = 0 };
    for ([_]struct { climb: u32, lifted: bool }{ .{ .climb = 4, .lifted = true }, .{ .climb = 2, .lifted = false } }) |case| {
        var hf = try Heightfield.init(gpa, grid, .{ .height = 2, .climb = case.climb, .radius = 1 });
        defer hf.deinit(gpa);
        // Separate spans, so no merge decides them: a floor, a short obstacle above it and a
        // second one above that.
        try hf.addSpan(gpa, 0, 0, 0, 2, walkable);
        try hf.addSpan(gpa, 0, 0, 3, 5, unwalkable);
        try hf.addSpan(gpa, 0, 0, 6, 8, unwalkable);
        hf.filterLowObstacles();
        var buf: [4]Span = undefined;
        const got = spansAt(&hf, 0.05, 0.05, &buf);
        try testing.expectEqual(@as(usize, 3), got.len);
        try testing.expectEqual(case.lifted, got[1].area == walkable);
        // The second obstacle is judged against the first as it was: unwalkable.
        try testing.expectEqual(unwalkable, got[2].area);
    }
}

test "every allocation failure is reported, and nothing leaks" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(1, 0, 1), false);
    scene.box(.init(0.2, 0, 0.2), .init(0.5, 0.3, 0.5));
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, sources: []const Source) !void {
            var hf = try solid(gpa, walker, sources);
            hf.deinit(gpa);
        }
    }.run, .{scene.sources()});
}

test "a span between neighbours that differ by more than the climb is too steep to stand on" {
    const gpa = testing.allocator;
    const grid: Grid = .{ .origin = .zero, .cell_size = 0.1, .cell_height = 0.05, .width = 5, .depth = 5, .height = 100, .triangles = 0 };
    for ([_]struct { climb: u32, stands: bool }{ .{ .climb = 4, .stands = false }, .{ .climb = 6, .stands = true } }) |case| {
        var hf = try Heightfield.init(gpa, grid, .{ .height = 2, .climb = case.climb, .radius = 1 });
        defer hf.deinit(gpa);
        // Floors rising by 3 cells a column along X: the middle column's −X neighbour is 3
        // below it and its +X neighbour 3 above, each within a climb of 4, but 6 apart.
        for (0..5) |z| for (0..5) |x| {
            const top: u16 = if (x <= 1) 10 else if (x == 2) 13 else 16;
            try hf.addSpan(gpa, @intCast(x), @intCast(z), 0, top, walkable);
        };
        hf.filterLedges();
        try testing.expectEqual(case.stands, hf.span(hf.head(2, 2)).area == walkable);
    }
}
