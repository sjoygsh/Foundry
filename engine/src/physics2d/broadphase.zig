//! The broadphase: a uniform spatial hash, and the rule that keeps it from mattering.
//!
//! A broadphase exists to answer *which bodies could possibly be involved* without testing
//! every body against every other. Its answer is allowed to contain false positives; it is not
//! allowed to influence a result. That second half is the whole of I9's presence here, and
//! ADR-0022 states it as a binding rule:
//!
//! > **Candidates are collected, then sorted by body handle index, then processed.** Nothing
//! > reads a bucket in bucket order and acts on it.
//!
//! The payoff is that this file is replaceable. A different acceleration structure that
//! produces the same candidate *set* produces the same results, so swapping a uniform hash for
//! a quadtree or a BVH is invisible to every test in the module — which is exactly the
//! property ADR-0022's revisit trigger needs in order to be actable.
//!
//! **Two tiers**, because most bodies do not move in most ticks: static bodies live in their
//! own hash that is untouched while movable ones move (`tilemaps-and-collision.md` §2). A
//! static body may still be repositioned — a door opening — and its tier is updated then;
//! "static" describes a frequency, not a prohibition.
//!
//! Tile grids are **not** here. A grid is a shape source rather than a body and is walked
//! directly, which is what makes it cost the same for a 2000x2000 map as for a 20x20 one (§4).
//!
//! Design: `docs/design/tilemaps-and-collision.md` §5.

const std = @import("std");
const core = @import("core");

const body_mod = @import("body.zig");
const shape_mod = @import("shape.zig");

const Allocator = std.mem.Allocator;
const BodyHandle = body_mod.BodyHandle;
const BodyKind = body_mod.BodyKind;
const Bounds = shape_mod.Bounds;

/// A cell's integer coordinates. Signed, because the world has no origin and a body at a
/// negative coordinate is ordinary.
pub const CellKey = struct { x: i32, y: i32 };

/// The most cells one body or one query may touch before it is treated as oversized.
///
/// **A guard against content, not a tuning knob.** Cell size is chosen from the first body
/// inserted, so a body a million units across arriving after a handful of small ones would
/// otherwise ask for a million cells and hang the frame. Bodies come from files, and files
/// come from mods (CLAUDE.md §7), so the pathological case is reachable rather than
/// theoretical. Anything past this goes in the spill list, which every query considers.
const max_cells_per_span: u64 = 4096;

/// The cell range a rectangle covers, or the fact that it covers too many.
const Span = struct {
    min_x: i32 = 0,
    min_y: i32 = 0,
    max_x: i32 = 0,
    max_y: i32 = 0,
    /// Oversized, or not a finite rectangle at all. Such a body is in the spill list and in
    /// no cell.
    spilled: bool = false,

    fn cellCount(self: Span) u64 {
        if (self.spilled) return 0;
        const w = @as(u64, @intCast(self.max_x - self.min_x)) + 1;
        const h = @as(u64, @intCast(self.max_y - self.min_y)) + 1;
        return w * h;
    }
};

/// A reusable result buffer.
///
/// The caller owns it and clears it between queries, so a per-frame query loop allocates once
/// and then never again — the same reason `render2d` hands out buffers rather than slices it
/// owns.
pub const Candidates = struct {
    items: std.ArrayList(BodyHandle) = .empty,

    pub const empty: Candidates = .{};

    pub fn deinit(self: *Candidates, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.* = .empty;
    }

    pub fn clear(self: *Candidates) void {
        self.items.clearRetainingCapacity();
    }

    /// The candidates, **deduplicated and in ascending handle-index order**.
    pub fn handles(self: *const Candidates) []const BodyHandle {
        return self.items.items;
    }
};

