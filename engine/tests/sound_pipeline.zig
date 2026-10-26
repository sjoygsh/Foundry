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
