//! Models by content ID: a compiled package to `render3d.Content`'s draws.
//!
//! `content.zig` reads records and composes assets that only exist once a package has been
//! compiled, mounted and loaded, so its tests are here, over the real compiler (the same one
//! `fpack` and the editor run), store, registry and renderer (`meshes.md` §8, §11 item 4).

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const rhi = @import("rhi");
const asset = @import("asset");
const author = @import("author");
const render3d = @import("render3d");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const rgbaPng = @import("ui_theme.zig").rgbaPng;

const target_size = 32;
const target_bytes = target_size * target_size * 4;

const manifest =
    \\foundry:mod demo:content { name "test" version 1 license "Apache-2.0" }
;

/// A quad at z = -2 facing +Z, the same numbers the glTF below stores.
const quad_positions = [_]Vec3{ .init(-1, -1, -2), .init(1, -1, -2), .init(1, 1, -2), .init(-1, 1, -2) };
const quad_uvs = [_][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

fn id(text: []const u8) ContentId {
    return ContentId.fromString(text);
}

/// Source tree, install tree, and every module between them, torn down in dependency order:
/// `Content` hands its assets back through the registry, which calls into the renderer.
const Stack = struct {
    gpa: Allocator,
    os: *platform.os.Os,
    tmp: std.testing.TmpDir,
    /// What an author edits.
    src: []u8,
    /// What an install holds: the compiler's generated assets, and the source files copied
    /// beside them, as the build stages a package. The registry mounts this.
    out: []u8,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: std.ArrayList(u8) = .empty,
    device: *rhi.Device,
    renderer: render3d.Renderer,
    assets: asset.Registry,
    content: render3d.Content,

    fn init(samples: u32) !*Stack {
        const gpa = testing.allocator;
        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-integration", .env = &.{} });
        errdefer os.deinit();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(testing.io, &path_buf);
        const src = try platform.os.joinPath(gpa, &.{ path_buf[0..path_len], "src" });
        errdefer gpa.free(src);
        const out = try platform.os.joinPath(gpa, &.{ path_buf[0..path_len], "out" });
        errdefer gpa.free(out);
        const device = try rhi.Device.init(gpa, .{ .surface_size = .{ .width = target_size, .height = target_size } });
        errdefer device.deinit();

        const self = try gpa.create(Stack);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .os = os,
            .tmp = tmp,
            .src = src,
            .out = out,
            .schemas = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
            .device = device,
            .renderer = try render3d.Renderer.init(gpa, device, .{ .sample_count = samples }),
            .assets = undefined,
            .content = undefined,
        };
        self.assets = .init(gpa, os, &self.store, .{});
        self.content = .init(gpa, &self.renderer, &self.assets, .default);
        try self.write("mod.fdt", manifest);
        return self;
    }

    fn deinit(self: *Stack) void {
        self.content.deinit();
        self.assets.deinit(self.gpa);
        self.renderer.deinit();
        self.device.deinit();
        self.store.deinit(self.gpa);
        self.schemas.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
        self.gpa.free(self.src);
        self.gpa.free(self.out);
        self.os.deinit();
        self.tmp.cleanup();
        self.gpa.destroy(self);
    }

    fn writeUnder(self: *Stack, root: []const u8, rel: []const u8, contents: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ root, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    /// An authoring file only: text, or a glTF and its buffer.
    fn write(self: *Stack, rel: []const u8, contents: []const u8) !void {
        try self.writeUnder(self.src, rel, contents);
    }

    /// A runtime file the install carries as it is: a PNG, an `.fmesh`.
    fn install(self: *Stack, rel: []const u8, contents: []const u8) !void {
        try self.writeUnder(self.src, rel, contents);
        try self.writeUnder(self.out, rel, contents);
    }

    /// Compiles `src` and loads it in place of whatever was loaded, as `app`'s package reload
    /// does: the store is replaced at the same address, and the registry remounted.
    fn build(self: *Stack) !void {
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(self.gpa);
        const identity = try author.compile(self.gpa, self.os, self.src, .{ .assets_out = self.out }, &self.schemas, &self.diags, &next);
        defer self.gpa.free(identity.name);

        self.assets.clearMounts();
        self.store.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
        self.bytes = next;
        self.store = .init(self.gpa, .default);
        const handle = try self.store.add(self.gpa, "demo:content", self.bytes.items, &self.schemas, &self.diags);
        try self.assets.mount(self.gpa, handle, self.out);
    }

    /// `build`, then what a host does when the content generation moves.
    fn reload(self: *Stack) !void {
        try self.build();
        _ = self.assets.reloadAll(self.gpa);
        try self.content.contentChanged();
    }

    fn begin(self: *Stack) !void {
        try self.renderer.begin(.{
            .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 },
            .target_size = .{ .width = target_size, .height = target_size },
            .clear_color = .{ 0, 0, 1, 1 },
        });
    }

    /// Records what was submitted since `begin`, and reads the surface back when asked.
    fn finish(self: *Stack, pixels: ?*[target_bytes]u8) !void {
        const readback = if (pixels != null) try self.device.createBuffer(.{
            .label = "model content readback",
            .size = target_bytes,
            .usage = .{ .copy_dst = true },
            .memory = .readback,
        }) else rhi.BufferHandle.none;
        defer if (!readback.isNone()) self.device.destroyBuffer(readback);

        const frame = try self.device.beginFrame();
        var cmd = try self.device.beginCommandBuffer();
        try self.renderer.prepare(cmd, frame);
        try self.renderer.recordFrame(cmd, frame, false);
        if (pixels != null) {
            try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .present, .to = .copy_src }});
            try cmd.copyTextureToBuffer(.{ .src = frame.surface_texture, .size = .{ .width = target_size, .height = target_size }, .dst = readback });
            try cmd.textureBarrier(&.{.{ .texture = frame.surface_texture, .from = .copy_src, .to = .present }});
        }
        try cmd.submit();
        try self.device.endFrame();
        if (pixels) |destination| {
            self.device.waitIdle();
            const mapped = try self.device.mapBuffer(readback);
            @memcpy(destination, mapped[0..target_bytes]);
            self.device.unmapBuffer(readback);
        }
    }

    fn violations(self: *Stack) usize {
        return if (rhi.backend == .null) self.device.violationCount() else 0;
    }

    fn materialDesc(self: *Stack, handle: render3d.MaterialHandle) render3d.MaterialDesc {
        return self.renderer.materials.getConst(handle).?.desc;
    }
};

