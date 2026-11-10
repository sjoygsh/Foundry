//! A convex hull's faces, found from its points (`collision-scale.md` §6, ADR-0078).
//!
//! The points are never changed: the narrowphase still measures a hull by its points alone.
//! What this adds is each face's plane, so a hit can say which face it lies on, and `reduce`,
//! which names the points that are the hull's own corners.
//!
//! It works in two parts, in f64. First the hull itself is built as triangles, one point at a
//! time in the order given, as exactly as f64 allows: no point is moved, merged or left out for
//! being near a plane. Then triangles whose corners lie on one plane, within a tolerance scaled
//! by the hull's size, are gathered into one face, so a box's eight corners give six faces and
//! not twelve triangles. Only the second part is lenient, and it cannot open the surface.
//! The same points in the same order give the same faces (I9).
const std = @import("std");
const core = @import("core");
const Vec3 = core.math.Vec3;
const Allocator = std.mem.Allocator;

/// A face's plane in the hull's own space: `normal · p == offset` on it, and less inside.
pub const Plane = struct {
    /// Unit, out of the hull.
    normal: Vec3,
    offset: f32,
};

/// The most points a hull holds, `shape.max_hull_points`.
pub const max_points: usize = 256;
/// The most faces `max_points` points can have: 2n − 4 triangles, when no two share a plane.
pub const max_faces: usize = 2 * max_points - 4;
/// Triangles whose corners are within this fraction of the hull's diagonal of one plane are one
/// face.
pub const plane_tolerance: f64 = 1e-5;
/// What f64 arithmetic on f32 points cannot tell from zero, as a fraction of the diagonal. A
/// point this near a triangle's plane is on it while the hull is built.
const exact_tolerance: f64 = 1e-10;

pub const ReduceError = error{
    OutOfMemory,
    /// The points have no volume: they are one point, a line or a plane, within the tolerance.
    Flat,
    /// The hull has more than `max_points` corners.
    TooManyPoints,
    /// The hull could not be built: rounding left no consistent surface over the points. No
    /// input is known to do this.
    Tangled,
};

/// The planes of the hull's faces, largest face first, owned by the caller. Empty when the points
/// are flat within the tolerance or the hull could not be built: such a hull still collides by
/// its points, and reports the contact normal as its surface's.
pub fn faces(gpa: Allocator, points: []const Vec3) error{OutOfMemory}![]Plane {
    var builder = Builder.init(gpa, points) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Flat, error.Tangled => return &.{},
    };
    defer builder.deinit();
    const out = try gpa.alloc(Plane, builder.face_count);
    for (builder.tris.items) |tri| {
        if (!tri.alive or !tri.seed) continue;
        out[tri.face] = .{
            .normal = .init(@floatCast(tri.normal.x), @floatCast(tri.normal.y), @floatCast(tri.normal.z)),
            // The builder measures from the hull's low corner. The plane is the hull's own.
            .offset = @floatCast(tri.offset + tri.normal.dot(builder.origin)),
        };
    }
    return out;
}

/// The points that are corners of the hull, in the order they were given, owned by the caller.
/// A point inside the hull, on a face or along an edge is not one, and neither is a repeat.
pub fn reduce(gpa: Allocator, points: []const Vec3) ReduceError![]Vec3 {
    var builder = try Builder.init(gpa, points);
    defer builder.deinit();
    // A corner is where three faces or more meet. A point two faces share is along an edge.
    const met = try gpa.alloc([3]u32, points.len);
    defer gpa.free(met);
    const none = std.math.maxInt(u32);
    @memset(met, .{ none, none, none });
    for (builder.tris.items) |tri| {
        if (!tri.alive) continue;
        for (tri.v) |v| for (&met[v]) |*slot| {
            if (slot.* == tri.face) break;
            if (slot.* == none) {
                slot.* = tri.face;
                break;
            }
        };
    }
    var count: usize = 0;
    for (met) |m| count += @intFromBool(m[2] != none);
    if (count > max_points) return error.TooManyPoints;
    const out = try gpa.alloc(Vec3, count);
    var at: usize = 0;
    for (met, points) |m, p| if (m[2] != none) {
        out[at] = p;
        at += 1;
    };
    return out;
}

