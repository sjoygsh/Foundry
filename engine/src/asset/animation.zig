//! FANM v1: 20-byte header (magic/version/duration/joint count/track count),
//! 16-byte descriptors (joint/path/interpolation/key count/time offset/value offset),
//! then each track's tightly packed f32 times and values, in descriptor order.
//! Borrowed views permit unaligned input. The loader copies into aligned owned arrays.
const std = @import("std");
const core = @import("core");
const bin = @import("animation_binary.zig");
const registry = @import("registry.zig");
const schemas = @import("schemas.zig");
const Allocator = std.mem.Allocator;
pub const magic = "FANM";
pub const format_version: u32 = 1;
pub const header_size: usize = 20;
pub const track_size: usize = 16;
pub const Path = enum(u8) {
    translation = 0,
    rotation = 1,
    scale = 2,
    pub fn width(p: Path) usize {
        return if (p == .rotation) 4 else 3;
    }
};
pub const Interpolation = enum(u8) { step = 0, linear = 1 };
pub const Limits = struct {
    max_file_bytes: usize = 256 * 1024 * 1024,
    max_joints: u32 = 256,
    max_tracks: u32 = 768,
    max_keys_per_track: u32 = 65_536,
    max_total_keys: u32 = 8_388_608,
    pub const default: Limits = .{};
};
pub const ReadError = error{ NotAnAnimation, UnsupportedVersion, Malformed, OverLimit, InvalidDuration, InvalidJointCount, UnknownJoint, DuplicateTrack, EmptyTrack, InvalidTime, UnsortedTimes, InvalidValue, InvalidRotation };
pub const WriteError = ReadError || error{ValueCountMismatch} || Allocator.Error;
pub fn versionOf(b: []const u8) ?u32 {
    return bin.version(b, magic);
}
pub const TrackView = struct {
    joint: u16,
    path: Path,
    interpolation: Interpolation,
    times: []align(1) const f32,
    values: []align(1) const f32,
};
pub const View = struct {
    bytes: []const u8,
    duration: f32,
    joint_count: u32,
    track_count: u32,
    pub fn track(v: View, index: usize) TrackView {
        const at = header_size + index * track_size;
        const path: Path = @enumFromInt(v.bytes[at + 2]);
        const count = bin.int(u32, v.bytes, at + 4);
        const times = bin.int(u32, v.bytes, at + 8);
        const values = bin.int(u32, v.bytes, at + 12);
        return .{ .joint = bin.int(u16, v.bytes, at), .path = path, .interpolation = @enumFromInt(v.bytes[at + 3]), .times = std.mem.bytesAsSlice(f32, v.bytes[times .. times + @as(usize, count) * 4]), .values = std.mem.bytesAsSlice(f32, v.bytes[values .. values + @as(usize, count) * path.width() * 4]) };
    }
    pub fn copy(v: View, gpa: Allocator) Allocator.Error!Animation {
        const tracks = try gpa.alloc(Track, v.track_count);
        errdefer gpa.free(tracks);
        var made: usize = 0;
        errdefer for (tracks[0..made]) |t| {
            gpa.free(t.times);
            gpa.free(t.values);
        };
        for (tracks, 0..) |*t, i| {
            const from = v.track(i);
            const times = try gpa.alloc(f32, from.times.len);
            errdefer gpa.free(times);
            const values = try gpa.alloc(f32, from.values.len);
            for (times, from.times) |*to, f| to.* = f;
            for (values, from.values) |*to, f| to.* = f;
            t.* = .{ .joint = from.joint, .path = from.path, .interpolation = from.interpolation, .times = times, .values = values };
            made += 1;
        }
        return .{ .duration = v.duration, .joint_count = v.joint_count, .tracks = tracks };
    }
};
pub const Track = struct {
    joint: u16,
    path: Path,
    interpolation: Interpolation = .linear,
    times: []const f32,
    values: []const f32,
};
pub const Animation = struct {
    duration: f32,
    joint_count: u32,
    tracks: []Track,
    pub fn deinit(a: *Animation, gpa: Allocator) void {
        for (a.tracks) |t| {
            gpa.free(t.times);
            gpa.free(t.values);
        }
        gpa.free(a.tracks);
    }
    /// Pairing is explicit: either asset may have been overridden independently.
    pub fn checkJointCount(a: Animation, count: usize) error{SkeletonMismatch}!void {
        if (a.joint_count != count) return error.SkeletonMismatch;
    }
};
pub fn read(bytes: []const u8, limits: Limits) ReadError!View {
    const version = versionOf(bytes) orelse return error.NotAnAnimation;
    if (version != format_version) return error.UnsupportedVersion;
    if (bytes.len > @min(limits.max_file_bytes, Limits.default.max_file_bytes)) return error.OverLimit;
    if (bytes.len < header_size) return error.Malformed;
    const duration = bin.float(bytes, 8);
    const joints = bin.int(u32, bytes, 12);
    const count = bin.int(u32, bytes, 16);
    if (!std.math.isFinite(duration) or duration <= 0) return error.InvalidDuration;
    if (joints > @min(limits.max_joints, 256) or count > @min(limits.max_tracks, 768)) return error.OverLimit;
    if (joints == 0) return error.InvalidJointCount;
    var end: u64 = header_size + @as(u64, count) * track_size;
    if (end > bytes.len) return error.Malformed;
    var seen = std.StaticBitSet(768).initEmpty();
    var total_keys: u64 = 0;
    const view: View = .{ .bytes = bytes, .duration = duration, .joint_count = joints, .track_count = count };
    for (0..count) |i| {
        const at = header_size + i * track_size;
        const joint = bin.int(u16, bytes, at);
        const path = std.enums.fromInt(Path, bytes[at + 2]) orelse return error.Malformed;
        _ = std.enums.fromInt(Interpolation, bytes[at + 3]) orelse return error.Malformed;
        if (joint >= joints) return error.UnknownJoint;
        const slot = @as(usize, joint) * 3 + @intFromEnum(path);
        if (seen.isSet(slot)) return error.DuplicateTrack;
        seen.set(slot);
        const keys = bin.int(u32, bytes, at + 4);
        if (keys > @min(limits.max_keys_per_track, Limits.default.max_keys_per_track)) return error.OverLimit;
        if (keys == 0) return error.EmptyTrack;
        total_keys += keys;
        if (total_keys > @min(limits.max_total_keys, Limits.default.max_total_keys)) return error.OverLimit;
        if (bin.int(u32, bytes, at + 8) != end) return error.Malformed;
        end += @as(u64, keys) * 4;
        if (bin.int(u32, bytes, at + 12) != end) return error.Malformed;
        end += @as(u64, keys) * path.width() * 4;
        if (end > bytes.len) return error.Malformed;
        const t = view.track(i);
        var previous: f32 = -1;
        for (t.times) |time| {
            if (!std.math.isFinite(time) or time < 0 or time > duration) return error.InvalidTime;
            if (time <= previous) return error.UnsortedTimes;
            previous = time;
        }
        for (t.values) |value| if (!std.math.isFinite(value)) return error.InvalidValue;
        if (path == .rotation) for (0..keys) |key| {
            const v = t.values[key * 4 ..][0..4];
            const q: core.math.Quat = .{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] };
            if (!q.isUnit()) return error.InvalidRotation;
        };
    }
    if (end != bytes.len) return error.Malformed;
    return view;
}
pub const Source = struct { duration: f32, joint_count: u32, tracks: []const Track };
pub fn write(gpa: Allocator, source: Source) WriteError![]u8 {
    if (source.tracks.len > 768 or source.joint_count > 256) return error.OverLimit;
    var size: u64 = header_size + source.tracks.len * track_size;
    var keys: u64 = 0;
    for (source.tracks) |t| {
        if (t.times.len > Limits.default.max_keys_per_track) return error.OverLimit;
        if (t.values.len != t.times.len * t.path.width()) return error.ValueCountMismatch;
        keys += t.times.len;
        if (keys > Limits.default.max_total_keys) return error.OverLimit;
        size += @as(u64, t.times.len + t.values.len) * 4;
    }
    if (size > Limits.default.max_file_bytes) return error.OverLimit;
    const b = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(b);
    @memcpy(b[0..4], magic);
    bin.put(u32, b, 4, format_version);
    bin.putFloat(b, 8, source.duration);
    bin.put(u32, b, 12, source.joint_count);
    bin.put(u32, b, 16, @intCast(source.tracks.len));
    var offset: usize = header_size + source.tracks.len * track_size;
    for (source.tracks, 0..) |t, i| {
        const at = header_size + i * track_size;
        bin.put(u16, b, at, t.joint);
        b[at + 2] = @intFromEnum(t.path);
        b[at + 3] = @intFromEnum(t.interpolation);
        bin.put(u32, b, at + 4, @intCast(t.times.len));
        bin.put(u32, b, at + 8, @intCast(offset));
        for (t.times) |f| {
            bin.putFloat(b, offset, f);
            offset += 4;
        }
        bin.put(u32, b, at + 12, @intCast(offset));
        for (t.values) |f| {
            bin.putFloat(b, offset, f);
            offset += 4;
        }
    }
    _ = try read(b, .default);
    return b;
}
pub fn animationLoader() registry.Loader {
    return .{ .schema = schemas.animation.id, .max_source_bytes = Limits.default.max_file_bytes, .load = load, .unload = unload };
}
fn load(_: ?*anyopaque, gpa: Allocator, _: @import("data").store.Record, bytes: []const u8) registry.LoadError!registry.Payload {
    const view = read(bytes, .default) catch |err| return if (err == error.UnsupportedVersion) error.UnsupportedVersion else error.InvalidAsset;
    const owned = try gpa.create(Animation);
    errdefer gpa.destroy(owned);
    owned.* = try view.copy(gpa);
    return .fromPointer(owned);
}
fn unload(_: ?*anyopaque, gpa: Allocator, payload: registry.Payload) void {
    const owned: *Animation = @ptrCast(@alignCast(payload.pointer().?));
    owned.deinit(gpa);
    gpa.destroy(owned);
}
pub fn fromPayload(payload: registry.Payload) *const Animation {
    return @ptrCast(@alignCast(payload.pointer().?));
}
