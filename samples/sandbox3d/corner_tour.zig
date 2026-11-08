//! M37's six stages in the corner (`docs/design/collision-extras.md` §11), each with its check,
//! after M23's five, which keep their own pin. Like `Tour`, a stage is a teleport and a corner
//! set back to its start, then ordinary ticks: the corner's pieces first, then `Walk.step`, the
//! path real input takes.
const std = @import("std");
const core = @import("core");
const physics = @import("physics3d");
const walk_mod = @import("walk.zig");
const extras_mod = @import("extras.zig");
const Extras = extras_mod.Extras;
const Vec3 = core.math.Vec3;
const skin = physics.narrow.contact_skin;
const log = core.log.scoped(.sandbox3d);

pub const CornerTour = struct {
    stage: usize = 0,
    tick: usize = 0,
    failed: ?[]const u8 = null,
    hash: u64 = 0xcbf29ce484222325,
    trace: [max_ticks]Vec3 = undefined,
    len: usize = 0,
    emit: bool = true,
    /// What a stage gathers on its way.
    carried: bool = false,
    yaw: f32 = 0,
    half_pace: usize = 0,
    crate_at: Vec3 = .zero,
    still: usize = 0,
    ceiling: bool = false,
    walls: bool = false,
    feet: Vec3 = .zero,
    pub const max_ticks = 600;
    pub const names = [_][]const u8{ "lift", "turntable", "crate", "door", "ledge", "rock" };
    const durations = [_]usize{ 200, 60, 80, 90, 90, 60 };
    const starts = [_]Vec3{
        .init(extras_mod.lift_centre.x, extras_mod.lift_low + skin, extras_mod.lift_centre.z),
        .init(extras_mod.table_centre.x + 0.5, extras_mod.table_centre.y + extras_mod.table_half + skin, extras_mod.table_centre.z),
        .init(extras_mod.crate_start.x + 1.0, skin, extras_mod.crate_start.z),
        .init(extras_mod.hinge.x + 0.8, skin, extras_mod.hinge.z),
        .init(extras_mod.ledge_centre.x, skin, extras_mod.ledge_centre.z),
        .init(extras_mod.origin.x, skin, extras_mod.origin.z + 1.2),
    };
    const directions = [_]Vec3{ .zero, .zero, .init(-1, 0, 0), .zero, .zero, .init(0, 0, 1) };

    pub fn done(self: *const CornerTour) bool {
        return self.failed != null or self.stage == names.len;
    }
    fn require(self: *CornerTour, okay: bool) void {
        if (!okay and self.failed == null) self.failed = names[self.stage];
    }

    /// A tick: the corner's pieces, then the player.
    pub fn advance(self: *CornerTour, walk: *walk_mod.Walk, extras: *Extras, dt: f32) !void {
        try self.prepare(walk, extras, null);
        try self.move(walk, extras, dt);
    }

    /// A tick's first half, §13's first step: a stage's start, and the pieces moved. The frame
    /// loop times it apart from the player's move, with `clock`, or with none.
    pub fn prepare(self: *CornerTour, walk: *walk_mod.Walk, extras: *Extras, clock: anytype) !void {
        if (self.done()) return;
        const gpa = walk.gpa;
        const world = &walk.world;
        if (self.tick == 0) {
            try extras.reset(gpa, world, 0);
            try walk.teleport(starts[self.stage]);
            walk.yaw = 0;
            walk.pitch = 0;
            self.carried = false;
            self.yaw = 0;
            self.half_pace = 0;
            self.still = 0;
            self.ceiling = false;
            self.walls = false;
            self.crate_at = extras.local(world, extras.crate).position;
            self.feet = starts[self.stage];
        }
        try extras.step(gpa, world, clock);
    }

    /// Its second half: the player's move, through `Walk.step`, and the stage's checks.
    pub fn move(self: *CornerTour, walk: *walk_mod.Walk, extras: *Extras, dt: f32) !void {
        if (self.done()) return;
        const world = &walk.world;
        const jump = self.stage == 4 and self.tick == 1;
        try walk.step(.{ .direction = if (self.tick == 0) .zero else directions[self.stage], .jump = jump }, dt);
        const r = walk.result;
        self.trace[self.len] = r.feet;
        self.len += 1;
        for (std.mem.asBytes(&r.feet)) |b| self.hash = (self.hash ^ b) *% 0x100000001b3;
        self.require(!r.stuck);
        const speed = walk.settings.?.walk_speed;
        if (self.tick > 0) switch (self.stage) {
            0 => self.carried = self.carried or r.carried.length() > 0,
            1 => self.yaw += r.carried_yaw,
            2 => {
                const crate = extras.local(world, extras.crate).position;
                const moved = crate.sub(self.crate_at).length();
                if (@abs(moved / (speed * dt) - extras_mod.crate_push) < 0.01) self.half_pace += 1;
                self.still = if (moved < 1e-6) self.still + 1 else 0;
                self.crate_at = crate;
            },
            3 => {
                // Never through: the door never overlaps the player, nor moves it.
                var found: [4]physics.Overlap = undefined;
                const door = world.body(extras.door).?.pose;
                const n = try world.overlap(extras_mod.doorShape(), door, .{ .ignore = extras.door }, &found);
                const player = world.character(walk.character).?.body;
                for (found[0..n.count]) |o| self.require(!o.body.eql(player));
                self.require(r.feet.sub(self.feet).length() < 1e-3);
            },
            4 => self.ceiling = self.ceiling or r.ceiling,
            5 => self.walls = self.walls or r.walls > 0,
            else => unreachable,
        };
        if (self.tick == durations[self.stage]) {
            switch (self.stage) {
                // Carried up to the platform's height.
                0 => self.require(self.carried and @abs(r.feet.y - extras_mod.lift_high) <= 0.01),
                // A quarter-turn's yaw over a second.
                1 => self.require(@abs(self.yaw - extras_mod.table_rate) <= 1e-3),
                // Pushed half a metre at half pace, then stopped by the wall.
                2 => {
                    const crate = extras.local(world, extras.crate).position;
                    self.require(extras_mod.crate_start.x - crate.x >= 0.5 and self.half_pace >= 15 and self.still >= 20);
                    self.require(@abs(crate.x - extras_mod.crate_half.x - extras_mod.wall_x) <= 0.01);
                },
                // Stopped by the player within `cast_tolerance`: its last sweep met the player
                // where the door stands, not shut.
                3 => {
                    const player = world.character(walk.character).?.body;
                    const stop = extras.door_stop orelse return self.require(false);
                    self.require(stop.body.eql(player) and stop.fraction == 0 and extras.door_angle > 0.2);
                },
                // Up through the ledge from below, and down onto it.
                4 => self.require(!self.ceiling and r.grounded and @abs(r.feet.y - (extras_mod.ledge_centre.y)) <= 0.01 and
                    r.ground != null and walk.surface().eql(core.ContentId.fromString("sandbox3d:surface.wood"))),
                // Blocked by the proxy, a few boxes, at its scaled face, not by the rock's faces.
                5 => {
                    const s = extras.settings.?;
                    const face = s.rock_position.z - s.rock_scale * 0.47;
                    const radius = walk.settings.?.character.radius;
                    self.require(self.walls and extras.rock_triangles <= 24 and @abs(r.feet.z - (face - radius - skin)) <= 0.01);
                },
                else => unreachable,
            }
            if (self.emit and self.failed == null) log.info("tour: {s} pass (feet {d:.4},{d:.4},{d:.4}, on {s})", .{ names[self.stage], r.feet.x, r.feet.y, r.feet.z, surfaceLabel(walk) });
            self.stage += 1;
            self.tick = 0;
        } else self.tick += 1;
        if (self.emit) if (self.failed) |stage| log.warn("tour: FAIL {s} (tick {d}, feet {d:.4},{d:.4},{d:.4}, grounded {}, walls {d}, carried yaw {d:.5}, door {d:.4})", .{ stage, self.tick, r.feet.x, r.feet.y, r.feet.z, r.grounded, r.walls, self.yaw, extras.door_angle });
    }

    fn surfaceLabel(walk: *const walk_mod.Walk) []const u8 {
        const s = walk.surface();
        inline for (.{ "stone", "wood", "metal" }) |name| {
            if (s.eql(core.ContentId.fromString("sandbox3d:surface." ++ name))) return name;
        }
        return if (s.isNone()) "none" else "another surface";
    }
};

/// The turn the tilted tour is run in: Step 1's, a 0.7 rad tilt about an axis off every plane.
pub fn tilt() core.math.Quat {
    return core.math.Quat.fromAxisAngle(Vec3.init(1, 0.3, 0.5).normalize(), 0.7);
}

/// Every tick of two traces within `tolerance`, compared in the upright frame, and how far
/// apart they came at most.
pub fn compare(upright: []const Vec3, tilted: []const Vec3, tolerance: f32) struct { matches: bool, worst: f32 } {
    if (upright.len != tilted.len) return .{ .matches = false, .worst = std.math.inf(f32) };
    var worst: f32 = 0;
    for (upright, tilted) |a, b| worst = @max(worst, a.sub(b).length());
    return .{ .matches = worst <= tolerance, .worst = worst };
}
