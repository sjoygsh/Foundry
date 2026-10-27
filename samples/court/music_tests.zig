//! The court's soundtrack and mix as content (music.md §9, mixing.md §11): its records, what
//! its streamed music costs to hold, its buses, and `nocturne` changing both with no code. The tracks and stingers are the
//! real files, played on the null backend's stepped device with immediate tasks.
const std = @import("std");
const asset = @import("asset");
const audio = @import("audio");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const options = @import("court_test_options");
const music_mod = @import("music.zig");
const sounds_mod = @import("sounds.zig");
const t = std.testing;

const null_backend = platform.null_backend;
const Mixer = audio.MixerOf(null_backend.Platform);
const Music = audio.MusicOf(Mixer);
const ContentId = core.ContentId;

const rate = 48_000;
const buffer = 512;

/// The court's packages, with `nocturne` after them or not, over a stepped device.
const Rig = struct {
    gpa: std.mem.Allocator,
    os: *platform.os.Os,
    plat: *null_backend.Platform,
    diags: data.Diagnostics,
    schemas: data.Registry,
    store: data.Store,
    assets: asset.Registry,
    mixer: *Mixer,
    bytes: [3]?[]u8 = @splat(null),

    fn init(gpa: std.mem.Allocator, nocturne: bool) !*Rig {
        const self = try gpa.create(Rig);
        errdefer gpa.destroy(self);
        const os = try platform.os.Os.init(gpa, .{});
        errdefer os.deinit();
        const plat = try null_backend.Platform.init(gpa, .{});
        errdefer plat.deinit();
        self.* = .{
            .gpa = gpa,
            .os = os,
            .plat = plat,
            .diags = .init(gpa, .default),
            .schemas = .init(gpa, .default),
            .store = .init(gpa, .default),
            .assets = undefined,
            .mixer = undefined,
        };
        errdefer self.release();
        try asset.schemas.registerAll(gpa, &self.schemas);
        try asset.music.registerAll(gpa, &self.schemas);
        try asset.mix.registerAll(gpa, &self.schemas);
        self.assets = .init(gpa, os, &self.store, .{});
        self.mixer = try Mixer.init(gpa, plat, &self.assets, .{ .sample_rate = rate, .buffer_frames = buffer });
        try self.assets.registerLoader(gpa, self.mixer.soundLoader());

        _ = try self.add(0, "foundry:core", options.core_package);
        try self.assets.mount(gpa, try self.add(1, "court:content", options.package), options.sources);
        if (nocturne) try self.assets.mount(gpa, try self.add(2, "nocturne:content", options.nocturne_package), options.nocturne_sources);
        return self;
    }

    fn add(self: *Rig, slot: usize, name: []const u8, path: []const u8) !data.store.PackageHandle {
        const bytes = try self.os.readFile(self.gpa, path, 16 * 1024 * 1024);
        self.bytes[slot] = bytes;
        return self.store.add(self.gpa, name, bytes, &self.schemas, &self.diags);
    }

    fn release(self: *Rig) void {
        for (self.bytes) |b| if (b) |bytes| self.gpa.free(bytes);
        self.diags.deinit(self.gpa);
        self.plat.deinit();
        self.os.deinit();
    }

    fn deinit(self: *Rig) void {
        const gpa = self.gpa;
        self.mixer.shutdown();
        self.assets.deinit(gpa);
        self.mixer.deinit();
        self.store.deinit(gpa);
        self.schemas.deinit(gpa);
        self.release();
        gpa.destroy(self);
    }

    fn playlist(self: *Rig, id: ContentId) !asset.music.Playlist {
        return asset.music.decodePlaylist(self.store.lookup(id).?.fields);
    }

    fn stinger(self: *Rig, id: ContentId) !asset.music.Stinger {
        return asset.music.decodeStinger(self.store.lookup(id).?.fields);
    }

    /// One buffer, then the mixer's and the sequencer's updates, as a frame has them.
    fn frame(self: *Rig, music: *Music) !void {
        _ = try self.plat.stepAudio(self.mixer.device, buffer);
        self.mixer.update();
        music.update();
    }

    /// Frames until every start the sequencer has asked for has begun, each on its frame.
    fn settle(self: *Rig, music: *Music) !void {
        var ring: [Music.start_capacity]audio.MusicStart = undefined;
        for (0..rate * 4 / buffer) |_| {
            try self.frame(music);
            const all = music.starts(&ring);
            var waiting = false;
            for (all) |start| {
                if (self.mixer.startedAt(start.voice)) |actual| {
                    try t.expectEqual(start.frame, actual);
                } else if (self.mixer.isPlaying(start.voice)) waiting = true;
            }
            if (!waiting) return;
        }
        return error.StartsNeverBegan;
    }
};

