//! Edits to `.fdt` source that change one construct and leave every other byte alone
//! (M15, ADR-0043, `docs/design/editor.md` §5).
//!
//! Each operation takes one file's bytes and the spans a parse with `Options.spans` gave
//! for them, and returns an `Edit`: one byte range and what replaces it. The range is the
//! construct itself, plus — for an insertion or a removal — the whitespace and at most one
//! line ending that separate it from its neighbours, so that removing a field neither
//! leaves a blank line where it was nor joins two lines together. Nothing else is ever in
//! the range: a comment beside a construct is outside it and stays, byte for byte; a comment
//! inside one goes with it. Line endings and indentation of new text are the file's own.
//!
//! Operations check before they cut. Bytes that are not the ones the spans were parsed from,
//! a span outside them or naming another file, and an index past the end are refused, so a
//! stale or hostile span is an error rather than an edit in the wrong place. `apply` checks
//! that edits are in order, do not overlap, and leave a file no larger than the parser takes.
//!
//! Deciding *whether* an edit is right — that a value suits its field, that the result still
//! parses — is the caller's, who holds the schema and re-parses the candidate (`editor.md`
//! §5). This file decides only *where* the bytes go.

const std = @import("std");

const emit = @import("emit.zig");
const limits_mod = @import("limits.zig");
const parser = @import("parser.zig");
const schema_mod = @import("schema.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const FieldSource = parser.FieldSource;
const FieldType = schema_mod.FieldType;
const Limits = limits_mod.Limits;
const RecordSource = parser.RecordSource;
const SourceFile = parser.SourceFile;
const Span = parser.Span;
const Value = value_mod.Value;
const ValueSource = parser.ValueSource;

/// One replaced range, half-open, in a file's current bytes.
pub const Edit = struct {
    start: u32,
    end: u32,
    /// What goes there. Allocated by the operation that made the edit; free it with `deinit`.
    text: []const u8,

    pub fn deinit(self: Edit, gpa: Allocator) void {
        gpa.free(self.text);
    }
};

/// One file's current bytes, beside what its parse recorded about them.
pub const Text = struct {
    /// This file's index in `Document.files`, which every span it is given must name.
    index: u32,
    file: SourceFile,
    bytes: []const u8,

    pub fn of(doc: *const parser.Document, index: u32, bytes: []const u8) Error!Text {
        if (index >= doc.files.len) return error.InvalidSpan;
        return .{ .index = index, .file = doc.files[index], .bytes = bytes };
    }
};

pub const Options = struct {
    /// Where content IDs in new values get their spelling (`emit.Spellings`).
    spellings: *const emit.Spellings,
    limits: Limits = .default,
};

pub const Error = error{
    /// The bytes are not the ones the spans were parsed from.
    StaleSource,
    /// A span outside the bytes, naming another file, or not the construct the operation
    /// needs — a container whose ends are not its brackets.
    InvalidSpan,
    /// Edits out of order, or overlapping.
    InvalidEdit,
    IndexOutOfRange,
    /// The result would be larger than a content file may be.
    SourceTooLarge,
} || emit.Error;

/// Checks that `text.bytes` are the bytes its spans describe.
pub fn verify(text: Text) Error!void {
    if (text.bytes.len != text.file.len) return error.StaleSource;
    if (std.hash.Wyhash.hash(0, text.bytes) != text.file.digest) return error.StaleSource;
}

/// The bytes with `edits` made, in a new allocation the caller owns.
///
/// Edits must be in order and must not overlap; two insertions at one offset go in the order
/// given.
pub fn apply(gpa: Allocator, bytes: []const u8, edits: []const Edit, limits: Limits) Error![]u8 {
    var size: usize = bytes.len;
    var at: u32 = 0;
    for (edits) |edit| {
        if (edit.start > edit.end or edit.end > bytes.len or edit.start < at) return error.InvalidEdit;
        at = edit.end;
        size = size - (edit.end - edit.start) + edit.text.len;
    }
    if (size > @min(limits.max_source_bytes, std.math.maxInt(u32))) return error.SourceTooLarge;

    const out = try gpa.alloc(u8, size);
    var from: usize = 0;
    var to: usize = 0;
    for (edits) |edit| {
        const kept = bytes[from..edit.start];
        @memcpy(out[to..][0..kept.len], kept);
        to += kept.len;
        @memcpy(out[to..][0..edit.text.len], edit.text);
        to += edit.text.len;
        from = edit.end;
    }
    @memcpy(out[to..], bytes[from..]);
    return out;
}

/// Replaces a value where it stands.
pub fn replaceValue(gpa: Allocator, options: Options, text: Text, target: ValueSource, t: FieldType, v: Value) Error!Edit {
    try verify(text);
    try checkSpan(text, target.span);
    const out = try written(gpa, options, text, target.span.start, .value, "", t, v);
    return .{ .start = target.span.start, .end = target.span.end, .text = out };
}

/// Adds a field at the end of a record body or an inline struct.
///
/// `container` is the braces and what is between them (`RecordSource.body`, or a struct's
/// `ValueSource.span`); `fields` are the fields written in it. In a body that spans lines the
/// field gets a line of its own, after the last field's line and any comment ending it; on
/// one line it joins them, two spaces after the last.
pub fn insertField(
    gpa: Allocator,
    options: Options,
    text: Text,
    container: Span,
    fields: []const FieldSource,
    name: []const u8,
    t: FieldType,
    v: Value,
) Error!Edit {
    try verify(text);
    try checkContainer(text, container, '{', '}');
    for (fields) |f| try checkInside(text, container, f.span());
    const elements = try spansOf(gpa, fields);
    defer gpa.free(elements);
    return insertAt(gpa, options, text, container, elements, elements.len, .{ .field = name }, t, v);
}

/// Removes one field of a record body or an inline struct.
pub fn removeField(gpa: Allocator, text: Text, container: Span, fields: []const FieldSource, index: usize) Error!Edit {
    try verify(text);
    try checkContainer(text, container, '{', '}');
    for (fields) |f| try checkInside(text, container, f.span());
    if (index >= fields.len) return error.IndexOutOfRange;
    const elements = try spansOf(gpa, fields);
    defer gpa.free(elements);
    return removal(text.bytes, elements, index, container.end - 1);
}

/// Adds an element to a list, so that it ends up at `index`.
pub fn insertItem(gpa: Allocator, options: Options, text: Text, list: ValueSource, index: usize, elem: FieldType, v: Value) Error!Edit {
    try verify(text);
    try checkContainer(text, list.span, '[', ']');
    for (list.items) |item| try checkInside(text, list.span, item.span);
    if (index > list.items.len) return error.IndexOutOfRange;
    const elements = try itemSpans(gpa, list);
    defer gpa.free(elements);
    return insertAt(gpa, options, text, list.span, elements, index, .item, elem, v);
}

/// Removes one element of a list.
pub fn removeItem(gpa: Allocator, text: Text, list: ValueSource, index: usize) Error!Edit {
    try verify(text);
    try checkContainer(text, list.span, '[', ']');
    for (list.items) |item| try checkInside(text, list.span, item.span);
    if (index >= list.items.len) return error.IndexOutOfRange;
    const elements = try itemSpans(gpa, list);
    defer gpa.free(elements);
    return removal(text.bytes, elements, index, list.span.end - 1);
}

/// Moves one element of a list so that it ends up at index `to`.
///
/// The elements trade places and everything between them stays where it is, comments
/// included: a comment between two elements belongs to the gap, not to either of them.
pub fn moveItem(gpa: Allocator, text: Text, list: ValueSource, from: usize, to: usize) Error!Edit {
    try verify(text);
    try checkContainer(text, list.span, '[', ']');
    for (list.items) |item| try checkInside(text, list.span, item.span);
    if (from >= list.items.len or to >= list.items.len) return error.IndexOutOfRange;
    const items = list.items;
    if (from == to) return .{ .start = items[from].span.start, .end = items[from].span.start, .text = "" };

    const lo = @min(from, to);
    const hi = @max(from, to);
    const bytes = text.bytes;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lo..hi + 1) |k| {
        // Which original element lands at position `k`.
        const source = if (k == to) from else if (from < to) k + 1 else k - 1;
        try out.appendSlice(gpa, bytes[items[source].span.start..items[source].span.end]);
        if (k != hi) try out.appendSlice(gpa, bytes[items[k].span.end..items[k + 1].span.start]);
    }
    return .{ .start = items[lo].span.start, .end = items[hi].span.end, .text = try out.toOwnedSlice(gpa) };
}

