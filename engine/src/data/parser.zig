//! The `.fdt` parser (ADR-0020, `docs/design/content-schemas.md` §4).
//!
//! Produces a `Document`: the schema declarations and the records of **one package**, with
//! `@import` spliced in at the point of use. It does not register schemas, does not check
//! records against them, and does not merge packages — each of those is a later step with
//! its own diagnostics, and keeping them apart is what lets a file with a syntax error
//! still report every *other* syntax error in it.
//!
//! **`data` cannot open a file**, so `@import` resolves through a caller-supplied
//! `Resolver`. Which also means every test in here is hermetic: a resolver backed by a
//! hash map is a dozen lines, and nothing in this module has ever touched a disk.
//!
//! Everything here is untrusted input (CLAUDE.md §5). Errors are collected, never
//! asserted, and every recursion is depth-bounded.

const std = @import("std");
const core = @import("core");

const diagnostic = @import("diagnostic.zig");
const id_mod = @import("id.zig");
const lexer_mod = @import("lexer.zig");
const limits_mod = @import("limits.zig");
const schema_mod = @import("schema.zig");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Diagnostics = diagnostic.Diagnostics;
const Field = schema_mod.Field;
const FieldType = schema_mod.FieldType;
const Lexer = lexer_mod.Lexer;
const Limits = limits_mod.Limits;
const NamedValue = value_mod.NamedValue;
const SchemaId = id_mod.SchemaId;
const Source = diagnostic.Source;
const Token = lexer_mod.Token;
const Value = value_mod.Value;

/// Where a declaration came from. Kept per declaration rather than per file, because a
/// document is many files once imports are spliced, and "which file said this?" is the
/// first question anyone asks about a merged result.
pub const Origin = struct {
    file: []const u8,
    line: u32,
    column: u32,
    /// How many bytes the thing named covers, so a later pass can draw a caret of the
    /// right width.
    length: u32 = 1,
    /// The text of `line`, without its newline.
    ///
    /// Carried rather than looked up, because by the time a record is checked against a
    /// schema the bytes it was parsed from may be gone — a document is many files once
    /// imports are spliced, and the resolver owns every one of them. Holding the line is
    /// what lets a type error render with the same caret a syntax error gets.
    line_text: []const u8 = "",

    pub fn location(self: Origin) diagnostic.Location {
        return .{ .file = self.file, .line = self.line, .column = self.column };
    }
};

/// One field as written inside a record body.
///
/// Two locations, because two different mistakes belong in two different places: an
/// unknown or repeated field name is about the *name*, and a value of the wrong type is
/// about the *value*. A record spans lines, so pointing at the record for either leaves
/// the reader to work out which of its fields was meant.
pub const FieldDecl = struct {
    name: []const u8,
    value: Value,
    name_origin: Origin,
    value_origin: Origin,
};

pub const SchemaDecl = struct {
    id: SchemaId,
    /// The source spelling, kept for diagnostics and for hash-collision reporting.
    text: []const u8,
    /// Inferred as the highest `since` over all fields, so there is one source of truth
    /// for a schema's version rather than a declared number that can disagree with it.
    version: u32,
    fields: []const Field,
    origin: Origin,
};

pub const RecordDecl = struct {
    pub const Kind = enum { define, patch, remove };

    kind: Kind,
    /// `.none` for `@patch` and `@remove`, which take their schema from what they target.
    schema: SchemaId,
    schema_text: []const u8,
    /// Where the schema was named — the directive itself for `@patch` and `@remove`. An
    /// unknown schema is a complaint about that word and nothing else.
    schema_origin: Origin,
    id: ContentId,
    text: []const u8,
    fields: []const FieldDecl,
    origin: Origin,
};

/// The parsed contents of one package.
pub const Document = struct {
    arena: core.Arena,
    namespace: []const u8,
    schemas: []const SchemaDecl = &.{},
    records: []const RecordDecl = &.{},
    /// Every identifier string seen, by hash — the table ADR-0005 asks for so that a hash
    /// collision is a build error naming both strings rather than a runtime mystery. It is
    /// also what turns a numeric id back into a readable name in a diagnostic.
    strings: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,

    pub fn deinit(self: *Document, gpa: Allocator) void {
        self.strings.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// The source spelling of a hashed identifier, if this document mentioned it.
    pub fn stringOf(self: *const Document, hash: u64) ?[]const u8 {
        return self.strings.get(hash);
    }
};

/// How an `@import` is answered. `data` has no filesystem, so the caller supplies one.
pub const Resolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, importer: []const u8, requested: []const u8) Resolution,

    pub fn resolve(self: Resolver, importer: []const u8, requested: []const u8) Resolution {
        return self.resolveFn(self.ctx, importer, requested);
    }
};

pub const Resolution = union(enum) {
    /// `name` is canonical: the parser uses it for cycle detection and for diagnostics,
    /// so two spellings of one file must produce the same name or the file is parsed
    /// twice. `bytes` stays owned by the resolver.
    found: struct { name: []const u8, bytes: []const u8 },
    not_found,
    /// The path resolved outside the package root. A separate answer from `not_found`
    /// because it is a different mistake with a different fix.
    outside_package,
};

pub const Options = struct {
    /// The package's namespace, used to expand a bare schema name.
    ///
    /// Required rather than defaulted: a wrong namespace produces content that parses
    /// cleanly and refers to schemas nobody defined, which is the worst kind of wrong.
    namespace: []const u8,
    limits: Limits = .default,
    /// Absent means `@import` is unavailable, and using it is a diagnostic rather than a
    /// crash. Tests that do not import need supply nothing.
    resolver: ?Resolver = null,
};

pub const Error = error{
    /// At least one diagnostic of severity `error` was recorded. The diagnostics are the
    /// result; this is only the signal.
    ContentInvalid,
} || Allocator.Error;

/// Parses one file, splicing in whatever it imports.
pub fn parse(
    gpa: Allocator,
    source_name: []const u8,
    source_bytes: []const u8,
    options: Options,
    diags: *Diagnostics,
) Error!Document {
    var doc: Document = .{ .arena = .init(gpa), .namespace = "" };
    errdefer doc.deinit(gpa);
    doc.namespace = try doc.arena.allocator().dupe(u8, options.namespace);

    var parser: Parser = .{
        .gpa = gpa,
        .doc = &doc,
        .diags = diags,
        .limits = options.limits,
        .resolver = options.resolver,
    };
    defer parser.deinit();

    try parser.parseFile(source_name, source_bytes, 0);

    doc.schemas = try doc.arena.allocator().dupe(SchemaDecl, parser.schemas.items);
    doc.records = try doc.arena.allocator().dupe(RecordDecl, parser.records.items);

    if (diags.failed) return error.ContentInvalid;
    return doc;
}