const D3 = struct {
    x: f64,
    y: f64,
    z: f64,

    fn of(p: Vec3) D3 {
        return .{ .x = p.x, .y = p.y, .z = p.z };
    }
    fn sub(a: D3, b: D3) D3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    fn dot(a: D3, b: D3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    fn cross(a: D3, b: D3) D3 {
        return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
    }
    fn scale(a: D3, s: f64) D3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
};

const no_tri = std.math.maxInt(u32);

const Tri = struct {
    /// Counter-clockwise seen from outside.
    v: [3]u32,
    /// The triangle across the edge from `v[i]` to `v[i + 1]`.
    adj: [3]u32 = .{ no_tri, no_tri, no_tri },
    normal: D3,
    offset: f64,
    /// Twice the triangle's area.
    area: f64,
    alive: bool = true,
    /// Being taken away by the point now being added.
    going: bool = false,
    /// The face this triangle is part of, and whether its plane is that face's.
    face: u32 = no_tri,
    seed: bool = false,
};

const Builder = struct {
    gpa: Allocator,
    points: []const Vec3,
    /// The points' low corner, which every point is measured from. The difference of two f32s
    /// is exact in f64, so nothing is lost, and a hull far from its origin is built as well as
    /// one at it.
    origin: D3,
    /// On a plane, while building.
    exact: f64,
    /// On a plane, when gathering triangles into faces.
    tolerance: f64,
    tris: std.ArrayList(Tri) = .empty,
    free: std.ArrayList(u32) = .empty,
    face_count: u32 = 0,

    const Error = error{ OutOfMemory, Flat, Tangled };

    fn deinit(self: *Builder) void {
        self.tris.deinit(self.gpa);
        self.free.deinit(self.gpa);
    }

    fn at(self: *const Builder, index: u32) D3 {
        return D3.of(self.points[index]).sub(self.origin);
    }

    fn init(gpa: Allocator, points: []const Vec3) Error!Builder {
        if (points.len < 4) return error.Flat;
        var low = D3.of(points[0]);
        var high = low;
        var reach: f64 = 0;
        for (points) |point| {
            const p = D3.of(point);
            low = .{ .x = @min(low.x, p.x), .y = @min(low.y, p.y), .z = @min(low.z, p.z) };
            high = .{ .x = @max(high.x, p.x), .y = @max(high.y, p.y), .z = @max(high.z, p.z) };
            reach = @max(reach, @max(@abs(p.x), @max(@abs(p.y), @abs(p.z))));
        }
        const diagonal = @sqrt(high.sub(low).dot(high.sub(low)));
        if (!(diagonal > 0) or !std.math.isFinite(diagonal)) return error.Flat;
        var self: Builder = .{
            .gpa = gpa,
            .points = points,
            .origin = low,
            .exact = exact_tolerance * diagonal,
            // Points far from their own origin were rounded to f32 there, and corners meant to
            // share a plane miss it by that much. The tolerance never falls under it.
            .tolerance = @max(plane_tolerance * diagonal, 8.0 * std.math.floatEps(f32) * reach),
        };
        errdefer self.deinit();
        const first = try self.start();
        // Each link a point makes, by the vertex its edge of the horizon starts and ends at.
        const starts = try gpa.alloc(u32, points.len * 2);
        defer gpa.free(starts);
        @memset(starts, no_tri);
        var horizon: std.ArrayList(Edge) = .empty;
        defer horizon.deinit(gpa);
        for (0..points.len) |i| {
            if (std.mem.indexOfScalar(u32, &first, @intCast(i)) != null) continue;
            try self.add(@intCast(i), starts[0..points.len], starts[points.len..], &horizon);
        }
        try self.check();
        try self.group();
        return self;
    }

    /// The first four corners: the lowest x, the point farthest from it, the point farthest from
    /// their line, and the point farthest from their plane. Each tie goes to the lower index.
    fn start(self: *Builder) Error![4]u32 {
        const n: u32 = @intCast(self.points.len);
        var a: u32 = 0;
        for (1..n) |i| if (self.points[i].x < self.points[a].x) {
            a = @intCast(i);
        };
        var b = a;
        var best: f64 = 0;
        for (0..n) |i| {
            const d = self.at(@intCast(i)).sub(self.at(a));
            if (d.dot(d) > best) {
                best = d.dot(d);
                b = @intCast(i);
            }
        }
        if (!(@sqrt(best) > self.tolerance)) return error.Flat;
        const axis = self.at(b).sub(self.at(a));
        var c = a;
        best = 0;
        for (0..n) |i| {
            const k = axis.cross(self.at(@intCast(i)).sub(self.at(a)));
            if (k.dot(k) > best) {
                best = k.dot(k);
                c = @intCast(i);
            }
        }
        if (!(@sqrt(best / axis.dot(axis)) > self.tolerance)) return error.Flat;
        var normal = axis.cross(self.at(c).sub(self.at(a)));
        normal = normal.scale(1 / @sqrt(normal.dot(normal)));
        var d = a;
        best = 0;
        var above = false;
        for (0..n) |i| {
            const h = normal.dot(self.at(@intCast(i)).sub(self.at(a)));
            if (@abs(h) > best) {
                best = @abs(h);
                d = @intCast(i);
                above = h > 0;
            }
        }
        if (!(best > 4 * self.tolerance)) return error.Flat;
        // `d` goes under the first triangle, so that triangle faces out.
        if (above) std.mem.swap(u32, &b, &c);
        try self.tris.ensureTotalCapacity(self.gpa, 4);
        for ([_][3]u32{ .{ a, b, c }, .{ a, d, b }, .{ b, d, c }, .{ c, d, a } }) |v| {
            self.tris.appendAssumeCapacity(try self.triangle(v));
        }
        for (self.tris.items, 0..) |*tri, t| for (0..3) |e| {
            for (self.tris.items, 0..) |other, u| {
                if (u == t) continue;
                for (0..3) |f| if (other.v[f] == tri.v[(e + 1) % 3] and other.v[(f + 1) % 3] == tri.v[e]) {
                    tri.adj[e] = @intCast(u);
                };
            }
        };
        return .{ a, b, c, d };
    }

    fn triangle(self: *const Builder, v: [3]u32) error{Tangled}!Tri {
        const a = self.at(v[0]);
        const k = self.at(v[1]).sub(a).cross(self.at(v[2]).sub(a));
        const area = @sqrt(k.dot(k));
        if (!(area > 0) or !std.math.isFinite(area)) return error.Tangled;
        const normal = k.scale(1 / area);
        return .{ .v = v, .normal = normal, .offset = normal.dot(a), .area = area };
    }

    fn height(self: *const Builder, tri: Tri, point: u32) f64 {
        return tri.normal.dot(self.at(point)) - tri.offset;
    }

    const Edge = struct { from: u32, to: u32, outside: u32, made: u32 = no_tri };

    /// Adds one point. A point over no triangle is inside the hull or on it, and changes
    /// nothing. Otherwise every triangle the point is over goes, and the hole is closed by a fan
    /// from the point to the hole's rim. A new triangle whose point is exactly on the plane of
    /// the triangle across the rim takes that plane as its own: it is more of the same face, and
    /// it may have no area to find a plane from, when the point is in line with the rim's edge.
    fn add(self: *Builder, point: u32, starts: []u32, ends: []u32, horizon: *std.ArrayList(Edge)) Error!void {
        var kept: usize = 0;
        var going: usize = 0;
        for (self.tris.items) |*tri| {
            if (!tri.alive) continue;
            tri.going = self.height(tri.*, point) > self.exact;
            kept += @intFromBool(!tri.going);
            going += @intFromBool(tri.going);
        }
        if (going == 0) return;
        if (kept == 0) return error.Tangled;

        horizon.clearRetainingCapacity();
        defer for (horizon.items) |edge| {
            starts[edge.from] = no_tri;
            ends[edge.to] = no_tri;
        };
        for (self.tris.items) |tri| {
            if (!tri.alive or !tri.going) continue;
            for (0..3) |e| {
                if (self.tris.items[tri.adj[e]].going) continue;
                const edge: Edge = .{ .from = tri.v[e], .to = tri.v[(e + 1) % 3], .outside = tri.adj[e] };
                // A rim that passes through a vertex twice is not one loop.
                if (starts[edge.from] != no_tri or ends[edge.to] != no_tri) {
                    try horizon.append(self.gpa, edge);
                    return error.Tangled;
                }
                starts[edge.from] = @intCast(horizon.items.len);
                ends[edge.to] = @intCast(horizon.items.len);
                try horizon.append(self.gpa, edge);
            }
        }
        if (horizon.items.len < 3) return error.Tangled;
        // One loop, not two: walking from the first edge must come back after every edge.
        var walked: usize = 0;
        var cursor: u32 = 0;
        while (true) {
            walked += 1;
            cursor = starts[horizon.items[cursor].to];
            if (cursor == no_tri or walked > horizon.items.len) return error.Tangled;
            if (cursor == 0) break;
        }
        if (walked != horizon.items.len) return error.Tangled;

        // The triangles going give their places to the new ones.
        for (self.tris.items, 0..) |*tri, t| if (tri.alive and tri.going) {
            tri.alive = false;
            tri.going = false;
            try self.free.append(self.gpa, @intCast(t));
        };
        try self.tris.ensureUnusedCapacity(self.gpa, horizon.items.len);
        for (horizon.items) |*edge| {
            const across = self.tris.items[edge.outside];
            var made: Tri = undefined;
            if (@abs(self.height(across, point)) <= self.exact) {
                const a = self.at(edge.from);
                const k = self.at(edge.to).sub(a).cross(self.at(point).sub(a));
                made = .{ .v = .{ edge.from, edge.to, point }, .normal = across.normal, .offset = across.offset, .area = @sqrt(k.dot(k)) };
            } else {
                made = try self.triangle(.{ edge.from, edge.to, point });
            }
            if (self.free.pop()) |slot| {
                edge.made = slot;
                self.tris.items[slot] = made;
            } else {
                edge.made = @intCast(self.tris.items.len);
                self.tris.appendAssumeCapacity(made);
            }
        }
        for (horizon.items) |edge| {
            const made = &self.tris.items[edge.made];
            made.adj = .{ edge.outside, horizon.items[starts[edge.to]].made, horizon.items[ends[edge.from]].made };
            const outside = &self.tris.items[edge.outside];
            for (0..3) |e| if (outside.v[e] == edge.to and outside.v[(e + 1) % 3] == edge.from) {
                outside.adj[e] = edge.made;
            };
        }
    }

    /// The surface is closed, and no point is outside it.
    fn check(self: *const Builder) error{Tangled}!void {
        for (self.tris.items, 0..) |tri, t| {
            if (!tri.alive) continue;
            for (0..3) |e| {
                if (tri.adj[e] == no_tri) return error.Tangled;
                const other = self.tris.items[tri.adj[e]];
                if (!other.alive) return error.Tangled;
                var back = false;
                for (0..3) |f| {
                    if (other.adj[f] == t and other.v[f] == tri.v[(e + 1) % 3] and other.v[(f + 1) % 3] == tri.v[e]) back = true;
                }
                if (!back) return error.Tangled;
            }
            for (0..self.points.len) |i| {
                if (self.height(tri, @intCast(i)) > 0.01 * self.tolerance) return error.Tangled;
            }
        }
    }

    /// Gathers triangles into faces. The largest triangle not yet in a face starts one, and takes
    /// every triangle reached across an edge whose corners are all on its plane. Each is measured
    /// against the first triangle's plane and never its neighbour's, so a gentle curve does not
    /// creep into one face.
    fn group(self: *Builder) error{ OutOfMemory, Flat }!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.gpa);
        while (true) {
            var seed: u32 = no_tri;
            for (self.tris.items, 0..) |tri, t| {
                if (!tri.alive or tri.face != no_tri) continue;
                if (seed == no_tri or tri.area > self.tris.items[seed].area) seed = @intCast(t);
            }
            if (seed == no_tri) break;
            const plane = self.tris.items[seed];
            self.tris.items[seed].face = self.face_count;
            self.tris.items[seed].seed = true;
            try stack.append(self.gpa, seed);
            while (stack.pop()) |t| {
                for (self.tris.items[t].adj) |next| {
                    const other = &self.tris.items[next];
                    if (other.face != no_tri or other.normal.dot(plane.normal) <= 0) continue;
                    var on = true;
                    for (other.v) |v| on = on and @abs(self.height(plane, v)) <= 2 * self.tolerance;
                    if (!on) continue;
                    other.face = self.face_count;
                    try stack.append(self.gpa, next);
                }
            }
            self.face_count += 1;
        }
        // Thinner than the tolerance can tell: its two sides took everything between them.
        if (self.face_count < 4) return error.Flat;
    }
};