/// Adds a record at the end of a file, after one blank line. `record` is a record's text
/// without a line ending (`emit.writeRecord`, or `duplicateRecord`).
pub fn appendRecord(gpa: Allocator, text: Text, record: []const u8) Error!Edit {
    try verify(text);
    const bytes = text.bytes;
    const nl = emit.Newline.detect(bytes).text();
    const content_end = std.mem.trimEnd(u8, bytes, " \t\r\n").len;
    const empty = content_end <= bomLength(bytes);
    const breaks = std.mem.count(u8, bytes[content_end..], "\n");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (!empty) for (0..2 -| breaks) |_| try out.appendSlice(gpa, nl);
    try out.appendSlice(gpa, record);
    try out.appendSlice(gpa, nl);
    const len: u32 = @intCast(bytes.len);
    return .{ .start = len, .end = len, .text = try out.toOwnedSlice(gpa) };
}

/// Adds a record after another, with one blank line between them.
pub fn insertRecordAfter(gpa: Allocator, text: Text, after: RecordSource, record: []const u8) Error!Edit {
    try verify(text);
    try checkSpan(text, after.span);
    const nl = emit.Newline.detect(text.bytes).text();
    // After any comment ending the record's last line, so that comment stays with it.
    const at = lineContentEnd(text.bytes, after.span.end);
    const out = try std.mem.concat(gpa, u8, &.{ nl, nl, record });
    return .{ .start = at, .end = at, .text = out };
}

/// Removes a record: the lines it occupies when it has them to itself, otherwise just it
/// and the space beside it.
pub fn removeRecord(gpa: Allocator, text: Text, record: RecordSource) Error!Edit {
    _ = gpa;
    try verify(text);
    try checkSpan(text, record.span);
    return removal(text.bytes, &.{record.span}, 0, null);
}

/// A copy of a record's text under a new ID. Everything else — its fields, their layout,
/// comments inside it — is copied exactly.
pub fn duplicateRecord(gpa: Allocator, options: Options, text: Text, record: RecordSource, new_id: []const u8) Error![]u8 {
    try verify(text);
    try checkSpan(text, record.span);
    try checkInside(text, record.span, record.id);
    _ = try emit.checkSpelling(options.spellings, new_id);
    const bytes = text.bytes;
    return std.mem.concat(gpa, u8, &.{
        bytes[record.span.start..record.id.start],
        new_id,
        bytes[record.id.end..record.span.end],
    });
}

// --- placement -------------------------------------------------------------

const Kind = union(enum) {
    /// A field, and its name.
    field: []const u8,
    item,
    value,
};

/// Inserts a new element so that it ends up at `index` among `elements`, inside `container`
/// (whose first and last bytes are its brackets).
fn insertAt(
    gpa: Allocator,
    options: Options,
    text: Text,
    container: Span,
    elements: []const Span,
    index: usize,
    kind: Kind,
    t: FieldType,
    v: Value,
) Error!Edit {
    const bytes = text.bytes;
    const open = container.start;
    const close = container.end - 1;
    const nl = emit.Newline.detect(bytes).text();
    const separator = if (kind == .field) "  " else " ";

    if (std.mem.indexOfScalar(u8, bytes[open..close], '\n') == null) {
        // One line: the element joins it.
        if (elements.len == 0) {
            // Replacing the space between the brackets, which is only ever blanks: on one
            // line, a comment would have run to its end and taken the closing bracket.
            // Anything else means the span is not an empty container, and nothing is cut.
            for (bytes[open + 1 .. close]) |c| if (c != ' ' and c != '\t' and c != '\r') return error.InvalidSpan;
            const pad = if (kind == .field) " " else "";
            const out = try written(gpa, options, text, open, kind, pad, t, v);
            errdefer gpa.free(out);
            const padded = try std.mem.concat(gpa, u8, &.{ out, pad });
            gpa.free(out);
            return .{ .start = open + 1, .end = close, .text = padded };
        }
        if (index < elements.len) {
            const at = elements[index].start;
            const out = try written(gpa, options, text, at, kind, "", t, v);
            errdefer gpa.free(out);
            const joined = try std.mem.concat(gpa, u8, &.{ out, separator });
            gpa.free(out);
            return .{ .start = at, .end = at, .text = joined };
        }
        const at = elements[elements.len - 1].end;
        const out = try written(gpa, options, text, at, kind, separator, t, v);
        return .{ .start = at, .end = at, .text = out };
    }

    if (index < elements.len and firstOnLine(bytes, elements[index].start)) {
        // Before an element with a line of its own: a line of the same indentation above it.
        const at = elements[index].start;
        const indent = indentOf(bytes, at);
        const out = try written(gpa, options, text, at, kind, "", t, v);
        errdefer gpa.free(out);
        const joined = try std.mem.concat(gpa, u8, &.{ out, nl, indent });
        gpa.free(out);
        return .{ .start = at, .end = at, .text = joined };
    }
    if (index < elements.len) {
        const at = elements[index].start;
        const out = try written(gpa, options, text, at, kind, "", t, v);
        errdefer gpa.free(out);
        const joined = try std.mem.concat(gpa, u8, &.{ out, separator });
        gpa.free(out);
        return .{ .start = at, .end = at, .text = joined };
    }

    // At the end: a new line after the last element's, or the opening bracket's. Past a
    // comment that ends that line, so the comment stays with what it was written beside —
    // unless the closing bracket is on that line too, in which case before the bracket.
    const anchor = if (elements.len > 0) elements[elements.len - 1].end else open + 1;
    const line_end = lineContentEnd(bytes, anchor);
    const at = if (close < line_end) anchor else line_end;

    var indent_buf: std.ArrayList(u8) = .empty;
    defer indent_buf.deinit(gpa);
    if (elements.len > 0 and firstOnLine(bytes, elements[elements.len - 1].start)) {
        try indent_buf.appendSlice(gpa, indentOf(bytes, elements[elements.len - 1].start));
    } else if (firstOnLine(bytes, close)) {
        try indent_buf.appendSlice(gpa, indentOf(bytes, close));
        try indent_buf.appendSlice(gpa, emit.indent_step);
    } else {
        try indent_buf.appendSlice(gpa, indentOf(bytes, open));
        try indent_buf.appendSlice(gpa, emit.indent_step);
    }
    const out = try writtenWithIndent(gpa, options, text, indent_buf.items, kind, t, v);
    errdefer gpa.free(out);
    const joined = try std.mem.concat(gpa, u8, &.{ nl, indent_buf.items, out });
    gpa.free(out);
    return .{ .start = at, .end = at, .text = joined };
}

