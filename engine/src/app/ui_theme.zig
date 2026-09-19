//! A `foundry:ui_theme` record, resolved into what the kernel and the walker take
//! (ADR-0041 decision 3).
//!
//! A theme is content, so a mod re-skins a game's screens by overriding one record. This is
//! where the record meets the textures loaded now: its atlas and font are acquired by content
//! id, every patch and icon is checked against the atlas as loaded, and the result is a
//! `ui.Style`, a `ui.Skin`, the `UiFont` the walker draws with, and the walker's image table.
//!
//! **A theme that cannot be used is one warning and the host's fallback**, never a failed
//! frame, which is `solidRegion`'s rule. Any field wrong in any way refuses the whole theme
//! and names that field: a theme half-applied is a screen nobody designed. `app` cannot see
//! `debug`, and the kernel has no style of its own, so the fallback is the host's built-in
//! style (`mod-management.md` §10).
//!
//! **Resolve again whenever content changes.** A theme holds the textures it acquired, and a
//! reload may have replaced the record, its atlas or its font. The host releases the old
//! theme and resolves the new one, which is how a reload re-skins a running screen.
//!
//! Design: `docs/design/mod-management.md` §10.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const render2d = @import("render2d");
const ui = @import("ui");

const ui_draw = @import("ui_draw.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const schema = asset.ui_theme;

/// How long an icon's name may be. A name is a key a game looks up, not text a player reads.
pub const max_icon_name = 64;

/// A theme, resolved. Holds its atlas and font textures until `deinit`.
pub const Theme = struct {
    style: ui.Style,
    skin: ui.Skin,
    font: ui_draw.Font,
    /// The walker's image table (`UiDrawOptions.images`). Its only entry is the atlas.
    images: [1]render2d.TextureHandle,
    held: [2]asset.AssetHandle,
    /// The icons' names, and the icons themselves.
    arena: std.heap.ArenaAllocator,

    /// Every patch and icon of the skin is drawn from this.
    pub const atlas: ui.ImageRef = .of(0);

    /// Releases the textures. `self` must not move while the skin or the table is in use:
    /// both point into it.
    pub fn deinit(self: *Theme, assets: *asset.Registry) void {
        for (self.held) |handle| assets.release(handle);
        self.arena.deinit();
        self.* = undefined;
    }

    /// The walker's options for a screen drawn with this theme.
    pub fn drawOptions(self: *const Theme, layer: i16) ui_draw.Options {
        return .{ .layer = layer, .images = &self.images };
    }
};

/// Resolves theme `id` against the content and textures loaded now, or returns null and adds
/// exactly one warning to `diags`, naming the theme and the first thing wrong with it.
pub fn resolve(
    gpa: Allocator,
    store: *const data.Store,
    assets: *asset.Registry,
    renderer: *render2d.Renderer,
    id: ContentId,
    diags: *data.Diagnostics,
) Allocator.Error!?Theme {
    var why: []const u8 = "";
    var label: []const u8 = "";
    return build(gpa, store, assets, renderer, id, &why, &label) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => {
            // By its spelling when a record was found; a theme nobody loaded has only its hash.
            if (label.len != 0) {
                try diags.addFmt(gpa, .warning, .whole("<ui theme>"), 0, "", "ui theme '{s}' {s}; using the fallback style", .{ label, why });
            } else {
                try diags.addFmt(gpa, .warning, .whole("<ui theme>"), 0, "", "ui theme {f} {s}; using the fallback style", .{ id, why });
            }
            return null;
        },
    };
}

const Error = error{Refused} || Allocator.Error;

fn refuse(why: *[]const u8, reason: []const u8) error{Refused} {
    why.* = reason;
    return error.Refused;
}

