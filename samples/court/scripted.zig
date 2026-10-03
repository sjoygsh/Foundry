//! The scripted play-through driver (playable3d.md §10.2).
//!
//! It reads the game as a player sees it and answers with what a player's hands do: the
//! `Intent` their movement becomes, and the menu keys they press. It never writes game
//! state or names a phase change, so a script cannot take a path a player cannot. The waypoints are test data in `testdata/play.zig`.
const std = @import("std");
const core = @import("core");
const walk_mod = @import("walk.zig");
const game_mod = @import("game.zig");
const menus_mod = @import("menus.zig");
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

/// One frame of a script: what the player's hands do, on the pad and in the menus.
pub const Frame = struct {
    intent: Intent = .{},
    keys: menus_mod.Keys = .{},
};

pub const ScriptDriver = struct {
    script: *const play.Script,
    step: usize = 0,
    ticks: u32 = 0,
    done: bool = false,
    /// Why the script stopped short, if it did. Null with `done` set means it succeeded.
    failure: ?Failure = null,

    pub const Failure = enum { wrong_ending, timed_out, unknown_beacon };

    pub fn init(kind: ScriptKind) ScriptDriver {
        return .{ .script = kind.script() };
    }

    pub fn succeeded(self: *const ScriptDriver) bool {
        return self.done and self.failure == null;
    }

    fn fail(self: *ScriptDriver, why: Failure) Frame {
        self.failure = why;
        self.done = true;
        return .{};
    }

    /// What the player does this frame. Call once per frame until `done`.
    pub fn next(self: *ScriptDriver, game: *const Game) Frame {
        if (self.done) return .{};
        self.ticks += 1;
        if (self.ticks > self.script.tick_limit) return self.fail(.timed_out);

        const steps = self.script.steps;
        var out: Frame = .{};
        while (true) {
            if (self.step >= steps.len) {
                self.done = true;
                return .{};
            }
            switch (steps[self.step]) {
                .press => |key| {
                    self.step += 1;
                    switch (key) {
                        .up => out.keys.up = true,
                        .down => out.keys.down = true,
                        .left => out.keys.left = true,
                        .right => out.keys.right = true,
                        .accept => out.keys.accept = true,
                        .back => out.keys.back = true,
                    }
                    // A script that ends on a press is done with it: its last key may
                    // be Quit, after which no frame comes.
                    if (self.step >= steps.len) self.done = true;
                    return out;
                },
                .expect => |wanted| {
                    const phase = phaseOf(wanted);
                    if (game.phase == phase) {
                        // Met: the next step acts in this same frame, so waiting for a
                        // phase never costs the world an idle tick.
                        self.step += 1;
                        continue;
                    }
                    if (game.ended() and isEnding(phase)) return self.fail(.wrong_ending);
                    return out;
                },
                else => {},
            }
            // A move. It needs a game in play; anything else is for the next `expect` to judge.
            if (game.phase != .playing) {
                while (self.step < steps.len and steps[self.step] != .expect) self.step += 1;
                if (self.step >= steps.len) return self.fail(.wrong_ending);
                continue;
            }
            const feet = game.walk.result.feet;
            switch (steps[self.step]) {
                .walk => |w| {
                    const nav = moveTowards(game, point(w.to));
                    out.intent.direction = nav.dir;
                    aimTowards(game, point(w.face), &out.intent);
                    if (nav.dist < w.within) self.step += 1;
                },
                .jump => |j| {
                    out.intent.direction = moveTowards(game, point(j.to)).dir;
                    out.intent.jump = true;
                    aimTowards(game, point(j.face), &out.intent);
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
                        aimTowards(game, beacon.useCentre(), &out.intent);
                        out.intent.use = true;
                    }
                },
                .wait_gate => if (game.gate) |*g| {
                    if (g.progress >= 1.0) self.step += 1;
                },
                .stand => {},
                .press, .expect => unreachable,
            }
            return out;
        }
    }
};

fn phaseOf(p: play.Phase) game_mod.Phase {
    return switch (p) {
        .title => .title,
        .playing => .playing,
        .paused => .paused,
        .won => .won,
        .caught => .caught,
        .fell => .fell,
    };
}

fn isEnding(phase: game_mod.Phase) bool {
    return phase == .won or phase == .caught or phase == .fell;
}

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
