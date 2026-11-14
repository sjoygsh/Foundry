//! The shadow atlas's tiles (`shadows-local.md` §4, §5, ADR-0080): a row of square pages, one
//! buddy quadtree per page, rebuilt from nothing every frame, and the order and size in which
//! local lights ask for tiles. Pure: no device, no frame, so it is its own oracle.
const std = @import("std");
const core = @import("core");
const Vec3 = core.math.Vec3;
const camera_mod = @import("camera.zig");
const frustum = @import("frustum.zig");
const lighting = @import("lighting.zig");

pub const max_pages = 4;
/// The smallest tile a request may ask for.
pub const min_side = 128;
/// The largest page: two 4,096 cascade tiles a side.
pub const max_page_side = 8192;
/// Tiles a frame may hold, cascades included; compiled into the frame uniform (§8).
pub const max_tiles = lighting.max_shadow_tiles;
/// A point light, or a spot wider than `max_spot_cone`, casts through six faces (§6, §7).
pub const face_count = 6;
/// The widest spot that casts through one perspective tile, radians from its axis.
pub const max_spot_cone: f32 = std.math.pi / 3.0;

const max_levels = std.math.log2_int(u32, max_page_side / min_side) + 1;
/// Nodes in one full quadtree of `max_levels` levels: (4^levels - 1) / 3.
const nodes_per_page = (std.math.pow(u32, 4, max_levels) - 1) / 3;

/// A granted tile in atlas texels from the top-left, page offset included.
pub const Tile = struct {
    x: u32,
    y: u32,
    side: u32,

    pub fn overlaps(a: Tile, b: Tile) bool {
        return a.x < b.x + b.side and b.x < a.x + a.side and a.y < b.y + b.side and b.y < a.y + a.side;
    }
};

const Node = enum(u8) { free, split, used };

pub const Atlas = struct {
    page_side: u32,
    pages: u32,
    levels: u32,
    nodes: [max_pages][nodes_per_page]Node,

    /// `page_side` a power of two from `2 * min_side` to `max_page_side`; `pages` 1 to 4.
    pub fn init(page_side: u32, pages: u32) Atlas {
        std.debug.assert(std.math.isPowerOfTwo(page_side) and page_side >= 2 * min_side and page_side <= max_page_side);
        std.debug.assert(pages >= 1 and pages <= max_pages);
        var atlas: Atlas = .{ .page_side = page_side, .pages = pages, .levels = std.math.log2_int(u32, page_side / min_side) + 1, .nodes = undefined };
        atlas.reset();
        return atlas;
    }

    pub fn width(self: Atlas) u32 {
        return self.page_side * self.pages;
    }

    pub fn height(self: Atlas) u32 {
        return self.page_side;
    }

    /// Every page empty again: a frame's tiles never outlive it (§4).
    pub fn reset(self: *Atlas) void {
        for (&self.nodes) |*page| @memset(page, .free);
    }

    /// The first free square of `side` in the fixed walk: pages in order, then quadrants
    /// top-left, top-right, bottom-left, bottom-right, recursively. A larger free square is
    /// split only when no square of `side` is free, and then the smallest such square is.
    /// Null when nothing can hold it; nothing changes then.
    pub fn allocate(self: *Atlas, side: u32) ?Tile {
        if (side < min_side or !std.math.isPowerOfTwo(side) or side > self.page_side) return null;
        const level = std.math.log2_int(u32, self.page_side / side);
        var from = level + 1;
        while (from > 0) {
            from -= 1;
            for (0..self.pages) |page| {
                if (self.find(@intCast(page), 0, 0, 0, 0, from)) |found| {
                    // Split down through each first quadrant, whose corner is the found one's.
                    var node = found.node;
                    var at = from;
                    while (at < level) : (at += 1) {
                        self.nodes[page][node] = .split;
                        node = 4 * node + 1;
                    }
                    self.nodes[page][node] = .used;
                    return .{ .x = @as(u32, @intCast(page)) * self.page_side + found.x, .y = found.y, .side = side };
                }
            }
        }
        return null;
    }

    /// `count` tiles of one side, or none: a point light's faces filter alike only at one size.
    pub fn allocateGroup(self: *Atlas, side: u32, out: []Tile) bool {
        const saved = self.nodes;
        for (out) |*tile| {
            tile.* = self.allocate(side) orelse {
                self.nodes = saved;
                return false;
            };
        }
        return true;
    }

    const Found = struct { node: usize, x: u32, y: u32 };

    /// The first free node at `want`, descending only into split nodes, in the fixed order.
    fn find(self: *const Atlas, page: u32, node: usize, level: u32, x: u32, y: u32, want: u32) ?Found {
        const state = self.nodes[page][node];
        if (level == want) return if (state == .free) .{ .node = node, .x = x, .y = y } else null;
        if (state != .split) return null;
        const half = (self.page_side >> @intCast(level)) / 2;
        for (0..4) |q| {
            const qx = x + @as(u32, @intCast(q % 2)) * half;
            const qy = y + @as(u32, @intCast(q / 2)) * half;
            if (self.find(page, 4 * node + 1 + q, level + 1, qx, qy, want)) |found| return found;
        }
        return null;
    }
};

