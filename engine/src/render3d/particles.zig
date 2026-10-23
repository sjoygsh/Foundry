//! Running particle emitters (`docs/design/particles.md` §6, ADR-0064).
//!
//! **An instance is owned by handle, never content.** `create` names a
//! `foundry:particle_emitter` record and a transform. The instance has no content ID, nothing
//! saves it, and only its creator destroys it (ADR-0063's rule for runtime resources). Its
//! description is the record's, followed across a reload with the handle, the live particles
//! and the seed's stream kept.
//!
//! **Its look is an ordinary material.** The record names a `foundry:material`, resolved through
//! `Content` like any other, so a texture reload, a package override of the look and the
//! placeholder for a broken one all arrive by the path materials already have.
//!
//! **One runtime mesh per instance, written straight into kept staging** (§7). `prepare`
//! reserves a staging buffer sized for an instance's quads, lets `particles.Expander` write the
//! streams and indices into it in the layout `uploadMesh` reads, and hands it to
//! `updateMeshFromStaged`. No intermediate `asset.Mesh` is built, which is what made M28's
//! inline water slow. The mesh is drawn with an identity world, because expansion writes world
//! space (Step 2's Resolution).
//!
//! **The frame's order of calls:** `step` on the simulation tick; `prepare(view)` after the
//! camera is known and before `Renderer.begin`, because it writes meshes; `draw` inside the
//! window. After a package reload, `Content.contentChanged` first, then `contentChanged` here.
//!
//! **Order is ascending slot index** (`core.HandlePool`'s documented iteration), the same on
//! every machine: instances are stepped, prepared and drawn in it.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");
const particles = @import("particles");

