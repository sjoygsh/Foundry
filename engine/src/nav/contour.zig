//! Contours: each region's outline traced along its spans' edges, simplified, and with its
//! holes bridged in (`navigation.md` §5.5).
//!
//! **Everything here is integers.** A contour vertex is a corner of the grid, `x` and `z` in
//! columns from the origin and `y` in cells, so every orientation and intersection test is
//! exact and every build of the same field gives the same outline (I9).
//!
//! **Winding.** An outline runs counter-clockwise seen from +Y: its interior is on the left
//! of each edge, where "left" is `turn(a, b, c) > 0`. Holes are traced the other way, and
//! bridging makes one counter-clockwise loop of each region.

const std = @import("std");

const open_mod = @import("open.zig");

const Allocator = std.mem.Allocator;
const OpenField = open_mod.OpenField;
const none = open_mod.none;
const unwalkable = open_mod.unwalkable;

/// A grid corner, and the region across the edge that leaves it (0 for none).
pub const Vertex = struct {
    x: i32,
    y: i32,
    z: i32,
    neighbour: u16 = 0,

    pub fn sameXz(a: Vertex, b: Vertex) bool {
        return a.x == b.x and a.z == b.z;
    }
};

pub const Contour = struct {
    region: u16,
    vertices: []Vertex,
};

/// Every region's single loop, holes bridged in, in region order.
pub const Contours = struct {
    items: []Contour,
    /// Regions whose outline could not be made one loop. Zero in every scene the suite builds;
    /// a hostile level is answered by leaving the region out, never by a panic.
    skipped: u32 = 0,

    pub fn deinit(self: *Contours, gpa: Allocator) void {
        for (self.items) |c| gpa.free(c.vertices);
        gpa.free(self.items);
        self.* = undefined;
    }
};

pub const Settings = struct {
    /// `edge_max_error` in cells.
    max_error: f32,
    /// `edge_max_length` in cells; 0 is no limit.
    max_edge: f32,

    pub fn of(edge_max_error: f32, edge_max_length: f32, cell_size: f32) Settings {
        return .{ .max_error = edge_max_error / cell_size, .max_edge = edge_max_length / cell_size };
    }
};

/// `> 0` when `c` is left of `a → b` seen from +Y, `0` when the three are in line.
pub fn turn(a: Vertex, b: Vertex, c: Vertex) i64 {
    return @as(i64, b.z - a.z) * (c.x - a.x) - @as(i64, b.x - a.x) * (c.z - a.z);
}

/// Twice the signed area seen from +Y: positive for a counter-clockwise loop.
pub fn area2(loop: []const Vertex) i64 {
    var sum: i64 = 0;
    for (loop, 0..) |a, i| {
        const b = loop[(i + 1) % loop.len];
        sum += @as(i64, a.z) * b.x - @as(i64, a.x) * b.z;
    }
    return sum;
}

pub fn build(gpa: Allocator, f: *const OpenField, region_count: u16, settings: Settings) Allocator.Error!Contours {
    const n = f.spans.len;
    // A bit per direction whose edge leaves the span's region.
    const flags = try gpa.alloc(u4, n);
    defer gpa.free(flags);
    for (f.spans, flags) |s, *out| {
        out.* = 0;
        if (s.region == 0) continue;
        var bits: u4 = 0;
        for (0..4) |k| {
            const j = s.links[k];
            const other: u16 = if (j == none) 0 else f.spans[j].region;
            if (other != s.region) bits |= @as(u4, 1) << @intCast(k);
        }
        // A lone span has no inside to trace around.
        out.* = if (bits == 0xf) 0 else bits;
    }
    const where = try spanColumns(gpa, f);
    defer gpa.free(where);

    // Each region's loops, outlines and holes together, gathered in scan order.
    var loops: std.ArrayList(Contour) = .empty;
    defer {
        for (loops.items) |c| gpa.free(c.vertices);
        loops.deinit(gpa);
    }
    var raw: std.ArrayList(Vertex) = .empty;
    defer raw.deinit(gpa);
    var simple: std.ArrayList(Simple) = .empty;
    defer simple.deinit(gpa);
    for (0..n) |ii| {
        const i: u32 = @intCast(ii);
        if (flags[i] == 0) continue;
        raw.clearRetainingCapacity();
        // A walk that does not close is a field this module made wrongly; its region is left
        // out rather than trusted.
        if (!try walk(gpa, f, flags, where, i, &raw)) continue;
        try simplify(gpa, raw.items, &simple, settings);
        if (simple.items.len < 3) continue;
        const vertices = try gpa.alloc(Vertex, simple.items.len);
        for (simple.items, vertices) |s, *v| v.* = s.v;
        loops.append(gpa, .{ .region = f.spans[i].region, .vertices = vertices }) catch |err| {
            gpa.free(vertices);
            return err;
        };
    }

    var out: std.ArrayList(Contour) = .empty;
    errdefer {
        for (out.items) |c| gpa.free(c.vertices);
        out.deinit(gpa);
    }
    var skipped: u32 = 0;
    for (1..@as(usize, region_count) + 1) |r| {
        if (try joinRegion(gpa, loops.items, @intCast(r), &out) == false) skipped += 1;
    }
    return .{ .items = try out.toOwnedSlice(gpa), .skipped = skipped };
}