fn quadFile(gpa: Allocator) ![]u8 {
    const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = 6 }};
    const streams = [_]asset.MeshStream{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&quad_positions) },
        .{ .semantic = .uv0, .format = .float32x2, .bytes = std.mem.sliceAsBytes(&quad_uvs) },
    };
    return asset.mesh_file.write(gpa, .{
        .vertex_count = quad_positions.len,
        .streams = &streams,
        .index_format = .uint16,
        .indices = std.mem.sliceAsBytes(&quad_indices),
        .submeshes = &submeshes,
        .bounds = try asset.Mesh.computeBounds(&quad_positions),
    });
}

/// Four texels, each its own colour, so a flipped or resampled texture is visible.
fn checkerPng(gpa: Allocator, size: u32) ![]u8 {
    const pixels = try gpa.alloc(u8, @as(usize, size) * size * 4);
    defer gpa.free(pixels);
    const colors = [4][4]u8{ .{ 230, 40, 30, 255 }, .{ 40, 200, 60, 255 }, .{ 30, 60, 220, 255 }, .{ 240, 220, 50, 255 } };
    for (0..size) |y| for (0..size) |x| {
        const quadrant = @as(usize, @intFromBool(x >= size / 2)) + 2 * @as(usize, @intFromBool(y >= size / 2));
        @memcpy(pixels[(y * size + x) * 4 ..][0..4], &colors[quadrant]);
    };
    return rgbaPng(gpa, size, size, pixels);
}

// -- the records ------------------------------------------------------------------