const content_mod = @import("content.zig");
const frustum_mod = @import("frustum.zig");
const renderer_mod = @import("renderer.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Mat4 = core.math.Mat4;
const Vec3 = core.math.Vec3;
const Content = content_mod.Content;
const FrameView = renderer_mod.FrameView;
const MaterialHandle = renderer_mod.MaterialHandle;
const MeshHandle = renderer_mod.MeshHandle;
const Renderer = renderer_mod.Renderer;
const StreamSet = renderer_mod.StreamSet;
const log = core.log.scoped(.render3d);

pub const Emitter = opaque {};
pub const EmitterHandle = core.Handle(Emitter);

pub const Limits = struct {
    max_emitters: u32 = 1024,

    pub const default: Limits = .{};
};

pub const Error = content_mod.Error || error{
    InvalidConfig,
    /// No record has the ID.
    EmitterNotFound,
    /// The record is not a `foundry:particle_emitter`.
    NotAnEmitter,
    /// The record does not decode; the log line says which field.
    InvalidEmitter,
    /// The material's shading model needs a stream a particle mesh does not have.
    InvalidMaterial,
    /// A stale or never-issued handle.
    InvalidHandle,
    InvalidTransform,
    TooManyEmitters,
};

/// The streams every particle mesh has (Step 2's `Output`).
const particle_streams = StreamSet.of(&.{ .position, .uv0, .color });

/// Instances per `step` chunk: one, because each is a whole system's step.
const step_grain: u32 = 1;

pub const Particles = struct {
    gpa: Allocator,
    renderer: *Renderer,
    content: *Content,
    limits: Limits,
    emitters: core.HandlePool(Emitter, Entry) = .empty,
    /// Entries in iteration order, rebuilt per `step`: what the jobs index.
    order: std.ArrayList(*Entry) = .empty,
    /// Counters `step` gathered since the last `prepare`.
    dropped: u64 = 0,

    const Self = @This();

    pub fn init(gpa: Allocator, renderer: *Renderer, content: *Content, limits: Limits) Error!Self {
        if (limits.max_emitters == 0) return error.InvalidConfig;
        return .{ .gpa = gpa, .renderer = renderer, .content = content, .limits = limits };
    }

    /// Releases every instance, whoever made it.
    pub fn deinit(self: *Self) void {
        var it = self.emitters.iterator();
        while (it.next()) |entry| self.release(entry.value);
        self.emitters.deinit(self.gpa);
        self.order.deinit(self.gpa);
        self.* = undefined;
    }

    pub const Create = struct {
        emitter: ContentId,
        transform: Mat4 = .identity,
        /// Separates instances of one record: a stable constant the caller chooses, never a
        /// creation order (`particles.System.init`).
        stream: u64 = 0,
    };

    /// A running instance of a record, playing from the next step. A refusal holds nothing.
    pub fn create(self: *Self, options: Create) Error!EmitterHandle {
        if (self.emitters.count() >= self.limits.max_emitters) return error.TooManyEmitters;
        if (!finite(options.transform)) return error.InvalidTransform;
        const record = try self.read(options.emitter);
        const material = try self.content.acquireMaterial(record.material);
        errdefer self.content.releaseMaterial(material);
        const sorted = try self.shapeOf(material);
        var system = try particles.System.init(self.gpa, record.capacity, record.seed, options.stream);
        errdefer system.deinit();
        var expander = try particles.Expander.init(self.gpa, record.capacity);
        errdefer expander.deinit();
        return self.emitters.add(self.gpa, .{
            .id = options.emitter,
            .description = .of(record),
            .material_id = record.material,
            .material = material,
            .sorted = sorted,
            .system = system,
            .expander = expander,
            .transform = options.transform,
        });
    }

    /// Inside a frame's window the mesh and material are only doomed, and go when it closes
    /// (ADR-0063); the handle is invalid at once.
    pub fn destroy(self: *Self, handle: EmitterHandle) error{InvalidHandle}!void {
        const entry = self.emitters.get(handle) orelse return error.InvalidHandle;
        self.release(entry);
        _ = self.emitters.remove(handle);
    }

    pub fn setTransform(self: *Self, handle: EmitterHandle, transform: Mat4) error{ InvalidHandle, InvalidTransform }!void {
        const entry = self.emitters.get(handle) orelse return error.InvalidHandle;
        if (!finite(transform)) return error.InvalidTransform;
        entry.transform = transform;
    }

    pub fn play(self: *Self, handle: EmitterHandle) error{InvalidHandle}!void {
        (self.emitters.get(handle) orelse return error.InvalidHandle).system.play();
    }

    pub fn stop(self: *Self, handle: EmitterHandle) error{InvalidHandle}!void {
        (self.emitters.get(handle) orelse return error.InvalidHandle).system.stop();
    }

    pub fn clear(self: *Self, handle: EmitterHandle) error{InvalidHandle}!void {
        (self.emitters.get(handle) orelse return error.InvalidHandle).system.clear();
    }

    pub fn liveCount(self: *Self, handle: EmitterHandle) ?u32 {
        return (self.emitters.getConst(handle) orelse return null).system.liveCount();
    }

    /// The instance's state hash, for pins (`particles.System.hash`).
    pub fn stateHash(self: *Self, handle: EmitterHandle) ?u64 {
        return (self.emitters.getConst(handle) orelse return null).system.hash();
    }

    /// Steps every instance a reload has not refused, on the simulation tick. Instances are
    /// independent, so `jobs` runs them as one chunk each; each one's result is the same bytes
    /// whichever worker ran it.
    pub fn step(self: *Self, tick: u64, dt: f32, jobs: core.Jobs) Allocator.Error!void {
        self.order.clearRetainingCapacity();
        try self.order.ensureTotalCapacity(self.gpa, self.emitters.count());
        var it = self.emitters.iterator();
        while (it.next()) |entry| if (!entry.value.refused) self.order.appendAssumeCapacity(entry.value);
        const work: StepWork = .{ .entries = self.order.items, .tick = tick, .dt = dt };
        jobs.forChunks(@intCast(self.order.items.len), step_grain, &work, StepWork.chunk);
        for (self.order.items) |entry| {
            self.dropped += entry.system.counts.dropped - entry.dropped_seen;
            entry.dropped_seen = entry.system.counts.dropped;
        }
    }

    /// Expands and uploads every visible instance for `view`, outside the frame's window. An
    /// instance outside the view frustum keeps last frame's mesh and is not drawn; one with no
    /// live particles is not drawn. Counts go to the next frame's `Stats`.
    pub fn prepare(self: *Self, view: FrameView, jobs: core.Jobs) Error!void {
        if (self.renderer.recording) return error.InFrame;
        if (!view.camera.isValid() or view.target_size.isEmpty()) return error.InvalidCamera;
        const frustum = frustum_mod.Frustum.fromViewProjection(view.camera.viewProjection(view.target_size.width, view.target_size.height));
        const camera = view.camera;
        const eye: particles.View = .{
            .eye = camera.position,
            .right = camera.rotation.rotate(.right),
            .up = camera.rotation.rotate(.up),
            .forward = camera.rotation.rotate(.forward),
        };
        var counts: renderer_mod.ParticleCounts = .{ .dropped = @intCast(@min(self.dropped, std.math.maxInt(u32))) };
        self.dropped = 0;
        var it = self.emitters.iterator();
        while (it.next()) |slot| {
            const entry = slot.value;
            entry.ready = false;
            if (entry.refused) {
                counts.refused += 1;
                continue;
            }
            const box = entry.system.bounds orelse continue;
            const world = if (entry.description.record.space == .local) entry.transform else Mat4.identity;
            const bounds = frustum_mod.Bounds.transformed(.{ .min = vec(box.min), .max = vec(box.max) }, world);
            if (self.renderer.config.cull and frustum.excludes(bounds)) {
                counts.culled += 1;
                continue;
            }
            try self.upload(entry, eye, jobs);
            entry.ready = true;
            counts.emitters += 1;
            counts.particles += entry.system.liveCount();
        }
        self.renderer.noteParticles(counts);
    }

    /// Submits each prepared instance, inside the frame's window.
    pub fn draw(self: *Self) Error!void {
        var it = self.emitters.iterator();
        while (it.next()) |slot| {
            const entry = slot.value;
            if (!entry.ready or entry.mesh.isNone()) continue;
            try self.renderer.drawMesh(.{ .mesh = entry.mesh, .material = entry.material, .world = .identity });
        }
    }

    /// Re-reads every instance's record after a package reload, once `Content` has re-resolved
    /// its materials. A record that is gone or no longer decodes, or whose material no longer
    /// suits a particle mesh, leaves its instance stopped and drawing nothing, counted, until a
    /// reload restores it (`Instances.submit`'s rule). Otherwise the new description takes over
    /// at the next step, with the handle, the particles and the stream kept; a lower capacity
    /// removes the oldest first.
    pub fn contentChanged(self: *Self) Error!void {
        var it = self.emitters.iterator();
        while (it.next()) |slot| {
            const entry = slot.value;
            const record = self.read(entry.id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (!entry.refused) log.warn("particle emitter {f} is stopped: {t}", .{ entry.id, err });
                    entry.refused = true;
                    continue;
                },
            };
            if (!record.material.eql(entry.material_id)) {
                const material = self.content.acquireMaterial(record.material) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        log.warn("particle emitter {f} is stopped: its material {t}", .{ entry.id, err });
                        entry.refused = true;
                        continue;
                    },
                };
                self.content.releaseMaterial(entry.material);
                entry.material = material;
                entry.material_id = record.material;
            }
            entry.sorted = self.shapeOf(entry.material) catch {
                log.warn("particle emitter {f} is stopped: its material's shading needs a stream particles do not have", .{entry.id});
                entry.refused = true;
                continue;
            };
            if (record.capacity != entry.system.capacity) {
                try entry.system.setCapacity(record.capacity);
                const expander = try particles.Expander.init(self.gpa, record.capacity);
                entry.expander.deinit();
                entry.expander = expander;
            }
            entry.description = .of(record);
            entry.refused = false;
        }
    }

    // -- internals ---------------------------------------------------------------------

    fn read(self: *Self, id: ContentId) Error!asset.ParticleEmitter {
        const record = self.content.assets.store.lookup(id) orelse return error.EmitterNotFound;
        if (!record.schema_id.eql(asset.particle_emitter.particle_emitter.id)) return error.NotAnEmitter;
        return asset.particle_emitter.decode(record.fields) catch |err| {
            log.warn("particle emitter '{s}' {s}", .{ record.name, asset.particle_emitter.describe(err) });
            return error.InvalidEmitter;
        };
    }

    /// Whether `material` blends, after checking its model needs no stream but a particle
    /// mesh's.
    fn shapeOf(self: *Self, material: MaterialHandle) Error!bool {
        const shape = self.renderer.materialShape(material) orelse return error.InvalidMaterial;
        if (!particle_streams.contains(shape.requires)) return error.InvalidMaterial;
        return shape.alpha_mode == .blend;
    }

    fn release(self: *Self, entry: *Entry) void {
        if (!entry.mesh.isNone()) self.renderer.destroyMesh(entry.mesh);
        self.content.releaseMaterial(entry.material);
        entry.system.deinit();
        entry.expander.deinit();
    }

    /// One instance's quads into a staging reservation, then into its mesh.
    fn upload(self: *Self, entry: *Entry, eye: particles.View, jobs: core.Jobs) Error!void {
        const quads = entry.system.liveCount();
        const layout = Layout.of(quads);
        const staged = try self.renderer.reserveStaging("render3d particles", layout.size);
        const bytes = staged.bytes;
        const out: particles.Output = .{
            .positions = layout.slice([3]f32, bytes, layout.positions, quads * 4),
            .uvs = layout.slice([2]f32, bytes, layout.uvs, quads * 4),
            .colors = layout.slice([4]f32, bytes, layout.colors, quads * 4),
            .indices = layout.slice(u16, bytes, layout.indices, quads * 6),
        };
        const emitter = entry.description.emitter();
        const expanded = entry.expander.expand(&entry.system, &emitter, eye, .{ .sorted = entry.sorted, .transform = entry.transform }, out, jobs);
        const box = expanded.bounds.?;
        const aabb: asset.MeshAabb = .{ .min = vec(box.min), .max = vec(box.max) };
        const submeshes = [_]asset.Submesh{.{ .first_index = 0, .index_count = quads * 6 }};
        // Only each stream's length is read from these: the bytes are already staged.
        const mesh: asset.Mesh = .{
            .vertex_count = quads * 4,
            .streams = &.{
                .{ .semantic = .position, .format = .float32x3, .bytes = std.mem.sliceAsBytes(out.positions) },
                .{ .semantic = .uv0, .format = .float32x2, .bytes = std.mem.sliceAsBytes(out.uvs) },
                .{ .semantic = .color, .format = .float32x4, .bytes = std.mem.sliceAsBytes(out.colors) },
            },
            .index_format = .uint16,
            .indices = std.mem.sliceAsBytes(out.indices),
            .submeshes = &submeshes,
            .bounds = aabb,
        };
        const prepared: renderer_mod.PreparedMesh = .{ .submesh_bounds = &.{aabb} };
        if (entry.mesh.isNone()) {
            entry.mesh = try self.renderer.createMeshFromStaged(mesh, "render3d particles", staged, prepared);
        } else {
            try self.renderer.updateMeshFromStaged(entry.mesh, mesh, "render3d particles", staged, prepared);
        }
    }
};