/// One tier: a uniform grid of buckets keyed by cell, plus the bodies too large to bucket.
pub const SpatialHash = struct {
    /// Zero until the first insert decides it.
    cell_size: f32 = 0,
    cells: std.AutoHashMapUnmanaged(CellKey, std.ArrayList(BodyHandle)) = .empty,
    /// Body slot index to the span it currently occupies, so removing a body costs its own
    /// cells rather than a walk over every bucket.
    spans: std.AutoHashMapUnmanaged(u32, Span) = .empty,
    /// Bodies whose span was refused by `max_cells_per_span`. Always considered.
    spill: std.ArrayList(BodyHandle) = .empty,

    pub const empty: SpatialHash = .{};

    pub fn deinit(self: *SpatialHash, gpa: Allocator) void {
        var it = self.cells.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        self.cells.deinit(gpa);
        self.spans.deinit(gpa);
        self.spill.deinit(gpa);
        self.* = .empty;
    }

    pub fn count(self: *const SpatialHash) u32 {
        return self.spans.count();
    }

    /// Decides the cell size from the first body inserted, if it was not configured.
    ///
    /// The first body's bounding extent is a heuristic and is stated as one: it is right when
    /// bodies are of similar size, which is what a tile game has, and it is why
    /// `World.Options.cell_size` exists for when the first body is not representative. A
    /// uniform hash is the right first structure and the wrong last one (ADR-0022).
    fn chooseCellSize(self: *SpatialHash, area: Bounds) void {
        if (self.cell_size > 0) return;
        const width = area.max.x - area.min.x;
        const height = area.max.y - area.min.y;
        const extent = @max(width, height);
        self.cell_size = if (std.math.isFinite(extent) and extent > 0) extent else 1;
    }

    fn spanOf(self: *const SpatialHash, area: Bounds) Span {
        if (!std.math.isFinite(area.min.x) or !std.math.isFinite(area.min.y) or
            !std.math.isFinite(area.max.x) or !std.math.isFinite(area.max.y))
        {
            return .{ .spilled = true };
        }

        const size = self.cell_size;
        const limit: f32 = @floatFromInt(std.math.maxInt(i32) / 2);
        const lo_x = @floor(area.min.x / size);
        const lo_y = @floor(area.min.y / size);
        const hi_x = @floor(area.max.x / size);
        const hi_y = @floor(area.max.y / size);
        // Compared in float space before any cast: `@intFromFloat` of an out-of-range value is
        // undefined behaviour, and these came from a position a game supplied.
        if (@abs(lo_x) > limit or @abs(lo_y) > limit or @abs(hi_x) > limit or @abs(hi_y) > limit) {
            return .{ .spilled = true };
        }

        const span: Span = .{
            .min_x = @intFromFloat(lo_x),
            .min_y = @intFromFloat(lo_y),
            .max_x = @intFromFloat(hi_x),
            .max_y = @intFromFloat(hi_y),
        };
        if (span.cellCount() > max_cells_per_span) return .{ .spilled = true };
        return span;
    }

    pub fn insert(self: *SpatialHash, gpa: Allocator, handle: BodyHandle, area: Bounds) Allocator.Error!void {
        self.chooseCellSize(area);
        const span = self.spanOf(area);

        try self.spans.put(gpa, handle.index, span);
        errdefer _ = self.spans.remove(handle.index);

        if (span.spilled) {
            try self.spill.append(gpa, handle);
            return;
        }

        var y = span.min_y;
        while (y <= span.max_y) : (y += 1) {
            var x = span.min_x;
            while (x <= span.max_x) : (x += 1) {
                const entry = try self.cells.getOrPut(gpa, .{ .x = x, .y = y });
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(gpa, handle);
            }
        }
    }

    pub fn remove(self: *SpatialHash, gpa: Allocator, handle: BodyHandle) void {
        const span = (self.spans.fetchRemove(handle.index) orelse return).value;

        if (span.spilled) {
            for (self.spill.items, 0..) |candidate, i| {
                if (candidate.index == handle.index) {
                    _ = self.spill.swapRemove(i);
                    return;
                }
            }
            return;
        }

        var y = span.min_y;
        while (y <= span.max_y) : (y += 1) {
            var x = span.min_x;
            while (x <= span.max_x) : (x += 1) {
                const key: CellKey = .{ .x = x, .y = y };
                const list = self.cells.getPtr(key) orelse continue;
                for (list.items, 0..) |candidate, i| {
                    if (candidate.index == handle.index) {
                        // `swapRemove` rather than an ordered one: a bucket's order is
                        // deliberately meaningless, because every consumer sorts.
                        _ = list.swapRemove(i);
                        break;
                    }
                }
                if (list.items.len == 0) {
                    list.deinit(gpa);
                    _ = self.cells.remove(key);
                }
            }
        }
    }

    /// Moves a body to a new rectangle.
    ///
    /// **Incremental, and it exits early when the span did not change** — which is the common
    /// case, because a body usually moves a fraction of a cell. Rebuilding the structure every
    /// tick to discover that most things did not move is work paid for nothing (§2).
    pub fn update(self: *SpatialHash, gpa: Allocator, handle: BodyHandle, area: Bounds) Allocator.Error!void {
        const existing = self.spans.get(handle.index) orelse return self.insert(gpa, handle, area);
        const span = self.spanOf(area);
        if (!span.spilled and !existing.spilled and
            span.min_x == existing.min_x and span.max_x == existing.max_x and
            span.min_y == existing.min_y and span.max_y == existing.max_y)
        {
            return;
        }
        self.remove(gpa, handle);
        try self.insert(gpa, handle, area);
    }

    /// Appends every body whose cells meet `area`, without sorting or deduplicating.
    ///
    /// Private to the module: a caller must go through `Broadphase.query`, which does both.
    /// A raw bucket walk is precisely the thing ADR-0022's rule forbids reaching a result.
    fn collect(self: *const SpatialHash, gpa: Allocator, area: Bounds, out: *Candidates) Allocator.Error!void {
        if (self.cell_size <= 0) return;
        try out.items.appendSlice(gpa, self.spill.items);

        const span = self.spanOf(area);
        if (span.spilled) {
            // A query too large to bucket looks at everything, which is correct and slow, and
            // says so rather than quietly returning less than it should.
            var cells = self.cells.valueIterator();
            while (cells.next()) |list| try out.items.appendSlice(gpa, list.items);
            return;
        }

        var y = span.min_y;
        while (y <= span.max_y) : (y += 1) {
            var x = span.min_x;
            while (x <= span.max_x) : (x += 1) {
                const list = self.cells.get(.{ .x = x, .y = y }) orelse continue;
                try out.items.appendSlice(gpa, list.items);
            }
        }
    }
};

