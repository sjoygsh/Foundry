//! Translation from glTF's document into Foundry's rows 3–5.
//!
//! This file is the seam ADR-0053 requires: its output is canonical `.fmesh`/`.fcol`, PNG bytes and
//! checked `.fdt` text. No glTF type leaves `author/gltf/`.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");

const accessor = @import("accessor.zig");
const document = @import("document.zig");
const skin_import = @import("skin.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = data.Diagnostics;
const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Transform = core.math.Transform;
const Vec3 = core.math.Vec3;

pub const Front = enum { minus_z, plus_z };

pub const MaterialMapping = struct {
    name: []const u8,
    material: []const u8,
};

pub const Settings = struct {
    model_id: []const u8,
    source: []const u8,
    front: Front = .minus_z,
    materials: []const MaterialMapping = &.{},
    collision: bool = false,
    collision_exclude: []const []const u8 = &.{},
};

pub const ImageInput = struct {
    bytes: []const u8,
    /// Canonical package-relative source for an external image; null for an embedded one.
    external_path: ?[]const u8 = null,
};

pub const GeneratedAsset = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const Result = struct {
    source: []const u8,
    assets: []const GeneratedAsset,
};

pub const Error = error{ContentInvalid} || Allocator.Error;

pub fn run(
    gpa: Allocator,
    arena: Allocator,
    doc: *const document.Document,
    buffers: []const []const u8,
    images: []const ImageInput,
    settings: Settings,
    limits: document.Limits,
    diags: *Diagnostics,
) Error!Result {
    var ctx: Context = .{
        .gpa = gpa,
        .arena = arena,
        .doc = doc,
        .buffers = buffers,
        .images = images,
        .settings = settings,
        .limits = limits,
        .diags = diags,
    };
    return ctx.translate();
}

const Context = struct {
    gpa: Allocator,
    arena: Allocator,
    doc: *const document.Document,
    buffers: []const []const u8,
    images: []const ImageInput,
    settings: Settings,
    limits: document.Limits,
    diags: *Diagnostics,
    collision_placements: []?Mat4 = &.{},
    rig: ?skin_import.Rig = null,

    fn translate(self: *Context) Error!Result {
        try self.validateDocument();
        self.rig = try (skin_import.Context{ .gpa = self.gpa, .arena = self.arena, .doc = self.doc, .buffers = self.buffers, .source = self.settings.source, .diags = self.diags, .limits = self.limits }).prepare(if (self.settings.front == .plus_z) Mat4.rotationY(std.math.pi) else Mat4.identity);
        var out: std.ArrayList(u8) = .empty;
        var generated: std.ArrayList(GeneratedAsset) = .empty;

        for (self.doc.meshes, 0..) |_, i| {
            const path = try self.generatedPath("mesh", i, asset.schemas.mesh_extension);
            const bytes = try self.translateMesh(@intCast(i));
            try generated.append(self.arena, .{ .path = path, .bytes = bytes });
            const id = try self.generatedId("mesh", i);
            try out.print(self.arena, "{s} {s} {{ source ", .{ asset.schemas.mesh_name, id });
            try self.writeString(&out, path);
            try out.appendSlice(self.arena, " }\n");
        }

        const material_ids = try self.emitMaterials(&out);
        try self.emitTextures(&out);
        try self.emitModel(&out, material_ids);
        if (self.settings.collision) try self.emitCollision(&out, &generated);
        if (self.rig) |rig| {
            const path = try self.generatedPath("skeleton", 0, "fskel");
            const bytes = asset.skeleton.write(self.arena, rig.skeleton) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return self.fail("skeleton", null, "cannot encode imported rig: {s}; repair joint transforms or names", .{@errorName(err)}),
            };
            try generated.append(self.arena, .{ .path = path, .bytes = bytes });
            try out.print(self.arena, "{s} {s}.skeleton {{ source ", .{ asset.schemas.skeleton_name, self.settings.model_id });
            try self.writeString(&out, path);
            try out.appendSlice(self.arena, " }\n");
            for (rig.clips, 0..) |clip, i| {
                const cp = try self.generatedPath("clip", i, "fanim");
                const cb = asset.animation.write(self.arena, clip.source) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return self.fail("animation", clip.name, "cannot encode imported clip: {s}; repair keys", .{@errorName(err)}),
                };
                try generated.append(self.arena, .{ .path = cp, .bytes = cb });
                try out.print(self.arena, "{s} {s} {{ source ", .{ asset.schemas.animation_name, try self.generatedId("clip", i) });
                try self.writeString(&out, cp);
                try out.appendSlice(self.arena, " }\n");
            }
        }

        // Embedded images are runtime products. External images remain ordinary authored
        // assets and are copied by the package host, not duplicated here.
        for (self.images, 0..) |image, i| {
            if (image.external_path != null) continue;
            const path = try self.generatedPath("texture", i, "png");
            try generated.append(self.arena, .{
                .path = path,
                .bytes = try self.arena.dupe(u8, image.bytes),
            });
        }
        return .{
            .source = out.items,
            .assets = generated.items,
        };
    }

    fn validateDocument(self: *Context) Error!void {
        for (self.settings.collision_exclude) |excluded| {
            var matched = false;
            for (self.doc.nodes) |node| if (node.name) |name| {
                if (std.mem.eql(u8, excluded, name)) matched = true;
            };
            if (!matched) return self.fail("model_import.collision_exclude", excluded, "names no node in the file", .{});
        }
        if (!isVersion2(self.doc.asset.version)) return self.fail("asset.version", null, "must be glTF 2.x", .{});
        if (self.doc.asset.minVersion) |minimum| {
            if (!isAtMost20(minimum)) return self.fail("asset.minVersion", null, "requires glTF {s}, newer than the supported 2.0", .{minimum});
        }
        for (self.doc.extensionsRequired) |name| {
            if (!std.mem.eql(u8, name, "KHR_materials_unlit") and !std.mem.eql(u8, name, "KHR_materials_emissive_strength")) {
                return self.fail("extensionsRequired", null, "requires unsupported extension '{s}'", .{name});
            }
        }
        for (self.doc.extensionsUsed) |name| {
            if (std.mem.eql(u8, name, "KHR_materials_unlit") or std.mem.eql(u8, name, "KHR_materials_emissive_strength")) continue;
            var required = false;
            for (self.doc.extensionsRequired) |required_name| {
                if (std.mem.eql(u8, name, required_name)) required = true;
            }
            if (!required) try self.warn("extensionsUsed", null, "extension '{s}' is used but not imported", .{name});
        }
        if (self.doc.cameras) |values| if (values.len != 0) try self.warn("cameras", null, "cameras are not imported in M20", .{});
        if (self.doc.buffers.len != self.buffers.len) return self.fail("buffers", null, "the resolved buffer count does not match the document", .{});
        if (self.doc.images.len != self.images.len) return self.fail("images", null, "the resolved image count does not match the document", .{});
    }

    fn translateMesh(self: *Context, mesh_index: u32) Error![]const u8 {
        const source_mesh = self.doc.meshes[mesh_index];
        if (source_mesh.primitives.len == 0) return self.failMesh(mesh_index, null, "has no primitives", .{});

        var streams: [8]std.ArrayList(u8) = @splat(.empty);
        defer for (&streams) |*stream| stream.deinit(self.gpa);
        var indices: std.ArrayList(u32) = .empty;
        defer indices.deinit(self.gpa);
        var submeshes: std.ArrayList(asset.Submesh) = .empty;
        defer submeshes.deinit(self.gpa);
        var layout: ?Layout = null;
        var vertex_count: u32 = 0;
        var bounds: ?asset.MeshAabb = null;
        const skinned = if (self.rig) |rig| rig.mesh_skinned[mesh_index] else false;
        const joint_bounds = try self.arena.alloc(asset.MeshAabb, if (skinned) self.rig.?.skeleton.parents.len else 0);
        const influenced = try self.arena.alloc(bool, joint_bounds.len);
        @memset(influenced, false);
        @memset(joint_bounds, .{ .min = .zero, .max = .zero });

        for (source_mesh.primitives, 0..) |primitive, primitive_index| {
            const at: u32 = @intCast(primitive_index);
            if (primitive.mode != 4) return self.failMesh(mesh_index, at, "uses primitive mode {d}; only triangle lists (4) are supported", .{primitive.mode});
            if (primitive.targets) |targets| if (targets.len != 0) return self.failMesh(mesh_index, at, "has morph targets; export a skeletal mesh without morph targets", .{});
            const primitive_layout = try self.primitiveLayout(mesh_index, at, primitive);
            const material_index = primitive.material orelse @as(u32, @intCast(self.doc.materials.len));
            if (material_index > self.doc.materials.len) return self.failMesh(mesh_index, at, "references material {d}, outside the material array", .{material_index});
            const material: document.Material = if (material_index == self.doc.materials.len) .{} else self.doc.materials[material_index];
            if (!isUnlit(material) and !self.isMappedMaterial(material)) {
                if (!primitive_layout.normal) return self.failMesh(mesh_index, at, "lit material needs NORMAL; export normals, or mark the material KHR_materials_unlit", .{});
                if (material.normalTexture != null and !primitive_layout.tangent) return self.failMesh(mesh_index, at, "normalTexture needs TANGENT; export tangents", .{});
            }
            if (layout) |expected| {
                if (!expected.eql(primitive_layout)) return self.failMesh(mesh_index, at, "does not carry the same imported attributes and formats as primitive 0", .{});
            } else layout = primitive_layout;

            const position_index = primitive.attributes.map.get("POSITION").?;
            const positions = accessor.open(self.doc, self.buffers, position_index) catch |err|
                return self.failAccessor(mesh_index, at, "POSITION", position_index, err);
            if (positions.component != .f32 or positions.shape != .vec3 or positions.normalized) {
                return self.failMesh(mesh_index, at, "POSITION accessor {d} must be non-normalized FLOAT VEC3", .{position_index});
            }
            if (positions.count == 0) return self.failMesh(mesh_index, at, "POSITION accessor {d} is empty", .{position_index});
            const base_vertex = vertex_count;
            vertex_count = std.math.add(u32, vertex_count, positions.count) catch return self.failMesh(mesh_index, at, "vertex count overflows", .{});
            if (vertex_count > asset.mesh_file.Limits.default.max_vertices) return self.failMesh(mesh_index, at, "exceeds the mesh vertex limit", .{});

            for (0..positions.count) |i| {
                const p = Vec3.init(
                    try self.readFloat(mesh_index, at, "POSITION", positions, @intCast(i), 0),
                    try self.readFloat(mesh_index, at, "POSITION", positions, @intCast(i), 1),
                    try self.readFloat(mesh_index, at, "POSITION", positions, @intCast(i), 2),
                );
                if (!p.isFinite()) return self.failMesh(mesh_index, at, "POSITION accessor {d} contains a non-finite value", .{position_index});
                try appendVec3(&streams[0], self.gpa, p);
                if (bounds) |*box| {
                    box.min.x = @min(box.min.x, p.x);
                    box.min.y = @min(box.min.y, p.y);
                    box.min.z = @min(box.min.z, p.z);
                    box.max.x = @max(box.max.x, p.x);
                    box.max.y = @max(box.max.y, p.y);
                    box.max.z = @max(box.max.z, p.z);
                } else bounds = .{ .min = p, .max = p };
            }

            try self.appendOptional(mesh_index, at, primitive, "NORMAL", .normal, positions.count, &streams[1]);
            try self.appendOptional(mesh_index, at, primitive, "TANGENT", .tangent, positions.count, &streams[5]);
            try self.appendOptional(mesh_index, at, primitive, "TEXCOORD_0", .uv, positions.count, &streams[2]);
            try self.appendOptional(mesh_index, at, primitive, "TEXCOORD_1", .uv, positions.count, &streams[3]);
            try self.appendOptional(mesh_index, at, primitive, "COLOR_0", .color, positions.count, &streams[4]);
            if (skinned) {
                try self.appendSkin(mesh_index, at, primitive, positions, &streams[6], &streams[7], joint_bounds, influenced);
            } else if (primitive_layout.skin) return self.failMesh(mesh_index, at, "JOINTS_0/WEIGHTS_0 have no used skin; export the mesh with its skin in the default scene", .{});

            const first_index: u32 = @intCast(indices.items.len);
            if (primitive.indices) |index_accessor| {
                const view = accessor.open(self.doc, self.buffers, index_accessor) catch |err|
                    return self.failAccessor(mesh_index, at, "indices", index_accessor, err);
                if (view.shape != .scalar or view.normalized or
                    !(view.component == .u8 or view.component == .u16 or view.component == .u32))
                {
                    return self.failMesh(mesh_index, at, "index accessor {d} must be non-normalized UNSIGNED_BYTE, UNSIGNED_SHORT or UNSIGNED_INT SCALAR", .{index_accessor});
                }
                for (0..view.count) |i| {
                    const local = try self.readUnsigned(mesh_index, at, "indices", view, @intCast(i), 0);
                    if (local >= positions.count) return self.failMesh(mesh_index, at, "index {d} is outside the primitive's {d} vertices", .{ local, positions.count });
                    try indices.append(self.gpa, std.math.add(u32, base_vertex, local) catch return self.failMesh(mesh_index, at, "index overflows", .{}));
                }
            } else {
                for (0..positions.count) |i| try indices.append(self.gpa, base_vertex + @as(u32, @intCast(i)));
            }
            const count: u32 = @intCast(indices.items.len - first_index);
            if (count == 0 or count % 3 != 0) return self.failMesh(mesh_index, at, "has {d} indices; a triangle list needs a non-zero multiple of three", .{count});
            try submeshes.append(self.gpa, .{ .first_index = first_index, .index_count = count });
        }

        const final_layout = layout.?;
        var descriptors: std.ArrayList(asset.MeshStream) = .empty;
        defer descriptors.deinit(self.gpa);
        try descriptors.append(self.gpa, .{ .semantic = .position, .format = .float32x3, .bytes = streams[0].items });
        if (final_layout.normal) try descriptors.append(self.gpa, .{ .semantic = .normal, .format = .float32x3, .bytes = streams[1].items });
        if (final_layout.tangent) try descriptors.append(self.gpa, .{ .semantic = .tangent, .format = .float32x4, .bytes = streams[5].items });
        if (final_layout.uv0) try descriptors.append(self.gpa, .{ .semantic = .uv0, .format = .float32x2, .bytes = streams[2].items });
        if (final_layout.uv1) try descriptors.append(self.gpa, .{ .semantic = .uv1, .format = .float32x2, .bytes = streams[3].items });
        if (final_layout.color) |format| try descriptors.append(self.gpa, .{ .semantic = .color, .format = format, .bytes = streams[4].items });
        if (skinned) {
            try descriptors.append(self.gpa, .{ .semantic = .joints, .format = .uint8x4, .bytes = streams[6].items });
            try descriptors.append(self.gpa, .{ .semantic = .weights, .format = .float32x4, .bytes = streams[7].items });
        }

        const index_format: asset.MeshIndexFormat = if (vertex_count <= 65_536) .uint16 else .uint32;
        var index_bytes: std.ArrayList(u8) = .empty;
        defer index_bytes.deinit(self.gpa);
        for (indices.items) |index| switch (index_format) {
            .uint16 => try appendInt(u16, &index_bytes, self.gpa, @intCast(index)),
            .uint32 => try appendInt(u32, &index_bytes, self.gpa, index),
        };
        const mesh: asset.Mesh = .{
            .vertex_count = vertex_count,
            .streams = descriptors.items,
            .index_format = index_format,
            .indices = index_bytes.items,
            .submeshes = submeshes.items,
            .bounds = bounds.?,
            .joint_bounds = joint_bounds,
        };
        return asset.mesh_file.write(self.arena, mesh) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.failMesh(mesh_index, null, "does not form a valid runtime mesh: {s}", .{@errorName(err)}),
        };
    }

    const Layout = struct {
        normal: bool = false,
        tangent: bool = false,
        uv0: bool = false,
        uv1: bool = false,
        color: ?asset.MeshVertexFormat = null,
        skin: bool = false,

        fn eql(a: Layout, b: Layout) bool {
            return a.normal == b.normal and a.tangent == b.tangent and a.uv0 == b.uv0 and a.uv1 == b.uv1 and a.color == b.color and a.skin == b.skin;
        }
    };

    fn primitiveLayout(self: *Context, mesh_index: u32, primitive_index: u32, primitive: document.Primitive) Error!Layout {
        if (primitive.attributes.map.get("POSITION") == null) return self.failMesh(mesh_index, primitive_index, "has no POSITION attribute", .{});
        var result: Layout = .{};
        var it = primitive.attributes.map.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const index = entry.value_ptr.*;
            if (std.mem.eql(u8, name, "POSITION")) continue;
            if (std.mem.eql(u8, name, "NORMAL")) {
                result.normal = true;
            } else if (std.mem.eql(u8, name, "TEXCOORD_0")) {
                result.uv0 = true;
            } else if (std.mem.eql(u8, name, "TEXCOORD_1")) {
                result.uv1 = true;
            } else if (std.mem.eql(u8, name, "COLOR_0")) {
                const view = accessor.open(self.doc, self.buffers, index) catch |err|
                    return self.failAccessor(mesh_index, primitive_index, name, index, err);
                result.color = try self.colorFormat(mesh_index, primitive_index, index, view);
            } else if (std.mem.eql(u8, name, "TANGENT")) {
                result.tangent = true;
            } else if (std.mem.startsWith(u8, name, "JOINTS_") or std.mem.startsWith(u8, name, "WEIGHTS_")) {
                if (!std.mem.eql(u8, name, "JOINTS_0") and !std.mem.eql(u8, name, "WEIGHTS_0")) return self.failMesh(mesh_index, primitive_index, "attribute '{s}' exceeds four influences; export only JOINTS_0/WEIGHTS_0", .{name});
                result.skin = true;
            } else {
                try self.warnMesh(mesh_index, primitive_index, "attribute '{s}' is not imported", .{name});
            }
        }
        return result;
    }

    const AttributeKind = enum { normal, tangent, uv, color };

    fn appendSkin(self: *Context, mesh: u32, primitive_index: u32, primitive: document.Primitive, positions: accessor.View, joints_out: *std.ArrayList(u8), weights_out: *std.ArrayList(u8), boxes: []asset.MeshAabb, influenced: []bool) Error!void {
        const ji = primitive.attributes.map.get("JOINTS_0") orelse return self.failMesh(mesh, primitive_index, "has no JOINTS_0; export joint indices", .{});
        const wi = primitive.attributes.map.get("WEIGHTS_0") orelse return self.failMesh(mesh, primitive_index, "has no WEIGHTS_0; export skin weights", .{});
        const joints = accessor.open(self.doc, self.buffers, ji) catch |err| return self.failAccessor(mesh, primitive_index, "JOINTS_0", ji, err);
        const weights = accessor.open(self.doc, self.buffers, wi) catch |err| return self.failAccessor(mesh, primitive_index, "WEIGHTS_0", wi, err);
        if (joints.shape != .vec4 or joints.normalized or !(joints.component == .u8 or joints.component == .u16) or joints.count != positions.count) return self.failMesh(mesh, primitive_index, "JOINTS_0 must be non-normalized UNSIGNED_BYTE/SHORT VEC4 with POSITION's count; repair the accessor", .{});
        if (weights.shape != .vec4 or weights.count != positions.count or !((weights.component == .f32 and !weights.normalized) or ((weights.component == .u8 or weights.component == .u16) and weights.normalized))) return self.failMesh(mesh, primitive_index, "WEIGHTS_0 must be FLOAT or normalized UNSIGNED_BYTE/SHORT VEC4 with POSITION's count; repair the accessor", .{});
        var normalized: u32 = 0;
        const rig = self.rig.?;
        for (0..positions.count) |v| {
            var js: [4]u8 = undefined;
            var ws: [4]f32 = undefined;
            var sum: f64 = 0;
            for (0..4) |lane| {
                const j = try self.readUnsigned(mesh, primitive_index, "JOINTS_0", joints, @intCast(v), @intCast(lane));
                if (j >= rig.remap.len) return self.failMesh(mesh, primitive_index, "vertex {d} joint {d} is outside the skin; repair joint indices", .{ v, j });
                js[lane] = rig.remap[j];
                ws[lane] = try self.readFloat(mesh, primitive_index, "WEIGHTS_0", weights, @intCast(v), @intCast(lane));
                if (!std.math.isFinite(ws[lane]) or ws[lane] < 0) return self.failMesh(mesh, primitive_index, "vertex {d} has negative or non-finite weights; repair skin weights", .{v});
                sum += ws[lane];
                if (ws[lane] > 0) for (0..lane) |previous| {
                    if (ws[previous] > 0 and js[previous] == js[lane]) return self.failMesh(mesh, primitive_index, "vertex {d} repeats a weighted joint; merge duplicate influences on export", .{v});
                };
            }
            if (sum == 0) return self.failMesh(mesh, primitive_index, "vertex {d} has all-zero weights; assign an influence", .{v});
            if (@abs(sum - 1) > 1e-6) normalized += 1;
            const p = Vec3.init(try self.readFloat(mesh, primitive_index, "POSITION", positions, @intCast(v), 0), try self.readFloat(mesh, primitive_index, "POSITION", positions, @intCast(v), 1), try self.readFloat(mesh, primitive_index, "POSITION", positions, @intCast(v), 2));
            for (&ws, js) |*w, j| {
                w.* = @floatCast(@as(f64, w.*) / sum);
                if (w.* > 0) {
                    if (!influenced[j]) {
                        boxes[j] = .{ .min = p, .max = p };
                        influenced[j] = true;
                    } else {
                        boxes[j].min = .init(@min(boxes[j].min.x, p.x), @min(boxes[j].min.y, p.y), @min(boxes[j].min.z, p.z));
                        boxes[j].max = .init(@max(boxes[j].max.x, p.x), @max(boxes[j].max.y, p.y), @max(boxes[j].max.z, p.z));
                    }
                }
            }
            try joints_out.appendSlice(self.gpa, &js);
            for (ws) |w| try appendF32(weights_out, self.gpa, w);
        }
        if (normalized != 0) try self.warnMesh(mesh, primitive_index, "normalized weights for {d} vertex/vertices", .{normalized});
    }

    fn appendOptional(self: *Context, mesh_index: u32, primitive_index: u32, primitive: document.Primitive, name: []const u8, kind: AttributeKind, expected_count: u32, out: *std.ArrayList(u8)) Error!void {
        const index = primitive.attributes.map.get(name) orelse return;
        const view = accessor.open(self.doc, self.buffers, index) catch |err|
            return self.failAccessor(mesh_index, primitive_index, name, index, err);
        if (view.count != expected_count) return self.failMesh(mesh_index, primitive_index, "{s} accessor {d} has {d} elements; POSITION has {d}", .{ name, index, view.count, expected_count });
        switch (kind) {
            .normal => {
                if (view.component != .f32 or view.shape != .vec3 or view.normalized) return self.failMesh(mesh_index, primitive_index, "NORMAL accessor {d} must be non-normalized FLOAT VEC3", .{index});
                for (0..view.count) |i| {
                    const value = Vec3.init(
                        try self.readFloat(mesh_index, primitive_index, name, view, @intCast(i), 0),
                        try self.readFloat(mesh_index, primitive_index, name, view, @intCast(i), 1),
                        try self.readFloat(mesh_index, primitive_index, name, view, @intCast(i), 2),
                    );
                    if (!value.isFinite() or @abs(value.length() - 1) > 1e-3) return self.failMesh(mesh_index, primitive_index, "NORMAL accessor {d} contains a non-unit or non-finite value", .{index});
                    try appendVec3(out, self.gpa, value);
                }
            },
            .tangent => {
                if (view.component != .f32 or view.shape != .vec4 or view.normalized) return self.failMesh(mesh_index, primitive_index, "TANGENT accessor {d} must be non-normalized FLOAT VEC4", .{index});
                for (0..view.count) |i| {
                    var values: [4]f32 = undefined;
                    for (0..4) |lane| values[lane] = try self.readFloat(mesh_index, primitive_index, name, view, @intCast(i), @intCast(lane));
                    const xyz = Vec3.init(values[0], values[1], values[2]);
                    if (!xyz.isFinite() or @abs(xyz.length() - 1) > 1e-3 or (values[3] != 1 and values[3] != -1)) return self.failMesh(mesh_index, primitive_index, "TANGENT accessor {d} needs finite unit xyz and w exactly +1 or -1", .{index});
                    for (values) |value| try appendF32(out, self.gpa, value);
                }
            },
            .uv => {
                if (view.shape != .vec2 or !((view.component == .f32 and !view.normalized) or
                    ((view.component == .u8 or view.component == .u16) and view.normalized)))
                {
                    return self.failMesh(mesh_index, primitive_index, "{s} accessor {d} must be FLOAT or normalized UNSIGNED_BYTE/UNSIGNED_SHORT VEC2", .{ name, index });
                }
                for (0..view.count) |i| {
                    try appendF32(out, self.gpa, try self.readFloat(mesh_index, primitive_index, name, view, @intCast(i), 0));
                    try appendF32(out, self.gpa, try self.readFloat(mesh_index, primitive_index, name, view, @intCast(i), 1));
                }
            },
            .color => {
                const format = try self.colorFormat(mesh_index, primitive_index, index, view);
                for (0..view.count) |i| switch (format) {
                    .unorm8x4 => {
                        try out.append(self.gpa, @intCast(try self.readUnsigned(mesh_index, primitive_index, name, view, @intCast(i), 0)));
                        try out.append(self.gpa, @intCast(try self.readUnsigned(mesh_index, primitive_index, name, view, @intCast(i), 1)));
                        try out.append(self.gpa, @intCast(try self.readUnsigned(mesh_index, primitive_index, name, view, @intCast(i), 2)));
                        try out.append(self.gpa, if (view.shape == .vec4) @intCast(try self.readUnsigned(mesh_index, primitive_index, name, view, @intCast(i), 3)) else 255);
                    },
                    .float32x4 => {
                        for (0..3) |lane| try appendF32(out, self.gpa, try self.readFloat(mesh_index, primitive_index, name, view, @intCast(i), @intCast(lane)));
                        try appendF32(out, self.gpa, if (view.shape == .vec4) try self.readFloat(mesh_index, primitive_index, name, view, @intCast(i), 3) else 1);
                    },
                    else => unreachable,
                };
            },
        }
    }

    fn colorFormat(self: *Context, mesh_index: u32, primitive_index: u32, index: u32, view: accessor.View) Error!asset.MeshVertexFormat {
        if (!(view.shape == .vec3 or view.shape == .vec4)) return self.failMesh(mesh_index, primitive_index, "COLOR_0 accessor {d} must be VEC3 or VEC4", .{index});
        if (view.component == .u8 and view.normalized) return .unorm8x4;
        if ((view.component == .u16 and view.normalized) or (view.component == .f32 and !view.normalized)) return .float32x4;
        return self.failMesh(mesh_index, primitive_index, "COLOR_0 accessor {d} must be FLOAT or normalized UNSIGNED_BYTE/UNSIGNED_SHORT", .{index});
    }

    fn emitMaterials(self: *Context, out: *std.ArrayList(u8)) Error![]const []const u8 {
        const needs_default = self.hasPrimitiveWithoutMaterial();
        const slot_count = self.doc.materials.len + @intFromBool(needs_default);
        const ids = try self.arena.alloc([]const u8, slot_count);
        var mapping_used = try self.gpa.alloc(bool, self.settings.materials.len);
        defer self.gpa.free(mapping_used);
        @memset(mapping_used, false);

        for (self.doc.materials, 0..) |material, i| {
            var mapped: ?[]const u8 = null;
            if (material.name) |name| {
                for (self.settings.materials, 0..) |mapping, m| {
                    if (!std.mem.eql(u8, mapping.name, name)) continue;
                    if (mapped != null) return self.fail("materials", name, "is matched by more than one import mapping", .{});
                    mapped = mapping.material;
                    mapping_used[m] = true;
                }
            }
            ids[i] = mapped orelse try self.generatedId("material", i);
            if (mapped == null) try self.emitMaterial(out, @intCast(i), material, ids[i]);
        }
        if (needs_default) {
            const index = self.doc.materials.len;
            ids[index] = try self.generatedId("material", index);
            try self.emitMaterial(out, @intCast(index), .{}, ids[index]);
        }
        for (mapping_used, self.settings.materials) |used, mapping| {
            if (!used) return self.fail("model_import.materials", mapping.name, "maps no material in the file", .{});
        }
        return ids;
    }

    fn isMappedMaterial(self: *Context, material: document.Material) bool {
        const name = material.name orelse return false;
        for (self.settings.materials) |mapping| if (std.mem.eql(u8, mapping.name, name)) return true;
        return false;
    }

    fn emitMaterial(self: *Context, out: *std.ArrayList(u8), index: u32, material: document.Material, id: []const u8) Error!void {
        const path = try std.fmt.allocPrint(self.arena, "materials[{d}]", .{index});
        const unlit = isUnlit(material);
        for (material.pbrMetallicRoughness.baseColorFactor) |component| {
            if (!std.math.isFinite(component) or component < 0 or component > 1) return self.fail(path, material.name, "has a baseColorFactor outside [0, 1] or not finite", .{});
        }
        if (!std.math.isFinite(material.alphaCutoff) or material.alphaCutoff < 0 or material.alphaCutoff > 1) return self.fail(path, material.name, "has an alphaCutoff outside [0, 1] or not finite", .{});
        const alpha = if (std.mem.eql(u8, material.alphaMode, "OPAQUE"))
            "opaque"
        else if (std.mem.eql(u8, material.alphaMode, "MASK"))
            "mask"
        else if (std.mem.eql(u8, material.alphaMode, "BLEND"))
            "blend"
        else
            return self.fail(path, material.name, "has unknown alphaMode '{s}'", .{material.alphaMode});

        try out.print(self.arena, "{s} {s} {{ shading foundry:shading.{s} base_color {{ r {d} g {d} b {d} a {d} }}", .{
            asset.schemas.material_name,
            id,
            if (unlit) @as([]const u8, "unlit") else "lit",
            material.pbrMetallicRoughness.baseColorFactor[0],
            material.pbrMetallicRoughness.baseColorFactor[1],
            material.pbrMetallicRoughness.baseColorFactor[2],
            material.pbrMetallicRoughness.baseColorFactor[3],
        });
        if (material.pbrMetallicRoughness.baseColorTexture) |texture_info| {
            const image_index = try self.imageForTexture(path, texture_info);
            const texture_id = try self.generatedId("texture", image_index);
            try out.print(self.arena, " base_color_texture {s}", .{texture_id});
        }
        if (!unlit) {
            const pbr = material.pbrMetallicRoughness;
            const metallic = pbr.metallicFactor orelse 1;
            const roughness = pbr.roughnessFactor orelse 1;
            if (!unitInterval(metallic) or !unitInterval(roughness)) return self.fail(path, material.name, "metallicFactor and roughnessFactor must be finite in [0, 1]", .{});
            try out.print(self.arena, " metallic {d} roughness {d}", .{ metallic, roughness });
            if (pbr.metallicRoughnessTexture) |info| try self.emitTextureRef(out, path, "metallic_roughness_texture", info);
            if (material.normalTexture) |info| {
                if (!std.math.isFinite(info.scale)) return self.fail(path, material.name, "normalTexture.scale must be finite", .{});
                try self.emitTextureRef(out, path, "normal_texture", info);
                try out.print(self.arena, " normal_scale {d}", .{info.scale});
            }
            if (material.occlusionTexture) |info| {
                if (!unitInterval(info.strength)) return self.fail(path, material.name, "occlusionTexture.strength must be finite in [0, 1]", .{});
                try self.emitTextureRef(out, path, "occlusion_texture", info);
                try out.print(self.arena, " occlusion_strength {d}", .{info.strength});
            }
            const emissive = material.emissiveFactor orelse .{ 0, 0, 0 };
            for (emissive) |component| if (!unitInterval(component)) return self.fail(path, material.name, "emissiveFactor must be finite in [0, 1]", .{});
            try out.print(self.arena, " emissive {{ r {d} g {d} b {d} }}", .{ emissive[0], emissive[1], emissive[2] });
            if (material.emissiveTexture) |info| try self.emitTextureRef(out, path, "emissive_texture", info);
            const strength = try self.emissiveStrength(path, material);
            try out.print(self.arena, " emissive_strength {d}", .{strength});
        }
        try out.print(self.arena, " alpha_mode \"{s}\" alpha_cutoff {d} double_sided {s} }}\n", .{
            alpha,
            material.alphaCutoff,
            if (material.doubleSided) "true" else "false",
        });
    }

    fn emitTextureRef(self: *Context, out: *std.ArrayList(u8), path: []const u8, name: []const u8, info: anytype) Error!void {
        const image_index = try self.imageForTexture(path, info);
        const texture_id = try self.generatedId("texture", image_index);
        try out.print(self.arena, " {s} {s}", .{ name, texture_id });
    }

    fn emissiveStrength(self: *Context, path: []const u8, material: document.Material) Error!f32 {
        const extensions = material.extensions orelse return 1;
        const value = extensions.map.get("KHR_materials_emissive_strength") orelse return 1;
        const object = switch (value) {
            .object => |v| v,
            else => return self.fail(path, material.name, "KHR_materials_emissive_strength must be an object", .{}),
        };
        const raw = object.get("emissiveStrength") orelse return 1;
        const strength: f32 = switch (raw) {
            .float => |v| @floatCast(v),
            .integer => |v| @floatFromInt(v),
            else => return self.fail(path, material.name, "emissiveStrength must be a non-negative finite number", .{}),
        };
        if (!std.math.isFinite(strength) or strength < 0) return self.fail(path, material.name, "emissiveStrength must be a non-negative finite number", .{});
        return strength;
    }

    const Sampling = struct { filter: []const u8 = "linear", wrap: []const u8 = "repeat" };

    fn emitTextures(self: *Context, out: *std.ArrayList(u8)) Error!void {
        var choices = try self.gpa.alloc(?Sampling, self.images.len);
        defer self.gpa.free(choices);
        @memset(choices, null);
        var spaces = try self.gpa.alloc(?bool, self.images.len); // true: sRGB; false: linear
        defer self.gpa.free(spaces);
        @memset(spaces, null);
        for (self.doc.materials, 0..) |material, i| {
            const uses = textureUses(material);
            for (uses) |use| {
                const info = use.info orelse continue;
                const path = try std.fmt.allocPrint(self.arena, "materials[{d}].{s}", .{ i, use.name });
                const image_index = try self.imageForTexture(path, info);
                const texture = self.doc.textures[info.index];
                const choice = try self.samplingFor(path, texture.sampler);
                if (choices[image_index]) |previous| {
                    if (!std.mem.eql(u8, previous.filter, choice.filter) or !std.mem.eql(u8, previous.wrap, choice.wrap)) {
                        return self.fail(path, null, "uses image {d} with sampling different from another texture; one Foundry texture has one sampler", .{image_index});
                    }
                } else choices[image_index] = choice;
                if (spaces[image_index]) |previous| {
                    if (previous != use.srgb) return self.fail(path, null, "uses image {d} in both sRGB and linear slots; use separate images for the two colour spaces", .{image_index});
                } else spaces[image_index] = use.srgb;
            }
        }

        for (self.images, 0..) |image, i| {
            const id = try self.generatedId("texture", i);
            const source = image.external_path orelse try self.generatedPath("texture", i, "png");
            const sampling = choices[i] orelse Sampling{};
            try out.print(self.arena, "{s} {s} {{ source ", .{ asset.schemas.texture_name, id });
            try self.writeString(out, source);
            try out.print(self.arena, " filter \"{s}\" wrap \"{s}\" color_space \"{s}\" mipmaps true }}\n", .{ sampling.filter, sampling.wrap, if (spaces[i] orelse true) @as([]const u8, "srgb") else "linear" });
        }
    }

    fn imageForTexture(self: *Context, path: []const u8, info: anytype) Error!u32 {
        if (info.texCoord != 0) return self.fail(path, null, "uses texCoord {d}; export TEXCOORD_0 for every material texture", .{info.texCoord});
        if (info.extensions) |extensions| {
            if (extensions.map.contains("KHR_texture_transform")) try self.warn(path, null, "KHR_texture_transform is ignored", .{});
        }
        if (info.index >= self.doc.textures.len) return self.fail(path, null, "references texture {d}, outside the texture array", .{info.index});
        const image_index = self.doc.textures[info.index].source orelse return self.fail(path, null, "references texture {d}, which has no source image", .{info.index});
        if (image_index >= self.images.len) return self.fail(path, null, "references image {d}, outside the image array", .{image_index});
        return image_index;
    }

    fn samplingFor(self: *Context, path: []const u8, maybe_index: ?u32) Error!Sampling {
        const sampler = if (maybe_index) |index| blk: {
            if (index >= self.doc.samplers.len) return self.fail(path, null, "references sampler {d}, outside the sampler array", .{index});
            break :blk self.doc.samplers[index];
        } else document.Sampler{};
        if (sampler.wrapS != sampler.wrapT) return self.fail(path, null, "has different wrapS ({d}) and wrapT ({d}); Foundry textures use one wrap mode", .{ sampler.wrapS, sampler.wrapT });
        const wrap = switch (sampler.wrapS) {
            33_071 => "clamp",
            10_497 => "repeat",
            33_648 => "mirror",
            else => return self.fail(path, null, "uses unsupported wrap value {d}", .{sampler.wrapS}),
        };
        return .{
            .filter = if (sampler.magFilter == 9728) "nearest" else "linear",
            .wrap = wrap,
        };
    }

    fn emitModel(self: *Context, out: *std.ArrayList(u8), material_ids: []const []const u8) Error!void {
        const scene_index = self.doc.scene orelse if (self.doc.scenes.len != 0) @as(u32, 0) else return self.fail("scenes", null, "has no default scene and no scenes[0] to import", .{});
        if (scene_index >= self.doc.scenes.len) return self.fail("scene", null, "references scenes[{d}], outside the scene array", .{scene_index});

        try out.print(self.arena, "{s} {s} {{\n    slots [", .{ asset.schemas.model_name, self.settings.model_id });
        for (material_ids, 0..) |id, i| {
            const name = if (i < self.doc.materials.len) self.doc.materials[i].name orelse try std.fmt.allocPrint(self.arena, "material{d}", .{i}) else "default";
            try out.appendSlice(self.arena, " { name ");
            try self.writeString(out, name);
            try out.print(self.arena, " material {s} }}", .{id});
        }
        try out.appendSlice(self.arena, " ]\n    parts [");

        var visited = try self.gpa.alloc(bool, self.doc.nodes.len);
        defer self.gpa.free(visited);
        @memset(visited, false);
        if (self.settings.collision) {
            self.collision_placements = try self.arena.alloc(?Mat4, self.doc.nodes.len);
            @memset(self.collision_placements, null);
        }
        const Stack = struct { node: u32, parent: Mat4, depth: u32, excluded: bool = false };
        var stack: std.ArrayList(Stack) = .empty;
        defer stack.deinit(self.gpa);
        const roots = self.doc.scenes[scene_index].nodes;
        var r = roots.len;
        while (r > 0) {
            r -= 1;
            try stack.append(self.gpa, .{ .node = roots[r], .parent = Mat4.identity, .depth = 1 });
        }
        while (stack.pop()) |entry| {
            if (entry.node >= self.doc.nodes.len) return self.fail("scene.nodes", null, "references nodes[{d}], outside the node array", .{entry.node});
            if (entry.depth > self.limits.max_node_depth) return self.failNode(entry.node, "is deeper than the {d}-node limit", .{self.limits.max_node_depth});
            if (visited[entry.node]) return self.failNode(entry.node, "is reached twice (a cycle or a second parent)", .{});
            visited[entry.node] = true;
            const node = self.doc.nodes[entry.node];
            var excluded = entry.excluded;
            if (node.name) |name| for (self.settings.collision_exclude) |omit| {
                if (std.mem.eql(u8, name, omit)) excluded = true;
            };
            if (node.camera != null) try self.warnNode(entry.node, "camera placement is not imported in M20", .{});
            const local = try self.nodeMatrix(entry.node, node);
            const world = Mat4.mul(entry.parent, local);
            if (node.mesh) |mesh_index| {
                if (mesh_index >= self.doc.meshes.len) return self.failNode(entry.node, "references meshes[{d}], outside the mesh array", .{mesh_index});
                var part_matrix = world;
                if (self.settings.front == .plus_z) part_matrix = Mat4.mul(part_matrix, Mat4.rotationY(std.math.pi));
                if (node.skin != null) part_matrix = .identity;
                const transform = Transform.fromMat4Exact(part_matrix) catch return self.failNode(entry.node, "has a flattened transform that is not exactly representable as TRS", .{});
                if (self.settings.collision and !excluded) self.collision_placements[entry.node] = part_matrix;
                for (self.doc.meshes[mesh_index].primitives, 0..) |primitive, submesh| {
                    const slot: u32 = primitive.material orelse @intCast(self.doc.materials.len);
                    if (slot >= material_ids.len) return self.failMesh(mesh_index, @intCast(submesh), "references material {d}, outside the material array", .{slot});
                    try self.writePart(out, mesh_index, @intCast(submesh), slot, transform);
                }
            }
            var child = node.children.len;
            while (child > 0) {
                child -= 1;
                try stack.append(self.gpa, .{ .node = node.children[child], .parent = world, .depth = entry.depth + 1, .excluded = excluded });
            }
        }
        try out.appendSlice(self.arena, " ]\n");
        if (self.rig) |rig| {
            try out.print(self.arena, "    skeleton {s}.skeleton\n    clips [", .{self.settings.model_id});
            for (rig.clips, 0..) |clip, i| {
                try out.appendSlice(self.arena, " { name ");
                try self.writeString(out, clip.name);
                try out.print(self.arena, " clip {s} }}", .{try self.generatedId("clip", i)});
            }
            try out.appendSlice(self.arena, " ]\n");
        }
        try out.appendSlice(self.arena, "}\n");
    }

    fn emitCollision(self: *Context, out: *std.ArrayList(u8), generated: *std.ArrayList(GeneratedAsset)) Error!void {
        var positions: std.ArrayList(Vec3) = .empty;
        defer positions.deinit(self.gpa);
        var indices: std.ArrayList(u32) = .empty;
        defer indices.deinit(self.gpa);
        var dropped: u64 = 0;
        // Node array order, not traversal order. Model flattening validated the default
        // scene already; inactive and excluded subtrees have no placement here.
        for (self.collision_placements, 0..) |placement, node_index| {
            const matrix = placement orelse continue;
            const mesh_index = self.doc.nodes[node_index].mesh.?;
            var view = asset.mesh_file.read(generated.items[mesh_index].bytes, .default) catch
                return self.failNode(@intCast(node_index), "has invalid generated collision input", .{});
            const mesh = view.mesh();
            if (positions.items.len + mesh.vertex_count > asset.collision_mesh.Limits.default.max_vertices)
                return self.fail("model_import.collision", null, "exceeds the collision vertex limit", .{});
            const base: u32 = @intCast(positions.items.len);
            for (mesh.streams) |stream| {
                if (stream.semantic != .position) continue;
                for (std.mem.bytesAsSlice(Vec3, stream.bytes), 0..) |local, vertex| {
                    var p = matrix.mulPoint(local);
                    if (self.doc.nodes[node_index].skin != null) {
                        var js: []const u8 = &.{};
                        var ws: []const u8 = &.{};
                        for (mesh.streams) |skin_stream| switch (skin_stream.semantic) {
                            .joints => js = skin_stream.bytes,
                            .weights => ws = skin_stream.bytes,
                            else => {},
                        };
                        p = .zero;
                        for (0..4) |lane| {
                            const weight: f32 = @bitCast(std.mem.readInt(u32, ws[(vertex * 4 + lane) * 4 ..][0..4], .little));
                            if (weight != 0) p = p.add(self.rig.?.bind_matrices[js[vertex * 4 + lane]].mulPoint(local).scale(weight));
                        }
                    }
                    if (!asset.collision_mesh.positionValid(p)) return self.failNode(@intCast(node_index), "has collision geometry outside the finite ±8192 m envelope", .{});
                    try positions.append(self.gpa, p);
                }
            }
            for (mesh.submeshes) |submesh| {
                var at = submesh.first_index;
                const end = at + submesh.index_count;
                while (at < end) : (at += 3) {
                    var triangle: [3]u32 = undefined;
                    for (&triangle, 0..) |*index, corner| {
                        const offset = (@as(usize, at) + corner) * mesh.index_format.size();
                        index.* = base + switch (mesh.index_format) {
                            .uint16 => @as(u32, std.mem.readInt(u16, mesh.indices[offset..][0..2], .little)),
                            .uint32 => std.mem.readInt(u32, mesh.indices[offset..][0..4], .little),
                        };
                    }
                    if (asset.collision_mesh.degenerate(positions.items[triangle[0]], positions.items[triangle[1]], positions.items[triangle[2]])) {
                        dropped += 1;
                        continue;
                    }
                    if (indices.items.len / 3 >= asset.collision_mesh.Limits.default.max_triangles)
                        return self.fail("model_import.collision", null, "exceeds the collision triangle limit", .{});
                    try indices.appendSlice(self.gpa, &triangle);
                }
            }
        }
        if (dropped != 0) try self.warn("model_import.collision", null, "dropped {d} degenerate triangle(s)", .{dropped});
        if (indices.items.len == 0) return self.fail("model_import.collision", null, "derives an empty collision mesh", .{});
        // Private generated path; identity is the model ID plus the unnumbered segment.
        const numbered = try self.generatedPath("collision", 0, asset.schemas.collision_mesh_extension);
        const bytes = asset.collision_mesh.write(self.arena, positions.items, indices.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail("model_import.collision", null, "cannot encode collision geometry: {s}", .{@errorName(err)}),
        };
        try generated.append(self.arena, .{ .path = numbered, .bytes = bytes });
        try out.print(self.arena, "{s} {s}.collision {{ source ", .{ asset.schemas.collision_mesh_name, self.settings.model_id });
        try self.writeString(out, numbered);
        try out.appendSlice(self.arena, " }\n");
    }

    fn nodeMatrix(self: *Context, index: u32, node: document.Node) Error!Mat4 {
        const has_trs = node.translation != null or node.rotation != null or node.scale != null;
        if (node.matrix != null and has_trs) return self.failNode(index, "writes both matrix and TRS", .{});
        if (node.matrix) |flat| {
            var matrix: Mat4 = undefined;
            for (0..4) |column| {
                for (0..4) |row| matrix.cols[column][row] = flat[column * 4 + row];
            }
            return matrix;
        }
        const t = node.translation orelse .{ 0, 0, 0 };
        const r = node.rotation orelse .{ 0, 0, 0, 1 };
        const s = node.scale orelse .{ 1, 1, 1 };
        const transform: Transform = .{
            .translation = Vec3.init(t[0], t[1], t[2]),
            .rotation = Quat{ .x = r[0], .y = r[1], .z = r[2], .w = r[3] },
            .scale = Vec3.init(s[0], s[1], s[2]),
        };
        if (!transform.isValid()) return self.failNode(index, "has a non-finite TRS or a non-unit rotation", .{});
        return transform.toMat4();
    }

    fn writePart(self: *Context, out: *std.ArrayList(u8), mesh_index: u32, submesh: u32, slot: u32, transform: Transform) Error!void {
        const mesh_id = try self.generatedId("mesh", mesh_index);
        try out.print(
            self.arena,
            " {{ mesh {s} submesh {d} slot {d} translation {{ x {d} y {d} z {d} }} rotation {{ x {d} y {d} z {d} w {d} }} scale {{ x {d} y {d} z {d} }} }}",
            .{ mesh_id, submesh, slot, transform.translation.x, transform.translation.y, transform.translation.z, transform.rotation.x, transform.rotation.y, transform.rotation.z, transform.rotation.w, transform.scale.x, transform.scale.y, transform.scale.z },
        );
    }

    fn hasPrimitiveWithoutMaterial(self: *const Context) bool {
        for (self.doc.meshes) |mesh| for (mesh.primitives) |primitive| if (primitive.material == null) return true;
        return false;
    }

    fn generatedId(self: *Context, kind: []const u8, index: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}.{s}{d}", .{ self.settings.model_id, kind, index });
    }

    fn generatedPath(self: *Context, kind: []const u8, index: anytype, extension: []const u8) Allocator.Error![]const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, self.settings.source, '/');
        const dir = if (slash) |at| self.settings.source[0..at] else "";
        const file = if (slash) |at| self.settings.source[at + 1 ..] else self.settings.source;
        const dot = std.mem.lastIndexOfScalar(u8, file, '.') orelse file.len;
        const stem = file[0..dot];
        return if (dir.len == 0)
            std.fmt.allocPrint(self.arena, "{s}/{s}{d}.{s}", .{ stem, kind, index, extension })
        else
            std.fmt.allocPrint(self.arena, "{s}/{s}/{s}{d}.{s}", .{ dir, stem, kind, index, extension });
    }

    fn writeString(self: *Context, out: *std.ArrayList(u8), text: []const u8) Error!void {
        data.emit.writeString(out, self.arena, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail("generated record", null, "contains text that cannot be emitted: {s}", .{@errorName(err)}),
        };
    }

    fn readFloat(
        self: *Context,
        mesh: u32,
        primitive: u32,
        semantic: []const u8,
        view: accessor.View,
        element: u32,
        lane: u32,
    ) Error!f32 {
        return view.float(element, lane) catch |err|
            return self.failMesh(mesh, primitive, "{s} accessor cannot be read: {s}", .{ semantic, @errorName(err) });
    }

    fn readUnsigned(
        self: *Context,
        mesh: u32,
        primitive: u32,
        semantic: []const u8,
        view: accessor.View,
        element: u32,
        lane: u32,
    ) Error!u32 {
        return view.unsigned(element, lane) catch |err|
            return self.failMesh(mesh, primitive, "{s} accessor cannot be read: {s}", .{ semantic, @errorName(err) });
    }

    fn failAccessor(self: *Context, mesh: u32, primitive: u32, semantic: []const u8, index: u32, err: anyerror) Error {
        return self.failMesh(mesh, primitive, "{s} accessor {d} is invalid: {s}", .{ semantic, index, @errorName(err) });
    }

    fn failMesh(self: *Context, mesh: u32, primitive: ?u32, comptime fmt: []const u8, args: anytype) Error {
        const path = if (primitive) |p|
            std.fmt.allocPrint(self.arena, "meshes[{d}].primitives[{d}]", .{ mesh, p }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(self.arena, "meshes[{d}]", .{mesh}) catch return error.OutOfMemory;
        return self.fail(path, self.doc.meshes[mesh].name, fmt, args);
    }

    fn warnMesh(self: *Context, mesh: u32, primitive: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const path = try std.fmt.allocPrint(self.arena, "meshes[{d}].primitives[{d}]", .{ mesh, primitive });
        try self.warn(path, self.doc.meshes[mesh].name, fmt, args);
    }

    fn failNode(self: *Context, node: u32, comptime fmt: []const u8, args: anytype) Error {
        const path = std.fmt.allocPrint(self.arena, "nodes[{d}]", .{node}) catch return error.OutOfMemory;
        return self.fail(path, self.doc.nodes[node].name, fmt, args);
    }

    fn warnNode(self: *Context, node: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const path = try std.fmt.allocPrint(self.arena, "nodes[{d}]", .{node});
        try self.warn(path, self.doc.nodes[node].name, fmt, args);
    }

    fn fail(self: *Context, path: []const u8, name: ?[]const u8, comptime fmt: []const u8, args: anytype) Error {
        const detail = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
        if (name) |object_name| {
            self.diags.addFmt(self.gpa, .err, .whole(self.settings.source), 1, "", "{s} ('{s}') {s}", .{ path, object_name, detail }) catch return error.OutOfMemory;
        } else {
            self.diags.addFmt(self.gpa, .err, .whole(self.settings.source), 1, "", "{s} {s}", .{ path, detail }) catch return error.OutOfMemory;
        }
        return error.ContentInvalid;
    }

    fn warn(self: *Context, path: []const u8, name: ?[]const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const detail = try std.fmt.allocPrint(self.arena, fmt, args);
        if (name) |object_name| {
            try self.diags.addFmt(self.gpa, .warning, .whole(self.settings.source), 1, "", "{s} ('{s}') {s}", .{ path, object_name, detail });
        } else {
            try self.diags.addFmt(self.gpa, .warning, .whole(self.settings.source), 1, "", "{s} {s}", .{ path, detail });
        }
    }
};

