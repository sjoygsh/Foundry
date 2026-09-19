//! `foundry:ui_theme` — how a game's screens look, as content (ADR-0041).
//!
//! ```fdt
//! foundry:ui_theme room:ui.theme {
//!     atlas       room:textures.ui           # a foundry:texture: every patch and icon
//!     font        { texture foundry:fonts.debug  cell_w 8  cell_h 8  columns 16  count 95 }
//!     text_scale  1.5
//!     line_height 20   padding_x 10   padding_y 8   spacing 5
//!     patch_scale 2                          # screen units per atlas pixel, for borders
//!     colors      { text 0xffe2b4f0  text_dim 0x96826ec8  ... }   # sRGB, 0xRRGGBBAA
//!     patches     [ { part "button"  x 0 y 0 w 12 h 12  left 4 top 4 right 4 bottom 4 } ]
//!     icons       [ { name "warning"  x 0 y 40 w 8 h 8 } ]
//! }
//! ```
//!
//! **A mechanism, not content** (I5). The record type is the engine's, registered at
//! runtime through the call a mod's `@schema` uses (I6). A game ships its theme in its own
//! package, and any later package may override the record whole.
//!
//! **It lives here, not beside the kernel**, for `asset.tilemap`'s reason: `fpack` has to
//! check a theme without linking a renderer, and `ui` sits at L1 with no `data` to hold a
//! schema in. `app` reads the record and builds `ui.Style` and `ui.Skin` from it.
//!
//! **Every name here is on authors' disks** (`CLAUDE.md` §7), fixed when ADR-0041 was
//! accepted and by this file's first version. Adding a field, a colour or a part later is
//! additive; renaming one is a break. The part names a patch may use are `ui.Skin`'s; an
//! unknown one is ignored, so a theme written for a later engine still loads.
//!
//! Design: `docs/design/mod-management.md` §10.

const std = @import("std");
const data = @import("data");

const Allocator = std.mem.Allocator;
const Field = data.Field;
const FieldType = data.FieldType;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;

pub const name = "foundry:ui_theme";

