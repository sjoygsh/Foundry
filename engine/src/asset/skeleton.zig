//! FSKL v1: 16-byte header; 108 bytes per joint (parent/reserved/TRS/inverse bind);
//! root matrix; 8-byte name entries (offset/length into consecutive UTF-8 name bytes).
//! Readers borrow arbitrary-alignment bytes; loaders own aligned arrays, not an anim value.
const std = @import("std");
const core = @import("core");
const bin = @import("animation_binary.zig");
const registry = @import("registry.zig");
const schemas = @import("schemas.zig");
const Allocator = std.mem.Allocator;
const Transform = core.math.Transform;
const Mat4 = core.math.Mat4;
pub const magic = "FSKL";
pub const format_version: u32 = 1;
pub const header_size: usize = 16;
pub const joint_size: usize = 108;
pub const no_parent: u16 = 0xffff;
pub const Limits = struct {
    max_file_bytes: usize = 1024 * 1024,
    max_joints: u32 = 256,
    max_name_bytes: u32 = 65_536,
    pub const default: Limits = .{};
};
pub const ReadError = error{ NotASkeleton, UnsupportedVersion, Malformed, OverLimit, NoJoints, ParentOutOfOrder, InvalidRest, InvalidInverseBind, InvalidRoot, InvalidName };
pub const WriteError = ReadError || error{LengthMismatch} || Allocator.Error;
pub fn versionOf(b: []const u8) ?u32 {
    return bin.version(b, magic);
}

pub const View = struct {
    bytes: []const u8,
    joint_count: u32,
    root: Mat4,
    pub fn parent(v: View, joint: usize) u16 {
        return bin.int(u16, v.bytes, header_size + joint * joint_size);
    }
    pub fn rest(v: View, joint: usize) Transform {
        const at = header_size + joint * joint_size + 4;
        return .{
            .translation = .init(bin.float(v.bytes, at), bin.float(v.bytes, at + 4), bin.float(v.bytes, at + 8)),
            .rotation = .{ .x = bin.float(v.bytes, at + 12), .y = bin.float(v.bytes, at + 16), .z = bin.float(v.bytes, at + 20), .w = bin.float(v.bytes, at + 24) },
            .scale = .init(bin.float(v.bytes, at + 28), bin.float(v.bytes, at + 32), bin.float(v.bytes, at + 36)),
        };
    }
    pub fn inverseBind(v: View, joint: usize) Mat4 {
        return bin.matrix(v.bytes, header_size + joint * joint_size + 44);
    }
    pub fn name(v: View, joint: usize) []const u8 {
        const table = header_size + @as(usize, v.joint_count) * joint_size + 64;
        const at = table + joint * 8;
        const offset = bin.int(u32, v.bytes, at);
        const length = bin.int(u32, v.bytes, at + 4);
        const start = table + @as(usize, v.joint_count) * 8 + offset;
        return v.bytes[start .. start + length];
    }
    pub fn copy(v: View, gpa: Allocator) Allocator.Error!Skeleton {
        const parents = try gpa.alloc(u16, v.joint_count);
        errdefer gpa.free(parents);
        const rest_values = try gpa.alloc(Transform, v.joint_count);
        errdefer gpa.free(rest_values);
        const inverse_bind = try gpa.alloc(Mat4, v.joint_count);
        errdefer gpa.free(inverse_bind);
        const names = try gpa.alloc([]const u8, v.joint_count);
        errdefer gpa.free(names);
        const table = header_size + @as(usize, v.joint_count) * joint_size + 64;
        const name_bytes = try gpa.dupe(u8, v.bytes[table + @as(usize, v.joint_count) * 8 ..]);
        for (0..v.joint_count) |j| {
            parents[j] = v.parent(j);
            rest_values[j] = v.rest(j);
            inverse_bind[j] = v.inverseBind(j);
            const offset = bin.int(u32, v.bytes, table + j * 8);
            names[j] = name_bytes[offset .. offset + v.name(j).len];
        }
        return .{ .parents = parents, .rest = rest_values, .inverse_bind = inverse_bind, .root = v.root, .names = names, .name_bytes = name_bytes };
    }
};
pub const Skeleton = struct {
    parents: []u16,
    rest: []Transform,
    inverse_bind: []Mat4,
    root: Mat4,
    names: [][]const u8,
    name_bytes: []u8,
    pub fn deinit(s: *Skeleton, gpa: Allocator) void {
        gpa.free(s.parents);
        gpa.free(s.rest);
        gpa.free(s.inverse_bind);
        gpa.free(s.names);
        gpa.free(s.name_bytes);
    }
};

