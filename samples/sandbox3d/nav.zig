//! M32's navigation mesh (`docs/design/navigation.md` §9.1): the walker's, built from the room's
//! and the course's collision and every prop's, at load and again at each reload, on the
//! background pool; drawn when N is pressed.
//!
//! **The glue the design leaves to a game** (§7): read `sandbox3d:nav.walker`, check each source
//! is a loaded `foundry:collision_mesh`, add each prop's collision at its position and yaw, and
//! start a `nav.Build`. A source that will not load is said and left out, as the walk's
//! collision is. `plinth` reaches navigation through its prop, and `stout` through the record.
//!
//! **Arrival is presentation** (ADR-0061): the mesh in use is the last one that arrived. Until a
//! new one does, the old one is drawn. A build a reload superseded is kept until it finishes and
//! then discarded untaken.

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

/// The recipe's sources and every prop's collision, as `nav.Source`s borrowing loaded assets.
/// `held` receives each asset handle acquired here, for the caller to release once the build has
/// copied them.
pub fn gather(gpa: Allocator, store: *const data.Store, assets: *asset.Registry, props: *const Props, out: *std.ArrayList(nav.Source), held: *std.ArrayList(asset.AssetHandle)) !nav.Config {
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

pub const Navigation = struct {
    gpa: Allocator,
    pending: ?nav.Build = null,
    /// Builds a reload superseded, kept until they finish.
    stale: std.ArrayList(nav.Build) = .empty,
    mesh: ?nav.Mesh = null,
    shown: bool = false,
    /// `FOUNDRY_SANDBOX3D_NAV=off`: nothing is built, and the same frames are still measured, as
    /// the baseline a build's frames are compared with.
    off: bool = false,
    view: render3d.MeshHandle = .none,
    material: render3d.MaterialHandle = .none,
    /// Whether `view` shows `mesh` as it is now.
    view_current: bool = false,
    /// Measurement only, never read by a tick: the frames from a request to after its arrival.
    window: Window = .{ .label = "navigation", .pump_span = "navigation.pump" },
    requested_ns: u64 = 0,
    requests: u32 = 0,
    arrivals: u32 = 0,

    pub fn init(gpa: Allocator) Navigation {
        return .{ .gpa = gpa };
    }

    /// Waits for every build to finish, through `tasks`, then frees it all.
    pub fn deinit(self: *Navigation, tasks: core.Tasks, renderer: ?*render3d.Renderer, content: ?*render3d.Content) void {
        tasks.wait();
        if (self.pending) |*b| b.deinit();
        for (self.stale.items) |*b| b.deinit();
        self.stale.deinit(self.gpa);
        if (self.mesh) |*m| m.deinit(self.gpa);
        if (renderer) |r| if (!self.view.isNone()) r.destroyMesh(self.view);
        if (content) |c| if (!self.material.isNone()) c.releaseMaterial(self.material);
        self.* = undefined;
    }

    /// Starts a build from the content as it is now. A build already running is superseded.
    pub fn request(self: *Navigation, tasks: core.Tasks, store: *const data.Store, assets: *asset.Registry, props: *const Props, frame: u64, now_ns: u64) void {
        if (self.off) {
            self.window.start(frame, .sync);
            self.window.markReady(frame, 0);
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
        const config = gather(self.gpa, store, assets, props, &sources, &held) catch |err| {
            log.warn("navigation: no build ({t}); {s}", .{ err, if (self.mesh != null) "keeping the last mesh" else "no mesh" });
            return;
        };
        const started = nav.Build.start(tasks, self.gpa, config, sources.items) catch |err| {
            log.warn("navigation: the build did not start ({t})", .{err});
            return;
        };
        if (self.pending) |old| self.stale.append(self.gpa, old) catch {
            // No room to keep it: wait for it here rather than leak it. Rare, and never on a tick.
            tasks.wait();
            var discarded = old;
            discarded.deinit();
        };
        self.pending = started;
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

    /// Discards finished stale builds and takes the pending one if it has arrived. On the main
    /// thread, between frames.
    pub fn pump(self: *Navigation, frame: u64, now_ns: u64) void {
        var i: usize = 0;
        while (i < self.stale.items.len) {
            if (self.stale.items[i].ready()) {
                var b = self.stale.swapRemove(i);
                b.deinit();
            } else i += 1;
        }
        var b = &(self.pending orelse return);
        const answer = b.take() orelse return;
        b.deinit();
        self.pending = null;
        const took: i64 = @intCast(now_ns -| self.requested_ns);
        self.window.markReady(frame, took);
        const fresh = answer catch |err| {
            log.warn("navigation: the build failed ({t}); {s}", .{ err, if (self.mesh != null) "keeping the last mesh" else "no mesh" });
            return;
        };
        if (self.mesh) |*old| old.deinit(self.gpa);
        self.mesh = fresh;
        self.view_current = false;
        self.arrivals += 1;
        log.info("navigation: {d} polygons, {d} regions, {d} detail triangles, {d} skipped; request to arrival {d:.3}ms", .{
            fresh.polygons.len, regionCount(&fresh), fresh.detail.triangles.len, fresh.skipped, @as(f64, @floatFromInt(took)) / core.time.ns_per_ms,
        });
    }

    pub fn toggle(self: *Navigation) void {
        self.shown = !self.shown;
        log.info("n: navigation mesh {s}", .{if (self.shown) "shown" else "hidden"});
    }

    /// Writes the view's runtime mesh if it is shown and out of date. Outside the frame's
    /// submission window, as every runtime mesh write is (ADR-0063).
    pub fn prepare(self: *Navigation, renderer: *render3d.Renderer, content: *render3d.Content) void {
        if (!self.shown or self.view_current) return;
        const mesh = &(self.mesh orelse return);
        if (self.material.isNone()) {
            self.material = content.acquireMaterial(material_id) catch |err| {
                log.warn("navigation view: {f} is not usable ({t}); not drawn", .{ material_id, err });
                self.shown = false;
                return;
            };
        }
        self.writeView(renderer, mesh) catch |err| {
            log.warn("navigation view not drawn ({t})", .{err});
            self.shown = false;
            return;
        };
        self.view_current = true;
    }

    fn writeView(self: *Navigation, renderer: *render3d.Renderer, mesh: *const nav.Mesh) !void {
        const n = nav.debugViewCount(mesh);
        if (n == 0) return error.Empty;
        const vertices = try self.gpa.alloc(nav.ViewVertex, n);
        defer self.gpa.free(vertices);
        const written = nav.debugView(mesh, vertices);
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
            self.view = try renderer.createMesh(owned.mesh, "sandbox3d navigation");
        } else try renderer.updateMesh(self.view, owned.mesh, "sandbox3d navigation");
    }

    /// Drawn inside the frame, after `begin`.
    pub fn draw(self: *const Navigation, renderer: *render3d.Renderer) !void {
        if (!self.shown or !self.view_current or self.view.isNone() or self.material.isNone()) return;
        try renderer.drawMesh(.{ .mesh = self.view, .material = self.material, .world = .identity });
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
