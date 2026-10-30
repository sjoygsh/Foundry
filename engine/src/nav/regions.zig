//! Regions: the eroded surface partitioned by a watershed over its distance field, then small
//! islands dropped and small regions merged (`navigation.md` §5.4).
//!
//! **Order decides everything, so it is fixed** (I9). Levels fall two at a time from the
//! highest distance. At each level, existing regions first grow into newly uncovered spans, each
//! span joining the neighbour region nearest its seed (ties to the first direction, −X, +Z, +X,
//! −Z), applied after the whole pass so no span sees a half-updated field. Then every span still
//! unclaimed at that level seeds a region, scanning spans in their index order. After merging,
//! regions are renumbered in the order their first span appears.
//!
//! **A region may have holes.** A floor around a pillar is one region with the pillar's hole in
//! it; the contour stage bridges holes into their outline (§5.5).

const std = @import("std");

const open_mod = @import("open.zig");

const Allocator = std.mem.Allocator;
const OpenField = open_mod.OpenField;
const none = open_mod.none;
const unwalkable = open_mod.unwalkable;

/// Region 0 is no region; the rest fit a `u16`.
pub const max_regions: u32 = std.math.maxInt(u16) - 1;
/// How many passes regions grow by at each level before seeding. Recast's figure: enough for the
/// distance field's two-a-step levels, without letting one region race across a plateau.
pub const grow_passes: u32 = 8;

pub const Error = error{ OutOfMemory, TooLarge };

pub const Settings = struct {
    /// An island of regions smaller than this many spans is dropped.
    min_spans: u32,
    /// A region smaller than this many spans merges into a neighbour.
    merge_spans: u32,

    /// The record's square metres, in cells of `cell_size`. Rounded up: an island exactly at the
    /// minimum survives.
    pub fn of(region_min_area: f32, region_merge_area: f32, cell_size: f32) Settings {
        const cell = cell_size * cell_size;
        return .{
            .min_spans = @intFromFloat(@ceil(region_min_area / cell)),
            .merge_spans = @intFromFloat(@ceil(region_merge_area / cell)),
        };
    }
};

/// Assigns every walkable span of `f` a region, or none if its island was too small, which also
/// makes it unwalkable. Builds the distance field first. Returns the number of regions.
pub fn build(gpa: Allocator, f: *OpenField, settings: Settings) Error!u16 {
    try f.buildDistanceField(gpa);
    const n = f.spans.len;
    const region = try gpa.alloc(u16, n);
    defer gpa.free(region);
    const seed_distance = try gpa.alloc(u16, n);
    defer gpa.free(seed_distance);
    @memset(region, 0);
    @memset(seed_distance, 0);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var changes: std.ArrayList(Change) = .empty;
    defer changes.deinit(gpa);

    var next_region: u32 = 1;
    var level: u32 = (@as(u32, f.max_distance) + 1) & ~@as(u32, 1);
    while (level > 0) {
        level = if (level >= 2) level - 2 else 0;
        try grow(gpa, f, region, seed_distance, &changes, level, grow_passes);
        for (0..n) |i| {
            if (f.spans[i].area == unwalkable or region[i] != 0 or f.distance[i] < level) continue;
            if (next_region > max_regions) return error.TooLarge;
            if (try flood(gpa, f, region, seed_distance, &stack, @intCast(i), level, @intCast(next_region))) next_region += 1;
        }
    }
    // Until nothing is left to claim, with no limit on the passes.
    try grow(gpa, f, region, seed_distance, &changes, 0, std.math.maxInt(u32));

    const count = try mergeAndFilter(gpa, f, region, next_region, settings);
    for (f.spans, region) |*s, r| {
        s.region = r;
        if (r == 0) s.area = unwalkable;
    }
    return count;
}

const Change = struct { span: u32, region: u16, distance: u16 };

/// Grows existing regions into unclaimed spans at or above `level`, `passes` times at most.
fn grow(gpa: Allocator, f: *const OpenField, region: []u16, seed_distance: []u16, changes: *std.ArrayList(Change), level: u32, passes: u32) Allocator.Error!void {
    var pass: u32 = 0;
    while (pass < passes) : (pass += 1) {
        changes.clearRetainingCapacity();
        var pending: u32 = 0;
        for (f.spans, 0..) |s, ii| {
            const i: u32 = @intCast(ii);
            if (s.area == unwalkable or region[i] != 0 or f.distance[i] < level) continue;
            pending += 1;
            var best: u16 = 0;
            var best_distance: u32 = std.math.maxInt(u32);
            for (0..4) |k| {
                const j = s.links[k];
                if (j == none or f.spans[j].area != s.area or region[j] == 0) continue;
                const d = @as(u32, seed_distance[j]) + 2;
                if (d < best_distance) {
                    best = region[j];
                    best_distance = d;
                }
            }
            if (best != 0) try changes.append(gpa, .{ .span = i, .region = best, .distance = @intCast(@min(best_distance, std.math.maxInt(u16))) });
        }
        for (changes.items) |c| {
            region[c.span] = c.region;
            seed_distance[c.span] = c.distance;
        }
        if (changes.items.len == 0 or changes.items.len == pending) break;
    }
}

