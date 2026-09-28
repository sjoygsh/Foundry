//! A texture and a mesh from a package, through `render3d`'s private loaders, to a draw.
//!
//! `render3d/loader.zig`'s loaders are never registered (`meshes.md` §7.4): they reach the
//! registry only through `acquireWith`. Their unit test pins their identity; this is the
//! composition — `.fdt` records, a PNG and an `.fmesh` on disk, a content ID, a material, a
//! frame on the null backend's validation — that only exists above both modules.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const rhi = @import("rhi");
const asset = @import("asset");
const render3d = @import("render3d");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Vec3 = core.math.Vec3;

const texture_id = core.ContentId.fromString("demo:textures.crate");
const linear_id = core.ContentId.fromString("demo:textures.mask");
const mesh_id = core.ContentId.fromString("demo:meshes.quad");
const broken_id = core.ContentId.fromString("demo:meshes.broken");

const package_source =
    \\foundry:texture demo:textures.crate {
    \\    source  "textures/crate.png"
    \\    mipmaps true
    \\}
    \\foundry:texture demo:textures.mask {
    \\    source      "textures/crate.png"
    \\    color_space "linear"
    \\}
    \\foundry:mesh demo:meshes.quad   { source "meshes/quad.fmesh" }
    \\foundry:mesh demo:meshes.broken { source "meshes/broken.fmesh" }
;

/// Teardown order is the load-bearing part, as in `asset_pipeline.zig`: the registry unloads
/// through loaders whose context is the renderer, so it goes first.
const Stack = struct {
    gpa: Allocator,
    os: *platform.os.Os,
    tmp: std.testing.TmpDir,
    dir: []u8,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: std.ArrayList(u8) = .empty,
    device: *rhi.Device,
    renderer: render3d.Renderer,
    assets: asset.Registry,

    fn init() !*Stack {
        const gpa = testing.allocator;
        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-integration", .env = &.{} });
        errdefer os.deinit();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(testing.io, &path_buf);
        const dir = try platform.os.joinPath(gpa, &.{ path_buf[0..path_len], "foundry-model-loaders" });
        errdefer gpa.free(dir);

        const device = try rhi.Device.init(gpa, .{ .surface_size = .{ .width = 32, .height = 32 } });
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
            .renderer = try render3d.Renderer.init(gpa, device, .{ .sample_count = 1 }),
            .assets = undefined,
        };
        self.assets = .init(gpa, os, &self.store, .{});
        try asset.schemas.registerAll(gpa, &self.schemas);
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
        self.tmp.cleanup();
        self.gpa.destroy(self);
    }

    fn writeFile(self: *Stack, rel: []const u8, contents: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ self.dir, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    fn loadPackage(self: *Stack) !void {
        var doc = try data.parser.parse(self.gpa, "content.fdt", package_source, .{ .namespace = "demo" }, &self.diags);
        defer doc.deinit(self.gpa);
        var pkg = try data.check.Package.init(self.gpa, "demo:models", 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.schemas, &self.diags);
        try data.fpk.write(self.gpa, &pkg, &self.schemas, &self.bytes);
        const handle = try self.store.add(self.gpa, "demo:models", self.bytes.items, &self.schemas, &self.diags);
        try self.assets.mount(self.gpa, handle, self.dir);
    }
};

fn quadFile(gpa: Allocator) ![]u8 {
    const positions = [_]Vec3{ .init(-1, -1, -2), .init(1, -1, -2), .init(1, 1, -2), .init(-1, 1, -2) };
    const uvs = [_][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = 6 }};
    const streams = [_]asset.MeshStream{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&positions) },
        .{ .semantic = .uv0, .format = .float32x2, .bytes = std.mem.sliceAsBytes(&uvs) },
    };
    return asset.mesh_file.write(gpa, .{
        .vertex_count = positions.len,
        .streams = &streams,
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&indices),
        .submeshes = &submeshes,
        .bounds = try asset.Mesh.computeBounds(&positions),
    });
}

test "a package's texture and mesh load through render3d's private loaders and draw" {
    const stack = try Stack.init();
    defer stack.deinit();

    const png = try @import("ui_theme.zig").solidPng(stack.gpa, 8, 8);
    defer stack.gpa.free(png);
    try stack.writeFile("textures/crate.png", png);
    const quad = try quadFile(stack.gpa);
    defer stack.gpa.free(quad);
    try stack.writeFile("meshes/quad.fmesh", quad);
    try stack.writeFile("meshes/broken.fmesh", "not a mesh");
    try stack.loadPackage();

    const textures = render3d.textureLoader(&stack.renderer);
    const meshes = render3d.meshLoader(&stack.renderer);
    const texture_asset = try stack.assets.acquireWith(stack.gpa, texture_id, textures);
    const mesh_asset = try stack.assets.acquireWith(stack.gpa, mesh_id, meshes);

    // Neither loader is a registration: the shared path still has none for either schema.
    try testing.expectError(error.NoLoader, stack.assets.acquire(stack.gpa, mesh_id));
    try testing.expectError(error.NoLoader, stack.assets.acquire(stack.gpa, texture_id));
    // A file that is not a mesh is refused as a value, and leaves nothing resident.
    try testing.expectError(error.InvalidAsset, stack.assets.acquireWith(stack.gpa, broken_id, meshes));

    // Provenance: each payload answers only for the loader that made it.
    const texture = render3d.textureOf(&stack.assets, texture_asset, &stack.renderer).?;
    const mesh = render3d.meshOf(&stack.assets, mesh_asset, &stack.renderer).?;
    try testing.expect(render3d.meshOf(&stack.assets, texture_asset, &stack.renderer) == null);

    // The record's colour space reaches the material's check.
    const linear_asset = try stack.assets.acquireWith(stack.gpa, linear_id, textures);
    const linear = render3d.textureOf(&stack.assets, linear_asset, &stack.renderer).?;
    try testing.expectError(error.WrongColorSpace, stack.renderer.createMaterial(.{ .base_color_texture = linear }, "linear"));

    const material = try stack.renderer.createMaterial(.{ .base_color_texture = texture }, "crate");
    try stack.renderer.begin(.{
        .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 },
        .target_size = .{ .width = 32, .height = 32 },
    });
    try stack.renderer.drawMesh(.{ .mesh = mesh, .material = material, .world = .identity });
    const frame = try stack.device.beginFrame();
    var cmd = try stack.device.beginCommandBuffer();
    try stack.renderer.prepare(cmd, frame);
    var pass = try cmd.beginRenderPass(stack.renderer.passDesc(frame, false));
    try stack.renderer.record(pass);
    pass.end();
    try cmd.submit();
    try stack.device.endFrame();
    try testing.expectEqual(@as(u32, 1), stack.renderer.frameStats().draws);
    if (rhi.backend == .null) try testing.expectEqual(@as(usize, 0), stack.device.violationCount());

    stack.renderer.destroyMaterial(material);

    // Everything the private loaders made is handed back to them, without a release each.
    try testing.expectEqual(@as(u32, 1), stack.assets.unloadWith(stack.gpa, meshes));
    try testing.expectEqual(@as(u32, 2), stack.assets.unloadWith(stack.gpa, textures));
    try testing.expect(render3d.meshOf(&stack.assets, mesh_asset, &stack.renderer) == null);
}
