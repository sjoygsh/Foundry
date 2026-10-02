//! Sample-owned native consent and retained submission. No mod code runs inside a frame.
const std = @import("std");
const abi = @import("abi");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const render3d = @import("render3d");
const scene = @import("scene");
const physics = @import("physics3d");
const Walk = @import("walk.zig").Walk;
const log = core.log.scoped(.sandbox3d);
const Vec3 = core.math.Vec3;
const Mat4 = core.math.Mat4;

pub const Consent = struct {
    ids: [64]core.ContentId = undefined,
    len: usize = 0,

    /// Malformed or overflowing input refuses the whole consent set, never grants a prefix.
    pub fn parse(text: ?[]const u8) error{ InvalidConsent, TooManyConsents }!Consent {
        var out: Consent = .{};
        var names = std.mem.splitScalar(u8, text orelse "", ',');
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            const id = data.contentId(name) catch return error.InvalidConsent;
            if (out.contains(id)) continue;
            if (out.len == out.ids.len) return error.TooManyConsents;
            out.ids[out.len] = id;
            out.len += 1;
        }
        return out;
    }
    pub fn contains(self: *const Consent, id: core.ContentId) bool {
        for (self.ids[0..self.len]) |granted| if (granted.eql(id)) return true;
        return false;
    }
};