/// Claims for region `r` every span connected to `start` at or above two levels below
/// `level`, unless one of them already touches another region, which then stays where it is
/// for the regions to grow into. Returns whether `r` claimed anything.
fn flood(gpa: Allocator, f: *const OpenField, region: []u16, seed_distance: []u16, stack: *std.ArrayList(u32), start: u32, level: u32, r: u16) Allocator.Error!bool {
    const area = f.spans[start].area;
    const floor = if (level >= 2) level - 2 else 0;
    stack.clearRetainingCapacity();
    try stack.append(gpa, start);
    region[start] = r;
    seed_distance[start] = 0;
    var claimed: u32 = 0;
    while (stack.pop()) |c| {
        // A span beside another region, straight or diagonal, is left for growth.
        var other = false;
        for (0..4) |k| {
            const a = f.spans[c].links[k];
            if (a == none or f.spans[a].area != area) continue;
            if (region[a] != 0 and region[a] != r) {
                other = true;
                break;
            }
            const b = f.spans[a].links[(k + 1) % 4];
            if (b == none or f.spans[b].area != area) continue;
            if (region[b] != 0 and region[b] != r) {
                other = true;
                break;
            }
        }
        if (other) {
            region[c] = 0;
            continue;
        }
        claimed += 1;
        for (0..4) |k| {
            const a = f.spans[c].links[k];
            if (a == none or f.spans[a].area != area) continue;
            if (f.distance[a] >= floor and region[a] == 0) {
                region[a] = r;
                seed_distance[a] = 0;
                try stack.append(gpa, a);
            }
        }
    }
    return claimed > 0;
}

