//! M33's crowd (`docs/design/agents.md` §11.1): sixteen pawns walking one way round the room on
//! the navigation mesh, keeping apart, a climber going by the platform, the drop and the ladder,
//! and a crate a key slides into their way.
//!
//! **Pawns have no bodies,** so `Crowd.step`'s wish is the move: nothing calls `place`, and a pawn
//! is drawn where the crowd says. The court shows the other way round, with a controller.
//!
//! **The policy `nav` leaves to a game** (`agents.md` §15): pawns circulate one way, because a
//! gap one agent wide jams two directions; few climb, because the platform's mesh is narrower
//! than two pawns and walls then press them together; and a pawn that says `blocked` gives up on
//! that corner and takes the next.
//!
//! **A mesh reaches this crowd through `adopt`, at a frame boundary, before any tick** (ADR-0061's
//! decision 4). The tests replay a recorded list of adoptions.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const nav = @import("nav");
const physics = @import("physics3d");
const render3d = @import("render3d");

const Allocator = std.mem.Allocator;
const Fields = data.fpk.Fields;
const Mat4 = core.math.Mat4;
const Quat = core.math.Quat;
const Vec3 = core.math.Vec3;
const log = core.log.scoped(.sandbox3d);

pub const record_id = core.ContentId.fromString("sandbox3d:crowd.main");
pub const max_pawns = 32;
pub const max_corners = 8;

pub const Settings = struct {
    model: core.ContentId,
    count: u32,
    radius: f32,
    height: f32,
    speed: f32,
    acceleration: f32,
    /// The way round the floor, which every pawn but the climbers takes.
    corners: [max_corners]Vec3 = @splat(.zero),
    corner_count: usize = 0,
    /// The first `climbers` pawns' way, over the platform and by the links.
    climbers: u32,
    climb: [max_corners]Vec3 = @splat(.zero),
    climb_count: usize = 0,
    /// The half-size of the box a pawn is drawn as, and of the crate model, metres.
    model_half: f32,
    /// Where the pawns start: rows of four from here, in +X and then +Z.
    spawn: Vec3,
    spawn_spacing: f32,
    crate_half: Vec3,
    crate_from: Vec3,
    crate_to: Vec3,
    crate_seconds: f32,

    pub fn read(fields: Fields) !Settings {
        const model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidCrowd;
        if (model.isNone()) return error.InvalidCrowd;
        const count = (try fields.intAt(try index(fields, "count"))) orelse return error.InvalidCrowd;
        if (count < 1 or count > max_pawns) return error.InvalidCrowd;
        var out: Settings = .{
            .model = model,
            .count = @intCast(count),
            .radius = try bounded(fields, "radius", 0.05, 1),
            .height = try bounded(fields, "height", 0.1, 4),
            .speed = try bounded(fields, "speed", 0.1, 10),
            .acceleration = try bounded(fields, "acceleration", 0.1, 100),
            .climbers = @intCast(@min((try fields.intAt(try index(fields, "climbers"))) orelse return error.InvalidCrowd, max_pawns)),
            .model_half = try bounded(fields, "model_half", 0.01, 10),
            .spawn = try point(fields, "spawn"),
            .spawn_spacing = try bounded(fields, "spawn_spacing", 0.1, 10),
            .crate_half = try point(fields, "crate_half"),
            .crate_from = try point(fields, "crate_from"),
            .crate_to = try point(fields, "crate_to"),
            .crate_seconds = try bounded(fields, "crate_seconds", 0.05, 60),
        };
        if (out.crate_half.x <= 0 or out.crate_half.y <= 0 or out.crate_half.z <= 0) return error.InvalidCrowd;
        out.corner_count = try route(fields, "corners", &out.corners);
        out.climb_count = try route(fields, "climb", &out.climb);
        return out;
    }

    fn route(fields: Fields, name: []const u8, out: *[max_corners]Vec3) !usize {
        const list = (try fields.listAt(try index(fields, name))) orelse return error.InvalidCrowd;
        if (list.len < 2 or list.len > max_corners) return error.InvalidCrowd;
        for (0..list.len) |i| {
            const p = (try list.nestedAt(@intCast(i))) orelse return error.InvalidCrowd;
            out[i] = .init(try number(p, "x"), try number(p, "y"), try number(p, "z"));
        }
        return list.len;
    }
};

