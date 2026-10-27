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
const bus = @import("bus.zig");
const effects = @import("effects.zig");
const spatial = @import("spatial.zig");
const streaming = @import("stream.zig");
const voice = @import("voice.zig");

const Allocator = std.mem.Allocator;
const Voice = voice.Voice;
const Feed = streaming.Feed;
const vorbis = asset.vorbis;
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
    /// Voices that can play at once. Past this, `play` steals the lowest-priority, quietest,
    /// oldest voice whose priority is at most the new one's, or returns `error.NoFreeVoice`
    /// when every voice outranks it (`mixing.md` §7).
    voices: u32 = 32,
    /// Extra voices `play` never claims, where a stolen voice fades out (§7).
    fade_slots: u32 = 4,
    /// How long a stolen voice fades: 256 frames is 5.3 ms at 48 kHz.
    steal_fade_frames: u32 = 256,
    /// Commands the game may issue between two device callbacks. Past this a command is
    /// dropped and counted — see `commandsDropped`.
    command_capacity: u32 = 256,
    sample_rate: u32 = 48_000,
    channels: u8 = 2,
    buffer_frames: u32 = 512,
    master_gain: f32 = 1.0,
    /// Streamed voices that can play at once (`music.md` §6.1). Each owns a ring of one
    /// second at the largest rate a stream may have, allocated here. Past it, `play` of a
    /// streamed sound returns `error.NoFreeStream`.
    streams: u32 = 4,
    /// Where streams decode. `immediate` decodes inside `play` and `update`, on the game
    /// thread; a game hands its background pool's (`platform.Background`) so the decode
    /// happens beside the frame. Must outlive the mixer.
    tasks: core.Tasks = core.tasks.immediate,
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
    /// The source frame the voice begins on (`mixing.md` §6.2). At or past the sound's end is
    /// refused with `InvalidStart`. A looping voice started past its loop's end begins where
    /// that frame falls within the region.
    start_frame: u64 = 0,
    /// Makes the voice spatial (`mixing.md` §5): it is placed from here against the listener
    /// each `update`, and `pan` is ignored. In ADR-0048's metres.
    position: ?core.math.Vec3 = null,
    /// The `foundry:audio_attenuation` a spatial voice uses, in place of its sound record's.
    attenuation: ?core.ContentId = null,
    /// Overrides the sound record's `priority` (0–255; higher is kept when voices run out).
    priority: ?u8 = null,
};

pub const Listener = spatial.Listener;

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
    /// Every voice is in use by one of higher priority, so none could be stolen (§7).
    NoFreeVoice,
    /// No such sound, or one a hot reload has retired.
    UnknownSound,
    /// The command ring was full, so the voice could not be started. **Distinct from
    /// dropping a `set_gain`**: a `play` that vanished would strand a slot that no
    /// retirement is ever coming for, so the claim is undone and the caller told.
    CommandQueueFull,
    /// Every stream is in use, so a streamed sound cannot start (`Options.streams`).
    NoFreeStream,
    /// A streamed voice's decoder state could not be allocated.
    OutOfMemory,
    /// `start_frame` is at or past the sound's end: caller arithmetic, refused by name.
    InvalidStart,
    /// A spatial play's position is not finite.
    InvalidPosition,
    /// A spatial play's attenuation names no `foundry:audio_attenuation`, or one that does not
    /// decode.
    UnknownAttenuation,
};

/// What `play` can fail with: everything about a voice, plus everything about resolving a
/// content id. **The registry's own set, unflattened**, because a sound that is missing, a
/// sound whose file is gone and a sound that is really a texture send an author to three
/// different places, and collapsing them into one `UnknownSound` would throw that away.
pub const PlayError = VoiceError || asset.AcquireError;

/// What `useMix` and `contentChanged` can be refused with: a tree the records cannot make
/// (`bus.BuildError`), or a handoff that cannot be sent yet.
pub const MixError = bus.BuildError || error{
    /// The command ring was full, so the tree was not handed over; the old one plays on.
    CommandQueueFull,
    /// Four trees are already waiting for the callback to give them back. An `update` drains
    /// them.
    SwapPending,
};

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
    fade_gain: struct { voice: VoiceHandle, at: ?u64, gain: f32, frames: u32 },
    /// A spatial voice's new placement, glided to across the next buffer.
    spatial: struct { voice: VoiceHandle, placed: spatial.Placed },
    /// Takes a voice from its slot before a `play` claims the slot (§7): into fade voice
    /// `into` to fade over `frames`, or cut at once when `into` is null.
    steal: struct { victim: VoiceHandle, into: ?u32, frames: u32 },
    /// Installs a bus tree between two buffers, and every voice's bus in it (§8.3). The old
    /// tree comes back as a `tree` event.
    swap_mix: *bus.Tree,
    /// Ramps a bus's game gain (`setBusGain`).
    bus_gain: struct { index: u16, gain: f32, frames: u32 },
    /// A reload changed a bus record's gain.
    bus_base: struct { index: u16, gain: f32 },
    /// New parameters for one effect, of its kind and fixed fields (`setEffect`, §9).
    effect: struct { unit: u16, effect: asset.mix.Effect, frames: u32 },
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
    /// The loop region and the first source frame, already folded (`mixing.md` §6.3).
    loop_start: usize,
    loop_end: usize,
    start: usize,
    /// A streamed voice's frames, in place of `samples`.
    feed: ?*Feed,
    /// A spatial voice's first placement, which it starts at rather than glides to.
    placed: ?spatial.Placed,
    /// Its bus in the tree the callback will have when this arrives.
    bus: u16,
};

/// Callback thread to game thread: a voice's first sample landed on `frame`, or the voice
/// gave its slot back.
const Event = struct {
    /// `tree`: a `swap_mix` installed its tree, so the one before it may be freed.
    kind: enum(u8) { started, retired, tree },
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
    /// The stream a streamed voice reads, told when the voice retires.
    stream: ?u32 = null,
    /// A spatial voice's place, recomputed each `update` (`mixing.md` §5.5).
    space: ?Space = null,
    /// What stealing weighs (§7): the priority, the gains the game last set, and the order
    /// voices were started in.
    priority: u8 = 128,
    level: f32 = 1,
    envelope: f32 = 1,
    sequence: u64 = 0,
    /// A stolen voice still fading or not yet cut, whose references wait for the callback's
    /// word that it has stopped reading. The slot itself already plays its new voice.
    zombie: ?Zombie = null,
};

/// A stolen voice's references, released when its retirement arrives (§7's lifetime).
const Zombie = struct {
    generation: u32,
    sound: SoundHandle,
    held: asset.AssetHandle,
    stream: ?u32,
    /// The fade voice it took, freed with it.
    fade: ?u32,
};

/// Where a spatial voice is, as the game last said, and what was last sent for it.
const Space = struct {
    position: core.math.Vec3,
    occlusion: f32 = 0,
    attenuation: asset.mix.Attenuation,
    sent: spatial.Placed,
};

/// A streamed sound: its compressed bytes, kept, and the headers every stream of it shares
/// read-only (`music.md` §4, §6.1). Boxed, so a decoder may borrow it while the sound table
/// grows.
const Compressed = struct {
    bytes: []u8,
    headers: vorbis.Headers,
    /// What `vorbis.Decoder.reserve` needs so a decode task never allocates.
    spanning: usize,
    /// Where a seek may begin, built by the proving pass (`mixing.md` §6.1).
    index: []vorbis.Checkpoint,

    fn destroy(self: *Compressed, gpa: Allocator) void {
        gpa.free(self.index);
        self.headers.deinit();
        gpa.free(self.bytes);
        gpa.destroy(self);
    }
};

/// What the sound loader's decode hands its finish: the samples or the compressed bytes, and
/// how the record says to mix them (`mixing.md` §4.1).
const Loaded = struct {
    data: union(enum) {
        resident: asset.Sound,
        streamed: *Compressed,
    },
    settings: asset.mix.SoundSettings,

    fn deinit(self: *Loaded, gpa: Allocator) void {
        switch (self.data) {
            .resident => |*sound| sound.deinit(gpa),
            .streamed => |compressed| compressed.destroy(gpa),
        }
    }
};

/// One streamed voice's decoding (`music.md` §6). The table is fixed at `init`, so a feed's
/// address is stable for the voice that reads it and the task that fills it.
const Stream = struct {
    feed: Feed,

    // -- the game thread's --------------------------------------------------------
    in_use: bool = false,
    sound: SoundHandle = .none,
    /// Its voice has retired: nothing reads the feed any more.
    retired: bool = false,
    /// A decode task has been started and its `done` not yet seen.
    in_flight: bool = false,
    done: core.tasks.Done = .{},

    // -- the producer's: the task in flight, or the game thread when none is ---------
    decoder: vorbis.Decoder = undefined,
    looping: bool = false,
    /// The sound's seek index, borrowed from its `Compressed`, which the stream keeps alive.
    index: []const vorbis.Checkpoint = &.{},
    /// The loop region in source frames: a looping stream decodes to `loop_end` and seeks
    /// back to `loop_start` (`mixing.md` §6.3).
    loop_start: u64 = 0,
    loop_end: u64 = 0,
    /// The source frame the decoder gives next.
    source: u64 = 0,
    /// Absolute frames decoded so far, across every pass.
    produced: u64 = 0,
    /// A one-shot has decoded its last frame, or the decoder failed.
    ended: bool = false,

    /// The decode task: fills the ring until it is full or the sound ends.
    ///
    /// **Never allocates and should never fail.** The decoder's memory was reserved at
    /// `play` from what the load's proving pass measured, and the same bytes decoded whole
    /// at load. A failure anyway ends the stream, which the voice hears as an underrun.
    fn fill(erased: *anyopaque) void {
        const self: *Stream = @ptrCast(@alignCast(erased));
        var empty_passes: u8 = 0;
        const ch = self.feed.channels;
        while (!self.ended) {
            var room = self.feed.room(self.produced);
            if (room.len == 0) break;
            if (self.looping) {
                // At the region's end, back to its start: the seek is exact, so the seam is
                // the region's length and nothing else (`mixing.md` §6.3).
                if (self.source >= self.loop_end) {
                    self.decoder.seek(self.index, self.loop_start) catch |err| {
                        log.err("a streamed loop failed to restart ({t}); it goes silent", .{err});
                        self.ended = true;
                        break;
                    };
                    self.source = self.loop_start;
                }
                const left: usize = @intCast(@min(self.loop_end - self.source, room.len / ch));
                room = room[0 .. left * ch];
            }
            const got = self.decoder.read(room) catch |err| {
                log.err("a streamed sound failed to decode while playing ({t}); it goes silent", .{err});
                self.ended = true;
                break;
            };
            if (got == 0) {
                // A pass that made nothing would loop forever.
                empty_passes += 1;
                if (!self.looping or empty_passes > 1) {
                    self.ended = true;
                    break;
                }
                self.source = self.loop_end;
                continue;
            }
            empty_passes = 0;
            self.source += got;
            self.produced += got;
            self.feed.publish(self.produced);
        }
    }
};

