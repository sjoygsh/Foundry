//! `settings.fset` — the user's own preferences, on disk.
//!
//! Three kinds of input decide how an application starts, and ADR-0031 keeps them apart:
//! **bootstrap** facts the host supplies, **defaults** that are ordinary content, and the
//! **preferences** in this file. They are separated because they answer to different
//! authorities. Content may say how loud the game is by default; it may not say where the
//! game reads files from, which packages are enabled, or whether native code runs. A
//! preference may override a default; it may never become authority.
//!
//! **This is not a content package.** It has no manifest, no content id, no load order and
//! no place in the store — it is one application's local state, and giving it package
//! semantics would put private state into the mod pipeline for nothing (ADR-0031).
//!
//! **The layout is `data`'s, not a second one.** A settings file is one field block
//! written against a registered schema, exactly the way `.fpk` writes a record and a save
//! writes a component (`content-schemas.md` §5.3). The envelope below is the only new
//! thing: a header naming which schema the block belongs to, and how long its two sections
//! are. Two encoders of one layout would be two things that drift apart, and that drift
//! reads as a field returning zero rather than as an error.
//!
//! **Everything here is untrusted.** The file is ordinary user-writable state; it can be
//! hand-edited, truncated by a full disk, or left behind by a build that knows more than
//! this one. Every length, offset and presence bit is checked before it is believed, and
//! anything this build cannot read is *preserved* rather than replaced — a newer file that
//! an older build silently overwrites is a user's settings destroyed by an update.
//!
//! Design: `docs/design/distribution.md` §5 and §6; ADR-0031.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.app);

/// Four bytes that say what the file is before anything in it is trusted.
pub const magic = "FSET";

/// Bumped when the envelope below changes. In a field rather than in the magic, for the
/// reason `.fpk` puts its own there: a file from a future build reports "envelope version
/// 2, this build understands 1" rather than "not a settings file", and the difference
/// decides whether it is preserved or replaced.
pub const envelope_version: u32 = 1;

/// ```
/// 0   magic            [4]u8   "FSET"
/// 4   envelope_version u32
/// 8   schema_id        u64     the application's settings SchemaId
/// 16  schema_version   u32
/// 20  flags            u32     reserved, must be zero
/// 24  fields_len       u32     field section byte length
/// 28  strings_len      u32     string section byte length
/// 32  field bytes, then string bytes — exactly, with nothing after them
/// ```
pub const header_size = 32;

/// The name the file has under an application's user-data directory.
pub const default_leaf = "settings.fset";

/// Hard bounds on a settings file.
///
/// Deliberately far smaller than `data.Limits`, and for a different reason. A content
/// package is authored and may legitimately be large; this is a handful of values a person
/// changed in a menu. A settings file that wants a megabyte is not a settings file, and the
/// cheapest place to say so is before anything is allocated for it.
pub const Limits = struct {
    /// The whole file, header included.
    max_file_bytes: usize = 64 << 10,
    /// Fields in the settings schema itself.
    max_fields: u32 = 64,
    /// Nesting of inline structs within the schema.
    max_depth: u32 = 4,
    max_list_elements: usize = 128,
    max_string_bytes: usize = 1024,

    pub const default: Limits = .{};

    /// The shape `data` wants for the same bounds, for the one read that consults them.
    pub fn dataLimits(self: Limits) data.Limits {
        return .{
            .max_nesting_depth = self.max_depth,
            .max_list_elements = self.max_list_elements,
        };
    }
};

// ---------------------------------------------------------------------------
// The schema a settings file may describe
// ---------------------------------------------------------------------------

pub const SchemaError = error{
    /// The schema has no id, so a file could not say which schema it belongs to.
    MissingSchemaId,
    /// Version 0. Versions start at 1 so "unset" and "first" are distinguishable.
    InvalidVersion,
    TooManyFields,
    TooDeep,
};

/// Whether a schema is one a settings file may be written against.
///
/// Checked at both ends and not only at registration, because `data.Registry`'s bounds are
/// a content package's and are thousands of fields wide. A settings *file* is smaller by
/// two orders of magnitude, and the limit that matters is the one the reader enforces.
pub fn checkSchema(schema: data.Schema, limits: Limits) SchemaError!void {
    if (schema.id.isNone()) return error.MissingSchemaId;
    if (schema.version == 0) return error.InvalidVersion;
    if (schema.fields.len > limits.max_fields) return error.TooManyFields;
    try checkDepth(schema.fields, limits, 1);
}

fn checkDepth(fields: []const data.Field, limits: Limits, depth: u32) SchemaError!void {
    if (depth > limits.max_depth) return error.TooDeep;
    for (fields) |field| try checkTypeDepth(field.type, limits, depth);
}

fn checkTypeDepth(t: data.FieldType, limits: Limits, depth: u32) SchemaError!void {
    switch (t) {
        .nested => |nested| try checkDepth(nested, limits, depth + 1),
        .list => |elem| try checkTypeDepth(elem.*, limits, depth + 1),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

pub const EncodeError = error{
    /// The caller supplied a different number of slots than the schema has fields. A
    /// mistake in the calling code: a slot list that is short would silently drop the
    /// preferences at the end.
    FieldCountMismatch,
    /// A value the schema cannot hold, or one a settings file will not carry — a
    /// nonfinite float above all.
    ValueRefused,
    /// The encoded file would be past `Limits.max_file_bytes`.
    TooLarge,
} || SchemaError || Allocator.Error;

/// Writes `values` as a settings file.
///
/// `values` is one slot per schema field, in field order; `null` means the user has no
/// preference for that field and the file simply omits it. Omission is the whole of how a
/// preference and a default are told apart on the way back in — a field that is absent is
/// one the application answers from content or from its built-in fallback.
///
/// The bytes are a function of the values alone: field order is the schema's, strings are
/// interned in the order the fields are written, and nothing consults a clock, an address
/// or the environment. Two encodes of equal values are byte-identical (I9).
pub fn encode(
    gpa: Allocator,
    schema: data.Schema,
    values: []const ?data.Value,
    limits: Limits,
    out: *std.ArrayList(u8),
) EncodeError!void {
    try checkSchema(schema, limits);
    if (values.len != schema.fields.len) return error.FieldCountMismatch;

    const data_limits = limits.dataLimits();
    for (values, 0..) |maybe, i| {
        const v = maybe orelse continue;
        data.schema.checkValue(schema.fields[i].type, v, data_limits, 0) catch
            return error.ValueRefused;
        try checkEncodable(v, limits);
    }

    var writer: data.BlockWriter = .{ .gpa = gpa };
    defer writer.deinit();

    const block = writer.begin(schema.fields) catch |err| return mapBlockError(err);
    for (values, 0..) |maybe, i| {
        const v = maybe orelse continue;
        block.set(i, v) catch |err| return mapBlockError(err);
    }

    const fields_len = std.math.cast(u32, writer.fields.items.len) orelse return error.TooLarge;
    const strings_len = std.math.cast(u32, writer.strings.items.len) orelse return error.TooLarge;
    const total = @as(u64, header_size) + fields_len + strings_len;
    if (total > limits.max_file_bytes) return error.TooLarge;

    try out.ensureUnusedCapacity(gpa, @intCast(total));
    out.appendSliceAssumeCapacity(magic);
    appendU32(out, envelope_version);
    appendU64(out, schema.id.hash);
    appendU32(out, schema.version);
    appendU32(out, 0); // flags
    appendU32(out, fields_len);
    appendU32(out, strings_len);
    out.appendSliceAssumeCapacity(writer.fields.items);
    out.appendSliceAssumeCapacity(writer.strings.items);
}

/// The layout's own errors, in this file's vocabulary.
///
/// `ValueTypeMismatch` cannot reach here — every value was checked against its field
/// above — but mapping it is cheaper than an `unreachable` that would become a crash if
/// that ever stopped being true.
fn mapBlockError(err: data.fpk.BlockError) EncodeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => error.TooLarge,
        error.ValueTypeMismatch => error.ValueRefused,
    };
}

