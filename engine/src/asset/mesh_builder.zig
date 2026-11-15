//! Typed streams in, a validated `asset.Mesh` out (`docs/design/runtime-geometry.md` §3).
//!
//! A generator produces the same runtime mesh an importer does (ADR-0053), and this is how it
//! does so without writing little-endian bytes by hand. Each setter copies its values into
//! memory the builder owns; `finish` computes the bounds, validates the result exactly as a
//! loaded `.fmesh` is validated, and hands every byte to the returned `OwnedMesh`.
//!
//! **Pure and thread-free.** It allocates only through the allocator it is given and touches
//! no device and no global, so a background task may run it (ADR-0061). The same calls with
//! the same values give the same bytes (I9).
//!
//! **A generator's mistake is the same named error a hostile file gets.** Counts are checked
//! against `Limits` before anything is copied, so a runaway count is refused rather than
//! allocated; everything else is `Mesh.validate`'s.

const std = @import("std");
const core = @import("core");

const mesh_mod = @import("mesh.zig");
const tangents = @import("tangents.zig");

const Allocator = std.mem.Allocator;
const Vec3 = core.math.Vec3;
const Mesh = mesh_mod.Mesh;
const Semantic = mesh_mod.Semantic;
const Stream = mesh_mod.Stream;
const Submesh = mesh_mod.Submesh;
const VertexFormat = mesh_mod.VertexFormat;
const IndexFormat = mesh_mod.IndexFormat;

/// Bounds on what one builder accepts. The defaults are `.fmesh`'s (`mesh_file.Limits`), so a
/// generated mesh may be as large as a loaded one and no larger.
pub const Limits = struct {
    max_vertices: u32 = 16_777_216,
    /// Three per triangle; four times the vertex limit leaves room for any closed surface.
    max_indices: u32 = 67_108_864,
    max_submeshes: u32 = 65_536,

    pub const default: Limits = .{};
};

pub const Error = mesh_mod.Error || Allocator.Error || error{
    TooManyVertices,
    TooManyIndices,
    TooManySubmeshes,
    /// Indices were given twice.
    IndicesAlreadySet,
    /// `generateTangents` needs normals, UV0 and indices, each already set.
    TangentsNeedNormals,
    TangentsNeedUv0,
    TangentsNeedIndices,
};

/// A validated mesh whose every slice was allocated by the builder's allocator. It may be
/// moved freely, and across threads; `deinit` with that same allocator.
pub const OwnedMesh = struct {
    mesh: Mesh,

    pub fn deinit(self: *OwnedMesh, gpa: Allocator) void {
        for (self.mesh.streams) |stream| gpa.free(stream.bytes);
        gpa.free(self.mesh.streams);
        gpa.free(self.mesh.indices);
        // `Mesh` views submeshes unaligned, for file bytes; these were allocated aligned.
        const submeshes: []const Submesh = @alignCast(self.mesh.submeshes);
        gpa.free(submeshes);
        self.* = undefined;
    }
};

