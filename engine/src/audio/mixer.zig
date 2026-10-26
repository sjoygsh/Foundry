//! The mixer: a voice table split across two threads, and the two rings between them.
//!
//! **No field below is written by both threads.** That sentence is the whole concurrency
//! design, and it is why no lock appears anywhere in this module. The split is stated on
//! each field and is worth checking against before adding one.
//!
//! Design: `docs/design/audio.md` §4, §5 and §7.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const asset = @import("asset");

const ring = @import("ring.zig");
const voice = @import("voice.zig");

const Allocator = std.mem.Allocator;
const Voice = voice.Voice;
const log = core.log.scoped(.audio);

/// Phantom tag for `VoiceHandle` (I1). See `root.zig` for why a voice is generational.
pub const Voices = opaque {};
pub const VoiceHandle = core.Handle(Voices);

/// Phantom tag for `SoundHandle`.
pub const Sounds = opaque {};

/// A decoded sound the mixer owns. **This, and not a pointer to the samples, is what the
/// asset loader's payload will be** — the indirection is what lets a hot reload retire a
/// sound while a voice is still reading it (`audio.md` §7).
pub const SoundHandle = core.Handle(Sounds);

pub const Options = struct {
    /// Voices that can play at once. `play` returns `error.NoFreeVoice` past this; there
    /// is no voice stealing in M5, deliberately (`audio.md` §11).
    voices: u32 = 32,
    /// Commands the game may issue between two device callbacks. Past this a command is
    /// dropped and counted — see `commandsDropped`.
    command_capacity: u32 = 256,
    sample_rate: u32 = 48_000,
    channels: u8 = 2,
    buffer_frames: u32 = 512,
    master_gain: f32 = 1.0,
};

pub const PlayParams = struct {
    gain: f32 = 1.0,
    /// -1 hard left, 0 centre, 1 hard right. Constant-power (`voice.panGains`).
    pan: f32 = 0.0,
    pitch: f32 = 1.0,
    looping: bool = false,
    /// The mixer frame the voice's first sample lands on (`clock`). Null starts it at the
    /// next callback. A frame already past when the command arrives starts it at once and
    /// counts in `lateStarts` (`music.md` §5.2).
    start_at: ?u64 = null,
    /// The envelope's value when the voice starts: 0 for a voice that will fade in.
    envelope: f32 = 1.0,
};

pub const Curve = voice.Curve;

/// A ramp of a voice's envelope (`music.md` §5.3).
pub const Fade = struct {
    /// The mixer frame the ramp begins on. Null, or a frame already past, begins it at the
    /// next callback, and it then runs its whole length.
    at: ?u64 = null,
    /// Zero sets the envelope at once.
    frames: u32,
    to: f32,
    curve: Curve = .linear,
    /// Retire the voice when the ramp ends.
    stop: bool = false,
};

pub const InitError = platform.AudioError || error{
    /// The device has more than two channels. Refused by name rather than silently mixed
    /// into the first two: surround is a real feature that Foundry does not have, and a
    /// game shipping to a 5.1 setup deserves the sentence (`audio.md` §5, §12).
    UnsupportedChannelCount,
};

pub const VoiceError = error{
    /// Every voice is in use. The game decides what to do; the mixer does not steal one.
    NoFreeVoice,
    /// No such sound, or one a hot reload has retired.
    UnknownSound,
    /// The command ring was full, so the voice could not be started. **Distinct from
    /// dropping a `set_gain`**: a `play` that vanished would strand a slot that no
    /// retirement is ever coming for, so the claim is undone and the caller told.
    CommandQueueFull,
};

/// What `play` can fail with: everything about a voice, plus everything about resolving a
/// content id. **The registry's own set, unflattened**, because a sound that is missing, a
/// sound whose file is gone and a sound that is really a texture send an author to three
/// different places, and collapsing them into one `UnknownSound` would throw that away.
pub const PlayError = VoiceError || asset.AcquireError;

/// A command, game thread to callback thread. One way, always.
const Command = union(enum) {
    play: Play,
    stop: struct { voice: VoiceHandle },
    stop_all,
    set_gain: struct { voice: VoiceHandle, gain: f32 },
    set_pan: struct { voice: VoiceHandle, left: f32, right: f32 },
    set_pitch: struct { voice: VoiceHandle, step: f64 },
    set_master_gain: struct { gain: f32 },
    fade: struct { voice: VoiceHandle, fade: Fade },
    fade_gain: struct { voice: VoiceHandle, gain: f32, frames: u32 },
};

const Play = struct {
    voice: VoiceHandle,
    /// Borrowed. Alive for the voice's whole life; §7's two mechanisms are what say so.
    samples: []const f32,
    channels: u8,
    frames: usize,
    step: f64,
    gain: f32,
    left: f32,
    right: f32,
    looping: bool,
    start_at: ?u64,
    envelope: f32,
};

/// Callback thread to game thread: a voice's first sample landed on `frame`, or the voice
/// gave its slot back.
const Event = struct {
    kind: enum(u8) { started, retired },
    slot: u32,
    generation: u32,
    frame: u64 = 0,
};

/// Game-thread bookkeeping for one voice.
const Slot = struct {
    /// Bumped on every claim, so a handle for a finished voice cannot address the one
    /// that took its place.
    generation: u32 = 0,
    playing: bool = false,
    sound: SoundHandle = .none,
    /// **Held for the voice's lifetime**, which is hazard one of `audio.md` §7: `play`
    /// acquires and the retirement drain releases, so a game cannot drop the last
    /// reference to something it can still hear. `.none` for a voice started from a
    /// sound the mixer was handed directly rather than through content.
    held: asset.AssetHandle = .none,
    /// The mixer frame the voice's first sample landed on, once `update` has heard.
    started_at: ?u64 = null,
};

/// A decoded sound and what keeps it alive.
const Stored = struct {
    sound: asset.Sound,
    /// Voices currently playing it. The samples cannot be freed above zero.
    refs: u32 = 0,
    /// Set when the owner has released it — a hot reload, or an explicit release — while
    /// a voice may still be reading. Freed by a later `update`.
    retired: bool = false,
};