fn index(fields: Fields, name: []const u8) !u32 {
    for (fields.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    return error.InvalidCrowd;
}

fn number(fields: Fields, name: []const u8) !f32 {
    const v: f32 = @floatCast((try fields.floatAt(try index(fields, name))) orelse return error.InvalidCrowd);
    if (!std.math.isFinite(v)) return error.InvalidCrowd;
    return v;
}

fn bounded(fields: Fields, name: []const u8, lo: f32, hi: f32) !f32 {
    const v = try number(fields, name);
    if (v < lo or v > hi) return error.InvalidCrowd;
    return v;
}

fn point(fields: Fields, name: []const u8) !Vec3 {
    const p = (try fields.nestedAt(try index(fields, name))) orelse return error.InvalidCrowd;
    const v: Vec3 = .init(try number(p, "x"), try number(p, "y"), try number(p, "z"));
    if (!physics.shape.positionValid(v)) return error.InvalidCrowd;
    return v;
}

pub const Pawn = struct {
    handle: nav.AgentHandle = .none,
    /// The corner it is heading for.
    corner: u32 = 0,
    climber: bool = false,
    /// Spreads pawns round a corner, so that sixteen do not want one point.
    place: Vec3 = .zero,
};

pub const CrowdDemo = struct {
    gpa: Allocator,
    settings: ?Settings = null,
    crowd: ?nav.Crowd = null,
    pawns: [max_pawns]Pawn = @splat(.{}),
    model: render3d.ModelHandle = .none,
    /// How far along its slide the crate is, 0 to 1, and which way it is going.
    crate_at: f32 = 0,
    crate_target: f32 = 0,
    // Measurement and tests, never read by a tick.
    corners_reached: u32 = 0,
    gave_up: u32 = 0,
    crossed: [3]u32 = @splat(0),
    was_crossing: [max_pawns]bool = @splat(false),

    pub fn init(gpa: Allocator) CrowdDemo {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *CrowdDemo, content: ?*render3d.Content) void {
        if (self.crowd) |*c| c.deinit();
        self.crowd = null;
        if (content) |c| if (!self.model.isNone()) c.releaseModel(self.model);
        self.model = .none;
    }

    /// At each content refresh: the record, the model, and the pawns back at their starts. Any
    /// mesh the crowd held is gone, so a later `adopt` seats them.
    pub fn refresh(self: *CrowdDemo, store: *const data.Store, content: ?*render3d.Content) void {
        self.deinit(content);
        self.settings = null;
        const record = store.lookup(record_id) orelse {
            log.warn("{f} is missing; no crowd", .{record_id});
            return;
        };
        const settings = Settings.read(record.fields) catch |err| {
            log.warn("{f} is refused ({t}); no crowd", .{ record_id, err });
            return;
        };
        var crowd = nav.Crowd.init(self.gpa, .{ .max_agents = max_pawns, .blocked_ticks = 150 }) catch |err| {
            log.warn("no crowd ({t})", .{err});
            return;
        };
        for (self.pawns[0..settings.count], 0..) |*p, i| {
            const turn = core.math.trig.sinCosTurns(@as(f64, @floatFromInt(i % 8)) / 8);
            p.place = .init(@as(f32, @floatCast(turn[1])) * 0.3, 0, @as(f32, @floatCast(turn[0])) * 0.3);
            p.climber = i < settings.climbers;
            // Climbers start well apart along their way: the pocket holds one at a time.
            p.corner = if (p.climber) @intCast(i * 3 % settings.climb_count) else 0;
            if (p.climber) p.place = .zero;
            const column: f32 = @floatFromInt(i % 4);
            const row: f32 = @floatFromInt(i / 4);
            const start = settings.spawn.add(.init(column * settings.spawn_spacing, 0, row * settings.spawn_spacing));
            p.handle = crowd.add(self.params(&settings), start) catch |err| {
                log.warn("pawn {d} omitted ({t})", .{ i, err });
                continue;
            };
            self.next(&crowd, &settings, p);
        }
        self.crowd = crowd;
        self.settings = settings;
        self.crate_at = 0;
        self.crate_target = 0;
        self.was_crossing = @splat(false);
        if (content) |c| self.model = c.acquireModel(settings.model) catch |err| blk: {
            log.warn("the crowd is not drawn: {f} ({t})", .{ settings.model, err });
            break :blk .none;
        };
    }

    fn params(_: *const CrowdDemo, s: *const Settings) nav.AgentParams {
        return .{ .radius = s.radius, .height = s.height, .speed = s.speed, .acceleration = s.acceleration, .arrival_radius = 0.3 };
    }

    fn next(_: *CrowdDemo, crowd: *nav.Crowd, s: *const Settings, p: *Pawn) void {
        const way = if (p.climber) s.climb[0..s.climb_count] else s.corners[0..s.corner_count];
        p.corner = (p.corner + 1) % @as(u32, @intCast(way.len));
        _ = crowd.setTarget(p.handle, way[p.corner].add(p.place));
    }

    /// A rebuilt mesh, at a frame boundary, before the frame's ticks.
    pub fn adopt(self: *CrowdDemo, mesh: *const nav.Mesh) void {
        if (self.crowd) |*c| c.setMesh(mesh);
    }

    /// Starts the crate sliding to its other end.
    pub fn moveCrate(self: *CrowdDemo) void {
        self.crate_target = 1 - self.crate_target;
    }

    pub fn cratePosition(self: *const CrowdDemo) ?Vec3 {
        const s = self.settings orelse return null;
        return s.crate_from.lerp(s.crate_to, self.crate_at);
    }

    /// One fixed tick. True when the crate has come to rest, so the mesh is out of date. Not while
    /// it slides: a build here takes less than a frame, so every tick would be a rebuild, and
    /// every rebuild sends all sixteen pawns back to search.
    pub fn step(self: *CrowdDemo, dt: f32) bool {
        const s = &(self.settings orelse return false);
        const crowd = &(self.crowd orelse return false);
        for (self.pawns[0..s.count], 0..) |*p, i| {
            const v = crowd.agent(p.handle) orelse continue;
            const crossing = v.state == .on_link;
            if (crossing and !self.was_crossing[i]) {
                if (crowd.mesh) |m| if (v.link < m.links.len) {
                    self.crossed[@intFromEnum(m.links[v.link].kind)] += 1;
                };
            }
            self.was_crossing[i] = crossing;
            switch (v.state) {
                .arrived => {
                    self.corners_reached += 1;
                    self.next(crowd, s, p);
                },
                .blocked => {
                    self.gave_up += 1;
                    self.next(crowd, s, p);
                },
                else => {},
            }
        }
        crowd.step(dt);
        if (self.crate_at == self.crate_target) return false;
        const by = dt / s.crate_seconds;
        self.crate_at = if (self.crate_target > self.crate_at) @min(self.crate_target, self.crate_at + by) else @max(self.crate_target, self.crate_at - by);
        return self.crate_at == self.crate_target;
    }

    pub fn draw(self: *const CrowdDemo, content: *render3d.Content, crate: render3d.ModelHandle) !void {
        const s = &(self.settings orelse return);
        const crowd = &(self.crowd orelse return);
        if (!self.model.isNone()) {
            const scale: Vec3 = .init(s.radius / s.model_half, s.height * 0.5 / s.model_half, s.radius / s.model_half);
            for (self.pawns[0..s.count]) |*p| {
                const v = crowd.agent(p.handle) orelse continue;
                try content.drawModel(.{ .model = self.model, .world = Mat4.trs(v.position.add(.init(0, s.height * 0.5, 0)), Quat.identity, scale) });
            }
        }
        if (crate.isNone()) return;
        const h = s.crate_half;
        try content.drawModel(.{ .model = crate, .world = Mat4.trs(self.cratePosition().?, Quat.identity, .init(h.x / s.model_half, h.y / s.model_half, h.z / s.model_half)) });
    }
};
