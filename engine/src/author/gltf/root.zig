//! The private glTF importer owned by `author`.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");

pub const accessor = @import("accessor.zig");
pub const container = @import("container.zig");
pub const document = @import("document.zig");
pub const translate = @import("translate.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;

pub const Limits = struct {
    container: container.Limits = .default,
    document: document.Limits = .default,

    pub const default: Limits = .{};
};

pub const ReadError = error{
    InvalidPath,
    OutsidePackage,
    NotFound,
    OverLimit,
} || Allocator.Error;

pub const Resolved = struct {
    path: []const u8,
    bytes: []const u8,
};

/// Resolves a URI relative to the importing glTF. Both returned slices live at least as long
/// as the import. The compiler supplies this over its confined, cached loader.
pub const Reader = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, parent: []const u8, uri: []const u8, max_bytes: usize) ReadError!Resolved,

    pub fn read(self: Reader, parent: []const u8, uri: []const u8, max_bytes: usize) ReadError!Resolved {
        return self.readFn(self.ctx, parent, uri, max_bytes);
    }
};

pub const Error = error{ContentInvalid} || Allocator.Error;

pub fn import(
    gpa: Allocator,
    arena: Allocator,
    source: []const u8,
    bytes: []const u8,
    settings: translate.Settings,
    reader: Reader,
    limits: Limits,
    diags: *Diagnostics,
) Error!translate.Result {
    const extension = extensionOf(source);
    const is_glb = std.mem.eql(u8, extension, "glb");
    if (!is_glb and !std.mem.eql(u8, extension, "gltf")) return fail(gpa, diags, source, "is not a .gltf or .glb file");
    const view = container.open(bytes, is_glb, limits.container) catch |err|
        return failFmt(gpa, diags, source, "container is invalid: {s}", .{@errorName(err)});
    const parsed = document.parse(arena, view.json, limits.document) catch |err|
        return failFmt(gpa, diags, source, "JSON document is invalid or over its limits: {s}", .{@errorName(err)});

    const buffers = try arena.alloc([]const u8, parsed.value.buffers.len);
    for (parsed.value.buffers, 0..) |buffer, i| {
        const resolved = if (buffer.uri) |uri| blk: {
            try validateUri(gpa, diags, source, try std.fmt.allocPrint(arena, "buffers[{d}].uri", .{i}), uri);
            break :blk reader.read(source, uri, limits.container.max_file_bytes) catch |err|
                return failFmt(gpa, diags, source, "buffers[{d}].uri '{s}' could not be read inside the package: {s}", .{ i, uri, @errorName(err) });
        } else blk: {
            if (!is_glb or i != 0 or view.bin == null) return failFmt(gpa, diags, source, "buffers[{d}] has no URI and no matching GLB BIN chunk", .{i});
            break :blk Resolved{ .path = source, .bytes = view.bin.? };
        };
        if (buffer.byteLength > resolved.bytes.len) return failFmt(gpa, diags, source, "buffers[{d}] declares {d} bytes but its source has {d}", .{ i, buffer.byteLength, resolved.bytes.len });
        // A GLB BIN chunk may have at most three padding bytes. External buffers may be
        // larger than their declared logical range; accessors can see only that range.
        if (buffer.uri == null and resolved.bytes.len - @as(usize, @intCast(buffer.byteLength)) > 3) return failFmt(gpa, diags, source, "buffers[{d}] leaves more than GLB's three padding bytes", .{i});
        buffers[i] = resolved.bytes[0..@intCast(buffer.byteLength)];
    }

    const images = try arena.alloc(translate.ImageInput, parsed.value.images.len);
    for (parsed.value.images, 0..) |image, i| {
        if ((image.uri == null) == (image.bufferView == null)) return failFmt(gpa, diags, source, "images[{d}] must name exactly one URI or bufferView", .{i});
        const input: translate.ImageInput = if (image.uri) |uri| blk: {
            try validateUri(gpa, diags, source, try std.fmt.allocPrint(arena, "images[{d}].uri", .{i}), uri);
            const resolved = reader.read(source, uri, limits.container.max_file_bytes) catch |err|
                return failFmt(gpa, diags, source, "images[{d}].uri '{s}' could not be read inside the package: {s}", .{ i, uri, @errorName(err) });
            break :blk .{ .bytes = resolved.bytes, .external_path = resolved.path };
        } else blk: {
            const view_index = image.bufferView.?;
            if (view_index >= parsed.value.bufferViews.len) return failFmt(gpa, diags, source, "images[{d}].bufferView references {d}, outside the bufferView array", .{ i, view_index });
            const buffer_view = parsed.value.bufferViews[view_index];
            if (buffer_view.buffer >= buffers.len) return failFmt(gpa, diags, source, "images[{d}].bufferView references missing buffer {d}", .{ i, buffer_view.buffer });
            const end = std.math.add(u64, buffer_view.byteOffset, buffer_view.byteLength) catch return failFmt(gpa, diags, source, "images[{d}].bufferView range overflows", .{i});
            if (end > buffers[buffer_view.buffer].len) return failFmt(gpa, diags, source, "images[{d}].bufferView lies outside its buffer", .{i});
            break :blk .{ .bytes = buffers[buffer_view.buffer][@intCast(buffer_view.byteOffset)..@intCast(end)] };
        };
        if (image.mimeType) |mime| if (!std.mem.eql(u8, mime, "image/png")) return failFmt(gpa, diags, source, "images[{d}] has MIME type '{s}'; re-export it as PNG", .{ i, mime });
        if (!asset.png.isPng(input.bytes)) return failFmt(gpa, diags, source, "images[{d}] is not PNG; re-export it as PNG", .{i});
        var decoded = asset.png.decode(gpa, input.bytes, .{}) catch |err|
            return failFmt(gpa, diags, source, "images[{d}] is not a valid supported PNG: {s}", .{ i, @errorName(err) });
        decoded.deinit(gpa);
        images[i] = input;
    }

    return translate.run(gpa, arena, &parsed.value, buffers, images, settings, limits.document, diags);
}