/// Every reserved word in the format, in one place.
///
/// Value keywords and schema attributes are the only bare words the grammar gives meaning
/// to. Directives are `@`-prefixed precisely so this list can never grow into the space
/// mods use for schema names (ADR-0020); attributes are inside parentheses for the same
/// reason, at the level below.
const keywords = struct {
    const true_ = "true";
    const false_ = "false";
    const optional = "optional";
    const default = "default";
    const since = "since";
};

const Fail = error{Recorded};
const ParseError = Fail || Allocator.Error;

const Parser = struct {
    gpa: Allocator,
    doc: *Document,
    diags: *Diagnostics,
    limits: Limits,
    resolver: ?Resolver,

    schemas: std.ArrayList(SchemaDecl) = .empty,
    records: std.ArrayList(RecordDecl) = .empty,
    /// Canonical names currently being parsed, innermost last. Cycle detection reports
    /// this as a chain, because "cyclic import" alone is useless in a tree of forty files.
    stack: std.ArrayList([]const u8) = .empty,
    /// Canonical names already spliced in. Importing one twice is a no-op, not an error:
    /// diamond imports are the normal case, not a mistake.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    // Per-file cursor state.
    source: Source = .{ .name = "", .bytes = "" },
    lexer: Lexer = .init(""),
    token: Token = .{ .tag = .eof, .start = 0, .end = 0 },
    /// Unclosed brackets before the current token. Recovery uses it to find its way back
    /// to the top level without guessing.
    depth: u32 = 0,
    /// The last source line copied into the arena, and the slice it was copied from. See
    /// `lineText`.
    last_line: ?struct { source: []const u8, copy: []const u8 } = null,

    fn deinit(self: *Parser) void {
        self.schemas.deinit(self.gpa);
        self.records.deinit(self.gpa);
        self.stack.deinit(self.gpa);
        self.seen.deinit(self.gpa);
    }

    fn arena(self: *Parser) Allocator {
        return self.doc.arena.allocator();
    }

    // --- files ----------------------------------------------------------------

    fn parseFile(self: *Parser, name: []const u8, bytes: []const u8, depth: u32) Allocator.Error!void {
        if (bytes.len > self.limits.max_source_bytes) {
            try self.diags.addFmt(self.gpa, .err, .{ .file = name, .line = 1, .column = 1 }, 1, "", "'{s}' is {d} bytes, over the {d}-byte limit for a content file", .{ name, bytes.len, self.limits.max_source_bytes });
            return;
        }

        const owned_name = try self.arena().dupe(u8, name);
        try self.seen.put(self.gpa, owned_name, {});
        try self.stack.append(self.gpa, owned_name);
        defer _ = self.stack.pop();

        // Save the enclosing file's cursor: an import is spliced in the middle of one.
        const saved_source = self.source;
        const saved_lexer = self.lexer;
        const saved_token = self.token;
        const saved_depth = self.depth;
        defer {
            self.source = saved_source;
            self.lexer = saved_lexer;
            self.token = saved_token;
            self.depth = saved_depth;
            self.last_line = null;
        }

        self.source = .{ .name = owned_name, .bytes = bytes };
        self.lexer = .init(bytes);
        self.depth = 0;
        self.last_line = null;
        self.advance();

        while (self.token.tag != .eof) {
            const before = self.token.start;
            self.item(depth) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Recorded => self.recover(),
            };
            // Every iteration must consume something, or a malformed file becomes a hang.
            if (self.token.start == before and self.token.tag != .eof) self.advance();
        }
    }

    fn item(self: *Parser, depth: u32) ParseError!void {
        switch (self.token.tag) {
            .directive => try self.directive(depth),
            .identifier, .content_id => try self.record(),
            .invalid_directive => {
                try self.errAt(self.token, "expected a directive name after '@'", .{});
                return error.Recorded;
            },
            else => {
                try self.unexpected("a record or a directive");
                return error.Recorded;
            },
        }
    }

    // --- directives -----------------------------------------------------------

    fn directive(self: *Parser, depth: u32) ParseError!void {
        const token = self.token;
        const name = token.text(self.source.bytes)[1..];

        if (std.mem.eql(u8, name, "import")) return self.importDirective(token, depth);
        if (std.mem.eql(u8, name, "schema")) return self.schemaDirective();
        if (std.mem.eql(u8, name, "patch")) return self.recordDirective(.patch);
        if (std.mem.eql(u8, name, "remove")) return self.recordDirective(.remove);

        try self.errAt(token, "unknown directive '@{s}'; expected @import, @schema, @patch or @remove", .{name});
        return error.Recorded;
    }

    fn importDirective(self: *Parser, token: Token, depth: u32) ParseError!void {
        self.advance();
        const path_token = self.token;
        if (path_token.tag != .string) {
            try self.unexpected("a quoted path");
            return error.Recorded;
        }
        const path = try self.stringValue(path_token);
        self.advance();

        if (depth + 1 >= self.limits.max_import_depth) {
            try self.errAt(token, "imports nested more than {d} deep", .{self.limits.max_import_depth});
            return error.Recorded;
        }

        const resolver = self.resolver orelse {
            try self.errAt(token, "@import is not available here: no import resolver was supplied", .{});
            return error.Recorded;
        };

        switch (resolver.resolve(self.source.name, path)) {
            .not_found => {
                try self.errAt(path_token, "cannot find imported file '{s}'", .{path});
                return error.Recorded;
            },
            .outside_package => {
                try self.errAt(path_token, "'{s}' resolves outside the package; a package may only import its own files", .{path});
                return error.Recorded;
            },
            .found => |file| {
                for (self.stack.items, 0..) |entry, i| {
                    if (!std.mem.eql(u8, entry, file.name)) continue;
                    try self.reportCycle(path_token, i, file.name);
                    return error.Recorded;
                }
                // Importing the same file twice is a no-op. Diamond imports are normal.
                if (self.seen.contains(file.name)) return;
                try self.parseFile(file.name, file.bytes, depth + 1);
            },
        }
    }

    fn reportCycle(self: *Parser, token: Token, start: usize, name: []const u8) Allocator.Error!void {
        var chain: std.ArrayList(u8) = .empty;
        defer chain.deinit(self.gpa);
        for (self.stack.items[start..]) |entry| {
            try chain.appendSlice(self.gpa, entry);
            try chain.appendSlice(self.gpa, " -> ");
        }
        try chain.appendSlice(self.gpa, name);
        try self.errAt(token, "import cycle: {s}", .{chain.items});
    }

    // --- schemas --------------------------------------------------------------

    fn schemaDirective(self: *Parser) ParseError!void {
        self.advance();
        const ref = self.token;
        const schema_id, const text = try self.schemaRef();
        self.advance();

        try self.expect(.lbrace);
        var fields: std.ArrayList(Field) = .empty;
        defer fields.deinit(self.gpa);
        var version: u32 = 1;
        try self.fieldDecls(&fields, &version, 0);
        try self.expect(.rbrace);

        try self.schemas.append(self.gpa, .{
            .id = schema_id,
            .text = text,
            .version = version,
            .fields = try self.arena().dupe(Field, fields.items),
            .origin = try self.originOf(ref),
        });
    }

    fn fieldDecls(
        self: *Parser,
        out: *std.ArrayList(Field),
        version: *u32,
        depth: u32,
    ) ParseError!void {
        if (depth >= self.limits.max_nesting_depth) {
            try self.errAt(self.token, "schema nested more than {d} deep", .{self.limits.max_nesting_depth});
            return error.Recorded;
        }
        while (self.token.tag == .identifier or self.token.tag == .content_id) {
            if (out.items.len >= self.limits.max_fields_per_schema) {
                try self.errAt(self.token, "more than {d} fields in one schema", .{self.limits.max_fields_per_schema});
                return error.Recorded;
            }
            const name_token = self.token;
            const name = try self.fieldName(name_token);
            self.advance();

            const field_type = try self.typeExpr(depth);
            var field: Field = .{ .name = name, .type = field_type };
            // A `while` rather than an `if`: `(since 5) (optional)` is how somebody who
            // thinks of them as separate modifiers will write it, and refusing that buys
            // nothing. Within a group or across them, the last one written wins.
            while (self.token.tag == .lparen) try self.attributes(&field, depth);
            version.* = @max(version.*, field.since);
            try out.append(self.gpa, field);
        }
    }

    fn typeExpr(self: *Parser, depth: u32) ParseError!FieldType {
        if (depth >= self.limits.max_nesting_depth) {
            try self.errAt(self.token, "type nested more than {d} deep", .{self.limits.max_nesting_depth});
            return error.Recorded;
        }
        switch (self.token.tag) {
            .identifier => {
                const text = self.token.text(self.source.bytes);
                const t = FieldType.keyword(text) orelse {
                    try self.errAt(self.token, "'{s}' is not a type; expected one of bool, i32, i64, u32, u64, f32, f64, string, id, '[' or '{{'", .{text});
                    return error.Recorded;
                };
                self.advance();
                return t;
            },
            .lbracket => {
                self.advance();
                const elem = try self.arena().create(FieldType);
                elem.* = try self.typeExpr(depth + 1);
                try self.expect(.rbracket);
                return .{ .list = elem };
            },
            .lbrace => {
                self.advance();
                var nested: std.ArrayList(Field) = .empty;
                defer nested.deinit(self.gpa);
                var version: u32 = 1;
                try self.fieldDecls(&nested, &version, depth + 1);
                try self.expect(.rbrace);
                return .{ .nested = try self.arena().dupe(Field, nested.items) };
            },
            else => {
                try self.unexpected("a type");
                return error.Recorded;
            },
        }
    }

    /// `( optional )`, `( default 0.5 )`, `( since 2 default 1 )`.
    ///
    /// Bracketed rather than bare, for the same reason directives carry an `@`: attribute
    /// names would otherwise occupy the same syntactic slot as field names, so adding an
    /// attribute in a later release could break a mod that had used the word as a field.
    /// The parentheses make that impossible instead of merely unlikely.
    fn attributes(self: *Parser, field: *Field, depth: u32) ParseError!void {
        self.advance(); // '('
        while (self.token.tag == .identifier) {
            const token = self.token;
            const name = token.text(self.source.bytes);
            self.advance();

            if (std.mem.eql(u8, name, keywords.optional)) {
                field.presence = .optional;
            } else if (std.mem.eql(u8, name, keywords.default)) {
                field.presence = .{ .default = try self.value(depth + 1) };
            } else if (std.mem.eql(u8, name, keywords.since)) {
                if (self.token.tag != .integer) {
                    try self.unexpected("a version number");
                    return error.Recorded;
                }
                const n = try self.integerValue(self.token);
                if (n < 1 or n > std.math.maxInt(u32)) {
                    try self.errAt(self.token, "schema versions start at 1", .{});
                    return error.Recorded;
                }
                field.since = @intCast(n);
                self.advance();
            } else {
                try self.errAt(token, "'{s}' is not an attribute; expected optional, default or since", .{name});
                return error.Recorded;
            }
        }
        try self.expect(.rparen);
    }

    // --- records --------------------------------------------------------------

    fn record(self: *Parser) ParseError!void {
        const schema_token = self.token;
        const schema_id, const schema_text = try self.schemaRef();
        self.advance();

        const id_token = self.token;
        const content_id, const text = try self.contentRef();
        self.advance();

        const fields = try self.recordBody();
        try self.records.append(self.gpa, .{
            .kind = .define,
            .schema = schema_id,
            .schema_text = schema_text,
            .schema_origin = try self.originOf(schema_token),
            .id = content_id,
            .text = text,
            .fields = fields,
            .origin = try self.originOf(id_token),
        });
    }

    fn recordDirective(self: *Parser, kind: RecordDecl.Kind) ParseError!void {
        const directive_token = self.token;
        self.advance();
        const id_token = self.token;
        const content_id, const text = try self.contentRef();
        self.advance();

        const fields: []const FieldDecl = switch (kind) {
            .remove => &.{},
            else => try self.recordBody(),
        };
        try self.records.append(self.gpa, .{
            .kind = kind,
            .schema = .none,
            .schema_text = "",
            .schema_origin = try self.originOf(directive_token),
            .id = content_id,
            .text = text,
            .fields = fields,
            .origin = try self.originOf(id_token),
        });
    }

    /// A record's own fields, which carry locations. The fields *inside* a value do not
    /// (`fieldValues`): an inline struct is a handful of names on a line or two, and a
    /// complaint about one of them points at the field that contains it.
    fn recordBody(self: *Parser) ParseError![]const FieldDecl {
        try self.expect(.lbrace);
        var fields: std.ArrayList(FieldDecl) = .empty;
        defer fields.deinit(self.gpa);

        while (self.token.tag == .identifier or self.token.tag == .content_id) {
            if (fields.items.len >= self.limits.max_fields_per_record) {
                try self.errAt(self.token, "more than {d} fields in one record", .{self.limits.max_fields_per_record});
                return error.Recorded;
            }
            const name_token = self.token;
            const name = try self.fieldName(name_token);
            self.advance();
            const value_token = self.token;
            const v = try self.value(0);
            try fields.append(self.gpa, .{
                .name = name,
                .value = v,
                .name_origin = try self.originOf(name_token),
                .value_origin = try self.originOf(value_token),
            });
        }

        try self.expect(.rbrace);
        return self.arena().dupe(FieldDecl, fields.items);
    }

    fn fieldValues(self: *Parser, out: *std.ArrayList(NamedValue), depth: u32) ParseError!void {
        while (self.token.tag == .identifier or self.token.tag == .content_id) {
            if (out.items.len >= self.limits.max_fields_per_record) {
                try self.errAt(self.token, "more than {d} fields in one record", .{self.limits.max_fields_per_record});
                return error.Recorded;
            }
            const name = try self.fieldName(self.token);
            self.advance();
            const v = try self.value(depth);
            try out.append(self.gpa, .{ .name = name, .value = v });
        }
    }

    // --- values ---------------------------------------------------------------

    fn value(self: *Parser, depth: u32) ParseError!Value {
        if (depth >= self.limits.max_nesting_depth) {
            try self.errAt(self.token, "value nested more than {d} deep", .{self.limits.max_nesting_depth});
            return error.Recorded;
        }
        const token = self.token;
        switch (token.tag) {
            .identifier => {
                const text = token.text(self.source.bytes);
                if (std.mem.eql(u8, text, keywords.true_)) {
                    self.advance();
                    return .{ .bool = true };
                }
                if (std.mem.eql(u8, text, keywords.false_)) {
                    self.advance();
                    return .{ .bool = false };
                }
                try self.errAt(token, "expected a value, found '{s}'; a content reference needs its namespace, as in 'foundry:{s}'", .{ text, text });
                return error.Recorded;
            },
            .integer => {
                const n = try self.integerValue(token);
                self.advance();
                return .{ .int = n };
            },
            .float => {
                const f = try self.floatValue(token);
                self.advance();
                return .{ .float = f };
            },
            .string => {
                const s = try self.stringValue(token);
                self.advance();
                return .{ .string = s };
            },
            .content_id => {
                const content_id, _ = try self.contentRef();
                self.advance();
                return .{ .id = content_id };
            },
            .lbracket => {
                self.advance();
                var items: std.ArrayList(Value) = .empty;
                defer items.deinit(self.gpa);
                while (self.token.tag != .rbracket and self.token.tag != .eof) {
                    if (items.items.len >= self.limits.max_list_elements) {
                        try self.errAt(self.token, "more than {d} elements in one list", .{self.limits.max_list_elements});
                        return error.Recorded;
                    }
                    try items.append(self.gpa, try self.value(depth + 1));
                }
                try self.expect(.rbracket);
                return .{ .list = try self.arena().dupe(Value, items.items) };
            },
            .lbrace => {
                self.advance();
                var fields: std.ArrayList(NamedValue) = .empty;
                defer fields.deinit(self.gpa);
                try self.fieldValues(&fields, depth + 1);
                try self.expect(.rbrace);
                return .{ .nested = try self.arena().dupe(NamedValue, fields.items) };
            },
            .unterminated_string => {
                try self.errAt(token, "unterminated string; a string may not contain a line break", .{});
                return error.Recorded;
            },
            .malformed_number => {
                try self.errAt(token, "'{s}' is not a number", .{token.text(self.source.bytes)});
                return error.Recorded;
            },
            else => {
                try self.unexpected("a value");
                return error.Recorded;
            },
        }
    }

    fn integerValue(self: *Parser, token: Token) ParseError!i128 {
        const raw = token.text(self.source.bytes);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        for (raw) |c| if (c != '_') try buf.append(self.gpa, c);

        var text = buf.items;
        var negative = false;
        if (text.len > 0 and text[0] == '-') {
            negative = true;
            text = text[1..];
        }
        const base: u8 = if (std.mem.startsWith(u8, text, "0x")) blk: {
            text = text[2..];
            break :blk 16;
        } else 10;

        const magnitude = std.fmt.parseInt(i128, text, base) catch {
            try self.errAt(token, "integer literal '{s}' does not fit in 64 bits", .{raw});
            return error.Recorded;
        };
        return if (negative) -magnitude else magnitude;
    }

    fn floatValue(self: *Parser, token: Token) ParseError!f64 {
        const raw = token.text(self.source.bytes);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        for (raw) |c| if (c != '_') try buf.append(self.gpa, c);

        const f = std.fmt.parseFloat(f64, buf.items) catch {
            try self.errAt(token, "'{s}' is not a number", .{raw});
            return error.Recorded;
        };
        // Neither survives content review, and I9 has enough to worry about. There is no
        // literal spelling for them either, so this only catches an overflowing exponent.
        if (!std.math.isFinite(f)) {
            try self.errAt(token, "'{s}' is out of range for a number", .{raw});
            return error.Recorded;
        }
        return f;
    }

    /// Decodes escapes and validates UTF-8. The escape set is closed: an unknown escape is
    /// an error rather than a passed-through backslash, because silently accepting `\d` is
    /// how a format acquires an accidental specification.
    fn stringValue(self: *Parser, token: Token) ParseError![]const u8 {
        const raw = token.text(self.source.bytes);
        const body = raw[1 .. raw.len - 1];

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);

        var i: usize = 0;
        while (i < body.len) {
            if (body[i] != '\\') {
                try out.append(self.gpa, body[i]);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= body.len) {
                try self.errAt(token, "string ends with an incomplete escape", .{});
                return error.Recorded;
            }
            switch (body[i]) {
                '"' => try out.append(self.gpa, '"'),
                '\\' => try out.append(self.gpa, '\\'),
                'n' => try out.append(self.gpa, '\n'),
                'r' => try out.append(self.gpa, '\r'),
                't' => try out.append(self.gpa, '\t'),
                'u' => {
                    const codepoint, const consumed = self.unicodeEscape(body[i..]) catch {
                        try self.errAt(token, "expected \\u{{...}} with 1 to 6 hex digits", .{});
                        return error.Recorded;
                    };
                    var encoded: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(codepoint, &encoded) catch {
                        try self.errAt(token, "\\u{{{x}}} is not a character", .{codepoint});
                        return error.Recorded;
                    };
                    try out.appendSlice(self.gpa, encoded[0..n]);
                    i += consumed - 1;
                },
                else => {
                    try self.errAt(token, "unknown escape '\\{c}'; the escapes are \\\" \\\\ \\n \\r \\t and \\u{{...}}", .{body[i]});
                    return error.Recorded;
                },
            }
            i += 1;
        }

        if (!std.unicode.utf8ValidateSlice(out.items)) {
            try self.errAt(token, "string is not valid UTF-8", .{});
            return error.Recorded;
        }
        return self.arena().dupe(u8, out.items);
    }

    fn unicodeEscape(self: *Parser, text: []const u8) !struct { u21, usize } {
        _ = self;
        if (text.len < 4 or text[1] != '{') return error.BadEscape;
        const close = std.mem.indexOfScalar(u8, text, '}') orelse return error.BadEscape;
        const digits = text[2..close];
        if (digits.len == 0 or digits.len > 6) return error.BadEscape;
        const codepoint = std.fmt.parseInt(u21, digits, 16) catch return error.BadEscape;
        return .{ codepoint, close + 1 };
    }

    // --- identifiers ----------------------------------------------------------

    /// A schema reference: a full `namespace:name`, or a bare name meaning one in this
    /// package's own namespace.
    ///
    /// The asymmetry with content references is deliberate. A schema name repeats on every
    /// record of that type, so eliding it pays; a content id is unique, so eliding it would
    /// save nothing and cost the property ADR-0020 bought the bare-token syntax for —
    /// `grep foundry:item.ash` finding every use across every package on disk.
    fn schemaRef(self: *Parser) ParseError!struct { SchemaId, []const u8 } {
        const token = self.token;
        const text = token.text(self.source.bytes);
        const full = if (token.tag == .content_id)
            text
        else if (token.tag == .identifier)
            try std.fmt.allocPrint(self.arena(), "{s}:{s}", .{ self.doc.namespace, text })
        else {
            try self.unexpected("a schema name");
            return error.Recorded;
        };

        id_mod.validate(full) catch |err| {
            try self.errAt(token, "'{s}' is not a valid schema name: {s}", .{ full, describe(err) });
            return error.Recorded;
        };
        const schema_id: SchemaId = .fromStringUnchecked(full);
        if (schema_id.isNone()) {
            try self.errAt(token, "'{s}' hashes to the reserved zero id", .{full});
            return error.Recorded;
        }
        const owned = try self.intern(token, schema_id.hash, full);
        return .{ schema_id, owned };
    }

    fn contentRef(self: *Parser) ParseError!struct { ContentId, []const u8 } {
        const token = self.token;
        if (token.tag != .content_id and token.tag != .identifier) {
            try self.unexpected("a content id");
            return error.Recorded;
        }
        const text = token.text(self.source.bytes);
        const content_id = id_mod.contentId(text) catch |err| {
            try self.errAt(token, "'{s}' is not a valid content id: {s}", .{ text, describe(err) });
            return error.Recorded;
        };
        const owned = try self.intern(token, content_id.hash, text);
        return .{ content_id, owned };
    }

    /// Records the source spelling of a hash, and reports a collision naming both strings.
    ///
    /// ADR-0005 asked for exactly this: 64 bits of FNV-1a makes a collision vanishingly
    /// unlikely, and making it loud costs one hash map.
    fn intern(self: *Parser, token: Token, hash: u64, text: []const u8) ParseError![]const u8 {
        const gop = try self.doc.strings.getOrPut(self.gpa, hash);
        if (gop.found_existing) {
            if (!std.mem.eql(u8, gop.value_ptr.*, text)) {
                try self.errAt(token, "'{s}' and '{s}' hash to the same id; one of them has to be renamed", .{ text, gop.value_ptr.* });
                return error.Recorded;
            }
            return gop.value_ptr.*;
        }
        const owned = try self.arena().dupe(u8, text);
        gop.value_ptr.* = owned;
        return owned;
    }

    fn fieldName(self: *Parser, token: Token) ParseError![]const u8 {
        const text = token.text(self.source.bytes);
        if (!id_mod.isValidSegment(text)) {
            try self.errAt(token, "'{s}' is not a field name: names are lowercase letters, digits and underscores, starting with a letter", .{text});
            return error.Recorded;
        }
        return self.arena().dupe(u8, text);
    }

    // --- cursor ---------------------------------------------------------------

    fn advance(self: *Parser) void {
        switch (self.token.tag) {
            .lbrace, .lbracket, .lparen => self.depth +|= 1,
            .rbrace, .rbracket, .rparen => self.depth -|= 1,
            else => {},
        }
        self.token = self.lexer.next();
    }

    fn expect(self: *Parser, tag: Token.Tag) ParseError!void {
        if (self.token.tag != tag) {
            try self.unexpected(tag.describe());
            return error.Recorded;
        }
        self.advance();
    }

    /// Skips to something that can begin a top-level item, so that the rest of the file is
    /// still checked. A parser that reports one error per run makes fixing twenty a
    /// twenty-build afternoon.
    fn recover(self: *Parser) void {
        while (self.token.tag != .eof) {
            self.advance();
            if (self.depth != 0) continue;
            switch (self.token.tag) {
                .directive, .identifier, .content_id, .eof => return,
                else => {},
            }
        }
    }

    // --- diagnostics ----------------------------------------------------------

    fn originOf(self: *Parser, token: Token) Allocator.Error!Origin {
        const loc = self.source.location(token.start);
        return .{
            .file = loc.file,
            .line = loc.line,
            .column = loc.column,
            .length = @max(1, token.len()),
            .line_text = try self.lineText(token.start),
        };
    }

    /// The line containing `offset`, copied into the document's arena.
    ///
    /// One line is remembered, which is enough: a field's name and its value are almost
    /// always written together, so the common case is two origins on one line. The
    /// remembered slice is compared against the source rather than trusted, and cleared
    /// when a file's parse begins or ends, so a buffer the resolver reused at the same
    /// address can never be mistaken for the line it used to hold.
    fn lineText(self: *Parser, offset: usize) Allocator.Error![]const u8 {
        const line = self.source.lineText(offset);
        if (self.last_line) |cached| {
            if (cached.source.ptr == line.ptr and cached.source.len == line.len) return cached.copy;
        }
        const copy = try self.arena().dupe(u8, line);
        self.last_line = .{ .source = line, .copy = copy };
        return copy;
    }

    fn errAt(self: *Parser, token: Token, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.diags.addFmt(
            self.gpa,
            .err,
            self.source.location(token.start),
            @max(1, token.len()),
            self.source.lineText(token.start),
            fmt,
            args,
        );
    }

    fn unexpected(self: *Parser, expected: []const u8) Allocator.Error!void {
        const token = self.token;
        // The two a person types out of habit get their own answer, because "an unexpected
        // character" would send them looking for a typo they did not make.
        if (token.tag == .invalid) {
            const c = self.source.bytes[token.start];
            if (c == ',') {
                return self.errAt(token, "'.fdt' does not use commas; whitespace separates values", .{});
            }
            if (c == '=') {
                return self.errAt(token, "'.fdt' does not use '='; a field is its name followed by its value", .{});
            }
        }
        try self.errAt(token, "expected {s}, found {s}", .{ expected, token.tag.describe() });
    }
};

