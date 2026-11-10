//! M38's stage in the yard (`docs/design/collision-scale.md` §11), after M37's six, which keep
//! their own pin. Like `CornerTour`, it is a teleport and a yard set back to its start, then
//! ordinary ticks: the movers first, then `Walk.step`, the path real input takes.
//!
//! The player starts in the middle lane among the stones, walks along it, is turned aside by the
//! mover circling there, walks up the boulder's ramp at the lane's end, and stands on it. Every
//! tick, nothing the player's capsule overlaps is a stone or a mover. At the end it stands on the
//! ramp, whose normal is 20° from up, and the world holds the yard's bodies and its one baked mesh.
const std = @import("std");
const core = @import("core");
const physics = @import("physics3d");
const walk_mod = @import("walk.zig");
const yard_mod = @import("yard.zig");
const Yard = yard_mod.Yard;
const Vec3 = core.math.Vec3;
const log = core.log.scoped(.sandbox3d);

pub const YardTour = struct {
    stage: usize = 0,
    tick: usize = 0,
    failed: ?[]const u8 = null,
    hash: u64 = 0xcbf29ce484222325,
    trace: [max_ticks]Vec3 = undefined,
    len: usize = 0,
    emit: bool = true,
    /// How far from the lane's middle the player was turned, and whether a mover pushed it.
    aside: f32 = 0,
    pushed: bool = false,
    /// Whether one tick of the walk tested both a closed-form pair and a GJK pair, and the
    /// counters as they stood before it.
    both: bool = false,
    closed_before: u32 = 0,
    gjk_before: u32 = 0,
    standing: usize = 0,
    /// What the end found, for the log.
    degrees: f32 = 0,
    bodies: u32 = 0,
    baked: u32 = 0,
    pub const names = [_][]const u8{"yard"};
    pub const max_ticks = 800;
    /// Where the walk starts and stops, about the yard's origin: in the middle lane, and a metre
    /// and a half up the ramp.
    pub const start_x: f32 = 2;
    pub const stop_x: f32 = yard_mod.boulder_x + 1.5;
    const walk_limit = 720;
    const stand_ticks = 30;

    pub fn done(self: *const YardTour) bool {
        return self.failed != null or self.stage == names.len;
    }
    fn require(self: *YardTour, okay: bool) void {
        if (!okay and self.failed == null) self.failed = names[self.stage];
    }

    /// A tick: the movers, then the player.
    pub fn advance(self: *YardTour, walk: *walk_mod.Walk, yard: *Yard, dt: f32) !void {
        try self.prepare(walk, yard, null);
        try self.move(walk, yard, dt);
    }

    /// A tick's first half, §13's first step: the stage's start, and the movers moved. The frame
    /// loop times it apart from the player's move, with `clock`, or with none.
    pub fn prepare(self: *YardTour, walk: *walk_mod.Walk, yard: *Yard, clock: anytype) !void {
        if (self.done()) return;
        const world = &walk.world;
        if (self.tick == 0) {
            try yard.reset(walk.gpa, world, 0);
            const s = yard.settings.?;
            const z = yard_mod.laneZ(yard_mod.middleLane(s.rows), s.rows);
            try walk.teleport(yard.point(.init(start_x, yard_mod.height(start_x, z) + 0.1, z)));
            walk.yaw = 0;
            walk.pitch = 0;
            const r = world.report();
            self.closed_before = r.pairs_closed;
            self.gjk_before = r.pairs_gjk;
        }
        try yard.step(walk.gpa, world, clock);
        if (yard.pushed > 0) self.pushed = true;
    }

    /// Its second half: the player's move, through `Walk.step`, and the stage's checks.
    pub fn move(self: *YardTour, walk: *walk_mod.Walk, yard: *Yard, dt: f32) !void {
        if (self.done()) return;
        const world = &walk.world;
        const s = yard.settings.?;
        const local_x = walk.result.feet.x - s.origin.x;
        const walking = self.tick > 0 and self.standing == 0 and local_x < stop_x and self.tick <= walk_limit;
        try walk.step(.{ .direction = if (walking) .init(1, 0, 0) else .zero }, dt);
        const r = walk.result;
        self.trace[self.len] = r.feet;
        self.len += 1;
        for (std.mem.asBytes(&r.feet)) |b| self.hash = (self.hash ^ b) *% 0x100000001b3;
        self.require(!r.stuck);

        // Never through: the player's capsule overlaps no stone and no mover.
        const player = world.character(walk.character).?;
        var found: [8]physics.Overlap = undefined;
        const n = try world.overlap(world.body(player.body).?.shape, world.body(player.body).?.pose, .{ .ignore = player.body }, &found);
        for (found[0..n.count]) |o| self.require(!yard_mod.isStone(o.user) and !yard_mod.isMover(o.user));

        const lane = yard_mod.laneZ(yard_mod.middleLane(s.rows), s.rows);
        if (local_x < yard_mod.boulder_x) self.aside = @max(self.aside, @abs(r.feet.z - s.origin.z - lane));
        const report = world.report();
        const closed = report.pairs_closed -% self.closed_before;
        const gjk = report.pairs_gjk -% self.gjk_before;
        if (walking and local_x < yard_mod.boulder_x - 1 and closed > 0 and gjk > 0) self.both = true;
        self.closed_before = report.pairs_closed;
        self.gjk_before = report.pairs_gjk;

        if (self.tick > 0 and !walking) self.standing += 1;
        if (self.standing == stand_ticks) {
            // On the ramp: grounded on the boulder, its normal 20° from up in the upright frame.
            const ground = r.ground orelse return self.finish(walk, false);
            const normal = walk.frame.conjugate().rotate(ground.surface_normal);
            self.degrees = std.math.radiansToDegrees(std.math.acos(std.math.clamp(normal.y, -1, 1)));
            self.bodies = report.bodies_static + report.bodies_kinematic;
            self.baked = report.meshes_baked;
            const max_slope = walk.settings.?.character.max_slope;
            self.require(r.grounded and ground.body.eql(yard.boulder) and @abs(self.degrees - yard_mod.ramp_degrees) <= 0.01 and
                std.math.degreesToRadians(self.degrees) < max_slope);
            self.require(local_x >= stop_x - 0.1);
            // Turned aside by the mover in its lane, and both routines used among the stones.
            self.require(self.pushed and self.aside >= 0.1 and self.both);
            self.require(self.bodies >= 2100 and self.baked == 1);
            return self.finish(walk, true);
        }
        if (self.tick == max_ticks - 1) return self.finish(walk, false);
        self.tick += 1;
    }

    fn finish(self: *YardTour, walk: *const walk_mod.Walk, reached: bool) void {
        if (!reached) self.require(false);
        const r = walk.result;
        if (self.emit) {
            if (self.failed) |stage| {
                log.warn("tour: FAIL {s} (tick {d}, feet {d:.4},{d:.4},{d:.4}, grounded {}, ramp {d:.4} degrees, aside {d:.3} m, pushed {}, both pairs {}, {d} bodies, {d} baked)", .{ stage, self.tick, r.feet.x, r.feet.y, r.feet.z, r.grounded, self.degrees, self.aside, self.pushed, self.both, self.bodies, self.baked });
            } else {
                log.info("tour: yard pass (feet {d:.4},{d:.4},{d:.4}, ramp {d:.4} degrees, aside {d:.3} m, {d} bodies, {d} baked mesh)", .{ r.feet.x, r.feet.y, r.feet.z, self.degrees, self.aside, self.bodies, self.baked });
            }
        }
        self.stage += 1;
    }
};