/// What a seen casting light asks of the atlas this frame (§5).
pub const Request = struct {
    /// The light's index in submission order.
    light: u32,
    /// From the camera to the nearest point of its range sphere, 0 inside it or unbounded.
    distance: f32,
    side: u32,
    /// One for a spot to `max_spot_cone`; six for a point or a wider spot.
    faces: u32,
};

pub const Limits = struct { min: u32, max: u32 };

/// The faces a local light casts through.
pub fn facesOf(light: lighting.Light) u32 {
    return if (light.kind == .spot and light.outer_cone <= max_spot_cone) 1 else face_count;
}

/// A light's range sphere's projected diameter in pixels, capped at the target's larger side:
/// the whole target when unbounded or when the sphere holds the camera.
pub fn coverage(center: Vec3, range: f32, camera: camera_mod.Camera, target_width: u32, target_height: u32) f32 {
    const cap: f32 = @floatFromInt(@max(target_width, target_height));
    if (range == 0) return cap;
    const d = center.sub(camera.position).length();
    if (d <= range) return cap;
    // The sphere's angular radius, as the tangent the projection divides by.
    const tangent = range / @sqrt(d * d - range * range);
    const pixels = @as(f32, @floatFromInt(target_height)) * tangent / @tan(camera.vertical_fov * 0.5);
    return @min(cap, pixels);
}

/// The power of two at or above half the coverage, clamped to the limits.
pub fn sideFor(pixels: f32, limits: Limits) u32 {
    const half = @max(1, @ceil(pixels * 0.5));
    if (half >= @as(f32, @floatFromInt(limits.max))) return limits.max;
    const side = std.math.ceilPowerOfTwoAssert(u32, @intFromFloat(half));
    return std.math.clamp(side, limits.min, limits.max);
}

/// A casting point or spot light's request, or null when the camera cannot see its sphere
/// (or its range is no farther than the shadow's near plane), which casts nothing (§5).
pub fn requestFor(light: lighting.Light, index: u32, camera: camera_mod.Camera, view: frustum.Frustum, target_width: u32, target_height: u32, near: f32, limits: Limits) ?Request {
    std.debug.assert(light.kind != .directional);
    const center = Vec3.init(light.world.cols[3][0], light.world.cols[3][1], light.world.cols[3][2]);
    var distance: f32 = 0;
    if (light.range != 0) {
        if (light.range <= near) return null;
        if (view.excludes(.{ .center = center, .extent = .init(light.range, light.range, light.range) })) return null;
        distance = @max(0, center.sub(camera.position).length() - light.range);
    }
    return .{
        .light = index,
        .distance = distance,
        .side = sideFor(coverage(center, light.range, camera, target_width, target_height), limits),
        .faces = facesOf(light),
    };
}

