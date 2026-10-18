//! Private `render3d` asset loaders (`docs/design/meshes.md` §7.4).
//!
//! They are passed only to `asset.Registry.acquireWith`: neither claims the schema globally.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");

const renderer_mod = @import("renderer.zig");
const Allocator = std.mem.Allocator;
const Renderer = renderer_mod.Renderer;

/// Split (ADR-0062): the PNG decode and the mip chain off the main thread, through
/// `asset.texture_decode`; the upload in the finish (`background.md` §7).
pub fn textureLoader(renderer: *Renderer) asset.Loader {
    return .{
        .schema = asset.schemas.texture.id,
        .ctx = renderer,
        .load = loadTexture,
        .unload = unloadTexture,
        .split = .{
            .decode_ctx = &renderer.texture_limits,
            .decode = asset.texture_decode.decode,
            .finish = finishTexture,
            .discard = asset.texture_decode.discard,
            // A chain is megabytes; returning it is not the main thread's work.
            .after_finish = .free_on_pool,
        },
    };
}

/// Split: the file's whole validation off the main thread; the buffers in the finish.
pub fn meshLoader(renderer: *Renderer) asset.Loader {
    return .{
        .schema = asset.schemas.mesh.id,
        .ctx = renderer,
        .max_source_bytes = asset.MeshFileLimits.default.max_file_bytes,
        .load = loadMesh,
        .unload = unloadMesh,
        .split = .{ .decode = decodeMesh, .finish = finishMesh, .discard = discardMesh },
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
    return textureLoader(renderer).loadWhole(gpa, record, bytes);
}

fn finishTexture(ctx: ?*anyopaque, _: Allocator, record: asset.Record, decoded: asset.Decoded, budget: *asset.Budget) asset.LoadError!asset.Payload {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx orelse return error.LoadFailed));
    const texture = asset.texture_decode.of(decoded);
    const options: renderer_mod.TextureOptions = .{
        .filter = enumField(renderer_mod.Filter, record, asset.schemas.filter_field, .nearest),
        .wrap = enumField(renderer_mod.Wrap, record, asset.schemas.wrap_field, .clamp),
        // The decode read the same field with the same default, so its chain is in this space.
        .color_space = enumField(asset.ColorSpace, record, asset.schemas.color_space_field, .srgb),
        .mipmaps = texture.chain != null,
        .label = record.name,
    };
    const made = if (texture.chain) |chain|
        renderer.createTextureFromChain(chain, options)
    else
        renderer.createTexture(texture.image.?, options);
    const handle = made catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.LoadFailed,
    };
    // The chain is the registry's to free, on the pool (`asset.AfterFinish.free_on_pool`).
    budget.charge(texture.byteSize());
    return .fromHandle(handle);
}

fn unloadTexture(ctx: ?*anyopaque, _: Allocator, payload: asset.Payload) void {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx orelse return));
    renderer.destroyTexture(payload.asHandle(renderer_mod.TextureHandle));
}

fn loadMesh(ctx: ?*anyopaque, gpa: Allocator, record: asset.Record, bytes: []const u8) asset.LoadError!asset.Payload {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx orelse return error.LoadFailed));
    return meshLoader(renderer).loadWhole(gpa, record, bytes);
}

/// The file's bytes, owned, and the view its validation returned over them.
const DecodedMesh = struct {
    bytes: []u8,
    view: asset.mesh_file.View,
};

fn decodeMesh(_: ?*const anyopaque, gpa: Allocator, _: asset.Record, bytes: []const u8) asset.LoadError!asset.Decoded {
    const owned = try gpa.dupe(u8, bytes);
    errdefer gpa.free(owned);
    const view = asset.mesh_file.read(owned, .default) catch |err| return switch (err) {
        error.UnsupportedVersion => error.UnsupportedVersion,
        else => error.InvalidAsset,
    };
    const decoded = try gpa.create(DecodedMesh);
    decoded.* = .{ .bytes = owned, .view = view };
    return .fromPointer(decoded);
}

fn finishMesh(ctx: ?*anyopaque, _: Allocator, record: asset.Record, decoded: asset.Decoded, budget: *asset.Budget) asset.LoadError!asset.Payload {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx orelse return error.LoadFailed));
    const mesh: *DecodedMesh = @ptrCast(@alignCast(decoded.pointer().?));
    const handle = renderer.createMesh(mesh.view.mesh(), record.name) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.LoadFailed,
    };
    budget.charge(mesh.bytes.len);
    return .fromHandle(handle);
}

fn discardMesh(gpa: Allocator, decoded: asset.Decoded) void {
    const mesh: *DecodedMesh = @ptrCast(@alignCast(decoded.pointer().?));
    gpa.free(mesh.bytes);
    gpa.destroy(mesh);
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