pub fn MixerOf(comptime P: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        plat: *P,
        /// Borrowed. **The registry is torn down before the mixer**, exactly as it is
        /// before the renderer that registers the texture loader: the registry's `deinit`
        /// unloads through `soundLoader`, which calls back into this object.
        assets: *asset.Registry,

        /// The device this mixer opened. Public because a game that wants to silence
        /// output entirely does it through `platform`, and because the null backend's
        /// stepped device is driven by it in tests.
        device: platform.AudioDeviceHandle = .none,
        /// What the device actually does, which is not always what was asked for.
        /// Written once, before `ready`; read by the callback thereafter.
        info: platform.AudioInfo,

        /// **False until the mixer is fully built.** The device may call back the instant
        /// it is opened, and `info` is not known until after that call returns. Until
        /// this flips, the callback writes silence and touches nothing else.
        ready: std.atomic.Value(bool) = .init(false),

        // -- owned by the game thread ---------------------------------------------
        slots: []Slot,
        free_list: std.ArrayList(u32),
        sounds: core.HandlePool(Sounds, Stored) = .empty,

        // -- owned by the callback thread -----------------------------------------
        voices: []Voice,
        master_gain: f32,
        /// Frames mixed since the mixer started: the frame number of the next buffer's
        /// first sample. Published through `clock_frames`.
        mixed: u64 = 0,

        // -- shared, one writer each ----------------------------------------------
        to_audio: ring.Ring(Command),
        from_audio: ring.Ring(Event),
        /// `mixed`, stored with release after each buffer and read with acquire by
        /// `clock`. **Presentation, never simulation** (`music.md` §5.1).
        clock_frames: std.atomic.Value(u64) = .init(0),
        /// Scheduled starts whose frame had passed when they arrived. Written by the
        /// callback; a diagnostic, so monotonic.
        late_starts: std.atomic.Value(u32) = .init(0),

        pub fn init(
            gpa: Allocator,
            plat: *P,
            assets: *asset.Registry,
            options: Options,
        ) InitError!*Self {
            const voice_count = @max(1, options.voices);

            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);

            const slots = try gpa.alloc(Slot, voice_count);
            errdefer gpa.free(slots);
            @memset(slots, .{});

            const voices = try gpa.alloc(Voice, voice_count);
            errdefer gpa.free(voices);
            @memset(voices, .{});

            var free_list: std.ArrayList(u32) = .empty;
            errdefer free_list.deinit(gpa);
            try free_list.ensureTotalCapacityPrecise(gpa, voice_count);
            // Descending, so the first voice claimed is slot zero and a test reading the
            // mix order does not have to know the order the free list was built in (I9).
            var i: u32 = voice_count;
            while (i > 0) {
                i -= 1;
                free_list.appendAssumeCapacity(i);
            }

            var to_audio: ring.Ring(Command) = try .init(gpa, options.command_capacity);
            errdefer to_audio.deinit(gpa);

            // **Sized so an event can never be dropped.** A voice starts at most once and
            // retires at most once, and its slot cannot play again until `update` drains
            // the retirement — and with it, the ring being FIFO, the start before it. So
            // at most two events per voice are ever outstanding. A dropped retirement
            // would strand a slot forever, which is the one loss this design cannot
            // absorb — so it is made structurally impossible rather than counted.
            var from_audio: ring.Ring(Event) = try .init(gpa, 2 * voice_count);
            errdefer from_audio.deinit(gpa);

            self.* = .{
                .gpa = gpa,
                .plat = plat,
                .assets = assets,
                .info = .{
                    .sample_rate = options.sample_rate,
                    .channels = options.channels,
                    .buffer_frames = options.buffer_frames,
                },
                .slots = slots,
                .free_list = free_list,
                .voices = voices,
                .master_gain = options.master_gain,
                .to_audio = to_audio,
                .from_audio = from_audio,
            };

            self.device = try plat.openAudio(.{
                .sample_rate = options.sample_rate,
                .channels = options.channels,
                .buffer_frames = options.buffer_frames,
                .callback = callback,
                .ctx = self,
            });
            errdefer plat.closeAudio(self.device);

            self.info = plat.audioInfo(self.device) orelse return error.InvalidAudioDevice;
            if (self.info.channels == 0 or self.info.channels > 2) {
                // Warn, not err: the error return is the report, and this line only
                // carries the number the error set cannot.
                log.warn(
                    "audio: a {d}-channel device is not supported; mono and stereo are",
                    .{self.info.channels},
                );
                return error.UnsupportedChannelCount;
            }

            // Release, paired with the callback's acquire: everything above is visible
            // to the device thread before it is allowed to look at any of it.
            self.ready.store(true, .release);
            log.info("mixer: {d} voice(s) at {d} Hz, {d} channel(s)", .{
                voice_count,
                self.info.sample_rate,
                self.info.channels,
            });
            return self;
        }

        /// Stops the device and gives back everything the mixer borrowed from the registry.
        ///
        /// **The step between a running mixer and a torn-down one**, and it exists because
        /// the two things that have to happen at teardown want opposite orders. The
        /// registry unloads through a loader that borrows this object, so the loader has to
        /// go before `deinit`; but the mixer holds a reference per playing voice, so those
        /// have to come back *before* the loader goes or the registry rightly complains
        /// that something is still holding an asset it is unloading.
        ///
        /// So: `shutdown`, then unregister the loader, then `deinit`. Closing the device
        /// here is what makes the middle step safe — no callback can be reading a sound
        /// afterwards. Skipping it costs a warning per still-playing sound and nothing
        /// worse; calling it twice is a no-op.
        pub fn shutdown(self: *Self) void {
            self.plat.closeAudio(self.device);
            self.device = .none;
            self.ready.store(false, .monotonic);

            // The device thread is gone, so this is the one place a voice may be ended
            // without a round trip through the retirement ring.
            for (self.slots) |*slot| {
                if (!slot.playing) continue;
                slot.playing = false;
                const held = slot.held;
                slot.held = .none;
                slot.sound = .none;
                if (!held.isNone()) self.assets.release(held);
            }
        }

        pub fn deinit(self: *Self) void {
            const gpa = self.gpa;

            // **The device goes first.** Closing it is what stops the thread; freeing
            // anything below while a callback is in flight is the one ordering mistake
            // here that would be a crash rather than a wrong sound.
            self.plat.closeAudio(self.device);
            self.device = .none;
            self.ready.store(false, .monotonic);

            // **Deliberately not `shutdown`.** This has to be safe after the registry has
            // already gone — which is the order a caller reaches for when the mixer is one
            // field among many — and handing a reference back to a freed registry would be
            // the worst available way to end a program. A caller that skipped `shutdown`
            // has left reference counts high on a registry that is on its way out anyway.

            var it = self.sounds.iterator();
            while (it.next()) |entry| entry.value.sound.deinit(gpa);
            self.sounds.deinit(gpa);

            self.to_audio.deinit(gpa);
            self.from_audio.deinit(gpa);
            self.free_list.deinit(gpa);
            gpa.free(self.slots);
            gpa.free(self.voices);
            gpa.destroy(self);
        }

        // -- sounds ---------------------------------------------------------------

        /// Takes ownership of `sound` and returns the handle voices are started from.
        pub fn insertSound(self: *Self, sound: asset.Sound) Allocator.Error!SoundHandle {
            return self.sounds.add(self.gpa, .{ .sound = sound });
        }

        /// Gives a sound up. **The samples are not freed here** if a voice is still
        /// reading them: the sound is marked retired and a later `update` frees it, once
        /// every voice has pushed the retirement that says it stopped looking.
        ///
        /// This is the same shape `render2d` uses for GPU resources rather than trusting
        /// a deferred destroy underneath it, and here it is not a preference — the thread
        /// that is reading cannot be asked.
        pub fn releaseSound(self: *Self, sound: SoundHandle) void {
            const stored = self.sounds.get(sound) orelse return;
            stored.retired = true;
            self.collect(sound, stored);
        }

        /// Frees a retired sound once nothing is playing it. Game thread only.
        fn collect(self: *Self, handle: SoundHandle, stored: *Stored) void {
            if (!stored.retired or stored.refs != 0) return;
            stored.sound.deinit(self.gpa);
            _ = self.sounds.remove(handle);
        }

        pub fn soundCount(self: *const Self) u32 {
            return self.sounds.count();
        }

        /// The `foundry:sound` loader, to register with an `asset.Registry` at startup.
        ///
        /// **Registered from above, at runtime** (I6): `asset` is L2 and knows nothing
        /// about mixing, `audio` is L3 and does. The record type lives down there — a
        /// source path is not a mixer concept, and `fpack` reads one without linking a
        /// mixer — while the capability that turns it into playable samples is registered
        /// upward. The dependency points down, the capability points up, and a mod adding
        /// an asset kind the engine has never heard of does exactly the same thing.
        ///
        /// **The payload is a `SoundHandle`, not a pointer to the samples.** That
        /// indirection is what hazard two of `audio.md` §7 needs: a reload can retire the
        /// old sound while a voice is still reading it, and the voice's slot holds the
        /// handle it started with rather than whatever the record now names.
        ///
        /// `self` is borrowed for as long as the loader is registered, so the registry
        /// must be torn down before the mixer is.
        ///
        /// Split (M27): the decode and conversion on any thread, and a finish that hands the
        /// samples to the mixer. The decoder is chosen by the file's first bytes, `RIFF` or
        /// `OggS`, never by its extension (M30, `music.md` §4).
        pub fn soundLoader(self: *Self) asset.Loader {
            return .{
                .schema = asset.schemas.sound.id,
                .ctx = self,
                .load = soundLoad,
                .unload = soundUnload,
                .split = .{ .decode = soundDecode, .finish = soundFinish, .discard = soundDiscard, .after_finish = .adopt },
            };
        }

        fn soundLoad(
            ctx: ?*anyopaque,
            gpa: Allocator,
            record: asset.Record,
            bytes: []const u8,
        ) asset.LoadError!asset.Payload {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            return self.soundLoader().loadWhole(gpa, record, bytes);
        }

        fn soundDecode(
            _: ?*const anyopaque,
            gpa: Allocator,
            record: asset.Record,
            bytes: []const u8,
        ) asset.LoadError!asset.Decoded {
            const stream = asset.schemas.boolField(record, asset.schemas.sound, asset.schemas.stream_field) orelse false;
            const vorbis = bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS");
            if (stream and !vorbis) {
                // Streaming PCM that is already resident would buy nothing and cost a ring.
                log.warn("{f}: stream is for compressed sounds, and this is not one", .{record.id});
                return error.UnsupportedVersion;
            }
            const boxed = try gpa.create(asset.Sound);
            errdefer gpa.destroy(boxed);
            // `stream true` is decoded whole for now, as a resident sound; M30 Step 5 keeps it
            // compressed and decodes it as it plays (`music.md` §6).
            const decoded = if (vorbis) asset.vorbis.decode(gpa, bytes, .{}) else asset.wav.decode(gpa, bytes, .{});
            boxed.* = decoded catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // A valid file this decoder does not handle. The file is fine and the
                // answer for the author is different: transcode, do not debug.
                error.UnsupportedSound => error.UnsupportedVersion,
                error.SoundTooLarge => error.LoadFailed,
                error.InvalidSound => error.InvalidAsset,
            };
            return .fromPointer(boxed);
        }

        /// The samples become the mixer's; only the box they came in is freed here.
        fn soundFinish(
            ctx: ?*anyopaque,
            gpa: Allocator,
            _: asset.Record,
            decoded: asset.Decoded,
            _: *asset.Budget,
        ) asset.LoadError!asset.Payload {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const boxed: *asset.Sound = @ptrCast(@alignCast(decoded.pointer().?));
            const handle = try self.insertSound(boxed.*);
            gpa.destroy(boxed);
            return .fromHandle(handle);
        }

        fn soundDiscard(gpa: Allocator, decoded: asset.Decoded) void {
            const boxed: *asset.Sound = @ptrCast(@alignCast(decoded.pointer().?));
            boxed.deinit(gpa);
            gpa.destroy(boxed);
        }

        fn soundUnload(ctx: ?*anyopaque, gpa: Allocator, payload: asset.Payload) void {
            // Not freed here, and not with this allocator's knowledge: the samples belong
            // to the mixer and may be under a device thread's cursor right now.
            _ = gpa;
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.releaseSound(payload.asHandle(SoundHandle));
        }

        // -- the game-thread API --------------------------------------------------

        /// Starts a sound by content id.
        ///
        /// **This is where everything that can fail, fails** — which is precisely what
        /// leaves the mix callback with nothing to report (`audio.md` §5).
        pub fn play(self: *Self, id: core.ContentId, params: PlayParams) PlayError!VoiceHandle {
            // Refused here rather than at the payload cast: starting a voice on something
            // that turned out to be a texture is a mistake worth catching where the id
            // was written.
            const held = try self.assets.acquireOf(self.gpa, id, asset.schemas.sound.id);
            errdefer self.assets.release(held);

            const payload = self.assets.payloadOf(held) orelse return error.AssetNotFound;
            const handle = try self.playSound(payload.asHandle(SoundHandle), params);
            self.slots[handle.index].held = held;
            return handle;
        }

        /// Starts a sound the mixer already holds, bypassing content resolution.
        ///
        /// What the loader's product is played through, and the entry point for a caller
        /// that generated its own samples. **Not part of what the public ABI will expose**
        /// (`audio.md` §10): across that boundary a sound is a content id and nothing else.
        pub fn playSound(self: *Self, sound: SoundHandle, params: PlayParams) VoiceError!VoiceHandle {
            const stored = self.sounds.get(sound) orelse return error.UnknownSound;
            // A sound on its way out is not a sound to start something new on.
            if (stored.retired) return error.UnknownSound;
            if (stored.sound.frameCount() == 0) return error.UnknownSound;

            const index = self.free_list.pop() orelse return error.NoFreeVoice;
            const slot = &self.slots[index];
            slot.generation = nextGeneration(slot.generation);
            slot.playing = true;
            slot.sound = sound;
            slot.started_at = null;
            stored.refs += 1;

            const handle: VoiceHandle = .{ .index = index, .generation = slot.generation };
            const gains = voice.panGains(params.pan);
            const started = self.to_audio.push(.{ .play = .{
                .voice = handle,
                .samples = stored.sound.samples,
                .channels = stored.sound.channels,
                .frames = stored.sound.frameCount(),
                .step = voice.stepFor(stored.sound.sample_rate, self.info.sample_rate, params.pitch),
                .gain = params.gain,
                .left = gains.left,
                .right = gains.right,
                .looping = params.looping,
                .start_at = params.start_at,
                .envelope = params.envelope,
            } });

            if (!started) {
                // Undo the claim. Nothing was ever started, so no retirement is coming.
                stored.refs -= 1;
                slot.playing = false;
                slot.sound = .none;
                self.free_list.appendAssumeCapacity(index);
                return error.CommandQueueFull;
            }
            return handle;
        }

        pub fn stop(self: *Self, handle: VoiceHandle) void {
            _ = self.stopChecked(handle);
        }

        /// Queues a stop and reports whether the command ring accepted it. The legacy void
        /// wrapper remains for engine/game callers whose presentation controls may be dropped
        /// when the ring is full; the public ABI uses this checked form so a mod is never told
        /// success for a command that vanished.
        pub fn stopChecked(self: *Self, handle: VoiceHandle) bool {
            return self.to_audio.push(.{ .stop = .{ .voice = handle } });
        }

        pub fn stopAll(self: *Self) void {
            _ = self.stopAllChecked();
        }

        pub fn stopAllChecked(self: *Self) bool {
            return self.to_audio.push(.stop_all);
        }

        pub fn setGain(self: *Self, handle: VoiceHandle, gain: f32) void {
            _ = self.setGainChecked(handle, gain);
        }

        pub fn setGainChecked(self: *Self, handle: VoiceHandle, gain: f32) bool {
            return self.to_audio.push(.{ .set_gain = .{ .voice = handle, .gain = gain } });
        }

        /// The trigonometry runs here, once, rather than per sample in the callback.
        pub fn setPan(self: *Self, handle: VoiceHandle, pan: f32) void {
            _ = self.setPanChecked(handle, pan);
        }

        pub fn setPanChecked(self: *Self, handle: VoiceHandle, pan: f32) bool {
            const gains = voice.panGains(pan);
            return self.to_audio.push(.{
                .set_pan = .{ .voice = handle, .left = gains.left, .right = gains.right },
            });
        }

        /// The ratio is computed here for the same reason the pan gains are: the callback
        /// does arithmetic, not policy, and the device's rate is known on this side.
        pub fn setPitch(self: *Self, handle: VoiceHandle, pitch: f32) void {
            _ = self.setPitchChecked(handle, pitch);
        }

        pub fn setPitchChecked(self: *Self, handle: VoiceHandle, pitch: f32) bool {
            const slot = self.liveSlot(handle) orelse return false;
            const stored = self.sounds.getConst(slot.sound) orelse return false;
            return self.to_audio.push(.{ .set_pitch = .{
                .voice = handle,
                .step = voice.stepFor(stored.sound.sample_rate, self.info.sample_rate, pitch),
            } });
        }

        /// Ramps the voice's envelope from wherever it is (`music.md` §5.3).
        pub fn fade(self: *Self, handle: VoiceHandle, params: Fade) void {
            _ = self.fadeChecked(handle, params);
        }

        pub fn fadeChecked(self: *Self, handle: VoiceHandle, params: Fade) bool {
            return self.to_audio.push(.{ .fade = .{ .voice = handle, .fade = params } });
        }

        /// Ramps the voice's level, the gain `setGain` sets at once, linearly over `frames`
        /// from the next callback.
        pub fn fadeGain(self: *Self, handle: VoiceHandle, gain: f32, frames: u32) void {
            _ = self.fadeGainChecked(handle, gain, frames);
        }

        pub fn fadeGainChecked(self: *Self, handle: VoiceHandle, gain: f32, frames: u32) bool {
            return self.to_audio.push(.{ .fade_gain = .{ .voice = handle, .gain = gain, .frames = frames } });
        }

        /// Frames the device has mixed since the mixer started, as of the last callback:
        /// the frame the next buffer begins on.
        ///
        /// **Presentation, never simulation.** It advances with a thread Foundry does not
        /// control, so no tick may read it (I9, `music.md` §5.1), and `scene` cannot see
        /// this module to try.
        pub fn clock(self: *const Self) u64 {
            return self.clock_frames.load(.acquire);
        }

        /// The mixer frame this voice's first sample landed on, or null if it has not
        /// started as far as `update` has heard, or is no longer playing.
        pub fn startedAt(self: *const Self, handle: VoiceHandle) ?u64 {
            const slot = self.liveSlotConst(handle) orelse return null;
            return slot.started_at;
        }

        /// Scheduled starts whose frame had already passed when the command reached the
        /// callback. Each of them started at once instead.
        pub fn lateStarts(self: *const Self) u32 {
            return self.late_starts.load(.monotonic);
        }

        pub fn setMasterGain(self: *Self, gain: f32) void {
            _ = self.setMasterGainChecked(gain);
        }

        pub fn setMasterGainChecked(self: *Self, gain: f32) bool {
            return self.to_audio.push(.{ .set_master_gain = .{ .gain = gain } });
        }

        /// Whether the game still believes this voice is playing.
        ///
        /// **For presentation, and the doc comment is the point** (`audio.md` §8). It
        /// lags: a sound that ended reads as playing until `update` drains its
        /// retirement. Nothing in a simulation may branch on it — and structurally
        /// nothing can, because `scene` cannot see this module at all.
        pub fn isPlaying(self: *const Self, handle: VoiceHandle) bool {
            return self.liveSlotConst(handle) != null;
        }

        /// Called once per frame, on the game thread.
        ///
        /// **If it is not called**: voices never return to the free list, retired sounds
        /// are never freed, and `play` starts failing with `error.NoFreeVoice` after
        /// `voices` sounds. That is a loud, immediate failure rather than a slow leak,
        /// which is the right way round.
        pub fn update(self: *Self) void {
            while (self.from_audio.pop()) |event| {
                const slot = &self.slots[event.slot];
                if (event.kind == .started) {
                    if (slot.playing and slot.generation == event.generation) slot.started_at = event.frame;
                    continue;
                }
                const retired = event;
                // A generation that has moved on means this slot was already reclaimed;
                // the retirement is for a voice two lives ago and is simply old news.
                if (!slot.playing or slot.generation != retired.generation) continue;

                slot.playing = false;
                const sound = slot.sound;
                const held = slot.held;
                slot.sound = .none;
                slot.held = .none;
                slot.started_at = null;
                self.free_list.appendAssumeCapacity(retired.slot);

                if (self.sounds.get(sound)) |stored| {
                    stored.refs -= 1;
                    // Only now, with the release/acquire pair behind us, is it safe to
                    // free samples the device thread was reading.
                    self.collect(sound, stored);
                }
                // And only now may the game's last reference to the asset go, which is
                // hazard one: `play` acquired it and this is the other end of that.
                if (!held.isNone()) self.assets.release(held);
            }
        }

        /// Commands the ring refused. Non-zero means the ring is too small or the game is
        /// issuing commands faster than a callback period; both are the game's to fix,
        /// which is why `Options` exposes the size.
        pub fn commandsDropped(self: *const Self) u32 {
            return self.to_audio.dropCount();
        }

        pub fn activeVoices(self: *const Self) u32 {
            var count: u32 = 0;
            for (self.slots) |slot| {
                if (slot.playing) count += 1;
            }
            return count;
        }

        fn liveSlot(self: *Self, handle: VoiceHandle) ?*Slot {
            if (handle.index >= self.slots.len) return null;
            const slot = &self.slots[handle.index];
            if (!slot.playing or slot.generation != handle.generation) return null;
            return slot;
        }

        fn liveSlotConst(self: *const Self, handle: VoiceHandle) ?*const Slot {
            if (handle.index >= self.slots.len) return null;
            const slot = &self.slots[handle.index];
            if (!slot.playing or slot.generation != handle.generation) return null;
            return slot;
        }

        // -- the callback thread --------------------------------------------------

        fn callback(ctx: ?*anyopaque, out: []f32) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            // Acquire, paired with `init`'s release. Before this reads true, nothing in
            // `self` is guaranteed to be built.
            if (!self.ready.load(.acquire)) {
                @memset(out, 0);
                return;
            }
            self.mix(out);
        }

        /// One buffer. **Nothing in here can fail**, and that is a design property rather
        /// than optimism: there is no allocation to fail, no file to be missing, and no
        /// handle to be invalid that is not simply ignored (`audio.md` §5).
        fn mix(self: *Self, out: []f32) void {
            // 1. Drain the command ring. Bounded work: one pass over what is queued.
            while (self.to_audio.pop()) |command| self.apply(command);

            // 2. Silence is zeroes. The buffer arrives holding whatever the driver last
            //    put there, so this is not an optimisation to skip when nothing plays.
            @memset(out, 0);

            // 3. Mix in slot index order — stable, documented, and the reason two runs of
            //    the stepped device produce identical samples (I9, `audio.md` §8).
            const channels = self.info.channels;
            const frames: u64 = out.len / channels;
            for (self.voices, 0..) |*v, index| {
                if (!v.active) continue;
                const generation = v.generation;
                // A voice waits for the buffer that holds its start frame, and its first
                // sample lands on that frame rather than at the buffer's start.
                var offset: usize = 0;
                if (v.pending) {
                    if (v.start_at >= self.mixed + frames) continue;
                    offset = @intCast(v.start_at - self.mixed);
                    v.pending = false;
                    self.report(.{ .kind = .started, .slot = @intCast(index), .generation = generation, .frame = v.start_at });
                }
                if (!v.mix(out[offset * channels ..], channels, self.mixed + offset)) {
                    self.retire(@intCast(index), generation);
                }
            }

            // 4. Master gain, then clamp. **The clamp is not a limiter and does not
            //    pretend to be**: it is here because an `f32` outside [-1, 1] handed to a
            //    driver that converts to `s16` without clamping *wraps*, and wrapping is
            //    the single worst sound a program can make. Twenty voices at full gain
            //    will clip; a real limiter is out of scope (`audio.md` §12).
            for (out) |*sample| {
                sample.* = std.math.clamp(sample.* * self.master_gain, -1.0, 1.0);
            }

            // 5. The clock moves by exactly this buffer, published last so a game that
            //    reads it sees every event this buffer pushed.
            self.mixed += frames;
            self.clock_frames.store(self.mixed, .release);
        }

        /// A voice stops reading its samples here, and the push is what tells the game
        /// thread it may free them.
        fn retire(self: *Self, index: u32, generation: u32) void {
            self.report(.{ .kind = .retired, .slot = index, .generation = generation });
        }

        fn report(self: *Self, event: Event) void {
            // Sized so this cannot fail (see `init`). Ignoring the result would hide a
            // stranded slot, so the impossible case says so instead of vanishing.
            if (!self.from_audio.push(event)) {
                core.assert.unreachableCode(
                    "audio: the events ring was full, which its size forbids",
                    .{},
                );
            }
        }

        fn apply(self: *Self, command: Command) void {
            switch (command) {
                .play => |p| {
                    // A `play` addresses its slot directly: the game thread claimed it,
                    // and no other command for that generation can have arrived first.
                    // Commands drain before a buffer is mixed, so `mixed` is the earliest
                    // frame this voice can still land on.
                    var start = self.mixed;
                    if (p.start_at) |at| {
                        if (at >= self.mixed) start = at else _ = self.late_starts.fetchAdd(1, .monotonic);
                    }
                    self.voices[p.voice.index] = .{
                        .active = true,
                        .generation = p.voice.generation,
                        .samples = p.samples,
                        .channels = p.channels,
                        .frames = p.frames,
                        .cursor = 0,
                        .step = p.step,
                        .level = .hold(p.gain),
                        .envelope = .hold(p.envelope),
                        .left = p.left,
                        .right = p.right,
                        .looping = p.looping,
                        .pending = true,
                        .start_at = start,
                    };
                },
                .stop => |s| {
                    const v = self.liveVoice(s.voice) orelse return;
                    v.active = false;
                    self.retire(s.voice.index, s.voice.generation);
                },
                .stop_all => {
                    for (self.voices, 0..) |*v, index| {
                        if (!v.active) continue;
                        v.active = false;
                        self.retire(@intCast(index), v.generation);
                    }
                },
                .set_gain => |s| {
                    // At once, and cancelling any `fade_gain` under way: its meaning
                    // before M30, kept for every existing caller and the public table.
                    const v = self.liveVoice(s.voice) orelse return;
                    v.level = .hold(s.gain);
                },
                .fade => |s| {
                    const v = self.liveVoice(s.voice) orelse return;
                    const f = s.fade;
                    v.envelope.start(.{
                        .begin = @max(f.at orelse self.mixed, self.mixed),
                        .frames = f.frames,
                        .to = f.to,
                        .curve = f.curve,
                        .stop = f.stop,
                    });
                },
                .fade_gain => |s| {
                    const v = self.liveVoice(s.voice) orelse return;
                    v.level.start(.{ .begin = self.mixed, .frames = s.frames, .to = s.gain, .curve = .linear, .stop = false });
                },
                .set_pan => |s| {
                    const v = self.liveVoice(s.voice) orelse return;
                    v.left = s.left;
                    v.right = s.right;
                },
                .set_pitch => |s| {
                    const v = self.liveVoice(s.voice) orelse return;
                    v.step = s.step;
                },
                .set_master_gain => |s| self.master_gain = s.gain,
            }
        }

        /// The generational refusal, on the callback side.
        ///
        /// **This is belt and braces.** What actually makes a stale command safe is that
        /// the ring is FIFO with a single producer, so commands arrive in the order the
        /// game thread issued them — and the game thread cannot issue a `play` for
        /// generation n+1 until it has drained the retirement for generation n. A `stop`
        /// for a dead voice can therefore only ever arrive *before* the `play` that
        /// recycles its slot, never after. Saying that out loud is the difference between
        /// a design and a coincidence.
        fn liveVoice(self: *Self, handle: VoiceHandle) ?*Voice {
            if (handle.index >= self.voices.len) return null;
            const v = &self.voices[handle.index];
            if (!v.active or v.generation != handle.generation) return null;
            return v;
        }
    };
}