pub fn read(bytes: []const u8, limits: Limits) ReadError!View {
    const version = versionOf(bytes) orelse return error.NotASkeleton;
    if (version != format_version) return error.UnsupportedVersion;
    if (bytes.len > @min(limits.max_file_bytes, Limits.default.max_file_bytes)) return error.OverLimit;
    if (bytes.len < header_size) return error.Malformed;
    const count = bin.int(u32, bytes, 8);
    const names = bin.int(u32, bytes, 12);
    if (count > @min(limits.max_joints, 256) or names > @min(limits.max_name_bytes, Limits.default.max_name_bytes)) return error.OverLimit;
    if (count == 0) return error.NoJoints;
    const root_at = header_size + @as(usize, count) * joint_size;
    const table = root_at + 64;
    if (table + @as(usize, count) * 8 + names != bytes.len) return error.Malformed;
    const view: View = .{ .bytes = bytes, .joint_count = count, .root = bin.matrix(bytes, root_at) };
    if (!bin.affine(view.root)) return error.InvalidRoot;
    var name_offset: u64 = 0;
    for (0..count) |j| {
        if (bin.int(u16, bytes, header_size + j * joint_size + 2) != 0) return error.Malformed;
        const parent = view.parent(j);
        if (parent != no_parent and parent >= j) return error.ParentOutOfOrder;
        if (!view.rest(j).isValid()) return error.InvalidRest;
        if (!bin.affine(view.inverseBind(j))) return error.InvalidInverseBind;
        const offset = bin.int(u32, bytes, table + j * 8);
        const length = bin.int(u32, bytes, table + j * 8 + 4);
        if (offset != name_offset or name_offset + length > names) return error.Malformed;
        name_offset += length;
        const name = view.name(j);
        if (!std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
    }
    if (name_offset != names) return error.Malformed;
    return view;
}
pub const Source = struct {
    parents: []const u16,
    rest: []const Transform,
    inverse_bind: []const Mat4,
    root: Mat4 = .identity,
    names: []const []const u8,
};
pub fn write(gpa: Allocator, source: Source) WriteError![]u8 {
    const count = source.parents.len;
    if (count > 256) return error.OverLimit;
    if (count == 0) return error.NoJoints;
    if (source.rest.len != count or source.inverse_bind.len != count or source.names.len != count) return error.LengthMismatch;
    var name_size: usize = 0;
    for (source.names) |name| {
        if (name.len > Limits.default.max_name_bytes - name_size) return error.OverLimit;
        name_size += name.len;
    }
    const root_at = header_size + count * joint_size;
    const table = root_at + 64;
    const start = table + count * 8;
    const b = try gpa.alloc(u8, start + name_size);
    errdefer gpa.free(b);
    @memset(b, 0);
    @memcpy(b[0..4], magic);
    bin.put(u32, b, 4, format_version);
    bin.put(u32, b, 8, @intCast(count));
    bin.put(u32, b, 12, @intCast(name_size));
    var offset: usize = 0;
    for (source.parents, source.rest, source.inverse_bind, source.names, 0..) |parent, rest, inverse, name, j| {
        const at = header_size + j * joint_size;
        bin.put(u16, b, at, parent);
        const values = [_]f32{ rest.translation.x, rest.translation.y, rest.translation.z, rest.rotation.x, rest.rotation.y, rest.rotation.z, rest.rotation.w, rest.scale.x, rest.scale.y, rest.scale.z };
        for (values, 0..) |f, i| bin.putFloat(b, at + 4 + i * 4, f);
        bin.putMatrix(b, at + 44, inverse);
        bin.put(u32, b, table + j * 8, @intCast(offset));
        bin.put(u32, b, table + j * 8 + 4, @intCast(name.len));
        @memcpy(b[start + offset ..][0..name.len], name);
        offset += name.len;
    }
    bin.putMatrix(b, root_at, source.root);
    _ = try read(b, .default);
    return b;
}
pub fn skeletonLoader() registry.Loader {
    return .{ .schema = schemas.skeleton.id, .max_source_bytes = Limits.default.max_file_bytes, .load = load, .unload = unload };
}
fn load(_: ?*anyopaque, gpa: Allocator, _: @import("data").store.Record, bytes: []const u8) registry.LoadError!registry.Payload {
    const view = read(bytes, .default) catch |err| return if (err == error.UnsupportedVersion) error.UnsupportedVersion else error.InvalidAsset;
    const owned = try gpa.create(Skeleton);
    errdefer gpa.destroy(owned);
    owned.* = try view.copy(gpa);
    return .fromPointer(owned);
}
fn unload(_: ?*anyopaque, gpa: Allocator, payload: registry.Payload) void {
    const owned: *Skeleton = @ptrCast(@alignCast(payload.pointer().?));
    owned.deinit(gpa);
    gpa.destroy(owned);
}
pub fn fromPayload(payload: registry.Payload) *const Skeleton {
    return @ptrCast(@alignCast(payload.pointer().?));
}
