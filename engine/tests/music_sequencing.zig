//! `audio.Music` over real content: playlists and stingers as records, tracks as sounds, on the
//! null backend's stepped device with immediate tasks (`docs/design/music.md` §8, §12).
//!
//! What only this level can test is that the sequencer and the records compose: a playlist's
//! tracks resolve through the store, a sound's length comes back through the mixer's loader,
//! and an override replacing a record is read at the next boundary. Every scheduled start is
//! checked against arithmetic written out here, independently of `Music`'s, and against the
//! frame the mixer reports it actually started on.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const asset = @import("asset");
const audio = @import("audio");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;

const null_backend = platform.null_backend;
const Mixer = audio.MixerOf(null_backend.Platform);
const Music = audio.MusicOf(Mixer);

const rate = 48_000;
const buffer = 256;

/// A mono 16-bit WAV of `frames` frames: a sawtooth whose period is `period`, so each track
/// sounds, and hashes, like itself.
fn wavBytes(gpa: Allocator, frames: u32, period: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const w = struct {
        fn int(g: Allocator, o: *std.ArrayList(u8), comptime T: type, value: T) !void {
            var bytes: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, .little);
            try o.appendSlice(g, &bytes);
        }
    };
    try out.appendSlice(gpa, "RIFF");
    try w.int(gpa, &out, u32, 36 + frames * 2);
    try out.appendSlice(gpa, "WAVEfmt ");
    try w.int(gpa, &out, u32, 16);
    try w.int(gpa, &out, u16, 1);
    try w.int(gpa, &out, u16, 1);
    try w.int(gpa, &out, u32, rate);
    try w.int(gpa, &out, u32, rate * 2);
    try w.int(gpa, &out, u16, 2);
    try w.int(gpa, &out, u16, 16);
    try out.appendSlice(gpa, "data");
    try w.int(gpa, &out, u32, frames * 2);
    for (0..frames) |i| {
        // A period of 0 is silence.
        if (period == 0) {
            try w.int(gpa, &out, i16, 0);
            continue;
        }
        const phase: i32 = @intCast(i % period);
        const value = @divTrunc((phase * 2 - @as(i32, @intCast(period))) * 12_000, @as(i32, @intCast(period)));
        try w.int(gpa, &out, i16, @intCast(value));
    }
    return out.toOwnedSlice(gpa);
}

const Stack = struct {
    gpa: Allocator,
    os: *platform.os.Os,
    plat: *null_backend.Platform,
    tmp: std.testing.TmpDir,
    dir: []u8,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    packages: std.ArrayList([]u8) = .empty,
    assets: asset.Registry,
    mixer: *Mixer,

    fn init() !*Stack {
        const gpa = testing.allocator;
        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-music", .env = &.{} });
        errdefer os.deinit();
        const plat = try null_backend.Platform.init(gpa, .{});
        errdefer plat.deinit();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(testing.io, &path_buf);
        const dir = try platform.os.joinPath(gpa, &.{ path_buf[0..path_len], "foundry-music" });
        errdefer gpa.free(dir);

        const self = try gpa.create(Stack);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .os = os,
            .tmp = tmp,
            .plat = plat,
            .dir = dir,
            .schemas = .init(gpa, .default),
            .diags = .init(gpa, .default),
            .store = .init(gpa, .default),
            .assets = undefined,
            .mixer = undefined,
        };
        self.assets = .init(gpa, os, &self.store, .{});
        self.mixer = try Mixer.init(gpa, plat, &self.assets, .{ .channels = 1, .sample_rate = rate, .buffer_frames = buffer });
        try asset.schemas.registerAll(gpa, &self.schemas);
        try asset.music.registerAll(gpa, &self.schemas);
        try self.assets.registerLoader(gpa, self.mixer.soundLoader());
        return self;
    }

    fn deinit(self: *Stack) void {
        self.mixer.shutdown();
        self.assets.deinit(self.gpa);
        self.mixer.deinit();
        self.plat.deinit();
        self.store.deinit(self.gpa);
        self.schemas.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        for (self.packages.items) |bytes| self.gpa.free(bytes);
        self.packages.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.os.deinit();
        self.tmp.cleanup();
        self.gpa.destroy(self);
    }

    fn writeWav(self: *Stack, rel: []const u8, frames: u32, period: u32) !void {
        const bytes = try wavBytes(self.gpa, frames, period);
        defer self.gpa.free(bytes);
        const path = try platform.os.joinPath(self.gpa, &.{ self.dir, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, bytes);
    }

    /// Compiles text into a package and loads it after any loaded before it.
    fn loadPackage(self: *Stack, name: []const u8, source: []const u8) !void {
        var doc = try data.parser.parse(self.gpa, "content.fdt", source, .{
            .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
        }, &self.diags);
        defer doc.deinit(self.gpa);
        var pkg = try data.check.Package.init(self.gpa, name, 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.schemas, &self.diags);
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.gpa);
        try data.fpk.write(self.gpa, &pkg, &self.schemas, &bytes);
        const owned = try bytes.toOwnedSlice(self.gpa);
        try self.packages.append(self.gpa, owned);
        const handle = try self.store.add(self.gpa, name, owned, &self.schemas, &self.diags);
        try self.assets.mount(self.gpa, handle, self.dir);
    }

    fn step(self: *Stack) ![]const f32 {
        return self.plat.stepAudio(self.mixer.device, buffer);
    }
};

