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
pub fn textureLoader(renderer: *Renderer) asset.Loader {
    return .{
        .schema = asset.schemas.texture.id,
        .ctx = renderer,
        .load = load,
        .unload = unload,
    };
}

fn load(
    ctx: ?*anyopaque,
    gpa: Allocator,
    record: asset.Record,
    bytes: []const u8,
) asset.LoadError!asset.Payload {
    const renderer: *Renderer = @ptrCast(@alignCast(ctx.?));
    const caps = renderer.device.capabilities();

    // Bounded by what this device can actually hold, rather than by the decoder's generic
    // ceiling. An image too large to become a texture is refused before it is expanded,
    // instead of after 64 MiB has been allocated to find out.
    var image = asset.png.decode(gpa, bytes, .{
        .max_dimension = caps.max_texture_dimension,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // A valid PNG this decoder does not handle — the file is fine and the answer for
        // the author is different, which is the distinction `UnsupportedVersion` carries.
        error.UnsupportedImage => error.UnsupportedVersion,
        error.ImageTooLarge => error.LoadFailed,
        error.InvalidImage => error.InvalidAsset,
    };
    defer image.deinit(gpa);

    const handle = renderer.createTexture(image, .{
        .filter = filterOf(record),
        .wrap = wrapOf(record),
        .label = record.name,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Not the content's fault and not a version: the device said no.
        else => error.LoadFailed,
    };
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

/// One sampler field, read as an enum whose tag names *are* its spelling in content.
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

test "every sampler spelling a schema default names is one the renderer accepts" {
    // The defaults are declared in `asset` and consumed here, in two modules that cannot
    // see each other's constants. A default nothing here recognises would silently become
    // this function's fallback and look correct, so the agreement is checked rather than
    // assumed.
    inline for (.{
        .{ Filter, asset.schemas.filter_field },
        .{ Wrap, asset.schemas.wrap_field },
    }) |pair| {
        const index = asset.schemas.texture.fieldIndex(pair[1]).?;
        const declared = asset.schemas.texture.fields[index].presence.default.string;
        try testing.expect(std.meta.stringToEnum(pair[0], declared) != null);
    }
}
