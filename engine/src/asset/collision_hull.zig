//! Bounded `.fhul` points, a convex hull's compiled form (ADR-0078, `collision-scale.md` §7).
//! `read` borrows the input; the registered loader copies into aligned, owned CPU arrays.
//!
//! **Version 1:** the magic `FHUL`, the version, a u32 count of `min_points` to `max_points`,
//! the bounds as two `Vec3`s, then the points. No faces: `physics3d` finds them from the points
//! (`hull.faces`), and a file that holds none cannot disagree with its points.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const registry = @import("registry.zig");
const schemas = @import("schemas.zig");
const collision_mesh = @import("collision_mesh.zig");
const Vec3 = core.math.Vec3;
const Allocator = std.mem.Allocator;

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError(".fhul views require a little-endian target");
    if (@sizeOf(Vec3) != 12) @compileError(".fhul point layout changed");
}

pub const magic = "FHUL";
pub const format_version: u32 = 1;
pub const header_size: usize = 36;
/// The fewest points that can span a volume.
pub const min_points: u32 = 4;
/// `physics3d.hull.max_points`, without a dependency sideways.
pub const max_points: u32 = 256;
pub const max_file_bytes: usize = header_size + max_points * 12;
pub const ReadError = error{ NotACollisionHull, UnsupportedVersion, Malformed, OverLimit };
pub const WriteError = error{ InvalidHull, OutOfMemory };
pub const Bounds = collision_mesh.Bounds;

pub fn versionOf(bytes: []const u8) ?u32 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], magic)) return null;
    return std.mem.readInt(u32, bytes[4..8], .little);
}

pub const View = struct {
    /// Unaligned intentionally, as `.fcol`'s view is.
    points: []align(1) const Vec3,
    bounds: Bounds,

    pub fn copy(self: View, gpa: Allocator) Allocator.Error!CollisionHull {
        const points = try gpa.alloc(Vec3, self.points.len);
        for (points, self.points) |*to, from| to.* = from;
        return .{ .points = points, .bounds = self.bounds };
    }
};

/// What a game hands `physics3d.World.addHull`, by the hull's content ID.
pub const CollisionHull = struct {
    points: []Vec3,
    bounds: Bounds,

    pub fn deinit(self: *CollisionHull, gpa: Allocator) void {
        gpa.free(self.points);
    }
};

/// Refused: a wrong magic, a version other than 1, a count under `min_points` (`Malformed`) or
/// over `max_points` (`OverLimit`), bounds not finite or not ordered, a point not finite, past
/// `collision_mesh.max_coordinate` or outside the bounds, and a length that is not the count's.
pub fn read(bytes: []const u8) ReadError!View {
    const version = versionOf(bytes) orelse return error.NotACollisionHull;
    if (version != format_version) return error.UnsupportedVersion;
    if (bytes.len > max_file_bytes) return error.OverLimit;
    if (bytes.len < header_size) return error.Malformed;
    const count = std.mem.readInt(u32, bytes[8..12], .little);
    if (count > max_points) return error.OverLimit;
    if (count < min_points) return error.Malformed;
    if (header_size + @as(usize, count) * 12 != bytes.len) return error.Malformed;
    const bounds: Bounds = .{ .min = readVec(bytes, 12), .max = readVec(bytes, 24) };
    if (!bounds.min.isFinite() or !bounds.max.isFinite() or bounds.min.x > bounds.max.x or
        bounds.min.y > bounds.max.y or bounds.min.z > bounds.max.z) return error.Malformed;
    const points = std.mem.bytesAsSlice(Vec3, bytes[header_size..]);
    for (points) |p| {
        if (!collision_mesh.positionValid(p) or p.x < bounds.min.x or p.y < bounds.min.y or p.z < bounds.min.z or
            p.x > bounds.max.x or p.y > bounds.max.y or p.z > bounds.max.z) return error.Malformed;
    }
    return .{ .points = points, .bounds = bounds };
}

/// Canonical bounds and exact f32 points in input order. `InvalidHull` for a count out of range
/// or a point the reader would refuse. Whether the points span a volume is `physics3d`'s to say,
/// and `author`'s to check before writing (§9).
pub fn write(gpa: Allocator, points: []const Vec3) WriteError![]u8 {
    if (points.len < min_points or points.len > max_points) return error.InvalidHull;
    var bounds: Bounds = .{ .min = points[0], .max = points[0] };
    for (points) |p| {
        if (!collision_mesh.positionValid(p)) return error.InvalidHull;
        bounds.min = .init(@min(bounds.min.x, p.x), @min(bounds.min.y, p.y), @min(bounds.min.z, p.z));
        bounds.max = .init(@max(bounds.max.x, p.x), @max(bounds.max.y, p.y), @max(bounds.max.z, p.z));
    }
    const bytes = try gpa.alloc(u8, header_size + points.len * 12);
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], format_version, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(points.len), .little);
    writeVec(bytes, 12, bounds.min);
    writeVec(bytes, 24, bounds.max);
    for (points, 0..) |p, i| writeVec(bytes, header_size + i * 12, p);
    return bytes;
}

