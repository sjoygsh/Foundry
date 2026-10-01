//! Private primitives for canonical little-endian animation assets. No anim dependency.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("animation asset views require little endian");
}
pub fn int(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}
pub fn put(comptime T: type, b: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, b[at..][0..@sizeOf(T)], value, .little);
}
pub fn float(b: []const u8, at: usize) f32 {
    return @bitCast(int(u32, b, at));
}
pub fn putFloat(b: []u8, at: usize, value: f32) void {
    put(u32, b, at, @bitCast(value));
}
pub fn matrix(b: []const u8, at: usize) core.math.Mat4 {
    var m: core.math.Mat4 = undefined;
    for (0..4) |c| for (0..4) |r| {
        m.cols[c][r] = float(b, at + (c * 4 + r) * 4);
    };
    return m;
}
pub fn putMatrix(b: []u8, at: usize, m: core.math.Mat4) void {
    for (0..4) |c| for (0..4) |r| {
        putFloat(b, at + (c * 4 + r) * 4, m.cols[c][r]);
    };
}
pub fn affine(m: core.math.Mat4) bool {
    for (m.cols) |c| for (c) |f| {
        if (!std.math.isFinite(f)) return false;
    };
    return m.cols[0][3] == 0 and m.cols[1][3] == 0 and m.cols[2][3] == 0 and m.cols[3][3] == 1;
}
pub fn version(b: []const u8, magic: []const u8) ?u32 {
    if (b.len < 8 or !std.mem.eql(u8, b[0..4], magic)) return null;
    return int(u32, b, 4);
}
