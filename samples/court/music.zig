//! What the court's music does (music.md §9): which playlist plays in which phase, the
//! chase while the warden is close, the stingers, the pause duck, and the ending.
//!
//! Music is presentation, as sound is (`sounds.zig`). It reads the game's phase, positions
//! and tick events, and the game never reads anything here (I9). What plays is content:
//! `court:music.main` names the playlists and stingers, and a mod overriding them changes
//! the music with no code.
//!
//! `FOUNDRY_COURT_MUSIC_LOG=on` writes the evidence criteria 2 and 3 read: every start the
//! sequencer asked for, with the frame it asked and the frame the mixer reports it began on,
//! and the counters every ten seconds and at exit.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const audio = @import("audio");
const game_mod = @import("game.zig");

const Fields = data.fpk.Fields;
const log = core.log.scoped(.court);

pub const MusicSet = struct {
    title: core.ContentId,
    calm: core.ContentId,
    chase: core.ContentId,
    beacon: core.ContentId,
    gate: core.ContentId,
    ending: core.ContentId,
    chase_distance: f32,
    chase_hold: f32,
    pause_gain: f32,
    pause_fade: f32,
    ending_fade: f32,

    pub const record_id = "court:music.main";

    pub fn read(fields: Fields) error{InvalidMusic}!MusicSet {
        return .{
            .title = try id(fields, "title"),
            .calm = try id(fields, "calm"),
            .chase = try id(fields, "chase"),
            .beacon = try id(fields, "beacon"),
            .gate = try id(fields, "gate"),
            .ending = try id(fields, "ending"),
            .chase_distance = try bounded(fields, "chase_distance", 0.5, 1000),
            .chase_hold = try bounded(fields, "chase_hold", 0, 60),
            .pause_gain = try bounded(fields, "pause_gain", 0, 1),
            .pause_fade = try bounded(fields, "pause_fade", 0, 10),
            .ending_fade = try bounded(fields, "ending_fade", 0, 30),
        };
    }

    /// The set a store holds, or null with one log line.
    pub fn find(store: *const data.Store) ?MusicSet {
        const record = store.lookup(core.ContentId.fromString(record_id)) orelse {
            log.warn("missing '{s}'; the court has no music", .{record_id});
            return null;
        };
        if (!record.schema.id.eql(data.SchemaId.fromStringUnchecked("court:music_set"))) {
            log.warn("'{s}' is not a 'court:music_set'; the court has no music", .{record_id});
            return null;
        }
        return read(record.fields) catch {
            log.warn("invalid '{s}'; the court has no music", .{record_id});
            return null;
        };
    }
};

fn index(fields: Fields, name: []const u8) error{InvalidMusic}!u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return error.InvalidMusic;
}

fn id(fields: Fields, name: []const u8) error{InvalidMusic}!core.ContentId {
    const value = (fields.idAt(try index(fields, name)) catch return error.InvalidMusic) orelse return error.InvalidMusic;
    if (value.isNone()) return error.InvalidMusic;
    return value;
}

fn bounded(fields: Fields, name: []const u8, min: f32, max: f32) error{InvalidMusic}!f32 {
    const raw = (fields.floatAt(try index(fields, name)) catch return error.InvalidMusic) orelse return error.InvalidMusic;
    const value: f32 = @floatCast(raw);
    if (!std.math.isFinite(value) or value < min or value > max) return error.InvalidMusic;
    return value;
}

/// The playlist a phase asks for, or null for silence: the endings have stopped the music,
/// and a pause keeps whatever was playing, ducked.
pub fn wanted(set: MusicSet, phase: game_mod.Phase, chasing: bool) ?core.ContentId {
    return switch (phase) {
        .title => set.title,
        .playing => if (chasing) set.chase else set.calm,
        .paused, .won, .caught, .fell => null,
    };
}

/// Whether the warden is within `distance` of the player on the ground, height aside.
pub fn wardenNear(game: *const game_mod.Game, distance: f32) bool {
    const warden = game.warden orelse return false;
    var delta = warden.feet.sub(game.walk.result.feet);
    delta.y = 0;
    return delta.length() <= distance;
}