/// Value-level bounds the schema does not express.
///
/// A nonfinite float is refused at both ends deliberately. It is a legal `f64` and an
/// illegal preference: nothing a person can choose in a menu is a NaN, so one in the file
/// is either corruption or someone probing, and letting it through means every consumer of
/// every setting has to defend against it separately.
fn checkEncodable(v: data.Value, limits: Limits) EncodeError!void {
    switch (v) {
        .float => |f| if (!std.math.isFinite(f)) return error.ValueRefused,
        .string => |s| if (s.len > limits.max_string_bytes) return error.ValueRefused,
        .list => |items| {
            if (items.len > limits.max_list_elements) return error.ValueRefused;
            for (items) |item| try checkEncodable(item, limits);
        },
        .nested => |named| for (named) |nv| try checkEncodable(nv.value, limits),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

pub const DecodeError = error{
    /// Not a settings file at all.
    NotSettings,
    /// Written by a build that understands more than this one.
    FutureVersion,
    /// Written against an earlier version of this schema, which this build has no
    /// conversion for. Preserved rather than guessed at: the presence bitmap's width
    /// changes with the field count, so an older block's fields are not at the offsets
    /// this build would read them from, and "mostly right" is the worst available answer.
    PastVersion,
    /// Another application's settings, or another schema's.
    ForeignSchema,
    /// This build's file, and damaged.
    Malformed,
    /// Larger than this build is willing to read, so it cannot be judged at all.
    TooLarge,
} || SchemaError || Allocator.Error;

/// Reads a settings file written against `schema`.
///
/// The returned fields **borrow `bytes`** and are valid only while it is: a settings file
/// is read once at startup and the values are copied out of it, so there is nothing to be
/// gained by allocating a second copy of what is already in memory.
///
/// Every field is walked before this returns, not lazily as the caller reads. A file whose
/// third field is corrupt has to be refused whether or not anybody asks for the third
/// field, because the decision it drives — use this file, or use defaults — is made once.
pub fn decode(
    gpa: Allocator,
    bytes: []const u8,
    schema: data.Schema,
    limits: Limits,
) DecodeError!data.fpk.Fields {
    try checkSchema(schema, limits);
    if (bytes.len > limits.max_file_bytes) return error.TooLarge;
    if (bytes.len < header_size) return error.NotSettings;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotSettings;

    const file_envelope = readU32(bytes, 4);
    if (file_envelope > envelope_version) return error.FutureVersion;
    if (file_envelope != envelope_version) return error.NotSettings;

    if (readU64(bytes, 8) != schema.id.hash) return error.ForeignSchema;
    const file_schema_version = readU32(bytes, 16);
    if (file_schema_version > schema.version) return error.FutureVersion;
    if (file_schema_version < schema.version) return error.PastVersion;

    // Reserved bits are reserved: a build that does not know what a flag means must not
    // decide it did not matter.
    if (readU32(bytes, 20) != 0) return error.Malformed;

    const fields_len = readU32(bytes, 24);
    const strings_len = readU32(bytes, 28);
    if (@as(u64, header_size) + fields_len + strings_len != bytes.len) return error.Malformed;

    const blocks: data.Blocks = .{
        .fields = bytes[header_size..][0..fields_len],
        .strings = bytes[header_size + fields_len ..][0..strings_len],
        .max_list_elements = limits.max_list_elements,
    };
    const view = blocks.blockAt(0, schema.fields) orelse return error.Malformed;
    try checkPresence(view, schema.fields.len);
    try checkReadable(gpa, view, limits);
    return view;
}

/// Refuses presence bits that address fields the schema does not have.
///
/// They can only be set by something other than this encoder, and a file disagreeing with
/// its own schema about how many fields exist is exactly the kind of small wrongness that
/// is cheap to catch here and unbounded to chase later.
fn checkPresence(view: data.fpk.Fields, field_count: usize) DecodeError!void {
    const used = data.fpk.presenceBytes(field_count);
    if (used == 0) return;
    if (used > view.block.len) return error.Malformed;
    const used_bits = field_count % 8;
    if (used_bits == 0) return;
    const valid: u8 = @intCast((@as(u16, 1) << @intCast(used_bits)) - 1);
    if (view.block[used - 1] & ~valid != 0) return error.Malformed;
}

/// Reads every present field once, so that a decode either succeeds whole or fails.
fn checkReadable(gpa: Allocator, view: data.fpk.Fields, limits: Limits) DecodeError!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var i: u32 = 0;
    while (i < view.count()) : (i += 1) {
        const read = view.valueAt(arena.allocator(), i) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        try checkDecoded(read orelse continue, limits);
    }
}

fn checkDecoded(v: data.Value, limits: Limits) DecodeError!void {
    switch (v) {
        .float => |f| if (!std.math.isFinite(f)) return error.Malformed,
        .string => |s| if (s.len > limits.max_string_bytes) return error.Malformed,
        .list => |items| {
            if (items.len > limits.max_list_elements) return error.Malformed;
            for (items) |item| try checkDecoded(item, limits);
        },
        .nested => |named| for (named) |nv| try checkDecoded(nv.value, limits),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Migrations
// ---------------------------------------------------------------------------

/// One step of a settings schema's history: how a file at `from.version` becomes a file at
/// the next version.
///
/// **Ordinary code over the old version's values** (`mod-management.md` §6). There is no
/// generic schema diff: a framework guessing at intent would guess wrong exactly when a
/// field changed meaning rather than shape, and that is when a migration matters.
///
/// An application lists one per older version, oldest first, ending at the version before
/// its current one. A file at an older version is converted in memory when it is loaded,
/// and nothing is written until the application saves; before the first save at the new
/// version, the old file is copied once to `<leaf>.v<old>`.
pub const Migration = struct {
    /// The schema a file at this step was written against, exactly as it was.
    from: data.Schema,
    /// Fills `new`, one slot per field of the next version and all null on entry, from
    /// `old`, one slot per field of `from`. Anything it allocates comes from `arena`, which
    /// lives as long as the values do.
    convert: *const fn (arena: Allocator, old: []const ?data.Value, new: []?data.Value) Allocator.Error!void,
};

/// The chain from `version` to `schema`, or null when `migrations` cannot make that walk:
/// no step starts there, a step is missing, or a step names another schema.
fn chainFrom(migrations: []const Migration, schema: data.Schema, version: u32) ?[]const Migration {
    const start = for (migrations, 0..) |m, i| {
        if (m.from.version == version) break i;
    } else return null;
    const chain = migrations[start..];
    for (chain, 0..) |m, i| {
        if (!m.from.id.eql(schema.id)) return null;
        if (m.from.version != version + i) return null;
    }
    if (chain[chain.len - 1].from.version + 1 != schema.version) return null;
    return chain;
}

/// A file's values, one optional per field, copied into `arena`.
fn valuesOf(arena: Allocator, fields: data.fpk.Fields, count: usize) DecodeError![]?data.Value {
    const out = try arena.alloc(?data.Value, count);
    for (out, 0..) |*slot, i| {
        slot.* = fields.valueAt(arena, @intCast(i)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
    }
    return out;
}

/// Converts `bytes`, a file at an older version, into `schema`'s current version and
/// encodes the result. Null when there is no chain for it.
fn migrate(
    gpa: Allocator,
    bytes: []const u8,
    schema: data.Schema,
    migrations: []const Migration,
    limits: Limits,
) (DecodeError || EncodeError)!?[]u8 {
    const chain = chainFrom(migrations, schema, readU32(bytes, 16)) orelse return null;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const fields = try decode(gpa, bytes, chain[0].from, limits);
    var values = try valuesOf(arena.allocator(), fields, chain[0].from.fields.len);
    for (chain, 0..) |step, i| {
        const next = if (i + 1 < chain.len) chain[i + 1].from else schema;
        const converted = try arena.allocator().alloc(?data.Value, next.fields.len);
        @memset(converted, null);
        try step.convert(arena.allocator(), values, converted);
        values = converted;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try encode(gpa, schema, values, limits, &out);
    return try out.toOwnedSlice(gpa);
}

fn optionalEql(a: ?data.Value, b: ?data.Value) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

// ---------------------------------------------------------------------------
// Resolving a value out of the layers that may supply it
// ---------------------------------------------------------------------------

/// Where a resolved value came from.
///
/// Kept beside the value rather than thrown away, because two decisions need it. A content
/// hot reload may move a default and must **not** move a field the user has chosen
/// (`distribution.md` §5), which is a question about origin. And a preference is only worth
/// writing back when it is the user's; writing back a content default would freeze it, so
/// that the package that supplied it could never change it again.
pub const Origin = enum {
    /// The application's own built-in value. Used when nothing usable was supplied.
    fallback,
    /// An ordinary content record — a default a package author chose, which a mod may
    /// override by ordinary content override.
    content,
    /// The user's own saved preference.
    user,
};

pub fn Resolved(comptime T: type) type {
    return struct {
        value: T,
        origin: Origin,

        pub fn isUser(self: @This()) bool {
            return self.origin == .user;
        }
    };
}

/// One place a value may come from: a block of fields, and the schema that names them.
///
/// The two settings layers have different shapes on disk — a content record lives in a
/// package and a preference lives in `settings.fset` — and exactly the same shape in
/// memory, because both are field blocks (`content-schemas.md` §5.3). That is what lets one
/// resolution walk read both.
pub const Layer = struct {
    schema: data.Schema,
    fields: data.fpk.Fields,
    origin: Origin,
};

/// The highest-priority layer that supplies a usable value for `name`, or `fallback`.
///
/// `layers` is given in **increasing** priority, and is walked backwards. A layer that
/// omits the field, spells it as another type, or supplies a number outside `[min, max]` is
/// skipped rather than fatal — which is §4's "validated content defaults -> valid user
/// overrides" made literal. A preference a person edited by hand into nonsense costs them
/// that preference and nothing else.
pub fn resolveInt(
    comptime T: type,
    name: []const u8,
    fallback: T,
    min: T,
    max: T,
    layers: []const ?Layer,
) Resolved(T) {
    var i = layers.len;
    while (i > 0) {
        i -= 1;
        const layer = layers[i] orelse continue;
        const index = layer.schema.fieldIndex(name) orelse continue;
        const raw = (layer.fields.intAt(index) catch null) orelse continue;
        const value = std.math.cast(T, raw) orelse continue;
        if (value < min or value > max) {
            log.warn("settings: {s} {s}={d} is outside {d}..{d}; ignoring it", .{
                @tagName(layer.origin), name, value, min, max,
            });
            continue;
        }
        return .{ .value = value, .origin = layer.origin };
    }
    return .{ .value = fallback, .origin = .fallback };
}

/// The float counterpart, with the same rules and one more: a nonfinite value never wins.
///
/// The codec already refuses one from a file, so this is the layer that catches a nonfinite
/// *content* default — a package is as capable of holding a NaN as a preferences file, and
/// it reaches the same mixer gain if nobody stops it.
pub fn resolveFloat(
    comptime T: type,
    name: []const u8,
    fallback: T,
    min: T,
    max: T,
    layers: []const ?Layer,
) Resolved(T) {
    var i = layers.len;
    while (i > 0) {
        i -= 1;
        const layer = layers[i] orelse continue;
        const index = layer.schema.fieldIndex(name) orelse continue;
        const raw = (layer.fields.floatAt(index) catch null) orelse continue;
        const value: T = @floatCast(raw);
        if (!std.math.isFinite(value) or value < min or value > max) {
            log.warn("settings: {s} {s}={d} is not a usable value in {d}..{d}; ignoring it", .{
                @tagName(layer.origin), name, value, min, max,
            });
            continue;
        }
        return .{ .value = value, .origin = layer.origin };
    }
    return .{ .value = fallback, .origin = .fallback };
}

/// A set of content-id spellings — the packages a player has enabled.
///
/// Sorted and unique, which is what makes writing it canonical: the same set encodes to the
/// same bytes whatever order it was assembled in (I9). It holds **spellings** rather than
/// hashes because a settings file has to name a package in a way a person can read and a
/// future build can still resolve, and because a hash cannot be turned back into a name for
/// a diagnostic.
///
/// It is a *selected set* and nothing more. It does not order anything — `mod` resolves
/// order from the manifests — and enabling a package is not consent to run native code
/// (ADR-0031).
pub const IdSet = struct {
    /// Owned, sorted, unique.
    ids: []const []u8 = &.{},

    pub fn deinit(self: *IdSet, gpa: Allocator) void {
        for (self.ids) |id| gpa.free(id);
        gpa.free(self.ids);
        self.* = undefined;
    }

    /// Reads the set from one layer's list field.
    ///
    /// An absent field is an empty set. A field holding anything that is not a content id,
    /// or naming one twice, yields an empty set and a warning: a selection that is
    /// partly understood is worse than none, because the packages it silently dropped are
    /// the ones the player would notice missing.
    pub fn read(gpa: Allocator, layer: Layer, name: []const u8, max: usize) Allocator.Error!IdSet {
        const index = layer.schema.fieldIndex(name) orelse return .{};
        const list = (layer.fields.listAt(index) catch null) orelse return .{};
        if (list.len > max) {
            log.warn("settings: '{s}' names {d} packages, past the {d} allowed", .{ name, list.len, max });
            return .{};
        }

        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |item| gpa.free(item);
            owned.deinit(gpa);
        }

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        var i: u32 = 0;
        while (i < list.len) : (i += 1) {
            const value = (list.valueAt(arena.allocator(), i) catch null) orelse return .{};
            if (value != .string) return .{};
            _ = data.contentId(value.string) catch {
                log.warn("settings: '{s}' is not a content id; ignoring the whole selection", .{value.string});
                return .{};
            };
            for (owned.items) |already| {
                if (std.mem.eql(u8, already, value.string)) {
                    log.warn("settings: '{s}' is named twice; ignoring the whole selection", .{value.string});
                    return .{};
                }
            }
            try owned.append(gpa, try gpa.dupe(u8, value.string));
        }

        const ids = try owned.toOwnedSlice(gpa);
        std.mem.sort([]u8, ids, {}, lessThanId);
        return .{ .ids = ids };
    }

    /// The set as a value a list field can hold. Borrows `buf`, which must be at least as
    /// long as the set, and the set's own strings.
    pub fn toValue(self: IdSet, buf: []data.Value) data.Value {
        for (self.ids, 0..) |id, i| buf[i] = .{ .string = id };
        return .{ .list = buf[0..self.ids.len] };
    }

    pub fn contains(self: IdSet, id: []const u8) bool {
        for (self.ids) |held| {
            if (std.mem.eql(u8, held, id)) return true;
        }
        return false;
    }
};

fn lessThanId(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

/// What a load found, and what it means for writing.
pub const State = enum {
    /// The file was read and decoded.
    loaded,
    /// Nothing is stored yet. The ordinary first run.
    absent,
    /// This build's file, and unreadable. Defaults now; the next explicit save copies it
    /// aside before replacing it.
    damaged,
    /// A file this build must not touch: a newer envelope, a different schema version, a
    /// different schema, or one too large to judge. Defaults now, and **no writing** —
    /// an older build quietly overwriting newer preferences is the failure this exists to
    /// prevent.
    preserved,
    /// The user-data directory could not be read. Defaults now, and no writing.
    unavailable,
};

/// A settings file, and what was found there. Owns the bytes the fields borrow.
pub const Loaded = struct {
    state: State,
    bytes: []u8 = &.{},
    /// The decoded fields, or null whenever `state` is not `.loaded`.
    fields: ?data.fpk.Fields = null,
    /// The version the file on disk had, when it was older and `bytes` is its conversion.
    migrated_from: ?u32 = null,
    /// That older file, exactly as read, when there was one.
    original: []u8 = &.{},

    pub fn deinit(self: *Loaded, gpa: Allocator) void {
        if (self.bytes.len != 0) gpa.free(self.bytes);
        if (self.original.len != 0) gpa.free(self.original);
        self.* = undefined;
    }
};

pub const SaveError = error{
    /// The stored file is one this build must not replace.
    Preserved,
} || EncodeError || platform.os.FileError;

/// One application's settings file, under a directory the host chose.
///
/// Opt-in: an application that keeps no preferences constructs none of this and pays
/// nothing for it. The engine does not own one, because the engine does not own an
/// application's configuration (ADR-0031).
pub const Storage = struct {
    os: *platform.Os,
    /// The user-data directory, absolute and borrowed. It is a capability: every path
    /// below is confined to it and no caller can name a file outside it.
    dir: []const u8,
    leaf: []const u8 = default_leaf,
    limits: Limits = .default,
    /// How files at older versions of the schema become the current one. Empty: an older
    /// file is kept and never replaced, as a newer one is.
    migrations: []const Migration = &.{},

    /// Cleared by a load that found something this build must not replace. A `Storage`
    /// nobody has loaded from starts writable: it has nothing it could destroy.
    writable: bool = true,
    /// Set by a load that found a damaged file, so the next save copies it aside first.
    backup_pending: bool = false,

    pub const OpenError = error{
        /// A relative user-data root. Refused rather than resolved, because resolving one
        /// means writing beside whatever directory the process happens to be in — an app
        /// bundle, or a read-only install (`distribution.md` §6).
        RootNotAbsolute,
        /// A leaf that is not one ordinary file name.
        InvalidLeaf,
    };

    pub fn open(os: *platform.Os, dir: []const u8, leaf: []const u8) OpenError!Storage {
        if (!platform.os.isAbsolute(dir)) return error.RootNotAbsolute;
        if (!platform.os.isSafeRelativePath(leaf)) return error.InvalidLeaf;
        if (std.mem.indexOfScalar(u8, leaf, '/') != null) return error.InvalidLeaf;
        // Bounded by what a replacement can name, not by what a filesystem can hold: a
        // leaf `Os` cannot build a temporary sibling for is one that could be loaded and
        // never saved, and finding that out on the first save is finding it out too late.
        if (leaf.len + backup_suffix.len > platform.os.max_replaceable_name) return error.InvalidLeaf;
        return .{ .os = os, .dir = dir, .leaf = leaf };
    }

    /// Reads the stored preferences, or says why there are none to read.
    ///
    /// Never fails: every outcome is one an application has to handle at startup anyway,
    /// and turning "the user has not saved anything yet" into an error would make the
    /// ordinary first run the exceptional path.
    pub fn load(self: *Storage, gpa: Allocator, schema: data.Schema) Allocator.Error!Loaded {
        // A load is the whole of what this knows about the file, so it decides both
        // answers outright rather than narrowing ones an earlier load left behind. A
        // directory that was unreadable a moment ago and is readable now is a `Storage`
        // that may write again.
        const loaded = try self.inspect(gpa, schema, true);
        self.writable = switch (loaded.state) {
            .preserved, .unavailable => false,
            .loaded, .absent, .damaged => true,
        };
        self.backup_pending = loaded.state == .damaged;
        return loaded;
    }

    /// The file as it is now, converted when it is older. `report` says whether to log
    /// what was found: a load does, and the re-read before a save does not repeat it.
    fn inspect(self: *Storage, gpa: Allocator, schema: data.Schema, report: bool) Allocator.Error!Loaded {
        const file = self.os.readFileConfined(gpa, self.dir, self.leaf, self.limits.max_file_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The file, or the directory holding it, is not there: a first run.
            error.FileNotFound => return .{ .state = .absent },
            error.FileTooLarge => {
                if (report) log.warn("settings: '{s}' is larger than {d} bytes; keeping it and using defaults", .{
                    self.leaf, self.limits.max_file_bytes,
                });
                return .{ .state = .preserved };
            },
            else => {
                if (report) log.warn("settings: '{s}' could not be read ({t}); using defaults", .{ self.leaf, err });
                return .{ .state = .unavailable };
            },
        };
        const fields = decode(gpa, file.bytes, schema, self.limits) catch |err| switch (err) {
            error.OutOfMemory => {
                gpa.free(file.bytes);
                return error.OutOfMemory;
            },
            error.PastVersion => return self.convert(gpa, file.bytes, schema, report),
            else => {
                gpa.free(file.bytes);
                return self.refusal(err, report);
            },
        };
        return .{ .state = .loaded, .bytes = file.bytes, .fields = fields };
    }

    /// An older file, converted in memory. The file itself is not touched until a save.
    /// Takes ownership of `original`.
    fn convert(self: *Storage, gpa: Allocator, original: []u8, schema: data.Schema, report: bool) Allocator.Error!Loaded {
        const version = readU32(original, 16);
        const converted = migrate(gpa, original, schema, self.migrations, self.limits) catch |err| {
            gpa.free(original);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                // The older file itself is damaged: as for a current one, copy it aside.
                error.NotSettings, error.Malformed => self.refusal(error.Malformed, report),
                else => blk: {
                    if (report) log.warn("settings: '{s}' at version {d} did not convert ({t}); keeping it and using defaults", .{ self.leaf, version, err });
                    break :blk .{ .state = .preserved };
                },
            };
        } orelse {
            gpa.free(original);
            if (report) log.warn("settings: '{s}' is at version {d}, which this build cannot convert; keeping it and using defaults", .{ self.leaf, version });
            return .{ .state = .preserved };
        };
        const fields = decode(gpa, converted, schema, self.limits) catch |err| {
            // Encoded against this schema a moment ago; a failure here is the conversion's.
            gpa.free(converted);
            gpa.free(original);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (report) log.warn("settings: '{s}' converted to something unreadable ({t}); keeping it and using defaults", .{ self.leaf, err });
            return .{ .state = .preserved };
        };
        if (report) log.info("settings: '{s}' converted from version {d} to {d}; written at the next save", .{ self.leaf, version, schema.version });
        return .{ .state = .loaded, .bytes = converted, .fields = fields, .migrated_from = version, .original = original };
    }

    /// What a file this build will not use means, said once when `report` asks.
    fn refusal(self: *Storage, err: DecodeError, report: bool) Loaded {
        switch (err) {
            error.FutureVersion, error.PastVersion, error.ForeignSchema, error.TooLarge => {
                if (report) log.warn("settings: '{s}' was written by another build or schema ({t}); keeping it and using defaults", .{ self.leaf, err });
                return .{ .state = .preserved };
            },
            error.MissingSchemaId, error.InvalidVersion, error.TooManyFields, error.TooDeep => {
                // The application's own schema, not the file. Nothing on disk is at fault
                // and nothing on disk may be replaced on account of it.
                if (report) log.warn("settings: the schema this build asked for is not one a settings file may hold ({t})", .{err});
                return .{ .state = .unavailable };
            },
            error.NotSettings, error.Malformed => {
                if (report) log.warn("settings: '{s}' is damaged ({t}); using defaults, and saving will copy it aside", .{ self.leaf, err });
                return .{ .state = .damaged };
            },
            error.OutOfMemory => unreachable,
        }
    }

    /// Writes `values`, merged over the file as it is now, replacing what is stored.
    ///
    /// **Merged by field** (`mod-management.md` §6). The file is read again, and a field
    /// whose value in `values` still equals its value in `baseline` — what this process
    /// read, or last wrote — is one this process did not change, so the file's current
    /// value is kept. Two running instances therefore keep each other's changes to
    /// different fields; the same field changed in both is the last writer's. With no
    /// `baseline`, every field is this process's.
    ///
    /// A file that is older now is converted first, and copied once to `<leaf>.v<old>`
    /// before it is replaced. A newer one is never replaced. The directory is created here
    /// and not at startup: an application that never changes a preference leaves nothing
    /// behind, and a run that only reads never has to be able to write.
    pub fn save(
        self: *Storage,
        gpa: Allocator,
        schema: data.Schema,
        values: []const ?data.Value,
        baseline: ?[]const ?data.Value,
    ) SaveError!void {
        if (!self.writable) return error.Preserved;
        if (values.len != schema.fields.len) return error.FieldCountMismatch;
        if (baseline) |b| if (b.len != values.len) return error.FieldCountMismatch;

        var current = try self.inspect(gpa, schema, false);
        defer current.deinit(gpa);
        switch (current.state) {
            .preserved => {
                self.writable = false;
                return error.Preserved;
            },
            .damaged => self.backup_pending = true,
            .loaded, .absent, .unavailable => {},
        }

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const merged = try arena.allocator().dupe(?data.Value, values);
        if (baseline) |base| if (current.fields) |fields| {
            const now: []const ?data.Value = valuesOf(arena.allocator(), fields, schema.fields.len) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Decoded a moment ago; a field that will not read now keeps ours.
                else => values,
            };
            for (merged, base, now) |*slot, before, disk| {
                if (optionalEql(slot.*, before)) slot.* = disk;
            }
        };

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        // Encoded before anything on disk is touched. A value the schema refuses must not
        // be able to cost the user the settings they already had.
        try encode(gpa, schema, merged, self.limits, &bytes);

        try self.os.createDirPath(self.dir);
        if (self.backup_pending) self.copyAside(gpa);
        if (current.migrated_from) |version| try self.keepOlder(current.original, version);

        const durability = try self.os.replaceFileConfined(
            self.dir,
            self.leaf,
            bytes.items,
            self.limits.max_file_bytes,
        );
        if (durability == .entry_unflushed) {
            log.debug("settings: '{s}' was replaced but its directory entry was not flushed", .{self.leaf});
        }
    }

    /// Keeps a file of an older version as `<leaf>.v<version>`, once: the first save at the
    /// new version copies it, and later ones leave that copy alone. Not best effort, unlike
    /// a damaged file's copy: this is what a player who goes back to an older build puts
    /// back, so a save that cannot keep it does not replace it either.
    fn keepOlder(self: *Storage, original: []const u8, version: u32) SaveError!void {
        var name_buf: [platform.os.max_replaceable_name + 16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}.v{d}", .{ self.leaf, version }) catch return error.InvalidPath;
        if (self.os.statFileConfined(self.dir, name)) |_| return else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        _ = try self.os.replaceFileConfined(self.dir, name, original, self.limits.max_file_bytes);
        log.info("settings: the version {d} file was kept as '{s}'", .{ version, name });
    }

    /// Moves a damaged file out of the way, once, before it is replaced.
    ///
    /// Best effort on purpose: the point is to give a user something to look at, not to
    /// make saving depend on a file that is already broken. A backup that cannot be
    /// written is reported and the save goes ahead — refusing to save would leave the
    /// user unable to fix their settings through the game that broke them.
    fn copyAside(self: *Storage, gpa: Allocator) void {
        self.backup_pending = false;

        var name_buf: [platform.os.max_replaceable_name + backup_suffix.len]u8 = undefined;
        const backup = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ self.leaf, backup_suffix }) catch return;

        const read = self.os.readFileConfined(gpa, self.dir, self.leaf, self.limits.max_file_bytes) catch |err| {
            log.warn("settings: the damaged '{s}' could not be copied aside ({t})", .{ self.leaf, err });
            return;
        };
        defer gpa.free(read.bytes);

        _ = self.os.replaceFileConfined(self.dir, backup, read.bytes, self.limits.max_file_bytes) catch |err| {
            log.warn("settings: '{s}' could not be written ({t})", .{ backup, err });
            return;
        };
        log.info("settings: the damaged '{s}' was kept as '{s}'", .{ self.leaf, backup });
    }
};

/// How an application keeps its settings file: where it is, whether this run may write it,
/// and how long a change waits before it does.
pub const FileOptions = struct {
    leaf: []const u8 = default_leaf,
    limits: Limits = .default,
    /// Whether this run may write at all. A scripted run with a frame budget says `false`:
    /// a budget marks a run nobody is watching, and such a run must leave a person's
    /// choices exactly as it found them (`distribution.md` §4).
    persist: bool = true,
    /// Frames a change waits before it is written. A drag reports every frame it moves;
    /// without this the file would be rewritten sixty times a second while a slider is held
    /// (`distribution.md` §6).
    settle_frames: u32 = 60,
    /// The schema's history, oldest first (`Migration`). Borrowed for the file's life.
    migrations: []const Migration = &.{},
};

/// An application's settings file, from opening it to deciding when to write it.
///
/// The part of keeping preferences that is the same for every application, so that it is
/// written once. What stays the application's: which fields exist, what they mean, what is
/// a usable value, and what to do with one (ADR-0031). This owns none of that and could not
/// name a window or a volume if it wanted to.
pub const File = struct {
    /// The user-data directory, owned, and borrowed by `storage`.
    dir: []u8 = &.{},
    storage: ?Storage = null,
    /// What the last load found. Its bytes outlive the load, because a `Layer` reads them.
    loaded: Loaded = .{ .state = .absent },
    persist: bool = false,
    settle_frames: u32 = 60,

    /// A change that has not reached the disk.
    dirty: bool = false,
    settled: u32 = 0,
    /// The values as read, or as this process last wrote them: what a save compares
    /// against to know which fields this process changed.
    baseline: ?[]?data.Value = null,
    baseline_arena: ?std.heap.ArenaAllocator = null,

    /// Opens the application's settings under the OS's per-user location and reads them.
    ///
    /// **Never fails.** Every reason there might be nothing to read — no user directory at
    /// all, one that cannot be read, a file a newer build wrote — is a reason to carry on
    /// with defaults. An application that refused to start because a preference was missing
    /// would be worse in every case than one that starts without it.
    pub fn open(
        gpa: Allocator,
        os: *platform.Os,
        schema: data.Schema,
        options: FileOptions,
    ) Allocator.Error!File {
        const dir = os.userDataDirAlloc(gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("settings: no user data directory ({t}); preferences are not kept", .{err});
                return .{};
            },
        };
        errdefer gpa.free(dir);

        var storage = Storage.open(os, dir, options.leaf) catch |err| {
            log.warn("settings: '{s}' cannot hold preferences ({t})", .{ dir, err });
            gpa.free(dir);
            return .{};
        };
        storage.limits = options.limits;
        storage.migrations = options.migrations;

        var loaded = try storage.load(gpa, schema);
        errdefer loaded.deinit(gpa);
        var baseline_arena: ?std.heap.ArenaAllocator = null;
        errdefer if (baseline_arena) |*a| a.deinit();
        var baseline: ?[]?data.Value = null;
        if (loaded.fields) |fields| {
            baseline_arena = .init(gpa);
            baseline = valuesOf(baseline_arena.?.allocator(), fields, schema.fields.len) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Decoded whole a moment ago; nothing to compare against is the safe answer.
                else => null,
            };
        }
        return .{
            .dir = dir,
            .storage = storage,
            .loaded = loaded,
            .persist = options.persist and storage.writable,
            .settle_frames = options.settle_frames,
            .baseline = baseline,
            .baseline_arena = baseline_arena,
        };
    }

    pub fn deinit(self: *File, gpa: Allocator) void {
        self.loaded.deinit(gpa);
        if (self.baseline_arena) |*a| a.deinit();
        if (self.dir.len != 0) gpa.free(self.dir);
        self.* = .{};
    }

    /// The file as it was on disk before it was converted, read against `older`, when it
    /// was at exactly that version. A host moving a field out of its settings reads the
    /// old value here (`mod-management.md` §6).
    pub fn older(self: File, gpa: Allocator, older_schema: data.Schema) ?Layer {
        const from = self.loaded.migrated_from orelse return null;
        if (from != older_schema.version) return null;
        const limits = if (self.storage) |s| s.limits else Limits.default;
        const fields = decode(gpa, self.loaded.original, older_schema, limits) catch return null;
        return .{ .schema = older_schema, .fields = fields, .origin = .user };
    }

    pub fn state(self: File) State {
        return self.loaded.state;
    }

    /// The saved preferences as a layer to resolve against, or null when there are none.
    pub fn layer(self: File, schema: data.Schema) ?Layer {
        const fields = self.loaded.fields orelse return null;
        return .{ .schema = schema, .fields = fields, .origin = .user };
    }

    /// A preference changed. Starts the wait rather than the write.
    pub fn touch(self: *File) void {
        self.dirty = true;
        self.settled = 0;
    }

    /// One frame of waiting, and the write when the waiting is over.
    ///
    /// `values` is only read when something is actually written, so building it is cheap
    /// enough to do every frame and correct to build from whatever is current.
    pub fn tick(self: *File, gpa: Allocator, schema: data.Schema, values: []const ?data.Value) void {
        if (!self.dirty) return;
        self.settled += 1;
        if (self.settled < self.settle_frames) return;
        self.flush(gpa, schema, values);
    }

    /// Writes now if anything is waiting. Called when a change settles, and once more at a
    /// normal shutdown — never on a fatal exit, which has nothing trustworthy to write.
    pub fn flush(self: *File, gpa: Allocator, schema: data.Schema, values: []const ?data.Value) void {
        if (!self.dirty) return;
        self.dirty = false;
        self.settled = 0;
        if (!self.persist) return;

        const storage = if (self.storage) |*s| s else return;
        storage.save(gpa, schema, values, self.baseline) catch |err| {
            // Said once. A warning repeated every time a slider moves is a warning nobody
            // reads, and the condition that caused it does not change within a run.
            self.persist = false;
            switch (err) {
                error.Preserved => log.warn(
                    "settings: the stored file was written by another build; keeping it as it is",
                    .{},
                ),
                else => log.warn("settings: could not be saved ({t}); not trying again this run", .{err}),
            }
            return;
        };
        self.rebase(gpa, values) catch {
            // Without a baseline every field is this process's, which is what a save was
            // before merging existed: correct, and only less generous to another instance.
            if (self.baseline_arena) |*a| a.deinit();
            self.baseline_arena = null;
            self.baseline = null;
        };
    }

    /// What was just written becomes what the next save compares against.
    fn rebase(self: *File, gpa: Allocator, values: []const ?data.Value) !void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const copy = try arena.allocator().alloc(?data.Value, values.len);
        for (copy, values) |*slot, v| slot.* = if (v) |value| try value.clone(arena.allocator(), .default) else null;
        if (self.baseline_arena) |*old| old.deinit();
        self.baseline_arena = arena;
        self.baseline = copy;
    }
};