/// Nearest first, ties by submission order: a stable insertion sort, so the order is a pure
/// function of the requests.
pub fn order(requests: []Request) void {
    if (requests.len < 2) return;
    for (1..requests.len) |i| {
        const item = requests[i];
        var j = i;
        while (j > 0 and before(item, requests[j - 1])) : (j -= 1) requests[j] = requests[j - 1];
        requests[j] = item;
    }
}

fn before(a: Request, b: Request) bool {
    return a.distance < b.distance or (a.distance == b.distance and a.light < b.light);
}

pub const Placed = struct {
    request: Request,
    /// The side granted, at most the request's.
    side: u32,
    first_tile: u32,
};

pub const Placement = struct {
    placed: [max_tiles]Placed = undefined,
    count: u32 = 0,
    dropped: u32 = 0,
};

/// Ordered requests into the atlas after whatever it already holds: each at its side, then
/// halved down to `limits.min`, all its faces at one side; one that does not fit at the
/// minimum, or would pass `max_tiles`, is dropped and counted. `tiles` receives every grant
/// after `tile_count` existing ones, in order.
pub fn place(atlas: *Atlas, requests: []const Request, limits: Limits, tiles: *[max_tiles]Tile, tile_count: *u32) Placement {
    var result: Placement = .{};
    for (requests) |request| {
        if (tile_count.* + request.faces > max_tiles) {
            result.dropped += 1;
            continue;
        }
        var side = request.side;
        const granted = while (true) {
            if (atlas.allocateGroup(side, tiles[tile_count.*..][0..request.faces])) break true;
            if (side <= limits.min) break false;
            side /= 2;
        };
        if (!granted) {
            result.dropped += 1;
            continue;
        }
        result.placed[result.count] = .{ .request = request, .side = side, .first_tile = tile_count.* };
        result.count += 1;
        tile_count.* += request.faces;
    }
    return result;
}

const testing = std.testing;

test "one to four cascades are granted M39's tiles, column i mod 2 and row i / 2" {
    for (1..5) |count| {
        var atlas = Atlas.init(2048, 2);
        for (0..count) |i| {
            const tile = atlas.allocate(1024).?;
            try testing.expectEqual(Tile{ .x = @as(u32, @intCast(i % 2)) * 1024, .y = @as(u32, @intCast(i / 2)) * 1024, .side = 1024 }, tile);
        }
    }
}

test "the walk is fixed: a mixed set of requests always gets the same tiles" {
    const sides = [_]u32{ 1024, 1024, 512, 256, 256, 1024, 2048, 128, 512 };
    const want = [_]?Tile{
        .{ .x = 0, .y = 0, .side = 1024 },     .{ .x = 1024, .y = 0, .side = 1024 },
        .{ .x = 0, .y = 1024, .side = 512 },   .{ .x = 512, .y = 1024, .side = 256 },
        .{ .x = 768, .y = 1024, .side = 256 }, .{ .x = 1024, .y = 1024, .side = 1024 },
        .{ .x = 2048, .y = 0, .side = 2048 },  .{ .x = 512, .y = 1280, .side = 128 },
        .{ .x = 0, .y = 1536, .side = 512 },
    };
    for (0..2) |_| {
        var atlas = Atlas.init(2048, 2);
        for (sides, want) |side, tile| try testing.expectEqual(tile, atlas.allocate(side));
    }
}

test "a request no free square can hold is refused and changes nothing, and a smaller one still fits" {
    var atlas = Atlas.init(1024, 1);
    _ = atlas.allocate(512).?;
    _ = atlas.allocate(512).?;
    _ = atlas.allocate(512).?;
    const before_refusal = atlas.nodes;
    try testing.expectEqual(@as(?Tile, null), atlas.allocate(1024));
    try testing.expectEqualSlices(Node, &before_refusal[0], &atlas.nodes[0]);
    try testing.expectEqual(Tile{ .x = 512, .y = 512, .side = 256 }, atlas.allocate(256).?);
    // Not a power of two, too small, or larger than a page.
    for ([_]u32{ 0, 300, 64, 2048 }) |side| try testing.expectEqual(@as(?Tile, null), atlas.allocate(side));
}

