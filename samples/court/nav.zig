//! The warden's navigation meshes (`docs/design/navigation.md` §9.2, `agents.md` §9): built from the
//! level's collision on the background pool, and drawn when `FOUNDRY_COURT_NAV=show`.
//!
//! **The glue the design leaves to a game** (§7): read `court:nav.warden`, check each source is a
//! loaded `foundry:collision_mesh`, and start a build with the gate as a box. The court holds two
//! meshes for a run. Generation 1 has the gate shut. A later one, built when the gate comes to rest
//! open, is kept and adopted again the next time it opens.
//!
//! **A mesh reaches a tick only as an input** (ADR-0061's decision 4, ADR-0070): `pump` numbers an
//! arrival, and `main.zig` puts the number in the next `Intent`. `Game.step` adopts it. So the game
//! and its replay read the same mesh on the same tick, however late the build arrived. The first
//! mesh is what Play waits for, so no tick runs without an answer.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const nav = @import("nav");
const render3d = @import("render3d");

const Allocator = std.mem.Allocator;
const Vec3 = core.math.Vec3;
const log = core.log.scoped(.court);

pub const recipe_id = core.ContentId.fromString("court:nav.warden");
pub const material_id = core.ContentId.fromString("court:materials.navigation");

/// A recipe's volumes and links as `nav` takes them.
pub const Features = struct {
    costs: [nav.max_areas]f32 = undefined,
    cost_count: usize = 0,
    volumes: [nav.max_volumes]nav.Volume = undefined,
    volume_count: usize = 0,
    links: [nav.max_links]nav.LinkInput = undefined,
    link_count: usize = 0,

    pub fn read(self: *Features, settings: *const asset.nav_mesh.Settings, store: *const data.Store) !void {
        self.cost_count = try asset.nav_mesh.resolveAreas(settings, store, self.costs[0..nav.max_areas]);
        var ids: [asset.nav_mesh.max_areas]core.ContentId = undefined;
        const areas = settings.areas(&ids);
        for (settings.volumes(), self.volumes[0..settings.volumes().len]) |v, *out| {
            var at: u8 = 0;
            for (areas, 1..) |id, i| {
                if (id.eql(v.area)) at = @intCast(i);
            }
            out.* = .{ .area = at, .min = v.min, .max = v.max };
        }
        self.volume_count = settings.volumes().len;
        for (settings.links(), self.links[0..settings.links().len]) |l, *out| {
            out.* = .{ .kind = @enumFromInt(@intFromEnum(l.kind)), .from = l.from, .to = l.to, .two_way = l.two_way, .cost = l.cost, .snap = l.snap, .arc = l.arc };
        }
        self.link_count = settings.links().len;
    }

    pub fn view(self: *const Features) nav.Features {
        if (self.volume_count == 0) return .{ .links = self.links[0..self.link_count] };
        return .{ .costs = self.costs[0..self.cost_count], .volumes = self.volumes[0..self.volume_count], .links = self.links[0..self.link_count] };
    }
};

/// The gate, as a box where it stands.
pub const GateBox = struct { half_extents: Vec3, position: Vec3 };

/// The recipe's sources as `nav.Source`s borrowing loaded assets, and its config. `held` receives
/// every handle acquired, for the caller to release once the build has copied them.
pub fn gather(gpa: Allocator, store: *const data.Store, assets: *asset.Registry, out: *std.ArrayList(nav.Source), held: *std.ArrayList(asset.AssetHandle), features: *Features) !nav.Config {
    const record = store.lookup(recipe_id) orelse return error.MissingRecipe;
    if (!record.schema.id.eql(asset.nav_mesh.nav_mesh.id)) return error.WrongKind;
    const settings = asset.nav_mesh.decode(record.fields) catch |err| {
        log.warn("{f}: navigation mesh {s}", .{ recipe_id, asset.nav_mesh.describe(err) });
        return error.InvalidRecipe;
    };
    asset.nav_mesh.checkSources(&settings, store, asset.schemas.collision_mesh.id) catch |err| {
        log.warn("{f}: navigation mesh {s}", .{ recipe_id, asset.nav_mesh.describe(err) });
        return error.InvalidRecipe;
    };
    features.read(&settings, store) catch |err| {
        log.warn("{f}: its areas or links could not be read ({t})", .{ recipe_id, err });
        return error.InvalidRecipe;
    };
    for (settings.sources()) |id| {
        const handle = assets.acquire(gpa, id) catch |err| {
            log.warn("navigation source {f} omitted ({t})", .{ id, err });
            continue;
        };
        try held.append(gpa, handle);
        const product = assets.getIfLoader(handle, asset.collisionMeshLoader()) orelse {
            log.warn("navigation source {f} omitted (not collision)", .{id});
            continue;
        };
        const geometry = asset.collision_mesh.fromPayload(product.payload);
        try out.append(gpa, .{ .positions = geometry.positions, .indices = geometry.indices });
    }
    var config: nav.Config = undefined;
    inline for (std.meta.fields(nav.Config)) |f| @field(config, f.name) = @field(settings, f.name);
    return config;
}