fn id(text: []const u8) ContentId {
    return ContentId.fromString(text);
}

/// Steps one buffer, then updates the mixer and the sequencer, as a frame does.
fn frame(s: *Stack, music: *Music) ![]const f32 {
    const out = try s.step();
    s.mixer.update();
    music.update();
    return out;
}

/// Checks every start `music` asked for against the frame the mixer reports, for each voice
/// that has started and still plays. Returns how many it has seen.
fn checkStarts(s: *Stack, music: *Music, checked: *u64) !void {
    var buf: [Music.start_capacity]audio.MusicStart = undefined;
    const all = music.starts(&buf);
    const first = music.startCount() - all.len;
    while (checked.* < music.startCount()) {
        const start = all[@intCast(checked.* - first)];
        const actual = s.mixer.startedAt(start.voice) orelse return;
        try testing.expectEqual(start.frame, actual);
        checked.* += 1;
    }
}

const sequence_source =
    \\foundry:sound t:music.a1 { source "music/a1.wav" }
    \\foundry:sound t:music.a2 { source "music/a2.wav" }
    \\foundry:sound t:music.b1 { source "music/b1.wav" }
    \\foundry:sound t:music.sting { source "music/sting.wav" }
    \\foundry:music_playlist t:music.a {
    \\    tracks [ t:music.a1 t:music.a2 ]
    \\    crossfade 0.05
    \\    tempo 360
    \\    beats_per_bar 2
    \\}
    \\foundry:music_playlist t:music.b {
    \\    tracks [ t:music.b1 ]
    \\    crossfade 0.02
    \\    gain 0.5
    \\}
    \\foundry:music_stinger t:music.s {
    \\    sound t:music.sting
    \\    duck 0.5
    \\    duck_fade 0.005
    \\}
;

fn sequenceStack() !*Stack {
    const s = try Stack.init();
    errdefer s.deinit();
    try s.writeWav("music/a1.wav", 12_000, 97);
    try s.writeWav("music/a2.wav", 50_000, 61);
    try s.writeWav("music/b1.wav", 20_000, 211);
    try s.writeWav("music/sting.wav", 2_000, 23);
    try s.loadPackage("t:content", sequence_source);
    return s;
}

