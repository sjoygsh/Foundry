//! `render2d`, as the public table publishes it.
//!
//! The RHI never crosses this file. A mod sees handles and plain descriptors, while the host
//! lends the renderer and the camera that the application owns. The renderer remains the
//! owner of its draw list and GPU resources; this layer validates untrusted input and maps
//! the renderer's errors to `FoundryResult`.
//!
//! Design: `docs/design/public-abi.md` §9; `docs/design/render2d.md` §§5, 6, 8, 10 and 12.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");
const render2d = @import("render2d");

const types = @import("types.zig");
const render_types = @import("render_types.zig");

const Asset = types.Asset;
const Result = types.Result;
const Str = types.Str;

const Camera = render_types.Camera;
const Color = render_types.Color;
const Font = render_types.Font;
const Rect = render_types.Rect;
const Sprite = render_types.Sprite;
const Stats = render_types.Stats;
const TextOptions = render_types.TextOptions;
const Vec2 = render_types.Vec2;
const ViewDesc = render_types.ViewDesc;

/// The phantom target for an ABI view handle. The renderer's own `ViewId` is only an index
/// and is valid for one `begin`; this outer handle adds the generation the C boundary needs.
const AbiView = opaque {};
const AbiViewHandle = core.Handle(AbiView);

const max_codepoint: u32 = 0x10ffff;
pub const max_render_textures: u32 = 256;

/// A host-owned wrapper around an asset-backed renderer texture. This is deliberately not
/// the renderer's handle: the extra slot owns the ABI reference acquired for the caller and
/// can release it without ever asking render2d to destroy a registry-owned payload.
const AbiTexture = opaque {};
const AbiTextureHandle = core.Handle(AbiTexture);

/// The shape HostOf must provide for the texture ownership bridge. The host may use this type
/// directly or an identical private type; the call layer only accesses these four fields.
pub const RenderTextureSlot = struct {
    active: bool = false,
    generation: u32 = 0,
    asset: asset.AssetHandle = .none,
};