fn validateUri(gpa: Allocator, diags: *Diagnostics, source: []const u8, path: []const u8, uri: []const u8) Error!void {
    if (uri.len == 0 or uri[0] == '/' or uri[0] == '\\' or
        std.mem.indexOfScalar(u8, uri, '\\') != null or
        std.mem.indexOfScalar(u8, uri, '?') != null or
        std.mem.indexOfScalar(u8, uri, '#') != null or
        std.mem.indexOfScalar(u8, uri, '%') != null or
        std.mem.indexOfScalar(u8, uri, ':') != null)
    {
        return failFmt(gpa, diags, source, "{s} '{s}' is not a plain package-relative path (data URIs, absolute paths and URLs are refused)", .{ path, uri });
    }
}

fn extensionOf(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    return path[dot + 1 ..];
}

fn fail(gpa: Allocator, diags: *Diagnostics, source: []const u8, message: []const u8) Error {
    diags.addFmt(gpa, .err, .whole(source), 1, "", "{s}", .{message}) catch return error.OutOfMemory;
    return error.ContentInvalid;
}

fn failFmt(gpa: Allocator, diags: *Diagnostics, source: []const u8, comptime fmt: []const u8, args: anytype) Error {
    diags.addFmt(gpa, .err, .whole(source), 1, "", fmt, args) catch return error.OutOfMemory;
    return error.ContentInvalid;
}

test {
    _ = accessor;
    _ = container;
    _ = document;
    _ = translate;
}

const TestFile = struct {
    path: []const u8,
    bytes: []const u8,
};

const TestReader = struct {
    files: []const TestFile,

    fn interface(self: *TestReader) Reader {
        return .{ .ctx = self, .readFn = read };
    }

    fn read(ctx: *anyopaque, parent: []const u8, uri: []const u8, max_bytes: usize) ReadError!Resolved {
        const self: *TestReader = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, uri, "..") or std.mem.startsWith(u8, uri, "../") or
            std.mem.indexOf(u8, uri, "/../") != null)
        {
            return error.OutsidePackage;
        }
        const parent_dir = std.fs.path.dirnamePosix(parent) orelse "";
        for (self.files) |file| {
            const matches = if (parent_dir.len == 0)
                std.mem.eql(u8, file.path, uri)
            else
                file.path.len == parent_dir.len + 1 + uri.len and
                    std.mem.eql(u8, file.path[0..parent_dir.len], parent_dir) and
                    file.path[parent_dir.len] == '/' and
                    std.mem.eql(u8, file.path[parent_dir.len + 1 ..], uri);
            if (!matches) continue;
            if (file.bytes.len > max_bytes) return error.OverLimit;
            return .{ .path = file.path, .bytes = file.bytes };
        }
        return error.NotFound;
    }
};