/// A sound record's fields, checked to be one.
fn soundFields(store: *const data.Store, id: ContentId) !data.fpk.Fields {
    const record = store.lookup(id) orelse return error.MissingSound;
    try t.expect(record.schema.id.eql(asset.schemas.sound.id));
    return record.fields;
}

fn boolField(fields: data.fpk.Fields, name: []const u8) ?bool {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return fields.boolAt(@intCast(i)) catch null;
    return null;
}

fn stringField(fields: data.fpk.Fields, name: []const u8) ?[]const u8 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return fields.stringAt(@intCast(i)) catch null;
    return null;
}

test "court: the soundtrack's tracks stream, and are held in under an eighth of their 16-bit WAV" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = t.allocator;
    const rig = try Rig.init(gpa, false);
    defer rig.deinit();
    const set = music_mod.MusicSet.find(&rig.store).?;

    var resident: usize = 0;
    var wav: u64 = 0;
    for ([_]ContentId{ set.title, set.calm, set.chase }) |id| {
        const playlist = try rig.playlist(id);
        try t.expectEqual(@as(f32, 96), playlist.tempo);
        for (playlist.tracks()) |track| {
            const fields = try soundFields(&rig.store, track);
            try t.expectEqual(@as(?bool, true), boolField(fields, "stream"));
            const path = try platform.os.joinPath(gpa, &.{ options.sources, stringField(fields, "source").? });
            defer gpa.free(path);
            const bytes = try rig.os.readFile(gpa, path, 16 * 1024 * 1024);
            defer gpa.free(bytes);
            // What the mixer holds for a streamed sound, counted where it allocates.
            var counted: core.mem.Counted = .init("track", gpa);
            const holder = try Mixer.init(counted.allocator(), rig.plat, &rig.assets, .{ .sample_rate = rate, .buffer_frames = buffer, .streams = 0, .voices = 1 });
            defer holder.deinit();
            const before = counted.live_bytes;
            const sound = try holder.insertStreamed(bytes);
            resident += counted.live_bytes - before;
            holder.releaseSound(sound);
            holder.update();
            var headers = try asset.vorbis.readHeaders(gpa, bytes, .{});
            defer headers.deinit();
            wav += headers.frames * headers.info.channels * 2;
        }
    }
    // Criterion 4's second half (music.md §1).
    try t.expect(resident * 8 <= wav);
    // The stingers stay resident, so they can land a tenth of a second after they are asked.
    for ([_]ContentId{ set.beacon, set.gate, set.ending }) |id| {
        const fields = try soundFields(&rig.store, (try rig.stinger(id)).sound);
        try t.expect(boolField(fields, "stream") != true);
    }
}

test "court: the calm playlist follows the title on its bar, and a beacon's stinger lands on a beat" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = t.allocator;
    const rig = try Rig.init(gpa, false);
    defer rig.deinit();
    const set = music_mod.MusicSet.find(&rig.store).?;
    var music = Music.init(gpa, rig.mixer, &rig.assets, .{ .seed = 1 });
    defer music.deinit();

    try music.play(set.title);
    try rig.settle(&music);
    try music.play(set.calm);
    try music.stinger(set.beacon);
    try rig.settle(&music);
    var ring: [Music.start_capacity]audio.MusicStart = undefined;
    const starts = music.starts(&ring);
    try t.expectEqual(@as(usize, 3), starts.len);
    // 96 bpm: a beat is 30,000 frames and a bar 120,000, counted from the title's start.
    const beat = 30_000;
    try t.expectEqual(@as(u64, 0), (starts[1].frame - starts[0].frame) % (4 * beat));
    try t.expectEqual(audio.MusicStart.Kind.stinger, starts[2].kind);
    try t.expect(starts[2].id.eql((try rig.stinger(set.beacon)).sound));
    try t.expectEqual(@as(u64, 0), (starts[2].frame - starts[0].frame) % beat);
    try t.expectEqual(@as(u32, 0), rig.mixer.underruns());
    try t.expectEqual(@as(u32, 0), rig.mixer.lateStarts());

    // The evidence the court's log writes agrees: every start on its frame.
    var evidence: music_mod.Evidence = .{};
    evidence.check(&music, rig.mixer, false);
    try t.expectEqual(@as(u64, 3), evidence.asked);
    try t.expectEqual(@as(u64, 3), evidence.exact);
    try t.expect(evidence.clean(rig.mixer.underruns(), rig.mixer.lateStarts(), 0));
}