/// Builds the render2d calls for one host type. `H` is deliberately generic: tests and tools
/// can lend a real renderer without naming `app.Engine`, and a host can supply no renderer at
/// all while retaining one table shape (`public-abi.md` §4).
pub fn Of(comptime H: type) type {
    return struct {
        pub fn renderTextureOfAsset(asset_handle: Asset, out: ?*types.Texture) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            const renderer = h.renderer orelse return .unavailable;

            const expected_loader = render2d.textureLoader(renderer);
            const loaded = engine.assets.getIfLoader(
                asset_handle.unwrap(asset.AssetHandle),
                expected_loader,
            ) orelse return textureProvenanceFailure(engine, asset_handle, expected_loader);
            // The registry query proves both that this is a texture asset and that the
            // payload was made by this renderer's loader. The pool check remains useful for
            // a malformed/custom loader that claims the texture loader's identity.
            const texture = loaded.payload.asHandle(render2d.TextureHandle);
            if (renderer.textureSize(texture) == null) return .invalid_handle;

            // `asset_find` intentionally does not add a reference. Acquire one here so the
            // ABI result has a balanced lifetime independent of the input handle. If the
            // host table is full, immediately give that extra reference back.
            const owned_asset = engine.assets.acquire(engine.gpa, loaded.id) catch |err| {
                return assetAcquireFailure(err);
            };
            const slot = openTextureSlot(h, owned_asset) orelse {
                engine.assets.release(owned_asset);
                return .limit;
            };
            destination.* = .wrap(slot);
            return .ok;
        }

        /// The wrapper owns one asset reference, while the asset loader owns the renderer
        /// payload. Releasing the wrapper reference is the only valid destruction operation;
        /// the registry evicts and destroys the payload when its own count reaches zero.
        pub fn renderDestroyTexture(handle: types.Texture) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            _ = h.renderer orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            const slot = resolveTextureSlot(h, handle) orelse return .invalid_handle;
            engine.assets.release(slot.asset);
            closeTextureSlot(slot);
            return .ok;
        }

        pub fn renderDrawSprite(supplied: ?*const Sprite) callconv(.c) Result {
            const sprite = supplied orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const renderer = h.renderer orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            const texture = resolveTexture(h, engine, renderer, sprite.texture) catch |err| {
                return textureResolutionFailure(err);
            };
            const mapped = spriteValue(sprite.*, texture) catch return .invalid_argument;

            renderer.drawSprite(mapped) catch |err| return renderFailure(err);
            return .ok;
        }

        pub fn renderDrawText(
            supplied_font: ?*const Font,
            text: Str,
            supplied_options: ?*const TextOptions,
        ) callconv(.c) Result {
            const font = supplied_font orelse return .invalid_argument;
            const options = supplied_options orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const renderer = h.renderer orelse return .unavailable;
            // The public boundary validates all strings as UTF-8 (§6). The renderer still
            // retains its replacement-glyph behaviour for strings supplied by engine code;
            // a mod must cross this boundary with valid UTF-8.
            const bytes = text.utf8() orelse return .invalid_argument;
            const engine = h.engine orelse return .unavailable;
            const texture = resolveTexture(h, engine, renderer, font.texture) catch |err| {
                return textureResolutionFailure(err);
            };
            const mapped_font = fontValue(font.*, texture) catch return .invalid_argument;
            const mapped_options = textOptionsValue(options.*) catch return .invalid_argument;

            renderer.drawText(mapped_font, bytes, mapped_options) catch |err| {
                return renderFailure(err);
            };
            return .ok;
        }

        pub fn renderAddView(supplied: ?*const ViewDesc, out: ?*types.View) callconv(.c) Result {
            const desc = supplied orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const renderer = h.renderer orelse return .unavailable;
            const mapped = viewDescValue(desc.*) catch return .invalid_argument;

            const id = renderer.addView(mapped) catch |err| return renderFailure(err);
            destination.* = .wrap(AbiViewHandle{
                .index = @intCast(id.index()),
                .generation = viewGeneration(renderer),
            });
            return .ok;
        }

        pub fn renderSelectView(view: types.View) callconv(.c) Result {
            const h = H.current() orelse return .unavailable;
            const renderer = h.renderer orelse return .unavailable;
            const unpacked = view.unwrap(AbiViewHandle);
            const generation = viewGeneration(renderer);
            if (unpacked.bits() == 0 or
                @as(u32, @truncate(unpacked.bits() >> 32)) != generation or
                @as(u32, @truncate(unpacked.bits())) >= 64)
            {
                return .invalid_handle;
            }

            renderer.setView(render2d.ViewId.fromIndex(@truncate(unpacked.bits()))) catch |err| {
                return renderFailure(err);
            };
            return .ok;
        }

        pub fn renderCameraGet(out: ?*Camera) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            _ = h.renderer orelse return .unavailable;
            const camera = h.camera orelse return .unavailable;
            const value = fromCamera(camera.*);
            if (!validCamera(value)) return .invalid_argument;
            destination.* = value;
            return .ok;
        }

        pub fn renderCameraSet(supplied: ?*const Camera) callconv(.c) Result {
            const camera = supplied orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            _ = h.renderer orelse return .unavailable;
            const destination = h.camera orelse return .unavailable;
            if (!validCamera(camera.*)) return .invalid_argument;
            destination.* = cameraValue(camera.*);
            return .ok;
        }

        pub fn renderWorldToScreen(world: Vec2, out: ?*Vec2) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            _ = h.renderer orelse return .unavailable;
            const camera = h.camera orelse return .unavailable;
            const current = fromCamera(camera.*);
            if (!validCamera(current)) return .invalid_argument;
            if (!validVec2(world)) return .invalid_argument;

            const result = vec2Value(camera.*.worldToScreen(core.math.Vec2.init(world.x, world.y)));
            if (!validVec2(result)) return .invalid_argument;
            destination.* = result;
            return .ok;
        }

        pub fn renderScreenToWorld(screen: Vec2, out: ?*Vec2) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            _ = h.renderer orelse return .unavailable;
            const camera = h.camera orelse return .unavailable;
            const current = fromCamera(camera.*);
            if (!validCamera(current)) return .invalid_argument;
            if (!validVec2(screen)) return .invalid_argument;

            const result = vec2Value(camera.*.screenToWorld(core.math.Vec2.init(screen.x, screen.y)));
            if (!validVec2(result)) return .invalid_argument;
            destination.* = result;
            return .ok;
        }

        pub fn renderStats(out: ?*Stats) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const renderer = h.renderer orelse return .unavailable;
            const stats = renderer.frameStats();
            destination.* = .{
                .sprites = stats.sprites,
                .glyphs = stats.glyphs,
                .tiles = stats.tiles,
                .batches = stats.batches,
                .draw_calls = stats.draw_calls,
                .vertices = stats.vertices,
                .vertex_bytes = stats.vertex_bytes,
                .buffers_used = stats.buffers_used,
                .textures_resident = stats.textures_resident,
                .views = stats.views,
            };
            return .ok;
        }
    };
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn validVec2(value: Vec2) bool {
    return finite(value.x) and finite(value.y);
}