fn describe(err: id_mod.Error) []const u8 {
    return switch (err) {
        error.EmptyId => "it is empty",
        error.IdTooLong => "it is too long",
        error.MissingNamespace => "it has no 'namespace:' prefix",
        error.MultipleColons => "it has more than one colon",
        error.EmptyNamespace => "there is nothing before the colon",
        error.EmptyName => "there is nothing after the colon",
        error.EmptySegment => "it has an empty part between dots",
        error.SegmentMustStartWithLetter => "each part must start with a letter",
        error.UppercaseNotAllowed => "identifiers are lowercase",
        error.InvalidCharacter => "it contains a character that is not a letter, digit or underscore",
        error.ReservedHash => "it hashes to the reserved zero id",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A resolver over a hash map. This is the whole reason `data` taking bytes rather than
/// paths is worth having: an import test needs no filesystem, no temp directory and no
/// cleanup, and it cannot be flaky.
const MapResolver = struct {
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    outside: []const u8 = "\x00none",

    fn resolver(self: *MapResolver) Resolver {
        return .{ .ctx = self, .resolveFn = resolve };
    }

    fn resolve(ctx: *anyopaque, importer: []const u8, requested: []const u8) Resolution {
        _ = importer;
        const self: *MapResolver = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, requested, self.outside)) return .outside_package;
        const bytes = self.files.get(requested) orelse return .not_found;
        return .{ .found = .{ .name = requested, .bytes = bytes } };
    }
};