const backup_suffix = ".bak";

// ---------------------------------------------------------------------------
// Little-endian helpers
// ---------------------------------------------------------------------------

fn appendU32(out: *std.ArrayList(u8), v: u32) void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    out.appendSliceAssumeCapacity(&buf);
}

fn appendU64(out: *std.ArrayList(u8), v: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    out.appendSliceAssumeCapacity(&buf);
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readU64(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The shape `distribution.md` §4 names as M9's reference: a window size, a volume, and
/// the set of packages the player has enabled. Everything a settings file has to be able
/// to hold is one of these four kinds.
fn testSchema() data.Schema {
    return .{
        .id = data.SchemaId.parse("test:settings") catch unreachable,
        .version = 1,
        .fields = &.{
            .{ .name = "window_width", .type = .u32, .presence = .optional },
            .{ .name = "window_height", .type = .u32, .presence = .optional },
            .{ .name = "master_volume", .type = .f32, .presence = .optional },
            .{ .name = "enabled", .type = .{ .list = &.string }, .presence = .optional },
        },
    };
}

fn sampleValues() [4]?data.Value {
    return .{
        .{ .int = 1280 },
        .{ .int = 720 },
        .{ .float = 0.25 },
        .{ .list = &.{ .{ .string = "wisp:content" }, .{ .string = "room:content" } } },
    };
}

fn encodeSample(gpa: Allocator, values: []const ?data.Value) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try encode(gpa, testSchema(), values, .default, &out);
    return out;
}

test "a settings file round trips every kind a preference can be" {
    const gpa = testing.allocator;
    const values = sampleValues();

    var bytes = try encodeSample(gpa, &values);
    defer bytes.deinit(gpa);

    const view = try decode(gpa, bytes.items, testSchema(), .default);
    try testing.expectEqual(@as(?i128, 1280), try view.intAt(0));
    try testing.expectEqual(@as(?i128, 720), try view.intAt(1));
    try testing.expectEqual(@as(?f64, 0.25), try view.floatAt(2));

    const list = (try view.listAt(3)).?;
    try testing.expectEqual(@as(u32, 2), list.len);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqualStrings("wisp:content", (try list.valueAt(arena.allocator(), 0)).?.string);
    try testing.expectEqualStrings("room:content", (try list.valueAt(arena.allocator(), 1)).?.string);
}

test "the same preferences encode to the same bytes" {
    const gpa = testing.allocator;
    const values = sampleValues();

    var first = try encodeSample(gpa, &values);
    defer first.deinit(gpa);
    var second = try encodeSample(gpa, &values);
    defer second.deinit(gpa);

    try testing.expectEqualSlices(u8, first.items, second.items);
}

test "a preference nobody set is absent rather than zero" {
    const gpa = testing.allocator;
    const values: [4]?data.Value = .{ null, null, .{ .float = 1.0 }, null };

    var bytes = try encodeSample(gpa, &values);
    defer bytes.deinit(gpa);

    const view = try decode(gpa, bytes.items, testSchema(), .default);
    // Absent, not zero. The difference is the whole of how a user's choice and a
    // content default are told apart.
    try testing.expect(!view.present(0));
    try testing.expect(view.present(2));
    try testing.expectEqual(@as(?i128, null), try view.intAt(0));
    try testing.expectEqual(@as(?f64, 1.0), try view.floatAt(2));
}

test "a file that is not settings at all is refused before anything is believed" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotSettings, decode(gpa, "", testSchema(), .default));
    try testing.expectError(error.NotSettings, decode(gpa, "FSET", testSchema(), .default));
    try testing.expectError(
        error.NotSettings,
        decode(gpa, &[_]u8{0} ** header_size, testSchema(), .default),
    );

    const oversize = try gpa.alloc(u8, (Limits.default.max_file_bytes) + 1);
    defer gpa.free(oversize);
    @memset(oversize, 0);
    try testing.expectError(error.TooLarge, decode(gpa, oversize, testSchema(), .default));
}