const records =
    \\foundry:texture demo:textures.linear { source "textures/mask.png" color_space "linear" }
    \\foundry:mesh demo:meshes.gone { source "meshes/gone.fmesh" }
    \\
    \\foundry:material demo:materials.red   { base_color { r 1 g 0 b 0 a 1 } }
    \\foundry:material demo:materials.crate { base_color_texture demo:textures.crate }
    \\foundry:material demo:materials.bad_mode    { alpha_mode "additive" }
    \\foundry:material demo:materials.too_bright  { base_color { r 1.5 g 0 b 0 a 1 } }
    \\foundry:material demo:materials.linear      { base_color_texture demo:textures.linear }
    \\foundry:material demo:materials.bad_shading { shading demo:shading.absent }
    \\foundry:material demo:materials.no_texture  { base_color_texture demo:textures.absent }
    \\
    \\foundry:model demo:models.pair {
    \\    slots [ { name "red" material demo:materials.red } { name "crate" material demo:materials.crate } ]
    \\    parts [ { mesh demo:meshes.quad submesh 0 slot 0 translation { x -1 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 0.5 y 0.5 z 1 } }
    \\            { mesh demo:meshes.quad submesh 0 slot 1 translation { x 1 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 0.5 y 0.5 z 1 } }
    \\            { mesh demo:meshes.gone submesh 0 slot 0 translation { x 0 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 1 y 1 z 1 } }
    \\            { mesh demo:meshes.quad submesh 3 slot 0 translation { x 0 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 1 y 1 z 1 } } ]
    \\}
    \\foundry:model demo:models.unresolved {
    \\    slots [ { name "a" material demo:materials.absent } ]
    \\    parts [ { mesh demo:meshes.quad submesh 0 slot 0 translation { x 0 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 1 y 1 z 1 } } ]
    \\}
    \\foundry:model demo:models.no_slot {
    \\    slots [ ]
    \\    parts [ { mesh demo:meshes.quad submesh 0 slot 0 translation { x 0 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 1 y 1 z 1 } } ]
    \\}
    \\foundry:model demo:models.bad_rotation {
    \\    slots [ { name "a" material demo:materials.red } ]
    \\    parts [ { mesh demo:meshes.quad submesh 0 slot 0 translation { x 0 y 0 z 0 } rotation { x 1 y 1 z 1 w 1 } scale { x 1 y 1 z 1 } } ]
    \\}
    \\
;

/// The package above, with its files: a quad, two PNGs and a mesh the install lacks.
fn recordStack() !*Stack {
    const stack = try Stack.init(1);
    errdefer stack.deinit();
    const quad = try quadFile(stack.gpa);
    defer stack.gpa.free(quad);
    try stack.install("meshes/quad.fmesh", quad);
    // The compiler sees it; the install does not, so it fails to load at run time.
    try stack.write("meshes/gone.fmesh", quad);
    const png = try checkerPng(stack.gpa, 8);
    defer stack.gpa.free(png);
    try stack.install("textures/crate.png", png);
    try stack.install("textures/mask.png", png);
    try stack.write("content.fdt", records);
    try stack.build();
    return stack;
}

test "a model resolves by content ID, drops what does not load, and draws its parts in order" {
    const stack = try recordStack();
    defer stack.deinit();

    const pair = try stack.content.acquireModel(id("demo:models.pair"));
    // The same ID is the same model, with one more reference.
    try testing.expect(pair.eql(try stack.content.acquireModel(id("demo:models.pair"))));
    stack.content.releaseModel(pair);

    try stack.begin();
    try stack.content.drawModel(.{ .model = pair, .world = .identity });
    try stack.finish(null);
    // Four parts: the missing mesh is dropped, and the out-of-range submesh is skipped.
    try testing.expectEqual(@as(u32, 2), stack.renderer.frameStats().draws);
    try testing.expectEqual(@as(usize, 0), stack.violations());

    // Each distinct mesh once (the quad; the gone mesh never loaded), and one texture.
    try testing.expectEqual(@as(usize, 1), stack.content.models.getConst(pair).?.meshes.len);
    try testing.expectEqual(@as(u32, 2), stack.content.materials.count());

    // Draws are record order: the red slot's part, then the crate's.
    const red = try stack.content.acquireMaterial(id("demo:materials.red"));
    defer stack.content.releaseMaterial(red);
    try testing.expect(stack.renderer.draws.items[0].material.eql(red));
    try testing.expectEqual(@as(f32, -1), stack.renderer.draws.items[0].world.cols[3][0]);
    try testing.expectEqual(@as(f32, 0.5), stack.renderer.draws.items[0].world.cols[0][0]);

    stack.content.releaseModel(pair);
    try testing.expectEqual(@as(u32, 0), stack.content.models.count());
    // The red material survives through `acquireMaterial`; the crate's went with the model.
    try testing.expectEqual(@as(u32, 1), stack.content.materials.count());
}

