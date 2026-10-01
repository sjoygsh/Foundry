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
const app = @import("app");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const rgbaPng = @import("ui_theme.zig").rgbaPng;

pub const target_size = 32;
const target_bytes = target_size * target_size * 4;

const manifest =
    \\foundry:mod demo:content { name "test" version 1 license "Apache-2.0" }
;

/// A quad at z = -2 facing +Z, the same numbers the glTF below stores.
const quad_positions = [_]Vec3{ .init(-1, -1, -2), .init(1, -1, -2), .init(1, 1, -2), .init(-1, 1, -2) };
const quad_uvs = [_][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

pub fn id(text: []const u8) ContentId {
    return ContentId.fromString(text);
}

/// Source tree, install tree, and every module between them, torn down in dependency order:
/// `Content` hands its assets back through the registry, which calls into the renderer.
pub const Stack = struct {
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

    pub fn init(samples: u32) !*Stack {
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

    pub fn deinit(self: *Stack) void {
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

    pub fn writeUnder(self: *Stack, root: []const u8, rel: []const u8, contents: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ root, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    /// An authoring file only: text, or a glTF and its buffer.
    pub fn write(self: *Stack, rel: []const u8, contents: []const u8) !void {
        try self.writeUnder(self.src, rel, contents);
    }

    /// A runtime file the install carries as it is: a PNG, an `.fmesh`.
    pub fn install(self: *Stack, rel: []const u8, contents: []const u8) !void {
        try self.writeUnder(self.src, rel, contents);
        try self.writeUnder(self.out, rel, contents);
    }

    /// Compiles `src` and loads it in place of whatever was loaded, as `app`'s package reload
    /// does: the store is replaced at the same address, and the registry remounted.
    pub fn build(self: *Stack) !void {
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
    pub fn reload(self: *Stack) !void {
        try self.build();
        _ = self.assets.reloadAll(self.gpa);
        try self.content.contentChanged();
    }

    pub fn begin(self: *Stack) !void {
        try self.renderer.begin(.{
            .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 },
            .target_size = .{ .width = target_size, .height = target_size },
            .clear_color = .{ 0, 0, 1, 1 },
        });
    }

    /// Records what was submitted since `begin`, and reads the surface back when asked.
    pub fn finish(self: *Stack, pixels: ?*[target_bytes]u8) !void {
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

    pub fn violations(self: *Stack) usize {
        return if (rhi.backend == .null) self.device.violationCount() else 0;
    }

    pub fn materialDesc(self: *Stack, handle: render3d.MaterialHandle) render3d.MaterialDesc {
        return self.renderer.materials.getConst(handle).?.desc;
    }
};

pub fn quadFile(gpa: Allocator) ![]u8 {
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

pub const animation_records =
    \\foundry:material demo:skin.material { base_color { r 0.6 g 0.3 b 0.1 a 1 } }
    \\foundry:model demo:skin.model {
    \\ slots [ { name "main" material demo:skin.material } ]
    \\ parts [ { mesh demo:skin.mesh submesh 0 slot 0 translation { x 0 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 1 y 1 z 1 } } ]
    \\ skeleton demo:skin.rig
    \\ clips [ { name "walk" clip demo:skin.walk } ]
    \\}
;

fn rigFile(gpa: Allocator, count: usize) ![]u8 {
    const parents = [_]u16{ asset.skeleton.no_parent, 0 };
    const rest = [_]core.math.Transform{ .{}, .{} };
    const inverse = [_]Mat4{ .identity, .identity };
    const names = [_][]const u8{ "root", "child" };
    return asset.skeleton.write(gpa, .{ .parents = parents[0..count], .rest = rest[0..count], .inverse_bind = inverse[0..count], .names = names[0..count] });
}

fn clipFile(gpa: Allocator, count: u32) ![]u8 {
    return asset.animation.write(gpa, .{ .duration = 1, .joint_count = count, .tracks = &.{} });
}

pub fn animationStack(rig_count: usize, clip_count: u32, text: []const u8) !*Stack {
    const stack = try Stack.init(1);
    errdefer stack.deinit();
    const joints = [_][4]u8{.{ 0, 255, 255, 255 }} ** 4;
    const weights = [_][4]f32{.{ 1, 0, 0, 0 }} ** 4;
    const box = try asset.Mesh.computeBounds(&quad_positions);
    const mesh = try asset.mesh_file.write(stack.gpa, .{ .vertex_count = 4, .bounds = box, .joint_bounds = &.{box}, .streams = &.{
        .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&quad_positions) },
        .{ .semantic = .joints, .format = .uint8x4, .bytes = std.mem.sliceAsBytes(&joints) },
        .{ .semantic = .weights, .format = .float32x4, .bytes = std.mem.sliceAsBytes(&weights) },
    }, .index_format = .uint16, .indices = std.mem.sliceAsBytes(&quad_indices), .submeshes = &.{.{ .first_index = 0, .index_count = 6 }} });
    defer stack.gpa.free(mesh);
    try stack.install("skin/mesh.fmesh", mesh);
    const rig = try rigFile(stack.gpa, rig_count);
    defer stack.gpa.free(rig);
    try stack.install("skin/rig.fskel", rig);
    const clip = try clipFile(stack.gpa, clip_count);
    defer stack.gpa.free(clip);
    try stack.install("skin/walk.fanim", clip);
    try stack.write("skin.fdt", text);
    try stack.build();
    return stack;
}

test "M24 model animation assets are current handle borrows and palette refusals submit no parts" {
    const stack = try animationStack(1, 1, animation_records);
    defer stack.deinit();
    const model = try stack.content.acquireModel(id("demo:skin.model"));
    try testing.expectEqual(@as(usize, 1), stack.content.skeletonOf(model).?.parents.len);
    try testing.expectEqual(@as(u32, 1), stack.content.clipOf(model, "walk").?.joint_count);
    try testing.expect(stack.content.clipOf(model, "missing") == null);
    try stack.begin();
    try testing.expectError(error.MissingSkin, stack.content.drawModel(.{ .model = model, .world = .identity }));
    try testing.expectError(error.InvalidSkinCount, stack.content.drawModel(.{ .model = model, .world = .identity, .skin = &.{ .identity, .identity } }));
    try testing.expectEqual(@as(usize, 0), stack.renderer.draws.items.len);
    try stack.content.drawModel(.{ .model = model, .world = .identity, .skin = &.{.identity} });
    try stack.finish(null);
    try testing.expectEqual(@as(u32, 4), stack.renderer.frameStats().skinned_vertices);
    // A separately overridden clip can mismatch the unchanged model's rig. Refuse before
    // any submission, then follow a healthy reload through the same retained handles.
    const bad_clip = try clipFile(stack.gpa, 2);
    defer stack.gpa.free(bad_clip);
    try stack.writeUnder(stack.out, "skin/walk.fanim", bad_clip);
    _ = stack.assets.reloadAll(stack.gpa);
    try stack.begin();
    try testing.expectError(error.SkeletonMismatch, stack.content.drawModel(.{ .model = model, .world = .identity, .skin = &.{.identity} }));
    try testing.expectEqual(@as(usize, 0), stack.renderer.draws.items.len);
    const good_clip = try clipFile(stack.gpa, 1);
    defer stack.gpa.free(good_clip);
    try stack.writeUnder(stack.out, "skin/walk.fanim", good_clip);
    _ = stack.assets.reloadAll(stack.gpa);
    try stack.content.drawModel(.{ .model = model, .world = .identity, .skin = &.{.identity} });
    try stack.finish(null);
    // Skeleton override is checked independently of the clip and mesh.
    const renamed = try std.mem.replaceOwned(u8, stack.gpa, animation_records, "name \"walk\"", "name \"stride\"");
    defer stack.gpa.free(renamed);
    try stack.write("skin.fdt", renamed);
    try stack.reload();
    try testing.expect(stack.content.clipOf(model, "walk") == null);
    try testing.expectEqual(@as(u32, 1), stack.content.clipOf(model, "stride").?.joint_count);
    const bad_rig = try rigFile(stack.gpa, 2);
    defer stack.gpa.free(bad_rig);
    try stack.writeUnder(stack.out, "skin/rig.fskel", bad_rig);
    _ = stack.assets.reloadAll(stack.gpa);
    try stack.begin();
    try testing.expectError(error.SkeletonMismatch, stack.content.drawModel(.{ .model = model, .world = .identity, .skin = &.{ .identity, .identity } }));
    try testing.expectEqual(@as(usize, 0), stack.renderer.draws.items.len);
    const good_rig = try rigFile(stack.gpa, 1);
    defer stack.gpa.free(good_rig);
    try stack.writeUnder(stack.out, "skin/rig.fskel", good_rig);
    _ = stack.assets.reloadAll(stack.gpa);
    // A caller can explicitly retire a resident handle. A still-retained asset payload
    // must not turn that stale renderer handle into an optional-unwrapping trap.
    var meshes = stack.renderer.meshes.iterator();
    stack.renderer.destroyMesh(meshes.next().?.id);
    try testing.expectError(error.InvalidMesh, stack.content.drawModel(.{ .model = model, .world = .identity, .skin = &.{.identity} }));
    try testing.expectEqual(@as(usize, 0), stack.renderer.draws.items.len);
    stack.content.releaseModel(model);
    try testing.expect(stack.content.skeletonOf(model) == null);
    try testing.expect(stack.content.clipOf(model, "stride") == null);
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "M24 models refuse missing rigs incompatible assets duplicate names and clip limits" {
    for ([_][2]u32{ .{ 2, 1 }, .{ 1, 2 }, .{ 2, 2 } }) |counts| {
        const stack = try animationStack(counts[0], counts[1], animation_records);
        defer stack.deinit();
        try testing.expectError(error.InvalidModelRecord, stack.content.acquireModel(id("demo:skin.model")));
        try testing.expectEqual(@as(u32, 0), stack.content.models.count());
    }
    for ([_]struct { from: []const u8, to: []const u8 }{
        .{ .from = " skeleton demo:skin.rig", .to = "" },
        .{ .from = "{ name \"walk\" clip demo:skin.walk }", .to = "{ name \"walk\" clip demo:skin.walk } { name \"walk\" clip demo:skin.walk }" },
        .{ .from = "name \"walk\"", .to = "name \"\"" },
    }) |edit| {
        const text = try std.mem.replaceOwned(u8, testing.allocator, animation_records, edit.from, edit.to);
        defer testing.allocator.free(text);
        const stack = try animationStack(1, 1, text);
        defer stack.deinit();
        try testing.expectError(error.InvalidModelRecord, stack.content.acquireModel(id("demo:skin.model")));
    }
    const stack = try animationStack(1, 1, animation_records);
    defer stack.deinit();
    stack.content.limits.max_clips = 0;
    try testing.expectError(error.InvalidModelRecord, stack.content.acquireModel(id("demo:skin.model")));
    stack.content.limits.max_clips = 1;
    stack.content.limits.max_clip_name_bytes = 3;
    try testing.expectError(error.InvalidModelRecord, stack.content.acquireModel(id("demo:skin.model")));
}

// `light.md` §11: the compiler, real mod ordering and Content, not a code-material
// stand-in for an override. Both pixel values are checked against the same CPU oracle.
test "a compiled content mod changes a lit pixel through resolved package order" {
    for ([_]u32{ 1, 4 }) |samples| {
        var before: [4]u8 = undefined;
        for ([_]bool{ false, true }) |enabled| {
            const stack = try Stack.init(samples);
            defer stack.deinit();
            const normals = [_]Vec3{Vec3.init(0, 0, 1)} ** 4;
            const mesh = try asset.mesh_file.write(stack.gpa, .{
                .vertex_count = 4,
                .streams = &.{
                    .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&quad_positions) },
                    .{ .semantic = .normal, .format = .float32x3, .bytes = std.mem.sliceAsBytes(&normals) },
                },
                .index_format = .uint16,
                .indices = std.mem.sliceAsBytes(&quad_indices),
                .submeshes = &.{.{ .first_index = 0, .index_count = 6 }},
                .bounds = try asset.Mesh.computeBounds(&quad_positions),
            });
            defer stack.gpa.free(mesh);
            try stack.install("meshes/lit.fmesh", mesh);
            try stack.write("content.fdt",
                \\foundry:mesh demo:meshes.lit { source "meshes/lit.fmesh" }
                \\foundry:material demo:materials.lit { shading foundry:shading.lit base_color { r 0.7 g 0.2 b 0.1 a 1 } roughness 0.7 }
                \\foundry:model demo:models.lit {
                \\ slots [{ name "lit" material demo:materials.lit }]
                \\ parts [{ mesh demo:meshes.lit submesh 0 slot 0 translation { x 0 y 0 z 0 } rotation { x 0 y 0 z 0 w 1 } scale { x 1 y 1 z 1 } }]
                \\}
            );
            try stack.build();
            try stack.writeUnder(stack.out, "demo.fpk", stack.bytes.items);
            const base_path = try platform.os.joinPath(stack.gpa, &.{ stack.out, "demo.fpk" });
            defer stack.gpa.free(base_path);
            var deps = try author.dependency.Set.load(stack.gpa, stack.os, &.{.{ .path = base_path }}, .default, &stack.diags);
            defer deps.deinit();
            const mod_src = try platform.os.joinPath(stack.gpa, &.{ stack.src, "mod-source" });
            defer stack.gpa.free(mod_src);
            try stack.writeUnder(mod_src, "mod.fdt",
                \\foundry:mod dusk:content { name "Pixel dusk" version 1 license "Apache-2.0" requires [{ id demo:content }] }
                \\foundry:material demo:materials.lit { shading foundry:shading.lit base_color { r 0.1 g 0.25 b 0.8 a 1 } roughness 0.4 emissive { r 0 g 0 b 0.1 } emissive_strength 2 }
            );
            var mod_bytes: std.ArrayList(u8) = .empty;
            defer mod_bytes.deinit(stack.gpa);
            const identity = try author.compile(stack.gpa, stack.os, mod_src, .{ .dependencies = &deps }, &stack.schemas, &stack.diags, &mod_bytes);
            defer stack.gpa.free(identity.name);
            try stack.writeUnder(stack.out, "dusk.fpk", mod_bytes.items);
            var set = try app.ModSet.init(stack.gpa, stack.os, &.{.{ .dir = stack.out, .origin = .installed }}, .{ .required = &.{id("demo:content")} }, &stack.diags);
            defer set.deinit();
            const order = try set.start(if (enabled) &.{id("dusk:content")} else &.{}, &stack.diags);
            try testing.expectEqual(@as(usize, if (enabled) 2 else 1), order.order.len);
            if (enabled) {
                try testing.expect(order.order[0].id.eql(id("demo:content")));
            }
            stack.assets.clearMounts();
            stack.store.deinit(stack.gpa);
            stack.store = .init(stack.gpa, .default);
            for (order.order) |entry| {
                const bytes = if (entry.id.eql(id("demo:content"))) stack.bytes.items else mod_bytes.items;
                const handle = try stack.store.add(stack.gpa, entry.name, bytes, &stack.schemas, &stack.diags);
                try stack.assets.mount(stack.gpa, handle, stack.out);
            }
            const material = try stack.content.acquireMaterial(id("demo:materials.lit"));
            const desc = stack.materialDesc(material);
            try testing.expect(desc.shading.eql(render3d.lit_id));
            try testing.expectEqual(@as(f32, if (enabled) 0.1 else 0.7), desc.base_color[0]);
            const model = try stack.content.acquireModel(id("demo:models.lit"));
            try stack.renderer.begin(.{ .camera = .{ .vertical_fov = std.math.pi / 2.0, .near = 0.1, .far = 10 }, .target_size = .{ .width = target_size, .height = target_size }, .ambient = .{ 0.5, 0.5, 0.5 } });
            const light: render3d.Light = .{ .kind = .directional, .intensity = 1, .world = .identity };
            try stack.renderer.addLight(light);
            try stack.content.drawModel(.{ .model = model, .world = .identity });
            var pixels: [target_bytes]u8 = undefined;
            try stack.finish(&pixels);
            try testing.expectEqual(@as(usize, 0), stack.violations());
            if (rhi.backend != .null) {
                const expected = render3d.lighting.toneMap(render3d.lighting.shade(.{
                    .base = desc.base_color[0..3].*,
                    .metallic = desc.metallic,
                    .roughness = desc.roughness,
                    .emissive = .{ desc.emissive[0] * desc.emissive_strength, desc.emissive[1] * desc.emissive_strength, desc.emissive[2] * desc.emissive_strength },
                }, .init(0.0625, -0.0625, -2), .init(0, 0, 1), .zero, &.{light}, .{ 0.5, 0.5, 0.5 }, null));
                const pixel = pixels[(16 * target_size + 16) * 4 ..][0..4];
                for (expected, 0..) |linear, c| {
                    const encoded = if (linear <= 0.0031308) linear * 12.92 else 1.055 * std.math.pow(f32, linear, 1.0 / 2.4) - 0.055;
                    const byte: i32 = @intFromFloat(@round(std.math.clamp(encoded, 0, 1) * 255));
                    const channel = if (stack.device.capabilities().surface_format == .bgra8_unorm_srgb) 2 - c else c;
                    try testing.expect(@abs(@as(i32, pixel[channel]) - byte) <= if (rhi.backend == .vulkan) @as(i32, 3) else 2);
                }
                if (!enabled) @memcpy(&before, pixel) else try testing.expect(!std.mem.eql(u8, &before, pixel));
            }
            stack.content.releaseModel(model);
            stack.content.releaseMaterial(material);
        }
    }
}

/// Four texels, each its own colour, so a flipped or resampled texture is visible.
pub fn checkerPng(gpa: Allocator, size: u32) ![]u8 {
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

pub const records =
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
pub fn recordStack() !*Stack {
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

const lit_records =
    \\foundry:texture demo:textures.base { source "textures/lit.png" color_space "srgb" }
    \\foundry:texture demo:textures.data { source "textures/lit.png" color_space "linear" }
    \\foundry:material demo:materials.lit {
    \\ shading foundry:shading.lit
    \\ base_color { r 0.2 g 0.3 b 0.4 a 1 }
    \\ base_color_texture demo:textures.base
    \\ metallic 0.6 roughness 0.7 metallic_roughness_texture demo:textures.data
    \\ normal_texture demo:textures.data normal_scale -0.5
    \\ occlusion_texture demo:textures.data occlusion_strength 0.8
    \\ emissive { r 0.1 g 0.2 b 0.3 } emissive_texture demo:textures.base emissive_strength 12
    \\ casts_shadow false
    \\}
    \\foundry:material demo:materials.unread { metallic 0.7 normal_texture demo:textures.absent emissive_strength 2 }
    \\foundry:material demo:materials.bad_mr { shading foundry:shading.lit metallic_roughness_texture demo:textures.base }
    \\foundry:material demo:materials.bad_normal { shading foundry:shading.lit normal_texture demo:textures.base }
    \\foundry:material demo:materials.bad_ao { shading foundry:shading.lit occlusion_texture demo:textures.base }
    \\foundry:material demo:materials.bad_emission { shading foundry:shading.lit emissive_texture demo:textures.data }
    \\foundry:material demo:materials.bad_value { shading foundry:shading.lit metallic 2 }
;

test "version 2 lit content resolves five slots with aliases and follows every texture reload" {
    const stack = try Stack.init(1);
    defer stack.deinit();
    const png = try checkerPng(stack.gpa, 8);
    defer stack.gpa.free(png);
    try stack.install("textures/lit.png", png);
    try stack.write("lit.fdt", lit_records);
    try stack.build();
    const material = try stack.content.acquireMaterial(id("demo:materials.lit"));
    const before = stack.materialDesc(material);
    try testing.expect(before.shading.eql(render3d.lit_id));
    try testing.expectEqual(@as(f32, 0.6), before.metallic);
    try testing.expectEqual(@as(f32, 0.7), before.roughness);
    try testing.expectEqual(@as(f32, -0.5), before.normal_scale);
    try testing.expectEqual(@as(f32, 0.8), before.occlusion_strength);
    try testing.expectEqual([3]f32{ 0.1, 0.2, 0.3 }, before.emissive);
    try testing.expectEqual(@as(f32, 12), before.emissive_strength);
    try testing.expect(!before.casts_shadow);
    try testing.expect(!before.base_color_texture.isNone());
    try testing.expect(before.base_color_texture.eql(before.emissive_texture));
    try testing.expect(before.metallic_roughness_texture.eql(before.normal_texture));
    try testing.expect(before.normal_texture.eql(before.occlusion_texture));
    try testing.expectEqual(@as(u32, 2), stack.assets.count());
    // Move both texture payloads and re-read the records. Each slot holds its own
    // reference, even aliases; no old handle remains bound.
    try stack.reload();
    const after = stack.materialDesc(material);
    try testing.expect(!after.base_color_texture.eql(before.base_color_texture));
    try testing.expect(!after.normal_texture.eql(before.normal_texture));
    try testing.expect(after.emissive_texture.eql(after.base_color_texture));
    try testing.expect(after.metallic_roughness_texture.eql(after.occlusion_texture));
    stack.content.releaseMaterial(material);
    try testing.expectEqual(@as(u32, 2), stack.assets.evictUnused(stack.gpa));
    try testing.expectEqual(@as(u32, 0), stack.assets.count());
    try testing.expectEqual(@as(usize, 0), stack.violations());
}

test "lit content refuses wrong slot spaces and ranges; unlit ignores unresolved lit references once" {
    const stack = try Stack.init(1);
    defer stack.deinit();
    const png = try checkerPng(stack.gpa, 8);
    defer stack.gpa.free(png);
    try stack.install("textures/lit.png", png);
    try stack.write("lit.fdt", lit_records);
    try stack.build();
    const unread = try stack.content.acquireMaterial(id("demo:materials.unread"));
    try testing.expect(stack.materialDesc(unread).shading.eql(render3d.unlit_id));
    try testing.expectEqual(@as(f32, 0.7), stack.materialDesc(unread).metallic);
    try testing.expect(stack.materialDesc(unread).normal_texture.isNone());
    var entries = stack.content.materials.iterator();
    const entry = entries.next().?;
    try testing.expect(entry.value.reported_ignored);
    try stack.content.contentChanged();
    try testing.expect(entry.value.reported_ignored);
    try testing.expectEqual(@as(u32, 0), stack.assets.count());
    for ([_][]const u8{ "bad_mr", "bad_normal", "bad_ao", "bad_emission", "bad_value" }) |name| {
        const text = try std.fmt.allocPrint(stack.gpa, "demo:materials.{s}", .{name});
        defer stack.gpa.free(text);
        const material = try stack.content.acquireMaterial(id(text));
        try testing.expectEqual(render3d.content.placeholder.base_color, stack.materialDesc(material).base_color);
    }
    try testing.expectEqual(@as(u32, 2), stack.assets.evictUnused(stack.gpa));
    try testing.expectEqual(@as(usize, 0), stack.violations());
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