const testing = std.testing;

fn expectPlane(planes: []const Plane, normal: Vec3, offset: f32) !void {
    for (planes) |plane| {
        if (plane.normal.sub(normal).length() < 1e-5 and @abs(plane.offset - offset) < 1e-5) return;
    }
    return error.TestExpectedPlane;
}

/// Every point is on or under every plane, and every plane holds three points or more.
fn expectHull(points: []const Vec3, planes: []const Plane) !void {
    var reach: f32 = 0;
    var low = points[0];
    var high = points[0];
    for (points) |p| {
        reach = @max(reach, p.length());
        low = .init(@min(low.x, p.x), @min(low.y, p.y), @min(low.z, p.z));
        high = .init(@max(high.x, p.x), @max(high.y, p.y), @max(high.z, p.z));
    }
    // The gathering tolerance, twice over, and what f32 loses far from the origin.
    const slack = 4e-5 * high.sub(low).length() + 32 * std.math.floatEps(f32) * reach;
    try testing.expect(planes.len >= 4 and planes.len <= max_faces);
    for (planes) |plane| {
        try testing.expectApproxEqAbs(@as(f32, 1), plane.normal.length(), 1e-5);
        var on: usize = 0;
        for (points) |p| {
            const h = plane.normal.dot(p) - plane.offset;
            try testing.expect(h <= slack);
            on += @intFromBool(h >= -slack);
        }
        try testing.expect(on >= 3);
    }
}