/// The two tiers, and the only way to ask them anything.
pub const Broadphase = struct {
    movers: SpatialHash = .empty,
    statics: SpatialHash = .empty,

    pub const empty: Broadphase = .{};

    pub fn deinit(self: *Broadphase, gpa: Allocator) void {
        self.movers.deinit(gpa);
        self.statics.deinit(gpa);
        self.* = .empty;
    }

    pub fn setCellSize(self: *Broadphase, size: f32) void {
        self.movers.cell_size = size;
        self.statics.cell_size = size;
    }

    fn tier(self: *Broadphase, kind: BodyKind) *SpatialHash {
        return switch (kind) {
            .static => &self.statics,
            .movable, .trigger => &self.movers,
        };
    }

    pub fn insert(
        self: *Broadphase,
        gpa: Allocator,
        handle: BodyHandle,
        kind: BodyKind,
        area: Bounds,
    ) Allocator.Error!void {
        try self.tier(kind).insert(gpa, handle, area);
    }

    pub fn remove(self: *Broadphase, gpa: Allocator, handle: BodyHandle, kind: BodyKind) void {
        self.tier(kind).remove(gpa, handle);
    }

    pub fn update(
        self: *Broadphase,
        gpa: Allocator,
        handle: BodyHandle,
        kind: BodyKind,
        area: Bounds,
    ) Allocator.Error!void {
        try self.tier(kind).update(gpa, handle, area);
    }

    /// Every body that might meet `area`, **deduplicated and sorted by handle index**.
    ///
    /// `out` is cleared first. The result may contain false positives — a body in a cell the
    /// rectangle touches but that the rectangle misses — and callers narrow it themselves;
    /// what it may not contain is a false *negative*, and what it may not do is vary with how
    /// the hash bucketed.
    pub fn query(self: *const Broadphase, gpa: Allocator, area: Bounds, out: *Candidates) Allocator.Error!void {
        out.clear();
        // Statics first, then movers, though the order of these two calls is not observable:
        // the sort below is what fixes the order, which is the point.
        try self.statics.collect(gpa, area, out);
        try self.movers.collect(gpa, area, out);
        sortAndDedupe(&out.items);
    }

    pub fn count(self: *const Broadphase) u32 {
        return self.movers.count() + self.statics.count();
    }
};

