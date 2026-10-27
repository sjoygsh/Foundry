//! A `.wav` on disk to samples in a device buffer, through every module on the way.
//!
//! `.fdt` text and a `.wav` become a package; the package becomes a store; a content id
//! becomes a `SoundHandle`; the handle plays. Each step is unit-tested where it lives.
//! What is only testable here is that they compose, because the modules involved are
//! deliberately blind to each other: `asset` is L2 and knows nothing about mixing, and
//! `audio` is L3 and is not granted `data` at all.
//!
//! The other thing that is only testable here is `audio.md` §7's second hazard — a hot
//! reload replacing a sound while a voice is reading its samples. That needs a real
//! registry over a real file, which is to say it needs to stand above both modules.
//!
//! It runs on the null backend's stepped device, so the samples are the same every run.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const asset = @import("asset");
const audio = @import("audio");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const null_backend = platform.null_backend;
const Mixer = audio.MixerOf(null_backend.Platform);

const package_source =
    \\foundry:sound foundry:sounds.chirp {
    \\    source "sounds/chirp.wav"
    \\}
;

/// One frame of 16-bit mono PCM at 48 kHz, at whatever level is asked for.
///
/// Built rather than embedded, because the reload test needs two files that differ in
/// exactly one way and nothing else.
fn wavBytes(gpa: Allocator, frames: []const i16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "RIFF");
    try appendInt(gpa, &out, u32, @intCast(36 + frames.len * 2));
    try out.appendSlice(gpa, "WAVEfmt ");
    try appendInt(gpa, &out, u32, 16);
    try appendInt(gpa, &out, u16, 1); // PCM
    try appendInt(gpa, &out, u16, 1); // mono
    try appendInt(gpa, &out, u32, 48_000);
    try appendInt(gpa, &out, u32, 48_000 * 2);
    try appendInt(gpa, &out, u16, 2);
    try appendInt(gpa, &out, u16, 16);
    try out.appendSlice(gpa, "data");
    try appendInt(gpa, &out, u32, @intCast(frames.len * 2));
    for (frames) |sample| try appendInt(gpa, &out, i16, sample);

    return out.toOwnedSlice(gpa);
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

/// The whole stack, assembled the way a game assembles it.
///
/// **Teardown order is the load-bearing part**, and it is the same order the texture
/// pipeline has: the asset registry unloads through the loaders it was given, so it goes
/// before the mixer that registered one, which holds the device and goes before the
/// platform.
const Stack = struct {
    gpa: Allocator,
    os: *platform.os.Os,
    plat: *null_backend.Platform,
    tmp: std.testing.TmpDir,
    dir: []u8,
    schemas: data.Registry,
    diags: data.Diagnostics,
    store: data.Store,
    bytes: std.ArrayList(u8) = .empty,
    assets: asset.Registry,
    mixer: *Mixer,

    fn init(options: audio.Options) !*Stack {
        const gpa = testing.allocator;

        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-integration", .env = &.{} });
        errdefer os.deinit();

        const plat = try null_backend.Platform.init(gpa, .{});
        errdefer plat.deinit();

        // `std`'s temporary directory, not `Os.tempDirAlloc`: this `Os` is handed no
        // environment, and on Windows only the environment names a temporary directory.
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(testing.io, &path_buf);
        const dir = try platform.os.joinPath(gpa, &.{ path_buf[0..path_len], "foundry-sound-pipeline" });
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
        self.mixer = try Mixer.init(gpa, plat, &self.assets, options);

        // The two runtime registrations that make the engine able to load a sound at
        // all, and both are calls a mod could make (I6): the record type, then the
        // loader that consumes it.
        try asset.schemas.registerAll(gpa, &self.schemas);
        try asset.mix.registerAll(gpa, &self.schemas);
        try self.assets.registerLoader(gpa, self.mixer.soundLoader());
        return self;
    }

    fn deinit(self: *Stack) void {
        // The order the module documents, and what the sandbox does: `shutdown` closes
        // the device and hands back the asset reference every playing voice held, then the
        // registry unloads through a loader that is still valid, then the mixer goes.
        self.mixer.shutdown();
        self.assets.deinit(self.gpa);
        self.mixer.deinit();
        self.plat.deinit();
        self.store.deinit(self.gpa);
        self.schemas.deinit(self.gpa);
        self.diags.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.os.deinit();
        self.tmp.cleanup();
        self.gpa.destroy(self);
    }

    fn writeFile(self: *Stack, rel: []const u8, contents: []const u8) !void {
        const path = try platform.os.joinPath(self.gpa, &.{ self.dir, rel });
        defer self.gpa.free(path);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFile(path, contents);
    }

    fn writeWav(self: *Stack, rel: []const u8, frames: []const i16) !void {
        const bytes = try wavBytes(self.gpa, frames);
        defer self.gpa.free(bytes);
        try self.writeFile(rel, bytes);
    }

    /// Compiles text into a package and loads it, which is what `fpack` plus the engine do.
    fn loadPackage(self: *Stack, name: []const u8, source: []const u8) !void {
        var doc = try data.parser.parse(self.gpa, "content.fdt", source, .{
            .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
        }, &self.diags);
        defer doc.deinit(self.gpa);

        var pkg = try data.check.Package.init(self.gpa, name, 1, .default);
        defer pkg.deinit(self.gpa);
        try pkg.addDocument(self.gpa, &doc, &self.schemas, &self.diags);
        try data.fpk.write(self.gpa, &pkg, &self.schemas, &self.bytes);

        const handle = try self.store.add(self.gpa, name, self.bytes.items, &self.schemas, &self.diags);
        try self.assets.mount(self.gpa, handle, self.dir);
    }

    fn step(self: *Stack, frames: u32) ![]const f32 {
        return self.plat.stepAudio(self.mixer.device, frames);
    }
};

const chirp_id = core.ContentId.fromString("foundry:sounds.chirp");

