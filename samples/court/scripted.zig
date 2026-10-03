//! The scripted play-through driver (playable3d.md §10.2).
//!
//! It reads the game as a player sees it and answers with the `Intent` a player's input
//! becomes: move, look, jump, use and restart. It never writes game state, so a script
//! cannot take a path a player cannot. The waypoints are test data in `testdata/play.zig`.
const std = @import("std");
const core = @import("core");
const walk_mod = @import("walk.zig");
const game_mod = @import("game.zig");
const play = @import("testdata/play.zig");

const Vec3 = core.math.Vec3;
const Quat = core.math.Quat;
const Intent = walk_mod.Intent;
const Game = game_mod.Game;

pub const ScriptKind = enum {
    win,
    caught,
    fell,

    pub fn parse(text: []const u8) ?ScriptKind {
        return std.meta.stringToEnum(ScriptKind, text);
    }

    pub fn script(self: ScriptKind) *const play.Script {
        return switch (self) {
            .win => &play.win,
            .caught => &play.caught,
            .fell => &play.fell,
        };
    }
};

pub const ScriptDriver = struct {
    script: *const play.Script,
    step: usize = 0,
    /// How many times the script's ending has been reached.
    endings: u8 = 0,
    ticks: u32 = 0,
    /// The restart that follows the last ending has been sent; the next tick checks it.
    restarting: bool = false,
    done: bool = false,
    /// Why the script stopped short, if it did. Null with `done` set means it succeeded.
    failure: ?Failure = null,

    pub const Failure = enum { wrong_ending, timed_out, unknown_beacon, restart_did_not_play };

    pub fn init(kind: ScriptKind) ScriptDriver {
        return .{ .script = kind.script() };
    }

    pub fn succeeded(self: *const ScriptDriver) bool {
        return self.done and self.failure == null and self.endings == self.script.runs;
    }

    fn fail(self: *ScriptDriver, why: Failure) Intent {
        self.failure = why;
        self.done = true;
        return .{};
    }

    /// The intent for the tick about to run. Call once per tick until `done`.
    pub fn nextIntent(self: *ScriptDriver, game: *const Game) Intent {
        if (self.done) return .{};
        self.ticks += 1;
        if (self.ticks > self.script.tick_limit) return self.fail(.timed_out);

        if (self.restarting) {
            if (game.phase != .playing) return self.fail(.restart_did_not_play);
            self.done = true;
            return .{};
        }

        const expected: game_mod.Phase = switch (self.script.ending) {
            .won => .won,
            .caught => .caught,
            .fell => .fell,
        };
        switch (game.phase) {
            .playing => {},
            .won, .caught, .fell => {
                if (game.phase != expected) return self.fail(.wrong_ending);
                self.endings += 1;
                self.step = 0;
                // A win is left standing after its last run; a failure is restarted, which
                // is what its screen offers.
                if (self.endings == self.script.runs and expected == .won) {
                    self.done = true;
                    return .{};
                }
                if (self.endings == self.script.runs) self.restarting = true;
                return .{ .restart = true };
            },
            .title, .paused => return .{},
        }

        if (self.step >= self.script.steps.len) return .{};
        var intent: Intent = .{};
        const feet = game.walk.result.feet;
        switch (self.script.steps[self.step]) {
            .walk => |w| {
                const nav = moveTowards(game, point(w.to));
                intent.direction = nav.dir;
                aimTowards(game, point(w.face), &intent);
                if (nav.dist < w.within) self.step += 1;
            },
            .jump => |j| {
                intent.direction = moveTowards(game, point(j.to)).dir;
                intent.jump = true;
                aimTowards(game, point(j.face), &intent);
                if (feet.z < j.land_z and game.walk.result.grounded) self.step += 1;
            },
            .use => |name| {
                const id = core.ContentId.fromString(name);
                const beacon = for (game.beacons[0..game.beacon_count]) |*b| {
                    if (b.id.eql(id)) break b;
                } else return self.fail(.unknown_beacon);
                if (beacon.lit) {
                    self.step += 1;
                } else {
                    aimTowards(game, beacon.useCentre(), &intent);
                    intent.use = true;
                }
            },
            .wait_gate => if (game.gate) |*g| {
                if (g.progress >= 1.0) self.step += 1;
            },
            .stand => {},
        }
        return intent;
    }
};

fn point(p: play.Point) Vec3 {
    return .init(p[0], p[1], p[2]);
}

/// The move input, relative to the yaw, that walks the player toward `target`.
fn moveTowards(game: *const Game, target: Vec3) struct { dir: Vec3, dist: f32 } {
    var delta = target.sub(game.walk.result.feet);
    delta.y = 0;
    const dist = delta.length();
    if (dist < 1e-4) return .{ .dir = .zero, .dist = 0 };
    return .{ .dir = Quat.fromAxisAngle(.up, -game.walk.yaw).rotate(delta.scale(1.0 / dist)), .dist = dist };
}

/// The relative look motion that turns the view onto `target` in one tick, as a mouse
/// flick would.
fn aimTowards(game: *const Game, target: Vec3, intent: *Intent) void {
    const look_rate = if (game.rules) |r| r.look_rate else return;
    const to = target.sub(game.walk.eye());
    const desired_yaw = @mod(std.math.atan2(-to.x, -to.z), 2 * std.math.pi);
    const desired_pitch = std.math.atan2(to.y, @sqrt(to.x * to.x + to.z * to.z));
    var dyaw = desired_yaw - game.walk.yaw;
    while (dyaw > std.math.pi) dyaw -= 2 * std.math.pi;
    while (dyaw < -std.math.pi) dyaw += 2 * std.math.pi;
    intent.look_dx = -dyaw / look_rate;
    intent.look_dy = -(desired_pitch - game.walk.pitch) / look_rate;
}
