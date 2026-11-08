//! Bounded `.fcol` geometry, independent of render meshes and physics (ADR-0057).
//! `read` borrows the input; the registered loader copies into aligned, owned CPU arrays.
//!
//! **Version 2 appends what a triangle is made of and which way it faces** (ADR-0076,
//! `collision-extras.md` §9): after version 1's header and arrays, a u32 count of at most
//! `max_surfaces`, that many content-ID hashes (u64), then a u32 per triangle with a surface index
//! in its low 16 bits (`no_surface` for none) and the one-sided flag in bit 16. The other bits are
//! zero. A mesh with no surface and no one-sided face is written as version 1, so it keeps its
//! bytes.
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
/// The newest version read and written. Version 1 is still read, and still written for a mesh
/// version 2 would add nothing to.
pub const format_version: u32 = 2;
pub const header_size: usize = 40;
pub const max_surfaces: u32 = 65_535;
pub const no_surface: u16 = 0xFFFF;
pub const one_sided_bit: u32 = 1 << 16;
/// A triangle with no surface, two-sided: what every version 1 triangle is.
pub const plain_attribute: u32 = no_surface;
const reserved_bits: u32 = ~(one_sided_bit | 0xFFFF);
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

/// What version 2 adds, as `write` takes it. Empty `triangle_attributes` means every triangle is
/// `plain_attribute`; otherwise there is one a triangle.
pub const Attributes = struct {
    surfaces: []const core.ContentId = &.{},
    triangle_attributes: []const u32 = &.{},
};

/// A triangle attribute's surface index, or null for none.
pub fn surfaceIndex(attribute: u32) ?u16 {
    const index: u16 = @truncate(attribute);
    return if (index == no_surface) null else index;
}

pub fn oneSided(attribute: u32) bool {
    return attribute & one_sided_bit != 0;
}

pub const View = struct {
    /// Unaligned slices intentionally: a valid file need not start at an aligned address.
    positions: []align(1) const Vec3,
    indices: []align(1) const u32,
    bounds: Bounds,
    /// Version 2's, and empty for version 1: no surfaces, and every triangle plain.
    surfaces: []align(1) const core.ContentId = &.{},
    triangle_attributes: []align(1) const u32 = &.{},

    /// An aligned, owned copy for consumers such as physics3d.World.addMesh.
    pub fn copy(self: View, gpa: Allocator) Allocator.Error!CollisionMesh {
        const positions = try gpa.alloc(Vec3, self.positions.len);
        errdefer gpa.free(positions);
        const indices = try gpa.alloc(u32, self.indices.len);
        errdefer gpa.free(indices);
        const surfaces = try gpa.alloc(core.ContentId, self.surfaces.len);
        errdefer gpa.free(surfaces);
        const attributes = try gpa.alloc(u32, self.triangle_attributes.len);
        errdefer gpa.free(attributes);
        for (positions, self.positions) |*to, from| to.* = from;
        for (indices, self.indices) |*to, from| to.* = from;
        for (surfaces, self.surfaces) |*to, from| to.* = from;
        for (attributes, self.triangle_attributes) |*to, from| to.* = from;
        return .{ .positions = positions, .indices = indices, .bounds = self.bounds, .surfaces = surfaces, .triangle_attributes = attributes };
    }
};

pub const CollisionMesh = struct {
    positions: []Vec3,
    indices: []u32,
    bounds: Bounds,
    /// Version 2's, and empty for version 1 (`View`).
    surfaces: []core.ContentId = &.{},
    triangle_attributes: []u32 = &.{},

    pub fn deinit(self: *CollisionMesh, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.indices);
        gpa.free(self.surfaces);
        gpa.free(self.triangle_attributes);
    }

    /// Triangle `index`'s surface, or `.none`.
    pub fn surfaceOf(self: *const CollisionMesh, index: usize) core.ContentId {
        if (self.triangle_attributes.len == 0) return .none;
        const at = surfaceIndex(self.triangle_attributes[index]) orelse return .none;
        return self.surfaces[at];
    }

    pub fn oneSidedAt(self: *const CollisionMesh, index: usize) bool {
        return self.triangle_attributes.len != 0 and oneSided(self.triangle_attributes[index]);
    }
};