/// Drops islands of regions below `min_spans`, merges regions below `merge_spans` into the
/// neighbour they share the longest border with, and renumbers what is left in order of first
/// appearance. Two regions that share a column are never merged: one would lie over the other.
/// Nor are two of different areas: a polygon has one cost.
fn mergeAndFilter(gpa: Allocator, f: *const OpenField, region: []u16, next_region: u32, settings: Settings) Error!u16 {
    const count = next_region;
    const spans = try gpa.alloc(u32, count);
    defer gpa.free(spans);
    @memset(spans, 0);
    for (region) |r| spans[r] += 1;
    const area_of = try gpa.alloc(u8, count);
    defer gpa.free(area_of);
    @memset(area_of, unwalkable);
    for (f.spans, region) |s, r| area_of[r] = s.area;

    // Shared border lengths, in links, both ways; and which pairs share a column.
    var borders: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer borders.deinit(gpa);
    var stacked: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer stacked.deinit(gpa);
    for (f.spans, 0..) |s, i| {
        const r = region[i];
        if (r == 0) continue;
        for (s.links) |j| {
            if (j == none) continue;
            const q = region[j];
            if (q == 0 or q == r) continue;
            const entry = try borders.getOrPut(gpa, pair(r, q));
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }
    for (f.columns) |c| {
        for (c.first..c.first + c.count) |a| for (a + 1..c.first + c.count) |b| {
            const ra = region[a];
            const rb = region[b];
            if (ra == 0 or rb == 0 or ra == rb) continue;
            try stacked.put(gpa, pair(ra, rb), {});
            try stacked.put(gpa, pair(rb, ra), {});
        };
    }

    // Islands: regions joined by any border, by union-find with the lower id as the root.
    const island = try gpa.alloc(u32, count);
    defer gpa.free(island);
    for (island, 0..) |*v, i| v.* = @intCast(i);
    for (borders.keys()) |key| unite(island, key >> 16, key & 0xffff);
    const island_spans = try gpa.alloc(u32, count);
    defer gpa.free(island_spans);
    @memset(island_spans, 0);
    for (1..count) |r| island_spans[root(island, @intCast(r))] += spans[r];
    const into = try gpa.alloc(u32, count);
    defer gpa.free(into);
    for (into, 0..) |*v, i| v.* = @intCast(i);
    for (1..count) |r| {
        if (spans[r] > 0 and island_spans[root(island, @intCast(r))] < settings.min_spans) {
            into[r] = 0;
            spans[r] = 0;
        }
    }

    // Merging, smallest-first in effect: every pass takes regions in id order, and repeats
    // until a pass merges nothing.
    var merged = true;
    while (merged) {
        merged = false;
        for (1..count) |ri| {
            const r: u32 = @intCast(ri);
            if (into[r] != r or spans[r] == 0 or spans[r] >= settings.merge_spans) continue;
            var target: u32 = 0;
            var longest: u32 = 0;
            for (borders.keys(), borders.values()) |key, length| {
                if (key >> 16 != r) continue;
                const q = key & 0xffff;
                if (into[q] != q or spans[q] == 0) continue;
                if (stacked.contains(pair(r, q)) or area_of[q] != area_of[r]) continue;
                if (length > longest or (length == longest and q < target)) {
                    target = q;
                    longest = length;
                }
            }
            if (target == 0) continue;
            try absorb(gpa, &borders, &stacked, r, target);
            into[r] = target;
            spans[target] += spans[r];
            spans[r] = 0;
            merged = true;
        }
    }

    // Renumber: each span's final region, in order of first appearance.
    const renumber = try gpa.alloc(u16, count);
    defer gpa.free(renumber);
    @memset(renumber, 0);
    var final: u32 = 0;
    for (region) |*r| {
        if (r.* == 0) continue;
        var target: u32 = r.*;
        while (into[target] != target and into[target] != 0) target = into[target];
        if (into[target] == 0) {
            r.* = 0;
            continue;
        }
        if (renumber[target] == 0) {
            final += 1;
            renumber[target] = @intCast(final);
        }
        r.* = renumber[target];
    }
    return @intCast(final);
}

/// Moves `r`'s borders and stacking onto `target`.
fn absorb(gpa: Allocator, borders: *std.AutoArrayHashMapUnmanaged(u32, u32), stacked: *std.AutoArrayHashMapUnmanaged(u32, void), r: u32, target: u32) Allocator.Error!void {
    // Collected first: the maps change as they are rewritten.
    var moved: std.ArrayList([2]u32) = .empty;
    defer moved.deinit(gpa);
    for (borders.keys(), borders.values()) |key, length| {
        if (key >> 16 == r) try moved.append(gpa, .{ key & 0xffff, length });
    }
    for (moved.items) |m| {
        const q = m[0];
        _ = borders.orderedRemove(pair(r, q));
        _ = borders.orderedRemove(pair(q, r));
        if (q == target) continue;
        for ([_]u32{ pair(target, q), pair(q, target) }) |key| {
            const entry = try borders.getOrPut(gpa, key);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += m[1];
        }
    }
    var lifted: std.ArrayList(u32) = .empty;
    defer lifted.deinit(gpa);
    for (stacked.keys()) |key| {
        if (key >> 16 == r) try lifted.append(gpa, key & 0xffff);
    }
    for (lifted.items) |q| {
        _ = stacked.orderedRemove(pair(r, q));
        _ = stacked.orderedRemove(pair(q, r));
        if (q == target) continue;
        try stacked.put(gpa, pair(target, q), {});
        try stacked.put(gpa, pair(q, target), {});
    }
}

fn pair(a: u32, b: u32) u32 {
    return a << 16 | b;
}

fn root(parent: []u32, x: u32) u32 {
    var r = x;
    while (parent[r] != r) r = parent[r];
    return r;
}

fn unite(parent: []u32, a: u32, b: u32) void {
    const ra = root(parent, a);
    const rb = root(parent, b);
    if (ra == rb) return;
    if (ra < rb) parent[rb] = ra else parent[ra] = rb;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const scenes = @import("scenes.zig");
const config_mod = @import("config.zig");
const walker = config_mod.walker;

fn settingsOf(c: config_mod.Config) Settings {
    return .of(c.region_min_area, c.region_merge_area, c.cell_size);
}

/// Every walkable span has a region in 1..count, every region has a span, and an unwalkable
/// span has none.
fn expectPartition(f: *const OpenField, count: u16) !void {
    const seen = try testing.allocator.alloc(bool, @as(usize, count) + 1);
    defer testing.allocator.free(seen);
    @memset(seen, false);
    for (f.spans) |s| {
        if (s.area == unwalkable) {
            try testing.expectEqual(@as(u16, 0), s.region);
        } else {
            try testing.expect(s.region >= 1 and s.region <= count);
            seen[s.region] = true;
        }
    }
    for (seen[1..]) |v| try testing.expect(v);
}

/// Connected walkable surfaces, by a flood over links; and that no region spans two of them.
fn islandsOf(f: *const OpenField) !u32 {
    const gpa = testing.allocator;
    const island = try gpa.alloc(u32, f.spans.len);
    defer gpa.free(island);
    @memset(island, none);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var count: u32 = 0;
    for (f.spans, 0..) |s, i| {
        if (s.area == unwalkable or island[i] != none) continue;
        island[i] = count;
        try stack.append(gpa, @intCast(i));
        while (stack.pop()) |c| for (f.spans[c].links) |j| {
            if (j == none or f.spans[j].area == unwalkable or island[j] != none) continue;
            island[j] = count;
            try stack.append(gpa, j);
        };
        count += 1;
    }
    const of_region = try gpa.alloc(u32, 65536);
    defer gpa.free(of_region);
    @memset(of_region, none);
    for (f.spans, island) |s, k| {
        if (s.area == unwalkable) continue;
        if (of_region[s.region] == none) of_region[s.region] = k;
        try testing.expectEqual(of_region[s.region], k);
    }
    return count;
}

fn built(gpa: Allocator, c: config_mod.Config, scene: *scenes.Scene) !struct { OpenField, u16 } {
    var f = try open_mod.openOf(gpa, c, scene);
    errdefer f.deinit(gpa);
    try f.erode(gpa);
    const count = try build(gpa, &f, settingsOf(c));
    return .{ f, count };
}

test "an open floor is one region" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    var f, const count = try built(gpa, walker, &scene);
    defer f.deinit(gpa);
    try testing.expectEqual(@as(u16, 1), count);
    try expectPartition(&f, count);
    try testing.expectEqual(@as(u32, 1), try islandsOf(&f));
}

test "a pillar's hollow inside and its top are islands too small to keep" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    scene.box(.init(4.55, 0, 4.55), .init(5.55, 3, 5.55));
    var f, const count = try built(gpa, walker, &scene);
    defer f.deinit(gpa);
    try expectPartition(&f, count);
    // Nothing at the pillar's middle survives, at the floor or on its top.
    const c = f.column(@intFromFloat(@floor((5.05 - f.grid.origin.x) / 0.1)), @intFromFloat(@floor((5.05 - f.grid.origin.z) / 0.1)));
    for (f.spans[c.first..][0..c.count]) |s| try testing.expectEqual(unwalkable, s.area);
    // The floor around it is kept: some regions, none of them above the floor.
    try testing.expect(count >= 1);
    for (f.spans) |s| {
        if (s.area != unwalkable) try testing.expect(s.y <= 4);
    }
}

