//! The bounded, canonical `.fmesh` runtime mesh format.
//!
//! The file borrows the same `Mesh` that code-built geometry uses. Reading copies no payload:
//! a `View` owns only eight stream descriptors and every byte slice points into the caller's
//! input. See `docs/design/meshes.md` §3.

const std = @import("std");
const builtin = @import("builtin");
const mesh_mod = @import("mesh.zig");

const Allocator = std.mem.Allocator;
const Aabb = mesh_mod.Aabb;
const IndexFormat = mesh_mod.IndexFormat;
const Mesh = mesh_mod.Mesh;
const Semantic = mesh_mod.Semantic;
const Stream = mesh_mod.Stream;
const Submesh = mesh_mod.Submesh;
const VertexFormat = mesh_mod.VertexFormat;

comptime {
    if (builtin.cpu.arch.endian() != .little) {
        @compileError(".fmesh payloads require a little-endian target");
    }
    if (@sizeOf(Submesh) != 8) @compileError(".fmesh submesh layout changed");
    if (@sizeOf(Aabb) != 24) @compileError(".fmesh joint-bounds layout changed");
}

pub const magic = "FMSH";
pub const format_version: u32 = 2;
pub const header_size: usize = 48;
pub const skin_header_size: usize = 56;
pub const stream_entry_size: usize = 12;
pub const submesh_entry_size: usize = 8;
pub const max_streams: usize = 8;

pub const Limits = struct {
    max_file_bytes: u64 = 256 * 1024 * 1024,
    max_vertices: u32 = 16_777_216,
    max_submeshes: u32 = 65_536,
    max_joints: u16 = 256,

    pub const default: Limits = .{};
};

pub const ReadError = error{
    NotAMesh,
    UnsupportedVersion,
    Malformed,
    OverLimit,
} || mesh_mod.Error;

pub const WriteError = error{TooLarge} || mesh_mod.Error || Allocator.Error;

/// The format version, when the bytes have the mesh magic and a complete version field.
pub fn versionOf(bytes: []const u8) ?u32 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], magic)) return null;
    return std.mem.readInt(u32, bytes[4..8], .little);
}

/// A no-allocation view of one validated file. Keep this value at a stable address while a
/// `Mesh` returned by `mesh` is in use: that mesh's stream slice points into this value.
pub const View = struct {
    bytes: []const u8,
    vertex_count: u32,
    index_format: IndexFormat,
    index_offset: u32,
    index_length: u32,
    submesh_offset: u32,
    submesh_count: u32,
    bounds: Aabb,
    descriptors: [max_streams]Descriptor,
    stream_count: u8,
    joint_bounds: []align(1) const Aabb = &.{},
    streams: [max_streams]Stream = undefined,

    const Descriptor = struct {
        semantic: Semantic,
        format: VertexFormat,
        offset: u32,
        length: u32,
    };

    pub fn mesh(self: *View) Mesh {
        for (self.descriptors[0..self.stream_count], self.streams[0..self.stream_count]) |descriptor, *stream| {
            const start: usize = descriptor.offset;
            stream.* = .{
                .semantic = descriptor.semantic,
                .format = descriptor.format,
                .bytes = self.bytes[start .. start + descriptor.length],
            };
        }
        const submesh_bytes = self.bytes[self.submesh_offset .. self.submesh_offset + self.submesh_count * submesh_entry_size];
        return .{
            .vertex_count = self.vertex_count,
            .streams = self.streams[0..self.stream_count],
            .index_format = self.index_format,
            .indices = self.bytes[self.index_offset .. self.index_offset + self.index_length],
            .submeshes = std.mem.bytesAsSlice(Submesh, submesh_bytes),
            .bounds = self.bounds,
            .joint_bounds = self.joint_bounds,
        };
    }
};