pub const Builder = struct {
    gpa: Allocator,
    limits: Limits,
    /// Indexed by slot (ADR-0054); `null` until set.
    streams: [8]?Stream = @splat(null),
    vertex_count: ?u32 = null,
    /// Computed from the typed positions when they are given.
    bounds: ?mesh_mod.Aabb = null,
    index_format: IndexFormat = .uint16,
    indices: ?[]u8 = null,
    submeshes: std.ArrayList(Submesh) = .empty,

    const Self = @This();

    pub fn init(gpa: Allocator, limits: Limits) Self {
        return .{ .gpa = gpa, .limits = limits };
    }

    /// Frees whatever `finish` did not take. Safe after `finish`, and after a refusal.
    pub fn deinit(self: *Self) void {
        for (&self.streams) |*slot| if (slot.*) |stream| {
            self.gpa.free(stream.bytes);
            slot.* = null;
        };
        if (self.indices) |bytes| self.gpa.free(bytes);
        self.indices = null;
        self.submeshes.deinit(self.gpa);
    }

    /// A non-finite position is refused here, where the bounds are computed from it.
    pub fn positions(self: *Self, values: []const Vec3) Error!void {
        if (self.streams[Semantic.position.slot()] != null) return error.DuplicateSemantic;
        if (values.len > self.limits.max_vertices) return error.TooManyVertices;
        const bounds = try Mesh.computeBounds(values);
        try self.addStream(.position, .float32x3, std.mem.sliceAsBytes(values), values.len);
        self.bounds = bounds;
    }

    pub fn normals(self: *Self, values: []const Vec3) Error!void {
        try self.addStream(.normal, .float32x3, std.mem.sliceAsBytes(values), values.len);
    }

    pub fn uv0(self: *Self, values: []const [2]f32) Error!void {
        try self.addStream(.uv0, .float32x2, std.mem.sliceAsBytes(values), values.len);
    }

    /// Float colour, each channel in [0, 1].
    pub fn colors(self: *Self, values: []const [4]f32) Error!void {
        try self.addStream(.color, .float32x4, std.mem.sliceAsBytes(values), values.len);
    }

    /// Normalized 8-bit colour, the compact form vertex-coloured geometry uses.
    pub fn colors8(self: *Self, values: []const [4]u8) Error!void {
        try self.addStream(.color, .unorm8x4, std.mem.sliceAsBytes(values), values.len);
    }

    pub fn indices16(self: *Self, values: []const u16) Error!void {
        try self.setIndices(.uint16, std.mem.sliceAsBytes(values), values.len);
    }

    pub fn indices32(self: *Self, values: []const u32) Error!void {
        try self.setIndices(.uint32, std.mem.sliceAsBytes(values), values.len);
    }

    /// One triangle-list range. With none, `finish` makes one spanning every index.
    pub fn submesh(self: *Self, first_index: u32, index_count: u32) Error!void {
        if (self.submeshes.items.len >= self.limits.max_submeshes) return error.TooManySubmeshes;
        try self.submeshes.append(self.gpa, .{ .first_index = first_index, .index_count = index_count });
    }

    /// MikkTSpace tangents from the positions, normals, UV0 and indices already set
    /// (ADR-0086, `docs/design/environment.md` §5.2), as a `float32x4` tangent stream.
    ///
    /// MikkTSpace gives each corner its own tangent, and corners of one vertex differ at a UV
    /// seam or a mirror. A vertex keeps its index and its first corner's tangent; each other
    /// tangent its corners need becomes one new vertex at the end, a copy of every stream,
    /// in the order of the corners that first need it. So a mesh whose corners agree gains
    /// only the tangent stream, and the same input gives the same bytes. A vertex no index
    /// names gets +x with a sign of +1. 16-bit indices become 32-bit if the new vertices
    /// pass their range.
    ///
    /// A tangent MikkTSpace cannot normalize, from a normal along the UV's direction or a
    /// zero normal, is written as it is and refused by `finish` as `InvalidTangent`. On any
    /// refusal the builder is unchanged.
    pub fn generateTangents(self: *Self) Error!void {
        if (self.streams[Semantic.tangent.slot()] != null) return error.DuplicateSemantic;
        const position = self.streams[Semantic.position.slot()] orelse return error.MissingPosition;
        const normal = self.streams[Semantic.normal.slot()] orelse return error.TangentsNeedNormals;
        const uv = self.streams[Semantic.uv0.slot()] orelse return error.TangentsNeedUv0;
        const index_bytes = self.indices orelse return error.TangentsNeedIndices;
        const vertex_count = self.vertex_count.?;
        if (normal.bytes.len != @as(usize, vertex_count) * 12 or uv.bytes.len != @as(usize, vertex_count) * 8) {
            return error.InvalidStreamLength;
        }

        const index_count = index_bytes.len / self.index_format.size();
        const indices = try self.gpa.alloc(u32, index_count);
        defer self.gpa.free(indices);
        for (indices, 0..) |*index, i| index.* = switch (self.index_format) {
            .uint16 => std.mem.readInt(u16, index_bytes[i * 2 ..][0..2], .little),
            .uint32 => std.mem.readInt(u32, index_bytes[i * 4 ..][0..4], .little),
        };

        const corners = tangents.generate(self.gpa, .{
            .positions = std.mem.bytesAsSlice([3]f32, position.bytes),
            .normals = std.mem.bytesAsSlice([3]f32, normal.bytes),
            .uvs = std.mem.bytesAsSlice([2]f32, uv.bytes),
            .indices = indices,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamLengthMismatch => error.InvalidStreamLength,
            error.InvalidIndexCount => error.InvalidIndexCount,
            error.IndexOutOfRange => error.IndexOutOfRange,
            error.TooManyTriangles => error.TooManyIndices,
            error.NonFinitePosition => error.NonFinitePosition,
            error.NonFiniteNormal => error.InvalidNormal,
            error.NonFiniteTexcoord => error.InvalidTexcoord,
        };
        defer self.gpa.free(corners);

        // Which vertex each corner ends on, and the vertices the split adds.
        const first = try self.gpa.alloc(?tangents.Tangent, vertex_count);
        defer self.gpa.free(first);
        @memset(first, null);
        const Key = struct { vertex: u32, bits: [4]u32 };
        var added: std.AutoHashMapUnmanaged(Key, u32) = .empty;
        defer added.deinit(self.gpa);
        var sources: std.ArrayList(u32) = .empty;
        defer sources.deinit(self.gpa);
        var extra: std.ArrayList(tangents.Tangent) = .empty;
        defer extra.deinit(self.gpa);
        for (indices, corners) |*index, tangent| {
            const vertex = index.*;
            if (first[vertex]) |kept| {
                if (@as(u128, @bitCast(kept)) == @as(u128, @bitCast(tangent))) continue;
                const entry = try added.getOrPut(self.gpa, .{ .vertex = vertex, .bits = @bitCast(tangent) });
                if (!entry.found_existing) {
                    if (vertex_count + sources.items.len >= self.limits.max_vertices) return error.TooManyVertices;
                    entry.value_ptr.* = @intCast(vertex_count + sources.items.len);
                    try sources.append(self.gpa, vertex);
                    try extra.append(self.gpa, tangent);
                }
                index.* = entry.value_ptr.*;
            } else {
                first[vertex] = tangent;
            }
        }
        const total: u32 = @intCast(vertex_count + sources.items.len);

        // Every new buffer before anything is replaced, so a refusal changes nothing.
        var grown: [8]?[]u8 = @splat(null);
        defer for (grown) |bytes| if (bytes) |b| self.gpa.free(b);
        for (self.streams, 0..) |slot, at| if (slot) |stream| {
            if (sources.items.len == 0) continue;
            const stride = stream.format.size();
            const bytes = try self.gpa.alloc(u8, @as(usize, total) * stride);
            grown[at] = bytes;
            @memcpy(bytes[0..stream.bytes.len], stream.bytes);
            for (sources.items, 0..) |source, k| {
                @memcpy(bytes[(vertex_count + k) * stride ..][0..stride], stream.bytes[source * stride ..][0..stride]);
            }
        };
        // Bytes, as every stream is, so `deinit` frees them as it frees the others.
        const tangent_bytes = try self.gpa.alloc(u8, @as(usize, total) * 16);
        grown[Semantic.tangent.slot()] = tangent_bytes;
        for (first, 0..) |kept, v| {
            const value: tangents.Tangent = kept orelse .{ 1, 0, 0, 1 };
            @memcpy(tangent_bytes[v * 16 ..][0..16], std.mem.asBytes(&value));
        }
        @memcpy(tangent_bytes[@as(usize, vertex_count) * 16 ..], std.mem.sliceAsBytes(extra.items));

        const format: IndexFormat = if (self.index_format == .uint16 and total <= 65_536) .uint16 else .uint32;
        const new_indices = try self.gpa.alloc(u8, index_count * format.size());
        errdefer self.gpa.free(new_indices);
        for (indices, 0..) |index, i| switch (format) {
            .uint16 => std.mem.writeInt(u16, new_indices[i * 2 ..][0..2], @intCast(index), .little),
            .uint32 => std.mem.writeInt(u32, new_indices[i * 4 ..][0..4], index, .little),
        };

        // Nothing below fails.
        for (&self.streams, &grown) |*slot, *bytes| if (bytes.*) |b| {
            if (slot.*) |*stream| {
                self.gpa.free(stream.bytes);
                stream.bytes = b;
            } else {
                slot.* = .{ .semantic = .tangent, .format = .float32x4, .bytes = b };
            }
            bytes.* = null;
        };
        self.gpa.free(index_bytes);
        self.indices = new_indices;
        self.index_format = format;
        self.vertex_count = total;
    }

    /// Bounds from the positions, then `Mesh.validate`. On success the bytes are the returned
    /// mesh's and the builder is empty; on a refusal the builder still owns them.
    pub fn finish(self: *Self) Error!OwnedMesh {
        if (self.streams[Semantic.position.slot()] == null) return error.MissingPosition;
        const vertex_count = self.vertex_count.?;
        const index_bytes = self.indices orelse &.{};
        if (self.submeshes.items.len == 0) {
            const count = index_bytes.len / self.index_format.size();
            if (count != 0) try self.submesh(0, @intCast(count));
        }

        var count: usize = 0;
        for (self.streams) |slot| count += @intFromBool(slot != null);
        const streams = try self.gpa.alloc(Stream, count);
        errdefer self.gpa.free(streams);
        var at: usize = 0;
        for (self.streams) |slot| if (slot) |value| {
            streams[at] = value;
            at += 1;
        };

        var built: Mesh = .{
            .vertex_count = vertex_count,
            .streams = streams,
            .index_format = self.index_format,
            .indices = index_bytes,
            .submeshes = self.submeshes.items,
            .bounds = self.bounds.?,
        };
        try built.validate();

        // The last thing that can fail: nothing has moved out of the builder before it.
        built.submeshes = try self.submeshes.toOwnedSlice(self.gpa);
        // A validated mesh has a non-empty submesh, so it has indices.
        built.indices = self.indices.?;
        self.indices = null;
        self.streams = @splat(null);
        self.vertex_count = null;
        self.bounds = null;
        return .{ .mesh = built };
    }

    fn addStream(self: *Self, semantic: Semantic, format: VertexFormat, bytes: []const u8, count: usize) Error!void {
        if (self.streams[semantic.slot()] != null) return error.DuplicateSemantic;
        if (count > self.limits.max_vertices) return error.TooManyVertices;
        // Every stream must have the positions' count, and `validate` names a mismatch
        // whichever stream was given first.
        if (semantic == .position) self.vertex_count = @intCast(count);
        const owned = try self.gpa.dupe(u8, bytes);
        self.streams[semantic.slot()] = .{ .semantic = semantic, .format = format, .bytes = owned };
    }

    fn setIndices(self: *Self, format: IndexFormat, bytes: []const u8, count: usize) Error!void {
        if (self.indices != null) return error.IndicesAlreadySet;
        if (count > self.limits.max_indices) return error.TooManyIndices;
        const owned = try self.gpa.dupe(u8, bytes);
        self.indices = owned;
        self.index_format = format;
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

const quad_positions = [_]Vec3{ .init(-1, 0, 1), .init(1, 0, 1), .init(1, 0, -1), .init(-1, 0, -1) };
const quad_normals = [_]Vec3{.up} ** 4;
const quad_colors = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 255, 255, 255, 255 } };
const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

fn buildQuad(gpa: Allocator) Error!OwnedMesh {
    var builder = Builder.init(gpa, .default);
    defer builder.deinit();
    try builder.positions(&quad_positions);
    try builder.normals(&quad_normals);
    try builder.colors8(&quad_colors);
    try builder.indices16(&quad_indices);
    return builder.finish();
}

test "a builder-made quad is byte-identical to a hand-written one" {
    var owned = try buildQuad(testing.allocator);
    defer owned.deinit(testing.allocator);

    const hand: Mesh = .{
        .vertex_count = 4,
        .streams = &.{
            .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&quad_positions) },
            .{ .semantic = .normal, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&quad_normals) },
            .{ .semantic = .color, .format = .unorm8x4, .bytes = std.mem.sliceAsBytes(&quad_colors) },
        },
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&quad_indices),
        .submeshes = &.{.{ .first_index = 0, .index_count = 6 }},
        .bounds = try Mesh.computeBounds(&quad_positions),
    };
    const got = owned.mesh;
    try testing.expectEqual(hand.vertex_count, got.vertex_count);
    try testing.expectEqual(hand.streams.len, got.streams.len);
    for (hand.streams, got.streams) |want, have| {
        try testing.expectEqual(want.semantic, have.semantic);
        try testing.expectEqual(want.format, have.format);
        try testing.expectEqualSlices(u8, want.bytes, have.bytes);
    }
    try testing.expectEqual(hand.index_format, got.index_format);
    try testing.expectEqualSlices(u8, hand.indices, got.indices);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(hand.submeshes), std.mem.sliceAsBytes(got.submeshes));
    try testing.expectEqual(hand.bounds, got.bounds);
}