const JsonParts = struct {
    asset: []const u8 = "\"version\":\"2.0\"",
    buffers: []const u8 = "{\"uri\":\"mesh.bin\",\"byteLength\":42}",
    buffer_views: []const u8 =
        "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36}," ++
        "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6}",
    accessors: []const u8 =
        "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," ++
        "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}",
    meshes: []const u8 =
        "{\"name\":\"Triangle\",\"primitives\":[{\"attributes\":{\"POSITION\":0},\"indices\":1,\"material\":0}]}",
    nodes: []const u8 = "{\"mesh\":0}",
    scene_nodes: []const u8 = "0",
    materials: []const u8 = "{\"name\":\"Mat\"}",
    tail: []const u8 = "",
};

fn makeJson(gpa: Allocator, parts: JsonParts) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"asset\":{");
    try out.appendSlice(gpa, parts.asset);
    try out.appendSlice(gpa, "},\"buffers\":[");
    try out.appendSlice(gpa, parts.buffers);
    try out.appendSlice(gpa, "],\"bufferViews\":[");
    try out.appendSlice(gpa, parts.buffer_views);
    try out.appendSlice(gpa, "],\"accessors\":[");
    try out.appendSlice(gpa, parts.accessors);
    try out.appendSlice(gpa, "],\"meshes\":[");
    try out.appendSlice(gpa, parts.meshes);
    try out.appendSlice(gpa, "],\"nodes\":[");
    try out.appendSlice(gpa, parts.nodes);
    try out.appendSlice(gpa, "],\"scenes\":[{\"nodes\":[");
    try out.appendSlice(gpa, parts.scene_nodes);
    try out.appendSlice(gpa, "]}],\"scene\":0,\"materials\":[");
    try out.appendSlice(gpa, parts.materials);
    try out.append(gpa, ']');
    try out.appendSlice(gpa, parts.tail);
    try out.append(gpa, '}');
    return out.toOwnedSlice(gpa);
}

fn makeTriangleBin() [42]u8 {
    var bytes: [42]u8 = @splat(0);
    writeTestF32(&bytes, 12, 1);
    writeTestF32(&bytes, 28, 1);
    std.mem.writeInt(u16, bytes[36..38], 0, .little);
    std.mem.writeInt(u16, bytes[38..40], 1, .little);
    std.mem.writeInt(u16, bytes[40..42], 2, .little);
    return bytes;
}

fn makeTriangleNormalBin() [80]u8 {
    var bytes: [80]u8 = @splat(0);
    const triangle = makeTriangleBin();
    @memcpy(bytes[0..triangle.len], &triangle);
    writeTestF32(&bytes, 52, 1);
    writeTestF32(&bytes, 64, 1);
    writeTestF32(&bytes, 76, 1);
    return bytes;
}

fn makeQuadBin() [92]u8 {
    var bytes: [92]u8 = @splat(0);
    writeTestF32(&bytes, 12, 1);
    writeTestF32(&bytes, 28, 1);
    writeTestF32(&bytes, 36, 1);
    writeTestF32(&bytes, 40, 1);
    writeTestF32(&bytes, 60, 1);
    writeTestF32(&bytes, 64, 1);
    writeTestF32(&bytes, 68, 1);
    writeTestF32(&bytes, 76, 1);
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    for (indices, 0..) |index, i| std.mem.writeInt(u16, bytes[80 + i * 2 ..][0..2], index, .little);
    return bytes;
}

fn writeTestF32(bytes: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @bitCast(value), .little);
}