/// One block of fields and the declaration it is read against.
const Block = struct {
    fields: data.fpk.Fields,
    decl: []const data.Field,

    fn index(self: Block, name: []const u8) ?u32 {
        for (self.decl, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return @intCast(i);
        return null;
    }

    fn float(self: Block, name: []const u8) ?f32 {
        const raw = (self.fields.floatAt(self.index(name) orelse return null) catch null) orelse return null;
        const narrowed: f32 = @floatCast(raw);
        return if (std.math.isFinite(narrowed)) narrowed else null;
    }

    fn uint(self: Block, name: []const u8) ?u32 {
        const raw = (self.fields.intAt(self.index(name) orelse return null) catch null) orelse return null;
        return std.math.cast(u32, raw);
    }

    fn string(self: Block, name: []const u8) ?[]const u8 {
        return (self.fields.stringAt(self.index(name) orelse return null) catch null) orelse null;
    }

    fn id(self: Block, name: []const u8) ?ContentId {
        return (self.fields.idAt(self.index(name) orelse return null) catch null) orelse null;
    }

    fn nested(self: Block, name: []const u8) ?Block {
        const i = self.index(name) orelse return null;
        const inner = (self.fields.nestedAt(i) catch null) orelse return null;
        return .{ .fields = inner, .decl = self.decl[i].type.nested };
    }

    /// A list of inline structs, with the structs' declaration.
    fn list(self: Block, name: []const u8) ?struct { items: data.fpk.List, decl: []const data.Field } {
        const i = self.index(name) orelse return null;
        const items = (self.fields.listAt(i) catch null) orelse return null;
        return .{ .items = items, .decl = self.decl[i].type.list.nested };
    }
};

fn build(
    gpa: Allocator,
    store: *const data.Store,
    assets: *asset.Registry,
    renderer: *render2d.Renderer,
    id: ContentId,
    why: *[]const u8,
    label: *[]const u8,
) Error!Theme {
    const record = store.lookup(id) orelse return refuse(why, "is not loaded");
    label.* = record.name;
    if (!record.schema.id.eql(schema.ui_theme.id)) return refuse(why, "is not a foundry:ui_theme record");
    const top: Block = .{ .fields = record.fields, .decl = record.schema.fields };

    // Every number before any texture, so a malformed theme acquires nothing.
    const text_scale = positive(top.float("text_scale")) orelse return refuse(why, "has a text_scale that is not a positive number");
    const line_height = positive(top.float("line_height")) orelse return refuse(why, "has a line_height that is not a positive number");
    const padding_x = nonNegative(top.float("padding_x")) orelse return refuse(why, "has a padding_x that is not a number of zero or more");
    const padding_y = nonNegative(top.float("padding_y")) orelse return refuse(why, "has a padding_y that is not a number of zero or more");
    const spacing = nonNegative(top.float("spacing")) orelse return refuse(why, "has a spacing that is not a number of zero or more");
    const patch_scale = positive(top.float("patch_scale")) orelse return refuse(why, "has a patch_scale that is not a positive number");
    var style_extras: struct { separator: ?f32 = null, scrollbar: ?f32 = null, disabled_alpha: ?f32 = null } = .{};
    if (top.index("separator")) |i| if (top.fields.present(i)) {
        style_extras.separator = nonNegative(top.float("separator")) orelse return refuse(why, "has a separator that is not a number of zero or more");
    };
    if (top.index("scrollbar")) |i| if (top.fields.present(i)) {
        style_extras.scrollbar = positive(top.float("scrollbar")) orelse return refuse(why, "has a scrollbar that is not a positive number");
    };
    if (top.index("disabled_alpha")) |i| if (top.fields.present(i)) {
        const a = top.float("disabled_alpha") orelse return refuse(why, "has a disabled_alpha that is not a number");
        if (a < 0 or a > 1) return refuse(why, "has a disabled_alpha outside 0 to 1");
        style_extras.disabled_alpha = a;
    };

    const colors = top.nested("colors") orelse return refuse(why, "has no colors");
    var palette: [schema.color_names.len]ui.Color = undefined;
    for (&palette, schema.color_names) |*c, name| {
        c.* = colorOf(colors.uint(name) orelse {
            why.* = "is missing a colour, or has one that is not 0xRRGGBBAA";
            return error.Refused;
        });
    }

    const font_block = top.nested("font") orelse return refuse(why, "has no font");
    const cell_w = font_block.uint("cell_w") orelse 0;
    const cell_h = font_block.uint("cell_h") orelse 0;
    const columns = font_block.uint("columns") orelse 0;
    const glyph_count = font_block.uint("count") orelse 0;
    if (cell_w == 0 or cell_h == 0 or columns == 0 or glyph_count == 0) {
        return refuse(why, "has a font whose cell, columns or count is not a positive whole number");
    }
    const first = font_block.uint("first") orelse return refuse(why, "has a font whose first codepoint is not a number");
    if (@as(u64, first) + glyph_count - 1 > 0x10FFFF) return refuse(why, "has a font whose glyphs run past the last codepoint");
    const letter_spacing = font_block.float("letter_spacing") orelse 0;
    const line_spacing = font_block.float("line_spacing") orelse 0;

    // The textures, by content id and only as textures.
    const atlas_id = top.id("atlas") orelse return refuse(why, "has no atlas");
    const font_id = font_block.id("texture") orelse return refuse(why, "has a font with no texture");
    const atlas_handle = assets.acquireOf(gpa, atlas_id, asset.schemas.texture.id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(why, "has an atlas that is not a texture that loads"),
    };
    errdefer assets.release(atlas_handle);
    const font_handle = assets.acquireOf(gpa, font_id, asset.schemas.texture.id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(why, "has a font texture that is not a texture that loads"),
    };
    errdefer assets.release(font_handle);

    const atlas_texture = textureOf(assets, atlas_handle);
    const font_texture = textureOf(assets, font_handle);
    const atlas_size = renderer.textureSize(atlas_texture) orelse return refuse(why, "has an atlas with no texture behind it");
    const font_size = renderer.textureSize(font_texture) orelse return refuse(why, "has a font with no texture behind it");

    const rows = (glyph_count + columns - 1) / columns;
    if (@as(u64, columns) * cell_w > font_size.width or @as(u64, rows) * cell_h > font_size.height) {
        return refuse(why, "has a font grid larger than its texture");
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    var skin: ui.Skin = .{
        .patch_scale = patch_scale,
        .positive = palette[7],
        .negative = palette[8],
        .warning = palette[9],
        .selection = palette[10],
    };
    if (top.list("patches")) |patches| {
        var k: u32 = 0;
        while (k < patches.items.len) : (k += 1) {
            const entry: Block = .{ .fields = (patches.items.nestedAt(k) catch null) orelse return refuse(why, "has a patch that cannot be read"), .decl = patches.decl };
            const part_name = entry.string("part") orelse return refuse(why, "has a patch with no part");
            // A part this engine does not know is one a later engine added: ignored, so a
            // theme written for it still loads here.
            const part = std.meta.stringToEnum(ui.SkinPart, part_name) orelse continue;
            if (skin.patches.get(part) != null) return refuse(why, "names one part twice");
            const source = sourceIn(entry, atlas_size) orelse return refuse(why, "has a patch that is empty or not inside its atlas");
            const insets: ui.Insets = .{
                .left = entry.uint("left") orelse 0,
                .top = entry.uint("top") orelse 0,
                .right = entry.uint("right") orelse 0,
                .bottom = entry.uint("bottom") orelse 0,
            };
            if (@as(u64, insets.left) + insets.right > source.w or @as(u64, insets.top) + insets.bottom > source.h) {
                return refuse(why, "has a patch whose insets are wider or taller than it");
            }
            skin.patches.set(part, .{ .source = source, .insets = insets });
        }
    }
    if (top.list("icons")) |icons| {
        const out = try arena.allocator().alloc(ui.SkinIcon, icons.items.len);
        for (out, 0..) |*slot, k| {
            const entry: Block = .{ .fields = (icons.items.nestedAt(@intCast(k)) catch null) orelse return refuse(why, "has an icon that cannot be read"), .decl = icons.decl };
            const name = entry.string("name") orelse return refuse(why, "has an icon with no name");
            if (name.len == 0 or name.len > max_icon_name) return refuse(why, "has an icon whose name is empty or too long");
            for (out[0..k]) |earlier| if (std.mem.eql(u8, earlier.name, name)) return refuse(why, "names one icon twice");
            const source = sourceIn(entry, atlas_size) orelse return refuse(why, "has an icon that is empty or not inside its atlas");
            slot.* = .{ .name = try arena.allocator().dupe(u8, name), .source = source };
        }
        skin.icons = out;
    }

    const font: ui_draw.Font = .{
        .font = .{
            .glyphs = render2d.Region.whole(font_texture, font_size),
            .cell = .{ .width = cell_w, .height = cell_h },
            .columns = columns,
            .first_codepoint = @intCast(first),
            .glyph_count = glyph_count,
        },
        .letter_spacing = letter_spacing,
        .line_spacing = line_spacing,
    };
    var style: ui.Style = .{
        .font = font.metrics(),
        .text_scale = text_scale,
        .line_height = line_height,
        .padding = .init(padding_x, padding_y),
        .spacing = spacing,
        .text = palette[0],
        .text_dim = palette[1],
        .surface = palette[2],
        .control = palette[3],
        .control_hot = palette[4],
        .control_active = palette[5],
        .accent = palette[6],
    };
    if (style_extras.separator) |v| style.separator_thickness = v;
    if (style_extras.scrollbar) |v| style.scrollbar = v;
    if (style_extras.disabled_alpha) |v| style.disabled_alpha = v;

    return .{
        .style = style,
        .skin = skin,
        .font = font,
        .images = .{atlas_texture},
        .held = .{ atlas_handle, font_handle },
        .arena = arena,
    };
}

/// A patch's or an icon's rectangle, when it is non-empty and wholly inside the atlas.
fn sourceIn(entry: Block, size: render2d.Extent2D) ?ui.ImageSource {
    const x = entry.uint("x") orelse return null;
    const y = entry.uint("y") orelse return null;
    const w = entry.uint("w") orelse return null;
    const h = entry.uint("h") orelse return null;
    if (w == 0 or h == 0) return null;
    if (@as(u64, x) + w > size.width or @as(u64, y) + h > size.height) return null;
    return .{ .image = Theme.atlas, .x = x, .y = y, .w = w, .h = h };
}

fn positive(v: ?f32) ?f32 {
    const value = v orelse return null;
    return if (value > 0) value else null;
}

fn nonNegative(v: ?f32) ?f32 {
    const value = v orelse return null;
    return if (value >= 0) value else null;
}

/// `0xRRGGBBAA` in sRGB, into the kernel's linear light through the renderer's own transfer
/// function: above the seam, where the conversion belongs (`ui/style.zig`).
fn colorOf(packed_rgba: u32) ui.Color {
    const c = render2d.Color.srgb8(
        @truncate(packed_rgba >> 24),
        @truncate(packed_rgba >> 16),
        @truncate(packed_rgba >> 8),
        @truncate(packed_rgba),
    );
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// The registry holds a loader's product as one opaque word; `render2d` put a
/// `TextureHandle` there.
fn textureOf(assets: *asset.Registry, handle: asset.AssetHandle) render2d.TextureHandle {
    const payload = assets.payloadOf(handle) orelse return .none;
    return payload.asHandle(render2d.TextureHandle);
}

const testing = std.testing;

test "a packed colour is sRGB, converted by the renderer's own function" {
    const c = colorOf(0xffe2b4f0);
    const want = render2d.Color.srgb8(0xff, 0xe2, 0xb4, 0xf0);
    try testing.expectEqual(want.r, c.r);
    try testing.expectEqual(want.g, c.g);
    try testing.expectEqual(want.b, c.b);
    try testing.expectEqual(want.a, c.a);
}