const cube = [_]Vec3{
    .init(-1, -1, -1), .init(1, -1, -1), .init(1, 1, -1), .init(-1, 1, -1),
    .init(-1, -1, 1),  .init(1, -1, 1),  .init(1, 1, 1),  .init(-1, 1, 1),
};

test "hull: a box's corners give six faces, in any order and with points inside" {
    const gpa = testing.allocator;
    const planes = try faces(gpa, &cube);
    defer gpa.free(planes);
    try testing.expectEqual(@as(usize, 6), planes.len);
    for ([_]Vec3{ .init(1, 0, 0), .init(-1, 0, 0), .init(0, 1, 0), .init(0, -1, 0), .init(0, 0, 1), .init(0, 0, -1) }) |n| {
        try expectPlane(planes, n, 1);
    }
    try expectHull(&cube, planes);

    // The corners shuffled, with the centre, face centres, edge midpoints and repeats among them.
    var rng = core.rng.Pcg32.init(4, 38);
    for (0..64) |_| {
        var many: [8 + 1 + 6 + 12 + 4]Vec3 = undefined;
        var n: usize = 0;
        for (cube) |p| {
            many[n] = p;
            n += 1;
        }
        many[n] = .zero;
        n += 1;
        for ([_]Vec3{ .init(1, 0, 0), .init(-1, 0, 0), .init(0, 1, 0), .init(0, -1, 0), .init(0, 0, 1), .init(0, 0, -1) }) |p| {
            many[n] = p;
            n += 1;
        }
        for (0..12) |e| {
            const s: f32 = if (e & 1 == 0) -1 else 1;
            const u: f32 = if (e & 2 == 0) -1 else 1;
            many[n] = switch (e / 4) {
                0 => .init(0, s, u),
                1 => .init(s, 0, u),
                else => .init(s, u, 0),
            };
            n += 1;
        }
        for (0..4) |i| {
            many[n] = cube[i * 2];
            n += 1;
        }
        var i = many.len;
        while (i > 1) : (i -= 1) std.mem.swap(Vec3, &many[i - 1], &many[rng.below(@intCast(i))]);
        const again = try faces(gpa, &many);
        defer gpa.free(again);
        try testing.expectEqual(@as(usize, 6), again.len);
        try expectHull(&many, again);
        const corners = try reduce(gpa, &many);
        defer gpa.free(corners);
        try testing.expectEqual(@as(usize, 8), corners.len);
        // In the order given, each a corner, none twice.
        var at: usize = 0;
        for (corners) |corner| {
            try testing.expectEqual(@as(f32, 3), corner.lengthSquared());
            while (!many[at].eql(corner)) at += 1;
            at += 1;
        }
    }
}

