//! M32's warden navigation mesh (`docs/design/navigation.md` §9.2): built from the level's
//! collision when the court loads, on the background pool, and drawn when
//! `FOUNDRY_COURT_NAV=show`. **The game does not use it yet**: the warden patrols as before, and
//! M33's warden walks on this mesh.
//!
//! **The glue the design leaves to a game** (§7): read `court:nav.warden`, check each source is a
//! loaded `foundry:collision_mesh`, and start a `nav.Build`. The court reloads no content, so it
//! builds once. The gate and the beacons are bodies, not collision content, and are not sources:
//! a gate that opens while the game runs is M33's obstacles.
//!
//! **Arrival is presentation** (ADR-0061): nothing a tick computes reads the mesh.

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

/// The recipe's sources as `nav.Source`s borrowing loaded assets, and its config. `held` receives
/// every handle acquired, for the caller to release once the build has copied them.
pub fn gather(gpa: Allocator, store: *const data.Store, assets: *asset.Registry, out: *std.ArrayList(nav.Source), held: *std.ArrayList(asset.AssetHandle)) !nav.Config {
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
    var config: nav.Config = undefined;
    inline for (std.meta.fields(nav.Config)) |f| @field(config, f.name) = @field(settings, f.name);
    return config;
}

pub const Navigation = struct {
    gpa: Allocator,
    pending: ?nav.Build = null,
    mesh: ?nav.Mesh = null,
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
        return .{ .gpa = gpa };
    }

    /// Waits for the build through `tasks`, then frees everything.
    pub fn deinit(self: *Navigation, tasks: core.Tasks, renderer: ?*render3d.Renderer, content: ?*render3d.Content) void {
        tasks.wait();
        if (self.pending) |*b| b.deinit();
        if (self.mesh) |*m| m.deinit(self.gpa);
        if (renderer) |r| if (!self.view.isNone()) r.destroyMesh(self.view);
        if (content) |c| if (!self.material.isNone()) c.releaseMaterial(self.material);
        self.* = undefined;
    }

    pub fn request(self: *Navigation, tasks: core.Tasks, store: *const data.Store, assets: *asset.Registry, now_ns: u64) void {
        if (self.off) {
            self.requested_ns = @max(now_ns, 1);
            self.arrived_frame = 0;
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
        const config = gather(self.gpa, store, assets, &sources, &held) catch |err| {
            log.warn("navigation: no build ({t})", .{err});
            return;
        };
        self.pending = nav.Build.start(tasks, self.gpa, config, sources.items) catch |err| {
            log.warn("navigation: the build did not start ({t})", .{err});
            return;
        };
        self.requested_ns = now_ns;
        log.info("navigation: building the warden's mesh from {d} source(s)", .{sources.items.len});
    }

    /// Takes the build if it has arrived. On the main thread, between frames.
    pub fn pump(self: *Navigation, frame: u64, now_ns: u64) void {
        var b = &(self.pending orelse return);
        const answer = b.take() orelse return;
        b.deinit();
        self.pending = null;
        self.arrived_frame = frame;
        const took = @as(f64, @floatFromInt(now_ns -| self.requested_ns)) / core.time.ns_per_ms;
        const fresh = answer catch |err| {
            log.warn("navigation: the build failed ({t})", .{err});
            return;
        };
        self.mesh = fresh;
        self.view_current = false;
        log.info("navigation: {d} polygons, {d} detail triangles, {d} skipped; request to arrival {d:.3}ms", .{
            fresh.polygons.len, fresh.detail.triangles.len, fresh.skipped, took,
        });
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
            self.view = try renderer.createMesh(owned.mesh, "court navigation");
        } else try renderer.updateMesh(self.view, owned.mesh, "court navigation");
    }

    /// Inside the frame, after `begin`.
    pub fn draw(self: *const Navigation, renderer: *render3d.Renderer) !void {
        if (!self.shown or !self.view_current or self.view.isNone() or self.material.isNone()) return;
        try renderer.drawMesh(.{ .mesh = self.view, .material = self.material, .world = .identity });
    }
};