fn parseOk(source: []const u8) !Document {
    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    return parse(testing.allocator, "test.fdt", source, .{ .namespace = "foundry" }, &diags) catch |err| {
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        diags.render(&writer) catch {};
        std.debug.print("unexpected parse failure:\n{s}\n", .{writer.buffered()});
        return err;
    };
}

/// Parses, expects failure, and returns the rendered diagnostics for inspection.
fn parseErr(source: []const u8, buf: []u8) ![]const u8 {
    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    const result = parse(testing.allocator, "test.fdt", source, .{ .namespace = "foundry" }, &diags);
    try testing.expectError(error.ContentInvalid, result);

    var writer: std.Io.Writer = .fixed(buf);
    try diags.render(&writer);
    return writer.buffered();
}

test "the worked example from the design document parses" {
    var doc = try parseOk(
        \\# Torches. Referenced by the starting inventory.
        \\item foundry:item.torch {
        \\    name    "Torch"
        \\    weight  0.5
        \\    stack   20
        \\    tags    ["light" "fuel"]
        \\    light   { radius 6.0  falloff 2.0 }
        \\    drops   foundry:item.ash
        \\}
        \\
        \\item foundry:item.ash {
        \\    name   "Ash"
        \\    weight 0.05
        \\}
    );
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), doc.records.len);
    const torch = doc.records[0];
    try testing.expectEqualStrings("foundry:item", torch.schema_text);
    try testing.expectEqualStrings("foundry:item.torch", torch.text);
    try testing.expectEqual(RecordDecl.Kind.define, torch.kind);
    try testing.expectEqual(@as(usize, 6), torch.fields.len);
    try testing.expectEqualStrings("Torch", torch.fields[0].value.string);
    try testing.expectEqual(@as(f64, 0.5), torch.fields[1].value.float);
    try testing.expectEqual(@as(i128, 20), torch.fields[2].value.int);
    try testing.expectEqual(@as(usize, 2), torch.fields[3].value.list.len);
    try testing.expectEqualStrings("falloff", torch.fields[4].value.nested[1].name);
    try testing.expect(torch.fields[5].value.id.eql(ContentId.fromString("foundry:item.ash")));

    // Line and column, so a later step can point at the record itself.
    try testing.expectEqual(@as(u32, 2), torch.origin.line);
    try testing.expectEqual(@as(u32, 6), torch.origin.column);
}