/// The four pieces of one instance's staging, where `uploadMesh` reads them: each stream, then
/// the indices, each at a multiple of 16 bytes (`renderer.zig`'s `meshPieces`).
const Layout = struct {
    positions: usize,
    uvs: usize,
    colors: usize,
    indices: usize,
    size: usize,

    const alignment = 16;

    fn of(quads: u32) Layout {
        const vertices: usize = @as(usize, quads) * 4;
        var at: usize = 0;
        const positions = at;
        at += std.mem.alignForward(usize, vertices * 12, alignment);
        const uvs = at;
        at += std.mem.alignForward(usize, vertices * 8, alignment);
        const colors = at;
        at += std.mem.alignForward(usize, vertices * 16, alignment);
        return .{ .positions = positions, .uvs = uvs, .colors = colors, .indices = at, .size = at + @as(usize, quads) * 6 * 2 };
    }

    /// A typed view of staging. Every backend maps a buffer at a 16-byte boundary at least, and
    /// each piece starts at a multiple of 16, so the cast is aligned (`rhi`'s null backend
    /// models that promise, Step 5's Resolution).
    fn slice(_: Layout, comptime T: type, bytes: []u8, offset: usize, len: usize) []T {
        const start: [*]T = @ptrCast(@alignCast(bytes.ptr + offset));
        return start[0..len];
    }
};