test "a group takes all its tiles at one side or none" {
    var atlas = Atlas.init(1024, 1);
    _ = atlas.allocate(512).?;
    _ = atlas.allocate(512).?;
    _ = atlas.allocate(512).?;
    var faces: [face_count]Tile = undefined;
    const saved = atlas.nodes;
    // The last quadrant holds four 256 tiles, not six.
    try testing.expect(!atlas.allocateGroup(256, &faces));
    try testing.expectEqualSlices(Node, &saved[0], &atlas.nodes[0]);
    try testing.expect(atlas.allocateGroup(128, &faces));
    for (faces[1..]) |face| try testing.expectEqual(@as(u32, 128), face.side);
}

test "no two grants overlap, over a seeded sweep of a thousand request lists" {
    var rng = core.rng.Pcg32.init(40, 2);
    for (0..1000) |_| {
        var atlas = Atlas.init(2048, 1 + rng.below(max_pages));
        var grants: [256]Tile = undefined;
        var n: usize = 0;
        for (0..1 + rng.below(64)) |_| {
            const side = @as(u32, min_side) << @intCast(rng.below(5));
            if (atlas.allocate(side)) |tile| {
                try testing.expect(tile.x + tile.side <= atlas.width() and tile.y + tile.side <= atlas.height());
                try testing.expectEqual(@as(u32, 0), tile.x % tile.side);
                for (grants[0..n]) |other| try testing.expect(!tile.overlaps(other));
                grants[n] = tile;
                n += 1;
            }
        }
    }
}

test "requests go nearest sphere first, ties by submission, and sizes follow coverage" {
    const camera: camera_mod.Camera = .{ .position = .zero, .rotation = .identity, .vertical_fov = std.math.pi / 3.0, .near = 0.1, .far = 80 };
    const view = frustum.Frustum.fromViewProjection(camera.viewProjection(1280, 720));
    const limits: Limits = .{ .min = 256, .max = 1024 };
    const at = struct {
        fn light(kind: @FieldType(lighting.Light, "kind"), p: Vec3, range: f32) lighting.Light {
            return .{ .kind = kind, .intensity = 1, .range = range, .casts_shadow = true, .world = core.math.Mat4.translation(p) };
        }
    };
    const lights = [_]lighting.Light{
        at.light(.point, .init(0, 0, -30), 4), // 26 m away
        at.light(.point, .init(0, 0, -10), 4), // 6 m
        at.light(.spot, .init(0, 0, -2), 4), // holds the camera: 0
        at.light(.point, .init(0, 0, 30), 4), // behind: unseen
        at.light(.point, .init(5, 0, -20), 0), // unbounded: 0
        at.light(.point, .init(0, 0, -10.0), 4), // ties the second, later
    };
    var requests: [lights.len]Request = undefined;
    var n: usize = 0;
    for (lights, 0..) |light, i| {
        if (requestFor(light, @intCast(i), camera, view, 1280, 720, 0.05, limits)) |r| {
            requests[n] = r;
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 5), n);
    // No requests, and one, are already in order.
    order(requests[0..0]);
    order(requests[0..1]);
    order(requests[0..n]);
    const want = [_]u32{ 2, 4, 1, 5, 0 };
    for (requests[0..n], want) |r, light| try testing.expectEqual(light, r.light);
    try testing.expectEqual(@as(f32, 0), requests[0].distance);
    try testing.expectApproxEqAbs(@as(f32, 6), requests[2].distance, 1e-5);
    // Holding the camera or unbounded: the whole target, so the largest tile.
    try testing.expectEqual(@as(u32, 1024), requests[0].side);
    try testing.expectEqual(@as(u32, 1024), requests[1].side);
    // A default 45-degree spot casts through one tile, a point through six.
    try testing.expectEqual(@as(u32, 1), requests[0].faces);
    try testing.expectEqual(@as(u32, 6), requests[2].faces);
    // 26 m away, 4 m of range: about 168 pixels across, so a 128 request, clamped up to 256.
    try testing.expectEqual(@as(u32, 256), requests[4].side);
    // A range no farther than the shadow's near plane casts nothing.
    try testing.expectEqual(@as(?Request, null), requestFor(at.light(.point, .init(0, 0, -5), 0.04), 0, camera, view, 1280, 720, 0.05, limits));
}

