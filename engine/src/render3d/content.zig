//! Models and materials by content ID (`docs/design/meshes.md` §8).
//!
//! The renderer never touches the registry, so it stays testable with code-built meshes
//! alone; this file is the one place `render3d` reads `foundry:model` and
//! `foundry:material` records and composes the assets they name.
//!
//! **What it holds.** Asset handles, never payloads: a draw reads the current payload
//! through each handle, so a reloaded mesh is followed without being told, and a material
//! is rebuilt when the texture payload it was built from is no longer the current one.
//! Material handles it gives out stay valid across every rebuild (`Renderer.updateMaterial`).
//!
//! **Content is untrusted.** A model record that cannot be read is refused at
//! `acquireModel`. After that, nothing a package does can crash a draw: a material that
//! fails to resolve draws as the magenta placeholder, and a mesh that fails to load drops
//! its parts. Each is reported once per resolution, by ID and reason, never per frame.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");

const loader = @import("loader.zig");
const renderer_mod = @import("renderer.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const MaterialDesc = renderer_mod.MaterialDesc;
const MaterialHandle = renderer_mod.MaterialHandle;
const Renderer = renderer_mod.Renderer;
const TextureHandle = renderer_mod.TextureHandle;
const log = core.log.scoped(.render3d);

pub const Model = opaque {};
pub const ModelHandle = core.Handle(Model);

pub const SlotOverride = struct { slot: u32, material: MaterialHandle };

pub const ModelDraw = struct {
    model: ModelHandle,
    world: Mat4,
    /// At most one per slot. Each replaces that slot's material for this draw only.
    overrides: []const SlotOverride = &.{},
    skin: ?[]const Mat4 = null,
};

/// Bounds on one model record, because its lists are a package's to choose.
pub const Limits = struct {
    max_slots: u32 = 256,
    max_parts: u32 = 4096,
    max_clips: u32 = 1024,
    max_clip_name_bytes: u32 = 65_536,

    pub const default: Limits = .{};
};

pub const Error = error{
    ModelNotFound,
    NotAModel,
    InvalidModelRecord,
    MaterialNotFound,
    NotAMaterial,
    /// A stale or never-issued `ModelHandle`.
    InvalidModel,
    InvalidOverride,
    SkeletonMismatch,
} || renderer_mod.Error;

/// Magenta, opaque and untextured: visible, and not a colour a real material is taken for.
pub const placeholder: MaterialDesc = .{ .base_color = .{ 1, 0, 1, 1 } };

/// The RHI borrows labels, and a record's name is borrowed from package bytes a reload frees.
const material_label = "render3d content material";

const MaterialTag = opaque {};
const EntryHandle = core.Handle(MaterialTag);

const MaterialEntry = struct {
    id: ContentId,
    refs: u32,
    /// The renderer's, and stable for the entry's life.
    handle: MaterialHandle,
    /// `.none` when the record names no texture, or the entry is the placeholder.
    textures: [5]asset.AssetHandle,
    /// The payload the bind group was built from; a different current one means rebuild.
    built_from: [5]TextureHandle,
    reported_ignored: bool = false,
};

const Part = struct {
    /// `.none` when its mesh failed to load: the part is dropped, not the model.
    mesh: asset.AssetHandle,
    submesh: u32,
    slot: u32,
    local: Mat4,
    /// Set once a draw of this part has been refused, so the refusal is logged once.
    reported: bool = false,
};

const ModelEntry = struct {
    id: ContentId,
    refs: u32,
    parts: []Part,
    slots: []EntryHandle,
    /// Each distinct mesh acquired once, in first-use order.
    meshes: []asset.AssetHandle,
    skeleton: asset.AssetHandle = .none,
    clips: []NamedClip = &.{},
};

const NamedClip = struct { name: []u8, handle: asset.AssetHandle };

pub const Content = struct {
    gpa: Allocator,
    renderer: *Renderer,
    assets: *asset.Registry,
    limits: Limits,
    materials: core.HandlePool(MaterialTag, MaterialEntry) = .empty,
    models: core.HandlePool(Model, ModelEntry) = .empty,

    const Self = @This();

    /// Records are read from `assets`' own store, so the two can never disagree about which
    /// packages are loaded.
    pub fn init(gpa: Allocator, renderer: *Renderer, assets: *asset.Registry, limits: Limits) Self {
        return .{ .gpa = gpa, .renderer = renderer, .assets = assets, .limits = limits };
    }

    /// Releases everything, whatever its count. Materials go first, because a material does
    /// not keep its texture alive (Step 5's Resolution). Each reference this holds is released,
    /// so a clean teardown leaves nothing held; then every mesh and texture made through
    /// `render3d`'s loaders is handed back with `unloadWith`, which also covers a caller's own
    /// acquisitions through them.
    pub fn deinit(self: *Self) void {
        var materials = self.materials.iterator();
        while (materials.next()) |entry| {
            self.renderer.destroyMaterial(entry.value.handle);
            for (entry.value.textures) |texture| if (!texture.isNone()) self.assets.release(texture);
        }
        self.materials.deinit(self.gpa);
        var models = self.models.iterator();
        while (models.next()) |entry| {
            for (entry.value.meshes) |handle| self.assets.release(handle);
            self.releaseAnimation(entry.value);
            self.freeModel(entry.value);
        }
        self.models.deinit(self.gpa);
        _ = self.assets.unloadWith(self.gpa, loader.meshLoader(self.renderer));
        _ = self.assets.unloadWith(self.gpa, loader.textureLoader(self.renderer));
        self.* = undefined;
    }

    // -- models ------------------------------------------------------------------------

    /// Resolves a `foundry:model` record: every part and slot validated, each distinct mesh
    /// and texture acquired once, each distinct material created once. The same ID acquired
    /// again is the same handle with one more reference.
    pub fn acquireModel(self: *Self, id: ContentId) Error!ModelHandle {
        var existing = self.models.iterator();
        while (existing.next()) |entry| if (entry.value.id.eql(id)) {
            entry.value.refs += 1;
            return entry.id;
        };
        const record = try self.modelRecord(id);
        var built = try self.buildModel(record);
        errdefer self.dropModel(&built);
        return self.models.add(self.gpa, built);
    }

    pub fn releaseModel(self: *Self, handle: ModelHandle) void {
        const entry = self.models.get(handle) orelse {
            log.warn("release of a model handle that is stale or was never issued", .{});
            return;
        };
        entry.refs -= 1;
        if (entry.refs != 0) return;
        self.dropModel(entry);
        _ = self.models.remove(handle);
    }

    /// One `drawMesh` per part, in record order, at `world · part`, with the slot's material
    /// or its override. **A refused draw records nothing**: the handle, the world matrix and
    /// every override are checked before the first part is submitted. A part whose mesh is
    /// missing, or which its current mesh cannot draw, is skipped and reported once.
    pub fn drawModel(self: *Self, draw: ModelDraw) Error!void {
        const model = self.models.getConst(draw.model) orelse return error.InvalidModel;
        for (draw.world.cols) |column| for (column) |value| {
            if (!std.math.isFinite(value)) return error.InvalidTransform;
        };
        for (draw.overrides, 0..) |override, i| {
            if (override.slot >= model.slots.len) return error.InvalidOverride;
            for (draw.overrides[0..i]) |earlier| if (earlier.slot == override.slot) return error.InvalidOverride;
            if (!self.renderer.isMaterial(override.material)) return error.InvalidMaterial;
        }
        // Preflight every current mesh and animation asset before any part is submitted.
        try self.checkAnimation(model.*);
        if (model.skeleton.isNone()) {
            if (draw.skin != null) return error.UnexpectedSkin;
        } else {
            const skeleton = self.skeletonOf(draw.model) orelse return error.SkeletonMismatch;
            const matrices = draw.skin orelse return error.MissingSkin;
            try @import("skinning.zig").validate(matrices, skeleton.parents.len);
        }
        for (model.parts) |part| {
            if (part.mesh.isNone()) continue;
            const mesh = loader.meshOf(self.assets, part.mesh, self.renderer) orelse continue;
            const joint_count = self.renderer.meshJointCount(mesh) orelse return error.InvalidMesh;
            try self.renderer.validateSkin(mesh, if (joint_count != 0) draw.skin else null);
        }

        for (model.slots) |slot| try self.refresh(slot);
        for (draw.overrides) |override| if (self.entryOf(override.material)) |slot| try self.refresh(slot);

        const parts = self.models.get(draw.model).?.parts;
        for (parts) |*part| {
            if (part.mesh.isNone()) continue;
            const mesh = loader.meshOf(self.assets, part.mesh, self.renderer) orelse continue;
            const joint_count = self.renderer.meshJointCount(mesh) orelse return error.InvalidMesh;
            const material = for (draw.overrides) |override| {
                if (override.slot == part.slot) break override.material;
            } else self.materials.getConst(model.slots[part.slot]).?.handle;
            self.renderer.drawMesh(.{
                .mesh = mesh,
                .submesh = part.submesh,
                .material = material,
                .world = Mat4.mul(draw.world, part.local),
                .skin = if (joint_count != 0) draw.skin else null,
            }) catch |err| switch (err) {
                error.InvalidSubmesh, error.MissingStream, error.InvalidTransform => {
                    if (!part.reported) log.warn("model {f}: a part cannot be drawn ({t}); it is skipped", .{ model.id, err });
                    part.reported = true;
                },
                else => return err,
            };
        }
    }

    /// Current payloads, borrowed until the next asset/content reload, never retained by us.
    pub fn skeletonOf(self: *Self, handle: ModelHandle) ?*const asset.skeleton.Skeleton {
        const model = self.models.getConst(handle) orelse return null;
        if (model.skeleton.isNone()) return null;
        const loaded = self.assets.getIfLoader(model.skeleton, asset.skeletonLoader()) orelse return null;
        return asset.skeleton.fromPayload(loaded.payload);
    }

    pub fn clipOf(self: *Self, handle: ModelHandle, name: []const u8) ?*const asset.animation.Animation {
        const model = self.models.getConst(handle) orelse return null;
        for (model.clips) |clip| if (std.mem.eql(u8, clip.name, name)) {
            const loaded = self.assets.getIfLoader(clip.handle, asset.animationLoader()) orelse return null;
            return asset.animation.fromPayload(loaded.payload);
        };
        return null;
    }

    // -- materials ---------------------------------------------------------------------

    /// A `foundry:material` record as a renderer material, for code that draws meshes itself
    /// or overrides a slot. Its handle survives every rebuild; `releaseMaterial` gives it back.
    pub fn acquireMaterial(self: *Self, id: ContentId) Error!MaterialHandle {
        const record = self.assets.store.lookup(id) orelse return error.MaterialNotFound;
        if (!record.schema_id.eql(asset.schemas.material.id)) return error.NotAMaterial;
        const entry = try self.retainMaterial(id);
        return self.materials.getConst(entry).?.handle;
    }

    pub fn releaseMaterial(self: *Self, handle: MaterialHandle) void {
        const entry = self.entryOf(handle) orelse {
            log.warn("release of a material handle Content did not issue", .{});
            return;
        };
        self.releaseEntry(entry);
    }

    // -- reload ------------------------------------------------------------------------

    /// Re-reads every model and material record, after a package reload has moved `app`'s
    /// content generation. A changed part, slot or colour is not a changed file, so
    /// nothing else notices it (`assets.md`'s hot-reload Resolution).
    ///
    /// Materials first, in handle order, then models: a model that now names a new
    /// material resolves it fresh. A model whose record has gone, or no longer reads, keeps
    /// drawing what it had and says so, as a failed asset reload changes nothing.
    pub fn contentChanged(self: *Self) Error!void {
        var materials = self.materials.iterator();
        while (materials.next()) |entry| try self.resolveMaterial(entry.id);

        var models = self.models.iterator();
        while (models.next()) |entry| {
            const id = entry.value.id;
            const record = self.modelRecord(id) catch |err| {
                log.warn("model {f} could not be re-read ({t}); keeping what it had", .{ id, err });
                continue;
            };
            var built = self.buildModel(record) catch |err| switch (err) {
                error.InvalidModelRecord => continue,
                else => return err,
            };
            const slot = self.models.get(entry.id).?;
            built.refs = slot.refs;
            var old = slot.*;
            slot.* = built;
            self.dropModel(&old);
        }
    }

    // -- internals ---------------------------------------------------------------------

    fn modelRecord(self: *Self, id: ContentId) Error!asset.Record {
        const record = self.assets.store.lookup(id) orelse return error.ModelNotFound;
        if (!record.schema_id.eql(asset.schemas.model.id)) return error.NotAModel;
        return record;
    }

    /// Reads and validates the whole record before acquiring anything, so a refusal leaves
    /// nothing held.
    fn buildModel(self: *Self, record: asset.Record) Error!ModelEntry {
        const gpa = self.gpa;
        const slot_list = listField(record.fields, "slots") orelse return refuse(record, "has no readable slots");
        const part_list = listField(record.fields, "parts") orelse return refuse(record, "has no readable parts");
        if (slot_list.len > self.limits.max_slots) return refuse(record, "has more slots than render3d's limit");
        if (part_list.len > self.limits.max_parts) return refuse(record, "has more parts than render3d's limit");

        const slot_ids = try gpa.alloc(ContentId, slot_list.len);
        defer gpa.free(slot_ids);
        for (slot_ids, 0..) |*slot_id, i| {
            const fields = (slot_list.nestedAt(@intCast(i)) catch null) orelse return refuse(record, "has a slot that cannot be read");
            slot_id.* = idField(fields, "material") orelse return refuse(record, "has a slot with no material");
        }

        const parts = try gpa.alloc(Part, part_list.len);
        var parts_owned = true;
        defer if (parts_owned) gpa.free(parts);
        const mesh_ids = try gpa.alloc(ContentId, part_list.len);
        defer gpa.free(mesh_ids);
        for (parts, mesh_ids, 0..) |*part, *mesh_id, i| {
            const fields = (part_list.nestedAt(@intCast(i)) catch null) orelse return refuse(record, "has a part that cannot be read");
            mesh_id.* = idField(fields, "mesh") orelse return refuse(record, "has a part with no mesh");
            const submesh = uintField(fields, "submesh") orelse return refuse(record, "has a part with no submesh");
            const slot = uintField(fields, "slot") orelse return refuse(record, "has a part with no slot");
            if (slot >= slot_ids.len) return refuse(record, "has a part naming a slot it does not have");
            const translation = vec3Field(fields, "translation") orelse return refuse(record, "has a part with no translation");
            const scale = vec3Field(fields, "scale") orelse return refuse(record, "has a part with no scale");
            const r = nestedField(fields, "rotation") orelse return refuse(record, "has a part with no rotation");
            const rotation = core.math.Quat.validated(
                floatField(r, "x") orelse std.math.nan(f32),
                floatField(r, "y") orelse std.math.nan(f32),
                floatField(r, "z") orelse std.math.nan(f32),
                floatField(r, "w") orelse std.math.nan(f32),
            ) catch return refuse(record, "has a part whose rotation is not a unit quaternion");
            const transform: core.math.Transform = .{ .translation = translation, .rotation = rotation, .scale = scale };
            if (!transform.isValid()) return refuse(record, "has a part whose transform is not finite");
            part.* = .{ .mesh = .none, .submesh = submesh, .slot = slot, .local = transform.toMat4() };
        }

        // Everything read; now acquire, releasing what was taken if anything fails.
        const slots = try gpa.alloc(EntryHandle, slot_ids.len);
        var retained: usize = 0;
        errdefer {
            for (slots[0..retained]) |entry| self.releaseEntry(entry);
            gpa.free(slots);
        }
        for (slot_ids) |slot_id| {
            slots[retained] = try self.retainMaterial(slot_id);
            retained += 1;
        }

        var meshes: std.ArrayList(asset.AssetHandle) = .empty;
        errdefer {
            for (meshes.items) |handle| self.assets.release(handle);
            meshes.deinit(gpa);
        }
        for (parts, mesh_ids, 0..) |*part, mesh_id, i| {
            // A mesh named twice is acquired once, and a failure is reported once.
            for (mesh_ids[0..i], parts[0..i]) |earlier_id, earlier| {
                if (earlier_id.eql(mesh_id)) {
                    part.mesh = earlier.mesh;
                    break;
                }
            } else {
                part.mesh = self.assets.acquireWith(gpa, mesh_id, loader.meshLoader(self.renderer)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => blk: {
                        log.warn("model {f}: mesh {f} did not load ({t}); its parts are dropped", .{ record.id, mesh_id, err });
                        break :blk .none;
                    },
                };
                if (!part.mesh.isNone()) meshes.append(gpa, part.mesh) catch |err| {
                    self.assets.release(part.mesh);
                    return err;
                };
            }
        }

        var skeleton = asset.AssetHandle.none;
        if (idField(record.fields, "skeleton")) |skeleton_id| {
            skeleton = self.assets.acquireWith(gpa, skeleton_id, asset.skeletonLoader()) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => refuse(record, "has a skeleton that cannot be loaded"),
            };
        }
        errdefer if (!skeleton.isNone()) self.assets.release(skeleton);
        var clips: std.ArrayList(NamedClip) = .empty;
        errdefer {
            for (clips.items) |clip| {
                self.assets.release(clip.handle);
                gpa.free(clip.name);
            }
            clips.deinit(gpa);
        }
        if (listField(record.fields, "clips")) |list| {
            if (list.len > @min(self.limits.max_clips, 1024)) return refuse(record, "has too many clips");
            var name_bytes: usize = 0;
            for (0..list.len) |i| {
                const fields = (list.nestedAt(@intCast(i)) catch null) orelse return refuse(record, "has an unreadable clip");
                const name = (fields.stringAt(indexOf(fields, "name") orelse return refuse(record, "has an unnamed clip")) catch null) orelse return refuse(record, "has an unnamed clip");
                if (name.len == 0 or name.len > @min(self.limits.max_clip_name_bytes, 65_536) -| name_bytes) return refuse(record, "has an empty or over-limit clip name");
                name_bytes += name.len;
                for (clips.items) |earlier| if (std.mem.eql(u8, name, earlier.name)) return refuse(record, "has duplicate clip names");
                const clip_id = idField(fields, "clip") orelse return refuse(record, "has a clip with no asset");
                const owned_name = try gpa.dupe(u8, name);
                errdefer gpa.free(owned_name);
                const clip = self.assets.acquireWith(gpa, clip_id, asset.animationLoader()) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => refuse(record, "has a clip that cannot be loaded"),
                };
                errdefer self.assets.release(clip);
                try clips.append(gpa, .{ .name = owned_name, .handle = clip });
            }
        }
        var built: ModelEntry = .{ .id = record.id, .refs = 1, .parts = parts, .slots = slots, .meshes = meshes.items, .skeleton = skeleton, .clips = clips.items };
        self.checkAnimation(built) catch return refuse(record, "has incompatible mesh, skeleton or clip joint counts");
        const owned_clips = try clips.toOwnedSlice(gpa);
        errdefer {
            for (owned_clips) |clip| {
                self.assets.release(clip.handle);
                gpa.free(clip.name);
            }
            gpa.free(owned_clips);
        }
        const owned_meshes = try meshes.toOwnedSlice(gpa);
        parts_owned = false;
        built.meshes = owned_meshes;
        built.clips = owned_clips;
        return built;
    }

    fn checkAnimation(self: *Self, model: ModelEntry) error{SkeletonMismatch}!void {
        const count: usize = if (model.skeleton.isNone()) 0 else blk: {
            const loaded = self.assets.getIfLoader(model.skeleton, asset.skeletonLoader()) orelse return error.SkeletonMismatch;
            break :blk asset.skeleton.fromPayload(loaded.payload).parents.len;
        };
        if (count == 0 and model.clips.len != 0) return error.SkeletonMismatch;
        for (model.clips) |clip| {
            const loaded = self.assets.getIfLoader(clip.handle, asset.animationLoader()) orelse return error.SkeletonMismatch;
            try asset.animation.fromPayload(loaded.payload).checkJointCount(count);
        }
        for (model.meshes) |handle| {
            const mesh = loader.meshOf(self.assets, handle, self.renderer) orelse continue;
            const joints = self.renderer.meshJointCount(mesh) orelse continue;
            if (joints != 0 and joints != count) return error.SkeletonMismatch;
        }
    }

    fn releaseAnimation(self: *Self, model: *const ModelEntry) void {
        if (!model.skeleton.isNone()) self.assets.release(model.skeleton);
        for (model.clips) |clip| self.assets.release(clip.handle);
    }

    fn dropModel(self: *Self, model: *ModelEntry) void {
        for (model.slots) |entry| self.releaseEntry(entry);
        for (model.meshes) |handle| self.assets.release(handle);
        self.releaseAnimation(model);
        self.freeModel(model);
    }

    fn freeModel(self: *Self, model: *ModelEntry) void {
        self.gpa.free(model.parts);
        self.gpa.free(model.slots);
        self.gpa.free(model.meshes);
        for (model.clips) |clip| self.gpa.free(clip.name);
        self.gpa.free(model.clips);
    }

    fn retainMaterial(self: *Self, id: ContentId) Error!EntryHandle {
        var existing = self.materials.iterator();
        while (existing.next()) |entry| if (entry.value.id.eql(id)) {
            entry.value.refs += 1;
            return entry.id;
        };
        const handle = try self.renderer.createMaterial(placeholder, material_label);
        errdefer self.renderer.destroyMaterial(handle);
        const entry = try self.materials.add(self.gpa, .{
            .id = id,
            .refs = 1,
            .handle = handle,
            .textures = @splat(.none),
            .built_from = @splat(.none),
        });
        errdefer _ = self.materials.remove(entry);
        try self.resolveMaterial(entry);
        return entry;
    }

    fn releaseEntry(self: *Self, handle: EntryHandle) void {
        const entry = self.materials.get(handle) orelse return;
        entry.refs -= 1;
        if (entry.refs != 0) return;
        // The material first: it binds the texture, and does not keep it alive.
        self.renderer.destroyMaterial(entry.handle);
        for (entry.textures) |texture| if (!texture.isNone()) self.assets.release(texture);
        _ = self.materials.remove(handle);
    }

    fn entryOf(self: *Self, material: MaterialHandle) ?EntryHandle {
        var it = self.materials.iterator();
        while (it.next()) |entry| if (entry.value.handle.eql(material)) return entry.id;
        return null;
    }

    /// Rebuilds a material whose texture payload has moved under it — a reload swapped it,
    /// or the asset was unloaded — before any draw binds the old one.
    fn refresh(self: *Self, handle: EntryHandle) Error!void {
        const entry = self.materials.getConst(handle).?;
        for (entry.textures, entry.built_from) |texture, built_from| {
            if (texture.isNone()) continue;
            const current = loader.textureOf(self.assets, texture, self.renderer) orelse TextureHandle.none;
            if (!current.eql(built_from)) {
                try self.resolveMaterial(handle);
                return;
            }
        }
    }

    /// Reads the record and rebuilds the material behind the entry's stable handle. Only
    /// allocation and device failures are errors; anything content got wrong becomes the
    /// placeholder, reported once.
    fn resolveMaterial(self: *Self, handle: EntryHandle) Error!void {
        const id = self.materials.getConst(handle).?.id;
        var desc: MaterialDesc = .{};
        var textures: [5]asset.AssetHandle = @splat(.none);
        errdefer for (textures) |texture| if (!texture.isNone()) self.assets.release(texture);
        const reason: ?[]const u8 = blk: {
            const record = self.assets.store.lookup(id) orelse break :blk "its record is not in any loaded package";
            if (!record.schema_id.eql(asset.schemas.material.id)) break :blk "its record is not a foundry:material";
            const texture_ids = readMaterial(record.fields, &desc) catch |err| break :blk switch (err) {
                error.UnknownAlphaMode => "its alpha_mode is not opaque, mask or blend",
                error.Unreadable => "its fields cannot be read",
            };
            const reads = self.renderer.materialFields(desc.shading) orelse break :blk "its shading model is not registered";
            const enabled = [5]bool{ reads.base_color_texture, reads.metallic_roughness, reads.normal, reads.occlusion, reads.emissive };
            var handles: [5]TextureHandle = @splat(.none);
            for (texture_ids, enabled, 0..) |texture_id, enabled_slot, i| {
                if (!enabled_slot) continue;
                if (texture_id) |tid| {
                    textures[i] = self.assets.acquireWith(self.gpa, tid, loader.textureLoader(self.renderer)) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => break :blk "one of its textures did not load",
                    };
                    handles[i] = loader.textureOf(self.assets, textures[i], self.renderer) orelse break :blk "one of its textures did not load";
                }
            }
            desc.base_color_texture = handles[0];
            desc.metallic_roughness_texture = handles[1];
            desc.normal_texture = handles[2];
            desc.occlusion_texture = handles[3];
            desc.emissive_texture = handles[4];
            const entry = self.materials.get(handle).?;
            self.renderer.updateMaterial(entry.handle, desc, material_label) catch |err| break :blk switch (err) {
                error.UnknownShadingModel => "its shading model is not registered",
                error.InvalidMaterialValue => "a value is not finite or outside its material range",
                error.WrongColorSpace => "a texture has the wrong colour space for its slot",
                error.InvalidTexture => "one of its textures did not load",
                else => |e| return e,
            };
            // Non-default unread values and references are the author's intent, not
            // schema-expanded defaults. Report once for this entry, never per frame/reload.
            const ignored = (!reads.metallic_roughness and (desc.metallic != 0 or desc.roughness != 1 or texture_ids[1] != null)) or
                (!reads.normal and (desc.normal_scale != 1 or texture_ids[2] != null)) or
                (!reads.occlusion and (desc.occlusion_strength != 1 or texture_ids[3] != null)) or
                (!reads.emissive and (!std.mem.eql(f32, &desc.emissive, &.{ 0, 0, 0 }) or desc.emissive_strength != 1 or texture_ids[4] != null)) or
                (!reads.base_color_texture and texture_ids[0] != null) or
                (!reads.casts_shadow and !desc.casts_shadow) or
                (desc.alpha_mode == .blend and desc.casts_shadow and reads.casts_shadow);
            if (ignored and !entry.reported_ignored) {
                log.warn("material {f}: fields unread by its shading model are ignored", .{id});
                entry.reported_ignored = true;
            }
            break :blk null;
        };

        const entry = self.materials.get(handle).?;
        if (reason) |why| {
            log.warn("material {f} is drawn as the placeholder: {s}", .{ id, why });
            for (textures) |texture| if (!texture.isNone()) self.assets.release(texture);
            textures = @splat(.none);
            desc = placeholder;
            try self.renderer.updateMaterial(entry.handle, placeholder, material_label);
        }
        // Hold all five new slots before releasing any old slot, including aliases.
        for (entry.textures) |texture| if (!texture.isNone()) self.assets.release(texture);
        entry.textures = textures;
        entry.built_from = .{ desc.base_color_texture, desc.metallic_roughness_texture, desc.normal_texture, desc.occlusion_texture, desc.emissive_texture };
    }
};