/// A decoded sound and what keeps it alive.
const Stored = struct {
    /// Empty for a streamed sound, whose frames are decoded as it plays.
    sound: asset.Sound,
    compressed: ?*Compressed = null,
    /// How its record says to mix it (`mixing.md` §4.1); the defaults for a sound inserted
    /// directly.
    settings: asset.mix.SoundSettings = .{},
    /// Voices currently playing it. The samples cannot be freed above zero.
    refs: u32 = 0,
    /// Set when the owner has released it — a hot reload, or an explicit release — while
    /// a voice may still be reading. Freed by a later `update`.
    retired: bool = false,

    fn frameCount(self: *const Stored) usize {
        if (self.compressed) |c| return @intCast(c.headers.frames);
        return self.sound.frameCount();
    }

    fn deinit(self: *Stored, gpa: Allocator) void {
        self.sound.deinit(gpa);
        if (self.compressed) |c| c.destroy(gpa);
    }
};

/// Trees that may be handed over and not yet given back at once (§8.3).
const max_pending_swaps = 4;

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
        /// Fixed at `init`. Each feed is shared with the voice reading it and the task
        /// filling it (`stream.zig`); the rest is the game thread's.
        streams: []Stream,
        /// Every stream's ring, one allocation.
        stream_storage: []f32,
        tasks: core.Tasks,
        /// Who hears the spatial voices: the last listener `setListener` accepted.
        listener: spatial.Basis = .{},
        /// Fade voices in use, by index past the slots (§7).
        fade_busy: []bool,
        steal_fade_frames: u32,
        /// Plays started, for stealing's age order.
        sequence: u64 = 0,
        stolen_count: u32 = 0,
        cut_count: u32 = 0,
        /// The bus tree as the game thread last built it, which every command since refers to.
        mirror: ?*bus.Tree = null,
        /// Trees handed over and replaced, oldest first, each freed by the `tree` event that
        /// says the callback has let it go (null for the first swap, which replaced none).
        retiring: std.ArrayList(?*bus.Tree) = .empty,
        misrouted_count: u32 = 0,

        // -- owned by the callback thread -----------------------------------------
        voices: []Voice,
        master_gain: f32,
        /// The bus tree being mixed, installed by `swap_mix`; null mixes M30's way.
        tree: ?*bus.Tree = null,
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
        /// Buffers in which a streamed voice found a frame missing and played silence for
        /// it. Written by the callback; a diagnostic, so monotonic.
        underrun_count: std.atomic.Value(u32) = .init(0),

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

            // The fade voices sit past the slots' voices; nothing but a steal reaches them.
            const voices = try gpa.alloc(Voice, voice_count + options.fade_slots);
            errdefer gpa.free(voices);
            @memset(voices, .{});
            const fade_busy = try gpa.alloc(bool, options.fade_slots);
            errdefer gpa.free(fade_busy);
            @memset(fade_busy, false);

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
            // the retirement — and with it, the ring being FIFO, the start before it. A
            // steal is the one way a slot plays again first (§7), and a slot with a stolen
            // voice outstanding cannot be stolen from again, so it adds at most one more per
            // slot, the stolen voice's retirement; four per slot leaves room to spare. A
            // dropped retirement would strand a slot forever, which is the one loss this
            // design cannot absorb, so it is made structurally impossible rather than counted.
            // Plus one `tree` event for each swap that may be outstanding.
            var from_audio: ring.Ring(Event) = try .init(gpa, 4 * voice_count + max_pending_swaps);
            errdefer from_audio.deinit(gpa);

            // One second at the highest rate a sound may have, for each stream: the most any
            // stream needs, so nothing is allocated for a ring when one starts.
            const ring_samples: usize = vorbis.max_sample_rate * vorbis.max_channels;
            const stream_storage = try gpa.alloc(f32, ring_samples * options.streams);
            errdefer gpa.free(stream_storage);
            const streams = try gpa.alloc(Stream, options.streams);
            errdefer gpa.free(streams);
            for (streams, 0..) |*st, n| st.* = .{ .feed = .{ .storage = stream_storage[n * ring_samples ..][0..ring_samples] } };

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
                .fade_busy = fade_busy,
                .steal_fade_frames = options.steal_fade_frames,
                .master_gain = options.master_gain,
                .to_audio = to_audio,
                .from_audio = from_audio,
                .streams = streams,
                .stream_storage = stream_storage,
                .tasks = options.tasks,
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

            // Then every decode task, and only then the streams they fill (`music.md` §6.5).
            self.quiesceStreams();
            for (self.streams, 0..) |*st, index| if (st.in_use) self.freeStream(@intCast(index));

            // The device thread is gone, so this is the one place a voice may be ended
            // without a round trip through the retirement ring.
            for (self.slots) |*slot| {
                if (!slot.playing) continue;
                slot.playing = false;
                slot.stream = null;
                const held = slot.held;
                slot.held = .none;
                slot.sound = .none;
                if (!held.isNone()) self.assets.release(held);
            }
            // And every stolen voice still fading, or cut and not yet reported.
            for (self.slots) |*slot| if (slot.zombie) |z| {
                slot.zombie = null;
                if (!z.held.isNone()) self.assets.release(z.held);
            };
        }

        /// Waits for every decode task in flight. **Only when one is**: an executor whose
        /// owner has already torn it down ran what it held first, so a mixer outliving its
        /// pool never calls into it.
        fn quiesceStreams(self: *Self) void {
            for (self.streams) |*st| {
                if (st.in_flight and !st.done.isSet()) {
                    self.tasks.wait();
                    break;
                }
            }
            for (self.streams) |*st| st.in_flight = false;
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

            self.quiesceStreams();
            for (self.streams) |*st| if (st.in_use) st.decoder.deinit();
            gpa.free(self.streams);
            gpa.free(self.stream_storage);

            var it = self.sounds.iterator();
            while (it.next()) |entry| entry.value.deinit(gpa);
            self.sounds.deinit(gpa);

            self.to_audio.deinit(gpa);
            self.from_audio.deinit(gpa);
            self.free_list.deinit(gpa);
            gpa.free(self.slots);
            gpa.free(self.voices);
            gpa.free(self.fade_busy);
            // The device is closed: every tree, current or retiring, is the game thread's again.
            for (self.retiring.items) |old| if (old) |t| t.destroy();
            self.retiring.deinit(gpa);
            if (self.mirror) |t| t.destroy();
            gpa.destroy(self);
        }

        // -- sounds ---------------------------------------------------------------

        /// Takes ownership of `sound` and returns the handle voices are started from.
        pub fn insertSound(self: *Self, sound: asset.Sound) Allocator.Error!SoundHandle {
            return self.sounds.add(self.gpa, .{ .sound = sound });
        }

        /// `insertSound` with mixing settings, as a `foundry:sound` record would give them.
        /// A loop region that does not fit the sound is refused, and the sound is not taken.
        pub fn insertSoundWith(self: *Self, sound: asset.Sound, settings: asset.mix.SoundSettings) (asset.mix.Refusal || Allocator.Error)!SoundHandle {
            try settings.validate();
            try settings.checkLoop(sound.frameCount());
            return self.sounds.add(self.gpa, .{ .sound = sound, .settings = settings });
        }

        /// Takes an Ogg Vorbis file as a streamed sound: proved by decoding it whole once,
        /// then kept compressed and decoded as each voice of it plays (`music.md` §4, §6).
        /// The bytes are copied.
        pub fn insertStreamed(self: *Self, bytes: []const u8) (vorbis.DecodeError || Allocator.Error)!SoundHandle {
            return self.insertStreamedWith(bytes, .{}) catch |err| switch (err) {
                error.OutOfMemory, error.InvalidSound, error.UnsupportedSound, error.SoundTooLarge => |e| e,
                // The defaults have the whole file as their region, which always fits.
                else => unreachable,
            };
        }

        /// `insertStreamed` with mixing settings. A loop region that does not fit is refused.
        pub fn insertStreamedWith(self: *Self, bytes: []const u8, settings: asset.mix.SoundSettings) (vorbis.DecodeError || asset.mix.Refusal || Allocator.Error)!SoundHandle {
            try settings.validate();
            const compressed = try prepareStreamed(self.gpa, bytes);
            errdefer compressed.destroy(self.gpa);
            if (settings.loop_start != 0 or settings.loop_end != 0) try settings.checkLoop(compressed.headers.frames);
            return self.adoptStreamed(compressed, settings);
        }

        fn prepareStreamed(gpa: Allocator, bytes: []const u8) vorbis.DecodeError!*Compressed {
            const proven = try vorbis.prove(gpa, bytes, .{});
            var headers = proven.headers;
            errdefer headers.deinit();
            errdefer gpa.free(proven.index);
            const compressed = try gpa.create(Compressed);
            errdefer gpa.destroy(compressed);
            compressed.* = .{ .bytes = try gpa.dupe(u8, bytes), .headers = headers, .spanning = proven.spanning, .index = proven.index };
            return compressed;
        }

        fn adoptStreamed(self: *Self, compressed: *Compressed, settings: asset.mix.SoundSettings) Allocator.Error!SoundHandle {
            const info = compressed.headers.info;
            return self.sounds.add(self.gpa, .{
                .sound = .{ .samples = @constCast(@as([]const f32, &.{})), .channels = info.channels, .sample_rate = info.sample_rate },
                .compressed = compressed,
                .settings = settings,
            });
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
            stored.deinit(self.gpa);
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
            const ogg = bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS");
            if (stream and !ogg) {
                // Streaming PCM that is already resident would buy nothing and cost a ring.
                log.warn("{f}: stream is for compressed sounds, and this is not one", .{record.id});
                return error.UnsupportedVersion;
            }
            // How it is mixed, which `fpack` already checked as far as the record alone can.
            const settings = asset.mix.decodeSound(record.fields) catch |err| {
                log.warn("{f}: sound {s}", .{ record.id, asset.mix.describe(err) });
                return error.InvalidAsset;
            };
            const boxed = try gpa.create(Loaded);
            errdefer gpa.destroy(boxed);
            // A streamed sound is decoded whole too, and its samples thrown away: the proving
            // pass that lets a stream's decode treat failure as impossible (`music.md` §4).
            boxed.* = .{ .settings = settings, .data = loaded: {
                if (stream) break :loaded .{ .streamed = prepareStreamed(gpa, bytes) catch |err| return loadError(err) };
                const decoded = if (ogg) vorbis.decode(gpa, bytes, .{}) else asset.wav.decode(gpa, bytes, .{});
                break :loaded .{ .resident = decoded catch |err| return loadError(err) };
            } };
            errdefer boxed.deinit(gpa);
            // The loop region against the length, which only now is known (`mixing.md` §4.1).
            // A sound with no loop points has nothing to check: its region is the whole file.
            if (settings.loop_start != 0 or settings.loop_end != 0) {
                const frames: u64 = switch (boxed.data) {
                    .resident => |sound| sound.frameCount(),
                    .streamed => |compressed| compressed.headers.frames,
                };
                settings.checkLoop(frames) catch |err| {
                    log.warn("{f}: sound {s}", .{ record.id, asset.mix.describe(err) });
                    return error.InvalidAsset;
                };
            }
            return .fromPointer(boxed);
        }

        fn loadError(err: asset.SoundDecodeError) asset.LoadError {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // A valid file this decoder does not handle. The file is fine and the
                // answer for the author is different: transcode, do not debug.
                error.UnsupportedSound => error.UnsupportedVersion,
                error.SoundTooLarge => error.LoadFailed,
                error.InvalidSound => error.InvalidAsset,
            };
        }

        /// The samples, or the compressed bytes, become the mixer's; only the box they came
        /// in is freed here.
        fn soundFinish(
            ctx: ?*anyopaque,
            gpa: Allocator,
            _: asset.Record,
            decoded: asset.Decoded,
            _: *asset.Budget,
        ) asset.LoadError!asset.Payload {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const boxed: *Loaded = @ptrCast(@alignCast(decoded.pointer().?));
            const handle = switch (boxed.data) {
                .resident => |sound| try self.sounds.add(self.gpa, .{ .sound = sound, .settings = boxed.settings }),
                .streamed => |compressed| try self.adoptStreamed(compressed, boxed.settings),
            };
            gpa.destroy(boxed);
            return .fromHandle(handle);
        }

        fn soundDiscard(gpa: Allocator, decoded: asset.Decoded) void {
            const boxed: *Loaded = @ptrCast(@alignCast(decoded.pointer().?));
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
            if (stored.frameCount() == 0) return error.UnknownSound;

            // The region and the first frame, folded so the voice and its stream need not ask
            // (`mixing.md` §6.2, §6.3). A one-shot's region is the whole file, which it uses
            // only to know where it ends.
            const frames: u64 = stored.frameCount();
            if (params.start_frame >= frames) return error.InvalidStart;
            const loop_start: u64 = if (params.looping) stored.settings.loop_start else 0;
            const loop_end: u64 = if (params.looping) stored.settings.loopEnd(frames) else frames;
            var start = params.start_frame;
            if (params.looping and start >= loop_end) start = loop_start + (start - loop_start) % (loop_end - loop_start);

            // A spatial voice's attenuation, resolved once, and its first placement, so its
            // first buffer is already where it is rather than gliding there (`mixing.md` §5).
            var space: ?Space = null;
            if (params.position) |position| {
                if (!position.isFinite()) return error.InvalidPosition;
                const attenuation = try self.resolveAttenuation(params.attenuation orelse stored.settings.attenuation);
                space = .{
                    .position = position,
                    .attenuation = attenuation,
                    .sent = spatial.place(self.listener, position, attenuation, 0, self.info.sample_rate),
                };
            }

            // A free slot, or one to steal (`mixing.md` §7). Chosen before anything is claimed,
            // so a refusal below leaves every voice as it was.
            const priority = params.priority orelse stored.settings.priority;
            const victim: ?u32 = if (self.free_list.items.len > 0) null else self.chooseVictim(priority) orelse return error.NoFreeVoice;
            // A steal and the play after it go together or not at all.
            if (victim != null and self.to_audio.capacity() - self.to_audio.len() < 2) return error.CommandQueueFull;

            // A streamed sound needs a stream as well as a voice, and its decoder state, which
            // is the one thing `play` allocates (`music.md` §6.1).
            var stream_index: ?u32 = null;
            if (stored.compressed) |compressed| {
                const n = self.freeStreamIndex() orelse return error.NoFreeStream;
                const st = &self.streams[n];
                st.decoder = vorbis.Decoder.init(self.gpa, compressed.bytes, &compressed.headers) catch |err| return streamError(err);
                st.decoder.reserve(compressed.spanning) catch {
                    st.decoder.deinit();
                    return error.OutOfMemory;
                };
                // Begun part-way: one packet decoded for its overlap and at most a page of frames
                // dropped, on the game thread where `play` may cost (`mixing.md` §6.1).
                if (start != 0) st.decoder.seek(compressed.index, start) catch |err| {
                    st.decoder.deinit();
                    return streamError(err);
                };
                st.feed.reset(compressed.headers.info.sample_rate, compressed.headers.info.channels);
                st.in_use = true;
                st.sound = sound;
                st.retired = false;
                st.in_flight = false;
                st.looping = params.looping;
                st.index = compressed.index;
                st.loop_start = loop_start;
                st.loop_end = loop_end;
                st.source = start;
                st.produced = 0;
                st.ended = false;
                // The stream holds the compressed bytes alive for its decode task, which may
                // outlast the voice (`music.md` §6.5).
                stored.refs += 1;
                stream_index = n;
            }

            const index = if (victim) |v| self.steal(v) else self.free_list.pop().?;
            const slot = &self.slots[index];
            slot.generation = nextGeneration(slot.generation);
            slot.priority = priority;
            slot.level = params.gain;
            slot.envelope = params.envelope;
            self.sequence += 1;
            slot.sequence = self.sequence;
            slot.playing = true;
            slot.sound = sound;
            slot.started_at = null;
            slot.stream = stream_index;
            slot.space = space;
            stored.refs += 1;

            const handle: VoiceHandle = .{ .index = index, .generation = slot.generation };
            const gains = voice.panGains(params.pan);
            const started = self.to_audio.push(.{ .play = .{
                .voice = handle,
                .samples = stored.sound.samples,
                .channels = stored.sound.channels,
                .frames = stored.frameCount(),
                .step = voice.stepFor(stored.sound.sample_rate, self.info.sample_rate, params.pitch),
                .gain = params.gain,
                .left = gains.left,
                .right = gains.right,
                .looping = params.looping,
                .start_at = params.start_at,
                .envelope = params.envelope,
                .loop_start = @intCast(loop_start),
                .loop_end = @intCast(loop_end),
                .start = @intCast(start),
                .feed = if (stream_index) |n| &self.streams[n].feed else null,
                .placed = if (space) |s| s.sent else null,
                .bus = self.route(stored.settings.bus, true),
            } });

            if (!started) {
                // Undo the claim. Nothing was ever started, so no retirement is coming, and
                // no decode task either.
                stored.refs -= 1;
                slot.playing = false;
                slot.sound = .none;
                slot.stream = null;
                slot.space = null;
                self.free_list.appendAssumeCapacity(index);
                if (stream_index) |n| self.freeStream(n);
                return error.CommandQueueFull;
            }
            // The first fill starts now, so the ring is full before a scheduled start arrives
            // (§8.4's lookahead is a second).
            if (stream_index) |n| self.refill(&self.streams[n]);
            return handle;
        }

        // -- buses (`mixing.md` §8, ADR-0067) -----------------------------------------

        /// Mixes through the tree of buses under `root`, from the next callback: every
        /// `foundry:audio_bus` whose chain of parents reaches it. A tree the records cannot
        /// make is refused by name, and the mix carries on as it was.
        pub fn useMix(self: *Self, root: core.ContentId) MixError!void {
            if (self.retiring.items.len >= max_pending_swaps) return error.SwapPending;
            const tree = try bus.build(self.gpa, self.assets.store, root, self.info.buffer_frames, self.info.channels, self.info.sample_rate, self.voices.len);
            errdefer tree.destroy();
            try self.handOver(tree);
        }

        /// After a reload: a changed bus gain is sent as a command and the tree plays on, while
        /// a changed shape (a bus added or moved, a chain changed) builds a new tree and swaps
        /// it in (§8.3). Without a tree, nothing.
        pub fn contentChanged(self: *Self) MixError!void {
            const current = self.mirror orelse return;
            if (self.retiring.items.len >= max_pending_swaps) return error.SwapPending;
            const candidate = try bus.build(self.gpa, self.assets.store, current.ids[0], self.info.buffer_frames, self.info.channels, self.info.sample_rate, self.voices.len);
            if (!candidate.sameShape(current)) {
                errdefer candidate.destroy();
                return self.handOver(candidate);
            }
            defer candidate.destroy();
            for (candidate.records, 0..) |record, k| {
                if (record.gain == current.records[k].gain) continue;
                if (!self.to_audio.push(.{ .bus_base = .{ .index = @intCast(k), .gain = record.gain } })) return error.CommandQueueFull;
                current.records[k].gain = record.gain;
            }
            // An effect's new parameters, a filter's ramped over one buffer so a reload does
            // not click (§8.3).
            for (candidate.effect_values, 0..) |value, u| {
                if (std.meta.eql(value, current.effect_values[u])) continue;
                const frames: u32 = @intCast(current.block);
                if (!self.to_audio.push(.{ .effect = .{ .unit = @intCast(u), .effect = value, .frames = frames } })) return error.CommandQueueFull;
                current.effect_values[u] = value;
            }
        }

        /// New parameters for effect `slot` of bus `id`, ramped over `frames` where the effect
        /// ramps (a filter's frequency, Q and gain), at once otherwise (§9). Refused for a bus
        /// or slot that is not there, an effect of another kind, a changed field that sizes
        /// memory (a delay's time, a reverb's size or predelay, a limiter's lookahead: those
        /// are a reload's), or values out of their records' ranges.
        pub fn setEffect(self: *Self, id: core.ContentId, slot: u8, effect: asset.mix.Effect, frames: u32) void {
            _ = self.setEffectChecked(id, slot, effect, frames);
        }

        pub fn setEffectChecked(self: *Self, id: core.ContentId, slot: u8, effect: asset.mix.Effect, frames: u32) bool {
            effect.validate() catch return false;
            const tree = self.mirror orelse return false;
            const index = tree.indexOf(id) orelse return false;
            if (slot >= tree.unit_count[index]) return false;
            const unit = tree.unit_first[index] + slot;
            if (!effects.fixedEql(tree.effect_values[unit], effect)) return false;
            if (!self.to_audio.push(.{ .effect = .{ .unit = unit, .effect = effect, .frames = frames } })) return false;
            tree.effect_values[unit] = effect;
            return true;
        }

        /// Sends `tree` to the callback with every voice's bus in it, and keeps the one it
        /// replaces until the callback gives it back.
        fn handOver(self: *Self, tree: *bus.Tree) MixError!void {
            try self.retiring.ensureUnusedCapacity(self.gpa, 1);
            for (self.slots, 0..) |*slot, i| {
                tree.voice_bus[i] = if (slot.playing) busIn(tree, self.soundBus(slot.sound)) else 0;
            }
            for (self.slots) |*slot| if (slot.zombie) |z| if (z.fade) |n| {
                tree.voice_bus[self.slots.len + n] = busIn(tree, self.soundBus(z.sound));
            };
            if (!self.to_audio.push(.{ .swap_mix = tree })) return error.CommandQueueFull;
            self.retiring.appendAssumeCapacity(self.mirror);
            self.mirror = tree;
        }

        fn soundBus(self: *Self, sound: SoundHandle) ?core.ContentId {
            const stored = self.sounds.get(sound) orelse return null;
            return stored.settings.bus;
        }

        fn busIn(tree: *const bus.Tree, id: ?core.ContentId) u16 {
            return tree.indexOf(id orelse return 0) orelse 0;
        }

        /// The bus a sound routed to `id` mixes into now: 0 (the root) for none, for no tree, or
        /// for a bus the tree does not have, which a play counts as misrouted (§8.2).
        fn route(self: *Self, id: ?core.ContentId, count: bool) u16 {
            const tree = self.mirror orelse return 0;
            const which = id orelse return 0;
            return tree.indexOf(which) orelse {
                if (count) self.misrouted_count += 1;
                return 0;
            };
        }

        /// Ramps bus `id`'s game gain to `gain` over `frames`, from the next callback. The
        /// output is the record's gain times this one, so a player's slider and a reload of
        /// the record never overwrite each other (§8.4).
        pub fn setBusGain(self: *Self, id: core.ContentId, gain: f32, frames: u32) void {
            _ = self.setBusGainChecked(id, gain, frames);
        }

        pub fn setBusGainChecked(self: *Self, id: core.ContentId, gain: f32, frames: u32) bool {
            if (!std.math.isFinite(gain) or gain < 0) return false;
            const tree = self.mirror orelse return false;
            const index = tree.indexOf(id) orelse return false;
            return self.to_audio.push(.{ .bus_gain = .{ .index = index, .gain = gain, .frames = frames } });
        }

        /// Frames the mix delays the longest path from a bus to the device: the sum of the
        /// lookaheads of the limiters on it (§9). The sample clock counts mixed frames, and a
        /// voice scheduled to one is heard this much later. 0 without a tree.
        pub fn mixerLatency(self: *const Self) u32 {
            const tree = self.mirror orelse return 0;
            var longest: usize = 0;
            for (0..tree.count()) |start| {
                var total: usize = 0;
                var k: u16 = @intCast(start);
                while (true) {
                    // A unit's lookahead is fixed when the tree is built, so reading it here,
                    // while the callback runs the unit, reads nothing the callback writes.
                    for (tree.chain(k)) |*unit| total += unit.latency();
                    if (k == 0) break;
                    k = tree.parents[k];
                }
                longest = @max(longest, total);
            }
            return @intCast(longest);
        }

        /// Plays whose sound names a bus the tree does not have, mixed into the root instead.
        pub fn misrouted(self: *const Self) u32 {
            return self.misrouted_count;
        }

        // -- voice stealing (`mixing.md` §7) -----------------------------------------

        /// The slot to take for a voice of `priority`, or null when every playing voice
        /// outranks it. Lowest priority first, then the quietest by what the game last set,
        /// then the oldest: every input is game-thread state, so the choice is deterministic.
        /// A slot whose last stolen voice is still outstanding is not taken again.
        fn chooseVictim(self: *const Self, priority: u8) ?u32 {
            var best: ?u32 = null;
            for (self.slots, 0..) |*slot, index| {
                if (!slot.playing or slot.zombie != null or slot.priority > priority) continue;
                if (best) |b| if (!self.quieter(slot, &self.slots[b])) continue;
                best = @intCast(index);
            }
            return best;
        }

        /// Whether `a` should be stolen before `b`.
        fn quieter(self: *const Self, a: *const Slot, b: *const Slot) bool {
            _ = self;
            if (a.priority != b.priority) return a.priority < b.priority;
            const la = loudness(a);
            const lb = loudness(b);
            if (la != lb) return la < lb;
            return a.sequence < b.sequence;
        }

        /// The game thread's estimate of how loud a voice is: its level, its envelope's target,
        /// and a spatial voice's distance and occlusion. One placed past its far distance is 0.
        fn loudness(slot: *const Slot) f32 {
            const space: f32 = if (slot.space) |s| s.sent.space else 1;
            return slot.level * slot.envelope * space;
        }

        /// Takes slot `index` from its voice and returns it free: the voice moves to a fade
        /// voice to fade out, or is cut when none is free. Its references wait as a zombie for
        /// the retirement the callback reports once it has stopped reading (§7's lifetime).
        fn steal(self: *Self, index: u32) u32 {
            const slot = &self.slots[index];
            const spare: ?u32 = for (self.fade_busy, 0..) |busy, n| {
                if (!busy) break @intCast(n);
            } else null;
            if (spare) |n| self.fade_busy[n] = true else self.cut_count += 1;
            self.stolen_count += 1;
            const victim: VoiceHandle = .{ .index = index, .generation = slot.generation };
            // Room for this and the play after it was checked before anything was claimed.
            const pushed = self.to_audio.push(.{ .steal = .{ .victim = victim, .into = spare, .frames = self.steal_fade_frames } });
            std.debug.assert(pushed);
            slot.zombie = .{ .generation = slot.generation, .sound = slot.sound, .held = slot.held, .stream = slot.stream, .fade = spare };
            slot.playing = false;
            slot.sound = .none;
            slot.held = .none;
            slot.stream = null;
            slot.space = null;
            slot.started_at = null;
            return index;
        }

        /// Voices taken from their slots for a new one, faded or cut.
        pub fn stolen(self: *const Self) u32 {
            return self.stolen_count;
        }

        /// Steals that found every fade voice busy, and cut their victim at once.
        pub fn cutSteals(self: *const Self) u32 {
            return self.cut_count;
        }

        /// The attenuation a spatial voice uses: the named record's, or the defaults when none
        /// is named. Its schema is checked here, where the ID resolves (Step 1's Resolution).
        fn resolveAttenuation(self: *Self, id: ?core.ContentId) VoiceError!asset.mix.Attenuation {
            const which = id orelse return .{};
            const record = self.assets.store.lookup(which) orelse return error.UnknownAttenuation;
            if (!record.schema_id.eql(asset.mix.attenuation.id)) return error.UnknownAttenuation;
            return asset.mix.decodeAttenuation(record.fields) catch |err| {
                log.warn("{f}: audio attenuation {s}", .{ which, asset.mix.describe(err) });
                return error.UnknownAttenuation;
            };
        }

        // -- spatial voices (`mixing.md` §5, ADR-0068) ------------------------------

        /// Sets who hears the spatial voices, from the next `update`. A listener with a
        /// non-finite vector, or a `forward` parallel to `up`, is refused and the previous one
        /// kept.
        pub fn setListener(self: *Self, listener: Listener) void {
            _ = self.setListenerChecked(listener);
        }

        pub fn setListenerChecked(self: *Self, listener: Listener) bool {
            self.listener = spatial.basis(listener) orelse return false;
            return true;
        }

        /// Moves a spatial voice, from the next `update`. Refused for a voice that is not
        /// playing or not spatial, and for a position that is not finite.
        pub fn setPosition(self: *Self, handle: VoiceHandle, position: core.math.Vec3) void {
            _ = self.setPositionChecked(handle, position);
        }

        pub fn setPositionChecked(self: *Self, handle: VoiceHandle, position: core.math.Vec3) bool {
            if (!position.isFinite()) return false;
            const slot = self.liveSlot(handle) orelse return false;
            const space = &(slot.space orelse return false);
            space.position = position;
            return true;
        }

        /// How occluded a spatial voice is, 0 (open) to 1 (fully), from the next `update`. The
        /// game decides what is in the way (§5.4); out of range is clamped, not finite refused.
        pub fn setOcclusion(self: *Self, handle: VoiceHandle, amount: f32) void {
            _ = self.setOcclusionChecked(handle, amount);
        }

        pub fn setOcclusionChecked(self: *Self, handle: VoiceHandle, amount: f32) bool {
            if (!std.math.isFinite(amount)) return false;
            const slot = self.liveSlot(handle) orelse return false;
            const space = &(slot.space orelse return false);
            space.occlusion = std.math.clamp(amount, 0, 1);
            return true;
        }

        /// Places every spatial voice against the listener and sends each one that moved
        /// (§5.5). A placement the ring refuses is sent again next frame, since `sent` is
        /// what the voice actually has.
        fn placeSpatial(self: *Self) void {
            for (self.slots, 0..) |*slot, index| {
                if (!slot.playing) continue;
                const space = &(slot.space orelse continue);
                const placed = spatial.place(self.listener, space.position, space.attenuation, space.occlusion, self.info.sample_rate);
                if (placed.eql(space.sent)) continue;
                const handle: VoiceHandle = .{ .index = @intCast(index), .generation = slot.generation };
                if (self.to_audio.push(.{ .spatial = .{ .voice = handle, .placed = placed } })) space.sent = placed;
            }
        }

        fn streamError(err: vorbis.DecodeError) VoiceError {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // The bytes decoded whole at load, so a refusal now means they changed.
                else => error.UnknownSound,
            };
        }

        fn freeStreamIndex(self: *const Self) ?u32 {
            for (self.streams, 0..) |*st, n| if (!st.in_use) return @intCast(n);
            return null;
        }

        /// Starts a decode task for a stream below half full (`music.md` §6.2). One at a
        /// time: a stream with a task in flight waits for its `Done`.
        fn refill(self: *Self, st: *Stream) void {
            if (st.in_flight or st.ended or st.retired) return;
            if (st.feed.level() >= st.feed.capacity / 2) return;
            st.done = .{};
            self.tasks.start(.{ .context = st, .call = Stream.fill }, &st.done) catch return;
            st.in_flight = true;
        }

        /// Frees a stream whose voice has retired and whose task has finished, or one that
        /// never had either. Game thread.
        fn freeStream(self: *Self, n: u32) void {
            const st = &self.streams[n];
            std.debug.assert(st.in_use and !st.in_flight);
            st.decoder.deinit();
            const sound = st.sound;
            const feed = st.feed;
            st.* = .{ .feed = feed };
            if (self.sounds.get(sound)) |stored| {
                stored.refs -= 1;
                self.collect(sound, stored);
            }
        }

        /// Settles finished decode tasks, starts the ones streams need, and frees streams
        /// both sides are done with (`music.md` §6.2, §6.5).
        fn pumpStreams(self: *Self) void {
            for (self.streams, 0..) |*st, n| {
                if (!st.in_use) continue;
                if (st.in_flight and st.done.isSet()) st.in_flight = false;
                if (st.retired) {
                    if (!st.in_flight) self.freeStream(@intCast(n));
                    continue;
                }
                self.refill(st);
            }
        }

        /// Buffers in which a streamed voice played silence for a frame it did not yet have
        /// (`music.md` §6.3). Criterion 2 requires it to stay at zero.
        pub fn underruns(self: *const Self) u32 {
            return self.underrun_count.load(.monotonic);
        }

        /// Frames decoded ahead of a streamed voice, or null for a voice that is not one or is
        /// no longer playing. Approximate while the device runs. For a diagnostic and a margin
        /// measurement, never for a decision.
        pub fn streamBuffered(self: *const Self, handle: VoiceHandle) ?u64 {
            const slot = self.liveSlotConst(handle) orelse return null;
            const n = slot.stream orelse return null;
            return self.streams[n].feed.level();
        }

        /// Streams claimed, including ones whose voice has gone but whose task has not.
        pub fn streamsInUse(self: *const Self) u32 {
            var count: u32 = 0;
            for (self.streams) |st| {
                if (st.in_use) count += 1;
            }
            return count;
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
            if (!self.to_audio.push(.{ .set_gain = .{ .voice = handle, .gain = gain } })) return false;
            if (self.liveSlot(handle)) |slot| slot.level = gain;
            return true;
        }

        /// The trigonometry runs here, once, rather than per sample in the callback.
        pub fn setPan(self: *Self, handle: VoiceHandle, pan: f32) void {
            _ = self.setPanChecked(handle, pan);
        }

        pub fn setPanChecked(self: *Self, handle: VoiceHandle, pan: f32) bool {
            // A spatial voice's position decides its pan (`mixing.md` §5.1).
            if (self.liveSlot(handle)) |slot| if (slot.space != null) return false;
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
            if (!self.to_audio.push(.{ .fade = .{ .voice = handle, .fade = params } })) return false;
            if (self.liveSlot(handle)) |slot| slot.envelope = params.to;
            return true;
        }

        /// Ramps the voice's level, the gain `setGain` sets at once, linearly over `frames`
        /// from the next callback.
        pub fn fadeGain(self: *Self, handle: VoiceHandle, gain: f32, frames: u32) void {
            _ = self.fadeGainChecked(handle, gain, frames);
        }

        pub fn fadeGainChecked(self: *Self, handle: VoiceHandle, gain: f32, frames: u32) bool {
            return self.fadeGainAtChecked(handle, null, gain, frames);
        }

        /// `fadeGain` beginning at mixer frame `at`, as `fade` can: how a duck lands on the
        /// frame a stinger starts (`music.md` §8.4). Null, or a frame already past, begins it
        /// at the next callback.
        pub fn fadeGainAt(self: *Self, handle: VoiceHandle, at: ?u64, gain: f32, frames: u32) void {
            _ = self.fadeGainAtChecked(handle, at, gain, frames);
        }

        pub fn fadeGainAtChecked(self: *Self, handle: VoiceHandle, at: ?u64, gain: f32, frames: u32) bool {
            if (!self.to_audio.push(.{ .fade_gain = .{ .voice = handle, .at = at, .gain = gain, .frames = frames } })) return false;
            if (self.liveSlot(handle)) |slot| slot.level = gain;
            return true;
        }

        pub const SoundInfo = struct {
            /// Device frames the sound lasts at pitch 1: its frames through the voice's rate
            /// ratio, rounded up. A resampled voice accumulates its step, so its real end can
            /// differ from this by a frame; nothing scheduled depends on that frame.
            frames: u64,
            streamed: bool,
            /// The sound's own length, in its frames.
            source_frames: u64 = 0,
            /// Source frames per device frame at pitch 1.
            step: f64 = 1,
            /// The record gives a loop region (`mixing.md` §4.1).
            loops: bool = false,
        };

        /// What `play` would start, without starting it: loads the sound if need be.
        pub fn soundInfo(self: *Self, id: core.ContentId) PlayError!SoundInfo {
            const held = try self.assets.acquireOf(self.gpa, id, asset.schemas.sound.id);
            defer self.assets.release(held);
            const payload = self.assets.payloadOf(held) orelse return error.AssetNotFound;
            const stored = self.sounds.getConst(payload.asHandle(SoundHandle)) orelse return error.UnknownSound;
            const step = voice.stepFor(stored.sound.sample_rate, self.info.sample_rate, 1);
            const frames: f64 = @floatFromInt(stored.frameCount());
            return .{
                .frames = @intFromFloat(@ceil(frames / step)),
                .streamed = stored.compressed != null,
                .source_frames = stored.frameCount(),
                .step = step,
                .loops = stored.settings.loop_start != 0 or stored.settings.loop_end != 0,
            };
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
                if (event.kind == .tree) {
                    // The callback has let go of the tree before the one it installed.
                    if (self.retiring.orderedRemove(0)) |old| old.destroy();
                    continue;
                }
                const slot = &self.slots[event.slot];
                if (event.kind == .started) {
                    if (slot.playing and slot.generation == event.generation) slot.started_at = event.frame;
                    continue;
                }
                const retired = event;
                // A stolen voice's retirement: the callback has stopped reading it, so its
                // references go now (§7). Exactly once: a voice that ended by itself before its
                // steal arrived reports twice, and the second finds no zombie.
                if (slot.zombie) |z| if (z.generation == retired.generation) {
                    slot.zombie = null;
                    if (z.stream) |n| self.streams[n].retired = true;
                    if (z.fade) |n| self.fade_busy[n] = false;
                    if (self.sounds.get(z.sound)) |stored| {
                        stored.refs -= 1;
                        self.collect(z.sound, stored);
                    }
                    if (!z.held.isNone()) self.assets.release(z.held);
                    continue;
                };
                // A generation that has moved on means this slot was already reclaimed;
                // the retirement is for a voice two lives ago and is simply old news.
                if (!slot.playing or slot.generation != retired.generation) continue;

                slot.playing = false;
                const sound = slot.sound;
                const held = slot.held;
                slot.sound = .none;
                slot.held = .none;
                slot.started_at = null;
                slot.space = null;
                // Its stream is freed once its decode task, if one is in flight, is done too.
                if (slot.stream) |n| self.streams[n].retired = true;
                slot.stream = null;
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
            self.placeSpatial();
            self.pumpStreams();
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

            // With a bus tree, the buffer is mixed in blocks its buses can hold (§8).
            if (self.tree) |tree| {
                const ch = self.info.channels;
                var rest = out;
                while (rest.len > 0) {
                    const n = @min(rest.len / ch, tree.block) * ch;
                    self.mixTree(tree, rest[0..n]);
                    rest = rest[n..];
                }
                return;
            }

            // 2. Silence is zeroes. The buffer arrives holding whatever the driver last
            //    put there, so this is not an optimisation to skip when nothing plays.
            @memset(out, 0);

            // 3. Mix in slot index order — stable, documented, and the reason two runs of
            //    the stepped device produce identical samples (I9, `audio.md` §8).
            self.mixVoices(null, out);

            // 4. Master gain, then clamp. **The clamp is not a limiter and does not
            //    pretend to be**: it is here because an `f32` outside [-1, 1] handed to a
            //    driver that converts to `s16` without clamping *wraps*, and wrapping is
            //    the single worst sound a program can make. Twenty voices at full gain
            //    will clip; M31's limiter is an effect a game puts on its root bus.
            for (out) |*sample| {
                sample.* = std.math.clamp(sample.* * self.master_gain, -1.0, 1.0);
            }

            // 5. The clock moves by exactly this buffer, published last so a game that
            //    reads it sees every event this buffer pushed.
            self.mixed += out.len / self.info.channels;
            self.clock_frames.store(self.mixed, .release);
        }

        /// One block through the bus tree (§8.1): each voice into its bus's buffer, in slot
        /// order; each bus below the root, children before parents, through its gain into its
        /// parent; then the root's gain, the master gain and the clamp.
        fn mixTree(self: *Self, tree: *bus.Tree, out: []f32) void {
            const ch = self.info.channels;
            const frames = out.len / ch;
            @memset(out, 0);
            for (1..tree.count()) |k| @memset(tree.buffer(@intCast(k), frames), 0);
            self.mixVoices(tree, out);
            for (tree.order) |k| {
                const from = tree.buffer(k, frames);
                // Its effects, in order, before its gain (§8.1).
                for (tree.chain(k)) |*unit| unit.process(from, ch);
                const parent = tree.parents[k];
                const into = if (parent == 0) out else tree.buffer(parent, frames);
                for (0..frames) |f| {
                    const gain = tree.base[k] * tree.level[k].at(self.mixed + f);
                    for (0..ch) |c| into[f * ch + c] += from[f * ch + c] * gain;
                }
            }
            for (tree.chain(0)) |*unit| unit.process(out, ch);
            for (0..frames) |f| {
                const gain = tree.base[0] * tree.level[0].at(self.mixed + f) * self.master_gain;
                for (out[f * ch ..][0..ch]) |*sample| sample.* = std.math.clamp(sample.* * gain, -1.0, 1.0);
            }
            self.mixed += frames;
            self.clock_frames.store(self.mixed, .release);
        }

        /// Every active voice into `out`, or into its bus's buffer when there is a tree, in slot
        /// index order (I9).
        fn mixVoices(self: *Self, tree: ?*bus.Tree, out: []f32) void {
            const channels = self.info.channels;
            const frames: u64 = out.len / channels;
            for (self.voices, 0..) |*v, index| {
                if (!v.active) continue;
                const generation = v.generation;
                // A voice waits for the buffer that holds its start frame, and its first
                // sample lands on that frame rather than at the buffer's start.
                var offset: usize = 0;
                if (v.pending) {
                    if (v.wait_for_feed) {
                        // An unscheduled stream starts with its first frames, not before them.
                        if (v.feed.?.written.load(.acquire) < @min(2, v.frames)) continue;
                        v.wait_for_feed = false;
                        v.start_at = @max(v.start_at, self.mixed);
                    }
                    if (v.start_at >= self.mixed + frames) continue;
                    offset = @intCast(v.start_at - self.mixed);
                    v.pending = false;
                    self.report(.{ .kind = .started, .slot = @intCast(index), .generation = generation, .frame = v.start_at });
                }
                const target = if (tree) |t| (if (v.bus == 0 or v.bus >= t.count()) out else t.buffer(v.bus, @intCast(frames))) else out;
                const playing = v.mix(target[offset * channels ..], channels, self.mixed + offset);
                if (v.underran) {
                    v.underran = false;
                    _ = self.underrun_count.fetchAdd(1, .monotonic);
                }
                if (!playing) self.retire(v.owner orelse @as(u32, @intCast(index)), generation);
            }
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
                        .loop_start = p.loop_start,
                        .loop_end = p.loop_end,
                        .start = p.start,
                        .bus = p.bus,
                        .cursor = @floatFromInt(p.start),
                        .step = p.step,
                        .level = .hold(p.gain),
                        .envelope = .hold(p.envelope),
                        .left = p.left,
                        .right = p.right,
                        .looping = p.looping,
                        .pending = true,
                        .start_at = start,
                        .feed = p.feed,
                        .wait_for_feed = p.feed != null and p.start_at == null,
                    };
                    if (p.placed) |placed| {
                        const v = &self.voices[p.voice.index];
                        v.spatial = true;
                        v.left = placed.left;
                        v.right = placed.right;
                        v.space = placed.space;
                        v.lowpass = placed.lowpass;
                    }
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
                        self.retire(v.owner orelse @as(u32, @intCast(index)), v.generation);
                    }
                },
                .steal => |s| {
                    // A victim that already ended reported its own retirement when it did, and
                    // that releases the zombie: every voice that stops here reports, so a second
                    // report would only be ignored. One stopped below has not, so it does.
                    const v = self.liveVoice(s.victim) orelse return;
                    v.active = false;
                    const into = s.into orelse return self.retire(s.victim.index, s.victim.generation);
                    if (v.pending) return self.retire(s.victim.index, s.victim.generation);
                    const out = &self.voices[self.slots.len + into];
                    out.* = v.*;
                    out.active = true;
                    out.owner = s.victim.index;
                    out.envelope.start(.{ .begin = self.mixed, .frames = s.frames, .to = 0, .curve = .linear, .stop = true });
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
                    v.level.start(.{ .begin = @max(s.at orelse self.mixed, self.mixed), .frames = s.frames, .to = s.gain, .curve = .linear, .stop = false });
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
                .swap_mix => |tree| {
                    self.tree = tree;
                    for (self.voices, tree.voice_bus) |*v, b| v.bus = b;
                    self.report(.{ .kind = .tree, .slot = 0, .generation = 0 });
                },
                .bus_gain => |s| {
                    const tree = self.tree orelse return;
                    if (s.index >= tree.count()) return;
                    tree.level[s.index].start(.{ .begin = self.mixed, .frames = s.frames, .to = s.gain, .curve = .linear, .stop = false });
                },
                .bus_base => |s| {
                    const tree = self.tree orelse return;
                    if (s.index < tree.count()) tree.base[s.index] = s.gain;
                },
                .effect => |s| {
                    const tree = self.tree orelse return;
                    if (s.unit < tree.units.len) tree.units[s.unit].set(s.effect, s.frames);
                },
                .spatial => |s| {
                    const v = self.liveVoice(s.voice) orelse return;
                    v.glide = .{ .left = s.placed.left, .right = s.placed.right, .space = s.placed.space, .lowpass = s.placed.lowpass };
                },
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
    // Nothing of its priority or lower to take: since M31 an equal priority may be stolen
    // (`mixing.md` §7), so the refusal is shown one below it.
    try testing.expectError(error.NoFreeVoice, f.mixer.playSound(sound, .{ .priority = 127 }));

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

// -- streams ------------------------------------------------------------------------

fn oggFixture(comptime name: []const u8) []const u8 {
    for (asset.ogg.fixtures) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.ogg;
    }
    @compileError("no fixture " ++ name);
}