test "streams come out in slot order whatever order they were given in" {
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.colors8(&quad_colors);
    try builder.indices16(&quad_indices);
    try builder.normals(&quad_normals);
    try builder.positions(&quad_positions);
    var owned = try builder.finish();
    defer owned.deinit(testing.allocator);
    try testing.expectEqual(Semantic.position, owned.mesh.streams[0].semantic);
    try testing.expectEqual(Semantic.normal, owned.mesh.streams[1].semantic);
    try testing.expectEqual(Semantic.color, owned.mesh.streams[2].semantic);
}

test "two runs over the same values give the same bytes" {
    var a = try buildQuad(testing.allocator);
    defer a.deinit(testing.allocator);
    var b = try buildQuad(testing.allocator);
    defer b.deinit(testing.allocator);
    for (a.mesh.streams, b.mesh.streams) |x, y| try testing.expectEqualSlices(u8, x.bytes, y.bytes);
    try testing.expectEqualSlices(u8, a.mesh.indices, b.mesh.indices);
}

test "uv, float colour, 32-bit indices and explicit submeshes are carried" {
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(&quad_positions);
    try builder.uv0(&.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } });
    try builder.colors(&([_][4]f32{.{ 1, 1, 1, 1 }} ** 4));
    try builder.indices32(&.{ 0, 1, 2, 0, 2, 3 });
    try builder.submesh(0, 3);
    try builder.submesh(3, 3);
    var owned = try builder.finish();
    defer owned.deinit(testing.allocator);
    try testing.expectEqual(IndexFormat.uint32, owned.mesh.index_format);
    try testing.expectEqual(@as(usize, 2), owned.mesh.submeshes.len);
    try testing.expectEqual(VertexFormat.float32x4, owned.mesh.streams[2].format);
}