test "a model record that cannot be resolved is refused, and holds nothing afterwards" {
    const stack = try recordStack();
    defer stack.deinit();

    try testing.expectError(error.ModelNotFound, stack.content.acquireModel(id("demo:models.absent")));
    try testing.expectError(error.NotAModel, stack.content.acquireModel(id("demo:materials.red")));
    try testing.expectError(error.InvalidModelRecord, stack.content.acquireModel(id("demo:models.no_slot")));
    try testing.expectError(error.InvalidModelRecord, stack.content.acquireModel(id("demo:models.bad_rotation")));
    try testing.expectError(error.MaterialNotFound, stack.content.acquireMaterial(id("demo:materials.absent")));
    try testing.expectError(error.NotAMaterial, stack.content.acquireMaterial(id("demo:models.pair")));
    try testing.expectEqual(@as(u32, 0), stack.content.models.count());
    try testing.expectEqual(@as(u32, 0), stack.content.materials.count());
    try testing.expectEqual(@as(u32, 0), stack.assets.count());
}

test "a material that fails to resolve is the magenta placeholder, and never a crash" {
    const stack = try recordStack();
    defer stack.deinit();

    const good = try stack.content.acquireMaterial(id("demo:materials.crate"));
    try testing.expect(!stack.materialDesc(good).base_color_texture.isNone());
    for ([_][]const u8{
        "demo:materials.bad_mode",
        "demo:materials.too_bright",
        "demo:materials.linear",
        "demo:materials.bad_shading",
        "demo:materials.no_texture",
    }) |name| {
        const handle = try stack.content.acquireMaterial(id(name));
        const desc = stack.materialDesc(handle);
        try testing.expectEqual(render3d.content.placeholder.base_color, desc.base_color);
        try testing.expect(desc.base_color_texture.isNone());
    }
    // A placeholder holds no texture: the linear one it tried is released, and evictable.
    try testing.expectEqual(@as(u32, 1), stack.assets.evictUnused(stack.gpa));
    try testing.expectEqual(@as(u32, 1), stack.assets.count());

    // A slot naming a record that does not exist resolves, and draws, as the placeholder.
    const unresolved = try stack.content.acquireModel(id("demo:models.unresolved"));
    try stack.begin();
    try stack.content.drawModel(.{ .model = unresolved, .world = .identity });
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 1), stack.renderer.frameStats().draws);
    try testing.expectEqual(render3d.content.placeholder.base_color, stack.materialDesc(stack.renderer.draws.items[0].material).base_color);
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "slot overrides replace one slot for one draw, and a refused draw records nothing" {
    const stack = try recordStack();
    defer stack.deinit();
    const pair = try stack.content.acquireModel(id("demo:models.pair"));
    const crate = try stack.content.acquireMaterial(id("demo:materials.crate"));
    const code_built = try stack.renderer.createMaterial(.{ .base_color = .{ 0, 1, 0, 1 } }, "override");
    defer stack.renderer.destroyMaterial(code_built);

    try stack.begin();
    try testing.expectError(error.InvalidOverride, stack.content.drawModel(.{ .model = pair, .world = .identity, .overrides = &.{.{ .slot = 2, .material = crate }} }));
    try testing.expectError(error.InvalidOverride, stack.content.drawModel(.{ .model = pair, .world = .identity, .overrides = &.{
        .{ .slot = 0, .material = crate },
        .{ .slot = 0, .material = code_built },
    } }));
    try testing.expectError(error.InvalidMaterial, stack.content.drawModel(.{ .model = pair, .world = .identity, .overrides = &.{.{ .slot = 0, .material = .none }} }));
    var bad = Mat4.identity;
    bad.cols[3][1] = std.math.inf(f32);
    try testing.expectError(error.InvalidTransform, stack.content.drawModel(.{ .model = pair, .world = bad }));
    try testing.expectError(error.InvalidModel, stack.content.drawModel(.{ .model = .none, .world = .identity }));
    try testing.expectEqual(@as(usize, 0), stack.renderer.draws.items.len);

    // Content's own material and a code-built one are both valid overrides.
    try stack.content.drawModel(.{ .model = pair, .world = .identity, .overrides = &.{
        .{ .slot = 0, .material = crate },
        .{ .slot = 1, .material = code_built },
    } });
    try stack.content.drawModel(.{ .model = pair, .world = Mat4.translation(.init(0, 0, -1)) });
    try testing.expect(stack.renderer.draws.items[0].material.eql(crate));
    try testing.expect(stack.renderer.draws.items[1].material.eql(code_built));
    try testing.expect(!stack.renderer.draws.items[2].material.eql(crate));
    try testing.expect(stack.renderer.draws.items[3].material.eql(crate));
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 4), stack.renderer.frameStats().draws);
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "a reloaded texture, record or model is followed, and handles stay valid" {
    const stack = try recordStack();
    defer stack.deinit();
    const pair = try stack.content.acquireModel(id("demo:models.pair"));
    const red = try stack.content.acquireMaterial(id("demo:materials.red"));
    const crate = try stack.content.acquireMaterial(id("demo:materials.crate"));
    const before = stack.materialDesc(crate).base_color_texture;

    // A PNG edited on disk: the registry swaps the payload and destroys the old texture.
    // The draw must rebind first, or the null backend reports binding a destroyed resource.
    const smaller = try checkerPng(stack.gpa, 4);
    defer stack.gpa.free(smaller);
    try stack.writeUnder(stack.out, "textures/crate.png", smaller);
    try testing.expect(stack.assets.reloadChanged(stack.gpa) > 0);
    try stack.begin();
    try stack.content.drawModel(.{ .model = pair, .world = .identity });
    try stack.finish(null);
    try testing.expectEqual(@as(usize, 0), stack.violations());
    try testing.expect(!stack.materialDesc(crate).base_color_texture.eql(before));
    try testing.expect(stack.renderer.isMaterial(crate));

    // A colour and a part edited in the text: a package reload, which no file stamp shows.
    const edited = try std.mem.replaceOwned(u8, stack.gpa, records, "r 1 g 0 b 0 a 1 } }\n", "r 1 g 1 b 0 a 1 } }\n");
    defer stack.gpa.free(edited);
    const dropped = try std.mem.replaceOwned(u8, stack.gpa, edited, "            { mesh demo:meshes.quad submesh 3", "            { mesh demo:meshes.quad submesh 0");
    defer stack.gpa.free(dropped);
    try stack.write("content.fdt", dropped);
    try stack.reload();
    try testing.expectEqual([4]f32{ 1, 1, 0, 1 }, stack.materialDesc(red).base_color);
    try stack.begin();
    try stack.content.drawModel(.{ .model = pair, .world = .identity });
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 3), stack.renderer.frameStats().draws);

    // A model whose record is gone keeps drawing what it had.
    const without_pair = try std.mem.replaceOwned(u8, stack.gpa, dropped, "foundry:model demo:models.pair", "foundry:model demo:models.renamed");
    defer stack.gpa.free(without_pair);
    try stack.write("content.fdt", without_pair);
    try stack.reload();
    try stack.begin();
    try stack.content.drawModel(.{ .model = pair, .world = .identity });
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 3), stack.renderer.frameStats().draws);
    try testing.expectEqual(@as(usize, 0), stack.violations());

    // And a material whose record is gone becomes the placeholder behind the same handle.
    const without_red = try std.mem.replaceOwned(u8, stack.gpa, without_pair, "foundry:material demo:materials.red", "foundry:material demo:materials.renamed");
    defer stack.gpa.free(without_red);
    try stack.write("content.fdt", without_red);
    try stack.reload();
    try testing.expect(stack.renderer.isMaterial(red));
    try testing.expectEqual(render3d.content.placeholder.base_color, stack.materialDesc(red).base_color);
    stack.content.releaseMaterial(red);
    stack.content.releaseMaterial(crate);
}