test "a bare schema name means this package's namespace; a content id never elides" {
    var doc = try parseOk("item foundry:item.torch { } othermod:weapon foundry:item.sword { }");
    defer doc.deinit(testing.allocator);

    try testing.expectEqualStrings("foundry:item", doc.records[0].schema_text);
    try testing.expectEqualStrings("othermod:weapon", doc.records[1].schema_text);

    // The elision is one-way. A content id without a namespace is a diagnostic, and it
    // names the fix rather than the rule.
    var buf: [512]u8 = undefined;
    const rendered = try parseErr("item torch { }", &buf);
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "no 'namespace:' prefix"));
}

test "a schema declaration, its types and its attributes" {
    var doc = try parseOk(
        \\@schema foundry:item {
        \\    name    string
        \\    weight  f32       (default 0.0)
        \\    stack   u32       (default 1)
        \\    tags    [string]  (optional)
        \\    drops   id        (optional)
        \\    light   { radius f32  falloff f32 }  (optional)
        \\    grid    [[i32]]
        \\}
    );
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), doc.schemas.len);
    const s = doc.schemas[0];
    try testing.expectEqualStrings("foundry:item", s.text);
    try testing.expectEqual(@as(u32, 1), s.version);
    try testing.expectEqual(@as(usize, 7), s.fields.len);

    try testing.expect(s.fields[0].type == .string);
    try testing.expect(s.fields[0].presence == .required);
    try testing.expect(s.fields[1].type == .f32);
    try testing.expectEqual(@as(f64, 0.0), s.fields[1].presence.default.float);
    try testing.expectEqual(@as(i128, 1), s.fields[2].presence.default.int);
    try testing.expect(s.fields[3].type.list.* == .string);
    try testing.expect(s.fields[3].presence == .optional);
    try testing.expect(s.fields[4].type == .id);
    try testing.expectEqualStrings("radius", s.fields[5].type.nested[0].name);
    try testing.expect(s.fields[6].type.list.*.list.* == .i32);
}