test "a wide spot casts through six faces, and sides are powers of two at or above half the coverage" {
    var spot: lighting.Light = .{ .kind = .spot, .intensity = 1, .outer_cone = max_spot_cone, .world = .identity };
    try testing.expectEqual(@as(u32, 1), facesOf(spot));
    spot.outer_cone = max_spot_cone + 0.01;
    try testing.expectEqual(@as(u32, face_count), facesOf(spot));
    const limits: Limits = .{ .min = 256, .max = 1024 };
    try testing.expectEqual(@as(u32, 256), sideFor(1, limits));
    try testing.expectEqual(@as(u32, 512), sideFor(513 * 2 - 2, limits));
    try testing.expectEqual(@as(u32, 1024), sideFor(1026, limits));
    try testing.expectEqual(@as(u32, 1024), sideFor(5000, limits));
}

test "a full atlas halves a request, then drops it, counted, and the tile limit drops too" {
    var atlas = Atlas.init(1024, 1);
    var tiles: [max_tiles]Tile = undefined;
    var count: u32 = 0;
    tiles[0] = atlas.allocate(512).?;
    tiles[1] = atlas.allocate(512).?;
    tiles[2] = atlas.allocate(512).?;
    count = 3;
    // One free 512 quadrant: four 256s, or sixteen 128s.
    const requests = [_]Request{
        .{ .light = 0, .distance = 0, .side = 512, .faces = 6 }, // six fit only at 128: halved twice
        .{ .light = 1, .distance = 1, .side = 256, .faces = 1 }, // the third 256
        .{ .light = 2, .distance = 2, .side = 256, .faces = 1 }, // the fourth
        .{ .light = 3, .distance = 3, .side = 128, .faces = 6 }, // two 128s left: dropped
    };
    const placement = place(&atlas, &requests, .{ .min = 128, .max = 1024 }, &tiles, &count);
    try testing.expectEqual(@as(u32, 3), placement.count);
    try testing.expectEqual(@as(u32, 128), placement.placed[0].side);
    try testing.expectEqual(@as(u32, 3), placement.placed[0].first_tile);
    try testing.expectEqual(@as(u32, 256), placement.placed[1].side);
    try testing.expectEqual(@as(u32, 10), placement.placed[2].first_tile);
    try testing.expectEqual(Tile{ .x = 768, .y = 768, .side = 256 }, tiles[10]);
    try testing.expectEqual(@as(u32, 1), placement.dropped);
    try testing.expectEqual(@as(u32, 11), count);

    // Thirty-two tiles at most: four cascades and four points fill them, and a fifth point drops.
    var big = Atlas.init(8192, 4);
    count = 0;
    for (0..4) |i| {
        tiles[i] = big.allocate(4096).?;
        count += 1;
    }
    var points: [5]Request = undefined;
    for (&points, 0..) |*r, i| r.* = .{ .light = @intCast(i), .distance = 0, .side = 128, .faces = 6 };
    const full = place(&big, &points, .{ .min = 128, .max = 1024 }, &tiles, &count);
    try testing.expectEqual(@as(u32, 4), full.count);
    try testing.expectEqual(@as(u32, 1), full.dropped);
    try testing.expectEqual(@as(u32, 28), count);
}
