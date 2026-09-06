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
};

/// A voice giving its slot back. Callback thread to game thread.
const Retired = struct {
    slot: u32,
    generation: u32,
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

        // -- shared, one writer each ----------------------------------------------
        to_audio: ring.Ring(Command),
        from_audio: ring.Ring(Retired),

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

            // **Sized so a retirement can never be dropped.** A voice retires at most
            // once and cannot play again until `update` returns its slot, so at most
            // `voice_count` retirements can ever be outstanding. A dropped retirement
            // would strand a slot forever, which is the one loss this design cannot
            // absorb — so it is made structurally impossible rather than counted.
            var from_audio: ring.Ring(Retired) = try .init(gpa, voice_count);
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

        pub fn deinit(self: *Self) void {
            const gpa = self.gpa;

            // **The device goes first.** Closing it is what stops the thread; freeing
            // anything below while a callback is in flight is the one ordering mistake
            // here that would be a crash rather than a wrong sound.
            self.plat.closeAudio(self.device);
            self.ready.store(false, .monotonic);

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
        pub fn soundLoader(self: *Self) asset.Loader {
            return .{
                .schema = asset.schemas.sound.id,
                .ctx = self,
                .load = soundLoad,
                .unload = soundUnload,
            };
        }

        fn soundLoad(
            ctx: ?*anyopaque,
            gpa: Allocator,
            record: asset.Record,
            bytes: []const u8,
        ) asset.LoadError!asset.Payload {
            _ = record;
            const self: *Self = @ptrCast(@alignCast(ctx.?));

            var decoded = asset.wav.decode(gpa, bytes, .{}) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // A valid WAV this decoder does not handle. The file is fine and the
                // answer for the author is different: transcode, do not debug.
                error.UnsupportedSound => error.UnsupportedVersion,
                error.SoundTooLarge => error.LoadFailed,
                error.InvalidSound => error.InvalidAsset,
            };
            errdefer decoded.deinit(gpa);

            return .fromHandle(try self.insertSound(decoded));
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
            _ = self.to_audio.push(.{ .stop = .{ .voice = handle } });
        }

        pub fn stopAll(self: *Self) void {
            _ = self.to_audio.push(.stop_all);
        }

        pub fn setGain(self: *Self, handle: VoiceHandle, gain: f32) void {
            _ = self.to_audio.push(.{ .set_gain = .{ .voice = handle, .gain = gain } });
        }

        /// The trigonometry runs here, once, rather than per sample in the callback.
        pub fn setPan(self: *Self, handle: VoiceHandle, pan: f32) void {
            const gains = voice.panGains(pan);
            _ = self.to_audio.push(.{
                .set_pan = .{ .voice = handle, .left = gains.left, .right = gains.right },
            });
        }

        /// The ratio is computed here for the same reason the pan gains are: the callback
        /// does arithmetic, not policy, and the device's rate is known on this side.
        pub fn setPitch(self: *Self, handle: VoiceHandle, pitch: f32) void {
            const slot = self.liveSlot(handle) orelse return;
            const stored = self.sounds.getConst(slot.sound) orelse return;
            _ = self.to_audio.push(.{ .set_pitch = .{
                .voice = handle,
                .step = voice.stepFor(stored.sound.sample_rate, self.info.sample_rate, pitch),
            } });
        }

        pub fn setMasterGain(self: *Self, gain: f32) void {
            _ = self.to_audio.push(.{ .set_master_gain = .{ .gain = gain } });
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
            while (self.from_audio.pop()) |retired| {
                const slot = &self.slots[retired.slot];
                // A generation that has moved on means this slot was already reclaimed;
                // the retirement is for a voice two lives ago and is simply old news.
                if (!slot.playing or slot.generation != retired.generation) continue;

                slot.playing = false;
                const sound = slot.sound;
                const held = slot.held;
                slot.sound = .none;
                slot.held = .none;
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
            for (self.voices, 0..) |*v, index| {
                if (!v.active) continue;
                const generation = v.generation;
                if (!v.mix(out, self.info.channels)) {
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
        }

        /// 5. A voice stops reading its samples here, and the push is what tells the game
        ///    thread it may free them.
        fn retire(self: *Self, index: u32, generation: u32) void {
            // Sized so this cannot fail (see `init`). Ignoring the result would hide a
            // stranded slot, so the impossible case says so instead of vanishing.
            if (!self.from_audio.push(.{ .slot = index, .generation = generation })) {
                core.assert.unreachableCode(
                    "audio: the retirement ring was full, which its size forbids",
                    .{},
                );
            }
        }

        fn apply(self: *Self, command: Command) void {
            switch (command) {
                .play => |p| {
                    // A `play` addresses its slot directly: the game thread claimed it,
                    // and no other command for that generation can have arrived first.
                    self.voices[p.voice.index] = .{
                        .active = true,
                        .generation = p.voice.generation,
                        .samples = p.samples,
                        .channels = p.channels,
                        .frames = p.frames,
                        .cursor = 0,
                        .step = p.step,
                        .gain = p.gain,
                        .left = p.left,
                        .right = p.right,
                        .looping = p.looping,
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
                    const v = self.liveVoice(s.voice) orelse return;
                    v.gain = s.gain;
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
