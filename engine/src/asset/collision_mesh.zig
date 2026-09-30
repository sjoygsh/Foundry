//! Bounded `.fcol` v1 geometry, independent of render meshes and physics (ADR-0057).
//! `read` borrows the input; the registered loader copies into aligned, owned CPU arrays.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const registry = @import("registry.zig");
const schemas = @import("schemas.zig");
const Vec3 = core.math.Vec3;
const Allocator = std.mem.Allocator;

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError(".fcol views require a little-endian target");
    if (@sizeOf(Vec3) != 12) @compileError(".fcol position layout changed");
}

pub const magic = "FCOL";
pub const format_version: u32 = 1;
pub const header_size: usize = 40;
pub const Limits = struct {
    max_file_bytes: usize = 256 * 1024 * 1024,
    max_vertices: u32 = 3_145_728,
    max_triangles: u32 = 1_048_576,
    pub const default: Limits = .{};
};
// Same numerical envelope as physics3d, without a dependency upward or sideways.
pub const max_coordinate: f32 = 8192;
pub const min_triangle_area: f32 = 1e-12;
pub const ReadError = error{ NotACollisionMesh, UnsupportedVersion, Malformed, OverLimit };
pub const WriteError = error{ InvalidMesh, TooLarge, OutOfMemory };
pub const Bounds = struct { min: Vec3, max: Vec3 };

pub fn versionOf(bytes: []const u8) ?u32 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], magic)) return null;
    return std.mem.readInt(u32, bytes[4..8], .little);
}

pub const View = struct {
    /// Unaligned slices intentionally: a valid file need not start at an aligned address.
    positions: []align(1) const Vec3,
    indices: []align(1) const u32,
    bounds: Bounds,

    /// An aligned, owned copy for consumers such as physics3d.World.addMesh.
    pub fn copy(self: View, gpa: Allocator) Allocator.Error!CollisionMesh {
        const positions = try gpa.alloc(Vec3, self.positions.len);
        errdefer gpa.free(positions);
        const indices = try gpa.alloc(u32, self.indices.len);
        errdefer gpa.free(indices);
        for (positions, self.positions) |*to, from| to.* = from;
        for (indices, self.indices) |*to, from| to.* = from;
        return .{ .positions = positions, .indices = indices, .bounds = self.bounds };
    }
};

pub const CollisionMesh = struct {
    positions: []Vec3,
    indices: []u32,
    bounds: Bounds,

    pub fn deinit(self: *CollisionMesh, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.indices);
    }
};

pub fn read(bytes: []const u8, limits: Limits) ReadError!View {
    const version = versionOf(bytes) orelse return error.NotACollisionMesh;
    if (version != format_version) return error.UnsupportedVersion;
    if (bytes.len > @min(limits.max_file_bytes, Limits.default.max_file_bytes)) return error.OverLimit;
    if (bytes.len < header_size) return error.Malformed;
    const vertices = std.mem.readInt(u32, bytes[8..12], .little);
    const triangles = std.mem.readInt(u32, bytes[12..16], .little);
    if (vertices > limits.max_vertices or triangles > limits.max_triangles or
        vertices > Limits.default.max_vertices or triangles > Limits.default.max_triangles) return error.OverLimit;
    if (vertices == 0 or triangles == 0) return error.Malformed;
    const end_positions = header_size + @as(u64, vertices) * 12;
    const end = end_positions + @as(u64, triangles) * 12;
    if (end != bytes.len) return error.Malformed;
    const positions = std.mem.bytesAsSlice(Vec3, bytes[header_size..@intCast(end_positions)]);
    const indices = std.mem.bytesAsSlice(u32, bytes[@intCast(end_positions)..]);
    const bounds: Bounds = .{ .min = readVec(bytes, 16), .max = readVec(bytes, 28) };
    if (!bounds.min.isFinite() or !bounds.max.isFinite() or bounds.min.x > bounds.max.x or
        bounds.min.y > bounds.max.y or bounds.min.z > bounds.max.z) return error.Malformed;
    for (positions) |p| {
        if (!positionValid(p) or p.x < bounds.min.x or p.y < bounds.min.y or p.z < bounds.min.z or
            p.x > bounds.max.x or p.y > bounds.max.y or p.z > bounds.max.z) return error.Malformed;
    }
    for (indices) |index| if (index >= vertices) return error.Malformed;
    return .{ .positions = positions, .indices = indices, .bounds = bounds };
}

pub fn positionValid(p: Vec3) bool {
    return p.isFinite() and @abs(p.x) <= max_coordinate and @abs(p.y) <= max_coordinate and @abs(p.z) <= max_coordinate;
}