/// Allocated by the sample at its final address before binding; callbacks borrow its host.
pub const Native = struct {
    host: abi.Host = .{},
    loader: abi.NativeLoaderOf(abi.Host) = undefined,
    instances: render3d.Instances = undefined,
    orbiter_owner: ?u64 = null,
    ticks: usize = 0,
    hash: u64 = 0xcbf29ce484222325,
    first: ?Mat4 = null,
    trace: [proof_ticks][3]Mat4 = undefined,
    submitted: bool = false,
    blocked: bool = false,
    pub const proof_ticks = 360;
    pub const orbiter_id = core.ContentId.fromString("orbiter:content");

    pub fn init(self: *Native, engine: *app.Engine, world: *scene.World, content: *render3d.Content, collision: *physics.World) !void {
        self.* = .{};
        self.instances = try .init(engine.gpa, .default);
        self.host = .{ .engine = engine, .world = world, .render3d_content = content, .render3d_instances = &self.instances, .collision3d = collision, .collision3d_allocator = engine.gpa };
        self.host.bind();
        self.loader = .init(engine.gpa, &self.host);
    }

    pub fn load(self: *Native, entries: []const mod.Entry, consent: Consent, diags: *data.Diagnostics) !void {
        // Iteration is resolved order. A consented but unselected package never reaches here.
        for (entries) |entry| {
            if (entry.native == null) continue;
            if (!consent.contains(entry.id)) {
                log.info("native {s}: content loaded; code not consented", .{entry.name});
                continue;
            }
            try self.loader.load(&.{entry}, diags);
        }
        for (self.loader.loaded.items) |item| {
            if (item.id.eql(orbiter_id) and self.host.modId(item.self) != null) self.orbiter_owner = item.self.bits;
        }
    }

    pub fn deinit(self: *Native) void {
        self.loader.deinit(); // shutdown with content, world and host still live
        self.host.unbind(); // also sweeps acquisitions left by a failed or dishonest shutdown
        self.instances.deinit(self.host.render3d_content.?);
    }

    pub fn fillStress(self: *Native) !void {
        while (self.instances.instances.count() < 1024) {
            const i = self.instances.instances.count();
            const position: Vec3 = .init(5 + @as(f32, @floatFromInt(i % 32)), 0, @as(f32, @floatFromInt(i / 32)));
            _ = try self.instances.create(self.host.render3d_content.?, 0, .fromString("plinth:models.plinth"), Mat4.translation(position));
        }
    }

    pub fn canLoadWorld(self: *const Native) bool {
        return self.loader.loaded.items.len == 0;
    }

    pub fn submit(self: *Native, content: *render3d.Content, renderer: *render3d.Renderer) !void {
        const before = renderer.draws.items.len;
        const lights_before = renderer.light_count;
        try self.instances.submit(content, renderer);
        const owner = self.orbiter_owner orelse return;
        var drew = false;
        var lit = false;
        var instances = self.instances.instances.iterator();
        while (instances.next()) |entry| {
            if (entry.value.owner != owner) continue;
            for (renderer.draws.items[before..]) |draw| if (std.meta.eql(draw.world, entry.value.world)) {
                drew = true;
                break;
            };
        }
        var lights = self.instances.lights.iterator();
        while (lights.next()) |entry| {
            if (entry.value.owner != owner) continue;
            for (renderer.lights[lights_before..renderer.light_count]) |light| if (std.meta.eql(light, entry.value.light)) {
                lit = true;
                break;
            };
        }
        self.submitted = self.submitted or (drew and lit);
    }

    pub fn body(self: *Native) ?physics.BodyHandle {
        const owner = self.orbiter_owner orelse return null;
        for (self.host.bodies3d) |owned| {
            if (owned.owner.bits != owner) continue;
            const handle = physics.BodyHandle.fromBits(owned.handle.bits);
            const value = self.host.collision3d.?.body(handle) orelse continue;
            if (value.user == core.ContentId.fromString("orbiter:solid").hash) return handle;
        }
        return null;
    }

    /// Fixed number of actual callback results, never frame time or a native-only backdoor.
    pub fn record(self: *Native) !void {
        const owner = self.orbiter_owner orelse return;
        if (self.ticks >= proof_ticks) return;
        var it = self.instances.instances.iterator();
        const entry = while (it.next()) |entry| {
            if (entry.value.owner == owner) break entry.value;
        } else return error.OrbiterInstanceMissing;
        var lights = self.instances.lights.iterator();
        const lamp = while (lights.next()) |entry_light| {
            if (entry_light.value.owner == owner) break entry_light.value.light;
        } else return error.OrbiterLightMissing;
        const solid = self.host.collision3d.?.body(self.body() orelse return error.OrbiterBodyMissing).?;
        if (solid.kind != .kinematic or entry.override_count != 1) return error.OrbiterStateMismatch;
        const position: Vec3 = .init(entry.world.cols[3][0], entry.world.cols[3][1], entry.world.cols[3][2]);
        if (solid.pose.position.sub(position).length() > 1e-5 or
            lamp.world.cols[3][0] != position.x or lamp.world.cols[3][2] != position.z) return error.OrbiterStateMismatch;
        const body_matrix = Mat4.trs(solid.pose.position, solid.pose.rotation, .one);
        for (entry.world.cols, body_matrix.cols) |visual_col, solid_col| for (visual_col, solid_col) |visual, collision| {
            if (@abs(visual - collision) > 1e-5) return error.OrbiterStateMismatch;
        };
        self.trace[self.ticks] = .{ entry.world, body_matrix, lamp.world };
        for (std.mem.asBytes(&entry.world), std.mem.asBytes(&body_matrix)) |a, b| {
            // Hash visual and collision bits separately; matrices may round differently.
            self.hash = (self.hash ^ a) *% 0x100000001b3;
            self.hash = (self.hash ^ b) *% 0x100000001b3;
        }
        for (std.mem.asBytes(&lamp.world)) |b| self.hash = (self.hash ^ b) *% 0x100000001b3;
        if (self.first == null) self.first = entry.world;
        self.ticks += 1;
        if (self.ticks == proof_ticks) {
            if (std.meta.eql(self.first.?, entry.world)) return error.OrbiterDidNotMove;
            log.info("tour: orbiter poses ({d} ticks, {x:0>16})", .{ self.ticks, self.hash });
        }
    }

    pub fn proveBlocking(self: *Native, walk: *Walk, dt: f32) !void {
        if (self.orbiter_owner == null) return;
        if (!self.submitted or self.ticks != proof_ticks) return error.OrbiterNotDrawn;
        const handle = self.body() orelse return error.OrbiterBodyMissing;
        const solid = walk.world.body(handle).?;
        // Find a clear approach to the *actual* moving body, not through the table or wall.
        const approach = for ([_]Vec3{ .forward, .right, .init(0, 0, 1), .init(-1, 0, 0) }) |local| {
            const direction = solid.pose.rotation.rotate(local);
            const feet = solid.pose.position.sub(direction.scale(1.1)).sub(.init(0, 0.5 - physics.narrow.contact_skin, 0));
            const cast = try walk.world.shapeCast(.{ .capsule = .{ .radius = 0.3, .half_height = 0.6 } }, .{ .position = feet.add(.init(0, 0.95, 0)), .rotation = solid.pose.rotation }, direction.scale(1.4), .{ .mask = 1, .ignore = walk.world.character(walk.character).?.body });
            if (cast != null and cast.?.body.eql(handle)) break .{ .forward = direction, .start = feet };
        } else return error.OrbiterCastFailed;
        const forward = approach.forward;
        const start = approach.start;
        try walk.teleport(start);
        walk.yaw = std.math.atan2(-forward.x, -forward.z);
        walk.pitch = -0.4;
        for (0..120) |_| try walk.step(.{ .direction = .forward }, dt);
        const advance = walk.result.feet.sub(start).dot(forward);
        if (walk.result.stuck or advance < 0.1 or advance > 0.85) return error.OrbiterBlockingFailed;
        self.blocked = true;
        log.info("tour: orbiter pass (submitted instance/light, cast, player blocked after {d:.4}m)", .{advance});
    }
};
