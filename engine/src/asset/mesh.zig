//! The in-memory runtime mesh shared by code-built geometry and M20's asset loader.
//!
//! This is ADR-0053's runtime representation, not a file format and not GPU residency.
//! Streams borrow their bytes from the builder, use asset-owned format names, and remain
//! entirely below `rhi`. `render3d` validates and copies them when it uploads a mesh.
//!
//! Design: `docs/design/render3d.md` §5 and ADR-0054.

const std = @import("std");
const core = @import("core");

const Vec3 = core.math.Vec3;

/// The fixed shader slot as well as the meaning of one vertex stream (ADR-0054).
pub const Semantic = enum(u8) {
    position = 0,
    normal = 1,
    tangent = 2,
    uv0 = 3,
    uv1 = 4,
    color = 5,
    joints = 6,
    weights = 7,

    pub fn slot(self: Semantic) u8 {
        return @intFromEnum(self);
    }
};

/// Formats the runtime mesh can carry.
///
/// These are deliberately asset names rather than aliases of `rhi.VertexFormat`: `asset`
/// and `rhi` are sibling L2 modules.
pub const VertexFormat = enum(u8) {
    float32x2 = 0,
    float32x3 = 1,
    float32x4 = 2,
    unorm8x4 = 3,
    uint8x4 = 4,

    pub fn size(self: VertexFormat) u32 {
        return switch (self) {
            .float32x2 => 8,
            .float32x3 => 12,
            .float32x4 => 16,
            .unorm8x4, .uint8x4 => 4,
        };
    }
};

pub const IndexFormat = enum(u8) {
    uint16 = 0,
    uint32 = 1,

    pub fn size(self: IndexFormat) u32 {
        return switch (self) {
            .uint16 => 2,
            .uint32 => 4,
        };
    }
};

/// One tightly packed stream. Streams are separate and never interleaved (ADR-0054).
pub const Stream = struct {
    semantic: Semantic,
    format: VertexFormat,
    bytes: []const u8,
};

/// One triangle-list range in the mesh's index buffer.
pub const Submesh = extern struct {
    first_index: u32,
    index_count: u32,
};

/// Local-space bounds. Both endpoints are finite and every position is contained, inclusive.
pub const Aabb = extern struct {
    min: Vec3,
    max: Vec3,

    pub fn contains(self: Aabb, point: Vec3) bool {
        return point.x >= self.min.x and point.x <= self.max.x and
            point.y >= self.min.y and point.y <= self.max.y and
            point.z >= self.min.z and point.z <= self.max.z;
    }

    pub fn isValid(self: Aabb) bool {
        return self.min.isFinite() and self.max.isFinite() and
            self.min.x <= self.max.x and
            self.min.y <= self.max.y and
            self.min.z <= self.max.z;
    }
};

/// Every malformed runtime-mesh shape has a stable, specific refusal.
pub const Error = error{
    EmptyVertices,
    MissingPosition,
    DuplicateSemantic,
    UnsupportedVertexFormat,
    InvalidStreamLength,
    IndexFormatTooSmall,
    InvalidIndexCount,
    IndexOutOfRange,
    MissingSubmesh,
    EmptySubmesh,
    InvalidSubmeshRange,
    NonFinitePosition,
    InvalidNormal,
    InvalidTangent,
    InvalidTexcoord,
    InvalidColor,
    InvalidBounds,
    IncompleteSkin,
    TooManyJoints,
    InvalidJointBounds,
    InvalidWeights,
    JointOutOfRange,
};

