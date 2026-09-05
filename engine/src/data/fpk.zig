//! `.fpk` — the runtime package format (`docs/design/content-schemas.md` §5).
//!
//! Shipped builds never parse `.fdt` (ADR-0006). `fpack` compiles a package directory into
//! one of these and the engine loads it, so this file is both halves of a compatibility
//! contract: the writer and the reader of a format that will outlive every build that ever
//! reads it (I8).
//!
//! **Two encodings, for two different jobs.** Schemas are self-describing and are *decoded*
//! at load, because they have to become `Schema` values the registry can hold. Records are
//! not: a record's fields are laid out by its schema at fixed offsets, so reading one is
//! arithmetic on bytes that were never copied. §5.3 is the reason — the parse tree is
//! pointer-shaped, and the point of a runtime format is to not chase pointers at load.
//!
//! **Nothing in a package is trusted.** Package files arrive from mod authors and from the
//! internet. Every offset and length is checked against the section it addresses before
//! anything is dereferenced, every string is UTF-8-validated, and every accessor is
//! bounds-safe against a file that disagrees with the schema it names. A byte-for-byte
//! random file is an error, and so is a valid file with one byte changed; both are tests.
//!
//! **`data` cannot open a file**, so this writes into a byte buffer and reads out of one.
//! The same discipline as the parser, with the same payoff: the round trip is a pure
//! function and every test here is hermetic.
//!
//! **The field-block layout is shared, and a package is not its only user.** A save writes
//! each component's fields against the schema its component type declares, laid out exactly
//! the way a record is (`entity-storage.md` §9) — so `BlockWriter` and `Blocks` below are
//! the layout on its own, and `.fpk`'s header, schema section and record index are the
//! container this file wraps around it. Two implementations of one layout would be two
//! things that drift apart, and that drift reads as a field returning zero rather than as
//! an error.

const std = @import("std");
const core = @import("core");