/// Each span's column, as `x | z << 16`, so the walk can step between columns.
fn spanColumns(gpa: Allocator, f: *const OpenField) Allocator.Error![]u32 {
    const where = try gpa.alloc(u32, f.spans.len);
    for (0..f.grid.depth) |z| for (0..f.grid.width) |x| {
        const c = f.column(@intCast(x), @intCast(z));
        for (c.first..c.first + c.count) |i| where[i] = @intCast(x | z << 16);
    };
    return where;
}

/// Traces one loop from span `start`, clearing the flags of the edges it walks: on an edge,
/// record its corner and turn clockwise; across a link, step and turn anticlockwise.
fn walk(gpa: Allocator, f: *const OpenField, flags: []u4, where: []const u32, start: u32, out: *std.ArrayList(Vertex)) Allocator.Error!bool {
    var i = start;
    var x: i32 = @intCast(where[i] & 0xffff);
    var z: i32 = @intCast(where[i] >> 16);
    var dir: u2 = 0;
    while (flags[i] & (@as(u4, 1) << dir) == 0) dir +%= 1;
    const start_dir = dir;
    // Each span's four edges are each recorded once and each crossed at most once.
    var budget: usize = 8 * f.spans.len + 8;
    while (budget > 0) : (budget -= 1) {
        const bit = @as(u4, 1) << dir;
        if (flags[i] & bit != 0) {
            var px = x;
            var pz = z;
            switch (dir) {
                0 => pz += 1,
                1 => {
                    px += 1;
                    pz += 1;
                },
                2 => px += 1,
                3 => {},
            }
            const j = f.spans[i].links[dir];
            const across: u16 = if (j == none) 0 else f.spans[j].region;
            try out.append(gpa, .{ .x = px, .y = cornerHeight(f, i, dir), .z = pz, .neighbour = across });
            flags[i] &= ~bit;
            dir +%= 1;
        } else {
            const j = f.spans[i].links[dir];
            // A flag is clear only where the link leads into the same region.
            if (j == none) return false;
            x += @intCast(open_mod.directions[dir][0]);
            z += @intCast(open_mod.directions[dir][1]);
            i = j;
            dir -%= 1;
        }
        if (i == start and dir == start_dir) return true;
    }
    return false;
}

/// The highest floor of the up-to-four spans around the corner at the start of edge `dir`,
/// so both regions that share the corner give it the same height.
fn cornerHeight(f: *const OpenField, i: u32, dir: u2) i32 {
    var h: i32 = f.spans[i].y;
    const side = dir +% 1;
    if (link(f, i, dir)) |a| {
        h = @max(h, f.spans[a].y);
        if (link(f, a, side)) |b| h = @max(h, f.spans[b].y);
    }
    if (link(f, i, side)) |a| {
        h = @max(h, f.spans[a].y);
        if (link(f, a, dir)) |b| h = @max(h, f.spans[b].y);
    }
    return h;
}

fn link(f: *const OpenField, i: u32, k: u2) ?u32 {
    const j = f.spans[i].links[k];
    return if (j == none or f.spans[j].area == unwalkable) null else j;
}

const Simple = struct { v: Vertex, raw: u32 };