test "a floor and a platform it cannot reach are separate regions" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(8, 0, 8), false);
    scene.box(.init(2.05, 0, 2.05), .init(5.05, 1, 5.05));
    var f, const count = try built(gpa, walker, &scene);
    defer f.deinit(gpa);
    try expectPartition(&f, count);
    try testing.expectEqual(@as(u32, 2), try islandsOf(&f));
    try testing.expect(count >= 2);
    // The floor appears first in scan order, so its first region is region 1.
    const floor_column = f.column(10, 10);
    try testing.expectEqual(@as(u16, 1), f.spans[floor_column.first].region);
}

test "below the minimum an island is dropped, and above it kept" {
    const gpa = testing.allocator;
    // The platform's top is 31 columns square, 23 once the ledge and the radius are taken:
    // 5.29 m². The floor around it is about 38 m². Each is an island.
    for ([_]struct { min: f32, kept: u32 }{ .{ .min = 2, .kept = 2 }, .{ .min = 8, .kept = 1 }, .{ .min = 50, .kept = 0 } }) |case| {
        var scene: scenes.Scene = .{};
        scene.floor(.init(0, 0, 0), .init(8, 0, 8), false);
        scene.box(.init(2.05, 0, 2.05), .init(5.05, 1, 5.05));
        var c = walker;
        c.region_min_area = case.min;
        var f, const count = try built(gpa, c, &scene);
        defer f.deinit(gpa);
        try expectPartition(&f, count);
        try testing.expectEqual(case.kept, try islandsOf(&f));
    }
}

test "small regions merge into the neighbour they share most border with" {
    const gpa = testing.allocator;
    // An L of two corridors meeting at a corner gives the watershed several seeds; with a large
    // merge area they become one.
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 2), false);
    scene.floor(.init(0, 0, 2), .init(2, 0, 12), false);
    var c = walker;
    c.region_merge_area = 0;
    var split, const many = try built(gpa, c, &scene);
    defer split.deinit(gpa);
    try expectPartition(&split, many);
    c.region_merge_area = 1000;
    var joined, const one = try built(gpa, c, &scene);
    defer joined.deinit(gpa);
    try expectPartition(&joined, one);
    try testing.expectEqual(@as(u16, 1), one);
    try testing.expect(many > 1);
}