/// Criterion 5's mix: a playlist, its crossfade, a stinger on the beat with its duck, and a
/// switch on the bar line, then the new playlist looping into itself. Returns the hash of every
/// sample, and checks each start against arithmetic written out here.
fn sequencedMix() !u64 {
    const s = try sequenceStack();
    defer s.deinit();
    var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .lookahead_frames = 1024, .stinger_lookahead_frames = 512 });
    defer music.deinit();

    var hash = std.hash.Wyhash.init(0);
    var checked: u64 = 0;
    try music.play(id("t:music.a"));
    var buffers: u32 = 0;
    while (buffers < 270) : (buffers += 1) {
        // Clock 12,800, then 28,160: the stinger, then the switch.
        if (buffers == 50) try music.stinger(id("t:music.s"));
        if (buffers == 110) try music.play(id("t:music.b"));
        const out = try frame(s, &music);
        hash.update(std.mem.sliceAsBytes(out));
        try checkStarts(s, &music, &checked);
    }

    // The arithmetic of §8, frame by frame:
    // - a1 starts one lookahead in: 1,024, fading in over the crossfade, 0.05 s = 2,400;
    // - a2 starts at a1's end less the crossfade: 1,024 + 12,000 − 2,400 = 10,624;
    // - at clock 12,800 the stinger's earliest frame is 12,800 + 512 = 13,312, and a2's next
    //   beat (360 bpm, 8,000 frames) from 10,624 is 18,624;
    // - at clock 28,160 the switch's earliest is 29,184. a2's next beat would be 34,624, but its
    //   next bar (two beats, 16,000 frames) is 42,624, before a2's end at 60,624;
    // - b1 crossfades in over 0.02 s = 960, and loops into itself at
    //   42,624 + 20,000 − 960 = 61,664.
    var buf: [Music.start_capacity]audio.MusicStart = undefined;
    const all = music.starts(&buf);
    const expected = [_]struct { frame: u64, id: []const u8 }{
        .{ .frame = 1_024, .id = "t:music.a1" },
        .{ .frame = 10_624, .id = "t:music.a2" },
        .{ .frame = 18_624, .id = "t:music.sting" },
        .{ .frame = 42_624, .id = "t:music.b1" },
        .{ .frame = 61_664, .id = "t:music.b1" },
    };
    try testing.expectEqual(expected.len, all.len);
    for (expected, all) |want, got| {
        try testing.expectEqual(want.frame, got.frame);
        try testing.expect(got.id.eql(id(want.id)));
    }
    // Every one started on the frame it asked for, and none was late.
    try testing.expectEqual(@as(u64, expected.len), checked);
    try testing.expectEqual(@as(u32, 0), s.mixer.lateStarts());
    try testing.expectEqual(@as(u32, 0), s.mixer.commandsDropped());
    return hash.final();
}

test "a sequenced mix starts every track and stinger on the frame the arithmetic gives, and is pinned" {
    const first = try sequencedMix();
    // The same samples every run (criterion 5), and the same as the pin.
    try testing.expectEqual(first, try sequencedMix());
    try testing.expectEqual(@as(u64, 2692657964278199496), first);
}

test "a setGain during a stinger's duck holds once the duck is over" {
    var runs: [2][]f32 = undefined;
    for (&runs, [_]bool{ false, true }) |*out, sting| {
        const s = try Stack.init();
        defer s.deinit();
        try s.writeWav("music/a1.wav", 30_000, 97);
        try s.writeWav("music/quiet.wav", 2_000, 0);
        try s.loadPackage("t:content",
            \\foundry:sound t:music.a1 { source "music/a1.wav" }
            \\foundry:sound t:music.quiet { source "music/quiet.wav" }
            \\foundry:music_playlist t:music.a { tracks [ t:music.a1 ] crossfade 0 }
            \\foundry:music_stinger t:music.s { sound t:music.quiet quantize "now" duck 0.25 duck_fade 0.005 }
        );
        var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .lookahead_frames = 1024, .stinger_lookahead_frames = 512 });
        defer music.deinit();
        try music.play(id("t:music.a"));
        out.* = try testing.allocator.alloc(f32, 64 * buffer);
        for (0..64) |b| {
            if (sting and b == 20) try music.stinger(id("t:music.s"));
            // Paused under the stinger in one run, before any stinger in the other.
            if (b == (if (sting) @as(usize, 25) else 2)) music.setGain(0.5, 0);
            @memcpy(out.*[b * buffer ..][0..buffer], try frame(s, &music));
        }
    }
    defer for (runs) |r| testing.allocator.free(r);
    // After the duck's release, the level is the paused one, not the one before it.
    const after = 5_632 + 2_000 + 240;
    try testing.expectEqualSlices(f32, runs[0][after..], runs[1][after..]);
}