/// The rule, in code.
///
/// **`pdq` rather than the insertion sort the design named.** The key is a slot index and is
/// unique per body, so stability buys nothing, and a query covering a large region can return
/// hundreds of candidates — a size at which an O(n^2) sort is a frame, not a rounding error.
/// The design's reasoning was that candidate sets are small, which is true of the common case
/// and not guaranteed by anything; this keeps the common case fast and the uncommon one
/// survivable.
fn sortAndDedupe(items: *std.ArrayList(BodyHandle)) void {
    std.sort.pdq(BodyHandle, items.items, {}, lessByIndex);

    var write: usize = 0;
    for (items.items, 0..) |handle, read| {
        if (read > 0 and handle.index == items.items[write - 1].index) continue;
        items.items[write] = handle;
        write += 1;
    }
    items.shrinkRetainingCapacity(write);
}

fn lessByIndex(_: void, a: BodyHandle, b: BodyHandle) bool {
    return a.index < b.index;
}

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

fn handleAt(index: u32) BodyHandle {
    return .{ .index = index, .generation = 1 };
}

fn boxAt(x: f32, y: f32, half: f32) Bounds {
    return .fromCenter(.{ .x = x, .y = y }, .{ .x = half, .y = half });
}

test "the first insert decides the cell size, and configuration overrides it" {
    var hash: SpatialHash = .empty;
    defer hash.deinit(testing.allocator);

    try hash.insert(testing.allocator, handleAt(0), boxAt(0, 0, 1.5));
    try testing.expectEqual(@as(f32, 3), hash.cell_size);

    var configured: SpatialHash = .{ .cell_size = 8 };
    defer configured.deinit(testing.allocator);
    try configured.insert(testing.allocator, handleAt(0), boxAt(0, 0, 1.5));
    try testing.expectEqual(@as(f32, 8), configured.cell_size);
}

test "a body spanning several cells is found from any of them" {
    var phase: Broadphase = .empty;
    defer phase.deinit(testing.allocator);
    phase.setCellSize(1);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    // Half-extent 1.4 at the origin: cells -2..1 on both axes.
    try phase.insert(testing.allocator, handleAt(7), .movable, boxAt(0, 0, 1.4));

    try phase.query(testing.allocator, boxAt(-1.5, -1.5, 0.1), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);

    try phase.query(testing.allocator, boxAt(1.2, 1.2, 0.1), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);

    // ...and exactly once, however many of its cells the query covers.
    try phase.query(testing.allocator, boxAt(0, 0, 5), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);
    try testing.expectEqual(@as(u32, 7), out.handles()[0].index);
}

test "candidates come back sorted by handle index whatever order they went in" {
    var phase: Broadphase = .empty;
    defer phase.deinit(testing.allocator);
    phase.setCellSize(1);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);

    for ([_]u32{ 9, 2, 5, 0, 7 }) |index| {
        try phase.insert(testing.allocator, handleAt(index), .movable, boxAt(0.5, 0.5, 0.2));
    }
    try phase.query(testing.allocator, boxAt(0.5, 0.5, 0.1), &out);

    const got = out.handles();
    try testing.expectEqual(@as(usize, 5), got.len);
    for (got[1..], got[0 .. got.len - 1]) |later, earlier| {
        try testing.expect(earlier.index < later.index);
    }
}