/// The same file, resident and streamed, each in a mixer of its own.
const Pair = struct {
    resident: *Fixture,
    streamed: *Fixture,
    resident_sound: SoundHandle,
    streamed_sound: SoundHandle,

    fn init(bytes: []const u8, options: Options) !Pair {
        return initWith(bytes, options, .{});
    }

    /// Both sides given the same mixing settings, as one `foundry:sound` record would.
    fn initWith(bytes: []const u8, options: Options, settings: asset.mix.SoundSettings) !Pair {
        const resident = try Fixture.init(testing.allocator, options);
        errdefer resident.deinit();
        const streamed = try Fixture.init(testing.allocator, options);
        errdefer streamed.deinit();
        const decoded = try asset.vorbis.decode(testing.allocator, bytes, .{});
        return .{
            .resident = resident,
            .streamed = streamed,
            .resident_sound = try resident.mixer.insertSoundWith(decoded, settings),
            .streamed_sound = try streamed.mixer.insertStreamedWith(bytes, settings),
        };
    }

    fn deinit(self: Pair) void {
        self.streamed.deinit();
        self.resident.deinit();
    }

    fn play(self: Pair, params: PlayParams) ![2]VoiceHandle {
        return .{ try self.resident.mixer.playSound(self.resident_sound, params), try self.streamed.mixer.playSound(self.streamed_sound, params) };
    }

    /// One buffer from each, after each mixer's `update`; they must be identical.
    fn stepBoth(self: Pair, frames: u32) !void {
        self.resident.mixer.update();
        self.streamed.mixer.update();
        const expected = try testing.allocator.dupe(f32, try self.resident.step(frames));
        defer testing.allocator.free(expected);
        try testing.expectEqualSlices(f32, expected, try self.streamed.step(frames));
    }
};

