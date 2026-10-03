//! Scripted play-through drivers for samples/court (§10.2).
//! Produces an Intent each tick from player input mechanisms only:
//! moving (WASD), looking, jumping (Space), using (E), and restarting (R).
const std = @import("std");
const core = @import("core");
const walk_mod = @import("walk.zig");
const game_mod = @import("game.zig");

const Vec3 = core.math.Vec3;
const Quat = core.math.Quat;
const Intent = walk_mod.Intent;
const Game = game_mod.Game;

pub const ScriptKind = enum {
    win,
    caught,
    fell,
};

pub const ScriptDriver = struct {
    kind: ScriptKind,
    step: usize = 0,
    wait_ticks: u32 = 0,
    wins_completed: u32 = 0,
    done: bool = false,

    pub fn init(kind: ScriptKind) ScriptDriver {
        return .{ .kind = kind };
    }

    pub fn nextIntent(self: *ScriptDriver, game: *const Game, dt: f32) Intent {
        switch (self.kind) {
            .win => return self.nextWinIntent(game, dt),
            .caught => return self.nextCaughtIntent(game, dt),
            .fell => return self.nextFellIntent(game, dt),
        }
    }

    fn nextWinIntent(self: *ScriptDriver, game: *const Game, dt: f32) Intent {
        _ = dt;
        const feet = game.walk.result.feet;
        const yaw = game.walk.yaw;
        const look_rate = if (game.rules) |r| r.look_rate else 0.004;

        if (game.phase == .won) {
            if (self.wins_completed == 0) {
                self.wins_completed = 1;
                self.step = 0;
                return .{ .restart = true };
            } else {
                self.done = true;
                return .{};
            }
        }

        var intent: Intent = .{};

        switch (self.step) {
            // 0: Walk to Beacon 1 (open courtyard at (3.5, 0, 4.5)). Stop near (2.5, 0, 4.5).
            0 => {
                const nav = moveTowards(feet, yaw, .init(2.5, 0, 4.5));
                intent.direction = nav.dir;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(3.5, 0.5, 4.5), look_rate, &intent);
                if (nav.dist < 0.25) self.step = 1;
            },
            // 1: Aim at Beacon 1 and Use.
            1 => {
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(3.5, 0.5, 4.5), look_rate, &intent);
                intent.use = true;
                if (game.isBeaconLit(core.ContentId.fromString("court:beacon.open"))) self.step = 2;
            },
            // 2: Walk west along south corridor to (-3.5, 0, 4.5) to bypass warden patrol.
            2 => {
                const nav = moveTowards(feet, yaw, .init(-3.5, 0, 4.5));
                intent.direction = nav.dir;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(-3.5, 0.5, 1.4), look_rate, &intent);
                if (nav.dist < 0.3) self.step = 3;
            },
            // 3: Walk north to wall lip (-3.5, 0, 1.4) facing North.
            3 => {
                const nav = moveTowards(feet, yaw, .init(-3.5, 0, 1.4));
                intent.direction = nav.dir;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(-3.5, 0.5, 0.0), look_rate, &intent);
                if (nav.dist < 0.25) self.step = 4;
            },
            // 4: Jump forward North over low wall.
            4 => {
                const nav = moveTowards(feet, yaw, .init(-3.5, 0, 0.3));
                intent.direction = nav.dir;
                intent.jump = true;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(-3.5, 0.5, 0.0), look_rate, &intent);
                if (feet.z < 0.8 and game.walk.result.grounded) self.step = 5;
            },
            // 5: Walk to Beacon 2 (behind wall at (-3.0, 0, -0.5)). Stop near (-2.2, 0, -0.5).
            5 => {
                const nav = moveTowards(feet, yaw, .init(-2.2, 0, -0.5));
                intent.direction = nav.dir;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(-3.0, 0.5, -0.5), look_rate, &intent);
                if (nav.dist < 0.25) self.step = 6;
            },
            // 6: Aim at Beacon 2 and Use.
            6 => {
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(-3.0, 0.5, -0.5), look_rate, &intent);
                intent.use = true;
                if (game.isBeaconLit(core.ContentId.fromString("court:beacon.wall"))) self.step = 7;
            },
            // 7: Walk east onto open courtyard floor at (0.0, 0, -0.5).
            7 => {
                const nav = moveTowards(feet, yaw, .init(0.0, 0, -0.5));
                intent.direction = nav.dir;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(0.0, 0.5, -1.8), look_rate, &intent);
                if (nav.dist < 0.3) self.step = 8;
            },
            // 8: Walk to gap edge at (0.0, 0, -1.6).
            8 => {
                const nav = moveTowards(feet, yaw, .init(0.0, 0, -1.6));
                intent.direction = nav.dir;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(0.0, 0.5, -3.5), look_rate, &intent);
                if (nav.dist < 0.2) self.step = 9;
            },
            // 9: Jump forward North over gap onto Ledge.
            9 => {
                const nav = moveTowards(feet, yaw, .init(0.0, 0, -3.5));
                intent.direction = nav.dir;
                intent.jump = true;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(0.0, 0.5, -3.5), look_rate, &intent);
                if (feet.z < -3.3 and game.walk.result.grounded) self.step = 10;
            },
            // 10: Walk to Beacon 3 on Ledge at (2.0, 0, -5.5). Stop near (1.2, 0, -5.5).
            10 => {
                const nav = moveTowards(feet, yaw, .init(1.2, 0, -5.5));
                intent.direction = nav.dir;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(2.0, 0.5, -5.5), look_rate, &intent);
                if (nav.dist < 0.25) self.step = 11;
            },
            // 11: Aim at Beacon 3 and Use. Gate starts opening!
            11 => {
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(2.0, 0.5, -5.5), look_rate, &intent);
                intent.use = true;
                if (game.isBeaconLit(core.ContentId.fromString("court:beacon.ledge"))) self.step = 12;
            },
            // 12: Walk to front of Gate at (0.0, 0, -7.0).
            12 => {
                const nav = moveTowards(feet, yaw, .init(0.0, 0, -7.0));
                intent.direction = nav.dir;
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(0.0, 1.25, -9.0), look_rate, &intent);
                if (nav.dist < 0.25) self.step = 13;
            },
            // 13: Wait for gate to open, then walk through into exit volume.
            13 => {
                aimTowards(game.walk.eye(), yaw, game.walk.pitch, .init(0.0, 1.25, -9.0), look_rate, &intent);
                if (game.gate) |g| {
                    if (g.progress >= 1.0) {
                        const nav = moveTowards(feet, yaw, .init(0.0, 0, -8.6));
                        intent.direction = nav.dir;
                    }
                }
            },
            else => {},
        }

        return intent;
    }

    fn nextCaughtIntent(self: *ScriptDriver, game: *const Game, dt: f32) Intent {
        _ = dt;
        const feet = game.walk.result.feet;
        const yaw = game.walk.yaw;

        if (game.phase == .caught) {
            self.done = true;
            return .{ .restart = true };
        }

        var intent: Intent = .{};
        // Walk directly into the warden's patrol line at (0.0, 0, 2.5).
        const nav = moveTowards(feet, yaw, .init(0.0, 0, 2.5));
        if (nav.dist > 0.2) {
            intent.direction = nav.dir;
        }
        return intent;
    }

    fn nextFellIntent(self: *ScriptDriver, game: *const Game, dt: f32) Intent {
        _ = dt;
        const feet = game.walk.result.feet;
        const yaw = game.walk.yaw;

        if (game.phase == .fell) {
            self.done = true;
            return .{ .restart = true };
        }

        var intent: Intent = .{};
        // Walk directly North into the pit gap at (0.0, 0, -2.5).
        const nav = moveTowards(feet, yaw, .init(0.0, 0, -2.5));
        intent.direction = nav.dir;
        if (feet.z < -1.0 and feet.z > -2.0) {
            intent.jump = true;
        }
        return intent;
    }
};