/// Generation zero is `Handle.none`, so it is skipped on wrap rather than handed out.
fn nextGeneration(current: u32) u32 {
    return if (current == std.math.maxInt(u32)) 1 else current + 1;
}

pub const Mixer = MixerOf(platform.Platform);

// -- tests ---------------------------------------------------------------------------
//
// Driven by the null backend's stepped device: the callback runs synchronously, on this
// thread, for exactly the frames asked for. That makes the arithmetic, the command
// protocol and the voice lifecycle testable and reproducible. It does **not** exercise
// the rings under real concurrency — producer and consumer are one thread here — and
// `ring.zig` says what does.

const testing = std.testing;
const null_backend = platform.null_backend;

const TestMixer = MixerOf(null_backend.Platform);

const Fixture = struct {
    gpa: Allocator,
    plat: *null_backend.Platform,
    os: *platform.os.Os,
    store: asset.Store,
    assets: asset.Registry,
    mixer: *TestMixer,

    /// The registry is real but its store is empty, which is exactly right for these:
    /// everything here is below `play(ContentId)`, and resolving a content id is the
    /// integration suite's job because it needs a package on a disk.
    fn init(gpa: Allocator, options: Options) !*Fixture {
        const plat = try null_backend.Platform.init(gpa, .{});
        errdefer plat.deinit();

        const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-audio", .env = &.{} });
        errdefer os.deinit();

        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .plat = plat,
            .os = os,
            .store = .init(gpa, .default),
            .assets = undefined,
            .mixer = undefined,
        };
        self.assets = .init(gpa, os, &self.store, .{});
        self.mixer = try TestMixer.init(gpa, plat, &self.assets, options);
        return self;
    }

    fn deinit(self: *Fixture) void {
        // The order the module documents: the registry unloads through the mixer's
        // loader, so it goes first.
        self.assets.deinit(self.gpa);
        self.mixer.deinit();
        self.store.deinit(self.gpa);
        self.os.deinit();
        self.plat.deinit();
        self.gpa.destroy(self);
    }

    /// One device callback of exactly `frames`, returning what it produced.
    fn step(self: *Fixture, frames: u32) ![]const f32 {
        return self.plat.stepAudio(self.mixer.device, frames);
    }

    fn add(self: *Fixture, samples: []const f32, channels: u8, rate: u32) !SoundHandle {
        const decoded = try asset.Sound.alloc(self.gpa, samples.len / channels, channels, rate);
        @memcpy(decoded.samples, samples);
        return self.mixer.insertSound(decoded);
    }
};