/// The range that removes `elements[index]`.
///
/// Alone on its lines, the lines go, with one line ending. Sharing a line, the element goes
/// with the blanks between it and the next element on that line, or else the blanks before
/// it — or, first on its line and followed by a comment or the closing bracket, the blanks
/// after it, so the comment keeps its indentation.
fn removal(bytes: []const u8, elements: []const Span, index: usize, close: ?u32) Error!Edit {
    const s = elements[index];
    const line_start = lineStart(bytes, s.start);
    const line_end = lineContentEnd(bytes, s.end);
    if (isBlank(bytes[line_start..s.start]) and isBlank(bytes[s.end..line_end])) {
        return .{ .start = line_start, .end = afterLineEnding(bytes, line_end), .text = "" };
    }

    if (index + 1 < elements.len) {
        const next = elements[index + 1].start;
        if (next <= line_end and isBlank(bytes[s.end..next])) return .{ .start = s.start, .end = next, .text = "" };
    }
    const before = skipBlanksBack(bytes, s.start);
    if (before > line_start) return .{ .start = before, .end = s.end, .text = "" };
    var after = skipBlanks(bytes, s.end);
    if (close) |c| after = @min(after, c);
    return .{ .start = s.start, .end = after, .text = "" };
}

/// The text of a new element, whose first byte goes at `at`: indented, if it is a block,
/// from the line `at` is on.
fn written(
    gpa: Allocator,
    options: Options,
    text: Text,
    at: u32,
    kind: Kind,
    prefix: []const u8,
    t: FieldType,
    v: Value,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, prefix);
    const ctx: emit.Context = .{
        .spellings = options.spellings,
        .newline = emit.Newline.detect(text.bytes),
        .indent = indentOf(text.bytes, at),
        .limits = options.limits,
    };
    switch (kind) {
        .field => |name| try emit.writeField(&out, gpa, ctx, name, t, v),
        .item, .value => try emit.writeValue(&out, gpa, ctx, t, v),
    }
    return out.toOwnedSlice(gpa);
}

fn writtenWithIndent(gpa: Allocator, options: Options, text: Text, indent: []const u8, kind: Kind, t: FieldType, v: Value) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const ctx: emit.Context = .{
        .spellings = options.spellings,
        .newline = emit.Newline.detect(text.bytes),
        .indent = indent,
        .limits = options.limits,
    };
    switch (kind) {
        .field => |name| try emit.writeField(&out, gpa, ctx, name, t, v),
        .item, .value => try emit.writeValue(&out, gpa, ctx, t, v),
    }
    return out.toOwnedSlice(gpa);
}

// --- checks ----------------------------------------------------------------

fn checkSpan(text: Text, s: Span) Error!void {
    if (s.file != text.index or s.start > s.end or s.end > text.bytes.len) return error.InvalidSpan;
}

fn checkInside(text: Text, outer: Span, inner: Span) Error!void {
    try checkSpan(text, inner);
    if (inner.start < outer.start or inner.end > outer.end) return error.InvalidSpan;
}

fn checkContainer(text: Text, s: Span, open: u8, close: u8) Error!void {
    try checkSpan(text, s);
    if (s.len() < 2 or text.bytes[s.start] != open or text.bytes[s.end - 1] != close) return error.InvalidSpan;
}

fn spansOf(gpa: Allocator, fields: []const FieldSource) Allocator.Error![]Span {
    const out = try gpa.alloc(Span, fields.len);
    for (fields, out) |f, *s| s.* = f.span();
    return out;
}

fn itemSpans(gpa: Allocator, list: ValueSource) Allocator.Error![]Span {
    const out = try gpa.alloc(Span, list.items.len);
    for (list.items, out) |item, *s| s.* = item.span;
    return out;
}

// --- lines -----------------------------------------------------------------

fn bomLength(bytes: []const u8) u32 {
    return if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) 3 else 0;
}

/// The first byte of the line holding `pos`. A byte-order mark is not part of the first line.
fn lineStart(bytes: []const u8, pos: u32) u32 {
    const start: u32 = if (std.mem.lastIndexOfScalar(u8, bytes[0..pos], '\n')) |i| @intCast(i + 1) else 0;
    const bom = bomLength(bytes);
    return if (start < bom and pos >= bom) bom else start;
}

