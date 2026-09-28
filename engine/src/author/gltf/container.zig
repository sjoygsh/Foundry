//! glTF containers: JSON `.gltf` and the two-chunk `.glb` form.

const std = @import("std");

pub const glb_magic: u32 = 0x46546c67;
pub const glb_version: u32 = 2;
pub const json_chunk: u32 = 0x4e4f534a;
pub const bin_chunk: u32 = 0x004e4942;

pub const Limits = struct {
    max_file_bytes: usize = 256 * 1024 * 1024,
    max_json_bytes: usize = 16 * 1024 * 1024,

    pub const default: Limits = .{};
};

pub const Error = error{
    InvalidContainer,
    UnsupportedVersion,
    OverLimit,
};

pub const View = struct {
    json: []const u8,
    bin: ?[]const u8 = null,
};

pub fn open(bytes: []const u8, is_glb: bool, limits: Limits) Error!View {
    if (bytes.len > limits.max_file_bytes) return error.OverLimit;
    if (!is_glb) {
        if (bytes.len > limits.max_json_bytes) return error.OverLimit;
        return .{ .json = bytes };
    }
    if (bytes.len < 20) return error.InvalidContainer;
    if (readInt(u32, bytes, 0) != glb_magic) return error.InvalidContainer;
    if (readInt(u32, bytes, 4) != glb_version) return error.UnsupportedVersion;
    if (readInt(u32, bytes, 8) != bytes.len) return error.InvalidContainer;

    var at: usize = 12;
    const json_len: usize = readInt(u32, bytes, at);
    const first_kind = readInt(u32, bytes, at + 4);
    at += 8;
    if (first_kind != json_chunk or json_len % 4 != 0 or json_len > limits.max_json_bytes or
        at +| json_len > bytes.len)
    {
        return if (json_len > limits.max_json_bytes) error.OverLimit else error.InvalidContainer;
    }
    const json = std.mem.trimEnd(u8, bytes[at .. at + json_len], " \t\r\n");
    at += json_len;
    var bin: ?[]const u8 = null;
    if (at < bytes.len) {
        if (bytes.len - at < 8) return error.InvalidContainer;
        const len: usize = readInt(u32, bytes, at);
        const kind = readInt(u32, bytes, at + 4);
        at += 8;
        if (kind != bin_chunk or len % 4 != 0 or at +| len != bytes.len) return error.InvalidContainer;
        bin = bytes[at .. at + len];
    }
    return .{ .json = json, .bin = bin };
}

fn readInt(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

test "GLB has one leading JSON chunk and at most one BIN chunk" {
    const testing = std.testing;
    const json = "{\"asset\":{\"version\":\"2.0\"}}     ";
    var bytes: [12 + 8 + json.len + 8 + 4]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], glb_magic, .little);
    std.mem.writeInt(u32, bytes[4..8], glb_version, .little);
    std.mem.writeInt(u32, bytes[8..12], bytes.len, .little);
    std.mem.writeInt(u32, bytes[12..16], json.len, .little);
    std.mem.writeInt(u32, bytes[16..20], json_chunk, .little);
    @memcpy(bytes[20 .. 20 + json.len], json);
    const second = 20 + json.len;
    std.mem.writeInt(u32, bytes[second..][0..4], 4, .little);
    std.mem.writeInt(u32, bytes[second + 4 ..][0..4], bin_chunk, .little);
    const view = try open(&bytes, true, .default);
    try testing.expectEqualStrings("{\"asset\":{\"version\":\"2.0\"}}", view.json);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, view.bin.?);

    bytes[16] = 0;
    try testing.expectError(error.InvalidContainer, open(&bytes, true, .default));
}