const check = @import("check.zig");
const id_mod = @import("id.zig");
const limits_mod = @import("limits.zig");
const schema_mod = @import("schema.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Field = schema_mod.Field;
const FieldType = schema_mod.FieldType;
const Limits = limits_mod.Limits;
const NamedValue = value_mod.NamedValue;
const Registry = schema_mod.Registry;
const Schema = schema_mod.Schema;
const SchemaId = id_mod.SchemaId;
const Value = value_mod.Value;

// ---------------------------------------------------------------------------
// The format
// ---------------------------------------------------------------------------

pub const magic = "FPKG";

/// Bumped when the layout below changes. It lives in a **field, not in the magic**, so a
/// package from a future Foundry reports "format version 3, this build understands 1"
/// rather than "not a package" — which is the whole practical value of I8 at a file
/// boundary (§5.1).
pub const format_version: u32 = 1;

/// ```
/// 0   magic            [4]u8   "FPKG"
/// 4   format_version   u32
/// 8   package_id       u64     ContentId of the package's own namespace:name
/// 16  package_version  u32
/// 20  flags            u32     must be zero
/// 24  schema_count     u32
/// 28  record_count     u32
/// 32  schemas_offset   u32     schema entries, then their field declarations
/// 36  schemas_len      u32
/// 40  records_offset   u32     record_count fixed entries
/// 44  records_len      u32
/// 48  fields_offset    u32     packed record field data
/// 52  fields_len       u32
/// 56  strings_offset   u32     every string in the package, deduplicated
/// 60  strings_len      u32
/// 64  name_offset      u32     the package's own namespace:name
/// 68  name_len         u32
/// ```
///
/// The name is in the file because a package that can only state its own id is a package
/// no diagnostic can name: "foundry:core supplied this record" is an answer, and
/// "4f2ac91e… supplied this record" is not. The schemas and the records each carry their
/// spelling for the same reason (§4.5), and the package was the one thing left that did
/// not.
pub const header_size = 72;

const schema_entry_size = 24;
const record_entry_size = 32;

/// Sections start on an 8-byte boundary, and so does every record block and list array
/// inside the field data. Values are read with explicit little-endian loads, which cost
/// nothing on a little-endian host and are correct on any other, so alignment is not what
/// makes reads legal — it is what keeps a future zero-copy mapping possible.
const section_align = 8;

/// The byte written for each field type. **Spelled out rather than taken from the union's
/// declaration order**, for the reason `core/id.zig` spells out FNV-1a: a persisted format
/// is a compatibility contract, and reordering a Zig declaration must not be able to
/// change what a byte means. Zero is never written, so a zeroed buffer fails.
const TypeTag = enum(u8) {
    bool = 1,
    i32 = 2,
    i64 = 3,
    u32 = 4,
    u64 = 5,
    f32 = 6,
    f64 = 7,
    string = 8,
    id = 9,
    list = 10,
    nested = 11,

    fn of(t: FieldType) TypeTag {
        return switch (t) {
            .bool => .bool,
            .i32 => .i32,
            .i64 => .i64,
            .u32 => .u32,
            .u64 => .u64,
            .f32 => .f32,
            .f64 => .f64,
            .string => .string,
            .id => .id,
            .list => .list,
            .nested => .nested,
        };
    }
};

/// The tags of a self-describing value, used only for a schema field's default.
const ValueTag = enum(u8) {
    bool = 1,
    int = 2,
    float = 3,
    string = 4,
    id = 5,
    list = 6,
    nested = 7,
};

const PresenceTag = enum(u8) { required = 1, optional = 2, default = 3 };

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------
//
// A record's fields sit in one block: a presence bitmap, one bit per field, then one slot
// per field in declaration order. Declaration order, because it is the order a schema may
// only append to (§3) — so a slot's offset never moves for content already written.
//
// These walk a schema's field tree, and a schema decoded from a file has already been
// depth-bounded by the decoder, so the recursion is bounded by the time it gets here.

pub fn presenceBytes(field_count: usize) u32 {
    return @intCast((field_count + 7) / 8);
}

pub fn alignOf(t: FieldType) u32 {
    return switch (t) {
        .bool => 1,
        .i32, .u32, .f32, .string, .list => 4,
        .i64, .u64, .f64, .id => 8,
        .nested => |fields| blockAlign(fields),
    };
}

pub fn sizeOf(t: FieldType) u32 {
    return switch (t) {
        .bool => 1,
        .i32, .u32, .f32 => 4,
        .i64, .u64, .f64, .id => 8,
        // Both are a pair of u32: an offset and a length, into the strings section for a
        // string and the fields section for a list.
        .string, .list => 8,
        .nested => |fields| blockSize(fields),
    };
}

fn blockAlign(fields: []const Field) u32 {
    var a: u32 = 1;
    for (fields) |f| a = @max(a, alignOf(f.type));
    return a;
}

/// The size of one record's field block, rounded so that an array of them strides evenly.
pub fn blockSize(fields: []const Field) u32 {
    var cursor = presenceBytes(fields.len);
    var a: u32 = 1;
    for (fields) |f| {
        const fa = alignOf(f.type);
        a = @max(a, fa);
        cursor = alignUp(cursor, fa);
        cursor += sizeOf(f.type);
    }
    return alignUp(cursor, a);
}

/// The distance between consecutive elements of a list.
fn strideOf(t: FieldType) u32 {
    return alignUp(sizeOf(t), alignOf(t));
}

/// Where field `index` sits inside a block.
///
/// Walked rather than cached, which is O(fields) of integer arithmetic and no string
/// comparison — the property §5 actually asks for. A per-schema offset table is the
/// obvious next step and belongs with the caller that first wants it.
fn slotOffset(fields: []const Field, index: usize) ?u32 {
    if (index >= fields.len) return null;
    var cursor = presenceBytes(fields.len);
    for (fields, 0..) |f, i| {
        cursor = alignUp(cursor, alignOf(f.type));
        if (i == index) return cursor;
        cursor += sizeOf(f.type);
    }
    return null;
}

fn alignUp(v: u32, a: u32) u32 {
    return (v + a - 1) & ~(a - 1);
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------
//
// A field block is not only a record's shape. A save writes each component's fields
// against the schema its component type declares, and lays them out exactly the way a
// package lays out a record (`entity-storage.md` §9) — deliberately, so that one schema,
// one versioning rule and one piece of reading code serve both formats. Two
// implementations of one layout are two things that drift apart, and that drift shows up
// as a field reading zero rather than as an error.
//
// So the layout lives here, once, over the two buffers it needs — the packed fields and
// the strings they refer to — and each format assembles its own container around what it
// produces. `.fpk` writes records into it; a save writes components into it; neither can
// tell the difference from the inside.

pub const BlockError = error{
    /// A value whose shape is not the one its field declares. The checker cannot produce
    /// this; a caller assembling a block by hand can, and the writer is the last place
    /// that can still say so.
    ValueTypeMismatch,
    /// Past the format's 32-bit offsets — four gigabytes in one file.
    TooLarge,
} || Allocator.Error;

pub const WriteError = error{
    /// A record whose schema is not registered. The writer cannot lay out fields it
    /// cannot see.
    UnknownSchema,
} || BlockError;

/// A reference into the strings section: where it starts, and how long it is.
pub const Ref = struct { offset: u32, len: u32 };

/// Lays out field blocks, and the strings they refer to.
///
/// Owns the two buffers and nothing else: a caller writes blocks into it, then takes
/// `fields` and `strings` and assembles whatever container it is building. Offsets are
/// relative to each buffer's start, which is what makes them portable between formats.
pub const BlockWriter = struct {
    gpa: Allocator,
    fields: std.ArrayList(u8) = .empty,
    strings: std.ArrayList(u8) = .empty,
    interned: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *BlockWriter) void {
        self.fields.deinit(self.gpa);
        self.strings.deinit(self.gpa);
        self.interned.deinit(self.gpa);
        self.* = undefined;
    }

    /// Adds a string, or finds the one already there.
    ///
    /// The interning table borrows its keys from the caller's strings, which outlive the
    /// writer in every current caller: they are schema field names and checked content.
    pub fn intern(self: *BlockWriter, s: []const u8) BlockError!Ref {
        const len = try cast32(s.len);
        if (self.interned.get(s)) |offset| return .{ .offset = offset, .len = len };
        const offset = try cast32(self.strings.items.len);
        try self.strings.appendSlice(self.gpa, s);
        try self.interned.put(self.gpa, s, offset);
        return .{ .offset = offset, .len = len };
    }

    /// Reserves a zeroed block for `fields` and returns a handle that fills it in.
    ///
    /// Zeroed is what "nothing present" looks like — the presence bitmap goes down with
    /// the rest — so a block whose fields are never set reads back as a record that
    /// omitted every one of them.
    pub fn begin(self: *BlockWriter, fields: []const Field) BlockError!Block {
        try self.pad();
        const base = try cast32(self.fields.items.len);
        try self.fields.appendNTimes(self.gpa, 0, blockSize(fields));
        return .{ .writer = self, .base = base, .fields = fields };
    }

    /// Reserves `count` blocks end to end and returns where the run starts.
    ///
    /// `blockSize` is rounded to the block's own alignment precisely so that an array of
    /// them strides evenly, which is what lets a save address a component store's dense
    /// array by index rather than by a per-element offset table. Writing a string or a
    /// list from inside one of these appends *after* the run, so the stride holds.
    pub fn beginArray(self: *BlockWriter, fields: []const Field, count: u32) BlockError!u32 {
        try self.pad();
        const base = try cast32(self.fields.items.len);
        if (count != 0) {
            const size = blockSize(fields);
            const total = std.math.mul(u32, size, count) catch return error.TooLarge;
            try self.fields.appendNTimes(self.gpa, 0, total);
        }
        return base;
    }

    /// The `index`-th block of a run reserved by `beginArray`.
    pub fn blockIn(self: *BlockWriter, base: u32, fields: []const Field, index: u32) Block {
        return .{ .writer = self, .base = base + blockSize(fields) * index, .fields = fields };
    }

    /// Starts the next block on a section boundary, so a block's alignment is a property
    /// of the buffer rather than of what happens to precede it.
    pub fn pad(self: *BlockWriter) Allocator.Error!void {
        const pad_len = alignUp(@intCast(self.fields.items.len), section_align) - self.fields.items.len;
        try self.fields.appendNTimes(self.gpa, 0, pad_len);
    }

    fn writeSlot(self: *BlockWriter, t: FieldType, v: Value, at: u32) BlockError!void {
        switch (t) {
            .bool => {
                if (v != .bool) return error.ValueTypeMismatch;
                self.fields.items[at] = @intFromBool(v.bool);
            },
            .i32 => try self.putInt(i32, at, v),
            .i64 => try self.putInt(i64, at, v),
            .u32 => try self.putInt(u32, at, v),
            .u64 => try self.putInt(u64, at, v),
            .f32 => try self.putFloat(f32, at, v),
            .f64 => try self.putFloat(f64, at, v),
            .string => {
                if (v != .string) return error.ValueTypeMismatch;
                const ref = try self.intern(v.string);
                self.putU32(at, ref.offset);
                self.putU32(at + 4, ref.len);
            },
            .id => {
                if (v != .id) return error.ValueTypeMismatch;
                self.putU64(at, v.id.hash);
            },
            .list => |elem| {
                if (v != .list) return error.ValueTypeMismatch;
                const count = try cast32(v.list.len);
                const offset = try self.appendArray(elem.*, v.list);
                self.putU32(at, offset);
                self.putU32(at + 4, count);
            },
            .nested => |fields| {
                if (v != .nested) return error.ValueTypeMismatch;
                const block: Block = .{ .writer = self, .base = at, .fields = fields };
                try block.fill(.{ .named = v.nested });
            },
        }
    }

    fn appendArray(self: *BlockWriter, elem: FieldType, items: []const Value) BlockError!u32 {
        if (items.len == 0) return 0;
        try self.pad();
        const base = try cast32(self.fields.items.len);
        const stride = strideOf(elem);
        try self.fields.appendNTimes(self.gpa, 0, stride * try cast32(items.len));
        for (items, 0..) |item, i| {
            try self.writeSlot(elem, item, base + stride * @as(u32, @intCast(i)));
        }
        return base;
    }

    fn putInt(self: *BlockWriter, comptime T: type, at: u32, v: Value) BlockError!void {
        if (v != .int) return error.ValueTypeMismatch;
        const n = std.math.cast(T, v.int) orelse return error.ValueTypeMismatch;
        std.mem.writeInt(T, self.fields.items[at..][0..@sizeOf(T)], n, .little);
    }

    fn putFloat(self: *BlockWriter, comptime F: type, at: u32, v: Value) BlockError!void {
        // An integer literal in a float field is what the checker leaves behind when the
        // conversion is exact (§4.3), so the widening happens here rather than being a
        // second thing content authors have to know about.
        const f: F = switch (v) {
            .float => |x| @floatCast(x),
            .int => |x| @floatFromInt(x),
            else => return error.ValueTypeMismatch,
        };
        const Bits = std.meta.Int(.unsigned, @bitSizeOf(F));
        std.mem.writeInt(Bits, self.fields.items[at..][0..@sizeOf(F)], @bitCast(f), .little);
    }

    fn putU32(self: *BlockWriter, at: u32, v: u32) void {
        std.mem.writeInt(u32, self.fields.items[at..][0..4], v, .little);
    }

    fn putU64(self: *BlockWriter, at: u32, v: u64) void {
        std.mem.writeInt(u64, self.fields.items[at..][0..8], v, .little);
    }
};

/// Encodes schemas self-describingly: field names, types, `since` and defaults.
///
/// Shared for the same reason the block layout is. A save carries the full schema of every
/// component type it holds (`entity-storage.md` §9), because that is what lets a build whose
/// component has gained a field read an older file against the shape it was *written* with
/// rather than against its own — which is exactly what a package does and exactly what I8
/// asks for. One encoder, so the two cannot disagree about what a byte means.
pub const SchemaWriter = struct {
    gpa: Allocator,
    /// Field names and string defaults are interned here: they land in the strings section
    /// beside everything else, because both halves end up in one file.
    blocks: *BlockWriter,
    decls: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *SchemaWriter) void {
        self.decls.deinit(self.gpa);
        self.* = undefined;
    }

    /// Appends one schema's field declarations, and returns where they start in `decls`.
    pub fn add(self: *SchemaWriter, fields: []const Field) BlockError!u32 {
        const offset = try cast32(self.decls.items.len);
        try appendU32(self.gpa, &self.decls, try cast32(fields.len));
        try self.writeFieldDecls(fields);
        return offset;
    }

    fn writeFieldDecls(self: *SchemaWriter, fields: []const Field) BlockError!void {
        for (fields) |f| {
            const name_ref = try self.blocks.intern(f.name);
            try appendU32(self.gpa, &self.decls, name_ref.offset);
            try appendU32(self.gpa, &self.decls, name_ref.len);
            try appendU32(self.gpa, &self.decls, f.since);
            try self.decls.append(self.gpa, @intFromEnum(@as(PresenceTag, switch (f.presence) {
                .required => .required,
                .optional => .optional,
                .default => .default,
            })));
            try self.writeType(f.type);
            switch (f.presence) {
                .default => |d| try self.writeValueBlob(d),
                else => {},
            }
        }
    }

    fn writeType(self: *SchemaWriter, t: FieldType) BlockError!void {
        try self.decls.append(self.gpa, @intFromEnum(TypeTag.of(t)));
        switch (t) {
            .list => |elem| try self.writeType(elem.*),
            .nested => |fields| {
                try appendU32(self.gpa, &self.decls, try cast32(fields.len));
                try self.writeFieldDecls(fields);
            },
            else => {},
        }
    }

    fn writeValueBlob(self: *SchemaWriter, v: Value) BlockError!void {
        const out = &self.decls;
        switch (v) {
            .bool => |x| {
                try out.append(self.gpa, @intFromEnum(ValueTag.bool));
                try out.append(self.gpa, @intFromBool(x));
            },
            .int => |x| {
                try out.append(self.gpa, @intFromEnum(ValueTag.int));
                var buf: [16]u8 = undefined;
                std.mem.writeInt(i128, &buf, x, .little);
                try out.appendSlice(self.gpa, &buf);
            },
            .float => |x| {
                try out.append(self.gpa, @intFromEnum(ValueTag.float));
                try appendU64(self.gpa, out, @bitCast(x));
            },
            .string => |str| {
                try out.append(self.gpa, @intFromEnum(ValueTag.string));
                const ref = try self.blocks.intern(str);
                try appendU32(self.gpa, out, ref.offset);
                try appendU32(self.gpa, out, ref.len);
            },
            .id => |x| {
                try out.append(self.gpa, @intFromEnum(ValueTag.id));
                try appendU64(self.gpa, out, x.hash);
            },
            .list => |items| {
                try out.append(self.gpa, @intFromEnum(ValueTag.list));
                try appendU32(self.gpa, out, try cast32(items.len));
                for (items) |item| try self.writeValueBlob(item);
            },
            .nested => |named| {
                try out.append(self.gpa, @intFromEnum(ValueTag.nested));
                try appendU32(self.gpa, out, try cast32(named.len));
                for (named) |nv| {
                    const ref = try self.blocks.intern(nv.name);
                    try appendU32(self.gpa, out, ref.offset);
                    try appendU32(self.gpa, out, ref.len);
                    try self.writeValueBlob(nv.value);
                }
            },
        }
    }
};