fn validRect(value: Rect) bool {
    return finite(value.x) and finite(value.y) and finite(value.w) and finite(value.h);
}

fn validColor(value: Color) bool {
    return finite(value.r) and finite(value.g) and finite(value.b) and finite(value.a);
}

fn validCamera(value: Camera) bool {
    return validVec2(value.center) and finite(value.zoom) and finite(value.rotation) and
        validRect(value.viewport) and value.zoom > 0 and value.viewport.w > 0 and value.viewport.h > 0;
}

fn openTextureSlot(
    h: anytype,
    owned_asset: asset.AssetHandle,
) ?AbiTextureHandle {
    const start = h.render_texture_next % max_render_textures;
    var tried: u32 = 0;
    while (tried < max_render_textures) : (tried += 1) {
        const index_u32 = (start + tried) % max_render_textures;
        const index: usize = @intCast(index_u32);
        const slot = &h.render_textures[index];
        if (slot.active) continue;

        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.active = true;
        slot.asset = owned_asset;
        h.render_texture_next = (index_u32 + 1) % max_render_textures;
        return .{ .index = index_u32, .generation = slot.generation };
    }
    return null;
}

const TextureResolutionError = error{ InvalidHandle, InvalidArgument };

/// Resolves the current renderer payload for a wrapper. The slot intentionally retains only
/// the owned asset handle: a registry reload can replace its payload (and its loader/schema),
/// so a cached `TextureHandle` would either draw stale GPU state or cross renderer ownership.
fn resolveTexture(
    h: anytype,
    engine: anytype,
    renderer: *render2d.Renderer,
    handle: types.Texture,
) TextureResolutionError!render2d.TextureHandle {
    const slot = resolveTextureSlot(h, handle) orelse return error.InvalidHandle;
    const expected_loader = render2d.textureLoader(renderer);
    const loaded = engine.assets.getIfLoader(slot.asset, expected_loader) orelse {
        // Preserve the boundary's existing distinction: a changed record schema is an
        // invalid argument, while a stale/wrong-renderer payload is an invalid handle.
        const current = engine.assets.get(slot.asset) orelse return error.InvalidHandle;
        if (!current.schema_id.eql(expected_loader.schema)) return error.InvalidArgument;
        return error.InvalidHandle;
    };

    const texture = loaded.payload.asHandle(render2d.TextureHandle);
    if (renderer.textureSize(texture) == null) return error.InvalidHandle;
    return texture;
}

fn textureResolutionFailure(err: TextureResolutionError) Result {
    return switch (err) {
        error.InvalidHandle => .invalid_handle,
        error.InvalidArgument => .invalid_argument,
    };
}

/// Creation uses the same loader query as draw resolution. If it fails, inspect the asset
/// only to retain the public distinction between a wrong schema and wrong provenance.
fn textureProvenanceFailure(engine: anytype, handle: Asset, expected: asset.Loader) Result {
    const current = engine.assets.get(handle.unwrap(asset.AssetHandle)) orelse return .invalid_handle;
    if (!current.schema_id.eql(expected.schema)) return .invalid_argument;
    return .invalid_handle;
}

fn resolveTextureSlot(h: anytype, handle: types.Texture) ?*@TypeOf(h.render_textures[0]) {
    const raw = handle.unwrap(AbiTextureHandle);
    const bits = raw.bits();
    if (bits == 0) return null;

    const index: u32 = @truncate(bits);
    const generation: u32 = @truncate(bits >> 32);
    if (index >= max_render_textures or generation == 0) return null;

    const slot = &h.render_textures[@as(usize, @intCast(index))];
    if (!slot.active or slot.generation != generation) return null;
    return slot;
}

fn closeTextureSlot(slot: anytype) void {
    const generation = slot.generation;
    slot.* = .{};
    // A released handle must not become valid when the same slot is reused. The next open
    // increments this preserved generation before issuing a new wrapper.
    slot.generation = generation;
}

fn cameraValue(value: Camera) render2d.Camera2D {
    return .{
        .center = .init(value.center.x, value.center.y),
        .zoom = value.zoom,
        .rotation = value.rotation,
        .viewport = .init(value.viewport.x, value.viewport.y, value.viewport.w, value.viewport.h),
    };
}