test "the cell size never loses a body, whatever it costs in false positives" {
    // The broadphase's actual contract, stated as a test. It may return a body the rectangle
    // only shares a cell with -- a larger cell size returns more of those -- but it may never
    // omit one the rectangle truly meets. That asymmetry is what lets the structure be
    // replaced: narrowing is the caller's job and is exact, so only false *negatives* would
    // change a result. `World.queryBounds` asserts the narrowed answer is invariant.
    const sizes = [_]f32{ 0.25, 1, 4, 33 };
    const truly_inside = [_]u32{ 0, 1, 3 };

    for (sizes) |size| {
        var phase: Broadphase = .empty;
        defer phase.deinit(testing.allocator);
        phase.setCellSize(size);

        var out: Candidates = .empty;
        defer out.deinit(testing.allocator);

        try phase.insert(testing.allocator, handleAt(0), .movable, boxAt(0, 0, 0.5));
        try phase.insert(testing.allocator, handleAt(1), .static, boxAt(3, 0, 0.5));
        try phase.insert(testing.allocator, handleAt(2), .movable, boxAt(-9, 4, 2));
        try phase.insert(testing.allocator, handleAt(3), .trigger, boxAt(2.5, 0.5, 1));

        const area: Bounds = .{ .min = .{ .x = -1, .y = -1 }, .max = .{ .x = 4, .y = 1 } };
        try phase.query(testing.allocator, area, &out);

        for (truly_inside) |index| {
            var found = false;
            for (out.handles()) |handle| found = found or handle.index == index;
            if (!found) {
                std.debug.print("cell size {d} lost body {d}\n", .{ size, index });
                return error.BroadphaseLostABody;
            }
        }
        // Sorted and deduplicated, at every size.
        for (out.handles()[1..], out.handles()[0 .. out.handles().len - 1]) |later, earlier| {
            try testing.expect(earlier.index < later.index);
        }
    }
}

test "insertion order does not change the answer" {
    // I9's stronger M5 form: two descriptions of the same world must agree. The handles are
    // assigned deliberately rather than by insertion, because that is what isolates the
    // structure's order from the pool's.
    const orders = [_][4]u32{
        .{ 0, 1, 2, 3 },
        .{ 3, 2, 1, 0 },
        .{ 2, 0, 3, 1 },
    };
    const places = [_][2]f32{ .{ 0, 0 }, .{ 0.4, 0.2 }, .{ 5, 5 }, .{ 0.9, -0.3 } };

    var first: [4]u32 = undefined;
    var first_len: usize = 0;

    for (orders, 0..) |order, run| {
        var phase: Broadphase = .empty;
        defer phase.deinit(testing.allocator);
        phase.setCellSize(1);

        var out: Candidates = .empty;
        defer out.deinit(testing.allocator);

        for (order) |index| {
            const place = places[index];
            try phase.insert(testing.allocator, handleAt(index), .movable, boxAt(place[0], place[1], 0.3));
        }
        try phase.query(testing.allocator, boxAt(0.4, 0, 1), &out);

        if (run == 0) {
            first_len = out.handles().len;
            for (out.handles(), 0..) |handle, i| first[i] = handle.index;
            try testing.expectEqual(@as(usize, 3), first_len);
        } else {
            try testing.expectEqual(first_len, out.handles().len);
            for (out.handles(), 0..) |handle, i| try testing.expectEqual(first[i], handle.index);
        }
    }
}