test "a content id becomes samples in a device buffer" {
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 4 });
    defer s.deinit();

    // Full-scale negative, silence, half, and just under full-scale positive.
    try s.writeWav("sounds/chirp.wav", &.{ -32768, 0, 16384, 32767 });
    try s.loadPackage("foundry:core", package_source);

    const v = try s.mixer.play(chirp_id, .{});
    try testing.expect(s.mixer.isPlaying(v));

    // A mono device, so nothing is scaled by a pan gain: these are the sixteen-bit
    // values divided by 32768, exactly, all the way from a file the test wrote.
    try testing.expectEqualSlices(f32, &[_]f32{
        -1.0,
        0.0,
        0.5,
        32767.0 / 32768.0,
    }, try s.step(4));

    s.mixer.update();
    try testing.expectEqual(@as(u32, 0), s.mixer.activeVoices());
}

test "the content id is what identifies a sound, never its path" {
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 2 });
    defer s.deinit();

    // The record names a file under a directory layout of the package's own choosing,
    // and nothing at runtime can ask for it that way (ADR-0021).
    try s.writeWav("audio/private/wherever.wav", &.{ 16384, 16384 });
    try s.loadPackage("foundry:core",
        \\foundry:sound foundry:sounds.chirp {
        \\    source "audio/private/wherever.wav"
        \\}
    );

    _ = try s.mixer.play(chirp_id, .{});
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5 }, try s.step(2));
}

test "a sound that is really a texture is refused where the id was written" {
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 2 });
    defer s.deinit();

    try s.writeWav("sounds/chirp.wav", &.{16384});
    try s.loadPackage("foundry:core",
        \\foundry:texture foundry:sounds.chirp { source "sounds/chirp.wav" }
    );

    // Not `UnknownSound`: the registry's own error survives, because "there is no such
    // record", "its file is missing" and "it is the wrong record type" send an author to
    // three different places.
    try testing.expectError(error.WrongSchema, s.mixer.play(chirp_id, .{}));
    try testing.expectError(
        error.AssetNotFound,
        s.mixer.play(core.ContentId.fromString("foundry:sounds.absent"), .{}),
    );
    try testing.expectEqual(@as(u32, 0), s.mixer.activeVoices());
}

test "a corrupt wav is a different sentence from an unsupported one" {
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 2 });
    defer s.deinit();

    try s.writeFile("sounds/chirp.wav", "not a RIFF file at all");
    try s.loadPackage("foundry:core", package_source);
    try testing.expectError(error.InvalidAsset, s.mixer.play(chirp_id, .{}));

    // And a valid file outside the subset maps to the version error, because the file is
    // fine and the fix is to transcode it rather than to go looking for corruption.
    const gpa = s.gpa;
    const bytes = try wavBytes(gpa, &.{ 0, 0 });
    defer gpa.free(bytes);
    // Format tag 7 is mu-law, at offset 20: past "RIFF", the size, "WAVE", "fmt " and
    // its own size.
    bytes[20] = 7;
    try s.writeFile("sounds/chirp.wav", bytes);
    try testing.expectError(error.UnsupportedVersion, s.mixer.play(chirp_id, .{}));
}

test "the mixer holds the asset for the voice's lifetime" {
    // Hazard one of §7: the game cannot drop the last reference to something it can
    // still hear. `testing.allocator` is half the assertion — an early free is a
    // use-after-free on the device thread — and the samples staying right is the other.
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 2, .voices = 1 });
    defer s.deinit();

    try s.writeWav("sounds/chirp.wav", &.{ 16384, 16384 });
    try s.loadPackage("foundry:core", package_source);

    const v = try s.mixer.play(chirp_id, .{ .looping = true });

    // The game acquires and releases around the mixer's back, which is exactly what a
    // level teardown looks like. The mixer's own reference is what keeps it alive.
    const held = try s.assets.acquire(s.gpa, chirp_id);
    s.assets.release(held);
    _ = s.assets.evictUnused(s.gpa);

    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5 }, try s.step(2));
    try testing.expectEqual(@as(u32, 1), s.mixer.soundCount());

    // And once the voice ends, the mixer's reference goes with it and the sound really
    // does become evictable.
    s.mixer.stop(v);
    _ = try s.step(2);
    s.mixer.update();
    _ = s.assets.evictUnused(s.gpa);
    try testing.expectEqual(@as(u32, 0), s.mixer.soundCount());
}

test "a reload while a voice is playing swaps the sound without cutting it off" {
    // Hazard two of §7, and the reason the loader's payload is a handle rather than a
    // pointer to samples. `Registry.reload` calls `unload` on the old payload at the top
    // of a frame while the device thread is in the middle of reading it.
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 2, .voices = 2 });
    defer s.deinit();

    try s.writeWav("sounds/chirp.wav", &.{ 16384, 16384 });
    try s.loadPackage("foundry:core", package_source);

    const old = try s.mixer.play(chirp_id, .{ .looping = true });
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5 }, try s.step(2));

    // The author saves a quieter take over the top of it.
    try s.writeWav("sounds/chirp.wav", &.{ 8192, 8192 });
    const handle = try s.assets.acquire(s.gpa, chirp_id);
    defer s.assets.release(handle);
    try s.assets.reload(s.gpa, handle);

    // Two sounds are alive at once: the new one, and the old one that a voice is still
    // reading. Freeing the old one here would be the use-after-free this design exists
    // to make impossible.
    try testing.expectEqual(@as(u32, 2), s.mixer.soundCount());
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5 }, try s.step(2));

    // A voice started after the reload gets the new take.
    s.mixer.stop(old);
    _ = try s.step(2);
    s.mixer.update();
    // And now nothing is reading the old samples, so they are gone.
    try testing.expectEqual(@as(u32, 1), s.mixer.soundCount());

    _ = try s.mixer.play(chirp_id, .{ .looping = true });
    try testing.expectEqualSlices(f32, &[_]f32{ 0.25, 0.25 }, try s.step(2));
}