fn expectAllZero(samples: []const f32) !void {
    for (samples) |sample| try testing.expectEqual(@as(f32, 0.0), sample);
}

test "with nothing playing the device gets silence, every time" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 2, .buffer_frames = 4 });
    defer f.deinit();

    // The buffer arrives holding whatever the driver last put in it, so this is a real
    // assertion rather than a tautology.
    try expectAllZero(try f.step(4));
    try expectAllZero(try f.step(4));
    try testing.expectEqual(@as(u32, 0), f.mixer.activeVoices());
}

test "a voice at the device's own rate reproduces its samples exactly" {
    // A mono device, so nothing is scaled by a pan gain and the comparison can be exact.
    // An approximate check here would pass for a resampler half a frame out of step.
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4 });
    defer f.deinit();

    const source = [_]f32{ 0.25, -0.5, 0.75, -1.0 };
    const sound = try f.add(&source, 1, 48_000);
    _ = try f.mixer.playSound(sound, .{});

    try testing.expectEqualSlices(f32, &source, try f.step(4));
}

test "gain scales, master gain scales everything, and the sum is clamped" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 1, .voices = 4 });
    defer f.deinit();

    const source = [_]f32{0.8};
    const sound = try f.add(&source, 1, 48_000);

    _ = try f.mixer.playSound(sound, .{ .gain = 0.5, .looping = true });
    try testing.expectEqualSlices(f32, &[_]f32{0.4}, try f.step(1));

    // Two more voices at full gain: 0.4 + 0.8 + 0.8 is over one, and the clamp catches
    // it. Not a limiter — an `f32` above 1 handed to a driver that converts to `s16`
    // without clamping *wraps*, which is the worst sound a program can make.
    _ = try f.mixer.playSound(sound, .{ .looping = true });
    _ = try f.mixer.playSound(sound, .{ .looping = true });
    try testing.expectEqualSlices(f32, &[_]f32{1.0}, try f.step(1));

    f.mixer.setMasterGain(0.0);
    try expectAllZero(try f.step(1));
}

