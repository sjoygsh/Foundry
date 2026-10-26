//! `foundry:music_playlist` and `foundry:music_stinger` — a soundtrack as content
//! (`docs/design/music.md` §7, ADR-0066).
//!
//! ```fdt
//! foundry:music_playlist court:music.calm {
//!     tracks    [ court:music.calm_a  court:music.calm_b ]   # foundry:sound records
//!     order     "shuffle"
//!     crossfade 3
//!     tempo     96
//! }
//! foundry:music_stinger court:music.beacon {
//!     sound    court:sounds.beacon_sting
//!     quantize "beat"
//! }
//! ```
//!
//! **Mechanism, not content** (I5): the record types are the engine's, registered through the
//! call a mod's `@schema` uses (I6), and a game's playlists live in its own package where any
//! later package may override one whole.
//!
//! **They live here, not beside `audio.Music`**, for `particle_emitter`'s reason: `fpack` and
//! the editor check a record with no mixer linked. `audio` reads the values this decodes.
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

pub const playlist_name = "foundry:music_playlist";
pub const stinger_name = "foundry:music_stinger";

pub const max_tracks: usize = 64;
pub const max_crossfade: f32 = 30;
pub const max_gain: f32 = 4;
pub const max_tempo: f32 = 400;
pub const max_beats_per_bar: u32 = 32;
/// A beat offset or a duck's fade longer than this is a typo, not music.
pub const max_seconds: f32 = 600;