test "a sound requested on the background pool plays the same samples as one acquired" {
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 4 });
    defer s.deinit();
    const pool = try s.os.startBackground(s.gpa, .{ .count = 2 });
    defer pool.deinit();
    // Before the pool goes: the registry must not quiesce into a stopped one.
    defer s.assets.useTasks(core.tasks.immediate);
    s.assets.useTasks(pool.tasks());

    try s.writeWav("sounds/chirp.wav", &.{ -32768, 0, 16384, 32767 });
    try s.loadPackage("foundry:core", package_source);

    // Decoded on a worker, handed to the mixer by a pump on this thread.
    const requested = try s.assets.request(s.gpa, chirp_id);
    defer s.assets.release(requested);
    while (s.assets.state(requested).? == .pending) {
        _ = s.assets.pump(s.gpa, .{});
        pool.tasks().wait();
    }
    try testing.expectEqual(asset.State.ready, s.assets.state(requested).?);

    // `play` acquires the entry the request made ready, and hears exactly what a synchronous
    // load gives (the test above).
    const v = try s.mixer.play(chirp_id, .{});
    try testing.expect(s.mixer.isPlaying(v));
    try testing.expectEqualSlices(f32, &[_]f32{ -1.0, 0.0, 0.5, 32767.0 / 32768.0 }, try s.step(4));
    s.mixer.update();
}

test "an .ogg plays through the same play, decoded as the reference decodes it" {
    // M30: the loader picks the decoder by the file's first bytes, and the record and the
    // call are the ones a .wav uses.
    // A mono device at the file's own rate, so the voice copies samples unchanged.
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 64, .sample_rate = 44_100 });
    defer s.deinit();
    const fixture = asset.ogg.fixtures[0];
    try s.writeFile("music/theme.ogg", fixture.ogg);
    try s.loadPackage("foundry:core",
        \\foundry:sound foundry:sounds.chirp {
        \\    source "music/theme.ogg"
        \\}
    );
    var expected = try asset.vorbis.decode(s.gpa, fixture.ogg, .{});
    defer expected.deinit(s.gpa);

    _ = try s.mixer.play(chirp_id, .{});
    try testing.expectEqual(expected.sample_rate, s.plat.audioInfo(s.mixer.device).?.sample_rate);
    try testing.expectEqualSlices(f32, expected.samples[0..64], try s.step(64));
}

test "stream is for compressed sounds: a streamed .wav is refused, a streamed .ogg loads" {
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 2 });
    defer s.deinit();
    try s.writeWav("sounds/chirp.wav", &.{ 16384, 16384 });
    try s.writeFile("music/theme.ogg", asset.ogg.fixtures[0].ogg);
    try s.loadPackage("foundry:core",
        \\foundry:sound foundry:sounds.chirp {
        \\    source "sounds/chirp.wav"
        \\    stream true
        \\}
        \\foundry:sound foundry:sounds.theme {
        \\    source "music/theme.ogg"
        \\    stream true
        \\}
    );
    try testing.expectError(error.UnsupportedVersion, s.mixer.play(chirp_id, .{}));
    _ = try s.mixer.play(core.ContentId.fromString("foundry:sounds.theme"), .{});
}

test "a loop region is checked against the decoded length at load, resident or streamed" {
    // M31 Step 1 (`mixing.md` §4.1): the record alone cannot know a sound's length, so a
    // region past the end, or one starting at or after it, is refused where the sound decodes.
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 2 });
    defer s.deinit();
    var frames: [200]i16 = undefined;
    for (&frames, 0..) |*f, i| f.* = @intCast(i * 100);
    try s.writeWav("sounds/chirp.wav", &frames);
    try s.writeFile("music/theme.ogg", asset.ogg.fixtures[0].ogg);
    try s.loadPackage("foundry:core",
        \\foundry:sound foundry:sounds.fits { source "sounds/chirp.wav" loop_start 50 loop_end 200 }
        \\foundry:sound foundry:sounds.past { source "sounds/chirp.wav" loop_start 50 loop_end 201 }
        \\foundry:sound foundry:sounds.after { source "sounds/chirp.wav" loop_start 200 }
        \\foundry:sound foundry:sounds.theme_fits { source "music/theme.ogg" stream true loop_start 64 }
        \\foundry:sound foundry:sounds.theme_after { source "music/theme.ogg" stream true loop_start 100000000 }
    );
    const id = core.ContentId.fromString;
    _ = try s.mixer.play(id("foundry:sounds.fits"), .{});
    try testing.expectError(error.InvalidAsset, s.mixer.play(id("foundry:sounds.past"), .{}));
    try testing.expectError(error.InvalidAsset, s.mixer.play(id("foundry:sounds.after"), .{}));
    _ = try s.mixer.play(id("foundry:sounds.theme_fits"), .{});
    try testing.expectError(error.InvalidAsset, s.mixer.play(id("foundry:sounds.theme_after"), .{}));
}