fn refuse(record: asset.Record, why: []const u8) error{InvalidModelRecord} {
    log.warn("model '{s}' {s}", .{ record.name, why });
    return error.InvalidModelRecord;
}

/// Fills `desc` from a material record and returns the texture it names, if any. A field
/// the record lacks keeps `MaterialDesc`'s default, which is the schema's.
fn readMaterial(fields: asset.RecordFields, desc: *MaterialDesc) error{ Unreadable, UnknownAlphaMode }![5]?ContentId {
    if (indexOf(fields, "shading")) |i| desc.shading = (fields.idAt(i) catch return error.Unreadable) orelse desc.shading;
    if (indexOf(fields, "base_color")) |i| if (fields.nestedAt(i) catch return error.Unreadable) |color| {
        for ([_][]const u8{ "r", "g", "b", "a" }, &desc.base_color) |name, *channel| {
            channel.* = floatField(color, name) orelse return error.Unreadable;
        }
    };
    if (indexOf(fields, "alpha_mode")) |i| if (fields.stringAt(i) catch return error.Unreadable) |text| {
        desc.alpha_mode = std.meta.stringToEnum(renderer_mod.AlphaMode, text) orelse return error.UnknownAlphaMode;
    };
    if (indexOf(fields, "alpha_cutoff")) |i| if (fields.floatAt(i) catch return error.Unreadable) |value| {
        desc.alpha_cutoff = @floatCast(value);
    };
    if (indexOf(fields, "double_sided")) |i| desc.double_sided = (fields.boolAt(i) catch return error.Unreadable) orelse desc.double_sided;
    inline for (.{ "metallic", "roughness", "normal_scale", "occlusion_strength", "emissive_strength" }) |name| {
        if (indexOf(fields, name)) |i| if (fields.floatAt(i) catch return error.Unreadable) |value| {
            @field(desc, name) = @floatCast(value);
        };
    }
    if (indexOf(fields, "emissive")) |i| if (fields.nestedAt(i) catch return error.Unreadable) |color| {
        for ([_][]const u8{ "r", "g", "b" }, &desc.emissive) |name, *channel| channel.* = floatField(color, name) orelse return error.Unreadable;
    };
    if (indexOf(fields, "casts_shadow")) |i| desc.casts_shadow = (fields.boolAt(i) catch return error.Unreadable) orelse desc.casts_shadow;
    var ids: [5]?ContentId = @splat(null);
    for ([_][]const u8{ "base_color_texture", "metallic_roughness_texture", "normal_texture", "occlusion_texture", "emissive_texture" }, &ids) |name, *id| {
        if (indexOf(fields, name)) |i| id.* = fields.idAt(i) catch return error.Unreadable;
    }
    return ids;
}