test "court: nocturne replaces the calm music and the beacon's stinger, with no code" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = t.allocator;
    const rig = try Rig.init(gpa, true);
    defer rig.deinit();
    // The game's choice of record is unchanged; what the record holds is the mod's.
    const set = music_mod.MusicSet.find(&rig.store).?;
    try t.expect(set.calm.eql(.fromString("court:music.calm")));
    const calm = try rig.playlist(set.calm);
    try t.expectEqual(@as(usize, 2), calm.tracks().len);
    try t.expect(calm.tracks()[0].eql(.fromString("nocturne:music.nocturne_a")));
    try t.expect(calm.tracks()[1].eql(.fromString("nocturne:music.nocturne_b")));
    try t.expectEqual(@as(f32, 72), calm.tempo);
    try t.expectEqual(@as(u32, 3), calm.beats_per_bar);
    const beacon = try rig.stinger(set.beacon);
    try t.expect(beacon.sound.eql(.fromString("nocturne:music.beacon")));
    // The rest of the soundtrack is the court's.
    try t.expect((try rig.playlist(set.chase)).tracks()[0].eql(.fromString("court:music.tracks.chase")));

    var music = Music.init(gpa, rig.mixer, &rig.assets, .{ .seed = 1 });
    defer music.deinit();
    try music.play(set.calm);
    try rig.settle(&music);
    try music.stinger(set.beacon);
    try rig.settle(&music);
    var ring: [Music.start_capacity]audio.MusicStart = undefined;
    const starts = music.starts(&ring);
    try t.expectEqual(@as(usize, 2), starts.len);
    try t.expect(starts[0].id.eql(.fromString("nocturne:music.nocturne_a")));
    try t.expect(starts[1].id.eql(.fromString("nocturne:music.beacon")));
    // 72 bpm: a beat is 40,000 frames from the track's start.
    try t.expectEqual(@as(u64, 0), (starts[1].frame - starts[0].frame) % 40_000);
    try t.expectEqual(@as(u32, 0), rig.mixer.underruns());
}

fn settingsOf(store: *const data.Store, id: ContentId) !asset.mix.SoundSettings {
    return asset.mix.decodeSound(try soundFields(store, id));
}

test "court: every sound has its bus and priority, and the tree mixes them with none misrouted" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = t.allocator;
    const rig = try Rig.init(gpa, false);
    defer rig.deinit();
    const mix = sounds_mod.MixSet.find(&rig.store).?;
    try rig.mixer.useMix(mix.master);
    const set = sounds_mod.SoundSet.find(&rig.store).?;
    const music = music_mod.MusicSet.find(&rig.store).?;
    const id = ContentId.fromString;

    // Footsteps give way first, then the warden's, and the music never (mixing.md §11).
    const Expect = struct { sound: ContentId, bus: []const u8, priority: u8 };
    const expected = [_]Expect{
        .{ .sound = set.step, .bus = "court:bus.effects", .priority = 32 },
        .{ .sound = set.jump, .bus = "court:bus.effects", .priority = 32 },
        .{ .sound = set.land, .bus = "court:bus.effects", .priority = 32 },
        .{ .sound = set.warden_step, .bus = "court:bus.effects", .priority = 64 },
        .{ .sound = set.gate, .bus = "court:bus.effects", .priority = 128 },
        .{ .sound = id("court:sounds.beacon"), .bus = "court:bus.effects", .priority = 128 },
        .{ .sound = set.ambience, .bus = "court:bus.ambience", .priority = 160 },
        .{ .sound = set.won, .bus = "court:bus.ui", .priority = 200 },
        .{ .sound = set.caught, .bus = "court:bus.ui", .priority = 200 },
        .{ .sound = set.fell, .bus = "court:bus.ui", .priority = 200 },
        .{ .sound = set.click, .bus = "court:bus.ui", .priority = 200 },
    };
    for (expected) |e| {
        const settings = try settingsOf(&rig.store, e.sound);
        try t.expect(settings.bus.?.eql(id(e.bus)));
        try t.expectEqual(e.priority, settings.priority);
        _ = try rig.mixer.play(e.sound, .{ .position = if (settings.attenuation != null) core.math.Vec3.init(1, 1, -2) else null });
    }
    // The spatial ones carry an attenuation the mixer resolves.
    try t.expect((try settingsOf(&rig.store, set.warden_step)).attenuation.?.eql(id("court:attenuation.warden")));
    try t.expect((try settingsOf(&rig.store, set.gate)).attenuation.?.eql(id("court:attenuation.prop")));
    for ([_]ContentId{ music.title, music.calm, music.chase }) |list| {
        for ((try rig.playlist(list)).tracks()) |track| {
            const settings = try settingsOf(&rig.store, track);
            try t.expect(settings.bus.?.eql(mix.music));
            try t.expectEqual(@as(u8, 255), settings.priority);
        }
    }
    for ([_]ContentId{ music.beacon, music.gate, music.ending }) |sting| {
        const settings = try settingsOf(&rig.store, (try rig.stinger(sting)).sound);
        try t.expect(settings.bus.?.eql(mix.music));
        try t.expectEqual(@as(u8, 255), settings.priority);
    }
    for (0..8) |_| {
        _ = try rig.plat.stepAudio(rig.mixer.device, buffer);
        rig.mixer.update();
    }
    try t.expectEqual(@as(u32, 0), rig.mixer.misrouted());
    try t.expectEqual(@as(u32, 0), rig.mixer.overCeiling());
    // The master's limiter is the only lookahead: 2 ms at 48 kHz.
    try t.expectEqual(@as(u32, 96), rig.mixer.mixerLatency());
    // The muffle is the world bus's third effect, open to the top of hearing, and a pause's
    // sweep down is a retune of that same filter, which the mixer takes.
    const slot = sounds_mod.slotOf(&rig.store, mix.effects, mix.muffle).?;
    try t.expectEqual(@as(u8, 2), slot);
    var muffle = sounds_mod.filterOf(&rig.store, mix.muffle).?;
    try t.expectEqual(@as(f32, 20_000), muffle.frequency);
    muffle.frequency = mix.muffle_frequency;
    try t.expect(rig.mixer.setEffectChecked(mix.effects, slot, .{ .filter = muffle }, 12_000));
    try t.expect(!rig.mixer.setEffectChecked(mix.effects, 2, .{ .reverb = .{} }, 0));
}

