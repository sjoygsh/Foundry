//! M41's scenery (`docs/design/environment.md` §11): the yard's and the room's environments, two
//! rows of spheres on the yard's hillside and a glTF lamp in M37's corner, all named by
//! `sandbox3d:scenery.main`.
//!
//! - **One environment a frame** (§4), chosen by where the camera is: inside the room's walls
//!   (`indoors_half` either way of the origin and below `indoors_height`) it is `indoors`, and
//!   anywhere else `outdoors`. Both are requested once, prefiltered on the background pool, and
//!   named by the frame only once ready, so a frame never waits for one. `--environment=off`
//!   names neither.
//! - **The spheres** are one runtime mesh drawn fourteen times, each with its own content
//!   material, decorative and never a body, so no tour pin moves.
//! - **The lamp** is a model whose light the import made a record; it is drawn and its light is
//!   submitted through `modelLights`, the path a game places a model's lights by (ADR-0085).
//!
//! The record is untrusted content: it is read whole or not at all, and a missing piece is left
//! out and said once, as the yard and the corner do.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const render3d = @import("render3d");
const Vec3 = core.math.Vec3;
const Quat = core.math.Quat;
const Mat4 = core.math.Mat4;
const Fields = data.fpk.Fields;
const log = core.log.scoped(.sandbox3d);

pub const record_id = core.ContentId.fromString("sandbox3d:scenery.main");
/// Spheres in a row; the two rows are dielectric and metal.
pub const row_len = 7;

pub const Settings = struct {
    outdoors: core.ContentId = .none,
    indoors: core.ContentId = .none,
    indoors_half: f32 = 3,
    indoors_height: f32 = 3,
    lamp: core.ContentId = .none,
    lamp_position: Vec3 = .zero,
    lamp_yaw: f32 = 0,
    sphere_origin: Vec3 = .zero,
    sphere_step: Vec3 = .zero,
    sphere_row: Vec3 = .zero,
    sphere_radius: f32 = 0.35,
    dielectric: [row_len]core.ContentId = @splat(.none),
    metal: [row_len]core.ContentId = @splat(.none),

    pub fn read(fields: Fields) error{InvalidScenery}!Settings {
        var out: Settings = .{
            .outdoors = try optionalId(fields, "outdoors"),
            .indoors = try optionalId(fields, "indoors"),
            .indoors_half = try number(fields, "indoors_half"),
            .indoors_height = try number(fields, "indoors_height"),
            .lamp = try optionalId(fields, "lamp"),
            .lamp_position = try xyz(fields, "lamp_position"),
            .lamp_yaw = try number(fields, "lamp_yaw"),
            .sphere_origin = try xyz(fields, "sphere_origin"),
            .sphere_step = try xyz(fields, "sphere_step"),
            .sphere_row = try xyz(fields, "sphere_row"),
            .sphere_radius = try number(fields, "sphere_radius"),
        };
        if (out.indoors_half <= 0 or out.indoors_half > 100 or out.indoors_height <= 0 or out.indoors_height > 100) return error.InvalidScenery;
        if (out.sphere_radius <= 0 or out.sphere_radius > 2) return error.InvalidScenery;
        for ([_]Vec3{ out.lamp_position, out.sphere_origin, out.sphere_step, out.sphere_row }) |v|
            if (@abs(v.x) > 1000 or @abs(v.y) > 1000 or @abs(v.z) > 1000) return error.InvalidScenery;
        try ids(fields, "dielectric", &out.dielectric);
        try ids(fields, "metal", &out.metal);
        return out;
    }

    /// Where sphere `i` of `row` stands, before the ground lifts it.
    pub fn sphereAt(self: Settings, row: usize, i: usize) Vec3 {
        return self.sphere_origin.add(self.sphere_step.scale(@floatFromInt(i))).add(self.sphere_row.scale(@floatFromInt(row)));
    }

    /// The environment for a camera at `eye`: indoors inside the room's walls, else outdoors.
    pub fn environmentFor(self: Settings, eye: Vec3) core.ContentId {
        const inside = @abs(eye.x) < self.indoors_half and @abs(eye.z) < self.indoors_half and eye.y < self.indoors_height;
        return if (inside) self.indoors else self.outdoors;
    }
};