fn indexOf(fields: asset.RecordFields, name: []const u8) ?u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return null;
}

fn listField(fields: asset.RecordFields, name: []const u8) ?asset.RecordList {
    return (fields.listAt(indexOf(fields, name) orelse return null) catch null) orelse null;
}

fn nestedField(fields: asset.RecordFields, name: []const u8) ?asset.RecordFields {
    return (fields.nestedAt(indexOf(fields, name) orelse return null) catch null) orelse null;
}

fn idField(fields: asset.RecordFields, name: []const u8) ?ContentId {
    return (fields.idAt(indexOf(fields, name) orelse return null) catch null) orelse null;
}

fn uintField(fields: asset.RecordFields, name: []const u8) ?u32 {
    const value = (fields.intAt(indexOf(fields, name) orelse return null) catch null) orelse return null;
    return std.math.cast(u32, value);
}

/// Narrowed to `f32`. A value too large becomes infinite here and is refused by whoever
/// checks finiteness — the transform, or the renderer's material validation.
fn floatField(fields: asset.RecordFields, name: []const u8) ?f32 {
    const value = (fields.floatAt(indexOf(fields, name) orelse return null) catch null) orelse return null;
    return @floatCast(value);
}

fn vec3Field(fields: asset.RecordFields, name: []const u8) ?Vec3 {
    const v = nestedField(fields, name) orelse return null;
    return .init(floatField(v, "x") orelse return null, floatField(v, "y") orelse return null, floatField(v, "z") orelse return null);
}