pub const Navigation = struct {
    gpa: Allocator,
    /// Every mesh of a run, since a replay and a restart may read any of them. The court makes two.
    meshes: nav.Meshes,
    /// The generation the game has adopted, which is the one drawn.
    current: u32 = 0,
    /// The generation with the gate open, once it has been built.
    open_generation: u32 = 0,
    /// Whether the mesh being built is the open gate's.
    building_open: bool = false,
    /// A generation for the next tick's input.
    owed: u32 = 0,
    /// Whether the first mesh has arrived, or failed. Play waits for it.
    ready: bool = false,
    shown: bool = false,
    /// `FOUNDRY_COURT_NAV=off`: nothing is built, and the same frames are still measured, as the
    /// baseline a build's frames are compared with.
    off: bool = false,
    view: render3d.MeshHandle = .none,
    material: render3d.MaterialHandle = .none,
    view_current: bool = false,
    // Measurement only, never read by a tick: the frames from the request to 60 past arrival.
    requested_ns: u64 = 0,
    arrived_frame: ?u64 = null,
    frames: u32 = 0,
    worst_frame_ns: i64 = 0,
    worst_pump_ns: i64 = 0,
    reported: bool = false,

    pub const frames_after_arrival = 60;

    pub fn init(gpa: Allocator) Navigation {
        return .{ .gpa = gpa, .meshes = .init(gpa, .{}) };
    }

    /// The mesh drawn.
    pub fn mesh(self: *const Navigation) ?*const nav.Mesh {
        return self.meshes.get(self.current);
    }

    /// Waits for the build through `tasks`, then frees everything.
    pub fn deinit(self: *Navigation, tasks: core.Tasks, renderer: ?*render3d.Renderer, content: ?*render3d.Content) void {
        self.meshes.deinit(tasks);
        if (renderer) |r| if (!self.view.isNone()) r.destroyMesh(self.view);
        if (content) |c| if (!self.material.isNone()) c.releaseMaterial(self.material);
        self.* = undefined;
    }

    pub fn request(self: *Navigation, tasks: core.Tasks, store: *const data.Store, assets: *asset.Registry, gate: ?GateBox, now_ns: u64) void {
        if (self.off) {
            self.requested_ns = @max(now_ns, 1);
            self.arrived_frame = 0;
            self.ready = true;
            log.info("navigation: off; measuring the same frames with no build", .{});
            return;
        }
        var sources: std.ArrayList(nav.Source) = .empty;
        defer sources.deinit(self.gpa);
        var held: std.ArrayList(asset.AssetHandle) = .empty;
        defer {
            for (held.items) |h| assets.release(h);
            held.deinit(self.gpa);
        }
        var features: Features = .{};
        const config = gather(self.gpa, store, assets, &sources, &held, &features) catch |err| {
            log.warn("navigation: no build ({t})", .{err});
            self.ready = true;
            return;
        };
        var box: nav.BoxGeometry = undefined;
        if (gate) |g| sources.append(self.gpa, nav.boxSource(g.half_extents, .{ .position = g.position, .rotation = .identity }, &box)) catch |err| {
            log.warn("navigation: the gate is left out ({t})", .{err});
        };
        self.meshes.markDirty();
        self.meshes.start(tasks, config, sources.items, features.view()) catch |err| {
            log.warn("navigation: the build did not start ({t})", .{err});
            self.ready = true;
            return;
        };
        self.requested_ns = now_ns;
        log.info("navigation: building the warden's mesh from {d} source(s)", .{sources.items.len});
    }

    /// Takes the build if it has arrived. On the main thread, between frames. `gate_open` is
    /// whether the game's gate still stands open, since a restart may have shut it meanwhile.
    pub fn pump(self: *Navigation, frame: u64, now_ns: u64, gate_open: bool) void {
        const arrival = self.meshes.pump() orelse return;
        self.ready = true;
        self.arrived_frame = frame;
        const open = self.building_open;
        self.building_open = false;
        const took = @as(f64, @floatFromInt(now_ns -| self.requested_ns)) / core.time.ns_per_ms;
        switch (arrival) {
            .failed => |err| log.warn("navigation: the build failed ({t})", .{err}),
            .generation => |generation| {
                const fresh = self.meshes.get(generation).?;
                if (fresh.links_unattached != 0) log.warn("navigation: {d} link(s) landed on no polygon", .{fresh.links_unattached});
                log.info("navigation: {d} polygons, {d} detail triangles, {d} links, {d} skipped; request to arrival {d:.3}ms", .{
                    fresh.polygons.len, fresh.detail.triangles.len, fresh.links.len, fresh.skipped, took,
                });
                if (open) {
                    self.open_generation = generation;
                    if (gate_open) self.owed = generation;
                }
            },
        }
    }

    /// The gate has come to rest open: its mesh, built now if this is the first time.
    pub fn gateOpened(self: *Navigation, tasks: core.Tasks, store: *const data.Store, assets: *asset.Registry, gate: GateBox, now_ns: u64) void {
        if (self.off or self.current == 0) return;
        if (self.open_generation != 0) {
            self.owed = self.open_generation;
            return;
        }
        self.building_open = true;
        self.request(tasks, store, assets, gate, now_ns);
        if (self.meshes.pending == null) self.building_open = false;
    }

    /// What goes in the next tick's input, once.
    pub fn takeOwed(self: *Navigation) u32 {
        defer self.owed = 0;
        return self.owed;
    }

    /// The generation the game has adopted, so that it is the one drawn.
    pub fn noteAdopted(self: *Navigation, generation: u32) void {
        if (generation == self.current) return;
        self.current = generation;
        self.view_current = false;
    }

    /// One frame's work (no pacing sleep, image acquire or present), from the request to
    /// `frames_after_arrival` frames after the mesh arrived.
    pub fn noteFrame(self: *Navigation, recorder: *const core.profile.Recorder) void {
        if (self.reported or self.requested_ns == 0) return;
        const frame = recorder.latest() orelse return;
        var waiting: i64 = 0;
        for (frame.spans) |span| {
            const name = recorder.nameOf(span.name);
            if (std.mem.eql(u8, name, "render.acquire") or std.mem.eql(u8, name, "render.present")) waiting += span.durationNs();
            if (std.mem.eql(u8, name, "navigation.pump")) self.worst_pump_ns = @max(self.worst_pump_ns, span.durationNs());
        }
        self.worst_frame_ns = @max(self.worst_frame_ns, frame.total_ns - waiting);
        self.frames += 1;
        if (self.arrived_frame) |at| if (frame.index >= at + frames_after_arrival) self.report();
    }

    pub fn report(self: *Navigation) void {
        if (self.reported or self.requested_ns == 0) return;
        self.reported = true;
        log.info("navigation: frame work over {d} frames from the request: max {d:.3}ms; budget 16.67ms; navigation.pump max {d:.3}ms", .{
            self.frames, @as(f64, @floatFromInt(self.worst_frame_ns)) / core.time.ns_per_ms, @as(f64, @floatFromInt(self.worst_pump_ns)) / core.time.ns_per_ms,
        });
    }

    /// Writes the view's runtime mesh before the frame begins, as every runtime write is
    /// (ADR-0063).
    pub fn prepare(self: *Navigation, renderer: *render3d.Renderer, content: *render3d.Content) void {
        if (!self.shown or self.view_current) return;
        const current = self.mesh() orelse return;
        if (self.material.isNone()) {
            self.material = content.acquireMaterial(material_id) catch |err| {
                log.warn("navigation view: {f} is not usable ({t}); not drawn", .{ material_id, err });
                self.shown = false;
                return;
            };
        }
        self.writeView(renderer, current) catch |err| {
            log.warn("navigation view not drawn ({t})", .{err});
            self.shown = false;
            return;
        };
        self.view_current = true;
    }

    fn writeView(self: *Navigation, renderer: *render3d.Renderer, current: *const nav.Mesh) !void {
        const n = nav.debugViewCount(current);
        if (n == 0) return error.Empty;
        const vertices = try self.gpa.alloc(nav.ViewVertex, n);
        defer self.gpa.free(vertices);
        const written = nav.debugView(current, vertices);
        const positions = try self.gpa.alloc(Vec3, written.len);
        defer self.gpa.free(positions);
        const colours = try self.gpa.alloc([4]f32, written.len);
        defer self.gpa.free(colours);
        const uvs = try self.gpa.alloc([2]f32, written.len);
        defer self.gpa.free(uvs);
        const indices = try self.gpa.alloc(u32, written.len);
        defer self.gpa.free(indices);
        for (written, positions, colours, uvs, indices, 0..) |v, *p, *c, *uv, *ix, i| {
            p.* = v.position;
            c.* = v.color;
            uv.* = .{ 0, 0 };
            ix.* = @intCast(i);
        }
        var builder: asset.MeshBuilder = .init(self.gpa, .{});
        defer builder.deinit();
        try builder.positions(positions);
        try builder.uv0(uvs);
        try builder.colors(colours);
        try builder.indices32(indices);
        var owned = try builder.finish();
        defer owned.deinit(self.gpa);
        if (self.view.isNone()) {
            self.view = try renderer.createMesh(owned.mesh, "court navigation");
        } else try renderer.updateMesh(self.view, owned.mesh, "court navigation");
    }

    /// Inside the frame, after `begin`.
    pub fn draw(self: *const Navigation, renderer: *render3d.Renderer) !void {
        if (!self.shown or !self.view_current or self.view.isNone() or self.material.isNone()) return;
        try renderer.drawMesh(.{ .mesh = self.view, .material = self.material, .world = .identity });
    }
};