test "court: the title plays its intro once and then its body, one voice, as long as it plays" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = t.allocator;
    const rig = try Rig.init(gpa, false);
    defer rig.deinit();
    const set = music_mod.MusicSet.find(&rig.store).?;
    const track = (try rig.playlist(set.title)).tracks()[0];
    const settings = try settingsOf(&rig.store, track);
    // Eight bars of 2.5 s, then eight more: 20 s and 40 s at 48 kHz.
    try t.expectEqual(@as(u64, 960_000), settings.loop_start);
    try t.expectEqual(@as(u64, 1_920_000), settings.loop_end);
    const info = try rig.mixer.soundInfo(track);
    try t.expect(info.loops and info.streamed);
    try t.expectEqual(@as(u64, 1_920_000), info.source_frames);
    // The calm playlist resumes where it was left.
    try t.expect((try rig.playlist(set.calm)).resumes);

    var music = Music.init(gpa, rig.mixer, &rig.assets, .{ .seed = 1 });
    defer music.deinit();
    try music.play(set.title);
    try rig.settle(&music);
    // Past the loop's end and a few seconds into its second pass: still the one start.
    for (0..rate * 46 / buffer) |_| try rig.frame(&music);
    var ring: [Music.start_capacity]audio.MusicStart = undefined;
    const starts = music.starts(&ring);
    try t.expectEqual(@as(usize, 1), starts.len);
    try t.expect(rig.mixer.isPlaying(starts[0].voice));
    try t.expectEqual(@as(u32, 1), rig.mixer.activeVoices());
    try t.expectEqual(@as(u32, 0), rig.mixer.underruns());
}

test "court: nocturne lengthens the courtyard and echoes the music, with no code" {
    if (comptime !options.available) return error.SkipZigTest;
    const gpa = t.allocator;
    const id = ContentId.fromString;
    for ([_]bool{ false, true }) |nocturne| {
        const rig = try Rig.init(gpa, nocturne);
        defer rig.deinit();
        const room = rig.store.lookup(id("court:fx.courtyard")).?;
        const reverb = (try asset.mix.decodeEffect(room.schema_id, room.fields)).reverb;
        try t.expectEqual(@as(f32, if (nocturne) 3.2 else 1.4), reverb.decay);
        const music_bus = try asset.mix.decodeBus(rig.store.lookup(id("court:bus.music")).?.fields);
        try t.expectEqual(@as(usize, if (nocturne) 1 else 0), music_bus.effects().len);
        if (nocturne) {
            try t.expect(music_bus.effects()[0].eql(id("nocturne:fx.echo")));
            const echo = rig.store.lookup(id("nocturne:fx.echo")).?;
            // Three eighths of a beat at 72 bpm.
            try t.expectApproxEqAbs(@as(f32, 0.375 * 60.0 / 72.0), (try asset.mix.decodeEffect(echo.schema_id, echo.fields)).delay.time, 1e-6);
            // Nocturne's own music goes through the music bus too.
            for ([_][]const u8{ "nocturne:music.nocturne_a", "nocturne:music.nocturne_b", "nocturne:music.beacon" }) |sound| {
                try t.expect((try settingsOf(&rig.store, id(sound))).bus.?.eql(id("court:bus.music")));
            }
        }
        // The tree builds either way, and the echo is the music bus's.
        try rig.mixer.useMix(id("court:bus.master"));
        try t.expectEqual(@as(u32, 96), rig.mixer.mixerLatency());
    }
}