test "a spatial play uses its sound's attenuation record, and a play may name another" {
    // M31 Step 4 (`mixing.md` §5): the attenuation resolves where the ID does, at play, and a
    // record of the wrong schema is refused by name.
    const s = try Stack.init(.{ .buffer_frames = 4 });
    defer s.deinit();
    var frames: [4000]i16 = undefined;
    @memset(&frames, 16384);
    try s.writeWav("sounds/chirp.wav", &frames);
    try s.loadPackage("foundry:core",
        \\foundry:audio_attenuation foundry:att.near { model "linear" max_distance 4 }
        \\foundry:audio_attenuation foundry:att.far { model "linear" max_distance 40 }
        \\foundry:sound foundry:sounds.chirp { source "sounds/chirp.wav" attenuation foundry:att.near }
    );
    const id = core.ContentId.fromString;
    // Two metres to the right: hard right, and a third of the way from 1 m to 4 m.
    _ = try s.mixer.play(chirp_id, .{ .position = .init(2, 0, 0) });
    s.mixer.update();
    var out = try s.step(4);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5 * 2.0 / 3.0), out[1], 1e-6);
    s.mixer.stopAll();
    s.mixer.update();
    _ = try s.step(4);
    s.mixer.update();
    // Named on the play instead: 1 − (2 − 1)/(40 − 1).
    _ = try s.mixer.play(chirp_id, .{ .position = .init(2, 0, 0), .attenuation = id("foundry:att.far") });
    s.mixer.update();
    out = try s.step(4);
    try testing.expectApproxEqAbs(@as(f32, 0.5 * (1.0 - 1.0 / 39.0)), out[1], 1e-6);
    // A sound is not an attenuation.
    try testing.expectError(error.UnknownAttenuation, s.mixer.play(chirp_id, .{ .position = .zero, .attenuation = chirp_id }));
}

test "an Opus file is refused as the valid file it is, and a broken Ogg as broken" {
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 2 });
    defer s.deinit();
    const gpa = s.gpa;
    // The first page of a fixture, rewritten to announce Opus, with its CRC recomputed.
    const page = try gpa.dupe(u8, asset.ogg.fixtures[2].ogg[0..58]);
    defer gpa.free(page);
    @memcpy(page[28..36], "OpusHead");
    page[5] |= 0x04;
    std.mem.writeInt(u32, page[22..26], 0, .little);
    std.mem.writeInt(u32, page[22..26], asset.ogg.crc32(page), .little);
    try s.writeFile("music/opus.ogg", page);
    page[30] ^= 0xff; // The CRC no longer matches.
    try s.writeFile("music/broken.ogg", page);
    try s.loadPackage("foundry:core",
        \\foundry:sound foundry:sounds.opus {
        \\    source "music/opus.ogg"
        \\}
        \\foundry:sound foundry:sounds.broken {
        \\    source "music/broken.ogg"
        \\}
    );
    try testing.expectError(error.UnsupportedVersion, s.mixer.play(core.ContentId.fromString("foundry:sounds.opus"), .{}));
    try testing.expectError(error.InvalidAsset, s.mixer.play(core.ContentId.fromString("foundry:sounds.broken"), .{}));
}

test "a streamed .ogg plays through content, decoded as it plays, and a reload mid-stream keeps it" {
    // M30 Step 5: `stream true` keeps the file compressed and decodes it into a ring as the
    // voice plays. Mono at the files' own rate, so the voice copies frames unchanged.
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 64, .sample_rate = 44_100 });
    defer s.deinit();
    const first = asset.ogg.fixtures[0];
    const second = asset.ogg.fixtures[1];
    try s.writeFile("music/theme.ogg", first.ogg);
    try s.loadPackage("foundry:core",
        \\foundry:sound foundry:sounds.chirp {
        \\    source "music/theme.ogg"
        \\    stream true
        \\}
    );
    var old_take = try asset.vorbis.decode(s.gpa, first.ogg, .{});
    defer old_take.deinit(s.gpa);
    var new_take = try asset.vorbis.decode(s.gpa, second.ogg, .{});
    defer new_take.deinit(s.gpa);
    try testing.expectEqual(old_take.sample_rate, new_take.sample_rate);

    const old = try s.mixer.play(chirp_id, .{});
    try testing.expectEqual(@as(u32, 1), s.mixer.streamsInUse());
    try testing.expectEqualSlices(f32, old_take.samples[0..64], try s.step(64));

    // The author saves another take while the first streams: two sounds are alive, and the
    // voice keeps decoding the bytes it started with.
    try s.writeFile("music/theme.ogg", second.ogg);
    const handle = try s.assets.acquire(s.gpa, chirp_id);
    defer s.assets.release(handle);
    try s.assets.reload(s.gpa, handle);
    try testing.expectEqual(@as(u32, 2), s.mixer.soundCount());
    s.mixer.update();
    try testing.expectEqualSlices(f32, old_take.samples[64..128], try s.step(64));

    s.mixer.stop(old);
    _ = try s.step(64);
    s.mixer.update();
    try testing.expectEqual(@as(u32, 1), s.mixer.soundCount());
    try testing.expectEqual(@as(u32, 0), s.mixer.streamsInUse());

    _ = try s.mixer.play(chirp_id, .{});
    try testing.expectEqualSlices(f32, new_take.samples[0..64], try s.step(64));
}

/// One of the gallery's texture decodes, as its loader's decode phase does it: the PNG, then
/// its whole mip chain (`background.md` §7).
const GalleryDecode = struct {
    bytes: []const u8,
    failed: bool = false,

    fn run(erased: *anyopaque) void {
        const self: *GalleryDecode = @ptrCast(@alignCast(erased));
        var image = asset.png.decode(testing.allocator, self.bytes, .{}) catch {
            self.failed = true;
            return;
        };
        defer image.deinit(testing.allocator);
        var chain = asset.mips.generate(testing.allocator, image, .srgb) catch {
            self.failed = true;
            return;
        };
        chain.deinit(testing.allocator);
    }
};

