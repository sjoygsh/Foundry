//! What the court sounds like (playable3d.md §6.2, mixing.md §11): which sound each event
//! plays, where the ones with a place are, what is in their way, and the mix they go through.
//!
//! Sound is presentation. It is driven by the events a tick emitted and by the frame; no
//! tick reads anything here, so the audio thread's timing cannot change an outcome (I9).
//! The engine places a spatial voice against the listener (ADR-0068); this file says where
//! the listener and each source are, and how occluded each source is, from one ray.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const audio = @import("audio");
const game_mod = @import("game.zig");
const menus = @import("menus.zig");

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
            .won = try id(fields, "won"),
            .caught = try id(fields, "caught"),
            .fell = try id(fields, "fell"),
            .click = try id(fields, "click"),
        };
    }

    /// The set a store holds, or null with one log line.
    pub fn find(store: *const data.Store) ?SoundSet {
        const record = lookup(store, record_id, "court:sound_set", "the court is silent") orelse return null;
        return read(record.fields) catch {
            log.warn("invalid '{s}'; the court is silent", .{record_id});
            return null;
        };
    }
};

/// Which bus each slider moves, and what a pause does to the world (mixing.md §11).
pub const MixSet = struct {
    /// The root the mixer mixes through. The master volume is the mixer's master gain.
    master: core.ContentId,
    music: core.ContentId,
    /// The world bus: effects and ambience, under the courtyard reverb.
    effects: core.ContentId,
    /// The world's low-pass, swept down while paused.
    muffle: core.ContentId,
    muffle_frequency: f32,
    muffle_fade: f32,

    pub const record_id = "court:mix.main";

    pub fn read(fields: Fields) error{InvalidSounds}!MixSet {
        return .{
            .master = try id(fields, "master"),
            .music = try id(fields, "music"),
            .effects = try id(fields, "effects"),
            .muffle = try id(fields, "muffle"),
            .muffle_frequency = try bounded(fields, "muffle_frequency", 20, 20_000),
            .muffle_fade = try bounded(fields, "muffle_fade", 0, 10),
        };
    }

    /// The set a store holds, or null with one log line: the court then mixes as M30 did.
    pub fn find(store: *const data.Store) ?MixSet {
        const record = lookup(store, record_id, "court:mix_set", "the court mixes with no buses") orelse return null;
        return read(record.fields) catch {
            log.warn("invalid '{s}'; the court mixes with no buses", .{record_id});
            return null;
        };
    }
};

fn lookup(store: *const data.Store, record_id: []const u8, schema: []const u8, otherwise: []const u8) ?data.store.Record {
    const record = store.lookup(core.ContentId.fromString(record_id)) orelse {
        log.warn("missing '{s}'; {s}", .{ record_id, otherwise });
        return null;
    };
    if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked(schema))) {
        log.warn("'{s}' is not a '{s}'; {s}", .{ record_id, schema, otherwise });
        return null;
    }
    return record;
}

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

/// The listener the engine places spatial voices against: the walker's eye and look.
pub fn listener(walk: anytype) audio.Listener {
    const rotation = walk.rotation();
    return .{ .position = walk.eye(), .forward = rotation.rotate(.forward), .up = rotation.rotate(.up) };
}

/// A ray from the ears stops this far short of a source, so the ground a source stands on,
/// or the prop it is, does not count as being in its way.
pub const source_margin: f32 = 0.3;
/// The most occlusion changes in a frame: a source passing behind a wall is muffled over
/// about an eighth of a second at 60 Hz, not in one step.
pub const occlusion_rate: f32 = 0.125;

/// How occluded a source is from the ears, 0 or 1: whether one ray against the court's
/// walls, ears to source, meets anything first. `ignore` is the source's own body.
pub fn occluded(world: anytype, ears: Vec3, source: Vec3, ignore: ?@import("physics3d").BodyHandle) f32 {
    const delta = source.sub(ears);
    const distance = delta.length();
    if (!std.math.isFinite(distance) or distance <= source_margin) return 0;
    const hit = world.raycast(ears, delta.scale(1 / distance), distance - source_margin, .{ .mask = game_mod.Game.level_layer, .ignore = ignore }) catch return 0;
    return if (hit != null) 1 else 0;
}

/// One step of a voice's occlusion toward the ray's answer.
pub fn approach(current: f32, target: f32) f32 {
    return current + std.math.clamp(target - current, -occlusion_rate, occlusion_rate);
}

/// What a placed voice follows.
const Source = union(enum) {
    /// Stays where it began: a beacon.
    fixed: Vec3,
    /// The warden's body, as it walks.
    warden,
    /// The gate, as it sinks.
    gate,
};