pub fn read(bytes: []const u8, limits: Limits) ReadError!View {
    const version = versionOf(bytes) orelse return error.NotACollisionMesh;
    if (version != 1 and version != 2) return error.UnsupportedVersion;
    if (bytes.len > @min(limits.max_file_bytes, Limits.default.max_file_bytes)) return error.OverLimit;
    if (bytes.len < header_size) return error.Malformed;
    const vertices = std.mem.readInt(u32, bytes[8..12], .little);
    const triangles = std.mem.readInt(u32, bytes[12..16], .little);
    if (vertices > limits.max_vertices or triangles > limits.max_triangles or
        vertices > Limits.default.max_vertices or triangles > Limits.default.max_triangles) return error.OverLimit;
    if (vertices == 0 or triangles == 0) return error.Malformed;
    const end_positions = header_size + @as(u64, vertices) * 12;
    const end = end_positions + @as(u64, triangles) * 12;
    if (version == 1 and end != bytes.len) return error.Malformed;
    if (version == 2 and end + 4 > bytes.len) return error.Malformed;
    const positions = std.mem.bytesAsSlice(Vec3, bytes[header_size..@intCast(end_positions)]);
    const indices = std.mem.bytesAsSlice(u32, bytes[@intCast(end_positions)..@intCast(end)]);
    var surfaces: []align(1) const core.ContentId = &.{};
    var attributes: []align(1) const u32 = &.{};
    if (version == 2) {
        const at: usize = @intCast(end);
        const count = std.mem.readInt(u32, bytes[at..][0..4], .little);
        if (count > max_surfaces) return error.Malformed;
        const end_surfaces = at + 4 + @as(u64, count) * 8;
        if (end_surfaces + @as(u64, triangles) * 4 != bytes.len) return error.Malformed;
        surfaces = std.mem.bytesAsSlice(core.ContentId, bytes[at + 4 .. @intCast(end_surfaces)]);
        attributes = std.mem.bytesAsSlice(u32, bytes[@intCast(end_surfaces)..]);
        // No table entry is the absent ID, which no content compiler emits.
        for (surfaces) |id| if (id.isNone()) return error.Malformed;
        for (attributes) |a| {
            if (a & reserved_bits != 0) return error.Malformed;
            if (surfaceIndex(a)) |index| if (index >= count) return error.Malformed;
        }
    }
    const bounds: Bounds = .{ .min = readVec(bytes, 16), .max = readVec(bytes, 28) };
    if (!bounds.min.isFinite() or !bounds.max.isFinite() or bounds.min.x > bounds.max.x or
        bounds.min.y > bounds.max.y or bounds.min.z > bounds.max.z) return error.Malformed;
    for (positions) |p| {
        if (!positionValid(p) or p.x < bounds.min.x or p.y < bounds.min.y or p.z < bounds.min.z or
            p.x > bounds.max.x or p.y > bounds.max.y or p.z > bounds.max.z) return error.Malformed;
    }
    for (indices) |index| if (index >= vertices) return error.Malformed;
    return .{ .positions = positions, .indices = indices, .bounds = bounds, .surfaces = surfaces, .triangle_attributes = attributes };
}

pub fn positionValid(p: Vec3) bool {
    return p.isFinite() and @abs(p.x) <= max_coordinate and @abs(p.y) <= max_coordinate and @abs(p.z) <= max_coordinate;
}

pub fn degenerate(a: Vec3, b: Vec3, c: Vec3) bool {
    return Vec3.cross(b.sub(a), c.sub(a)).lengthSquared() < 4 * min_triangle_area * min_triangle_area;
}

/// Canonical bounds and exact f32 positions in input order; no tree or structural padding.
/// Version 1: no surfaces, and every triangle two-sided.
pub fn write(gpa: Allocator, positions: []const Vec3, indices: []const u32) WriteError![]u8 {
    return writeWith(gpa, positions, indices, .{});
}