test "a stream's first decode, queued behind the whole gallery, arrives inside its half-second margin" {
    // `music.md` §6.2: a refill starts when half a second is left, so the pool must deliver
    // frames within that even behind its worst neighbour, M27's gallery. Here the stream's
    // first decode is queued behind all eight of the gallery's, half a second before the voice
    // is due: a refill's position at its worst. Played in real time, so only a release build
    // says anything; Debug skips it.
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    const gpa = testing.allocator;
    const options = @import("mod_pipeline_options");

    const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-stream-margin", .env = &.{} });
    defer os.deinit();
    const threads = platform.background.defaultCount();
    const pool = try os.startBackground(gpa, .{ .count = threads });
    defer pool.deinit();
    const plat = try null_backend.Platform.init(gpa, .{});
    defer plat.deinit();
    var store: asset.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    var assets: asset.Registry = .init(gpa, os, &store, .{});
    const mixer = try Mixer.init(gpa, plat, &assets, .{ .tasks = pool.tasks() });
    defer {
        mixer.shutdown();
        assets.deinit(gpa);
        mixer.deinit();
    }
    const sound = try mixer.insertStreamed(asset.ogg.fixtures[2].ogg);

    var pngs: [8][]u8 = undefined;
    for (&pngs, 0..) |*png, i| {
        const name = try std.fmt.allocPrint(gpa, "gallery{d}.png", .{i});
        defer gpa.free(name);
        const path = try platform.os.joinPath(gpa, &.{ options.gallery_dir, name });
        defer gpa.free(path);
        png.* = try os.readFile(gpa, path, 16 << 20);
    }
    defer for (pngs) |png| gpa.free(png);

    var decodes: [8]GalleryDecode = undefined;
    var done: [8]core.tasks.Done = @splat(.{});
    for (&decodes, &done, pngs) |*d, *flag, png| {
        d.* = .{ .bytes = png };
        try pool.tasks().start(.{ .context = d, .call = GalleryDecode.run }, flag);
    }
    const queued = os.monotonicNanos();
    const margin: u64 = 24_000;
    const v = try mixer.playSound(sound, .{ .start_at = mixer.clock() + margin, .looping = true });

    // Ten-millisecond buffers at their own pace, for two seconds: the start, and the refills
    // after it while the gallery may still be decoding. Arrivals are looked for every
    // millisecond between buffers.
    var first_frames_ns: ?u64 = null;
    var gallery_ns: ?u64 = null;
    var deadline = queued;
    var buffers: u32 = 0;
    while (buffers < 200) {
        os.sleep(.fromMillis(1));
        const at = os.monotonicNanos() - queued;
        if (first_frames_ns == null and (mixer.streamBuffered(v) orelse 0) > 0) first_frames_ns = at;
        if (gallery_ns == null) {
            var all = true;
            for (&done) |*flag| all = all and flag.isSet();
            if (all) gallery_ns = at;
        }
        if (os.monotonicNanos() < deadline) continue;
        _ = try plat.stepAudio(mixer.device, 480);
        mixer.update();
        deadline += 10 * std.time.ns_per_ms;
        buffers += 1;
    }
    pool.tasks().wait();
    for (decodes) |d| try testing.expect(!d.failed);

    std.debug.print("stream margin ({t}, {d} background thread(s)): first frames after {d:.1} ms behind the gallery (done after {d:.1} ms); margin 500 ms; {d} underrun(s)\n", .{
        @import("builtin").mode,
        threads,
        @as(f64, @floatFromInt(first_frames_ns orelse 0)) / 1e6,
        @as(f64, @floatFromInt(gallery_ns orelse 0)) / 1e6,
        mixer.underruns(),
    });
    try testing.expect(first_frames_ns != null);
    try testing.expect(first_frames_ns.? < margin * std.time.ns_per_s / 48_000);
    try testing.expectEqual(@as(u32, 0), mixer.underruns());
}

// -- M31 Step 6: the bus tree (`mixing.md` §8) ---------------------------------------------

/// Compiles `source` as package `name` into bytes of its own, kept in `keep`, which must outlive
/// the stack: the store borrows a package's bytes, and `Stack.loadPackage` reuses one buffer.
fn addPackage(s: *Stack, keep: *std.ArrayList([]u8), name: []const u8, source: []const u8) !void {
    var doc = try data.parser.parse(s.gpa, "content.fdt", source, .{ .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?] }, &s.diags);
    defer doc.deinit(s.gpa);
    var pkg = try data.check.Package.init(s.gpa, name, 1, .default);
    defer pkg.deinit(s.gpa);
    try pkg.addDocument(s.gpa, &doc, &s.schemas, &s.diags);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(s.gpa);
    try data.fpk.write(s.gpa, &pkg, &s.schemas, &bytes);
    const owned = try bytes.toOwnedSlice(s.gpa);
    try keep.append(s.gpa, owned);
    const handle = try s.store.add(s.gpa, name, owned, &s.schemas, &s.diags);
    try s.assets.mount(s.gpa, handle, s.dir);
}

fn freeAll(list: *std.ArrayList([]u8)) void {
    for (list.items) |b| testing.allocator.free(b);
    list.deinit(testing.allocator);
}

const mix_source =
    \\foundry:audio_bus t:bus.master { gain 0.5 }
    \\foundry:audio_bus t:bus.music { parent t:bus.master gain 0.5 }
    \\foundry:audio_bus t:bus.world { parent t:bus.master }
    \\foundry:audio_bus t:bus.effects { parent t:bus.world gain 0.25 }
    \\foundry:audio_bus t:bus.other_root { }
    \\foundry:audio_bus t:bus.elsewhere { parent t:bus.other_root }
    \\foundry:sound t:s.music { source "dc.wav" bus t:bus.music }
    \\foundry:sound t:s.effect { source "dc.wav" bus t:bus.effects }
    \\foundry:sound t:s.plain { source "dc.wav" }
    \\foundry:sound t:s.lost { source "dc.wav" bus t:bus.elsewhere }
;

fn dcStack(keep: *std.ArrayList([]u8), source: []const u8) !*Stack {
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 8 });
    errdefer s.deinit();
    var frames: [4000]i16 = undefined;
    @memset(&frames, 16384);
    try s.writeWav("dc.wav", &frames);
    try addPackage(s, keep, "t:content", source);
    return s;
}