pub fn degenerate(a: Vec3, b: Vec3, c: Vec3) bool {
    return Vec3.cross(b.sub(a), c.sub(a)).lengthSquared() < 4 * min_triangle_area * min_triangle_area;
}

/// Canonical bounds and exact f32 positions in input order; no tree or structural padding.
pub fn write(gpa: Allocator, positions: []const Vec3, indices: []const u32) WriteError![]u8 {
    if (positions.len > Limits.default.max_vertices or indices.len / 3 > Limits.default.max_triangles) return error.TooLarge;
    if (positions.len == 0 or indices.len == 0 or indices.len % 3 != 0) return error.InvalidMesh;
    var bounds: Bounds = .{ .min = positions[0], .max = positions[0] };
    for (positions) |p| {
        if (!positionValid(p)) return error.InvalidMesh;
        bounds.min = .init(@min(bounds.min.x, p.x), @min(bounds.min.y, p.y), @min(bounds.min.z, p.z));
        bounds.max = .init(@max(bounds.max.x, p.x), @max(bounds.max.y, p.y), @max(bounds.max.z, p.z));
    }
    for (indices) |index| if (index >= positions.len) return error.InvalidMesh;
    const bytes = try gpa.alloc(u8, header_size + positions.len * 12 + indices.len * 4);
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], format_version, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(positions.len), .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(indices.len / 3), .little);
    writeVec(bytes, 16, bounds.min);
    writeVec(bytes, 28, bounds.max);
    for (positions, 0..) |p, i| writeVec(bytes, header_size + i * 12, p);
    const offset = header_size + positions.len * 12;
    for (indices, 0..) |index, i| std.mem.writeInt(u32, bytes[offset + i * 4 ..][0..4], index, .little);
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

pub fn collisionMeshLoader() registry.Loader {
    return .{ .schema = schemas.collision_mesh.id, .max_source_bytes = Limits.default.max_file_bytes, .load = load, .unload = unload };
}
fn load(_: ?*anyopaque, gpa: Allocator, _: @import("data").store.Record, bytes: []const u8) registry.LoadError!registry.Payload {
    const view = read(bytes, .default) catch |err| return switch (err) {
        error.UnsupportedVersion => error.UnsupportedVersion,
        else => error.InvalidAsset,
    };
    const owned = try gpa.create(CollisionMesh);
    errdefer gpa.destroy(owned);
    owned.* = try view.copy(gpa);
    return .fromPointer(owned);
}
fn unload(_: ?*anyopaque, gpa: Allocator, payload: registry.Payload) void {
    const owned: *CollisionMesh = @ptrCast(@alignCast(payload.pointer().?));
    owned.deinit(gpa);
    gpa.destroy(owned);
}
pub fn fromPayload(payload: registry.Payload) *const CollisionMesh {
    return @ptrCast(@alignCast(payload.pointer().?));
}

const testing = std.testing;
const fixture_positions = [_]Vec3{ .zero, .init(1, 0, 0), .init(0, 1, 0) };
const fixture_indices = [_]u32{ 0, 1, 2 };

test "fcol: canonical round trip and hash, including an unaligned borrowed view" {
    const bytes = try write(testing.allocator, &fixture_positions, &fixture_indices);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u64, 0xc854ac2cc345318d), core.id.fnv1a64(bytes));
    const offset = try testing.allocator.alloc(u8, bytes.len + 1);
    defer testing.allocator.free(offset);
    @memcpy(offset[1..], bytes);
    const view = try read(offset[1..], .default);
    try testing.expectEqual(@intFromPtr(offset.ptr) + 1 + header_size, @intFromPtr(view.positions.ptr));
    for (view.positions, fixture_positions) |actual, expected| try testing.expectEqualDeep(expected, actual);
    for (view.indices, fixture_indices) |actual, expected| try testing.expectEqual(expected, actual);
    var copy = try view.copy(testing.allocator);
    defer copy.deinit(testing.allocator);
    @memset(offset, 0);
    try testing.expectEqualDeep(fixture_positions[1], copy.positions[1]);
    try testing.expectEqualSlices(u32, &fixture_indices, copy.indices);
}

