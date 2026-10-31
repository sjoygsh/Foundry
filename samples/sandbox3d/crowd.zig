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
//! **The climber is a walker figure** (`animation-logic.md` §11): it walks in `stride` at the rate
//! its speed asks for, and plays a clip on a link by the rule the court's warden does, put at
//! `link_t` on each tick. It has no controller, so a pose is all it adds, and the pawn is still
//! the crowd's. A game with no rig still has its pawn, drawn as a crate.
//!
//! **A mesh reaches this crowd through `adopt`, at a frame boundary, before any tick** (ADR-0061's
//! decision 4). The tests replay a recorded list of adoptions.

const std = @import("std");
const anim = @import("anim");
const asset = @import("asset");
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
const link_kinds = @typeInfo(nav.LinkKind).@"enum".fields.len;
const idle_clip = anim.clipName("idle");
const stride_clip = anim.clipName("stride");
pub const land = core.ContentId.fromString("sandbox3d:event.land");
/// Seconds into a crossing's clip, and between walking and standing.
const fade_seconds: f32 = 0.15;

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
    /// What the first climber is drawn as, how tall that is, and the clip for each link kind.
    climber_model: core.ContentId,
    climber_set: core.ContentId,
    climber_height: f32,
    link_clips: [link_kinds]u64,

    pub fn read(fields: Fields) !Settings {
        const model = (try fields.idAt(try index(fields, "model"))) orelse return error.InvalidCrowd;
        if (model.isNone()) return error.InvalidCrowd;
        const count = (try fields.intAt(try index(fields, "count"))) orelse return error.InvalidCrowd;
        if (count < 1 or count > max_pawns) return error.InvalidCrowd;
        const climber_model = (try fields.idAt(try index(fields, "climber_model"))) orelse return error.InvalidCrowd;
        const climber_set = (try fields.idAt(try index(fields, "climber_set"))) orelse return error.InvalidCrowd;
        if (climber_model.isNone() or climber_set.isNone()) return error.InvalidCrowd;
        const clips = (try fields.nestedAt(try index(fields, "link_clips"))) orelse return error.InvalidCrowd;
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
            .climber_model = climber_model,
            .climber_set = climber_set,
            .climber_height = try bounded(fields, "climber_height", 0.1, 4),
            .link_clips = .{ try clipNamed(clips, "jump"), try clipNamed(clips, "drop"), try clipNamed(clips, "ladder") },
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

fn clipNamed(fields: Fields, name: []const u8) !u64 {
    const text = (try fields.stringAt(try index(fields, name))) orelse return error.InvalidCrowd;
    return anim.clipName(text);
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

/// The first climber's body, as far as anything has one: a pose. See the module's note.
pub const Figure = struct {
    rig: asset.RigHandle = .none,
    model: render3d.ModelHandle = .none,
    /// Zero while its rig can't play it.
    stride_speed: f32 = 0,
    player: anim.Player = .{},
    link_clip: u64 = 0,
    link_clips: [link_kinds]u64 = @splat(0),
    last: Vec3 = .zero,
    yaw: f32 = 0,
    joint_count: usize = 0,
    scratch: [anim.max_joints]core.math.Transform = undefined,
    pose: [anim.max_joints]core.math.Transform = undefined,
    matrices: [anim.max_joints]Mat4 = undefined,
    // Measurement and tests, never read by a tick.
    played: [link_kinds]u32 = @splat(0),
    landed: u32 = 0,
    /// Ticks a clip was refused, which `bindFigure` is there to prevent.
    refused: u32 = 0,

    /// One tick, after the crowd's. `view` is where the crowd says the pawn now is.
    fn step(self: *Figure, rig: *const anim.Rig, crowd: *const nav.Crowd, view: nav.AgentView, dt: f32) !void {
        const moved = view.position.sub(self.last);
        self.last = view.position;
        const length = @sqrt(moved.x * moved.x + moved.z * moved.z);
        const walking = length > 1e-5;
        if (walking) self.yaw = std.math.atan2(-moved.x, -moved.z);

        const clip = self.crossingClip(crowd, view);
        var out: anim.Step = undefined;
        if (view.state == .on_link and clip != 0) {
            if (!self.player.playing(clip)) {
                try self.player.play(rig.*, clip, .{ .fade = fade_seconds });
                self.played[self.kindOf(crowd, view)] += 1;
            }
            self.link_clip = clip;
            self.player.seek(rig.*, view.link_t, dt, &out);
        } else if (self.link_clip != 0) {
            // The tick it lands: the crowd has already said it is off the link.
            self.link_clip = 0;
            self.player.seek(rig.*, 1, dt, &out);
        } else {
            const speed = if (walking) @min(length / dt / self.stride_speed, anim.max_speed) else 1;
            const wanted = if (walking) stride_clip else idle_clip;
            if (!self.player.playing(wanted)) try self.player.play(rig.*, wanted, .{ .fade = fade_seconds, .phase = .keep, .speed = speed });
            if (walking) try self.player.setSpeed(rig.*, speed);
            self.player.advance(rig.*, dt, &out);
        }
        for (out.fired()) |event| {
            if (event.eql(land)) self.landed += 1;
        }
        const n = rig.skeleton.jointCount();
        const pose: anim.Pose = .{ .local = self.pose[0..n] };
        self.player.evaluate(rig.*, .{ .local = self.scratch[0..n] }, pose);
        anim.skinMatrices(rig.skeleton, pose, self.matrices[0..n]);
        self.joint_count = n;
    }

    fn kindOf(_: *const Figure, crowd: *const nav.Crowd, view: nav.AgentView) usize {
        return @intFromEnum(crowd.mesh.?.links[view.link].kind);
    }

    fn crossingClip(self: *const Figure, crowd: *const nav.Crowd, view: nav.AgentView) u64 {
        const mesh = crowd.mesh orelse return 0;
        if (view.link >= mesh.links.len) return 0;
        return self.link_clips[@intFromEnum(mesh.links[view.link].kind)];
    }
};

pub const CrowdDemo = struct {
    gpa: Allocator,
    settings: ?Settings = null,
    crowd: ?nav.Crowd = null,
    pawns: [max_pawns]Pawn = @splat(.{}),
    model: render3d.ModelHandle = .none,
    figure: Figure = .{},
    /// Null for a crowd of crates.
    rigs: ?*asset.Rigs = null,
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
        if (content) |c| {
            if (!self.model.isNone()) c.releaseModel(self.model);
            if (!self.figure.model.isNone()) c.releaseModel(self.figure.model);
        }
        self.model = .none;
        if (self.rigs) |rigs| if (!self.figure.rig.isNone()) rigs.release(self.figure.rig);
        self.figure.rig = .none;
        self.figure.model = .none;
        self.figure.stride_speed = 0;
        self.figure.joint_count = 0;
    }

    /// After `refresh`, for a game with rigs: makes the first climber a figure. One that its set
    /// can't give what it plays stays a crate, and says so.
    pub fn bindFigure(self: *CrowdDemo, rigs: *asset.Rigs, content: ?*render3d.Content) void {
        const s = self.settings orelse return;
        self.rigs = rigs;
        if (s.climbers == 0) return;
        const f = &self.figure;
        f.* = .{};
        f.rig = rigs.acquire(s.climber_set) catch |err| {
            log.warn("the climber stays a crate: {f} did not build ({t})", .{ s.climber_set, err });
            return;
        };
        const rig = rigs.get(f.rig).?;
        if (rig.find(idle_clip) == null or rig.motionSpeed(stride_clip) <= 0) {
            log.warn("the climber stays a crate: {f} has no 'idle' or no moving 'stride'", .{s.climber_set});
            return;
        }
        for (s.link_clips, &f.link_clips) |name, *usable| {
            usable.* = if (rig.find(name) != null) name else 0;
        }
        f.player.play(rig.*, idle_clip, .{}) catch unreachable;
        f.stride_speed = rig.motionSpeed(stride_clip);
        if (self.crowd) |*c| if (c.agent(self.pawns[0].handle)) |v| {
            f.last = v.position;
        };
        if (content) |c| f.model = c.acquireModel(s.climber_model) catch |err| blk: {
            log.warn("the climber is not drawn: {f} ({t})", .{ s.climber_model, err });
            break :blk .none;
        };
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
        if (self.figure.stride_speed > 0) {
            if (self.rigs.?.get(self.figure.rig)) |rig| if (crowd.agent(self.pawns[0].handle)) |view| {
                self.figure.step(rig, crowd, view, dt) catch |err| {
                    self.figure.refused += 1;
                    log.warn("the climber stopped animating ({t})", .{err});
                };
            };
        }
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
            for (self.pawns[0..s.count], 0..) |*p, i| {
                const v = crowd.agent(p.handle) orelse continue;
                if (i == 0 and self.figure.joint_count != 0 and !self.figure.model.isNone()) {
                    const f = &self.figure;
                    const size = s.height / s.climber_height;
                    try content.drawModel(.{ .model = f.model, .world = Mat4.trs(v.position, Quat.fromAxisAngle(.up, f.yaw), .init(size, size, size)), .skin = f.matrices[0..f.joint_count] });
                    continue;
                }
                try content.drawModel(.{ .model = self.model, .world = Mat4.trs(v.position.add(.init(0, s.height * 0.5, 0)), Quat.identity, scale) });
            }
        }
        if (crate.isNone()) return;
        const h = s.crate_half;
        try content.drawModel(.{ .model = crate, .world = Mat4.trs(self.cratePosition().?, Quat.identity, .init(h.x / s.model_half, h.y / s.model_half, h.z / s.model_half)) });
    }
};