/// The font's glyph grid, read as `render2d.BitmapFont` reads one.
pub const font_fields = [_]Field{
    .{ .name = "texture", .type = .id },
    .{ .name = "cell_w", .type = .u32 },
    .{ .name = "cell_h", .type = .u32 },
    .{ .name = "columns", .type = .u32 },
    .{ .name = "first", .type = .u32, .presence = .{ .default = .{ .int = ' ' } } },
    .{ .name = "count", .type = .u32 },
    .{ .name = "letter_spacing", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    .{ .name = "line_spacing", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
};

/// Every colour a theme names, in this order: the seven `ui.Style` reads, then the four only
/// a game screen uses, which go to `ui.Skin`. Each is sRGB, packed `0xRRGGBBAA`, because
/// that is how a person writes a colour; the conversion to linear light happens above the
/// kernel, with the renderer's own function.
pub const color_names = [_][]const u8{
    "text",     "text_dim", "surface", "control",   "control_hot", "control_active", "accent",
    "positive", "negative", "warning", "selection",
};

pub const color_fields: [color_names.len]Field = blk: {
    var fields: [color_names.len]Field = undefined;
    for (&fields, color_names) |*f, n| f.* = .{ .name = n, .type = .u32 };
    break :blk fields;
};

/// One nine-slice patch of the atlas, for one of `ui.Skin`'s parts.
pub const patch_fields = [_]Field{
    .{ .name = "part", .type = .string },
    .{ .name = "x", .type = .u32 },
    .{ .name = "y", .type = .u32 },
    .{ .name = "w", .type = .u32 },
    .{ .name = "h", .type = .u32 },
    .{ .name = "left", .type = .u32, .presence = .{ .default = .{ .int = 0 } } },
    .{ .name = "top", .type = .u32, .presence = .{ .default = .{ .int = 0 } } },
    .{ .name = "right", .type = .u32, .presence = .{ .default = .{ .int = 0 } } },
    .{ .name = "bottom", .type = .u32, .presence = .{ .default = .{ .int = 0 } } },
};

/// One icon of the atlas, by the game's own name for it.
pub const icon_fields = [_]Field{
    .{ .name = "name", .type = .string },
    .{ .name = "x", .type = .u32 },
    .{ .name = "y", .type = .u32 },
    .{ .name = "w", .type = .u32 },
    .{ .name = "h", .type = .u32 },
};

const patch_type: FieldType = .{ .nested = &patch_fields };
const icon_type: FieldType = .{ .nested = &icon_fields };

pub const ui_theme: Schema = .{
    .id = SchemaId.fromStringUnchecked(name),
    .version = 1,
    .fields = &.{
        .{ .name = "atlas", .type = .id },
        .{ .name = "font", .type = .{ .nested = &font_fields } },
        .{ .name = "text_scale", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
        .{ .name = "line_height", .type = .f32 },
        .{ .name = "padding_x", .type = .f32 },
        .{ .name = "padding_y", .type = .f32 },
        .{ .name = "spacing", .type = .f32 },
        // Absent, these three are `ui.Style`'s own defaults.
        .{ .name = "separator", .type = .f32, .presence = .optional },
        .{ .name = "scrollbar", .type = .f32, .presence = .optional },
        .{ .name = "disabled_alpha", .type = .f32, .presence = .optional },
        .{ .name = "patch_scale", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
        .{ .name = "colors", .type = .{ .nested = &color_fields } },
        .{ .name = "patches", .type = .{ .list = &patch_type }, .presence = .optional },
        .{ .name = "icons", .type = .{ .list = &icon_type }, .presence = .optional },
    },
};

pub fn registerAll(gpa: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    _ = try registry.register(gpa, ui_theme);
}

const testing = std.testing;

test "the theme schema registers, twice without complaint" {
    var registry: Registry = .init(testing.allocator, .default);
    defer registry.deinit(testing.allocator);
    try registerAll(testing.allocator, &registry);
    try registerAll(testing.allocator, &registry);
    try testing.expect(registry.lookup(ui_theme.id) != null);
}

test "a theme compiles from text, and one missing a colour does not" {
    var registry: Registry = .init(testing.allocator, .default);
    defer registry.deinit(testing.allocator);
    try registerAll(testing.allocator, &registry);

    const colors = "colors { text 0xffffffff text_dim 0x808080ff surface 0x000000cc control 0x333333ff " ++
        "control_hot 0x444444ff control_active 0x555555ff accent 0x3366ffff positive 0x33cc33ff " ++
        "negative 0xcc3333ff warning 0xffcc00ff selection 0x3366ff80 }";
    const good = "foundry:ui_theme t:theme { atlas t:atlas font { texture t:font cell_w 8 cell_h 8 columns 16 count 95 } " ++
        "line_height 20 padding_x 4 padding_y 4 spacing 2 " ++ colors ++
        " patches [ { part \"button\" x 0 y 0 w 12 h 12 left 4 top 4 right 4 bottom 4 } ] icons [ { name \"lock\" x 0 y 16 w 8 h 8 } ] }";
    try testing.expect(try compiles(&registry, good));

    const missing = "foundry:ui_theme t:theme { atlas t:atlas font { texture t:font cell_w 8 cell_h 8 columns 16 count 95 } " ++
        "line_height 20 padding_x 4 padding_y 4 spacing 2 colors { text 0xffffffff } }";
    try testing.expect(!try compiles(&registry, missing));
}

fn compiles(registry: *Registry, source: []const u8) !bool {
    const gpa = testing.allocator;
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "theme.fdt", source, .{ .namespace = "t" }, &diags);
    defer doc.deinit(gpa);
    var package = try data.check.Package.init(gpa, "t:content", 1, .default);
    defer package.deinit(gpa);
    package.addDocument(gpa, &doc, registry, &diags) catch |err| switch (err) {
        error.ContentInvalid => return false,
        else => return err,
    };
    return !diags.failed;
}
