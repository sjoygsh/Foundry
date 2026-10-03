//! What the court sounds like (playable3d.md §6.2): which sound each event plays, and the
//! gain and pan of the ones that have a place.
//!
//! Sound is presentation. It is driven by the events a tick emitted and by the frame; no
//! tick reads anything here, so the audio thread's timing cannot change an outcome (I9).
//! The mixer has gain and pan and no listener, so position is this file's arithmetic.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const audio = @import("audio");
const game_mod = @import("game.zig");

const Vec3 = core.math.Vec3;
const Fields = data.fpk.Fields;
const log = core.log.scoped(.court);

pub const SoundSet = struct {
    ambience: core.ContentId,
    ambience_gain: f32,
    step: core.ContentId,
    step_distance: f32,
    jump: core.ContentId,
    land: core.ContentId,
    gate: core.ContentId,
    warden_step: core.ContentId,
    warden_step_distance: f32,
    hearing_distance: f32,
    won: core.ContentId,
    caught: core.ContentId,
    fell: core.ContentId,
    click: core.ContentId,

    pub const record_id = "court:sounds.main";

    pub fn read(fields: Fields) error{InvalidSounds}!SoundSet {
        return .{
            .ambience = try id(fields, "ambience"),
            .ambience_gain = try bounded(fields, "ambience_gain", 0, 1),
            .step = try id(fields, "step"),
            .step_distance = try bounded(fields, "step_distance", 0.1, 100),
            .jump = try id(fields, "jump"),
            .land = try id(fields, "land"),
            .gate = try id(fields, "gate"),
            .warden_step = try id(fields, "warden_step"),
            .warden_step_distance = try bounded(fields, "warden_step_distance", 0.1, 100),
            .hearing_distance = try bounded(fields, "hearing_distance", 0.5, 1000),
            .won = try id(fields, "won"),
            .caught = try id(fields, "caught"),
            .fell = try id(fields, "fell"),
            .click = try id(fields, "click"),
        };
    }

    /// The set a store holds, or null with one log line.
    pub fn find(store: *const data.Store) ?SoundSet {
        const record = store.lookup(core.ContentId.fromString(record_id)) orelse {
            log.warn("missing '{s}'; the court is silent", .{record_id});
            return null;
        };
        if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked("court:sound_set"))) {
            log.warn("'{s}' is not a 'court:sound_set'; the court is silent", .{record_id});
            return null;
        }
        return read(record.fields) catch {
            log.warn("invalid '{s}'; the court is silent", .{record_id});
            return null;
        };
    }
};

fn index(fields: Fields, name: []const u8) error{InvalidSounds}!u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidSounds;
}

fn id(fields: Fields, name: []const u8) error{InvalidSounds}!core.ContentId {
    const value = (fields.idAt(try index(fields, name)) catch return error.InvalidSounds) orelse return error.InvalidSounds;
    if (value.isNone()) return error.InvalidSounds;
    return value;
}

fn bounded(fields: Fields, name: []const u8, min: f32, max: f32) error{InvalidSounds}!f32 {
    const raw = (fields.floatAt(try index(fields, name)) catch return error.InvalidSounds) orelse return error.InvalidSounds;
    const value: f32 = @floatCast(raw);
    if (!std.math.isFinite(value) or value < min or value > max) return error.InvalidSounds;
    return value;
}

pub const Placed = struct { gain: f32, pan: f32 };

/// Gain from distance, falling in a line to silence at `hearing`, and pan from the
/// source's direction relative to the listener's yaw: -1 hard left, 1 hard right.
pub fn place(listener: Vec3, yaw: f32, source: Vec3, hearing: f32) Placed {
    var delta = source.sub(listener);
    delta.y = 0;
    const distance = delta.length();
    const gain = std.math.clamp(1 - distance / hearing, 0, 1);
    // On top of the listener there is no direction to pan toward.
    if (distance < 1e-3) return .{ .gain = gain, .pan = 0 };
    const right = core.math.Quat.fromAxisAngle(.up, yaw).rotate(.right);
    return .{ .gain = gain, .pan = std.math.clamp(delta.scale(1 / distance).dot(right), -1, 1) };
}

