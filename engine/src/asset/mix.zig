//! How a game is mixed, as content: `foundry:audio_bus`, the five effect records,
//! `foundry:audio_attenuation`, and what `foundry:sound` version 3 says about mixing
//! (`docs/design/mixing.md` §4, ADR-0067, ADR-0068).
//!
//! ```fdt
//! foundry:audio_bus court:bus.world {
//!     parent  court:bus.master
//!     effects [ court:fx.courtyard  court:fx.world_glue ]
//! }
//! foundry:audio_reverb court:fx.courtyard {
//!     decay 1.4
//!     wet   0.18
//! }
//! foundry:audio_attenuation court:attenuation.warden {
//!     max_distance 18
//! }
//! ```
//!
//! **Mechanism, not content** (I5): the record types are the engine's, registered through the
//! call a mod's `@schema` uses (I6). Which buses exist and what they carry is a game's, in its
//! own package, where a later package may add a bus with one record or override any one whole.
//!
//! **One schema per effect.** Each field carries its own range, `fpack` refuses a reverb with
//! a `ratio`, and the editor shows only the fields that apply. The set is fixed engine code,
//! because effects run on the device thread where a mod's fault could not be contained
//! (`audio.md` §10).
//!
//! **They live here, not beside the mixer**, for `particle_emitter`'s reason: `fpack` and the
//! editor check a record with no mixer linked. `audio` reads the values this decodes.
//!
//! **Every name here is on authors' disks** (CLAUDE.md §7). Adding a field later is additive;
//! renaming one is a break.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Fields = data.fpk.Fields;
const Registry = data.Registry;
const Schema = data.Schema;
const SchemaId = data.SchemaId;

pub const bus_name = "foundry:audio_bus";
pub const attenuation_name = "foundry:audio_attenuation";
pub const filter_name = "foundry:audio_filter";
pub const delay_name = "foundry:audio_delay";
pub const reverb_name = "foundry:audio_reverb";
pub const compressor_name = "foundry:audio_compressor";
pub const limiter_name = "foundry:audio_limiter";

/// Effects one bus may run, in order.
pub const max_effects: usize = 8;
pub const max_bus_gain: f32 = 4;
/// Priorities are a byte's worth, so a `u32` field above this is a typo, not a priority.
pub const max_priority: u32 = 255;
/// A loop region shorter than this would click on every pass, and is refused.
pub const min_loop_frames: u64 = 64;
/// Ten kilometres: an attenuation reaching further is a unit mistake.
pub const max_distance_limit: f32 = 10_000;