fn makeGlb(gpa: Allocator, json: []const u8, bin: []const u8) Allocator.Error![]u8 {
    const json_len = std.mem.alignForward(usize, json.len, 4);
    const bin_len = std.mem.alignForward(usize, bin.len, 4);
    const bytes = try gpa.alloc(u8, 12 + 8 + json_len + 8 + bin_len);
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], container.glb_magic, .little);
    std.mem.writeInt(u32, bytes[4..8], container.glb_version, .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(bytes.len), .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(json_len), .little);
    std.mem.writeInt(u32, bytes[16..20], container.json_chunk, .little);
    @memcpy(bytes[20 .. 20 + json.len], json);
    @memset(bytes[20 + json.len .. 20 + json_len], ' ');
    const bin_at = 20 + json_len;
    std.mem.writeInt(u32, bytes[bin_at..][0..4], @intCast(bin_len), .little);
    std.mem.writeInt(u32, bytes[bin_at + 4 ..][0..4], container.bin_chunk, .little);
    @memcpy(bytes[bin_at + 8 ..][0..bin.len], bin);
    return bytes;
}

const test_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
    0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x38, 0xa1, 0x61, 0xf3,
    0x1f, 0x00, 0x05, 0x14, 0x02, 0x2c, 0xc2, 0x0e, 0x5d, 0x14, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

test "generated import fixtures cover containers, topology, transforms and mappings" {
    const testing = std.testing;
    const triangle = makeTriangleBin();

    // The binary-container fixture is independent of the external-file reader.
    const glb_json = try makeJson(testing.allocator, .{ .buffers = "{\"byteLength\":42}" });
    defer testing.allocator.free(glb_json);
    const glb = try makeGlb(testing.allocator, glb_json, &triangle);
    defer testing.allocator.free(glb);
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var diags = Diagnostics.init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        var reader: TestReader = .{ .files = &.{} };
        const result = try import(testing.allocator, arena.allocator(), "models/triangle.glb", glb, .{
            .model_id = "demo:models.triangle",
            .source = "models/triangle.glb",
        }, reader.interface(), .default, &diags);
        try testing.expect(!diags.failed);
        try testing.expectEqual(@as(usize, 1), result.assets.len);
        var mesh_view = try asset.mesh_file.read(result.assets[0].bytes, .default);
        const mesh = mesh_view.mesh();
        try testing.expectEqual(@as(u32, 3), mesh.vertex_count);
        try testing.expectEqual(@as(usize, 1), mesh.submeshes.len);
    }

    const Case = struct {
        parts: JsonParts = .{},
        settings: translate.Settings,
        source_contains: []const u8,
        part_count: usize = 1,
        submesh_count: usize = 1,
    };
    const mapping = [_]translate.MaterialMapping{.{ .name = "Mat", .material = "demo:shared.matte" }};
    const cases = [_]Case{
        .{
            .parts = .{ .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0},\"material\":0}]}" },
            .settings = .{ .model_id = "demo:models.unindexed", .source = "models/fixture.gltf" },
            .source_contains = "demo:models.unindexed.mesh0",
        },
        .{
            .parts = .{ .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0},\"indices\":1}]}", .materials = "" },
            .settings = .{ .model_id = "demo:models.default_material", .source = "models/fixture.gltf" },
            .source_contains = "demo:models.default_material.material0",
        },
        .{
            .parts = .{ .meshes = "{\"name\":\"Split\",\"primitives\":[" ++
                "{\"attributes\":{\"POSITION\":0},\"indices\":1,\"material\":0}," ++
                "{\"attributes\":{\"POSITION\":0},\"indices\":1,\"material\":0}]}" },
            .settings = .{ .model_id = "demo:models.split", .source = "models/fixture.gltf" },
            .source_contains = "submesh 1",
            .part_count = 2,
            .submesh_count = 2,
        },
        .{
            .parts = .{ .nodes = "{\"translation\":[1,0,0],\"children\":[1]}," ++
                "{\"translation\":[2,0,0],\"children\":[2]}," ++
                "{\"translation\":[3,0,0],\"mesh\":0}" },
            .settings = .{ .model_id = "demo:models.chain", .source = "models/fixture.gltf" },
            .source_contains = "translation { x 6",
        },
        .{
            .parts = .{ .nodes = "{\"scale\":[-1,1,1],\"mesh\":0}" },
            .settings = .{ .model_id = "demo:models.mirror", .source = "models/fixture.gltf" },
            .source_contains = "scale { x -1",
        },
        .{
            .settings = .{ .model_id = "demo:models.front", .source = "models/fixture.gltf", .front = .plus_z },
            .source_contains = "rotation { x 0 y 1",
        },
        .{
            .settings = .{ .model_id = "demo:models.mapped", .source = "models/fixture.gltf", .materials = &mapping },
            .source_contains = "material demo:shared.matte",
        },
        .{
            .parts = .{ .nodes = "{\"mesh\":0},{\"translation\":[2,0,0],\"mesh\":0}", .scene_nodes = "0,1" },
            .settings = .{ .model_id = "demo:models.instances", .source = "models/fixture.gltf" },
            .source_contains = "translation { x 2",
            .part_count = 2,
        },
    };
    for (cases) |case| {
        const json = try makeJson(testing.allocator, case.parts);
        defer testing.allocator.free(json);
        const files = [_]TestFile{.{ .path = "models/mesh.bin", .bytes = &triangle }};
        var reader: TestReader = .{ .files = &files };
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var diags = Diagnostics.init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        const result = try import(testing.allocator, arena.allocator(), case.settings.source, json, case.settings, reader.interface(), .default, &diags);
        try testing.expect(!diags.failed);
        try testing.expect(std.mem.indexOf(u8, result.source, case.source_contains) != null);
        try testing.expectEqual(case.part_count, std.mem.count(u8, result.source, " { mesh "));
        var mesh_view = try asset.mesh_file.read(result.assets[0].bytes, .default);
        try testing.expectEqual(case.submesh_count, mesh_view.mesh().submeshes.len);
    }
}