test "a streamed voice equals its resident decode, sample for sample, across three loop seams" {
    // Same rate as the device, and a rate the voice resamples, so the seam is read across
    // the next pass's first frame by interpolation as well as directly.
    const cases = [_]struct { bytes: []const u8, frames: u64 }{
        .{ .bytes = comptime oggFixture("short"), .frames = 300 },
        .{ .bytes = comptime oggFixture("mono44_q0"), .frames = 66_150 * 48_000 / 44_100 },
    };
    for (cases) |case| {
        const pair = try Pair.init(case.bytes, .{ .buffer_frames = 512 });
        defer pair.deinit();
        _ = try pair.play(.{ .looping = true, .pan = 0.3 });
        var mixed: u64 = 0;
        while (mixed < case.frames * 7 / 2) : (mixed += 512) try pair.stepBoth(512);
        try testing.expectEqual(@as(u32, 0), pair.streamed.mixer.underruns());
        try testing.expectEqual(@as(u32, 1), pair.streamed.mixer.activeVoices());
    }

    // And a one-shot ends in the same buffer, retires, and gives its stream back.
    const pair = try Pair.init(comptime oggFixture("short"), .{ .buffer_frames = 128 });
    defer pair.deinit();
    _ = try pair.play(.{});
    for (0..4) |_| try pair.stepBoth(128);
    pair.streamed.mixer.update();
    try testing.expectEqual(@as(u32, 0), pair.streamed.mixer.activeVoices());
    try testing.expectEqual(@as(u32, 0), pair.streamed.mixer.streamsInUse());
}