/// `write`, with surfaces and one-sided faces. Version 2 only when `attributes` has a surface
/// or a triangle that is not `plain_attribute`; otherwise version 1, byte for byte `write`'s.
/// Refused as `InvalidMesh`: a table past `max_surfaces` or holding `.none`, attributes that are
/// not one a triangle, reserved bits, or an index past the table.
pub fn writeWith(gpa: Allocator, positions: []const Vec3, indices: []const u32, attributes: Attributes) WriteError![]u8 {
    if (positions.len > Limits.default.max_vertices or indices.len / 3 > Limits.default.max_triangles) return error.TooLarge;
    if (positions.len == 0 or indices.len == 0 or indices.len % 3 != 0) return error.InvalidMesh;
    var bounds: Bounds = .{ .min = positions[0], .max = positions[0] };
    for (positions) |p| {
        if (!positionValid(p)) return error.InvalidMesh;
        bounds.min = .init(@min(bounds.min.x, p.x), @min(bounds.min.y, p.y), @min(bounds.min.z, p.z));
        bounds.max = .init(@max(bounds.max.x, p.x), @max(bounds.max.y, p.y), @max(bounds.max.z, p.z));
    }
    for (indices) |index| if (index >= positions.len) return error.InvalidMesh;
    const triangles = indices.len / 3;
    if (attributes.surfaces.len > max_surfaces) return error.InvalidMesh;
    if (attributes.triangle_attributes.len != 0 and attributes.triangle_attributes.len != triangles) return error.InvalidMesh;
    for (attributes.surfaces) |id| if (id.isNone()) return error.InvalidMesh;
    var plain = attributes.surfaces.len == 0;
    for (attributes.triangle_attributes) |a| {
        if (a & reserved_bits != 0) return error.InvalidMesh;
        if (surfaceIndex(a)) |index| if (index >= attributes.surfaces.len) return error.InvalidMesh;
        if (a != plain_attribute) plain = false;
    }
    const v1_size = header_size + positions.len * 12 + indices.len * 4;
    const size = if (plain) v1_size else v1_size + 4 + attributes.surfaces.len * 8 + triangles * 4;
    const bytes = try gpa.alloc(u8, size);
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], if (plain) 1 else 2, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(positions.len), .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(indices.len / 3), .little);
    writeVec(bytes, 16, bounds.min);
    writeVec(bytes, 28, bounds.max);
    for (positions, 0..) |p, i| writeVec(bytes, header_size + i * 12, p);
    const offset = header_size + positions.len * 12;
    for (indices, 0..) |index, i| std.mem.writeInt(u32, bytes[offset + i * 4 ..][0..4], index, .little);
    if (plain) return bytes;
    std.mem.writeInt(u32, bytes[v1_size..][0..4], @intCast(attributes.surfaces.len), .little);
    for (attributes.surfaces, 0..) |id, i| std.mem.writeInt(u64, bytes[v1_size + 4 + i * 8 ..][0..8], id.hash, .little);
    const at = v1_size + 4 + attributes.surfaces.len * 8;
    for (0..triangles) |i| {
        const a = if (attributes.triangle_attributes.len == 0) plain_attribute else attributes.triangle_attributes[i];
        std.mem.writeInt(u32, bytes[at + i * 4 ..][0..4], a, .little);
    }
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
    return .{ .schema = schemas.collision_mesh.id, .max_source_bytes = Limits.default.max_file_bytes, .load = load, .unload = unload, .split = .{ .decode = decode, .finish = registry.adoptDecoded, .discard = discard, .after_finish = .adopt } };
}
fn load(_: ?*anyopaque, gpa: Allocator, record: @import("data").store.Record, bytes: []const u8) registry.LoadError!registry.Payload {
    return collisionMeshLoader().loadWhole(gpa, record, bytes);
}
/// The whole parse and validation, on any thread; the finish adopts the result (M27).
fn decode(_: ?*const anyopaque, gpa: Allocator, _: @import("data").store.Record, bytes: []const u8) registry.LoadError!registry.Decoded {
    const view = read(bytes, .default) catch |err| return switch (err) {
        error.UnsupportedVersion => error.UnsupportedVersion,
        else => error.InvalidAsset,
    };
    const owned = try gpa.create(CollisionMesh);
    errdefer gpa.destroy(owned);
    owned.* = try view.copy(gpa);
    return registry.Decoded.fromPointer(owned);
}
fn discard(gpa: Allocator, decoded: registry.Decoded) void {
    unload(null, gpa, .{ .bits = decoded.bits });
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
        .{ .offset = 4, .value = 3, .err = error.UnsupportedVersion },
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
    std.mem.writeInt(u32, bytes[4..8], 3, .little);
    try testing.expectError(error.UnsupportedVersion, loader.load(null, testing.allocator, record, bytes));
}