test "pan splits a mono source across a stereo device with constant power" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 2, .buffer_frames = 1 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{1.0}, 1, 48_000);
    const v = try f.mixer.playSound(sound, .{ .pan = -1.0, .looping = true });

    var out = try f.step(1);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[1], 1e-6);

    // And a pan change reaches the voice by command, not by reaching into it.
    f.mixer.setPan(v, 1.0);
    out = try f.step(1);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[1], 1e-6);
}

test "a sound at half the device's rate is resampled by the voice" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4, .sample_rate = 48_000 });
    defer f.deinit();

    // 24 kHz into 48 kHz: one source frame per two output frames, interpolated between.
    const sound = try f.add(&[_]f32{ 0.0, 1.0 }, 1, 24_000);
    _ = try f.mixer.playSound(sound, .{});

    const out = try f.step(4);
    try testing.expectEqual(@as(f32, 0.0), out[0]);
    try testing.expectEqual(@as(f32, 0.5), out[1]);
    try testing.expectEqual(@as(f32, 1.0), out[2]);

    // Pitch is the same operation, so it reaches the same machinery.
    const doubled = try f.add(&[_]f32{ 0.0, 1.0 }, 1, 24_000);
    const v = try f.mixer.playSound(doubled, .{});
    f.mixer.setPitch(v, 2.0);
    const fast = try f.step(2);
    try testing.expectEqual(@as(f32, 0.0), fast[0]);
    try testing.expectEqual(@as(f32, 1.0), fast[1]);
}