test "a schema's version is the highest `since` on its fields, not a separate number" {
    var doc = try parseOk(
        \\@schema foundry:item {
        \\    weight f32
        \\    stack  u32 (since 2 default 1)
        \\    glow   f32 (since 5) (optional)
        \\}
    );
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 5), doc.schemas[0].version);
    try testing.expectEqual(@as(u32, 2), doc.schemas[0].fields[1].since);
}

test "attributes are bracketed, so a field may be named after one" {
    // This is the property the parentheses buy. Without them, `optional` in the slot after
    // a type would be ambiguous forever, and adding an attribute later could break a mod.
    var doc = try parseOk("@schema foundry:x { optional string  default i32  since f32 }");
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), doc.schemas[0].fields.len);
    try testing.expectEqualStrings("optional", doc.schemas[0].fields[0].name);
    try testing.expectEqualStrings("since", doc.schemas[0].fields[2].name);
}

test "@patch and @remove name a record without naming a schema" {
    var doc = try parseOk(
        \\@patch foundry:item.torch { weight 0.4 }
        \\@remove foundry:item.ash
    );
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), doc.records.len);
    try testing.expectEqual(RecordDecl.Kind.patch, doc.records[0].kind);
    try testing.expect(doc.records[0].schema.isNone());
    try testing.expectEqual(@as(usize, 1), doc.records[0].fields.len);
    try testing.expectEqual(RecordDecl.Kind.remove, doc.records[1].kind);
    try testing.expectEqual(@as(usize, 0), doc.records[1].fields.len);
}