test "a stinger ducks the music to its factor from its start to its end, and back" {
    // A silent stinger, so what is heard is the music alone, ducked; and the same run without
    // it, for the music undisturbed.
    var runs: [2][]f32 = undefined;
    for (&runs, [_]bool{ false, true }) |*out, sting| {
        const s = try Stack.init();
        defer s.deinit();
        try s.writeWav("music/a1.wav", 30_000, 97);
        try s.writeWav("music/quiet.wav", 2_000, 0);
        try s.loadPackage("t:content",
            \\foundry:sound t:music.a1 { source "music/a1.wav" }
            \\foundry:sound t:music.quiet { source "music/quiet.wav" }
            \\foundry:music_playlist t:music.a { tracks [ t:music.a1 ] crossfade 0 tempo 360 }
            \\foundry:music_stinger t:music.s { sound t:music.quiet quantize "now" duck 0.25 duck_fade 0.005 }
        );
        var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .lookahead_frames = 1024, .stinger_lookahead_frames = 512 });
        defer music.deinit();
        try music.play(id("t:music.a"));
        out.* = try testing.allocator.alloc(f32, 64 * buffer);
        for (0..64) |b| {
            // Clock 5,120: the stinger lands at 5,632, the duck ramps down over 240 frames
            // before it and back up over 240 after its 2,000 frames.
            if (sting and b == 20) try music.stinger(id("t:music.s"));
            @memcpy(out.*[b * buffer ..][0..buffer], try frame(s, &music));
        }
    }
    defer for (runs) |r| testing.allocator.free(r);
    const plain = runs[0];
    const ducked = runs[1];
    // Untouched before the ramp down, and after the ramp back up.
    try testing.expectEqualSlices(f32, plain[0 .. 5_632 - 240], ducked[0 .. 5_632 - 240]);
    try testing.expectEqualSlices(f32, plain[5_632 + 2_000 + 240 ..], ducked[5_632 + 2_000 + 240 ..]);
    // At its factor for the stinger's whole length; the stinger is silence, so adds nothing.
    for (plain[5_632..][0..2_000], ducked[5_632..][0..2_000]) |p, d| try testing.expectEqual(p * 0.25, d);
}

/// The IDs of every track start `music` has asked for, in order.
fn trackStarts(music: *const Music, out: []ContentId, frames: []u64) usize {
    var buf: [Music.start_capacity]audio.MusicStart = undefined;
    var n: usize = 0;
    for (music.starts(&buf)) |start| if (start.kind == .track) {
        out[n] = start.id;
        frames[n] = start.frame;
        n += 1;
    };
    return n;
}

fn shuffled(seed: u64, ids: *[12]ContentId) !void {
    const s = try Stack.init();
    defer s.deinit();
    for (0..4) |i| {
        const rel = try std.fmt.allocPrint(s.gpa, "music/c{d}.wav", .{i});
        defer s.gpa.free(rel);
        try s.writeWav(rel, 1_000, @intCast(13 + i));
    }
    try s.loadPackage("t:content",
        \\foundry:sound t:music.c0 { source "music/c0.wav" }
        \\foundry:sound t:music.c1 { source "music/c1.wav" }
        \\foundry:sound t:music.c2 { source "music/c2.wav" }
        \\foundry:sound t:music.c3 { source "music/c3.wav" }
        \\foundry:music_playlist t:music.c { tracks [ t:music.c0 t:music.c1 t:music.c2 t:music.c3 ] order "shuffle" crossfade 0 }
    );
    var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .seed = seed, .lookahead_frames = 1024 });
    defer music.deinit();
    try music.play(id("t:music.c"));
    for (0..56) |_| _ = try frame(s, &music);

    var all: [Music.start_capacity]ContentId = undefined;
    var frames: [Music.start_capacity]u64 = undefined;
    const n = trackStarts(&music, &all, &frames);
    try testing.expect(n >= 12);
    @memcpy(ids, all[0..12]);
    // With no crossfade, each track starts on the frame the one before it ends.
    for (frames[1..n], frames[0 .. n - 1]) |next, previous| try testing.expectEqual(previous + 1_000, next);
    try testing.expectEqual(@as(u32, 0), s.mixer.lateStarts());
}