const square_positions = [_]Vec3{ .zero, .init(1, 0, 0), .init(1, 0, 1), .init(0, 0, 1) };
const square_indices = [_]u32{ 0, 2, 1, 0, 3, 2 };
const grass = core.ContentId.fromString("test:surface.grass");
const stone = core.ContentId.fromString("test:surface.stone");

test "fcol v2: surfaces and one-sided faces round trip, and a plain mesh is still version 1" {
    const gpa = testing.allocator;
    const attributes: Attributes = .{ .surfaces = &.{ grass, stone }, .triangle_attributes = &.{ 1 | one_sided_bit, plain_attribute } };
    const bytes = try writeWith(gpa, &square_positions, &square_indices, attributes);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(?u32, 2), versionOf(bytes));
    try testing.expectEqual(header_size + 4 * 12 + 6 * 4 + 4 + 2 * 8 + 2 * 4, bytes.len);
    // Borrowed from an unaligned start, as version 1's view is.
    const offset = try gpa.alloc(u8, bytes.len + 1);
    defer gpa.free(offset);
    @memcpy(offset[1..], bytes);
    const view = try read(offset[1..], .default);
    try testing.expectEqual(@as(usize, 2), view.surfaces.len);
    try testing.expect(view.surfaces[1].eql(stone));
    try testing.expectEqual(@as(?u16, 1), surfaceIndex(view.triangle_attributes[0]));
    try testing.expect(oneSided(view.triangle_attributes[0]));
    try testing.expectEqual(@as(?u16, null), surfaceIndex(view.triangle_attributes[1]));
    try testing.expect(!oneSided(view.triangle_attributes[1]));
    var owned = try view.copy(gpa);
    defer owned.deinit(gpa);
    @memset(offset, 0);
    try testing.expect(owned.surfaceOf(0).eql(stone) and owned.oneSidedAt(0));
    try testing.expect(owned.surfaceOf(1).isNone() and !owned.oneSidedAt(1));
    // And written again, the same bytes.
    const again = try writeWith(gpa, owned.positions, owned.indices, .{ .surfaces = owned.surfaces, .triangle_attributes = owned.triangle_attributes });
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, bytes, again);

    // Nothing to add: version 1, byte for byte `write`'s, whose hash is pinned above.
    const plain = try writeWith(gpa, &fixture_positions, &fixture_indices, .{ .triangle_attributes = &.{plain_attribute} });
    defer gpa.free(plain);
    try testing.expectEqual(@as(u64, 0xc854ac2cc345318d), core.id.fnv1a64(plain));
    const v1 = try read(plain, .default);
    try testing.expectEqual(@as(usize, 0), v1.surfaces.len + v1.triangle_attributes.len);
    var v1_owned = try v1.copy(gpa);
    defer v1_owned.deinit(gpa);
    try testing.expect(v1_owned.surfaceOf(0).isNone() and !v1_owned.oneSidedAt(0));
    // A one-sided face alone is reason enough for version 2.
    const sided = try writeWith(gpa, &fixture_positions, &fixture_indices, .{ .triangle_attributes = &.{plain_attribute | one_sided_bit} });
    defer gpa.free(sided);
    try testing.expectEqual(@as(?u32, 2), versionOf(sided));
}