const Placed = struct {
    voice: audio.VoiceHandle,
    source: Source,
    occlusion: f32,
};

/// The court's sounds over one mixer. Without a mixer or a sound set every call is a
/// counted no-op, so the game plays the same and says what it could not play.
pub const Sounds = struct {
    mixer: ?*audio.Mixer = null,
    set: ?SoundSet = null,
    /// The mix this court uses, or null to mix as M30 did, with no buses.
    mix: ?MixSet = null,
    /// The muffle's slot on the world bus, and its record's own values to return to.
    muffle_slot: ?u8 = null,
    muffle_open: ?asset.mix.Filter = null,
    muffled: bool = false,
    ambience: audio.VoiceHandle = .none,
    /// The spatial voices still playing, moved and occluded each frame. A voice past the
    /// capacity plays on where it began.
    placed: [capacity]Placed = undefined,
    placed_len: usize = 0,
    /// Sounds asked for, started, and refused. A scripted run asserts `dropped` is zero.
    requested: u32 = 0,
    played: u32 = 0,
    dropped: u32 = 0,

    const capacity = 16;

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

    /// Mixes through the court's buses from the next callback (`court:mix.main`), and finds
    /// the world's muffle. A tree the records cannot make is said once, and the court mixes
    /// as M30 did.
    pub fn useMix(self: *Sounds, store: *const data.Store, mix: ?MixSet) void {
        self.mix = mix;
        const mixer = self.mixer orelse return;
        const m = mix orelse return;
        mixer.useMix(m.master) catch |err| {
            log.warn("the court's mix {f} is refused ({t}); it mixes with no buses", .{ m.master, err });
            self.mix = null;
            return;
        };
        self.muffle_slot = slotOf(store, m.effects, m.muffle);
        self.muffle_open = filterOf(store, m.muffle);
        if (self.muffle_slot == null or self.muffle_open == null) log.warn("the world bus {f} has no filter {f}; a pause does not muffle it", .{ m.effects, m.muffle });
    }

    /// The three sliders: the master gain, and the music and world buses' own gains, each
    /// ramped over a few milliseconds so a held key does not crackle.
    pub fn applyVolumes(self: *Sounds, options: menus.Options) void {
        const mixer = self.mixer orelse return;
        mixer.setMasterGain(options.volume);
        const m = self.mix orelse return;
        const frames = mixer.info.sample_rate / 50;
        mixer.setBusGain(m.music, options.music, frames);
        mixer.setBusGain(m.effects, options.effects, frames);
    }

    /// A pause sweeps the world's low-pass down to `muffle_frequency`; a resume sweeps it
    /// back to its record's values. Asked once per change.
    pub fn setPaused(self: *Sounds, paused: bool) void {
        if (paused == self.muffled) return;
        self.muffled = paused;
        const mixer = self.mixer orelse return;
        const m = self.mix orelse return;
        const slot = self.muffle_slot orelse return;
        var filter = self.muffle_open orelse return;
        if (paused) filter.frequency = @min(filter.frequency, m.muffle_frequency);
        const frames: u32 = @intFromFloat(@round(m.muffle_fade * @as(f32, @floatFromInt(mixer.info.sample_rate))));
        if (!mixer.setEffectChecked(m.effects, slot, .{ .filter = filter }, frames)) {
            log.warn("the muffle {f} was not changed", .{m.muffle});
            return;
        }
        log.info("the world's low-pass sweeps to {d:.0} Hz over {d:.2} s", .{ filter.frequency, m.muffle_fade });
    }

    /// The events of one tick, heard from where the player now stands.
    pub fn onEvents(self: *Sounds, game: *game_mod.Game) void {
        const set = self.set orelse return;
        const ears = game.walk.eye();
        for (game.tickEvents()) |event| switch (event.kind) {
            .step => _ = self.start(set.step, .{ .gain = 0.5 }),
            .jump => _ = self.start(set.jump, .{ .gain = 0.6 }),
            .land => _ = self.start(set.land, .{ .gain = 0.7 }),
            .beacon => {
                const at = game.beacons[event.beacon].useCentre();
                self.place(game.beacons[event.beacon].settings.sound, .{ .fixed = at }, at, occluded(&game.walk.world, ears, at, null));
            },
            .gate => {
                const g = &(game.gate orelse continue);
                self.place(set.gate, .gate, g.current_pos, occluded(&game.walk.world, ears, g.current_pos, g.body));
            },
            .warden_step => {
                const at = wardenBody(game) orelse event.position;
                self.place(set.warden_step, .warden, at, occluded(&game.walk.world, ears, at, null));
            },
            .won => _ = self.start(set.won, .{}),
            .caught => _ = self.start(set.caught, .{}),
            .fell => _ = self.start(set.fell, .{}),
        };
    }

    fn place(self: *Sounds, sound: core.ContentId, source: Source, at: Vec3, occlusion: f32) void {
        const voice = self.start(sound, .{ .position = at, .occlusion = occlusion });
        if (voice.isNone() or self.placed_len == capacity) return;
        self.placed[self.placed_len] = .{ .voice = voice, .source = source, .occlusion = occlusion };
        self.placed_len += 1;
    }

    pub fn click(self: *Sounds) void {
        const set = self.set orelse return;
        _ = self.start(set.click, .{ .gain = 0.5 });
    }

    /// Once per frame, before the mixer's update: the listener from the walker's eye, each
    /// spatial voice moved to its source and occluded by what is now in the way, and the
    /// ambience from the title onward.
    pub fn frame(self: *Sounds, game: *game_mod.Game) void {
        const mixer = self.mixer orelse return;
        const set = self.set orelse return;
        mixer.setListener(listener(&game.walk));
        const ears = game.walk.eye();
        var i: usize = 0;
        while (i < self.placed_len) {
            const p = &self.placed[i];
            if (!mixer.isPlaying(p.voice)) {
                self.placed[i] = self.placed[self.placed_len - 1];
                self.placed_len -= 1;
                continue;
            }
            const at: Vec3, const ignore = switch (p.source) {
                .fixed => |where| .{ where, null },
                .warden => .{ wardenBody(game) orelse {
                    i += 1;
                    continue;
                }, null },
                .gate => if (game.gate) |*g| .{ g.current_pos, g.body } else {
                    i += 1;
                    continue;
                },
            };
            p.occlusion = approach(p.occlusion, occluded(&game.walk.world, ears, at, ignore));
            mixer.setPosition(p.voice, at);
            mixer.setOcclusion(p.voice, p.occlusion);
            i += 1;
        }
        if (self.ambience.isNone() or !mixer.isPlaying(self.ambience)) {
            self.ambience = self.start(set.ambience, .{ .gain = set.ambience_gain, .looping = true });
        }
    }

    /// Before a content reload retires the sounds, and at shutdown.
    pub fn silence(self: *Sounds) void {
        if (self.mixer) |mixer| mixer.stopAll();
        self.ambience = .none;
        self.placed_len = 0;
    }
};