/// Recast's simplification (§5.5): keep every vertex where the region across changes, or the
/// extreme corners of a loop with one neighbour throughout; add back the farthest raw vertex
/// of a wall edge while it strays more than the error; split wall edges longer than the limit.
fn simplify(gpa: Allocator, raw: []const Vertex, out: *std.ArrayList(Simple), settings: Settings) Allocator.Error!void {
    out.clearRetainingCapacity();
    const n = raw.len;
    for (raw, 0..) |v, i| {
        if (v.neighbour != raw[(i + 1) % n].neighbour) try out.append(gpa, .{ .v = v, .raw = @intCast(i) });
    }
    if (out.items.len == 0) {
        // Lower-left and upper-right, by x and then z.
        var ll: usize = 0;
        var ur: usize = 0;
        for (raw, 0..) |v, i| {
            if (v.x < raw[ll].x or (v.x == raw[ll].x and v.z < raw[ll].z)) ll = i;
            if (v.x > raw[ur].x or (v.x == raw[ur].x and v.z > raw[ur].z)) ur = i;
        }
        try out.append(gpa, .{ .v = raw[ll], .raw = @intCast(ll) });
        if (ur != ll) try out.append(gpa, .{ .v = raw[ur], .raw = @intCast(ur) });
    }

    const max_error2 = settings.max_error * settings.max_error;
    var i: usize = 0;
    while (i < out.items.len) {
        const a = out.items[i];
        const b = out.items[(i + 1) % out.items.len];
        // Walked in a fixed direction between the two, so a border two regions share is
        // simplified the same from both sides.
        var lo = a.v;
        var hi = b.v;
        var step: usize = 1;
        var ci: usize = (a.raw + 1) % n;
        var end: usize = b.raw;
        if (!(b.v.x > a.v.x or (b.v.x == a.v.x and b.v.z > a.v.z))) {
            step = n - 1;
            ci = (b.raw + step) % n;
            end = a.raw;
            std.mem.swap(Vertex, &lo, &hi);
        }
        var farthest: ?usize = null;
        var deviation: f32 = 0;
        // Only walls are tessellated: a border between regions stays straight between its
        // change points, the same line from both sides.
        if (raw[ci].neighbour == 0) {
            while (ci != end) : (ci = (ci + step) % n) {
                const d = distanceToSegment2(raw[ci], lo, hi);
                if (d > deviation) {
                    deviation = d;
                    farthest = ci;
                }
            }
        }
        if (farthest != null and deviation > max_error2) {
            try out.insert(gpa, i + 1, .{ .v = raw[farthest.?], .raw = @intCast(farthest.?) });
        } else i += 1;
    }

    if (settings.max_edge > 0) {
        const max_edge2 = settings.max_edge * settings.max_edge;
        i = 0;
        while (i < out.items.len) {
            const a = out.items[i];
            const b = out.items[(i + 1) % out.items.len];
            var split: ?usize = null;
            if (raw[(a.raw + 1) % n].neighbour == 0) {
                const dx: f32 = @floatFromInt(b.v.x - a.v.x);
                const dz: f32 = @floatFromInt(b.v.z - a.v.z);
                if (dx * dx + dz * dz > max_edge2) {
                    const span = if (b.raw < a.raw) b.raw + n - a.raw else b.raw - a.raw;
                    if (span > 1) {
                        // The same midpoint from either side.
                        split = if (b.v.x > a.v.x or (b.v.x == a.v.x and b.v.z > a.v.z))
                            (a.raw + span / 2) % n
                        else
                            (a.raw + (span + 1) / 2) % n;
                    }
                }
            }
            if (split) |s| {
                try out.insert(gpa, i + 1, .{ .v = raw[s], .raw = @intCast(s) });
            } else i += 1;
        }
    }

    // Each vertex carries the region across the edge that leaves it.
    for (out.items) |*s| s.v.neighbour = raw[(s.raw + 1) % n].neighbour;
    // Consecutive vertices at one place say nothing.
    i = 0;
    while (out.items.len > 0 and i < out.items.len) {
        if (out.items.len > 1 and out.items[i].v.sameXz(out.items[(i + 1) % out.items.len].v)) {
            _ = out.orderedRemove((i + 1) % out.items.len);
            if (i >= out.items.len) i = 0;
        } else i += 1;
    }
}

fn distanceToSegment2(p: Vertex, a: Vertex, b: Vertex) f32 {
    const px: f32 = @floatFromInt(p.x - a.x);
    const pz: f32 = @floatFromInt(p.z - a.z);
    const dx: f32 = @floatFromInt(b.x - a.x);
    const dz: f32 = @floatFromInt(b.z - a.z);
    const len2 = dx * dx + dz * dz;
    var t: f32 = if (len2 > 0) (px * dx + pz * dz) / len2 else 0;
    t = std.math.clamp(t, 0, 1);
    const ex = px - t * dx;
    const ez = pz - t * dz;
    return ex * ex + ez * ez;
}

// -- holes ---------------------------------------------------------------------------