test "an import splices its records into the importing package, at the point of use" {
    var resolver: MapResolver = .{};
    defer resolver.files.deinit(testing.allocator);
    try resolver.files.put(testing.allocator, "shared.fdt", "item foundry:item.ash { name \"Ash\" }");

    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);

    var doc = try parse(testing.allocator, "main.fdt",
        \\item foundry:item.a { }
        \\@import "shared.fdt"
        \\item foundry:item.b { }
    , .{ .namespace = "foundry", .resolver = resolver.resolver() }, &diags);
    defer doc.deinit(testing.allocator);

    // Order is the order they appear, imports inlined where they are written — which is
    // one of the two iteration orders I9 depends on being documented (§6).
    try testing.expectEqual(@as(usize, 3), doc.records.len);
    try testing.expectEqualStrings("foundry:item.a", doc.records[0].text);
    try testing.expectEqualStrings("foundry:item.ash", doc.records[1].text);
    try testing.expectEqualStrings("foundry:item.b", doc.records[2].text);
    // And the origin follows the file, not the package.
    try testing.expectEqualStrings("shared.fdt", doc.records[1].origin.file);
    try testing.expectEqualStrings("main.fdt", doc.records[2].origin.file);
}

test "importing the same file twice is a no-op, because diamonds are normal" {
    var resolver: MapResolver = .{};
    defer resolver.files.deinit(testing.allocator);
    try resolver.files.put(testing.allocator, "base.fdt", "item foundry:item.base { }");
    try resolver.files.put(testing.allocator, "left.fdt", "@import \"base.fdt\"");
    try resolver.files.put(testing.allocator, "right.fdt", "@import \"base.fdt\"");

    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    var doc = try parse(testing.allocator, "main.fdt",
        \\@import "left.fdt"
        \\@import "right.fdt"
    , .{ .namespace = "foundry", .resolver = resolver.resolver() }, &diags);
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), doc.records.len);
}

test "an import cycle is reported as the chain, not as the word 'cycle'" {
    var resolver: MapResolver = .{};
    defer resolver.files.deinit(testing.allocator);
    try resolver.files.put(testing.allocator, "a.fdt", "@import \"b.fdt\"");
    try resolver.files.put(testing.allocator, "b.fdt", "@import \"a.fdt\"");

    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    const result = parse(testing.allocator, "a.fdt", "@import \"b.fdt\"", .{
        .namespace = "foundry",
        .resolver = resolver.resolver(),
    }, &diags);
    try testing.expectError(error.ContentInvalid, result);

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try diags.render(&writer);
    try testing.expect(std.mem.containsAtLeast(u8, writer.buffered(), 1, "a.fdt -> b.fdt -> a.fdt"));
}

test "an import that cannot be answered says which way it failed" {
    var resolver: MapResolver = .{};
    defer resolver.files.deinit(testing.allocator);

    var buf: [1024]u8 = undefined;
    {
        var diags: Diagnostics = .init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        _ = parse(testing.allocator, "a.fdt", "@import \"gone.fdt\"", .{
            .namespace = "foundry",
            .resolver = resolver.resolver(),
        }, &diags) catch {};
        var w: std.Io.Writer = .fixed(&buf);
        try diags.render(&w);
        try testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "cannot find imported file 'gone.fdt'"));
    }
    {
        var diags: Diagnostics = .init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        _ = parse(testing.allocator, "a.fdt", "@import \"\\u{0}none\"", .{
            .namespace = "foundry",
            .resolver = resolver.resolver(),
        }, &diags) catch {};
        var w: std.Io.Writer = .fixed(&buf);
        try diags.render(&w);
        try testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "resolves outside the package"));
    }
    {
        // No resolver at all is a diagnostic, not a crash.
        var diags: Diagnostics = .init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        _ = parse(testing.allocator, "a.fdt", "@import \"x.fdt\"", .{ .namespace = "foundry" }, &diags) catch {};
        var w: std.Io.Writer = .fixed(&buf);
        try diags.render(&w);
        try testing.expect(std.mem.containsAtLeast(u8, w.buffered(), 1, "no import resolver"));
    }
}

test "string escapes are a closed set, and the unknown ones are errors" {
    var doc = try parseOk("item foundry:x { s \"a\\\"b\\\\c\\nd\\te\\u{2764}\" }");
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("a\"b\\c\nd\te\u{2764}", doc.records[0].fields[0].value.string);

    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.containsAtLeast(u8, try parseErr("item foundry:x { s \"a\\d\" }", &buf), 1, "unknown escape '\\d'"));
    try testing.expect(std.mem.containsAtLeast(u8, try parseErr("item foundry:x { s \"a\\u{}\" }", &buf), 1, "1 to 6 hex digits"));
    try testing.expect(std.mem.containsAtLeast(u8, try parseErr("item foundry:x { s \"a\\u{d800}\" }", &buf), 1, "is not a character"));
}

test "the two characters people type out of habit get their own answer" {
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.containsAtLeast(
        u8,
        try parseErr("item foundry:x { a 1, b 2 }", &buf),
        1,
        "does not use commas",
    ));
    try testing.expect(std.mem.containsAtLeast(
        u8,
        try parseErr("item foundry:x { a = 1 }", &buf),
        1,
        "does not use '='",
    ));
}

test "a diagnostic points at the token, with the line and a caret under it" {
    var buf: [1024]u8 = undefined;
    const rendered = try parseErr(
        \\item foundry:x {
        \\    weight 1.
        \\}
    , &buf);

    try testing.expectEqualStrings(
        \\test.fdt:2:12: error: '1.' is not a number
        \\    weight 1.
        \\           ^~
        \\
    , rendered);
}

test "one broken record does not hide the next twenty" {
    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    const result = parse(testing.allocator, "test.fdt",
        \\item foundry:x { a 1. }
        \\item foundry:y { b 2. }
        \\item foundry:z { c "ok" }
        \\item foundry:w { d 3. }
    , .{ .namespace = "foundry" }, &diags);

    try testing.expectError(error.ContentInvalid, result);
    // Three broken records, three errors — not one error and a stalled parser.
    try testing.expectEqual(@as(usize, 3), diags.count());
    try testing.expectEqual(@as(u32, 1), diags.items.items[0].location.line);
    try testing.expectEqual(@as(u32, 2), diags.items.items[1].location.line);
    try testing.expectEqual(@as(u32, 4), diags.items.items[2].location.line);
}