/// Where the line holding `pos` ends, before its `\n` or `\r\n` — or the end of the file.
fn lineContentEnd(bytes: []const u8, pos: u32) u32 {
    const nl: u32 = if (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |i| @intCast(i) else return @intCast(bytes.len);
    return if (nl > pos and bytes[nl - 1] == '\r') nl - 1 else nl;
}

/// Past the line ending that begins at `pos`, if one does.
fn afterLineEnding(bytes: []const u8, pos: u32) u32 {
    if (std.mem.startsWith(u8, bytes[pos..], "\r\n")) return pos + 2;
    if (std.mem.startsWith(u8, bytes[pos..], "\n")) return pos + 1;
    return pos;
}

fn isBlank(bytes: []const u8) bool {
    for (bytes) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn firstOnLine(bytes: []const u8, pos: u32) bool {
    return isBlank(bytes[lineStart(bytes, pos)..pos]);
}

/// The leading blanks of the line holding `pos`.
fn indentOf(bytes: []const u8, pos: u32) []const u8 {
    const start = lineStart(bytes, pos);
    var end = start;
    while (end < bytes.len and (bytes[end] == ' ' or bytes[end] == '\t')) end += 1;
    return bytes[start..end];
}

fn skipBlanks(bytes: []const u8, pos: u32) u32 {
    var i = pos;
    while (i < bytes.len and (bytes[i] == ' ' or bytes[i] == '\t')) i += 1;
    return i;
}

fn skipBlanksBack(bytes: []const u8, pos: u32) u32 {
    var i = pos;
    while (i > 0 and (bytes[i - 1] == ' ' or bytes[i - 1] == '\t')) i -= 1;
    return i;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Diagnostics = @import("diagnostic.zig").Diagnostics;
const core = @import("core");

/// A resolver over a hash map, as `parser.zig`'s tests use: no disk.
const Files = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn resolver(self: *Files) parser.Resolver {
        return .{ .ctx = self, .resolveFn = resolve };
    }

    fn resolve(ctx: *anyopaque, importer: []const u8, requested: []const u8) parser.Resolution {
        _ = importer;
        const self: *Files = @ptrCast(@alignCast(ctx));
        const bytes = self.map.get(requested) orelse return .not_found;
        return .{ .found = .{ .name = requested, .bytes = bytes } };
    }
};

fn parseSpans(gpa: Allocator, bytes: []const u8, files: ?*Files) !parser.Document {
    var diags: Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    return parser.parse(gpa, "items.fdt", bytes, .{
        .namespace = "foundry",
        .spans = true,
        .resolver = if (files) |f| f.resolver() else null,
    }, &diags);
}

/// Applies one edit and frees it.
fn applied(gpa: Allocator, bytes: []const u8, edit: Edit) ![]u8 {
    defer edit.deinit(gpa);
    return apply(gpa, bytes, &.{edit}, .default);
}

/// The bytes an edit removes, other than the construct itself, are separators only: blanks
/// and at most a line ending. Anything else — a comment, a neighbour — would be lost.
fn expectOnlySeparators(bytes: []const u8, edit: Edit, construct: Span) !void {
    try testing.expect(edit.start <= construct.start and construct.end <= edit.end);
    for (bytes[edit.start..construct.start]) |c| try testing.expect(std.mem.indexOfScalar(u8, " \t\r\n", c) != null);
    for (bytes[construct.end..edit.end]) |c| try testing.expect(std.mem.indexOfScalar(u8, " \t\r\n", c) != null);
    try testing.expect(std.mem.count(u8, bytes[edit.start..construct.start], "\n") + std.mem.count(u8, bytes[construct.end..edit.end], "\n") <= 1);
}

const no_spellings: emit.Spellings = .empty;
const opts: Options = .{ .spellings = &no_spellings };

const rich =
    \\# Items. The comments here are the author's and must survive.
    \\@import "shared.fdt"
    \\
    \\@schema foundry:item {
    \\    name   string
    \\    weight f32 (optional)
    \\    tags   [string] (optional)
    \\    light  { radius f32  falloff f32 (default 2.0) } (optional)
    \\    drops  id (optional)
    \\    rows   [[string]] (optional)
    \\}
    \\
    \\item foundry:item.torch {
    \\    name    "Torch"   # shown in the inventory
    \\    weight  0.5
    \\    tags    ["light" "fuel"]
    \\    light   { radius 6.0  falloff 2.0 }
    \\    drops   foundry:item.ash
    \\    rows    [
    \\        ["a" "b"]  # first row
    \\        ["c"]
    \\    ]
    \\}
    \\
    \\@patch foundry:item.ash { weight 0.4 }
    \\@remove foundry:item.old
    \\
;
const shared =
    \\item foundry:item.ash {
    \\    name "Ash"
    \\}
    \\
;

fn fieldType(doc: *const parser.Document, name: []const u8) FieldType {
    for (doc.schemas[0].fields) |f| if (std.mem.eql(u8, f.name, name)) return f.type;
    unreachable;
}

test "spans cover exactly what was written, in the file that wrote it" {
    var files: Files = .{};
    defer files.map.deinit(testing.allocator);
    try files.map.put(testing.allocator, "shared.fdt", shared);
    var doc = try parseSpans(testing.allocator, rich, &files);
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), doc.files.len);
    try testing.expectEqualStrings("items.fdt", doc.files[0].name);
    try testing.expectEqual(@as(?u32, null), doc.files[0].importer);
    try testing.expectEqualStrings("shared.fdt", doc.files[1].name);
    try testing.expectEqual(@as(?u32, 0), doc.files[1].importer);
    try testing.expectEqual(@as(u32, shared.len), doc.files[1].len);
    try testing.expectEqual(@as(usize, 1), doc.imports.len);
    try testing.expectEqualStrings("@import \"shared.fdt\"", rich[doc.imports[0].span.start..doc.imports[0].span.end]);
    try testing.expectEqual(@as(?u32, 1), doc.imports[0].file);

    const schema = doc.schemas[0].source.?;
    try testing.expect(std.mem.startsWith(u8, rich[schema.start..schema.end], "@schema foundry:item {"));
    try testing.expect(std.mem.endsWith(u8, rich[schema.start..schema.end], "(optional)\n}"));

    // Imports are spliced where they are written, so the imported record comes first — and
    // its spans are in its own file.
    const ash = doc.records[0].source.?;
    try testing.expectEqual(@as(u32, 1), ash.span.file);
    try testing.expectEqualStrings("item foundry:item.ash {\n    name \"Ash\"\n}", shared[ash.span.start..ash.span.end]);

    const torch = doc.records[1].source.?;
    const t = rich;
    try testing.expectEqual(@as(u32, 0), torch.span.file);
    try testing.expectEqualStrings("item", t[torch.head.start..torch.head.end]);
    try testing.expectEqualStrings("foundry:item.torch", t[torch.id.start..torch.id.end]);
    try testing.expect(t[torch.body.?.start] == '{' and t[torch.body.?.end - 1] == '}');
    try testing.expectEqual(torch.body.?.end, torch.span.end);
    try testing.expectEqual(@as(usize, 6), torch.fields.len);
    try testing.expectEqualStrings("name", t[torch.fields[0].name.start..torch.fields[0].name.end]);
    try testing.expectEqualStrings("\"Torch\"", t[torch.fields[0].value.span.start..torch.fields[0].value.span.end]);
    try testing.expectEqualStrings("[\"light\" \"fuel\"]", t[torch.fields[2].value.span.start..torch.fields[2].value.span.end]);
    try testing.expectEqualStrings("\"fuel\"", t[torch.fields[2].value.items[1].span.start..torch.fields[2].value.items[1].span.end]);
    const light = torch.fields[3].value;
    try testing.expectEqualStrings("{ radius 6.0  falloff 2.0 }", t[light.span.start..light.span.end]);
    try testing.expectEqualStrings("falloff 2.0", t[light.fields[1].span().start..light.fields[1].span().end]);
    const rows = torch.fields[5].value;
    try testing.expectEqualStrings("[\"a\" \"b\"]", t[rows.items[0].span.start..rows.items[0].span.end]);
    try testing.expectEqualStrings("\"b\"", t[rows.items[0].items[1].span.start..rows.items[0].items[1].span.end]);

    const patch = doc.records[2].source.?;
    try testing.expectEqualStrings("@patch foundry:item.ash { weight 0.4 }", t[patch.span.start..patch.span.end]);
    const remove = doc.records[3].source.?;
    try testing.expectEqualStrings("@remove foundry:item.old", t[remove.span.start..remove.span.end]);
    try testing.expectEqual(@as(?Span, null), remove.body);

    // Every value span, parsed on its own, is the value the document holds.
    for (doc.records[1].fields, torch.fields) |decl, where| {
        const alone = try std.fmt.allocPrint(testing.allocator, "x foundry:r {{ f {s} }}", .{t[where.value.span.start..where.value.span.end]});
        defer testing.allocator.free(alone);
        var again = try parseSpans(testing.allocator, alone, null);
        defer again.deinit(testing.allocator);
        try testing.expect(again.records[0].fields[0].value.eql(decl.value));
    }
}