const StepWork = struct {
    entries: []const *Entry,
    tick: u64,
    dt: f32,

    fn chunk(self: *const StepWork, piece: core.jobs.Chunk) void {
        for (self.entries[piece.begin..piece.end]) |entry| {
            const emitter = entry.description.emitter();
            entry.system.step(&emitter, self.tick, self.dt, entry.transform);
        }
    }
};

const Entry = struct {
    id: ContentId,
    description: Description,
    material_id: ContentId,
    material: MaterialHandle,
    /// The material blends, so expansion sorts.
    sorted: bool,
    system: particles.System,
    expander: particles.Expander,
    mesh: MeshHandle = .none,
    transform: Mat4,
    /// A reload removed or broke its record or material: not stepped, not drawn.
    refused: bool = false,
    /// Prepared this frame, so `draw` submits it.
    ready: bool = false,
    /// `system.counts.dropped` already reported.
    dropped_seen: u64 = 0,
};

/// A decoded record and the slices `particles.Emitter` borrows, held together so the view is
/// rebuilt from the entry's own storage at each use, wherever the pool has moved it.
const Description = struct {
    record: asset.ParticleEmitter,
    bursts: [particles.max_bursts]particles.Burst,
    sizes: [particles.max_curve_keys]particles.Key,
    colors: [particles.max_curve_keys]particles.ColorKey,

    fn of(record: asset.ParticleEmitter) Description {
        var out: Description = .{ .record = record, .bursts = undefined, .sizes = undefined, .colors = undefined };
        for (record.bursts(), 0..) |b, i| out.bursts[i] = .{ .time = b.time, .count = b.count };
        for (record.sizeOverLife(), 0..) |k, i| out.sizes[i] = .{ .t = k.t, .value = k.value };
        for (record.colorOverLife(), 0..) |k, i| out.colors[i] = .{ .t = k.t, .color = k.color };
        return out;
    }

    /// Field for field (`particles.md` §4); `engine/tests/particle_emitter.zig` holds the rules
    /// of the two shapes equal.
    fn emitter(self: *const Description) particles.Emitter {
        const r = &self.record;
        return .{
            .capacity = r.capacity,
            .rate = r.rate,
            .bursts = self.bursts[0..r.burst_count],
            .duration = r.duration,
            .loop = r.loop,
            .lifetime = .{ .min = r.lifetime.min, .max = r.lifetime.max },
            .shape = .{
                .kind = switch (r.shape.kind) {
                    .point => .point,
                    .sphere => .sphere,
                    .box => .box,
                    .cone => .cone,
                },
                .radius = r.shape.radius,
                .angle = r.shape.angle,
                .extent = r.shape.extent,
                .surface = r.shape.surface,
            },
            .speed = .{ .min = r.speed.min, .max = r.speed.max },
            .acceleration = r.acceleration,
            .drag = r.drag,
            .size = .{ .min = r.size.min, .max = r.size.max },
            .size_over_life = self.sizes[0..r.size_key_count],
            .rotation = .{ .min = r.rotation.min, .max = r.rotation.max },
            .spin = .{ .min = r.spin.min, .max = r.spin.max },
            .color_over_life = self.colors[0..r.color_key_count],
            .additive = r.additive,
            .facing = switch (r.facing) {
                .camera => .camera,
                .velocity => .velocity,
                .up => .up,
            },
            .stretch = r.stretch,
            .space = switch (r.space) {
                .world => .world,
                .local => .local,
            },
            .sheet = .{ .columns = r.sheet.columns, .rows = r.sheet.rows, .frames = r.sheet.frames, .fps = r.sheet.fps },
            .seed = r.seed,
        };
    }
};

fn vec(v: [3]f32) Vec3 {
    return .init(v[0], v[1], v[2]);
}

fn finite(m: Mat4) bool {
    for (m.cols) |column| for (column) |value| if (!std.math.isFinite(value)) return false;
    return true;
}
