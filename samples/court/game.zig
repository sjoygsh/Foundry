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
    /// Level geometry and the gate, which block characters.
    pub const level_layer: u32 = 1;
    pub const warden_layer: u32 = 1 << 2;

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

        // Hash order wherever order matters (I9). Above the bound, the lowest hashes are
        // kept, so which beacons survive never depends on the store's iteration order.
        var found: [max_beacons]data.store.Record = undefined;
        var count: usize = 0;
        var dropped: usize = 0;
        while (it.next()) |rec| {
            var at: usize = count;
            while (at > 0 and rec.id.hash < found[at - 1].id.hash) at -= 1;
            if (at == max_beacons) {
                dropped += 1;
                continue;
            }
            if (count == max_beacons) dropped += 1 else count += 1;
            var move = count - 1;
            while (move > at) : (move -= 1) found[move] = found[move - 1];
            found[at] = rec;
        }
        if (dropped != 0) log.warn("{d} beacon(s) above the bound of {d} are ignored", .{ dropped, max_beacons });

        for (found[0..count]) |rec| {
            const settings = beacon_mod.BeaconSettings.read(rec.fields) catch |err| {
                log.warn("beacon {f} omitted: {t}", .{ rec.id, err });
                continue;
            };
            if (!isModel(store, settings.model)) {
                log.warn("beacon {f} omitted: its model is not a 'foundry:model'", .{rec.id});
                continue;
            }
            // `user` is the beacon's slot here, not its place among the records: a refused
            // record ahead of it must not make Use light a neighbour.
            const slot = self.beacon_count;
            var beacon: beacon_mod.Beacon = .{ .id = rec.id, .settings = settings };
            beacon.body = self.walk.world.addBody(self.gpa, .{
                .shape = .{ .box = .{ .half_extents = settings.use_half } },
                .pose = .{ .position = beacon.useCentre(), .rotation = .identity },
                .kind = .static,
                .layer = beacon_mod.beacon_layer,
                .user = @intCast(slot),
            }) catch |err| {
                log.warn("beacon {f} omitted: {t}", .{ rec.id, err });
                continue;
            };
            beacon.model = acquire(content, settings.model, rec.id);
            self.beacons[slot] = beacon;
            self.beacon_count += 1;
        }
    }

    fn refreshGate(self: *Game, store: *const data.Store, content: ?*render3d.Content) void {
        if (self.gate) |*g| g.deinit(self.gpa, &self.walk.world, content);
        self.gate = null;

        const id = core.ContentId.fromString("court:gate.main");
        const record = store.lookup(id) orelse {
            log.warn("missing 'court:gate.main'; court cannot be completed", .{});
            return;
        };
        if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked("court:gate"))) {
            log.warn("'court:gate.main' is not a 'court:gate'; court cannot be completed", .{});
            return;
        }
        const settings = gate_mod.GateSettings.read(record.fields) catch |err| {
            log.warn("invalid 'court:gate.main' ({t}); court cannot be completed", .{err});
            return;
        };
        if (!isModel(store, settings.model)) {
            log.warn("'court:gate.main' names a model that is not a 'foundry:model'; court cannot be completed", .{});
            return;
        }
        const body = self.walk.world.addBody(self.gpa, .{
            .shape = .{ .box = .{ .half_extents = settings.half_extents } },
            .pose = .{ .position = settings.closed, .rotation = .identity },
            .kind = .kinematic,
            .user = record.id.hash,
        }) catch |err| {
            log.warn("gate body omitted ({t}); court cannot be completed", .{err});
            return;
        };

        self.gate = .{
            .id = record.id,
            .settings = settings,
            .model = acquire(content, settings.model, id),
            .body = body,
            .current_pos = settings.closed,
        };
    }

    fn refreshWarden(self: *Game, store: *const data.Store, content: ?*render3d.Content, dt: f32) void {
        if (self.warden) |*w| w.deinit(self.gpa, &self.walk.world, content);
        self.warden = null;
        const rules = self.rules orelse return;

        const id = core.ContentId.fromString("court:warden.main");
        const record = store.lookup(id) orelse {
            log.warn("missing 'court:warden.main'; patrol disabled", .{});
            return;
        };
        if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked("court:warden"))) {
            log.warn("'court:warden.main' is not a 'court:warden'; patrol disabled", .{});
            return;
        }
        const settings = warden_mod.WardenSettings.read(record.fields) catch |err| {
            log.warn("invalid 'court:warden.main' ({t}); patrol disabled", .{err});
            return;
        };
        if (!isModel(store, settings.model)) {
            log.warn("'court:warden.main' names a model that is not a 'foundry:model'; patrol disabled", .{});
            return;
        }
        // The player's slope, step and snap, with the warden's own capsule. It collides
        // with the level alone, so a beacon or the player never blocks its patrol.
        var config = rules.character;
        config.radius = settings.radius;
        config.height = settings.height;
        config.step_height = @min(config.step_height, settings.height - 2 * settings.radius);
        config.max_move = warden_mod.max_move;
        config.layer = warden_layer;
        config.mask = level_layer;
        const character = self.walk.world.addCharacter(self.gpa, config, settings.waypoints[0], 0) catch |err| {
            log.warn("warden character omitted ({t}); patrol disabled", .{err});
            return;
        };

        const pause_ticks: u32 = @intFromFloat(@round(settings.pause / dt));
        self.warden = .{
            .settings = settings,
            .model = acquire(content, settings.model, id),
            .character = character,
            .feet = settings.waypoints[0],
            .wait_ticks = pause_ticks,
            .pause_ticks = pause_ticks,
        };
    }

    fn isModel(store: *const data.Store, id: core.ContentId) bool {
        const record = store.lookup(id) orelse return false;
        return record.schema.id.eql(asset.schemas.model.id);
    }

    /// A model that fails to load leaves its owner in the game, undrawn, and says so.
    fn acquire(content: ?*render3d.Content, model: core.ContentId, owner: core.ContentId) render3d.ModelHandle {
        const c = content orelse return .none;
        return c.acquireModel(model) catch |err| {
            log.warn("{f}: model {f} is not drawn ({t})", .{ owner, model, err });
            return .none;
        };
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

        // 2. Use: one ray from the eye along the look, against the beacons' layer only.
        if (intent.use) {
            const forward = self.walk.rotation().rotate(.forward);
            const hit_opt = self.walk.world.raycast(self.walk.eye(), forward, rules.reach, .{ .mask = beacon_mod.beacon_layer }) catch |err| blk: {
                // Validated rules and a unit look direction leave nothing to refuse.
                log.warn("use ray refused ({t})", .{err});
                break :blk null;
            };
            if (hit_opt) |hit| if (hit.user < self.beacon_count) {
                const beacon = &self.beacons[@intCast(hit.user)];
                if (!beacon.lit) {
                    beacon.lit = true;
                    if (self.allBeaconsLit()) if (self.gate) |*g| {
                        g.opening = true;
                    };
                }
            };
        }

        // 3. Step gate.
        if (self.gate) |*g| try g.step(self.gpa, &self.walk.world, dt);

        // 4. Step warden.
        var caught = false;
        if (self.warden) |*w| {
            try w.step(self.gpa, &self.walk.world, rules.gravity, dt);
            caught = w.feet.sub(self.walk.result.feet).length() < rules.catch_distance;
        }

        // 5. One ending a tick, in a fixed order: the exit, then the pit, then the warden.
        const feet = self.walk.result.feet;
        const gate_open = if (self.gate) |g| g.progress >= 1.0 else false;
        const in_exit = feet.x >= rules.exit_min.x and feet.x <= rules.exit_max.x and
            feet.y >= rules.exit_min.y and feet.y <= rules.exit_max.y and
            feet.z >= rules.exit_min.z and feet.z <= rules.exit_max.z;
        if (self.allBeaconsLit() and gate_open and in_exit) {
            self.phase = .won;
        } else if (feet.y < rules.pit_height) {
            self.phase = .fell;
        } else if (caught) {
            self.phase = .caught;
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
        if (self.gate) |*g| {
            h = hashBytes(h, std.mem.asBytes(&g.progress));
            h = hashBytes(h, std.mem.asBytes(&g.current_pos.x));
            h = hashBytes(h, std.mem.asBytes(&g.current_pos.y));
            h = hashBytes(h, std.mem.asBytes(&g.current_pos.z));
        }
        if (self.warden) |*w| {
            h = hashBytes(h, std.mem.asBytes(&w.feet.x));
            h = hashBytes(h, std.mem.asBytes(&w.feet.y));
            h = hashBytes(h, std.mem.asBytes(&w.feet.z));
            h = hashBytes(h, std.mem.asBytes(&w.yaw));
            const wp: u32 = @intCast(w.waypoint);
            h = hashBytes(h, std.mem.asBytes(&wp));
            h = hashBytes(h, std.mem.asBytes(&w.velocity));
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
