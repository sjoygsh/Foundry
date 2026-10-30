//! M32's navigation mesh (`docs/design/navigation.md` §9.1): the walker's, built from the room's
//! and the course's collision and every prop's, at load and again at each reload, on the
//! background pool; drawn when N is pressed.
//!
//! **The glue the design leaves to a game** (§7): read `sandbox3d:nav.walker`, check each source
//! is a loaded `foundry:collision_mesh`, add each prop's collision at its position and yaw, and
//! start a `nav.Build`. A source that will not load is said and left out, as the walk's
//! collision is. `plinth` reaches navigation through its prop, and `stout` through the record.
//!
//! **Arrival is not adoption** (ADR-0061's decision 4): `pump` makes the last mesh that arrived the
//! one drawn, and offers it to the crowd through `takeAdoption`, which the frame hands over before
//! any tick. Until a new one arrives the old one stays. `nav.Meshes` runs one build at a time, so
//! a reload or a sliding crate during one waits and is read as it is by then.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const nav = @import("nav");
const render3d = @import("render3d");
const Props = @import("props.zig").Props;
const Window = @import("gallery.zig").Window;

const Allocator = std.mem.Allocator;
const Vec3 = core.math.Vec3;
const log = core.log.scoped(.sandbox3d);

pub const recipe_id = core.ContentId.fromString("sandbox3d:nav.walker");
pub const material_id = core.ContentId.fromString("sandbox3d:materials.navigation");

/// The recipe as `nav` takes it, field for field.
pub fn configOf(s: *const asset.nav_mesh.Settings) nav.Config {
    var out: nav.Config = undefined;
    inline for (std.meta.fields(nav.Config)) |f| @field(out, f.name) = @field(s, f.name);
    return out;
}

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

/// The recipe's sources and every prop's collision, as `nav.Source`s borrowing loaded assets.
/// `held` receives each asset handle acquired here, for the caller to release once the build has
/// copied them.
pub fn gather(gpa: Allocator, store: *const data.Store, assets: *asset.Registry, props: *const Props, out: *std.ArrayList(nav.Source), held: *std.ArrayList(asset.AssetHandle), features: *Features) !nav.Config {
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
        log.warn("{f}: navigation mesh {s}", .{ recipe_id, if (@as(anyerror, err) == error.OutOfMemory) "ran out of memory" else asset.nav_mesh.describe(@errorCast(err)) });
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
    for (props.entries[0..props.len]) |*entry| {
        if (entry.asset_handle.isNone()) continue;
        const product = assets.getIfLoader(entry.asset_handle, asset.collisionMeshLoader()) orelse continue;
        const geometry = asset.collision_mesh.fromPayload(product.payload);
        try out.append(gpa, .{
            .positions = geometry.positions,
            .indices = geometry.indices,
            .pose = .{ .position = entry.settings.position, .rotation = entry.settings.rotation() },
        });
    }
    return configOf(&settings);
}

/// A running obstacle, as a box at a place.
pub const Obstacle = struct { half_extents: Vec3, position: Vec3 };

