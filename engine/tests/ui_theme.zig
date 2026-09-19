//! A `foundry:ui_theme` record on disk to a skinned draw, through every module on the way.
//!
//! `.fdt` text and two PNGs become a package, the package a store, and the record a
//! `ui.Style`, a `ui.Skin`, a font and the walker's image table (ADR-0041). Each piece is
//! unit-tested where it lives; what only this can test is that `app` reads a record the
//! engine's schema checked, acquires its textures through the real loader, and hands the
//! kernel and the walker numbers they agree about.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const rhi = @import("rhi");
const asset = @import("asset");
const render2d = @import("render2d");
const ui = @import("ui");
const app = @import("app");

const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A PNG of one colour, `width` by `height`, in stored DEFLATE blocks: no compressor, and
/// bytes a test can predict.
fn solidPng(gpa: Allocator, width: u32, height: u32) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..height) |_| {
        try raw.append(gpa, 0);
        for (0..width) |_| try raw.appendSlice(gpa, &.{ 0xff, 0xff, 0xff, 0xff });
    }

    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var rest = raw.items;
    while (true) {
        const n: u16 = @intCast(@min(rest.len, 0xffff));
        const last = rest.len == n;
        try z.append(gpa, if (last) 1 else 0);
        try z.appendSlice(gpa, &.{ @truncate(n), @truncate(n >> 8), @truncate(~n), @truncate(~n >> 8) });
        try z.appendSlice(gpa, rest[0..n]);
        rest = rest[n..];
        if (last) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw.items), .big);
    try z.appendSlice(gpa, &adler);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(gpa, &out, "IHDR", &ihdr);
    try chunk(gpa, &out, "IDAT", z.items);
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, bytes: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(bytes.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, bytes);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(bytes);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(gpa, &sum);
}

/// The whole stack, as `asset_pipeline.zig` assembles it, with the theme's schema too.
const Stack = struct {
    gpa: Allocator,
    os: *platform.os.Os,
    tmp: std.testing.TmpDir,
    dir: []u8,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    /// Every package's bytes, which the store borrows for as long as it holds the package.
    packages: std.ArrayList([]u8) = .empty,
    device: *rhi.Device,
    renderer: render2d.Renderer,
    assets: asset.Registry,

    fn init() !*Stack {
        const gpa = testing.allocator;
        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-ui-theme", .env = &.{} });
        errdefer os.deinit();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(testing.io, &path_buf);
        const dir = try gpa.dupe(u8, path_buf[0..path_len]);
        errdefer gpa.free(dir);
        const device = try rhi.Device.init(gpa, .{});
        errdefer device.deinit();

        const self = try gpa.create(Stack);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .os = os,
            .tmp = tmp,
            .dir = dir,
            .schemas = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
            .device = device,
            .renderer = try render2d.Renderer.init(gpa, device, .{ .quads_per_buffer = 64 }),
            .assets = undefined,
        };
        self.assets = .init(gpa, os, &self.store, .{});
        try asset.schemas.registerAll(gpa, &self.schemas);
        try asset.ui_theme.registerAll(gpa, &self.schemas);
        try self.assets.registerLoader(gpa, render2d.textureLoader(&self.renderer));

        // A 64x32 atlas and the 128x48 shape of the debug font.
        for ([_]struct { []const u8, u32, u32 }{ .{ "textures/atlas.png", 64, 32 }, .{ "textures/font.png", 128, 48 } }) |image| {
            const png = try solidPng(gpa, image[1], image[2]);
            defer gpa.free(png);
            try self.writeFile(image[0], png);
        }
        return self;
    }

    fn deinit(self: *Stack) void {
        self.assets.deinit(self.gpa);
        self.renderer.deinit();
        self.device.deinit();
        self.store.deinit(self.gpa);
        self.schemas.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        for (self.packages.items) |bytes| self.gpa.free(bytes);
        self.packages.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.os.deinit();
        self.tmp.cleanup();
        self.gpa.destroy(self);
    }

    fn writeFile(self: *Stack, rel: []const u8, contents: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ self.dir, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    fn loadPackage(self: *Stack, name: []const u8, source: []const u8) !void {
        var doc = try data.parser.parse(self.gpa, "content.fdt", source, .{
            .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
        }, &self.diags);
        defer doc.deinit(self.gpa);
        var pkg = try data.check.Package.init(self.gpa, name, 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.schemas, &self.diags);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        try data.fpk.write(self.gpa, &pkg, &self.schemas, &bytes);
        try self.packages.ensureUnusedCapacity(self.gpa, 1);
        const owned = try bytes.toOwnedSlice(self.gpa);
        self.packages.appendAssumeCapacity(owned);
        const handle = try self.store.add(self.gpa, name, owned, &self.schemas, &self.diags);
        try self.assets.mount(self.gpa, handle, self.dir);
    }

    fn freshDiagnostics(self: *Stack) void {
        self.diags.deinit(self.gpa);
        self.diags = .init(self.gpa, .default);
    }

    fn resolve(self: *Stack, id: []const u8) !?app.UiTheme {
        return app.resolveUiTheme(self.gpa, &self.store, &self.assets, &self.renderer, core.ContentId.fromString(id), &self.diags);
    }
};