test "shuffle draws a permutation per cycle from its seed, never repeating across a cycle's seam" {
    var first: [12]ContentId = undefined;
    try shuffled(7, &first);
    for (0..3) |cycle| {
        const run = first[cycle * 4 ..][0..4];
        for (run, 0..) |a, i| for (run[i + 1 ..]) |b| try testing.expect(!a.eql(b));
        if (cycle > 0) try testing.expect(!run[0].eql(first[cycle * 4 - 1]));
    }
    var again: [12]ContentId = undefined;
    try shuffled(7, &again);
    for (first, again) |a, b| try testing.expect(a.eql(b));
    var other: [12]ContentId = undefined;
    try shuffled(8, &other);
    var same = true;
    for (first, other) |a, b| same = same and a.eql(b);
    try testing.expect(!same);
}

test "a track shorter than twice the crossfade plays without one, and loop false lets the music end" {
    const s = try Stack.init();
    defer s.deinit();
    try s.writeWav("music/long.wav", 10_000, 50);
    try s.writeWav("music/short.wav", 3_000, 70);
    try s.loadPackage("t:content",
        \\foundry:sound t:music.long { source "music/long.wav" }
        \\foundry:sound t:music.short { source "music/short.wav" }
        \\foundry:music_playlist t:music.p { tracks [ t:music.long t:music.short t:music.long ] crossfade 0.05 loop false }
    );
    var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .lookahead_frames = 1024 });
    defer music.deinit();
    try music.play(id("t:music.p"));
    var checked: u64 = 0;
    for (0..140) |_| {
        _ = try frame(s, &music);
        try checkStarts(s, &music, &checked);
    }
    var ids: [Music.start_capacity]ContentId = undefined;
    var frames: [Music.start_capacity]u64 = undefined;
    const n = trackStarts(&music, &ids, &frames);
    // long at 1,024 with its fade in; short (3,000 < 2 × 2,400) at long's end with no fade;
    // long again at short's end, also with none; then nothing.
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u64, &.{ 1_024, 11_024, 14_024 }, frames[0..3]);
    try testing.expectEqual(@as(u64, 3), checked);
    try testing.expectEqual(@as(?ContentId, null), music.current());
    s.mixer.update();
    try testing.expectEqual(@as(u32, 0), s.mixer.activeVoices());
}

test "stop fades the music out and schedules nothing more; playing the same playlist again does nothing" {
    const s = try sequenceStack();
    defer s.deinit();
    var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .lookahead_frames = 1024 });
    defer music.deinit();
    try music.play(id("t:music.a"));
    try music.play(id("t:music.a"));
    try testing.expectEqual(@as(u64, 1), music.startCount());
    for (0..10) |_| _ = try frame(s, &music);
    music.stop(0.01);
    for (0..80) |_| _ = try frame(s, &music);
    try testing.expectEqual(@as(u64, 1), music.startCount());
    try testing.expectEqual(@as(u32, 0), s.mixer.activeVoices());
    try testing.expectEqual(@as(?ContentId, null), music.current());
}

test "a stinger with no music plays one stinger lookahead from now, and one on the bar waits for it" {
    const s = try sequenceStack();
    defer s.deinit();
    var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .lookahead_frames = 1024, .stinger_lookahead_frames = 512 });
    defer music.deinit();
    for (0..3) |_| _ = try frame(s, &music);
    try music.stinger(id("t:music.s"));
    var buf: [Music.start_capacity]audio.MusicStart = undefined;
    try testing.expectEqual(@as(u64, 768 + 512), music.starts(&buf)[0].frame);

    // The track starts at 768 + 1,024 = 1,792, and its first bar line is its first beat, at
    // its start; the stinger's earliest frame, 1,280, is before it, so it waits for it.
    try s.loadPackage("t:bar", "foundry:music_stinger t:music.bar { sound t:music.sting quantize \"bar\" }");
    try music.play(id("t:music.a"));
    try music.stinger(id("t:music.bar"));
    try testing.expectEqual(@as(u64, 1_792), music.starts(&buf)[2].frame);
    // Past it, the next is a bar later.
    for (0..10) |_| _ = try frame(s, &music);
    try music.stinger(id("t:music.bar"));
    try testing.expectEqual(@as(u64, 1_792 + 16_000), music.starts(&buf)[3].frame);
}

