//! Typed, range-checked access to glTF buffer data.

const std = @import("std");
const document = @import("document.zig");

pub const Error = error{
    MissingBufferView,
    IndexOutOfRange,
    SparseUnsupported,
    UnsupportedComponent,
    UnsupportedType,
    InvalidRange,
    InvalidStride,
    InvalidAlignment,
    CountTooLarge,
};

pub const Component = enum(u32) {
    i8 = 5120,
    u8 = 5121,
    i16 = 5122,
    u16 = 5123,
    u32 = 5125,
    f32 = 5126,

    pub fn size(self: Component) u32 {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .u32, .f32 => 4,
        };
    }
};

pub const Shape = enum {
    scalar,
    vec2,
    vec3,
    vec4,
    mat2,
    mat3,
    mat4,

    pub fn components(self: Shape) u32 {
        return switch (self) {
            .scalar => 1,
            .vec2 => 2,
            .vec3 => 3,
            .vec4, .mat2 => 4,
            .mat3 => 9,
            .mat4 => 16,
        };
    }
};

pub const View = struct {
    bytes: []const u8,
    offset: usize,
    stride: usize,
    count: u32,
    component: Component,
    shape: Shape,
    normalized: bool,

    pub fn components(self: View) u32 {
        return self.shape.components();
    }

    pub fn unsigned(self: View, element: u32, lane: u32) Error!u32 {
        const at = try self.location(element, lane);
        return switch (self.component) {
            .u8 => self.bytes[at],
            .u16 => std.mem.readInt(u16, self.bytes[at..][0..2], .little),
            .u32 => std.mem.readInt(u32, self.bytes[at..][0..4], .little),
            else => error.UnsupportedComponent,
        };
    }

    pub fn float(self: View, element: u32, lane: u32) Error!f32 {
        const at = try self.location(element, lane);
        return switch (self.component) {
            .f32 => @bitCast(std.mem.readInt(u32, self.bytes[at..][0..4], .little)),
            .u8 => if (self.normalized) @as(f32, @floatFromInt(self.bytes[at])) / 255.0 else error.UnsupportedComponent,
            .u16 => if (self.normalized)
                @as(f32, @floatFromInt(std.mem.readInt(u16, self.bytes[at..][0..2], .little))) / 65_535.0
            else
                error.UnsupportedComponent,
            .i8 => if (self.normalized)
                @max(-1.0, @as(f32, @floatFromInt(@as(i8, @bitCast(self.bytes[at])))) / 127.0)
            else
                error.UnsupportedComponent,
            .i16 => if (self.normalized)
                @max(-1.0, @as(f32, @floatFromInt(@as(i16, @bitCast(std.mem.readInt(u16, self.bytes[at..][0..2], .little))))) / 32_767.0)
            else
                error.UnsupportedComponent,
            .u32 => error.UnsupportedComponent,
        };
    }

    fn location(self: View, element: u32, lane: u32) Error!usize {
        if (element >= self.count or lane >= self.shape.components()) return error.IndexOutOfRange;
        return self.offset + @as(usize, element) * self.stride + @as(usize, lane) * self.component.size();
    }
};