test "hull: a turned box has six faces, far from its origin and with coarse corners, and a bumped one has more" {
    const gpa = testing.allocator;
    var rng = core.rng.Pcg32.init(21, 38);
    for (0..64) |round| {
        // Turned corners are rounded to f32, so no four of them share a plane exactly. Far from
        // the origin they are rounded more coarsely still.
        const rotation = core.math.Quat.fromAxisAngle(Vec3.init(rng.float01() - 0.5, rng.float01() + 0.1, rng.float01() - 0.5).normalize(), rng.float01() * 6);
        const far: Vec3 = switch (round % 3) {
            0 => .zero,
            1 => .init(900, -900, 450),
            else => .init(8000, -8000, 4000),
        };
        // And every third box has each corner off by a few millionths of its size, as a file
        // that stores coarse numbers would leave them.
        const coarse: f32 = if (round % 3 == 0 and round % 2 == 0) 3e-5 else 0;
        var box: [8]Vec3 = undefined;
        for (&box, cube) |*p, corner| {
            const off = Vec3.init(rng.float01() - 0.5, rng.float01() - 0.5, rng.float01() - 0.5).scale(coarse);
            p.* = rotation.rotate(corner.mul(.init(1, 0.25, 3))).add(off).add(far);
        }
        const planes = try faces(gpa, &box);
        defer gpa.free(planes);
        try testing.expectEqual(@as(usize, 6), planes.len);
        try expectHull(&box, planes);
        const corners = try reduce(gpa, &box);
        defer gpa.free(corners);
        try testing.expectEqualSlices(Vec3, &box, corners);

        // One corner pushed out by a thousandth of the box is a real bump on three faces. Eight
        // kilometres out, f32 cannot hold a thousandth of this box, and the bump is not tried.
        if (round % 3 == 2) continue;
        box[6] = box[6].add(rotation.rotate(.init(0.006, 0.006, 0.006)));
        const dented = try faces(gpa, &box);
        defer gpa.free(dented);
        try testing.expect(dented.len > 6);
        try expectHull(&box, dented);
    }
}