/// A borrowed, validated view of triangle-list geometry.
///
/// A builder owns every slice. M20's loader will own them instead. Nothing here allocates,
/// opens a file, or knows that a GPU exists.
pub const Mesh = struct {
    vertex_count: u32,
    streams: []const Stream,
    index_format: IndexFormat,
    indices: []const u8,
    submeshes: []align(1) const Submesh,
    bounds: Aabb,
    /// Model bind-space boxes, one per joint. Empty for unskinned meshes.
    /// A joint with no influenced vertices has a zero box (animation3d.md §6).
    joint_bounds: []align(1) const Aabb = &.{},

    /// Refuses malformed or unsupported geometry without repairing it.
    pub fn validate(self: Mesh) Error!void {
        if (self.vertex_count == 0) return error.EmptyVertices;
        if (self.index_format == .uint16 and self.vertex_count > 65_536) {
            return error.IndexFormatTooSmall;
        }

        var seen: u8 = 0;
        var positions: ?[]const u8 = null;
        var joints: ?[]const u8 = null;
        var weights: ?[]const u8 = null;
        for (self.streams) |stream| {
            const bit = @as(u8, 1) << @intCast(stream.semantic.slot());
            if (seen & bit != 0) return error.DuplicateSemantic;
            seen |= bit;

            const supported = switch (stream.semantic) {
                .position, .normal => stream.format == .float32x3,
                .tangent => stream.format == .float32x4,
                .uv0, .uv1 => stream.format == .float32x2,
                .color => stream.format == .unorm8x4 or stream.format == .float32x4,
                .joints => stream.format == .uint8x4,
                .weights => stream.format == .float32x4,
            };
            if (!supported) return error.UnsupportedVertexFormat;

            const expected = @as(u64, self.vertex_count) * stream.format.size();
            if (stream.bytes.len != expected) return error.InvalidStreamLength;
            if (stream.semantic == .position) positions = stream.bytes;
            if (stream.semantic == .joints) joints = stream.bytes;
            if (stream.semantic == .weights) weights = stream.bytes;

            switch (stream.semantic) {
                .normal => {
                    var offset: usize = 0;
                    while (offset < stream.bytes.len) : (offset += @sizeOf(Vec3)) {
                        const normal = readVec3(stream.bytes[offset..][0..@sizeOf(Vec3)]);
                        const length = normal.length();
                        if (!normal.isFinite() or !std.math.isFinite(length) or @abs(length - 1) > 1e-3) {
                            return error.InvalidNormal;
                        }
                    }
                },
                .tangent => {
                    var offset: usize = 0;
                    while (offset < stream.bytes.len) : (offset += 16) {
                        const xyz = readVec3(stream.bytes[offset..][0..12]);
                        const sign = std.mem.bytesToValue(f32, stream.bytes[offset + 12 ..][0..4]);
                        const length = xyz.length();
                        if (!xyz.isFinite() or !std.math.isFinite(length) or @abs(length - 1) > 1e-3 or
                            (sign != 1 and sign != -1)) return error.InvalidTangent;
                    }
                },
                .uv0, .uv1 => {
                    var offset: usize = 0;
                    while (offset < stream.bytes.len) : (offset += 8) {
                        const x = std.mem.bytesToValue(f32, stream.bytes[offset..][0..4]);
                        const y = std.mem.bytesToValue(f32, stream.bytes[offset + 4 ..][0..4]);
                        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidTexcoord;
                    }
                },
                .color => if (stream.format == .float32x4) {
                    var offset: usize = 0;
                    while (offset < stream.bytes.len) : (offset += 16) {
                        for (0..4) |component| {
                            const value = std.mem.bytesToValue(f32, stream.bytes[offset + component * 4 ..][0..4]);
                            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidColor;
                        }
                    }
                },
                else => {},
            }
        }
        const position_bytes = positions orelse return error.MissingPosition;
        if ((joints != null) != (weights != null) or
            (joints != null) != (self.joint_bounds.len != 0)) return error.IncompleteSkin;
        if (self.joint_bounds.len > 256) return error.TooManyJoints;
        for (self.joint_bounds) |box| if (!box.isValid()) return error.InvalidJointBounds;
        if (joints) |joint_bytes| {
            for (0..self.vertex_count) |vertex| {
                var sum: f32 = 0;
                const position = readVec3(position_bytes[vertex * 12 ..][0..12]);
                for (0..4) |lane| {
                    const weight = std.mem.bytesToValue(f32, weights.?[vertex * 16 + lane * 4 ..][0..4]);
                    if (!std.math.isFinite(weight) or weight < 0) return error.InvalidWeights;
                    sum += weight;
                    if (weight == 0) continue;
                    const joint = joint_bytes[vertex * 4 + lane];
                    if (joint >= self.joint_bounds.len) return error.JointOutOfRange;
                    if (!self.joint_bounds[joint].contains(position)) return error.InvalidJointBounds;
                }
                if (!std.math.isFinite(sum) or @abs(sum - 1) > 1e-3) return error.InvalidWeights;
            }
        }

        const index_size = self.index_format.size();
        if (self.indices.len % index_size != 0) return error.InvalidIndexCount;
        const index_count = self.indices.len / index_size;
        if (index_count % 3 != 0) return error.InvalidIndexCount;

        for (0..index_count) |i| {
            if (indexAt(self.index_format, self.indices, i) >= self.vertex_count) {
                return error.IndexOutOfRange;
            }
        }

        if (self.submeshes.len == 0) return error.MissingSubmesh;
        for (self.submeshes) |submesh| {
            if (submesh.index_count == 0) return error.EmptySubmesh;
            const first = @as(u64, submesh.first_index);
            const count = @as(u64, submesh.index_count);
            if (first % 3 != 0 or count % 3 != 0 or first + count > index_count) {
                return error.InvalidSubmeshRange;
            }
        }

        if (!self.bounds.isValid()) return error.InvalidBounds;
        var offset: usize = 0;
        while (offset < position_bytes.len) : (offset += @sizeOf(Vec3)) {
            const position = readVec3(position_bytes[offset..][0..@sizeOf(Vec3)]);
            if (!position.isFinite()) return error.NonFinitePosition;
            if (!self.bounds.contains(position)) return error.InvalidBounds;
        }
    }

    /// Computes exact local-space bounds for a builder's positions.
    ///
    /// Loaded bounds are never replaced with this result: `validate` checks what the asset
    /// supplied. This helper is for code that is constructing a mesh in the first place.
    pub fn computeBounds(positions: []const Vec3) Error!Aabb {
        if (positions.len == 0) return error.EmptyVertices;
        if (!positions[0].isFinite()) return error.NonFinitePosition;

        var result: Aabb = .{ .min = positions[0], .max = positions[0] };
        for (positions[1..]) |position| {
            if (!position.isFinite()) return error.NonFinitePosition;
            result.min.x = @min(result.min.x, position.x);
            result.min.y = @min(result.min.y, position.y);
            result.min.z = @min(result.min.z, position.z);
            result.max.x = @max(result.max.x, position.x);
            result.max.y = @max(result.max.y, position.y);
            result.max.z = @max(result.max.z, position.z);
        }
        return result;
    }
};