pub const Scenery = struct {
    settings: ?Settings = null,
    /// `--environment=off`: no frame names an environment.
    enabled: bool = true,
    outdoors: render3d.EnvironmentHandle = .none,
    indoors: render3d.EnvironmentHandle = .none,
    sphere: render3d.MeshHandle = .none,
    materials: [2 * row_len]render3d.MaterialHandle = @splat(.none),
    lamp: render3d.ModelHandle = .none,
    /// Frames that named each environment and drew its sky, for the exit's report and the tour.
    outdoor_frames: u64 = 0,
    indoor_frames: u64 = 0,
    reported: bool = false,

    /// Reads the record again and follows it: what it newly names is asked for before what it no
    /// longer names is let go, so an unchanged environment is not prefiltered twice.
    pub fn refresh(self: *Scenery, gpa: std.mem.Allocator, store: *const data.Store, content: ?*render3d.Content) void {
        const c = content orelse return;
        self.reported = false;
        const record = store.lookup(record_id) orelse {
            self.release(c);
            self.settings = null;
            return;
        };
        const s = Settings.read(record.fields) catch {
            log.warn("'sandbox3d:scenery.main' is not a scenery record this sample can read; no environments, spheres or lamp", .{});
            self.release(c);
            self.settings = null;
            return;
        };
        var next: Scenery = .{ .enabled = self.enabled, .settings = s, .outdoor_frames = self.outdoor_frames, .indoor_frames = self.indoor_frames };
        next.outdoors = requestOne(c, s.outdoors);
        next.indoors = requestOne(c, s.indoors);
        for (s.dielectric ++ s.metal, 0..) |id, i| next.materials[i] = c.acquireMaterial(id) catch |err| blk: {
            log.warn("a sphere's material is not drawn ({t})", .{err});
            break :blk .none;
        };
        if (!s.lamp.isNone()) next.lamp = c.acquireModel(s.lamp) catch |err| blk: {
            log.warn("the M41 lamp is not drawn ({t})", .{err});
            break :blk .none;
        };
        next.sphere = self.sphere;
        self.sphere = .none;
        if (next.sphere.isNone() or (self.settings != null and self.settings.?.sphere_radius != s.sphere_radius)) {
            if (!next.sphere.isNone()) c.renderer.destroyMesh(next.sphere);
            next.sphere = sphereMesh(gpa, c, s.sphere_radius) catch |err| blk: {
                log.warn("the M41 spheres are not drawn ({t})", .{err});
                break :blk .none;
            };
        }
        self.release(c);
        self.* = next;
    }

    pub fn deinit(self: *Scenery, content: ?*render3d.Content) void {
        const c = content orelse return;
        self.release(c);
        if (!self.sphere.isNone()) c.renderer.destroyMesh(self.sphere);
        self.sphere = .none;
    }

    fn release(self: *Scenery, c: *render3d.Content) void {
        if (!self.outdoors.isNone()) c.releaseEnvironment(self.outdoors);
        if (!self.indoors.isNone()) c.releaseEnvironment(self.indoors);
        for (&self.materials) |*m| {
            if (!m.isNone()) c.releaseMaterial(m.*);
            m.* = .none;
        }
        if (!self.lamp.isNone()) c.releaseModel(self.lamp);
        self.outdoors = .none;
        self.indoors = .none;
        self.lamp = .none;
    }

    /// The environment a frame at `eye` names: null when off, unset, or not yet ready.
    pub fn environment(self: *Scenery, content: *render3d.Content, eye: Vec3) ?render3d.EnvironmentHandle {
        if (!self.enabled) return null;
        const s = self.settings orelse return null;
        const id = s.environmentFor(eye);
        if (id.isNone()) return null;
        const handle = if (id.eql(s.indoors)) self.indoors else self.outdoors;
        if (handle.isNone()) return null;
        // Settled before each frame that names it (`environmentState`): a finished prefilter is
        // written here, outside the window.
        const state = (content.environmentState(handle) catch return null) orelse return null;
        if (state != .ready) return null;
        return handle;
    }

    /// Counts what the frame drew, from its own statistics.
    pub fn noteFrame(self: *Scenery, stats: render3d.Stats) void {
        if (!stats.sky_drawn) return;
        const s = self.settings orelse return;
        const id = stats.environment orelse return;
        if (id.eql(s.indoors)) self.indoor_frames += 1 else if (id.eql(s.outdoors)) self.outdoor_frames += 1;
    }

    /// The lamp's light, at its place; the caller submits it with its others.
    pub fn lampLights(self: *Scenery, content: *render3d.Content, out: []render3d.Light) []render3d.Light {
        const s = self.settings orelse return out[0..0];
        if (self.lamp.isNone()) return out[0..0];
        return content.modelLights(self.lamp, lampWorld(s), out) catch |err| {
            if (!self.reported) log.warn("the M41 lamp's light is not submitted ({t})", .{err});
            self.reported = true;
            return out[0..0];
        };
    }

    /// The spheres and the lamp. `ground` lifts a sphere's centre onto the hillside: the height
    /// under it, or null where there is none.
    pub fn draw(self: *Scenery, content: *render3d.Content, ground: anytype) void {
        const s = self.settings orelse return;
        if (!self.lamp.isNone()) content.drawModel(.{ .model = self.lamp, .world = lampWorld(s) }) catch |err| {
            if (!self.reported) log.warn("the M41 lamp is not drawn ({t})", .{err});
            self.reported = true;
        };
        if (self.sphere.isNone()) return;
        for (0..2) |row| for (0..row_len) |i| {
            const material = self.materials[row * row_len + i];
            if (material.isNone()) continue;
            var at = s.sphereAt(row, i);
            at.y += (ground.heightAt(at) orelse 0) + s.sphere_radius + 0.02;
            content.renderer.drawMesh(.{ .mesh = self.sphere, .material = material, .world = Mat4.translation(at) }) catch |err| {
                if (!self.reported) log.warn("an M41 sphere is not drawn ({t})", .{err});
                self.reported = true;
            };
        };
    }
};