test "voices mix through their buses' gains to the root, and a missing bus is the root's" {
    var keep: std.ArrayList([]u8) = .empty;
    defer freeAll(&keep);
    const s = try dcStack(&keep, mix_source);
    defer s.deinit();
    const id = core.ContentId.fromString;
    try s.mixer.useMix(id("t:bus.master"));
    const tree = s.mixer.mirror.?;
    // The root, then the rest by ascending content ID; the other root's buses are not here.
    try testing.expectEqual(@as(usize, 4), tree.count());
    try testing.expect(tree.ids[0].eql(id("t:bus.master")));
    try testing.expect(tree.indexOf(id("t:bus.elsewhere")) == null);
    // Children before parents: effects before world.
    const effects = tree.indexOf(id("t:bus.effects")).?;
    const world = tree.indexOf(id("t:bus.world")).?;
    try testing.expect(std.mem.indexOfScalar(u16, tree.order, effects).? < std.mem.indexOfScalar(u16, tree.order, world).?);
    for (1..tree.order.len) |i| {
        const a = tree.order[i - 1];
        const b = tree.order[i];
        // Siblings in order of index, which is ascending content ID.
        if (tree.parents[a] == tree.parents[b]) try testing.expect(a < b);
    }

    const cases = [_]struct { sound: []const u8, gain: f32 }{
        .{ .sound = "t:s.music", .gain = 0.5 * 0.5 },
        .{ .sound = "t:s.effect", .gain = 0.25 * 1 * 0.5 },
        .{ .sound = "t:s.plain", .gain = 0.5 },
        .{ .sound = "t:s.lost", .gain = 0.5 },
    };
    for (cases) |case| {
        _ = try s.mixer.play(id(case.sound), .{});
        s.mixer.update();
        const out = try s.step(8);
        for (out) |sample| try testing.expectApproxEqAbs(0.5 * case.gain, sample, 1e-7);
        s.mixer.stopAll();
        s.mixer.update();
        _ = try s.step(8);
        s.mixer.update();
    }
    try testing.expectEqual(@as(u32, 1), s.mixer.misrouted());
    // The master gain still applies, after the root.
    s.mixer.setMasterGain(0.5);
    _ = try s.mixer.play(id("t:s.plain"), .{});
    s.mixer.update();
    for (try s.step(8)) |sample| try testing.expectApproxEqAbs(0.5 * 0.5 * 0.5, sample, 1e-7);
}

test "setBusGain ramps a bus's own gain, times its record's, and a long buffer mixes in blocks" {
    var keep: std.ArrayList([]u8) = .empty;
    defer freeAll(&keep);
    const s = try dcStack(&keep, mix_source);
    defer s.deinit();
    const id = core.ContentId.fromString;
    try s.mixer.useMix(id("t:bus.master"));
    _ = try s.mixer.play(id("t:s.music"), .{ .looping = true });
    s.mixer.update();
    _ = try s.step(8);
    try testing.expect(s.mixer.setBusGainChecked(id("t:bus.music"), 0, 40));
    try testing.expect(!s.mixer.setBusGainChecked(id("t:bus.elsewhere"), 0, 40));
    try testing.expect(!s.mixer.setBusGainChecked(id("t:bus.music"), -1, 40));
    s.mixer.update();
    // 48 frames on an 8-frame device's tree: six blocks, the ramp continuous across them.
    const out = try s.step(48);
    for (out, 0..) |sample, f| {
        const ramp: f32 = if (f >= 40) 0 else 1 - @as(f32, @floatFromInt(f)) / 40;
        try testing.expectApproxEqAbs(0.5 * 0.25 * ramp, sample, 1e-6);
    }
}

test "a tree the records cannot make is refused by name, and the mix plays on" {
    const id = core.ContentId.fromString;
    const cases = [_]struct { source: []const u8, root: []const u8, err: anyerror }{
        .{ .source = "foundry:audio_bus t:r { parent t:p }\nfoundry:audio_bus t:p { }", .root = "t:r", .err = error.RootHasParent },
        .{ .source = "foundry:sound t:r { source \"dc.wav\" }", .root = "t:r", .err = error.NotABus },
        .{ .source = "foundry:audio_bus t:r { }", .root = "t:nowhere", .err = error.NotABus },
        .{ .source = "foundry:audio_bus t:r { }\nfoundry:audio_bus t:a { parent t:b }\nfoundry:audio_bus t:b { parent t:a }", .root = "t:r", .err = error.Cycle },
        .{ .source = "foundry:audio_bus t:r { }\nfoundry:sound t:s { source \"dc.wav\" }\nfoundry:audio_bus t:a { parent t:s }", .root = "t:r", .err = error.NotABus },
        .{ .source = "foundry:audio_bus t:r { effects [ t:s ] }\nfoundry:sound t:s { source \"dc.wav\" }", .root = "t:r", .err = error.InvalidBus },
    };
    for (cases) |case| {
        var keep: std.ArrayList([]u8) = .empty;
        defer freeAll(&keep);
        const s = try dcStack(&keep, case.source);
        defer s.deinit();
        try testing.expectError(case.err, s.mixer.useMix(id(case.root)));
        try testing.expect(s.mixer.mirror == null);
    }

    // Nine below the root is too deep; thirty-three in all is too many.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(testing.allocator);
    try deep.appendSlice(testing.allocator, "foundry:audio_bus t:b0 { }\n");
    for (1..10) |i| try deep.print(testing.allocator, "foundry:audio_bus t:b{d} {{ parent t:b{d} }}\n", .{ i, i - 1 });
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(testing.allocator);
    try wide.appendSlice(testing.allocator, "foundry:audio_bus t:b0 { }\n");
    for (1..33) |i| try wide.print(testing.allocator, "foundry:audio_bus t:b{d} {{ parent t:b0 }}\n", .{i});
    for ([_]struct { source: []const u8, err: anyerror }{ .{ .source = deep.items, .err = error.TooDeep }, .{ .source = wide.items, .err = error.TooManyBuses } }) |case| {
        var keep: std.ArrayList([]u8) = .empty;
        defer freeAll(&keep);
        const s = try dcStack(&keep, case.source);
        defer s.deinit();
        try testing.expectError(case.err, s.mixer.useMix(id("t:b0")));
    }
}