test "spans are only recorded when asked for" {
    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    var doc = try parser.parse(testing.allocator, "a.fdt", "item foundry:item.a { name \"A\" }", .{ .namespace = "foundry" }, &diags);
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), doc.files.len);
    try testing.expect(doc.records[0].source == null);
}

test "a malformed file gives no spans to edit with" {
    try testing.expectError(error.ContentInvalid, parseSpans(testing.allocator, "item foundry:item.a { name }", null));
}

/// Parses `src`, makes the edit `f` chooses, and checks the result against `expected`.
fn expectEdit(
    src: []const u8,
    expected: []const u8,
    comptime f: fn (gpa: Allocator, doc: *const parser.Document, text: Text) anyerror!Edit,
) !void {
    var doc = try parseSpans(testing.allocator, src, null);
    defer doc.deinit(testing.allocator);
    const text = try Text.of(&doc, 0, src);
    const out = try applied(testing.allocator, src, try f(testing.allocator, &doc, text));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
    // Whatever the edit, the result is still `.fdt`.
    var again = try parseSpans(testing.allocator, out, null);
    again.deinit(testing.allocator);
}

test "replacing a value changes its bytes and no others" {
    const src = "item foundry:item.a {  # note\n    weight 0.5  # heavy\n    tags [\"a\"]\n}\n";
    try expectEdit(src, "item foundry:item.a {  # note\n    weight 0.25  # heavy\n    tags [\"a\"]\n}\n", struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const edit = try replaceValue(gpa, opts, text, doc.records[0].source.?.fields[0].value, .f32, .{ .float = 0.25 });
            try testing.expectEqual(doc.records[0].source.?.fields[0].value.span.start, edit.start);
            try testing.expectEqual(doc.records[0].source.?.fields[0].value.span.end, edit.end);
            return edit;
        }
    }.f);
    // A block value takes the indentation of the line it starts on, and the file's endings.
    const crlf = "item foundry:item.a {\r\n    rows []\r\n}\r\n";
    try expectEdit(crlf, "item foundry:item.a {\r\n    rows [\r\n        [\"x\"]\r\n    ]\r\n}\r\n", struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const inner: FieldType = .string;
            const elem: FieldType = .{ .list = &inner };
            return replaceValue(gpa, opts, text, doc.records[0].source.?.fields[0].value, .{ .list = &elem }, .{ .list = &.{.{ .list = &.{.{ .string = "x" }} }} });
        }
    }.f);
}

test "a field added to a body on several lines gets its own, after any comment ending the last" {
    try expectEdit(
        "item foundry:item.a {\n    name \"A\"  # shown\n}\n",
        "item foundry:item.a {\n    name \"A\"  # shown\n    weight 0.5\n}\n",
        struct {
            fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
                const r = doc.records[0].source.?;
                return insertField(gpa, opts, text, r.body.?, r.fields, "weight", .f32, .{ .float = 0.5 });
            }
        }.f,
    );
    try expectEdit(
        "\t item foundry:item.a {  # empty\n\t }\n",
        "\t item foundry:item.a {  # empty\n\t     weight 0.5\n\t }\n",
        struct {
            fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
                const r = doc.records[0].source.?;
                return insertField(gpa, opts, text, r.body.?, r.fields, "weight", .f32, .{ .float = 0.5 });
            }
        }.f,
    );
    // The closing brace on the last field's line stays after the new field.
    try expectEdit(
        "item foundry:item.a {\n    name \"A\" }\n",
        "item foundry:item.a {\n    name \"A\"\n    weight 0.5 }\n",
        struct {
            fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
                const r = doc.records[0].source.?;
                return insertField(gpa, opts, text, r.body.?, r.fields, "weight", .f32, .{ .float = 0.5 });
            }
        }.f,
    );
}

test "a field added on one line joins it, and an empty pair of braces opens up" {
    try expectEdit("item foundry:item.a { name \"A\" }", "item foundry:item.a { name \"A\"  weight 0.5 }", struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const r = doc.records[0].source.?;
            return insertField(gpa, opts, text, r.body.?, r.fields, "weight", .f32, .{ .float = 0.5 });
        }
    }.f);
    try expectEdit("item foundry:item.a {}", "item foundry:item.a { weight 0.5 }", struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const r = doc.records[0].source.?;
            return insertField(gpa, opts, text, r.body.?, r.fields, "weight", .f32, .{ .float = 0.5 });
        }
    }.f);
    try expectEdit("item foundry:item.a { light { radius 6.0 } }", "item foundry:item.a { light { radius 6.0  falloff 2.0 } }", struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const light = doc.records[0].source.?.fields[0].value;
            return insertField(gpa, opts, text, light.span, light.fields, "falloff", .f32, .{ .float = 2.0 });
        }
    }.f);
}