test "with tasks held back, an underrun is silent, counted, keeps the timeline, and recovers on time" {
    var manual = try core.tasks.Manual.init(testing.allocator, 4);
    defer manual.deinit();
    const pair = try Pair.init(comptime oggFixture("stereo48_q4"), .{ .buffer_frames = 256 });
    defer pair.deinit();
    const held = try Fixture.init(testing.allocator, .{ .buffer_frames = 256, .tasks = manual.tasks() });
    defer held.deinit();
    const sound = try held.mixer.insertStreamed(comptime oggFixture("stereo48_q4"));

    // Scheduled at frame 0 in all three, so the timeline is the thing compared.
    _ = try pair.resident.mixer.playSound(pair.resident_sound, .{ .start_at = 0 });
    _ = try held.mixer.playSound(sound, .{ .start_at = 0 });
    try testing.expectEqual(@as(u32, 1), manual.pending());
    for (0..4) |_| {
        _ = try pair.resident.step(256);
        held.mixer.update();
        try expectAllZero(try held.step(256));
    }
    // One per buffer that missed frames, and the decode is still the one task in flight.
    try testing.expectEqual(@as(u32, 4), held.mixer.underruns());
    try testing.expectEqual(@as(u32, 1), manual.pending());

    // The frames arrive late: the four buffers missed are thrown away, and the fifth is the
    // track's fifth buffer, not its first.
    manual.runAll();
    held.mixer.update();
    const expected = try testing.allocator.dupe(f32, try pair.resident.step(256));
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(f32, expected, try held.step(256));
    try testing.expectEqual(@as(u32, 4), held.mixer.underruns());
    manual.runAll();
}