test "a one-shot retires, and update is what gives its slot back" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4, .voices = 1 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{ 1.0, 1.0 }, 1, 48_000);
    const v = try f.mixer.playSound(sound, .{});
    try testing.expect(f.mixer.isPlaying(v));

    _ = try f.step(4);
    // The voice ended on the device thread, but the game thread has not heard yet —
    // which is exactly why `isPlaying` is documented as presentation-only.
    try testing.expect(f.mixer.isPlaying(v));
    try testing.expectError(error.NoFreeVoice, f.mixer.playSound(sound, .{}));

    f.mixer.update();
    try testing.expect(!f.mixer.isPlaying(v));
    try testing.expectEqual(@as(u32, 0), f.mixer.activeVoices());
    _ = try f.mixer.playSound(sound, .{});
}

test "a stale handle's stop leaves the voice that took its slot alone" {
    // The oldest bug in game audio: a footstep's handle, kept for 400 ms and stopped
    // after the door that reused its slot started playing. With a bare index the door
    // goes silent for no reason anyone can reproduce.
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 2, .voices = 1 });
    defer f.deinit();

    const footstep = try f.add(&[_]f32{ 0.5, 0.5 }, 1, 48_000);
    const door = try f.add(&[_]f32{1.0}, 1, 48_000);

    const stale = try f.mixer.playSound(footstep, .{});
    _ = try f.step(2);
    f.mixer.update();

    const fresh = try f.mixer.playSound(door, .{ .looping = true });
    // The same slot, a different generation. Without the generation these would be equal.
    try testing.expectEqual(stale.index, fresh.index);
    try testing.expect(!stale.eql(fresh));

    f.mixer.stop(stale);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 1.0 }, try f.step(2));
    try testing.expect(f.mixer.isPlaying(fresh));

    // And the real handle does stop it.
    f.mixer.stop(fresh);
    try expectAllZero(try f.step(2));
    f.mixer.update();
    try testing.expectEqual(@as(u32, 0), f.mixer.activeVoices());
}

test "a loop keeps playing past its own length, in phase" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 3 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{ 0.1, 0.2, 0.3 }, 1, 48_000);
    _ = try f.mixer.playSound(sound, .{ .looping = true });

    // Three buffers of three frames over a three-frame sound: the seam falls on a buffer
    // boundary each time, which is where an off-by-one in the wrap would show.
    for (0..3) |_| {
        try testing.expectEqualSlices(f32, &[_]f32{ 0.1, 0.2, 0.3 }, try f.step(3));
    }
    try testing.expectEqual(@as(u32, 1), f.mixer.activeVoices());
}