test "fcol: every read refusal, bounded counts, finite positions, bounds and exact length" {
    const bytes = try write(testing.allocator, &fixture_positions, &fixture_indices);
    defer testing.allocator.free(bytes);
    try testing.expectError(error.NotACollisionMesh, read("nope", .default));
    for (8..bytes.len) |length| try testing.expectError(error.Malformed, read(bytes[0..length], .default));
    try testing.expectError(error.OverLimit, read(bytes, .{ .max_file_bytes = bytes.len - 1 }));
    const cases = [_]struct { offset: usize, value: u32, err: ReadError }{
        .{ .offset = 4, .value = 2, .err = error.UnsupportedVersion },
        .{ .offset = 8, .value = 0, .err = error.Malformed },
        .{ .offset = 12, .value = 0, .err = error.Malformed },
        .{ .offset = 8, .value = Limits.default.max_vertices + 1, .err = error.OverLimit },
        .{ .offset = 12, .value = Limits.default.max_triangles + 1, .err = error.OverLimit },
        .{ .offset = 40, .value = @bitCast(std.math.nan(f32)), .err = error.Malformed },
        .{ .offset = 40, .value = @bitCast(@as(f32, 8193)), .err = error.Malformed },
        .{ .offset = 28, .value = @bitCast(@as(f32, -1)), .err = error.Malformed },
        .{ .offset = 28, .value = @bitCast(@as(f32, 0)), .err = error.Malformed },
        .{ .offset = 16, .value = @bitCast(std.math.inf(f32)), .err = error.Malformed },
        .{ .offset = 16, .value = @bitCast(std.math.nan(f32)), .err = error.Malformed },
        .{ .offset = 76, .value = 3, .err = error.Malformed },
    };
    for (cases) |case| {
        const bad = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(bad);
        std.mem.writeInt(u32, bad[case.offset..][0..4], case.value, .little);
        try testing.expectError(case.err, read(bad, .default));
    }
    var trailing: [89]u8 = undefined;
    @memcpy(trailing[0..88], bytes);
    trailing[88] = 0;
    try testing.expectError(error.Malformed, read(&trailing, .default));
    // Newer files remain recognisable even when their body is not v1's layout.
    std.mem.writeInt(u32, bytes[4..8], 9, .little);
    try testing.expectError(error.UnsupportedVersion, read(bytes[0..8], .default));
}

test "fcol: writer refuses bad geometry and retains runtime-degenerate triangles" {
    try testing.expectError(error.InvalidMesh, write(testing.allocator, &.{}, &fixture_indices));
    try testing.expectError(error.InvalidMesh, write(testing.allocator, &fixture_positions, &.{}));
    try testing.expectError(error.InvalidMesh, write(testing.allocator, &fixture_positions, &.{ 0, 1 }));
    try testing.expectError(error.InvalidMesh, write(testing.allocator, &fixture_positions, &.{ 0, 1, 3 }));
    try testing.expectError(error.InvalidMesh, write(testing.allocator, &.{.init(std.math.nan(f32), 0, 0)}, &.{ 0, 0, 0 }));
    const bytes = try write(testing.allocator, &fixture_positions, &.{ 0, 0, 0 });
    defer testing.allocator.free(bytes);
    const view = try read(bytes, .default);
    try testing.expect(degenerate(view.positions[0], view.positions[0], view.positions[0]));
    try testing.expect(!degenerate(fixture_positions[0], fixture_positions[1], fixture_positions[2]));
    try testing.expect(degenerate(.zero, .init(1e-6, 0, 0), .init(0, 1e-6, 0)));
    try testing.expect(!degenerate(.zero, .init(2e-6, 0, 0), .init(0, 2e-6, 0)));
}

fn allocationProof(gpa: Allocator) !void {
    const bytes = try write(gpa, &fixture_positions, &fixture_indices);
    defer gpa.free(bytes);
    const view = try read(bytes, .default);
    var copied = try view.copy(gpa);
    defer copied.deinit(gpa);
    const loader = collisionMeshLoader();
    const payload = try loader.load(null, gpa, std.mem.zeroes(@import("data").store.Record), bytes);
    defer loader.unload(null, gpa, payload);
    try testing.expectEqualDeep(fixture_positions[2], fromPayload(payload).positions[2]);
}

test "fcol: loader owns its decoded product, preserves version refusals and unwinds allocations" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationProof, .{});
    const bytes = try write(testing.allocator, &fixture_positions, &fixture_indices);
    defer testing.allocator.free(bytes);
    const loader = collisionMeshLoader();
    const record = std.mem.zeroes(@import("data").store.Record);
    const payload = try loader.load(null, testing.allocator, record, bytes);
    defer loader.unload(null, testing.allocator, payload);
    @memset(bytes, 0);
    try testing.expectEqualDeep(fixture_positions[1], fromPayload(payload).positions[1]);
    try testing.expectError(error.InvalidAsset, loader.load(null, testing.allocator, record, bytes));
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], 2, .little);
    try testing.expectError(error.UnsupportedVersion, loader.load(null, testing.allocator, record, bytes));
}