test "setGain ramps every music voice's level from the next callback" {
    var runs: [2][]f32 = undefined;
    for (&runs, [_]bool{ false, true }) |*out, halve| {
        const s = try sequenceStack();
        defer s.deinit();
        var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .lookahead_frames = 1024 });
        defer music.deinit();
        try music.play(id("t:music.a"));
        out.* = try testing.allocator.alloc(f32, 20 * buffer);
        for (0..20) |b| {
            if (halve and b == 8) music.setGain(0.5, 0);
            @memcpy(out.*[b * buffer ..][0..buffer], try frame(s, &music));
        }
    }
    defer for (runs) |r| testing.allocator.free(r);
    try testing.expectEqualSlices(f32, runs[0][0 .. 8 * buffer], runs[1][0 .. 8 * buffer]);
    // Halving is exact in binary, through the fade in and after it.
    for (runs[0][8 * buffer ..], runs[1][8 * buffer ..]) |p, h| try testing.expectEqual(p * 0.5, h);
}

test "a reload changes a playlist at its next boundary, and never cuts the track playing" {
    const s = try sequenceStack();
    defer s.deinit();
    var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .lookahead_frames = 1024 });
    defer music.deinit();
    try music.play(id("t:music.a"));
    for (0..8) |_| _ = try frame(s, &music);
    // An override replaces the playlist whole: b1 and then a1, where a1 and a2 were.
    try s.loadPackage("t:mod", "foundry:music_playlist t:music.a { tracks [ t:music.b1 t:music.a1 ] crossfade 0.05 }");
    music.contentChanged();
    for (0..60) |_| _ = try frame(s, &music);

    var ids: [Music.start_capacity]ContentId = undefined;
    var frames: [Music.start_capacity]u64 = undefined;
    const n = trackStarts(&music, &ids, &frames);
    try testing.expectEqual(@as(usize, 2), n);
    // a1 was not cut: its successor starts on its own crossfade boundary, as it would have.
    try testing.expectEqual(@as(u64, 10_624), frames[1]);
    // The rebuilt order begins a cycle of the new list: b1, not a2.
    try testing.expect(ids[1].eql(id("t:music.b1")));
}

test "an ID that is not a playlist or a stinger, and a track that is not a sound, are refused by name" {
    const s = try sequenceStack();
    defer s.deinit();
    try s.loadPackage("t:bad",
        \\foundry:music_playlist t:music.bad { tracks [ t:music.s ] }
        \\foundry:music_stinger t:music.bad_sting { sound t:music.a }
    );
    var music = Music.init(s.gpa, s.mixer, &s.assets, .{});
    defer music.deinit();
    try testing.expectError(error.NotAPlaylist, music.play(id("t:music.absent")));
    try testing.expectError(error.NotAPlaylist, music.play(id("t:music.s")));
    try testing.expectError(error.NotAStinger, music.stinger(id("t:music.a")));
    try testing.expectError(error.NotASound, music.play(id("t:music.bad")));
    try testing.expectError(error.NotASound, music.stinger(id("t:music.bad_sting")));
    try testing.expectEqual(@as(u64, 0), music.startCount());
    try testing.expectEqual(@as(u32, 0), s.mixer.activeVoices());
}