test "an unscheduled streamed start waits for its first frames instead of underrunning" {
    var manual = try core.tasks.Manual.init(testing.allocator, 4);
    defer manual.deinit();
    const f = try Fixture.init(testing.allocator, .{ .buffer_frames = 64, .tasks = manual.tasks() });
    defer f.deinit();
    const resident = try Fixture.init(testing.allocator, .{ .buffer_frames = 64 });
    defer resident.deinit();
    const bytes = comptime oggFixture("short");
    const decoded = try asset.vorbis.decode(testing.allocator, bytes, .{});
    const reference = try resident.mixer.insertSound(decoded);
    const sound = try f.mixer.insertStreamed(bytes);

    const v = try f.mixer.playSound(sound, .{});
    try expectAllZero(try f.step(64));
    try expectAllZero(try f.step(64));
    f.mixer.update();
    try testing.expectEqual(@as(?u64, null), f.mixer.startedAt(v));
    try testing.expectEqual(@as(u32, 0), f.mixer.underruns());

    manual.runAll();
    _ = try resident.mixer.playSound(reference, .{});
    const expected = try testing.allocator.dupe(f32, try resident.step(64));
    defer testing.allocator.free(expected);
    try testing.expectEqualSlices(f32, expected, try f.step(64));
    f.mixer.update();
    try testing.expectEqual(@as(?u64, 128), f.mixer.startedAt(v));
    try testing.expectEqual(@as(u32, 0), f.mixer.underruns());
    manual.runAll();
}

test "a stopped stream, and its released sound, are freed only once its decode task is done" {
    var manual = try core.tasks.Manual.init(testing.allocator, 4);
    defer manual.deinit();
    const f = try Fixture.init(testing.allocator, .{ .buffer_frames = 64, .tasks = manual.tasks() });
    defer f.deinit();
    const sound = try f.mixer.insertStreamed(comptime oggFixture("short"));

    const v = try f.mixer.playSound(sound, .{ .start_at = 0 });
    f.mixer.stop(v);
    // A hot reload's half: the sound is given up while its stream still reads it.
    f.mixer.releaseSound(sound);
    _ = try f.step(64);
    f.mixer.update();
    try testing.expect(!f.mixer.isPlaying(v));
    // The voice has gone, but the task still holds the decoder and the bytes.
    try testing.expectEqual(@as(u32, 1), f.mixer.streamsInUse());
    try testing.expectEqual(@as(u32, 1), f.mixer.soundCount());
    f.mixer.update();
    try testing.expectEqual(@as(u32, 1), f.mixer.streamsInUse());

    manual.runAll();
    f.mixer.update();
    try testing.expectEqual(@as(u32, 0), f.mixer.streamsInUse());
    try testing.expectEqual(@as(u32, 0), f.mixer.soundCount());
}

test "a streamed sound released while it plays keeps playing, and is freed after it" {
    const pair = try Pair.init(comptime oggFixture("short"), .{ .buffer_frames = 100 });
    defer pair.deinit();
    _ = try pair.play(.{});
    try pair.stepBoth(100);
    pair.resident.mixer.releaseSound(pair.resident_sound);
    pair.streamed.mixer.releaseSound(pair.streamed_sound);
    try testing.expectEqual(@as(u32, 1), pair.streamed.mixer.soundCount());
    for (0..3) |_| try pair.stepBoth(100);
    pair.streamed.mixer.update();
    try testing.expectEqual(@as(u32, 0), pair.streamed.mixer.soundCount());
    try testing.expectError(error.UnknownSound, pair.streamed.mixer.playSound(pair.streamed_sound, .{}));
}

test "past the stream table, a streamed play is refused, and nothing is left claimed" {
    const f = try Fixture.init(testing.allocator, .{ .buffer_frames = 64, .streams = 1 });
    defer f.deinit();
    const sound = try f.mixer.insertStreamed(comptime oggFixture("short"));
    const resident = try f.add(&[_]f32{0.5}, 1, 48_000);

    const first = try f.mixer.playSound(sound, .{ .looping = true });
    try testing.expectError(error.NoFreeStream, f.mixer.playSound(sound, .{}));
    try testing.expectEqual(@as(u32, 1), f.mixer.activeVoices());
    // A resident sound needs no stream.
    _ = try f.mixer.playSound(resident, .{});

    f.mixer.stop(first);
    _ = try f.step(64);
    f.mixer.update();
    try testing.expectEqual(@as(u32, 0), f.mixer.streamsInUse());
    _ = try f.mixer.playSound(sound, .{});
    try testing.expectEqual(@as(u32, 1), f.mixer.streamsInUse());
}

test "shutdown waits for a decode task in flight before it frees the stream" {
    var manual = try core.tasks.Manual.init(testing.allocator, 4);
    defer manual.deinit();
    const f = try Fixture.init(testing.allocator, .{ .buffer_frames = 64, .tasks = manual.tasks() });
    defer f.deinit();
    const sound = try f.mixer.insertStreamed(comptime oggFixture("short"));
    _ = try f.mixer.playSound(sound, .{ .looping = true });
    try testing.expectEqual(@as(u32, 1), manual.pending());
    f.mixer.shutdown();
    try testing.expectEqual(@as(u32, 0), manual.pending());
    try testing.expectEqual(@as(u32, 0), f.mixer.streamsInUse());
}

test "a streamed sound is proved whole when it is added: one that would fail partway is refused then" {
    const f = try Fixture.init(testing.allocator, .{ .buffer_frames = 64 });
    defer f.deinit();
    // The last page claims a thousand frames more than the packets hold. The headers and the
    // container are sound, so only decoding every packet finds it.
    const bytes = try testing.allocator.dupe(u8, comptime oggFixture("short"));
    defer testing.allocator.free(bytes);
    const last = std.mem.lastIndexOf(u8, bytes, "OggS").?;
    const page = bytes[last..];
    const granule = std.mem.readInt(u64, page[6..14], .little);
    std.mem.writeInt(u64, page[6..14], granule + 1000, .little);
    std.mem.writeInt(u32, page[22..26], 0, .little);
    std.mem.writeInt(u32, page[22..26], asset.ogg.crc32(page), .little);

    try testing.expectError(error.InvalidSound, f.mixer.insertStreamed(bytes));
    try testing.expectEqual(@as(u32, 0), f.mixer.soundCount());
}