fn moveTowards(feet: Vec3, yaw: f32, target: Vec3) struct { dir: Vec3, dist: f32 } {
    var delta = target.sub(feet);
    delta.y = 0;
    const dist = delta.length();
    if (dist < 1e-4) return .{ .dir = .zero, .dist = 0 };
    const world_dir = delta.scale(1.0 / dist);
    const local_dir = Quat.fromAxisAngle(.up, -yaw).rotate(world_dir);
    return .{ .dir = local_dir, .dist = dist };
}

fn aimTowards(eye: Vec3, yaw: f32, pitch: f32, target: Vec3, look_rate: f32, intent: *Intent) void {
    const to = target.sub(eye);
    const desired_yaw = @mod(std.math.atan2(-to.x, -to.z), 2 * std.math.pi);
    const h_dist = @sqrt(to.x * to.x + to.z * to.z);
    const desired_pitch = std.math.clamp(std.math.atan2(to.y, h_dist), -85 * std.math.pi / 180.0, 85 * std.math.pi / 180.0);

    var dyaw = desired_yaw - yaw;
    while (dyaw > std.math.pi) dyaw -= 2 * std.math.pi;
    while (dyaw < -std.math.pi) dyaw += 2 * std.math.pi;
    const dpitch = desired_pitch - pitch;

    intent.look_dx = -dyaw / look_rate;
    intent.look_dy = -dpitch / look_rate;
}