test "command delivery on the real device: how many frames a play takes to land, measured and printed" {
    // §8.4: a start scheduled closer to the clock than a command takes to reach the callback
    // would be late. Measured on the build's own device, playing silence, so only a release
    // build with a real backend says anything; anything else skips.
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    if (platform.Platform == null_backend.Platform) return error.SkipZigTest;
    const gpa = testing.allocator;
    const RealMixer = audio.MixerOf(platform.Platform);

    const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-music-latency", .env = &.{} });
    defer os.deinit();
    const plat = platform.Platform.init(gpa, .{}) catch return error.SkipZigTest;
    defer plat.deinit();
    var store: asset.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    var assets: asset.Registry = .init(gpa, os, &store, .{});
    const mixer = RealMixer.init(gpa, plat, &assets, .{ .streams = 0 }) catch return error.SkipZigTest;
    defer {
        mixer.shutdown();
        assets.deinit(gpa);
        mixer.deinit();
    }
    const silence = try asset.Sound.alloc(gpa, 64, 1, mixer.info.sample_rate);
    @memset(silence.samples, 0);
    const sound = try mixer.insertSound(silence);

    // Each play is scheduled for the clock it just read: the first frame of the next buffer.
    // It lands there if the command reaches the callback before that buffer is mixed, and a
    // buffer later (a slip, counted late) if a callback was already mixing when it was pushed.
    // The frames between the asked frame and the actual one are the delivery's cost.
    var worst: u64 = 0;
    var slips: u32 = 0;
    const runs = 400;
    for (0..runs) |i| {
        os.sleep(.fromMillis(@intCast(i % 7)));
        const asked = mixer.clock();
        const v = try mixer.playSound(sound, .{ .looping = true, .start_at = asked });
        const started = while (true) {
            os.sleep(.fromMillis(1));
            mixer.update();
            if (mixer.startedAt(v)) |frame_| break frame_;
        };
        if (started > asked) slips += 1;
        worst = @max(worst, started - asked);
        mixer.stop(v);
    }
    const ms = 1000.0 / @as(f64, @floatFromInt(mixer.info.sample_rate));
    std.debug.print("command delivery ({t}): {d} Hz, {d}-frame buffers; {d} of {d} plays slipped, worst by {d} frames ({d:.1} ms); a buffer is {d:.1} ms\n", .{
        @import("builtin").mode,
        mixer.info.sample_rate,
        mixer.info.buffer_frames,
        slips,
        runs,
        worst,
        @as(f64, @floatFromInt(worst)) * ms,
        @as(f64, @floatFromInt(mixer.info.buffer_frames)) * ms,
    });
    // A slip is at most a buffer, and the resident-stinger lookahead clears several.
    try testing.expect(worst <= mixer.info.buffer_frames);
    try testing.expect(@as(f64, @floatFromInt(mixer.info.buffer_frames)) * ms * 4 < audio.music_stinger_lookahead_seconds * 1000);
    try testing.expectEqual(slips, mixer.lateStarts());
}

test "a streamed stinger is scheduled a track's lookahead ahead, since its first decode must land" {
    const s = try sequenceStack();
    defer s.deinit();
    const ogg = asset.ogg.fixtures[4].ogg;
    const path = try platform.os.joinPath(s.gpa, &.{ s.dir, "music/long_sting.ogg" });
    defer s.gpa.free(path);
    try s.os.writeFile(path, ogg);
    try s.loadPackage("t:streamed",
        \\foundry:sound t:music.long_sting { source "music/long_sting.ogg" stream true }
        \\foundry:music_stinger t:music.ls { sound t:music.long_sting quantize "now" }
    );
    var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .lookahead_frames = 1024, .stinger_lookahead_frames = 512 });
    defer music.deinit();
    for (0..2) |_| _ = try frame(s, &music);
    try music.stinger(id("t:music.ls"));
    try music.stinger(id("t:music.s"));
    var buf: [Music.start_capacity]audio.MusicStart = undefined;
    const all = music.starts(&buf);
    try testing.expectEqual(@as(u64, 512 + 1_024), all[0].frame);
    try testing.expectEqual(@as(u64, 512 + 512), all[1].frame);
}

test "a two-track shuffle never plays one track twice in a row, across many cycles" {
    // Each cycle's draw is a coin flip, so its first track matches the last one played about
    // half the time; the swap is what keeps every seam a change.
    const s = try Stack.init();
    defer s.deinit();
    try s.writeWav("music/x.wav", 500, 17);
    try s.writeWav("music/y.wav", 500, 19);
    try s.loadPackage("t:content",
        \\foundry:sound t:music.x { source "music/x.wav" }
        \\foundry:sound t:music.y { source "music/y.wav" }
        \\foundry:music_playlist t:music.xy { tracks [ t:music.x t:music.y ] order "shuffle" crossfade 0 }
    );
    var music = Music.init(s.gpa, s.mixer, &s.assets, .{ .seed = 3, .lookahead_frames = 1024 });
    defer music.deinit();
    try music.play(id("t:music.xy"));
    // Forty tracks: twenty cycles.
    for (0..82) |_| _ = try frame(s, &music);
    var ids: [Music.start_capacity]ContentId = undefined;
    var frames: [Music.start_capacity]u64 = undefined;
    const n = trackStarts(&music, &ids, &frames);
    try testing.expect(n >= 40);
    for (ids[1..n], ids[0 .. n - 1]) |next, previous| try testing.expect(!next.eql(previous));
}