fn isUnlit(material: document.Material) bool {
    const extensions = material.extensions orelse return false;
    return extensions.map.contains("KHR_materials_unlit");
}

fn unitInterval(value: f32) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 1;
}

const TextureUse = struct {
    name: []const u8,
    info: ?document.TextureInfo,
    srgb: bool,
};

fn textureUses(material: document.Material) [5]TextureUse {
    const lit = !isUnlit(material);
    return .{
        .{ .name = "pbrMetallicRoughness.baseColorTexture", .info = material.pbrMetallicRoughness.baseColorTexture, .srgb = true },
        .{ .name = "pbrMetallicRoughness.metallicRoughnessTexture", .info = if (lit) material.pbrMetallicRoughness.metallicRoughnessTexture else null, .srgb = false },
        .{ .name = "normalTexture", .info = if (lit and material.normalTexture != null) plainTextureInfo(material.normalTexture.?) else null, .srgb = false },
        .{ .name = "occlusionTexture", .info = if (lit and material.occlusionTexture != null) plainTextureInfo(material.occlusionTexture.?) else null, .srgb = false },
        .{ .name = "emissiveTexture", .info = if (lit) material.emissiveTexture else null, .srgb = true },
    };
}

fn plainTextureInfo(info: anytype) document.TextureInfo {
    return .{ .index = info.index, .texCoord = info.texCoord, .extensions = info.extensions };
}

fn isVersion2(text: []const u8) bool {
    return text.len >= 1 and text[0] == '2' and (text.len == 1 or text[1] == '.');
}

fn isAtMost20(text: []const u8) bool {
    return std.mem.eql(u8, text, "2") or std.mem.eql(u8, text, "2.0");
}

fn appendInt(comptime T: type, out: *std.ArrayList(u8), gpa: Allocator, value: T) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

fn appendF32(out: *std.ArrayList(u8), gpa: Allocator, value: f32) Allocator.Error!void {
    try appendInt(u32, out, gpa, @bitCast(value));
}

fn appendVec3(out: *std.ArrayList(u8), gpa: Allocator, value: Vec3) Allocator.Error!void {
    try appendF32(out, gpa, value.x);
    try appendF32(out, gpa, value.y);
    try appendF32(out, gpa, value.z);
}