test "a truncated or padded settings file is damaged, not partly read" {
    const gpa = testing.allocator;
    const values = sampleValues();
    var bytes = try encodeSample(gpa, &values);
    defer bytes.deinit(gpa);

    // Every prefix past the header disagrees with the lengths the header states.
    var cut: usize = header_size;
    while (cut < bytes.items.len) : (cut += 1) {
        try testing.expectError(error.Malformed, decode(gpa, bytes.items[0..cut], testSchema(), .default));
    }

    const padded = try gpa.alloc(u8, bytes.items.len + 1);
    defer gpa.free(padded);
    @memcpy(padded[0..bytes.items.len], bytes.items);
    padded[bytes.items.len] = 0;
    try testing.expectError(error.Malformed, decode(gpa, padded, testSchema(), .default));
}

test "an offset that points outside its own section is refused" {
    const gpa = testing.allocator;
    const values = sampleValues();
    var bytes = try encodeSample(gpa, &values);
    defer bytes.deinit(gpa);

    const fields_len = readU32(bytes.items, 24);

    // The string field's offset, reached past the presence bytes. Pushing it beyond the
    // strings section has to fail rather than read whatever follows.
    const damaged = try gpa.dupe(u8, bytes.items);
    defer gpa.free(damaged);
    std.mem.writeInt(u32, damaged[header_size + fields_len - 8 ..][0..4], 0xffff_fff0, .little);
    try testing.expectError(error.Malformed, decode(gpa, damaged, testSchema(), .default));

    // Reserved flags are reserved: a build that does not know what one means must not
    // decide it did not matter.
    const flagged = try gpa.dupe(u8, bytes.items);
    defer gpa.free(flagged);
    std.mem.writeInt(u32, flagged[20..24], 1, .little);
    try testing.expectError(error.Malformed, decode(gpa, flagged, testSchema(), .default));
}