test "fadeGainAt begins the level's ramp on its frame, and a frame already past at the next callback" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4 });
    defer f.deinit();
    const sound = try f.add(&[_]f32{1.0}, 1, 48_000);
    const v = try f.mixer.playSound(sound, .{ .looping = true });

    // From frame 6, over 4 frames, to 0: a duck landing mid-buffer.
    f.mixer.fadeGainAt(v, 6, 0, 4);
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 1, 1, 1 }, try f.step(4));
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 1, 1, 0.75 }, try f.step(4));
    try testing.expectEqualSlices(f32, &[_]f32{ 0.5, 0.25, 0, 0 }, try f.step(4));

    // Frame 2 has gone: the ramp back up begins at the next callback, frame 12.
    f.mixer.fadeGainAt(v, 2, 1, 4);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0.25, 0.5, 0.75 }, try f.step(4));
}

// -- M31 Step 3: start offsets and loop regions (`mixing.md` §6.2, §6.3) -------------------

/// A mono ramp whose sample `i` is `i`, so a voice's output names the frames it read.
fn rampSound(gpa: Allocator, frames: usize) !asset.Sound {
    const sound = try asset.Sound.alloc(gpa, frames, 1, 48_000);
    for (sound.samples, 0..) |*s, i| s.* = @floatFromInt(i);
    return sound;
}

fn expectFrames(f: *Fixture, expected: []const f32) !void {
    f.mixer.update();
    const out = try f.step(@intCast(expected.len));
    for (expected, out) |e, o| try testing.expectEqual(e / 256, o);
}

test "a loop region plays its intro once and then its region, and a one-shot ignores it" {
    // Gain 1/256 keeps the ramp's values inside the clamp, and exact in f32.
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 64 });
    defer f.deinit();
    const sound = try f.mixer.insertSoundWith(try rampSound(testing.allocator, 200), .{ .loop_start = 100, .loop_end = 164 });
    _ = try f.mixer.playSound(sound, .{ .looping = true, .gain = 1.0 / 256.0 });
    var expected: [64]f32 = undefined;
    // The intro: 0 to 163, across three buffers, then the region again and again.
    var frame: u64 = 0;
    for (0..8) |_| {
        for (&expected) |*e| {
            const source = if (frame < 164) frame else 100 + (frame - 164) % 64;
            e.* = @floatFromInt(source);
            frame += 1;
        }
        try expectFrames(f, &expected);
    }
    // Played once, the same sound runs to its own end and stops.
    const g = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 200 });
    defer g.deinit();
    const once = try g.mixer.insertSoundWith(try rampSound(testing.allocator, 200), .{ .loop_start = 100, .loop_end = 164 });
    _ = try g.mixer.playSound(once, .{ .gain = 1.0 / 256.0 });
    var whole: [200]f32 = undefined;
    for (&whole, 0..) |*e, i| e.* = @floatFromInt(i);
    try expectFrames(g, &whole);
    g.mixer.update();
    try testing.expectEqual(@as(u32, 0), g.mixer.activeVoices());
}

test "a start offset begins part-way, and a loop started past its region's end folds into it" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 4 });
    defer f.deinit();
    const sound = try f.mixer.insertSoundWith(try rampSound(testing.allocator, 200), .{ .loop_start = 100, .loop_end = 164 });
    const v = try f.mixer.playSound(sound, .{ .gain = 1.0 / 256.0, .start_frame = 30 });
    try expectFrames(f, &.{ 30, 31, 32, 33 });
    f.mixer.stop(v);
    // 190 is past 164: (190 − 100) mod 64 = 26 frames into the region.
    _ = try f.mixer.playSound(sound, .{ .looping = true, .gain = 1.0 / 256.0, .start_frame = 190 });
    try expectFrames(f, &.{ 126, 127, 128, 129 });

    // At or past the end is the caller's arithmetic, refused by name, and nothing is claimed.
    try testing.expectError(error.InvalidStart, f.mixer.playSound(sound, .{ .start_frame = 200 }));
    try testing.expectError(error.InvalidStart, f.mixer.playSound(sound, .{ .start_frame = std.math.maxInt(u64) }));
    f.mixer.stopAll();
    f.mixer.update();
    _ = try f.step(4);
    f.mixer.update();
    try testing.expectEqual(@as(u32, 0), f.mixer.activeVoices());
}

test "a loop region that does not fit is refused, and the defaults are the whole file" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1 });
    defer f.deinit();
    var sound = try rampSound(testing.allocator, 200);
    defer sound.deinit(testing.allocator);
    try testing.expectError(error.LoopPastEnd, f.mixer.insertSoundWith(sound, .{ .loop_start = 0, .loop_end = 201 }));
    try testing.expectError(error.InvalidLoop, f.mixer.insertSoundWith(sound, .{ .loop_start = 200 }));
    try testing.expectError(error.LoopTooShort, f.mixer.insertSoundWith(sound, .{ .loop_start = 150, .loop_end = 180 }));
    try testing.expectError(error.LoopPastEnd, f.mixer.insertStreamedWith(comptime oggFixture("short"), .{ .loop_end = 1_000_000 }));
}

test "a streamed voice with a loop region or a start equals its resident decode, across three seams" {
    // Each case played on a resident and a streamed copy; every buffer must be identical.
    // Rates the voice copies and rates it resamples, so seams are read by interpolation too.
    const Case = struct { bytes: []const u8, settings: asset.mix.SoundSettings, params: PlayParams, frames: u64 };
    const cases = [_]Case{
        // A region inside a short file, from the start.
        .{ .bytes = comptime oggFixture("short"), .settings = .{ .loop_start = 64, .loop_end = 250 }, .params = .{ .looping = true }, .frames = 64 + 186 * 4 },
        // An intro, then a region ending at the file's end, begun part-way through the intro.
        .{ .bytes = comptime oggFixture("mono44_q0"), .settings = .{ .loop_start = 20_000 }, .params = .{ .looping = true, .pan = -0.4, .start_frame = 9_000 }, .frames = 66_150 * 4 * 48_000 / 44_100 },
        // A region in the middle, begun inside it.
        .{ .bytes = comptime oggFixture("stereo48_q4"), .settings = .{ .loop_start = 30_000, .loop_end = 50_000 }, .params = .{ .looping = true, .start_frame = 41_000 }, .frames = 20_000 * 4 },
        // A start past the region's end, folded into it.
        .{ .bytes = comptime oggFixture("stereo48_q4"), .settings = .{ .loop_start = 30_000, .loop_end = 50_000 }, .params = .{ .looping = true, .start_frame = 70_000 }, .frames = 20_000 * 4 },
        // A one-shot begun part-way, to its end.
        .{ .bytes = comptime oggFixture("stereo22_qm1"), .settings = .{}, .params = .{ .start_frame = 5_000 }, .frames = 0 },
    };
    for (cases) |case| {
        const pair = try Pair.initWith(case.bytes, .{ .buffer_frames = 512 }, case.settings);
        defer pair.deinit();
        _ = try pair.play(case.params);
        var mixed: u64 = 0;
        const until = if (case.frames == 0) 200_000 else case.frames;
        while (mixed < until) : (mixed += 512) try pair.stepBoth(512);
        try testing.expectEqual(@as(u32, 0), pair.streamed.mixer.underruns());
        pair.streamed.mixer.update();
        pair.resident.mixer.update();
        try testing.expectEqual(pair.resident.mixer.activeVoices(), pair.streamed.mixer.activeVoices());
        try testing.expectEqual(@as(u32, if (case.params.looping) 1 else 0), pair.streamed.mixer.activeVoices());
    }
}

// -- M31 Step 4: spatial voices (`mixing.md` §5) ------------------------------------------

fn dcSound(f: *Fixture, frames: usize, channels: u8, values: []const f32) !SoundHandle {
    const sound = try asset.Sound.alloc(testing.allocator, frames, channels, 48_000);
    for (0..frames) |i| for (0..channels) |c| {
        sound.samples[i * channels + c] = values[c];
    };
    return f.mixer.insertSound(sound);
}

test "a spatial voice is placed against the listener from its first buffer" {
    const f = try Fixture.init(testing.allocator, .{ .buffer_frames = 64 });
    defer f.deinit();
    const sound = try dcSound(f, 4096, 1, &.{0.5});
    const at: core.math.Vec3 = .init(3, 0, -4);
    _ = try f.mixer.playSound(sound, .{ .looping = true, .position = at, .pan = -1 });
    const expected = spatial.place(.{}, at, .{}, 0, 48_000);
    f.mixer.update();
    const out = try f.step(64);
    // No glide into the first buffer: every frame is already where the source is, and the
    // `pan` it was played with is ignored.
    for (0..64) |i| {
        try testing.expectEqual(0.5 * expected.left * expected.space, out[i * 2]);
        try testing.expectEqual(0.5 * expected.right * expected.space, out[i * 2 + 1]);
    }
    try testing.expect(expected.right > expected.left);
}

test "a moving source glides across each buffer, with no step at a buffer's edge" {
    const f = try Fixture.init(testing.allocator, .{ .buffer_frames = 128 });
    defer f.deinit();
    const sound = try dcSound(f, 48_000, 1, &.{1.0});
    var x: f32 = -6;
    const v = try f.mixer.playSound(sound, .{ .looping = true, .position = .init(x, 0, -1) });
    var previous: [2]f32 = undefined;
    var first = true;
    for (0..60) |_| {
        const before = spatial.place(f.mixer.listener, .init(x, 0, -1), .{}, 0, 48_000);
        x += 0.2;
        try testing.expect(f.mixer.setPositionChecked(v, .init(x, 0, -1)));
        f.mixer.update();
        const after = spatial.place(f.mixer.listener, .init(x, 0, -1), .{}, 0, 48_000);
        const out = try f.step(128);
        // The buffer ends exactly on the new placement.
        try testing.expectApproxEqAbs(after.left * after.space, out[127 * 2], 1e-6);
        try testing.expectApproxEqAbs(after.right * after.space, out[127 * 2 + 1], 1e-6);
        // No frame moves further than an even share of the change, at the edge or inside. Each
        // output is a pan gain times the space gain, each gliding linearly, so a frame's step is
        // bounded by the two changes' shares together (every gain is at most 1).
        const step_l = (@abs(after.left - before.left) + @abs(after.space - before.space)) / 128 + 1e-6;
        const step_r = (@abs(after.right - before.right) + @abs(after.space - before.space)) / 128 + 1e-6;
        for (0..128) |i| {
            const l = out[i * 2];
            const r = out[i * 2 + 1];
            if (!first) {
                try testing.expect(@abs(l - previous[0]) <= step_l);
                try testing.expect(@abs(r - previous[1]) <= step_r);
            }
            first = false;
            previous = .{ l, r };
        }
    }
}

test "a stereo source is summed to mono, and a mono device hears only the space gain" {
    const f = try Fixture.init(testing.allocator, .{ .buffer_frames = 16 });
    defer f.deinit();
    const sound = try dcSound(f, 1000, 2, &.{ 0.8, 0.2 });
    _ = try f.mixer.playSound(sound, .{ .position = .init(0, 0, -0.5) });
    f.mixer.update();
    const out = try f.step(16);
    const p = spatial.place(.{}, .init(0, 0, -0.5), .{}, 0, 48_000);
    try testing.expectApproxEqAbs(0.5 * p.left, out[0], 1e-7);
    try testing.expectApproxEqAbs(0.5 * p.right, out[1], 1e-7);
    try testing.expectEqual(out[0], out[1]);

    const g = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 16 });
    defer g.deinit();
    const mono = try dcSound(g, 1000, 1, &.{0.5});
    _ = try g.mixer.playSound(mono, .{ .position = .init(6, 0, 0) });
    g.mixer.update();
    const heard = try g.step(16);
    try testing.expectEqual(0.5 * spatial.distanceGain(.{}, 6), heard[0]);
}