pub fn open(doc: *const document.Document, buffers: []const []const u8, index: u32) Error!View {
    if (index >= doc.accessors.len) return error.IndexOutOfRange;
    const value = doc.accessors[index];
    if (value.sparse != null) return error.SparseUnsupported;
    const view_index = value.bufferView orelse return error.MissingBufferView;
    if (view_index >= doc.bufferViews.len) return error.IndexOutOfRange;
    const buffer_view = doc.bufferViews[view_index];
    if (buffer_view.buffer >= buffers.len) return error.IndexOutOfRange;
    const bytes = buffers[buffer_view.buffer];
    const component = std.enums.fromInt(Component, value.componentType) orelse return error.UnsupportedComponent;
    const shape = parseShape(value.type) orelse return error.UnsupportedType;
    if (value.count > std.math.maxInt(u32)) return error.CountTooLarge;

    const element_size = std.math.mul(u64, component.size(), shape.components()) catch return error.InvalidRange;
    const stride: u64 = buffer_view.byteStride orelse element_size;
    if (stride < element_size or stride > 252 or stride % component.size() != 0) return error.InvalidStride;
    const start = std.math.add(u64, buffer_view.byteOffset, value.byteOffset) catch return error.InvalidRange;
    if (start % component.size() != 0 or value.byteOffset % component.size() != 0) return error.InvalidAlignment;
    const view_end = std.math.add(u64, buffer_view.byteOffset, buffer_view.byteLength) catch return error.InvalidRange;
    if (view_end > bytes.len or start > view_end) return error.InvalidRange;
    const occupied = if (value.count == 0) 0 else blk: {
        const skipped = std.math.mul(u64, value.count - 1, stride) catch return error.InvalidRange;
        break :blk std.math.add(u64, skipped, element_size) catch return error.InvalidRange;
    };
    const end = std.math.add(u64, start, occupied) catch return error.InvalidRange;
    if (end > view_end) return error.InvalidRange;

    return .{
        .bytes = bytes,
        .offset = @intCast(start),
        .stride = @intCast(stride),
        .count = @intCast(value.count),
        .component = component,
        .shape = shape,
        .normalized = value.normalized,
    };
}

fn parseShape(text: []const u8) ?Shape {
    if (std.mem.eql(u8, text, "SCALAR")) return .scalar;
    if (std.mem.eql(u8, text, "VEC2")) return .vec2;
    if (std.mem.eql(u8, text, "VEC3")) return .vec3;
    if (std.mem.eql(u8, text, "VEC4")) return .vec4;
    if (std.mem.eql(u8, text, "MAT2")) return .mat2;
    if (std.mem.eql(u8, text, "MAT3")) return .mat3;
    if (std.mem.eql(u8, text, "MAT4")) return .mat4;
    return null;
}

test "an accessor is bounded by its view, stride and alignment" {
    const testing = std.testing;
    const doc: document.Document = .{
        .asset = .{ .version = "2.0" },
        .buffers = &.{.{ .byteLength = 32 }},
        .bufferViews = &.{.{ .buffer = 0, .byteOffset = 4, .byteLength = 24, .byteStride = 12 }},
        .accessors = &.{.{ .bufferView = 0, .componentType = 5126, .count = 2, .type = "VEC3" }},
    };
    const bytes = [_]u8{0} ** 32;
    const view = try open(&doc, &.{&bytes}, 0);
    try testing.expectEqual(@as(u32, 2), view.count);

    var bad = doc;
    bad.accessors = &.{.{ .bufferView = 0, .byteOffset = 2, .componentType = 5126, .count = 1, .type = "VEC3" }};
    try testing.expectError(error.InvalidAlignment, open(&bad, &.{&bytes}, 0));
}

test "normalized integers widen by glTF's exact conversion" {
    const testing = std.testing;
    const bytes = [_]u8{ 0, 255, 0, 0, 255, 255 };
    const doc: document.Document = .{
        .asset = .{ .version = "2.0" },
        .buffers = &.{.{ .byteLength = bytes.len }},
        .bufferViews = &.{
            .{ .buffer = 0, .byteOffset = 0, .byteLength = 2 },
            .{ .buffer = 0, .byteOffset = 2, .byteLength = 4 },
        },
        .accessors = &.{
            .{ .bufferView = 0, .componentType = 5121, .normalized = true, .count = 1, .type = "VEC2" },
            .{ .bufferView = 1, .componentType = 5123, .normalized = true, .count = 1, .type = "VEC2" },
        },
    };
    const u8s = try open(&doc, &.{&bytes}, 0);
    try testing.expectEqual(@as(f32, 0), try u8s.float(0, 0));
    try testing.expectEqual(@as(f32, 1), try u8s.float(0, 1));
    const u16s = try open(&doc, &.{&bytes}, 1);
    try testing.expectEqual(@as(f32, 0), try u16s.float(0, 0));
    try testing.expectEqual(@as(f32, 1), try u16s.float(0, 1));
}