test "a presence bit for a field the schema does not have is refused" {
    const gpa = testing.allocator;
    const values = sampleValues();
    var bytes = try encodeSample(gpa, &values);
    defer bytes.deinit(gpa);

    const damaged = try gpa.dupe(u8, bytes.items);
    defer gpa.free(damaged);
    // Four fields, so bits 4..7 of the single presence byte address nothing.
    damaged[header_size] |= 0b1000_0000;
    try testing.expectError(error.Malformed, decode(gpa, damaged, testSchema(), .default));
}

test "a nonfinite preference is refused at both ends" {
    const gpa = testing.allocator;
    const nan: [4]?data.Value = .{ null, null, .{ .float = std.math.nan(f64) }, null };
    try testing.expectError(error.ValueRefused, encodeSample(gpa, &nan));

    const values = sampleValues();
    var bytes = try encodeSample(gpa, &values);
    defer bytes.deinit(gpa);

    // The same value arriving from a file rather than from a caller. A NaN is a legal
    // f32 and an illegal preference, and the reader is where that has to be settled —
    // otherwise every consumer of every setting defends against it separately.
    const damaged = try gpa.dupe(u8, bytes.items);
    defer gpa.free(damaged);
    // Found by its bits rather than by a computed offset: the test has no business
    // reimplementing the layout it is checking.
    var quarter: [4]u8 = undefined;
    std.mem.writeInt(u32, &quarter, @bitCast(@as(f32, 0.25)), .little);
    const at = std.mem.indexOf(u8, damaged, &quarter).?;
    std.mem.writeInt(u32, damaged[at..][0..4], 0x7fc0_0000, .little);
    try testing.expectError(error.Malformed, decode(gpa, damaged, testSchema(), .default));
}

