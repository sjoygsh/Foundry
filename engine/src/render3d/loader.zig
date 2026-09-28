//! Private `render3d` asset loaders (`docs/design/meshes.md` §7.4).
//!
//! They are passed only to `asset.Registry.acquireWith`: neither claims the schema globally.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");

const renderer_mod = @import("renderer.zig");
const Allocator = std.mem.Allocator;
const Renderer = renderer_mod.Renderer;

pub fn textureLoader(renderer: *Renderer) asset.Loader {
    return .{
        .schema = asset.schemas.texture.id,
        .ctx = renderer,
        .load = loadTexture,
        .unload = unloadTexture,
    };
}

pub fn meshLoader(renderer: *Renderer) asset.Loader {
    return .{
        .schema = asset.schemas.mesh.id,
        .ctx = renderer,
        .max_source_bytes = asset.MeshFileLimits.default.max_file_bytes,
        .load = loadMesh,
        .unload = unloadMesh,
    };
}

pub fn textureOf(registry: *asset.Registry, handle: asset.AssetHandle, renderer: *Renderer) ?renderer_mod.TextureHandle {
    const loaded = registry.getIfLoader(handle, textureLoader(renderer)) orelse return null;
    return loaded.payload.asHandle(renderer_mod.TextureHandle);
}

pub fn meshOf(registry: *asset.Registry, handle: asset.AssetHandle, renderer: *Renderer) ?renderer_mod.MeshHandle {
    const loaded = registry.getIfLoader(handle, meshLoader(renderer)) orelse return null;
    return loaded.payload.asHandle(renderer_mod.MeshHandle);
}

fn loadTexture(ctx: ?*anyopaque, gpa: Allocator, record: asset.Record, bytes: []const u8) asset.LoadError!asset.Payload {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx orelse return error.LoadFailed));
    var image = asset.png.decode(gpa, bytes, .{ .max_dimension = renderer.device.capabilities().max_texture_dimension }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedImage => error.UnsupportedVersion,
        error.InvalidImage => error.InvalidAsset,
        error.ImageTooLarge => error.LoadFailed,
    };
    defer image.deinit(gpa);

    const handle = renderer.createTexture(image, .{
        .filter = enumField(renderer_mod.Filter, record, asset.schemas.filter_field, .nearest),
        .wrap = enumField(renderer_mod.Wrap, record, asset.schemas.wrap_field, .clamp),
        .color_space = enumField(asset.ColorSpace, record, asset.schemas.color_space_field, .srgb),
        .mipmaps = asset.schemas.boolField(record, asset.schemas.texture, asset.schemas.mipmaps_field) orelse false,
        .label = record.name,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.LoadFailed,
    };
    return .fromHandle(handle);
}

fn unloadTexture(ctx: ?*anyopaque, _: Allocator, payload: asset.Payload) void {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx orelse return));
    renderer.destroyTexture(payload.asHandle(renderer_mod.TextureHandle));
}

fn loadMesh(ctx: ?*anyopaque, _: Allocator, record: asset.Record, bytes: []const u8) asset.LoadError!asset.Payload {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx orelse return error.LoadFailed));
    var view = asset.mesh_file.read(bytes, .default) catch |err| return switch (err) {
        error.UnsupportedVersion => error.UnsupportedVersion,
        else => error.InvalidAsset,
    };
    const handle = renderer.createMesh(view.mesh(), record.name) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.LoadFailed,
    };
    return .fromHandle(handle);
}

fn unloadMesh(ctx: ?*anyopaque, _: Allocator, payload: asset.Payload) void {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx orelse return));
    renderer.destroyMesh(payload.asHandle(renderer_mod.MeshHandle));
}

fn enumField(comptime E: type, record: asset.Record, field: []const u8, default: E) E {
    const text = asset.schemas.stringField(record, asset.schemas.texture, field) orelse return default;
    return std.meta.stringToEnum(E, text) orelse {
        core.log.scoped(.render3d).warn("texture '{s}': unknown {s} '{s}'; using {s}", .{
            record.name, field, text, @tagName(default),
        });
        return default;
    };
}

const testing = std.testing;

test "private loaders keep their schema identity and accept every texture default" {
    inline for (.{
        .{ renderer_mod.Filter, asset.schemas.filter_field },
        .{ renderer_mod.Wrap, asset.schemas.wrap_field },
        .{ asset.ColorSpace, asset.schemas.color_space_field },
    }) |pair| {
        const index = asset.schemas.texture.fieldIndex(pair[1]).?;
        const declared = asset.schemas.texture.fields[index].presence.default.string;
        try testing.expect(std.meta.stringToEnum(pair[0], declared) != null);
    }

    var renderer: Renderer = undefined;
    const texture = textureLoader(&renderer);
    const mesh = meshLoader(&renderer);
    try testing.expect(texture.schema.eql(asset.schemas.texture.id));
    try testing.expect(mesh.schema.eql(asset.schemas.mesh.id));
    try testing.expectEqual(asset.MeshFileLimits.default.max_file_bytes, mesh.max_source_bytes);
    try testing.expect(!texture.eql(mesh));
}
