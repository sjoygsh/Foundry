//! Same scripted intents and executable checkpoints on null, Metal and Vulkan (§10.5).
const std = @import("std");
const core = @import("core");
const walk_mod = @import("walk.zig");
const Vec3 = core.math.Vec3;
const skin = @import("physics3d").narrow.contact_skin;
const log = core.log.scoped(.sandbox3d);

pub const Tour = struct {
    stage: usize = 0,
    tick: usize = 0,
    steps: usize = 0,
    snapped: bool = false,
    failed: ?[]const u8 = null,
    hash: u64 = 0xcbf29ce484222325,
    trace: [max_ticks]Vec3 = undefined,
    len: usize = 0,
    emit: bool = true,
    pub const max_ticks = 700;
    const names = [_][]const u8{ "floor", "steps", "ramp", "steep slope", "wall slide" };
    const durations = [_]usize{ 80, 130, 40, 120, 120 };
    const starts = [_]Vec3{ .init(1.1, skin, 2.5), .init(-1.3, skin, 0.1), .init(-1.1, 0.6 + skin, -2.1), .init(-2.0, skin, -0.7), .init(-0.3, 0.65, -2.65) };
    const directions = [_]Vec3{ .init(0, 0, -1), .init(0, 0, -0.4), .init(1, 0, 0), .init(-1, 0, 0), .init(0.2, 0, -0.34641016) };

    pub fn done(self: *const Tour) bool {
        return self.failed != null or self.stage == names.len;
    }
    fn require(self: *Tour, okay: bool) void {
        if (!okay and self.failed == null) self.failed = names[self.stage];
    }
    /// Stage setup is an explicit teleport, then one ordinary settling tick; movement then
    /// goes only through Walk.step, just as real input does. No synthetic collision fixtures.
    pub fn advance(self: *Tour, walk: *walk_mod.Walk, dt: f32) !void {
        if (self.done()) return;
        if (self.tick == 0) {
            try walk.teleport(starts[self.stage]);
            walk.yaw = 0;
            walk.pitch = 0;
        }
        try walk.step(.{ .direction = if (self.tick == 0) .zero else directions[self.stage] }, dt);
        const r = walk.result;
        self.trace[self.len] = r.feet;
        self.len += 1;
        for (std.mem.asBytes(&r.feet)) |b| self.hash = (self.hash ^ b) *% 0x100000001b3;
        self.require(!r.stuck);
        if (self.tick > 0) switch (self.stage) {
            0 => self.require(r.grounded and r.walls == 0),
            1 => {
                if (r.stepped > 0) self.steps += 1;
            },
            2 => {
                self.require(r.grounded);
                self.snapped = self.snapped or r.snapped;
            },
            3 => self.require(r.feet.y <= starts[3].y + skin + 1e-5),
            4 => {},
            else => unreachable,
        };
        if (self.tick == durations[self.stage]) {
            switch (self.stage) {
                0 => self.require(r.feet.z < -1.4), // Across the floor's x = -z seam.
                1 => self.require(@abs(r.feet.y - 0.6) <= 2 * skin and self.steps >= 4),
                2 => self.require(self.snapped and r.feet.y < 2 * skin),
                3 => self.require(r.walls > 0),
                4 => self.require(r.feet.x - starts[4].x >= 0.8 * directions[4].x * walk.settings.?.walk_speed * dt * @as(f32, @floatFromInt(durations[4]))),
                else => unreachable,
            }
            if (self.emit and self.failed == null) log.info("tour: {s} pass (feet {d:.4},{d:.4},{d:.4})", .{ names[self.stage], r.feet.x, r.feet.y, r.feet.z });
            self.stage += 1;
            self.tick = 0;
        } else self.tick += 1;
        if (self.emit) if (self.failed) |stage| log.warn("tour: FAIL {s} (tick {d}, feet {d:.4},{d:.4},{d:.4}, grounded {}, walls {d}, stepped {d:.4})", .{ stage, self.tick, r.feet.x, r.feet.y, r.feet.z, r.grounded, r.walls, r.stepped });
    }
    pub fn replayMatches(self: *const Tour, other: *const Tour) bool {
        return self.failed == null and other.failed == null and self.stage == names.len and other.stage == names.len and
            self.hash == other.hash and self.len == other.len and
            std.mem.eql(u8, std.mem.sliceAsBytes(self.trace[0..self.len]), std.mem.sliceAsBytes(other.trace[0..other.len]));
    }
};