const removal_src =
    \\item foundry:item.torch {
    \\    name    "Torch"   # shown in the inventory
    \\    weight  0.5
    \\    light   { radius 6.0  falloff 2.0 }
    \\}
    \\
;

test "removing a field takes its line, or its place on a shared one, and nothing beside it" {
    try expectEdit(removal_src,
        \\item foundry:item.torch {
        \\    name    "Torch"   # shown in the inventory
        \\    light   { radius 6.0  falloff 2.0 }
        \\}
        \\
    , struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const r = doc.records[0].source.?;
            const edit = try removeField(gpa, text, r.body.?, r.fields, 1);
            try expectOnlySeparators(text.bytes, edit, r.fields[1].span());
            return edit;
        }
    }.f);
    try expectEdit(removal_src,
        \\item foundry:item.torch {
        \\    name    "Torch"   # shown in the inventory
        \\    weight  0.5
        \\    light   { radius 6.0 }
        \\}
        \\
    , struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const light = doc.records[0].source.?.fields[2].value;
            const edit = try removeField(gpa, text, light.span, light.fields, 1);
            try expectOnlySeparators(text.bytes, edit, light.fields[1].span());
            return edit;
        }
    }.f);
    try expectEdit(removal_src,
        \\item foundry:item.torch {
        \\    name    "Torch"   # shown in the inventory
        \\    weight  0.5
        \\    light   { falloff 2.0 }
        \\}
        \\
    , struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const light = doc.records[0].source.?.fields[2].value;
            const edit = try removeField(gpa, text, light.span, light.fields, 0);
            try expectOnlySeparators(text.bytes, edit, light.fields[0].span());
            return edit;
        }
    }.f);
}

test "a comment beside a removed field outlives it" {
    // The preservation guard: a line is taken whole only when nothing but blanks is left on
    // it. A field with a comment after it goes; the comment stays, at its indentation.
    try expectEdit(removal_src,
        \\item foundry:item.torch {
        \\    # shown in the inventory
        \\    weight  0.5
        \\    light   { radius 6.0  falloff 2.0 }
        \\}
        \\
    , struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const r = doc.records[0].source.?;
            const edit = try removeField(gpa, text, r.body.?, r.fields, 0);
            try expectOnlySeparators(text.bytes, edit, r.fields[0].span());
            return edit;
        }
    }.f);
}

const list_src =
    \\item foundry:item.a {
    \\    tags [
    \\        "a"  # first
    \\        "b"
    \\    ]
    \\    flat ["a" "b" "c"]
    \\    none []
    \\}
    \\
;

fn listEdit(comptime field: usize, comptime op: enum { insert, remove, move }, comptime a: usize, comptime b: usize) fn (Allocator, *const parser.Document, Text) anyerror!Edit {
    return struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const list = doc.records[0].source.?.fields[field].value;
            return switch (op) {
                .insert => insertItem(gpa, opts, text, list, a, .string, .{ .string = "x" }),
                .remove => blk: {
                    const edit = try removeItem(gpa, text, list, a);
                    try expectOnlySeparators(text.bytes, edit, list.items[a].span);
                    break :blk edit;
                },
                .move => moveItem(gpa, text, list, a, b),
            };
        }
    }.f;
}

fn listCase(comptime field: usize, comptime op: anytype, comptime a: usize, comptime b: usize, expected_field: []const u8) !void {
    const lines = [_][]const u8{ "    tags [\n        \"a\"  # first\n        \"b\"\n    ]\n", "    flat [\"a\" \"b\" \"c\"]\n", "    none []\n" };
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, "item foundry:item.a {\n");
    for (lines, 0..) |line, i| try expected.appendSlice(testing.allocator, if (i == field) expected_field else line);
    try expected.appendSlice(testing.allocator, "}\n");
    try expectEdit(list_src, expected.items, listEdit(field, op, a, b));
}

test "list elements go in, come out and move where they stand" {
    try listCase(0, .insert, 1, 0, "    tags [\n        \"a\"  # first\n        \"x\"\n        \"b\"\n    ]\n");
    try listCase(0, .insert, 0, 0, "    tags [\n        \"x\"\n        \"a\"  # first\n        \"b\"\n    ]\n");
    try listCase(0, .insert, 2, 0, "    tags [\n        \"a\"  # first\n        \"b\"\n        \"x\"\n    ]\n");
    try listCase(0, .remove, 0, 0, "    tags [\n        # first\n        \"b\"\n    ]\n");
    try listCase(0, .remove, 1, 0, "    tags [\n        \"a\"  # first\n    ]\n");
    // The elements trade places; the comment between them stays in the gap.
    try listCase(0, .move, 0, 1, "    tags [\n        \"b\"  # first\n        \"a\"\n    ]\n");

    try listCase(1, .insert, 1, 0, "    flat [\"a\" \"x\" \"b\" \"c\"]\n");
    try listCase(1, .insert, 3, 0, "    flat [\"a\" \"b\" \"c\" \"x\"]\n");
    try listCase(1, .remove, 1, 0, "    flat [\"a\" \"c\"]\n");
    try listCase(1, .remove, 2, 0, "    flat [\"a\" \"b\"]\n");
    try listCase(1, .remove, 0, 0, "    flat [\"b\" \"c\"]\n");
    try listCase(1, .move, 2, 0, "    flat [\"c\" \"a\" \"b\"]\n");
    try listCase(1, .move, 0, 2, "    flat [\"b\" \"c\" \"a\"]\n");
    try listCase(1, .move, 1, 1, "    flat [\"a\" \"b\" \"c\"]\n");

    try listCase(2, .insert, 0, 0, "    none [\"x\"]\n");
}

const records_src =
    \\# a comment
    \\item foundry:item.a {
    \\    name "A"  # note
    \\}
    \\
    \\item foundry:item.b {
    \\}
    \\
;