test "a textured quad imports external PNG and widened UV stream" {
    const testing = std.testing;
    const quad = makeQuadBin();
    const json = try makeJson(testing.allocator, .{
        .buffers = "{\"uri\":\"quad.bin\",\"byteLength\":92}",
        .buffer_views = "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":48}," ++
            "{\"buffer\":0,\"byteOffset\":48,\"byteLength\":32}," ++
            "{\"buffer\":0,\"byteOffset\":80,\"byteLength\":12}",
        .accessors = "{\"bufferView\":0,\"componentType\":5126,\"count\":4,\"type\":\"VEC3\"}," ++
            "{\"bufferView\":1,\"componentType\":5126,\"count\":4,\"type\":\"VEC2\"}," ++
            "{\"bufferView\":2,\"componentType\":5123,\"count\":6,\"type\":\"SCALAR\"}",
        .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"TEXCOORD_0\":1},\"indices\":2,\"material\":0}]}",
        .materials = "{\"name\":\"Paper\",\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0}}}",
        .tail = ",\"images\":[{\"uri\":\"quad.png\",\"mimeType\":\"image/png\"}],\"textures\":[{\"source\":0}]",
    });
    defer testing.allocator.free(json);
    const files = [_]TestFile{
        .{ .path = "models/quad.bin", .bytes = &quad },
        .{ .path = "models/quad.png", .bytes = &test_png },
    };
    var reader: TestReader = .{ .files = &files };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diags = Diagnostics.init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    const result = try import(testing.allocator, arena.allocator(), "models/quad.gltf", json, .{
        .model_id = "demo:models.quad",
        .source = "models/quad.gltf",
    }, reader.interface(), .default, &diags);
    try testing.expectEqual(@as(usize, 1), result.assets.len);
    try testing.expect(std.mem.indexOf(u8, result.source, "source \"models/quad.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.source, "mipmaps true") != null);
    var mesh_view = try asset.mesh_file.read(result.assets[0].bytes, .default);
    try testing.expectEqual(@as(usize, 2), mesh_view.mesh().streams.len);
}

test "unsupported optional glTF features are named warnings, not silent drops" {
    const testing = std.testing;
    const triangle = makeTriangleBin();
    const json = try makeJson(testing.allocator, .{
        .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"TANGENT\":0},\"indices\":1,\"material\":0}]}",
        .nodes = "{\"mesh\":0,\"camera\":0,\"skin\":0}",
        .tail = ",\"extensionsUsed\":[\"EXT_optional\"],\"cameras\":[{}],\"animations\":[{}],\"skins\":[{}]",
    });
    defer testing.allocator.free(json);
    const files = [_]TestFile{.{ .path = "models/mesh.bin", .bytes = &triangle }};
    var reader: TestReader = .{ .files = &files };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diags = Diagnostics.init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    _ = try import(testing.allocator, arena.allocator(), "models/warnings.gltf", json, .{
        .model_id = "demo:warnings",
        .source = "models/warnings.gltf",
    }, reader.interface(), .default, &diags);
    try testing.expect(!diags.failed);
    const needles = [_][]const u8{ "EXT_optional", "cameras", "animations", "skins", "TANGENT", "camera placement", "skin placement" };
    for (needles) |needle| {
        var found = false;
        for (diags.items.items) |diag| if (std.mem.indexOf(u8, diag.message, needle) != null) {
            found = true;
            break;
        };
        try testing.expect(found);
    }
}

fn expectImportFailure(json: []const u8, files: []const TestFile, limits: Limits, needle: []const u8) !void {
    const testing = std.testing;
    var reader: TestReader = .{ .files = files };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diags = Diagnostics.init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    try testing.expectError(error.ContentInvalid, import(testing.allocator, arena.allocator(), "models/bad.gltf", json, .{
        .model_id = "demo:models.bad",
        .source = "models/bad.gltf",
    }, reader.interface(), limits, &diags));
    try testing.expect(diags.failed);
    for (diags.items.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, needle) != null) return;
    }
    std.debug.print("expected diagnostic containing '{s}'\n", .{needle});
    for (diags.items.items) |diag| std.debug.print("  {s}\n", .{diag.message});
    return error.TestExpectedEqual;
}