const textures =
    \\foundry:texture t:textures.atlas { source "textures/atlas.png" }
    \\foundry:texture t:textures.font  { source "textures/font.png" }
    \\
;

/// A theme whose every field is valid. The malformed ones below are this with one thing
/// changed, so each proves its field alone refuses the theme.
const base_theme =
    \\foundry:ui_theme t:ui.theme {
    \\    atlas t:textures.atlas
    \\    font { texture t:textures.font  cell_w 8  cell_h 8  columns 16  count 95 }
    \\    text_scale 1.5
    \\    line_height 20
    \\    padding_x 10
    \\    padding_y 8
    \\    spacing 5
    \\    disabled_alpha 0.4
    \\    patch_scale 2
    \\    colors { text 0xffe2b4f0  text_dim 0x96826ec8  surface 0x0a0806e1  control 0x2e261eeb
    \\             control_hot 0x4a3c2cf5  control_active 0x6e583cff  accent 0xffbe6eff
    \\             positive 0x7ccf7cff  negative 0xe06a5aff  warning 0xf0c050ff  selection 0xffbe6e60 }
    \\    patches [
    \\        { part "panel"  x 0  y 0  w 12  h 12  left 4  top 4  right 4  bottom 4 }
    \\        { part "button" x 12 y 0  w 12  h 12  left 4  top 4  right 4  bottom 4 }
    \\        { part "gauge"  x 24 y 0  w 12  h 12 }
    \\    ]
    \\    icons [ { name "lock"  x 0  y 16  w 8  h 8 }  { name "warning"  x 8  y 16  w 8  h 8 } ]
    \\}
    \\
;

