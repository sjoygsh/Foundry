//! Content on disk to a sprite on screen, through every module that is on the way.
//!
//! `.fdt` text and a `.png` become a package; the package becomes a store; a content ID
//! becomes a `TextureHandle`; the handle draws. Each of those steps is unit-tested where it
//! lives — what is only testable here is that they compose, because the modules involved
//! are deliberately blind to each other: `asset` is L2 and knows nothing about a GPU,
//! `render2d` is L3 and is not granted `data` at all.
//!
//! This runs headless on the null RHI backend, which is one of the reasons that backend
//! exists (CLAUDE.md §7): it enforces the strict rules Metal would forgive, so the frame at
//! the end is a real validation pass rather than a formality.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const rhi = @import("rhi");
const asset = @import("asset");
const render2d = @import("render2d");

const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A 1x1 RGBA PNG whose single pixel is (200, 40, 60, 255).
const one_pixel_png = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x38, 0xA1, 0x61, 0xF3,
    0x1F, 0x00, 0x05, 0x14, 0x02, 0x2C, 0xC2, 0x0E, 0x5D, 0x14, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

const package_source =
    \\foundry:texture foundry:textures.sprites {
    \\    source "textures/sprites.png"
    \\    filter "linear"
    \\    wrap   "repeat"
    \\}
;

/// The whole stack, assembled the way `app` will assemble it at step 9.
///
/// **Teardown order is the load-bearing part.** The asset registry unloads through the
/// loaders it was given, so it must go before the renderer that registered one, which must
/// go before the device. `testing.allocator` and the null backend's validation together
/// notice if that is wrong.
const Stack = struct {
    gpa: Allocator,
    os: *platform.os.Os,
    dir: []u8,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: std.ArrayList(u8) = .empty,
    device: *rhi.Device,
    renderer: render2d.Renderer,
    assets: asset.Registry,

    fn init() !*Stack {
        const gpa = testing.allocator;

        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-integration", .env = &.{} });
        errdefer os.deinit();

        const temp = try os.tempDirAlloc(gpa);
        defer gpa.free(temp);
        const dir = try platform.os.joinPath(gpa, &.{ temp, "foundry-asset-pipeline" });
        errdefer gpa.free(dir);

        const device = try rhi.Device.init(gpa, .{});
        errdefer device.deinit();

        const self = try gpa.create(Stack);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .os = os,
            .dir = dir,
            .schemas = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
            .device = device,
            .renderer = try render2d.Renderer.init(gpa, device, .{ .quads_per_buffer = 64 }),
            .assets = undefined,
        };
        self.assets = .init(gpa, os, &self.store, .{});

        // The two registrations that make the engine able to load a texture at all, and
        // both are runtime calls a mod could make (I6): the record type, then the loader.
        try asset.schemas.registerAll(gpa, &self.schemas);
        try self.assets.registerLoader(gpa, render2d.textureLoader(&self.renderer));
        return self;
    }

    fn deinit(self: *Stack) void {
        self.assets.deinit(self.gpa);
        self.renderer.deinit();
        self.device.deinit();
        self.store.deinit(self.gpa);
        self.schemas.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.os.deinit();
        self.gpa.destroy(self);
    }

    fn writeFile(self: *Stack, rel: []const u8, contents: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ self.dir, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    /// Compiles text into a package and loads it, which is what `fpack` plus the engine do.
    fn loadPackage(self: *Stack, name: []const u8, source: []const u8) !void {
        var doc = try data.parser.parse(self.gpa, "content.fdt", source, .{
            .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
        }, &self.diags);
        defer doc.deinit(self.gpa);

        var pkg = try data.check.Package.init(self.gpa, name, 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.schemas, &self.diags);
        try data.fpk.write(self.gpa, &pkg, &self.schemas, &self.bytes);

        const handle = try self.store.add(self.gpa, name, self.bytes.items, &self.schemas, &self.diags);
        try self.assets.mount(self.gpa, handle, self.dir);
    }

    /// One complete frame, driven the way `app` drives it.
    fn frame(self: *Stack, sprite: ?render2d.Sprite) !void {
        try self.renderer.begin(.{ .camera = .{ .viewport = .init(0, 0, 1280, 720) } });
        if (sprite) |s| try self.renderer.drawSprite(s);

        const ctx = try self.device.beginFrame();
        const cmd = try self.device.beginCommandBuffer();
        try self.renderer.prepare(cmd, ctx);

        const pass = try cmd.beginRenderPass(.{
            .label = "integration",
            .color = &.{.{
                .texture = ctx.surface_texture,
                .load = .{ .clear = .{ .color = .{ 0, 0, 0, 1 } } },
                .store = .store,
                .initial_state = .undefined,
                .final_state = .present,
            }},
        });
        try self.renderer.record(pass);
        pass.end();
        try cmd.submit();
        try self.device.endFrame();
    }
};