fn fromCamera(value: render2d.Camera2D) Camera {
    return .{
        .center = .{ .x = value.center.x, .y = value.center.y },
        .zoom = value.zoom,
        .rotation = value.rotation,
        .viewport = .{ .x = value.viewport.x, .y = value.viewport.y, .w = value.viewport.w, .h = value.viewport.h },
    };
}

fn vec2Value(value: core.math.Vec2) Vec2 {
    return .{ .x = value.x, .y = value.y };
}

fn rectValue(value: Rect) core.math.Rect {
    return .init(value.x, value.y, value.w, value.h);
}

fn colorValue(value: Color) render2d.Color {
    return .linear(value.r, value.g, value.b, value.a);
}

fn blendValue(code: i32) ?render2d.BlendMode {
    return switch (code) {
        0 => .alpha,
        1 => .additive,
        2 => .none,
        else => null,
    };
}

fn spriteValue(value: Sprite, texture: render2d.TextureHandle) !render2d.Sprite {
    const blend = blendValue(value.blend) orelse return error.InvalidArgument;
    if (!validVec2(value.position) or !validVec2(value.size) or !validRect(value.uv) or
        !validVec2(value.origin) or !finite(value.rotation) or !validColor(value.tint))
    {
        return error.InvalidArgument;
    }

    return .{
        .texture = texture,
        .position = .init(value.position.x, value.position.y),
        .size = .init(value.size.x, value.size.y),
        .uv = rectValue(value.uv),
        .origin = .init(value.origin.x, value.origin.y),
        .rotation = value.rotation,
        .tint = colorValue(value.tint),
        .layer = value.layer,
        .blend = blend,
        .flip_x = types.boolIn(value.flip_x),
        .flip_y = types.boolIn(value.flip_y),
    };
}

fn fontValue(value: Font, texture: render2d.TextureHandle) !render2d.BitmapFont {
    if (!validRect(value.uv) or value.first_codepoint > max_codepoint) {
        return error.InvalidArgument;
    }

    const substitute: ?u21 = if (value.substitute == Font.no_codepoint)
        null
    else if (value.substitute <= max_codepoint)
        @intCast(value.substitute)
    else
        return error.InvalidArgument;

    // `BitmapFont.cellRegion` calculates the grid origin products as u32 and Region.sub
    // clamps each cell to the source region. Refuse a grid whose final cell would wrap or
    // be silently truncated, since the descriptor came from a mod and cannot reach an
    // engine assertion. The arithmetic is widened before comparing it with the region.
    if (value.glyph_count != 0) {
        if (value.columns == 0 or value.cell_width == 0 or value.cell_height == 0) {
            return error.InvalidArgument;
        }
        const columns_used: u64 = @min(value.glyph_count, value.columns);
        const rows_used: u64 = (@as(u64, value.glyph_count) - 1) / value.columns + 1;
        const grid_width = columns_used * value.cell_width;
        const grid_height = rows_used * value.cell_height;
        if (grid_width > std.math.maxInt(u32) or grid_height > std.math.maxInt(u32) or
            grid_width > value.width or grid_height > value.height)
        {
            return error.InvalidArgument;
        }
    }

    return .{
        .glyphs = .{
            .texture = texture,
            .uv = rectValue(value.uv),
            .size_px = .{ .width = value.width, .height = value.height },
        },
        .cell = .{ .width = value.cell_width, .height = value.cell_height },
        .columns = value.columns,
        .first_codepoint = @intCast(value.first_codepoint),
        .glyph_count = value.glyph_count,
        .substitute = substitute,
    };
}

fn textOptionsValue(value: TextOptions) !render2d.TextOptions {
    const blend = blendValue(value.blend) orelse return error.InvalidArgument;
    if (!validVec2(value.position) or !finite(value.scale) or !validColor(value.tint) or
        !finite(value.letter_spacing) or !finite(value.line_spacing))
    {
        return error.InvalidArgument;
    }

    return .{
        .position = .init(value.position.x, value.position.y),
        .scale = value.scale,
        .tint = colorValue(value.tint),
        .layer = value.layer,
        .blend = blend,
        .letter_spacing = value.letter_spacing,
        .line_spacing = value.line_spacing,
    };
}