test "stopAll silences everything and returns every slot" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 1, .voices = 8 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{0.1}, 1, 48_000);
    for (0..8) |_| _ = try f.mixer.playSound(sound, .{ .looping = true });
    try testing.expectEqual(@as(u32, 8), f.mixer.activeVoices());

    const before = try f.step(1);
    try testing.expectApproxEqAbs(@as(f32, 0.8), before[0], 1e-6);

    f.mixer.stopAll();
    try expectAllZero(try f.step(1));
    f.mixer.update();
    try testing.expectEqual(@as(u32, 0), f.mixer.activeVoices());
}

test "the same commands produce the same samples, run after run" {
    // I9's promise, in the only form audio can honour it (`audio.md` §8): not that a
    // running game sounds the same, but that the mixer is a function of its commands and
    // its buffer sizes. Slot index order is what makes the sum's rounding identical too.
    const gpa = testing.allocator;
    var first: [16]f32 = undefined;

    for (0..2) |run| {
        const f = try Fixture.init(gpa, .{ .channels = 2, .buffer_frames = 8, .voices = 4 });
        defer f.deinit();

        const a = try f.add(&[_]f32{ 0.1, 0.2, 0.3 }, 1, 44_100);
        const b = try f.add(&[_]f32{ -0.4, 0.5 }, 1, 32_000);
        _ = try f.mixer.playSound(a, .{ .pan = -0.3, .looping = true });
        _ = try f.mixer.playSound(b, .{ .gain = 0.7, .pitch = 1.3, .looping = true });

        _ = try f.step(8);
        const out = try f.step(8);
        if (run == 0) @memcpy(&first, out) else try testing.expectEqualSlices(f32, &first, out);
    }
}

test "a full command ring refuses a play instead of stranding its slot" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 1, .voices = 8, .command_capacity = 2 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{0.1}, 1, 48_000);
    _ = try f.mixer.playSound(sound, .{ .looping = true });
    _ = try f.mixer.playSound(sound, .{ .looping = true });

    // The third command has nowhere to go. A dropped `play` would leave a slot no
    // retirement is ever coming for, so the claim is undone and the caller told —
    // unlike a dropped `set_gain`, which is simply counted.
    try testing.expectError(error.CommandQueueFull, f.mixer.playSound(sound, .{}));
    try testing.expectEqual(@as(u32, 2), f.mixer.activeVoices());
    try testing.expectEqual(@as(u32, 1), f.mixer.commandsDropped());

    // And the slot really did come back: once the ring drains, a play succeeds.
    _ = try f.step(1);
    _ = try f.mixer.playSound(sound, .{});
    try testing.expectEqual(@as(u32, 3), f.mixer.activeVoices());
}

test "checked control commands report a full ring" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 1, .voices = 1, .command_capacity = 1 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{0.1}, 1, 48_000);
    const playing = try f.mixer.playSound(sound, .{ .looping = true });

    // The play command occupies the only slot. Every checked form observes the drop, while
    // the legacy void wrappers remain available to callers that intentionally tolerate one.
    // Ring capacity has a floor of two, so the first checked control occupies its second slot.
    try testing.expect(f.mixer.setGainChecked(playing, 0.5));
    try testing.expect(!f.mixer.stopChecked(playing));
    try testing.expect(!f.mixer.setPanChecked(playing, 0.5));
    try testing.expect(!f.mixer.setPitchChecked(playing, 1.5));
    try testing.expect(!f.mixer.setMasterGainChecked(0.5));
    try testing.expect(!f.mixer.stopAllChecked());
    try testing.expectEqual(@as(u32, 5), f.mixer.commandsDropped());
}

test "a sound released while it is playing is freed only once nothing is reading it" {
    // Hot reload's hazard, in miniature. `testing.allocator` is the actual assertion:
    // freeing early would be a use-after-free on the device thread, and never freeing
    // would be a leak, and it fails on both.
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 2, .voices = 2 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{ 0.5, 0.5 }, 1, 48_000);
    const v = try f.mixer.playSound(sound, .{ .looping = true });

    f.mixer.releaseSound(sound);
    try testing.expectEqual(@as(u32, 1), f.mixer.soundCount());
    // And it cannot be started again while it is on its way out.
    try testing.expectError(error.UnknownSound, f.mixer.playSound(sound, .{}));

    // Still audible, because the samples are still there.
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5 }, try f.step(2));

    f.mixer.stop(v);
    _ = try f.step(2);
    f.mixer.update();
    try testing.expectEqual(@as(u32, 0), f.mixer.soundCount());
}

test "a device with more than two channels is refused by name" {
    const gpa = testing.allocator;
    const plat = try null_backend.Platform.init(gpa, .{});
    defer plat.deinit();
    const os = try platform.os.Os.init(gpa, .{ .app_name = "foundry-audio", .env = &.{} });
    defer os.deinit();
    var store: asset.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    var assets: asset.Registry = .init(gpa, os, &store, .{});
    defer assets.deinit(gpa);

    // Silently mixing into the first two would ship a 5.1 game that plays out of the
    // front-left pair and nobody would know why (`audio.md` §5).
    try testing.expectError(
        error.UnsupportedChannelCount,
        TestMixer.init(gpa, plat, &assets, .{ .channels = 6 }),
    );
}

test "an unknown sound is refused rather than played as silence" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 1 });
    defer f.deinit();

    try testing.expectError(error.UnknownSound, f.mixer.playSound(.none, .{}));
    try testing.expectError(
        error.UnknownSound,
        f.mixer.playSound(.{ .index = 7, .generation = 3 }, .{}),
    );
    try testing.expectEqual(@as(u32, 0), f.mixer.activeVoices());
}

test "commands for a voice that never existed change nothing" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 1 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{1.0}, 1, 48_000);
    _ = try f.mixer.playSound(sound, .{ .looping = true });

    const nowhere: VoiceHandle = .{ .index = 999, .generation = 4 };
    f.mixer.stop(nowhere);
    f.mixer.setGain(nowhere, 0.0);
    f.mixer.setPan(nowhere, 1.0);
    f.mixer.setPitch(nowhere, 4.0);

    // Untrusted input at the ABI one day, and a handle out of range must be a no-op
    // rather than an index into somebody else's voice.
    try testing.expectEqualSlices(f32, &[_]f32{1.0}, try f.step(1));
}

// -- M30 Step 4: the clock, scheduled starts and ramps (`music.md` §5) -----------------

test "the clock advances by exactly each buffer, whatever its size" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 2, .buffer_frames = 4 });
    defer f.deinit();

    try testing.expectEqual(@as(u64, 0), f.mixer.clock());
    _ = try f.step(4);
    try testing.expectEqual(@as(u64, 4), f.mixer.clock());
    _ = try f.step(7);
    _ = try f.step(1);
    try testing.expectEqual(@as(u64, 12), f.mixer.clock());
}

test "a scheduled start lands on its frame mid-buffer, sample-exact, and reports it" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4 });
    defer f.deinit();

    const source = [_]f32{ 0.25, -0.5, 0.75 };
    const sound = try f.add(&source, 1, 48_000);
    // Frame 6 is in the second buffer, two frames in. The first buffer is silent, and the
    // voice is held across it rather than started early.
    const v = try f.mixer.playSound(sound, .{ .start_at = 6 });
    try expectAllZero(try f.step(4));
    f.mixer.update();
    try testing.expectEqual(@as(?u64, null), f.mixer.startedAt(v));

    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0, 0.25, -0.5 }, try f.step(4));
    try testing.expectEqualSlices(f32, &[_]f32{ 0.75, 0, 0, 0 }, try f.step(4));
    f.mixer.update();
    try testing.expectEqual(@as(u32, 0), f.mixer.lateStarts());

    // It ended in the third buffer, so its slot is back and the answer has gone with it.
    try testing.expectEqual(@as(?u64, null), f.mixer.startedAt(v));
    const looped = try f.mixer.playSound(sound, .{ .start_at = 13, .looping = true });
    _ = try f.step(4);
    f.mixer.update();
    try testing.expectEqual(@as(?u64, 13), f.mixer.startedAt(looped));
}