test "the glTF subset refuses every named hostile boundary with an object path" {
    const testing = std.testing;
    const triangle = makeTriangleBin();
    const normal = makeTriangleNormalBin();
    const ordinary = [_]TestFile{.{ .path = "models/mesh.bin", .bytes = &triangle }};

    const UriCase = struct { uri: []const u8, needle: []const u8 };
    for ([_]UriCase{
        .{ .uri = "data:application/octet-stream;base64,AA==", .needle = "not a plain package-relative path" },
        .{ .uri = "/absolute.bin", .needle = "not a plain package-relative path" },
        .{ .uri = "https://example.invalid/mesh.bin", .needle = "not a plain package-relative path" },
        .{ .uri = "../mesh.bin", .needle = "inside the package" },
    }) |case| {
        const buffer = try std.fmt.allocPrint(testing.allocator, "{{\"uri\":\"{s}\",\"byteLength\":42}}", .{case.uri});
        defer testing.allocator.free(buffer);
        const json = try makeJson(testing.allocator, .{ .buffers = buffer });
        defer testing.allocator.free(json);
        try expectImportFailure(json, &ordinary, .default, case.needle);
    }

    const Refusal = struct { parts: JsonParts, files: ?[]const TestFile = null, needle: []const u8, limits: Limits = .default };
    const normal_files = [_]TestFile{.{ .path = "models/mesh.bin", .bytes = &normal }};
    var out_of_range = triangle;
    std.mem.writeInt(u16, out_of_range[40..42], 3, .little);
    const range_files = [_]TestFile{.{ .path = "models/mesh.bin", .bytes = &out_of_range }};
    var non_finite = triangle;
    writeTestF32(&non_finite, 0, std.math.nan(f32));
    const non_finite_files = [_]TestFile{.{ .path = "models/mesh.bin", .bytes = &non_finite }};
    var non_unit = normal;
    writeTestF32(&non_unit, 52, 2);
    const non_unit_files = [_]TestFile{.{ .path = "models/mesh.bin", .bytes = &non_unit }};
    const corrupt_png = [_]u8{ 0x89, 'P', 'N', 'G', 0, 0, 0, 0 };
    const png_files = [_]TestFile{
        .{ .path = "models/mesh.bin", .bytes = &triangle },
        .{ .path = "models/image.png", .bytes = &test_png },
    };
    const corrupt_png_files = [_]TestFile{
        .{ .path = "models/mesh.bin", .bytes = &triangle },
        .{ .path = "models/image.png", .bytes = &corrupt_png },
    };
    const jpeg_files = [_]TestFile{
        .{ .path = "models/mesh.bin", .bytes = &triangle },
        .{ .path = "models/image.jpg", .bytes = "not a png" },
    };
    const refusals = [_]Refusal{
        .{ .parts = .{ .asset = "\"version\":\"1.0\"" }, .needle = "asset.version" },
        .{ .parts = .{ .asset = "\"version\":\"2.0\",\"minVersion\":\"2.1\"" }, .needle = "asset.minVersion" },
        .{ .parts = .{ .tail = ",\"extensionsRequired\":[\"EXT_hostile\"]" }, .needle = "extensionsRequired" },
        .{ .parts = .{ .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0},\"indices\":1,\"material\":0,\"mode\":5}]}" }, .needle = "meshes[0].primitives[0]" },
        .{ .parts = .{ .meshes = "{\"primitives\":[{\"attributes\":{},\"indices\":1,\"material\":0}]}" }, .needle = "has no POSITION" },
        .{ .parts = .{ .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"JOINTS_0\":0},\"indices\":1,\"material\":0}]}" }, .needle = "JOINTS_0" },
        .{ .parts = .{ .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0},\"indices\":1,\"material\":0,\"targets\":[{}]}]}" }, .needle = "morph targets" },
        .{ .parts = .{ .accessors = "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\",\"sparse\":{}}," ++
            "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}" }, .needle = "SparseUnsupported" },
        .{ .parts = .{ .buffer_views = "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":20}," ++
            "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6}" }, .needle = "InvalidRange" },
        .{ .parts = .{ .buffer_views = "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36,\"byteStride\":8}," ++
            "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6}" }, .needle = "InvalidStride" },
        .{ .parts = .{ .accessors = "{\"bufferView\":0,\"byteOffset\":2,\"componentType\":5126,\"count\":2,\"type\":\"VEC3\"}," ++
            "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}" }, .needle = "InvalidAlignment" },
        .{ .parts = .{ .accessors = "{\"bufferView\":0,\"componentType\":5126,\"count\":4294967296,\"type\":\"VEC3\"}," ++
            "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}" }, .needle = "CountTooLarge" },
        .{ .parts = .{}, .files = &non_finite_files, .needle = "non-finite" },
        .{ .parts = .{}, .files = &range_files, .needle = "outside the primitive" },
        .{ .parts = .{ .buffers = "{\"uri\":\"mesh.bin\",\"byteLength\":80}", .buffer_views = "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36}," ++
            "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6}," ++
            "{\"buffer\":0,\"byteOffset\":44,\"byteLength\":36}", .accessors = "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," ++
            "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}," ++
            "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}", .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0,\"NORMAL\":2},\"indices\":1,\"material\":0}]}" }, .files = &non_unit_files, .needle = "non-unit" },
        .{ .parts = .{ .buffers = "{\"uri\":\"mesh.bin\",\"byteLength\":80}", .buffer_views = "{\"buffer\":0,\"byteOffset\":0,\"byteLength\":36}," ++
            "{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6}," ++
            "{\"buffer\":0,\"byteOffset\":44,\"byteLength\":36}", .accessors = "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," ++
            "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}," ++
            "{\"bufferView\":2,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}", .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0},\"indices\":1,\"material\":0},{\"attributes\":{\"POSITION\":0,\"NORMAL\":2},\"indices\":1,\"material\":0}]}" }, .files = &normal_files, .needle = "same imported attributes" },
        .{ .parts = .{ .materials = "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0,\"texCoord\":1}}}", .tail = ",\"images\":[{\"uri\":\"image.png\",\"mimeType\":\"image/png\"}],\"textures\":[{\"source\":0}]" }, .files = &png_files, .needle = "texCoord 1" },
        .{ .parts = .{ .materials = "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0}}}", .tail = ",\"images\":[{\"uri\":\"image.png\",\"mimeType\":\"image/png\"}]," ++
            "\"textures\":[{\"source\":0,\"sampler\":0}]," ++
            "\"samplers\":[{\"wrapS\":10497,\"wrapT\":33071}]" }, .files = &png_files, .needle = "different wrapS" },
        .{ .parts = .{ .tail = ",\"images\":[{\"uri\":\"image.jpg\",\"mimeType\":\"image/jpeg\"}]" }, .files = &jpeg_files, .needle = "image/jpeg" },
        .{ .parts = .{ .tail = ",\"images\":[{\"uri\":\"image.png\",\"mimeType\":\"image/png\"}]" }, .files = &corrupt_png_files, .needle = "not PNG" },
        .{ .parts = .{ .meshes = "{\"primitives\":[{\"attributes\":{\"POSITION\":0},\"indices\":1,\"material\":0},{\"attributes\":{\"POSITION\":0},\"indices\":1,\"material\":1}]}", .materials = "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":0}}}," ++
            "{\"pbrMetallicRoughness\":{\"baseColorTexture\":{\"index\":1}}}", .tail = ",\"images\":[{\"uri\":\"image.png\",\"mimeType\":\"image/png\"}]," ++
            "\"textures\":[{\"source\":0,\"sampler\":0},{\"source\":0,\"sampler\":1}]," ++
            "\"samplers\":[{\"wrapS\":10497,\"wrapT\":10497},{\"wrapS\":33071,\"wrapT\":33071}]" }, .files = &png_files, .needle = "sampling different" },
        .{ .parts = .{ .nodes = "{\"children\":[0],\"mesh\":0}" }, .needle = "nodes[0]" },
        .{ .parts = .{ .nodes = "{\"children\":[2]},{\"children\":[2]},{\"mesh\":0}", .scene_nodes = "0,1" }, .needle = "reached twice" },
        .{ .parts = .{ .nodes = "{\"scale\":[2,1,1],\"children\":[1]},{\"rotation\":[0,0,0.38268343,0.9238795],\"mesh\":0}" }, .needle = "not exactly representable" },
        .{ .parts = .{}, .needle = "OverLimit", .limits = .{ .container = .{ .max_file_bytes = 1 } } },
        .{ .parts = .{}, .needle = "OverLimit", .limits = .{ .container = .{ .max_json_bytes = 1 } } },
        .{ .parts = .{}, .needle = "OverLimit", .limits = .{ .document = .{ .max_json_bytes = 1 } } },
        .{ .parts = .{}, .needle = "OverLimit", .limits = .{ .document = .{ .max_nodes = 0 } } },
        .{ .parts = .{}, .needle = "OverLimit", .limits = .{ .document = .{ .max_meshes = 0 } } },
        .{ .parts = .{}, .needle = "OverLimit", .limits = .{ .document = .{ .max_primitives = 0 } } },
        .{ .parts = .{}, .needle = "OverLimit", .limits = .{ .document = .{ .max_accessors = 0 } } },
        .{ .parts = .{ .tail = ",\"images\":[{\"uri\":\"image.png\"}]" }, .needle = "OverLimit", .limits = .{ .document = .{ .max_images = 0 } } },
        .{ .parts = .{ .nodes = "{\"children\":[1]},{\"mesh\":0}" }, .needle = "deeper than", .limits = .{ .document = .{ .max_node_depth = 1 } } },
    };
    for (refusals) |case| {
        const json = try makeJson(testing.allocator, case.parts);
        defer testing.allocator.free(json);
        try expectImportFailure(json, case.files orelse &ordinary, case.limits, case.needle);
    }
}