fn indexAt(format: IndexFormat, bytes: []const u8, index: usize) u32 {
    return switch (format) {
        .uint16 => std.mem.bytesToValue(u16, bytes[index * 2 ..][0..2]),
        .uint32 => std.mem.bytesToValue(u32, bytes[index * 4 ..][0..4]),
    };
}

fn readVec3(bytes: *const [@sizeOf(Vec3)]u8) Vec3 {
    return std.mem.bytesToValue(Vec3, bytes);
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const TestGeometry = struct {
    positions: [3]Vec3 = .{
        .{ .x = -2, .y = 1, .z = 4 },
        .{ .x = 3, .y = -5, .z = 0 },
        .{ .x = 1, .y = 2, .z = -6 },
    },
    colors: [3][4]u8 = .{
        .{ 255, 0, 0, 255 },
        .{ 0, 255, 0, 255 },
        .{ 0, 0, 255, 255 },
    },
    indices16: [3]u16 = .{ 0, 1, 2 },
    submeshes: [1]Submesh = .{.{ .first_index = 0, .index_count = 3 }},

    fn mesh(self: *const TestGeometry, streams: *[2]Stream) Mesh {
        streams.* = .{
            .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&self.positions) },
            .{ .semantic = .color, .format = .unorm8x4, .bytes = std.mem.sliceAsBytes(&self.colors) },
        };
        return .{
            .vertex_count = self.positions.len,
            .streams = streams,
            .index_format = .uint16,
            .indices = std.mem.sliceAsBytes(&self.indices16),
            .submeshes = &self.submeshes,
            .bounds = Mesh.computeBounds(&self.positions) catch unreachable,
        };
    }
};

fn validMesh(geometry: *const TestGeometry, streams: *[2]Stream) Mesh {
    return geometry.mesh(streams);
}

test "semantic values are the fixed shader slots" {
    try testing.expectEqual(@as(u8, 0), Semantic.position.slot());
    try testing.expectEqual(@as(u8, 1), Semantic.normal.slot());
    try testing.expectEqual(@as(u8, 2), Semantic.tangent.slot());
    try testing.expectEqual(@as(u8, 3), Semantic.uv0.slot());
    try testing.expectEqual(@as(u8, 4), Semantic.uv1.slot());
    try testing.expectEqual(@as(u8, 5), Semantic.color.slot());
    try testing.expectEqual(@as(u8, 6), Semantic.joints.slot());
    try testing.expectEqual(@as(u8, 7), Semantic.weights.slot());
}