test "a stream whose count differs from the positions' is refused, either way round" {
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(&quad_positions);
    try builder.normals(quad_normals[0..3]);
    try builder.indices16(&quad_indices);
    try testing.expectError(error.InvalidStreamLength, builder.finish());

    var other = Builder.init(testing.allocator, .default);
    defer other.deinit();
    try other.normals(quad_normals[0..3]);
    try other.positions(&quad_positions);
    try other.indices16(&quad_indices);
    try testing.expectError(error.InvalidStreamLength, other.finish());
}

test "non-finite values, bad normals and indices out of range are refused" {
    var nan_positions = quad_positions;
    nan_positions[2].y = std.math.nan(f32);
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try testing.expectError(error.NonFinitePosition, builder.positions(&nan_positions));
    try testing.expectError(error.MissingPosition, builder.finish());

    var short_normals = quad_normals;
    short_normals[1] = .init(0, 0.5, 0);
    var b2 = Builder.init(testing.allocator, .default);
    defer b2.deinit();
    try b2.positions(&quad_positions);
    try b2.normals(&short_normals);
    try b2.indices16(&quad_indices);
    try testing.expectError(error.InvalidNormal, b2.finish());

    var b3 = Builder.init(testing.allocator, .default);
    defer b3.deinit();
    try b3.positions(&quad_positions);
    try b3.indices16(&.{ 0, 1, 4 });
    try testing.expectError(error.IndexOutOfRange, b3.finish());
}