// -- §11 item 4: nothing downstream knows it was glTF ------------------------------

const gltf_json =
    \\{"asset":{"version":"2.0"},
    \\ "buffers":[{"uri":"quad.bin","byteLength":92}],
    \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":32},{"buffer":0,"byteOffset":80,"byteLength":12}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[-1,-1,-2],"max":[1,1,-2]},
    \\              {"bufferView":1,"componentType":5126,"count":4,"type":"VEC2"},
    \\              {"bufferView":2,"componentType":5123,"count":6,"type":"SCALAR"}],
    \\ "images":[{"uri":"quad.png","mimeType":"image/png"}],
    \\ "textures":[{"source":0}],
    \\ "materials":[{"name":"Paper","extensions":{"KHR_materials_unlit":{}},"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
    \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"indices":2,"material":0}]}],
    \\ "nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}],"scene":0}
;

fn quadBin() [92]u8 {
    var bytes: [92]u8 = undefined;
    @memcpy(bytes[0..48], std.mem.sliceAsBytes(&quad_positions));
    @memcpy(bytes[48..80], std.mem.sliceAsBytes(&quad_uvs));
    @memcpy(bytes[80..92], std.mem.sliceAsBytes(&quad_indices));
    return bytes;
}

fn readOut(stack: *Stack, rel: []const u8) ![]u8 {
    const path = try platform.os.joinPath(stack.gpa, &.{ stack.out, rel });
    defer stack.gpa.free(path);
    return stack.os.readFile(stack.gpa, path, 1 << 20);
}