test "occlusion muffles: the low-pass passes a steady level and stops the highest frequency" {
    const f = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 256 });
    defer f.deinit();
    // The device's Nyquist frequency: +0.5, −0.5, ...
    const sound = try asset.Sound.alloc(testing.allocator, 4096, 1, 48_000);
    for (sound.samples, 0..) |*s, i| s.* = if (i % 2 == 0) 0.5 else -0.5;
    const nyquist = try f.mixer.insertSound(sound);
    const v = try f.mixer.playSound(nyquist, .{ .looping = true, .position = .init(0, 0, -0.5) });
    f.mixer.update();
    // Open: no filter at all, the samples exactly.
    const open = try f.step(256);
    for (open, 0..) |s, i| try testing.expectEqual(@as(f32, if (i % 2 == 0) 0.5 else -0.5), s);
    try testing.expect(f.mixer.setOcclusionChecked(v, 1));
    f.mixer.update();
    _ = try f.step(256);
    f.mixer.update();
    const shut = try f.step(256);
    var peak: f32 = 0;
    for (shut) |s| peak = @max(peak, @abs(s));
    // A 1,200 Hz one-pole holds the Nyquist frequency to a few percent, under half the gain.
    try testing.expect(peak < 0.5 * 0.5 * 0.1);

    // A steady level passes the filter, at the occluded gain.
    const g = try Fixture.init(testing.allocator, .{ .channels = 1, .buffer_frames = 256 });
    defer g.deinit();
    const dc = try dcSound(g, 48_000, 1, &.{0.5});
    const w = try g.mixer.playSound(dc, .{ .looping = true, .position = .init(0, 0, -0.5) });
    try testing.expect(g.mixer.setOcclusionChecked(w, 1));
    for (0..8) |_| {
        g.mixer.update();
        _ = try g.step(256);
    }
    g.mixer.update();
    const settled = try g.step(256);
    try testing.expectApproxEqAbs(@as(f32, 0.25), settled[255], 1e-4);
}

test "spatial refusals: not finite, not spatial, not playing, no such attenuation, and pan" {
    const f = try Fixture.init(testing.allocator, .{});
    defer f.deinit();
    const sound = try dcSound(f, 1000, 1, &.{0.5});
    const nan = std.math.nan(f32);
    try testing.expectError(error.InvalidPosition, f.mixer.playSound(sound, .{ .position = .init(nan, 0, 0) }));
    try testing.expectError(error.UnknownAttenuation, f.mixer.playSound(sound, .{ .position = .zero, .attenuation = core.ContentId.fromString("t:nowhere") }));
    try testing.expectEqual(@as(u32, 0), f.mixer.activeVoices());

    const placed = try f.mixer.playSound(sound, .{ .looping = true, .position = .zero });
    const plain = try f.mixer.playSound(sound, .{ .looping = true });
    try testing.expect(!f.mixer.setPositionChecked(placed, .init(0, nan, 0)));
    try testing.expect(!f.mixer.setOcclusionChecked(placed, std.math.inf(f32)));
    try testing.expect(!f.mixer.setPositionChecked(plain, .zero));
    try testing.expect(!f.mixer.setOcclusionChecked(plain, 0.5));
    try testing.expect(!f.mixer.setPositionChecked(.none, .zero));
    // A spatial voice's position decides its pan; a plain voice's pan still applies.
    try testing.expect(!f.mixer.setPanChecked(placed, 1));
    try testing.expect(f.mixer.setPanChecked(plain, 1));

    // A listener that cannot be heard from is refused, and the previous one kept.
    try testing.expect(f.mixer.setListenerChecked(.{ .position = .init(1, 2, 3) }));
    try testing.expect(!f.mixer.setListenerChecked(.{ .forward = .up }));
    try testing.expect(!f.mixer.setListenerChecked(.{ .position = .init(nan, 0, 0) }));
    try testing.expectEqual(@as(f32, 2), f.mixer.listener.position.y);
}

// -- M31 Step 5: voice stealing (`mixing.md` §7) ------------------------------------------

test "stealing takes the lowest priority, then the quietest, then the oldest, and never a higher one" {
    const Case = struct {
        /// Each playing voice's priority, gain and whether it is placed past its far distance.
        voices: []const struct { priority: u8, gain: f32 = 1, far: bool = false },
        new: u8,
        /// The voice expected to go, or null for `NoFreeVoice`.
        victim: ?usize,
    };
    const cases = [_]Case{
        .{ .voices = &.{ .{ .priority = 50 }, .{ .priority = 10, .gain = 1 }, .{ .priority = 50, .gain = 0.01 } }, .new = 100, .victim = 1 },
        .{ .voices = &.{ .{ .priority = 50, .gain = 0.5 }, .{ .priority = 50, .gain = 0.2 }, .{ .priority = 50, .gain = 0.9 } }, .new = 50, .victim = 1 },
        .{ .voices = &.{ .{ .priority = 50 }, .{ .priority = 50 }, .{ .priority = 50 } }, .new = 60, .victim = 0 },
        .{ .voices = &.{ .{ .priority = 50, .gain = 0.1 }, .{ .priority = 50, .far = true }, .{ .priority = 50 } }, .new = 50, .victim = 1 },
        .{ .voices = &.{ .{ .priority = 200 }, .{ .priority = 201 }, .{ .priority = 255 } }, .new = 199, .victim = null },
    };
    for (cases) |case| {
        const f = try Fixture.init(testing.allocator, .{ .voices = @intCast(case.voices.len) });
        defer f.deinit();
        const sound = try dcSound(f, 4096, 1, &.{0.1});
        var handles: [3]VoiceHandle = undefined;
        for (case.voices, 0..) |v, i| {
            handles[i] = try f.mixer.playSound(sound, .{
                .looping = true,
                .gain = v.gain,
                .priority = v.priority,
                .position = if (v.far) core.math.Vec3.init(100, 0, 0) else null,
            });
        }
        const result = f.mixer.playSound(sound, .{ .priority = case.new });
        if (case.victim) |want| {
            _ = try result;
            for (handles[0..case.voices.len], 0..) |h, i| try testing.expectEqual(i != want, f.mixer.isPlaying(h));
            try testing.expectEqual(@as(u32, 1), f.mixer.stolen());
        } else {
            try testing.expectError(error.NoFreeVoice, result);
            for (handles[0..case.voices.len]) |h| try testing.expect(f.mixer.isPlaying(h));
            try testing.expectEqual(@as(u32, 0), f.mixer.stolen());
        }
    }
}

test "a stolen voice fades to silence over exactly its fade, and its references go after it" {
    const f = try Fixture.init(testing.allocator, .{ .voices = 1, .channels = 1, .buffer_frames = 512, .steal_fade_frames = 256 });
    defer f.deinit();
    const loud = try dcSound(f, 48_000, 1, &.{0.5});
    const quiet = try dcSound(f, 48_000, 1, &.{0.0});
    _ = try f.mixer.playSound(loud, .{ .looping = true });
    f.mixer.update();
    _ = try f.step(512);
    _ = try f.mixer.playSound(quiet, .{ .looping = true });
    try testing.expectEqual(@as(u32, 1), f.mixer.stolen());
    try testing.expectEqual(@as(u32, 0), f.mixer.cutSteals());
    f.mixer.update();
    const out = try f.step(512);
    for (0..256) |i| try testing.expectEqual(0.5 * (1 - @as(f32, @floatFromInt(i)) / 256), out[i]);
    for (out[256..]) |s| try testing.expectEqual(@as(f32, 0), s);
    // The fade retired on its last frame; its sound is held until `update` hears it.
    try testing.expect(f.mixer.fade_busy[0]);
    f.mixer.releaseSound(loud);
    try testing.expectEqual(@as(u32, 2), f.mixer.soundCount());
    f.mixer.update();
    try testing.expect(!f.mixer.fade_busy[0]);
    try testing.expectEqual(@as(u32, 1), f.mixer.soundCount());
}

test "with every fade voice busy a steal cuts, and a victim that already ended is released once" {
    const f = try Fixture.init(testing.allocator, .{ .voices = 1, .channels = 1, .buffer_frames = 64, .fade_slots = 0 });
    defer f.deinit();
    const loud = try dcSound(f, 48_000, 1, &.{0.5});
    const quiet = try dcSound(f, 48_000, 1, &.{0.0});
    _ = try f.mixer.playSound(loud, .{ .looping = true });
    f.mixer.update();
    _ = try f.step(64);
    _ = try f.mixer.playSound(quiet, .{ .looping = true });
    try testing.expectEqual(@as(u32, 1), f.mixer.cutSteals());
    f.mixer.update();
    for (try f.step(64)) |s| try testing.expectEqual(@as(f32, 0), s);
    f.mixer.update();
    f.mixer.stopAll();
    f.mixer.update();
    _ = try f.step(64);
    f.mixer.update();

    // A one-shot that ends in the callback, stolen before `update` has heard: its own
    // retirement and the steal's both arrive, and its references are released exactly once.
    const blip = try dcSound(f, 32, 1, &.{0.5});
    _ = try f.mixer.playSound(blip, .{});
    f.mixer.update();
    _ = try f.step(64);
    _ = try f.mixer.playSound(quiet, .{ .looping = true });
    f.mixer.releaseSound(blip);
    _ = try f.step(64);
    f.mixer.update();
    try testing.expectEqual(@as(u32, 2), f.mixer.soundCount());
    // And one stolen while still waiting for its scheduled start never sounds at all.
    f.mixer.stopAll();
    f.mixer.update();
    _ = try f.step(64);
    f.mixer.update();
    _ = try f.mixer.playSound(loud, .{ .start_at = f.mixer.clock() + 10_000 });
    _ = try f.mixer.playSound(quiet, .{});
    f.mixer.update();
    for (try f.step(64)) |s| try testing.expectEqual(@as(f32, 0), s);
}

test "a stolen streamed voice keeps its stream through the fade, then gives it back" {
    const f = try Fixture.init(testing.allocator, .{ .voices = 1, .buffer_frames = 256 });
    defer f.deinit();
    const music = try f.mixer.insertStreamed(comptime oggFixture("stereo48_q4"));
    const quiet = try dcSound(f, 48_000, 1, &.{0.0});
    _ = try f.mixer.playSound(music, .{ .looping = true });
    f.mixer.update();
    _ = try f.step(256);
    _ = try f.mixer.playSound(quiet, .{ .looping = true });
    f.mixer.update();
    try testing.expectEqual(@as(u32, 1), f.mixer.streamsInUse());
    const out = try f.step(256);
    // The fade is the stream's frames, under a falling envelope: not silence.
    var heard = false;
    for (out[0..64]) |s| heard = heard or s != 0;
    try testing.expect(heard);
    try testing.expectEqual(@as(u32, 1), f.mixer.streamsInUse());
    // The fade ends on frame 256, the first of the next buffer, where it retires.
    f.mixer.update();
    _ = try f.step(256);
    f.mixer.update();
    try testing.expectEqual(@as(u32, 0), f.mixer.streamsInUse());
    try testing.expectEqual(@as(u32, 0), f.mixer.underruns());
}