test "hull: a tetrahedron, an octahedron and a sixteen-sided rim give their faces" {
    const gpa = testing.allocator;
    const tetra = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1) };
    const four = try faces(gpa, &tetra);
    defer gpa.free(four);
    try testing.expectEqual(@as(usize, 4), four.len);
    try expectPlane(four, .init(-1, 0, 0), 0);
    try expectPlane(four, .init(0, -1, 0), 0);
    try expectPlane(four, .init(0, 0, -1), 0);
    try expectPlane(four, Vec3.init(1, 1, 1).normalize(), 1.0 / @sqrt(3.0));
    // The slanted face is the largest, and so the first.
    try testing.expectApproxEqAbs(@as(f32, 1.0 / @sqrt(3.0)), four[0].offset, 1e-6);

    const octa = [_]Vec3{ .init(1, 0, 0), .init(-1, 0, 0), .init(0, 1, 0), .init(0, -1, 0), .init(0, 0, 1), .init(0, 0, -1) };
    const eight = try faces(gpa, &octa);
    defer gpa.free(eight);
    try testing.expectEqual(@as(usize, 8), eight.len);
    try expectHull(&octa, eight);

    // A drum: two sixteen-sided rims, the upper narrower. Eighteen faces.
    var drum: [32]Vec3 = undefined;
    for (0..16) |i| {
        const angle = @as(f32, @floatFromInt(i)) * std.math.tau / 16.0;
        drum[i] = .init(2 * @cos(angle), 0, 2 * @sin(angle));
        drum[16 + i] = .init(1.5 * @cos(angle), 0.5, 1.5 * @sin(angle));
    }
    const eighteen = try faces(gpa, &drum);
    defer gpa.free(eighteen);
    try testing.expectEqual(@as(usize, 18), eighteen.len);
    try expectPlane(eighteen, .init(0, 1, 0), 0.5);
    try expectPlane(eighteen, .init(0, -1, 0), 0);
    try expectHull(&drum, eighteen);
    const corners = try reduce(gpa, &drum);
    defer gpa.free(corners);
    try testing.expectEqualSlices(Vec3, &drum, corners);
}