test "an imported textured quad is the code-built quad, in bytes, in records and in pixels" {
    for ([_]u32{ 1, 4 }) |samples| {
        const stack = try Stack.init(samples);
        defer stack.deinit();
        const bin = quadBin();
        try stack.write("models/quad.bin", &bin);
        try stack.write("models/quad.gltf", gltf_json);
        const png = try checkerPng(stack.gpa, 8);
        defer stack.gpa.free(png);
        try stack.install("models/quad.png", png);
        try stack.build();

        // The generated mesh is the one code writes, byte for byte.
        const imported_mesh = try readOut(stack, "models/quad/mesh0.fmesh");
        defer stack.gpa.free(imported_mesh);
        const code_mesh = try quadFile(stack.gpa);
        defer stack.gpa.free(code_mesh);
        try testing.expectEqualSlices(u8, code_mesh, imported_mesh);

        // The generated records hold the values code passes below.
        const texture = stack.store.lookup(id("demo:models.quad.texture0")).?;
        try testing.expectEqualStrings("linear", asset.schemas.stringField(texture, asset.schemas.texture, asset.schemas.filter_field).?);
        try testing.expectEqualStrings("repeat", asset.schemas.stringField(texture, asset.schemas.texture, asset.schemas.wrap_field).?);
        try testing.expectEqualStrings("srgb", asset.schemas.stringField(texture, asset.schemas.texture, asset.schemas.color_space_field).?);
        try testing.expect(asset.schemas.boolField(texture, asset.schemas.texture, asset.schemas.mipmaps_field).?);
        const material = try stack.content.acquireMaterial(id("demo:models.quad.material0"));
        defer stack.content.releaseMaterial(material);
        const desc = stack.materialDesc(material);
        try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, desc.base_color);
        try testing.expectEqual(render3d.AlphaMode.@"opaque", desc.alpha_mode);
        try testing.expect(desc.shading.eql(render3d.unlit_id) and !desc.double_sided);

        const model = try stack.content.acquireModel(id("demo:models.quad"));
        const entry = stack.content.models.getConst(model).?;
        try testing.expectEqual(@as(usize, 1), entry.parts.len);
        try testing.expect(entry.parts[0].local.approxEql(.identity, 0));

        // The same quad from code: its own mesh, texture and material.
        var image = try asset.png.decode(stack.gpa, png, .{});
        defer image.deinit(stack.gpa);
        const code_texture = try stack.renderer.createTexture(image, .{ .filter = .linear, .wrap = .repeat, .color_space = .srgb, .mipmaps = true });
        const code_material = try stack.renderer.createMaterial(.{ .base_color_texture = code_texture }, "code quad");
        defer stack.renderer.destroyMaterial(code_material);
        var code_view = try asset.mesh_file.read(code_mesh, .default);
        const code_quad = try stack.renderer.createMesh(code_view.mesh(), "code quad");

        var imported_pixels: [target_bytes]u8 = undefined;
        try stack.begin();
        try stack.content.drawModel(.{ .model = model, .world = .identity });
        try stack.finish(&imported_pixels);
        var code_pixels: [target_bytes]u8 = undefined;
        try stack.begin();
        try stack.renderer.drawMesh(.{ .mesh = code_quad, .material = code_material, .world = .identity });
        try stack.finish(&code_pixels);
        try testing.expectEqual(@as(usize, 0), stack.violations());

        if (rhi.backend != .null) {
            try testing.expectEqualSlices(u8, &code_pixels, &imported_pixels);
            // And it drew something: the centre is not the clear colour.
            const centre = (16 * target_size + 16) * 4;
            try testing.expect(!std.mem.eql(u8, imported_pixels[centre..][0..4], imported_pixels[0..4]));
        }
    }
}
