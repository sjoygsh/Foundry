//! `audio.Music`: playlists, crossfades and stingers, scheduled on the mixer's clock
//! (`docs/design/music.md` §8, ADR-0066).
//!
//! **A game-thread sequencer, beside the mixer it drives, and not privileged.** It turns "this
//! playlist next" into frame-exact scheduled starts and equal-power fades, and "this stinger"
//! into a start on the next beat with a duck around it. It reaches the mixer only through its
//! public game-thread calls (`play` with `start_at`, `fade`, `fadeGainAt`, `clock`,
//! `soundInfo`, `isPlaying`), so a game, and after M48 a mod, could have written it.
//!
//! **Which playlist plays when is the game's choice**, never this file's: the court asks for
//! "chase" when its warden is near, and `Music` never knows why.
//!
//! **Presentation, never simulation.** It schedules against the mixer's clock, which advances
//! with the device, so nothing a tick computes may read it (I9). It reads no wall clock, and
//! shuffles from an explicit seed.
//!
//! **Every start is decided before it is due.** A track is scheduled once the clock is within
//! `lookahead` of where it must begin, so the command and a streamed track's first decode both
//! arrive in time; a resident stinger needs only the command's delivery, and has a shorter
//! lookahead of its own (§8.4, Step 6's Resolution).

const std = @import("std");
const core = @import("core");
const asset = @import("asset");