test "a valid mesh passes and bounds are computed from every position" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    const mesh = validMesh(&geometry, &streams);

    try mesh.validate();
    try testing.expectEqual(Vec3{ .x = -2, .y = -5, .z = -6 }, mesh.bounds.min);
    try testing.expectEqual(Vec3{ .x = 3, .y = 2, .z = 4 }, mesh.bounds.max);
    try testing.expectEqual(@as(u32, 12), VertexFormat.float32x3.size());
    try testing.expectEqual(@as(u32, 8), VertexFormat.float32x2.size());
    try testing.expectEqual(@as(u32, 16), VertexFormat.float32x4.size());
    try testing.expectEqual(@as(u32, 4), VertexFormat.unorm8x4.size());
    try testing.expectEqual(@as(u32, 2), IndexFormat.uint16.size());
    try testing.expectEqual(@as(u32, 4), IndexFormat.uint32.size());
    try testing.expectEqual(@as(usize, 24), @sizeOf(Aabb));
}

test "an empty vertex set is refused" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    var mesh = validMesh(&geometry, &streams);
    mesh.vertex_count = 0;
    try testing.expectError(error.EmptyVertices, mesh.validate());
    try testing.expectError(error.EmptyVertices, Mesh.computeBounds(&.{}));
}

test "a mesh without positions is refused" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    var mesh = validMesh(&geometry, &streams);
    mesh.streams = streams[1..];
    try testing.expectError(error.MissingPosition, mesh.validate());
}

test "a semantic given twice is refused" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    const mesh = validMesh(&geometry, &streams);
    streams[1].semantic = .position;
    streams[1].format = .float32x3;
    try testing.expectError(error.DuplicateSemantic, mesh.validate());
}

test "each semantic accepts only its supported format set" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    const mesh = validMesh(&geometry, &streams);

    streams[0].format = .unorm8x4;
    try testing.expectError(error.UnsupportedVertexFormat, mesh.validate());
    streams[0].format = .float32x3;
    streams[1].format = .float32x3;
    try testing.expectError(error.UnsupportedVertexFormat, mesh.validate());
    streams[1] = .{ .semantic = .normal, .format = .float32x2, .bytes = streams[0].bytes };
    try testing.expectError(error.UnsupportedVertexFormat, mesh.validate());

    streams[1] = .{ .semantic = .tangent, .format = .float32x3, .bytes = streams[0].bytes };
    try testing.expectError(error.UnsupportedVertexFormat, mesh.validate());
}

test "tangent streams require finite unit xyz and an exact handedness sign" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    const mesh = validMesh(&geometry, &streams);
    var tangents = [_][4]f32{.{ 1, 0, 0, 1 }} ** 3;
    streams[1] = .{ .semantic = .tangent, .format = .float32x4, .bytes = std.mem.sliceAsBytes(&tangents) };
    try mesh.validate();
    tangents[0][3] = 0;
    try testing.expectError(error.InvalidTangent, mesh.validate());
    tangents[0][3] = -1;
    try mesh.validate();
    tangents[1][0] = 0.99;
    try testing.expectError(error.InvalidTangent, mesh.validate());
    tangents[1][0] = std.math.nan(f32);
    try testing.expectError(error.InvalidTangent, mesh.validate());
}

test "normal streams are finite and unit length" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    const mesh = validMesh(&geometry, &streams);
    var normals = [_]Vec3{ Vec3.up, Vec3.up, Vec3.up };
    streams[1] = .{ .semantic = .normal, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&normals) };
    try mesh.validate();
    normals[1].y = 0.998;
    try testing.expectError(error.InvalidNormal, mesh.validate());
    normals[1].y = std.math.nan(f32);
    try testing.expectError(error.InvalidNormal, mesh.validate());
}

