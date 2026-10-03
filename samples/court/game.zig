//! Central simulation state machine for samples/court:
//! phases, beacons, Use interaction, kinematic gate, patrolling warden,
//! exit and pit detection, restart, and deterministic state hashing.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const physics = @import("physics3d");
const render3d = @import("render3d");
const walk_mod = @import("walk.zig");
const walk_settings = @import("walk_settings.zig");
const beacon_mod = @import("beacon.zig");
const gate_mod = @import("gate.zig");
const warden_mod = @import("warden.zig");

const Vec3 = core.math.Vec3;
const Intent = walk_mod.Intent;
const log = core.log.scoped(.court);

pub const Phase = enum(u8) {
    title = 0,
    playing = 1,
    paused = 2,
    won = 3,
    caught = 4,
    fell = 5,
};

pub const Game = struct {
    gpa: std.mem.Allocator,
    phase: Phase = .playing,
    walk: walk_mod.Walk,
    rules: ?walk_settings.Settings = null,
    beacons: [max_beacons]beacon_mod.Beacon = undefined,
    beacon_count: usize = 0,
    gate: ?gate_mod.Gate = null,
    warden: ?warden_mod.Warden = null,
    tick: u64 = 0,

    pub const max_beacons = 8;

    pub fn init(gpa: std.mem.Allocator) Game {
        return .{
            .gpa = gpa,
            .walk = walk_mod.Walk.init(gpa),
        };
    }

    pub fn deinit(self: *Game, assets: *asset.Registry, content: ?*render3d.Content) void {
        self.clearBeacons(content);
        if (self.gate) |*g| g.deinit(self.gpa, &self.walk.world, content);
        self.gate = null;
        if (self.warden) |*w| w.deinit(self.gpa, &self.walk.world, content);
        self.warden = null;
        self.walk.deinit(assets);
    }

    fn clearBeacons(self: *Game, content: ?*render3d.Content) void {
        for (self.beacons[0..self.beacon_count]) |*b| {
            b.deinit(self.gpa, &self.walk.world, content);
        }
        self.beacon_count = 0;
    }

    pub fn refresh(self: *Game, store: *const data.Store, assets: *asset.Registry, content: ?*render3d.Content, dt: f32) void {
        self.walk.refresh(store, assets, dt);
        self.rules = self.walk.settings;
        self.refreshBeacons(store, content);
        self.refreshGate(store, content);
        self.refreshWarden(store, content, dt);
    }

    fn refreshBeacons(self: *Game, store: *const data.Store, content: ?*render3d.Content) void {
        self.clearBeacons(content);
        var it = store.iterate(data.SchemaId.fromStringUnchecked("court:beacon"));

        var found: [max_beacons]data.store.Record = undefined;
        var count: usize = 0;
        while (it.next()) |rec| {
            if (count < max_beacons) {
                found[count] = rec;
                count += 1;
            }
        }

        // Sort by content ID hash ascending (Invariant 9).
        var i: usize = 0;
        while (i < count) : (i += 1) {
            var j: usize = i + 1;
            while (j < count) : (j += 1) {
                if (found[j].id.hash < found[i].id.hash) {
                    const tmp = found[i];
                    found[i] = found[j];
                    found[j] = tmp;
                }
            }
        }

        for (found[0..count], 0..) |rec, idx| {
            const settings = beacon_mod.BeaconSettings.read(rec.fields) catch |err| {
                log.warn("beacon {f} omitted: {t}", .{ rec.id, err });
                continue;
            };

            const model_handle = if (content) |c| (c.acquireModel(settings.model) catch render3d.ModelHandle.none) else render3d.ModelHandle.none;

            // Static box collider for Use raycast: centered at y + 0.5.
            const box_shape = physics.Shape{ .box = .{ .half_extents = .init(0.4, 0.5, 0.4) } };
            const body = self.walk.world.addBody(self.gpa, .{
                .shape = box_shape,
                .pose = .{ .position = settings.position.add(.init(0, 0.5, 0)), .rotation = .identity },
                .kind = .static,
                .layer = beacon_mod.beacon_layer,
                .mask = ~@as(u32, 0),
                .user = @intCast(idx),
            }) catch |err| {
                log.warn("beacon body {f} omitted: {t}", .{ rec.id, err });
                continue;
            };

            self.beacons[self.beacon_count] = .{
                .id = rec.id,
                .settings = settings,
                .model = model_handle,
                .body = body,
                .lit = false,
            };
            self.beacon_count += 1;
        }
    }

    fn refreshGate(self: *Game, store: *const data.Store, content: ?*render3d.Content) void {
        if (self.gate) |*g| g.deinit(self.gpa, &self.walk.world, content);
        self.gate = null;

        const record = store.lookup(core.ContentId.fromString("court:gate.main")) orelse {
            log.warn("missing 'court:gate.main'; court cannot be completed", .{});
            return;
        };
        const settings = gate_mod.GateSettings.read(record.fields) catch |err| {
            log.warn("invalid 'court:gate.main' ({t}); court cannot be completed", .{err});
            return;
        };

        const model_handle = if (content) |c| (c.acquireModel(settings.model) catch render3d.ModelHandle.none) else render3d.ModelHandle.none;
        const gate_box = physics.Shape{ .box = .{ .half_extents = .init(1.0, 1.25, 0.08) } };
        const body = self.walk.world.addBody(self.gpa, .{
            .shape = gate_box,
            .pose = .{ .position = settings.closed, .rotation = .identity },
            .kind = .kinematic,
            .layer = 1,
            .mask = ~@as(u32, 0),
            .user = record.id.hash,
        }) catch |err| {
            log.warn("gate body omitted ({t}); court cannot be completed", .{err});
            return;
        };

        self.gate = .{
            .id = record.id,
            .settings = settings,
            .model = model_handle,
            .body = body,
            .current_pos = settings.closed,
            .progress = 0,
            .opening = false,
        };
    }

    fn refreshWarden(self: *Game, store: *const data.Store, content: ?*render3d.Content, dt: f32) void {
        if (self.warden) |*w| w.deinit(self.gpa, &self.walk.world, content);
        self.warden = null;

        const record = store.lookup(core.ContentId.fromString("court:warden.main")) orelse {
            log.warn("missing 'court:warden.main'; patrol disabled", .{});
            return;
        };
        const settings = warden_mod.WardenSettings.read(record.fields) catch |err| {
            log.warn("invalid 'court:warden.main' ({t}); patrol disabled", .{err});
            return;
        };

        const model_handle = if (content) |c| (c.acquireModel(settings.model) catch render3d.ModelHandle.none) else render3d.ModelHandle.none;
        const character = self.walk.world.addCharacter(self.gpa, .{
            .radius = 0.22,
            .height = 1.7,
            .max_slope = std.math.pi / 4.0,
            .step_height = 0.35,
            .snap_distance = 0.3,
            .max_move = 1,
            .layer = 2,
            .mask = 1,
        }, settings.waypoints[0], 0) catch |err| {
            log.warn("warden character omitted ({t}); patrol disabled", .{err});
            return;
        };

        var warden: warden_mod.Warden = .{
            .settings = settings,
            .model = model_handle,
            .character = character,
            .feet = settings.waypoints[0],
            .yaw = 0,
            .velocity = 0,
            .tick = 0,
            .waypoint = 1,
            .wait_ticks = 60,
            .weight = 0,
        };

        if (content) |c| {
            warden.evaluate(c, dt) catch {};
        }

        self.warden = warden;
    }

    pub fn allBeaconsLit(self: *const Game) bool {
        if (self.beacon_count == 0) return false;
        for (self.beacons[0..self.beacon_count]) |b| {
            if (!b.lit) return false;
        }
        return true;
    }

    pub fn litCount(self: *const Game) usize {
        var count: usize = 0;
        for (self.beacons[0..self.beacon_count]) |b| {
            if (b.lit) count += 1;
        }
        return count;
    }

    pub fn isBeaconLit(self: *const Game, id: core.ContentId) bool {
        for (self.beacons[0..self.beacon_count]) |b| {
            if (b.id.eql(id)) return b.lit;
        }
        return false;
    }

    pub fn restart(self: *Game) !void {
        const rules = self.rules orelse return;
        self.phase = .playing;
        try self.walk.teleport(rules.spawn);
        self.walk.yaw = rules.spawn_yaw;
        self.walk.pitch = 0;
        self.walk.velocity = 0;
        for (self.beacons[0..self.beacon_count]) |*b| {
            b.lit = false;
        }
        if (self.gate) |*g| {
            try g.reset(self.gpa, &self.walk.world);
        }
        if (self.warden) |*w| {
            try w.reset(self.gpa, &self.walk.world);
        }
        self.tick = 0;
    }

    pub fn step(self: *Game, intent: Intent, dt: f32) !void {
        if (intent.restart) {
            try self.restart();
            return;
        }

        const rules = self.rules orelse return;

        if (self.phase != .playing) return;

        // 1. Move player.
        try self.walk.step(intent, dt);

        // 2. Handle Use raycast.
        if (intent.use) {
            const eye = self.walk.eye();
            const forward = self.walk.rotation().rotate(.forward);
            const hit_opt = self.walk.world.raycast(eye, forward, rules.reach, .{ .mask = beacon_mod.beacon_layer }) catch null;
            if (hit_opt) |hit| {
                const idx = hit.user;
                if (idx < self.beacon_count) {
                    if (!self.beacons[idx].lit) {
                        self.beacons[idx].lit = true;
                        if (self.allBeaconsLit() and self.gate != null) {
                            self.gate.?.opening = true;
                        }
                    }
                }
            }
        }

        // 3. Step gate.
        if (self.gate) |*g| {
            try g.step(self.gpa, &self.walk.world, dt);
        }

        // 4. Step warden.
        if (self.warden) |*w| {
            try w.step(self.gpa, &self.walk.world, dt);
            const delta = w.feet.sub(self.walk.result.feet);
            if (delta.length() < rules.catch_distance) {
                self.phase = .caught;
            }
        }

        // 5. Check pit fall.
        if (self.walk.result.feet.y < rules.pit_height) {
            self.phase = .fell;
        }

        // 6. Check exit completion.
        if (self.allBeaconsLit() and (self.gate == null or self.gate.?.progress >= 1.0)) {
            const feet = self.walk.result.feet;
            if (feet.x >= rules.exit_min.x and feet.x <= rules.exit_max.x and
                feet.y >= rules.exit_min.y and feet.y <= rules.exit_max.y and
                feet.z >= rules.exit_min.z and feet.z <= rules.exit_max.z)
            {
                self.phase = .won;
            }
        }

        self.tick += 1;
    }

    pub fn hashTick(self: *const Game) u64 {
        var h: u64 = 0xcbf29ce484222325;
        const phase_val: u8 = @intFromEnum(self.phase);
        h = hashBytes(h, std.mem.asBytes(&phase_val));
        h = hashBytes(h, std.mem.asBytes(&self.walk.result.feet.x));
        h = hashBytes(h, std.mem.asBytes(&self.walk.result.feet.y));
        h = hashBytes(h, std.mem.asBytes(&self.walk.result.feet.z));
        h = hashBytes(h, std.mem.asBytes(&self.walk.yaw));
        h = hashBytes(h, std.mem.asBytes(&self.walk.pitch));
        h = hashBytes(h, std.mem.asBytes(&self.walk.velocity));
        for (self.beacons[0..self.beacon_count]) |b| {
            const lit_byte: u8 = if (b.lit) 1 else 0;
            h = hashBytes(h, std.mem.asBytes(&lit_byte));
        }
        if (self.gate) |g| {
            h = hashBytes(h, std.mem.asBytes(&g.progress));
            h = hashBytes(h, std.mem.asBytes(&g.current_pos.x));
            h = hashBytes(h, std.mem.asBytes(&g.current_pos.y));
            h = hashBytes(h, std.mem.asBytes(&g.current_pos.z));
        }
        if (self.warden) |w| {
            h = hashBytes(h, std.mem.asBytes(&w.feet.x));
            h = hashBytes(h, std.mem.asBytes(&w.feet.y));
            h = hashBytes(h, std.mem.asBytes(&w.feet.z));
            h = hashBytes(h, std.mem.asBytes(&w.yaw));
            const wp: u32 = @intCast(w.waypoint);
            h = hashBytes(h, std.mem.asBytes(&wp));
            h = hashBytes(h, std.mem.asBytes(&w.wait_ticks));
            h = hashBytes(h, std.mem.asBytes(&w.weight));
            h = hashBytes(h, std.mem.asBytes(&w.tick));
        }
        return h;
    }
};

fn hashBytes(h_in: u64, bytes: []const u8) u64 {
    var h = h_in;
    for (bytes) |b| {
        h = (h ^ b) *% 0x100000001b3;
    }
    return h;
}