test "fcol v2: every read refusal of the table and the attributes" {
    const gpa = testing.allocator;
    const bytes = try writeWith(gpa, &square_positions, &square_indices, .{ .surfaces = &.{ grass, stone }, .triangle_attributes = &.{ 0, 1 } });
    defer gpa.free(bytes);
    const v1_size = header_size + 4 * 12 + 6 * 4;
    const table = v1_size + 4;
    const attributes = table + 2 * 8;
    // Truncated anywhere, or one byte long, it is malformed.
    for (8..bytes.len) |length| try testing.expectError(error.Malformed, read(bytes[0..length], .default));
    const long = try gpa.alloc(u8, bytes.len + 1);
    defer gpa.free(long);
    @memcpy(long[0..bytes.len], bytes);
    long[bytes.len] = 0;
    try testing.expectError(error.Malformed, read(long, .default));
    const Case = struct { offset: usize, value: u32 };
    const cases = [_]Case{
        // A table past its limit, or one longer or shorter than the file holds.
        .{ .offset = v1_size, .value = max_surfaces + 1 },
        .{ .offset = v1_size, .value = 3 },
        .{ .offset = v1_size, .value = 1 },
        // The absent ID in the table.
        .{ .offset = table + 8, .value = 0 },
        // An index past the table, and reserved bits.
        .{ .offset = attributes, .value = 2 },
        .{ .offset = attributes + 4, .value = 1 | (1 << 17) },
        .{ .offset = attributes, .value = 0x8000_0000 },
    };
    for (cases) |case| {
        const bad = try gpa.dupe(u8, bytes);
        defer gpa.free(bad);
        std.mem.writeInt(u32, bad[case.offset..][0..4], case.value, .little);
        if (case.offset == table + 8) std.mem.writeInt(u32, bad[case.offset + 4 ..][0..4], 0, .little);
        try testing.expectError(error.Malformed, read(bad, .default));
    }
    // A version 1 file with version 2's tail is not version 1.
    const tailed = try gpa.dupe(u8, bytes);
    defer gpa.free(tailed);
    std.mem.writeInt(u32, tailed[4..8], 1, .little);
    try testing.expectError(error.Malformed, read(tailed, .default));
}

test "fcol v2: the writer refuses what the reader would" {
    const gpa = testing.allocator;
    const big = try gpa.alloc(core.ContentId, max_surfaces + 1);
    defer gpa.free(big);
    @memset(big, grass);
    try testing.expectError(error.InvalidMesh, writeWith(gpa, &square_positions, &square_indices, .{ .surfaces = big }));
    const full = try writeWith(gpa, &square_positions, &square_indices, .{ .surfaces = big[0..max_surfaces], .triangle_attributes = &.{ max_surfaces - 1, 0 } });
    defer gpa.free(full);
    try testing.expectEqual(@as(u16, max_surfaces - 1), surfaceIndex((try read(full, .default)).triangle_attributes[0]).?);
    // A table of 65,536 whose length the file does hold is refused by its count alone.
    const v1_size = header_size + 4 * 12 + 6 * 4;
    const over = try gpa.alloc(u8, full.len + 8);
    defer gpa.free(over);
    @memcpy(over[0 .. v1_size + 4 + max_surfaces * 8], full[0 .. v1_size + 4 + max_surfaces * 8]);
    std.mem.writeInt(u32, over[v1_size..][0..4], max_surfaces + 1, .little);
    std.mem.writeInt(u64, over[v1_size + 4 + max_surfaces * 8 ..][0..8], grass.hash, .little);
    @memcpy(over[over.len - 8 ..], full[full.len - 8 ..]);
    try testing.expectError(error.Malformed, read(over, .default));
    try testing.expectError(error.InvalidMesh, writeWith(gpa, &square_positions, &square_indices, .{ .surfaces = &.{core.ContentId.none} }));
    try testing.expectError(error.InvalidMesh, writeWith(gpa, &square_positions, &square_indices, .{ .surfaces = &.{grass}, .triangle_attributes = &.{0} }));
    try testing.expectError(error.InvalidMesh, writeWith(gpa, &square_positions, &square_indices, .{ .surfaces = &.{grass}, .triangle_attributes = &.{ 0, 1 } }));
    try testing.expectError(error.InvalidMesh, writeWith(gpa, &square_positions, &square_indices, .{ .surfaces = &.{grass}, .triangle_attributes = &.{ 0, 1 << 20 } }));
}

fn allocationProofV2(gpa: Allocator) !void {
    const bytes = try writeWith(gpa, &square_positions, &square_indices, .{ .surfaces = &.{grass}, .triangle_attributes = &.{ 0, one_sided_bit | no_surface } });
    defer gpa.free(bytes);
    const loader = collisionMeshLoader();
    const payload = try loader.load(null, gpa, std.mem.zeroes(@import("data").store.Record), bytes);
    defer loader.unload(null, gpa, payload);
    const mesh = fromPayload(payload);
    try testing.expect(mesh.surfaceOf(0).eql(grass) and mesh.oneSidedAt(1));
}

test "fcol v2: the loader reads version 2 and unwinds every allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationProofV2, .{});
}