/// Version 1.
pub const playlist: Schema = .{
    .id = SchemaId.fromStringUnchecked(playlist_name),
    .version = 1,
    .fields = &.{
        .{ .name = "tracks", .type = .{ .list = &.id } },
        .{ .name = "order", .type = .string, .presence = .{ .default = .{ .string = "sequential" } } },
        .{ .name = "loop", .type = .bool, .presence = .{ .default = .{ .bool = true } } },
        .{ .name = "crossfade", .type = .f32, .presence = .{ .default = .{ .float = 2 } } },
        .{ .name = "gain", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
        .{ .name = "tempo", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
        .{ .name = "beats_per_bar", .type = .u32, .presence = .{ .default = .{ .int = 4 } } },
        .{ .name = "first_beat", .type = .f32, .presence = .{ .default = .{ .float = 0 } } },
    },
};

/// Version 1.
pub const stinger: Schema = .{
    .id = SchemaId.fromStringUnchecked(stinger_name),
    .version = 1,
    .fields = &.{
        .{ .name = "sound", .type = .id },
        .{ .name = "quantize", .type = .string, .presence = .{ .default = .{ .string = "beat" } } },
        .{ .name = "gain", .type = .f32, .presence = .{ .default = .{ .float = 1 } } },
        .{ .name = "duck", .type = .f32, .presence = .{ .default = .{ .float = 0.5 } } },
        .{ .name = "duck_fade", .type = .f32, .presence = .{ .default = .{ .float = 0.1 } } },
    },
};

pub fn registerAll(gpa: Allocator, registry: *Registry) (data.schema.RegisterError || Allocator.Error)!void {
    _ = try registry.register(gpa, playlist);
    _ = try registry.register(gpa, stinger);
}

pub const Order = enum { sequential, shuffle };
pub const Quantize = enum { now, beat, bar };

/// A decoded playlist. A fixed array rather than a slice, so a value owns what it says and can
/// be kept and compared with no allocator.
pub const Playlist = struct {
    track_buffer: [max_tracks]ContentId = undefined,
    track_count: u8 = 0,
    order: Order = .sequential,
    loop: bool = true,
    /// Seconds, between tracks and entering this playlist.
    crossfade: f32 = 2,
    gain: f32 = 1,
    /// Beats per minute; 0 is no grid.
    tempo: f32 = 0,
    beats_per_bar: u32 = 4,
    /// Seconds into each track where beat one falls.
    first_beat: f32 = 0,

    pub fn tracks(self: *const Playlist) []const ContentId {
        return self.track_buffer[0..self.track_count];
    }

    pub fn validate(self: *const Playlist) Refusal!void {
        if (self.track_count == 0) return error.NoTracks;
        if (!within(self.crossfade, 0, max_crossfade)) return error.InvalidCrossfade;
        if (!within(self.gain, 0, max_gain)) return error.InvalidGain;
        if (!within(self.tempo, 0, max_tempo)) return error.InvalidTempo;
        if (self.beats_per_bar == 0 or self.beats_per_bar > max_beats_per_bar) return error.InvalidBeatsPerBar;
        if (!within(self.first_beat, 0, max_seconds)) return error.InvalidFirstBeat;
    }
};

pub const Stinger = struct {
    sound: ContentId,
    quantize: Quantize = .beat,
    gain: f32 = 1,
    /// The music's level beneath it, as a factor; 1 is no duck.
    duck: f32 = 0.5,
    /// Seconds, into the duck and back out.
    duck_fade: f32 = 0.1,

    pub fn validate(self: *const Stinger) Refusal!void {
        if (!within(self.gain, 0, max_gain)) return error.InvalidGain;
        if (!within(self.duck, 0, 1)) return error.InvalidDuck;
        if (!within(self.duck_fade, 0, max_seconds)) return error.InvalidDuckFade;
    }
};

pub const Refusal = error{
    NoTracks,
    TooManyTracks,
    InvalidCrossfade,
    InvalidGain,
    InvalidTempo,
    InvalidBeatsPerBar,
    InvalidFirstBeat,
    InvalidDuck,
    InvalidDuckFade,
};

/// What only a record can get wrong, besides the value's refusals.
pub const DecodeError = Refusal || error{
    /// The block disagrees with its schema: a damaged or hostile package.
    Unreadable,
    UnknownOrder,
    UnknownQuantize,
    /// A track or a stinger's sound names a record that is not a `foundry:sound`, or none.
    NotASound,
};

/// A sentence naming the field, for a diagnostic or a log line: "its <...>".
pub fn describe(err: DecodeError) []const u8 {
    return switch (err) {
        error.Unreadable => "cannot be read against its schema",
        error.UnknownOrder => "has an order that is not sequential or shuffle",
        error.UnknownQuantize => "has a quantize that is not now, beat or bar",
        error.NotASound => "names a track or sound that is not a foundry:sound",
        error.NoTracks => "has no tracks",
        error.TooManyTracks => "has more than 64 tracks",
        error.InvalidCrossfade => "has a crossfade that is negative, not finite or above 30 seconds",
        error.InvalidGain => "has a gain that is not between 0 and 4",
        error.InvalidTempo => "has a tempo that is negative, not finite or above 400",
        error.InvalidBeatsPerBar => "has a beats_per_bar that is not between 1 and 32",
        error.InvalidFirstBeat => "has a first_beat that is negative, not finite or above 600 seconds",
        error.InvalidDuck => "has a duck that is not between 0 and 1",
        error.InvalidDuckFade => "has a duck_fade that is negative, not finite or above 600 seconds",
    };
}

/// Reads and validates a playlist laid out against this schema. An absent field is its
/// default, so a package from before a later version still decodes (I8).
pub fn decodePlaylist(fields: Fields) DecodeError!Playlist {
    var out: Playlist = .{};
    const list = try listOf(fields, "tracks") orelse return error.Unreadable;
    if (list.len > max_tracks) return error.TooManyTracks;
    for (0..list.len) |i| {
        out.track_buffer[i] = (list.idAt(@intCast(i)) catch return error.Unreadable) orelse return error.Unreadable;
    }
    out.track_count = @intCast(list.len);
    if (try stringOf(fields, "order")) |text| out.order = std.meta.stringToEnum(Order, text) orelse return error.UnknownOrder;
    if (try boolOf(fields, "loop")) |v| out.loop = v;
    if (try floatOf(fields, "crossfade")) |v| out.crossfade = v;
    if (try floatOf(fields, "gain")) |v| out.gain = v;
    if (try floatOf(fields, "tempo")) |v| out.tempo = v;
    if (try intOf(fields, "beats_per_bar")) |v| out.beats_per_bar = std.math.cast(u32, v) orelse return error.InvalidBeatsPerBar;
    if (try floatOf(fields, "first_beat")) |v| out.first_beat = v;
    try out.validate();
    return out;
}

pub fn decodeStinger(fields: Fields) DecodeError!Stinger {
    var out: Stinger = .{ .sound = try idOf(fields, "sound") orelse return error.Unreadable };
    if (try stringOf(fields, "quantize")) |text| out.quantize = std.meta.stringToEnum(Quantize, text) orelse return error.UnknownQuantize;
    if (try floatOf(fields, "gain")) |v| out.gain = v;
    if (try floatOf(fields, "duck")) |v| out.duck = v;
    if (try floatOf(fields, "duck_fade")) |v| out.duck_fade = v;
    try out.validate();
    return out;
}

/// Whether every track names a `foundry:sound` in `store`: the check that needs the IDs
/// resolved, so it runs where they resolve, at load (§7).
pub fn checkTracks(value: *const Playlist, store: *const data.Store, sound_schema: SchemaId) DecodeError!void {
    for (value.tracks()) |track| try checkSound(track, store, sound_schema);
}

pub fn checkSound(id: ContentId, store: *const data.Store, sound_schema: SchemaId) DecodeError!void {
    const record = store.lookup(id) orelse return error.NotASound;
    if (!record.schema_id.eql(sound_schema)) return error.NotASound;
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

fn boolOf(fields: Fields, field: []const u8) DecodeError!?bool {
    const i = indexOf(fields, field) orelse return null;
    return fields.boolAt(i) catch return error.Unreadable;
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

const Decoded = union(enum) { playlist: DecodeError!Playlist, stinger: DecodeError!Stinger };

/// Compiles `source` as package `t:content` and decodes its one record.
fn decodeText(source: []const u8) !Decoded {
    const gpa = testing.allocator;
    var registry: Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    try registerAll(gpa, &registry);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var doc = try data.parser.parse(gpa, "music.fdt", source, .{ .namespace = "t" }, &diags);
    defer doc.deinit(gpa);
    var package = try data.check.Package.init(gpa, "t:content", 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &doc, &registry, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &registry, &bytes);
    var reader = try data.fpk.Reader.open(gpa, bytes.items, .default);
    defer reader.deinit();
    const view = reader.record(0).?;
    const fields = reader.fieldsOf(view, reader.schemaFor(view.schema_id).?.*);
    if (view.schema_id.eql(playlist.id)) return .{ .playlist = decodePlaylist(fields) };
    return .{ .stinger = decodeStinger(fields) };
}

fn playlistOf(source: []const u8) !DecodeError!Playlist {
    return (try decodeText(source)).playlist;
}

fn stingerOf(source: []const u8) !DecodeError!Stinger {
    return (try decodeText(source)).stinger;
}

test "an absent field is its default, and the design's example decodes as it says" {
    const minimal = try (try playlistOf("foundry:music_playlist t:p { tracks [ t:a ] }"));
    try testing.expectEqual(@as(usize, 1), minimal.tracks().len);
    try testing.expect(minimal.tracks()[0].eql(ContentId.fromString("t:a")));
    try testing.expectEqual(Order.sequential, minimal.order);
    try testing.expect(minimal.loop);
    try testing.expectEqual(@as(f32, 2), minimal.crossfade);
    try testing.expectEqual(@as(f32, 1), minimal.gain);
    try testing.expectEqual(@as(f32, 0), minimal.tempo);
    try testing.expectEqual(@as(u32, 4), minimal.beats_per_bar);
    try testing.expectEqual(@as(f32, 0), minimal.first_beat);

    const calm = try (try playlistOf(
        \\foundry:music_playlist t:calm {
        \\    tracks [ t:calm_a t:calm_b ]
        \\    order "shuffle"
        \\    loop false
        \\    crossfade 3
        \\    gain 0.8
        \\    tempo 96
        \\    beats_per_bar 3
        \\    first_beat 0.25
        \\}
    ));
    try testing.expectEqual(@as(usize, 2), calm.tracks().len);
    try testing.expectEqual(Order.shuffle, calm.order);
    try testing.expect(!calm.loop);
    try testing.expectEqual(@as(f32, 3), calm.crossfade);
    try testing.expectEqual(@as(f32, 0.8), calm.gain);
    try testing.expectEqual(@as(f32, 96), calm.tempo);
    try testing.expectEqual(@as(u32, 3), calm.beats_per_bar);
    try testing.expectEqual(@as(f32, 0.25), calm.first_beat);

    const sting = try (try stingerOf("foundry:music_stinger t:s { sound t:beep }"));
    try testing.expect(sting.sound.eql(ContentId.fromString("t:beep")));
    try testing.expectEqual(Quantize.beat, sting.quantize);
    try testing.expectEqual(@as(f32, 1), sting.gain);
    try testing.expectEqual(@as(f32, 0.5), sting.duck);
    try testing.expectEqual(@as(f32, 0.1), sting.duck_fade);
    const bar = try (try stingerOf("foundry:music_stinger t:s { sound t:beep quantize \"bar\" gain 2 duck 1 duck_fade 0 }"));
    try testing.expectEqual(Quantize.bar, bar.quantize);
    try testing.expectEqual(@as(f32, 1), bar.duck);
}

test "every playlist and stinger refusal is named" {
    const playlists = [_]struct { source: []const u8, err: DecodeError }{
        .{ .source = "foundry:music_playlist t:p { tracks [ ] }", .err = error.NoTracks },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] order \"random\" }", .err = error.UnknownOrder },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] crossfade -1 }", .err = error.InvalidCrossfade },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] crossfade 30.5 }", .err = error.InvalidCrossfade },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] gain 4.5 }", .err = error.InvalidGain },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] gain -0.1 }", .err = error.InvalidGain },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] tempo -1 }", .err = error.InvalidTempo },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] tempo 401 }", .err = error.InvalidTempo },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] beats_per_bar 0 }", .err = error.InvalidBeatsPerBar },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] beats_per_bar 33 }", .err = error.InvalidBeatsPerBar },
        .{ .source = "foundry:music_playlist t:p { tracks [ t:a ] first_beat -0.5 }", .err = error.InvalidFirstBeat },
    };
    for (playlists) |case| try testing.expectError(case.err, try playlistOf(case.source));

    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    try many.appendSlice(testing.allocator, "foundry:music_playlist t:p { tracks [");
    for (0..max_tracks + 1) |i| try many.print(testing.allocator, " t:track{d}", .{i});
    try many.appendSlice(testing.allocator, " ] }");
    try testing.expectError(error.TooManyTracks, try playlistOf(many.items));

    const stingers = [_]struct { source: []const u8, err: DecodeError }{
        .{ .source = "foundry:music_stinger t:s { sound t:a quantize \"soon\" }", .err = error.UnknownQuantize },
        .{ .source = "foundry:music_stinger t:s { sound t:a gain 5 }", .err = error.InvalidGain },
        .{ .source = "foundry:music_stinger t:s { sound t:a duck 1.5 }", .err = error.InvalidDuck },
        .{ .source = "foundry:music_stinger t:s { sound t:a duck -0.5 }", .err = error.InvalidDuck },
        .{ .source = "foundry:music_stinger t:s { sound t:a duck_fade -1 }", .err = error.InvalidDuckFade },
    };
    for (stingers) |case| try testing.expectError(case.err, try stingerOf(case.source));

    // A package's text cannot spell a non-finite number, but its bytes can carry one.
    var bad: Playlist = .{ .track_count = 1 };
    bad.tempo = std.math.nan(f32);
    try testing.expectError(error.InvalidTempo, bad.validate());
    bad = .{ .track_count = 1, .crossfade = std.math.inf(f32) };
    try testing.expectError(error.InvalidCrossfade, bad.validate());
    const loud: Stinger = .{ .sound = .none, .gain = std.math.nan(f32) };
    try testing.expectError(error.InvalidGain, loud.validate());
}