const mixer_mod = @import("mixer.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const VoiceHandle = mixer_mod.VoiceHandle;
const Playlist = asset.music.Playlist;
const Stinger = asset.music.Stinger;
const log = core.log.scoped(.audio);

pub const Options = struct {
    /// Seeds shuffle: the same seed gives the same order, every run (I9).
    seed: u64 = 0,
    /// How far ahead of the clock a track is scheduled. Null is one second at the device's
    /// rate, which covers a streamed track's first decode behind the background pool's worst
    /// neighbour (`music.md` §6.2).
    lookahead_frames: ?u32 = null,
    /// How far ahead a resident stinger is scheduled: the command's delivery alone. Null is
    /// `stinger_lookahead_seconds` at the device's rate. A streamed stinger takes
    /// `lookahead_frames`.
    stinger_lookahead_frames: ?u32 = null,
};

/// The default resident-stinger lookahead. A command reaches the callback within one buffer
/// (Step 6's Resolution measured the Mac's 512-frame device, 10.7 ms), and this clears that
/// several times over; a streamed track's first decode is what needs the full second.
pub const stinger_lookahead_seconds: f64 = 0.1;

/// What `play` and `stinger` can be refused with: the mixer's, a record's, or an ID that is
/// not one.
pub const Error = mixer_mod.PlayError || asset.music.DecodeError || error{
    /// No `foundry:music_playlist` record has this ID.
    NotAPlaylist,
    /// No `foundry:music_stinger` record has this ID.
    NotAStinger,
};

/// One start `Music` asked for, kept so that its actual frame can be compared
/// (criterion 3): `Mixer.startedAt(voice)` against `frame`.
pub const Start = struct {
    voice: VoiceHandle,
    frame: u64,
    kind: Kind,
    id: ContentId,

    pub const Kind = enum { track, stinger };
};

pub fn MusicOf(comptime M: type) type {
    return struct {
        const Self = @This();

        pub const start_capacity = 64;
        const max_voices = 8;
        const max_deferred = 16;

        gpa: Allocator,
        mixer: *M,
        registry: *asset.Registry,
        rate: u32,
        lookahead: u64,
        stinger_lookahead: u64,
        rng: core.rng.Pcg32,

        /// What `setGain` set: a factor on every playlist's own gain.
        gain: f32 = 1,

        // -- the playing playlist ---------------------------------------------------
        playlist_id: ?ContentId = null,
        playlist: Playlist = .{},
        /// This cycle's order, as indices into `playlist.tracks()`.
        order: [asset.music.max_tracks]u8 = undefined,
        order_len: u8 = 0,
        /// Where in `order` the head track is.
        position: u8 = 0,
        /// The record may have changed: rebuild the order at the next boundary.
        stale: bool = false,
        /// The last track scheduled: the one every later decision is relative to.
        head: ?Head = null,
        /// The playlist has no more tracks; the head plays out.
        ended: bool = false,

        /// Every music voice that may still sound, for gain changes and ducks.
        voices: [max_voices]?MusicVoice = @splat(null),
        /// Level ramps waiting for the ramp before them to begin, so they do not replace it in
        /// the voice's one queued slot (`voice.Ramp`).
        deferred: [max_deferred]?Deferred = @splat(null),
        duck: ?Duck = null,

        /// Playlists left with `resume` set, most recent first replacing the oldest.
        resumes: [max_resumes]?Resume = @splat(null),

        /// The last `start_capacity` starts, oldest overwritten; `start_count` counts them all.
        start_ring: [start_capacity]Start = undefined,
        start_count: u64 = 0,

        const Head = struct {
            voice: VoiceHandle,
            track: ContentId,
            start: u64,
            /// Device frames it plays for from `start`; unbounded for a looping track.
            frames: u64,
            /// The source frame it began on: 0, or where a resumed playlist left it.
            start_frame: u64 = 0,
            /// Source frames per device frame.
            step: f64 = 1,
        };

        /// Where a `resume` playlist was left (`mixing.md` §10.2).
        const Resume = struct {
            playlist: ContentId,
            order: [asset.music.max_tracks]u8,
            order_len: u8,
            position: u8,
            /// The source frame of `order[position]`'s track to start on.
            frame: u64,
        };
        const max_resumes = 8;

        const MusicVoice = struct {
            handle: VoiceHandle,
            /// The playlist's gain the voice was started under.
            base: f32,
        };

        const Deferred = struct {
            /// Sent once the clock has passed this frame.
            after: u64,
            handle: VoiceHandle,
            at: u64,
            /// The playlist's gain; the music's own is applied when the ramp is sent, so a
            /// `setGain` during a duck is not undone by its release.
            base: f32,
            frames: u32,
        };

        const Duck = struct {
            factor: f32,
            /// The music is back to full level from here.
            until: u64,
            frames: u32,
        };

        pub fn init(gpa: Allocator, mixer: *M, registry: *asset.Registry, options: Options) Self {
            const rate = mixer.info.sample_rate;
            const stinger_default: u64 = @intFromFloat(@ceil(stinger_lookahead_seconds * @as(f64, @floatFromInt(rate))));
            return .{
                .gpa = gpa,
                .mixer = mixer,
                .registry = registry,
                .rate = rate,
                .lookahead = options.lookahead_frames orelse rate,
                .stinger_lookahead = options.stinger_lookahead_frames orelse stinger_default,
                .rng = .init(options.seed, 0x6d75_7369_63),
            };
        }

        /// Fades whatever still plays out over a tenth of a second, so tearing the sequencer
        /// down mid-track does not click.
        pub fn deinit(self: *Self) void {
            self.stop(0.1);
            self.* = undefined;
        }

        // -- the game's calls -----------------------------------------------------

        /// Plays `id`'s first track, crossfading from whatever plays now with `id`'s
        /// crossfade. With music playing under a tempo the switch lands on its next bar line,
        /// otherwise one lookahead from now (§8.3). The playlist already playing does nothing.
        pub fn play(self: *Self, id: ContentId) Error!void {
            if (self.playlist_id) |playing| if (playing.eql(id) and !self.ended) return;
            const value = try self.readPlaylist(id);
            const now = self.mixer.clock();

            // Where it was left, for a `resume` playlist that was; its first track otherwise.
            var order: [asset.music.max_tracks]u8 = undefined;
            var order_len: u8 = undefined;
            var position: u8 = 0;
            var start_frame: u64 = 0;
            if (value.resumes) if (self.takeResume(id, &value)) |saved| {
                order = saved.order;
                order_len = saved.order_len;
                position = saved.position;
                start_frame = saved.frame;
            };
            if (position == 0 and start_frame == 0) order_len = self.newCycle(&value, &order, null);
            const track = value.tracks()[order[position]];
            const info = try self.mixer.soundInfo(track);
            const cf = self.seconds(value.crossfade);

            var at = now + self.lookahead;
            if (self.head) |head| {
                at = @max(at, head.start);
                if (self.gridPoint(head, self.playlist.beats_per_bar, at)) |bar| at = @min(bar, head.start +| head.frames);
                self.leave(head, at);
            }
            const looping = loopsAsOne(&value, info);
            const frames = remaining(info, start_frame, looping);
            const fade_in = cf > 0 and frames >= 2 * cf;
            const handle = try self.startTrack(track, at, value.gain, fade_in, start_frame, looping);
            if (fade_in) self.mixer.fade(handle, .{ .at = at, .frames = @intCast(cf), .to = 1, .curve = .equal_power });
            // The old head gives way on the same frame, over the new playlist's crossfade.
            if (self.head) |head| {
                self.mixer.fade(head.voice, .{ .at = at, .frames = if (fade_in) @intCast(cf) else 0, .to = 0, .curve = .equal_power, .stop = true });
            }

            self.playlist_id = id;
            self.playlist = value;
            self.order = order;
            self.order_len = order_len;
            self.position = position;
            self.stale = false;
            self.ended = false;
            self.head = .{ .voice = handle, .track = track, .start = at, .frames = frames, .start_frame = start_frame, .step = info.step };
        }

        /// A single looping track with a loop region plays as one looping voice, its intro once
        /// and its body for as long as it lasts (§10.1).
        fn loopsAsOne(value: *const Playlist, info: M.SoundInfo) bool {
            return value.loop and value.track_count == 1 and info.loops;
        }

        /// Device frames a track plays for from `start_frame`: unbounded when it loops.
        fn remaining(info: M.SoundInfo, start_frame: u64, looping: bool) u64 {
            if (looping) return std.math.maxInt(u64);
            if (start_frame == 0) return info.frames;
            const left: f64 = @floatFromInt(info.source_frames -| start_frame);
            return @intFromFloat(@ceil(left / info.step));
        }

        /// Records where the playing playlist is being left at frame `at`, if it resumes:
        /// the head's track at the source frame it will have reached (§10.2). A track already
        /// played out resumes at the next one.
        fn leave(self: *Self, head: Head, at: u64) void {
            const id = self.playlist_id orelse return;
            if (!self.playlist.resumes or self.ended) return;
            const elapsed: f64 = @floatFromInt(at -| head.start);
            var frame = head.start_frame + @as(u64, @intFromFloat(elapsed * head.step));
            var position = self.position;
            const looping = head.frames == std.math.maxInt(u64);
            const source_end = head.start_frame + @as(u64, @intFromFloat(@as(f64, @floatFromInt(head.frames)) * head.step));
            if (!looping and frame >= source_end) {
                frame = 0;
                position = if (position + 1 >= self.order_len) 0 else position + 1;
            }
            const saved: Resume = .{ .playlist = id, .order = self.order, .order_len = self.order_len, .position = position, .frame = frame };
            for (&self.resumes) |*slot| if (slot.*) |r| if (r.playlist.eql(id)) {
                slot.* = saved;
                return;
            };
            // The oldest makes room: shift everything down one, newest first.
            var i: usize = max_resumes - 1;
            while (i > 0) : (i -= 1) self.resumes[i] = self.resumes[i - 1];
            self.resumes[0] = saved;
        }

        /// The saved point for `id`, removed, if it still fits the playlist as it now reads.
        fn takeResume(self: *Self, id: ContentId, value: *const Playlist) ?Resume {
            for (&self.resumes) |*slot| if (slot.*) |r| if (r.playlist.eql(id)) {
                slot.* = null;
                if (r.order_len != value.track_count or r.position >= r.order_len) return null;
                return r;
            };
            return null;
        }

        /// Fades every music voice out over `fade_seconds` from the next callback, and forgets
        /// the playlist. Stingers already playing finish.
        pub fn stop(self: *Self, fade_seconds: f32) void {
            if (self.head) |head| self.leave(head, self.mixer.clock());
            const frames: u32 = @intCast(self.seconds(fade_seconds));
            for (&self.voices) |*slot| if (slot.*) |v| {
                self.mixer.fade(v.handle, .{ .frames = frames, .to = 0, .stop = true });
                slot.* = null;
            };
            self.deferred = @splat(null);
            self.duck = null;
            self.playlist_id = null;
            self.head = null;
            self.ended = false;
        }

        /// Plays a stinger at the next point its `quantize` names on the head track's grid,
        /// with the music ducked beneath it (§8.4). With no music, or no tempo, it plays one
        /// lookahead from now.
        pub fn stinger(self: *Self, id: ContentId) Error!void {
            const value = try self.readStinger(id);
            const info = try self.mixer.soundInfo(value.sound);
            const now = self.mixer.clock();
            const earliest = now + if (info.streamed) self.lookahead else self.stinger_lookahead;

            var at = earliest;
            if (self.head) |head| {
                const beats: ?u32 = switch (value.quantize) {
                    .now => null,
                    .beat => 1,
                    .bar => self.playlist.beats_per_bar,
                };
                if (beats) |n| if (self.gridPoint(head, n, earliest)) |point| {
                    at = point;
                };
            }
            const handle = try self.mixer.play(value.sound, .{ .start_at = at, .gain = value.gain });
            self.record(.{ .voice = handle, .frame = at, .kind = .stinger, .id = value.sound });

            if (value.duck >= 1) return;
            const frames: u32 = @intCast(self.seconds(value.duck_fade));
            const down = at -| frames;
            const until = at + info.frames;
            self.duck = .{ .factor = value.duck, .until = @max(until, if (self.duck) |d| d.until else 0), .frames = frames };
            for (&self.voices) |*slot| if (slot.*) |v| {
                self.mixer.fadeGainAt(v.handle, down, v.base * self.gain * value.duck, frames);
                self.release(v.handle, down, self.duck.?.until, v.base, frames);
            };
        }

        /// Ramps every music voice's level to `gain` times its playlist's over
        /// `fade_seconds`: the court's pause duck.
        pub fn setGain(self: *Self, gain: f32, fade_seconds: f32) void {
            self.gain = gain;
            const frames: u32 = @intCast(self.seconds(fade_seconds));
            const now = self.mixer.clock();
            const factor = self.duckAt(now);
            for (self.voices) |slot| if (slot) |v| {
                self.mixer.fadeGain(v.handle, v.base * gain * factor, frames);
                // This ramp takes the voice's one queued slot, which may hold a duck's release:
                // queue the release again, behind it.
                if (self.duck) |d| if (factor < 1) self.release(v.handle, now, d.until, v.base, d.frames);
            };
        }

        /// Once per frame, after `Mixer.update`: schedules the next track when its boundary is
        /// within the lookahead, and sends level ramps that were waiting their turn.
        pub fn update(self: *Self) void {
            const now = self.mixer.clock();
            for (&self.voices) |*slot| if (slot.*) |v| {
                if (!self.mixer.isPlaying(v.handle)) slot.* = null;
            };
            for (&self.deferred) |*slot| if (slot.*) |d| if (now > d.after) {
                self.mixer.fadeGainAt(d.handle, d.at, d.base * self.gain, d.frames);
                slot.* = null;
            };
            if (self.duck) |d| if (now >= d.until) {
                self.duck = null;
            };

            const head = self.head orelse return;
            if (self.ended or self.playlist_id == null) return;
            const cf = self.seconds(self.playlist.crossfade);
            // A looping head's end is unbounded, so nothing follows it until a switch.
            const end = head.start +| head.frames;
            const earliest = if (cf > 0 and head.frames >= 2 * cf) end - cf else end;
            if (now + self.lookahead < earliest) return;
            self.advance(head) catch |err| {
                log.warn("music: the next track could not start ({t}); the playlist ends here", .{err});
                self.ended = true;
            };
        }

        /// A reload may have changed a record: the playlist is re-read at the next track
        /// boundary, and a changed track list starts a new cycle of the new list there. A
        /// playing track is never cut (§8.5). Stingers are read at every `stinger` call.
        pub fn contentChanged(self: *Self) void {
            self.stale = true;
        }

        /// The starts asked for, oldest first: at most `start_capacity`, the most recent.
        pub fn starts(self: *const Self, out: *[start_capacity]Start) []const Start {
            const n: usize = @intCast(@min(self.start_count, start_capacity));
            const first = self.start_count - n;
            for (0..n) |i| out[i] = self.start_ring[@intCast((first + i) % start_capacity)];
            return out[0..n];
        }

        pub fn startCount(self: *const Self) u64 {
            return self.start_count;
        }

        /// The playlist playing, if any.
        pub fn current(self: *const Self) ?ContentId {
            return if (self.ended) null else self.playlist_id;
        }

        // -- arithmetic -----------------------------------------------------------

        fn seconds(self: *const Self, s: f32) u64 {
            if (!(s > 0)) return 0;
            return @intFromFloat(@round(@as(f64, s) * @as(f64, @floatFromInt(self.rate))));
        }

        /// The first point at or after `from` on the head track's grid of `beats` beats:
        /// `start + first_beat + n · beats · 60 / tempo` seconds, as a frame. Null with no tempo.
        fn gridPoint(self: *const Self, head: Head, beats: u32, from: u64) ?u64 {
            const p = self.playlist;
            if (p.tempo <= 0) return null;
            const rate: f64 = @floatFromInt(self.rate);
            const period = @as(f64, @floatFromInt(beats)) * 60.0 / @as(f64, p.tempo) * rate;
            // A track resumed part-way began `start_frame / step` device frames into itself, so its
            // beat one fell that long before `start`.
            const into = @as(f64, @floatFromInt(head.start_frame)) / head.step;
            const offset = @as(f64, p.first_beat) * rate - into;
            const since: f64 = if (from > head.start) @floatFromInt(from - head.start) else 0;
            var n = @max(0, @ceil((since - offset) / period));
            while (true) : (n += 1) {
                const at = offset + n * period;
                if (at < 0) continue;
                const point = head.start + @as(u64, @intFromFloat(@round(at)));
                if (point >= from) return point;
            }
        }

        /// The duck's factor on the level of a voice starting at `frame`.
        fn duckAt(self: *const Self, frame: u64) f32 {
            const d = self.duck orelse return 1;
            return if (frame < d.until) d.factor else 1;
        }

        // -- scheduling -----------------------------------------------------------

        /// Schedules the head's successor: on the head's crossfade boundary when both tracks
        /// are at least twice the crossfade, otherwise at the head's end with no fade.
        fn advance(self: *Self, head: Head) Error!void {
            // A reload since the last boundary: the record is read again here, and a new track
            // list starts a new cycle of it. The track playing is never cut (§8.5).
            var restart = false;
            if (self.stale) {
                self.stale = false;
                if (self.readPlaylist(self.playlist_id.?)) |value| {
                    restart = !sameTracks(&value, &self.playlist);
                    self.playlist = value;
                } else |err| {
                    log.warn("music: the playlist record no longer reads ({t}); it plays as it was", .{err});
                }
            }

            var position: usize = @as(usize, self.position) + 1;
            if (restart or position >= self.order_len) {
                if (!self.playlist.loop and !restart) {
                    self.ended = true;
                    return;
                }
                self.order_len = self.newCycle(&self.playlist, &self.order, head.track);
                position = 0;
            }
            const track = self.playlist.tracks()[self.order[position]];
            const info = try self.mixer.soundInfo(track);
            const cf = self.seconds(self.playlist.crossfade);
            const crossfade = cf > 0 and head.frames >= 2 * cf and info.frames >= 2 * cf;
            const at = if (crossfade) head.start + head.frames - cf else head.start + head.frames;

            const handle = try self.startTrack(track, at, self.playlist.gain, crossfade, 0, false);
            if (crossfade) {
                self.mixer.fade(handle, .{ .at = at, .frames = @intCast(cf), .to = 1, .curve = .equal_power });
                self.mixer.fade(head.voice, .{ .at = at, .frames = @intCast(cf), .to = 0, .curve = .equal_power, .stop = true });
            }
            self.position = @intCast(position);
            self.head = .{ .voice = handle, .track = track, .start = at, .frames = info.frames, .step = info.step };
        }

        /// Starts a track at `at`, silent if it is to fade in, at its level under any duck.
        fn startTrack(self: *Self, track: ContentId, at: u64, base: f32, fade_in: bool, start_frame: u64, looping: bool) Error!VoiceHandle {
            const factor = self.duckAt(at);
            const handle = try self.mixer.play(track, .{
                .start_at = at,
                .gain = base * self.gain * factor,
                .envelope = if (fade_in) 0 else 1,
                .start_frame = start_frame,
                .looping = looping,
            });
            self.record(.{ .voice = handle, .frame = at, .kind = .track, .id = track });
            for (&self.voices) |*slot| if (slot.* == null) {
                slot.* = .{ .handle = handle, .base = base };
                break;
            } else if (slot == &self.voices[max_voices - 1]) {
                log.warn("music: more than {d} music voices at once; the oldest ignores gain changes", .{max_voices});
            };
            if (self.duck) |d| if (factor < 1) self.release(handle, at, d.until, base, d.frames);
            return handle;
        }

        /// Queues the ramp back up from a duck, to be sent once the ramp down has begun.
        fn release(self: *Self, handle: VoiceHandle, after: u64, at: u64, base: f32, frames: u32) void {
            for (&self.deferred) |*slot| if (slot.*) |d| if (d.handle.eql(handle)) {
                slot.* = null;
            };
            for (&self.deferred) |*slot| if (slot.* == null) {
                slot.* = .{ .after = after, .handle = handle, .at = at, .base = base, .frames = frames };
                return;
            };
            log.warn("music: too many ducks at once; one voice stays ducked", .{});
        }

        /// A new cycle's order. Shuffle is Fisher–Yates from the seeded generator, and a first
        /// track that would repeat `last` swaps with the cycle's last (§8.2).
        fn newCycle(self: *Self, value: *const Playlist, order: *[asset.music.max_tracks]u8, last: ?ContentId) u8 {
            const n = value.track_count;
            for (0..n) |i| order[i] = @intCast(i);
            if (value.order == .shuffle and n > 1) {
                var i: u32 = n - 1;
                while (i > 0) : (i -= 1) {
                    const j = self.rng.below(i + 1);
                    std.mem.swap(u8, &order[i], &order[j]);
                }
                if (last) |previous| if (value.tracks()[order[0]].eql(previous)) {
                    std.mem.swap(u8, &order[0], &order[n - 1]);
                };
            }
            return n;
        }

        fn record(self: *Self, start: Start) void {
            self.start_ring[@intCast(self.start_count % start_capacity)] = start;
            self.start_count += 1;
        }

        // -- records --------------------------------------------------------------

        fn readPlaylist(self: *Self, id: ContentId) Error!Playlist {
            const record_ = self.registry.store.lookup(id) orelse return error.NotAPlaylist;
            if (!record_.schema_id.eql(asset.music.playlist.id)) return error.NotAPlaylist;
            const value = asset.music.decodePlaylist(record_.fields) catch |err| {
                log.warn("music playlist '{s}' {s}", .{ record_.name, asset.music.describe(err) });
                return err;
            };
            asset.music.checkTracks(&value, self.registry.store, asset.schemas.sound.id) catch |err| {
                log.warn("music playlist '{s}' {s}", .{ record_.name, asset.music.describe(err) });
                return err;
            };
            return value;
        }

        fn readStinger(self: *Self, id: ContentId) Error!Stinger {
            const record_ = self.registry.store.lookup(id) orelse return error.NotAStinger;
            if (!record_.schema_id.eql(asset.music.stinger.id)) return error.NotAStinger;
            const value = asset.music.decodeStinger(record_.fields) catch |err| {
                log.warn("music stinger '{s}' {s}", .{ record_.name, asset.music.describe(err) });
                return err;
            };
            asset.music.checkSound(value.sound, self.registry.store, asset.schemas.sound.id) catch |err| {
                log.warn("music stinger '{s}' {s}", .{ record_.name, asset.music.describe(err) });
                return err;
            };
            return value;
        }
    };
}

fn sameTracks(a: *const Playlist, b: *const Playlist) bool {
    if (a.track_count != b.track_count) return false;
    for (a.tracks(), b.tracks()) |x, y| if (!x.eql(y)) return false;
    return true;
}

pub const Music = MusicOf(mixer_mod.Mixer);