test "a small GLB mutation sweep is bounded and always returns data or a diagnostic" {
    const testing = std.testing;
    const triangle = makeTriangleBin();
    const json = try makeJson(testing.allocator, .{ .buffers = "{\"byteLength\":42}" });
    defer testing.allocator.free(json);
    const original = try makeGlb(testing.allocator, json, &triangle);
    defer testing.allocator.free(original);
    const start = std.Io.Clock.awake.now(testing.io);

    var length: usize = 0;
    while (length < original.len) : (length += 1) try expectMutationOutcome(original[0..length]);
    const changed = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(changed);
    for (changed, 0..) |*byte, i| {
        byte.* ^= 0xff;
        try expectMutationOutcome(changed);
        byte.* = original[i];
    }

    const elapsed = std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds;
    try testing.expect(elapsed < 5 * std.time.ns_per_s);
}

fn expectMutationOutcome(bytes: []const u8) !void {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diags = Diagnostics.init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    var reader: TestReader = .{ .files = &.{} };
    _ = import(testing.allocator, arena.allocator(), "mutation.glb", bytes, .{
        .model_id = "demo:mutation",
        .source = "mutation.glb",
    }, reader.interface(), .default, &diags) catch |err| switch (err) {
        error.ContentInvalid => {
            try testing.expect(diags.failed);
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}