fn lampWorld(s: Settings) Mat4 {
    return Mat4.trs(s.lamp_position, Quat.fromAxisAngle(Vec3.up, s.lamp_yaw), .one);
}

fn requestOne(c: *render3d.Content, id: core.ContentId) render3d.EnvironmentHandle {
    if (id.isNone()) return .none;
    return c.requestEnvironment(id) catch |err| {
        log.warn("an M41 environment is not lighting anything ({t})", .{err});
        return .none;
    };
}

/// A UV sphere's arrays, which `sphereMesh` builds a mesh from and the tests read.
pub const Sphere = struct {
    positions: std.ArrayList(Vec3) = .empty,
    normals: std.ArrayList(Vec3) = .empty,
    indices: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Sphere, gpa: std.mem.Allocator) void {
        self.positions.deinit(gpa);
        self.normals.deinit(gpa);
        self.indices.deinit(gpa);
    }
};

/// 32 segments and 16 rings, normals out, counter-clockwise from outside.
pub fn sphereGeometry(gpa: std.mem.Allocator, radius: f32) !Sphere {
    const segments = 32;
    const rings = 16;
    var out: Sphere = .{};
    errdefer out.deinit(gpa);
    for (0..rings + 1) |r| {
        const polar = std.math.pi * @as(f32, @floatFromInt(r)) / rings;
        for (0..segments + 1) |sgm| {
            const azimuth = 2 * std.math.pi * @as(f32, @floatFromInt(sgm)) / segments;
            const n: Vec3 = .init(@sin(polar) * @cos(azimuth), @cos(polar), -@sin(polar) * @sin(azimuth));
            try out.positions.append(gpa, n.scale(radius));
            try out.normals.append(gpa, n);
        }
    }
    const stride: u32 = segments + 1;
    for (0..rings) |r| for (0..segments) |sgm| {
        const a: u32 = @intCast(r * stride + sgm);
        const b = a + stride;
        try out.indices.appendSlice(gpa, &.{ a, b, a + 1, a + 1, b, b + 1 });
    };
    return out;
}

fn sphereMesh(gpa: std.mem.Allocator, c: *render3d.Content, radius: f32) !render3d.MeshHandle {
    var sphere = try sphereGeometry(gpa, radius);
    defer sphere.deinit(gpa);
    var builder: asset.MeshBuilder = .init(gpa, .{});
    defer builder.deinit();
    try builder.positions(sphere.positions.items);
    try builder.normals(sphere.normals.items);
    try builder.indices32(sphere.indices.items);
    var mesh = try builder.finish();
    defer mesh.deinit(gpa);
    return c.renderer.createMesh(mesh.mesh, "sandbox3d spheres");
}

fn index(fields: Fields, name: []const u8) ?u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return null;
}

fn number(fields: Fields, name: []const u8) error{InvalidScenery}!f32 {
    const i = index(fields, name) orelse return error.InvalidScenery;
    const value = (fields.floatAt(i) catch return error.InvalidScenery) orelse return error.InvalidScenery;
    const narrowed: f32 = @floatCast(value);
    if (!std.math.isFinite(narrowed)) return error.InvalidScenery;
    return narrowed;
}

fn xyz(fields: Fields, name: []const u8) error{InvalidScenery}!Vec3 {
    const i = index(fields, name) orelse return error.InvalidScenery;
    const nested = (fields.nestedAt(i) catch return error.InvalidScenery) orelse return error.InvalidScenery;
    return .init(try number(nested, "x"), try number(nested, "y"), try number(nested, "z"));
}

fn optionalId(fields: Fields, name: []const u8) error{InvalidScenery}!core.ContentId {
    const i = index(fields, name) orelse return .none;
    return (fields.idAt(i) catch return error.InvalidScenery) orelse .none;
}

/// Exactly a row's worth of material IDs.
fn ids(fields: Fields, name: []const u8, out: *[row_len]core.ContentId) error{InvalidScenery}!void {
    const i = index(fields, name) orelse return error.InvalidScenery;
    const list = (fields.listAt(i) catch return error.InvalidScenery) orelse return error.InvalidScenery;
    if (list.len != row_len) return error.InvalidScenery;
    for (out, 0..) |*id, n| id.* = (list.idAt(@intCast(n)) catch return error.InvalidScenery) orelse return error.InvalidScenery;
}