/// Where a field's value comes from while a block is being filled.
///
/// Two shapes because a record's fields are indexed by the schema and an inline struct's
/// are named — the one place the checked representation is not positional
/// (`content-schemas.md` §3), and the only place that difference is visible.
pub const Source = union(enum) {
    slots: []const ?Value,
    named: []const NamedValue,

    fn get(self: Source, fields: []const Field, index: usize) ?Value {
        switch (self) {
            .slots => |s| return if (index < s.len) s[index] else null,
            .named => |n| {
                const name = fields[index].name;
                for (n) |nv| if (std.mem.eql(u8, nv.name, name)) return nv.value;
                return null;
            },
        }
    }
};

/// One reserved block, and the schema that says where its fields go.
///
/// A handle rather than a buffer: writing a string or a list appends to the writer, which
/// may move the block's bytes, so a block keeps an offset and re-derives the pointer at
/// every write. **Setting a field marks it present**; a field never set stays absent,
/// which is what an omitted optional and a field a later schema version added both look
/// like on the way back in.
pub const Block = struct {
    writer: *BlockWriter,
    base: u32,
    fields: []const Field,

    /// Writes one field, by position.
    ///
    /// Position, because a schema may only ever append (`content-schemas.md` §3), so
    /// field *i* is field *i* in every version that has it.
    pub fn set(self: Block, index: usize, v: Value) BlockError!void {
        const offset = slotOffset(self.fields, index) orelse return error.ValueTypeMismatch;
        // The presence bit goes down before the slot, because writing the slot may grow
        // the buffer and every index has to be taken against the current one.
        self.markPresent(index);
        try self.writer.writeSlot(self.fields[index].type, v, self.base + offset);
    }

    /// An inline struct field, as a block of its own.
    ///
    /// Returned rather than built from a `Value`, because a `.nested` value is a slice of
    /// named values somebody has to allocate — and a serializer walking a Zig struct has
    /// the fields already.
    pub fn nested(self: Block, index: usize) BlockError!Block {
        const offset = slotOffset(self.fields, index) orelse return error.ValueTypeMismatch;
        const t = self.fields[index].type;
        if (t != .nested) return error.ValueTypeMismatch;
        self.markPresent(index);
        return .{ .writer = self.writer, .base = self.base + offset, .fields = t.nested };
    }

    fn fill(self: Block, src: Source) BlockError!void {
        for (self.fields, 0..) |_, i| {
            const v = src.get(self.fields, i) orelse continue;
            try self.set(i, v);
        }
    }

    fn markPresent(self: Block, index: usize) void {
        self.writer.fields.items[self.base + index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
};

/// The sections a field block's references point into, and the one bound that reading
/// them needs.
///
/// A block is not self-contained: a string field holds an offset into the strings section
/// and a list field an offset into the fields section, so reading either needs both
/// buffers. This is that pair — and it is what lets `Fields` read a save's blocks as
/// readily as a package's, because the reading code has no idea which file it is looking
/// at. That is the point of it.
pub const Blocks = struct {
    fields: []const u8 = &.{},
    strings: []const u8 = &.{},
    /// A list's element count comes out of the file, so it is bounded before it is
    /// believed. The only limit a block read consults.
    max_list_elements: usize = Limits.default.max_list_elements,

    /// A block's fields, ready to be read against `schema_fields`.
    pub fn view(self: Blocks, schema_fields: []const Field, block: []const u8) Fields {
        return .{ .blocks = self, .fields = schema_fields, .block = block };
    }

    /// A block at `offset` in the fields section, bounds-checked against it.
    pub fn blockAt(self: Blocks, offset: u32, schema_fields: []const Field) ?Fields {
        const size = blockSize(schema_fields);
        if (@as(u64, offset) + size > self.fields.len) return null;
        return self.view(schema_fields, self.fields[offset..][0..size]);
    }

    /// The `index`-th block of a run written by `BlockWriter.beginArray`.
    pub fn blockInArray(self: Blocks, base: u32, schema_fields: []const Field, index: u32) ?Fields {
        const size = blockSize(schema_fields);
        const at = std.math.add(u32, base, std.math.mul(u32, size, index) catch return null) catch return null;
        return self.blockAt(at, schema_fields);
    }

    fn string(self: Blocks, offset: u32, len: u32) ?[]const u8 {
        const end = @as(u64, offset) + len;
        if (end > self.strings.len) return null;
        if (!onCodepointBoundary(self.strings, offset)) return null;
        if (!onCodepointBoundary(self.strings, @intCast(end))) return null;
        return self.strings[offset..][0..len];
    }

    fn stringRef(self: Blocks, bytes: []const u8, at: u32) ReadError![]const u8 {
        const offset = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const len = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        return self.string(offset, len) orelse error.Malformed;
    }

    fn makeList(self: Blocks, elem: FieldType, offset: u32, count: u32) ReadError!List {
        if (count == 0) return .{ .blocks = self, .elem = elem, .bytes = &.{}, .len = 0 };
        if (count > self.max_list_elements) return error.Malformed;
        const total = @as(u64, strideOf(elem)) * count;
        if (@as(u64, offset) + total > self.fields.len) return error.Malformed;
        return .{
            .blocks = self,
            .elem = elem,
            .bytes = self.fields[offset..][0..@intCast(total)],
            .len = count,
        };
    }

    fn readValue(
        self: Blocks,
        arena: Allocator,
        t: FieldType,
        bytes: []const u8,
        at: u32,
    ) ReadValueError!Value {
        if (@as(u64, at) + sizeOf(t) > bytes.len) return error.Malformed;
        return switch (t) {
            .bool => .{ .bool = bytes[at] != 0 },
            .i32 => .{ .int = std.mem.readInt(i32, bytes[at..][0..4], .little) },
            .i64 => .{ .int = std.mem.readInt(i64, bytes[at..][0..8], .little) },
            .u32 => .{ .int = std.mem.readInt(u32, bytes[at..][0..4], .little) },
            .u64 => .{ .int = std.mem.readInt(u64, bytes[at..][0..8], .little) },
            .f32 => .{ .float = @as(f32, @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little))) },
            .f64 => .{ .float = @bitCast(std.mem.readInt(u64, bytes[at..][0..8], .little)) },
            .string => .{ .string = try self.stringRef(bytes, at) },
            .id => .{ .id = .{ .hash = std.mem.readInt(u64, bytes[at..][0..8], .little) } },
            .list => |elem| blk: {
                const list = try self.makeList(
                    elem.*,
                    std.mem.readInt(u32, bytes[at..][0..4], .little),
                    std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little),
                );
                const items = try arena.alloc(Value, list.len);
                const stride = strideOf(elem.*);
                for (items, 0..) |*item, i| {
                    item.* = try self.readValue(arena, elem.*, list.bytes, stride * @as(u32, @intCast(i)));
                }
                break :blk .{ .list = items };
            },
            .nested => |fields| blk: {
                const block = bytes[at..][0..sizeOf(t)];
                const nested_view = self.view(fields, block);
                // Absent optionals are left out, which is how the checker represents an
                // inline struct — so a value read back compares equal to the one written.
                const buf = try arena.alloc(NamedValue, fields.len);
                var n: usize = 0;
                for (fields, 0..) |field, i| {
                    if (!nested_view.present(@intCast(i))) continue;
                    const offset = slotOffset(fields, i) orelse return error.Malformed;
                    buf[n] = .{
                        .name = field.name,
                        .value = try self.readValue(arena, field.type, block, offset),
                    };
                    n += 1;
                }
                break :blk .{ .nested = buf[0..n] };
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

/// Compiles a checked package into `out`.
///
/// `registry` supplies the schemas: every schema the package carries (§6 — the ones it
/// declares and the ones its records use) is written into the file at the version the
/// registry holds *now*, and every record is laid out against that same version. Which is
/// why a package should be compiled against a registry holding only what it and its
/// dependencies put there: the file records the shape it was built against, and a store
/// reading it later trusts that record over its own newer copy.
pub fn write(
    gpa: Allocator,
    pkg: *const check.Package,
    registry: *Registry,
    out: *std.ArrayList(u8),
) WriteError!void {
    var b: Builder = .{
        .gpa = gpa,
        .blocks = .{ .gpa = gpa },
        .schemas = undefined,
    };
    b.schemas = .{ .gpa = gpa, .blocks = &b.blocks };
    defer b.deinit();

    for (pkg.schemas.items) |decl| {
        const schema = registry.lookup(decl.id) orelse return error.UnknownSchema;
        try b.addSchema(schema.*, decl.text);
    }
    for (pkg.records()) |rec| {
        const schema = registry.get(rec.schema) orelse return error.UnknownSchema;
        try b.addRecord(rec, schema.*);
    }

    try b.assemble(pkg, out);
}

const Builder = struct {
    gpa: Allocator,
    /// The record blocks and the strings, laid out by the shared writer above. A package
    /// is that pair plus a header, a schema section and a record index.
    blocks: BlockWriter,
    schema_entries: std.ArrayList(u8) = .empty,
    /// The self-describing field declarations, encoded by the shared writer above.
    schemas: SchemaWriter,
    records: std.ArrayList(u8) = .empty,
    /// Scratch, refilled per record: the record's values widened to the schema's current
    /// field count, so a record checked against an older version writes its successor's
    /// defaults rather than a short block.
    slots: std.ArrayList(?Value) = .empty,

    fn deinit(self: *Builder) void {
        self.blocks.deinit();
        self.schema_entries.deinit(self.gpa);
        self.schemas.deinit();
        self.records.deinit(self.gpa);
        self.slots.deinit(self.gpa);
    }

    fn intern(self: *Builder, s: []const u8) WriteError!Ref {
        return self.blocks.intern(s);
    }

    // --- schemas --------------------------------------------------------------

    fn addSchema(self: *Builder, schema: Schema, name: []const u8) WriteError!void {
        const name_ref = try self.intern(name);
        const decl_offset = try self.schemas.add(schema.fields);

        try appendU64(self.gpa, &self.schema_entries, schema.id.hash);
        try appendU32(self.gpa, &self.schema_entries, schema.version);
        try appendU32(self.gpa, &self.schema_entries, name_ref.offset);
        try appendU32(self.gpa, &self.schema_entries, name_ref.len);
        try appendU32(self.gpa, &self.schema_entries, decl_offset);
    }

    // --- records --------------------------------------------------------------

    fn addRecord(self: *Builder, rec: check.Record, schema: Schema) WriteError!void {
        try self.slots.resize(self.gpa, schema.fields.len);
        for (self.slots.items, 0..) |*slot, i| slot.* = rec.value(schema, @intCast(i));

        const block = try self.blocks.begin(schema.fields);
        try block.fill(.{ .slots = self.slots.items });
        const name_ref = try self.intern(rec.text);

        try appendU64(self.gpa, &self.records, rec.id.hash);
        try appendU64(self.gpa, &self.records, rec.schema_id.hash);
        try appendU32(self.gpa, &self.records, name_ref.offset);
        try appendU32(self.gpa, &self.records, name_ref.len);
        try appendU32(self.gpa, &self.records, block.base);
        try appendU32(self.gpa, &self.records, blockSize(schema.fields));
    }

    // --- assembly -------------------------------------------------------------

    fn assemble(self: *Builder, pkg: *const check.Package, out: *std.ArrayList(u8)) WriteError!void {
        // Interned before the section lengths are taken, because it lands in the strings
        // section like every other name.
        const name_ref = try self.intern(pkg.name);

        const schemas_len = try cast32(self.schema_entries.items.len + self.schemas.decls.items.len);
        const records_len = try cast32(self.records.items.len);
        const fields_len = try cast32(self.blocks.fields.items.len);
        const strings_len = try cast32(self.blocks.strings.items.len);

        const schemas_offset: u32 = header_size;
        const records_offset = alignUp(try addU32(schemas_offset, schemas_len), section_align);
        const fields_offset = alignUp(try addU32(records_offset, records_len), section_align);
        const strings_offset = alignUp(try addU32(fields_offset, fields_len), section_align);
        const total = try addU32(strings_offset, strings_len);

        try out.ensureUnusedCapacity(self.gpa, total);
        const start = out.items.len;

        var header: [header_size]u8 = @splat(0);
        @memcpy(header[0..4], magic);
        std.mem.writeInt(u32, header[4..8], format_version, .little);
        std.mem.writeInt(u64, header[8..16], pkg.id.hash, .little);
        std.mem.writeInt(u32, header[16..20], pkg.version, .little);
        std.mem.writeInt(u32, header[20..24], 0, .little); // flags
        std.mem.writeInt(u32, header[24..28], try cast32(pkg.schemas.items.len), .little);
        std.mem.writeInt(u32, header[28..32], try cast32(pkg.records().len), .little);
        std.mem.writeInt(u32, header[32..36], schemas_offset, .little);
        std.mem.writeInt(u32, header[36..40], schemas_len, .little);
        std.mem.writeInt(u32, header[40..44], records_offset, .little);
        std.mem.writeInt(u32, header[44..48], records_len, .little);
        std.mem.writeInt(u32, header[48..52], fields_offset, .little);
        std.mem.writeInt(u32, header[52..56], fields_len, .little);
        std.mem.writeInt(u32, header[56..60], strings_offset, .little);
        std.mem.writeInt(u32, header[60..64], strings_len, .little);
        std.mem.writeInt(u32, header[64..68], name_ref.offset, .little);
        std.mem.writeInt(u32, header[68..72], name_ref.len, .little);
        try out.appendSlice(self.gpa, &header);

        try out.appendSlice(self.gpa, self.schema_entries.items);
        try out.appendSlice(self.gpa, self.schemas.decls.items);
        try padTo(self.gpa, out, start, records_offset);
        try out.appendSlice(self.gpa, self.records.items);
        try padTo(self.gpa, out, start, fields_offset);
        try out.appendSlice(self.gpa, self.blocks.fields.items);
        try padTo(self.gpa, out, start, strings_offset);
        try out.appendSlice(self.gpa, self.blocks.strings.items);
    }
};

fn padTo(gpa: Allocator, out: *std.ArrayList(u8), start: usize, offset: u32) Allocator.Error!void {
    const written = out.items.len - start;
    if (written < offset) try out.appendNTimes(gpa, 0, offset - written);
}

fn appendU32(gpa: Allocator, out: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn appendU64(gpa: Allocator, out: *std.ArrayList(u8), v: u64) Allocator.Error!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn cast32(v: usize) BlockError!u32 {
    return std.math.cast(u32, v) orelse error.TooLarge;
}

fn addU32(a: u32, b: u32) BlockError!u32 {
    const sum, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.TooLarge;
    return sum;
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

/// What decoding a schema's declarations can fail with. Shared, because a save carries
/// schemas the same way a package does.
pub const SchemaReadError = error{
    /// An offset, a length or a count that the file's own size contradicts.
    Malformed,
    TooManyFields,
    NestingTooDeep,
} || Allocator.Error;

pub const OpenError = error{
    /// Too short, or the magic is not `FPKG`. Ask `versionOf` before reporting this: a
    /// package from a future Foundry is a different problem with a different fix.
    NotAPackage,
    UnsupportedVersion,
    /// A flag bit this build does not know. Flags change how bytes are read, so an
    /// unknown one is refused rather than ignored.
    UnsupportedFlags,
    InvalidUtf8,
} || SchemaReadError;

pub const ReadError = error{
    /// The file disagrees with itself, or with the schema it names.
    Malformed,
    /// The caller asked for a kind the field is not. A mistake in the reading code, not
    /// in the file, and worth telling apart from one.
    WrongType,
};

pub const ReadValueError = ReadError || Allocator.Error;

/// The format version of `bytes`, or null if it is not a package at all.
///
/// Separate from `open` so that a caller can say "package format version 3, this build
/// understands 1" — which is what a version in a field rather than in the magic is *for*.
pub fn versionOf(bytes: []const u8) ?u32 {
    if (bytes.len < header_size) return null;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return null;
    return std.mem.readInt(u32, bytes[4..8], .little);
}

/// One record's identity and its packed fields.
pub const RecordView = struct {
    id: ContentId,
    schema_id: SchemaId,
    /// The source spelling of `id`, borrowed from the file.
    name: []const u8,
    block: []const u8,
};

pub const Reader = struct {
    /// Holds the decoded schemas, and nothing else. Records are never decoded.
    arena: core.Arena,
    bytes: []const u8,
    id: ContentId,
    /// The source spelling of `id`, borrowed from the file.
    name: []const u8 = "",
    version: u32,
    limits: Limits,

    schemas: []const Schema = &.{},
    /// The source spelling of each schema in `schemas`, by the same index.
    schema_names: []const []const u8 = &.{},

    records_section: []const u8 = &.{},
    /// The record blocks and their strings, in the shape any format that lays fields out
    /// this way hands to `Fields`.
    blocks: Blocks = .{},
    record_count: u32 = 0,

    /// Validates the file's structure and decodes its schemas.
    ///
    /// `bytes` is borrowed for the reader's whole life and is never copied: strings and
    /// field data are read out of it in place. What is *not* deferred is safety — after
    /// this returns, every section, every record entry and every string in those entries
    /// has been checked against the file's own size, and every accessor below re-checks
    /// what it reads out of a record block, because a block's shape depends on a schema
    /// the file does not have to agree with.
    pub fn open(gpa: Allocator, bytes: []const u8, limits: Limits) OpenError!Reader {
        if (bytes.len < header_size) return error.NotAPackage;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotAPackage;
        if (std.mem.readInt(u32, bytes[4..8], .little) != format_version) return error.UnsupportedVersion;
        if (std.mem.readInt(u32, bytes[20..24], .little) != 0) return error.UnsupportedFlags;

        const schema_count = std.mem.readInt(u32, bytes[24..28], .little);
        const record_count = std.mem.readInt(u32, bytes[28..32], .little);

        const schemas_section = sectionAt(bytes, 32) orelse return error.Malformed;
        const records_section = sectionAt(bytes, 40) orelse return error.Malformed;
        const fields_section = sectionAt(bytes, 48) orelse return error.Malformed;
        const strings_section = sectionAt(bytes, 56) orelse return error.Malformed;

        // One pass over the strings, so that resolving a string ref later is two boundary
        // tests rather than a scan. A slice of valid UTF-8 is valid UTF-8 exactly when
        // neither end lands in the middle of a codepoint.
        if (!std.unicode.utf8ValidateSlice(strings_section)) return error.InvalidUtf8;

        // Counts are believed only after the bytes to hold them have been found.
        if (@as(u64, schema_count) * schema_entry_size > schemas_section.len) return error.Malformed;
        if (@as(u64, record_count) * record_entry_size > records_section.len) return error.Malformed;

        var self: Reader = .{
            .arena = .init(gpa),
            .bytes = bytes,
            .id = .{ .hash = std.mem.readInt(u64, bytes[8..16], .little) },
            .version = std.mem.readInt(u32, bytes[16..20], .little),
            .limits = limits,
            .records_section = records_section,
            .blocks = .{
                .fields = fields_section,
                .strings = strings_section,
                .max_list_elements = limits.max_list_elements,
            },
            .record_count = record_count,
        };
        errdefer self.arena.deinit();

        self.name = self.string(
            std.mem.readInt(u32, bytes[64..68], .little),
            std.mem.readInt(u32, bytes[68..72], .little),
        ) orelse return error.Malformed;

        try self.decodeSchemas(schemas_section, schema_count);
        try self.validateRecordEntries();
        return self;
    }

    pub fn deinit(self: *Reader) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn schemaCount(self: *const Reader) u32 {
        return @intCast(self.schemas.len);
    }

    /// A schema this package declares, by id.
    pub fn schemaFor(self: *const Reader, schema_id: SchemaId) ?*const Schema {
        for (self.schemas) |*s| if (s.id.eql(schema_id)) return s;
        return null;
    }

    pub fn record(self: *const Reader, index: u32) ?RecordView {
        if (index >= self.record_count) return null;
        const at = index * record_entry_size;
        const e = self.records_section[at..][0..record_entry_size];
        const name_offset = std.mem.readInt(u32, e[16..20], .little);
        const name_len = std.mem.readInt(u32, e[20..24], .little);
        const block_offset = std.mem.readInt(u32, e[24..28], .little);
        const block_len = std.mem.readInt(u32, e[28..32], .little);
        return .{
            .id = .{ .hash = std.mem.readInt(u64, e[0..8], .little) },
            .schema_id = .{ .hash = std.mem.readInt(u64, e[8..16], .little) },
            // Both were checked in `validateRecordEntries`, which is why this cannot fail.
            .name = self.string(name_offset, name_len).?,
            .block = self.blocks.fields[block_offset..][0..block_len],
        };
    }

    /// A record's fields, ready to be read against `schema`.
    pub fn fieldsOf(self: *const Reader, view: RecordView, schema: Schema) Fields {
        return self.blocks.view(schema.fields, view.block);
    }

    /// Reads every field of every record.
    ///
    /// Not required before reading — every accessor is bounds-safe on its own — but it
    /// turns a package that will fail on the tenth field of the thousandth record into one
    /// that fails at load, which is the difference between a diagnosable package and a
    /// mysterious one.
    ///
    /// A record naming a schema the package does not carry is `Malformed` rather than a
    /// record skipped: a package carries every schema its records use (§6), so a record
    /// whose schema is missing is a file that has been damaged or built wrong, and a
    /// silent skip would turn that into content that quietly is not there.
    pub fn walk(self: *const Reader, gpa: Allocator) ReadValueError!void {
        var arena: core.Arena = .init(gpa);
        defer arena.deinit();
        var i: u32 = 0;
        while (i < self.record_count) : (i += 1) {
            const view = self.record(i).?;
            const schema = self.schemaFor(view.schema_id) orelse return error.Malformed;
            const fields = self.fieldsOf(view, schema.*);
            for (0..schema.fields.len) |index| {
                _ = try fields.valueAt(arena.allocator(), @intCast(index));
            }
        }
    }

    // --- internals ------------------------------------------------------------

    fn decodeSchemas(self: *Reader, section: []const u8, count: u32) OpenError!void {
        const arena = self.arena.allocator();
        const entries_len = count * schema_entry_size;
        const decls = section[entries_len..];

        const schemas = try arena.alloc(Schema, count);
        const names = try arena.alloc([]const u8, count);

        for (0..count) |i| {
            const e = section[i * schema_entry_size ..][0..schema_entry_size];
            const name_offset = std.mem.readInt(u32, e[12..16], .little);
            const name_len = std.mem.readInt(u32, e[16..20], .little);
            const decl_offset = std.mem.readInt(u32, e[20..24], .little);
            if (decl_offset > decls.len) return error.Malformed;

            var decoder: SchemaDecoder = .{
                .bytes = decls,
                .pos = decl_offset,
                .arena = arena,
                .strings = self.blocks.strings,
                .limits = self.limits,
            };
            schemas[i] = .{
                .id = .{ .hash = std.mem.readInt(u64, e[0..8], .little) },
                .version = std.mem.readInt(u32, e[8..12], .little),
                .fields = try decoder.readFields(),
            };
            names[i] = self.string(name_offset, name_len) orelse return error.Malformed;
        }

        self.schemas = schemas;
        self.schema_names = names;
    }

    fn validateRecordEntries(self: *Reader) OpenError!void {
        var i: u32 = 0;
        while (i < self.record_count) : (i += 1) {
            const e = self.records_section[i * record_entry_size ..][0..record_entry_size];
            const name_offset = std.mem.readInt(u32, e[16..20], .little);
            const name_len = std.mem.readInt(u32, e[20..24], .little);
            const block_offset = std.mem.readInt(u32, e[24..28], .little);
            const block_len = std.mem.readInt(u32, e[28..32], .little);
            if (self.string(name_offset, name_len) == null) return error.Malformed;
            if (@as(u64, block_offset) + block_len > self.blocks.fields.len) return error.Malformed;
        }
    }

    fn string(self: *const Reader, offset: u32, len: u32) ?[]const u8 {
        return self.blocks.string(offset, len);
    }
};

/// A record's packed fields, plus the schema that says how to read them.
///
/// Holds no copy of anything: the block is a slice of the file. Every accessor checks what
/// it is about to read against the block it was given, so a file whose blocks disagree with
/// the schema returns `Malformed` rather than whatever happened to be next in memory.
pub const Fields = struct {
    blocks: Blocks,
    fields: []const Field,
    block: []const u8,

    pub fn count(self: Fields) u32 {
        return @intCast(self.fields.len);
    }

    pub fn present(self: Fields, index: u32) bool {
        if (index >= self.fields.len) return false;
        const byte = index / 8;
        if (byte >= self.block.len) return false;
        return self.block[byte] & (@as(u8, 1) << @intCast(index % 8)) != 0;
    }

    pub fn boolAt(self: Fields, index: u32) ReadError!?bool {
        const s = try self.slot(index, &.{.bool}) orelse return null;
        return self.block[s] != 0;
    }

    /// Any integer field, widened. The declared type is what the file stores; `i128` is
    /// what covers every one of them, the same reason `Value` holds one.
    pub fn intAt(self: Fields, index: u32) ReadError!?i128 {
        const s = try self.slot(index, &.{ .i32, .i64, .u32, .u64 }) orelse return null;
        return switch (self.fields[index].type) {
            .i32 => std.mem.readInt(i32, self.block[s..][0..4], .little),
            .i64 => std.mem.readInt(i64, self.block[s..][0..8], .little),
            .u32 => std.mem.readInt(u32, self.block[s..][0..4], .little),
            .u64 => std.mem.readInt(u64, self.block[s..][0..8], .little),
            else => unreachable,
        };
    }

    pub fn floatAt(self: Fields, index: u32) ReadError!?f64 {
        const s = try self.slot(index, &.{ .f32, .f64 }) orelse return null;
        return switch (self.fields[index].type) {
            .f32 => @as(f32, @bitCast(std.mem.readInt(u32, self.block[s..][0..4], .little))),
            .f64 => @bitCast(std.mem.readInt(u64, self.block[s..][0..8], .little)),
            else => unreachable,
        };
    }

    pub fn stringAt(self: Fields, index: u32) ReadError!?[]const u8 {
        const s = try self.slot(index, &.{.string}) orelse return null;
        return try self.blocks.stringRef(self.block, s);
    }

    pub fn idAt(self: Fields, index: u32) ReadError!?ContentId {
        const s = try self.slot(index, &.{.id}) orelse return null;
        return .{ .hash = std.mem.readInt(u64, self.block[s..][0..8], .little) };
    }

    pub fn nestedAt(self: Fields, index: u32) ReadError!?Fields {
        const s = try self.slot(index, &.{.nested}) orelse return null;
        const t = self.fields[index].type;
        return .{ .blocks = self.blocks, .fields = t.nested, .block = self.block[s..][0..sizeOf(t)] };
    }

    pub fn listAt(self: Fields, index: u32) ReadError!?List {
        const s = try self.slot(index, &.{.list}) orelse return null;
        return try self.blocks.makeList(
            self.fields[index].type.list.*,
            std.mem.readInt(u32, self.block[s..][0..4], .little),
            std.mem.readInt(u32, self.block[s + 4 ..][0..4], .little),
        );
    }

    /// The field as a `Value`. Strings are borrowed from the file; lists and inline
    /// structs are built in `arena`. For tooling and for tests — a system reading content
    /// in a loop wants the typed accessors, which copy nothing at all.
    pub fn valueAt(self: Fields, arena: Allocator, index: u32) ReadValueError!?Value {
        if (index >= self.fields.len) return null;
        if (!self.present(index)) return null;
        const at = try self.slotIn(index);
        return try self.blocks.readValue(arena, self.fields[index].type, self.block, at);
    }

    fn slot(self: Fields, index: u32, kinds: []const TypeTag) ReadError!?u32 {
        if (index >= self.fields.len) return null;
        for (kinds) |k| {
            if (TypeTag.of(self.fields[index].type) == k) break;
        } else return error.WrongType;
        if (!self.present(index)) return null;
        return try self.slotIn(index);
    }

    fn slotIn(self: Fields, index: u32) ReadError!u32 {
        if (presenceBytes(self.fields.len) > self.block.len) return error.Malformed;
        const at = slotOffset(self.fields, index) orelse return error.Malformed;
        if (@as(u64, at) + sizeOf(self.fields[index].type) > self.block.len) return error.Malformed;
        return at;
    }
};

/// A list field's elements, in place.
pub const List = struct {
    blocks: Blocks,
    elem: FieldType,
    bytes: []const u8,
    len: u32,

    pub fn valueAt(self: List, arena: Allocator, index: u32) ReadValueError!?Value {
        if (index >= self.len) return null;
        return try self.blocks.readValue(arena, self.elem, self.bytes, strideOf(self.elem) * index);
    }

    /// A content id element, without an allocator.
    ///
    /// `valueAt` can already read one, and needs an arena it will not use — an `id` is a
    /// scalar. A list of references is the shape every "this entity has these components"
    /// record has (`entity-storage.md` §8), so it is worth the three lines not to hand an
    /// allocator to a loop that allocates nothing.
    pub fn idAt(self: List, index: u32) ReadError!?ContentId {
        if (index >= self.len) return null;
        if (self.elem != .id) return error.WrongType;
        const at = strideOf(self.elem) * index;
        if (@as(u64, at) + 8 > self.bytes.len) return error.Malformed;
        return .{ .hash = std.mem.readInt(u64, self.bytes[at..][0..8], .little) };
    }

    /// An integer element, without an allocator.
    ///
    /// The same three lines `idAt` earns, for the same reason: a scalar allocates nothing,
    /// and a list of numbers is as common a shape as a list of references — a tile size, a
    /// list of solid tile ids, a palette index (`tilemaps-and-collision.md` §9).
    pub fn intAt(self: List, index: u32) ReadError!?i128 {
        if (index >= self.len) return null;
        const at = strideOf(self.elem) * index;
        if (@as(u64, at) + sizeOf(self.elem) > self.bytes.len) return error.Malformed;
        return switch (self.elem) {
            .i32 => std.mem.readInt(i32, self.bytes[at..][0..4], .little),
            .i64 => std.mem.readInt(i64, self.bytes[at..][0..8], .little),
            .u32 => std.mem.readInt(u32, self.bytes[at..][0..4], .little),
            .u64 => std.mem.readInt(u64, self.bytes[at..][0..8], .little),
            else => error.WrongType,
        };
    }

    pub fn floatAt(self: List, index: u32) ReadError!?f64 {
        if (index >= self.len) return null;
        const at = strideOf(self.elem) * index;
        if (@as(u64, at) + sizeOf(self.elem) > self.bytes.len) return error.Malformed;
        return switch (self.elem) {
            .f32 => @as(f32, @bitCast(std.mem.readInt(u32, self.bytes[at..][0..4], .little))),
            .f64 => @bitCast(std.mem.readInt(u64, self.bytes[at..][0..8], .little)),
            else => error.WrongType,
        };
    }

    pub fn nestedAt(self: List, index: u32) ReadError!?Fields {
        if (index >= self.len) return null;
        if (self.elem != .nested) return error.WrongType;
        const at = strideOf(self.elem) * index;
        const size = sizeOf(self.elem);
        if (@as(u64, at) + size > self.bytes.len) return error.Malformed;
        return .{ .blocks = self.blocks, .fields = self.elem.nested, .block = self.bytes[at..][0..size] };
    }
};

fn sectionAt(bytes: []const u8, header_offset: usize) ?[]const u8 {
    const offset = std.mem.readInt(u32, bytes[header_offset..][0..4], .little);
    const len = std.mem.readInt(u32, bytes[header_offset + 4 ..][0..4], .little);
    if (offset % section_align != 0) return null;
    if (@as(u64, offset) + len > bytes.len) return null;
    return bytes[offset..][0..len];
}

fn onCodepointBoundary(bytes: []const u8, at: u32) bool {
    if (at >= bytes.len) return at == bytes.len;
    return bytes[at] & 0xC0 != 0x80;
}

/// Decodes what `SchemaWriter` encodes: field declarations and their defaults.
///
/// Depth-bounded and count-bounded, because everything it reads came out of a file
/// somebody else wrote. Public because a save's component type table is this encoding —
/// see `SchemaWriter` for why the two formats share it.
pub const SchemaDecoder = struct {
    bytes: []const u8,
    pos: usize,
    arena: Allocator,
    strings: []const u8,
    limits: Limits,

    fn take(self: *SchemaDecoder, n: usize) SchemaReadError![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Malformed;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    fn u8v(self: *SchemaDecoder) SchemaReadError!u8 {
        return (try self.take(1))[0];
    }

    fn u32v(self: *SchemaDecoder) SchemaReadError!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn u64v(self: *SchemaDecoder) SchemaReadError!u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    fn strv(self: *SchemaDecoder) SchemaReadError![]const u8 {
        const offset = try self.u32v();
        const len = try self.u32v();
        const end = @as(u64, offset) + len;
        if (end > self.strings.len) return error.Malformed;
        if (!onCodepointBoundary(self.strings, offset)) return error.Malformed;
        if (!onCodepointBoundary(self.strings, @intCast(end))) return error.Malformed;
        return self.strings[offset..][0..len];
    }

    /// The smallest a field declaration can be: two u32 for the name, one for `since`,
    /// one byte of presence and one of type. Believing a count before checking it against
    /// this is how a four-byte file asks for a gigabyte.
    pub const min_field_bytes = 4 + 4 + 4 + 1 + 1;

    /// One schema's fields, at the decoder's current position — the shape `SchemaWriter.add`
    /// writes: a field count, then that many declarations.
    pub fn readFields(self: *SchemaDecoder) SchemaReadError![]const Field {
        const count = try self.u32v();
        return self.fields(count, 0);
    }

    fn fields(self: *SchemaDecoder, count: u32, depth: u32) SchemaReadError![]const Field {
        if (depth >= self.limits.max_nesting_depth) return error.NestingTooDeep;
        if (count > self.limits.max_fields_per_schema) return error.TooManyFields;
        if (@as(u64, count) * min_field_bytes > self.bytes.len - self.pos) return error.Malformed;

        const out = try self.arena.alloc(Field, count);
        for (out) |*f| {
            const name = try self.strv();
            const since = try self.u32v();
            const presence_tag = try self.u8v();
            const field_type = try self.fieldType(depth);
            f.* = .{
                .name = name,
                .type = field_type,
                .since = since,
                .presence = switch (presence_tag) {
                    @intFromEnum(PresenceTag.required) => .required,
                    @intFromEnum(PresenceTag.optional) => .optional,
                    @intFromEnum(PresenceTag.default) => .{ .default = try self.value(depth) },
                    else => return error.Malformed,
                },
            };
        }
        return out;
    }

    fn fieldType(self: *SchemaDecoder, depth: u32) SchemaReadError!FieldType {
        if (depth >= self.limits.max_nesting_depth) return error.NestingTooDeep;
        return switch (try self.u8v()) {
            @intFromEnum(TypeTag.bool) => .bool,
            @intFromEnum(TypeTag.i32) => .i32,
            @intFromEnum(TypeTag.i64) => .i64,
            @intFromEnum(TypeTag.u32) => .u32,
            @intFromEnum(TypeTag.u64) => .u64,
            @intFromEnum(TypeTag.f32) => .f32,
            @intFromEnum(TypeTag.f64) => .f64,
            @intFromEnum(TypeTag.string) => .string,
            @intFromEnum(TypeTag.id) => .id,
            @intFromEnum(TypeTag.list) => blk: {
                const elem = try self.arena.create(FieldType);
                elem.* = try self.fieldType(depth + 1);
                break :blk .{ .list = elem };
            },
            @intFromEnum(TypeTag.nested) => blk: {
                const n = try self.u32v();
                break :blk .{ .nested = try self.fields(n, depth + 1) };
            },
            else => error.Malformed,
        };
    }

    fn value(self: *SchemaDecoder, depth: u32) SchemaReadError!Value {
        if (depth >= self.limits.max_nesting_depth) return error.NestingTooDeep;
        return switch (try self.u8v()) {
            @intFromEnum(ValueTag.bool) => .{ .bool = (try self.u8v()) != 0 },
            @intFromEnum(ValueTag.int) => .{ .int = std.mem.readInt(i128, (try self.take(16))[0..16], .little) },
            @intFromEnum(ValueTag.float) => .{ .float = @bitCast(try self.u64v()) },
            @intFromEnum(ValueTag.string) => .{ .string = try self.strv() },
            @intFromEnum(ValueTag.id) => .{ .id = .{ .hash = try self.u64v() } },
            @intFromEnum(ValueTag.list) => blk: {
                const count = try self.u32v();
                if (count > self.limits.max_list_elements) return error.Malformed;
                // Every element is at least its own tag byte.
                if (count > self.bytes.len - self.pos) return error.Malformed;
                const items = try self.arena.alloc(Value, count);
                for (items) |*item| item.* = try self.value(depth + 1);
                break :blk .{ .list = items };
            },
            @intFromEnum(ValueTag.nested) => blk: {
                const count = try self.u32v();
                if (count > self.limits.max_fields_per_record) return error.Malformed;
                if (@as(u64, count) * 9 > self.bytes.len - self.pos) return error.Malformed;
                const named = try self.arena.alloc(NamedValue, count);
                for (named) |*nv| {
                    nv.name = try self.strv();
                    nv.value = try self.value(depth + 1);
                }
                break :blk .{ .nested = named };
            },
            else => error.Malformed,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const diagnostic = @import("diagnostic.zig");
const parser_mod = @import("parser.zig");

/// Parses, checks and compiles one source into a package's bytes — the whole pipeline,
/// which is the only useful thing to test a format against.
const Fixture = struct {
    registry: Registry,
    pkg: check.Package,
    bytes: std.ArrayList(u8),

    fn compile(source: []const u8) !Fixture {
        const gpa = testing.allocator;
        var f: Fixture = .{
            .registry = .init(gpa, .default),
            .pkg = try .init(gpa, "foundry:core", 3, .default),
            .bytes = .empty,
        };
        errdefer f.deinit();

        var diags: diagnostic.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);

        var doc = try parser_mod.parse(gpa, "test.fdt", source, .{ .namespace = "foundry" }, &diags);
        defer doc.deinit(gpa);

        f.pkg.addDocument(gpa, &doc, &f.registry, &diags) catch |err| {
            var buf: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            diags.render(&w) catch {};
            std.debug.print("unexpected content failure:\n{s}\n", .{w.buffered()});
            return err;
        };

        try write(gpa, &f.pkg, &f.registry, &f.bytes);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.bytes.deinit(testing.allocator);
        self.pkg.deinit(testing.allocator);
        self.registry.deinit(testing.allocator);
    }

    fn open(self: *const Fixture) OpenError!Reader {
        return Reader.open(testing.allocator, self.bytes.items, .default);
    }
};

const round_trip_source =
    \\@schema item {
    \\    name    string
    \\    weight  f32       (default 0.5)
    \\    stack   u32       (default 1)
    \\    tags    [string]  (optional)
    \\    drops   id        (optional)
    \\    light   { radius f32  falloff f32 (default 2.0) }
    \\    grid    [[i32]]
    \\    heavy   i64
    \\    huge    u64
    \\    exact   f64
    \\    lit     bool
    \\}
    \\
    \\item foundry:item.torch {
    \\    name   "Torch"
    \\    weight 0.5
    \\    stack  20
    \\    tags   ["light" "fuel"]
    \\    drops  foundry:item.ash
    \\    light  { radius 6.0 }
    \\    grid   [[1 2] [3 4]]
    \\    heavy  -9007199254740993
    \\    huge   18446744073709551615
    \\    exact  0.1
    \\    lit    true
    \\}
    \\
    \\item foundry:item.ash {
    \\    name   "Ash"
    \\    light  { radius 0.0  falloff 0.0 }
    \\    grid   []
    \\    heavy  0
    \\    huge   0
    \\    exact  0.0
    \\    lit    false
    \\}
;

test "every value of every record survives the round trip" {
    var f = try Fixture.compile(round_trip_source);
    defer f.deinit();

    var r = try f.open();
    defer r.deinit();

    try testing.expect(r.id.eql(ContentId.fromString("foundry:core")));
    // The package says its own name, so a store can answer "who supplied this?" with
    // something a person can read.
    try testing.expectEqualStrings("foundry:core", r.name);
    try testing.expectEqual(@as(u32, 3), r.version);
    try testing.expectEqual(@as(u32, 1), r.schemaCount());
    try testing.expectEqual(@as(u32, 2), r.record_count);
    try testing.expectEqualStrings("foundry:item", r.schema_names[0]);

    var arena: core.Arena = .init(testing.allocator);
    defer arena.deinit();

    for (f.pkg.records(), 0..) |rec, i| {
        const view = r.record(@intCast(i)).?;
        try testing.expect(view.id.eql(rec.id));
        try testing.expect(view.schema_id.eql(rec.schema_id));
        try testing.expectEqualStrings(rec.text, view.name);

        const written = r.schemaFor(view.schema_id).?;
        const original = f.registry.get(rec.schema).?;
        const fields = r.fieldsOf(view, written.*);

        for (0..written.fields.len) |index| {
            const want = rec.value(original.*, @intCast(index));
            const got = try fields.valueAt(arena.allocator(), @intCast(index));
            if (want == null) {
                try testing.expect(got == null);
                continue;
            }
            try testing.expect(got != null);
            try testing.expect(got.?.eql(want.?));
        }
    }
}

test "the schema comes back the way it went in" {
    var f = try Fixture.compile(round_trip_source);
    defer f.deinit();

    var r = try f.open();
    defer r.deinit();

    const written = r.schemas[0];
    const original = f.registry.lookup(SchemaId.fromStringUnchecked("foundry:item")).?;
    try testing.expect(written.id.eql(original.id));
    try testing.expectEqual(original.version, written.version);
    try testing.expectEqual(original.fields.len, written.fields.len);

    for (original.fields, written.fields) |a, b| {
        try testing.expect(a.eql(b)); // name and type, including through lists and structs
        try testing.expectEqual(a.since, b.since);
        try testing.expectEqual(std.meta.activeTag(a.presence), std.meta.activeTag(b.presence));
        switch (a.presence) {
            .default => |d| try testing.expect(d.eql(b.presence.default)),
            else => {},
        }
    }
}

test "the typed accessors read out of the file without copying it" {
    var f = try Fixture.compile(round_trip_source);
    defer f.deinit();

    var r = try f.open();
    defer r.deinit();

    const view = r.record(0).?;
    const fields = r.fieldsOf(view, r.schemas[0]);

    const name = (try fields.stringAt(0)).?;
    try testing.expectEqualStrings("Torch", name);
    // Borrowed, not copied: the string is a slice of the file itself.
    try testing.expect(@intFromPtr(name.ptr) >= @intFromPtr(f.bytes.items.ptr));
    try testing.expect(@intFromPtr(name.ptr) < @intFromPtr(f.bytes.items.ptr) + f.bytes.items.len);

    try testing.expectEqual(@as(f64, 0.5), (try fields.floatAt(1)).?);
    try testing.expectEqual(@as(i128, 20), (try fields.intAt(2)).?);
    try testing.expectEqual(@as(i128, -9007199254740993), (try fields.intAt(7)).?);
    try testing.expectEqual(@as(i128, std.math.maxInt(u64)), (try fields.intAt(8)).?);
    try testing.expectEqual(@as(f64, 0.1), (try fields.floatAt(9)).?);
    try testing.expectEqual(true, (try fields.boolAt(10)).?);
    try testing.expect((try fields.idAt(4)).?.eql(ContentId.fromString("foundry:item.ash")));

    const tags = (try fields.listAt(3)).?;
    try testing.expectEqual(@as(u32, 2), tags.len);

    const light = (try fields.nestedAt(5)).?;
    try testing.expectEqual(@as(f64, 6.0), (try light.floatAt(0)).?);
    try testing.expectEqual(@as(f64, 2.0), (try light.floatAt(1)).?); // the schema's default

    const grid = (try fields.listAt(6)).?;
    try testing.expectEqual(@as(u32, 2), grid.len);

    // Asking for the wrong kind is a mistake in the reading code, and says so rather than
    // returning a number made of somebody's name.
    try testing.expectError(error.WrongType, fields.boolAt(0));
    try testing.expectError(error.WrongType, fields.intAt(1));
}

test "an absent optional is absent, and a defaulted one is not" {
    var f = try Fixture.compile(round_trip_source);
    defer f.deinit();

    var r = try f.open();
    defer r.deinit();

    const ash = r.fieldsOf(r.record(1).?, r.schemas[0]);
    try testing.expect(!ash.present(3)); // tags
    try testing.expect(!ash.present(4)); // drops
    try testing.expect((try ash.listAt(3)) == null);
    try testing.expect((try ash.idAt(4)) == null);

    // The defaults were filled by the checker, so they are ordinary present fields here.
    try testing.expect(ash.present(1));
    try testing.expectEqual(@as(f64, 0.5), (try ash.floatAt(1)).?);
    try testing.expectEqual(@as(i128, 1), (try ash.intAt(2)).?);

    // An empty list is present and empty, which is not the same as absent.
    try testing.expect(ash.present(6));
    try testing.expectEqual(@as(u32, 0), (try ash.listAt(6)).?.len);
}

test "an f32 field stores an f32, and an integer literal in one comes back a float" {
    var f = try Fixture.compile(
        \\@schema item { weight f32  size f64  count f32 }
        \\item foundry:item.torch { weight 0.1  size 0.1  count 2 }
    );
    defer f.deinit();

    var r = try f.open();
    defer r.deinit();
    const fields = r.fieldsOf(r.record(0).?, r.schemas[0]);

    // 0.1 is not representable in binary, so an f32 field quantises it. That is the
    // schema's promise rather than a loss: the alternative is a field that claims to be
    // an f32 and is not.
    try testing.expectEqual(@as(f64, @as(f32, 0.1)), (try fields.floatAt(0)).?);
    try testing.expect((try fields.floatAt(0)).? != @as(f64, 0.1));
    try testing.expectEqual(@as(f64, 0.1), (try fields.floatAt(1)).?);

    // The checker leaves an exact integer literal as an integer (§4.3); the format stores
    // what the schema declared.
    try testing.expectEqual(@as(f64, 2.0), (try fields.floatAt(2)).?);
}

test "strings are stored once no matter how often they are written" {
    var f = try Fixture.compile(
        \\@schema item { name string  other string }
        \\item foundry:item.a { name "same"  other "same" }
        \\item foundry:item.b { name "same"  other "same" }
    );
    defer f.deinit();

    var r = try f.open();
    defer r.deinit();

    // "same" appears four times in the content and once in the file.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.blocks.strings, "same"));

    const a = r.fieldsOf(r.record(0).?, r.schemas[0]);
    const b = r.fieldsOf(r.record(1).?, r.schemas[0]);
    try testing.expectEqualStrings("same", (try a.stringAt(0)).?);
    try testing.expectEqualStrings("same", (try b.stringAt(1)).?);
}

test "a record written against an older schema version is stored against the newer one" {
    var f = try Fixture.compile(
        \\@schema item { name string }
        \\item foundry:item.torch { name "Torch" }
        \\@schema item { name string  weight f32 (since 2) (default 0.5) }
        \\item foundry:item.ash { name "Ash"  weight 0.25 }
    );
    defer f.deinit();

    var r = try f.open();
    defer r.deinit();

    // One schema, at version 2, and both records laid out for it — the torch by way of
    // the default the extension had to bring with it.
    try testing.expectEqual(@as(u32, 1), r.schemaCount());
    try testing.expectEqual(@as(u32, 2), r.schemas[0].version);

    const torch = r.fieldsOf(r.record(0).?, r.schemas[0]);
    try testing.expectEqualStrings("Torch", (try torch.stringAt(0)).?);
    try testing.expectEqual(@as(f64, 0.5), (try torch.floatAt(1)).?);

    const ash = r.fieldsOf(r.record(1).?, r.schemas[0]);
    try testing.expectEqual(@as(f64, 0.25), (try ash.floatAt(1)).?);
}

test "a package with no records at all is still a package" {
    var f = try Fixture.compile("@schema item { name string }");
    defer f.deinit();

    var r = try f.open();
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), r.record_count);
    try testing.expectEqual(@as(u32, 1), r.schemaCount());
    try testing.expect(r.record(0) == null);
    try r.walk(testing.allocator);
}

test "the version is in a field, so a package from the future says which version it is" {
    var f = try Fixture.compile("@schema item { name string }");
    defer f.deinit();

    try testing.expectEqual(@as(u32, format_version), versionOf(f.bytes.items).?);

    const bytes = try testing.allocator.dupe(u8, f.bytes.items);
    defer testing.allocator.free(bytes);
    std.mem.writeInt(u32, bytes[4..8], 3, .little);

    try testing.expectEqual(@as(u32, 3), versionOf(bytes).?);
    try testing.expectError(error.UnsupportedVersion, Reader.open(testing.allocator, bytes, .default));

    // A flag this build does not know changes how bytes are read, so it is refused too.
    @memcpy(bytes, f.bytes.items);
    std.mem.writeInt(u32, bytes[20..24], 1, .little);
    try testing.expectError(error.UnsupportedFlags, Reader.open(testing.allocator, bytes, .default));
}

test "a file that is not a package is refused before anything is read out of it" {
    var rng: core.rng.Pcg32 = .init(0xf00d, 0);
    var buf: [512]u8 = undefined;

    try testing.expectError(error.NotAPackage, Reader.open(testing.allocator, "", .default));
    try testing.expectError(error.NotAPackage, Reader.open(testing.allocator, "FPKG", .default));

    for (0..64) |_| {
        for (&buf) |*b| b.* = @truncate(rng.next());
        try testing.expectError(error.NotAPackage, Reader.open(testing.allocator, &buf, .default));
    }

    // And with the magic and version made right, so the refusal has to come from the
    // structure rather than from the first four bytes.
    var refused: usize = 0;
    for (0..256) |_| {
        for (&buf) |*b| b.* = @truncate(rng.next());
        @memcpy(buf[0..4], magic);
        std.mem.writeInt(u32, buf[4..8], format_version, .little);
        std.mem.writeInt(u32, buf[20..24], 0, .little);
        var r = Reader.open(testing.allocator, &buf, .default) catch {
            refused += 1;
            continue;
        };
        defer r.deinit();
        r.walk(testing.allocator) catch {};
    }
    try testing.expect(refused > 0);
}

test "a valid package with one byte changed is refused or read safely, never dereferenced" {
    var f = try Fixture.compile(round_trip_source);
    defer f.deinit();

    const scratch = try testing.allocator.dupe(u8, f.bytes.items);
    defer testing.allocator.free(scratch);

    // Seeded, so a failure is reproducible: I9 applies to the tests as well as to the
    // engine. What is being asserted is that nothing panics — every out-of-bounds read
    // this could produce is a safety check in a debug build, so the test is the assertion.
    var rng: core.rng.Pcg32 = .init(0x5eed, 0);
    for (0..4000) |_| {
        @memcpy(scratch, f.bytes.items);
        const at = rng.below(@intCast(scratch.len));
        scratch[at] ^= @as(u8, @truncate(1 + rng.below(255)));

        var r = Reader.open(testing.allocator, scratch, .default) catch continue;
        defer r.deinit();
        r.walk(testing.allocator) catch continue;
    }
}

test "the sections say where they are, and they are where they say" {
    var f = try Fixture.compile(round_trip_source);
    defer f.deinit();
    const bytes = f.bytes.items;

    try testing.expectEqualStrings(magic, bytes[0..4]);
    // The four section refs only: the name ref that follows them points into the strings
    // section rather than being a section of its own.
    var at: usize = 32;
    var previous_end: u32 = header_size;
    while (at < 64) : (at += 8) {
        const offset = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const len = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        try testing.expectEqual(@as(u32, 0), offset % section_align);
        try testing.expect(offset >= previous_end);
        try testing.expect(offset + len <= bytes.len);
        previous_end = offset + len;
    }
    try testing.expectEqual(bytes.len, previous_end);
}

// -- the block layout on its own ---------------------------------------------------

test "blocks round-trip without a package around them" {
    // What a save does: lay out blocks against a schema, keep the two buffers, and read
    // them back with nothing but the schema that wrote them. No header, no record index,
    // no `Reader` — which is the whole point of the layout being separable.
    const gpa = testing.allocator;
    const fields = [_]Field{
        .{ .name = "x", .type = .f32, .presence = .optional },
        .{ .name = "label", .type = .string, .presence = .optional },
        .{ .name = "where", .type = .{ .nested = &.{
            .{ .name = "row", .type = .i32, .presence = .optional },
            .{ .name = "col", .type = .i32, .presence = .optional },
        } }, .presence = .optional },
        .{ .name = "absent", .type = .u64, .presence = .optional },
    };

    var w: BlockWriter = .{ .gpa = gpa };
    defer w.deinit();

    var offsets: [2]u32 = undefined;
    for (0..2) |i| {
        const block = try w.begin(&fields);
        offsets[i] = block.base;
        try block.set(0, .{ .float = @as(f64, @floatFromInt(i)) * 0.5 });
        try block.set(1, .{ .string = "shared" });
        const where = try block.nested(2);
        try where.set(0, .{ .int = @as(i64, @intCast(i)) });
        try where.set(1, .{ .int = 9 });
        // Field 3 is never set, so it reads back absent.
    }

    const blocks: Blocks = .{ .fields = w.fields.items, .strings = w.strings.items };
    for (0..2) |i| {
        const view = blocks.blockAt(offsets[i], &fields).?;
        try testing.expectEqual(@as(f64, @floatFromInt(i)) * 0.5, (try view.floatAt(0)).?);
        try testing.expectEqualStrings("shared", (try view.stringAt(1)).?);
        const where = (try view.nestedAt(2)).?;
        try testing.expectEqual(@as(i128, @intCast(i)), (try where.intAt(0)).?);
        try testing.expectEqual(@as(i128, 9), (try where.intAt(1)).?);
        try testing.expect(!view.present(3));
        try testing.expect((try view.intAt(3)) == null);
    }

    // One copy of the string, because interning is part of the layout rather than of the
    // package writer that used to own it.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.strings.items, "shared"));
}

test "a block refuses a value its field cannot hold" {
    const gpa = testing.allocator;
    const fields = [_]Field{
        .{ .name = "small", .type = .u32, .presence = .optional },
        .{ .name = "flat", .type = .i32, .presence = .optional },
    };

    var w: BlockWriter = .{ .gpa = gpa };
    defer w.deinit();
    const block = try w.begin(&fields);

    try testing.expectError(error.ValueTypeMismatch, block.set(0, .{ .int = 5_000_000_000 }));
    try testing.expectError(error.ValueTypeMismatch, block.set(0, .{ .bool = true }));
    // Not a nested field, and asking for it as one is a mistake in the writing code.
    try testing.expectError(error.ValueTypeMismatch, block.nested(1));
    // Past the schema's fields.
    try testing.expectError(error.ValueTypeMismatch, block.set(2, .{ .int = 0 }));
}