/// Where the warden is heard from: the middle of its body, not its feet on the ground.
fn wardenBody(game: *const game_mod.Game) ?Vec3 {
    const w = game.warden orelse return null;
    const s = w.settings orelse return null;
    return w.feet.add(.init(0, s.height / 2, 0));
}

/// The slot `effect` holds on bus `bus`, by its record.
pub fn slotOf(store: *const data.Store, bus: core.ContentId, effect: core.ContentId) ?u8 {
    const record = store.lookup(bus) orelse return null;
    if (!record.schema.id.eql(asset.mix.bus.id)) return null;
    const decoded = asset.mix.decodeBus(record.fields) catch return null;
    for (decoded.effects(), 0..) |candidate, k| if (candidate.eql(effect)) return @intCast(k);
    return null;
}

/// `effect`'s record as a filter, or null for anything else.
pub fn filterOf(store: *const data.Store, effect: core.ContentId) ?asset.mix.Filter {
    const record = store.lookup(effect) orelse return null;
    const decoded = asset.mix.decodeEffect(record.schema.id, record.fields) catch return null;
    return switch (decoded) {
        .filter => |f| f,
        else => null,
    };
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

test "sounds: occlusion moves toward the ray's answer by its rate, and settles there" {
    var o: f32 = 0;
    for (0..8) |_| o = approach(o, 1);
    try testing.expectEqual(@as(f32, 1), o);
    o = approach(o, 0);
    try testing.expectApproxEqAbs(@as(f32, 1 - occlusion_rate), o, 1e-6);
    for (0..20) |_| o = approach(o, 0);
    try testing.expectEqual(@as(f32, 0), o);
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
        .won = .fromString("a:g"),
        .caught = .fromString("a:h"),
        .fell = .fromString("a:i"),
        .click = .fromString("a:j"),
    };
    with_set.click();
    try testing.expectEqual(@as(u32, 1), with_set.requested);
    try testing.expectEqual(@as(u32, 1), with_set.dropped);
    try testing.expectEqual(@as(u32, 0), with_set.played);
    // The mix's calls are no-ops without a mixer, and say nothing.
    with_set.applyVolumes(.{});
    with_set.setPaused(true);
    try testing.expect(with_set.muffled);
}