fn srgb(packed_rgba: u32) ui.Color {
    const c = render2d.Color.srgb8(@truncate(packed_rgba >> 24), @truncate(packed_rgba >> 16), @truncate(packed_rgba >> 8), @truncate(packed_rgba));
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

test "a valid theme resolves into a style, a skin, a font and the walker's table, and draws" {
    const stack = try Stack.init();
    defer stack.deinit();
    try stack.loadPackage("t:content", textures ++ base_theme);

    var theme = (try stack.resolve("t:ui.theme")).?;
    defer theme.deinit(&stack.assets);
    try testing.expectEqual(@as(usize, 0), stack.diags.count());

    const style = theme.style;
    try testing.expectEqual(@as(f32, 1.5), style.text_scale);
    try testing.expectEqual(@as(f32, 20), style.line_height);
    try testing.expectEqual(core.math.Vec2.init(10, 8), style.padding);
    try testing.expectEqual(@as(f32, 5), style.spacing);
    try testing.expectEqual(@as(f32, 0.4), style.disabled_alpha);
    // Not in the theme, so the kernel's own default.
    try testing.expectEqual(@as(f32, 1), style.separator_thickness);
    try testing.expectEqual(srgb(0xffe2b4f0), style.text);
    try testing.expectEqual(srgb(0x6e583cff), style.control_active);
    // The metrics the kernel measures with are the font the walker draws with.
    try testing.expectEqual(theme.font.metrics(), style.font);
    try testing.expectEqual(@as(u32, 95), theme.font.font.glyph_count);
    try testing.expectEqual(@as(u21, ' '), theme.font.font.first_codepoint);

    const skin = theme.skin;
    try testing.expectEqual(@as(f32, 2), skin.patch_scale);
    const panel = skin.patch(.panel).?;
    try testing.expectEqual(ui.ImageSource{ .image = app.UiTheme.atlas, .x = 0, .y = 0, .w = 12, .h = 12 }, panel.source);
    try testing.expectEqual(ui.Insets.all(4), panel.insets);
    try testing.expectEqual(@as(u32, 12), skin.patch(.button).?.source.x);
    // A part the theme did not give, and one this engine does not know, which is ignored.
    try testing.expect(skin.patch(.button_hot) == null);
    try testing.expectEqual(@as(u32, 16), skin.icon("lock").?.y);
    try testing.expect(skin.icon("gauge") == null);
    try testing.expectEqual(srgb(0xf0c050ff), skin.warning);
    try testing.expectEqual(srgb(0xffbe6e60), skin.selection);

    // End to end: the panel patch, cut by the kernel and drawn by the walker from the atlas
    // the theme acquired.
    var list: ui.DrawList = .{};
    defer list.deinit(stack.gpa);
    try list.addNineSlice(stack.gpa, .init(0, 0, 200, 100), panel.source, panel.insets, skin.patch_scale, .white);
    try stack.renderer.begin(.{ .camera = .{ .viewport = .init(0, 0, 1280, 720) } });
    try app.drawUi(&list, &stack.renderer, theme.font, .screen, theme.drawOptions(0));
    try testing.expectEqual(@as(usize, 9), stack.renderer.batcher.items.items.len);
    try testing.expect(stack.renderer.batcher.items.items[0].sprite.texture.eql(theme.images[0]));
}

test "each malformed field refuses the whole theme with one warning naming it" {
    const stack = try Stack.init();
    defer stack.deinit();

    // Every variant is the base theme with one field broken, under an id of its own.
    const cases = [_]struct { find: []const u8, replace: []const u8, says: []const u8 }{
        .{ .find = "text_scale 1.5", .replace = "text_scale 0", .says = "text_scale" },
        .{ .find = "line_height 20", .replace = "line_height -3", .says = "line_height" },
        .{ .find = "patch_scale 2", .replace = "patch_scale 0", .says = "patch_scale" },
        .{ .find = "disabled_alpha 0.4", .replace = "disabled_alpha 1.5", .says = "disabled_alpha" },
        .{ .find = "cell_w 8", .replace = "cell_w 0", .says = "font" },
        .{ .find = "count 95", .replace = "count 400", .says = "font grid" },
        .{ .find = "atlas t:textures.atlas", .replace = "atlas t:textures.nowhere", .says = "atlas" },
        .{ .find = "atlas t:textures.atlas", .replace = "atlas t:ui.theme", .says = "atlas" },
        .{ .find = "texture t:textures.font", .replace = "texture t:textures.nowhere", .says = "font texture" },
        .{ .find = "x 12 y 0  w 12", .replace = "x 60 y 0  w 12", .says = "patch" },
        .{ .find = "left 4  top 4  right 4  bottom 4 }\n        { part \"gauge\"", .replace = "left 8  top 4  right 8  bottom 4 }\n        { part \"gauge\"", .says = "insets" },
        .{ .find = "part \"button\"", .replace = "part \"panel\"", .says = "part twice" },
        .{ .find = "name \"warning\"  x 8  y 16", .replace = "name \"warning\"  x 60  y 30", .says = "icon" },
        .{ .find = "name \"warning\"", .replace = "name \"lock\"", .says = "icon twice" },
    };

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(stack.gpa);
    try source.appendSlice(stack.gpa, textures);
    for (cases, 0..) |case, i| {
        const renamed = try std.fmt.allocPrint(stack.gpa, "t:ui.bad{d} {{", .{i});
        defer stack.gpa.free(renamed);
        const first = try std.mem.replaceOwned(u8, stack.gpa, base_theme, "t:ui.theme {", renamed);
        defer stack.gpa.free(first);
        try testing.expect(std.mem.indexOf(u8, first, case.find) != null);
        const broken = try std.mem.replaceOwned(u8, stack.gpa, first, case.find, case.replace);
        defer stack.gpa.free(broken);
        try source.appendSlice(stack.gpa, broken);
    }
    try stack.loadPackage("t:content", source.items);

    for (cases, 0..) |case, i| {
        stack.freshDiagnostics();
        var name_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&name_buf, "t:ui.bad{d}", .{i});
        try testing.expect(try stack.resolve(id) == null);
        try testing.expectEqual(@as(usize, 1), stack.diags.count());
        const message = stack.diags.items.items[0].message;
        if (std.mem.indexOf(u8, message, case.says) == null) {
            std.debug.print("case {d}: '{s}' does not mention '{s}'\n", .{ i, message, case.says });
            return error.TestUnexpectedResult;
        }
    }

    // And a theme nobody has, and a record that is not a theme.
    stack.freshDiagnostics();
    try testing.expect(try stack.resolve("t:ui.nothing") == null);
    try testing.expect(try stack.resolve("t:textures.atlas") == null);
    try testing.expectEqual(@as(usize, 2), stack.diags.count());
}

test "a later package's theme wins, and resolving again re-skins" {
    const stack = try Stack.init();
    defer stack.deinit();
    try stack.loadPackage("t:content", textures ++ base_theme);

    var before = (try stack.resolve("t:ui.theme")).?;
    defer before.deinit(&stack.assets);

    // A mod overrides the whole record, as content override always does: a new scale and a
    // new accent, the same atlas.
    const brighter = try std.mem.replaceOwned(u8, stack.gpa, base_theme, "text_scale 1.5", "text_scale 2");
    defer stack.gpa.free(brighter);
    const recoloured = try std.mem.replaceOwned(u8, stack.gpa, brighter, "accent 0xffbe6eff", "accent 0x55aaffff");
    defer stack.gpa.free(recoloured);
    try stack.loadPackage("mod:content", recoloured);

    var after = (try stack.resolve("t:ui.theme")).?;
    defer after.deinit(&stack.assets);
    try testing.expectEqual(@as(f32, 1.5), before.style.text_scale);
    try testing.expectEqual(@as(f32, 2), after.style.text_scale);
    try testing.expectEqual(srgb(0x55aaffff), after.style.accent);
    try testing.expectEqual(@as(usize, 0), stack.diags.count());
}