test "two regions that share a column never merge, however small" {
    const gpa = testing.allocator;
    // By hand: column A holds a floor and, 50 cells above it, a ledge; column B a floor beside
    // A's. A's floor (region 1) borders B's floor (region 2), and A's ledge is region 2 as well,
    // so region 2 lies over region 1 in column A.
    var columns = [_]open_mod.Column{ .{ .first = 0, .count = 2 }, .{ .first = 2, .count = 1 } };
    var spans = [_]open_mod.OpenSpan{
        .{ .y = 0, .clearance = 40, .area = open_mod.walkable, .links = .{ none, none, 2, none } },
        .{ .y = 50, .clearance = open_mod.open_clearance, .area = open_mod.walkable },
        .{ .y = 0, .clearance = open_mod.open_clearance, .area = open_mod.walkable, .links = .{ 0, none, none, none } },
    };
    const f: OpenField = .{
        .grid = .{ .origin = .zero, .cell_size = 0.1, .cell_height = 0.05, .width = 2, .depth = 1, .height = 100, .triangles = 0 },
        .agent = .{ .height = 36, .climb = 7, .radius = 0 },
        .columns = &columns,
        .spans = &spans,
    };
    var region = [_]u16{ 1, 2, 2 };
    try testing.expectEqual(@as(u16, 2), try mergeAndFilter(gpa, &f, &region, 3, .{ .min_spans = 0, .merge_spans = 10 }));
    try testing.expectEqualSlices(u16, &.{ 1, 2, 2 }, &region);
}

test "regions are the same every time" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 2), false);
    scene.floor(.init(0, 0, 2), .init(2, 0, 12), false);
    scene.box(.init(0.55, 0, 6.05), .init(1.05, 2, 6.55));
    var c = walker;
    c.region_merge_area = 0;
    var a, const na = try built(gpa, c, &scene);
    defer a.deinit(gpa);
    var b, const nb = try built(gpa, c, &scene);
    defer b.deinit(gpa);
    try testing.expectEqual(na, nb);
    for (a.spans, b.spans) |x, y| try testing.expectEqual(x.region, y.region);
}

test "every allocation failure in region building is reported, and nothing leaks" {
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(2, 0, 1), false);
    scene.floor(.init(0, 0, 1), .init(1, 0, 2), false);
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, s: *scenes.Scene) !void {
            var f = try open_mod.openOf(gpa, walker, s);
            defer f.deinit(gpa);
            try f.erode(gpa);
            _ = try build(gpa, &f, settingsOf(walker));
        }
    }.run, .{&scene});
}

test "the L's watershed is pinned" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(12, 0, 2), false);
    scene.floor(.init(0, 0, 2), .init(2, 0, 12), false);
    scene.box(.init(0.55, 0, 6.05), .init(1.05, 2, 6.55));
    var c = walker;
    c.region_merge_area = 0;
    var f, const count = try built(gpa, c, &scene);
    defer f.deinit(gpa);
    var sizes: [16]u32 = @splat(0);
    for (f.spans) |s| {
        if (s.region != 0) sizes[s.region - 1] += 1;
    }
    // Recorded from this step's build. A change to growth, flooding, seeding or numbering moves
    // it; a deliberate one updates it here and says why in the Resolution.
    try testing.expectEqual(@as(u16, 4), count);
    try testing.expectEqualSlices(u32, &.{ 422, 1064, 371, 579 }, sizes[0..4]);
}

test "the pillar floor's watershed is pinned" {
    const gpa = testing.allocator;
    var scene: scenes.Scene = .{};
    scene.floor(.init(0, 0, 0), .init(10, 0, 10), false);
    scene.box(.init(4.55, 0, 4.55), .init(5.55, 3, 5.55));
    scene.box(.init(1.55, 0, 7.05), .init(2.05, 3, 8.55));
    var c = walker;
    c.region_merge_area = 0;
    var f, const count = try built(gpa, c, &scene);
    defer f.deinit(gpa);
    var sizes: [32]u32 = @splat(0);
    for (f.spans) |s| {
        if (s.region != 0) sizes[s.region - 1] += 1;
    }
    // Recorded from this step's build, as the L's pin is.
    try testing.expectEqual(@as(u16, 5), count);
    try testing.expectEqualSlices(u32, &.{ 2716, 2009, 1984, 1037, 189 }, sizes[0..5]);
}