fn readVec(bytes: []const u8, at: usize) Vec3 {
    return .init(@bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little)), @bitCast(std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little)), @bitCast(std.mem.readInt(u32, bytes[at + 8 ..][0..4], .little)));
}
fn writeVec(bytes: []u8, at: usize, p: Vec3) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(p.x), .little);
    std.mem.writeInt(u32, bytes[at + 4 ..][0..4], @bitCast(p.y), .little);
    std.mem.writeInt(u32, bytes[at + 8 ..][0..4], @bitCast(p.z), .little);
}

pub fn collisionHullLoader() registry.Loader {
    return .{ .schema = schemas.collision_hull.id, .max_source_bytes = max_file_bytes, .load = load, .unload = unload, .split = .{ .decode = decode, .finish = registry.adoptDecoded, .discard = discard, .after_finish = .adopt } };
}
fn load(_: ?*anyopaque, gpa: Allocator, record: @import("data").store.Record, bytes: []const u8) registry.LoadError!registry.Payload {
    return collisionHullLoader().loadWhole(gpa, record, bytes);
}
/// The whole parse and validation, on any thread; the finish adopts the result (M27).
fn decode(_: ?*const anyopaque, gpa: Allocator, _: @import("data").store.Record, bytes: []const u8) registry.LoadError!registry.Decoded {
    const view = read(bytes) catch |err| return switch (err) {
        error.UnsupportedVersion => error.UnsupportedVersion,
        else => error.InvalidAsset,
    };
    const owned = try gpa.create(CollisionHull);
    errdefer gpa.destroy(owned);
    owned.* = try view.copy(gpa);
    return registry.Decoded.fromPointer(owned);
}
fn discard(gpa: Allocator, decoded: registry.Decoded) void {
    unload(null, gpa, .{ .bits = decoded.bits });
}
fn unload(_: ?*anyopaque, gpa: Allocator, payload: registry.Payload) void {
    const owned: *CollisionHull = @ptrCast(@alignCast(payload.pointer().?));
    owned.deinit(gpa);
    gpa.destroy(owned);
}
pub fn fromPayload(payload: registry.Payload) *const CollisionHull {
    return @ptrCast(@alignCast(payload.pointer().?));
}

const testing = std.testing;
const box = [_]Vec3{
    .init(-1, 0, -1), .init(1, 0, -1), .init(1, 0, 1), .init(-1, 0, 1),
    .init(-1, 2, -1), .init(1, 2, -1), .init(1, 2, 1), .init(-1, 2, 1),
};

test "fhul: canonical round trip, an unaligned borrowed view, and the same bytes again" {
    const gpa = testing.allocator;
    const bytes = try write(gpa, &box);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(?u32, 1), versionOf(bytes));
    try testing.expectEqual(header_size + 8 * 12, bytes.len);
    const offset = try gpa.alloc(u8, bytes.len + 1);
    defer gpa.free(offset);
    @memcpy(offset[1..], bytes);
    const view = try read(offset[1..]);
    try testing.expectEqual(@intFromPtr(offset.ptr) + 1 + header_size, @intFromPtr(view.points.ptr));
    try testing.expectEqualDeep(Vec3.init(-1, 0, -1), view.bounds.min);
    try testing.expectEqualDeep(Vec3.init(1, 2, 1), view.bounds.max);
    var owned = try view.copy(gpa);
    defer owned.deinit(gpa);
    @memset(offset, 0);
    for (owned.points, box) |actual, expected| try testing.expectEqualDeep(expected, actual);
    const again = try write(gpa, owned.points);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
    // Four points and 256 are both in range.
    const four = try write(gpa, &(box[0..3].* ++ box[4..5].*));
    defer gpa.free(four);
    _ = try read(four);
    var many: [max_points]Vec3 = undefined;
    for (&many, 0..) |*p, i| p.* = .init(@floatFromInt(i % 7), @floatFromInt(i % 5), @floatFromInt(i % 3));
    const full = try write(gpa, &many);
    defer gpa.free(full);
    try testing.expectEqual(@as(usize, max_points), (try read(full)).points.len);
}