test "a value past the file's own bounds is refused" {
    const gpa = testing.allocator;

    const long = try gpa.alloc(u8, Limits.default.max_string_bytes + 1);
    defer gpa.free(long);
    @memset(long, 'x');
    const long_string: [4]?data.Value = .{ null, null, null, .{ .list = &.{.{ .string = long }} } };
    try testing.expectError(error.ValueRefused, encodeSample(gpa, &long_string));

    const items = try gpa.alloc(data.Value, Limits.default.max_list_elements + 1);
    defer gpa.free(items);
    for (items) |*item| item.* = .{ .string = "x" };
    const long_list: [4]?data.Value = .{ null, null, null, .{ .list = items } };
    try testing.expectError(error.ValueRefused, encodeSample(gpa, &long_list));

    // A slot list that does not match the schema is the caller's mistake, and a short one
    // would silently drop the preferences at the end.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testing.expectError(
        error.FieldCountMismatch,
        encode(gpa, testSchema(), &.{null}, .default, &out),
    );
}

test "a schema a settings file could not describe is refused before the file is touched" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const anonymous: data.Schema = .{ .id = .none, .fields = &.{} };
    try testing.expectError(error.MissingSchemaId, encode(gpa, anonymous, &.{}, .default, &out));

    const unversioned: data.Schema = .{
        .id = data.SchemaId.parse("test:settings") catch unreachable,
        .version = 0,
        .fields = &.{},
    };
    try testing.expectError(error.InvalidVersion, encode(gpa, unversioned, &.{}, .default, &out));

    var wide: [Limits.default.max_fields + 1]data.Field = undefined;
    for (&wide) |*f| f.* = .{ .name = "n", .type = .u32, .presence = .optional };
    const too_wide: data.Schema = .{
        .id = data.SchemaId.parse("test:settings") catch unreachable,
        .fields = &wide,
    };
    try testing.expectError(error.TooManyFields, checkSchema(too_wide, .default));

    const deep: data.Schema = .{
        .id = data.SchemaId.parse("test:settings") catch unreachable,
        .fields = &.{.{ .name = "a", .type = .{
            .nested = &.{.{ .name = "b", .type = .{
                .nested = &.{.{ .name = "c", .type = .{
                    .nested = &.{.{ .name = "d", .type = .{
                        .nested = &.{.{ .name = "e", .type = .u32 }},
                    } }},
                } }},
            } }},
        } }},
    };
    try testing.expectError(error.TooDeep, checkSchema(deep, .default));
}

test "another build's file is told apart from another schema's" {
    const gpa = testing.allocator;
    const values = sampleValues();
    var bytes = try encodeSample(gpa, &values);
    defer bytes.deinit(gpa);

    const newer_envelope = try gpa.dupe(u8, bytes.items);
    defer gpa.free(newer_envelope);
    std.mem.writeInt(u32, newer_envelope[4..8], envelope_version + 1, .little);
    try testing.expectError(error.FutureVersion, decode(gpa, newer_envelope, testSchema(), .default));

    const newer_schema = try gpa.dupe(u8, bytes.items);
    defer gpa.free(newer_schema);
    std.mem.writeInt(u32, newer_schema[16..20], 2, .little);
    try testing.expectError(error.FutureVersion, decode(gpa, newer_schema, testSchema(), .default));

    // The same file read by a build whose schema has moved on. Refused rather than read
    // against the wrong offsets: the presence bitmap widens with the field count, so an
    // older block's fields are not where this build would look for them.
    var moved_on = testSchema();
    moved_on.version = 2;
    try testing.expectError(error.PastVersion, decode(gpa, bytes.items, moved_on, .default));

    var other = testSchema();
    other.id = data.SchemaId.parse("test:other") catch unreachable;
    try testing.expectError(error.ForeignSchema, decode(gpa, bytes.items, other, .default));
}

test "encoding survives an allocator that fails at every step" {
    const values = sampleValues();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, vals: []const ?data.Value) !void {
            var out = try encodeSample(gpa, vals);
            out.deinit(gpa);
        }
    }.run, .{@as([]const ?data.Value, &values)});
}

// -- resolution ----------------------------------------------------------------------

/// A layer built the way both real ones are: bytes somewhere, and a block read out of them.
const TestLayer = struct {
    bytes: std.ArrayList(u8),
    layer: Layer,

    fn init(gpa: Allocator, schema: data.Schema, values: []const ?data.Value, origin: Origin) !TestLayer {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        try encode(gpa, schema, values, .default, &bytes);
        const fields = try decode(gpa, bytes.items, schema, .default);
        return .{ .bytes = bytes, .layer = .{ .schema = schema, .fields = fields, .origin = origin } };
    }

    fn deinit(self: *TestLayer, gpa: Allocator) void {
        self.bytes.deinit(gpa);
    }
};