/// Version 1.
pub const bus: Schema = .{
    .id = SchemaId.fromStringUnchecked(bus_name),
    .version = 1,
    .fields = &.{
        .{ .name = "parent", .type = .id, .presence = .optional },
        .{ .name = "gain", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
        .{ .name = "effects", .type = .{ .list = &.id }, .presence = .optional },
    },
};

/// Version 1.
pub const attenuation: Schema = .{
    .id = SchemaId.fromStringUnchecked(attenuation_name),
    .version = 1,
    .fields = &.{
        .{ .name = "model", .type = .string, .presence = .{ .default = .{ .string = "inverse" } } },
        .{ .name = "min_distance", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
        .{ .name = "max_distance", .type = .f32, .presence = .{ .default = .{ .float = 30 } } },
        .{ .name = "occluded_gain", .type = .f32, .presence = .{ .default = .{ .float = 0.5 } } },
        .{ .name = "occluded_cutoff", .type = .f32, .presence = .{ .default = .{ .float = 1200 } } },
    },
};

/// Version 1.
pub const filter: Schema = .{
    .id = SchemaId.fromStringUnchecked(filter_name),
    .version = 1,
    .fields = &.{
        .{ .name = "shape", .type = .string },
        .{ .name = "frequency", .type = .f32 },
        .{ .name = "q", .type = .f32, .presence = .{ .default = .{ .float = 0.7071 } } },
        .{ .name = "gain_db", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    },
};

/// Version 1.
pub const delay: Schema = .{
    .id = SchemaId.fromStringUnchecked(delay_name),
    .version = 1,
    .fields = &.{
        .{ .name = "time", .type = .f32 },
        .{ .name = "feedback", .type = .f32, .presence = .{ .default = .{ .float = 0.3 } } },
        .{ .name = "wet", .type = .f32, .presence = .{ .default = .{ .float = 0.3 } } },
        .{ .name = "dry", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
    },
};

/// Version 1.
pub const reverb: Schema = .{
    .id = SchemaId.fromStringUnchecked(reverb_name),
    .version = 1,
    .fields = &.{
        .{ .name = "decay", .type = .f32, .presence = .{ .default = .{ .float = 1.5 } } },
        .{ .name = "damping", .type = .f32, .presence = .{ .default = .{ .float = 0.5 } } },
        .{ .name = "size", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
        .{ .name = "predelay", .type = .f32, .presence = .{ .default = .{ .float = 0.01 } } },
        .{ .name = "wet", .type = .f32, .presence = .{ .default = .{ .float = 0.25 } } },
        .{ .name = "dry", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
    },
};

/// Version 1.
pub const compressor: Schema = .{
    .id = SchemaId.fromStringUnchecked(compressor_name),
    .version = 1,
    .fields = &.{
        .{ .name = "threshold_db", .type = .f32, .presence = .{ .default = .{ .float = -18 } } },
        .{ .name = "ratio", .type = .f32, .presence = .{ .default = .{ .float = 3 } } },
        .{ .name = "knee_db", .type = .f32, .presence = .{ .default = .{ .float = 6 } } },
        .{ .name = "attack", .type = .f32, .presence = .{ .default = .{ .float = 0.01 } } },
        .{ .name = "release", .type = .f32, .presence = .{ .default = .{ .float = 0.15 } } },
        .{ .name = "makeup_db", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    },
};

/// Version 1.
pub const limiter: Schema = .{
    .id = SchemaId.fromStringUnchecked(limiter_name),
    .version = 1,
    .fields = &.{
        .{ .name = "ceiling_db", .type = .f32, .presence = .{ .default = .{ .float = -1 } } },
        .{ .name = "release", .type = .f32, .presence = .{ .default = .{ .float = 0.1 } } },
        .{ .name = "lookahead", .type = .f32, .presence = .{ .default = .{ .float = 0.002 } } },
    },
};

/// The schemas this file declares, in a fixed order.
pub const schemas = [_]Schema{ bus, attenuation, filter, delay, reverb, compressor, limiter };

pub fn registerAll(gpa: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    for (&schemas) |schema| _ = try registry.register(gpa, schema);
}

// -- values ------------------------------------------------------------------------

/// What a `foundry:sound` record says about mixing it: version 3's fields (§4.1). Version 1 and
/// 2 records read as these defaults, so they play exactly as before.
pub const SoundSettings = struct {
    /// The bus it mixes into; none is the root.
    bus: ?ContentId = null,
    /// 0–255; higher is kept when voices run out (§7).
    priority: u8 = 128,
    /// The `foundry:audio_attenuation` a spatial play uses; none is the defaults.
    attenuation: ?ContentId = null,
    /// Source frames. A loop region matters only when the voice loops.
    loop_start: u64 = 0,
    /// Source frames; 0 is the sound's end.
    loop_end: u64 = 0,

    /// The checks the record alone can make. The rest need the sound's length (`checkLoop`).
    pub fn validate(self: *const SoundSettings) Refusal!void {
        if (self.loop_end != 0 and self.loop_start >= self.loop_end) return error.InvalidLoop;
        if (self.loop_end != 0 and self.loop_end - self.loop_start < min_loop_frames) return error.LoopTooShort;
    }

    /// The loop region against a sound of `frames` frames: the checks only the decoded length
    /// can make, run where the sound is decoded (`mixing.md` §4.1).
    pub fn checkLoop(self: *const SoundSettings, frames: u64) Refusal!void {
        if (self.loop_end > frames) return error.LoopPastEnd;
        const end = self.loopEnd(frames);
        if (self.loop_start >= end) return error.InvalidLoop;
        if (end - self.loop_start < min_loop_frames) return error.LoopTooShort;
    }

    /// The region's end in frames, for a sound of `frames` frames.
    pub fn loopEnd(self: *const SoundSettings, frames: u64) u64 {
        return if (self.loop_end == 0) frames else self.loop_end;
    }
};

pub const Model = enum { inverse, linear };

pub const Attenuation = struct {
    model: Model = .inverse,
    /// Metres; full gain inside it.
    min_distance: f32 = 1,
    /// Metres; silent at and past it.
    max_distance: f32 = 30,
    /// The gain factor when fully occluded.
    occluded_gain: f32 = 0.5,
    /// Hz: the voice's low-pass when fully occluded.
    occluded_cutoff: f32 = 1200,

    pub fn validate(self: *const Attenuation) Refusal!void {
        if (!within(self.min_distance, 0, max_distance_limit) or self.min_distance <= 0) return error.InvalidMinDistance;
        if (!within(self.max_distance, 0, max_distance_limit) or self.max_distance <= self.min_distance) return error.InvalidMaxDistance;
        if (!within(self.occluded_gain, 0, 1)) return error.InvalidOccludedGain;
        if (!within(self.occluded_cutoff, 20, 20_000)) return error.InvalidOccludedCutoff;
    }
};

/// A decoded bus. A fixed array rather than a slice, so a value owns what it says.
pub const Bus = struct {
    /// None makes it a root.
    parent: ?ContentId = null,
    gain: f32 = 1,
    effect_buffer: [max_effects]ContentId = undefined,
    effect_count: u8 = 0,

    pub fn effects(self: *const Bus) []const ContentId {
        return self.effect_buffer[0..self.effect_count];
    }

    pub fn validate(self: *const Bus) Refusal!void {
        if (!within(self.gain, 0, max_bus_gain)) return error.InvalidGain;
    }
};

pub const Shape = enum { lowpass, highpass, bandpass, lowshelf, highshelf, peak };

pub const Filter = struct {
    shape: Shape,
    /// Hz.
    frequency: f32,
    q: f32 = 0.7071,
    /// Shelves and peak only.
    gain_db: f32 = 0,

    pub fn validate(self: *const Filter) Refusal!void {
        if (!within(self.frequency, 20, 20_000)) return error.InvalidFrequency;
        if (!within(self.q, 0.1, 20)) return error.InvalidQ;
        if (!within(self.gain_db, -24, 24)) return error.InvalidGainDb;
    }
};

pub const Delay = struct {
    /// Seconds; fixed for a tree's life, since it sizes the line.
    time: f32,
    feedback: f32 = 0.3,
    wet: f32 = 0.3,
    dry: f32 = 1,

    pub fn validate(self: *const Delay) Refusal!void {
        if (!within(self.time, 0.001, 2)) return error.InvalidTime;
        if (!within(self.feedback, 0, 0.95)) return error.InvalidFeedback;
        if (!within(self.wet, 0, 1)) return error.InvalidWet;
        if (!within(self.dry, 0, 1)) return error.InvalidDry;
    }
};

pub const Reverb = struct {
    /// Seconds to fall 60 dB.
    decay: f32 = 1.5,
    /// 0–1: how much faster high frequencies decay.
    damping: f32 = 0.5,
    /// Scales the delay lines; fixed for a tree's life.
    size: f32 = 1,
    /// Seconds; fixed for a tree's life.
    predelay: f32 = 0.01,
    wet: f32 = 0.25,
    dry: f32 = 1,

    pub fn validate(self: *const Reverb) Refusal!void {
        if (!within(self.decay, 0.1, 20)) return error.InvalidDecay;
        if (!within(self.damping, 0, 1)) return error.InvalidDamping;
        if (!within(self.size, 0.25, 2)) return error.InvalidSize;
        if (!within(self.predelay, 0, 0.2)) return error.InvalidPredelay;
        if (!within(self.wet, 0, 1)) return error.InvalidWet;
        if (!within(self.dry, 0, 1)) return error.InvalidDry;
    }
};

pub const Compressor = struct {
    threshold_db: f32 = -18,
    ratio: f32 = 3,
    knee_db: f32 = 6,
    /// Seconds.
    attack: f32 = 0.01,
    /// Seconds.
    release: f32 = 0.15,
    makeup_db: f32 = 0,

    pub fn validate(self: *const Compressor) Refusal!void {
        if (!within(self.threshold_db, -60, 0)) return error.InvalidThreshold;
        if (!within(self.ratio, 1, 20)) return error.InvalidRatio;
        if (!within(self.knee_db, 0, 24)) return error.InvalidKnee;
        if (!within(self.attack, 0.0001, 0.5)) return error.InvalidAttack;
        if (!within(self.release, 0.001, 5)) return error.InvalidRelease;
        if (!within(self.makeup_db, 0, 24)) return error.InvalidMakeup;
    }
};

pub const Limiter = struct {
    ceiling_db: f32 = -1,
    /// Seconds.
    release: f32 = 0.1,
    /// Seconds; fixed for a tree's life, since it sizes the delay.
    lookahead: f32 = 0.002,

    pub fn validate(self: *const Limiter) Refusal!void {
        if (!within(self.ceiling_db, -24, 0)) return error.InvalidCeiling;
        if (!within(self.release, 0.001, 2)) return error.InvalidRelease;
        if (!within(self.lookahead, 0.0005, 0.01)) return error.InvalidLookahead;
    }
};

/// Any one effect, as a bus's chain holds it.
pub const Effect = union(enum) {
    filter: Filter,
    delay: Delay,
    reverb: Reverb,
    compressor: Compressor,
    limiter: Limiter,

    pub fn validate(self: *const Effect) Refusal!void {
        switch (self.*) {
            inline else => |*value| try value.validate(),
        }
    }
};

pub const Refusal = error{
    InvalidLoop,
    LoopTooShort,
    LoopPastEnd,
    InvalidPriority,
    InvalidMinDistance,
    InvalidMaxDistance,
    InvalidOccludedGain,
    InvalidOccludedCutoff,
    InvalidGain,
    TooManyEffects,
    InvalidFrequency,
    InvalidQ,
    InvalidGainDb,
    InvalidTime,
    InvalidFeedback,
    InvalidWet,
    InvalidDry,
    InvalidDecay,
    InvalidDamping,
    InvalidSize,
    InvalidPredelay,
    InvalidThreshold,
    InvalidRatio,
    InvalidKnee,
    InvalidAttack,
    InvalidRelease,
    InvalidMakeup,
    InvalidCeiling,
    InvalidLookahead,
};

/// What only a record can get wrong, besides the value's refusals.
pub const DecodeError = Refusal || error{
    /// The block disagrees with its schema: a damaged or hostile package.
    Unreadable,
    UnknownModel,
    UnknownShape,
    /// The record is not one of this file's effect schemas.
    NotAnEffect,
    /// A sound's or a bus's `bus`/`parent` names a record that is not a `foundry:audio_bus`.
    NotABus,
    /// A sound's `attenuation` names a record that is not a `foundry:audio_attenuation`.
    NotAnAttenuation,
};

/// A sentence naming the field, for a diagnostic or a log line: "its <...>".
pub fn describe(err: DecodeError) []const u8 {
    return switch (err) {
        error.Unreadable => "cannot be read against its schema",
        error.UnknownModel => "has a model that is not inverse or linear",
        error.UnknownShape => "has a shape that is not lowpass, highpass, bandpass, lowshelf, highshelf or peak",
        error.NotAnEffect => "names an effect that is not a foundry:audio_filter, _delay, _reverb, _compressor or _limiter",
        error.NotABus => "names a bus or parent that is not a foundry:audio_bus",
        error.NotAnAttenuation => "names an attenuation that is not a foundry:audio_attenuation",
        error.InvalidLoop => "has a loop_start at or after its loop end",
        error.LoopTooShort => "has a loop region shorter than 64 frames",
        error.LoopPastEnd => "has a loop_end past the sound's last frame",
        error.InvalidPriority => "has a priority above 255",
        error.InvalidMinDistance => "has a min_distance that is not positive, not finite or above 10 km",
        error.InvalidMaxDistance => "has a max_distance that is not above min_distance, not finite or above 10 km",
        error.InvalidOccludedGain => "has an occluded_gain that is not between 0 and 1",
        error.InvalidOccludedCutoff => "has an occluded_cutoff that is not between 20 and 20,000 Hz",
        error.InvalidGain => "has a gain that is not between 0 and 4",
        error.TooManyEffects => "has more than 8 effects",
        error.InvalidFrequency => "has a frequency that is not between 20 and 20,000 Hz",
        error.InvalidQ => "has a q that is not between 0.1 and 20",
        error.InvalidGainDb => "has a gain_db that is not between -24 and 24",
        error.InvalidTime => "has a time that is not between 0.001 and 2 seconds",
        error.InvalidFeedback => "has a feedback that is not between 0 and 0.95",
        error.InvalidWet => "has a wet that is not between 0 and 1",
        error.InvalidDry => "has a dry that is not between 0 and 1",
        error.InvalidDecay => "has a decay that is not between 0.1 and 20 seconds",
        error.InvalidDamping => "has a damping that is not between 0 and 1",
        error.InvalidSize => "has a size that is not between 0.25 and 2",
        error.InvalidPredelay => "has a predelay that is not between 0 and 0.2 seconds",
        error.InvalidThreshold => "has a threshold_db that is not between -60 and 0",
        error.InvalidRatio => "has a ratio that is not between 1 and 20",
        error.InvalidKnee => "has a knee_db that is not between 0 and 24",
        error.InvalidAttack => "has an attack that is not between 0.0001 and 0.5 seconds",
        error.InvalidRelease => "has a release outside its range",
        error.InvalidMakeup => "has a makeup_db that is not between 0 and 24",
        error.InvalidCeiling => "has a ceiling_db that is not between -24 and 0",
        error.InvalidLookahead => "has a lookahead that is not between 0.0005 and 0.01 seconds",
    };
}

/// A noun for a diagnostic: "audio bus 't:b' has ...".
pub fn noun(schema_id: SchemaId) ?[]const u8 {
    if (schema_id.eql(bus.id)) return "audio bus";
    if (schema_id.eql(attenuation.id)) return "audio attenuation";
    if (schema_id.eql(filter.id)) return "audio filter";
    if (schema_id.eql(delay.id)) return "audio delay";
    if (schema_id.eql(reverb.id)) return "audio reverb";
    if (schema_id.eql(compressor.id)) return "audio compressor";
    if (schema_id.eql(limiter.id)) return "audio limiter";
    return null;
}

/// Decodes any record of this file's schemas, for a checker that only wants to know whether
/// it is valid. Null for any other schema.
pub fn check(schema_id: SchemaId, fields: Fields) ?DecodeError!void {
    if (schema_id.eql(bus.id)) return if (decodeBus(fields)) |_| {} else |err| err;
    if (schema_id.eql(attenuation.id)) return if (decodeAttenuation(fields)) |_| {} else |err| err;
    if (isEffect(schema_id)) return if (decodeEffect(schema_id, fields)) |_| {} else |err| err;
    return null;
}

/// Reads a `foundry:sound`'s mixing fields. An absent field is its default, so a version 1 or 2
/// record decodes as it always played (I8).
pub fn decodeSound(fields: Fields) DecodeError!SoundSettings {
    var out: SoundSettings = .{};
    if (try idOf(fields, "bus")) |id| out.bus = id;
    if (try intOf(fields, "priority")) |v| {
        if (v < 0 or v > max_priority) return error.InvalidPriority;
        out.priority = @intCast(v);
    }
    if (try idOf(fields, "attenuation")) |id| out.attenuation = id;
    if (try intOf(fields, "loop_start")) |v| out.loop_start = std.math.cast(u64, v) orelse return error.InvalidLoop;
    if (try intOf(fields, "loop_end")) |v| out.loop_end = std.math.cast(u64, v) orelse return error.InvalidLoop;
    try out.validate();
    return out;
}

pub fn decodeAttenuation(fields: Fields) DecodeError!Attenuation {
    var out: Attenuation = .{};
    if (try stringOf(fields, "model")) |text| out.model = std.meta.stringToEnum(Model, text) orelse return error.UnknownModel;
    if (try floatOf(fields, "min_distance")) |v| out.min_distance = v;
    if (try floatOf(fields, "max_distance")) |v| out.max_distance = v;
    if (try floatOf(fields, "occluded_gain")) |v| out.occluded_gain = v;
    if (try floatOf(fields, "occluded_cutoff")) |v| out.occluded_cutoff = v;
    try out.validate();
    return out;
}

pub fn decodeBus(fields: Fields) DecodeError!Bus {
    var out: Bus = .{};
    if (try idOf(fields, "parent")) |id| out.parent = id;
    if (try floatOf(fields, "gain")) |v| out.gain = v;
    if (try listOf(fields, "effects")) |list| {
        if (list.len > max_effects) return error.TooManyEffects;
        for (0..list.len) |i| {
            out.effect_buffer[i] = (list.idAt(@intCast(i)) catch return error.Unreadable) orelse return error.Unreadable;
        }
        out.effect_count = @intCast(list.len);
    }
    try out.validate();
    return out;
}

pub fn isEffect(schema_id: SchemaId) bool {
    inline for (.{ filter, delay, reverb, compressor, limiter }) |schema| {
        if (schema_id.eql(schema.id)) return true;
    }
    return false;
}

/// Reads an effect record of whichever of the five schemas `schema_id` names.
pub fn decodeEffect(schema_id: SchemaId, fields: Fields) DecodeError!Effect {
    const out: Effect = if (schema_id.eql(filter.id)) .{ .filter = .{
        .shape = std.meta.stringToEnum(Shape, try stringOf(fields, "shape") orelse return error.Unreadable) orelse return error.UnknownShape,
        .frequency = try floatOf(fields, "frequency") orelse return error.Unreadable,
        .q = try floatOf(fields, "q") orelse 0.7071,
        .gain_db = try floatOf(fields, "gain_db") orelse 0,
    } } else if (schema_id.eql(delay.id)) .{ .delay = .{
        .time = try floatOf(fields, "time") orelse return error.Unreadable,
        .feedback = try floatOf(fields, "feedback") orelse 0.3,
        .wet = try floatOf(fields, "wet") orelse 0.3,
        .dry = try floatOf(fields, "dry") orelse 1,
    } } else if (schema_id.eql(reverb.id)) .{ .reverb = .{
        .decay = try floatOf(fields, "decay") orelse 1.5,
        .damping = try floatOf(fields, "damping") orelse 0.5,
        .size = try floatOf(fields, "size") orelse 1,
        .predelay = try floatOf(fields, "predelay") orelse 0.01,
        .wet = try floatOf(fields, "wet") orelse 0.25,
        .dry = try floatOf(fields, "dry") orelse 1,
    } } else if (schema_id.eql(compressor.id)) .{ .compressor = .{
        .threshold_db = try floatOf(fields, "threshold_db") orelse -18,
        .ratio = try floatOf(fields, "ratio") orelse 3,
        .knee_db = try floatOf(fields, "knee_db") orelse 6,
        .attack = try floatOf(fields, "attack") orelse 0.01,
        .release = try floatOf(fields, "release") orelse 0.15,
        .makeup_db = try floatOf(fields, "makeup_db") orelse 0,
    } } else if (schema_id.eql(limiter.id)) .{ .limiter = .{
        .ceiling_db = try floatOf(fields, "ceiling_db") orelse -1,
        .release = try floatOf(fields, "release") orelse 0.1,
        .lookahead = try floatOf(fields, "lookahead") orelse 0.002,
    } } else return error.NotAnEffect;
    try out.validate();
    return out;
}

// -- references, checked where they resolve -----------------------------------------

/// Whether a sound's `bus` and `attenuation` name records of the right schemas in `store`.
/// IDs resolve across packages, so this runs at load, as a playlist's tracks are checked.
pub fn checkSoundReferences(value: *const SoundSettings, store: *const data.Store) DecodeError!void {
    if (value.bus) |id| try expectSchema(store, id, bus.id, error.NotABus);
    if (value.attenuation) |id| try expectSchema(store, id, attenuation.id, error.NotAnAttenuation);
}

/// Whether a bus's `parent` is a bus and each of its effects is an effect, in `store`.
pub fn checkBusReferences(value: *const Bus, store: *const data.Store) DecodeError!void {
    if (value.parent) |id| try expectSchema(store, id, bus.id, error.NotABus);
    for (value.effects()) |id| {
        const record = store.lookup(id) orelse return error.NotAnEffect;
        if (!isEffect(record.schema_id)) return error.NotAnEffect;
    }
}

fn expectSchema(store: *const data.Store, id: ContentId, schema_id: SchemaId, err: DecodeError) DecodeError!void {
    const record = store.lookup(id) orelse return err;
    if (!record.schema_id.eql(schema_id)) return err;
}

fn indexOf(fields: Fields, field: []const u8) ?u32 {
    for (fields.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, field)) return @intCast(i);
    return null;
}

fn floatOf(fields: Fields, field: []const u8) DecodeError!?f32 {
    const i = indexOf(fields, field) orelse return null;
    const value = (fields.floatAt(i) catch return error.Unreadable) orelse return null;
    return @floatCast(value);
}

fn intOf(fields: Fields, field: []const u8) DecodeError!?i128 {
    const i = indexOf(fields, field) orelse return null;
    return fields.intAt(i) catch return error.Unreadable;
}

fn stringOf(fields: Fields, field: []const u8) DecodeError!?[]const u8 {
    const i = indexOf(fields, field) orelse return null;
    return fields.stringAt(i) catch return error.Unreadable;
}

fn idOf(fields: Fields, field: []const u8) DecodeError!?ContentId {
    const i = indexOf(fields, field) orelse return null;
    return fields.idAt(i) catch return error.Unreadable;
}

fn listOf(fields: Fields, field: []const u8) DecodeError!?data.fpk.List {
    const i = indexOf(fields, field) orelse return null;
    return fields.listAt(i) catch return error.Unreadable;
}

fn within(value: f32, lo: f32, hi: f32) bool {
    return std.math.isFinite(value) and value >= lo and value <= hi;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;
const schemas_mod = @import("schemas.zig");

/// A package compiled from text, kept open so its records can be decoded.
const Compiled = struct {
    bytes: std.ArrayList(u8),
    reader: data.fpk.Reader,

    fn init(source: []const u8) !*Compiled {
        const gpa = testing.allocator;
        var registry: Registry = .init(gpa, .default);
        defer registry.deinit(gpa);
        try registerAll(gpa, &registry);
        try schemas_mod.registerAll(gpa, &registry);
        var diags: data.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);
        var doc = try data.parser.parse(gpa, "mix.fdt", source, .{ .namespace = "t" }, &diags);
        defer doc.deinit(gpa);
        var package = try data.check.Package.init(gpa, "t:content", 1, .default);
        defer package.deinit(gpa);
        try package.addDocument(gpa, &doc, &registry, &diags);
        const self = try gpa.create(Compiled);
        errdefer gpa.destroy(self);
        self.bytes = .empty;
        errdefer self.bytes.deinit(gpa);
        try data.fpk.write(gpa, &package, &registry, &self.bytes);
        self.reader = try data.fpk.Reader.open(gpa, self.bytes.items, .default);
        return self;
    }

    fn deinit(self: *Compiled) void {
        self.reader.deinit();
        self.bytes.deinit(testing.allocator);
        testing.allocator.destroy(self);
    }

    fn schemaOf(self: *Compiled, i: u32) SchemaId {
        return self.reader.record(i).?.schema_id;
    }

    fn fields(self: *Compiled, i: u32) Fields {
        const view = self.reader.record(i).?;
        return self.reader.fieldsOf(view, self.reader.schemaFor(view.schema_id).?.*);
    }
};

/// The one record's refusal, or null if it decodes.
fn refusalOf(source: []const u8) !?DecodeError {
    const c = try Compiled.init(source);
    defer c.deinit();
    const schema_id = c.schemaOf(0);
    const result: DecodeError!void = if (schema_id.eql(schemas_mod.sound.id))
        (if (decodeSound(c.fields(0))) |_| {} else |err| err)
    else
        check(schema_id, c.fields(0)).?;
    // As a value: a refusal is this helper's answer, not its failure.
    result catch |err| return @as(?DecodeError, err);
    return null;
}

test "an absent field is its default, in every record" {
    const c = try Compiled.init(
        \\foundry:sound t:s { source "s.ogg" }
        \\foundry:audio_attenuation t:a { }
        \\foundry:audio_bus t:b { }
        \\foundry:audio_filter t:f { shape "lowpass" frequency 800 }
        \\foundry:audio_delay t:d { time 0.25 }
        \\foundry:audio_reverb t:r { }
        \\foundry:audio_compressor t:c { }
        \\foundry:audio_limiter t:l { }
    );
    defer c.deinit();

    const sound = try decodeSound(c.fields(0));
    try testing.expectEqual(@as(?ContentId, null), sound.bus);
    try testing.expectEqual(@as(u8, 128), sound.priority);
    try testing.expectEqual(@as(?ContentId, null), sound.attenuation);
    try testing.expectEqual(@as(u64, 0), sound.loop_start);
    try testing.expectEqual(@as(u64, 0), sound.loop_end);

    try testing.expectEqual(Attenuation{}, try decodeAttenuation(c.fields(1)));
    const b = try decodeBus(c.fields(2));
    try testing.expectEqual(@as(?ContentId, null), b.parent);
    try testing.expectEqual(@as(f32, 1), b.gain);
    try testing.expectEqual(@as(usize, 0), b.effects().len);

    try testing.expectEqual(Effect{ .filter = .{ .shape = .lowpass, .frequency = 800 } }, try decodeEffect(c.schemaOf(3), c.fields(3)));
    try testing.expectEqual(Effect{ .delay = .{ .time = 0.25 } }, try decodeEffect(c.schemaOf(4), c.fields(4)));
    try testing.expectEqual(Effect{ .reverb = .{} }, try decodeEffect(c.schemaOf(5), c.fields(5)));
    try testing.expectEqual(Effect{ .compressor = .{} }, try decodeEffect(c.schemaOf(6), c.fields(6)));
    try testing.expectEqual(Effect{ .limiter = .{} }, try decodeEffect(c.schemaOf(7), c.fields(7)));
    // A sound is not an effect.
    try testing.expectError(error.NotAnEffect, decodeEffect(c.schemaOf(0), c.fields(0)));
}

test "every field is read as written" {
    const c = try Compiled.init(
        \\foundry:sound t:s { source "s.ogg" bus t:b priority 255 attenuation t:a loop_start 44100 loop_end 88200 }
        \\foundry:audio_attenuation t:a { model "linear" min_distance 2 max_distance 18 occluded_gain 0.25 occluded_cutoff 900 }
        \\foundry:audio_bus t:b { parent t:root gain 0.5 effects [ t:f t:r ] }
        \\foundry:audio_filter t:f { shape "peak" frequency 2000 q 2 gain_db -6 }
        \\foundry:audio_reverb t:r { decay 3.2 damping 0.2 size 1.5 predelay 0.05 wet 0.4 dry 0.8 }
        \\foundry:audio_compressor t:c { threshold_db -20 ratio 2 knee_db 0 attack 0.005 release 0.3 makeup_db 3 }
        \\foundry:audio_limiter t:l { ceiling_db -0.5 release 0.05 lookahead 0.005 }
    );
    defer c.deinit();

    const sound = try decodeSound(c.fields(0));
    try testing.expect(sound.bus.?.eql(ContentId.fromString("t:b")));
    try testing.expectEqual(@as(u8, 255), sound.priority);
    try testing.expect(sound.attenuation.?.eql(ContentId.fromString("t:a")));
    try testing.expectEqual(@as(u64, 44100), sound.loop_start);
    try testing.expectEqual(@as(u64, 88200), sound.loop_end);

    try testing.expectEqual(Attenuation{ .model = .linear, .min_distance = 2, .max_distance = 18, .occluded_gain = 0.25, .occluded_cutoff = 900 }, try decodeAttenuation(c.fields(1)));
    const b = try decodeBus(c.fields(2));
    try testing.expect(b.parent.?.eql(ContentId.fromString("t:root")));
    try testing.expectEqual(@as(f32, 0.5), b.gain);
    try testing.expectEqual(@as(usize, 2), b.effects().len);
    try testing.expect(b.effects()[1].eql(ContentId.fromString("t:r")));
    try testing.expectEqual(Effect{ .filter = .{ .shape = .peak, .frequency = 2000, .q = 2, .gain_db = -6 } }, try decodeEffect(c.schemaOf(3), c.fields(3)));
    try testing.expectEqual(Effect{ .reverb = .{ .decay = 3.2, .damping = 0.2, .size = 1.5, .predelay = 0.05, .wet = 0.4, .dry = 0.8 } }, try decodeEffect(c.schemaOf(4), c.fields(4)));
    try testing.expectEqual(Effect{ .compressor = .{ .threshold_db = -20, .ratio = 2, .knee_db = 0, .attack = 0.005, .release = 0.3, .makeup_db = 3 } }, try decodeEffect(c.schemaOf(5), c.fields(5)));
    try testing.expectEqual(Effect{ .limiter = .{ .ceiling_db = -0.5, .release = 0.05, .lookahead = 0.005 } }, try decodeEffect(c.schemaOf(6), c.fields(6)));
}

test "every refusal is named" {
    const cases = [_]struct { source: []const u8, err: DecodeError }{
        // foundry:sound version 3
        .{ .source = "foundry:sound t:s { source \"s.ogg\" priority 256 }", .err = error.InvalidPriority },
        .{ .source = "foundry:sound t:s { source \"s.ogg\" loop_start 100 loop_end 100 }", .err = error.InvalidLoop },
        .{ .source = "foundry:sound t:s { source \"s.ogg\" loop_start 100 loop_end 50 }", .err = error.InvalidLoop },
        .{ .source = "foundry:sound t:s { source \"s.ogg\" loop_start 100 loop_end 163 }", .err = error.LoopTooShort },
        // foundry:audio_attenuation
        .{ .source = "foundry:audio_attenuation t:a { model \"exponential\" }", .err = error.UnknownModel },
        .{ .source = "foundry:audio_attenuation t:a { min_distance 0 }", .err = error.InvalidMinDistance },
        .{ .source = "foundry:audio_attenuation t:a { min_distance -1 }", .err = error.InvalidMinDistance },
        .{ .source = "foundry:audio_attenuation t:a { min_distance 5 max_distance 5 }", .err = error.InvalidMaxDistance },
        .{ .source = "foundry:audio_attenuation t:a { max_distance 10001 }", .err = error.InvalidMaxDistance },
        .{ .source = "foundry:audio_attenuation t:a { occluded_gain 1.5 }", .err = error.InvalidOccludedGain },
        .{ .source = "foundry:audio_attenuation t:a { occluded_cutoff 10 }", .err = error.InvalidOccludedCutoff },
        .{ .source = "foundry:audio_attenuation t:a { occluded_cutoff 20001 }", .err = error.InvalidOccludedCutoff },
        // foundry:audio_bus
        .{ .source = "foundry:audio_bus t:b { gain 4.5 }", .err = error.InvalidGain },
        .{ .source = "foundry:audio_bus t:b { gain -1 }", .err = error.InvalidGain },
        .{ .source = "foundry:audio_bus t:b { effects [ t:e1 t:e2 t:e3 t:e4 t:e5 t:e6 t:e7 t:e8 t:e9 ] }", .err = error.TooManyEffects },
        // foundry:audio_filter
        .{ .source = "foundry:audio_filter t:f { shape \"notch\" frequency 800 }", .err = error.UnknownShape },
        .{ .source = "foundry:audio_filter t:f { shape \"lowpass\" frequency 19 }", .err = error.InvalidFrequency },
        .{ .source = "foundry:audio_filter t:f { shape \"lowpass\" frequency 20001 }", .err = error.InvalidFrequency },
        .{ .source = "foundry:audio_filter t:f { shape \"lowpass\" frequency 800 q 0.05 }", .err = error.InvalidQ },
        .{ .source = "foundry:audio_filter t:f { shape \"lowpass\" frequency 800 q 21 }", .err = error.InvalidQ },
        .{ .source = "foundry:audio_filter t:f { shape \"peak\" frequency 800 gain_db 25 }", .err = error.InvalidGainDb },
        // foundry:audio_delay
        .{ .source = "foundry:audio_delay t:d { time 0 }", .err = error.InvalidTime },
        .{ .source = "foundry:audio_delay t:d { time 2.5 }", .err = error.InvalidTime },
        .{ .source = "foundry:audio_delay t:d { time 0.25 feedback 0.96 }", .err = error.InvalidFeedback },
        .{ .source = "foundry:audio_delay t:d { time 0.25 wet 1.1 }", .err = error.InvalidWet },
        .{ .source = "foundry:audio_delay t:d { time 0.25 dry -0.1 }", .err = error.InvalidDry },
        // foundry:audio_reverb
        .{ .source = "foundry:audio_reverb t:r { decay 0.05 }", .err = error.InvalidDecay },
        .{ .source = "foundry:audio_reverb t:r { decay 21 }", .err = error.InvalidDecay },
        .{ .source = "foundry:audio_reverb t:r { damping 1.5 }", .err = error.InvalidDamping },
        .{ .source = "foundry:audio_reverb t:r { size 0.2 }", .err = error.InvalidSize },
        .{ .source = "foundry:audio_reverb t:r { size 2.5 }", .err = error.InvalidSize },
        .{ .source = "foundry:audio_reverb t:r { predelay 0.3 }", .err = error.InvalidPredelay },
        .{ .source = "foundry:audio_reverb t:r { wet 2 }", .err = error.InvalidWet },
        .{ .source = "foundry:audio_reverb t:r { dry 2 }", .err = error.InvalidDry },
        // foundry:audio_compressor
        .{ .source = "foundry:audio_compressor t:c { threshold_db 1 }", .err = error.InvalidThreshold },
        .{ .source = "foundry:audio_compressor t:c { threshold_db -61 }", .err = error.InvalidThreshold },
        .{ .source = "foundry:audio_compressor t:c { ratio 0.5 }", .err = error.InvalidRatio },
        .{ .source = "foundry:audio_compressor t:c { ratio 21 }", .err = error.InvalidRatio },
        .{ .source = "foundry:audio_compressor t:c { knee_db 25 }", .err = error.InvalidKnee },
        .{ .source = "foundry:audio_compressor t:c { attack 0 }", .err = error.InvalidAttack },
        .{ .source = "foundry:audio_compressor t:c { attack 0.6 }", .err = error.InvalidAttack },
        .{ .source = "foundry:audio_compressor t:c { release 0 }", .err = error.InvalidRelease },
        .{ .source = "foundry:audio_compressor t:c { release 6 }", .err = error.InvalidRelease },
        .{ .source = "foundry:audio_compressor t:c { makeup_db -1 }", .err = error.InvalidMakeup },
        // foundry:audio_limiter
        .{ .source = "foundry:audio_limiter t:l { ceiling_db 0.5 }", .err = error.InvalidCeiling },
        .{ .source = "foundry:audio_limiter t:l { ceiling_db -25 }", .err = error.InvalidCeiling },
        .{ .source = "foundry:audio_limiter t:l { release 3 }", .err = error.InvalidRelease },
        .{ .source = "foundry:audio_limiter t:l { lookahead 0.0001 }", .err = error.InvalidLookahead },
        .{ .source = "foundry:audio_limiter t:l { lookahead 0.02 }", .err = error.InvalidLookahead },
    };
    for (cases) |case| {
        const got = try refusalOf(case.source);
        if (got == null or got.? != case.err) {
            std.debug.print("{s}: expected {t}, got {?t}\n", .{ case.source, case.err, got });
            return error.TestUnexpectedResult;
        }
    }

    // A package's text cannot spell a non-finite number, but its bytes can carry one.
    var a: Attenuation = .{ .max_distance = std.math.inf(f32) };
    try testing.expectError(error.InvalidMaxDistance, a.validate());
    a = .{ .occluded_gain = std.math.nan(f32) };
    try testing.expectError(error.InvalidOccludedGain, a.validate());
    const r: Effect = .{ .reverb = .{ .decay = std.math.nan(f32) } };
    try testing.expectError(error.InvalidDecay, r.validate());
    const b: Bus = .{ .gain = std.math.nan(f32) };
    try testing.expectError(error.InvalidGain, b.validate());
}

test "a loop region is checked against the sound's length where the length is known" {
    const whole: SoundSettings = .{};
    try whole.checkLoop(1000);
    try testing.expectEqual(@as(u64, 1000), whole.loopEnd(1000));
    // A sound shorter than the shortest region cannot loop as a region at all.
    try testing.expectError(error.LoopTooShort, whole.checkLoop(10));

    const intro: SoundSettings = .{ .loop_start = 400 };
    try intro.checkLoop(1000);
    try testing.expectError(error.InvalidLoop, intro.checkLoop(400));
    try testing.expectError(error.LoopTooShort, intro.checkLoop(450));

    const region: SoundSettings = .{ .loop_start = 100, .loop_end = 900 };
    try region.checkLoop(900);
    try region.checkLoop(1000);
    try testing.expectError(error.LoopPastEnd, region.checkLoop(899));
}

test "references resolve to the right schemas, or are refused by name" {
    const gpa = testing.allocator;
    var registry: Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    try registerAll(gpa, &registry);
    try schemas_mod.registerAll(gpa, &registry);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "mix.fdt",
        \\foundry:audio_bus t:root { }
        \\foundry:audio_bus t:world { parent t:root effects [ t:verb ] }
        \\foundry:audio_reverb t:verb { }
        \\foundry:audio_attenuation t:near { }
        \\foundry:sound t:click { source "click.wav" }
    , .{ .namespace = "t" }, &diags);
    defer doc.deinit(gpa);
    var package = try data.check.Package.init(gpa, "t:content", 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &doc, &registry, &diags);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &registry, &bytes);
    _ = try store.add(gpa, "t:content", bytes.items, &registry, &diags);

    const t = ContentId.fromString;
    try checkSoundReferences(&.{ .bus = t("t:world"), .attenuation = t("t:near") }, &store);
    try checkSoundReferences(&.{}, &store);
    try testing.expectError(error.NotABus, checkSoundReferences(&.{ .bus = t("t:verb") }, &store));
    try testing.expectError(error.NotABus, checkSoundReferences(&.{ .bus = t("t:nowhere") }, &store));
    try testing.expectError(error.NotAnAttenuation, checkSoundReferences(&.{ .attenuation = t("t:root") }, &store));

    var world: Bus = .{ .parent = t("t:root"), .effect_count = 1 };
    world.effect_buffer[0] = t("t:verb");
    try checkBusReferences(&world, &store);
    world.effect_buffer[0] = t("t:click");
    try testing.expectError(error.NotAnEffect, checkBusReferences(&world, &store));
    world.effect_buffer[0] = t("t:verb");
    world.parent = t("t:near");
    try testing.expectError(error.NotABus, checkBusReferences(&world, &store));
}