/// The sequencer's asked starts, checked against the frames the mixer reports.
pub const Evidence = struct {
    const capacity = audio.Music.start_capacity;

    pending: [capacity]audio.MusicStart = undefined,
    pending_len: usize = 0,
    /// Starts taken from the sequencer so far: its `startCount`.
    seen: u64 = 0,
    asked: u64 = 0,
    /// Reported by the mixer on the frame asked for.
    exact: u64 = 0,
    /// Reported on a different frame: a start that missed. Criterion 3 requires none.
    missed: u64 = 0,
    /// Retired before they began, as a stop retires a track scheduled behind the one
    /// fading out. Not a miss: nothing was heard late.
    cancelled: u64 = 0,
    /// Starts the ring had overwritten before they were read. A run requires none.
    lost: u64 = 0,

    /// Nothing missed or lost, and the mixer's and the game's counts of trouble all zero.
    pub fn clean(self: *const Evidence, underruns: u32, late_starts: u32, refused: u32) bool {
        return self.missed == 0 and self.lost == 0 and underruns == 0 and late_starts == 0 and refused == 0;
    }

    /// Once per frame, after the mixer's and the sequencer's updates. `music` is an
    /// `audio.MusicOf(M)` over `mixer`, an `M`.
    pub fn check(self: *Evidence, music: anytype, mixer: anytype, verbose: bool) void {
        const count = music.startCount();
        if (count > self.seen) {
            var ring: [capacity]audio.MusicStart = undefined;
            const all = music.starts(&ring);
            const fresh: usize = @intCast(@min(count - self.seen, all.len));
            self.lost += count - self.seen - fresh;
            for (all[all.len - fresh ..]) |start| {
                self.asked += 1;
                if (self.pending_len == capacity) {
                    self.lost += 1;
                    continue;
                }
                self.pending[self.pending_len] = start;
                self.pending_len += 1;
            }
            self.seen = count;
        }
        var i: usize = 0;
        while (i < self.pending_len) {
            const start = self.pending[i];
            if (mixer.startedAt(start.voice)) |actual| {
                if (actual == start.frame) self.exact += 1 else self.missed += 1;
                if (verbose or actual != start.frame) log.info("music: {t} {f} asked frame {d}, began on {d}", .{ start.kind, start.id, start.frame, actual });
            } else if (!mixer.isPlaying(start.voice)) {
                self.cancelled += 1;
                if (verbose) log.info("music: {t} {f} asked frame {d}, retired before it began", .{ start.kind, start.id, start.frame });
            } else {
                i += 1;
                continue;
            }
            self.pending[i] = self.pending[self.pending_len - 1];
            self.pending_len -= 1;
        }
    }
};

/// The court's music over one mixer. Without a mixer or a music set every call does
/// nothing, so the game plays the same in silence.
pub const Soundtrack = struct {
    music: ?audio.Music = null,
    mixer: ?*audio.Mixer = null,
    set: ?MusicSet = null,
    /// The playlist last asked for, so a frame asks again only when the answer changes.
    asked: ?core.ContentId = null,
    paused: bool = false,
    /// The last playing tick at which the warden was within `chase_distance`.
    near_tick: ?u64 = null,
    hold_ticks: u64 = 0,
    /// Calls the sequencer refused. A scripted run asserts this is zero.
    refused: u32 = 0,
    evidence: Evidence = .{},
    verbose: bool = false,

    pub fn init(gpa: std.mem.Allocator, mixer: ?*audio.Mixer, registry: *asset.Registry, set: ?MusicSet, tick_seconds: f32, verbose: bool) Soundtrack {
        const m = mixer orelse return .{};
        const s = set orelse return .{ .mixer = m };
        return .{
            .music = audio.Music.init(gpa, m, registry, .{}),
            .mixer = m,
            .set = s,
            .hold_ticks = @intFromFloat(@ceil(s.chase_hold / tick_seconds)),
            .verbose = verbose,
        };
    }

    pub fn deinit(self: *Soundtrack) void {
        if (self.music) |*music| music.deinit();
        self.music = null;
    }

    fn refuse(self: *Soundtrack, what: []const u8, target: core.ContentId, err: anyerror) void {
        self.refused += 1;
        log.warn("music: {s} {f} refused ({t})", .{ what, target, err });
    }

    /// The events of one tick: a beacon's and the gate's stingers, and an ending's.
    pub fn onEvents(self: *Soundtrack, game: *const game_mod.Game) void {
        const music = if (self.music) |*m| m else return;
        const set = self.set.?;
        // Only a game in play is chased: the warden walks on the title screen too.
        if (game.phase == .playing and wardenNear(game, set.chase_distance)) self.near_tick = game.tick;
        for (game.tickEvents()) |event| switch (event.kind) {
            .beacon => music.stinger(set.beacon) catch |err| self.refuse("stinger", set.beacon, err),
            .gate => music.stinger(set.gate) catch |err| self.refuse("stinger", set.gate, err),
            .won, .caught, .fell => {
                // The ending takes its beat from the music before the music goes.
                music.stinger(set.ending) catch |err| self.refuse("stinger", set.ending, err);
                music.stop(set.ending_fade);
                self.asked = null;
                self.near_tick = null;
            },
            else => {},
        };
    }

    /// Whether the chase plays at `tick`: the warden close now, or within the hold.
    pub fn chasing(self: *const Soundtrack, tick: u64) bool {
        const near = self.near_tick orelse return false;
        return tick -| near <= self.hold_ticks;
    }

    /// Once per frame, after the mixer's update: the sequencer's own update, timed with the
    /// mixer's by the caller, comes first (`update`); then the phase's playlist and duck.
    pub fn update(self: *Soundtrack) void {
        if (self.music) |*music| music.update();
    }

    pub fn frame(self: *Soundtrack, game: *const game_mod.Game) void {
        const music = if (self.music) |*m| m else return;
        const set = self.set.?;
        const pause = game.phase == .paused;
        if (pause != self.paused) {
            self.paused = pause;
            music.setGain(if (pause) set.pause_gain else 1, set.pause_fade);
        }
        if (wanted(set, game.phase, self.chasing(game.tick))) |playlist| {
            const same = if (self.asked) |a| a.eql(playlist) else false;
            if (!same) {
                self.asked = playlist;
                music.play(playlist) catch |err| self.refuse("playlist", playlist, err);
            }
        }
        self.evidence.check(music, self.mixer.?, self.verbose);
    }

    /// The counters, as one line.
    pub fn report(self: *const Soundtrack, when: []const u8) void {
        const mixer = self.mixer orelse return;
        const e = self.evidence;
        log.info("music {s}: {d} start(s) asked, {d} on their frame, {d} missed, {d} retired before they began, {d} unread, {d} pending; {d} underrun(s), {d} late start(s), {d} command(s) dropped, {d} refused", .{
            when, e.asked, e.exact, e.missed, e.cancelled, e.lost, e.pending_len, mixer.underruns(), mixer.lateStarts(), mixer.commandsDropped(), self.refused,
        });
    }

    /// What criteria 2 and 3 require of a run: nothing missed, lost, late, underrun or
    /// refused.
    pub fn clean(self: *const Soundtrack) bool {
        const mixer = self.mixer orelse return true;
        return self.evidence.clean(mixer.underruns(), mixer.lateStarts(), self.refused);
    }
};

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