/// Reads and validates a canonical `.fmesh`, borrowing all payload bytes from `bytes`.
pub fn read(bytes: []const u8, limits: Limits) ReadError!View {
    const version = versionOf(bytes) orelse return error.NotAMesh;
    if (version != 1 and version != format_version) return error.UnsupportedVersion;
    if (bytes.len > limits.max_file_bytes) return error.OverLimit;
    const head: usize = if (version == 1) header_size else skin_header_size;
    if (bytes.len < head) return error.Malformed;
    const joint_count: u16 = if (version == 1) 0 else readInt(u16, bytes, 48);
    if (joint_count > @min(limits.max_joints, 256)) return error.OverLimit;
    if (version == 2 and (joint_count == 0 or readInt(u16, bytes, 50) != 0)) return error.Malformed;

    const vertex_count = readInt(u32, bytes, 8);
    if (vertex_count > limits.max_vertices) return error.OverLimit;
    const index_format = switch (bytes[12]) {
        0 => IndexFormat.uint16,
        1 => IndexFormat.uint32,
        else => return error.Malformed,
    };
    const stream_count = bytes[13];
    if (stream_count == 0 or stream_count > max_streams) return error.Malformed;
    if (readInt(u16, bytes, 14) != 0) return error.Malformed;
    const index_count = readInt(u32, bytes, 16);
    const submesh_count = readInt(u32, bytes, 20);
    if (submesh_count > limits.max_submeshes) return error.OverLimit;

    const stream_table_bytes = checkedMul(stream_count, stream_entry_size) orelse return error.Malformed;
    const submesh_table_bytes = checkedMul(submesh_count, submesh_entry_size) orelse return error.Malformed;
    const submesh_offset = checkedAdd(head, stream_table_bytes) orelse return error.Malformed;
    const payload_offset = checkedAdd(submesh_offset, submesh_table_bytes) orelse return error.Malformed;
    if (payload_offset > bytes.len) return error.Malformed;

    const index_length = checkedMul(index_count, index_format.size()) orelse return error.Malformed;
    const after_indices = checkedAdd(payload_offset, index_length) orelse return error.Malformed;
    // A u16 triangle occupies six bytes. The canonical two zero bytes which align the first
    // stream are structural padding, not an unaccounted payload gap.
    const first_stream_offset = alignForward4(after_indices) orelse return error.Malformed;
    if (first_stream_offset > bytes.len) return error.Malformed;
    for (bytes[after_indices..first_stream_offset]) |byte| if (byte != 0) return error.Malformed;

    var descriptors: [max_streams]View.Descriptor = undefined;
    var expected_offset = first_stream_offset;
    var previous_semantic: ?u8 = null;
    for (0..stream_count) |i| {
        const at = head + i * stream_entry_size;
        const semantic = std.enums.fromInt(Semantic, bytes[at]) orelse return error.Malformed;
        const format = std.enums.fromInt(VertexFormat, bytes[at + 1]) orelse return error.Malformed;
        if (version == 1 and (semantic == .joints or semantic == .weights or format == .uint8x4)) return error.UnsupportedVertexFormat;
        if (readInt(u16, bytes, at + 2) != 0) return error.Malformed;
        if (previous_semantic) |previous| {
            if (@intFromEnum(semantic) <= previous) return error.Malformed;
        }
        previous_semantic = @intFromEnum(semantic);

        const offset = readInt(u32, bytes, at + 4);
        const length = readInt(u32, bytes, at + 8);
        if (offset % 4 != 0 or offset != expected_offset) return error.Malformed;
        expected_offset = checkedAdd(offset, length) orelse return error.Malformed;
        if (expected_offset > bytes.len) return error.Malformed;
        descriptors[i] = .{ .semantic = semantic, .format = format, .offset = offset, .length = length };
    }
    const joint_offset = expected_offset;
    if (version == 2) {
        if (readInt(u32, bytes, 52) != joint_offset) return error.Malformed;
        expected_offset = checkedAdd(joint_offset, @as(usize, joint_count) * 24) orelse return error.Malformed;
    }
    if (expected_offset != bytes.len) return error.Malformed;

    const bounds: Aabb = .{
        .min = .{ .x = readF32(bytes, 24), .y = readF32(bytes, 28), .z = readF32(bytes, 32) },
        .max = .{ .x = readF32(bytes, 36), .y = readF32(bytes, 40), .z = readF32(bytes, 44) },
    };
    var view: View = .{
        .bytes = bytes,
        .vertex_count = vertex_count,
        .index_format = index_format,
        .index_offset = @intCast(payload_offset),
        .index_length = @intCast(index_length),
        .submesh_offset = @intCast(submesh_offset),
        .submesh_count = submesh_count,
        .bounds = bounds,
        .descriptors = descriptors,
        .stream_count = stream_count,
        .joint_bounds = std.mem.bytesAsSlice(Aabb, bytes[joint_offset..]),
    };
    try view.mesh().validate();
    return view;
}