/// Makes region `r`'s loops one counter-clockwise loop and appends it to `out`. False when the
/// region has no outline or a hole could not be bridged.
pub fn joinRegion(gpa: Allocator, loops: []const Contour, r: u16, out: *std.ArrayList(Contour)) Allocator.Error!bool {
    var outline: ?[]const Vertex = null;
    var holes: std.ArrayList([]const Vertex) = .empty;
    defer holes.deinit(gpa);
    for (loops) |c| {
        if (c.region != r) continue;
        const a = area2(c.vertices);
        if (a > 0) {
            // One outline per region: a watershed region is connected.
            if (outline != null) return false;
            outline = c.vertices;
        } else if (a < 0) try holes.append(gpa, c.vertices);
    }
    const base = outline orelse return false;
    var merged: std.ArrayList(Vertex) = .empty;
    defer merged.deinit(gpa);
    try merged.appendSlice(gpa, base);

    // Leftmost hole first, so each bridge sees the holes still to come.
    std.mem.sort([]const Vertex, holes.items, {}, struct {
        fn less(_: void, a: []const Vertex, b: []const Vertex) bool {
            const la = a[leftmost(a)];
            const lb = b[leftmost(b)];
            return la.x < lb.x or (la.x == lb.x and la.z < lb.z);
        }
    }.less);
    for (holes.items, 0..) |hole, h| {
        if (!try bridge(gpa, &merged, hole, holes.items[h + 1 ..])) return false;
    }
    const vertices = try merged.toOwnedSlice(gpa);
    out.append(gpa, .{ .region = r, .vertices = vertices }) catch |err| {
        gpa.free(vertices);
        return err;
    };
    return true;
}

fn leftmost(loop: []const Vertex) usize {
    var best: usize = 0;
    for (loop, 0..) |v, i| {
        if (v.x < loop[best].x or (v.x == loop[best].x and v.z < loop[best].z)) best = i;
    }
    return best;
}

/// Joins `hole` into `outline` by the shortest diagonal from one of its vertices, starting at
/// its leftmost, to an outline vertex that sees it without crossing the outline or a later hole.
fn bridge(gpa: Allocator, outline: *std.ArrayList(Vertex), hole: []const Vertex, later: []const []const Vertex) Allocator.Error!bool {
    const start = leftmost(hole);
    for (0..hole.len) |step| {
        const hi = (start + step) % hole.len;
        const p = hole[hi];
        var best: ?usize = null;
        var best_d: i64 = std.math.maxInt(i64);
        for (outline.items, 0..) |q, k| {
            if (!inCone(outline.items, k, p)) continue;
            const dx: i64 = q.x - p.x;
            const dz: i64 = q.z - p.z;
            const d = dx * dx + dz * dz;
            if (d >= best_d) continue;
            if (crossesLoop(q, p, outline.items) or crossesLoop(q, p, hole)) continue;
            var blocked = false;
            for (later) |other| {
                if (crossesLoop(q, p, other)) {
                    blocked = true;
                    break;
                }
            }
            if (blocked) continue;
            best = k;
            best_d = d;
        }
        if (best) |k| {
            // outline[0..k], outline[k], hole from hi round to hi again, then outline[k..].
            var joined: std.ArrayList(Vertex) = .empty;
            defer joined.deinit(gpa);
            try joined.appendSlice(gpa, outline.items[0 .. k + 1]);
            for (0..hole.len + 1) |s| try joined.append(gpa, hole[(hi + s) % hole.len]);
            try joined.appendSlice(gpa, outline.items[k..]);
            outline.clearRetainingCapacity();
            try outline.appendSlice(gpa, joined.items);
            return true;
        }
    }
    return false;
}

/// Whether `p` lies inside the angle the loop makes at vertex `i` (counter-clockwise loop).
pub fn inCone(loop: []const Vertex, i: usize, p: Vertex) bool {
    const a = loop[i];
    const next = loop[(i + 1) % loop.len];
    const prev = loop[(i + loop.len - 1) % loop.len];
    if (turn(prev, a, next) >= 0) return turn(a, p, prev) > 0 and turn(p, a, next) > 0;
    return !(turn(a, p, next) >= 0 and turn(p, a, prev) >= 0);
}

/// Whether segment `a b` crosses an edge of `loop` that does not end at `a` or `b`.
fn crossesLoop(a: Vertex, b: Vertex, loop: []const Vertex) bool {
    for (loop, 0..) |c, i| {
        const d = loop[(i + 1) % loop.len];
        if (c.sameXz(a) or c.sameXz(b) or d.sameXz(a) or d.sameXz(b)) continue;
        if (intersects(a, b, c, d)) return true;
    }
    return false;
}

/// Segments `a b` and `c d` meet, properly or by touching.
pub fn intersects(a: Vertex, b: Vertex, c: Vertex, d: Vertex) bool {
    const t1 = turn(a, b, c);
    const t2 = turn(a, b, d);
    const t3 = turn(c, d, a);
    const t4 = turn(c, d, b);
    if (((t1 > 0) != (t2 > 0)) and t1 != 0 and t2 != 0 and ((t3 > 0) != (t4 > 0)) and t3 != 0 and t4 != 0) return true;
    return (t1 == 0 and between(a, b, c)) or (t2 == 0 and between(a, b, d)) or
        (t3 == 0 and between(c, d, a)) or (t4 == 0 and between(c, d, b));
}

