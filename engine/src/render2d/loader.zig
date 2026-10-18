//! The texture loader: `foundry:texture` records become GPU textures.
//!
//! **Registered from above, at runtime** (I6, `assets.md` §5). `asset` is L2 and cannot
//! know what a GPU texture is; `render2d` is L3 and does. So the record type lives down
//! there — a source path is not a GPU concept, and `fpack` has to read one without linking
//! a renderer — while the capability that turns it into a texture is registered upward into
//! the asset registry at startup. The dependency points down, the capability points up, and
//! a mod adding an asset kind the engine has never heard of does exactly the same thing.
//!
//! The payload is a `TextureHandle`, which the registry holds as an opaque word and never
//! looks inside. The renderer that made it is the only thing that frees it.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");

const renderer_mod = @import("renderer.zig");
const texture_mod = @import("texture.zig");

const Allocator = std.mem.Allocator;
const Filter = texture_mod.Filter;
const Renderer = renderer_mod.Renderer;
const TextureHandle = texture_mod.TextureHandle;
const Wrap = texture_mod.Wrap;
const log = core.log.scoped(.render2d);

/// The loader to hand `asset.Registry.registerLoader`.
///
/// `renderer` is borrowed for as long as the loader is registered, so the registry must be
/// torn down before the renderer is — the registry's `deinit` unloads through this.
///
/// Split (ADR-0062): the PNG decode and any mip chain off the main thread, through
/// `asset.texture_decode`, which `render3d` shares; the upload in the finish.
pub fn textureLoader(renderer: *Renderer) asset.Loader {
    return .{
        .schema = asset.schemas.texture.id,
        .ctx = renderer,
        .load = load,
        .unload = unload,
        .split = .{
            .decode_ctx = &renderer.texture_limits,
            .decode = asset.texture_decode.decode,
            .finish = finish,
            .discard = asset.texture_decode.discard,
        },
    };
}

fn load(
    ctx: ?*anyopaque,
    gpa: Allocator,
    record: asset.Record,
    bytes: []const u8,
) asset.LoadError!asset.Payload {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx.?));
    return textureLoader(renderer).loadWhole(gpa, record, bytes);
}

/// The decode bounded the image by this device's limit before it was expanded, rather than
/// after 64 MiB had been allocated to find out; what is left is the upload.
fn finish(
    ctx: ?*anyopaque,
    gpa: Allocator,
    record: asset.Record,
    decoded: asset.Decoded,
    budget: *asset.Budget,
) asset.LoadError!asset.Payload {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx.?));
    const texture = asset.texture_decode.of(decoded);
    const options: texture_mod.TextureOptions = .{
        .filter = filterOf(record),
        .wrap = wrapOf(record),
        // The decode read the same field with the same default, so its chain is in this space.
        .color_space = sampler(asset.ColorSpace, record, asset.schemas.color_space_field, .srgb),
        .mipmaps = texture.chain != null,
        .label = record.name,
    };
    const made = if (texture.chain) |chain|
        renderer.createTextureFromChain(chain, options)
    else
        renderer.createTexture(texture.image.?, options);
    const handle = made catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Not the content's fault and not a version: the device said no.
        else => error.LoadFailed,
    };
    budget.charge(texture.byteSize());
    asset.texture_decode.discard(gpa, decoded);
    return .fromHandle(handle);
}

fn unload(ctx: ?*anyopaque, gpa: Allocator, payload: asset.Payload) void {
    _ = gpa;
    const renderer: *Renderer = @ptrCast(@alignCast(ctx.?));
    renderer.destroyTexture(payload.asHandle(TextureHandle));
}

fn filterOf(record: asset.Record) Filter {
    return sampler(Filter, record, asset.schemas.filter_field, .nearest);
}

fn wrapOf(record: asset.Record) Wrap {
    return sampler(Wrap, record, asset.schemas.wrap_field, .clamp);
}

/// One enumerated field — a sampler mode or the colour space — read as an enum whose tag
/// names *are* its spelling in content.
///
/// One table rather than two: adding a filter mode means adding a tag, and the content
/// spelling follows, so the schema and the renderer cannot come to disagree about what is
/// legal — the same reason `data.FieldType` reads its own tag names.
///
/// **An unrecognised spelling warns and falls back.** It is a content mistake, and the
/// checker cannot catch it: the type list is closed and there is no enum type, so the
/// domain is only knowable here (`asset/schemas.zig`). Refusing the whole texture would
/// answer a typo with a missing sprite, which is the least diagnosable outcome available;
/// a wrong-looking sprite plus a line naming the field, the value and the legal set sends
/// the author to the right line.
fn sampler(comptime E: type, record: asset.Record, field: []const u8, default: E) E {
    const text = asset.schemas.stringField(record, asset.schemas.texture, field) orelse return default;
    return std.meta.stringToEnum(E, text) orelse {
        log.warn("texture '{s}': '{s}' is not a {s}; using {s}", .{
            record.name, text, field, @tagName(default),
        });
        return default;
    };
}

const testing = std.testing;

test "every spelling a schema default names is one the renderer accepts" {
    // The defaults are declared in `asset` and consumed here, in two modules that cannot
    // see each other's constants. A default nothing here recognises would silently become
    // this function's fallback and look correct, so the agreement is checked rather than
    // assumed.
    inline for (.{
        .{ Filter, asset.schemas.filter_field },
        .{ Wrap, asset.schemas.wrap_field },
        .{ asset.ColorSpace, asset.schemas.color_space_field },
    }) |pair| {
        const index = asset.schemas.texture.fieldIndex(pair[1]).?;
        const declared = asset.schemas.texture.fields[index].presence.default.string;
        try testing.expect(std.meta.stringToEnum(pair[0], declared) != null);
    }
}