/// Writes the one canonical byte representation of a valid runtime mesh.
pub fn write(gpa: Allocator, source: Mesh) WriteError![]u8 {
    try source.validate();
    if (source.streams.len == 0 or source.streams.len > max_streams or
        source.indices.len / source.index_format.size() > std.math.maxInt(u32) or
        source.submeshes.len > std.math.maxInt(u32))
    {
        return error.TooLarge;
    }

    var streams: [max_streams]Stream = undefined;
    @memcpy(streams[0..source.streams.len], source.streams);
    std.mem.sortUnstable(Stream, streams[0..source.streams.len], {}, struct {
        fn lessThan(_: void, a: Stream, b: Stream) bool {
            return a.semantic.slot() < b.semantic.slot();
        }
    }.lessThan);

    const head: usize = if (source.joint_bounds.len == 0) header_size else skin_header_size;
    const submesh_offset = checkedAdd(head, checkedMul(source.streams.len, stream_entry_size) orelse return error.TooLarge) orelse return error.TooLarge;
    const payload_offset = checkedAdd(submesh_offset, checkedMul(source.submeshes.len, submesh_entry_size) orelse return error.TooLarge) orelse return error.TooLarge;
    const after_indices = checkedAdd(payload_offset, source.indices.len) orelse return error.TooLarge;
    var total = alignForward4(after_indices) orelse return error.TooLarge;
    for (streams[0..source.streams.len]) |stream| total = checkedAdd(total, stream.bytes.len) orelse return error.TooLarge;
    const joint_offset = total;
    total = checkedAdd(total, source.joint_bounds.len * 24) orelse return error.TooLarge;
    if (total > std.math.maxInt(u32)) return error.TooLarge;

    const bytes = try gpa.alloc(u8, total);
    errdefer gpa.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], magic);
    writeInt(u32, bytes, 4, if (source.joint_bounds.len == 0) 1 else format_version);
    if (head == skin_header_size) {
        writeInt(u16, bytes, 48, @intCast(source.joint_bounds.len));
        writeInt(u32, bytes, 52, @intCast(joint_offset));
    }
    writeInt(u32, bytes, 8, source.vertex_count);
    bytes[12] = @intFromEnum(source.index_format);
    bytes[13] = @intCast(source.streams.len);
    writeInt(u32, bytes, 16, @intCast(source.indices.len / source.index_format.size()));
    writeInt(u32, bytes, 20, @intCast(source.submeshes.len));
    writeF32(bytes, 24, source.bounds.min.x);
    writeF32(bytes, 28, source.bounds.min.y);
    writeF32(bytes, 32, source.bounds.min.z);
    writeF32(bytes, 36, source.bounds.max.x);
    writeF32(bytes, 40, source.bounds.max.y);
    writeF32(bytes, 44, source.bounds.max.z);

    var stream_offset = alignForward4(after_indices).?;
    for (streams[0..source.streams.len], 0..) |stream, i| {
        const at = head + i * stream_entry_size;
        bytes[at] = @intFromEnum(stream.semantic);
        bytes[at + 1] = @intFromEnum(stream.format);
        writeInt(u32, bytes, at + 4, @intCast(stream_offset));
        writeInt(u32, bytes, at + 8, @intCast(stream.bytes.len));
        @memcpy(bytes[stream_offset .. stream_offset + stream.bytes.len], stream.bytes);
        stream_offset += stream.bytes.len;
    }
    for (source.submeshes, 0..) |submesh, i| {
        const at = submesh_offset + i * submesh_entry_size;
        writeInt(u32, bytes, at, submesh.first_index);
        writeInt(u32, bytes, at + 4, submesh.index_count);
    }
    @memcpy(bytes[payload_offset .. payload_offset + source.indices.len], source.indices);
    for (source.joint_bounds, 0..) |box, i| {
        const at = joint_offset + i * 24;
        writeF32(bytes, at, box.min.x);
        writeF32(bytes, at + 4, box.min.y);
        writeF32(bytes, at + 8, box.min.z);
        writeF32(bytes, at + 12, box.max.x);
        writeF32(bytes, at + 16, box.max.y);
        writeF32(bytes, at + 20, box.max.z);
    }
    return bytes;
}

fn checkedAdd(a: anytype, b: anytype) ?usize {
    const result, const overflow = @addWithOverflow(@as(usize, @intCast(a)), @as(usize, @intCast(b)));
    return if (overflow == 0) result else null;
}

fn checkedMul(a: anytype, b: anytype) ?usize {
    const result, const overflow = @mulWithOverflow(@as(usize, @intCast(a)), @as(usize, @intCast(b)));
    return if (overflow == 0) result else null;
}

fn alignForward4(value: usize) ?usize {
    const plus = checkedAdd(value, 3) orelse return null;
    return plus & ~@as(usize, 3);
}

fn readInt(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}

fn readF32(bytes: []const u8, at: usize) f32 {
    return @bitCast(readInt(u32, bytes, at));
}