test "a body that moves within its cells is not re-bucketed" {
    var hash: SpatialHash = .{ .cell_size = 10 };
    defer hash.deinit(testing.allocator);

    try hash.insert(testing.allocator, handleAt(0), boxAt(5, 5, 1));
    const buckets = hash.cells.count();

    // Still inside cell (0,0): the update is an early return, which is the common case in a
    // frame where most bodies move a fraction of a cell.
    try hash.update(testing.allocator, handleAt(0), boxAt(6, 6, 1));
    try testing.expectEqual(buckets, hash.cells.count());
    try testing.expectEqual(@as(u32, 1), hash.count());

    // Across a boundary: re-bucketed, and the old bucket is gone rather than left empty.
    try hash.update(testing.allocator, handleAt(0), boxAt(25, 25, 1));
    try testing.expectEqual(@as(u32, 1), hash.count());
    try testing.expectEqual(@as(?std.ArrayList(BodyHandle), null), hash.cells.get(.{ .x = 0, .y = 0 }));
}

test "removing a body empties its buckets rather than leaving them behind" {
    var hash: SpatialHash = .{ .cell_size = 1 };
    defer hash.deinit(testing.allocator);

    try hash.insert(testing.allocator, handleAt(0), boxAt(0, 0, 2.5));
    try testing.expect(hash.cells.count() > 1);

    hash.remove(testing.allocator, handleAt(0));
    try testing.expectEqual(@as(u32, 0), hash.count());
    try testing.expectEqual(@as(u32, 0), hash.cells.count());

    // Removing twice is not an error. A world that removed a body and then removed it again
    // is a caller mistake the pool already refuses; this must not corrupt anything.
    hash.remove(testing.allocator, handleAt(0));
    try testing.expectEqual(@as(u32, 0), hash.count());
}

test "an oversized body spills rather than asking for a million cells" {
    var hash: SpatialHash = .{ .cell_size = 1 };
    defer hash.deinit(testing.allocator);

    // Small first, so the cell size is not rescued by the giant's own extent.
    try hash.insert(testing.allocator, handleAt(0), boxAt(0, 0, 0.5));
    try hash.insert(testing.allocator, handleAt(1), boxAt(0, 0, 100_000));

    try testing.expectEqual(@as(usize, 1), hash.spill.items.len);
    try testing.expect(hash.cells.count() < 16);

    // And it is still found, from anywhere, because the spill list is always considered.
    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);
    var phase: Broadphase = .{ .movers = hash, .statics = .empty };
    hash = .empty;
    defer phase.deinit(testing.allocator);

    try phase.query(testing.allocator, boxAt(9_000, -9_000, 1), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);
    try testing.expectEqual(@as(u32, 1), out.handles()[0].index);
}

test "the static tier is untouched while movers move" {
    var phase: Broadphase = .empty;
    defer phase.deinit(testing.allocator);
    phase.setCellSize(1);

    try phase.insert(testing.allocator, handleAt(0), .static, boxAt(0, 0, 0.4));
    const static_buckets = phase.statics.cells.count();

    try phase.insert(testing.allocator, handleAt(1), .movable, boxAt(0, 0, 0.4));
    var step: u32 = 0;
    while (step < 20) : (step += 1) {
        const x: f32 = @floatFromInt(step);
        try phase.update(testing.allocator, handleAt(1), .movable, boxAt(x, 0, 0.4));
    }

    try testing.expectEqual(static_buckets, phase.statics.cells.count());
    try testing.expectEqual(@as(u32, 1), phase.statics.count());
    try testing.expectEqual(@as(u32, 2), phase.count());

    // A static body may still be repositioned. "Static" is a frequency, not a prohibition.
    try phase.update(testing.allocator, handleAt(0), .static, boxAt(40, 40, 0.4));
    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);
    try phase.query(testing.allocator, boxAt(40, 40, 0.1), &out);
    try testing.expectEqual(@as(usize, 1), out.handles().len);
    try testing.expectEqual(@as(u32, 0), out.handles()[0].index);
}

test "a query with no cell size yet returns nothing rather than reading an empty structure" {
    var phase: Broadphase = .empty;
    defer phase.deinit(testing.allocator);

    var out: Candidates = .empty;
    defer out.deinit(testing.allocator);
    try phase.query(testing.allocator, boxAt(0, 0, 1), &out);
    try testing.expectEqual(@as(usize, 0), out.handles().len);
}