test "a reload that changes a gain keeps the tree, and one that changes its shape swaps it" {
    var keep: std.ArrayList([]u8) = .empty;
    defer freeAll(&keep);
    const s = try dcStack(&keep, mix_source);
    defer s.deinit();
    const id = core.ContentId.fromString;
    try s.mixer.useMix(id("t:bus.master"));
    s.mixer.update();
    _ = try s.step(8);
    s.mixer.update();
    try testing.expectEqual(@as(usize, 0), s.mixer.retiring.items.len);
    const first = s.mixer.mirror.?;
    _ = try s.mixer.play(id("t:s.lost"), .{ .looping = true });

    // A later package changes the music bus's gain: the same tree, a new gain.
    try addPackage(s, &keep, "m:gain", "foundry:audio_bus t:bus.music { parent t:bus.master gain 1 }");
    try s.mixer.contentChanged();
    try testing.expectEqual(first, s.mixer.mirror.?);
    try testing.expectEqual(@as(f32, 1), first.records[first.indexOf(id("t:bus.music")).?].gain);

    // Another moves the lost sound's bus under this root: a new shape, swapped in, and the
    // voice already playing follows its sound's bus into it.
    try addPackage(s, &keep, "m:shape", "foundry:audio_bus t:bus.elsewhere { parent t:bus.master gain 0.5 }");
    try s.mixer.contentChanged();
    try testing.expect(first != s.mixer.mirror.?);
    try testing.expectEqual(@as(usize, 1), s.mixer.retiring.items.len);
    s.mixer.update();
    const out = try s.step(8);
    for (out) |sample| try testing.expectApproxEqAbs(0.5 * 0.5 * 0.5, sample, 1e-7);
    // The old tree goes once the callback has let it go, and `testing.allocator` sees no leak.
    s.mixer.update();
    try testing.expectEqual(@as(usize, 0), s.mixer.retiring.items.len);
}

// -- M31 Step 7: effects on buses (`mixing.md` §9) ------------------------------------------

const fx_source =
    \\foundry:audio_bus t:bus.master { effects [ t:fx.muffle t:fx.echo ] }
    \\foundry:audio_filter t:fx.muffle { shape "lowpass" frequency 500 }
    \\foundry:audio_delay t:fx.echo { time 0.25 wet 0 }
    \\foundry:audio_bus t:bus.world { parent t:bus.master effects [ t:fx.room ] }
    \\foundry:audio_reverb t:fx.room { decay 1.2 wet 0.3 }
    \\foundry:sound t:s.buzz { source "buzz.wav" }
;

fn buzzStack(keep: *std.ArrayList([]u8)) !*Stack {
    const s = try Stack.init(.{ .channels = 1, .buffer_frames = 256 });
    errdefer s.deinit();
    // The device's Nyquist frequency, which a 500 Hz low-pass all but removes.
    var frames: [48_000]i16 = undefined;
    for (&frames, 0..) |*f, i| f.* = if (i % 2 == 0) 16384 else -16384;
    try s.writeWav("buzz.wav", &frames);
    try addPackage(s, keep, "t:content", fx_source);
    return s;
}

fn peakOf(s: *Stack, buffers: usize) !f32 {
    var peak: f32 = 0;
    for (0..buffers) |_| {
        s.mixer.update();
        for (try s.step(256)) |x| peak = @max(peak, @abs(x));
    }
    return peak;
}

test "a bus's filter shapes what reaches it, and setEffect retunes it in place" {
    var keep: std.ArrayList([]u8) = .empty;
    defer freeAll(&keep);
    const s = try buzzStack(&keep);
    defer s.deinit();
    const id = core.ContentId.fromString;
    try s.mixer.useMix(id("t:bus.master"));
    _ = try s.mixer.play(id("t:s.buzz"), .{ .looping = true });
    _ = try peakOf(s, 4);
    try testing.expect(try peakOf(s, 4) < 0.01);
    // Opened to a high-pass at the same frequency: the buzz comes through nearly whole.
    try testing.expect(s.mixer.setEffectChecked(id("t:bus.master"), 0, .{ .filter = .{ .shape = .highpass, .frequency = 500 } }, 0));
    _ = try peakOf(s, 2);
    try testing.expect(try peakOf(s, 4) > 0.45);

    // Refused: no such bus or slot, another kind, a delay's time, values out of range.
    try testing.expect(!s.mixer.setEffectChecked(id("t:bus.nowhere"), 0, .{ .filter = .{ .shape = .lowpass, .frequency = 500 } }, 0));
    try testing.expect(!s.mixer.setEffectChecked(id("t:bus.master"), 2, .{ .filter = .{ .shape = .lowpass, .frequency = 500 } }, 0));
    try testing.expect(!s.mixer.setEffectChecked(id("t:bus.master"), 0, .{ .delay = .{ .time = 0.25 } }, 0));
    try testing.expect(!s.mixer.setEffectChecked(id("t:bus.master"), 1, .{ .delay = .{ .time = 0.5 } }, 0));
    try testing.expect(s.mixer.setEffectChecked(id("t:bus.master"), 1, .{ .delay = .{ .time = 0.25, .wet = 0.5 } }, 0));
    try testing.expect(!s.mixer.setEffectChecked(id("t:bus.master"), 0, .{ .filter = .{ .shape = .lowpass, .frequency = 5 } }, 0));
}