test "hull: the same points in the same order give the same faces, wherever the hull stands" {
    const gpa = testing.allocator;
    var rng = core.rng.Pcg32.init(11, 38);
    for (0..1500) |round| {
        var points: [max_points]Vec3 = undefined;
        const n: usize = 4 + rng.below(if (round < 8) 253 else 40);
        // Rounds alternate between points in a ball, points on a sphere, and points on a
        // lattice, which is full of shared planes and lines. Some rounds shake every point by
        // about the tolerance, which is where a rule about "on the plane" is weakest.
        const far: f32 = if (round % 5 == 4) 900 else 0;
        const shake: f32 = switch (round % 7) {
            0 => 2e-5,
            1 => 2e-4,
            else => 0,
        };
        const rotation = core.math.Quat.fromAxisAngle(Vec3.init(rng.float01() - 0.5, rng.float01() + 0.1, rng.float01() - 0.5).normalize(), rng.float01() * 6);
        for (points[0..n]) |*p| {
            const raw: Vec3 = .init(rng.float01() * 2 - 1, rng.float01() * 2 - 1, rng.float01() * 2 - 1);
            const local = switch (round % 3) {
                0 => raw,
                1 => if (raw.length() > 0.01) raw.normalize() else Vec3.init(1, 0, 0),
                else => Vec3.init(@round(raw.x * 2), @round(raw.y * 2), @round(raw.z * 2)).scale(0.5),
            };
            const shaken = local.add(Vec3.init(rng.float01() - 0.5, rng.float01() - 0.5, rng.float01() - 0.5).scale(shake));
            p.* = rotation.rotate(shaken.mul(.init(1, 0.4, 2.5))).add(.init(far, -far, far * 0.5));
        }
        const planes = try faces(gpa, points[0..n]);
        defer gpa.free(planes);
        if (planes.len == 0) {
            // Only a lattice round can be flat, and then `reduce` says so.
            try testing.expectEqual(@as(usize, 2), round % 3);
            try testing.expectError(error.Flat, reduce(gpa, points[0..n]));
            continue;
        }
        try expectHull(points[0..n], planes);
        const again = try faces(gpa, points[0..n]);
        defer gpa.free(again);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(planes), std.mem.sliceAsBytes(again));

        // The corners alone are the same hull.
        const corners = try reduce(gpa, points[0..n]);
        defer gpa.free(corners);
        try testing.expect(corners.len >= 4 and corners.len <= n);
        const fewer = try faces(gpa, corners);
        defer gpa.free(fewer);
        try testing.expect(fewer.len >= 4);
        try expectHull(points[0..n], fewer);
        if (shake == 0 and far == 0) try testing.expectEqual(planes.len, fewer.len);
        // Reducing again takes nothing more, unless points sit at the tolerance, where a corner
        // of the first pass may be on an edge in the second.
        const once = try reduce(gpa, corners);
        defer gpa.free(once);
        if (shake == 0 and far == 0) {
            try testing.expectEqualSlices(Vec3, corners, once);
        } else {
            try testing.expect(once.len >= 4 and once.len <= corners.len);
        }
    }
}