test "a start already past starts at once and counts as late" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 2 });
    defer f.deinit();

    _ = try f.step(2);
    _ = try f.step(2);
    const sound = try f.add(&[_]f32{ 1, 1 }, 1, 48_000);
    const v = try f.mixer.playSound(sound, .{ .start_at = 1, .looping = true });
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 1 }, try f.step(2));
    f.mixer.update();
    try testing.expectEqual(@as(u32, 1), f.mixer.lateStarts());
    try testing.expectEqual(@as(?u64, 4), f.mixer.startedAt(v));

    // On time is not late: a start on the next buffer's first frame lands there.
    const w = try f.mixer.playSound(sound, .{ .start_at = 6, .looping = true });
    _ = try f.step(2);
    f.mixer.update();
    try testing.expectEqual(@as(u32, 1), f.mixer.lateStarts());
    try testing.expectEqual(@as(?u64, 6), f.mixer.startedAt(w));
}

test "a crossfade built by hand from two voices keeps its summed power at the middle" {
    // Each voice is panned hard to one side, so the left channel is the first voice's gain
    // and the right channel the second's, and power is left² + right².
    const f = try Fixture.init(testing.allocator, .{ .channels = 2, .buffer_frames = 8 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{1.0}, 1, 48_000);
    inline for (.{ Curve.equal_power, Curve.linear }) |curve| {
        const start = f.mixer.clock() + 8;
        const out_voice = try f.mixer.playSound(sound, .{ .pan = -1, .looping = true, .start_at = start });
        const in_voice = try f.mixer.playSound(sound, .{ .pan = 1, .looping = true, .start_at = start, .envelope = 0 });
        f.mixer.fade(out_voice, .{ .at = start, .frames = 8, .to = 0, .curve = curve, .stop = true });
        f.mixer.fade(in_voice, .{ .at = start, .frames = 8, .to = 1, .curve = curve });

        try expectAllZero(try f.step(8));
        const out = try f.step(8);
        const middle = 4 * 2;
        const power = out[middle] * out[middle] + out[middle + 1] * out[middle + 1];
        switch (curve) {
            .equal_power => {
                try testing.expectApproxEqAbs(@as(f32, 1.0), power, 1e-6);
                // And at every frame of it, not only the middle.
                for (0..8) |i| {
                    const l = out[i * 2];
                    const r = out[i * 2 + 1];
                    try testing.expectApproxEqAbs(@as(f32, 1.0), l * l + r * r, 1e-6);
                }
            },
            // The reason the curve exists: linear dips by half, 3 dB, at the middle.
            .linear => try testing.expectApproxEqAbs(@as(f32, 0.5), power, 1e-6),
        }
        // The stopping fade retires its voice on its end frame, the next buffer's first;
        // the other plays on at full.
        const after = try f.step(8);
        try testing.expectApproxEqAbs(@as(f32, 0.0), after[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 1.0), after[1], 1e-6);
        f.mixer.update();
        try testing.expect(!f.mixer.isPlaying(out_voice));
        try testing.expect(f.mixer.isPlaying(in_voice));
        f.mixer.stop(in_voice);
        _ = try f.step(8);
        f.mixer.update();
    }
    try testing.expectEqual(@as(u32, 0), f.mixer.lateStarts());
}

test "a fade with no frame, or a frame past, begins at the next callback and runs its length" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{1.0}, 1, 48_000);
    const v = try f.mixer.playSound(sound, .{ .looping = true });
    _ = try f.step(4);
    f.mixer.fade(v, .{ .frames = 4, .to = 0 });
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 0.75, 0.5, 0.25 }, try f.step(4));
    f.mixer.fade(v, .{ .at = 2, .frames = 4, .to = 1 });
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0.25, 0.5, 0.75 }, try f.step(4));

    // A stop with no length ends the voice at once.
    f.mixer.fade(v, .{ .frames = 0, .to = 0, .stop = true });
    try expectAllZero(try f.step(4));
    f.mixer.update();
    try testing.expect(!f.mixer.isPlaying(v));
}

test "fadeGain ramps the level, setGain still sets it at once, and the two compose with a fade" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{1.0}, 1, 48_000);
    const v = try f.mixer.playSound(sound, .{ .looping = true, .gain = 0.5 });
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.5, 0.5, 0.5 }, try f.step(4));

    f.mixer.fadeGain(v, 1.0, 4);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.625, 0.75, 0.875 }, try f.step(4));
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 1, 1, 1 }, try f.step(4));

    // A duck on the level while the envelope fades: the product, frame by frame.
    f.mixer.fadeGain(v, 0.5, 4);
    f.mixer.fade(v, .{ .frames = 4, .to = 0 });
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 0.65625, 0.375, 0.15625 }, try f.step(4));

    // `setGain` lands at the next callback with no ramp, and cancels one under way.
    f.mixer.fade(v, .{ .frames = 0, .to = 1 });
    f.mixer.fadeGain(v, 0.0, 400);
    f.mixer.setGain(v, 0.25);
    try testing.expectEqualSlices(f32, &[_]f32{ 0.25, 0.25, 0.25, 0.25 }, try f.step(4));
}

test "every voice starting and retiring in one buffer fits the events ring" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4, .voices = 4 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{0.1}, 1, 48_000);
    var handles: [4]VoiceHandle = undefined;
    for (&handles) |*h| h.* = try f.mixer.playSound(sound, .{});
    // Four starts and four retirements, eight events, with no `update` in between.
    _ = try f.step(4);
    try testing.expectEqual(@as(usize, 8), f.mixer.from_audio.len());
    f.mixer.update();
    try testing.expectEqual(@as(u32, 0), f.mixer.activeVoices());
    for (handles) |h| try testing.expectEqual(@as(?u64, null), f.mixer.startedAt(h));
}

test "a start reported for a slot's earlier voice does not stamp the voice now in it" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4, .voices = 1 });
    defer f.deinit();

    const sound = try f.add(&[_]f32{0.1}, 1, 48_000);
    const old = try f.mixer.playSound(sound, .{});
    _ = try f.step(4);
    f.mixer.update();
    const now = try f.mixer.playSound(sound, .{ .looping = true });
    try testing.expectEqual(old.index, now.index);

    // The FIFO never delivers this, but a slot is told apart by generation, not trust.
    try testing.expect(f.mixer.from_audio.push(.{ .kind = .started, .slot = old.index, .generation = old.generation, .frame = 999 }));
    f.mixer.update();
    try testing.expectEqual(@as(?u64, null), f.mixer.startedAt(now));
    _ = try f.step(4);
    f.mixer.update();
    try testing.expectEqual(@as(?u64, 4), f.mixer.startedAt(now));
}