test "a submesh past the end, missing positions and missing indices are refused" {
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(&quad_positions);
    try builder.indices16(&quad_indices);
    try builder.submesh(3, 6);
    try testing.expectError(error.InvalidSubmeshRange, builder.finish());

    var b2 = Builder.init(testing.allocator, .default);
    defer b2.deinit();
    try b2.normals(&quad_normals);
    try testing.expectError(error.MissingPosition, b2.finish());

    var b3 = Builder.init(testing.allocator, .default);
    defer b3.deinit();
    try b3.positions(&quad_positions);
    try testing.expectError(error.MissingSubmesh, b3.finish());
}

test "a stream or the indices given twice are refused" {
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(&quad_positions);
    try testing.expectError(error.DuplicateSemantic, builder.positions(&quad_positions));
    try builder.colors8(&quad_colors);
    try testing.expectError(error.DuplicateSemantic, builder.colors(&([_][4]f32{.{ 1, 1, 1, 1 }} ** 4)));
    try builder.indices16(&quad_indices);
    try testing.expectError(error.IndicesAlreadySet, builder.indices32(&.{ 0, 1, 2 }));
}

test "limits refuse a count before anything is copied" {
    const limits: Limits = .{ .max_vertices = 3, .max_indices = 3, .max_submeshes = 1 };
    var builder = Builder.init(testing.allocator, limits);
    defer builder.deinit();
    try testing.expectError(error.TooManyVertices, builder.positions(&quad_positions));
    try testing.expectError(error.TooManyVertices, builder.normals(&quad_normals));
    try testing.expectError(error.TooManyVertices, builder.colors8(&quad_colors));
    try testing.expectError(error.TooManyIndices, builder.indices16(&quad_indices));
    try builder.submesh(0, 3);
    try testing.expectError(error.TooManySubmeshes, builder.submesh(0, 3));
}