test "a value comes from the highest layer that has a usable one" {
    const gpa = testing.allocator;

    var content = try TestLayer.init(gpa, testSchema(), &[_]?data.Value{
        .{ .int = 1024 }, .{ .int = 768 }, .{ .float = 0.5 }, null,
    }, .content);
    defer content.deinit(gpa);

    var user = try TestLayer.init(gpa, testSchema(), &[_]?data.Value{
        .{ .int = 1920 }, null, null, null,
    }, .user);
    defer user.deinit(gpa);

    const layers = [_]?Layer{ content.layer, user.layer };

    // The user chose a width, so the user's width wins.
    const width = resolveInt(u32, "window_width", 1280, 320, 8192, &layers);
    try testing.expectEqual(@as(u32, 1920), width.value);
    try testing.expectEqual(Origin.user, width.origin);

    // They chose no height, so the package's default stands and a later package could
    // still change it.
    const height = resolveInt(u32, "window_height", 720, 320, 8192, &layers);
    try testing.expectEqual(@as(u32, 768), height.value);
    try testing.expectEqual(Origin.content, height.origin);

    const volume = resolveFloat(f32, "master_volume", 1, 0, 1, &layers);
    try testing.expectEqual(@as(f32, 0.5), volume.value);
    try testing.expectEqual(Origin.content, volume.origin);

    // Nothing supplies this one at all.
    const absent = resolveInt(u32, "not_a_field", 42, 0, 100, &layers);
    try testing.expectEqual(@as(u32, 42), absent.value);
    try testing.expectEqual(Origin.fallback, absent.origin);
    try testing.expect(!absent.isUser());
}

test "a value outside its range loses to the layer under it" {
    const gpa = testing.allocator;

    var content = try TestLayer.init(gpa, testSchema(), &[_]?data.Value{
        .{ .int = 1024 }, .{ .int = 100_000 }, .{ .float = 4 }, null,
    }, .content);
    defer content.deinit(gpa);

    var user = try TestLayer.init(gpa, testSchema(), &[_]?data.Value{
        .{ .int = 8 }, null, null, null,
    }, .user);
    defer user.deinit(gpa);

    const layers = [_]?Layer{ content.layer, user.layer };

    // A hand-edited preference costs the person that preference and nothing else.
    const width = resolveInt(u32, "window_width", 1280, 320, 8192, &layers);
    try testing.expectEqual(@as(u32, 1024), width.value);
    try testing.expectEqual(Origin.content, width.origin);

    // A package is as able to hold an unusable number as a person is, and it falls the
    // same way — to the value the application knows is safe.
    const height = resolveInt(u32, "window_height", 720, 320, 8192, &layers);
    try testing.expectEqual(@as(u32, 720), height.value);
    try testing.expectEqual(Origin.fallback, height.origin);

    const volume = resolveFloat(f32, "master_volume", 1, 0, 1, &layers);
    try testing.expectEqual(@as(f32, 1), volume.value);
    try testing.expectEqual(Origin.fallback, volume.origin);

    // A layer that is simply not there is skipped, which is what the first run looks like.
    const only_content = [_]?Layer{ content.layer, null };
    try testing.expectEqual(@as(u32, 1024), resolveInt(u32, "window_width", 1280, 320, 8192, &only_content).value);
    try testing.expectEqual(@as(u32, 1280), resolveInt(u32, "window_width", 1280, 320, 8192, &.{}).value);
}

test "a selection is read sorted, or not at all" {
    const gpa = testing.allocator;

    var chosen = try TestLayer.init(gpa, testSchema(), &[_]?data.Value{
        null, null, null, .{ .list = &.{ .{ .string = "wisp:content" }, .{ .string = "brighter:content" } } },
    }, .user);
    defer chosen.deinit(gpa);

    var set = try IdSet.read(gpa, chosen.layer, "enabled", 128);
    defer set.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), set.ids.len);
    try testing.expectEqualStrings("brighter:content", set.ids[0]);
    try testing.expectEqualStrings("wisp:content", set.ids[1]);
    try testing.expect(set.contains("wisp:content"));
    try testing.expect(!set.contains("room:content"));

    // Sorted and unique means the same set encodes to the same bytes however it was
    // assembled, which is what makes a settings file comparable between runs.
    var buf: [2]data.Value = undefined;
    var written = try encodeSample(gpa, &[_]?data.Value{ null, null, null, set.toValue(&buf) });
    defer written.deinit(gpa);
    const round = try decode(gpa, written.items, testSchema(), .default);
    var again = try IdSet.read(gpa, .{ .schema = testSchema(), .fields = round, .origin = .user }, "enabled", 128);
    defer again.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), again.ids.len);
    try testing.expectEqualStrings("brighter:content", again.ids[0]);
}

test "a selection that is partly wrong is not partly used" {
    const gpa = testing.allocator;

    var absent = try TestLayer.init(gpa, testSchema(), &[_]?data.Value{ null, null, null, null }, .user);
    defer absent.deinit(gpa);
    var empty = try IdSet.read(gpa, absent.layer, "enabled", 128);
    defer empty.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), empty.ids.len);

    // Not a content id at all. Dropping it silently would leave the player with a
    // selection they did not make and no way to see why.
    var bad = try TestLayer.init(gpa, testSchema(), &[_]?data.Value{
        null, null, null, .{ .list = &.{ .{ .string = "wisp:content" }, .{ .string = "not an id" } } },
    }, .user);
    defer bad.deinit(gpa);
    var none = try IdSet.read(gpa, bad.layer, "enabled", 128);
    defer none.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), none.ids.len);

    var twice = try TestLayer.init(gpa, testSchema(), &[_]?data.Value{
        null, null, null, .{ .list = &.{ .{ .string = "wisp:content" }, .{ .string = "wisp:content" } } },
    }, .user);
    defer twice.deinit(gpa);
    var refused = try IdSet.read(gpa, twice.layer, "enabled", 128);
    defer refused.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), refused.ids.len);

    // More packages than the caller is willing to hold.
    var over = try IdSet.read(gpa, twice.layer, "enabled", 1);
    defer over.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), over.ids.len);
}

// -- storage -------------------------------------------------------------------------

const StorageFixture = struct {
    os: *platform.Os,
    tmp: std.testing.TmpDir,
    dir: []u8,

    fn init() !StorageFixture {
        const gpa = testing.allocator;
        const os = try platform.Os.init(gpa, .{ .app_name = "foundry-settings-test", .env = &.{} });
        errdefer os.deinit();

        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        // A directory below the temporary one, so that the first save has to create it —
        // which is the ordinary first run on a machine that has never run this game.
        const dir = try platform.os.joinPath(gpa, &.{ buf[0..n], "Application Support", "foundry-test" });
        return .{ .os = os, .tmp = tmp, .dir = dir };
    }

    fn deinit(self: *StorageFixture) void {
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
        self.os.deinit();
    }

    fn storage(self: *StorageFixture) !Storage {
        return Storage.open(self.os, self.dir, default_leaf);
    }

    fn writeRaw(self: *StorageFixture, leaf: []const u8, bytes: []const u8) !void {
        try self.os.createDirPath(self.dir);
        _ = try self.os.replaceFileConfined(self.dir, leaf, bytes, 1 << 20);
    }

    fn readRaw(self: *StorageFixture, leaf: []const u8) ![]u8 {
        const read = try self.os.readFileConfined(testing.allocator, self.dir, leaf, 1 << 20);
        return read.bytes;
    }
};

test "preferences survive a process that is no longer running" {
    const gpa = testing.allocator;
    var fixture = try StorageFixture.init();
    defer fixture.deinit();

    var writing = try fixture.storage();
    var first = try writing.load(gpa, testSchema());
    defer first.deinit(gpa);
    try testing.expectEqual(State.absent, first.state);
    try testing.expect(first.fields == null);

    const values = sampleValues();
    try writing.save(gpa, testSchema(), &values, null);

    // A second `Storage` over the same directory: nothing is carried in memory, so this
    // is the same question a relaunch asks.
    var reading = try fixture.storage();
    var loaded = try reading.load(gpa, testSchema());
    defer loaded.deinit(gpa);
    try testing.expectEqual(State.loaded, loaded.state);
    try testing.expectEqual(@as(?i128, 1280), try loaded.fields.?.intAt(0));
    try testing.expectEqual(@as(?f64, 0.25), try loaded.fields.?.floatAt(2));
}

test "a damaged file is kept beside the one that replaces it" {
    const gpa = testing.allocator;
    var fixture = try StorageFixture.init();
    defer fixture.deinit();

    try fixture.writeRaw(default_leaf, "FSET and then nonsense");

    var storage = try fixture.storage();
    var loaded = try storage.load(gpa, testSchema());
    defer loaded.deinit(gpa);
    try testing.expectEqual(State.damaged, loaded.state);
    try testing.expect(loaded.fields == null);
    try testing.expect(storage.writable);

    const values = sampleValues();
    try storage.save(gpa, testSchema(), &values, null);

    const kept = try fixture.readRaw(default_leaf ++ ".bak");
    defer gpa.free(kept);
    try testing.expectEqualStrings("FSET and then nonsense", kept);

    var reading = try fixture.storage();
    var again = try reading.load(gpa, testSchema());
    defer again.deinit(gpa);
    try testing.expectEqual(State.loaded, again.state);
}

test "a file this build does not understand is preserved, not overwritten" {
    const gpa = testing.allocator;
    var fixture = try StorageFixture.init();
    defer fixture.deinit();

    const values = sampleValues();
    var bytes = try encodeSample(gpa, &values);
    defer bytes.deinit(gpa);
    std.mem.writeInt(u32, bytes.items[4..8], envelope_version + 1, .little);
    try fixture.writeRaw(default_leaf, bytes.items);

    var storage = try fixture.storage();
    var loaded = try storage.load(gpa, testSchema());
    defer loaded.deinit(gpa);
    try testing.expectEqual(State.preserved, loaded.state);
    try testing.expect(!storage.writable);

    // The user's newer preferences are what this refuses to destroy, so the refusal has
    // to reach the caller rather than being a quiet no-op.
    try testing.expectError(error.Preserved, storage.save(gpa, testSchema(), &values, null));

    const on_disk = try fixture.readRaw(default_leaf);
    defer gpa.free(on_disk);
    try testing.expectEqualSlices(u8, bytes.items, on_disk);
}