test "records are appended after one blank line, inserted after a neighbour and removed whole" {
    try expectEdit(records_src, records_src ++ "\nitem foundry:item.c {\n}\n", struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            _ = doc;
            return appendRecord(gpa, text, "item foundry:item.c {\n}");
        }
    }.f);
    try expectEdit(records_src,
        \\# a comment
        \\item foundry:item.a {
        \\    name "A"  # note
        \\}
        \\
        \\item foundry:item.c {
        \\}
        \\
        \\item foundry:item.b {
        \\}
        \\
    , struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            return insertRecordAfter(gpa, text, doc.records[0].source.?.*, "item foundry:item.c {\n}");
        }
    }.f);
    try expectEdit(records_src, "# a comment\n\nitem foundry:item.b {\n}\n", struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            const r = doc.records[0].source.?.*;
            const edit = try removeRecord(gpa, text, r);
            try expectOnlySeparators(text.bytes, edit, r.span);
            return edit;
        }
    }.f);

    // However the file ends, the new record gets one blank line before it, and the file's
    // line endings. An empty file, or one with only a byte-order mark, gets none.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "item foundry:item.a {}", "item foundry:item.a {}\n\nitem foundry:item.c {}\n" },
        .{ "item foundry:item.a {}\n\n\n", "item foundry:item.a {}\n\n\nitem foundry:item.c {}\n" },
        .{ "item foundry:item.a {}\r\n", "item foundry:item.a {}\r\n\r\nitem foundry:item.c {}\r\n" },
        .{ "", "item foundry:item.c {}\n" },
        .{ "\xEF\xBB\xBF", "\xEF\xBB\xBFitem foundry:item.c {}\n" },
    };
    for (cases) |case| {
        var doc = try parseSpans(testing.allocator, case[0], null);
        defer doc.deinit(testing.allocator);
        const out = try applied(testing.allocator, case[0], try appendRecord(testing.allocator, try Text.of(&doc, 0, case[0]), "item foundry:item.c {}"));
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(case[1], out);
    }
}

test "a byte-order mark stays when the first record goes" {
    try expectEdit("\xEF\xBB\xBFitem foundry:item.a {\n}\nitem foundry:item.b {\n}\n", "\xEF\xBB\xBFitem foundry:item.b {\n}\n", struct {
        fn f(gpa: Allocator, doc: *const parser.Document, text: Text) !Edit {
            return removeRecord(gpa, text, doc.records[0].source.?.*);
        }
    }.f);
}

test "a duplicate is the record's own text under a new id" {
    var doc = try parseSpans(testing.allocator, records_src, null);
    defer doc.deinit(testing.allocator);
    const text = try Text.of(&doc, 0, records_src);
    const spellings: Options = .{ .spellings = &doc.strings };
    const copy = try duplicateRecord(testing.allocator, spellings, text, doc.records[0].source.?.*, "foundry:item.a2");
    defer testing.allocator.free(copy);
    try testing.expectEqualStrings("item foundry:item.a2 {\n    name \"A\"  # note\n}", copy);

    try testing.expectError(error.InvalidId, duplicateRecord(testing.allocator, spellings, text, doc.records[0].source.?.*, "a2"));
    var colliding: emit.Spellings = .empty;
    defer colliding.deinit(testing.allocator);
    try colliding.put(testing.allocator, core.ContentId.fromString("foundry:item.a2").hash, "foundry:item.other");
    try testing.expectError(error.IdCollision, duplicateRecord(testing.allocator, .{ .spellings = &colliding }, text, doc.records[0].source.?.*, "foundry:item.a2"));
}

test "an edit to an imported record changes that file, once, and no other" {
    const root = "@import \"shared.fdt\"\n@import \"other.fdt\"\nitem foundry:item.r {\n}\n";
    const other = "@import \"shared.fdt\"\nitem foundry:item.o {\n}\n";
    var files: Files = .{};
    defer files.map.deinit(testing.allocator);
    try files.map.put(testing.allocator, "shared.fdt", shared);
    try files.map.put(testing.allocator, "other.fdt", other);
    var doc = try parseSpans(testing.allocator, root, &files);
    defer doc.deinit(testing.allocator);

    // The diamond: `shared.fdt` is reached twice and parsed once.
    try testing.expectEqual(@as(usize, 3), doc.files.len);
    try testing.expectEqualStrings("other.fdt", doc.files[2].name);
    try testing.expectEqual(@as(?u32, 0), doc.files[2].importer);
    try testing.expectEqual(@as(usize, 3), doc.imports.len);
    try testing.expectEqual(@as(?u32, 1), doc.imports[0].file);
    try testing.expectEqual(@as(?u32, 2), doc.imports[1].file);
    try testing.expectEqual(@as(?u32, null), doc.imports[2].file);
    try testing.expectEqual(@as(u32, 2), doc.imports[2].span.file);

    const ash = doc.records[0].source.?;
    try testing.expectEqual(@as(u32, 1), ash.span.file);
    const text = try Text.of(&doc, 1, shared);
    const out = try applied(testing.allocator, shared, try replaceValue(testing.allocator, opts, text, ash.fields[0].value, .string, .{ .string = "Cinders" }));
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("item foundry:item.ash {\n    name \"Cinders\"\n}\n", out);

    // The same span offered against the root's bytes is refused, not cut into them.
    try testing.expectError(error.InvalidSpan, replaceValue(testing.allocator, opts, try Text.of(&doc, 0, root), ash.fields[0].value, .string, .{ .string = "x" }));
    try testing.expectError(error.InvalidSpan, Text.of(&doc, 3, root));
}