test "more than 65536 vertices refuse 16-bit indices" {
    const positions = try testing.allocator.alloc(Vec3, 65_537);
    defer testing.allocator.free(positions);
    for (positions, 0..) |*p, i| p.* = .init(@floatFromInt(i % 7), 0, 0);
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(positions);
    try builder.indices16(&.{ 0, 1, 2 });
    try testing.expectError(error.IndexFormatTooSmall, builder.finish());
}

test "a refusal leaves the builder owning its bytes, and a finish leaves it empty" {
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(&quad_positions);
    try testing.expectError(error.MissingSubmesh, builder.finish());
    try builder.indices16(&quad_indices);
    var owned = try builder.finish();
    defer owned.deinit(testing.allocator);
    try testing.expect(builder.indices == null);
    for (builder.streams) |slot| try testing.expect(slot == null);
}

const quad_uvs = [_][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };

test "generated tangents on a quad add only the tangent stream" {
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(&quad_positions);
    try builder.normals(&quad_normals);
    try builder.uv0(&quad_uvs);
    try builder.colors8(&quad_colors);
    try builder.indices16(&quad_indices);
    try builder.generateTangents();
    var owned = try builder.finish();
    defer owned.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 4), owned.mesh.vertex_count);
    try testing.expectEqual(IndexFormat.uint16, owned.mesh.index_format);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&quad_indices), owned.mesh.indices);
    try testing.expectEqual(Semantic.tangent, owned.mesh.streams[2].semantic);
    const want = [_][4]f32{.{ 1, 0, 0, -1 }} ** 4;
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want), owned.mesh.streams[2].bytes);
}

test "a vertex whose corners disagree is split, every stream copied" {
    // Two triangles share vertices 0 and 2, but the second is UV-mirrored, so its corners
    // need the opposite tangent there.
    const positions = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 0, -1), .init(-1, 0, 0) };
    const normals = [_]Vec3{.up} ** 4;
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 } };
    const colors = [_][4]u8{ .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, .{ 9, 10, 11, 12 }, .{ 13, 14, 15, 16 } };
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(&positions);
    try builder.normals(&normals);
    try builder.uv0(&uvs);
    try builder.colors8(&colors);
    try builder.indices16(&indices);
    try builder.generateTangents();
    var owned = try builder.finish();
    defer owned.deinit(testing.allocator);

    const mesh = owned.mesh;
    try testing.expectEqual(@as(u32, 6), mesh.vertex_count);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&[_]u16{ 0, 1, 2, 4, 5, 3 }), mesh.indices);
    const new_positions = std.mem.bytesAsSlice(Vec3, mesh.streams[0].bytes);
    try testing.expectEqual(positions[0], new_positions[4]);
    try testing.expectEqual(positions[2], new_positions[5]);
    const new_colors = std.mem.bytesAsSlice([4]u8, mesh.streams[4].bytes);
    try testing.expectEqual(colors[0], new_colors[4]);
    try testing.expectEqual(colors[2], new_colors[5]);
    const new_tangents = std.mem.bytesAsSlice([4]f32, mesh.streams[2].bytes);
    for ([_]usize{ 0, 1, 2 }) |v| try testing.expectEqual(@as(f32, 1), new_tangents[v][0]);
    for ([_]usize{ 3, 4, 5 }) |v| try testing.expectEqual(@as(f32, -1), new_tangents[v][0]);
}

