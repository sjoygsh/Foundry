//! Public render handles retain asset identity, not a copied renderer handle.
//!
//! These are integration tests because the behaviour crosses the ABI, asset registry and
//! render2d. A renderer texture handle is meaningful only to the renderer whose loader made
//! it, and an asset reload may replace that handle in place.

const std = @import("std");

const abi = @import("abi");
const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const render2d = @import("render2d");
const rhi = @import("rhi");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const Engine = app.EngineOf(platform.null_backend.Platform, rhi.null_backend.Device);
const Host = abi.HostOf(Engine);
const Table = abi.TableOf(Host);

const texture_id = core.ContentId.fromString("foundry:textures.sprites");
const texture_source =
    \\foundry:texture foundry:textures.sprites { source "textures/sprites.png" }
;

const one_pixel_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x38, 0xA1, 0x61, 0xF3,
    0x1F, 0x00, 0x05, 0x14, 0x02, 0x2C, 0xC2, 0x0E, 0x5D, 0x14, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

const four_pixel_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xB6, 0x0D, 0x24, 0x00, 0x00, 0x00,
    0x1B, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x38, 0xA1, 0x61, 0xF3,
    0x5F, 0xE4, 0x44, 0xC0, 0x7F, 0x06, 0x0D, 0x9B, 0x13, 0xFF, 0xFF, 0xFF,
    0x67, 0xF8, 0x0F, 0x00, 0x4D, 0xA1, 0x09, 0x7F, 0x63, 0xEE, 0x64, 0x39,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

const Fixture = struct {
    gpa: Allocator,
    engine: *Engine,
    renderer_a: *render2d.Renderer,
    renderer_b: *render2d.Renderer,
    host: Host,
    dir: []u8,
    package_bytes: std.ArrayList([]u8) = .empty,

    fn init() !*Fixture {
        const gpa = testing.allocator;
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .engine = try Engine.init(gpa, .{ .headless = true, .hot_reload = false }),
            .renderer_a = undefined,
            .renderer_b = undefined,
            .host = .{},
            .dir = undefined,
        };
        errdefer self.engine.deinit();

        const temp = try self.engine.os.tempDirAlloc(gpa);
        defer gpa.free(temp);
        self.dir = try platform.os.joinPath(gpa, &.{ temp, "foundry-abi-render" });
        errdefer gpa.free(self.dir);
        try self.engine.os.createDirPath(self.dir);

        try self.addPackage("foundry:content", texture_source);
        try self.writeImage(&one_pixel_png);

        self.renderer_a = try gpa.create(render2d.Renderer);
        self.renderer_a.* = try render2d.Renderer.init(gpa, self.engine.gpu, .{ .quads_per_buffer = 8 });
        errdefer self.renderer_a.deinit();
        self.renderer_b = try gpa.create(render2d.Renderer);
        self.renderer_b.* = try render2d.Renderer.init(gpa, self.engine.gpu, .{ .quads_per_buffer = 8 });
        errdefer self.renderer_b.deinit();

        try self.engine.assets.registerLoader(gpa, render2d.textureLoader(self.renderer_a));
        self.host = .{ .engine = self.engine, .renderer = self.renderer_a };
        self.host.bind();
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.host.unbind();
        _ = self.engine.assets.unregisterLoader(self.gpa, asset.schemas.texture.id);
        self.renderer_b.deinit();
        self.gpa.destroy(self.renderer_b);
        self.renderer_a.deinit();
        self.gpa.destroy(self.renderer_a);
        self.engine.deinit();
        for (self.package_bytes.items) |bytes| self.gpa.free(bytes);
        self.package_bytes.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.gpa.destroy(self);
    }

    fn writeImage(self: *Fixture, bytes: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ self.dir, "textures/sprites.png" });
        defer self.gpa.free(path);
        try self.engine.os.createDirPath(std.fs.path.dirname(path).?);
        try self.engine.os.writeFile(path, bytes);
    }

    fn addPackage(self: *Fixture, name: []const u8, source: []const u8) !void {
        var diags: data.Diagnostics = .init(self.gpa, .default);
        defer diags.deinit(self.gpa);
        var doc = try data.parser.parse(self.gpa, "test.fdt", source, .{
            .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
        }, &diags);
        defer doc.deinit(self.gpa);
        var pkg = try data.check.Package.init(self.gpa, name, 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.engine.schemas, &diags);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        try data.fpk.write(self.gpa, &pkg, &self.engine.schemas, &bytes);
        const package_bytes = try bytes.toOwnedSlice(self.gpa);
        try self.package_bytes.append(self.gpa, package_bytes);
        const package = try self.engine.store.add(
            self.gpa,
            name,
            package_bytes,
            &self.engine.schemas,
            &diags,
        );
        try self.engine.assets.mount(self.gpa, package, self.dir);
    }

    fn drawSetup(self: *Fixture) !void {
        try self.renderer_a.begin(.{ .camera = .{ .viewport = .init(0, 0, 64, 64) } });
    }
};

test "ABI texture wrappers reject another renderer and follow an asset reload" {
    const f = try Fixture.init();
    defer f.deinit();

    var asset_handle: abi.Asset = .none;
    try testing.expectEqual(abi.Result.ok, Table.v1.asset_acquire(texture_id, &asset_handle));

    f.host.renderer = f.renderer_b;
    var wrong_renderer_texture: abi.Texture = .none;
    try testing.expectEqual(
        abi.Result.invalid_handle,
        Table.v1.render_texture_of_asset(asset_handle, &wrong_renderer_texture),
    );

    f.host.renderer = f.renderer_a;
    var wrapper: abi.Texture = .none;
    try testing.expectEqual(abi.Result.ok, Table.v1.render_texture_of_asset(asset_handle, &wrapper));
    try testing.expectEqual(abi.Result.ok, Table.v1.asset_release(asset_handle));

    const owned = asset_handle.unwrap(asset.AssetHandle);
    const before = f.engine.assets.get(owned).?.payload.bits;
    try f.drawSetup();
    var sprite: abi.RenderSprite = .{ .texture = wrapper, .size = .{ .x = 8, .y = 8 } };
    try testing.expectEqual(abi.Result.ok, Table.v1.render_draw_sprite(&sprite));

    try f.writeImage(&four_pixel_png);
    try f.engine.assets.reload(f.gpa, owned);
    const after = f.engine.assets.get(owned).?.payload.bits;
    try testing.expect(before != after);
    try f.drawSetup();
    try testing.expectEqual(abi.Result.ok, Table.v1.render_draw_sprite(&sprite));

    f.host.renderer = f.renderer_b;
    try f.renderer_b.begin(.{ .camera = .{ .viewport = .init(0, 0, 64, 64) } });
    try testing.expectEqual(abi.Result.invalid_handle, Table.v1.render_draw_sprite(&sprite));

    f.host.renderer = f.renderer_a;
    try testing.expectEqual(abi.Result.ok, Table.v1.render_destroy_texture(wrapper));
}