fn testSet() MusicSet {
    return .{
        .title = .fromString("t:title"),
        .calm = .fromString("t:calm"),
        .chase = .fromString("t:chase"),
        .beacon = .fromString("t:beacon"),
        .gate = .fromString("t:gate"),
        .ending = .fromString("t:ending"),
        .chase_distance = 3,
        .chase_hold = 2,
        .pause_gain = 0.3,
        .pause_fade = 0.25,
        .ending_fade = 1,
    };
}

test "music: each phase asks for its playlist, and a pause or an ending asks for none" {
    const set = testSet();
    try testing.expect(wanted(set, .title, false).?.eql(set.title));
    try testing.expect(wanted(set, .playing, false).?.eql(set.calm));
    try testing.expect(wanted(set, .playing, true).?.eql(set.chase));
    for ([_]game_mod.Phase{ .paused, .won, .caught, .fell }) |phase| try testing.expectEqual(@as(?core.ContentId, null), wanted(set, phase, true));
}

test "music: without a mixer or a set the soundtrack does nothing and is clean" {
    var registry: asset.Registry = undefined;
    var none = Soundtrack.init(testing.allocator, null, &registry, testSet(), 1.0 / 60.0, false);
    defer none.deinit();
    try testing.expect(none.music == null);
    try testing.expect(none.clean());
}

test "music: the chase lasts its hold past the last tick the warden was near" {
    var track: Soundtrack = .{ .hold_ticks = 120 };
    try testing.expect(!track.chasing(100));
    track.near_tick = 100;
    try testing.expect(track.chasing(100));
    try testing.expect(track.chasing(220));
    try testing.expect(!track.chasing(221));
    // A restart's tick counts from zero again; a stale near tick is not a chase forever.
    try testing.expect(track.chasing(0));
}

test "music: a run is clean only with nothing missed, lost, underrun, late or refused" {
    const fine: Evidence = .{ .asked = 3, .exact = 2, .cancelled = 1 };
    try testing.expect(fine.clean(0, 0, 0));
    try testing.expect(!fine.clean(1, 0, 0));
    try testing.expect(!fine.clean(0, 1, 0));
    try testing.expect(!fine.clean(0, 0, 1));
    try testing.expect(!(Evidence{ .missed = 1 }).clean(0, 0, 0));
    try testing.expect(!(Evidence{ .lost = 1 }).clean(0, 0, 0));
}