test "a split past 65536 vertices widens the indices" {
    // 65,535 vertices, and a mirrored triangle that needs two more.
    const count = 65_535;
    const positions = try testing.allocator.alloc(Vec3, count);
    defer testing.allocator.free(positions);
    const normals = try testing.allocator.alloc(Vec3, count);
    defer testing.allocator.free(normals);
    const uvs = try testing.allocator.alloc([2]f32, count);
    defer testing.allocator.free(uvs);
    for (positions, normals, uvs, 0..) |*p, *n, *t, i| {
        p.* = .init(@floatFromInt(i % 251), 0, -@as(f32, @floatFromInt(i / 251)));
        n.* = .up;
        t.* = .{ p.x, -p.z };
    }
    // Two triangles on vertices 0, 1, 251: the second mirrors u.
    uvs[252] = .{ 1, 0 };
    positions[252] = .init(-1, 0, 0);
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(positions);
    try builder.normals(normals);
    try builder.uv0(uvs);
    try builder.indices16(&.{ 0, 1, 251, 0, 251, 252 });
    try builder.generateTangents();
    try testing.expectEqual(IndexFormat.uint32, builder.index_format);
    var owned = try builder.finish();
    defer owned.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, count + 2), owned.mesh.vertex_count);
}

test "generateTangents refuses missing inputs, a second tangent stream and a split past the limit" {
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try testing.expectError(error.MissingPosition, builder.generateTangents());
    try builder.positions(&quad_positions);
    try testing.expectError(error.TangentsNeedNormals, builder.generateTangents());
    try builder.normals(&quad_normals);
    try testing.expectError(error.TangentsNeedUv0, builder.generateTangents());
    try builder.uv0(&quad_uvs);
    try testing.expectError(error.TangentsNeedIndices, builder.generateTangents());
    try builder.indices16(&quad_indices);
    try builder.generateTangents();
    try testing.expectError(error.DuplicateSemantic, builder.generateTangents());

    const positions = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 0, -1), .init(-1, 0, 0) };
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 } };
    var tight = Builder.init(testing.allocator, .{ .max_vertices = 5 });
    defer tight.deinit();
    try tight.positions(&positions);
    try tight.normals(&quad_normals);
    try tight.uv0(&uvs);
    try tight.indices16(&.{ 0, 1, 2, 0, 2, 3 });
    try testing.expectError(error.TooManyVertices, tight.generateTangents());
    // Unchanged by the refusal.
    try testing.expectEqual(@as(u32, 4), tight.vertex_count.?);
    try testing.expect(tight.streams[Semantic.tangent.slot()] == null);

    var bad = Builder.init(testing.allocator, .default);
    defer bad.deinit();
    try bad.positions(&quad_positions);
    try bad.normals(&quad_normals);
    try bad.uv0(&quad_uvs);
    try bad.indices16(&.{ 0, 1, 7 });
    try testing.expectError(error.IndexOutOfRange, bad.generateTangents());
}

test "a tangent MikkTSpace cannot normalize is refused at finish" {
    // Normals along +x, the UV's u direction: the projected tangent is zero.
    const along = [_]Vec3{.init(1, 0, 0)} ** 4;
    var builder = Builder.init(testing.allocator, .default);
    defer builder.deinit();
    try builder.positions(&quad_positions);
    try builder.normals(&along);
    try builder.uv0(&quad_uvs);
    try builder.indices16(&quad_indices);
    try builder.generateTangents();
    try testing.expectError(error.InvalidTangent, builder.finish());
}

test "every allocation failure while generating tangents leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            const positions = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 0, -1), .init(-1, 0, 0) };
            const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 } };
            var builder = Builder.init(gpa, .default);
            defer builder.deinit();
            try builder.positions(&positions);
            try builder.normals(&quad_normals);
            try builder.uv0(&uvs);
            try builder.colors8(&quad_colors);
            try builder.indices16(&.{ 0, 1, 2, 0, 2, 3 });
            try builder.generateTangents();
            var owned = try builder.finish();
            owned.deinit(gpa);
        }
    }.run, .{});
}

test "every allocation failure is reported and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var owned = try buildQuad(gpa);
            owned.deinit(gpa);
        }
    }.run, .{});
}