test "a reload that retunes an effect keeps the tree, and one that resizes it swaps the tree" {
    var keep: std.ArrayList([]u8) = .empty;
    defer freeAll(&keep);
    const s = try buzzStack(&keep);
    defer s.deinit();
    const id = core.ContentId.fromString;
    try s.mixer.useMix(id("t:bus.master"));
    s.mixer.update();
    _ = try s.step(256);
    s.mixer.update();
    const first = s.mixer.mirror.?;
    try addPackage(s, &keep, "m:wet", "foundry:audio_reverb t:fx.room { decay 3 wet 0.6 }");
    try s.mixer.contentChanged();
    try testing.expectEqual(first, s.mixer.mirror.?);
    try testing.expectEqual(@as(f32, 3), first.effect_values[2].reverb.decay);
    try addPackage(s, &keep, "m:size", "foundry:audio_reverb t:fx.room { size 1.5 }");
    try s.mixer.contentChanged();
    try testing.expect(first != s.mixer.mirror.?);
    s.mixer.update();
    _ = try s.step(256);
    s.mixer.update();
    try testing.expectEqual(@as(usize, 0), s.mixer.retiring.items.len);
}

// -- M31 Step 8: the limiter's latency, and the mixing speed (`mixing.md` §9, §14) -----------

test "mixerLatency is the longest path's sum of limiter lookaheads" {
    var keep: std.ArrayList([]u8) = .empty;
    defer freeAll(&keep);
    const s = try dcStack(&keep,
        \\foundry:audio_bus t:root { effects [ t:fx.limit ] }
        \\foundry:audio_limiter t:fx.limit { lookahead 0.002 }
        \\foundry:audio_bus t:world { parent t:root effects [ t:fx.glue t:fx.guard ] }
        \\foundry:audio_compressor t:fx.glue { }
        \\foundry:audio_limiter t:fx.guard { lookahead 0.005 }
        \\foundry:audio_bus t:ui { parent t:root }
    );
    defer s.deinit();
    try testing.expectEqual(@as(u32, 0), s.mixer.mixerLatency());
    try s.mixer.useMix(core.ContentId.fromString("t:root"));
    try testing.expectEqual(@as(u32, 96 + 240), s.mixer.mixerLatency());
}

/// The court's mix, as §14's timing test loads it: a limiter on the master, a reverb,
/// compressor and filter on the world, and buses for music, effects, ambience and UI.
const court_shaped =
    \\foundry:audio_bus t:bus.master { effects [ t:fx.limit ] }
    \\foundry:audio_limiter t:fx.limit { }
    \\foundry:audio_bus t:bus.music { parent t:bus.master }
    \\foundry:audio_bus t:bus.world { parent t:bus.master effects [ t:fx.room t:fx.glue t:fx.muffle ] }
    \\foundry:audio_reverb t:fx.room { decay 1.4 wet 0.18 }
    \\foundry:audio_compressor t:fx.glue { threshold_db -20 ratio 2 }
    \\foundry:audio_filter t:fx.muffle { shape "lowpass" frequency 20000 }
    \\foundry:audio_bus t:bus.effects { parent t:bus.world }
    \\foundry:audio_bus t:bus.ambience { parent t:bus.world }
    \\foundry:audio_bus t:bus.ui { parent t:bus.master }
    \\foundry:sound t:s.music { source "noise.wav" bus t:bus.music }
    \\foundry:sound t:s.effect { source "noise.wav" bus t:bus.effects }
    \\foundry:sound t:s.ambience { source "noise.wav" bus t:bus.ambience }
    \\foundry:sound t:s.ui { source "noise.wav" bus t:bus.ui }
;

test "mixing speed: the court's full load, frames per second, single-threaded, printed" {
    // §14 and criterion 6: at least 20x real time on the Arc PC's i3 in ReleaseSafe. Debug
    // measures nothing worth reading, so it skips, as the stream margin does.
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    var keep: std.ArrayList([]u8) = .empty;
    defer freeAll(&keep);
    const s = try Stack.init(.{ .channels = 2, .buffer_frames = 512 });
    defer s.deinit();
    var noise: [48_000]i16 = undefined;
    var rng = core.rng.Pcg32.init(0x4e4f_4953, 0);
    for (&noise) |*n| n.* = @intCast(@as(i32, @intCast(rng.below(16384))) - 8192);
    try s.writeWav("noise.wav", &noise);
    try addPackage(s, &keep, "t:content", court_shaped);
    const id = core.ContentId.fromString;
    try s.mixer.useMix(id("t:bus.master"));
    // 32 voices: 8 music, 8 UI, and 16 spatial effects and ambience at seeded places, some
    // occluded, with a pitch so every voice resamples.
    for (0..8) |i| {
        _ = try s.mixer.play(id("t:s.music"), .{ .looping = true, .gain = 0.2, .pitch = 1.01 });
        _ = try s.mixer.play(id("t:s.ui"), .{ .looping = true, .gain = 0.2, .pitch = 0.99 });
        const a = try s.mixer.play(id("t:s.effect"), .{ .looping = true, .gain = 0.2, .position = .init(@floatFromInt(i), 0, -3), .pitch = 1.02 });
        const b = try s.mixer.play(id("t:s.ambience"), .{ .looping = true, .gain = 0.2, .position = .init(-@as(f32, @floatFromInt(i)), 1, 2) });
        if (i % 2 == 0) s.mixer.setOcclusion(a, 0.7);
        _ = b;
    }
    try testing.expectEqual(@as(u32, 32), s.mixer.activeVoices());
    const seconds = 20;
    const start = std.Io.Clock.awake.now(testing.io);
    var mixed: usize = 0;
    while (mixed < seconds * 48_000) : (mixed += 512) {
        s.mixer.update();
        _ = try s.step(512);
    }
    const ns: u64 = @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start.nanoseconds);
    const ratio = @as(f64, @floatFromInt(seconds)) * 1e9 / @as(f64, @floatFromInt(@max(ns, 1)));
    std.debug.print("mixing speed ({t}): {d:.0}x real time (32 voices, 16 spatial, 6 buses, 4 effects)\n", .{ @import("builtin").mode, ratio });
    try testing.expect(ratio >= 20);
    try testing.expectEqual(@as(u32, 0), s.mixer.misrouted());
}