test "a user-data root that cannot be read disables writing rather than moving" {
    const gpa = testing.allocator;
    var fixture = try StorageFixture.init();
    defer fixture.deinit();

    // A directory where the settings file should be: readable as a name, not as a file.
    const as_dir = try platform.os.joinPath(gpa, &.{ fixture.dir, default_leaf });
    defer gpa.free(as_dir);
    try fixture.os.createDirPath(as_dir);

    var storage = try fixture.storage();
    var loaded = try storage.load(gpa, testSchema());
    defer loaded.deinit(gpa);
    try testing.expectEqual(State.unavailable, loaded.state);
    try testing.expect(!storage.writable);

    const values = sampleValues();
    try testing.expectError(error.Preserved, storage.save(gpa, testSchema(), &values, null));
}

test "a relative root or a leaf that is not one name is refused" {
    var fixture = try StorageFixture.init();
    defer fixture.deinit();

    try testing.expectError(
        error.RootNotAbsolute,
        Storage.open(fixture.os, "relative/user-data", default_leaf),
    );
    try testing.expectError(
        error.InvalidLeaf,
        Storage.open(fixture.os, fixture.dir, "nested/settings.fset"),
    );
    try testing.expectError(
        error.InvalidLeaf,
        Storage.open(fixture.os, fixture.dir, "../settings.fset"),
    );
    try testing.expectError(
        error.InvalidLeaf,
        Storage.open(fixture.os, fixture.dir, ""),
    );
}

// -- migrations and merged writes (M14 Step 3) ------------------------------------

/// The test schema's history: version 1 had a selection that version 2 moved out and
/// replaced with a key, and version 3 added a flag.
const history = struct {
    const v1: data.Schema = testSchema();
    const v2: data.Schema = .{
        .id = testSchema().id,
        .version = 2,
        .fields = &.{
            .{ .name = "window_width", .type = .u32, .presence = .optional },
            .{ .name = "window_height", .type = .u32, .presence = .optional },
            .{ .name = "master_volume", .type = .f32, .presence = .optional },
            .{ .name = "profile", .type = .u32, .presence = .optional },
        },
    };
    const v3: data.Schema = .{
        .id = testSchema().id,
        .version = 3,
        .fields = &.{
            .{ .name = "window_width", .type = .u32, .presence = .optional },
            .{ .name = "window_height", .type = .u32, .presence = .optional },
            .{ .name = "master_volume", .type = .f32, .presence = .optional },
            .{ .name = "profile", .type = .u32, .presence = .optional },
            .{ .name = "vsync", .type = .bool, .presence = .optional },
        },
    };

    fn oneToTwo(_: Allocator, old: []const ?data.Value, new: []?data.Value) Allocator.Error!void {
        @memcpy(new[0..3], old[0..3]);
    }
    fn twoToThree(_: Allocator, old: []const ?data.Value, new: []?data.Value) Allocator.Error!void {
        @memcpy(new[0..4], old[0..4]);
        new[4] = .{ .bool = true };
    }

    const to_v2 = [_]Migration{.{ .from = v1, .convert = oneToTwo }};
    const to_v3 = [_]Migration{ .{ .from = v1, .convert = oneToTwo }, .{ .from = v2, .convert = twoToThree } };
};

test "an older file converts in memory through every step, and the first save keeps it once" {
    const gpa = testing.allocator;
    var f = try StorageFixture.init();
    defer f.deinit();

    var old = try f.storage();
    const v1_values = sampleValues();
    try old.save(gpa, history.v1, &v1_values, null);
    const original = try f.readRaw(default_leaf);
    defer gpa.free(original);

    var storage = try f.storage();
    storage.migrations = &history.to_v3;
    var loaded = try storage.load(gpa, history.v3);
    defer loaded.deinit(gpa);
    try testing.expectEqual(State.loaded, loaded.state);
    try testing.expectEqual(@as(?u32, 1), loaded.migrated_from);
    const fields = loaded.fields.?;
    try testing.expectEqual(@as(?i128, 1280), try fields.intAt(0));
    try testing.expectEqual(@as(?f64, 0.25), try fields.floatAt(2));
    try testing.expectEqual(@as(?i128, null), try fields.intAt(3));
    try testing.expectEqual(@as(?bool, true), try fields.boolAt(4));

    // Loading wrote nothing.
    const untouched = try f.readRaw(default_leaf);
    defer gpa.free(untouched);
    try testing.expectEqualSlices(u8, original, untouched);

    // The first save at the new version keeps the old file beside it, once.
    var values: [5]?data.Value = .{ .{ .int = 1280 }, .{ .int = 720 }, .{ .float = 0.25 }, .{ .int = 1 }, .{ .bool = true } };
    try storage.save(gpa, history.v3, &values, null);
    const kept = try f.readRaw(default_leaf ++ ".v1");
    defer gpa.free(kept);
    try testing.expectEqualSlices(u8, original, kept);
    const now = try f.readRaw(default_leaf);
    defer gpa.free(now);
    try testing.expectEqual(@as(u32, 3), readU32(now, 16));
    // The older build, meanwhile, will not save over what the newer one wrote.
    var older_build = try f.storage();
    try testing.expectError(error.Preserved, older_build.save(gpa, history.v1, &v1_values, null));

    // A player can put a version 1 file back by hand. The next save converts it and keeps
    // the first copy rather than this one.
    var different = sampleValues();
    different[0] = .{ .int = 999 };
    var older_bytes: std.ArrayList(u8) = .empty;
    defer older_bytes.deinit(gpa);
    try encode(gpa, history.v1, &different, .default, &older_bytes);
    try f.writeRaw(default_leaf, older_bytes.items);
    values[1] = .{ .int = 800 };
    try storage.save(gpa, history.v3, &values, null);
    const still = try f.readRaw(default_leaf ++ ".v1");
    defer gpa.free(still);
    try testing.expectEqualSlices(u8, original, still);

    // A chain that does not reach the current version converts nothing, and keeps the file.
    try f.writeRaw(default_leaf, original);
    var gap = try f.storage();
    gap.migrations = history.to_v3[1..];
    var refused = try gap.load(gpa, history.v3);
    defer refused.deinit(gpa);
    try testing.expectEqual(State.preserved, refused.state);
}

test "two writers keep each other's fields, and the same field is the last writer's" {
    const gpa = testing.allocator;
    var f = try StorageFixture.init();
    defer f.deinit();

    var seed = try f.storage();
    const first: [4]?data.Value = .{ .{ .int = 1000 }, .{ .int = 700 }, .{ .float = 0.5 }, null };
    try seed.save(gpa, testSchema(), &first, null);

    // Both read the same file, and each keeps what it read as its baseline.
    var a = try f.storage();
    var a_loaded = try a.load(gpa, testSchema());
    defer a_loaded.deinit(gpa);
    var b = try f.storage();
    var b_loaded = try b.load(gpa, testSchema());
    defer b_loaded.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a_base = try valuesOf(arena.allocator(), a_loaded.fields.?, 4);
    const b_base = try valuesOf(arena.allocator(), b_loaded.fields.?, 4);

    // `a` changes the width; `b`, whose width is stale, changes only the volume.
    var a_values: [4]?data.Value = first;
    a_values[0] = .{ .int = 1200 };
    try a.save(gpa, testSchema(), &a_values, a_base);
    var b_values: [4]?data.Value = first;
    b_values[2] = .{ .float = 0.75 };
    try b.save(gpa, testSchema(), &b_values, b_base);

    var after = try seed.load(gpa, testSchema());
    defer after.deinit(gpa);
    try testing.expectEqual(@as(?i128, 1200), try after.fields.?.intAt(0));
    try testing.expectEqual(@as(?f64, 0.75), try after.fields.?.floatAt(2));

    // Both change the height: the last save wins that field, and only that field.
    a_values[1] = .{ .int = 710 };
    try a.save(gpa, testSchema(), &a_values, a_base);
    b_values[1] = .{ .int = 720 };
    try b.save(gpa, testSchema(), &b_values, b_base);
    var last = try seed.load(gpa, testSchema());
    defer last.deinit(gpa);
    try testing.expectEqual(@as(?i128, 720), try last.fields.?.intAt(1));
    try testing.expectEqual(@as(?i128, 1200), try last.fields.?.intAt(0));

    // A newer build's file appears: neither writer replaces it.
    var future: std.ArrayList(u8) = .empty;
    defer future.deinit(gpa);
    try encode(gpa, history.v2, &.{ null, null, null, .{ .int = 3 } }, .default, &future);
    try f.writeRaw(default_leaf, future.items);
    try testing.expectError(error.Preserved, a.save(gpa, testSchema(), &a_values, a_base));
    const kept = try f.readRaw(default_leaf);
    defer gpa.free(kept);
    try testing.expectEqualSlices(u8, future.items, kept);
}