fn writeF32(bytes: []u8, at: usize, value: f32) void {
    writeInt(u32, bytes, at, @bitCast(value));
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const Vec3 = @import("core").math.Vec3;

const Fixture = struct {
    positions: [3]Vec3 = .{ .{ .x = -1 }, .{ .x = 1 }, .{ .y = 1 } },
    uvs: [3][2]f32 = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } },
    indices: [3]u16 = .{ 0, 1, 2 },
    submeshes: [1]Submesh = .{.{ .first_index = 0, .index_count = 3 }},
    streams: [2]Stream = undefined,

    fn mesh(self: *Fixture) Mesh {
        // Deliberately non-canonical order: the writer must sort it.
        self.streams = .{
            .{ .semantic = .uv0, .format = .float32x2, .bytes = std.mem.sliceAsBytes(&self.uvs) },
            .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&self.positions) },
        };
        return .{
            .vertex_count = 3,
            .streams = &self.streams,
            .index_format = .uint16,
            .indices = std.mem.sliceAsBytes(&self.indices),
            .submeshes = &self.submeshes,
            .bounds = Mesh.computeBounds(&self.positions) catch unreachable,
        };
    }
};

test "fmesh write-read-write is byte identical and its view borrows the file" {
    var fixture: Fixture = .{};
    const first = try write(testing.allocator, fixture.mesh());
    defer testing.allocator.free(first);
    var view = try read(first, .default);
    const decoded = view.mesh();
    try decoded.validate();
    try testing.expectEqual(Semantic.position, decoded.streams[0].semantic);
    try testing.expectEqual(Semantic.uv0, decoded.streams[1].semantic);
    try testing.expect(decoded.indices.ptr == first.ptr + view.index_offset);
    const second = try write(testing.allocator, decoded);
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);
}

test "fmesh distinguishes identity, version, malformed shape, and limits" {
    try testing.expectError(error.NotAMesh, read("no", .default));
    try testing.expectError(error.NotAMesh, read("NOPE\x01\x00\x00\x00", .default));
    var fixture: Fixture = .{};
    const valid = try write(testing.allocator, fixture.mesh());
    defer testing.allocator.free(valid);

    var changed = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(changed);
    writeInt(u32, changed, 4, 3);
    try testing.expectError(error.UnsupportedVersion, read(changed, .default));
    writeInt(u32, changed, 4, 1);
    try testing.expectError(error.OverLimit, read(changed, .{ .max_file_bytes = changed.len - 1 }));
    try testing.expectError(error.OverLimit, read(changed, .{ .max_vertices = 2 }));
    try testing.expectError(error.OverLimit, read(changed, .{ .max_submeshes = 0 }));
    try testing.expectError(error.Malformed, read(changed[0 .. header_size - 1], .default));
}

test "fmesh refuses noncanonical header and table shapes" {
    var fixture: Fixture = .{};
    const valid = try write(testing.allocator, fixture.mesh());
    defer testing.allocator.free(valid);

    const Mutant = struct { at: usize, value: u8 };
    const mutants = [_]Mutant{
        .{ .at = 12, .value = 9 }, // index enum
        .{ .at = 13, .value = 0 }, // stream count
        .{ .at = 14, .value = 1 }, // header reserved
        .{ .at = header_size, .value = 9 }, // semantic enum
        .{ .at = header_size + 1, .value = 9 }, // format enum
        .{ .at = header_size + 2, .value = 1 }, // stream reserved
        .{ .at = header_size + stream_entry_size, .value = 0 }, // non-increasing semantics
    };
    for (mutants) |mutant| {
        const bytes = try testing.allocator.dupe(u8, valid);
        defer testing.allocator.free(bytes);
        bytes[mutant.at] = mutant.value;
        try testing.expectError(error.Malformed, read(bytes, .default));
    }
}

test "fmesh refuses offsets, padding, truncation, and trailing bytes" {
    var fixture: Fixture = .{};
    const valid = try write(testing.allocator, fixture.mesh());
    defer testing.allocator.free(valid);

    const first_offset_at = header_size + 4;
    const offset = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(offset);
    writeInt(u32, offset, first_offset_at, readInt(u32, offset, first_offset_at) + 4);
    try testing.expectError(error.Malformed, read(offset, .default));

    var padding = try testing.allocator.dupe(u8, valid);
    defer testing.allocator.free(padding);
    const tables_end = header_size + 2 * stream_entry_size + submesh_entry_size;
    // The padding follows the index *bytes*: three u16s end two bytes short of alignment.
    padding[tables_end + std.mem.sliceAsBytes(&fixture.indices).len] = 1;
    try testing.expectError(error.Malformed, read(padding, .default));

    try testing.expectError(error.Malformed, read(valid[0 .. valid.len - 1], .default));
    const trailing = try std.mem.concat(testing.allocator, u8, &.{ valid, &.{0} });
    defer testing.allocator.free(trailing);
    try testing.expectError(error.Malformed, read(trailing, .default));
}