fn viewDescValue(value: ViewDesc) !render2d.ViewDesc {
    return switch (value.kind) {
        0 => blk: {
            if (!validCamera(value.camera)) return error.InvalidArgument;
            break :blk .{ .camera = cameraValue(value.camera) };
        },
        1 => blk: {
            if (!validRect(value.screen) or value.screen.w <= 0 or value.screen.h <= 0) {
                return error.InvalidArgument;
            }
            break :blk .{ .screen = rectValue(value.screen) };
        },
        else => error.InvalidArgument,
    };
}

fn viewGeneration(renderer: *const render2d.Renderer) u32 {
    return normalizeGeneration(renderer.viewGeneration());
}

fn normalizeGeneration(value: anytype) u32 {
    const low: u32 = @truncate(@as(u64, @intCast(value)));
    return if (low == 0) 1 else low;
}

fn assetAcquireFailure(err: asset.AcquireError) Result {
    return switch (err) {
        error.AssetNotFound, error.SourceMissing => .not_found,
        error.WrongSchema, error.SourceRejected => .invalid_argument,
        error.NoLoader => .unavailable,
        error.UnsupportedVersion => .unsupported,
        error.InvalidAsset => .invalid_argument,
        error.LoadFailed => .internal,
        error.OutOfMemory => .out_of_memory,
    };
}

fn renderFailure(err: anyerror) Result {
    return switch (err) {
        error.InvalidTexture => .invalid_handle,
        error.InvalidAtlas => .invalid_handle,
        error.InvalidView => .invalid_handle,
        error.InvalidCamera => .invalid_argument,
        error.NotRecording => .refused,
        error.TooManyViews => .limit,
        error.TextureTooLarge => .limit,
        error.AtlasFull => .limit,
        error.RegionTooLarge => .limit,
        error.OutOfMemory => .out_of_memory,
        else => Result.fromError(err),
    };
}

test "render input conversion rejects non-finite values before render2d" {
    const bad: Sprite = .{ .texture = .{ .bits = 1 }, .position = .{ .x = std.math.nan(f32) } };
    try std.testing.expectError(error.InvalidArgument, spriteValue(bad, .none));

    const bad_camera: Camera = .{ .viewport = .{ .w = std.math.inf(f32), .h = 1 } };
    try std.testing.expect(!validCamera(bad_camera));
}

test "render font conversion refuses multiplication overflow" {
    const bad: Font = .{
        .cell_width = std.math.maxInt(u32),
        .cell_height = 1,
        .columns = 3,
        .glyph_count = 3,
    };
    try std.testing.expectError(error.InvalidArgument, fontValue(bad, .none));
}

test "render texture slots invalidate stale wrappers and preserve generation" {
    const Fixture = struct {
        render_textures: [max_render_textures]RenderTextureSlot = @splat(.{}),
        render_texture_next: u32 = 0,
    };

    var fixture: Fixture = .{};
    const owned_asset = asset.AssetHandle.fromBits(@as(u64, 3) | (@as(u64, 7) << 32));

    const first = openTextureSlot(&fixture, owned_asset).?;
    const first_public: types.Texture = .wrap(first);
    const slot = resolveTextureSlot(&fixture, first_public).?;
    try std.testing.expect(slot.active);
    try std.testing.expect(slot.asset.eql(owned_asset));

    closeTextureSlot(slot);
    try std.testing.expect(resolveTextureSlot(&fixture, first_public) == null);

    // Opening another slot is allowed to use a different index, whose independent
    // generation may happen to match. Force reuse of this exact slot to prove that the
    // released wrapper cannot become valid again.
    fixture.render_texture_next = first.index;
    const second = openTextureSlot(&fixture, owned_asset).?;
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.generation != first.generation);
}

test "render text rejects malformed UTF-8 before resolving renderer handles" {
    const testing = std.testing;
    const host_mod = @import("host.zig");
    const test_engine = @import("test_engine.zig");
    const audio = @import("audio");
    const Host = host_mod.HostWithMixer(test_engine.TestEngine, audio.Mixer);
    const Calls = Of(Host);

    // No device is needed: malformed input must be rejected before the texture or renderer
    // is touched. The renderer pointer is therefore an intentionally uninitialised sentinel;
    // reaching it would be a test failure rather than a valid execution path.
    var renderer: render2d.Renderer = undefined;
    var host: Host = .{ .renderer = &renderer };
    host.bind();
    defer host.unbind();

    const invalid = [_]u8{0xff};
    var font: Font = .{ .texture = .none };
    var options: TextOptions = .{};
    try testing.expectEqual(Result.invalid_argument, Calls.renderDrawText(
        &font,
        Str.from(&invalid),
        &options,
    ));
}