/// The court's sounds over one mixer. Without a mixer or a sound set every call is a
/// counted no-op, so the game plays the same and says what it could not play.
pub const Sounds = struct {
    mixer: ?*audio.Mixer = null,
    set: ?SoundSet = null,
    ambience: audio.VoiceHandle = .none,
    gate: audio.VoiceHandle = .none,
    gate_position: Vec3 = .zero,
    /// Sounds asked for, started, and refused. A scripted run asserts `dropped` is zero.
    requested: u32 = 0,
    played: u32 = 0,
    dropped: u32 = 0,

    fn start(self: *Sounds, sound: core.ContentId, params: audio.PlayParams) audio.VoiceHandle {
        self.requested += 1;
        const mixer = self.mixer orelse {
            self.dropped += 1;
            return .none;
        };
        const voice = mixer.play(sound, params) catch |err| {
            self.dropped += 1;
            log.warn("sound {f} not played ({t})", .{ sound, err });
            return .none;
        };
        self.played += 1;
        return voice;
    }

    /// The events of one tick, heard from where the player now stands.
    pub fn onEvents(self: *Sounds, game: *const game_mod.Game) void {
        const set = self.set orelse return;
        const ears = game.walk.eye();
        const yaw = game.walk.yaw;
        for (game.tickEvents()) |event| switch (event.kind) {
            .step => _ = self.start(set.step, .{ .gain = 0.5 }),
            .jump => _ = self.start(set.jump, .{ .gain = 0.6 }),
            .land => _ = self.start(set.land, .{ .gain = 0.7 }),
            .beacon => _ = self.start(game.beacons[event.beacon].settings.sound, .{}),
            .gate => {
                const at = place(ears, yaw, event.position, set.hearing_distance);
                self.gate = self.start(set.gate, .{ .gain = at.gain, .pan = at.pan });
                self.gate_position = event.position;
            },
            .warden_step => {
                const at = place(ears, yaw, event.position, set.hearing_distance);
                // Out of earshot is not a sound, and not a dropped one.
                if (at.gain > 0) _ = self.start(set.warden_step, .{ .gain = at.gain, .pan = at.pan });
            },
            .won => _ = self.start(set.won, .{}),
            .caught => _ = self.start(set.caught, .{}),
            .fell => _ = self.start(set.fell, .{}),
        };
    }

    pub fn click(self: *Sounds) void {
        const set = self.set orelse return;
        _ = self.start(set.click, .{ .gain = 0.5 });
    }

    /// Once per frame: the mixer's own frame, the ambience from the title onward, and the
    /// moving gate followed as the player turns.
    pub fn frame(self: *Sounds, game: *const game_mod.Game) void {
        const mixer = self.mixer orelse return;
        mixer.update();
        const set = self.set orelse return;
        if (self.ambience.isNone() or !mixer.isPlaying(self.ambience)) {
            self.ambience = self.start(set.ambience, .{ .gain = set.ambience_gain, .looping = true });
        }
        if (!self.gate.isNone()) {
            if (mixer.isPlaying(self.gate)) {
                const at = place(game.walk.eye(), game.walk.yaw, self.gate_position, set.hearing_distance);
                mixer.setGain(self.gate, at.gain);
                mixer.setPan(self.gate, at.pan);
            } else self.gate = .none;
        }
    }

    /// Before a content reload retires the sounds, and at shutdown.
    pub fn silence(self: *Sounds) void {
        if (self.mixer) |mixer| mixer.stopAll();
        self.ambience = .none;
        self.gate = .none;
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "sounds: gain falls with distance to silence, and pan follows the look" {
    const here: Vec3 = .zero;
    // Facing -Z (yaw 0), a source at +X is to the right, at -X to the left.
    const right = place(here, 0, .init(5, 0, 0), 10);
    try testing.expectApproxEqAbs(@as(f32, 0.5), right.gain, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), right.pan, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), place(here, 0, .init(-5, 0, 0), 10).pan, 1e-6);
    // Straight ahead and straight behind are centred.
    try testing.expectApproxEqAbs(@as(f32, 0), place(here, 0, .init(0, 0, -5), 10).pan, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), place(here, 0, .init(0, 0, 5), 10).pan, 1e-6);
    // Turning a quarter left puts what was ahead on the right.
    try testing.expectApproxEqAbs(@as(f32, 1), place(here, std.math.pi / 2.0, .init(0, 0, -5), 10).pan, 1e-5);
    // At and past the hearing distance there is nothing; height does not count.
    try testing.expectEqual(@as(f32, 0), place(here, 0, .init(10, 0, 0), 10).gain);
    try testing.expectEqual(@as(f32, 0), place(here, 0, .init(40, 0, 0), 10).gain);
    try testing.expectApproxEqAbs(@as(f32, 0.5), place(here, 0, .init(5, 30, 0), 10).gain, 1e-6);
    // On top of the listener: full, centred, and finite.
    const on = place(here, 0, here, 10);
    try testing.expectEqual(@as(f32, 1), on.gain);
    try testing.expectEqual(@as(f32, 0), on.pan);
}

test "sounds: without a mixer every request is counted as dropped, and none is played" {
    var s: Sounds = .{ .set = undefined };
    s.set = null;
    s.click();
    try testing.expectEqual(@as(u32, 0), s.requested);
    var with_set: Sounds = .{};
    with_set.set = .{
        .ambience = .fromString("a:a"),
        .ambience_gain = 1,
        .step = .fromString("a:b"),
        .step_distance = 1,
        .jump = .fromString("a:c"),
        .land = .fromString("a:d"),
        .gate = .fromString("a:e"),
        .warden_step = .fromString("a:f"),
        .warden_step_distance = 1,
        .hearing_distance = 10,
        .won = .fromString("a:g"),
        .caught = .fromString("a:h"),
        .fell = .fromString("a:i"),
        .click = .fromString("a:j"),
    };
    with_set.click();
    try testing.expectEqual(@as(u32, 1), with_set.requested);
    try testing.expectEqual(@as(u32, 1), with_set.dropped);
    try testing.expectEqual(@as(u32, 0), with_set.played);
}
