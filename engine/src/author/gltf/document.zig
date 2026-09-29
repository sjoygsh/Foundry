//! The bounded typed view of glTF 2.0 JSON.
//!
//! glTF is an authoring input, never a runtime representation (ADR-0053). Keeping the
//! standard-library JSON dependency in this file makes that boundary visible and gives a
//! future `std.json` change one place to touch.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_json_bytes: usize = 16 * 1024 * 1024,
    max_json_depth: u32 = 64,
    max_nodes: usize = 65_536,
    max_node_depth: u32 = 64,
    max_meshes: usize = 4_096,
    max_primitives: usize = 65_536,
    max_accessors: usize = 65_536,
    max_images: usize = 1_024,

    pub const default: Limits = .{};
};

pub const Error = error{
    InvalidJson,
    OverLimit,
} || Allocator.Error;

pub const Asset = struct {
    version: []const u8,
    minVersion: ?[]const u8 = null,
};

pub const Buffer = struct {
    uri: ?[]const u8 = null,
    byteLength: u64,
};

pub const BufferView = struct {
    buffer: u32,
    byteOffset: u64 = 0,
    byteLength: u64,
    byteStride: ?u32 = null,
};

pub const Accessor = struct {
    bufferView: ?u32 = null,
    byteOffset: u64 = 0,
    componentType: u32,
    normalized: bool = false,
    count: u64,
    type: []const u8,
    sparse: ?std.json.Value = null,
};

pub const Primitive = struct {
    attributes: std.json.ArrayHashMap(u32),
    indices: ?u32 = null,
    material: ?u32 = null,
    mode: u32 = 4,
    targets: ?[]const std.json.Value = null,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const Mesh = struct {
    name: ?[]const u8 = null,
    primitives: []const Primitive,
};

pub const Node = struct {
    name: ?[]const u8 = null,
    camera: ?u32 = null,
    children: []const u32 = &.{},
    skin: ?u32 = null,
    mesh: ?u32 = null,
    matrix: ?[16]f32 = null,
    translation: ?[3]f32 = null,
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const Scene = struct {
    name: ?[]const u8 = null,
    nodes: []const u32 = &.{},
};

pub const TextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const NormalTextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    scale: f32 = 1,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const OcclusionTextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    strength: f32 = 1,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const PbrMetallicRoughness = struct {
    baseColorFactor: [4]f32 = .{ 1, 1, 1, 1 },
    baseColorTexture: ?TextureInfo = null,
    metallicFactor: ?f32 = null,
    roughnessFactor: ?f32 = null,
    metallicRoughnessTexture: ?TextureInfo = null,
};

pub const Material = struct {
    name: ?[]const u8 = null,
    pbrMetallicRoughness: PbrMetallicRoughness = .{},
    normalTexture: ?NormalTextureInfo = null,
    occlusionTexture: ?OcclusionTextureInfo = null,
    emissiveTexture: ?TextureInfo = null,
    emissiveFactor: ?[3]f32 = null,
    alphaMode: []const u8 = "OPAQUE",
    alphaCutoff: f32 = 0.5,
    doubleSided: bool = false,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const Texture = struct {
    sampler: ?u32 = null,
    source: ?u32 = null,
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const Image = struct {
    name: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    bufferView: ?u32 = null,
};

pub const Sampler = struct {
    magFilter: ?u32 = null,
    minFilter: ?u32 = null,
    wrapS: u32 = 10_497,
    wrapT: u32 = 10_497,
};

pub const Document = struct {
    asset: Asset,
    scene: ?u32 = null,
    scenes: []const Scene = &.{},
    nodes: []const Node = &.{},
    meshes: []const Mesh = &.{},
    accessors: []const Accessor = &.{},
    bufferViews: []const BufferView = &.{},
    buffers: []const Buffer = &.{},
    materials: []const Material = &.{},
    textures: []const Texture = &.{},
    images: []const Image = &.{},
    samplers: []const Sampler = &.{},
    cameras: ?[]const std.json.Value = null,
    animations: ?[]const std.json.Value = null,
    skins: ?[]const std.json.Value = null,
    extensionsUsed: []const []const u8 = &.{},
    extensionsRequired: []const []const u8 = &.{},
    extensions: ?std.json.ArrayHashMap(std.json.Value) = null,
};

pub const Parsed = struct {
    value: Document,
};

/// Parses into the caller's arena. The explicit token pass supplies the nesting bound that
/// `std.json` deliberately leaves to its caller.
pub fn parse(arena: Allocator, bytes: []const u8, limits: Limits) Error!Parsed {
    if (bytes.len > limits.max_json_bytes) return error.OverLimit;
    try checkDepth(arena, bytes, limits.max_json_depth);
    const value = std.json.parseFromSliceLeaky(Document, arena, bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
        .allocate = .alloc_if_needed,
        .max_value_len = limits.max_json_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    try checkLimits(value, limits);
    return .{ .value = value };
}

fn checkDepth(allocator: Allocator, bytes: []const u8, max_depth: u32) Error!void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    var depth: u32 = 0;
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        switch (token) {
            .object_begin, .array_begin => {
                if (depth >= max_depth) return error.OverLimit;
                depth += 1;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            .end_of_document => break,
            else => {},
        }
    }
    if (depth != 0) return error.InvalidJson;
}

fn checkLimits(doc: Document, limits: Limits) Error!void {
    if (doc.nodes.len > limits.max_nodes or doc.meshes.len > limits.max_meshes or
        doc.accessors.len > limits.max_accessors or doc.images.len > limits.max_images)
    {
        return error.OverLimit;
    }
    var primitives: usize = 0;
    for (doc.meshes) |mesh| {
        primitives = std.math.add(usize, primitives, mesh.primitives.len) catch return error.OverLimit;
        if (primitives > limits.max_primitives) return error.OverLimit;
    }
}

test "JSON nesting and document counts are bounded before translation" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ok = try parse(arena.allocator(),
        \\{"asset":{"version":"2.0"},"scenes":[{"nodes":[]}]}
    , .default);
    try testing.expectEqualStrings("2.0", ok.value.asset.version);

    try testing.expectError(error.OverLimit, parse(arena.allocator(),
        \\{"asset":{"version":"2.0"},"scenes":[{"nodes":[]}]}
    , .{ .max_json_depth = 2 }));
    try testing.expectError(error.OverLimit, parse(arena.allocator(),
        \\{"asset":{"version":"2.0"},"nodes":[{},{}]}
    , .{ .max_nodes = 1 }));
}