test "stale bytes, foreign spans, bad indices and overlapping edits are refused" {
    const src = "item foundry:item.a {\n    tags [\"a\" \"b\"]\n}\n";
    var doc = try parseSpans(testing.allocator, src, null);
    defer doc.deinit(testing.allocator);
    const text = try Text.of(&doc, 0, src);
    const r = doc.records[0].source.?.*;
    const tags = r.fields[0].value;

    // Bytes that changed after the parse, at the same length or not.
    var changed: [src.len]u8 = src.*;
    changed[30] = 'X';
    try testing.expectError(error.StaleSource, removeItem(testing.allocator, try Text.of(&doc, 0, &changed), tags, 0));
    try testing.expectError(error.StaleSource, removeItem(testing.allocator, try Text.of(&doc, 0, src[0 .. src.len - 1]), tags, 0));

    // Spans outside the bytes, in another file, or around something that is not a list.
    var outside = tags;
    outside.span.end = src.len + 5;
    try testing.expectError(error.InvalidSpan, removeItem(testing.allocator, text, outside, 0));
    var foreign = tags;
    foreign.span.file = 1;
    try testing.expectError(error.InvalidSpan, removeItem(testing.allocator, text, foreign, 0));
    try testing.expectError(error.InvalidSpan, removeItem(testing.allocator, text, tags.items[0], 0));
    try testing.expectError(error.InvalidSpan, insertField(testing.allocator, opts, text, tags.span, &.{}, "x", .bool, .{ .bool = true }));
    var inverted = tags;
    inverted.span.start = inverted.span.end + 1;
    try testing.expectError(error.InvalidSpan, replaceValue(testing.allocator, opts, text, inverted, .bool, .{ .bool = true }));
    // Brackets around more than blanks, offered as an empty list, are not one.
    try testing.expectError(error.InvalidSpan, insertItem(testing.allocator, opts, text, .{ .span = tags.span }, 0, .string, .{ .string = "x" }));

    try testing.expectError(error.IndexOutOfRange, removeItem(testing.allocator, text, tags, 2));
    try testing.expectError(error.IndexOutOfRange, insertItem(testing.allocator, opts, text, tags, 3, .string, .{ .string = "x" }));
    try testing.expectError(error.IndexOutOfRange, moveItem(testing.allocator, text, tags, 0, 2));
    try testing.expectError(error.IndexOutOfRange, removeField(testing.allocator, text, r.body.?, r.fields, 1));

    // `apply` takes edits in order, not overlapping, inside the bytes.
    try testing.expectError(error.InvalidEdit, apply(testing.allocator, src, &.{ .{ .start = 5, .end = 10, .text = "" }, .{ .start = 8, .end = 12, .text = "" } }, .default));
    try testing.expectError(error.InvalidEdit, apply(testing.allocator, src, &.{ .{ .start = 8, .end = 12, .text = "" }, .{ .start = 0, .end = 2, .text = "" } }, .default));
    try testing.expectError(error.InvalidEdit, apply(testing.allocator, src, &.{.{ .start = 3, .end = src.len + 1, .text = "" }}, .default));
    try testing.expectError(error.InvalidEdit, apply(testing.allocator, src, &.{.{ .start = 4, .end = 3, .text = "" }}, .default));
    // And never makes a file larger than the parser would read.
    try testing.expectError(error.SourceTooLarge, apply(testing.allocator, src, &.{.{ .start = 0, .end = 0, .text = "##" }}, .{ .max_source_bytes = src.len + 1 }));
    // A value the emitter refuses is refused here too, with the emitter's reason.
    try testing.expectError(error.NotFinite, replaceValue(testing.allocator, opts, text, tags.items[0], .f64, .{ .float = std.math.inf(f64) }));
}

test "with no edits, or a value written back as it was, a file is byte for byte the same" {
    // Written the way the emitter writes, so re-emitting every value reproduces it exactly —
    // with its comments, byte-order mark and CRLF endings untouched between the values.
    const canonical = "\xEF\xBB\xBF# kept\r\n@schema foundry:item {\r\n    name string\r\n    weight f32\r\n    tags [string]\r\n    light { radius f32  falloff f32 }\r\n    drops id\r\n    rows [[string]]\r\n    big u64\r\n}\r\n\r\n" ++
        "item foundry:item.torch {  # kept\r\n    name \"T\\\"orch\\n\"  # kept\r\n    weight 0.1\r\n    tags [\"light\" \"fuel\"]\r\n    light { radius 6.0  falloff -0.0 }\r\n    drops foundry:item.torch\r\n    rows [\r\n        [\"a\" \"b\"]\r\n        []\r\n    ]\r\n    big 18446744073709551615\r\n}\r\n";
    var doc = try parseSpans(testing.allocator, canonical, null);
    defer doc.deinit(testing.allocator);
    const text = try Text.of(&doc, 0, canonical);

    const none = try apply(testing.allocator, canonical, &.{}, .default);
    defer testing.allocator.free(none);
    try testing.expectEqualSlices(u8, canonical, none);

    const decl = doc.records[0];
    var edits: std.ArrayList(Edit) = .empty;
    defer {
        for (edits.items) |e| e.deinit(testing.allocator);
        edits.deinit(testing.allocator);
    }
    for (decl.fields, decl.source.?.fields) |field, where| {
        try edits.append(testing.allocator, try replaceValue(testing.allocator, .{ .spellings = &doc.strings }, text, where.value, fieldType(&doc, field.name), field.value));
    }
    const same = try apply(testing.allocator, canonical, edits.items, .default);
    defer testing.allocator.free(same);
    try testing.expectEqualSlices(u8, canonical, same);
}

fn editEverything(gpa: Allocator) !void {
    var files: Files = .{};
    defer files.map.deinit(gpa);
    try files.map.put(gpa, "shared.fdt", shared);
    var doc = try parseSpans(gpa, rich, &files);
    defer doc.deinit(gpa);
    const text = try Text.of(&doc, 0, rich);
    const torch = doc.records[1].source.?.*;
    const o: Options = .{ .spellings = &doc.strings };

    const tag: FieldType = .string;
    const row: FieldType = .{ .list = &tag };
    var edits: std.ArrayList(Edit) = .empty;
    defer {
        for (edits.items) |edit| edit.deinit(gpa);
        edits.deinit(gpa);
    }
    try edits.ensureTotalCapacity(gpa, 9);
    edits.appendAssumeCapacity(try replaceValue(gpa, o, text, torch.fields[1].value, .f32, .{ .float = 0.25 }));
    edits.appendAssumeCapacity(try insertField(gpa, o, text, torch.fields[3].value.span, torch.fields[3].value.fields, "falloff", .f32, .{ .float = 1.0 }));
    edits.appendAssumeCapacity(try removeField(gpa, text, torch.body.?, torch.fields, 0));
    edits.appendAssumeCapacity(try insertItem(gpa, o, text, torch.fields[5].value, 1, row, .{ .list = &.{.{ .string = "z" }} }));
    edits.appendAssumeCapacity(try removeItem(gpa, text, torch.fields[2].value, 0));
    edits.appendAssumeCapacity(try moveItem(gpa, text, torch.fields[5].value, 0, 1));
    edits.appendAssumeCapacity(try appendRecord(gpa, text, "item foundry:item.c {\n}"));
    edits.appendAssumeCapacity(try insertRecordAfter(gpa, text, torch, "item foundry:item.d {\n}"));
    edits.appendAssumeCapacity(try removeRecord(gpa, text, doc.records[3].source.?.*));
    for (edits.items) |edit| {
        const out = try apply(gpa, rich, &.{edit}, .default);
        gpa.free(out);
    }
    const copy = try duplicateRecord(gpa, o, text, torch, "foundry:item.torch2");
    gpa.free(copy);
}

test "running out of memory anywhere in parsing with spans or editing is an error, never a leak" {
    try testing.checkAllAllocationFailures(testing.allocator, editEverything, .{});
}