test "fhul: every read refusal is named" {
    const gpa = testing.allocator;
    const bytes = try write(gpa, &box);
    defer gpa.free(bytes);
    try testing.expectError(error.NotACollisionHull, read("nope"));
    try testing.expectError(error.NotACollisionHull, read("FCOL\x01\x00\x00\x00"));
    for (8..bytes.len) |length| try testing.expectError(error.Malformed, read(bytes[0..length]));
    const long = try gpa.alloc(u8, bytes.len + 1);
    defer gpa.free(long);
    @memcpy(long[0..bytes.len], bytes);
    long[bytes.len] = 0;
    try testing.expectError(error.Malformed, read(long));
    const Case = struct { offset: usize, value: u32, err: ReadError };
    const cases = [_]Case{
        .{ .offset = 4, .value = 0, .err = error.UnsupportedVersion },
        .{ .offset = 4, .value = 2, .err = error.UnsupportedVersion },
        .{ .offset = 8, .value = 3, .err = error.Malformed },
        .{ .offset = 8, .value = 0, .err = error.Malformed },
        .{ .offset = 8, .value = max_points + 1, .err = error.OverLimit },
        // A count the file does not hold.
        .{ .offset = 8, .value = 9, .err = error.Malformed },
        // Bounds not finite, or not ordered.
        .{ .offset = 12, .value = @bitCast(std.math.nan(f32)), .err = error.Malformed },
        .{ .offset = 24, .value = @bitCast(std.math.inf(f32)), .err = error.Malformed },
        .{ .offset = 28, .value = @bitCast(@as(f32, -1)), .err = error.Malformed },
        // A point not finite, past the coordinate limit, or outside the bounds.
        .{ .offset = header_size, .value = @bitCast(std.math.nan(f32)), .err = error.Malformed },
        .{ .offset = header_size + 4, .value = @bitCast(std.math.inf(f32)), .err = error.Malformed },
        .{ .offset = header_size, .value = @bitCast(@as(f32, -8193)), .err = error.Malformed },
        .{ .offset = header_size + 12, .value = @bitCast(@as(f32, 1.5)), .err = error.Malformed },
    };
    for (cases) |case| {
        const bad = try gpa.dupe(u8, bytes);
        defer gpa.free(bad);
        std.mem.writeInt(u32, bad[case.offset..][0..4], case.value, .little);
        try testing.expectError(case.err, read(bad));
    }
    // Three points, and the length three points make.
    const three = try gpa.dupe(u8, bytes[0 .. header_size + 3 * 12]);
    defer gpa.free(three);
    std.mem.writeInt(u32, three[8..12], 3, .little);
    try testing.expectError(error.Malformed, read(three));
    std.mem.writeInt(u32, three[8..12], 0, .little);
    try testing.expectError(error.Malformed, read(three[0..header_size]));
    // A file longer than 256 points could be is over the limit before its count is read.
    const huge = try gpa.alloc(u8, max_file_bytes + 12);
    defer gpa.free(huge);
    @memset(huge, 0);
    @memcpy(huge[0..8], bytes[0..8]);
    try testing.expectError(error.OverLimit, read(huge));
}

test "fhul: the writer refuses what the reader would" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidHull, write(gpa, box[0..3]));
    var many: [max_points + 1]Vec3 = undefined;
    for (&many, 0..) |*p, i| p.* = .init(@floatFromInt(i), 0, 0);
    try testing.expectError(error.InvalidHull, write(gpa, &many));
    var bad = box;
    bad[5] = .init(std.math.nan(f32), 0, 0);
    try testing.expectError(error.InvalidHull, write(gpa, &bad));
    bad[5] = .init(0, 8193, 0);
    try testing.expectError(error.InvalidHull, write(gpa, &bad));
}

fn allocationProof(gpa: Allocator) !void {
    const bytes = try write(gpa, &box);
    defer gpa.free(bytes);
    var copied = try (try read(bytes)).copy(gpa);
    defer copied.deinit(gpa);
    const loader = collisionHullLoader();
    const payload = try loader.load(null, gpa, std.mem.zeroes(@import("data").store.Record), bytes);
    defer loader.unload(null, gpa, payload);
    try testing.expectEqualDeep(box[6], fromPayload(payload).points[6]);
}

test "fhul: the loader owns its product, keeps version refusals and unwinds allocations" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationProof, .{});
    const gpa = testing.allocator;
    const bytes = try write(gpa, &box);
    defer gpa.free(bytes);
    const loader = collisionHullLoader();
    const record = std.mem.zeroes(@import("data").store.Record);
    const payload = try loader.load(null, gpa, record, bytes);
    defer loader.unload(null, gpa, payload);
    @memset(bytes, 0);
    try testing.expectEqualDeep(box[1], fromPayload(payload).points[1]);
    try testing.expectError(error.InvalidAsset, loader.load(null, gpa, record, bytes));
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], 2, .little);
    try testing.expectError(error.UnsupportedVersion, loader.load(null, gpa, record, bytes));
}