test "texture coordinates are finite" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    const mesh = validMesh(&geometry, &streams);
    var uvs = [_]core.math.Vec2{ .{}, .{ .x = 1 }, .{ .y = 1 } };
    streams[1] = .{ .semantic = .uv0, .format = .float32x2, .bytes = std.mem.sliceAsBytes(&uvs) };
    try mesh.validate();
    uvs[2].x = std.math.inf(f32);
    try testing.expectError(error.InvalidTexcoord, mesh.validate());
}

test "float colour streams are finite and normalized" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    const mesh = validMesh(&geometry, &streams);
    var colors = [_][4]f32{ .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 0.5 }, .{ 0, 0, 1, 1 } };
    streams[1] = .{ .semantic = .color, .format = .float32x4, .bytes = std.mem.sliceAsBytes(&colors) };
    try mesh.validate();
    colors[1][3] = 1.01;
    try testing.expectError(error.InvalidColor, mesh.validate());
    colors[1][3] = std.math.nan(f32);
    try testing.expectError(error.InvalidColor, mesh.validate());
}

test "a stream length must exactly match its vertex count and format" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    const mesh = validMesh(&geometry, &streams);
    streams[0].bytes = streams[0].bytes[0 .. streams[0].bytes.len - 1];
    try testing.expectError(error.InvalidStreamLength, mesh.validate());
}

test "uint16 indices cannot address more than 65536 vertices" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    var mesh = validMesh(&geometry, &streams);
    mesh.vertex_count = 65_537;
    try testing.expectError(error.IndexFormatTooSmall, mesh.validate());
}

test "indices must be whole triangle lists" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    var mesh = validMesh(&geometry, &streams);
    const indices = mesh.indices;
    mesh.indices = indices[0..4];
    try testing.expectError(error.InvalidIndexCount, mesh.validate());
    mesh.indices = indices[0..5];
    try testing.expectError(error.InvalidIndexCount, mesh.validate());
}

test "every index must name a vertex" {
    var geometry: TestGeometry = .{};
    geometry.indices16[2] = 3;
    var streams: [2]Stream = undefined;
    const mesh = validMesh(&geometry, &streams);
    try testing.expectError(error.IndexOutOfRange, mesh.validate());
}

test "a mesh needs a non-empty submesh" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    var mesh = validMesh(&geometry, &streams);
    mesh.submeshes = &.{};
    try testing.expectError(error.MissingSubmesh, mesh.validate());

    mesh.submeshes = &geometry.submeshes;
    geometry.submeshes[0].index_count = 0;
    try testing.expectError(error.EmptySubmesh, mesh.validate());
}

test "a submesh is an in-range span of whole triangles" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    var mesh = validMesh(&geometry, &streams);

    geometry.submeshes[0] = .{ .first_index = 3, .index_count = 3 };
    try testing.expectError(error.InvalidSubmeshRange, mesh.validate());
    geometry.submeshes[0] = .{ .first_index = 1, .index_count = 3 };
    try testing.expectError(error.InvalidSubmeshRange, mesh.validate());
}

test "non-finite positions are refused by validation and bounds computation" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    var mesh = validMesh(&geometry, &streams);
    geometry.positions[1].x = std.math.nan(f32);
    mesh.bounds = .{ .min = .{ .x = -10, .y = -10, .z = -10 }, .max = .{ .x = 10, .y = 10, .z = 10 } };
    try testing.expectError(error.NonFinitePosition, mesh.validate());
    try testing.expectError(error.NonFinitePosition, Mesh.computeBounds(&geometry.positions));
}

test "bounds must be finite, ordered, and contain every position" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    var mesh = validMesh(&geometry, &streams);

    mesh.bounds.min.x = std.math.nan(f32);
    try testing.expectError(error.InvalidBounds, mesh.validate());
    mesh.bounds = .{ .min = Vec3.one, .max = Vec3.zero };
    try testing.expectError(error.InvalidBounds, mesh.validate());
    mesh.bounds = .{ .min = .{ .x = -1, .y = -5, .z = -6 }, .max = .{ .x = 3, .y = 2, .z = 4 } };
    try testing.expectError(error.InvalidBounds, mesh.validate());
}

test "uint32 indices are read without alignment assumptions" {
    var geometry: TestGeometry = .{};
    var streams: [2]Stream = undefined;
    var mesh = validMesh(&geometry, &streams);
    const storage = [_]u8{ 0xaa, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0 };
    mesh.index_format = .uint32;
    mesh.indices = storage[1..];
    try mesh.validate();
}