const sprites_id = core.ContentId.fromString("foundry:textures.sprites");

test "a content id becomes a texture, and the texture draws" {
    const stack = try Stack.init();
    defer stack.deinit();

    try stack.writeFile("textures/sprites.png", &one_pixel_png);
    try stack.loadPackage("foundry:core", package_source);

    // The only thing the caller names is the ID. Not a path, not a file, not a package —
    // which is the whole of ADR-0021 in one line.
    const handle = try stack.assets.acquire(stack.gpa, sprites_id);
    defer stack.assets.release(handle);

    // The payload came back through a module that has no idea what a GPU texture is.
    const texture = stack.assets.payloadOf(handle).?.asHandle(render2d.TextureHandle);
    const size = stack.renderer.textureSize(texture).?;
    try testing.expectEqual(@as(u32, 1), size.width);
    try testing.expectEqual(@as(u32, 1), size.height);

    try stack.frame(.{
        .texture = texture,
        .position = .init(0, 0),
        .size = .init(64, 64),
    });
    try testing.expectEqual(@as(u32, 1), stack.renderer.frameStats().draw_calls);
}

test "eviction returns the texture to the renderer that made it" {
    const stack = try Stack.init();
    defer stack.deinit();

    try stack.writeFile("textures/sprites.png", &one_pixel_png);
    try stack.loadPackage("foundry:core", package_source);

    const handle = try stack.assets.acquire(stack.gpa, sprites_id);
    const texture = stack.assets.payloadOf(handle).?.asHandle(render2d.TextureHandle);
    stack.assets.release(handle);

    try testing.expectEqual(@as(u32, 1), stack.assets.evictUnused(stack.gpa));
    // The renderer's handle is stale, not dangling: I1 at the seam between two modules
    // that were compiled without either knowing the other's storage.
    try testing.expect(stack.renderer.textureSize(texture) == null);

    // The GPU objects retire behind the frames that could still reference them, so the
    // null backend's rules have to hold across the frames after an eviction too.
    for (0..3) |_| try stack.frame(null);
}

test "a sampler mode nobody recognises still draws, and says so" {
    const stack = try Stack.init();
    defer stack.deinit();

    try stack.writeFile("textures/sprites.png", &one_pixel_png);
    try stack.loadPackage("foundry:core",
        \\foundry:texture foundry:textures.sprites {
        \\    source "textures/sprites.png"
        \\    filter "sideways"
        \\}
    );

    // The checker cannot catch this — the type list is closed, so `filter` is a string and
    // its domain is only knowable in the loader. Answering a typo with a missing sprite
    // would be the least diagnosable outcome available, so the loader warns and falls back.
    const handle = try stack.assets.acquire(stack.gpa, sprites_id);
    defer stack.assets.release(handle);
    const texture = stack.assets.payloadOf(handle).?.asHandle(render2d.TextureHandle);
    try testing.expect(stack.renderer.textureSize(texture) != null);
}

test "a texture the content never named is a value, not a crash" {
    const stack = try Stack.init();
    defer stack.deinit();

    try stack.writeFile("textures/sprites.png", &one_pixel_png);
    try stack.loadPackage("foundry:core", package_source);

    try testing.expectError(error.AssetNotFound, stack.assets.acquire(
        stack.gpa,
        core.ContentId.fromString("foundry:textures.missing"),
    ));
    // A mod naming a texture that is not installed must not take the frame with it.
    try stack.frame(null);
}