pub const Navigation = struct {
    gpa: Allocator,
    /// The newest few generations: the sandbox replays nothing, so it keeps only what is in use.
    meshes: nav.Meshes,
    /// The generation drawn and in use, or 0.
    current: u32 = 0,
    /// A generation that has arrived and is not yet the crowd's.
    owed: u32 = 0,
    shown: bool = false,
    /// `FOUNDRY_SANDBOX3D_NAV=off`: nothing is built, and the same frames are still measured, as
    /// the baseline a build's frames are compared with.
    off: bool = false,
    view: render3d.MeshHandle = .none,
    /// The agents' paths, a mesh of their own because they change every tick.
    agents_view: render3d.MeshHandle = .none,
    agents_drawn: bool = false,
    material: render3d.MaterialHandle = .none,
    /// Whether `view` shows the mesh as it is now.
    view_current: bool = false,
    /// Measurement only, never read by a tick: the frames from a request to after its arrival.
    window: Window = .{ .label = "navigation", .pump_span = "navigation.pump" },
    requested_ns: u64 = 0,
    requests: u32 = 0,
    arrivals: u32 = 0,

    pub fn init(gpa: Allocator) Navigation {
        return .{ .gpa = gpa, .meshes = .init(gpa, .{ .keep = 3 }) };
    }

    /// The mesh in use, if one has arrived.
    pub fn mesh(self: *const Navigation) ?*const nav.Mesh {
        return self.meshes.get(self.current);
    }

    /// Waits for a build to finish, through `tasks`, then frees it all.
    pub fn deinit(self: *Navigation, tasks: core.Tasks, renderer: ?*render3d.Renderer, content: ?*render3d.Content) void {
        self.meshes.deinit(tasks);
        if (renderer) |r| if (!self.view.isNone()) r.destroyMesh(self.view);
        if (renderer) |r| if (!self.agents_view.isNone()) r.destroyMesh(self.agents_view);
        if (content) |c| if (!self.material.isNone()) c.releaseMaterial(self.material);
        self.* = undefined;
    }

    /// Starts a build from the content as it is now, or asks for one when the one running ends.
    pub fn request(self: *Navigation, tasks: core.Tasks, store: *const data.Store, assets: *asset.Registry, props: *const Props, obstacle: ?Obstacle, frame: u64, now_ns: u64) void {
        self.meshes.markDirty();
        self.service(tasks, store, assets, props, obstacle, frame, now_ns);
    }

    /// Starts the build that is owed, if one is and none is running. Each frame, since a change
    /// made during a build is read only when that build has ended.
    pub fn service(self: *Navigation, tasks: core.Tasks, store: *const data.Store, assets: *asset.Registry, props: *const Props, obstacle: ?Obstacle, frame: u64, now_ns: u64) void {
        if (!self.meshes.wantsBuild()) return;
        if (self.off) {
            self.window.start(frame, .sync);
            self.window.markReady(frame, 0);
            log.info("navigation: off; measuring the same frames with no build", .{});
            self.meshes.dirty = false;
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
        const config = gather(self.gpa, store, assets, props, &sources, &held, &features) catch |err| {
            self.meshes.dirty = false;
            log.warn("navigation: no build ({t}); {s}", .{ err, if (self.mesh() != null) "keeping the last mesh" else "no mesh" });
            return;
        };
        var box: nav.BoxGeometry = undefined;
        if (obstacle) |o| sources.append(self.gpa, nav.boxSource(o.half_extents, .{ .position = o.position, .rotation = .identity }, &box)) catch |err| {
            log.warn("navigation: the obstacle is left out ({t})", .{err});
        };
        self.meshes.start(tasks, config, sources.items, features.view()) catch |err| {
            log.warn("navigation: the build did not start ({t})", .{err});
            return;
        };
        self.requests += 1;
        self.requested_ns = now_ns;
        self.window.start(frame, .background);
        log.info("navigation: building from {d} sources ({t} executor)", .{ sources.items.len, if (tasks.vtable == core.tasks.immediate.vtable) @as(enum { immediate, pool }, .immediate) else .pool });
    }

    /// What `request` cost the main thread, said by the caller, who has the clock.
    pub fn noteRequestCost(self: *const Navigation, ns: u64) void {
        if (self.off) return;
        log.info("navigation: the request took {d:.3}ms on the main thread (gathering and copying the sources)", .{@as(f64, @floatFromInt(ns)) / core.time.ns_per_ms});
    }

    /// Takes a finished build if there is one. On the main thread, between frames.
    pub fn pump(self: *Navigation, frame: u64, now_ns: u64) void {
        const arrival = self.meshes.pump() orelse return;
        const took: i64 = @intCast(now_ns -| self.requested_ns);
        self.window.markReady(frame, took);
        switch (arrival) {
            .failed => |err| log.warn("navigation: the build failed ({t}); {s}", .{ err, if (self.mesh() != null) "keeping the last mesh" else "no mesh" }),
            .generation => |generation| {
                self.current = generation;
                self.owed = generation;
                self.meshes.use(generation);
                self.view_current = false;
                self.arrivals += 1;
                const fresh = self.mesh().?;
                if (fresh.links_unattached != 0) log.warn("navigation: {d} link(s) landed on no polygon", .{fresh.links_unattached});
                log.info("navigation: {d} polygons, {d} regions, {d} detail triangles, {d} links, {d} skipped; request to arrival {d:.3}ms", .{
                    fresh.polygons.len, regionCount(fresh), fresh.detail.triangles.len, fresh.links.len, fresh.skipped, @as(f64, @floatFromInt(took)) / core.time.ns_per_ms,
                });
            },
        }
    }

    /// The mesh newly arrived, for the frame to hand the crowd before any tick, once.
    pub fn takeAdoption(self: *Navigation) ?*const nav.Mesh {
        if (self.owed == 0) return null;
        self.owed = 0;
        return self.mesh();
    }

    pub fn toggle(self: *Navigation) void {
        self.shown = !self.shown;
        log.info("n: navigation mesh {s}", .{if (self.shown) "shown" else "hidden"});
    }

    /// Writes the view's runtime mesh if it is shown and out of date. Outside the frame's
    /// submission window, as every runtime mesh write is (ADR-0063).
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

    /// Writes the agents' paths, every frame they are shown. An empty crowd draws nothing.
    pub fn prepareAgents(self: *Navigation, renderer: *render3d.Renderer, crowd: ?*const nav.Crowd) void {
        self.agents_drawn = false;
        if (!self.shown or self.material.isNone()) return;
        const c = crowd orelse return;
        const n = nav.debugAgentsCount(c);
        if (n == 0) return;
        const vertices = self.gpa.alloc(nav.ViewVertex, n) catch return;
        defer self.gpa.free(vertices);
        const written = nav.debugAgents(c, vertices);
        if (written.len == 0) return;
        self.writeMesh(renderer, &self.agents_view, written, "sandbox3d agents") catch |err| {
            log.warn("the agents' paths are not drawn ({t})", .{err});
            return;
        };
        self.agents_drawn = true;
    }

    fn writeView(self: *Navigation, renderer: *render3d.Renderer, current: *const nav.Mesh) !void {
        const n = nav.debugViewCount(current);
        if (n == 0) return error.Empty;
        const vertices = try self.gpa.alloc(nav.ViewVertex, n);
        defer self.gpa.free(vertices);
        try self.writeMesh(renderer, &self.view, nav.debugView(current, vertices), "sandbox3d navigation");
    }

    fn writeMesh(self: *Navigation, renderer: *render3d.Renderer, into: *render3d.MeshHandle, written: []const nav.ViewVertex, label: []const u8) !void {
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
        if (into.isNone()) {
            into.* = try renderer.createMesh(owned.mesh, label);
        } else try renderer.updateMesh(into.*, owned.mesh, label);
    }

    /// Drawn inside the frame, after `begin`.
    pub fn draw(self: *const Navigation, renderer: *render3d.Renderer) !void {
        if (!self.shown or !self.view_current or self.view.isNone() or self.material.isNone()) return;
        try renderer.drawMesh(.{ .mesh = self.view, .material = self.material, .world = .identity });
        if (self.agents_drawn) try renderer.drawMesh(.{ .mesh = self.agents_view, .material = self.material, .world = .identity });
    }

    /// After a content change: the material may be another record now.
    pub fn contentChanged(self: *Navigation, content: *render3d.Content) void {
        if (!self.material.isNone()) content.releaseMaterial(self.material);
        self.material = .none;
        self.view_current = false;
    }
};

pub fn regionCount(mesh: *const nav.Mesh) u32 {
    var max: u16 = 0;
    for (mesh.polygons) |p| max = @max(max, p.region);
    return max;
}