test "hull: flat points have no faces, and too many corners are refused" {
    const gpa = testing.allocator;
    const flat = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 0, 1), .init(1, 0, 1), .init(0.5, 0, 0.5) };
    const line = [_]Vec3{ .init(0, 0, 0), .init(1, 1, 1), .init(2, 2, 2), .init(3, 3, 3) };
    const one = [_]Vec3{ .init(2, 2, 2), .init(2, 2, 2), .init(2, 2, 2), .init(2, 2, 2) };
    // Thinner than the tolerance of its own size.
    const sheet = [_]Vec3{ .init(0, 0, 0), .init(100, 0, 0), .init(0, 0, 100), .init(100, 1e-4, 100) };
    for ([_][]const Vec3{ &flat, &line, &one, &sheet, flat[0..3] }) |points| {
        const planes = try faces(gpa, points);
        try testing.expectEqual(@as(usize, 0), planes.len);
        try testing.expectError(error.Flat, reduce(gpa, points));
    }

    // 300 points on a sphere are all corners.
    var ball: [300]Vec3 = undefined;
    var rng = core.rng.Pcg32.init(2, 38);
    for (&ball) |*p| {
        var v: Vec3 = .init(rng.float01() - 0.5, rng.float01() - 0.5, rng.float01() - 0.5);
        while (v.length() < 0.05) v = .init(rng.float01() - 0.5, rng.float01() - 0.5, rng.float01() - 0.5);
        p.* = v.normalize();
    }
    try testing.expectError(error.TooManyPoints, reduce(gpa, &ball));
    const most = try reduce(gpa, ball[0..max_points]);
    defer gpa.free(most);
    try testing.expectEqual(max_points, most.len);
    const planes = try faces(gpa, ball[0..max_points]);
    defer gpa.free(planes);
    // A few neighbours among 256 random points share a plane within the tolerance.
    try testing.expect(planes.len <= max_faces and planes.len >= max_faces - 16);
    try expectHull(ball[0..max_points], planes);
}

test "hull: every allocation failure frees what was taken" {
    const Try = struct {
        fn both(gpa: Allocator, points: []const Vec3) !void {
            const planes = try faces(gpa, points);
            defer gpa.free(planes);
            const corners = try reduce(gpa, points);
            gpa.free(corners);
        }
    };
    var points: [24]Vec3 = undefined;
    var rng = core.rng.Pcg32.init(9, 38);
    for (&points) |*p| p.* = .init(rng.float01(), rng.float01(), rng.float01());
    try testing.checkAllAllocationFailures(testing.allocator, Try.both, .{@as([]const Vec3, &points)});
}