/// `c`, in line with `a b`, lies on the closed segment.
fn between(a: Vertex, b: Vertex, c: Vertex) bool {
    if (a.x != b.x) return (a.x <= c.x and c.x <= b.x) or (a.x >= c.x and c.x >= b.x);
    return (a.z <= c.z and c.z <= b.z) or (a.z >= c.z and c.z >= b.z);
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const scenes = @import("scenes.zig");
const config_mod = @import("config.zig");
const heightfield = @import("heightfield.zig");
const regions = @import("regions.zig");

fn contoursOf(gpa: Allocator, c: config_mod.Config, scene: *scenes.Scene) !Contours {
    var hf = try heightfield.solid(gpa, c, scene.sources());
    defer hf.deinit(gpa);
    var f = try OpenField.init(gpa, &hf);
    defer f.deinit(gpa);
    try f.erode(gpa);
    const count = try regions.build(gpa, &f, .of(c.region_min_area, c.region_merge_area, c.cell_size));
    return build(gpa, &f, count, .of(c.edge_max_error, c.edge_max_length, c.cell_size));
}

test "two regions' shared border has the same vertices from both sides" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 2), false);
    scene.floor(.init(0, 0, 2), .init(2, 0, 12), false);
    scene.box(.init(0.55, 0, 6.05), .init(1.05, 2, 6.55));
    var c = config_mod.walker;
    c.region_merge_area = 0;
    var loops = try contoursOf(gpa, c, &scene);
    defer loops.deinit(gpa);
    try testing.expectEqual(@as(u32, 0), loops.skipped);
    var borders: u32 = 0;
    for (loops.items) |l| {
        // One counter-clockwise loop per region, holes bridged in.
        try testing.expect(area2(l.vertices) > 0);
        for (l.vertices, 0..) |a, i| {
            if (a.neighbour == 0) continue;
            const b = l.vertices[(i + 1) % l.vertices.len];
            borders += 1;
            // The region across has the edge the other way, and says who is across from it.
            var found = false;
            for (loops.items) |other| {
                if (other.region != a.neighbour) continue;
                for (other.vertices, 0..) |p, j| {
                    const q = other.vertices[(j + 1) % other.vertices.len];
                    if (p.sameXz(b) and q.sameXz(a) and p.neighbour == l.region) found = true;
                }
            }
            try testing.expect(found);
        }
    }
    try testing.expect(borders > 0);
}

test "a hole is bridged: one loop, with the bridge's ends in it twice" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(6, 0, 6), false);
    scene.box(.init(2.55, 0, 2.55), .init(3.55, 3, 3.55));
    var c = config_mod.walker;
    c.region_merge_area = 1000;
    var loops = try contoursOf(gpa, c, &scene);
    defer loops.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), loops.items.len);
    const l = loops.items[0].vertices;
    try testing.expect(area2(l) > 0);
    var repeated: u32 = 0;
    for (l, 0..) |a, i| for (l[i + 1 ..]) |b| {
        if (a.sameXz(b)) repeated += 1;
    };
    try testing.expectEqual(@as(u32, 2), repeated);
}

test "simplification keeps a turned floor's staircase within the error, with few vertices" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(-4, 0, -4), .init(4, 0, 4), false);
    const sources = scene.sources();
    var turned = sources[0];
    turned.pose = .{ .position = .init(10, 0, 10), .rotation = @import("core").math.Quat.fromAxisAngle(.init(0, 1, 0), std.math.pi / 6.0) };
    var c = config_mod.walker;
    c.region_merge_area = 1000;
    c.edge_max_length = 0;
    var hf = try heightfield.solid(gpa, c, &.{turned});
    defer hf.deinit(gpa);
    var f = try OpenField.init(gpa, &hf);
    defer f.deinit(gpa);
    try f.erode(gpa);
    const count = try regions.build(gpa, &f, .of(c.region_min_area, c.region_merge_area, c.cell_size));
    var loops = try build(gpa, &f, count, .of(c.edge_max_error, c.edge_max_length, c.cell_size));
    defer loops.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), loops.items.len);
    // Four sides of a staircase, each simplified to a handful of vertices at a 1.3-cell error.
    try testing.expect(loops.items[0].vertices.len <= 24);
    try testing.expect(loops.items[0].vertices.len >= 4);
}