test "an identifier that would need normalising is refused where it is written" {
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.containsAtLeast(u8, try parseErr("item Foundry:Torch { }", &buf), 1, "identifiers are lowercase"));
    try testing.expect(std.mem.containsAtLeast(u8, try parseErr("item foundry:2torch { }", &buf), 1, "must start with a letter"));
    try testing.expect(std.mem.containsAtLeast(u8, try parseErr("item foundry:a..b { }", &buf), 1, "empty part between dots"));
    try testing.expect(std.mem.containsAtLeast(u8, try parseErr("item foundry:item-torch { }", &buf), 1, "not a letter, digit or underscore"));
    try testing.expect(std.mem.containsAtLeast(u8, try parseErr("item foundry:x { Weight 1 }", &buf), 1, "is not a field name"));
}

test "numbers keep their type, and an out-of-range one is refused" {
    var doc = try parseOk("item foundry:x { a 1  b 1.0  c -3  d 1e-3  e 0xff  f 1_000  g -0x10 }");
    defer doc.deinit(testing.allocator);
    const f = doc.records[0].fields;
    try testing.expectEqual(@as(i128, 1), f[0].value.int);
    try testing.expectEqual(@as(f64, 1.0), f[1].value.float);
    try testing.expectEqual(@as(i128, -3), f[2].value.int);
    try testing.expectEqual(@as(f64, 1e-3), f[3].value.float);
    try testing.expectEqual(@as(i128, 255), f[4].value.int);
    try testing.expectEqual(@as(i128, 1000), f[5].value.int);
    try testing.expectEqual(@as(i128, -16), f[6].value.int);

    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.containsAtLeast(u8, try parseErr("item foundry:x { a 1e400 }", &buf), 1, "out of range"));
}

test "booleans are values; anything else bare is a reference that forgot its namespace" {
    var doc = try parseOk("item foundry:x { a true  b false }");
    defer doc.deinit(testing.allocator);
    try testing.expect(doc.records[0].fields[0].value.bool);
    try testing.expect(!doc.records[0].fields[1].value.bool);

    var buf: [512]u8 = undefined;
    const rendered = try parseErr("item foundry:x { a torch }", &buf);
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "'foundry:torch'"));
}

test "an unterminated string is reported where it opened" {
    var buf: [512]u8 = undefined;
    const rendered = try parseErr("item foundry:x { s \"runs off\n}", &buf);
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "may not contain a line break"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "test.fdt:1:20"));
}

test "an unknown directive names the ones that exist" {
    var buf: [512]u8 = undefined;
    const rendered = try parseErr("@include \"x.fdt\"", &buf);
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "unknown directive '@include'"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "@import, @schema, @patch or @remove"));
}

test "an unknown type names the ones that exist" {
    var buf: [512]u8 = undefined;
    const rendered = try parseErr("@schema foundry:x { a float }", &buf);
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "'float' is not a type"));
    try testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "f32"));
}

test "nesting is bounded in both a value and a type" {
    const shallow: Options = .{ .namespace = "foundry", .limits = .{ .max_nesting_depth = 4 } };
    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    try testing.expectError(error.ContentInvalid, parse(
        testing.allocator,
        "t.fdt",
        "item foundry:x { a [[[[[1]]]]] }",
        shallow,
        &diags,
    ));

    var diags2: Diagnostics = .init(testing.allocator, .default);
    defer diags2.deinit(testing.allocator);
    try testing.expectError(error.ContentInvalid, parse(
        testing.allocator,
        "t.fdt",
        "@schema foundry:x { a { b { c { d { e f32 } } } } }",
        shallow,
        &diags2,
    ));
}

test "a source file larger than the limit is refused before it is parsed" {
    const big = try testing.allocator.alloc(u8, 200);
    defer testing.allocator.free(big);
    @memset(big, ' ');

    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    try testing.expectError(error.ContentInvalid, parse(testing.allocator, "big.fdt", big, .{
        .namespace = "foundry",
        .limits = .{ .max_source_bytes = 100 },
    }, &diags));
    try testing.expect(std.mem.containsAtLeast(u8, diags.items.items[0].message, 1, "over the 100-byte limit"));
}

test "the string table remembers every spelling, which is how a diagnostic reads back" {
    var doc = try parseOk("item foundry:item.torch { drops foundry:item.ash }");
    defer doc.deinit(testing.allocator);

    try testing.expectEqualStrings("foundry:item.torch", doc.stringOf(ContentId.fromString("foundry:item.torch").hash).?);
    try testing.expectEqualStrings("foundry:item.ash", doc.stringOf(ContentId.fromString("foundry:item.ash").hash).?);
    try testing.expectEqualStrings("foundry:item", doc.stringOf(SchemaId.fromStringUnchecked("foundry:item").hash).?);
    try testing.expect(doc.stringOf(0) == null);
}

test "parsing never hangs, whatever the bytes are" {
    // A stand-in for the fuzzer this file is a target for. Every prefix of a plausible
    // document, and every prefix with a byte flipped, must terminate.
    const source =
        \\@import "a.fdt"
        \\@schema foundry:item { weight f32 (default 0.5)  light { r f32 } }
        \\item foundry:item.torch { name "T" tags ["a" "b"] drops foundry:item.ash }
        \\@patch foundry:item.torch { weight 0.4 }
    ;
    var scratch: [512]u8 = undefined;
    for (0..source.len + 1) |cut| {
        var diags: Diagnostics = .init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        var doc = parse(testing.allocator, "f.fdt", source[0..cut], .{ .namespace = "foundry" }, &diags) catch continue;
        doc.deinit(testing.allocator);
    }
    for (0..source.len) |i| {
        @memcpy(scratch[0..source.len], source);
        scratch[i] = '{';
        var diags: Diagnostics = .init(testing.allocator, .default);
        defer diags.deinit(testing.allocator);
        var doc = parse(testing.allocator, "f.fdt", scratch[0..source.len], .{ .namespace = "foundry" }, &diags) catch continue;
        doc.deinit(testing.allocator);
    }
}

test "every byte value in a file produces diagnostics rather than a panic" {
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);

    var diags: Diagnostics = .init(testing.allocator, .default);
    defer diags.deinit(testing.allocator);
    var doc = parse(testing.allocator, "bytes.fdt", &all, .{ .namespace = "foundry" }, &diags) catch return;
    doc.deinit(testing.allocator);
}
